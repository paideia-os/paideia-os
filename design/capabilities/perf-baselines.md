# PaideiaOS — Capabilities: Performance Baselines

**Status:** Placeholder
**Date:** 2026-06-17
**Scope:** Performance baseline measurements for the capability system. Addresses CAP-O11. Populated when phase-2 implementation lands and runs on bare metal.

---

## 0. Status

Placeholder. Actual measurements come from phase-2 implementation on a bare-metal CI runner.

---

## 1. Aspirational targets (from `linearity-and-tags.md` §14)

| Operation | Target |
|---|---|
| Hardware-LAM verify (epoch + kind) | ≤ 5 ns |
| Software-LAM verify (mask + check) | ≤ 12 ns |
| Mint (subset, no retype) | ≤ 100 ns |
| Retype (memory → IPC endpoint) | ≤ 200 ns |
| Revoke (epoch bump only) | ≤ 30 ns |
| Revoke subtree (10 descendants) | ≤ 1 µs |
| Seal | ≤ 50 ns |
| Unseal | ≤ 50 ns |
| Epoch exhaustion migration (10 descendants) | ≤ 5 µs |
| Audit entry emission | ≤ 10 ns |

---

## 2. Methodology

Same as `ipc/perf-baselines.md` §2.

---

## 3. Baselines (to be filled in)

| Operation | Hardware | Median | p99 | Std dev | Date measured |
|---|---|---|---|---|---|
| ... | ... | ... | ... | ... | ... |

---

*End of placeholder.*
