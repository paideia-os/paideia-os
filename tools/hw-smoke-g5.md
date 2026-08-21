# tools/hw-smoke-g5.md — G5 hardware-smoke recipe

Operator recipe for the G5 hardware-only test, per D7
`gated:hardware` discipline. This does NOT run in CI or QEMU; it
runs on a real ThinkPad T14 G4 (Iris Xe GPU + eDP panel) with the
G4 renderer, the G5 font stack, and a font-load server holding a
Noto Sans + Noto Color Emoji install.

The smoke is marked `dormant` under CI — the witness module
(`tests/kernel/drivers/text/hw_smoke_g5_placeholder.pdx`) compiles
and links but is not called from the QEMU boot path.

---

## G5.M3-003 (#1503): SDF glyphs at 1.25x / 1.5x / 1.75x pixel-perfect on real T14

### Prerequisites

- ThinkPad T14 G4 (Meteor Lake or successor with Iris Xe).
- eDP panel with G1 display-timeline + G2 scanout-lease + G3
  swapchain + G4 vector-renderer substrates landed (kernel booted
  with the G1..G4 fingerprints reported on the boot log).
- A userspace font-load server holding a Noto Sans install (Latin
  + CJK + Devanagari) and a Noto Color Emoji install (COLR/CPAL).
- A compositor that consumes `text_shape_channel.shape` requests
  and renders through the G4 vector-renderer.
- USB serial cable + minicom/screen for the boot log.
- A camera fixture pointed at the panel for the visual half of the
  acceptance (a bench cam feeding a screen-capture on a companion
  laptop is enough).

### Procedure

1. Boot the T14 into a paideia-os image with `G5_HW_SMOKE=1` set
   in the loader's `_init_caps` sidecar.
2. The boot witness (once the operator wires the tail of the G5
   block in `r30_platform.pdx`) opens:
   - one `KIND_FONT_ATLAS` against a 2048x2048 KIND_GPU_BO on the
     eDP scanout engine, format `FONT_FORMAT_SDF`;
   - three `KIND_TEXT_SHAPE` caps against the string
     "Paideia OS 1.25x / 1.5x / 1.75x", one per scale;
   - one `KIND_TEXT_SHAPE` for the Devanagari corpus at 3/2 (P9
     for Indic conjunct clustering);
   - one `KIND_TEXT_SHAPE` for a color-emoji run (👋🌍) at 3/2.
3. The test drives 60 rendered frames of each shape:
   - Each frame calls `text_shape_channel.shape`, submits the
     resulting cap to the compositor, then samples the
     rendered pixels through the G3 present-feedback stream.
   - The compositor must report zero cache misses on the
     sub-pixel positioning path after the first frame of each
     scale.
4. After frame 60 for each scale, the test asserts:
   - The observed pixel grid matches the golden fixture at
     `tests/gold/g5/latin_<scale>.png` within 2 LSB per channel.
   - The Devanagari cluster count matches the golden.
   - The color-emoji run reports `CE_KIND_COLR` and one strike
     per rendered glyph.
5. On PASS the boot log emits:

       G5 TEXT HW SMOKE OK

   On FAIL it emits the offending scale + assertion label and
   halts.

### Expected result

- 3 scales * 60 frames land without watchdog timeout.
- Sub-pixel cache invalidation fires exactly once per scale change
  (between the 1.25x and 1.5x pass, and between 1.5x and 1.75x).
- Devanagari cluster count matches the golden ±0.
- Color-emoji strike selection lands on the 32/64/128 band as
  documented in `drivers/text/color_emoji.pdx`.

### Failure modes

- If the font-load server does not hold a Noto Sans install, the
  boot witness aborts with a `SKIP: no Noto Sans` banner.
- If the compositor does not implement `text_shape_channel`, the
  witness aborts with `SKIP: no text_shape_channel`.
- If the pixel-grid mismatch exceeds 2 LSB per channel, the
  witness fails and prints:

       G5 TEXT HW SMOKE FAIL scale=<n> reason=<label>

- If the sub-pixel cache reports a hit at the new scale (i.e.
  invalidation did not fire), the witness fails with the recorded
  cache state.

---

## Notes

The HW-smoke exercises the `tsc_apply_shape` and `subpx_cache_*`
primitives that this milestone lands, so a failure of the QEMU-side
dormant witnesses (`kind_font_atlas_synth.pdx`,
`kind_text_shape_synth.pdx`, `sdf_synth.pdx`, `subpixel_synth.pdx`,
`shaper_synth.pdx`, `color_emoji_synth.pdx`,
`font_load_channel_synth.pdx`, `text_shape_channel_synth.pdx`,
`g5_integration_synth.pdx`) means the HW smoke will not run either
— the primitive itself has regressed. Fix the QEMU witnesses
first.

The confinement gate in `tools/build.sh` pins the writers of
`_font_atlas_table`, `_text_shape_table`, `_subpx_cache`, and the
per-driver `_*_stats` cells to their respective owner objects. If
the HW-smoke witness needs to add a third writer for a bench
helper, extend the gate rather than remove the pin.

Cross-reference `tools/hw-smoke-g3.md` for the swapchain substrate
the G5 text stack presents through, and `tools/hw-smoke-g1.md`
for the vblank + timeline substrate everything above depends on.
