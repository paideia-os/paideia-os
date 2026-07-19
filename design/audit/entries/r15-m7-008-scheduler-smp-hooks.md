---
audit_id: r15-m7-008-scheduler-smp-hooks
issue: 569
files:
  - src/kernel/core/sched/idle.pdx
  - src/kernel/core/sched/runqueue.pdx
  - src/kernel/core/sched/pick_next.pdx
  - src/kernel/core/sched/switch.pdx
  - src/kernel/core/sched/wake_block.pdx
  - src/kernel/core/sched/task_pool.pdx
effects: []
capabilities: []
reviewed_by:
date: 2026-07-18
status: complete
---

# AUDIT R15-M7-008 — Scheduler SMP-ready hooks: cpu_local swap recipe

## Issue

R15-M7-008 (#569): "Every scheduler entry point uses `cpu_local_get()` for current,
and per-CPU runqueue would sit at cpu_local + offset — leave the pointer set to a
single global runqueue for R14B but structure the calls so switching to per-CPU
is a symbol-swap."

Acceptance: audit doc lists all runqueue accesses and confirms all go through
the cpu_local pointer path when SMP lands.

## Purpose

R15.M7 primitives (#562 idle_task, #563 runqueue, #564 sched_switch_r15,
#567 sched_block/sched_wake) landed on a single-CPU model. The runqueue,
current-TCB pointer, and idle-TCB pointer are RIP-relative globals; the
scheduler is not yet aware that per-CPU state exists.

This audit inventories every access to those globals in the R15.M7 scheduler
code path, classifies each symbol as per-CPU vs shared, and specifies the
exact per-CPU migration recipe (symbol-swap or accessor-swap) that will be
applied when SMP lands (R16.M-SMP). Non-scheduler callers (kernel_main
witnesses, R11-era preempt/timer paths, syscall handlers) are catalogued
separately so the SMP migration knows the total footprint but does not have
to touch them in the same commit.

## Shared vs per-CPU classification

Under an SMP model with a global process table but per-CPU scheduling state,
the five symbols split as follows:

| Symbol            | Class           | Rationale                                                             |
|-------------------|-----------------|-----------------------------------------------------------------------|
| `_current_tcb`    | **per-CPU**     | Each CPU has exactly one running thread. Read on every scheduler hop.  |
| `_runq_head_slot` | **per-CPU**     | Each CPU has its own runqueue. Cross-CPU migration is a separate op.   |
| `_idle_tcb`       | **per-CPU**     | Each CPU idles in its own hlt loop with its own kernel stack.          |
| `_task_pool`      | **shared**      | Global process inventory. All CPUs allocate/free from the same slab.   |
| `_pid_table`      | **shared**      | Global PID→slab index. Must be visible to sys_wait/sys_exit anywhere.  |

`_task_pool` and `_pid_table` stay RIP-relative globals under SMP; they get a
spinlock (or later, RCU) but the symbol never moves into cpu_local. All
per-CPU symbols migrate to `[cpu_local + offset]` via `cpu_local_get()` +
constant-offset dereference. The per-CPU control block already reserves
`CPU_LOCAL_OFF_CURRENT_TCB = 8` (see `src/kernel/core/cpu/local.pdx`); new
offsets `CPU_LOCAL_OFF_RUNQ_HEAD` and `CPU_LOCAL_OFF_IDLE_TCB` will be added
in the SMP commit.

## Cpu_local swap recipe (template)

Today's single-CPU access pattern:

```pdx
lea rax, [rip + _current_tcb];
mov rax, [rax];                       // read current TCB
```

Per-CPU replacement (post-#569):

```pdx
call cpu_local_get;                                     // rax = &this_cpu
mov  rax, [rax + CPU_LOCAL_OFF_CURRENT_TCB];            // read current TCB
```

Store form:

```pdx
lea rcx, [rip + _current_tcb];
mov [rcx], rdi;                       // write current TCB
```

becomes

```pdx
call cpu_local_get;                                     // rax = &this_cpu
mov  [rax + CPU_LOCAL_OFF_CURRENT_TCB], rdi;            // write current TCB
```

Net delta: +1 instruction per site (the `call`) minus caller-save discipline
around `rax`. `cpu_local_get` is `sysreg` effect only and is callee-save
clean (RCX/RDX are caller-save in SysV AMD64), so no additional prologue.
When PA-R14-001 lands (gs-mem-operand encoder), `cpu_local_get` collapses to
one instruction `mov rax, [gs:0]` and the callee-save cost disappears.

Runqueue-head accesses receive the same treatment against
`CPU_LOCAL_OFF_RUNQ_HEAD`; idle-TCB accesses against
`CPU_LOCAL_OFF_IDLE_TCB`.

---

## Access inventory — R15.M7 scheduler code

Every access to each of the five symbols within the R15.M7 scheduler files is
catalogued below with file+line, containing function, R/W, current storage
class, and the specific migration recipe.

### 1. `_current_tcb` — per-CPU (3 sites in R15.M7 code)

#### Site C1 — `switch.pdx:109` in `sched_switch_r15` (save-current)

```pdx
lea rax, [rip + _current_tcb];
mov rax, [rax];                       // rax = current TCB
```

- Access pattern: **read** (base load + deref)
- Currently a global: **yes**
- Recipe: replace two-instruction sequence with
  `call cpu_local_get; mov rax, [rax + CPU_LOCAL_OFF_CURRENT_TCB];`
- Callee-save impact: `sched_switch_r15` is already in unsafe block with
  `cli` on the very next instruction after the RFLAGS spill (line 122); the
  extra `call` sits *before* `cli`, so no atomicity issue.

#### Site C2 — `switch.pdx:154` in `sched_switch_r15` (update-to-next)

```pdx
lea rcx, [rip + _current_tcb];
mov [rcx], rdi;                       // _current_tcb = next_tcb
```

- Access pattern: **write** (base load + store)
- Currently a global: **yes**
- Recipe:
  `call cpu_local_get; mov [rax + CPU_LOCAL_OFF_CURRENT_TCB], rdi;`
- Careful: this site executes with `cli` (interrupts off). `cpu_local_get`
  currently reads MSR via `rdmsr` — safe under `cli`, and idempotent since
  IA32_GS_BASE does not change mid-CPU. Post-PA-R14-001 the call is just a
  `mov rax, [gs:0]`, trivially safe.

#### Site C3 — `wake_block.pdx:41` in `sched_block` (load-current)

```pdx
mov rax, [rip + _current_tcb];        // combined lea+load form
```

- Access pattern: **read**
- Currently a global: **yes**
- Recipe: replace single-instruction fused-load with
  `call cpu_local_get; mov rax, [rax + CPU_LOCAL_OFF_CURRENT_TCB];`
- Note: assembler currently accepts `mov reg, [rip + sym]` as a single memory
  load with RIP-relative encoding. The rewrite drops from 1 instruction to 2.

---

### 2. `_runq_head_slot` — per-CPU (3 sites in R15.M7 code)

Runqueue accesses all take the pattern *load base into rax, then dereference
`[rax + 432]` (next) and `[rax + 440]` (prev)*. Only the base load references
the symbol; every field access derives from it. That is exactly the property
that makes symbol-swap trivial: **rewrite the base load, leave every derived
field access untouched**.

#### Site R1 — `runqueue.pdx:176` in `runq_init`

```pdx
lea rax, [rip + _runq_head_slot];
mov [rax + 432], rax;                 // head.next = &head
mov [rax + 440], rax;                 // head.prev = &head
```

- Access pattern: **read (base) + 2 writes (fields)**
- Currently a global: **yes**
- Recipe: replace `lea` with
  `call cpu_local_get; add rax, CPU_LOCAL_OFF_RUNQ_HEAD;`
  Both following stores are unchanged (they use `[rax + 432]`, `[rax + 440]`).
- SMP nuance: `runq_init` becomes per-CPU-per-boot. AP startup path will call
  it (or an inlined equivalent) after `cpu_local_get` returns the AP's
  block. On BSP this replaces the current single kernel_main call site.

#### Site R2 — `runqueue.pdx:192` in `runq_enqueue`

```pdx
lea rax, [rip + _runq_head_slot];     // rax = &head
mov rcx, [rax + 440];                 // rcx = head.prev
mov [rdi + 432], rax;                 // task.next = &head
mov [rdi + 440], rcx;                 // task.prev = tail
mov [rcx + 432], rdi;                 // tail.next = task
mov [rax + 440], rdi;                 // head.prev = task
```

- Access pattern: **read (base) + 1 read (head.prev) + 2 writes (fields)**
- Currently a global: **yes**
- Recipe: replace `lea` with
  `call cpu_local_get; add rax, CPU_LOCAL_OFF_RUNQ_HEAD;`
  All four `[rax + ...]` / `[rdi + ...]` accesses unchanged.
- Cross-CPU concern: `runq_enqueue(task)` may be called from `sched_wake`
  targeting a task that *did not last run on this CPU*. Under SMP with
  per-CPU runqueues, the enqueue must land on the target task's home CPU's
  runqueue (recorded on the task struct at a to-be-added field). That is a
  *policy* change beyond symbol-swap; #569 does not resolve it. The audit
  flags it here so the SMP commit does not treat runq_enqueue as pure
  symbol-swap.

#### Site R3 — `pick_next.pdx:103` in `sched_pick_next_r15`

```pdx
lea rax, [rip + _runq_head_slot];     // rax = &head
mov rdi, [rax + 432];                 // rdi = head.next (candidate)
cmp rdi, rax;                         // list empty?
je  pick_empty;
...
```

- Access pattern: **read (base) + 2 reads (fields) + 3 writes (rotate)**
- Currently a global: **yes**
- Recipe: replace `lea` with
  `call cpu_local_get; add rax, CPU_LOCAL_OFF_RUNQ_HEAD;`
  All subsequent `[rax + 432]` / `[rax + 440]` accesses unchanged.
- Register pressure: `sched_pick_next_r15` is a leaf and uses only rax/rcx/rdi.
  The `call cpu_local_get` fits without spilling.

Note: **`runq_dequeue` (runqueue.pdx:206) has zero references to
`_runq_head_slot`**. It operates entirely through the task's own next/prev
pointers, which happen to point at the sentinel head when the list contains
one element. That is *precisely* the property that makes runq_dequeue
symbol-swap-free: it works against any doubly-linked circular list,
regardless of whether the head is global or per-CPU. Excellent design.

---

### 3. `_idle_tcb` — per-CPU (2 sites in R15.M7 code)

#### Site I1 — `idle.pdx:65` in `idle_init` (publish)

```pdx
lea rax, [rip + _idle_task_slot];
lea rcx, [rip + _idle_tcb];
mov [rcx], rax;                       // _idle_tcb = &_idle_task_slot
```

- Access pattern: **write** (base load + store)
- Currently a global: **yes**
- Recipe under SMP: `_idle_task_slot` also becomes per-CPU (each CPU idles on
  its own stack — see §1 classification). The site rewrites to:
  ```pdx
  call cpu_local_get;                                  // rax = &this_cpu
  mov  rcx, rax;                                       // save cpu-local base
  lea  rax, [rip + _idle_task_slots];                  // NEW: array of per-CPU slots
  mov  rdx, [rcx + CPU_LOCAL_OFF_CPU_ID];              // cpu_id
  shl  rdx, 12;                                        // idx * 4096 (slot size)
  add  rax, rdx;                                       // this CPU's slot addr
  mov  [rcx + CPU_LOCAL_OFF_IDLE_TCB], rax;            // publish
  ```
- Alternative (simpler): keep `_idle_task_slot` singular for BSP, allocate AP
  idle slots at AP-startup time via `phys_alloc`, publish per-CPU via the
  cpu_local store. Same net effect, less .bss overhead.
- This site is the **highest structural change** in the entire audit; every
  other site is a mechanical symbol-swap.

#### Site I2 — `pick_next.pdx:132` in `sched_pick_next_r15` (empty-fallback)

```pdx
pick_empty:
  mov rax, [rip + _idle_tcb];         // return idle
  ret
```

- Access pattern: **read** (fused RIP-relative load)
- Currently a global: **yes**
- Recipe:
  `call cpu_local_get; mov rax, [rax + CPU_LOCAL_OFF_IDLE_TCB];`
- Same +1 instruction cost as C3.

---

### 4. `_task_pool` — shared (1 site in R15.M7 code)

#### Site P1 — `task_pool.pdx:90` in `task_new`

```pdx
lea r13, [rip + _task_pool];
mov rcx, r12;
sub rcx, 1;
shl rcx, 12;                          // *4096
add r13, rcx;                         // r13 = slab_addr
```

- Access pattern: **read** (base compute for slab addressing)
- Currently a global: **yes**
- Recipe under SMP: **no change**. `_task_pool` stays global. The SMP
  hardening is a spinlock around `task_new`'s pid_alloc + slab-zero + publish
  window (steps 2–8 in the current body), plus TSO-safe publish ordering.
  Symbol reference itself is unchanged.

---

### 5. `_pid_table` — shared (3 sites in R15.M7 code)

#### Site D1 — `task_pool.pdx:36` in `pid_alloc`

```pdx
lea rax, [rip + _pid_table];
mov rax, [rax + rcx*8];               // load _pid_table[rcx]
```

- Access pattern: **read** (scan for free slot)
- Currently a global: **yes**
- Recipe under SMP: **no change** to symbol. Add spinlock (or cmpxchg16b
  reservation) around the scan+publish pair. Symbol reference is unchanged.

#### Site D2 — `task_pool.pdx:62` in `pid_free`

```pdx
lea rax, [rip + _pid_table];
mov [rax + rdi*8], 0;                 // rdi = pid; store 0
```

- Access pattern: **write**
- Currently a global: **yes**
- Recipe under SMP: **no change** to symbol. Store lands under the same lock
  that pid_alloc acquires.

#### Site D3 — `task_pool.pdx:122` in `task_new` (publish)

```pdx
lea rcx, [rip + _pid_table];
mov [rcx + r12*8], r13;               // _pid_table[pid] = slab_addr
```

- Access pattern: **write** (publish new task)
- Currently a global: **yes**
- Recipe under SMP: **no change** to symbol. Publish must be
  release-ordered w.r.t. the slab-zero (step 6). On x86 TSO this is free
  (stores don't reorder past prior stores), but a `sfence` or `mfence`
  should be added defensively for future ordering-relaxation. Symbol
  reference itself is unchanged.

---

## Function-level summary

| Function              | File                     | Runq | Curr | Idle | Pool | Pid | Complexity of SMP swap |
|-----------------------|--------------------------|------|------|------|------|-----|------------------------|
| `idle_init`           | idle.pdx                 |  0   |  0   |  1   |  0   |  0  | High (per-CPU slot)    |
| `runq_init`           | runqueue.pdx             |  1   |  0   |  0   |  0   |  0  | Trivial (base swap)    |
| `runq_enqueue`        | runqueue.pdx             |  1   |  0   |  0   |  0   |  0  | Trivial + policy note  |
| `runq_dequeue`        | runqueue.pdx             |  0   |  0   |  0   |  0   |  0  | **Zero** (design win)  |
| `sched_pick_next_r15` | pick_next.pdx            |  1   |  0   |  1   |  0   |  0  | Trivial (base swaps)   |
| `sched_switch_r15`    | switch.pdx               |  0   |  2   |  0   |  0   |  0  | Trivial (base swaps)   |
| `sched_block`         | wake_block.pdx           |  0   |  1   |  0   |  0   |  0  | Trivial (base swap)    |
| `sched_wake`          | wake_block.pdx           |  0   |  0   |  0   |  0   |  0  | Zero direct + wake-tgt |
| `pid_alloc`           | task_pool.pdx            |  0   |  0   |  0   |  0   |  1  | Zero (add lock)        |
| `pid_free`            | task_pool.pdx            |  0   |  0   |  0   |  0   |  1  | Zero (under lock)      |
| `task_new`            | task_pool.pdx            |  0   |  0   |  0   |  1   |  1  | Zero (under lock)      |
| **Totals (R15.M7)**   |                          |  3   |  3   |  2   |  1   |  3  |                        |

**Site totals:** 12 unique symbol-reference sites in R15.M7 scheduler code.
Per-CPU migration touches 8 sites (3 runq + 3 current + 2 idle). Shared sites
(4: 1 pool + 3 pid) require locking but no symbol swap.

## Ordering — highest-priority swaps first

Under R16.M-SMP (BSP+AP bring-up), sites are ordered by "blocks correct SMP
soonest". If we bring up an AP before touching a site, that site is a
data-race waiting to happen.

1. **Site C1 (`sched_switch_r15` save-current)** and **C2 (update-to-next)** —
   context switch is on the AP's hot path from tick zero. **Blocks all AP
   scheduling.** Must land in the same commit as AP startup.

2. **Site R3 (`sched_pick_next_r15` runq base load)** — every timer tick on
   every AP reads it. **Blocks AP timer-driven preemption.** Land with C1/C2.

3. **Site R1 (`runq_init`)** — per-AP bootstrap. AP-startup path must call
   the swapped-runq_init before its first `sti`. **Blocks AP bring-up.**
   Same-commit dependency with C1/C2/R3.

4. **Site I2 (`sched_pick_next_r15` idle fallback)** and **I1 (idle_init
   publish)** — every AP needs its own idle to hlt into when its runqueue
   empties. **Blocks first AP idle transition.** Land with R1.

5. **Site R2 (`runq_enqueue` base load)** — cold once every AP has bootstrapped
   with an empty local runqueue; hot as soon as `sched_wake` targets any task.
   Land with the wake-target CPU-selection policy (out of scope for #569).

6. **Site C3 (`sched_block` load-current)** — hot for any task that blocks
   under an AP. Land with C1/C2 (same commit is easiest).

7. **Shared sites (D1–D3, P1)** — locking-only. Can land in a separate commit
   before or after the per-CPU swaps, provided the lock is acquired on BSP
   too before the first AP comes up. Recommended: **land the lock first**,
   in a preparatory commit, so #569's per-CPU migration commit does not
   also introduce a locking discipline.

**Suggested SMP-migration commit split:**

- Commit A (pre-SMP prep): add spinlock around task_pool/pid_table sites.
  Zero runtime effect on single-CPU (uncontended); establishes the discipline.
- Commit B (per-CPU migration): all 8 per-CPU sites in one commit. Idle-slot
  restructuring at site I1 is the largest single change; carries its own
  design entry.
- Commit C (AP startup): drives the whole migration on real hardware /
  QEMU-SMP.

## Estimated LOC delta

Per per-CPU site (C1, C2, C3, R1, R2, R3, I2):
- Current: 1–2 instructions (a `lea` and sometimes a `mov` deref)
- Rewritten: 2–3 instructions (`call cpu_local_get`, `mov rax, [rax+off]`,
  optional `add rax, off`)
- Net: **+1 instruction per site**

Seven sites × +1 instruction = **+7 LOC of instructions**, plus roughly
**+7 LOC of updated justifications** (each unsafe block's justification
string needs the "reads _current_tcb via cpu_local" language) = **~14 LOC**
across the per-CPU-swap commit.

Site I1 (`idle_init` publish) is the outlier: reworked to a per-CPU idle
slot indexed by cpu_id. Estimate **+15 LOC of new code** (per-CPU idle-slot
array or AP-time allocation) plus new offset constants in
`src/kernel/core/cpu/local.pdx` (+2 LOC:
`CPU_LOCAL_OFF_RUNQ_HEAD = 24`, `CPU_LOCAL_OFF_IDLE_TCB = 32`) and revised
kernel_main call sites (+3 LOC).

Shared-symbol lock addition (D1, D2, D3, P1): **+~20 LOC** across pid_alloc,
pid_free, task_new (lock acquire+release wrappers or in-body cli/sti pair
under interim non-locking discipline).

**Total estimated LOC delta for per-CPU migration: ~55–60 LOC**, split across
three commits per the ordering above.

## Non-R15.M7 sites (for SMP-migration completeness only)

The SMP migration must also touch (but #569 does not audit in detail) the
following sites which pre-date R15.M7 and reference the same symbols:

- `src/kernel/core/int/exceptions.pdx:143-144` — `handle_timer` reads
  `_current_tcb` to decrement per-TCB budget. Same recipe as C3.
- `src/kernel/core/int/idt.pdx:213` — legacy `_current_tcb` load. Verify
  whether still on any live path; consider deletion.
- `src/kernel/core/sched/preempt.pdx:112,132` — R11-era `sched_preempt_to`
  reads/writes `_current_tcb`. Same recipe as C1/C2 if preempt.pdx is
  retained under R15+; otherwise slated for removal alongside the R11 TCB
  layout.
- `src/kernel/core/sched/switch.pdx:90` — old `sched_switch` writes
  `Runqueue._current_tcb`. This is the pre-#564 path; verify unused, then
  remove.
- `src/kernel/core/syscall/handlers/sys_wait.pdx:30`,
  `sys_exit.pdx:42,92` — `_pid_table` scans in syscall bodies. **Shared,
  no swap; locking only** (same as D1–D3).
- `src/kernel/boot/kernel_main.pdx` witnesses (multiple sites) — witness/
  test code exercises symbols directly. Under SMP, witnesses may need
  `cpu_local_get`-adjusted references or become BSP-only tests. Not on the
  hot path.

These are catalogued here so the SMP migration commit knows its full
touch-set; per the issue scope, only the R15.M7 sites are the subject of
the swap recipe.

## Confirmation

**Every access site in R15.M7 scheduler code is documented above.** For
each site:

- **Current storage class is a global** — confirmed for all 12 sites.
  Reference: search
  `grep -n '_runq_head_slot\|_current_tcb\|_idle_tcb\|_task_pool\|_pid_table'
  src/kernel/core/sched/*.pdx` returns exactly these 12 non-comment sites
  (plus declarations and justification-string mentions, which are not code
  accesses).
- **A per-CPU migration recipe is specified** — each per-CPU site (C1, C2,
  C3, R1, R2, R3, I1, I2) has an exact `cpu_local_get` + offset rewrite.
  Each shared site (P1, D1, D2, D3) is confirmed as symbol-stable with a
  locking discipline to be added.
- **All per-CPU accesses will route through `cpu_local_get()`** — the
  common code shape is `call cpu_local_get; mov …, [rax + CPU_LOCAL_OFF_…]`,
  uniform across the 8 per-CPU sites. When PA-R14-001 (gs-mem-operand)
  lands, `cpu_local_get` becomes a compiler-inlined `mov …, [gs:off]`,
  reducing the per-site cost to zero instructions vs today.

Acceptance criterion of #569 is met: the audit lists all runqueue accesses
and confirms every per-CPU access has a documented path to a `cpu_local`
pointer indirection.

## References

- `design/kernel/r15-m7-001-idle-task.md` — idle-task design (site I1 source)
- `design/kernel/r15-m7-002-runqueue.md` — runqueue design (sites R1–R3)
- `design/kernel/r15-m7-003-sched-switch.md` — switch design (sites C1, C2)
- `design/kernel/r15-m7-006-block-wake.md` — block/wake design (site C3)
- `design/audit/entries/r15-m7-001-idle-task.md`
- `design/audit/entries/r15-m7-002-runqueue.md`
- `design/audit/entries/r15-m7-003-sched-switch.md`
- `design/audit/entries/r15-m7-006-block-wake.md`
- `src/kernel/core/cpu/local.pdx` — cpu_local_t layout, `cpu_local_get`
- `design/multicore/per-cpu-layout.md` — per-CPU control block design
