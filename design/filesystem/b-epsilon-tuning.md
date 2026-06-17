# PaideiaOS — Filesystem: B-epsilon Tree Parameter Tuning

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Concrete value selection for the B-epsilon parameter ε and node size. Addresses FS-O5.

---

## 0. Parameters

- **B**: node size in bytes (typically 2048-4096 for cache-line-friendly).
- **ε**: tuning parameter ∈ (0, 1); each node has B^ε children.
- **Buffer size per internal node**: B - B^ε × pointer_size.

---

## 1. Initial selection

- B = 4096 (matches one 4 KiB page).
- ε = 0.5 → B^ε = ~64 children.
- Pointer size: 8 bytes → 64 × 8 = 512 bytes for child pointers.
- Buffer size: 4096 - 512 = 3584 bytes for pending updates.

---

## 2. Tuning under load

Phase 2: ship initial parameters; collect telemetry.
Phase 3: tune based on workload patterns.

---

## 3. Trade-offs

- Higher ε: more children per node, smaller buffer. Closer to standard B-tree (write-optimization decreases).
- Lower ε: fewer children, larger buffer. Stronger write-optimization but deeper tree.

---

## 4. Open issues

| ID | Issue |
|---|---|
| BET-O1 | Per-workload parameter selection — auto-tune. |

---

*End of document.*
