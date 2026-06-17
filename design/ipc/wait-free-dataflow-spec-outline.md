# PaideiaOS — TLA+ Specification Outline for the Wait-Free Dataflow IPC

**Status:** Draft v0.1 — outline for the TLA+ spec, not the spec itself
**Date:** 2026-06-17
**Scope:** A structured outline of what `design/ipc/wait-free-dataflow.tla` (the TLA+ formal specification, planned per IPC-O1) will contain. Lays out the model, the operators, the properties to be checked, and the verification strategy. The actual `.tla` file is a phase-1 deliverable; this outline is the design that guides its construction.

**Hard inputs:**
- `wait-free-dataflow.md` — the algorithm specification.
- `proof.md` — the informal proof that the TLA+ spec will mechanize at the model-checking level.
- TLA+ Language Standard (Lamport, *Specifying Systems*, 2002).

---

## 0. Why TLA+

Per Q2 (verification-friendly but not mechanized) + the cross-decision tension #1 commitment: PaideiaOS does not pursue full mechanized theorem-proving (Coq/Isabelle level) but does commit to model-checked formal specs as the verification-friendly substrate.

TLA+ specifically:
- Strong industrial track record (Newcombe et al. 2015, AWS case studies).
- Both TLC (exhaustive small-model checker) and Apalache (symbolic model checker) are mature.
- Refinement reasoning is supported.
- Property notation (`[]<>P`, `<>[]P`) directly expresses the wait-freedom + deadlock-freedom claims.

---

## 1. Spec structure

```tla+
---- MODULE WaitFreeDataflow ----
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Capacity,           \* channel capacity N
    Producers,          \* set of producer IDs (singleton for SPSC; larger for testing composition)
    Consumers,          \* set of consumer IDs
    Messages,           \* set of possible message values
    Tags                \* set of LAM tag values

VARIABLES
    head,               \* head index per channel
    tail,               \* tail index per channel
    slots,              \* slot contents per channel
    slot_caps,          \* slot-caps held by each producer
    waiters,            \* set of consumers currently waiting per channel
    audit_log,          \* sequence of audit events (for trace inspection)
    state               \* per-thread program-state machine

vars == << head, tail, slots, slot_caps, waiters, audit_log, state >>

----------------------------------------------------------------
\* Type invariant
TypeInvariant ==
    /\ head \in [Channels -> Nat]
    /\ tail \in [Channels -> Nat]
    /\ \A c \in Channels : slots[c] \in [0..Capacity-1 -> Messages \cup {EMPTY}]
    /\ \A p \in Producers : slot_caps[p] \in 0..Capacity
    /\ waiters \in [Channels -> SUBSET Consumers]
    /\ ...

\* Algorithm actions
Enqueue(p, c, msg) ==
    /\ slot_caps[p] > 0                              \* preconditions
    /\ state[p] = "running"
    /\ LET pos == head[c] % Capacity
       IN  /\ slots' = [slots EXCEPT ![c][pos] = msg]
           /\ head' = [head EXCEPT ![c] = head[c] + 1]
           /\ slot_caps' = [slot_caps EXCEPT ![p] = slot_caps[p] - 1]
           /\ audit_log' = audit_log \o << [type |-> "enqueue", chan |-> c, msg |-> msg, by |-> p] >>
           /\ UNCHANGED << tail, waiters, state >>

Dequeue(c, q) ==
    \/ /\ head[c] = tail[c]                          \* empty case
       /\ \* return Empty, register WaitOn
       ...
    \/ /\ head[c] > tail[c]                          \* non-empty
       /\ LET pos == tail[c] % Capacity IN
          /\ tail' = [tail EXCEPT ![c] = tail[c] + 1]
          /\ \* mint a slot-cap on the return channel (recursive Enqueue)
          ...

\* Initial state
Init ==
    /\ head = [c \in Channels |-> 0]
    /\ tail = [c \in Channels |-> 0]
    /\ slots = [c \in Channels |-> [i \in 0..Capacity-1 |-> EMPTY]]
    /\ slot_caps = [p \in Producers |-> Capacity]
    /\ waiters = [c \in Channels |-> {}]
    /\ audit_log = << >>
    /\ state = [t \in Producers \cup Consumers |-> "running"]

\* Next-state relation
Next ==
    \/ \E p \in Producers, c \in Channels, msg \in Messages : Enqueue(p, c, msg)
    \/ \E c \in Channels, q \in Consumers : Dequeue(c, q)
    \/ Notify(...)
    \/ ScheduleWake(...)

\* Specification
Spec == Init /\ [][Next]_vars /\ WeakFairness(vars, Next)

================================================================
```

This is illustrative; the actual TLA+ will be substantially more detailed (proper handling of the linearization points, etc.).

---

## 2. Properties to check

### 2.1 Type invariant

`TypeInvariant` (as sketched above): state is always well-formed.

Checked by TLC at every state.

### 2.2 Wait-freedom

Wait-freedom is naturally an *operational* property (about step counts), which TLA+ does not directly capture without an additional counter. The formulation:

```tla+
EnqueueProgress ==
    \A p \in Producers, c \in Channels :
        WF_vars(\E msg \in Messages : Enqueue(p, c, msg))

DequeueProgress ==
    \A c \in Channels, q \in Consumers :
        WF_vars(Dequeue(c, q))
```

with weak fairness ensures that any continually-enabled Enqueue or Dequeue is eventually taken. The actual O(1) step-count claim is informal (per `proof.md` §2).

### 2.3 Linearizability

The linearizability witness pattern (per the standard literature; e.g., Doolan et al., or Burrows' technique). The idea:

```tla+
LinearizationOrder ==
    \* For every history, the set of linearization points forms a total order.
    \* Each operation's linearization point lies between its invocation and its response.
    \* The resulting sequential history satisfies the FIFO queue specification.
    ...
```

TLC can model-check this property over bounded executions.

### 2.4 Deadlock-freedom (acyclic)

For acyclic dataflow graphs:

```tla+
DeadlockFree ==
    [](\A t \in Threads : state[t] = "waiting" =>
        <>(state[t] = "running"))
```

That is: every waiting thread eventually runs again.

This property holds under the proof of Theorem 3 (per `proof.md` §5).

### 2.5 Slot-cap conservation

```tla+
SlotCapConservation ==
    \A c \in Channels :
        slot_caps[producer_of(c)] + (head[c] - tail[c]) = Capacity
```

Invariant.

### 2.6 No double-dequeue

```tla+
NoDoubleDequeue ==
    \A c \in Channels, msg \in Messages :
        \* Each message that is enqueued is dequeued exactly once.
        ...
```

Linearizability implies this.

### 2.7 Replay marker correctness

```tla+
ReplayMarkers ==
    \* The audit_log records every enqueue / dequeue.
    \* The order of audit records corresponds to the linearization order.
    \A msg : msg \in slots[*] => exists corresponding audit entry
```

---

## 3. Verification strategy

### 3.1 TLC (exhaustive small-model)

- Capacity N = 2, 4, 8.
- 1 producer, 1 consumer (basic SPSC).
- ~16 messages.
- All scheduling interleavings.

Properties checked: TypeInvariant, SlotCapConservation, NoDoubleDequeue, DeadlockFree (with explicit fairness).

### 3.2 Apalache (symbolic)

- Larger models.
- Symbolic execution to verify properties over unbounded message spaces.
- Bounded model checking with iteration depth ~10.

### 3.3 Property-based testing in PaideiaOS

The TLA+ spec is the oracle. The OCaml QuickCheck-style harness (per `02-development-environment.md` §9.4) generates random schedules; for each, checks that the PaideiaOS implementation's behavior matches the spec's behavior at every linearization point.

### 3.4 Beyond model checking

For results that exceed TLC's model-size limits:
- Manual proof sketch (per `proof.md`).
- Future TLAPS-based proof (TLA+ Proof System; phase 4+ if pursued).

---

## 4. Composition: merger and splitter nodes

The base SPSC spec is for one channel. Composition (per IPC-Q2: MPSC via merger node, MPMC via splitter + merger) is modeled separately:

```tla+
---- MODULE MergerNode ----
EXTENDS WaitFreeDataflow

\* A merger node consumes from N SPSC channels and produces to one.
\* Spec mirrors the merger node's deadlock-freedom + composition properties.

MergerSpec == ... 

================================================================
```

Similar for `SplitterNode`.

The composition properties to verify:
- Merger's outbound channel is FIFO with respect to one merger policy (round-robin, priority, etc.).
- Splitter's inbound channel is fan-out to N outbound channels per a routing policy.
- Composed graphs (producer → merger → consumer) preserve the FIFO and deadlock-freedom properties.

---

## 5. The cycle_cap case

For dataflow regions constructed with `cycle_cap`, deadlock-freedom is per-protocol. Each cyclic protocol must provide its own TLA+ spec (a small one, focused on the protocol's specific cycle).

The base spec models acyclic graphs; cyclic extensions are separate modules that import this one.

---

## 6. Refinement: from spec to implementation

The PaideiaOS implementation is a refinement of the TLA+ spec. The refinement is verified by:
- Trace inclusion: the implementation's behavior is a subset of the spec's allowed behaviors.
- Manual inspection of the algorithm code against the spec actions.

Future work could mechanize the refinement via TLAPS or another proof framework.

---

## 7. Files in the verification artifact set

When complete, the IPC verification artifact set is:

```
design/ipc/
├── wait-free-dataflow.md            ✅ (existing tier-1 doc)
├── proof.md                          ✅ (informal proof, just written)
├── wait-free-dataflow-spec-outline.md ✅ (this doc)
├── wait-free-dataflow.tla            (to write; the actual TLA+ spec)
├── wait-free-dataflow.cfg            (TLC configuration)
├── MergerNode.tla                    (composition spec)
├── SplitterNode.tla                  (composition spec)
└── property-tests/                   (the OCaml QuickCheck harness inputs)
```

---

## 8. Phase-1 deliverable

Per `milestones.md` §2 / IPC-O1:

- TLA+ spec authored.
- TLC small-model runs pass (8 messages, capacity 4, single channel).
- Apalache runs pass (capacity 8, bounded message count).
- The PaideiaOS implementation's PBT corpus matches spec behavior.

When all four are achieved, the wait-freedom + linearizability + deadlock-freedom claims have model-checking-grade evidence. The `paper-grade` proof (`proof.md`) supplements this with the human-readable argument.

---

## 9. Open issues

| ID | Issue |
|---|---|
| SPEC-O1 | Concrete TLA+ writing — phase-1 deliverable. |
| SPEC-O2 | The exact small-model parameters for TLC — capacity, message count, thread count. |
| SPEC-O3 | The Apalache configuration (symbolic transitions, depth, etc.). |
| SPEC-O4 | The merger/splitter spec — separate modules; phase-1 if pursued. |
| SPEC-O5 | The refinement-mapping from spec to implementation — formal definition. |
| SPEC-O6 | TLAPS proof of the high-level theorems (beyond model-checking) — phase 4+. |

---

*End of document.*
