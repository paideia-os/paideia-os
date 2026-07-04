---
audit_id: r15-m3-003-kernel-gs-base
issue: 531
file: src/kernel/core/syscall/msr.pdx
function: syscall_msr_init
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-07-04
---

# AUDIT r15-m3-003 — IA32_KERNEL_GS_BASE Init (#531)

**Outcome: AUDIT-ONLY. Follow-up filed for _cpu_locals rebase.**

Reaffirms the r15-m3-001 (#529) finding for IA32_KERNEL_GS_BASE
(0xC0000102). `syscall_msr_init` at `src/kernel/core/syscall/msr.pdx:58-63`
programs the MSR via `lea rax, [rip + _cpu0_kernel_gs]` followed by
`edx:eax` split and `wrmsr`. Disassembly resolves the target to a
high-VA `.bss` symbol (verified in #529 audit: `0xFFFF80000052B190`).
`swapgs` in `syscall_entry` (entry.pdx:26) will therefore load
`GS_BASE` from a valid kernel-mapped 16-byte BSS placeholder on ring
transition — sufficient for R15.M3 audit gates. MSR is written
unconditionally at boot from `kernel_main_64`, well before any ring-3
code exists.

**Delta note vs. issue acceptance:** #531 requests
`&_cpu_locals[0]` (128-byte per-CPU control block from
`src/kernel/core/cpu/local.pdx:15`, landed by R14b-M5-001 #506) instead
of the r13-era `_cpu0_kernel_gs` (16-byte stub in `msr.pdx:18`). Both
symbols are high-VA BSS and both satisfy "MSR initialized" for R15.M3
audit-only gates. Rebase to `&_cpu_locals[0]` is a mechanical follow-up
required before per-CPU state (current TCB, TLB mailbox) is dereferenced
from `syscall_entry` — filed for R16 substrate work, does not block this
milestone.

## References

- Source: `src/kernel/core/syscall/msr.pdx:18,58-63`
- Target rebase substrate: `src/kernel/core/cpu/local.pdx:15` (`_cpu_locals`)
- Prior audit: `design/audit/entries/r15-m3-001-msr-audit-post-higher-half.md` §(e)
- Intel SDM Vol 3A §4.2, §6.15 (KERNEL_GS_BASE / swapgs)
