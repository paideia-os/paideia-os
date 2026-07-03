---
audit_id: r13-m3-002-kpti-pgd-copy
issue: 446
file: src/kernel/core/mm/kpti.pdx
function: aspace_create_user_pgd
effects: [mem]
capabilities: []
reviewed_by:
date: 2026-07-03
status: stub
---

# AUDIT r13-m3-002 — KPTI PGD-copy discipline (R13-m3-002)

## Justification

KPTI (Kernel Page Table Isolation) mitigates Meltdown (CVE-2017-5754) by forcing every user-space process to hold two isolated page-table roots (PML4s):
- **KERNEL_PGD**: full kernel mappings + higher-half + trampoline + user pages (used in ring 0, CPU-side)
- **USER_PGD**: user pages + trampoline only (used in ring 3, CPU-side)

On syscall entry (ring 0), the kernel swaps CR3 to KERNEL_PGD; on sysretq exit to ring 3, swaps back to USER_PGD. This isolation prevents user-mode speculative prefetch from reading privileged kernel memory.

`aspace_create_user_pgd` is the factory function for USER_PGD instantiation. Currently stubbed (Phase 1) returning ASPACE_CREATE_NOT_YET to signal "not yet activated" (distinct from OOM). Full implementation deferred to Phase 2+ pending:
1. Dedicated trampoline PDPT (not the shared PML4[256] alias installed by #445 r13-m3-001).
2. m5-002 syscall entry trampoline with CR3 swap machinery.
3. #480 kernel VMA move to higher-half execution context.
4. m10-001 fork wiring both aspace_create (KERNEL_PGD) and aspace_create_user_pgd (USER_PGD).

Citation: Intel SDM Vol 3C §4.1.1 (SMEP/SMAP); Linus Torvalds KPTI design (2017); design/infrastructure/kpti-plan.md (phase strategy).

## Intended sequence (Phase 1 stub)

1. **Prologue:** No register save needed; immediate return.
2. **Load sentinel:** `MOV RAX, 0xFFFFFFFE` (ASPACE_CREATE_NOT_YET).
3. **Return:** `RET`.

Full Phase 2+ body (deferred):
1. Allocate new PML4 via phys_alloc(0).
2. Zero all 512 entries.
3. Install dedicated trampoline PDPT (not shared alias) at PML4[256].
4. Return new PML4 phys base or ASPACE_CREATE_NOT_YET on error.

## Invariants

**I1: Return code clarity**
The stub returns ASPACE_CREATE_NOT_YET (0xFFFFFFFE = 4294967294) on every call. Callers can distinguish:
- 0xFFFFFFFF (ASPACE_CREATE_OOM, 4294967295): allocation failure
- 0xFFFFFFFE (ASPACE_CREATE_NOT_YET, 4294967294): feature not yet activated
- Any other value: valid USER_PGD phys base

**I2: No side effects (stub)**
Stub performs no memory writes, no phys_alloc calls, no register clobber (except RAX for return value). State is unchanged except for return value in RAX.

**I3: Symbol presence**
`aspace_create_user_pgd` symbol exists in the final kernel ELF, allowing downstream call sites (fork, spawn, task creation) to link. Symbol visibility and calling convention match aspace_create (RDI ← kernel_pml4, RAX ← result).

**I4: Sentinel distinct from OOM**
ASPACE_CREATE_NOT_YET (0xFFFFFFFE) ≠ ASPACE_CREATE_OOM (0xFFFFFFFF). This two-state encoding allows callers to:
- Retry on NOT_YET (feature activation expected in future phase).
- Panic or wait on OOM (allocation pool exhausted, immediate recovery needed).

## Non-invariants

**NI1: Kernel PML4 not read (stub)**
The stub ignores kernel_pml4 (RDI parameter). Full implementation will read and copy kernel_pml4[256..511] to establish shared kernel-space view in USER_PGD.

**NI2: No user pages installed (stub)**
Stub does not allocate or map user-space memory. Full implementation will zero entries 0..255 (user half) and install trampoline-only PDPT at [256].

**NI3: Trampoline not created (stub)**
Stub does not allocate or populate the dedicated trampoline page(s). Trampoline creation is deferred to Phase 2; Phase 1 only installs shared PML4[256] alias (r13-m3-001).

**NI4: No activation gating (stub)**
Stub does not check whether KPTI machinery (syscall entry CR3 swap, sysretq swap-back) is installed. Callers must ensure full activation path before using returned USER_PGD.

## Caller discipline

```
Input:
  RDI ← kernel_pml4   (kernel KERNEL_PGD phys base, u64)

Output:
  RAX ← 0xFFFFFFFE    (ASPACE_CREATE_NOT_YET, stub; feature not yet active)
      ← valid u64     (future: new USER_PGD phys base, when Phase 2+ active)
      ← 0xFFFFFFFF    (future: ASPACE_CREATE_OOM, on allocation failure)

Clobber:
  RAX (only register modified)

Flags:
  ZF set iff RAX == 0 (never in stub; always 0xFFFFFFFE)
```

Caller responsibilities:
1. Pass valid kernel_pml4 (kernel KERNEL_PGD phys base).
2. Check return value: if 0xFFFFFFFE, defer USER_PGD setup to later phase or panic.
3. If return is valid (future), pair USER_PGD with KERNEL_PGD in process structure.
4. Install USER_PGD in CR3 on user-mode entry (ring 3); swap to KERNEL_PGD on syscall entry (ring 0).

## Consumers

- **fork / spawn syscalls (m10-001):** Will call both aspace_create (KERNEL_PGD) and aspace_create_user_pgd (USER_PGD) to initialize new process.
- **Process initialization (scheduler, R10+):** May call aspace_create_user_pgd during task setup.
- **KPTI CR3 swap machinery (m5-002, #480):** Uses installed USER_PGD as target for ring-3 CR3 loads.

## Activation prerequisites

1. **r13-m3-001 (#445) complete:** PML4[256] higher-half alias installed and tested.
2. **Dedicated trampoline PDPT:** Separate from shared alias; requires independent allocation and population (not yet designed).
3. **m5-002 syscall CR3 swap:** Trampoline code that swaps CR3 on entry (ring 0) and exit (ring 3).
4. **#480 kernel VMA move:** Kernel execution shifted to higher-half VA (0xFFFF8000...); requires linker and page-table changes.
5. **m10-001 fork wiring:** Caller infrastructure to invoke both aspace_create and aspace_create_user_pgd atomically.

## Verification

1. **Build succeeds:**
   ```bash
   ./tools/build.sh
   ```
   Confirms paideia-as assembles kpti.pdx without error; symbol table includes aspace_create_user_pgd.

2. **Symbol presence:**
   ```bash
   nm build/kernel.elf | grep aspace_create_user_pgd
   ```
   Expected output: single symbol (stub or future implementation) with KERNEL_PGD-relative address.

3. **Smoke tests pass byte-identically:**
   All five regression modes (boot_r8_only, boot_r10, boot_r11, boot_r12, boot_r12_denial) must pass. Stub does not affect boot flow or memory state.

4. **No stale encodings:**
   ```bash
   objdump -d build/kernel.elf | grep -A5 aspace_create_user_pgd
   ```
   Expected: MOV RAX, 0xFFFFFFFE; RET (or equivalent encoding).

## Failure modes

- **F1 (caller ignores NOT_YET):** If caller treats 0xFFFFFFFE as valid USER_PGD phys base and installs in CR3, CPU will generate #PF or #GP (invalid page table) on first user-mode access. Mitigation: caller must check return code and panic if NOT_YET before proceeding.
- **F2 (future OOM during allocation):** When Phase 2 full implementation lands, phys_alloc may fail (pool exhausted). Returns 0xFFFFFFFF (ASPACE_CREATE_OOM). Caller must distinguish from NOT_YET and retry or escalate.
- **F3 (concurrent calls during Phase 2):** Future full implementation may share state with phys_alloc or kernel PML4. Concurrent calls risk torn reads or lost updates. Mitigated by single-threaded bootstrap and fork-time single calls.

## Cross-references

- **Issue:** #446 (R13-m3-002 KPTI PGD-copy discipline Phase 1 stub)
- **Related issues:**
  - #445 (r13-m3-001): PML4[256] higher-half alias (Phase 1 prerequisite).
  - #480 (r13-m3-003): Kernel VMA move and far-jmp transition (Phase 2 prerequisite).
  - #913 (MVP stubs): Phase 1 stub harness for unsafe blocks.
- **Plans:**
  - design/infrastructure/kpti-plan.md: full KPTI implementation strategy.
  - design/infrastructure/phys-alloc-plan.md: physical memory allocation (Phase 2 full body).
- **Related audits:**
  - r13-m3-001-hh-alias.md (#445): PML4[256] alias setup.
  - r13-m2-003-aspace-create.md (#421): KERNEL_PGD factory (aspace_create).
- **Intel SDM Vol 3:**
  - §4.1.1: SMEP, SMAP, and user-space isolation.
  - §4.5: 4-level paging and PML4 structure.
  - §4.10.4: TLB invalidation (INVLPG).
- **Modules:**
  - Kpti (src/kernel/core/mm/kpti.pdx): this entry (stub).
  - AspaceCreate (src/kernel/core/mm/aspace_create.pdx): KERNEL_PGD factory.
  - PhysAlloc (src/kernel/core/mm/phys_alloc.pdx): allocation for Phase 2 full body.

## Errata

None at this time. Stub design is clean separation from Phase 2+ full implementation.

---
**Audit:** r13-m3-002 Phase 1 stub (July 2026)
