# PWP protocol spec — vocabulary index

**Status:** Wave-0 Batch-1 KEYSTONE. First of the four G7 protocol-freeze drafts.
**Issue:** paideia-os#2242 (`G7-M1-001`), milestone `g7-compositor-protocol`.
**Depth:** authoritative reference for every downstream compositor issue in G7–G12.
**Date:** 2026-09-03.
**Scope:** enumerates the `KIND_*` derived capabilities the paideia-window-protocol (PWP) wire touches, names each one's linearity discipline and parent, and fixes the derivation graph downstream issues cite. No wire framing, no opcode tables, no lifecycle machine — those land as separate M1 siblings (#2243 / #2244) referencing this vocabulary index.

Related documents (read-only from this doc's viewpoint):
- `design/roadmap/next-wave-synthesis.md` §2 (Axis 2 G-round catalogue) and §5 (78 derived-kinds summary).
- `design/architecture/next-wave-derived-kinds.md` — the authoritative kind ordinal + failure-band registry; new kinds catalogued here reserve slots there at G7.M2+ landing time, not at spec time.
- `design/graphics/r101-kernel-plan.md` §4 — the kernel-side display authority chain (`KIND_DISPLAY_BACKEND` → `KIND_DISPLAY_ENGINE` → `KIND_DISPLAY_OUTPUT` → `KIND_DISPLAY_PLANE`) the compositor consumes but does not mint.
- `design/graphics/r102-wire-abi.md` (planned; MASTER_PLAN §10.1 Q-SVC-1 chore, agent W0-25) — byte-layout authority for every wire message the PWP carries between compositor and clients.
- `MASTER_PLAN.md` §10 (MECE invariants) — the design-doc single-authority rule this vocabulary is filed under.

---

## §1. Introduction

The paideia-window-protocol (PWP) is one wire protocol, spoken by one compositor process (`svc-compositor`), against one client contract, over a fixed vocabulary of derived capability kinds. The commitment "no `wp-*` / `ext-*` fragmentation" (pitfall P11 in `next-wave-synthesis.md` §4) turns on this vocabulary being closed at G7 protocol freeze: minor-version bumps may add fields inside the schemas below, and may add new kinds derived under them, but the roots enumerated here are the freeze surface.

This document exists so that every G7 / G8 / G9 / G10 / G11 / G12 issue can cite one place for kind names, parents, and linearity discipline. Downstream issues that name a `KIND_*` name that does not appear here, or that name a parent inconsistent with the graph in §3, are refused review until either this doc or the issue body is reconciled. The intent is exactly the intent MASTER_PLAN §10.2 encodes for cross-repo cap-kind allocation, lowered to compositor scope.

The doc is deliberately spec-shaped, not implementation-shaped: no `.pdx` code, no row-tail byte layouts, no opcode numbering. Those live in `pwp-spec-wire.md` (#2243) and in per-kind `kind_*.pdx` sources under `src/user/compositor/` when G7.M2+ agents land the real bodies. The kind ordinals themselves are allocated at landing time in `next-wave-derived-kinds.md` from the next free tag past `0x1B4`; treating slot allocation as a landing artefact rather than a spec commitment matches how the R91–R101 blocks already work in that registry.

Non-goals of this vocabulary index:
- (a) Anything the kernel already mints. `KIND_DISPLAY_OUTPUT`, `KIND_DISPLAY_PLANE`, `KIND_DISPLAY_TIMELINE`, `KIND_SCANOUT_LEASE`, `KIND_VK_SURFACE`, and `KIND_VK_SWAPCHAIN_IMAGE` are consumed by the compositor but are catalogued in `next-wave-derived-kinds.md` §R36 / §R37 / §G1 / §G2 / §G3 rows and are referenced (not re-defined) here.
- (b) The `KIND_HW_TIMELINE` derived family used for GPU→display sync. The compositor holds and forwards these; it does not mint them. See `next-wave-derived-kinds.md` and pitfall P1 in `next-wave-synthesis.md` §4.
- (c) Font / color / a11y-provider primitives that live one layer below the compositor. `KIND_FONT_ATLAS`, `KIND_TEXT_SHAPE`, `KIND_COLOR_PROFILE`, `KIND_HDR_METADATA`, `KIND_TONEMAP_LUT` are catalogued at G4 / G5 / G6.

---

## §2. Kind catalogue

Ordered by dependency depth from the composition root. Each entry gives (name → linearity → parent → purpose). Every kind derives *within* the compositor authority tree; the compositor process holds `RIGHT_MINT` on the parent of every root entry below.

### 2.1 `KIND_SURFACE`
- **Linearity:** non-linear (`RIGHT_MINT` present; children `KIND_SUBSURFACE`, `KIND_WINDOW` derive from it).
- **Parent:** `KIND_IPC_ENDPOINT = 5`.
- **Purpose:** the client-facing composition primitive. One `KIND_SURFACE` is one 2D region the client renders into, addressed as an RPC endpoint the compositor answers on. Carries scale factor, viewport, transform, colour profile ID, buffer-attach state, and the current `KIND_DAMAGE_REGION` reference. The whole compositor tree grows off this root; `KIND_WINDOW`, `KIND_LAYER`, `KIND_SUBSURFACE`, and `KIND_INPUT_ROUTE` all name a surface as their anchor. Fractional-scale as first-class per pitfall P3 (`next-wave-synthesis.md` §4) means the scale factor lives on the surface, not on the swapchain, matching the shape `KIND_VK_SURFACE` already writes down.

### 2.2 `KIND_SURFACE_COMMIT`
- **Linearity:** **LINEAR** (no `R_MINT`; consumed on commit).
- **Parent:** `KIND_SURFACE`.
- **Purpose:** one atomic-commit transaction against a surface. The client accumulates pending state (buffer attach with `(timeline_id, value)`, damage region, geometry updates, subsurface reparent) on the cap; the compositor consumes the cap at commit, atomically transitions the surface to the new state at the timeline value the buffer waits on, and issues a fresh `KIND_PRESENT_FEEDBACK` event when the frame reaches scanout. Linearity here forecloses double-commit and torn frames; the primitive is the wire-level counterpart of `KIND_MODESET_TXN` at the display layer.

### 2.3 `KIND_SUBSURFACE`
- **Linearity:** non-linear.
- **Parent:** `KIND_SURFACE`.
- **Purpose:** an anchored, positioned child surface inside a parent surface's coordinate space. Sync mode (sync / desync) is stored on the edge; sync-mode subsurfaces commit atomically with the parent's `KIND_SURFACE_COMMIT`, desync subsurfaces commit independently. Backs both video overlays (desync — commit at frame cadence) and toolkit-level compositing regions (sync — commit at UI-frame cadence). Never carries top-level window semantics; upgrade to `KIND_WINDOW` is a distinct mint.

### 2.4 `KIND_WINDOW`
- **Linearity:** non-linear.
- **Parent:** `KIND_SURFACE`.
- **Purpose:** the toplevel window authority. Adds z-order slot, parent-window edge (for modality), tab-order slot, workspace slot, and — mandatorily, per pitfall P4 — an `KIND_A11Y_TREE` binding at mint time. Windows are the granularity of user-visible focus and of the XDG-shell-equivalent state machine (§2.7). Every `KIND_WINDOW` mint is audited so a lost-window bug becomes a searchable event, not an ambient-state guess.

### 2.5 `KIND_LAYER`
- **Linearity:** non-linear.
- **Parent:** `KIND_WINDOW`.
- **Purpose:** a per-window compositing layer edge. Carries the layer role (background / content / overlay / cursor / notification), its blend equation, and its damage-tracking bucket. Layers are the unit the compositor addresses when it decides to promote content to a hardware plane for direct-scanout candidacy versus composite-through-shader.

### 2.6 `KIND_LAYER_TREE`
- **Linearity:** non-linear (sealed subtree; traversal is via row indirection, no ambient pointer walk).
- **Parent:** `KIND_WINDOW`.
- **Purpose:** the ordered forest of `KIND_LAYER` edges rooted at one window, with damage-region propagation rules attached. A commit against the tree walks the subtree in stable order, aggregating damage (per §2.10) up to the window root so the compositor can issue a minimal repaint. The sealed-subtree discipline stops a compromised client from reaching a sibling window's layer tree through the same channel.

### 2.7 `KIND_XDG_TOPLEVEL_STATE` and `KIND_XDG_POPUP`
- **Linearity:** non-linear (both).
- **Parent:** `KIND_WINDOW` (both).
- **Purpose:** the XDG-shell-equivalent surface pair. `KIND_XDG_TOPLEVEL_STATE` carries the window-state enum ({normal, maximized, fullscreen, minimized, tiled-{left,right,top,bottom}}), the current window geometry (excluding client-side decoration), and interactive-resize edge bindings. `KIND_XDG_POPUP` carries popup positioning against a parent, the grab semantics for input capture, and the dismiss chain. Both are separate kinds rather than fields on `KIND_WINDOW` so a toolkit that composes windows differently (e.g. tiling-only, no popup semantics) can hold `KIND_WINDOW` without ever minting a popup.

### 2.8 `KIND_OUTPUT`
- **Linearity:** non-linear (compositor-side view of a kernel-minted cap).
- **Parent:** `KIND_DISPLAY_OUTPUT = 0x170` (see `next-wave-derived-kinds.md` §R36).
- **Purpose:** the compositor-facing name for one addressable output surface. Not a new mint at the kernel level — the compositor holds a `KIND_DISPLAY_OUTPUT` from the display driver and re-exports a narrower `KIND_OUTPUT` cap to clients that need to name an output for placement (fullscreen, per-output workspace binding, VRR opt-in). Rights on the client-visible `KIND_OUTPUT` are QUERY-only; the `RIGHT_MINT` needed to lease a plane stays with the compositor.

### 2.9 `KIND_SEAT`
- **Linearity:** non-linear.
- **Parent:** `KIND_IPC_ENDPOINT = 5`.
- **Purpose:** one collection of input devices bound to one logical user session (per Wayland's seat vocabulary). Carries keyboard, pointer, and touch device slots; a workstation with two keyboards and one mouse can present a single seat, while a multi-seat kiosk configuration presents two. Seat identity is what `KIND_INPUT_ROUTE` binds against, and what `KIND_SEAT` lock/unlock (G8.M5-002, #2286) mediates for the emergency-console handover flow.

### 2.10 `KIND_INPUT_ROUTE`
- **Linearity:** **LINEAR** (consumed when the routing decision is made; no double-route).
- **Parent:** `KIND_IPC_ENDPOINT = 5`, with mint-time reference to a `KIND_SEAT` and a `KIND_SURFACE`.
- **Purpose:** one directed input-event route from a seat's active device to a surface at a moment in time. The input server (a compositor-*independent* process; pitfall P2) mints a route per focus decision, delivers the events through it, and consumes it on focus change. The linearity discipline forecloses the "grabbed input keeps firing after focus moved" bug class Wayland's implicit grab shape has re-hit repeatedly.

### 2.11 `KIND_DAMAGE_REGION`
- **Linearity:** non-linear.
- **Parent:** `KIND_MEMORY = 4`.
- **Purpose:** one rect-list describing the sub-region of a surface that changed since the last commit. Carries a rect-count header and up to N (bounded, per row-tail) `(x, y, w, h)` entries; aggregation across the subsurface tree is by union with clipping, computed at commit time. Buffer-age-aware repaint (G9.M3-002, #2295) reads damage regions across N frames to decide how much of the front buffer to re-composite.

### 2.12 `KIND_PRESENT_FEEDBACK`
- **Linearity:** non-linear (stream-shaped).
- **Parent:** `KIND_IPC_ENDPOINT = 5`.
- **Purpose:** the per-surface feedback stream that carries `(target_time, actual_time, refresh_period, present_id, flags)` back to the client after every present. Mandatory per pitfall P6 (`next-wave-synthesis.md` §4). Enables client-side adaptive-rate presentation (e.g. dropping from 120 Hz to 60 Hz cadence under load), missed-vsync detection, and back-pressure signalling. The compositor budget is one refresh period; the classifier (#2299) labels events as ON-TIME / LATE / MISSED / SKIPPED against that budget.

### 2.13 `KIND_WORKSPACE`
- **Linearity:** non-linear.
- **Parent:** `KIND_IPC_ENDPOINT = 5`.
- **Purpose:** one addressable workspace — the granularity of "switch what set of windows is visible on which output". Carries a workspace ID, a per-workspace window set, a tiling layout descriptor, and a per-output visibility mapping. Workspace switch is a present-timeline-synchronised atomic transition (#2289) so the user never sees half-old / half-new state during the switch. Per-workspace persistence is a session-hook consumer (#2290).

### 2.14 `KIND_CLIP_OFFER`
- **Linearity:** SEALED cap flow (opaque MIME payload; no ambient broadcast).
- **Parent:** `KIND_MEMORY = 4`.
- **Purpose:** one clipboard offer — the source window's serialised payload advertised over MIME types, wrapped as a sealed capability so a paste operation is an explicit capability handoff and not an ambient global-state read. Selection ownership (§2.16) issues the offer; the compositor delivers it to the target window at paste-request time; no third process can silently observe the clipboard. Solves the "any app can snoop the clipboard" X11 problem structurally.

### 2.15 `KIND_DND_OFFER`
- **Linearity:** SEALED cap flow (short-lived; consumed at drop).
- **Parent:** `KIND_MEMORY = 4`.
- **Purpose:** one in-flight drag-and-drop offer. MIME-typed like a clip offer, but scoped to the active drag session with a drop-target capability handoff at the accept boundary. The source releases the cap when the drop is either accepted (delivered to the target) or cancelled (returned to the source without leakage). Structurally forecloses "drag-payload leaked to hovered-but-not-dropped windows".

### 2.16 `KIND_SELECTION_OWNER`
- **Linearity:** non-linear (single owner per selection kind: primary / clipboard).
- **Parent:** `KIND_IPC_ENDPOINT = 5`.
- **Purpose:** the authority that owns a selection (primary or clipboard) at a moment. Ownership is revoked on window destroy so a stale selection reference never survives its window; the next paste attempt against a revoked owner fails cleanly rather than reading freed memory or unrelated content. One selection kind, one owner, at any time.

### 2.17 `KIND_RECOVERY_PLANE`
- **Linearity:** non-linear (reservation is stable; the plane cap is minted once at boot).
- **Parent:** `KIND_DISPLAY_PLANE = 0x173` (see `next-wave-derived-kinds.md` §R36).
- **Purpose:** the reserved primary plane on pipe 0 for the recovery console. Held by the input server (not by `svc-compositor`) so a compositor lockup never blocks the plane. Pitfall P8 enforcement: `KIND_SCANOUT_LEASE` mint refuses `plane_slot == SL_RESERVED_PLANE_SLOT` (already written down in `next-wave-derived-kinds.md` §0x188), and `KIND_RECOVERY_PLANE` is that slot's cap-shaped name. Takeover flow (#2270) is what promotes the input server to the display source when compositor death is detected.

### 2.18 `KIND_IME_SESSION`
- **Linearity:** **LINEAR** (one open composition session at a time per text-input surface).
- **Parent:** `KIND_IPC_ENDPOINT = 5`.
- **Purpose:** one open input-method composition session bound to one text-input surface. Consumed on session close (commit or cancel). Linearity forecloses the "two IMEs both think they own the composition" bug class Wayland's `text-input-v3` has hit; there is exactly one open session per surface per moment.

### 2.19 `KIND_IME_PROVIDER`
- **Linearity:** non-linear.
- **Parent:** `KIND_IPC_ENDPOINT = 5`.
- **Purpose:** the discoverable authority for an input-method provider (Latin autocomplete, Pinyin, Zhuyin, Kana, Hangul, Devanagari, InScript). The compositor's IME router (§2.20) selects a provider at session mint; the provider swap protocol (#2315) mediates runtime switch.

### 2.20 `KIND_IME_ROUTER`
- **Linearity:** non-linear (single-instance in compositor).
- **Parent:** `KIND_IPC_ENDPOINT = 5`.
- **Purpose:** the compositor-held authority that routes text-input events between the active `KIND_IME_SESSION`, the selected `KIND_IME_PROVIDER`, and the focused text-input surface. Pitfall P10 enforcement: one router, one keyboard-event contract, no `fcitx`/`ibus`/`scim` fragmentation. The router is what makes the compositor the *exclusive* IME router the synthesis commits to.

### 2.21 `KIND_A11Y_TREE`
- **Linearity:** non-linear (mutation-log-shaped; commits are linear at the boundary via #2304).
- **Parent:** `KIND_MEMORY = 4`.
- **Purpose:** one per-window accessibility tree in AccessKit-shape (nodes with role / state / value / edges). Bound *at* `KIND_WINDOW` mint (mandatory per #2305; elaboration fails without a subtree per #2307), so a11y is a first-class protocol participant, not a sidecar (pitfall P4). Screen readers subscribe against the tree; the compositor never has to guess at semantics.

### 2.22 `KIND_A11Y_NODE`
- **Linearity:** non-linear.
- **Parent:** `KIND_A11Y_TREE`.
- **Purpose:** one node in an accessibility tree — role, state, value, name, description, and edges to siblings and children. The catalogue of concrete role/state/value node schemas is the deliverable of #2303 and lands under `src/user/a11y/node_kind.pdx`.

**Catalogue count:** 22 kinds (20 new to G7–G11 + 2 re-exports of kernel-minted kinds `KIND_DISPLAY_OUTPUT` and `KIND_DISPLAY_PLANE`).

---

## §3. Derivation graph

Each arrow is "child derives from parent" (parent holds `R_MINT`). Kernel-minted kinds referenced but not defined here are drawn in `[brackets]`.

```
[KIND_IPC_ENDPOINT = 5]
  ├── KIND_SURFACE
  │     ├── KIND_SURFACE_COMMIT       (LINEAR)
  │     ├── KIND_SUBSURFACE
  │     └── KIND_WINDOW
  │           ├── KIND_LAYER
  │           ├── KIND_LAYER_TREE
  │           ├── KIND_XDG_TOPLEVEL_STATE
  │           └── KIND_XDG_POPUP
  ├── KIND_SEAT
  ├── KIND_INPUT_ROUTE                (LINEAR; refs KIND_SEAT + KIND_SURFACE)
  ├── KIND_PRESENT_FEEDBACK           (stream)
  ├── KIND_WORKSPACE
  ├── KIND_SELECTION_OWNER
  ├── KIND_IME_SESSION                (LINEAR)
  ├── KIND_IME_PROVIDER
  └── KIND_IME_ROUTER

[KIND_MEMORY = 4]
  ├── KIND_DAMAGE_REGION
  ├── KIND_CLIP_OFFER                 (SEALED)
  ├── KIND_DND_OFFER                  (SEALED)
  └── KIND_A11Y_TREE
        └── KIND_A11Y_NODE

[KIND_DISPLAY_OUTPUT = 0x170]  (kernel-minted; re-exported)
  └── KIND_OUTPUT                     (compositor-issued QUERY-only view)

[KIND_DISPLAY_PLANE = 0x173]   (kernel-minted; reserved slot)
  └── KIND_RECOVERY_PLANE
```

Downstream issues reference this graph by kind name. Where a downstream issue introduces a further-derived kind (e.g. G12 toolkit layers over `KIND_WINDOW`), it MUST land its ordinal in `next-wave-derived-kinds.md` first, per MASTER_PLAN §10.2.

---

## §4. Linearity properties

Per pitfall P1 (`next-wave-synthesis.md` §4), the compositor's substrate for atomicity is linearity — a linear cap cannot double-commit, cannot re-parent, and cannot be forged into a wide side channel. Four kinds in this catalogue are linear; two are SEALED cap flows; the rest are non-linear (`RIGHT_MINT` present).

| Kind                          | Discipline                       | Rationale                                                                                          |
|-------------------------------|----------------------------------|----------------------------------------------------------------------------------------------------|
| `KIND_SURFACE_COMMIT`         | LINEAR                           | One commit per transaction; consumed at the atomic transition. Foreclosures double-commit / torn frames. |
| `KIND_INPUT_ROUTE`            | LINEAR                           | One route per focus decision; consumed at focus change. Foreclosures stale-grab bugs.               |
| `KIND_IME_SESSION`            | LINEAR                           | One open composition per text-input surface. Foreclosures dual-IME races.                           |
| *(binding-only linear)*       | LINEAR at bind boundary          | `KIND_A11Y_TREE` mutation log commits linearly at the boundary via #2304 but is non-linear as a cap. |
| `KIND_CLIP_OFFER`             | SEALED                           | MIME payload opaque; delivered by explicit cap handoff; no ambient broadcast.                       |
| `KIND_DND_OFFER`              | SEALED                           | As above, plus scoped to the active drag session.                                                   |
| All other kinds in §2         | non-linear (derived; `R_MINT`)    | Standard `KIND_*` derivation pattern per `linearity-and-tags.md`.                                    |

Kernel-minted kinds the compositor consumes (`KIND_DISPLAY_TIMELINE`, `KIND_MODESET_TXN`, `KIND_SCANOUT_LEASE`, `KIND_VK_SWAPCHAIN_IMAGE`, `KIND_GPU_CONTEXT`, `KIND_GPU_SUBMIT`) carry their own linearity discipline as documented at their landing in `next-wave-derived-kinds.md` §R36 / §R37 / §G1 / §G2 / §G3; this document does not re-decide them.

---

## §5. Freeze plan — pointer to G7.M1-004

This vocabulary index is one of four G7.M1 protocol-freeze drafts. The full freeze surface is:

- **G7.M1-001** (paideia-os#2242) — *this document* — vocabulary index (kind names, linearity, parents).
- **G7.M1-002** (paideia-os#2243) — `design/compositor/pwp-spec-wire.md` — wire framing + request/event opcode tables.
- **G7.M1-003** (paideia-os#2244) — `design/compositor/pwp-spec-lifecycle.md` — atomic-commit lifecycle + timeline-guarded state machine.
- **G7.M1-004** (paideia-os#2245) — `design/compositor/pwp-spec-freeze-review.md` — the 3-week freeze-review record and sign-off gate.

Per pitfall register row R1 (`next-wave-synthesis.md` §7), compositor protocol calcification is the top-ranked risk in the entire next-wave roadmap (damage: Irrecoverable; probability: High). The mitigation is the 3-week freeze review before any G7.M2 code lands: three external reviewers if reachable (Fuchsia / Wayland / Zed shape); no-extension-protocol written policy (#2271); a11y-tree binding as *acceptance* on G7 close.

**No changes to this vocabulary after G7.M1-004 sign-off** without a monorepo PR that also updates every consumer named in §6. That PR is a session serialization point per MASTER_PLAN §10.3.

---

## §6. Downstream consumers

The rows below cite this document by relative path (`design/compositor/pwp-spec-vocabulary.md`) in their issue body. This list is the file-touch closure over which a vocabulary change is a breaking change.

**G7 (compositor protocol) — 20 issues:**
- G7.M2-001..004 (#2246, #2248, #2250, #2252) — `KIND_SURFACE` + `KIND_SURFACE_COMMIT` + geometry + buffer-attach.
- G7.M3-001..003 (#2254, #2256, #2258) — `KIND_WINDOW` + `KIND_LAYER_TREE` + subsurface sync modes.
- G7.M4-001..003 (#2260, #2262, #2265) — XDG-shell-equivalent states / geometry / popup.
- G7.M5-001..003 (#2266, #2267, #2268) — clipboard / DnD / selection.
- G7.M6-001..002 (#2269, #2270) — recovery-plane reservation + takeover.
- G7.M7-001..002 (#2271, #2272) — no-extension policy + minor-version cadence.
- G7.M8-001 (#2273) — T14 hw-smoke first-window.

**G8 (input routing) — 4 issues:** G8.M1-001..002 (#2274, #2275), G8.M2-002 (#2278), G8.M5-001..002 (#2285, #2286).

**G9 (windowing + feedback) — 12 issues:** G9.M1-001..003, G9.M2-001..003, G9.M3-001..003, G9.M4-001..003 (#2288–#2299).

**G10 (accessibility) — 11 issues:** G10.M1-001..003 (#2302, #2303, #2304), G10.M2-001..003 (#2305, #2306, #2307), G10.M3-001..003, G10.M4-001..002 (#2311, #2312), plus G10.M5-001 T14 hw-smoke.

**G11 (IME) — 12 issues:** G11.M1-001..003 (#2314, #2315, #2316), G11.M2 / M3 / M4 / M5 series (#2317–#2324), plus G11.M6-001 T14 hw-smoke.

**G12 (toolkit) — 8 issues cite this doc transitively via `KIND_UI_CONTEXT`:** G12.M1-001..003 (#2326–#2328), G12.M2-001..003 (#2329–#2331), G12.M3-001 (#2332), G12.M4-002 (#2336).

**paideia-as cross-repo — 1 bundle:** `paideia-as v0.29 compositor substrate` (row-polymorphic effects, handler composition, session-type recursion) blocks G7.M2 landing but references this doc for target-vocabulary shape.

**Total downstream-consumer count:** 68 paideia-os issues + 1 paideia-as bundle = 69 rows explicitly unblocked or shape-constrained by this vocabulary. Transitively, every issue in G7–G12 (~102 rows in the manifest) touches at least one kind named here.

---

*End of vocabulary index. Sibling M1 drafts land at #2243, #2244; freeze-review record and sign-off gate at #2245.*
