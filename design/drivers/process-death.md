# PaideiaOS — Process Death and the Cascade

**Status:** v1.0 — the trigger lands; one dependency named and left open
**Date:** 2026-08-16
**Issue:** #1583 (surfaced by R30.M9-002 / #1086)
**Code:** `src/kernel/core/driver/process_death.pdx`,
`src/kernel/core/int/fault_kill.pdx`,
`src/kernel/core/syscall/handlers/sys_exit.pdx` §step 2.6,
`src/kernel/core/driver/driver_table.pdx` §pid-generation,
`src/kernel/core/sched/task_pool.pdx` §`_pid_gen`
**Witness:** `tests/kernel/driver/death_witness.pdx` — `R31 DEATH CASCADE OK`
**Builds on:** R29 cascade restart (#1044/#1047/#1048),
`design/drivers/cascade-restart.md`

---

## 1. The gap this closes

R29 built a complete cascade-restart and capability-revocation mechanism.
`driver_restart_node` force-stops a driver through whitelisted FSM edges,
marks every endpoint bound to it dead and wakes the clients parked on them,
tears down its IOMMU domain, charges the restart against an intensity
budget, escalates when the budget is exhausted, and re-arms the survivor at
a fresh incarnation.

It had five call sites. All five were synthetic: the chaos harness and the
R29 boot witness. **No fault handler and no supervisor reached it.** A
driver process could die holding every capability it had ever been granted
and nothing would take them back.

The driver descriptor even carried a `pid` field, at `[+0]` bits `[63:32]`,
written by `driver_table_register` since R29.M2. Nothing read it.

### Why this is not a memory leak

A capability slot that outlives its owner is inherited by whatever process
next occupies it. The ACPI bubble holds `KIND_OP_REGION` windows and,
through them, reach into the embedded controller and the LPSS buses. **The
next process gets the EC.**

Leaked memory is recovered by reboot. Leaked authority is *exercised* before
anybody notices. The two failures are not in the same category and should
not be prioritised as if they were.

---

## 2. Two triggers, and which one matters

| Route | Where | Weight |
|---|---|---|
| Orderly exit | `sys_exit_body` step 2.6 | secondary |
| **Ring-3 fault** | `fault_ring3_death_check`, from vectors 0/6/13/14 | **primary** |

A process that calls `exit` has usually finished its work. It is the case
*least* likely to still be holding an OpRegion window, an I²C claim, or the
ACPI Global Lock. The process that faults mid-transaction is the one that
is.

Wiring only `sys_exit` would have produced a green test suite over a system
that still leaked authority in exactly the case where leaking it is
dangerous. That is why `int/fault_kill.pdx` exists as code rather than as a
comment saying the fault path is future work.

### 2.1 What the fault path had to become first

Before #1583 there was no fault path to hook. Every CPU exception in this
kernel ended in `exc_handle` → `klog_panic` → halt, with **no CPL
discrimination anywhere**: the only place `CS.RPL` was read was the KPTI
plumbing in `isr_trampoline.pdx`, and it used it to decide `swapgs` and the
CR3 flip, never policy. A `#GP` raised by a ring-3 process stopped the
machine.

For a microkernel that is the wrong answer twice over. It is wrong as
policy — a userspace fault is an ordinary event and the kernel is the part
that is supposed to survive it. It is wrong as *isolation*: a machine that
halts on a bubble crash has not contained the crash, it has been taken down
by it.

So `fault_ring3_death_check` is a new decision, and it is deliberately
conservative. It converts a fault into a task death only when **all four**
hold:

1. `CS.RPL == 3`. A ring-0 fault is a kernel-integrity failure and must
   still panic — continuing means running the rest of boot on an invariant
   already observed broken. The test masks RPL rather than comparing
   against a selector literal, so a future GDT rearrangement cannot silently
   invert it.
2. `_current_tcb != 0`. A fault before the scheduler exists has no task.
3. `pid > 1`. Killing init leaves nothing to schedule and nothing to reap
   the corpse. A panic names that; switching away from a dead init would
   hang with no diagnosis.
4. The task is not already `ZOMBIE`. A fault inside an already-dead task
   means the death path itself faulted, and re-entering would recurse. That
   one genuinely is a kernel bug.

Every declining answer runs the previous behaviour verbatim, which is why
this could be added to four live exception handlers without changing what
any of them does today.

### 2.2 Why the function returns instead of switching

`fault_ring3_death_check` revokes and marks the task `ZOMBIE`, then
**returns**. The handler does the four-call scheduling tail
(`runq_dequeue` → `sched_pick_next_r15` → `sched_switch_r15`), guarded by
the return value.

The split is what makes the fault path testable. A witness can build a trap
frame with a ring-3 CS, point `_current_tcb` at a task it owns, call this,
and assert on the part that matters — the row unbound, the endpoints dead,
the clients woken, the node re-armed, the corpse carrying a fault-shaped
exit status. What it cannot do is survive `sched_switch_r15`, and it does
not have to: that tail is byte-identical to `dispatch_exit`'s, which every
shell smoke mode runs on every `exit`.

Fusing the two would have left the interesting half witnessed only by a real
fault arriving at a real moment — the shape of an assertion never observed
failing.

---

## 3. A pid is not an identity

`pid_alloc` is a dense-low-first scan of `_pid_table[1..64]`, and `pid_free`
unconditionally writes zero into the slot. A reaped pid goes to the very
next `task_new`, immediately, with no aging and no "don't reuse the most
recent" heuristic. The codebase says so in its own comments —
`task_pool.pdx:302` ("slab must be fully zero before pid becomes reusable")
and the `#829` XSAVE scrub, which exists *because* pids recycle.

That is fine for a pid used as a transient handle and fatal for one used as
a **correlation key**. A driver row still naming pid 7 from a previous
occupant will match an unrelated new task handed pid 7, and the consequence
is not a missed revocation but a *wrong* one: **a live process's
capabilities torn down on the strength of a number collision.** That is
strictly worse than the leak being fixed, so it gets two independent
defences rather than one.

### 3.1 First line — the binding is invalidated when it stops being true

A binding is a property of a **life**, not of a slot. It is dropped:

- by `driver_death_notify`, **before** any teardown runs;
- by `driver_table_rearm_incarnation`, with the incarnation it named — the
  re-armed life has no process yet, and the supervisor binds the
  successor's pid when it spawns one;
- by `driver_table_unregister`, with the rest of the row.

So a stale binding is already a bug in the first line before the generation
is ever consulted.

### 3.2 Second line — the generation

`_pid_gen[p]` is a per-pid counter bumped by `task_new` at the moment the
slot acquires a new occupant, **before** the `_pid_table` publish. That
ordering is the invariant: a reader that resolves a pid and then reads its
generation can never straddle two incarnations.

It is never zero for a live task (first allocation yields 1), which is what
frees zero to serve as the driver row's *unbound* sentinel without colliding
with a real incarnation.

The driver row carries the low 16 bits at `[+0]` bits `[31:16]` — the field
that was "reserved, must be zero", where zero keeps a meaning.

### 3.3 Why the generation shares a u64 with the pid

The key is the pair. A key whose halves can be written separately is a key
that can be observed half-updated. Sharing one u64 makes bind and unbind
single stores, so there is no interval in which a row names a pid at
somebody else's generation. Every other mutator in `driver_table.pdx`
already preserves untouched header bytes through a mask-and-OR, so both
halves are carried or dropped together by construction.

The spare high 32 bits of `[+8]` were the alternative and were rejected for
exactly that reason.

---

## 4. Idempotence, and the assertion that nearly did not bite

Death, an explicit teardown and a supervisor sweep can all reach one row.
`driver_death_notify` unbinds **before** it calls `driver_restart_node`, so
the second arrival resolves nothing and returns `DRV_DEATH_NO_SLOT`.

With the unbind last — or absent — the second arrival would charge another
restart against the intensity budget, and five arrivals would latch
`perm_failed` on a node whose only fault was dying once.

**The testing trap here is worth recording, because the first version of the
witness fell into it.** Two mechanisms drop a binding: the notifier's
explicit unbind, and `rearm_incarnation` dropping the key with the
incarnation. Assertions that "the binding is gone after a death" are
satisfied by *either*, so deleting the unbind entirely left the witness
green. Two independent mechanisms is the right design and the wrong test.

The **escalation** path separates them. When the budget is exhausted,
`driver_restart_node` latches `perm_failed` and returns *without re-arming*
— escalation is the absence of a re-arm, not a new state. So on that death,
and only on that death, the re-arm cannot have dropped the key, and a
binding that is gone afterwards is gone because the notifier consumed it.
Sub-test P drives six deaths to reach that point; with the unbind removed it
fails at stage 17.

---

## 5. Residuals, named

**16-bit generation truncation.** The driver row carries the low 16 bits, so
aliasing needs 65536 reuses *of the same pid* between a bind and the death
that consumes it. This is second-line defence in any case: reaching it
requires the first line (§3.1) to have already failed. Widening it means
moving the key out of the header u64 and giving up the single-store
property of §3.3, which is a worse trade at this size.

**No SMP reservation on `pid_alloc`.** `pid_alloc` does not reserve the slot
it finds (`task_pool.pdx:100` says so), so under SMP two CPUs can be handed
the same pid. The generation counter inherits that race rather than fixing
it; the fix is the `LOCK CMPXCHG` reserve-on-find proposed in
`design/audit/entries/r15-m6-010-fork-multicore.md` §7/§8, and it belongs
there rather than here.

**Who binds.** `driver_death_bind` is the audited way to install a key, and
its intended caller is the supervisor at the moment it spawns a driver
process. There is no in-kernel supervisor yet, so today the callers are the
witness and the tests. That is a gap in *who binds*, not in whether death
fires: the trigger is installed in the IDT and in `sys_exit`, and it fires
on every ring-3 fault and every exit whether or not anything is bound.

**A genuine CPU-raised ring-3 fault reaching the handler.** The witness
drives `fault_ring3_death_check` with a synthetic frame. The handler wiring
that calls it is four vectors of six instructions each, and the scheduling
tail is `dispatch_exit`'s. What is not witnessed end-to-end is a real fault
arriving at a real handler and the machine continuing — which needs a
ring-3 excursion the boot sequence can return from, and the existing
one-shot `_ring3_witness_active` escape is already spent by `boot_r15_ring3`.

---

## 6. What death does NOT revoke, and why

`driver_death_notify` revokes exactly what the driver row **names**:

- the DMA domain at `[+32]`, through `driver_lifecycle_teardown`;
- every endpoint bound to the slot, through
  `driver_restart_reap_endpoints` — the ChannelDead cascade.

It does **not** revoke the dead process's `KIND_OP_REGION` (`0x150`),
`KIND_I2C_BUS` (`0x152`), `KIND_I2C_SLAVE` (`0x153`), `KIND_GPIO_LINE`
(`0x154`) or `KIND_FW_SESSION` (`0x155`) capabilities.

**Not because the cascades are missing — they all exist — but because there
is no relation to walk.**

- `cap_table` descriptors carry `(kind, rights, target_ptr)`. The struct
  declares `generation` and `flags`; nothing writes them. There is **no
  owner field**, and `cap_mint_write` takes no owner argument.
- There is one global `cap_table` and no per-task CSpaces.
  `loader/seed_caps.pdx:270` says so outright.
- Every cascade in the kernel keys on a **parent** identity — a cap slot
  (`opregion_cascade_revoke_by_parent`), a bus row
  (`i2c_slave_cascade_revoke_by_bus_row`), a controller id
  (`gpio_line_cascade_revoke_by_controller`) — never on a holder.
- The `driver_hint` fields on `kind_i2c_slave` and `kind_gpio_line` are
  stored at mint and read by nothing. They are reserved for the R31 binder.

So **"the capabilities held by process P" is not a representable query
today.** #1583's scope item 3 — a composed witness of one bubble death
revoking all five kinds — assumed it was. Writing that witness would have
required inventing the ownership relation in the same change that wires the
trigger, and inventing it badly (a side table that can drift from the rows
it describes is exactly what `design/drivers/cascade-restart.md` §2 argues
against for the supervision link).

**That is filed as #1587.** It is a different gap from the one
#1583 names: #1583's title and evidence are entirely about the missing
*trigger*, and the trigger is now real, fires on both routes, and is
witnessed. The ownership relation is a capability-layer design with its own
argument to make about where the relation lives — most plausibly by giving
the driver row a manifest of the **root** capabilities the driver was seeded
with, since all five kinds cascade from a root, and by populating
`driver_hint` with the driver slot for the two kinds that already reserve
the field.

---

## 7. Relationship to #1086 (ACPI bubble crash isolation)

`design/acpi/crash-isolation.md` names three properties.

| # | Property | Before | After |
|---|---|---|---|
| P1 | The kernel survives a ring-3 fault | witnessed (R29) | **strengthened** — it now survives by *killing the task*, not by halting |
| P2 | The dead bubble's capabilities are revoked | blocked, no trigger | **the trigger lands**; the DMA domain and every channel are revoked, the five ACPI kinds are not (§6) |
| P3 | The Global Lock is not stranded | `aml_glk_abandon` landed | unchanged; residual below |

### P3's residual is not closed

§4.4 of that document names it: a fault taken *inside* the Global Lock's
critical section, with no fault handler to run `aml_glk_abandon`.

This work is a **precondition** for closing it and not a substitute. The
lock's nesting bookkeeping lives in the dying process's address space, and
the kernel cannot execute there — a kernel-side death path can revoke
capabilities but cannot surrender a lock whose state it does not own. And
the lock word itself carries no owner identity: an Owned bit the successor
did not set is indistinguishable from firmware's own hold, and stealing a
lock firmware genuinely holds is worse than leaving ours stranded.

Closing it still needs what §4.4 specifies — **ownership evidence that
survives the process**: a journal page recording lock intent, held by a
capability the supervisor re-grants across restart, written before the
acquiring compare-exchange and cleared after the releasing one. What has
changed is that there is now a death path with somewhere to hang the
journal sweep; what has not changed is that the journal does not exist.

---

## 8. Summary

| Claim | Status | Evidence |
|---|---|---|
| A dying process reaches the cascade | ✅ | sub-tests E–J (fault), N (exit) |
| A ring-0 fault still panics | ✅ | sub-test C |
| A recycled pid does not revoke a live process | ✅ | sub-tests 4, M |
| A second revocation is a clean no-op | ✅ | sub-tests K, L, P, Q |
| The unbind is load-bearing independent of the re-arm | ✅ | sub-test P (escalation path) |
| All five ACPI kinds revoked on death | ❌ | no cap→owner relation exists (§6) |
| A real CPU ring-3 fault witnessed end-to-end | ❌ | §5 |
| Global Lock residual closed | ❌ | §7 — needs the journal |
