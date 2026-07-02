---
audit_id: r11-m3-003-sched-preempt-to
issue: 395
file: src/kernel/core/sched/preempt.pdx
function: sched_preempt_to
effects: [mem]
capabilities: [sched]
reviewed_by:
date: 2026-07-02
status: complete
---

# AUDIT R11-m3-003 — sched_preempt_to: Preemption composition (COMPLETE)

## Issue

R11-m3-003 (#395): Implement sched_preempt_to(next_tcb, frame) -> () as the atomic preemption composition: save the current TCB's state into the trap frame, restore the next TCB's state from the trap frame, and update the global _current_tcb pointer. This function is called from handle_timer when _preempt_needed is set.

## Implementation

Composition using sched_save_frame and sched_restore_frame:

```pdx
pub let sched_preempt_to : (u64, u64) -> () !{mem} @{sched} =
  fn (next_tcb: u64, frame: u64) -> unsafe {
    effects: { mem },
    capabilities: { sched },
    block: {
      // Load current TCB from Runqueue._current_tcb
      lea rax, [rip + Runqueue._current_tcb]
      mov rax, [rax]               // RAX = current TCB pointer

      // Preserve arguments across function calls
      push rdi                      // preserve next_tcb
      push rsi                      // preserve frame

      // Save current context: sched_save_frame(current, frame)
      mov rdi, rax                  // RDI = current TCB
      // RSI already = frame
      call sched_save_frame

      // Restore arguments
      pop rsi                       // RSI = frame
      pop rdi                       // RDI = next_tcb

      // Restore next context: sched_restore_frame(next_tcb, frame)
      call sched_restore_frame

      // Update _current_tcb = next_tcb
      lea rax, [rip + Runqueue._current_tcb]
      mov [rax], rdi                // RDI = next_tcb

      ret
    }
  }
```

## Function Composition

1. **Load current TCB:** `lea rax, [rip + Runqueue._current_tcb]; mov rax, [rax]`
   - Fetches the global pointer to the currently-running TCB from Runqueue._current_tcb (RIP-relative addressing, per position-independent code)
2. **Preserve arguments:** `push rdi; push rsi` (next_tcb and frame pointers)
3. **Save current:** `mov rdi, rax; call sched_save_frame`
   - Calls sched_save_frame(current_tcb, frame) to extract current state into TCB
4. **Restore arguments:** `pop rsi; pop rdi`
5. **Restore next:** `call sched_restore_frame`
   - Calls sched_restore_frame(next_tcb, frame) to install next state into frame
6. **Update global:** `lea rax, [rip + Runqueue._current_tcb]; mov [rax], rdi`
   - Writes next_tcb into the global _current_tcb pointer
7. **Return:** `ret` (iretq from interrupt will use the modified frame)

## Call Order and Atomicity

From the interrupt handler's perspective (handle_timer), this entire sequence runs with interrupts disabled:
- Save current TCB's RIP/RSP/RFLAGS into its TCB (m3-001)
- Restore next TCB's RIP/RSP/RFLAGS into the trap frame (m3-002)
- Update _current_tcb globally
- Return to caller; caller issues iretq using the modified trap frame

This ensures that the CPU returns to the correct task with the correct stack and RIP.

## Push/Pop Rationale

The push/pop sequence for argument preservation is valid in an unsafe block on paideia-as 0.11.0:
- RSP is well-defined within the interrupt handler's stack context (kernel stack)
- push/pop are single-instruction operations with no side effects on RFLAGS from the interrupt frame's perspective (the frame is not yet active)
- Alternatives (scratch registers) would require more careful allocation; push/pop is clearer

## Verification

- Symbol present in kernel.elf: sched_preempt_to
- Function called from handle_timer (m4 wires the call)
- Depends on: sched_save_frame (m3-001), sched_restore_frame (m3-002)
- No functional change to boot flow (m4 wires calls)

## References

- src/kernel/core/sched/preempt.pdx
- src/kernel/core/sched/runqueue.pdx (Runqueue._current_tcb)
- design/audit/entries/r11-m3-001-sched-save-frame.md (composition component)
- design/audit/entries/r11-m3-002-sched-restore-frame.md (composition component)

---
**Audit:** R11-m3-003 bundle (July 2026)
