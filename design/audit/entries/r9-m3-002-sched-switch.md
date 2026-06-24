---
audit_id: r9-m3-002-sched-switch
issue: 361
file: src/kernel/core/sched/switch.pdx
function: sched_switch_regs, sched_switch
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-24
---

# AUDIT r9-m3-002 — Context-switch stub for cooperative scheduler

## Overview

R9-m3-002 audits the context-switch stub that was introduced in R4.5-003. Per the softarch §"R9-narrow recommendation":
- Full callee-saved register save/restore is deferred to R10 (Phase 7)
- R9-narrow uses cooperative multitasking without actual context switching
- Audit entry explicitly notes deferral to R10

The switch.pdx module remains unchanged from R4.5-003: `sched_switch_regs` is a stub (mov rax, rax placeholder), and `sched_switch` updates the bookkeeping (current_tcb). No real registers are saved or restored during R9.

## Justification

### Honest scope for R9-narrow MVP

Per R4.5-003, the intended 23-instruction sequence:
- **SAVE half:** 11 instructions to push RBX, RBP, R12–R15, RFLAGS, RSP, RIP into from_tcb
- **RESTORE half:** 11 symmetric instructions to reload registers from to_tcb
- **iretq:** 1 instruction to return to to_tcb's saved RIP

None of these are implemented in R9 due to paideia-as encoder limitations:
- Base+displacement memory operands (`mov [rdi+0x80], rbp`) — not yet supported
- `iretq` instruction — not yet supported

For R9-narrow, the full register swap is skipped. No tasks are actually context-switched; the kernel remains in boot context throughout.

### Deferred logic (R10)

Full context-switch body deferred to R10 (Phase 7) includes:
- Saving callee-saved regs (RBP, RBX, R12–R15) to from_tcb
- Saving RFLAGS and RSP to from_tcb
- Saving RIP (current position) to from_tcb
- Restoring all of the above from to_tcb
- Loading RSP and issuing iretq to jump to to_tcb's saved code location

## Implementation details

### `sched_switch_regs(from_tcb, to_tcb)` stub

```pdx
let sched_switch_regs : (u64, u64) -> () !{sysreg} @{} =
  fn (from_tcb: u64) (to_tcb: u64) -> unsafe {
    ...
    block: {
      mov rax, rax  // placeholder
    }
  }
```

Accepts two TCB pointers but performs no operations. The justification documents the full intended sequence for R10.

### `sched_switch(from, to)` bookkeeping

```pdx
let sched_switch : (u64, u64) -> u64 = fn (from_tcb: u64) (to_tcb: u64) -> {
  sched_switch_regs(from_tcb, to_tcb);
  current_tcb = to_tcb;  // Update bookkeeping mirror
  SWITCH_OK
}
```

Calls the register-switch stub (which does nothing), updates the current_tcb bookkeeping, and returns SWITCH_OK. This is real and parseable on paideia-as 0.6.0+.

## Invariants

1. **No register modification:** sched_switch_regs is a stub; kernel state unchanged
2. **Bookkeeping update:** current_tcb mirror is updated (for audit and future R10 integration)
3. **No stack corruption:** MVP avoids context-switch because no real stack operations occur

## Testing strategy

- R9 verification: call sched_switch(tcb0, tcb1); verify current_tcb updates to tcb1 (✓ done: no errors)
- R10 integration: implement register save/restore; verify callee-saved regs preserved across switches
- R10 correctness: verify on-stack frame (SS/RSP/RFLAGS/CS/RIP) is built correctly for iretq

## Future work (R10)

- Emit the 11 GPR push instructions (base+displacement operand support in paideia-as)
- Emit the 11 GPR pop instructions
- Emit the iretq instruction
- Verify TCB offsets (0x00, 0x08, ..., 0x78) match TCB struct definition
- Audit per Intel SDM Vol 3A §6.14.5 (Switching Stacks in IA-32e Mode)
