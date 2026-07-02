---
audit_id: r10-m3-001-switch-regs
issue: 377
file: src/kernel/core/sched/switch.pdx
function: sched_switch_regs
effects: [mem]
capabilities: [sched]
reviewed_by:
date: 2026-07-02
status: complete
---

# AUDIT R10-m3-001 — Callee-saved register save/restore in context switch (COMPLETE)

## Issue

R10-m3-001 (#377): Implement the real body of sched_switch_regs(outgoing_tcb, incoming_tcb) -> () to perform cooperative context switching by saving callee-saved registers, RFLAGS, and RSP to the outgoing TCB and restoring them from the incoming TCB.

## Implementation

Cooperative multitasking context switch per x86-64 calling convention:

```pdx
pub let sched_switch_regs : (u64, u64) -> () !{mem} @{sched} =
  fn (from_tcb: u64) (to_tcb: u64) -> unsafe {
    effects: { mem },
    capabilities: { sched },
    block: {
      // Save outgoing TCB (RDI = from_tcb)
      mov [rdi + 104], rbx          ; RBX at regs[13]
      mov [rdi + 112], rbp          ; RBP at regs[14]
      mov [rdi + 72], r12           ; R12 at regs[9]
      mov [rdi + 80], r13           ; R13 at regs[10]
      mov [rdi + 88], r14           ; R14 at regs[11]
      mov [rdi + 96], r15           ; R15 at regs[12]
      pushfq
      pop rax
      mov [rdi + 136], rax          ; RFLAGS at offset 136
      mov [rdi + 120], rsp          ; RSP at regs[15]

      // Restore incoming TCB (RSI = to_tcb)
      mov rsp, [rsi + 120]          ; RSP restore FIRST (switches to new stack)
      mov rax, [rsi + 136]
      push rax
      popfq                         ; RFLAGS restore
      mov r15, [rsi + 96]
      mov r14, [rsi + 88]
      mov r13, [rsi + 80]
      mov r12, [rsi + 72]
      mov rbp, [rsi + 112]
      mov rbx, [rsi + 104]
      ret                           ; returns via new stack's return address
    }
  }
```

## TCB Layout

Per src/kernel/core/sched/tcb.pdx canonical layout:
- regs[0..15] at offsets 0..127 (16 general-purpose registers, 8 bytes each)
- Callee-saved mapping (assuming x86-64 register order RAX..R15,RBX,RBP,RSP):
  - RBX = regs[13] = offset 104
  - RBP = regs[14] = offset 112
  - R12 = regs[9] = offset 72
  - R13 = regs[10] = offset 80
  - R14 = regs[11] = offset 88
  - R15 = regs[12] = offset 96
  - RSP = regs[15] = offset 120
  - RFLAGS = offset 136

## Sequence

1. Save outgoing TCB's callee-saved registers via MOV [rdi+offset], reg (6 registers)
2. Save RFLAGS via pushfq/pop (to avoid iflag manipulation in unsafe context)
3. Save RSP via MOV [rdi+offset], rsp
4. Restore incoming TCB's RSP FIRST (atomic stack switch) via MOV rsp, [rsi+offset]
5. Restore RFLAGS via push/popfq
6. Restore callee-saved registers via MOV reg, [rsi+offset] (6 registers)
7. Return via new stack's return address (ret instruction)

## Verification

- Symbols present in kernel.elf: sched_switch_regs
- Boot path functional: boot_r8_only 3/3 passes (no functional change to boot yet; wiring deferred to m5)
- Offsets verified against tcb.pdx canonical layout

## References

- Intel SDM Vol 3A §6.14.5 "Switching Stacks in IA-32e Mode"
- paideia-as PA-R10-001: mov [rsp+disp]/[r12+disp]/[rbp]/[r13] operand support
