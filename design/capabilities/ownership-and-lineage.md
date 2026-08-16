# Capability ownership and capability lineage

**Round.** R31.M1 — closes #1587 and #1589 together.
**Status.** Decided. Implemented by `src/kernel/core/cap/table.pdx`,
`src/kernel/core/cap/owner.pdx`, the `[cap-stride]` gate in
`tools/build.sh`, and witnessed by `tests/kernel/cap/owner_sweep_synth.pdx`.

---

## 0. Why these two issues are one decision

#1587 says the capability table has no owner, so *"the capabilities held by
process P"* is not a representable query. #1589 says `struct Capability`
declares `generation` and `flags` that have no storage, and that writing
them at their declared offsets would corrupt the adjacent descriptor.

They are the same question asked twice: **what is the shape of a capability
descriptor, and where does a column that is not part of it live?** Answering
#1589 with Option B (widen the stride to 32 bytes) would have made #1587's
owner a natural fourth word. Answering it with Option A (drop the phantom
fields, keep 24 bytes) forces the owner somewhere else. Deciding either in
isolation would have pre-committed the other by accident.

Both are decided here. §3 chooses; §2 is the argument that had to be made
first, because it determines what is being stored.

---

## 1. Ownership and lineage are different axes

This is the trap the whole design is arranged around, so it is stated before
anything is built.

Every cascade the kernel already has keys on **parent identity** — the
derivation lineage:

| function | key |
|---|---|
| `opregion_cascade_revoke_by_parent(parent_slot)` | a cap slot |
| `i2c_slave_cascade_revoke_by_bus_row(bus_row)` | a row id |
| `gpio_line_cascade_revoke_by_controller(controller_id)` | a bdf key |
| `dma_cascade_revoke_by_parent(parent_slot)` | a cap slot |
| `msix_cascade_revoke_by_parent(parent_slot)` | a cap slot |

Owner-based revocation keys on **holder**. These are not the same relation
and neither implies the other:

> A capability C can be **derived from** a parent owned by X while being
> **held by** Y.
>
> X dying must cascade to C — C's authority was carved out of X's, and a
> sub-window of a window that no longer exists names nothing.
>
> Y dying must revoke C — Y is the process that could exercise it, and a
> slot that outlives its holder is inherited by whatever process next
> occupies it.

Two different sweeps. Both are needed. Neither may silently stand in for the
other, and the failure modes of substituting one for the other are not
symmetric:

- **Lineage standing in for ownership** (what the tree has today) *under*-revokes.
  A crashed ACPI bubble's OpRegion windows survive its death, because nothing
  it held was derived from anything that also died. This is the leak #1587
  names.
- **Ownership standing in for lineage** *over*-revokes in one direction and
  under-revokes in the other. It would tear down a live process's derived
  windows because their root's holder died, while missing a child window that
  the dying process derived and then handed to someone else.

So the implementation composes them rather than choosing: **the owner sweep
finds the slots; the per-kind audited revoke beneath each slot runs the
lineage cascade.** `cap_owner_sweep_revoke` is deliberately not a loop of
three zero-stores; it dispatches on `kind` to the same
`opregion_cap_revoke` / `i2c_bus_cap_revoke` / `i2c_slave_cap_revoke` /
`gpio_line_cap_revoke` / `fw_session_cap_revoke` entry points that the
lineage cascades already call. The two axes meet exactly once, at that
dispatch, and that is the only place they are allowed to meet.

### 1.1 OpRegion transitivity is preserved as a fixed point

`KIND_OP_REGION` is the one kind of the five that is transitive: a window can
be derived from a window, so revoking a root must reach grandchildren.
`opregion_cascade_revoke_by_parent` implements that as an **iterated fixed
point** — repeat the full 256-slot scan until a pass revokes nothing — and
not as recursion, because recursion would put an unbounded-depth call chain
on a teardown path, which is precisely the shape a hostile derivation chain
would exploit.

The owner sweep preserves this. For each owned `KIND_OP_REGION` slot it calls
`opregion_cascade_revoke_by_parent(slot)` **and then**
`opregion_cap_revoke(slot)`, in that order. It does not recurse, does not
compute a subtree, and does not need to know whether the slot is a root: the
cascade's own fixed point handles depth, and revoking a leaf simply finds no
children on the first pass and terminates on the second. The other four kinds
get a single audited revoke, because none of them carries `RIGHT_MINT` in a
form that produces grandchildren (`i2c_bus_cap_revoke` cascades to its slaves
internally, one level, from inside its own body).

---

## 2. Where the owner column lives: side table vs widened stride

### 2.1 The measured cost of widening

`design/drivers/cascade-restart.md` §2 argues, for the supervision link, that
*"the row is the thing that would have to be corrupted for the invariant to
break, so the row is where the invariant is enforced"* — an argument against
side tables. That argument is real and it is the reason this section exists
rather than a one-line decision.

Widening the descriptor to 32 bytes was measured, not estimated. A mechanical
classification of every `cap_table` base reference in the tree finds **136
sites across 36 files**, in three forms:

| form | sites | shape |
|---|---|---|
| V — variable slot | 71 | `mov rax, cap_table; shl rX,3; shl rY,4; add` |
| C — constant slot | 30 | `mov rax, cap_table; add rax, <slot*24>` |
| Z — slot 0 | 35 | `mov rax, cap_table` with no scaling |

Every one is hand-written assembly. A stride change edits 101 of them (V and
C), and a site missed reads a *different, live* descriptor rather than
faulting — the same class of failure #1589 already names, multiplied by a
hundred. `kernel_main.pdx` alone holds 42 references.

### 2.2 A parallel array indexed by the same key is not a side table

The cascade-restart §2 argument is about a table keyed on a **different**
identity with an **independent** lifetime: a supervision link stored
elsewhere could name a parent slot that had since been reallocated, and
nothing in either structure would say so. That is drift.

`cap_owner[256]` is not that. It is a **column split of one record** —
struct-of-arrays rather than array-of-structs:

- **same key** — indexed by `slot`, the identical index the descriptor uses;
- **same cardinality** — exactly `CAP_SLOT_MAX`, pinned by the build gate;
- **same lifetime** — a slot's owner is meaningful exactly while its
  descriptor's `kind` is non-zero, and both are written by the same call;
- **no independent allocation** — there is nothing to allocate, so there is
  nothing that can be allocated out of step.

Drift is possible only through a writer that updates one column and not the
other. There is exactly one such writer, `cap_mint_write`, and it becomes the
writer of both. That is a strictly smaller obligation than the 101-site edit,
and it is the obligation a build gate can actually discharge.

**Decision: side table.** `pub let mut cap_owner : [u64; 256]`, stride 24
preserved. This settles #1589 as **Option A**.

### 2.3 The invariant the split creates, and the discipline that holds it

The split has exactly one new failure mode and it must be named, because it
is the same leak #1587 exists to close, re-created one level down:

> If a slot is re-minted for a new holder and the owner column is not
> updated, the new capability is owned by the **previous** holder. A later
> sweep for that dead holder then revokes a live process's capability — the
> #1587 leak inverted into the worse failure that §1 of
> `process_death.pdx` warns about.

The discipline is therefore **not** "remember to clear the owner on revoke".
It is:

> **`cap_mint_write` unconditionally writes `cap_owner[slot] =
> CAP_OWNER_NONE`, on every mint, before returning.**

A mint is the only moment a slot changes hands. Clearing at mint makes stale
ownership unreachable by construction rather than by the diligence of every
revoke path — including the paths that clear a descriptor with three zero
stores and never call a revoke function at all, of which the tree has
several. Ownership is then stamped *after* the mint, by
`cap_owner_claim(slot, pid)`, which is a separate, audited step.

#### 2.3.1 The route a stale key actually arrives by (#1592)

The paragraph above is the design. #1592 showed that it was, for a while,
**only** the design: the instruction could be deleted and every test in the
14-mode matrix still passed, because no fixture reused a capability slot.
Every mint in the tree's witnesses went into a fresh slot whose column was
already `.bss`-zero, and clearing an already-zero column is indistinguishable
from not clearing it.

Writing the missing witness turned up something worth recording, because the
obvious version of it proves nothing:

> **A slot freed by an OWNER SWEEP has a clean column already.**
> `cap_revoke_slot` clears the column of every slot the sweep matched, on
> every path, including a refused per-kind revoke. So "mint for P, kill P,
> sweep, re-mint" leaves nothing for the mint's clear to do, and a witness
> built that way passes with the instruction deleted.

The route that does leave a stale key is the other axis:

> **THE LINEAGE CASCADES DO NOT TOUCH THE OWNER COLUMN.**
> `cap_owner` is written in exactly five files — `table.pdx`, `mint.pdx`,
> `owner.pdx`, `loader/seed_caps.pdx`, `driver/process_death.pdx` — and no
> per-kind revoke and no cascade is among them.

So when a capability is revoked because its *parent* died, its descriptor
goes and its owner column stays. If its holder was somebody other than the
parent's holder — which §2 of this document establishes is possible, because
ownership and lineage are independent relations — the freed slot now carries
a **live** process's key, and the next mint into it would hand the new
capability to that live process. When *it* dies, it takes a capability it
never held.

That is the concrete reachable path, in shipping code, with nothing
synthetic in it. `owner_sweep_synth.pdx` sub-test U builds exactly it: an
op-region root held by one process, a child derived from it held by a
second, the first dies, and the child's slot is re-minted and must come back
unowned. Deleting the clear fails it at stage 20.

---

## 3. Owner identity is `(pid, generation)`, never a bare pid

A bare pid as owner would be a bug, not a simplification. `pid_alloc` is a
dense-low-first scan and `pid_free` zeroes its slot with no aging, so a
reaped pid is handed to the very next `task_new`. A sweep keyed on the number
alone would eventually revoke a **live** process's capabilities — strictly
worse than the leak being fixed, and the exact reasoning
`design/drivers/process-death.md` §"A pid is not an identity" already
records.

Iter 53 (#1583) built `_pid_gen[64]` for this, with `pid_gen_bump` called
from `task_new` *before* the `_pid_table` publish, so a reader that resolves
a pid and then reads the generation can never straddle two incarnations.
**That mechanism is reused. No second one is invented.**

### 3.1 Encoding

```
cap_owner[slot] : u64
  bits [15:0]    pid          1 .. CAP_OWNER_PID_MAX-1   (0 reserved)
  bits [63:16]   generation   low 48 bits of _pid_gen[pid] (0 reserved)
```

`CAP_OWNER_PID_MAX = 64` is `pid_gen_read`'s own bound, chosen so the sweep's
domain is *exactly* the domain on which a generation is readable. A pid the
sweep would accept but `pid_gen_read` would refuse cannot exist.

48 bits of generation rather than the driver row's 16: the driver row
truncates because it had 16 bits of space in a 48-byte layout, and it says so.
A dedicated `u64` has room for the whole counter, so it takes as much of it
as the pid field leaves. A collision needs 2^48 incarnations of one pid.

### 3.2 The two sentinels, and why they cannot be confused

Requirement: some slots belong to no process, and some belong to the kernel,
and a sweep must match neither — nor may the two be confused with each other,
because "unowned" and "the kernel's own" are different facts about a slot.

```
CAP_OWNER_NONE   = 0x0000000000000000     pid 0,      gen 0
CAP_OWNER_KERNEL = 0xFFFFFFFFFFFFFFFF     pid 0xFFFF, gen 0xFFFFFFFFFFFF
```

`CAP_OWNER_NONE` is `.bss` zero, so an untouched slot reads as unowned
without an initialisation pass — which also means a slot cleared by any of
the tree's three-zero-store paths degrades to unowned rather than to some
process.

`CAP_OWNER_KERNEL` is all-ones. Its pid field is `0xFFFF`, which
`pid_alloc` — ceilinged at 64 — can never produce.

Neither can be matched, and the guarantee is **doubled deliberately**,
because a sweep that misses is a sweep that reports revocation that did not
happen:

1. **Value-level.** `cap_owner_pack(pid, gen)` returns `CAP_OWNER_NONE` for
   any refused input, so a valid key is never `0`; and a valid key's pid
   field is `< 64`, so it is never all-ones.
2. **Domain-level.** `cap_owner_sweep_revoke` refuses `pid == 0`,
   `pid >= CAP_OWNER_PID_MAX` and `gen & 0xFFFFFFFFFFFF == 0` *before
   scanning anything*. The kernel sentinel's pid is not in the sweep's
   domain at all, so it is not merely unmatched — it is unaskable.

Sub-tests G and H of the witness assert both, separately: that a sweep for
the kernel is refused up front, and that a live sweep leaves kernel-owned and
unowned slots byte-identical.

### 3.3 What the count means

`cap_owner_sweep_revoke` returns **the number of slots whose owner column
matched the key**, not the number of successful revokes. This is
order-independent by construction: if the sweep revokes a bus at slot 40 and
that bus's lineage cascade clears a slave at slot 41 that the same process
also owned, the sweep still counts slot 41 when it reaches it — the slot was
held by the dead process, which is the question being answered. Revokes are
idempotent, so the second visit returning `*_REVOKE_ALREADY` is not an error
and is not reported as one.

---

## 4. #1589: the struct stops lying

**Option A, taken.** `struct Capability` now declares exactly the three
fields that have storage:

```
struct Capability { kind: u64, rights: u64, target_ptr: u64 }
```

`generation` and `flags` are gone. At stride 24, `generation`'s declared
offset `+24` was the **next descriptor's `kind`** — and `kind` is the first
thing every gate checks, so the corruption would have presented as an
unrelated capability changing type, far from its cause.

Both TODOs that instructed a contributor to step on that mine are corrected:

- `mint.pdx:44` — *"Initialize descriptor fields (kind, target_ptr, rights,
  generation, flags)"* → the three real fields, plus the owner-column clear.
- `revoke.pdx:36` — *"fetch descriptor, increment generation (wrapping within
  4-bit), write back"* → replaced by the real dispatch, and by §4.1.

### 4.1 What replaces the generation-based stale-handle defence

**Nothing, and that is recorded rather than papered over.** Handle reuse is
**not currently defended** at the capability layer. A handle whose slot has
been revoked and re-minted resolves to the new capability, and the only thing
standing between a caller and the wrong object is the `kind` check that every
gate performs — which catches a re-mint to a *different* kind and does not
catch a re-mint to the same one.

Three things make this an acceptable state to record rather than an urgent
one to fix, and one of them is new as of this change:

1. The five derived kinds do not hand out raw handles; they take a **slot**
   and re-derive the row from the descriptor on every call. A stale slot
   fails the kind check or the `*_tail_valid` row check.
2. `cap_revoke`'s handle decode masks to bits `[7:0]`, so a "handle" is a
   slot number today; there is no generation field in it to check against.
   Restoring a generation defence means changing the handle layout
   (`design/capabilities/handle-layout.md`), not adding a table column.
3. **New:** the owner column now makes a re-minted slot detectably
   *un*-owned until claimed (§2.3), which does not defend a stale handle but
   does stop a stale *sweep* from acting on one.

This is filed forward, not resolved here.

### 4.2 The `[cap-stride]` gate

In the shape of the existing `[gpio-pin-confine]` and `[fw-session-confine]`
arity pins, in `tools/build.sh`, so a future divergence is a **build
failure** rather than a memory-corruption bug. Five independent halves:

1. **Declarations.** `cap_table : [u64; 768]`, `cap_owner : [u64; 256]`, and
   the three constants `CAP_SLOT_MAX = 256`, `CAP_DESC_BYTES = 24`,
   `CAP_TABLE_U64S = 768` must appear verbatim in `table.pdx`.
2. **The identity.** `CAP_SLOT_MAX * CAP_DESC_BYTES == CAP_TABLE_U64S * 8`
   is evaluated in the gate. This is exactly the equation #1589's mine
   violates: a struct widened without the array, or an array widened without
   the stride, breaks it.
3. **The phantom fields stay gone.** The `struct Capability` block must not
   contain `generation` or `flags`.
4. **Every site.** All 136 `cap_table` base references in `src/` and
   `tests/` are classified as V, C or Z (§2.1). A `shl` amount other than
   `{3,4}`, or a constant byte offset that is not a multiple of 24, or a
   site that matches none of the three forms, fails the build and names the
   file and line. A vacuity guard fires if the classifier finds fewer than
   60 V-form, 20 C-form or 120 total sites, so a refactor that makes the
   pattern stop matching cannot make the gate pass by scanning nothing.
5. **What is dereferenced from the base (#1591).** Halves 1–4 police how a
   descriptor *address is computed* and say nothing about the offsets then
   used through it. That is not a theoretical gap: a single stray
   `mov [rax + 24], rdx` appended after a correct base computation and a
   correct three-word write passed all four halves with exit 0, while
   corrupting the next descriptor's `kind` — #1589's exact failure shape,
   reached without touching `table.pdx` at all. Half 5 walks forward from
   each classified site, follows the register holding the computed base, and
   checks every constant offset dereferenced through it: **V** sites are
   pinned to `{0, 8, 16}`, because a variable-slot base reaching past its
   own descriptor lands on a slot nobody chose; **C** and **Z** sites, whose
   base names a constant slot, are bounds-checked only (8-byte aligned, and
   inside the table), because from a slot-aligned constant base every
   multiple of 8 is legitimately *some* descriptor's field and no arithmetic
   can separate deliberate from accidental. A register-indexed dereference
   through a tracked base is refused for every form and needs an explicit
   `// [cap-stride-ok: <reason>]` annotation; the tree currently needs none.

Half 5 is a **bounded scan, not a dataflow analysis**, and the gate's own
header enumerates what it cannot see — writes after a `call`, past a label,
beyond an 80-line window, or through a base that was parked in memory. The
bound is written down there rather than left to be discovered, which is the
lesson #1591 taught about half 4.

Non-vacuity of each half is demonstrated by mutation; the induced failures
and their tags are recorded in the commit message. Half 5 has its own
vacuity floor (120 V-form dereferences, 240 total) for the same reason half
4 does: its walk has several stop conditions, and a change that made it stop
immediately everywhere would leave it passing without inspecting anything.

---

## 5. Where ownership is stamped

| stamper | slots | owner written |
|---|---|---|
| `cap_mint_write` | every mint | `CAP_OWNER_NONE` (unconditional clear) |
| `loader_seed_caps(sidecar, task_ptr)` | a loaded process's seeded caps | `(task->pid, pid_gen_read(pid))` |
| `cap_owner_claim(slot, pid)` | supervisor-granted caps | `(pid, pid_gen_read(pid))` |
| `cap_owner_claim_kernel(slot)` | kernel-held caps | `CAP_OWNER_KERNEL` |

`loader_seed_caps` is the wire-in that matters, and it closes a loose end
rather than opening one: the function has threaded a `task_ptr` argument
since R20b.M4-002 and done nothing with it, with the comment *"task_ptr
threaded through for R21+ per-task cap_tables … unused at R20b"*. It is now
used for exactly the thing the argument was reserved for — associating the
minted capability with the task it was minted for — without waiting for
per-task CSpaces to exist.

`task_ptr == 0` (the boot witness's own call) stamps nothing and leaves
`CAP_OWNER_NONE`, which is correct: caps seeded with no task are the
kernel's, not some process's.

---

## 6. Per-task CSpaces are not this change

#1587 lists per-task CSpaces as the most principled option — ownership stops
being a field and becomes the structure — and
`design/capabilities/per-task-cspace.md` is referenced from four files and
does not exist.

That is still true and this change does not pretend otherwise. It is
deliberately deferred, for one reason: a per-task CSpace changes the *type*
of every capability-taking function in the kernel, because a slot number
stops being globally meaningful. The owner column is a column; the CSpace is
a re-typing. Doing the re-typing to answer "which capabilities did P hold"
would be answering a question about revocation by rewriting the addressing
model, and this round has a bubble to isolate.

What this change buys the CSpace work when it happens: the owner column is
the *migration oracle*. When per-task tables land, every slot's owner says
which task's table it should have gone into, and a slot whose owner is
`CAP_OWNER_NONE` is one the migration has to make a decision about
explicitly.

---

## 7. Reassessment of #1086 (ACPI bubble crash isolation, P2)

`design/acpi/crash-isolation.md` §3.4 P2 asks for: one bubble death revoking
`KIND_OP_REGION` (0x150), `KIND_I2C_BUS` (0x152), `KIND_I2C_SLAVE` (0x153),
`KIND_GPIO_LINE` (0x154) and `KIND_FW_SESSION` (0x155) **together**, each
with a ghost-row sweep in the shape of
`gpio_line_cascade_revoke_by_controller` phase 2 and
`tests/kernel/cap/gpio_cap_synth.pdx` sub-test L.

With §1–§5 in place that witness is writable, and
`tests/kernel/cap/owner_sweep_synth.pdx` writes it. See §8 of that file's
header for the sub-test map. What it asserts:

- one `driver_death_notify(pid)` revokes all five kinds held by that pid, in
  one call, with no per-kind trigger;
- OpRegion transitivity survives — a grandchild window derived two levels
  below an owned root is revoked, by fixed point, not recursion;
- the ghost-row sweep runs for each kind: a row left allocated with no
  descriptor pointing at it is reclaimed, so a dead bubble cannot leave a pin
  held or an I²C address unmintable;
- a stale `(pid, generation)` — live pid, dead generation — matches nothing;
- `CAP_OWNER_KERNEL` and `CAP_OWNER_NONE` slots are untouched, and the sweep
  for either is refused before it scans;
- **a re-minted slot does not inherit the previous holder's key** (sub-test
  U, added by #1592) — the slot is freed by a *lineage* cascade, which leaves
  the column set, and the re-mint must clear it or a later sweep destroys a
  live, unrelated capability. See §2.3.1.

One correction to that witness's own narrative, made by #1592. Its header
said six owned slots were swept while **nine** descriptors were cleared, the
extra three being the OpRegion child, the OpRegion grandchild, and the second
I²C slave. The number is **eight**. The I²C slave's descriptor was already
null before the composed death — the fixture ghosts it at sub-test I as
scaffolding for sub-tests N and O, and sub-test N's own comment says so — so
the death cleared no descriptor there. What the death reclaims at that slot
is its *row*, which is a different fact and is sub-test N's subject. Two
lineage-cleared descriptors and one lineage-reclaimed row. Every individual
assertion the fixture made was true; the sentence summarising them was not,
and the assertion offered as evidence for the ninth (`kind == 0` on a slot
already zeroed two sub-tests earlier) was true and empty. It has been
replaced by the assertion that carries the argument: the two lineage-cleared
slots read `CAP_OWNER_NONE`, so the owner axis demonstrably never touched
them.

**What remains outside the witness**, and therefore what #1086 must still be
read as not covering: the bubble is a *synthetic* death driven through
`driver_death_notify` and `fault_ring3_death_check` with a fabricated ring-3
trap frame, exactly as #1583's witness does. A genuine CPU-raised fault from
a real `acpi_supervisor` process arriving at the handler is still unwitnessed
— the same gap recorded in `design/drivers/process-death.md` §7, and it is a
gap in the *arrival*, not in the revocation. `ChannelDead`-to-clients and
auto-restart are #1583's witness (sub-tests H and I) and are not re-asserted
here.

---

## 8. Files

| file | role |
|---|---|
| `src/kernel/core/cap/table.pdx` | the 3-field struct, the three pinned constants, `cap_owner[256]`, the two sentinels |
| `src/kernel/core/cap/owner.pdx` | `cap_owner_pack` / `_set` / `_get` / `_claim` / `_claim_kernel` / `_clear`, `cap_revoke_slot`, `cap_owner_sweep_revoke` |
| `src/kernel/core/cap/mint.pdx` | `cap_mint_write` clears the owner column; TODO corrected |
| `src/kernel/core/cap/revoke.pdx` | `cap_revoke` delegates to `cap_revoke_slot`; TODO corrected. **Currently has no caller** — see below |
| `src/kernel/core/loader/seed_caps.pdx` | stamps `(pid, gen)` from the previously-unused `task_ptr` |
| `src/kernel/core/driver/process_death.pdx` | `driver_death_notify` runs the sweep between steps 1 and 2 |
| `tools/build.sh` | invokes the `[cap-stride]` gate |
| `tools/verify-cap-stride.sh` | the gate itself, five halves (§4.2) |
| `tests/kernel/cap/owner_sweep_synth.pdx` | the composed five-kind witness, plus the slot-reuse witness (§2.3.1) |

### 8.1 `cap_revoke(handle)` is unreachable, and that is stated rather than implied

`cap_revoke` gained a real body in #1589 and, as of #1592, **has no caller
anywhere in `src/kernel/`**. There is no `call cap_revoke` in the tree; the
only invocations are direct calls from witnesses. Every revocation the
running kernel performs enters one layer down at `cap_revoke_slot` — from
`cap_owner_sweep_revoke` on process death, from each kind's own audited
revoke, or from a lineage cascade.

It is recorded because the gap between *has a real body* and *is exercised by
the system* is precisely the gap that lets a function rot: witness calls
cover the body, so no gate complains, while nothing in production depends on
it being right. A function with a real body and no caller reads as live code
and is not.

**What would make it reachable:** a syscall that takes a *handle*. The five
derived kinds all take a slot and re-derive their row from the descriptor on
every call, so none of them route through it. A handle-taking revoke syscall
needs §4.1's handle-layout question settled first — a handle today is bits
[7:0] with nowhere to put a generation, so `cap_revoke(h)` cannot distinguish
a live capability from a stale handle to a re-minted slot. Wiring it up ahead
of that decision would ship the ambiguity rather than resolve it.
