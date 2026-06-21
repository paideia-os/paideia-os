---
audit_id: boot-gdt-001
issue: 1
file: src/kernel/boot/gdt.pdx
function: gdt_load
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT boot-gdt-001 — gdt_load

## Justification
LGDT installs the CPU's Global Descriptor Table register, a privileged
system-register write with no typed surface in paideia-as. Required during
Phase-1 boot to replace the firmware-provided GDT with the kernel's own
flat 32/64 descriptor set prior to the long-mode transition.

The unsafe block contains exactly one instruction (`lgdt [rdi]`) which
takes the GDTR descriptor pointer from RDI per the paideia-as calling
convention.
