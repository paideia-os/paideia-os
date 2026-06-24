---
audit_id: r9-m3-001-runqueue
issue: 360
file: src/kernel/core/sched/runqueue.pdx
function: (module-level declarations)
effects: [mem]
capabilities: []
reviewed_by:
date: 2026-06-24
---

# AUDIT r9-m3-001 — Runqueue stub for cooperative scheduler

## Overview

R9-m3-001 establishes a stub runqueue declaration for the R9-narrow cooperative scheduler MVP. Per the softarch §"R9-narrow recommendation":
- Full scheduler context-switch and runqueue manipulation are deferred to R10 (Phase 7)
- R9-narrow uses a tick-counter-based approach with no actual runqueue operations
- Audit entry documents the deferral explicitly

This module declares a 2-slot TCB array (`runqueue`) in .bss and associated metadata, but performs no operations on it during R9.

## Justification

### Honest scope for R9-narrow MVP

The runqueue.pdx module declares:
```pdx
pub let mut runqueue : [u64; 2] = [0; 2]
pub let mut runqueue_len : u64 = 0
pub let mut runqueue_current : u64 = 0
```

These declarations reserve memory for future runqueue operations. No insertion, removal, or picking logic is implemented in R9. The array is allocated but unused during this phase.

### Deferred logic (R10)

Full runqueue operations deferred to R10 (Phase 7) include:
- `runqueue_enqueue(tcb)` — insert a TCB into the runqueue by priority
- `runqueue_dequeue(tcb)` — remove a TCB from the runqueue
- `runqueue_pick_next()` — select the next TCB to run

## Implementation details

### Storage layout

```pdx
pub let mut runqueue : [u64; 2] = [0; 2]          // 2-slot TCB array (expansion planned for R10)
pub let mut runqueue_len : u64 = 0                 // Number of valid entries (unused in R9)
pub let mut runqueue_current : u64 = 0             // Current runqueue index for round-robin (unused in R9)
```

The array is declared with init value `[0; 2]`, meaning both slots start at address 0. Real TCB pointers will be populated in R10.

## Invariants

1. **Array bounds:** runqueue has exactly 2 slots (expandable in R10 to 256+ slots)
2. **Unused in R9:** All fields remain unmodified during R9 execution
3. **Reserved for R10:** Declaration prevents symbol conflicts when R10 populates the queue

## Testing strategy

- Unit test (R10): enqueue/dequeue/pick_next operations
- Integration test (R10): multi-threaded yield behavior with runqueue
- R9 verification: ensure kernel boots without runqueue operations (✓ done: boot proceeds to halt loop)

## Future work (R10)

- Implement per-priority linked lists within the runqueue
- Implement enqueue/dequeue/pick_next with O(1) priority-bitmap lookups
- Integrate with `sched_yield()` (yield.pdx) to actually move TCBs through the queue
- Implement round-robin within priority level (runqueue_current index)
