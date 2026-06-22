---
audit_id: exceptions-001
issue: 257
file: src/kernel/core/int/exceptions.pdx
function: cpu_halt / read_cr2
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT exceptions-001 — CPU exception handlers (R6.5-006)

## Justification
The six critical exception handlers (vectors 0 DE, 3 BP, 6 UD, 8 DF, 13 GP,
14 PF) trace the fault and halt the CPU. Two privileged operations are involved:
`hlt` (stop the CPU) and `mov rax, cr2` (read the faulting linear address, page
fault only). Both are unsafe and live in structured unsafe blocks.

Citation: Intel SDM Vol 3A §6.15 (exception reference), §4.7 (page-fault CR2).
**Verification TODO.**

## Per-vector behaviour (<= 8 instructions each)
- DE/BP/UD/DF/GP: save context, write "EXCn vector=N rip=...", halt loop.
- PF: additionally `mov rax, cr2` and include cr2=... in the trace, then halt.
- Phase 7+ extends PF to recoverable handling (demand paging / COW).

## Phase-6 honest scope gaps
- **hlt loop** (cli; hlt; jmp): `cpu_halt` emits `hlt`; the cli + loop wrapper is
  gated on the loop/jmp encoder.
- **mov-from-CR2 operand**: `read_cr2` emits `mov rax, rax` placeholder.
- **UART trace emission**: gated on the uart_puts loop (boot/uart.pdx).
  Implemented for real: the error-code/CR2-read classification predicates and
  the per-vector dispatch.

## Verification (when encoders land)
Per vector: induce the exception (e.g. `div rax, 0` for DE), verify the trace
appears on UART and the kernel halts cleanly.
