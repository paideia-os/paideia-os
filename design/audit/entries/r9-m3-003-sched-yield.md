---
audit_id: r9-m3-003-sched-yield
issue: 362
file: src/kernel/core/sched/yield.pdx
function: sched_yield, sched_yield_to
effects: []
capabilities: []
reviewed_by:
date: 2026-06-24
---

# AUDIT r9-m3-003 — Yield stub for cooperative scheduler

## Overview

R9-m3-003 audits the yield stub that was introduced in R4.5-005. Per the softarch §"R9-narrow recommendation":
- Full yield-with-runqueue logic is deferred to R10 (Phase 7)
- R9-narrow uses voluntary CPU release without actual task switching
- Audit entry explicitly notes deferral to R10

The yield.pdx module remains unchanged from R4.5-005: `sched_yield` and `sched_yield_to` implement only the bookkeeping (state transitions) using local mirrors. No actual runqueue operations occur.

## Justification

### Honest scope for R9-narrow MVP

Per R4.5-005, the intended yield sequence:
1. Mark current_tcb as STATE_RUNNABLE
2. Enqueue current_tcb into the runqueue (by priority)
3. Call sched_pick_next to find the next runnable TCB
4. If next == current (self-yield), no switch; return YIELD_NOOP
5. Otherwise, switch to next via sched_switch; return YIELD_OK

For R9-narrow, steps 2–3 are skipped. The bookkeeping (state transitions) is modeled via local variables, but no actual runqueue or task-selection happens. The kernel remains in boot context throughout.

### Deferred logic (R10)

Full yield-with-runqueue logic deferred to R10 (Phase 7) includes:
- Real `runqueue_enqueue(tcb)` call to insert current_tcb
- Real `sched_pick_next()` call to select next
- Real `sched_switch(current, next)` call with register save/restore (per R9-m3-002)

## Implementation details

### `sched_yield()` bookkeeping-only

```pdx
let sched_yield : () -> u64 = fn () -> {
  current_state = STATE_RUNNABLE;        // Mark current as runnable
  let self_tcb : u64 = current_tcb;      // Snapshot self
  let chosen : u64 = next_tcb;           // Placeholder for pick_next result
  if chosen == self_tcb {
    current_state = STATE_RUNNING;       // Revert to running (no other TCB available)
    YIELD_NOOP
  } else {
    current_tcb = chosen;                // Update bookkeeping
    current_state = STATE_RUNNING;
    YIELD_OK
  }
}
```

No actual enqueue/pick/switch happens. The `next_tcb` variable is left at its initial value (0), simulating a no-op yield within the current TCB.

### `sched_yield_to(target)` direct-targeting

```pdx
let sched_yield_to : (u64) -> u64 = fn (target_tcb: u64) -> {
  if target_tcb == current_tcb {
    YIELD_NOOP
  } else {
    current_tcb = target_tcb;
    current_state = STATE_RUNNING;
    YIELD_OK
  }
}
```

Allows explicit hand-off to a named TCB (for future IPC or priority-inversion avoidance). Bookkeeping is updated but no register save/restore happens.

## Invariants

1. **No runqueue modification:** sched_yield does not insert/remove TCBs
2. **No task selection:** next-TCB is always self or a pre-specified target (no priority-based selection)
3. **No register save:** sched_switch_regs is not called with real arguments
4. **Bookkeeping consistency:** current_tcb and current_state mirrors are updated

## Testing strategy

- R9 verification: call sched_yield(); verify YIELD_NOOP returned (✓ done: no errors)
- R10 integration: implement real enqueue/pick/switch; verify YIELD_OK returns when next != self
- R10 correctness: verify runqueue state after yield (TCB moved from RUNNING to RUNNABLE and back)

## Future work (R10)

- Call real `runqueue_enqueue(current_tcb)` to insert into priority queue
- Call real `sched_pick_next()` to select next RUNNABLE TCB
- Call real `sched_switch(current_tcb, next)` with register save/restore
- Implement `sched_yield_to()` to support priority inheritance and IPC hand-off
- Handle edge case: yield with no other runnable TCB (busy-wait or idle task)
