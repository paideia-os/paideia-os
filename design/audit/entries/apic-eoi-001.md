# apic-eoi-001: LAPIC End-of-Interrupt Signal

**Issue:** #358 (R9-m2-003)

**Module:** `src/kernel/core/apic/eoi.pdx::Eoi`

**Function:** `apic_eoi() -> () !{sysreg, mem} @{boot}`

## Summary

Signals end-of-interrupt (EOI) to the LAPIC by writing 0 to the EOI MMIO register. This acknowledges interrupt handling and re-enables lower-priority interrupts.

## Implementation

| Aspect | Detail |
|--------|--------|
| **MMIO register** | LAPIC EOI @ 0xFEE000B0 |
| **Value written** | 0 (any value works; 0 is canonical) |
| **Encoding** | `mov [rax], ecx` (32-bit write via 64-bit register) |
| **Real body** | `mov rax, 0xFEE000B0; xor rcx, rcx; mov [rax], ecx; ret` |

## Justification

Per Intel SDM Vol 3A §10.8.5, writing to the EOI register (MMIO offset 0xB0) must happen before the ISR returns. The write acknowledges the interrupt to the LAPIC and allows it to service lower-priority pending interrupts.

**Timing:** EOI must be issued after the ISR has completed its work but before iretq returns to the interrupted code.

**paideia-as support:** Standard mov encoding for 32-bit MMIO (v0.6.0+).

## Cross-module references

Called by `handle_timer` (core/int/exceptions.pdx) at the end of timer ISR.

## Phase 6 integration

- Follows design/infrastructure/apic-system.md §3 (interrupt completion sequence).
- Required by R9-m2-004 ISR orchestration for correct LAPIC operation.

---
**Audit:** R9-m2-003 bundle (June 2026)
