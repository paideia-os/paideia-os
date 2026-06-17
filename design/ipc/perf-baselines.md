# PaideiaOS — IPC: Performance Baselines

**Status:** Placeholder
**Date:** 2026-06-17
**Scope:** Performance baseline measurements for the wait-free dataflow IPC primitive. Will be populated when the phase-2 implementation lands and runs on bare metal. Addresses IPC-O4.

**Hard inputs:**
- `wait-free-dataflow.md` §12 — aspirational budgets.

---

## 0. Status

This document is a placeholder. The actual baselines come from measurements taken once:
1. The phase-2 paideia-as IPC implementation is functional.
2. A bare-metal CI runner exists.
3. The measurement harness is built.

Estimated phase: late phase 2 / early phase 3.

---

## 1. Aspirational targets (from `wait-free-dataflow.md` §12)

| Operation | Target |
|---|---|
| Same-core SPSC enqueue + dequeue (inline message) | ≤ 100 ns |
| Cross-core SPSC enqueue + dequeue (inline message) | ≤ 300 ns |
| Cross-socket SPSC enqueue + dequeue (inline message) | ≤ 1 µs |
| Sync session round-trip (↑Req . ↓Resp) | ≤ 500 ns |
| Slot-cap return on dequeue | ≤ 20 ns additional |
| Trace marker emission | ≤ 10 ns |

---

## 2. Measurement methodology

When measurements are taken:
- Hardware: Sapphire Rapids workstation (aspirational tier per dev-env §1.2).
- Runs: 100K iterations per measurement.
- Statistics: median + p99 + standard deviation.
- Power: bare-metal, no other workload, CPU power-state pinned to maximum performance.
- Mitigations: both with full Q15 mitigations and with `relax-mitigations` for comparison.

---

## 3. Baselines (to be filled in)

| Operation | Hardware | Mitigations | Median | p99 | Std dev | Date measured |
|---|---|---|---|---|---|---|
| Same-core enqueue+dequeue | TBD | TBD | TBD | TBD | TBD | TBD |
| Cross-core enqueue+dequeue | TBD | TBD | TBD | TBD | TBD | TBD |
| ... | ... | ... | ... | ... | ... | ... |

---

## 4. Regression tracking

Each measurement is committed to this document; regressions exceeding 10% from the established baseline trigger investigation.

---

*End of placeholder.*
