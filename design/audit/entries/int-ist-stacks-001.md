---
audit_id: int-ist-stacks-001
issue: 118
file: src/kernel/core/int/ist.pdx
function: stub_ist_init
effects: [sysreg, rawmem]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT int-ist-stacks-001 — IST stack initialization

## Justification

IST (Interrupt Stack Table) stacks are dedicated memory regions allocated in kernel .bss
and registered into per-CPU TSS (Task State Segment) structures via system-register writes.
This requires unsafe raw memory access (reading/writing kernel BSS) and privileged MSR/register
access (TSS.ist fields). IST stacks are mandatory for handling double-fault (#8), NMI (#2),
and machine-check (#18) exceptions, as these exceptions cannot safely use the current kernel
stack (which may be invalid or corrupted).

The unsafe operations include:
- Allocating three 4KB stacks in kernel BSS per CPU
- Computing stack top pointers (base + 4096)
- Writing IST pointers into the per-CPU TSS structure
- Ensuring proper 16-byte alignment for stack safety
