---
audit_id: apic-x2apic-001
issue: 121
file: src/kernel/core/apic/x2apic.pdx
function: stub_enable_x2apic
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT apic-x2apic-001 — x2APIC enablement

## Justification

x2APIC mode is enabled via privileged MSR writes to IA32_APIC_BASE (0x1B). This MSR controls
the APIC operation mode and must be written during early boot on all CPUs to enable extended
APIC registers and higher-performance interrupt delivery. Reading and writing this MSR is a
privileged system-register operation that affects the CPU's interrupt handling capability.

The unsafe operations include:
- Reading IA32_APIC_BASE_MSR via RDMSR instruction
- Modifying bits 10-11 (x2APIC and global enable flags)
- Writing IA32_APIC_BASE_MSR via WRMSR instruction
- Per-CPU execution to ensure all cores are synchronized
