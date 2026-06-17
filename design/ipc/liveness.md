# PaideiaOS — IPC: Per-Server Liveness Checker

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Static-analysis specification of the liveness checker that verifies a server's main loop satisfies the deadlock-freedom proof's "every consumer eventually dequeues" assumption (per `proof.md` §5.5). Addresses IPC-O11.

**Hard inputs:**
- `proof.md` §5.5 — the liveness assumption.
- `wait-free-dataflow.md` §16 — assumption 7 of the deadlock-freedom proof.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| LIV-D1 | Liveness checking is a static analysis run at server-registration time | Pre-execution |
| LIV-D2 | The checker verifies each server's main loop reaches a `dequeue` on each inbound channel in finite time | Discharges the proof assumption |
| LIV-D3 | The check is conservative: reject when liveness cannot be proved | Safety over completeness |
| LIV-D4 | The check uses control-flow analysis + termination analysis on the main loop | Standard static analysis |
| LIV-D5 | A server that fails the check cannot be registered as a channel consumer | Enforcement |

---

## 1. The liveness obligation

The deadlock-freedom proof (`proof.md` §5.5) assumes:

> Every consumer eventually dequeues from each of its inbound channels.

If a consumer's main loop never reaches a `dequeue` on a channel C (perhaps because it loops indefinitely on something else), C accumulates messages, producers on C run out of slot-caps, and a chain of waits develops.

The checker rejects servers whose static analysis cannot verify the assumption.

---

## 2. What the checker verifies

For each server registering with a `RecvCap` on channel C:
1. The server has a *main loop* — a top-level loop in its `main` function.
2. The main loop has a finite, bounded body.
3. The body reaches a `dequeue(C)` operation (or a transitive call that does so) in every iteration.
4. No path in the body indefinitely blocks before reaching the dequeue.

The body may contain inner loops, conditionals, and effect operations, but every path through the body must terminate.

---

## 3. Analysis algorithm

### 3.1 Control-flow graph

Build the CFG of the main loop's body. Identify:
- Termination points (`break`, `return`).
- Dequeue calls per inbound channel.
- Blocking operations (`WaitOn`, `wait_for_token`, etc.).

### 3.2 Per-channel dequeue reachability

For each inbound channel C, check that every cycle in the CFG passes through at least one dequeue(C) operation.

If yes: liveness verified for C.
If no: report error `S0908` (liveness obligation violated).

### 3.3 Termination of inner constructs

Each inner loop must terminate. For deterministic loops (with bounded iteration counts), this is trivial. For loops over IPC channels, the producer-side bound argument applies.

If termination cannot be proved, the checker is conservative and rejects.

### 3.4 Effect-handler bypass

If the main loop installs an effect handler that captures `Dequeue`, the checker must verify the handler eventually returns. This is a higher-order analysis; phase 2+ feature.

For phase 1, effect-handler-installing servers are rejected by the checker; they must register an exception.

---

## 4. Examples

### 4.1 Valid

```paideia-as
fn main(input1 : RecvCap, input2 : RecvCap) -> unit !{...} =
  loop {
    select {
      input1 => |msg| process(msg)
      input2 => |msg| process(msg)
    }
  }
```

The `select` ensures both channels are dequeued in turn. Verified.

### 4.2 Invalid (loop never reaches dequeue)

```paideia-as
fn main(input : RecvCap) -> unit !{...} =
  loop {
    do_something_else()
  }
```

The main loop doesn't dequeue. Rejected: `S0908`.

### 4.3 Invalid (one inbound never dequeued)

```paideia-as
fn main(input1 : RecvCap, input2 : RecvCap) -> unit !{...} =
  loop {
    let msg = input1.recv()
    process(msg)
    // input2 never dequeued
  }
```

Rejected: `S0908` for input2.

---

## 5. Limitations

- The checker rejects servers it cannot prove safe. False negatives are possible (a server may actually satisfy liveness but the checker can't prove it).
- Workarounds: refactor the server into the canonical patterns the checker recognizes, or register a manual exemption (audited).

---

## 6. Phase 2+ feature

Phase 1: no checker; rely on developer discipline.
Phase 2: checker comes online; new server registrations validated.
Phase 3+: relax conservative rules; add support for more patterns.

---

## 7. Open issues

| ID | Issue |
|---|---|
| LIV-O1 | The exact set of patterns the checker recognizes — initial list. |
| LIV-O2 | Manual exemption process — what audit trail; who approves. |
| LIV-O3 | Effect-handler termination analysis — phase 2+ design. |
| LIV-O4 | Runtime liveness monitoring — supplement static analysis with runtime detection (a server holding inbound messages for > 60 s is flagged). |

---

*End of document.*
