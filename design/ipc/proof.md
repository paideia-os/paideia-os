# PaideiaOS — Wait-Free Dataflow IPC: Paper-Grade Informal Proof

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** The paper-grade informal proof of wait-freedom, linearizability, and deadlock-freedom for the PaideiaOS novel wait-free dataflow IPC primitive (Q1). Discharges the cross-decision tension #1 from `01-foundational-decisions.md` §3 — the verification-friendly posture's commitment to a rigorous informal proof when mechanized verification was declined (Q2). Companion to `wait-free-dataflow.md` and the (future) TLA+ specification.

**Hard inputs:**
- `wait-free-dataflow.md` §4 (the SPSC algorithm), §8 (slot-cap economy), §16 (deadlock-freedom proof sketch).
- `01-foundational-decisions.md` §3 cross-decision tension #1.
- Owens et al., *x86-TSO*, 2009 — memory model.
- Herlihy, *Wait-Free Synchronization*, 1991.

---

## 0. Theorem statements

### Theorem 1 (Wait-Freedom of SPSC operations)

For every legal execution of the PaideiaOS wait-free SPSC primitive, every `Enqueue(channel, slot_cap, message)` operation and every `Dequeue(channel)` operation completes in O(1) of its own program steps, regardless of the state and progress of any other thread.

### Theorem 2 (Linearizability)

The SPSC primitive is linearizable: every concurrent history of operations has a sequential reordering that is consistent with each thread's program order, satisfies the sequential specification, and respects the real-time order of non-overlapping operations.

### Theorem 3 (Deadlock-Freedom in acyclic dataflow graphs)

Given a dataflow graph constructed from this primitive's SPSC channels where:
- the graph is acyclic, and
- the slot-cap economy is preserved, and
- every consumer eventually dequeues from each of its inbound channels,

then no process is ever blocked indefinitely waiting on an IPC operation.

### Theorem 4 (Capability conservation)

For each channel of capacity N, the total number of outstanding `slot_cap`s plus the number of messages currently in transit equals N at all times.

---

## 1. Notation and model

### 1.1 Channel state

A channel is an abstract data type with state `(head, tail, slots, slot_caps_held, capacity)`:
- `head : N` — monotonically increasing index, written only by the producer.
- `tail : N` — monotonically increasing index, written only by the consumer.
- `slots : N → Slot` — a function from index modulo capacity to slot content.
- `slot_caps_held : N` — count of slot-caps the producer currently holds.
- `capacity : N` — fixed channel capacity.

Invariant: `slot_caps_held + (head - tail) ≤ capacity` always holds (this is Theorem 4).

### 1.2 Memory model

x86-TSO per Owens et al. 2009. The relevant properties:
- Aligned 64-bit loads and stores are atomic.
- Stores by a single thread appear in program order to other threads (subject to local store-buffering).
- Loads by a single thread appear to access memory in program order.
- A store followed by an `mfence` is globally visible before subsequent loads on other threads.

The SPSC algorithm relies on these properties to ensure:
- The producer's slot-body store is globally visible before the head-index store.
- The consumer's tail-index store is globally visible before the next slot-cap return.

### 1.3 Operation steps

`Enqueue(channel, slot_cap, message)`:
1. Consume `slot_cap` (substructural; statically checked).
2. Atomic load `head` (call it `h`).
3. Compute `pos = h mod capacity`.
4. Write `slots[pos] = message` (this is a sequence of stores depending on message size).
5. (No fence needed on x86-TSO for the next step.)
6. Atomic store `head = h + 1`.
7. (Optional) wake notification.
8. Return.

`Dequeue(channel)`:
1. Atomic load `tail` (call it `t`).
2. Atomic load `head` (call it `h`).
3. If `t == h`, return `Empty`.
4. Compute `pos = t mod capacity`.
5. Read `slots[pos] = message`.
6. Atomic store `tail = t + 1`.
7. Mint a fresh `slot_cap` and enqueue on the return channel (recursive use of the primitive).
8. Return `Some(message)`.

---

## 2. Proof of Theorem 1 (Wait-Freedom)

**Statement.** Every `Enqueue` and `Dequeue` operation completes in O(1) of its own steps regardless of others' progress.

**Proof.**

*Enqueue.* The Enqueue body (§1.3 steps 1–7) is a bounded sequence of operations:
- Step 1: O(1) static check at compile time (no runtime cost).
- Step 2: one atomic load.
- Step 3: one arithmetic operation.
- Step 4: a bounded number of stores (depending on message size, which is fixed by the channel's schema).
- Step 5: zero (no fence on x86-TSO).
- Step 6: one atomic store.
- Step 7: zero or one IPI (the notification path, bounded).

The total step count is fixed by the schema, not by any other thread's behavior. The producer never spins, never waits, never retries. Each step is a single hardware operation (load, store, branch, or arithmetic), and each completes in a bounded number of cycles on the underlying CPU.

Therefore Enqueue completes in O(1) of its own program steps.

*Dequeue.* By symmetric argument: §1.3 steps 1–8 are each bounded; no step depends on the producer's progress. Step 7 (mint a fresh slot_cap and enqueue on the return channel) is a recursive Enqueue on a different SPSC channel; by the recursive argument, that Enqueue is also wait-free.

The recursion is well-founded because the return channel has its own kernel-guaranteed capacity (per §8.6 of the IPC doc), so its Enqueue never blocks.

**QED.**

---

## 3. Proof of Theorem 2 (Linearizability)

**Statement.** The SPSC primitive is linearizable.

**Proof.**

We exhibit a linearization point for each operation:
- **Enqueue's linearization point** is the atomic store of `head = h + 1` (step 6 of §1.3).
- **Dequeue's linearization point** (when it returns `Some(message)`) is the atomic store of `tail = t + 1` (step 6).
- **Dequeue's linearization point** (when it returns `Empty`) is the atomic load of `head` (step 2).

We must show:
1. Each operation's linearization point lies between its invocation and its response (it does, by construction).
2. The linearization order satisfies the sequential SPSC specification (a queue: FIFO order between Enqueue and Dequeue).

For (2):

**Claim.** For any two operations Op₁ and Op₂ on the channel, if Op₁'s linearization point precedes Op₂'s, then the SPSC behaves as if Op₁ logically happened first.

*Case 1: Two Enqueues from the same producer.* This case does not arise — single-producer means at most one Enqueue is in flight per channel at any time. The producer's program order linearizes the Enqueues.

*Case 2: Two Dequeues from the same consumer.* Same — single-consumer.

*Case 3: An Enqueue and a Dequeue, Enqueue first (linearization-order).* The Enqueue's store to `head` is globally visible before the Dequeue's load of `head` (x86-TSO + the linearization order). Therefore the Dequeue's `h` value reflects the Enqueue (`h > t`), and the Dequeue can proceed (returning `Some(message)` for the just-enqueued message, given the FIFO discipline).

*Case 4: An Enqueue and a Dequeue, Dequeue first (linearization-order).* The Dequeue's `head` load happens before the Enqueue's `head` store is globally visible. The Dequeue sees `t == h`, returns `Empty`. The Enqueue then proceeds and stores the new head. The next Dequeue will see `h > t` and return the message.

In all cases, the linearization order respects FIFO and the SPSC specification. **QED.**

---

## 4. Proof of Theorem 4 (Capability conservation)

**Statement.** For each channel of capacity N: `slot_caps_held + (head - tail) = N` invariantly.

**Proof.**

*Initial state.* At channel construction, the kernel mints N slot_caps to the producer and sets `head = tail = 0`. So `slot_caps_held = N` and `head - tail = 0`, summing to N.

*Inductive step (after Enqueue).* Enqueue consumes one slot_cap (so `slot_caps_held` decreases by 1) and increments `head` (so `head - tail` increases by 1). The invariant is preserved.

*Inductive step (after Dequeue, returning Some).* Dequeue increments `tail` (so `head - tail` decreases by 1) and mints one slot_cap (so `slot_caps_held` increases by 1). The invariant is preserved.

*Inductive step (after Dequeue, returning Empty).* Empty Dequeue does not modify any state. The invariant is preserved.

By induction, the invariant holds at all times. **QED.**

---

## 5. Proof of Theorem 3 (Deadlock-Freedom in acyclic graphs)

**Statement.** Given the dataflow graph is acyclic, the slot-cap economy is preserved (Theorem 4), and every consumer eventually dequeues, no process is blocked indefinitely.

**Proof.**

A process is blocked when it cannot make progress on its next operation. The two blocking conditions are:
- A producer has no slot_caps available and is waiting for the return channel.
- A consumer is waiting for input.

We argue that each is finite under the assumptions.

### 5.1 Lemma: A consumer's wait is finite.

A consumer that finds its inbound channel empty registers `WaitOn(channel)` (per the scheduler integration, §7 of the IPC doc). The wait is broken by the next Enqueue.

The Enqueue happens because:
- The producer holds a slot_cap (by Theorem 4: `slot_caps_held > 0` is equivalent to the producer having capacity).
- The producer has a message to send (assumption: the protocol drives the producer to send).
- Enqueue is wait-free (Theorem 1) and thus completes once invoked.

Therefore the consumer's wait ends in finite time.

### 5.2 Lemma: A producer's wait for slot-caps is finite.

A producer that holds no slot_caps registers `WaitOn(slot_return_channel)`. The wait is broken by the next slot-cap mint on the return channel.

A slot-cap is minted when the consumer dequeues a message. The consumer dequeues because:
- The consumer's inbound channel has a message (by Theorem 4 + the producer's prior Enqueue).
- The protocol drives the consumer to dequeue (assumption).
- Dequeue is wait-free (Theorem 1).

Therefore the producer's wait ends in finite time.

### 5.3 Acyclicity and well-foundedness

The argument so far establishes: a consumer's wait depends on a producer's progress; a producer's wait depends on a consumer's progress.

In a general graph, this dependency could form a cycle:
- Process A waiting for a message from B.
- B is waiting for a slot-cap from A.

The acyclicity hypothesis excludes this: if there is an edge A → B (A produces to B's channel), there is no edge B → A. Therefore there is no cyclic dependency between A's progress and B's.

In the partial order induced by the dataflow graph:
- Process X depends on processes that produce to X's inbound channels (call them "upstream").
- Process X's wait can only be broken by upstream progress.

Since the graph is acyclic, the "upstream" relation is a strict partial order with a least element: a process with no inbound dependencies (a *source* process). Source processes are not blocked (they have no inbound channels to wait on, and their slot-cap supply is provided by the consumer at the destination of their outbound channels — a finite chain of dependencies all the way to leaves).

By induction on the depth of the acyclic graph:
- Base case: source processes are not blocked indefinitely.
- Inductive step: process X (at depth d) is unblocked when its upstream processes (at depth < d) make progress. By induction, upstream processes are not blocked indefinitely. Therefore X is not blocked indefinitely.

**QED.**

### 5.4 Discussion: cyclic regions

The proof assumed acyclicity. For dataflow regions constructed with `cycle_cap` (per IPC-Q1), the proof above does not apply. Each cyclic protocol must establish its own deadlock-freedom (e.g., by argument over a per-protocol resource ordering, or by a per-protocol TLA+ model check).

This is the rationale behind the IPC primitive's design choice: structural acyclicity gives deadlock-freedom for free; explicit `cycle_cap` makes the cyclic case visible and audit-traceable.

### 5.5 Discussion: the "eventually dequeues" assumption

Theorem 3 assumes every consumer eventually dequeues. This is the liveness assumption that distinguishes the theorem from a pure safety property. In practice:
- The supervisor's policy enforces it by refusing to register a server whose main loop does not include a Dequeue on every inbound channel.
- The "liveness checker" (planned per IPC-O11) is a static analysis that verifies the assumption per server.

A consumer that *violates* the assumption (deliberately stops dequeuing) breaks the upstream's flow. The kernel does not prevent this — it is a per-server obligation — but the supervisor's audit log surfaces such cases.

---

## 6. Discussion: relationship to seL4-MCS and prior wait-free literature

### 6.1 Comparison to seL4-MCS

seL4-MCS (Lyons et al., EuroSys 2018) uses synchronous rendezvous IPC with scheduling-context donation. PaideiaOS rejected this in favor of the asynchronous wait-free dataflow primitive (Q1). The PaideiaOS scheduler retains SC donation (per `scheduler.md` §7) but applies it to *session-typed* sync RPC built atop the async primitive, not to the primitive itself.

The seL4-MCS deadlock-freedom argument relies on the rendezvous semantics; ours relies on the acyclic-graph + capability-conservation invariant.

### 6.2 Comparison to wait-free queue literature

Yang and Mellor-Crummey (PPoPP 2016) gave a wait-free MPMC queue using fetch-and-add and helping. Our SPSC primitive does not require fetch-and-add nor helping; the single-producer / single-consumer restriction makes the algorithm dramatically simpler. The merger/splitter composition (per IPC-Q2) recovers MPSC/MPMC via dataflow-graph topology rather than algorithmic complexity.

### 6.3 Comparison to Lamport's classical SPSC

Lamport (TOPLAS 1983) gave the canonical SPSC queue. Our primitive is essentially Lamport's algorithm with PaideiaOS-specific extensions:
- LAM-tagged capability transport (Q7).
- Replay markers for D13.
- AVX-512-wide slot emission.
- Effect-handler integration (Q-A3).

The core wait-freedom argument is Lamport's; the additions are orthogonal.

---

## 7. Future formalization

The proof is *informal*. The corresponding *formal* artifact is a TLA+ specification (`design/ipc/wait-free-dataflow.tla`, planned per IPC-O1):
- Model the channel state, the producer's program, the consumer's program.
- State each theorem as a TLA+ property (`Wait-Free`, `Linearizable`, `Deadlock-Free`).
- Use TLC for exhaustive small-model checks (capacity ≤ 8, single channel) and Apalache for symbolic checks.

The mechanized proof in TLA+ corroborates this informal proof at the model-checking level (not full theorem proving — that was Q2's declined ambition). Discrepancies between the informal proof and the spec are caught at the spec-development stage.

---

## 8. Conclusion

The PaideiaOS wait-free dataflow IPC primitive provides:
- **Wait-freedom**: O(1) per operation, established by direct argument on the algorithm's step count.
- **Linearizability**: each operation has a well-defined linearization point that respects FIFO.
- **Capability conservation**: a structural invariant maintained by the slot-cap economy.
- **Deadlock-freedom in acyclic graphs**: established by topological induction over the dataflow graph.

These properties together discharge the Q1/Q2 obligation: the project committed to a novel wait-free dataflow primitive whose correctness would be defended by a paper-grade informal proof (in lieu of mechanized verification). This document is that proof.

---

## 9. References

- Owens, S., Sarkar, S., Sewell, P. *A Better x86 Memory Model: x86-TSO*. TPHOLs 2009.
- Herlihy, M. *Wait-Free Synchronization*. TOPLAS 13(1), 1991.
- Lamport, L. *Specifying Concurrent Program Modules*. TOPLAS 5(2), 1983.
- Yang, C., Mellor-Crummey, J. *A Wait-free Queue as Fast as Fetch-and-Add*. PPoPP 2016.
- Lyons, A. et al. *Scheduling-Context Capabilities*. EuroSys 2018.
- Klein, G. et al. *seL4: Formal Verification of an OS Kernel*. SOSP 2009.

---

*End of document.*
