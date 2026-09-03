# PWP minor-version bump cadence + capability advertisement rules

**Status:** Wave-0 Batch-7 authoritative amendment policy. G7.M7-002.
**Issue:** paideia-os#2272 (`G7-M7-002`), milestone `g7-compositor-protocol`.
**Depends on:** G7-M7-001 (no-extension-policy, paideia-os#2271) — the freeze this cadence amends.
**Adjacent:** G7-M1-004 (freeze-review record, paideia-os#2245) — the review discipline this cadence re-runs on every bump.
**Date:** 2026-09-03.
**Scope:** the sole amendment channel PWP admits. Names the version shape, the cadence bounds, the wire capability-advertisement rules, what counts as additive, and the amendment review record every bump produces. This document is the operational form of [`no-extension-policy.md`](./no-extension-policy.md) §3.

Related documents (read-only from this doc's viewpoint):
- `design/compositor/no-extension-policy.md` — the ban this cadence amends around; §3 points here for the how.
- `design/compositor/pwp-spec-vocabulary.md` §2 (kind catalogue), §5 (freeze commitment), §6 (downstream-consumer list touched at every bump).
- `design/compositor/pwp-spec-freeze-review.md` (paideia-os#2245, planned) — the freeze-review record shape re-run at every minor bump.
- `design/compositor/pwp-spec-wire.md` (paideia-os#2243, planned) — the opcode table that grows only at minor bumps.
- `MASTER_PLAN.md` §10.3 — the serialization-point discipline every bump lands under.

---

## §1. Motivation

The no-extension policy (G7-M7-001) forecloses every wire path that would grow PWP incrementally: no `wp-*` / `zwp-*` / `xdg-*` / `ext-*` namespace, no runtime capability probe, no compositor-minted KIND ordinals, no "SHOULD-implement" opcodes, no draft / experimental / staging protocols, no compositor-implementation-specific opcodes. That leaves **one** amendment channel — the minor-version bump — and cites this document as its owner.

Without a written cadence, the one remaining channel becomes ad-hoc: a bump when a maintainer feels like it, a bump when a hardware round demands it, a bump when a client team pressures. Ad-hoc bumps have the same interop-matrix cost as Wayland extensions, only slower to accumulate. This document writes down the cadence, the bounds, the acceptance rules, and the review record so the one path forward stays boring.

---

## §2. Versioning shape

The version is a two-integer tuple `PWP-<major>.<minor>`. Both integers are unsigned; both start at 1. There is no third component (no patch level), no pre-release identifier (no `-alpha`, `-beta`, `-rc`), no build metadata (no `+sha`). Fixes ride the next minor bump; there is no `2.3.1`.

- **MAJOR bump.** Wire-incompatible. Cited when a survivable design bug cannot be repaired within the current framing — a byte-order reversal, a header-format change, an opcode renumbering that cannot ride an additive slot, a KIND removal that cannot ride deprecation. Under the no-extension discipline the connection-time REFUSE is the sole cutover mechanism (see [`no-extension-policy.md`](./no-extension-policy.md) §4.2, "Retiring a wire capability is a major-version bump").
- **MINOR bump.** Additive-only. See §5 for what "additive" means and does not mean. Every opcode, KIND ordinal, RIGHTS bit, and row-tail field present at PWP-`<M>`.`<N>` retains its exact meaning at PWP-`<M>`.`<N+1>`; the delta is a suffix, never a rewrite.

Existing wire slots — KIND ordinals, opcode numbers, RIGHTS bit positions, row-tail field offsets — NEVER change semantics across minor bumps. Renumbering, redefinition, or removal is a major event.

---

## §3. Cadence

- **Floor: one minor per year (aggregate).** If a year passes without accumulated additive candidates that meet the acceptance bar of §5 and the review bar of §6, no bump happens. The floor is a permission, not a mandate; empty bumps are refused at review as documentary drift. The upper bound on inaction is the review-window cadence of §6, not this floor.
- **Ceiling: four minors per year.** Faster than quarterly and downstream clients thrash their capability tables — a toolkit that must retest against PWP-2.7, 2.8, 2.9, 2.10 in one calendar year is being asked to pay Wayland-shape interop costs at a slower rate but no smaller area. The ceiling is enforced at review: a fifth minor within twelve months is refused unless the reviewer record explicitly cites a survivable interop bug that cannot wait.
- **Major cadence: one per decade or on a survivable design bug, whichever comes first.** The aim is zero — the no-extension policy exists so that a major bump is a rare event, not a scheduled one. Every major bump requires an RFC arguing why the survivable-bug threshold was met and re-runs the entire freeze-review discipline (G7-M1-004) end to end, not just the delta.

The cadence is deliberately narrow: the floor is one, the ceiling is four, and the median expectation across a decade is roughly two minors per year on hardware-generation cadence with occasional dry years.

**Trigger.** A minor bump is triggered when an in-tree RFC folder — `design/compositor/rfcs/pwp-<major>.<minor>/` — accumulates at least one accepted RFC and the cadence bounds above permit. Accepted RFCs sit in that folder between review windows; a bump lands when a review window opens and the folder is non-empty. Review windows open at roughly quarter cadence but are not scheduled; a maintainer opens one by filing a `pwp-minor-review-<N>.md` skeleton against the accumulated folder (see §6). Nothing forces a window open on an empty folder; nothing forces a folder to accumulate on a schedule. The cadence is demand-driven within its bounds, not calendar-driven.

---

## §4. Capability advertisement rules

The wire capability-advertisement channel is the connection-time version tuple, and nothing else. There is no in-band capability probe message at any minor version (this is [`no-extension-policy.md`](./no-extension-policy.md) §3, rejection criterion 2, re-affirmed here).

**Hello frame.** Every PWP connection opens with a `PWP_HELLO` frame whose FIRST field is the two-integer `(major, minor)` tuple. No other field precedes it; parsers refuse a frame that does not carry the tuple in that position.

**Server response.** The server replies with exactly one of:
- `PWP_HELLO_ACCEPT(server_major, server_minor)` — connection proceeds; the client MUST honour §4.1/§4.2 depending on how the two tuples relate.
- `PWP_HELLO_MAJOR_MISMATCH(server_major, server_minor)` — the server does not implement the client's major. The connection closes. There is no cross-major fallback; a client that must speak multiple majors opens independent connections at each major tag.
- `PWP_HELLO_MINOR_TOO_NEW(server_major, server_minor)` — the client asked for a minor the server does not carry within the shared major. The connection closes. The client MAY reconnect at a lower minor if its compile-time feature requirements permit.

There is no fourth response. There is no negotiation, no counter-offer, no capability list.

### §4.1 Client at minor N encounters server at minor M < N (within the same major)

Connect succeeds via `PWP_HELLO_ACCEPT`. The client MAY use only opcodes, KIND ordinals, and RIGHTS bits present at the server's minor M. The client SHOULD gate every feature use on a compile-time-known minimum-minor constant for that feature; using a feature above M is a client bug, not a wire negotiation. The wire rejects an out-of-range opcode as a framing violation (no "unrecognised opcode, skip" behaviour, per [`no-extension-policy.md`](./no-extension-policy.md) §5 layer 1).

### §4.2 Client at minor N encounters server at minor M > N (within the same major)

Connect succeeds. The client uses opcodes from its own N. The server MUST accept every opcode at every minor at-or-below its own M within the same major — this is the additive-only guarantee of §2, enforced wire-side.

### §4.3 Compile-time only

There is no capability-probe wire message at any minor version. Toolkits that need to gate on a feature do so at compile time against the minimum-minor constant that feature was added at, and the runtime check is the version tuple at hello time. The rule is the same at PWP-2.1 and PWP-2.99: the tuple carries every question a client is allowed to ask about server capability.

---

## §5. What counts as additive

A change is **additive** — and therefore admissible for a minor bump — if and only if it belongs to one of the following four shapes:

1. **A new `KIND_*` entry** in `pwp-spec-vocabulary.md` §2, minted from an ordinal reserved through the monorepo-serialized cap-kind allocation authority (`design/architecture/next-wave-derived-kinds.md`, per MASTER_PLAN §10.2).
2. **A new RIGHTS bit** on an existing KIND, occupying a previously-unused bit position in the rights word.
3. **A new opcode number** in the wire framing, occupying a previously-unused opcode slot. The opcode's meaning at this minor is its meaning at every subsequent minor within the major.
4. **A new field appended** to an existing struct that carries a size-and-version prefix, with the size prefix growing to accommodate. Existing readers at earlier minors truncate at the earlier size prefix; new readers dispatch on the current-minor size and read the appended field.

A change is **not additive** — and therefore requires a MAJOR bump, not a minor — if it belongs to any of the following:

1. Renumbering an opcode, a KIND ordinal, or a RIGHTS bit position.
2. Changing the meaning of an existing opcode, KIND slot, or RIGHTS bit.
3. Removing a KIND, an opcode, or a RIGHTS bit — even one no client uses.
4. Changing wire framing structure (byte order, header layout, length-prefix width, alignment).
5. Changing the semantics of an existing row-tail field, or reordering existing fields inside a row-tail schema.
6. Changing the linearity discipline of an existing KIND (linear → non-linear or vice versa).

The line between "new field on an existing struct" (additive) and "changing the meaning of an existing field" (major) is drawn at the size-and-version prefix: appending past the current prefix is additive; touching a byte at or below the current prefix is major.

### §5.1 Worked example — an additive that lands under this policy

Suppose PWP-2.7 is in the field and a hardware round exposes a new per-plane HDR peak-luminance clamp (the same worked example [`no-extension-policy.md`](./no-extension-policy.md) §3.1 uses). The change appends a `peak_nits` field inside the `KIND_HDR_METADATA` row-tail carried by `KIND_SURFACE`. The row-tail's size-and-version prefix grows from 128 to 132 bytes. Under this policy the change qualifies as additive by shape 4 of §5 (new field appended to a size-and-version-prefixed struct); the delta reserves no new KIND, no new opcode, no new RIGHTS bit. `PWP_MINOR` bumps from 7 to 8. Existing PWP-2.7 clients continue to connect and the server truncates the outbound row-tail to 128 bytes on their frames; PWP-2.8 clients read the 132-byte row-tail. A `pwp-minor-review-8.md` record lands in the same PR and walks the ten-item no-extension checklist against the delta. No wire semantics changed; the interop matrix picks up one column, not one axis.

---

## §6. Amendment review

Every minor bump produces exactly one in-tree review record: `design/compositor/pwp-minor-review-<N>.md`, where `<N>` is the target minor within the current major (e.g. `pwp-minor-review-8.md` for the PWP-2.7 → PWP-2.8 bump). The record MUST contain, verbatim, four sections:

1. **The delta.** Every additive change landing at this minor, cited by KIND name / opcode number / RIGHTS bit / row-tail field.
2. **The rationale.** For each change, the hardware round, interop bug, or client-team RFC that motivated it; each rationale is a link to the originating monorepo issue or design document.
3. **The re-affirmation.** An explicit statement that this minor bump complies with the no-extension policy — a walk-through of the ten-item review checklist from [`no-extension-policy.md`](./no-extension-policy.md) §5.1 against the delta, with each item's answer recorded.
4. **The downstream-consumer delta.** A list of every consumer named in `pwp-spec-vocabulary.md` §6 that this bump touches, cross-linked to the concurrent PR that updates each one (MASTER_PLAN §10.3 serialization requirement).

Cross-links every review record carries by name:
- Freeze-review record — G7-M1-004, `design/compositor/pwp-spec-freeze-review.md` (paideia-os#2245).
- No-extension policy — G7-M7-001, [`design/compositor/no-extension-policy.md`](./no-extension-policy.md).
- Vocabulary index §2 — `design/compositor/pwp-spec-vocabulary.md`.
- Wire spec — G7-M1-002, `design/compositor/pwp-spec-wire.md` (paideia-os#2243).

Absence of any of the four sections is a rejection reason at review. A review record that lands without a corresponding minor bump in the wire spec, the vocabulary index, or the reference `svc-compositor` implementation — or any bump that lands without the review record — is documentary drift, refused at MASTER_PLAN §10.3 serialization.

---

## §7. Related work

- **Semantic Versioning** (semver.org, 2.0.0) — the widely-known baseline. PWP diverges by dropping the patch component (fixes ride minor bumps), dropping pre-release identifiers (draft namespaces are foreclosed by G7-M7-001), and treating the wire itself — not an API surface — as the versioned artefact. Cited so RFC authors coming from application-versioning conventions have the divergence in one place.
- **Wayland protocol versioning per-global** — the counterexample. Wayland versions each `wl_*` / `wp-*` / `zwp-*` / `xdg-*` / `ext-*` global independently, at that global's own cadence, negotiated at `wl_registry` bind time. The result is the fragmentation catalogued in [`no-extension-policy.md`](./no-extension-policy.md) §6.1. PWP's single-tuple discipline exists to foreclose exactly this axis multiplication.
- **HTTP versioning (0.9 → 1.0 → 1.1 → 2 → 3)** — an example where a single connection-time version tuple carried real feature additions across decades. HTTP/1.1 relative to HTTP/1.0 added chunked transfer encoding, persistent connections, host headers, cache-control semantics; each an additive change under a whole-protocol version bump rather than a per-feature extension namespace. PWP's minor cadence is shaped after HTTP's episodic minor-bump discipline, not after semver's per-fix patch cadence.
- **SPKI/SDSI capability certificate versioning** (RFC 2693) — the cap-oriented precedent. SPKI versions the certificate format monotonically and treats capability semantics as fixed at each version; new capability shapes ride new versions rather than optional certificate extensions. PWP's KIND-catalogue-per-minor discipline is the compositor-layer analogue.
- **Fuchsia FIDL API-level versioning** — see [`no-extension-policy.md`](./no-extension-policy.md) §6.4. FIDL's single-axis compatibility discipline is the closest modern comparable to the version-tuple channel §4 writes down.

---

*End of minor-version cadence. Freeze the wire, bump the tuple, record the review — no other path exists.*
