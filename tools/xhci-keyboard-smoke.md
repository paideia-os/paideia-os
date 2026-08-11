# T14 G4 xHCI keyboard-input hardware smoke

**Owner issue:** #969 (R26.M6-005, `gated:hardware`).
**Prereqs to run:** T14 G4 physical unit + a USB-attached keyboard
(chassis keyboard suffices — it enumerates as an HID device behind
the internal xHCI root complex).
**Status:** Harness landable at R26 close; **live run gated on
first-boot on the T14 G4 with the R27 driver-attach wire.**

---

## 0. Scope

This document is the operator-run recipe that promotes the xHCI
substrate landed across R26 (M1–M6) from a QEMU-TCG structural
witness to a real-hardware acceptance witness on the T14 G4.

The wire this smoke exercises:

- **R22** PCIe enumeration finds a class `0C/03 prog-if 30` device
  under the root bus.
- **R26.M1** `xhci_probe` records the controller in `_xhci_devices`
  and emits `XHCI PROBE N=<count>`.
- **R26.M1** `xhci_bios_handoff` transfers ownership from BIOS to OS
  via the USBLEGSUP capability; `xhci_reset` clears USBSTS.CNR.
- **R26.M2** command ring + event ring + MSI-X are provisioned.
- **R26.M3** port reset lands the connected device in Default state
  and reports the negotiated speed.
- **R26.M3–M4** `xhci_enable_slot` + `xhci_input_context_init` +
  `xhci_address_device` bind the slot; `xhci_configure_ep_hid`
  wires EP1 IN Interrupt endpoint for the keyboard.
- **R26.M5** `xhci_get_descriptor(Device)` + `..._config` +
  `xhci_hid_set_boot_protocol(0)` cross the class-specific control
  transfer surface; the keyboard is now driven in Boot Protocol
  and posts 8-byte reports on EP1 IN.
- **R26.M6** `hid_process_report` decodes each 8-byte report and
  bridges per-keypress ASCII bytes into the TTY cooked-mode layer
  via `hid_bridge_to_tty` -> `tty_process_input` -> `_tty_line_buf`.

This smoke is **not** an end-to-end regression — it is a one-off
promotion pass to move the T14 G4 §2.4 USB row in
`design/hardware/quirks.md` from `PROVISIONAL → CONFIRMED`.

---

## 1. Prerequisites

### 1.1 Hardware

- T14 G4 physical unit (Intel Raptor Lake — the MVP target).
- USB keyboard: chassis keyboard is fine; the internal keyboard on
  the T14 G4 sits behind the same xHCI root hub as the external
  USB-A / USB-C ports.
- Serial-over-USB or ethernet-tethered GDB stub for remote
  observation. The T14 G4 has no debug UART on chassis — see
  `design/hardware/quirks.md §2.5` for the framebuffer-fallback
  discipline.

### 1.2 Firmware / BIOS toggles

- **UEFI boot** (Legacy CSM off — the R19 UEFI stub is the entry).
- **Secure Boot: Disabled** (the R19 UEFI stub is unsigned at MVP).
- **Intel VMD Controller: Disabled** (required for NVMe; leave off
  even for a keyboard-only smoke — R22 PCI enumerator uses the same
  code path and the VMD indirection breaks class-code matching for
  every downstream device, not just NVMe).
- No BIOS-side "Fast Boot"; xHCI needs the port-power stabilisation
  window BIOS provides in the normal boot path.

### 1.3 Software

- `build/kernel.elf` from `bash tools/build.sh` (must pass all 15
  gates).
- UEFI boot image built via `bash tools/build-uefi-image.sh`.
- GDB with `gdb-multiarch` (or a native x86_64 GDB) for the attach
  step.

---

## 2. Operator recipe

### 2.1 Boot

1. Copy the UEFI image to a USB thumb drive per
   `tools/build-uefi-image.sh` §Manual install.
2. Insert into the T14 G4; F12 -> UEFI USB Boot.
3. Observe the R19+ boot fingerprints on the framebuffer:
   `UEFI kernel_main entered` -> `PDMP W1 OK ...` -> `PCI PROBE ...`
   -> `XHCI PROBE N=<count>`. The `<count>` should be **>= 1** for
   the T14 G4 (the internal xHCI root complex).

If `XHCI PROBE N=0` appears: the R22 PCI enumerator did not find
the xHCI class-code triple. Common cause: Legacy CSM was left on and
UEFI booted the CSM path. Return to §1.2.

### 2.2 Attach GDB

```bash
# From the developer laptop:
gdb-multiarch build/kernel.elf
(gdb) target remote /dev/ttyUSB0    # or tcp:host:port for ether
(gdb) break xhci_keyboard_smoke_witness
(gdb) continue
```

Alternatively (once the R27 driver-attach wire lands and the
handler-chain fires on the first hotplug edge), the witness is
callable directly:

```
(gdb) call xhci_keyboard_smoke_witness()
```

### 2.3 Type at shell prompt

After the shell prompt appears (`R17 SHELL READY` fingerprint), type:

```
echo hello<Enter>
```

Expected side-effects on the serial log (or the framebuffer via
`fb_console_puts`):

- One `HID KEY <char>\n` fingerprint per keypress (`HID KEY e`,
  `HID KEY c`, `HID KEY h`, `HID KEY o`, `HID KEY  `,
  `HID KEY h`, `HID KEY e`, `HID KEY l`, `HID KEY l`, `HID KEY o`,
  `HID KEY \n`) — 11 lines total.
- The shell processes the composed line as normal: `hello\n` echoes
  back through the R14 shell built-in.

The `HID KEY \n` (LF byte after Enter) is expected — the newline
usage code 0x28 maps to ASCII 0x0A which the TTY layer already
canonicalises through `tty_process_input`.

### 2.4 Witness invocation (structural check)

Even without the R27 wire, the witness can be called from GDB to
prove the R26.M6 substrate composes end-to-end:

```
(gdb) call xhci_keyboard_smoke_witness()
$1 = 0
```

Expected fingerprints:

```
XHCI KBD SMOKE BEGIN
XHCI KBD SMOKE TRANSLATE OK
HID KEY a
XHCI KBD SMOKE REPORT OK
XHCI KBD SMOKE END
```

Return value 0 = pass. Return value 1 = TRANSLATE FAIL (the R26.M6
keymap or `hid_translate` is broken).

---

## 3. Quirks-database promotion pass

On successful live capture, promote the following row(s) in
`design/hardware/quirks.md`:

- **§2.4 USB row** (`2x TB4 + 2x USB-A + 1x USB-C 3.2; all under
  xHCI`): `PROVISIONAL → CONFIRMED` with the round observed = R26.M6
  and source = "first-boot on unit S/N XXXX (2026-08-11)".
- **New row (§2.4):** "T14 G4 USB keyboard — Boot Protocol works
  after xHCI enable" — anchor at PROVISIONAL until the first-light
  capture flips it to CONFIRMED.

Any deviation observed during the live pass (e.g. Boot Protocol
descriptor rejected, EP1 IN report length != 8, unexpected report
cadence) gets a new row in the quirks database with the observed
behaviour, the R26.M6 handling gap, and a CONFIRMED status.

---

## 4. Wire-up posture

At R26.M6 close, `xhci_keyboard_smoke_witness` is a callable ELF
symbol that is **not** wired into `kernel_main_uefi` — an operator
with GDB has to `call xhci_keyboard_smoke_witness()` manually.

The R27 driver-attach path (planned at
`design/roadmap/r18-plus-bare-metal.md §R27`) will:

1. Add an IRQ walker over the event ring that dispatches Port Status
   Change Events (TRB Type 34) to `xhci_hotplug_handler_event`.
2. Extend the hotplug-attach chain to full slot enable + input-ctx
   init + address-device + configure-ep-hid, mediated by a per-port
   slot ledger.
3. Add a second IRQ path for Transfer Events (TRB Type 32) that
   dispatches to `hid_process_report(report_pa)` on each EP1 IN
   completion.
4. Wire `xhci_keyboard_smoke_witness` into `kernel_main_uefi` behind
   `Features.XHCI_KEYBOARD_SMOKE_AT_BOOT = 1` (default 0 to keep
   `-kernel` boots side-effect-free).

Until (4) lands, the smoke stays operator-run.

---

## 5. Related documents

- `design/roadmap/r18-plus-bare-metal.md §R26` — round scope.
- `design/round-retrospectives/r26-closure.md` — the R26 retro that
  cross-references this file.
- `design/hardware/quirks.md §2.4` — USB row target for promotion.
- `tools/nvme-hw-smoke.md` — sibling operator recipe for the R24
  NVMe smoke; same shape.
