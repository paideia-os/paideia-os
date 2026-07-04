---
audit_id: r14b-m4-008-user-pml4-populate-lowhalf
issue: 504
file: src/kernel/core/mm/aspace_map.pdx, src/kernel/core/cap/kind_process.pdx
function: aspace_map
effects: [mem, sysreg]
capabilities: [aspace]
reviewed_by:
date: 2026-07-04
---

# AUDIT r14b-m4-008 — User PML4 Populate (Low-Half) — No-Op Landing

## Scope

Issue #504 states the goal: `aspace_map` must write into `user_pml4_pa`, not `kernel_pml4_pa`.
This goal is **already met structurally** by the function signature. The function takes `as_root`
as its first argument (RDI) and walks whatever PML4 the caller provides, with no hard-coded
reference to kernel-space tables. Per-process aspace creation in `kind_process.pdx` OP_CREATE
allocates a fresh PML4 for each process. No code changes required.

## Structural Proof

**Function signature** (`aspace_map.pdx:47`):
```
let aspace_map : (u64, u64, u64, u64) -> u64 !{mem, sysreg} @{} =
  fn (as_root: u64) (vaddr: u64) (paddr: u64) (flags: u64) -> ...
```

Caller discipline: `RDI=as_root` (PML4 base, physical address).

**Walker seeds from caller-supplied root** (`aspace_map.pdx:57`):
```asm
mov r12, rdi;           // r12 ← as_root (caller's PML4)
```

All four levels (PML4, PDPT, PD, PT) descend from `r12`. No reference to
`_kernel_pml4_pa` inside the walker.

## Per-Process Aspace Root

`kind_process.pdx` OP_CREATE (lines 31–59):
1. Calls `aspace_create(&pml4)` (line 41) to derive a fresh PML4 for this process.
2. Stores result at pool offset `(pid-1)*32 + 0` (line 50):
   ```asm
   mov [rdi + 0], rax;     // PROCESS_OFF_ASPACE_ROOT = 0
   ```
3. OP_GET_ASPACE_ROOT (lines 61–78) reads this value back for the caller.

Each process has its own PML4, allocated and managed independently.

## Out of Scope

Wiring actual user-aspace callers (KIND_PAGE_TABLE OP_MAP real handler, MMIO real map)
is separate work, deferred to their own issues. This issue confirms the infrastructure
is already correct.

## Grep Evidence

No non-comment callers of `aspace_map` currently exist in `src/`:
```bash
$ grep -r "call aspace_map" src/ --include="*.pdx" --include="*.S"
# (no results)
```

All references are to design intent or internal labels within `aspace_map.pdx` itself.

## Conclusion

Issue #504 is **closed as no-op**. The structural invariant—that `aspace_map` is
caller-parameterized and does not reference kernel-space tables—is already satisfied.
Real callers will pass process-specific PML4 roots from the per-process aspace pool.
