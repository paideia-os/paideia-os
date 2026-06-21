# PaideiaOS Audit Catalog

Every `unsafe { }` block in PaideiaOS kernel source carries an audit
entry under `design/audit/entries/`. The entry records:

- The IR effect (`sysreg`, `mmio`, `rawmem`, etc.) that the block performs.
- The capability set required (often empty for kernel-internal blocks).
- A human-readable justification ≥ 20 characters.

## Entry schema

```yaml
---
audit_id: <slug>
issue: <gh-issue-number>
file: src/kernel/.../<basename>.pdx
function: <function name>
effects: [<effect-name>, ...]
capabilities: [<cap-name>, ...]
reviewed_by:
date: YYYY-MM-DD
---

# AUDIT <slug> — <function name>

## Justification
<paragraph explaining why this block needs unsafe>
```

The `effects` field uses paideia-as effect names (`sysreg` for CR/DR/MSR
ops, `rawmem` for unbounded memory writes, `mmio` for device-port I/O).
The `capabilities` field is currently empty for all kernel-internal
operations; once userspace exposure begins, capabilities will be required.

## Phase-1 entries (12 unsafe blocks across 9 files)

| Audit ID | File | Function | Effects |
|----------|------|----------|---------|
| boot-gdt-001 | boot/gdt.pdx | gdt_load | sysreg |
| boot-pagetables-001 | boot/pagetables.pdx | (data; no fn) | sysreg |
| boot-longmode-001 | boot/long_mode.pdx | transition | sysreg |
| boot-zerobss-001 | boot/zero_bss.pdx | zero_bss | sysreg |
| uart-init-001 | boot/uart.pdx | uart_out | sysreg |
| uart-putc-001 | boot/uart.pdx | uart_putc | sysreg |
| uart-puts-001 | boot/uart.pdx | uart_puts | sysreg |

## Phase-2+ growth

Each new `.pdx` file with an `unsafe { }` block adds a corresponding
audit entry in the same commit. The CI smoke (Phase-1 m1-014) will
eventually verify that every `unsafe { }` block in the source tree
has a matching audit entry.

## Phase 1 honest scope

All Phase-1 unsafe blocks are Phase-1 stubs (single-instruction or
single-port-write) gated on paideia-as encoder gaps (cf. paideia-as
issues #734, #736 for the open bugs). Real multi-instruction
unsafe blocks land when paideia-as Phase 6 ships jcc/cmp/call
encoders for the unsafe-block payload walker.
