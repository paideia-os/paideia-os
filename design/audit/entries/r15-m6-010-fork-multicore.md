---
audit_id: r15-m6-010-fork-multicore
issue: 561
files:
  - src/kernel/core/mm/aspace_clone.pdx
  - src/kernel/core/mm/frame_meta.pdx
  - src/kernel/core/mm/phys_alloc.pdx
  - src/kernel/core/mm/phys_free.pdx
  - src/kernel/core/sched/task_pool.pdx
  - src/kernel/core/syscall/handlers/sys_fork.pdx
  - src/kernel/core/syscall/handlers/sys_wait.pdx
  - src/kernel/core/syscall/handlers/sys_exit.pdx
  - src/kernel/core/fs/fd_table.pdx
effects: [mem, sysreg]
capabilities: []
reviewed_by:
date: 2026-07-18
status: draft
blocks: [PA-R13-012]
depends_on:
  landed_primitives: [545, 548, 549, 552, 555, 556, 557, 558, 559]
  phase_c_blocked: [553, 661]
---

# AUDIT R15-M6-010 — Fork/Exec/Wait multicore race audit (Path A)

## 0. Purpose and scope

R15.M6 landed the fork/exec/wait primitives against a single-CPU kernel. The
Path A composition (task_new + aspace_clone_cow + fd_copy + wait/exit) works
correctly today because the kernel executes one CPU-thread at a time and no
preemption crosses primitive boundaries. This audit inventories every site
that would race under multi-CPU. Each site carries a `TODO(PA-R13-012)` tag,
a race-scenario sketch, an impact class (data corruption vs refcount leak vs
zombie orphan vs stale FD), a fix approach chosen to be the *simplest*
adequate primitive (LOCK CMPXCHG, LOCK XADD, per-CPU struct, or a
short-lived spinlock), and a LOC diff estimate.

The audit doc lands under #561 as a landing gate. The fixes wait for
PA-R13-012 in paideia-as (`xchg [mem], reg`, `lock cmpxchg`, `lock` prefix,
`mfence`) — see `design/milestones/r14b-master-plan.md` — and for the R15.M7
SMP promotion round (per-CPU GS data, SIPI, AP bootstrap).

**Scope discipline.** This audit covers only the landed R15.M6 primitives.
Blocked Phase C paths (#553 `pf_handler_cow`, #661 fast-flip) will get their
own audit when they land. Non-M6 subsystems (scheduler runqueue, IPC ports,
capability tables) are audited elsewhere.

**Path A vs Path B.** Path A = correct-but-inefficient (coarse spinlocks;
one CPU at a time in each MM primitive). Path B (per-CPU freelists,
percpu magazines, lock-free bitmap allocator) is post-R15.M7. This audit
scopes Path A only.

---

## 1. Race-site summary table

| # | Site | File:Function | Impact | Fix | LOC |
|---|------|---------------|--------|-----|-----|
| 1 | Refcount RMW (incref)         | `frame_meta.pdx:frame_meta_incref` (117-123)      | Refcount leak / lost update → premature free | `LOCK XADD` | 2 |
| 2 | Refcount RMW (decref)         | `phys_free.pdx:phys_free` (49-56)                  | Refcount leak / double-free of frame | `LOCK CMPXCHG` loop or `LOCK XADD` + rescue | 10 |
| 3 | Bitmap RMW (alloc set-bit)    | `phys_alloc.pdx:phys_alloc` (44-79)                | Two CPUs allocate same page → memory corruption | `LOCK CMPXCHG` on word | 12 |
| 4 | Bitmap RMW (free clear-bit)   | `phys_free.pdx:phys_free` (65-74)                  | Torn word / lost bit clear → leaked frame | `LOCK CMPXCHG` on word | 10 |
| 5 | Refcount init after alloc     | `phys_alloc.pdx:phys_alloc` (83-84)                | Init store loses vs concurrent incref (impossible until published) — but only if publish reordered | `mfence` after publish; store is safe order | 2 |
| 6 | Bitmap-frame-meta invariant   | `phys_alloc.pdx` <-> `frame_meta.pdx`              | Semantic invariant `bit_set == refcount>=1` breaks across CPUs mid-sequence | Hold `phys_lock` across bitmap set + meta init | 6 (shared with #3) |
| 7 | pid_alloc non-reserving scan  | `task_pool.pdx:pid_alloc` (33-43)                  | Two CPUs get same pid → collision in `_pid_table` publish → orphaned task_struct | Convert scan+publish to `LOCK CMPXCHG` on `_pid_table[i]` (reserve on find) | 15 |
| 8 | `_pid_table[pid]` publish     | `task_pool.pdx:task_new` step 7 (122-123)          | Overwrites reservation from concurrent pid_alloc | Fused into fix #7 | 0 (shared) |
| 9 | Src-PTE CoW rewrite           | `aspace_clone.pdx:aspace_clone_cow` L4 (195-199)   | Concurrent read on src aspace observes torn RW/COW transition | `LOCK CMPXCHG` on PTE + shootdown IPI to src CPUs | 20 |
| 10 | Src-PTE TLB coherence         | `aspace_clone.pdx:aspace_clone_cow` (walker post-rewrite) | Sibling CPU using src aspace has stale RW TLB entry → silent write bypasses CoW | TLB shootdown IPI per rewritten leaf (or aggregate) | 25 |
| 11 | Nested aspace_map on shared dst | `aspace_clone.pdx:aspace_clone_cow` (line 235)   | dst is fresh so races are impossible today; audited only for future path where dst is pre-live | Sequencing note; no change today | 0 |
| 12 | fd_table copy loop            | `sys_fork.pdx:sys_fork_body` (52-59)               | Parent sys_open/sys_close concurrent with fork → child gets torn fd view (some slots pre-open, some post) | Snapshot under `parent->fd_lock` OR require caller to hold parent locked | 8 |
| 13 | fd_set store                  | `fd_table.pdx:fd_set` (36)                         | Aligned 8B store is TSO-atomic — but no fence w.r.t. subsequent fd_alloc scan | Add release ordering (`sfence` on write side is unnecessary on x86 TSO; commit is publish) | 2 |
| 14 | fd_alloc non-reserving scan   | `fd_table.pdx:fd_alloc` (50-58)                    | Two threads (same aspace) alloc same fd → double-open | `LOCK CMPXCHG` on `fd[i]` (reserve on find) | 12 |
| 15 | sys_wait pid_table scan       | `sys_wait.pdx:sys_wait_body` (27-44)               | Sees mid-transition child (state store not fenced) → misses ZOMBIE this pass; harmless if we then block, but interacts with #17 | Acquire `pid_table_lock` for scan; release-ordered state store on sys_exit | 8 |
| 16 | sys_wait double-reap          | `sys_wait.pdx:sys_wait_body` (46-51)               | Two sys_wait on same parent see same ZOMBIE child → both call `pid_free` → double free of pid slot; second waiter returns stale pid | Fold ZOMBIE-observe + pid_free into atomic `LOCK CMPXCHG` on `_pid_table[pid]` from `slab` → `0` | 12 |
| 17 | sys_wait state=WAITING publish | `sys_wait.pdx:sys_wait_body` (60-61)              | Writer sets WAITING after scan; concurrent child sys_exit could observe non-WAITING and skip wakeup → wait sleeps forever | Rendezvous under `parent->lock`: scan + state-set + child-check under same lock | 15 |
| 18 | sys_exit ZOMBIE publish       | `sys_exit.pdx:sys_exit_body` step 1 (73-74)        | Same ordering issue as #17 mirrored: publish ZOMBIE, then check parent WAITING — parent may transition in between | Same rendezvous protocol as #17 | 0 (shared) |
| 19 | orphan_adopt walker           | `sys_exit.pdx:orphan_adopt` (36-60)                | Concurrent task_new for the exiting parent's pid (post-pid_free) would let a fresh task inherit ex-orphans; concurrent sys_exit of a child could observe stale parent_pid | Serialize orphan walker under `pid_table_lock` (from #7) | 6 |
| 20 | sys_exit parent-slot lookup   | `sys_exit.pdx:sys_exit_body` step 4-6 (92-109)     | Use-after-free: parent slab reclaimed by concurrent parent-exit + `pid_free` between our load and wakeup | Hold `pid_table_lock` from load through wakeup; or grab per-parent refcount | 20 |
| 21 | sys_exit wakeup store order   | `sys_exit.pdx:sys_exit_body` (103-109)             | Three stores (wait_result_pid, wait_result_status, state=RUNNABLE); x86-64 TSO gives per-CPU total-order but reader on another CPU needs `mfence` for RUNNABLE to be the last-visible store | Insert `mfence` before state store (or `xchg` on state which is implicitly locked) | 3 |
| 22 | task_new pid_table publish + slab-zero visibility | `task_pool.pdx:task_new` step 6-7 (105-123) | Reader in another CPU sees pid_table[pid] pointing to slab but slab fields not yet visible (stale-zero read) | `mfence` between rep-stosq/field-stores and `_pid_table` publish store | 3 |

**Row count: 22 sites.** #6, #8, #11, #18 do not add LOC — they are
sequencing / justification notes tied to a neighbour fix.

**Total unique LOC delta estimate: ~185 LOC** (see §5).

---

## 2. Per-site prose

### 2.1 Refcount RMW — `frame_meta_incref`

**Location.** `src/kernel/core/mm/frame_meta.pdx:117-123`, function
`frame_meta_incref`.

**Race scenario.** CPU-A and CPU-B both fork the same parent
concurrently. Both walkers reach the same L4 leaf (shared library
mapping, say libc `.text` frame). Both call `frame_meta_incref(frame_pa)`.
The three-instruction RMW body

```
mov rcx, [rax + rdi*8]   ; read
add rcx, 1               ; +1
mov [rax + rdi*8], rcx   ; write
```

executes as A-read (0) → B-read (0) → A-add (1) → B-add (1) → A-write (1)
→ B-write (1). Final refcount is 1 despite two increments.

**Impact.** Refcount underflow at teardown. First child's teardown
decrements 1 → 0 → phys_free clears the bitmap bit → sibling child now
has a mapping to a frame the pool believes free → next phys_alloc hands
out the still-live frame → memory corruption.

**Fix.** Replace the three-instruction RMW with `lock xadd`. `xadd`
returns old value in the source register; add 1 to it to get the new
count (return contract preserved).

```
lea rax, [rip + _frame_meta]
mov rcx, 1
lock xadd [rax + rdi*8], rcx   ; rcx = old value
add rcx, 1                     ; rcx = new value
mov rax, rcx
ret
```

**LOC delta.** -3 lines + 4 lines = **+1 net; 2 lines edited.** Round to
**2 LOC**.

**TODO tag site.** Above the RMW block:
```
// TODO(PA-R13-012): replace read-add-write with `lock xadd`; see
//                    design/audit/entries/r15-m6-010-fork-multicore.md §2.1.
```

---

### 2.2 Refcount RMW — `phys_free` decref

**Location.** `src/kernel/core/mm/phys_free.pdx:49-56`.

**Race scenario.** Mirror of §2.1 on the decrement side, but the guard
adds a second race window: read → cmp 0 (idempotency check) → sub 1 →
store. Concurrent incref of the same slot from another aspace (sharing
the frame) between cmp and store loses the +1, potentially producing a
0 decref that shouldn't free the frame (if the incref had already
committed).

**Impact.** Premature frame release: bitmap bit cleared while another
CPU's aspace still holds a CoW mapping to the frame. Next phys_alloc
hands out the still-mapped frame; use-after-free class corruption.

**Fix.** Two-step: (a) atomic decrement via `lock xadd` with -1
(equivalent to `lock dec` but usable for the "was zero?" guard because
we get the old value). (b) On old_value == 0, we performed a spurious
decrement — undo with `lock xadd` +1 and return OK (idempotent path). On
old_value == 1, fall through to bitmap clear. On old_value > 1, return
OK-still-shared.

```
mov rcx, 0xFFFFFFFFFFFFFFFF     ; -1
lock xadd [r10 + rdi*8], rcx    ; rcx = old
cmp rcx, 0
je  phys_free_undo_zero          ; was already 0 → we went to -1; undo
cmp rcx, 1
jne phys_free_still_shared
; fall through: old was 1, new is 0, free the bit
```

**LOC delta.** ~10 LOC (undo path adds a small block).

**TODO tag site.** At the top of the guard block.

---

### 2.3 Bitmap RMW — `phys_alloc` set-bit

**Location.** `src/kernel/core/mm/phys_alloc.pdx:44-79`.

**Race scenario.** Two CPUs concurrently allocate. Both scan the same
word, both find the same first-zero bit (say bit 5 of word 0). Both
compute the OR mask `1 << 5`. Both do:

```
mov r9, [rax + rdx*8]   ; both read word=0
or  r9, r8              ; both compute word |= (1<<5)
mov [rax + rdx*8], r9   ; both write
```

Under TSO the final word is `1<<5` regardless of interleave — but each
CPU proceeds to compute `page_index = word*64 + 5 = 5`, both return the
same VA, and then both call `frame_meta[5] = 1`. Two sibling processes
now own physical page 5.

**Impact.** Memory corruption; the two processes have independent
mappings to the same frame. Every "process isolation" invariant fails.

**Fix.** CAS loop on the bitmap word: read old, compute new (old | mask),
`lock cmpxchg` old→new; retry on failure. On failure, the concurrent CPU
took our bit — restart the bit-scan on the fresh word.

```
retry:
  mov r9, [rax + rdx*8]           ; old
  ; find first zero bit → rcx (unchanged from current logic)
  ; if word is 0xFF..FF → next_word
  mov r8, 1
  mov cl, cl                       ; safe shift
  shl r8, cl                       ; r8 = mask
  mov r11, r9                      ; r11 = expected
  or  r9, r8                       ; r9 = new
  mov rax_scratch, r11
  lock cmpxchg [rax + rdx*8], r9   ; RAX=expected, [mem]=new on success
  jne retry                        ; another CPU raced
```

**LOC delta.** ~12 LOC (the CAS loop; keeps the outer word-scan).

**TODO tag site.** Just above `scan_loop:`.

---

### 2.4 Bitmap RMW — `phys_free` clear-bit

**Location.** `src/kernel/core/mm/phys_free.pdx:65-74`.

**Race scenario.** Concurrent alloc + free on the same bitmap word. Free
reads word, computes `word & ~mask`, writes; alloc reads word (perhaps
older value), computes `word | mask'`, writes. Lost update: either the
alloc'd bit is dropped (freed frame reallocated to nobody) or the freed
bit is re-set (allocator misses the release).

**Impact.** Frame leak (bit stays set forever) OR two-CPU allocation of
same frame (mirror of §2.3).

**Fix.** CAS loop; mirror of §2.3 but with mask complement.

**LOC delta.** ~10 LOC.

**TODO tag site.** Above `clear bit` block.

---

### 2.5 Refcount init store after alloc

**Location.** `src/kernel/core/mm/phys_alloc.pdx:83-84`.

**Race scenario.** After the bitmap CAS wins (§2.3), the plain store
`mov [_frame_meta + rdi*8], 1` needs to be visible to any subsequent
CPU that dereferences the alloc'd VA. On x86-64 TSO, stores from the
same CPU are seen in order — so a reader that sees the alloc's return
address (bitmap bit) then reads the meta will see 1. But if the alloc
result is published via a *different* memory location (e.g., through a
PTE install), the reader on another CPU sees:

```
CPU-A: bitmap set → meta=1 → PTE install
CPU-B:                                    PTE read → meta read
```

TSO guarantees CPU-B sees the ordered stores. So this is not a race per
se — but pairs of atomics need a memory-order justification.

**Fix.** No code change required today; add a comment referencing TSO.
Escalate to `mfence` if we ever add a non-x86 architecture.

**LOC delta.** 2 LOC (comment only).

**TODO tag site.** Above the init store.

---

### 2.6 Bitmap-meta pairing invariant

**Location.** `phys_alloc.pdx:44-84` + `phys_free.pdx:49-74`.

**Invariant.** `_frame_meta[i] == 0  ⇔  _phys_pool_bitmap bit i == 0`.

**Race scenario.** Between §2.3's bitmap CAS-set and §2.5's meta init
store, another CPU could observe `bit == 1, meta == 0` — a stale window
where the pool believes the frame allocated but the metadata is not yet
initialized. If that CPU calls `frame_meta_incref(frame)` in that
window (impossible today because the frame isn't referenced yet — but
possible under adversarial ordering with pre-published PTEs), the
starting refcount is 0 → 1 instead of 1 → 2. Later decref underflows.

**Fix.** Order: bitmap CAS-set MUST happen before meta init; both must
complete before the alloc returns. TSO gives us this without fences.
Only concern: publication path. Add a comment; no code change.

**LOC delta.** 0 (shared justification with §2.3).

---

### 2.7 pid_alloc non-reserving scan

**Location.** `src/kernel/core/sched/task_pool.pdx:33-43`.

**Race scenario.** `pid_alloc` scans `_pid_table[1..64]` for the first
`== 0` slot and returns the index — *without writing*. The write happens
in `task_new` step 7 (line 122-123). Between pid_alloc-return and
task_new-publish, another CPU running its own fork can call pid_alloc,
see the same NULL slot, return the same pid. Both task_news then
publish to `_pid_table[pid]` — last writer wins; first task_new's
slab is orphaned but retains a live user_pml4 (leak) and the second
task_new's slab is the visible one.

**Impact.** Orphaned task_struct + double-allocated PID → the scheduler
enqueues both slabs, both tasks think they own pid N, wait/exit target
the visible slab only.

**Fix.** Convert pid_alloc from find-only to reserve-on-find via CAS:

```
pid_alloc_loop:
  cmp rcx, 64
  ja  pid_alloc_none
  lea rax, [rip + _pid_table]
  mov rdx, [rax + rcx*8]        ; expected
  cmp rdx, 0
  jne pid_alloc_next            ; slot busy
  ; reserve with sentinel PID_RESERVED (e.g. 0xFFFFFFFFFFFFFFFF)
  mov r8, 0xFFFFFFFFFFFFFFFF
  mov rax_scratch, 0            ; expected
  lock cmpxchg [rax + rcx*8], r8
  jne pid_alloc_next            ; someone else took it
  mov rax, rcx
  ret
pid_alloc_next:
  add rcx, 1
  jmp pid_alloc_loop
```

The reservation sentinel lets `task_new` step 7 overwrite it with the
real slab address unconditionally. `pid_free` on rollback clears it
back to 0.

**LOC delta.** ~15 LOC.

**TODO tag site.** Above `pid_alloc_loop:`.

---

### 2.8 `_pid_table[pid]` publish store

**Location.** `task_pool.pdx:122-123` (`task_new` step 7).

**Fixed by §2.7.** The reservation sentinel lets this store be a plain
overwrite — no CAS needed here.

**LOC delta.** 0 (shared).

---

### 2.9 Src-PTE CoW rewrite

**Location.** `src/kernel/core/mm/aspace_clone.pdx:195-199` (L4 leaf loop).

**Race scenario.** The walker rewrites the src PTE in place:
`frame_pa | (preserved_flags & ~RW) | COW | PRESENT`. If another CPU
concurrently reads the src PTE (page fault, walker for a different
child), it observes the rewrite. The single 8-byte store is TSO-atomic
so no torn read — but the *semantic* transition (from RW to
RO+COW) is a state machine transition, and readers on other CPUs need
to know a rewrite happened (they cached the RW bit in TLB).

**Impact.** See §2.10 (TLB coherence). Also: if two aspace_clone_cow
walk the same src concurrently (two forks of same parent), both
transitions to `RO+COW` — that's idempotent, but both increment
refcount → double-count → refcount leak (fixed by §2.1).

**Fix.** CAS on the PTE: expected = original RW-mapped PTE, new = COW
PTE. On CAS failure another walker did the transition already; skip
increment (it did the incref). This is subtle: we need to distinguish
"we did the transition" from "someone did it before us".

```
retry:
  mov rax, [r10 + rbx*8]          ; expected
  mov r11, rax
  and r11, 1                       ; PRESENT check unchanged
  jz  clone_l4_next
  ; compute new: (rax & (FRAME | FLAGS)) & ~RW | COW | PRESENT
  ; if already has COW bit set → skip (another walker won)
  mov rcx, rax
  and rcx, 0x200                   ; COW bit
  jnz clone_l4_incref_only         ; already CoW; just incref
  ; do the CAS
  ; ... compose new_pte ...
  mov rax_scratch, rax
  lock cmpxchg [r10 + rbx*8], new
  jne retry
  ; we did the transition; incref
```

**LOC delta.** ~20 LOC (the CAS + branch handling).

**TODO tag site.** Above the L4 leaf-processing block.

---

### 2.10 Src-PTE TLB coherence

**Location.** Post-rewrite of every L4 leaf in aspace_clone_cow.

**Race scenario.** After the CoW rewrite (§2.9), sibling CPUs that had
the src aspace loaded (e.g., the forking task's other threads, or a
child forked earlier which now shares src CR3) may have cached the RW
TLB entry. Those CPUs can now write to the frame without triggering
the CoW handler → silent write-through-CoW → the "isolated aspace"
invariant fails.

**Impact.** Silent aspace sharing across parent + child → violated
process isolation. Correctness-critical.

**Fix.** Send TLB shootdown IPI to every CPU that has the src aspace
loaded. R15.M6 has no per-CPU-active-aspace tracking yet; needs
`_active_aspace_per_cpu[NR_CPUS]` array + IPI vector for invlpg.
Aggregated: one IPI per walker invocation, with a bitmap of shot-down
pages, dispatched after the walker completes all L4 rewrites (batched
shootdown). At R15.M6 there is only the current CPU; the IPI stub can
be a no-op stub for now.

**LOC delta.** ~25 LOC — includes the per-CPU aspace tracker
(3-4 lines), the shootdown vector stub, and the walker call to it.

**TODO tag site.** After the L4 loop ends (`clone_l4_done:`).

---

### 2.11 Nested aspace_map on shared dst

**Location.** `aspace_clone.pdx:235` (call to aspace_map inside walker).

**Race scenario.** dst is a freshly-created empty user aspace not yet
loaded on any CPU — no concurrent access is possible. This is safe
today.

**Fix.** Sequencing note only; no change today. If a future path
publishes the child PML4 to the runqueue before the walker completes,
this becomes a race — flag the sequencing assumption.

**LOC delta.** 0.

---

### 2.12 fd_table copy loop

**Location.** `src/kernel/core/syscall/handlers/sys_fork.pdx:52-59`.

**Race scenario.** The loop reads `parent->fd[i]` for i in 0..31 and
writes each to `child->fd[i]`. If the parent has multiple threads (not
until R15.M7 threads land) OR if a signal handler runs mid-fork (not
until R15.M8+), a concurrent `sys_open` on the parent modifies fd_table
between our reads → child gets a "torn" snapshot: some slots are
pre-open state, some post-open. Not corruption per se, but observable
non-atomicity of fork's contract "child inherits parent's fd table".

**Impact.** Correctness of fork's atomicity contract; not memory
corruption. Semantically, POSIX fork requires atomic snapshot.

**Fix.** Take a per-task `fd_lock` for the copy loop. Because the
copy is 32 aligned loads and 32 aligned stores, we can also structure
this as `rep movsq` under lock — cheaper.

**LOC delta.** ~8 LOC (lock acquire/release + `rep movsq`).

**TODO tag site.** Above `sys_fork_fd_loop:`.

---

### 2.13 fd_set aligned store

**Location.** `src/kernel/core/fs/fd_table.pdx:36`.

**Race scenario.** Single aligned 8-byte store; TSO-atomic. No torn
value observable. But `fd_set` from one thread must be visible to
`fd_alloc`/`fd_get` on another thread — TSO gives this without fences.

**Fix.** No code change; add a `TODO(PA-R13-012)` comment noting the
architectural assumption (x86-64 TSO; would need `sfence` on weaker
memory models).

**LOC delta.** 2 LOC (comment).

**TODO tag site.** Above the store.

---

### 2.14 fd_alloc non-reserving scan

**Location.** `src/kernel/core/fs/fd_table.pdx:50-58`.

**Race scenario.** Same shape as §2.7 (pid_alloc). Two threads in the
same task (post-R15.M7) both call `fd_alloc`, both find the same
first-zero slot, both return the same fd. Whichever caller writes
first "wins" the slot; the second caller's subsequent `fd_set` clobbers
the first's file entry. Both threads then hold references to the same
fd; ordering of close operations produces double-close (fd_set(0))
against a still-live file.

**Impact.** File-descriptor double-allocation; file leak or use-after-
close.

**Fix.** Convert scan to CAS-reserve: for each slot, `lock cmpxchg`
0 → FD_RESERVED_SENTINEL. On success, return the fd; caller writes the
real value via fd_set. On failure, advance and rescan.

**LOC delta.** ~12 LOC.

**TODO tag site.** Above `fd_alloc_loop:`.

---

### 2.15 sys_wait pid_table scan

**Location.** `src/kernel/core/syscall/handlers/sys_wait.pdx:27-44`.

**Race scenario.** The scan reads `_pid_table[i]` (slab pointer) and
then `slab->state` (u32 at offset 8). Between these two loads, a
concurrent sys_exit on the child could store STATE_ZOMBIE. If our
observation of `state` happens *before* the concurrent store, we miss
the zombie this pass and fall through to §2.17 (set WAITING). The
zombie-child + waiting-parent rendezvous is broken (see §2.17 for
the rendezvous fix).

**Impact.** Interacts with §2.17 — see there for the compound race.

**Fix.** Acquire a coarse `pid_table_lock` for the scan. Combined with
§2.17's rendezvous, the scan runs atomic w.r.t. state transitions.

**LOC delta.** ~8 LOC (lock + release).

**TODO tag site.** Above the scan loop.

---

### 2.16 sys_wait double-reap

**Location.** `sys_wait.pdx:46-51`.

**Race scenario.** Two threads of the same parent (post-R15.M7 threads)
both call `sys_wait`. Both scan, both find the same ZOMBIE child,
both save `child->pid` + `child->exit_status`, both call
`pid_free(pid)`. Second `pid_free` writes 0 to an already-0 slot (idempotent), but both waiters return the same pid — POSIX violation
(each zombie must be reaped by exactly one wait).

**Impact.** Semantic: zombie double-reap. Not memory corruption, but a
correctness violation of the wait contract.

**Fix.** Fuse the ZOMBIE-observe + pid_free into a single CAS:
`lock cmpxchg [_pid_table + pid*8]`, expected = observed slab pointer,
new = 0. On success we reaped it. On failure another waiter got there
first — continue scanning.

**LOC delta.** ~12 LOC.

**TODO tag site.** Above `sys_wait_zombie_found:`.

---

### 2.17 sys_wait state=WAITING publish + sys_exit ZOMBIE publish rendezvous

**Location.** `sys_wait.pdx:60-61` + `sys_exit.pdx:73-74`.

**Race scenario (the wait/exit deadlock race).** Classic sleep/wakeup
race:

```
CPU-A (parent)                  CPU-B (child)
scan pid_table                  (still RUNNABLE)
  no zombie found
                                sys_exit: state=ZOMBIE
                                check parent state: not WAITING
                                skip wakeup
set parent->state = WAITING
block forever
```

Parent misses the ZOMBIE; child misses the WAITING; nobody wakes anyone.

**Impact.** Wait blocks forever; process tree wedges.

**Fix.** Rendezvous under `parent->lock`:

- sys_wait: acquire `parent->lock` → scan → if no zombie, set
  `parent->state = WAITING` → release lock → block.
- sys_exit: acquire `parent->lock` → set `child->state = ZOMBIE`
  → check `parent->state == WAITING` → if yes, wake parent → release
  lock.

Both sides atomic under the same lock; the scan + state-set fuse.

**LOC delta.** ~15 LOC (lock acquire/release across both bodies).

**TODO tag site.** Above sys_wait_scan_done and sys_exit_body step 1.

---

### 2.18 sys_exit ZOMBIE publish

**Location.** `sys_exit.pdx:73-74`.

**Fixed by §2.17.** Shared rendezvous.

**LOC delta.** 0 (shared).

---

### 2.19 orphan_adopt walker

**Location.** `sys_exit.pdx:36-60`.

**Race scenario.** Two concurrent sys_exit calls both walk `_pid_table`
rewriting parent_pids of their orphans. Rewrites of the same child's
parent_pid interleave; the field is a u32 aligned store, so no torn
write — but the semantic outcome depends on which walker "won". Also:
if a fresh `task_new` publishes a slab into a slot that was just
`pid_free`'d, that fresh task's parent_pid is not one of the exiting
parents' pids — but the walker might mid-scan see the slot as
allocated and check parent_pid; if parent_pid == exiting_pid coincidentally
(same fresh task's parent), the walker rewrites it to 1 → wrong parent.

**Impact.** Wrong parent_pid on a fresh sibling task; wait tree
corruption.

**Fix.** Serialize under `pid_table_lock` (same lock as §2.7 and §2.15).

**LOC delta.** ~6 LOC (lock + release).

**TODO tag site.** Above `orphan_adopt_loop:`.

---

### 2.20 sys_exit parent-slot lookup + wakeup

**Location.** `sys_exit.pdx:92-109` (steps 4-6).

**Race scenario.** Use-after-free.

```
CPU-A (child exiting)               CPU-B (parent exiting)
load parent slab: r8 = _pid_table[parent_pid]
                                    sys_exit: state=ZOMBIE, walk...
                                    orphan_adopt over its own children
                                    ...
                                    (parent later sys_wait'd by grandparent)
                                    pid_free(parent_pid)  ← _pid_table[parent_pid]=0
                                    ; parent's slab_pool slot now free
                                    ; (task_free would zero the slab, or a
                                    ;  fresh task_new could reuse it)
[r8 + 8] load ← stale slab
[r8 + 1704] store ← writes into freed / reused slab
```

The three stores at 103-109 land in freed memory OR in a reused slab
belonging to a fresh unrelated task — that task's `wait_result_*` and
`state` fields get corrupted.

**Impact.** Slab corruption of a live unrelated task. Critical: worst
class of race in this audit.

**Fix.** Hold `pid_table_lock` from parent-slot lookup through wakeup
completion. Combined with §2.17's parent-lock rendezvous, this fuses
into a single locked critical section.

Alternative: refcount-per-slab (mini-refcount for the task_struct
itself, separate from user_pml4 refcount). incref on load, decref
after wakeup. Higher overhead; deferred as a Path B option.

**LOC delta.** ~20 LOC.

**TODO tag site.** Above step 4 lookup.

---

### 2.21 sys_exit wakeup store order

**Location.** `sys_exit.pdx:103-109`.

**Race scenario.** Three stores: `wait_result_pid`, `wait_result_status`,
`state = RUNNABLE`. Comment says "state LAST". On x86-64 TSO, stores
from CPU-A are seen in program order by CPU-B — TSO gives us release
semantics on stores for free. So the audit reads as compliant.

The subtle case: if a future architecture (ARM, RISC-V) is targeted,
we need explicit release fences. Also: if the reader on CPU-B uses
a load-acquire pattern to observe state==RUNNABLE and then reads
wait_result_pid, on x86 the load-load ordering is total-store-ordered
— fine. On weaker memory, an `lfence` on the reader OR `sfence` on
the writer is needed.

**Fix.** No code change on x86-64. Add `TODO(PA-R13-012)`
justification note that today TSO suffices; a portable fix would add
`mfence` (or `xchg`-implicit-lock on the state store) before the state
store.

**LOC delta.** 3 LOC (comment; possibly a defensive `mfence`).

**TODO tag site.** Above the three-store block.

---

### 2.22 task_new pid_table publish + slab-zero visibility

**Location.** `task_pool.pdx:105-123` (steps 5-7).

**Race scenario.** Rep stosq zeroes 2224 bytes; then field stores
populate user_pml4_pa @ 16, pid @ 0, parent_pid @ 4. Then step 7
publishes: `_pid_table[pid] = slab_addr`.

If another CPU sees the publish and dereferences the slab, TSO gives
us visibility of the earlier stores (they precede the publish store
in program order). So on x86-64, no fence needed. Under weaker memory
models an `sfence` or `mfence` between step 6 and step 7 is required.

**Fix.** No code change on x86-64. Add a `TODO(PA-R13-012)` note.

**LOC delta.** 3 LOC (comment; possibly a defensive `mfence`).

**TODO tag site.** Between step 6 (last field store) and step 7
(publish store).

---

## 3. Priority ordering

Fix sites are grouped by impact class. Highest priority = data
corruption of user memory; lowest priority = TSO-safe-today-but-need-
fence-on-portable.

### 3.1 Data corruption (fix FIRST)

These sites, unfixed under SMP, produce silent memory corruption of
user aspace or a live task_struct. Landing SMP without these is
unsafe.

| Site | Rationale |
|------|-----------|
| §2.3  | Two CPUs allocate same physical frame → aspace isolation broken |
| §2.4  | Two CPUs free/alloc collision → same result via a different path |
| §2.9  | Src-PTE rewrite race → dual RW mapping |
| §2.10 | TLB shootdown missing → silent RW writes bypass CoW |
| §2.20 | Use-after-free on parent slab → foreign task_struct corrupted |
| §2.7  | Duplicate pid → orphaned task_struct + scheduler enqueue confusion |

### 3.2 Refcount leak / semantic corruption (fix SECOND)

Sites that produce refcount underflow → premature frame release →
eventual data corruption, but through a longer causal chain.

| Site | Rationale |
|------|-----------|
| §2.1  | Refcount incref lost update → premature phys_free of shared frame |
| §2.2  | Refcount decref lost update → mirror of §2.1 |
| §2.16 | Zombie double-reap → semantic wait violation, no memory unsafety today |
| §2.17 | Wait/exit sleep-wakeup race → process tree wedge |
| §2.19 | orphan_adopt over concurrent task_new → wrong parent_pid on fresh task |

### 3.3 FD table (fix THIRD)

Not memory-unsafe today (aligned 8-byte stores are TSO-atomic), but
POSIX semantic violations.

| Site | Rationale |
|------|-----------|
| §2.12 | Torn fd snapshot in child (needs parent lock) |
| §2.14 | fd_alloc double-issue |
| §2.15 | pid_table scan visibility (subsumed by §2.17 in most paths) |
| §2.13 | Aligned store visibility (TSO-safe today) |

### 3.4 TSO-safe today / portability guard (fix LAST)

Sites that are correct on x86-64 due to TSO but would break under a
weaker memory model. Comment-only or defensive `mfence`.

| Site | Rationale |
|------|-----------|
| §2.5  | Refcount init visibility |
| §2.6  | Bitmap-meta pairing (justification note) |
| §2.8  | pid_table publish (fused with §2.7) |
| §2.11 | Fresh dst aspace (sequencing note) |
| §2.18 | Wait/exit rendezvous (fused with §2.17) |
| §2.21 | sys_exit wakeup store order (TSO safe) |
| §2.22 | task_new publish visibility (TSO safe) |

---

## 4. Introduced primitives

The Path A fix set introduces a small set of shared kernel primitives.
None exist today. Estimated LOC counted separately from the site fixes
below.

| Primitive | Purpose | LOC |
|-----------|---------|-----|
| `spinlock_acquire` / `spinlock_release` | Coarse lock body: `lock cmpxchg` on a u64 word | 20 |
| `_pid_table_lock` (single spinlock) | Serializes pid_alloc/pid_free/pid_table scans (§2.7, §2.15, §2.17, §2.19, §2.20) | 4 |
| `_phys_lock` (single spinlock) | Serializes bitmap+meta pair (§2.3, §2.4, §2.6). Alternative: fine-grained CAS as in §2.3 body; if CAS suffices, drop this lock | 4 |
| `_active_aspace_per_cpu[NR_CPUS]` | Per-CPU active-user-PML4 tracker (§2.10) | 6 |
| `tlb_shootdown_ipi(pml4, va_bitmap)` | IPI-based shootdown of a shot-list to CPUs where `_active_aspace == pml4` | 30 |
| Per-parent `->lock` (offset in task_struct) | Wait/exit rendezvous (§2.17, §2.20) | 4 (layout) |

**Primitive LOC total: ~68.**

---

## 5. LOC delta summary

| Category | Sites | LOC |
|----------|-------|-----|
| Data corruption fixes (§3.1) | 6 | 92 |
| Refcount + semantic (§3.2) | 5 | 45 |
| FD table (§3.3) | 4 | 24 |
| TSO comment-only (§3.4) | 7 | ~11 |
| Shared primitives (§4)    | 6 | 68 |

**Total: ~240 LOC** across all landed R15.M6 primitives.

Distribution notes:

- The largest single fix is TLB shootdown (§2.10) at ~25 LOC plus the
  shootdown-IPI primitive at ~30 LOC — combined ~55 LOC. This is the
  most complex delta but also the most cleanly-separable (lands as a
  self-contained subsystem before any of the M6 fixes are applied).
- The `pid_table_lock` primitive at 4 LOC serializes 4 sites; the
  acquire/release pairs at each site add ~24 LOC combined — the amortized
  cost per site drops sharply because they share the same lock.
- The bitmap-CAS fixes (§2.3, §2.4) at ~22 LOC combined are the smallest
  correctness-critical delta.

Full breakdown, one row per site, in the summary table (§1). No fix
site exceeds 25 LOC individually; the audit is small-and-many rather
than large-and-few.

---

## 6. TODO(PA-R13-012) comment site catalog

Each site gets a comment placed on the line *above* the racy code
block, pointing back to this audit's section for the fix rationale.
The tag format is the standard PaideiaOS TODO tag; the R13 encoder gap
that blocks the fix is spelled explicitly so an issue-search on
"PA-R13-012" finds every downstream site.

Recommended comment shape (identical structure across sites):

```
// TODO(PA-R13-012): SMP hardening.
//   Race: <name from §2.N>.
//   Impact: <one line from §2.N impact>.
//   Fix: <one line from §2.N fix approach>.
//   See design/audit/entries/r15-m6-010-fork-multicore.md §2.N.
```

Catalog of insertion sites (file:line for each TODO):

| Site | File | Line (approx) |
|------|------|---------------|
| §2.1  | frame_meta.pdx     | above 117 |
| §2.2  | phys_free.pdx      | above 49  |
| §2.3  | phys_alloc.pdx     | above 39 (scan_loop) |
| §2.4  | phys_free.pdx      | above 65 |
| §2.5  | phys_alloc.pdx     | above 83 |
| §2.6  | phys_alloc.pdx     | above 83 (paired with §2.5) |
| §2.7  | task_pool.pdx      | above 33 (pid_alloc_loop) |
| §2.8  | task_pool.pdx      | above 122 (publish) |
| §2.9  | aspace_clone.pdx   | above 180 (leaf processing) |
| §2.10 | aspace_clone.pdx   | above 267 (clone_l4_done) |
| §2.11 | aspace_clone.pdx   | above 235 (aspace_map call) |
| §2.12 | sys_fork.pdx       | above 52 (fd_loop) |
| §2.13 | fd_table.pdx       | above 36 (fd_set store) |
| §2.14 | fd_table.pdx       | above 51 (fd_alloc_loop) |
| §2.15 | sys_wait.pdx       | above 27 (scan_loop) |
| §2.16 | sys_wait.pdx       | above 46 (zombie_found) |
| §2.17 | sys_wait.pdx + sys_exit.pdx | above 60 / above 73 |
| §2.18 | sys_exit.pdx       | above 73 (paired with §2.17) |
| §2.19 | sys_exit.pdx       | above 38 (orphan_adopt_loop) |
| §2.20 | sys_exit.pdx       | above 92 (step 4 lookup) |
| §2.21 | sys_exit.pdx       | above 103 (three-store block) |
| §2.22 | task_pool.pdx      | above 122 (publish) |

Some rows overlap on `above 122` in `task_pool.pdx` (§2.8 + §2.22) —
both about the publish store. Use a single combined TODO with two
`§` references.

---

## 7. Retirement path

This audit doc is retired when:

1. PA-R13-012 lands in paideia-as (issue #925). `lock cmpxchg`,
   `lock xadd`, `xchg [mem], reg`, `mfence`, and the `lock` prefix
   are all encoded and audited.
2. R15.M7 SMP promotion round runs. Per-CPU GS data, SIPI trampoline,
   AP bootstrap, and the shootdown-IPI vector land.
3. Each site's `TODO(PA-R13-012)` comment is replaced by the actual
   fix from §2 with a `// R13-hardening applied: see §2.N` note.
4. A new smoke-mode `boot_r15_smp_forkexec` exercises fork/exec/wait
   on ≥2 CPUs and passes byte-identically across ≥100 runs (concurrency
   determinism floor per `design/02-development-environment.md`).

Progress can be tracked by grep:

```bash
grep -rn "TODO(PA-R13-012)" src/ | wc -l
```

At the end of R13 hardening the count drops to 0.

---

## 8. Cross-references

- **Issue:** #561 (R15.M6 subsystem 9 issue 10 — landing gate).
- **paideia-as encoder gap:** #925 (PA-R13-012).
- **Master plan:** `design/milestones/r14b-master-plan.md`
  ("`lock cmpxchg`, `xchg [mem], reg`, `mfence` — PA-R13-012 bundle").
- **Tactical plan:** `design/milestones/r14b-tactical-plan.md` §10
  ("audit doc lists every place that would race under Path A").
- **Related R15.M6 designs:**
  - `design/kernel/r15-m6-001-aspace-clone.md`
  - `design/kernel/r15-m6-003-sys-fork.md`
  - `design/kernel/r15-m6-004-sys-execve.md`
  - `design/kernel/r15-m6-005-sys-wait.md`
  - `design/kernel/r15-m6-006-sys-exit.md`
  - `design/kernel/r15-m6-007-orphan-adoption.md`
  - `design/kernel/r15-m6-008-cow-refcount-frame-metadata.md`
- **Round retrospective:** `design/round-retrospectives/r13-shell-foundation.md`
  ("PA-R13-012 remains HARD blocker for Rev-2 M10").
- **Take-stock:** `design/milestones/take-stock-2026-07-03.md`
  ("Multi-CPU. Needs PA-R14-001 (GS prefix), PA-R13-012 (atomics),
  PA-R13-005 (mfence)").

---

*End of audit R15-M6-010.*
