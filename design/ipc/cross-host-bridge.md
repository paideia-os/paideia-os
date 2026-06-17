# PaideiaOS — IPC: Cross-Host Bridge

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Specification of the cross-host bridge that extends the local wait-free dataflow IPC primitive into a network-mediated transport for distributed capabilities (D14). Addresses IPC-O8.

**Hard inputs:**
- `wait-free-dataflow.md` §15 — bridge node is a userspace server using two local channels plus a TCP/QUIC connection.
- `security/pq-trust-root.md` §7 — universal hybrid KEM at every confidentiality boundary.
- `network/stack.md` — TCP/UDP/QUIC channels available.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| BRG-D1 | A cross-host bridge is a pair of userspace processes (one per host) running on each side | Symmetric design |
| BRG-D2 | Transport: TCP, UDP, or QUIC at choice; QUIC preferred for new deployments | Pillar 7 forward-looking |
| BRG-D3 | All cross-host traffic uses the universal hybrid KEM (X25519 + ML-KEM-1024) for confidentiality | PQ doc binding |
| BRG-D4 | Authentication: each host's bridge uses operational-tier signing keys (hybrid Ed25519 + ML-DSA-65) | PQ doc binding |
| BRG-D5 | Messages are serialized to Cap'n Proto over the wire | Q13 binding |
| BRG-D6 | Bridge is a normal userspace process; failure containment via the supervisor's restart policy | Standard |
| BRG-D7 | Capabilities are *translated*, not transferred, across the bridge — a remote capability is *attested* by the bridge to the remote party | Distributed capability semantics |

---

## 1. Architecture

```
   Host A                                              Host B
   ┌──────────────────┐                            ┌──────────────────┐
   │ Producer process │                            │ Consumer process │
   │   ──Channel A──► │                            │ ──Channel A──    │
   └──────────────────┘                            └──────────────────┘
            │                                              ▲
            │                                              │
            ▼                                              │
   ┌──────────────────┐    encrypted hybrid-KEM   ┌──────────────────┐
   │ Bridge A         │    + Cap'n-Proto serialized │ Bridge B       │
   │ (userspace)      │    over TCP/QUIC          │ (userspace)      │
   │ ◄──Channel B───  │ ◄────────────────────────► │ ◄──Channel B─── │
   └──────────────────┘                            └──────────────────┘
```

Local channels (A on Host A side, B on Host A side; A on Host B side, B on Host B side) connect to the bridge processes; the network connection carries serialized messages between bridges.

---

## 2. Connection establishment

```
1. Host A's supervisor decides to bridge to Host B.
2. Bridge A initiates a connection to Bridge B:
   a. TCP/QUIC handshake with hybrid X25519 + ML-KEM-1024 KEM.
   b. Mutual TLS-equivalent: each side proves operational-tier identity via Ed25519+ML-DSA-65 signature.
   c. Capability negotiation: the bridges agree on which channels are exposed.
3. After establishment, bridges create local channel pairs (one Send, one Recv on each side).
4. Producers and consumers on each host see local channels and communicate via the bridge transparently.
```

---

## 3. Message format

Each cross-host frame:

```capnp
struct CrossHostMessage {
  protocolVersion @0 :UInt32;
  flowId @1 :UInt64;          # local channel binding
  sequenceNumber @2 :UInt64;
  messagePayload @3 :Data;    # the user message, serialized
  capabilities @4 :List(CapabilityAttestation);
  signature @5 :Signature;    # over the above fields
}

struct CapabilityAttestation {
  remoteHost @0 :HostId;
  capability @1 :CapabilityRef;  # opaque reference, not the cap itself
  rights @2 :RightsBitmask;
  signedBy @3 :SignerId;
  signature @4 :Signature;
}
```

Each frame includes a sequence number (for FIFO preservation across reconnects) and a per-frame signature (operational key).

---

## 4. Capability translation (D14 semantics)

A capability is not transferred across the bridge — it cannot be, since each host has its own descriptor table. Instead:

- Producer-side bridge sees a local capability.
- Bridge mints a *remote capability attestation*: "Host A's process P holds cap C with rights R, as of time T".
- The attestation is signed by Host A's operational signing key.
- Consumer-side bridge receives the attestation.
- Consumer-side bridge mints a *local proxy capability*: a capability on Host B that represents the remote one.
- Operations on the proxy translate to RPC over the bridge.

This is the D14 distributed-capability mechanism.

---

## 5. Operations on remote capabilities

When a process on Host B invokes an operation on a remote-attested capability:
1. The local proxy receives the call.
2. The proxy forwards via the bridge: serialize operation + arguments.
3. Bridge A receives, invokes the actual capability on Host A.
4. Result is serialized back.
5. Proxy returns the result to caller.

Latency: a single cross-host operation costs one round-trip — typically 1–10 ms over LAN, 50–200 ms over WAN.

---

## 6. Failure modes

### 6.1 Bridge crash

If a bridge crashes:
- Local channels see `ChannelDead`.
- The supervisor restarts the bridge.
- On restart, the bridge reconnects to its peer.
- A grace window allows re-binding of local channels; otherwise channels die.

### 6.2 Network partition

If the network fails:
- Bridge detects via TCP/QUIC timeouts.
- Local channels see `ChannelDead` after a configurable grace period.
- Producers/consumers handle as crash.

### 6.3 Authentication failure

If the peer cannot prove identity:
- Bridge refuses connection.
- Audit log records the attempt.
- Local channels see `ConnectionRefused`.

---

## 7. Performance

| Metric | Budget | Substrate |
|---|---|---|
| LAN cross-host latency | ≤ 1 ms | bare-metal + 25G NIC |
| WAN cross-host latency | network-dominated (~10-200 ms) | varies |
| Throughput LAN | ≥ 10 Gbps | bare-metal |
| Connection establishment | ≤ 100 ms LAN; ≤ 1 s WAN | varies |

---

## 8. Phase 3+ feature

Cross-host IPC is a desirable feature (D14), not phase-1 or phase-2. The design is fixed in this doc so phase-1/2 implementations don't make choices incompatible with this future.

Phase 1: no cross-host IPC; processes are local only.
Phase 2: local IPC mature; cross-host bridge is sketched but not implemented.
Phase 3+: bridge implementation lands.

---

## 9. Open issues

| ID | Issue |
|---|---|
| BRG-O1 | Multiple-host federation — a cluster of N PaideiaOS hosts forms a distributed capability namespace. Each pair has a bridge; the topology is a complete graph or a star. Phase 4+. |
| BRG-O2 | Capability revocation propagation — when a host revokes a capability, how do other hosts learn? |
| BRG-O3 | Cross-host clock sync (for capability timestamps) — NTS/PTP integration. |
| BRG-O4 | Replay attacks on the wire — sequence numbers + signed messages prevent within-connection replay; cross-connection requires nonce coordination. |
| BRG-O5 | The transport choice per channel (TCP vs QUIC) — both supported; default should be decided. |

---

*End of document.*
