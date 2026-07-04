---
audit_id: r15-m3-002-star-selector
issue: 530
file: src/kernel/core/syscall/msr.pdx
function: syscall_msr_init
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-07-04
---

# AUDIT r15-m3-002 — IA32_STAR Selector Encoding (#530)

**Outcome: AUDIT-ONLY. No drift. No fix required.**

Reaffirms the r15-m3-001 (#529) finding for IA32_STAR (0xC0000081).
`syscall_msr_init` at `src/kernel/core/syscall/msr.pdx:38-43` programs
`STAR_VALUE = 0x0018000800000000` (line 15). Field decode per Intel SDM
Vol 3A §6.15 Table 6-16:

- **Bits 47:32 = 0x0008** — SYSCALL kernel base: kernel `CS = 0x08`
  (GDT slot 1, kernel code64, DPL=0), kernel `SS = 0x08 + 8 = 0x10`
  (GDT slot 2, kernel data, DPL=0). Matches the GDT layout installed by
  #423 (r13-m4-001).
- **Bits 63:48 = 0x0018** — SYSRET user base: user `SS = 0x18 + 8 = 0x20`
  (GDT slot 4, user data, DPL=3), user `CS = 0x18 + 16 = 0x28` (GDT slot
  5, user code64, DPL=3). SYSRET hardware forces RPL=3 on both, producing
  effective selectors `SS=0x23` and `CS=0x2B` — matching `USER_SS` /
  `USER_CS` from #522.

**Delta note vs. issue text:** #530's acceptance literal `0x001B_0008_...`
tags RPL=3 in the STAR user base. The programmed value `0x0018_0008_...`
omits RPL bits; SYSRET forces RPL=3 regardless, so both literals yield
the same effective ring-3 selectors. The current `0x0018` form is
RPL-clean and matches the GDT byte offset. No behavioural difference.

## References

- Source: `src/kernel/core/syscall/msr.pdx:15,38-43`
- Substrate: `src/kernel/boot/gdt.pdx` (GDT slots 1/2/4/5)
- Prior audit: `design/audit/entries/r15-m3-001-msr-audit-post-higher-half.md` §(b)
- Intel SDM Vol 3A §6.15 (SYSCALL/SYSRET fields)
