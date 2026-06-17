# PaideiaOS — Security: Release-Line Key Management

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Detailed key management for the release-line signing tier. Addresses PQ-O1 (KMS for ML-DSA) follow-up.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| RKM-D1 | Release-line key stored in networked HSM or PQ-aware KMS | Per PQ doc §5.1 |
| RKM-D2 | If PQ-aware KMS unavailable: self-hosted networked HSM | Fallback |
| RKM-D3 | Key rotates annually (per PQ-Q9) | Cadence |
| RKM-D4 | Backup key generated and offline-stored | Disaster recovery |

---

## 1. Storage options

| Option | Pros | Cons |
|---|---|---|
| Cloud KMS (AWS, GCP, Azure) | Managed; mature | ML-DSA support uncertain in 2026 |
| Self-hosted networked HSM | Full control | Operational burden |
| Hybrid: classical in cloud KMS + PQ self-hosted | Reuse existing | Two systems |

---

## 2. Recommendation

Self-hosted networked HSM until cloud KMS PQ support matures.

---

## 3. Operations

- Initial setup: ceremony similar to root (smaller scale).
- Daily use: automated via CI release pipeline (signing requests from release-cutter role).
- Rotation: annually + on suspicion.

---

## 4. Open issues

| ID | Issue |
|---|---|
| RKM-O1 | Specific HSM model — depends on phase 3+ timeline. |
| RKM-O2 | KMS provider re-evaluation in 2027–2028. |

---

*End of document.*
