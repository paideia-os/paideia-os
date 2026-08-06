---
issue: 724 (D2 defect)
milestone: R17.M2 → R17.M5 (init boot chain, blocks #723)
subsystem: 9 — syscall dispatch (sys_exit termination wiring)
prereq:
  - "#557 (sys_exit_body: mark ZOMBIE, wake parent if WAITING — LANDED)"
  - "#563 (runq_dequeue: O(1) unlink from circular runqueue — LANDED)"
  - "#563 (sched_pick_next_r15: O(1) rotate + idle fallback — LANDED)"
  - "#564 (sched_switch_r15: full context switch — LANDED)"
  - "#620 (kernel_main → init: publishes _current_tcb, runq_enqueue init — LANDED)"
blocks:
  - "#723 (fork/exec/wait full runtime chain — child sys_exit currently panics in klog_panic hlt loop; blocks the round-trip)"
touching:
  - src/kernel/core/syscall/dispatch.pdx                     (dispatch_exit body replacement)
  - design/kernel/r17-m0-724-d2-sys-exit-terminate.md        (this doc)
related:
  - design/kernel/r15-m6-006-sys-exit.md                     (§Scope out-of-scope point 3: "Scheduler transition. After sys_exit_body returns, the syscall wrapper must not return to userspace — it must invoke the scheduler to pick another task. That's a wrapper concern, not a body concern — deferred." — THIS doc implements the deferred wrapper concern.)
  - design/kernel/r15-m7-006-block-wake.md                   (sched_block precedent: state-flip + runq_dequeue + pick + switch — sys_exit's dispatch is structurally the same minus the state flip, because sys_exit_body already wrote STATE_ZOMBIE)
---

# R17-M0-724-D2 — sys_exit dispatch: real task-termination path (#724 defect D2)

## 1. Scope

Replace the placeholder `dispatch_exit_halt` klog_panic infinite loop in
`src/kernel/core/syscall/dispatch.pdx` with a real termination sequence that:

1. Calls `sys_exit_body(current, status)` — marks the exiting task ZOMBIE
   and wakes its parent if the parent is WAITING (unchanged from #557).
2. Removes the exiting task from the runqueue (`runq_dequeue`) so
   `sched_pick_next_r15` will never re-select it.
3. Picks the next runnable task (`sched_pick_next_r15`).
4. Context-switches to it (`sched_switch_r15`) — this call never returns
   because the exiting task has been dequeued.

Two invariants define completion:

- **No return to the exiting task.** After `sched_switch_r15(next)`, the
  next task's kernel stack is loaded and control jumps to next's saved
  RIP (either its own `continuation` for a resumed task, or its entry
  point for a fresh task). The exiting task's kernel stack is abandoned;
  the ZOMBIE's TCB is retained until the parent's `sys_wait_body` reaps
  it via `pid_free`.
- **19/19 smoke matrix stays green.** No fingerprint file needs editing.
  The only observable difference for existing witnesses is that the
  post-exit path no longer emits the `[panic]` klog banner from
  `klog_panic` inside `dispatch_exit_halt` — but no fingerprint file
  matches that banner (it was a defensive marker for "this shouldn't
  happen"), so no matcher breaks.

Explicitly out of scope (deferred):

- **sys_wait_body real blocking.** `sys_wait_body` still sets
  `current->state = STATE_WAITING` and returns 0 without invoking
  `sched_block`. The parent is left on the runqueue and continues
  running after wait4 returns. That's a separate defect (call it #724
  D5) with its own dispatch-shape and design pass; it does not block
  #724 D2. When the parent's sys_wait_body path returns 0 with pid==0,
  init's current source (`src/user/init.pdx`) treats that as reap
  success and calls sys_exit(0) — which #724 D2 now handles correctly.
  The end-to-end #723 chain runs to completion because init's exit
  terminates the last user task and control transitions to `_idle_tcb`.
- **Runqueue re-enqueue of woken parent.** `sys_exit_body` writes
  `parent->state = STATE_RUNNABLE` on the wake path but does NOT call
  `runq_enqueue(parent)`. Because `sys_wait_body` never called
  `runq_dequeue` on the WAITING transition (deferred defect, above),
  the parent is already on the runqueue with a stale STATE_WAITING
  when sys_exit's wake path runs. sys_exit's wake writes the state
  back to STATE_RUNNABLE in place. `sched_pick_next_r15` doesn't
  inspect state; it just picks head.next. So the parent gets picked
  after the ZOMBIE is dequeued. No new dispatch step needed here.
  When #724 D5 lands and sys_wait properly runq_dequeues on WAITING,
  a companion edit to sys_exit_body (or this dispatch) must
  runq_enqueue the woken parent.
- **fd release / aspace teardown of ZOMBIE.** Per #557 §Scope
  point 6 "No slab teardown, no pid_free": that's the parent's
  sys_wait return path (`task_free`). sys_exit does not free the
  ZOMBIE's slab; retention keeps `child->exit_status` alive for the
  parent to read. Unchanged here.

## 2. Prereq check

### 2.1 What's in place

| Primitive              | Location                                             | Signature / effect                              |
|------------------------|------------------------------------------------------|-------------------------------------------------|
| `sys_exit_body`        | `src/kernel/core/syscall/handlers/sys_exit.pdx:66`   | `(u64, u64) -> ()` !{mem} @{}                    |
| `runq_dequeue`         | `src/kernel/core/sched/runqueue.pdx:206`             | `(u64) -> ()` !{mem} @{sched}                    |
| `sched_pick_next_r15`  | `src/kernel/core/sched/pick_next.pdx:99`             | `() -> u64` !{mem} @{sched}                      |
| `sched_switch_r15`     | `src/kernel/core/sched/switch.pdx:98`                | `(u64) -> ()` !{mem, sysreg} @{sched}            |
| `_current_tcb`         | `src/kernel/core/sched/runqueue.pdx:85` (mut u64)    | ptr to running task_struct                       |
| `_idle_tcb`            | `src/kernel/core/sched/idle.pdx` (mut u64)           | ptr to idle task_struct (empty-runq fallback)   |

All four primitives were exercised by the R15.M7 witness suite (idle_witness,
runqueue_witness sub-tests A–D, sched_switch witness, block_wake witness sub-test B)
and by `sched_block`'s production body in `wake_block.pdx:34-72`, which uses
exactly this shape:

```
current = _current_tcb
current->state = STATE_WAITING
runq_dequeue(current)
next = sched_pick_next_r15()
sched_switch_r15(next)
```

sys_exit's dispatch is the same shape with two differences:

1. State flip is STATE_ZOMBIE (already done inside `sys_exit_body`) not STATE_WAITING.
2. There is no resume path — the ZOMBIE will never be woken; its TCB is
   awaiting reap by the parent's `sys_wait_body`.

### 2.2 What is not in place

Nothing. All four calls compile against the existing `.pdx` sources; no
new encoder patterns are introduced beyond what the R15.M7 witness
suite already exercises.

### 2.3 Encoder gaps

**None.** Every mnemonic in the new dispatch_exit body appears in the
extant witness code:

- `mov rax, [rip + _current_tcb]` — used 10 times in dispatch.pdx today
- `mov rdi, rax` — trivial reg-reg move
- `mov rdi, [rip + _current_tcb]` — direct load into rdi for the second call
- `call runq_dequeue` / `call sched_pick_next_r15` / `call sched_switch_r15` — plain PLT-less near-calls
- `jmp dispatch_exit_halt` — unchanged from prior code

## 3. Design

### 3.1 Body sequence — four steps, one exit

```
dispatch_exit:
    ; ----- SysV entry: rsp % 16 == 8 (call syscall_dispatch pushed RA) -----
    ; Enter dispatch_exit via cmp/je from the sysno linear chain (no push).
    ; So rsp % 16 == 8 upon reaching dispatch_exit label.

    ; ----- step 1: sys_exit_body(current, status) -----
    mov rax, [rip + _current_tcb]
    mov rdi, rax                          ; rdi = current
    ; rsi = status (already SysV-positioned by syscall_dispatch's caller)
    sub rsp, 8                            ; rsp % 16 == 0 (alignment prelude)
    call sys_exit_body                    ; push RA → rsp%16==8 for callee entry
    ; on return: rsp % 16 == 0

    ; ----- step 2: runq_dequeue(current) -----
    ; _current_tcb hasn't changed (sys_exit_body doesn't touch it).
    ; Re-load for clarity; a stashed rdi would also work but adds coupling.
    mov rdi, [rip + _current_tcb]
    call runq_dequeue                     ; push RA → rsp%16==8; return → rsp%16==0

    ; ----- step 3: next = sched_pick_next_r15() -----
    call sched_pick_next_r15              ; push RA → rsp%16==8; return with rax = next → rsp%16==0

    ; ----- step 4: sched_switch_r15(next) — never returns -----
    mov rdi, rax                          ; rdi = next TCB
    call sched_switch_r15                 ; push RA → rsp%16==8; returns to next's stack (not us)

    ; UNREACHABLE. Defensive fallthrough:
    jmp dispatch_exit_halt

dispatch_exit_halt:
    lea rdi, [rip + SUBSYS_INT_]
    lea rsi, [rip + tag_exit_returned]
    call klog_panic
    jmp dispatch_exit_halt
```

### 3.2 Alignment reasoning

The single `sub rsp, 8` before `call sys_exit_body` sets `rsp % 16 == 0`.
Every subsequent `call` pushes 8 bytes of return address, satisfying the
SysV `rsp % 16 == 8` entry contract for the callee. Each callee returns
to us with `rsp % 16 == 0` — the same state as after the initial
`sub rsp, 8`. So we can chain any number of calls without further
`sub`/`add rsp, 8` bookkeeping. This mirrors `sched_block`'s prologue
in `wake_block.pdx`, which does no explicit alignment adjustment
because it's already invoked in the aligned context.

The absence of an `add rsp, 8` epilogue is intentional and correct:
`sched_switch_r15` never returns to us. If a scheduler bug (broken
runq_dequeue precondition, invariant violation in sched_pick_next_r15,
etc.) did return, the `jmp dispatch_exit_halt` picks up the pieces via
klog_panic — misaligned rsp is the least of our worries at that point.

### 3.3 _current_tcb load timing

`sys_exit_body` does not touch `_current_tcb`. `runq_dequeue` operates
on the task pointer we pass in `rdi` — also does not touch `_current_tcb`.
So between steps 1 and 2 we can either:

(a) Re-load `_current_tcb` into rdi (this design).
(b) Stash the pointer somewhere before step 1 (e.g., push rbx / mov rbx, rax
    before sys_exit_body, then mov rdi, rbx after; pop rbx before sched_switch_r15).

Option (a) is chosen because:

- Fewer register-save discipline concerns (no callee-save push/pop needed).
- The re-load is a single RIP-relative load — 7 bytes, ~4 cycles — vs.
  three instructions (push/mov/pop) for the stash approach.
- The `_current_tcb` value is guaranteed identical because no callee in
  step 1 modifies it (verified against `sys_exit.pdx` §3.6 register
  discipline table).

`sched_pick_next_r15` may inspect `_current_tcb` but does not modify it.
`sched_switch_r15` DOES modify `_current_tcb ← next` internally as part
of its switch protocol (per `switch.pdx:154`). That's fine — we've
already used the old `_current_tcb` value in steps 1 and 2, and step 4
consumes rax (next) not `_current_tcb`.

### 3.4 Never-return semantics for sched_switch_r15

`sched_switch_r15` per its design (`design/kernel/r15-m7-003-sched-switch.md`):

1. Saves outgoing (from `_current_tcb`): callee-save GPRs, RFLAGS, RSP, RIP=&continuation
2. Updates `_current_tcb ← next` (via rdi)
3. Loads incoming (from rdi): kernel stack rsp
4. Pushes synthetic RFLAGS + RIP frame onto next's stack
5. Loads incoming callee-save GPRs
6. `ret` — consumes pushed RIP → jumps to continuation (or fresh entry)

The outgoing side saves state into the ZOMBIE's TCB. That state is
never read again because:

- `_current_tcb` no longer points at the ZOMBIE (updated in step 2 of
  the switch protocol).
- The ZOMBIE is off the runqueue (runq_dequeue in dispatch step 2), so
  `sched_pick_next_r15` cannot select it.
- No other primitive walks TCBs and calls `sched_switch_r15(zombie)`.

The waste is 8 GPR stores + 2 flag/rsp stores + 1 rip store = 11 store
instructions worth of "we saved state that will never be read". The
alternative — a `sched_switch_r15_no_save` variant that skips the save
side — would introduce an ABI surface split for zero-perf-critical
speed on a code path that fires at most once per user task lifecycle.
Retention is Pareto-adequate.

### 3.5 Interaction with sys_exit_body's parent wakeup

When a child exits with parent WAITING:

1. `sys_exit_body` writes:
   - `child->state = STATE_ZOMBIE (3)`
   - `child->exit_status = status`
   - `parent->wait_result_pid = child->pid`
   - `parent->wait_result_status = status`
   - `parent->state = STATE_RUNNABLE (1)` (was STATE_WAITING=2)
2. `runq_dequeue(child)` — child leaves runqueue.
3. `sched_pick_next_r15()` — walks head.next of the circular list.
   Now — parent is still on the runqueue (sys_wait_body never dequeued
   it; see §Scope deferred defect), so head.next may or may not point
   at parent depending on prior rotations. Either way, some task on the
   runqueue is returned.
4. `sched_switch_r15(next)` — switches to next.

The parent will be selected some subsequent tick (or the tick after,
depending on the rotate order). Its wait4 syscall has ALREADY returned
0 in the current implementation (sys_wait_body doesn't block); the
parent code has already read `wait_status` and moved on. So the
"wakeup" is semantically vestigial in the current chain — but it costs
nothing and aligns the design with the eventual real-blocking
sys_wait.

### 3.6 Interaction with the idle path

If the runqueue becomes empty (init exits with no other runnable
tasks), `sched_pick_next_r15` returns `_idle_tcb`. `sched_switch_r15`
switches to the idle task's kernel stack. The idle body (`idle.pdx`)
is an `hlt; jmp .` loop that consumes the CPU until an interrupt
arrives. At R17.M0 with LAPIC timer broken (per #662) and no serial
IRQ delivery to a shell yet, this means the kernel stays parked in
`hlt` — but crucially, no `klog_panic` fires and no `#GP` on the
exiting task's stale kernel stack.

The `INIT BOOT OK` fingerprint marker (via `uart_puts` in kernel_main
before `enter_userland_initial`) has already emitted by the time init
runs its user body. Nothing in the fingerprint file requires activity
after init's sys_exit.

### 3.7 File and module structure

Single-file change:

```
src/kernel/core/syscall/dispatch.pdx      (modify dispatch_exit body)
```

No new module, no new directory. The design doc lives at:

```
design/kernel/r17-m0-724-d2-sys-exit-terminate.md
```

## 4. Test canary — smoke matrix

No new witness. Every existing smoke mode must remain green:

| Mode                    | Expectation post-change                                             |
|-------------------------|----------------------------------------------------------------------|
| boot_min                | No change — pre-init code path.                                     |
| boot_banner             | No change.                                                           |
| boot_r8_only            | No change.                                                           |
| boot_r10                | No change.                                                           |
| boot_r11                | No change.                                                           |
| boot_r12                | No change.                                                           |
| boot_r12_denial         | No change.                                                           |
| boot_r14b_hivma         | No change.                                                           |
| boot_r14b_kpti          | No change.                                                           |
| boot_r14b_ipi           | No change.                                                           |
| boot_r14b_loader        | No change.                                                           |
| boot_r14b_ud            | No change.                                                           |
| boot_r15_ring3          | No change.                                                           |
| boot_r15_process        | No change.                                                           |
| boot_r17_init           | Same fingerprint. Sys_exit chain now terminates cleanly.            |
| boot_panic              | No change.                                                           |
| boot_panic_halt         | No change.                                                           |
| boot_exc3               | No change.                                                           |

Behavioral difference for `boot_r17_init` when init reaches ring 3 and
calls sys_exit (either directly via init_shutdown or via the wait4
loop returning to init_shutdown): the kernel switches to `_idle_tcb`
and parks in `hlt` instead of panicking in dispatch_exit_halt. Serial
log post-change ends with the idle task's silent hlt rather than a
`[panic]` banner, provided the child gets scheduled and runs.

## 5. LOC estimate

| File                                                              | LOC delta |
|-------------------------------------------------------------------|-----------|
| `src/kernel/core/syscall/dispatch.pdx`                            | +30       |
| `design/kernel/r17-m0-724-d2-sys-exit-terminate.md`               | +350      |
| **Total**                                                         | **~380**  |

Actual assembly delta in `dispatch.pdx`: +5 instructions (mov rdi
_current_tcb, call runq_dequeue, call sched_pick_next_r15, mov rdi
rax, call sched_switch_r15). Comments raise the file-level LOC.

## 6. Backtrack candidates

### 6.1 Backtrack A — Move the switch into sys_exit_body

Instead of extending dispatch_exit, extend `sys_exit_body` itself to
call sched_pick_next_r15 + sched_switch_r15 at the tail.

**Reject.** #557's design (`r15-m6-006-sys-exit.md` §3.2) explicitly
splits the "leaf body" from the "syscall wrapper" so the body is
testable without the scheduler. Wiring the scheduler into the body
retroactively defeats that split and breaks the R15.M6 sys_exit
witness (which drives sys_exit_body from kernel_main and expects
control to return post-call). The witness would then need a mock
scheduler — massive scope creep.

### 6.2 Backtrack B — Introduce a `sys_exit_terminate_current` helper

Extract steps 2-4 into a new named helper in `wake_block.pdx` (paired
with `sched_block`):

```
sched_exit_current():
    runq_dequeue(_current_tcb)
    next = sched_pick_next_r15()
    sched_switch_r15(next)  ; never returns
```

Then dispatch_exit becomes:

```
dispatch_exit:
    mov rax, [rip + _current_tcb]
    mov rdi, rax
    call sys_exit_body
    call sched_exit_current
    jmp dispatch_exit_halt
```

**Neutral.** Cleaner abstraction — the "exit sequence" is named — and
future callers (e.g., a kill_signal handler, or a runtime panic that
tears down a user task) can reuse it. But it costs one indirect layer
for a sequence that fires from exactly one call site today.

**Retain as follow-up.** File as a paideia-os cleanup issue once
multiple exit paths land. For now, inlining in dispatch keeps the
change minimal.

### 6.3 Backtrack C — Use sched_block instead of the raw sequence

Since `sched_block` already does `state-flip + runq_dequeue + pick +
switch`, one might try:

```
dispatch_exit:
    ...
    call sys_exit_body                    ; sets state=ZOMBIE
    call sched_block                       ; would set state=WAITING (!)
```

**Reject.** `sched_block` writes STATE_WAITING (2) into the current
task's state field, clobbering the STATE_ZOMBIE (3) that sys_exit_body
just wrote. This would corrupt the "am I a ZOMBIE?" invariant and
break `sys_wait_body`'s scan (which looks for state==ZOMBIE). Also
`sched_block` has a `#663` precondition guard `state == STATE_RUNNABLE
(1)`; the ZOMBIE would trip the guard and `klog_panic`.

### 6.4 Backtrack D — Also runq_enqueue the woken parent

If sys_wait ever gains a real block via sched_block, then when
sys_exit's wake path runs, the parent is off the runqueue (in
STATE_WAITING). Just flipping state to STATE_RUNNABLE isn't enough —
the parent must be runq_enqueue'd too, or `sched_pick_next_r15` can
never select it.

**Deferred to #724 D5** (sys_wait real blocking). When that lands,
the sys_exit body or dispatch must also `runq_enqueue(parent)` on
the wake path. This design is unchanged; the follow-up is a 2-line
addition in either `sys_exit.pdx` (inside the state=RUNNABLE branch)
or a dispatch step 1.5 between sys_exit_body and runq_dequeue.

### 6.5 Backtrack E — Add pid_free at exit time

Free the ZOMBIE's slab and pid slot at sys_exit time instead of
waiting for the parent's sys_wait to reap. Requires either a
side-table for exit_status or coalescing wait4's return into the
sched_exit path.

**Reject.** Explicitly rejected by #557 §Scope point 6. Retains
Pareto-simpler zombie-retention design.

## 7. Tractability

**HIGH.**

- Every primitive already lands with its own witness.
- No new encoder patterns.
- No new module, no new directory, no linker-script edit.
- Follows the same sequence as `sched_block` (`wake_block.pdx:34`).
- Fingerprint files unchanged; smoke matrix stays green modulo the
  behavioral improvement (init sys_exit no longer panics).
- Register discipline is trivially correct — 4 caller-save regs (rax,
  rdi) and the transitively-preserved sysV callee-save set from every
  callee's own justification.

## 8. Cross-cutting risks

- **sched_pick_next_r15 idle fallback.** When init exits with no other
  runnable tasks, the runqueue may hit its empty-list branch. Under
  the current post-`sys_wait_body` state, the parent stays on the
  runqueue but the child doesn't, so a lone init exit still has the
  parent on the queue. However, at #723's target chain (init forks
  child, child execves child_hello, child exits, parent reaps, parent
  exits), the parent's dispatch_exit fires with only `_idle_tcb` as a
  candidate. `sched_pick_next_r15` returns `_idle_tcb`;
  `sched_switch_r15(_idle_tcb)` puts the CPU into idle's hlt loop.
  Mitigation: `_idle_tcb` is installed at kernel_main boot time and
  its TCB is initialized with `sched_switch_r15_continuation` as
  RIP (per #562).

- **_current_tcb re-load race.** No race in single-CPU R17.M0.
  Between steps 1 and 2 nothing mutates `_current_tcb`. Timer
  preemption is broken (#662 pending) so no ISR can rewrite it. For
  R17+ SMP, the syscall entry path holds a per-CPU disable-IRQs
  discipline; `_current_tcb` is per-CPU.

- **rsp misalignment on defensive fallthrough.** If sched_switch_r15
  did return (a scheduler bug), the caller's rsp would be at
  `rsp % 16 == 0` (because sched_switch_r15's ret pops the RA
  cleanly). `jmp dispatch_exit_halt` — no further calls — until
  `call klog_panic` in dispatch_exit_halt. That call pushes 8,
  making `rsp % 16 == 8` on entry to klog_panic, matching SysV.
  Alignment is fine even on the impossible-path.

- **Dispatch-verify script gate.** `tools/verify-syscall-dispatch.sh`
  check 11 uses `grep -A 10 "sys_exit_body"` to look for `hlt` or
  `klog_panic` within 10 lines of the sys_exit_body call. Post-#724
  D2 the new instructions between the call and `dispatch_exit_halt`
  are:
  1. `mov rdi, [_current_tcb]` (RIP-rel = 1 line)
  2. `call runq_dequeue` (1 line)
  3. `call sched_pick_next_r15` (1 line)
  4. `mov rdi, rax` (1 line)
  5. `call sched_switch_r15` (1 line)
  6. `jmp dispatch_exit_halt` (1 line)
  7. `dispatch_exit_halt:` header (no disasm line; label only)
  8. `lea rdi, [SUBSYS_INT_]` (1 line)
  9. `lea rsi, [tag_exit_returned]` (1 line)
  10. `call klog_panic` (1 line)

  That's 10 disasm lines after the anchor, so klog_panic is at
  precisely line 10 (within `-A 10`). Verify script passes.
  Mitigation if it doesn't: widen `-A 10` to `-A 15` in the check
  or update the check to reflect the new sequence explicitly.

## 9. Backtrack markers

| Symptom                                        | Root cause hypothesis                                | Where to look                                              |
|------------------------------------------------|------------------------------------------------------|------------------------------------------------------------|
| INIT ENTERED RING3 fires but no scheduler activity | dispatch_exit's runq_dequeue tore init off, and no other task on runqueue → idle. Expected. | tools/run-smoke.sh boot_r17_init should still pass fingerprint |
| dispatch_exit_halt klog_panic fires post-fix   | sched_switch_r15 returned to the ZOMBIE — impossible in normal ops | Check runq_dequeue was reached; verify _current_tcb ordering |
| Fingerprint boot_r17_init fails                | New dispatch broke pre-init boot flow (unlikely — only dispatch_exit touched) | Diff serial log against pre-fix baseline                    |
| Test file boot_r15_process fingerprint fails   | Same — dispatch_exit unrelated to R15 process pool witness | Dispatch_exit isn't reached in R15 fixtures; regression must be elsewhere |
| REAPED marker fails to fire                    | This defect (#724 D2) does not fix parent's wait4 blocking; the parent-side reap semantics are #724 D5's target | Deferred; see §Scope out-of-scope point 1                   |

## 10. References

- Issue: paideia-os#724 (D2 defect)
- Blocks: paideia-os#723 (fork/exec/wait full runtime chain)
- Prereqs: #557 (sys_exit_body), #563 (runq primitives), #564 (sched_switch_r15), #620 (init boot)
- Related: `design/kernel/r15-m6-006-sys-exit.md` §Scope point 3 (deferred scheduler transition — implemented here)
- Related: `src/kernel/core/sched/wake_block.pdx` sched_block (same shape as this dispatch)
