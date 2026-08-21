# tools/hw-smoke-g4.md — G4 hardware-smoke recipe

Operator recipe for the G4 hardware-only test, per D7
`gated:hardware` discipline. This does NOT run in CI or QEMU; it
runs on a real ThinkPad T14 G4 (Iris Xe GPU + eDP panel + a working
paideia-as `@wgsl_module` toolchain reachable through
`VK_paideia_surface`).

The smoke is marked `dormant` under CI — the witness module
(`tests/kernel/drivers/vello/hw_smoke_g4_placeholder.pdx`) compiles
and links but is not called from the QEMU boot path.

---

## G4.M4-003 (#1490): draw complex vector scene on real T14 (Ghostscript tiger)

### Prerequisites

- ThinkPad T14 G4 (Meteor Lake or successor with Iris Xe).
- eDP panel with G1 display-timeline substrate + G3 swapchain
  substrate + G4 Vello substrate landed (kernel booted with G1 +
  G3 + G4 fingerprints reported on the boot log).
- A userspace Vulkan compositor + ICD reachable through the
  `VK_paideia_surface` extension.
- A hardcoded Ghostscript tiger scene: 2000+ paths, mix of stroke
  + fill (both even-odd + non-zero) + gradient fills + one blur
  filter. The scene is encoded per the G4.M1-005 (#1479) format
  and stored as a `_tiger_scene_bytes` byte slice compiled into
  the smoke sidecar.
- The pre-recorded golden CPU-fallback hash for the tiger scene
  at 1920x1080 @ 4x MSAA. Stored as `TIGER_GOLDEN_HASH` in the
  smoke sidecar.
- USB serial cable + minicom/screen for the boot log.

### Procedure

1. Boot the T14 into a paideia-os image with `G4_HW_SMOKE=1` set
   in the loader's `_init_caps` sidecar.
2. The boot witness (`r30_platform.pdx`,
   `g4_hw_smoke_witness_call` at the tail of the G4 block once
   the operator wires it) opens:
   - one `KIND_VELLO_RENDERER` against the Iris Xe context,
     tile_size=16, sample_count=4, coarsening_level=2;
   - one `KIND_VELLO_SCENE` over a KIND_GPU_BO large enough for
     the tiger scene bytes (roughly 512 KiB);
   - one subscription to `vello_render_channel`.
3. The test runs one submission:
   - Calls `vrc_apply_encode(scene_slot, TIGER_BYTES, TIGER_PATHS,
     4, VS_FL_HAS_GRADIENTS|VS_FL_HAS_BLUR|VS_FL_TILED_COARSE)`.
   - Calls `vrc_apply_submit(renderer_slot, scene_slot,
     target_bo_slot)` and captures `submit_id`.
   - Calls `vrc_apply_await(submit_id, 100_000_000)` (100 ms
     watchdog).
   - On success, computes the CPU-fallback hash via `vcf_start`
     + iterated `vcf_ingest` over the tiger's per-tile
     coverage/color tuples, then calls
     `vcf_verify(slot, TIGER_GOLDEN_HASH)`.
4. After the submission, the test asserts:
   - `vrc_apply_await` returned before the watchdog.
   - `vcf_verify` returned OK (bit-exact CPU/GPU equivalence).
   - The tile-grid metrics (`vt_occupied_of`, `vt_skipped_of`,
     `vt_coarsened_of`) sum to at least 90% of the total tile
     count (tx*ty = 240*135 = 32,400 at 1920x1080 / 8-px tiles;
     coarsening pulls tile count down but must cover >=90% of
     the frame).
5. On PASS the boot log emits:

       G4 VELLO TIGER HW SMOKE OK

   On FAIL it emits the offending stage + assertion label and
   halts.

### Expected result

- One submit lands within 100 ms watchdog.
- CPU-fallback hash matches GPU hash bit-for-bit (§7 R3
  mitigation asserts this equivalence for the chosen op set).
- Tile occupancy >=90% of frame; coarsened tiles >=25% (tiger
  has vast flat background regions).

### Failure modes

- If `@wgsl_module` is not linked into the paideia-as toolchain
  the boot witness aborts with a `SKIP: no @wgsl_module` banner.
- If `vrc_apply_await` fires the watchdog the witness fails with
  `G4 VELLO TIGER TIMEOUT`.
- If `vcf_verify` returns HASH_MISMATCH the witness fails with:

       G4 VELLO TIGER HW SMOKE FAIL hash cpu=<H1> gpu=<H2>

- If tile occupancy is below the 90% floor the witness fails
  with the observed (occupied, skipped, coarsened) triple.

---

## Notes

The HW-smoke touches the `vp_submit` primitive that this milestone
lands, so a failure of the QEMU-side dormant witnesses
(`vello_pipeline_synth.pdx`, `vello_cpu_fallback_synth.pdx`,
`g4_integration_synth.pdx`) means the HW smoke will not run either
— the primitive itself has regressed. Fix the QEMU witnesses first.

The confinement gate in `tools/build.sh` pins the writers of
`_vello_scene_table`, `_vello_renderer_table`, `_vp_ring`,
`_ve_ring`, `_vt_state`, and `_vcf_state` to their respective owner
objects. If the HW-smoke witness needs to add a helper writer,
extend the gate rather than remove the pin.

Cross-reference with `tools/hw-smoke-g3.md` for the Vulkan
swapchain substrate the Vello renderer feeds into, and
`tools/hw-smoke-g1.md` for the display-timeline substrate under
that.
