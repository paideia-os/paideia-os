# R19 First-Light Boot Guide — Thinkpad T14 Gen 4

**Issue:** paideia-os#804
**Round / Milestone:** R19 / R19.M5-004
**Artefact:** `build/uefi/paideia-esp.img` (64 MiB FAT32 with `/EFI/BOOT/BOOTX64.EFI` + `/paideia/kernel.elf`)

This document walks a paideia developer through booting the R19.M5
UEFI image on a real Lenovo Thinkpad T14 Gen 4 (Raptor Lake, TPM 2.0,
Secure Boot capable). It complements the QEMU + OVMF fixtures at
`tools/run-uefi-ovmf.sh` (#802) and `tools/run-uefi-swtpm.sh` (#803)
by capturing the hardware-specific setup + expected behaviour + known
failure modes for the actual T14 G4 that R19 targets.

**Status at R19.M5 close:** the artefact + guide are ready. Real-HW
confirmation is a separate step the operator performs and records in
`design/round-retrospectives/r19-closure.md`. Confirmation is expected
to reproduce the OVMF observable — the stub reaches the finalizer's
`push _kernel_main_uefi_pa; ret` and jumps to a bare LMA that has no
kernel code loaded there, so the CPU stumbles forward until the T14's
own microcode raises an exception. That is the correct M5 behaviour;
end-to-end kernel-side execution requires the R20 ELF loader that
consumes the M5 LMA-substituted stub.

---

## 1. Build the image

```
git clone --recursive git@github.com:paideia-os/paideia-os.git
cd paideia-os
(cd tools/paideia-as && cargo build --release -p paideia-as)
bash tools/build.sh              # → build/kernel.elf
bash tools/build-uefi-stub.sh    # → build/uefi/uefi_stub.efi (LMA-substituted)
bash tools/build-uefi-image.sh   # → build/uefi/paideia-esp.img (64 MiB)
```

The final image should be `~67108864` bytes and `file(1)` will
identify it as `DOS/MBR boot sector, ... FAT (32 bit), ...`.

## 2. Write to USB

Identify the USB target (**double-check** — writing to the wrong
device destroys data):

```
lsblk -o NAME,SIZE,TYPE,MODEL,TRAN | grep -i usb
```

Assume `/dev/sdX`. Write:

```
sudo dd if=build/uefi/paideia-esp.img of=/dev/sdX bs=4M oflag=direct,sync status=progress
sync
```

Verify the FAT is readable off the stick:

```
sudo mount /dev/sdX /mnt/paideia
ls -R /mnt/paideia/EFI /mnt/paideia/paideia
sudo umount /mnt/paideia
```

Expected: `/mnt/paideia/EFI/BOOT/BOOTX64.EFI` (~3 KiB) +
`/mnt/paideia/paideia/kernel.elf` (~262 KiB at R19.M5).

## 3. Thinkpad T14 G4 BIOS setup

Enter BIOS setup by tapping **F1** at power-on (with the ThinkPad logo
on screen). Under **Security**:

- **Secure Boot** — set to **Disabled** for R19.M5. The stub is
  unsigned; signed-boot support lands in a follow-up round (currently
  pinned as R23-plus in `design/roadmap/r18-plus-bare-metal.md`).
- **TPM 2.0** — leave **Enabled**. Our R19.M3 TCG2 probe
  (`src/boot/uefi_tcg2.pdx`) will silently no-op if no TPM is present
  and record a `HashLogExtendEvent` if one is; enabled is the more
  interesting test surface.

Under **Config → Storage**:

- **VMD Controller** (Intel Volume Management Device) — set to
  **Disabled**. VMD hides SATA/NVMe behind an Intel-proprietary
  controller that our R19 code has no drivers for. Even though we
  boot from USB (not internal SSD), some T14 BIOS revisions couple
  VMD activation with USB EHCI controller quirks that manifest as a
  spurious "boot device not found" on the paideia ESP.

Under **Startup**:

- **UEFI/Legacy Boot** — set to **UEFI Only**. Legacy CSM is not on
  the paideia roadmap; leaving it enabled adds boot-order ambiguity
  that has bitten first-light attempts on ThinkPads before.
- **Boot Priority Order** — move `USB HDD` above the internal SSD.

Save and exit (**F10**), then boot.

## 4. Expected serial capture

The T14 G4 has no built-in serial header, so console capture requires
one of:

- **USB serial dongle** — connect a FT232 / CH340 to the ThinkPad USB-C
  Dock (Gen 2) — the dock exposes a serial adapter as `ttyUSB0` on a
  host machine running `screen /dev/ttyUSB0 115200,8n1`. Not all T14 G4
  configs have serial through their dock; verify with `lsusb -v` on the
  host once plugged into the dock.
- **UEFI-to-video capture** — the R19.M3 GOP capture path
  (`src/boot/uefi_gop.pdx`) latches the framebuffer descriptor but the
  R19.M5 stub does NOT print to it (only to ConOut, which the firmware
  paints to the local display before ExitBootServices). A phone-camera
  photograph of the ThinkPad display captures the pre-EBS banner. This
  is the fallback if no USB serial is available.

Expected output on a successful path-through:

```
BdsDxe: loading Boot0001 "..." from ...
BdsDxe: starting Boot0001 "..." from ...
paideia boot: entry ok
```

The `paideia boot: entry ok` line is emitted by `efi_main` via
`ConOut->OutputString` in `src/boot/uefi_stub.pdx` (see the
`_hello_char16` slot at line 177 and its emit at line 280-285). This
is the R19.M5 acceptance witness.

After that line, one of the following happens (all correct at M5):

1. **UEFI exception handler catches a #UD / #GP / #PF** — the CPU
   jumped to `_kernel_main_uefi_pa` (LMA of `kernel_main_uefi`, e.g.
   `0x1167CB` — you can confirm the value via
   `nm build/kernel.elf | grep kernel_main_uefi` and subtracting
   `0xFFFF800000000000`), but no kernel code lives at that PA because
   OVMF/T14-firmware never loaded `kernel.elf` into memory. Execution
   stumbles forward through firmware data + hits an invalid opcode.
   RAX at the point of exception equals the resolved LMA — this is the
   witness that the M5 LMA substitution reached the stub.
2. **Silent triple-fault reboot** — same underlying cause; the T14
   firmware's `-no-reboot` equivalent (some vendors reboot on triple-
   fault, some hang). If the machine reboots to BIOS, this is the
   scenario.
3. **Hang without further output** — the CPU is spinning in an
   endless faulted state; T14 firmware's LID / power button will
   force a shutdown.

R20's ELF loader will load `/paideia/kernel.elf` from the ESP, install
higher-half paging, then jump — end-to-end boot to the R19.M4
`UEFI kernel_main entered` marker becomes possible then.

## 5. Smoke checklist (fill in and paste into r19-closure.md)

```
[ ] Image builds cleanly on operator's dev box.
[ ] dd to USB completes without error.
[ ] T14 G4 boot order sees USB HDD (F12 boot menu shows the entry).
[ ] BdsDxe log line appears (BIOS found + started the .efi).
[ ] paideia boot: entry ok appears (efi_main ran, ConOut worked).
[ ] Post-banner behaviour observed (one of #1 / #2 / #3 above; note
    which — informs R20 ELF-loader-first design).
[ ] BIOS setting notes: Secure Boot state, VMD state, TPM state
    (Enabled/Disabled — do NOT list secrets), boot order.
[ ] GOP mode chosen (if visible on-screen — resolution + format,
    e.g. 1920x1200 BGR8888).
[ ] TPM vendor tag (if TCG2 probe latched something — inspect
    `_efi_tcg2_this` post-panic via a debug-probe attach; skip if not
    available).
[ ] Map-key retry count from `_efi_memmap_retries` (see
    finalize_ebs_loop's `r15` in the panic dump).
```

## 6. Known SwTPM Environmental Issues (mirrors run-uefi-swtpm.sh SKIP)

On Ubuntu 24.04 + QEMU 8.2.2 + `OVMF_CODE_4M.fd` + swtpm 0.9, OVMF's
TCG2 driver hangs during the TPM 2.0 startup handshake and never
emits its `BdsDxe` banner. Symptoms:

- QEMU launches, allocates memory, opens the ESP + TPM socket FDs.
- The serial log stays 0 bytes after 60+ seconds.
- swtpm's own log is empty (no incoming commands).

Not diagnosed at R19.M5. Suspected causes:

1. OVMF was compiled without swtpm-compatible negotiation (some
   distro packages ship a minimal TCG2 driver that only speaks to
   real TPM hardware).
2. AppArmor / SELinux denies the QEMU→swtpm socket without an
   explicit local policy addition.
3. `tpm-tis` vs `tpm-crb` mismatch with the OVMF driver's expected
   interface.

Reproducer: `bash tools/run-uefi-swtpm.sh` — exits 77 (SKIP) with the
diagnostic pointing back to this doc.

Debug matrix to try when unblocking:

- Rebuild OVMF from `edk2` HEAD with `TPM_ENABLE=TRUE` and see if the
  handshake progresses.
- Add an AppArmor local override for `/tmp/paideia-swtpm.*/*.sock`
  and re-run.
- Switch `-device tpm-tis` to `-device tpm-crb` and vice versa (the
  fixture defaults to `tpm-tis`).
- Try Fedora / Arch host — different swtpm build revisions may
  interoperate cleanly.

## 7. Real-HW quirk log template

Append to `design/hardware/quirks.md` after the first-light attempt:

```
| Machine        | Firmware ver | Serial capture | Post-banner state | Quirks / setup notes |
|----------------|--------------|----------------|-------------------|----------------------|
| Thinkpad T14 G4 | R28ET…       | USB-serial via dock | #UD @ … RAX=… | Secure Boot off, VMD off, TPM 2.0 on, boot order USB HDD first |
```

## 8. Closure

When first-light produces `paideia boot: entry ok` on the T14 G4:

1. Photograph the screen (or capture serial) — file under
   `design/round-retrospectives/r19-closure-attachments/` as
   `t14-g4-first-light.<ext>`.
2. Fill in the smoke checklist (§5) and append the quirks row (§7).
3. Update `STATUS.md` with an `R19 (Paideia-native UEFI PE32+ boot) —
   CLOSED YYYY-MM-DD` section mirroring the R18 close structure.
4. Move to R20 (kernel ELF loader) with the M5 LMA-substitution stub
   as the launch point.
