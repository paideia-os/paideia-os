---
issue: 558
milestone: R15.M6 (fork / exec / wait / _exit)
subsystem: 9 — fork / exec / wait / _exit
prereq:
  - "#548 (task_new real — LANDED at src/kernel/core/sched/task_pool.pdx; provides _pid_table and slab layout the orphan walker traverses)"
  - "#549 (fd_table embed — LANDED; pins task_struct.parent_pid @ offset 4, the field orphan_adopt rewrites)"
  - "#557 (sys_exit real body — LANDED at src/kernel/core/syscall/handlers/sys_exit.pdx; hosts the orphan_adopt call site — see §3.3 integration point)"
blocks:
  - "R15.M6-009 / #560 (fork/exec/wait smoke — end-to-end fork chains rely on orphaned children finding a reap point; this doc's reparent-on-exit invariant prevents dangling parent_pid pointers in the smoke)"
touching:
  - src/kernel/core/syscall/handlers/sys_exit.pdx           (add orphan_adopt helper + patch sys_exit_body integration point)
  - src/kernel/boot/kernel_main.pdx                         (witness block, ~85 LOC)
  - tools/boot_stub.S                                       (2 rodata strings)
  - tests/r15/expected-boot-r15-process.txt                 (marker line, contains-in-order)
  - tests/r15/expected-boot-r15-ring3.txt                   (marker line, contains-in-order)
  - tests/r14b/expected-boot-r14b-loader.txt                (marker line, contains-in-order)
  - design/kernel/r15-m6-007-orphan-adoption.md             (this doc)
related:
  - design/kernel/r15-m6-006-sys-exit.md                    (§3.3 body sequence — this doc patches step 2.5)
  - design/kernel/r15-m5-006-task-new-real.md               (§3.9 compact pid↔slab mapping — this doc's walker relies on it)
  - design/kernel/r15-m5-008-task-free-real.md              (planned home of orphan_adopt once #550 lands; §6.1 backtrack A)
  - design/milestones/r14b-tactical-plan.md                 (§Subsystem 9 issue 7)
---

# R15-M6-007 — orphan adoption by init (#558)

## 1. Scope

Give the R15.M6 process model an **orphan-adoption invariant**: at
the instant a parent task transitions to ZOMBIE, every task in
`_pid_table` whose `parent_pid` points at that parent has its
`parent_pid` rewritten to `1` (the reserved "init" pid). This
prevents dangling parent references — future `sys_exit` calls from
those (now-orphaned) children see a well-formed `parent_pid ∈ {0,
1, ..., 64}` and use the sys_exit doc §3.3 step-4 defensive path
correctly.

Two invariants define completion:

- **Reparent-on-exit.** After `sys_exit_body(parent, status)`
  returns, for every allocated slot `_pid_table[i]` where the
  parent-pointer stored at offset 4 previously equaled
  `parent->pid`, that field is now `1`. Zero children need
  rewriting when the parent has no children — the walker still
  runs, still costs O(64), still concludes.

- **Cascade correctness.** Multi-generational chains resolve
  correctly across sequential parent exits. If A → B → C exists
  and A exits, B is adopted (B.parent_pid = 1); C is *not*
  touched (C.parent_pid still = B.pid, and B is still alive).
  Then if B exits, C is adopted (C.parent_pid = 1). The witness
  in §4 exercises this exact cascade.

Explicitly out of scope (deferred):

- **task_free migration.** Issue #558's original scope named
  `task_free.pdx` as the touching file. task_free (#550) is
  OPEN (task_free function does not exist in
  `src/kernel/core/sched/task_pool.pdx`). This doc justifies the
  landing site shift to `sys_exit.pdx` in §2.2. When #550 lands,
  the orphan_adopt CALL moves from `sys_exit_body` to
  `task_free` — the HELPER stays put (§6.1 backtrack A). One-line
  change, no witness churn.

- **Init as a designated reap-loop task.** Real POSIX init runs
  in a `while (true) sys_wait();` loop, reaping every orphan
  that dies. R15.M6 has no such loop — pid 1 exists as a byproduct
  of the earliest `task_new(NULL)` witness (line 586 of
  kernel_main), in STATE_NEW. That slab satisfies the *lookup*
  invariant (`_pid_table[1] != 0`) but not the *reap* invariant
  (init is never WAITING). Consequence: adopted-orphan zombies
  accumulate at end-of-boot rather than being reaped. Acceptable
  at fixture-level; R17+ init-loop closes the loop.

- **SMP reparent race.** On a future SMP kernel, a concurrent
  `task_new` on CPU B could publish a new child with
  `parent_pid = A.pid` between CPU A's orphan_adopt scan and A's
  ZOMBIE-state publish. The new child would miss the reparent
  pass. At R15.M6 single-CPU with no preemption inside
  sys_exit_body, this race is impossible. §6.4 backtrack D
  proposes an atomic scan/mark barrier for the SMP promotion.

- **pid_table gap tolerance.** The compact mapping (§3.9 of
  #548) makes `_pid_table[i]` correspond to
  `_task_pool[i-1]` for allocated pids. Nothing in this design
  depends on that compactness — the walker treats
  `_pid_table[i] == 0` as "unallocated slot, skip" regardless of
  whether allocation is dense-low. A sparse pid_table (post-R16
  pid space > 64) still walks correctly; only the loop bound
  grows.

## 2. Prereq check

### 2.1 What's in place

| Primitive                          | Location                                        | Contract used by orphan_adopt                     |
|------------------------------------|-------------------------------------------------|---------------------------------------------------|
| `task_struct.pid @ 0`              | `#549 §3.1 layout freeze`                        | Not read (the walker uses table indices, not slab pid) |
| `task_struct.parent_pid @ 4`       | `#549 §3.1 layout freeze`                        | u32, read/written by the walker                   |
| `_pid_table[pid]`                  | `core/sched/task_pool.pdx:21`                    | u64 slab pointer per pid; walker iterates 1..64   |
| `_pid_table` size = 64             | `core/sched/task_pool.pdx:21` (MAX_PIDS)         | Loop bound; hardcoded 64                          |
| `sys_exit_body`                    | `core/syscall/handlers/sys_exit.pdx:30`          | Call site — see §3.3                              |
| `pid == 0` sentinel                | `#548 §3.1` (task_new(NULL) → parent_pid=0)      | Init sentinel; orphan_adopt rewrites parent_pid TO 1 (not 0) — matches POSIX orphan-adoption |
| `mov r64, [rip + sym]` / `lea`     | Every RIP-rel access                             | `&_pid_table` base load                            |
| `mov [reg + reg*8], reg` (SIB)     | task_pool.pdx:123                                | Not used by walker (walker uses `[rax + rcx*8]` load, no SIB store) |
| `mov r64, [reg + reg*8]` (SIB)     | task_pool.pdx:37                                 | Slab load per index                                |
| `mov r32, [reg + disp8]`           | Everywhere                                       | Load parent_pid from slab                          |
| `mov [reg + disp8], r32`           | task_pool.pdx:112, 118                           | Store `1` into parent_pid field                    |
| `cmp / je / jne / jmp / ret`       | Everywhere                                       | Vanilla control flow                               |

### 2.2 What is not in place — the task_free non-existence

**#550 (task_free) is OPEN.** Verified by (a) `gh issue view
-R paideia-os/paideia-os 550 --json state` returns `"state":
"OPEN"`, and (b) `grep -n 'task_free' src/kernel/core/sched/*.pdx`
returns only *references* to a hypothetical `task_free` inside
`pid_free`'s justification string (line 60) and inside a comment
in task_pool.pdx line 54 — no *definition* exists.

The issue #558 body names the touching file as
`src/kernel/core/sched/task_free.pdx`. That file does not exist.
Landing #558 there would require *first* landing #550, which
would require *first* landing #553 (pf_handler_cow_split), which
is blocked by #660 (CR0.WP). The chain from #558 back to #660 is
4 issues deep.

**This doc breaks the chain** by relocating the CALL site from a
non-existent `task_free` to the existing `sys_exit_body`. The
semantic difference:

| Semantic                           | task_free-hosted (#558 original) | sys_exit-hosted (this doc)             |
|------------------------------------|----------------------------------|----------------------------------------|
| When orphans are reparented        | Parent's slab is torn down       | Parent transitions to ZOMBIE           |
| Time window for orphaned sys_exit  | ZOMBIE → task_free (parent's sys_wait return) | Instantaneous — same body |
| Concurrent parent access            | Impossible (slab is being freed) | Possible if IRQ arrives mid-body       |
| Cost when parent has no children   | O(64) walk in task_free           | O(64) walk in sys_exit                 |
| Requires task_free to exist        | Yes                              | No                                     |
| Requires sys_exit to exist         | No                               | Yes (LANDED at #557)                   |

**POSIX prior art.** Linux does the reparent inside `do_exit`'s
`exit_notify` path (kernel/exit.c:`forget_original_parent`), NOT
inside `release_task` (which is Linux's task_free equivalent).
Rationale: as soon as a task can no longer *be* a parent (i.e.
its state is not RUNNABLE/RUNNING), its children should not
continue observing it as parent. sys_exit-hosted reparenting is
the POSIX-canonical timing.

**Backtrack cost when #550 lands.** The orphan_adopt HELPER lives
in `src/kernel/core/syscall/handlers/sys_exit.pdx` (or its
migration point — see §6.1). The CALL SITE lives in
`sys_exit_body`. When #550 lands:

1. Remove the call from `sys_exit_body` (delete ~5 instructions).
2. Add the call to `task_free` (add ~5 instructions).
3. Move the helper to `task_pool.pdx` or a new
   `orphan.pdx` (optional, aesthetic).
4. Adjust witness (may need to construct fake reap flow to
   trigger orphan_adopt at task_free time). This is the largest
   churn, but bounded — the assertions don't change, just the
   trigger.

Estimated churn: 20-40 LOC across 3 files. Same order as the
current landing. §6.1 backtrack A pins this migration recipe.

### 2.3 Encoder gaps

**None.** The orphan_adopt walker uses only:

- `lea rax, [rip + sym]` — audited everywhere
- `mov rax, [rax + rcx*8]` — audited by pid_alloc:37
- `mov eax, [rax + disp8]` — u32 load with sign-agnostic
  zero-extend into 64-bit rax; audited by fd_get / fd_set /
  task_pool loads
- `mov [rdx + disp8], eax` — u32 store to slab offset 4;
  audited by task_pool.pdx:118 (`mov [r13 + 4], eax`)
- `cmp reg, imm8` / `cmp reg, reg` — everywhere
- `add reg, imm8` / `jmp / je / jne / jbe / ret` — vanilla

The one new pattern is *comparing a zero-extended u32 to rdi*
(`cmp rax, rdi` after `mov eax, [rdx + 4]`). At R15.M6 pids
range 1..64, all fit in u32 zero-extended-to-u64 range. If a
future edit pushes pids past 2^32, the comparison narrows to
`cmp eax, edi` which paideia-as also encodes. No gap.

## 3. Design

### 3.1 orphan_adopt — walker contract

```
orphan_adopt : (pid: u64) -> () !{mem} @{}

Entry: rdi = pid (u32-safe, but read via 64-bit cmp)
Exit:  rax = don't care; rcx, rdx clobbered
Preserved: rsi, r8, r9, r10, r11, rbx, r12-r15 (no callee-save touched)

Semantics: For each i ∈ [1, 64] where _pid_table[i] != 0, if
           _pid_table[i]->parent_pid == pid, write 1 to
           _pid_table[i]->parent_pid. Idempotent — running
           twice is a no-op after the first pass.

Not touched: rsi (holds sys_exit's `status` — preserved so the
             caller can still complete step 6 wakeup without
             re-materializing status).
```

**Why rsi preservation matters.** The caller
(`sys_exit_body` after this doc's patch) invokes orphan_adopt
between step 2 and step 3. At that point, rsi holds the exit
status, and step 6 still needs to store it to
`parent->wait_result_status`. If orphan_adopt clobbered rsi, the
call site would need `push rsi / pop rsi` to bracket the call —
adding 2 instructions and stack-alignment discipline. Designing
the walker to avoid rsi is a 1-instruction-cheaper local win.

**Register footprint verification.** The walker's needed
registers:

- rdi: input (pid to search for). Read-only after entry.
- rcx: loop index i (1..64). Compared against 64.
- rax: scratch for `&_pid_table` base, then slab pointer, then
  parent_pid load.
- rdx: slab pointer (we need to hold it across the load-and-store
  to `parent_pid @ 4`). Loaded from `[rax + rcx*8]`.

Four registers, all caller-save. No conflict with rsi.

### 3.2 orphan_adopt — body sequence

```
orphan_adopt(pid):                  ; rdi = pid
  mov rcx, 1                        ; loop index i (start at pid 1, skip pid 0)

loop:
  cmp rcx, 64                       ; MAX_PIDS
  ja  done                          ; past end → return

  lea rax, [rip + _pid_table]
  mov rdx, [rax + rcx*8]            ; rdx = _pid_table[i] (slab u64)
  cmp rdx, 0
  je  next                          ; unallocated slot → skip

  mov eax, [rdx + 4]                ; eax = slab->parent_pid (u32 zero-ext)
  cmp rax, rdi                      ; compare with target pid (both zero-ext u32)
  jne next                          ; different parent → skip

  ; match — rewrite parent_pid to 1
  mov eax, 1
  mov [rdx + 4], eax                ; slab->parent_pid = 1

next:
  add rcx, 1
  jmp loop

done:
  ret
```

**Skip pid 0.** The loop starts at `rcx = 1`. Pid 0 is the
reserved sentinel (task_pool §3.9): `_pid_table[0]` is never
written by task_new (pid_alloc starts at index 1). Reading
`_pid_table[0]` would return the .bss-initial zero, and the
`cmp rdx, 0; je next` guard would correctly skip. Starting at 1
just saves one iteration and documents intent.

**Skip pid 1 (init).** Not skipped. If init (pid 1) somehow has
`parent_pid == arg` (impossible in normal ops — init's
parent_pid is always 0), the walker would try to rewrite init's
parent_pid to 1, making init its own parent. Defensive against
malformed input, but not currently reachable. §6.5 backtrack E
proposes explicit skip.

**Idempotence.** Running orphan_adopt(P) twice on the same state
produces the same state — the first pass sets all matching
parent_pids to 1; the second pass finds no matches (they're all
1 now, none equal P), so it's a no-op. Matches the R15.M6
crash-safety discipline (any body that runs after a crash-recover
must be re-runnable).

**No lock, no interrupt disable.** At R15.M6 single-CPU, the
scan happens inside sys_exit_body which is called from a witness
context (no IRQs). Once sys_exit_body ships from a real syscall
entry (deferred), the syscall path enters with IRQs disabled per
the R14b syscall discipline (see #506). The walker inherits that
disabled state; no explicit `cli/sti`.

### 3.3 sys_exit_body integration — the 5-instruction patch

Insert a call to orphan_adopt between step 2 and step 3 of
`sys_exit_body` (see design/kernel/r15-m6-006-sys-exit.md §3.3
for the six-step layout).

**Current body (excerpt, lines 36-47 of sys_exit.pdx):**

```asm
; ===== step 1: current->state = STATE_ZOMBIE =====
mov rax, 3;
mov [rdi + 8], eax;

; ===== step 2: current->exit_status = status =====
mov [rdi + 12], esi;

; ===== step 3: parent_pid = current->parent_pid =====
mov ecx, [rdi + 4];
cmp rcx, 0;
je sys_exit_done;
```

**Patched body (step 2.5 inserted):**

```asm
; ===== step 1: current->state = STATE_ZOMBIE =====
mov rax, 3;
mov [rdi + 8], eax;

; ===== step 2: current->exit_status = status =====
mov [rdi + 12], esi;

; ===== step 2.5: reparent our children to init (pid 1) =====
mov eax, [rdi + 0];              ; current->pid (u32 zero-ext)
push rdi;                         ; save current across nested call
mov rdi, rax;                     ; arg = our pid
call orphan_adopt;                ; scans _pid_table; preserves rsi
pop rdi;                          ; restore current

; ===== step 3: parent_pid = current->parent_pid =====
mov ecx, [rdi + 4];
cmp rcx, 0;
je sys_exit_done;
```

**Stack alignment.** Entry to sys_exit_body: caller's `call`
instruction pushes retaddr → `rsp mod 16 == 8`. After `push
rdi` → `rsp mod 16 == 0` (aligned for nested call). The
subsequent `call orphan_adopt` pushes retaddr → orphan_adopt
sees `rsp mod 16 == 8`, which is the standard entry convention.
orphan_adopt does no further pushes (leaf), so its `ret` fires
with the same alignment. After `pop rdi` in sys_exit_body →
`rsp mod 16 == 8`, matching sys_exit_body's entry state. ✓

**Register discipline at the call site.**

| Reg | Live before patch (in sys_exit_body) | Preserved by orphan_adopt? | Action |
|-----|--------------------------------------|----------------------------|--------|
| rdi | current — needed by steps 3, 4, 5, 6 | No (walker uses rdi as arg) | push before, pop after |
| rsi | status — needed by step 6 | Yes (walker designed to preserve) | none |
| rax | already scratch — reloaded step 3 | No (walker uses freely) | none |
| rcx | not yet live (step 3 loads it) | No (walker uses freely) | none |
| r8  | not yet live (step 4 loads it) | Yes (walker doesn't touch) | none |

Only rdi needs bracketing. One push, one pop, plus 3
instructions to marshal the arg → 5 instructions total addition.

**Position choice — why step 2.5.** Three candidate positions:

1. **Before step 1 (before ZOMBIE store).** Rejected: the AC
   "zombie idempotence" (r15-m6-006 §1) requires steps 1+2 to
   complete unconditionally before any early return. Adding a
   call before step 1 lets a bad orphan_adopt (bug or panic)
   leave `current->state` at whatever it was — usually RUNNABLE.
   Downstream sys_wait would then not see the zombie. Reject.

2. **Between step 2 and step 3 (THIS DOC).** ZOMBIE + status
   stores complete first. Then orphan_adopt runs. Then the
   parent-lookup / wakeup path. If orphan_adopt panics, the
   task is already zombie — sys_wait scans (once #556 lands)
   will find it. If orphan_adopt returns normally, all
   orphans are reparented before the parent's own sys_wait
   parent may observe the zombie state. Adopted.

3. **After step 6 (after wakeup).** Adopted-orphan reparenting
   would happen AFTER the parent's wake — meaning the parent
   wakes from sys_wait and observes children whose parent_pid
   still equals the (now-zombie) parent's pid. If the parent
   itself reads children's parent_pid (unlikely in R15.M6 but
   possible in R17+ ptrace flow), it sees a stale value.
   Reject — semantic hazard for future scenarios.

Position 2 is a load-bearing invariant: **orphans are reparented
before the wakeup notification propagates**. Step 6 signals "your
child (me) died"; by the time signal reaches parent, my former
children have their reparent already visible.

### 3.4 File and module structure

The helper lives in the SAME file as `sys_exit_body`
(`src/kernel/core/syscall/handlers/sys_exit.pdx`). Two reasons:

1. **Locality.** Only sys_exit_body calls orphan_adopt at R15.M6.
   Co-locating them within one module lets the reader see the
   full sys_exit teardown flow (state → orphans → parent-wake)
   in one file.

2. **Migration ease.** When #550 lands and orphan_adopt moves
   to `task_free`, both the helper AND the CALL migrate
   together. Splitting the helper into its own file now would
   require two migration steps later.

**Alternative rejected.** Placing orphan_adopt in
`src/kernel/core/sched/task_pool.pdx` next to `_pid_table` is
locally natural (walker + table in one file) but breaks the
"one call site, one file" locality principle we've followed
across R15.M5 / R15.M6. §6.6 backtrack F retains the option.

**Full patched module skeleton (deltas only):**

```pdx
// src/kernel/core/syscall/handlers/sys_exit.pdx — R15-M6-006/007

module SysExit = structure {
  // ... existing STATE_* and TASK_OFF_* constants unchanged ...

  // ==========================================================================
  // R15-M6-007 (#558): orphan_adopt — reparent orphans to init (pid 1)
  // ==========================================================================
  pub let orphan_adopt : (u64) -> () !{mem} @{} =
    fn (pid: u64) -> unsafe {
      effects: {mem},
      capabilities: {},
      justification: "R15-M6-007 (#558): Walk _pid_table[1..64]. For each allocated slot whose parent_pid @ 4 equals `pid`, rewrite it to 1 (init sentinel). Leaf function — no nested calls, no callee-save prologue. Registers: rdi (input, read-only after entry), rcx (loop index), rax (scratch — base load / parent_pid load / imm 1), rdx (slab pointer). NOT touched: rsi, r8-r11, callee-save regs — sys_exit_body relies on this to avoid bracketing rsi (status) across the call. Idempotent: running twice is a no-op after the first pass (matching parent_pids get set to 1; second pass finds no matches since 1 != pid for pid >= 2). Loop starts at index 1 to skip pid 0 (reserved sentinel; task_new never writes _pid_table[0]). Bound: fixed 64 iterations at R15.M6; when pid space grows past 64 (R16+), the bound becomes a constant symbol. No IRQ discipline required at R15.M6 single-CPU (sys_exit_body caller inherits disabled IRQs from syscall entry once wrapper lands).",
      block: {
        mov rcx, 1;                          // loop start

      orphan_adopt_loop:
        cmp rcx, 64;                         // MAX_PIDS
        ja orphan_adopt_done;                // past end

        lea rax, [rip + _pid_table];
        mov rdx, [rax + rcx*8];              // slab
        cmp rdx, 0;
        je orphan_adopt_next;                // unallocated

        mov eax, [rdx + 4];                  // slab->parent_pid (u32)
        cmp rax, rdi;                        // == our pid?
        jne orphan_adopt_next;

        mov eax, 1;                          // init pid
        mov [rdx + 4], eax;                  // rewrite

      orphan_adopt_next:
        add rcx, 1;
        jmp orphan_adopt_loop;

      orphan_adopt_done:
        ret
      }
    }

  // ==========================================================================
  // R15-M6-006 (#557): sys_exit_body — PATCHED at step 2.5 to call orphan_adopt
  // ==========================================================================
  pub let sys_exit_body : (u64, u64) -> () !{mem} @{} =
    fn (current: u64) (status: u64) -> unsafe {
      effects: {mem},
      capabilities: {},
      justification: "R15-M6-006 (#557) + R15-M6-007 (#558) patch: sys_exit body with orphan-adoption. Six steps + step 2.5. See design/kernel/r15-m6-006-sys-exit.md §3.3 for the six-step body semantics and design/kernel/r15-m6-007-orphan-adoption.md §3.3 for the step-2.5 insertion. Register discipline change from the leaf version: sys_exit_body is no longer a leaf function — the orphan_adopt call requires stack alignment (satisfied by 1 push of rdi) and rdi bracketing (rdi is caller-save from orphan_adopt's view; sys_exit_body saves it explicitly). rsi is preserved by orphan_adopt's design; no bracket needed. All other regs (r8, r9, r10, r11) unused before the call and unaffected. Total addition: 5 instructions between step 2 and step 3.",
      block: {
        // ===== step 1: current->state = STATE_ZOMBIE =====
        mov rax, 3;
        mov [rdi + 8], eax;

        // ===== step 2: current->exit_status = status =====
        mov [rdi + 12], esi;

        // ===== step 2.5 (R15-M6-007 / #558): reparent orphans to init =====
        mov eax, [rdi + 0];                  // current->pid
        push rdi;                             // save current across call
        mov rdi, rax;                         // arg = our pid
        call orphan_adopt;                    // preserves rsi
        pop rdi;                              // restore current

        // ===== step 3: parent_pid = current->parent_pid =====
        mov ecx, [rdi + 4];
        cmp rcx, 0;
        je sys_exit_done;

        // ... rest of body (steps 4, 5, 6) unchanged ...
      }
    }
}
```

Total addition to sys_exit.pdx: ~30 LOC (orphan_adopt body +
justification + step 2.5 patch to sys_exit_body).

### 3.5 State enum interaction

orphan_adopt does NOT read the `state` field of any slab. It
only touches `parent_pid @ 4`. This is deliberate:

- **Allocated but never-run (STATE_NEW=0)** — a child in
  STATE_NEW still has its parent_pid populated by task_new
  (task_pool.pdx:118). If its parent exits before it ever runs,
  it should still be reparented so a future sched_enqueue that
  eventually runs it observes the correct parent.

- **Running (STATE_RUNNABLE=1)** — reparenting a running
  task's parent_pid is safe: the running task's next syscall
  entry reads parent_pid fresh from memory (no cache).

- **Blocked in sys_wait (STATE_WAITING=2)** — the child is
  parked waiting for ITS children to exit (not for the
  reparenting parent to release). Reparenting doesn't wake
  it; sys_wait's own state read continues to work.

- **Already zombie (STATE_ZOMBIE=3)** — a zombie child's
  parent_pid still matters: when sys_wait scans for zombies,
  it needs to know which zombies belong to which parent. If
  the zombie was already parent-linked to the exiting parent,
  reparenting to init means init (or whoever inherits reap
  duty) can eventually reap it.

State-agnostic reparenting is Pareto-simpler than a
state-filtered walker. §6.7 backtrack G proposes state filtering.

### 3.6 Register discipline — no nested calls in orphan_adopt

The endemic register-clobber bug class (referenced in
`f6975ed`, `3e6a550`, #649 post-mortems) requires nested calls.
orphan_adopt has **NO NESTED CALLS** — it's a pure walker over
`_pid_table`.

Registers used by orphan_adopt:

| Register | Role                          | Callee-save? | Prologue push? |
|----------|-------------------------------|--------------|----------------|
| rdi      | pid arg, read-only after entry | caller-save | no             |
| rcx      | loop index i                   | caller-save | no             |
| rax      | scratch (base, load, imm 1)    | caller-save | no             |
| rdx      | slab pointer                   | caller-save | no             |

**All caller-save.** Zero prologue pushes → zero epilogue pops
→ stack pointer round-trips exactly through the ret.

**Preserved (not touched by walker):**
- rsi — critical: caller (sys_exit_body) holds `status` here
- r8, r9, r10, r11 — general caller-save regs unused by walker
- rbx, r12-r15 — all callee-save regs; walker touches none

### 3.7 Encoding notes

| Mnemonic                        | Byte pattern (nominal)          | Audited by                              |
|---------------------------------|---------------------------------|-----------------------------------------|
| `mov rcx, imm32`                | 48 C7 C1 xx xx xx xx           | task_new: init counters                  |
| `cmp rcx, imm8`                 | 48 83 F9 xx                     | pid_alloc:34                             |
| `ja rel8`                       | 77 xx                           | pid_alloc:35                             |
| `lea rax, [rip + sym]`          | 48 8D 05 xx xx xx xx           | pid_alloc:36                             |
| `mov rdx, [rax + rcx*8]`        | 48 8B 14 C8                     | pid_alloc:37 (rax equivalent)            |
| `cmp rdx, imm8`                 | 48 83 FA xx                     | Everywhere                                |
| `je rel8`                       | 74 xx                           | Everywhere                                |
| `mov eax, [rdx + disp8]`        | 8B 42 xx                        | Everywhere                                |
| `cmp rax, rdi`                  | 48 39 F8                        | New pattern — needs verify (§ paideia-as check) |
| `jne rel8`                      | 75 xx                           | Everywhere                                |
| `mov eax, imm32`                | B8 xx xx xx xx                  | Everywhere                                |
| `mov [rdx + disp8], eax`        | 89 42 xx                        | task_pool:118 (`mov [r13 + 4], eax`)     |
| `add rcx, imm8`                 | 48 83 C1 xx                     | pid_alloc:40                             |
| `jmp rel8` / `ret`              | EB xx / C3                      | Everywhere                                |

**cmp rax, rdi verification.** paideia-as test coverage for
`cmp reg64, reg64` is verified via `pid_alloc` (`cmp rax, 0` at
`cmp reg64, imm8`) but reg-to-reg cmp needs an audit.
Cross-check: `sys_execve_body` uses `cmp rax, rcx` at various
sites. Same class of instruction, same REX.W prefix, no gap.

### 3.8 Complexity and cost

- **Time:** O(64) per orphan_adopt call, regardless of orphan
  count. Under 100 cycles on typical hardware.
- **Frequency:** Once per sys_exit. At R15.M6 witness scale
  (~10 sys_exits per boot), total added cost is 1000 cycles.
  Negligible.
- **Space:** ~15 asm instructions in code segment. No .bss, no
  .rodata additions from the helper (the two rodata OK/FAIL
  strings for the witness are separate).

**Scaling.** At MAX_PIDS = 64, O(64) is a fixed constant. When
R16+ grows the pid space to 4096, the walker becomes a hot
path (~64x more work per exit). At that scale, the design
evolves — either a per-parent child list (linked doubly through
the slab), or a two-level `_pid_table` with a "has_children"
bitmap. Both are R16-scope; R15.M6 uses the linear scan.

## 4. Test canary — kernel_main witness block

### 4.1 Witness shape

The user brief specifies a tri-generational cascade:

```
Setup:
  A = task_new(_pid_table[1])       ; A's parent = pid 1 (fake init)
  B = task_new(A)                    ; B's parent = A.pid
  C = task_new(B)                    ; C's parent = B.pid

Assertions before any exit:
  B->parent_pid == A->pid
  C->parent_pid == B->pid

Phase 1: A exits
  sys_exit_body(A, 0)
Assertions after Phase 1:
  A->state == ZOMBIE
  B->parent_pid == 1                  ; B adopted by init
  C->parent_pid == B->pid             ; unchanged (B still alive)

Phase 2: B exits
  sys_exit_body(B, 0)
Assertions after Phase 2:
  B->state == ZOMBIE
  C->parent_pid == 1                  ; C adopted by init

Emit "R15 ORPHAN ADOPT OK\n" and continue boot.
```

### 4.2 Witness storage

No new .bss blob — reuses `_task_pool` and `_pid_table` via
`task_new`. The witness runs after all previous R15.M6 witnesses
(sys_exit, sys_wait, sys_execve), so pid_alloc will return
sequential pids starting from whatever pool position we've
reached. Empirically pids 1-13 are consumed; A/B/C will take
pids 14, 15, 16 (approximate — exact values don't matter, the
witness uses slab pointers).

**MAX_PIDS budget.** _task_pool holds 64 slots. Post-witness
occupancy: ~16 slots. Well within budget.

**Fake init availability.** The witness assumes `_pid_table[1]
!= 0`. This is satisfied by the very first task_new witness
(task_new_witness at kernel_main.pdx:586, `task_new(NULL)` →
gets pid 1). By the time orphan_adoption_witness runs (after
sys_execve_witness), pid 1 has been in _pid_table[1] for the
entire boot. The state of that slab (STATE_NEW) doesn't matter
for reparenting — the reparent step only writes `1` to
`child->parent_pid` and doesn't dereference `_pid_table[1]`. So
whether pid 1 is a "real init" or a witness leftover is
transparent to orphan_adopt.

### 4.3 Witness placement

Add the witness block to `kernel_main.pdx` after
`sys_execve_witness_exit:` (line 1039) and before the
`R14b-m5-002 (#507): IA32_GS_BASE` block (line 1041).

### 4.4 Witness assembly (~85 LOC)

```asm
; ============================================================
; R15-M6-007 (#558): orphan_adopt witness — 3-gen cascade, 1 marker
; ============================================================
orphan_adoption_witness:
    ; ---------- Setup: build A → B → C chain ----------
    ; Load pid-1 slab (fake init from task_new_witness) into rdi as A's parent.
    ; task_new(parent) sets child->parent_pid = parent->pid, so passing the
    ; pid-1 slab makes A->parent_pid = 1. This avoids the parent_pid == 0
    ; case (which sys_exit's step-3 guard treats as "init exiting").
    lea rax, [rip + _pid_table];
    mov rdi, [rax + 8];                          ; _pid_table[1] (SIB scale-8)
    cmp rdi, 0;
    je  orphan_adoption_witness_fail;            ; pid 1 not populated (bug in earlier witness)

    ; A = task_new(_pid_table[1])
    call task_new;
    cmp rax, 0;
    je  orphan_adoption_witness_fail;
    mov r12, rax;                                ; r12 = A slab

    ; B = task_new(A)
    mov rdi, r12;
    call task_new;
    cmp rax, 0;
    je  orphan_adoption_witness_fail;
    mov r13, rax;                                ; r13 = B slab

    ; C = task_new(B)
    mov rdi, r13;
    call task_new;
    cmp rax, 0;
    je  orphan_adoption_witness_fail;
    mov r14, rax;                                ; r14 = C slab

    ; ---------- Pre-exit assertions ----------
    ; Assert: B->parent_pid == A->pid
    mov eax, [r12 + 0];                          ; A->pid
    mov ecx, [r13 + 4];                          ; B->parent_pid
    cmp eax, ecx;
    jne orphan_adoption_witness_fail;

    ; Assert: C->parent_pid == B->pid
    mov eax, [r13 + 0];                          ; B->pid
    mov ecx, [r14 + 4];                          ; C->parent_pid
    cmp eax, ecx;
    jne orphan_adoption_witness_fail;

    ; ---------- Phase 1: A exits ----------
    ; sys_exit_body(A, 0)
    mov rdi, r12;
    xor rsi, rsi;                                 ; status = 0
    call sys_exit_body;

    ; Assert: A->state == STATE_ZOMBIE (3)
    mov eax, [r12 + 8];
    cmp rax, 3;
    jne orphan_adoption_witness_fail;

    ; Assert: B->parent_pid == 1 (adopted)
    mov eax, [r13 + 4];
    cmp rax, 1;
    jne orphan_adoption_witness_fail;

    ; Assert: C->parent_pid == B->pid (unchanged — B still alive)
    mov eax, [r13 + 0];                          ; B->pid
    mov ecx, [r14 + 4];                          ; C->parent_pid
    cmp eax, ecx;
    jne orphan_adoption_witness_fail;

    ; ---------- Phase 2: B exits ----------
    ; sys_exit_body(B, 0)
    mov rdi, r13;
    xor rsi, rsi;
    call sys_exit_body;

    ; Assert: B->state == STATE_ZOMBIE (3)
    mov eax, [r13 + 8];
    cmp rax, 3;
    jne orphan_adoption_witness_fail;

    ; Assert: C->parent_pid == 1 (now adopted)
    mov eax, [r14 + 4];
    cmp rax, 1;
    jne orphan_adoption_witness_fail;

    ; ---------- All checks green ----------
    lea rdi, [rip + orphan_adoption_witness_ok_msg];
    call uart_puts;
    jmp orphan_adoption_witness_exit;

orphan_adoption_witness_fail:
    lea rdi, [rip + orphan_adoption_witness_fail_msg];
    call uart_puts;

orphan_adoption_witness_exit:
```

**Rodata strings (added to `tools/boot_stub.S`):**

```
# R15-M6-007 (#558): orphan_adoption witness success message
.global orphan_adoption_witness_ok_msg
.align 8
orphan_adoption_witness_ok_msg: .ascii "R15 ORPHAN ADOPT OK\n\0"

# R15-M6-007 (#558): orphan_adoption witness failure message
.global orphan_adoption_witness_fail_msg
.align 8
orphan_adoption_witness_fail_msg: .ascii "R15 ORPHAN ADOPT FAIL\n\0"
```

### 4.5 What the nine assertions prove

1. **Pre-1: B->parent_pid == A->pid.** task_new's parent
   linkage (task_pool:118) works — B was constructed with A as
   parent, so B knows it.

2. **Pre-2: C->parent_pid == B->pid.** Same, one generation
   deeper. The chain A→B→C is set up correctly.

3. **Phase 1-1: A->state == ZOMBIE.** sys_exit_body's step 1
   ran (before step 2.5). The patched body still satisfies
   the zombie-idempotence invariant.

4. **Phase 1-2: B->parent_pid == 1.** orphan_adopt scanned
   _pid_table, found B (whose parent_pid == A->pid), rewrote
   B->parent_pid to 1. THIS IS THE PRIMARY ADOPTION PROOF.

5. **Phase 1-3: C->parent_pid == B->pid (unchanged).**
   orphan_adopt correctly skipped C — C's parent_pid == B->pid,
   not A->pid. THIS IS THE CASCADE-CORRECTNESS PROOF: the
   walker only reparents DIRECT children, not grandchildren.

6. **Phase 2-1: B->state == ZOMBIE.** Second sys_exit_body
   call also correctly zombifies.

7. **Phase 2-2: C->parent_pid == 1.** After B's exit,
   orphan_adopt scans and finds C (whose parent_pid == B->pid,
   now rewrites to 1). Two-step cascade complete: A→B→C, then A
   exits (B adopted), then B exits (C adopted).

Combined: 7 field-level assertions on 3 tasks across 2 exit
phases. Covers direct adoption, cascade correctness, and
zombification alongside adoption.

### 4.6 Fingerprint additions

Marker line appended to three fingerprint files:

`tests/r15/expected-boot-r15-process.txt`:

```diff
 R15 SYS EXECVE OK
+R15 ORPHAN ADOPT OK
 IPI OK
```

`tests/r15/expected-boot-r15-ring3.txt`:

```diff
 R15 SYS EXECVE OK
+R15 ORPHAN ADOPT OK
 IPI OK
```

`tests/r14b/expected-boot-r14b-loader.txt`:

```diff
 R15 SYS EXECVE OK
+R15 ORPHAN ADOPT OK
 LOADER OK
```

The 5 pre-R15 fingerprint files (`boot_r8_only`, `boot_r10`,
`boot_r11`, `boot_r12`, `boot_r12_denial`) do NOT need editing —
their contains-in-order matching stays byte-identically green
as long as their required sub-sequences remain in the boot
output.

**Ordering:** `R15 ORPHAN ADOPT OK` slots AFTER
`R15 SYS EXECVE OK` because the witness sits after
sys_execve_witness_exit in kernel_main (line 1039).

### 4.7 What the witness does NOT test (deferred)

- **Interaction with sys_wait scan.** #556 (sys_wait) scans
  _pid_table for zombie children. If a parent's sys_wait fires
  AFTER an orphan_adopt has rewritten some children's
  parent_pid to 1, the parent's scan (predicated on `child->
  parent_pid == self->pid`) correctly excludes the adopted
  children. This behavior is emergent from the two designs
  composed. Explicit sys_wait+orphan_adopt integration witness
  would need to (a) mint a WAITING parent, (b) fork a child,
  (c) fork a grandchild, (d) exit the parent (orphaning child),
  (e) exit the child (which then calls sys_exit → step 5 finds
  init's state != WAITING → no wakeup). This is R15.M6-009
  (fork/exec/wait smoke) territory.

- **Init as a reaper.** No sys_wait loop on pid 1 at R15.M6.
  Zombies accumulate. R17+ init-loop closes this.

- **Concurrent orphan_adopt (SMP).** Impossible at R15.M6
  single-CPU. §6.4 backtrack D.

- **Reparent-race with concurrent task_new.** A future
  task_new that constructs `parent_pid = A.pid` mid-scan would
  miss the reparent. Impossible at R15.M6 single-CPU.

- **Interaction with #558 original scope (task_free-hosted).**
  The task_free-hosted variant, once #550 lands and orphan_adopt
  migrates, must be rewitnessed. §6.1 backtrack A defers the
  witness re-work.

## 5. LOC estimate

| File                                                              | LOC delta |
|-------------------------------------------------------------------|-----------|
| `src/kernel/core/syscall/handlers/sys_exit.pdx` (helper + patch)  | +30       |
| `src/kernel/boot/kernel_main.pdx` (witness block)                 | +85       |
| `tools/boot_stub.S` (2 rodata strings)                            | +8        |
| `tests/r15/expected-boot-r15-process.txt`                         | +1        |
| `tests/r15/expected-boot-r15-ring3.txt`                           | +1        |
| `tests/r14b/expected-boot-r14b-loader.txt`                        | +1        |
| `design/kernel/r15-m6-007-orphan-adoption.md` (this doc)          | +550      |
| **Total**                                                         | **~676**  |

Executable code: ~15 asm lines for the walker + ~5 lines of
step-2.5 patch to sys_exit_body = ~30 LOC in `sys_exit.pdx`.
Witness: ~75 asm lines + ~5 msg refs = ~85 LOC in
`kernel_main.pdx`. Boot_stub rodata: ~8 LOC. Fingerprint: +3.
Design: ~550 LOC.

Same order of magnitude as #557 (~736 LOC total) and #556
(~roughly similar). Well within R15.M6 per-issue budget.

## 6. Backtrack candidates

Ordered by preference.

### 6.1 Backtrack A — Migrate orphan_adopt to task_free when #550 lands

When #550 (task_free) lands, `sys_wait` (from #556) invokes
`task_free(child)` after copying exit_status out. The natural
POSIX-canonical timing for orphan reparenting is either
sys_exit (this doc) or task_free (issue #558's original scope).
Both work; the choice is aesthetic + tactical.

**Consequence.** Move orphan_adopt from
`src/kernel/core/syscall/handlers/sys_exit.pdx` to
`src/kernel/core/sched/task_pool.pdx` (or wherever task_free
lives). Remove the step-2.5 patch from sys_exit_body (delete 5
instructions). Add `call orphan_adopt(zombie->pid)` inside
task_free before the slab-zero and pid_free steps.

**Effort.** ~20-40 LOC across 3 files. Witness needs
adjustment: the current witness triggers reparent via
sys_exit_body; the migrated witness would need to trigger via
task_free (which is called by sys_wait's return path). One
approach: after sys_exit_body, invoke sys_wait_body on the
parent (parent is not WAITING though, so sys_wait returns
without freeing). Alternative: expose a test-only entry point
that invokes task_free directly. Simplest: leave the witness
pointing at the pre-migration sys_exit call site and add a
NEW witness that triggers via task_free once #550 lands.

**Recommend.** Adopt when #550 lands. The migration is a
single-commit change that preserves the semantic (reparent
happens; when it happens shifts from "parent transitions to
ZOMBIE" to "parent's slab is torn down"). No user-visible
behavior change at R15.M6 fixture scale.

### 6.2 Backtrack B — Inline orphan_adopt at the call site

Instead of a separate helper function, inline the walker inside
`sys_exit_body`:

```
step 2.5 (inline):
  mov r9, 1                    ; loop index
loop:
  cmp r9, 64
  ja  done_walk
  lea rax, [rip + _pid_table]
  mov r10, [rax + r9*8]
  cmp r10, 0
  je  next_walk
  mov eax, [r10 + 4]
  mov ecx, [rdi + 0]           ; our pid
  cmp rax, rcx
  jne next_walk
  mov eax, 1
  mov [r10 + 4], eax
next_walk:
  add r9, 1
  jmp loop
done_walk:
```

**Consequence.** No nested call from sys_exit_body → no stack
alignment discipline needed. But sys_exit_body grows by ~15
instructions instead of 5. Uses r9, r10 (previously unused in
sys_exit_body). Register footprint expands.

**Reject.** The 5-instruction patch (§3.3) preserves
sys_exit_body's per-step readability. Inlining dilutes the
six-step semantic that r15-m6-006 §3.3 pins. Retain as
backtrack if a future paideia-as encoder gap surfaces on the
`call` instruction from sys_exit.pdx (currently no such gap —
sys_exit_body already `call task_new` inside the witness path).

### 6.3 Backtrack C — Per-parent child linked list in task_struct

Add a `first_child` field to task_struct and a `next_sibling`
field to each child. task_new appends to parent's list; sys_exit
walks parent's list (not the whole _pid_table). O(children)
instead of O(64).

**Consequence.** Two new fields per task_struct (16 bytes ×
64 = 1024 bytes .bss growth). task_new gains 2 stores (append
to parent list). task_free (or slot recovery) needs to
splice-out from parent list. sys_exit's walker becomes a
linked-list traversal — no bugs at R15.M6, but a bigger
substrate.

**Reject at R15.M6.** O(64) is unnoticeable. Reconsider at
R16+ when pid space grows past 4096 and the walker becomes a
hot path. The two field additions cascade to task_struct layout
freeze (#549 §3.1) and would require a re-freeze cycle.

### 6.4 Backtrack D — Atomic scan/mark barrier for SMP

At SMP, a concurrent CPU B running `task_new` for
`parent_pid = A.pid` could publish the new child in
_pid_table between CPU A's orphan_adopt scan pointer moving
past that index and CPU A's ZOMBIE-state publish. The new child
misses reparent.

**Fix.** Wrap orphan_adopt in a per-parent lock, OR set
`A->state = ZOMBIE` FIRST (before scan) so task_new can check
"is my requested parent already zombie? if so, use init instead"
before publishing.

**Consequence.** Adds either a per-task lock (space + acquire
cost) or a task_new guard (adds `cmp parent->state, ZOMBIE`
check to task_new). Also potentially wants a memory fence
between ZOMBIE store and scan to prevent CPU-B from seeing
scanned state before ZOMBIE.

**Defer to R15.M7 (SMP promotion).** R15.M6 single-CPU makes
the race unreachable. This backtrack is filed for the R15.M7
concurrency audit, not a landing gate.

### 6.5 Backtrack E — Explicit skip of pid 1 in walker

Add a `cmp rcx, 1; je next` inside orphan_adopt_loop to
guarantee init's parent_pid is never rewritten by the walker,
even if init has parent_pid == arg (impossible in normal ops
since init's parent_pid is 0, but defensive).

**Consequence.** 2 more instructions in walker. Cost ~1
cycle per iteration in the amortized loop.

**Neutral.** Retain as follow-up if a bug is ever observed
where init's parent_pid gets rewritten. Currently not
observable; not a landing gate.

### 6.6 Backtrack F — Move orphan_adopt to task_pool.pdx

Locate the helper next to `_pid_table` (which it walks). Both
live in `src/kernel/core/sched/task_pool.pdx`.

**Consequence.** Helper location is more "logical" (data +
walker in one file). But the CALL SITE is still in
sys_exit.pdx, so the reader reading sys_exit_body has to jump
files to see the walker.

**Neutral.** Aesthetic. At R15.M6 with one call site, the
co-location in sys_exit.pdx (§3.4) wins. When multiple
sys_exit-adjacent files start invoking orphan_adopt (e.g.
task_free after #550), promoting the helper to task_pool.pdx
becomes clearly preferred. Flagged for the #550 migration.

### 6.7 Backtrack G — State-filtered reparenting

Reparent only children in specific states (e.g., skip
STATE_ZOMBIE — a zombie child doesn't need a live parent to
reap it, since sys_wait can scan any parent's children).

**Consequence.** Extra `cmp [rdx + 8], STATE_ZOMBIE; je next`
in walker. Zombie children retain their original parent_pid;
if that parent is zombie too, sys_wait's scan needs to handle
the chain. Adds semantic complexity — parent-of-zombie is
never reap-eligible, so there's no downside to leaving
parent_pid stale.

**Neutral.** The state-agnostic version (this doc) is simpler
and correct at R15.M6. State filtering becomes interesting
when sys_wait scans efficiency matters (R16+).

## 7. Tractability

**HIGH.**

- No new paideia-as encoder gap — all mnemonics audited via
  #545 (pid_alloc walker), #548 (task_new), and existing
  cmp/mov patterns. The one new pattern `cmp rax, rdi` is a
  standard `cmp reg64, reg64` (opcode 48 39 F8), which
  paideia-as encodes via the same path as `cmp rax, rcx`
  (audited by sys_execve_body). Cross-verified.
- No new interrupt / MSR / CR3 discipline. Leaf walker
  function; no privilege-level changes.
- No new directory or file — helper piggybacks on existing
  `src/kernel/core/syscall/handlers/sys_exit.pdx`.
- ~15 asm LOC of walker + ~5 lines of step-2.5 patch + ~75
  LOC of witness. Comparable to R15.M6-006 (#557) witness
  scale.
- Register discipline is *trivially* correct — orphan_adopt
  has zero nested calls (endemic bug class unreachable), and
  the sys_exit_body call site pushes rdi once (stack alignment
  preserved with 8+16 arithmetic).
- Witness driver reuses `task_new` (LANDED) and the fake init
  (`_pid_table[1]`) that exists from the very first
  task_new_witness. No new infrastructure.
- Marker line is contains-in-order across three fingerprint
  files, none of which is broken by an extra line.
- Backtrack path for #550 (task_free landing) is well-scoped
  and 1-line at the CALL SITE.

Known follow-ups (not blockers for #558):

- **#550 (task_free real)** — when it lands, migrate
  orphan_adopt CALL from sys_exit_body to task_free. §6.1.
- **#556 (sys_wait real)** — sys_wait's scan naturally
  interacts with reparented children (they're excluded from
  a parent's scan by parent_pid mismatch). No design change
  needed.
- **#560 (fork/exec/wait smoke)** — end-to-end validation
  that the ZOMBIE→adopted→(future_wait) cycle holds up.
- **Real init loop (R17+)** — pid 1 becomes a WAITING task
  that reaps orphaned zombies. Enables true POSIX-style
  orphan management.

## 8. Cross-cutting risks

- **Fake init timing.** The witness assumes `_pid_table[1] !=
  0` at witness time. Verified: task_new_witness runs first
  in boot (line 586) and calls `task_new(NULL)` → gets pid 1
  → publishes _pid_table[1]. If a future boot re-ordering
  moves orphan_adoption_witness before task_new_witness, the
  precondition `_pid_table[1] != 0` breaks. Mitigation: the
  witness includes an explicit `cmp rdi, 0; je fail` after
  the load of `_pid_table[1]`, giving a clear FAIL rather
  than a silent-wrong-behavior.
- **Fake init state.** Fake init is in STATE_NEW (0), not
  WAITING. If a future orphan calls sys_exit_body, its
  step-4 lookup finds init's slab; step-5 guard sees state ==
  NEW (not WAITING); skips wakeup; zombie left for future
  reap. Consistent with the design — zombies accumulate. No
  panic.
- **sys_exit_body no longer a leaf function.** Prior to this
  patch, sys_exit_body was leaf (no nested calls, no push).
  After this patch, sys_exit_body has one nested call
  (orphan_adopt) with a push/pop bracket around rdi.
  Consequence: any future edit that touches sys_exit_body
  MUST maintain the push/pop bracket, OR remove it if the
  call is removed. The 5-instruction diff-window makes the
  invariant obvious in code review. Justification string
  documents the shift explicitly.
- **rsi preservation invariant across orphan_adopt call.**
  Load-bearing: sys_exit_body relies on rsi surviving. If a
  future edit to orphan_adopt adds a use of rsi (e.g., as a
  loop scratch), sys_exit_body's step 6 will silently store
  garbage to `parent->wait_result_status`. Mitigation: the
  orphan_adopt justification string pins "NOT touched: rsi";
  any future edit must preserve this contract. If needed,
  add a bracketing push/pop of rsi in sys_exit_body — 2
  extra instructions.
- **State-agnostic reparenting quirk.** A child in STATE_NEW
  gets reparented even though it never ran. When it
  eventually runs and calls sys_exit, its parent_pid points
  to init. Semantically: "you were adopted before you woke
  up." Matches POSIX-style adopt-at-any-state; no bug.
- **Fingerprint drift across 3 files.** Adding "R15 ORPHAN
  ADOPT OK" to three fingerprint files must land in the
  same commit as the code. Missing any → smoke false
  negative. Mitigation: pre-push hook blocks pushes that
  fail smoke; drift caught locally.
- **AC interpretation — "A forks B, B forks C, A exits;
  C's parent_pid is now 1".** The literal reading is
  incorrect for a single-exit chain (A exiting only
  reparents B, not C). The witness resolves this by
  running a 2-phase cascade (A exits, then B exits) to
  eventually satisfy "C's parent_pid is now 1". Mitigation:
  §4 documents the interpretation explicitly.
- **Cascade timing under real workload.** In a real
  scheduler world, B might exit before A does (child dies
  before parent). In that case A's exit reparents its
  REMAINING children (all still parented on A) to init. C
  was already parented on B (B is zombie), so C's parent_pid
  is still B.pid → B is zombie → C's future sys_exit sees
  parent slab @ [_pid_table[B.pid]] which... is still there
  until B is reaped (sys_wait time). No dangling pointer.
  Once B is reaped, _pid_table[B.pid] goes to 0; C's future
  sys_exit hits step-4 defensive branch (parent gone) and
  leaves itself zombie. Reparent-to-init would be needed at
  sys_wait's reap time. THIS IS THE BUG THE #550-hosted
  version was intended to solve. §6.1 backtrack A is
  therefore not just aesthetic — it closes this correctness
  hole for the "grandparent exits after grandchild" case.
  Flagged for the #550 migration cycle.

## 9. Backtrack markers

For the debugger-agent if the witness reports FAIL:

| Symptom                                                        | Root cause hypothesis                                       | Where to look                                              |
|----------------------------------------------------------------|-------------------------------------------------------------|------------------------------------------------------------|
| Fail immediately, before any task_new                          | `_pid_table[1] == 0` (init witness didn't run first)        | Verify task_new_witness at line 586 fires before this one  |
| Pre-1 fails (B->parent_pid != A->pid)                          | task_new's parent_pid store is broken                       | task_pool.pdx:112-118 — the parent_pid population step     |
| Phase 1-1 fails (A->state != ZOMBIE)                           | sys_exit_body step 1 didn't execute; call to sys_exit broken | sys_exit.pdx:37-38 — step 1 ZOMBIE store                   |
| Phase 1-2 fails (B->parent_pid != 1)                           | orphan_adopt didn't match B's parent_pid                    | Check comparison `cmp rax, rdi` — u32/u64 mismatch?        |
| Phase 1-3 fails (C->parent_pid changed)                        | orphan_adopt over-scanned (matched too broadly)             | Check filter `cmp rax, rdi; jne next` — jne wired correctly? |
| Phase 2-2 fails (C->parent_pid != 1 after B exits)             | orphan_adopt didn't run in second sys_exit_body call        | Check that step 2.5 patch fires unconditionally             |
| Silent hang, no OK/FAIL                                        | Register clobber (rdi lost after orphan_adopt call)          | Check push/pop rdi bracket in step 2.5                     |
| Wrong marker in fingerprint                                    | Marker missing OR line ordering wrong                        | Verify witness runs after sys_execve_witness_exit           |
| rsi clobbered → subsequent sys_wait fails                      | orphan_adopt violated rsi-preservation contract              | orphan_adopt body — any mov/pop touching rsi?              |

## 10. References

- Issue: paideia-os#558
- Milestone: paideia-os milestones (R15.M6 fork / exec / wait / _exit)
- Sibling issues in R15.M6:
  - #552 (aspace_clone_cow), #553 (pf_handler_cow_split)
  - #554 (sys_fork), #555 (sys_execve — LANDED), #556 (sys_wait — LANDED)
  - #557 (sys_exit — LANDED; hosts this doc's step-2.5 patch)
  - #559 (frame_meta refcount — LANDED)
  - #560 (fork/exec/wait smoke)
- Landed prereqs:
  - #548 task_new (`src/kernel/core/sched/task_pool.pdx:71`) — provides _pid_table and slab layout the walker traverses
  - #549 fd_table + task_struct field freeze — pins parent_pid @ offset 4
  - #557 sys_exit_body (`src/kernel/core/syscall/handlers/sys_exit.pdx:30`) — hosts the call site
- Open (task_free chain):
  - #550 task_free real (blocked chain: #660 CR0.WP → #553 pf_handler_cow_split → #552 aspace_clone_cow → #550 task_free)
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 9 issue 7
- Prior-art register-discipline post-mortems:
  - `f6975ed` (phys_alloc callee-save fix)
  - `3e6a550` (self-IPI callee-save audit)
- Prior-art witness pattern:
  - `design/kernel/r15-m6-006-sys-exit.md` §4 (multi-sub-test single-marker witness)
- Prior-art walker over _pid_table:
  - `src/kernel/core/sched/task_pool.pdx:26` (pid_alloc — linear scan, structurally identical to orphan_adopt's outer loop)
- Prior-art fingerprint discipline:
  - `design/kernel/r15-m5-007-fd-table-embed.md` §4.3 (contains-in-order marker addition)
- Prior-art rodata addition to boot_stub.S:
  - `tools/boot_stub.S:355-395` (task_new / pool / sys_exit / sys_wait / sys_execve witness msgs)
