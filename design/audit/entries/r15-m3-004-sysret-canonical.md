---
audit_id: r15-m3-004-sysret-canonical
issue: 532
file: src/kernel/core/syscall/msr.pdx
function: syscall_msr_init
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-07-04
---

# AUDIT r15-m3-004 — SYSRET Canonicality + LSTAR Sign-Extension (#532)

**Outcome: AUDIT-ONLY. No drift. No fix required.**

Verifies that IA32_LSTAR is canonical (bit 47 sign-extended into bits
63:48) — a non-canonical LSTAR raises `#GP(0)` on `SYSCALL`, and a
non-canonical `rcx` at `SYSRET` behaves similarly for the return path.
`syscall_msr_init` at `src/kernel/core/syscall/msr.pdx:46-50` writes
LSTAR via `lea rax, [rip + syscall_entry]`. `syscall_entry` lives in
`.text.syscall_trampoline` at VA `0xFFFF800000104000` (verified in #529
audit disassembly). Bit 47 of that VA is 1; bits 63:48 = `0xFFFF` — full
sign-extension. Canonical.

**SYSRET-side canonicality**: `sysret` (entry.pdx:62) loads user RIP
from `rcx`. `rcx` was pushed at ring-3 entry by hardware from user
RIP (canonical by IF/ring-3 execution invariant) and popped/restored by
entry.pdx:52 before `sysretq`. Provided the user context that issued
`SYSCALL` had canonical RIP (enforced by page-table VA layout — user
code lives in the low half `0x0000_0000_0040_0000` per R15.M2 user
_start map, bits 63:47 = 0, canonical), `sysret` returns to a
canonical address.

**Effective ring-3 selectors on SYSRET** (per STAR audit r15-m3-002):
`CS = 0x2B` (0x28 | RPL3), `SS = 0x23` (0x20 | RPL3). Both target
DPL=3 GDT descriptors and match `USER_CS`/`USER_SS` (#522). No `#GP` on
segment load.

## References

- Source: `src/kernel/core/syscall/msr.pdx:46-50`
- SYSRET site: `src/kernel/core/syscall/entry.pdx:52,62`
- Prior audit: `design/audit/entries/r15-m3-001-msr-audit-post-higher-half.md` §(c)
- Linker: `src/kernel/link.ld` (KERNEL_VMA_BASE = 0xFFFF800000000000)
- Intel SDM Vol 3A §6.15, §3.3.7.1 (canonical addresses)
