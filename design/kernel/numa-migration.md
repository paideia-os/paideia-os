# PaideiaOS — Kernel: NUMA Memory Migration Semantics

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Detailed semantics of `migrate_cap` per memory-model.md §4.3. Addresses MEM-O3 — linearity interaction with migration.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| MIG-D1 | `migrate_cap` consumes the original capability (linear semantics) | Substructural discipline |
| MIG-D2 | Returns a fresh capability on the target NUMA domain | Same kind, different domain |
| MIG-D3 | The original physical pages are freed; new pages allocated on target | Copy-and-remap |
| MIG-D4 | Migration is atomic from the caller's view (single operation) | Simplicity |
| MIG-D5 | All page-table entries mapping the original are updated | Consistency |
| MIG-D6 | Audited per migration | Visibility |

---

## 1. `migrate_cap` operation

```paideia-as
fn migrate_cap(cap : MemCap ↓, target_numa : NumaDomain, policy : MigrationPolicy)
              -> MemCap !{mem_migrate, audit_log}
```

The `cap` parameter is consumed (linear). The result is a new MemCap on the target NUMA domain.

Policy parameter:
- `Copy`: copy contents to new location.
- `Move`: same as Copy but the original is verified unreachable before destruction.
- `Discard`: do not copy contents; new pages are zero-initialized.

---

## 2. Implementation sequence

```
1. Allocate target_numa pages (size matches cap's region).
2. Identify all page-table entries pointing to the original.
3. Acquire all required IPI locks for TLB shootdown.
4. Copy contents (if policy is Copy or Move).
5. Update PTEs atomically: change physical address to new pages.
6. TLB shootdown to all CPUs mapping the affected addresses.
7. Free original pages back to source NUMA pool.
8. Mint new MemCap descriptor pointing to new pages.
9. Audit log: source NUMA, target NUMA, size, policy.
10. Return new cap.
```

---

## 3. Linearity guarantees

The original cap is consumed; the type system enforces no double-migration. The new cap has the same rights bits as the original (rights are not modifiable during migration).

---

## 4. Performance

Per `memory-model.md` §13:
- Migration of 4 KiB page cross-socket: ≤ 1 µs.

Larger regions scale linearly.

---

## 5. Phase 2+ feature

Phase 1: no migration; processes pin to NUMA at start.
Phase 2: migration available.

---

## 6. Open issues

| ID | Issue |
|---|---|
| MIG-O1 | Migration with active DMA — the source pages may be DMA-active; need IOMMU coordination. |
| MIG-O2 | Migration of shared pages — refcount handling. |
| MIG-O3 | Migration policy presets — when to copy vs discard. |

---

*End of document.*
