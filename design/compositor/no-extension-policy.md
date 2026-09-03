# PWP no-extension policy — single-protocol discipline

**Status:** Wave-0 Batch-6 authoritative policy. G7.M7-001.
**Issue:** paideia-os#2271 (`G7-M7-001`), milestone `g7-compositor-protocol`.
**Depends on:** G7-M1-004 (freeze review, paideia-os#2245) — the freeze this policy defends.
**Feeds:** G7-M7-002 (minor-version cadence, paideia-os#2272) — the amendment path this policy points to.
**Date:** 2026-09-03.
**Scope:** the paideia-window-protocol (PWP) is one protocol, one wire, one vocabulary. This document writes down the commitment, its enforcement, its cost, and the amendment path that replaces the extension mechanism it forecloses. It is pitfall P11 (`next-wave-synthesis.md` §4) enforcement.

Related documents (read-only from this doc's viewpoint):
- `design/compositor/pwp-spec-vocabulary.md` §1, §5 — the freeze surface this policy stabilises.
- `design/compositor/pwp-spec-wire.md` (paideia-os#2243) — the wire framing whose opcode table is closed at every minor version.
- `design/compositor/pwp-spec-freeze-review.md` (paideia-os#2245) — the freeze-review record that first enacts this policy.
- `design/roadmap/next-wave-synthesis.md` §4 (pitfall register), §7 (risk register R1).
- `MASTER_PLAN.md` §10.3 — the serialization-point discipline a vocabulary change goes through.

---

## §1. Motivation

Wayland's protocol lives in three tiers: `wl_*` core, `xdg_*` stable extensions, and `wp_*` / `zwp_*` / `ext_*` staging extensions. A running client of 2026 vintage negotiates linux-dmabuf, xdg-shell, xdg-decoration, wp-single-pixel-buffer, wp-viewporter, wp-fractional-scale-v1, wp-linux-drm-syncobj-v1, wp-color-management-v1, wp-content-type-v1, wp-cursor-shape-v1, wp-presentation-time, wp-primary-selection-v1, wp-tablet-v2, xdg-activation-v1, xdg-foreign-v2, xdg-output-v1, xdg-toplevel-drag-v1, xdg-toplevel-icon-v1, and roughly forty more depending on the compositor. Two clients often disagree on which extensions the compositor supports; each carries a fallback tree for the ones it does not; every compositor implements a distinct subset; the interop matrix is combinatorial.

This is pitfall P11 — *protocol proliferation*. The mechanism that made it inevitable is `wl_registry`: a runtime-enumerated set of globals over which clients dispatch at connection time. Once that mechanism exists, every new capability naturally lands as a new global, versioned independently, negotiated separately, and shipped by whichever compositor implements it first. There is no natural pressure to fold new work into the core vocabulary; the extension slot is always the cheaper path.

PWP is the opposite decision, taken with eyes-open. There is one protocol. There is one vocabulary — the 22 kinds enumerated in `pwp-spec-vocabulary.md` §2. There is one wire — the framing frozen at G7-M1-002. A compositor either implements PWP-`<major>`.`<minor>` or it does not; a client either accepts that version or it refuses the connection. Nothing is negotiated at connection time except the version number. This is the anti-Wayland decision, and it is the design commitment this document writes down.

The commitment is not a limitation — it is a discipline that trades prototyping speed for interop determinism. The engineering economy it aims at is one where a toolkit statically compiles against a version tag, a compositor exhaustively implements a version tag, and interop between them is a single-axis question rather than a matrix. That economy is the reason the discipline exists.

---

## §2. The rule

> No client-visible protocol extension mechanism exists in PWP. There is no `wl_registry`-like runtime enumeration of "supported globals." There is no `wp-*`, `zwp-*`, `ext-*`, `xdg-*`, or vendor prefix namespace. A compositor either implements PWP-`<major>`.`<minor>` or it does not; a client asks for a version at connection time, and either the connection is accepted or it is refused with a version-mismatch error carrying the compositor's actual `(major, minor)` tuple.

The version tuple is the *only* capability-negotiation channel. Everything downstream of the accepted version is fixed: the kind catalogue is fixed, the opcode table is fixed, the row-tail layouts are fixed, the rights bits are fixed, and the wire framing is fixed. A client does not query "does this compositor support `KIND_XDG_POPUP`?" — a compositor that implements PWP-2.x supports every kind in the PWP-2.x vocabulary or is not a PWP-2.x compositor.

Version acceptance is boolean; there is no "partial support" state, no "graceful degradation" path, no per-feature opt-out. A partial implementation is not a valid PWP compositor.

The version-tuple exchange is the first message pair on every PWP connection. The client sends `(major, minor)` as its declared *minimum* accepted version; the compositor replies either with `ACCEPT(major, minor)` naming its exact implemented version (which the client checks for `>= client_minor` within the same `major`), or with `REFUSE(compositor_major, compositor_minor, reason)`. There is no third message. A compositor that receives a version tuple with a `major` it does not implement replies REFUSE unconditionally; there is no cross-major fallback path. Clients that need to support multiple `major` versions do so at the client-library layer, by opening independent connections at different `major` tags, not by negotiating within one connection.

---

## §3. Amendment path (in place of extensions)

New protocol functionality does not land as an extension. It lands as a **minor version bump** — the amendment mechanism owned by G7-M7-002 (paideia-os#2272). The path is:

1. A candidate change is drafted as a monorepo RFC against `design/compositor/pwp-spec-vocabulary.md`. The RFC either adds a `KIND_*` entry to §2, adds a field inside an existing row-tail schema, or adds a rights bit to an existing kind. It does not add a new global namespace.
2. The RFC lands at a minor-bump gate — PWP-2.x → PWP-2.(x+1) — and the freeze-review discipline of G7-M1-004 re-runs on the delta. See `paideia-os#2272` for the cadence, review windows, and criteria.
3. On acceptance, every downstream consumer listed in `pwp-spec-vocabulary.md` §6 is updated in the same monorepo PR (a MASTER_PLAN §10.3 serialization point). No consumer is left running against the old minor.
4. Compositors and clients tag their supported version tuple; the version-mismatch error at connection time is the sole compatibility mechanism.

The minor-bump cadence is deliberately slow. G7-M7-002 sets the expected floor at one minor per year absent an interop bug that demands earlier. This is a cost, and it is written down in §4.

The following patterns are **forbidden by policy**, not merely absent from the current draft:

1. **Vendor-prefixed globals** (`wp_*`, `zwp_*`, `xdg_*`, `ext_*`, or any bare-vendor prefix). A PWP wire message that names a kind outside the current-minor §2 catalogue is a wire protocol violation, not an unrecognised extension. The parser rejects at the framing layer.
2. **Extension negotiation over the wire.** No capability handshake exists beyond the version-tuple exchange. A client does not send a list of desired extensions; a compositor does not advertise a list of supported extensions.
3. **Compositor-defined "custom" KIND ids.** A compositor MAY NOT mint a KIND ordinal outside the range allocated to it in `next-wave-derived-kinds.md` for the current PWP minor. Cross-repo kind allocation is the sole authority.
4. **Client-defined KIND ids.** A client MAY NOT introduce a KIND identifier into the wire. Client-side vocabulary is `KIND_UI_CONTEXT`-shaped (G12), which composes on top of PWP without adding wire kinds.
5. **Text-format capability probes.** No "does this compositor support colour management?" query exists. Either the current PWP minor's vocabulary includes `KIND_COLOR_PROFILE`-adjacent kinds or it does not; the answer is knowable from the accepted version.
6. **Optional message opcodes.** Every opcode in the wire table at a given PWP minor is mandatory. A compositor that does not implement every opcode at its declared minor is not a valid compositor at that minor. There are no "SHOULD-implement" or "MAY-implement" wire ops; the RFC 2119 vocabulary at the wire layer is MUST or absent.
7. **Draft / experimental / staging namespaces.** No parallel "unstable" protocol namespace exists. A feature is either in the current PWP minor's frozen vocabulary or it is not on the wire. Prototyping happens against a private branch of the spec, not against clients in the field.
8. **Compositor-specific "extra" opcodes.** A specific compositor implementation (svc-compositor, or any downstream fork) MAY NOT add opcodes to the wire. Wire authority is the spec, not the implementation.

Each of the eight is a rejection criterion at freeze review (G7-M1-004) and at every subsequent minor-bump review (G7-M7-002).

### 3.1 Worked example — an amendment that lands as a minor bump

To make the amendment path concrete: suppose the freeze-review record has PWP-2.7 in the field, and a hardware round (say R41) introduces a new display-side capability — a per-plane HDR peak-luminance clamp — that the compositor should expose to clients so a toolkit can render tone-mapped previews at the correct nit level. Under a Wayland-shape mechanism this would be a `wp-hdr-preview-v1` extension, negotiated at `wl_registry` bind time, implemented by whichever compositor volunteered first, and ignored by the rest. Under PWP the same change is:

1. Draft `pwp-rfc-2.8-hdr-peak-clamp.md` against `design/compositor/pwp-spec-vocabulary.md`, adding a `peak_nits` field inside the `KIND_HDR_METADATA` row-tail already carried by `KIND_SURFACE` (§2.1). The RFC declares the target minor: PWP-2.8.
2. The G7-M7-002 minor-bump review committee runs the freeze-review criteria on the delta: does the change respect linearity? does it break wire framing? does it touch a linearity boundary the vocabulary index does not describe? The rejection criteria in §3.1–§3.8 above are checked by name.
3. On acceptance, the same monorepo PR updates `pwp-spec-vocabulary.md`, `pwp-spec-wire.md` (row-tail size grows), the reference `svc-compositor` implementation, every toolkit `KIND_UI_CONTEXT`-shaped consumer, and the conformance suite. All downstream consumers named in `pwp-spec-vocabulary.md` §6 are touched in one PR.
4. `PWP_MINOR` bumps from 7 to 8. Existing PWP-2.7 clients continue to connect; the compositor accepts them and truncates the row-tail on outbound messages. Existing PWP-2.7 compositors refuse a client that asks for PWP-2.8. The version-mismatch is the sole compatibility surface.

The RFC did not add a global. It did not add an opcode. It added a field inside a schema that was already frozen at row-tail size 128 bytes and is now frozen at row-tail size 132 bytes. The change is auditable as a single commit against a single file, and the interop matrix picks up one new column (`2.8 supports peak_nits`) rather than one new axis.

---

## §4. Consequences (both sides)

### 4.1 Positive

- **No client fallback trees.** A client never writes "if the compositor does not support `wp-fractional-scale-v1`, do integer scaling." Fractional-scale is either in the accepted PWP minor or the connection was refused at handshake. Client code paths collapse.
- **Static toolkit codegen.** A toolkit compiled against PWP-2.7 emits exactly the message opcodes for PWP-2.7. No runtime capability queries, no conditional dispatch, no dynamic loader for optional protocol modules. The toolkit binary and the spec version are in 1:1 correspondence.
- **Reproducible interop test matrix.** The interop matrix has one axis (version) rather than N (extensions). A conformance suite for PWP-2.7 is a single artefact; a compositor either passes it end-to-end or is not a PWP-2.7 compositor. There is no "conformant with respect to the subset we implement" reading.
- **Fewer attack surfaces.** Extension parsers have been Wayland CVE hotspots (e.g. `wl_shm`-adjacent format handling, cursor-theme deserialisation, image-format probes in unstable protocols). A closed vocabulary means the parser surface is fixed at each minor and can be fuzzed exhaustively at freeze review. New CVE surface arrives only at minor-bump review, on a cadence measured in years.
- **Auditable protocol evolution.** Every wire capability change is a monorepo commit against `pwp-spec-vocabulary.md` plus a minor version tag. `git log` on that file is the complete history of PWP wire semantics; there is no separate registry to consult.
- **Session-type integrity.** The paideia-as row-polymorphic session-type discipline (`compositor substrate` bundle) requires the effect row to be closed at compile time. A closed protocol vocabulary is the substrate the effect row is written against; an extension mechanism would force the row to be dynamic.
- **No "flag-day compositor" pressure.** Because the vocabulary is closed at each minor, a compositor upgrade is a single-axis event. Users do not experience the Wayland pattern of "the compositor updated and now client X does not render because extension Y was renamed at v3."

### 4.2 Negative

- **Slower prototyping.** A protocol change must go through the minor-bump gate — RFC, freeze review re-run, cross-consumer update in one PR. Experimental protocols cannot land in-tree behind a feature flag; they land in the next minor or not at all. Expected cadence floor is one minor per year (G7-M7-002).
- **Vendor-specific hardware features surface differently.** A GPU vendor's proprietary interop primitive (e.g. AMD's implicit-sync forwarding, NVIDIA's swapchain hint bits) surfaces via out-of-band `KIND_GPU_*` capabilities minted by the display authority, not via a compositor-visible extension. The compositor sees a stable `KIND_VK_SWAPCHAIN_IMAGE`; the vendor-specific tuning is under the kernel-side `KIND_GPU_CONTEXT` derivation. Wire ops do not multiply per vendor.
- **Compositor authors cannot ship experimental protocols in-tree.** A downstream compositor fork that wants to try a new interaction pattern cannot ship it as `wp-fork-experimental-v1`. It ships as a private branch of the spec, exercises it in a private client set, and lands the delta in the next PWP minor if the community accepts it. The rejection of the private-fork pattern is deliberate: it is what stops the extension registry from re-forming under a different name.
- **Third-party compositors compete on implementation quality, not protocol variety.** Every conformant PWP-2.x compositor speaks the same vocabulary; differentiation is renderer performance, scheduling policy, session integration — never wire semantics. This narrows the design space for competing compositor authors and is a real cost, taken with eyes-open.
- **A "hot" client feature waits for the next minor.** A client that wants a wire capability the current minor does not carry either waits for the bump or contributes an RFC that meets the freeze-review bar. There is no fast lane. The trade is: fewer, better, jointly-designed wire changes, at the cost of latency to add any single one.
- **Retiring a wire capability is a major-version bump, not a graceful deprecation.** Because every opcode at a given minor is mandatory, an opcode cannot be marked "deprecated, do not use." Removal is a `<major>` bump — the connection-time version-mismatch error is the sole mechanism for cutting over. G7-M7-002 documents the major-bump discipline; the expected cadence is one major per decade or on a survivable design bug.

The consequences are symmetric with the positive side: interop determinism buys stability and audit surface; the prototyping cost is the price of that stability.

### 4.3 What the trade actually forecloses

To make the acceptance-of-cost explicit, three concrete categories of future work are ruled out at the wire layer by this policy:

- **Compositor-shipped "labs" features.** A researcher who wants to explore, say, a stylus-driven per-stroke input protocol cannot ship it as `pwp-labs-stylus-v1` and iterate against willing clients over a release cycle. The iteration happens on a private branch and lands atomically at a minor bump — or does not land at all. This is the cost of foreclosing the drift path.
- **Per-vendor optimisation surfaces.** Hardware vendors accustomed to shipping IHV-specific extensions (the pattern OpenGL/Vulkan preserves under "vendor extensions promoted to KHR promoted to core") cannot use the compositor wire as that surface. Vendor tuning lives under the kernel-side `KIND_GPU_*` and `KIND_DISPLAY_*` derivations, not at the compositor boundary. The compositor sees a uniform vocabulary; the vendor-specific work happens below the compositor line.
- **Downstream compositor differentiation on wire semantics.** A future PaideiaOS compositor fork — say, one optimised for tiling-window-manager workloads — cannot differentiate by adding a `tiling-hints-v1` protocol clients can opt into. It differentiates by implementing the same PWP-2.x vocabulary with a different scheduling and layout policy, addressable through the same wire. Users switching compositors do not switch protocols.

None of these are accidents of the current draft; all three are deliberate consequences of the single-protocol commitment. Each is the price of the interop matrix collapsing to one axis.

---

## §5. Enforcement

The policy is enforced at four layers, in order of increasing radius:

1. **Wire framing (G7-M1-002, paideia-os#2243).** The framing layer does not encode any extension-namespace concept. A message that names an opcode outside the current-minor opcode table is a framing violation and closes the connection. There is no "unrecognised opcode, skip" behaviour; the parser refuses the frame.
2. **Vocabulary index (`pwp-spec-vocabulary.md` §2).** The kind catalogue is frozen at minor-version boundaries. A PR that adds a §2 entry without a matching minor bump is rejected at review. The freeze commitment is documented in `pwp-spec-vocabulary.md` §5.
3. **Freeze-review record (G7-M1-004, paideia-os#2245).** The initial freeze review sign-off enacts this policy. Subsequent minor-bump reviews (G7-M7-002 cadence) apply the same criteria: any pattern in §3.1–§3.8 is a rejection reason cited by name.
4. **Cross-repo cap-kind allocation.** Kind ordinals for PWP live in `next-wave-derived-kinds.md`. Allocation is monorepo-serialized under MASTER_PLAN §10.2; a compositor MAY NOT mint an ordinal it does not own, and a client MAY NOT introduce an ordinal at all. The single source of truth forecloses parallel-namespace drift.

Cross-links for reviewers reaching this doc from an RFC or an issue body:
- Freeze review sign-off: `design/compositor/pwp-spec-freeze-review.md` (G7-M1-004, paideia-os#2245).
- Minor-bump cadence: `design/compositor/version-cadence.md` (G7-M7-002, paideia-os#2272) — the amendment gate this policy points to.
- Kind catalogue: `design/compositor/pwp-spec-vocabulary.md` §2.
- Wire framing: `design/compositor/pwp-spec-wire.md` (G7-M1-002, paideia-os#2243).
- Pitfall origin: `design/roadmap/next-wave-synthesis.md` §4 P11, §7 R1.

### 5.1 Review checklist (verbatim, for RFC authors)

Every PWP RFC and every minor-bump review re-runs the following ten checks against the proposed delta. A "yes" on any of items 1–8 is a rejection; a "no" on 9 or 10 is a rejection.

1. Does the change introduce a new `wp_*`, `zwp_*`, `xdg_*`, `ext_*`, or vendor-prefixed global? — must be **no**.
2. Does the change add a runtime capability probe beyond the version tuple? — must be **no**.
3. Does the change mint a KIND ordinal outside the current allocation authority? — must be **no**.
4. Does the change introduce a client-defined KIND identifier onto the wire? — must be **no**.
5. Does the change add a "SHOULD-implement" or "MAY-implement" opcode? — must be **no**.
6. Does the change add a draft / experimental / staging namespace? — must be **no**.
7. Does the change add a compositor-implementation-specific opcode? — must be **no**.
8. Does the change break the linearity discipline of any kind in `pwp-spec-vocabulary.md` §4? — must be **no**.
9. Does the change include concurrent updates to every downstream consumer in `pwp-spec-vocabulary.md` §6? — must be **yes**.
10. Does the change carry the minor-version bump and the conformance-suite delta in the same PR? — must be **yes**.

The checklist is the operational form of the policy. It is copied into every RFC template and every minor-bump review record.

---

## §6. Related work

### 6.1 Wayland — the counter-example this policy answers

Wayland shipped in 2008 with a core protocol of ~20 interfaces and a `wl_registry` mechanism for adding more. By 2013, the extension ecosystem included ~10 stable and unstable protocols; by 2025, the count crossed 100 across the `wp-*`, `zwp-*`, `xdg-*`, and `ext-*` namespaces, with additional per-compositor prefixes (`kde_*`, `weston_*`, `wlr_*`, `treeland_*`, etc.). The lived consequence is documented across a decade of interop bug reports: two compositors implementing the same feature via different extension names, clients carrying fallback trees N deep, and toolkits shipping runtime capability probes at every startup.

The mechanism that made this inevitable is not extension proliferation itself — it is `wl_registry` as a runtime negotiation surface. Once the mechanism exists, the extension slot is always the cheaper path than reworking the core vocabulary. PWP forecloses the mechanism.

Three specific Wayland patterns that PWP structurally cannot reproduce:

- **The "compositor missing extension X" fallback.** Clients like Firefox, Chromium, Kitty, and GTK ship code paths of the form `if (wp_fractional_scale_manager_v1 == NULL) { round_scale_to_integer(); } else { request_fractional_scale(); }`. Under PWP the check is impossible: the accepted version tuple determines the answer at compile time, and both branches do not co-exist in the client binary.
- **The "extension renamed at v2" episode.** Wayland's `wp-linux-explicit-synchronization-v1` was superseded by `linux-drm-syncobj-v1` with different semantics for the same underlying facility; clients had to carry both dispatch paths for years. Under PWP the analogous transition is a major-version bump, not a name collision between coexisting extensions.
- **The "vendor-only extension" fragment.** `weston_direct_display`, `kde_screen_edge_v1`, and `treeland_dde_shell_v1` are compositor-specific extensions that clients targeting those compositors must code against explicitly. Under PWP the compositor-specific extension has no landing surface at all; features that are compositor-implementation-specific stay implementation-side and do not touch the wire.

### 6.2 X11 XExtension — the deeper counter-example

X11's extension mechanism, XExtension, was designed in 1987 to allow adding features without changing the core protocol. The 40-year lived experience is the reason PWP takes the opposite decision. A partial catalogue of X11 extensions still fielded in 2026: XRender, Xrandr, XFixes, XComposite, Xinerama, Xdamage, XKB, XI, XI2, XSync, XSHM, XVideo, MIT-SHM, DRI, DRI2, DRI3, Present, RECORD, RES, DPMS, Xevie, XSELinux, XTest, GLX, EGL — sixteen-plus extensions with active clients, most with their own quirks, their own version negotiation, and their own historical CVE surface. The X11 core is one protocol; the X11 real deployment is roughly 25.

PWP takes the discipline of the core and refuses the extension mechanism outright. The extension mechanism *is* the source of the sprawl; foreclosing it is the load-bearing decision.

### 6.3 Plan 9 / 9P — single-protocol discipline that scaled

Plan 9's 9P is the affirmative example. One protocol; one small vocabulary of messages (Tversion, Tauth, Tattach, Twalk, Topen, Tcreate, Tread, Twrite, Tclunk, Tremove, Tstat, Twstat, and their R-counterparts); no extension mechanism. Every resource in Plan 9 — files, networks, GUI windows, processes — is named as a file, addressed by 9P. The protocol evolved through numbered revisions (9P1, 9P2000, 9P2000.u, 9P2000.L), each a single monotone versioning step, not an extension.

The lesson PWP takes from 9P is that a small, closed protocol vocabulary can address a very broad surface if the vocabulary is chosen well and if the discipline against adding messages is kept. PWP's 22 kinds are the analogue of 9P's 13 message pairs — the closed set the protocol commits to, and the sole surface downstream tooling compiles against.

### 6.4 Fuchsia FIDL versioning — the modern comparable

Fuchsia's FIDL uses API-level versioning rather than extension negotiation: a component declares a minimum API level, the platform accepts or refuses, and the wire vocabulary at that level is fixed. This is closer to PWP's model than to Wayland's, and it is the closest existing precedent for the single-axis compatibility discipline PWP writes down. Where PWP diverges is in the compositor-specific vocabulary discipline — the closed KIND catalogue — and in the linearity contract carried on the wire; FIDL is a more general RPC substrate and does not impose either.

---

## §7. Amendment authority

This document itself is under the same discipline it enforces. Changes to §2 (the rule) require a major version bump. Changes to §3 (the amendment path) require a monorepo RFC and freeze-review re-run. Changes to §4 (consequences) are documentary and land at minor bumps as the lived experience of the discipline is recorded. Changes to §5 (enforcement) require concurrent updates to the layers named — a change to enforcement wording without a matching change to the wire framing spec or the vocabulary index is rejected as documentary drift.

The freeze-review record (G7-M1-004) enacts this policy on first sign-off. Every subsequent minor-bump review (G7-M7-002 cadence) re-affirms it. Retiring the policy is a major-version event and requires an explicit RFC arguing the extension mechanism has become worth its historical cost — an argument the current design considers structurally unwinnable, but which the version discipline allows to be made.

---

*End of no-extension policy. Cadence discipline lands at paideia-os#2272; freeze review record at paideia-os#2245.*
