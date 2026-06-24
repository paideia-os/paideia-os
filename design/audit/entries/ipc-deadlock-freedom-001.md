---
audit_id: ipc-deadlock-freedom-001
issue: 346
file: design/ipc/deadlock-freedom-argument.md
function: N/A (design document)
effects: []
capabilities: []
reviewed_by:
date: 2026-06-24
---

# AUDIT ipc-deadlock-freedom-001 — B6-005 Deadlock-freedom invariant and closure

## Justification

The B6-005 milestone documents the deadlock-freedom argument for the B6 IPC channel
as a reference model, ahead of Phase-2's full wait-free dataflow proof.

Key claims established in B6:
1. **Single-producer-single-consumer discipline**: Only one CPU writes head, only one writes tail
2. **Lock-free read path**: Dequeue loads both cursors and proceeds without synchronization
3. **Eventual progress**: Each enqueue/dequeue progresses the logical head/tail counters
4. **Bounded buffers prevent starvation**: Fixed 64-slot ring ensures bounded queue depth

Design references:
- design/ipc/p3-deadlock-freedom.md — formal argument structure (P3 era)
- design/ipc/deadlock-freedom-argument.md — B6 MVP argument

This is a **design assertion**, not runtime code, because:
- The claim depends on external discipline (kernel must ensure SPSC caller invariants)
- No lock or atomic is used; correctness relies on isolation and timing
- B6 MVP defers proof formalization to Phase-2+ (wait-free dataflow)
