---
audit_id: apic-ioapic-001
issue: 168
file: src/kernel/core/apic/ioapic.pdx
function: stub_ioapic_set_redir
effects: [mmio]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT apic-ioapic-001 — I/O APIC redirect table programming

## Justification

I/O APIC redirect table entries are configured via memory-mapped I/O (MMIO) operations to
physical addresses discovered during ACPI MADT parsing. Each redirect entry is a 64-bit value
that specifies the interrupt vector, delivery mode, destination APIC ID, and masking state.

Writing to MMIO space is an unsafe operation because:
- Incorrect vector assignments may route interrupts to the wrong handler
- Improper destination masking could deadlock or crash the system
- Out-of-bounds IRQ indices could access undefined MMIO regions
- Concurrent writes could race with hardware state updates

The unsafe operations include:
- Reading IOAPIC MMIO base address from ACPI MADT
- Computing redirect table entry offsets
- Writing 64-bit values to I/O APIC MMIO space
- Masking/unmasking individual interrupt lines during runtime
