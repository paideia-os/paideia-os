# PaideiaOS — IPC: Merger Node Design

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** The *merger node* — a userspace process that fan-ins from N SPSC channels into one. Addresses IPC-O6. Combined with the splitter node, the merger enables MPSC, MPMC, and arbitrary fan-in patterns over the wait-free SPSC primitive (per IPC-Q2).

**Hard inputs:**
- `wait-free-dataflow.md` §3 — channel discipline; merger nodes are how MPSC is reached.
- `wait-free-dataflow.md` §6 — session types compose at the merger boundary.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| MERGE-D1 | A merger node is a userspace process holding a `merger_cap` capability | Capability-discipline per IPC-Q2 |
| MERGE-D2 | A merger has N input channels and 1 output channel; both are wait-free SPSC | Fundamental design |
| MERGE-D3 | The merger's *drain policy* is configurable per instance: round-robin, priority, weighted-fair, capability-derived | Flexibility |
| MERGE-D4 | The merger preserves session types: the output channel's schema must be compatible with all input channels' schemas | Type-system consistency |
| MERGE-D5 | The merger's drain is wait-free per input but may rebatch on output | Performance |
| MERGE-D6 | A merger's failure (crash) is treated as IPC partition: downstream consumer sees `ChannelDead` per IPC-Q9 | Failure containment |

---

## 1. Merger node architecture

```
   ┌──────────────────────────────────────────────────────────┐
   │   Merger node (userspace process)                          │
   │                                                            │
   │   Inputs (N SPSC channels):                               │
   │   ┌──────────────────────┐                                │
   │   │ Channel(Schema)  in1 │ ── recv ──► ┌──────────────┐ │
   │   └──────────────────────┘             │              │ │
   │   ┌──────────────────────┐             │              │ │
   │   │ Channel(Schema)  in2 │ ── recv ──► │  Drain       │ │
   │   └──────────────────────┘             │  policy      │ │
   │            ...                          │  (RR / pri / │ │
   │   ┌──────────────────────┐             │   weighted)  │ │
   │   │ Channel(Schema)  inN │ ── recv ──► │              │ │
   │   └──────────────────────┘             └─────┬────────┘ │
   │                                              │           │
   │                                              ▼           │
   │   Output (1 SPSC channel):                              │
   │   ┌──────────────────────┐                              │
   │   │ Channel(Schema) out  │ ◄── send ──                  │
   │   └──────────────────────┘                              │
   │                                                          │
   └──────────────────────────────────────────────────────────┘
```

---

## 2. The `merger_cap`

A merger node holds a `merger_cap` granted by the supervisor. The capability authorizes:
- Constructing the N input channels (one per producer).
- Constructing the 1 output channel (to the consumer).
- The drain operations.

The supervisor's policy decides who gets `merger_cap`; typically driver framework components and protocol bridges (per `drivers/framework.md`).

---

## 3. Schema compatibility

The N input channels and the 1 output channel must agree on the message schema:
- Input schema = Output schema (the simple case).
- Input schemas are sub-types of Output schema (type-promotion case).
- Or: a transformation lambda is part of the merger's configuration (the *transforming merger*).

The transforming merger is more capable but requires lambda-passing — phase 2+.

For phase 1–2, only identical-schema mergers are supported.

---

## 4. Drain policies

### 4.1 Round-robin

```paideia-as
policy = RoundRobin
```

The merger drains one message from input 1, then input 2, ..., then input N, then back to 1. Wait-free SPSC dequeue per input; aggregate is bounded by N × per-channel cost.

Fair across producers. Default policy.

### 4.2 Priority

```paideia-as
policy = Priority [in1=high, in2=medium, in3=low, ...]
```

Higher-priority inputs are drained first; lower-priority inputs only when higher are empty.

Useful for: critical control messages mixed with bulk data; audit-event prioritization.

### 4.3 Weighted fair

```paideia-as
policy = WeightedFair [in1=4, in2=2, in3=1, ...]
```

In each round, drain ratio-proportional. E.g., 4:2:1 means: in each 7-message cycle, drain 4 from in1, 2 from in2, 1 from in3.

Useful for: bandwidth allocation across producers; multi-tenant fairness.

### 4.4 Capability-derived

```paideia-as
policy = CapabilityDerived
```

Each input's priority/weight is read from the producer's capability metadata (e.g., the producer's SC priority). This makes the merger respect the system's overall scheduling discipline.

### 4.5 Custom

The merger is itself a process; the operator can write a custom lambda for the drain policy. Phase 3+.

---

## 5. Drain implementation

### 5.1 Main loop

```paideia-as
fn merger_main(inputs : Array<RecvCap>, output : SendCap, policy : DrainPolicy) -> unit !{...} =
  loop {
    let next_input = policy.select(inputs)
    match next_input.try_recv() with
    | Some(msg) ->
        output.send(msg)
    | None ->
        // input empty; policy may decide to skip or wait
        policy.handle_empty(next_input)
    end
  }
```

### 5.2 Wait behavior

When all inputs are empty, the merger should wait rather than busy-poll. The wait mechanism:
- Register `WaitOn(any_of_inputs)` — the kernel wakes on the next enqueue to any input.
- The merger resumes and drains the input that triggered the wake.

This is the "wait on multiple channels" pattern. Implementation: the merger's effect environment installs a special handler that watches multiple channels.

### 5.3 Output backpressure

If the output channel is full (consumer is slow), the merger pauses draining inputs:
- The slot-cap economy on the output causes the merger to wait on output slot-caps.
- During the wait, input channels accumulate.
- This is the natural backpressure flow: slow consumer slows merger which slows producers.

---

## 6. Failure containment

### 6.1 Merger crash

If the merger process dies:
- The N input channels lose their consumer (the merger was the consumer); inputs become "channel dead" per IPC-Q9.
- The output channel loses its producer (the merger was the producer); output becomes "channel dead".
- All producers see `ChannelDead` on subsequent sends.
- The downstream consumer sees `ChannelDead` on subsequent receives.
- The supervisor restarts the merger if policy dictates (per `drivers/framework.md` lifecycle).

### 6.2 Input channel death

If a producer dies and its input channel dies, the merger continues draining the remaining N-1 inputs. The merger's audit log records the dead input.

### 6.3 Output channel death

If the consumer dies and the output channel dies, the merger detects `ChannelDead` on send. The merger pauses, audits, and signals upstream producers via the audit log. The supervisor may restart the consumer or terminate the merger.

---

## 7. Use cases

### 7.1 Log aggregation

N producers (kernel, drivers, applications) write audit events to N SPSC channels. A merger aggregates into one stream for the audit log writer.

### 7.2 NIC RX from multiple queues

Modern NICs use RSS to distribute packets across multiple RX queues; each queue is an input to a merger; the merger aggregates into the network stack's main input stream.

### 7.3 Multi-producer command queue

A device with multiple clients (e.g., the NVMe driver receiving requests from FS, supervisor, audit) uses a merger to serialize requests into a single submission queue.

---

## 8. Performance

| Metric | Budget | Substrate |
|---|---|---|
| Per-message merger overhead (drain + send) | ≤ 200 ns | bare-metal SR |
| Wake latency on empty input → activity | ≤ 1 µs | bare-metal |
| Drain throughput with 4 inputs | ≥ 5 Mpps | bare-metal |

Aspirational; per-deployment baselines come from `perf-baselines.md` (future).

---

## 9. Verification

### 9.1 Property tests

- The merger preserves the FIFO order *within* each input channel (a merger's output is a FIFO interleaving of the inputs).
- The merger respects the drain policy: round-robin actually round-robins, priority respects priorities.
- Failure containment: an input's death does not break other inputs.

### 9.2 Compositional verification

When the merger is composed with the upstream (the producers) and downstream (the consumer), the overall dataflow graph remains acyclic — assuming the consumer does not produce back to any producer.

---

## 10. Open issues

| ID | Issue |
|---|---|
| MERGE-O1 | The "wait on multiple channels" mechanism — concrete implementation. |
| MERGE-O2 | Custom-lambda drain policy — phase 3+ feature; design deferred. |
| MERGE-O3 | Merger scaling — for N > 64 inputs, the policy.select() cost becomes significant; consider tree-of-mergers. |
| MERGE-O4 | Output backpressure metrics — surface to operators for diagnosis. |

---

*End of document.*
