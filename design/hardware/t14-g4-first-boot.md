# T14 G4 first-full-MVP-boot recipe

**Owner issue:** paideia-os #1004 (R28.M2 — Bootable distribution +
real-HW smoke).
**Prereqs to run:** T14 G4 physical unit + one **spare** USB stick
(≥ 128 MiB — the MVP image is ~64 MiB, headroom for post-write growth)
+ USB-serial adapter + DB-9 null-modem cable + Lenovo Universal USB-C
Dock Gen 2 (or equivalent DB-9 exposure).
**Status:** Landable pre-first-light — the artifact
(`tools/build-image.sh` output) and every dependency in this recipe is
present as of R28.M1 close. Live-boot confirmation is a separate
operator step whose outcome seeds the R28.M2 fingerprints in
`tests/hw/`.

---

## 0. Scope

Step-by-step recipe from cold-powered T14 G4 to a `$` shell prompt on
attached serial console, running the R28 MVP image
(`build/mvp/paideia-mvp.img`). Complements:

- `design/roadmap/r19-t14-g4-boot-guide.md` — R19 UEFI-stub first-light
  (predecessor artifact, no kernel loaded).
- `tools/nvme-hw-smoke.md` — NVMe HW witness (R24.M6 #908; GDB-driven).
- `tools/xhci-keyboard-smoke.md` — xHCI + HID keyboard witness.
- `design/kernel/serial-console-fallback.md` — the serial capture
  recipes this doc's §5 pulls from (#1003).
- `tools/run-smoke-hw.sh` — the fingerprint verifier this doc's §6
  hands off to (#1002).
- `tools/hw-smoke-r51-nvme-t14g4.md` — R51.M8-006 (#1680) unified BDEV
  HW witness; extends this doc's §6.1 with the mount+write+flush+
  unmount+remount+read sequence against the internal NVMe device.

**Non-goals.** Booting from internal NVMe (deferred to R25+ when the
driver-attach path wires probe→identify→io_queues→mount into
`kernel_main_uefi`). Wi-Fi (deferred permanently for MVP window per
`design/roadmap/r18-plus-bare-metal.md §4`). Framebuffer console
rendering (R23 substrate; separate real-HW cross-check via
`design/round-retrospectives/r23-closure.md`).

---

## 1. Build the image

```
git clone --recursive git@github.com:paideia-os/paideia-os.git
cd paideia-os
(cd tools/paideia-as && cargo build --release -p paideia-as)
bash tools/build.sh                     # kernel.elf     (~15 gates)
bash tools/build-uefi-stub.sh           # uefi_stub.efi
bash tools/build-user.sh                # shell/init/true/child_hello
bash tools/build-image.sh               # ONE command, all four phases
```

Or in one shot:

```
bash tools/build-image.sh               # runs all four component builds
```

Output: `build/mvp/paideia-mvp.img` — partitionless FAT32 ESP,
`~67108864` bytes at R28.M1, contains:

- `/EFI/BOOT/BOOTX64.EFI` — firmware-default fallback path.
- `/EFI/PAIDEIA/PAIDEIA.EFI` — branded canonical path (identical bytes
  as `BOOTX64.EFI`; the ESP has both so paranoid firmwares find one
  path if not the other).
- `/paideia/kernel.elf` — kernel image the stub loads.
- `/paideia/rootfs.pdxfs` — PdxFS-lite root filesystem blob with
  `/etc/hello`, `/bin/sh`, and the seeded init tree.

Sanity check:

```
file build/mvp/paideia-mvp.img          # DOS/MBR boot sector, FAT (32 bit), ...
ls -la build/mvp/paideia-mvp.img        # ~64 MiB
```

---

## 2. Write to USB

**Warning.** `dd` to the wrong device destroys data irreversibly.
Verify twice.

```
lsblk -o NAME,SIZE,TYPE,MODEL,TRAN | grep -i usb
```

Assume the USB stick enumerates as `/dev/sdX` (X = a, b, c, …). It
must not be currently mounted; unmount any auto-mounted partitions:

```
mount | grep /dev/sdX                   # if anything appears, umount it
```

Write the image raw:

```
sudo dd if=build/mvp/paideia-mvp.img of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

Post-write verification (optional but recommended):

```
sudo mount /dev/sdX /mnt/paideia
ls -R /mnt/paideia/EFI /mnt/paideia/paideia
sudo umount /mnt/paideia
```

Expected paths present:

```
/mnt/paideia/EFI/BOOT/BOOTX64.EFI
/mnt/paideia/EFI/PAIDEIA/PAIDEIA.EFI
/mnt/paideia/paideia/kernel.elf
/mnt/paideia/paideia/rootfs.pdxfs
```

---

## 3. T14 G4 BIOS setup

Enter BIOS setup by tapping **F1** at power-on (with the ThinkPad logo
on screen). Configure:

| Menu | Setting | Value | Reason |
|------|---------|-------|--------|
| Security | Secure Boot | **Disabled** | R28.M1 ships **unsigned** `PAIDEIA.EFI` (per `design/security/pe-secure-boot-signing.md` — signing lands at R32+ ML-DSA-65 substrate + #1001). |
| Security | TPM 2.0 | Enabled (leave default) | R19.M3 TCG2 probe (`src/boot/uefi_tcg2.pdx`) will silently no-op if disabled and `HashLogExtendEvent` if present — enabled is the more interesting path. |
| Config → Storage | **Intel VMD Controller** | **Disabled** | Per `design/hardware/quirks.md §2.4` — VMD hides NVMe behind a proprietary indirection paideia has no drivers for. Even booting from USB, some T14 BIOS revisions couple VMD activation with USB EHCI quirks that manifest as "boot device not found". |
| Startup | CSM Support | Disabled | paideia-os is UEFI-only (Pillar 5). |
| Startup | UEFI/Legacy Boot | **UEFI Only** | Legacy CSM adds boot-order ambiguity that has bitten first-light attempts on ThinkPads before. |
| Startup | Boot Priority Order | **USB HDD first** | Otherwise the T14 falls through to internal SSD (which has whatever OS was previously installed). |

Save and exit (**F10**), then let the machine reboot to BIOS POST.

---

## 4. Wire up serial capture

**Before** power-cycling to boot from USB. If the operator waits until
`4. Boot from USB` is complete before attaching serial, the entire
kernel banner and early-boot trace is lost.

1. Attach USB-serial adapter (FT232 / CH340 / CP2102) to the operator
   dev box.
2. Connect adapter → DB-9 null-modem cable → Lenovo Universal USB-C
   Dock Gen 2's rear DB-9.
3. Connect the T14 G4 to the dock via USB-C (not the USB-A ports;
   power + display + dock features route via USB-C).
4. Verify adapter enumeration on the dev box:
   ```
   ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null
   dmesg | tail -5
   lsusb | grep -iE 'ftdi|prolific|qinheng|silabs'
   ```
5. Start the capture tool of your choice (per
   `design/kernel/serial-console-fallback.md §3` — `tio`, `picocom`,
   `screen`, or the raw `stty`+`cat` pair). Recommended:
   ```
   tio -b 115200 -d 8 -p none -s 1 -f none /dev/ttyUSB0
   ```

The tool should render nothing yet (T14 not booting). Do not close it.

---

## 5. Boot from USB

1. Insert the paideia USB stick into any T14 G4 USB-A port.
2. Cold-power the T14 G4 (fully off, then press power).
3. When the ThinkPad logo appears, tap **F12** (Startup Boot Menu).
   Select the USB HDD entry matching the paideia stick.
4. Firmware handoff → `\EFI\BOOT\BOOTX64.EFI` → `PAIDEIA.EFI` stub →
   loads `/paideia/kernel.elf` → `kernel_main_uefi` starts writing to
   COM1.

If BIOS boot-order was correctly set in §3, F12 is unnecessary; the
USB stick boots by default. F12 is the paranoia path for one-off
overrides.

---

## 6. Expected serial output

Serial capture should render the following in order (representative,
not exhaustive — round-to-round the exact line set drifts as new
substrate lands; the anchor markers below are the ones this doc
promises):

```
paideia boot: entry ok               <-- R19 stub's efi_main
PaideiaOS R<N> boot                  <-- boot/banner.pdx (kernel entry)
... HPET, X2APIC, MCFG, PCI enum, SMP bringup, ...
SMP BRINGUP DONE
... e1000e/i219 probe, ARP, ...
INIT START                           <-- src/user/init.pdx
SHELL START                          <-- src/user/shell.pdx
$                                    <-- shell prompt (interactive)
```

The `$ ` prompt is the R28.M2 acceptance witness: kernel booted +
INIT ran + fork'd shell reached its read loop.

### 6.1 R51.M8-006 extension: unified BDEV path on internal NVMe

**Status: UNSEEDED, `gated:hardware`** (#1680, closing R51.M8). Once
the `$ ` prompt is reached, the R51 closing witness drives one more
step against the T14 G4's internal NVMe device before the boot
recipe's acceptance surface is considered complete for R51:

```
$ ... mount+write+flush+unmount+remount+read sequence (see below) ...
T14 G4 HW BDEV OK
```

This is the R51.M8-003 (#1677) sequence — mount, snapshot digest,
write 32 journaled records with the six-step FLUSH barrier order,
clean unmount, remount, WAL replay, snapshot digest compare — run
interactively by the operator at the shell prompt rather than emitted
automatically by the boot log. See `tools/hw-smoke-r51-nvme-t14g4.md`
for the full procedure, the fingerprint fields (superblock digest,
itable digest, WAL-head LBA, `mount_gen`, `blkdev_row_family`), and the
promotion checklist. No expected values are recorded here or there
until a real capture seeds them — recording an invented value would be
worse than recording none.

---

## 7. Interactive smoke sanity checks

At the `$ ` prompt (type each command + Enter):

### 7.1 `cat /etc/hello`

Expected:

```
$ cat /etc/hello
hello from paideia
$
```

Proves PdxFS-lite mount succeeded, `/etc/hello` file exists in the
rootfs blob (seeded by `tools/mkfs-pdxfs-lite-seed.sh`), and userspace
`cat` (or shell builtin equivalent) can read the file through the
`sys_open` / `sys_read` path.

### 7.2 `pwd` + `cd /tmp` + `pwd`

Proves the tmpfs mount at `/tmp` (R25 substrate) works and the shell's
`cd` builtin updates working-dir state.

### 7.3 `true` (via `/bin/true`)

Expected:

```
$ true
TRUE OK
$
```

Proves the shell's fork+execve+wait4 chain works end-to-end on real
hardware (matches `boot_r17_shell_child_process` smoke fingerprint).

### 7.4 `exit`

Expected (final):

```
$ exit
... (init reap trace) ...
```

Proves the shell → sys_exit → init wait4 → clean-shutdown chain
(matches `boot_r17_shell_shutdown` smoke fingerprint).

Between step 7.1 and 7.4, the operator may also run:

- Additional `pwd`/`cd`/`help`/multi-arg-`echo` commands per
  `boot_r17_shell_multi_command` (helpful to cross-check the
  post-#1016 shell arg tokenizer on real hardware, though the QEMU
  smoke exercises identical binary bytes).

---

## 8. Fingerprint verification

After the operator sees the interactive chain end-to-end, run the
harness fingerprint check against the captured log (assumes the
capture tool wrote to a log file — `tio --log` or `cat > log`):

```
PAIDEIA_HW_SMOKE=1 PAIDEIA_HW_SMOKE_LOG=/tmp/paideia.log \
    tools/run-smoke-hw.sh boot
```

For a single-power-on end-to-end pass through boot + pdxfs + net
verification:

```
PAIDEIA_HW_SMOKE=1 tools/run-smoke-hw.sh all
```

Fingerprint files under `tests/hw/expected-hw-{boot,pdxfs,net}.txt`
are seeded from the first successful boot log — until they exist,
`run-smoke-hw.sh` soft-skips (exit 77) rather than failing the run.

---

## 9. Troubleshooting

### 9.1 Machine hangs at Lenovo splash / UEFI init

- **Secure Boot still enabled.** Some Insyde revisions reject unsigned
  images silently. Re-check §3 BIOS Setup → Security → Secure Boot =
  Disabled. Persist across power-cycle (F10 to save).
- **VMD Controller still Enabled.** Same silent-hang symptom on some
  BIOS revisions when USB EHCI enumeration collides with VMD. Set to
  Disabled per §3.
- **CSM enabled with UEFI mode.** BIOS may attempt to route the boot
  through the CSM path if `UEFI/Legacy Boot = Both`; set to
  `UEFI Only`.

### 9.2 BdsDxe finds USB but nothing after

- USB stick was written but `sync` was not run — some bytes still in
  page cache, image on stick truncated. `sudo sync` after `dd` and
  reinsert.
- Wrong bs — very old kernels have quirks with `bs=4M`; if in doubt,
  `bs=1M` is portable.

### 9.3 Boot reaches kernel banner but no `SHELL START`

- Rootfs blob missing or malformed. Verify §2 post-write mount check
  shows `/paideia/rootfs.pdxfs` present.
- PdxFS-lite mount failing at boot — check for `PDXFS MOUNT FAIL` in
  serial log; correlate with `design/filesystem/pdxfs-lite-perf.md`
  fault paths.
- Init's fork/execve of `/bin/sh` failed — check for `INIT FORK SH
  FAIL` in serial log; correlate with `src/user/init.pdx` around the
  fork call site.

### 9.4 Serial log is blank

Per `design/kernel/serial-console-fallback.md §6`:

- Wrong tty device path (adapter enumerated as `/dev/ttyACM0` instead
  of `/dev/ttyUSB0` on some CDC-ACM converters — `PAIDEIA_HW_SERIAL_DEV`
  overrides).
- Baud mismatch (any of 9600/38400/57600 will still enumerate cleanly
  but produce zero legible output at kernel 115200 speed).
- TX/RX not crossed on null-modem cable (verify with loopback plug or
  multimeter).
- Missing dialout/uucp group membership on operator machine.

### 9.5 Serial log fills with garbled bytes

- Baud mismatch (see §9.4 above).
- Adapter is 3.3V TTL wired to a 5V RS-232 signal without a level
  shifter (rare — happens with bare FTDI breakout boards, not with
  proper USB-serial dongles).
- Kernel COM1 init drifted (unlikely if `bash tools/build.sh` completed
  clean — the UART init is part of the 15-gate verification matrix).

### 9.6 Shell prompt appears but keyboard input does not echo

- xHCI + HID Boot Keyboard driver did not attach — see
  `tools/xhci-keyboard-smoke.md` for the diagnostic recipe.
- On T14 G4 the internal keyboard is an I²C-HID device that requires
  ACPICA (R34) — until then, USB keyboards attached via the dock work
  but the built-in laptop keyboard is dark. Serial-console-only
  operation is the R28.M2 posture; a USB keyboard is a nice-to-have
  after INIT reaps.

---

## 10. Post-boot quirks-db promotion

After a clean run per §5–7:

1. **`design/hardware/quirks.md §2.4` VMD row** — promote status
   `PROVISIONAL → CONFIRMED` if VMD-off behavior matched the recipe.
   Set `Round observed = R28.M2`. Cite git SHA at which this boot
   ran + T14 G4 serial number + BIOS revision (from BIOS Setup →
   Main → System → BIOS version).
2. **`design/hardware/quirks.md §2.5` UART row** — promote from
   `PROVISIONAL → CONFIRMED` once serial capture via dock DB-9 is
   validated.
3. **New quirks discovered.** Any surprise during §5–7 gets a fresh
   row under the appropriate `§2.x` subsection following the schema
   in `design/hardware/quirks.md §1`.
4. **Fingerprint seed.** Extract deterministic lines from the boot log
   and populate:
   ```
   tests/hw/expected-hw-boot.txt
   tests/hw/expected-hw-pdxfs.txt
   tests/hw/expected-hw-net.txt
   ```
   Same in-order contains-check semantics as `tools/run-smoke.sh`
   fingerprint files (one grep-substring per line; blank lines and
   `#`-comments allowed).

---

## 11. Cross-references

- `tools/build-image.sh` — R28.M1 #998, MVP image assembly.
- `tools/mkfs-pdxfs-lite-seed.sh` — R28.M1 #1000, rootfs blob with
  `/etc/hello`.
- `tools/build-uefi-image.sh` — R28.M1 #999, ESP layout (branded
  `/EFI/PAIDEIA/` + fallback `/EFI/BOOT/`).
- `tools/build-uefi-stub.sh` — R19 UEFI PE32+ stub.
- `tools/run-smoke-hw.sh` — R28.M2 #1002, fingerprint verifier.
- `design/kernel/serial-console-fallback.md` — R28.M2 #1003, capture
  recipes.
- `design/roadmap/r19-t14-g4-boot-guide.md` — R19 first-light
  (predecessor recipe).
- `design/hardware/quirks.md §2` — T14 G4 quirks rows.
- `design/security/pe-secure-boot-signing.md` — why R28.M1 ships
  unsigned + deferred #1001 signing.
- `tools/hw-smoke-r51-nvme-t14g4.md` — R51.M8-006 #1680, §6.1's
  unified BDEV HW witness (closes R51.M8).

---

*Landed 2026-08-11 at R28.M2 (#1004). Live-boot confirmation pending
physical hardware access.*
