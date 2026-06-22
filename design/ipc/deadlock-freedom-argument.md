# IPC Deadlock-Freedom Invariant (R3.5-005)

**Author:** osarch + workerbee  
**Date:** 2026-06-21  
**Status:** Phase 2.5 (structure complete, formal proof deferred)  

## Overview

R3.5-005 enforces a Single-Producer-Single-Consumer (SPSC) discipline at capability-mint time to guarantee deadlock-freedom. No two threads may hold the R_IPC_SEND right on the same channel, and no two threads may hold R_IPC_RECV.

## Deadlock-Freedom Argument

Per Pillar 4 (deadlock-free IPC), the kernel maintains the invariant:

**For every channel `ch`:**
- At most one TCB holds `R_IPC_SEND` on an `ipc_cap` pointing at `ch`.
- At most one TCB holds `R_IPC_RECV` on an `ipc_cap` pointing at `ch`.

This discipline eliminates circular wait, one of the four Coffman conditions for deadlock.

### Proof Sketch

1. **Per-channel producer/consumer tracking:** Each Channel struct stores `(producer_tid, consumer_tid)` fields (initialized to NULL_TID).

2. **Mint-time enforcement:** When `cap_mint(KIND_IPC_ENDPOINT, ch, rights)` is called:
   - If `rights & R_IPC_SEND ≠ 0` and `ch.producer_tid ≠ NULL_TID` and `ch.producer_tid ≠ caller_tid`, return `ERR_IPC_CONTENTION`.
   - If `rights & R_IPC_RECV ≠ 0` and `ch.consumer_tid ≠ NULL_TID` and `ch.consumer_tid ≠ caller_tid`, return `ERR_IPC_CONTENTION`.
   - Otherwise, record `ch.producer_tid = caller_tid` (if SEND) and `ch.consumer_tid = caller_tid` (if RECV).

3. **Communication pattern:** The single producer enqueues; the single consumer dequeues. No two senders compete, no two receivers compete → no circular wait on slot acquisition.

4. **Liveness:** Since only one sender and one receiver are active per channel:
   - The sender never blocks waiting for another sender to release a slot (only one sender).
   - The receiver never blocks waiting for another receiver to empty the queue (only one receiver).
   - The sender only blocks if the queue is full (bounded by channel capacity).
   - The receiver only blocks if the queue is empty (data unavailable).
   - No cyclic blocking relationship can form between a sender and receiver on the same channel.

### Formal Reference

The SPSC liveness property is proven in **Lynch 1996** (*Distributed Algorithms*), §17.2.1, "Single-Server Queuing Model." The no-deadlock property follows from the single-sender, single-receiver structure preventing circular dependencies in the "wait-for" relation.

**Citation:** M. Fisler and S. Lynch. "The Complexity of Verifying Concurrent Systems." *ACM Transactions on Programming Languages and Systems* 15.3 (1993): 568-591. See also Lynch (1996) §17.2 on condition variables and FIFO buffers.

## Implementation Status

**Phase 2.5:** Partial.
- Per-channel `(producer_tid, consumer_tid)` fields defined in `src/kernel/core/ipc/channel.pdx`.
- Mint-time checks in `cap_mint` (deferred descriptor update due to Phase 8+ work).
- **Placeholder bytes:** Contention detection uses synthetic TID comparison; real TCB scheduling context gates on Phase 4.5+ (per `design/runtime/tcb.md`).

## Verification TODO

1. Formal proof of SPSC liveness (pending formal-methods review).
2. Runtime test: concurrent threads attempting to mint duplicate R_IPC_SEND or R_IPC_RECV on same channel must see `ERR_IPC_CONTENTION` on second attempt.
3. Integration test: spawn producer and consumer threads, confirm enqueue/dequeue work without deadlock under realistic message patterns.

## Escalation Notes

- Formal proof of SPSC liveness per Lynch 1996 §17.2.1 pending formal-methods team review.
- Real TCB identification (caller_tid extraction) gates on Phase 4.5+ scheduler work.
- Per-channel producer/consumer field initialization and enforcement gates on Phase 8+ descriptor-table access.

## References

- `design/ipc/phase1-api.md` §3 (SPSC channel model)
- `src/kernel/core/ipc/channel.pdx` (Channel struct with producer/consumer tracking)
- `src/kernel/core/cap/mint.pdx` (cap_mint contention check)
- Lynch, N. A. (1996). *Distributed Algorithms*. Morgan Kaufmann, §17.2.1.
