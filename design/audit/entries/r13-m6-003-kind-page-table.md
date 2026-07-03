---
audit_id: r13-m6-003-kind-page-table
issue: 451
file: src/kernel/core/cap/kind_page_table.pdx
function: (declarations only; no handler wired)
effects: []
capabilities: []
reviewed_by:
date: 2026-07-03
---

# R13-m6-003 — KIND_PAGE_TABLE (structural stub; R14-deferred)

**Issue:** #451
**Files:** src/kernel/core/cap/kind_page_table.pdx (new; declarations only)
**Related:** #430 (structural precedent), #450 (aspace_map deferral precedent), #420 (aspace_map), #422 (aspace_unmap)

## Landing scope

Op-code constants only:
- KIND_PAGE_TABLE_OP_MAP = 0
- KIND_PAGE_TABLE_OP_UNMAP = 1

No handler, no dispatch branch, no tag string, no pub promotion of aspace_map/unmap. Kind=3 remains a fallthrough in cap_invoke_dispatch (returns target_ptr).

## Deferral rationale

Four blockers:

**B1. Args encoding.** OP_MAP requires {vaddr, paddr, flags}; the dispatch ABI (rdi=rights, rsi=target_ptr, rdx=op_arg) passes exactly one 64-bit op_arg. Three addresses cannot pack losslessly into one u64. Design options:
- Memory-region cap indirection (caller mints separate cap for the payload).
- Extended dispatch ABI (add more arg registers).
- SMAP-bracketed user-struct read (kernel reads a user-space struct pointed to by op_arg).
All three deferred to R14 pending memory-region-cap design.

**B2. Current-aspace API absent.** Inherits #450. aspace_activate.pdx is a mov rax, rax placeholder. No runtime "which aspace am I in" resolver. Without it, the handler cannot decide whose PML4 target_ptr refers to.

**B3. Huge-page walker collision.** Inherits #450. Boot_stub.S installs PS=1 1 GiB huge pages at PDPT[0..3] via PML4[0] and PML4[256]. aspace_map's 4-level walker treats every level as 4 KiB PTs; descent into an existing PS=1 entry would clobber it.

**B4. No user-space minter.** R13 has no ring-3 code that mints kind=3 caps. Even if the handler landed, no test would exercise it. cap_smoke and cap_dispatch_smoke don't mint kind=3.

## Data model (pinned for R14)

No new .bss needed. target_ptr = aspace_root already lives in the Process descriptor at PROCESS_OFF_ASPACE_ROOT (0). KIND_PAGE_TABLE is a "view" cap over an existing process's PML4, not a new object.

## Ops (deferred implementation reference)

R14 semantics:

- **OP_MAP (0)**: rights & RIGHT_INVOKE (0x08). Args-encoding-scheme TBD (see B1). Delegates to aspace_map(target_ptr, vaddr, paddr, flags).
- **OP_UNMAP (1)**: rights & RIGHT_INVOKE (0x08). Args TBD. Delegates to aspace_unmap(target_ptr, vaddr).

Handler ABI: (rdi=rights, rsi=target_ptr, rdx=op_arg) -> rax.

## Follow-up landing plan (R14)

1. Promote aspace_map to pub in aspace_map.pdx.
2. Promote aspace_unmap to pub in aspace_unmap.pdx.
3. Add cap_pt_msg tag string to tags.pdx.
4. Add cmp rcx, 3; je call_kind_page_table branch to invoke.pdx.
5. Add cap_handler_page_table body in kind_page_table.pdx per R14-blessed args-encoding scheme.
6. Consider audit item to resolve B2/B3 (current-aspace API + huge-page walker) before wiring.

## Regression

.bss growth: 0 bytes. .rodata growth: ~40 bytes for the three constants. Fingerprints byte-identical across 5-mode smoke suite.

## Cross-references

- #430 (structural precedent), #431 (real-handler precedent showing when wired-stub is possible), #450 (aspace_map deferral matches).
- src/kernel/core/mm/aspace_map.pdx (aspace_map — private, ready for pub promotion in R14).
- src/kernel/core/mm/aspace_unmap.pdx (aspace_unmap).
- .plans/r13-round-osarch-plan.md §4 m6-003.

## Acceptance

- [x] Build succeeds.
- [x] 5-mode regression byte-identically green.
- [x] Op-code constants declared.
- [x] No dispatch/wiring changes.
- [x] Follow-up landing plan documented.
