# PaideiaOS — Kernel: Hybrid Core Placement Under Contention

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Placement policy when all P-cores are full and Any-class SCs await. Addresses SCH-O6.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| HCP-D1 | If all P-cores full and Any-class SC waiting, place on best E-core | Avoid starvation |
| HCP-D2 | Promote E-core SCs to P-core when P-core opens | Performance preferred |
| HCP-D3 | Sticky bias: a thread that ran on P-core prefers P-core next | Locality |

---

## 1. Placement decision tree

```
For SC with core_class = Any:
  if any P-core has runqueue slack: place on least-loaded P-core
  else if any E-core has runqueue slack: place on least-loaded E-core
  else: queue on least-loaded P-core; preempt lowest-priority

For SC with core_class = P-only:
  if any P-core has slack: place
  else: queue on least-loaded P-core; preempt if higher priority
  reject placement on E-core (return error)

For SC with core_class = E-only:
  symmetric
```

---

## 2. Promotion

When a P-core idles and an Any-class SC is running on an E-core:
- Periodic check (every 100 ms) migrates the SC to the P-core.
- Preserves NUMA preference.

---

## 3. Open issues

| ID | Issue |
|---|---|
| HCP-O1 | Tuning the promotion interval. |

---

*End of document.*
