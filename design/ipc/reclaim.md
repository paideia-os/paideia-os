# PaideiaOS — IPC: Capability Reclamation Policy

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Specification of how capabilities held in dying channels are reclaimed. Addresses IPC-O9.

**Hard inputs:**
- `wait-free-dataflow.md` §9.5 — capabilities in pending messages are enqueued on the system-wide reclaim channel; supervisor decides disposition.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| RCM-D1 | One global reclaim channel; supervisor is the consumer | Centralized policy |
| RCM-D2 | Reclaim channel is the wait-free SPSC primitive (MPSC variant via merger) | Standard mechanism |
| RCM-D3 | Disposition policies: destroy / forward to designated cleaner / audit-and-discard | Configurable per cap kind |
| RCM-D4 | Reclaim is at-most-once: a reclaimed capability cannot be re-reclaimed | Substructural invariant |
| RCM-D5 | The supervisor maintains a reclaim-queue depth metric and alerts on overflow | Operability |

---

## 1. The reclaim channel

A single MPSC channel (built from merger nodes per IPC-Q2):

```paideia-as
let reclaim_channel : Channel(ReclaimSchema) = ...
let reclaim_consumer : RecvCap = ... (held by supervisor)
```

The schema:

```paideia-as
signature ReclaimSchema =
  protocol = μX. (↑ReclaimItem | ↑Close) . X
  message_type = ReclaimItem
  effects = !{capability_reclaim}

struct ReclaimItem {
  capability : OpaqueCap     // the capability being reclaimed
  origin_process : ProcessId  // which process held it
  reason : ReclaimReason     // why
  timestamp : u64
}

enum ReclaimReason {
  ChannelDeath,
  ProcessTermination,
  ExplicitRevoke,
  ResourcePressure,
}
```

---

## 2. Producer side

Producers of reclaim events:
- The kernel's channel-death path (when a channel dies with pending messages, each containing capabilities).
- Process termination (when a process holding caps dies, the kernel reclaims its CSpace).
- Explicit revocation (the supervisor revokes a capability; the holder's view is invalidated; the cap descriptor needs disposition).
- Resource-pressure response (the supervisor invokes mass-revocation of low-priority caps to free resources).

Each producer holds a SendCap to the reclaim channel; the merger consolidates.

---

## 3. Consumer (supervisor) side

The supervisor's reclaim handler:

```paideia-as
fn reclaim_handler() -> unit !{capability_reclaim, audit_log} =
  loop {
    let item = reclaim_consumer.recv()
    audit_log.write(item)
    match disposition_for(item.capability.kind) with
    | Destroy ->
        kernel.destroy_capability(item.capability)
    | Forward(cleaner) ->
        cleaner.send(item.capability)
    | AuditAndDiscard ->
        // audit already done; nothing more
        ()
    end
  }
```

The `disposition_for` function maps capability kind to policy:

| Kind | Default disposition |
|---|---|
| `memory` | Destroy (free the memory back to the pool) |
| `ipc-endpoint` | Destroy |
| `port` | Audit-and-discard (the port goes to a free pool implicitly) |
| `irq` | Audit-and-discard |
| `process` | Forward to the supervisor's process-management policy |
| `sched-ctx` | Destroy (return budget to the AS) |
| `slot-cap` | Destroy (the slot is reclaimed) |
| `cycle-cap` | Forward to audit (cycle revocations are significant) |
| `handoff-cap` | Forward to audit (handoff revocations affect availability) |
| `audit` | Forward to audit-log (the audit-log cap was held by something; record) |
| `seal-cap` / `unseal-cap` | Destroy + audit |

---

## 4. Race conditions

If a capability is in transit (in a channel slot at the moment of channel death) and the consumer has not yet dequeued:
- The slot's tag becomes stale (channel-death epoch bump).
- The reclaim handler picks up the capability from the dead channel's slots and enqueues a reclaim item.
- The capability is destroyed; any future LAM verification fails.

This race is handled by the channel-death sequence in `wait-free-dataflow.md` §9.5.

---

## 5. Performance

| Metric | Budget | Substrate |
|---|---|---|
| Per-reclaim latency | ≤ 1 µs | bare-metal |
| Reclaim queue depth alarm | > 100 outstanding | configurable |
| Mass-reclaim throughput | ≥ 100K caps/s | bare-metal |

---

## 6. Phase 1 / Phase 2

Phase 1: no separate reclaim channel; kernel directly destroys caps. (The capability system is itself nascent in phase 1.)

Phase 2: the design above lands.

---

## 7. Open issues

| ID | Issue |
|---|---|
| RCM-O1 | Multiple cleaner processes — for different kinds; the dispatch is per-kind via a registry. |
| RCM-O2 | Cleaner crash handling — if a cleaner dies with caps it received, do they recurse into reclaim? Yes; this is fine. |
| RCM-O3 | Reclaim-queue-overflow recovery — what if the supervisor falls behind? |
| RCM-O4 | Disposition rules for derived kinds — derived kinds inherit base kind disposition by default; explicit overrides per derived kind. |

---

*End of document.*
