---
audit_id: pf_handler-001
issue: 145
file: src/kernel/core/mm/pf_handler.pdx
function: stub_pf_handler
effects: [sysreg, rawmem]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT pf_handler-001 — Page Fault Handler

## Justification
The page-fault (#PF) handler is an exception-handler entry point that
executes in response to hardware page-fault exceptions. It must read
CR2 (faulting address) and CR3 (current page table) via sysreg operations,
then validate and update the current address space's page tables (rawmem).

This is a Phase-5 stub documenting the dual unsafe surface (sysreg CR read
+ rawmem page-table modification) required for fault handling. The real
implementation will land in Phase 6 when paideia-as gains structured control
flow and exception-dispatch support. Until then, the handler remains a
no-op stub that panics on any fault, which is acceptable for Phase 1
single-threaded boot verification.
