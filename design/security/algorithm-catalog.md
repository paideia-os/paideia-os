# PaideiaOS — Security: Algorithm Catalog

**Status:** Living document — schema specified; entries grow over time
**Date:** 2026-06-17
**Scope:** The authoritative catalog of cryptographic schemes used in PaideiaOS. Each scheme has a stable identifier; the catalog tracks active, deprecated, and revoked schemes. Addresses PQ-O6.

**Hard inputs:**
- `pq-trust-root.md` §11 — algorithm-agile signing with versioned identifiers + multi-algorithm safety net.
- `pq-trust-root.md` §11.2 — catalog source-of-truth.

---

## 0. Catalog discipline

- Each scheme has a unique stable identifier (`scheme_id`).
- Schemes are immutable once published; modifications produce a new scheme_id.
- Statuses: `active`, `deprecated`, `revoked`. Once published, status changes (active → deprecated → revoked) are signed by the root.
- The catalog is itself a signed artifact (SLH-DSA-256s signed by the root); verifiers consult it via the public key manifest.

---

## 1. Catalog file format

`design/security/algorithm-catalog.toml` (the authoritative source):

```toml
[catalog]
version = "0.1.0"
last_updated = "2026-06-17"
catalog_signature = "<root-signed signature bytes>"

[scheme."paideia-pq-hybrid-v1"]
description = "Hybrid Ed25519 + ML-DSA-65 signature"
classical = "ed25519"
pq = "ml-dsa-65"
combiner = "concat-then-sign"
status = "active"
introduced = "2026-06-17"
deprecated = ""
revoked = ""

[scheme."paideia-pq-hash-v1"]
description = "SLH-DSA-128s signature for boot chain"
pq = "slh-dsa-128s"
status = "active"
introduced = "2026-06-17"

[scheme."paideia-pq-hash-v2-root"]
description = "SLH-DSA-256s signature for root"
pq = "slh-dsa-256s"
status = "active"
introduced = "2026-06-17"

[scheme."paideia-pq-kem-v1"]
description = "Hybrid X25519 + ML-KEM-1024 KEM"
classical = "x25519"
pq = "ml-kem-1024"
combiner = "concat-then-kdf"
status = "active"
introduced = "2026-06-17"

[scheme."paideia-classical-v1"]
description = "Ed25519 signature for ephemeral CI use"
classical = "ed25519"
status = "active"
introduced = "2026-06-17"
```

---

## 2. Initial catalog (per `pq-trust-root.md` §11.2)

| scheme_id | Description | Use |
|---|---|---|
| `paideia-pq-hybrid-v1` | Ed25519 + ML-DSA-65 | Release artifacts, operational signing |
| `paideia-pq-hash-v1` | SLH-DSA-128s | Boot chain |
| `paideia-pq-hash-v2-root` | SLH-DSA-256s | Root (long-lived) |
| `paideia-pq-kem-v1` | X25519 + ML-KEM-1024 | All confidentiality (TLS, IPC bridge, etc.) |
| `paideia-classical-v1` | Ed25519 only | Ephemeral CI inter-stage |

---

## 3. Adding a new scheme

When a new primitive ships (e.g., a future NIST PQ standard):
1. Allocate a new `scheme_id`.
2. Add catalog entry with `status = "active"` and current date.
3. Sign the new catalog version with the root.
4. Publish.
5. The algorithm-agility mechanism (§11 of PQ doc) allows deployment.

---

## 4. Deprecating a scheme

When cryptanalysis weakens a primitive:
1. Status changes `active → deprecated`.
2. Sign the new catalog.
3. Existing artifacts using this scheme continue to verify but are flagged.
4. New artifacts use a successor scheme.
5. Rotation cadence + event-driven rotation phases out the deprecated scheme.

---

## 5. Revoking a scheme

When a scheme is decisively broken:
1. Status changes `deprecated → revoked`.
2. Sign the new catalog.
3. Existing artifacts using this scheme are no longer trusted.
4. Verifiers reject signatures using revoked schemes.

---

## 6. Verifier discipline

A verifier:
1. Reads the artifact's signature header to extract `scheme_id`.
2. Consults the local catalog for the scheme's status.
3. If `active`: verify normally.
4. If `deprecated`: verify but emit warning.
5. If `revoked`: reject.
6. If `scheme_id` not in catalog: reject (unknown scheme).

The catalog must be kept up to date on every verifier; this is the responsibility of the supervisor.

---

## 7. Open issues

| ID | Issue |
|---|---|
| CAT-O1 | Catalog distribution — how does a fresh PaideiaOS install get the initial catalog? Hardcoded for v0.x; updated via release process. |
| CAT-O2 | The catalog's wire format for signing — TOML is human-friendly; canonical JSON or CBOR for signing. |
| CAT-O3 | Cross-version compatibility — can a v0.1.0 verifier read a v0.2.0 catalog? Yes (new fields are additive). |
| CAT-O4 | Replay protection on catalog updates — the supervisor's last-known catalog version is checked. |

---

*End of document.*
