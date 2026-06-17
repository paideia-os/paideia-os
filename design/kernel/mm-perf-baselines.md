# PaideiaOS — Kernel: Memory Management Performance Baselines

**Status:** Placeholder
**Date:** 2026-06-17
**Scope:** Performance baselines for the memory subsystem. Addresses MEM-O14.

---

## 0. Status

Placeholder. Populated when phase-2 implementation runs on bare metal.

---

## 1. Aspirational targets (from `memory-model.md` §13)

| Operation | Target |
|---|---|
| Kernel direct-map access (local NUMA) | ~1 cycle (post-TLB-hit) |
| Cross-NUMA direct-map miss | ~200 cycles |
| Page-table install (one entry) | ~50 ns |
| Retype memory → page table | ~150 ns |
| Page fault round-trip to warm pager | ≤ 1 µs |
| Cold page fault | ≤ 5 µs |
| CoW write fault | ≤ 3 µs |
| PCID-switching context switch | ≤ 300 cycles |
| KPTI CR3 switch overhead | ≤ 150 cycles |
| TLB shootdown one-page invalidate | ≤ 500 ns |
| NUMA migrate_cap (4 KiB cross-socket) | ≤ 1 µs |

---

*End of placeholder.*
