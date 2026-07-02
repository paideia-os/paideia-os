---
audit_id: r10-m5-fixup-switch-regs-offsets
related_issue: 377
file: src/kernel/core/sched/switch.pdx
function: sched_switch_regs
effects: [mem]
capabilities: [sched]
reviewed_by:
date: 2026-07-02
status: complete
---

# AUDIT R10-m5 Fixup — Corrected sched_switch_regs register offsets (COMPLETE)

## Summary

R10-m3-001 defined the correct register offsets in the audit entry but the implementation used incorrect compact offsets. This fixup corrects the implementation to match the audit entry.

## Issue

R10-m3-001 audit entry specified correct offsets per tcb.pdx canonical layout:
- RBX = regs[13] = offset 104
- RBP = regs[14] = offset 112
- R12 = regs[9] = offset 72
- R13 = regs[10] = offset 80
- R14 = regs[11] = offset 88
- R15 = regs[12] = offset 96
- RSP = regs[15] = offset 120
- RFLAGS = offset 136

But the implementation used compact offsets (0, 8, 16, 24, 32, 40, 48, 56) that didn't match the TCB layout.

## Fix

Updated src/kernel/core/sched/switch.pdx sched_switch_regs to use correct offsets:

```pdx
// Save outgoing TCB (from_tcb in RDI)
mov [rdi + 104], rbx;         // RBX at regs[13]
mov [rdi + 112], rbp;         // RBP at regs[14]
mov [rdi + 72], r12;          // R12 at regs[9]
mov [rdi + 80], r13;          // R13 at regs[10]
mov [rdi + 88], r14;          // R14 at regs[11]
mov [rdi + 96], r15;          // R15 at regs[12]
pushfq;
pop rax;
mov [rdi + 136], rax;         // RFLAGS at offset 136
mov [rdi + 120], rsp;         // RSP at regs[15]

// Restore incoming TCB (to_tcb in RSI)
mov rsp, [rsi + 120];         // RSP restore FIRST
mov rax, [rsi + 136];
push rax;
popfq;                        // RFLAGS restore
mov r15, [rsi + 96];
mov r14, [rsi + 88];
mov r13, [rsi + 80];
mov r12, [rsi + 72];
mov rbp, [rsi + 112];
mov rbx, [rsi + 104];
ret
```

Also made sched_switch_regs pub (was private) so it can be called from tasks.pdx module.

## Verification

- Offsets verified against tcb.pdx canonical layout
- Context switching works correctly in boot_r10 test
- Task A/B alternation proves register save/restore is correct

## Impact

Without this fix, sched_switch_regs would corrupt the TCB layout and prevent proper context switching. This fix was necessary for r10-m5 task alternation to work.
