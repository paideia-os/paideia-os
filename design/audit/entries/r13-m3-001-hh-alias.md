# Audit: r13-m3-001 Phase 1 — PML4[256] Higher-Half Alias (#445)

## Justification

The higher-half kernel virtual address space (0xFFFF_8000_0000_0000) requires an alias entry in the PML4. PML4[256] is populated with a pointer to the same PDPT as PML4[0], creating an identity-mapped window at the higher-half VA. This alias is essential for r13-m3-002 (Phase 2) KPTI page-table copy logic, which will shadow user-space page tables and switch between them via far-jmp. The actual kernel execution remains in the low VA (0x0) during Phase 1; the higher-half mapping is passive until Phase 2 (#480) relocates the kernel VMA and performs the far-jmp transition.

## Intended Sequence

Four assembly lines inserted in `tools/boot_stub.S` after PDPT[0..3] population and before CR3 load:

```asm
    # R13-m3-001 Phase 1 (#445): higher-half aliasing.
    # PML4[256] mirrors PML4[0] so VA 0xFFFF_8000_XXXX_XXXX resolves via
    # the same PDPT (identity map). Installs the mapping only; execution
    # remains at low VA. Phase 2 (#480) relocates kernel VMA.
    movl $pdpt, %eax
    orl  $0x03, %eax               # RW | P
    movl %eax, pml4 + (256 * 8)    # PML4[256].lo = PDPT phys | flags
    movl $0,   pml4 + (256 * 8) + 4  # PML4[256].hi = 0
```

Placement: between existing PDPT population (line 33) and CR3 load (line 35 in original). No execution-flow change; all operations are data writes to the PML4 page table.

## Invariants

**I1: PML4[0] Preserved**
The existing PML4[0] entry (populated at boot lines 19–23) remains unchanged and continues to alias the identity-mapped low region (0x0–0xFFFFFFFF). This invariant is critical for boot-stub execution and Phase-1 kernel operation.

**I2: PML4[256] Equals PML4[0] Except for Caller Checks**
PML4[256].lo and PML4[256].hi are set identically to PML4[0] (both point to the same PDPT physical address with RW | P flags). PDPT entries accessed through either PML4 entry resolve identically. Future phases (KPTI copy) may diverge the PDPT contents, but at Phase 1's close, both entries are identical.

## Non-Invariants

**NI1: Execution Still at Low VA**
The kernel's program counter remains in the identity-mapped low region (0x100000). The higher-half PML4[256] mapping is installed but not used for instruction fetch or TLB fills during Phase 1. This is by design; Phase 2 (#480) will perform a far-jmp to switch to the higher-half VA space.

**NI2: Phase 2 VMA Move Deferred**
The VMA (Virtual Memory Address) is not updated in `link.ld` or `.text` section mapping. `KERNEL_VMA_HIGHER_HALF` remains a placeholder comment. Actual kernel relocation occurs in Phase 2 (#480), which rewrites page tables and performs the transition. This phase only installs the alias; Phase 2 activates it.

## Verification

After build and boot:

1. **Kernel build succeeds:**
   ```bash
   ./tools/build.sh
   ```
   Confirms that boot_stub.S assembles cleanly with the new PML4[256] population lines.

2. **Smoke tests pass byte-identically:**
   All five regression modes (boot_r8_only, boot_r10, boot_r11, boot_r12, boot_r12_denial) must pass with no output divergence. The new PML4[256] slot is not dereferenced during Phase 1, so regression output is unaffected.

3. **QEMU monitor inspection (manual, not scripted):**
   - Launch QEMU with `-monitor stdio`
   - At break-point, `info mem` shows both low and higher-half mappings
   - `xp/x 0x100000` displays kernel code at low VA
   - `xp/x 0xffff800000100000` displays the same code via the higher-half alias
   - Both should be byte-identical

## Cross-References

- **Issue #445:** Implement PML4[256] higher-half alias (r13-m3-001 Phase 1)
- **Issue #480:** Relocate kernel VMA and perform far-jmp to higher-half (r13-m3-002 Phase 2)
- **r13-preflight §F:** VMA strategy and higher-half setup (references PML4[256] and deferred Phase 2 transition)
- **tools/boot_stub.S:** Lines 35–42 (new code block)
- **src/kernel/link.ld:** Lines 25–28 (comment update, KERNEL_VMA_HIGHER_HALF symbol)

## Errata

**Plan discrepancy:** The original plan (r13-preflight §4, m3-001) stated PDPT[510] as the higher-half location, implying VMA 0xFFFF_FFFF_C000_0000 (PML4[511]/PDPT[510]). This was incorrect; the canonical higher-half VMA 0xFFFF_8000_0000_0000 decodes to PML4[256]/PDPT[0]. The adopted approach (PML4[256]) aligns with this VMA and is consistent with Phase 2 KPTI design (single PDPT per isolation domain). This correction was made during audit and is now the authoritative specification.

