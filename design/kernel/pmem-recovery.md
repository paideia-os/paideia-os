# PaideiaOS — Kernel: Persistent Memory Recovery

**Status:** Draft v0.1 (phase 3+)
**Date:** 2026-06-17
**Scope:** PMem region recovery on power-fail. Addresses MEM-O10.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| PMR-D1 | PMem regions survive power-fail | By definition |
| PMR-D2 | At boot, pager re-attaches surviving PMem caps | Standard |
| PMR-D3 | Region metadata records the owning process / identity | Standard |
| PMR-D4 | If owning process is gone: region is orphan; supervisor decides | Policy |

---

## 1. Recovery sequence

```
1. Boot.
2. Kernel discovers PMem regions via ACPI / NFIT table.
3. Pager reads each region's metadata header.
4. For each region:
   a. Look up the owning process in the registry.
   b. If process exists: re-mint PersistentMemCap, hand to process.
   c. If process gone: mark region orphan; supervisor decides:
      - Restore from snapshot.
      - Discard.
      - Hand to recovery service.
```

---

## 2. Open issues

| ID | Issue |
|---|---|
| PMR-O1 | Orphan-region recovery policy. |
| PMR-O2 | Multi-region transactions (atomicity across PMem regions). |

---

*End of document.*
