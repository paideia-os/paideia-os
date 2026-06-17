# PaideiaOS — Security: Root Ceremony Protocol

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Operational protocol for the root signing ceremony (per `pq-trust-root.md` §8.1). Addresses PQ-O7.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| RCR-D1 | ≥ 2-of-3 named participants physically present | PQ doc binding |
| RCR-D2 | Ceremony script documented step-by-step here | Repeatable |
| RCR-D3 | Video recording optional (per participant policy) | Privacy + traceability |
| RCR-D4 | Witness sign-off required | Authority chain |
| RCR-D5 | Annual recovery drill | Procedural exercise |

---

## 1. Pre-ceremony checklist

- [ ] HSM is operational and tested.
- [ ] All participants are scheduled and confirmed.
- [ ] The artifact to be signed (catalog update, release-line key delegation, etc.) is prepared.
- [ ] Witnesses are present.
- [ ] Audit log is operational.
- [ ] Backup HSM is operational (in case primary fails).

---

## 2. Ceremony script

```
Step 1: Convene
  - All participants and witnesses gather at the secure location.
  - Verify identities (government ID + project credential).
  - Confirm the artifact to be signed.

Step 2: Activate HSM
  - Power on HSM (if not already).
  - Each participant authenticates with their credential.
  - HSM session opens; 2-of-3 quorum confirmed.

Step 3: Verify artifact
  - The artifact bytes are read from a verified medium (signed USB drive).
  - The artifact's BLAKE3 hash is computed and verified against the expected.
  - All participants visually confirm the hash.

Step 4: Sign
  - The HSM signs the artifact's hash with the root key.
  - Signature is written to a verified output medium.

Step 5: Verify signature
  - The signature is verified against the published root public key.
  - All participants and witnesses confirm verification succeeds.

Step 6: Audit
  - An audit log entry is created:
    {
      timestamp,
      participants (names),
      witnesses (names),
      operation (sign / delegate / rotate),
      artifact_hash,
      signature
    }
  - Entry is signed by each participant and witness.

Step 7: Conclude
  - HSM session closed.
  - Output medium sealed in tamper-evident bag.
  - Audit log is filed.
```

---

## 3. Annual recovery drill

Per `pq-trust-root.md` §8.5, an annual drill exercises the recovery protocol:

1. Simulate loss of one participant.
2. Two remaining participants invoke the ceremony.
3. Issue a rotation delegation (test artifact, not production).
4. Verify the rotation produces a new root key.
5. Destroy the test artifact.
6. Update `design/security/operations.md` (future) with any procedural failures.

---

## 4. Lost-quorum recovery

If a participant becomes permanently unavailable:
1. Two remaining participants invoke the ceremony with `rotate` operation.
2. They establish a new root key with a new quorum (3 named participants).
3. The new root re-signs all active release-line delegations.
4. The old root is destroyed via HSM-side `key_destroy`, audited.

---

## 5. Open issues

| ID | Issue |
|---|---|
| RCR-O1 | Specific HSM vendor and model (per `hsm-procurement.md`, future). |
| RCR-O2 | Physical location requirements — secure facility. |
| RCR-O3 | Video recording policy — case-by-case decision. |
| RCR-O4 | Witness identity rules — who qualifies. |

---

*End of document.*
