# PaideiaOS — Kernel: SC Donation Under Failure

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Robust SC donation recovery when donor or consumer crashes mid-RPC. Addresses SCH-O5.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| SCD-D1 | Per-CPU donor shadow: O(1) lookup of who donated to whom | Performance |
| SCD-D2 | Donor crash → consumer's SC reverts immediately on next schedule | Fail-fast |
| SCD-D3 | Consumer crash → donor SC released; donor resumed with error | Fail-fast |

---

## 1. Per-CPU donor shadow

Each CPU maintains an array of (consumer_TCB, donor_TCB, original_SC) for active donations. The array is bounded (rare to have > 64 nested donations); O(1) lookup.

---

## 2. Donor crash

```
1. Kernel detects donor TCB death.
2. Walk per-CPU shadows for entries where donor = this TCB.
3. For each entry: restore consumer's original SC.
4. Consumer continues on its own SC (which may have lower priority).
```

---

## 3. Consumer crash

```
1. Kernel detects consumer TCB death.
2. Walk per-CPU shadows for entries where consumer = this TCB.
3. For each entry: release the donated SC back to donor.
4. Wake donor with RpcAborted.
```

---

## 4. Performance vs full TCB walk

Per-CPU shadow is O(1); the original full TCB walk (per `wait-free-dataflow.md` §7.3) was O(n). The shadow approach is preferred.

---

## 5. Open issues

| ID | Issue |
|---|---|
| SCD-O1 | Cross-CPU shadow synchronization. |

---

*End of document.*
