---
audit_id: boot-pagetables-001
issue: 2
file: src/kernel/boot/pagetables.pdx
function: (data; no executable code at this stage)
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT boot-pagetables-001 — page-table layout

## Justification
Page tables are kernel-internal data structures consumed by the MMU
(privileged sysreg state). Phase-1 stub: only first qword of each
table declared as the symbol anchor. Full 512-entry table allocation
requires paideia-as .bss support (issue filed; deferred to Phase 1.5).

The PDPT entries hard-code 1 GiB pages (PS=1 + P=1 + RW=1 = 0x83
flags) for the first 4 GiB of physical memory, supporting 64-bit
identity mapping at long-mode entry per Intel SDM Vol 3A §4.5.

## Known limitations
- 512-entry tables not yet allocated; long-mode entry (P1-003) requires
  this allocation to land before CR3 load succeeds.
- CPUID PDPE1GB probe + 2 MiB fallback (per spec AC) requires the
  unsafe-block CPUID encoder which is m2-002 (shipped). Wiring
  pends P1-003.

## Implementation notes
Path A approach: Phase-1 stub uses individual u64 constants for table
entry anchors. All constants are immutable and emitted to .rodata
(read-only). The full 512-entry tables (4 KiB each) await paideia-as
.bss allocation support (see cross-repo gap in paideia-as).
