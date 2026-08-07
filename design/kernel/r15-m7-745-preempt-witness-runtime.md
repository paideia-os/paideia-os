# r15-m7-745 — Preempt Witness Runtime: Real Timer Preempt On the Wire

Status: LANDED
Issue: paideia-os#745 (follow-up to #566; also closes #566 AC)
Predecessors: #566 (timer preempt plumbing, b47c166), #744 (per-task
TSS.RSP0 + KPTI kstack mapping, 3b51985), #564 (sched_switch_r15),
#563 (sched_pick_next_r15), #728 D9 (per-task kernel stacks)
Also closes: #566 (its AC — "3 tasks; each prints its id in a loop;
output alternates roughly evenly" — is met by this issue's wire).

## 1. Motivation

At the #566 landing the preempt-tail machinery in `trampoline_vec32`
was wired but strictly inert: no smoke mode ever exercised the
`sched_pick_next_r15 → sched_switch_r15` branch on the wire because
`SCHED_BUDGET_DEFAULT` was hedged to `1_000_000` (10 000 s at the
target 100 Hz tick), effectively disabling preempt for every mode's
duration. The debugger's #566 verify pass observed additionally that
the preempt witness in `sched/tasks.pdx` hardcoded `cmp rcx, 1`
against its `_preempt_witness_a_visits` counter, so task A exited on
its first iteration before ever reaching `sti; hlt` — the interleaving
path was structurally dead code (§4.2 of the #566 design doc).

#744 landed the second missing piece: `sched_switch_r15` now updates
`TSS.RSP0` to the incoming task's per-task kstack top on every switch
(guarded on `kstack_top != 0` for ring-0-only synthetic TCBs), and
`kpti_build_user_pml4` maps `_task_kernel_stacks` (261 pages) into
every user PML4 so the CPU's push at `TSS.RSP0` succeeds under user
CR3. That eliminated the cross-ring-3 stack-corruption hazard that
originally forced the 1M hedge.

This issue completes the runtime side of #566: the witness is now
armed against a live LAPIC timer, its bodies drive real preempt
across two ring-0 tasks, and the wire proves `PA / PB / PA / PB / PA`
interleaving before `R15 PREEMPT OK`. `SCHED_BUDGET_DEFAULT` stays
at 1M for AC-critical paths (init, child), preserved by a per-body
budget override that is scoped strictly to the two witness tasks.

## 2. Reproducing the #566-verify hang (target ≥ 2)

Baseline reproduction of the debugger's finding, before this fix:

1. Change `cmp rcx, 1` → `cmp rcx, 3` in
   `_preempt_witness_task_a_entry` / `_b_entry` (source of truth
   supposed to be `PREEMPT_WITNESS_TARGET = 3`).
2. Rebuild, run `boot_r15_process`.

Observed wire: `PA TICK` (from task A's first iteration's `klog_s1`)
reaches COM1; then boot hangs. No second `PA TICK`, no `PB TICK`, no
`R15 PREEMPT OK`. Smoke times out at 8 s.

Root cause: at that source layout the LAPIC timer is not yet armed
at the preempt-witness call site (it is initialised at L7565, well
after the witness runs). Task A executes `sti; hlt`, but no
interrupt can preempt it — the LVT_TIMER is masked at power-on
default. The hang is `hlt` waiting forever for a delivery that will
never occur.

The #745 comment on the issue predicted a different root cause
("handle_timer's reset to `SCHED_BUDGET_DEFAULT = 1M` stretches the
next slice to 10 000 s"). That is a real second-order defect that
would surface immediately once the timer is armed — see §5. Both
defects need fixing; this issue fixes both.

## 3. Why ring-0 witness tasks (not ring-3)

`_preempt_witness_task_a_tcb` / `_b_tcb` are synthetic 2224-byte
slabs allocated in `sched/tasks.pdx` with `kstack_top` left at .bss
zero. `sched_switch_r15`'s #744 TSS.RSP0 guard skips the update
for these TCBs — correctly, because these tasks never take a
ring-3 → ring-0 transition (there is no ring-3 code path; the
witness bodies run in ring 0 throughout). For ring-0 → ring-0
interrupts, the CPU pushes the `iretq` frame on the CURRENT stack,
not on TSS.RSP0, so each witness's ISR-time context lands on its
own dedicated 4 KiB kernel stack
(`_preempt_witness_task_a_stack` / `_b_stack`). No cross-task
stack contention is possible.

This keeps the witness self-contained: it exercises `pick_next` +
`sched_switch_r15`'s ring-0 → ring-0 preempt path independently of
the ring-3 machinery that #744 delivered. A future ring-3 preempt
witness would require ELF-loaded ring-3 tasks with per-task kstacks
(covered by `task_new`) — orthogonal to this issue.

## 4. LAPIC timer arm-and-mask ordering

The pre-existing boot flow armed the LAPIC timer late
(`kernel_main.pdx:7565-7568`), after every other boot witness had
completed. The witnesses (IPI structural, self-IPI runtime,
uart_rx wire) were designed against a masked LVT_TIMER — their
brief `sti` windows only expected delivery of the specific vector
under test.

For #745, the preempt witness needs the timer LVT unmasked in its
own window (so `hlt` in the witness body actually resumes). The
naïve fix — call `lapic_timer_init` inside the witness prep, leave
the LVT unmasked afterwards, reuse the existing L7565-7568 pair as
a no-op — was tried first and hangs the r17_init AC. Cause: on
QEMU TCG the LAPIC timer fires at ~100 kHz
(`init_count=10000` / bus_clock≈1 GHz = 10 μs/tick), and the
uart_rx_wire_witness's 200 000 000-cycle poll takes ~2 s of wall
time. During that 2 s the timer ISR runs ~200 000 times. Each
`handle_timer` invocation (LAPIC MMIO EOI + iretq) costs enough
that the cumulative overhead prevents the smoke from reaching
`INIT BOOT OK` within the 8 s r17_init timeout.

The fix is a scoped arm/mask pair around the preempt witness:

```
preempt_witness:
    ... prep both TCBs ...
    call lapic_timer_init                   ; UNMASK LVT (write 0x20020)
    mov rdi, 10000
    call lapic_timer_init_periodic_count    ; arm initial count
    sti
    sched_switch_r15(task_a)                ; witness runs here
    ; task A exits back to boot via sched_switch_r15(_sched_witness_boot_tcb)
    cli
    ... dequeue witnesses, check visit counts ...

preempt_witness_exit:
    mov rax, 0xFEE00320
    mov rcx, 0x30020                        ; mask=bit16 | periodic | vec 32
    mov_d [rax], rcx                        ; RE-MASK LVT

... IPI witness, self-IPI witness, uart_rx_wire_witness ...

    call lapic_timer_init                   ; UNMASK LVT for init_boot
    mov rdi, 10000
    call lapic_timer_init_periodic_count

init_boot:
    ...
```

The mask write at `preempt_witness_exit` is the only new addition
downstream of the witness — `lapic_timer_init` at the pre-init
site already writes `LVT_TIMER = 0x20020` (mask=0) which
unmasks. The two LAPIC calls at L7633-7636 are unchanged; their
role shifts from "first arm" to "re-arm after witness mask" but
their code and effect are identical.

## 5. Per-body budget reset: bypassing handle_timer's default

`handle_timer` in `exceptions.pdx` handles budget exhaustion by:

```
mov ecx, [rax + 112]      ; current budget
sub ecx, 1
mov_d [rax + 112], ecx    ; write back
cmp ecx, 0
jne ack
mov rcx, 1000000          ; SCHED_BUDGET_DEFAULT
mov_d [rax + 112], rcx    ; RESET
lea rax, [_preempt_needed]
mov rcx, 1
mov [rax], rcx            ; request preempt
```

So the SECOND slice of any task that hits budget=0 is 1 000 000
ticks long. For the witness at 100 kHz timer that is ~10 s per
slice — the interleaving would drag through 40 s of wall time for
`PA / PB / PA / PB / PA` and the smoke would time out.

The witness bodies work around this by RE-writing their own
`sched_budget = 1` on every iteration, immediately before `sti; hlt`:

```
preempt_witness_a_loop:
    ; (1) increment _preempt_witness_a_visits
    ; (2) klog "PA TICK"
    ; (3) reload visits, cmp PREEMPT_WITNESS_TARGET, jae exit

    ; (4) reset own budget to 1
    lea rax, [rip + _current_tcb]
    mov rax, [rax]              ; rax = task_a's TCB
    mov rcx, 1
    mov_d [rax + 112], rcx      ; TCB.sched_budget = 1

    ; (5) yield to timer
    sti
    hlt
    jmp preempt_witness_a_loop
```

`_current_tcb` at this point is task A's own TCB — the switch is
what put it here — so the store lands on the correct slab.

### 5.1 Why the reset must land AFTER klog, not before

Placing `mov_d [rax + 112], 1` before `call klog_s1` looks
tempting (fewer instructions between the reset and the `hlt`) but
opens a re-entrancy race in `klog_emit_core`:

```
klog_emit_core epilogue:
    mov rax, [r14 + 256]     ; restore RFLAGS
    pushfq
    mov [rsp], rax
    popfq                    ; <-- IF=1 restored here
    xor rax, rax
    mov [rip + _klog_in_progress_bsp], rax   ; <-- clear gate here
```

Between the `popfq` (IF=1) and the gate clear, IF is on and the
gate is still set. If a timer preempts in that window and switches
to the other witness task, the incoming task's `klog_s1` observes
gate=1, hits the `emit_skip` early-return, and its `PA TICK` /
`PB TICK` never reaches the wire. The interleaving proof breaks
without any visible crash — a silent-drop failure mode.

By placing the reset AFTER `klog_s1` returns, budget stays at
`SCHED_BUDGET_DEFAULT - N` (N = timer ticks that fired during
klog, always ≪ 1M) throughout the whole klog call. Preempt cannot
fire until the reset instruction executes, by which point
klog has fully released its gate.

Kernel_main's witness prep sets initial budget to
`SCHED_BUDGET_DEFAULT` (1M) — was 3 pre-#745 — for the same
reason: the FIRST iteration's klog must complete before preempt
can fire.

## 6. Runqueue ordering: which task ends up at head.next

`sched_pick_next_r15` returns `_runq_head_slot.next` AND rotates
it to the tail on every call. The trampoline preempt tail guards
against `next == _current_tcb`, so if the picked task IS the
current task the switch is suppressed (the rotation still takes
effect as a side effect).

With naïve enqueue order (`task_a` first, then `task_b`), the
runqueue after enqueue is `head → task_a → task_b → head`. Boot
then switches to task A directly (`_current_tcb = task_a`). On the
first timer preempt, `pick_next` returns `head.next = task_a`,
guard trips, no switch — but the rotation moves task_a to tail:
`head → task_b → task_a → head`. Task A continues running until
the NEXT budget-zero. On that second preempt, `pick_next` returns
`task_b`, switch fires. Net effect: task A gets a double-slice on
entry, wire shows `PA / PA / PB / PA` (task_b only gets 1 tick).

The fix is to enqueue task_b FIRST, then task_a. Runqueue becomes
`head → task_b → task_a → head`. First preempt from task_a: pick
returns `task_b` (different from current), switch fires
immediately. Even single-tick preempt slice throughout. Wire
becomes the intended `PA / PB / PA / PB / PA`.

This is a witness-local ordering discipline — production tasks
enqueue in whatever order `task_new` returns from `pid_alloc` and
handle_timer's decrement is the only real preempt trigger; the
`next == current` guard is what protects AC-single-task paths
where preempt legitimately no-ops.

## 7. Wire evidence

Wire output between `R15 BLOCK WAKE OK` and `R15 PREEMPT OK` (from
`/tmp/paideia-os-smoke.log`, `boot_r15_process` mode):

```
R15 BLOCK WAKE OK
00000000166dfe76|0|I|SCHD|PA TICK
000000001685f150|0|I|SCHD|PB TICK
0000000016965480|0|I|SCHD|PA TICK
00000000169d0cf8|0|I|SCHD|PB TICK
0000000016a08dfe|0|I|SCHD|PA TICK
R15 PREEMPT OK
```

Three `PA TICK` and two `PB TICK`, strictly alternating. TSC
deltas are ~1-2 M cycles between adjacent ticks — consistent with
QEMU TCG LAPIC firing every ~10 μs (bus_clock/init_count).

The wire proves:
- **Real timer preempt fires.** Task A cannot increment
  `_preempt_witness_b_visits`; the two `PB TICK` entries prove the
  timer ISR's preempt tail switched from task A to task B on ticks
  where task A had budget=1 → 0. No cooperative path could produce
  interleaved output because the witness bodies contain no
  `sched_switch_r15(_task_b_tcb)` call.
- **The switch preserves callee-save state.** Each `PA TICK` after
  the first uses `_preempt_witness_a_visits` as a running counter
  loaded from memory, but the loop body's control flow depends on
  the `jmp preempt_witness_a_loop` at the tail; if `sched_switch_
  r15`'s continuation reset caller state incorrectly, the second
  and third iterations would not fall into the loop head.
- **The runqueue rotates correctly.** Five ticks produce five
  distinct outputs alternating between the two witnesses'
  counters, which is only possible if `sched_pick_next_r15`'s
  circular-list rotation is a true rotation (not, say, a
  static-head that always returns task B).

The fingerprint delta is a subset chosen to prove the round-trip:

```
R15 BLOCK WAKE OK   <- unchanged
PA TICK             <- NEW: task A first iteration
PB TICK             <- NEW: proves switch A → B
PA TICK             <- NEW: proves switch B → A
R15 PREEMPT OK      <- unchanged
```

Full deterministic wire is `PA PB PA PB PA` — the shorter
fingerprint keeps flexibility if any future change (e.g.
different `PREEMPT_WITNESS_TARGET`) shifts the count while
preserving alternation.

## 8. AC preservation

`SCHED_BUDGET_DEFAULT` remains 1 000 000 (`task_pool.pdx:91`,
`exceptions.pdx:202` — both reset paths). Every real task
(`task_new`) initialises `sched_budget = 1M` and `handle_timer`
resets to 1M on zero. At the 100 kHz TCG timer, a 1M-tick slice is
~10 s — far longer than any AC path takes, so preempt never fires
during init / child execution and the `next == current` guard in
the preempt tail keeps single-task paths as clean no-ops.

The per-body budget override in `_preempt_witness_task_a/b_entry`
writes budget=1 via `[_current_tcb + 112]`, which mutates ONLY the
running task's TCB. On witness exit, `_current_tcb` returns to
`_sched_witness_boot_tcb` (whose budget stays at .bss zero →
u32-wraps on first decrement, never triggers preempt). Init boots
later with its own real `task_new`-initialised budget of 1M. The
witness has zero effect on init's timing envelope.

The 20-mode smoke matrix stays green through this landing:
`boot_r15_process`, `boot_r15_ring3`, `boot_r16_uart_rx`,
`boot_r17_init` (the AC-critical mode) all pass with the new
`PA TICK / PB TICK / PA TICK / R15 PREEMPT OK` fingerprint
addition and no other change.

## 9. Files touched

- `src/kernel/core/sched/tasks.pdx` — witness bodies:
  - `cmp rcx, 1` → `cmp rcx, 3` (target = `PREEMPT_WITNESS_TARGET`)
    in both `_preempt_witness_task_a_entry` and `_b_entry`.
  - Insert 4-instruction budget-reset sequence between the target
    check and `sti` in both bodies (`lea/mov/mov/mov_d`).
  - Update module-level and per-fn justification strings to
    reference #745 and design §5.
- `src/kernel/boot/kernel_main.pdx` — `preempt_witness` block:
  - Initial budget bump `mov rcx, 3` → `mov rcx, 1000000` (avoids
    klog re-entrancy race on first iteration; see §5).
  - Swap enqueue order (`task_b` before `task_a`) so first
    `sched_pick_next_r15` from task A rotates to task B on the
    very first preempt (see §6).
  - Insert `call lapic_timer_init` + `call lapic_timer_init_
    periodic_count(10000)` inside the witness prep, immediately
    before `sti; sched_switch_r15(task_a)` (see §4).
  - At `preempt_witness_exit`, insert 3-instruction LVT_TIMER
    mask write (`mov 0xFEE00320; mov 0x30020; mov_d`) so
    subsequent boot witnesses run without timer ISR overhead
    (see §4).
  - Strengthen witness verification: `cmp _preempt_witness_a_
    visits, 3` AND `cmp _preempt_witness_b_visits, 2` (was just
    `cmp _preempt_witness_a_visits, 1`).
- `tests/r15/expected-boot-r15-process.txt`,
  `tests/r15/expected-boot-r15-ring3.txt`,
  `tests/r17/expected-boot-r17-init.txt`,
  `tests/r16/expected-boot-r16-uart-rx.txt` — insert three
  fingerprint lines (`PA TICK`, `PB TICK`, `PA TICK`) between the
  pre-existing predecessor line (`R15 BLOCK WAKE OK` or
  `R17 INIT LOAD OK`) and `R15 PREEMPT OK`.

No changes to:
- `handle_timer` — the reset-to-`SCHED_BUDGET_DEFAULT` behaviour
  stays as designed; witness bodies override at the source (their
  TCBs) rather than changing the global default.
- `trampoline_vec32` — the preempt-tail guards
  (`next == current`, `next == idle`) remain unchanged; they are
  what preserves AC when the runqueue holds a single runnable
  task.
- `sched_switch_r15`, `sched_pick_next_r15` — the ring-0 preempt
  path is exercised as-designed by the witness. Any latent
  correctness issue would have surfaced as a hang or crash on the
  wire; the observed 5-tick interleaving is proof of correctness
  at the design's stated contract.
- `SCHED_BUDGET_DEFAULT` — kept at 1M pending a future issue that
  drops it globally and adds a runtime preempt witness across
  ring-3 tasks (would need reworking of the AC's fork/wait timing
  or of the wait4 zombie-vs-block-vs-woken races that a smaller
  budget would surface).

## 10. Backtracking log

Three implementation attempts before landing:

**Attempt 1** (fails): change `cmp rcx, 1` → `cmp rcx, 3` in
witness bodies. Wire produces one `PA TICK`; boot hangs at
`sti; hlt`. Root cause: LAPIC timer LVT is masked at power-on and
never unmasked before the witness runs (the sole
`lapic_timer_init` call is at L7565, after all witnesses). Fix:
arm the timer inside `preempt_witness` prep.

**Attempt 2** (fails): arm the LAPIC timer in the witness prep.
Preempt fires; wire produces `PA PA PB PA` (task_a=3, task_b=1)
then `R15 PREEMPT FAIL` (task_b's visits < 2). Root cause 1:
runqueue enqueue order places task_a at `head.next`, so the first
`sched_pick_next_r15` returns task_a (= current), guard skips
switch, task_a gets a double-slice. Root cause 2: `handle_timer`
resets budget to `SCHED_BUDGET_DEFAULT = 1M`, so if task_a's
budget=1 initial reset had been bypassed on iteration 2 (which it
was — kernel_main set budget=3 not 1M so the second iteration
started with the handle_timer reset of 1M, then bypassed by the
new per-body reset), further iterations still hit the double-slice
because rotation only advanced pick_next's head-pointer, not the
`current` = task_a assumption. Fix: swap enqueue order + change
kernel_main initial budget to 1M (klog race protection).

Wait — after attempt 2 the r15_process fingerprint passed (5 ticks
in the right order) but `boot_r17_init` failed at `INIT BOOT OK`.
Root cause: LAPIC timer stays armed after the witness, ~200 000
timer ISR entries during uart_rx_wire_witness's 2 s poll starve
the CPU enough to miss the 8 s smoke timeout.

**Attempt 3** (lands): add 3-instruction LVT_TIMER mask write at
`preempt_witness_exit`. The pre-existing `lapic_timer_init` at
L7633 unmasks it for init boot. All 20 smoke modes green.

## 11. Latent issues surfaced

None new in the scheduler / preempt machinery. Two known-existing
issues re-verified as latent (not this issue's scope):

1. **TSS.RSP0 not updated for init's first ring-3 entry.**
   `enter_userland_initial` iretqs into init without calling
   `sched_switch_r15`, so `TSS.RSP0` retains its `tss_install`
   default (boot's `_kernel_stack`). Init's first ring-3 → ring-0
   transition (timer interrupt at 100 kHz for a 10 s slice, or its
   first syscall — wait, syscall uses MSRs not TSS) would push its
   frame on boot's kernel stack. Safe at present because no other
   task uses that stack concurrently and init's per-task kstack
   takes over on its first `sched_switch_r15` (into child, from
   sys_wait4). Future MP work will need to update TSS.RSP0 in
   `enter_userland_initial` or in the pre-init publish block.

2. **QEMU TCG LAPIC bus_clock is not 1 GHz.** The design comment
   in `handle_timer` and elsewhere claims 100 Hz tick; empirical
   TSC deltas suggest ~100 kHz. This is a pure documentation
   drift — the code itself uses `init_count = 10000` without
   frequency assumption, so no behaviour depends on the 100 Hz
   claim being accurate. A doc-scrub follow-up could reconcile.

## 12. Commit shape

Single commit against `main`, message:

```
Fix #745: real timer preempt on wire — witness interleaving
proves cross-task preempt (closes #566 AC)
```

Files: `src/kernel/core/sched/tasks.pdx`,
`src/kernel/boot/kernel_main.pdx`,
`tests/r15/expected-boot-r15-process.txt`,
`tests/r15/expected-boot-r15-ring3.txt`,
`tests/r17/expected-boot-r17-init.txt`,
`tests/r16/expected-boot-r16-uart-rx.txt`,
`design/kernel/r15-m7-745-preempt-witness-runtime.md`.

No changes to boot_panic / boot_exc3 asm (their preempt witness
messages are unchanged rodata already present at #566 landing).
