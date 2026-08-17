# PaideiaOS — The Embedded Controller, kernel side

**Status:** Ratified v1.0
**Date:** 2026-08-17
**Round:** R31.M1 (issues #1089, #1090, #1091)
**Owners:** acpi + drivers + capabilities
**Enforcement:** `tools/build.sh` (`[ec-confine]` — storage confinement,
arity pins, no-widening check), `tests/kernel/cap/ec_query_synth.pdx`
(three boot fingerprints), `tools/verify-cap-stride.sh`,
`tools/lint-no-kernel-aml.sh`.

Companion to `design/acpi/embedded-controller.md`, which specifies the
**ring-3** half. Read that one first; this document only covers what the
kernel does, and it is deliberately a small and sharply bounded set.

---

## 0. THE THING TO READ IF YOU READ ONE SECTION

**Embedded-controller transactions authorised through this path are not
arbitrated against System Management Mode.** They will not be until
**#1580** is closed.

The ACPI Global Lock — the mechanism that exists precisely because SMM
drives the controller behind the OS's back — is implemented, correct and
thoroughly witnessed in `src/user/aml/aml_glk.pdx` (R30.M8-001, #1082).
In a real boot **it does nothing**, because three pieces of plumbing are
missing:

| Missing | Where | Consequence |
|---|---|---|
| `FIRMWARE_CTRL` / `X_FIRMWARE_CTRL` are declared and never read | `src/kernel/acpi/fadt.pdx` | the FACS address is never resolved, so the lock word at FACS+0x10 has no address |
| no FACS field in the supervisor wire schema | `design/ipc/acpi-supervisor-schema.md` | nothing could carry the address to the ring-3 bubble that acquires the lock |
| PM1 control port parsed into `fadt_info` and then dropped | `src/kernel/acpi/fadt.pdx` → nothing | the `GBL_RLS` release doorbell has nowhere to go, so firmware waits |

Only the test corpus attaches a lock. **On the T14 target this means the
OS and firmware can drive the controller's registers at the same time,
and neither will know.**

### Why this milestone did not close it

Closing #1580 means reading `FIRMWARE_CTRL` (and `X_FIRMWARE_CTRL`, which
supersedes it when non-zero) at FADT parse, adding a FACS field to the
wire schema, populating it at handoff, plumbing PM1a/PM1b control, and
attaching the real lock in the production path — not the corpus.

A **half**-plumbed version of that is strictly worse than none. The
current state is at least legible: nothing claims a lock. A version that
resolved the FACS and did not reach the bubble, or reached the bubble and
could not ring the doorbell, would read as wired at every call site and
still be inert — which is the exact failure mode #1580 was filed to
prevent from recurring.

### What was done instead, and why it is not just a comment

`ec_access_arbitrated()` returns the arbitration state.
**Nothing in this tree sets it**, and
`tests/kernel/cap/ec_query_synth.pdx` **stage 35 pins it at 0**.

That pin is an assertion that **fails when the thing it describes becomes
true**. The commit that closes #1580 breaks the boot witness and cannot
pass the pre-push matrix without also rewriting §0 of this document and
the header of `src/kernel/core/drivers/ec/ec_access.pdx`. A comment would
have rotted silently; this cannot.

It is the same device #1065 used to keep the EC OpRegion gate honest
while it was shut, and R31.M1 mutation-tested it in the other direction
too: a mutant that sets the word during `ec_access_bind` — i.e. that
falsely claims arbitration — produces `R31 EC ACCESS FAIL line=35`.

Every audit record this path emits is therefore a record of an
**unarbitrated** transaction, and §4 says so where the record format is
defined.

---

## 1. What is in the kernel, and what is emphatically not

`design/acpi/no-aml-in-kernel.md` forbids a firmware-bytecode interpreter
in ring 0, and `tools/lint-no-kernel-aml.sh` enforces it down to the
token level — including inside `justification:` strings, which are code
and are not comment-stripped. `_Qxx` dispatch *is* bytecode evaluation:
the query byte selects a control method. So the register handshake, the
timeouts, the transaction claim and the query episode all live in ring 3
and stay there.

| Concern | Where | Since |
|---|---|---|
| `IBF`/`OBF` handshake, bounded timeouts, refusal codes | `src/user/aml/aml_ec.pdx` | R30.M7 (#1079/#1081) |
| `_Qxx` name construction, exact-scope resolution, invocation | `src/user/aml/aml_ec.pdx` | R30.M7 (#1080) |
| transaction claim vs. query episode (the reentrancy decision) | `src/user/aml/aml_ec.pdx` | R30.M7 (#1081) |
| Global Lock protocol | `src/user/aml/aml_glk.pdx` | R30.M8 (#1082) |
| **who may subscribe to a controller's queries** | `src/kernel/core/cap/kind_ec_query.pdx` | **R31.M1 (#1090)** |
| **the extent every transaction is confined to, and its record** | `src/kernel/core/drivers/ec/ec_access.pdx` | **R31.M1 (#1089)** |
| **routing a decoded query to its subscribers** | `src/kernel/core/acpi/ec_route.pdx` | **R31.M1 (#1091)** |

The kernel's three pieces are the ones that **cannot** live in the
bubble, because the bubble runs firmware bytecode and is therefore
untrusted with exactly them: the definition of the controller's extent,
the record of what was done to it, and the decision about who is allowed
to hear about it.

---

## 2. #1091 was mostly already done, and this says which part

The issue's deliverable reads "`_Qxx` query byte decoder; dispatch into
`acpi_event_channel`". **The decoder half shipped in R30.M7 and was not
rebuilt.** `aml_ec_query_pump` issues `QR_EC`, reads the byte, builds the
four-character `_Qxx` NameSeg with uppercase hex, resolves it *exactly*
in the controller's own scope (not by the §5.3 upward search rule, which
would find an ancestor's `_Q80`), invokes the method, treats byte 0 as
"nothing pending" rather than as `_Q00`, bounds episode nesting at 4, and
counts a missing method rather than latching it as a fault.
`tools/verify-aml-parser.sh` pins its signature and its arity.

What was missing was that **the decoded query went nowhere**.
`aml_ec_query_pump` returned a status to a caller that did not exist, and
no subscriber in the machine could learn that a lid had closed. Grep
confirmed the situation before this milestone: `acpi_event_channel`
appeared exactly once in the repository, in
`design/roadmap/next-wave-softarch.md`, as a name with no code behind it;
`KIND_EC_QUERY` appeared only as "a *planned* R31 kind" in
`design/acpi/crash-isolation.md`.

So #1091 here is the routing, and only the routing.

---

## 3. `KIND_EC_QUERY` — the subscription (#1090)

Tag `0x156`, derived over `KIND_IPC_ENDPOINT` (base slot 5). Full
specification in `design/architecture/next-wave-derived-kinds.md`
§`KIND_EC_QUERY` and in the module header. Three points belong here.

### 3.1 The gate is in two halves because one half is empty

The kind check alone admits **every endpoint in the machine**, the
shell's stdout included. That is the #1075 lesson (`KIND_GPIO_LINE`)
restated: when every candidate shares the base kind, a kind check
discriminates nothing, and a gate that discriminates nothing is worse
than no gate because it reads like one.

The second half is a **second capability argument**: `region_slot` must
be a live `KIND_OP_REGION` carrying `RIGHT_MINT`, over
`OPREG_SPACE_EC (0x03)`, with a declared length in 1..256.

```
KIND_IPC_ENDPOINT (5)          KIND_OP_REGION (0x150, space 0x03)
    + RIGHT_MINT                          + RIGHT_MINT
   "where you are told"            "which controller, and that
          \                          firmware declared it"
           \                            /
            +------ both required -----+
                        |
                 KIND_EC_QUERY (0x156)
```

Both `ec_addr` and `endpoint_id` are **inherited** from the two parents
and are not arguments anywhere in the mint. A subscription stamped with
controller A's address while its region capability names controller B
would pass both halves and then misreport, for its whole life, which
machine's events it was receiving — the same argument
`acpi_evt_cap_mint` makes for not accepting a GSI.

The two failure codes are kept distinct — `MINT_BAD_REGION` for "that is
not a region capability" and `MINT_BAD_SPACE` for "it is one, over the
wrong space or of an impossible size" — because the fixes differ.

### 3.2 The notify bitmap starts full and only ever narrows

256 bits, one per possible query byte, in four row words. `ec_query_row_narrow`
**clears** one bit and there is no primitive that sets one; `tools/build.sh`
greps for the natural names of a widening mutant and refuses the build.

Starting full is not a weakening. The mint gate already proved the minter
holds a `KIND_OP_REGION` over the whole EmbeddedControl space of that
controller, so "every query this controller raises" is reach it
demonstrably had, and the child begins with no more than its parent.
Narrowing afterwards is how a subscriber that only cares about the lid
stops being woken by the battery — a preference, expressed monotonically,
so a holder can never end a boot with more reach than it started with.

The alternative — taking the mask as a mint argument — is not
expressible: 256 bits of mask plus slot, parent, region and rights is
eight registers and SysV has six, and every workaround (a mask covering
only the low 128 query bytes, a band index selecting one word, a pointer
to a caller-owned array) either silently loses `_Qxx` values real
firmware uses — the corpus fixture uses `_Q80` — or hands a raw
destination address across the boundary the confinement assertion exists
to close.

### 3.3 It is not loader-seedable, deliberately

`KIND_SEEDABLE_TABLE` omits it and this milestone added no entry. #1597's
rule refuses a kind *defined by its derivation*, because seeding
manufactures a root with no parent. This kind is the strongest case for
that rule so far: both parents are load-bearing, one of them supplies the
controller address the row records, and a sidecar entry naming it would
create a subscription to an address taken from untrusted image bytes with
no region capability behind it. The refusal needs no code — the predicate
scans an enumeration — so the decision is recorded rather than
implemented.

---

## 4. The transaction gate and the record (#1089)

`ec_access_bind(region_slot)` — **arity one, pinned in `tools/build.sh`**
— takes the same `KIND_OP_REGION` and inherits base and length from its
row. There is no base parameter and no length parameter anywhere in the
module. A caller-supplied extent would mean every range refusal was
enforcing the caller's claim rather than the kernel's grant, which is the
confinement property inverted.

`ec_access_audit(op, addr, value)` gates and records:

| Gate | Code | Why it is separate |
|---|---|---|
| a binding exists | `EC_ACCESS_UNBOUND` | with none, "in range" has no definition |
| op is read or write | `EC_ACCESS_BAD_OP` | checked *before* the range, so a malformed op on a legal address reports the fault a caller can fix |
| a write's value fits in a byte | `EC_ACCESS_BAD_VALUE` | refused, never masked — masking puts a byte on the wire nobody asked for |
| `addr < len` | `EC_ACCESS_RANGE` | **the grant, not the specification** |

The last row is the load-bearing one, and the boot witness asserts it
against a region minted with **length 64**: address 64 is inside the
256-byte space ACPI defines and outside the extent the capability
granted. A gate confined to the specification passes every other
assertion in the witness and fails that one — mutation-tested,
`R31 EC ACCESS FAIL line=38`.

This is a **fourth** independent range check, and is not redundant with
the three `design/acpi/embedded-controller.md` §6.1 enumerates: all three
of those are inside the bubble, and a bubble that is wrong or compromised
passes them by construction.

### The record

One `drv_audit_emit` per transaction, permitted or refused, into the
sealed `driver_audit_channel` ring (#1040/#1041) rather than a private
log — that ring is tamper-evident and already reconciled across a driver
restart.

```
event     DRV_AUDIT_EV_EC_XACT (7)
kind      0            — not a capability transition, so mint/revoke
                         accounting stays exact under EC traffic
subject   EC-space address
principal (op << 32) | (value & 0xFF)
outcome   0, or the EC_ACCESS_* refusal code
```

The value is carried because "which byte was written to charge control"
is not answerable from the address alone, and this is the one device in
the tree whose written values can outlive the boot. **Every one of these
records describes an unarbitrated transaction** (§0).

Emission covers refusals as well as permissions: an attempt on an address
outside the region is the single most important thing this module can
ever see, and a record made only on success would omit it.

---

## 5. Routing (#1091)

`ec_route_query(ec_addr, query_byte)` walks the eight subscription rows
and offers a record to each recipient:

```
acpi_evt_offer(ACPI_EVT_SRC_EC_QUERY = 3, endpoint_id,
               a0 = ec_addr, a1 = query_byte, a2 = subscription row)
```

Source 3 is the **third** value in the offer gate's enumeration, and
`acpi_evt_offer`'s own justification anticipated it in R30.M4: it carries
`NEEDS_ACK` in a `flags` field of its own rather than deriving it from
`source`, "so that a future third acknowledging source does not require
every subscriber to learn a new source number." A query is **not**
acknowledging — the GPE that woke the machine was acknowledged by the
record that carried it, and acking a query would re-enable a hardware bit
nobody masked — so `flags` stays 0 and the enumeration grew by exactly
one value.

### Four outcomes, counted separately

| Counter | Meaning | Fix |
|---|---|---|
| `routed` | an offer was accepted | — |
| `filtered` | a live subscription for this controller has unsubscribed from this byte | **none; working as configured** |
| `unrouted` | no live subscription names this controller | mint the capability |
| `refused` | a matching subscription existed and the stream said no | backpressure, or nothing bound |

"The lid does nothing" has three completely different causes and this is
the only place that can tell them apart. `unrouted` is counted **once per
query**, not once per row, so one unrouted lid event does not look like a
storm.

Query byte 0 is refused with its own code and its own counter. That check
is deliberately made in **both** places: the ring-3 one protects the
interpreter from invoking a method firmware defined for something else
(`design/acpi/embedded-controller.md` §9), and this one protects the
stream from a caller that did not honour that contract.

### Confinement survived contact with its first consumer

The router never touches `_ec_query_table`. It asks
`ec_query_row_covers` and `ec_query_row_target`, which return a boolean
and an endpoint identity — never an address into the table. That is what
lets `tools/build.sh` keep asserting that only `kind_ec_query.o`
relocates against the array, and the router was written to satisfy the
assertion rather than the assertion relaxed to admit the router. A
confinement that is never consumed has not been tested.

---

## 6. What is deliberately not here

| Not implemented | Why | Where it goes |
|---|---|---|
| SMM arbitration in production | FACS/PM1 unplumbed | **#1580**, and §0 |
| a caller for `ec_route_query` | the kernel→userspace event transport does not exist; this module is the sibling of `acpi_evt_notify`, which has had the same status since R30.M4 and is witnessed the same way | `design/kernel/r30-m4-sci-gpe-path.md` |
| EC ports discovered from `_CRS` | `aml_resource.pdx` decodes them; nothing wires the decode to `aml_ec_attach` | the supervisor, with the transport |
| a revoke cascade on `KIND_EC_QUERY` | nothing derives from a subscription; an empty cascade call would be a hook that looks maintained and is not | n/a |
| a syscall reaching any of this | there is no ACPI syscall and this milestone did not invent one | with the transport |

The second row is the one to be careful about. This milestone **does not
widen** the transport gap and does not pretend to close it. What it
removes is a different absence: before it, even with a transport in
place, a decoded query had nowhere to go.

---

## 7. Mutation results

Every guardrail introduced by R31.M1 was mutation-tested against a real
QEMU boot. Each mutant produced its own tag:

| Mutant | Tag |
|---|---|
| second half of the gate: drop the `KIND_OP_REGION` kind check | `R31 KIND_EC_QUERY FAIL line=12` |
| second half of the gate: accept the wrong address space | `R31 KIND_EC_QUERY FAIL line=13` |
| rights: admit `RIGHT_MINT` into a leaf kind | `R31 KIND_EC_QUERY FAIL line=14` |
| narrowing clears a whole bitmap word instead of one bit | `R31 KIND_EC_QUERY FAIL line=17` |
| **falsely claim SMM arbitration at bind** | `R31 EC ACCESS FAIL line=35` |
| range bound uses the 256-byte specification, not the grant | `R31 EC ACCESS FAIL line=38` |
| router accepts query byte 0 | `R31 EC QUERY ROUTE FAIL line=53` |
| offer gate rejects source 3 | `R31 EC QUERY ROUTE FAIL line=51` |

The last two are recorded separately because they are the two ways the
routing path can be silently wrong: one delivers an event that did not
happen, the other delivers nothing at all.

The fifth row is the important one. The statement "this path is not
arbitrated" is not prose — a change that contradicts it fails the build.

---

## 8. Cross-references

- `design/acpi/embedded-controller.md` — the ring-3 half; §2 for why this
  device gets more care than the rest of R30, §4 for the reentrancy
  decision, §6.1 for the three in-bubble range checks, §9 for query zero.
- `design/acpi/global-lock.md` — the protocol #1580 must reach.
- `design/acpi/no-aml-in-kernel.md` — why the interpreter is not here.
- `design/kernel/r30-m4-sci-gpe-path.md` — the deferral path and the
  transport gap.
- `design/architecture/next-wave-derived-kinds.md` — the `KIND_EC_QUERY`
  catalog row.
- `design/capabilities/ownership-and-lineage.md` — the `cap_revoke_slot`
  dispatch this kind was added to.
