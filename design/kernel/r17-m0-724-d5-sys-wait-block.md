# R17-M0-724-D5 — sys_wait real block + sys_exit wake re-enqueue

Status: **design + implementation**
Scope: paideia-os, structural defect group D5 surfaced by debugger
verification of D6 on commit `6230956`. D5a and D5b are co-requisite:
D5b masks harmlessly today only because D5a is missing; the moment
D5a lands, D5b becomes mandatory or the parent — freshly woken but
still off the runqueue — is never picked again.
Depends on: D2 (`6a57f8d`), D6 (`6230956`). Blocks wire-visible AC of
`#723`, which additionally needs D4 (init post-iretq #GP) and D3
(dump.pdx vec corruption) — see §7.

## 1. Problem — verbatim from the debugger comment

> D5a — `sys_wait_body` never blocks.
> File: `src/kernel/core/syscall/handlers/sys_wait.pdx:56-64`.
> Current behavior: sets `current->state = STATE_WAITING`, returns
> `rax=0` immediately. Required behavior: after setting WAITING
> state, call `sched_block` so control leaves the parent until a wake
> event fires. On resume, sys_wait_body must return the zombie
> child's status.
>
> D5b — `sys_exit_body` wake path never re-enqueues the parent.
> File: `src/kernel/core/syscall/handlers/sys_exit.pdx:102-109`.
> Current behavior: writes `parent->state = STATE_RUNNABLE` directly,
> no runq_enqueue call. Required behavior: after flipping state, call
> `runq_enqueue(parent)`. Currently masked because D5a's absence
> means the parent was never dequeued, but the moment D5a lands, a
> woken parent must be back on the runq to ever get picked.

## 2. Current state — the two regions verbatim

### 2.1 `sys_wait_body` would-block tail
(`src/kernel/core/syscall/handlers/sys_wait.pdx:56-64`)

```
sys_wait_scan_done:
  cmp r9, 0;
  je  sys_wait_echild;
  // Have children, none zombie → block.
  mov rax, 2;                             // STATE_WAITING (2)
  mov [rbx + 8], eax;                     // current->state = WAITING
  xor rax, rax;
  xor rdx, rdx;
  jmp sys_wait_return;
```

Effect: parent slab's `state @ +8` flips from RUNNABLE to WAITING; body
returns `{rax=0, rdx=0}` up through the dispatcher and, from the
dispatcher, back to userland via `sysret`. The parent then re-enters
userland immediately with `wait4()` returning `0` — not what any Unix
program expects (`wait4` blocks; only `waitpid(..., WNOHANG)` returns
`0` on children-still-alive, and even then the caller expects rax to
be `0`, *and* to be in userland with the child at some point
progressing toward exit — which cannot happen because the parent is
still running and never yields).

### 2.2 `sys_exit_body` wake step
(`src/kernel/core/syscall/handlers/sys_exit.pdx:102-109`)

```
// ===== step 6: wakeup — three stores, state LAST =====
mov eax, [rdi + 0];                     // current->pid (u32)
mov [r8 + 1704], eax;                   // parent->wait_result_pid

mov [r8 + 1708], esi;                   // parent->wait_result_status = status

mov rax, 1;                             // STATE_RUNNABLE
mov [r8 + 8], eax;                      // parent->state (publish last)

sys_exit_done:
ret
```

Effect: three stores to the parent's slab (wait_result_pid,
wait_result_status, state=RUNNABLE). No runqueue mutation. Since D5a
never removed the parent from the runqueue (the state=WAITING write in
sys_wait_body did *not* dequeue), the parent is still on
`_runq_head_slot`, and sched_pick_next_r15 picks it up naturally on
the next scheduling opportunity. The wake here is data-only.

## 3. Root cause split

### 3.1 D5a — no yield

`sys_wait_body`'s WAITING write is a bare `mov [rbx+8], eax`. It:

* does **not** call `sched_block`,
* does **not** dequeue `current` from `_runq_head_slot`,
* does **not** invoke `sched_pick_next_r15` / `sched_switch_r15`.

Control simply returns to the syscall dispatcher, which returns to
`syscall_entry`, which `sysret`s to userland. The parent is back in
userland with `rax=0` from `wait4()`, still on the runqueue, still
RUNNABLE-looking to future schedule decisions (well — `state` is
`WAITING` per the store, but nothing consults `state` outside
`sched_block`'s guard and `sched_wake`'s idempotence check, both of
which are on paths the parent never re-enters). The child, meanwhile,
was never picked — the parent's `sysret` returned control to userland
without any intervening `sched_pick_next_r15`. The parent spins,
the child never runs, deadlock.

### 3.2 D5b — no re-enqueue

The wake step writes `parent->state = RUNNABLE` but does not
`runq_enqueue(parent)`. Today this is a no-op-quality defect because
the parent is *still on the runqueue* — D5a's absence means the WAITING
store never dequeued it. But once D5a is fixed and `sched_block`
starts calling `runq_dequeue(current)`, the parent leaves the
runqueue. If the wake path then only flips `state` back to
RUNNABLE without a matching `runq_enqueue`, the parent lives in
scheduler limbo: `state == RUNNABLE`, but `runq_next == 0`. It will
never be selected again. Its child exits, its child gets ZOMBIE'd and
dequeued, no one else calls `runq_enqueue(parent)`, `sched_pick_next_r15`
runs and picks `_idle_tcb`, and the system idles forever with a woken
parent in memory that no one can reach.

D5a and D5b are one landing. Splitting them either breaks the flow
(D5a alone deadlocks on wake, D5b alone is dead code) or introduces a
transient regression window between two commits.

## 4. Design — D5a: split body-signal from dispatcher-block

Two candidate shapes:

**(A)** Keep the `state=WAITING` write in `sys_wait_body`; add a
`call sched_block` immediately after. `sched_block`'s precondition is
`_current_tcb.state == STATE_RUNNABLE` (per `wake_block.pdx:38-46,
#663 kassert_fail guard`); if we flip state to WAITING before calling,
the guard fires `kassert_fail(SUBSYS_SCHD, 167, 46, expected=RUNNABLE,
actual=WAITING)` and the kernel panics. To make this work we would
have to *not* set state at all in `sys_wait_body` (letting `sched_block`
do it, because `sched_block` internally sets `_current_tcb.state = 2`
at its step 2 after the guard passes). Which collapses to option (B).

**(B)** Remove the `state=WAITING` write from `sys_wait_body`
entirely. Have it return `rax=0, rdx=0` as a would-block signal. The
syscall dispatcher's `dispatch_wait4` sees `rax == 0` and calls
`sched_block`, which itself performs the RUNNABLE→WAITING state flip,
`runq_dequeue`, `sched_pick_next_r15`, and `sched_switch_r15`.

We pick **(B)**. Justifications:

1. **sched_block owns state=WAITING already.** `wake_block.pdx:56`
   writes `[rax + 8] = 2` between the guard and the dequeue. Removing
   `sys_wait_body`'s duplicate write is a delete, not an addition.

2. **Guard integrity.** `sched_block`'s `#663` guard exists precisely
   to catch "someone changed state under me" bugs. Feeding it a
   pre-WAITING state to bypass would erode a real safety net that
   already caught real defects in the R15.M7 development window.

3. **Keeps `sys_wait_body` a leaf-plus-pid_free.** The current
   function is entirely testable in a boot witness: no scheduler
   dependencies, no `_current_tcb` requirement, no kernel-stack
   assumptions. Preserving that testability means the boot witness
   (`kernel_main.pdx:2011`) can continue to run sub-tests A/B/C
   without needing to set up a fake `_current_tcb` or a runqueue.
   `sched_block`'s side effects, being outside the body, are covered
   by the existing `block_wake_witness` (`kernel_main.pdx:6679`).

4. **Dispatcher is the composition point.** `dispatch_wait4` already
   composes body + user-pointer writeback of `wstatus`. Adding
   sched_block + wake-result-read to that composition is a natural
   extension, mirrored by `dispatch_exit`'s composition (`sys_exit_body`
   + `runq_dequeue` + `sched_pick_next_r15` + `sched_switch_r15`).

## 5. Design — D5b: sys_exit wake path adds runq_enqueue(parent)

Straightforward addition at the tail of the six-step wake path. After
the three stores (wait_result_pid, wait_result_status, state), call
`runq_enqueue(parent)`. Register discipline:

| Reg  | State at step-6 entry | Role after runq_enqueue add            |
|------|-----------------------|----------------------------------------|
| rdi  | current (caller-save) | argument to runq_enqueue = parent       |
| r8   | parent slab           | consumed by move-into-rdi, then dead    |
| rax  | scratch               | needs no preserve — step-6 is terminal  |

Alignment: entry rsp %16 == 8 (SysV call convention).
`sys_exit_body`'s existing prologue is `push rdi ... pop rdi` around
`orphan_adopt`, restoring rsp %16 == 8 after `pop rdi`. The new call
therefore needs a fresh 8-byte alignment. Use the standard `sub rsp,
8; call runq_enqueue; add rsp, 8;` idiom (mirrors `dispatch.pdx`'s
`#672 MEDIUM SysV alignment pad` in every leaf-call site).

Effects/capabilities widening: `sys_exit_body` was `!{mem} @{}`.
Adding a call to `runq_enqueue` (`!{mem} @{sched}`) widens the
capabilities to `@{sched}`. Effects stay `!{mem}` — runq_enqueue is
pure memory, no sysreg. The orphan_adopt call was already inside a
`@{}` context and reads/writes memory; that stays.

## 6. Kernel-stack discipline across sched_block

Here is the exact trace for a fork+wait+exit round-trip after D5+D6
land, single-CPU, no timer preemption inside syscalls (IF=0 gated by
IA32_FMASK per `msr.pdx:30`):

```
[ parent in userland, calls wait4() ]
    → syscall_entry (entry.pdx)
        - lea rsp = &_syscall_kernel_stack + 16384      (fixed shared stack)
        - push rcx (user RIP); push r11 (user RFLAGS); push rax (sysno)
        - pop rdi (sysno → arg0); shuffle SysV
        - call syscall_dispatch                          (RA slot on shared stack)
    → syscall_dispatch → dispatch_wait4
        - mov rax, [_current_tcb]; mov rdi, rax          (rdi = parent TCB)
        - push rsi                                       (save wstatus user ptr)
        - call sys_wait_body                             (RA slot on shared stack)
            - scans _pid_table; no zombie; returns rax=0
        - pop rsi
        - cmp rax, 0; je dispatch_wait4_would_block
        - push rsi                                       (save wstatus again)
        - call sched_block                               (RA on shared stack)
            - _current_tcb.state = WAITING
            - runq_dequeue(parent)
            - next = sched_pick_next_r15()               (returns child)
            - sched_switch_r15(child):
                * pushfq; cli
                * save parent's rbx/rbp/r12-r15 → parent.regs_save.{56..96}
                * save parent's rsp → parent.regs_save.rsp @ +32
                * save &sched_switch_r15_continuation → parent.regs_save.rip @ +40
                * _current_tcb ← child
                * rsp = child.regs_save.rsp
                * push child.regs_save.rflags; push child.regs_save.rip
                * restore child's callee-saves
                * ret → child.regs_save.rip == &sched_switch_r15_continuation
            - continuation: popfq; ret
                * ret consumes the top of child's kernel stack; for a
                  fresh forked child this is &sys_fork_child_landing
                * child runs in ring-3 (via iretq inside landing)
[ child in userland, does its thing, calls exit(42) ]
    → syscall_entry (same shared stack, rsp reset to top — parent's
      saved stack contents at +16376/-16368/-16360 are still there
      because syscall_entry's push chain overwrites +16376/-16368/-16360
      unconditionally, which is safe because the parent's saved rsp
      pointing into that range does not survive — see §8 caveat)
    → syscall_dispatch → dispatch_exit
        - call sys_exit_body                             (child → ZOMBIE)
            - state = ZOMBIE
            - exit_status = 42
            - orphan_adopt(child->pid)                    (reparent to 1)
            - parent = _pid_table[child.parent_pid]
            - if parent.state == WAITING:
                - parent.wait_result_pid = child.pid
                - parent.wait_result_status = 42
                - parent.state = RUNNABLE
                - runq_enqueue(parent)                    ← D5b addition
        - runq_dequeue(child)                             (child now ZOMBIE)
        - next = sched_pick_next_r15()                   (returns parent)
        - sched_switch_r15(parent)
            - save child.rsp etc. (never read again)
            - _current_tcb ← parent
            - rsp = parent.regs_save.rsp                 (points into shared stack)
            - push parent.regs_save.rflags; push parent.regs_save.rip
            - restore parent's callee-saves
            - ret → &sched_switch_r15_continuation
        - continuation: popfq; ret
            - ret pops the top of parent's saved stack, which was the
              RA for the `call sched_block` above → returns to
              dispatch_wait4 at the instruction after `call sched_block`
[ back in dispatch_wait4, we are now "the parent", control has resumed ]
        - pop rsi                                        (wstatus user ptr)
        - mov rax, [_current_tcb]                        (parent, again)
        - mov ecx, [rax + 1704]                          (wait_result_pid)
        - mov edx, [rax + 1708]                          (wait_result_status)
        - mov rax, rcx                                   (rax = zombie pid)
        - cmp rsi, 0; je done
        - mov [rsi], edx                                 (writeback status)
        - ret                                            (to syscall_dispatch, to
                                                          syscall_entry, to sysret)
[ parent in userland, wait4() returns pid=2, *wstatus = 42 ]
```

### 6.1 Two subtleties in that trace

**Shared kernel stack.** All tasks share `_syscall_kernel_stack`
(`kernel_stack.pdx:10`). When child enters its syscall via
`syscall_entry`, it does `lea rsp, [rip + _syscall_kernel_stack +
16384]` — this **overwrites** wherever the parent's saved rsp was
pointing. That is safe *only* because the parent's `sched_switch_r15`
saved rsp is deep in that stack (past the point that the child's push
chain writes to). Specifically the parent's saved rsp lands at
`_syscall_kernel_stack + 16384 - N` where N is the push chain depth
below `dispatch_wait4`'s `push rsi` before `call sched_block`. The
child's push chain (`push rcx; push r11; push rax` = 24 bytes deep)
does not reach that far.

That is a soundness accident that happens to work at this call depth.
It is the same latent concern flagged in D6's §14 followups; D5's
landing does not increase or decrease the concern. Longer-term, each
task must have its own kernel stack (per-TCB, populated at task_new
time). That is D-not-yet.

**Kernel-side wait_result_{pid,status} are stale on second call.**
`sys_exit_body`'s wake path writes wait_result_{pid,status} on every
matched wake. If the parent calls wait4() twice, the second wait4 sees
stale fields from the first wake unless someone clears them. Two
mitigations:

* On wake-read at `dispatch_wait4`, we could store 0 back to the two
  fields. Explicit but adds two writes per wait4.
* Rely on the guard `parent.state == WAITING` in
  `sys_exit_body:97-100`. When the parent isn't blocked, the wake
  path is skipped — no stale write to worry about. On the next
  wait4, the parent enters `sys_wait_body`, hits the runtime scan,
  finds a zombie or gets ECHILD or goes into WAITING again; the
  post-`sched_block` wait_result read is only reached after a fresh
  wake fired the store. Stale values in wait_result_{pid,status}
  from a prior epoch are never re-read.

We take the second (no explicit clear). Simpler, and correct today.
If a future refactor factors out "reap by wait_result" as a
standalone primitive, it should clear post-read to keep the semantics
robust.

## 7. Interaction with D4 (init post-iretq #GP) and D3 (dump.pdx vec corruption)

D5 is a **structural** landing: after D5, the parent task can
voluntarily yield inside `wait4()` and the child can execute; the wake
path re-enqueues the parent so it can pick up the child's exit status.

For `#723`'s AC (`CHILD HELLO 42\nWAIT: pid=2 status=42`) to appear on
wire, additional pieces must land:

* **D4** — init post-iretq #GP. Init currently faults immediately
  after entering ring-3. Without D4, init never calls fork/wait, so
  the parent-side wait_result chain doesn't exercise. D5 is
  **wire-invisible** without D4.
* **D3** — dump.pdx vec corruption. Concerns the diagnostic path
  when things go wrong. Orthogonal to the happy path — D3 does not
  block the AC directly, but its presence may mask other regressions
  when they arise. Filed separately.

D5 stands on its own for the invariant "a parent blocked in
`wait4()` correctly yields to the scheduler, and a child's exit
correctly wakes and re-enqueues the parent." It is verifiable
structurally today via the existing witnesses (`sys_wait_witness`,
`sys_exit_witness`) with the modifications listed in §9.

## 8. Contract discipline

* `sys_wait_body` **stays a leaf-plus-pid_free**: no scheduler
  dependency, no `_current_tcb` requirement, no runqueue interaction.
  It remains fully witness-testable in a boot context. It returns
  `rax=0, rdx=0` as the "would-block please block me at the dispatch
  layer" signal. Callers other than `dispatch_wait4` (there are
  none today, but future waitpid variants, tests, ...) must honor
  that signal or become the block-composition point themselves.
* `dispatch_wait4` **is the composition point**: it owns the
  block-then-read-wait-result orchestration. If a future non-wait4
  entry point wants the same "signal + block + reap" chain, it
  should factor out this composition into a `sys_wait_or_block`
  helper — not the leaf body.
* `sys_exit_body`'s wake path **owns runq_enqueue(parent)**. This
  mirrors the pattern in `sched_wake` (`wake_block.pdx:80`):
  state=RUNNABLE first, then `runq_enqueue`. `sys_exit_body` cannot
  simply call `sched_wake(parent)` because `sched_wake` reads
  `parent.state` and early-exits if already RUNNABLE — but between
  the state store and the enqueue call, `sched_wake` would say "no
  wake needed" and return without enqueueing. The inline two-step
  (state store then explicit `runq_enqueue`) sidesteps that
  ordering trap. Alternative: reorder `sched_wake` to
  runq_enqueue-first-then-state-store. Not done here — that touches
  the sched_wake API surface and is out of scope for D5.
* **Failure paths.** None new. `runq_enqueue` never fails at R17.M0
  (single-CPU, no allocation, unlimited-length circular list).

## 9. Witness updates

### 9.1 `sys_wait_witness` sub-test B
(`kernel_main.pdx:2065-2113`)

Currently asserts:
```
call sys_wait_body;
cmp rax, 0; jne fail;                 // would-block signal
mov eax, [r12 + 8]; cmp rax, 2; jne fail;   // state == WAITING
```

After D5a: `sys_wait_body` no longer writes `state=WAITING` (that's
now `sched_block`'s job at the dispatch layer, not the body's). The
`state == WAITING` assertion must therefore change to `state == NEW`
(0) — proving the body is a pure "check + signal-would-block" leaf
with no scheduler side-effect. The `rax == 0` assertion continues
to prove the would-block signal.

### 9.2 `sys_exit_witness` sub-test 2
(`kernel_main.pdx:1929-1996`)

Currently asserts wake stores (state, wait_result_{pid,status}). After
D5b, the wake path also calls `runq_enqueue(parent2)`. Preconditions:

* `runq_init` must have been called (else runq_enqueue writes into
  a NULL `head.prev + 432`, faulting).
* `parent2` must have `runq_next == runq_prev == 0` (task_new's
  `rep_stosq` handles this).

Add `call runq_init;` at the top of sys_exit_witness (idempotent per
runqueue.pdx §runq_init "Idempotent: safe to re-call"; mirrors
sys_fork_witness's pattern at `kernel_main.pdx:2375`). Add a positive
assertion: after `sys_exit_body(child2, 99)`, `_runq_head_slot.next
== parent2` — proving parent2 was enqueued. Add cleanup:
`runq_dequeue(parent2)` before witness exit, so the runqueue
returns to empty (mirrors sys_fork_witness's cleanup at
`kernel_main.pdx:2516`).

Sub-test 1 (non-WAITING parent, no reap) does **not** exercise the
wake path — the guard `cmp rax, 2; jne sys_exit_done` at
`sys_exit.pdx:99-100` bails before the runq_enqueue call. No changes
needed there.

## 10. Register discipline changes

### 10.1 `sys_wait_body`

Delete two instructions (`mov rax, 2; mov [rbx + 8], eax`). No
register-set change; the fallthrough to `xor rax, rax; xor rdx, rdx;
jmp sys_wait_return` is preserved. Alignment unchanged. Effects and
capabilities unchanged (`!{mem} @{}`).

### 10.2 `dispatch_wait4`
(`dispatch.pdx:241-251`)

Adds a would-block branch. Extra registers touched:

| Reg  | Role at extended dispatch_wait4                                    |
|------|--------------------------------------------------------------------|
| rax  | scratch — sys_wait_body return, then _current_tcb reload, then pid |
| rcx  | scratch — wait_result_pid load                                     |
| rdx  | scratch — wait_result_status load                                  |
| rsi  | wstatus user ptr — stack-preserved across sys_wait_body AND        |
|      | sched_block                                                        |
| rdi  | (inbound) sysno-then-current; consumed before block                |

Alignment: entry rsp %16 == 8; `push rsi` before each of two calls
brings it to %16 == 0; `pop rsi` restores %16 == 8 for the trailing
writeback and `ret`. Effects/capabilities inherit dispatch's
`!{mem, sysreg} @{cap, sched}` — sched_block adds nothing new.

### 10.3 `sys_exit_body`
(`sys_exit.pdx:66-114`)

Adds three instructions (`sub rsp, 8; mov rdi, r8; call
runq_enqueue; add rsp, 8;`) between the state store and
`sys_exit_done`. Widens capabilities from `@{}` to `@{sched}`.
Justification string updated to mention runq_enqueue's role and the
alignment idiom.

## 11. paideia-as reserved-label discipline

`dispatch_wait4_would_block`, `dispatch_wait4_writeback`,
`dispatch_wait4_done` — all `dispatch_wait4_`-prefixed local labels,
none clash with reserved keywords (`loop`, `if`, `retry`, ...).

## 12. Byte-count discipline for new rodata

No new rodata is introduced. No changes to strings, tags, or panic
messages. The three new offset constants live in the existing
`sys_exit.pdx` `TASK_OFF_WAIT_RESULT_{PID,STATUS}` constants (already
defined at 1704/1708); D5 does not add or move them.

## 13. Verification checklist

1. Kernel builds clean.
2. Smoke matrix: `boot_r8_only + boot_r10 + boot_r11 + boot_r12 +
   boot_r12_denial + boot_r14b_hivma + boot_r14b_kpti +
   boot_r14b_ipi + boot_r14b_loader` all pass (the pre-push gate).
3. Additional single-mode verification: `boot_r15_process`,
   `boot_r17_init` — the modes that emit `R15 SYS EXIT OK` and
   `R15 SYS WAIT OK`. Both fingerprints must still appear.
4. Disasm confirms:
   - `sys_wait_body` no longer writes `state @ +8` on the
     would-block path (only path that writes state was the WAITING
     write we deleted).
   - `dispatch_wait4` includes a `call sched_block` on the rax==0
     branch, followed by reads of `[_current_tcb + 1704]` and
     `[_current_tcb + 1708]`.
   - `sys_exit_body` includes a `call runq_enqueue` after the
     state=RUNNABLE store in the wake path.

## 14. Followups (deferred, own landings)

* **D4** — init post-iretq #GP. Blocks wire visibility of #723 AC.
* **D3** — dump.pdx vec corruption. Diagnostics.
* **Per-task kernel stack allocation.** Currently a single
  `_syscall_kernel_stack` is shared; D5's block path relies on this
  being deep enough that the child's push chain does not overwrite
  the parent's saved rsp region. Works at current call depth; not
  general.
* **wait_result clear-on-read.** If a future refactor factors out
  "reap by wait_result" as a standalone primitive, it should clear
  the two u32 slots post-read to make the semantics robust against
  a caller re-entering the wait path without going through
  `sched_block` first.
* **sched_wake reordering.** Could take `sched_wake` from
  "state-then-enqueue" to "enqueue-then-state" so that the wake
  path in `sys_exit_body` becomes `call sched_wake(parent)` instead
  of the inlined two-step. Not done here — API surface change.

## 15. Cross-references

- `design/kernel/r17-m0-724-d2-sys-exit-terminate.md` (D2 — exit
  dispatch real termination path)
- `design/kernel/r17-m0-724-d6-fork-enqueue.md` (D6 — fork enqueue +
  regs_save init; §7 explicitly flags D5 as follow-up)
- `src/kernel/core/sched/wake_block.pdx` (sched_block/sched_wake
  primitives; source of the RUNNABLE-only guard)
- `src/kernel/core/sched/switch.pdx` (sched_switch_r15 mechanics;
  the continuation trampoline that D5's resume path returns via)
