---
issue: 563
milestone: R15.M7 (Scheduler: cooperative → timer-preemptive)
subsystem: 10 — Scheduler
prereq:
  - "#543 (task-struct layout freeze — this doc extends the freeze at +432 / +440)"
  - "#544 (`_task_pool[64]` slab in .bss @align(4096) — LANDED)"
  - "#548 (`task_new` real body — `rep stosq` zeroes runq_next/prev to NULL by side effect; no code change needed here)"
  - "#549 (`fd_table` embed @+168..+424 — pins the upper bound this doc's runq fields must sit above)"
  - "#562 (idle task + `sched_pick_next_r15` O(64) stub — this doc rewrites pick_next's body and reuses `_idle_tcb` as the empty-list fallback)"
blocks:
  - "#564 (r15-m7-003 sched-switch-real — first save→restore; consumes pick_next's output but does not touch runq_next/prev)"
  - "#565 (r15-m7-004 lapic-timer 100Hz — first periodic pick_next; treats the runqueue as read-write hot path)"
touching:
  - src/kernel/core/sched/runqueue.pdx           (new symbols: `_runq_head_slot`, `runq_init`, `runq_enqueue`, `runq_dequeue`)
  - src/kernel/core/sched/pick_next.pdx          (rewrite `sched_pick_next_r15` body: O(64) walk → O(1) rotate)
  - src/kernel/boot/kernel_main.pdx              (runq_witness block + `call runq_init` insertion + banner strings, ~85 LOC)
  - tests/r15/expected-boot-r15-process.txt      (marker line, contains-in-order)
  - tests/r15/expected-boot-r15-ring3.txt        (marker line, contains-in-order)
  - design/kernel/task-struct-layout.md          (freeze extension — two-row addition for runq_next/prev)
related:
  - design/milestones/r14b-tactical-plan.md §Subsystem 10 (issue 2)
  - design/kernel/r15-m7-001-idle-task.md        (§2 slab discipline this doc reuses; §3 regs_save freeze this doc leaves untouched)
  - design/kernel/r15-m5-006-task-new-real.md    (§3.5 slab-layout freeze this doc extends further)
  - design/kernel/r15-m5-007-fd-table-embed.md   (fd_table span +168..+424 — this doc's runq fields sit strictly above)
  - design/kernel/scheduler.md                   (long-term architecture)
---

# R15-M7-002 — real runqueue: doubly-linked circular list with head sentinel (#563)

## 1. Scope

Replace the R10 fixed-2-task alternation and #562's O(64) `_pid_table`
linear scan with a **real doubly-linked circular runqueue**, so that
`sched_pick_next_r15` becomes an O(1) rotation of the head sentinel's
successor to the tail.

Acceptance criteria (from #563):

- enqueue 5 tasks; `sched_pick_next_r15` in sequence returns each once,
  round-robin.
- `runq_dequeue` removes a task from the list; subsequent picks skip it.

Everything else in R15.M7 is built on top of this: #564 (real
`sched_switch`) consumes pick_next's output but does not touch
`runq_next` / `runq_prev`; #565 (LAPIC-timer 100 Hz) drives pick_next
on each tick and depends on its O(1) discipline to bound ISR latency.

Explicitly out of scope (deferred):

- **State-transition-triggered enqueue.** Enqueueing tasks when they
  become `STATE_RUNNABLE` (out of `STATE_NEW` or `STATE_WAITING`) is
  the invariant that ties `state` to list membership. At R15.M7 that
  wiring lands piecemeal with #564 (initial enqueue at first
  save→restore) and #567 (`wake_from_waiting` — dequeue-from-waitq +
  enqueue-to-runq). This issue's witness enqueues by direct call and
  is thus decoupled from the state-transition contract.
- **Priority levels.** The runqueue is a **single FIFO** — no
  `level_heads[16]` bitmap fan-out yet. Priority scheduling is a
  Phase-9+ concern; R15.M7 is round-robin only. When multi-level
  lands, `_runq_head_slot` becomes `_runq_head_slot[16]` and pick_next
  gains a `bsr priority_bitmap` prelude (paideia-as #913 encoder gap
  currently blocks the single-instruction form).
- **Per-CPU runqueues.** SMP will need one runqueue per CPU keyed on
  `cpu_local`. Single-CPU R15.M7 uses one global sentinel; #566
  (r15-m7-008 SMP-ready hooks) documents the symbol-swap to
  `_runq_head_slot[NR_CPUS]` when APs come online.
- **Idle on the runqueue.** Idle stays **off** the runqueue — it's the
  fallback picked only when the queue is empty. This preserves the
  invariant "every entry is a real user/kernel task" and lets pick_next
  distinguish "picked something" from "fell back to idle" for future
  statistics (#571 sched-metrics).
- **task_new auto-enqueue.** `task_new` allocates in `STATE_NEW`, not
  `STATE_RUNNABLE`, so it does **not** enqueue. The transition
  `NEW → RUNNABLE` happens later (at first `sched_switch` or at the
  `sys_execve` return). This issue changes nothing in `task_new`; the
  `rep stosq` zero-fill already leaves `runq_next` / `runq_prev` at NULL,
  which is the correct off-runqueue witness.

## 2. Field offset extension — task_struct freeze @ +432 / +440

**Freeze: `runq_next` @ task+432 (u64), `runq_prev` @ task+440 (u64).**

This is an increment to the layout doc that #543 owns; the update is a
two-row addition, no field motion. Cross-linked below in §12.

### 2.1 Where the two u64s land in the existing slab

The R15.M5 slab has been frozen field-by-field to this point:

```
offset  size   field                    frozen by
------  -----  ----------------------   -----------------
     0      4  pid              (u32)   #548 (r15-m5-006)
     4      4  parent_pid       (u32)   #548
     8      4  state            (u32)   #543 / #548
    12      4  exit_status      (u32)   #548 / #556 (sys_exit)
    16      8  user_pml4_pa     (u64)   #548
    24      8  (pad / kernel_stack ptr — reserved, not yet consumed)
    32    120  regs_save[15]    (u64×15) #562 (r15-m7-001, RSP@+32, RIP@+40)
   152     16  (reserved — used by #564 for saved GPR overflow)
   168    256  fd_table         (u64×32) #549 (r15-m5-007)
   424      8  (reserved — earmarked for kernel_stack; #562 idle_init
                justification references it as deferred)
   432      8  runq_next        (u64)   #563 (THIS ISSUE)
   440      8  runq_prev        (u64)   #563 (THIS ISSUE)
   448   1776  (reserved for future — signal_mask, timers, cgroup, etc.)
  2224    ---  total struct size (== 278 u64s, matches _idle_task_slot &
                _task_pool slot size — no growth)
```

### 2.2 Why +432 / +440 (not +424 / +432)

Both offsets are 8-byte aligned; both fit in `disp8` reach from `rdi`
(≤127 rules out `disp8`, both need `disp32` — this is a non-issue since
x86-64 encodings are indifferent between `disp8` and `disp32` at the
consumer surface). The choice between them is preservation of the
`+424` slot for the previously-earmarked `kernel_stack` field. The
`kernel_stack` reference already appears in the #562 idle_init
justification comment ("kernel_stack=0 (deferred; #564 reads
regs_save.rsp not kernel_stack)") and reserving +424 for it now avoids
a future field-motion churn when #564 or #566 embeds the top-of-stack
pointer at that slot.

Alternatives considered:

| Placement | Verdict |
|---|---|
| +424 / +432 (tighter pack)                                     | rejected — collides with `kernel_stack` earmark; forces a future two-field slide |
| +432 / +440 (this issue's choice)                              | **chosen** — clean gap for kernel_stack at +424, adjacent runq pair for pointer-comparison locality |
| +2216 / +2224 (end-of-slab, grows struct)                      | rejected — grows the slab past 2224 bytes, breaking the `[u64; 278]` shape consumed by `_idle_task_slot`, `_task_pool`, and `_witness_task_struct` |
| Out-of-slab side table (`_runq_next_table[64]`, `_runq_prev_table[64]`) | rejected — costs two indirect loads per rotate (pid → slab, then slab → index → table); defeats the O(1) rotation this issue exists to install |

### 2.3 Slab shape invariant preserved

`_idle_task_slot`, `_task_pool[i]`, and the future `_runq_witness_slot_N`
blobs are all `[u64; 278]` (2224 bytes). Placing runq fields at +432 /
+440 sits fully inside that shape — no growth, no realignment. The
`rep stosq` in `task_new` (278 iterations, #548) already zero-fills
those two bytes as a side effect, so a fresh task's off-runqueue
invariant `runq_next == 0 && runq_prev == 0` holds without any new
store in `task_new`.

Idle's `_idle_task_slot` is `.bss` zero-init: its runq fields are 0.
Idle never enters the runqueue (see §1 out-of-scope) — those zeros are
witness-only ("idle is not on any list") and are never dereferenced.

## 3. Data structure choice — doubly-linked circular list with sentinel head

### 3.1 Options considered

| Option | Enq | Deq | Rot | Empty check | Verdict |
|---|---|---|---|---|---|
| A. Singly-linked FIFO (`head` + `tail` ptrs)          | O(1) at tail | **O(n)** (must walk to find predecessor) | O(1) | `head == 0` | rejected — dequeue-not-at-head is O(n); `sched_dequeue(task)` is called from `sys_exit`, `wait_on_fd`, `sched_switch` on every state exit and must be O(1) |
| B. Doubly-linked, NULL-terminated (`head` + `tail` ptrs) | O(1) at tail | O(1)  | O(1) | `head == 0` | plausible — but empty-check branch appears in every operation; head/tail special-cased at four ends |
| C. **Doubly-linked circular with sentinel head**       | O(1) at tail | O(1) | O(1) | `head.next == &head` | **chosen** — no NULL branches inside enq/deq bodies; empty is a self-referential state not a special value |
| D. Two linked lists (RUNNABLE + WAITING) unified via `state` field | O(1) | O(1) | O(1) | — | deferred — the WAITING side lands with #567; single-list first |

### 3.2 Why C — sentinel-simplifies-branches

**Circular means the tail's `next` is the sentinel and the sentinel's
`prev` is the tail.** Insertion at tail becomes "insert immediately
before sentinel"; rotation becomes "unlink sentinel.next, insert at
tail" — both without a single conditional. The three-instruction cost
of the sentinel comparison (`cmp head.next, &head; je pick_empty`) is
paid once per pick, not per link mutation.

**Sentinel means enq/deq have no NULL branches in the mutation body.**
In Option B, `runq_dequeue(task)` must ask "am I the head? am I the
tail? both?" and branch four ways. In Option C, the four "neighbor"
writes (`task.prev.next = task.next` and `task.next.prev = task.prev`)
apply uniformly whether the neighbors are real tasks or the sentinel —
the sentinel's fields are just more memory to write.

**Register discipline is minimal.** Every one of `runq_enqueue`,
`runq_dequeue`, and the pick_next rotation body fits in caller-save
registers (`rax`, `rcx`, `rdi`) — no callee-save spills, no push/pop
prologue/epilogue. This matters because #565 (LAPIC-timer preemptive)
calls `sched_pick_next_r15` from an ISR body where minimizing the
prologue is bounded-latency guarantee territory.

### 3.3 The sentinel storage — `_runq_head_slot`

```
// src/kernel/core/sched/runqueue.pdx

// Sentinel head of the runqueue's doubly-linked circular list.
// Only the two u64s at +432 (next) and +440 (prev) are meaningful;
// the surrounding 432 bytes are dead weight paid for shape uniformity
// with real task slots (so runq_enqueue/dequeue don't have to test
// "am I writing into a sentinel or a task"). 448 bytes (56 u64s) is
// the minimal size that keeps +432 and +440 in-slab.
//
// Post-runq_init invariant:
//   _runq_head_slot[54] (= +432 = next) == &_runq_head_slot
//   _runq_head_slot[55] (= +440 = prev) == &_runq_head_slot
// which is the canonical "empty circular list" state.
pub let mut _runq_head_slot : [u64; 56] = uninit @align(8)
```

Rationale for 448 bytes (not the full 2224):

- 448 is the smallest multiple of 8 that keeps `+440` in-bounds.
  Wasting 432 bytes on the sentinel is cheaper than the alternative
  (an out-of-slab side table, see §2.2 Alternatives).
- 448 vs 2224 costs 1776 bytes — negligible against the ~16 KiB kernel
  BSS, and buys "sentinel and task have identical field-write cost"
  which the enq/deq bodies rely on.
- `_task_pool[i]` and `_idle_task_slot` remain 2224 bytes; only the
  sentinel is truncated. Pointer arithmetic on the sentinel is *only*
  via `+432` and `+440`, never via `+2224` end-of-slab bounds.

## 4. `runq_init` — initialize the sentinel

```
// src/kernel/core/sched/runqueue.pdx  — new function

pub let runq_init : () -> () !{mem} @{boot} = fn () -> unsafe {
  effects: { mem },
  capabilities: { boot },
  justification: "R15-M7-002 (#563): runqueue bootstrap — set _runq_head_slot.next = _runq_head_slot.prev = &_runq_head_slot, establishing the canonical empty-circular-list invariant. Called once from kernel_main before any pick_next call (including idle_witness sub-test 4, which after this issue reads _runq_head_slot). Register discipline: rax scratch only (caller-save). Idempotent: safe to re-call. Leaf (no calls).",
  block: {
    lea rax, [rip + _runq_head_slot];
    mov [rax + 432], rax;               // head.next = &head
    mov [rax + 440], rax;               // head.prev = &head
    ret
  }
}
```

**Call site.** In `kernel_main.pdx`, insert `call runq_init`
**immediately before** the existing `call idle_init` line inside the
`idle_witness` block (or, equivalently, just before `idle_witness:`).
This ensures:

- idle_witness sub-test 4 — which after this issue calls the rewritten
  pick_next — sees `_runq_head_slot.next == &_runq_head_slot` (empty)
  and falls through to `_idle_tcb`. Sub-test 4's semantic (returns
  idle when nothing is runnable) is preserved.
- The runqueue witness in §7 starts from a known-empty runqueue.

An alternative is to bundle `call runq_init` into `idle_init` so the
scheduler bootstrap is a single call. Rejected: `idle_init` is
idle-specific (publishes `_idle_tcb`, populates `regs_save` for
idle_code); mixing the runqueue sentinel into it conflates two
concerns. The explicit `call runq_init` in kernel_main is cheaper to
read and cheaper to move if #566 refactors the SMP bootstrap.

## 5. `runq_enqueue(task)` — O(1) tail insertion

```
// src/kernel/core/sched/runqueue.pdx  — new function

pub let runq_enqueue : (u64) -> () !{mem} @{sched} = fn (task: u64) -> unsafe {
  effects: { mem },
  capabilities: { sched },
  justification: "R15-M7-002 (#563): insert `task` at the runqueue tail (immediately before the sentinel). Sequence: (1) load head addr into rax. (2) load current tail (= head.prev) into rcx. (3) task.next = &head. (4) task.prev = tail. (5) tail.next = task. (6) head.prev = task. Correctness on empty list: head.next == head.prev == &head, so `tail` == &head; the four link-writes make head.next = task, head.prev = task, task.next = task.prev = &head — exactly the single-element circular state. Correctness on one-element list rotate: identical to enqueue-then-dequeue at head, so this function alone (called after runq_dequeue in pick_next) handles the rotate. Register discipline: rax/rcx scratch; rdi = task (caller-provided). All caller-save. Callee-save clean. Leaf.",
  block: {
    lea rax, [rip + _runq_head_slot];   // rax = &head
    mov rcx, [rax + 440];               // rcx = head.prev (current tail)
    mov [rdi + 432], rax;               // task.next = &head
    mov [rdi + 440], rcx;               // task.prev = tail
    mov [rcx + 432], rdi;               // tail.next = task
    mov [rax + 440], rdi;               // head.prev = task
    ret
  }
}
```

**Contract:** caller guarantees `task != 0` and `task != &_runq_head_slot`.
No bounds check by policy — enqueueing NULL corrupts head.prev.next
(unmapped write, #PF); enqueueing the sentinel corrupts head. Both are
kernel bugs, not runtime conditions. R16.M3 syscall boundary validates
task pointers.

**Contract:** caller guarantees `task` is not already on the runqueue.
Double-enqueue would splice the sentinel out of the list; detected only
by the invariant sanity check in §7 (witness). At R15.M7 all enqueue
callers are trusted (this issue's witness + #564 sched_switch). #567
adds a state-machine check (`state == STATE_RUNNABLE` implies
"presumed on runq") when the enqueue-on-wake path lands.

## 6. `runq_dequeue(task)` — O(1) unlink

```
// src/kernel/core/sched/runqueue.pdx  — new function

pub let runq_dequeue : (u64) -> () !{mem} @{sched} = fn (task: u64) -> unsafe {
  effects: { mem },
  capabilities: { sched },
  justification: "R15-M7-002 (#563): unlink `task` from its current position in the runqueue. Sequence: (1) rax = task.next. (2) rcx = task.prev. (3) rax.prev = rcx (patch successor's back-pointer). (4) rcx.next = rax (patch predecessor's forward-pointer). (5) task.next = task.prev = 0 (NULL-out for the off-runqueue witness invariant). Correctness on single-element list: task.next == task.prev == &head; step 3 writes head.prev = &head and step 4 writes head.next = &head — the canonical empty state. Correctness in general: sentinel is treated identically to a task in the link-writes, so no NULL-branch needed. Register discipline: rax/rcx scratch; rdi = task. All caller-save. Callee-save clean. Leaf.",
  block: {
    mov rax, [rdi + 432];               // rax = task.next
    mov rcx, [rdi + 440];               // rcx = task.prev
    mov [rax + 440], rcx;               // task.next.prev = task.prev
    mov [rcx + 432], rax;               // task.prev.next = task.next
    mov qword ptr [rdi + 432], 0;       // task.next = NULL
    mov qword ptr [rdi + 440], 0;       // task.prev = NULL
    ret
  }
}
```

**Contract:** caller guarantees `task` is on the runqueue (or is the
sentinel — but callers should never dequeue the sentinel). Dequeueing
an off-runqueue task (`task.next == 0`) writes into address 0 (#PF) —
kernel bug. At R15.M7 all dequeue callers are trusted (this issue's
witness + #564 sched_switch on state exit). #567 adds a "task->state !=
STATE_RUNNABLE → skip dequeue" branch when the block-on-wait path lands.

**Post-condition:** `task.next == 0 && task.prev == 0` — the
off-runqueue witness invariant. This lets any later caller test "is
this task on a runqueue?" with `cmp [rdi + 432], 0`; used by #567.

## 7. `sched_pick_next_r15` rewrite — O(1) rotate + idle fallback

The R15.M7-001 body (O(64) `_pid_table` linear scan) is **replaced
entirely** with an O(1) circular-list rotate. The public signature and
name are unchanged: existing callers (idle_witness sub-test 4) work
without edit.

```
// src/kernel/core/sched/pick_next.pdx  — REWRITE of sched_pick_next_r15

pub let sched_pick_next_r15 : () -> u64 !{mem} @{sched} = fn () -> unsafe {
  effects: { mem },
  capabilities: { sched },
  justification: "R15-M7-002 (#563): O(1) round-robin pick — read head.next; if it's the sentinel (empty list), return _idle_tcb; otherwise rotate head.next to the tail position and return it. Rotate implementation: dequeue head.next, enqueue at tail — inlined here rather than calling runq_dequeue + runq_enqueue to save two ret sequences (this function is called from the LAPIC timer ISR at #565 and is on the bounded-latency hot path). Register discipline: rax (head addr / return), rcx (temp for chain writes), rdi (picked task ptr). All caller-save. Callee-save clean. Leaf. Replaces the R15.M7-001 O(64) _pid_table scan; the semantic contract (returns a RUNNABLE task or _idle_tcb) is unchanged, only the implementation and the source of RUNNABLE-ness (list membership vs. state field).",
  block: {
    lea rax, [rip + _runq_head_slot];      // rax = &head
    mov rdi, [rax + 432];                  // rdi = head.next (candidate)
    cmp rdi, rax;                          // list empty?
    je  pick_empty;                        // yes → return idle

    // ----- inline rotate: move rdi from head-position to tail-position -----
    // (1) Unlink rdi:
    //   head.next  = rdi.next
    //   rdi.next.prev = &head
    mov rcx, [rdi + 432];                  // rcx = rdi.next
    mov [rax + 432], rcx;                  // head.next = rdi.next
    mov [rcx + 440], rax;                  // rdi.next.prev = &head

    // (2) Re-insert rdi at tail (before head):
    //   tail_new = head.prev  (may be &head if rdi was sole element)
    //   rdi.next = &head
    //   rdi.prev = tail_new
    //   tail_new.next = rdi
    //   head.prev = rdi
    mov rcx, [rax + 440];                  // rcx = current tail (may be &head)
    mov [rdi + 432], rax;                  // rdi.next = &head
    mov [rdi + 440], rcx;                  // rdi.prev = tail_new
    mov [rcx + 432], rdi;                  // tail_new.next = rdi
    mov [rax + 440], rdi;                  // head.prev = rdi

    mov rax, rdi;                          // return picked task
    ret;

  pick_empty:
    mov rax, [rip + _idle_tcb];            // fallback: idle
    ret
  }
}
```

### 7.1 Single-element rotation is a no-op — proof by trace

Given: `head.next = T`, `head.prev = T`, `T.next = &head`, `T.prev = &head`.
Registers on entry: `rax = &head`, then `rdi = T`.

1. `rcx = T.next = &head`
2. `head.next = &head` (writes `[rax + 432] = &head`)
3. `head.prev = &head` (writes `[rcx + 440] = rax`, and `rcx == rax`)
4. `rcx = head.prev = &head` (just written in step 3)
5. `T.next = &head`
6. `T.prev = &head` (writes `[rdi + 440] = rcx`, and `rcx == &head`)
7. `head.next = T` (writes `[rcx + 432] = rdi`, and `rcx == rax`)
8. `head.prev = T`

Final: `head.next = T`, `head.prev = T`, `T.next = &head`,
`T.prev = &head` — identical to the entry state. Correct.

### 7.2 Multi-element rotation preserves order — proof sketch

Given: `head.next = T1, T1.next = T2, ..., T5.next = &head`,
`head.prev = T5, T5.prev = T4, ..., T1.prev = &head`.

- Step 1: `rcx = T1.next = T2`
- Step 2: `head.next = T2`
- Step 3: `T2.prev = &head`
- Step 4: `rcx = head.prev = T5`
- Step 5: `T1.next = &head`
- Step 6: `T1.prev = T5`
- Step 7: `T5.next = T1`
- Step 8: `head.prev = T1`

Final: `head.next = T2, T2.next = T3, ..., T5.next = T1, T1.next = &head`.
The list has rotated: T1 moved from position 1 to position 5. On the
next call, T2 rotates to the tail, and so on — round-robin.

### 7.3 Why inline rotate instead of calling runq_dequeue + runq_enqueue

Two ret/call pairs cost ~4 cycles + return-stack pressure per pick. At
100 Hz timer (#565) that's ~800 cycles/second of avoidable overhead —
irrelevant now, relevant later. More materially: `runq_dequeue`'s
NULL-out of `task.next` / `task.prev` (the last two writes) would be
immediately overwritten by `runq_enqueue`, so the pair does 4 dead
writes per rotate. Inline pick fuses the two operations and drops the
dead writes.

The `runq_enqueue` / `runq_dequeue` primitives remain — they're the
API #564 sched_switch and #567 wake_from_waiting will use for
non-rotation transitions (task enters/leaves the runq due to state
change, not due to being picked).

## 8. Witness pattern — 3 sub-tests, 1 marker

Insert into `boot_continue_after_ring3` (kernel_main.pdx),
**immediately after** the existing `idle_witness_exit:` label (line
~1703) and **before** the `R14b-m5-007` IPI witness (line ~1705). The
runq witness runs after idle_witness so that idle_witness sub-test 4
(which after this issue reads `_runq_head_slot`) sees a clean
empty-post-init runqueue.

Fingerprint marker: `R15 RUNQUEUE OK`.

```
      // ============================================================
      // R15-M7-002 (#563): runqueue witness — 3 sub-tests, 1 marker
      // ============================================================
      runq_witness:
          // Precondition: runq_init has been called (see kernel_main
          // insertion §4). _runq_head_slot.next == _runq_head_slot.prev
          // == &_runq_head_slot (empty circular list).

          // ---------- Sub-test A: empty runqueue → sched_pick_next_r15 returns _idle_tcb ----------
          call sched_pick_next_r15;
          mov r12, [rip + _idle_tcb];
          cmp rax, r12;
          jne runq_witness_fail;

          // ---------- Sub-test B: enqueue 5 tasks; 5 picks round-robin ----------
          // Use 5 dedicated bss stubs (see storage §8.1). Enqueue in
          // order 1..5; pick_next must return them in the same order.
          lea rdi, [rip + _runq_witness_task_1];
          call runq_enqueue;
          lea rdi, [rip + _runq_witness_task_2];
          call runq_enqueue;
          lea rdi, [rip + _runq_witness_task_3];
          call runq_enqueue;
          lea rdi, [rip + _runq_witness_task_4];
          call runq_enqueue;
          lea rdi, [rip + _runq_witness_task_5];
          call runq_enqueue;

          // Pick #1 must return _runq_witness_task_1
          call sched_pick_next_r15;
          lea rcx, [rip + _runq_witness_task_1];
          cmp rax, rcx;
          jne runq_witness_fail;

          // Pick #2 must return _runq_witness_task_2
          call sched_pick_next_r15;
          lea rcx, [rip + _runq_witness_task_2];
          cmp rax, rcx;
          jne runq_witness_fail;

          // Pick #3 must return _runq_witness_task_3
          call sched_pick_next_r15;
          lea rcx, [rip + _runq_witness_task_3];
          cmp rax, rcx;
          jne runq_witness_fail;

          // Pick #4 must return _runq_witness_task_4
          call sched_pick_next_r15;
          lea rcx, [rip + _runq_witness_task_4];
          cmp rax, rcx;
          jne runq_witness_fail;

          // Pick #5 must return _runq_witness_task_5
          call sched_pick_next_r15;
          lea rcx, [rip + _runq_witness_task_5];
          cmp rax, rcx;
          jne runq_witness_fail;

          // After 5 picks, the list has rotated a full cycle — order
          // is (task_1, task_2, task_3, task_4, task_5) again from head.

          // ---------- Sub-test C: dequeue task_3, 4 picks skip it ----------
          lea rdi, [rip + _runq_witness_task_3];
          call runq_dequeue;

          // Assert: task_3's runq_next and runq_prev are NULL
          lea rcx, [rip + _runq_witness_task_3];
          mov rax, [rcx + 432];
          cmp rax, 0;
          jne runq_witness_fail;
          mov rax, [rcx + 440];
          cmp rax, 0;
          jne runq_witness_fail;

          // Pick #6 must return task_1 (task_3 skipped)
          call sched_pick_next_r15;
          lea rcx, [rip + _runq_witness_task_1];
          cmp rax, rcx;
          jne runq_witness_fail;

          // Pick #7 must return task_2
          call sched_pick_next_r15;
          lea rcx, [rip + _runq_witness_task_2];
          cmp rax, rcx;
          jne runq_witness_fail;

          // Pick #8 must return task_4 (task_3 not in list)
          call sched_pick_next_r15;
          lea rcx, [rip + _runq_witness_task_4];
          cmp rax, rcx;
          jne runq_witness_fail;

          // Pick #9 must return task_5
          call sched_pick_next_r15;
          lea rcx, [rip + _runq_witness_task_5];
          cmp rax, rcx;
          jne runq_witness_fail;

          // ---------- Drain: dequeue remaining 4, verify empty ----------
          lea rdi, [rip + _runq_witness_task_1];
          call runq_dequeue;
          lea rdi, [rip + _runq_witness_task_2];
          call runq_dequeue;
          lea rdi, [rip + _runq_witness_task_4];
          call runq_dequeue;
          lea rdi, [rip + _runq_witness_task_5];
          call runq_dequeue;

          // Assert empty: head.next == &head
          lea rax, [rip + _runq_head_slot];
          mov rcx, [rax + 432];
          cmp rcx, rax;
          jne runq_witness_fail;

          // Post-drain: pick returns idle again
          call sched_pick_next_r15;
          mov r12, [rip + _idle_tcb];
          cmp rax, r12;
          jne runq_witness_fail;

          // ---------- All checks green ----------
          lea rdi, [rip + runq_witness_ok_msg];
          call uart_puts;
          jmp runq_witness_exit;

      runq_witness_fail:
          lea rdi, [rip + runq_witness_fail_msg];
          call uart_puts;

      runq_witness_exit:
```

### 8.1 Witness task storage

Five dedicated 448-byte bss blobs — same shape as `_runq_head_slot`,
big enough to host `runq_next @+432` and `runq_prev @+440`. Placed in
`runqueue.pdx` (adjacent to the sentinel definition).

```
// src/kernel/core/sched/runqueue.pdx  — new bss (witness fixtures)

pub let mut _runq_witness_task_1 : [u64; 56] = uninit @align(8)
pub let mut _runq_witness_task_2 : [u64; 56] = uninit @align(8)
pub let mut _runq_witness_task_3 : [u64; 56] = uninit @align(8)
pub let mut _runq_witness_task_4 : [u64; 56] = uninit @align(8)
pub let mut _runq_witness_task_5 : [u64; 56] = uninit @align(8)
```

These are witness-only — never touched by production code. They exist
because using real `_task_pool[i]` slabs would risk polluting the
task-lifecycle witness state (the pool slots are populated by preceding
`task_new` / `sys_fork` witnesses and should not be re-linked by us).
Dedicated stubs keep the runqueue witness self-contained.

Total additional BSS: 5 × 448 = 2240 bytes. Negligible against the
kernel's ~16 KiB BSS budget.

### 8.2 Banner strings

Add to the banner constants block in kernel_main.pdx:

```
pub let runq_witness_ok_msg   : [u8; 19] = "R15 RUNQUEUE OK\r\n\0";
pub let runq_witness_fail_msg : [u8; 21] = "R15 RUNQUEUE FAIL\r\n\0";
```

### 8.3 Why 3 sub-tests (not 5) — collapsing the acceptance criteria

The AC has two clauses: "enqueue 5 → 5 picks round-robin" and "dequeue
removes from list". Sub-test A is the invariant precondition (empty →
idle). Sub-test B covers clause 1 with a positive 5-check trace.
Sub-test C covers clause 2 with a positive dequeue trace and a
skip-verification (four picks around the dequeued middle).

The drain-and-re-verify-empty tail (last block of sub-test C) closes
the loop: it proves the list can return to the initial empty state, so
subsequent code (the IPI witness that follows) sees the same runqueue
state that the idle witness saw.

### 8.4 Note on r12 usage across sub-test A and drain-verify

`r12` is callee-save, so `uart_puts` (called only at the ok/fail exit)
does not clobber it. Sub-test A parks `_idle_tcb` in r12 briefly and
compares; we reload `_idle_tcb` into r12 at the drain-verify point
rather than assuming it survived — the intervening `sched_pick_next_r15`
calls preserve r12 (it's callee-save, and pick_next's justification
declares "callee-save clean"), but reloading is cheaper to audit than
proving the invariant across nine call sites.

## 9. Interaction with #562 (idle task witness sub-test 4)

Before this issue: sub-test 4 called `sched_pick_next_r15`, which
scanned `_pid_table[1..64]` for any RUNNABLE task and returned
`_idle_tcb` when none found. The precondition analysis
(design/kernel/r15-m7-001-idle-task.md §7 last paragraph) asserted
that at that point no task was in RUNNABLE state.

After this issue: sub-test 4 calls the rewritten `sched_pick_next_r15`,
which reads `_runq_head_slot.next` and returns `_idle_tcb` when
`head.next == &head`. The new precondition is: **`runq_init` has
been called AND no task has been enqueued since**.

The kernel_main insertion in §4 places `call runq_init` immediately
before the idle_witness block, so:

1. runq_init runs → head.next = head.prev = &head (empty).
2. idle_witness sub-test 1..3 run (no runq mutation).
3. idle_witness sub-test 4 calls new pick_next → sees empty → returns idle. ✓
4. runq_witness sub-test A: still empty → returns idle. ✓
5. runq_witness sub-test B: enqueues 5, drains 5, dequeues 4 → empty. ✓

The idle-task-doc §7 precondition analysis becomes stale (it references
`_pid_table` states) but not wrong — that analysis is about state, not
runqueue membership, and states haven't changed. A one-line note in
the idle-task doc §7 pointing to this issue's rewrite is a reasonable
follow-up (non-blocking).

## 10. Deferred to follow-on issues

- **#564 (r15-m7-003 sched-switch-real).** Consumes `sched_pick_next_r15`'s
  output as the "next TCB to switch to". Does not touch `runq_next` /
  `runq_prev` directly — the runqueue rotation happens **inside**
  pick_next, so from sched_switch's perspective the returned pointer
  is just "the current TCB" for the following slice. Sched_switch is
  the first caller that reads `regs_save.rsp` / `regs_save.rip` from
  the picked task and jumps to it, closing the loop opened by #562.
- **#565 (r15-m7-004 lapic-timer 100 Hz).** Programs the timer to
  drive `sched_pick_next_r15` on each tick. Bounded-latency guarantee
  depends on pick_next being O(1) — the O(64) walk this issue replaces
  would have blown the 100 μs budget at pathological pool fill.
- **#567 (r15-m7-005 wake-from-waiting).** First transition-driven
  `runq_enqueue` caller. Adds the state-machine check
  (`state != STATE_RUNNABLE` on entry → enqueue). Symmetric
  `runq_dequeue` from `sys_wait` / `wait_on_fd` on block.
- **#568 (r15-m7-006 sched-metrics).** Distinguishes "picked a task"
  from "fell back to idle" via a counter in the empty-list branch of
  pick_next. Trivial to add — one atomic increment before
  `mov rax, [rip + _idle_tcb]`.
- **#571 (r15-m7-008 priority-levels).** Widens `_runq_head_slot` to
  `_runq_head_slot[16]` and adds a `bsr priority_bitmap` prelude to
  pick_next. Requires paideia-as #913 (bsr encoder) to land first.
- **#574 (r15-m7-009 per-CPU runqueues).** Widens further to
  `_runq_head_slot[NR_CPUS][16]` keyed by `cpu_local` GS_BASE.

## 11. Fingerprint file updates

Two files need one marker line each, inserted **between** the existing
`R15 IDLE TASK OK` line (line 22 / 21) and `IPI OK` (line 23 / 22).

**`tests/r15/expected-boot-r15-process.txt`** — add `R15 RUNQUEUE OK`
after `R15 IDLE TASK OK` and before `IPI OK`.

**`tests/r15/expected-boot-r15-ring3.txt`** — same insertion at the
symmetric position (verify the exact preceding marker; the two files
diverge only by ordering of earlier R15 witnesses).

No new smoke mode is needed — both existing modes
(`boot_r15_ring3`, `boot_r15_process`) exercise
`boot_continue_after_ring3`, so both fingerprints pick up the new
marker in-order.

## 12. Cross-linked layout doc update

**`design/kernel/task-struct-layout.md`** — freeze extension: two new
rows in the field table.

```
432      8    runq_next     : u64    // R15-M7-002 (#563)
440      8    runq_prev     : u64    // R15-M7-002 (#563)
```

If the layout doc has an "Invariants" or "Off-slab-membership rules"
section, add:

> **Off-runqueue invariant.** A task is off the runqueue iff
> `runq_next == 0 && runq_prev == 0`. `task_new` (#548) establishes
> this via `rep stosq` zero-fill; `runq_dequeue` (#563) re-establishes
> it on unlink; `runq_enqueue` (#563) violates it (writes non-NULL) as
> its post-condition.

## 13. LOC estimate

| Component                                                          | File                | Lines |
|---|---|---|
| `_runq_head_slot` declaration + 5 witness stubs                    | runqueue.pdx        | 8 |
| `runq_init` (unsafe fn, ~3 asm instructions)                       | runqueue.pdx        | 12 |
| `runq_enqueue` (unsafe fn, ~6 asm instructions)                    | runqueue.pdx        | 18 |
| `runq_dequeue` (unsafe fn, ~6 asm instructions)                    | runqueue.pdx        | 18 |
| `sched_pick_next_r15` REWRITE (unsafe fn, ~14 asm instructions)    | pick_next.pdx       | 30 (net: replaces existing ~25 LOC, delta ~+5) |
| `call runq_init` insertion + banner-string decls                   | kernel_main.pdx     | 6 |
| Witness block (3 sub-tests + drain + empty re-verify)              | kernel_main.pdx     | 85 |
| `expected-boot-r15-process.txt` marker line                        | tests/r15/          | 1 |
| `expected-boot-r15-ring3.txt` marker line                          | tests/r15/          | 1 |
| Layout-doc freeze extension                                        | design/kernel/      | 4 |
| **Total (net new)**                                                |                     | **~180 LOC** |

Encoder gaps expected: **none**. Every instruction lands on
already-audited paideia-as encodings (`lea`, `mov r/m64`, `mov m64,imm32`
for the NULL-out, `cmp`, `je`, `jne`, `call`, `ret`). The
`mov qword ptr [rdi + 432], 0` form is already exercised by
`aspace_map.pdx` zero-writes and `pid_free`.

## 14. Tractability

**Green.** Every design decision is either (a) a shape reuse of an
already-landed pattern (slab-in-.bss, unsafe-block asm justification,
witness/fingerprint pair, `rep stosq` zero-fill in task_new) or (b) a
small, isolated new artifact (`_runq_head_slot` 448-byte sentinel, 3
new primitives ≤ 6 instructions each). Zero encoder gaps.

Cross-module surface changes are minimal:

- `sched_pick_next_r15` — rewritten in-place; signature unchanged;
  callers (idle_witness sub-test 4) work without edit. Semantic
  contract preserved: "returns a RUNNABLE task or `_idle_tcb`".
- `task_new` — untouched; `rep stosq` already zeroes the two new
  fields as a side effect.
- Layout doc — two-row freeze extension only, no field motion.

**Live risks:**

1. **Runqueue initialization ordering.** If a future caller invokes
   `sched_pick_next_r15` before `runq_init`, it will read `head.next
   == 0` (bss zero), compare it against `&_runq_head_slot` (non-zero),
   *not* recognize the empty state, and dereference NULL. Mitigation:
   `runq_init` is called from `boot_continue_after_ring3` before any
   witness runs; the only pre-witness caller is the (deferred) #565
   timer ISR, which cannot fire before the boot prologue completes.
   #566 (SMP hooks) will need per-CPU runq_init.

2. **Double-enqueue corruption.** `runq_enqueue` with a
   task-already-on-runq splices the sentinel out of the ring — pick_next
   then walks garbage until it hits an unmapped page. At R15.M7 all
   enqueue callers are trusted; #567 adds a state-machine guard
   (`state == RUNNABLE` on entry to `wake_from_waiting` implies "already
   on runq, skip"). No defensive check inside `runq_enqueue` — kernel
   invariants are checked by convention, not by runtime cost.

3. **Offset freeze churn.** If #564 or #567 wants `runq_next` /
   `runq_prev` at different offsets, three sites migrate: `runq_enqueue`
   (2 stores), `runq_dequeue` (4 stores including NULL-out), and
   `sched_pick_next_r15` (5 loads/stores). Total: 11 immediate-offset
   fixes, all `disp32 + 8`. The choice of +432/+440 (over +424/+432)
   preserves +424 for the earmarked `kernel_stack`, avoiding this
   migration when #564 lands.

The one design decision that could be second-guessed later is the
448-byte sentinel size — if slab-shape uniformity ever demands a
full 2224-byte sentinel (e.g., for a debugger walking task lists that
tests `state @+8` on every entry), we grow the declaration from
`[u64; 56]` to `[u64; 278]`. Nothing else changes; no code-site edits.
