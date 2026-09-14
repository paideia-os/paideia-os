# Compositor split decision — in-tree library vs. svc-compositor satellite

**Status:** Design (wave α-01). Docs-only.
**Date:** 2026-09-14.
**Grounds in:** `ECOSYSTEM_STATUS.md` (2026-09-13 refresh, Delta + Table 2), `design/user/in-tree-vs-satellite-transition.md`, `design/graphics/compositor-lineage.md` (α-04), `design/graphics/compositor-vocab-adoption.md` (α-03).

## 1. The split, precisely

Two real, independently-developed compositor implementations exist
today with no cross-reference between their histories:

- **In-tree:** `src/user/compositor/*.pdx` — 35 library modules
  (`surface_commit`, `layer_tree`, `tiling_bsp`, `damage_kind`, …,
  the "PWP" vocabulary) backed by a completed kernel `cap_invoke`
  surface (`KIND_SURFACE` mint packing, `KIND_FRAMEBUFFER`/`KIND_SEAT`
  handlers, `KIND_A11Y_NODE` dispatch, `sys_sched_wait_ns`) and 25
  kernel-linked unit/integration tests under
  `tests/kernel/{compositor,postui-desktop}/`. **No `fn main` exists
  anywhere in the directory**, and `tools/build-user.sh` explicitly
  excludes `compositor/*` (along with `a11y/`, `color/`, `ime/`,
  `input_server/`, `libpaideia_ui/`, `postui-desktop/`) from the
  `SHELL_OBJECTS`/`INIT_OBJECTS` link step (paideia-os #2344, to keep
  `shell.elf` under the 65536-byte `EXECVE_IMAGE_MAX`). Real code, zero
  linked entry point.
- **Satellite:** `svc-compositor` (github.com/paideia-os/svc-compositor,
  v1.4.0) — a real window table, damage/commit decode, a 60 Hz render
  loop, and a focus-routed input pump; scanout blit is a WEAK-stub
  (canned 1920x1080); does not consume the kernel-side
  `KIND_SURFACE`/`KIND_FRAMEBUFFER`/`KIND_SEAT` cap-handler wiring the
  in-tree side was built against. Not adopted as a `.gitmodules`
  submodule; boot does not reference it at all.

**Neither is a bootable desktop.** This is the second instance of the
in-tree-vs-satellite hazard the 2026-09-12 refresh first flagged for
`cat/cp/mkdir/mv/rm/dispatch/tokenizer` (`design/user/
in-tree-vs-satellite-transition.md`), and it is structurally different
from that first instance: coreutils have two *feature-comparable*
implementations of the same CLI contract, so "pick the more-featured
one, retire the other" is a clean call. The compositor pair has two
*architecturally different* implementations (kernel cap kinds + unwired
library vs. userspace daemon + unwired-to-kernel wire protocol) — see
`compositor-lineage.md` for how they diverged.

## 2. Why the coreutils rule doesn't transfer directly

`in-tree-vs-satellite-transition.md`'s universal rule — "satellite is
master; in-tree is retired" — assumes both sides implement the same
external contract and the satellite is simply further along. Here:

- The in-tree side is not a competing *implementation* of
  `svc-compositor`'s job; it is the *kernel substrate*
  `svc-compositor` would need to sit on top of (§2 of
  `compositor-vocab-adoption.md`). Retiring it the way `mkdir.pdx` gets
  retired would delete the only code that exercises the kernel cap
  handlers directly, and the 25 kernel-linked tests with it.
- The satellite side is not missing features relative to the in-tree
  side so much as missing an entirely different axis: kernel-cap
  awareness. Feature count does not settle this the way it settles
  `cat` vs. `cat`.

## 3. Recommended reconciliation path

Three phases, mirroring the shape `in-tree-vs-satellite-transition.md`
already uses for `shell` (split-authoritative during transition,
satellite-master after cutover), adapted for the architectural split:

### Phase 1 — today: declare roles, no code motion

- **In-tree `src/user/compositor/*.pdx` becomes the reference/
  test-oracle library.** Its job is to keep validating the kernel cap
  surface (`KIND_SURFACE`/`KIND_FRAMEBUFFER`/`KIND_SEAT`/
  `KIND_A11Y_NODE`) via `tests/kernel/compositor/*.pdx`, not to ship as
  a client. Unblock that test suite per
  `design/testing/compositor-test-runner.md` (α-02) so it stops being
  dead weight and starts being the regression gate for kernel-side
  compositor changes.
  Repurposed, not retired.
- **Satellite `svc-compositor` becomes the shipping-authoritative
  process**, matching R102's original single-compositor-process intent
  (`compositor-lineage.md` §4). It needs to adopt the frozen vocabulary
  before it can claim that role for real — tracked in
  `compositor-vocab-adoption.md` (α-03).
- No submodule adoption yet (see α-05 for why, and its sequencing).

### Phase 2 — vocab adoption lands (blocks on α-03)

Once `svc-compositor` mints/queries real `KIND_SURFACE`/
`KIND_FRAMEBUFFER`/`KIND_SEAT` caps instead of its own R102-v0
structures, its window table and damage/commit decode become
verifiable against the *same* kernel handlers the in-tree test suite
already exercises. At that point the two implementations stop being
disconnected: the in-tree tests are effectively also regression-testing
the contract `svc-compositor` depends on.

### Phase 3 — submodule adoption + narrowing the in-tree side

Once Phase 2 is verified working end-to-end (a real client can mint a
surface, commit a buffer, and see a pixel via `svc-compositor` against
the kernel cap surface), adopt `svc-compositor` as a `.gitmodules`
submodule per `design/tooling/svc-compositor-submodule-adoption.md`
(α-05). At that point re-evaluate whether any of the 35 in-tree
`compositor/*.pdx` modules can be deleted (their logic now lives,
proven, in the satellite) versus kept purely as kernel-cap witnesses —
that narrowing decision is deliberately deferred past this document,
since it depends on Phase 2's actual shape, not a guess made now.

## 4. What this document is not saying

This is not a decision to retire either side today. It is a decision
about *roles*: reference/test-oracle (in-tree) vs.
shipping-authoritative (satellite), with the fusion point being shared
vocabulary (α-03), not a feature bake-off. No code changes accompany
this document.
