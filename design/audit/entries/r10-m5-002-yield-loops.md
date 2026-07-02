---
audit_id: r10-m5-002-yield-loops
issue: 383
file: src/kernel/core/sched/tasks.pdx
functions: [task_a_entry, task_b_entry]
effects: [mem, sched]
capabilities: [boot, sched]
reviewed_by:
date: 2026-07-02
status: complete
---

# AUDIT R10-m5-002 — Cooperative yield loops in Task A and Task B (COMPLETE)

## Issue

R10-m5-002 (#383): Replace the simple halt loops in task entry points with cooperative yield loops that print the task name and switch control to the other task.

## Implementation

Both task_a_entry and task_b_entry implement infinite loops:

```pdx
pub let task_a_entry : () -> () !{mem, sched} @{boot, sched} = fn() -> unsafe {
  effects: { mem, sched },
  capabilities: { boot, sched },
  block: {
    task_a_loop:
      lea rdi, [rip + _task_a_msg];
      call uart_puts;
      lea rdi, [rip + _task_a_tcb];
      lea rsi, [rip + _task_b_tcb];
      call sched_switch_regs;
      jmp task_a_loop
  }
}
```

Task B is symmetric (swaps message and TCB arguments).

## Context: Per-Task Message Output

Each task has a compile-time message defined in boot_stub.S (.rodata):
- _task_a_msg = "TASK A\n"
- _task_b_msg = "TASK B\n"

## Cooperative Multitasking

When task_a_entry calls sched_switch_regs(task_a_tcb, task_b_tcb):
1. sched_switch_regs saves Task A's callee-saved registers and RSP (including the return address for the jmp loop)
2. sched_switch_regs restores Task B's callee-saved registers and RSP
3. sched_switch_regs returns via `ret`, which pops Task B's return address (task_b_entry for the first yield, or the return address from Task B's previous yield call)
4. Control transfers to Task B, which prints its message and yields back to Task A
5. When Task A is resumed, sched_switch_regs returns from the call, and Task A continues at the next instruction (jmp task_a_loop)

## Register and Effects

- Effects: mem (uart_puts reads message; sched_switch_regs modifies TCBs), sched (task switching)
- Capabilities: boot (required for task bodies per design), sched (required for sched_switch_regs and TCB manipulation)

## Verification

- Symbols present: task_a_entry, task_b_entry, _task_a_msg, _task_b_msg
- Alternation verified: boot_r10 fingerprint shows repeated TASK A / TASK B sequence
- Stack integrity: each task maintains its own kernel stack through context switches

## References

- R10-m3-001 audit entry (sched_switch_regs implementation, fixed in m5)
- R10-m5-001 audit entry (bootstrap into Task A)
- R10-m5-003 audit entry (boot_r10 fingerprint)
