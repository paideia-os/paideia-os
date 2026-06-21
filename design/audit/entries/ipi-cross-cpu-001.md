---
audit_id: ipi-cross-cpu-001
issue: 175
file: src/kernel/core/ipi/cross_cpu.pdx
function: stub_ipi_send
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT ipi-cross-cpu-001 — Cross-CPU IPI delivery

## Justification

Inter-Processor Interrupts (IPIs) are sent via the LAPIC ICR (Interrupt Command Register)
MSR in x2APIC mode. Writing to x2APIC_ICR_MSR is a privileged system-register operation
that directly affects the interrupt delivery behavior of all CPUs on the platform.

Improper IPI delivery can cause:
- Incorrect target CPU selection leading to lost notifications
- Interrupt storm if vector is misaligned
- Deadlock if scheduler reschedule IPIs don't fire
- Data corruption if TLB shootdown IPIs don't complete

The unsafe operations include:
- Computing ICR value from vector and target APIC ID
- Writing x2APIC_ICR_MSR to dispatch the IPI
- Waiting for delivery completion (checking delivery status bit)
- Broadcasting to all CPUs (special ICR mode)
- Per-CPU state synchronization
