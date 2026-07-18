---
issue: 562
milestone: R15.M7 (Scheduler: cooperative → timer-preemptive)
subsystem: 10 — Scheduler
prereq:
  - "#543 (task-struct layout freeze — pins the field offsets this doc reuses)"
  - "#544 (`_task_pool[64]` slab in .bss @align(4096) — LANDED)"
  - "#548 (`task_new` real body — LANDED; pins compact pid↔slab mapping)"
  - "#549 (`fd_table` embed @+168 — LANDED; pins upper byte range this doc must avoid)"
blocks:
  - "#563 (r15-m7-002 runqueue-real — the linked-list replacement of the O(64) pick_next stub landed here)"
  - "#564 (r15-m7-003 sched-switch-real — first real save→restore into `regs_save`; this doc freezes RIP/RSP offsets)"
  - "#565 (r15-m7-004 lapic-timer 100Hz — first timer-driven pick_next call)"
touching:
  - src/kernel/core/sched/idle.pdx              (idle_code + `_idle_task_slot` + `_idle_kernel_stack` + `_idle_tcb` + init)
  - src/kernel/core/sched/pick_next.pdx         (new `sched_pick_next_r15` — O(64) pid_table scan; returns _idle_tcb on empty)
  - src/kernel/boot/kernel_main.pdx             (idle_init call + witness block, ~40 LOC)
  - tests/r15/expected-boot-r15-process.txt     (marker line, contains-in-order)
  - tests/r15/expected-boot-r15-ring3.txt       (marker line, contains-in-order)
  - design/kernel/task-struct-layout.md         (regs_save.rip / regs_save.rsp offset freeze — cross-linked)
related:
  - design/milestones/r14b-tactical-plan.md §Subsystem 10 (issue 1, line 1129)
  - design/kernel/r15-m5-006-task-new-real.md   (§3.5 slab-layout freeze this doc extends)
  - design/kernel/scheduler.md                  (long-term architecture)
---

# R15-M7-001 — idle task boot init: `_idle_task_slot`, `_idle_tcb`, `sched_pick_next_r15` (#562)

## 1. Scope

Give the kernel a **single, always-runnable, never-blocking** task
whose body is `1: hlt; jmp 1b`, so that:

1. `sched_pick_next()` has a **well-defined answer when the runqueue is
   empty** — it returns the idle task, not `NULL` and not a garbage
   pointer. This closes the last open case in the scheduler's
   partial function, making it total.
2. The CPU has somewhere to go when every real task blocks. `hlt`
   parks the core until the next interrupt (LAPIC-timer or IPI),
   which then re-enters the scheduler with the same pick_next answer
   until a real task wakes.

Everything else in R15.M7 (runqueue linked list #563, real
`sched_switch` #564, preemptive timer #565) is built on top of this
baseline. Without idle, `sched_pick_next` would need a
"return-caller-uninterrupted-if-empty" special case, which conflates
"pick a task to run" with "there is no task to run"; idle collapses
those two into one uniform pick.

Explicitly out of scope (deferred):

- **Actually context-switching to idle.** This issue only makes idle
  *pickable* and installs its bootstrapped state. The first real
  save→restore path is `sched_switch` (#564). The AC "idle task
  consumes CPU when no other tasks" is satisfied at the smoke level by
  witnessing idle's `regs_save.rip == &idle_code` and
  `state == STATE_RUNNABLE` — full runtime consumption is proven when
  #564 lands.
- **Multi-CPU idle.** SMP will need one idle task per CPU, keyed on
  `cpu_local`. R15.M7 is single-CPU; a single `_idle_tcb` global
  suffices. #566 (r15-m7-008-scheduler-smp-ready-hooks) documents the
  symbol-swap to per-CPU when APs come online.
- **Idle power management (`monitor`/`mwait`, C-states).** `hlt`
  alone is the R15.M7 discipline; C-state depth and MWAIT hints
  land at R17+ with power-management design.
- **Real runqueue enqueue/dequeue of idle.** Idle is **not** on the
  runqueue — it's the fallback picked only when the runqueue is
  empty. This keeps the runqueue's invariant simple ("every entry is
  a real user/kernel task"), and lets pick_next distinguish "picked
  something to run" from "fell back to idle" for future statistics.

## 2. Slot placement decision

**Recommended: dedicated `_idle_task_slot` in `.bss`, NOT
`_task_pool[0]`, published via a dedicated `_idle_tcb` global.**

### 2.1 Options considered

| Option | Slot | pid | Publish | Verdict |
|---|---|---|---|---|
| A | `_task_pool[0]` | 0 (sentinel) | `_pid_table[0]` | rejected — collides with #548 compact mapping |
| B | `_task_pool[0]` | 1 (repurpose) | `_pid_table[1]` | rejected — loses pid 1 for init |
| C | new `_idle_task_slot` in .bss | 0 (dedicated) | dedicated `_idle_tcb` global | **chosen** |
| D | new `_idle_task_slot` in .bss | 0 | `_pid_table[0]` | plausible; adds no value over C |

### 2.2 Why Option C

**#548's compact mapping is load-bearing.** The invariant
`_pid_table[pid] == &_task_pool[pid - 1]` for every allocated task
underlies `task_new`, `task_free`, `sys_fork`, `sys_wait`, and the
existing #551 3-task pool witness. Slot `_task_pool[0]` in that
mapping hosts pid 1's slab (the init process's slab), and `pid_alloc`
scans `_pid_table[1..64]` — index 0 in the pid table is a sentinel
"never allocated". Putting idle in `_task_pool[0]` breaks the
`pid → slab` computation for pid 1 (which becomes ambiguous: it
either lives in slot 0 as before, or lives in slot 1 with a hole).
Both breakages cascade through five callers.

**Idle isn't a task, it's a scheduler primitive.** A real task has
a user address space, a PID visible to `sys_wait`, a parent, a fork
history, an fd_table with tty attached. Idle has none of these:
- `user_pml4_pa = 0` — no aspace (idle runs in the kernel higher half
  using whatever PML4 is loaded when it's picked)
- `parent_pid = 0` — no parent (it predates init)
- `fd_table[0..32] = 0` — no file descriptors
- `exit_status = 0` — it can never exit
Treating it as `task_pool[0]` would lie about all of these; treating
it as a dedicated slot with `state = STATE_RUNNABLE` and a
bootstrapped `regs_save` says exactly what it is.

**A dedicated `_idle_tcb` global gives O(1) pick_next fallback.**
Option D (publish via `_pid_table[0]`) would require pick_next to
special-case index 0 or scan `_pid_table[0..64]` (one extra
comparison per pick, forever). A dedicated global makes the fallback
one load: `mov rax, [rip + _idle_tcb]; ret`. Zero conditionals in
the hot path.

### 2.3 Storage

```
// src/kernel/core/sched/idle.pdx

// Backing storage: 2224-byte slab, same shape as _task_pool slots so
// sched_switch (#564) can use one uniform layout. .bss uninit → zero,
// which pre-satisfies pid=0 and state=STATE_RUNNABLE... no wait, state
// is written explicitly (see §5). Aligned to 4 KiB for cache-line
// symmetry with _task_pool.
pub let mut _idle_task_slot : [u64; 278] = uninit @align(4096)

// Idle's kernel stack: 4 KiB (one page). Idle never grows a call chain
// — its whole body is 3 bytes — so a smaller stack than the 8 KiB real
// tasks get is defensible. Kept at 4 KiB (512 u64s) to be the same
// order of magnitude and one page for TLB-count parity.
pub let mut _idle_kernel_stack : [u64; 512] = uninit @align(16)

// Dedicated pointer to _idle_task_slot, published at idle_init and read
// by sched_pick_next_r15 as its "runqueue empty" fallback. RIP-relative
// via lea + mov [rip + _idle_tcb], _idle_task_slot at init time.
pub let mut _idle_tcb : u64 = 0
```

## 3. task_struct regs_save layout freeze

**Freeze: `regs_save` spans `[+32, +152)` — 15 u64 slots, 120 bytes.**

This matches the region already reserved by #548's r15-m5-006 doc
(§3.5 post-condition, lines 405–422) — nothing moves. This doc
**names the two slots** that #562 and #564 need:

| Field | Offset | Type | Freeze in this doc |
|---|---|---|---|
| `regs_save.rsp` | task + 32 (slot 0) | u64 | #562 (idle bootstrap) |
| `regs_save.rip` | task + 40 (slot 1) | u64 | #562 (idle bootstrap) |
| `regs_save.rflags` | task + 48 (slot 2) | u64 | #564 (sched_switch) |
| `regs_save.rbx..r15` | task + 56..+152 | 12 × u64 | #564 (sched_switch) |

Rationale:
- `RSP` at slot 0 mirrors the R10-M4 TCB convention (`_task_a_tcb`
  puts RSP at `regs[15]` @ +120 within a 184-byte TCB — different
  offset, same idea: "the pointer we load first"). Reserving slot 0
  makes `mov rsp, [rdi + 32]` a single instruction with `disp8`.
- `RIP` at slot 1 lets #564's switch-in path be a single sequential
  load pair: `mov rsp, [rdi+32]; mov rax, [rdi+40]; jmp rax`.
- `RFLAGS` at slot 2 leaves `push [rdi+48]; popfq` idiomatic.
- The remaining 12 slots (72 bytes) hold the callee-saved GPRs
  (RBX, RBP, R12–R15) plus scratch. #564 fixes their individual
  offsets.

The two fields we freeze here (`rsp`, `rip`) suffice for #562's
bootstrap; #564 tightens the rest.

**Cross-linked to `design/kernel/task-struct-layout.md`.** This
freeze is an increment to the layout doc that #543 owns; the
update is a table addition, no field motion.

## 4. `idle_code` emission

**In `.text` (the default kernel text section), 3 bytes: `F4 EB FD`.**

```
// src/kernel/core/sched/idle.pdx

pub let idle_code : () -> () !{sysreg} @{boot} = fn () -> unsafe {
  effects: { sysreg },
  capabilities: { boot },
  justification: "R15-M7-001 (#562): idle-task body — infinite hlt loop. Executes at CPL=0 with kernel CS/SS. hlt (0xF4) halts the CPU until the next interrupt; on return from the interrupt handler control resumes at the jmp (0xEB 0xFD, short backward jump -3) which loops back to hlt. Never returns (no ret). The kernel context this runs under is whatever CR3 was loaded when sched_switch (#564) picked idle — idle does not manipulate CR3. Safe: hlt in ring-0 is privileged, but that's the ring idle runs in; jmp is trivially safe. No stack push, no register clobber beyond RIP itself.",
  block: {
    idle_loop:
      hlt
      jmp idle_loop
  }
}
```

**Why `.text` not `.text.idle`.** No linker-script segregation buys
anything at R15.M7: idle_code is 3 bytes, and the higher-half kernel
image is already ~40 KiB. A distinct section only becomes worth its
prologue overhead when we start attributing per-section metrics
(size, coverage, hot/cold layout) — that's an R17+ concern. `.text`
placement keeps the linker script (`src/kernel/kernel.ld`) untouched.

**Why not `.rodata`.** `.rodata` is not executable — attempting
to fetch `hlt` from a page marked NX/W^X would #GP or #PF. `.text`
gets `X` from the higher-half PT install.

**Encoding audit.** `hlt` = `0xF4` (1 byte) and `jmp rel8 = 0xEB, disp8`
(2 bytes). Backward short jump: `disp8 = -3` (target = current +
disp8 + 2 = `idle_code + 2 + (-3) = idle_code - 1` — wait, that
lands one byte before `hlt`; the correct disp is the byte OFFSET
from the end of the `jmp` instruction to the target. `hlt` at
offset 0, `jmp` at offset 1, `jmp` ends at offset 3, target is
offset 0, so `disp8 = 0 - 3 = -3 = 0xFD`. Confirmed: `F4 EB FD`.
paideia-as `jmp rel8` encoding is already exercised in
`aspace_map.pdx` retry loops and `pt_walk`.

## 5. Bootstrap sequence in kernel_main

`idle_init` is a new function in `idle.pdx`, called from
`boot_continue_after_ring3` **before** the R10 Task A bootstrap
(specifically: between `pic_mask_all` and the loader witness, so
idle exists before any code path that might call `sched_pick_next`).

```
// src/kernel/core/sched/idle.pdx  — new function

pub let idle_init : () -> () !{mem, sysreg} @{boot} = fn () -> unsafe {
  effects: { mem, sysreg },
  capabilities: { boot },
  justification: "R15-M7-001 (#562): idle-task bootstrap. Called once from kernel_main, before any code path that can invoke sched_pick_next. Sequence: (1) publish _idle_tcb = &_idle_task_slot. (2) Populate the two fields sched_switch (#564) will read: regs_save.rsp = _idle_kernel_stack + 4096 (top-of-stack for pre-decrement push semantics), regs_save.rip = &idle_code. (3) Set state = STATE_RUNNABLE (u32 at +8) — idle is always eligible. Leave every other field at .bss zero: pid=0 (sentinel — idle has no PID visible to sys_wait, sys_fork, or pid_alloc), parent_pid=0, exit_status=0, user_pml4_pa=0 (idle uses whatever CR3 is loaded when picked — kernel higher-half addresses are always mapped), kernel_stack=0 (deferred; #564 reads regs_save.rsp not kernel_stack). Register discipline: no callee-save touched (rax/rcx/rdi scratch only, all caller-save). Idempotent: safe to call multiple times.",
  block: {
    // (1) Publish _idle_tcb.
    lea rax, [rip + _idle_task_slot];
    lea rcx, [rip + _idle_tcb];
    mov [rcx], rax;

    // (2) regs_save.rsp = &_idle_kernel_stack + 4096 (top-of-stack).
    //     Stack grows down; the "top" is the highest addressable u64.
    //     _idle_kernel_stack is 512 u64s = 4096 bytes; top = base + 4096.
    lea rcx, [rip + _idle_kernel_stack];
    add rcx, 4096;
    mov [rax + 32], rcx;                 // regs_save.rsp @ +32

    // (3) regs_save.rip = &idle_code.
    lea rcx, [rip + idle_code];
    mov [rax + 40], rcx;                 // regs_save.rip @ +40

    // (4) state = STATE_RUNNABLE (1).
    mov ecx, 1;
    mov [rax + 8], ecx;                  // state @ +8 (u32)

    ret
  }
}
```

**Call site in `kernel_main.pdx`.** In `boot_continue_after_ring3`,
insert `call idle_init` between the existing `pic_mask_all` and the
`R14b-m5-007` IPI witness. This ordering:
- Runs after interrupts are wired (so any future `sched_pick_next`
  call from an ISR sees a populated `_idle_tcb`), but
- Runs before any test that might indirectly call `sched_pick_next`.

At R15.M7 no code actually calls `sched_pick_next` yet from the boot
path (the R10 cooperative `task_a_entry` bootstrap is direct, not
scheduler-mediated). So the ordering is defensive — it just anchors
the invariant "if you can call sched_pick_next after the boot
prologue, `_idle_tcb` is non-zero".

## 6. `sched_pick_next_r15` stub semantics

```
// src/kernel/core/sched/pick_next.pdx  — new function alongside existing r11 variant

pub let sched_pick_next_r15 : () -> u64 !{mem} @{sched} = fn () -> unsafe {
  effects: { mem },
  capabilities: { sched },
  justification: "R15-M7-001 (#562): O(64) linear scan of _pid_table[1..64] for the first task with state == STATE_RUNNABLE (1). Returns _idle_tcb (guaranteed non-zero by idle_init) when no RUNNABLE task is found. NOT the hot path — #563 replaces this with a linked-list runqueue in O(1) enqueue/dequeue. At R15.M7 zero real tasks are enqueued anyway (the R10 alternation still drives Task A/B directly), so this scan touches only null slots and returns idle every time — exactly the AC #562 asserts. Register discipline: rcx (scan index), rax (return / slab load), all caller-save. Callee-save clean.",
  block: {
    mov rcx, 1;                                 // pid scan starts at 1
  pick_loop:
    cmp rcx, 64;                                // MAX_PIDS
    ja  pick_idle;                              // past end → idle
    lea rax, [rip + _pid_table];
    mov rax, [rax + rcx*8];                     // _pid_table[rcx]
    cmp rax, 0;
    je  pick_next_slot;                         // free slot
    mov edx, [rax + 8];                         // task->state (u32)
    cmp edx, 1;                                 // STATE_RUNNABLE
    je  pick_hit;                               // found one
  pick_next_slot:
    add rcx, 1;
    jmp pick_loop;
  pick_hit:
    ret;                                        // rax already = slab_addr
  pick_idle:
    mov rax, [rip + _idle_tcb];
    ret
  }
}
```

**O(64) is fine at R15.M7.** With zero enqueued tasks the scan
touches 64 empty slots and returns idle in ~200 cycles.
With ≤32 tasks (R15 test load) it's ~100 cycles average. #563's
linked-list replacement drops this to O(1), but the semantic
contract stays identical: "return a RUNNABLE task, or `_idle_tcb`".

**Naming: `sched_pick_next_r15`.** Deliberately co-exists with
`sched_pick_next` (from the older Phase-4 stub in pick_next.pdx —
currently returns `idle_tcb` sentinel = 0) and `sched_pick_next_r11`
(the 2-task alternation). Nothing in the tree calls the Phase-4 stub;
it stays as inert legacy until #563 deletes it. `sched_pick_next_r11`
is still called from the R11 preemption smoke and must not be
disturbed until #565 replaces the timer ISR's pick call.

## 7. Test canary — witness pattern

Insert into `boot_continue_after_ring3` (kernel_main.pdx), just after
the existing `sys_fork_witness_exit` block and before the
`R14b-m5-002 (#507)` GS_BASE setup. Fingerprint marker:
`R15 IDLE TASK OK`.

```
      // ============================================================
      // R15-M7-001 (#562): idle-task witness — 4 sub-tests, 1 marker
      // ============================================================
      idle_witness:
          // ---------- Sub-test 1: _idle_tcb is published + non-zero ----------
          call idle_init;                          // idempotent — safe to re-call
          mov rax, [rip + _idle_tcb];
          cmp rax, 0;
          je  idle_witness_fail;
          mov r12, rax;                            // r12 = &_idle_task_slot

          // Assert: _idle_tcb == &_idle_task_slot (identity)
          lea rax, [rip + _idle_task_slot];
          cmp rax, r12;
          jne idle_witness_fail;

          // ---------- Sub-test 2: state == STATE_RUNNABLE ----------
          mov eax, [r12 + 8];                      // state (u32) @ +8
          cmp rax, 1;                              // STATE_RUNNABLE
          jne idle_witness_fail;

          // ---------- Sub-test 3: regs_save.rip == &idle_code ----------
          mov rax, [r12 + 40];                     // regs_save.rip @ +40
          lea rcx, [rip + idle_code];
          cmp rax, rcx;
          jne idle_witness_fail;

          // Assert: regs_save.rsp is inside _idle_kernel_stack
          mov rax, [r12 + 32];                     // regs_save.rsp @ +32
          lea rcx, [rip + _idle_kernel_stack];
          cmp rax, rcx;
          jb  idle_witness_fail;                   // rsp < stack base → bad
          add rcx, 4096;
          cmp rax, rcx;
          ja  idle_witness_fail;                   // rsp > stack top → bad

          // ---------- Sub-test 4: pick_next returns idle when nothing RUNNABLE ----------
          // Precondition: no earlier witness left a task in RUNNABLE state.
          //   task_new witnesses all leave state=STATE_NEW (0);
          //   sys_exit witnesses leave state=STATE_ZOMBIE (3);
          //   sys_wait sub-test B leaves parent_b in STATE_WAITING (2);
          //   sys_wait sub-test A reaped its child (slot cleared).
          // No RUNNABLE tasks exist → pick_next must return _idle_tcb.
          call sched_pick_next_r15;
          cmp rax, r12;                            // must == &_idle_task_slot
          jne idle_witness_fail;

          // ---------- All checks green ----------
          lea rdi, [rip + idle_witness_ok_msg];
          call uart_puts;
          jmp idle_witness_exit;

      idle_witness_fail:
          lea rdi, [rip + idle_witness_fail_msg];
          call uart_puts;

      idle_witness_exit:
```

Add the two strings to the banner constants block:
```
pub let idle_witness_ok_msg   : [u8; 20] = "R15 IDLE TASK OK\r\n\0";
pub let idle_witness_fail_msg : [u8; 22] = "R15 IDLE TASK FAIL\r\n\0";
```

**Note on sub-test 4's precondition.** The R15.M5/M6 witnesses that
precede this leave `_pid_table[1..64]` populated with tasks in
states `NEW` (0), `ZOMBIE` (3), and `WAITING` (2) — not `RUNNABLE`.
This is arithmetic on the witness sequence in §7 above, not an
assumption. If a future witness lands a `RUNNABLE` task before the
idle witness, sub-test 4 breaks, and we add `_pid_table` zeroing to
this witness's prelude — but that hasn't happened at R15.M7, and #563
(runqueue-real) will restructure this witness anyway.

**Why we do NOT actually context-switch to idle in this witness.**
Loading `regs_save.rsp` into `RSP` and jumping to `regs_save.rip`
would enter idle_code's `hlt` loop, halting the CPU — the smoke
harness would time out. Real switch-to-idle happens in the #564
sched_switch witness, which arms a timer to fire before the smoke
timeout and observes the wake path.

## 8. Deferred to follow-on issues

- **#563 (r15-m7-002 runqueue-real).** Replaces `sched_pick_next_r15`'s
  O(64) scan with a doubly-linked list. Idle stays off the runqueue;
  the empty-runqueue check falls back to `_idle_tcb`.
- **#564 (r15-m7-003 sched-switch-real).** First save→restore path
  that reads `regs_save.rsp` / `regs_save.rip`. Extends the layout
  freeze this doc started to cover RFLAGS and the callee-save GPRs.
- **#565 (r15-m7-004 lapic-timer 100Hz).** Programs the timer to
  drive `sched_pick_next` on each tick — from that point idle is
  actually entered when nothing is runnable.
- **#566–#568 (block/wake, yield-on-empty-tty-read, SMP hooks).**
  Extend idle's role to per-CPU and mesh it with block/wake state.

## 9. Fingerprint file updates

Two files need one marker line each, inserted **before** the
`IPI OK` line (matches the boot order after §7's insertion):

**`tests/r15/expected-boot-r15-process.txt`** — add `R15 IDLE TASK OK`
between `R15 SYS FORK OK` and `IPI OK`.

**`tests/r15/expected-boot-r15-ring3.txt`** — same line at the
symmetric position (verify the exact preceding marker; the two files
diverge only by ordering of earlier R15 witnesses).

No new smoke mode is needed — the two existing modes (`boot_r15_ring3`,
`boot_r15_process`) both exercise `boot_continue_after_ring3`, so
both fingerprints pick up the new marker in-order.

## 10. LOC estimate

| Component | File | Lines |
|---|---|---|
| `idle_code` (unsafe fn, 3 bytes of asm + boilerplate) | idle.pdx | 12 |
| `_idle_task_slot` + `_idle_kernel_stack` + `_idle_tcb` declarations | idle.pdx | 8 |
| `idle_init` (unsafe fn, ~10 asm instructions) | idle.pdx | 24 |
| `sched_pick_next_r15` (unsafe fn, ~15 asm instructions) | pick_next.pdx | 28 |
| Witness block (4 sub-tests + banner strings) | kernel_main.pdx | 55 |
| `call idle_init` insertion + banner-string decls | kernel_main.pdx | 6 |
| **Total** | | **~135 LOC** |

Encoder gaps expected: **none**. Every instruction lands on already-audited
paideia-as encodings (hlt, jmp rel8, mov r/m, lea, cmp, ja/je/jne, ret).

## 11. Tractability

**Green.** Every design decision is either (a) a shape reuse of an
already-landed pattern (slab-in-.bss, unsafe-block asm justification,
witness/fingerprint pair) or (b) a small, isolated new artifact
(idle_code's 3 bytes, `_idle_tcb`'s single u64). Zero encoder gaps.
No cross-module surface changes: the two new symbols
(`sched_pick_next_r15`, `_idle_tcb`) are consumed only by #563 and
later — nothing at R15.M7 wires them into a hot path yet, so a
regression in either is caught by the witness alone, not by
downstream breakage.

The one live risk is the `regs_save.rsp` / `regs_save.rip` offset
freeze: if #564 wants a different layout, #562 has to migrate two
stores (`mov [rax+32]`, `mov [rax+40]`). The layout picked (RSP at
slot 0, RIP at slot 1) matches idiomatic ret-into-switch code and
mirrors the R10-M4 TCB `regs[15]=RSP` convention — reversal would be
a mild surprise for #564's implementer. If #564 elects a different
scheme, the migration is one-line-per-store in `idle_init`.
