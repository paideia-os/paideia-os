---
audit_id: r14b-m3-003-boot-stub-high-mapping
issue: 491
file: tools/boot_stub.S
function: (boot stub page-table setup)
effects: []
capabilities: [boot]
reviewed_by:
date: 2026-07-04
---

# Audit: r14b-m3-003 — Boot Stub PML4[256] Higher-Half Alias Verification (#491)

## Overview

Issue #491 (r14b-m3-003-boot-stub-page-tables-add-high-mapping) stated the goal: ensure the kernel's higher-half virtual address space is mapped by installing a PML4[256] alias that resolves to the same PDPT as PML4[0]. Empirical verification post-#489 (linker VMA/LMA split) confirms that this alias was already installed during r13-m3-001 Phase 1 (#445). The boot stub at `tools/boot_stub.S:39–42` contains the alias population, and post-#489 kernel execution successfully runs `.text` at higher-half VMA `0xFFFF800000...` via this mapping. No code changes are required; the acceptance criteria are satisfied by pre-existing work.

## Current Mapping

The boot stub establishes a two-level page-table alias for 4 GiB of identity-mapped physical memory:

| Structure | Entry | Target | Flags | Coverage |
|-----------|-------|--------|-------|----------|
| PML4[0] | → PDPT (phys) | Identity first 4 GiB | 0x03 (RW\|P) | VA `0x00000000..0xFFFFFFFF` → phys `[0..4 GiB)` |
| PML4[256] | → PDPT (phys) | Same PDPT as PML4[0] | 0x03 (RW\|P) | VA `0xFFFF800000000000..0xFFFF8000FFFFFFFF` → phys `[0..4 GiB)` |
| PDPT[0] | → 1 GiB huge page | Phys 0x00000000 | 0x83 (PS\|RW\|P) | Phys [0..1 GiB) |
| PDPT[1] | → 1 GiB huge page | Phys 0x40000000 | 0x83 (PS\|RW\|P) | Phys [1..2 GiB) |
| PDPT[2] | → 1 GiB huge page | Phys 0x80000000 | 0x83 (PS\|RW\|P) | Phys [2..3 GiB) |
| PDPT[3] | → 1 GiB huge page | Phys 0xC0000000 | 0x83 (PS\|RW\|P) | Phys [3..4 GiB) |

Both PML4[0] and PML4[256] point to the same PDPT structure, so virtual address walks through either entry (low or high) resolve identically to physical addresses. This is the architectural foundation for the kernel's execution model: boot stub and Phase 1 execute via PML4[0] (low VA), while Phase 2+ (deferred) can execute via PML4[256] (high VA) with no change to the underlying physical mapping.

## Empirical Proof

Post-#489 verification via debugger (reported in #489) confirms that the walk from PML4[256] through PDPT[0] to physical memory is correct and functional:

- **High-VA kernel symbol:** `syscall_entry` at VMA `0xffff8000001074a0` (high-half address)
- **Physical address:** `0x1074a0` (low physical)
- **Address resolution:** `0xffff8000001074a0 - 0xFFFF800000000000 = 0x1074a0` ✓
- **Execution result:** The kernel's syscall dispatch executes correctly from this high VA, proving PML4[256]→PDPT[0]→phys walk is valid.
- **Regression smoke tests:** All five boot modes (boot_r8_only, boot_r10, boot_r11, boot_r12, boot_r12_denial) produce byte-identical output, confirming that the alias, though mapped, does not introduce spurious faults or TLB divergence during Phase 1 (which executes via PML4[0]).

## Cross-Reference to Code

1. **`tools/boot_stub.S:35–42`** — PML4[256] alias installation:
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

2. **`tools/boot_stub.S:25–33`** — PDPT huge-page setup (identity-mapped 1 GiB pages):
   ```asm
   movl $0x00000083, pdpt + 0
   movl $0,          pdpt + 4
   movl $0x40000083, pdpt + 8
   movl $0,          pdpt + 12
   movl $0x80000083, pdpt + 16
   movl $0,          pdpt + 20
   movl $0xC0000083, pdpt + 24
   movl $0,          pdpt + 28
   ```

3. **`src/kernel/link.ld:9–12`** — VMA identity-alias formula:
   ```
   KERNEL_VMA_BASE = 0xFFFF800000000000 is PML4[256]'s alias base: the
   boot stub aliases PML4[256] → PDPT[0..3] identity, so VMA
   (KERNEL_VMA_BASE + phys) → phys directly. Kernel .text at
   VMA 0xFFFF800000103xxx, LMA 0x103xxx executes correctly.
   ```

## Cross-Reference to Milestones

- **#445 (r13-m3-001 Phase 1)** — Landed the PML4[256] alias in `tools/boot_stub.S:35–42` under the original design scope. This issue (#491) audits the existing work's correctness post-#489.

- **#489 (r14b-m3-001, Linker VMA/LMA split)** — Updated `src/kernel/link.ld` to map kernel `.text` at VMA `0xFFFF800000...` with LMA in the low region. This depends on the PML4[256] alias already existing; the audit confirms the dependency is satisfied.

- **#490 (r14b-m3-002, imm64 overflow audit)** — Verified no live imm32 overflow risks in the linker split; confirmed all R_X86_64_32 relocations remain confined to boot_stub.o low-VA structures and do not target the high-VA alias.

- **#492 (r14b-m3-004, follow-up)** — Add `_kernel_high_entry` symbol for explicit higher-half entry point documentation. Still needed; out of scope for this audit.

- **#493 (r14b-m3-005, follow-up)** — Boot-stub far-jmp transition from low VA to high VA. Still needed; out of scope for this audit.

## Conclusion

The acceptance criteria for #491 are satisfied by pre-existing work:

1. **PML4[256] alias installed:** Yes, by #445 at `tools/boot_stub.S:35–42`.
2. **Alias resolves to correct PDPT:** Yes, both PML4[0] and PML4[256] point to the same PDPT with identical flags (0x03).
3. **Kernel executes at high VA:** Yes, post-#489, kernel `.text` at VMA `0xFFFF800000...` executes correctly via the alias walk.
4. **No live bugs:** Confirmed by #489 debugger verification and smoke-test byte-identity.

**Verdict:** AC met by pre-existing work. Close as done.
