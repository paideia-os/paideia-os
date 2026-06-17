# PaideiaOS — Security: TCG TPM PQ Extensions Tracking

**Status:** Tracking document
**Date:** 2026-06-17
**Scope:** Status of TCG's TPM PQ-extension work. Addresses PQ-O2.

---

## 0. Current status (2026-06-17)

- TCG has a working group on PQ TPM extensions.
- ML-DSA and SLH-DSA support drafted but not yet in TPM 2.0 spec.
- `swtpm` does not yet expose PQ primitives.

## 1. Implication for PaideiaOS

Until TCG ratifies + `swtpm`/hardware TPMs ship PQ support:
- TPM holds classical attestation keys (ECDSA-P384).
- PQ signing in the enclave; TPM attests the enclave's identity.

## 2. Re-evaluation cadence

Quarterly. When PQ TPM support ships:
- Migrate root key storage if appropriate.
- Update PQ trust root doc.

---

*End of tracking doc.*
