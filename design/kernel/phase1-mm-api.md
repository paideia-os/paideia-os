# PaideiaOS — Kernel: Phase-1 Memory Management API

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Phase-1 minimal memory-management interface before page-table-as-capability and CoW emergence come online in phase 2. Addresses MEM-O13.

**Hard inputs:**
- `memory-model.md` §12 — phase-1 vs phase-2 split.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| P1MM-D1 | Page tables are kernel-internal data structures (not capabilities) | Type system not ready |
| P1MM-D2 | Manual allocation per AS via direct kernel calls | Simpler |
| P1MM-D3 | 4K and 2M pages only; no 1G yet | Scope realism |
| P1MM-D4 | No CoW; copy-on-write deferred to phase 2 | Out of scope |
| P1MM-D5 | No KPTI in phase 1 (dev workstations only; trusted) | Pragmatic |
| P1MM-D6 | No CXL/PMem support | Out of scope |
| P1MM-D7 | Critical-structures region established at fixed VA from phase 1 | Required for kernel |

---

## 1. Phase-1 operations

```nasm
; Allocate physical memory.
; Inputs: RDI = size in bytes (rounded up to page), RSI = NUMA hint
; Output: RAX = physical address (or 0 on failure)
extern p1_phys_alloc

; Free physical memory.
; Inputs: RDI = physical address, RSI = size
extern p1_phys_free

; Create a new AS (allocates page tables).
; Output: RAX = AS handle (top-level page-table physical address)
extern p1_aspace_create

; Map a physical range into an AS at a virtual address.
; Inputs: RDI = AS, RSI = virtual addr, RDX = physical addr, RCX = size, R8 = flags (RWX)
extern p1_aspace_map

; Unmap from an AS.
; Inputs: RDI = AS, RSI = virtual addr, RDX = size
extern p1_aspace_unmap

; Switch CR3 to use the given AS.
; Input: RDI = AS handle
extern p1_aspace_activate

; Destroy an AS.
; Input: RDI = AS handle
extern p1_aspace_destroy
```

7 entry points. No capability discipline; the kernel trusts callers in phase 1.

---

## 2. Migration to phase 2

Phase 2 adds:
- Page tables become capabilities (per MEM-Q2).
- Userspace assembles via `retype` + `map`.
- CoW via substructural sharing.
- KPTI for security.
- 1G pages.
- MMIO/PMem/CXL.mem derived kinds.

Phase-1 callers continue via wrapper functions over phase-2 capability operations.

---

## 3. Open issues

| ID | Issue |
|---|---|
| P1MM-O1 | Per-domain free-list sizing — phase 1 uses simple buddy allocator; phase 2 splits per NUMA. |
| P1MM-O2 | Phase-1 fault handling — kernel handles page faults itself; no pager. |

---

## 4. Phase-5 closure

**Date:** 2026-06-21  
**Status:** Stubs and constants complete; Phase 6 will implement bodies.

Phase 5 provides a complete skeleton of the Phase-1 memory-management API:

- **22 core MM modules** in `src/kernel/core/mm/`:
  - Memory-map parser (E820 audit)
  - Kernel image reservation
  - Buddy allocator (4K–2M, 10 free lists per order)
  - Per-CPU magazine cache (16 pages)
  - Physical allocation/free API
  - Address-space struct and lifecycle
  - PCID allocator (12-bit space, 4096 max)
  - Page-table walking and mapping (4K + 2M)
  - Page-fault handler (CR2/CR3 audit)
  - Panic trace ring buffer
  - NUMA preparation (per-domain lists, refill strategy)

- **7 smoke tests** in `tests/smoke/`:
  - `mm_torture.pdx` — buddy allocator stress
  - `mm_aspace_roundtrip.pdx` — AS lifecycle
  - `mm_2mib_mapping.pdx` — 2M page support
  - `mm_pcid_exhaustion.pdx` — PCID overflow handling
  - `mm_pf_userfault.pdx` — fault handler validation
  - `perf_pt_walk.pdx` — page-table walk latency
  - `perf_as_switch.pdx` — CR3 switch latency

- **3 audit entries** in `design/audit/entries/`:
  - `memory_map-001.md` — E820 table read (rawmem)
  - `aspace_activate-001.md` — CR3 write (sysreg)
  - `pf_handler-001.md` — fault handler (sysreg + rawmem)

All modules contain stubs/constants only per Phase 6 paideia-as limitations.
Real function bodies will be implemented in Phase 6 once paideia-as gains
structured control flow and multi-instruction unsafe block support.

---

*End of document.*
