# PWP protocol freeze-review record + sign-off gate

**Status:** Wave-0 authoritative process record. G7-M1-004.
**Issue:** paideia-os#2245 (`G7-M1-004`), milestone `g7-compositor-protocol`.
**Round:** G7. **Size:** S.
**Depends on:** G7-M1-001 (vocabulary index, #2242, landed), G7-M1-002 (wire spec, #2243, planned), G7-M1-003 (lifecycle spec, #2244, planned).
**Feeds:** every G7-M2..M8 primitive already landed (see §6), and every future minor/major bump (G7-M7-002, #2272).
**Date:** 2026-09-05.
**Scope:** defines what a PWP protocol "freeze" is, what triggers a mandatory review, the 21-day review window, the two-approval sign-off gate, and the Change Log this file accumulates for every reviewed change from this point forward. This is the R1 mitigation gate named in `next-wave-synthesis.md` §7 (compositor protocol calcification, Irrecoverable / High).

Related documents (read-only from this doc's viewpoint):
- `design/compositor/pwp-spec-vocabulary.md` — the frozen kind catalogue (§2) and the freeze plan pointer (§5) that names this document.
- `design/compositor/no-extension-policy.md` — the single-protocol discipline this freeze defends; §5.1 supplies the ten-item checklist this review reuses.
- `design/compositor/pwp-version-cadence.md` — the minor/major bump cadence that re-runs this review's discipline on every future amendment (G7-M7-002, #2272).
- `MASTER_PLAN.md` §10.3 — the version-bump + submodule-bump serialization discipline every sign-off lands under.

Naming note for the record: this document was initially filed at `pwp-protocol-freeze-review.md` per the dispatch prompt, then renamed to `pwp-spec-freeze-review.md` at batch close to match the path every sibling document (and the issue body for #2245) already cited. No cross-references were changed — they were correct all along.

---

## §1. Purpose

**What a "freeze" is.** A freeze is the state a PWP surface enters once its defining document is signed off: the kind catalogue (`pwp-spec-vocabulary.md` §2), the wire framing and opcode table (`pwp-spec-wire.md`, planned), and the atomic-commit lifecycle machine (`pwp-spec-lifecycle.md`, planned) are each fixed at that point. A frozen surface does not change except through the review discipline this document defines. Freezing is not a one-time event for the whole protocol — it is a state each of the three M1 surfaces enters independently, and it is what the minor-version cadence (`pwp-version-cadence.md`) amends around rather than through.

**What "review" means.** A review is the 21-day, two-approval process defined in §3–§4 below, run against a specific proposed change to a frozen surface. A review is not a design conversation; the design conversation (RFC drafting, prototyping, discussion) happens before a review opens. The review itself is a fixed-window, recorded, sign-off gate — its output is either a Change Log entry (§5) recording the change as accepted, or a closed review with no entry (rejected, or withdrawn).

**What triggers a review.** Any candidate change in one of the five categories of §2 against a frozen PWP surface. A change that does not fall into one of those five categories — an implementation detail inside `svc-compositor` that touches no wire-visible kind, opcode, or schema — does not trigger this gate; ordinary code review suffices. The dividing line is wire-visibility: if a client compiled against the old surface would observe a difference (a new capability, a renumbered slot, a reinterpreted byte), the change is in scope for this gate.

This document is deliberately narrow relative to its two siblings. `pwp-spec-vocabulary.md` owns *what* is frozen (the kind catalogue); `no-extension-policy.md` owns *why* nothing may be added outside a governed channel and supplies the ten-item rejection checklist; this document owns *how* a governed change actually moves from proposal to landed fact — the window, the gate, and the ledger. A reviewer who wants to know whether a specific change is even eligible reads the no-extension policy first; a reviewer who wants to know how long to wait and whom to ask reads this document.

This gate exists because pitfall P11 (`next-wave-synthesis.md` §4) identifies protocol proliferation as the single highest-risk failure mode in the compositor stack, and risk register row R1 (`next-wave-synthesis.md` §7) rates the damage of unmitigated calcification as **Irrecoverable** at **High** probability. The no-extension policy (`no-extension-policy.md`) forecloses every incremental-extension escape hatch; the freeze-review gate is what makes the one remaining channel — the minor/major version bump — a governed process rather than an ad-hoc one.

---

## §2. Change categories requiring review

A candidate change requires a freeze review if it falls into any of the following five categories. These are the wire-visible change shapes; they are the categories the no-extension policy's ten-item checklist (`no-extension-policy.md` §5.1) is run against at every review.

**(a) Opcode add / remove / renumber.** Any change to the wire opcode table (`pwp-spec-wire.md`, once landed): a new opcode occupying a previously-unused slot, removal of an existing opcode, or renumbering an opcode to a different slot. Addition is the only shape that can qualify as additive under a minor bump (`pwp-version-cadence.md` §5); removal and renumbering are always major-bump events.

**(b) Wire-framing change.** Any change to byte order, header layout, length-prefix width, alignment, or the overall frame structure carried by every PWP message. Framing is the layer beneath the opcode table; a framing change invalidates every existing parser regardless of which opcodes it emits, and is always a major-bump event (`pwp-version-cadence.md` §5, non-additive item 4).

**(c) Capability-schema break.** Any change to a `KIND_*` entry's row-tail schema (`pwp-spec-vocabulary.md` §2), a RIGHTS bit's meaning, or a KIND's linearity discipline (§4 of the vocabulary index) that is not a pure size-and-version-prefixed append. Appending a new field past an existing size prefix is additive (§5 shape 4 of the cadence document) and may qualify for a minor bump; touching a byte at or below the current prefix, reinterpreting an existing field, or flipping a KIND's linearity is a break and is always a major-bump event.

**(d) Event-vs-request re-classification.** Any change that moves a wire message from client-request to compositor-event or vice versa, or that changes a message's directionality (unidirectional to bidirectional, single-response to stream-shaped as `KIND_PRESENT_FEEDBACK` is). This category exists separately from (a) because a message can keep its opcode number and payload shape while its protocol role changes underneath a client — the two Wayland-shape failure modes (silent reclassification, and outright renumbering) are distinguished here because they carry different client-visible symptoms and different review questions.

**(e) Sub-range boundary shift.** Any change to a reserved-range boundary that a KIND ordinal allocation, an opcode block, or a RIGHTS-bit block claims in `next-wave-derived-kinds.md` or `pwp-spec-wire.md`. Shifting a boundary can silently invalidate an allocation another in-flight change assumed was stable — this is the sub-range analogue of (a)'s renumbering risk, called out separately because it is caught by grepping range tables, not opcode tables, and reviewers checking only (a) miss it.

A change spanning more than one category is reviewed once, against the union of the categories it touches; the Change Log entry (§5) cites every category the change falls under.

---

## §3. Review window

Every review that opens under §2 runs a **21 calendar-day window**, measured from PR-open (the RFC or diff is posted against the frozen surface it amends) to merge. The window is not extendable and not shortenable by reviewer consensus — a change that gathers two approvals on day 3 still waits until day 21 to merge. The fixed floor exists so that a review's visibility window does not depend on how quickly the first two reviewers happen to respond; a silent stakeholder who would object has three weeks of calendar time to appear regardless of how fast the nominal approvers act.

**Parallel reviews are permitted.** Multiple independent changes — even ones touching the same frozen surface, provided their diffs are disjoint per the MASTER_PLAN §10.5 file-disjoint dispatch invariant — may have open review windows concurrently. Each review's 21-day clock runs independently from its own PR-open date. A review is not blocked from opening because another review is already in its window; the constraint is on merge ordering (MASTER_PLAN §10.3 serialization, applied at merge time, not at review-open time), not on review concurrency.

**Withdrawal.** A review may be withdrawn by its author at any point before merge; a withdrawn review closes without a Change Log entry and does not count against the minor-bump ceiling (`pwp-version-cadence.md` §3).

**Expiry.** A review that has not gathered the required two approvals (§4) by day 21 does not auto-merge and does not auto-reject; it stays open past day 21 until either the sign-off gate is met or the author withdraws it. The 21-day figure is a floor on review visibility, not a ceiling on review duration.

---

## §4. Sign-off gate

A change may merge only once it holds **2 approvals**, of which **at least 1** is from a paideia-os core reviewer, **and** the 21-day window (§3) has elapsed. Both conditions are required; satisfying one early does not waive the other.

**Core reviewer.** A paideia-os core reviewer is a person (or, for an autonomous loop, the designated review agent role for the session) with standing write authority over `design/compositor/` and `src/user/compositor/` — the same authority MASTER_PLAN §10.1 vests in whoever holds single-authority sign-off over a design doc's home directory. This document does not separately enumerate named reviewers; the roster is whoever currently holds that authority per the project's standing governance, and is out of scope for a protocol-review record to duplicate.

**Approval scope.** An approval on a freeze review is an explicit statement that the reviewer has run the no-extension-policy ten-item checklist (`no-extension-policy.md` §5.1) against the diff and recorded a per-item answer, not a bare "LGTM." A review missing a checklist walk-through from at least one approver is incomplete regardless of approval count.

**Merge is the Change Log write.** The act of merging a signed-off review is, in the same PR, the act of appending its Change Log entry (§5) to this file. A change that merges without a corresponding entry — or an entry that appears without a corresponding merge — is documentary drift, rejected at MASTER_PLAN §10.3 serialization, identical to the drift condition `pwp-version-cadence.md` §6 defines for minor-bump review records.

**Rejection.** A review that gathers an explicit objection from a core reviewer does not merge regardless of approval count elsewhere, until the objection is withdrawn or the diff is revised to address it. There is no override vote; a single standing core-reviewer objection is a hold, not a minority position to be out-voted. A rejected review closes the same way a withdrawn one does (§3) — no Change Log entry, no count against the minor-bump ceiling.

### §4.1 Worked example — a review walkthrough

Suppose an RFC proposes appending a `peak_nits` field to the `KIND_HDR_METADATA` row-tail carried by `KIND_SURFACE` (the same worked example `no-extension-policy.md` §3.1 and `pwp-version-cadence.md` §5.1 use). The PR opens day 0 against `pwp-spec-vocabulary.md`, citing category (c) — a capability-schema change, additive-shaped per the size-and-version-prefix test. A core reviewer runs the ten-item checklist by day 4, confirms all ten answers land on the required side, and approves with the checklist recorded inline. A second reviewer approves by day 9. Both approvals stand on day 9, but the PR does not merge until day 21, because the fixed window (§3) does not shorten for early consensus. On day 21 the PR merges, and the same commit appends the Change Log entry — affected: `KIND_HDR_METADATA.peak_nits`; category: (c); PR link; two approvers; one-sentence rationale citing the hardware round that motivated it.

---

## §5. Format of a Change Log entry

Every entry in §7 uses exactly this five-field shape, in order:

```
### <date, YYYY-MM-DD>
- **Affected:** <opcode number(s) / KIND name(s) / schema field(s), by exact name>
- **Category:** <one or more of (a)-(e) from §2>
- **PR:** <link>
- **Approvers:** <name/handle 1> (core), <name/handle 2>
- **Rationale:** <one sentence — the hardware round, interop bug, or RFC that motivated the change>
```

An entry with a missing field, an approver count below two, or zero core approvers is malformed and is itself a rejection reason at the next review that touches this file. The five-field shape is deliberately terse — the rationale is one sentence because the argument for the change belongs in the linked PR and its RFC, not duplicated here; this file is a ledger, not an archive.

---

## §6. Precedent — G7-M2..M8 primitives shipped before this freeze took effect

The kind catalogue (`pwp-spec-vocabulary.md` §2, landed at #2242) closed the *vocabulary* before this review gate existed. Eighteen G7-M2..M8 issues then landed real `.pdx` capability bodies against that closed vocabulary across two batches, both on 2026-09-03, before this document (#2245) was written. None of the eighteen went through a §3/§4 review, because no review process existed yet to run them through. They are grandfathered: accepted as-is, not subject to retroactive review, and are cited here only so the Change Log in §7 has an honest starting line — the first entry in §7 is the first change reviewed under this gate, not the first change PWP ever made.

Two of the four G7-M1 sibling drafts this freeze depends on — `pwp-spec-wire.md` (#2243) and `pwp-spec-lifecycle.md` (#2244) — are still planned, not landed, as of this writing. The eighteen primitives below are therefore KIND/struct definitions minted against the vocabulary index alone; none yet carry an assigned wire opcode, because the opcode table they would be assigned into does not exist yet. This is noted so a future reviewer does not read "no opcode number" as an oversight in the precedent table.

| Issue | Slug | Primitive | KIND ordinal | Source file | Landing commit |
|---|---|---|---|---|---|
| #2246 | G7-M2-001 | `KIND_SURFACE` | `0x1B8` | `src/user/compositor/surface_kind.pdx` | `64c6012` |
| #2248 | G7-M2-002 | `KIND_SURFACE_COMMIT` (LINEAR) + `atomic_commit_batch` | `0x1B9` | `src/user/compositor/surface_commit.pdx` | `64c6012` |
| #2250 | G7-M2-003 | `SurfaceGeometry` value type (rational num/den, P3) | — | `src/user/compositor/surface_geometry.pdx` | `64c6012` |
| #2252 | G7-M2-004 | `SurfaceBufferBind` (mandatory explicit-sync, P1) | — | `src/user/compositor/surface_buffer_bind.pdx` | `64c6012` |
| #2254 | G7-M3-001 | `KIND_WINDOW` (structural P4 a11y-mint gate) | `0x1C1` | `src/user/compositor/window_kind.pdx` | `64c6012` |
| #2256 | G7-M3-002 | `KIND_LAYER_TREE` (sealed subtree + damage aggregation) | `0x1C2` | `src/user/compositor/layer_tree.pdx` | `64c6012` |
| #2258 | G7-M3-003 | `KIND_SUBSURFACE` (sync/desync edges) | `0x1BA` | `src/user/compositor/subsurface_sync.pdx` | `044a257` |
| #2260 | G7-M4-001 | `KIND_XDG_TOPLEVEL_STATE` (tiling first-class) | `0x1C4` | `src/user/compositor/xdg_shell_states.pdx` | `64c6012` |
| #2262 | G7-M4-002 | `xdg_shell_geometry` value type (resize + geometry-update) | — | `src/user/compositor/xdg_shell_geometry.pdx` | `044a257` |
| #2265 | G7-M4-003 | `KIND_XDG_POPUP` (positioning + grab semantics) | `0x1C5` | `src/user/compositor/xdg_shell_popup.pdx` | `044a257` |
| #2266 | G7-M5-001 | `KIND_CLIP_OFFER` (sealed, no `R_MINT`) | `0x1C6` | `src/user/compositor/clipboard.pdx` | `64c6012` |
| #2267 | G7-M5-002 | `KIND_DND_OFFER` (sealed, no `R_DND_MINT`) | `0x1C7` | `src/user/compositor/dnd_offer.pdx` | `044a257` |
| #2268 | G7-M5-003 | `KIND_SELECTION_OWNER` (sealed, auto-revoke on window destroy) | `0x1C9` | `src/user/compositor/selection_owner.pdx` | `044a257` |
| #2269 | G7-M6-001 | `KIND_RECOVERY_PLANE` (input-server-held, no `R_TAKEOVER`) | `0x1C8` | `src/user/compositor/recovery_plane_reserve.pdx` | `64c6012` |
| #2270 | G7-M6-002 | `recovery_plane_takeover` (`RIGHT_TAKEOVER = 0x004`) | — | `src/user/compositor/recovery_plane_takeover.pdx` | `044a257` |
| #2271 | G7-M7-001 | No-extension policy (P11 single-protocol discipline) | — | `design/compositor/no-extension-policy.md` | `64c6012` |
| #2272 | G7-M7-002 | Minor-version bump cadence | — | `design/compositor/pwp-version-cadence.md` | `044a257` |
| #2273 | G7-M8-001 | T14 hw-smoke first-window spec (5 tests) | — | `tools/hw-smoke-g7.md` | `044a257` |

Both commits are on `main`: `64c6012` ("Wave 0 Batch 6: G7-M2..M7 PWP compositor kernel wave", 2026-09-03) and `044a257` ("Wave 0 Batch 7: G7 close-out — M3-003, M4-002/003, M5-002/003, M6-002, M7-002, M8-001", 2026-09-03). Batch 7's commit message also records three build-surfaced fixes riding alongside the grandfathered primitives (a fingerprint-allowlist update, an encoder-shape fix in `color/hdr_metadata_kind.pdx`, and an `and`-immediate rewrite in `compositor/selection_owner.pdx`); those are implementation fixes, not wire-visible changes, and are cited here only for completeness — they are not §2 categories and would not have triggered a review even under this gate.

---

## §7. Change Log

*Empty at file birth. Every future change accepted under §2 through the §3/§4 gate is appended below, oldest first, in the §5 format. No entry predates this file's own landing — the eighteen G7-M2..M8 primitives that predate the gate are recorded as precedent in §6, not as Change Log entries.*

(none yet)

---

## §8. Related work

**IETF RFC last-call.** A 21-day floor with no early-exit-on-consensus is the shape IETF last-call review has used since RFC 2026: a fixed minimum visibility window regardless of how quickly the nominal reviewers respond, so a working group outside the immediate author/reviewer pair has calendar time to object. PWP's window borrows the fixed-floor shape and drops IETF's variable extension mechanism (Area Director discretion to lengthen last-call) — this gate's window is exactly 21 days, never shorter, never explicitly longer; a review that needs more time simply stays open past day 21 per §3.

**Rust RFC process.** The two-approval-with-designated-authority shape (§4) is closer to Rust's RFC process than to a simple majority vote: a Rust RFC needs sign-off from the relevant subteam, not a headcount of arbitrary approvers. PWP's "at least 1 core reviewer" rule is the compositor-scale analogue — breadth of approval matters less than depth of standing authority over the surface being changed.

**Python PEP steward model.** PEPs are terse, living documents with a fixed structural shape (motivation, specification, rationale, rejected alternatives) that a steward accepts or rejects, not a discussion thread. This document's Change Log format (§5) takes the same terseness bet: a five-field ledger entry, with the argument for the change left in the linked PR rather than re-litigated in the ledger.

---

*End of freeze-review record. Minor/major bump cadence lives at `pwp-version-cadence.md` (paideia-os#2272); no-extension policy at `no-extension-policy.md` (paideia-os#2271); kind catalogue at `pwp-spec-vocabulary.md` (paideia-os#2242).*
