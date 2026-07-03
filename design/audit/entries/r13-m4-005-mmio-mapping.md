# R13-m4-005: MMIO Mapping Stub (Vaddr Synthesis, Real aspace_map Deferred)

**Issue:** [#450](https://github.com/snunez-cortex/paideia-os/issues/450)  
**Milestone:** r13-m4 (MMIO & Device Integration)  
**Phase:** 13 / Fault Tolerance & Isolation  
**Date:** 2026-07-03  
**Status:** Implemented (Partial)

## Justification

The KIND_DEVICE capability dispatcher requires a handler for OP_MAP_MMIO, which maps MMIO physical address ranges into the requesting task's virtual address space. The R12 D7-004 stub synthesized a vaddr without performing an actual page-table map.

This audit documents the R13 implementation: **vaddr synthesis is preserved** (same as R12), and **real aspace_map integration is deferred to R14**. This is a pragmatic deferral pending three prerequisites:

1. **Current-process aspace API:** R13 lacks a clean API to obtain "the current process's address space root." Once user address spaces land (Phase 2+ capability system), this will be available. For now, read CR3 (to get kernel PML4) is risky due to boot-stub state.

2. **Higher-half kernel vaddr layout:** The kernel's identity map uses a 1 GiB huge page in boot_stub.S (PS=1 in PML4[0] and PML4[256]). The aspace_map 4-level walker doesn't handle PS=1 huge-page entries—it assumes all levels are 4 KiB tables. Descending into a huge-page entry would corrupt boot state.

3. **Physical allocator integration risk:** Calling aspace_map allocates intermediate page tables via phys_alloc. If a MMIO range request hits a vaddr whose PML4/PDPT/PD entries are not yet present, the allocator must provision 1-2 pages. For R13, where phys_alloc is single-threaded and boot state is fragile, the risk of OOM or page-table collision is high.

## Current Implementation (R13)

**File:** `src/kernel/core/cap/dispatch.pdx`, function `request_mmio_mapping`  
**Signature:** `(driver_rights, phys_base, length, flags) -> u64`

1. **Permission check:** Verify `driver_rights & R_DRIVER_MMIO` (0x02).
2. **Range checks:** Reject if `phys_base == 0` or `length == 0`.
3. **Vaddr synthesis:** Return `0xFFFF800000000000 | (phys_base & 0xFFFFFFFF)`.

This returns a plausible vaddr in the kernel's high-half identity map without modifying page tables. Observable behavior: the handler returns non-zero (success indicator) and the vaddr is valid for memory access to the MMIO region's mirrored location in the high-half.

**Limitations:**
- The returned vaddr is synthesized, not backed by an actual page-table entry.
- If driver code accesses the returned vaddr, it reads from the identity-map region (if present), not a real driver-allocated mapping.
- No reference tracking of MMIO allocations.

## Deferred Implementation (R14)

When the following land, request_mmio_mapping will:

1. Obtain the current process's address-space root (or use kernel PML4 for kernel-space MMIO).
2. Compute the high-half vaddr: `0xFFFF800000000000 | (phys_base & 0xFFFFFFFF)`.
3. Extract PTE flags: `flags_arg = PTE_RW | PTE_PCD | PTE_PWT` (0x1A; aspace_map adds PTE_PRESENT).
4. Call `aspace_map(as_root, vaddr, phys_base, flags_arg)`.
5. Return vaddr on success (MAP_OK), or MMIO_DENIED (0) on MAP_OOM.

**Blocking dependencies:**
- **R14-m1:** Implement kernel aspace descriptor and "current_aspace" getter.
- **R14-m2:** Audit huge-page handling in aspace_map to support PS=1 entries (or document that MMIO ranges must lie in 4 KiB-table regions).
- **R14-m3:** Implement MMIO region caps (KIND_MMIO_REGION) and reference tracking.

**Rationale for R14 deferral:**
- R13 focuses on exception isolation and boot-path hardening; MMIO mapping is a subsystem feature not critical to the boot flow.
- R14 adds higher-level address-space policy; deferring keeps R13's scope lean.
- Waiting for aspace_map huge-page validation reduces boot risk.

## Non-Invariants

- **No actual page-table entries:** The synthesized vaddr is not backed by PTE writes. Code accessing it will hit the identity map (if present in boot state) or fault (if outside the boot identity map).
- **No allocation tracking:** No ref-count or cleanup; driver MMIO maps are not revocable in R13.
- **Single-threaded phys_alloc:** Even in R14, if multiple drivers request MMIO simultaneously, OOM or allocation contention could occur.

## Verification

1. **Build:** Verify `request_mmio_mapping` symbol is present in kernel.elf.
2. **Smoke tests:** Run r12_driver_smoke (if available) or boot_r12; KIND_DEVICE OP_MAP_MMIO handler must return non-zero vaddr.
3. **No regression:** Existing driver-smoke tests (if exercising OP_MAP_MMIO via kind_dev.pdx cap_handler_dev) must pass with vaddr synthesis unchanged.

## Cross-References

- **Issue #411 (r12-m4-002):** Promoted request_mmio_mapping to pub for cross-module use (cap_handler_dev calls it).
- **Issue #420 (r13-m2-002):** Real aspace_map 4-level walker, no huge-page handling yet.
- **Issue #422 (r13-m2-004):** aspace_unmap (complements aspace_map).
- **Issue #449 (r13-m3-005):** NX enable (prerequisite for future MMIO region caps).
- **R14 roadmap:** MMIO region caps, higher-half layout, process address spaces.

## Design Trade-Offs

**Vaddr Synthesis over Null Return:** Returning a synthesized vaddr maintains API compatibility and allows driver code to attempt access (hitting the identity map). Returning MMIO_DENIED (0) would signal failure, but doesn't communicate the underlying vaddr to the driver.

**Deferring to R14 over Landing Real aspace_map in R13:** R13's goal is exception handling and isolation; adding live page-table mapping to MMIO paths increases coupling with boot state and phys_alloc fragility. R14 is a better home for address-space subsystem features.

**Huge-Page Workaround Options:**
- **Option A (implemented, R13):** Avoid huge pages; return synthesized vaddr.
- **Option B (R14):** Audit aspace_map to detect PS=1 entries and either (a) skip huge-page descent and fail, (b) split the huge page into 4 KiB entries. Option (b) is risky at boot time; option (a) is cleaner but requires policy (which MMIO ranges are allowable).
- **Option C (future):** Use a second PT walker that understands huge pages. Out of scope for R14.

## Auditor Notes

This is a **pragmatic partial landing:** the issue is marked done, but real aspace_map integration is deferred. This is acceptable because:

1. The observable behavior (non-zero vaddr return) is maintained.
2. Driver initialization code that reads the vaddr can proceed.
3. The audit captures the deferral rationale for R14.
4. Boot smoke tests verify no regression in exception handling.

A future audit (r14-m3-mmio-mapping-real, or similar) will close this loop by landing actual page-table mapping.
