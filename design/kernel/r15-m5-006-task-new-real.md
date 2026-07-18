---
issue: 548
milestone: R15.M5 (Process abstraction — task_struct, PID allocator, fd table)
subsystem: 8 — Process abstraction
prereq:
  - "#543 (task-struct layout freeze — offsets pinned by #549 §3.1; doc-only landing)"
  - "#544 (task_pool slab — `_task_pool[64] @align(4096)` in .bss; not yet landed)"
  - "#545 (pid_alloc — dense-low-first scan of _pid_table[1..64]; not yet landed)"
  - "#547 (task-state-machine — STATE_NEW=0 enum + transition guards; NEW value is the rep-stosq zero)"
  - "R15-M1-001 / #513 (aspace_create_user — LANDED at src/kernel/core/mm/aspace_create.pdx:96)"
  - "paideia-as #1228 (`rep stosb` / `RepStosq` / `RepMovsq` encoding — LANDED; F3 48 AB audited)"
blocks:
  - "#550 (task_free real — witness driver's task_new/task_free round-trip; pins compact pid↔slab mapping)"
  - "#551 (boot_r15_process smoke — fingerprint 'TASK pool ok pids=1,2,3' needs task_new)"
  - "R15.M6-003 (sys_fork — task_new(current) is the fork body's first call)"
  - "R17.M2-005 (kernel_main init bootstrap — task_new(NULL) is init's construction)"
touching:
  - src/kernel/core/sched/task_pool.pdx           (task_new body — new module or extended by #544)
  - src/kernel/boot/kernel_main.pdx               (witness block, ~50 LOC)
  - tests/r15/expected-boot-r15-ring3.txt         (marker line, contains-in-order)
  - tests/r14b/expected-boot-r14b-loader.txt      (marker line, contains-in-order)
  - design/kernel/r15-m5-006-task-new-real.md     (this doc)
related:
  - design/kernel/r15-m5-007-fd-table-embed.md    (task_struct offsets — 0/4/8/16/168/2224)
  - design/kernel/r15-m5-008-task-free-real.md    (§3.6 compact mapping this doc honors)
  - design/kernel/r15-m1-010-phys-free-real-body.md (backs aspace teardown reclamation)
  - design/milestones/r14b-tactical-plan.md §Subsystem 8 (interfaces line 894–898, issue 6 line 946)
---

# R15-M5-006 — task_new real body: pid_alloc + slab index + aspace + zero + populate (#548)

## 1. Scope

Give `task_new` a real body so that:

1. `task_new(NULL)` — the init construction — returns a valid `task_struct*`
   with `pid == 1`, `parent_pid == 0`, `state == STATE_NEW`, a fresh
   `user_pml4_pa` (kernel-half copied, user-half zero), and every other
   byte of the 2224-byte slab set to zero (including `fd_table[0..32]`).
2. `task_new(parent)` for a non-NULL `parent : *task` reads
   `parent->pid` and writes it to `parent_pid`; every other field
   follows the init path.
3. Failure paths are honest: `pid_alloc → 0` (no free pid) or
   `aspace_create_user → 0xFFFFFFFF` (no free pml4 frame) both cause
   `task_new` to return `0` after releasing any pid slot it already
   reserved.

Two invariants define completion:

- **Compact pid↔slab mapping** (pinned by #550 §3.6, honored here):
  `pid_table[pid] == &_task_pool[pid - 1]` for every allocated task.
  `task_new` establishes this identity; `task_free`/`pid_free`
  breaks it via `pid_table[pid] = NULL`.
- **Slab is zeroed before any field write.** `rep stosq` clears all
  278 qwords (2224 bytes) *before* the field-populate step, so
  no stale byte survives from a previous occupant. This is what
  makes `task_new → task_free × 100` a byte-conservative round-trip
  (the #550 witness's central AC).

Explicitly out of scope (deferred):

- **Kernel stack allocation.** `kernel_stack` @ offset 24 is left
  at 0. R15.M6-001 (`sched_enqueue`) grows a per-task kernel stack
  from a magazine allocator when the task first becomes runnable;
  R15.M5 tasks never run, they're just constructed.
- **regs_save initialization.** `regs_save[0..15]` @ offset 32
  stays zero. R15.M6-002 (`sys_execve`) populates it with the
  ring-3 entry frame at execve time. A NEW task doesn't need
  register state — it never runs.
- **fd[0..2] population.** The reservation discipline is #549's:
  `fd_alloc` skips fds 0/1/2 unconditionally, so they stay at
  sentinel-0 until #1613 (`connect-tty-to-init-fd012`) writes
  tty0 into task[1].fd[0/1/2].
- **State machine wire-up.** #547 lands the STATE_NEW → RUNNABLE
  transition guard. `task_new` here writes the raw value `0`
  (which is STATE_NEW after #547 lands). Wire-up is #547's concern.
- **Rollback of aspace_create_user on later failure.** This body
  has no later failure — aspace_create_user is the *last* fallible
  step. If it succeeds, the whole function succeeds. So no
  aspace teardown rollback path is needed here.
- **Kernel-thread tasks (no aspace).** All R15.M5 tasks get a
  real user aspace. Kernel-thread task_structs (aspace = 0) are
  a future concern; §6.3 backtrack covers the NULL-guard split.

## 2. Prereq check

### 2.1 What's in place

| Primitive                    | Location                                        | Contract used by task_new                          |
|------------------------------|-------------------------------------------------|----------------------------------------------------|
| `aspace_create_user()`       | `core/mm/aspace_create.pdx:96`                  | `() -> u64 !{mem} @{}`. Returns pml4_pa or `0xFFFFFFFF` (ASPACE_CREATE_OOM). Callee-saves `r12/r13/r14` per prior art. |
| `phys_alloc(0)`              | `core/mm/phys_alloc.pdx:22`                     | Backs aspace_create_user's inner pml4 allocation. |
| `phys_alloc_free_count()`    | `core/mm/phys_alloc.pdx:114`                    | Backs the witness's round-trip stability check.   |
| `rep stosq`                  | paideia-as PA-R13-012 audit; `F3 48 AB` encoding | Zero 2224-byte slab in one instruction.          |
| `mov [reg + disp8], reg32`   | fd_table.pdx SIB+disp encoding audit            | Field stores (pid, parent_pid, state) — u32 slots. |
| `mov [reg + reg*8], reg64`   | fd_table.pdx line 36 (fd_set)                   | pid_table[pid] = slab_addr — scale-8 store.       |
| `lea r64, [rip + sym]`       | Every RIP-rel access in this codebase           | `&_task_pool`, `&_pid_table` base loads.         |
| Callee-save discipline       | phys_alloc (`f6195ed`), aspace_teardown, aspace_create | Prior art: 3-5 push prologue, matching pop epilogue. |

### 2.2 What is not in place — required prerequisites this doc consumes on faith

`task_new` cannot land before three code-level prerequisites:

- **#543** — task_struct layout freeze doc. This design references
  offsets `0 (pid)`, `4 (parent_pid)`, `8 (state)`, `16 (user_pml4_pa)`,
  `168..424 (fd_table)`, and `2224 (total size)` as pinned. #549's
  landed doc already fixed those values (`r15-m5-007-fd-table-embed.md`
  §3.1); #543 is a doc-only ratification. Design is internally
  consistent even before #543 lands.
- **#544** — `_task_pool : [u64; 64 * 512] @align(4096)` static
  `.bss` region. Layout confirmed as identical to `_phys_page_pool`
  (`phys_pool.pdx:25`, `[u64; 524288] @align(4096)`) — no encoder
  gap. This design assumes the pool's base symbol is `_task_pool`
  and each entry is contiguous 4 KiB (matches #550 §3.6 and #550
  §3.7 module layout).
- **#545** — `pid_alloc` linear scan of `_pid_table[1..64]` for the
  first NULL slot, returns pid ∈ [1, MAX_PIDS] or 0 on -EAGAIN.
  §3.9 of this doc pins the contract this issue relies on.
- **#547** — task-state-machine STATE_NEW = 0 constant. This body
  writes state = 0 directly; #547 formalizes that value as the
  named enum variant. No code coupling to the enum type until
  #547 wires the transition guard into `sched_enqueue`.

### 2.3 pid_alloc contract pinned by this doc (for #545)

`task_new` calls `pid_alloc()` and relies on:

```
pid_alloc : () -> u64 !{mem} @{}
  Effect: linear scan of _pid_table[1..MAX_PIDS] for the first
    NULL slot. Does NOT modify _pid_table (task_new writes the
    slab pointer in step 6 below). At R15.M5 single-CPU with no
    preemption inside task_new, the non-reservation is race-free:
    no interleaved caller sees the returned pid between pid_alloc
    return and the pid_table[pid] = slab_addr store.
  Return: pid ∈ [1, 64] on success; 0 on -EAGAIN (no free slot).
  Registers: callee-save clean (rbx, r12-r15 preserved).
```

The alternative (pid_alloc writes a reservation sentinel that
task_new overwrites) is discussed in §6.1 backtrack A. It buys
R15.M6 fork's SMP correctness for one extra store per allocation
and one extra store per free — cheap, but not needed at R15.M5.
Locking in the non-reservation contract now means #545 lands
without a wasted write; §6.1's promotion is a one-line addition
to pid_alloc at R15.M6-001 time.

### 2.4 Encoder gaps

**None.** The task_new body uses only:

- Register-to-register `mov`, `xor`, `test`, `cmp`, `push`, `pop`, `sub`, `shl`, `add`
- `rep stosq` — audited by `tools/paideia-as/tests/build-emit/rep_stosq_smoke.pdx`
- `call` cross-module — used in every `.pdx` in `core/`
- `mov r64, [rip + sym]` / `lea r64, [rip + sym]` — RIP-rel
- `mov [reg + disp8], reg32/64` — audited by fd_table SIB+disp
- `mov [reg + reg*8], reg64` — audited by fd_table.pdx:36 (fd_set)
- `je / jz / ret`

No SIB scaling on extended base registers is required (which would
trigger PA-#928 — aspace_teardown.pdx:37 documents the workaround).
Two SIB expressions are used but both use `rcx` as base
(`_pid_table` write in step 6) or as index (r12*8), neither of
which is REX.B-extended.

## 3. Design

### 3.1 Body sequence — seven steps, one rationale

```
task_new(parent: *task) -> *task:
  step 1  save callee-save regs (rbx, r12, r13) + capture parent into rbx
  step 2  pid = pid_alloc()          [→ r12; fail path: return 0]
  step 3  slab = &_task_pool + (pid - 1) * 4096    [→ r13]
  step 4  pml4_pa = aspace_create_user()  [→ rax; on OOM: pid_free(pid), return 0]
  step 5  rep stosq — zero 278 qwords (2224 bytes) at slab
  step 6  populate fields: pid, parent_pid, user_pml4_pa
           (state stays at rep-stosq zero == STATE_NEW)
  step 7  pid_table[pid] = slab
  ret     rax = slab
```

**Why this order.**

1. **pid_alloc first (step 2).** Cheapest failure path. If we're
   out of pids, no aspace was allocated so no rollback is needed.
   Returning 0 immediately is the simplest recovery.

2. **Slab index arithmetic before aspace (step 3).** Pure register
   arithmetic; no memory writes yet. Preparing `r13 = slab_addr`
   makes step 5's `rep stosq` a one-line load into `rdi`.
   Also — crucially — no observable state is committed to the
   slab yet, so the aspace failure path (step 4) can bail cleanly.

3. **aspace_create_user before rep stosq (step 4 before step 5).**
   This is the *last* fallible step. If it fails, we haven't
   touched a single byte of the slab (steps 5–7 not run). The
   only rollback needed is `pid_free(pid)` — no slab zero, no
   pid_table repair.

   The alternative (rep stosq first, then aspace_create_user)
   would leave a zeroed but "half-alive" slab if OOM struck at
   step 4: the slab would look like a NEW task from any casual
   observer, but no aspace and no pid_table entry — a phantom.
   Doing aspace first avoids this class of intermediate state.

4. **rep stosq before field population (step 5 before step 6).**
   Absolute discipline: no field write survives from a previous
   occupant. `rep stosq` zeroes all 278 qwords in one microcoded
   burst; then step 6's five field stores overwrite specific
   slots. Because step 6 writes exactly the fields that need
   non-zero values (pid, parent_pid, user_pml4_pa), every other
   field — including `state @ 8` — remains at its rep-stosq
   zero, which is `STATE_NEW`. This is why the ordering is not
   `populate then zero the rest`; that would need a piecewise
   zero pass and an ordering constraint on which fields to
   preserve.

5. **pid_table write LAST (step 7).** The slab is fully
   constructed before it becomes discoverable via
   `pid_table[pid]`. At R15.M5 single-CPU with no preemption
   inside task_new this is design hygiene, not a correctness
   requirement. At R15.M6 SMP fork, a concurrent
   `pid_alloc → task_new` on another CPU could see the pid_table
   entry *before* the slab is populated if the order were
   reversed — leading to a torn-read hazard. Pinning "table last"
   now closes that door.

6. **state = NEW is free.** `rep stosq` zeroes offset 8 to `0`;
   `STATE_NEW = 0` (per #547). No explicit `mov [r13 + 8], 0`
   is required — but §3.6 discusses whether to write it anyway
   for defensive documentation. Design choice: **skip the write.**
   The zero is documented in this doc + the justification string;
   redundant hardware instructions are Pareto-inferior.

### 3.2 Register discipline — the debugger-endemic bug class this design avoids

Recent PaideiaOS post-mortems (`f6195ed` — phys_alloc r12–r15 fix;
`3e6a550` — self-IPI callee-save audit) established that register
clobber across nested calls is the endemic bug class. `task_new`
holds three pieces of state — `parent`, `pid`, `slab_addr` —
across two nested calls (`pid_alloc`, `aspace_create_user`) and
one microcoded op (`rep stosq` clobbers `rax/rcx/rdi` but those
are caller-save; no discipline needed for callee-save).

**Prologue / epilogue.**

```
task_new_prologue:
    push rbx        ; save because we use rbx = parent (u64)
    push r12        ; save because we use r12 = pid (u64, low 32 bits meaningful)
    push r13        ; save because we use r13 = slab_addr (u64)
    ; 3 pushes = 24 bytes.
    ; Entry rsp ≡ 8 mod 16 (call pushed return address).
    ; After 3 pushes: rsp = 8 + 24 = 32 ≡ 0 mod 16. STACK ALIGNED at nested calls.

    mov rbx, rdi                    ; rbx = parent (survives all nested calls)

    ; ... steps 2-7 use rbx/r12/r13 freely; nested calls preserve them ...

task_new_epilogue:
    mov rax, r13                    ; return slab_addr
    pop r13
    pop r12
    pop rbx
    ret

task_new_fail_return:
    xor eax, eax                    ; return 0 = failure sentinel
    pop r13
    pop r12
    pop rbx
    ret
```

**Stack alignment.** After `call task_new` pushes the return
address, `rsp ≡ 8 mod 16`. Three prologue pushes bring `rsp` to
`8 + 24 = 32 ≡ 0 mod 16`. Every nested `call pid_alloc`,
`call aspace_create_user`, `call pid_free` (only on OOM rollback)
sees `rsp ≡ 0 mod 16` — SysV compliant. If a future edit adds a
4th push, restore alignment with `sub rsp, 8` / `add rsp, 8`
around the call block, matching the aspace_teardown 5-push
pattern (which lands `rsp ≡ 0` with 5 pushes because it doesn't
manage return values by convention).

**Cross-call save/restore.** `pid_alloc`, `aspace_create_user`,
and `pid_free` all follow the codebase's callee-save discipline:
they push/pop what they clobber (aspace_create.pdx lines 44–51
save r12/r13/r14 explicitly; phys_alloc post-`f6195ed` does the
same). No extra push/pop inside the body is needed — the
3-push prologue covers the whole function.

**Post-aspace_create_user register handling.** `aspace_create_user`
returns `pml4_pa` in `rax`. We need to hold this across
`rep stosq` (which clobbers `rax`, `rcx`, `rdi`). Two options:

- **Option A: stash on stack.** `push rax; rep stosq; pop rax`.
  Simple, but complicates alignment: after the push, `rsp ≡ 8
  mod 16`, and if anything called between push and pop, that
  callee sees a misaligned stack. `rep stosq` isn't a call, so
  it's fine — but a future edit that inserts a call would silently
  break. **Adopted with a comment.**
- **Option B: use r14 as extra callee-save.** Adds one push
  (4 total = 32-byte prologue), keeps alignment invariant robust
  to future edits. **Backtracked to §6.2** — not adopted because
  we don't need r14 for anything else and the 3-push prologue
  is minimal.

Adopting Option A, the pml4_pa lives on stack for exactly the
duration of the 5-instruction `rep stosq` block. No call is
issued between the `push rax` and `pop rcx`; alignment is
irrelevant because `rep stosq` is not a call site.

### 3.3 Step 3 — slab index arithmetic

At R15.M5 with the compact pid↔slab mapping (§3.9 / #550 §3.6):

```
slab_addr = &_task_pool + (pid - 1) * TASK_STRUCT_SIZE_ROUNDED
        = &_task_pool + (pid - 1) * 4096
        = &_task_pool + ((pid - 1) << 12)
```

pid is in `[1, 64]` so `(pid - 1) ∈ [0, 63]`, and `(pid - 1) << 12`
yields offsets `[0, 63 * 4096]` = `[0, 258048]` — safely inside
the pool's `64 * 4096 = 262144`-byte extent.

Assembly:

```
    lea r13, [rip + _task_pool]     ; r13 = &_task_pool[0]
    mov rcx, r12                    ; rcx = pid
    sub rcx, 1                      ; rcx = pid - 1
    shl rcx, 12                     ; rcx = (pid - 1) << 12
    add r13, rcx                    ; r13 = &_task_pool[pid-1]
```

Five instructions, all in registers. No memory access. The
`lea [rip + _task_pool]` RIP-rel is the same pattern used by
kpti.pdx line 246 for `_kernel_pml4_pa` — audited substrate.

**Why not SIB with scale-8 × 512?** `mov r13, [rip + _task_pool]`
+ `lea r13, [r13 + r12*4096]` would be shorter, but `*4096`
isn't a valid SIB scale (only 1/2/4/8). The `shl` approach is
one extra instruction and dodges the scale limit cleanly.

### 3.4 Step 4 — aspace_create_user integration

```
    call aspace_create_user         ; rax = pml4_pa or 0xFFFFFFFF
    mov rcx, 0xFFFFFFFF
    cmp rax, rcx
    je task_new_fail_rollback
    ; rax = pml4_pa; will use in step 6 after rep stosq
```

**OOM sentinel `0xFFFFFFFF`.** Confirmed by
`aspace_create.pdx:87` (`aspace_create_oom` returns
`ASPACE_CREATE_OOM = 4294967295 = 0xFFFFFFFF`). This is a 32-bit
`-1`, distinguishable from any physical address (which is
`< 2^40` in QEMU / real hw with `PA_MAX_BITS ≤ 52`).

**Failure path.** `task_new_fail_rollback` calls `pid_free(pid)`
to release the pid slot pid_alloc reserved us in step 2, then
falls through to `task_new_fail_return` which returns 0.

```
task_new_fail_rollback:
    mov edi, r12d                   ; rdi = pid (u32 zero-ext)
    call pid_free
    ; fall through to fail return

task_new_fail_return:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret
```

**`pid_free` contract.** Pinned by #550 §3.5: writes
`_pid_table[pid] = NULL`. Two instructions (`lea rax, [rip +
_pid_table]; mov [rax + rdi*8], 0`). Safe to call even though
we haven't yet written pid_table[pid] to anything non-NULL:
`pid_free` unconditionally stores 0, and pid_alloc's contract
(§2.3) says it doesn't modify pid_table either — so pid_table[pid]
was NULL before pid_alloc, still NULL after pid_alloc, and stays
NULL after pid_free. No corruption; the pid slot is releasable
by the next pid_alloc.

### 3.5 Step 5 — slab zero (2224 bytes) via `rep stosq`

```
    push rax                        ; stash pml4_pa (rax = pml4_pa from step 4)
    mov rdi, r13                    ; rdi = slab_addr
    mov rcx, 278                    ; 2224 / 8 = 278 qwords
    xor eax, eax                    ; fill value = 0
    rep stosq
    pop rcx                         ; rcx = pml4_pa (restored)
```

**Encoder support.** `rep stosq` audited by paideia-as
`rep_stosq_smoke.pdx` (PA-R13-012), `F3 48 AB` (3 bytes total).

**Post-condition.** `[r13 + 0..2224)` is all zero. In particular:
- `pid = 0` @ offset 0
- `parent_pid = 0` @ offset 4
- `state = 0 == STATE_NEW` @ offset 8
- `exit_status = 0` @ offset 12
- `user_pml4_pa = 0` @ offset 16 (about to be overwritten)
- `kernel_stack = 0` @ offset 24 (deferred, stays 0 at R15.M5)
- `regs_save[0..15] = 0` @ offsets 32..152
- `sched_next = 0` @ offset 152
- `sched_budget = 0` @ offset 160
- `fd_table[0..32] = 0` @ offsets 168..424 — every fd slot free
- `_fd_reserved = 0` @ offsets 424..1704
- `wait_child_pid = 0` @ offset 1704
- `wait_reply_slot = 0` @ offset 1708
- `reserved = 0` @ offsets 1712..2224

Step 6 overwrites pid, parent_pid, user_pml4_pa. Everything else
stays zeroed — the "STATE_NEW slab" ground state.

**`push rax; pop rcx` around rep stosq.** The push saves
pml4_pa; the pop restores it into rcx (which we can use freely
in step 6; the register choice is arbitrary among caller-save
GPRs). We do NOT re-use rax after rep stosq because rep stosq
leaves rax = 0 unchanged (its role in the instruction is as the
fill value); could pop into rax and it'd overwrite 0 with
pml4_pa — semantically identical. Choosing `rcx` disambiguates
intent from the "fill value" role rax played moments earlier.

**Alignment note.** `_task_pool[i]` is 4 KiB-aligned per #544;
`r13 = _task_pool + (pid-1)*4096` preserves alignment. Any
alignment satisfies `rep stosq`'s 8-byte minimum, and modern x86
fast-strings kicks in on 4 KiB alignment.

**Why `rep stosq` not a hand loop.** One instruction, ≈70 cycles
for 2224 bytes on modern x86. A qword loop is ~5 instructions
per iteration × 278 iterations = ~350 ns. The rep form is
idiomatic and matches the tactical plan's expected `rep stosb`
entry (issue #6 encoder gaps line 950; we adopt `rep stosq`
because the slab is qword-aligned and the win is 8×).

### 3.6 Step 6 — field population

```
    ; rcx = pml4_pa (restored from stash)
    mov [r13 + 16], rcx             ; user_pml4_pa @ 16 (u64)

    ; pid @ 0 (u32) — write low 32 bits of r12
    mov [r13 + 0], r12d

    ; parent_pid @ 4 (u32) — read parent->pid if parent != NULL, else 0
    xor eax, eax                    ; default parent_pid = 0
    test rbx, rbx                   ; rbx = parent pointer
    jz skip_parent_load
    mov eax, [rbx + 0]              ; parent->pid (u32 zero-ext into eax)
skip_parent_load:
    mov [r13 + 4], eax              ; parent_pid @ 4 (u32)

    ; state @ 8 stays at rep-stosq zero == STATE_NEW; no store needed
    ; exit_status @ 12 stays at rep-stosq zero
    ; kernel_stack @ 24 stays at rep-stosq zero (deferred to R15.M6-001)
```

**Three explicit stores** (plus one conditional read for
non-init parent):

1. `mov [r13 + 16], rcx` — u64 store, `mov r/m64, r64` encoding.
   Uses `[reg + disp8]` addressing; no SIB. Audited.
2. `mov [r13 + 0], r12d` — u32 store, `mov r/m32, r32` encoding.
   `[reg + 0]` with disp8=0; no SIB. Audited.
3. `mov [r13 + 4], eax` — u32 store, same as above with disp8=4.

**Parent NULL-handling.** `task_new(NULL)` is init construction:
`parent_pid = 0` sentinel. `task_new(&some_task)` is R15.M6 fork:
`parent_pid = parent->pid`. The `test rbx, rbx; jz` guard handles
both cases in 3 instructions.

**Alternative: task_new takes a u32 parent_pid.** Simpler for
task_new (no memory read); pushes the pid extraction to the
caller. The tactical plan §Subsystem 8 says
`task_new : (parent: *task) -> *task`. This design honors that
signature. If R15.M6 fork wants `task_new(current_task_pid())`
instead, a 3-line change flips the signature; no field-layout
impact. See §6.4 backtrack D.

**Why write pid twice-effective-once.** rep stosq set pid to 0;
step 6 writes r12d over it. Two writes to the same slot are
harmless — the second wins. We do NOT reorder step 6 before
step 5 because that would lose the field to rep stosq.

### 3.7 Step 7 — pid_table[pid] = slab_addr

```
    lea rcx, [rip + _pid_table]     ; rcx = &_pid_table[0]
    mov [rcx + r12*8], r13          ; pid_table[pid] = slab_addr
```

Two instructions. The SIB `[rcx + r12*8]` is safe: neither `rcx`
nor `r12` is a REX.B-extended base (only extended-base+SIB
triggers PA-#928). scale-8 is standard for u64 arrays.

**Compact mapping honored.** `r13 == &_task_pool[pid-1]` by
step 3's construction; the store makes `pid_table[pid] ==
&_task_pool[pid-1]`, which is the invariant #550 §3.6 pins for
this issue.

**"Table last" ordering.** By this point the slab is fully
constructed (steps 5+6 done). Any caller that discovers this
task via `pid_table[pid]` sees a consistent slab. At R15.M5
single-CPU this is aesthetic; at R15.M6 SMP fork this is the
publish-side of the acquire/release pattern that a concurrent
lookup must respect on the load side.

### 3.8 Full `task_new` body — assembly draft

```pdx
pub let task_new : (u64) -> u64 !{mem} @{} =
  fn (parent: u64) -> unsafe {
    effects: {mem},
    capabilities: {},
    justification: "R15-M5-006 (#548): 7-step construction. (1) Save callee-save rbx/r12/r13 (3 pushes align rsp to 16). (2) Capture parent pointer into rbx (survives nested calls; NULL sentinel means init). (3) Call pid_alloc; on 0 (no free slot) return 0. Save pid in r12. (4) Compute slab_addr = &_task_pool + (pid-1)*4096 into r13 via lea + sub + shl + add (no SIB scale-4096; shl 12 instead). (5) Call aspace_create_user; on 0xFFFFFFFF (OOM) call pid_free(pid) to rollback, then return 0. Result pml4_pa saved on stack across rep stosq. (6) rep stosq: 278 qwords × 8 = 2224 bytes zeroed at slab (F3 48 AB; audited by paideia-as PA-R13-012). Also zeros fd_table[0..32] as a side effect — matches the R15.M5 'fd slots are opaque u64, sentinel 0 = free' invariant. (7) Pop pml4_pa into rcx; three field stores: user_pml4_pa @ 16, pid @ 0 (u32), parent_pid @ 4 (u32, derived from parent->pid if parent != NULL else 0). state @ 8 stays at rep-stosq zero == STATE_NEW; no explicit store. (8) pid_table[pid] = slab_addr via SIB store [rcx + r12*8] (rcx = &_pid_table); this is the publish step. (9) Return slab_addr in rax. Register discipline: rbx/r12/r13 preserved via 3-push prologue; nested calls (pid_alloc, aspace_create_user, pid_free) trusted to callee-save per their own justifications. Stack alignment: rsp ≡ 0 mod 16 at every nested call site.",
    block: {
      // ===== prologue: 3-push, capture parent =====
      push rbx;
      push r12;
      push r13;
      mov rbx, rdi;                     // rbx = parent (u64; 0 sentinel for init)

      // ===== step 2: pid_alloc =====
      call pid_alloc;                   // rax = pid or 0
      test rax, rax;
      jz task_new_fail_return;
      mov r12, rax;                     // r12 = pid

      // ===== step 3: slab_addr = &_task_pool + (pid-1)*4096 =====
      lea r13, [rip + _task_pool];
      mov rcx, r12;
      sub rcx, 1;
      shl rcx, 12;                      // *4096
      add r13, rcx;                     // r13 = slab_addr

      // ===== step 4: aspace_create_user =====
      call aspace_create_user;          // rax = pml4_pa or 0xFFFFFFFF
      mov rcx, 4294967295;              // 0xFFFFFFFF (ASPACE_CREATE_OOM)
      cmp rax, rcx;
      je task_new_fail_rollback;

      // ===== step 5: rep stosq — zero 2224 bytes =====
      push rax;                         // stash pml4_pa (rep stosq clobbers rax)
      mov rdi, r13;                     // dst = slab
      mov rcx, 278;                     // 2224/8 qwords
      xor eax, eax;                     // fill = 0
      rep stosq;
      pop rcx;                          // rcx = pml4_pa

      // ===== step 6: populate fields =====
      mov [r13 + 16], rcx;              // user_pml4_pa
      mov [r13 + 0], r12d;              // pid (u32)
      xor eax, eax;                     // default parent_pid = 0
      test rbx, rbx;                    // NULL parent?
      jz task_new_skip_parent_load;
      mov eax, [rbx + 0];               // parent->pid (u32)
    task_new_skip_parent_load:
      mov [r13 + 4], eax;               // parent_pid (u32)
      // state @ 8 stays at rep-stosq zero == STATE_NEW

      // ===== step 7: pid_table[pid] = slab_addr =====
      lea rcx, [rip + _pid_table];
      mov [rcx + r12*8], r13;

      // ===== epilogue: return slab_addr =====
      mov rax, r13;
      pop r13;
      pop r12;
      pop rbx;
      ret;

      // ===== OOM rollback: release pid, then return 0 =====
    task_new_fail_rollback:
      mov edi, r12d;                    // rdi = pid
      call pid_free;
      // fall through

    task_new_fail_return:
      xor eax, eax;
      pop r13;
      pop r12;
      pop rbx;
      ret
    }
  }
```

Total executable LOC: ~40 lines of assembly, ~55 counting the
justification string. Same order of magnitude as #550's task_free
(~30 asm LOC) and #549's fd_alloc (~20 asm LOC).

### 3.9 pid ⇋ slab_index mapping — the compact invariant (honored)

Pinned by #550 §3.6:

```
pid_table[pid] == &_task_pool[pid - 1]     for every allocated pid ∈ [1, 64]
pid_table[0]    == NULL sentinel
pid_table[pid]  == NULL                     for every free pid ∈ [1, 64]
```

`task_new` step 7 establishes the identity `pid_table[pid] =
&_task_pool[pid-1]` and step 3 computes the RHS the same way,
so the invariant is byte-preserved. `task_free`/`pid_free` (in
#550) break the identity by writing `pid_table[pid] = NULL`; the
next `pid_alloc` scans for the first NULL slot and returns `pid`
again — the reuse loop that #550's witness exercises 100 times.

The `task_new(NULL) → pid == 1` first-boot AC follows from the
scan starting at index 1 (skipping the `pid_table[0]` sentinel);
first NULL is at index 1 on a fresh boot.

## 4. Test canary — kernel_main witness block

### 4.1 Witness shape

The AC (from the issue body): `task_new(init) returns a valid
task with pid 1; fresh task has state=new`.

Extended for robustness (matches #550's witness pattern):

- pid == 1 on first call
- state == STATE_NEW (0)
- parent_pid == 0 (NULL parent)
- user_pml4_pa != 0 (aspace_create_user succeeded)
- pid_table[1] == returned slab_addr (mapping invariant)

The witness lives in `kernel_main.pdx` inside
`boot_continue_after_ring3`, between #549's "R15 FD TABLE OK" and
#550's "R15 TASK FREE OK" (which is the direct extension of this
witness — it calls task_new too).

```asm
; ============================================================
; R15-M5-006 (#548): task_new witness — single-call construction
; ============================================================

; task_new(NULL) — construct init.
xor rdi, rdi;                              ; parent = NULL sentinel
call task_new;
cmp rax, 0;
je  task_new_witness_fail;                 ; 0 = OOM = bug at boot

mov r12, rax;                              ; r12 = task_struct*

; Check 1: pid == 1
mov eax, [r12 + 0];                        ; pid @ 0 (u32)
cmp eax, 1;
jne task_new_witness_fail;

; Check 2: parent_pid == 0
mov eax, [r12 + 4];                        ; parent_pid @ 4 (u32)
cmp eax, 0;
jne task_new_witness_fail;

; Check 3: state == STATE_NEW (0)
mov eax, [r12 + 8];                        ; state @ 8 (u32)
cmp eax, 0;
jne task_new_witness_fail;

; Check 4: user_pml4_pa != 0
mov rax, [r12 + 16];                       ; user_pml4_pa @ 16 (u64)
cmp rax, 0;
je  task_new_witness_fail;

; Check 5: pid_table[1] == r12
lea rax, [rip + _pid_table];
mov rcx, [rax + 8];                        ; pid_table[1] (index 1 * 8 = 8)
cmp rcx, r12;
jne task_new_witness_fail;

; All checks green
lea rdi, [rip + task_new_witness_ok_msg];
call uart_puts;
jmp task_new_witness_exit;

task_new_witness_fail:
    lea rdi, [rip + task_new_witness_fail_msg];
    call uart_puts;

task_new_witness_exit:
```

Rodata strings (added to `kernel_main.pdx` alongside
`fd_witness_ok_msg`):

```
task_new_witness_ok_msg   : "R15 TASK NEW OK\n"
task_new_witness_fail_msg : "R15 TASK NEW FAIL\n"
```

### 4.2 What the five post-conditions prove

1. **Return non-NULL.** task_new completed without OOM at boot
   (both pid_alloc and aspace_create_user succeeded).
2. **pid == 1.** Dense-low-first pid_alloc scan started at 1
   and found NULL immediately — no stale reservation from
   pre-witness code. Directly hits the AC.
3. **parent_pid == 0.** The `test rbx, rbx; jz skip_parent_load`
   branch was taken (NULL parent), and the fallthrough
   `xor eax, eax; mov [r13 + 4], eax` correctly stored 0.
4. **state == STATE_NEW.** rep stosq zeroed offset 8;
   no accidental subsequent write clobbered it. Directly hits
   the second AC.
5. **user_pml4_pa != 0.** aspace_create_user returned a real
   pml4 physical address, and step 6's `mov [r13 + 16], rcx`
   installed it. This is what makes #550's aspace_teardown call
   meaningful downstream.
6. **pid_table[1] == r12.** Step 7 published the mapping;
   the "table last" ordering happened.

The witness does NOT free the task — that's #550's territory.
Leaving `_task_pool[0]` occupied at end of boot is fine (init
is meant to be persistent; the R15.M5 witness's world ends here).

### 4.3 Fingerprint additions

Marker line appended to two fingerprint files (contains-in-order):

`tests/r15/expected-boot-r15-ring3.txt`:

```diff
 R15 RING3 HELLO OK
 R15 FD TABLE OK
+R15 TASK NEW OK
 IPI OK
```

`tests/r14b/expected-boot-r14b-loader.txt`:

```diff
 R15 FD TABLE OK
+R15 TASK NEW OK
 LOADER OK
```

The other 5 fingerprint files (`boot_r8_only`, `boot_r10`,
`boot_r11`, `boot_r12`, `boot_r12_denial`) do **not** need
editing — their scope is pre-R14b substrate that runs before
this witness; the extra line post-dates their fingerprint
window and contains-in-order matching stays byte-identically
green.

**Fingerprint interaction with #550.** #550's task_free witness
appends "R15 TASK FREE OK" after this doc's "R15 TASK NEW OK".
When both land, the boot log carries both markers; the
fingerprint files must both be edited when they land together
OR each separately (order-independent). This doc's fingerprint
edits are safe to land alone (no dependency on #550).

### 4.4 What the witness does NOT test (deferred)

- **Round-trip pid reuse.** #550's witness runs a 100-iteration
  loop; this issue's witness is a single-call construction. Reuse
  is #550's concern.
- **Non-init parent (fork path).** R15.M6-003 (`sys_fork`)
  exercises `task_new(current_task())`; parent_pid is read from
  `[parent + 0]`. A single-iteration variant with a stub parent
  pointer + post-check `t->parent_pid == stub_pid` would add
  coverage — deferred to fork's own witness.
- **-EAGAIN path** (pid_alloc exhaustion after 64 tasks). Would
  need 64 pre-`task_new` calls; excessive for a boot witness.
  Deferred to sys_fork stress test at R15.M6.
- **-ENOMEM path** (aspace_create_user OOM). Would need
  phys pool exhaustion; excessive for a boot witness. Deferred.
- **fd_table zero-check.** Included in the rep-stosq region;
  the `state @ 8 == 0` and `user_pml4_pa @ 16` checks flank
  the fd_table region (168..424) and would detect any accidental
  under-count in rep stosq (rcx too small would leave 168 zero
  and 424 nonzero, or leave 8 zero and 24 nonzero — either
  case fails a check).

## 5. LOC estimate

| File                                                              | LOC delta |
|-------------------------------------------------------------------|-----------|
| `src/kernel/core/sched/task_pool.pdx` (task_new body)             | +55       |
| `src/kernel/boot/kernel_main.pdx` (witness block + rodata)        | +50       |
| `tests/r15/expected-boot-r15-ring3.txt`                           | +1        |
| `tests/r14b/expected-boot-r14b-loader.txt`                        | +1        |
| `design/kernel/r15-m5-006-task-new-real.md` (this doc)            | +560      |
| **Total**                                                         | **~667**  |

Executable code: ~40 asm lines + ~15 justification / structure
lines = ~55 LOC in `task_pool.pdx`. Witness: ~45 lines of asm +
~5 lines of rodata = ~50 LOC in `kernel_main.pdx`. Design +
fingerprint: ~562 LOC.

Same order of magnitude as #549 (~554 LOC total) and #550
(~657 LOC total). Within the milestone's per-issue budget.

## 6. Backtrack candidates

Ordered by preference.

### 6.1 Backtrack A — pid_alloc reserves via slab-address write

Instead of pid_alloc leaving `_pid_table[pid]` untouched
(§2.3), pid_alloc writes `pid_table[pid] = &_task_pool[pid-1]`
(the eventual mapping) at reservation time. Then task_new step 7
becomes a no-op:

```
    ; step 7 elided — pid_alloc already installed the mapping
    ; (task_new just doesn't undo it on failure paths)
```

**Consequence.** One fewer instruction pair in task_new. But
task_new's failure paths must be careful: on aspace_create_user
OOM, `pid_free(pid)` must clear the mapping (which it does
already — pid_free writes 0). No change to rollback logic.

R15.M6 SMP fork gets an extra concurrency win: the
reservation is atomic under the caller's lock (pid_alloc + its
write both happen inside a lock scope). At R15.M5 the write is
still redundant with task_new's step 7 — until the parallel-fork
path lands.

**Recommend as first backtrack** if #545 (pid_alloc) lands with
the reservation write. Otherwise stay with the split
(pid_alloc scans, task_new publishes) documented here.

### 6.2 Backtrack B — 4-push prologue (add r14 for pml4_pa)

Instead of `push rax / pop rcx` around `rep stosq` (§3.2 Option
A), add a 4th push `push r14` to the prologue and hold pml4_pa
in `r14` across the rep stosq. Push count = 4 = 32 bytes;
combined with return address = 40 bytes = 8 mod 16 — need
`sub rsp, 8` in prologue and `add rsp, 8` in epilogue to
restore alignment.

**Consequence.** 3 extra instructions (push, sub, add). No
stack-scratch during body → simpler mental model for future
edits that add calls to the middle of the body.

**Reject as primary.** Option A's `push rax / pop rcx` is
tight and its risk (a future edit inserting a call between
push and pop) is documented; the r14 promotion is a clean
1-line change if that risk materializes.

### 6.3 Backtrack C — task_new(NULL) skips aspace_create_user

If task_new(NULL) — init construction — doesn't need a fresh
user aspace (because the kernel launches init by loading its
ELF into a pre-existing aspace, e.g. the kernel PML4 itself
in the low half), skip step 4 for the NULL-parent branch:

```
    test rbx, rbx
    jz task_new_skip_aspace_create
    call aspace_create_user
    ; ...
task_new_skip_aspace_create:
    ; user_pml4_pa left at rep-stosq zero
```

**Consequence.** init runs on a NULL user_pml4_pa, which
`task_free`'s `aspace_teardown(0)` would then have to
NULL-guard against (#550 §8 flagged this as a cross-cutting
risk). Adds a 3-instruction guard to task_free.

**Reject.** Contradicts the tactical plan §Subsystem 8 failure
mode ("no free frame for pml4 → -ENOMEM"). The extra fd_frame
allocation for init is 4 KiB — cheap. Also, R17.M2-005
(`kernel-launch-init-bootstrap`) uses task_new(init) as the
first step; if init has no aspace, the ELF loader has nowhere
to put user pages.

### 6.4 Backtrack D — task_new signature: u32 parent_pid instead of *task

Change signature to `task_new : (u32 parent_pid) -> *task`.
Simpler body (no `test rbx, rbx; jz` — always write parent_pid).
task_new(0) = init; task_new(current()->pid) = fork.

**Consequence.** 4 fewer instructions in step 6 (no NULL guard).
But R15.M6 fork's `sys_fork` prologue grows: `mov edi, [current
+ 0]` before `call task_new`. Net wash.

**Reject in favor of tactical plan signature.** The `*task`
form is what the tactical plan §Subsystem 8 says; adopting it
here gives R15.M6 fork one fewer memory read at the trust
boundary. Also more consistent with `task_free : (*task) -> ()`
(they take the same pointer type).

### 6.5 Backtrack E — explicit `state = STATE_NEW` write

Instead of relying on rep stosq's zero == STATE_NEW identity
(§3.1 rationale 6), add an explicit write:

```
    mov rax, 0                      ; STATE_NEW = 0
    mov [r13 + 8], eax              ; state @ 8
```

**Consequence.** 2 extra instructions. Explicit — a reader
doesn't have to know STATE_NEW = 0 to understand step 6.
Robust to a future #547 refactor that renumbers states
(STATE_NEW = 1, etc.) — but no such refactor is expected,
because 0 is the "ground state" value by convention across
the entire mm/sched substrate.

**Neutral.** If a code reviewer requests it during landing,
accept. Otherwise omit — the design doc's §3.1 rationale 6
+ the justification string document the reliance on the
zero == NEW identity.

### 6.6 Backtrack F — kernel_stack allocation inside task_new

Instead of leaving `kernel_stack @ 24` at rep-stosq zero
(deferred to R15.M6-001), allocate a per-task kernel stack
in task_new:

```
    mov rdi, 0                      ; order = 0
    call phys_alloc                 ; rax = stack_base_pa or 0
    test rax, rax
    jz task_new_fail_rollback_aspace   ; NEW rollback path
    mov [r13 + 24], rax             ; kernel_stack
```

**Consequence.** Adds a 4th fallible step + a 3-step rollback
(pid_free, aspace_teardown, phys_free) if a subsequent step
fails. Substantial complexity increase.

**Reject at R15.M5.** No task runs at R15.M5 (they're all
constructed, never enqueued). Kernel stacks are a scheduler
concern; the natural home is R15.M6-001 sched_enqueue's first
call for a given task. Landing kernel_stack allocation there
keeps task_new's failure surface at 2 steps (pid, aspace) and
its rollback shape minimal.

## 7. Tractability

**HIGH.**

- No new paideia-as encoder gap (rep stosq, SIB store, RIP-rel
  lea, cross-module call, imm32 store — all audited).
- No new IDT / GDT / TSS / CR3 / MSR discipline.
- No new module directory; `src/kernel/core/sched/` is
  established substrate.
- ~40 asm LOC of body + ~45 asm LOC of witness. Same tempo as
  #549 (fd_table, ~80 asm LOC), #550 (task_free, ~30 asm LOC),
  and #649 (phys_free real, ~40 asm LOC).
- Register discipline is documented and matches the phys_alloc
  post-mortem pattern (`f6195ed`) + aspace_teardown 5-push
  pattern — the specific bug class that bit the previous
  milestone is called out in §3.2, not repeated.
- One design consumer sits ready: #550's task_free is fully
  designed, honors this doc's compact mapping (§3.9 / #550 §3.6),
  and its witness will fail loudly if this issue's task_new
  drifts from the contract.
- Marker line is contains-in-order in two fingerprint files;
  both already carry the R15-M5-007 marker one line above.

Known follow-ups (not blockers for #548):

- **#545 pid_alloc landing** — this doc pins the contract §2.3;
  #545's own doc references this section for its ratification.
- **#547 task-state-machine landing** — this doc writes state = 0
  (STATE_NEW); #547 formalizes 0 as STATE_NEW and adds the
  transition guards that R15.M6 sched_enqueue calls.
- **R15.M6-001 sched_enqueue** — this issue's tasks aren't
  enqueued; sched_enqueue is where kernel_stack allocation
  lands (§6.6 backtrack F).
- **R15.M6-003 sys_fork** — fork's first call is
  `task_new(current())`. §6.4's signature ratification pays off
  there.

## 8. Cross-cutting risks

- **#545 pid_alloc landing with reservation write.** §2.3 pins
  the non-reservation contract; if #545 lands the reservation
  variant, this issue's step 7 becomes a redundant write (no
  correctness impact, just wasted 2 instructions). Mitigation:
  §6.1 backtrack A is the promotion path; landing #545 first
  and adjusting task_new step 7 is a 2-line edit.
- **aspace_create_user register clobber regression.** §3.4
  trusts aspace_create_user's callee-save discipline
  (aspace_create.pdx lines 44–51 save r12/r13/r14). If a
  future edit forgets to restore r13, task_new's `r13 =
  slab_addr` gets corrupted, and step 5's rep stosq scribbles
  on the wrong memory. Mitigation: the witness's post-checks
  (`pid_table[1] == r12` in check 5) would catch this
  immediately — a stomped r13 makes the pid_table entry point
  at wherever rep stosq scribbled, which won't match r12.
- **pid_alloc returning 0 at boot.** §3.4 handles this cleanly
  (`test rax, rax; jz task_new_fail_return`). But at boot with
  no prior task_new calls, pid_alloc should always find slot 1
  free — a 0 return means pid_alloc is broken. The witness's
  `cmp rax, 0; je task_new_witness_fail` catches this as
  "R15 TASK NEW FAIL" on the log, immediately after any log
  output pid_alloc might have produced.
- **rep stosq under-count / over-count.** rcx = 278 is
  arithmetic (2224 / 8); a typo of 32 (fd_table size) would
  zero only 256 bytes and leave the later fields dirty; a typo
  of 512 would over-write into the next slab's page. Mitigation:
  the witness's checks flank the region (`state @ 8` and
  `user_pml4_pa @ 16` inside; the pid_table check outside). An
  under-count leaves stale bytes; the outer pid_table pointer
  would still match r12 (that's set in step 7, unaffected by
  step 5), but state or user_pml4_pa might carry stale content
  and fail their checks — assuming the memory had non-zero
  bytes to begin with. If it happens to be zero, the failure
  goes silent. Sturdier check: assert `_task_pool[0]` was zero
  *before* task_new (a boot invariant — `.bss` is zero-init).
  Skipped to keep the witness under 50 LOC; landed as a
  follow-up if drift is observed.
- **Slab index arithmetic overflow.** `(pid - 1) << 12` with
  pid = 1 gives 0; pid = 64 gives 63 * 4096 = 258048 =
  0x3F000. All safely inside the 64 * 4096 = 262144-byte
  pool. No overflow concern; pid > 64 can't happen because
  pid_alloc caps at MAX_PIDS = 64.
- **Field write ordering with respect to pid_table publish.**
  Step 6 writes pid/parent_pid/pml4_pa; step 7 publishes.
  x86 memory ordering is TSO — stores are seen in program
  order by other cores. But `mov` isn't a memory barrier;
  a compiler reordering that moved step 7 before step 6
  would corrupt the invariant. paideia-as does no such
  reordering (it emits stores in source order). Mitigation:
  the source order is the contract; a future paideia-as
  optimizer that reorders stores would need to respect a
  fence directive. §6.5 backtrack E discusses an explicit
  `sfence` — not adopted at R15.M5 (single-CPU) but flagged
  for R15.M6 SMP fork.
- **Fingerprint drift.** Adding "R15 TASK NEW OK" to two
  files must land in the same commit as the code. Missing
  either → smoke false negative. Mitigation: pre-push hook
  blocks pushes that fail smoke (per
  `feedback_paideia_os_no_cicd`); drift caught locally.

## 9. Backtrack markers

For the debugger-agent if the witness reports FAIL:

| Symptom                                     | Root cause hypothesis                              | Where to look                                      |
|---------------------------------------------|----------------------------------------------------|----------------------------------------------------|
| task_new returns 0, no other output         | pid_alloc returned 0 at boot (broken scan)         | `#545` pid_alloc: scan start at pid 1 not 0; `_pid_table[1]` should be NULL at boot |
| task_new returns 0 after aspace log lines   | aspace_create_user returned OOM                    | phys pool exhausted at boot — check pre-witness allocations (loader?) |
| Check 1 FAIL: pid != 1                      | pid_alloc dense-low-first not working              | `#545` scan starts at index 2 or skips index 1     |
| Check 2 FAIL: parent_pid != 0               | test rbx, rbx guard skipped                        | `task_new` step 6: verify `test rbx, rbx; jz` present and taken |
| Check 3 FAIL: state != 0                    | rep stosq count wrong (< 2 qwords) OR later write clobbered state | `task_new` step 5: rcx = 278? step 6: no accidental `mov [r13 + 8], ...`? |
| Check 4 FAIL: user_pml4_pa == 0             | pop rcx wrong OR mov [r13 + 16], rcx skipped       | `task_new` step 6: verify pop pairs push; verify store offset = 16 |
| Check 5 FAIL: pid_table[1] != r12           | Step 7 not executed OR wrote wrong base            | `task_new` step 7: `lea rcx, [rip + _pid_table]` — check symbol resolution; `[rcx + r12*8]` — check r12 preserved |
| Silent hang, no OK/FAIL                     | task_new clobbers rbx/r12/r13 and returns to wrong RIP | `task_new` prologue/epilogue: verify 3 pushes match 3 pops on every return path (both success and 2 failure exits) |
| "R15 TASK NEW OK" then hang before next marker | Witness's r12 held task pointer got clobbered by a subsequent call before the check block completed | Witness lives inside boot_continue_after_ring3; check any interceding call preserves r12 |

## 10. References

- Issue: paideia-os#548
- Milestone: paideia-os milestones/61 (R15.M5 Process abstraction)
- Sibling issues:
  - #543 (layout freeze — doc)
  - #544 (task_pool slab — storage)
  - #545 (pid_alloc — reservation; §2.3 contract pin)
  - #547 (task-state-machine — STATE_NEW = 0)
  - #549 (fd_table — LANDED; offsets pinned)
  - #550 (task_free real — designed; §3.6 compact-mapping contract)
  - #551 (boot_r15_process smoke)
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 8 (line 862+), interfaces (line 894–898),
  issue #6 (line 946), encoder gap PA-R15-006 (line 1993)
- Master plan: `design/milestones/r14b-master-plan.md`
  §R15.M5 process abstraction
- Prior-art aspace factory: `src/kernel/core/mm/aspace_create.pdx`
  lines 96–131 (aspace_create_user 3-push prologue, OOM sentinel)
- Prior-art register-discipline post-mortem: commit `f6195ed`
  (phys_alloc callee-save fix — §3.2 immunizes against)
- Prior-art rep_stosq encoder audit: paideia-as
  `tools/paideia-as/CHANGELOG.md` (PA-R13-012, F3 48 AB)
- Prior-art fingerprint pattern:
  `design/kernel/r15-m5-007-fd-table-embed.md` §4.3
  (contains-in-order marker addition)
- Prior-art compact pid↔slab mapping:
  `design/kernel/r15-m5-008-task-free-real.md` §3.6
  (contract this doc honors)
- paideia-as encoder audits: `tools/paideia-as/tests/build-emit/`
  — `rep_stosq_smoke.pdx` (step 5),
  `mov_mem_imm_sib_disp.pdx` (step 7 pid_table store).
