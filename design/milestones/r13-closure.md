# PaideiaOS R13 Closure: Cap-Dispatch Surface + Syscall Table (Partial)

**Status:** CLOSED (PARTIAL)
**Milestones:** R13.M1–R13.M7 landed; R13.M8 + Rev-1 M8/M9 + Rev-2 M9–M15 deferred to R14
**Date:** 2026-07-03

---

## Executive Summary

**R13** was scoped as a *full userspace + interactive shell* round: bootstrap the ring-0/ring-3 boundary, land ELF loading and a live user shell, then bring up VFS, fork/exec/wait, signals, and preemptive multicore on top. **That scope was not achieved.** Ring-3 was blocked on a chain of dependent gaps (aspace_map huge-page collision, TSS+`ltr` encoder, user-linker + `build/shell.bin`, cap_smoke migration) that surfaced only once the cap-dispatch surface reached the ring-transition boundary.

What R13 **did** land is the substrate under that boundary:

1. The **cap-dispatch surface** grew from 4 kinds (R12) to a **13-entry dispatch table** covering all ten of the remaining kinds specified in preflight §B — five with real handler bodies (THREAD, IPC_PORT, TIMER, NOTIFICATION, REPLY), three as structural stubs with pinned data models and R14 follow-up plans (PROCESS, PAGE_TABLE, INTERRUPT), and OP_MAP_MMIO retained as vaddr-synthesis pending real `aspace_map` integration.
2. The **SYSCALL/SYSRET fast-path** was built out end-to-end: five MSR pins (EFER.SCE, STAR, LSTAR, FMASK, KERNEL_GS_BASE), a real ring-transition trampoline with register-shuffle from SYSCALL ABI to SysV C ABI, and a **13-entry syscall table per preflight §C** (2 real handlers wired: `sys_yield`, `sys_cap_invoke`, `sys_debug_puts`; 10 return ENOSYS pending downstream milestones).
3. The **MMU-hardening perimeter** landed: PML4[256] higher-half alias, KPTI PGD-copy stub, SMEP, SMAP, NX, a real 8-entry GDT with SYSRET-compatible slot layout, IST stacks (DF/NMI/MC), and IDT-IST rewire for the four critical vectors.
4. The **user-space source tree** exists under `src/user/`: `shell.pdx`, `syscall_shim.pdx`, `io.pdx`, `builtins.pdx`. This code compiles nowhere in R13 — `tools/build.sh` globs only `src/kernel/` — but it is a §C-native, straight-line demonstrative main and it pins the user-side ABI for R14.

**None of the R13 additions emit observable output at boot.** The `boot_r12` fingerprint remains byte-identical across every mode: no `CAP INVOKE THREAD/PORT/TIMER/NOTIF/REPLY` line appears because the R8 `cap_smoke` fixture (which anchors the fingerprint) still mints only KIND_PAGE / KIND_IPC_ENDPOINT / KIND_SCHED_CTX / KIND_DEVICE. The new handlers are reachable code paths but dead code at boot — proving the dispatch table extended without perturbing the existing invocation matrix.

**Final Boot Output (byte-identical to R12):**
```
B
PaideiaOS R8
CAP OK
IPC OK
CAP INVOKE MEM
CAP INVOKE IPC
CAP INVOKE SCHED
CAP INVOKE DEV
CAP DISPATCH OK
IDT OK
TASK A
TASK B
TASK A
```

(13 lines; the observable envelope of R12 is preserved as R13's regression guard. All new R13 code — 10 additional dispatch branches, syscall MSR + trampoline + table, GDT/IST/IDT/SMEP/SMAP/NX bring-up, plus the entire `src/user/` tree — is off-path in the 5-mode smoke suite.)

---

## Per-Milestone Summary

### R13.M1: Pre-Flight Audit + Architecture Pins

**Issues:** #417 (m1-001), #418 (m1-002)
**Status:** COMPLETE

**M1-001** audited encoder coverage against the R13 multicore + userspace critical path. Verified 11 present encoders (mem-operand variants, direct call, LEA-RIP-relative, cmp/je); identified 7 escalations (PA-R13-001..007), of which five are HARD blockers (`ltr r16`, `gs:` prefix, `xchg [mem],reg`, `lock cmpxchg`, `mfence`) and two soft (CR4 write variants, `fxsave`/`fxrstor`).

**M1-002** pinned seven architectural decisions to byte-exact resolution: GDT slot layout with SYSRET-compatible ordering, SYSCALL MSR values (IA32_STAR / IA32_LSTAR / IA32_FMASK), higher-half kernel VA (0xFFFF_8000_0010_0000), KPTI dual-PGD layout, per-CPU struct (64-byte aligned, MAX_CPUS=8), IPI vector table (vec 32–36), signal frame format (24 × u64 = 192 bytes), and ELF-lite parser skeleton. Filed as `design/audit/entries/r13-m1-002-arch-pins.md`; the pins govern every downstream milestone in R13 and every deferred milestone in R14.

**Audit entries:** r13-m1-002-arch-pins.md

**Post-landing correction:** Backtracking #481 (plan §4 m5-003 wording drift) filed and resolved (commit 40af7ae) — preflight §C is the frozen source of truth for the syscall table, superseding the round plan.

---

### R13.M2: Physical Memory + Address Space API

**Issues:** #419 (phys_alloc), #420 (aspace_map), #421 (aspace_create), #422 (aspace_unmap), #444 (buddy interface parking)
**Status:** COMPLETE (source-structural)

**M2-001** implemented `phys_alloc` as a bump allocator over a static 64-page pool (later grown to 1024 pages in m2-005). **M2-002** landed `aspace_map` as a real 4-level page-table walker with 9-bit index extraction, intermediate-table allocation via `phys_alloc`, leaf-PTE composition, and `invlpg` per Intel SDM Vol 3A §4.5 + §4.10.4.1. **M2-003** landed `aspace_create` with upper-half PGD copy loop and CR3 composition (PML4 | PCID | no-flush). **M2-004** landed `aspace_unmap` with per-CPU shootdown mailbox bookkeeping. **M2-005** parked the buddy allocator interface (`buddy_alloc` / `buddy_free`) as stubs returning `BUDDY_NULL` for orders 1..10 while preserving the bump-allocator order-0 fast path.

**Backtracking #480** filed for higher-half VMA relocation (m3-001 Phase-2 kernel remapping to 0xFFFF_8000_0010_0000). Deferred to R14 — Phase-1 installs the PML4[256] alias but the kernel keeps executing in the low-VA identity map.

**Audit entries:** r13-m2-001-phys-alloc.md, r13-m2-002-aspace-map.md, r13-m2-003-aspace-create.md, r13-m2-004-aspace-unmap.md, r13-m2-005-buddy-allocator.md

**Known limitation:** `aspace_map`'s walker treats every level as 4 KiB PTs; the boot-stub 1 GiB huge-page entries in PML4[0]/PML4[256] would be clobbered on descent. This is the deferral rationale for real `OP_MAP_MMIO` (m4-005), real `KIND_PAGE_TABLE` (m6-003), and m8 kernel-user transition.

---

### R13.M3: MMU Hardening (Higher-Half + KPTI + SMEP/SMAP/NX)

**Issues:** #445 (m3-001 Phase 1), #446 (m3-002), #447 (m3-003), #448 (m3-004), #449 (m3-005)
**Status:** COMPLETE (Phase-1 alias only; Phase-2 kernel VMA move deferred to R14 per #480)

**M3-001 Phase 1** wrote PML4[256] to mirror PML4[0] in `tools/boot_stub.S` after PDPT population and before CR3 load — a passive higher-half alias. Kernel execution remains in the low identity map; Phase 2 (kernel VMA relocation + far-jmp transition) is deferred to R14. **M3-002** landed `aspace_create_user_pgd` as a stub returning `ASPACE_CREATE_NOT_YET`; full USER_PGD instantiation waits on a dedicated trampoline PDPT and m5-002's CR3-swap machinery. **M3-003 / M3-004 / M3-005** enabled SMEP (CR4.20), SMAP (CR4.21), and NX (IA32_EFER.NXE bit 11) with CPUID guards; all three are safe at enable-time because no user pages are mapped yet.

**Audit entries:** r13-m3-001-hh-alias.md, r13-m3-002-kpti-pgd-copy.md, r13-m3-003-smep.md, r13-m3-004-smap.md, r13-m3-005-nx.md

---

### R13.M4: GDT + IST + IDT + MMIO Wiring

**Issues:** #423 (m4-001), #424 (m4-002), #425 (m4-003), #426 (m4-004), #450 (m4-005)
**Status:** MOSTLY COMPLETE — #424 (TSS + `ltr`) remains OPEN, blocked on PA-R13-001 (paideia-as #914, `ltr r16` encoder)

**M4-001** replaced the boot-stub GDT with a real 8-slot install: kernel code64 at 0x08 (fixes a latent code32/code64 CS mismatch), kernel data at 0x10, user data at 0x20, user code64 at 0x28, TSS slots 6–7 reserved as zero pending m4-002. GDT layout derived from SYSRET semantics (STAR[47:32] = 0x0018 → user CS = 0x28, user SS = 0x20). **M4-003** allocated 16 KiB IST stacks in `.bss` for DF, NMI, MC vectors. **M4-004** rewrote the IST field of four critical IDT vectors (2 NMI, 8 DF, 14 PF, 18 MC) to point at the m4-003 stacks. **M4-005** landed the `KIND_DEVICE` `OP_MAP_MMIO` deferral audit: `request_mmio_mapping` continues to synthesize a high-half vaddr (`0xFFFF800000000000 | (phys_base & 0xFFFFFFFF)`) without walking page tables — real `aspace_map` integration filed as backtracking to R14.

**Open:** M4-002 (#424) — TSS install + `ltr` load. Substrate blocker filed as paideia-as #914; the TSS structure is architecturally required for ring-3 entry (RSP0 field on ring-0 exception delivery) so this issue gates real m8 landing.

**Audit entries:** r13-m4-001-gdt-install.md, r13-m4-003-ist-stacks.md, r13-m4-004-idt-ist-rewire.md, r13-m4-005-mmio-mapping.md

---

### R13.M5: SYSCALL/SYSRET Entry Path

**Issues:** #427 (m5-001), #428 (m5-002), #429 (m5-003)
**Status:** COMPLETE (3/3)

**M5-001** wrote five MSRs to enable SYSCALL/SYSRET encoding per Intel SDM Vol 3A §6.15: IA32_EFER (SCE=1, NXE preserved via read-modify-write), IA32_STAR = 0x0018000800000000 (kernel CS = 0x08, user base = 0x18), IA32_LSTAR = `&syscall_entry`, IA32_FMASK = 0x47700 (Linux SYSCALL_MASK: TF | IF | DF | IOPL | NT | AC), IA32_KERNEL_GS_BASE = `&_cpu0_kernel_gs`. The initial audit claimed `sysret` was missing (PA-R13-009); reverified against paideia-as ae6039b, confirmed `encode_sysret()` in `crates/paideia-as-encoder/src/encode_instruction.rs` produces `48 0F 07`. **PA-R13-009 was withdrawn as invalid**, and the `entry_stub.pdx` placeholder was replaced in the same round with the real trampoline.

**M5-002** landed the real trampoline: save user RSP to `_saved_user_rsp[0]`, load kernel RSP top from `_syscall_kernel_stack[2048]` (16 KiB), push rcx (user RIP) / r11 (user RFLAGS) / rax (syscall#), shuffle SYSCALL ABI → SysV C ABI (`rax→rdi, rdi→rsi, rsi→rdx, rdx→rcx, r10→r8`), call `syscall_dispatch`, restore, `sysret`. R13 simplifications documented and audited: no `swapgs` (single-CPU); no KPTI CR3 flip (no unprivileged code); single-CPU stack (data race under multicore); no user-RSP validation.

**M5-003** replaced the m5-002 stub dispatcher with a **13-entry linear cmp/je chain per preflight §C** (superseding round-plan §4 wording; backtracking record #481). Three handlers are real: `sys_yield` (tail-calls `sched_yield`), `sys_cap_invoke` (arg shuffle rsi→rdi, rdx→rsi, tail-calls `cap_invoke`), `sys_debug_puts` (arg shuffle rsi→rdi, calls `uart_puts`, echoes `msg_len`). Ten return ENOSYS with per-handler deferral rationale: `sys_ipc_send`/`sys_ipc_recv` gated on ring-3; `sys_cap_mint` on descriptor-layout definition (arity mismatch with existing `Mint.cap_mint`); `sys_cap_query`/`sys_cpu_id` on absent kernel symbols; `sys_signal_register`/`sys_signal_return` on Rev-2 m11; `sys_sipi_target` on Rev-2 m13; `sys_kpti_enable` on m3-002's runtime hook. Effects widened `syscall_entry: !{sysreg, mem} @{}` → `!{mem, sysreg} @{cap, sched}`.

**Audit entries:** r13-m5-001-syscall-msrs.md, r13-m5-002-syscall-trampoline.md, r13-m5-003-syscall-table.md

---

### R13.M6: Full Cap-Dispatch (10 New Kinds)

**Issues:** #430 (KIND_PROCESS), #431 (KIND_THREAD), #451 (KIND_PAGE_TABLE), #452 (KIND_IPC_PORT), #453 (KIND_TIMER), #454 (KIND_NOTIFICATION + KIND_INTERRUPT), #455 (KIND_REPLY)
**Status:** COMPLETE (7 issues closed): 5 real handlers, 3 structural stubs

**Real handlers landed (5):**

| Kind | Value | Ops | Handler |
|---|---|---|---|
| KIND_THREAD | 2 | OP_CREATE, OP_START (stub) | 30-instruction real body; pool 64 × 32B; OP_START defers scheduler enqueue to R14 |
| KIND_IPC_PORT | (per §B) | OP_SEND, OP_RECV | Point-to-point message slot; 64 × 16B pool; WOULD_BLOCK on full-SEND / empty-RECV |
| KIND_TIMER | (per §B) | OP_ARM, OP_CANCEL, OP_READ_TSC | Direct BSP LAPIC deadline + TSC read; target_ptr ignored |
| KIND_NOTIFICATION | (per §B) | OP_SIGNAL, OP_WAIT, OP_POLL | Counting-semaphore + LWW payload; 64 × 16B pool; matches seL4 notification-badge semantics at cap layer |
| KIND_REPLY | (per §B) | OP_REPLY, OP_STATUS | One-shot RPC reply cap; 64 × 16B pool; consumed-flag + payload sufficient for m11 SIGCHLD |

**Structural stubs landed (3):** filed with pinned data models and explicit R14 follow-up plans:

- **KIND_PROCESS (#430):** `_process_pool: [u64; 256]` + `_next_pid: [u64; 1]` declared in `.bss`; no handler wired. Three concrete blockers documented: cap_smoke path collision (slot 0 mints kind=1 and asserts result == target_ptr; a real PROCESS handler returning a fresh pid breaks the R8 fingerprint — migration filed as #482), paideia-as encoder gaps (PA-R13-010 `sub reg, imm`, PA-R13-011 back-to-back label sharing — both have `add r, 0xFF...FF` and duplicate-block workarounds), and `_next_pid` zero-init collision with `PROCESS_INVALID_PID=0`. **A companion bootstrap `process_init` (called from `kernel_main` after `nx_enable`) writes `_next_pid[0]=1` and `_next_tid[0]=1`** — landed alongside #431 to cover both counters symmetrically.
- **KIND_PAGE_TABLE (#451):** Op-code constants only (`OP_MAP=0`, `OP_UNMAP=1`); no handler, no dispatch branch, no tag string. Four blockers: args-encoding (three addresses cannot pack into one op_arg — requires memory-region-cap indirection or extended dispatch ABI), current-aspace API absent, huge-page walker collision, no user-space minter. Kind=3 remains a fallthrough.
- **KIND_INTERRUPT (bundled into #454):** ~10-instruction structural stub; real handler defers to R14 pending `_irq_notification_map[256]` design, ISR-side notification post inside `src/kernel/core/int/`, and userspace-visible EOI path.

**Deferred (1):** **KIND_DEVICE `OP_MAP_MMIO` (#450)** — retained the R12 vaddr-synthesis path; real `aspace_map` integration deferred pending huge-page walker fix, current-aspace API, and MMIO-region cap design (R14-m1..m3).

**Boot-time observability:** zero. None of the seven new handlers are minted at boot in `cap_smoke` or `cap_dispatch_smoke`. The dispatch surface grew from 4 branches to 10 real branches + 2 structural, but the invocation matrix at boot is unchanged. `boot_r12` fingerprint asserts this byte-identically.

**Audit entries:** r13-m6-001-kind-process.md, r13-m6-002-kind-thread.md, r13-m6-003-kind-page-table.md, r13-m6-004-kind-ipc-port.md, r13-m6-005-kind-timer.md, r13-m6-006-kind-interrupt-notification.md, r13-m6-007-kind-reply.md

**Backtracking:** #482 (cap_smoke migration for real KIND_PROCESS handler landing).

---

### R13.M7: User Shell Binary v1 (Source-Only)

**Issues:** #432 (m7-001), #433 (m7-002), #434 (m7-003)
**Status:** COMPLETE (source-only; not linked into kernel.elf)

Landed the user-space source tree under `src/user/`, using **§C-native syscall shims only** (no POSIX):

- **shell.pdx** (m7-001): straight-line demonstrative `_start` — banner (`"PaideiaOS shell v0.1\n"`) → prompt (`"$ "`) → help menu (`"help|exit\n"`) → `dispatch_cap(0, 0)` → `sys_exit_thread(0)`. No interactive loop; no `sys_read`; no command parsing.
- **syscall_shim.pdx** (m7-002): four wrappers matching the §C freeze — `sys_exit_thread` (syscall 0), `sys_yield` (1), `sys_cap_invoke` (4), `sys_debug_puts` (12). Linux x86_64 syscall ABI: RAX=syscall#, RDI/RSI=args, RCX/R11 clobbered by SYSCALL.
- **io.pdx + builtins.pdx** (m7-003): `puts` (wraps `sys_debug_puts`), `builtin_help`, `builtin_exit`, `dispatch_cap`. No `getline` (no `sys_read`); no `parse_decimal`; no `cap N M` builtin.

**Backtracking #483** filed as the R13 user-shell drift record: preflight §C intentionally excluded `sys_read` from the frozen syscall table, so the R13 shell cannot be interactive by design. The interactive shell — with `sys_read`, decimal parsing, and a real REPL — lands in R14.

**Regression:** `tools/build.sh` only globs `src/kernel/`; `src/user/*.pdx` are not compiled at R13. No binary produced; no regression vector; no observable boot change.

**Audit entries:** r13-m7-001-shell-main.md, r13-m7-002-syscall-shim.md, r13-m7-003-io-builtins.md

---

### R13.M8: Kernel-User Transition — DEFERRED

**Issues:** m8-001 / m8-002 / m8-003 (kernel-side loader + user linker + ring-3 first jump)
**Status:** ZERO ISSUES LANDED. Bundled deferral filed as **#484**.

**Blocker chain:**

1. **`aspace_map` huge-page fix** (R14-m2). The boot-stub 1 GiB huge-page entries in PML4[0]/PML4[256] would be clobbered when the walker descends looking for a 4 KiB PT. Every ring-3 mapping path routes through `aspace_map`, so this is upstream of all m8 work.
2. **TSS + `ltr`** (#424, blocked on PA-R13-001 / paideia-as #914). Ring-3 → ring-0 exception delivery requires TSS.RSP0 to point at a valid ring-0 stack; without an installed TSS the CPU triple-faults on the first ring-3 exception.
3. **User linker + `build/shell.bin` build step.** `tools/build.sh` has no discipline for compiling `src/user/*.pdx` under a user-space linker script, running `objcopy -O binary`, and `.incbin`-ing the result into `kernel.elf`.
4. **cap_smoke migration** (#482). Real ring-3 first-jump requires `KIND_PROCESS OP_CREATE` to return a fresh pid, which breaks the R8 fingerprint's slot-0 = 0xCAFE assertion.

Straight ordering: (1) unblocks (2) unblocks (3) unblocks a functional (4). R14-m1..m4 will resolve them in that order, then land the m8 bundle.

---

### Deferred Rev-1/Rev-2 Milestones

**Rev-1 m8 shell v2 (#438/#439):** Closed as deferred per #483 — no `sys_read` in §C.
**Rev-1 m9 smoke (#440/#441):** Closed as deferred — depends on landed ring-3.
**Rev-2 m9 VFS (#456–#460):** Closed as deferred (bundle #485). Depends on ring-3, file cap layer, and blockdev backend.
**Rev-2 m10 fork/exec/wait (#461–#465):** Closed as deferred (bundle #486). Blocked on PA-R13-012 (paideia-as #925: `xchg` / `lock cmpxchg` / `lock` prefix not encoded) — spinlock-free implementations are unsafe under multicore.
**Rev-2 m11 signals (#466–#469):** Closed as deferred. Requires `sys_signal_register` / `sys_signal_return` from §C, plus signal-frame push infrastructure.
**Rev-2 m12 exec builtin (#470):** Closed as deferred. Requires m10 exec.
**Rev-2 m13 multicore (#471–#476):** Closed as deferred. Blocked on PA-R13-012 + `gs:` prefix + `mfence`.
**Rev-2 m14 preemption to ring-3 (#477/#478):** Closed as deferred. Requires TSS + real `sched_preempt_to` under ring-3 frames.
**Rev-2 m15 smoke (#479):** Closed as deferred. Bundle-level fixture for all Rev-2 landings.

---

## Design Decisions Pinned

1. **§C as the frozen syscall interface** (over round-plan §4 wording drift). Backtracking #481 records the reconciliation: the preflight §C 13-entry table (sys_exit_thread, sys_yield, sys_ipc_send, sys_ipc_recv, sys_cap_invoke, sys_cap_mint, sys_cap_query, sys_signal_register, sys_signal_return, sys_cpu_id, sys_sipi_target, sys_kpti_enable, sys_debug_puts) is the source of truth. §J POSIX shim is not adopted at R13.

2. **SYSRET-first GDT layout.** GDT slots derive from SYSRET's `STAR[47:32]+16 → user CS, STAR[47:32]+8 → user SS` rule; user data at 0x20 and user code64 at 0x28 satisfy the layout with STAR[47:32]=0x0018. Kernel code64 fixed at 0x08 (with L=1) closes a latent code32/code64 mismatch present since the boot-stub GDT.

3. **13-entry linear cmp/je syscall dispatch** (over indirect table). 13 is small; direct branches are debuggable and cheap; a jump-table with `mov rax, [table + rdi*8]; jmp rax` requires `.rodata` layout that's cleaner once the table stabilises. R14 will re-architect once the ENOSYS entries land real bodies.

4. **Cap-dispatch: direct-branch chain preserved from R12.** Extended from 4-way to 10 real + 2 structural branches. Handler-table migration (R12 boundary #7) not undertaken at R13; direct chain is still legible at 10-way. A2 migration deferred to R15+ once kind count and handler-hot-path profile stabilise.

5. **Structural stubs pin data models before dispatch.** KIND_PROCESS (#430) and KIND_PAGE_TABLE (#451) landed pool declarations, byte offsets, and R14 follow-up plans without wiring dispatch branches. This preserves the boot fingerprint (kind=1, kind=3 fall through to R8 MVP returning target_ptr) while committing the layout so R14 handler landings are additive rather than exploratory.

6. **Per-CPU BSP-only allocation for R13.** IA32_KERNEL_GS_BASE points at `_cpu0_kernel_gs`; `_syscall_kernel_stack` is a single 16 KiB array; `_saved_user_rsp` is a single u64 slot. Multi-CPU replication is Rev-2 m13's job. Documented as an R13 data race that is unreachable while the trampoline is unreachable.

7. **User source tree lives, kernel build ignores it.** `src/user/*.pdx` exists as a §C-native reference; `tools/build.sh` globs only `src/kernel/`. R14-m3 lands the user linker discipline.

8. **PML4[256] alias installed, kernel VMA move deferred.** m3-001 Phase 1 populates PML4[256] to mirror PML4[0]. Phase 2 (linker script move to 0xFFFF_8000_0010_0000 + far-jmp transition) is #480, deferred to R14. Every downstream mapping / KPTI landing assumes the Phase-2 kernel VMA; Phase-1 keeps execution safe in the low identity map until then.

---

## Observable Proof

### boot_r12 Fingerprint (Byte-Identical Across R13)

R13 elected **no new fingerprint**. The R12 13-line output is the R13 regression guard:

```
B                    ← boot-stub 'B'
PaideiaOS R8         ← banner
CAP OK               ← cap_smoke (unchanged mints, unchanged expectations)
IPC OK               ← ipc_smoke
CAP INVOKE MEM       ← cap_dispatch_smoke slot 4 (KIND_PAGE)
CAP INVOKE IPC       ← slot 5 (KIND_IPC_ENDPOINT)
CAP INVOKE SCHED     ← slot 6 (KIND_SCHED_CTX)
CAP INVOKE DEV       ← slot 7 (KIND_DEVICE)
CAP DISPATCH OK      ← aggregate success + denial witness
IDT OK               ← idt_install
TASK A / TASK B / TASK A   ← R10 cooperative multitasking
```

**Non-emission proof (falsifiability inverted):** If any of the five real R13 handlers (THREAD, IPC_PORT, TIMER, NOTIFICATION, REPLY) had emitted its tag at boot, that would prove a `cap_smoke` regression. The absence of `CAP INVOKE THREAD` / `PORT` / `TIMER` / `NOTIF` / `REPLY` from the fingerprint is precisely the R13-partial-closure reality: the code paths exist, are correctly linked into the dispatch chain, and are dead code because no fixture mints those kinds. R14 lands the fixtures.

### 5-mode regression matrix

| Mode | R13 result | Notes |
|---|---|---|
| boot_r8_only | PASS × 3 | R8 subsystems byte-identical |
| boot_r10 | PASS × 3 | Cooperative alternation unchanged |
| boot_r11 | PASS × 3 | Preemptive alternation unchanged |
| boot_r12 | PASS × 3 | 13-line R12 fingerprint byte-identical |
| boot_r12_denial | PASS × 3 | Rights-enforcement witness preserved |

**Aggregate: 15/15 PASS across every R13 landing.** Every audit's "Regression" section reads "Fingerprints byte-identical." That is the observable proof of *R13 as substrate*, not *R13 as feature*.

---

## Cross-Repo Work

Four paideia-as escalations filed under PA-R13; one withdrawn:

| Escalation | paideia-as encoder | Issue # | R13 impact | Status |
|---|---|---|---|---|
| PA-R13-001 | `ltr r16` (load task register) | #914 | Blocks m4-002 (#424) TSS install → gates ring-3 exception delivery | OPEN (blocks R14 m4-002 landing) |
| PA-R13-009 | `sysret` / `sysretq` | #922 | Believed missing during m5-001; reverified present | **WITHDRAWN as invalid** |
| PA-R13-010 | `sub reg, imm` | #923 | Blocks natural `pid - 1` slot arithmetic; workaround `add r, 0xFF...FF` accepted | OPEN, workaround used |
| PA-R13-011 | Back-to-back label sharing | #924 | Blocks shared error-tail labels in real handlers; workaround duplicate-block | OPEN, workaround used |
| PA-R13-012 | `xchg [mem], reg` / `lock cmpxchg` / `lock` prefix | #925 | Blocks spinlocks → blocks Rev-2 m10 (fork/exec/wait), m13 (multicore) | OPEN (blocks R14 m10 + m13 landings) |

**Submodule pin:** `tools/paideia-as` at ae6039b (v0.11.0+28); no bump required for R13 landings.

**Backtracking issues filed (paideia-os side):**

- **#480** — m3-001 Phase 2 higher-half VMA relocation. Deferred to R14.
- **#481** — plan §4 m5-003 wording drift; §C is source of truth. **RESOLVED** in commit 40af7ae.
- **#482** — cap_smoke migration for real KIND_PROCESS handler landing. Deferred to R14.
- **#483** — R13 user-shell §C drift record (no `sys_read`/`sys_write`). Closes Rev-1 m8/m9.
- **#484** — m8 kernel-user transition deferral bundle. R14-m4.
- **#485** — Rev-2 m9 VFS deferral bundle. R14-post-m8.
- **#486** — Rev-2 m10 fork/exec/wait/cleanup deferral bundle. Blocked on PA-R13-012.

---

## Boundaries Carried Forward to R14

R14's job is to close the ring-3 boundary that R13 built the substrate for. Ordered dependencies:

1. **TSS + `ltr` install** (#424; blocked on paideia-as #914 landing `ltr r16`). Every downstream ring-3 landing needs TSS.RSP0.
2. **`aspace_map` huge-page fix.** Either detect PS=1 entries and skip / split, or restrict user mappings to 4 KiB-only VA ranges. Unblocks m8-001 and real `OP_MAP_MMIO`.
3. **Higher-half kernel VMA relocation (Phase 2 of m3-001).** Move kernel `.text`/`.data` to 0xFFFF_8000_0010_0000 with far-jmp transition; retire the low-VA identity map for kernel code.
4. **User linker + `build/shell.bin`.** Compile `src/user/*.pdx` under a user-space linker script, `objcopy` to raw binary, `.incbin` into `kernel.elf`. Discipline in `tools/build.sh`.
5. **cap_smoke migration** (#482). Migrate the slot-0 assertion off of KIND_PROCESS so the R8 fingerprint tolerates a real fresh-pid return.
6. **Real m8 (kernel-user transition):** ELF-lite load of `shell.bin`; user-page-table build; ring-3 first-jump via SYSRET into shell `_start`. Observable payoff: `PaideiaOS shell v0.1\n` on COM1 from ring 3.
7. **Structural-stub promotions to real handlers:** KIND_PROCESS (#482 unblocks), KIND_PAGE_TABLE (args-encoding decision + current-aspace API), KIND_INTERRUPT (`_irq_notification_map` + ISR post path).
8. **Rev-2 milestones** — m9 VFS, m10 fork/exec/wait, m11 signals, m12 exec builtin — cascade after ring-3 lands and PA-R13-012 (paideia-as #925) provides atomic primitives.
9. **Rev-2 m13 multicore** — SIPI, per-CPU GS data, TLB shootdown — deferred pending PA-R13-012 + `gs:` prefix + `mfence`.
10. **Interactive shell v2** — real `sys_read`, decimal parsing, `cap N M` builtin — closes Rev-1 m8 deferral (#483).

---

## Verification Results

**No new fingerprint added.** R13's regression envelope is the R12 5-mode matrix run against every landing. Every audit entry's "Regression" section attests "Fingerprints byte-identical across 5-mode smoke suite." This is not a weakness — it is precisely how a substrate round proves it did no harm.

- Boot-r12 fingerprint (13 lines): PASS on every R13 commit.
- boot_r12_denial (rights-enforcement witness): PASS on every R13 commit.
- boot_r8_only / boot_r10 / boot_r11: PASS on every R13 commit.
- **Aggregate:** 15/15 PASS on the closure commit set.

**Perturbation surface:** `.bss` growth from R13 additions is ~10 KiB (pools for THREAD, IPC_PORT, TIMER, NOTIFICATION, REPLY, PROCESS + syscall stack + saved-rsp + IST stacks + phys pool growth). `.rodata` growth is ~200 bytes for tag strings and syscall constants. `.text` growth is dominated by the syscall trampoline + 5 real handlers (~1200 bytes). None of these perturbations reach the fingerprint bytes.

---

## Audit Trail

R13 audit entries (28 files under `design/audit/entries/`):

- **M1:** r13-m1-002-arch-pins.md (7-decision pin document)
- **M2:** r13-m2-001-phys-alloc.md, r13-m2-002-aspace-map.md, r13-m2-003-aspace-create.md, r13-m2-004-aspace-unmap.md, r13-m2-005-buddy-allocator.md
- **M3:** r13-m3-001-hh-alias.md, r13-m3-002-kpti-pgd-copy.md, r13-m3-003-smep.md, r13-m3-004-smap.md, r13-m3-005-nx.md
- **M4:** r13-m4-001-gdt-install.md, r13-m4-003-ist-stacks.md, r13-m4-004-idt-ist-rewire.md, r13-m4-005-mmio-mapping.md
- **M5:** r13-m5-001-syscall-msrs.md, r13-m5-002-syscall-trampoline.md, r13-m5-003-syscall-table.md
- **M6:** r13-m6-001-kind-process.md, r13-m6-002-kind-thread.md, r13-m6-003-kind-page-table.md, r13-m6-004-kind-ipc-port.md, r13-m6-005-kind-timer.md, r13-m6-006-kind-interrupt-notification.md, r13-m6-007-kind-reply.md
- **M7:** r13-m7-001-shell-main.md, r13-m7-002-syscall-shim.md, r13-m7-003-io-builtins.md

---

## Status Summary

**R13 CLOSED (PARTIAL):**

- **Landed:** 15 issues across M1–M7 as real bodies or structural stubs with pinned data models.
- **Deferred to R14:** 22 issues across M8, Rev-1 M8/M9, Rev-2 M9–M15, and open substrate item #424. Bundled deferral records #481–#486.
- **Regression envelope:** boot_r12 fingerprint byte-identical across every landing (15/15 across the 5-mode matrix).

**What R13 shipped (honest inventory):**

- Cap-dispatch surface extended from 4 kinds to 10 real + 2 structural stubs.
- SYSCALL/SYSRET fast path built end-to-end: 5 MSRs + real trampoline + 13-entry syscall table per §C.
- MMU-hardening perimeter: PML4[256] alias, KPTI PGD-copy stub, SMEP + SMAP + NX + real GDT + IST stacks + IDT-IST rewire.
- User-space source tree under `src/user/` (§C-native, straight-line demonstrative main; not compiled at R13).

**What R13 did NOT ship (round-over-round scope reality):**

- **No ring-3 execution.** Ring-3 was the R13 headline objective; it did not land.
- **No interactive shell.** The shell binary exists in source but is not linked, loaded, or entered.
- **No VFS, no fork/exec/wait, no signals, no multicore, no ring-3 preemption.** All Rev-2 milestones closed as deferred.
- **No boot-observable proof of any R13 handler or the syscall table.** All new dispatch and syscall code is reachable but dead in the 5-mode smoke suite.

**Round-over-round scope statement:** R13 was scoped as a full userspace + shell OS. Ring-3 was blocked on a substrate chain (TSS+`ltr` encoder, `aspace_map` huge-page collision, user-linker discipline, cap_smoke migration) that R13 uncovered by trying to reach it. R13 instead landed the cap-dispatch surface, the syscall entry path, the MMU-hardening perimeter, and the user-space source tree — the substrate that R14 will execute against. Real ring-3 lands in R14.

**Pre-push hook:** Unchanged from R12 — four modes (boot_r8_only, boot_r10, boot_r11, boot_r12).

**Microkernel discipline (Pillar 3):** Extended in surface (dispatch chain now covers 10 real kinds + 2 structural stubs) but unchanged in reach (no new kind is minted at boot; no ring-3 code invokes any). Reach lands with R14 ring-3.

**Next Round:** R14 (Ring-3 First-Jump + Real m8 + Structural-Stub Promotions) — See forthcoming `design/milestones/r14-kickoff.md`.

---

**Milestone:** R13
**Related Issues:** #417–#455, #480–#486, #914, #923, #924, #925
**Author:** Santiago Nunez-Corrales
**Date:** 2026-07-03
