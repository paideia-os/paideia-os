# R31.M2-1599 — `task_free` is a death, and deaths sweep the owner column

Issue: #1599. Companion to `design/capabilities/ownership-and-lineage.md`
(#1587) and `design/capabilities/loader-seeded-slot-allocation.md` (#1596).

## 1. The defect

Every *real* process death sweeps the capability ownership column:

```
sys_exit_body §2.6 ──┐
fault_kill        ──┴─> driver_death_notify ─> cap_owner_sweep_revoke(pid, gen)
```

`task_free` did not. It ran `aspace_teardown` → slab zero → `pid_free`, and
never touched `cap_owner`. That is the *other* way a task stops existing, and
it is not a corner: `boot_spawn_user_task` reaches it directly through
`bspawn_fail_free_task` on elf-load and stack failures, both of which occur
*after* `loader_seed_caps` has claimed the image's sidecar capabilities for
the task's `(pid, generation)`.

## 2. Why it bites — the generation is stamped at allocation

`pid_gen_bump` runs in `task_new`, at allocation, **not** in
`pid_free`/`task_free`. So after a `task_free` the pid slot is free but
`_pid_gen[pid]` still names the incarnation that just died, and a stale owner
key therefore still reads **live** through `cap_owner_live_key` until that
exact pid is reused.

Compose that with #1596's ownership pre-pass, which *refuses* to seed a slot
a live key claims, and the shape is:

> A spawn that fails for any reason permanently poisons the slots it had
> already claimed, and `LOADER_SEED_SLOT_TAKEN` surfaces on the **next**
> spawn rather than the one that failed.

A recoverable, well-reported failure turned into a permanent, misattributed
one. Worse, whether it bites at all depends on whether the freed pid happens
to get reused first — so the same defect is intermittent.

## 3. The fix, and the alternative that was rejected

`task_free` reads the generation and sweeps, as step 2.5, **before**
`aspace_teardown`:

```
pid_gen_read(pid) -> gen
cap_owner_sweep_revoke(pid, gen)     // count discarded
aspace_teardown(pml4)
rep stosq slab zero
pid_free(pid)
```

### 3.1 Why not bump the generation at death instead?

Bumping `_pid_gen` in `pid_free`/`task_free` would also make the stale key
read dead, and it is the wrong fix in three independent ways:

1. **It makes the leak unsweepable rather than swept.** The column would
   still carry the dead task's key, and `cap_owner_sweep_revoke`, which
   matches on the exact packed `(pid, gen)`, could never match it again — a
   descriptor left live, held by nobody, reachable by no teardown. That
   trades a loud refusal for a silent retention. `cap_owner_live_key`'s own
   header argues for the opposite direction: a missed sweep should degrade
   to "the slot looks free", never to "the slot is unclaimable by anyone".
2. **`pid_free` runs where no occupant ever appeared** — `task_new`'s OOM
   rollback, `sys_fork`'s `fail_rollback`, the boot-time bulk reset. Bumping
   there makes the counter stop meaning "incarnations of this pid", which is
   the property #1583 stamps it at allocation to preserve.
3. **`driver_death_notify` reads `pid_gen_read(pid)` at death** and relies on
   it still naming the *dying* task. Moving the bump to death makes that read
   order-dependent across `sys_exit` and `sys_wait4`; a sweep that runs after
   the bump matches nothing and reports success — the exact failure #1590
   closed.

So the generation stays stamped at allocation.

### 3.2 Ordering

The sweep runs first, mirroring the real death path (revoke authority, then
release memory) and guaranteeing that no per-kind revoke beneath the sweep
reaches through a descriptor into an address space already torn down.

### 3.3 Idempotence

Free by construction, with no flag. `cap_owner_sweep_revoke` clears the
column on every slot it matches — `cap_own_rv_unown` runs even for a refused
per-kind revoke — so a second arrival matches zero slots, revokes nothing,
and its audit record is suppressed at count 0. A real death that already
swept, followed by a `task_free`, is clean.

### 3.4 Effects and capabilities

`task_free` widens from `@{fs}` to `@{cap, fs}`. Effects are unchanged:
`cap_owner_sweep_revoke`'s `!{mem, sysreg}` is already a subset. Its three
callers — `boot_spawn_user_task` (`@{cap, sched}`),
`boot_continue_after_ring3` (`@{boot}`) and the `task_pool_bounds` fixture —
all elaborate unchanged. `TaskPool` now calls into `CapOwner`, which calls
back into `TaskPool` for `pid_gen_read`; the elaborator accepts the mutual
reference.

### 3.5 The #1596 patch is reverted

`m6_symtab_witness` carried a local sweep-then-free as a stopgap. It is
removed rather than kept alongside: the sweep is idempotent so keeping both
would be *harmless*, but it would also mean the witness passes whether or not
`task_free` does its job — a witness that survives the removal of the
mechanism it depends on, which is the class of defect #1577/#1578/#1585/#1592
are all instances of.

## 4. Keeping the failing-spawn path under test

The matrix had **no failing spawn in it at all**. That is the actual reason
this survived two milestones.

### 4.1 Why the failure has to be injected

The post-claim window is one step wide. Against the moment `loader_seed_caps`
stamps `cap_owner`:

| `boot_spawn_user_task` failure | claimed anything? |
| --- | --- |
| `registry_full`, `no_frames` | no — refused before `task_new` |
| `task_new` | no — no task |
| `bad_entry` | no — step 2, before `elf_lite_load` |
| `elf_load` | no — `loader_seed_caps` validates *every* entry, ownership pre-pass included, before minting *any* |
| `stack` | **yes** — `elf_lite_load` returned `ELF_OK`, slots are minted and claimed, `user_stack_alloc` then finds no frames |

So no malformed image can reach the state under test; only frame exhaustion
can, and arranging genuine exhaustion past the `>= BOOT_SPAWN_MIN_FREE_FRAMES`
pre-check but short of four stack pages plus page tables means perturbing the
whole boot's allocator to hit a window a few frames wide. A test that fragile
stops being evidence.

### 4.2 `_boot_spawn_inject_stack_fail`

A one-shot `.bss` word. When set, `boot_spawn_user_task` skips
`user_stack_alloc` and takes the **existing** `bspawn_err_stack` path — the
production teardown, not a parallel one — so the state torn down (caps
claimed, stack unmapped) is byte-for-byte what a real `user_stack_alloc` OOM
would have produced. It is consumed on the way past; a knob that stayed armed
would turn a forgotten store into every later spawn failing, a worse failure
than the one being tested. No production path writes it.

### 4.3 The witness (sub-test 4.5, `boot_r31_spawn_pair`)

Asserts, in order:

- (a) the spawn actually failed — otherwise (b)–(d) are vacuous;
- (b) it failed for the reason claimed (`BOOT_SPAWN_ERR_STACK` = 6), not some
  earlier reason that never claimed anything;
- (c) the injection was consumed;
- (d) **both** slots the failed spawn claimed read `CAP_OWNER_NONE` through
  `cap_owner_live_key` — the same predicate #1596's pre-pass uses, so the
  question is asked in the exact terms the next spawn will ask it.

Then sub-test 5 spawns the same image for real. Marker:
`R31 SPAWN FAIL SWEEP OK`, asserted in `tests/r31/expected-spawn-pair.txt`.

### 4.4 Mutation results

| mutation | result |
| --- | --- |
| remove the sweep from `task_free` | **FAIL** — `R31 BOOT SPAWN FAIL line=45`, `R31 BOOT SPAWN ERR count=6`. Sub-test (d): slot 0 still reads live. |
| remove the injection check from `boot_spawn_user_task` | **FAIL** — `R31 BOOT SPAWN FAIL line=45`, `R31 BOOT SPAWN ERR count=0` (last error stale = the spawn succeeded). Sub-test (a); the knob is not vacuous. |
| remove the sweep **and** neuter sub-test (d) | **PASS** — see §4.5. |

### 4.5 The third row is the important one: (d) is not redundant

The obvious design would have been to skip the predicate and let the second
spawn's refusal be the whole test. It was measured, and it does not work:
with the sweep removed *and* sub-test (d) neutered, the boot **passes**.

The reason is the same mechanism that makes the bug intermittent. The failed
spawn releases pid *P*; the immediately following real spawn calls `task_new`,
which `pid_alloc`s *P* back (dense-low-first, no aging) and bumps
`_pid_gen[P]`. The stale key's generation no longer matches, so
`cap_owner_live_key` answers `CAP_OWNER_NONE` and the pre-pass admits the
seed. The poison is masked by the very reuse that would otherwise expose it.

So the downstream symptom is only visible when the poisoned pid is *not* the
next one allocated — which depends on intervening `task_new`/`task_free`
traffic and is therefore exactly the kind of boot-order coincidence a golden
should never rest on. That was already stated, informally, in the note #1596
left on `m6_symtab_witness` ("whether the stale key still LOOKS live depends
on whether the freed pid happens to be reused before the spawn, which is not
a property to leave a boot depending on"). §4.5 is that sentence, measured.

**Sub-test (d) is the guardrail.** It asks the pre-pass predicate at the one
moment the answer is unambiguous: after the teardown, before any allocation
can mask it. The end-to-end spawn in sub-test 5 remains valuable as a
regression check on everything *else* about the seed path, but it is not what
detects a missing sweep, and this document says so rather than letting a
future reader assume otherwise.
