---
issue: 551
milestone: R15.M5 (Process abstraction — task_struct, PID allocator, fd table)
subsystem: 8 — Process abstraction
prereq:
  - "#544 (task_pool slab — LANDED at b73e470)"
  - "#545 (pid_alloc dense-low scan — LANDED at b73e470)"
  - "#548 (task_new real body — LANDED at b73e470)"
  - "#549 (fd_table embed — LANDED at 22437af)"
blocks:
  - "R15.M5 closure (Subsystem 8 witness bundle)"
  - "R15.M6 (sys_fork lifecycle proofs will layer over the same 3-task fingerprint)"
touching:
  - src/kernel/boot/kernel_main.pdx              (~45 LOC pool witness block, appended to task_new witness)
  - tools/boot_stub.S                            (2 new .ascii messages, ~6 LOC)
  - tools/run-smoke.sh                           (1 new smoke-mode case, ~6 LOC)
  - tests/r15/expected-boot-r15-process.txt      (new fingerprint, ~14 LOC)
  - design/kernel/r15-m5-009-smoke-process-mode.md (this doc)
related:
  - design/kernel/r15-m5-006-task-new-real.md    (single-task witness this doc extends)
  - design/kernel/r15-m5-007-fd-table-embed.md   (fd_alloc/set/get already witnessed)
  - design/kernel/r15-m5-008-task-free-real.md   (task_free is RESET — this doc deliberately does not depend on it)
  - design/milestones/r14b-tactical-plan.md §Subsystem 8 item 9 (line 966)
---

# R15-M5-009 — `boot_r15_process` smoke: 3-task pool witness with `TASK pool ok pids=1,2,3` marker (#551)

## 1. Scope

Give R15.M5 Subsystem 8 a fingerprint that proves the **pool + PID
allocator + task_new** triple composes as designed across a
**3-task sequence**, without relying on the task_free path
(#550 is currently reset; see §5.4).

The witness runs at boot, immediately after the single-task
witness landed by #548 (`R15 TASK NEW OK`), and prints exactly
one deterministic line:

```
R15 TASK pool ok pids=1,2,3
```

The `boot_r15_process` smoke mode asserts this line, plus the
full ring-3 fingerprint that precedes and follows it, as a
contains-in-order match against captured serial output.

### 1.1 What this issue proves

- **PID allocator is dense-low-first without churn.** Three
  consecutive `task_new(NULL)` calls with no intervening `task_free`
  yield pids `1, 2, 3` in that exact order — confirms
  `pid_alloc`'s linear scan of `_pid_table[1..64]` (§2.3 of #548)
  starts at index 1 every call and finds the first NULL each time.
- **Slab base + stride arithmetic is monotone.** The three
  slab addresses returned satisfy
  `slab_i = &_task_pool + (i-1) * 4096` for `i ∈ {1, 2, 3}`,
  which the `pid_table[i] = slab_i` publish step confirms via
  three SIB-scale-8 loads.
- **`aspace_create_user` composes cleanly across the third call.**
  Three back-to-back user aspaces are constructed; the third one
  landing (non-zero `pml4_pa` in `_task_pool[2] @ +16`) proves
  `phys_alloc`/`aspace_create_user` state stays consistent across
  the allocation churn.

### 1.2 What this issue deliberately does NOT prove

- **No task_free round-trip.** #550 (`task_free`) is reset — its
  100-iter round-trip hits an unknown bug (issue body records
  four hypotheses). This witness constructs three tasks and
  leaves them in the pool for the remainder of the boot. That
  is safe: `_task_pool` is 64 × 4096 = 256 KiB of pinned `.bss`,
  the boot never enters ring-3 for pids 2/3, and the LOADER /
  ELF LOAD witnesses that follow use pids allocated later
  (or never dereference the pool).
- **No re-alloc / no compaction.** The dense-low-reuse invariant
  (freeing pid 2 then allocating → pid 2) is a **`task_free`
  responsibility**; it lands with the #550 fix, not here.
- **No state-machine transitions.** The three tasks all stay
  in `STATE_NEW`; the runqueue never sees them. #547
  (state-machine doc) formalizes the transition table.
- **No fd_table exercise on the new tasks.** #549's fd witness
  runs earlier against `_fd_witness_task` (a static 2224-byte
  blob) and is unchanged by this issue.

## 2. Prereq check

### 2.1 What's in place

| Primitive                    | Location                                        | Contract used by this witness                       |
|------------------------------|-------------------------------------------------|-----------------------------------------------------|
| `task_new(NULL)`             | `core/sched/task_pool.pdx` (landed b73e470)     | `(u64) -> u64 !{mem} @{}`. Returns slab addr or 0. Callee-saves rbx, r12–r15 via 3-push prologue (§3.1 of #548). |
| `_task_pool` symbol          | `core/sched/task_pool.pdx:20`                   | `[u64; 17792] @align(4096)` — 64 × 2224-byte slots. |
| `_pid_table` symbol          | `core/sched/task_pool.pdx:25`                   | `[u64; 64]` — index `pid` holds slab addr or 0.     |
| `pid_alloc()`                | `core/sched/task_pool.pdx:32`                   | Linear scan starting at index 1; returns lowest free pid. |
| `aspace_create_user()`       | `core/mm/aspace_create.pdx:96`                  | `() -> u64 !{mem} @{}`. Returns pml4_pa or 0xFFFFFFFF (ASPACE_CREATE_OOM). |
| `uart_puts` register profile | `boot/uart.pdx:81`                              | Clobbers rax/rcx/rsi/rdi only. Preserves rbx, r12–r15. Verified §3.3. |
| `.ascii` string emit in boot_stub.S | `tools/boot_stub.S:355-362`              | Prior art: `task_new_witness_ok_msg` — the pool witness follows the same `.global` + `.align 8` + `.ascii "...\n\0"` recipe. |

### 2.2 What is NOT in place

- **`task_free` real body (#550).** Reset. This issue's design is
  **explicitly independent** of it. If #550 lands after #551 is
  green, the pool witness can be extended with an alloc-free-realloc
  hop under a follow-up issue (§5.4 backtrack B).

### 2.3 Encoder gaps

**None.** The pool witness uses only:

- Register-to-register `mov`, `xor`, `cmp` — audited every module.
- Cross-module `call task_new` — audited every module.
- `lea r64, [rip + sym]` — RIP-relative address load.
- `mov r32, [r64 + disp8]` — pid field read at offset 0 (u32 slot).
- `mov r64, [r64 + disp8]` — `_pid_table` slot read at offset 16 / 24.
- `je / jne / jmp` — control flow only.
- No SIB-scale on REX.B-extended base registers (see PA-#928 caveat
  in #548 §2.4). All SIB uses base rax (`_pid_table` base) with a
  fixed disp8 offset, or no SIB at all (fixed offsets 16 / 24 into
  `_pid_table`).

## 3. Design

### 3.1 Placement in `boot_continue_after_ring3`

The witness lives in `src/kernel/boot/kernel_main.pdx` inside
`boot_continue_after_ring3` (the tail extracted for #652), directly
after the existing `task_new_witness_exit:` label (line 549) and
before the `IA32_GS_BASE` setup at line 551.

Sequence in kernel_main_64's tail:

1. `fd_witness_done:`   (#549 — landed)
2. `task_new_witness_exit:` (#548 — landed; task 1 verified, r12 = slab_1)
3. **`pool_witness:`** (#551 — this issue)
4. `wrmsr` GS_BASE (#507)
5. `process_init` … `pic_mask_all`
6. IPI structural witness (#512 / #646)
7. LOADER / ELF LOAD witness (#520 / #648)

The witness fits between (2) and (4) because:

- Task 1 is already constructed and verified by (2). r12 holds
  `slab_1` at that point; the `wrmsr` at (4) does not touch r12.
- GS_BASE (4) does not depend on the pool state. Delaying it by
  one witness is boot-order-neutral.
- The witness completes before `process_init` — `process_init`
  currently does not touch `_task_pool` (verified by grep at
  design time), so no aliasing concern.

### 3.2 Body sequence — four steps, one rationale

```
; Precondition (from #548 witness): r12 = slab_1 (task 1's slab addr),
; unless task_new(NULL) for pid 1 failed — in which case the fail path
; already emitted "R15 TASK NEW FAIL" and r12 may hold garbage.
; Guard: pool witness runs only if task 1 slab pointer is non-zero.

pool_witness:
  ; step 1: guard — bail if task 1 witness failed
  cmp r12, 0
  je  pool_witness_fail                     ; task 1 failed; pool witness fails too

  ; step 2: construct task 2 → verify pid == 2 → save slab in r13
  xor  rdi, rdi                             ; parent = NULL
  call task_new
  cmp  rax, 0
  je   pool_witness_fail
  mov  r13, rax                             ; r13 = slab_2
  mov  eax, [r13 + 0]                       ; pid @ 0 (u32)
  cmp  eax, 2
  jne  pool_witness_fail

  ; step 3: construct task 3 → verify pid == 3 → save slab in r14
  xor  rdi, rdi
  call task_new
  cmp  rax, 0
  je   pool_witness_fail
  mov  r14, rax                             ; r14 = slab_3
  mov  eax, [r14 + 0]
  cmp  eax, 3
  jne  pool_witness_fail

  ; step 4: publish check — pid_table[2] == r13, pid_table[3] == r14
  lea  rax, [rip + _pid_table]
  mov  rcx, [rax + 16]                      ; pid_table[2]  (index 2 * 8 = 16)
  cmp  rcx, r13
  jne  pool_witness_fail
  mov  rcx, [rax + 24]                      ; pid_table[3]  (index 3 * 8 = 24)
  cmp  rcx, r14
  jne  pool_witness_fail

  ; all green
  lea  rdi, [rip + pool_witness_ok_msg]
  call uart_puts
  jmp  pool_witness_exit

pool_witness_fail:
  lea  rdi, [rip + pool_witness_fail_msg]
  call uart_puts

pool_witness_exit:
  ; fall through to GS_BASE setup at line 551
```

**Why this specific check set.**

- **Only `pid == N` field-checked (not parent_pid, state, pml4_pa).**
  The single-task witness (#548) already covers those five checks
  on task 1. Tasks 2 and 3 share the same construction path, so
  the marginal information from re-checking every field is small.
  The three pieces of unique evidence 2/3 add over 1 are:
    (a) `pid_alloc` returns 2 then 3 (allocator advances, not stuck);
    (b) `pid_table[2..3]` publishes correctly (SIB store at a
        non-1 index is not special-cased);
    (c) three back-to-back `aspace_create_user` calls succeed
        (implicit in `rax != 0` at each `task_new` return).
- **`pid_table[N]` check is the strongest single check.** It
  proves the *whole* body ran to step 8 (`pid_table[pid] = slab_addr`
  publish step of #548 §3.1). If any earlier step failed, the
  slot would be either untouched (0) or written to the wrong slab.
- **No re-check of task 1.** `pid_table[1] == slab_1` was verified
  by #548's witness already. Re-checking would only add noise and
  extend register pressure (we'd need to spill `slab_1` into r15).

### 3.3 Register discipline

- Uses only r12/r13/r14 for slab pointers. r12 is inherited from
  the #548 witness (`slab_1`); r13/r14 are written fresh here.
- `uart_puts` and `uart_putc` (verified in `boot/uart.pdx:52-98`)
  clobber only rax/rcx/rsi/rdi. rbx, r12–r15 are preserved.
- `task_new` self-documents (justification in `task_pool.pdx`) as
  preserving rbx, r12, r13 via 3-push prologue. It also does not
  touch r14 or r15 (verified by reading the body — no `mov r14,`
  or `mov r15,` in the task_new function). So r14 is safe as
  `slab_3` across a hypothetical fourth `task_new` call.
- No stack alignment concerns: no local `push`/`pop`; every `call`
  site inherits the boot stack alignment established by
  `boot_stub.S` (rsp ≡ 0 mod 16 at kernel_main_64 entry, preserved
  through the prior witnesses).

### 3.4 String data — `tools/boot_stub.S`

Append immediately after `task_new_witness_fail_msg` (line 362 area):

```asm
# R15-M5-009 (#551): task pool witness — 3-task success message
.global pool_witness_ok_msg
.align 8
pool_witness_ok_msg: .ascii "R15 TASK pool ok pids=1,2,3\n\0"

# R15-M5-009 (#551): task pool witness — failure message
.global pool_witness_fail_msg
.align 8
pool_witness_fail_msg: .ascii "R15 TASK pool FAIL\n\0"
```

The success string is prefixed `R15 ` for grep-ability with the
family of R15-era markers; the fingerprint substring
`TASK pool ok pids=1,2,3` is still a substring of that emitted
line (see §3.6 on contains-in-order matching).

### 3.5 Fingerprint file — `tests/r15/expected-boot-r15-process.txt`

The `boot_r15_process` fingerprint is the ring-3 fingerprint **plus
one new line inserted after `R15 TASK NEW OK`**:

```
B
HI VA FFFF8000
PaideiaOS R8
PHYS FREE ROUNDTRIP OK
KPTI OK
KPTI SCRATCH OK
ENTER USER RELOC OK
R15 RING3 HELLO OK
R15 FD TABLE OK
R15 TASK NEW OK
TASK pool ok pids=1,2,3
IPI OK
LOADER OK
ELF LOAD OK
```

**Why superset (not standalone).** A regression that removes
*any* earlier marker (KPTI OK dropped, ring3 broken, ipi missing)
also fails the process fingerprint. That means `boot_r15_process`
is strictly stronger than `boot_r15_ring3`; there is never a
scenario where `ring3` is green but `process` is red due to an
"earlier" bug. This makes bisection cleaner: process failing +
ring3 green ⇒ regression is between `R15 TASK NEW OK` and
`IPI OK`, i.e. **in this issue's code**.

The fingerprint uses the substring `TASK pool ok pids=1,2,3`
(no `R15 ` prefix). Contains-in-order matching (§3.6) treats
the emitted line `R15 TASK pool ok pids=1,2,3\n` as a match, and
the tactical plan (line 966) pins that exact substring.

### 3.6 Smoke-mode wiring — `tools/run-smoke.sh`

Add a case in the mode dispatcher, mirroring `boot_r15_ring3`:

```bash
    boot_r15_process)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r15/expected-boot-r15-process.txt"
        TIMEOUT=6
        EXPECTED=""
        ;;
```

Place immediately after `boot_r15_ring3`. Timeout is 6 s
(same as ring3; three extra `task_new` calls each cost a
`phys_alloc` + `aspace_create_user` round-trip, order 10 µs
each on QEMU — well under the timeout budget).

Update the mode-list comment in the header docstring
(`# Usage:` block, lines 6-28) to include `boot_r15_process`.

### 3.7 Contains-in-order matching — interaction with other fingerprints

`tools/run-smoke.sh` (lines 175-198) iterates fingerprint lines
and requires each one to be **present as a substring somewhere in
the log**. Order is enforced *loosely* — a later line must be
findable after the earlier match. The current implementation
(commit d7e12… inspected) uses `[[ "${log_content}" == *"${line}"* ]]`
which is a global substring test (not offset-anchored), so
"after" is not strictly enforced. This is a documented weakness
but it means the process fingerprint's new line does not need to
occupy a specific byte offset — only to appear in the log.

**Impact on existing fingerprints:**

- `boot_r15_ring3` continues to run the same kernel binary. Its
  fingerprint is a strict prefix (up to line ordering) of the
  process fingerprint minus `TASK pool ok pids=1,2,3`. Since the
  pool witness *adds* one output line and *removes* nothing,
  every existing fingerprint line still appears in the boot log
  in the same relative order.
- `boot_r14b_loader`, `boot_r14b_ipi`, `boot_r14b_kpti`,
  `boot_r14b_hivma`, `boot_r14b_ud` all run smaller subsets of
  the same boot log. All remain byte-identically green.
- The 5-mode legacy smoke (`boot_r8_only`, `boot_r10`, `boot_r11`,
  `boot_r12`, `boot_r12_denial`) — unchanged; those fingerprints
  don't include any R15 lines and don't observe the new witness.

### 3.8 Failure signature vs. #548 witness

If the pool witness fails, the log will show:

```
R15 TASK NEW OK           ← #548 witness green (task 1 constructed)
R15 TASK pool FAIL        ← #551 witness red (task 2 or 3 failed)
```

That two-line signature distinguishes:

- **`R15 TASK NEW FAIL` + no pool line** ⇒ task 1 broken, #548 regression.
- **`R15 TASK NEW OK` + `R15 TASK pool FAIL`** ⇒ pid_alloc reuse,
  or `aspace_create_user` OOM on second/third aspace, or SIB store
  at index != 1 broken. Bisect targets the sequence
  `pid_alloc → aspace → publish`.
- **`R15 TASK NEW OK` + no pool line at all** ⇒ pool witness code
  itself crashed (triple fault mid-witness). Bisect targets the
  first `mov eax, [r13+0]` load — a null slab pointer would fault
  there since the guard is on r12, not on rax after `task_new`.

## 4. Verification

### 4.1 Local smoke

```bash
./tools/run-smoke.sh boot_r15_process
# expected: exit 0, "smoke: fingerprint check passed (all 14 lines found in order)"
```

### 4.2 Regression baseline

All existing smoke modes stay green byte-identically:

```bash
for m in boot_r8_only boot_r10 boot_r11 boot_r12 boot_r12_denial \
         boot_r14b_hivma boot_r14b_kpti boot_r14b_ipi boot_r14b_loader \
         boot_r14b_ud boot_r15_ring3 boot_r15_process; do
  ./tools/run-smoke.sh "$m" || { echo "REGRESSION: $m"; exit 1; }
done
```

The pre-push hook remains `boot_r10` (unchanged). Manual per-milestone
verification runs the loop above.

### 4.3 3/3 reps acceptance

Issue acceptance criterion is "3/3 reps green". Three consecutive
`./tools/run-smoke.sh boot_r15_process` invocations must return exit 0.
There is no non-determinism in the pool witness (no timing, no IRQ,
no PRNG), so 3/3 is expected on first landing; deviations indicate a
build reproducibility bug, not a witness flake.

## 5. Backtrack candidates

### 5.1 Backtrack A — pool witness fires before task 1 witness fails silently

If `R15 TASK NEW FAIL` prints but r12 is not zero (task_new returned
a bogus pointer that was still non-NULL), the guard at step 1 lets
control fall through into step 2 and `[r13 + 0]` faults on a bad
address. Mitigation: the fail path in #548 explicitly did NOT store
into r12 on the failure branch (see `task_new_witness_fail:` at
kernel_main.pdx:545 — jumps directly to fail msg without writing
r12). If that ever changes, this witness should either add a
sentinel-clear (`xor r12, r12`) on the fail branch, or become a
skip-if-r12-taint by re-loading `slab_1` from `pid_table[1]`.

### 5.2 Backtrack B — task_free lands (#550 fix)

Once #550 is fixed, the pool witness can grow one extra step:
after step 4, call `task_free(r14)` (dropping task 3), then
`task_new(NULL)` again and assert `pid == 3` (dense-low reuse).
That upgrade is a follow-up issue in R15.M5, not a re-open of
this one. It would change the fingerprint line to something like
`R15 TASK pool ok pids=1,2,3 reuse=3` — non-overlapping with this
issue's fingerprint substring, so the two can co-exist under
different smoke modes.

### 5.3 Backtrack C — MAX_TASKS raised past 64

If R15.M6 raises `MAX_TASKS` (currently 64 per #544's slab shape),
the pool witness scales trivially by extending step-count. The
`pid_table[N]` disp8 encoding (0, 8, 16, 24) needs to stay disp8
(< 128) for the checked indices; up to `pid_table[15]` (disp = 120)
is safe. For pool witnesses beyond pid 15 the offset would need
`disp32` — one encoder audit but no design change.

### 5.4 Backtrack D — dense-low invariant weakens under SMP

At R15.M5 the boot runs on CPU 0 only, and `pid_alloc` has no lock.
If R15.M7 adds AP bring-up and any AP calls `task_new` before this
witness runs, the `pids=1,2,3` invariant breaks (AP might race to
grab pid 2). The witness must then either (a) run before AP bring-up
(currently the case — `boot_continue_after_ring3` is entirely
BSP-side), or (b) hold a global `_task_pool_lock` across the three
allocations. #548 §2.3 pins pid_alloc as "single-CPU race-free";
this witness's placement respects that pin.

### 5.5 Backtrack E — witness output interleaves with IPI witness

If the IPI witness (#512 / #646) ever runs asynchronously (e.g.
its handler prints from an IRQ context after the pool witness
started), the fingerprint line ordering could get shuffled and
the process fingerprint's later lines (`IPI OK`, `LOADER OK`)
would appear before or interleaved with the pool witness's
output. Currently both witnesses are synchronous BSP-side blocks
and this risk is theoretical. If #646 grows async delivery
verification, the pool witness may need to be pushed *before*
the IPI witness (both currently emit to the same UART — polled,
serialized).

## 6. Sizing

| Location                                             | LOC     | Kind                     |
|------------------------------------------------------|---------|--------------------------|
| `src/kernel/boot/kernel_main.pdx` pool_witness block | ~45     | .pdx assembly + justification comment |
| `tools/boot_stub.S` two `.ascii` strings + `.global` | ~8      | assembler data           |
| `tools/run-smoke.sh` `boot_r15_process)` case + doc  | ~8      | bash                     |
| `tests/r15/expected-boot-r15-process.txt`            | ~14     | plain text               |
| `design/kernel/r15-m5-009-smoke-process-mode.md`     | (this)  | markdown                 |
| **Kernel-side total**                                | **~75** |                          |

## 7. Tractability

**High.** The witness is a mechanical extension of #548's
task_new witness (r12 pattern → r13, r14 pattern), the string
emit follows a template used seven times already in
`boot_stub.S`, and the smoke-mode case is a copy-paste of
`boot_r15_ring3`. No paideia-as encoder demands. No new
subsystem interaction. No dependence on #550 (which is reset).
No dependence on #547 (doc-only).

Estimated implementation time: **one workerbee session**.
Estimated risk of regressing an existing smoke mode: **near-zero**
(the change is purely additive — one new emit line, one new
fingerprint file, one new run-smoke.sh case).
