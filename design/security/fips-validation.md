# PaideiaOS — Security: NIST FIPS Validation

**Status:** Decision document
**Date:** 2026-06-17
**Scope:** Whether to pursue NIST FIPS 203/204/205 validation for PaideiaOS PQ implementations. Addresses PQ-O12.

---

## 0. Decision

**Pursue validation at phase 3, conditional on resources.**

---

## 1. Validation budget

- Lab fees: $50–200K (validator + testing).
- Timeline: 6–18 months.
- Engineering effort: significant (test vector compliance, code freezes).

## 2. Benefit

- Required for some regulated deployments.
- Credibility / external trust signal.
- Forces rigorous testing.

## 3. Cost

- Time and money.
- Constrains how often the validated component can change.
- Once validated, modifications require re-validation.

## 4. Recommendation

- Phase 1–2: claim conformance (clearly marked "claimed conformant").
- Phase 3: if project is funded, pursue validation for ML-DSA-65 and ML-KEM-1024 primary use cases.
- Phase 4+: extend to other primitives as needed.

---

## 5. Open issues

| ID | Issue |
|---|---|
| FIPS-O1 | Specific NVLAP lab selection. |
| FIPS-O2 | Validation budget allocation. |

---

*End of document.*
