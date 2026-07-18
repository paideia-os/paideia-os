---
issue: 557
milestone: R15.M6 (fork / exec / wait / _exit)
subsystem: 9 — fork / exec / wait / _exit
prereq:
  - "#548 (task_new real — LANDED at src/kernel/core/sched/task_pool.pdx; provides parent+child construction the witness drives)"
  - "#549 (fd_table embed — LANDED; pins task_struct offsets 0/4/8/12/16 that sys_exit reads/writes)"
  - "#550 (task_free real — LANDED; sys_exit deliberately does NOT free; parent's sys_wait consumer does)"
  - "#547 (task-state-machine — doc-only ratification of state enum; this doc pins the R15.M6-safe 4-state contract)"
  - "R15.M6-005 / #556 (sys_wait real body — tactical plan lists as prereq; but the sys_exit body here is independent-testable via witness driver and can land ahead of #556 with the syscall wrapper deferred)"
blocks:
  - "R15.M6-005 / #556 (sys_wait — consumes the state=WAITING → RUNNABLE wakeup and the wait_result_pid/wait_result_status fields this doc pins)"
  - "R15.M6-007 / #558 (orphan adoption by init — task_free of a parent must run reparent-to-init before its children hit sys_exit with stale parent_pid; wire-up point noted in §8)"
  - "R15.M6-009 / #560 (fork/exec/wait smoke — the fingerprint `WAIT: pid=child status=N` proves sys_exit + sys_wait round-trip)"
touching:
  - src/kernel/core/syscall/handlers/sys_exit.pdx           (NEW module + NEW handlers/ directory)
  - src/kernel/boot/kernel_main.pdx                         (witness block, ~75 LOC)
  - tools/boot_stub.S                                       (2 rodata strings)
  - tests/r15/expected-boot-r15-process.txt                 (marker line, contains-in-order)
  - tests/r15/expected-boot-r15-ring3.txt                   (marker line, contains-in-order)
  - tests/r14b/expected-boot-r14b-loader.txt                (marker line, contains-in-order)
  - design/kernel/r15-m6-006-sys-exit.md                    (this doc)
related:
  - design/kernel/r15-m5-006-task-new-real.md               (task_struct field offsets — 0/4/8/16 pinned; this doc consumes 12)
  - design/kernel/r15-m5-007-fd-table-embed.md              (§3.1 — this doc DIVERGES from the 5-state hint and REPURPOSES wait_reply_slot; see §3.1 discrepancy notes)
  - design/kernel/r15-m5-008-task-free-real.md              (§6.5 backtrack E — anticipated exit_status side-table; superseded by this doc's in-slab field)
  - design/milestones/r14b-tactical-plan.md                 (§Subsystem 9 issue 6, line 1051; state machine line 908 + 1012)
---

# R15-M6-006 — sys_exit real body: zombie + exit_status + parent-wait wakeup (#557)

## 1. Scope

Give `sys_exit` a real, testable body so that:

1. `sys_exit_body(current, status)` transitions `current->state` to
   `STATE_ZOMBIE` and stores `status` into `current->exit_status`,
   unconditionally.
2. If the parent (looked up via `_pid_table[current->parent_pid]`)
   is in `STATE_WAITING`, the body:
   - Writes `parent->wait_result_pid   = current->pid`
   - Writes `parent->wait_result_status = current->exit_status`
   - Transitions `parent->state = STATE_RUNNABLE` (wakeup)
3. `sys_exit_body` does **NOT** free the child slab or pid slot. The
   parent's `sys_wait` (#556) is the sole consumer of the zombie's
   exit_status, and its return path invokes `task_free(child)` after
   copying the two u32s out.
4. If the parent is not in `STATE_WAITING` (still `RUNNABLE`, or
   never called `sys_wait`), the child stays zombie; the parent's
   *future* `sys_wait` will scan `_pid_table` for zombie children
   with `parent_pid == self.pid` and reap synchronously.
5. If `current->parent_pid == 0` (no parent — init exiting) or
   `_pid_table[parent_pid] == 0` (parent already gone; shouldn't
   happen after reparent-to-init lands #558, but defensively
   handled), the body still sets the zombie state + exit_status
   and returns — no wakeup.

Two invariants define completion:

- **Zombie idempotence.** After `sys_exit_body(t, s)`, `t->state ==
  ZOMBIE` and `t->exit_status == s` **regardless** of parent
  presence, parent state, or pid_table content. A parent that
  arrives later (via sys_wait scan) sees the same slab bytes.
- **Parent wakeup atomicity (single-CPU).** The three-store wakeup
  (`wait_result_pid`, `wait_result_status`, `state = RUNNABLE`)
  runs with interrupts disabled for the duration of the body OR
  is trusted to be uninterruptible at R15.M6 single-CPU. Ordering
  discipline documented in §3.6.

Explicitly out of scope (deferred):

- **Syscall wrapper wiring.** The current `sys_exit` handler in
  `src/kernel/core/syscall/dispatch.pdx:127` prints `[exit]` and
  halts. This doc lands the *body* (`sys_exit_body`) as a leaf
  function testable without a real syscall entry. The wrapper
  (`sys_exit`) that reads `current` from `cpu_local` (via
  `cpu_local_get`) and calls `sys_exit_body`, then invokes the
  scheduler to pick the next runnable task, is a downstream
  edit — deferred to the sys_wait landing (#556) or a follow-up
  once the scheduler exposes `sched_pick_next` at the R15.M6
  altitude. The dispatch.pdx stub stays as `[exit]` + hlt until
  that edit lands. This split is exactly what §3.2 mandates for
  testability without a running scheduler.
- **fd release.** The issue AC "fds released" is a request for
  R15.M5's `task_free`-style fd zeroing, but task_free is the
  post-reap step done by the parent's sys_wait return path. At
  sys_exit time, fds stay populated because they may still be
  referenced by inherited zombie state (e.g. a debugger reading
  the exit code). At R15.M5 fds are opaque u64s (no vnode
  refcount), so leaving them populated is harmless; when R16.M3
  grows the slot to `fd_entry`, this design's task_free-in-wait
  path calls `fd_close_all` before releasing the slab. See §8
  cross-cutting risk on this AC interpretation.
- **Scheduler transition.** After sys_exit_body returns, the
  syscall wrapper must not return to userspace (the caller is
  zombie). It must invoke the scheduler to pick another task.
  That's a wrapper concern, not a body concern — deferred.
- **kind_reply / capability-based wakeup.** The tactical plan
  §Subsystem 9 mentions `current->wait_reply_slot = <cap slot>`
  and `kind_reply wait`. That's an SMP-safe wakeup pattern for
  a future R15.M6+ hardening step. R15.M6 single-CPU uses the
  simpler `parent->state = RUNNABLE` polling model documented
  here. §6.2 backtrack B is the promotion path.
- **Reparent-to-init.** #558 walks `_pid_table` on parent
  destruction and rewrites `child->parent_pid = 1`. Not this
  issue's concern; sys_exit here reads `current->parent_pid`
  as-is (whatever any prior reparent-to-init pass left it at).

## 2. Prereq check

### 2.1 What's in place

| Primitive                    | Location                                        | Contract used by sys_exit_body                     |
|------------------------------|-------------------------------------------------|----------------------------------------------------|
| `task_struct.pid @ 0`        | `design/kernel/r15-m5-007-fd-table-embed.md`    | u32, read to compute wait_result_pid               |
| `task_struct.parent_pid @ 4` | `#549 §3.1 layout freeze`                       | u32, read to look up parent slab                   |
| `task_struct.state @ 8`      | `#549 §3.1 layout freeze`                       | u32, written to STATE_ZOMBIE / STATE_RUNNABLE      |
| `task_struct.exit_status @ 12` | `#549 §3.1 layout freeze`                     | u32, written to `status` from sys_exit arg         |
| `_pid_table[pid]`            | `core/sched/task_pool.pdx:21`                   | u64 slab pointer, indexed by pid (SIB scale-8)     |
| `task_new`                   | `core/sched/task_pool.pdx:71`                   | Constructs parent+child slabs the witness drives   |
| `mov [reg + disp8], imm32`   | `mov_mem_imm_sib.pdx` audit (used by pid_free)  | State + exit_status stores (u32 immediate 3, 42, 99) |
| `mov [reg + disp8], r32`     | `task_pool.pdx:112, 118` (fd_table stores)      | State + exit_status stores from register           |
| `mov r64, [rip + sym]` / `lea` | Every RIP-rel access in this codebase         | `&_pid_table` base loads                           |

### 2.2 What is not in place — required prerequisites this doc consumes on faith

- **#547 task-state-machine doc.** This body writes literal
  integers `3` (ZOMBIE) and `1` (RUNNABLE) to `state @ 8`. #547
  formalizes the enum. This doc pins the 4-state contract in §3.4;
  #547's ratification must adopt it (or backtrack via §6.5).
- **cpu_local `current_task()` accessor** — needed by the syscall
  wrapper `sys_exit`, NOT by `sys_exit_body`. This split lets the
  body land testably without the accessor. When the accessor
  lands (as part of the sys_fork / sys_wait wire-up), the wrapper
  edit is 5 lines.
- **`src/kernel/core/syscall/handlers/` directory.** Does not
  exist yet. Creating it is the same discipline as #549 creating
  `src/kernel/core/fs/` — plain `mkdir` in the layout, no
  linker-script edit (kernel_build.sh walks the tree). §3.5
  documents the directory addition.

### 2.3 Encoder gaps

**None.** The sys_exit_body uses only:

- Register-to-register `mov`, `xor`, `cmp` — audited substrate
- `mov r32, [reg + disp8]` — audited by fd_table SIB+disp
- `mov [reg + disp8], r32` — audited by fd_table stores
- `mov [reg + disp8], imm32` — audited by pid_free store, kpti immediate stores
- `mov [reg + reg*8], reg64` and `mov r64, [reg + reg*8]` — SIB
  scale-8 pid_table load, audited by task_pool.pdx:123
- `je / jne / jz / jmp / ret` — vanilla control flow

No calls inside the body → no callee-save discipline required
(callers see caller-save regs intact by convention).

## 3. Design

### 3.1 task_struct field pinning (R15.M6 addendum to fd-table doc §3.1)

This doc **freezes** the four fields sys_exit reads/writes plus the
two wakeup fields it writes on the parent:

```
Confirmed by #549 §3.1 (unchanged):
  offset   size   field         type   used by sys_exit
  ------   ----   -----------   ----   ----------------
     0       4    pid           u32    read for wait_result_pid on parent
     4       4    parent_pid    u32    read to look up parent slab
     8       4    state         u32    written STATE_ZOMBIE (self), STATE_RUNNABLE (parent)
    12       4    exit_status   u32    written from status arg (self); read for wait_result_status on parent
    16       8    user_pml4_pa  u64    NOT touched by sys_exit (parent's sys_wait invokes task_free)

Pinned by THIS doc (repurposed from fd-table doc §3.1 speculative fields):
  offset   size   field                type   used by sys_exit
  ------   ----   -----------------    ----   ----------------
  1704       4    wait_result_pid      u32    written on parent when parent is WAITING
  1708       4    wait_result_status   u32    written on parent when parent is WAITING
```

**Discrepancy with fd-table doc §3.1 (called out for #543
ratification):**

| Aspect            | fd-table doc §3.1 speculative | This doc (R15.M6 freeze) |
|-------------------|-------------------------------|--------------------------|
| Field name @ 1704 | `wait_child_pid`               | `wait_result_pid`         |
| Field name @ 1708 | `wait_reply_slot`              | `wait_result_status`      |
| State count       | 5 (NEW/RUNNABLE/RUNNING/BLOCKED/ZOMBIE) | 4 (NEW/RUNNABLE/WAITING/ZOMBIE) |
| State values      | ZOMBIE=4                       | ZOMBIE=3                  |

**Why this doc wins over the fd-table doc §3.1 hint:** the
fd-table doc explicitly labeled its state enum a comment "pinned
by this doc" but the fd_table code (`fd_get`, `fd_set`,
`fd_alloc`) does NOT inspect state, so the 5-state hint has zero
code consumer to date. The task_new witness in kernel_main
(`state == 0` check at line 604) treats 0 as NEW without
commitment to what non-zero values mean. #547 has not landed. So
this doc's freeze is the first *load-bearing* commitment, and it
adopts the 4-state contract that the R15.M6 sys_exit + sys_wait
model needs. RUNNING is implicit (the currently-executing task is
identified by `cpu_local_get`, not by a `state == RUNNING` field —
this is x86 SMP-standard: no "am I the running one" self-query).
BLOCKED is folded into WAITING (the only R15.M6 block reason is
"blocked in sys_wait for child exit"; other block reasons —
sys_read on empty pipe, mutex — arrive later and can extend the
enum without breaking sys_exit).

**#543 ratification action:** the layout-freeze doc must record
`state ∈ {NEW=0, RUNNABLE=1, WAITING=2, ZOMBIE=3}` and rename the
1704/1708 fields to `wait_result_pid`/`wait_result_status`. This
doc is the source of truth until #543 lands.

### 3.2 Function split — testable body + syscall wrapper

```
sys_exit_body : (current: u64, status: u64) -> () !{mem} @{}
    Leaf function. No nested calls. Directly writes to fields on
    `current` and (conditionally) on parent. Testable by the
    witness with an explicit `current` pointer — no scheduler,
    no cpu_local, no interrupt state manipulation.

sys_exit_wrapper : (status: u64) -> u64 !{mem, sysreg} @{sched}
    NOT lANDED THIS ISSUE. Downstream edit (paired with sys_wait
    #556). Reads current = cpu_local_get()->current_task, calls
    sys_exit_body(current, status), then invokes the scheduler
    to pick another runnable task. Never returns to userspace.
```

Why the split. The user brief for #557 explicitly requests
"witness pattern, no real syscall wiring". Splitting the leaf
body out of the wrapper achieves that in the smallest possible
diff — the body ships now, the wrapper edits `dispatch.pdx` when
the scheduler is ready. The alternative (implementing the whole
wrapper now, with a stub `cpu_local_get_current_task`) inflates
the diff, couples this issue to the scheduler landing, and defeats
the "landable independent" property.

### 3.3 Body sequence — six steps, one rationale

```
sys_exit_body(current, status):
  step 1  current->state       = STATE_ZOMBIE  (u32 store @ 8)
  step 2  current->exit_status = status         (u32 store @ 12)
  step 3  parent_pid = current->parent_pid     (u32 load @ 4)
          if parent_pid == 0: return           (init exiting, no parent)
  step 4  parent = _pid_table[parent_pid]      (u64 load, SIB scale-8)
          if parent == 0: return                (parent gone; defensive — reparent-to-init makes this unreachable in normal ops)
  step 5  if parent->state != STATE_WAITING: return
          (parent will scan zombies via sys_wait)
  step 6  parent->wait_result_pid    = current->pid          (u32)
          parent->wait_result_status = status                 (u32)
          parent->state              = STATE_RUNNABLE         (u32)
          return
```

**Why this order.**

1. **Zombie transition BEFORE parent lookup (steps 1–2 before
   step 3).** The AC "zombie idempotence" — after sys_exit_body,
   `current->state == ZOMBIE` and `current->exit_status ==
   status` unconditionally — is met by front-loading these two
   stores. Any error / early-return path in steps 3-5 has
   already satisfied the AC. A caller that observes the zombie
   state (post-return) always sees the correct exit_status,
   whether or not parent wakeup happened.

2. **`parent_pid == 0` early return (step 3 guard).** Init (pid
   1) exits with `parent_pid == 0` (task_new(NULL) sets
   parent_pid to zero). No parent to wake; no lookup needed.
   This branch also covers "orphaned tasks awaiting reparent" —
   if #558 has not run by the time an orphan calls sys_exit,
   `parent_pid` may point at a since-freed pid; step 4 catches
   that case defensively.

3. **`parent == 0` defensive branch (step 4 guard).** After #558
   reparent-to-init lands, every non-init task's parent_pid
   points at a live task_struct (init if the original parent
   died). Before #558, a race window exists where a parent
   died before reparenting the child; step 4 catches the
   dangling reference and treats it as "no parent" — zombie
   left for future GC (or R15.M6-007's forced-reap at boot
   completion). No panic; the R15.M6 discipline is
   defensive-correct rather than assertion-panic.

4. **`parent->state != WAITING` early return (step 5 guard).**
   The parent may be RUNNABLE (still running its own code,
   hasn't called sys_wait yet) or NEW (freshly constructed and
   not yet enqueued — rare but possible during a fork race).
   In either case the parent will invoke sys_wait later; that
   sys_wait's zombie-scan will find this child. Writing to
   `wait_result_pid` NOW would race with a concurrent parent
   sys_wait scan (parent reads its own wait_result_pid to
   decide "am I already reap-signaled from a prior exit?").
   The state guard makes the write happen only when the parent
   is *parked* in sys_wait — no race.

5. **Wakeup stores in order pid/status/state (step 6).** The
   parent is parked in sys_wait, spinning on `parent->state ==
   WAITING` (or on a future kind_reply cap). The wakeup writes:
   - First: `wait_result_pid` — data the parent will consume.
   - Second: `wait_result_status` — data the parent will consume.
   - Last: `state = RUNNABLE` — the *publish* signal. Once
     this store is visible, the parent may observe the wakeup
     and read the two data fields.

   At R15.M6 single-CPU with no preemption inside sys_exit_body,
   this ordering is aesthetic — the parent isn't running until
   the scheduler picks it, which won't happen until we return
   from sys_exit and the wrapper (deferred) invokes
   sched_pick_next. On SMP the "publish last" discipline
   matches x86 TSO: parent's load-of-state (LoadLoad-ordered
   after the publish state=RUNNABLE store) is guaranteed to see
   the two prior stores. §6.4 backtrack D discusses an explicit
   sfence for SMP.

6. **No slab teardown, no pid_free.** sys_exit_body is NOT the
   inverse of task_new. That's task_free (#550), which runs from
   the parent's sys_wait after copying the exit_status out. If
   sys_exit called task_free, the parent's sys_wait would race
   with the freed pid_table[child] slot — pid gets reused
   before the parent reads it. Zombie retention across sys_exit
   → sys_wait is what makes the return value valid.

### 3.4 State enum contract (R15.M6 freeze)

```
STATE_NEW      : u32 = 0    // freshly constructed by task_new; never run
STATE_RUNNABLE : u32 = 1    // in a runqueue OR currently executing (RUNNING is implicit)
STATE_WAITING  : u32 = 2    // parked in sys_wait for a child's sys_exit
STATE_ZOMBIE   : u32 = 3    // sys_exit ran; parent has not yet reaped
```

**Transitions this design commits to:**

| From        | To          | Trigger                          | Landing issue      |
|-------------|-------------|----------------------------------|--------------------|
| NEW         | RUNNABLE    | sched_enqueue                    | R15.M6-001         |
| RUNNABLE    | WAITING     | sys_wait (no zombie child yet)   | R15.M6-005 (#556)  |
| WAITING     | RUNNABLE    | sys_exit on any child            | **this issue**     |
| RUNNABLE    | ZOMBIE      | sys_exit on self                 | **this issue**     |
| ZOMBIE      | (freed)     | parent's sys_wait reap           | R15.M6-005 (#556)  |

**Transitions NOT committed (future extensions):**

- BLOCKED (sys_read / mutex) — new enum variant added later
- SLEEPING (sys_nanosleep) — new enum variant added later
- STOPPED (SIGSTOP / debugger) — deferred to R17+

**Discrepancy with `src/kernel/core/sched/tcb.pdx` STATE_* constants.**
`tcb.pdx` and `budget.pdx` and `yield.pdx` all define
`STATE_RUNNING=0, STATE_RUNNABLE=1, STATE_BLOCKED=2` for the R11
TCB (thread control block, distinct from the task_struct this
issue targets). Those are TCB-level states inside the R11
scheduler, NOT task-level states. The two enums coexist because
the R11 scheduler and the R15 process model are still layered:
the R11 TCB is a scheduler cookie; the R15 task_struct is a
process record. Unifying them is R17+ scheduler-integration work.
This doc's enum is task_struct-only. No conflict.

### 3.5 File and module structure

```
src/kernel/core/syscall/handlers/           <-- NEW directory
    sys_exit.pdx                            <-- this issue's body module
```

Precedent: `src/kernel/core/fs/` was created new by #549 (fd_table
embed) with the same discipline — `mkdir` in the layout, no
`kernel_build.sh` edit (the build discovers `.pdx` files by
directory walk). Verified against
`kernel_build.sh` for `mm/`, `ipc/`, `int/`, `fs/`.

**Full module skeleton:**

```pdx
// src/kernel/core/syscall/handlers/sys_exit.pdx — R15-M6-006 (#557)
// Task-terminate body: state → ZOMBIE, exit_status → status,
// conditional parent wakeup if parent is WAITING.
//
// Issue #557 (R15.M6 subsystem 9 issue 6).

module SysExit = structure {
  // ==========================================================================
  // State enum — R15.M6 freeze (§3.4)
  // ==========================================================================
  pub let STATE_NEW      : u32 = 0
  pub let STATE_RUNNABLE : u32 = 1
  pub let STATE_WAITING  : u32 = 2
  pub let STATE_ZOMBIE   : u32 = 3

  // ==========================================================================
  // Field offsets — pinned by design/kernel/r15-m5-007-fd-table-embed.md §3.1
  // and this doc §3.1 (wait_result_* repurpose).
  // ==========================================================================
  pub let TASK_OFF_PID                : u64 = 0
  pub let TASK_OFF_PARENT_PID         : u64 = 4
  pub let TASK_OFF_STATE              : u64 = 8
  pub let TASK_OFF_EXIT_STATUS        : u64 = 12
  pub let TASK_OFF_WAIT_RESULT_PID    : u64 = 1704
  pub let TASK_OFF_WAIT_RESULT_STATUS : u64 = 1708

  // ==========================================================================
  // R15-M6-006 (#557): sys_exit_body — leaf body, testable without scheduler
  // ==========================================================================
  pub let sys_exit_body : (u64, u64) -> () !{mem} @{} =
    fn (current: u64) (status: u64) -> unsafe {
      effects: {mem},
      capabilities: {},
      justification: "R15-M6-006 (#557): sys_exit body — testable leaf function (no nested calls, no cpu_local, no scheduler dependency). Entry: rdi = current (*task, non-NULL), rsi = status (u32 semantics, u64 ABI). Six steps: (1) current->state = STATE_ZOMBIE (u32 store @ offset 8). (2) current->exit_status = status (u32 store @ offset 12). (3) Load current->parent_pid (u32 zero-ext @ offset 4). If zero, return — init exiting or already reparented to zero sentinel. (4) Load parent = _pid_table[parent_pid] (u64 SIB scale-8, indexed by pid). If NULL, return — parent gone, orphan zombie left for future GC. (5) Load parent->state (u32 @ offset 8). If not STATE_WAITING, return — parent will scan zombies via sys_wait when it eventually calls. (6) Wakeup stores in order: parent->wait_result_pid = current->pid (u32), parent->wait_result_status = status (u32), parent->state = STATE_RUNNABLE (u32) — state store LAST so the parent's post-wakeup read of wait_result_* sees consistent data (TSO publish-last discipline; explicit sfence not needed at R15.M6 single-CPU, flagged for SMP promotion in §6.4). Register discipline: no nested calls → no callee-save prologue required; uses rax, rcx, r8, r9 (all caller-save). rdi (current) preserved through the entire body — reused for offset arithmetic without stashing. rsi (status) is preserved through step 6 (read directly from register into memory). Post-condition: current->state == ZOMBIE and current->exit_status == status ALWAYS, regardless of parent presence or parent state — this is the zombie-idempotence AC. Ordering: step 1+2 stores (self) execute before ANY parent-related loads/stores so the AC is met even on the earliest early-return path.",
      block: {
        // ===== step 1: current->state = STATE_ZOMBIE =====
        mov rax, 3;                             // STATE_ZOMBIE
        mov [rdi + 8], eax;                     // state @ 8 (u32)

        // ===== step 2: current->exit_status = status =====
        mov [rdi + 12], esi;                    // exit_status @ 12 (u32 low of status)

        // ===== step 3: parent_pid = current->parent_pid =====
        mov ecx, [rdi + 4];                     // parent_pid @ 4 (u32 zero-ext)
        cmp rcx, 0;
        je sys_exit_done;                       // no parent, done

        // ===== step 4: parent = _pid_table[parent_pid] =====
        lea rax, [rip + _pid_table];
        mov r8, [rax + rcx*8];                  // r8 = parent slab (u64)
        cmp r8, 0;
        je sys_exit_done;                       // parent gone, done

        // ===== step 5: guard on parent->state == STATE_WAITING =====
        mov eax, [r8 + 8];                      // parent->state (u32)
        cmp rax, 2;                             // STATE_WAITING
        jne sys_exit_done;                      // not waiting, done

        // ===== step 6: wakeup — three stores, state LAST =====
        mov eax, [rdi + 0];                     // current->pid (u32)
        mov [r8 + 1704], eax;                   // parent->wait_result_pid

        mov [r8 + 1708], esi;                   // parent->wait_result_status = status

        mov rax, 1;                             // STATE_RUNNABLE
        mov [r8 + 8], eax;                      // parent->state (publish last)

      sys_exit_done:
        ret
      }
    }
}
```

Total executable LOC: ~20 assembly lines + ~15 justification /
constants = ~35 LOC in `sys_exit.pdx`. Same order of magnitude as
`pid_free` (~5 asm lines), `fd_get/set` (~2 asm lines each), and
one step smaller than `task_new` (~40 asm lines) and `task_free`
(~30 asm lines).

### 3.6 Register discipline — the debugger-endemic bug this design avoids (again)

Recent PaideiaOS post-mortems (`f6195ed` — phys_alloc r12-r15
fix; `3e6a550` — self-IPI callee-save audit; #649 debugger
sessions) confirm that **register clobber across nested calls is
the endemic bug class**. sys_exit_body has **NO NESTED CALLS**,
so the class does not apply — but the same discipline that
avoids it in nested-call bodies also *prevents future edits*
that add nested calls from introducing the bug.

**Registers this body uses:**

| Register | Role                                | Callee-save? | Prologue push? |
|----------|-------------------------------------|--------------|----------------|
| rdi      | current (arg, preserved through body) | caller-save | no             |
| rsi      | status (arg, preserved through step 6) | caller-save | no             |
| rax      | scratch (imm loads, u32 reads)      | caller-save  | no             |
| rcx      | parent_pid (u32 zero-ext)           | caller-save  | no             |
| r8       | parent slab pointer                 | caller-save  | no             |

**All caller-save.** The caller (witness or future syscall
wrapper) is trusted to save/restore what *it* holds live across
the `call sys_exit_body`. This body's contract to the caller:
"you get back rax = don't care, rcx/r8 clobbered, rdi/rsi
preserved (by convention — not by discipline; a future edit may
clobber). No callee-save reg touched."

**Stack alignment.** Zero pushes → alignment is whatever the
caller passes in. No `call` inside the body → no downstream
alignment obligation.

**Future edit adding a nested call.** If R16.M3 wants sys_exit
to call `fd_close_all(current)` (per AC "fds released"), that
edit needs to:
- Push callee-save regs if it wants to hold rbx/r12/r13 across
  the fd_close_all call.
- Ensure `sub rsp, 8` if the total push count keeps rsp mis-16.
- The current 5-register footprint (all caller-save) is
  already-compatible; no push count needed if the added call
  uses fresh caller-save regs.

**Comparison to task_new's 3-push prologue.** task_new has
nested calls (pid_alloc, aspace_create_user, pid_free). It uses
rbx/r12/r13 (all callee-save) to hold live state across them.
Prologue = 3 pushes = 24 bytes; combined with return-address
push (8 bytes) = 32 bytes = 16 mod 0 → aligned. This body has
zero nested calls, so no such invariant needs maintaining.

### 3.7 Encoding notes — every mnemonic used

| Mnemonic                       | Byte pattern (nominal)          | Audited by                              |
|--------------------------------|---------------------------------|-----------------------------------------|
| `mov rax, imm32` (STATE_*)     | 48 C7 C0 xx xx xx xx           | Everywhere                              |
| `mov [rdi + disp8], eax`       | 89 47 xx                        | fd_table stores (task_pool.pdx:112,118) |
| `mov [rdi + disp8], esi`       | 89 77 xx                        | Same class as above                     |
| `mov ecx, [rdi + disp8]`       | 8B 4F xx                        | task_pool.pdx post-load                 |
| `lea rax, [rip + sym]`         | 48 8D 05 xx xx xx xx           | Every RIP-rel access                    |
| `mov r8, [rax + rcx*8]`        | 4C 8B 04 C8                     | task_pool.pdx:123 (pid_table load)      |
| `mov eax, [r8 + disp16]`       | 41 8B 80 xx xx xx xx           | New — needs verify (§ paideia-as check) |
| `mov [r8 + disp16], eax`       | 41 89 80 xx xx xx xx           | New — needs verify (§ paideia-as check) |
| `mov [r8 + disp8], eax`        | 41 89 40 xx                     | REX.B + disp8, standard                 |
| `cmp rcx, imm8`                | 48 83 F9 xx                     | Everywhere                              |
| `cmp rax, imm8`                | 48 83 F8 xx                     | Everywhere                              |
| `je / jne / jmp / ret`         | 74/75/EB/C3                     | Everywhere                              |

**Disp16 vs disp32.** Offset 1704 fits in a signed disp16 range
but x86-64 has no disp16 for `mov [reg + disp]` — only disp8
(signed −128..127) and disp32. Since 1704 exceeds disp8, the
encoder emits disp32. Verified pattern in
`kpti.pdx:246` (accessing symbols at large offsets via disp32).
No new paideia-as gap.

**REX.B on r8 as base.** `mov [r8 + disp32], eax` requires
REX.B (opcode extension). paideia-as audit
`aspace_teardown.pdx:37` flagged PA-#928 for
**SIB with extended base register** — but this pattern is a
plain `[base + disp]` (no SIB), which paideia-as handles
correctly. No gap. Cross-check: `aspace_create.pdx:96` uses
`[r12 + disp8]` extensively without issue.

## 4. Test canary — kernel_main witness block

### 4.1 Witness shape

The user brief's AC:

- task_new(NULL) → parent
- task_new(parent) → child
- Simulate child running (set state = RUNNABLE via direct write, since
  task_new leaves state = NEW and we want the child in an
  observable pre-exit state)
- Call sys_exit_body(child, 42)
- Verify child->state == ZOMBIE (3)
- Verify child->exit_status == 42
- Since parent is NEW (not WAITING), no reap side effect
- Verify parent->state still == NEW (0)
- Verify parent->wait_result_pid still == 0 (unset)

**Extended for coverage** — also test the WAITING-parent wakeup path:

- task_new(NULL) → parent2 (fresh)
- Set parent2->state = STATE_WAITING (2)
- task_new(parent2) → child2
- Call sys_exit_body(child2, 99)
- Verify child2->state == ZOMBIE, child2->exit_status == 99
- Verify parent2->state == RUNNABLE (1) — was 2, now 1
- Verify parent2->wait_result_pid == child2->pid
- Verify parent2->wait_result_status == 99

Both sub-tests emit a single joint marker `R15 SYS EXIT OK\n`
on success. A single-witness with both paths is what the AC
"exit propagates status to parent via wait" needs to be
plausibly verified end-to-end.

### 4.2 Witness storage

No new `.bss` blob — the witness reuses `_task_pool` and
`_pid_table` via `task_new`. Tasks constructed:

| Slot | Pid     | Role                          |
|------|---------|-------------------------------|
| 4    | 4       | parent (non-WAITING) — sub-test 1 |
| 5    | 5       | child (of parent 4) — sub-test 1  |
| 6    | 6       | parent2 (WAITING) — sub-test 2    |
| 7    | 7       | child2 (of parent2 6) — sub-test 2 |

Pids 1/2/3 are already held by the #548/#551 witnesses. The
witness allocator (`pid_alloc`) picks 4-7 next. No teardown
between witnesses (task_free not invoked here); slots stay
occupied until end-of-boot.

**MAX_PIDS budget.** `_task_pool` holds 64 slots. Post-witness
occupancy: 7 slots. Well within budget. R15.M6-009 fork/exec/wait
smoke will do the actual task_free stress test.

### 4.3 Witness assembly

The witness lives in `kernel_main.pdx` inside
`boot_continue_after_ring3`, immediately after `pool_witness_exit:`
(line 678) and before the GS_BASE setup (line 680).

```asm
; ============================================================
; R15-M6-006 (#557): sys_exit witness — 2 sub-tests, 1 marker
; ============================================================
sys_exit_witness:
    ; ---------- Sub-test 1: non-WAITING parent, no reap ----------
    ; parent = task_new(NULL)
    xor rdi, rdi;
    call task_new;
    cmp rax, 0;
    je  sys_exit_witness_fail;
    mov r12, rax;                                ; r12 = parent (pid 4)

    ; child = task_new(parent)
    mov rdi, r12;
    call task_new;
    cmp rax, 0;
    je  sys_exit_witness_fail;
    mov r13, rax;                                ; r13 = child (pid 5)

    ; Set child->state = STATE_RUNNABLE (1) — simulate running
    ; Not strictly required (NEW→ZOMBIE is a legal transition
    ; per §3.4 — task_new default), but documents intent.
    mov rax, 1;
    mov [r13 + 8], eax;                          ; child->state = RUNNABLE

    ; sys_exit_body(child, 42)
    mov rdi, r13;
    mov rsi, 42;
    call sys_exit_body;

    ; Assert: child->state == STATE_ZOMBIE (3)
    mov eax, [r13 + 8];
    cmp rax, 3;
    jne sys_exit_witness_fail;

    ; Assert: child->exit_status == 42
    mov eax, [r13 + 12];
    cmp rax, 42;
    jne sys_exit_witness_fail;

    ; Assert: parent->state unchanged (NEW = 0)
    mov eax, [r12 + 8];
    cmp rax, 0;
    jne sys_exit_witness_fail;

    ; Assert: parent->wait_result_pid unchanged (0)
    mov eax, [r12 + 1704];
    cmp rax, 0;
    jne sys_exit_witness_fail;

    ; ---------- Sub-test 2: WAITING parent, reap wakeup ----------
    ; parent2 = task_new(NULL)
    xor rdi, rdi;
    call task_new;
    cmp rax, 0;
    je  sys_exit_witness_fail;
    mov r12, rax;                                ; r12 = parent2 (pid 6)

    ; Set parent2->state = STATE_WAITING (2) — simulate parked in sys_wait
    mov rax, 2;
    mov [r12 + 8], eax;

    ; child2 = task_new(parent2)
    mov rdi, r12;
    call task_new;
    cmp rax, 0;
    je  sys_exit_witness_fail;
    mov r13, rax;                                ; r13 = child2 (pid 7)

    ; sys_exit_body(child2, 99)
    mov rdi, r13;
    mov rsi, 99;
    call sys_exit_body;

    ; Assert: child2->state == STATE_ZOMBIE
    mov eax, [r13 + 8];
    cmp rax, 3;
    jne sys_exit_witness_fail;

    ; Assert: child2->exit_status == 99
    mov eax, [r13 + 12];
    cmp rax, 99;
    jne sys_exit_witness_fail;

    ; Assert: parent2->state == STATE_RUNNABLE (1) — was 2, wakeup transition
    mov eax, [r12 + 8];
    cmp rax, 1;
    jne sys_exit_witness_fail;

    ; Assert: parent2->wait_result_pid == child2->pid (7)
    mov eax, [r13 + 0];                          ; child2->pid
    mov ecx, [r12 + 1704];                       ; parent2->wait_result_pid
    cmp rax, rcx;
    jne sys_exit_witness_fail;

    ; Assert: parent2->wait_result_status == 99
    mov eax, [r12 + 1708];
    cmp rax, 99;
    jne sys_exit_witness_fail;

    ; ---------- All checks green ----------
    lea rdi, [rip + sys_exit_witness_ok_msg];
    call uart_puts;
    jmp sys_exit_witness_exit;

sys_exit_witness_fail:
    lea rdi, [rip + sys_exit_witness_fail_msg];
    call uart_puts;

sys_exit_witness_exit:
```

**Rodata strings (added to `tools/boot_stub.S`):**

```
# R15-M6-006 (#557): sys_exit witness success message
.global sys_exit_witness_ok_msg
.align 8
sys_exit_witness_ok_msg: .ascii "R15 SYS EXIT OK\n\0"

# R15-M6-006 (#557): sys_exit witness failure message
.global sys_exit_witness_fail_msg
.align 8
sys_exit_witness_fail_msg: .ascii "R15 SYS EXIT FAIL\n\0"
```

### 4.4 What the eleven assertions prove

Sub-test 1 (non-WAITING parent — no reap):

1. **child->state == ZOMBIE.** Step 1 of the body ran; the u32
   store at [rdi + 8] wrote 3.
2. **child->exit_status == 42.** Step 2 ran; [rdi + 12] wrote
   the low 32 bits of rsi.
3. **parent->state unchanged (NEW).** Step 5 guard triggered
   (parent->state was 0, not 2) — no wakeup store.
4. **parent->wait_result_pid unchanged (0).** Step 6 skipped.

Together these prove the zombie-set path is idempotent and the
non-WAITING guard prevents cross-slab writes.

Sub-test 2 (WAITING parent — reap wakeup):

5. **child2->state == ZOMBIE.** Step 1 ran (independently of
   parent state).
6. **child2->exit_status == 99.** Step 2 ran.
7. **parent2->state == RUNNABLE.** Step 6 executed the state
   transition (was 2 → now 1).
8. **parent2->wait_result_pid == child2->pid.** The wakeup
   stored the child's pid correctly.
9. **parent2->wait_result_status == 99.** The wakeup stored
   the child's exit_status correctly.

Together these prove the wakeup path executes when the parent is
WAITING and propagates both data fields plus the state
transition.

Combined: 9 field-level assertions on 4 tasks. Covers
zombie-set, non-WAITING skip, WAITING wakeup, and inter-field
consistency (wait_result_pid matches actual child pid).

### 4.5 Fingerprint additions

Marker line appended to three fingerprint files (contains-in-order):

`tests/r15/expected-boot-r15-process.txt`:

```diff
 R15 FD TABLE OK
 R15 TASK NEW OK
 TASK pool ok pids=1,2,3
+R15 SYS EXIT OK
 IPI OK
```

`tests/r15/expected-boot-r15-ring3.txt`:

```diff
 R15 FD TABLE OK
 R15 TASK NEW OK
+R15 SYS EXIT OK
 IPI OK
```

`tests/r14b/expected-boot-r14b-loader.txt`:

```diff
 R15 FD TABLE OK
 R15 TASK NEW OK
+R15 SYS EXIT OK
 LOADER OK
```

The other 5 fingerprint files (`boot_r8_only`, `boot_r10`,
`boot_r11`, `boot_r12`, `boot_r12_denial`) do **not** need
editing — their scope is pre-R15 substrate; the extra line
post-dates their fingerprint window and contains-in-order matching
stays byte-identically green.

**Ordering vs. r15-m6-008 frame_meta.** `R15 FRAME META OK`
already lands at line 5 of expected-boot-r15-process.txt (per
current file). `R15 SYS EXIT OK` slots after `TASK pool ok
pids=1,2,3` (line 12) because sys_exit's witness runs after
pool_witness_exit in kernel_main (line 678).

### 4.6 What the witness does NOT test (deferred)

- **Syscall wrapper.** The `sys_exit` wrapper (dispatch entry
  from ring 3) still prints `[exit]` and halts. Testing the
  wrapper requires cpu_local_current_task lookup — deferred to
  the sys_wait wire-up (#556).
- **Scheduler transition.** After sys_exit_body, the caller
  (real userspace) must not resume. The witness doesn't invoke
  the scheduler — the caller (kernel boot code) just returns
  from the witness and continues. This is not a bug; the
  witness is a fixture, not a real syscall.
- **kind_reply cap wakeup.** Not modeled at R15.M6; §6.2 backtrack B.
- **Reparent-to-init interaction.** #558 not landed; the
  witness constructs tasks with real parent_pid pointers, so
  the parent gone → orphan branch (step 4) is not exercised. A
  future integration witness after #558 could construct A → B,
  free A, then have B call sys_exit — verifies step 4's
  `parent == 0` guard.
- **Reap (pool teardown).** Zombie retention at end-of-boot is
  acceptable at the fixture level; R15.M6-009 fork/exec/wait
  smoke runs the full round-trip with real reap.
- **Concurrent sys_exit.** Two children exiting simultaneously
  is an SMP concern; single-CPU R15.M6 has no such race.

## 5. LOC estimate

| File                                                              | LOC delta |
|-------------------------------------------------------------------|-----------|
| `src/kernel/core/syscall/handlers/sys_exit.pdx` (NEW)             | +50       |
| `src/kernel/boot/kernel_main.pdx` (witness block)                 | +75       |
| `tools/boot_stub.S` (2 rodata strings)                            | +8        |
| `tests/r15/expected-boot-r15-process.txt`                         | +1        |
| `tests/r15/expected-boot-r15-ring3.txt`                           | +1        |
| `tests/r14b/expected-boot-r14b-loader.txt`                        | +1        |
| `design/kernel/r15-m6-006-sys-exit.md` (this doc)                 | +600      |
| **Total**                                                         | **~736**  |

Executable code: ~20 asm lines + ~15 constants/scaffolding in
`sys_exit.pdx` = ~50 LOC. Witness: ~65 asm lines + ~5 rodata refs
= ~75 LOC in `kernel_main.pdx`. Boot_stub rodata: ~8 LOC.
Fingerprint: ~3 LOC. Design: ~600 LOC.

Same order of magnitude as #548 (~667 LOC total) and #550
(~657 LOC total). Well within R15.M6 per-issue budget.

## 6. Backtrack candidates

Ordered by preference.

### 6.1 Backtrack A — Land sys_exit wrapper with the body

Rather than splitting `sys_exit_body` out and leaving the
`dispatch.pdx` wrapper at its `[exit]` + hlt stub, implement the
full wrapper this issue:

```
sys_exit(status):
    current = cpu_local_get()->current_task
    sys_exit_body(current, status)
    call sched_pick_next        // never returns
```

**Consequence.** Requires:
- `cpu_local_get()->current_task` accessor (~10 LOC in
  `cpu/local.pdx`)
- `sched_pick_next()` at the R15.M6 altitude (not the R11 TCB
  scheduler — a new dispatcher over `_pid_table` for
  runnable tasks). This is a substantial R15.M6-001 landing
  that hasn't happened yet.

Net: couples this issue's landing to two currently-absent
primitives. Defeats independent testability.

**Reject as primary.** Retain as backtrack if #556 (sys_wait)
lands with both accessors as side-effect. In that case, this
issue's dispatch.pdx edit is a 5-line replacement of the
`[exit]`+hlt stub, no other churn.

### 6.2 Backtrack B — kind_reply cap wakeup instead of state polling

Instead of `parent->state = RUNNABLE`, invoke a kind_reply
capability that the parent is parked on (via `sys_wait` → cap
receive). Signal-side:

```
parent_reply_cap = current->parent->wait_reply_slot   ; cap handle
kind_reply_send(parent_reply_cap, {pid: current->pid, status: status})
```

**Consequence.** Requires a live kind_reply substrate (partially
in `src/kernel/core/reply/` but not yet wired to task_struct);
requires the parent to have minted a reply cap before sys_wait
returns from ring 3 to kernel; requires the kind_reply queue to
be drained on the parent's post-wakeup path. Substantial
plumbing for R15.M6.

**Recommend as SMP-safety promotion at R15.M7 or R16.M1.** The
kind_reply model is the tactical plan's stated end-state
(§Subsystem 9 A). At R15.M6 single-CPU, state polling is
functionally equivalent and 10× simpler. The switch is a
one-line edit in step 6 (replace `parent->state = RUNNABLE`
with `kind_reply_send(parent_reply_cap, ...)`) once the
substrate is ready.

### 6.3 Backtrack C — Free current inside sys_exit (atomic teardown)

Follow R15.M5's `task_free` model — sys_exit does everything:
fds released, aspace torn down, slab zeroed, pid freed. Parent's
sys_wait consumes exit_status from a side-table `_zombie_exit_status[MAX_PIDS]`.

**Consequence.** Copy the exit_status into the side table
BEFORE task_free zeroes the slab:

```
_zombie_exit_status[current->pid] = status
task_free(current)
if parent->state == WAITING:
    parent->wait_result = {pid: <saved>, status: <saved>}
    parent->state = RUNNABLE
```

At sys_wait time, the parent reads from `_zombie_exit_status`
instead of from `child->exit_status` (child slab is gone).

**Reject.** Explicitly named by task-free doc §6.5 as "R15.M6
concern"; tactical plan §Subsystem 9 A explicitly states
"exit_status is stored in `zombie_slot[pid]`; parent's wait
consumes" — but on closer reading, `zombie_slot[pid]` is
ambiguous between "the slab still labeled zombie" (this design)
and "a separate side table" (backtrack C). This design's
in-slab approach is Pareto-simpler:
- No new global array; `child->exit_status` at offset 12 is
  the canonical location.
- Parent's sys_wait can scan `_pid_table` for children AND
  simultaneously read their exit_status (single memory region).
- task_free stays symmetric with task_new (task_free = inverse
  of task_new, called by parent AFTER reading exit_status).

The side-table variant is a valid engineering choice at R16+
when zombie retention grows (posix says a parent can wait on a
zombie's exit_status for arbitrarily long; if _pid_table is a
scarce 64 slots, we may run out with many zombies). At R15.M6
64 slots is Pareto-adequate.

### 6.4 Backtrack D — Explicit sfence before parent->state store

At R15.M6 single-CPU, x86's TSO gives us store ordering for
free. On SMP, a concurrent parent-CPU that races the child's
sys_exit could observe `parent->state = RUNNABLE` (LoadStore
reorder happens on some µarch — but not x86 TSO) BEFORE seeing
the two data stores.

x86 TSO guarantees: stores from a single CPU are seen in
program order by all other CPUs. So step 6's ordering
(pid → status → state) is guaranteed by the ISA at R15.M6
single-CPU AND at R15.M7 SMP (assuming both CPUs are x86-64,
which they are on our target hardware).

**Consequence of adopting anyway.** Add `sfence` before the
`parent->state = RUNNABLE` store. One extra instruction,
~5 cycles. Adds no correctness (TSO already guarantees it).

**Reject.** Documenting the TSO reliance in the justification
string is enough. If we ever port to Aarch64 (weaker memory
model), sfence promotes to `dmb ish` (ARM equivalent) and the
one-line edit is in the same location.

### 6.5 Backtrack E — Keep 5-state enum from fd-table doc §3.1

Adopt (NEW=0, RUNNABLE=1, RUNNING=2, BLOCKED=3, ZOMBIE=4)
instead of this doc's 4-state. Add a distinct `STATE_RUNNING`
that indicates the currently-executing task (as opposed to
merely-runnable-in-queue).

**Consequence.** sys_exit_body writes ZOMBIE=4 (not 3). Every
transition doc and witness updates the constants. `STATE_RUNNING`
becomes a stored field — but nothing needs it because the
running task is identified by `cpu_local_get()` on any CPU, not
by inspecting task_struct.state. So RUNNING is a *label* with no
scheduler consumer, and the enum grows without functional need.

**Reject.** The 4-state enum this doc pins is the smallest
correct set for R15.M6 sys_exit + sys_wait. If a future
scheduler primitive needs to distinguish RUNNING from RUNNABLE
(e.g., migration policies that skip currently-running tasks),
extend the enum then — the compare-imm sites in sys_exit
(`cmp rax, 2` and `cmp rax, 1`) don't collide with any
higher-numbered variant.

### 6.6 Backtrack F — Body inline in dispatch.pdx (no new module)

Instead of `src/kernel/core/syscall/handlers/sys_exit.pdx`,
inline the body inside `dispatch.pdx` as a new `pub let
sys_exit_body`, keeping the wrapper's `sys_exit` next to it.

**Consequence.** No new directory; smaller diff. But
`dispatch.pdx` is already 140 LOC of dispatch logic; adding
another 50 LOC of body dilutes it. Also breaks the tactical
plan §Subsystem 9 issue 6 pattern (touching:
`src/kernel/core/syscall/handlers/sys_exit.pdx`) which points at
a per-syscall-handler module organization.

**Reject.** The tactical plan explicitly names the file path
`handlers/sys_exit.pdx`; adopting it now sets up sys_fork,
sys_execve, sys_wait to land in sibling files without a
directory-refactor commit.

### 6.7 Backtrack G — Preserve exit_status separately from task_struct.exit_status

At R15.M5 task-free doc §6.5 flagged an "exit_status side-table
`_zombie_exit_status[MAX_PIDS]`". This backtrack revives that
idea WITHOUT the atomic-teardown of §6.3 — just a mirror. Store
exit_status BOTH in child slab @ 12 AND in a global u32 array
by pid.

**Consequence.** Two write sites (child slab + array); parent
sys_wait can look up by pid without dereferencing the slab.
Advantages: fewer memory reads at sys_wait time; failure
isolation if the child slab gets stomped by a bug.

**Neutral.** Costs 4 bytes × 64 = 256 bytes of `.bss` and one
extra u32 store per sys_exit. Buys defensive redundancy but no
correctness. Retained as follow-up if debugger sessions find a
class of "exit_status stomped" bugs; add then.

## 7. Tractability

**HIGH.**

- No new paideia-as encoder gap — all mnemonics audited via
  #548, #549, #550's precedent bodies. `mov [r8 + disp32], r32`
  and `mov r32, [r8 + disp32]` are the only near-new patterns
  (offsets 1704, 1708 exceed disp8 range) and they lower via
  standard REX.B + ModRM + disp32 which paideia-as already
  emits for large-offset accesses (`kpti.pdx:246`, various
  `_kernel_pml4_pa` reads).
- No new IDT / GDT / TSS / CR3 / MSR discipline. Leaf function;
  no interrupt manipulation.
- New directory `src/kernel/core/syscall/handlers/` — precedent
  is `src/kernel/core/fs/` (created by #549); no `kernel_build.sh`
  edit required (build discovers `.pdx` files by directory
  walk).
- ~20 asm LOC of body + ~65 asm LOC of witness. Same tempo as
  #548's ~90 LOC of witness, #550's ~50 LOC of witness.
- Register discipline is *trivially* correct — zero nested
  calls, all caller-save regs used. The endemic bug class
  (register clobber across nested calls) is unreachable in
  this body.
- Witness driver is real: `task_new` (#548) is LANDED,
  `_pid_table` is LANDED. The witness pins down real behavior,
  not a mock.
- Marker line is contains-in-order across three fingerprint
  files, none of which is broken by an extra line (all use
  contains-in-order matching per boot smoke discipline).

Known follow-ups (not blockers for #557):

- **R15.M6-001 sched_enqueue** — provides sched_pick_next for
  the syscall wrapper.
- **R15.M6-005 sys_wait (#556)** — the primary consumer of the
  4-state enum + wait_result_* fields this doc pins.
- **R15.M6-007 orphan reparent (#558)** — must run in
  task_free before sys_exit's step 4 guard becomes reachable
  in normal ops.
- **Syscall wrapper wire-up** — replace the `[exit]`+hlt stub
  in `dispatch.pdx:127` with `call sys_exit_body` + scheduler
  transition. Lives with whichever issue exposes
  cpu_local_current_task first.
- **R15.M6-009 fork/exec/wait smoke** — end-to-end validation
  that this doc's design shape holds up under
  fork → child_exit → parent_wait.

## 8. Cross-cutting risks

- **AC "fds released" interpretation.** The issue AC lists
  "fds released" alongside "exit propagates status to parent
  via wait". This doc's interpretation: fd release happens at
  `task_free` time (parent's sys_wait return path), NOT at
  sys_exit time. Rationale (§ Scope out-of-scope point 2): at
  R15.M5 fds are opaque u64 with no vnode refcount, so leaving
  them populated in a zombie is harmless; at R16.M3 when
  slots grow to fd_entry with vnode refcounts, task_free's
  fd_close_all loop decrements them. sys_exit calling
  fd_close_all NOW would either be a no-op (R15.M5) or would
  double-free vnode refcounts (R16.M3 if sys_wait's task_free
  also tried). Mitigation: this doc pins the "fd release at
  reap, not at exit" invariant. If a maintainer reads the AC
  as "fds close at sys_exit", they must edit both this doc and
  #556 (sys_wait) to reflect the split.
- **State enum discrepancy with #549 fd-table doc §3.1.**
  fd-table doc named 5 states with ZOMBIE=4. This doc pins 4
  states with ZOMBIE=3. Mitigation: §3.1 discrepancy table
  explicit. #543 layout-freeze doc must adopt this doc's
  freeze OR file a re-freeze issue. task_new witness at
  kernel_main.pdx:604 uses `cmp rax, 0` for NEW check — no
  hard-coded reference to ZOMBIE=3/4 — so no cascade break
  from adopting this doc's enum.
- **Field rename discrepancy with #549 fd-table doc §3.1.**
  fd-table doc named 1704 `wait_child_pid` and 1708
  `wait_reply_slot`. This doc renames to `wait_result_pid` /
  `wait_result_status`. No code currently references either
  name — the fields are pure design pins. Mitigation: this
  doc §3.1 records the rename; #543 adopts.
- **sys_exit_body called BEFORE any task_new witness has
  populated pid_table.** Won't happen: witness ordering places
  sys_exit_witness AFTER pool_witness_exit; pids 1-3 are
  live before sys_exit_witness runs. But if a future edit
  reorders the witness suite, the sys_exit body defensively
  handles `_pid_table[parent_pid] == 0` (step 4 guard) so no
  panic on that path — just skips the wakeup.
- **Parent slab overwrite race.** If a future parallel edit
  makes sys_exit run under IRQs enabled AND an interrupt
  handler re-enters sys_exit for a different task on a
  shared CPU (impossible at R15.M6 single-CPU), the two
  bodies could race on parent slab writes. Mitigation:
  document that sys_exit_body must run with IRQs disabled;
  R15.M6 single-CPU makes this vacuous. R15.M7 SMP needs a
  per-task lock OR the kind_reply cap wakeup (§6.2). Flagged
  in the justification string.
- **Callee-save clobber in task_new (used by witness).**
  task_new is LANDED at commit involving `f6195ed` /
  `3e6a550` register-discipline fixes. The witness uses r12
  and r13 to hold parent and child slab pointers across
  task_new calls. task_new's 3-push prologue preserves
  rbx/r12/r13. Mitigation: this is settled infrastructure;
  no risk introduced by this issue's witness.
- **Fingerprint drift.** Adding "R15 SYS EXIT OK" to three
  files must land in the same commit as the code. Missing
  any → smoke false negative. Mitigation: pre-push hook
  blocks pushes that fail smoke (per
  `feedback_paideia_os_no_cicd`); drift caught locally.
- **`sys_exit_body` return semantics vs. `sys_exit` never-return.**
  The tactical plan §Subsystem 9 declares `sys_exit : (status:
  i32) -> !` (never returns). `sys_exit_body` returns () — it's
  a helper. The wrapper (deferred) is what implements the `!`
  semantic via `sched_pick_next`. Mitigation: naming split
  (`_body` suffix) makes the distinction explicit.
- **Compact pid↔slab mapping (§3.9 of #548).** This body relies
  on `_pid_table[parent_pid]` returning `&_task_pool[parent_pid
  - 1]`. That invariant is pinned by #548 §3.9 / #550 §3.6.
  Mitigation: if a future edit breaks the compact mapping
  (e.g., for pid > 64 space), this body's step 4 still works
  as long as `_pid_table[pid]` continues to be the canonical
  slab lookup — which is the invariant the mapping was
  designed to preserve.

## 9. Backtrack markers

For the debugger-agent if the witness reports FAIL:

| Symptom                                        | Root cause hypothesis                                | Where to look                                              |
|------------------------------------------------|------------------------------------------------------|------------------------------------------------------------|
| Sub-test 1 fails, child->state != 3            | Step 1 store missed or wrong offset                   | `mov [rdi + 8], eax` — verify offset 8 and value 3         |
| Sub-test 1 fails, child->exit_status != 42     | Step 2 store missed or wrong reg                      | `mov [rdi + 12], esi` — verify offset 12 and low-32 of rsi |
| Sub-test 1 fails, parent->state != 0           | Step 5 guard didn't trigger, step 6 ran erroneously   | `cmp rax, 2; jne sys_exit_done` — check parent->state read |
| Sub-test 2 fails, parent2->state != 1          | Step 6 state store missed OR ran but wrong value      | `mov rax, 1; mov [r8 + 8], eax` — verify STATE_RUNNABLE=1  |
| Sub-test 2 fails, wait_result_pid != child.pid | Step 6 pid store used wrong source or wrong offset    | `mov eax, [rdi + 0]; mov [r8 + 1704], eax` — verify 1704   |
| Sub-test 2 fails, wait_result_status != 99     | Step 6 status store missed (rsi clobbered?)          | `mov [r8 + 1708], esi` — verify rsi was preserved          |
| Silent hang, no OK/FAIL                        | task_new returned 0 (pid exhaustion) OR body clobbered rip | Check pool occupancy (should be 3 before witness; 7 after) |
| Fingerprint mismatch, R15 SYS EXIT OK missing  | Marker not emitted; either sub-test failed silently OR uart_puts didn't flush | Check jmp targets around sys_exit_witness_exit             |
| Fingerprint mismatch, extra line before marker | Wrong witness block ordering                          | Verify witness sits after pool_witness_exit (line 678)     |

## 10. References

- Issue: paideia-os#557
- Milestone: paideia-os milestones/62 (R15.M6 fork / exec / wait / _exit)
- Sibling issues in R15.M6:
  - #552 (aspace_clone_cow), #553 (pf_handler_cow_split)
  - #554 (sys_fork), #555 (sys_execve), #556 (sys_wait — primary consumer of this doc's freeze)
  - #558 (orphan adoption), #559 (frame_meta refcount — LANDED)
  - #560 (fork/exec/wait smoke)
- Landed prereqs:
  - #548 task_new (`src/kernel/core/sched/task_pool.pdx:71`) — parent/child construction
  - #549 fd_table + task_struct field freeze (`src/kernel/core/fs/fd_table.pdx`)
  - #550 task_free (`src/kernel/core/sched/task_pool.pdx`, wraps aspace_teardown + pid_free)
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 9 issue 6 (line 1051), state machine (lines 908, 1012),
  interfaces (line 1003)
- Master plan: `design/milestones/r14b-master-plan.md`
  §R15.M6 fork/exec/wait/_exit
- Prior-art register-discipline post-mortems:
  - `f6195ed` (phys_alloc callee-save fix)
  - `3e6a550` (self-IPI callee-save audit)
- Prior-art witness pattern:
  - `design/kernel/r15-m5-006-task-new-real.md` §4 (single-call witness with post-condition asserts)
  - `design/kernel/r15-m5-008-task-free-real.md` §4 (multi-iteration loop with pool round-trip)
- Prior-art fingerprint discipline:
  - `design/kernel/r15-m5-007-fd-table-embed.md` §4.3 (contains-in-order marker addition)
- Prior-art rodata addition to boot_stub.S:
  - `tools/boot_stub.S:355-372` (task_new / pool witness msgs)
- paideia-as encoder audits:
  - `tools/paideia-as/tests/build-emit/mov_mem_imm_sib_disp.pdx` (SIB+disp32 store)
  - `tools/paideia-as/tests/build-emit/mov_mem_imm_sib.pdx` (SIB+scale-8 imm store)
