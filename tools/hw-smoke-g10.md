# tools/hw-smoke-g10.md — G10 a11y bring-up recipe

Operator recipe for the G10 accessibility hardware-only test, per
D7 `gated:hardware` discipline. This does NOT run in CI or QEMU;
it runs on a real ThinkPad T14 Gen4 (12th-gen + successors) with
a USB Braille display attached, an Orca-shape screen reader
running as a satellite process, and the G1..G9 substrates plus
the R37 audio-engine caps landed and reporting fingerprints from
prior Waves.

This is the terminal doc for the G10 accessibility milestone. It
closes issues #2302, #2303, #2304, #2305, #2306, #2307, #2308,
#2309, #2310, #2311, #2312, and this one (#2313). It exercises
the full a11y stack end-to-end: KIND_A11Y_TREE mint at window
creation (pitfall P4 gate), the AccessKit-shape node schema,
screen-reader client subscription + push, TTS speak on focus
change, USB Braille scroll delivery, and keyboard-navigation
tab-order DFS with focus-ring render.

The smoke is marked `dormant` under CI — the a11y witness sidecar
is present in the tree but is not called from the QEMU boot path.
See §6 (Wiring pending) for what the follow-up wire-body
milestone must land before this recipe runs against real
firmware.

---

## 1. Purpose

Prove end-to-end a11y-tree walk on real T14 Gen4 hardware. The
single boot exercises:

- `KIND_A11Y_TREE` mint bound to a `KIND_WINDOW` at window
  creation, enforcing pitfall P4 (no window without an a11y
  binding);
- `screen_reader_protocol` subscription from an Orca-shape
  satellite process and push of `KIND_A11Y_NODE` tree deltas
  under the mutation-log linear commit discipline (G10-M1-003 /
  #2304);
- `screen_reader_tts` label speak on focus change through the
  R37 audio engine's speech-synthesis sink;
- `screen_reader_braille` 40-cell scroll delivery to a USB HID
  Braille display attached to the input server's Braille slot;
- `keynav_taborder` DFS traversal across the widget tree +
  `keynav_focus_ring` render into the compositor layer tree at
  the focused-node bounding rect.

The G7 compositor (KIND_SURFACE / KIND_WINDOW / KIND_LAYER_TREE)
and G8 input-server (KIND_INPUT_SERVER / KIND_SEAT) substrates
are pre-conditions, not part of the test matrix here. The R37
audio engine (KIND_AUDIO_ENGINE / KIND_AUDIO_SINK) is also a
pre-condition for T3.

## 2. Prerequisites

- Reference hardware: ThinkPad T14 Gen4 (or any laptop the
  fingerprint sheet lists) with a USB Braille display attached
  to any USB-A/USB-C port (any brltty-compatible 40-cell unit;
  the R32 HID substrate exposes it via the generic Braille HID
  usage page).
- Boot mode: `-kernel` via `boot_stub.S`, opted into the 14-mode
  matrix's `g10-a11y` slot; the loader sets `PAIDEIA_G10_SMOKE=1`
  in the `_init_caps` sidecar.
- G7 first-window bring-up passes (there is one `KIND_WINDOW`
  the a11y-tree binds against at mint time; T1..T5 walk it).
- G8 input-routing bring-up passes (Tab / Shift-Tab key events
  reach the keynav DFS handler through a mint route).
- `KIND_A11Y_TREE` substrate booted per G10-M1-001 (#2302) and
  reporting its init fingerprint on the boot log before the G10
  witness runs.
- Orca-shape screen-reader satellite process (svc-sr) running
  and subscribed to `screen_reader_protocol` per G10-M2-001
  (#2305).
- R37 audio engine integrated (from earlier Wave); the boot
  banner shows `R37 AUDIO ENGINE OK sinks>=1` — the TTS sink is
  synthesised on top of the default output.
- Sample app running with widgets (the settings/display panel
  from the G12 toolkit substrate — three focusable widgets
  minimum: brightness slider, scale combo, night-mode toggle).
- USB serial cable + minicom/screen for the boot log.

## 3. Test matrix

Five sub-tests, run in order, one boot. Each emits an explicit
fingerprint on the serial log on PASS; on FAIL the witness halts
after emitting the offending fingerprint's `FAIL` variant.

### T1: a11y-tree bind at window mint (P4 gate)

Mint a fresh `KIND_WINDOW` for the sample-app toplevel. Assert
the mint dispatcher rejects the request unless the caller
provides a `KIND_A11Y_TREE` handle in the auxiliary slot (the P4
gate landed in G10-M1-002). Then re-mint with a valid a11y-tree
handle and assert the resulting window carries the tree binding
in its window-descriptor tail.

- PASS: `G10 A11Y BIND OK`
- FAIL: `G10 A11Y BIND FAIL stage=<no_reject|bind_missing|tail_missing>`

### T2: screen-reader subscription + push event

Have svc-sr subscribe to `screen_reader_protocol` on the a11y
tree from T1. Sample app pushes N=3 `KIND_A11Y_NODE` insertions
(one per widget) through the tree mutation log; each mutation
commits linearly at the log boundary (#2304). Witness observes
svc-sr's receive-count against the subscription and asserts
observed==N within the per-test deadline.

- PASS: `G10 SR SUBSCRIBE OK count=<N>`
- FAIL: `G10 SR SUBSCRIBE FAIL stage=<subscribe|push|receive> observed=<N>`

### T3: TTS speak label on focus change

Focus moves from the brightness slider to the scale combo (one
Tab keystroke, routed via the G8 mint route from T5's
pre-arrangement). The keynav handler emits a focus-change event;
the screen-reader client resolves the newly-focused
`KIND_A11Y_NODE`'s `label` field and calls `screen_reader_tts`
to speak it through the R37 audio-engine TTS sink. Witness
listens for the sink's active-frame counter to advance and
asserts the TTS sink reports `speak_active=1` within the
deadline.

- PASS: `G10 TTS SPEAK OK`
- FAIL: `G10 TTS SPEAK FAIL reason=<no_focus_evt|no_label|no_sink|timeout>`

### T4: Braille display 40-cell scroll

Same focused `KIND_A11Y_NODE` label from T3 is rendered onto the
USB Braille display through `screen_reader_braille`. Witness
issues a scroll (right, 40 cells) via the Braille display's HID
output report and asserts the display's cell buffer receives the
scrolled payload — the witness reads back the cell-buffer echo
from the HID input report on the same interface and asserts
`cells==40` non-zero cells written.

- PASS: `G10 BRAILLE SCROLL OK cells=40`
- FAIL: `G10 BRAILLE SCROLL FAIL reason=<no_device|no_render|scroll_short|timeout> cells=<N>`

### T5: tab-order DFS + focus-ring render

Operator (or the witness's synthetic key injector) presses Tab
four times. `keynav_taborder` walks the widget subtree in DFS
order across the three focusable widgets (slider → combo →
toggle → wrap-back to slider); after each step,
`keynav_focus_ring` (G10-M3 / #2311) draws a 2-pixel focus
outline into the compositor's overlay layer at the focused
widget's bounding rect. Witness asserts the layer-tree damage
sequence advances four times and each observed rect matches the
expected widget geometry.

- PASS: `G10 KEYNAV FOCUS OK`
- FAIL: `G10 KEYNAV FOCUS FAIL step=<N> observed=<rect> expected=<rect>`

## 4. Failure taxonomy

Serial output to grep for each expected error path:

- `SKIP: no G7 window` — G7 first-window witness did not land a
  `KIND_WINDOW` for the a11y-tree to bind against; abort before
  T1.
- `SKIP: no G8 route` — G8 input-routing witness did not land a
  mint route for Tab keystrokes; abort before T5 (T1..T4 still
  run).
- `SKIP: no R37 audio` — R37 audio-engine substrate not
  integrated; abort before T3 (T1, T2, T4, T5 still run).
- `SKIP: no braille dev` — no USB Braille display detected on
  any HID interface within the boot's device-enumeration window;
  abort before T4 (T1..T3, T5 still run).
- `G10 * FAIL ...` — one of the five test fingerprints listed
  above; the witness halts immediately, no further tests run.
- `#PF at <rip>` in the interval — page fault inside an a11y,
  screen-reader, TTS, Braille, or keynav path; treat as a hard
  regression, capture full serial and open a bug.
- `WATCHDOG G10 T<n>` — a test failed to emit either its PASS
  or FAIL fingerprint before its per-test 2-second timeout
  (3-second for T3 to allow TTS sink warmup, 3-second for T4 to
  allow Braille HID round-trip); witness halts.

## 5. Success criteria

- All five tests pass in one boot, in order.
- All five fingerprints appear on the serial log in the order
  T1, T2, T3, T4, T5.
- No `G10 * FAIL` line anywhere in the log.
- No `#PF` inside the G10 window (between the G8 CLOSE line and
  the G10 CLOSE line).
- No `WATCHDOG G10 T<n>` line.
- Serial log ends with:

      G10 CLOSE OK issues=2302,2303,2304,2305,2306,2307,2308,2309,2310,2311,2312,2313

## 6. Wiring pending

The KIND_A11Y_TREE / screen_reader_protocol / screen_reader_tts /
screen_reader_braille / keynav_taborder / keynav_focus_ring cap
dispatchers landed in G10-M1..M4 are NOT yet wired into
`src/kernel/boot/kernel_main.pdx`. This doc specifies what the
future a11y wire-body milestone (post-G10, deferred, not yet
filed) must verify. That milestone must:

- Register the G10 cap kinds (KIND_A11Y_TREE, KIND_A11Y_NODE) in
  the boot cap table (alongside the G7 compositor caps once G7
  wire-body lands).
- Bind the a11y-tree mutation-log commit path into the init-cap
  sidecar, subscribing to the compositor's window-mint hook so
  the P4 gate is enforced from boot 1.
- Register the screen-reader satellite process (svc-sr) as an
  init-cap dependent, spawned once the a11y substrate is up.
- Add the `PAIDEIA_G10_SMOKE=1` env var to the
  `tools/run-smoke.sh` mode matrix.
- Add the G10 witness call at the tail of the G10 block in the
  platform init file (mirroring the G4/G5/G7/G8 witness-wiring
  shape).

Until that milestone lands, this recipe is a specification for
the tester, not an executable procedure. The build-time gate in
`tools/build.sh` continues to pin the G10 cap-table writers to
their owner objects; the wire-body milestone must extend that
gate, not remove pins.

## 7. Reproduction command

Once the wire-body milestone lands, the T14 tester runs:

    PAIDEIA_G10_SMOKE=1 bash tools/run-smoke.sh

Note that `PAIDEIA_G10_SMOKE` is not yet wired into
`tools/run-smoke.sh`; the mode matrix add is part of the
wire-body milestone (see §6). Before that lands, the operator
can manually patch `_init_caps` in the loader sidecar to set the
sentinel and boot the T14 by hand — the witness will run against
whatever G10 dispatchers are reachable, but the G7/G8/R37/Braille
pre-conditions still guard T1..T5.

---

## Notes

The HW-smoke exercises the a11y-tree / screen-reader /
TTS / Braille / keynav primitives that the G10 milestone lands,
so a failure of the QEMU-side dormant witnesses
(`kind_a11y_tree_synth.pdx`, `screen_reader_protocol_synth.pdx`,
`screen_reader_tts_synth.pdx`, `screen_reader_braille_synth.pdx`,
`keynav_taborder_synth.pdx`, `keynav_focus_ring_synth.pdx`,
`g10_integration_synth.pdx`) means this HW smoke will not run
either — the primitive itself has regressed. Fix the QEMU
witnesses first.

Cross-reference `tools/hw-smoke-g7.md` for the compositor
substrate the a11y-tree binds against at window mint (pitfall
P4 gate depends on a live `KIND_WINDOW`), `tools/hw-smoke-g8.md`
for the input-routing substrate T5's Tab injection routes
through, and `design/compositor/pwp-spec-vocabulary.md` §2.21
for the KIND_A11Y_TREE / KIND_A11Y_NODE type signatures the
witness asserts against.
