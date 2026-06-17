# PaideiaOS — Kernel: Refill Timer Wheel

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Hierarchical timer wheel for SC refill scheduling and other deadline timers. Addresses SCH-O11.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| TW-D1 | TSC-deadline based (uses Intel TSC-DEADLINE MSR) | Hardware support |
| TW-D2 | Hierarchical wheel: ms, s, minute levels | Scales |
| TW-D3 | Minimum granularity: 1 µs | Per scheduler.md §2.1 |
| TW-D4 | Per-CPU wheels | Multicore-pure |

---

## 1. Architecture

```
   ms wheel: 1000 buckets at 1 ms resolution
   s wheel: 60 buckets at 1 s resolution
   minute wheel: 60 buckets at 1 min resolution
```

A timer is placed in the bucket matching its expiration. Per tick, the current bucket's timers fire; rotation cascades from longer to shorter wheels.

---

## 2. Wheel operations

| Op | Cost |
|---|---|
| Add timer | O(1) amortized |
| Cancel timer | O(1) |
| Per-tick processing | O(timers expiring this tick) |

---

## 3. TSC drift handling

Inter-CPU TSC synchronization assumed (Intel guarantees on modern hardware). Drift detection at boot; logged if detected.

---

## 4. Open issues

| ID | Issue |
|---|---|
| TW-O1 | Timer wheel resolution under low-load (skip empty buckets). |

---

*End of document.*
