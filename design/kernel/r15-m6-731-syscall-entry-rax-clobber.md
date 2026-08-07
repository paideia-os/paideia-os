---
issue: 731
milestone: R17.M0 (post-#730 D10; hidden-foundation cleanup blocking #723 truth)
subsystem: 9 — syscall entry / exit trampoline (strict-KPTI hazard)
prereq:
  - "#502 (R14b-m4-006: syscall_entry CR3 save/flip landed the epilogue that hides this bug)"
  - "#724 D4 / #626 (entry-side rax clobber — same shape, opposite direction)"
  - "#728 D9 (per-task kstack + TCB-derived user_pml4 in the epilogue — set the immediate context for the exit-side rax clobber this fix addresses)"
  - "#730 D10 (execve completes; child_hello reaches ring-3 — provides the wire signal needed to observe the epilogue's return value at all)"
blocks:
  - "#723 AC (the fake-green `WAIT: pid=2 status=42` line — #731 makes it fail honestly, unmasking #732)"
  - "#732 (wait4 -EFAULT on init's wait_status pointer — invisible until #731 stops clobbering rax)"
  - "#733 (any other syscall whose return value was silently masked, e.g. fork's child pid observed by parent, write's byte count, execve's error path — each is a separate follow-up if wired to a wire-visible check)"
touching:
  - src/kernel/core/syscall/entry.pdx           (save rax after dispatch, reload before sysret)
  - src/kernel/core/syscall/trampoline_data.pdx (new _saved_syscall_ret_rax slot)
  - tests/r17/expected-boot-r17-init.txt        (remove fake WAIT/REAPED lines; honest post-fix fingerprint)
  - design/kernel/r15-m6-731-syscall-entry-rax-clobber.md (this doc)
related:
  - design/kernel/r17-m0-724-d4-init-post-iretq-gp.md   (entry-side twin of this bug — same fix pattern)
  - design/kernel/r17-m0-728-d9-sys-exit-sched-switch-ud.md  (introduced the three-`mov rax` epilogue sequence that materialised this bug's clobber)
  - design/kernel/r17-m0-730-d10-execve-complete.md     (§12 D13 filed the "rax leaks user_pml4_pa" note as a nice-to-have — #731 elevates it to root-cause status)
---

# R15-M6-731 — `syscall_entry` epilogue clobbers rax across CR3 flip: every syscall return value masked with `user_pml4_pa`

## 1. Scope

Fix `src/kernel/core/syscall/entry.pdx`'s epilogue so that whatever value
`syscall_dispatch` returned in `rax` actually survives to userspace via
`sysret`.

Pre-fix, the epilogue unconditionally overwrites `rax` with `user_pml4_pa`
between the dispatch's `ret` and `sysret`. Every syscall on every ring-3
task, since commit `397d9ed` (#502 / R14b-m4-006 landed the epilogue in Nov
'25) has silently returned `user_pml4_pa` to userspace instead of the real
result. Negative errnos were masked into small-positive garbage; real
return values (fork's child pid, write's byte count, execve's success
signal) were lost.

Wire evidence and root-cause diagnosis credit: the debugger's live
instrumentation session on the #730 D10 adversarial-verify follow-up, whose
sub-issue #731 was carved out of. This landing is the fix and honest
regression-baseline for that finding.

Explicitly out of scope (each filed as a distinct followup — see §7):

- **#732** — wait4 returns -EFAULT on init's `wait_status` pointer. Only
  visible now that this fix stops masking it. Not fixed here.
- **#733 (family)** — any other syscall whose return path had a wire-visible
  consumer masked by this bug. Trip each when it surfaces.
- Sanitising other user-visible caller-save GPRs (rdi, rsi, rdx, r8, r9,
  r10) on sysret. Same shape (kernel state leaks to userspace), but
  independent bug — the `syscall_dispatch` handlers leave stale kernel
  scratch in these regs and this fix does nothing about it. Filed as #728
  D13 successor.

## 2. Empirical evidence

### 2.1 Fingerprint mismatch on post-fix boot (the intended, honest failure)

Pre-fix `boot_r17_init`:

```
INIT ENTERED RING3
INIT OK
CHILD HELLO 42
WAIT: pid=2 status=42
REAPED
```

Post-fix `boot_r17_init`:

```
INIT ENTERED RING3
INIT OK
CHILD HELLO 42
<END OF LOG>
```

The AC-line ("WAIT: pid=2 status=42") DISAPPEARS on the fix. That is the
correct outcome. The pre-fix run only printed it because init's guard
```
call sys_wait4
cmp rax, 0
jl init_shutdown        # -> sys_exit(0), no WAIT printed
```
never fired: the real `sys_wait_body` was returning `-14` (EFAULT — #732),
but the epilogue clobbered `rax` to `user_pml4_pa` (~0x2ea000 on this
build), which is positive, so `jl` fell through and init happily printed
its fake AC line on top of a hard-failed syscall.

### 2.2 Debugger's live instrumentation (from the #731 D-run this landing consumes)

The debugger ran GDB-attached QEMU under `-d int,cpu_reset` with a
watchpoint on `_saved_user_rsp` and a breakpoint on the `mov cr3, rax`
just before `sysret`. Per the report handed to this landing:

- `call syscall_dispatch` returned with `rax = -14 = 0xFFFFFFFFFFFFFFF2`
  on init's wait4 syscall (matching `sys_wait_body`'s -EFAULT branch, per
  #732's still-buggy `user_ptr_ok(wait_status, 4)` failure).
- At the `mov cr3, rax` breakpoint, `rax = 0x2ea000` (a small positive
  number in `phys_alloc`'s early-allocated user PML4 range).
- The three `mov rax, ...` instructions between them (lines 115-119
  of entry.pdx) each unconditionally overwrite `rax`.
- `sysret` places whatever `rax` holds at that instant into user rax.
  Userspace observed `0x2ea000`, not `-14`.

### 2.3 Root cause pinpointed to lines 99-126 of entry.pdx

Pre-fix epilogue:

```
call syscall_dispatch;              // (1) rax = real return value
pop r11;                            // (2)
pop rcx;                            // (3)
mov rax, [rip + _current_tcb];      // (4) CLOBBER 1: rax = &current_tcb
mov rsp, [rax + 104];               // (5)
mov rax, [rax + 16];                // (6) CLOBBER 2: rax = user_pml4_va
mov r10, 0xFFFF800000000000;
sub rax, r10;                       // (7) rax = user_pml4_pa
mov cr3, rax;                       // (8) rax still = user_pml4_pa
swapgs;
sysret                              // (9) userspace sees rax = user_pml4_pa
```

Lines (4)-(8) form a five-instruction dance where `rax` is used as the
scratch conduit for computing `user_pml4_pa` from the TCB, then feeding it
to `cr3`. No other GPR was reserved for the return value between (1) and
(9). Result: every ring-3 syscall's return was silently replaced with
`user_pml4_pa`.

### 2.4 Why this hid across `#724 D1..D10` (all "wire-verified" landings)

Every kernel-side witness in the D1..D10 chain checks `klog` output, not
user `rax`. The child_hello exit-status witness (`WAIT: pid=2 status=42`)
appeared to work because:

- `sys_write(1, msg, 15)` in child_hello had its return value clobbered,
  but child_hello never checks the return; the UART side-effect (via
  `dispatch_write_uart`) happened regardless.
- `sys_exit(42)` never returns — `dispatch_exit` calls `sched_switch_r15`
  which never comes back to the syscall_entry epilogue for the exiting task.
- Init's `sys_wait4` DID return, and DID have its `rax` clobbered, but the
  clobbered value (a positive number) still passed init's `cmp rax, 0; jl`
  guard — the guard was written expecting -1 on error but received
  `+user_pml4_pa` on error. Init cheerfully printed WAIT on top of the
  masked EFAULT.

The bug is a textbook example of *silent success* — every witness said OK
because every witness only looked at kernel-emitted UART bytes, none looked
at what user rax actually held. #723's whole AC line was fake.

### 2.5 Age of the bug

Wire-traceable back to commit `397d9ed` (R14b-m4-006 / #502) which landed
the exit-side CR3 flip in Nov '25. Latent-until-exercised until #724 D2/D5/D6
landed init as the initial ring-3 task in Aug '26 — nine months of any
wire-level ring-3 caller silently misbehaving.

The exact three-`mov rax` sequence in the current epilogue is #728 D9 (Aug
2026); prior to D9 the epilogue used `mov rsp, [rip + _saved_user_rsp]` +
`mov rax, [rip + _saved_user_pml4]; mov cr3, rax`, which had the same
clobber (rax = _saved_user_pml4). The bug shape has been continuous since
#502.

## 3. Fix design

### 3.1 Options considered

**Option A — memory slot on trampoline data page (chosen).** Add a single
qword `_saved_syscall_ret_rax` to `trampoline_data.pdx`. Store rax
immediately after `syscall_dispatch` returns; reload from the slot
immediately before `sysret`. The slot is accessible in both PML4s (kernel
via higher-half identity at PML4[256]; user via PT[261] installed by
`kpti_build_user_pml4`), matching the pattern already used by
`_saved_user_rax` (D4), `_saved_user_rsp`, `_saved_user_pml4`, and
`_iretq_frame_scratch`.

**Option B — reserve a scratch GPR.** Candidates:
- `rcx` (dead until sysret loads user RIP from it — but we've already
  `pop rcx` in the epilogue, so rcx already holds user RIP at the point we'd
  need scratch).
- `r11` (same story — holds user rflags for sysret; dead through
  intermediate ops but sysret needs it).
- `r10` (SysV caller-save; not otherwise live at the epilogue). This is
  the only truly-free scratch, but it's already used in the current
  epilogue as the KERNEL_VMA_BASE constant loader (line 118 pre-fix).
  Rearranging to free r10 requires reordering the CR3 computation.
- Callee-save (`rbx`, `r12`-`r15`) — would need push/pop on the kernel
  stack, adding a matched pair of memory ops and burdening the small
  per-task kstack with epilogue framing. Trades one memory hop for two
  and needs additional stack-alignment care.

**Option C — swap the order.** Do the CR3 computation with `rax` freely,
then reload rax from a slot before sysret. Same as A in effect but
requires either a slot (equivalent to A) or a callee-save push (worse
than A).

### 3.2 Decision: Option A (memory slot)

Reasons the memory slot wins over the scratch-GPR approach:

1. **No register-liveness reasoning across the epilogue.** paideia-as has
   a documented history of silent miscompiles (see the workerbee memory
   note, the R14b-m4-006 `mov cr3, r9` REX.B gap noted in
   `enter_user.pdx`, the `4c 21` vs `4c 01` `AND` vs `ADD` opcode canary in
   `pt_walk.o`). Any register-reservation fix that assumes "no encoder
   quirk touches this reg between here and there" is fragile. A memory
   store is a distinct, easily-verified opcode.

2. **Pattern reuse.** `_saved_user_rax` on the entry side does exactly the
   same thing for exactly the same reason (D4). Making the exit side
   symmetric aids review — anyone reading either half of the trampoline
   sees the same idiom.

3. **Trivially survives CR3 flip.** The trampoline data page is mapped in
   both PML4s. No question about which CR3 is loaded at load or store time.

4. **Cost negligible.** One store + one load per syscall on a UP kernel.
   Both hit L1 (page is hot; already accessed for
   `_saved_user_rsp`/`_saved_user_pml4`/`_iretq_frame_scratch` on the
   same path). Trades one memory round-trip for immunity from an entire
   class of future encoder regressions.

### 3.3 Placement of the store and reload

**Store site**: immediately after `call syscall_dispatch;`, before
`pop r11; pop rcx`. Rationale:
- `call` return puts the u64 result in rax per SysV.
- The two `pop` instructions do not touch rax on x86-64 (they load into
  r11 / rcx respectively).
- Placing the store here bounds the window where any change could
  intercept rax to a single well-marked line.

**Reload site**: immediately after `swapgs`, immediately before `sysret`.
Rationale:
- `swapgs` swaps `IA32_GS_BASE`/`IA32_KERNEL_GS_BASE`. It touches no
  general-purpose registers.
- `sysret` reads `rcx` (→ user RIP) and `r11` (→ user RFLAGS) but does
  not touch `rax`.
- Placing the reload last means anything else in the epilogue is free to
  clobber rax without risk to the return value.

### 3.4 UP-single-slot safety

`_saved_syscall_ret_rax` is a single u64 shared across all tasks. Safe on
UP because:

- SYSCALL entry sets IF=0 via `IA32_FMASK` (kernel_main sets FMASK during
  MSR init).
- The epilogue completes atomically from userspace's POV: everything from
  `mov [rip + _saved_syscall_ret_rax], rax` through `sysret` runs under
  IF=0.
- No nested syscall on this CPU can concurrently touch the slot (nested
  syscall is impossible with IF=0; and even if a fault fired mid-epilogue
  the IST-swapped handler wouldn't run a SYSCALL).

SMP will require a per-CPU slot (identical rationale to the SMP note on
`_saved_user_rax`, `_saved_user_rsp`, and `_iretq_frame_scratch` — see
§14 of `r17-m0-724-d6-fork-enqueue.md`). This fix does NOT introduce new
SMP hazard beyond what those existing slots already have.

### 3.5 Total trampoline data page usage

Existing slots after this landing:
```
_saved_user_rsp        : 8 B
_saved_user_pml4       : 8 B
_kernel_pml4_pa        : 8 B
_iretq_frame_scratch   : 40 B
_user_cr3_save         : 8 B
_isr_scratch_rax       : 8 B
_saved_user_rax        : 8 B
_saved_syscall_ret_rax : 8 B (new)
--
Total                  : 96 B
```

Well within 4 KiB. No new PT[261] or PML4[256] entry needed — same page.

## 4. Interaction with #728 D13 (execve rax leak)

`design/kernel/r17-m0-730-d10-execve-complete.md` §12 filed **D13** as a
"nice-to-have": "zero user-visible caller-save regs on sysret from execve
(currently rax leaks the user_pml4_pa post-CR3-flip)".

**#731 fully subsumes the D13 concern for rax on execve.** `sys_execve_shim`
already sets `rax = 0` on success (via `xor rax, rax` at
`sys_execve_shim.pdx:308`). Pre-#731, that 0 was overwritten by the
epilogue's `user_pml4_pa` clobber before reaching sysret. Post-#731, the
epilogue preserves rax across the CR3 flip, so userspace observes rax=0
on execve success as intended by SysV / SC+ semantics.

D13's remaining concern — leaks in `rdi`, `rsi`, `rdx`, `r8`, `r9`, `r10`
— is NOT addressed by this fix. Those registers hold scratch values from
the dispatched syscall body (e.g., `sys_execve_shim` leaves `rbx` as
current-tcb pointer, `r14` as entry_rip, etc., and paideia-as-generated
`ret` pops the callee's own saved registers but does not clear caller-save
regs). File that as its own successor to D13 if a wire-visible leak
matters — it doesn't affect correctness of any current AC.

## 5. Interaction with SYSRET's user-visible register set

Intel SDM Vol 3A §5.8.8 (SYSRET — Return From Fast System Call), 64-bit
mode:

| Register | SYSRET effect |
|----------|---------------|
| CS.selector | Set from `IA32_STAR[63:48] + 16` (0x33 in current kernel) |
| SS.selector | Set from `IA32_STAR[63:48] + 8` (0x2B in current kernel) |
| RIP | Loaded from RCX |
| RFLAGS | Loaded from R11 (with reserved bits handled per SDM) |
| CPL | 0 → 3 |
| Other GPRs | UNTOUCHED (whatever kernel put there is what userspace sees) |

So sysret's ABI to userspace is: **RCX is user RIP, R11 is user RFLAGS,
everything else is whatever the kernel left in it**. For a correct kernel,
that means:
- **RAX** — must hold the syscall return value (this is what #731 fixes).
- **RBX, RBP, R12-R15** — callee-save under SysV. `syscall_dispatch` and
  its callees preserve these across `call`. They should reach sysret
  unchanged from what userspace stored on entry. (Verified: no epilogue
  op touches them post-#731.)
- **RDI, RSI, RDX, R8, R9, R10** — caller-clobbered. Kernel dispatch is
  free to trash them. Any residual kernel value leaks to userspace on
  sysret. That's a separate cleanup (D13 tail).

#731's fix places `mov rax, [rip + _saved_syscall_ret_rax]` after `swapgs`
and immediately before `sysret`, meeting the SDM's "RAX must hold the
return value at sysret" requirement.

## 6. Implementation delta

`src/kernel/core/syscall/trampoline_data.pdx` — one new pub let:
```
pub let mut _saved_syscall_ret_rax : [u64; 1] = uninit @align(8)
```
Full comment block describes the fix and cross-refs D4.

`src/kernel/core/syscall/entry.pdx` — two new instructions in the epilogue:

Right after `call syscall_dispatch;`:
```
mov [rip + _saved_syscall_ret_rax], rax;
```

Right after `swapgs;` and immediately before `sysret`:
```
mov rax, [rip + _saved_syscall_ret_rax];
```

The file-level `justification` string is updated to include the new step
numbering (10 = save ret, 16 = reload ret) and to reference #731.

`tests/r17/expected-boot-r17-init.txt` — lines 28-29 (`WAIT: pid=2
status=42` and `REAPED`) DELETED. Post-fix, init's `sys_wait4` correctly
surfaces its underlying EFAULT (#732), init's `jl init_shutdown` guard
correctly fires, and neither line is emitted. The fingerprint now reflects
this honest state. Follow-up #732 will restore a genuine `WAIT: pid=2
status=42` line once wait4's user_ptr_ok gate is fixed.

## 7. Follow-ups filed against this landing

- **#732** — `sys_wait_body` returns -EFAULT on init's `wait_status`
  pointer, blocking the honest post-#731 AC line. Now the primary blocker
  of the #723 AC; needs its own root-cause analysis (probably a
  `user_ptr_ok` gate that mis-computes the mapping under the parent's
  post-fork aspace, or a stale-mapping issue after `sched_block`).
- **#733** — audit every wire-visible caller of a syscall that was
  previously return-value-checked (init's `cmp rax` guards, any user
  syscall_shim.pdx call site) and confirm none regressed on real values
  now that returns are honest. `sys_fork`'s parent-side return of child
  pid → r12 was previously `user_pml4_pa`; init's parent path took the
  non-zero branch (correctly, by luck), and never used r12 subsequently
  — but a future wait4-of-specific-pid would need the real pid.
- **D13-tail** — zero (or explicitly sanitize) `rdi`, `rsi`, `rdx`, `r8`,
  `r9`, `r10` before `sysret` to close the caller-save leak surface.
  Not urgent (no current AC depends on it) but should land before any
  security-model verification.

## 8. Verification

### 8.1 Post-fix wire log

```
$ tools/run-smoke.sh boot_r17_init
smoke: fingerprint check passed (all 27 lines found in order)

$ tail -8 /tmp/paideia-os-smoke.log
R17 BIN CHILD HELLO SEED OK
INIT BOOT OK
INIT ENTERED RING3
INIT OK
CHILD HELLO 42
```

Log ends at `CHILD HELLO 42`. No trap frame, no EXC HALT after the init
chain. This is init reaching `init_shutdown → sys_exit(0)` correctly:
`sys_exit_body` marks init ZOMBIE, `runq_dequeue` removes it,
`sched_pick_next` returns `_idle_tcb`, `sched_switch_r15(idle)` transfers
control, and the CPU sits in `_idle_task`'s `hlt` loop until QEMU's 8-s
smoke timeout fires. Clean.

### 8.2 Full smoke matrix

All 19 modes PASS (18 modes plus `boot_tick`):

```
boot_min, boot_banner, boot_tick, boot_r8_only,
boot_r10, boot_r11, boot_r12, boot_r12_denial,
boot_r14b_hivma, boot_r14b_kpti, boot_r14b_ipi,
boot_r14b_loader, boot_r14b_ud,
boot_r15_ring3, boot_r15_process,
boot_r17_init, boot_panic, boot_panic_halt, boot_exc3
```

Pre-push 10/10 modes PASS.

### 8.3 Adversarial self-check (against the report's stated expectations)

Predicted post-fix behaviour (from #731 task brief):
- (a) init prints `INIT ENTERED RING3`, `INIT OK`, `CHILD HELLO 42` as
      before — CONFIRMED (all three on wire in order).
- (b) `WAIT`/`REAPED` do NOT print (because wait4 now correctly surfaces
      its EFAULT) — CONFIRMED (both absent from post-fix log).
- (c) System halts cleanly via `init_shutdown` — CONFIRMED (no trap frame,
      no EXC HALT; log terminates on QEMU smoke-timer expiry after init
      transferred to idle).

### 8.4 What #731 stops masking

Every one of #724 D1..D10's "wire-verified" landings was verified against
klog witnesses only, never against user rax. Post-#731, any regression in
a syscall's return value would produce either:

- an unexpected trap in userspace (guards previously bypassed will now
  fire on real error returns), OR
- a fingerprint diff (init's control flow changes as guards begin firing
  correctly).

Either surfaces on smoke. That's the actual regression base #723 needed
in the first place.

## 9. Softarch retrospective

### 9.1 Why this survived so long

Two compounding failures:

1. **Witness discipline**: every ring-3-facing landing wrote its witness
   as "kernel emits UART bytes when handler is invoked", never as "user
   observes the correct rax value on return". The kernel-side witness
   was true; the user-side effect was silently wrong. This is a
   structural gap in the test harness, not a coding oversight — it needs
   a userland verifier that reads `rax` and prints it back through a
   channel-independent path (perhaps sys_debug_puts with the u64 hex-
   formatted into a static buffer, then checked via fingerprint).

2. **The bug's shape rewarded coincidence**: `user_pml4_pa` happens to
   always be a small positive number (from `phys_alloc`'s early-fixed
   allocation). Every `cmp rax, 0; jl <errpath>` guard init had was
   written expecting -1 on error, but received a positive garbage value
   on error, which fell through to the success path. Bug-hides-bug.

### 9.2 Preventing recurrence

- **User-observable-rax witness**: add a smoke that reads user rax after
  a known-value syscall (e.g., a `sys_debug_ret(0xDEADBEEF)` that echoes
  its rax input into a wire-visible marker). Track as design.
- **Register-liveness audit**: extend `tools/opcode-canary.sh` with a
  syscall-epilogue check that asserts either (a) no `mov rax, ...`
  between `call syscall_dispatch` and `sysret`, or (b) a matching
  `mov rax, [rip + _saved_syscall_ret_rax]` restore before `sysret`.
  Small assembler-pattern grep, high-value regression guard.
- **Callee-save discipline audit**: same pattern for rbx/rbp/r12-r15;
  they must survive every dispatch call. Currently trusted by
  construction (paideia-as's calling convention), but never explicitly
  witnessed.

### 9.3 Cost of the delay

The `#724 D1..D10` landing chain took ten separate root-cause fixes to
reach the fake CHILD HELLO 42/WAIT: pid=2 status=42 marker. Each of
those fixes was real, but the AC line "verifying" that they cohered was
fake — a bug this deep hides all failure modes downstream of it. Every
witness that predicated "success" on init observing a syscall return was
wrong; every "verified" AC was noise. A single earlier landing that made
one negative-errno path visible on wire (or the register-liveness audit
above) would have surfaced #731 within its first ring-3 witness. Instead
we accumulated a nine-month wire-invisible masked-return-value regression.

## 10. Commit + push

Commit message:
```
Fix #731: syscall_entry preserves rax across sysret CR3 flip — root
cause behind #723 AC verify chain of masked bugs
```

Post-push, unmask filed follow-ups #732 (wait4 -EFAULT) and #733 (other
masked syscall returns; escalate per wire evidence).
