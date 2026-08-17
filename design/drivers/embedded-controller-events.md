# Embedded-controller platform events: meaning, priority, and loss

**Round.** R31 — Embedded Controller + platform sensors + thermal + battery + backlight
**Sub-milestone.** R31.M1
**Issues.** #1092 (R31.M1-004, AC-adapter presence), #1093 (R31.M1-005, lid + power button + hot-keys)

**Code.**

| file | what it holds |
| --- | --- |
| `src/kernel/core/acpi/ec_event.pdx` | the byte→class meaning table, per-class accounting, the admission rule |
| `src/kernel/core/acpi/ec_route.pdx` | the router, extended to classify, admit and count per class |
| `src/kernel/core/acpi/evt_stream.pdx` | the stream; `a2` of a source-3 record now carries the class |
| `src/kernel/core/cap/kind_ec_query.pdx` | `ec_query_row_class` and op 6, the ring-3-reachable classification query |
| `tests/kernel/cap/ec_query_synth.pdx` | stages D and E, `R31 EC EVENT CLASS OK` / `R31 EC EVENT SHED OK` |

---

## §0 `power_policy_channel` does not exist

#1092's deliverable reads *"AC insertion/removal event → `power_policy_channel`"*.
That name was looked for before anything was designed. It occurs **exactly
once** in this repository:

```
design/roadmap/next-wave-softarch.md:140:
  `power_policy_channel : Channel(PowerPolicySchema)` — bidirectional; …
```

A name in a sentence. No code, no schema, no kind, no caller, no test. It is
the same shape `acpi_event_channel` had one iteration ago, when #1091 went
looking for it and found a roadmap line.

**Decision: no second channel was created.** AC, lid, power-button and hot-key
events all travel the path #1091 built — `ec_route_query` → `acpi_evt_offer`
with `ACPI_EVT_SRC_EC_QUERY` — and this iteration supplies the thing that path
was missing, which is *meaning*.

The reason is specific rather than aesthetic. The stream's accounting identity

```
offered == drained + depth + drops + unrouted
```

is what makes a lost platform event *localisable*: a subscriber reading records
whose sequence jumps from 40 to 43 knows two events were lost **between those
two**. A second channel carrying a subset of the same events would hand an
operator two incomplete sequences with no way to interleave them, and the
property that survives is worth more than the tidiness of a dedicated name.
#1091 added the stream's third source precisely because the R30.M4 design
anticipated extension; taking that invitation is cheaper and more honest than
declining it.

---

## §1 What reads these events: **nothing**

These issues route events *to* somewhere. The question of what reads them was
asked directly, and the answer is stated here in full rather than left to be
discovered.

* **No ring-3 program binds a `KIND_ACPI_EVENT` endpoint.** Every call site of
  `acpi_evt_bind` is in a boot witness. Nothing under `src/user/` references any
  `acpi_evt_*` symbol at all.
* **There is no `DRAIN` op and no `ACK` op on `KIND_ACPI_EVENT`**, by design
  rather than omission: a record is 64 bytes and a three-register capability
  invocation cannot copy one out without taking a destination pointer, which is
  the aliasing the `_acpi_evt_ring` confinement assertion exists to prevent
  (`design/kernel/r30-m4-sci-gpe-path.md` §11.6).
* **There is no power policy, no lid handler, no battery monitor and no
  platform shutdown consumer** anywhere under `src/user/`.
  `src/user/acpi_supervisor.pdx` handles four enumeration ops and replies with
  zero-filled stubs. `init_shutdown` in `src/user/init.pdx` is a process-reaping
  loop with no relationship to platform power.
* **`aml_ec_query_pump`** — the ring-3 half that would *call* `ec_route_query` —
  **has no caller in `src/` either.** Its only callers are in the C harness.
* Because `sci_arm.pdx` gates the SCI unmask on `acpi_evt_ready()`, in a real
  boot the interrupt is never unmasked. The stream is not merely undrained; it
  is never fed.

**Therefore: the consumer of everything in this iteration is a boot witness,
and pressing the power button still does not shut this machine down.**

That is recorded as the status, not smoothed over. The two fingerprints assert
what actually happens — a classified record lands in a kernel ring, the shed
rule holds under a burst, a loss is counted against its class — and assert
nothing about delivery to a policy layer, because there is no policy layer to
deliver to. A witness that dressed the kernel talking to itself up as delivery
is the failure #1590 had to unwind for three already-closed issues.

### What was nevertheless not-nothing

Before this iteration a decoded query byte had **no meaning anywhere in the
system**. Nothing in the tree could say that `0x2B` is a lid transition and
`0x20` is the power button, so "route AC insertion to power policy" was not
merely unimplemented — it was *inexpressible*. After it, the meaning exists, is
authority-gated, is monotone, is carried in the record, and is reachable from
ring 3 through the one door that exists.

### The one surface a ring-3 consumer can reach today

`EC_QUERY_OP_QUERY_CLASS` (op 6 on `KIND_EC_QUERY`, `RIGHT_OBSERVE`). A holder
asks "what does byte *q* mean on the controller my subscription names" and gets
a class. It reads the controller **from its own row** and takes no address, so
it cannot be used as an oracle over a controller the holder has no subscription
to. It exists because there is no `DRAIN` op: the class in a record's `a2` is
unreadable from userspace, so a holder that wants to know whether a byte is the
power button has to ask.

Op 6 is `OBSERVE` and deliberately not `INVOKE`. Op 3 (`QUERY_WANTS`) is
`INVOKE` because it reveals which events *the holder* is watching for — a
statement about the holder's behaviour. A class is a statement about the
**platform**: the same answer for every holder, so it belongs with the metadata
reads.

---

## §2 The map is installed, not compiled in

There is no correct table of query-byte meanings that could be written into the
kernel. `_Qxx` numbering is chosen by each vendor's firmware: what a method
*does* is the AML body of `_Q2B`, and the only way to learn that `0x2B` is the
lid is to see that its body notifies the lid device. That is bytecode
evaluation, and `design/acpi/no-aml-in-kernel.md` forbids it in ring 0 down to
the token level.

So the kernel holds a table of small integers and never learns them by itself.
`ec_event_map_set(query_byte, class)` is the installer and its intended caller
is the ring-3 supervisor that already evaluates the controller's methods.
Hardcoding the T14 G4's numbering would have produced a kernel that silently
misreads every other laptop, which is worse than one that admits it does not
know.

The numbers in the witness (`0x20` power, `0x2B` lid, `0x30`/`0x31` AC,
`0x60`–`0x63` hot-keys) are **the fixture's, not the platform's**, and the
witness says so at the point of use.

---

## §3 The map starts empty, only fills, and a filled entry cannot change

The notify bitmap in `kind_ec_query.pdx` starts **full** and only ever narrows.
This table is its mirror image: it starts **empty** and only ever fills, and an
entry that has a meaning cannot acquire a different one while the map is bound.

| request | result |
| --- | --- |
| unset byte → class *C* | installed, `installed` += 1 |
| byte holding *C* → *C* | `EC_EVT_OK`, idempotent, `installed` unchanged |
| byte holding *C* → *D* | **`EC_EVT_MAP_ALREADY`**, `refused` += 1 |
| byte 0 → anything | `EC_EVT_MAP_BAD_BYTE` |
| class > `EC_EVT_CLASS_MAX` | `EC_EVT_MAP_BAD_CLASS` |
| any, while unbound | `EC_EVT_MAP_UNBOUND` |

**Why this is the most important invariant in the file.** Every downstream
decision is taken from the class — whether the event may be shed under
pressure, which counter a loss lands in, what a subscriber does when it
arrives. A byte that means `POWER` at boot and `HOTKEY` an hour later
reclassifies a power-button press as a droppable Fn key, and there is no
symptom until somebody's machine will not turn off.

Byte 0 is **refused a meaning** rather than ignored. `QR_EC` returning 0 means
no query is pending; `ec_route_query` refuses to route it and
`design/acpi/embedded-controller.md` §9 refuses to dispatch it. An entry for it
could only be read by a caller that had already broken two other contracts, and
admitting it would make this the one place in the path that treats "nothing
happened" as an event with semantics.

Monotonicity is claimed **within a binding**. `ec_event_reset` (boot/teardown)
and `ec_event_map_unbind` clear wholesale; neither is a per-entry operation.
`tools/build.sh` greps for the absence of the natural names a per-entry demotion
primitive would be given, the same way it greps for a widening primitive on the
notify bitmap.

---

## §4 One map, one controller, and the assumption is *enforced*

The table is 256 entries keyed by query byte, not 65536 keyed by (controller,
byte). The T14 G4 has one embedded controller.

A single-controller assumption left implicit is exactly how a second controller
silently inherits the first one's meanings. So:

* the map is **bound** to one controller address;
* the address is **inherited** from a `KIND_OP_REGION` capability over the
  EmbeddedControl space, via the same gate (`ec_query_check_region_ec`) the
  subscription mint uses — reused verbatim rather than reimplemented, because a
  second weaker definition of "a legitimate embedded-controller region" is the
  drift that makes two gates disagree;
* `ec_event_map_bind` has **arity one**, for the reason `ec_access_bind` takes
  no base and no length: an argued address would attach one machine's event
  meanings to a controller the capability never named;
* `ec_event_class_of` returns `EC_EVT_CLASS_NONE` for any other address **and
  counts it** in `foreign`.

A second controller therefore gets **no meanings rather than the wrong ones**,
which fails toward "unclassified" instead of "misclassified", and the counter
says which happened.

`ec_event_map_unbind` clears the map as well as the binding. This differs
deliberately from `acpi_evt_unbind`, which keeps its state: there the state is
counters, and discarding drop totals at teardown erases evidence just as
somebody starts looking for it — so the counters survive here too. But the map
is not evidence, it is a set of assertions true only of one controller, and
leaving it populated across a rebind would reintroduce §4's failure through the
back door.

---

## §5 Representation: one entry per qword

A class fits in three bits and eight would fit per qword. They are unpacked,
for two reasons.

1. **Packing makes installing one byte a read-modify-write over seven
   neighbours.** On a table where one neighbour is the power button and another
   is a hot-key, a mask bug does not corrupt the entry being written — it
   corrupts a *different event's meaning*, which is the class of bug §3 exists
   to prevent and the hardest kind to see.
2. **The mnemonic table has no variable-count shift** (see
   `ec_query_row_wants`, which walks a 6-bit count one bit at a time and says
   why). Packed access would need two of those bounded loops per lookup on the
   routing path.

Unpacked, an index is `byte << 3` and an entry is a whole qword nothing else
shares. Two kilobytes of `.bss`.

---

## §6 Event loss, answered explicitly

The `QR_EC` mechanism has no replay. The controller signals, the OS asks, the
controller answers with one query byte, and if that byte is not drained the
event is simply gone. So the three questions are answered rather than assumed.

### Can the path drop an event?

**Yes, in three distinct ways, each with its own code and its own counter.**

| # | cause | router | per class | code |
| --- | --- | --- | --- | --- |
| 1 | the stream was full (tail-drop at depth 32) | `refused` | `lost` | routed count 0 |
| 2 | nobody bound, or no subscription wanted the byte | `unrouted` / `filtered` | — | routed count 0 |
| 3 | the admission rule shed it (§7) | — | `shed` | **`EC_ROUTE_SHED`** |

Case 2 is not a loss anybody asked for. Case 1 is backpressure. Case 3 is the
only one in which **this kernel** is what discarded an event the machine really
produced, and it therefore returns a distinct code rather than a routed count of
zero: a shed event and an unwanted one must never be the same observation.

### What happens when the destination is full or absent?

The offer is refused, the **offer number is still consumed**, and the record
never exists. Refusal is the whole of it: nothing blocks, nothing retries, no
old record is overwritten. Tail-drop keeps the old records and refuses the new
one, because overwrite-oldest would turn bounded loss into reordering and erase
the first report of the condition that caused the overrun.

`acpi_evt_offer` never blocks, which is what lets the routing path be driven
from anywhere without inheriting a scheduling dependency.

### Is a dropped event detectable?

**Yes, and per class, which is the point.** The stream's own `drops` counter
says "some platform event was lost". That is not enough: a lost hot-key is a
keystroke and a lost power-button press is an unclean shutdown, and an aggregate
cannot tell them apart.

```
ec_event_stat(EC_EVT_CLASS_POWER, EC_EVT_CT_LOST)
```

can, and the witness asserts it moves (stage E4). **Nothing on the power-button
path is dropped silently.** The four counters per class are `seen` (queries),
`delivered` (records — two subscriptions to one controller make this advance by
two on one `seen`), `lost`, `shed`.

`_ec_route_state[8]` additionally retains `last_class`: what the router thought
the last query *meant*. That is the first question anybody asks when the power
button does nothing, and a wrong answer there points at the meaning table while
a right one points at the consumer — entirely different investigations.

### `NEEDS_ACK` was used rather than reinvented

`acpi_evt_offer` carries `ACPI_EVT_REC_F_NEEDS_ACK` in a `flags` field of its
own, so that *what the subscriber owes* is separate from *where the event came
from*. An EC query is **not** an acknowledging source: the GPE that woke the
machine was already acknowledged by the GPE record that carried it, and
acknowledging a query would re-enable a hardware bit nobody masked. So `flags`
stays 0 for source 3, and no parallel notion of delivery guarantee was
introduced.

### The one gap stated rather than closed

The ring-3 pump that would call the router does not exist (§1), so a query lost
**before** `ec_route_query` — because nobody issued `QR_EC` at all — is
invisible to all of the above and would have to be counted in the pump.

---

## §7 The priority inversion this milestone would otherwise have shipped

Fn keys arrive as **bursts**. One press of a brightness key can produce several
`_Qxx` queries in rapid succession, and holding it produces a stream of them.
Everything else on this path is a singleton: the lid closes once, the adapter is
pulled once, the power button is pressed once.

The stream is 32 deep, shared with GPE and firmware-notification traffic, and
tail-drop. Compose those two facts:

> **A long enough hot-key burst fills the stream, and the next record refused is
> whatever arrives next — including the power button.**

The least important event on the path evicts the most important one, and it does
so through a *correctly implemented* ring. Holding the brightness key and then
pressing power would be the reproduction.

### The rule

A `HOTKEY`-class query is refused admission once the stream's depth reaches
`EC_EVT_HOTKEY_WATERMARK` = **24 of 32**, leaving eight slots a hot-key burst
cannot consume. AC, lid and power-button events are never shed and may use the
whole ring.

**Why 24, and why a watermark rather than a quota:**

* **Eight reserved is more than the non-sheddable classes can simultaneously
  need.** There are three of them, the controller answers one query at a time,
  and a machine with more than eight un-drained lid-and-power events has a
  wedged consumer rather than a backlog.
* **A watermark needs only `acpi_evt_depth`.** A per-class quota would have to
  be decremented when a record is drained, coupling this rule to
  `acpi_evt_pop` — a function that deliberately knows nothing about classes and
  that in a real boot nothing calls.
* **Shedding is not coalescing, and this module does not coalesce.** Collapsing
  repeated hot-keys would mean scanning the pending records, i.e. reaching into
  `_acpi_evt_ring` from outside the one object allowed to relocate against it.
  Dropping a hot-key that arrives past the watermark, **and counting it**, is a
  worse user experience and a much better boundary, and the count is what tells
  an operator to repair the consumer rather than the ring.

### The sheddable set is an enumeration of one, not a range

`ec_event_admit` tests `class != EC_EVT_CLASS_HOTKEY`, not `class <
EC_EVT_CLASS_HOTKEY`. Today those select the same set, because the class domain
is exactly 0..4 and `HOTKEY` is its maximum — which is exactly why a reader
reaches for the range compare, and why this is written down. They diverge the
moment R31.M2 and R31.M3 extend the enumeration: a range compare would send the
new thermal and battery classes into the watermark check and make them
**silently sheddable**, where the inequality admits every class that is not a
hot-key.

This is not hypothetical. A mutant that changed the test to a range compare was
proposed as a *correction* during review of this very change, on the reasonable
grounds that it is equivalent — and it is, until it is not. **And it stops being
true in the very next iteration:** #1094 adds a thermal class, which is precisely
the value a range compare would silently make sheddable — a missed thermal trip
on a machine whose EC owns fan control. A future class joins the sheddable set
only by being named.

### The reservation is soft, and saying so matters

The eight slots are reserved **against hot-keys only**. GPE records and firmware
notifications share this stream and carry no class, so a GPE storm can still
fill the ring and refuse a power-button press — which the per-class `lost`
counter then records rather than hides. Making the reservation hard would mean
teaching `acpi_evt_offer` about classes, and it has two other sources whose
records have none.

### The shed fires before the drop

The rule is checked before the walk, so a hot-key that is shed never reaches
`acpi_evt_offer` at all. The witness asserts
`ec_event_stat(HOTKEY, LOST) == 0` and `acpi_evt_drops() == 0` after a
forty-query burst: shedding and dropping are different events with different
fixes, and if they shared a counter that assertion could not exist.

---

## §8 The four classes, and why each is on the list

**Power button — `EC_EVT_CLASS_POWER`.** A long press is handled by firmware and
the OS never sees it. So the OS path is the **only graceful one**: a lost
short-press means the machine does not shut down when asked, and the user's next
move is to hold the button, which is an unclean shutdown every single time.
Never shed. Its losses are counted separately from every other class.

**Lid — `EC_EVT_CLASS_LID`.** On a laptop a close normally means suspend, and on
this target the EC owns fan control — so a missed lid event leaves a running
machine in a closed bag, which is a **thermal** event and not merely a power
one. Never shed.

**AC presence — `EC_EVT_CLASS_AC`.** Insertion and removal drive charging
policy. A missed removal leaves the system believing it is on wall power while
the battery drains. **One class for both directions**: which direction it was is
the `_Qxx` byte, which the record carries, and firmware numbers the two
transitions separately or shares one method depending on the vendor — a class
that encoded the direction would be a claim about firmware this kernel cannot
check.

**Hot-keys — `EC_EVT_CLASS_HOTKEY`.** The only bursty class, the only sheddable
one, and the reason §7 exists.

**Thermal and battery are deliberately not declared.** R31.M2 and R31.M3 own
those events and will extend the enumeration; a class value nothing produces and
nothing consumes would be a constant pretending to be a mechanism.

---

## §9 The payload: `a2` carries the class

#1091 put the matching subscription row in a source-3 record's `a2`.
R31.M1-005 replaces it with the event class, and that is a **replacement**
rather than an addition on purpose.

The row was kernel bookkeeping. A subscriber cannot act on it: there is no op on
any capability that takes a row id — every op reads the row out of the holder's
own descriptor — and a subscriber's delivery count is already readable through
`EC_QUERY_OP_QUERY_DELIVERED`. Two subscriptions to one controller receiving one
byte are already distinguished by the record's `subscriber` field. So the row
told the recipient nothing it could use.

The class is the opposite: it is the one thing a subscriber cannot obtain any
other way, because deriving it means reading the controller's `_Qxx` bodies.

`a2` is already source-dependent by design — the record layout documents it as
*"strike count | notification value"* — so a third column is the documented
pattern rather than a repurposing.

### Why not a sixth argument to `acpi_evt_offer`

It has five call sites, every one of them setting argument registers by hand,
and **nothing in `tools/build.sh` checked its shape**. A sixth parameter added
without touching all five would leave a call site passing whatever it happened
to leave in `r9` as an event class — a silent-failure surface, not a build
failure. The arity is now pinned so a future attempt is loud instead.

---

## §10 What is still missing

| gap | status | where |
| --- | --- | --- |
| kernel→userspace event transport | pre-existing; not widened, not closed | `design/kernel/r30-m4-sci-gpe-path.md` §11.6 |
| a caller for `aml_ec_query_pump` | still absent; the router it would call now classifies, admits and counts | §1 |
| a ring-3 consumer that acts on a class | **absent, and this is the honest headline** — the mechanism has no subject | §1 |
| an installer for the meaning table in a real boot | absent; `ec_event_map_bind` / `ec_event_map_set` are reachable only from the witness | §2 |
| ACPI Global Lock arbitration for EC transactions | open, pinned at 0 by the boot witness | #1580, `embedded-controller-kernel-path.md` §0 |
| per-class quota instead of a soft watermark | declined with reasons | §7 |
| thermal and battery classes | R31.M2 / R31.M3 | §8 |
| queries lost before the router (nobody issued `QR_EC`) | uncountable here by construction | §6 |

---

## §11 Witness and mutation

`tests/kernel/cap/ec_query_synth.pdx`, stages D and E, cap slots 200..211.

**`R31 EC EVENT CLASS OK`** (#1092) — unbound map answers `NONE` and refuses
installs; a `SystemMemory` region cannot bind; the right one binds and the
address is *inherited*; rebinding is refused; eight meanings install (the
vacuity guard for everything after it); byte 0 and an out-of-range class are
refused; **a byte's meaning cannot change**; a foreign controller gets `NONE`
and is counted; **AC insertion routes with `a2 == EC_EVT_CLASS_AC`**; removal is
the same class; an unmapped byte still routes, labelled `NONE`.

**`R31 EC EVENT SHED OK`** (#1093) — lid and power button route labelled; a
**forty-query hot-key burst** yields 22 delivered and 18 shed with zero lost and
zero ring drops; **after that burst the power button still lands**; a lid event
is not shed at a depth where a hot-key is; the ring is then filled with lid
events until a power-button press is genuinely **lost and detectable as
`POWER`**, never shed; op 6 answers through the capability, and `INVOKE` alone is
denied it; the meanings do not survive an unbind while the counters do.

| Mutant | Tag |
|---|---|
| watermark removed — no class is sheddable, so the burst fills the ring | `R31 EC EVENT SHED FAIL line=82` |
| **sheddable set made a range — the power button is shed after a burst** | `R31 EC EVENT SHED FAIL line=83` |
| **a refused offer is not counted against its class — a lost power press becomes undetectable** | `R31 EC EVENT SHED FAIL line=84` |
| meaning-table monotonicity gate dropped — a byte may be silently remapped | `R31 EC EVENT CLASS FAIL line=65` |
| class lookup ignores the bound controller — a second EC inherits the first one's meanings | `R31 EC EVENT CLASS FAIL line=66` |

The middle two are the ones this milestone exists for. The second is the
priority inversion itself: with the sheddable set widened by one value, a
forty-query hot-key burst evicts the power-button press that follows it, and
stage E3 is the only assertion in the tree that notices. The third is the
silent-drop mutant: the event is still lost either way, but the operator can no
longer tell *what* was lost, which is the difference between a counted drop and
an invisible one.

Note that the second mutant is not a strawman. `jb` in place of `jne` is
behaviourally identical today and was proposed as a correction during review;
§7's "enumeration of one, not a range" exists because of it.
