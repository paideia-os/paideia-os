# R113.M8 — T14 G4 real-HW compositor smoke: scope

Tracking: paideia-os #2417 (R113.M8-037), with #2418/#2419/#2420 as
siblings in the same M8 wave. Umbrella: R113 GPU-native compositor
(#2380; see `design/graphics/r113-gpu-native-gui.md` for the full
milestone-status refresh).

Status: **blocked-doc scoping only.** This wave needs a physical
Lenovo ThinkPad T14 Gen 4 unit; nothing here lands code. It exists so
the four M8 issues have a shared, precise definition of "done" the
day the hardware is available, instead of four independently-guessed
smoke procedures.

## 0. Dependency chain is already closed

#2417's own title says "blocked on R111.M4-015" — that dependency
(#2367, GOP framebuffer console) is **closed**. So are its siblings:
`R111.M5-017` (#2369, xHCI real-HW attach) and `R111.M5-018` (#2370,
HID keyboard input). The R111 T14-boot-to-`$` umbrella (#2353) is
closed. **M8 is not blocked on any open kernel or compositor work** —
it is blocked purely on physical hardware being in an operator's
hands. This document assumes that gate lifts and describes what to do
the moment it does.

## 1. What real-HW smoke covers

Four issues, four distinct proof obligations — none of them
substitutes for another:

- **#2417 (M8-037) — compositor smoke.** The full stack boots
  unattended to a graphical desktop: kernel → `init` → compositor
  daemon → `postui-desktop` client, with a terminal widget and status
  bar rendered and visible on the T14's own panel (or an attached
  external display). This is the integration proof — every other M8
  issue is a narrower slice of the same boot.
- **#2418 (M8-038) — external-USB-keyboard input smoke.** Keystrokes
  from a real USB HID keyboard (not the T14's internal keyboard, which
  is a different HID path) reach the focused surface. Proves the xHCI
  external-port + HID-boot-protocol + R113.M3 input-routing chain
  end-to-end on real silicon, not just QEMU's emulated USB HID.
- **#2419 (M8-039) — direct-scanout witness on Iris Xe.** A single
  full-screen surface with no compositing needed (R113.M4-018's
  direct-scanout path) is proven to hit a real Intel Iris Xe
  (Raptor Lake-U) display plane directly — no GPU-composite blend, no
  software fallback. Proves the DRM_FOURCC/tile-modifier negotiation
  (M1-004) and the GuC-loaded GPU backend (`tools/hw-smoke-r37-guc.md`)
  actually agree with the real display controller's plane
  capabilities, which QEMU's virtual GPU cannot exercise.
- **#2420 (M8-040) — multi-surface composite witness on Iris Xe.**
  Two or more surfaces (e.g. the terminal + status bar) are blended
  through the R113.M4-019 GPU-composite path via the real R37 submit
  ring. Proves the composite path (not just direct-scanout) survives
  contact with real GPU command-submission latency and real vblank
  timing (M4-020/M4-021).

## 2. Minimum hardware to run it

- One Lenovo ThinkPad T14 Gen 4 (Intel Raptor Lake-U, Iris Xe
  integrated graphics) — the same unit `design/hardware/
  t14-g4-first-boot.md` and `design/boot/t14-hw-in-loop.md` already
  assume.
- USB stick ≥ 128 MiB flashed via `tools/mkimage.sh` /
  `tools/build-image.sh`.
- USB-TTL serial adapter + DB-9 null-modem + Lenovo Universal USB-C
  Dock Gen 2 (or equivalent DB-9 exposure) for boot-log capture —
  per `design/boot/t14-hw-in-loop.md` §3.1 (the T14 G4 chassis has no
  debug UART header; DCI-over-USB-C is the documented fallback, §3.3).
- A **second**, external USB keyboard distinct from the T14's internal
  one — required specifically for #2418; the internal keyboard alone
  cannot exercise the external-xHCI-port HID path.
- A display attached to the T14's own panel is sufficient for
  #2417/#2419/#2420; an external DP/HDMI monitor is optional
  (useful for a human to visually confirm the composite result, but
  not required by the fingerprint-based pass/fail contract below).

## 3. QEMU-validatable vs. real-HW-only

| Sub-check | QEMU today | Needs real HW |
|---|---|---|
| Compositor boots, `postui-desktop` starts, surfaces mint | Yes — R113.M1-M7's own boot witnesses + `tools/run-qemu-t14fidelity.sh` cover this on QEMU's virtual GPU | Confirm identical boot sequence reaches the same fingerprints on real firmware (per `design/boot/t14-hw-in-loop.md`'s golden-comparison discipline) |
| Terminal widget + status bar render correct pixels | Partially — QEMU's virtual display can be screenshotted, but pixel-exact GPU composite behavior is emulator-specific | Yes — real Iris Xe composite/scanout timing and plane behavior cannot be emulated |
| Internal keyboard input routing | Yes — QEMU emulates a PS/2 or USB HID keyboard already exercised by existing R113.M3 witnesses | No — this is the *internal* keyboard, already covered |
| **External USB keyboard on a real xHCI port** (#2418) | **No** — QEMU's USB HID emulation does not distinguish "external port on real silicon" from "internal keyboard"; the real xHCI real-HW-attach path (#2369) is precisely what QEMU cannot exercise | **Yes — real-HW-only** |
| **Direct-scanout on real Iris Xe plane** (#2419) | **No** — QEMU's virtual GPU has no real display-plane hardware to scan out to; direct-scanout vs. composite is only a meaningful distinction against a real display controller | **Yes — real-HW-only** |
| **Multi-surface composite via real R37 submit ring** (#2420) | Partially — the submit-ring *protocol* is exercised in QEMU (R37 GPU witnesses), but real GPU command-submission latency, real vblank cadence, and real GuC firmware behavior are not | **Yes for the hardware-timing half; QEMU covers the protocol half** |

**Reading this table:** #2417 is the one M8 issue with meaningful
QEMU pre-coverage (the whole boot-to-desktop sequence already runs
green in QEMU via existing R113 boot witnesses) — real-HW smoke for
#2417 is mostly a *confirmation* run. #2418, #2419, and #2420 are each
proving something structurally absent from QEMU's emulation — for
those three, "run it in QEMU first" is not a meaningful pre-check;
the real-HW run is the first and only time the assertion can be made.

## 4. Recommended smoke matrix once HW is in hand

Ordered by dependency (each step's prerequisite is the previous
step's pass):

1. **Boot confirmation** (prereq for all of the below): run
   `tools/capture-t14-boot.sh` against the R113-enabled image, compare
   against a new `tests/expected-t14-r113-fidelity.golden` (extends the
   existing `tests/expected-t14-fidelity.golden` pattern from
   `design/boot/t14-hw-in-loop.md`) that asserts the boot reaches a
   compositor-ready fingerprint, not just `SHELL START`.
2. **#2417 compositor smoke:** with the T14's own panel as display and
   no external keyboard yet, confirm `postui-desktop`'s terminal
   widget + status bar are visually present (operator eyeball check)
   AND the boot log carries the M1-M7 fingerprint sequence through to
   a new `compositor desktop ok` marker (to be added alongside this
   wave's implementation, following the `[legacy: ...]` dual-form
   discipline `tools/verify-fingerprint-coverage.sh` expects).
3. **#2419 direct-scanout witness:** with only the terminal widget
   full-screen (no status bar, forcing the M4-018 single-plane path),
   confirm the boot log's GPU-path fingerprint reports direct-scanout
   (not composite) and the image is pixel-correct on the real panel.
4. **#2420 multi-surface composite witness:** restore the status bar
   (forcing M4-019's composite path), confirm the fingerprint reports
   composite mode and both surfaces render correctly with no tearing
   across at least one observed vblank cycle (M4-020/M4-021).
5. **#2418 external-keyboard smoke:** attach the second USB keyboard
   to an external xHCI port (not the internal keyboard's controller),
   type into the terminal widget, confirm keystrokes appear — this can
   run any time after step 2 and does not depend on 3/4.

Each step's pass/fail should land as its own line in
`tools/hw-smoke-fingerprints.md` (the existing per-feature HW-smoke
index — see `tools/hw-smoke-r44-gui-terminal.md` and
`tools/hw-smoke-r37-guc.md` for the established doc shape this matrix
should follow when the wave actually runs) rather than one combined
pass/fail, so a partial hardware session (e.g., keyboard unavailable
that day) can still record real progress on the other three.

## 5. Non-goals

- No CI/CD wiring — per the standing `paideia-os: no CI/CD` posture,
  this stays a local, operator-driven, hardware-in-loop procedure
  forever, same as every other `tools/hw-smoke-*.md` in the tree.
- No QEMU substitute is claimed for #2418/#2419/#2420 — §3 above is
  explicit that these three have no meaningful QEMU pre-check; do not
  accept a QEMU-only "pass" as closing them.
- No new kernel or compositor code is scoped by this document. If the
  real-HW run surfaces a defect, file it as its own issue against the
  relevant R113 milestone rather than folding a code fix into this
  scoping doc.

## 6. Cross-references

- `design/graphics/r113-gpu-native-gui.md` — R113 milestone status
  refresh (this doc's sibling in the same cohort).
- `design/boot/t14-hw-in-loop.md` — boot-capture + golden-compare
  harness this matrix's step 1 extends.
- `design/hardware/t14-g4-first-boot.md` — the R28.M2 BIOS/serial
  bring-up recipe this wave's operator still needs.
- `tools/hw-smoke-r37-guc.md`, `tools/hw-smoke-r44-gui-terminal.md` —
  precedent HW-smoke doc shapes for the GPU/GUI surface.
- `tools/hw-smoke-fingerprints.md` — the per-feature HW-smoke index
  this wave's results should append to.
