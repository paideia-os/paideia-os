---
audit_id: aspace_activate-001
issue: 137
file: src/kernel/core/mm/aspace_activate.pdx
function: p1_aspace_activate
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT aspace_activate-001 — Address Space Activation

## Justification
p1_aspace_activate switches the CPU to a different address space by
writing a new CR3 value (page-table base + PCID). This is a privileged
system-register write that flushes the TLB (or preserves it if PCID is
available). The unsafe block performs the CR3 write, which is required
to change address-space contexts during phase 1.

This is a Phase-5 stub documenting the sysreg effect (CR3 modification)
that will appear in the real implementation during Phase 6. The actual
CR3 write instruction will be added once paideia-as supports the MOV CR3
instruction encoding.
