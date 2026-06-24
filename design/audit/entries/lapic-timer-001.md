# lapic-timer-001: LAPIC Timer TSC-Deadline Mode + Rearm

**Issue:** #357 (R9-m2-002)

**Module:** `src/kernel/core/apic/lapic_timer.pdx::LapicTimer`

**Functions:**
- `lapic_timer_init() -> () !{sysreg, mem} @{boot}`
- `lapic_timer_rearm(interval: u64) -> () !{sysreg} @{boot}`

## Summary

Programs the LAPIC local timer to fire on a TSC-deadline basis with interrupt vector 32. Rearm function sets the next deadline via IA32_TSC_DEADLINE MSR.

## Implementation

### lapic_timer_init()

| Aspect | Detail |
|--------|--------|
| **MMIO register** | LAPIC LVT Timer @ 0xFEE00320 |
| **Value written** | 0x40020 = `(2 << 17) \| 32` |
| **Bit 18:17** | 0b10 = TSC-deadline mode (per Intel SDM Vol 3A §10.5.1) |
| **Bit 7:0** | 32 = interrupt vector |
| **Encoding** | `mov [rax], ecx` (32-bit MMIO write via 64-bit register) |
| **Real body** | `mov rax, 0xFEE00320; mov rcx, 0x40020; mov [rax], ecx; ret` |

### lapic_timer_rearm(interval: u64)

| Aspect | Detail |
|--------|--------|
| **Input** | RDI = interval (in TSC cycles) |
| **MSR** | IA32_TSC_DEADLINE (0x6E0) |
| **Procedure** | `rdtsc` (EDX:EAX), compose 64-bit TSC, add interval, write MSR |
| **Encoding** | Full rdtsc + wrmsr sequence |
| **Real body** | `rdtsc; shl rdx, 32; or rax, rdx; add rax, rdi; mov rcx, 0x6E0; mov rdx, rax; shr rdx, 32; wrmsr; ret` |

## Justification

**TSC-deadline mode:** Per Intel SDM Vol 3A §10.5.1, writing mode bits 18:17 = 0b10 selects TSC-deadline mode, where the timer fires when the CPU's TSC >= the value written to IA32_TSC_DEADLINE MSR.

**MMIO vs MSR split:**
- **MMIO (LVT Timer @ 0xFEE00320):** Mode selection and vector routing.
- **MSR (IA32_TSC_DEADLINE 0x6E0):** Deadline value (written per rearm).

**32-bit write limitation:** The specification notes that 32-bit MMIO writes are preferred; paideia-as allows 32-bit loads/stores via r32 operands in 64-bit regs.

**paideia-as support:** rdtsc, rdmsr, wrmsr encoders (v0.6.0+).

## Cross-module references

Called from `kernel_main_64` (boot/kernel_main.pdx) before `sti`.

Called by `handle_timer` (core/int/exceptions.pdx) to rearm after each interrupt.

## Phase 6 integration

- Follows design/infrastructure/apic-system.md §2 (LAPIC timer programming).
- Integrated into R9-m2-002 bootflow and R9-m2-004 ISR.

---
**Audit:** R9-m2-002 bundle (June 2026)
