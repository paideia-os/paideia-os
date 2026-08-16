---
issue: 1594
milestone: R31.M2
topic: Task pool sizing — the slot is the unit, not the struct
---

# Task pool sizing

## 1. The defect

```
_task_pool : [u64; 17792]        142336 bytes  = 64 * 2224   (the STRUCT)
task_new   : slab = &_task_pool + (pid - 1) * 4096            (the SLOT)
pid_alloc  : returns pid in [1, 63]
```

`142336 / 4096 = 34.75`. The array held thirty-four and three-quarter slots
while the allocator addressed sixty-three of them.

| pid | slab start (offset) | construction ends | inside the array? |
|-----|--------------------:|------------------:|-------------------|
| 34  | 135168 | 137392 | yes |
| 35  | 139264 | 141488 | yes, with 848 bytes to spare |
| 36  | 143360 | 145584 | **no — begins 1024 bytes past the end** |
| 63  | 253952 | 256176 | no — 113840 bytes past the end |

17792 was computed from the struct size (64 × 278 qwords). The addressing was
computed from the slot stride. Both numbers were correct about the thing they
described and neither described the array's job, which is to hold as many
SLOTS as the allocator can name.

The sibling array shows the rule: `Xsave._task_xsave_areas` is `[u64; 33280]`
carrying the comment `65 * 512` — sized from the slot, because
`xsave_area_for` strides by the slot. That one is right for the same reason
this one was wrong.

## 2. What it actually corrupted

Not `_pid_table` / `_pid_gen`, despite those being the immediately following
declarations. At `12768dc` the .bss layout was:

```
ffff8000007d3000  _task_pool            142336 B
ffff8000007f5c00  _pid_table               512 B
ffff8000007f5e00  _pid_gen                 512 B
ffff8000007f6000  _task_kernel_stacks  1064960 B
```

pid 35's construction stops at `…7f58b0`, 848 bytes short of `_pid_table`, and
pid 36's slab begins at `…7f6000` — exactly `_task_kernel_stacks`. The linker
had laid both allocator tables inside slot 34's unused padding, and nothing
addresses a slab above +2224, so they were untouched. **The obvious canary
fixture — seed a sentinel into `_pid_table`, allocate past the boundary,
assert it survives — passes on the broken tree.**

What took the damage was `_task_kernel_stacks`: every pid from 36 to 63 wrote
a complete `task_struct` into the kernel stacks of pids 1 through 7. That is
worse than a corrupted buffer. It is two writers with different ideas about
what the bytes mean, one of them a return-address chain, and it is the same
failure `#728 D9` created per-task kernel stacks to eliminate.

The array's own headroom is why the blast radius stopped there: it is sized
for a 64-block ceiling that `pid_alloc` never reaches, so pid 63's overflow
landed at block 6.8 of 65 rather than off the end of the object.

## 3. Why it survived

The boot path uses four pids. `12768dc` moved init's children from pid 2 to
pid 4 by adding two boot-spawned daemons; before that it used two. Roughly 23
boot witnesses, a 14-mode smoke matrix and 53 iterations of adversarial review
never asked for a thirty-sixth task.

A bound that only the untravelled part of a range violates cannot be found by
travelling the ordinary part. That is the general lesson and it is why the
witness for this drives the range deliberately rather than observing boot.

## 4. The ceiling

`MAX_PIDS = 64` is the ENTRY COUNT of `_pid_table` and `_pid_gen`, which are
indexed **by pid** with pid 0 a reserved sentinel. The allocatable range is
therefore `[1, 63]` and the concurrent-task ceiling is 63, not 64. The old
comments said "64 slots" and "pid ∈ [1, 64]"; that claim is the origin of this
defect, since `64 * 2224` is what someone computed from it.

The ceiling was reviewed rather than raised to make the assertion pass:

* **It is what the tables can express.** `pid_alloc`'s `cmp rcx, 64 / jae` is
  an array bound, not a policy number — `#740` changed it from `ja` precisely
  because pid 64 reads one qword past a `[u64; 64]` table. A true 64-task
  ceiling needs 65-entry tables and three bound changes, two of them in the
  `sys_exit` / `sys_wait` scanners that still use `ja` and belong to `#1585`.
  Widening here would edit those under a different issue's argument.
* **Nothing is near it.** Boot reaches pid 4. 63 is ~16× headroom.

The pool is sized for `MAX_PIDS` slots rather than `PID_MAX` (63), so the
invariant is stated over the table bound itself and the spare slot is
available if the ceiling ever moves. It mirrors the spare block
`_task_kernel_stacks` already carries.

## 5. Stride versus struct

Both numbers are right and they mean different things.

* **2224 is the struct, and it is full.** `sys_fork.pdx` pins
  `TASK_OFF_LANDING_RA` at +2216 — the last qword. No field sits above it, so
  no code reads a byte of the slot padding, so a recycled slot cannot leak a
  dead task's bytes through it. The build gate asserts
  `max(TASK_OFF_*) + 8 <= TASK_STRUCT_BYTES` so that a new field at +2224
  fails the build instead of quietly extending the struct past what `task_new`
  zeroes.
* **4096 is the stride, and it is deliberate.** It makes pid → slab a single
  `shl 12` instead of an `imul` by a non-power-of-two. The identical trade is
  made and named for the AP idle TCBs in `ap_bringup.pdx` §"Storage layout",
  which spends the same 1872 bytes per slot for the same reason.
* **The zero-fill covers the struct, not the slot, and must keep doing so.**
  `task_free` `rep_stosq`s through whatever task pointer it is handed, and the
  tree holds 18 standalone `[u64; 278]` slabs — idle, the sched and preempt
  witnesses, the chaos fake TCB, the syscall witness tasks — that are exactly
  2224 bytes with no padding. A 512-qword fill through any of them overruns.
  The gate pins all 18 to `TASK_STRUCT_QWORDS` for that reason.

So there is no second bug here: the 1872-byte tail is inter-slot padding, not
an uninitialised part of the struct. Before this fix the padding was not even
inside the array — the array ended at `64 * 2224`, so slot 34's tail ran past
it, which is how the allocator tables came to live there. Sizing from the slot
puts all of it back inside the object it belongs to.

## 6. The fix

### 6.1 One derivation, checked

`src/kernel/core/sched/task_pool.pdx` now declares the geometry once:

```
MAX_PIDS           = 64      PID_MAX            = 63
TASK_SLOT_SHIFT    = 12      TASK_SLOT_BYTES    = 4096
TASK_STRUCT_QWORDS = 278     TASK_STRUCT_BYTES  = 2224
TASK_POOL_QWORDS   = 32768   // MAX_PIDS * TASK_SLOT_BYTES / 8
```

The derivation cannot live in the type. paideia-as (4d0e7b3) requires an array
length to be an integer literal:
`crates/paideia-as/src/cmd_build/layout.rs::compute_bss_size_from_type` returns
8 for any length node that is not an `ExprLiteral`. `[u64; MAX_PIDS * 512]`
would therefore not fail the build — it would emit an **eight-byte**
`_task_pool`, the same defect several orders of magnitude worse. This is a
paideia-as gap worth an issue in that repo; until then the relation lives in
the gate.

### 6.2 `task_slab_of_pid`

The pid → address arithmetic was five inline instructions inside `task_new`
with no bound, no name, and no caller a witness could aim at. It is now a
function that refuses pid 0 and any pid ≥ `MAX_PIDS`, and `task_new` routes a
refusal into its existing OOM rollback. The pid-0 refusal is not decorative:
`(0 - 1) << 12` is `0xFFFFFFFFFFFFF000`, which lands the slab one slot **below**
the pool base, and a `jae MAX_PIDS` bound alone does not stop it.

### 6.3 `tools/verify-task-pool-bounds.sh`

Runs beside `no-aml-lint`, `fingerprint-coverage` and `cap-stride`, before any
assembler work. Checks: internal consistency of the constants; **the assertion**
`pool_bytes >= MAX_PIDS * TASK_SLOT_BYTES`; the declared array literal against
`TASK_POOL_QWORDS`; `_pid_table` / `_pid_gen` entry counts; all four pid bounds
in the file (value **and** `jae`-not-`ja`); `task_slab_of_pid`'s shift and its
pid-0 refusal; every `rep_stosq` width; `max(TASK_OFF_*) + 8` against the
struct; the 18 standalone slabs; and the two sibling pid-indexed arrays
(`_task_kernel_stacks`, `_task_xsave_areas`) against the same `MAX_PIDS`.

Mutation-tested — nine induced divergences, each caught, each tagged
`[task-pool-bounds]`. See §8.

## 7. The witness

`tests/kernel/sched/task_pool_bounds.pdx`, called from `kernel_main` between
the `task_free` and `task_new` witnesses, where the pid table is provably
empty (the preceding witness has just run 100 `task_new`/`task_free` round
trips and asserted the table and the physical free count both returned).

The canary is **measured, not guessed**: `_tpb_limit` is the lowest address
above `&_task_pool` among the pid-indexed structures the kernel has. Whatever
the linker put next is what is watched. This is the design point — a fixture
that seeded a sentinel into `_pid_table` would have passed on the broken tree
(§2).

| | |
|---|---|
| **A** | `task_slab_of_pid` refuses 0, `MAX_PIDS`, `MAX_PIDS+1`, `~0`. |
| **B** | Shape: `slab(pid) == base + (pid-1)*4096`, dense, for every allocatable pid. Not a detector; it establishes that checking the highest slab checks all of them. |
| **C** | **The detector.** `slab(PID_MAX) + 2224 <= _tpb_limit`. On the broken tree: 256176 against 142336. |
| **D** | Sweep: pattern-fill and re-zero the full footprint through every free slab up to the ceiling, checking the canary after each. Containment-checked per pid *before* each write, so a broken tree is diagnosed rather than scribbled across 110 KiB of kernel stack. |
| **E** | The shipping constructor at the top of the range: force the pid table full to `PID_MAX-1`, run the real `task_new`, assert the slab address, containment, pid, kernel-stack top and generation, verify the canary (exempting the two qwords `task_new` is documented to write), `task_free`, and restore exactly the entries it forced. |

Both exits restore. Leaving 62 phantom `_pid_table` occupants behind would
misdirect every subsequent `task_new` in the boot path and break the shell
fingerprints far from the cause.

Fingerprint `R31 TASK POOL BOUNDS OK`, asserted in
`tests/r17/expected-boot-r17-init.txt` and `tests/r17/shell-echo-hello.golden`
between `R15 TASK FREE OK` and `R15 TASK NEW OK`.

## 8. Mutation results

Build gate — nine mutations, all caught, all tagged `[task-pool-bounds]`:

| # | Mutation | Reported |
|---|---|---|
| M1 | `_task_pool` back to `[u64; 17792]` | declared literal vs `TASK_POOL_QWORDS` |
| M2 | `MAX_PIDS` 64 → 65 | seven findings incl. the pool-size assertion and all four bounds |
| M3 | `TASK_SLOT_SHIFT` 12 → 13 | shift vs stride, and `task_slab_of_pid`'s shift |
| M4 | `TASK_SLOT_BYTES` 4096 → 8192 | pool holds 32 slots, ceiling hands out 63 |
| M5 | `task_new` fill 278 → 512 qwords | fill width vs `TASK_STRUCT_QWORDS` |
| M6 | `pid_alloc` `jae` → `ja` | the `#740` fencepost, named |
| M7 | `task_slab_of_pid` pid-0 refusal deleted | names `0xFFFFFFFFFFFFF000` |
| M8 | `_idle_task_slot` 278 → 277 | standalone slab vs `task_free`'s fill |
| M9 | `TASK_OFF_LANDING_RA` 2216 → 2224 | field above the zero-filled region |

Witness — two mutations against a rebuilt mutant kernel:

* **W1**: `_task_pool` shrunk back to `[u64; 17792]` (gate bypassed, `nm`
  confirms `_task_pool` size back to `0x22c00` and `_pid_table` back to
  `…7f5c00`). `R31 TASK POOL BOUNDS FAIL line=3` — sub-test C.
* **W2**: same shrunken pool with C blinded to pid 35 so it passes.
  `R31 TASK POOL BOUNDS FAIL line=4` — sub-test D's per-pid containment
  catches it independently, at the first pid that would leave the pool.

Both reverted; `build/kernel.elf` md5 verified back to the clean value.

## 9. Fallout: `death_witness` sub-test 3

`tests/kernel/driver/death_witness.pdx` sub-test 3 used pid 63 as "a pid
nothing in this boot allocates". `#1594`'s witness allocates `PID_MAX`
deliberately, so that stopped being true. It now uses pid 64 — `MAX_PIDS`,
which `pid_gen_read` bounds out permanently — so the sub-test can no longer be
invalidated by another fixture's allocation choices.

Moving it exposed a **separate, pre-existing imprecision in `#1583`**, recorded
here and at the sub-test rather than fixed under this issue:
`driver_death_bind` refuses on `pid_gen_read(pid) == 0`, whose justification
calls that "never allocated, **already reaped**, or out of range". `pid_free`
does not reset `_pid_gen` and `pid_gen_bump` only increments, so an
already-reaped pid keeps a non-zero generation and **is** bound. The security
property still holds — the next occupant gets a higher generation and cannot
match the key — so the consequence is a row bound to a dead incarnation that
resolves to nothing, which sub-test M already covers as a stale binding. Keying
the refusal on `_pid_table[pid] != 0` belongs to a `#1583` follow-up.

## 10. Cross-references

* `src/kernel/core/sched/task_pool.pdx` — the geometry constants and
  `task_slab_of_pid`
* `tools/verify-task-pool-bounds.sh` — the gate
* `tests/kernel/sched/task_pool_bounds.pdx` — the witness
* `design/kernel/task-struct-layout.md` — the 2224-byte struct freeze
* `src/kernel/core/sched/ap_bringup.pdx` §"Storage layout" — the same
  slot-versus-struct trade, made correctly
* `src/kernel/core/cpu/xsave.pdx` — the sibling pid-indexed array, sized from
  the slot
