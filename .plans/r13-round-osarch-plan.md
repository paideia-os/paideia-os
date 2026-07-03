# PaideiaOS R13 round — Ring-3 userspace + fully-featured shell OS

**Revision:** 2 (2026-07-03) — expanded per user directive to incorporate all previously-deferred items rationally.
**Author:** osarch + softarch (synthesis)
**Repo:** paideia-os/paideia-os (kernel; tools/paideia-as submodule pinned at ae6039b — v0.11.0-28)
**Companion repo:** paideia-os/paideia-as
**Predecessor:** R12 CLOSED (r12-closed tag, commit 54c464e)
**Reference plans:** `.plans/r12-round-osarch-plan.md`

## Round objective (revised)

Take paideia-os from a single-CPU ring-0-only kernel with observable cap dispatch (R12 close) to a **complete OS with**:

- Multi-process ring-3 userspace with cooperative + preemptive scheduling
- Interactive shell that can `exec` external programs from a filesystem
- Signal delivery (Ctrl-C, SIGKILL, SIGSEGV)
- Full 16-kind cap dispatch (KIND_PROCESS, KIND_THREAD, KIND_PAGE_TABLE, and 6 more)
- Higher-half kernel VA + KPTI + PCID (proper OS memory discipline)
- Multicore (SIPI + per-CPU GS + IPI + TLB shootdown)
- Filesystem (VFS + tmpfs; block-device abstraction)
- Real MMIO through aspace_map (retiring D7-004 synthesis stub)

The revised R13 is a **mega-round**. Every scope-boundary item from Revision 1 is now inside R13. Only items that require paideia-as features currently unavailable (curried-call plumbing → Phase 20+; large-page 2 MiB mapping in the pt walker → post-R13) are honestly deferred to R14+.

## 0. Scope decision (revised)

Considered scoping options for Revision 2:

- **Full incorporation of all deferred items (SELECTED).** 16 milestones, ~63 issues, 45-70 cycle estimate. Delivers a genuinely usable operating system after R13.
- Minimum shell (was Revision 1). 10 milestones, 27 issues. Delivers "typed input echoed back" but nothing beyond.
- Split R13 into R13.a (userspace foundation) + R13.b (multi-process + fs + signals) + R13.c (multicore). Rejected because the user's directive is to close the gap to "a proper shell session" — that requires all three phases.

Justification against project pillars:

1. **Pillar 3 (microkernel)**: fully-featured shell exercises the microkernel discipline end-to-end (every user op via cap_invoke, every context switch via kernel-authorized cap invocation).
2. **Pillar 6 (security)**: full 16-kind rights lattice + KPTI + user-space cap tables makes rights enforcement uniform.
3. **Pillar 10 (functional discipline)**: shell + VFS + fork/exec all live in userspace as pure loops; kernel is glue.
4. **Pillar 11 (research-driven)**: seL4 + L4Ka disciplines finally have full runtime substrate to inhabit.

## 1. Deferrals honestly kept for R14+

Only items requiring substrate NOT achievable in R13 timeframe:

- **Curried-call plumbing** — needs paideia-as Phase 20+; deferred with note.
- **Large-page (2 MiB) mapping in pt walker** — needs paideia-as PDPT huge-page semantics; deferred to R14 (R13 uses 4 KiB only).
- **Real network stack** — not on shell path.
- **Persistent filesystem beyond tmpfs** — needs block device drivers; tmpfs is sufficient for R13 shell.
- **NUMA awareness** — R14+.
- **Hot-plug CPU** — R14+.
- **Real ACPI parsing** — R14+.

Everything else that was previously deferred is now in-scope.

## 2. Pre-flight inventory (revised)

### 2.1 paideia-as ae6039b encoder surface for revised R13

Per softarch's audit + Revision 2 additions:

| Instruction | Status | R13 milestone using it |
|---|---|---|
| swapgs / syscall / sysretq / wrmsr / rdmsr / iretq / lgdt / lidt / mov cr3 / invlpg / hlt | all present | m4, m7 (baseline) |
| **ltr r16** | **MISSING → PA-R13-001** | m4 TSS install |
| **GS-relative mem operand** | **MISSING → PA-R13-002** | m4 (soft); m13 (HARD for multicore) |
| **xchg [mem], reg** | **MISSING → PA-R13-003** | m10 spinlocks; m13 multicore atomics |
| **lock cmpxchg** | **MISSING → PA-R13-004** | m10 CAS; m13 multicore |
| **mfence** | **MISSING → PA-R13-005** | m13 memory ordering |
| **mov cr4, r64** | verify (probably present) | m3 SMEP/SMAP/PCID |
| **wrmsr IA32_EFER (NX bit)** | present (uses wrmsr) | m3 NX enable |
| **fxsave/fxrstor** | verify — needed for signal frames | m11 signal delivery |
| **rep movsb** | verify — needed for memcpy in loader | m8 |

**Escalations required for revised R13:**

- **PA-R13-001 (HARD, m4)**: ltr r16.
- **PA-R13-002 (HARD for m13, SOFT for m4)**: GS-relative mem operand.
- **PA-R13-003 (HARD, m10 + m13)**: xchg [mem], reg.
- **PA-R13-004 (HARD, m10 + m13)**: lock cmpxchg.
- **PA-R13-005 (HARD, m13)**: mfence.
- **PA-R13-006 (soft, m3)**: any missing CR4 write forms.
- **PA-R13-007 (soft, m11)**: fxsave/fxrstor (only needed if signals must preserve floating-point state; can defer if signal handlers are integer-only).

Predicted paideia-as version at R13 close: v0.13.0 (5-6 encoder additions).

## 3. Milestone index (revised)

| # | Slug | Issues | Description |
|---|---|---|---|
| m1 | r13-preflight-and-architecture | 2 | Full arch audit, syscall table freeze, paideia-as escalations filed |
| m2 | r13-mm-api-activation | 5 | phys_alloc bump + buddy allocator + PCID discipline + aspace map/create/unmap |
| m3 | r13-higher-half-kernel + KPTI | 5 | Kernel remapped to 0xFFFF_8000_0000_0000; KPTI page tables (kernel-only PGD copied per user); SMEP/SMAP/NX enable |
| m4 | r13-gdt-tss-ist + KIND_DEVICE real MMIO | 5 | GDT with user selectors; TSS + IST stacks; IDT rewire; KIND_DEVICE handler upgraded to use real aspace_map |
| m5 | r13-syscall-entry | 3 | MSR setup; syscall trampoline; syscall table (SYS_CAP_INVOKE + WRITE + READ + EXIT + minimal FORK/EXEC placeholders) |
| m6 | r13-full-cap-dispatch (10 kinds) | 7 | KIND_PROCESS + KIND_THREAD + KIND_PAGE_TABLE + KIND_IPC_PORT + KIND_TIMER + KIND_INTERRUPT + KIND_NOTIFICATION + KIND_REPLY handlers |
| m7 | r13-user-shell-binary-v1 | 3 | src/user/shell.pdx main loop + syscall shim + basic I/O |
| m8 | r13-kernel-user-transition | 3 | Embedded shell binary via .incbin; loader; kernel_main transition |
| m9 | r13-vfs + tmpfs + block abstraction | 5 | VFS layer; in-memory tmpfs; block-device stub; embedded read-only /bin filesystem |
| m10 | r13-fork-exec + multi-process | 5 | fork syscall (copy-on-write via KIND_PROCESS + KIND_PAGE_TABLE); exec syscall (ELF-lite loader); process table; wait syscall |
| m11 | r13-signals + job control | 4 | Signal delivery (SIGINT via Ctrl-C on UART, SIGKILL, SIGSEGV auto-delivery on page fault, SIGCHLD on child exit) |
| m12 | r13-shell-v2 (exec + line editing) | 3 | Shell reads /bin listings, `exec` builtin invokes user programs, arrow-key history (bonus) |
| m13 | r13-multicore (SIPI + per-CPU + IPI + TLB shootdown) | 6 | AP wake-up sequence; per-CPU GS with real segment override; cross-CPU IPI; TLB shootdown discipline |
| m14 | r13-user-process-preemption | 2 | Extend R11 preemption to ring-3 (timer IRQ delivers to user; kernel entry via IRQ; sched_pick_next selects across all TCBs) |
| m15 | r13-smoke-fingerprint-regression | 3 | boot_r13 + boot_r13_cap + boot_r13_multicore + boot_r13_signal sub-modes; pre-push extended |
| m16 | r13-closure | 2 | r13-closure.md + STATUS + retrospective + r14-kickoff.md |
| **Σ** | | **63** | |

## 4. Detailed milestone specs

### m1 — Preflight + Architecture

- **m1-001** Pre-flight audit (S) — Same as Rev 1: encoder verification, kind mapping (all 16 kinds), syscall table freeze including FORK/EXEC/WAIT/SIGACTION, MM invariants (bump + buddy), TSS/IST layout, higher-half kernel VA plan (0xFFFF_8000_0000_0000), KPTI PGD-copy discipline, embedded shell binary, VFS layer plan, multicore SIPI sequence.
- **m1-002** Architecture pins (S) — GDT layout, syscall MSR pins, ring-transition byte sequences, higher-half kernel linker script, KPTI page-table layout, per-CPU data struct layout, IPI vectors, signal frame layout, VFS inode structure, ELF-lite binary format.

### m2 — MM API Activation

- **m2-001** phys_alloc bump allocator (S) — Same as Rev 1.
- **m2-002** aspace_map + 4-level PT walker + INVLPG (M) — Same as Rev 1.
- **m2-003** aspace_create + kernel-upper-half copy (S) — Same as Rev 1.
- **m2-004** aspace_unmap + INVLPG (S) — Same as Rev 1.
- **m2-005** Real buddy allocator (M) — Replace bump with buddy over 1024-page pool. Order 0-10 support. Free-list heads in .bss. Coalesce on free. Retires the R14-deferred note.

### m3 — Higher-half kernel VA + KPTI + SMEP/SMAP/NX (NEW)

- **m3-001** Higher-half kernel linker script (M) — kernel .text at 0xFFFF_8000_0010_0000+. Update boot_stub.S GDT to map higher-half via PDPT[510]. Kernel_main_64 runs from higher-half VA after CR3 setup.
- **m3-002** KPTI PGD-copy discipline (M) — Per-user process: two PML4s. Kernel PML4 has full kernel + trampoline; user PML4 has user mappings + trampoline only. Kernel-entry trampoline switches CR3 on syscall entry, back on sysretq.
- **m3-003** SMEP enable (CR4.SMEP = bit 20) (S) — Prevents kernel from executing user code accidentally. wrcr4.
- **m3-004** SMAP enable (CR4.SMAP = bit 21) + stac/clac discipline (S) — Prevents kernel from reading user memory except via explicit stac/clac windows.
- **m3-005** NX enable (IA32_EFER.NXE = bit 11) + PTE.XD discipline (S) — Non-executable user data pages.

### m4 — GDT + TSS + IST + KIND_DEVICE MMIO

- **m4-001** Real GDT install (M) — Same as Rev 1 m3-001.
- **m4-002** TSS + RSP0 + ltr (S) — Same as Rev 1 m3-002. Blocked on PA-R13-001.
- **m4-003** IST stacks (DF/NMI/MC/PF) (S) — Same as Rev 1 m3-003.
- **m4-004** IDT rewire with IST fields (S) — Same as Rev 1 m3-004.
- **m4-005** KIND_DEVICE OP_MAP_MMIO real body (S, NEW) — Replace D7-004 vaddr synthesis stub with real aspace_map(current_aspace, requested_vaddr, phys_base, PTE_P|PTE_RW|PTE_PCD|PTE_PWT). Uses m2 machinery.

### m5 — Syscall Entry

- **m5-001** MSR setup (S) — LSTAR/STAR/FMASK/KERNEL_GS_BASE. Same as Rev 1 m4-001.
- **m5-002** Syscall entry trampoline (M) — Same as Rev 1 m4-002.
- **m5-003** Syscall table (S) — 13 native syscalls per preflight §C (frozen 2026-07-02): sys_exit_thread(0), sys_yield(1), sys_ipc_send(2), sys_ipc_recv(3), sys_cap_invoke(4), sys_cap_mint(5), sys_cap_query(6), sys_signal_register(7), sys_signal_return(8), sys_cpu_id(9), sys_sipi_target(10), sys_kpti_enable(11), sys_debug_puts(12). ABI: rdi/rsi/rdx/r10 args, rax result. POSIX shim (SYS_FORK/EXEC/WAIT/SIGACTION/etc.) is a userland-layer concern deferred to R13-m9+/R14; do NOT collide these IDs with native syscalls.

### m6 — Full Cap Dispatch (10 kinds)

- **m6-001** KIND_PROCESS handler (S) — Same as Rev 1 m5-001.
- **m6-002** KIND_THREAD handler (S) — Same as Rev 1 m5-002.
- **m6-003** KIND_PAGE_TABLE handler (S, NEW) — OP_MAP / OP_UNMAP delegating to aspace_map/unmap. Ties into m7 loader.
- **m6-004** KIND_IPC_PORT handler (S, NEW) — Point-to-point IPC endpoint (distinct from R12's KIND_IPC_ENDPOINT which is SPSC ring). Wraps a single message slot per port.
- **m6-005** KIND_TIMER handler (S, NEW) — OP_ARM (arm a timeout callback via LAPIC deadline); OP_CANCEL; OP_READ_TSC.
- **m6-006** KIND_INTERRUPT + KIND_NOTIFICATION handlers (S, NEW) — Wrap IRQ delivery to userspace as a bounded notification queue. Cap needed for user-mode drivers.
- **m6-007** KIND_REPLY handler (S, NEW) — One-shot RPC-style reply cap. Consumed on use. Foundational for m11 signals (SIGCHLD → wait syscall uses reply cap).

### m7 — User Shell Binary v1

- **m7-001** Shell main loop (S) — Same as Rev 1 m6-001.
- **m7-002** Syscall shim (S) — Same as Rev 1 m6-002. Extended for new syscalls (fork/exec/wait/mmap).
- **m7-003** I/O + builtins v1 (S) — Same as Rev 1 m6-003. Builtins: help/cap/exit. exec builtin lands in m12.

### m8 — Kernel-User Transition

- **m8-001** Embedded shell binary via .incbin (S) — Same as Rev 1 m7-001.
- **m8-002** Loader (M) — Same as Rev 1 m7-002. Extended: also loads init/shell process, sets up KPTI-compatible PML4 pair.
- **m8-003** kernel_main_64 transition (S) — Same as Rev 1 m7-003.

### m9 — VFS + tmpfs + block-device abstraction (NEW)

- **m9-001** VFS layer (M) — inode + dentry + super_block structs. Ops table: read/write/open/close/mkdir/readdir/lookup.
- **m9-002** tmpfs (S) — In-memory FS. Root at /. Allocates pages via phys_alloc. Directory tree in memory.
- **m9-003** Block-device abstraction stub (S) — bio structure + ops table; MVP stub returns "no device." Groundwork for R14+ persistent FS.
- **m9-004** Embedded /bin filesystem (M) — Bootstrap tmpfs populated at boot from an .incbin'd tarball. Contains at least /bin/hello (prints "hello world" then exits) + /bin/echo + /bin/cat + /bin/ls.
- **m9-005** File descriptor table per-process (S) — Small (16 slots) FD table in KIND_PROCESS descriptor.

### m10 — fork + exec + multi-process (NEW)

- **m10-001** fork() syscall + COW page tables (M) — Copy PML4 with all writable pages marked read-only + COW bit. Page fault handler duplicates on write. Uses KIND_PROCESS+KIND_PAGE_TABLE dispatch.
- **m10-002** exec() syscall + ELF-lite loader (M) — Read binary from VFS; parse minimal ELF header (or paideia-native flat format); create new aspace; jump to entry point.
- **m10-003** wait()/waitpid() syscall + process table (S) — Global process table (256 slots max in R13). Parent-child relationship. SIGCHLD delivery on child exit.
- **m10-004** Process cleanup (aspace + TCB destruction) (S) — On exit: unmap aspace pages, free TCB, wake waiter with SIGCHLD reply cap.
- **m10-005** Spinlock primitives for multi-process shared state (S) — Uses PA-R13-003 (xchg) or PA-R13-004 (lock cmpxchg). Ready for m13 multicore but usable single-CPU.

### m11 — Signals + Job Control (NEW)

- **m11-001** Signal delivery infrastructure (M) — Per-process signal mask + pending set + handlers table. Signal frame pushed onto user stack on delivery. sigreturn syscall restores user context.
- **m11-002** SIGINT via Ctrl-C on UART (S) — UART receives 0x03; kernel scans for it in the read syscall path; delivers SIGINT to foreground process.
- **m11-003** SIGSEGV auto-delivery on page fault (S) — Extend #PF handler: if fault is user-mode and address is not COW-recoverable, deliver SIGSEGV.
- **m11-004** SIGCHLD + SIGKILL basic delivery (S) — Ties into wait() from m10-003.

### m12 — Shell v2 (interactive + exec support)

- **m12-001** Line editing + history (S) — Backspace/BEL from Rev 1 m8-001. Simple 8-line history buffer.
- **m12-002** Builtin dispatch v2 (S) — Rev 1 m8-002 + `ls` builtin (reads VFS root) + `cd` (updates process CWD).
- **m12-003** exec builtin (S) — Parses `exec /bin/hello arg1 arg2`, calls fork+exec, wait's for child.

### m13 — Multicore (NEW)

- **m13-001** AP wake-up via SIPI (M) — INIT + startup IPI sequence. AP boot stub in 16-bit real mode → 32 protected → 64 long. Writes its own IA32_KERNEL_GS_BASE.
- **m13-002** Per-CPU GS data (M) — Real GS-relative reads (PA-R13-002 landed). GS points to per-CPU struct containing current_tcb, kernel_stack_top, apic_id.
- **m13-003** BSP + AP boot synchronization (S) — Global "APs online" counter incremented atomically via PA-R13-004 lock cmpxchg. BSP waits.
- **m13-004** Cross-CPU IPI real dispatch (S) — vec33 handle_ipi_default becomes real. IPI vector table.
- **m13-005** TLB shootdown IPI (M) — For aspace_unmap on multi-CPU: shootdown IPI to CPUs sharing that aspace. Requires PA-R13-005 mfence.
- **m13-006** Per-CPU runqueue (S) — Each AP has its own runqueue. Load balancing R14+; R13 does static pin.

### m14 — User Process Preemption (NEW)

- **m14-001** Extend R11 preemption to ring-3 (M) — When timer fires in user mode, IDT trampoline saves user CS/RSP/RFLAGS/RIP; kernel entry via IRQ path (not syscall); sched_pick_next may select a different user TCB; iretq to new user context.
- **m14-002** User TCB context save (S) — Full 15-GPR + FPU state save/restore on preemption. Uses PA-R13-007 fxsave if needed.

### m15 — Smoke + Fingerprint + Regression

- **m15-001** boot_r13 mode + fingerprint (S) — Shell prompt appears, help output, exit.
- **m15-002** boot_r13_cap sub-mode (S) — cap N M builtin round-trips.
- **m15-003** boot_r13_full sub-mode + 6-mode pre-push gate (S) — Full end-to-end: fork/exec/wait cycle exercises multi-process + VFS + signals. printf 'exec /bin/hello\nexit\n' asserts child output + wait completion. `boot_r13_multicore` if hardware / QEMU -smp 2 available; `boot_r13_signal` asserts Ctrl-C delivery.

### m16 — Closure

- **m16-001** R13 closure + STATUS (S) — r13-closure.md follows R12 template.
- **m16-002** Retrospective + R14 kickoff (S) — R14 candidates: persistent FS + block devices; network stack; ACPI; NUMA; hot-plug; PCID full activation; curried-call plumbing.

## 5. Critical path

```
m1 → m2 → m3 → m4 (PA-R13-001) → m5 → m6 →
  { m7 → m8 } (parallel with m6)
→ m9 (VFS) → m10 (fork+exec) (PA-R13-003/004) → m11 (signals) → m12 (shell v2)
→ m13 (multicore) (PA-R13-002/005) → m14 (user preemption)
→ m15 → m16
```

Length: 16 milestones sequential. Parallelizable bands: ~11.

## 6. Cross-repo escalations (5-7 HARD blockers)

Filed at m1 close:

- **PA-R13-001**: ltr r16 encoder.
- **PA-R13-002**: GS-relative memory operand (65 prefix; adds segment override).
- **PA-R13-003**: xchg [mem], reg.
- **PA-R13-004**: lock cmpxchg.
- **PA-R13-005**: mfence.
- **PA-R13-006** (soft): CR4 write variants for SMEP/SMAP/PCID bits (verify current encoder).
- **PA-R13-007** (optional): fxsave / fxrstor (only if signals must preserve FP state; can defer if signal handlers are integer-only).

Predicted paideia-as version: v0.13.0 at R13 close.

## 7. Risk register (top 15)

| # | Risk | Prob | Impact | Mitigation |
|---|---|---|---|---|
| R1 | PA-R13-001 slips | med | high | File first in m1; hand-encoded .byte fallback |
| R2 | First iretq triple-faults | high | high | #DF with IST1 + trace handler |
| R3 | Higher-half + KPTI page-table complexity | high | high | m3 unit-testable via bochs single-step |
| R4 | fork() COW hangs or corrupts | high | high | Extensive m10 unit tests; QEMU register-dump verification |
| R5 | ELF loader edge cases | med | med | Use minimal ELF-lite format authored in-house; documented byte layout |
| R6 | Multicore synchronization bugs | high | high | m13 lands after m10 spinlock primitives mature |
| R7 | TLB shootdown races | high | high | m13 preflight: enumerate races; formal ordering per Intel SDM 8.3.2 |
| R8 | Signal delivery races (nested signals) | med | med | Block signals during handler unless SA_NODEFER |
| R9 | User process preemption context corruption | high | high | m14 byte-verify full 15-GPR + segment save/restore |
| R10 | Shell PT collides with kernel higher-half after m3 | low | high | Post-m3 shell VA at 0x0000_4000_0000 (lower-half) |
| R11 | VFS + tmpfs data corruption under fork | med | high | Per-process FD tables independent; VFS ops locked |
| R12 | Buddy allocator fragmentation exhausts pool | med | med | 1024 pages sufficient for R13 shell + 4 forked processes |
| R13 | QEMU -smp 2 semantics differ from real hw | med | med | m13 verify against bochs + qemu documentation |
| R14 | .incbin embedded /bin tarball incorrect format | med | med | Simple magic-header + tar-like layout, author in-house |
| R15 | Ctrl-C signal delivery misses when kernel busy | med | med | Ctrl-C sets pending bit; deliver on next syscall return or timer preempt |

## 8. Cycle estimate

Substantially more ambitious than R12:
- m1-m2: 6 cycles (preflight + MM)
- m3-m5: 12 cycles (higher-half + ring-3 + syscalls; higher-half is the risky item)
- m6: 5 cycles (10 cap kinds)
- m7-m8: 5 cycles (shell v1 + loader)
- m9: 6 cycles (VFS + tmpfs + /bin)
- m10: 8 cycles (fork + exec + wait)
- m11: 4 cycles (signals)
- m12: 3 cycles (shell v2)
- m13: 8 cycles (multicore — highest debug risk)
- m14: 3 cycles (user preemption)
- m15-m16: 3 cycles

**Total: 63 cycles.** Wallclock: 30-45 working days with heavy parallelization (m2/m3/m4 can be parallelized; m9/m10/m11 can partially overlap; m13 must sequential-follow m10).

## 9. Recommended sequencing

- **Days 1-3**: m1 (preflight + arch pins). File PA-R13-001..007 in paideia-as.
- **Days 4-8**: m2 (MM API + buddy) — parallel with paideia-as maintainer working on PA-R13-001.
- **Days 9-14**: m3 (higher-half + KPTI + SMEP/SMAP/NX) — biggest wildcard for schedule.
- **Days 15-19**: m4 (GDT/TSS/IST/KIND_DEVICE MMIO) — blocked on PA-R13-001.
- **Days 20-23**: m5 (syscall entry).
- **Days 24-28**: m6 (10 cap kinds) + m7 (shell v1) in parallel.
- **Days 29-32**: m8 (transition + loader). First observable ring-3 execution.
- **Days 33-38**: m9 (VFS + tmpfs).
- **Days 39-46**: m10 (fork/exec/wait). Highest debug time.
- **Days 47-50**: m11 (signals).
- **Days 51-53**: m12 (shell v2 with exec builtin).
- **Days 54-61**: m13 (multicore). Second-highest debug time.
- **Days 62-64**: m14 (user preemption).
- **Days 65-67**: m15 (smoke + regression).
- **Days 68-70**: m16 (closure).

Assumes 5 productive hours/day, single primary engineer + paideia-as maintenance.

## 10. Round acceptance gate

R13 CLOSED when all hold:

1. `tools/run-smoke.sh boot_r13` passes: shell prompt + help + exit.
2. `boot_r13_cap` passes: SYS_CAP_INVOKE round-trip.
3. `boot_r13_exec` passes: `exec /bin/hello` fork+exec+wait cycle observable.
4. `boot_r13_signal` passes: Ctrl-C delivers SIGINT observable.
5. `boot_r13_multicore` passes (if QEMU -smp available): 2 CPUs both execute tasks.
6. `.git/hooks/pre-push` gates on 6 modes.
7. R12 modes (`boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`, `boot_r12_denial`) still pass.
8. `design/milestones/r13-closure.md` written.
9. `tools/paideia-as` submodule bumped to a tagged v0.13.0 containing PA-R13-001..005 (007 if needed).
10. `design/milestones/r14-kickoff.md` written naming R14 candidates (persistent FS, network, ACPI, NUMA, hot-plug, curried calls).
11. Tag `r13-closed` on merge commit.

**Observable payoff:** a human at a terminal:
- Types `help` — sees syscall list.
- Types `ls /bin` — sees list of available programs.
- Types `exec /bin/hello` — sees "hello world" output from a spawned process.
- Types Ctrl-C during a long-running command — sees it interrupted.
- Types `exit` — shell halts cleanly.

This is a complete, if minimal, interactive operating system.

**End of revised round plan.**
