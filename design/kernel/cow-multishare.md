# PaideiaOS — Kernel: CoW Multi-Share Correctness

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Correctness of CoW when N processes share, multiple write simultaneously. Addresses MEM-O7.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| CMS-D1 | Simultaneous writers each trigger separate CoW | Standard |
| CMS-D2 | First writer wins; subsequent writers get their own copies | Linearizable |
| CMS-D3 | Page-fault handler holds a per-page lock during copy | Race avoidance |

---

## 1. Scenario

N processes share an affine read-only cap to a page. They all attempt to write simultaneously from different CPUs.

---

## 2. Resolution

```
1. CPU A page-faults on write.
2. CPU A acquires the page's per-page lock.
3. CPU B page-faults on write to same page.
4. CPU B blocks on lock.
5. CPU A allocates fresh page, copies, remaps for CPU A's process, decrements shared_count.
6. CPU A releases lock.
7. CPU B acquires lock.
8. CPU B sees shared_count > 1 still (others holding affine caps); allocates another fresh page for CPU B's process.
9. CPU B releases lock.
10. If shared_count reaches 1, the last holder regains write access (PTE upgraded).
```

---

## 3. Linearizability

The series of writes appears linearized at the lock acquisitions; each writer sees consistent state.

---

## 4. Open issues

| ID | Issue |
|---|---|
| CMS-O1 | Lock contention under heavy CoW — investigate fine-grained locking. |

---

*End of document.*
