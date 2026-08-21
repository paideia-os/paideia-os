# tools/hw-smoke-g2.md — G2 hardware-smoke recipes

Operator recipe for the G2 hardware-only test, per D7
`gated:hardware` discipline. This does NOT run in CI or QEMU; it
runs on a real ThinkPad T14 G4 (Iris Xe display + eDP panel with
Adaptive-Sync).

The smoke is marked `dormant` under CI — the KIND_SCANOUT_LEASE
substrate compiles and the boot witness exercises structural paths
against synthetic rows, but the fullscreen-video test below runs
only on real hardware.

---

## G2.M2-005 (#1452): fullscreen video with VRR + zero tearing on real T14 eDP

### Prerequisites

- ThinkPad T14 G4 (Meteor Lake or successor with Iris Xe).
- eDP panel advertising Adaptive-Sync SDP (DPCD 0x00080 bit 6 = 1).
  The T14 G4's default AUO B140HAN06.8 panel qualifies.
- paideia-os built from `main` with the G1 (display timeline + VRR)
  and G2 (scanout lease) milestones landed.
- USB serial cable + minicom/screen for the boot log.
- A test video: 60 seconds of variable-motion content
  (`tools/hw-smoke/tears-of-steel-60s-vfr.mkv` — VFR 30–60 fps).

### Procedure

1. Boot the T14 into a paideia-os image with `G2_HW_SMOKE=1` set in
   the loader's `_init_caps` sidecar.
2. The boot witness (`r30_platform.pdx`,
   `g2_scanout_hw_smoke_witness_call` — dormant placeholder
   registered at the tail of the G2 block) does the following:
   a. Opens the display topology, finds the eDP output on DDI 1.
   b. Mints a KIND_DISPLAY_TIMELINE against DDI 1 (G1.M1).
   c. Mints a KIND_VRR_RANGE with the DPCD-advertised range (G1.M2).
   d. Arms adaptive-sync on DDI 1 via `vrc_apply_enable` (G1.M2).
   e. Calls `scanout_default_for_fullscreen(plane_slot=1,
      output_slot=eDP, timeline_slot)` (G2.M3-004 P7) to obtain a
      lease.
   f. Decodes the test video (deferred to G3 Vulkan swapchain path;
      for the G2 dry-run the loop presents solid-color frames whose
      period modulates through the VRR range).
3. The render loop presents ~1800 frames (60 s × 30 fps average)
   through `slc_apply_present(lease, bo, target_scanout_value)`
   where `target_scanout_value` = current_scanout + 1 (per-frame VRR
   frame-latch, G2.M2-001).
4. Frame times are collected via `hpet_now_ns` at each vblank; the
   test computes:
   - **frame-time consistency**: max delta - min delta across all
     frames, per-setpoint;
   - **tear count**: number of vblanks at which the plane's
     next-buffer register was updated mid-scanout (detected via the
     `_scanout_in_flight` cell not being zero when the ISR reads it
     inside a scanout period, per G2.M2-002 single-buffer
     discipline).
5. On PASS the boot log emits:

       G2 SCANOUT HW SMOKE FULLSCREEN VRR OK

   On FAIL it emits the offending frame count + observed tear count
   and halts.

### Expected result

- **Zero torn frames** across the 60-second run — G2.M2-002 asserts
  single-buffer in-flight discipline: at most one buffer per lease
  is armed for scanout, so the plane's next-buffer register never
  changes mid-scanout.
- **Frame-time consistency**: per-setpoint jitter stays under one
  panel refresh period (< 6944 ns at 144 Hz).
- **Lease continuity**: the lease stays GRANTED for the full run;
  `sl_row_state(lease_row) == 1` at the end.

### Failure modes

- **Torn frames** > 0: the single-buffer arbiter in
  `drivers/dpy/scanout.pdx` §4 let a second present through while
  the first was in flight. Root-cause via `scanout_stat(SCN_ST_
  REFUSED)` — it should equal the number of tearing-prevention
  refusals across the run.
- **Lease REVOKED mid-run**: the compositor recovered the plane for
  another client (a fullscreen browser tab going foreground on a
  second output triggers this). The expected recovery path is
  `SCN_ST_FALLBACKS == 1` after the transition, with the
  compositor's own framebuffer visible.
- **Lease EXPIRED mid-run**: the safety-net auto-revoke fired
  (`scanout_expiry_sweep` returned non-zero). Root cause: the render
  loop stalled longer than `SCN_DEFAULT_EXPIRY_NS` = 5 s without a
  present. This is EXPECTED under the safety-net policy; a
  fullscreen client that hangs for 5 s SHOULD lose its lease.
- **VRR not armed**: `dpy_vrr_is_armed(DDI=1) == 0`. Check that
  G1.M2 landed and that the DPCD probe found an Adaptive-Sync
  panel (`dpy_vrr_stat(DPY_VRR_ST_PROBES) > 0`).

### Placement

This recipe carries the acceptance for issue #1452. The dormant
witness in `tests/kernel/drivers/dpy/scanout_hw_smoke_placeholder.pdx`
records the intent but is not registered in the r30_platform witness
chain — the recipe above is the acceptance path. When the R43
scheduler adds a wait-queue for present-feedback (replacing the
current spin in `drivers/dpy/timeline.pdx`), the recipe will be
extended to assert the per-frame present-feedback stream matches
the requested VRR cadence.
