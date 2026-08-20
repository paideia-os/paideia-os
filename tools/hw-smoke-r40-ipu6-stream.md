# R40.M3 IPU6 capture-stream hardware smoke — operator recipe (T14 G4)

**Owner issue:** #1358 (R40.M3-004, `gated:hardware`).
**Status:** **UNSEEDED.** Every procedure below is written to be run on a
real ThinkPad T14 Gen 4 with a real Intel IPU6EP (Meteor / Raptor Lake)
image processor, its shipping firmware bundle, and its bound MIPI-CSI
sensor (typically OmniVision OV5670 or a package equivalent). No
expected values are recorded, because recording an expected value
nobody measured is the failure this file exists to avoid.

This follows the discipline of `tools/hw-smoke-r40-ipu6.md`,
`tools/hw-smoke-r38-wifi.md`, `tools/hw-smoke-r37-guc.md`,
`tools/hw-smoke-r35-hotplug.md`, `tools/hw-smoke-r34-isoch.md`,
`tools/hw-smoke-r34.md`, `tools/hw-smoke-r30.md` and
`tools/hw-smoke-fingerprints.md`: the recipe lands before first light,
and the expectations are filled in from a real capture, at which point
the corresponding check promotes from SKIP to LIVE.

---

## 0. Scope

R40.M3 delivers the streaming-session layer above the R40.M1 IPU6
firmware bring-up and the R40.M2 KIND_CSI_CAMERA + PHY/enum/init
substrate:

  * `KIND_IPU6_STREAM` (`src/kernel/core/cap/kind_ipu6_stream.pdx`) --
    the row that names a bound (endpoint, camera, format, w, h, fps)
    quintuple. Derives over `KIND_IPC_ENDPOINT` (5), inherits the
    delivery endpoint id from the parent capability, and binds to a
    live `KIND_CSI_CAMERA` (0x17E) row.
  * `Ipu6Pipeline` (`src/kernel/core/drivers/cam/ipu6_pipeline.pdx`)
    -- the three-stage chain (`DENOISE -> ISP -> FORMAT`) with a
    scaffolded per-frame executor and per-stage entry counters.
  * `CameraCaptureChannel`
    (`src/kernel/core/ipc/camera_capture_channel.pdx`) -- the session
    schema: `open -> configure -> begin_stream -> frame* -> end_stream
    -> close`. The `FRAME` reply carries a `KIND_GPU_BO` slot ordinal
    (zero-copy: the buffer is a pre-imported GPU BO the pipeline
    hands back on completion, per R37 KIND_GPU_BO discipline).

The QEMU-OVMF boot exercises the three-module structural witness set
(`R40 KIND_IPU6_STREAM OK`, `R40 IPU6 PIPELINE OK`, `R40 CAM CAPTURE
CHAN OK` -- see `tools/hw-smoke-fingerprints.md` when it is amended).
Everything below runs OFF that path, against real silicon.

## 1. Pre-flight

1. Boot the T14 G4 with the R40.M1 firmware bundle loaded and the
   `R40 IPU6 LOAD OK` fingerprint on the console (see
   `tools/hw-smoke-r40-ipu6.md` §4).
2. Confirm `R40 SENSOR ENUM OK` and `R40 SENSOR INIT OK` fingerprints
   are on the console -- the M2 substrate has bound its sensor.
3. Confirm `R40 KIND_IPU6_STREAM OK`, `R40 IPU6 PIPELINE OK` and
   `R40 CAM CAPTURE CHAN OK` are on the console -- the M3 structural
   witnesses passed.

## 2. Mint the capture session

1. From the ring-3 camera supervisor, hold:
   * a live `KIND_IPC_ENDPOINT` (5) capability the compositor will
     receive frame notifications on, with `RIGHT_MINT`;
   * a live `KIND_CSI_CAMERA` (0x17E) capability naming the sensor.
2. Mint `KIND_IPU6_STREAM` (0x17F) with:
   * `format = IPU6S_FMT_NV12 (1)`
   * `width  = 1920`
   * `height = 1080`
   * `fps    = 30`
3. Refuse if `ipu6_stream_cap_mint_inner` returns non-zero. Record the
   returned error code (should be one of `IPU6S_MINT_*` per
   `kind_ipu6_stream.pdx` §2).

## 3. Configure the pipeline

1. Call `ipp2_configure(stream_key, IPP2_FMT_NV12, 1920, 1080)`.
2. Expect `IPP2_OK` (0). A non-zero return is the pipeline refusing;
   record the code.

## 4. Open the capture session

1. Call `ccc_open(stream_slot)`.
2. Call `ccc_configure(CCC_FMT_NV12, 1920, 1080, 30)`.
3. Call `ccc_begin_stream()`.
4. Confirm `ccc_fsm_get() == CCC_STATE_STREAMING (3)`.

## 5. **THE MEASUREMENT (SKIP until captured)**

Run for exactly 10 seconds. For each frame delivered:

  * Confirm `ccc_frame(bo_slot)` returns `CCC_OK` (0).
  * Confirm `ccc_last_bo_get()` matches the returned bo_slot.
  * Confirm the bound `KIND_GPU_BO` row's format matches
    `IPU6S_FMT_NV12` and its dimensions match 1920 x 1080.

**Expected count: 300 frames (30 fps sustained × 10 s).**

The **SKIP** promotes to **LIVE** when the operator has measured the
count on real silicon and recorded:

  * `MIN_FRAMES_10S = ___`  (the tolerated floor -- do not seed
     without a measured floor)
  * `MAX_FRAMES_10S = ___`  (the tolerated ceiling; the pipeline
     should not exceed the requested rate)
  * A one-frame screenshot committed to `docs/hw-smoke/r40-m3-frame0.ppm`
    for visual inspection (through the display supervisor).

## 6. Tear down

1. `ccc_end_stream()` -- FSM returns to `CCC_STATE_CONFIGURED`.
2. `ccc_close()` -- FSM returns to `CCC_STATE_CLOSED`.
3. `ipp2_teardown()` -- pipeline unbinds.
4. `ipu6_stream_cap_revoke_inner(slot)` -- capability revoked.

## 7. Blob-policy check

Per D1.a, the IPU6 firmware bundle carried BOTH a vendor RSA-2048
signature AND a paideia Dilithium-2 signature. Rerun the smoke with a
DELIBERATELY CORRUPTED signature slot and confirm the load path
refuses the boot with the corresponding `IPV_BAD_*_SIG` code per
`tools/hw-smoke-r40-ipu6.md` §5.

## 8. When the numbers arrive

Amend §5 with the measured MIN/MAX. Amend
`tools/hw-smoke-fingerprints.md` with the promoted line:

  * `R40 IPU6 STREAM HW-SMOKE OK n=<frames>/10s (LIVE)`

And replace `tests/kernel/drivers/cam/hw_smoke_ipu6_stream_placeholder.pdx`
with a real live-hardware witness.
