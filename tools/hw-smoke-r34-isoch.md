# R34.M5 isochronous hardware smoke — operator recipe (T14 G4)

**Owner issue:** #1190 (R34.M5-005, `gated:hardware`).
**Status:** **UNSEEDED.** Every procedure below is written to be run on a
real ThinkPad T14 Gen 4 with a real USB audio-class device attached, and
none of it has been run. No expected values are recorded, because
recording an expected value nobody measured is the failure this file
exists to avoid.

This follows the discipline of `tools/hw-smoke-r34.md`, `tools/hw-smoke-r30.md`
and `tools/hw-smoke-fingerprints.md`: the recipe lands before first
light, and the expectations are filled in from a real capture, at which
point the corresponding check promotes from SKIP to LIVE.

---

## 0. Scope

This document is the operator-run recipe that promotes the USB
isochronous substrate landed across R34.M5 (#1186-#1189) from a
QEMU-OVMF structural witness to a real-hardware acceptance witness on
the T14 G4. It exercises the **USB Audio Class (UAC1/UAC2, bInterface
Class 0x01)** path rather than UVC, because a commodity USB audio DAC
(or the ThinkPad's own internal USB audio if it enumerates) is easier
to obtain and safer to write to than a webcam.

The wire this smoke exercises:

- `src/kernel/core/cap/kind_isoch_stream.pdx` — KIND_ISOCH_STREAM
  (0x169), one isochronous stream's static identity, derived over
  KIND_USB_ENDPOINT.
- `src/kernel/core/drivers/usb/xhci/sof_timeline.pdx` — 11-bit frame
  counter, microframe advance, per-microframe byte budget.
- `src/kernel/core/drivers/usb/xhci/isoch_ring.pdx` — ISOCH TRB shadow
  ring, Schedule Frame ID stamping, service-interval enforcement.
- `src/kernel/core/drivers/usb/uvc/uvc_synth.pdx` — UVC payload
  header + frame reassembly (used here only as a shape check; UAC has
  a different payload shape but shares the isoch delivery path).

None of this is wired into `kernel_main_uefi` at boot — the R34.M5
witnesses run only from the boot-witness chain in QEMU-OVMF
(`R30Platform`), which mints and scrubs its own fixtures. There is no
live driver-attach path yet that would enumerate a real USB audio
device on boot; that wiring is R34.M6+ scope (mirrors the R34.M3 →
R34.M5 shape — see `tools/hw-smoke-r34.md §0`).

---

## 1. Prerequisites

### 1.1 Hardware

- T14 G4 physical unit (Intel Raptor Lake — the MVP target).
- A USB audio-class device: any commodity USB DAC (UAC 1 or UAC 2),
  or an active USB microphone. Not required to have functioning
  playback path — this smoke only opens an isoch stream and confirms
  the ring accepts admits at the declared service interval.
- Serial-over-USB or ethernet-tethered GDB stub, per
  `tools/xhci-keyboard-smoke.md §1.1`.

### 1.2 Firmware / BIOS toggles

Same as `tools/xhci-keyboard-smoke.md §1.2`: UEFI boot, Secure Boot
disabled, Intel VMD Controller disabled, Fast Boot off.

### 1.3 Software

- `build/kernel.elf` from `bash tools/build.sh` (must pass all gates,
  including the R34.M5 `isoch-stream-confine`, `sof-timeline-confine`,
  `isoch-ring-confine` and `uvc-synth-confine` one-writer checks).
- UEFI boot image via `tools/build-uefi-image.sh`.
- GDB with `gdb-multiarch`.

---

## 2. Operator recipe

### 2.1 SOF timeline advances at 1 kHz

1. Boot the T14 G4 with no USB devices attached other than input.
2. Attach GDB; break on any post-`R30Platform` witness (`init_task`
   entry is safe).
3. Read `_sof_state` and `_sof_stats` twice, one second apart:
   ```
   (gdb) p/x _sof_state
   (gdb) p _sof_stats
   (gdb) shell sleep 1
   (gdb) p _sof_stats
   ```
   `SOF_ST_UFRAMES` should have advanced by approximately 8000
   (8 microframes / ms × 1000 ms) and `SOF_ST_FRAMES` by approximately
   1000. Exact values depend on GDB stop-the-world latency.

**Acceptance:** UFRAMES delta in [7500, 8500] and FRAMES delta in
[900, 1100] across a 1-second wall-clock interval. **Expected
values: NOT YET MEASURED** (requires a live xHCI SOF-event dispatch
wire, which is R34.M6+ scope; until that wire lands this section
stays blocked and the numbers stay at zero, matching the R34.M3
`Blocked. Do not attempt yet.` posture in `tools/hw-smoke-r34.md §2.2`).

### 2.2 Mint + revoke isoch stream 20x — no capability leak

This is the #1190 deliverable's second half and the one that actually
stresses the mint/revoke discipline in `kind_isoch_stream.pdx`.

1. Before the first mint, read the stats cell via GDB:
   ```
   (gdb) p/x _isoch_stream_stats
   ```
   This is a `[u64; 4]` laid out `[MINTS, REVOKES, IN_USE_faults,
   ENOSPC_faults]`. Record the baseline `MINTS - REVOKES` delta — it
   should be 0 coming out of the R34.M5 boot-witness chain, since the
   witness scrubs its own table on exit.
2. Plug the USB audio device. Let it enumerate. Once the driver-
   attach wire (R34.M6+) opens an isoch stream against its microphone
   or speaker endpoint, one `_isoch_stream_table` row should populate.
3. Unplug. Confirm the driver-attach teardown path revokes the
   KIND_ISOCH_STREAM cap it minted for this device.
4. Repeat steps 2-3 **20 times** (a fresh plug cycle each time — do not
   reuse the enumerated state from a prior cycle).
5. After the 20th unplug, re-read the stats cell. Assert:
   - `MINTS - REVOKES == 0` (every mint this run was matched by a
     revoke — no leaked row).
   - `IN_USE_faults == 0` and `ENOSPC_faults == 0` (no stale row
     blocked a later mint, and the 16-row `ISOCH_MAX` ceiling was
     never exhausted by 20 cycles of a single device).

**Acceptance:** `MINTS == REVOKES` (net zero) with zero `IN_USE` or
`ENOSPC` faults. **Expected values: NOT YET MEASURED.**

This assertion requires the R34.M6+ driver-attach + hot-unplug wiring
(the xHCI Port Status Change Event dispatch described in
`tools/xhci-keyboard-smoke.md §4`, extended to the isochronous class) —
the teardown-on-unplug path does not exist yet as a boot-time wire,
only as the manual scrub each boot-witness performs on itself. Until
that wiring lands, this section stays blocked, matching the R30.M9 and
R34.M3 `Blocked. Do not attempt yet.` posture.

### 2.3 Service-interval enforcement under sustained load

Once the driver-attach wire admits a stream and begins scheduling ISOCH
TRBs against `isoch_ring_append`, this section becomes runnable:

1. Break on `isoch_ring_append` with GDB `commands` script counting
   invocations and recording the returned `sfi` and `length`.
2. Run for 60 seconds. Assert every invocation's `sfi` differs from
   the prior invocation's by AT LEAST the stream's declared
   `service_interval` (in frames, converted from microframes if HS).
3. Read `_isoch_ring_stats[ISOCH_RING_ST_REJECTS]` at the end.
   Assert 0.

**Acceptance:** No two adjacent TRBs schedule closer than
service_interval frames, and no admits were rejected during a period
where the SOF timeline reports no oversubscription. **Expected
values: NOT YET MEASURED.**

---

## 3. Quirks-database promotion pass

On successful live capture, add a row to `design/hardware/quirks.md
§2.4` for the specific USB audio device used (vendor/product string
from Get_Descriptor, UAC version, isoch endpoint bInterval, observed
bandwidth reservation), status CONFIRMED. Any deviation observed
(SFI stamping outside the declared window, admit rejects with an
idle SOF budget, a device that STALLs on its isoch endpoint rather
than dropping a packet) gets its own row with the observed behavior
and the R34.M5 handling gap.

---

## 4. Related documents

- `design/roadmap/next-wave-synthesis.md §2` — R34 round scope.
- `design/roadmap/next-wave-softarch.md §3` — R34 milestone breakdown.
- `tools/hw-smoke-r34.md` — sibling UNSEEDED recipe for R34.M3;
  same discipline.
- `tools/hw-smoke-r30.md` — sibling UNSEEDED recipe for R30.M9.
- `tools/xhci-keyboard-smoke.md` — sibling recipe for the R26 xHCI
  keyboard smoke; same shape for the hot-plug wiring this doc is
  blocked on.
- `tests/kernel/cap/isoch_stream_synth.pdx`,
  `tests/kernel/drivers/usb/xhci/sof_timeline_synth.pdx`,
  `tests/kernel/drivers/usb/xhci/isoch_ring_synth.pdx`,
  `tests/kernel/drivers/usb/uvc/uvc_synth_synth.pdx` — the QEMU-OVMF
  structural witnesses this recipe promotes from.
- `tests/kernel/drivers/usb/isoch/hw_smoke_audio_placeholder.pdx` —
  the dormant placeholder module this recipe drives.
