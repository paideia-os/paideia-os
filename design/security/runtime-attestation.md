# PaideiaOS — Security: Runtime Capability Attestation

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Detail specification of the runtime capability-attestation feature (per `pq-trust-root.md` §9.4). Addresses PQ-O11 and PQ-O14. Phase 2 deliverable.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| RTA-D1 | The supervisor signs runtime attestation quotes | Authority |
| RTA-D2 | Quote format includes process id, capability set, timestamp, nonce | Standard |
| RTA-D3 | Operational signing key (hybrid Ed25519 + ML-DSA-65) signs the quote | PQ doc binding |
| RTA-D4 | Sealed caps appear in quotes as opaque references (not introspectable) | Sealing preserved |
| RTA-D5 | Phase-2 deliverable | Scope realism |

---

## 1. Quote format

```capnp
struct CapabilityQuote {
  processId @0 :ProcessId;
  capabilitySet @1 :List(CapabilityRef);
  timestamp @2 :UInt64;        # nanoseconds since epoch
  nonce @3 :Data;              # caller-provided
  supervisorSig @4 :Signature; # over the above
}

struct CapabilityRef {
  kind @0 :BaseKind;           # always public
  derivedKind @1 :Text;        # may be empty for opaque
  rightsBitmask @2 :UInt64;    # may be 0 for sealed caps
  isSealed @3 :Bool;
  capId @4 :CapId;             # opaque kernel-side id
  derivationPath @5 :List(CapId);
}
```

---

## 2. Sealed capabilities in quotes

A sealed cap appears in the quote with:
- `kind` set (public).
- `derivedKind` empty (hidden).
- `rightsBitmask` set to 0 (hidden).
- `isSealed = true`.
- `capId` set (opaque reference).
- `derivationPath` truncated to the seal boundary.

The verifier can confirm the cap exists and is sealed; cannot learn its rights or derived kind.

---

## 3. Quote request

```paideia-as
fn request_capability_quote(target_process : ProcessCap,
                            nonce : Bytes)
                           -> CapabilityQuote !{attest_runtime, audit_log}
```

The caller provides a nonce (prevents replay) and a `target_process` cap. The supervisor:
1. Verifies the caller's authority.
2. Reads `target_process`'s current capability set.
3. Constructs the quote.
4. Signs with the operational key.
5. Returns.

---

## 4. Quote verification

A remote verifier:
1. Receives the quote.
2. Verifies the supervisor's signature (using the trust chain).
3. Verifies the nonce matches what the verifier sent.
4. Verifies the timestamp is recent (within an acceptable window).
5. Inspects the capability set per the verifier's policy.

---

## 5. Use cases

- Federated capability verification (D14).
- Remote-debugging consent ("does this process really have the debug capability?").
- Audit-driven verification ("does this process hold the capability it claimed to?").

---

## 6. Phase 2 implementation

The runtime attestation is a phase-2 deliverable. Phase 1 has no capability system; phase 2 builds the capability system and the attestation together.

---

## 7. Open issues

| ID | Issue |
|---|---|
| RTA-O1 | The exact "recent timestamp" window — minutes? Hours? Per-verifier policy. |
| RTA-O2 | Anti-replay across nonces — supervisor-side rate limiting. |
| RTA-O3 | The interaction with capability migration — a cap that just moved NUMA appears in the quote. |
| RTA-O4 | Performance — the quote is several KB; signing takes ~100 µs (ML-DSA-65). |

---

*End of document.*
