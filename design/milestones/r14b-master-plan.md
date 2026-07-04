# R14B Master Plan — Substrate to Interactive Shell

**Status:** DRAFT — awaiting user + softarch review
**Author:** osarch
**Date:** 2026-07-04
**Depends on:** `design/milestones/take-stock-2026-07-03.md`, `design/milestones/r14-preflight.md`, `design/milestones/r14-kickoff.md`, `design/round-retrospectives/r13-shell-foundation.md`
**HEAD at authoring:** `a049b87` (post r14-m2-003 huge-page detection + 71d0976 TSS `ltr`)

---

## 0. Preamble

R14B is the strategic covenant taking PaideiaOS from the current substrate — 4-mode boot (`boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`, `boot_r12_denial`), 10 real capability handlers, SYSCALL/SYSRET fast path unreached at runtime, TSS + `ltr` landed, KIND_PROCESS real, `aspace_map` huge-page-safe — to a **user typing at a serial console into an interactive shell running from ring 3, backed by a real VFS on top of a real KPTI'd higher-half kernel with cap-mediated file access.**

This document commits paideia-os to a MECE 24-milestone map across four phases (R14 tail + R15 + R16 + R17). Every milestone lands a functional artifact behind a distinct smoke-mode fingerprint. Every deferral is justified against the shell-demo north star. Every substrate gap is either resolved in-round, escalated to paideia-as, or explicitly scoped to a later phase.

The plan is *ambitious by design*. R13 taught (retrospective (b), (e)) that under-scoping preflight is the primary source of mid-round backtracking. R14B chooses the opposite failure mode: an over-explicit plan with occasional slack, rather than an under-explicit plan with recurring surprises.

This plan is not a schedule. It is a topological ordering. The autonomous-tempo directive (`feedback_paideia_os_tempo.md`) applies unchanged: continuous execution across issues and milestones, backtracking per gap, cross-repo escalation per `feedback_cross_repo_escalation.md`, submodule bump per `feedback_paideia_as_version_discipline.md`. R14B does not pause between milestones.

---

## 1. North Star: Interactive Shell Session Over Serial

### 1.1 The demo

A serial-terminal user, connected to COM1 of the QEMU instance running `kernel.elf`, observes the following exact transcript. Bracketed text (`[user types: ...]`) is not on screen — it is what the user types at the terminal; the rest is what paideia-os emits or echoes.

```
PaideiaOS R14B booting...
[boot output identical to boot_r12 mode through TSS OK]
TSS OK
KPTI OK
RING3 ENTER
INIT OK
paideia-shell v0.1 (build r14b)
Type 'help' for commands.
$ [user types: help][CR]
help
Available commands:
  help          — this message
  echo <args>   — write arguments to stdout
  exit          — terminate this shell
$ [user types: echo hello][CR]
echo hello
hello
$ [user types: exit][CR]
exit
paideia-shell: bye
INIT REAPED
SHUTDOWN
```

The transcript is what the `boot_r17_shell` smoke mode (see §7) will feed and verify. It is deliberately minimal — three commands (`help`, `echo`, `exit`) — because the invariant it commits paideia-os to is not "a full shell" but rather **every layer between ring 3 and COM1 working end-to-end.** A three-command demo exercises: ring-3 execution, SYSCALL/SYSRET, UART RX interrupt or poll, line discipline (echo + CR→LF + backspace-if-tested), VFS + fd table + `sys_read`/`sys_write`, argv parsing in user, `sys_exit_thread`, and process reaping. Adding more commands multiplies the demo without adding new exercised code paths at this scope.

### 1.2 What the demo commits paideia-os to (observable state)

By the time this transcript renders, the following invariants are ratified as *demonstrated*, not designed:

- **Kernel executes from higher-half canonical VA** (0xFFFF_8000_0010_0000 range) with KPTI CR3 switch active on every syscall entry/exit.
- **A user process runs in ring 3** with its own address space, distinct CR3, and only user-accessible pages mapped in its user-CR3.
- **A SYSCALL/SYSRET round-trip carries a syscall from ring 3 to a real kernel handler and back**, restoring user context and continuing user execution.
- **The kernel intercepts a UART RX interrupt** (or serves a polled read), delivers a byte to a blocked user read, and returns to user-mode.
- **A file descriptor abstraction** (whether POSIX-`fd` or KIND_FILE cap-slot per §C amendment resolution — see §11.1) mediates `sys_read`/`sys_write` between the shell and `/dev/console`.
- **A tmpfs + VFS layer** supports `/dev/console` mount and (optionally) a `/help.txt`-backed `help` implementation.
- **A user process terminates** via `sys_exit_thread`, the kernel reaps its process slot, resets `_next_pid` counter or leaves it monotonic, and initiates shutdown (isa-debug-exit 0x10 for smoke, or ACPI shutdown for real hardware).
- **The 5-mode + N boot fingerprint discipline** survives byte-identically through every commit in R14B. Existing modes never change; new modes are additive.

### 1.3 What the demo does NOT commit paideia-os to (deferred)

Justified deferrals against the north star:

- **Multicore**. The shell demo runs on BSP; APs remain unbooted. Path A (multicore) is R14B-δ+1 (post-shell). Justification: multicore does not appear in the demo transcript; adding it multiplies risk without changing the observable. It is R15-phase work under the current numbering.
- **Formal deadlock-freedom proof-obligation on running code** (Pillar 4). The demo uses SPSC + single-user-thread + a single console; no deadlock scenario is exercised. Design work continues in `design/ipc/` throughout R14B; the proof obligation ties to running code once cross-process IPC is demoed (post-R17).
- **Post-quantum crypto** (Pillar 6). No PQ ceremony is in the demo transcript. R18+ per take-stock §2.6.
- **Semantic terminal** (Pillar 8). `paideia-shell v0.1` is a POSIX-flavored command shell. The semantic terminal (typed records, Datalog queries, PDS format) is R18+ per take-stock §2.7.
- **CET, MPK, measured boot, TPM 2.0**. All are Pillar 6/10 obligations that live above ring-3 substrate. R17-post.
- **KIND_PAGE_TABLE, KIND_INTERRUPT** real handlers. Both are structural stubs today; the demo does not require either. R17-post.
- **Full ACPI/UEFI bring-up**. PVH direct-boot suffices for the demo. Full ACPI RSDP/MADT + UEFI ExitBootServices is R18+.
- **NUMA, buddy allocator, magazine caches**. Bump allocator suffices for R14B. Real MM stack is R17-post.

**Pillar-alignment audit for the demo:** Pillars 1, 3, 5, 10 are directly demonstrated. Pillar 2 (multicore) is explicitly deferred with note. Pillar 4 (deadlock-free IPC) is not exercised. Pillars 6 (PQ), 7 (networking), 8 (semantic terminal), 9 (hot-plug drivers), 11 (research discipline) are cross-cutting and remain aspirational at R14B close. Pillar 5 (no backwards compatibility) is honored in that no POSIX shim exists — `paideia-shell` is minimal, argv is passed via SysV ABI at `_start` (a de-facto ELF convention, not a POSIX obligation), and file descriptors are integers (or cap-slots — §C decision) with no `fcntl`, no `ioctl`, no `select`, no signals delivery in-scope for the demo.

---

## 2. Subsystem Inventory (12 subsystems)

Each subsystem lists (a) responsibility, (b) invariants, (c) primary interfaces, (d) minimum-viable slice for the demo (MVS), (e) what is deferred to R17-post.

### 2.1 Boot

**Responsibility.** Bring the CPU from PVH entry (32-bit protected mode, paging off) to `kernel_main` running in 64-bit long mode from the higher-half canonical VA, with a real GDT + IDT + TSS + IST + CR4 (SMEP/SMAP/PCID) + IA32_EFER (LME + NXE + SCE) + SYSCALL MSRs + KPTI CR3 base installed.

**Invariants.**
- PVH handoff at `_pvh_entry` (low VA 0x100000) is byte-identical to R13.
- After far-jmp transition, `%cs:%rip` runs from 0xFFFF_8000_0010_XXXX exclusively. Low-VA identity map is retained only for the PML4[0] alias needed by PDPT[0..3] boot huge pages until aspace_activate ratifies user aspaces.
- Boot huge pages (PML4[0] → PDPT[0..3] 1 GiB entries) are never clobbered by walker descent (guarded by `aspace_map` MAP_HUGE detection, r14-m2-003).

**Primary interfaces.**
- `boot_stub.S` → `_start` (kernel entry) with linear identity for early setup, then `ljmp *high_kernel_entry` to canonical high VA.
- `kernel_main.pdx` — orchestrator; calls into each subsystem's `_init` in dependency order.

**MVS for demo.** Existing PVH → long-mode transition + far-jmp to higher-half (M1–M2) + TSS `ltr` (M6) + full GDT/IDT/TSS/IST wire-up (already landed at 71d0976 for TSS).

**Deferred.** UEFI path, measured boot, TPM PCR extend, ACPI RSDP parse. All R17-post.

### 2.2 Memory Management

**Responsibility.** Physical-page allocation (bump today; buddy/magazine post-R14B), 4-level page-table walk with INVLPG discipline (Intel SDM Vol 3A §4.5), address-space creation + activation, KPTI dual-CR3 model, huge-page safety.

**Invariants.**
- `aspace_map` MUST return `MAP_HUGE = 0xFFFFFFFD` sentinel and refuse to descend if PS=1 is encountered at PDPT or PD; walker never clobbers boot huge pages. (Landed r14-m2-003.)
- Kernel PML4 owns entries [256..511]; user PML4 owns entries [0..255]. KPTI's user-CR3 mirrors kernel's ONLY the SYSCALL trampoline page + the KPTI stack + the IST stacks (Meltdown mitigation per Linux post-2018 model — TODO: verify citation to `arch/x86/mm/pti.c` or Gruss et al. USENIX Security 2017).
- INVLPG issued on every `aspace_unmap` or PTE downgrade; per-CPU shootdown mailbox exists but is single-CPU at R14B (multi-CPU shootdown is R15-post).

**Primary interfaces.**
- `phys_alloc.pdx :: alloc_frame() -> phys` (bump).
- `aspace_map.pdx :: map(pml4, vaddr, phys, attrs) -> status`.
- `aspace_create.pdx :: create() -> pml4_phys`.
- NEW at R14B-α: `aspace_activate(pml4)` — CR3 load with PCID + no-flush; wired into the syscall trampoline (KPTI) and into first-thread-start.
- NEW at R14B-α: `kpti_user_pgd_create(kernel_pml4) -> user_pml4` — real body of the stub currently returning `ASPACE_CREATE_NOT_YET`.

**MVS for demo.** Bump allocator + aspace_map + aspace_create + aspace_activate + kpti_user_pgd_create. All are R14B-α (m1–m5) work. No buddy, no magazine, no NUMA.

**Deferred.** Buddy allocator real, magazine caches, NUMA-local free lists, PCID rotation, huge-page splitting, 5-level paging, page-fault-driven user pager. All R17-post.

### 2.3 Interrupts / Traps

**Responsibility.** IDT install + real handlers for exceptions (0, 3, 6, 8, 13, 14) + LAPIC timer + LAPIC EOI + PIC mask-all + IST-safe stacks for DF/NMI/MC/PF + UART RX vector (new at R14B-δ).

**Invariants.**
- IDT is 256 entries, packed real, `lidt` executed (r13-m4-001).
- IST fields wired for vectors 2 (NMI), 8 (DF), 14 (PF), 18 (MC). Ring-3 exception delivery uses TSS.RSP0 (landed at 71d0976 — r13-m4-002 + audit fix).
- Ring-3 page fault delivers `#PF` to the kernel handler (`pf_handler.pdx`) via TSS.IST slot or RSP0, prints error code + faulting-address (CR2), and kills the offending user process. It never triple-faults.
- LAPIC timer never interrupts inside the KPTI trampoline window (mitigated by trampoline running with IF clear or via a critical-section guard — Gruss et al. Meltdown mitigation, verify citation).

**Primary interfaces.**
- `idt.pdx :: install_vector(vec, handler, ist_index)`.
- `exceptions.pdx` handlers per vector.
- NEW at R14B-δ: `uart_rx_isr` — vector 0x21 (COM1 IRQ4 → IOAPIC → LAPIC vector 33 in the flat model, or vector 0x24 via legacy PIC route — decision at R14B-δ preflight).

**MVS for demo.** BSP exception path (real). LAPIC timer (real). UART RX ISR real (M16). No IOAPIC bring-up; use LAPIC LVT direct route OR polled RX with periodic timer poll if IOAPIC design slips.

**Deferred.** IOAPIC full GSI routing, MSI/MSI-X, x2APIC, cross-CPU IPI. R15-post.

### 2.4 Syscall Entry

**Responsibility.** SYSCALL trampoline (`syscall_entry` in `entry.pdx`) — save user RSP, load kernel RSP, KPTI CR3 switch, `swapgs` (deferred single-CPU per r13-m1-002 justification), push rcx/r11/rax, shuffle SYSCALL→SysV ABI, dispatch, sysret with reverse. Table dispatch via linear cmp/je chain (13 entries → 17 after §C amendment).

**Invariants.**
- The trampoline entry PC + KPTI-mapped page containing it MUST be in the user-CR3's mapping. Otherwise SYSCALL from ring 3 immediately #PFs before it can KPTI-switch. Enforced by dedicated `.text.trampoline` section with linker guarantee.
- No user memory is touched before KPTI CR3 switch completes; no kernel memory is touched before switch. The trampoline is a straight-line assembly sequence with no data references.
- Every syscall handler returns via `syscall_return` which reverses KPTI CR3, reverses swapgs (when it lands), restores rcx/r11, and executes `sysret`.

**Primary interfaces.**
- `entry.pdx :: syscall_entry` — assembly trampoline.
- `dispatch.pdx :: syscall_dispatch(rax, rdi, rsi, rdx, r10, r8) -> ret` — C-ABI-flavored dispatcher.
- `table.pdx :: SYS_NR` — frozen 13 today; 17 after §C amendment resolution (M8).

**MVS for demo.** Full end-to-end trampoline with KPTI (M3–M4). Handlers: `sys_exit_thread` (M10), `sys_yield` (already), `sys_cap_invoke` (already), `sys_debug_puts` (already), `sys_read` (M15), `sys_write` (M18), `sys_open` (M19), `sys_close` (M19). Everything else remains ENOSYS.

**Deferred.** `sys_stat`, `sys_ipc_send`/`recv` (cap-invoke covers them), `sys_signal_register`/`return`, `sys_cpu_id`, `sys_sipi_target`, `sys_kpti_enable`. R15+.

### 2.5 Capabilities

**Responsibility.** Cap-slot table (per-process), cap invocation via SYSCALL 4, per-kind dispatch to real handlers, rights lattice enforcement, denial witness.

**Invariants.**
- 10 real kinds today (see take-stock §1.5). No kind is removed in R14B.
- Cap dispatch remains a linear cmp/je chain until handler count exceeds ~14 (R12 boundary #7, restated in R13 closure). Handler-table migration is R17-post.
- `boot_r12_denial` mode continues to witness `CAP DENIED` byte-identically through R14B.

**Primary interfaces.**
- `cap/dispatch.pdx :: cap_invoke_dispatch(slot, op_code, op_arg) -> ret`.
- Per-kind `kind_*.pdx` handlers.

**MVS for demo.** Existing surface + KIND_FILE (Option 2 of §C) OR unchanged (Option 1 uses fd table, not caps). Decision at M8.

**Deferred.** Sealed caps, generation-based revocation validation in dispatch, kind-specific rights lattice (high 32 bits), audit log persistence. R17-post.

### 2.6 Scheduler

**Responsibility.** TCB management (184-byte layout), runqueue (16-level priority bitmap), pick-next (BSR), preemption via LAPIC timer + budget, cooperative yield, sleep queues (new at R14B-δ for blocking `sys_read`).

**Invariants.**
- TCB layout is frozen at 184 bytes. Byte offsets pinned; no reorderings without a design note.
- `boot_r10` and `boot_r11` continue to witness cooperative + preemptive alternation byte-identically.
- A blocked-on-IO thread is *not* on the runqueue and is *not* selected by pick-next; it is on a per-device sleep queue.

**Primary interfaces.**
- `sched/switch.pdx :: sched_switch_to(next_tcb)`.
- NEW at R14B-δ: `sched/block_on.pdx :: block_on(wait_queue)` — pushes current TCB to wait queue, calls `sched_yield`.
- NEW at R14B-δ: `sched/wake_one.pdx :: wake_one(wait_queue)` — pops one TCB, marks RUNNABLE, adds to runqueue.

**MVS for demo.** Existing single-CPU cooperative + preemptive + budget + block/wake on a single UART sleep queue.

**Deferred.** CFS/EEVDF-style fair scheduling, real-time class, multi-CPU per-CPU runqueue, work-stealing. R15-post.

### 2.7 IPC

**Responsibility.** SPSC ring (KIND_IPC_ENDPOINT), single-slot port (KIND_IPC_PORT), one-shot reply (KIND_REPLY), counting notification (KIND_NOTIFICATION).

**Invariants.**
- All four cap-mediated primitives continue to work byte-identically.
- `boot_r12` continues to witness `IPC OK`.

**Primary interfaces.**
- Existing `kind_ipc.pdx`, `kind_ipc_port.pdx`, `kind_reply.pdx`, `kind_notification.pdx`.

**MVS for demo.** No IPC change is strictly required for the shell demo. However, if §C amendment resolves to Option 2 (cap-based file slots), a new KIND_FILE handler joins the family (M8 side-work; landed at M19).

**Deferred.** Formal deadlock-freedom proof-obligation binding, MPSC channel (blocked on `lock cmpxchg`), NUMA-local channel allocation. R15-post.

### 2.8 Process Management

**Responsibility.** Process slot pool (64 × 32B), PID allocation, `KIND_PROCESS OP_CREATE/OP_GET_ASPACE_ROOT` real handler (landed r14-m2-002), fork (NEW at R17-post, out of R14B scope), exec (NEW at R14B-β, kernel-side ELF-lite loader), wait, exit + reap.

**Invariants.**
- `_next_pid` monotonically increases; PID reuse deferred to R17-post.
- KIND_PROCESS handler continues to return fresh pid via OP_CREATE, aspace_root via OP_GET_ASPACE_ROOT.
- Reaping a process frees its slot, its aspace (via `aspace_destroy` — NEW at R14B-ζ), its cap-table page, and any open fd table entries.

**Primary interfaces.**
- `cap/kind_process.pdx`.
- NEW at R14B-β: `process/exec.pdx :: exec(pid, elf_lite_ptr, argc, argv_ptr) -> status` — loads ELF-lite into user aspace, sets user _start, argc/argv on user stack.
- NEW at R14B-γ: `process/exit.pdx :: exit_current(status)` — marks TCB EXITED, kicks reaper.
- NEW at R14B-ζ: `process/reap.pdx :: reap(pid) -> status`.

**MVS for demo.** Kernel spawns *init* (the shell binary) at boot: aspace_create → exec (shell binary) → aspace_activate → SYSRET into user _start. On shell `exit`, reaper cleans up and issues shutdown. **Single process at a time**. No fork, no multiple concurrent user processes.

**Deferred.** fork (COW), wait on child, multiple concurrent user processes, SIGCHLD. R17-post.

### 2.9 Filesystem + VFS

**Responsibility.** File descriptor table (kernel-side, per-process, up to 64 fds), tmpfs (in-memory node + data pool), VFS layer (mount table + lookup dispatch), `/dev/console` bind to UART, `sys_open`/`close`/`read`/`write` implementation.

**Invariants.**
- fd 0 = stdin, fd 1 = stdout, fd 2 = stderr, all bound to `/dev/console` at process init.
- `/dev/console` reads block on UART RX sleep queue; writes flush to `uart_putc`.
- tmpfs is *ephemeral* (no persistence). File data pool sized per compile-time constant (initial: 16 KiB).

**Primary interfaces.**
- NEW at R14B-ε: `fs/fd_table.pdx`, `fs/tmpfs.pdx`, `fs/vfs.pdx`, `fs/console.pdx`.

**MVS for demo.** fd table + tmpfs + VFS + /dev/console. Minimal: mount tmpfs at `/`, bind `/dev/console` to UART. Optionally `/help.txt` populated at boot with the help message so `help` reads it via `sys_read` (elegant but optional).

**Deferred.** paideia-tar loader (bundled initrd of user binaries), block-device driver, persistent FS, permissions, capability-based file semantics if Option 1 chosen for §C. R17-post.

### 2.10 UART + TTY

**Responsibility.** UART TX (existing, `uart_putc`, `uart_puts`), UART RX (NEW at R14B-δ, ISR-driven or polled), kernel ring buffer for RX bytes, line discipline (echo, CR→LF, backspace handling, buffered read until newline), sleep-queue integration.

**Invariants.**
- TX is byte-perfect (COM1 at 115200 8N1 today, no change).
- RX ring buffer is bounded (initial 256 bytes); overrun drops oldest byte and posts an audit tag `UART OVERRUN` on COM1.
- Line discipline is single-mode (canonical only — echo + line-buffered). No raw mode at R14B.

**Primary interfaces.**
- Existing `uart_putc`, `uart_puts`.
- NEW at R14B-δ: `uart/rx_isr.pdx`, `uart/tty.pdx :: tty_readline(buf, max) -> n`.

**MVS for demo.** Polled RX + polling-based tty_readline at M15 (safest, lowest risk). Interrupt-driven RX at M16 (upgrade path). Line discipline: echo the char on input, LF on CR, backspace erases last char (all in-kernel).

**Deferred.** Raw mode, multi-line editing, history, tab completion, SIGINT delivery on Ctrl-C. R17-post.

### 2.11 User-space Toolchain + Shell

**Responsibility.** `tools/build-user.sh` (globs `src/user/*.pdx`, compiles under user linker script, `objcopy -O binary`, produces `shell.bin`), user linker script (`src/user/link-user.ld`, base VA at ring-3 canonical low), embedding via `.incbin` in `kernel.elf`, shell source (main loop: readline → parse → dispatch → builtin exec).

**Invariants.**
- User binary is position-fixed (no PIC at R14B). Base VA pinned per §11.2 decision (recommended: 0x0000_0000_0040_0000 — 4 MiB, well above null-page + comfortably below kernel's low-VA identity map that is retired post-M2).
- Shell binary size < 16 KiB at R14B close. Enforced by linker script post-M22.

**Primary interfaces.**
- NEW at R14B-β: `tools/build-user.sh`, `src/user/link-user.ld`.
- NEW at R14B-ζ: `src/user/shell.pdx` (real body, not the R13 straight-line demo).

**MVS for demo.** All of the above.

**Deferred.** PIC user binaries, dynamic linking, multiple user binaries (only shell exists at R14B close), user-space libc-equivalent. R17-post.

### 2.12 Cross-repo (paideia-as)

**Responsibility.** paideia-as encoders that R14B requires. Bundling into releases (v0.12.0 already conjectured; v0.13.0 for R14B-δ interrupt work; v0.14.0 for R14B-γ/ε FP + atomic hardening).

**Invariants.**
- Submodule pin advances only at phase boundaries per `feedback_paideia_as_version_discipline.md`.
- Every gap surfaced during R14B execution is filed as `PA-R14B-NNN` in paideia-as within 24 hours of discovery. Fix + push + submodule bump per `feedback_cross_repo_escalation.md`.

**MVS for demo.** See §8 (encoder gap forecast).

**Deferred.** N/A — encoder work is per-need, not aspirational.

---

## 3. Dependency Graph

### 3.1 Subsystem adjacency (X blocks Y means Y's MVS cannot land without X's MVS)

| Blocks ↓ / Blocked-by → | Boot | MM | Int | Sysc | Cap | Sch | IPC | Proc | FS | UART | User | PA |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Boot**            |   |   |   |   |   |   |   |   |   |   |   | ✓ |
| **MM**              | ✓ |   |   |   |   |   |   |   |   |   |   | ✓ |
| **Interrupts**      | ✓ | ✓ |   |   |   |   |   |   |   |   |   |   |
| **Syscall**         | ✓ | ✓ | ✓ |   |   |   |   |   |   |   |   | ✓ |
| **Capabilities**    | ✓ | ✓ |   | ✓ |   |   |   |   |   |   |   |   |
| **Scheduler**       | ✓ | ✓ | ✓ |   |   |   |   |   |   |   |   |   |
| **IPC**             | ✓ | ✓ |   |   | ✓ | ✓ |   |   |   |   |   |   |
| **Process**         | ✓ | ✓ |   | ✓ | ✓ | ✓ |   |   |   |   |   | ✓ |
| **Filesystem**      | ✓ | ✓ |   | ✓ |   |   |   | ✓ |   | ✓ |   |   |
| **UART+TTY**        | ✓ |   | ✓ |   |   | ✓ |   |   |   |   |   |   |
| **Userspace/Shell** | ✓ | ✓ |   | ✓ |   |   |   | ✓ | ✓ | ✓ |   | ✓ |
| **paideia-as**      |   |   |   |   |   |   |   |   |   |   |   |   |

Column-major reading: `Boot` blocks nothing directly (it is the foundation). paideia-as blocks Boot (32-bit encoder for boot stub — landed at v0.11.0), MM (SUB imm), Syscall (mov_gs_seg, KPTI), Process (fxsave for FP context save/restore — deferred to R17-post), User (register-indirect calls for cap dispatch — deferred to R17-post).

### 3.2 Critical path (from now → demo)

The shortest chain of subsystem-milestone dependencies:

```
Boot (M1: link.ld) → Boot (M2: far-jmp higher-half)
  → MM (M3: KPTI CR3 switch in trampoline)
    → MM (M4: kpti_user_pgd_create real)
      → Boot/Syscall smoke (M5: boot_r14b_kpti closure)
        → PA + Process (M6: v0.12.0 + TSS `ltr` = LANDED but need to close #424 confirm)
          → User (M7: tools/build-user.sh + linker + .incbin)
            → Governance (M8: §C amendment resolution)
              → Process (M9: ELF-lite loader kernel-side)
                → Process/Sysc (M10: first ring-3 SYSRET into user _start)
                  → Sysc (M11: first ring-3 sys_debug_puts)
                    → Int/Sch (M14: ring-3 timer preemption)
                      → UART (M15: sys_read polled)
                        → UART (M16: RX ISR + ring buffer)
                          → UART (M17: TTY line discipline)
                            → Sysc (M18: sys_write finalize)
                              → FS (M19: fd table + sys_open/close)
                                → FS (M20: tmpfs)
                                  → FS (M21: VFS + /dev/console mount)
                                    → User (M22: shell _start + main loop)
                                      → User (M23: readline via sys_read)
                                        → User (M24: parser + builtins)
                                          → Process (M25: exit + reap + shutdown)
                                            → Demo (M26 not milestone: smoke boot_r17_shell)
```

The critical path is **24 milestones**, with M12 (user-mode #PF delivery) and M13 (page fault handler killing user process) as parallel deliverables to M11/M14. M26 is the smoke-fixture closure milestone; some plans would number this M25 or absorb it into M24, but §7 explains why it is distinct.

Numbered items landing on the critical path: M1, M2, M3, M4, M5, M6, M7, M8, M9, M10, M11, M14, M15, M16, M17, M18, M19, M20, M21, M22, M23, M24, M25, M26. That is all of them. **The whole plan is critical-path.** There is no non-critical-path work in R14B. This is by design: every milestone earns its slot by advancing the demo. Design work in `design/` documents that does not tie to a milestone (per §12) does not count against R14B milestone size.

---

## 4. Phase and Milestone Map

Four phases (R14B-α, β, γ, ε; there is no R14B-δ in the phase letters — the letters index PHASES not milestones, and I use α β γ ε to match the take-stock report style; if the user prefers I can re-letter δ). Each milestone shows: `name → goal → deliverable → exit fingerprint → prereqs → blocked-by → issue count`. The **issue count** is the softarch-tactical-issue estimate; softarch will consolidate this against the take-stock into a single tracker.

### Phase R14B-α — Higher-half kernel VMA + KPTI (Path B tail) — 5 milestones

#### M1 · `r14b-m1-linker-vma`
- **Goal.** Amend `link.ld` to relocate kernel `.text`/`.rodata`/`.data`/`.bss` to canonical higher-half VA (0xFFFF_8000_0010_0000), while keeping LMA at 0x100000 so PVH loads the image where boot_stub expects it.
- **Deliverable.** `link.ld` amended; `readelf -S build/kernel.elf` shows `.text` at VA 0xFFFF_8000_0010_XXXX. Boot fingerprint `boot_r12` continues to pass byte-identically because the kernel still executes from low VA identity map at this point (nothing has jumped yet).
- **Exit fingerprint.** All 5 modes byte-identical + `readelf -S` audit tag in commit.
- **Prereqs.** r14-preflight §C amendment (this milestone lands it).
- **Blocked-by.** None. paideia-as v0.11.0+28 sufficient.
- **Issue count.** 2 (link.ld amendment, kernel-source references to deleted `_kernel_higher_half_base` symbol).

#### M2 · `r14b-m2-boot-stub-far-jmp`
- **Goal.** In `boot_stub.S`, after long-mode transition and PML4 install, execute `ljmp *high_kernel_entry` to shift `%cs:%rip` from low identity map to canonical higher-half. Retire the low-VA identity map for `.text` on the far side (keep PML4[0]→PDPT[0..3] boot huge pages for boot-stub-still-live and for the trampoline page).
- **Deliverable.** `_start` runs from higher-half. QEMU trace confirms `%rip` in 0xFFFF_8000_XXXX range after the far-jmp.
- **Exit fingerprint.** New mode `boot_r14b_hh` (5 lines): existing `boot_r8_only` + `HIGHER-HALF OK` tag emitted from `kernel_main` after far-jmp confirms `rip` via `lea + and imm` witness.
- **Prereqs.** M1.
- **Blocked-by.** None.
- **Issue count.** 3 (boot_stub far-jmp, kernel_main high-VA audit tag, boot_r14b_hh smoke fixture).
- **RISK: HIGH.** Bad far-jmp target triple-faults with no error. Mitigation: extra audit pass, explicit `qemu -d int` bisect harness, single-instruction step through the far-jmp offline.

#### M3 · `r14b-m3-syscall-cr3-switch`
- **Goal.** Add KPTI CR3 switch to `syscall_entry` / `syscall_return` trampoline. Entry: save user CR3, load kernel CR3 (already loaded — this is a no-op initially since user CR3 == kernel CR3 until M4). Exit: reverse.
- **Deliverable.** Trampoline reads user CR3 into a scratch register on entry, writes kernel CR3, then on exit writes user CR3 back. All syscalls (currently unreached from ring 3, still exercised via kernel-side smoke) continue to succeed.
- **Exit fingerprint.** 5 modes + `boot_r14b_hh` pass byte-identically. Optional: `CR3 SWITCH` tag emitted from within the trampoline (guarded by a compile-time flag to avoid noise in final `boot_r17_shell` mode).
- **Prereqs.** M2.
- **Blocked-by.** None; paideia-as `mov cr3, r64` already present.
- **Issue count.** 2 (trampoline CR3 switch, tests).
- **RISK: HIGH.** CR3 switch inside the trampoline is a hairpin — the page containing `syscall_entry` must be mapped in both PGDs. Enforcement via dedicated `.text.trampoline` linker section with attributes.

#### M4 · `r14b-m4-kpti-user-pgd`
- **Goal.** Real body for `aspace_create_user_pgd(kernel_pml4) -> user_pml4`. Constructs a user PML4 that maps only PML4 entries [0..255] (user aspace) + a minimal kernel-side view: the trampoline page, the IST stacks, and the kernel stack for the current thread. Sentinel `ASPACE_CREATE_NOT_YET` is retired.
- **Deliverable.** `kpti.pdx` real. First-user-thread creation calls `aspace_create_user_pgd`. CR3 switch on syscall entry/exit now switches between distinct PGDs.
- **Exit fingerprint.** New mode `boot_r14b_kpti` — extends `boot_r14b_hh` with `KPTI OK` tag after kernel main calls `kpti_user_pgd_create` for a test aspace and validates the returned PML4 by walking it and asserting entries [256..511] contain only trampoline + IST + kernel-stack entries.
- **Prereqs.** M3.
- **Blocked-by.** None.
- **Issue count.** 4 (kpti.pdx real body, trampoline-page audit, IST-page mapping, smoke fixture).
- **RISK: MED.** KPTI mapping bugs cause `#PF` inside the trampoline before it can dispatch to a handler, which routes through IST — as long as IST is correctly mapped in the user PGD, the fault becomes debuggable rather than triple-faulting.

#### M5 · `r14b-m5-phase-a-closure`
- **Goal.** Phase R14B-α closure. Ratify Path B as complete. Bump paideia-as submodule if v0.12.0 has landed by now (it should — see M6).
- **Deliverable.** `boot_r14b_kpti` mode green three reps. Retrospective audit `design/audit/entries/r14b-alpha-closure.md`.
- **Exit fingerprint.** All 6 modes green (5 legacy + `boot_r14b_kpti`).
- **Prereqs.** M4.
- **Blocked-by.** None.
- **Issue count.** 1 (closure).

### Phase R14B-β — Ring-3 substrate (5 milestones)

#### M6 · `r14b-m6-tss-ltr-confirm`
- **Goal.** Confirm TSS `ltr` landing (71d0976) survives KPTI transitions. TSS.RSP0 correctly points to per-thread kernel stack. Ring-3 exception delivery is testable in principle.
- **Deliverable.** Audit tag `TSS RSP0 OK` emitted from `kernel_main` after TSS install, validating that `str` (store task register) returns 0x30. Cross-audit against paideia-as v0.12.0 encoder byte pattern for `ltr`.
- **Exit fingerprint.** `boot_r14b_kpti` + `TSS RSP0 OK` line added.
- **Prereqs.** M5.
- **Blocked-by.** paideia-as v0.12.0 (already landed for `ltr r16` per r13-m4-002). If v0.12.0 has not merged, this milestone is where the submodule bump happens.
- **Issue count.** 2 (TSS audit tag, submodule bump if needed).

#### M7 · `r14b-m7-user-toolchain`
- **Goal.** `tools/build-user.sh` compiles `src/user/*.pdx` under `src/user/link-user.ld` (user linker script) and produces `shell.bin` at fixed base VA (recommended: 0x0000_0000_0040_0000). `.incbin` embed of `shell.bin` into `kernel.elf` via a new symbol `_shell_bin_start` / `_shell_bin_end`.
- **Deliverable.** `tools/build-user.sh` script. `src/user/link-user.ld`. `build.sh` runs `build-user.sh` first. `readelf -s build/kernel.elf | grep _shell_bin` shows both symbols.
- **Exit fingerprint.** Boot fingerprint unchanged; new `SHELL BIN sz=N` audit tag on kernel_main emit where N is `_shell_bin_end - _shell_bin_start`.
- **Prereqs.** M6.
- **Blocked-by.** None (parse surface for 0.6.0 covers the shell source shape landed in R13; if a new construct is needed for the shell body it will surface an escalation at M22–M24).
- **Issue count.** 3 (build-user.sh, link-user.ld, kernel embed + audit tag).

#### M8 · `r14b-m8-syscall-c-amendment`
- **Goal.** Resolve r14-preflight §E: choose Option 1 (POSIX-style syscalls 13–16 for open/close/read/write) OR Option 2 (KIND_FILE cap-slot). Freeze §C'.
- **Deliverable.** `design/capabilities/file-syscall-semantics.md` written, deciding one option with pillar-aligned justification. Syscall table `table.pdx` amended if Option 1; new KIND_FILE stub + design if Option 2. Only the design + a scaffolding stub land here; real implementation is M15/M18/M19.
- **Exit fingerprint.** All modes unchanged. Design doc committed.
- **Prereqs.** M6 (no code dependency, but philosophically must be ratified before M9+).
- **Blocked-by.** User approval on the option choice (§11.1 flags this as an open architectural question).
- **Issue count.** 1 (design + stub + audit).
- **Note.** osarch recommendation: **Option 1** (POSIX-style syscalls 13–16). Rationale: (a) Pillar 3 (strict microkernel) is honored either way — the fd table + tmpfs live in kernel space at R14B whether they hide behind an fd integer or a cap slot, because there is no user-space FS server yet; (b) Pillar 5 (no backwards compat) is not violated by using integer fds — fds are a general typed-handle abstraction predating POSIX (Multics, ITS), and PaideiaOS-`fd` is not required to obey POSIX semantics like `dup2`, `select`, `fcntl` — it is simply "integer index into per-process kernel-side handle table"; (c) simpler implementation → smaller trusted computing base for R14B; (d) can be migrated to Option 2 in R17-post as a cap-security hardening without changing user-visible ABI (fd = 0..255 becomes a per-process cap-slot alias with kernel dispatch). Option 2 remains superior long-term (revocation, delegation) but adds risk to a phase already saturated with substrate work.

#### M9 · `r14b-m9-elf-lite-loader`
- **Goal.** Real body for `process/exec.pdx`: parse ELF-lite header of `_shell_bin`, walk PT_LOAD segments, map each into a fresh user aspace via `aspace_map`, set user entry PC = ELF `e_entry`.
- **Deliverable.** `process/elf_lite.pdx` (parser), `process/exec.pdx` (loader), `process/exec_smoke.pdx` (kernel-side test that runs at boot: create process → exec shell_bin → assert user aspace has expected mappings). "ELF-lite" is PaideiaOS's stripped ELF subset — 64-bit only, LOAD segments only, no dynamic, no relocation, no interp (see `design/toolchain/elf-lite-spec.md` — TODO: verify this doc exists; if not, write as M9 side-work).
- **Exit fingerprint.** New audit tag `EXEC LOADED entry=0xN` on COM1.
- **Prereqs.** M7, M8.
- **Blocked-by.** None.
- **Issue count.** 4 (elf_lite parser, exec real, exec_smoke, design/toolchain/elf-lite-spec.md if missing).

#### M10 · `r14b-m10-first-ring3-sysret`
- **Goal.** First ring-3 execution. Kernel does exec_shell + aspace_activate + set up user stack + issue SYSRET into user `_start`. User `_start` executes `hlt` immediately (as a proof-of-life placeholder; real shell _start comes at M22).
- **Deliverable.** Ring-3 hlt fires. Since ring-3 hlt is a #GP (privileged instruction), the #GP handler catches it, prints `RING3 HLT #GP` tag, and shuts down cleanly. This confirms ring-3 executed at least one instruction.
- **Exit fingerprint.** New mode `boot_r14b_ring3` — first `RING3 ENTER` tag before hlt attempt; `#GP FROM RING3` tag from handler; clean shutdown.
- **Prereqs.** M9.
- **Blocked-by.** None (all substrate assumed in place).
- **Issue count.** 5 (user _start placeholder, user stack setup, SYSRET path exercise, #GP handler audit-tag differentiation for ring-3 origin, smoke fixture).
- **RISK: HIGH.** First SYSRET. Requires MSR_STAR + MSR_LSTAR + FMASK + KPTI + TSS.RSP0 + user aspace + user CR3 + user CS/SS descriptor bits all correct. Any single wrong bit → triple-fault or immediate #GP. Mitigation: incremental commits within the milestone, each with independent audit, before the SYSRET itself is executed.

### Phase R14B-γ — Ring-3 semantics + IO substrate — 8 milestones

#### M11 · `r14b-m11-first-ring3-syscall`
- **Goal.** User `_start` changes from bare `hlt` to a `syscall` with rax=12 (`sys_debug_puts`) pointing at a static string `"HELLO FROM RING3"`.
- **Deliverable.** Ring-3 syscall lands in kernel `syscall_entry`, dispatches to `sys_debug_puts`, prints message, returns via SYSRET, user continues to `hlt`.
- **Exit fingerprint.** `HELLO FROM RING3` on COM1, followed by `#GP FROM RING3` (from the hlt). New mode `boot_r14b_syscall`.
- **Prereqs.** M10.
- **Blocked-by.** None.
- **Issue count.** 3 (user syscall shim update, kernel-side audit for ring-3 origin, smoke).
- **RISK: HIGH.** First syscall from ring 3. All the KPTI + SYSCALL substrate now sees load. Failure modes: KPTI CR3 not mapping trampoline in user PGD (→ triple-fault before any handler runs), TSS.RSP0 wrong (→ #DF), SYSRET path leaves IF clear (→ ring 3 hangs). Mitigation: bisect-friendly commit split.

#### M12 · `r14b-m12-user-pf-delivery`
- **Goal.** Kernel handles a ring-3 page fault without triple-faulting. User `_start` deliberately dereferences NULL (or an unmapped high VA); kernel `pf_handler` receives via IST, prints `#PF FROM RING3 addr=NULL`, kills the process (frees aspace, marks exit).
- **Deliverable.** `pf_handler.pdx` extended to differentiate kernel vs. user origin via error-code bit 2 (`U/S`, per Intel SDM Vol 3A §4.7). User-origin faults trigger process kill; kernel-origin retain the trace-then-halt semantics.
- **Exit fingerprint.** New mode `boot_r14b_pf` — user `_start` NULLs and dies; `#PF FROM RING3 addr=0x0 killed pid=1` tag; kernel shuts down cleanly.
- **Prereqs.** M11.
- **Blocked-by.** None.
- **Issue count.** 3 (pf_handler user branch, process kill path, smoke).
- **RISK: MED.** `#PF` from ring 3 lands via IDT[14] with IST already wired (r13-m4-004). What is new: the handler must differentiate origin and initiate a controlled kill, not halt the kernel.

#### M13 · `r14b-m13-ring3-timer`
- **Goal.** LAPIC timer interrupt from ring 3 correctly delivers to kernel via IDT, saves user context, dispatches ISR, restores, returns to ring 3.
- **Deliverable.** User `_start` from M11 is amended to spin (jump to self) instead of hlt. LAPIC timer fires, kernel handler prints `TIMER FROM RING3`, iretqs. User continues spinning. After N timer ticks, kernel forces exit.
- **Exit fingerprint.** New mode `boot_r14b_timer` — `TIMER FROM RING3` × N in output.
- **Prereqs.** M12.
- **Blocked-by.** None.
- **Issue count.** 3 (timer ISR ring-3 audit, forced-exit path, smoke).
- **RISK: MED.** First interrupt from ring 3. Verifies IDT[32] (LAPIC timer vector) correctly saves user context on kernel stack (not IST — LAPIC timer uses RSP0 via TSS).

#### M14 · `r14b-m14-argv-setup`
- **Goal.** Kernel sets up user stack with `argc`, `argv[]`, `envp[]` (empty), per SysV AMD64 ELF ABI (TODO: verify System V Application Binary Interface AMD64 Architecture Processor Supplement §3.4.1). User `_start` reads argc from stack, echoes `argc=N` via `sys_debug_puts`.
- **Deliverable.** `process/exec.pdx` extended to accept `argc`, `argv_ptr` and push them onto the user stack per ABI. `_start` in user reads them, echoes.
- **Exit fingerprint.** `argc=1 argv[0]=shell` on COM1. New mode `boot_r14b_argv`.
- **Prereqs.** M13.
- **Blocked-by.** None.
- **Issue count.** 2 (exec argv push, user _start argv reader).
- **RISK: LOW.** Straight data manipulation.

#### M15 · `r14b-m15-sys-read-polled`
- **Goal.** `sys_read(fd, buf, count)` implementation, polled UART variant. Blocks until UART DR (data ready) bit set, reads one byte, copies to user via `copy_to_user` (audit at M17), returns 1. Ignores fd for now (assumes stdin).
- **Deliverable.** `syscall/sys_read.pdx`. User `_start` amended to `sys_read(0, &buf, 1)`, then `sys_debug_puts("got: X")` where X is the byte.
- **Exit fingerprint.** New mode `boot_r14b_read_polled` — smoke feeds `X` on stdin (QEMU `-serial mon:stdio` + `send-char` from a script), kernel echoes `got: X`.
- **Prereqs.** M14.
- **Blocked-by.** None.
- **Issue count.** 4 (sys_read impl, copy_to_user audit, user _start amendment, smoke harness for stdin injection).
- **RISK: MED.** `copy_to_user` semantics: kernel must verify buf pointer is in user aspace and unmapped-page fault does not crash kernel. SMAP mitigates — access to user page from kernel requires STAC/CLAC bracketing (Intel SDM Vol 3A §4.6.1). At R14B this is manual; a `copy_to_user` primitive that STACs, does the access, CLACs is the M15 substrate deliverable.

#### M16 · `r14b-m16-uart-rx-isr`
- **Goal.** Upgrade from polled to interrupt-driven UART RX. IOAPIC routes COM1 IRQ4 to LAPIC vector 0x24 (or PIC vector 0x24 if IOAPIC bring-up is deferred). ISR reads UART LSR + RBR, pushes byte to kernel-side ring buffer, wakes any waiter on UART sleep queue.
- **Deliverable.** `int/uart_rx_isr.pdx`, `uart/rx_ring.pdx`. `sys_read` from M15 changes: check ring buffer; if empty, `block_on(uart_wait_queue)`; ISR wakes it.
- **Exit fingerprint.** `boot_r14b_read_polled` transitions to `boot_r14b_read_isr` — same input transcript, same output, but ring buffer + block/wake path exercised.
- **Prereqs.** M15, Scheduler `block_on`/`wake_one` (also lands here as substrate).
- **Blocked-by.** IOAPIC bring-up if used (add sub-milestone). Otherwise PIC-legacy route works.
- **Issue count.** 5 (uart_rx_isr, rx_ring, sched block_on/wake_one, IOAPIC or PIC route decision, smoke).
- **RISK: MED.** Sleep queue + wake path first exercise. If wake incorrect, sys_read hangs forever.

#### M17 · `r14b-m17-tty-line-discipline`
- **Goal.** Kernel-side TTY layer that transforms raw UART RX into line-buffered reads. Echoes each char (to UART TX), handles CR → LF conversion, handles backspace (erase last char + emit `\b \b`), buffers until CR/LF, then delivers full line to blocked `sys_read`.
- **Deliverable.** `uart/tty.pdx`. `sys_read` delegates to `tty_read_line`. Existing `boot_r14b_read_isr` upgrades: input `hello\n` → single `sys_read` returns "hello\n".
- **Exit fingerprint.** `boot_r14b_tty` — feed `hello\n`, kernel echoes each char, sys_read completes, kernel prints `got: hello`.
- **Prereqs.** M16.
- **Blocked-by.** None.
- **Issue count.** 3 (tty layer, echo path, smoke).
- **RISK: LOW.** Bounded string manipulation.

#### M18 · `r14b-m18-sys-write`
- **Goal.** `sys_write(fd, buf, count)` — writes `count` bytes from user buf to UART (ignoring fd; assumes stdout). Uses STAC/CLAC bracketed `copy_from_user`.
- **Deliverable.** `syscall/sys_write.pdx`. Distinct from `sys_debug_puts` (12) — `sys_write` (16) is the frozen user ABI; `sys_debug_puts` remains for kernel-side debug.
- **Exit fingerprint.** `boot_r14b_write` — user `_start` calls `sys_write(1, "written from ring 3\n", 20)` → COM1 shows the text.
- **Prereqs.** M17.
- **Blocked-by.** M8 syscall-table amendment must have added ID 16 for sys_write.
- **Issue count.** 3 (sys_write impl, copy_from_user primitive, smoke).

### Phase R14B-ε — Filesystem + shell — 8 milestones

#### M19 · `r14b-m19-fd-table`
- **Goal.** Per-process fd table (kernel-side). 64 fds. Each fd points to a struct with `{ops_ptr, private_data, ref_count, flags}`. Ops table has read/write/close pointers. `sys_open` at this milestone always succeeds for the special path `/dev/console` and binds fd to a console-ops struct.
- **Deliverable.** `fs/fd_table.pdx`. `syscall/sys_open.pdx` and `syscall/sys_close.pdx` real. `sys_read` and `sys_write` now dispatch through ops table (not hardcoded UART).
- **Exit fingerprint.** `boot_r14b_fd` — user opens `/dev/console`, reads a byte, writes a byte. Same COM1 IO as before but via fd dispatch.
- **Prereqs.** M18. §C amendment (M8) ratified.
- **Blocked-by.** None.
- **Issue count.** 5 (fd_table struct, sys_open, sys_close, ops dispatch in read/write, smoke).

#### M20 · `r14b-m20-tmpfs`
- **Goal.** In-memory hierarchical filesystem. inode pool (64 entries × 64 B), data pool (16 KiB), path lookup (single-level parse; nested lookup R17-post). `sys_open("/help.txt", O_RDONLY)` succeeds and reads back a pre-populated help text.
- **Deliverable.** `fs/tmpfs.pdx`. Boot init writes `/help.txt` = HELP_TEXT constant.
- **Exit fingerprint.** `boot_r14b_tmpfs` — user opens `/help.txt`, reads it via loop, writes to `/dev/console`; COM1 shows help text.
- **Prereqs.** M19.
- **Blocked-by.** None.
- **Issue count.** 5 (tmpfs inode + data, path parse, sys_open dispatch, boot-time populate, smoke).

#### M21 · `r14b-m21-vfs-mount`
- **Goal.** VFS layer with mount table. `tmpfs` mounts at `/`. `/dev/console` mounts via bind at `/dev/console` (or `devfs` variant — decision: bind on tmpfs is simpler for R14B, defer devfs to R17-post).
- **Deliverable.** `fs/vfs.pdx` with `vfs_mount`, `vfs_lookup`. `sys_open` walks mount table before delegating.
- **Exit fingerprint.** `boot_r14b_vfs` — `/dev/console` and `/help.txt` both openable via the same `sys_open`.
- **Prereqs.** M20.
- **Blocked-by.** None.
- **Issue count.** 4 (vfs.pdx, mount, lookup, smoke).

#### M22 · `r14b-m22-shell-main-loop`
- **Goal.** Real shell `_start`: open `/dev/console` (fd 3; fds 0/1/2 pre-opened by kernel), print banner, enter main loop. Body of the loop is a stub at this milestone: `puts("$ "); sys_read(0, buf, 256); puts("got line\n");` in an infinite loop.
- **Deliverable.** `src/user/shell.pdx` rewritten. `_start` calls into a `main` in `src/user/main.pdx`. Main loop stub.
- **Exit fingerprint.** `boot_r14b_shell_loop` — feed one line, shell echoes `got line` and re-prompts. Kill after 3 loops.
- **Prereqs.** M21.
- **Blocked-by.** None (assumes parse surface holds; if any construct fails, escalate).
- **Issue count.** 4 (shell.pdx rewrite, main.pdx, banner, smoke).

#### M23 · `r14b-m23-shell-readline`
- **Goal.** Line reader in user space. Loops `sys_read(0, buf+i, 1)`; returns buf when byte is `\n`. This is a duplicate of TTY line discipline (M17) but from the *user* side, which is honest: kernel TTY already returns lines, but user readline is the API boundary. If TTY layer delivers a full line in one read, this is trivially a wrapper.
- **Deliverable.** `src/user/readline.pdx :: readline(buf, max) -> n_read`.
- **Exit fingerprint.** Same as M22 but now the shell handles multi-byte lines correctly if TTY changes to raw mode (not in R14B, but the abstraction is future-proof).
- **Prereqs.** M22.
- **Blocked-by.** None.
- **Issue count.** 2 (readline, integration into shell main).

#### M24 · `r14b-m24-parser-and-builtins`
- **Goal.** Whitespace-split the line into argv, look up builtin by argv[0], dispatch. Three builtins: `help`, `echo`, `exit`.
- **Deliverable.** `src/user/parser.pdx`, `src/user/builtins.pdx` rewritten (R13 stub replaced). `help` reads `/help.txt` and writes to stdout. `echo` writes argv[1..] joined by spaces, plus LF. `exit` calls `sys_exit_thread(0)`.
- **Exit fingerprint.** `boot_r14b_shell_builtins` — feed `help\necho hello\nexit\n`, expect help text + `hello` + shell termination.
- **Prereqs.** M23.
- **Blocked-by.** None (assumes parse surface holds).
- **Issue count.** 4 (parser, help builtin, echo builtin, exit builtin).
- **RISK: MED.** Parser + builtins may drive fresh paideia-as gaps (function-pointer-like table dispatch for builtins may hit register-indirect-call absence; workaround via cmp/je chain per parse surface memory note).

#### M25 · `r14b-m25-exit-reap-shutdown`
- **Goal.** User `exit` → `sys_exit_thread(0)` → kernel marks TCB EXITED → reaper (running on BSP, invoked from the syscall exit path when it detects no runnable user threads) frees aspace, cap-table, fd-table, process slot. Reaper then issues shutdown: `isa-debug-exit` byte 0x10 (existing smoke convention) or ACPI shutdown (R17-post).
- **Deliverable.** `process/exit.pdx`, `process/reap.pdx`, `boot/shutdown.pdx`.
- **Exit fingerprint.** `INIT REAPED` + `SHUTDOWN` tags followed by QEMU exit code 33.
- **Prereqs.** M24.
- **Blocked-by.** None.
- **Issue count.** 4 (sys_exit_thread real, reaper, shutdown path, smoke).
- **RISK: MED.** Freeing an aspace that is currently in CR3 must switch CR3 to kernel-only PGD first, then walk-and-free. TLB semantics require INVLPG or full CR3-flush; INVLPG per-page suffices with PCID 0 for user aspace.

#### M26 · `r14b-m26-demo-closure`
- **Goal.** End-to-end demo. Serial input transcript matches §1.1. New smoke mode `boot_r17_shell` (retaining the naming style: this is the R17 close-out fingerprint, even though it lands in R14B numbering). Retrospective `design/round-retrospectives/r14b-shell-reached.md`.
- **Deliverable.** `tests/r14b/expected-shell.txt` with the exact transcript from §1.1, `tools/run-smoke.sh` mode dispatcher extended. All 6+8=14 modes green three reps.
- **Exit fingerprint.** `boot_r17_shell` transcript matches byte-identically (contains-in-order).
- **Prereqs.** M25.
- **Blocked-by.** None.
- **Issue count.** 2 (expected transcript, smoke mode dispatcher).

**Total milestone count: 26.** Slightly above the 15–25 sweet spot; the user requested "more milestones better than fewer if each has a real deliverable." M6 (TSS confirm) could be merged into M5 if softarch determines the audit tag is trivial; M23 could be merged into M22 if readline is a two-line wrapper. Both merges would drop the count to 24 without losing observable deliverables.

---

## 5. Verification Strategy Evolution

The 5-mode smoke discipline is the covenant of the round. R14B is additive: existing modes NEVER change; new modes gate new features until stable, then optionally graduate.

### 5.1 Mode evolution table (per phase)

| Phase | Modes existing at phase entry | New modes added | Total at phase exit |
|---|---|---|---|
| Entry (2026-07-04) | boot_r8_only, boot_r10, boot_r11, boot_r12, boot_r12_denial | — | **5** |
| R14B-α close (M5) | 5 legacy | boot_r14b_hh (M2), boot_r14b_kpti (M4) | **7** |
| R14B-β close (M10) | 7 | boot_r14b_ring3 (M10) | **8** |
| R14B-γ close (M18) | 8 | boot_r14b_syscall (M11), boot_r14b_pf (M12), boot_r14b_timer (M13), boot_r14b_argv (M14), boot_r14b_read_polled (M15), boot_r14b_read_isr (M16), boot_r14b_tty (M17), boot_r14b_write (M18) | **16** |
| R14B-ε close (M26) | 16 | boot_r14b_fd (M19), boot_r14b_tmpfs (M20), boot_r14b_vfs (M21), boot_r14b_shell_loop (M22), boot_r14b_shell_builtins (M24), boot_r17_shell (M26) | **22** |

Twenty-two modes at R14B close. Runtime per pre-push run: 22 modes × 3 reps × ~7 s = ~460 s. Acceptable; if it becomes onerous, softarch may consolidate lower-tier modes (e.g. `boot_r14b_read_polled` can be retired once `boot_r14b_read_isr` is stable and covers the same input transcript).

### 5.2 Byte-identical invariance across R14B

- **`boot_r8_only`** — MUST remain byte-identical from R8 (2026-05 landing) through R14B close. This is the anchor for the "no substrate churn" claim.
- **`boot_r10`, `boot_r11`** — MUST remain byte-identical. Any scheduler change must NOT alter their output.
- **`boot_r12`, `boot_r12_denial`** — MUST remain byte-identical. Any cap-dispatch change must NOT alter their output.

Any commit that changes any of the 5 legacy modes' fingerprint is a regression that MUST be reverted or accompanied by an explicit fingerprint amendment with r14-preflight-equivalent audit.

### 5.3 New-feature gating

New features are landed *behind* their own smoke mode. The pre-push hook runs all modes; a mode-owning commit that adds `boot_r14b_pf` must ensure `boot_r14b_pf` passes locally. A commit that touches subsystem code without adding or updating a mode is flagged for softarch review.

### 5.4 Fingerprint contains-in-order semantics

All fingerprints use the existing "contains-in-order" match (`tools/run-smoke.sh` current behavior). Byte-exact match is not required; each expected line must appear in order in the serial log, with arbitrary interleaving allowed (e.g. new debug tags from unrelated subsystems don't fail the fingerprint). This is Pareto-optimal for backward compatibility: adding new tags doesn't invalidate old fingerprints.

### 5.5 Input-injection smoke harness (NEW at M15)

`tools/run-smoke.sh` currently reads only kernel output. Starting at M15, a subset of modes require injecting stdin bytes into COM1. Recommended mechanism:

- QEMU option `-serial mon:stdio` allows a companion script to write to the same COM1.
- A wrapper `tools/run-smoke-io.sh` (NEW at M15) accepts a mode name and an input transcript file (e.g. `tests/r14b/input-shell.txt`), pipes the input into QEMU stdin at controlled rate (e.g. 20 ms/byte to simulate human typing), captures serial output, matches against expected transcript.
- Alternative: QEMU `chardev` with a socket, driven by a `netcat`-based feeder. Softarch decides at M15 preflight.

---

## 6. Encoder Gap Forecast (paideia-as escalations by phase)

Encoder gaps are surfaced during execution, not before. This list is anticipatory — based on grep of the kernel + user sources for constructs that will appear in R14B milestones and cross-referencing against paideia-as 0.11.0/0.12.0 encoder coverage per take-stock §1.14. Each entry lists (form, milestone-first-need, hardness, workaround if any).

### 6.1 R14B-α (M1–M5)

- **`ljmp *m64`** — CONFIRMED present per r14-preflight §A.1. No escalation.
- **`mov r64, imm64` (movabs)** — CONFIRMED present. No escalation.
- **`mov cr3, r64`** — CONFIRMED present per project-paideia-as-surface memory note. No escalation.
- **`invlpg [mem]`** — status TBD in preflight. Likely present per aspace_map (r14-m2-003) landing. Verify at M2.

### 6.2 R14B-β (M6–M10)

- **`iretq`** — REQUIRED for a non-SYSCALL return-to-user path. R14B chooses SYSRET-only initially; `iretq` may still be needed for interrupt return from ring 3. **Status TBD** — the R11 preemption epilogue already returns via iretq for ring-0 preemption; needs audit at M6 whether the same encoding works for ring-3 return. If not present, PA-R14B-001 filing at M6.
- **`hlt`** — CONFIRMED present per parse-surface memory. No escalation.
- **`swapgs`** — DEFERRED per r13-m1-002. Not required at R14B if single-CPU. Do not force. If needed (per-CPU state via GS becomes required for TTY sleep queue or similar), file PA-R14B-002.
- **`sti`, `cli`** — CONFIRMED present per parse-surface memory. No escalation.

### 6.3 R14B-γ (M11–M18)

- **`stac`, `clac`** — REQUIRED for SMAP-gated user-memory access at M15's `copy_to_user`. **Status TBD** — grep paideia-as encoders. Anticipated absent; PA-R14B-003 filing at M15 preflight.
- **`in`, `out`** — CONFIRMED partially present (`out_al rax`) per parse-surface. Verify variants (`in al, dx`, `out dx, al`) needed for UART RX polling (already used at TX). PA-R14B-004 if absent.
- **`test r/m, imm`** or **`bt r/m, imm`** — REQUIRED for UART LSR bit-checking. Likely present (test used pervasively). Verify at M15.
- **Register-indirect `call *reg`** or `call *mem` — REQUIRED for `fs/fd_table.pdx` ops-table dispatch (M19 rather than γ, listed here for planning). Per r14-preflight §A.1 memory note, indirect near jmp is ABSENT; call form status TBD. If both absent, workaround: linear cmp/je chain per operation kind (Pareto-adequate at 4 ops per ops table). Filed as PA-R14B-005 for future R15+ dispatch. Non-blocking at R14B.

### 6.4 R14B-ε (M19–M26)

- **Struct field addressing with dynamic offset** (`mov r, [base + reg*scale + disp]`) — SIB with index. Status TBD; typically supported. Verify at M19 for fd table indexing.
- **Function-pointer-like storage in `.data` and load-then-call** — needed for builtins table (M24). Workaround per register-indirect-call absence: cmp/je chain enumerating builtin names.
- **Bulk copy loops** (`rep movsb`) — REQUIRED for `sys_write` copy_from_user in M18. **Status TBD** — file PA-R14B-006 if absent; workaround is scalar loop with `mov` per byte (slower but adequate at demo scale).

### 6.5 Deferred to R15+ (documented for continuity)

- **`fxsave`, `fxrstor`** — PA-R13-007, R13 open. Blocks FP context save/restore (C17). Not needed until user programs use FP registers; shell doesn't.
- **`lock cmpxchg`, `xchg [mem], reg`, `mfence`** — PA-R13-012 bundle, R13 open. Blocks multicore; deferred with the multicore path.
- **GS-relative memory operand** — PA-R14-001 (#926). Blocks efficient per-CPU. Deferred with multicore.
- **`rdmsr`/`wrmsr` variants** — parse-surface confirms `wrmsr` present. `rdmsr` verify at M11.
- **`cpuid`** — status TBD; likely present per CR4 SMEP/SMAP CPUID guards in existing code. Verify.
- **CET (`endbr64`, `wruss`)** — not needed at R14B; R17-post per take-stock §2.

### 6.6 Total anticipated escalations

**6 R14B-phase escalations** (001–006), of which the first 3 are HIGH-probability, the rest MED-probability. Rate consistent with take-stock §2.8 baseline of 3 encoder gaps per round; R14B is 4-phase so 6 is proportionate.

paideia-as release cadence: v0.13.0 targets escalations 001–004 (R14B-β/γ needs), v0.14.0 targets 005–006 (R14B-ε needs). Both should land within R14B execution window without blocking milestones by more than 1 issue's worth of lead time — provided the per-`feedback_cross_repo_escalation.md` discipline is followed rigorously.

---

## 7. Rigor Invariants

Baseline discipline that MUST hold for every commit in R14B, per `feedback_paideia_os_no_cicd.md`:

1. **5 legacy modes byte-identical.** Every commit runs `tools/run-smoke.sh boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`, `boot_r12_denial` locally before push (via pre-push hook). Any change to expected output requires an explicit audit entry in `design/audit/entries/` naming the milestone that authorized the change.

2. **Milestone-mode gating.** New features land behind their milestone's smoke mode. Commit N introduces mode M_N; commit N+1 that touches M_N's subsystem must show M_N still passes.

3. **Structural-stub honesty.** If a milestone cannot complete real due to a substrate gap, land a structural stub per the r13-retrospective (c) pattern (pool + offsets pinned; not in dispatch chain; boot-invisible). Do NOT hidden-shortcut. Reference #430 debugger catch as the anchor.

4. **Cross-repo escalation discipline.** When a paideia-as gap is discovered during R14B execution, file PA-R14B-NNN within 24 hours (per `feedback_cross_repo_escalation.md`), push a fix to paideia-as, bump submodule pointer, resume paideia-os. Do NOT block paideia-os on paideia-as while alternative milestones exist.

5. **Preflight-M0.5 reachability audit.** Every phase (α/β/γ/ε) opens with a reachability audit tracing the phase's headline observable back through touched subsystems. Any gap must be filed as a blocker issue before the phase's M2 opens. This is the r13-retrospective (e) lesson generalized to sub-phase granularity.

6. **§C-freeze audit on every issue body.** Every new issue body during R14B is scanned against the current §C table (13 today, 17 post-M8) before entering the sprint queue. r13-retrospective (a) lesson.

7. **Design-doc parity for every real landing.** Every real handler landing includes a `design/audit/entries/r14b-mN-###-*.md` entry naming the pillar alignment, the substrate assumption, the deferral chain, and the exit fingerprint. The r13-m6-* audit entries are the model.

8. **paideia-as version discipline.** workspace.version + git tag + CHANGELOG entry move together at each phase close (per `feedback_paideia_as_version_discipline.md`). tools/find-paideia-as.sh remains strict.

### 7.1 Backtracking discipline

When a milestone reveals a design gap: file an issue, fix in-place, retain the milestone number, retry. Do NOT renumber downstream milestones. Do NOT collapse the failing milestone into the next one silently. **Every backtracking event gets a `design/audit/entries/r14b-mN-backtrack-*.md` entry** so the round retrospective can compute the actual backtracking rate against the plan.

R13 had 3 backtracking events across 6 milestones (#481, #482, #488) — 50% rate. R14B under the preflight-M0.5 discipline targets <20% (fewer than 5 events across 26 milestones). If the actual rate exceeds 30%, the R14B mid-round retrospective triggers a scope pause.

### 7.2 What is NOT invariant (what MAY change)

- **Serial output tag names.** Individual tag strings (e.g. `HIGHER-HALF OK` vs `KPTI OK`) may change during milestone development. What is invariant is that the frozen fingerprint file for each smoke mode continues to match.
- **Internal ABI within a subsystem.** TCB byte offsets are frozen; register conventions inside `sched_switch_to` are not. Aggressive refactoring within a landing is fine.
- **Handler-table dispatch style.** May migrate from linear cmp/je to indirect table at R17-post per R12 boundary #7.

---

## 8. Risk Map

For each milestone: triple-fault risk (LOW/MED/HIGH), reason, mitigation. Non-triple-fault risks (correctness, semantic) are secondary and covered per milestone in §4.

| Milestone | Triple-fault | Reason | Mitigation |
|---|---|---|---|
| M1 (linker VMA) | LOW | No code executes at high VA yet. | — |
| M2 (far-jmp) | **HIGH** | Bad far-jmp target triple-faults immediately, no diagnostic. | `qemu -d int,cpu_reset` bisect harness. Extra static audit. Single-step in QEMU monitor. Test with high-VA target that halts cleanly before enabling the transition permanently. |
| M3 (CR3 switch trampoline) | **HIGH** | Trampoline page not mapped in both PGDs → #PF at entry → IDT[14] handler must be in both PGDs → #DF → triple-fault. | Dedicated `.text.trampoline` section with linker guarantee that IST[1] handler page is in both PGDs. Explicit invariant check in `kpti_user_pgd_create` (M4) asserts trampoline VA is present. |
| M4 (kpti user PGD) | MED | Bad KPTI PGD → #PF from trampoline → same chain as M3. | Invariant check + M4 dry-run: create PGD, walk it, assert entries. |
| M5 (closure) | LOW | No new code. | — |
| M6 (TSS confirm) | LOW | Already landed; only audit tag added. | — |
| M7 (user toolchain) | LOW | No runtime change. | — |
| M8 (§C amendment) | LOW | Design + stub only. | — |
| M9 (ELF-lite loader) | LOW | Kernel-side only; no ring transition yet. | Kernel-side smoke exercises before M10. |
| M10 (first SYSRET) | **HIGH** | First ring transition. Any MSR/GDT/TSS bit wrong → triple-fault. | Incremental commits: SYSRET path exercised with `_start = hlt` first, only then upgrade to `_start` with real code. `qemu -d int` bisect. |
| M11 (first ring-3 syscall) | **HIGH** | KPTI + SYSCALL substrate under first load. Any bit wrong → triple-fault. | Same as M10 mitigation. Full trace of first syscall trap via QEMU monitor. |
| M12 (user #PF) | MED | Requires IDT[14] + IST + KPTI to cooperate; if PF handler page not in user PGD, #DF → triple-fault. | Invariant check in `kpti_user_pgd_create`. Deliberate NULL deref is controlled, not chaotic. |
| M13 (ring-3 timer) | MED | LAPIC timer via RSP0 (not IST) on ring-3 preemption. Wrong TSS.RSP0 → #DF. | Verify M6 audit tag matched expected TSS.RSP0 value. Static assertion. |
| M14 (argv setup) | LOW | Data manipulation only. | — |
| M15 (sys_read polled) | LOW | UART poll from ring 0; already covered by legacy. STAC/CLAC bracket protects. | Audit STAC/CLAC pairing rigorously. |
| M16 (UART RX ISR) | MED | New interrupt vector; if handler not in kernel PGD (during KPTI), #DF. | KPTI user-PGD includes IST slot for legacy IRQ vector or LAPIC vector 0x24. |
| M17 (TTY line discipline) | LOW | Bounded string work. | — |
| M18 (sys_write) | LOW | copy_from_user with STAC/CLAC bracket. | Same as M15. |
| M19 (fd table) | LOW | Kernel data structures + dispatch. | — |
| M20 (tmpfs) | LOW | Kernel data structures. | — |
| M21 (VFS mount) | LOW | Kernel dispatch layer. | — |
| M22 (shell main loop) | MED | User binary parse-surface risk (new constructs may fail paideia-as check). | Incremental commits per shell.pdx section; escalate per shakedown. |
| M23 (shell readline) | LOW | User-side wrapper. | — |
| M24 (parser + builtins) | MED | User binary parse-surface risk; builtins dispatch may need workaround for indirect call. | Same as M22 + cmp/je fallback for builtin dispatch. |
| M25 (exit + reap + shutdown) | MED | Freeing an aspace in-use requires CR3 switch to kernel-only PGD before walk-free. If reaper runs on the same TCB whose aspace is being freed, self-immolation. | Reaper runs on BSP kernel-thread context with its own aspace. Explicit `switch_to_kernel_aspace_before_free` primitive. |
| M26 (demo closure) | LOW | Smoke fixture only. | — |

### 8.1 Top-3 highest-risk transitions and how the plan sequences around them

**Risk #1: M2 (boot-stub far-jmp to higher-half).** First VA transition. The plan dedicates an entire milestone to this single instruction rather than bundling it with M3. Rationale: if M2 fails, the failure is contained to the far-jmp itself and can be bisected with a static readelf audit + single-step in QEMU. The R14 kickoff document (§Path B risk assessment) already flagged this as the medium risk of Path B; M1's link.ld amendment lands strictly before M2 so the VA constant is testable statically before any runtime attempt.

**Risk #2: M3 + M4 (KPTI CR3 switch in trampoline).** The trampoline-page-mapping invariant is the classical KPTI failure mode (Meltdown mitigation post-2018, per Kaslr/Kernel Address Space Layout Randomization + PTI literature — TODO: verify citation to Gruss, Lipp et al. USENIX Security 2018 "KASLR is Dead: Long Live KASLR" or Linux `arch/x86/mm/pti.c` documentation). The plan sequences M3 with a NO-OP CR3 switch (user CR3 == kernel CR3) before M4 introduces distinct PGDs. This staged introduction ensures the trampoline's *code path* is validated before the *data structure* it depends on is exercised.

**Risk #3: M10 (first SYSRET).** First ring-3 execution. The failure surface is the union of every MSR, every GDT slot, every TSS field, every KPTI mapping, and every trampoline invariant. The plan sequences M10 with a `_start = hlt` placeholder — the fastest possible user program — so the failure diagnostic is unambiguous: if #GP fires from ring 3 attempting to execute hlt, ring 3 was reached. If anything before that triple-faults, one of the substrate invariants failed. M11 then upgrades to a real syscall, again with maximum isolation.

**Secondary risk #4 (mentioned for completeness): M25 (reaper freeing in-use aspace).** Not on the top-3 list because it is a bounded correctness concern rather than a triple-fault risk (self-immolation would #PF, not triple-fault, given IST). But it is a plausible late-round backtracking source and the plan explicitly addresses it via the `switch_to_kernel_aspace_before_free` primitive.

---

## 9. Ordering Rationale

The R14B milestone sequence is the **least-risky ordering that still delivers the shell demo**. Justifications:

### 9.1 R14B-α before R14B-β (Path B before ring-3 substrate)

Ratified in r14-kickoff §Path B recommendation. Higher-half + KPTI first because: (a) they are self-contained (no ring-3 dependency), (b) they clear the aspace_map safety story for user aspaces (kernel is out of low half, user aspaces populate low half without collision risk), (c) they are the smallest substrate lift with the largest downstream fan-out unblocking, (d) they are independent of the paideia-as v0.12.0 bundle (already landed) and any §C amendment decision.

### 9.2 M6 (TSS confirm) before M7 (user toolchain)

TSS is the ring-3 exception delivery substrate. Building `shell.bin` and embedding it in kernel.elf without TSS invites first-ring-3-fault triple-fault at M10. Confirming TSS survives the KPTI transition BEFORE building user code establishes the substrate contract.

### 9.3 M8 (§C amendment) before M9 (ELF-lite loader)

The syscall table is user-visible ABI. Loading a `shell.bin` compiled against §C then discovering §C' is required for the demo (post-M15) forces a shell rebuild. Locking §C' at M8 lets M22–M24 be written once.

### 9.4 M9 (ELF-lite loader) before M10 (first SYSRET)

M10 requires a user binary to jump to. The loader lands first; M10 exercises it end-to-end.

### 9.5 M11 (first ring-3 syscall) before M12 (user #PF)

Both are ring-3 → kernel transitions, but SYSCALL is the *design-happy path* (initiated by user, MSR-mediated) whereas #PF is the *exception path* (initiated by hardware, IDT-mediated). Getting the happy path working first gives a known-good reference for debugging the exception path.

### 9.6 M13 (ring-3 timer preemption) after M12 (user #PF)

Timer interrupt from ring 3 is a **third** ring-transition kind: hardware-initiated, but via IDT+RSP0 rather than IDT+IST. Sequencing it after #PF (IDT+IST from ring 3) establishes IDT-from-ring-3 confidence before the RSP0 vs IST discrimination is exercised.

### 9.7 M15 (polled RX) before M16 (ISR RX)

Polled RX exercises the full read data path (UART → kernel buffer → user via copy_to_user) synchronously. Interrupt-driven RX adds asynchronous sleep-queue semantics. Landing polled first lets M15 debug the *data path* independently of the *concurrency mechanism* which M16 introduces.

### 9.8 M17 (TTY line discipline) after M16 (ISR RX)

Line discipline is a filter on the RX byte stream. Debugging TTY on polled RX is possible but strictly harder (each poll only returns one byte; multi-byte scenarios are contrived). ISR RX + ring buffer establishes the natural boundary at which line discipline is a well-defined filter.

### 9.9 M19–M21 (fd table → tmpfs → VFS mount) before M22 (shell main loop)

The shell requires `sys_read(0)` and `sys_write(1)` to work through fd 0 / fd 1, which requires fd table + `/dev/console` binding. Landing the FS layers before shell start ensures the shell's first system call succeeds.

### 9.10 M25 (exit + reap + shutdown) before M26 (demo closure)

The `exit` builtin must complete the cycle. Without reaper + shutdown, the demo transcript truncates at `exit` without the `SHUTDOWN` tag or QEMU exit. The transcript expected in §1.1 depends on M25 landing.

### 9.11 On the ordering of defensive infrastructure before code it protects

The r14-m2-003 huge-page detection (already landed) is the canonical example. The plan continues that pattern:

- **`copy_to_user` / `copy_from_user` primitives** at M15/M18 land STRICTLY before the first user-memory access from kernel. STAC/CLAC bracketing is not optional and not retrofitted.
- **`switch_to_kernel_aspace_before_free`** at M25 lands before reaper's first invocation. Not retrofitted after a self-immolation.
- **KPTI trampoline-page invariant check** at M4 lands with `kpti_user_pgd_create` real body, not after M10's first ring-3 SYSRET reveals the mapping bug.

---

## 10. Definition of Done for R14B

R14B is closed when ALL of the following hold, as observed at a single git commit:

1. **All 22 smoke modes green three reps** via `tools/run-smoke.sh` and pre-push hook. The 5 legacy modes are byte-identical to their R13-closure snapshots.

2. **`boot_r17_shell` transcript matches §1.1 exactly** (contains-in-order). A user typing `help`, `echo hello`, `exit` at COM1 produces the expected output.

3. **Zero open R14B-tagged tracking issues in `paideiaos/paideia-os` repo.** Milestone completion issues #484 (m8 kernel-user), #485 (m9 VFS), #486 (m10 fork/exec/wait) are retired — either satisfied by R14B milestones or explicitly re-deferred to R17-post with a documented rationale in `design/milestones/r14b-closure.md`.

4. **paideia-as submodule pinned at whichever release closes the R14B encoder needs** (anticipated v0.13.0 or v0.14.0 per §6). CHANGELOG entry present. `tools/find-paideia-as.sh` strict.

5. **Retrospective document written**: `design/round-retrospectives/r14b-shell-reached.md` with: (a) rate of backtracking events vs plan target (<30%), (b) rate of encoder escalations vs plan target (6), (c) rate of design-doc-first vs code-first landings, (d) subsequent-phase carryover list. Follows the r13-retrospective template.

6. **Design docs updated**: at minimum `design/memory/higher-half-vma.md`, `design/capabilities/file-syscall-semantics.md`, `design/toolchain/elf-lite-spec.md`, `design/audit/entries/r14b-*` for every real landing.

7. **Percent-complete rollup improves**. Take-stock §1 rollup mean of ~26% at R14B entry should exceed ~40% at R14B close, driven primarily by:
   - Boot: 25% → 45% (higher-half + KPTI real).
   - MM: 22% → 40% (KPTI real, aspace_activate real).
   - Syscall: 30% → 65% (reached from ring 3, 8 handlers real).
   - Process: 12% → 45% (exec real, exit + reap real).
   - Filesystem: 0% → 30% (fd table + tmpfs + VFS + console).
   - UART/TTY: 8% → 60% (RX real, TTY real).
   - Userspace: 8% → 55% (shell binary compiles + runs + interactive).

   Multi-CPU stays at 5% (deferred). PQ stays at 0% (deferred). Overall mean projected ~40%.

8. **North-star observable is invoke-able by hand**: `qemu-system-x86_64 -kernel build/kernel.elf -serial mon:stdio ...` presents a live shell that accepts human input over stdin.

---

## 11. Open Architectural Questions (for user decision)

These are pillar-affecting decisions that R14B cannot silently make. Each requires user ratification before the referenced milestone opens.

### 11.1 §C amendment: Option 1 vs Option 2 (before M8)

Per r14-preflight §E and take-stock §2.2. osarch recommendation: **Option 1** (POSIX-style syscalls 13–16 for sys_open/close/read/write). Rationale in §2 of this plan under M8 note. **User approval needed to open M8.** If Option 2 chosen, milestone map amendments propagate to M19 (fd table → KIND_FILE cap-slot) and M8 issue count increases by ~2.

### 11.2 User binary base VA (before M7)

Recommended: **0x0000_0000_0040_0000** (4 MiB). Above null-page (traps NULL derefs at ring 3), below any kernel-owned low-VA identity map remnant (which is retired post-M2 anyway), aligned to 2 MiB huge-page boundary for future PS=1 mapping. **User approval needed to open M7.** Alternative candidates: 0x0000_0000_1000_0000 (256 MiB), 0x0000_1000_0000_0000 (arbitrary mid-range). Any low-half VA works; the pick is a convention.

### 11.3 IOAPIC bring-up vs PIC-legacy route for UART RX (before M16)

Recommended: **PIC-legacy route (IRQ4 → vector 0x24 with 8259 PIC in legacy config)**. Rationale: PIC is already mask-all today (r13-m4 landing); un-masking IRQ4 is a 2-line change. IOAPIC bring-up is a 4–6 issue milestone that is not on the R14B critical path (belongs to Path A / multicore per r14-kickoff). **User approval needed to open M16.** If IOAPIC preferred, M16 splits into M16a (IOAPIC bring-up) and M16b (RX ISR), adding ~4 issues.

### 11.4 Shell binary embedding vs separate file (before M7)

Recommended: **`.incbin` embed into kernel.elf**. Rationale: no bootloader multi-file support needed at R14B (PVH direct-boot is one file). Alternative (paideia-tar initrd) is a bigger lift that spans M20 tmpfs interaction. **User approval needed to open M7 detail.** Not pillar-affecting; softarch may decide.

### 11.5 Shutdown mechanism (before M25)

Recommended: **`isa-debug-exit` byte 0x10** (existing smoke convention). Rationale: keeps the boot_r17_shell smoke reliable; ACPI shutdown requires a real ACPI parser (deferred). Alternative: `outw 0x604, 0x2000` (QEMU-specific hardcoded ACPI shutdown port). Both work. **Softarch decides at M25 preflight.** Not pillar-affecting.

### 11.6 SMEP/SMAP/UMIP disposition at R14B (before M15)

Confirmed active per take-stock §1.2. `stac`/`clac` bracketing at M15/M18 is mandatory. **User approval needed** on whether R14B should also enable UMIP (Intel SDM Vol 3A §5.7.4 — User Mode Instruction Prevention). Recommend **enable UMIP** at R14B-α closure — it's a 1-instruction CR4 bit (bit 11) and it hardens against user-mode reads of GDT/LDT/IDT/TR via `sgdt`/`sldt`/`sidt`/`str` (Pillar 5, side-channel mitigation). No milestone impact if enabled at M5 side-work.

---

## 12. Design-only Work Streams (not milestone-gated)

These documents can be written at any time in R14B; they are inputs to milestones but not milestones themselves. Per r13-retrospective (e), design-doc-first landings reduce mid-round backtracking rate.

- `design/memory/higher-half-vma.md` — R14B-α inputs; write before M1.
- `design/capabilities/file-syscall-semantics.md` — M8 deliverable.
- `design/toolchain/elf-lite-spec.md` — M9 input; write before M7.
- `design/toolchain/user-linker-model.md` — M7 input; write before M7.
- `design/fs/tmpfs-layout.md` — M20 input.
- `design/fs/vfs-mount-model.md` — M21 input.
- `design/interrupts/user-mode-pf-delivery.md` — M12 input.
- `design/kernel/copy-to-from-user.md` — M15 input.
- `design/kernel/reaper-and-shutdown.md` — M25 input.
- `design/multicore/per-cpu-layout.md` — take-stock §2.5 recommends; not R14B-critical but write for R15+ Path A preflight.

None of these blocks a milestone directly, but a milestone that opens without its input document is at higher backtracking risk.

---

## 13. Pillar Alignment Audit

Per `feedback-pillar-alignment.md`, each strategic choice in this plan is tied to pillars:

| Choice | Pillars |
|---|---|
| Higher-half VMA first (R14B-α) | 3 (microkernel — canonical layout for cap-mediated user MM), 5 (memory-safety substrate for KPTI) |
| KPTI at M4 | 5 (Meltdown-class side-channel closure), 6 (defense-in-depth for future PQ crypto residency) |
| Ring-3 substrate before FS | 3 (drivers/FS in userspace requires ring-3 first), 10 (effect discipline meaningful only when isolation boundary exists) |
| §C Option 1 recommendation | 5 (fds as general typed handles, not POSIX obligation), 3 (simpler kernel TCB) |
| Single-CPU shell demo | 2 (deferred — pillar demonstration is Path A / R15+), 4 (deferred — proof obligation ties to real IPC scenarios) |
| No PQ, no semantic terminal at R14B | 6, 8 (deferred to R17-post per take-stock §2.6, §2.7 — not pillar violation, ordering constraint) |
| Effect + capability annotations on every function | 10 (mandatory, non-negotiable, already present) |
| Structural stubs allowed | 11 (research discipline: explicit deferral > hidden shortcut) |

**No pillar is silently violated in R14B.** Deferrals (Pillars 2, 4, 6, 7, 8) are explicit and ordered.

---

## 14. References and Bibliography

Per `feedback-references.md`, this section lists citations. Uncertain items are marked TODO.

### Verified references

- Intel® 64 and IA-32 Architectures Software Developer's Manual (Intel SDM), current revision. Vol. 3A §4.5 (page-table walk semantics + INVLPG), §4.7 (page-fault error code encoding, U/S bit), §5.6 (SMEP), §5.7.4 (UMIP), §5.10 (KPCID), §7.7 (task register + TSS).
- System V Application Binary Interface AMD64 Architecture Processor Supplement, current draft (Matz, Hubička, Jaeger, Mitchell). §3.4 (process initialization state, argc/argv layout on stack). TODO: verify current draft revision.
- Kaminsky, J., PVH boot ABI specification for Xen and QEMU. TODO: verify current document title and hosting URL.
- Liedtke, J. (1993). "Improving IPC by Kernel Design." SOSP '93. (Foundational microkernel IPC principles; used implicitly for Pillar 3 IPC design.)

### TODO: verify

- Gruss et al. (2017/2018) — the paper detailing KPTI/PTI mitigation of Meltdown. Two candidate references: "KAISER: Kernel Address Isolation to have Side-channels Efficiently Removed" (Gruss et al. ESSoS 2017) and "Meltdown" (Lipp et al. USENIX Security 2018). Both are relevant; verify which is the primary citation for KPTI design as opposed to KASLR bypass.
- Linux `arch/x86/mm/pti.c` documentation as reference for KPTI implementation model.
- Multics fd abstraction predating POSIX — cited as justification for §C Option 1 as non-POSIX-obligated design choice. Verify primary source (Corbato / Vyssotsky / Daley or Organick "The Multics System" 1972).

### External-standards references

- ELF-lite: PaideiaOS-internal subset. `design/toolchain/elf-lite-spec.md` is the authoritative spec (to be created at M9 side-work if not present).
- paideia-as encoder audit: `crates/paideia-as-encoder/src/` per commit ae6039b / v0.11.0+28. Anchor for §6.

---

## 15. Cross-references

- Take-stock report: `/home/snunez/Development/PaideiaOS/design/milestones/take-stock-2026-07-03.md`.
- R14 preflight: `/home/snunez/Development/PaideiaOS/design/milestones/r14-preflight.md`.
- R14 kickoff (Path A/B/C/D decision): `/home/snunez/Development/PaideiaOS/design/milestones/r14-kickoff.md`.
- R13 closure: `/home/snunez/Development/PaideiaOS/design/milestones/r13-closure.md`.
- R13 retrospective: `/home/snunez/Development/PaideiaOS/design/round-retrospectives/r13-shell-foundation.md`.
- Feature inventory (pillars + Tier-1 Critical): `/home/snunez/Development/PaideiaOS/design/00-feature-inventory.md`.
- Current syscall dispatcher: `/home/snunez/Development/PaideiaOS/src/kernel/core/syscall/dispatch.pdx`.
- Current user shell source: `/home/snunez/Development/PaideiaOS/src/user/shell.pdx`.
- Boot stub: `/home/snunez/Development/PaideiaOS/tools/boot_stub.S` (candidate for pvh_entry.pdx migration under paideia-as v1.5 32-bit round — see `project-paideia-as-32bit-mode-round.md`).

---

## 16. Trailer

**Author.** osarch, per user request 2026-07-04. This document is the strategic covenant; softarch will consolidate against this plan and file the corresponding GitHub issues per the current tempo.

**Status.** DRAFT — pending user + softarch review. On user ratification, this document becomes the R14B binding plan.

**Change-log discipline.** Any material amendment to §4 (milestone map) requires a new `design/milestones/r14b-master-plan-vN.md` snapshot and a NEWS entry in `STATUS.md`. Non-material amendments (typo fixes, added references) may be done in-place.

**Autonomous loop applicability.** Per `feedback_paideia_os_tempo.md`, paideia-os runs continuously across all R14B milestones; no per-milestone pause. Per `feedback_cross_repo_escalation.md`, encoder gaps escalate to paideia-as in-flight. Per `feedback_paideia_as_version_discipline.md`, submodule pin advances at phase closures (α → β → γ → ε) via workspace.version + tag + CHANGELOG entry together.

**End of R14B master plan.**
