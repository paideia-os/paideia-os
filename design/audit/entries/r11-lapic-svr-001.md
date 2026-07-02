# r11-lapic-svr-001: LAPIC Spurious-Interrupt-Vector Register (SVR) Enable

**Issue:** #389 (R11-m1-002)

**Module:** `src/kernel/core/apic/lapic_timer.pdx::LapicTimer`

**Function:** `apic_svr_enable() -> () !{sysreg, mem} @{boot}`

## Summary

Writes the LAPIC Spurious-Interrupt-Vector Register (SVR) to globally enable LAPIC interrupt delivery. Per Intel SDM Vol 3A §10.4.7.1, LAPIC is disabled by default and requires software to set bit 8 in the SVR to enable it. Without this write, programmed LVT registers (e.g., timer, lint0/1) will not deliver interrupts.

## Implementation

| Aspect | Detail |
|--------|--------|
| **MMIO register** | Spurious-Interrupt-Vector (SVR) @ 0xFEE000F0 |
| **Value written** | 0x1FF (bit 8 = enable, bits 7:0 = 0xFF = spurious vector) |
| **Encoding** | `mov rax, 0xFEE000F0; mov rcx, 0x1FF; mov [rax], rcx` |
| **Real body** | 32-bit MMIO write to offset 0xF0 in LAPIC address space |
| **Silent behavior** | No print or halt; side-effect only (sets enable bit) |

## Justification

Per Intel SDM Vol 3A §10.4.7.1:
- Bit 8 is the APIC software enable bit. Setting it to 1 enables LAPIC globally.
- Bits 7:0 specify the spurious interrupt vector (0xFF is a reserved/rarely-used vector).
- This must be called **before** interrupts are enabled (sti) but **after** IDT and LVT registers are configured.

Without this write, even though `idt_install()` has installed the IDT and `lapic_timer_init()` has programmed the timer LVT, interrupts will not be delivered because the LAPIC is globally disabled.

**paideia-as support:** MMIO writes via `mov [rax], rcx` (v0.6.0+).

## Call order rationale (R11-m1-002)

Correct order in `kernel_main_64`:
1. `idt_install` — IDT must be loaded before any interrupts
2. `apic_enable` — Verify LAPIC global enable bit (MSR IA32_APIC_BASE bit 11)
3. `apic_svr_enable` — **Enable LAPIC via SVR bit 8** (NEW)
4. `pic_mask_all` — Mask PIC to prevent spurious IRQs
5. `lapic_timer_init` — Program LVT Timer register
6. `sched_init_runqueue_r10` — Initialize TCBs
7. Set `_current_tcb` — Ensure interrupt handlers have valid context
8. `sti` — Enable interrupts (NOW safe, moved here in R11-m1-002)
9. `task_a_entry` — Enter Task A

**Critical fix:** Previously, `sti` was called **before** `_current_tcb` was set. If an interrupt fired in that window, `handle_timer` would read an uninitialized (null or garbage) `_current_tcb` pointer. R11-m1-002 moves `sti` to after `_current_tcb` is set.

## Cross-module references

None (side-effect-only, no calls to external modules).

## Phase 6 integration

- Follows design/infrastructure/apic-system.md §2 (LAPIC enable sequence).
- Required for R10-m2-003 timer delivery (previously masked by missing SVR enable).
- Precedes `sti` in the bootflow.

---
**Audit:** R11-m1-002 bundle (July 2026)
