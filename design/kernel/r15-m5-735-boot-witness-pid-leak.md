# R15-M5-735: boot-witness pid leak — pid_table cleanup pre-init

**Status:** landed
**Issue:** paideia-os #735 — closes #723 AC
**Depends on:** #737 (dispatch_wait4 writeback), #736 D12 (runtime u32→decimal), #732 (wait4 marshalling)
**Precondition wire-state:** post-#736/#737 the `WAIT:` line's digits are runtime-derived from `rax` (child pid) and `wait_status[0]` (exit status). Init prints `WAIT: pid=23 status=42\n`. The `status=42` field is now honest; the `pid=23` field is honest too — that IS the child's real pid — but the child got pid=23 rather than the expected pid=2 because 21 boot-time witnesses leaked their allocated pids.
**AC target:** `WAIT: pid=2 status=42\n` on wire, with the `pid=2` coming from a real sys_wait4 return (which itself derives from `pid_alloc` handing init's fork child the second slot — pid 1 belongs to init).

---

## 1. Wire evidence pre-fix

At commit `dd3cc10` (#737 landed):

```
INIT ENTERED RING3
INIT OK
CHILD HELLO 42
WAIT: pid=23 status=42   ← honest, but pid is 23 not 2
REAPED
```

The status digits are correct (child exits with status 42, dispatch_wait4 writes it, init reads and formats). The pid digits are correct too — they reflect the actual `sys_fork` return. But the fork's `task_new` inside `sys_fork_body` calls `pid_alloc`, which is a dense-low-first linear scan of `_pid_table`. If pids 1..N are already allocated when fork runs, the child gets pid N+1.

---

## 2. Root cause

### 2.1 The witness pattern

`src/kernel/boot/kernel_main.pdx` runs a chain of ~11 structural witnesses that call `task_new` before init is scheduled. Each `task_new` publishes a slab pointer into `_pid_table[pid]` (task_pool.pdx §7 — "step 7: pid_table[pid] = slab_addr"). Only two witness pairs balance: `task_free_witness_loop` (100 iters of task_new+task_free) and `sys_wait_witness` sub-test A (task_new+task_new followed by sys_wait_body which pid_frees the reaped child). Every other witness leaves its allocated pid marked in `_pid_table`.

### 2.2 Enumeration of `task_new` sites in kernel_main.pdx

| Line | Witness | task_new count | task_free / pid_free? | Pids leaked |
|---|---|---|---|---|
| 1736 | task_free_witness_loop | 100 (loop) | 100 (paired) | 0 (balanced) |
| 1785 | task_new_witness | 1 | none | 1  (pid 1)          |
| 1841, 1851 | pool_witness | 2 | none | 2  (pids 2, 3)     |
| 1896, 1903 | sys_exit_witness sub-1 | 2 | none | 2  (pids 4, 5)     |
| 1942, 1953 | sys_exit_witness sub-2 | 2 | none | 2  (pids 6, 7)     |
| 2040, 2047 | sys_wait_witness sub-A | 2 | 1  (child reaped) | 1  (pid 8; pid 9 freed) |
| 2093, 2102 | sys_wait_witness sub-B | 2 | none | 2  (pid 9 reused, pid 10) |
| 2152 | sys_wait_witness sub-C | 1 | none | 1  (pid 11)        |
| 2189 | sys_execve_witness sub-A | 1 | none | 1  (pid 12)        |
| 2238 | sys_execve_witness sub-B | 1 | none | 1  (pid 13)        |
| 2307, 2314, 2321 | orphan_adoption_witness | 3 | none | 3  (pids 14, 15, 16) |
| 2413 (+ nested sys_fork_body) | sys_fork_witness | 1 + 1 (via body) | none | 2  (pids 17, 18)   |
| 4747 (+ nested sys_fork_body) | fd_inherit_witness | 1 + 1 | none | 2  (pids 19, 20)   |
| 4882 | fd_cloexec_witness | 1 | none | 1  (pid 21)        |
| 6365 | init_bootstrap_witness | 1 | none | 1  (init → pid 22 pre-fix) |

**Total leaked pids by the time init runs:** 21. Init's own task_new (line 6365) then consumes pid 22, and init's user-space `sys_fork()` allocates pid 23 for its child. Hence `WAIT: pid=23 ...` on wire.

### 2.3 Why the pid keeps growing

`pid_alloc` (task_pool.pdx L70-93) is a dense-low-first linear scan:

```
scan rcx from 1..64 for the first _pid_table[rcx] == 0
return rcx (or 0 if none free)
```

There is no per-witness reset. `pid_free` is only called from three sites — `task_new`'s OOM rollback, `task_free`, and `sys_wait_body`'s reap path. None of the leaky witnesses invoke `task_free` or `sys_wait_body` on their allocations.

---

## 3. Design choice

Two candidate approaches were evaluated (per #735's brief):

### Option 1 — pair each witness `task_new` with `task_free`

Add a matching `task_free` after each witness `task_new`. This is invasive because:

- Several witnesses (sys_exit, sys_execve, orphan_adoption) exercise state transitions on the allocated task and then leave the task in state ZOMBIE/RUNNABLE. Calling `task_free` afterwards would either need to be a no-op wrapper (defeating the point) or would need `task_free` to tolerate all lifecycle states — which is not the current contract.
- `task_free` calls `aspace_teardown`, which walks the user PML4 and frees leaves — heavy, and unnecessary for witness cleanup where the aspace was never used for real user pages.
- Ordering matters: `sys_wait_witness` sub-B intentionally verifies that pid 9 gets reused by parent_b (dense-low behavior after sub-A's reap). A blanket `task_free` after each sub-test would break this positive assertion.

### Option 2 — bulk-reset `_pid_table` post-witnesses, pre-init (**CHOSEN**)

After all boot-time witnesses have completed but before `init_bootstrap_witness` calls `task_new(NULL)`, zero every slot of `_pid_table[1..64]`. Rationale:

- **Safe:** by the time init_bootstrap runs, no witness-allocated task is referenced by any live kernel state (see §4 adversarial self-check below).
- **Cheap:** ~10 instructions (single loop, 64 iterations).
- **Local:** one edit site in kernel_main.pdx, no changes to any witness.
- **Idempotent:** re-runs of the boot flow start from a clean pid state.
- **Uses the primitive:** calls `pid_free` in a loop rather than direct MOV writes — keeps the abstraction boundary intact so any future change to `_pid_table`'s representation (e.g., a bitmap) needs only a `pid_free` update.

### 3.1 Reset location

Immediately before the `init_bootstrap_witness:` label at kernel_main.pdx:6362. This site is the last witness before init is constructed. All 21 leaky witnesses precede it (last one is `fd_cloexec_witness` at L4882). Between L4882 and L6362 there are NO `task_new`, `task_free`, `pid_alloc`, `pid_free`, or `_pid_table` references — confirmed by grep.

### 3.2 Reset mechanism

```asm
// R15-M5-735 (#735): clean _pid_table before init_bootstrap
// so init gets pid=1 (and its fork child gets pid=2 — see #723 AC).
xor r12, r12                              // r12 = counter (start at pid 0)
pid_table_reset_loop:
    mov rdi, r12
    call pid_free                         // zeros _pid_table[r12]
    add r12, 1
    cmp r12, 64                           // MAX_PIDS
    jb  pid_table_reset_loop
```

Iterates pids 0..63 inclusive (all 64 array slots). Including pid 0 is defensive — the design reserves pid 0 as the "idle" sentinel and `pid_alloc` starts scanning at pid 1, so slot 0 is never touched by allocation; but zeroing it costs nothing and matches the "clean slate" semantic.

The array `_pid_table` is declared `[u64; 64]` in task_pool.pdx L21, so valid indices are [0..63]. Iterating past 63 would OOB (into the adjacent `_task_kernel_stacks` allocation) — bounded above by `cmp r12, 64; jb`.

Register discipline: `r12` is callee-save under SysV; `pid_free` preserves it (its documented contract is "callee-save clean"). No other registers touched.

---

## 4. Adversarial self-check

### 4.1 Are any witness-allocated TCBs still live at reset time?

For "live" I take: (a) referenced by `_current_tcb`, (b) on the runqueue, (c) pointed to by any global. Auditing each witness:

- **task_free_witness_loop, task_new_witness:** allocated slabs live only in a local register (r12). No global reference, not enqueued.
- **pool_witness:** allocated slabs in r12/r13/r14. Not enqueued (no runqueue calls). No global.
- **sys_exit_witness:** children transitioned to STATE_ZOMBIE. sub-2 enqueues parent2 but explicitly calls `runq_dequeue` at L2010 before exit.
- **sys_wait_witness:** sub-A reaps child_a (pid_freed). sub-B leaves child_b in NEW state, unenqueued. sub-C parent_c not enqueued.
- **sys_execve_witness:** t_a's aspace swapped via execve; task itself not enqueued or globally referenced.
- **orphan_adoption_witness:** exit_body called on A, B — sets them to ZOMBIE. Not enqueued. C stays in NEW.
- **sys_fork_witness:** parent NEW; child was enqueued but explicit `runq_dequeue` at L2551 removes it.
- **fd_inherit_witness, fd_cloexec_witness:** parent + child (via fork_body inside). fork_body enqueues the child; **there is NO explicit dequeue in either witness after the fork_body call.** BUT: the runqueue is then re-initialized by the real `call runq_init` at kernel_main.pdx:6419 (well after reset time; note that runq_init just re-writes the head sentinel, orphaning stale next/prev pointers — this is documented behavior per runqueue.pdx `runq_init` "Idempotent: safe to re-call"). And crucially, the state field of these children is STATE_RUNNABLE, but they never get picked because the reset happens BEFORE runq_init re-runs — the runqueue is torn down before any scheduler picks from it.

Wait — that ordering claim needs re-verification. Reset happens at L6362 (pre-init_bootstrap). `runq_init` re-runs at L6419 (post-runqueue witness). So between L6362 and L6419, the runqueue is still holding stale pointers from fd_inherit / fd_cloexec's fork_body children. Nothing schedules between L6362 and L6419 (no `sched_pick_next_r15` call happens there — the runq witnesses at L6482+ come AFTER the runq_init re-init). Safe.

Also relevant: the child TCB slabs are still at their `_task_pool[i]` addresses. The reset only clears `_pid_table`, not the slabs themselves. If anything later dereferences a stale `_pid_table[i]` — no, it can't, because the entries are now zero. If anything indexes `_task_pool[i]` directly without going through `_pid_table` — the runqueue does exactly this (its `runq_next` / `runq_prev` fields are absolute slab addresses, not pid-indexed). The subsequent `runq_init` at L6419 severs those stale links.

**Verdict:** no witness TCB is live-referenced past reset time in a way the reset would break.

### 4.2 What if reset runs earlier than intended?

If the reset accidentally moved before `pool_witness` (L1828), the assertion `pool_witness` step 2 (`pid == 2`) would fail because pid_alloc would return 1 (empty table). This is a fail-loud regression. Guards the placement.

### 4.3 What if reset runs later than intended?

If placed after L6365, init's `task_new` runs first and gets pid=22, then reset zeros `_pid_table[22]`, orphaning the init slab. `_init_task` would still point at the slab (published at L6390), but pid-indexed lookups would fail. Init's fork child would then get pid=1 (first free slot). WAIT: pid=1 status=42 on wire — different pid, still not 2. Guards against post-init placement.

### 4.4 Wire assertion for the fix

Post-fix wire MUST show `WAIT: pid=2 status=42\n`. If it shows:
- `pid=1`: reset ran after init_bootstrap (init got wiped, child got pid 1).
- `pid=3+`: reset missed some leaks or ran too early.
- `pid=22`: reset didn't run.

---

## 5. Related latent issue (not fixed here)

`pid_alloc` at task_pool.pdx L70-93 tests `cmp rcx, 64; ja pid_alloc_none` — an out-of-bounds fencepost. `_pid_table : [u64; 64]` has valid indices [0..63], but the `ja` allows `rcx=64` to proceed, indexing `_pid_table[64]` which is one qword past the array's end (into `_task_kernel_stacks[0]`'s first slab, aligned by @align(4096) with slack). At R17.M0 this is unreachable in practice (63 pids are ample for boot), but it's a latent overrun. Fix would be `jae` or `cmp rcx, 63; ja`. Flagged as follow-up — not blocking #723's AC.

---

## 6. Implementation

### 6.1 Source edit

`src/kernel/boot/kernel_main.pdx` — insert the reset block between `libc_test_witness_done:` (~L6351) and `init_bootstrap_witness:` (L6362). ~10 lines including comment.

### 6.2 Test-fingerprint edit

`tests/r17/expected-boot-r17-init.txt` — change line 28 from `WAIT: pid=23 status=42` to `WAIT: pid=2 status=42`.

### 6.3 No other edits required

No `.pdx` source outside kernel_main.pdx changes. No test-file changes besides r17 fingerprint. All other boot modes (r8..r16, r14b) are unaffected — they don't reach init.

---

## 7. Verification plan

1. `tools/run-smoke.sh boot_r17_init` — must PASS with new fingerprint (`WAIT: pid=2 status=42`).
2. `tools/run-smoke.sh boot_r15_process` — pool witness must still PASS (dense-low pids 1→2→3 pre-reset).
3. Pre-push 10-mode matrix — all green.
4. Grep serial log at `/tmp/paideia-os-smoke.log` for the exact byte sequence `WAIT: pid=2 status=42\nREAPED`.

Once wire shows `WAIT: pid=2 status=42` from runtime-derived digits (post-#736/#737) with the pid arriving from real `pid_alloc` at the honestly-clean pid 2 slot, **#723's AC is truly and honestly closed** — no hardcoded literal in init.pdx, no leaked pids skewing the count.
