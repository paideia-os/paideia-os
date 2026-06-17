# PaideiaOS — Capabilities: Distributed Extension (D14)

**Status:** Draft v0.1 — phase 3+ feature
**Date:** 2026-06-17
**Scope:** Architectural sketch of the distributed-capability extension reserved for kind id 14 in `linearity-and-tags.md` §3.1. Pairs with `ipc/cross-host-bridge.md`. Phase 3+ implementation; the slot is reserved now to avoid future enum churn.

**Hard inputs:**
- `linearity-and-tags.md` §3.1 reserved slot #14.
- `ipc/cross-host-bridge.md` — cross-host bridge for IPC transport.
- D14 from feature inventory.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| DIST-D1 | Distributed capabilities are a phase 3+ feature | Scope realism |
| DIST-D2 | A distributed capability is a *local proxy* to a remote capability | Local kernel manages local proxies |
| DIST-D3 | Proxy operations forward via the cross-host bridge | Per ipc/cross-host-bridge.md |
| DIST-D4 | The base kind on each host is the proxy kind; the wire carries kind + nonce | Standard pattern |
| DIST-D5 | Revocation propagates across hosts via the bridge | Coordination required |

---

## 1. The local proxy

A *distributed proxy capability* is a normal local capability whose descriptor records:
- The remote-host id.
- The remote-cap reference (an opaque token).
- The signed attestation from the remote host's operational key.
- The expected rights and base kind on the remote host.

Operations on the proxy translate to RPC over the cross-host bridge.

---

## 2. Proxy creation

1. Host A's process P holds a local capability `cap_A`.
2. P wants to grant remote-use to a process on Host B.
3. P invokes `grant_remote(cap_A, target_host=B, target_process=Q)`.
4. The supervisor on A creates a remote-capability attestation (signed).
5. The bridge forwards to Host B's bridge.
6. Host B's supervisor receives, validates the signature, mints a local proxy with the attestation in its descriptor.
7. Process Q on Host B receives the proxy.

---

## 3. Proxy invocation

When Q invokes an operation on the proxy:

```
1. The kernel on B sees the proxy's kind (reserved kind 14).
2. Dispatch to the cross-host bridge.
3. Bridge serializes the operation + arguments.
4. Bridge B sends to Bridge A.
5. Bridge A receives, invokes the actual cap_A on Host A.
6. Bridge A sends result back.
7. Bridge B returns result to Q.
```

Latency: one round-trip across the network.

---

## 4. Revocation

When Host A's process P revokes `cap_A`:
1. The supervisor on A bumps the epoch.
2. Any future bridge RPC referencing the cap returns `Revoked`.
3. The bridge on A pushes a revocation notification to Host B.
4. Host B's supervisor bumps the proxy's epoch.
5. Process Q's next operation on the proxy fails.

The revocation may be delayed by network latency; Q may see one or more `Revoked` responses on in-flight ops, then proxy-side revocation.

---

## 5. Federation

A cluster of PaideiaOS hosts forms a *federation*: each host has bidirectional bridges to a subset of others.

The federation membership is configured by the supervisor's policy; new members are explicitly admitted (their operational keys added to the local trust set).

---

## 6. Phase 3+ implementation

This document is a sketch. The actual implementation requires:
- Cross-host bridge maturity (cross-host-bridge.md).
- Operational key infrastructure (security/pq-trust-root.md).
- Federation management protocols (TBD).
- Performance characterization (cross-host ops are 1000× slower than local).

---

## 7. Open issues

| ID | Issue |
|---|---|
| DIST-O1 | Per-operation authorization on the remote side — beyond holding the proxy. |
| DIST-O2 | Cross-host audit log consistency. |
| DIST-O3 | Time bounding of attestations — the attestation is signed at time T; how long is it valid? |
| DIST-O4 | The federation's recovery from partition — split-brain semantics. |
| DIST-O5 | Operating system version compatibility — different PaideiaOS versions in a federation. |

---

*End of document.*
