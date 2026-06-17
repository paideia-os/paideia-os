# PaideiaOS — Filesystem: Performance Baselines

**Status:** Placeholder
**Date:** 2026-06-17
**Scope:** Performance baselines for the CoW filesystem. Addresses FS-O14.

---

## 0. Status

Placeholder. Populated when phase-2 implementation runs on bare metal with NVMe.

---

## 1. Aspirational targets (from `cow-design.md` §14)

| Operation | Target |
|---|---|
| Single-file read 4 KiB cache hit | ≤ 1 µs |
| Single-file read cold | ≤ 50 µs |
| Single-file write 4 KiB buffered | ≤ 2 µs |
| Transaction commit (small) | ≤ 100 ms |
| Transaction commit (large) | ≤ 200 ms |
| Directory lookup (HAMT, 1M entries) | ≤ 5 µs |
| Snapshot creation | ≤ 10 µs |
| Merkle verification per node | ≤ 50 ns |
| BLAKE3 throughput | ≥ 2 GB/s per core |
| Zstd compression | ≥ 500 MB/s per core |

---

*End of placeholder.*
