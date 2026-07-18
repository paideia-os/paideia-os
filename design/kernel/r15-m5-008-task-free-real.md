---
issue: 550
milestone: R15.M5 (Process abstraction — task_struct, PID allocator, fd table)
subsystem: 8 — Process abstraction
prereq:
  - "#543 (task-struct layout freeze — pins offsets 0/16/168 that task_free reads)"
  - "#544 (task_pool slab — provides the backing storage the body zeroes)"
  - "#545 (pid_alloc — this issue lands the symmetric pid_free helper it needs)"
  - "#548 (task_new real — witness driver; task_free is the inverse operation)"
  - "#549 (fd_table embed — closed-slot semantics fold into the slab zero)"
  - "Subsystem 4 issue 9 (aspace_teardown) — LANDED at R14-m2-005 (real body)"
  - "R15-M1-010 / #649 (phys_free real body) — LANDED; aspace_teardown's inner phys_free calls are no longer no-ops"
blocks:
  - "#551 (boot_r15_process smoke — fingerprint needs task_new + task_free round-trip visible)"
  - "R15.M6-002 (sys_exit — zombie state → task_free split; this issue's atomic task_free unfolds into exit-then-reap)"
  - "R15.M6-003 (sys_fork — task_new/task_free churn stress-tests the pool bitmap and phys_free round-trip)"
  - "R15.M6-007 (orphan adoption by init — walks pool during task_free of parent; this issue pins the pool traversal invariant)"
touching:
  - src/kernel/core/sched/task_pool.pdx           (task_free body + pid_free helper — new module or extended by #544)
  - src/kernel/boot/kernel_main.pdx               (witness block, ~55 LOC)
  - tests/r15/expected-boot-r15-ring3.txt         (marker line, contains-in-order)
  - tests/r14b/expected-boot-r14b-loader.txt      (marker line, contains-in-order)
  - design/kernel/r15-m5-008-task-free-real.md    (this doc)
related:
  - design/kernel/r15-m5-007-fd-table-embed.md    (task_struct offsets 168..424, FD_TABLE_MAX=32)
  - design/kernel/r15-m1-010-phys-free-real-body.md (bitmap release the aspace_teardown inner loop drives)
  - design/milestones/r14b-tactical-plan.md §Subsystem 8 (source-of-truth layout, interface list line 894–898)
---

# R15-M5-008 — task_free real body: fd close + aspace teardown + pid_free + slab zero (#550)

## 1. Scope

Give `task_free` a real, resource-releasing body so that the process
lifecycle round-trip `task_new → ... → task_free → task_new` is
*conservative*: every byte of aspace, every fd slot, every pid slot,
and every task_struct byte returns to its pre-`task_new` state.

Two invariants define completion:

- **pid reuse.** After `task_free(t)` returns, the next `pid_alloc()`
  hands out `t->pid` (specifically pid 1, when `t` is init).
- **phys pool stability.** After `task_new → task_free × N` for any
  N ≤ 100, `phys_alloc_free_count()` equals its pre-loop value — the
  aspace pages allocated during `task_new` (PML4, PTs, user text/stack
  pages) are all reclaimed by `aspace_teardown`, which now really
  releases them via #649's `phys_free`.

Explicitly out of scope (deferred):

- **Zombie / reap split.** At R15.M5, `task_free` is *atomic*: fds +
  aspace + slab + pid all go in one call. R15.M6-002 (`sys_exit`) will
  split this into two phases — `task_zombify` (fds + aspace, keep pid
  + exit_status live) and `task_reap` (called from parent's
  `sys_wait`; drops pid + zeros slab). This design pins the *order* so
  the split is a clean bisection, not a re-plumb.
- **Orphan reparenting.** R15.M6-007 walks `pid_table` on parent
  destruction and rewrites `child->parent_pid = 1` for every child.
  Here we assume no children — the witness creates single leaf tasks.
- **Refcounted vnodes in fd slots.** At R15.M5 slots are opaque `u64`
  (per #549); zeroing the fd_table region is the correct "close all
  fds" primitive because no vnode has a live refcount to decrement.
  R16.M3 grows the slot to `fd_entry` and adds a real `fd_close(t, i)`
  primitive that this body will call in a loop.
- **Concurrency / TLB invalidation on other CPUs.** Single-CPU at
  R15.M5. R14b.M5's IPI substrate (#646) is available if we ever need
  a cross-CPU TLB shootdown at teardown; for the boot-time witness
  no other CPU holds a stale mapping.

## 2. Prereq check

### 2.1 What's in place

| Primitive              | Location                              | Contract used by task_free                     |
|------------------------|---------------------------------------|------------------------------------------------|
| `aspace_teardown(pml4)`| `core/mm/aspace_teardown.pdx`         | Walks 4-level PT, frees U-bit leaves + tables + PML4 root via `phys_free`. Callee-save-clean. Returns 0. |
| `phys_free(page, 0)`   | `core/mm/phys_free.pdx` (post-#649)   | Real bitmap release. VA/PA normalizer handles the mixed input aspace_teardown emits. |
| `fd_set(t, fd, val)`   | `core/fs/fd_table.pdx`                | One-liner store `mov [rdi + rsi*8 + 168], rdx`. Writing 0 clears the slot with no side effect at R15.M5. |
| `rep stosq`            | encoder, `tools/paideia-as/tests/build-emit/rep_stosq_smoke.pdx` | Zero the 2224-byte task_struct in one instruction. |
| Callee-save discipline | `phys_alloc.pdx` (fix in `f6195ed`), `aspace_teardown.pdx` | Prior art: push/pop `rbx, r12-r15` around calls that clobber them. |

### 2.2 What is *not* in place yet — required prerequisites this doc consumes on faith

`task_free` cannot land before its five prerequisites:

- **#543** — task_struct layout freeze. This design references offsets
  `0 (pid)`, `16 (user_pml4_pa)`, `168..424 (fd_table)`, `2224 (size)`
  as if they are frozen; #549's design already pins them at the same
  values (§3.1 of `r15-m5-007-fd-table-embed.md`) so the design is
  consistent even before #543 is merged.
- **#544** — `_task_pool[64] : [u8; 64 * 4096] @align(4096)` static
  `.bss` region + slab allocator hooks that `task_new` and `task_free`
  share. This design assumes the slab layout is `pid_table[pid]`-keyed
  (§3.6). If #544 lands a *decoupled* slab bitmap instead, the last
  step of task_free grows by one call (§6.1 backtrack A).
- **#545** — `pid_alloc()` linear scan; `pid_table[0]=0, pid_table[1..64]`
  as `task_struct*`. **This doc lands the matching `pid_free(pid)` in
  the same module** (§3.5). #545's own scope stops at `pid_alloc`; the
  free path lives here because it has no other consumer at R15.M5.
- **#548** — `task_new` real body. Provides the witness driver: this
  doc's canary loop calls `task_new` 100× and pairs each with `task_free`.
- **#549** — fd_table embed. **Landed** as of `22437af`. §3.4 folds the
  fd close step into the slab zero (safe because `fd_set` is a
  side-effect-free store at R15.M5).

### 2.3 Encoder gaps

**None expected.** The task_free body uses only:

- Register-to-register `mov`, `xor`, `push`, `pop`
- `rep stosq` — audited by `rep_stosq_smoke.pdx`
- `call` to `aspace_teardown`, `pid_free`
- `mov r64, [reg + disp8]` — used every 2 lines
- `ret`

No SIB scaling on extended base registers (which triggers PA-#928;
`aspace_teardown` documents the workaround). We don't need indexed
memory access; `rep stosq` bulk-zeroes the slab and single-disp loads
extract the pid and pml4_pa fields.

## 3. Design

### 3.1 Teardown order — five steps, one rationale

```
task_free(t):
  step 1  extract pid   into a preserved register  (before any writes destroy the field)
  step 2  extract pml4  into a preserved register  (before any writes destroy the field)
  step 3  aspace_teardown(pml4)                    (walks + frees user PT, calls phys_free per frame)
  step 4  rep stosq zero the 2224-byte slab        (also zeroes fd_table[0..32] — "close all fds")
  step 5  pid_free(pid)                            (last: pid_table[pid] = NULL → slot reusable)
  ret
```

**Why this order.**

1. **Extract-first (steps 1–2).** Both `pid` (offset 0) and `user_pml4_pa`
   (offset 16) live *inside* the memory region that step 4 will zero.
   Reading them into callee-saved registers before any teardown call
   removes the ordering coupling between steps 3 and 4 and lets us zero
   the whole struct in one `rep stosq` at step 4 rather than
   piecewise-preserving live fields.

2. **fds before aspace (step 4's fd close conceptually precedes step
   3's aspace teardown).** At R16.M3, fd slots point at vnodes; some
   of those vnodes back user memory (e.g. tmpfs-mmap). Closing them
   first prevents an aspace_teardown from tearing down a page that a
   vnode still refcounts. **At R15.M5 the slots are opaque `u64`**,
   so there is no live refcount and no strict ordering constraint —
   we merge the fd close into step 4's whole-slab zero as an
   optimization. The design is written as if steps 3 and 4 are ordered
   "fds then aspace" so the R16.M3 unfold is clean (§6.4 backtrack D):
   we simply move the fd_table zero out of the `rep stosq` prologue
   into an explicit `fd_close_all(t)` call before `aspace_teardown(pml4)`.

3. **aspace before slab zero (step 3 before step 4).** `aspace_teardown`
   reads no field of `task_struct` — it takes the pml4 address by
   value in rdi. So we could zero the slab first and then call
   `aspace_teardown(saved_pml4)`. We do teardown first anyway because
   it makes the invariant "if task_free is interrupted mid-way, the
   task_struct still contains a valid pml4 pointer for a diagnostic
   panic dump" hold — a debugger-friendliness point, not a correctness
   requirement at R15.M5 (interrupts are enabled but task_free runs
   with no yield points).

4. **pid_free LAST (step 5).** Freeing the pid slot before zeroing
   the slab creates a window where `pid_table[pid] == NULL` but the
   slab still holds live user_pml4_pa / kernel_stack pointers. A
   concurrent `task_new` (R15.M6 fork) could receive that pid, look
   up its slab via the `pid → slab_index` mapping (§3.6), and observe
   the *old* task's fields for a brief interval before its own
   `rep stosq` overwrites them. At R15.M5 we're single-CPU without
   preemption inside task_free, so no observable race — but the
   "pid last" discipline is the R15.M6-safe ordering and locking it
   in now avoids a re-plumb once fork lands.

5. **No slab_free step.** The slab entry is *not* released via a
   separate primitive because we use the pid ⇋ slab_index mapping
   (§3.6): `pid_free` freeing the pid_table entry is what makes the
   slab entry reusable (`task_new` looks up `pid_table[new_pid]` to
   discover whether the slab entry at `_task_pool[new_pid - 1]` is
   allocated). Backtrack B (§6.2) discusses the decoupled variant.

### 3.2 Register discipline — the debugger-endemic bug this design avoids

Recent PaideiaOS debugger sessions (`f6195ed` — phys_alloc preserving
r12-r15; `3e6a550` — self-IPI callee-save audit) have shown that
**register clobber across nested calls is the endemic bug class in
this codebase**. Every asm body that holds live state in `rbx / r12 /
r13 / r14 / r15` across a call to another `.pdx` function *must*
push/pop them or receive silent corruption.

`task_free` holds two live pieces of state — `pid` and `user_pml4_pa`
— across three nested calls (`aspace_teardown`, `pid_free`, and
`rep stosq` doesn't call anything but clobbers rdi/rcx/rax which are
caller-save so no discipline needed there). Discipline:

```
task_free_prologue:
    push rbx        ; save because caller may hold state here
    push r12        ; save because we use r12 = pid
    push r13        ; save because we use r13 = user_pml4_pa
    ; 3 pushes = 24 bytes. Entry rsp ≡ 8 mod 16 (call pushed return address).
    ; After 3 pushes: rsp ≡ 8 + 24 = 32 ≡ 0 mod 16. STACK ALIGNED at call sites.

    mov rbx, rdi                    ; rbx = task base (preserved across calls)
    mov r12d, [rbx + 0]             ; r12 = pid (u32, zero-extended to u64)
    mov r13,  [rbx + 16]            ; r13 = user_pml4_pa (u64)

    ; ... steps 3-5 use rbx/r12/r13 freely; nested calls preserve them ...

task_free_epilogue:
    pop r13
    pop r12
    pop rbx
    ret
```

**Stack alignment.** After `push return_address` (implicit at `call`)
`rsp ≡ 8 mod 16`. 3 subsequent pushes bring `rsp` to `8 + 24 = 32 ≡ 0`.
Every nested `call aspace_teardown` / `call pid_free` sees `rsp ≡ 0
mod 16` — SysV compliant. If a future edit adds a 4th push, restore
alignment with `sub rsp, 8` / `add rsp, 8` around the call block.

**Cross-call save/restore inside the body.** `aspace_teardown` and
`pid_free` are called out of this codebase, so we trust *their*
callee-save discipline (they push/pop what they clobber, per
`aspace_teardown.pdx` lines 26–30 and the phys_alloc fix in
commit `f6195ed`). No extra push/pop inside the body is required —
the prologue's 3 pushes cover the whole function.

### 3.3 Step 3 — aspace_teardown call

```
    mov rdi, r13                    ; r13 = user_pml4_pa (saved at prologue)
    call aspace_teardown            ; returns rax = 0 always
    ; discard rax — we don't propagate a failure at R15.M5
```

**Failure mode.** `aspace_teardown` cannot fail at R15.M5 (post #649
its inner `phys_free` returns `PHYS_FREE_OK` for all valid pool
pages; the range check happens per-page and out-of-range PTEs are
silently ignored, matching the "reclaim what we can" discipline of
teardown). If a future edit adds a failure path, task_free either
panics (destroying a task with a corrupt aspace is not recoverable)
or logs and continues — decision deferred to that future issue.

**Passing r13 not \[rbx + 16\].** By the time this call runs, step 4
has *not* yet zeroed the slab, so `[rbx + 16]` would also work. But
step 3 lives in a diamond: at R15.M6-002 `task_zombify` will move
this step earlier (before pid is fixed for the zombie) and re-use
`r13` from a different prologue. Using `r13` here is the
version-safe pattern.

### 3.4 Step 4 — slab zero (2224 bytes) via `rep stosq`

```
    ; rep stosq: rdi = dst, rcx = count in qwords, rax = value
    mov rdi, rbx                    ; rbx = task base (survived aspace_teardown)
    mov rcx, 278                    ; 2224 / 8 = 278 qwords
    xor eax, eax                    ; rax = 0 (fill value)
    rep stosq                       ; zero 278 qwords
```

**Encoder support.** `rep stosq` is audited by
`tools/paideia-as/tests/build-emit/rep_stosq_smoke.pdx`; encoding
`F3 48 AB`. No paideia-as gap.

**Post-condition.** `[rbx + 0..2224)` is all zero. In particular:
- `pid = 0` (offset 0)
- `state = 0 == STATE_NEW` (offset 8) — matches the R15.M6-safe
  interpretation "a slab-cleared task looks like a fresh NEW slot"
- `user_pml4_pa = 0` (offset 16)
- `fd_table[0..32] = 0` — **this is the "close all fds" side effect**;
  every slot back to sentinel-`0` (unused).

**Why `rep stosq`, not a byte loop.** `rep stosq` is one instruction,
one microcoded 8-byte-per-cycle burst on modern x86 (2224 bytes ≈ 70
cycles). A hand-rolled qword loop is ~5 instructions per iteration ×
278 iterations = 1400 instructions, ~350 ns. Same order of magnitude
but `rep stosq` is idiomatic and matches the tactical plan's
"`rep stosb` for zeroing" entry (issue #6 encoder gaps line 950 —
that flags `rep stosb` for #548 zeroing on `task_new`; we adopt
`rep stosq` because the slab is qword-aligned and the win is 8×).

**Alignment note.** `_task_pool[i]` is 4 KiB-aligned per #544, so
`rbx` is 4 KiB-aligned. Any alignment satisfies `rep stosq`'s 8-byte
minimum, and modern x86 fast-strings kicks in on 4 KiB alignment.

### 3.5 Step 5 — pid_free

`pid_free` is a new tiny helper that ships in the same
`task_pool.pdx` module (see §3.7 layout):

```
; pid_free(pid: u32) -> () !{mem} @{}
;   rdi = pid (zero-extended u32)
;   Effect: pid_table[pid] = NULL
;   No bounds check by policy — task_free is the sole caller at R15.M5
;   and passes a value from the task_struct.pid field, which is
;   provably in [1, MAX_PIDS) by construction (task_new only writes
;   valid pids there).
pid_free:
    lea rax, [rip + _pid_table]
    mov [rax + rdi*8], 0            ; imm32 form of mov mem, imm — OK per mov_mem_imm_sib_disp
    ret
```

`_pid_table : [u64; 64] @align(8)` is declared in the same module
(shared with `pid_alloc` from #545 which populates it). The
`_pid_table[0] = NULL sentinel` invariant is preserved (task_free
would only be called with `pid >= 1`; pid 0 never sees a task_free).

**Encoding of `mov [rax + rdi*8], 0`.** SIB+scale-8 store with imm32
source; audited by `tools/paideia-as/tests/build-emit/mov_mem_imm_sib.pdx`.

**Task_free call site:**

```
    ; step 5 — pid_free(saved pid)
    mov edi, r12d                   ; r12 = pid (u32, saved at prologue)
    call pid_free
```

Note `mov edi, r12d` (32-bit) not `mov rdi, r12` — pid is a u32 and
the calling convention passes u32s in `edi` (upper 32 bits zero-extended
by the write). Either form is equivalent for `pid_free`'s single use
of `rdi` as an index scaled by 8 (since valid pid < 64 fits in either).

### 3.6 pid ⇋ slab_index mapping — the compact invariant

`pid_table[pid]` stores `task_struct*`. At R15.M5 with `MAX_PIDS ==
MAX_TASKS == 64`, we adopt the compact mapping:

```
pid_table[pid] == &_task_pool[pid - 1]     for pid ∈ [1, 64]
pid_table[0]    == NULL sentinel
```

Consequence: `task_new` and `task_free` never allocate/free a
*separate* slab bitmap — the presence of a non-NULL pointer in
`pid_table[pid]` *is* the "slab entry allocated" bit. `pid_alloc`
scans `pid_table[1..64]` for the first NULL slot (which #545
already does — its scan naturally couples to this mapping).

Rationale: two allocators (pid + slab) would be redundant when the
identity `slab_index = pid - 1` is invariant. If R15.M6+ needs to
break this identity (e.g. `MAX_TASKS > MAX_PIDS` because zombies
retain a pid without a slab), we introduce a separate slab bitmap
then. §6.2 discusses the backtrack.

**This design pins the mapping** so #544 (task_slab) and #548
(task_new) commit to the same invariant. The design contract:
- `task_new`: after `pid = pid_alloc()`, sets `pid_table[pid] =
  &_task_pool[pid-1]` and returns that pointer.
- `task_free`: `pid_free(pid)` writes `pid_table[pid] = NULL` and
  releases the slab entry as a *side effect* of the NULL write.

### 3.7 Module layout — `task_pool.pdx`

The touching file per the tactical plan is
`src/kernel/core/sched/task_pool.pdx` (new). Its shape after this
issue lands (and the four prereq issues fill in their halves):

```
module TaskPool = structure {
  // Constants (frozen at #543/#544)
  pub let MAX_TASKS : u64 = 64
  pub let MAX_PIDS  : u64 = 64
  pub let TASK_STRUCT_SIZE : u64 = 2224    // matches #549 §3.1

  // Static storage (declared by #544; task_free reads pid_table only)
  pub let mut _task_pool  : [u64; 64 * 512] = uninit @align(4096)   // 64 × 4 KiB
  pub let mut _pid_table  : [u64; 64]       = uninit @align(8)

  // pid_alloc: lands with #545 (linear scan pid_table[1..64] for NULL)
  pub let pid_alloc : () -> u64 !{mem} @{} = ...

  // pid_free: LANDS HERE (#550) — 3-instruction helper
  pub let pid_free : (u64) -> () !{mem} @{} = fn (pid: u64) -> unsafe { ... }

  // task_new: lands with #548 (real body); paired with task_free here
  pub let task_new : (u64) -> u64 !{mem} @{} = ...

  // task_free: LANDS HERE (#550) — 5-step teardown
  pub let task_free : (u64) -> () !{mem} @{} = fn (t: u64) -> unsafe { ... }
}
```

`_task_pool`'s type `[u64; 64 * 512]` means 32768 qwords = 262144
bytes = 64 × 4 KiB. The paideia-as `@align(4096)` on a `.bss` u64
array is confirmed by `_phys_page_pool` (`phys_pool.pdx` line 25:
`[u64; 524288] @align(4096)`). No new encoder gap; PA-R16-003 is
listed as "verify" not "gap" (tactical plan line 2005).

### 3.8 Full `task_free` body — assembly draft

```pdx
pub let task_free : (u64) -> () !{mem} @{} =
  fn (t: u64) -> unsafe {
    effects: {mem},
    capabilities: {},
    justification: "R15-M5-008 (#550): 5-step teardown. (1) Save callee-save regs rbx/r12/r13 (3 pushes align rsp to 16). (2) Capture pid @off 0 into r12d, user_pml4_pa @off 16 into r13, task base into rbx — done before any teardown call zeroes the slab region so the fields survive step 4. (3) Call aspace_teardown(r13) — releases 4-level PT + user leaf frames via #649 phys_free. Returns 0; discarded. (4) rep stosq: 278 qwords × 8 = 2224 bytes zeroed at rbx, filling fd_table[0..32] as a side effect (fd close at R15.M5 is opaque-slot zeroing per #549 §3.3). (5) pid_free(r12) — writes pid_table[pid] = NULL, releasing both the pid slot and the slab entry (compact pid↔slab_index mapping, §3.6). Order rationale: pid last so the slab is fully zeroed before its pid becomes reusable by a concurrent task_new (R15.M6 hardening). Register discipline: rbx/r12/r13 preserved via 3-push prologue; nested calls (aspace_teardown, pid_free) are trusted to callee-save per their own justifications (aspace_teardown.pdx lines 26-30, pid_free is a 2-instruction leaf). Stack: rsp ≡ 0 mod 16 at every nested call site.",
    block: {
      // ===== prologue: save callee-save + capture fields =====
      push rbx;
      push r12;
      push r13;
      mov rbx, rdi;                     // rbx = task base
      mov r12d, [rbx + 0];              // r12 = pid (u32 zero-ext)
      mov r13,  [rbx + 16];             // r13 = user_pml4_pa

      // ===== step 3: aspace_teardown =====
      mov rdi, r13;
      call aspace_teardown;             // returns 0 always at R15.M5

      // ===== step 4: rep stosq — zero the 2224-byte slab =====
      // Also acts as "close all fds" — fd_table[0..32] at offset 168
      // is inside the zeroed region.
      mov rdi, rbx;
      mov rcx, 278;                     // 2224 / 8
      xor eax, eax;
      rep stosq;

      // ===== step 5: pid_free =====
      mov edi, r12d;                    // pid
      call pid_free;

      // ===== epilogue =====
      pop r13;
      pop r12;
      pop rbx;
      ret
    }
  }

pub let pid_free : (u64) -> () !{mem} @{} =
  fn (pid: u64) -> unsafe {
    effects: {mem},
    capabilities: {},
    justification: "R15-M5-008 (#550): pid_free is a 2-instruction leaf — write NULL into pid_table[pid]. No bounds check; task_free is the sole caller at R15.M5 and always passes a task_struct.pid field that pid_alloc previously validated as ∈ [1, MAX_PIDS). The store `mov [rax + rdi*8], 0` uses SIB+scale-8 with imm32 source, audited by tools/paideia-as/tests/build-emit/mov_mem_imm_sib.pdx.",
    block: {
      lea rax, [rip + _pid_table];
      mov [rax + rdi*8], 0;
      ret
    }
  }
```

Total executable LOC: ~30 lines of assembly across two functions, ~55
counting justification strings.

## 4. Test canary — kernel_main witness block

### 4.1 Witness shape

The tactical plan's AC for #550 is:

> create 100 tasks in a loop, free each; pid slot 1 always available
> for the next allocation after freeing.

The witness lives in `kernel_main.pdx` inside
`boot_continue_after_ring3` (same block as the fd_table witness at
lines 449–500, immediately after "R15 FD TABLE OK"). It runs after
#549's fd_table witness and *before* the IPI witness so the marker
lands in fingerprint order.

```asm
; ============================================================
; R15-M5-008 (#550): task_free witness — 100-iteration round-trip
; ============================================================

; r15 = iteration counter (0..100); we use r15 explicitly because
; the higher-numbered r12/r13/r14 are pre-emptively saved elsewhere in
; boot_continue_after_ring3 (see #649 phys_free witness for prior art).
; No push required — this witness runs at boot with no live callee-save
; state to preserve; the outer function is boot_continue_after_ring3
; which itself has no callee obligations beyond the calling boot code.

xor r15, r15;                              ; iteration counter

; Snapshot the phys pool free count BEFORE the loop.
call phys_alloc_free_count;
mov r14, rax;                              ; r14 = free_count_before

task_free_witness_loop:
    cmp r15, 100;
    jae task_free_witness_done;

    ; --- iteration i: task_new → assert pid == 1 → task_free ---
    xor rdi, rdi;                          ; parent = 0 (init sentinel)
    call task_new;                         ; rax = task_struct* (or 0 on ENOMEM)
    cmp rax, 0;
    je  task_free_witness_fail;            ; ENOMEM = bug

    mov r12, rax;                          ; r12 = task ptr (survives task_free)
    mov eax, [r12 + 0];                    ; load pid field
    cmp eax, 1;
    jne task_free_witness_fail;            ; pid MUST be 1 every iteration

    mov rdi, r12;
    call task_free;

    ; Post-condition check: pid_table[1] == NULL
    lea rax, [rip + _pid_table];
    mov rcx, [rax + 8];                    ; pid_table[1]
    cmp rcx, 0;
    jne task_free_witness_fail;

    ; Post-condition check: task_struct is zeroed (offset 16 = pml4_pa)
    mov rcx, [r12 + 16];
    cmp rcx, 0;
    jne task_free_witness_fail;

    add r15, 1;
    jmp task_free_witness_loop;

task_free_witness_done:
    ; Post-loop: free_count must equal free_count_before (all pages
    ; returned across 100 alloc/teardown cycles).
    call phys_alloc_free_count;
    cmp rax, r14;
    jne task_free_witness_fail;

    lea rdi, [rip + task_free_witness_ok_msg];
    call uart_puts;
    jmp task_free_witness_exit;

task_free_witness_fail:
    lea rdi, [rip + task_free_witness_fail_msg];
    call uart_puts;

task_free_witness_exit:
```

Rodata strings (added to `kernel_main.pdx` alongside `fd_witness_ok_msg`):

```
task_free_witness_ok_msg   : "R15 TASK FREE OK\n"
task_free_witness_fail_msg : "R15 TASK FREE FAIL\n"
```

### 4.2 What the four post-conditions prove

Per iteration:

1. **pid slot reuse.** `task_new` returns a task with pid == 1 every
   iteration → `pid_free` really cleared `pid_table[1]` on the previous
   `task_free`, and `pid_alloc`'s dense-low-first scan finds slot 1
   again. Directly hits the AC.
2. **pid_table zero.** After `task_free`, `pid_table[1] == NULL` →
   step 5 executed.
3. **Slab zero.** After `task_free`, `task_struct + 16 == 0` (pml4
   field) → step 4's `rep stosq` executed.

At loop end:

4. **Phys pool round-trip stability.** `phys_alloc_free_count()`
   returns the same value as before the loop → step 3
   (`aspace_teardown`) really released every frame `aspace_create`
   consumed inside `task_new`, and #649's `phys_free` really cleared
   the bitmap. This is the "no leak across 100 round-trips" invariant
   the master plan's R15.M6 (fork/exec) needs.

### 4.3 Fingerprint additions

Marker line appended to two fingerprint files (contains-in-order):

`tests/r15/expected-boot-r15-ring3.txt`:

```diff
 R15 RING3 HELLO OK
 R15 FD TABLE OK
+R15 TASK FREE OK
 IPI OK
```

`tests/r14b/expected-boot-r14b-loader.txt`:

```diff
 R15 FD TABLE OK
+R15 TASK FREE OK
 LOADER OK
```

The other 5 fingerprint files (`boot_r8_only`, `boot_r10`, `boot_r11`,
`boot_r12`, `boot_r12_denial`) do **not** need editing — their scope is
pre-R14b substrate that runs before this witness executes; the extra
line in the log post-dates their fingerprint window and contains-in-
order matching stays byte-identically green.

### 4.4 What the witness does NOT test (deferred)

- **Parent/child chain.** No fork yet; witness tasks are leaves with
  `parent_pid = 0`.
- **Non-leaf fd slots.** All fds stay at sentinel-0 across the loop.
  `task_free`'s "close all fds" pathway is exercised only in its
  `rep stosq` form, not with populated slots. A single-iteration
  variant with `fd_set(t, 5, 0xDEADBEEF)` before `task_free` +
  post-check `fd_get(t, 5) == 0` would validate the slot-zero path
  explicitly, but adds no additional coverage over the pml4-offset
  check (both are inside the `rep stosq` region). Deferred to
  R15.M6-002's zombie-split witness which does exercise this.
- **State machine transitions.** `task_free` in this design ignores
  the current `state` field — it just zeroes it. R15.M5-005 (#547)
  lands the state machine + panic-on-illegal-transition; the wire-up
  (`task_free must panic if state == RUNNING`) is a #547 concern, not
  a #550 concern.

## 5. LOC estimate

| File                                                              | LOC delta |
|-------------------------------------------------------------------|-----------|
| `src/kernel/core/sched/task_pool.pdx` (task_free + pid_free)      | +60       |
| `src/kernel/boot/kernel_main.pdx` (witness block + rodata)        | +55       |
| `tests/r15/expected-boot-r15-ring3.txt`                           | +1        |
| `tests/r14b/expected-boot-r14b-loader.txt`                        | +1        |
| `design/kernel/r15-m5-008-task-free-real.md` (this doc)           | +540      |
| **Total**                                                         | **~657**  |

Executable code: ~30 asm lines + ~55 justification / structure lines
= ~85 LOC in `task_pool.pdx`. Witness: ~50 lines of asm + ~5 lines of
rodata = ~55 LOC in `kernel_main.pdx`. Design + fingerprint: ~542 LOC.
Same order of magnitude as #549's ~554 LOC total.

## 6. Backtrack candidates

Ordered by preference.

### 6.1 Backtrack A — Separate slab bitmap (decouple pid from slab_index)

Instead of the compact `slab_index = pid - 1` mapping (§3.6), maintain
a separate `_task_slab_bitmap[64/64] = [u64; 1]` and a `task_slab_free(t)`
primitive that clears the bit corresponding to `(t - &_task_pool) / 4096`.
`task_free` grows by one call:

```
    call pid_free
    mov rdi, rbx
    call task_slab_free       ; NEW step 6
```

Consequence: two allocators (pid + slab) with their own bitmaps. At
R15.M5 this is redundant (identity mapping suffices), but at R15.M6+
when zombies retain a pid without a live slab (`task_zombify` frees
the slab but keeps `pid_table[pid] = &zombie_slot[pid]`), the
decoupling becomes necessary.

**Recommend as first backtrack** if #548's `task_new` design comes
back with an already-decoupled bitmap; otherwise reject because the
compact mapping is Pareto-optimal at R15.M5 and the R15.M6 transition
is a one-line addition to `task_free` at that time.

### 6.2 Backtrack B — Zombie-first split (do the R15.M6 refactor now)

Split `task_free` into `task_zombify(t)` (steps 3 + 4) and
`task_reap(t)` (step 5), with the state field driving the transition:

```
task_zombify(t):
    aspace_teardown(t->user_pml4_pa)
    // keep pid + exit_status + parent_pid live; zero everything else
    // (partial rep stosq with an offset skip — more complex than #4)
    t->state = ZOMBIE

task_reap(t):
    pid_free(t->pid)
    rep stosq the remaining fields (pid, state, exit_status, parent_pid)
```

The witness becomes `task_zombify → task_reap → assert pid reusable`.

Consequence: correctly models POSIX zombie semantics from R15.M5. But
R15.M5-005 (#547) has not landed the state machine; #548 has not
landed task_new's post-init state; the boot witness has no parent to
call `sys_wait`. The split adds coupling to unrelated deferred work.

**Reject as primary.** Retain as backtrack if R15.M6-002 (`sys_exit`)
becomes the next issue after this one and the maintainer prefers to
land the terminal shape once rather than migrating twice.

### 6.3 Backtrack C — Panic-on-fail instead of return-fail

`aspace_teardown` returns 0 unconditionally at R15.M5, so
`task_free` has no error path. If a future edit makes teardown
fallible (e.g. TLB shootdown failure), the natural response is
`panic("task_free: aspace teardown failed pid=%u\n", pid)` rather
than propagating a return code. Adds a panic call site + a rodata
format string; ~5 extra LOC.

**Neutral.** No panic path in this design because there's nothing
to panic on. If the R15.M6 zombie split adds `task_reap` fallibility
(e.g. reaping a still-running task), the panic lives there.

### 6.4 Backtrack D — Explicit `fd_close_all(t)` loop instead of `rep stosq` folding

Rather than let step 4's `rep stosq` zero the fd_table region as a
side effect, add an explicit prologue step 1':

```
    ; step 1': explicit fd close loop
    xor rcx, rcx
close_fd_loop:
    cmp rcx, 32                              ; FD_TABLE_MAX
    jae close_fd_done
    mov rdx, [rbx + rcx*8 + 168]             ; load slot
    test rdx, rdx
    jz close_fd_next                         ; already zero — skip
    xor edx, edx
    mov rsi, rcx
    mov rdi, rbx
    call fd_set                              ; fd_set(t, i, 0)
close_fd_next:
    add rcx, 1
    jmp close_fd_loop
close_fd_done:
```

Consequence: adds ~15 LOC + up to 32 `fd_set` calls per `task_free`.
At R15.M5 those calls are wasted work (fd_set is a naked store).
At R16.M3 they become vnode close operations (which is why the
design exists).

**Reject at R15.M5.** The `rep stosq` fold in §3.4 is functionally
identical (both zero the region) with zero call overhead. The R16.M3
transition rewrites this step to loop over `fd_close(t, i)` (a *new*
primitive that decrements vnode refcount, then zeros the slot). At
that time the change is local — just insert the loop before step 3.
This design is written to make that R16.M3 unfold a mechanical edit,
not a re-plumb.

### 6.5 Backtrack E — Preserve exit_status field across slab zero

Zero the slab piecewise so `t->exit_status` survives `task_free`.
`sys_wait` at R15.M6 wants to return `exit_status` to the parent
process; if `task_free` runs before `sys_wait` consumes it, the
value is lost. Consequence: 2-step `rep stosq` (zero pre-exit_status
region, skip 4 bytes, zero post-exit_status region) or a per-field
store loop.

**Reject at R15.M5.** No `sys_wait` yet; no `exit_status` consumer;
zeroing loses nothing. R15.M6-002 (`sys_exit`) will introduce a
side-table `_zombie_exit_status[MAX_PIDS] : [u32; 64]` that stores
the exit code by pid at zombification time; `task_reap` (R15.M6's
split of task_free) reads and clears that side table. The
`task_struct.exit_status` field becomes vestigial at that point —
retained only for debug dump alignment.

## 7. Tractability

**HIGH.**

- No new paideia-as encoder gap (`rep stosq`, SIB+disp store, RIP-rel
  `lea`, `call` cross-module — all audited).
- No new IDT / GDT / TSS / CR3 / MSR discipline.
- No new module directory; `src/kernel/core/sched/` is established
  substrate.
- ~30 asm LOC of body + ~5 asm LOC of pid_free + ~50 asm LOC of
  witness. Same tempo as #649 (phys_free real, ~40 asm LOC) and
  #549 (fd_table, ~80 asm LOC).
- Register discipline is documented and matches the phys_alloc
  post-mortem pattern (`f6195ed`) — the specific bug class that
  bit the previous milestone is *called out* in §3.2, not repeated.
- Witness backing is real: task_new (#548) creates the task, so the
  witness exercises the whole R15.M5 subsystem end-to-end. If #548
  slips, the witness cannot land — but then #550 cannot either, so
  the ordering is self-consistent.
- Marker line is contains-in-order in two fingerprint files, both
  of which already carry the R15-M5-007 marker one line above.

Known follow-ups (not blockers for #550):

- **R15.M6-002** (`sys_exit`) — splits `task_free` into
  `task_zombify` + `task_reap`. This design pre-arranges the split
  by ordering steps 3–4 before step 5 (§3.1 rationale 4).
- **R15.M6-007** (orphan adoption) — inserts a `foreach_child_of(pid)`
  walk at task_free entry that rewrites `child->parent_pid = 1`.
  Slots in cleanly between steps 2 and 3.
- **R16.M3-001** (`sys_open`) — grows fd slots to `fd_entry`; the
  §6.4 backtrack unfolds this step's implicit fd close into an
  explicit `fd_close(t, i)` loop.

## 8. Cross-cutting risks

- **#548 task_new commits to a different pid↔slab mapping.** §3.6
  pins the compact mapping `slab_index = pid - 1`. If #548 lands
  with a decoupled bitmap, this design's step 5 is insufficient —
  task_free must also call `task_slab_free(t)` (§6.1 backtrack A).
  Mitigation: #548's design doc (whenever it lands) references this
  doc's §3.6 as the pinned contract. This doc is written before
  #548's design; §3.6 is the authoritative freeze.
- **aspace_teardown handling of a NULL / zero pml4.** If task_new
  ever populates `user_pml4_pa = 0` (e.g. for a task without an
  aspace — kernel thread), `aspace_teardown(0)` walks nonsense
  memory. At R15.M5 task_new always allocates an aspace (per #548),
  so the field is always non-zero. Mitigation: task_free could
  guard with `test r13, r13; jz skip_teardown;` — 3 extra
  instructions, cheap. **Not adopted** because it papers over a
  task_new bug rather than surfacing it. If R15.M6 introduces
  kernel-thread task_structs without aspaces, the guard is a
  1-line addition at that time.
- **Silent partial teardown on aspace_teardown failure.** §3.3
  discards `aspace_teardown`'s return value. If a future
  aspace_teardown becomes fallible (see §6.3), that failure is
  swallowed. Mitigation: this doc pins the "unconditionally zero
  return" contract on aspace_teardown at R15.M5 — any future
  refactor that makes it fallible must also update every caller
  including this one. Regression captured by the phys_alloc
  free_count assertion in the witness (§4.2): if teardown fails
  to reclaim pages, the free_count check fails at iteration 100.
- **Callee-save clobber in aspace_teardown or pid_free.** §3.2
  trusts their discipline. If either regresses (e.g. an edit to
  `aspace_teardown` forgets to save `r13`), `task_free` breaks
  silently. Mitigation: the witness's per-iteration checks of
  `pid_table[1] == NULL` and `t->pml4 == 0` catch a partial task_free
  execution within one iteration; an r13 clobber would misroute the
  slab zero and the pml4 check would fail immediately. This is the
  cheapest early-warning we can build without adding a full
  register-state guard.
- **Fingerprint drift.** Adding "R15 TASK FREE OK" to two files
  must land in the same commit as the code. Missing either → smoke
  false negative. Mitigation: pre-push hook already blocks pushes
  that fail smoke (per `feedback_paideia_os_no_cicd`); we catch
  drift locally.

## 9. Backtrack markers

For the debugger-agent if the witness reports FAIL:

| Symptom                                | Root cause hypothesis                        | Where to look                      |
|----------------------------------------|----------------------------------------------|------------------------------------|
| Loop stops at iteration i > 1 with FAIL, pid != 1 | pid_free didn't clear pid_table[1]           | `pid_free`'s `mov [rax+rdi*8], 0` — check if imm-store encoding is wrong |
| Loop stops at iteration 1 with FAIL, pml4 != 0    | rep stosq clobbered but wrong count          | `rep stosq` count register — should be 278, not 32 or 2224 |
| Loop stops at iteration 1 with FAIL, pid != 1     | task_new returned pid > 1 on fresh boot      | `#545` pid_alloc: dense-low-first not working; may be scanning from pid 2 |
| free_count check fails at end (final line only)   | aspace_teardown → phys_free leaks 1+ page per iteration | Check aspace_teardown's per-level phys_free calls; #649 phys_free bit clearing |
| Silent hang, no FAIL, no OK            | task_free clobbers rbx and returns to wrong RIP | §3.2 discipline — verify prologue's 3 pushes match epilogue's 3 pops |
| FAIL immediately, iteration 0, task_new returns 0 | task_new hit ENOMEM on first call            | phys_alloc pool exhausted at boot — check what upstream witness (loader) leaked |

## 10. References

- Issue: paideia-os#550
- Milestone: paideia-os milestones/61 (R15.M5 Process abstraction)
- Sibling issues: #543 (layout), #544 (task_pool slab), #545 (pid_alloc),
  #548 (task_new), #549 (fd_table — landed), #551 (boot_r15_process)
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 8 (line 862+), interfaces (line 894–898), issue #8
  (line 960)
- Master plan: `design/milestones/r14b-master-plan.md`
  §R15.M5 process abstraction
- Prior-art register-discipline post-mortem: commit `f6195ed`
  (phys_alloc callee-save fix — the endemic-bug commit this
  design's §3.2 immunizes against)
- Prior-art teardown call graph: `src/kernel/core/mm/aspace_teardown.pdx`
  lines 26–30 (5-push prologue, 5-pop epilogue — same discipline shape)
- Prior-art fingerprint pattern: `design/kernel/r15-m5-007-fd-table-embed.md`
  §4.3 (contains-in-order marker addition)
- paideia-as encoder audits: `tools/paideia-as/tests/build-emit/`
  — `rep_stosq_smoke.pdx` (fold in §3.4),
  `mov_mem_imm_sib.pdx` (pid_free store in §3.5),
  `mov_mem_imm_sib_disp.pdx` (already used by #549 fd_table).
