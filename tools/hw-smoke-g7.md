# tools/hw-smoke-g7.md — G7 first-window bring-up recipe

Operator recipe for the G7 first-window hardware-only test, per D7
`gated:hardware` discipline. This does NOT run in CI or QEMU; it
runs on a real ThinkPad T14 Gen4 (Iris Xe / Xe LPG on 12th-gen +
successors) with the G1..G6 substrates landed and the R36 display
engine caps wired into the boot path from prior Waves.

This is the terminal doc for the G7 compositor milestone. It closes
issues #2246, #2248, #2250, #2252, #2254, #2256, #2258, #2260,
#2262, #2265, #2266, #2267, #2268, #2269, #2270, #2271, #2272, and
this one (#2273). It exercises the full compositor stack
end-to-end: KIND_SURFACE, KIND_SURFACE_COMMIT, KIND_WINDOW,
KIND_LAYER_TREE, xdg_shell_states, present-feedback, and the
recovery_plane_takeover fallback from G7-M6.

The smoke is marked `dormant` under CI — the compositor witness
sidecar is present in the tree but is not called from the QEMU boot
path. See §6 (Wiring pending) for what the follow-up wire-body
milestone must land before this recipe runs against real firmware.

---

## 1. Purpose

Prove end-to-end first-window bring-up on real Iris Xe hardware.
The single boot exercises:

- `KIND_SURFACE` allocation + `KIND_SURFACE_COMMIT` transactional
  attach against a G6 buffer-pool slot;
- `KIND_WINDOW` role binding a surface to an xdg_toplevel with a
  state machine (NORMAL / MAXIMIZED / FULLSCREEN);
- `KIND_LAYER_TREE` composition with damage aggregation up the
  parent chain;
- `xdg_shell_states` transitions with effective-geometry follow-up;
- present-feedback timelines tying commits to actual scanout on
  the eDP panel;
- `recovery_plane_takeover` from G7-M6-002 taking over the display
  source when the compositor process dies.

The R36 display-engine caps (KIND_DISPLAY_ENGINE, KIND_DISPLAY_OUTPUT,
KIND_MODESET_TXN, KIND_DISPLAY_PLANE) are already integrated per
prior Wave landings and are pre-conditions, not part of the test
matrix here.

## 2. Prerequisites

- Reference hardware: ThinkPad T14 Gen4 (or any Iris Xe / Xe LPG
  laptop the fingerprint sheet lists) with GuC + HuC firmware
  pinned per the `paideia-as` v0.33 release manifest and ML-DSA-65
  signed.
- Boot mode: `-kernel` via `boot_stub.S`, opted into the 14-mode
  matrix's `g7-first-window` slot; the loader sets
  `PAIDEIA_G7_SMOKE=1` in the `_init_caps` sidecar.
- G1 vblank/timeline, G2 scanout-lease, G3 swapchain, G4 vector
  renderer, G5 text stack, and G6 buffer-pool substrates all
  landed and reporting their fingerprints on the boot log before
  the G7 witness runs.
- R36 display-engine caps integrated (from earlier Wave); the boot
  banner shows `R36 DISPLAY ENGINE OK plane_count>=3`.
- G7-M1..M7 sidecar objects landed in-tree (this doc closes M8).
- USB serial cable + minicom/screen for the boot log.

## 3. Test matrix

Five sub-tests, run in order, one boot. Each emits an explicit
fingerprint on the serial log on PASS; on FAIL the witness halts
after emitting the offending fingerprint's `FAIL` variant.

### T1: single-window bring-up

Init a compositor process (svc-compositor). Mint one
`KIND_SURFACE`, one `KIND_WINDOW` bound to it, and one
`KIND_LAYER_TREE` root. Attach a 1x1 solid-color buffer from a G6
pool slot; issue `KIND_SURFACE_COMMIT`. Expect one window on the
primary output at (0,0), 1x1, opaque.

- PASS: `G7 FIRST WINDOW OK`
- FAIL: `G7 FIRST WINDOW FAIL stage=<mint|attach|commit|scanout>`

### T2: buffer swap with timeline sync

Attach two alternating buffers (A, B, A, B, ...) with explicit
wait/signal timelines on each commit. Cycle N=120 commits at the
panel's native refresh. Assert: zero tearing detected via the
present-feedback stream, zero implicit fence promotions logged.

- PASS: `G7 BUFFER SWAP OK count=<N>`
- FAIL: `G7 BUFFER SWAP FAIL reason=<tear|implicit_fence|timeout> at=<N>`

### T3: xdg_toplevel state transitions

Cycle the window through NORMAL → MAXIMIZED → FULLSCREEN → NORMAL.
After each transition, sample the effective geometry via
`kind_window_query` and assert it matches the state's expected
extent (NORMAL: 1x1; MAXIMIZED: work-area extent; FULLSCREEN:
output extent).

- PASS: `G7 STATE TRANSITION OK`
- FAIL: `G7 STATE TRANSITION FAIL from=<S1> to=<S2> geom=(<w>x<h>)`

### T4: layer_tree damage aggregation

Build a 3-level layer tree (root → mid → leaf). Damage a rect in
the leaf; commit. Assert the mid and root damage sequences advance
with the aggregated union rect. Repeat on a sibling leaf to verify
disjoint damage regions merge correctly.

- PASS: `G7 LAYER DAMAGE OK`
- FAIL: `G7 LAYER DAMAGE FAIL level=<mid|root> observed=<rect> expected=<rect>`

### T5: recovery plane takeover

Simulate compositor death (SIGSEGV in svc-compositor). Expect the
input server to detect the drop via the compositor-liveness
timeline and invoke `recovery_plane_takeover_execute` (G7-M6-002)
to take over the display source. Assert the panel continues to
scan out a fallback plane (solid recovery-color fill) within the
takeover deadline.

- PASS: `G7 RECOVERY TAKEOVER OK trigger=SIGSEGV`
- FAIL: `G7 RECOVERY TAKEOVER FAIL reason=<no_detect|deadline|no_scanout>`

## 4. Failure taxonomy

Serial output to grep for each expected error path:

- `SKIP: no R36` — R36 display-engine caps not integrated; abort
  before T1.
- `SKIP: no G6 pool` — buffer-pool substrate not landed; abort
  before T1's attach.
- `G7 * FAIL ...` — one of the five test fingerprints listed
  above; the witness halts immediately, no further tests run.
- `#PF at <rip>` in the interval — page fault inside a compositor
  or display-engine path; treat as a hard regression, capture
  full serial and open a bug.
- `WATCHDOG G7 T<n>` — a test failed to emit either its PASS or
  FAIL fingerprint before its per-test 2-second timeout;
  witness halts.

## 5. Success criteria

- All five tests pass in one boot, in order.
- All five fingerprints appear on the serial log in the order
  T1, T2, T3, T4, T5.
- No `G7 * FAIL` line anywhere in the log.
- No `#PF` inside the G7 window (between the R36 banner and the
  G7 CLOSE line).
- No `WATCHDOG G7 T<n>` line.
- Serial log ends with:

      G7 CLOSE OK issues=2246,2248,2250,2252,2254,2256,2258,2260,2262,2265,2266,2267,2268,2269,2270,2271,2272,2273

## 6. Wiring pending

The KIND_SURFACE / KIND_SURFACE_COMMIT / KIND_WINDOW /
KIND_LAYER_TREE / xdg_shell_states / present-feedback cap
dispatchers landed in G7-M1..M7 are NOT yet wired into
`src/kernel/boot/kernel_main.pdx`. This doc specifies what the
future compositor wire-body milestone (post-G7, deferred, not yet
filed) must verify. That milestone must:

- Register the G7 cap kinds in the boot cap table (alongside the
  R36 display-engine caps already present).
- Bind the svc-compositor entry point into the init-cap sidecar.
- Add the `PAIDEIA_G7_SMOKE=1` env var to the
  `tools/run-smoke.sh` mode matrix.
- Add the G7 witness call at the tail of the G7 block in
  `r30_platform.pdx` (mirroring the G4/G5 witness-wiring shape).

Until that milestone lands, this recipe is a specification for the
tester, not an executable procedure. The build-time gate in
`tools/build.sh` continues to pin the G7 cap-table writers to
their owner objects; the wire-body milestone must extend that gate,
not remove pins.

## 7. Reproduction command

Once the wire-body milestone lands, the T14 tester runs:

    PAIDEIA_G7_SMOKE=1 bash tools/run-smoke.sh

Note that `PAIDEIA_G7_SMOKE` is not yet wired into
`tools/run-smoke.sh`; the mode matrix add is part of the wire-body
milestone (see §6). Before that lands, the operator can manually
patch `_init_caps` in the loader sidecar to set the sentinel and
boot the T14 by hand — the witness will run against whatever
G7 dispatchers are reachable, but the R36 pre-condition still
guards T1.

---

## Notes

The HW-smoke exercises the surface/window/layer/xdg/feedback/recovery
primitives that the G7 milestone lands, so a failure of the
QEMU-side dormant witnesses (`kind_surface_synth.pdx`,
`kind_window_synth.pdx`, `kind_layer_tree_synth.pdx`,
`xdg_shell_states_synth.pdx`, `present_feedback_synth.pdx`,
`recovery_plane_takeover_synth.pdx`, `g7_integration_synth.pdx`)
means this HW smoke will not run either — the primitive itself has
regressed. Fix the QEMU witnesses first.

Cross-reference `tools/hw-smoke-g3.md` for the swapchain substrate
each G7 commit presents through, `tools/hw-smoke-g4.md` for the
vector-renderer substrate that layers may composite through, and
`tools/hw-smoke-g1.md` for the vblank + timeline substrate every
present-feedback stream reduces to.
