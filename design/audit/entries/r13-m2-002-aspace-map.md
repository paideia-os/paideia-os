---
audit_id: r13-m2-002-aspace-map
issue: 420
file: src/kernel/core/mm/aspace_map.pdx
function: aspace_map
effects: [mem, sysreg]
capabilities: []
retires: aspace-map-001
reviewed_by:
date: 2026-07-03
---

# AUDIT r13-m2-002 — Real 4-level page-table walker + INVLPG (R13-m2-002)

## Justification

`aspace_map` implements the core phase-2 capability-system requirement: virtual-address mapping via live page-table modification. The function (1) walks a 4-level x86-64 page-table hierarchy (PML4 → PDPT → PD → PT), (2) allocates intermediate tables on miss via phys_alloc, (3) writes the leaf PTE with physical address and access flags, and (4) invalidates the TLB with INVLPG.

Both page-table writes and INVLPG are unsafe: page-table writes change the active virtual-memory mapping for the running CPU (modifying per-level metadata and leaf translations), and INVLPG is a privileged TLB-management instruction that must follow each PTE write to preserve correctness. This unsafe block gates reads from the PML4 base and intermediate table pointers (computed via phys_alloc), writes to 4 table levels, and a single TLB invalidation.

Citation: Intel SDM Vol 3A §4.5 (linear-address translation; 4-level paging and 9-bit-per-level indexing) and §4.10.4.1 (INVLPG semantics and TLB invalidation discipline).

## Intended sequence

1. Extract 4 level-indices from vaddr via right-shift and mask:
   - i4 = (vaddr >> 39) & 0x1FF  [bits 47:39]
   - i3 = (vaddr >> 30) & 0x1FF  [bits 38:30]
   - i2 = (vaddr >> 21) & 0x1FF  [bits 29:21]
   - i1 = (vaddr >> 12) & 0x1FF  [bits 20:12]

2. PML4 walk (level 4):
   - Load entry: mov r9, [r12 + i4*8]  (r12 = as_root, the PML4 base phys)
   - If (r9 & PRESENT_BIT), mask to phys base (r9 & ~0xFFF) and descend
   - Else, phys_alloc(0) a new PDPT, write [r12 + i4*8] = phys | 0x07 (PRESENT|RW|US), descend

3. PDPT walk (level 3): repeat step 2 with i3, shift 30, labels *_pdpt

4. PD walk (level 2): repeat step 2 with i2, shift 21, labels *_pd

5. PT walk (level 1): no allocation (leaf is target)
   - Compute leaf PTE: (paddr & 0xFFFFFFFFFF000) | flags | PRESENT
   - Write: [r12 + i1*8] = pte

6. TLB invalidation: invlpg [vaddr]  (per SDM Vol 3A 4.10.4.1)

7. Return MAP_OK (0) on success, MAP_OOM (4294967294) if phys_alloc fails

## Invariants

- **I1** (one PTE per call): each call writes exactly one leaf PTE (level-1 table, offset i1*8).
- **I2** (TLB coherence): INVLPG [vaddr] is issued after the leaf PTE write, before return.
- **I3** (no page faults during walks): all page-table memory (PML4, PDPT, PD, PT) must be pinned (not subject to eviction or page faults); caller guarantees tables are in RAM and present in per-CPU physmem bookkeeping.
- **I4** (root table exists): the PML4 table (as_root) is already allocated and present at boot; aspace_map does not allocate the root.

## Non-invariants

- **NI1** (concurrent walks): aspace_map does NOT serialize across concurrent address-space maps or concurrent PT modification of the same vaddr on different CPUs. Caller must hold an address-space lock or equivalent.
- **NI2** (vaddr range coverage): aspace_map maps exactly one 4 KiB page (one PTE). Multi-page ranges are the caller's responsibility.
- **NI3** (flag validation): aspace_map does NOT validate flags (RW, US, etc.) or enforce policy; caller is responsible for consistency (e.g., not mapping user address ranges as supervisor-only).
- **NI4** (paddr validation): aspace_map does NOT verify paddr is a valid physical address or check for physical-memory reservation; caller must reserve and track paddr allocation.
- **NI5** (TLB scope): INVLPG [vaddr] flushes the TLB entry for vaddr on the current CPU only. Multi-CPU invalidation (IPI) is caller's responsibility.

## Caller discipline

```
RDI ← as_root      (PML4 phys base, u64)
RSI ← vaddr        (target virtual address, u64)
RDX ← paddr        (source physical address, u64)
RCX ← flags        (access flags: P|RW|US|..., u64)

RAX ← return value (MAP_OK=0 or MAP_OOM=4294967294, u64)
```

Caller must ensure:
1. `as_root` points to a pinned, allocated PML4 table (already present at boot).
2. `vaddr` is a canonical x86-64 address (sign-extended; typically < 2^47 for userspace, >= 2^63 for kernel).
3. `paddr` is a valid, allocated physical address (4-KiB aligned or masked to leaf).
4. Address space is locked or not subject to concurrent modification.
5. All intermediate tables (PDPT, PD, PT) that are allocated by aspace_map are marked pinned in the physmem allocator.

## Consumers

- **Phase 2 capability system**: aspace_map is the core operation for activating capability-based virtual-address mappings at userspace boundary.
- **phys_alloc**: aspace_map calls phys_alloc(0) to allocate intermediate tables; expects a phys address or 0 (OOM).
- **TLB invalidation path**: aspace_map directly uses invlpg (no helper); this is the only privileged TLB operation in the MM API.

## Retirement path

**Retires:** audit entry aspace-map-001 (R5.5-003, phase 5 stub with honest scope gaps).

**Successor:** none (this is the real implementation for phase 2); future phases may add:
- Huge-page support (2 MiB, 1 GiB) with additional level-skip logic.
- Fault-on-write (copy-on-write) handlers (requires additional PTE state tracking).
- Performance counters (per-address-space map latency, allocation stalls).

## Verification

1. **Symbolic execution** (paideia-as assembler feedback):
   - All 4 level indices correctly extracted: shr [shift], and 0x1FF.
   - All SIB [r12 + rax*8] base+displacement operands encode to valid byte sequences.
   - lea with [r12 + rax*8] computes correct offsets.
   - invlpg [rdi] encodes to a valid x86-64 instruction (0F 01 3F or similar).

2. **Static checks**:
   - MAP_OOM sentinel (4294967294 = 0xFFFFFFFE) does NOT sign-extend to 0xFFFFFFFFFFFFFFFE in objdump.
   - Register allocation: r12–r15 (callee-saved) used for state; rax, r8–r10 (caller-saved) used for temporaries.
   - Return path: pop r15, r14, r13, r12 in reverse order; ret on both success and OOM.

3. **Behavioral checks** (regression suite, ./tools/run-smoke.sh):
   - boot_r8_only: basic boot path, no advanced MM (regression guard).
   - boot_r10, boot_r11, boot_r12, boot_r12_denial: phase-2 capability boundary tests with aspace_map active.
   - Expected: all tests pass with no #PF, #GP, or TLB coherence failures.

4. **Timing and resource checks**:
   - Worst-case: 4 phys_alloc calls (one per level if all tables miss); each phys_alloc is O(1) per bitmap search.
   - One INVLPG per map (TLB invalidation cost is < 100 cycles on modern x86).
   - Stack use: 32 bytes (4 pushes, 4 pops); no dynamic allocation.

## Failure modes

- **F1** (phys_alloc fails at any level): return MAP_OOM (4294967294). Caller must handle: may indicate physmem exhaustion or allocator bug.
- **F2** (invalid as_root or table pointers): #PF or memory exception during [r8] load/store. Caller must ensure tables are pinned; kernel crash if as_root is stale.
- **F3** (canonical-address violation): vaddr > 2^47 (user half) or < 2^63 – 1 (kernel half). Behavior undefined (may map to wrong level). Caller must validate vaddr.
- **F4** (TLB coherence loss): if invlpg is omitted or delayed (e.g., due to exception before invlpg), stale TLB entries persist. Cached translations point to old PTE values, causing silent data corruption. This is a catastrophic correctness failure; audit invariant I2 prevents it.

## Cross-references

- **Intel SDM Vol 3A §4.5**: Linear-address translation, 4-level paging, 9-bit indexing per level, PTE structure.
- **Intel SDM Vol 3A §4.10.4.1**: INVLPG instruction, TLB invalidation semantics, scope (single-entry).
- **design/phys_alloc.md**: phys_alloc(0) interface, return value semantics, OOM behavior.
- **design/pt_walk.md**: page-table entry structure (PTE flags, present bit, mask definitions).
- **issue #247 (R5.5-003, aspace-map-001)**: predecessor entry; gaps (no SIB encoding, no INVLPG encoder) filled in R13-m2-002.
- **issue #420 (R13-m2-002)**: this entry; real 4-level walker implementation.
