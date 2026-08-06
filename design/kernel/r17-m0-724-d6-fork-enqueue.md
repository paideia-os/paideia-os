# R17-M0-724-D6 — fork enqueue + regs_save init

Status: **design + implementation**
Scope: paideia-os, D6 defect surfaced by debugger verification of D2 on
commit `6a57f8d`.
Depends on: none for structural landing; wire-visible child execution
additionally requires D4 (init post-iretq #GP) and D5 (sys_wait4 real
blocking) — see §7.

## 1. Problem — verbatim from the D6 comment

> `task_new` (`src/kernel/core/sched/task_pool.pdx`) and `sys_fork_body`
> (`src/kernel/core/syscall/handlers/sys_fork.pdx`) never call
> `runq_enqueue`, and `task_new` never populates the child's
> `regs_save.rsp / regs_save.rip`. Only `init` gets `runq_enqueue`'d —
> once, at `kernel_main.pdx:6908`.
>
> Consequence: forked children are structurally inert. `fork()` returns
> cleanly in the parent (parent gets child pid in rax), but the child
> TCB sits in the pool with no runqueue entry and no restore-state, so
> `sched_pick_next_r15` never selects it and it can never run.

## 2. Current state — what each site does today

### 2.1 `task_new` (`task_pool.pdx:71`)

Allocates a pid slot, zeroes a 2224-byte slab, writes `user_pml4_pa`
(@+16), `pid` (@+0), `parent_pid` (@+4). Everything else stays at
rep-stosq zero — including all `regs_save.*` fields (offsets +32..+96),
`state` (@+8, so STATE_NEW), the fd_table (@+168..), and the runq_next
/runq_prev links (@+432 / +440). Returns slab pointer in rax. **Never
touches the runqueue.** Contract per §548: low-level allocator, not a
"schedule me" call.

### 2.2 `sys_fork_body` (`sys_fork.pdx:25`)

Six phases: prologue → `task_new(parent)` → `aspace_clone_cow` →
fd_table copy → `fd_inherit_hold` → return child pid in rax, rdx=0.
No `runq_enqueue`. No `regs_save.rsp/rip/rflags` init. State stays at
STATE_NEW. The comment explicitly says "*scheduler-side child return
materialization*" is reserved (rdx) — meaning the design **planned** for
child materialization to happen elsewhere but never wired it.

### 2.3 `init` bootstrap (`kernel_main.pdx:6908`)

Init's setup happens outside fork: `init_bootstrap_witness` calls
`task_new(NULL)`, then `elf_lite_load(init.elf)` stashes `e_entry` at
`[_init_task + 1712]`, then post-boot the boot path allocates a user
stack via `user_stack_alloc`, wires `fd_table[0..2]` to `_tty0`,
publishes `_current_tcb = init`, sets `init.state = STATE_RUNNABLE`,
calls `runq_enqueue(init)`, and `sti; enter_userland_initial(entry_rip,
user_rsp, user_pml4_pa)`. Init enters ring-3 via a direct `iretq` (not
via `sched_switch_r15`), so its `regs_save` fields never needed to be
populated — the scheduler only reads them on **switch-back-in**.

### 2.4 `sched_switch_r15` swap-in mechanics
(`switch.pdx:98`)

The swap-in half (relevant to the child's *first* schedule) is:

```
mov rsp, [rdi + 32]           ; rsp = next.regs_save.rsp
mov rcx, [rdi + 48]
push rcx                       ; push next.regs_save.rflags
mov rcx, [rdi + 40]
push rcx                       ; push next.regs_save.rip
mov rbx, [rdi + 56] ... r15    ; restore callee-saves
ret                            ; pops the pushed rip
```

The `ret` jumps to `next.regs_save.rip`. For a resumed task this is
`sched_switch_r15_continuation`. For a **fresh** task the design is
uniform (§6.2 of #564): also point at
`sched_switch_r15_continuation`, but pre-place the fresh entry point as
a return-address on the fresh task's kernel stack so continuation's
final `ret` lands there.

`sched_switch_r15_continuation` (`switch.pdx:202`):

```
popfq          ; consume the pushed rflags
ret            ; consume the pushed RA (fresh entry point)
```

So for a fresh task, the kernel-stack layout at first schedule must be:

```
[regs_save.rsp - 0]  = fresh_entry_point_address  (consumed by continuation's ret)
```

with `regs_save.rip = &sched_switch_r15_continuation` and
`regs_save.rflags = <safe default>`. The two pushes inside
`sched_switch_r15` write into `[rsp-8]` and `[rsp-16]`; those slots
must be within writable kernel memory too.

## 3. Root cause

Fork semantics require the child to eventually execute the instruction
*immediately after* the parent's `syscall` instruction in user mode,
with `rax = 0` (the child's fork return value; the parent already got
`rax = child->pid`). The child inherits the parent's aspace (via
`aspace_clone_cow`) and fd_table, but nothing today teaches the
scheduler *how* to launch it. Without

  (a) a fresh entry point that walks ring-transition state and iretq's
      to ring-3 with rax=0, and
  (b) `regs_save.rsp/rip/rflags` pointing at that entry point via the
      uniform trampoline convention, and
  (c) the child on the runqueue,

`sched_pick_next_r15` cannot pick the child (walks `_runq_head_slot`'s
circular list — empty of children), and even if it could, `sched_switch_r15`
would jump to `[child + 40] == 0` and triple-fault.

D6 is (a) + (b) + (c) landed together. Landing any subset breaks the
others: (c) alone triple-faults on first pick; (a)+(b) without (c) is
dead code because the child is never selected.

## 4. Design choice — child re-entry to ring-3

Two candidates were considered per the task brief:

**(A)** A dedicated `sys_fork_child_landing` shim in kernel that sets
rax=0, rdx=0 and does `iretq` back to the parent's saved user trap
frame (which the child inherited).

**(B)** Copying the parent's trap frame into the child's kernel stack +
setting `regs_save.rip` to a shim that pops that frame with `iretq`.

We pick **(A)**. Justifications:

1. **Symmetric with `enter_userland_initial`.** The kernel already has
   the exact primitive we need: build a 5-slot iretq frame in the
   trampoline-data scratch page (`_iretq_frame_scratch`), do
   `swapgs; cli; mov cr3, <user_pml4_pa>; lea rsp, [rip +
   _iretq_frame_scratch]; iretq`. Reusing this pattern keeps a single
   audit surface for the "enter ring-3" primitive rather than two
   variants of it.

2. **KPTI trampoline discipline.** After the `mov cr3` to the child's
   user_pml4, only pages explicitly mapped by `kpti_build_user_pml4`
   are addressable. Those are: `.text.syscall_trampoline` (a single
   4 KiB page containing `entry.o` and `enter_user.o`),
   `.data.syscall_trampoline` (the trampoline data page, including
   `_iretq_frame_scratch`), `_kernel_stack`, IST stacks, GDT/IDT/TSS,
   `.text.isr_trampoline`. The child's kernel *stack* (a per-slab
   landing area, see §6) is **not** mapped in user_pml4. Option (B)
   would need every child's per-task kernel stack mapped into every
   user aspace — a bigger footprint and a per-fork
   `kpti_build_user_pml4` call. Option (A) uses only pages already
   mapped.

3. **rax=0 discipline.** enter_userland_initial does not zero rax
   before iretq (it holds the CR3 value at that moment, which then
   leaks into userland). A dedicated landing lets us xor rax/rdx just
   before iretq, satisfying fork's ABI cleanly.

4. **No trap-frame copy needed.** The parent's saved user rip/rsp/rflags
   are already fixed locations in trampoline data at fork time (see
   §5). We snapshot three u64s into the child's slab; no wholesale
   frame copy.

**Placement.** `sys_fork_child_landing` lives in
`src/kernel/core/syscall/enter_user.pdx` so it is linked into
`.text.syscall_trampoline` (per `link.ld:52-53`), and therefore
addressable both before and after the CR3 flip via the same VA.

## 5. Where does the child's user-mode rip/rsp/rflags come from?

At fork time the parent is mid-syscall. `syscall_entry` (entry.pdx)
saved:

  * user rsp → `_saved_user_rsp[0]` (trampoline data, fixed address).
  * user RIP (`rcx` from `syscall`) → `[_syscall_kernel_stack + 16384 - 8]`
    (pushed as the very first push after setting the kernel rsp).
  * user RFLAGS (`r11` from `syscall`) → `[_syscall_kernel_stack + 16384 - 16]`
    (second push).

Between the push chain and `sys_fork_body`, one additional push
(`push rax` = syscall#) then a `pop rdi` (syscall# → arg0) executes,
leaving these two slots undisturbed. `sys_fork_body` reads them
directly by absolute RIP-relative address arithmetic — no dependency
on the current rsp value inside `sys_fork_body`.

The three values are snapshotted into three new fields of the child's
task slab:

| Offset | Name              | Type | Source                                            |
|--------|-------------------|------|---------------------------------------------------|
| 1720   | fork_user_rip     | u64  | `[_syscall_kernel_stack + 16384 - 8]`             |
| 1728   | fork_user_rsp     | u64  | `[_saved_user_rsp]`                               |
| 1736   | fork_user_rflags  | u64  | `[_syscall_kernel_stack + 16384 - 16]` (IF=1)     |

These offsets are unused today (nearest allocated field is init's
`e_entry` stash at +1712; wait_result fields at +1704/+1708). They sit
inside the 2224-byte slab so `task_free`'s rep-stosq already zeroes
them at teardown. No slab layout change; only three new offset
constants published in `sys_fork.pdx`.

## 6. Child kernel-stack layout at first schedule

The child needs a **landing stack** just deep enough for the two
`sched_switch_r15` swap-in pushes (rflags + rip = 16 bytes) plus a
pre-placed return address for `sched_switch_r15_continuation`'s final
`ret` (8 bytes). We reuse the tail of the child's own slab:

| Slab offset | Contents (pre-schedule)                                        |
|-------------|----------------------------------------------------------------|
| +2200       | (scratch — will be `regs_save.rip` push from switch's swap-in) |
| +2208       | (scratch — will be `regs_save.rflags` push)                    |
| +2216       | **`&sys_fork_child_landing`** — consumed by continuation's ret |

`child.regs_save.rsp = child + 2216`.

Trace of the first swap-in with `rdi = child`:

```
mov rsp, [rdi + 32]        ; rsp = child + 2216
mov rcx, [rdi + 48]        ; rcx = child.rflags (= 0x2, IF=0 — see §6.1)
push rcx                    ; rsp = child + 2208, [child+2208] = 0x2
mov rcx, [rdi + 40]        ; rcx = &continuation
push rcx                    ; rsp = child + 2200, [child+2200] = &cont
mov rbx, [rdi + 56] ...     ; restore callee-saves (all zero for fresh child)
ret                         ; pops &continuation; jumps there; rsp = child + 2208

continuation:
popfq                       ; pops 0x2 → rflags; rsp = child + 2216
ret                         ; pops &sys_fork_child_landing; rsp = child + 2224 (past slab)
                            ; jumps to sys_fork_child_landing
```

After the final `ret`, rsp = child + 2224 (end of slab boundary). The
landing does **not** touch rsp before it overwrites it with `lea rsp,
[rip + _iretq_frame_scratch]`, so the ephemeral out-of-range rsp is
observationally invisible.

### 6.1 Why regs_save.rflags = 0x2 (IF=0), not 0x202 (IF=1)

Sole purpose of the fresh child's saved rflags is to control IF when
continuation's `popfq` runs, one instruction before landing's `cli`.
If IF=1 at that boundary, a timer interrupt could fire on the
`continuation.ret → sys_fork_child_landing` transition; the interrupt
would push its 5-slot iretq frame onto the child's landing stack —
which has 24 bytes total — overflowing into unrelated slab fields at
+2192, +2184, ... corrupting the child's TCB. Landing entering with
IF=0 makes this impossible: the `cli` becomes redundant-safe, the two
pushes for the iretq frame in `_iretq_frame_scratch` happen with IF=0,
the user-mode IF=1 comes purely from `fork_user_rflags` at iretq.

R10 witness pattern (kernel_main.pdx:6534) uses 0x202 because its
witness runs before `sti` — no interrupts to worry about. Not
applicable at post-init runtime.

## 7. Wire-visible AC — cross-defect dependencies

D6 is a **structural** landing: `sys_fork_body` now enqueues a
runnable, iretq-ready child, and `sched_pick_next_r15 → sched_switch_r15
→ continuation → sys_fork_child_landing → iretq` is a complete path
from a fork() syscall to the child running in ring-3 with rax=0.

For `#723`'s AC (`CHILD HELLO 42\nWAIT: pid=2 status=42`) to appear on
wire, additional pieces must land:

* **D4** — init post-iretq #GP. Init currently faults immediately
  after entering ring-3; without D4 there is no fork() ever invoked.
* **D5** — sys_wait4 real blocking. `sys_wait_body` today sets
  `current->state = STATE_WAITING` and returns rax=0 without calling
  `sched_block`. Without D5 the parent never voluntarily yields, so
  `sched_pick_next_r15` is never called after init's initial run, so
  the child is never picked from the runqueue — even though it is
  properly enqueued and ready.
* **D5 companion** — when the ISR/exit path wakes a WAITING parent,
  the parent needs `runq_enqueue` because D5's `sched_block` will
  `runq_dequeue` on the way to WAITING. `sys_exit_body`'s wake path
  currently only flips state to RUNNABLE; it must also
  `runq_enqueue(parent)`. Filed as D5-companion (deferred, own
  landing).

D6 stands on its own for the invariant "a child forked from a
runnable parent is a first-class scheduler citizen" — verifiable
today via a witness (not part of this landing) that manually calls
`sched_pick_next_r15` post-fork and asserts the head is the child;
follow-ups D4/D5 make the runtime chain observable on wire.

## 8. Contract discipline

* `task_new` **stays low-level**: no runqueue side effect, no
  regs_save init. It remains reusable for any future task-creation
  path that wants tighter control (kernel threads, kernel tasks that
  don't come from fork, deferred-until-ready worker pools, ...).
* `sys_fork_body` **is the composition point**: it owns fork-specific
  policy (child inherits parent's user context, materialize child
  return-registers, publish on runqueue). Discipline mirrors the
  existing `sched_wake` pattern in `wake_block.pdx:80`: set
  STATE_RUNNABLE then `runq_enqueue`.
* **Enqueue timing.** All of `regs_save.{rsp,rip,rflags}`, the
  in-slab landing return-address slot at +2216, and
  `fork_user_{rip,rsp,rflags}` at +1720/+1728/+1736 are populated
  **before** the state flip to STATE_RUNNABLE and the runq_enqueue
  call. Even at M0 single-CPU no-preemption-inside-syscall, this
  ordering makes the fresh-child invariant hold under any future
  preemption-inside-syscall design change without a retrofit.
* **Failure paths.** No new failure paths are introduced; the
  materialization is deterministic given task_new + aspace_clone_cow
  + fd_inherit_hold have all succeeded. On rollback (existing
  `sys_fork_fail_rollback`), the child slab is torn down by
  `aspace_teardown + pid_free` — the new fields have no external
  refcount so no additional cleanup needed.

## 9. Register discipline changes in `sys_fork_body`

Existing prologue pushes `rbx, r12, r13` (3 pushes → rsp %16 == 0 at
call sites; `r13` currently only for alignment). The new work
(materialize + enqueue) needs:

| Reg  | Role                                              |
|------|---------------------------------------------------|
| rbx  | current (parent) — unchanged                      |
| r12  | child slab — unchanged                            |
| rcx  | scratch — write-target and RIP-load               |
| rax  | scratch (address arithmetic for kstack top)       |
| rdi  | argument to `runq_enqueue` (= r12 at call site)   |

No additional callee-save spills required. `r13` remains alignment-
only. `sched_wake`/`sched_wake_r15` semantics are inlined into
sys_fork_body (state=RUNNABLE + runq_enqueue) rather than called out,
because `sched_wake` early-exits if the target is already RUNNABLE —
which a fresh child is not, but the two-instruction inline is cheaper
and clearer than the guard-then-set indirection.

## 10. `sys_fork_child_landing` register discipline

Entry: no caller — arrival via `sched_switch_r15_continuation → ret`.
All registers other than rsp are indeterminate (they hold the child's
initial callee-save state, which is zero from task_new's rep-stosq,
plus whatever caller-save state the scheduler left).

Sequence (in `enter_user.pdx`, so linked into
`.text.syscall_trampoline`, addressable pre- and post-CR3-flip):

```
cli                                     ; belt-and-braces (rflags=0x2 already IF=0)
mov rax, [rip + _current_tcb]           ; rax = child TCB
mov rcx, [rax + 1720]                   ; rcx = fork_user_rip
mov rdx, [rax + 1728]                   ; rdx = fork_user_rsp
mov r8,  [rax + 1736]                   ; r8  = fork_user_rflags
mov r9,  [rax + 16]                     ; r9  = user_pml4_va (phys_alloc form)
mov r10, 0xFFFF800000000000
sub r9, r10                             ; r9 = user_pml4_pa (genuine PA)

lea r11, [rip + _iretq_frame_scratch]
mov [r11 + 0],  rcx                     ; RIP
mov rcx, 0x2B
mov [r11 + 8],  rcx                     ; CS (user)
mov [r11 + 16], r8                      ; RFLAGS (parent's IF=1)
mov [r11 + 24], rdx                     ; RSP (user)
mov rcx, 0x23
mov [r11 + 32], rcx                     ; SS (user)

swapgs                                   ; kernel GS -> user GS
mov rax, r9
mov cr3, rax                             ; flip to child user PML4

lea rsp, [rip + _iretq_frame_scratch]    ; point rsp at pre-built frame
xor rax, rax                             ; fork() returns 0 in child
xor rdx, rdx
iretq
ud2                                      ; unreachable sentinel
```

Order rationale:

1. TCB fields (kernel .bss, not mapped in user_pml4) are read
   **before** the CR3 flip.
2. Writes to `_iretq_frame_scratch` (trampoline data, mapped in BOTH
   PML4s) happen before the CR3 flip so they're semantically
   equivalent to the enter_userland_initial pattern.
3. `swapgs` before `mov cr3` mirrors `enter_userland_initial`'s
   ordering (kernel_main.pdx:6885 boundary comment); on the way OUT
   of the kernel, swapgs is idempotent-order-independent with respect
   to cr3, but keeping the same ordering as the peer function means a
   single audit surface for "how kernel primitives leave to ring-3".
4. `mov cr3` is the last kernel-side operation; the next instruction
   fetch (`lea rsp, ...`) uses the new (user) CR3. That fetch is safe
   because `sys_fork_child_landing` lives in the trampoline text page
   mapped under user PML4.
5. `xor rax, rax; xor rdx, rdx` deliberately follow the CR3 flip.
   Placing them before would waste a register write since we need rax
   as a CR3 conduit anyway; keeping them adjacent to `iretq` reads
   cleanly as "clear return regs, then hand off".

## 11. Correctness of the reused `_iretq_frame_scratch`

`_iretq_frame_scratch` is a single-entry global in
trampoline data (per `trampoline_data.pdx:10`). Concurrent use would
corrupt the frame. Safety today:

* Only two writers exist: `enter_userland_initial` (boot-time
  init entry, once) and `sys_fork_child_landing` (first schedule of
  each forked child).
* `enter_userland_initial` runs before any second task exists.
* `sys_fork_child_landing` runs with IF=0 from `cli` through `iretq`.
  Single-CPU M0 → no cross-CPU concurrency. No syscall/IRQ can
  preempt this window.

On SMP (deferred to R18+), a per-CPU scratch is required. Flagged in
§14 as a followup.

## 12. Byte-count discipline for new rodata

No new rodata is added by D6. The three new offset constants in
`sys_fork.pdx` are compile-time `let` bindings, not `.rodata` strings.
Byte-count discipline (text bytes + 1 NUL) does not apply.

## 13. paideia-as reserved-label discipline

`sys_fork_child_landing` is a single straight-line block with no
internal labels — no clash with reserved keywords (`loop`, `if`,
`retry`, ...). `sys_fork_body`'s only added local labels (if any
prove necessary) are prefixed with `sys_fork_` per project style.

## 14. Followups

* **D5** (own landing): `sys_wait_body` must invoke `sched_block`
  when no zombie is present. Without this, D6's runtime effect is
  invisible on wire (parent never yields → scheduler never picks
  child).
* **D5 companion**: `sys_exit_body` wake path must
  `runq_enqueue(parent)` if D5 dequeues the WAITING parent from the
  runqueue.
* **Per-CPU `_iretq_frame_scratch`** when SMP lands.
* **Per-task kernel stack allocation**. Currently a single
  `_syscall_kernel_stack` is shared across all tasks; when task A
  blocks with rsp saved deep in this stack and task B enters a
  syscall (rsp reset to top), overlapping writes can corrupt A's
  saved region. Not a D6 bug — the current fork/wait/exit chain
  happens to be shallow enough that overlap doesn't occur — but a
  general soundness concern for multi-task workloads.

## 15. Verification checklist

1. Kernel builds clean.
2. Full 19-mode smoke matrix green.
3. Disasm confirms `sys_fork_child_landing` lives inside
   `.text.syscall_trampoline`'s single 4 KiB page (i.e., section size
   remains ≤ 0x1000 after the addition).
4. Disasm confirms `sys_fork_body` writes:
   - `[r12 + 1720]`, `[r12 + 1728]`, `[r12 + 1736]` (three fork_user_*
     stashes),
   - `[r12 + 40]` = `&sched_switch_r15_continuation` (regs_save.rip),
   - `[r12 + 48]` = 0x2 (regs_save.rflags, IF=0),
   - `[r12 + 2216]` = `&sys_fork_child_landing` (landing return
     address),
   - `[r12 + 32]` = r12+2216 (regs_save.rsp),
   - `[r12 + 8]` = 1 (state = STATE_RUNNABLE),
   - and calls `runq_enqueue` with `rdi = r12`.
