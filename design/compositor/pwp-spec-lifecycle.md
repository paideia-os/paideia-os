# PWP protocol spec — atomic-commit lifecycle

**Status:** Wave-0 Batch-8 protocol-freeze draft. Third of the four G7.M1 PWP freeze drafts.
**Issue:** paideia-os#2244 (`G7-M1-003`), milestone `g7-compositor-protocol`.
**Depends on:** G7-M1-001 (vocabulary index, paideia-os#2242, landed).
**Adjacent:** G7-M1-002 (wire framing, `pwp-spec-wire.md`, paideia-os#2243, planned — owns the authoritative opcode table; §6 below is this document's reservation request against it). G7-M1-004 (freeze-review record, `pwp-spec-freeze-review.md`, paideia-os#2245, in progress) — the sign-off gate this draft feeds.
**Date:** 2026-09-05.
**Scope:** the atomic-commit transaction primitive for PWP — `KIND_PWP_COMMIT_TXN` — as a LINEAR capability, its timeline guards, its state machine, and the eight change classes it batches. No wire byte layout, no opcode numbering authority (owned by #2243). This document is spec-shaped, matching the discipline `pwp-spec-vocabulary.md` line 24 sets for its siblings.

Related documents (read-only from this doc's viewpoint):
- `design/compositor/pwp-spec-vocabulary.md` §2.2 (`KIND_SURFACE_COMMIT`), §2.10 (`KIND_INPUT_ROUTE`), §2.13 (`KIND_WORKSPACE`), §2.18/§2.19 (`KIND_IME_SESSION`/`KIND_IME_PROVIDER`), §2.21 (`KIND_A11Y_TREE`), §3 (derivation graph), §4 (linearity table).
- `design/compositor/no-extension-policy.md` — the one-mechanism discipline this transaction primitive follows instead of a family of ad-hoc atomicity extensions.
- `design/compositor/pwp-version-cadence.md` — the additive-only amendment channel §6's reserved opcode block rides.
- `design/graphics/r101-kernel-plan.md` §4 — `KIND_MODESET_TXN` / `KIND_PAGE_FLIP`, the display-layer transaction precedent this document lifts to the protocol layer.
- `design/architecture/next-wave-derived-kinds.md` — ordinal `0x171` (`KIND_MODESET_TXN`) and the "LINEAR kinds" registry §KIND_PWP_COMMIT_TXN reserves a future slot in.
- `design/roadmap/next-wave-synthesis.md` §4 — pitfalls P1 (linearity-as-atomicity substrate), P2 (input-server process isolation), P4 (a11y as first-class), P6 (present feedback), P10 (single IME router).

**Note on vocabulary reconciliation (action item, not yet applied — out of scope for this document per its NEW-file-only mandate):** `KIND_PWP_COMMIT_TXN` is a new root-level kind and does not yet appear in `pwp-spec-vocabulary.md` §2/§3/§4. The vocabulary index is not frozen until G7-M1-004 signs off, so this is a normal pre-freeze gap, not drift — but it must land as a `pwp-spec-vocabulary.md` §2.23 entry (plus a `§3` graph leaf under `[KIND_IPC_ENDPOINT = 5]` and a `§4` LINEAR row) in a follow-up edit before freeze-review sign-off. This document is the authority for that entry's content; `pwp-spec-vocabulary.md` should cite it, not restate it.

---

## §0. Non-goals

- **Wire byte layout.** No row-tail offsets, no framing header, no length-prefix discipline. Those are `pwp-spec-wire.md`'s (#2243) to define; §6 only reserves opcode numbers against that future table.
- **`KIND_MODESET_TXN`'s own state machine.** The display-layer transaction this document's shape is lifted from (§1, §7) is specified at `design/graphics/r101-kernel-plan.md` §4 and is not re-derived here; it is cited as precedent, not re-litigated.
- **Buffer format / colour-space negotiation.** `buffer_attach` in §5 stages a readiness binding, not a format contract; format negotiation is `KIND_SURFACE`'s concern (`pwp-spec-vocabulary.md` §2.1).
- **Kind-ordinal allocation.** Per the pattern `pwp-spec-vocabulary.md` line 24 sets, `KIND_PWP_COMMIT_TXN`'s ordinal is a landing-time artefact assigned in `next-wave-derived-kinds.md` when G7.M2+ agents write `kind_pwp_commit_txn.pdx`, not a spec-time commitment. This document fixes the schema and the state machine; it does not fix the ordinal.
- **The `svc-compositor` reference implementation's internal locking primitive.** §3.3 fixes the *observable* contract (bounded wait, named failure sentinel); whether the implementation backs it with a futex, a spinlock, or a lock-free CAS loop is an implementation choice with no wire-visible difference.

---

## §1. Motivation

Wayland has exactly one atomicity primitive: `wl_surface.commit`, which guarantees only that one surface's own pending state (buffer attach, damage, opaque/input region, frame callback) lands as one unit. Everything adjacent to that boundary was bolted on separately, and each bolt-on needed its own protocol extension:

- **Cross-surface atomicity** exists only for the parent/subsurface tree, via `wl_subsurface` sync mode — a sync-mode child's commit is cached and released only when the parent commits. It does not extend to two unrelated toplevels, and it is not general: a compositor cannot ask "commit these three windows and this workspace switch together" without inventing new protocol.
- **Buffer readiness** needed `linux-drm-syncobj-v1` (explicit GPU fence sync), superseding the earlier `wp-linux-explicit-synchronization-v1` with different semantics — the exact "extension renamed at v2" episode `no-extension-policy.md` §6.1 cites as the cost of the extension mechanism.
- **Presentation timing** needed `wp-presentation-time`, then `wp-commit-timing-v1` / `wp-fifo-v1` for target-time hints — still per-surface, still additive extensions.
- **Accessibility** has no commit-boundary primitive at all. AT-SPI runs out-of-band over D-Bus, independent of any `wl_surface.commit`; a screen reader has no protocol guarantee that the a11y tree it reads describes the frame currently on screen. This is a documented, structural desync, not an implementation bug — there is nothing in the Wayland core or in `xdg-shell` for a client to synchronize against.
- **Workspace switch** is compositor-internal state with no client-visible atomicity contract; the "half-old half-new" visual tear during a workspace-switch animation is the direct symptom of there being no primitive that spans "restack these N windows, swap this M outputs' visible set, and present" as one unit.
- **IME composition** is `text-input-v3`, a protocol independent of surface commit; a provider swap and the surface's next frame have no ordering guarantee, so a frame can render composition text from the outgoing provider against the incoming provider's now-live session.

The pattern is structural: Wayland's only real atomicity mechanism (subsurface sync-mode grouping) covers one narrow case, and every other cross-cutting atomicity need either got its own extension or got no primitive at all. PWP already rejected the extension mechanism outright (`no-extension-policy.md`); repeating that mechanism's failure mode one atomicity axis at a time — a wire-sync extension here, a presentation-time extension there, an eventual "atomic commit group" extension nobody wrote yet for the rest — would be exactly the fragmentation PWP exists to foreclose.

**The novel-clean answer taken here:** one general transaction capability, `KIND_PWP_COMMIT_TXN`, that batches heterogeneous staged changes — not just surface state — under one timeline-guarded apply-or-abort boundary. This is not a new paradigm invented for PWP; it lifts a pattern PaideiaOS has already committed to one layer down. `KIND_MODESET_TXN` (`design/graphics/r101-kernel-plan.md` §4, ordinal `0x171`) already does this for the display engine: mint a transaction, populate N atomic properties across N KMS objects, commit-or-abort as one unit — the same shape `drmModeAtomicCommit` established in Linux DRM/KMS. `KIND_PWP_COMMIT_TXN` is that same discipline raised to the protocol layer, where the "properties" are surface commits, buffer attaches, damage, geometry, workspace switches, focus routing, a11y-subtree mutations, and IME bindings instead of plane/CRTC/connector properties. One mechanism, reused at both layers, is the point — not a family of per-need extensions.

`KIND_SURFACE_COMMIT` (`pwp-spec-vocabulary.md` §2.2) is not superseded by this. It remains the atomic boundary for *one surface's own* pending state — buffer attach, damage, geometry, local to that surface — exactly as specified. `KIND_PWP_COMMIT_TXN` is the outer envelope: a client may attach zero, one, or many `KIND_SURFACE_COMMIT` caps (across different surfaces) into one txn alongside non-surface-scoped changes, and the txn's apply consumes all of them as a single atomic step. §5 makes the surface-commit relationship precise.

---

## §2. The `KIND_PWP_COMMIT_TXN` capability schema

- **Linearity:** **LINEAR** (no `R_MINT`; consumed on `commit_apply`, `commit_abort`, or unilateral `DEADLINE_MISSED` transition).
- **Parent:** `KIND_IPC_ENDPOINT = 5` — mirrors `KIND_MODESET_TXN`'s parent choice and every other top-level PWP root in `pwp-spec-vocabulary.md` §3's derivation graph.
- **Mint (`commit_begin`):** the client's endpoint requests a new txn. The compositor assigns `txn_id`, binds `frame_deadline` to a `KIND_DISPLAY_TIMELINE` value (§3.1), and returns the pair. No changes are staged yet; state is `MINTED`.
- **Apply (`commit_apply`):** the client asserts staging is complete. The compositor re-validates every staged change's referenced caps are still live, then atomically merges the full staged set into the frame landing at `frame_deadline`. State becomes `APPLIED`; the cap is consumed; a `KIND_PRESENT_FEEDBACK` event fires per touched surface when that frame reaches scanout, mirroring `KIND_SURFACE_COMMIT`'s own apply-time behavior (`pwp-spec-vocabulary.md` §2.2).
- **Abort (`commit_abort`):** the client (or the compositor, on deadline miss or lock timeout) discards every staged change with no visible effect. State becomes `ABORTED` (client-initiated) or `DEADLINE_MISSED` (server-initiated); the cap is consumed either way.
- **Consume:** `APPLIED`, `ABORTED`, and `DEADLINE_MISSED` are terminal. Per the LINEAR discipline `pwp-spec-vocabulary.md` §4 already establishes for `KIND_SURFACE_COMMIT` / `KIND_INPUT_ROUTE` / `KIND_IME_SESSION`, any further op against a consumed `txn_id` returns `TXN_ALREADY_CONSUMED` rather than reviving or reusing the slot.

Fields (named, typed; row-tail byte offsets are `pwp-spec-wire.md`'s to assign, per the spec/implementation split this doc inherits from its siblings):

| Field              | Type                              | Semantics |
|--------------------|-----------------------------------|-----------|
| `txn_id`           | `u64`                             | Server-assigned, monotonic, unique among live txns. Opaque handle on the wire. |
| `origin_endpoint`  | `KIND_IPC_ENDPOINT` ref           | The minting client connection. Used so a txn's own later `commit_attach` calls against a surface it already locked are free re-entrant hits, not self-contention. |
| `frame_deadline`   | `u64` (timeline value)            | Bound once, at `commit_begin`; immutable for the txn's life. See §3.1. |
| `state`            | enum `{MINTED, STAGING, WAITING, APPLIED, ABORTED, DEADLINE_MISSED}` | Current lifecycle state; see §4. |
| `staged_count`     | `u16`                             | Number of change records currently attached. |
| `staged_classes`   | bitmap (`u16`, one bit per §5 consumer class) | Lets the compositor's apply pass dispatch only the change kinds actually present, without scanning an empty list per class. |
| `locked_surfaces`  | bounded list, ≤ `TXN_LOCK_MAX` (e.g. 32) surface-slot refs | Surfaces this txn currently holds the serialization lock on (§3.3). Released on any terminal transition. |
| `lock_wait_ceiling`| `u32` (ms)                        | Server-configured bound a `WAITING` txn may block before auto-abort; never exceeds remaining slack to `frame_deadline` (§3.3). |

No RIGHTS-bit table is defined here — `pwp-spec-vocabulary.md` does not assign per-kind rights bits either (that is `kind_*.pdx` implementation-time detail, per its own §2 convention); this document holds the same line.

---

## §3. Timeline guards

### 3.1 Frame-deadline binding at mint

`commit_begin` binds `frame_deadline` to a specific `KIND_DISPLAY_TIMELINE` tick — by default the next scanout boundary, with an optional bounded slack request (1–3 frames) the client may ask for at mint time. Once bound, `frame_deadline` does not move: a client cannot renegotiate more time mid-transaction by attaching more changes. This forecloses the "transaction that never closes" failure mode a client-controlled, unbounded staging window would otherwise invite — every `KIND_PWP_COMMIT_TXN` has a hard wall-clock ceiling from the moment it exists.

### 3.2 Deadline-missed auto-abort

The compositor's own frame pump — not the client — is the authority on whether `frame_deadline` has passed. If the txn is still in `MINTED`, `STAGING`, or `WAITING` when the compositor's timeline crosses `frame_deadline`, the compositor unilaterally transitions the txn to `DEADLINE_MISSED`: every staged change is discarded, every held surface lock (§3.3) is released, and the cap is consumed. The client does not need to be told synchronously — because `txn_id` is single-use, the client's *next* op against that id (a stray `commit_attach` or `commit_apply` sent after the deadline already passed, e.g. lost in a scheduling stall) returns `TXN_DEADLINE_MISSED`, which is sufficient for correctness even without a push event. A client that wants to distinguish "deadline missed" from "silently vanished" for diagnostics reads this from the reply to whichever request it happens to issue next; no dedicated event opcode is reserved for it (see §6).

### 3.3 Concurrent-txn serialization

Two live txns may name overlapping surfaces (e.g., two clients racing to commit the same shared-decoration surface, or one client opening a second txn against a surface its first txn already touched). Ordering is by `txn_id` — the lower id, having been minted first, holds priority:

1. `commit_attach` on txn A naming surface S succeeds immediately if no other live txn holds S's lock; S is added to A's `locked_surfaces` and A (or S's per-surface lock) blocks any other txn from locking S.
2. `commit_attach` on txn B naming the same S, while A still holds S's lock, does not fail immediately. B transitions to `WAITING` and blocks for up to `min(lock_wait_ceiling, time remaining to B's own frame_deadline)`.
3. If A releases S (via `APPLIED`, `ABORTED`, or `DEADLINE_MISSED`) before B's wait bound elapses, B retries the lock, acquires it, and returns to `STAGING`.
4. If B's wait bound elapses first, B auto-aborts with sentinel `TXN_SURFACE_BUSY`, releasing any other locks B already held. B does not silently retry past its own bound — an unbounded retry loop would just reproduce the deadlock risk the bound exists to foreclose.

This is a timeout, not a queue: PWP does not promise fairness or FIFO ordering across contending txns, only that no txn blocks past its own bounded wait. A workload that contends heavily on one surface (pathological, not expected) degrades to serialized single-frame-at-a-time commits against that surface, which is the same degrade a naive per-object lock would produce — the guard's job is only to make the failure mode a bounded, named sentinel instead of an unbounded hang.

### 3.4 Worked example — concurrent commit contention

Two independent clients, a decoration daemon (D) and the application it decorates (A), both hold a `KIND_SURFACE_COMMIT` against the same shared border surface S — a legitimate case, since client-side decoration split across two processes is a real PWP shape. Sequence:

1. D calls `commit_begin`, gets `txn_id = 41`, `frame_deadline = T`.
2. A calls `commit_begin`, gets `txn_id = 42`, `frame_deadline = T` (same target frame — both are reacting to the same resize event).
3. D calls `commit_attach(41, surface_commit(S))` first; S's lock is free, so 41 acquires it and enters `STAGING`.
4. A calls `commit_attach(42, surface_commit(S))` a few microseconds later; S is locked by 41, so 42 transitions to `WAITING`, bounded by `min(lock_wait_ceiling, T - now)`.
5. D calls `commit_apply(41)`. The compositor merges D's change, transitions 41 to `APPLIED`, and releases S's lock.
6. The wait in step 4 wakes on the release, retries the lock, succeeds, and 42 returns to `STAGING` — all before its wait bound elapsed.
7. A calls `commit_apply(42)`. Because this lands in the same frame interval as step 5 (both bound to `frame_deadline = T`), the border and the content it decorates reach scanout together.

Had D stalled (e.g., blocked on its own slow render) long enough that 42's wait bound elapsed before step 5, 42 would auto-abort with `TXN_SURFACE_BUSY`, and A's decoration-adjacent frame would simply not update that cycle — a missed decoration-sync frame, not a hang, and not a torn composite.

---

## §4. State machine

```
                      commit_begin
                           │
                           ▼
                     ┌───────────┐
                     │  MINTED   │   txn_id assigned; frame_deadline bound (§3.1)
                     └─────┬─────┘
                           │ commit_attach — every named surface's lock free
                           ▼
        ┌───────────►┌───────────┐
        │  retry ok   │  STAGING  │◄────────────────────────────┐
        │             └─────┬─────┘  commit_attach, locks free   │
        │                   │                                    │
        │       commit_attach names a surface locked              │
        │       by another live txn                               │
        │                   ▼                                     │
        │             ┌───────────┐                                │
        └─────────────┤  WAITING  ├────────────────────────────────┘
                       └─────┬─────┘
                             │ lock_wait_ceiling elapses (§3.3 rule 4)
                             ▼
                       ┌───────────┐
                       │  ABORTED  │  ── TXN_SURFACE_BUSY
                       └───────────┘

  From MINTED, STAGING, or WAITING — at any time, server-side only:
      compositor timeline crosses frame_deadline
            │
            ▼
      ┌────────────────┐
      │ DEADLINE_MISSED │   unilateral; staged changes discarded, locks released
      └────────────────┘

  From STAGING only, client-initiated:
      commit_apply  (all staged refs still live) ──► APPLIED    (terminal)
      commit_abort  (explicit)                   ──► ABORTED    (terminal)

  APPLIED | ABORTED | DEADLINE_MISSED are terminal: cap consumed, txn_id retired.
  Any further op against a retired txn_id ──► TXN_ALREADY_CONSUMED.
```

`APPLIED` is the only state where visible compositor state changes. Every path through `WAITING`, every `ABORTED`, and `DEADLINE_MISSED` leave every surface, workspace, route, and a11y-tree exactly as it was before `commit_begin` — the transaction either lands whole or leaves no trace, which is the entire point of routing eight otherwise-independent change classes through one cap instead of eight independent commit paths with eight independent partial-failure modes.

---

## §5. Consumers

Eight change classes are attachable via `commit_attach`, tagged by class in `staged_classes`. Each cites the vocabulary kind it stages a change against.

- **`surface_commit`** — attaches an already-minted `KIND_SURFACE_COMMIT` cap (`pwp-spec-vocabulary.md` §2.2) into the txn's staged set, transferring its ownership without consuming it yet. `commit_apply` consumes every attached `KIND_SURFACE_COMMIT` in the same atomic pass; `commit_abort`/`DEADLINE_MISSED` discard them unconsumed (their target surfaces keep their prior state; the client re-mints if it wants to retry). This is how a single txn spans multiple surfaces: one `KIND_SURFACE_COMMIT` per surface, N surfaces, one txn.
- **`buffer_attach`** — the `(timeline_id, value)` buffer-readiness binding a `KIND_SURFACE_COMMIT` already carries per §2.2, exposed as an independently attachable record so a txn can group *only* the buffer swap across several surfaces (e.g., a video layer and its UI overlay presenting the same instant) without dragging in unrelated geometry or damage state from either surface's full commit.
- **`damage`** — a `KIND_DAMAGE_REGION` (§2.11) reference staged against a surface named in this txn. Batching lets the compositor union damage across every surface the txn touches into one minimal repaint computed once at apply, rather than once per surface as each surface's own commit lands.
- **`geometry`** — position/size changes (`KIND_XDG_TOPLEVEL_STATE` geometry, `KIND_SUBSURFACE` anchor). Batching is what makes a tiling-WM operation — "resize these four tiled windows to their new tile geometry" — land in one visually atomic frame instead of four commits arriving across four frame boundaries, which is exactly the class of tear Wayland tiling compositors work around today with ad hoc subsurface-sync tricks that only cover parent/child pairs.
- **`workspace_switch`** — a `KIND_WORKSPACE` (§2.13) transition. Batching the switch with whatever `surface_commit`/`geometry`/`damage` changes realize the new workspace's visible window set is what makes the switch "present-timeline-synchronised" in the sense §2.13 already commits to (#2289) — the switch and the content that makes it visible land in the same `commit_apply`, foreclosing the half-old/half-new tear described in §1.
- **`focus_router`** — a co-scheduling hint toward a `KIND_INPUT_ROUTE` (§2.10) transition, **not** a hard member of the atomic set. `KIND_INPUT_ROUTE` is minted by the input server, a process deliberately independent of `svc-compositor` (pitfall P2 — a compositor lockup must never stall input, and the converse must hold too). A `focus_router` change stages the *intent* ("route focus to surface X at this txn's `frame_deadline`"); at `commit_apply` the compositor forwards that intent to the input server out-of-band, tagged with the same `frame_deadline` timeline value, but `commit_apply`'s own completion does not block on the input server's acknowledgment. The two land at the same timeline tick when the input server keeps up, and skew by at most one frame under input-server backpressure — never by an unbounded amount, and never by blocking the compositor's own apply on a process P2 requires stay decoupled.
- **`a11y_subtree`** — a `KIND_A11Y_TREE` (§2.21) mutation-log commit. Unlike `focus_router`, this *is* a hard atomic member: `KIND_A11Y_TREE` is compositor-local (parent `KIND_MEMORY`, §2.21), so its mutation lands in the same `commit_apply` pass as the visual change it describes, closing exactly the AT-SPI/Wayland desync §1 names — a screen reader reading the tree after an `APPLIED` txn's `KIND_PRESENT_FEEDBACK` event is guaranteed to be reading the tree state that matches what is on screen.
- **`ime_provider_bind`** — a `KIND_IME_SESSION`/`KIND_IME_PROVIDER` (§2.18/§2.19) binding change, staged so a provider swap (#2315) and the surface's next visible frame land together. Forecloses a frame rendering composition text from the outgoing provider against the incoming provider's now-live session.

### 5.1 Worked example — tiling-WM atomic resize plus workspace switch

A tiling window manager switches from workspace 1 (one maximized window) to workspace 2 (three windows in a left/right/right-split tiling layout) in response to a keybind. Under the old per-object-commit model this is four to five independent commits landing across as many frames, each individually torn-safe but jointly visible as a multi-frame shuffle. Under `KIND_PWP_COMMIT_TXN`:

1. `commit_begin` → `txn_id = 77`, `frame_deadline = T` (one frame of slack requested, since three windows' content may not all be pre-rendered).
2. `commit_attach(77, workspace_switch(workspace=2))`.
3. `commit_attach(77, geometry(window=A, rect=left-half))`.
4. `commit_attach(77, geometry(window=B, rect=top-right-quarter))`.
5. `commit_attach(77, geometry(window=C, rect=bottom-right-quarter))`.
6. `commit_attach(77, surface_commit(A))`, `commit_attach(77, surface_commit(B))`, `commit_attach(77, surface_commit(C))` — each window's own already-minted `KIND_SURFACE_COMMIT`, transferred in per §5's `surface_commit` rule.
7. `commit_attach(77, focus_router(target=A))` — a co-scheduling hint (§5), forwarded to the input server at apply, not blocked on.
8. `commit_attach(77, a11y_subtree(...))` — the a11y tree's workspace-2 root becomes the active tree at the same boundary.
9. `commit_apply(77)`. The compositor validates all nine staged changes' referenced caps are still live (a window closed mid-staging would fail validation here, not mid-apply), then merges all nine into the frame landing at `T`. A single `APPLIED` transition later, workspace 2's three windows, their geometry, their content, the input focus, and the a11y tree all reach the screen and the accessibility layer at once.

If window C's compositor-side render had not produced a buffer by `T` even with the one-frame slack, `commit_apply` fails validation on C's `buffer_attach` and the whole txn is refused — not partially applied with A and B tiled correctly and C blank. The WM's fallback is to retry with a fresh txn once C's buffer is ready, which reproduces the "land whole or leave no trace" guarantee §4 closes on, rather than a wire-visible half-tiled frame.

---

## §6. Wire representation

`pwp-spec-wire.md` (#2243) is not yet landed; the opcode numbers below are this document's **reservation request** against that table, not an independent grant — #2243 owns final numbering and may renumber before it lands (per `pwp-spec-vocabulary.md` line 24's "opcode numbering lives in `pwp-spec-wire.md`" split). This document reserves the 16-slot block `0x00F0`–`0x00FF` for txn-lifecycle opcodes; four are named now, twelve remain free for additive minor-bumps under `pwp-version-cadence.md`.

| Opcode   | Name            | Direction       | Purpose |
|----------|-----------------|-----------------|---------|
| `0x00F0` | `commit_begin`  | client → server | Mint a `KIND_PWP_COMMIT_TXN`. Reply carries `txn_id` and the bound `frame_deadline`. |
| `0x00F1` | `commit_attach` | client → server | Stage one change record (tagged by §5 class) against an open txn. Reply is success, `TXN_SURFACE_BUSY` (after the §3.3 wait bound elapses), or `TXN_DEADLINE_MISSED`. |
| `0x00F2` | `commit_apply`  | client → server | Request atomic merge of every staged change. Reply is `APPLIED` or a failure sentinel (`TXN_DEADLINE_MISSED`, or a per-change validation failure if a referenced cap died mid-staging). |
| `0x00F3` | `commit_abort`  | client → server | Explicit discard. Reply is `ABORTED`. |

No event opcode is reserved for `DEADLINE_MISSED` or `TXN_SURFACE_BUSY` — both are request/reply failure sentinels on whichever of `0x00F1`/`0x00F2` the client next issues (§3.2), not unsolicited server pushes. This keeps the txn-lifecycle surface entirely request/reply-shaped, consistent with the rest of PWP's connection-oriented framing, and avoids growing the event-class opcode space for a condition a lazy-discovery reply already communicates correctly.

---

## §7. Rationale + citations

- **DRM/KMS atomic modeset** (`drmModeAtomicCommit`, Linux kernel since 4.x) — the direct prior art: bundle N property changes across N kernel objects into one atomic request, validate as a whole, apply as a whole or reject as a whole. PaideiaOS already committed to this shape at the display layer as `KIND_MODESET_TXN` (`design/graphics/r101-kernel-plan.md` §4, ordinal `0x171`, `design/roadmap/next-wave-softarch.md` line 295); this document is that same commitment applied one layer up, not a new paradigm import — consistent with the project's preference for reusing an already-proven in-repo pattern over inventing a second mechanism for an adjacent problem.
- **Wayland `wl_subsurface` sync mode** — the one genuine Wayland atomicity primitive beyond single-surface commit, and the ceiling of what it can express (parent/child pairs only). Cited in full in §1.
- **`linux-drm-syncobj-v1`, `wp-commit-timing-v1`, `wp-fifo-v1`** — the per-need extension trail buffer-readiness and presentation-timing atomicity took in Wayland, each a separate protocol negotiated separately. `no-extension-policy.md` §6.1 already catalogues the `wp-linux-explicit-synchronization-v1` → `linux-drm-syncobj-v1` renaming episode as the canonical extension-mechanism cost; this document's motivation in §1 draws the same lesson for the atomicity axis specifically.
- **AT-SPI-over-D-Bus on Wayland** — the accessibility desync is a structural absence, not a bug report: no Wayland core or `xdg-shell` primitive ties an a11y-tree read to a specific committed frame. `a11y_subtree` in §5 is written specifically against this gap.
- **`pwp-spec-vocabulary.md`** §2.2, §2.10, §2.13, §2.18, §2.19, §2.21 — every consumer in §5 cites an existing vocabulary kind; this document introduces zero new derived kinds other than the txn root itself, by design (the reconciliation note above is the one exception, and it is additive, not a redefinition).
- **`next-wave-synthesis.md`** §4 pitfalls P1 (linearity as the atomicity substrate — the same argument `pwp-spec-vocabulary.md` §4 opens with), P2 (input-server process isolation — governs the `focus_router` asymmetry in §5), P4 (a11y as first-class, not sidecar — governs the `a11y_subtree` hard-member choice), P6 (present feedback budget — the `KIND_PRESENT_FEEDBACK` event `commit_apply` triggers per §2 mint description), P10 (single IME router — governs `ime_provider_bind`).

---

*End of atomic-commit lifecycle spec. Wire opcode reservation owned by paideia-os#2243 on landing; freeze-review record and sign-off gate at paideia-os#2245. Vocabulary back-port (`pwp-spec-vocabulary.md` §2.23/§3/§4 for `KIND_PWP_COMMIT_TXN`) is an open follow-up, not yet applied.*
