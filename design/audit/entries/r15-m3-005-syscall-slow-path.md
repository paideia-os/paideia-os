---
audit_id: r15-m3-005-syscall-slow-path
issue: 533
file: src/kernel/core/syscall/entry.pdx
function: syscall_entry
effects: [mem, sysreg]
capabilities: [cap, sched]
reviewed_by:
date: 2026-07-04
---

# AUDIT r15-m3-005 — SYSCALL Entry Slow Path (#533)

**Outcome: AUDIT-ONLY. Runtime ring-3 trace deferred to #645 blocker.**

Traces the SYSCALL entry sequence in `src/kernel/core/syscall/entry.pdx`
end-to-end against Intel SDM Vol 3A §6.15 and the KPTI/swapgs
disciplines landed by R14b-M4:

1. **swapgs** (line 26) — first instruction; kernel `GS_BASE` (from
   IA32_KERNEL_GS_BASE per r15-m3-003) becomes active. Landed by #503
   (R14b-M4-007).
2. **save user rsp** (line 29) — `mov [rip + _saved_user_rsp], rsp`
   before any stack switch. RIP-relative store to high-VA `.bss`
   symbol; safe because user CR3 still maps the higher half (KPTI
   kernel PML4 present in user CR3 too, per R14b-M3 audit).
3. **save user CR3 + flip to kernel PML4** (lines 30-33) — `_saved_user_pml4
   <- cr3`; `cr3 <- _kernel_pml4_pa`. Landed by #502 (R14b-M4-006).
4. **load kernel rsp** (line 34) — `lea rsp, [rip + _syscall_kernel_stack
   + 16384]` (top of 16 KiB BSS stack).
5. **preserve ring-transition state** (lines 37-39) — push `rcx` (user
   RIP), `r11` (user RFLAGS), `rax` (sysno).
6. **SYSCALL→SysV shuffle** (lines 42-46) — reverse-dep order:
   `r8<-r10`, `rcx<-rdx`, `rdx<-rsi`, `rsi<-rdi`, `pop rdi` (sysno).
7. **call syscall_dispatch** (line 49) — 13-entry table per r13-m5-003
   (#429).
8. **restore + return** (lines 52-58) — pop `r11`/`rcx`, restore user
   rsp, restore user CR3, `swapgs`, `sysretq` (encoded `48 0F 07`).

**Ordering caveat — pre-existing bug tracked at #645**: the current
sequence saves user rsp AND user CR3 via RIP-relative stores while the
user CR3 is still active. This works today only because R14b-M3 KPTI
keeps the kernel higher-half mapped in user CR3 (non-strict KPTI). The
strict-KPTI fix (flip CR3 first, then save rsp to a trampoline page)
lands with #645; not blocking R15.M3 audit gates because no ring-3
code has yet been reached.

**Runtime demonstration blocked**: the `qemu -d cpu` CS-transition
trace (`0x2B → 0x08 → 0x2B`) and `sys_debug_puts` round-trip
witnesses required by #533's acceptance criteria depend on
`enter_userland_initial` being driven with a real ring-3 payload and a
witness marker on return. Substrate for entry is complete (#526);
witness path deferred (#650, #652 per r15-m2-006 audit).

## References

- Source: `src/kernel/core/syscall/entry.pdx:20-64`
- CR3 flip origin: r14b-m4-006 (#502)
- swapgs origin: r14b-m4-007 (#503)
- Related bug: #645 (save-user-rsp-before-flip ordering)
- Ring-3 witness path: #650, #652 (deferred)
- Prior audits: `r13-m5-003-syscall-table.md`, `r15-m3-001-msr-audit-post-higher-half.md`
