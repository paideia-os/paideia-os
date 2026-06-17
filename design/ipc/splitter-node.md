# PaideiaOS — IPC: Splitter Node Design

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** The *splitter node* — a userspace process that fan-outs from one SPSC channel to N. Addresses IPC-O7. Mirror of the merger node (`merger-node.md`); together they enable MPMC patterns over the wait-free SPSC primitive.

**Hard inputs:**
- `wait-free-dataflow.md` §3.3 — splitter nodes are how multi-consumer fan-out is reached.
- `merger-node.md` — sibling design for fan-in.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| SPLIT-D1 | A splitter is a userspace process holding `splitter_cap` | Capability-discipline per IPC-Q2 |
| SPLIT-D2 | A splitter has 1 input channel and N output channels (all wait-free SPSC) | Fundamental design |
| SPLIT-D3 | Routing policy is configurable: broadcast, round-robin, hash-based, capability-derived | Flexibility |
| SPLIT-D4 | Schema preservation: input schema = output schemas (for broadcast) or sub-types (for routing) | Type-system consistency |
| SPLIT-D5 | Backpressure: a single slow consumer slows down the splitter (head-of-line blocking) unless the policy allows dropping | Pragmatic |

---

## 1. Architecture

```
   ┌──────────────────────────────────────────────────────────┐
   │   Splitter node (userspace process)                        │
   │                                                            │
   │   Input (1 SPSC channel):                                 │
   │   ┌──────────────────────┐                                │
   │   │ Channel(Schema)  in  │ ── recv ──►                   │
   │   └──────────────────────┘                                │
   │                                                            │
   │   Routing policy:                                          │
   │   ┌──────────────────────────────────────────────────┐  │
   │   │ select(msg) → set of output indices              │  │
   │   │   broadcast: all                                  │  │
   │   │   round-robin: next                              │  │
   │   │   hash: hash(msg) mod N                          │  │
   │   │   capability: msg.target's cap                   │  │
   │   └──────────────────────────────────────────────────┘  │
   │                                                            │
   │   Outputs (N SPSC channels):                              │
   │   ┌──────────────────────┐                                │
   │   │ Channel(Schema) out1 │ ◄── send ──                   │
   │   └──────────────────────┘                                │
   │   ┌──────────────────────┐                                │
   │   │ Channel(Schema) out2 │ ◄── send ──                   │
   │   └──────────────────────┘                                │
   │            ...                                            │
   │   ┌──────────────────────┐                                │
   │   │ Channel(Schema) outN │ ◄── send ──                   │
   │   └──────────────────────┘                                │
   │                                                            │
   └──────────────────────────────────────────────────────────┘
```

---

## 2. Routing policies

### 2.1 Broadcast

Every message goes to *every* output.

Use cases: state-change notifications, multicast subscriptions, audit-log shadowing.

If any single output is full, the splitter must decide: wait (block all outputs) or drop for the full output (continue others). Default: wait.

### 2.2 Round-robin

Each message goes to one output in round-robin order.

Use cases: load balancing across worker pool, parallel processing.

### 2.3 Hash-based

`output_index = hash(message_key) mod N`. The "key" extraction is part of the schema.

Use cases: routing by connection ID, partitioning by user ID, sticky session routing.

### 2.4 Capability-derived

The message itself carries a target capability; the splitter routes to the output associated with the target.

Use cases: explicit addressing, command routing to specific drivers.

### 2.5 Custom

A user-provided lambda computes the output index from the message. Phase 3+.

---

## 3. Implementation

### 3.1 Main loop

```paideia-as
fn splitter_main(input : RecvCap, outputs : Array<SendCap>, policy : RoutePolicy) -> unit !{...} =
  loop {
    let msg = input.recv()
    let targets = policy.select(msg)
    for target_idx in targets do
      outputs[target_idx].send(msg.clone())
    end
  }
```

Note: `msg.clone()` is necessary for broadcast (each output gets its own copy). For capability-laden messages, the clone semantics are subtle (a linear capability cannot be cloned; broadcast requires the message body to be unrestricted, or it must use share-mint semantics per CAP-Q7).

### 3.2 Broadcast with linear messages

When the message contains a linear capability and the policy is broadcast:
- The splitter mints affine shared-read capabilities to N consumers.
- Each consumer gets an affine copy.
- The substructural type system enforces consumer behavior.

This is the cleanest way to broadcast capability handles.

### 3.3 Output backpressure

Per output is independent: a full output blocks only its consumer, not the others.

For broadcast: if any output is full, the splitter pauses until at least one slot becomes available. The pause mechanism uses `WaitOn` on multiple outputs.

For non-broadcast: the routing decision determines a single target; if that target is full, the splitter waits on that target's slot-cap return.

---

## 4. Failure containment

### 4.1 Output death

If output K dies:
- The splitter detects on send to K.
- For broadcast: the policy decides whether to skip K or terminate.
- For round-robin/hash: the policy decides whether to re-route to a sibling output or drop.
- The supervisor's policy determines auto-restart of the consumer.

### 4.2 Splitter crash

Standard: input loses its consumer; outputs lose their producer; everyone gets `ChannelDead`; supervisor restarts.

---

## 5. Use cases

### 5.1 NIC TX RSS

The network stack splits outbound packets across multiple NIC TX queues for parallel transmission. The splitter routes by hash on the packet's flow tuple.

### 5.2 Audit log shadowing

The audit log is broadcast to:
- The local audit-log file writer.
- A network-backed remote archive (when configured).
- An anomaly detector (when configured).

### 5.3 Replicated storage

A write to a replicated storage system goes via a splitter to N storage replicas, each receiving the same write.

### 5.4 Pub/sub

A publisher uses a splitter to fan-out events to N subscribers.

---

## 6. Combined merger + splitter

A complete MPMC channel is:

```
N producers → merger → 1 channel → splitter → M consumers
```

The merger consolidates the N producers; the splitter fans out to the M consumers. The middle channel is a wait-free SPSC primitive.

This is heavier than a hypothetical primitive MPMC but is structurally simpler, makes contention points visible (the merger and splitter are named processes), and avoids the algorithmic complexity of true MPMC wait-free queues (per IPC-Q2 design rationale).

---

## 7. Performance

| Metric | Budget | Substrate |
|---|---|---|
| Per-message splitter overhead (route + send) | ≤ 300 ns | bare-metal |
| Broadcast to 4 outputs | ≤ 600 ns total | bare-metal |
| Hash-based routing | ≤ 100 ns lookup + send | bare-metal |

Aspirational.

---

## 8. Verification

### 8.1 Property tests

- The splitter preserves FIFO within each output (within an output's stream, messages arrive in the order they were routed).
- The broadcast policy delivers every message to every output (modulo skipping policy).
- The hash policy delivers consistent routing (same key → same output).

### 8.2 Acyclicity

The splitter does not introduce cycles into the dataflow graph: input → splitter → N outputs is a tree expansion.

---

## 9. Open issues

| ID | Issue |
|---|---|
| SPLIT-O1 | Broadcast with linear capabilities — the share-mint semantics need a precise spec. |
| SPLIT-O2 | The lambda-based custom routing policy — phase 3+; design deferred. |
| SPLIT-O3 | Output prioritization — when multiple outputs are eligible (broadcast), which is sent to first matters for latency-sensitive consumers. |
| SPLIT-O4 | Hash function selection for hash-based routing — BLAKE3 default? Faster non-cryptographic hash for non-adversarial use cases? |

---

*End of document.*
