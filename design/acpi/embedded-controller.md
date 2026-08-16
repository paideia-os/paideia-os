# PaideiaOS — The Embedded Controller

**Status:** Ratified v1.0
**Date:** 2026-08-15
**Round:** R30.M7 (issues #1079, #1080, #1081)
**Owners:** acpi + drivers
**Enforcement:** `tools/verify-aml-parser.sh` (module compile, storage
confinement, signature pinning, EC-gate inversion) + the corpus in
`tests/user/aml/aml_harness.c`.

Supersedes the "R31 will do it" placeholder text in
`src/user/aml/aml_region.pdx` §THE EMBEDDED CONTROLLER GATE (#1065).

---

## 1. Why these three issues are one document

#1079 (the `EmbeddedControl` OpRegion handler), #1080 (`_Qxx` query
dispatch) and #1081 (transaction serialization + timeout) are three
descriptions of one mechanism, and the ordering constraint between them
runs the wrong way for sequential design:

- The serialization scheme (#1081) is the thing that decides whether the
  query path (#1080) is expressible at all.
- The query path is the *only* caller that re-enters the OpRegion handler
  (#1079) from inside a transaction episode.

A serialization scheme designed against #1079 alone is a plain mutex, and
a plain mutex makes #1080 deadlock. That deadlock is not an edge case: on
real hardware it is what happens the first time the lid is closed. So the
three land together, and §4 is the load-bearing section of this document.

---

## 2. What the EC is, and why it gets more care than the rest of R30

The Embedded Controller on the T14 G4 owns battery charging, thermal and
fan control, the lid switch, backlight enable, and keyboard/touchpad
power. Three properties separate it from everything R30 has touched so
far:

**It is not recoverable in software.** A stray write to the GPIO pad
controller sets a pin wrong and can be set back. A stray write to an
undocumented EC offset can change charge thresholds or fan curves that
persist across reboot, and the register space outside what firmware
declares is vendor-undocumented — there is no specification saying what
does not happen.

**It is actively shared with firmware.** SMM drives the EC behind the
OS's back at any time; that contention is what the ACPI Global Lock
exists for. This is the first device in this kernel with a second
concurrent master that the OS cannot schedule, mask or observe.

**It is slow and it can wedge.** Transactions take milliseconds. A wedged
EC that never sets `OBF` will hang an unbounded poll forever, in a path
that battery and thermal code call routinely.

Consequences, all discharged below: no simulation (§3), a bounded wait on
every handshake step (§5), refusal rather than clamping on every failure
(§6), and a Global Lock seam that a later issue can fill without
redesigning anything (§7).

---

## 3. Placement: userspace, and why the kernel cannot host this

`design/acpi/no-aml-in-kernel.md` forbids an AML interpreter in ring 0,
and `tools/lint-no-kernel-aml.sh` enforces it down to the token level.
The `_Qxx` path is AML method evaluation by definition — the query byte
*selects a control method* — so #1080 cannot be kernel code, and #1081
cannot be separated from #1080 (§1). The whole mechanism therefore lands
as `src/user/aml/aml_ec.pdx`, alongside the interpreter it re-enters.

This is not a workaround. It is the posture the guardrail exists to
produce: firmware bytecode that drives battery charging runs in ring 3,
holding only what the supervisor was minted with, and an EC transaction
gone wrong is a userspace refusal rather than a ring-0 fault.

**The division of labour, unchanged from R30.M4:**

| Concern | Where | Why there |
|---|---|---|
| SCI assertion, mask, clear, EOI | `src/kernel/core/acpi/sci_isr.pdx` | interrupt context; bounded |
| Deferral to a context that can block | `gpe_table.pdx` ring → `evt_stream.pdx` | §8 |
| EC register handshake, serialization, timeout | `src/user/aml/aml_ec.pdx` | §5 |
| `_Qxx` resolution and invocation | `src/user/aml/aml_ec.pdx` → `aml_eval_method` | AML |
| OpRegion bind, bounds, width | `src/user/aml/aml_region.pdx` | already there (#1062/#1065) |

Port access stays confined to `aml_region_port_in` / `aml_region_port_out`
— still the only two functions in the repository containing `in`/`out`,
still asserted by `tools/verify-aml-parser.sh`. `aml_ec.pdx` calls them;
it does not contain a port instruction.

---

## 4. THE REENTRANCY DECISION

This is the section to read if you read only one.

### 4.1 The hazard

`_Qxx` methods routinely read and write EC registers. That is what they
are *for*: `_Q80` on a lid event reads the lid state byte out of EC
space. So the query path is:

```
SCI fires, SCI_EVT set in the EC status byte
  -> driver issues QR_EC (0x84), reads query byte xx
  -> driver dispatches _Qxx
       -> _Qxx executes AML that touches the EC OpRegion
            -> back into the EC transaction path
```

If the transaction lock is held across the `_Qxx` dispatch, the last step
deadlocks against the lock the dispatch itself holds. If the lock is
simply dropped before dispatch, an unrelated transaction can interleave
with the query and both are corrupted — the EC has *one* outstanding
transaction and no arbitration of its own.

### 4.2 The decision: two claims at two granularities

The lock and the episode are **different objects with different
lifetimes**, and conflating them is the bug:

**THE TRANSACTION CLAIM (`xact_busy`)** covers exactly one register
handshake — command byte, address byte, data byte — and nothing else. It
is taken at the top of `aml_ec_xact`, released on *every* exit path
including every timeout, and is **never held across a call into the
interpreter**. Its scope is microseconds-to-milliseconds of polling, and
it has no reentrant case at all: nothing the handshake calls can re-enter
it.

**THE EPISODE CLAIM (`episode` / `episode_depth`)** covers a query from
the `QR_EC` that produced the byte to the return of the `_Qxx` it
selected. It is a *coarser and weaker* claim: it does not exclude
transactions, it **admits** them. That is its entire purpose.

The invariant that makes the query path work:

> When `_Qxx` runs, `xact_busy` is 0 and `episode` is non-zero.

The `QR_EC` transaction takes and releases `xact_busy` like any other
transaction, *before* the dispatch. The dispatch then happens with the
transaction claim free, so the `_Qxx` body's EC reads acquire it normally
and complete. The episode claim remains held throughout, which is what
records that a query is in flight.

### 4.3 Why `xact_busy` is still checked, given it cannot fire today

`aml_ec_xact` refuses with `AML_ERR_EC_REENTRANT` if `xact_busy` is
already set on entry. In a single-threaded interpreter that is currently
unreachable through any legitimate path — which is precisely why it is
worth asserting. It is the guard that catches:

- a future issue that "just adds a quick EC read" inside the handshake;
- a second thread in the supervisor;
- and, most likely, a later refactor that decides to hold the lock across
  the dispatch after all — the thing this section exists to prevent.

The corpus witnesses it by reaching into the synthetic EC's per-step hook
and issuing a nested `aml_ec_xact` from inside a handshake. It refuses,
it counts the refusal, and — the part that matters — the **outer
transaction still completes correctly**. A reentrancy guard that
poisoned the transaction it fired inside would be a worse bug than the
one it was guarding against.

### 4.4 Bounding the episode

`_Qxx` can legitimately touch the EC. It can also, on a misbehaving
platform, cause another query to be pumped. `episode_depth` is bounded at
`AML_EC_QUERY_MAX_DEPTH = 4`; beyond that the pump refuses with
`AML_ERR_EC_QUERY_DEPTH` rather than recursing. Four is not a tuning
constant — it is "deep enough that a genuine cascade of distinct events
completes, shallow enough that a self-triggering query is caught on its
first cycle rather than after the C stack is gone."

The evaluator's own fuel and frame budgets bound what happens *inside*
each `_Qxx`; this bounds how many can nest.

### 4.5 What this design does NOT claim

It does not make the EC safe against SMM. Between two of this driver's
transactions, SMM may run its own — including inside a `_Qxx` episode.
That is correct and deliberate (§7); the Global Lock is a per-transaction
claim in every OS that implements it, and holding it across a `_Qxx`
would starve firmware for milliseconds.

---

## 5. The transaction, and the timeout that is not optional

ACPI 6.5 §12.2. Two ports, both from the EC device's `_CRS` — **never
hardcoded**; 0x62/0x66 are conventional and wrong on machines that
relocate them. `aml_ec_attach(device_node, data_port, cmd_port)` binds
both plus the namespace scope; until it is called every transaction
refuses with `AML_ERR_EC_UNBOUND`.

Status byte bits used: `OBF` (0x01), `IBF` (0x02), `SCI_EVT` (0x20).

**Read (`RD_EC`, 0x80):** wait `IBF` clear → write command → wait `IBF`
clear → write address → wait `OBF` set → read data.

**Write (`WR_EC`, 0x81):** wait `IBF` clear → write command → wait `IBF`
clear → write address → wait `IBF` clear → write data → wait `IBF` clear.

**Query (`QR_EC`, 0x84):** wait `IBF` clear → write command → wait `OBF`
set → read query byte.

Every one of those waits is bounded by `AML_EC_POLL_MAX` iterations. The
bound is not decoration:

> A test suite in which the fake EC always answers proves nothing about
> the path that matters, because the failure being guarded is precisely
> the one where it does not.

So the synthetic EC carries two wedge modes — `AML_EC_WEDGE_IBF` (never
clears `IBF`) and `AML_EC_WEDGE_OBF` (never sets `OBF`) — and the corpus
asserts that each produces a **refusal with its own code**, that the
refusal is counted, and that `xact_busy` is clear afterwards so the next
transaction is unaffected. A timeout that left the claim held would turn
one wedged transaction into a permanently dead EC path.

`AML_ERR_EC_STATUS` is separate from both timeouts: it fires when the
handshake completes its wait but the status byte is inconsistent with the
step reached (`OBF` set with `IBF` still set — the EC did not consume our
address, so the byte in the output buffer is not our data). Returning
that byte would be fiction of exactly the kind §3 of the #1065 gate
refused to produce.

### 5.1 Burst mode is NOT implemented

`BE_EC` (0x82) / `BD_EC` (0x83) are defined and deliberately unused. The
reason is stated here rather than left unmentioned: **the EC exits burst
autonomously after roughly one millisecond of inactivity**, with no
notification. Code that enters burst and then assumes it is still in
burst is wrong in a way that appears only under load — the exact class of
bug that a corpus running at full speed against a synthetic EC would
never reproduce. Burst is a throughput optimisation for multi-byte
sequences; nothing in R30.M7 has a multi-byte sequence to optimise. If it
is added later it must come with a re-check of `BURST` before every step
that assumes it, and the synthetic EC must model the autonomous exit.

---

## 6. Refusal codes

Refuse, never clamp, never retry forever. Distinct codes for distinct
causes, continuing `aml_region.pdx`'s numbering (62, 65, 66, 67 taken):

| Code | Name | Cause |
|---|---|---|
| 68 | `AML_ERR_EC_UNBOUND` | no `aml_ec_attach` — ports and scope unknown |
| 69 | `AML_ERR_EC_TIMEOUT_IBF` | input buffer never drained |
| 70 | `AML_ERR_EC_TIMEOUT_OBF` | output buffer never filled |
| 71 | `AML_ERR_EC_STATUS` | status inconsistent with the step reached |
| 72 | `AML_ERR_EC_RANGE` | EC address outside the 256-byte space |
| 73 | `AML_ERR_EC_REENTRANT` | transaction inside a transaction (§4.3) |
| 74 | `AML_ERR_EC_QUERY_DEPTH` | query episodes nested past the bound |
| 75 | `AML_ERR_EC_BAD_OP` | not a read or a write |

Each has its own counter, because a latched error code is overwritten by
the next success and "did the refusal happen at all" must stay assertable
— the same device `aml_region_refusals` and `aml_region_ec_gated` already
use.

### 6.1 Range confinement

Three independent checks, none of which subsumes the others:

1. **Bind time**, unchanged from #1065: an `EmbeddedControl` region
   declaring more than 256 bytes is refused outright.
2. **Access time**, unchanged from #1062: `aml_region_bounds_ok`
   confines the offset to the region's declared length.
3. **Transaction time**, new: `aml_ec_xact` refuses an address ≥ 256 with
   `AML_ERR_EC_RANGE`.

(3) exists because it guards a different thing. (1) and (2) trust the
binding row; (3) is the last statement before a byte goes on the wire,
and an out-of-range EC write is the destructive case of §2.

**The address is not a caller-supplied base.** `aml_ec_xact(op, addr,
value)` takes an EC-space address that `aml_region` derived from the
binding row's own offset arithmetic — the same confined footing #1075/
#1076 put the GPIO pad path on. There is no base parameter and no
region parameter; `tools/verify-aml-parser.sh` pins the exact declared
signature, so a mutant that adds one fails the build rather than the
review.

Likewise `aml_ec_query_pump()` has **arity zero**. The namespace scope
`_Qxx` is resolved in comes from `aml_ec_attach`, not from the caller,
for the same reason: a caller-supplied scope would let a query dispatch
some *other* device's `_Q80`.

---

## 7. The Global Lock seam

The ACPI Global Lock lands in a later R30 issue. It is not implemented
here. What is implemented is the seam, in a form that cannot silently rot:

`aml_ec_glk_enter()` / `aml_ec_glk_leave()` bracket the **handshake**,
inside `xact_busy`, on every path including every timeout exit. Today
they only count. The corpus asserts

> `glk_enters == glk_leaves`  and  `glk_enters == transactions attempted`

after every fixture. That is a balance assertion, not a comment: an
implementation that acquires the real lock and leaks it on the timeout
path — the single most likely way to get the Global Lock wrong — fails a
test that already exists, written before the lock did.

**The seam is per-transaction by design, and the episode is deliberately
outside it.** §4.5 explains why: SMM may interleave between a `_Qxx`'s
transactions, and must be allowed to.

---

## 8. Deferral: the query is not polled from the SCI ISR

`SCI_ISR_ALLOWED` in `tools/build.sh` restricts the SCI ISR to bounded,
non-blocking callees. An EC transaction violates that by construction —
milliseconds of polling in interrupt context is a livelock, not a slow
path — and it could not be added to the allowlist honestly.

It does not need to be. The existing R30.M4 path already has the right
shape and the EC needs no new mechanism:

```
SCI -> sci_isr_body: mask, clear, strike, enqueue, EOI   (bounded)
    -> gpe_table.pdx ring
    -> acpi_evt_pump (task context)
    -> evt_stream.pdx: ACPI_EVT_SRC_GPE record to the subscriber
    -> supervisor drains, calls aml_ec_query_pump()       (may block)
    -> acpi_evt_ack -> gpe_ack re-enables the GPE
```

**No new ISR allowlist is added by this milestone**, because no new
interrupt-context code is added by this milestone. The three existing
lists (`SCI_ISR_ALLOWED`, `DW_ISR_ALLOWED`, `GPIO_ISR_ALLOWED`) stay as
they are, separate as they are.

The kernel→userspace transport for `ACPI_EVT_SRC_GPE` records is still
unwired (the supervisor is a stub; see the map in
`design/kernel/r30-m4-sci-gpe-path.md`). That gap is not widened here:
`aml_ec_query_pump` is written to be called from the drain loop, and the
corpus calls it exactly where the drain loop will.

---

## 9. Query zero is not a query

`QR_EC` returning `0` means **no query pending**. Dispatching `_Q00` for
it is a real bug that appears in naive implementations: it invokes a
method the firmware may well have defined for something else, on an event
that did not happen.

`aml_ec_query_pump` returns three distinct outcomes, and the difference
between the first two is the point:

| Return | Meaning |
|---|---|
| 0 | `QR_EC` returned 0 — nothing pending, `queries_zero` incremented, **no method invoked** |
| 1 | a `_Qxx` was resolved and invoked |
| 2 | a non-zero query byte arrived but the table defines no matching `_Qxx` |
| `AML_EC_XACT_FAIL` | the `QR_EC` transaction itself was refused |

Outcome 2 is counted, not latched as an error: firmware is not obliged to
define every `_Qxx`, and treating a missing method as a fault would make
a normal machine look broken. Outcome 0 is counted separately from 2 for
the same reason a wedged subscriber is counted separately from an absent
one in `evt_stream.pdx` — they have different fixes.

The corpus witnesses the `_Q00` case directly: the fixture **defines**
`_Q00` with a body that increments an observable, the synthetic EC is
made to return query byte 0, and the assertion is that the observable did
not move.

### 9.1 Name construction

`_Qxx` is a 4-character NameSeg: `_`, `Q`, then the query byte as two
**uppercase** hex digits. It is resolved **exactly, in the EC device's
scope** — not by the §5.3 upward search rule. That distinction matters:
the search rule would happily find some ancestor's `_Q80` when this EC
does not define one, and run the wrong device's handler. The new
`aml_eval_find_in_scope(scope, seg)` in `aml_eval.pdx` is the exact-match
form; it lives there because `aml_path_buf` is confined to `aml_eval.o`.

---

## 10. Opening the #1065 gate, mechanically

#1065 made "the EC transaction is gated" a build-time fact:
`tools/verify-aml-parser.sh` asserted that **no object** relocates
against `aml_region_ec_backing_set`, and the corpus pinned
`aml_region_ec_hw_committed()` at 0. Its own comment said R31 must update
both, and that leaving the gate shut after the driver landed would be as
much of a defect as opening it early.

This milestone does exactly that, and keeps the check as strong:

- the "no caller" assertion becomes "**exactly one** caller, and it is
  `aml_ec.o`" — so the gate still cannot be opened from anywhere else;
- the `hw_committed == 0` pin becomes an assertion that the count tracks
  transactions actually performed;
- `aml_ec_state` and the synthetic-EC storage join the confinement list,
  for the reason `aml_region_ec_state` is on it: a second writer could
  open the gate, or forge a transaction count, without the driver.

The gated path itself is **not deleted**. With no backing registered the
handler still refuses with `AML_ERR_REGION_EC_GATED` before spending fuel
— which is what a supervisor that never calls `aml_ec_attach` still gets,
and what the existing #1065 assertions continue to prove.

---

## 11. What is deliberately not here

| Not implemented | Why | Where it goes |
|---|---|---|
| ACPI Global Lock | later R30 issue; seam is §7 | that issue |
| Burst mode | §5.1 | if ever, with the autonomous-exit model |
| `_REG` notification to the table | needs the supervisor's session plumbing | with the transport |
| EC ports discovered from `_CRS` | `aml_resource.pdx` decodes them; nothing wires the decode to `aml_ec_attach` yet | the supervisor, with the transport |
| kernel→userspace event transport | pre-existing gap (§8) | `design/kernel/r30-m4-sci-gpe-path.md` |
| A boot fingerprint | this milestone adds no kernel code, so no mode can reach it; the corpus is the witness and it runs in the pre-push matrix | n/a |

The last row is deliberate. `tools/verify-fingerprint-coverage.sh` now
fails the build on any emitted-but-unasserted marker, and the honest way
to satisfy it here is to emit none: the assertions this milestone needs —
fault injection, reentrancy, a wedged device — are ones a QEMU boot
cannot make, and `tools/verify-aml-parser.sh` is a first-class member of
the pre-push matrix.

---

## 12. Cross-references

- `design/acpi/no-aml-in-kernel.md` — why this is userspace.
- `design/kernel/r30-m4-sci-gpe-path.md` — the deferral path of §8.
- `design/acpi/acpica-bubble.md` — the capability membrane.
- `src/user/aml/aml_region.pdx` §THE EMBEDDED CONTROLLER GATE — the
  contract this opens.
- `src/user/aml/aml_ec.pdx` — the implementation.
- `tests/user/aml/aml_harness.c` — the witnesses.
