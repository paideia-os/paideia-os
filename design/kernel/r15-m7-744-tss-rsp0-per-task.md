# r15-m7-744 — Per-Task TSS.RSP0 Update in sched_switch_r15

Status: LANDED
Issue: paideia-os#744 (follow-up to #566)
Predecessors: #566 (timer preempt plumbing, b47c166), #728 D9 (per-task
kernel stacks, 795e2fc), #656/#718/#719/#720 (KPTI stack + descriptor
mappings), #564 (sched_switch_r15), #563 (sched_pick_next_r15)
Also closes: nothing new (see §7 on #745 status)

## 1. Motivation

At b47c166 (#566) the timer-preempt plumbing landed with an explicit hedge:
`SCHED_BUDGET_DEFAULT = 1_000_000` ticks at 100 Hz — ten-thousand seconds,
effectively "preemption never fires during any smoke". The hedge was needed
because `sched_switch_r15` did not update `TSS.RSP0`, and per-task kernel
stacks (#728 D9) had introduced a per-task `kstack_top` at TCB+24 that the
switch code did not consume. As a result, if a timer preempted task A while
it was ring-3 and the trampoline invoked `sched_switch_r15(task_b)`, the CPU
would then be running task B in ring-3 with `TSS.RSP0` still pointing at
task A's kernel stack (or the shared boot `_kernel_stack`). Any subsequent
ring-3 → ring-0 hardware transition from task B (interrupt or exception on
an IST=0 vector — most notably the periodic timer at vec 32) would push the
`iretq` frame onto whichever stack `TSS.RSP0` still held, corrupting either
task A's saved ISR state (silently trashing its resume path) or the shared
`_kernel_stack` (silently trashing whatever the previous ring-0 caller
stored there).

This issue lands the natural fix: `sched_switch_r15` now updates `TSS.RSP0`
to the incoming task's `kstack_top` on every switch (guarded on
`kstack_top != 0` to protect ring-0-only synthetic TCBs — see §3.2), and
`kpti_build_user_pml4` maps `_task_kernel_stacks` into every user PML4 so
the CPU's push at `TSS.RSP0` succeeds without a `#PF` under user CR3.

## 2. Wire evidence of the pre-fix problem

Two independent pieces confirm the problem was real, not theoretical.

**a) `_sched_witness_task_a/b_tcb` and `_preempt_witness_task_a/b_tcb`
comments (sched/tasks.pdx L196-198)**:

> NEW: _preempt_witness_task_a_tcb, _preempt_witness_task_b_tcb (2224-
> byte slabs, .bss zero-init; kstack_top left 0 so sched_switch_r15's
> TSS.RSP0 guard skips — irrelevant here anyway since these tasks are
> ring-0-only).

The tree already anticipated the guard this issue introduces. The comment
was aspirational at #566 landing time (the guard did not exist yet); this
issue closes the loop.

**b) The `SCHED_BUDGET_DEFAULT = 1_000_000` hedge itself** (r15-m7-566-
timer-preempt.md §3.1):

> Default = 10 ticks × 10 ms/tick = 100 ms slice. Chosen to comfortably
> exceed the AC completion window (fork→exec→wait→exit finishes in tens
> of milliseconds), so preemption never fires during the AC and the guard
> "next == current, skip switch" in trampoline_vec32 keeps AC single-task
> semantics intact.

The design point was 10 ticks but was raised to 1M "because the deferred
TSS.RSP0 per-task mapping (§3.6) means a cross-ring-3-task switch would
corrupt the shared `_kernel_stack`". This landing removes the "would
corrupt" premise; §5 discusses what to do with the hedge next.

## 3. Design

### 3.1 The write

Between the current-save phase (steps 1-2 of `sched_switch_r15`) and the
next-load phase (step 3), insert an unconditional load of
`[next_tcb + 24]` (per `TaskPool.TASK_OFF_KSTACK_TOP = 24`) followed by a
conditional store to `[_tss + 4]` (per Intel SDM Vol 3A §6.14.5 — 64-bit
TSS layout: byte offset +4 is the eight-byte `RSP0` field, following the
four-byte reserved-0 prefix).

```asm
mov rax, [rdi + 24]                   ; rax = next.kstack_top
cmp rax, 0
je skip_tss_rsp0_update
lea rcx, [rip + _tss]
mov [rcx + 4], rax                    ; TSS.RSP0 @ +4
skip_tss_rsp0_update:
```

Register choice: rax and rcx are both caller-save and both scratch at this
program point (rax last held `_current_tcb` for the current-save block; rcx
last held `_current_tcb`'s address for the pointer write). rdi (`next_tcb`)
must be preserved for step 3's `mov rsp, [rdi + 32]` and the subsequent
callee-save loads at `[rdi + 56..96]`.

### 3.2 The guard

`kstack_top == 0` identifies **synthetic ring-0-only TCBs** whose
`kstack_top` slot was never initialized by `task_new`:

- `Idle._idle_task_slot` — idle runs a 3-byte hlt/jmp loop in ring 0
  under whatever CR3 was loaded when scheduled; it never appears as the
  target of a ring-3 → ring-0 hardware transition. `idle_init` writes
  `regs_save.rsp` (its own dedicated 4 KiB kstack) and `regs_save.rip`
  (`&idle_code`) but leaves TCB+24 at `.bss` zero.
- `Tasks._sched_witness_boot_tcb` — the fake TCB representing
  "kernel_main / boot context" used by the #564 sched-switch witness.
  Written directly by kernel_main's witness prep; kstack_top is left at
  zero.
- `Tasks._preempt_witness_task_a_tcb`, `_preempt_witness_task_b_tcb` — the
  #566 witness tasks; ring-0 hlt-loop bodies whose kstacks are the
  dedicated `_preempt_witness_task_*_stack` regions, not the pool.
  Written directly by kernel_main's witness prep; kstack_top is left at
  zero.

Skipping the write in these cases preserves `TSS.RSP0`'s last valid value
from the previous real ring-3 task's switch-in (or `tss_install`'s boot
default `&_kernel_stack + 16384`). This is correct because none of these
TCBs are ever the target of a ring-3 → ring-0 hardware transition — the
CPU only consults `TSS.RSP0` on privilege escalation, and these TCBs
never appear as the ring-3 side of that transition.

### 3.3 The location in the switch flow

The write sits at step 2.5, between (2) `_current_tcb ← next_tcb` and (3)
`mov rsp, [rdi + 32]` (switch to next's stack). Placing it there means:

- `_current_tcb` and `TSS.RSP0` are updated in a single `cli`-protected
  window. IF is still 0 (the switch's `cli` at step 1 has not been
  undone), so no interrupt can observe the transient state where
  `_current_tcb` points at `next` but `TSS.RSP0` still holds `current`'s
  value.
- The write happens BEFORE the stack switch, so a hypothetical fault on
  the `mov [_tss+4], rax` (there is none — `_tss` is always mapped,
  writable, and cache-line aligned) would fault onto the still-current
  kernel stack, keeping the fault path debuggable. In practice there is
  no fault window here.

### 3.4 The counterpart: `_kernel_pml4_pa` (already handled)

The mirror concern to `TSS.RSP0` under KPTI is: when the CPU pushes the
iretq frame at `TSS.RSP0`, it does so under the CURRENT CR3 — for a ring-3
task, that is the task's user PML4. If the user PML4 does not map the
kstack VA, the push faults, cascades to `#DF`, cascades to triple-fault.

`_kernel_pml4_pa` is separately handled by the ISR trampoline (which flips
CR3 to kernel after the iretq frame is already on the kstack via
TSS.RSP0). This issue's Part B ensures the "before the CR3 flip" push
succeeds under user CR3.

## 4. kpti_build_user_pml4 extension

### 4.1 Region and math

`_task_kernel_stacks` (task_pool.pdx L57): `[u64; 133120] @align(16)`.

- Total size: 133 120 × 8 B = **1 064 960 B = 260 pages exactly** at 4 KiB.
- Base alignment: 16 B (only). The array's start may be at any byte offset
  within a page.
- Worst-case straddle: if base is at page-offset > 0, the region spans
  `ceil((offset + 1064960) / 4096) = 261` pages.

The kpti loop maps **261 pages conservatively** — the extra page is either
the leading straddle (aligned base: harmlessly maps the padding
immediately preceding `_task_kernel_stacks` in `.bss`) or the trailing
straddle (non-aligned base: covers the region's last bytes). Both are
`.bss` .data of the same character, kept RW=1/U=0/XD=1.

### 4.2 Cost analysis

**Per user_pml4 setup**:
- 261 `aspace_map` calls.
- 261 pages span ≤ 2 PTs (each PT covers 2 MiB; 260 pages = 1 040 KiB
  < 2 MiB, so unless the region crosses a 2-MiB boundary — rare given
  the linker's tendency to pack `.bss` — a single PT suffices).
- `aspace_map` allocates the shared PT lazily on the first miss and
  reuses it for adjacent pages, so this loop costs **~1-2 `phys_alloc`
  calls** for the PT(s) plus 261 PTE writes.
- 261 PTE writes = 261 × 8 B = 2 088 B of PT storage per user_pml4.

**Per AC run** (init + one fork + one execve): ~2 user_pml4
constructions, so ~522 `aspace_map` calls and ~2-4 PT-page allocations.
Empirically the smoke matrix still boots within its timeouts (§6).

### 4.3 Huge-page trade-off (rejected)

A 2 MiB PDE would cover 128 tasks' worth of kstacks in one PTE — dropping
the mapping cost from ~261 PTE writes to 1 PDE write, and dropping the
PT allocation entirely. But `aspace_map_2m.pdx` is a stub (no encoder path
for the 2 MiB PS bit in `aspace_map`'s walker), so this optimization
requires a full 2 MiB-page path to land first. Deferred as a natural
follow-up; the 4 KiB loop is functionally correct and its cost is bounded.

### 4.4 Register discipline

The extension follows the same pattern as the earlier `_kernel_stack` and
IST-stack mappings in `kpti_build_user_pml4`:

- r12: `user_pml4_pa` (loaded at function entry, preserved across all
  `aspace_map` calls per SysV callee-save).
- r14: page-aligned base of `_task_kernel_stacks` (loaded once, preserved
  across the loop).
- r15: iteration counter (0..261).
- rdi/rsi/rdx/rcx: per-call scratch for `aspace_map`'s four arguments.
- rax: `aspace_map`'s return (0 on success, non-zero → OOM branch to
  `kpti_build_oom`).

r14 and r15 are both SysV callee-save AND explicitly preserved by
`aspace_map`'s contract (verified in `aspace_map.pdx`'s prologue).

## 5. SCHED_BUDGET_DEFAULT decision

**Kept at 1 000 000** in both `task_pool.pdx:SCHED_BUDGET_DEFAULT` and
`exceptions.pdx:handle_timer`'s reset value.

### Rationale

Lowering to a smaller value (e.g. 10 for a 100 ms slice) would make real
timer preemption fire during the AC's `init → child_hello → wait → exit`
window. With Parts A and B in place, the switches themselves would be
correct (TSS.RSP0 follows, kstacks are mapped) — but two second-order
concerns argue for keeping the hedge:

1. **AC preservation is non-negotiable.** Lowering the default exercises
   code paths (the trampoline's cross-ring-3-task switch, the KPTI-user
   push under TSS.RSP0 = per-task kstack) that Parts A/B are the FIRST
   real coverage for. If a latent bug remains — an off-by-one in the
   guard, a missed PT entry, an unhandled kstack-top corner case — the
   fingerprint-driven smoke would surface it as an AC break, not as a
   clearly-isolated preempt-witness failure. Keeping the hedge lets the
   next commit (a proper preempt witness with per-task budget reset) be
   the one that pays the AC-breakage price if anything is still wrong,
   with a single-witness diagnostic instead of a cross-cutting AC
   regression.

2. **The AC's `sched_pick_next_r15` guard is a no-op at 1M.** Even at
   default 1M, when preemption never fires, the guard's structural
   correctness is exercised zero times per AC. Dropping to 10 exercises
   the guard hundreds of times per AC without changing the number of
   actual switches (init and its child are never simultaneously runnable
   in the wire-observable window — init blocks in `sys_wait4` before
   child runs its first user instruction, so `sched_pick_next_r15` always
   returns the same task and the guard suppresses the switch). This is
   pure latency overhead for no coverage gain.

The follow-up that drops SCHED_BUDGET_DEFAULT lower ships together with:
- A per-task-budget-reset in `handle_timer` (so the reset value doesn't
  swamp subsequent slice tests — see §6.3).
- A runtime preempt witness that actually exercises cross-task switches
  (see #745 follow-up in §7).

## 6. Files touched

- `src/kernel/core/sched/switch.pdx` — insert step 2.5 (TSS.RSP0 update)
  between `_current_tcb ← next` and `mov rsp, [rdi + 32]`. Extend the
  justification string to cover #744. Replace the pre-existing "scoped-
  out" comment block with the new implementation and rationale.
- `src/kernel/core/mm/kpti.pdx` — add a 261-page loop mapping
  `_task_kernel_stacks` with RW=1/U=0/XD=1 flags, following the same
  pattern as the earlier `_kernel_stack` and IST-stack loops. Replace
  the pre-existing "deferred" comment block with the implementation and
  a pointer to this design doc.

Both edits are self-contained. No changes to:
- `task_pool.pdx` (SCHED_BUDGET_DEFAULT stays at 1M; TASK_OFF_KSTACK_TOP
  stays at 24; task_new stays unchanged — it already sets kstack_top).
- `exceptions.pdx:handle_timer` (reset value stays at 1M for
  self-consistency with SCHED_BUDGET_DEFAULT).
- `idt.pdx:trampoline_vec32` (preempt tail already correctly guards
  next==current and next==idle).
- `tasks.pdx:_preempt_witness_task_*_entry` (target=1 cooperative witness
  stays; #745 follow-up will extend it).
- `kernel_main.pdx` preempt witness prep (stays as-is).
- Test fingerprints (no observable wire change — see §6.2).

## 6.1 Interaction with the #566 witness

The #566 preempt witness (kernel_main.pdx L6987+) runs both witness TCBs
as ring-0 tasks. Per §3.2 they have `kstack_top == 0`; the new guard in
`sched_switch_r15` skips the TSS.RSP0 update on switches involving them.
The witness's wire output is byte-identical (`PA TICK` then
`R15 PREEMPT OK`).

## 6.2 Interaction with the AC path

Init and child_hello both go through `task_new` (via `sys_fork` and
`sys_execve`), so both have `kstack_top` set correctly. The AC's switch
sequence is:

1. Boot → init (via `enter_userland_initial`, not `sched_switch_r15`) —
   TSS.RSP0 initialized by `tss_install` to `&_kernel_stack + 16384`, not
   yet a per-task stack. Init's first timer tick pushes iretq on
   `_kernel_stack`; harmless because init is the only runnable task.

2. Init → child (via `sched_block` inside `sys_wait4` → `sched_switch_r15
   (pick_next=child)`). **Now Part A fires**: TSS.RSP0 ← child's
   kstack_top. Any subsequent timer tick during child's ring-3 execution
   pushes iretq on child's own kstack — mapped by Part B.

3. Child → init (via `dispatch_exit`'s `sched_wake(init)` + explicit
   `sched_switch_r15(init)`). **Part A fires again**: TSS.RSP0 ← init's
   kstack_top. Init resumes, wakes, reaps, prints REAPED.

Fingerprints unchanged. Empirically the full 20-mode matrix boots green
(see §6.4).

## 6.3 Interaction with SCHED_BUDGET_DEFAULT

At 1M ticks the preempt tail never fires during any current smoke.
Therefore steps 2-3 above never happen via preemption — they happen via
cooperative `sched_switch_r15` calls from inside `sys_wait4` and
`dispatch_exit`. Part A applies uniformly to both cooperative and
preemptive switches; the fix is oblivious to the trigger source.

The follow-up that lowers SCHED_BUDGET_DEFAULT will need to:

1. Change the reset value in `handle_timer` (which currently mirrors
   SCHED_BUDGET_DEFAULT); otherwise, after the first preempt of any task,
   its budget resets to the (now-lowered) default and the preempt
   frequency stays useful.

2. Verify the AC still passes: init's syscall-heavy path (fork, wait4,
   exit) must reach completion within its (now-lowered) slice, or must
   correctly park in `sched_block` and yield the CPU to child without
   racing.

Both are simple mechanical changes but they exercise the
now-timer-preemption-live path for the first time on wire, so they belong
in their own commit.

## 6.4 Verification

Full 20-mode smoke matrix green post-fix:

```
boot_min: passed (all 1 lines found in order)
boot_banner: passed (all 4 lines found in order)
boot_tick: passed (all 6 lines found in order)
boot_r8_only: passed (all 4 lines found in order)
boot_r10: passed (all 11 lines found in order)
boot_r11: passed (all 10 lines found in order)
boot_r12: passed (all 15 lines found in order)
boot_r12_denial: passed (all 4 lines found in order)
boot_r14b_hivma: passed (all 3 lines found in order)
boot_r14b_kpti: passed (all 9 lines found in order)
boot_r14b_ipi: passed (all 5 lines found in order)
boot_r14b_loader: passed (all 84 lines found in order)
boot_r14b_ud: passed (all 13 lines found in order)
boot_r15_ring3: passed (all 75 lines found in order)
boot_r15_process: passed (all 76 lines found in order)
boot_r16_uart_rx: passed (all 33 lines found in order)
boot_r17_init: passed (all 31 lines found in order)
boot_panic: passed (all 5 lines found in order)
boot_panic_halt: passed (all 3 lines found in order)
boot_exc3: passed (all 4 lines found in order)
```

AC preserved end-to-end (r17_init tail):

```
R17 INIT LOAD OK
R15 IDLE TASK OK
R15 RUNQUEUE OK
R15 SCHED SWITCH OK
R15 BLOCK WAKE OK
... PA TICK ...
R15 PREEMPT OK
IPI OK
SELF IPI OK
LOADER OK
ELF LOAD OK
R15 CHILD HELLO EMBED OK
R17 BIN CHILD HELLO SEED OK
INIT BOOT OK
INIT ENTERED RING3
INIT OK
CHILD HELLO 42
WAIT: pid=2 status=42
REAPED
```

## 7. #745 status (target ≥ 2 witness hang)

#745 reports the preempt witness hangs at the second PA TICK when
`PREEMPT_WITNESS_TARGET ≥ 2`. Debugger's analysis (#745 body) noted the
witness code has `cmp rcx, 1` hardcoded rather than loading
PREEMPT_WITNESS_TARGET, so target=1 exits after the first iteration
without ever executing `sti; hlt` — the second-tick path is genuinely
unreachable in the shipped witness.

**Analysis with #744 in hand**: Parts A and B do **not** fix #745, for
two independent reasons:

1. The witness tasks are **ring-0**. Ring-0 preemption pushes the iretq
   frame on the CURRENT kernel stack (whatever RSP holds at the moment
   of the interrupt), not on TSS.RSP0. So the TSS.RSP0 update in Part A
   is a no-op for these tasks (the guard skips it — kstack_top=0), and
   the kpti mapping in Part B is irrelevant (no user CR3 in play).

2. The likely root cause is the **budget-reset-to-SCHED_BUDGET_DEFAULT**
   behavior in `handle_timer`. Each witness task starts with budget=3
   (set in kernel_main's witness prep) so the first preempt fires within
   3 timer ticks (~30 QEMU ms). But `handle_timer` resets the budget to
   `SCHED_BUDGET_DEFAULT = 1_000_000` on hitting 0 — so the task's SECOND
   slice is 10 000 seconds long. The witness would eventually complete
   its interleaving but far past the 8-second smoke timeout, presenting
   as a hang.

**Recommendation**: #745 stays open and is addressed by the same
follow-up that lowers SCHED_BUDGET_DEFAULT (§6.3). That follow-up:
- Lowers SCHED_BUDGET_DEFAULT (and the mirror in handle_timer's reset)
  to a testable value (e.g. 3-10 ticks).
- Fixes the `cmp rcx, 1` hardcode in `_preempt_witness_task_a/b_entry` to
  load PREEMPT_WITNESS_TARGET.
- Verifies wire output shows `PA/PB/PA/PB/...` interleaving.
- Preserves the AC (init's fork→wait→exit window must survive the
  now-active preempt).

## 8. Backtracking notes

- The natural place for the TSS.RSP0 write is `sched_switch_r15` itself,
  NOT `task_new` — task_new only sets the field once at task creation,
  and TSS.RSP0 must track the CURRENT running task, which changes on
  every switch. Placing the write in `sched_switch_r15` guarantees the
  invariant regardless of which caller triggered the switch (cooperative
  from sched_block/dispatch_exit, or preemptive from
  trampoline_vec32).
- The guard on `kstack_top == 0` is essential. Without it, a switch to
  idle would write 0 into TSS.RSP0; the NEXT ring-3 → ring-0 transition
  would push iretq at linear address 0 (which is unmapped in every user
  PML4) → #PF → #DF → triple-fault. Idle → real-task switches would then
  never observe a valid TSS.RSP0.
- The alternative "always write, but use `_kernel_stack + 16384` as
  fallback when `kstack_top == 0`" was considered and rejected: it
  reintroduces the pre-#728 shared-stack corruption for any ring-3 task
  that gets preempted while idle is TSS.RSP0-installed. Preserving the
  previous real task's kstack_top (the natural consequence of skipping
  the write) is strictly better — no shared stack, no corruption
  primitive.
- Adding the mapping to `kpti_build_user_pml4` (per-user_pml4) rather
  than to some CPU-init path is deliberate: each user_pml4 is a distinct
  page table tree, and the kpti mappings must live in each one
  independently. The existing `_kernel_stack` + IST + descriptor
  mappings follow the same pattern; this landing extends that pattern
  uniformly.
- 2 MiB huge-page support would be a cleaner solution (§4.3) but blocked
  on `aspace_map_2m.pdx` growing a real body. Filed as a natural
  follow-up: "kpti_build_user_pml4: 2 MiB huge-page path for
  _task_kernel_stacks".
