# R13-m5-003 — Syscall table (13 entries, preflight §C)

**Issue:** #429  
**File:** src/kernel/core/syscall/dispatch.pdx (rewritten), src/kernel/core/syscall/table.pdx (new)  
**Function:** syscall_dispatch  
**Effects:** mem, sysreg  
**Capabilities:** cap, sched

## Overview

Real syscall dispatcher replacing the #428 stub. Linear cmp/je chain over 13 syscall IDs per preflight §C. Adopted §C (native names) NOT §J (POSIX shim); rationale is that §C is the frozen preflight and downstream milestones reference its IDs.

## Table

| ID | Name | R13 Status | Handler |
|----|------|------------|---------|
| 0 | sys_exit_thread | dead code | xor rax, rax; ret |
| 1 | sys_yield | real | tail-call sched_yield |
| 2 | sys_ipc_send | ENOSYS | R13-m6 |
| 3 | sys_ipc_recv | ENOSYS | R13-m6 |
| 4 | sys_cap_invoke | real | tail-call cap_invoke after (rsi->rdi, rdx->rsi) |
| 5 | sys_cap_mint | ENOSYS | arity mismatch (see follow-up) |
| 6 | sys_cap_query | ENOSYS | R13-m2 handler absent |
| 7 | sys_signal_register | ENOSYS | R13-m4 |
| 8 | sys_signal_return | ENOSYS | R13-m4 |
| 9 | sys_cpu_id | ENOSYS | R13-m1 handler absent |
| 10 | sys_sipi_target | ENOSYS | R13-m2 |
| 11 | sys_kpti_enable | ENOSYS | R13-m3 runtime hook missing |
| 12 | sys_debug_puts | real | call uart_puts, echo msg_len |

## Register Discipline

Entry from trampoline: rdi=sysno, rsi=a0, rdx=a1, rcx=a2, r8=a3 (SysV C ABI).
Return: rax = handler result or ENOSYS.

## Handler Wiring

- sys_yield: no arg shuffle. tail-call sched_yield.
- sys_cap_invoke: shuffle rsi->rdi, rdx->rsi. tail-call cap_invoke.
- sys_debug_puts: shuffle rsi->rdi (msg_ptr). save rdx (msg_len) across call. return msg_len.

## ENOSYS Rationale (per stub)

- sys_ipc_send / sys_ipc_recv: no ring-3 IPC path yet; R13-m6.
- sys_cap_mint: §C spec is (descriptor:ptr, rights) -> slot; existing Mint.cap_mint takes (kind, target_ptr, rights). Needs descriptor-layout definition. Follow-up filed.
- sys_cap_query: no cap_query symbol; R13-m2 milestone-gated.
- sys_signal_register / sys_signal_return: R13-m4 signal work.
- sys_cpu_id: no cpu_id symbol; deferred.
- sys_sipi_target: R13-m2 multi-CPU.
- sys_kpti_enable: R13-m3 needs runtime hook.

## Effects Widening

syscall_entry widened !{sysreg, mem} @{} -> !{mem, sysreg} @{cap, sched} to cover reachable handlers.

## Cross-References

- design/milestones/r13-preflight.md §C
- design/audit/entries/r13-m5-002-syscall-trampoline.md
- src/kernel/core/cap/invoke.pdx:50 (cap_invoke)
- src/kernel/core/sched/yield.pdx:43 (sched_yield)
- src/kernel/boot/uart.pdx:81 (uart_puts)

## Acceptance Criteria

- [x] Build succeeds.
- [x] All 5 smoke modes green byte-identically.
- [x] objdump shows cmp/je chain in syscall_dispatch.
- [x] syscall_entry effects widened.
- [x] No stale references to old stub body.
