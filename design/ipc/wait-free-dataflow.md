# PaideiaOS — Wait-Free Dataflow IPC Primitive

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Architectural specification of the wait-free dataflow IPC primitive mandated by Q1 of `01-foundational-decisions.md`. Covers topology, channel discipline, the SPSC algorithm, message representation, capability transport, session typing, scheduler integration, backpressure, fault model, observability, paideia-as implementation strategy, and the Q1/Q2 verification obligation.

**Hard inputs (do not relitigate):**
- `design/00-feature-inventory.md` — feature inventory (C7 is this document's subject).
- `design/01-foundational-decisions.md` — Q1, Q2, Q13, Q14, Q15 are directly load-bearing.
- `design/02-development-environment.md` — TLA+/Apalache pinned (§7.3); property-based testing harness in OCaml (§9.4); `-icount rr` and `rr` available as postmortem (§13.4).
- `design/toolchain/custom-assembler.md` — substructural lattice (Q-A2), algebraic effects with handlers (Q-A3), ML-style functors (Q-A7), custom calling convention with R12/R13 capability band and R14/R15 effect band (§8), `unsafe`-block escape with mandatory effect/capability annotation (Q-A8).

---

## 0. Decisions summary

### 0.1 Inherited (already binding)

| Source | Constraint |
|---|---|
| Q1 | The IPC primitive is a novel wait-free dataflow primitive (rejected: seL4-MCS sync-only; Zircon hybrid). |
| Q2 | Verification-friendly but not mechanized — the project commits to a *paper-grade* informal deadlock-freedom proof + property-based testing. |
| Q13 | The semantic shell uses this primitive for in-process by-reference pipelines; serialization happens only at host/trust boundaries. |
| Q14 | Hard restart default; opt-in live state-handoff. |
| Q-A2 | Capabilities are linear (Walker's substructural lattice). |
| Q-A3 | Effects are algebraic with handlers; effect environment lives in R15. |
| Q-A7 | Module system is ML-style functors with applicative semantics. |
| `02-development-environment.md` §6.1 (Cross-tension #1) | Paper-grade informal proof + property-based testing must compensate for the absence of mechanized verification of the deadlock-freedom claim. |

### 0.2 New decisions in this document

| # | Question | Decision |
|---|---|---|
| IPC-Q1 | Topology constraint | DAG by default; cycles permitted only by holding a `cycle_cap` capability; cycle introduction is logged into the E19 audit channel. |
| IPC-Q2 | Channel primitive discipline | SPSC as the primitive; MPSC via a `merger_cap`-holding merger node; MPMC via a `splitter_cap` + merger composition. |
| IPC-Q3 | SPSC algorithm | Custom wait-free SPSC tailored for PaideiaOS — cache-line slot discipline, integrated LAM-tagged capability transport, integrated replay markers, AVX-512-wide enqueue path, integrated effect-handler hook points. Specification-first in TLA+; implementation derived. |
| IPC-Q4 | Message representation | Hybrid: each slot is one 64-byte cache line; payloads ≤ 56 bytes (after 8-byte header) travel inline; larger payloads travel as a linear capability to a memory region. |
| IPC-Q5 | Channel typing & capability flow | Channels are functor applications `Channel(Schema)` where `Schema` is a session-type-bearing signature; producer and consumer derive from the same functor instance. |
| IPC-Q6 | Synchronous RPC | Session-typed channels in the Honda/Yoshida lineage, adapted for asynchronous wait-free transport. The session type expresses the protocol structure (request/reply, branching, recursion, multiparty). |
| IPC-Q7 | Scheduler integration | Hybrid: notification-driven wake for async (`WaitOn(channel)`, IPI for cross-core); scheduling-context donation across sync session steps (seL4-MCS lineage). |
| IPC-Q8 | Backpressure | Capability-allocated slot economy — producer holds N linear `slot_cap`s; enqueue consumes one; dequeue mints one back over a paired return path; producer cannot enqueue without proof of available space. |
| IPC-Q9 | Fault model | Default: channel dies when either endpoint's process dies; pending messages and outstanding slot-caps reclaimed by kernel; surviving endpoint sees `ChannelDead`. Opt-in: a `handoff_cap`-holding supervisor may bind a replacement endpoint within a bounded window per Q14. |
| IPC-Q10 | Observability | Every IPC operation is an algebraic-effect operation (per Q-A3). Default handler emits structured replay markers (D13). Test handlers record traces in TLA+-compatible format. Property-based test handlers inject faults (drops, permitted reorderings, slow-consumer simulation). |

### 0.3 The two meta-obligations to acknowledge

1. **Paper-grade deadlock-freedom proof.** Q2 declined mechanized verification but the cross-decision tension list in `01-foundational-decisions.md` §3 mandates a *paper-grade informal proof* as a public artifact. This document carries the proof sketch in §16; the full proof lives at `design/ipc/wait-free-dataflow.tla` (the TLA+ spec) and `design/ipc/proof.md` (to write). The proof is the public defense of the IPC primitive's correctness claim.

2. **Scope realism.** The Q-A1..Q-A10 assembler choices and the IPC-Q1..IPC-Q10 here are mutually reinforcing — session types build on functors, slot-cap economies build on the substructural lattice, replay markers build on algebraic effects. This makes the project's correctness story coherent but also tightly couples the schedules. Phase-1 IPC requires phase-1 of the substructural lattice, functors, and algebraic effects from the assembler. See §17 for milestone interlock.

---

## 1. Architectural overview

```
                                   ┌────────────────────────────────┐
                                   │   IPC dataflow graph (DAG by   │
                                   │   default; cycles via cycle_cap)│
                                   └─────────────────┬──────────────┘
                                                     │
                  ┌──────────────────────────────────┼──────────────────────────────────┐
                  │                                  │                                  │
                  ▼                                  ▼                                  ▼
          ┌──────────────┐                   ┌──────────────┐                   ┌──────────────┐
          │  Producer    │ ── SPSC ch ─►     │  Consumer    │ ── SPSC ch ─►     │  Consumer    │
          │  (server A)  │ ◄ slot-cap return │  (server B)  │ ◄ slot-cap return │  (server C)  │
          └──────────────┘                   └──────────────┘                   └──────────────┘
                  │                                  │
                  │ holds N linear slot_caps          │ session-type peer; functor twin
                  │ session-type sender side          │ Channel(Schema).Recv
                  │ Channel(Schema).Send              │
                  │                                  │
                  ▼                                  ▼
          ┌────────────────────────────────────────────────────────────────────────────────┐
          │                          Per-CPU effect environment (R15)                      │
          │   ┌────────────────────┐  ┌────────────────────┐  ┌────────────────────┐      │
          │   │ Ipc effect handler │  │ Trace handler      │  │ Sched handler      │      │
          │   │  - enqueue         │  │  - on_enqueue      │  │  - notify          │      │
          │   │  - dequeue         │  │  - on_dequeue      │  │  - donate_sc       │      │
          │   │  - session_step    │  │  - on_session_step │  │  - wake            │      │
          │   │  - slot_consume    │  │  - on_slot_consume │  │                    │      │
          │   │  - slot_return     │  │  - on_handoff      │  │                    │      │
          │   └────────────────────┘  └────────────────────┘  └────────────────────┘      │
          └────────────────────────────────────────────────────────────────────────────────┘
                                                     │
                                                     ▼
                                ┌─────────────────────────────────────┐
                                │   Kernel IPC subsystem (src/kernel/  │
                                │   ipc/) — wait-free SPSC algorithm   │
                                │   + slot-cap mint/burn + notification│
                                │   + topology check + handoff support │
                                └─────────────────────────────────────┘
                                                     │
                                                     ▼
                                ┌─────────────────────────────────────┐
                                │   Per-CPU trace ring (D13) — replay  │
                                │   markers emitted by default handler │
                                └─────────────────────────────────────┘
```

---

## 2. Topology and graph types (IPC-Q1)

### 2.1 The dataflow graph

A PaideiaOS system at any instant has a **dataflow graph** whose nodes are processes (kernel, root task, userspace servers, applications) and whose edges are SPSC channels. The graph is *typed*: each edge carries a functor-application type (`Channel(Schema)`); each node carries a set of capability typings for its endpoints.

### 2.2 Acyclicity by default

The kernel's topology-check pass maintains a partial order over nodes: if there is an edge from A to B, then A < B. Constructing a channel from B to A when B's partial-order rank is greater would create a cycle; the kernel rejects the construction with `CycleAttempt`.

### 2.3 The `cycle_cap`

A process holding `cycle_cap` may construct a channel that would create a cycle. The construction succeeds; the cycle is recorded in `target/audit/cycles.json` and pushed to the E19 audit log. The supervisor (E10) grants `cycle_cap` to specific servers based on policy; the granted capability is itself linear and not transferable.

### 2.4 Verified-acyclic vs. permitted-cyclic regions

The graph is partitioned into:

- **Acyclic regions** — the kernel's topology check guarantees the partial order; deadlock-freedom is structural.
- **Cyclic regions** — connected components containing edges constructed with `cycle_cap`; the protocols in these regions carry an obligation to prove deadlock-freedom of their own protocols (per-protocol obligation, with the same TLA+ template as the primitive itself).

The audit log records exactly which servers participate in cyclic regions, so review can target the proof obligation.

### 2.5 Session-type duality (forward reference to §6)

For each channel, the producer's session type and the consumer's session type must be *dual*: every `↑Send T` on one side corresponds to a `↓Recv T` on the other. The functor application `Channel(S)` produces a `(S.Send, S.Recv)` pair where `S.Recv = dual(S.Send)`. Duality is checked at functor application time, before the channel is constructed.

---

## 3. Channel discipline (IPC-Q2): SPSC primitive

### 3.1 The primitive

A primitive channel has exactly two endpoints: a single producer with capability `Send(Schema)` and a single consumer with capability `Recv(Schema)`. Both are linear; neither may be duplicated.

### 3.2 MPSC via merger nodes

A multi-producer pattern is constructed as N SPSC channels feeding a *merger node* (a process holding `merger_cap`) that drains them into a single SPSC channel to the ultimate consumer. The merger's strategy (round-robin, priority, capability-derived) is its own concern; the kernel only guarantees that each input is a wait-free SPSC drain.

### 3.3 MPMC via splitter + merger composition

A multi-consumer pattern is constructed as a *splitter node* (`splitter_cap`) reading one SPSC channel and writing to N SPSC channels. The splitter's policy (broadcast, round-robin, capability-derived routing) is its own concern. MPMC is MPSC → splitter → N consumers, each pair an MPSC fan-in to themselves if needed.

### 3.4 Why composition rather than primitive MPMC

- The wait-free SPSC algorithm is small, fast, and well-understood; MPMC wait-free algorithms (Yang & Mellor-Crummey, Kogan & Petrank universal construction) are an order of magnitude more complex.
- The composition makes contention *visible* in the dataflow graph — the merger and splitter nodes are named, their policies are declared, their `merger_cap`/`splitter_cap` capabilities are auditable.
- Performance is excellent: a merger node servicing N inputs sees one cache line of contention per drain (only on its single output queue), which is *cheaper* than an N-way MPMC enqueue.

### 3.5 Cost of composition

A two-hop pattern (producer → merger → consumer) pays one extra cache-coherence round trip per message versus a hypothetical one-hop MPMC. For the common case where producer and merger share a CCX/socket, the extra cost is on the order of 30–50 cycles (TODO: measure on Sapphire Rapids and a Meteor Lake client). This is the price of structural simplicity.

---

## 4. SPSC algorithm (IPC-Q3): TLA+-specified custom design

### 4.1 The algorithm's distinguishing features

The SPSC algorithm is purpose-designed for PaideiaOS, not lifted from prior art. Distinguishing features:

1. **Cache-line slot discipline.** Each slot is exactly 64 bytes (one cache line); the producer-index and consumer-index head/tail variables live on separate cache lines to prevent false sharing; the slot array's geometry is announced via a CPUID-aware constant chosen by `paideia-as` at compile time.
2. **Integrated capability transport.** A slot carrying a capability stores the LAM-tagged capability handle inline in the slot's first 16 bytes; the kernel's tagged-store machinery (per Q7) writes the high LAM bits at enqueue time and verifies at dequeue.
3. **Integrated replay markers.** Every state transition (enqueue, dequeue, slot-cap mint, slot-cap burn) emits a structured marker by way of the IPC-effect default handler (§14). The marker layout is fixed at 32 bytes for fast emission.
4. **AVX-512 wide enqueue.** When the message payload is ≥ 64 bytes (a capability + large inline data), the slot store uses a single 512-bit `vmovntdq` plus `sfence` (when needed for ordering against the index store).
5. **Effect-handler hook points.** The enqueue and dequeue paths emit an effect operation (per Q-A3); the default handler is no-op in production after marker emission; test handlers can intercept.

### 4.2 Memory model

x86_64 TSO (total store order) is assumed. The algorithm relies on:

- Atomic loads and stores of aligned 64-bit values (head/tail indices).
- Release semantics of stores into slot bodies before the head-index update (achieved naturally on TSO without explicit fences; `sfence` only required for non-temporal stores).
- Acquire semantics of head-index loads before slot-body reads (likewise naturally TSO-compatible).

The TLA+ spec uses the standard x86-TSO model from Owens et al. (*A Better x86 Memory Model: x86-TSO*, TPHOLs 2009). Porting to other ISAs would require strengthening fences.

### 4.3 Index discipline

Two atomic 64-bit indices: `head` (producer-owned) and `tail` (consumer-owned). The capacity N is a power of two; the slot at logical position `i` is `slots[i mod N]`. Indices are monotonically increasing 64-bit counters; overflow is effectively impossible (300 years at 2 GHz).

### 4.4 Enqueue

```
Enqueue(channel, slot_cap, message):                 [§4 of TLA+ spec]
  1.  consume slot_cap linearly  (substructural check by paideia-as)
  2.  let h = atomic_load(channel.head)
  3.  let pos = h mod N
  4.  write message into slots[pos]                   (LAM tag bits set
                                                       if message carries cap)
  5.  emit Enqueue effect (default handler: replay marker)
  6.  atomic_store_release(channel.head, h + 1)
  7.  if WaitOn was registered, send notification
  8.  return Ok
```

Step 1 is checked at compile time (a linear `slot_cap` must be present); the wait-free runtime path is steps 2–7. Notification (step 7) is a non-blocking IPI or local set-flag; it is lossy by design (a missed notification is recovered by the next op).

### 4.5 Dequeue

```
Dequeue(channel):                                    [§5 of TLA+ spec]
  1.  let t = atomic_load(channel.tail)
  2.  let h = atomic_load_acquire(channel.head)
  3.  if t == h: return Empty
  4.  let pos = t mod N
  5.  read message from slots[pos]                   (LAM verify on cap)
  6.  emit Dequeue effect (default handler: replay marker)
  7.  atomic_store(channel.tail, t + 1)
  8.  mint a fresh slot_cap and send it back to producer
       (via the paired return channel)
  9.  return Some(message)
```

Step 8 is the slot-cap economy in action: every dequeue grants the producer one more enqueue's worth of slot. The mint operation is itself an SPSC enqueue on the paired return channel and follows §4.4.

### 4.6 Wait-freedom argument (sketch)

- The producer's operations (load head, write slot, store head, optional notify) are all bounded and unaffected by the consumer's behavior.
- The consumer's operations (load tail, load head, read slot, store tail, mint slot-cap) are bounded and unaffected by the producer's behavior except for the head-load.
- The head-load is atomic and bounded; the consumer never spins.
- Slot-cap return is itself a wait-free SPSC enqueue on the return channel.
- Therefore every operation completes in O(1) of its own steps.

The full argument (with TLA+ predicates) is in §16 and the spec file.

### 4.7 Linearizability

Each operation has a single linearization point:
- Enqueue: the atomic store of the new head (step 6 in §4.4).
- Dequeue: the atomic store of the new tail (step 7 in §4.5).

Standard model-checked linearizability witness pattern (Doolan et al.; TODO: verify reference) is applied in the TLA+ spec.

### 4.8 Why a custom algorithm

Established wait-free SPSC algorithms (Lamport classical, Vyukov, Yang-Mellor-Crummey for MPMC) are well-proven but were designed without:
- LAM-tagged capability transport.
- Structured replay markers.
- Effect-handler integration.
- AVX-512 wide-slot emission.

Adding these to an existing algorithm changes its critical section enough that the original proof no longer applies directly. Writing the spec from scratch with these features built in is the cleaner path; the wait-free SPSC algorithm core remains close to the standard ring-buffer family.

---

## 5. Message representation (IPC-Q4): hybrid 64-byte slot

### 5.1 Slot layout

Each slot is one cache line:

```
 Byte    0                  8                                                 64
 ┌────────────────┬──────────────────────────────────────────────────────────┐
 │ Header (8 B)   │                Payload (56 B)                            │
 └────────────────┴──────────────────────────────────────────────────────────┘

 Header (8 bytes):
   bits 0–7    : tag (0x00 = inline, 0x01 = cap-ref, 0x02 = sentinel)
   bits 8–23   : payload length (in bytes)
   bits 24–47  : session-step counter (for session-type debugging)
   bits 48–55  : replay-marker seq (per-channel)
   bits 56–63  : reserved (must be zero)
```

### 5.2 Inline payload (tag 0x00)

The payload bytes carry the message contents directly. Used for RPC requests/responses up to 56 bytes (e.g., capability lookups, small status messages, fixed-size protocol messages).

### 5.3 Cap-ref payload (tag 0x01)

The payload's first 16 bytes carry a LAM-tagged linear capability to a memory region; the next 8 bytes carry the region size; the remaining 32 bytes are reserved for future protocol metadata. The consumer dequeues the cap-ref and uses the capability to read the actual data zero-copy.

### 5.4 Sentinel payload (tag 0x02)

Used internally for channel-death notifications (consumed only by the surviving endpoint's `ChannelDead` mechanism, per §13).

### 5.5 Capability-tag verification

When the header indicates a payload with capability content, the kernel verifies on dequeue that the LAM tag bits match the channel's declared capability schema. A mismatch is a *fault* (the producer somehow stored a capability with the wrong tag) and triggers the audit logger plus the channel-death path. This is the runtime backstop for the static type system.

### 5.6 AVX-512 fast path

When the payload is ≥ 32 bytes, the enqueue uses `vmovntdq` for a single 512-bit non-temporal write of the slot; `sfence` follows to order against the head-index store. The fast path is selected at compile time by `paideia-as` based on the schema's declared payload-size class.

### 5.7 Why hybrid

- Small RPC messages are the dominant case in microkernels; making them zero-allocation is a critical performance property.
- Large payloads (network packets, FS blocks) are bulk transfers where zero-copy via capability is the correct model — copying them through the slot would dominate cost.
- Pure inline rejects large transfers; pure cap-ref penalizes small messages. The hybrid is Pareto-dominant.

---

## 6. Channel typing and session types (IPC-Q5, IPC-Q6)

### 6.1 Channel as functor application

A channel is declared as `module C = Channel(S)` where `S` is a structure matching the `ChannelSchema` signature. The functor produces a structure with two sub-modules: `C.Send` (the producer-side capability and operations) and `C.Recv` (the consumer-side capability and operations).

```paideia-as
signature ChannelSchema =
  protocol : SessionType            // see §6.2
  inline_max : u16                  // expected inline payload bound
  cap_shape : option CapShape       // declared capability transport
  effects : EffectRow               // effects performed on send/recv

module rpc_schema : ChannelSchema = struct
  let protocol = !{↑Request . ↓Response . end}
  let inline_max = 48
  let cap_shape = Some (LinearCap "ResponseAck")
  let effects = !{ipc_send}
end

module rpc_channel = Channel(rpc_schema)
// rpc_channel.Send : SendCap_for(rpc_schema)
// rpc_channel.Recv : RecvCap_for(rpc_schema)
```

### 6.2 Session types

A session type is a sequence of typed protocol actions. The action alphabet:

| Action | Meaning |
|---|---|
| `↑T` | Send a value of type T to the peer. |
| `↓T` | Receive a value of type T from the peer. |
| `T₁ ⊕ T₂` | Internal choice (sender picks between continuations). |
| `T₁ & T₂` | External choice (receiver picks between continuations). |
| `μX. T` | Recursion (T may reference X for unbounded protocols). |
| `end` | Protocol terminates. |
| `!{e₁,…} . T` | Continuation `T` after an effectful step. |

Lineage: Honda, *Types for Dyadic Interaction*, CONCUR 1993; Yoshida & Honda; Honda, Yoshida, Carbone, *Multiparty Asynchronous Session Types*, POPL 2008; Gay & Vasconcelos, *Linear Type Theory for Asynchronous Session Types*, JFP 20(1), 2010. Asynchronous formulation per Gay-Vasconcelos and Lindley-Morris, *Lightweight Functional Session Types*, in *Behavioural Types: from Theory to Tools*, 2017.

### 6.3 Duality

For a channel `Channel(S)` with session type `S.protocol = T`, the producer side has type `T` and the consumer side has type `dual(T)`, where `dual` is the standard involution: `dual(↑T) = ↓T`, `dual(↓T) = ↑T`, `dual(T₁ ⊕ T₂) = dual(T₁) & dual(T₂)`, etc. Duality is checked at functor application; mismatch produces an error categorized `session-duality`.

### 6.4 Async session types

Classical session types assume blocking send/recv. PaideiaOS's wait-free primitive is asynchronous, so the session-type semantics are *asynchronous* per Lindley-Morris: the type tracks what the next step in the protocol *should* be, but does not constrain when steps physically occur. The implication: a producer can issue multiple `↑T` sends in a row (queued); the consumer dequeues each in the type's specified order.

### 6.5 Compilation of session types

The paideia-as elaborator (Q-A4) lowers a session-typed channel into:
- A finite-state machine in the channel's runtime metadata (current state, transition table).
- Static checks on each `send`/`recv` call: the call's type must match the current state's expected action.
- Optional runtime assertions (debug builds) verifying the FSM state matches the actual operation.

### 6.6 Recursion and multiparty

Recursive session types (`μX. T`) compile to a state that re-enters the loop; the type-system check ensures the recursion is well-founded (every recursion path has a base case).

Multiparty session types (more than two participants in a single channel-equivalent) are *not* supported in phase 1. The dataflow graph models multi-party patterns as composition of binary channels via merger/splitter nodes (per §3); a future revision may add multiparty session types as a single primitive.

---

## 7. Scheduler integration (IPC-Q7)

### 7.1 Async wait-and-wake

A consumer that finds its channel empty may register a wait interest:

```
WaitOn(channel.Recv) -> WaitToken
```

`WaitOn` is a kernel operation that:
- Records the consumer's TCB (thread control block) in a per-channel wait list (a small fixed array; capacity 1 in the common case since channels are SPSC).
- Returns a `WaitToken` that can be checked or cancelled.

When the producer's next `Enqueue` completes (step 7 in §4.4), the kernel:
- Reads the wait list.
- If the consumer is on the local CPU, sets the consumer's runnable flag and yields if priority warrants.
- If the consumer is on a remote CPU, sends a single targeted IPI (no broadcast).
- If multiple consumers are waiting on multiple channels feeding the same target, IPI is batched within a 1-microsecond window.

The wake mechanism is lossy: if the consumer races (it finds a message *after* the empty check but *before* setting the wait list), the wake may go to a non-waiting consumer (a no-op). This is benign because the consumer will dequeue the message anyway.

### 7.2 Sync session and SC donation

When a producer issues `↑Request` on a sync-typed channel (a session type whose first action is `↑Req . ↓Resp . end` or similar), the kernel:
1. Performs the enqueue per §4.4.
2. Saves the producer's scheduling context (SC) on the channel's session-state metadata.
3. If the consumer is currently runnable and lower-priority, donates the producer's SC budget (priority + remaining quantum) to the consumer.
4. Suspends the producer pending the matching `↓Response`.

Lineage: Lyons et al., *Scheduling-Context Capabilities: A Principled, Light-Weight Operating-System Mechanism for Managing Time*, EuroSys 2018; this is the same mechanism seL4-MCS uses.

The donation is reversible: when the consumer's `↑Response` completes the session step, the SC returns to the producer, which resumes.

### 7.3 Cancellation and timeouts

A waiting consumer may cancel its wait via `Cancel(WaitToken)`; subsequent wakes are dropped. A sync producer may attach a timeout to its session-step; on expiry, the suspended producer is resumed with `SessionTimedOut`, and the half-completed session is in an undefined state (the producer must close the channel — see §8 for the fault path).

### 7.4 No spin-waits

A consumer that has not called `WaitOn` and finds the channel empty *returns* `Empty`; it does not spin. Spinning is reserved for very-low-level kernel paths that explicitly require it (e.g., MMIO polling), and those paths are not IPC consumers.

### 7.5 Energy interaction

The wake mechanism integrates with the energy-aware scheduler (D15 future): an IPI is the only thing that breaks a `UMWAIT` (Q-A2 of §1.4 in the dev-env doc). Channels that are idle long enough cause their consumers' cores to enter `C1E`/`C6` per ACPI policy; the IPI returns them. This is the energy story for IPC.

---

## 8. Backpressure: slot-cap economy (IPC-Q8)

### 8.1 The economy

At channel construction (`Channel(S)`), the constructor declares a capacity N. The constructor receives:
- N linear `slot_cap`s, granted to the *producer*.
- A `Recv(S)` capability, granted to the *consumer*.
- A *return-channel* `slot_return : Channel(SlotCapSchema)` linking consumer back to producer.

The producer can enqueue at most N messages before pausing; each enqueue consumes one `slot_cap` linearly.

### 8.2 Replenishment

When the consumer dequeues a message (step 8 of §4.5), the kernel mints a fresh `slot_cap` and enqueues it on `slot_return`. The producer dequeues `slot_return` (this dequeue is itself wait-free) to receive replenished slot-caps.

### 8.3 Type-level visibility

The producer's session type is implicitly augmented with the slot-cap consumption: every `↑T` step is `↑T !{slot_consume}` requiring `slot_cap` linearly. The producer cannot issue a step without holding a `slot_cap`. The type system enforces this; the kernel verifies at runtime.

### 8.4 What happens when slot-caps run out

The producer that holds no `slot_cap` and wants to send must:
- Drain `slot_return` (which is wait-free) to acquire replenished caps.
- If `slot_return` is empty, register `WaitOn(slot_return)`.
- When woken (because the consumer dequeued and minted a fresh cap), drain and proceed.

This pattern preserves wait-freedom *of the IPC primitive itself*: the producer's enqueue when given a `slot_cap` is unconditionally wait-free. The "wait when no slot available" path is a scheduler-level wait, not a wait-free-algorithm-level wait — it is by design.

### 8.5 Inflation: more slot-caps than capacity

A producer may not enqueue more than N messages because it cannot hold more than N `slot_cap`s — they are linear. The kernel mints exactly N at channel construction and one for each dequeue thereafter; the substructural type system prevents accidental duplication; the LAM tags backstop the runtime.

### 8.6 Why the return channel is also wait-free SPSC

The return channel is itself an SPSC channel (consumer → producer); the same primitive applies. This is recursive but well-founded because the return channel does not itself need a slot-cap economy in phase 1 (it carries unrestricted-class slot-caps; the kernel guarantees it has at least N slots, which equals the maximum that could be replenished). Phase 2 may revisit this.

---

## 9. Fault model and handoff (IPC-Q9)

### 9.1 Default: channel dies with either endpoint

When a process holding either side of a channel terminates (crash, kill, exit), the kernel:
1. Marks the channel `Dying`.
2. Reclaims all pending messages (releasing any capabilities they hold to a system-wide reclaim queue handled by the supervisor).
3. Reclaims all outstanding `slot_cap`s in the producer's possession.
4. Sets the surviving endpoint's next operation to return `ChannelDead`.
5. Eventually destroys the channel after the surviving endpoint has either acknowledged or itself died.

### 9.2 Opt-in handoff (Q14)

A channel constructed with a `handoff_cap` (granted by the supervisor at construction) participates in the Q14 live-handoff protocol:

1. The kernel notifies a designated supervisor process when an endpoint dies.
2. The supervisor has a bounded window (default: 5 seconds; configurable per channel) to call `BindReplacement(channel, new_endpoint_cap)`.
3. Within the window, pending messages and slot-caps are preserved.
4. After the window, the channel transitions to `Dying` per §9.1.

### 9.3 Session-type preservation across handoff

The handoff preserves:
- The session-type FSM state (the new endpoint enters at the same protocol step).
- The pending message queue.
- The slot-cap outstanding count.
- The replay-marker sequence number.

The supervisor's `BindReplacement` operation must provide:
- A new endpoint capability with the matching schema.
- An attestation that the new endpoint understands the current session-type state. (In phase 1, this is by-convention; phase 2 may add a typed handoff certificate.)

### 9.4 Cycle interaction

A channel in a cyclic region (constructed with `cycle_cap`) cannot opt into handoff in phase 1 — the deadlock-freedom proof obligation for the cyclic protocol becomes considerably harder to discharge across a handoff. This is a documented temporary restriction.

### 9.5 Capability reclamation

When the kernel reclaims pending messages on channel death, it must dispose of any linear capabilities they carry. The disposal policy is:
- The capability is enqueued on a system-wide *reclaim channel* whose consumer is the supervisor.
- The supervisor decides: destroy the capability (the resource is gone), forward to a designated cleaner, or audit and discard.
- The reclaim channel is itself wait-free SPSC; the supervisor's consumer side never blocks.

---

## 10. Observability: IPC ops as algebraic effects (IPC-Q10)

### 10.1 Effect declarations

```paideia-as
effect Ipc {
  op enqueue       : (ch: SendCap ↓, msg: Msg ↓) -> Result
  op dequeue       : (ch: RecvCap) -> option Msg
  op session_step  : (ch: SendCap | RecvCap, step: SessionStep) -> unit
  op slot_consume  : (ch: SendCap, slot: SlotCap ↓) -> unit
  op slot_return   : (ch: RecvCap, slot: SlotCap ↓) -> unit
  op handoff       : (ch: any, new_ep: EndpointCap ↓) -> unit
  op wait_on       : (ch: RecvCap) -> WaitToken
  op cancel_wait   : (tok: WaitToken ↓) -> unit
}
```

### 10.2 Default handler (production)

The default handler installed by the kernel at thread creation:
1. Emits a structured replay marker (32 bytes) to the per-CPU trace ring.
2. Calls into the wait-free primitive's actual implementation.
3. Returns the result.

The default handler's overhead is one indirect call (per the calling convention in §8 of the assembler doc: `mov rax, [r15 + offset]; call rax`) plus the marker emission (one 32-byte non-temporal store).

### 10.3 Trace handler

Activated by setting an environment capability at process start; the trace handler:
1. Records a structured trace entry in a contributor-readable format (JSON or TLA+-compatible).
2. Calls the production handler.
3. Records the response.

Used for offline analysis, TLA+ spec comparison, and reproducing failures.

### 10.4 Fault-injection handler

For property-based testing per `02-development-environment.md` §9.4:
1. Decides per-operation whether to:
   - Drop the operation (for backpressure resilience tests).
   - Delay the operation (for consumer-slowdown tests).
   - Reorder the operation within permitted bounds (for memory-model conformance tests).
2. Calls the production handler for non-faulted operations.

The fault-injection handler is loadable from the test harness; its policy is data-driven (TOML configuration).

### 10.5 The replay marker format

```
 Byte 0                    8                  16              32
 ┌──────────────────┬─────────────────┬──────────────────┐
 │ marker type (8)  │ channel id (8)  │ payload (16)     │
 └──────────────────┴─────────────────┴──────────────────┘
   types:
     0x10 = enqueue          0x40 = slot_consume    0x60 = wait_on
     0x11 = dequeue          0x41 = slot_return     0x61 = cancel_wait
     0x20 = session_step     0x50 = handoff         0x80 = channel_death
```

Each marker is 32 bytes (half a cache line); pairs of markers fit in one cache-line write when both halves are populated. The per-CPU trace ring is a power-of-two number of 32-byte slots; production default is 64 KiB (2K markers).

### 10.6 Integration with QEMU `-icount rr`

The trace ring is in normal guest memory; QEMU's record/replay covers it automatically. After a failing test, the host-side analyzer can:
1. Read the trace ring from the QEMU snapshot.
2. Decode the markers.
3. Compare to the TLA+ spec's expected trace.
4. Localize the divergence.

---

## 11. paideia-as implementation strategy

### 11.1 Module layout

`src/kernel/ipc/` is the kernel-side implementation:

```
src/kernel/ipc/
├── spsc.s          # the wait-free SPSC algorithm
├── slot_cap.s      # mint/burn/track of slot-caps
├── session.s       # session-type FSM
├── topology.s      # DAG check, cycle_cap handling
├── notify.s        # WaitOn / wake / IPI
├── handoff.s       # Q14 live-handoff support
├── effects.s       # Ipc effect declarations + default handler
└── trace.s         # per-CPU trace ring + marker emission
```

### 11.2 Phase-1 vs. phase-2 split

Phase 1 (NASM bootstrap):
- The wait-free SPSC algorithm in NASM with hand-traced linearity.
- A test harness that exercises producer/consumer pairs.
- The trace ring.
- *No session types* (phase 1 cannot type-check them — see Q-A4 elaborator caveat in `custom-assembler.md` §14.5).
- *No functor-typed channels* (phase 1 has restricted macros).
- *No cycle_cap auditing* (the DAG check is enforced procedurally).

Phase 2 (paideia-as coexistence):
- Session types come online.
- Functor-typed channels replace the procedural API.
- Algebraic-effect handlers wire in.
- Slot-cap economy replaces the phase-1 simple bounded-buffer.

Phase 3 (paideia-as canonical):
- Full implementation; phase-1 fallback removed.
- TLA+ spec is the source of truth; implementation is derived.

### 11.3 The TLA+ spec

`design/ipc/wait-free-dataflow.tla` is the formal specification. It is:
- Authored before phase-2 implementation begins.
- Checked with TLC for small-model exhaustive runs.
- Checked with Apalache for symbolic / larger runs.
- The property-based test harness (per `02-development-environment.md` §9.4) generates inputs whose expected behavior is derived from the spec.

### 11.4 Calling-convention impact

Per §8 of the assembler doc:
- R12 carries the channel capability (Send or Recv) on call.
- R13 carries the message (or message reference) for enqueue.
- R14 carries the slot-cap return-channel pointer.
- R15 carries the effect environment pointer with the `Ipc` handler.

A typical enqueue call site is:
```
mov  r12, send_cap          ; load capability
mov  r13, msg               ; load message
call enqueue                ; the Ipc effect operation
                            ; dispatches through r15 handler
```

The handler indirect-call resolution (§4.4 of the algebraic-effect compilation in `custom-assembler.md` §4.4) is:
```
mov  rax, [r15 + ipc_handler_offset]
call rax
```

So a default-handler enqueue is ~5 instructions plus the actual SPSC work. The hot path is well-suited to AVX-512 wide-slot stores.

---

## 12. Performance budget

### 12.1 Targets

| Operation | Budget | Substrate |
|---|---|---|
| Same-core SPSC enqueue + dequeue, inline message, default handler | ≤ 100 ns | bare-metal, Sapphire Rapids |
| Cross-core SPSC enqueue + dequeue, inline message, default handler | ≤ 300 ns | bare-metal, Sapphire Rapids (intra-socket) |
| Cross-socket SPSC enqueue + dequeue, inline message, default handler | ≤ 1 µs | bare-metal, dual-socket Xeon |
| Sync session round-trip (↑Req . ↓Resp), inline 56-byte messages, default handler | ≤ 500 ns | bare-metal, intra-core |
| Slot-cap return on dequeue | ≤ 20 ns additional | bare-metal |
| Trace marker emission | ≤ 10 ns | bare-metal |

### 12.2 The budgets are aspirational

The numbers are based on rough analogy with seL4 (sub-microsecond IPC achieved) and Zircon (low-microsecond IPC). Measured numbers will appear in `design/ipc/perf-baselines.md` (future). Regressing more than 10% from a published baseline is a `main`-blocking event per the perf-regression policy in `02-development-environment.md` §9.7.

### 12.3 What the budget implies for the algorithm

- The enqueue path must be lock-free at the instruction level: no `lock` prefix on x86 except where TSO demands it (the head-store is a regular store).
- The cache-line slot discipline must hold: producer's head, consumer's tail, and active slot all on distinct cache lines.
- The default handler's marker emission must not flush caches.
- AVX-512 fast path must be selected for ≥ 32-byte payloads.

---

## 13. Verification strategy

### 13.1 Layer A: TLA+ spec

`design/ipc/wait-free-dataflow.tla` formally specifies:
- The producer / consumer state machines.
- The slot-cap economy.
- The session-type FSM.
- The handoff protocol.
- The fault model.

Properties (with TLC for small models, Apalache for symbolic):
- **Type invariant.** Queue states are always well-formed.
- **Wait-freedom.** Every operation, considered in isolation, completes in a bounded number of its own steps.
- **Deadlock-freedom (acyclic).** When the graph is acyclic, there is always a process whose next IPC operation completes successfully.
- **Linearizability.** Operations linearize at their declared linearization points (§4.7).
- **Session-type duality preservation.** A channel's producer and consumer session-type FSMs remain dual through every operation.
- **Slot-cap conservation.** The total number of slot-caps + slot-occupied messages equals N at all times.
- **Handoff preservation.** Across a handoff event, the session FSM state and slot-cap accounting are preserved.

### 13.2 Layer B: property-based testing

Per `02-development-environment.md` §9.4, an OCaml QuickCheck-style harness drives a hosted simulator of the paideia-as IPC implementation:
- Random schedules of producer/consumer interleavings.
- Random message sequences (inline, cap-ref, mixed).
- Random fault injections via the fault-injection handler (§10.4).
- Shrinking on failure: failing schedules are minimized for inspection.

### 13.3 Layer C: linearity regression

The substructural type system catches misuse at compile time. `tests/linearity-regression/ipc/` carries:
- Accept inputs: every legal pattern of capability flow.
- Reject inputs: every illegal pattern (duplicate slot-cap, double-dequeue of message, etc.).

### 13.4 Layer D: bare-metal stress

A bare-metal test (per `02-development-environment.md` §10.6) runs a workload that exercises the IPC primitive across cores, sockets, and NUMA domains. Failure modes (memory-ordering violations, false sharing, IPI loss) are caught here, not in QEMU TCG.

---

## 14. Integration with surrounding subsystems

### 14.1 With the scheduler (C5/C6)

Per §7. The scheduler exposes `notify(tcb)`, `donate_sc(tcb_from, tcb_to)`, `revoke_donation(tcb_to)` as effects; the IPC subsystem invokes them via handlers installed at the kernel-thread root.

### 14.2 With the capability system (C4)

The IPC subsystem is one of the *consumers* of the capability system, not its definer. Every `SendCap`, `RecvCap`, `slot_cap`, `cycle_cap`, `handoff_cap`, `merger_cap`, `splitter_cap` is a capability minted by the capability system; the IPC subsystem holds them, transfers them through channels, and reclaims them at channel death.

### 14.3 With the address-space isolation (C10) and LAM (Q7)

A capability transferred through a channel is LAM-tagged on enqueue (the producer's address space) and verified on dequeue (the consumer's address space). The LAM bits encode the linearity class; mismatch triggers fault. This is the runtime backstop for the static type system.

### 14.4 With the audit log (E19)

Three events flow to the audit log:
- Cycle introduction via `cycle_cap`.
- Handoff events.
- Channel-death events accompanied by capability reclamation.

### 14.5 With the shell pipeline (E12) per Q13

The semantic shell's pipelines are dataflow graphs in this primitive's terms; each shell command is a process, each `|` is a channel. The shell's per-command schema is derived from the command's IPC schema (§6.1); typed records flow as either inline messages (for small records) or cap-ref messages (for large or zero-copy records). Cross-host pipelines (per Q13) serialize at the network boundary; the underlying primitive does not change.

---

## 15. What this primitive does not solve

- **Distributed IPC.** Cross-host channels (D14, Q13's cross-host pipelines) require a separate mechanism: a *bridge node* that serializes messages from a local channel onto a network-stack-mediated transport and reconstitutes them on the other side. The bridge is a userspace server using two local channels (one for each side) and a TCP/QUIC connection in between. The wait-free dataflow primitive is the local-IPC half only.
- **Reliable delivery.** The primitive guarantees that an enqueued message is delivered to the consumer (or the channel dies); it does not guarantee processing. If the consumer dequeues and crashes mid-processing, the message is lost.
- **Ordering across channels.** Within one channel, message order is preserved (FIFO). Across multiple channels, there is no inter-channel ordering — the dataflow graph's topology is the only ordering discipline.
- **Atomic multi-channel transactions.** A producer that wants to enqueue to channel A *iff* channel B has space must build the transactional logic in userspace; the primitive does not support multi-channel atomic operations.

---

## 16. Deadlock-freedom proof sketch

(Full proof at `design/ipc/proof.md`, in preparation.)

**Theorem (informal).** In an acyclic dataflow graph constructed from this primitive's SPSC channels with the slot-cap economy, no process is ever blocked indefinitely waiting on an IPC operation, provided that every consumer eventually dequeues from each of its inbound channels.

**Proof sketch:**

1. Wait-freedom of the SPSC algorithm: per §4.6, every individual enqueue/dequeue completes in O(1) of its own steps regardless of other parties' behavior.

2. Slot-cap conservation: the kernel mints N slot-caps at channel construction; each dequeue mints one fresh slot-cap to the producer; the substructural type system prevents duplication; the LAM tags prevent forgery. Therefore the total number of outstanding slot-caps + messages in transit = N at all times.

3. Producer non-starvation: a producer that holds no slot-caps registers `WaitOn(slot_return)`; per §7, the next dequeue on the channel will mint a slot-cap and wake the producer. The producer's wait ends in finite time iff the consumer eventually dequeues at least one message.

4. Consumer wake-up: a consumer that registers `WaitOn(channel)` and is empty will be woken by the next enqueue. The producer's enqueue is wait-free (item 1) so a producer with a slot-cap and a message ready will eventually enqueue.

5. By the assumption that every consumer eventually dequeues from each of its inbound channels, the chain of waits is finite: each producer waiting on slot-return is woken by its consumer's eventual dequeue, which is itself triggered by the consumer's policy.

6. The acyclicity of the graph guarantees there is no cycle of waits: process A waiting on a slot from B, B waiting on a message from A would require an edge A→B and an edge B→A, which is excluded by §2.

7. The "every consumer eventually dequeues" assumption is the only non-trivial proof obligation. It is discharged per-server by demonstrating that the consumer's main loop reaches a `dequeue` call on each of its inbound channels in finite time. This is a per-server obligation but is local (does not depend on other servers); the supervisor enforces it as a liveness gate at server registration.

**Discharge of the meta-obligation (Q2):** This sketch, formalized in TLA+ in the spec file and detailed in `design/ipc/proof.md`, is the paper-grade informal proof the cross-decision tension list mandated. The proof is the project's public defense of the wait-freedom and deadlock-freedom claims.

**Cyclic-region addendum:** A cyclic region constructed with `cycle_cap` is *not* covered by this proof. Each cyclic protocol must provide its own deadlock-freedom argument, written in the same TLA+ template. The supervisor's grant of `cycle_cap` is conditional on the protocol's proof being on file.

---

## 17. Open issues

| ID | Issue | Resolution location |
|---|---|---|
| IPC-O1 | The TLA+ specification (`design/ipc/wait-free-dataflow.tla`) is named in this document but not yet written. It is a phase-1 deliverable; the formal-proof obligation cannot be discharged until it exists. | `design/ipc/wait-free-dataflow.tla` |
| IPC-O2 | Multiparty session types are deferred (§6.6). Decide whether to add them in phase 3 or model multiparty via composition indefinitely. | `design/ipc/multiparty.md` (future) |
| IPC-O3 | Linearizability witness pattern reference (§4.7) — TODO: verify the most current TLA+ linearizability literature; Doolan et al. is named but may be superseded. | `design/ipc/wait-free-dataflow.tla` |
| IPC-O4 | Performance budgets (§12) are aspirational; baselines come from `design/ipc/perf-baselines.md` after first bare-metal run. | `design/ipc/perf-baselines.md` (future) |
| IPC-O5 | Handoff certificates (§9.3) are by-convention in phase 1. The phase-2 typed-handoff-certificate design is not yet started. | `design/ipc/typed-handoff.md` (future) |
| IPC-O6 | The merger/splitter node implementations (§3.2/§3.3) are not designed in this document. Each is a userspace server with its own design doc. | `design/ipc/merger-node.md`, `design/ipc/splitter-node.md` (future) |
| IPC-O7 | The slot-cap return channel in §8.6 is itself wait-free SPSC, but its own backpressure semantics are deferred (it cannot itself have a recursive slot-cap economy). The kernel-guaranteed-N-slots claim needs verification. | TLA+ spec |
| IPC-O8 | Cross-host bridge (§15) is named but undesigned; required for D14 distributed capabilities. | `design/ipc/cross-host-bridge.md` (future) |
| IPC-O9 | Reclaim-channel destination (§9.5) — should there be one global reclaim channel, or per-supervisor, or per-domain? Performance and security trade-off. | `design/ipc/reclaim.md` (future) |
| IPC-O10 | Interaction with the `paranoid-mitigations` (Q15) profile — every IPC op crossing domains pays the mitigation cost; is the budget in §12 achievable with full Spectre mitigations? Likely no; document the relax-mitigations capability scope. | `design/kernel/scheduler.md` (future) |
| IPC-O11 | The "every consumer eventually dequeues" liveness assumption in §16 is per-server; verifying it at server registration needs a checker design. | `design/ipc/liveness.md` (future) |
| IPC-O12 | Phase-1 fallback that omits session types and functors (§11.2) must define an API that is a *subset* of the phase-2 API so phase-1 code carries over. The API contract is the migration insurance. | `design/ipc/phase1-api.md` (future) |

---

## 18. References

### 18.1 Wait-free synchronization and concurrent data structures

- Herlihy, M. *Wait-Free Synchronization*. TOPLAS 13(1), 1991.
- Lamport, L. *Specifying Concurrent Program Modules*. TOPLAS 5(2), 1983.
- Vyukov, D. *Bounded MPMC Queue* (and related SPSC/MPSC writings). Concurrency-research blog and follow-ups.
- Yang, C. and Mellor-Crummey, J. *A Wait-free Queue as Fast as Fetch-and-Add*. PPoPP 2016.
- Kogan, A. and Petrank, E. *A Methodology for Creating Fast Wait-Free Data Structures*. PPoPP 2012.
- Hendler, D., Incze, I., Shavit, N., Tzafrir, M. *Flat Combining and the Synchronization-Parallelism Tradeoff*. SPAA 2010.

### 18.2 Memory model and verification

- Owens, S., Sarkar, S., Sewell, P. *A Better x86 Memory Model: x86-TSO*. TPHOLs 2009.
- Sewell, P., Sarkar, S., Owens, S., Nardelli, F.Z., Myreen, M. *x86-TSO: A Rigorous and Usable Programmer's Model for x86 Multiprocessors*. CACM 53(7), 2010.
- Lamport, L. *The Temporal Logic of Actions*. TOPLAS 16(3), 1994 (TLA foundational).
- Newcombe, C. et al. *How Amazon Web Services Uses Formal Methods*. CACM 58(4), 2015.

### 18.3 Session types

- Honda, K. *Types for Dyadic Interaction*. CONCUR 1993.
- Honda, K., Vasconcelos, V. T., Kubo, M. *Language Primitives and Type Discipline for Structured Communication-Based Programming*. ESOP 1998.
- Gay, S. J., Vasconcelos, V. T. *Linear Type Theory for Asynchronous Session Types*. JFP 20(1), 2010.
- Honda, K., Yoshida, N., Carbone, M. *Multiparty Asynchronous Session Types*. POPL 2008.
- Lindley, S., Morris, J. G. *Lightweight Functional Session Types*. In *Behavioural Types: from Theory to Tools*. River Publishers, 2017.
- Wadler, P. *Propositions as Sessions*. ICFP 2012.

### 18.4 Scheduling and IPC architecture

- Lyons, A., McLeod, K., Almatary, H., Heiser, G. *Scheduling-Context Capabilities: A Principled, Light-Weight Operating-System Mechanism for Managing Time*. EuroSys 2018.
- Elphinstone, K., Heiser, G. *From L3 to seL4 — What Have We Learnt in 20 Years of L4 Microkernels?*. SOSP 2013.
- Liedtke, J. *On Micro-Kernel Construction*. SOSP 1995.
- Bershad, B. et al. *User-level Interprocess Communication for Shared Memory Multiprocessors*. TOCS 9(2), 1991.

### 18.5 Functional / typed effect systems

- Plotkin, G., Pretnar, M. *Handlers of Algebraic Effects*. ESOP 2009.
- Leijen, D. *Koka: Programming with Row Polymorphic Effect Types*. MSFP 2014.

### 18.6 Standards

- Intel® 64 and IA-32 Architectures Software Developer's Manual, current revision (memory model, CPUID, LAM, AVX-512).
- DWARF 5 standard (debug info).

---

*End of document.*
