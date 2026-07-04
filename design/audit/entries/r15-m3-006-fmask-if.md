---
audit_id: r15-m3-006-fmask-if
issue: 534
file: src/kernel/core/syscall/msr.pdx
function: syscall_msr_init
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-07-04
---

# AUDIT r15-m3-006 — IA32_FMASK IF-Clear on SYSCALL Entry (#534)

**Outcome: AUDIT-ONLY. No drift. No fix required.**

Reaffirms the r15-m3-001 (#529) finding for IA32_FMASK (0xC0000084).
`syscall_msr_init` at `src/kernel/core/syscall/msr.pdx:52-56` programs
`FMASK_VALUE = 0x00047700` (line 16) via `mov rax, 0x47700; xor rdx,
rdx; wrmsr`. Semantics: on SYSCALL entry, hardware clears every RFLAGS
bit whose position is set in FMASK.

Decomposition of `0x00047700` (matches Linux `SYSCALL_MASK`):

| Bit  | Mask     | Flag | Effect on SYSCALL entry           |
|------|----------|------|-----------------------------------|
| 8    | 0x00100  | TF   | disable single-step                |
| **9**| **0x00200** | **IF** | **disable interrupts (audit target)** |
| 10   | 0x00400  | DF   | clear direction flag              |
| 12-13| 0x03000  | IOPL | force I/O priv 0                   |
| 14   | 0x04000  | NT   | clear nested-task                 |
| 18   | 0x40000  | AC   | disable alignment check           |

**IF audit gate satisfied**: bit 9 (`0x200`) is present in the mask, so
`RFLAGS.IF` is cleared automatically on every SYSCALL entry — the kernel
executes its syscall slow path (r15-m3-005) with interrupts disabled, as
R14B requires (no in-kernel blocking / preemption yet). No explicit `sti`
in `syscall_dispatch`. Kernel-side ISRs remain reachable through the IDT
on external ring-3 execution outside of syscall dispatch.

**Runtime trace requirement**: #534's second acceptance bullet ("syscall
trace shows IF=0 during dispatch") is a runtime witness that requires
ring-3 execution — deferred with the rest of the ring-3 witness path
(#650, #652 per r15-m2-006 audit) and #533's dispatch trace. FMASK
programming itself is structurally verified above.

## References

- Source: `src/kernel/core/syscall/msr.pdx:16,52-56`
- SYSCALL entry consumer: `src/kernel/core/syscall/entry.pdx`
- Prior audit: `design/audit/entries/r15-m3-001-msr-audit-post-higher-half.md` §(d)
- Linux constant: `arch/x86/include/uapi/asm/processor-flags.h` (`SYSCALL_MASK = 0x47700`)
- Intel SDM Vol 3A §6.15, §3.4.3 (RFLAGS)
