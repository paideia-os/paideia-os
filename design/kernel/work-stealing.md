# PaideiaOS — Kernel: Work-Stealing Tuning

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Work-stealing parameters and rules. Addresses SCH-O4.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| WS-D1 | Steal threshold: priority < 192 | Don't steal critical work |
| WS-D2 | Max one steal per idle tick | Avoid thrashing |
| WS-D3 | Stolen SCs run with reduced cache locality penalty acknowledged | Trade-off |
| WS-D4 | Stolen SC's NUMA preference is updated only if explicit migrate | Per MEM-Q3 |

---

## 1. Steal eligibility

A CPU's runqueue entries are eligible for stealing when:
- SC priority < 192 (avoid stealing drivers, kernel-supervisor work).
- Entry was enqueued > 10ms ago (avoid steal-and-immediately-yield).
- SC has positive budget.

---

## 2. Steal target selection

When multiple peer CPUs have stealable work:
- Prefer peer with the lowest aggregate priority (most likely to benefit from offload).
- Among ties, prefer peer with the most stealable entries.

---

## 3. Open issues

| ID | Issue |
|---|---|
| WS-O1 | Adaptive thresholds based on workload measurement. |

---

*End of document.*
