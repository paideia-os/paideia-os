# R40.M1 IPU6 firmware bring-up hardware smoke — operator recipe (T14 G4)

**Owner issue:** #1350 (R40.M1-004, `gated:hardware`).
**Status:** **UNSEEDED.** Every procedure below is written to be run on a
real ThinkPad T14 Gen 4 with a real Intel IPU6EP (Meteor / Raptor Lake)
image processor plus its shipping firmware bundle, and no expected values
are recorded, because recording an expected value nobody measured is the
failure this file exists to avoid.

This follows the discipline of `tools/hw-smoke-r38-wifi.md`,
`tools/hw-smoke-r37-guc.md`, `tools/hw-smoke-r35-hotplug.md`,
`tools/hw-smoke-r34-isoch.md`, `tools/hw-smoke-r34.md`,
`tools/hw-smoke-r30.md` and `tools/hw-smoke-fingerprints.md`: the recipe
lands before first light, and the expectations are filled in from a real
capture, at which point the corresponding check promotes from SKIP to
LIVE.

---

## 0. Scope

This document is the operator-run recipe that promotes the IPU6 firmware
bring-up composition landed across R40.M1 (#1347-#1349) from a
QEMU-OVMF structural witness to a real-hardware acceptance witness on
the T14 G4.  It exercises the **IPU6 firmware bring-up wire** — PCI
probe + BAR mapping, dual-signature verify, code-section upload and
BOOT_READY handshake — end to end against the on-chip IPU6EP.

The wire this smoke exercises:

- `src/kernel/core/drivers/cam/ipu6_probe.pdx` — PCI vendor/device
  filter (Intel 0x8086 / 0x9A19 TGL or 0x462E MTL-RPL), BAR0
  validation (8 MB minimum, 64 KiB alignment), chip revision decode.
- `src/kernel/core/drivers/cam/ipu6_verify.pdx` — dual-signature
  admission (RSA-2048 vendor + Dilithium-2 paideia re-sign, per D1.a).
- `src/kernel/core/drivers/cam/ipu6_load.pdx` — code section upload
  via DMA seam, CPU_HALT release, BOOT_READY poll with bounded wait.

None of this is wired into `kernel_main_uefi` at boot on either target
— the R40.M1 witnesses run only from the boot-witness chain in
QEMU-OVMF (`R30Platform`), which resets every module on entry and on
exit.  There is no live IPU6 transport binding on the QEMU path, no
on-chip SRAM to shovel firmware into, no BOOT_READY interrupt to
wait for; that wiring is R40.M3+ (live supervisor) scope.

---

## 1. Prerequisites

### 1.1 Hardware

- T14 G4 physical unit (Intel Raptor Lake, MVP target — the IPU6EP
  integrated image processor is the qualified path).
- Physical webcam sensor attached over MIPI-CSI (the T14 G4 lid
  webcam is the qualified sensor; a covered privacy shutter still
  lets the ISP boot, so the shutter position is not part of this
  check).
- IPU6EP firmware bundle from the Intel firmware repository, both
  the vendor-signed original and a paideia-re-signed copy (the
  re-sign key + procedure live in `design/security/blob-resign.md`;
  the exact path is deferred to R32 wave-2).
- Serial-over-USB or ethernet-tethered GDB stub, per
  `tools/xhci-keyboard-smoke.md §1.1`.

### 1.2 Firmware / BIOS toggles

Same as `tools/xhci-keyboard-smoke.md §1.2`, plus:
- Camera enabled in BIOS (the T14 G4 lets the camera be
  privacy-hard-disabled through firmware; this check needs it
  enabled).
- Intel VT-d **disabled** for the first-light capture.  VT-d routes
  IPU6 MMIO through the IOMMU, which is a later-wave scope.

### 1.3 Software

- `build/kernel.elf` from `bash tools/build.sh` (must pass all
  QEMU-OVMF fingerprints in `tests/r17/shell-shutdown.golden`,
  including `R40 IPU6 PROBE OK`, `R40 IPU6 VERIFY OK`,
  `R40 IPU6 LOAD OK`).
- A supervisor (deferred to R40.M3+) that binds a KIND_CSI_CAMERA
  cap and drives the composition into `kernel_main_uefi`.

---

## 2. Procedure

Each subsection is a distinct check.  Every one starts SKIP; every
one is promoted to LIVE by observing a real value on the T14 G4 and
recording it in the *Expected* box.  A LIVE check whose observation
disagrees with the recorded value is a REGRESSION — the recorded
value is what R40.M1 landed against, not what a passing boot happens
to produce this month.

### 2.1 PCI probe recognises IPU6EP (ipu6_probe)

Purpose: verify that `ipp_probe_recognise` accepts the T14 G4's IPU6EP
BAR shape and rejects everything else.

Steps (deferred to R40.M3+ supervisor):
1. Boot with the ring-3 supervisor that binds a KIND_HW cap over
   the IPU6EP PCI function.
2. Issue an IPC call `ipp_probe_recognise(class_pair, vendor,
   device_id, bar0_base, bar0_len, caps)` with values read out of
   `lspci -vvv` for the IPU6 function.
3. Verify the return value is not one of the failure codes
   (0xFFFFF268..0xFFFFF26F) and that the decoded (hw_type, step,
   dash) triple matches the CHIP_REV read directly through mmap.

Expected: **UNSEEDED.**

### 2.2 Firmware bundle dual-signature verify (ipu6_verify)

Purpose: verify that a valid (vendor-signed + paideia-re-signed)
bundle passes `ipv_verify` and that a bundle missing either signature
is rejected with the correct failure code.

Steps (deferred to R40.M3+ supervisor):
1. Load the vendor+paideia dual-signed bundle from disk into a
   contiguous kernel buffer.
2. Issue `ipv_verify(blob_ptr, blob_len)` — record the return code.
   Verify it is 0 (IPV_OK).
3. Verify `ipv_is_verified()` returns 1 and that
   `ipv_code_off_of()` / `ipv_code_len_of()` match the section
   header on disk.
4. Corrupt the vendor signature slot (zero its two words) in a copy
   of the buffer; call `ipv_verify` on the copy — verify the return
   is 0xFFFFF25C (BAD_VENDOR_SIG).
5. Corrupt the paideia signature slot instead; verify the return is
   0xFFFFF25B (BAD_PAIDEIA_SIG).

Expected: **UNSEEDED.**

### 2.3 Firmware upload + BOOT_READY handshake (ipu6_load)

Purpose: verify that a verified bundle uploads through the IPU6 CTRL
seam, releases CPU_HALT, and observes the BOOT_READY notification
within the bounded wait.

Steps (deferred to R40.M3+ supervisor):
1. With a bundle admitted per §2.2, issue `ipl_load(chip_rev)`
   where `chip_rev` is the value decoded per §2.1.
2. Verify the return is 0 (IPL_OK) and that `ipl_is_loaded()`
   returns 1.
3. Verify `ipl_ready_iters_of()` is significantly below
   `IPL_READY_MAX_ITERS` (a real IPU6EP responds well inside the 2s
   window; a poll count within a few thousand iterations is the
   healthy shape).
4. Read `CTRL_CODE_ADDR` / `CTRL_CODE_DIGEST` through
   `ipl_ctrl_read(3)` / `ipl_ctrl_read(4)` and verify they echo
   what the DMA descriptor requested.
5. Read `CTRL_UPLOAD_SEQ` through `ipl_ctrl_read(5)` and verify it
   bumped to 1.

Expected: **UNSEEDED.**

### 2.4 Firmware version report

Purpose: verify that the ALIVE / BOOT_READY notification carries the
firmware version string the bundle header advertised.

Steps (deferred to R40.M3+ supervisor):
1. After §2.3, issue an IPC call into the R40.M3+ IPU6 supervisor
   to read the firmware version string out of the ALIVE payload.
2. Compare the string against the version field in the on-disk
   bundle header.

Expected: **UNSEEDED.**

---

## 3. What promotes this document from UNSEEDED to LIVE

- All four sub-checks recorded against a single physical unit + a
  single firmware bundle.
- Every SKIP mark replaced with a concrete measurement.
- The three QEMU-OVMF fingerprints (`R40 IPU6 PROBE OK`,
  `R40 IPU6 VERIFY OK`, `R40 IPU6 LOAD OK`) still pass on the same
  `build/kernel.elf` used for the hardware capture.
- A follow-up issue lands `tests/kernel/drivers/cam/hw_smoke_ipu6.pdx`
  replacing the placeholder in
  `tests/kernel/drivers/cam/hw_smoke_ipu6_placeholder.pdx`.
