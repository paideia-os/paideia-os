# PaideiaOS IPC Phase-1: Deadlock-Freedom Argument

**Date:** 2026-06-21  
**Status:** Phase-3 Checkpoint  
**Scope:** Brief formal argument that the SPSC channel design with separate capabilities and bounded buffers is deadlock-free.

---

## Claim

The phase-1 SPSC channel design is **deadlock-free** (no cyclic wait dependencies) under the following assumptions:
1. Each channel has exactly one producer and one consumer.
2. Producer and consumer capabilities are disjoint (no reversal).
3. The ring buffer is bounded (finite capacity).
4. Enqueue and dequeue are non-blocking (no nested IPC).

---

## Proof Sketch

### Assumption: Single Producer, Single Consumer

By design, each channel has:
- Exactly one producer endpoint (holds producer_cap).
- Exactly one consumer endpoint (holds consumer_cap).

No task holds both capabilities simultaneously (enforced by cap system).

### Assumption: Capability Disjointness

The capabilities producer_cap and consumer_cap are **distinct and unrelated**.

- A producer task cannot obtain or use consumer_cap (no cap cloning in phase-1).
- A consumer task cannot obtain or use producer_cap (no cap cloning in phase-1).

Thus, there is **no circular dependency** between producer and consumer.

### Claim: No Wait Cycles

**Enqueue (producer):**
```
producer_task calls ipc_enqueue(producer_cap, ...)
  → Checks producer_cap (succeeds; producer holds it)
  → Writes to ring buffer
  → Returns (ENQUEUE_OK or ENQUEUE_FULL)
  → No wait on consumer_cap; no syscall to consumer task
```

**Dequeue (consumer):**
```
consumer_task calls ipc_dequeue(consumer_cap, ...)
  → Checks consumer_cap (succeeds; consumer holds it)
  → Reads from ring buffer
  → Returns (DEQUEUE_OK_BASE + bytes or DEQUEUE_EMPTY)
  → No wait on producer_cap; no syscall to producer task
```

### Key Observation: Bounded Buffer Prevents Indefinite Wait

If the ring buffer is full, `ipc_enqueue` returns `ENQUEUE_FULL` (does not wait).

If the ring buffer is empty, `ipc_dequeue` returns `DEQUEUE_EMPTY` (does not wait).

**No task ever blocks waiting for the other task.** Thus, the producer and consumer are **independent**—neither can cause the other to deadlock.

### Assumption: Non-Blocking Semantics

Neither producer nor consumer is allowed to call a nested IPC during an enqueue or dequeue operation.

If this assumption is violated (e.g., enqueue handler calls a second IPC on a different channel), deadlock could occur if those channels form a cycle. However, phase-1 prohibits nested IPC (syscalls are non-reentrant).

---

## Comparison to Other Approaches

### Unbounded Buffers (Risk)
If the ring buffer were unbounded, enqueue could block (or dynamically allocate), creating a dependency between producer and consumer. **We avoid this by bounding capacity to 256 slots and returning ENQUEUE_FULL.**

### Bidirectional Channels (Risk)
If producer and consumer held overlapping capabilities (e.g., both could enqueue and dequeue), a circular dependency could form. **We avoid this by enforcing separate caps.**

### Nested IPC (Risk)
If enqueue/dequeue could trigger nested syscalls, a cycle could form across multiple channels. **Phase-1 prohibits this.**

---

## Conclusion

The phase-1 SPSC channel design is deadlock-free by construction:
1. **No circular capability dependencies** (disjoint caps).
2. **No indefinite waits** (bounded buffer, non-blocking returns).
3. **No re-entrancy** (phase-1 syscalls are atomic).

This property holds for any number of channels and tasks, provided:
- Each channel has exactly one producer and one consumer.
- No capability is shared or cloned.
- No nested IPC occurs during channel operations.

For phase-2, when wait-free MPSC and async notification are added, the deadlock-freedom argument will need to be revisited (dependency on scheduler properties and IPC notification semantics).

---

*End of document.*
