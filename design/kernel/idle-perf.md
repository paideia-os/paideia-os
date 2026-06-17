# PaideiaOS — Kernel: Software-Fallback Idle Performance

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Cost analysis of the software-fallback idle path on pre-WAITPKG hardware. Addresses SCH-O7.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| IP-D1 | Pre-WAITPKG silicon: PAUSE spin loop for short waits, HLT for longer | Pragmatic |
| IP-D2 | Long-wait latency regresses by ~500 ns vs WAITPKG | Acknowledged |
| IP-D3 | Short-wait latency regresses by ~1 µs vs WAITPKG | Acknowledged |

---

## 1. Performance comparison

| Wait | WAITPKG | Software fallback |
|---|---|---|
| < 50 µs | TPAUSE (~10-50 ns wake) | PAUSE spin (busy CPU) |
| 50 µs – 1 ms | UMWAIT (~100-500 ns wake) | Spin then HLT (~1 µs wake) |
| > 1 ms | MWAIT C1 (~1 µs wake) | HLT (~1 µs wake) |

---

## 2. Power impact

- Spin loop burns power (CPU not idle).
- On battery, this is noticeable; on AC, less critical.

---

## 3. Mitigation

- Detect battery; tier the policy toward HLT-only on battery.
- Alert user that energy efficiency is degraded.

---

## 4. Open issues

| ID | Issue |
|---|---|
| IP-O1 | Battery-aware policy switching. |

---

*End of document.*
