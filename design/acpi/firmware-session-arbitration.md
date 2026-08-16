# Firmware-session arbitration — `KIND_FW_SESSION`

**Issues:** R30.M8-002 (#1083), R30.M8-003 (#1084), naming #1569
**Implementation:** `src/kernel/core/cap/kind_fw_session.pdx`
**Witness:** `tests/kernel/cap/fw_session_cap_synth.pdx` —
fingerprint `R30 KIND_FW_SESSION OK`
**Gate:** `tools/build.sh` — storage confinement + claim-arity pinning

---

## 1. Two locks, one level apart

`design/acpi/global-lock.md` describes arbitration against **firmware**,
where the other party preempts us and cannot be made to wait.

This document describes arbitration among **components of this OS** that
evaluate the same firmware object. Different parties, different
mechanism, and the same two failure modes: a claim that excludes nobody,
and a release that lands too early.

## 2. The name

The R30 catalog called this `KIND_AML_SESSION`. **That identifier cannot
exist in `src/kernel/core/cap/`**, because `tools/lint-no-kernel-aml.sh`
refuses any identifier beginning `aml` anywhere under `src/kernel/**` —
the Pillar 3 guardrail from #822, whose job is to keep a firmware
bytecode interpreter out of ring 0 (`design/acpi/no-aml-in-kernel.md`).
The catalog name and the file's address were in direct contradiction.

**#1569 was filed ahead of this issue** precisely so the contradiction
would be resolved before there was code to rename, and it was resolved by
renaming the capability rather than by carving an exception into the
lint. A boundary with one exception is a boundary with a precedent, and
the next exception is argued from this one rather than from the
rationale.

The new name is also the accurate one: what is arbitrated is an
*evaluation session* against a *firmware-supplied object*. Nothing about
it is specific to the AML bytecode language, and if a platform ever
describes itself in something else the name still reads correctly. A
guardrail placed at a real boundary pushing the catalog toward a better
name is the behaviour one wants from it.

## 3. What the capability makes true

> Many components may hold a session on the same firmware object and read
> it concurrently. At most one of them can be writing it at any moment,
> and the one that is writing knows it is.

Note what is **not** claimed: sessions are not mutually exclusive. That
is the point of having them. R31 will have a battery driver, a thermal
driver and a lid driver all evaluating objects under the same EC scope,
and an arbitration scheme that serialised all of them would serialise the
platform stack behind its slowest consumer.

What must be exclusive is **writing**, and it must be exclusive **per
object** rather than per session.

## 4. Why two tables

A capability names a *session*. Arbitration is about the *object*. Those
have different cardinalities: N sessions to 1 object.

Putting the writer claim in the session row would give every session its
own claim — which is the same as having no arbitration at all. Each
holder would successfully claim "the lock", observe that it holds it, and
write concurrently with every other holder doing the same. **That failure
has no symptom on the claiming side whatsoever**; it surfaces as a
firmware object with interleaved half-updates.

| table | rows | role |
|---|---|---|
| `_fw_object_table` | 8 × 128 B | **the arbitrated thing.** One row per distinct `(scope_path, op_region_domain)`. Carries the claim, the claim depth, the session refcount, and the path. |
| `_fw_session_table` | 16 × 16 B | **the capability's row.** One per live capability. Carries the domain, the parent slot, and an index into the object table. |
| `_fw_ep_registry` | 8 × 16 B | the second half of the derivation gate (§6). |

Two capabilities minted on the same `(scope_path, domain)` resolve to the
**same object row**. That is not an optimisation — it is the entire
mechanism. `fw_object_alloc` therefore **finds first and allocates
second**, and the witness asserts ten sessions leave `fw_objects_live()`
at 1.

Object rows are 128 bytes rather than the 96 the fields need, because a
power-of-two stride makes the row index a shift and paideia-as has no
`mul`.

## 5. Tail encoding — and why the path is stored whole

The catalog tail is `{scope_path:[u8;64], op_region_domain:u8}` — 65
bytes against a 64-**bit** `target_ptr`, so the tail goes in a private
table and `target_ptr` carries a row id. This is the row-indirection
discipline `KIND_HW_INTERRUPT` (#1019), `KIND_DMA_DOMAIN` (#1036),
`KIND_OP_REGION` (#1061), `KIND_ACPI_EVENT` (#1068) and `KIND_GPIO_LINE`
(#1075) all use.

`target_ptr` layout: row id in `[15:0]`, owning slot in `[31:16]` —
matching `KIND_GPIO_LINE`.

**The scope path is stored in full, not hashed**, and that is worth an
argument because 64 bytes per object is the largest row in the cap
subsystem and a 64-bit hash would have made it 8.

A hash collision between two distinct scope paths would merge two
firmware objects into one arbitration domain. The consequence is not a
wrong answer to a query — it is that a writer holding the claim on
`\_SB.PCI0.LPCB.EC0` would exclude a writer on an unrelated scope, and,
worse, the reverse: two paths that *should* share an object but hash
differently would not exclude each other at all. Identity is the whole
basis of the exclusion, so identity is exact.

The comparison requires **equal lengths first, then all bytes**. A
comparison that stopped at a shared prefix, or at a NUL, would report
`\_SB.PCI0.LPCB.EC0` and `\_SB.PCI0.LPCB.EC0X` as the same object. The
witness's two fixture paths share their first 17 bytes and differ in the
18th for exactly this reason.

**The kernel does not parse the path and must not.** It is a firmware
namespace this ring is forbidden to interpret, so an exact opaque byte
comparison is the strongest honest identity available.

## 6. Derivation — over `KIND_IPC_ENDPOINT`, in two halves

The parent is a `KIND_IPC_ENDPOINT` (base slot 5), because a session is a
conversation: the holder talks to the ACPI supervisor, and the authority
to open a session is downstream of the authority to talk to the component
that holds the firmware namespace.

**A kind check alone is an empty gate here**, and more obviously so than
anywhere it has been said before. *Every* IPC endpoint in the system is a
`KIND_IPC_ENDPOINT` — the shell's stdout is one. A gate stopping at
`kind == 5 && rights & RIGHT_MINT` would let the holder of any endpoint
whatsoever mint arbitration authority over the embedded controller.

| | check |
|---|---|
| **first half** | `cap_table[parent_slot].kind == KIND_IPC_ENDPOINT (5)` and `rights & RIGHT_MINT` |
| **second half** | the parent's **inherited** endpoint id must be registered in `_fw_ep_registry`, **and** the requested `op_region_domain` must be in the mask that registration granted |

This is the shape `KIND_GPIO_LINE` (#1075) established: a kind check that
every candidate satisfies, plus an inherited identity that must resolve
in a table the platform wrote.

**The endpoint id is inherited, never argued.** `fw_session_cap_mint` has
no endpoint parameter; it reads the id from the parent descriptor's
`target_ptr[15:0]`. That is what makes the second half unforgeable — a
caller cannot name an endpoint it does not hold, so it cannot claim a
domain that endpoint was not registered for.

The witness exercises all four refusals: wrong kind, right kind without
`RIGHT_MINT`, **right kind with `RIGHT_MINT` but an unregistered
endpoint**, and a registered endpoint asking for a domain it was not
registered for.

## 7. Rights

| bit | right | authorises |
|---|---|---|
| `0x001` | `READ` | sampling the object |
| `0x002` | `WRITE` | modifying it, **and taking the claim** |
| `0x008` | `INVOKE` | reading back the row's own object and domain |
| `0x010` | `REVOKE` | being revoked |
| `0x400` | `OBSERVE` | the holder, the depth, the canonical dump |

`R_FW_SESSION_ALL = 0x41B`.

`RIGHT_MINT` (`0x200`) is deliberately **outside** the mask: this kind is
a leaf of the derivation lattice. A session does not derive sessions, and
a MINT bit no gate reads is the shape that later acquires a meaning
nobody audited — the argument #1071 made and #1075 repeated.

**Taking the claim requires `RIGHT_WRITE`** even though it stores nothing
in the object, because its whole effect is to exclude other writers. A
read-only holder that could exclude writers could stall the platform
stack without ever having been granted authority over it.

The converse is a legitimate configuration and is why `WRITE` and the
claim are not the same thing: a session needing a consistent multi-read
snapshot takes the claim precisely so nobody writes underneath it.

## 8. The claim

* **Unclaimed** → take it; depth 1; `holder = row + 1`.
* **Held by the same session** → increment the depth and succeed. A
  session evaluating a method that evaluates another method against the
  same object must not deadlock against itself — the recursive-mutex rule
  `aml_ctl.pdx` states for `Serialized` methods, one level up.
* **Held by a different session** → `FW_SESSION_CLAIM_HELD`. A
  **refusal**, not a queue: this kernel has no place to park a waiter,
  and a silent grant would be a data race dressed as success.
* **Release at depth > 1** → decrement and **retain**. An inner release
  that dropped the claim would let a second session start writing the
  object in the middle of the outer session's update — the #1082
  nested-release failure one level up, with the same shape: the loser's
  corruption appears in the firmware object rather than in the loser's
  code.
* **Release holding nothing** → `FW_SESSION_CLAIM_NOT_HELD`, not a silent
  no-op, because it means a caller's bracketing is broken and the next
  release would be somebody else's.

The `holder` field stores `row + 1`. **The `+1` bias is deliberate:**
session row 0 is a legitimate row, and storing the row id raw would make
"row 0 holds the claim" and "nobody holds the claim" the same bit
pattern — the arbitration equivalent of always answering yes.

The owner comparison is against the **session row**, not the capability
slot, because a slot can be revoked and re-minted while a claim is
outstanding and the new occupant is not the old one.

## 9. Revoke

Reads the row id from the **descriptor**, never from an argument. Then:

1. **Releases the claim if this session held it, at any depth.** A
   revoked session cannot release its own claim afterwards, and a claim
   left held by a dead session would exclude every other writer on that
   object forever — a firmware object permanently frozen by a driver that
   has already exited.
2. Frees the session row.
3. Decrements the object refcount, and frees the object row at 0, so the
   table is reusable across a boot rather than monotonically consumed.
4. Clears the descriptor **through `cap_mint_write`**.

On (4): #1579 records that `cap_mint_write` is the only writer of
capability descriptors by convention rather than by build gate, and that
some existing revoke paths clear descriptors with direct stores instead.
This module does not fix that — not its issue — but deliberately does not
add to it. Both the mint and the revoke here go through `cap_mint_write`,
so when #1579 lands its gate, this module already satisfies it.

## 10. Linearizability — #1084

A property needs a definition before a test can assert it.
"Linearizable" is easy to put in a commit message and hard to put in an
assertion. This is the definition the witness uses.

**The object under test** is a single logical counter standing in for a
firmware object's state.

**An episode** is one session's read-modify-write against it, and it is
deliberately five separate steps:

```
CLAIM -> READ -> BUMP -> WRITE -> UNCLAIM
```

The split is the whole point. A one-step "increment" cannot be
interleaved and therefore cannot lose an update no matter how broken the
arbitration is. With `READ` and `WRITE` as distinct steps, a scheduler
can place another session's episode between them — which is where a lost
update comes from.

**A session trusts its own claim.** Steps 2..5 proceed if and only if the
session recorded a *successful claim*, not if the object's holder field
happens to name it. That is what a real driver does, and modelling it
any other way would build the arbitration's correctness into the harness:
the test would pass against an arbitration that granted every request.

The assertion is then:

| | property | how it is checked |
|---|---|---|
| **L1** | **mutual exclusion** — at no point between any two steps is more than one session inside an episode | after **every** step, not at the end |
| **L2** | **no lost updates** — the object's final value equals the number of completed `WRITE` steps | each episode adds exactly one, so the episodes admit a total order consistent with each session's program order |
| **L3** | **non-vacuity** — the schedule actually contended | exact blocked-step and total-step counts |

L1 is checked between adjacent steps because every episode ends with an
`UNCLAIM`: the quiescent final state is consistent with any amount of
overlap in between.

L2 is the machine-checkable statement of linearizability *of the
arbitrated object*. A broken arbitration fails L1 immediately and L2
shortly after, because two sessions read the same value and both write
it plus one.

L3 exists because **a "concurrent" test that executes sequentially proves
nothing.** Without it, L1 and L2 are satisfied by any schedule that
happens not to overlap.

## 11. The schedule is not round-robin

A harness that runs evaluator 1 to completion, then evaluator 2, cannot
manifest an arbitration bug. Neither can a round-robin schedule be
trusted to: it produces *some* interleavings, but not necessarily the
ones that break a naive implementation.

**Phase A is derived from the failure modes** and written out by hand,
step by step, as a 14-byte table. It contains the two interleavings a
naive implementation gets wrong:

| step | | |
|---:|---|---|
| 1 | S0 `CLAIM` | granted |
| 2 | S1 `CLAIM` | **refused** — *(i) two sessions both observe the object free; a check-then-set grants both* |
| 3 | S0 `READ` | |
| 4 | S2 `CLAIM` | refused |
| 5 | S0 `BUMP` | |
| 6 | S1 `READ` | **blocked** — S1 never got the claim and must not proceed on a refusal |
| 7 | S0 `WRITE` | |
| 8 | S0 `UNCLAIM` | |
| 9 | S1 `CLAIM` | **granted** — *(ii) a release lands between another session's check and its use* |
| 10 | S1 `READ` | |
| 11 | S0 `CLAIM` | refused |
| 12–14 | S1 `BUMP`/`WRITE`/`UNCLAIM` | |

Interleaving (ii) is got wrong in opposite directions by an
implementation that caches the refusal and by one that leaves the holder
field stale on release.

**Phase B is the ten-evaluator stress**, interleaved at *step*
granularity: every session attempts step *k* before any session attempts
step *k+1*, so the episodes overlap maximally.

```
for pass in 0..9:
  for op in 0..4:
    for i in 0..9:
      step((pass + i) mod 10, op)
```

**The rotation is load-bearing.** Without it, session 0 would claim first
in every pass and the other nine would never complete an episode — a much
weaker property wearing this test's name. With it, each of the ten wins
exactly one pass.

Phase B schedules 500 steps of which exactly 50 can be performed, so 450
are blocked. The witness asserts those **exact** figures rather than
`> 0`: a schedule that silently stopped contending would still clear a
floor, and the blocked count is the observable that says the interleaving
was as dense as it was designed to be.

## 12. Failure taxonomy — `0xFFFFFE10..0xFFFFFE1F`, a new band

**The `0xFFFFFFxx` band is exhausted.** At the time of writing it has two
free runs of eight and nothing wider, while every previous derived kind
took a contiguous sixteen (`KIND_GPIO_LINE` `0xFFFFFF10..1F`,
`KIND_ACPI_EVENT` `0xFFFFFF90..9F`, `KIND_OP_REGION` `0xFFFFFFC5..CF`,
`KIND_DMA_DOMAIN` `0xFFFFFFD5..DF`).

Splitting this kind's codes across two eight-wide holes to stay in the
old band would have made the taxonomy discontiguous for no reason other
than that the band was full, and would have left the *next* kind with the
same problem and less room. **`0xFFFFFExx` is opened here as the
successor band**, disjoint from every code in tree.

| code | name |
|---|---|
| `0xFFFFFE1F` | `FW_SESSION_MINT_BAD_ARG` |
| `0xFFFFFE1E` | `FW_SESSION_MINT_BAD_PARENT` |
| `0xFFFFFE1D` | `FW_SESSION_MINT_BAD_RIGHTS` |
| `0xFFFFFE1C` | `FW_SESSION_MINT_NO_EP` |
| `0xFFFFFE1B` | `FW_SESSION_MINT_BAD_DOMAIN` |
| `0xFFFFFE1A` | `FW_SESSION_MINT_BAD_SCOPE` |
| `0xFFFFFE19` | `FW_SESSION_MINT_ENOSPC` |
| `0xFFFFFE18` | `FW_SESSION_MINT_OBJ_ENOSPC` |
| `0xFFFFFE17` | `FW_SESSION_CLAIM_HELD` |
| `0xFFFFFE16` | `FW_SESSION_CLAIM_NOT_HELD` |
| `0xFFFFFE15` | `FW_SESSION_CLAIM_DEPTH` |
| `0xFFFFFE14` | `FW_SESSION_REVOKE_BAD_SLOT` |
| `0xFFFFFE13` | `FW_SESSION_REVOKE_WRONG_KIND` |
| `0xFFFFFE12` | `FW_SESSION_REVOKE_ALREADY` |
| `0xFFFFFE11` | `FW_SESSION_EP_ENOSPC` |

## 13. Confinement

`tools/build.sh` asserts that `_fw_object_table`, `_fw_session_table` and
`_fw_ep_registry` are relocated against from `kind_fw_session.o` and no
other object, each with a vacuity guard requiring the owner to reference
it.

`_fw_object_table` **is** the arbitration. A second writer could set a
holder (making the next release drop a claim this process never took),
clear one mid-episode (same consequence, no symptom on either side), or
write a scope path (merging two objects so the claim on one silently
excludes a writer on the other and fails to exclude its real peer). None
of the three has a symptom at the point of the bug.

`_fw_ep_registry` is the second half of the derivation gate — the whole
difference between "the parent is an IPC endpoint", which everything
satisfies, and "the parent is the supervisor's endpoint". A second writer
could register the shell's endpoint and mint arbitration authority over
the embedded controller.

`tools/build.sh` also pins the arities of `fw_session_claim`,
`fw_session_unclaim` and `fw_session_row_obj` verbatim. An object
parameter would make "arbitrate against something other than what my
capability names" expressible, and a caller that claimed one object while
writing another would be excluding nobody while reporting success.

## 14. Mutation results

| mutant | detected by | exact failure |
|---|---|---|
| a second session's claim on a held object is granted | boot witness | `smoke: fingerprint line 33 ('R30 KIND_FW_SESSION OK') NOT found`; serial shows `R30 KIND_FW_SESSION FAIL` |
| an inner `unclaim` drops the claim at any depth | boot witness | same, `R30 KIND_FW_SESSION FAIL` |
| `fw_object_alloc` allocates per capability instead of find-first | boot witness | same, `R30 KIND_FW_SESSION FAIL` |
| the golden line is perturbed (non-vacuity) | build gate | `[fingerprint-coverage] UNWITNESSED FINGERPRINTS (#1578 class): emitted at tests/kernel/cap/fw_session_cap_synth.pdx:118` |

The first three each break L1 and are caught between adjacent steps
rather than at the end of the schedule.

## 15. What this does not yet do

* **No waiting.** A refused claim is refused. There is no queue and no
  blocking, because this kernel has nowhere to park a waiter that a
  capability invocation could return to. R31 decides whether the
  supervisor retries or propagates.
* **No supervisor wiring.** `fw_ep_register` is called by the witness and
  by nothing else; the ACPI bring-up path that would register the real
  supervisor endpoint does not exist yet.
* **No userspace session identity.** `aml_ctl_ctx` still returns the
  constant 1, so `AML_ERR_MUTEX_CONTENTION` (54) remains unreachable from
  inside the bubble. The kernel-side arbitration landed first
  deliberately: it is the part that has to be right before more than one
  evaluator exists.

## 16. References

* `design/architecture/next-wave-derived-kinds.md` §`KIND_FW_SESSION`.
* `design/acpi/global-lock.md` — arbitration against firmware.
* `design/acpi/no-aml-in-kernel.md` §3 — why the name had to change.
* `design/roadmap/next-wave-softarch.md` §3 R30 — the catalog row.
