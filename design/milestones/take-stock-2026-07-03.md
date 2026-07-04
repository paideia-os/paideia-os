# PaideiaOS Take-Stock Report — 2026-07-03

**Vantage point:** R13 closed at tag `r13-closed` (commit b0868d1). R14 preflight (m1-001, #487) and three carryover items (m2-001 cap_smoke migration #482, m2-002 real KIND_PROCESS backfill #430, m2-003 aspace_map huge-page detection #488) have landed on top. HEAD = a049b87. Six open issues remain: #424 (TSS+`ltr`, blocked on paideia-as #914), #481/#483/#484/#485/#486 (deferral records).

**Scope of report:** Strategic architecture review, no code changes. Enumerates subsystem completion honestly; identifies deviations from the pillars in `MEMORY.md > project_paideiaos_vision.md` and the R13 round plan; and answers the "depth vs scaffolding" question.

**No overclaiming.** Structural stubs are counted as structural stubs, not as landed handlers, even where the audit-writing pattern is uniform with real landings. Where a percentage looks low, that is the honest ratio of what exists against a clean-slate x86_64-asm microkernel OS at Skylake-X/Ice-Lake feature level per `design/00-feature-inventory.md`.

---

## Section 1: Progress percent per subsystem

Ratios are against the eventual clean-slate OS goal, not against R13 or R14 scope. Anchors: `design/00-feature-inventory.md` (Tier-1 Critical C1–C18), pillars 1–11.

### 1.1 Boot (PVH entry, GDT, protected→long, kernel image)

**State.** PVH boot stub (`tools/boot_stub.S`, 145 lines) sets PML4, PDPT (four 1 GiB huge pages covering the low 4 GiB), long-mode via CR4.PAE + IA32_EFER.LME + CR0.PG, ljmp into 64-bit code. Kernel `_start` receives control at low identity-mapped VA. Real 8-slot GDT installed by kernel (`src/kernel/boot/gdt.pdx`, 109 lines) with SYSRET-compatible layout (STAR[47:32] = 0x0018). `banner.pdx` outputs `PaideiaOS R8` on COM1. Second-stage kernel image is statically linked (0 relocations per r14-preflight §B).

**Missing against C1 (feature-inventory).** UEFI boot path entirely absent — no `GetMemoryMap`, no ACPI RSDP discovery, no GOP init, no ExitBootServices. TPM PCR extension for measured boot absent. Multiboot-legacy explicitly excluded per Pillar 5, but the replacement (UEFI + measured handoff) has zero code. Kernel image is loaded by QEMU-PVH directly to 0x100000; no bootloader flow beyond `boot_stub.S`.

**Percent complete: 25%.** Working PVH → long-mode transition + real GDT is real substrate; UEFI + measured boot + typed handoff (all critical per pillar 6) is nowhere.

### 1.2 Memory management

**State.** `src/kernel/core/mm/` at 28 files, 1136 lines. Real pieces:
- `phys_alloc.pdx` (62 lines) — bump allocator over 1024-page static pool (r13-m2-001, #419; pool grown from 64 to 1024 in m2-005 wrap).
- `aspace_map.pdx` (184 lines) — real 4-level PT walker with 9-bit index extraction, INVLPG per Intel SDM Vol 3A §4.5. Huge-page detection landed r14-m2-003 (#488): PS=1 at PDPT/PD returns `MAP_HUGE` (0xFFFFFFFD) instead of clobbering boot huge pages.
- `aspace_create.pdx` (94 lines) — upper-half PGD copy + CR3 composition (PML4 | PCID | no-flush).
- `aspace_unmap.pdx` (121 lines) — per-CPU shootdown mailbox bookkeeping (mailbox not multi-CPU active).
- `smep.pdx` (39 lines), `smap.pdx` (40 lines), `nx.pdx` (42 lines) — CR4.20/21 + IA32_EFER.NXE set with CPUID guards.

**Stubs / not real.**
- `buddy.pdx` (97 lines) — interface parking; returns `BUDDY_NULL` for orders 1..10 (r13-m2-005, #444).
- `magazine.pdx` (89 lines), `numa_magazine.pdx`, `numa_free.pdx`, `pcid.pdx`, `pt_reclaim.pdx`, `pf_handler.pdx`, `panic_trace.pdx`, `reserve.pdx`, `cap_numa_migration.pdx`, `phys_free.pdx` — thin stubs / interface parking only.
- `kpti.pdx` (46 lines) — `aspace_create_user_pgd` returns sentinel `ASPACE_CREATE_NOT_YET = 0xFFFFFFFE`; no real KPTI CR3 flip.
- `aspace_map_2m.pdx` (12 lines) — stub.

**Missing against C2/C3/C10.** NUMA topology discovery (MADT-driven) not wired. Per-node buddy free-list heads absent. Higher-half kernel VMA not yet installed (Phase-1 PML4[256] alias only; Phase-2 relocation to 0xFFFF_8000_0010_0000 is #480, R14 Path B). Page-fault-driven pager protocol (Pillar 3, C13) absent. No 5-level paging support. No PCID activation. No huge-page splitting (Option B in r14-m2-003 audit, not landed).

**Percent complete: 22%.** Walker safety is real. Everything above the walker (buddy, magazine, NUMA, KPTI, higher-half) is scaffolding or absent.

### 1.3 Interrupts / traps

**State.** `src/kernel/core/int/` and `src/kernel/core/apic/` and `src/kernel/core/timer/`.
- `idt.pdx` (411 lines) — real 256-entry IDT with per-vector packing loop + real `lidt`.
- `exceptions.pdx` (222 lines) — handlers for vectors 0, 3, 6, 8, 13, 14 (divide, breakpoint, invalid-op, double-fault, GP, PF); CR2 read for PF; trace-then-halt semantics.
- `ist.pdx` (87 lines) — IST stacks in `.bss` for DF/NMI/MC (r13-m4-003, #425).
- `idt.pdx` also carries the r13-m4-004 IST-field rewire for vectors 2/8/14/18.
- `apic/enable.pdx` (41), `apic/lapic_timer.pdx` (116), `apic/eoi.pdx` (41), `apic/pic_mask.pdx` (50) — LAPIC enable, TSC-deadline timer init, EOI, PIC mask-all.
- `timer/lapic_isr.pdx` (140), `timer/wheel.pdx` (51), `timer/timer_add.pdx` (49) — timer ISR body, wheel scaffolding, timer_add plumbing.

**Missing.** IOAPIC (`apic/ioapic.pdx`, 46 lines) is a stub — no real GSI routing. MSI/MSI-X (`apic/msi.pdx`, 46 lines) is a stub. x2APIC (`apic/x2apic.pdx`, 33 lines) is a stub. Cross-CPU IPI (`ipi/cross_cpu.pdx`, 53 lines; `ipi/tlb_shootdown.pdx`, 96 lines; `ipi/resched.pdx`, 47 lines) — files exist but are single-CPU stubs; no observable IPI issue at R13 without AP bootstrap. User-space IRQ delivery via KIND_INTERRUPT / notification is structural stub only (r13-m6-006).

**Percent complete: 40%.** BSP interrupt path is real end-to-end (IDT + LAPIC + timer + exception handlers + IST). Cross-CPU + IOAPIC + user-space IRQ routing is scaffolding.

### 1.4 Syscall entry

**State.** `src/kernel/core/syscall/` — five files, 216 lines.
- `msr.pdx` (69 lines) — writes IA32_EFER.SCE, IA32_STAR = 0x0018000800000000, IA32_LSTAR = `&syscall_entry`, IA32_FMASK = 0x47700 (Linux SYSCALL_MASK: TF|IF|DF|IOPL|NT|AC), IA32_KERNEL_GS_BASE = `&_cpu0_kernel_gs` (r13-m5-001, #427).
- `entry.pdx` (56 lines) — real SYSCALL trampoline: save user RSP → load kernel RSP → push rcx/r11/rax → shuffle SYSCALL-ABI → SysV C-ABI (`rax→rdi, rdi→rsi, rsi→rdx, rdx→rcx, r10→r8`) → call dispatch → sysret (r13-m5-002, #428).
- `dispatch.pdx` (58 lines) — 13-entry linear cmp/je chain per preflight §C. 3 real handlers wired: `sys_yield` (1, tail-calls `sched_yield`), `sys_cap_invoke` (4, tail-calls `cap_invoke` after arg shuffle), `sys_debug_puts` (12, calls `uart_puts`). 10 return ENOSYS (0xFFFFFFFFFFFFFFDA).
- `table.pdx` (21 lines) — `SYS_NR = 13` frozen per §C.
- `kernel_stack.pdx` (12 lines) — single 16 KiB stack, BSP-only.

**Missing.** No `swapgs` on entry/exit (single-CPU pin per r13-m1-002). No KPTI CR3 flip (kpti stub only). No user-RSP validation. No signal-frame push (sys_signal_register/return are ENOSYS pending Rev-2 m11). Table entries 0, 2, 3, 5–11 are ENOSYS. Most importantly: **the entire syscall path is dead code — no ring-3 caller ever reaches it at R13.** Reachability lands in R14 with real ring-3.

**Percent complete: 30%.** Trampoline is real substrate; three real handlers exist; the whole path is unreached at runtime.

### 1.5 Capabilities

**State.** `src/kernel/core/cap/` at 34 files, 2611 lines — the largest and most-worked subsystem.

Real per-kind handlers landed with byte-verified bodies:

| Kind | Handler | Round |
|---|---|---|
| KIND_PAGE (4) | `kind_page.pdx` OP_READ/WRITE | R12-m3-001 |
| KIND_SCHED_CTX (7) | `kind_sched.pdx` OP_YIELD | R12-m3-002 |
| KIND_IPC_ENDPOINT (5) | `kind_ipc.pdx` OP_SEND/RECV | R12-m4-001 |
| KIND_DEVICE (10) | `kind_dev.pdx` OP_MAP_MMIO | R12-m4-002 |
| KIND_THREAD (2) | `kind_thread.pdx` OP_CREATE/START | R13-m6-002 |
| KIND_IPC_PORT | `kind_ipc_port.pdx` OP_SEND/RECV | R13-m6-004 |
| KIND_TIMER | `kind_timer.pdx` OP_ARM/CANCEL/READ_TSC | R13-m6-005 |
| KIND_NOTIFICATION | `kind_notification.pdx` OP_SIGNAL/WAIT/POLL | R13-m6-006 |
| KIND_REPLY | `kind_reply.pdx` OP_REPLY/STATUS | R13-m6-007 |
| KIND_PROCESS (1) | `kind_process.pdx` OP_CREATE/GET_ASPACE_ROOT | R14-m2-002 (backfill of r13-m6-001) |

That is 10 kinds with real bodies. `cap_mint`, `cap_verify`, `cap_invoke_dispatch` are real. Rights lattice is enforced per-handler (B1 style); `boot_r12_denial` mode witnesses `CAP DENIED` on OP_WRITE against a read-only KIND_PAGE cap.

**Structural stubs (pool + offsets pinned; not in dispatch chain).**
- KIND_PAGE_TABLE (3) — `kind_page_table.pdx`, r13-m6-003 / #451. Op-code constants only. Blocked on args-encoding decision.
- KIND_INTERRUPT — bundled into r13-m6-006 / #454. `_irq_notification_map[256]` design pending.

**Missing.** Handler-table (A2) dispatch — still linear cmp/je (adequate at 10-way, R15+ target per R12 boundary #7). Generation-based revocation validation not wired into dispatch path — `descriptor.generation` field exists (`cap/generation.pdx`) but is not checked. Sealed capabilities absent. Kind-specific rights lattice (high 32 bits) unused. Persistent audit-log absent (COM1 tags only).

**Percent complete: 60%.** This is the deepest subsystem. 10 real handlers + rights enforcement + denial witness is real functionality. What is missing is: revocation-in-dispatch, sealed caps, handler-table migration, cross-process cap delegation (blocked on ring-3).

### 1.6 Scheduler

**State.** `src/kernel/core/sched/` at 22 files.
- `tcb.pdx` — 184-byte TCB layout, byte offsets pinned.
- `runqueue.pdx`, `pick_next.pdx`, `priority_bitmap.pdx` — 16-level bitmap runqueue, BSR-equivalent pick.
- `switch.pdx`, `frame.pdx`, `preempt.pdx` — real callee-saved save/restore (r10-m3-001), sched_preempt_to (r11-m3-001), preempt-aware trampoline_vec32 epilogue (r11-m4-001).
- `yield.pdx`, `budget.pdx`, `tasks.pdx`, `tasks_r11.pdx` — Task A/B entry bodies, per-TCB budget (default 1M cycles).

**Observable proof.** `boot_r10` shows `TASK A / TASK B / TASK A / TASK B` cooperative alternation. `boot_r11` shows a softer 3-alternation preemptive signature (QEMU TCG is deterministic — real preemption at wall-clock intervals requires KVM or hardware).

**Missing.** Multi-CPU per-CPU runqueue absent (`gs_current.pdx` exists but GS-relative addressing is blocked on PA-R14-001). Work-stealing not implemented. Real time-slice at variable ns absent. `sched_pick_next` is priority-only, no CFS/EEVDF-style fair scheduling. Sleep queues absent. Wake-block (`wake_block.pdx`) is a stub.

**Percent complete: 40%.** Single-CPU cooperative + budget-driven preemption real; multicore + fair scheduling nowhere.

### 1.7 IPC

**State.** `src/kernel/core/ipc/` (11 files) plus 4 KIND_IPC_* cap handlers.
- `channel.pdx`, `channel_create.pdx`, `enqueue.pdx`, `dequeue.pdx` — real SPSC ring for KIND_IPC_ENDPOINT (64-slot pool, single ring); `ipc_smoke` witnesses `IPC OK` at boot.
- `port.pdx`, `slots.pdx` — KIND_IPC_PORT (r13-m6-004, #452): point-to-point single-slot pool; WOULD_BLOCK on full-SEND / empty-RECV.
- `mpsc_lock.pdx` — stub (blocked on lock cmpxchg encoder PA-R13-012).
- `allocator.pdx`, `destroy_channel.pdx` — thin.

**Companion cap layers.**
- KIND_NOTIFICATION (r13-m6-006) — counting semaphore + LWW payload; 64 × 16B pool.
- KIND_REPLY (r13-m6-007) — one-shot RPC reply cap; consumed-flag + payload; sufficient for m11 SIGCHLD design.

**Missing.** Multi-channel scheduling / priority. Formal deadlock-freedom argument (Pillar 4) exists as design doc only (r5-5 audit), not tied to a proof obligation on the running code. Cross-process IPC witness (requires ring-3). NUMA-local channel allocation stub. MPSC lock is a stub — blocks any multi-producer channel.

**Percent complete: 40%.** Four cap-mediated primitives are real; kernel-side single-consumer path works; nothing runs across processes because ring-3 doesn't exist yet.

### 1.8 Security controls

**State.** SMEP + SMAP + NX activated with CPUID guards at boot. Real 8-slot GDT with SYSRET-compatible layout. IST stacks + IST rewire for DF/NMI/MC/PF. Cap rights lattice enforced per-handler (`boot_r12_denial` witness). Effect + capability annotations `!{...} @{...}` on every kernel function (Pillar 10 discipline; paideia-as compiler enforces).

**Missing (critical against C10, C11, C15, pillar 6).**
- KPTI — stub only (`aspace_create_user_pgd` returns ASPACE_CREATE_NOT_YET).
- CET (IBT + shadow stack) — zero code.
- MPK/PKU — zero code.
- Ring separation — GDT slots exist (user CS=0x28, user SS=0x20) but no ring-3 code runs; SMEP/SMAP untested against ring-3 fetch/access.
- Measured boot / TPM 2.0 (C11) — zero code.
- RDRAND/RDSEED entropy plumbing (C15) — zero code.
- Post-quantum crypto — zero code (ML-KEM / ML-DSA / SLH-DSA per pillar 6 not touched). Grep for `ml_kem|ml_dsa|kyber|dilithium|sha3|rdrand|rdseed` in `src/` returns only SARIF metadata from paideia-as toolchain signing — nothing in kernel/user source.

**Percent complete: 18%.** SMEP/SMAP/NX + GDT/IST/cap-rights is a real substrate; KPTI + CET + PKU + measured boot + PQ are absent.

### 1.9 Userspace

**State.** `src/user/` at 4 files, 154 lines.
- `shell.pdx` (39) — straight-line `_start` (banner → prompt → help → dispatch_cap → exit). §C-native. No interactive loop.
- `syscall_shim.pdx` (56) — 4 wrappers matching §C: sys_exit_thread (0), sys_yield (1), sys_cap_invoke (4), sys_debug_puts (12).
- `io.pdx` (16), `builtins.pdx` (43) — `puts` (wraps sys_debug_puts), `builtin_help`, `builtin_exit`, `dispatch_cap`.

**Reality.** `tools/build.sh` globs only `src/kernel/`. No `build-user.sh`. No user linker script. No `shell.bin` produced. No `.incbin` into `kernel.elf`. No ELF-lite loader. **Ring-3 has never executed at R13.** The R13 closure calls this correctly: "This code compiles nowhere in R13 ... but it is a §C-native, straight-line demonstrative main and it pins the user-side ABI for R14."

**Percent complete: 8%.** Source shape exists; nothing runs.

### 1.10 Multi-CPU

**State.** `src/kernel/core/ipi/` has three files: `cross_cpu.pdx` (53 lines), `resched.pdx` (47 lines), `tlb_shootdown.pdx` (96 lines) — all single-CPU stubs. `sched/gs_current.pdx` scaffolds per-CPU-via-GS but the GS-relative addressing encoder (`mov r64, [gs:offset]`) is absent from paideia-as (PA-R14-001, #926, filed 2026-07-03 per r14-preflight §F).

**Missing.** SIPI (Startup IPI) to wake APs. AP bootstrap trampoline. Per-CPU struct instantiation ×MAX_CPUS. Per-CPU runqueue replication. Real IPI vector routing. TLB shootdown ack cycle. Cross-CPU cap-table generation counter. All of these are Path A in `r14-kickoff.md`.

**Multicore-first pillar (Pillar 2) reality.** The pillar says "no big kernel lock phase ever exists." R13's discipline instead documented single-CPU as an R13 data race that is unreachable while the trampoline is unreachable (r13-m5-002 justification). This is not a violation of the pillar's letter (there is no big kernel lock; there is only one CPU), but it is a deferral of the pillar's demonstration. R14 Path A is where the demonstration lands.

**Percent complete: 5%.** IPI stubs exist. Nothing else.

### 1.11 Filesystem

**State.** No VFS. No tmpfs. No file descriptor table. No block-device driver. No ELF loader. Grep for `vfs|tmpfs|fd_table|blkdev|filesystem|VFS` in `src/` returns nothing.

**Deferral records.** #485 (Rev-2 m9 VFS bundle, deferred), #486 (Rev-2 m10 fork/exec/wait bundle, deferred and blocked on PA-R13-012 for spinlocks).

**Missing.** Everything. The §C amendment for `sys_open/close/read/write` (r14-preflight §E) is still PENDING — recommendation for Option 1 (POSIX-style) is preliminary and unresolved.

**Percent complete: 0%.** No code.

### 1.12 Process management

**State.**
- KIND_PROCESS real handler landed in R14-m2-002 backfill (`kind_process.pdx`, 95 lines). OP_CREATE allocates slot, calls `aspace_create(&pml4)`, writes {aspace_root, pid, parent_pid=0, state=RUNNING}, bumps `_next_pid`, returns pid. OP_GET_ASPACE_ROOT extracts pid from op_arg[63:8], returns aspace_root or 0.
- `process/process_init.pdx` (19 lines), `process/process.pdx` (25 lines) — bootstrap sets `_next_pid[0]=1` and `_next_tid[0]=1`.
- 64-slot process pool at 32 bytes/slot.

**Missing.** No `fork`. No `exec`. No `wait` (KIND_REPLY exists as the substrate — see 1.7 — but no wait wrapper). No SIGCHLD (Rev-2 m11, deferred). No process teardown / cleanup. No PID reuse. `_next_pid` monotonically increases with no reclaim. Handler-side: `parent_pid=0` is written unconditionally — no parent tracking.

**Percent complete: 12%.** KIND_PROCESS handler is real and boot-time-callable; nothing above it exists.

### 1.13 Terminal / shell

**State.** COM1 UART TX real: `uart_init`, `uart_putc`, `uart_puts` in `src/kernel/boot/uart.pdx` (99 lines). Boot banner + all runtime tags (CAP OK, IPC OK, CAP INVOKE MEM/IPC/SCHED/DEV, IDT OK, TASK A/B) emit via this path. Ring-3 shell source exists (see 1.9) but does not run.

**Missing.**
- UART RX (`uart_getc`) — grep for `uart_getc|uart_rx|uart_input|sys_read|getline|readline` in `src/` returns only source files that mention these as absent/deferred. There is no line editing, no interrupt-driven RX, no polling loop.
- Interactive shell — impossible by design at R13 (no `sys_read` in §C; #483).
- Semantic shell (Pillar 8) — design docs only (`design/terminal/`: 14 files including `semantic-shell.md`, `datalog-spec.md`, `pds-format.md`, `wire-format.md`, `kitty-dialect.md`, `command-registry.md`). Zero runtime code.

**Percent complete: 8%.** TX exists; RX doesn't; semantic layer is design-only.

### 1.14 Cross-repo tooling

**State.** `tools/paideia-as` submodule pinned at ae6039b / v0.11.0+28 (STATUS.md; r14-preflight header says fe2293b / +PA-R9-002+003 — the two are consistent since fe2293b lives on the paideia-as CHANGELOG track above ae6039b, and the working tree currently shows the ae6039b tag).

**Open escalations (paideia-as `PA-R*` label):**

| Issue | Escalation | R14 impact |
|---|---|---|
| #914 | PA-R13-001 `ltr r16` | blocks #424 TSS install → gates ring-3 exception delivery |
| #915 | PA-R13-002 gs-relative memory operand | blocks per-CPU addressing (Path A) — duplicate of #926 filing |
| #916 | PA-R13-003 `xchg [mem], reg` | blocks spinlocks (Path A + fork under multicore) |
| #917 | PA-R13-004 `lock cmpxchg` | blocks atomics |
| #918 | PA-R13-005 `mfence` | blocks TLB shootdown ordering |
| #919 | PA-R13-006 CR4 write variants | soft; SMEP/SMAP already landed via existing form |
| #920 | PA-R13-007 fxsave/fxrstor | blocks FP save/restore (C17) |
| #921 | PA-R13-008 `pub let mut` .rodata bug | governance/emit issue |
| #923 | PA-R13-010 SUB r64, imm | workaround `add r, 0xFF...FF` used in kind_process |
| #924 | PA-R13-011 back-to-back labels | workaround duplicate-block used |
| #925 | PA-R13-012 `xchg` / `lock cmpxchg` / `lock` prefix (bundle) | HARD blocker for Rev-2 m10 + m13 |
| #926 | PA-R14-001 GS-relative memory operand | HARD blocker for Path A per-CPU dispatch (filed 2026-07-03 per r14-preflight §F) |

**Build discipline.** `tools/build.sh` compiles `src/kernel/*.pdx` per PA calling conventions. `tools/find-paideia-as.sh` enforces strict submodule pinning. No CI/CD in paideia-os per `feedback_paideia_os_no_cicd.md`; verification is local via `tools/run-smoke.sh` + pre-push hook (4 modes: boot_r8_only, boot_r10, boot_r11, boot_r12).

**Percent complete: 55%.** Encoder coverage is adequate for ring-0 kernel work up to R13. It is NOT adequate for multicore (missing gs-relative + atomics + mfence), FP context (missing fxsave), or interactive shell w/o §C amendment. paideia-as v0.12.0 bundle (PA-R13-001 + 010 + 011 + 012 + PA-R14-001) is the substrate pathway.

---

### Rollup

| Subsystem | % |
|---|---|
| Boot | 25 |
| Memory management | 22 |
| Interrupts / traps | 40 |
| Syscall entry | 30 |
| Capabilities | 60 |
| Scheduler | 40 |
| IPC | 40 |
| Security controls | 18 |
| Userspace | 8 |
| Multi-CPU | 5 |
| Filesystem | 0 |
| Process management | 12 |
| Terminal / shell | 8 |
| Cross-repo tooling | 55 |

**Unweighted mean: ~26%.** Capability system is the deepest subsystem. Filesystem, userspace-execution, multi-CPU, semantic shell, and the entire pillar-6 security stack (KPTI, CET, PKU, measured boot, PQ crypto) are the largest gaps.

---

## Section 2: Deviations from original specification + corrective plan

Anchors: `MEMORY.md > project_paideiaos_vision.md` ("clean-slate x86_64-asm microkernel OS, multicore-first, post-quantum, FP-disciplined, semantically-queryable terminal") plus the 11 pillars in `design/00-feature-inventory.md > §0 Preamble`.

### 2.1 R13 scope collapse (headline: userspace+shell → substrate landing)

**Spec.** `.plans/r13-round-osarch-plan.md` Rev-2 scoped R13 as "userspace + full-featured OS with shell, VFS, fork/exec, signals, multicore". Observable target: `PaideiaOS shell v0.1\n$ ` on COM1 from ring-3.

**Reality.** Cap-dispatch surface extended from 4 kinds to 10 real + 2 structural. SYSCALL/SYSRET fast path built end-to-end but unreached at runtime. MMU-hardening perimeter set (SMEP/SMAP/NX + real GDT + IST). User-space source tree exists at `src/user/` but does not compile into any binary. Ring-3 was NEVER reached.

**Root cause.** Four dependencies were invisible at R13 kickoff and stacked serially only when R13.M8 tried to reach ring-3:
1. `aspace_map` huge-page collision (boot huge pages in PML4[0]/PML4[256] would be clobbered by 4 KiB walker descent).
2. TSS + `ltr` requires paideia-as `ltr r16` encoder (PA-R13-001, #914).
3. User linker + `tools/build-user.sh` discipline — `build.sh` globs `src/kernel/` only.
4. `cap_smoke` fixture coupling to `kind=1` — real KIND_PROCESS handler returning fresh pid breaks R8 slot-0 assertion.

Straight-order: (1) → (2) → (3) → functional (4).

**Corrective plan.**
- **Landed:** aspace_map huge-page detection at r14-m2-003 (#488). `cap_smoke` migration at r14-m2-001 (#482). Real KIND_PROCESS handler at r14-m2-002 (backfill of #430).
- **Open:** #424 TSS+`ltr` still blocked on paideia-as #914; wait for paideia-as v0.12.0 bundle.
- **Process fix:** Adopt the r13-retrospective (k)(e) recommendation — preflight-M0.5 "reachability audit" tracing the round's headline observable back through every touched subsystem, and file all blockers before M1 opens. This would have caught the huge-page walker + `cap_smoke` coupling; the TSS blocker (already in PA-R13-001) and user-linker discipline gap would still have shown up but earlier.

### 2.2 §C syscall table drift (POSIX-flavored issue bodies vs preflight §C native names)

**Spec.** Preflight §C froze a 13-entry §C-native syscall table (sys_exit_thread, sys_yield, sys_ipc_send, sys_ipc_recv, sys_cap_invoke, sys_cap_mint, sys_cap_query, sys_signal_register, sys_signal_return, sys_cpu_id, sys_sipi_target, sys_kpti_enable, sys_debug_puts). No POSIX shim, no `sys_read`, no `sys_write`, no `sys_open`.

**Reality.** Issue bodies for m5-003 (#429, syscall table build-out) and m7 (#432/#433/#434, shell) referenced sys_read / sys_write / sys_exit. Backtracking #481 and #483 record the reconciliation. §C won. But the design consequence is that the R13 shell cannot be interactive — no `sys_read` means no line editing. r14-preflight §E now surfaces two options (POSIX-style syscalls 13–16 vs capability-based file slots via KIND_IPC_PORT) and defers the decision to R14-m2 planning.

**Root cause.** Issue-body authoring pre-dated §C freeze and was not re-audited against §C before it entered the sprint queue. Two backtracking records (#481 + #483) surfaced this within a single round.

**Corrective plan.**
- **Governance:** Adopt r13-retrospective lesson (a) — every issue body must post-date preflight §C freeze OR be re-audited against §C before it enters the sprint queue. This precedent is process-load-bearing for R14+.
- **Table amendment:** R14-m2 planning must choose between Option 1 (add sys_open/close/read/write at IDs 13–16) and Option 2 (cap-based file slots via KIND_IPC_PORT semantic overload). Preliminary architect recommendation in r14-preflight §E is Option 1 for simplicity + POSIX familiarity at the user-space boundary. Note that Option 2 aligns better with Pillar 3 (strict microkernel) + Pillar 6 (cap-mediated access control) but adds semantic overloading complexity to KIND_IPC_PORT. **This is an open architectural decision, not resolved yet.**
- **Consequence for R14 headline:** Whichever option is chosen, an interactive shell requires it. The `sys_read` question sits upstream of a "PaideiaOS shell v0.1\n$ " observable and cannot be side-stepped by a workaround at R14 scope. Recommend concluding the decision at R14-M1 side-work so R14-M2 tmpfs planning has a stable target.

### 2.3 KIND_PAGE_TABLE / KIND_INTERRUPT structural stubs (softarch-approved R14 deferrals)

**Spec.** Preflight §B enumerated 16 kinds including KIND_PAGE_TABLE (3) and KIND_INTERRUPT. R13 plan §4 listed real handlers for both.

**Reality.** Both landed as structural stubs — pool declarations and byte offsets pinned; no dispatch chain wire-up; no handler body.
- KIND_PAGE_TABLE (r13-m6-003, #451): four blockers — args-encoding (3 addresses cannot pack into one `op_arg` u64), current-aspace API absent, huge-page walker collision (now fixed at r14-m2-003), no user-space minter.
- KIND_INTERRUPT (bundled into r13-m6-006, #454): `_irq_notification_map[256]` design pending; ISR-side notification post inside `src/kernel/core/int/` not designed; userspace-visible EOI path not spec'd.

**Root cause.** Both are downstream of design decisions that R13 did not resolve. Structural stubs are the honest landing category (r13-retrospective lesson (c)) — they pin the data model without wiring dispatch, so R14 handler landings are additive rather than exploratory.

**Corrective plan.**
- KIND_PAGE_TABLE — R14-M4 or later, after huge-page fix (done), higher-half kernel VMA (R14 Path B), and args-encoding decision (either extend `cap_invoke_dispatch` ABI to take an aux register — likely r10 or r11 — or route through a memory-region cap indirection).
- KIND_INTERRUPT — R14 after `_irq_notification_map[256]` design in `design/interrupts/` (not yet written) and after user-space IRQ ownership model is decided (Pillar 3: driver in user, handler notification via KIND_NOTIFICATION).
- Pattern approval — softarch already approved. Continue with the discipline: structural stubs are auditable, tracked separately from real landings, and named so a scan of dispatch chain omissions reveals them.

### 2.4 KIND_DEVICE OP_MAP_MMIO returns synthesized vaddr, not aspace_map result

**Spec.** OP_MAP_MMIO on a KIND_DEVICE cap should map an MMIO region into the caller's address space via the real page-table walker.

**Reality.** `request_mmio_mapping` synthesizes `0xFFFF800000000000 | (phys_base & 0xFFFFFFFF)` and returns it. No `aspace_map` call. R12 landed this; R13 retained it with an R14-deferral audit (r13-m4-005, #450).

**Root cause.** aspace_map was unsafe against boot huge pages (walker collision). Also required current-aspace API (absent) and MMIO-region cap design (deferred).

**Corrective plan.**
- **Unblocker 1:** aspace_map huge-page detection landed at r14-m2-003. Walker no longer clobbers boot state.
- **Unblocker 2:** Higher-half kernel VMA (R14 Path B / #480) will move kernel out of low half, so user aspaces populate low half cleanly and MMIO regions can map into a distinct high-half range.
- **Unblocker 3:** MMIO-region cap design — write a short design note (`design/drivers/mmio-region-cap.md`) pinning: MMIO region → phys base + length + attrs; KIND_DEVICE cap holds region ID; OP_MAP_MMIO(region_id, target_va) → aspace_map(current_aspace, target_va, region.phys, region.len, MMIO_ATTRS). This is a design gap, not a code gap.
- **Backfill milestone:** R14-M5 or R14-M6 after Path B lands.

### 2.5 Multi-CPU: multicore-first pillar vs single-CPU-only R13 reality

**Spec.** Pillar 2: "Multicore-efficient by design. The kernel data structures, scheduler, and IPC paths are designed for many-core / NUMA from inception. No 'big kernel lock' phase ever exists."

**Reality.** Everything is single-CPU. `_cpu0_kernel_gs` is a single 64-byte struct. `_syscall_kernel_stack` is a single 16 KiB array. `_saved_user_rsp` is a single u64. Runqueue is a single flat array. No SIPI, no AP bootstrap, no per-CPU state instantiation, no IPI. Documented as an R13 data race that is unreachable while the trampoline is unreachable — a truthful but structurally deferred posture.

**Root cause.** Three encoder gaps in paideia-as:
- PA-R14-001 (#926) — GS-relative memory operand (segment prefix 0x65) not encoded. Blocks efficient per-CPU access.
- PA-R13-012 (#925) — `xchg [mem], reg` / `lock cmpxchg` / `lock` prefix not encoded. Blocks spinlocks + atomic counters.
- PA-R13-005 (#918) — `mfence` not encoded. Blocks TLB-shootdown ordering.

**Corrective plan.**
- **paideia-as v0.12.0 bundle:** PA-R13-001 + PA-R13-010/011/012 + PA-R14-001 already scoped per r13-closure §"R14 Carryover". This is the substrate path.
- **Sequencing:** Path A (multicore bring-up) in `r14-kickoff.md` opens AFTER Path B (higher-half + KPTI). Rationale: Path B is the smallest lift (6–9 issues) with no substrate blockers; it clears the aspace_map safety story for Path C (VFS/fork) as well. Path A cannot open until PA-R14-001 clears.
- **Design gap:** No document under `design/multicore/` exists yet. Recommend writing `design/multicore/per-cpu-layout.md` (BSP + APs, GS-base per-CPU struct format, per-CPU runqueue layout, IPI vector table) as R14-M1 side-work regardless of primary path.
- **Pillar honesty:** The pillar text says "no big kernel lock phase ever exists" — literally true because there is no lock at all (there is only one CPU). But that is not the same as pillar demonstration. When Path A opens, the demonstration must be structural — per-CPU data structures + fine-grained locking primitives designed in, not retrofitted. r13-retrospective (d) is the honest read: substrate gap rate is ~3/round, stable, and paideia-as v0.12.0 is the natural bundle.

### 2.6 Post-quantum crypto: pillar 6 vs zero code

**Spec.** Pillar 6: "Post-quantum KEMs (ML-KEM / Kyber, FIPS 203), signatures (ML-DSA / Dilithium, FIPS 204; SLH-DSA / SPHINCS+, FIPS 205), and hybrid handshakes (X25519+ML-KEM-768 per draft-ietf-tls-hybrid-design). ... Confidentiality and integrity are construction properties, not afterthoughts."

**Reality.** Zero code in paideia-os. `grep -rE "post-quantum|ml_kem|ml_dsa|kyber|dilithium|sha3|rdrand|rdseed" src/` returns only SARIF metadata from the paideia-as toolchain signing pipeline. No kernel entropy source (C15). No TPM 2.0 driver (C11). No measured-boot chain. No hybrid TLS. No `RDRAND`/`RDSEED` plumbing.

**Root cause.** Everything above the ring-0/ring-3 boundary is deferred until ring-3 lands. PQ crypto lives above VFS + networking + userspace, which are all downstream of ring-3 and IPC-mediated user servers. There has been no attempt because there is nowhere yet to run it.

**Corrective plan.**
- **Honest accounting:** PQ crypto is R18-R20 territory at the earliest. Between R14 (ring-3 land) and R18 (PQ crypto) sit: R15 (multicore land or VFS/fork completion), R16 (network stack — user-space TCP/QUIC per pillar 7), R17 (TPM 2.0 driver + measured-boot chain). This is not a schedule; it is a dependency chain.
- **Design work now:** Write `design/security/pq-crypto-plan.md` pinning ML-KEM-768 + ML-DSA-65 + SLH-DSA target parameter sets, and the entropy-source plumbing plan (RDRAND/RDSEED wrapped in a jitter loop + TPM RNG, per C15 references). This is design-only cost and unblocks R18+ execution.
- **Do not force early landing.** Attempting PQ crypto before entropy source + user-space + a networking substrate is premature. Pillar 6 will be visible in what does not get built now (POSIX-style shortcuts, weak legacy crypto) as much as in what gets built later.

### 2.7 FP-disciplined and semantically-queryable terminal (Pillars 8, 10)

**Spec.**
- Pillar 10: "Functional discipline in assembly. Calling conventions, macros, and ABIs encode monadic effect typing, applicative composition, and substructural (linear/affine) capability handling."
- Pillar 8: "Semantic terminal. A shell whose commands operate on typed, semantically queryable objects."

**Reality — Pillar 10.** FP discipline IS being demonstrated at the paideia-as level. Every function in `src/kernel/` carries `!{...} @{...}` effect + capability annotations (mem, sysreg, cap, sched, boot). The compiler enforces them. `justification: "..."` on every `unsafe {}` block. The syscall trampoline widened its effect signature from `!{sysreg, mem} @{}` to `!{mem, sysreg} @{cap, sched}` when the dispatch reached cap/sched paths. This is real FP discipline in assembly, working today.

**Reality — Pillar 8.** Zero runtime code. Design docs exist under `design/terminal/` (14 files: `semantic-shell.md`, `datalog-spec.md`, `pds-format.md`, `wire-format.md`, `kitty-dialect.md`, `command-registry.md`, `perf-baselines.md`, etc.) but nothing is compiled. The current shell is a §C-native `puts` chain.

**Root cause.** Terminal is downstream of ring-3 execution + a runtime object system + a schema store. All of that is R15+ territory.

**Corrective plan.**
- Pillar 10 — no corrective action needed. It is being demonstrated. Add a `design/toolchain/effect-effect-taxonomy.md` if the current implicit taxonomy (`mem, sysreg, cap, sched, boot, io`) has drifted from any design doc; last check was during r13-m5-003 audit and the taxonomy held.
- Pillar 8 — no corrective action at R14. Prep work: `design/terminal/semantic-shell.md` should be re-read against ring-3 substrate assumptions once Path C lands, and the schema-store design (`design/terminal/pds-format.md`) should be validated against the R14 VFS choice (POSIX vs cap-based).

### 2.8 paideia-as encoder gaps

**Spec.** paideia-as is meant to be substrate-adequate for each round; the design intent is that paideia-os work is not gated by encoder work.

**Reality.** Twelve open escalations across R13/R14 rounds. Three-per-round is stable (r13-retrospective (d)). Five are HARD blockers for R14+:
- PA-R13-001 (#914) — `ltr r16` — blocks TSS install → blocks all ring-3.
- PA-R13-012 (#925) — atomics + lock prefix — blocks spinlocks under multicore.
- PA-R14-001 (#926) — GS-relative memory operand — blocks efficient per-CPU access.
- PA-R13-005 (#918) — `mfence` — blocks TLB shootdown ordering.
- PA-R13-007 (#920) — `fxsave`/`fxrstor` — blocks FP context save/restore (C17).

**Root cause.** paideia-as milestone plan is driven by paideia-os round demand. Substrate discovery is intrinsic to R&D-OS work — the encoder gaps for R14 could not have been enumerated before R13.M8 tried to reach ring-3 and discovered them.

**Corrective plan.**
- **paideia-as v0.12.0 bundle:** Package PA-R13-001 + 003/004 (subset of 012) + 005 + PA-R14-001 as a single drop. This is 5 encoders in one release. Once landed, submodule bump to v0.12.0 clears the R14 Path A/B blockers and the ring-3 exception delivery blocker.
- **Rate discipline:** Three encoders / round is stable, not accelerating. This should be built into the release cadence — every paideia-os round R_N implies a paideia-as v0.M+1 release ~1 round later.
- **Feedback tracking (per `feedback_paideia_as_version_discipline.md`):** workspace.version + git tag + CHANGELOG entry move together at each phase close.

---

## Section 3: Depth vs scaffolding assessment

### 3.1 Subsystems ready for depth (real handlers under them, primitives compose)

- **Capabilities (60%).** Deepest subsystem. 10 real handlers + rights enforcement + denial witness + effect annotations. Ready for: generation-based revocation validation in dispatch, sealed caps, kind-specific rights lattice. Depth work here is productive today. Note that going deeper on caps without ring-3 yields dead code — but the dead code is exercisable from kernel-side fixtures (as R12 demonstrated with `cap_dispatch_smoke`).
- **IPC (40%).** Four cap-mediated primitives real (SPSC ring, single-slot port, one-shot reply, counting notification). Ready for: formal deadlock-freedom argument tied to the running code (pillar 4 obligation currently satisfied by design doc only). Multi-consumer MPSC channel blocked on `lock cmpxchg` (PA-R13-012).
- **Interrupts/timer (40%).** BSP path is fully real. Ready for: MSI/MSI-X plumbing, IOAPIC bring-up, user-space IRQ delivery via KIND_INTERRUPT + KIND_NOTIFICATION (already scaffolded).
- **Scheduler (40%).** TCB + runqueue + preemption real. Ready for: fair scheduling (CFS/EEVDF-like) via priority-bitmap extension, sleep queues, cooperative wake-from-IPC.
- **MM primitives (22% overall but the leaf walker is 100%).** aspace_map + huge-page detection safe. Ready for: KIND_PAGE_TABLE real handler (once args-encoding decided), KIND_DEVICE OP_MAP_MMIO backfill (once MMIO-region cap designed), aspace_activate wired to scheduler switch.

### 3.2 Subsystems needing scaffolding before depth is productive

- **Userspace execution.** Needs, in strict dependency order: (a) `tools/build-user.sh` discipline (compile `src/user/*.pdx` under user linker script, `objcopy -O binary`, `.incbin` into `kernel.elf`) — this is a build-system task, not a code task. (b) TSS + `ltr` install (#424, blocked on paideia-as PA-R13-001). (c) Higher-half kernel VMA (Path B / #480) so user aspaces populate low half without collision. (d) `cap_smoke` migration (DONE at r14-m2-001, #482). (e) §C amendment for `sys_read` (see 2.2). Only after all five does depth work on userspace become productive.
- **Filesystem.** Needs §C amendment decision (2.2) plus ring-3 (above). Then VFS layer decisions, tmpfs, block-device driver, ELF-lite loader. Everything is upstream.
- **Multi-CPU.** Needs PA-R14-001 (GS prefix), PA-R13-012 (atomics), PA-R13-005 (mfence). Then per-CPU struct instantiation, SIPI trampoline, AP bootstrap, IPI vector routing. All is substrate.
- **Process management (12%).** KIND_PROCESS real. Needs: fork (COW walker), exec (ELF-lite loader), wait (KIND_REPLY glue), signals (Rev-2 m11), process teardown. All upstream of ring-3. Once ring-3 lands, this becomes shallow and productive within a round or two.
- **Terminal / shell.** Needs UART RX + line editing + sys_read (or user-space RX ring). Interactive shell can then be written. Semantic shell is R15+.
- **Security controls (PQ crypto, KPTI, CET, MPK, measured boot).** Needs: KPTI real (Path B unlocks it), then CET IBT + shadow stack (short encoder work), then MPK/PKU (short encoder work). Measured boot needs TPM 2.0 driver — that lives in user-space per Pillar 3, so needs ring-3 + drivers. PQ crypto is R18-R20.

### 3.3 Critical-path scaffolding items

Ranked by leverage (each unblocks how many downstream subsystems):

1. **paideia-as v0.12.0 release** (PA-R13-001 + 012 + PA-R14-001 + PA-R13-005 minimum). Highest leverage. Unblocks: TSS install → ring-3 exception delivery. Unblocks: spinlocks → fork/exec/wait + multicore. Unblocks: per-CPU addressing → multicore. Unblocks: TLB shootdown → multicore. This one release is the fulcrum.

2. **Higher-half kernel VMA relocation (R14 Path B / #480).** Second-highest leverage. Unblocks: aspace_map safety confidence at scale (any user aspace populates low half cleanly). Unblocks: real KPTI (via runtime CR3 switch). Unblocks: KIND_PAGE_TABLE (once combined with args-encoding decision). Softens: KIND_DEVICE OP_MAP_MMIO real backfill. Path B is ~6–9 issues per r14-kickoff and is the R14 opener.

3. **TSS install (#424)** — gated on item 1. Once paideia-as v0.12.0 lands, this is a 1-issue landing that opens ring-3 exception delivery. Do NOT try to work around it; ring-3 without TSS.RSP0 triple-faults on first exception.

4. **`tools/build-user.sh` + user linker script.** Independent of item 1 and item 2. Can land any time. This is a 1-issue-sized build-system task. Unblocks: `shell.bin` embed → ring-3 first jump substrate.

5. **§C amendment decision (Option 1 vs Option 2 per r14-preflight §E).** Governance task at R14-M1 side-work. Unblocks: interactive shell, VFS, fork/exec/wait file semantics. Blocks nothing today because deferred milestones are already tagged as deferred. But blocking any depth-work on Path C.

6. **cap_smoke migration (#482)** — LANDED at r14-m2-001. Slot 0 is free for real KIND_PROCESS. Already exploited by r14-m2-002 backfill.

7. **aspace_map huge-page detection (#488)** — LANDED at r14-m2-003. Walker no longer clobbers boot pages. Kernel-side safety story is intact.

### 3.4 Recommended sequencing

The R14 kickoff document recommends Paths B → C → A → D. This report concurs, with additional detail on internal ordering.

**Immediate (R14-M2 through M4, current position).**
- Continue on the current task (Path B: higher-half kernel VMA + KPTI, #480, tracked as in-progress task #60). Aim: kernel `.text`/`.data` at 0xFFFF_8000_0010_0000 with a boot-time far-jmp transition, plus KPTI CR3 switch in the SYSCALL trampoline path.
- File PA-R14-001 (done per r14-preflight §F, #926).
- Resolve §C amendment as R14-M1 side-work — do not proceed to Path C without this decision.
- Write `design/multicore/per-cpu-layout.md` and `design/drivers/mmio-region-cap.md` as R14-M1 side-work.

**R14-M5 through M8 (Path B tail + user-space bring-up prerequisites).**
- Path B smoke fixture + closure (M6).
- `tools/build-user.sh` discipline (M7 or side-work in M4).
- If paideia-as v0.12.0 has landed by then: TSS install (#424, M8), then ring-3 first jump substrate.

**R14-M9 through M15 (Path C).**
- ELF-lite loader (real body of what R13 pinned in §I of the r13-plan).
- Ring-3 first jump via SYSRET (m8-002 / #484 chain).
- VFS + tmpfs (bundle #485).
- fork/exec/wait (bundle #486, blocked on PA-R13-012 for spinlocks; single-CPU fork lands first, spinlock hardening arrives once atomics do).
- Interactive shell v2 (closes #483).

**R15 (Path A + Path D).**
- Multicore SIPI + AP bootstrap.
- Per-CPU runqueue + GS-relative access.
- IPI + TLB shootdown.
- Ring-3 preemption across CPUs (Path D).

**R16+.**
- Network stack (Pillar 7, user-space TCP/QUIC).
- ACPI real bring-up (RSDP + MADT parsing, currently stubs).
- Drivers (NVMe, e1000e, virtio-net full — currently only virtio-net probe skeleton).

**R17+.**
- TPM 2.0 driver, measured boot completion.
- CET IBT + shadow stack.
- MPK/PKU.

**R18-R20.**
- Post-quantum crypto (ML-KEM-768, ML-DSA-65, SLH-DSA).
- Hybrid TLS handshake.
- Semantic shell runtime.

### 3.5 On the "backtracking with structural stub + R14-deferral audit" pattern

The r13-retrospective proposed three landing categories (lesson (c)):
- **Real handler** — full body, live in dispatch chain, boot-observable or reachable-in-fixture.
- **Structural stub** — pool declarations + byte offsets + R14 audit; not in dispatch chain; boot-invisible.
- **Hidden-shortcut stub** — presented as MVP, actually a 4-byte no-op; not a valid category (caught by debugger in #430).

**Assessment.** This pattern should CONTINUE. Rationale:
- Structural stubs preserved the boot fingerprint byte-identically across 15 R13 landings + 3 R14 landings. Zero regressions.
- The pattern makes deferral explicit and auditable (the r13-m6-* audit entries name the R14 blocker chain).
- The softarch / workerbee / debugger triangle catches drift (r13-retrospective (b) — #430 workerbee 4-byte stub caught by debugger).
- Pre-freeze scope discipline (§C) prevents wording drift from becoming silent ABI drift.

**But add:** a preflight-M0.5 "reachability audit" (r13-retrospective (e)). Trace the round's last-milestone observable back through every subsystem it touches, and file blockers before M1 opens. This would have caught the huge-page walker and cap_smoke coupling at R13 kickoff, saving the mid-round backtracking cost. Under this discipline, structural stubs land when a blocker chain is genuinely late-surfacing; otherwise the milestone is scoped honestly at preflight.

**No bigger reset warranted.** R13 shipped valid substrate; deferrals are tracked; the retrospective is honest; regression discipline held byte-identically. A reset would be higher-cost than pushing forward under the current discipline. What is needed is not a reset but a preflight upgrade (M0.5 reachability audit) and a substrate release cadence (paideia-as v_M+1 tracking paideia-os R_M+1).

### 3.6 Concrete recommendations

**R14 execution.**
1. Land Path B (higher-half + KPTI) — currently task #60 in-progress. Do not scope-creep into Path C.
2. Resolve §C amendment (Option 1 vs Option 2) as an M1 side-work document, not as a landing.
3. File `tools/build-user.sh` as a distinct issue and land in M4 or M5, independent of Path B kernel-side work.
4. Track paideia-as v0.12.0 progress; once landed, submodule bump + TSS install (#424) is R14's next opening.

**Depth first, on the ready subsystems.**
1. Capabilities — revocation-in-dispatch (`descriptor.generation` check). Sealed caps design. Kind-specific rights lattice population.
2. IPC — formal deadlock-freedom proof-obligation tied to the running SPSC + port + reply code (Pillar 4). Requires design work in `design/ipc/`.
3. Scheduler — sleep-queue + wake-on-IPC design + landing.

**Scaffold before depth on these.**
1. Userspace — ring-3 substrate first (Path B → TSS → user-linker → shell.bin embed).
2. Filesystem — §C amendment + ring-3 first, then VFS + tmpfs + block-device.
3. Multi-CPU — paideia-as v0.12.0 substrate first.
4. Terminal — sys_read (or user-space UART RX ring) first.

**Design-only cost that pays off later.**
1. `design/multicore/per-cpu-layout.md`.
2. `design/drivers/mmio-region-cap.md`.
3. `design/security/pq-crypto-plan.md`.
4. `design/interrupts/user-space-irq-model.md` (KIND_INTERRUPT + KIND_NOTIFICATION composition).
5. `design/memory/higher-half-vma.md` (already referenced in r14-preflight §G, not yet written).

**Governance.**
1. Preflight-M0.5 reachability audit — trace last-milestone observable back through touched subsystems, file blockers before M1.
2. Issue-body §C audit — every issue body post-dating a preflight freeze must be scanned against the frozen §C table before it enters the sprint queue.
3. paideia-as release cadence — v_M+1 tracks paideia-os R_M+1 by one round.

---

## Appendix A: Cross-references

- Round-by-round STATUS: `/home/snunez/Development/PaideiaOS/STATUS.md`.
- R13 closure: `/home/snunez/Development/PaideiaOS/design/milestones/r13-closure.md`.
- R13 retrospective: `/home/snunez/Development/PaideiaOS/design/round-retrospectives/r13-shell-foundation.md`.
- R14 preflight: `/home/snunez/Development/PaideiaOS/design/milestones/r14-preflight.md`.
- R14 kickoff: `/home/snunez/Development/PaideiaOS/design/milestones/r14-kickoff.md`.
- Feature inventory (pillar list + Tier-1 Critical C1–C18): `/home/snunez/Development/PaideiaOS/design/00-feature-inventory.md`.
- R14-m2-003 audit (huge-page detection): `/home/snunez/Development/PaideiaOS/design/audit/entries/r14-m2-003-aspace-map-huge.md`.
- R13-m5-003 audit (syscall table §C): `/home/snunez/Development/PaideiaOS/design/audit/entries/r13-m5-003-syscall-table.md`.
- R13-m6-001 real KIND_PROCESS handler: `/home/snunez/Development/PaideiaOS/src/kernel/core/cap/kind_process.pdx`.
- Syscall dispatcher: `/home/snunez/Development/PaideiaOS/src/kernel/core/syscall/dispatch.pdx`.
- Boot stub: `/home/snunez/Development/PaideiaOS/tools/boot_stub.S`.
- Kernel main: `/home/snunez/Development/PaideiaOS/src/kernel/boot/kernel_main.pdx`.
- User shell source: `/home/snunez/Development/PaideiaOS/src/user/shell.pdx`.

## Appendix B: Commit anchors

- R13 close: b0868d1 (`Land r13-m10-002 (#443): R13 retrospective + R14 kickoff docs`).
- r13-closed tag: b0868d1.
- R14 preflight: a6dba35 (`Land r14-m1-001 (#487): R14 preflight audit`).
- cap_smoke migration: 1f195e6 (`Land r14-m2-001 (#482)`).
- Real KIND_PROCESS: 76adf40 (`Land r14-m2-002 backfill of r13-m6-001 (#430)`).
- Huge-page detection: a049b87 (`Land r14-m2-003 (#488)`).
- HEAD (this report authoring): a049b87.

## Appendix C: Open paideia-as escalations (as of report authoring)

| paideia-as # | Escalation | Encoder | Round | Hard? |
|---|---|---|---|---|
| #914 | PA-R13-001 | `ltr r16` | R13 | HARD (blocks TSS → ring-3) |
| #915 | PA-R13-002 | gs-relative memory operand | R13 | HARD (duplicated as #926 for R14) |
| #916 | PA-R13-003 | `xchg [mem], reg` | R13 | HARD (multicore) |
| #917 | PA-R13-004 | `lock cmpxchg` | R13 | HARD (multicore) |
| #918 | PA-R13-005 | `mfence` | R13 | HARD (TLB shootdown) |
| #919 | PA-R13-006 | CR4 write variants | R13 | soft |
| #920 | PA-R13-007 | fxsave/fxrstor | R13 | HARD (FP save/restore, C17) |
| #921 | PA-R13-008 | `pub let mut` .rodata bug | R13 | governance |
| #923 | PA-R13-010 | SUB r64, imm | R13 | workaround |
| #924 | PA-R13-011 | back-to-back labels | R13 | workaround |
| #925 | PA-R13-012 | atomics bundle | R13 | HARD (Rev-2 m10 + m13) |
| #926 | PA-R14-001 | GS-relative memory operand | R14 | HARD (Path A per-CPU) |

Five HARD blockers form paideia-as v0.12.0 minimum bundle: 001 + 003 + 004 + 005 + 926 (which subsumes 002). With that release, R14 Path A + TSS install + TLB shootdown all unblock. R14 Path B and Path C are unblocked today.

---

**Author:** osarch (take-stock harness)
**Date:** 2026-07-03
**Status:** Advisory — no code changes proposed. Feeds R14 sequencing decisions and governance additions.
