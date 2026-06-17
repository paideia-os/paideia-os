# PaideiaOS — Kernel: Huge-Page Strategy

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Strategy and tuning for 2 MiB and 1 GiB page kinds. Addresses MEM-O8.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| HP-D1 | 1 GiB pages: phase 2+ feature; phase 1 uses 4K and 2M | Scope realism |
| HP-D2 | NUMA-aware huge-page pools: pre-allocate at boot per NUMA domain | Avoid fragmentation |
| HP-D3 | Per-CPU NUMA direct map uses 1 GiB pages where the NUMA region's base is 1 GiB-aligned | Performance optimization |
| HP-D4 | No transparent promotion: 1 GiB cap must be requested explicitly via retype | Predictability |
| HP-D5 | 1 GiB cap can be split into 512 × 2 MiB caps via `split_page` operation | Flexibility |

---

## 1. Boot-time pre-allocation

At boot, the kernel reserves huge-page memory per NUMA domain:
- 50% of memory available as 1 GiB pages.
- 30% of memory available as 2 MiB pages.
- 20% of memory available as 4 KiB pages.

The split is policy-driven; supervisor can override.

Pages are typed at allocation time. A 1 GiB page is *not* automatically 512 × 2 MiB pages; it is a single 1 GiB block.

---

## 2. Use cases for 1 GiB pages

- The per-CPU NUMA direct map.
- Large allocations (audit ring buffers, NIC ring buffers).
- Persistent-memory regions (when CXL.mem ships).
- Database-style applications (a future PaideiaOS workload).

---

## 3. Use cases for 2 MiB pages

- IPC channel slot arrays (per IPC primitive).
- PAX module images.
- Filesystem buffer pool.
- Page-table page allocations themselves.

---

## 4. 4 KiB pages

- Driver MMIO mappings.
- Small kernel objects.
- Page-table entries (not the pages themselves).

---

## 5. Split operation

```paideia-as
fn split_page(cap : Page1GCap ↓) -> Array<Page2MCap, 512> !{page_split, audit_log}
```

Consumes a 1 GiB page; produces 512 × 2 MiB page caps over the same physical region.

A symmetric `split_page_2m_to_4k` exists.

There is no `join_pages` reverse operation (joining requires verifying contiguity and alignment; not supported phase 2; possibly phase 3+).

---

## 6. Open issues

| ID | Issue |
|---|---|
| HP-O1 | Boot policy ratios — 50/30/20 is a guess; tune from measurements. |
| HP-O2 | The 1 GiB pre-allocation may waste memory on small systems; per-system policy. |
| HP-O3 | Join operation feasibility — phase 3+ if pursued. |

---

*End of document.*
