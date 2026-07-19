---
issue: 564
milestone: R15.M7 (Scheduler: cooperative → timer-preemptive)
topic: Task struct layout — regs_save region freeze (R15.M7-003)
---

# Task struct layout — regs_save region freeze

## Overview

This document freezes the layout of the `regs_save` region within the R15 `task_struct` (the `tcb.pdx` kernel TCB layout). The freeze is cumulative:

- **#562** froze `regs_save.rsp` at offset +32 and `regs_save.rip` at offset +40.
- **#564** (this issue) freezes `regs_save.rflags` and the callee-save GPRs (rbx, rbp, r12–r15).
- **Future issues** (#571, #572, etc.) will populate the reserved region at +104..+152.

## Field layout table

| Offset | Size | Field                    | Type  | Frozen by | Notes                                                                                                       |
|--------|------|--------------------------|-------|-----------|-------------------------------------------------------------------------------------------------------------|
| +32    | 8    | `regs_save.rsp`          | u64   | #562      | Kernel stack pointer at task suspend. Points to caller-of-sched_switch's return address (resumed) or entry. |
| +40    | 8    | `regs_save.rip`          | u64   | #562      | Resume address. ALWAYS `&sched_switch_r15_continuation` for R15 tasks.                                      |
| +48    | 8    | `regs_save.rflags`       | u64   | #564      | RFLAGS snapshot at suspend. IF preserved across the round-trip.                                             |
| +56    | 8    | `regs_save.rbx`          | u64   | #564      | SysV callee-save.                                                                                           |
| +64    | 8    | `regs_save.rbp`          | u64   | #564      | SysV callee-save.                                                                                           |
| +72    | 8    | `regs_save.r12`          | u64   | #564      | SysV callee-save.                                                                                           |
| +80    | 8    | `regs_save.r13`          | u64   | #564      | SysV callee-save.                                                                                           |
| +88    | 8    | `regs_save.r14`          | u64   | #564      | SysV callee-save.                                                                                           |
| +96    | 8    | `regs_save.r15`          | u64   | #564      | SysV callee-save.                                                                                           |
| +104..+152 | 48 | `regs_save._reserved`    | u64×6 | (open)    | Reserved for future: FS_BASE, GS_BASE_KERNEL, MSR_KERNEL_GS_BASE, XSAVE-ptr, CR3, IST-stack.               |

**Total `regs_save` extent: [+32, +152) — 15 u64 slots, 120 bytes.**

## Invariants

### regs_save.rip invariant

For every task that has been suspended at least once via `sched_switch_r15`, `regs_save.rip == &sched_switch_r15_continuation`. Fresh tasks that have never run must have `regs_save.rip == &sched_switch_r15_continuation` also, and their kernel stack must be pre-populated with the actual entry address at `regs_save.rsp` (see design/kernel/r15-m7-003-sched-switch.md §6.2 trampoline).

### Callee-save preservation

SysV x86-64 ABI callee-save registers (rbx, rbp, r12–r15) are saved and restored by `sched_switch_r15`. Any code that calls `sched_switch_r15` must not expect these registers to change across the call, even if control is decoupled across multiple task switches.

### RFLAGS IF preservation

The caller's IF (interrupt-enable bit) in RFLAGS is captured before `cli` disables interrupts and restored after `popfq` inside the continuation trampoline. The caller observes IF preserved across the `call sched_switch_r15` round-trip.

## Rationale

See design/kernel/r15-m7-003-sched-switch.md §3 for detailed rationale on field ordering (cache-line locality, disp8 encoding) and the choice of callee-save registers.

## Cross-references

- design/kernel/r15-m7-003-sched-switch.md (issue #564 — full context-switch implementation)
- design/kernel/r15-m7-001-idle-task.md (issue #562 — partial regs_save freeze)
- design/kernel/r15-m7-002-runqueue.md (issue #563 — sched_pick_next_r15)
