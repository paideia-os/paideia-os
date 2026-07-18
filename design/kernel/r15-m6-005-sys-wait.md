---
issue: 556
milestone: R15.M6 (fork / exec / wait / _exit)
subsystem: 9 — fork / exec / wait / _exit
prereq:
  - "#548 (task_new real — LANDED at src/kernel/core/sched/task_pool.pdx; provides parent+child construction the witness drives)"
  - "#549 (fd_table embed — LANDED; pins task_struct offsets 0/4/8/12/16 that sys_wait reads/writes)"
  - "#545 (pid_alloc / pid_free — LANDED; pid_free is the minimal reap primitive this body invokes)"
  - "R15.M6-006 / #557 (sys_exit real body — LANDED at src/kernel/core/syscall/handlers/sys_exit.pdx; pins the STATE_ZOMBIE=3 / STATE_WAITING=2 / STATE_RUNNABLE=1 enum and the wait_result_pid/wait_result_status fields at offsets 1704/1708)"
blocks:
  - "R15.M6-009 / #560 (fork/exec/wait smoke — the fingerprint 'WAIT: pid=child status=N' proves sys_exit + sys_wait round-trip)"
touching:
  - src/kernel/core/syscall/handlers/sys_wait.pdx           (NEW module)
  - src/kernel/boot/kernel_main.pdx                         (witness block, ~110 LOC)
  - tools/boot_stub.S                                       (2 rodata strings)
  - tests/r15/expected-boot-r15-process.txt                 (marker line, contains-in-order)
  - tests/r15/expected-boot-r15-ring3.txt                   (marker line, contains-in-order)
  - tests/r14b/expected-boot-r14b-loader.txt                (marker line, contains-in-order)
  - design/kernel/r15-m6-005-sys-wait.md                    (this doc)
related:
  - design/kernel/r15-m6-006-sys-exit.md                    (source of truth for state enum + wait_result_* field offsets; this doc consumes the freeze)
  - design/kernel/r15-m5-006-task-new-real.md               (task_struct layout — pid @ 0, parent_pid @ 4, state @ 8, exit_status @ 12)
  - design/kernel/r15-m5-008-task-free-real.md              (NOT LANDED — task_free body is still open; this doc explicitly declines to call it and picks a minimal reap instead)
  - design/milestones/r14b-tactical-plan.md                 (§Subsystem 9 issue 5, line 1046; state machine line 908 + 1012)
---

# R15-M6-005 — sys_wait real body: scan zombie children, reap, park on WAITING (#556)

## 1. Scope

Give `sys_wait` a real, testable body so that:

1. `sys_wait_body(current)` scans `_pid_table` for a task with
   `parent_pid == current->pid` and `state == STATE_ZOMBIE (3)`.
2. If a zombie child is found:
   - Read the child's `pid` (u32 @ 0).
   - Read the child's `exit_status` (u32 @ 12).
   - **Reap (minimal):** call `pid_free(child_pid)` — zeroes
     `_pid_table[child_pid]`, freeing the pid slot for future
     allocation. The child task_struct slab bytes stay in place
     inside `_task_pool` (temporary leak accepted; see §3.7).
   - Return `{child_pid, exit_status}` via `{rax, rdx}`.
3. If no zombie child is found but the scan saw at least one task
   with `parent_pid == current->pid` (child in some non-ZOMBIE
   state — NEW / RUNNABLE / WAITING):
   - Set `current->state = STATE_WAITING (2)`.
   - Return `rax = 0` (the "would block" signal to the syscall
     wrapper, which yields to the scheduler).
4. If the scan saw NO task with `parent_pid == current->pid`
   (parent has no children at all):
   - Return `rax = -ECHILD = -10 = 0xFFFFFFFFFFFFFFF6` (u64
     signed-negative).
   - Do NOT set state = WAITING; the parent is not blocked, it
     just called wait with no candidates.

Two invariants define completion:

- **Reap freshness.** After `sys_wait_body(t)` returns
  `{child_pid, exit_status}` on the sync path, the tuple
  `(child_pid, exit_status)` reflects the child's `sys_exit`
  arguments unmodified, AND `_pid_table[child_pid] == 0` so a
  subsequent `pid_alloc` can reuse the slot.
- **WAITING transition atomicity (single-CPU).** The store
  `current->state = STATE_WAITING` executes only on the no-zombie /
  have-children branch, and only if reached. Interrupts are trusted
  disabled at R15.M6 single-CPU; the wrapper is trusted to yield
  immediately after the body returns (see §3.2 split).

Explicitly out of scope (deferred):

- **Syscall wrapper wiring.** The current `sys_exit` slot in
  `src/kernel/core/syscall/dispatch.pdx:127` prints `[exit]` and
  halts; the `sys_wait4` slot at `dispatch.pdx:50` returns ENOSYS
  (no dispatch label yet, just a `je dispatch_enosys`). This doc
  lands the *body* (`sys_wait_body`) as a leaf function testable
  without a real syscall entry. The wrapper (`sys_wait4`) that
  reads `current` from cpu_local (via `cpu_local_get`), calls
  `sys_wait_body(current)`, checks return, either returns the
  result to userspace OR (rax == 0) invokes the scheduler to
  yield — that wire-up is a downstream edit paired with the
  R15.M6-001 scheduler landing (`sched_pick_next`) or a follow-up.
  The dispatch.pdx entry stays at ENOSYS until that edit lands.
- **Full task_free.** The tactical plan / R15.M5-008 doc envisions
  `task_free(child)` as the reap step, which would tear down the
  child's aspace + fd table + slab in addition to releasing the
  pid. That body is NOT LANDED (#550 still open). This doc
  explicitly declines to call task_free and adopts the minimal
  reap (`pid_free` only). Consequence: the child slab bytes and
  the user aspace stay allocated until a future edit adds
  task_free. §3.7 discusses the leak budget; §6.1 backtrack A
  is the promotion path once #550 lands.
- **Blocking / scheduler transition.** The no-zombie / have-children
  branch sets state = WAITING and returns rax = 0. The actual
  "yield to scheduler and later resume" is the wrapper's concern.
  The wrapper (deferred) invokes `sched_pick_next` and, on resume,
  reads `current->wait_result_pid` / `wait_result_status` (written
  by the child's `sys_exit_body` per #557 §3.3 step 6) to compute
  its return to userspace. The body here does NOT read
  wait_result_* — those fields are the *async* wakeup mailbox,
  consumed by the wrapper, not by the body.
- **kind_reply / capability-based wakeup.** Same rationale as
  #557 §Scope — R15.M6 single-CPU uses state polling; the
  kind_reply cap wakeup is a future SMP-safety promotion.
- **Multi-child priority / ordering.** POSIX allows wait4 to
  return any zombie child. This body uses the natural low-pid-first
  order from the linear scan over `_pid_table`. If a caller wants
  "wait for specific pid" (waitpid semantics), that's a superset
  operation added later.
- **-ECHILD vs. would-block distinction under SMP.** Single-CPU
  R15.M6 makes this trivially safe; a future SMP promotion needs
  atomicity between the "am I a parent?" check and the child's
  concurrent exit.

## 2. Prereq check

### 2.1 What's in place

| Primitive                    | Location                                        | Contract used by sys_wait_body                       |
|------------------------------|-------------------------------------------------|------------------------------------------------------|
| `task_struct.pid @ 0`        | `#549 §3.1 layout freeze`                       | u32, read as target parent_pid (current->pid)        |
| `task_struct.parent_pid @ 4` | `#549 §3.1 layout freeze`                       | u32, read on each candidate slab in scan             |
| `task_struct.state @ 8`      | `#549 §3.1 layout freeze` / `#557 §3.4 enum`    | u32, read (candidate), written STATE_WAITING (self)  |
| `task_struct.exit_status @ 12` | `#549 §3.1 layout freeze` / `#557 §3.3 step 2`| u32, read from zombie child                          |
| `_pid_table[pid]`            | `core/sched/task_pool.pdx:21`                   | u64 slab pointer, indexed by pid (SIB scale-8)       |
| `pid_free(pid)`              | `core/sched/task_pool.pdx:56`                   | Two-instruction primitive: zeroes _pid_table[pid]    |
| `task_new(parent)`           | `core/sched/task_pool.pdx:71`                   | Constructs parent + child slabs the witness drives   |
| STATE_ZOMBIE = 3             | `#557 §3.4 enum freeze`                         | Match target in scan                                 |
| STATE_WAITING = 2            | `#557 §3.4 enum freeze`                         | Self-transition target when no zombie found          |

### 2.2 What is not in place — required prerequisites this doc consumes on faith

- **task_free (#550) not landed.** By design (§Scope): this body
  uses `pid_free` only, not `task_free`. When #550 lands, §6.1
  backtrack A promotes the reap to full teardown.
- **cpu_local `current_task()` accessor** — needed by the syscall
  wrapper `sys_wait4`, NOT by `sys_wait_body`. Same split as
  #557 §2.2 point 2.
- **Scheduler `sched_pick_next`** — needed by the wrapper on the
  block path. Not by the body.

### 2.3 Encoder gaps

**None.** The sys_wait_body uses only:

- Register-to-register `mov`, `xor`, `cmp` — audited substrate
- `mov r32, [reg + disp8]` — audited by fd_table SIB+disp,
  sys_exit body
- `mov [reg + disp8], r32` — audited by fd_table stores,
  sys_exit body
- `mov r64, [reg + reg*8]` — SIB scale-8 pid_table load, audited
  by task_pool.pdx:37 and sys_exit body
- `mov r12d, [rax + disp8]` — REX.R + 8B; audited by
  task_pool.pdx:112 pattern (`mov [r13+0], r12d` uses REX.R same
  class) and #557 body
- `cmp rdx, r8` (64-bit REX.WR) — audited by
  phys_alloc.pdx:50 (`cmp r9, r12`) and elf_lite.pdx:294
- `call` / `ret` — one nested call (`pid_free`), same class as
  task_new's 3 nested calls
- `push rbx / r12 / r13` — audited by task_new prologue
- `mov rax, imm64` — the `-ECHILD = 0xFFFFFFFFFFFFFFF6` constant;
  encodes via movabs (0x48 B8 + 8 bytes), audited by
  aspace_map.pdx:182 (`mov r9, 0xFFFF800000000000`)

## 3. Design

### 3.1 task_struct field consumption (R15.M6 addendum)

This body reads/writes fields already frozen by #549 (fd-table
embed) and #557 (sys_exit body):

```
Read (candidate slab in scan):
  offset   size   field         type   role
  ------   ----   -----------   ----   ------------------------------------
     4       4    parent_pid    u32    matched against current->pid target
     8       4    state         u32    compared to STATE_ZOMBIE (3)
     0       4    pid           u32    reap payload (returned via rax)
    12       4    exit_status   u32    reap payload (returned via rdx)

Read (current slab, once at entry):
     0       4    pid           u32    scan target for parent_pid match

Written (current slab, only on block path):
     8       4    state         u32    STATE_WAITING (2)
```

No new field pins. This doc consumes the #557 freeze verbatim.

**Note on wait_result_pid/wait_result_status.** #557 pins these
at offsets 1704 / 1708 as the *async* wakeup mailbox: child's
`sys_exit_body` writes them when parent is WAITING. This body
(sys_wait) does NOT read those fields, because the sync path
extracts pid/status directly from the child slab (found via
scan) and the async path returns to the caller (wrapper) with
rax = 0 — the wrapper is the wait_result_* consumer post-resume.
Splitting reader roles this way keeps the body a leaf function.

### 3.2 Function split — testable body + syscall wrapper

```
sys_wait_body : (u64) -> {u64, u64} !{mem} @{}
    Leaf function (one nested call: pid_free). Directly scans
    _pid_table, extracts data from a zombie child, calls pid_free
    to release the slot, returns {pid, status} via {rax, rdx}.
    Testable by the witness with an explicit `current` pointer
    — no scheduler, no cpu_local.

sys_wait4_wrapper : (pid: i64, status_out: u64, opts: u64) -> i64 !{mem, sysreg} @{sched}
    NOT LANDED THIS ISSUE. Downstream edit paired with
    sched_pick_next. Reads current = cpu_local_get()->current_task,
    calls sys_wait_body(current), branches:
      - rax == -ECHILD:  return -ECHILD to userspace.
      - rax == 0:  yield via sched_pick_next; on resume, read
                   current->wait_result_pid / _status; return
                   those (with status_out copied via u32 store).
      - rax > 0:   write status_out = rdx; return rax.
```

Why the split. Same rationale as #557 §3.2 — the user brief
requests "witness pattern, no real syscall wiring". Splitting
the leaf body from the wrapper achieves that in the smallest
diff — the body ships now, the wrapper edits `dispatch.pdx`
when the scheduler is ready.

### 3.3 Body sequence — five steps, one rationale

```
sys_wait_body(current):
  step 1   target_ppid = current->pid                    (u32 zero-ext load @ 0)
  step 2   saw_child   = 0                               (r9 scratch flag)
           for pid = 1..MAX_PIDS (64):
             cand = _pid_table[pid]                       (u64 load, SIB scale-8)
             if cand == 0: continue                       (empty slot)
             if cand->parent_pid != target_ppid: continue (not our child)
             saw_child = 1                                (note: at least one)
             if cand->state != STATE_ZOMBIE (3): continue (not reapable yet)
             goto step 3                                  (found — jump out of loop)
           // Fell off end of scan
           goto step 4

  step 3   // ZOMBIE FOUND. rax = child slab, rcx = child pid.
           child_pid    = cand->pid                       (u32 @ 0)     -> r12
           exit_status  = cand->exit_status               (u32 @ 12)    -> r13
           pid_free(child pid)                            (nested call)
           return {rax = child_pid, rdx = exit_status}

  step 4   // No zombie found. Distinguish two cases.
           if saw_child == 0:
             return {rax = -ECHILD, rdx = 0}              (no children)
           current->state = STATE_WAITING (2)              (u32 store @ 8)
           return {rax = 0, rdx = 0}                       (would block)
```

**Why this order.**

1. **Load target_ppid ONCE at entry (step 1).** The scan loop
   compares each candidate's `parent_pid` (u32 @ 4) to this
   target. Loading it once out of `current->pid` avoids repeated
   dereferences (aesthetic, not correctness). Held in a
   caller-save reg (r8d) for scan duration — safe because no
   nested call runs during scan.

2. **saw_child flag threaded through the scan (step 2).** The
   -ECHILD vs. would-block distinction requires knowing whether
   any candidate matched parent_pid, regardless of state. A single
   pass with a flag is Pareto-simpler than a two-pass "find
   zombie first, then rescan for any child" approach.

3. **Continue on empty pid_table slot.** Scan skips slots where
   `_pid_table[pid] == 0`. Those are unallocated pids — no task
   to inspect. Every allocated pid points to a live task_struct
   in `_task_pool` (per #548 §3.9 compact mapping).

4. **Continue on parent_pid mismatch BEFORE state check.** The
   parent_pid check is cheap (u32 load + cmp) and gates the more
   semantic state check. Also, this ordering means we set
   saw_child only for genuine children (not for tasks with
   `state == ZOMBIE` but different parent).

5. **Extract child_pid + exit_status BEFORE pid_free (step 3).**
   Critical ordering: once `pid_free(child)` zeros
   `_pid_table[child_pid]`, the slab pointer is gone. If we tried
   to read `child->exit_status` after pid_free, we'd need a
   separate copy anyway. Extracting into callee-save r12/r13
   *before* the call is the minimal-stores approach.

6. **pid_free is the ONLY nested call.** No task_free, no
   aspace_teardown, no fd_close_all. This is the deliberate
   minimal-reap contract. §3.7 documents the leak budget.

7. **Fall-through order at step 4.** The -ECHILD path is
   compact (single mov imm64 + xor). The WAITING path is
   compact (one store + xor). Ordering them "-ECHILD first
   then WAITING" makes the -ECHILD constant slightly closer to
   the check that gates it (cache-locality micro-optimization,
   not correctness).

### 3.4 State enum contract (consumed from #557 §3.4)

```
STATE_NEW      : u32 = 0    // freshly constructed by task_new
STATE_RUNNABLE : u32 = 1    // in runqueue OR currently executing
STATE_WAITING  : u32 = 2    // parked in sys_wait for a child's sys_exit
STATE_ZOMBIE   : u32 = 3    // sys_exit ran; parent has not yet reaped
```

Transitions this body performs / observes:

| From (self) | To (self)   | Trigger                        | Landing issue     |
|-------------|-------------|--------------------------------|-------------------|
| RUNNABLE    | WAITING     | sys_wait, no zombie child yet  | **this issue**    |
| (any)       | (unchanged) | sys_wait, zombie found         | **this issue**    |
| (any)       | (unchanged) | sys_wait, no children (ECHILD) | **this issue**    |

Observed on candidates:

| Observed state | Interpretation                        |
|----------------|---------------------------------------|
| ZOMBIE (3)     | Reap-eligible child; extract + reap   |
| any other      | Not reap-eligible; continue scan      |

### 3.5 File and module structure

```
src/kernel/core/syscall/handlers/sys_wait.pdx   <-- NEW module (this issue)
src/kernel/core/syscall/handlers/sys_exit.pdx   <-- exists (from #557)
```

Directory already created by #557. No layout / build-script edit
needed.

**Full module skeleton:**

```pdx
// src/kernel/core/syscall/handlers/sys_wait.pdx — R15-M6-005 (#556)
// wait4 body: scan _pid_table for zombie children of `current`,
// reap via pid_free, return {pid, status}. If no zombie but
// children exist: state → WAITING. If no children: -ECHILD.
//
// Issue #556 (R15.M6 subsystem 9 issue 5).

module SysWait = structure {
  // ==========================================================================
  // Constants — mirror #557 freeze
  // ==========================================================================
  pub let STATE_WAITING  : u32 = 2
  pub let STATE_ZOMBIE   : u32 = 3
  pub let MAX_PIDS       : u64 = 64
  pub let ECHILD_NEG     : u64 = 0xFFFFFFFFFFFFFFF6      // -10 (u64 two's-complement)

  // ==========================================================================
  // Field offsets — consumed from #549 / #557
  // ==========================================================================
  pub let TASK_OFF_PID                : u64 = 0
  pub let TASK_OFF_PARENT_PID         : u64 = 4
  pub let TASK_OFF_STATE              : u64 = 8
  pub let TASK_OFF_EXIT_STATUS        : u64 = 12

  // ==========================================================================
  // R15-M6-005 (#556): sys_wait_body — leaf body, testable without scheduler
  // ==========================================================================
  pub let sys_wait_body : (u64) -> u64 !{mem} @{} =
    fn (current: u64) -> unsafe {
      effects: {mem},
      capabilities: {},
      justification: "R15-M6-005 (#556): sys_wait body — testable leaf function (one nested call: pid_free; no cpu_local, no scheduler). Entry: rdi = current (*task, non-NULL). Prologue: 3-push (rbx, r12, r13) → 16-mod-0 alignment at pid_free call site. Body: (1) load target_ppid = current->pid (u32 zero-ext @ 0) into r8d. (2) scan _pid_table[1..64] via rcx loop: skip empty slots (cand==0), skip cand->parent_pid != target_ppid; on match, set saw_child (r9 = 1); if cand->state == ZOMBIE (3), go to step 3. (3) ZOMBIE FOUND: save child_pid = cand->pid (u32 @ 0) into r12d; save exit_status = cand->exit_status (u32 @ 12) into r13d; call pid_free(scan_idx) — releases _pid_table[child_pid]; return rax = child_pid, rdx = exit_status. (4) NO ZOMBIE: check saw_child; if zero, return rax = -ECHILD (0xFFFFFFFFFFFFFFF6); else write current->state = STATE_WAITING (2) and return rax = 0. Register discipline: rbx (parent slab), r12 (child pid, survives pid_free), r13 (exit_status, survives pid_free) all callee-save-preserved via prologue push. r8d (target_ppid), r9 (saw_child flag), rcx (scan index), rax/rdx (scratch + return) are caller-save — NOT held across pid_free call, but the flow arranges so no non-preserved reg is read post-call. pid_free contract per #545: callee-save clean. TSO discipline: only one store site (current->state = WAITING) on the block path; single-CPU R15.M6 makes it trivially visible before the wrapper's yield.",
      block: {
        // ===== prologue =====
        push rbx;
        push r12;
        push r13;
        mov rbx, rdi;                           // rbx = current (parent slab)

        // ===== step 1: target_ppid = current->pid =====
        mov r8d, [rbx + 0];                     // r8 (via r8d) = our pid

        // ===== step 2: scan =====
        xor r9, r9;                             // r9 = saw_child = 0
        mov rcx, 1;                             // scan idx = pid 1
      sys_wait_scan_loop:
        cmp rcx, 64;                            // MAX_PIDS
        ja  sys_wait_scan_done;
        lea rax, [rip + _pid_table];
        mov rax, [rax + rcx*8];                 // rax = candidate slab
        cmp rax, 0;
        je  sys_wait_scan_next;                 // empty slot
        mov edx, [rax + 4];                     // cand->parent_pid (u32)
        cmp rdx, r8;                            // 64-bit cmp (zero-ext safe)
        jne sys_wait_scan_next;
        // This is a child of ours.
        mov r9, 1;                              // saw_child = 1
        mov edx, [rax + 8];                     // cand->state (u32)
        cmp rdx, 3;                             // STATE_ZOMBIE
        je  sys_wait_zombie_found;
      sys_wait_scan_next:
        add rcx, 1;
        jmp sys_wait_scan_loop;

      sys_wait_zombie_found:
        // rax = child slab, rcx = child pid (loop index)
        mov r12d, [rax + 0];                    // r12 = child->pid (save)
        mov r13d, [rax + 12];                   // r13 = exit_status (save)
        mov rdi, rcx;                           // rdi = pid for pid_free
        call pid_free;                          // zeroes _pid_table[pid]
        mov eax, r12d;                          // return pid
        mov edx, r13d;                          // return exit_status
        jmp sys_wait_return;

      sys_wait_scan_done:
        cmp r9, 0;
        je  sys_wait_echild;
        // Have children, none zombie → block.
        mov rax, 2;                             // STATE_WAITING
        mov [rbx + 8], eax;                     // current->state = WAITING
        xor rax, rax;
        xor rdx, rdx;
        jmp sys_wait_return;

      sys_wait_echild:
        mov rax, 0xFFFFFFFFFFFFFFF6;            // -ECHILD (-10)
        xor rdx, rdx;

      sys_wait_return:
        pop r13;
        pop r12;
        pop rbx;
        ret
      }
    }
}
```

Total executable LOC: ~35 assembly lines + ~15 justification /
constants = ~60 LOC in `sys_wait.pdx`. Slightly larger than
`sys_exit_body` (~35 LOC) because of the scan loop + 3-way
branch at end.

### 3.6 Register discipline — the debugger-endemic bug this design avoids (mirror of #557 §3.6)

**Registers this body uses:**

| Register | Role                                       | Callee-save? | Prologue push? | Survives pid_free? |
|----------|--------------------------------------------|--------------|----------------|--------------------|
| rbx      | current / parent slab (for WAITING store)  | callee-save  | yes            | yes                |
| r12      | child_pid (saved before pid_free)          | callee-save  | yes            | yes                |
| r13      | exit_status (saved before pid_free)        | callee-save  | yes            | yes                |
| r8       | target_ppid (our own pid), scan-only       | caller-save  | no             | not needed post-call |
| r9       | saw_child flag, scan-only                  | caller-save  | no             | not needed post-call |
| rcx      | scan index; passed as rdi arg to pid_free  | caller-save  | no             | not needed post-call |
| rax      | candidate slab load / return value         | caller-save  | no             | reloaded from r12  |
| rdx      | candidate field reads / return value       | caller-save  | no             | reloaded from r13  |
| rdi      | pid_free arg (child pid)                   | caller-save  | no             | not needed post-call |

**3 pushes** (rbx, r12, r13) = 24 bytes; combined with return-address
push (8 bytes) = 32 bytes = 16 mod 0. `pid_free` sees rsp aligned.

**pid_free contract (from #545 justification).** "Registers:
callee-save clean." So rbx, r12, r13 (our saved regs) are
untouched by the call. rax gets clobbered (pid_free returns
nothing meaningful; it does `mov [rax+rdi*8], 0; ret`).

**The endemic bug class NOT reached.** All values held live
across the pid_free call are in callee-save regs (r12, r13) with
prologue backing. Recent post-mortems (`f6ην6247` phys_alloc
r12-r15 fix, `3e6a550` self-IPI callee-save audit) show what
happens when this discipline is violated — this body's 3-push
prologue is the same discipline task_new uses across its 3
nested calls (pid_alloc, aspace_create_user, pid_free).

**Comparison to #557 sys_exit_body (no nested calls).** That body
uses ALL caller-save regs (rax, rcx, r8, rdi, rsi). This body
needs 3 callee-save because it has a nested call with two live
values (child_pid, exit_status) to preserve across it. The
prologue cost is 3 pushes vs. #557's zero pushes — proportionate
to the added complexity.

### 3.7 The minimal-reap contract — what leaks and why it's OK at R15.M6

This body calls **only** `pid_free(child_pid)`. It does NOT call:
- `task_free(child)` — not landed (#550 open).
- `aspace_teardown(child->user_pml4_pa)` — would leak the
  user aspace tree.
- `fd_close_all(child)` — no such function exists yet.

**What actually leaks per reap:**

| Resource                  | Size            | Recovered by                    |
|---------------------------|-----------------|---------------------------------|
| task_struct slab bytes    | 2224 B (~1 slot)| Next `task_new` reusing the pid |
| user aspace (PML4 + PT)   | 4 KiB × ~O(1)   | R15.M6-007 or a future GC pass  |
| child's fd_table u64s     | 256 B in-slab   | Slab reuse (rep-stosq zero)     |

**Why the leak is acceptable at R15.M6:**

1. **Slab reuse.** The compact mapping `_pid_table[pid] ==
   &_task_pool[pid-1]` is maintained across pid_free / pid_alloc.
   When the next task_new hits the reaped pid, it recomputes
   `slab_addr = &_task_pool + (pid-1)*4096` — the same physical
   slab — and calls `rep stosq` to zero it. The previous child's
   bytes never leak into a *later* task. The window is bounded by
   "until the pid gets reused"; on a 64-pid pool with slot 4-7
   already occupied and typical process churn low, that's soon.
2. **Aspace leak (bigger)**. The user aspace (PML4 + populated
   PTs) stays allocated. On a 64-process budget with 4 KiB pools
   each, worst-case leak = 64 * ~16 KiB = 1 MiB. Well within R14b
   physical memory budget (32 MiB pool). NOT recovered on slab
   reuse — task_new(parent) calls aspace_create_user which
   allocates a *fresh* PML4 pool, so the old PML4 stays orphaned.
3. **Debug ergonomics.** The zombie's slab (even after pid_free)
   remains readable in memory; a hypothetical debugger walking
   `_task_pool` can see past exit history. This is a feature
   pending R16+ audit-log design.
4. **Explicit backtrack path.** When #550 (task_free real) lands,
   §6.1 backtrack A replaces `pid_free(rcx)` with `task_free(rax)`
   — a 1-line diff, no other logic changes. This design does
   not commit to any invariant that task_free would break.

**Cross-check with #557 §Scope out-of-scope point 1.** #557's
sys_exit_body says "the parent's sys_wait consumer invokes
task_free(child) after copying the two u32s out." That
consumer IS this body. #557 anticipated task_free being ready
by the time #556 landed. It isn't. This doc explicitly
weakens the contract: sys_wait calls pid_free only, retaining
the shape of #557's design intent (parent reaps; child stays
zombie until reap) while punting the full teardown.

### 3.8 Encoding notes — every mnemonic used

| Mnemonic                       | Byte pattern (nominal)          | Audited by                              |
|--------------------------------|---------------------------------|-----------------------------------------|
| `push rbx`                     | 53                              | task_new prologue                       |
| `push r12`                     | 41 54                           | task_new prologue                       |
| `push r13`                     | 41 55                           | task_new prologue                       |
| `pop rbx / r12 / r13`          | 5B / 41 5C / 41 5D              | task_new epilogue                       |
| `mov rbx, rdi`                 | 48 89 FB                        | Everywhere                              |
| `mov r8d, [rbx + disp8]`       | 44 8B 43 xx                     | (r8d dst — REX.R + 8B, disp8)           |
| `mov r12d, [rax + disp8]`      | 44 8B 60 xx                     | REX.R + 8B; task_pool.pdx:112 (REX.R+B store class) |
| `mov r13d, [rax + disp8]`      | 44 8B 68 xx                     | Same class                              |
| `mov edx, [rax + disp8]`       | 8B 50 xx                        | Everywhere                              |
| `mov [rbx + disp8], eax`       | 89 43 xx                        | fd_table stores                         |
| `mov rax, imm32` (STATE_*)     | 48 C7 C0 xx xx xx xx           | Everywhere                              |
| `mov rax, imm64` (ECHILD_NEG)  | 48 B8 xx xx xx xx xx xx xx xx  | aspace_map.pdx:182                      |
| `mov rcx, imm32`               | 48 C7 C1 xx xx xx xx           | Everywhere                              |
| `mov rdi, rcx`                 | 48 89 CF                        | Everywhere                              |
| `mov eax, r12d` / `mov edx, r13d` | 44 89 E0 / 44 89 EA          | task_pool.pdx:134 (`mov edi, r12d`)     |
| `lea rax, [rip + sym]`         | 48 8D 05 xx xx xx xx           | Every RIP-rel access                    |
| `mov rax, [rax + rcx*8]`       | 48 8B 04 C8                     | task_pool.pdx:37                        |
| `cmp rcx, imm8`                | 48 83 F9 xx                     | Everywhere                              |
| `cmp rdx, r8` (64-bit REX.WR)  | 4C 39 C2                        | phys_alloc.pdx:50 (`cmp r9, r12`)       |
| `cmp rdx, imm8` (STATE_ZOMBIE) | 48 83 FA xx                     | Everywhere                              |
| `cmp r9, imm8` (0)             | 49 83 F9 xx                     | (REX.B + 83 /7 + disp8) — standard      |
| `xor r9, r9` / `xor rax, rax` / `xor rdx, rdx` | 4D 31 C9 / 48 31 C0 / 48 31 D2 | Everywhere         |
| `xor eax, eax`                 | 31 C0                           | Everywhere                              |
| `add rcx, imm8`                | 48 83 C1 xx                     | Everywhere                              |
| `je / jne / ja / jmp / ret`    | 74/75/77/EB/C3                  | Everywhere                              |
| `call rel32` (pid_free)        | E8 xx xx xx xx                  | task_new call to pid_alloc / pid_free   |

No new paideia-as encoder patterns. Every mnemonic mapped to an
existing precedent in the codebase.

## 4. Test canary — kernel_main witness block

### 4.1 Witness shape

Three sub-tests exercise the three return paths:

- **Sub-test A** (zombie found → reap): pre-populate a zombie
  child, call `sys_wait_body(parent)`, assert `rax == child.pid`,
  `rdx == exit_status`, `_pid_table[child.pid] == 0`, parent
  state unchanged.
- **Sub-test B** (children exist, none zombie → block):
  child in state NEW (or RUNNABLE), call `sys_wait_body(parent)`,
  assert `rax == 0`, `parent->state == STATE_WAITING (2)`.
- **Sub-test C** (no children → -ECHILD): parent with no
  children in `_pid_table`, call `sys_wait_body(parent)`, assert
  `rax == 0xFFFFFFFFFFFFFFF6`, parent state unchanged.

All three sub-tests emit a single joint marker `R15 SYS WAIT OK\n`
on success. Coverage exceeds the AC minimum (which only requires
A + C) by including B — the state = WAITING transition is the
one non-return-value side-effect of the body, and losing test
coverage on it invites regressions.

### 4.2 Witness storage

No new `.bss` blob — the witness reuses `_task_pool` and
`_pid_table` via `task_new`. Tasks constructed:

| Slot | Pid     | Role                              |
|------|---------|-----------------------------------|
| 8    | 8       | parent A — sub-test A             |
| 9    | 9       | zombie child A (reaped)           |
| 10   | 10      | parent B — sub-test B             |
| 11   | 11      | non-zombie child B (NEW)          |
| 12   | 12      | parent C (no children) — sub-test C |

Pids 1-7 are held by prior witnesses (task_pool + sys_exit).
`pid_alloc` returns 8-12 dense-low. Post-witness occupancy:
11 slots occupied (pid 9 reaped → slot free but slab dirty).
Well within 64-slot budget.

**Interference with sys_exit witness zombies.** sys_exit witness
leaves pid 5 and pid 7 in ZOMBIE state (with parent_pids 4 and 6
respectively). The sys_wait scan visits them — parent_pid != 8
(sub-test A) → skipped. Similarly for sub-tests B and C. No
cross-witness interference.

### 4.3 Witness assembly

Placement: inside `boot_continue_after_ring3` immediately after
`sys_exit_witness_exit` label (line 789), before the GS_BASE
setup (line 792).

```asm
; ============================================================
; R15-M6-005 (#556): sys_wait witness — 3 sub-tests, 1 marker
; ============================================================
sys_wait_witness:
    ; ---------- Sub-test A: zombie found, reap ----------
    ; parent_a = task_new(NULL)
    xor rdi, rdi;
    call task_new;
    cmp rax, 0;
    je  sys_wait_witness_fail;
    mov r12, rax;                                ; r12 = parent_a (pid 8)

    ; child_a = task_new(parent_a)
    mov rdi, r12;
    call task_new;
    cmp rax, 0;
    je  sys_wait_witness_fail;
    mov r13, rax;                                ; r13 = child_a (pid 9)

    ; Manually mark child_a as ZOMBIE with exit_status = 42
    mov rax, 3;                                  ; STATE_ZOMBIE
    mov [r13 + 8], eax;
    mov rax, 42;
    mov [r13 + 12], eax;                         ; exit_status = 42

    ; sys_wait_body(parent_a)
    mov rdi, r12;
    call sys_wait_body;

    ; Assert: rax == child_a->pid (9)
    mov rcx, [r13 + 0];                          ; child_a->pid
    and rcx, 0xFFFFFFFF;                         ; low 32 (pid is u32)
    cmp rax, rcx;
    jne sys_wait_witness_fail;

    ; Assert: rdx == 42
    cmp rdx, 42;
    jne sys_wait_witness_fail;

    ; Assert: _pid_table[9] == 0 (child slot reaped)
    lea rcx, [rip + _pid_table];
    mov rax, [rcx + 9*8];                        ; slot 9
    cmp rax, 0;
    jne sys_wait_witness_fail;

    ; Assert: parent_a->state unchanged (NEW = 0)
    mov eax, [r12 + 8];
    cmp rax, 0;
    jne sys_wait_witness_fail;

    ; ---------- Sub-test B: no zombie, block ----------
    ; parent_b = task_new(NULL)
    xor rdi, rdi;
    call task_new;
    cmp rax, 0;
    je  sys_wait_witness_fail;
    mov r12, rax;                                ; r12 = parent_b (pid 10)

    ; child_b = task_new(parent_b)  — state stays at NEW (=0)
    mov rdi, r12;
    call task_new;
    cmp rax, 0;
    je  sys_wait_witness_fail;
    mov r13, rax;                                ; r13 = child_b (pid 11)

    ; sys_wait_body(parent_b)
    mov rdi, r12;
    call sys_wait_body;

    ; Assert: rax == 0 (would block)
    cmp rax, 0;
    jne sys_wait_witness_fail;

    ; Assert: parent_b->state == STATE_WAITING (2)
    mov eax, [r12 + 8];
    cmp rax, 2;
    jne sys_wait_witness_fail;

    ; Assert: child_b->state unchanged (NEW = 0)
    mov eax, [r13 + 8];
    cmp rax, 0;
    jne sys_wait_witness_fail;

    ; Assert: _pid_table[11] != 0 (child NOT reaped)
    lea rcx, [rip + _pid_table];
    mov rax, [rcx + 11*8];
    cmp rax, 0;
    je  sys_wait_witness_fail;

    ; ---------- Sub-test C: no children, ECHILD ----------
    ; parent_c = task_new(NULL)
    xor rdi, rdi;
    call task_new;
    cmp rax, 0;
    je  sys_wait_witness_fail;
    mov r12, rax;                                ; r12 = parent_c (pid 12)

    ; sys_wait_body(parent_c) — no children exist for pid 12
    mov rdi, r12;
    call sys_wait_body;

    ; Assert: rax == -ECHILD (0xFFFFFFFFFFFFFFF6)
    mov rcx, 0xFFFFFFFFFFFFFFF6;
    cmp rax, rcx;
    jne sys_wait_witness_fail;

    ; Assert: parent_c->state unchanged (NEW = 0)
    mov eax, [r12 + 8];
    cmp rax, 0;
    jne sys_wait_witness_fail;

    ; ---------- All checks green ----------
    lea rdi, [rip + sys_wait_witness_ok_msg];
    call uart_puts;
    jmp sys_wait_witness_exit;

sys_wait_witness_fail:
    lea rdi, [rip + sys_wait_witness_fail_msg];
    call uart_puts;

sys_wait_witness_exit:
```

**Rodata strings (added to `tools/boot_stub.S`):**

```
# R15-M6-005 (#556): sys_wait witness success message
.global sys_wait_witness_ok_msg
.align 8
sys_wait_witness_ok_msg: .ascii "R15 SYS WAIT OK\n\0"

# R15-M6-005 (#556): sys_wait witness failure message
.global sys_wait_witness_fail_msg
.align 8
sys_wait_witness_fail_msg: .ascii "R15 SYS WAIT FAIL\n\0"
```

### 4.4 What the twelve assertions prove

Sub-test A (zombie found — reap):

1. **rax == child_a->pid.** Scan located pid 9 as the zombie; the
   body extracted its pid @ 0 and returned via rax.
2. **rdx == 42.** The exit_status @ 12 was extracted BEFORE
   pid_free zeroed the slot, preserved in r13 across the call,
   returned via rdx.
3. **_pid_table[9] == 0.** pid_free actually ran; the slot is
   free for future pid_alloc.
4. **parent_a->state unchanged (NEW).** Sync path doesn't touch
   parent state; step 4 (WAITING store) not reached.

Together these prove the reap path executes end-to-end: scan
finds zombie, data extraction survives pid_free, table slot
released.

Sub-test B (no zombie, block):

5. **rax == 0.** Block signal to the wrapper.
6. **parent_b->state == WAITING (2).** Step 4 WAITING store
   executed on the have-children branch.
7. **child_b->state unchanged (NEW = 0).** The body does NOT
   modify children's state on the block path.
8. **_pid_table[11] != 0.** No reap happened; child slot still
   allocated.

Together these prove the block path executes: no reap, state
transition on self, children left alone.

Sub-test C (no children, -ECHILD):

9. **rax == 0xFFFFFFFFFFFFFFF6.** ECHILD signal; parent has no
   children.
10. **parent_c->state unchanged (NEW).** ECHILD path does NOT
    set state = WAITING (documented in §3.3 step 4).

Together these prove the ECHILD path distinguishes "no children"
from "children not zombie" correctly.

Combined: 10 field-level assertions (plus the two rax equality
checks for -ECHILD and pid) on 5 tasks. Covers zombie-scan,
reap, would-block WAITING transition, and ECHILD.

### 4.5 Fingerprint additions

Marker line appended to three fingerprint files (contains-in-order):

`tests/r15/expected-boot-r15-process.txt`:

```diff
 R15 TASK NEW OK
 TASK pool ok pids=1,2,3
 R15 SYS EXIT OK
+R15 SYS WAIT OK
 IPI OK
```

`tests/r15/expected-boot-r15-ring3.txt`:

```diff
 R15 TASK NEW OK
 R15 SYS EXIT OK
+R15 SYS WAIT OK
 IPI OK
```

`tests/r14b/expected-boot-r14b-loader.txt`:

```diff
 R15 TASK NEW OK
 R15 SYS EXIT OK
+R15 SYS WAIT OK
 LOADER OK
```

The other 5 fingerprint files (`boot_r8_only`, `boot_r10`,
`boot_r11`, `boot_r12`, `boot_r12_denial`) do **not** need
editing — their scope is pre-R15 substrate; the extra line
post-dates their fingerprint window and contains-in-order
matching stays byte-identically green.

### 4.6 What the witness does NOT test (deferred)

- **Syscall wrapper.** The `sys_wait4` dispatch slot still
  returns ENOSYS. Wire-up requires cpu_local_current_task +
  sched_pick_next — deferred.
- **Cross-wakeup with sys_exit's WAITING transition.** Sub-test
  B leaves parent_b in state WAITING. If a subsequent witness
  called `sys_exit_body(child_b, S)` — with child_b having
  parent_pid == 10 — it would find parent_b in WAITING and
  execute the wakeup path (writing wait_result_pid/status).
  That is the R15.M6-009 fork/exec/wait smoke's job.
- **task_free integration.** #550 pending. When it lands, this
  body will delegate the reap to task_free (backtrack A) and
  the witness gets updated to also assert child slab bytes
  zeroed AND aspace released.
- **Concurrent sys_wait / sys_exit.** SMP-only concern.
- **Multi-child prioritization.** Current scan returns first
  (lowest-pid) zombie; no POSIX-style waitpid or priority.
  A future waitpid extension.

## 5. LOC estimate

| File                                                              | LOC delta |
|-------------------------------------------------------------------|-----------|
| `src/kernel/core/syscall/handlers/sys_wait.pdx` (NEW)             | +60       |
| `src/kernel/boot/kernel_main.pdx` (witness block)                 | +110      |
| `tools/boot_stub.S` (2 rodata strings)                            | +8        |
| `tests/r15/expected-boot-r15-process.txt`                         | +1        |
| `tests/r15/expected-boot-r15-ring3.txt`                           | +1        |
| `tests/r14b/expected-boot-r14b-loader.txt`                        | +1        |
| `design/kernel/r15-m6-005-sys-wait.md` (this doc)                 | +700      |
| **Total**                                                         | **~881**  |

Executable code: ~35 asm lines + ~15 constants/scaffolding in
`sys_wait.pdx` = ~60 LOC. Witness: ~100 asm lines + ~10 rodata refs
= ~110 LOC in `kernel_main.pdx`. Boot_stub rodata: ~8 LOC.
Fingerprint: ~3 LOC. Design: ~700 LOC.

Slightly larger than #557 (~736 LOC total) due to the 3-sub-test
witness and 3-way branch in the body. Same order of magnitude
as #548 and #550. Well within R15.M6 per-issue budget.

## 6. Backtrack candidates

Ordered by preference.

### 6.1 Backtrack A — Full task_free reap once #550 lands

Replace `pid_free(rcx)` with `task_free(rax)` (rax = child slab
pointer at the point of the call). One-line diff. task_free
per its R15.M5-008 doc handles aspace teardown + fd close-all +
slab zero + pid_free internally.

**Consequence.**
- Aspace leak eliminated — the current 1 MiB worst-case leak
  goes to zero.
- Register discipline shifts: task_free takes a slab pointer
  (rax) not a pid (rcx); rdi = rax setup replaces rdi = rcx.
  Still one nested call; 3-push prologue unchanged.
- Witness assertions extend to cover slab zeroing (child
  slab bytes at slot 4-based address should be zero
  post-reap).

**Prefer as soon as #550 lands.** This backtrack is the reason
§3.7's leak budget is temporary. File as follow-up issue to
this one; drop-in edit when #550 closes.

### 6.2 Backtrack B — Return via wait_result_pid / wait_result_status instead of {rax, rdx}

Write the sync-path reap payload into `current->wait_result_pid`
and `current->wait_result_status` (parent's own slab), return
only `rax = child_pid` (or 0 / -ECHILD). Wrapper reads
wait_result_* uniformly for both sync and async paths.

**Consequence.**
- Unified reap-payload API between sync and async. Wrapper
  is simpler.
- Two extra stores per sync reap (wait_result_pid,
  wait_result_status). Minor.
- Testable: witness reads parent->wait_result_pid /
  _status instead of rdx.
- **Reject as primary because it couples the body to the
  wait_result_* freeze more strongly.** If a future design
  wants to bypass the mailbox (e.g., large-arch registers),
  the sync path was the natural exit. Keeping {rax, rdx}
  return preserves that flexibility.

Retain if a future wrapper redesign prefers uniform payload
plumbing.

### 6.3 Backtrack C — Two-pass scan (find zombie, then rescan for any child)

Instead of the single-pass saw_child flag, run the scan twice:
first for `parent_pid == target && state == ZOMBIE`; on miss,
rescan for `parent_pid == target` to distinguish ECHILD from
would-block.

**Consequence.**
- Slightly simpler control flow (no flag reg); r9 freed.
- 2× scan cost on the ECHILD path (which does the full pass
  twice) and 2× on the would-block path (finds no zombie
  first, then finds a child on rescan). The reap path stays
  single-pass.
- 64-entry scan is trivially cheap; the perf hit is
  negligible.
- **Neutral.** Single-pass with flag chosen for aesthetic
  minimality; two-pass is equally correct. Retain as
  equivalent option.

### 6.4 Backtrack D — Scan children in reverse pid order (highest-first)

Reverse the loop direction. Modern POSIX doesn't specify order;
some kernels return youngest first.

**Consequence.**
- Priority effect on multi-zombie parents.
- **Neutral for R15.M6.** No user-observable ordering
  requirement yet. Low-first (default) is aesthetically
  simpler (matches pid_alloc's low-first bias).

### 6.5 Backtrack E — Return pid via rax + status via memory pointer arg

Add a `status_out : *u32` arg (rsi) and have the body write
`*status_out = exit_status` on the sync path.

**Consequence.**
- Matches the POSIX `wait(int *status)` shape more closely.
- The pointer needs validation (userspace or kernelspace).
  R15.M6 body is trusted-kernel-only; wrapper does the
  userspace copy_to_user later.
- **Reject as primary.** The wrapper is the right place for
  the userspace pointer contract; the body should stay
  purely register-based for testability. Retain as wrapper
  API decision.

### 6.6 Backtrack F — Body inline in dispatch.pdx

Same as #557 §6.6 — reject for the same reason (per-syscall
handler discipline).

### 6.7 Backtrack G — Zombie-scan optimization via free-list

Maintain a `_zombie_list` linked list; `sys_exit_body`
appends its `current` to the list; `sys_wait_body` pops the
head with matching parent_pid.

**Consequence.**
- O(1) reap instead of O(MAX_PIDS) scan.
- Requires adding two fields to task_struct (`next_zombie`,
  `prev_zombie`) OR a separate 64-entry queue.
- Complicates sys_exit (append to list) and sys_wait
  (traverse-with-filter — still O(zombies) not O(1) unless
  per-parent queues).
- 64-pid pool makes the scan O(64) which is faster than the
  extra bookkeeping.
- **Reject at R15.M6.** Retain as R16+ scale optimization
  if _pid_table grows to 1000s.

## 7. Tractability

**HIGH.**

- No new paideia-as encoder gap — every mnemonic mapped to an
  existing precedent (#548 task_new, #557 sys_exit, phys_alloc
  loop patterns).
- One nested call (pid_free), simplest possible; 3-push
  prologue matches task_new discipline.
- Body is ~35 asm lines; witness is ~100 asm lines. Same
  tempo as #557 (~85 asm total) and #548 (~90 asm total).
- Zero new field offsets — consumes #557's freeze verbatim.
- Zero new directory — `handlers/` already exists per #557.
- Witness driver is real: `task_new` (#548) is LANDED,
  `_pid_table` is LANDED, `pid_free` (#545) is LANDED,
  `sys_exit_body` (#557) is LANDED — no mocks anywhere.
- Marker line contains-in-order across three fingerprint
  files, none broken by an extra line.

Known follow-ups (not blockers for #556):

- **R15.M6-001 sched_enqueue** — provides sched_pick_next for
  the syscall wrapper.
- **Syscall wrapper wire-up** — replace `dispatch.pdx` ENOSYS
  slot 61 (sys_wait4) with `call sys_wait_body` + return-value
  branching. Lives with whichever issue exposes
  cpu_local_current_task first (likely paired with sys_exit
  wrapper landing).
- **R15.M5-008 task_free (#550)** — when landed, promote reap
  via backtrack A (§6.1). Filed as follow-up.
- **R15.M6-007 orphan reparent (#558)** — after this doc's
  minimal reap, an orphan child's parent_pid may reference a
  pid whose slot was reaped. #558's reparent-to-init pass on
  parent teardown eliminates dangling parent_pids.
- **R15.M6-009 fork/exec/wait smoke** — end-to-end that
  sys_wait + sys_exit round-trip works when driven by
  fork() from userspace.

## 8. Cross-cutting risks

- **AC "no children → -ECHILD" vs. "no zombie children now".**
  The AC lists these as separate cases (fixture forks + waits,
  no-children returns -ECHILD). This doc's saw_child flag is
  what distinguishes them. Mitigation: sub-test C in the witness
  covers the ECHILD path explicitly.
- **task_free absence (#550 open).** This doc's minimal reap
  (pid_free only) accepts a 1 MiB worst-case aspace leak in the
  R15.M6 window. Mitigation: §3.7 documents the budget; §6.1
  backtrack A is the fix once #550 lands.
- **Compact pid↔slab mapping.** This body relies on
  `_pid_table[pid]` returning `&_task_pool[pid-1]` for allocated
  pids; the invariant is pinned by #548 §3.9 / #550 §3.6.
  Mitigation: same as #557 §8 — if the mapping is broken by
  a future edit, this body's scan still works as long as
  `_pid_table[pid]` continues to be the canonical slab lookup.
- **Post-reap pid reuse race (single-CPU trivially safe).**
  After sys_wait_body returns and BEFORE the wrapper returns to
  userspace, the reaped pid could be re-allocated by a
  concurrent task_new. At R15.M6 single-CPU with no preemption
  inside sys_wait_body, this window doesn't exist — a task_new
  cannot preempt the wrapper. R15.M7 SMP needs a per-pid
  spinlock or an RCU-like grace period. Flagged in the
  justification string.
- **child slab bytes leak until pid reused.** §3.7 discusses.
  Not a correctness issue; retention window is bounded by
  next pid_alloc for the same slot.
- **State enum discrepancy risk.** This body consumes STATE_*
  constants from #557's freeze. If #557 is ever backtracked
  (e.g., renumbered enum), this body needs a parallel edit.
  Mitigation: constants are duplicated at the top of
  `sys_wait.pdx` (not imported from `sys_exit.pdx`), which
  makes the local view explicit but requires manual sync.
  Alternative: extract a shared `task_state.pdx` module —
  deferred to R16+ cleanup.
- **Interference with existing zombies from sys_exit witness.**
  Pids 5 and 7 are zombies with parent_pids 4 and 6. The
  sys_wait witness scans them but doesn't match its target
  parent_pids (8, 10, 12). Mitigation: witness pids chosen
  deliberately to avoid overlap.
- **Fingerprint drift.** Same discipline as #557 — pre-push
  hook blocks smoke-negative pushes.
- **`sys_wait_body` return semantics vs. POSIX wait4 ABI.**
  This body returns a raw `{pid, status}` pair. POSIX wait4
  encodes status as `(exit_status << 8) | signal_bits`. The
  encoding is the wrapper's concern; the body returns
  unencoded exit_status. Mitigation: naming convention
  (`exit_status` vs. `wait_status`) — the body's return is
  the raw value; the wrapper does the POSIX encoding.
- **saw_child flag reset if scan is re-entered.** Currently
  saw_child is a local scratch (r9), reset on function entry.
  If a future edit made this body re-entrant (via a nested
  call to itself — unlikely, but hypothetical), the flag would
  need proper scoping. Trivially safe as long as sys_wait_body
  is not recursive.

## 9. Backtrack markers

For the debugger-agent if the witness reports FAIL:

| Symptom                                          | Root cause hypothesis                                  | Where to look                                            |
|--------------------------------------------------|--------------------------------------------------------|----------------------------------------------------------|
| Sub-test A: rax != child pid                     | Loop ran off end / didn't match state ZOMBIE           | Verify `cmp rdx, 3; je zombie_found` fires               |
| Sub-test A: rdx != 42                            | exit_status not saved to r13 before pid_free           | Verify `mov r13d, [rax + 12]` executes pre-call          |
| Sub-test A: _pid_table[9] != 0                   | pid_free not called or wrong pid                       | Verify `mov rdi, rcx; call pid_free`                     |
| Sub-test A: parent_a->state changed              | Sync path erroneously wrote state                      | Verify no `mov [rbx+8], eax` on sync path                |
| Sub-test B: rax != 0                             | -ECHILD path taken erroneously (saw_child = 0?)        | Verify `mov r9, 1` fires on parent_pid match             |
| Sub-test B: parent_b->state != WAITING           | Block path didn't write, or wrote wrong constant       | Verify `mov rax, 2; mov [rbx+8], eax`                    |
| Sub-test B: child_b->state changed               | Scan mutated candidate slab                            | Verify no writes inside scan loop                        |
| Sub-test C: rax != 0xFFFFFFFFFFFFFFF6            | ECHILD constant wrong or block path taken              | Verify `mov rax, 0xFFFFFFFFFFFFFFF6` encoding            |
| Sub-test C: parent_c->state changed              | ECHILD path erroneously set WAITING                    | Verify `jmp sys_wait_return` after ECHILD, not fall-through |
| Silent hang (no OK / FAIL)                       | task_new returned 0 (pid exhaustion) OR body clobbered rip | Check pool occupancy (should be 7 before witness)      |
| Fingerprint mismatch, R15 SYS WAIT OK missing    | Marker not emitted; sub-test failed silently           | Check jmp targets around sys_wait_witness_exit           |
| Fingerprint mismatch, extra line before marker   | Wrong witness block ordering                           | Verify witness sits after sys_exit_witness_exit          |

## 10. References

- Issue: paideia-os#556
- Milestone: paideia-os milestones/62 (R15.M6 fork / exec / wait / _exit)
- Sibling issues in R15.M6:
  - #552 (aspace_clone_cow), #553 (pf_handler_cow_split)
  - #554 (sys_fork), #555 (sys_execve), #557 (sys_exit — LANDED)
  - #558 (orphan adoption), #559 (frame_meta refcount — LANDED)
  - #560 (fork/exec/wait smoke)
- Landed prereqs:
  - #548 task_new (`src/kernel/core/sched/task_pool.pdx:71`)
  - #545 pid_alloc / pid_free (`src/kernel/core/sched/task_pool.pdx:26,56`)
  - #549 fd_table + task_struct field freeze
    (`src/kernel/core/fs/fd_table.pdx`)
  - #557 sys_exit_body (`src/kernel/core/syscall/handlers/sys_exit.pdx`)
- Open prereq (design accommodates):
  - #550 task_free real body (design at
    `design/kernel/r15-m5-008-task-free-real.md`; body NOT LANDED)
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 9 issue 5 (line 1046), state machine (lines 908, 1012)
- Master plan: `design/milestones/r14b-master-plan.md`
  §R15.M6 fork/exec/wait/_exit
- Prior-art witness pattern:
  - `design/kernel/r15-m6-006-sys-exit.md` §4
    (2 sub-tests with post-condition asserts — this doc extends to 3)
- Prior-art register discipline post-mortems:
  - `f6195ed` (phys_alloc callee-save fix)
  - `3e6a550` (self-IPI callee-save audit)
- Prior-art rodata addition to boot_stub.S:
  - `tools/boot_stub.S:374-382` (sys_exit witness msgs)
