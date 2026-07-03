---
audit_id: r13-m2-003-aspace-create
issue: 421
file: src/kernel/core/mm/aspace_create.pdx
function: aspace_create
effects: [mem]
capabilities: []
retires: R5.5-006, #913
reviewed_by:
date: 2026-07-03
status: complete
---

# AUDIT r13-m2-003 — PML4 allocation + kernel-half copy (R13-m2-003)

## Justification

`aspace_create` implements the phase-2 core capability-system requirement: address-space initialization for userspace contexts. The function (1) allocates a new PML4 page via phys_alloc(0), (2) zeroes entries 0..255 (user-address-space half) to prevent stale kernel mappings from leaking into new processes, and (3) copies entries 256..511 (the kernel-address-space upper half) from the kernel PML4 to establish a shared kernel-space view across all address spaces.

Unsafe operations: reads from the kernel PML4 (raw physical memory at an arbitrary address passed at runtime), writes to newly allocated PML4 memory, and relies on phys_alloc to provide page-aligned memory. These operations must be protected by the unsafe block and justified under the capability system (address-space isolation).

Citation: Intel SDM Vol 3A §4.5 (4-level paging, PML4 structure and upper-half invariants); design/infrastructure/phys-alloc-plan.md (Phase 7 allocation) and design/audit/entries/r13-m2-001-phys-alloc.md (phys_alloc interface).

## Intended sequence

1. **Prologue:** Push callee-saved r12, r13, r14 (3 pushes, preserve caller's state).
2. **Input:** RDI = kernel_pml4 (kernel PML4 phys base). Save to r12.
3. **Allocate new PML4:**
   - MOV RDI, 0 (order=0 for single-page allocation).
   - CALL phys_alloc (returns new page phys base in RAX, or 0 on OOM).
   - CMP RAX, 0; JE aspace_create_oom (branch if allocation failed).
   - MOV R13, RAX (save new PML4 base).
4. **Zero user half (entries 0..255):**
   - MOV R14, 0 (loop counter, index into PML4).
   - aspace_create_zero_loop:
     - CMP R14, 256; JGE aspace_create_zero_done (exit when index >= 256).
     - LEA R8, [R13 + R14*8] (compute address of entry index).
     - MOV RAX, 0 (zero value).
     - MOV [R8], RAX (write zero entry).
     - ADD R14, 1; JMP aspace_create_zero_loop (next entry).
   - aspace_create_zero_done (all user entries zeroed).
5. **Copy kernel half (entries 256..512):**
   - MOV R14, 256 (loop counter, start at first kernel entry).
   - aspace_create_copy_loop:
     - CMP R14, 512; JGE aspace_create_copy_done (exit when index >= 512).
     - LEA R8, [R12 + R14*8] (compute address in kernel PML4).
     - MOV RAX, [R8] (load entry from kernel PML4).
     - LEA R8, [R13 + R14*8] (compute address in new PML4).
     - MOV [R8], RAX (write entry to new PML4).
     - ADD R14, 1; JMP aspace_create_copy_loop (next entry).
   - aspace_create_copy_done (all kernel entries copied).
6. **Success return:**
   - MOV RAX, R13 (return new PML4 base).
   - POP R14, R13, R12 (restore callee-saved registers in reverse order).
   - RET.
7. **OOM return:**
   - aspace_create_oom:
   - MOV RAX, 4294967295 (ASPACE_CREATE_OOM = u64_max).
   - POP R14, R13, R12.
   - RET.

## Invariants

- **I1** (new PML4 allocated once): Each call allocates exactly one new PML4 page via phys_alloc(0). No partial allocations or re-allocation.
- **I2** (user half zeroed): After the zero loop completes, entries 0..255 contain all zeros (0x00000000_00000000). No stale data persists.
- **I3** (kernel half copied): After the copy loop completes, entries 256..511 are bit-identical to the corresponding entries in kernel_pml4. The copy is byte-exact; no address translation or flags modification.
- **I4** (return value valid): On success, RAX holds the phys address of the new PML4 (same as r13). On failure, RAX holds 4294967295 (ASPACE_CREATE_OOM). Both are u64 values; no sign-extension or truncation.

## Non-invariants

- **NI1** (kernel PML4 validity):** aspace_create does NOT validate kernel_pml4 (passed in RDI). If kernel_pml4 is stale, unmapped, or points to non-PML4 memory, reads will return garbage. Caller must ensure kernel_pml4 is the true kernel PML4 base.
- **NI2** (new PML4 usage):** aspace_create does NOT check that the new PML4 is subsequently installed as an address space. Returning a PML4 base does not activate it; caller must install via CR3 write or equivalent.
- **NI3** (concurrent allocation):** aspace_create does NOT serialize concurrent calls to phys_alloc. If two CPUs call aspace_create simultaneously during bootstrap, both may receive distinct allocated pages (good) or the same page (bad race). Mitigated by single-threaded bootstrap.
- **NI4** (pool exhaustion):** If phys_alloc returns 0 (pool exhausted), aspace_create returns ASPACE_CREATE_OOM. Caller must handle and may need to pre-allocate PML4 pages during initialization to avoid exhaustion.

## Caller discipline

```
Input:
  RDI ← kernel_pml4   (kernel PML4 phys base, u64)

Output:
  RAX ← new PML4 base (on success, u64)
      ← 4294967295    (ASPACE_CREATE_OOM, on failure)

Clobber:
  RAX, RDI, R8, R12, R13, R14

Flags:
  ZF set iff RAX == 4294967295 (allocation failed)
```

Caller must ensure:
1. `kernel_pml4` is the true kernel PML4 phys base (stable throughout call).
2. No concurrent modifications to kernel_pml4 during the call (e.g., another CPU must not modify kernel_pml4 entries 256..511 while the copy loop is running).
3. Result (new PML4 base) must be stored and later installed as an address space's root (via CR3 or equivalent).
4. Caller must handle ASPACE_CREATE_OOM (RAX == 4294967295) and take appropriate action (panic, retry, or wait for phys_alloc to recover).

## Consumers

- **Phase 2 capability system:** aspace_create is the core operation for creating isolated address spaces in the userspace sandbox.
- **Process creation (future):** fork/spawn syscalls will call aspace_create to set up new process memory contexts.
- **phys_alloc:** aspace_create calls phys_alloc(0) to allocate the new PML4 page; expects a phys address or 0 (OOM).
- **Scheduler (R10+):** Early scheduler stubs may call aspace_create to initialize task address spaces.

## Retirement path

**Retires:** 
- R5.5-006 MVP stub (issue #250, paideia-as phase 5): unconditionally returned ASPACE_CREATE_OOM; no real allocation or copy.
- #913 MVP stub: aspace_create was an unsafe stub pending real MM activation; now superseded by real implementation.

**Successor:** None for phase 2. Future phases may add:
- Per-address-space capability tracking (e.g., address-space objects with revocation).
- Huge-page pre-allocation in kernel half.
- Address-space synchronization (copyback of kernel updates to all address spaces).
- NUMA-aware allocation (allocate PML4 from socket-local pool).

## Verification

1. **Symbolic execution** (paideia-as assembler feedback):
   - LEA with [R13 + R14*8] and [R12 + R14*8] must encode valid SIB (base+scale*index) byte sequences.
   - CMP/JGE, CMP/JLE branches must encode valid jumps (signed 8-bit or 32-bit displacements).
   - Push/pop r12, r13, r14 must use correct register encoding (register IDs 4, 5, 6 with REX prefix).
   - CALL phys_alloc must generate a valid relative call (near RIP-relative).

2. **Static checks:**
   - ASPACE_CREATE_OOM (4294967295 = 0xFFFFFFFF) must NOT sign-extend to 0xFFFFFFFFFFFFFFFF in 64-bit contexts; objdump should show as raw u64 constant.
   - Register allocation: r12, r13, r14 (callee-saved) used for kernel_pml4, new_pml4, loop counter; rax, r8 (caller-saved) used for temporaries and return.
   - Return paths: both success and OOM paths must pop r14, r13, r12 in reverse order before ret.
   - Prologue (3 pushes): mov r12, rdi must come after prologue, before any phys_alloc call.

3. **Behavioral checks** (regression suite, ./tools/run-smoke.sh):
   - boot_r8_only: basic boot path, no aspace_create yet (regression guard).
   - boot_r10, boot_r11, boot_r12, boot_r12_denial: phase-2+ capability tests with aspace_create active.
   - Expected: all tests pass with no #GP, #PF, or allocation failures; returned PML4 bases must be valid and distinct across calls.

4. **Disassembly verification:**
   - objdump -d build/kernel.elf --disassemble=aspace_create must show:
     - 3 PUSH r12, r13, r14 at prologue.
     - MOV r12, rdi (save kernel_pml4).
     - MOV rdi, 0; CALL phys_alloc.
     - CMP rax, 0; JE aspace_create_oom.
     - MOV r13, rax (save new PML4).
     - First loop: MOV r14, 0; CMP r14, 256; JGE; LEA r8; MOV rax, 0; MOV [r8], rax; ADD r14, 1; JMP (zero loop).
     - Second loop: MOV r14, 256; CMP r14, 512; JGE; LEA r8; MOV rax, [r8]; LEA r8; MOV [r8], rax; ADD r14, 1; JMP (copy loop).
     - Success return: MOV rax, r13; POP r14, r13, r12; RET.
     - OOM return: MOV rax, 0xFFFFFFFF; POP r14, r13, r12; RET.

## Failure modes

- **F1** (phys_alloc failure): If phys_alloc returns 0 (pool exhausted or allocator bug), aspace_create jumps to aspace_create_oom and returns ASPACE_CREATE_OOM (4294967295). Caller must detect (RAX == 4294967295 or ZF set) and handle gracefully (panic, retry with backoff, or wait for pool recovery).
- **F2** (kernel_pml4 stale or invalid): If kernel_pml4 does not point to a valid PML4 table in physmem, MOV RAX, [r12 + r14*8] during the copy loop may cause a page fault (#PF) or load garbage. Kernel crash or silent data corruption. Caller must ensure kernel_pml4 is the current kernel PML4 base; bootstrap guards this via boot.pdx assignment.
- **F3** (concurrent kernel_pml4 modification):** If another CPU modifies kernel_pml4 entries during the copy loop, the new address space may receive torn reads or intermediate values. Torn reads are unlikely (aligned u64 writes are atomic on x86), but flag-bit races are possible. Mitigated by: (a) single-threaded bootstrap (no concurrent modification), (b) kernel PML4 is immutable after boot (only new mappings added via aspace_map, which uses fences).
- **F4** (new PML4 never installed):** If caller receives the new PML4 base but never installs it (MOV CR3, new_pml4 or equivalent), the address space remains inactive. No error from aspace_create; caller's responsibility to activate.

## Cross-references

- **Issue:** #421 (R13-m2-003)
- **Plan:** design/infrastructure/phys-alloc-plan.md (Phase 7 allocation strategy)
- **Audit entries:**
  - r13-m2-001-phys-alloc.md (#419): phys_alloc interface and bump allocator.
  - r13-m2-002-aspace-map.md (#420): PML4 walking and TLB invalidation.
- **Related issues:**
  - #250 (R5.5-006): predecessor stub (paideia-as phase 5).
  - #913 (MVP stubs): aspace_create was rewritten as unsafe stub per this issue.
  - #420 (R13-m2-002): aspace_map (depends on PML4 created by aspace_create).
- **Intel SDM Vol 3A:**
  - §4.5: Linear-address translation, 4-level paging, PML4 structure.
  - §4.10.4.1: TLB invalidation and page-table entry coherence.
- **Modules:**
  - AspaceCreate (src/kernel/core/mm/aspace_create.pdx): this entry.
  - PhysAlloc (src/kernel/core/mm/phys_alloc.pdx): called by aspace_create(0).
  - Boot (src/kernel/core/arch/x86_64/boot.pdx): initializes kernel_pml4 before aspace_create is called.

---
**Audit:** R13-m2-003 bundle (July 2026)
