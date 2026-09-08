// SPDX-License-Identifier: MIT
# T14 G4 Hardware-in-Loop Boot Capture

**Status:** Draft v0.1 (R111.M7-027, paideia-os #2379 — 2026-09-08).
**Scope:** Operator recipe for booting the `tools/mkimage.sh` USB image
on a physical Lenovo ThinkPad T14 Gen 4 (Intel Raptor Lake-U), capturing
serial output over a USB-TTL adapter, and asserting the boot chain
reaches `SHELL START` via
`tools/capture-t14-boot.sh` + `tests/expected-t14-fidelity.golden`.
Closes the loop that
[`design/roadmap/t14-bootable-usb-wave.md`](../roadmap/t14-bootable-usb-wave.md)
§0 named "one dd, one boot, one `$` prompt".

**Companion tools:**
- [`tools/capture-t14-boot.sh`](../../tools/capture-t14-boot.sh) —
  the capture + golden-compare harness this document drives.
- [`tools/mkimage.sh`](../../tools/mkimage.sh) — the USB image builder
  (R111.M7-025) that produces `build/mvp/T14G4.img`.
- [`tools/run-qemu-t14fidelity.sh`](../../tools/run-qemu-t14fidelity.sh) —
  the QEMU-side counterpart (same golden, same ordered-substring
  contract; if the QEMU smoke passes and this one fails, a real-HW
  cascade regressed).
- [`tests/expected-t14-fidelity.golden`](../../tests/expected-t14-fidelity.golden) —
  single-source fingerprint contract (6 lines).

**Authorities cited:**
- [`design/boot/esp-layout.md`](esp-layout.md) — canonical ESP contents
  the image builder stages.
- [`design/hardware/quirks.md`](../hardware/quirks.md) §UART row
  (line 95) — the T14 G4 chassis has **no debug UART header**, and
  Intel DCI over USB-C requires a proprietary debug dongle.  This
  recipe therefore uses the **USB-C dock DB-9** attachment path
  (§3.1) as the load-bearing default; DCI is documented as an
  alternate path (§3.3).
- [`design/kernel/serial-console-fallback.md`](../kernel/serial-console-fallback.md) —
  the 115200 8N1 line discipline both sides must agree on.
- [`design/hardware/t14-g4-first-boot.md`](../hardware/t14-g4-first-boot.md) —
  the R28.M2 BIOS-setup walkthrough (§7 mirrors its checklist).

---

## 0. Executive summary

The T14 G4 has no chassis serial header; the operator's dev box reads
kernel `klog` bytes via a USB-TTL adapter wired **through a supported
attachment path** (§3).  Given that wiring, `dd` the mkimage.sh output
onto a USB stick, cold-power the T14 with F12 held to force the boot
menu, pick the USB entry, and let
`tools/capture-t14-boot.sh` timestamp every serial line into
`build/mvp/T14G4-capture-<UTC>.log`.  The harness then runs the same
ordered-substring golden compare that
`tools/run-qemu-t14fidelity.sh` uses in QEMU.  A PASS on real HW
promotes the six-line contract from "boots under emulated firmware"
to "boots under Insyde BIOS + physical Raptor Point-U PCH".

The whole flow is scripted at the operator layer (no ad-hoc `screen`
or `tio` invocations) so the capture is reproducible across operators
and preserved as a real-HW fixture at
`build/mvp/T14G4-capture-<UTC>.log`.  Post-mortem re-scoring uses
`--replay` (§6) so a golden update does not require another physical
boot.

---

## 1. What the smoke asserts

The six lines in [`tests/expected-t14-fidelity.golden`](../../tests/expected-t14-fidelity.golden)
form the ordered-substring contract; each is the earliest wire-visible
fingerprint that proves a specific real-HW-path invariant survived
Insyde firmware + Raptor Point-U routing:

1. `UEFI EBS OK` — the UEFI stub finalizer's ExitBootServices success
   line.  Proves firmware handoff completed under real OVMF-shaped
   Insyde BIOS.
2. `UEFI BRIDGE OK` — `kernel_main_uefi` Phase 5, immediately before
   `call kernel_main_64`.  Proves the R111.M1-002 bridge fired.
3. `UEFI PML4 OK` — after the `mov cr3, rax` that swaps in the
   identity + higher-half PML4.  Proves the paging bootstrap survived
   the transition off firmware page tables.
4. `ACPI RSDP HANDOFF OK` — from `kernel_main_64`'s
   `phase1_emit_rsdp_fingerprint`.  Proves the R20 witness read the
   RSDP the firmware handoff carried (not the EBDA scan).
5. `FB CONSOLE OK` — from `gop_fb_console_init`.  Proves GOP LFB
   scanout attached to the physical eDP panel via the format the
   Iris Xe firmware handed the loader.
6. `SHELL START` — from `src/user/shell.pdx` L20.  Proves the entire
   UEFI → kernel → init → shell chain landed on real HW.

The golden is the **only** place these literals live; do not
duplicate them here or in the capture script.  Adding a line
(`XHCI PROBE OK`, `NVME ATTACH OK`, ...) tightens both the QEMU smoke
and this HW recipe simultaneously.

---

## 2. Prerequisites

**On the operator's dev box:**
- Linux with `bash`, `python3`, `stty`, `timeout`, `dd`, and the
  `mtools` used by `tools/mkimage.sh` (see its `check_deps`).
- Membership in the `dialout` group (Debian/Ubuntu) or `uucp` (Arch)
  so the USB-TTL adapter's tty is R/W-able without root.
- A USB stick, ≥256 MiB, that the operator is willing to overwrite
  in full.
- A USB-TTL adapter — FT232/FT232RL (FTDI), CP2102/CP2102N (Silicon
  Labs), or CH340/CH341 (WCH).  Any of the three enumerate on modern
  Linux as `/dev/ttyUSB0` out of the box (FTDI + CH340 via
  `ftdi_sio` / `ch341` in-tree drivers; CP2102 via `cp210x`).

**On the T14 G4:**
- BIOS revision reasonably current (§7 records the two SETUP toggles
  the recipe assumes).
- Secure Boot **disabled** for the capture window.  Paideia's native
  `.pdxsgn` sections do not yet chain to a shim-signed blob; that
  work lands at R32/R82 per
  [`design/security/pe-secure-boot-signing.md`](../security/pe-secure-boot-signing.md).
- Intel VMD Controller: leave at factory default (Enabled).  The
  R47 VMD driver substrate (per
  [`design/hardware/quirks.md`](../hardware/quirks.md) §VMD row)
  handles the NVMe-behind-VMD indirection; a pre-R47 fallback of
  Disabled also boots for operators who prefer the direct-endpoint
  path.

**On the attachment path:** exactly one of §3.1 / §3.2 / §3.3.

---

## 3. USB-TTL adapter wiring

### 3.1 Path A — USB-C dock DB-9 (recommended default)

The T14 G4 chassis exposes **no on-board debug UART header** (per
[`design/hardware/quirks.md`](../hardware/quirks.md) §UART row).
The load-bearing production path is a Lenovo ThinkPad USB-C dock
that carries an RS-232 DB-9 out (Lenovo ThinkPad Universal USB-C
Dock Gen 2 is the tested reference).  The operator plugs the dock
into any T14 USB-C port; the dock's DB-9 becomes the T14's
external console.  Wire the USB-TTL adapter to the dock DB-9 via a
null-modem 3-wire cross:

```
   OPERATOR SIDE (USB-TTL adapter)          T14 DOCK SIDE (DB-9 male)
   ------------------------------------      -------------------------
   TXD (data OUT)  ------------------->    RXD (pin 2, data IN)
   RXD (data IN)   <-------------------    TXD (pin 3, data OUT)
   GND             <---(common ground)---> GND (pin 5)

                    (do NOT connect Vcc)
```

The USB-TTL adapter provides its own logic-level 3.3 V; DB-9 side is
RS-232 (±3 to ±15 V, inverted logic).  If the USB-TTL adapter itself
is 3.3 V TTL (not RS-232), an inline RS-232-to-TTL level shifter
(MAX3232 or similar) is required — an FT232RL-based board is TTL
only; an FT232R-based *cabled* adapter (the ones with a molded DB-9
end) already includes the shifter.  Use the **shifter-included**
variant with dock Path A.

RTS/CTS/DTR/DSR/DCD are **not** wired; the paideia UART init leaves
hardware flow control off (per
[`design/kernel/serial-console-fallback.md`](../kernel/serial-console-fallback.md))
and 115200 8N1 has plenty of margin without it.

### 3.2 Path B — Second-machine null-modem (rarely useful)

Some operators have a second host with a real DB-9 (older desktop,
KVM appliance).  A straight null-modem DB-9 cable between that host
and the dock DB-9 works identically to Path A — set the second host
up as the tty owner and run this recipe there.  Noted for symmetry
with server BMC setups; no advantage over Path A for a laptop
target.

### 3.3 Path C — Intel DCI over USB-C (alternate; not tested here)

Intel Direct Connect Interface (DCI) tunnels serial over the Raptor
Point-U's USB-C debug port with a **Silicon Labs 8256 DCI dongle**
or equivalent Intel Silicon View Technology (SVT) probe.  This is
the load-bearing path for firmware-level (pre-EBS) debug when the
UART itself is not yet initialized; for the R111 golden — every
fingerprint fires **after** ExitBootServices — the UART-over-dock
Path A is sufficient and does not depend on Intel restricted-signed
tooling.  DCI paths are documented in Intel Debug Solution reference
material and are **out of scope for this recipe**; an operator with
DCI already working can substitute their DCI-provided tty for
`--device` and everything downstream is identical.

### 3.4 Enumeration sanity check

With the adapter plugged into the dev box:

```
dmesg | tail -20                          # ftdi_sio / cp210x / ch341 attach
ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null
lsusb                                     # see FTDI / QinHeng / CP210x row
```

Expected first tty is `/dev/ttyUSB0` (FTDI + CH340 assign in the
`ttyUSB` class; CP2102 does too).  If the operator has multiple USB
serial adapters plugged in, the T14 dock's adapter may appear at
`/dev/ttyUSB1` / `/dev/ttyUSB2`; pass `--device` accordingly.

---

## 4. Writing the USB stick

The image is `build/mvp/T14G4.img` after
`bash tools/mkimage.sh build --fw-dir=<path>` (or `--no-firmware` for
a firmware-less dev-loop image).

### 4.1 Identify the target block device (SAFETY-CRITICAL)

**Writing to the wrong device destroys the host system.**  Identify
the target with `lsblk` **before** and **after** inserting the USB
stick:

```
lsblk -o NAME,SIZE,TYPE,MODEL,MOUNTPOINTS
# insert USB stick, wait 2 s
lsblk -o NAME,SIZE,TYPE,MODEL,MOUNTPOINTS
```

The **new row** is the USB stick.  A typical result:

```
NAME    SIZE  TYPE MODEL              MOUNTPOINTS
sda     512G  disk INTEL SSDPEKKF512  ...        <-- host SSD, DO NOT TOUCH
sdb     32G   disk USB DISK 3.0                  <-- the USB stick
```

Confirm by `SIZE` (should match the stick's advertised capacity, not
the host's) and by `MODEL` (usually a vendor name — `SanDisk`,
`Kingston`, `Corsair`, ...).  **Never** trust `NAME` alone; USB
sticks can enumerate as `sda` on a laptop whose only internal disk
is an NVMe (`nvme0n1`), and any block-device write with the wrong
letter is unrecoverable.

### 4.2 Unmount every partition the stick auto-mounted

Modern desktop environments auto-mount every partition on plug-in.
Unmount **all** of them:

```
for p in /dev/sdX?; do sudo umount "$p" 2>/dev/null || true; done
```

Replace `sdX` with the target from §4.1.

### 4.3 Write

`bs=4M` is the customary optimum for USB SATA-bridged flash;
`conv=fsync` guarantees the last block reaches the medium before
`dd` returns; `status=progress` gives a byte counter.

```
sudo dd if=build/mvp/T14G4.img of=/dev/sdX bs=4M conv=fsync status=progress
sudo sync
```

### 4.4 Optional: verify

Catches truncation + bad blocks by rehashing the on-disk image:

```
IMG_BYTES=$(stat -c %s build/mvp/T14G4.img)
BLOCKS=$(( (IMG_BYTES + 4*1024*1024 - 1) / (4*1024*1024) ))
sudo dd if=/dev/sdX bs=4M count=${BLOCKS} 2>/dev/null | sha256sum
# compare against:
cat build/mvp/T14G4.img.sha256
```

If the two hashes match, the stick is a byte-perfect copy.

---

## 5. Boot sequence

### 5.1 Physical setup

1. USB stick from §4 inserted into any T14 G4 USB-A port (USB-C ports
   also work; USB-A is the more common convenience).
2. USB-C dock connected to a T14 G4 USB-C port with the USB-TTL
   adapter wired to the dock DB-9 per §3.1.
3. Operator's dev box has the USB-TTL adapter's other end plugged in
   and enumerated per §3.4.
4. T14 G4 fully powered off (Fn+Shift+S "shutdown" — not sleep,
   not hibernate; the S5 → S0 cold-power transition is the one this
   recipe exercises).

### 5.2 Start the capture harness first

The dev box must be listening **before** the T14 emits its first
UART byte (the UEFI stub prints early — the "waiting for serial
output" banner marks the point at which any subsequent wire byte is
captured).  From the paideia-os repo root:

```
bash tools/capture-t14-boot.sh
```

Or with an alternate device:

```
bash tools/capture-t14-boot.sh --device /dev/ttyUSB1 --timeout 180
```

The harness prints:

```
[capture-t14-boot] waiting for serial output on /dev/ttyUSB0
[capture-t14-boot]   baud=115200 timeout=120s
[capture-t14-boot]   log=build/mvp/T14G4-capture-<UTC>.log
[capture-t14-boot]   golden=tests/expected-t14-fidelity.golden

*** Insert the T14G4.img USB stick and cold-power (or reset) the T14 NOW.
    Tap F12 at the Lenovo splash, select the USB entry.
    ...
```

### 5.3 Trigger the boot

On the T14:

1. Press the power button.  Release once the Lenovo splash appears.
2. **Immediately tap F12 repeatedly** (once or twice per second) until
   the "Startup Device Menu" appears.  On the T14 G4 Insyde firmware
   the F12 poll window is short (~500 ms) — if the splash goes to
   Windows / no-boot-device, `Ctrl+Alt+Del` and try again.
3. Arrow to the USB entry — usually shown as `USB HDD: <vendor>
   <model>` (e.g. `USB HDD: SanDisk Ultra`) or `KingstonDataTraveler`.
   **Not** `USB CD` (mkimage.sh emits a raw HDD image, not an ISO).
4. `Enter`.  Firmware chains into `/EFI/BOOT/BOOTX64.EFI` on the ESP.
5. The dev box terminal starts filling with timestamped UART lines
   within 2–5 seconds:

   ```
   [2026-09-08T17:12:34.512Z] paideia boot: entry ok
   [2026-09-08T17:12:34.867Z] UEFI EBS OK
   [2026-09-08T17:12:34.919Z] UEFI BRIDGE OK
   ...
   ```

### 5.4 Wait for the harness verdict

The harness closes the capture window at `--timeout` seconds (default
120) and runs the golden compare.  Expected:

```
[capture-t14-boot] capture window closed; scoring against golden
[capture-t14-boot]   log:    build/mvp/T14G4-capture-<UTC>.log (N bytes)
[capture-t14-boot]   golden: tests/expected-t14-fidelity.golden

[capture-t14-boot] OK: all 6 golden fingerprints observed
  + UEFI EBS OK
  + UEFI BRIDGE OK
  + UEFI PML4 OK
  + ACPI RSDP HANDOFF OK
  + FB CONSOLE OK
  + SHELL START
```

FAIL summary shape (any missing line):

```
[capture-t14-boot] FAIL: 2/6 golden fingerprints missing:
  - FB CONSOLE OK
  - SHELL START
[capture-t14-boot]        4/6 matched:
  + UEFI EBS OK
  + UEFI BRIDGE OK
  + UEFI PML4 OK
  + ACPI RSDP HANDOFF OK
```

The tail of the log is dumped to stderr on FAIL so the operator can
inspect where the boot chain gave up.

---

## 6. Replaying an existing capture

Every successful capture leaves
`build/mvp/T14G4-capture-<UTC>.log` on disk (not gitignored — the
operator may commit useful captures into `tests/hw-fixtures/` if
they want the corpus tracked, but the default location is the
build tree).  After a golden update, re-score without booting the
T14:

```
bash tools/capture-t14-boot.sh --replay build/mvp/T14G4-capture-<UTC>.log
```

`--replay` bypasses the tty setup entirely; only `python3` is
required.  This is also the shape for post-mortem: an operator who
captured a FAIL and wants to try a tightened golden line iterates
against the same log without another cold-boot.

---

## 7. BIOS setup checklist

One-time SETUP on a fresh T14 G4 (F1 during POST to enter):

- **Security → Secure Boot → Secure Boot:** Disabled.  (Paideia's
  `.pdxsgn` chain is not yet shim-signed; R32/R82 milestone.)
- **Boot → Boot Mode:** UEFI Only.  (Legacy CSM boot does not
  execute `\EFI\BOOT\BOOTX64.EFI`.)
- **Boot → Boot Order:** USB HDD above `Windows Boot Manager` /
  internal NVMe (or use F12 per §5.3 without changing default).
- **Config → Storage → Intel VMD Controller:** leave Enabled (factory
  default; R47 VMD substrate handles the indirection).  Disabling is
  a supported fallback — see the VMD row in
  [`design/hardware/quirks.md`](../hardware/quirks.md).

`F10` to save + exit.

---

## 8. Troubleshooting

**Nothing appears on the wire within 120 s (harness exits 3).**
Most common: BIOS never reached the USB stick.  Verify §7 (Secure
Boot off, UEFI mode) and re-attempt F12.  Second most common: TX/RX
crossed wrong on the null-modem side — swap them and re-run.
Third: wrong tty device (adapter enumerated as `/dev/ttyUSB1`
because a previous session left `/dev/ttyUSB0` claimed by a
different device); pass `--device`.  Fourth: wrong baud (a
non-paideia UART init on the dev box left `stty` at 9600; the
harness re-configures 115200 8N1 on every run, so this only bites
if `stty` itself fails — the harness reports that explicitly).

**Firmware boots to Windows even with the USB inserted.**  Boot
order does not include USB HDD before Windows Boot Manager, and F12
was not hit in time.  Cold-power again; hold F12 depressed from the
instant the Lenovo splash appears until the menu comes up.  If the
Lenovo splash is suppressed (some operators disable it), the F12
window is even shorter — set boot order in SETUP per §7 instead.

**`UEFI EBS OK` appears but `UEFI BRIDGE OK` does not.**  The
R111.M1-002 kernel_main_uefi bridge landed but has regressed.  This
is a paideia bug, not a wiring or BIOS issue; dump the log tail
(harness does this automatically on FAIL) and file it against the
current wave.

**`SHELL START` never appears; everything else does.**  Init
successfully mounted the rootfs but shell fork/exec dropped a
signal, or the rootfs `/bin/sh` binary is stale (image was built
against a shell that no longer boots).  Re-run
`bash tools/mkimage.sh build --fw-dir=<path>` on the dev box, re-dd
the stick, retry.

**FB CONSOLE OK missing.**  GOP LFB attach failed — Iris Xe GOP
handoff mismatch (per the GOP-Pixel-Format row in
[`design/hardware/quirks.md`](../hardware/quirks.md)).  Photograph the
T14 eDP panel; the panic path
([`design/testing/panic-fb-photograph-recovery.md`](../testing/panic-fb-photograph-recovery.md))
still emits its bold-red banner + ring dump on-screen, and the photo
carries the useful bytes serial did not.

**Adapter unplugged mid-capture / log ends `(no-EOL)`.**  The
timestamper flushes any partial trailing bytes on EOF with a
`(no-EOL)` suffix so nothing is silently dropped.  A `(no-EOL)`
line at the tail of the log means the wire went dark before its LF
arrived — usually a mid-capture adapter disconnect, not a boot bug.
Re-seat the USB-TTL adapter and re-run.

---

## 9. What this recipe does NOT assert

- Any driver bring-up beyond `FB CONSOLE OK` — NVMe attach, xHCI
  attach, i219-LM link — is out of scope; those are covered by
  [`tools/run-smoke-hw.sh`](../../tools/run-smoke-hw.sh) modes
  (`net`, `usb`) and by the R47 / R51 hardware smokes named in
  [`design/hardware/quirks.md`](../hardware/quirks.md).  This
  recipe answers the wave-0 termination question — "does the T14
  boot to `$` under real BIOS?" — and that alone.
- The wall-clock latency of each fingerprint.  The timestamp column
  of the capture log lets a reader compute deltas after the fact
  (`awk -F']' '{print $1}' <log>` extracts them), but the golden is
  order-only; a boot that takes 3 s and one that takes 90 s both
  PASS if all six lines land.
- Signature verification.  R111 ships with an all-zero manifest
  signature (`fw_manifest_verify_signature` dev-bypass, per
  [`design/boot/esp-layout.md`](esp-layout.md) §2.1) and the boot
  chain accepts.  R32/R82 lands real Ed25519 + ML-DSA-65 and the
  golden gains matching fingerprint lines at that time.

---

## 10. Follow-up landings

| Milestone   | Consumer                                        | Status |
| ----------- | ----------------------------------------------- | ------ |
| R111.M7-025 | `tools/mkimage.sh`                              | LANDED 2026-09-07 (#2377) |
| R111.M7-026 | `tools/run-qemu-t14fidelity.sh` + golden        | LANDED 2026-09-07 (#2378) |
| R111.M7-027 | `tools/capture-t14-boot.sh` + this recipe       | **THIS LANDING (#2379)**  |
| R111.M7-028 | First-light PASS captured, log committed to     | Deferred: physical T14    |
|             | `tests/hw-fixtures/T14G4-capture-first.log`     | access required           |
| R111.M7-029 | Retrospective + `r111-closed` tag               | Deferred (per wave close) |
| R32 / R82   | Golden grows signature-verify fingerprints      | Deferred                  |
