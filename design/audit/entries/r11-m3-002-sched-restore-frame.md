---
audit_id: r11-m3-002-sched-restore-frame
issue: 394
file: src/kernel/core/sched/preempt.pdx
function: sched_restore_frame
effects: [mem]
capabilities: [sched]
reviewed_by:
date: 2026-07-02
status: complete
---

# AUDIT R11-m3-002 — sched_restore_frame: Restore trap frame from TCB (COMPLETE)

## Issue

R11-m3-002 (#394): Implement sched_restore_frame(tcb, frame) -> () to write TCB state (RIP/RSP/RFLAGS) back into the trap frame, preparing it for iretq execution of the next task.

## Implementation

Symmetric to sched_save_frame: register-to-memory move sequence (source and destination swapped):

```pdx
pub let sched_restore_frame : (u64, u64) -> () !{mem} @{sched} =
  fn (tcb: u64, frame: u64) -> unsafe {
    effects: { mem },
    capabilities: { sched },
    block: {
      mov rax, [rdi + 128]        // RIP from TCB offset 128
      mov [rsi + 136], rax        // RIP → frame+136 (CPU frame RIP)
      mov rax, [rdi + 120]        // RSP from TCB offset 120
      mov [rsi + 160], rax        // RSP → frame+160 (CPU frame RSP)
      mov rax, [rdi + 136]        // RFLAGS from TCB offset 136
      mov [rsi + 144], rax        // RFLAGS → frame+144 (CPU frame RFLAGS)
      ret
    }
  }
```

## Trap Frame Layout

Same as sched_save_frame (m3-001):
- frame+136: RIP (8 bytes) — destination
- frame+144: RFLAGS (8 bytes) — destination
- frame+160: RSP (8 bytes) — destination

## TCB Layout

Same as sched_save_frame:
- TCB+120: RSP (source)
- TCB+128: RIP (source)
- TCB+136: RFLAGS (source)

## Sequence

1. Load RIP from TCB+128 into RAX
2. Store RAX into frame+136
3. Load RSP from TCB+120 into RAX
4. Store RAX into frame+160
5. Load RFLAGS from TCB+136 into RAX
6. Store RAX into frame+144
7. Return

## Verification

- Symbol present in kernel.elf: sched_restore_frame
- Function used by sched_preempt_to (m3-003)
- No functional change to boot flow (m4 wires calls)

## References

- src/kernel/core/sched/preempt.pdx
- src/kernel/core/sched/tcb.pdx (TCB offsets)
- design/audit/entries/r11-m3-001-sched-save-frame.md (symmetric pair)
- design/audit/entries/r11-m3-003-sched-preempt-to.md (composition)

---
**Audit:** R11-m3-002 bundle (July 2026)
