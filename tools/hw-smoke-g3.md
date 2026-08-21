# tools/hw-smoke-g3.md — G3 hardware-smoke recipe

Operator recipe for the G3 hardware-only test, per D7
`gated:hardware` discipline. This does NOT run in CI or QEMU; it
runs on a real ThinkPad T14 G4 (Iris Xe GPU + eDP panel + a working
Vulkan userspace ICD reachable through the `VK_paideia_surface`
extension).

The smoke is marked `dormant` under CI — the witness module
(`tests/kernel/drivers/vk/hw_smoke_g3_placeholder.pdx`) compiles
and links but is not called from the QEMU boot path.

---

## G3.M4-003 (#1474): Vulkan triangle renders with feedback loop on real T14

### Prerequisites

- ThinkPad T14 G4 (Meteor Lake or successor with Iris Xe).
- eDP panel with G1 display-timeline substrate + G3 swapchain
  substrate landed (kernel booted with G1 + G3 fingerprints
  reported on the boot log).
- A userspace Vulkan compositor + ICD reachable through the
  `VK_paideia_surface` extension registered in `vki_register`.
- A hardcoded SPIR-V vertex + fragment shader pair drawing a
  full-screen triangle (rgb interpolation).
- USB serial cable + minicom/screen for the boot log.

### Procedure

1. Boot the T14 into a paideia-os image with `G3_HW_SMOKE=1` set
   in the loader's `_init_caps` sidecar.
2. The boot witness (`r30_platform.pdx`,
   `g3_hw_smoke_witness_call` at the tail of the G3 block once
   the operator wires it) opens:
   - one `KIND_VK_SURFACE` against DDI 1 (eDP);
   - one `KIND_VK_SWAPCHAIN_IMAGE` rotation of image_count=3 in
     `VKSI_MODE_FIFO`;
   - one `KIND_DISPLAY_TIMELINE` per (engine, output) pair;
   - one subscription to `vk_present_feedback_channel`.
3. The test runs 60 rendered frames of the triangle:
   - Each frame calls `vswc_acquire`, submits the SPIR-V shaders
     against the acquired BO, calls `vswc_present(present_id=N,
     target_pts=0)`, then calls `vkf_wait_present(present_id=N,
     timeout_ns=100ms)`.
   - The presenter must return with a non-zero timestamp before
     the watchdog fires.
4. After frame 60, the test asserts:
   - Every `vkf_wait_present` returned before the watchdog.
   - The observed present timestamps are strictly monotone.
   - `vkb_average_latency` (acquire→present) is under one refresh
     period at the panel's default rate (16.7 ms for 60 Hz eDP).
5. On PASS the boot log emits:

       G3 VK HW SMOKE TRIANGLE OK

   On FAIL it emits the offending frame + assertion label and
   halts.

### Expected result

- 60 present cycles land without watchdog timeout.
- Monotonic present_ids observed on the feedback stream.
- Median acquire→present latency under 16.7 ms; p99 under 33 ms
  (~2 refresh periods).

### Failure modes

- If the ICD does not declare `VK_paideia_surface`, the boot
  witness aborts with a `SKIP: no VK_paideia_surface ICD` banner.
- If the SPIR-V blob fails the loader magic check, the witness
  aborts with a `SKIP: SPIR-V validation failed` banner.
- If any frame's watchdog fires, the witness fails and prints:

       G3 VK HW SMOKE FAIL frame=<n> reason=<label>

- If the observed latency exceeds one refresh period at p50, the
  witness fails with the recorded distribution.

---

## Notes

The HW-smoke touches the `vswc_present` primitive that this
milestone lands, so a failure of the QEMU-side dormant witnesses
(`swapchain_synth.pdx`, `features_synth.pdx`,
`g3_integration_synth.pdx`) means the HW smoke will not run either
— the primitive itself has regressed. Fix the QEMU witnesses
first.

The confinement gate in `tools/build.sh` pins the writers of
`_vk_swapchain_image_table`, `_vfc_queue`, and `_vkb_ring` to their
respective owner objects. If the HW-smoke witness needs to add a
third writer for a bench helper, extend the gate rather than
remove the pin.

Cross-reference with `tools/hw-smoke-g1.md` for the vblank
substrate the G3 swapchain rides on, and `tools/hw-smoke-r47-vmd.md`
for the VMD storage substrate that must be up before a graphics
smoke on a modern SKU is meaningful.
