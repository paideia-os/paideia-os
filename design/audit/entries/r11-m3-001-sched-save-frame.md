---
audit_id: r11-m3-001-sched-save-frame
issue: 393
file: src/kernel/core/sched/preempt.pdx
function: sched_save_frame
effects: [mem]
capabilities: [sched]
reviewed_by:
date: 2026-07-02
status: complete
---

# AUDIT R11-m3-001 — sched_save_frame: Save trap frame to TCB (COMPLETE)

## Issue

R11-m3-001 (#393): Implement sched_save_frame(tcb, frame) -> () to extract trap-frame state (RIP/RSP/RFLAGS) from the ISR handler's frame and store it into the corresponding TCB slots for later restoration during preemption.

## Implementation

Straightforward register-to-memory move sequence:

```pdx
pub let sched_save_frame : (u64, u64) -> () !{mem} @{sched} =
  fn (tcb: u64, frame: u64) -> unsafe {
    effects: { mem },
    capabilities: { sched },
    block: {
      mov rax, [rsi + 136]        // RIP from CPU frame (offset 136 in frame)
      mov [rdi + 128], rax        // RIP → TCB offset 128
      mov rax, [rsi + 160]        // RSP from CPU frame (offset 160 in frame)
      mov [rdi + 120], rax        // RSP → TCB offset 120
      mov rax, [rsi + 144]        // RFLAGS from CPU frame (offset 144 in frame)
      mov [rdi + 136], rax        // RFLAGS → TCB offset 136
      ret
    }
  }
```

## Trap Frame Layout

Per R11-m1 setup, the trap frame built by the ISR trampoline has:
- Offsets 0–15: errcode placeholder + vector
- Offsets 16–127: GPRs pushed by interrupt handler
- Offsets 136–175: CPU-pushed frame (40 bytes) containing RIP/CS/RFLAGS/RSP/SS

Within the CPU frame section (frame offsets 136–175):
- 136: RIP (8 bytes)
- 144: RFLAGS (8 bytes)
- 160: RSP (8 bytes)

## TCB Layout

Per tcb.pdx canonical layout:
- Offset 120: RSP
- Offset 128: RIP (new, per R11-m3-001 fixup)
- Offset 136: RFLAGS

## Sequence

1. Load RIP from frame+136 into RAX via base+displacement memory operand
2. Store RAX into TCB+128
3. Load RSP from frame+160 into RAX
4. Store RAX into TCB+120
5. Load RFLAGS from frame+144 into RAX
6. Store RAX into TCB+136
7. Return

## Verification

- Symbol present in kernel.elf: sched_save_frame
- Function used by sched_preempt_to (m3-003)
- No functional change to boot flow (m4 wires calls)

## References

- src/kernel/core/sched/preempt.pdx
- src/kernel/core/sched/tcb.pdx (TCB offsets)
- design/audit/entries/r11-m3-002-sched-restore-frame.md (symmetric)
- design/audit/entries/r11-m3-003-sched-preempt-to.md (composition)

---
**Audit:** R11-m3-001 bundle (July 2026)
