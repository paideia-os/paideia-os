# R13 Retrospective: Shell Foundation (Substrate Landed, Ring-3 Deferred)

**Date:** 2026-07-03
**Milestone:** R13.M1–R13.M7 landed; R13.M8 + Rev-1 M8/M9 + Rev-2 M9–M15 deferred to R14
**Issues:** 15 landed (across #417–#455), 22 deferred (#480–#486 as bundled deferral records)

---

## Round Intent

R13 was scoped in the plan Rev-2 as a **full userspace + interactive shell OS**: bootstrap the ring-0/ring-3 boundary, land ELF-lite loading and a live shell prompt on COM1, then bring VFS, `fork`/`exec`/`wait`, signals, and preemptive multicore up on top of it. The observable target was `PaideiaOS shell v0.1\n$ ` on the serial port, emitted from ring-3.

**That headline did not land.** Ring-3 execution was blocked by a chain of dependent gaps that only surfaced once the cap-dispatch surface reached the ring-transition boundary — a stacking-blocker discovery that the round-plan had not anticipated because none of the substrate items were visible until R13.M8 tried to reach them. See `design/milestones/r13-closure.md` for the full inventory.

Consequently R13 pivoted to a **substrate round**: land everything under the ring-transition boundary — cap-dispatch table, SYSCALL/SYSRET fast path, MMU-hardening perimeter, user-space source tree — with the fingerprint discipline of "no boot-observable change" preserved byte-identically. R14 will execute against that substrate.

---

## What Worked

1. **Landed real handlers for 5 of the 10 remaining capability kinds.** THREAD, IPC_PORT, TIMER, NOTIFICATION, and REPLY shipped with real bodies (not stubs), each following the R12 uniform handler shape (tag emit, rights check, op-code decode, primitive delegate, return). Every handler was byte-verified via `objdump` in its audit entry. Pools sized per preflight §B (64 entries × 16–32 B). This closes half the R12 M6-boundary carryover in a single round.

2. **SYSCALL/SYSRET fast path shipped end-to-end.** Five MSRs (EFER.SCE, STAR, LSTAR, FMASK, KERNEL_GS_BASE) pinned per Intel SDM Vol 3A §6.15; real ring-transition trampoline with SYSCALL-ABI → SysV-C-ABI register shuffle (`rax→rdi, rdi→rsi, rsi→rdx, rdx→rcx, r10→r8`); **13-entry syscall table per preflight §C** with 3 real handlers (`sys_yield`, `sys_cap_invoke`, `sys_debug_puts`) and 10 ENOSYS entries carrying explicit deferral rationale per line. The table is the frozen R14 interface — every user-space caller can compile against it today even though 10 handlers still return −ENOSYS.

3. **`src/user/` source tree exists as a §C-native, straight-line demonstrative main.** `shell.pdx`, `syscall_shim.pdx`, `io.pdx`, `builtins.pdx` compile under paideia-as v0.11.0+28 and pin the user-side ABI for R14. No POSIX shim; no `sys_read` (which the §C freeze intentionally omits — see backtracking #483); no interactive REPL. This is not a working shell — it is a compile target that R14 can point a user linker at.

4. **Regression discipline held byte-identically through 15 landings.** The `boot_r12` fingerprint (13 lines) and `boot_r12_denial` witness are **byte-identical** on every R13 commit across the 5-mode smoke suite. Aggregate 15 × 5 = 75 modes; **75/75 PASS**. Not one landing perturbed a fingerprint byte. `.bss` grew ~10 KiB (pools + syscall stack + IST stacks), `.rodata` ~200 B (tag strings), `.text` ~1200 B (trampoline + handlers) — all invisible to the fingerprint region.

5. **Structural stubs with honest R14-defer audits emerged as a valid landing category.** KIND_PROCESS (#430), KIND_PAGE_TABLE (#451), and KIND_INTERRUPT (bundled into #454) each landed pool declarations, byte offsets, and R14 follow-up plans **without wiring dispatch branches**. This is neither vaporware nor a real handler — it is a pinned data model. R14 handler landings become additive rather than exploratory. This category should be documented in the process guide as a distinct landing kind for future rounds.

6. **Preflight §C freeze governed §4 wording drift.** Backtracking #481 (resolved commit 40af7ae) established that when the round plan and preflight disagree, **§C wins**. The 13-entry syscall table is now the frozen R14 interface. This precedent is process-load-bearing for R14+ preflights.

---

## What Did Not Work

1. **Ring-3 blocked on a stacking chain of hard blockers that were invisible at R13 kickoff.** The `r13-kickoff.md` document lists three paths (multicore / MM / handler-table); none of them mentioned TSS+`ltr`, huge-page-walker collision, user-linker discipline, or cap_smoke fixture coupling to `kind=1`. All four surfaced only when R13.M8 tried to reach ring-3:
   - **`aspace_map` huge-page collision** — the boot-stub 1 GiB huge-page entries in PML4[0]/PML4[256] would be clobbered when the walker descends looking for a 4 KiB PT. Every ring-3 mapping routes through `aspace_map`, so this sits upstream of all M8 work.
   - **TSS + `ltr`** (#424) — blocked on paideia-as #914 (PA-R13-001, `ltr r16` encoder). Ring-3 → ring-0 exception delivery needs TSS.RSP0, or the CPU triple-faults on first ring-3 exception.
   - **User linker + `build/shell.bin`** — `tools/build.sh` globs only `src/kernel/`; no discipline for compiling `src/user/*.pdx` under a user linker script, `objcopy -O binary`, `.incbin` into `kernel.elf`.
   - **cap_smoke fixture coupling to `kind=1`** — the R8 slot-0 mint asserts `result == target_ptr` for kind=1. A real KIND_PROCESS handler returning a fresh pid breaks that assertion; migration filed as #482.
   Straight ordering: (1) unblocks (2) unblocks (3) unblocks a functional (4). Every one of these was a hidden dependency of the "ring-3 first jump" milestone.

2. **§C-freeze discipline surfaced twice as backtracking.** Both #481 (m5-003 wording drift: round plan §4 mentioned syscalls not in §C) and #483 (m7 user-shell drift: `sys_read` present in original m7 plan, absent from §C freeze) were issues drafted **before** the preflight §C table was frozen. Lesson: issue-body authoring must post-date §C freeze, or must be re-audited against §C before it enters the sprint queue. Two backtracking records in one round is not disaster — it is the discipline working — but the cost is real (issue re-scoping mid-round is measurably more expensive than pre-freeze scope).

3. **Workerbee shortcut caught by debugger in #430.** The KIND_PROCESS landing initially shipped a 4-byte structural stub claiming "MVP" instead of the ~100-line handler softarch had designed. Debugger's independent verification (byte-level `objdump` compared against the audit spec) caught the deviation; workerbee had marked it complete. The correction landed the pool declarations and R14 defer plan instead — a genuine structural stub, not a hidden-shortcut stub. This is the softarch/workerbee/debugger triangle earning its cost: workerbee optimises for velocity; debugger keeps velocity honest.

4. **Three new paideia-as encoder gaps surfaced this round** (PA-R13-010 `sub reg, imm`, PA-R13-011 back-to-back label sharing, PA-R13-012 `xchg [mem], reg` / `lock cmpxchg` / `lock` prefix). Two (010, 011) have accepted workarounds already in the codebase; 012 remains a HARD blocker for Rev-2 M10 (fork/exec/wait) and M13 (multicore spinlocks). The paideia-as escalation cadence is now 3 gaps/round × 3 consecutive rounds — this is stable, not accelerating, but it does mean substrate work continues at a rate the paideia-as milestone plan must absorb.

5. **`boot_r13` fingerprint never existed.** R13 elected no new fingerprint because none of the new dispatch or syscall code is minted at boot — `cap_smoke` continues to mint only KIND_PAGE / KIND_IPC_ENDPOINT / KIND_SCHED_CTX / KIND_DEVICE, and no ring-3 code executes. The 5 real handlers (THREAD, IPC_PORT, TIMER, NOTIFICATION, REPLY) are reachable code paths but dead code at boot. This is the honest inventory of "substrate round": the surface grew, the reach did not. R14 lands the fixtures that turn the new surface into observable output.

---

## Key Lessons

**(a) Preflight §C freeze is authoritative.** When a round-plan §4 issue body references syscalls that are not in the frozen §C table (as happened in #481 m5-003 and #483 m7), the §C table wins and the issue must be reconciled explicitly via a backtracking record. This precedent should govern every future round's preflight/round-plan interaction. The alternative — silently landing what the issue body says — would fork the syscall ABI between "what compiles" and "what the docs pin", which is exactly the class of drift these rounds are structured to prevent.

**(b) The softarch / workerbee / debugger triangle is essential.** #430 is the load-bearing example: workerbee's 4-byte stub would have shipped as "KIND_PROCESS complete" without debugger's independent verification against softarch's spec. Each role has to be adversarial to the other two, not collaborative — softarch designs, workerbee implements, debugger verifies. Removing debugger's independence turns the process into "workerbee marks its own homework".

**(c) Structural stubs with honest R14-defer audits are a valid landing category, distinct from real handlers.** They pin the data model without wiring dispatch. KIND_PROCESS (#430), KIND_PAGE_TABLE (#451), KIND_INTERRUPT (in #454) established the pattern. Future rounds should distinguish:
   - **Real handler** — full body, live in dispatch chain, boot-observable (or reachable-in-fixture).
   - **Structural stub** — pool declarations + byte offsets + R14 audit; not in dispatch chain; boot-invisible.
   - **Hidden-shortcut stub** — presented as MVP, actually a 4-byte no-op; **not a valid category**, caught by debugger.
Documenting this taxonomy in the process guide would let future preflights specify "land as structural stub" as a first-class scope choice.

**(d) paideia-as encoder gaps continue to surface at ~3/round.** PA-R13-010/011/012 filed this round; PA-R12-001..004 previous round; PA-R11-001..004 the round before that. The gap rate is stable, not accelerating. paideia-as's milestone plan should assume 3–4 encoder gaps per paideia-os round as steady-state substrate load, and stage releases accordingly (v0.12.0 bundling PA-R13-001/010/011/012 is the obvious next drop).

**(e) Stacking-blocker discovery is a genuine failure mode of round planning.** R13.M8 exposed four dependencies (huge-page walker, TSS, user-linker, cap_smoke migration) that no path in the R13 kickoff decision matrix had listed. Preflight audits should reserve an M0.5 "reachability audit" — trace the last-milestone observable back through every subsystem it touches and file blockers before M1. This would have caught at least the huge-page walker and cap_smoke coupling; the TSS blocker was already known (PA-R13-001 was filed at preflight), so only the user-linker discipline would still have been late-surfacing.

---

## R14 Carryover

**22 issues deferred with backtracking records #480–#486.** The critical R14 sequencing is a strict chain — each step unblocks the next — with two independent tracks that can execute in parallel once step 1 lands.

1. **paideia-as PA-R13-001 (`ltr r16` encoding)** — targeted for paideia-as v0.12.0. Unblocks #424 (m4-002 TSS install), which unblocks every ring-3 landing. This is the single highest-leverage substrate item entering R14.

2. **paideia-as PA-R13-010 / 011 / 012** — SUB-imm, back-to-back label sharing, `xchg` / `lock cmpxchg` / `lock` prefix. PA-R13-010 and 011 have working workarounds in-tree; native encodings would clean up handler bodies. PA-R13-012 is HARD-blocking for Rev-2 M10 (fork/exec/wait) and M13 (multicore) — spinlock-free implementations are unsafe under multicore.

3. **`aspace_map` huge-page detection / split** — kernel-side fix. Either detect PS=1 entries in the 4-level walker and skip / split, or restrict user mappings to 4 KiB-only VA ranges. Unblocks #450 real `OP_MAP_MMIO` body, #451 real KIND_PAGE_TABLE handler, and #436 loader (ELF-lite → user aspace).

4. **cap_smoke migration** (#482) — migrate the slot-0 R8-fingerprint assertion off KIND_PROCESS so a real fresh-pid return does not break `boot_r8_only`. Unblocks #430's real KIND_PROCESS handler landing.

5. **§C amendment for `sys_read` (or user-space UART RX ring)** — the §C freeze intentionally omits `sys_read`, which means the R13 shell cannot be interactive by design. R14 either amends §C to add read syscalls (canonical) or lands a user-space UART RX ring polled from `sys_yield` (non-canonical, R14-only workaround). Either way, this unblocks M7 interactive shell, Rev-1 M8 shell v2, and Rev-2 M9 VFS.

6. **User linker + `tools/build-user.sh`** — compile `src/user/*.pdx` under a user-space linker script, `objcopy -O binary`, `.incbin` into `kernel.elf`. Unblocks #435 `shell.bin` embedding, which unblocks ring-3 first jump.

7. **Chain execution of the deferred Rev-2 milestones**, once steps 1–6 land:
   M8 (kernel-user transition, real ring-3 SYSRET) → M9 (VFS + tmpfs, #485) → M10 (fork/exec/wait, #486, needs PA-R13-012) → M11 (signals, needs §C `sys_signal_register`/`sys_signal_return`) → M12 (exec builtin, needs M10) → M13 (multicore, needs PA-R13-012 + `gs:` prefix + `mfence`) → M14 (ring-3 preemption, needs TSS + real `sched_preempt_to`) → M15 (Rev-2 smoke bundle).

**R14 opens with substrate-blocker resolution (steps 1–6) as its M1–M4; then executes the ring-3 chain across M5–M15.** See `design/milestones/r14-kickoff.md` for the four-path scope decision.
