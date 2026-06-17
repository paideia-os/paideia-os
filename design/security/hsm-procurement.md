# PaideiaOS — Security: HSM Procurement

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** HSM vendor selection criteria for the root signing key. Addresses PQ-O5.

---

## 0. Requirements

- FIPS 140-3 Level 3 or higher.
- SLH-DSA-256s support (or planned support).
- ≥2-of-3 quorum at session level.
- Tamper-evident packaging.
- Offline operation (no network).

---

## 1. Candidate vendors (2026 landscape)

| Vendor | SLH-DSA support | Quorum | Notes |
|---|---|---|---|
| Thales Luna HSM 7 | TODO: verify | Yes | Mature; widely deployed |
| Entrust nShield | TODO: verify | Yes | Mature |
| YubiHSM 2 (firmware ext) | Limited | Limited | Small form factor |
| AWS CloudHSM | Limited | Limited | Networked (rejected) |
| Utimaco SecurityServer | TODO: verify | Yes | Used in EU contexts |

---

## 2. Selection process

1. Solicit current product specs from each vendor.
2. Confirm SLH-DSA-256s support timeline.
3. Run procurement bid process.
4. Select on technical merit + budget.

---

## 3. Open issues

| ID | Issue |
|---|---|
| HSM-O1 | Vendor selection — defer until phase 3+ release-line setup. |
| HSM-O2 | Backup HSM strategy (replicated for disaster recovery). |

---

*End of document.*
