---
audit_id: r14-m2-003-aspace-map-huge
issue: 488
file: src/kernel/core/mm/aspace_map.pdx
function: aspace_map
effects: [mem, sysreg]
capabilities: []
reviewed_by:
date: 2026-07-03
---

# R14-m2-003 — aspace_map huge-page detection

**Issue:** #488
**File:** src/kernel/core/mm/aspace_map.pdx (modified)
**Unblocks:** #450 (KIND_DEVICE MMIO real body backfill), #451 (KIND_PAGE_TABLE real handler), R14.M3 landing preparation

## Landing scope

Add PS=1 (huge-page) detection at PDPT and PD descent points in aspace_map. If an intermediate entry has bit 7 set (huge-page), aspace_map now returns MAP_HUGE (4294967293 = 0xFFFFFFFD) rather than descending into the huge-page's physical address and clobbering it with a spurious PDE/PTE write.

## Prior behavior (bug)

The 4-level walker unconditionally treated the PDPT/PD entry's physical address bits as a next-level table pointer. When boot_stub.S installs PS=1 1 GiB huge pages at PDPT[0..3] via PML4[0] and PML4[256], the walker would:

1. Read the huge-page entry.
2. Extract its physical address bits (which are the huge-page's target, NOT a table pointer).
3. Compute the PD/PT slot address at `huge_page_target + index*8`.
4. Write a spurious PDE/PTE at that offset — corrupting the physical memory that the huge-page was mapping.

Since kernel .text/.rodata/.bss all live in the low 4 GiB (covered by the boot huge pages), this would corrupt the running kernel.

## New behavior

At both PDPT descent and PD descent, before treating the entry's physical address bits as a table pointer:

```
mov r10, r9;      // r10 = intermediate entry
and r10, 0x80;    // bit 7 = PS
jnz aspace_map_huge;
```

Falls through to the standard "table-pointer" path on PS=0; jumps to the shared error tail on PS=1.

New error tail `aspace_map_huge` restores callee-saved registers and returns 4294967293 (MAP_HUGE).

## Sentinel table (updated)

| Sentinel | Value | Meaning |
|---|---|---|
| MAP_OK | 0 | leaf PTE written successfully |
| MAP_OVERLAP | 4294967295 | reserved (currently unused) |
| MAP_OOM | 4294967294 | phys_alloc failure while allocating intermediate table |
| MAP_HUGE | 4294967293 | **NEW** — PDPT or PD entry has PS=1; refuse to descend |

## Regression

Currently no code path calls aspace_map at runtime (the R13 landings that would exercise it — #450 real body, #451 real body, #436 loader — are all R14-deferred). Dead code addition; 5-mode byte-identically green.

## Downstream

- **#450 backfill** (KIND_DEVICE MMIO OP_MAP_MMIO): can now call aspace_map safely against the kernel PML4 without risk of clobbering the boot huge pages. Real body still needs the R14.M3 higher-half relocation to have a legitimate destination aspace, but the walker itself is now safe.
- **#451 backfill** (KIND_PAGE_TABLE OP_MAP): same.
- **#436 backfill** (kernel-user loader): iretq into ring-3 requires a user aspace, which requires aspace_map to safely handle the process's PML4. This landing ensures the walker won't corrupt boot state during that process.

## Deferred (Option B, not landed)

Softarch analyzed three options:
- **Option A**: Detect and reject (this landing). Prevents corruption; doesn't enable huge-page-region mapping.
- **Option B**: Detect and split. Allocate a PD, populate 512 × 2 MiB PDEs or 512×512 × 4 KiB PTEs mapping the same range, replace PDPT entry. Enables mapping into huge-page regions but adds substantial complexity.
- **Option C**: R14.M3 higher-half kernel relocation. User aspaces populate low-half only; kernel's huge-page-mapped PML4[0] is orphaned in user aspaces. aspace_map on user PML4 never encounters PS=1.

**Option C is the primary path.** Once R14.M3 lands, user aspaces have a clean PML4 with no huge-page entries anywhere, and aspace_map's PS=1 check becomes a defense-in-depth measure that's never triggered in practice.

**Option B is not landed** and not currently planned. If a legitimate use case emerges (e.g., splitting a huge page for W^X reasons in kernel memory), it can be added as a future issue.

## Cross-references

- design/milestones/r14-preflight.md (R14 kickoff sequencing).
- design/milestones/r14-kickoff.md (Path B higher-half relocation).
- src/kernel/core/mm/aspace_map.pdx (subject).
- tools/boot_stub.S:41 (PML4[256] alias installation — Phase 1 of higher-half).
- #450, #451, #436 (R13-deferred landings unblocked by this + R14.M3).
- #484 (m8 kernel-user transition deferral bundle — B1 blocker now resolved).

## Acceptance

- [x] Build succeeds.
- [x] 5-mode regression byte-identically green.
- [x] MAP_HUGE sentinel introduced (4294967293).
- [x] PS=1 check at PDPT descent (before treating entry as table pointer).
- [x] PS=1 check at PD descent (before treating entry as table pointer).
- [x] Shared aspace_map_huge error tail with correct register unwinding (pop r15/r14/r13/r12).
- [x] No changes to leaf PTE write path (PT level unchanged).
