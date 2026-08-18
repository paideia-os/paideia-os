# R34.M3 hardware smoke — operator recipe (T14 G4)

**Owner issue:** #1180 (R34.M3-005, `gated:hardware`).
**Status:** **UNSEEDED.** Every procedure below is written to be run on a
real ThinkPad T14 Gen 4 with a real USB flash key attached, and none of it
has been run. No expected values are recorded, because recording an
expected value nobody measured is the failure this file exists to avoid.

This follows the discipline of `tools/hw-smoke-r30.md` and
`tools/hw-smoke-fingerprints.md`: the recipe lands before first light, and
the expectations are filled in from a real capture, at which point the
corresponding check promotes from SKIP to LIVE.

---

## 0. Scope

This document is the operator-run recipe that promotes the USB
mass-storage substrate landed across R34.M3 (#1176-#1179) from a
QEMU-OVMF structural witness to a real-hardware acceptance witness on
the T14 G4. It does **not** exercise UAS (#1177) end-to-end — most
commodity USB flash keys enumerate BOT-only; a UAS-capable device is a
separate prerequisite noted in §1.1.

The wire this smoke exercises:

- `src/kernel/core/cap/kind_msc_lun.pdx` — KIND_MSC_LUN (0x166), one
  LUN's static identity, derived over KIND_USB_INTERFACE.
- `src/kernel/core/cap/kind_scsi_device.pdx` — KIND_SCSI_DEVICE (0x167),
  one SCSI logical unit's identity, derived over KIND_MSC_LUN.
- `src/kernel/core/cap/kind_usb_urb.pdx` — KIND_USB_URB (0x168), one
  outstanding USB Request Block, derived over KIND_IPC_ENDPOINT.
- `src/kernel/core/drivers/usb/msc/bot.pdx` — CBW/CSW Bulk-Only
  Transport (USB MSC BOT §3).
- `src/kernel/core/drivers/scsi/scsi_cmd.pdx` — SPC-4/SBC-3 CDB
  encode/decode (READ(10)/WRITE(10)/INQUIRY/READ CAPACITY/TEST UNIT
  READY/REQUEST SENSE).
- `src/kernel/core/ipc/usb_transfer_channel.pdx` — SUBMIT/CANCEL/POLL
  RPC schema fronting the URB table.

None of this is wired into `kernel_main_uefi` at boot — the R34.M3
witnesses run only from the boot-witness chain in QEMU-OVMF
(`R30Platform`), which mints and scrubs its own fixtures. There is no
live driver-attach path yet that would enumerate a real USB mass-storage
device on boot; that wiring is R34.M4+ scope (mirrors the R26→R27 xHCI
keyboard precedent — see `tools/xhci-keyboard-smoke.md §4`).

---

## 1. Prerequisites

### 1.1 Hardware

- T14 G4 physical unit (Intel Raptor Lake — the MVP target).
- A USB flash key, BOT-capable (i.e. essentially any commodity USB
  flash drive). Formatted with a known, disposable filesystem — this
  smoke **writes** to the device.
- Optional, for the UAS half of #1177: a UAS-capable enclosure/key
  (`bInterfaceProtocol == 0x62` on its MSC interface). Not required for
  the mount/read/write acceptance criterion, which BOT alone satisfies.
- Serial-over-USB or ethernet-tethered GDB stub, per
  `tools/xhci-keyboard-smoke.md §1.1`.

### 1.2 Firmware / BIOS toggles

Same as `tools/xhci-keyboard-smoke.md §1.2`: UEFI boot, Secure Boot
disabled, Intel VMD Controller disabled, Fast Boot off.

### 1.3 Software

- `build/kernel.elf` from `bash tools/build.sh` (must pass all gates,
  including the R34.M3 `usb-msc-drivers-confine` one-writer checks).
- UEFI boot image via `tools/build-uefi-image.sh`.
- GDB with `gdb-multiarch`.

---

## 2. Operator recipe

### 2.1 Mount + read + write (BOT path)

1. Boot the T14 G4 with the flash key already inserted in a USB-A
   port behind the internal xHCI root complex.
2. Attach GDB; break on `usb_mscbot_witness` if driving the structural
   witness, or (once the R34.M4 driver-attach wire lands) observe the
   boot fingerprint chain directly.
3. Drive the BOT command sequence by hand via GDB, mirroring
   `tests/kernel/drivers/usb/msc/bot_synth.pdx`:
   - INQUIRY — confirm Peripheral Device Type == 0x00 (direct-access
     block device) and a non-garbage vendor/product string.
   - TEST UNIT READY — confirm CSW status == 0 (no sense pending).
   - READ CAPACITY(10) — record the returned LBA count and block size.
     **These numbers are device-specific and must NOT be hard-coded
     into the golden path; they are read back and compared to the
     device's own reported capacity, nothing else.**
   - WRITE(10) a single known pattern block to a **scratch LBA** near
     the end of the device (never LBA 0 — that is the boot sector on
     most preformatted keys).
   - READ(10) the same LBA back; assert byte-for-byte match against
     the pattern written.
   - TEST UNIT READY again — confirm the device did not enter a sense
     state as a side effect of the write.
4. Record actual CBW tag / CSW tag pairing across the whole sequence:
   every CSW's `dCSWTag` must equal the CBW that provoked it. A
   mismatch here is a protocol-layer bug, not a device quirk.

**Acceptance:** INQUIRY succeeds, READ CAPACITY returns a plausible
LBA count and block size, WRITE(10) followed by READ(10) round-trips
the pattern exactly, and no CSW reports a non-zero status across the
sequence. **Expected values: NOT YET MEASURED** (device-dependent by
design — see step 3).

### 2.2 Hot-plug 20x — no capability leak

This is the #1180 deliverable's second half and the one that actually
stresses the mint/revoke discipline in `kind_msc_lun.pdx`,
`kind_scsi_device.pdx`, and `kind_usb_urb.pdx`.

1. Before the first plug, read the three stats cells via GDB:
   ```
   (gdb) p/x _msc_lun_stats
   (gdb) p/x _scsi_device_stats
   (gdb) p/x _usb_urb_stats
   ```
   Each is a `[u64; 4]` laid out `[MINTS, REVOKES, IN_USE_faults,
   ENOSPC_faults]` (see the `*_ST_*` constants in the corresponding
   `kind_*.pdx`). Record the baseline `MINTS - REVOKES` delta — it
   should be 0 coming out of the R34.M3 boot-witness chain, since each
   witness scrubs its own table on exit.
2. Plug the flash key. Let it enumerate and mount (per §2.1 up through
   READ CAPACITY — no write needed for this pass).
3. Unplug. Confirm the driver-attach teardown path revokes the
   KIND_MSC_LUN, KIND_SCSI_DEVICE, and KIND_USB_URB caps it minted for
   this device (i.e. `_*_table` rows for this device's slot go back to
   `in_use == 0`).
4. Repeat steps 2-3 **20 times** (a fresh plug cycle each time — do not
   reuse the enumerated state from a prior cycle).
5. After the 20th unplug, re-read all three stats cells. Assert:
   - `MINTS - REVOKES == 0` for all three kinds (every mint this run
     was matched by a revoke — no leaked row).
   - `IN_USE_faults == 0` and `ENOSPC_faults == 0` for all three (no
     stale row blocked a later mint, and the 16-row `URB_MAX` /
     equivalent ceilings were never exhausted by 20 cycles of a single
     device).

**Acceptance:** `MINTS == REVOKES` (net zero) across all three kinds
after 20 plug/unplug cycles, with zero `IN_USE` or `ENOSPC` faults.
**Expected values: NOT YET MEASURED.**

This assertion requires the R34.M4+ driver-attach + hot-unplug wiring
(the xHCI Port Status Change Event dispatch described in
`tools/xhci-keyboard-smoke.md §4`, extended to the MSC class) — the
teardown-on-unplug path does not exist yet as a boot-time wire, only as
the manual scrub each boot-witness performs on itself. Until that
wiring lands, this section stays blocked, matching the R30.M9
`Blocked. Do not attempt yet.` posture in `tools/hw-smoke-r30.md §1`.

---

## 3. Quirks-database promotion pass

On successful live capture, add a row to `design/hardware/quirks.md
§2.4` for the specific USB flash key/enclosure used (vendor/product
string from INQUIRY, BOT vs UAS, observed LBA count and block size),
status CONFIRMED. Any deviation observed (non-zero CSW status on a
sequence expected to succeed, CBW/CSW tag mismatch, a device that
stalls EP rather than STALLs correctly per BOT §5.3) gets its own row
with the observed behavior and the R34.M3 handling gap.

---

## 4. Related documents

- `design/roadmap/next-wave-synthesis.md §2` — R34 round scope.
- `design/roadmap/next-wave-softarch.md §3` — R34 milestone breakdown.
- `tools/hw-smoke-r30.md` — sibling UNSEEDED recipe; same discipline.
- `tools/xhci-keyboard-smoke.md` — sibling recipe for the R26 xHCI
  keyboard smoke; same shape for the hot-plug wiring this doc is
  blocked on.
- `tests/kernel/drivers/usb/msc/bot_synth.pdx`,
  `tests/kernel/drivers/usb/msc/uas_synth.pdx`,
  `tests/kernel/drivers/scsi/scsi_cmd_synth.pdx`,
  `tests/kernel/cap/msc_lun_synth.pdx`,
  `tests/kernel/cap/scsi_device_synth.pdx`,
  `tests/kernel/cap/usb_urb_synth.pdx` — the QEMU-OVMF structural
  witnesses this recipe promotes from.
