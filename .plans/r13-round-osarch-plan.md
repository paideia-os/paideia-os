# PaideiaOS R13 round — Ring-3 userspace + interactive shell foundation

**Author:** osarch + softarch
**Date:** 2026-07-03
**Repo:** paideia-os/paideia-os (kernel; tools/paideia-as submodule pinned at ae6039b — v0.11.0-28)
**Companion repo:** paideia-os/paideia-as (workspace at /home/snunez/Development/paideia-as/)
**Predecessor:** R12 CLOSED (r12-closed tag, commit 54c464e)
**Reference plans:** `.plans/r12-round-osarch-plan.md`, `.plans/r11-round-osarch-plan.md`

## Round objective

Take paideia-os from a single-CPU ring-0-only kernel with observable cap dispatch (R12 close) to an **interactive shell session where a human at a terminal can type `help` or `cap N M` or `exit` and see the kernel respond**. This is the qualitative jump R13 delivers: paideia-os goes from "a kernel that prints things" to "an operating system a person can talk to."

The round scope redirects R12's kickoff sketch. R12 recommended Path A (multicore). The user's directive redirects R13 toward closing the gap to a proper shell session — multicore is deferred to R14.

## 0. Scope decision

Considered:

- **(A) Multicore bring-up** — R12 kickoff recommended path. Requires PA-R11-001..004 substrate (GS-relative mem, xchg, lock cmpxchg, mfence). **Deferred to R14** because it does not lead toward a shell session.
- **(B) Shell foundation (SELECTED)** — MM API activation + ring-3 GDT/TSS/IST + syscall entry + KIND_PROCESS/KIND_THREAD real handlers + user binary loader + shell fixture. Delivers observable typed-interaction. Scope: 10 milestones, 27 issues.
- **(C) MM API alone** — Insufficient. MM without ring-3 leaves no consumer to prove it.
- **(D) Handler-table A2 + remaining 8 cap kinds** — Extends R12's dispatch scaffold but does not advance toward a shell. **Deferred to R14+** as a quality item.

Decision: **B, shell foundation.** Justification against project pillars:

1. **Pillar 3 (microkernel).** Ring-3 enforces the syscall-only kernel boundary. Every user operation goes through cap_invoke_dispatch via SYS_CAP_INVOKE.
2. **Pillar 6 (security by construction).** Ring-3 makes cap-mediated access mandatory rather than convention. Rights lattice (R12) becomes user-facing.
3. **Pillar 10 (functional discipline).** Shell process is a pure loop: read → parse → dispatch → echo.
4. **Pillar 11 (research-driven).** Follows seL4's "userspace is where policy lives" discipline (Elphinstone 2013 §3).
5. **Substrate readiness.** 95% of R13 encoders present in paideia-as ae6039b (per softarch §"paideia-as substrate audit"). Only HARD blocker: `ltr r16` (PA-R13-001).

## 1. Scope boundary (what is NOT in R13)

- **Multicore.** Deferred to R14. `_current_tcb` remains single global. Per-CPU GS-relative reads use `[rip + _current_tcb]` fallback (PA-R13-002 optional).
- **Higher-half kernel VA.** Kernel VA stays lower-half (identity-mapped 4 GiB from boot_stub.S). Shell mapped at 0x40000000 (above kernel identity ceiling but still lower-half). Full higher-half discipline defers to R14.
- **Multi-process.** Single init/shell process only. No fork/exec. No process reaping. SYS_EXIT halts CPU.
- **Filesystem.** No VFS, no FS. Shell builtins are cap-invocations, not exec of external binaries.
- **Preemption between user processes.** Timer still fires (R11 preserved) but only kernel task_a/task_b are ring-0 tenants; the user shell runs cooperatively.
- **PCID / KPTI.** Deferred to R14.
- **Signals.** No signal delivery mechanism.
- **Real buddy allocator.** phys_alloc is a bump allocator over a static pool for R13. Buddy defers to R14.
- **Curried-call plumbing.** Same status as R12 (blocked on paideia-as Phase 20+).
- **Remaining 8 cap kinds** beyond PROCESS/THREAD (KIND_PAGE_TABLE partial coverage via loader use only).
- **Real MMIO through aspace_map for KIND_DEVICE.** R12's stubbed vaddr synthesis stays.

## 2. Pre-flight inventory

### 2.1 paideia-as ae6039b encoder surface for R13

Per softarch's grep of `crates/paideia-as-encoder/src/encode_instruction.rs`:

| Instruction | Status | R13 usage site |
|---|---|---|
| swapgs | present | m4 syscall entry, m7 sysretq path |
| syscall | present | m4 syscall trap encoding (kernel side) |
| sysretq | present | m4 sysret |
| wrmsr / rdmsr | present | m4 IA32_LSTAR/STAR/FMASK/KERNEL_GS_BASE setup |
| iretq | present | m7 first ring-3 entry, already used by every IDT trampoline |
| lgdt | present | m3 GDT install |
| lidt | present | already used |
| **ltr r16** | **MISSING** | **m3 TSS install — PA-R13-001 HARD blocker** |
| mov cr3, r64 / mov r64, cr3 | present | m2 aspace context switch |
| invlpg [mem] | present | m2 PT walker |
| hlt | present | m8 SYS_EXIT |
| GS-relative mem operand `mov r64, [gs:disp32]` | MISSING | Optional PA-R13-002; workaround via rip-relative |
| xchg [mem], reg / lock cmpxchg / mfence | MISSING | Not on R13 critical path (single-CPU); defer to R14 |

**Escalations:**
- **PA-R13-001 (HARD): `ltr r16` encoder.** Bytes: `0F 00 /1` (ModR/M reg-form). E.g., `ltr ax` = `0F 00 D8`. Blocks m3.
- **PA-R13-002 (SOFT): segment-override on memory operand.** Adds `segment: Option<SegReg>` to `Operand::MemSib`/`MemDisp`; emit `65` prefix for GS, `64` for FS. E.g., `mov rax, [gs:0]` = `65 48 8B 04 25 00 00 00 00`. Nice-to-have; R13 proceeds without via rip-relative reads.

### 2.2 paideia-os current state

- `kernel_main.pdx` ends at `call task_a_entry` (line 104). All boot at ring-0, CS=0x18.
- `boot/gdt.pdx` is stub; active GDT is 5-entry hand-encoded in `boot_stub.S` (no user selectors, no TSS).
- `boot/tss.pdx` does not exist.
- `core/mm/*.pdx` all MVP stubs (R12 conversion legacy). Real bodies land in m2.
- `core/int/idt.pdx` real; every trampoline hardcodes `KERNEL_CS = 0x08` — m3 layout preserves this at GDT slot 1.
- `core/int/ist.pdx` constants only. Stacks not allocated. m3 lands them.
- `core/sched/gs_current.pdx` scaffolded but inert. m4 activates.
- `src/user/` does not exist.

## 3. Milestone index

| # | Milestone slug | Issues | Description | On critical path |
|---|---|---|---|---|
| m1 | `r13-preflight-and-architecture` | 2 | Ring-3 ABI, syscall convention (syscall/sysret via IA32_LSTAR), MM invariants, TSS layout, embedded-shell binary format, file layout | yes |
| m2 | `r13-mm-api-activation` | 4 | Real aspace_map + 4-level PT walker + INVLPG; aspace_create real; phys_alloc bump allocator; aspace_unmap real | yes (parallel with m3-m6) |
| m3 | `r13-gdt-tss-ist` | 4 | Real GDT with user selectors + TSS descriptor; TSS.RSP0 setup; IST stacks (DF/NMI/MC/PF); IDT rewire with IST fields | yes (blocked on PA-R13-001) |
| m4 | `r13-syscall-entry` | 3 | IA32_LSTAR/STAR/FMASK/KERNEL_GS_BASE MSR setup; syscall entry trampoline (swapgs + stack switch + dispatch); SYS_CAP_INVOKE/READ/WRITE/EXIT table | yes |
| m5 | `r13-kind-process-thread` | 2 | KIND_PROCESS handler (OP_CREATE, OP_GET_ASPACE_ROOT); KIND_THREAD handler (OP_CREATE, OP_START) | yes |
| m6 | `r13-user-shell-binary` | 3 | src/user/shell.pdx (main loop); src/user/syscall_shim.pdx; src/user/{io,builtins}.pdx | yes (parallel with m3-m5) |
| m7 | `r13-kernel-user-transition` | 3 | User binary loader (embed shell.bin via .incbin); aspace layout; first iretq to ring-3 | yes |
| m8 | `r13-shell-interactive-loop` | 2 | Line-buffering with echo; builtin dispatch (help/cap/exit) | yes |
| m9 | `r13-smoke-fingerprint-regression` | 2 | boot_r13 mode + fingerprint; boot_r13_cap sub-mode | yes |
| m10 | `r13-closure` | 2 | r13-closure.md + STATUS update; retrospective + r14-kickoff.md | yes |
| **Σ** | | **27** | | |

## 4. Milestone details

### m1 — r13-preflight-and-architecture

**m1-001: Pre-flight audit** (S) — encoder verification (esp. PA-R13-001 ltr status), kind-name mapping for KIND_PROCESS (2) and KIND_THREAD (?), syscall table freeze (nr, args, return), MM invariants, TSS/IST layout, user aspace VA plan (0x40000000-0x40101000), embedded-shell-binary format (.incbin approach). Produces `design/milestones/r13-preflight.md`. Files: `design/milestones/r13-preflight.md`.

**m1-002: Architecture pins** (S) — GDT layout (8 entries + TSS), syscall MSR pins, ring-transition byte sequences, error-return convention, module file layout under `src/kernel/syscall/`, `src/user/`, `src/kernel/user/loader.pdx`. Produces `design/audit/entries/r13-m1-002-arch-pins.md`.

### m2 — r13-mm-api-activation

**m2-001: phys_alloc bump allocator** (S) — replace stub with bump over `.bss` `_phys_page_pool : [u8; 64 * 4096]`. Add `_phys_pool_next : u64 = 0` global. Return `&_phys_page_pool + next * 4096` on order=0, PHYS_ALLOC_NULL on exhaustion. Files: `src/kernel/core/mm/phys_alloc.pdx`, `src/kernel/core/mm/phys_pool.pdx` (new).

**m2-002: aspace_map + PT walker** (M) — real body per softarch §MM: compute PML4 index, load PT entry, allocate intermediate via phys_alloc on miss, descend PDPT→PD→PT, compose leaf PTE, invlpg. Files: `src/kernel/core/mm/aspace_map.pdx`.

**m2-003: aspace_create real body** (S) — bump-alloc PML4, copy kernel upper-half (PML4[256..512]) from kernel PML4 (identity map), return new PML4 phys base. Files: `src/kernel/core/mm/aspace_create.pdx`.

**m2-004: aspace_unmap + INVLPG discipline** (S) — walk PT to leaf, zero PTE, invlpg. Files: `src/kernel/core/mm/aspace_unmap.pdx`.

### m3 — r13-gdt-tss-ist (BLOCKED on PA-R13-001)

**m3-001: Real GDT install** (M) — replace boot_stub.S 5-entry GDT with 8-entry (null, kernel code64=0x08, kernel data=0x10, user data placeholder=0x18, user data=0x20, user code=0x28, TSS descriptor spanning 0x30-0x38). Slot 1 CS=0x08 preserved so existing IDT trampolines still fire correctly. `lgdt` reloads GDTR from kernel-side (kernel-mode). Files: `src/kernel/boot/gdt.pdx` (real body), `tools/boot_stub.S` (potentially trim old GDT if superseded).

**m3-002: TSS structure + RSP0** (S) — 104-byte `_tss : [u8; 104]` in .bss. Populate TSS.rsp0 (kernel stack top), TSS.ist1..3 (IST stack tops). `ltr 0x30` to load task register. **Depends on PA-R13-001.** Files: `src/kernel/boot/tss.pdx` (new).

**m3-003: IST stacks (DF, NMI, MC, PF)** (S) — 4 × 16 KiB stacks in .bss. Populate IST slots. Files: `src/kernel/core/int/ist.pdx` (populate real stack tops).

**m3-004: IDT rewire with IST fields** (S) — update `idt_install` in `idt.pdx` so gates for vec 8/2/18/14 encode IST != 0 in the type-attr byte. Files: `src/kernel/core/int/idt.pdx`.

### m4 — r13-syscall-entry

**m4-001: MSR setup (LSTAR/STAR/FMASK/KERNEL_GS_BASE)** (S) — write IA32_LSTAR (kernel entry point), IA32_STAR[47:32]=0x08 (kernel CS on entry), STAR[63:48]=0x18 (user CS/SS derived), IA32_FMASK=0x200 (mask IF on entry), IA32_KERNEL_GS_BASE (per-CPU pointer, unused today but set for future). Files: `src/kernel/core/syscall/msr_setup.pdx` (new).

**m4-002: Syscall entry trampoline** (M) — the ring-3→ring-0 entry point. On `syscall`: CPU auto-loads CS/SS from STAR, RIP from LSTAR, RFLAGS masked. Trampoline: `swapgs`; save user RSP; load kernel RSP (from GS or rip-relative); build stack frame; dispatch on RAX = nr; call handler; restore RSP via swapgs; sysretq. Files: `src/kernel/core/syscall/entry.pdx` (new).

**m4-003: Syscall table (SYS_CAP_INVOKE/WRITE/READ/EXIT)** (S) — nr=0 SYS_CAP_INVOKE → cap_invoke_dispatch; nr=1 SYS_WRITE (fd=1 → uart_puts_len); nr=2 SYS_READ (fd=0 → uart_getc blocking poll on LSR bit 0); nr=3 SYS_EXIT → cli;hlt loop. Table validation: `rax < 4`. Files: `src/kernel/core/syscall/table.pdx` (new), `src/kernel/boot/uart.pdx` (add uart_getc + uart_puts_len).

### m5 — r13-kind-process-thread

**m5-001: KIND_PROCESS handler** (S) — `cap_handler_process` in new `src/kernel/core/cap/kind_process.pdx`. Ops: OP_CREATE (create process = aspace_create + reserve TCB), OP_GET_ASPACE_ROOT (return current process's PML4). Rights: RIGHT_INVOKE required. Wire kind=2 into `cap_invoke_dispatch`. Files: `src/kernel/core/cap/kind_process.pdx` (new), `src/kernel/core/cap/invoke.pdx` (add kind=2 branch).

**m5-002: KIND_THREAD handler** (S) — `cap_handler_thread` in new `src/kernel/core/cap/kind_thread.pdx`. Ops: OP_CREATE (create thread inside process = TCB alloc), OP_START (context switch to thread). Rights: RIGHT_INVOKE required. Wire kind=? (find in kind.pdx). Files: `src/kernel/core/cap/kind_thread.pdx` (new), `src/kernel/core/cap/invoke.pdx` (add kind branch).

### m6 — r13-user-shell-binary

**m6-001: Shell main loop (src/user/shell.pdx)** (S) — `.text` entry; loop: prompt → getline → parse → dispatch → repeat. Files: `src/user/shell.pdx` (new).

**m6-002: Syscall shim (src/user/syscall_shim.pdx)** (S) — `pub let sys_read/sys_write/sys_exit/sys_cap_invoke` unsafe wrappers around `syscall` instruction. ABI: rax=nr, rdi/rsi/rdx=args. Files: `src/user/syscall_shim.pdx` (new).

**m6-003: I/O + builtins (src/user/io.pdx, src/user/builtins.pdx)** (S) — `getline(buf, cap)` echo-per-char, terminates on \n. Builtins: `help` (prints syscall list), `cap N M` (decimal parse, SYS_CAP_INVOKE, print RES=), `exit` (SYS_EXIT 0). Files: `src/user/io.pdx` (new), `src/user/builtins.pdx` (new).

### m7 — r13-kernel-user-transition

**m7-001: Embedded shell binary via .incbin** (S) — `objcopy -O binary build/shell.elf build/shell.bin` post-build. `tools/boot_stub.S` gains `.incbin "build/shell.bin"` with `_shell_bin_start`/`_shell_bin_end` labels. Files: `tools/boot_stub.S`, `tools/build.sh` (add objcopy step).

**m7-002: Loader (src/kernel/user/loader.pdx)** (M) — steps: aspace_create → phys_alloc pages → aspace_map(0x40000000, PTE_P|PTE_US) for text, (0x40001000, PTE_P|PTE_US|PTE_RW) for bss + stack → memcpy shell.bin → load CR3 → build iretq frame (SS=0x20|3, RSP=0x40101000, RFLAGS=0x202, CS=0x28|3, RIP=0x40000000) → iretq. Files: `src/kernel/user/loader.pdx` (new).

**m7-003: kernel_main_64 transition** (S) — call loader after `cap_dispatch_smoke`. Files: `src/kernel/boot/kernel_main.pdx`.

### m8 — r13-shell-interactive-loop

**m8-001: Line buffer + echo discipline** (S) — 64-byte line buffer in shell .bss. Backspace (0x7F) rubs out via `\b \b`. On overrun echo BEL. On \n terminate. Files: `src/user/io.pdx` (extend).

**m8-002: Builtin dispatch** (S) — strcmp against "help"/"cap"/"exit". Parse `cap N M` as decimal u64 tokens. Unknown → "unknown\n". Files: `src/user/builtins.pdx` (extend).

### m9 — r13-smoke-fingerprint-regression

**m9-001: boot_r13 mode + fingerprint** (S) — `tests/r13/expected-boot-r13.txt` ~15 lines contains-in-order. `boot_r13` mode in `tools/run-smoke.sh` piping `printf 'help\nexit\n'` to QEMU stdin. Fingerprint includes SHELL$ prompt, help output (SYS_CAP_INVOKE/WRITE/READ/EXIT lines), SHELL$, exit, SHELL EXITED. Files: `tests/r13/expected-boot-r13.txt` (new), `tools/run-smoke.sh` (add mode).

**m9-002: boot_r13_cap sub-mode + pre-push extension** (S) — `printf 'cap 4 1\nexit\n'` — asserts SYS_CAP_INVOKE round-trip through KIND_PAGE OP_READ, RES= line prints result. Update `.git/hooks/pre-push` to gate on 5 modes. Regression matrix (5 modes × 3 reps = 15 runs). Files: `tests/r13/expected-boot-r13-cap.txt` (new), `.git/hooks/pre-push`, `design/audit/entries/r13-m9-002-regression-matrix.md`.

### m10 — r13-closure

**m10-001: R13 closure document + STATUS update** (S) — `design/milestones/r13-closure.md` following R12 template. STATUS.md append. Files: `design/milestones/r13-closure.md` (new), `STATUS.md`.

**m10-002: Retrospective + R14 kickoff** (S) — `design/round-retrospectives/r13-shell-foundation.md` (~200 lines). R14 kickoff: Path A (multicore), Path B (higher-half kernel + KPTI), Path C (VFS + tmpfs), Path D (multi-process). Files: `design/round-retrospectives/r13-shell-foundation.md` (new), `design/milestones/r14-kickoff.md` (new).

## 5. Critical path

```
m1-001 → m1-002 →
  { m2-001 → m2-002 → m2-003 → m2-004 } (MM parallel)
  { m3-001 → m3-002 → m3-003 → m3-004 } (blocked on PA-R13-001)
  { m6-001 → m6-002 → m6-003 } (user shell parallel)
→ m4-001 → m4-002 → m4-003
→ m5-001 → m5-002
→ m7-001 → m7-002 → m7-003
→ m8-001 → m8-002
→ m9-001 → m9-002
→ m10-001 → m10-002
```

Length: 27 issues sequential worst-case; parallel bands compress to ~14.

## 6. Cross-repo escalations

| # | Escalation | Instruction | Probability | Priority |
|---|---|---|---|---|
| PA-R13-001 | ltr r16 encoder | 0F 00 /1 ModR/M reg-form | 100% needed | **HARD blocker for m3** |
| PA-R13-002 | Segment-override on mem operand | 65/64 prefix | 100% recommended | Soft; workaround via rip-relative |

Predicted paideia-as version at R13 close: v0.12.0 (post-PA-R13-001 landing). Submodule bump required.

## 7. Risk register

| # | Risk | Prob | Impact | Mitigation |
|---|---|---|---|---|
| R1 | PA-R13-001 (ltr) slips | medium | high | File first in m1; if paideia-as blocks >3 days, hand-encode `.byte 0x0F, 0x00, 0xD8` |
| R2 | First iretq triple-faults silently | high | high | Install #DF (vec 8) with IST1 + trace handler dumping CR2/errcode/RIP |
| R3 | Shell PT collides with kernel identity | low | high | Shell VA at 0x40000000 (above 4 GiB kernel ceiling) |
| R4 | QEMU stdin buffering | medium | medium | -chardev stdio,mux=off + stty -icanon; fallback: kernel-embedded hardcoded input |
| R5 | User stack overflow into kernel | medium | high | Bounds-check line buffer; user stack = 1 page; page fault handler treats as fatal |
| R6 | First syscall corner cases (RCX/R11 clobber, RFLAGS.IF discipline) | high | medium | m4-002 byte-verified sequence; test against QEMU register dump |
| R7 | phys_alloc bump exhaustion | low | medium | 64-page pool sufficient for R13 (single aspace ≤ 16 pages) |
| R8 | aspace_map recursion depth (4 levels) | low | medium | Explicit non-recursive walk with per-level state |
| R9 | Loader iretq frame incorrect | high | high | m7-002 byte-verify against Intel SDM Vol 3A §6.14 |
| R10 | Shell binary linking (paideia-as .o → binary blob) | medium | high | Test .incbin approach standalone in m1; fallback via linker script |

## 8. Cycle estimate

Per softarch: **22-28 cycles**. Distributed:
- m1: 2 cycles
- m2: 4 cycles (MM real bodies)
- m3: 4 cycles (blocked on PA-R13-001)
- m4: 3 cycles (syscall trampoline)
- m5: 2 cycles
- m6: 3 cycles (user shell)
- m7: 3 cycles (loader + iretq)
- m8: 2 cycles
- m9: 2 cycles
- m10: 1 cycle

Wallclock: ~14 working days if parallelization is exercised; ~22 if strictly sequential.

## 9. Round acceptance gate

R13 CLOSED when all hold:

1. `tools/run-smoke.sh boot_r13` passes (contains-in-order fingerprint, 15s timeout, 3/3 reps).
2. `tools/run-smoke.sh boot_r13_cap` passes — SYS_CAP_INVOKE round-trip verified.
3. `.git/hooks/pre-push` gates on 5 modes: boot_r8_only + boot_r10 + boot_r11 + boot_r12 + boot_r13.
4. `boot_r12_denial` still passes — R13 additions do not weaken R12 rights lattice.
5. `design/milestones/r13-closure.md` written.
6. `tools/paideia-as` submodule bumped to a tagged v0.12.0 containing PA-R13-001.
7. `design/milestones/r14-kickoff.md` exists with Path A/B/C/D sketches.
8. Tag `r13-closed` on merge commit.

**The observable payoff line:** a human at a terminal types `help<enter>exit<enter>` and sees the shell respond.

## 10. Milestone-by-milestone acceptance summary

Each milestone gets its own closing audit entry. Full audit chain expected: r13-preflight.md, r13-m1-002-arch-pins.md, r13-m2-001-phys-alloc.md, r13-m2-002-aspace-map.md, r13-m2-003-aspace-create.md, r13-m2-004-aspace-unmap.md, r13-m3-001-gdt.md, r13-m3-002-tss.md, r13-m3-003-ist.md, r13-m3-004-idt-rewire.md, r13-m4-001-msr-setup.md, r13-m4-002-syscall-entry.md, r13-m4-003-syscall-table.md, r13-m5-001-kind-process.md, r13-m5-002-kind-thread.md, r13-m6-001-shell-loop.md, r13-m6-002-syscall-shim.md, r13-m6-003-io-builtins.md, r13-m7-001-embed-binary.md, r13-m7-002-loader.md, r13-m7-003-transition.md, r13-m8-001-line-buffer.md, r13-m8-002-builtin-dispatch.md, r13-m9-001-boot-r13-fingerprint.md, r13-m9-002-regression-matrix.md, r13-m10-001-closure.md, r13-m10-002-retrospective.md.

**End of round plan.**
