---
audit_id: r10-m5-001-bootstrap-task-a
issue: 382
file: src/kernel/boot/kernel_main.pdx
function: kernel_main_64
effects: [sysreg]
capabilities: [boot]
reviewed_by:
date: 2026-07-02
status: complete
---

# AUDIT R10-m5-001 — Bootstrap kernel_main into Task A (COMPLETE)

## Issue

R10-m5-001 (#382): After the R9 boot sequence, initialize the task runqueue and bootstrap Task A as the first running task.

## Implementation

Extends kernel_main_64 to:
1. Call sched_init_runqueue_r10 to initialize both Task A and Task B TCBs with their kernel stacks
2. Set _current_tcb = &_task_a_tcb to mark Task A as the running task
3. Load RSP from Task A's TCB and call task_a_entry to begin execution

Key code:
```pdx
call sched_init_runqueue_r10;
lea rax, [rip + _task_a_tcb];
lea rdi, [rip + _current_tcb];
mov [rdi], rax;
lea rax, [rip + _task_a_tcb];
mov rsp, [rax + 120];          // Load RSP from TCB.regs[15]
call task_a_entry;
```

## Context: Initialization vs. Bootstrap

R10-m4-001 (sched_init_runqueue_r10) initializes both Task A and Task B stacks:
- Task A: RSP = &stack[1023] (ready for direct call from kernel_main)
- Task B: stack[1023] = task_b_entry, RSP = &stack[1023] (ready for sched_switch_regs ret)

This hybrid initialization supports:
- Task A bootstrap via kernel_main call
- Task B bootstrap via Task A's first yield (sched_switch_regs)

After kernel_main calls task_a_entry, Task A runs its yield loop and switches between tasks via sched_switch_regs.

## Verification

- Symbol present: _task_a_tcb, task_a_entry
- Boot functional: tasks are entered and alternate via yield loop
- Fingerprint validation: boot_r10 test passes (TASK A / TASK B alternation)

## References

- R10-m4-001 audit entry (runqueue initialization)
- R10-m5-002 audit entry (task yield loops)
