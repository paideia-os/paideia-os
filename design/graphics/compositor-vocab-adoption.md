# svc-compositor vocabulary adoption — wire shape mapping

**Status:** Design (wave α-03). Docs-only.
**Date:** 2026-09-14.
**Grounds in:** `design/compositor/pwp-spec-vocabulary.md` (frozen kind catalogue), `src/kernel/core/cap/kind_surface.pdx`, `kind_framebuffer.pdx`, `kind_seat.pdx`, `design/kernel/compositor-impl-backtrack.md`, `ECOSYSTEM_STATUS.md` (2026-09-13).
**Precedes:** `design/graphics/compositor-lineage.md` (α-04), which sets why `svc-compositor` — not the in-tree library — is the vocabulary adopter.

## 0. Correction to the wave brief's ordinals

The wave brief that motivated this document named the target as
"`KIND_SURFACE` (0x1BA)". That ordinal is wrong in the current tree —
worth recording here since it is exactly the kind of drift this
document exists to prevent:

- `KIND_SURFACE = 0x1B8` (`src/kernel/core/cap/kind_surface.pdx:107`).
- `0x1BA` is `KIND_SUBSURFACE` (`src/kernel/core/cap/kind_session.pdx:70`).

Every mapping below uses the values read directly from the kernel
source, not the brief.

## 1. What "adopt the vocabulary" means concretely

`svc-compositor` (satellite, v1.4.0) currently owns its own R102-v0
wire structures and does not reference any `KIND_*` ordinal from the
kernel's cap registry — confirmed by `ECOSYSTEM_STATUS.md`: "Does not
yet consume the new kernel-side `KIND_SURFACE`/`KIND_FRAMEBUFFER`/
`KIND_SEAT` cap-handler wiring." Adoption means every place
`svc-compositor` currently synthesizes its own surface/window/scanout
record needs to instead mint or query the matching kernel cap via
`sys_cap_invoke`, using the op ordinals the kernel handlers already
dispatch on.

## 2. Per-kind wire shape mapping

### 2.1 `KIND_SURFACE = 0x1B8`

- **Kernel side:** `src/kernel/core/cap/kind_surface.pdx` (16-row pool,
  `cap_handler_surface`), mint packs `(w, h, format)` into `op_arg`'s
  upper 56 bits for the MINT ordinal (fixed by
  `design/kernel/compositor-impl-backtrack.md` COMP-IMPL-02 —
  previously `cap_invoke_dispatch`'s `call_kind_surface` shim zeroed
  these fields, making MINT unreachable). Row carries `surface_id`,
  scale, viewport, transform, colour-profile ID, buffer-attach state,
  current `KIND_DAMAGE_REGION` reference (`pwp-spec-vocabulary.md`
  §2.1). Parent: `KIND_IPC_ENDPOINT = 5`.
- **svc-compositor today:** synthesizes its own `window_table` entry
  per client connect (`ECOSYSTEM_STATUS.md`: "real window table") with
  no kernel-cap backing.
- **Wire mapping:** replace the ad-hoc window-table-row mint with
  `sys_cap_invoke(slot=<parent IPC endpoint>, op_arg=MINT | (w<<8) |
  (h<<32) | (format<<48))` (exact bit packing per
  `kind_surface.pdx`'s MINT-ordinal shim) and store the returned
  `surface_id` as the window table's primary key instead of a
  locally-generated one. Every subsequent `PWP_SURFACE_COMMIT` the
  client sends over the existing IPC channel becomes a second
  `sys_cap_invoke` against the same slot rather than a local state
  mutation.

### 2.2 `KIND_FRAMEBUFFER = 0x1AF` (the brief's "`KIND_FB_SCANOUT`")

- **Naming reconciliation, already recorded once:**
  `compositor-impl-backtrack.md` COMP-IMPL-03 established there is no
  `KIND_FB_SCANOUT` kind anywhere in the tree; the kind that owns the
  boot-populated LFB descriptor is `KIND_FRAMEBUFFER = 0x1AF`
  (`kind_framebuffer.pdx:99`), derived over `KIND_MEMORY`. This
  document reuses that finding rather than re-deriving it, and flags
  it because the wave brief repeats the stale "`KIND_FB_SCANOUT`" name
  — a second sighting of the same naming drift is worth a citation
  chain, not a second investigation.
- **Kernel side:** `cap_handler_framebuffer.pdx` dispatches QUERY ops
  (`FB_OP_QUERY_VA`, `_STRIDE`, `_WIDTH`, `_HEIGHT`, `_FORMAT` — the
  last backed by the new `fb_row_pixel_format` accessor). FLIP and
  REVOKE are **dedicated syscalls** (108–113,
  `design/user/syscall-table.md`), not `cap_invoke` ops — the 2-arg
  `sys_cap_invoke(slot, op_arg) -> u64` ABI cannot return the packed
  `{lfb_ptr, pitch, width, height}` tuple in one call, so a caller
  issues four separate QUERY invokes.
- **svc-compositor today:** scanout blit is "a WEAK-stub (canned
  1920x1080)" — it never reads real geometry at all.
- **Wire mapping:** on compositor startup, resolve the boot-assigned
  framebuffer slot, then issue the four QUERY invokes
  (`FB_OP_QUERY_WIDTH`/`_HEIGHT`/`_STRIDE`/`_VA`) to populate real
  geometry, replacing the canned 1920x1080 constant. Present/flip goes
  through `sys_framebuffer_flip` (sysno in the 108–113 dedicated range,
  `design/user/syscall-table.md`), not through `cap_invoke` — this is
  the one kind in this mapping where "adopt the vocabulary" means
  "call the dedicated syscall," not "call cap_invoke."

### 2.3 "`KIND_INPUT_EVENT`" — does not exist; two real candidates

No kind named `KIND_INPUT_EVENT` exists anywhere in the tree (kernel
or user). Two kernel-registered kinds cover adjacent ground, and
neither is a drop-in match:

- **`KIND_SEAT = 0x1BF`** (`kind_seat.pdx:143`, base 5 =
  `KIND_IPC_ENDPOINT`) — session/seat *authority*, not a per-event
  stream. `cap_handler_seat.pdx` is what R113's focus/input-routing
  gates against (`compositor-impl-backtrack.md` COMP-IMPL-04 renamed
  the brief's imagined "`KIND_INPUT_FOCUS`" to this).
- **`KIND_INPUT_ROUTE`** — defined, but *not* in the kernel's cap
  registry (`src/kernel/core/cap/kind.pdx` has no `0x1D7` entry). It is
  a userspace-local constant declared in
  `src/user/input_server/route_kind.pdx:117` (`= 0x1D7`,
  `KIND_INPUT_ROUTE_BASE = 0x1D0`), consumed only inside
  `src/user/input_server/*` and `src/user/compositor/*`. It is real
  vocabulary but it is not a kernel-derived capability today — a
  `sys_cap_invoke` against `0x1D7` would not resolve at the kernel cap
  layer at all.
- **Wire mapping recommendation:** `svc-compositor` should adopt
  `KIND_SEAT` for focus/grab/modifier-state authority (mint per login
  session, matching `KIND_SEAT_BASE = KIND_IPC_ENDPOINT`), and treat
  per-event pointer/keyboard/touch delivery as an **IPC message over
  the existing seat-scoped endpoint**, not a capability mint per event
  — minting a cap per input event would be a linearity/perf mismatch
  with every other event-stream kind in `pwp-spec-vocabulary.md` (which
  models one-shot state, e.g. `KIND_SURFACE_COMMIT`, as LINEAR caps,
  not high-frequency events as caps). If a true kernel-registered
  `KIND_INPUT_EVENT`/`KIND_INPUT_ROUTE` is wanted later, it needs a
  fresh mint request against `next-wave-derived-kinds.md`'s free-tag
  ledger (which is stale past `0x1B4` as of this writing — audit before
  allocating) rather than reusing the unregistered userspace `0x1D7`.

## 3. Sequencing

This mapping is a prerequisite for α-01's Phase 2 (re-plumbing
`svc-compositor` onto the kernel cap surface) and should land before
any submodule adoption (α-05) that would freeze `svc-compositor`'s
current wire shapes into this monorepo's build.
