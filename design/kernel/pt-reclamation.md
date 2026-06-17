# PaideiaOS — Kernel: Page-Table Page Reclamation

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Timing of page-table page reclamation; race with concurrent maps. Addresses MEM-O6.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| PTR-D1 | Reclamation is deferred to a quiescent point | Safety |
| PTR-D2 | A page-table page is reclaimable when refcount=0 AND no TLB references exist | Standard |
| PTR-D3 | RCU-style grace period before reclamation | Race avoidance |
| PTR-D4 | Per-CPU reclamation queue | Performance |

---

## 1. Reclamation sequence

```
1. PT page becomes unreferenced (last unmap).
2. Mark page as "pending reclamation".
3. Wait for grace period (one TSC-deadline cycle, ~1ms).
4. Verify no CPU has the page in TLB.
5. Return page to memory pool.
```

---

## 2. Race with concurrent maps

If a new map operation races with reclamation:
- The new map allocates a fresh PT page.
- The old page stays in pending state until grace period.
- No conflict.

---

## 3. Open issues

| ID | Issue |
|---|---|
| PTR-O1 | Quiescent-point detection on systems with idle CPUs. |

---

*End of document.*
