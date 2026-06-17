# PaideiaOS — Drivers: Driver Binary Signing and Verification

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Driver-binary signature verification on load. Addresses DR-O7.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| DSG-D1 | Every driver PAX binary is signed with the release-line key | Per PQ doc §3 |
| DSG-D2 | Supervisor verifies on load; refuses unsigned | Pillar 6 |
| DSG-D3 | Signature uses hybrid Ed25519 + ML-DSA-65 (paideia-pq-hybrid-v1) | Standard |
| DSG-D4 | The release-line cert chains to root per PQ doc §3 | Trust chain |

---

## 1. Loading sequence

```
1. Supervisor reads driver PAX from disk.
2. Verifies PAX magic and version.
3. Reads PAX signature.
4. Resolves the signer's public key via the algorithm catalog (per security/algorithm-catalog.md).
5. Verifies signature (hybrid: both Ed25519 and ML-DSA-65 must pass).
6. Verifies the release-line cap's chain to root.
7. If verified: load and start driver.
8. If failed: log to audit, refuse.
```

---

## 2. Phase 1 vs 2

Phase 1: no driver signing; drivers are part of the kernel build.
Phase 2: driver-signing comes online with the PQ trust root.

---

## 3. Open issues

| ID | Issue |
|---|---|
| DSG-O1 | Local development override — for development, allow self-signed drivers. |
| DSG-O2 | Signature caching to avoid re-verification on every load. |

---

*End of document.*
