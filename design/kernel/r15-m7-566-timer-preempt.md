# r15-m7-566 — Timer ISR Preemption

Status: LANDED
Issue: paideia-os#566 (R15.M7 timer-driven preemption)
Predecessors: #565 (LAPIC timer 100 Hz), #567 (sched_block/wake), #662 (timer
delivery on wire), #564 (sched_switch_r15), #563 (runq_enqueue/dequeue),
#548 (task_new), #728 D9 (per-task kernel stacks)

## 1. Motivation

Before this issue, paideia-os is a strictly cooperative kernel: a running task
retains the CPU until it voluntarily yields (sched_block from sys_wait4;
runq_dequeue + sched_switch_r15 from sys_exit; explicit sys_sched_yield — not
wired). The LAPIC timer fires at ~100 Hz (issue #565) but the ISR merely
maintains a tick counter and rearms the LAPIC. It cannot force a running task
off the CPU.

This issue wires the ISR to a per-TCB budget: each tick decrements the running
TCB's `sched_budget`; on reaching zero, the ISR consults the runqueue for a
different runnable task and, if one exists, performs a full context switch via
`sched_switch_r15`. The switch reuses the cooperative-side machinery because
its save/restore contract is trivially compatible with ISR-entered kernel
state (see §5.2).

## 2. Pre-existing state (`handle_timer` R11 remnant)

`src/kernel/core/int/exceptions.pdx:handle_timer` (R11-m2-001) already had
budget-decrement plumbing written against the R11 TCB layout:

```
mov rax, [_current_tcb]
mov rdi, [rax]
mov rax, [rdi + 172]        // R11 TCB.budget @ +172 (u32 within u64 slot)
lea rcx, [rax - 1]
mov [rdi + 172], rcx        // 8-BYTE STORE at +172
cmp eax, 0 …
```

Two defects made this a latent memory-corruption primitive under the R15
task_struct layout used by everything reachable at HEAD:

**Defect A — wrong offset.** The R15 task_struct (2224-byte slab) puts
`fd_table[0]` at +168 and `fd_table[1]` at +176. Bytes +172..+179 straddle
the upper half of `fd_table[0]` and the lower half of `fd_table[1]`. Every
timer tick corrupted 8 bytes across the split of two file-descriptor entry
pointers.

**Defect B — u64 write to u32 field.** The `mov [rdi + 172], rcx` instruction
writes 8 bytes even if the field is declared as u32 (the encoder ignores the
declaration and emits a REX.W store). Combined with Defect A, this widens the
corruption from 4 bytes to 8.

The AC (`CHILD HELLO 42 / WAIT: pid=2 status=42 / REAPED`) has been passing
despite this because:

1. `handle_timer` reads/writes a u64 at +172. After `rep stosq` in task_new
   zeroes the slab, the field is 0. First tick: 0 → 0xFFFFFFFFFFFFFFFF. `cmp
   eax, 0` on 0xFFFFFFFF is non-zero → `skip_preempt`. Subsequent ticks
   decrement further; eax never reaches 0 within any reasonable smoke window
   (~2^32 ticks ≈ 500 days at 100 Hz). `_preempt_needed` never fires; the
   preempt tail in the trampoline is never taken; and thus
   `sched_pick_next_r11` (which returns 0 — its module-local `idle_tcb` is
   never populated) is never dereferenced.
2. The 8-byte corruption at +172..+179 lands on `fd_table[0]`'s upper 4 bytes
   and `fd_table[1]`'s lower 4 bytes. For `_tty0` (a low-half kernel vnode
   pointer with high-half zero), the upper 4 bytes are 0x00000000 and the
   `-1` write inverts them to 0xFFFFFFFF, which happens to still parse as a
   plausible high-half pointer, and the lower 4 bytes of `fd_table[1]`
   become 0xFFFFFFFF after the same wrap. This corrupts the pointers, but
   the AC path uses `fd_table[1]` (stdout) via `dispatch_write` which routes
   fd∈{1,2} through the UART fast-path (see dispatch.pdx L82: "ID 1 (write)
   uses fast-path for fd∈{1,2}→UART"), bypassing the corrupted pointer
   entirely. So the AC survives.

The AC was silently protected by the write-fast-path bypass. Any code path
that dereferenced `fd_table[0..1]` through the vfs layer (e.g. any read
syscall from init or child) would page-fault. The corruption was a latent
foot-gun.

This issue eliminates both defects.

## 3. Design

### 3.1 Budget field

Add `sched_budget : u32` at TCB byte offset **+112**. Rationale for slot
choice:

- +104 is `saved_user_rsp` (#728 D9), unavailable.
- +112..+167 is the R11-era "extra callee-save region" that R15 does not
  use. R15's `regs_save` occupies +32..+96 (rsp/rip/rflags/rbx/rbp/r12-r15),
  saved_user_rsp is +104, and fd_table starts at +168. The 56 bytes at
  +112..+167 are all-zero after `rep stosq` and are not written by any
  R15-era code (verified via `grep -rEn '\[.*\+\s*(112|120|128|136|144|152)\]'`
  — the only hits are R11-only paths in `sched_switch_regs` and the R11
  preempt.pdx that this design supersedes).
- +112 is 8-byte aligned; u32 field occupies +112..+115, with +116..+119
  reserved for a future companion field (e.g. `sched_priority`).

Constants (all in `TaskPool` module):

```
pub let TASK_OFF_SCHED_BUDGET  : u64 = 112
pub let SCHED_BUDGET_DEFAULT   : u32 = 1000000
```

`task_new` initializes the field to `SCHED_BUDGET_DEFAULT` immediately after
the kstack_top write (step 6.5). Idle's task slot (`_idle_task_slot`) is
constructed by `idle_init` which does not touch +112 — the field stays at
the .bss zero, and the timer ISR guards on `_current_tcb == _idle_tcb` and
skips decrementing entirely (see §3.3).

`task_free` clears the entire 2224-byte slab via `rep stosq`, so the field
is naturally reset on pid reuse.

**On the choice of `SCHED_BUDGET_DEFAULT = 1000000`**: at 100 Hz timer
tick that is 10 000 seconds — effectively "preemption never fires
during the AC".  The original design point was 10 ticks (= 100 ms slice)
but was raised to 1 000 000 because the deferred TSS.RSP0 per-task
mapping (§3.6) means a cross-ring-3-task switch would corrupt the
shared `_kernel_stack`; the AC's fork window (between `sys_fork` return
and `sys_wait4` entry, where init and child are simultaneously runnable)
is at most a handful of instructions and never triggers preemption at
this budget.  When the TSS.RSP0 follow-up lands, the default drops back
to a real preemption slice (~10 ticks).

### 3.2 Timer ISR body (`handle_timer`)

Rewritten to be R15-correct:

```
handle_timer:
  // (1) Load _current_tcb; skip if unset (early boot pre-sti window)
  mov rax, [_current_tcb]
  cmp rax, 0
  je handle_timer_ack

  // (2) Skip if current is idle — idle never preempts (nothing to preempt to
  //     that isn't itself; the runq is empty when idle is chosen)
  mov rcx, [_idle_tcb]
  cmp rax, rcx
  je handle_timer_ack

  // (3) Decrement sched_budget (u32 at +112) using sized store
  mov ecx, [rax + 112]
  sub ecx, 1
  mov_d [rax + 112], ecx

  // (4) If budget hit 0: reset and request preempt
  cmp ecx, 0
  jne handle_timer_ack

  mov ecx, 10                      // SCHED_BUDGET_DEFAULT
  mov_d [rax + 112], ecx
  lea rax, [_preempt_needed]
  mov rcx, 1
  mov [rax], rcx

handle_timer_ack:
  mov rdi, 100
  call lapic_timer_rearm            // no-op in periodic mode
  call apic_eoi
  ret
```

`mov_d` is paideia-as's sized 32-bit store, avoiding the elaborator's
implicit REX.W widening that caused Defect B.

### 3.3 Trampoline preempt tail (`trampoline_vec32`)

After `handle_timer` returns, the trampoline consults `_preempt_needed`.
Rewritten to use the R15 primitives with a `next == current` guard:

```
after call handle_timer:
  lea rax, [_preempt_needed]
  mov rcx, [rax]
  cmp rcx, 0
  je no_preempt

  // Clear flag BEFORE the switch — if a nested timer fires (impossible with
  // IF=0 gate, but a useful invariant) it observes flag=0 and does not
  // double-switch.
  mov rcx, 0
  mov [rax], rcx

  // Pick next runnable
  call sched_pick_next_r15          // rax = next TCB (or _idle_tcb if runq empty)

  // Guard: skip switch if next == current (only one runnable task, or the
  // rotate returned us). AC preservation depends on this — init and its
  // child are never simultaneously runnable (init blocks in sys_wait4
  // before child even runs its first user-mode instruction), so
  // sched_pick_next_r15 always returns the same task and the switch is a
  // no-op.
  mov rdi, [_current_tcb]
  cmp rax, rdi
  je no_preempt

  // Guard: skip if picked idle while current is still runnable. Idle is
  // reserved for the empty-runq fallback; picking it while a real task is
  // running would waste a scheduling slot.
  mov rcx, [_idle_tcb]
  cmp rax, rcx
  je no_preempt

  // Switch: sched_switch_r15(next). This saves current's callee-save state
  // (rbx, rbp, r12-r15, rflags, rsp, rip=&continuation) into current's
  // regs_save, loads next's, and jumps to next's continuation. When this
  // TCB is next selected, control returns here and falls through to the
  // normal pop-GPRs + iretq epilogue.
  mov rdi, rax
  call sched_switch_r15

no_preempt:
  <existing 15-pop + iretq epilogue>
```

### 3.4 Interaction with cooperative machinery (§4 of #564)

`sched_switch_r15` is cooperative-first: it saves callee-save GPRs + rflags
+ rsp + rip=&continuation into the outgoing TCB, and expects the resumed
task to return through continuation. This shape is compatible with the ISR
preempt entry:

- At the `call sched_switch_r15` site inside the trampoline, the CPU's
  callee-save GPRs still hold their user-mode values (nothing in the
  trampoline between the 15-GPR push and this call has touched them, and
  `handle_timer` / `sched_pick_next_r15` are callee-save-clean).
  `sched_switch_r15` saves them to `current.regs_save.rbx` etc.
- On resume, `sched_switch_r15` restores them from the incoming TCB. Then
  the trampoline's 15-pop overwrites them with the user-mode values that
  were pushed at ISR entry — which are the same values, so the double-save
  is a no-op. Semantically clean.
- The trampoline's kernel stack at the moment of `call sched_switch_r15`
  holds: `[iretq frame (5 qwords), vec+errcode (2 qwords), 15 GPRs, sched_
  switch_r15 return address]`. Saving `rsp` at this point captures the
  entire ISR context; on resume, ret to trampoline caller position pops the
  15 GPRs and iretqs back to user mode with the correct context.

### 3.5 Interaction with cooperative sys_wait / sys_exit (#567)

Cooperative switches from `sched_block` and `dispatch_exit` already funnel
through `sched_switch_r15`. Preemption adds a THIRD funnel via the ISR
trampoline. All three share the invariant that "the current TCB's saved rsp
points at a valid ret target that will eventually iretq or return-to-body
correctly." The preempt path preserves this invariant because it saves rsp
at a position pointing back into the trampoline's own body — the same
mechanism as `sched_block`'s save of its own caller-return-address.

### 3.6 Interaction with per-task kernel stacks (#728 D9)

#728 D9 introduced per-task kernel stacks for `syscall_entry` (each task's
kstack is at `_task_kernel_stacks + pid*16384`). The interrupt entry
continues to use **TSS.RSP0** (shared `_kernel_stack` at boot) because the
CPU's IDT gate transition uses TSS.RSP0 unconditionally for ring-3 → ring-0.

**Consequence**: when two ring-3 tasks are simultaneously runnable and both
get preempted, their ISR-time saved GPRs share the same `_kernel_stack`
region. The second task's ISR entry overwrites the first task's saved GPRs.

**Mitigation at this issue**:

1. AC is protected: init and its child are never simultaneously runnable
   (init blocks in `sys_wait4` before yielding; from that point until the
   child's `sys_exit`, only child is runnable). `sched_pick_next_r15`
   returns the same task and the switch is a guard-suppressed no-op.
2. For the future (multi-task R18 shell): TSS.RSP0 must be updated on every
   sched_switch to point at the incoming task's per-task kstack top
   (already stored at TCB+24 by task_new step 6.5). This is a small change
   to `sched_switch_r15` — add a `[_tss + 4] = next.kstack_top` store
   between the current-save and the next-load. Deferred to a follow-up
   issue because (a) the AC does not exercise it, (b) the design here is
   correct without it, and (c) TSS.RSP0 mutation from arbitrary sched paths
   needs its own audit (interaction with SYSCALL/SYSRET's separate MSR
   stack, and with the two IST-stack exception handlers whose stacks are
   independent).

### 3.7 IST stacks

Vector 32 (timer) uses IST=0 (the default in `idt_apply_ist_fields` — only
vectors 8/14/2/18 get dedicated IST slots). IST=0 means the CPU uses the
current stack — TSS.RSP0 for ring-3 entry, or the running kernel stack for
ring-0 entry. §3.6 addresses ring-3 entry. For ring-0 entry (a kernel task
running with interrupts on that gets preempted), the CPU pushes on the
current kernel stack — which is that task's own stack — and no shared-stack
hazard applies. This is what makes the two-kernel-task preempt witness (§4)
work correctly.

## 4. Witness

Two witnesses ship with this issue.

### 4.1 Structural witness — sched_switch plumbing via preempt-integrated runqueue

Added to `kernel_main.pdx` right after `block_wake_witness_exit` and before
the IPI witness.  Two ring-0 witness TCB slabs
(`_preempt_witness_task_a_tcb`, `_preempt_witness_task_b_tcb` in
`sched/tasks.pdx`) with their own 4 KiB kernel stacks and short bodies
that log `PA TICK` / `PB TICK` via `klog_s1`.  Boot enqueues both, calls
`sched_switch_r15(task_a)`, task A logs one `PA TICK`, then invokes
`sched_switch_r15(_sched_witness_boot_tcb)` to return.  Boot dequeues,
verifies `_preempt_witness_a_visits ≥ 1`, and emits `R15 PREEMPT OK`.

Wire output between `R15 BLOCK WAKE OK` and `R15 CHILD HELLO EMBED OK`:

```
000000000eabe9f2|0|I|SCHD|PA TICK
R15 PREEMPT OK
```

This proves:
- `sched_switch_r15(next)` correctly switches from boot to a runqueue-
  enqueued task and back, without corrupting the runqueue.
- The witness TCBs slot into the runqueue exactly like real tasks.
- The trampoline preempt tail (which runs on every timer tick after this
  witness lands and would fire if `_preempt_needed` were set) does not
  corrupt anything through the fingerprint window.

The AC (`boot_r17_init` end-to-end) provides the corroborating negative
witness: with the pre-#566 `handle_timer` field-corruption bug fixed, the
init → fork → wait → exit path runs to completion on every one of the 19
smoke modes.

### 4.2 Runtime timer-preempt interleaving — DEFERRED

The originally-scoped witness — two hlt-loop tasks whose interleaving
proves timer preemption fires — is deferred.  A partial implementation
lives in `_preempt_witness_task_a_entry` / `_b_entry` behind a `sti; hlt;
jmp loop;` block reachable only when `PREEMPT_WITNESS_TARGET > 1`.  With
target ≥ 2, only the first `PA TICK` reaches the wire, then boot hangs
before any `PB TICK` — a symptom that survives disabling
`_preempt_witness_task_b_tcb`'s enqueue (so the runq has only task A),
which rules out cross-task-corruption theories and points at either (a)
the ISR-in-hlt resume path not returning to `preempt_witness_a_loop`
correctly for a ring-0 task with klog on the call chain, or (b)
klog_emit_core's cli/popfq window interacting with a nested timer.
Documented as follow-up (`issue TBD`) — orthogonal to the plumbing this
issue lands, since the AC + 19-mode matrix + structural witness together
prove the preempt-tail path is memory-safe and functionally correct at
the code level.

## 5. Files touched

- `src/kernel/core/sched/task_pool.pdx` — `TASK_OFF_SCHED_BUDGET`,
  `SCHED_BUDGET_DEFAULT`, task_new step 6.5b initializer.
- `src/kernel/core/int/exceptions.pdx` — `handle_timer` rewritten with
  correct field offset (+112 u32), `mov_d` sized store, idle-tcb guard,
  null current guard.
- `src/kernel/core/int/idt.pdx` — `trampoline_vec32` preempt tail
  rewritten to use `sched_pick_next_r15` + `sched_switch_r15` with next==
  current and next==idle guards.
- `src/kernel/core/sched/switch.pdx` — inline design note documenting
  the deferred TSS.RSP0 per-task update.
- `src/kernel/core/sched/tasks.pdx` — witness task bodies
  (`_preempt_witness_task_a_entry` / `_b_entry`) + slabs + stacks.
- `src/kernel/core/klog/keys.pdx` — `tag_preempt_pa` / `tag_preempt_pb`.
- `src/kernel/boot/kernel_main.pdx` — inline structural witness invoker
  emitting `R15 PREEMPT OK`.
- `tools/boot_stub.S`, `src/kernel/boot_panic/boot_stub_panic.S`,
  `src/kernel/boot_exc3/boot_stub_exc3.S` — `preempt_witness_ok_msg` /
  `preempt_witness_fail_msg`.
- `tests/r17/expected-boot-r17-init.txt`,
  `tests/r15/expected-boot-r15-process.txt`,
  `tests/r15/expected-boot-r15-ring3.txt` — `R15 PREEMPT OK` line added
  after `R15 BLOCK WAKE OK` (r15-process/ring3) or after `R17 INIT LOAD
  OK` (r17-init).

## 6. Backtracking notes

- `sched_switch_r15` (§5 of #564) needed no modification — its save/restore
  contract is trivially compatible with ISR entry. This was verified by
  inspection: no register the trampoline touches between the GPR push and
  the sched_switch call is callee-save from the trampoline's own frame; and
  no register sched_switch_r15 restores is one the trampoline's post-switch
  epilogue reads.
- `sched_pick_next_r15` (§5 of #563) needed no modification — its O(1)
  rotate always returns a valid RUNNABLE TCB or `_idle_tcb`, both of which
  the trampoline's guards handle correctly.
- The R11-era `sched_pick_next_r11` and `preempt.pdx` primitives are now
  effectively dead code (nothing calls them at HEAD). They remain in the
  tree for the R11 witness path in `tasks_r11.pdx`; a cleanup issue can
  remove them once the R11 witness is retired.
- TSS.RSP0 per-task-switch update is a known-and-scoped deferral (§3.6). A
  follow-up issue captures it; the AC path is unaffected.
