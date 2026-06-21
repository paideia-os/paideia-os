# Audit Entry: IPC Memory Ordering (P3-006)

**Date:** 2026-06-21  
**Status:** Phase-3 Checkpoint  
**Scope:** Catalogue head/tail acquire-release ordering requirements for SPSC channel operations

---

## Executive Summary

The phase-1 SPSC channel algorithm requires careful memory ordering to ensure that:
1. A message written by the producer is visible to the consumer before the head index is incremented.
2. A message is not overwritten until the consumer has read it (tail has advanced).

This document catalogues the acquire-release (acq-rel) ordering requirements, drawing on Lamport's SPSC queue and Vyukov's modern x86-64 SPSC queue design.

---

## Reference Works

- **Lamport (1974):** Lamport queues and the original proof of SPSC correctness.
- **Vyukov (2010):** "Lightweight multithreading in C++" — practical SPSC queue design with x86-64 ordering specifics.
- **C++11 Memory Model:** Sequential consistency for data-race-free programs.
- **x86-64 Manual (Section 8.2.6):** Memory ordering guarantees on Intel/AMD processors.

---

## The Algorithm

### Enqueue (producer)

```pseudo
enqueue(msg):
  if (head - tail) >= capacity:
    return FULL
  
  ring[head % capacity] = msg
  head++              // <-- ACQ-REL RELEASE
  return OK
```

### Dequeue (consumer)

```pseudo
dequeue():
  if head == tail:
    return EMPTY
  
  msg = ring[tail % capacity]   // <-- ACQ-REL ACQUIRE
  tail++
  return msg
```

---

## Memory Ordering Constraints

### Producer's Release: `head++`

**Constraint:** All stores to `ring[head % capacity]` must happen-before the store to `head`.

**Rationale:** If the consumer observes the new `head` value, it must see the message data in the ring.

**x86-64 Guarantees:**
- Stores are strongly ordered on x86-64.
- A simple `mov` to `head` in memory acts as a release without explicit barrier.
- However, the copy loop into `ring[head % capacity]` must complete before `head` is written.

**Implementation:**
```nasm
; Pseudocode
mov [rdi + chan_ring + r9*SLOT_SIZE], msg_data  ; write message
mfence                                          ; ensure visibility
mov [rdi + chan_head], eax                      ; store new head (release)
```

**Note:** On x86-64, the `mfence` may be optional if the message copy uses `rep movsb` (which is implicitly ordered). However, for clarity and forward compatibility (e.g., ARM64 in phase-2), an explicit barrier is conservative.

### Consumer's Acquire: `msg = ring[tail % capacity]`

**Constraint:** The load of `tail` must be followed by a load-acquire of the message data from the ring.

**Rationale:** If we read a stale `tail`, we might read a message that hasn't been written yet.

**x86-64 Guarantees:**
- Loads on x86-64 cannot be reordered against later loads (strong load ordering).
- A load from memory acts as an acquire on x86-64 without explicit barrier.
- The dequeue loop that copies from ring to output buffer must happen after the `tail` check.

**Implementation:**
```nasm
; Pseudocode
mov eax, [rdi + chan_tail]                      ; load tail (acquire implicitly)
cmp eax, [rdi + chan_head]                      ; check if empty
je .empty
mov msg_data, [rdi + chan_ring + rax*SLOT_SIZE] ; load message (acquire)
lfence                                          ; ensure visibility (conservative)
mov [rdi + chan_tail], eax+1                    ; increment tail
```

**Note:** Again, the `lfence` is conservative; x86-64's load ordering often makes it unnecessary.

---

## Phase-1 vs Phase-2 Differences

### Phase-1 (Current)
- Single producer, single consumer per channel.
- No concurrent enqueues or dequeues per channel.
- Concurrent access only via separate channels or global MPSC lock (see `mpsc_lock.pdx`).
- Simpler memory model: only inter-channel interference via the allocator.

### Phase-2 (Future)
- Wait-free SPSC algorithm (Vyukov).
- Potential for concurrent node producers (via merger trees).
- Stricter ordering requirements per session type.
- Effect-handler dispatch may impose additional ordering (TBD).

---

## Verification Checklist

For each enqueue/dequeue implementation:

- [ ] Producer writes message data to ring before incrementing head.
- [ ] Consumer acquires tail before reading message data from ring.
- [ ] Head and tail are only ever incremented (monotonic).
- [ ] No store is reordered past a head/tail write or load.
- [ ] Wraparound modulo arithmetic is correct (no off-by-one).
- [ ] Capability checks are performed before any ring access.
- [ ] Global MPSC lock is held around entire operation (if concurrent producer).

---

## Future Work

- [ ] x86-64 test harness: validate barrier placement with TSO/PSO test patterns.
- [ ] ARM64 equivalent: when phase-2 targets ARM, revisit acquire-release.
- [ ] Fencer tool: automatic verification of acq-rel ordering in NASM.

---

*End of audit entry.*
