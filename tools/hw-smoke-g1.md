# tools/hw-smoke-g1.md — G1 hardware-smoke recipes

Operator recipes for the two G1 hardware-only tests, per D7
`gated:hardware` discipline. These do NOT run in CI or QEMU; they
run on a real ThinkPad T14 G4 (Iris Xe display + eDP panel + at
least one external DP monitor for the cross-engine test).

Both smokes are marked `dormant` under CI — the witness modules
compile and link but are not called from the QEMU boot path. The
recipes below carry them.

---

## G1.M2-005 (#1436): VRR 40–144 Hz jitter test on real T14 eDP

### Prerequisites

- ThinkPad T14 G4 (Meteor Lake or successor with Iris Xe).
- eDP panel advertising Adaptive-Sync SDP (DPCD 0x00080 bit 6 = 1).
  The T14 G4's default AUO B140HAN06.8 panel qualifies.
- paideia-os built from `main` with the G1 milestone landed.
- USB serial cable + minicom/screen for the boot log.

### Procedure

1. Boot the T14 into a paideia-os image with `G1_HW_SMOKE=1` set in
   the loader's `_init_caps` sidecar.
2. The boot witness (r30_platform.pdx, `g1_vrr_hw_smoke_witness_call`
   at the tail of the G1 block) opens the VRR probe against DDI 1
   (eDP), mints a KIND_VRR_RANGE with the DPCD-advertised range, and
   arms adaptive-sync on DDI 1.
3. The test runs a 60-second render loop drawing a full-screen solid
   color that cycles through refresh setpoints in the range advertised
   by DPCD:
       40 Hz, 60 Hz, 90 Hz, 120 Hz, 144 Hz
   For each setpoint, the loop present-flushes ~90% of the target
   frame budget (so the frame lands well within the panel's window)
   and records the delta between requested and observed refresh.
4. Frame times are collected via `hpet_now_ns` at each vblank; the
   test computes the per-setpoint jitter (max delta - min delta) and
   asserts it stays under one panel refresh period (i.e. 1/max_hz).
5. On PASS the boot log emits:
       G1 VRR HW SMOKE 40-144 Hz OK
   On FAIL it emits the offending setpoint + observed jitter and
   halts.

### Expected result

Every setpoint's jitter stays under 6944 ns (= 1/144 Hz frame period)
on the T14's eDP panel. On the B140HAN06.8, observed jitter in
bring-up runs is under 3000 ns at every setpoint.

### Failure modes

- If DPCD 0x00080 bit 6 is 0, the probe returns NOT_ADAPTIVE and the
  witness aborts with a `SKIP: panel not adaptive-sync-capable`
  banner rather than a fail.
- If EDID range descriptor disagrees with DPCD by more than 1 Hz on
  either endpoint, the mint refuses RANGE_MISMATCH and the witness
  aborts with a `SKIP: firmware inconsistency` banner.
- If a setpoint's jitter exceeds one refresh period, the witness
  fails and prints:
       G1 VRR HW SMOKE FAIL setpoint=<hz> jitter_ns=<n>

---

## G1.M3-006 (#1442): cross-engine sync round-trip on real T14

### Prerequisites

- ThinkPad T14 G4 (as above).
- eDP panel + at least one external DP monitor connected to the T14's
  USB-C DP-alt output (for cross-engine — the GPU engine renders,
  the display engine of a DIFFERENT output presents).
- paideia-os built from `main`.

### Procedure

1. Boot the T14 with `G1_HW_SMOKE_XE=1` in the loader sidecar.
2. The boot witness (r30_platform.pdx, `g1_xe_hw_smoke_witness_call`
   at the tail of the G1 block) mints two KIND_DISPLAY_TIMELINE caps:
   one for (engine=0, output=1) — the eDP — and one for (engine=1,
   output=2) — the external DP.
3. The test runs 1000 round-trips of:
       (a) GPU on engine 0 renders a texture, signals timeline_0 to
           value N.
       (b) Display on engine 1 waits on timeline_0 to reach N via
           wait_scanout, then present_flushes timeline_1 to value N.
       (c) The next iteration on engine 0 waits on timeline_1 to
           reach N via wait_scanout before rendering N+1.
4. For each round-trip the test records the total time from (a) start
   to (c) reach, and asserts the median is under one eDP refresh
   period.

### Expected result

Median round-trip time under 6944 ns (1/144 Hz) on the T14 with the
eDP running at 144 Hz. 99th percentile under 15 ms (~2 refresh
periods) to accommodate GC pauses in the reference-count path.

### Failure modes

- If the external DP is not connected, the test aborts with a
  `SKIP: cross-engine requires two outputs` banner.
- If any round-trip exceeds the timeout (100 ms), the witness fails
  and prints:
       G1 XE HW SMOKE FAIL round=<n> time_ns=<n>

---

## Notes

Both smokes touch the `dpt_row_signal` primitive that this milestone
lands, so a failure of the QEMU-side dormant witness
(`kind_display_timeline_synth.pdx` in the r30_platform boot block)
means the HW smoke will not run either — the primitive itself has
regressed. Fix the QEMU witness first.

The confinement gate in `tools/build.sh` pins the two writers of
`_display_timeline_table` to `kind_display_timeline.o` and
`drivers/dpy/timeline.o`. If either the HW-smoke witness needs to
add a third writer for a benchmark helper, extend the gate rather
than remove the pin.
