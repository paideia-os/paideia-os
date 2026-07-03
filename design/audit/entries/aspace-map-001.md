---
audit_id: aspace-map-001
issue: 247
file: src/kernel/core/mm/aspace_map.pdx
function: aspace_map / pte_invlpg
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT aspace-map-001 — 4-level page-table map + INVLPG (R5.5-003)

## Justification
`aspace_map` writes into live page-table memory and invalidates the TLB. Both
are unsafe: a page-table write changes the active virtual-memory mapping for the
running CPU, and INVLPG is a privileged TLB-management instruction. The walk
itself reads page-table entries from raw physical memory at computed offsets.

Citation: Intel SDM Vol 3A §4.5 (4-level paging) for the 9-bit-per-level index
layout; §4.10.4.1 (INVLPG) for TLB invalidation discipline. **Verification TODO.**

## Intended sequence
1. Extract i4=bits[47:39], i3=[38:30], i2=[29:21], i1=[20:12] from vaddr.
2. PML4: `mov rax,[as_root + i4*8]`; if `rax & PRESENT` descend, else
   `phys_alloc(0)` a PDPT, write `mov [as_root + i4*8], new|PRESENT|RW`.
3. Repeat for PDPT->PD and PD->PT.
4. Leaf: `mov [pt_base + i1*8], (paddr & 0xFFFFFFFFFF000)|flags|PRESENT`.
5. `invlpg [vaddr]`.

## Phase-5 honest scope gaps
- **Base+displacement memory operands** (`mov rax,[base+idx*8]`): not in
  paideia-as 0.6.0. Gates the entry loads, parent writes, and leaf write.
- **INVLPG encoder**: not implemented; `pte_invlpg` emits `mov rax, rax`.
- Implemented for real: the four 9-bit index extractions and the leaf-PTE
  composition `make_pte(paddr, flags)`.

## Caller discipline
```
RDI ← as_root (PML4 phys base)
RSI ← vaddr,  RDX ← paddr,  RCX ← flags
```

## Verification (when encoders land)
```bash
./tools/paideia-as build --emit elf64 src/kernel/core/mm/aspace_map.pdx -o aspace_map.o
objdump -d aspace_map.o   # expect 4 indexed loads, up to 3 parent writes, 1 leaf write, 1 invlpg
```
Behavioral test (R5.5-003): map vaddr 0x4000_0000 -> paddr 0x10_0000 RW; read
back via a walk; expect the leaf PTE = 0x100000 | RW | PRESENT.

> Retired: 2026-07-03 by r13-m2-002-aspace-map (issue #420). Content preserved for historical reference.
