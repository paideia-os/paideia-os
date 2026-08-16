# PaideiaOS — ACPI Bubble Crash Isolation

**Status:** v1.0 — one of three properties implemented; the other two specified and blocked
**Date:** 2026-08-16
**Issue:** R30.M9-002 (#1086)
**Code:** `src/user/aml/aml_glk.pdx` (`aml_glk_abandon`), `tests/user/aml/aml_harness.c`
**Builds on:** R29 cascade restart (#1044/#1047/#1048), `design/drivers/cascade-restart.md`

---

## 1. What "isolation" has to mean here

The acpi_supervisor is a userspace process. A fault inside it is ordinary,
and "the kernel did not crash" is a very low bar — it is the bar a
microkernel clears by construction, not an achievement to witness.

The properties that actually matter are the ones where a dead bubble can
still do harm *after* it is dead. There are three, in increasing order of
how easy they are to get wrong:

| # | Property | Status |
|---|---|---|
| **P1** | The kernel survives a ring-3 fault, observably | **Already witnessed** — R29 (§2) |
| **P2** | The dead bubble's capabilities are revoked | **Blocked** — mechanism exists, trigger does not (§3) |
| **P3** | A bubble that dies mid-transaction does not strand the Global Lock | **Implemented and tested** (§4) |

This document is honest about which is which. P3 is the one landed by this
issue; P2 is specified here and blocked on a gap named in §3.4.

---

## 2. P1 — the kernel survives

Witnessed already, and not re-witnessed here. `kernel_main.pdx`'s
`r29_cascade_restart_witness` runs 40 sub-tests over a four-node
supervision tree, kills a node, and asserts the system afterwards —
fingerprint `R29 CASCADE RESTART OK`, pinned in
`tests/r17/shell-shutdown.golden`.

Its sharpest assertions are #25 and #26: `sys_ipc_recv_body` and
`sys_ipc_send_body` return `-ECONNRESET` (`0xFFFFFFFFFFFFFF98`) to a
client of the dead node **and return at all** — a returning call *is* the
no-hang proof.

Adding a second witness that killed a process and checked the kernel was
still up would restate this in different words. The R29 chaos harness
(`src/kernel/core/driver/chaos.pdx`, 100 kills per tree shape, under load)
already runs in the default smoke matrix.

---

## 3. P2 — a dead bubble must not leak authority

### 3.1 Why this is about authority, not memory

A crashed bubble that leaves its capabilities live has leaked
**authority**. The bubble holds `KIND_OP_REGION` windows and, through
them, reach into the embedded controller and the LPSS buses. A capability
slot that outlives its owner is inherited by whatever process next
occupies it — which is to say the next process gets the EC.

That is categorically worse than leaking memory. Leaked memory is
recovered by reboot; leaked authority is *exercised* before anybody
notices.

### 3.2 The kinds in question

| Kind | Value | Cascade function | Transitive? |
|---|---|---|---|
| `KIND_OP_REGION` | `0x150` | `opregion_cascade_revoke_by_parent` | **Yes** — fixed point |
| `KIND_I2C_BUS` | `0x152` | — (parent of the below) | |
| `KIND_I2C_SLAVE` | `0x153` | `i2c_slave_cascade_revoke_by_bus_row` | No (leaf kind) |
| `KIND_GPIO_LINE` | `0x154` | `gpio_line_cascade_revoke_by_controller` | No (leaf kind) |
| `KIND_FW_SESSION` | `0x155` | `fw_session_cap_revoke` | n/a (single slot) |

Two corrections to the issue's framing, recorded so they are not
re-introduced:

- **`KIND_AML_SESSION` does not exist.** It was renamed `KIND_FW_SESSION`
  by #1569 *before any code was written*, because
  `tools/lint-no-kernel-aml.sh` refuses any identifier beginning `aml`
  under `src/kernel/**` — the Pillar 3 guardrail keeping a bytecode
  interpreter out of ring 0.
- **`KIND_EC_*` does not exist yet.** `KIND_EC_QUERY` is a *planned* R31
  kind. There is nothing to revoke on death today, and a test asserting
  its revocation would be asserting against a kind that has never been
  minted.

Only `KIND_OP_REGION` is transitive, because a window can be derived from
a window. It is implemented as an **iterated fixed point, deliberately not
recursion** — a hostile derivation chain would otherwise put an
unbounded-depth call chain on a teardown path.

### 3.3 The ghost-row sweep is the pattern to follow

`gpio_line_cascade_revoke_by_controller` proves rather than assumes, in
two phases:

- **Phase 1 — by descriptor.** Scan the 256 `cap_table` descriptors for
  the kind, resolve each to its row, revoke through the audited path.
- **Phase 2 — by row.** Ignore descriptors entirely; scan all 32 rows and
  free any still-live row naming this controller.

Phase 2 is not redundancy. A descriptor cleared by any other path would
strand its row forever, and a stranded GPIO row still holds a **pin** on a
controller that no longer exists — so the next legitimate mint of that pin
is refused `IN_USE` by a ghost. On a GPIO line the pin may be the only way
to bring a device out of reset, so a leaked row can make a device
permanently unusable until reboot.

The corresponding test (`tests/kernel/cap/gpio_cap_synth.pdx` sub-test L)
**manufactures a ghost row no API can produce** — mints a slot, then zeroes
its descriptor by hand — and asserts phase 2 collects it. That is the
standard any P2 witness should meet.

### 3.4 Why P2 is not closed by this issue

**The revocation mechanism is complete. Nothing triggers it on process
death.**

- `sys_exit` (`src/kernel/core/syscall/handlers/sys_exit.pdx`) sets
  `STATE_ZOMBIE`, writes `exit_status`, wakes a waiting parent, and
  reparents orphans. **It revokes no capabilities and calls nothing in
  `driver/`.**
- `driver_restart_node` has five call sites, **all synthetic** — the chaos
  harness and the boot witness. No fault handler and no supervisor process
  reaches it.
- The driver descriptor carries a `pid`, but **no code reads it** to
  correlate a dying task with a driver slot.

So today a bubble crash revokes nothing, and a composed "bubble death
revokes all five kinds" witness would be asserting against a path that
cannot be entered. Writing one would produce a green test for a property
the system does not have — the worst possible outcome.

**Filed as its own issue** (number in the commit message): wire process
death to the cascade machinery — `sys_exit` and the fault path resolve the
dying task to its driver slot and call `driver_restart_node`. P2's witness
follows immediately after, and should be modelled on the ghost-row sweep
in §3.3.

---

## 4. P3 — the Global Lock must not be stranded

### 4.1 The hazard

The ACPI Global Lock arbitrates access to shared resources — the embedded
controller among them — between the OS and firmware. Its state word lives
at **FACS + 0x10, in firmware-owned memory**. It is not ours to abandon
silently.

If the bubble faults while holding it, the Owned bit stays set and
firmware waits for a release that never comes. On the T14 G4 target the
firmware side owns thermal response. **A stranded Global Lock is therefore
not a hung process; it is a machine that has stopped managing its own
temperature.**

This is the property most worth designing for, and it is the one this
issue implements.

### 4.2 What death-while-holding does: `aml_glk_abandon`

`aml_glk_abandon()` surrenders the lock at **every nesting level in one
operation**. It is deliberately *not* a loop over `aml_glk_leave`, and the
three differences are the design:

1. **Depth 0 is not an error.** `aml_glk_leave` answers depth 0 with
   `AML_ERR_GLK_UNDERFLOW`, because a release with nothing outstanding
   means a caller's bracketing is broken. On a death path, "we were not
   holding it" is the **ordinary** case — most deaths do not happen inside
   the critical section. If abandon latched a refusal on every clean
   shutdown, an operator would learn to ignore this code, and then ignore
   the one that mattered.

2. **One hardware release, not N.** Nesting depth is *our* bookkeeping;
   the hardware lock is held once however deeply we nested. Looping the
   hardware arm would, from its second pass, release a lock we no longer
   held — exactly what the underflow refusal exists to catch.

3. **It keeps the balance identities true.** The hardware release is
   counted, and the surrendered inner levels are credited to nested
   leaves. So after an abandon:

   ```
   hw_acquires  == hw_releases        (the lock is not stranded)
   nested_enters == nested_leaves     (the nesting was accounted for)
   ```

   This is what makes "not stranded" an **assertion** rather than an
   inspection. An abandon that forgot to account would leave the identity
   broken in precisely the way a real leak does — so the identity remains
   a usable leak detector *after* the death path has run, which is when
   you most want one.

The doorbell is rung iff the replaced value carried Pending, for the same
reason `aml_glk_leave` rings it: omitting it breaks nothing locally and
leaves firmware asleep forever. **Abandoning without ringing is
indistinguishable from not releasing at all, and quieter** — which is why
the fixture asserts both directions.

The release loop itself is a byte-for-byte structural mirror of
`aml_glk_leave`'s hardware arm — same `§5.2.10.1` clear, same unconditional
`aml_glk_smm_step` injection point inside the compare-exchange, same
1024-retry bound. A second, subtly different release loop is exactly how
two release paths drift apart.

### 4.3 What is witnessed

Six fixtures in `tests/user/aml/aml_harness.c`, run last in the Global
Lock block because the first one deliberately leaves the lock held:

- **The hazard itself, before it is answered.** Take the lock, issue no
  leave, and assert the stranded state *exists*: Owned set, depth
  non-zero, hardware counts unbalanced. A test that only showed abandon
  working would leave open whether there was anything to fix.
- Abandon surrenders every nesting level with **one** hardware release,
  and both balance identities hold afterwards.
- Abandon while holding nothing is silent — no error, no underflow counted
  — with `aml_glk_leave`'s contrasting refusal asserted in the same
  fixture so the difference is on one screen.
- Abandon is **idempotent**: a fault handler and a supervisor sweep can
  both reach a dying process, and the second abandon must not release a
  lock somebody else may by then hold.
- The doorbell rings when firmware is Pending, and does **not** ring when
  nobody waits.

One arm is **not** tested and the gap is recorded rather than hidden: the
unbound refusal. The FACS binding deliberately survives `aml_glk_reset`
and there is no detach, so "nothing is bound" is a one-shot observation
already spent by `test_ec_refuses_before_it_is_attached`.

### 4.4 The open half: who calls abandon

The mechanism is here. **The death-time trigger is not**, and it is
blocked on the same gap as P2 (§3.4).

The intended callers, in order of preference:

1. **The bubble's own fault handler**, before it dies. This is the only
   party that can run code in the dying address space, which is where the
   lock state lives. It requires userspace fault delivery, which does not
   exist.
2. **The supervisor**, via a teardown IPC before reaping. This cannot work
   for a *faulted* bubble — the supervisor cannot execute in the dead
   process's address space — but it does work for an orderly stop, which
   is the common case.

**The residual risk, named.** A fault taken *inside* the critical section,
with no fault handler, strands the lock and nothing in this design
recovers it. The successor incarnation cannot safely reclaim, because the
lock word carries no owner identity: an Owned bit it did not set is
indistinguishable from firmware's own hold, and stealing a lock firmware
genuinely holds is worse than leaving ours stranded.

Closing that residual needs **ownership evidence that survives the
process** — a journal page recording lock intent, held by a capability the
supervisor re-grants across restart, written before the acquiring
compare-exchange and cleared after the releasing one. A successor finding
a journal entry from a prior incarnation, with the word still Owned, would
then know the Owned bit is *ours* and may force-release it. Firmware's own
holds never appear in our journal, so the inference is sound.

That is specified here and not implemented: it needs surviving storage
that the restart path does not yet provide. The narrower mitigation
available today is structural and worth stating — **keep the critical
section short, bounded, and free of anything that can fault** — which is
already the shape of `aml_ec_xact`.

---

## 5. Summary

| Property | Landed | Where |
|---|---|---|
| P1 kernel survives | ✅ pre-existing | R29 witness, `R29 CASCADE RESTART OK` |
| P2 caps revoked on death | ❌ blocked | mechanism complete; no trigger (§3.4) |
| P3 Global Lock not stranded | ✅ this issue | `aml_glk_abandon` + 6 fixtures (§4) |
| P3 residual (fault inside the section) | ❌ specified | journal design (§4.4) |
