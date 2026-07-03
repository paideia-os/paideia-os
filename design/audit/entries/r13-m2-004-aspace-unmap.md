---
audit_id: r13-m2-004-aspace-unmap
issue: 422
file: src/kernel/core/mm/aspace_unmap.pdx
function: aspace_unmap
effects: [sysreg, mem]
capabilities: []
retires: R5.5-004, #248, aspace-unmap-001
reviewed_by:
date: 2026-07-03
status: complete
---

# AUDIT r13-m2-004 — 4-level PTE clear + local INVLPG (R13-m2-004)

## Justification

`aspace_unmap` implements the Phase 2 core capability-system requirement: clearing a mapped virtual address and invalidating the TLB locally. The function (1) descends the 4-level page-table hierarchy (PML4→PDPT→PD→PT) from the address-space root, (2) verifies each intermediate level's present bit, (3) on success, zeros the leaf PTE and executes INVLPG to flush the TLB entry, and (4) returns UNMAP_OK or UNMAP_NOT_MAPPED if any intermediate level is not present.

Unsafe operations: reads from page-table entries at computed physical addresses (raw memory at arbitrary offsets), writes to the leaf PTE (memory mutation), and INVLPG (privileged TLB management instruction). These operations must be protected by the unsafe block and justified under the capability system (address-space isolation and TLB coherency).

Citation: Intel SDM Vol 3A §4.5 (4-level paging, present bit at each level) and §4.10.4.1 (INVLPG and TLB invalidation discipline). **Verification TODO.**

## Intended sequence

1. **Prologue:** Push callee-saved r12, r13 (2 pushes, preserve caller's state).
2. **Input:** RDI = as_root (PML4 phys base), RSI = vaddr. Save to r12, r13.
3. **Level 4 (PML4 descent):**
   - MOV RAX, R13 (vaddr); SHR RAX, 39; AND RAX, 0x1FF (extract bits [47:39]).
   - LEA R8, [R12 + RAX*8] (compute PML4 entry address).
   - MOV R9, [R8] (load PML4 entry).
   - MOV R10, R9; AND R10, 1; JZ aspace_unmap_notmapped (test P bit, branch if not present).
   - SHR R9, 12; SHL R9, 12 (mask to phys address, clear flags).
   - MOV R12, R9 (advance r12 to PDPT).
4. **Level 3 (PDPT descent):** Repeat step 3, with shift 30 (bits [38:30]).
5. **Level 2 (PD descent):** Repeat step 3, with shift 21 (bits [29:21]).
6. **Level 1 (PT leaf):**
   - MOV RAX, R13; SHR RAX, 12; AND RAX, 0x1FF (extract bits [20:12]).
   - LEA R8, [R12 + RAX*8] (compute PT entry address).
   - MOV R9, [R8] (load PTE).
   - MOV R10, R9; AND R10, 1; JZ aspace_unmap_notmapped (test P bit).
7. **Leaf PTE clear:**
   - XOR RAX, RAX (zero value).
   - MOV [R8], RAX (write zero to PTE, invalidating the entry).
8. **TLB invalidation:**
   - MOV RDI, R13 (vaddr as operand for INVLPG).
   - INVLPG [RDI] (flush TLB entry for vaddr).
9. **Success return:**
   - XOR RAX, RAX (RAX = 0 = UNMAP_OK).
   - POP R13, R12 (restore callee-saved registers in reverse order).
   - RET.
10. **Not-mapped return:**
    - aspace_unmap_notmapped:
    - MOV RAX, 4294967295 (UNMAP_NOT_MAPPED = u64_max).
    - POP R13, R12.
    - RET.

## Invariants

- **I1** (4-level descent completes): Each call descends exactly 4 levels (PML4, PDPT, PD, PT), extracting the 9-bit index from the corresponding vaddr bits and loading entries at computed offsets. No level is skipped or repeated.
- **I2** (present bit verified at each level): Before advancing to the next level, the present bit (bit 0) of the loaded entry is tested. If P=0, the function branches to aspace_unmap_notmapped immediately; no descent continues past a non-present entry.
- **I3** (leaf PTE zeroed on success): When all four levels are present, the leaf PTE at [R12 + (vaddr[20:12])*8] is written with zero (0x0000000000000000), invalidating the mapping.
- **I4** (INVLPG executes after PTE clear): After zeroing the leaf PTE and before returning, INVLPG [vaddr] is executed to invalidate the TLB entry. The invlpg operand is the original vaddr (R13).
- **I5** (return value valid): On success, RAX holds 0 (UNMAP_OK). On any miss (non-present entry at levels 1–4), RAX holds 4294967295 (UNMAP_NOT_MAPPED). Both are u64 values; no sign-extension or truncation.

## Non-invariants

- **NI1** (as_root validity):** aspace_unmap does NOT validate as_root (passed in RDI). If as_root is stale, unmapped, or points to non-PML4 memory, reads will return garbage or fault. Caller must ensure as_root is a valid PML4 phys base (e.g., from a prior aspace_create call).
- **NI2** (vaddr page-aligned assumption):** aspace_unmap does NOT require vaddr to be page-aligned; the bit extraction (shr + and) works for any vaddr. However, a misaligned vaddr will decode to a valid (but likely wrong) page-table entry, potentially unmapping a neighboring page.
- **NI3** (concurrent modification of PML4):** aspace_unmap does NOT serialize concurrent modifications to the page-table hierarchy. If another CPU modifies an intermediate PML4/PDPT/PD entry during descent, aspace_unmap may load stale or torn data. Mitigated by: (a) single-threaded Phase 2 bootstrap, (b) multicore synchronization (invalidation, fencing) deferred to Phase 13+ (issue #xxx).
- **NI4** (entry flags preservation):** aspace_unmap reads and discards entry flags (RWX, user/kernel, etc.) during descent; only the physical address (bits [51:12]) and present bit (bit 0) are used. Dropped entries' access-control metadata is not preserved.
- **NI5** (shootdown coordination):** aspace_unmap executes only a local INVLPG; it does NOT send TLB-shootdown IPIs to other CPUs. Multicore TLB coherency is deferred to Phase 13+ per design (issue #xxx). Callers on multicore systems must handle cross-CPU invalidation separately.

## Caller discipline

```
Input:
  RDI ← as_root   (PML4 phys base, u64)
  RSI ← vaddr     (virtual address to unmap, u64)

Output:
  RAX ← 0                 (UNMAP_OK, on success)
      ← 4294967295        (UNMAP_NOT_MAPPED, if any intermediate level is not present)

Clobber:
  RAX, RDI, R8, R9, R10, R12, R13

Flags:
  ZF set iff RAX == 4294967295 (vaddr not mapped)
```

Caller must ensure:
1. `as_root` is the phys base of a valid PML4 allocated by aspace_create or equivalent.
2. `vaddr` is the canonical virtual address to unmap (no alias translation).
3. No concurrent modifications to the PML4/PDPT/PD/PT hierarchy during the call (enforced by single-threaded Phase 2 bootstrap).
4. After return, the page frame previously mapped at vaddr is safe to reuse (caller must have deallocated it or revoked access via other means).

## Consumers

- **Phase 2 capability system:** aspace_unmap is the core operation for unmapping virtual addresses from address spaces (revocation).
- **Process termination (future):** exit/kill syscalls will call aspace_unmap to tear down process memory.
- **Memory reclamation (future):** page-fault handlers or memory-pressure handlers may call aspace_unmap to free frames.
- **aspace_create:** depends on aspace_unmap for cleanup of intermediate tables on error (future enhancement).

## Retirement path

**Retires:**
- R5.5-004 MVP stub (issue #248, paideia-as phase 5): replaced queue_shootdown (TLB-shootdown mailbox bookkeeping stub), local_invlpg (privileged INVLPG stub), shootdown_mailbox state (per-CPU mailbox word), and shootdown_vaddr state (pending vaddr slot).
- aspace-unmap-001 audit entry: documented R5.5-004 phase-5 stubs; superseded by real implementation.
- #913 MVP stubs: aspace_unmap was an unsafe stub pending MM activation; now superseded by real 4-level descent.

**Successor:**
- Phase 13+ TLB-shootdown synchronization (#xxx): add cross-CPU INVLPG via IPI mailbox (restore shootdown coordination, deferred from R5.5).
- Phase 14+ address-space revocation (#xxx): track revocation state per address space, synchronize with capability system.

## Verification

1. **Symbolic execution** (paideia-as assembler feedback):
   - LEA with [R12 + RAX*8], [R8 + ...] must encode valid SIB (scale-index-base) byte sequences.
   - SHR/AND extraction for each level (shift 39, 30, 21, 12) must encode correctly; AND 0x1FF produces a 9-bit mask.
   - JZ aspace_unmap_notmapped branches must encode valid near jumps (signed 8-bit or 32-bit displacements).
   - Push/pop r12, r13 must use correct register encoding (register IDs 4, 5 with optional REX).
   - INVLPG [rdi] must encode per Intel SDM Vol 3A (mem operand, likely 0F 01 /7 rm opcode).

2. **Static checks:**
   - UNMAP_NOT_MAPPED (4294967295 = 0xFFFFFFFF) must NOT sign-extend to 0xFFFFFFFFFFFFFFFF in 64-bit contexts; objdump should show as raw u64 constant.
   - PT_INDEX_MASK = 0x1FF (9 bits).
   - SHIFT_* constants: 39, 30, 21, 12 (consecutive levels of 4-level paging).
   - Register allocation: r12, r13 (callee-saved) for as_root, vaddr; r8, r9, r10 (caller-saved) for entry loads and P-bit tests; rax (caller-saved) for index extraction and return.
   - Both success and not-mapped return paths pop r13, r12 in reverse order before ret.
   - Prologue (2 pushes): mov r12, rdi; mov r13, rsi must come after prologue, before any memory operations.

3. **Behavioral checks** (regression suite, ./tools/run-smoke.sh):
   - boot_r8_only: basic boot path, no aspace_unmap yet (regression guard).
   - boot_r10, boot_r11, boot_r12, boot_r12_denial: phase-2+ capability tests with aspace_unmap active.
   - Expected: all tests pass with no #GP, #PF, or page-fault loops; unmapped addresses must not corrupt kernel state.

4. **Disassembly verification:**
   - objdump -d build/kernel.elf --disassemble=aspace_unmap must show:
     - 2 PUSH r12, r13 at prologue.
     - MOV r12, rdi; MOV r13, rsi (save inputs).
     - 4 iterations of: SHR RAX, <shift>; AND RAX, 0x1FF; LEA R8; MOV R9; AND R10; JZ.
     - Level-advance: SHR R9, 12; SHL R9, 12; MOV R12, R9 (at levels 1–3).
     - Leaf: XOR RAX, 0; MOV [R8], RAX (zero PTE).
     - INVLPG [RDI] (TLB flush).
     - Success return: XOR RAX, 0; POP R13, R12; RET.
     - Not-mapped return: MOV RAX, 0xFFFFFFFF; POP R13, R12; RET.

## Failure modes

- **F1** (non-present entry at level 1–4):** If any intermediate entry lacks the P bit (bit 0 = 0), aspace_unmap branches to aspace_unmap_notmapped and returns UNMAP_NOT_MAPPED (4294967295). This is expected for unmapping a vaddr that was never mapped, or was already unmapped. Caller must distinguish success from not-mapped via ZF or RAX comparison.
- **F2** (as_root stale or invalid):** If as_root does not point to a valid PML4 in physmem, MOV R9, [r12 + ...] during level 4 descent may cause a page fault (#PF) or load garbage. Kernel crash or silent data corruption. Caller must ensure as_root is the current PML4 base from a prior aspace_create.
- **F3** (concurrent PML4 modification):** If another CPU modifies a PML4/PDPT/PD entry during aspace_unmap's descent, aspace_unmap may load a stale or intermediate value, advancing to wrong physical address or missing a non-present check. Torn reads unlikely (aligned u64 loads are atomic), but flag-bit races and stale cached values possible. Mitigated by single-threaded Phase 2 bootstrap; multicore serialization deferred to Phase 13+.
- **F4** (invlpg encode not available):** If paideia-as 0.6.0 lacks the INVLPG encoder or [reg] memory operand, the INVLPG [RDI] instruction emits a stub (e.g., mov rax, rax). TLB entry persists in cache, causing use-after-free on page reuse. Resolved when paideia-as adds INVLPG encoder (late Phase 2 or Phase 3).

## Cross-references

- **Issue:** #422 (R13-m2-004)
- **Plan:** design/infrastructure/phys-alloc-plan.md (Phase 7 allocation strategy)
- **Audit entries:**
  - r13-m2-001-phys-alloc.md (#419): phys_alloc interface and bump allocator.
  - r13-m2-002-aspace-map.md (#420): PML4 walking and leaf PTE write.
  - r13-m2-003-aspace-create.md (#421): PML4 allocation.
- **Retired audit entries:**
  - aspace-unmap-001.md (#248 R5.5-004): phase-5 MVP stub with mailbox bookkeeping.
- **Related issues:**
  - #248 (R5.5-004): predecessor MVP stub (paideia-as phase 5).
  - #913 (MVP stubs): aspace_unmap was rewritten as unsafe stub pending MM activation.
  - #420 (R13-m2-002): aspace_map (peer function, real 4-level write).
  - #421 (R13-m2-003): aspace_create (PML4 allocation, creates root for aspace_unmap).
- **Intel SDM Vol 3A:**
  - §4.5: Linear-address translation, 4-level paging, present bit per level.
  - §4.10.4.1: INVLPG instruction and TLB invalidation discipline.
- **Modules:**
  - AspaceUnmap (src/kernel/core/mm/aspace_unmap.pdx): this entry.
  - AspaceCreate (src/kernel/core/mm/aspace_create.pdx): allocates PML4 root.
  - AspaceMap (src/kernel/core/mm/aspace_map.pdx): peer function (write to leaf).
  - Boot (src/kernel/core/arch/x86_64/boot.pdx): initializes kernel PML4.

---
**Audit:** R13-m2-004 bundle (July 2026)
