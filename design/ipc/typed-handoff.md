# PaideiaOS — IPC: Typed State-Handoff Certificate

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Specification of the typed handoff certificate that supports Q14 live state-handoff for channels participating in the opt-in handoff mechanism. Addresses IPC-O5.

**Hard inputs:**
- `wait-free-dataflow.md` §9.3 — handoff preserves session-type FSM state, pending messages, slot-cap accounting, replay marker seq.
- `drivers/framework.md` §11 — drivers opting into handoff via `handoff_cap`.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| HND-D1 | Handoff state is serialized to a **Cap'n Proto** schema per channel | Q13 alignment + zero-copy reads |
| HND-D2 | Each `Channel(Schema)` defines a paired `Channel(Schema).HandoffState` schema | Type-system enforced |
| HND-D3 | The handoff certificate carries: session-FSM state, pending messages, outstanding slot-cap count, replay seq, schema version | Comprehensive |
| HND-D4 | The supervisor validates the certificate against the channel's current state before binding the replacement | Safety check |
| HND-D5 | Schema versioning: an older certificate is accepted if a `migrate` step is registered for the version gap | Forward compatibility |
| HND-D6 | The handoff window default is 5 seconds; configurable per channel via the `handoff_cap`'s descriptor | Per IPC §9.2 |

---

## 1. Handoff state schema

For a channel with schema `S`, the paired handoff schema is:

```capnp
struct HandoffCertificate(S) {
  schemaVersion @0 :UInt32;
  channelId @1 :ChannelId;
  sessionFsmState @2 :Text;      # name of the current FSM state
  pendingMessages @3 :List(S.MessageType);
  outstandingSlotCaps @4 :UInt32;
  replayMarkerSeq @5 :UInt64;
  timestamp @6 :UInt64;          # nanoseconds since epoch
  supervisorSignature @7 :Signature;
}
```

The producer of the handoff (the dying driver) constructs this; the consumer (the replacement driver) reads it.

---

## 2. Handoff sequence

```
1. Supervisor decides driver D needs update.
2. Supervisor sends begin_handoff(snapshot_cap) to D.
3. D enters Handoff state (per drivers framework §5).
4. D serializes its state:
   a. For each channel D owns:
      - Read the session FSM state.
      - Collect pending messages from in-flight queues.
      - Record outstanding slot-cap count.
      - Record last replay marker.
   b. Construct HandoffCertificate.
   c. Sign the certificate using D's process key (the supervisor's certificate verifies the signature).
   d. Store in the snapshot_cap-allocated region.
5. D responds handoff_complete.
6. D exits.
7. Supervisor starts D' with the snapshot certificate.
8. D' deserializes, validates each certificate, re-binds to the channels.
9. Channels continue from the recorded state.
```

---

## 3. Validation

The supervisor validates each handoff certificate:
- Schema version compatible with replacement's expected schema.
- Channel ID matches a known channel.
- Session FSM state is reachable from "start" via the replayMarkerSeq messages.
- Outstanding slot-caps + (head - tail) = capacity (Theorem 4 of `proof.md`).
- Signature valid (the dying driver signed it).

Failure aborts the handoff; the channel falls back to hard restart per Q14 default.

---

## 4. Schema migration

When the replacement driver expects schema version V' ≥ V (the version in the certificate):
- If V' = V: direct binding.
- If V' > V: a registered `migrate(certificate, V → V')` function transforms the certificate.
- If V' < V: rejected (cannot downgrade).

The migration function is part of the schema definition; failure to register one means schema V' is not handoff-compatible with V.

---

## 5. Handoff timing

| Phase | Budget |
|---|---|
| Serialization | ≤ 50 ms |
| Supervisor validation | ≤ 10 ms |
| Replacement startup + binding | ≤ 100 ms |
| Total handoff window | ≤ 5 seconds default |

If the supervisor or replacement exceeds the window, the channels fail.

---

## 6. Cyclic-region restriction

Per `wait-free-dataflow.md` §9.4, channels in cyclic regions (constructed with `cycle_cap`) cannot opt into handoff in phase 1. The deadlock-freedom proof obligation for cyclic protocols across a handoff is too complex for phase 1.

Phase 3+ may relax this if the cyclic protocols have associated handoff specs.

---

## 7. Open issues

| ID | Issue |
|---|---|
| HND-O1 | Schema migration tooling — the migrate function must be registered; concrete API. |
| HND-O2 | Handoff for channels mid-session-step — what if the producer's `↑Request` was sent but `↓Response` not yet received? |
| HND-O3 | Certificate audit log — every handoff is recorded in the audit log; format. |
| HND-O4 | Replacement driver authentication — does the replacement need to prove identity beyond holding the snapshot cap? |

---

*End of document.*
