# Compositor lineage — R102 CPU path vs. R113 GPU-native path

**Status:** Design (wave α-04). Docs-only.
**Date:** 2026-09-14.
**Grounds in:** `design/graphics/r102-user-plan.md` §8.3, `design/graphics/r113-gpu-native-gui.md`, `design/round-retrospectives/r102-closure.md`, `ECOSYSTEM_STATUS.md` (2026-09-13 refresh, Delta + Table 2).

## 1. The plan-of-record hand-off (never executed)

R102's own design commits to a specific succession (`r102-user-plan.md`
§8.3, "G7 hand-off contract"): R102's CPU-only `svc-compositor` is
explicitly disposable — "**svc-compositor binary: replaced.** Its wire
protocol version (R102-v0) is refused by the G7 compositor with a clean
version-mismatch reply; clients upgrade to a G7-shaped `libpdx-gfx` that
speaks G7-vN." `libpdx-gfx` and `libpdx-event` were meant to keep their
signatures stable across the swap so clients recompile, not rewrite.

**That hand-off never happened.** What actually landed as the
GPU-native successor — R113 (`design/graphics/r113-gpu-native-gui.md`,
umbrella #2380, M1–M7 closed, 36/40 issues) — is not a new build of the
`svc-compositor` binary at all. It is a parallel **in-tree** stack:
kernel-side surface/window/input/render primitives under
`src/kernel/core/graphics/*.pdx` (`surface_toplevel.pdx`, `focus.pdx`,
`ptr_route.pdx`, `touch_route.pdx`, `dma_buf.pdx`, …) plus a userspace
PWP module library at `src/user/compositor/*.pdx` (35 modules) and a
first client, `postui-desktop` — itself an in-tree, unwired skeleton
(`entry.pdx` has no process-spawn path; `init` never forks/execves it).

Meanwhile `svc-compositor` kept shipping on its own R102 track,
unaware R113 existed: it reached v1.4.0 with a real window table,
damage/commit decode, a 60 Hz render loop, and a focus-routed input
pump (`ECOSYSTEM_STATUS.md` Table 2) — but its scanout blit is a
WEAK-stub (canned 1920x1080) and it "does not yet consume the new
kernel-side `KIND_SURFACE`/`KIND_FRAMEBUFFER`/`KIND_SEAT` cap-handler
wiring" that R113 built. Two real implementations, two vocabularies,
zero cross-references between their commit histories.

## 2. Why they diverged instead of one replacing the other

- **Different execution models.** R102 planned a userspace daemon
  (`svc-compositor`) speaking a client wire protocol (PWP-v0) over
  IPC. R113 built its composition primitives as kernel-resident
  capability kinds (`KIND_SURFACE = 0x1B8`, `KIND_WINDOW`, `KIND_LAYER`,
  …; `design/compositor/pwp-spec-vocabulary.md` §2) invoked directly via
  `sys_cap_invoke`. The hand-off contract assumed the *client-facing
  surface* (libpdx-gfx/libpdx-event signatures) would stay put while
  the *implementation* swapped underneath. Instead the implementation
  moved from "userspace daemon over IPC" to "kernel cap kinds plus an
  in-tree client library" — a different architecture, not a
  same-shaped replacement.
- **No shared freeze document was consulted by both sides.**
  `pwp-spec-vocabulary.md` (G7, 2026-09-03) is the vocabulary R113's
  in-tree modules were built against. `svc-compositor`'s v1.1.0→v1.4.0
  landings happened on the satellite repo with no citation of that
  document (confirmed: `ECOSYSTEM_STATUS.md` — "neither repo's commit
  history references the concurrent kernel-side backtrack").
- **R113 closed as complete without revisiting R102's disposition.**
  The R113 status refresh (2026-09-13) declares M1–M7 "code-complete
  and QEMU-verified," closing #2380, but never states what happens to
  the still-live, still-shipping `svc-compositor` satellite. The
  umbrella closure treated R113 as a green-field landing, not a
  succession event.

## 3. Current state (2026-09-14)

| Path | Where | Vocabulary | Real body | Wired to boot |
|---|---|---|---|---|
| R102 CPU path | `svc-compositor` satellite (v1.4.0) | PWP-v0 (pre-freeze), own kind constants | window table, damage/commit, render loop, input pump; scanout blit WEAK-stub | not adopted as submodule; not in boot image |
| R113 GPU-native path | `src/kernel/core/graphics/*.pdx` + `src/user/compositor/*.pdx` | `pwp-spec-vocabulary.md` frozen kinds (`KIND_SURFACE=0x1B8`, `KIND_SUBSURFACE=0x1BA`, `KIND_WINDOW`, `KIND_SEAT=0x1BF`, …) | kernel side complete (cap mint/dispatch); user-side library real but excluded from the link step, no `fn main` | not wired — `postui-desktop` never forked by `init` |

Neither path is a bootable desktop today. Both are real code.

## 4. Target convergence

R102's own §8.3 intent — one client-facing vocabulary, one compositor
process, satellite-shipped — is still the right end state; only the
*implementation* it names is now wrong (it assumed a G7-vN successor
to the wire protocol, not a kernel cap-kind substrate). Recommended
convergence, sequenced against the other four α-wave docs:

1. **Freeze the vocabulary once** (already done, mostly): treat
   `pwp-spec-vocabulary.md`'s kind catalogue as the single source of
   truth for both paths going forward — this is what `svc-compositor`
   needs to adopt (α-03), not the other way around, since R113's
   kernel-side handlers (`cap_handler_surface`, `cap_handler_framebuffer`,
   `cap_handler_seat`) are already landed and frozen.
2. **`svc-compositor` becomes the shipping process**, matching R102's
   original disposition of "one compositor process" — but its scanout
   and surface/window/seat plumbing get rewired to call through the
   frozen kernel cap kinds instead of its own R102-v0 wire structures.
   This retires the "replace the binary" plan in favor of "re-plumb the
   binary," which is cheaper given how much real logic (render loop,
   damage decode, input pump) `svc-compositor` v1.4.0 already carries.
3. **`src/user/compositor/*.pdx` becomes the reference/test-oracle
   library**, not a second shipping client — its 35 modules and the
   kernel-linked test suite (`tests/kernel/compositor/*.pdx`) continue
   to validate the kernel cap surface directly, decoupled from whether
   `svc-compositor` or `postui-desktop` ever forks. See
   `design/graphics/compositor-split-decision.md` (α-01) for the full
   reconciliation path and `design/testing/compositor-test-runner.md`
   (α-02) for how that test suite actually gets built and run.
4. **`postui-desktop`'s wiring gap and `svc-compositor`'s scanout
   WEAK-stub are the same convergence point** — both need a real
   client bound to the frozen `KIND_SURFACE`/`KIND_FRAMEBUFFER` handlers.
   Whichever lands first (postui-desktop gets forked by `init`, or
   svc-compositor gets its scanout blit rewritten against
   `KIND_FRAMEBUFFER`) should be the one the other is measured against
   before a second, redundant real body is written.

No code changes accompany this document. It is the shared reference
the α-01/α-03/α-05 docs and any future R114+ wave should cite before
proposing new compositor work, so the R102/R113 fork is a documented
fact rather than a rediscovered surprise each session.
