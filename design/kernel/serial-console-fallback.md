# Serial-console fallback for headless HW

**Owner issue:** paideia-os #1003 (R28.M2 — Bootable distribution +
real-HW smoke).
**Status:** Documentation-only — the kernel already writes klog to
COM1 unconditionally (via `klog_ring_drain_to_uart`, landed pre-R28);
this doc formalizes the operator-side capture recipes so the
`tools/run-smoke-hw.sh` harness (#1002) and the T14 G4 first-boot
guide (#1004) have one canonical reference.

---

## 0. Scope

paideia-os targets bare metal from R28 forward. Every machine class
we ship on has different debug surfaces, but a 16550-compatible UART
at I/O port `0x3F8` (COM1) remains the widest common denominator: it
is what QEMU emulates by default, it is what modern server BMCs expose
over IPMI Serial-Over-LAN, and it is what USB-serial dongles plumbed
through docks or headers reach on laptops. This document is the
operator-side companion to the kernel-side UART writers — how to
attach, how to read, and how to interpret what comes across.

**Non-goals.** In-band bidirectional shell over UART (that lands as
R16.M4 RX substrate is exercised end-to-end by `boot_r16_uart_rx` and
`boot_r17_shell_*` smoke modes — see `design/kernel/r16-m4-666-uart-rx-e2e-smoke.md`
for the QEMU pipe path). This doc is strictly the read-side capture
recipe on the operator machine.

---

## 1. Kernel invariants

The kernel COM1 posture is fixed at boot and does not change through
the lifetime of the run:

| Register | Value | Set by | Rationale |
|----------|-------|--------|-----------|
| Baud     | 115200 | `src/kernel/boot/uart.pdx` step 3 (DLL=0x01, DLM=0x00) | Fastest standard 16550 rate before divisor-of-1 rounding error; matches every USB-serial adapter's advertised max cleanly. |
| Data bits | 8 | `uart.pdx` step 5 (LCR word length = 3) | Byte-transparent — no 7-bit ASCII assumption. |
| Parity   | none | `uart.pdx` step 5 (LCR parity = 0) | No wire-error detection needed; TCP has stronger integrity anyway. |
| Stop bits | 1 | `uart.pdx` step 5 (LCR stop = 0) | Fastest standard framing. |
| Flow ctl | none | Kernel never asserts RTS/DTR post-init | Simplifies wiring — 3-wire null-modem (TX/RX/GND) suffices. |
| IER      | 0x01 (ERBFI) | `src/kernel/core/uart/rx_init.pdx` (R16.M4 #595) | Receive-data-available interrupts only — no THRE / RLS / MSI. |

Anyone capturing serial from a paideia-os run must match `115200 8N1
no-flow-control` byte-for-byte. Framing errors show up as garbled bytes
in the log; the log itself never runs empty because the kernel emits
lots of TX during boot.

---

## 2. Which machines expose a UART

### 2.1 Laptops

| Machine | UART surface | Notes |
|---------|--------------|-------|
| Thinkpad T14 Gen 4 (MVP target) | **No chassis header.** USB-C dock DB-9 (Lenovo Universal USB-C Dock Gen 2). | Verified public docs; first-light confirms. See `design/hardware/quirks.md §2.5`. |
| Thinkpad T14 Gen 3 | Same as G4 — dock-only. | Same physical dock as G4. |
| Framework 13 (13th-gen Intel) | Internal M.2 header can be flashed to expose UART; also USB-C→UART adapter works. | Not on paideia critical path (post-MVP verification target). |
| Older Thinkpads (T430–T480) | Some dockables expose real DB-9 on the docking station. | Not paideia target class. |

### 2.2 Servers with BMC

Any 2010+ server with an OpenBMC / iDRAC / iLO / IPMI console:

- The BMC bridges physical COM1 to network via **Serial-Over-LAN**
  (IPMI 2.0 spec). The paideia kernel writes to COM1; the BMC forwards
  bytes to whoever connects via `ipmitool sol activate` or the vendor
  Java/HTML5 console.
- No physical cable needed on the operator side once the BMC is
  reachable — this is the recommended path for lab servers.
- BMC baud is fixed at BIOS/BMC-config-time; ensure it matches the
  kernel's 115200.

### 2.3 QEMU

Default: `-serial stdio` streams COM1 to the launching shell. Also
supported (all landed in `tools/run-smoke.sh`):

- `-serial file:/tmp/log` — write-only log capture (fingerprint verifier
  path).
- `-serial chardev:char0 -chardev pipe,id=char0,path=/tmp/pipe` —
  bidirectional named-pipe bridge (R16.M4 RX smoke — see
  `design/kernel/r16-m4-666-uart-rx-e2e-smoke.md`).

---

## 3. Operator-side capture tools

All three tools listed below read bytes from `/dev/ttyUSB0` (or the
adapter's enumeration path) and render them to a scrollable terminal.
Any of them works — pick whichever ships on your dev box. All examples
use the paideia-standard `115200 8N1 no-flow-control`.

### 3.1 `tio` (recommended)

Purpose-built for embedded serial; auto-reconnects if the adapter
re-enumerates; timestamps optional; log-to-file built in.

```
sudo apt install tio                 # Debian/Ubuntu
sudo dnf install tio                 # Fedora
brew install tio                     # macOS (Homebrew)

tio -b 115200 -d 8 -p none -s 1 -f none --log --log-file /tmp/paideia.log /dev/ttyUSB0
```

Ctrl-t q to quit. Ctrl-t ? for the full menu.

### 3.2 `picocom`

Older but universally available. No auto-reconnect but very small
footprint.

```
sudo apt install picocom

picocom -b 115200 -d 8 -p n -f n /dev/ttyUSB0
```

Ctrl-a Ctrl-x to quit.

### 3.3 `screen`

Multi-purpose; every UNIX box has it. Slightly awkward for pure serial
because Ctrl-a is the escape key.

```
screen /dev/ttyUSB0 115200,cs8,-parenb,-cstopb,-ixon,-ixoff
```

Ctrl-a k y to quit. `-ixon -ixoff` explicitly disables XON/XOFF flow
control (Ctrl-s / Ctrl-q would otherwise freeze the display).

### 3.4 `minicom`

Full curses UI; more knobs than most users need. Requires initial
config via `sudo minicom -s`. Not recommended for one-off captures.

### 3.5 Raw `cat` / `stty` (scripting path)

This is what `tools/run-smoke-hw.sh` uses. Not ergonomic for interactive
use, but the right primitive for automated fingerprint checking:

```
stty -F /dev/ttyUSB0 115200 cs8 -cstopb -parenb -crtscts -ixon -ixoff raw -echo
cat /dev/ttyUSB0 > /tmp/paideia.log     # in one terminal
# ... boot the target machine ...
# Ctrl-c the cat when done.
```

---

## 4. Attaching to the T14 G4

Full walkthrough lives in `design/hardware/t14-g4-first-boot.md §5`.
Short form:

1. Wire a USB-serial adapter (FT232 / CH340 / CP2102) via a DB-9 null-
   modem cable to the Lenovo Universal USB-C Dock Gen 2's rear DB-9.
2. Plug the operator side into your dev box; verify enumeration:
   ```
   ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null
   dmesg | tail -5
   lsusb | grep -iE 'ftdi|prolific|qinheng|silabs'
   ```
3. Add yourself to the `dialout` group (Debian/Ubuntu) or `uucp` (Arch)
   if `/dev/ttyUSB0` is not readable, then log out + in.
4. Start whichever capture tool from §3 you prefer BEFORE cold-powering
   the T14 G4, so the kernel's early UART bytes are not lost while the
   capture tool is initializing.

---

## 5. What you should see

The kernel emits a substantial pre-boot fingerprint that any capture
tool matched to §1 baud/framing will render legibly. A representative
early sequence (exact lines may drift with each round):

```
PaideiaOS R<N> boot
...
HPET ...
X2APIC ENABLED BSP
MCFG PRESENT ...
PCI DEV bus=... dev=... vendor=... device=...
PCI ENUM DONE devices=<N>
...
SMP BRINGUP START
CPU_ID_01_HELLO
CPU_ID_02_HELLO
CPU_ID_03_HELLO
SMP BRINGUP DONE
...
INIT START
SHELL START
$
```

Every one of those is a QEMU-fingerprint that a real HW run reproduces
byte-for-byte, modulo:

- `PCI DEV ...` lines: enumerate real hardware, not QEMU q35 defaults.
- SMP: the T14 G4 has more logical CPUs than QEMU `-smp 4`; the AP
  bring-up loop iterates over `_ap_apic_ids` as populated from MADT
  (R20.M2 #813), so `CPU_ID_XX_HELLO` line count matches the
  MADT-enumerated APs.

If the log fills with garbled bytes / framing errors, the tty
configuration diverges from §1. Re-check `stty -F /dev/ttyUSB0`:

```
stty -F /dev/ttyUSB0 -a | tr ';' '\n' | grep -E 'speed|cs8|parenb|cstopb|crtscts|ixon|ixoff'
```

The expected values are `speed 115200`, `-parenb -cstopb cs8 -crtscts
-ixon -ixoff`.

---

## 6. Troubleshooting

### Nothing appears on capture

- Wrong tty path — recheck enumeration (§4 step 2).
- TX/RX not crossed on null-modem cable (verify with a multimeter or
  a known-good loopback plug).
- Wrong baud (any of 9600, 38400, 57600 will still enumerate cleanly
  but produce zero legible output at kernel 115200 speed).
- T14 UEFI hung pre-`ExitBootServices` because Secure Boot is still
  enabled (unsigned image gets rejected silently on some Insyde
  revisions). See `design/hardware/t14-g4-first-boot.md §7`.

### Bytes appear but are garbled

- Baud mismatch (most common — verify §1 config on both sides).
- Adapter operating at 3.3V but wired to a 5V RS-232 level shifter
  (rare for lab USB-serial dongles; happens with barebones FTDI
  breakout boards).

### Line looks OK but log file stays 0 bytes

- Capture tool holds the FD but `cat` output redirection is buffered
  — pipe through `stdbuf -oL` (or use `tio --log`).
- The write side of the tty is being held by a stale `screen`/`tio`
  session — `sudo lsof /dev/ttyUSB0` to find the holder; kill and
  re-open.

### QEMU-side capture works but HW does not

- Kernel is not the same build. Rebuild `bash tools/build.sh` and
  re-flash the USB stick (`sudo dd if=build/mvp/paideia-mvp.img
  of=/dev/sdX bs=4M conv=fsync`).
- `-serial stdio` in QEMU forgives a lot of misconfiguration that a
  physical UART does not. Re-verify §1 against the physical adapter.

---

## 7. Cross-references

- `src/kernel/boot/uart.pdx` — TX-side init (steps 1–7 leaving IER=0x00,
  LCR=8N1, 115200 baud).
- `src/kernel/core/uart/rx_init.pdx` — R16.M4 #595 RX enablement (IER
  bit 0 ERBFI = 1).
- `design/kernel/r16-m4-001-uart-rx-init.md` — full R16.M4 RX design.
- `design/kernel/r16-m4-666-uart-rx-e2e-smoke.md` — QEMU chardev-pipe
  bidirectional smoke path.
- `tools/run-smoke.sh` — QEMU/TCG fingerprint verifier (`-serial
  file:LOG`).
- `tools/run-smoke-hw.sh` — real-HW fingerprint verifier (this doc's
  operator counterpart; #1002).
- `design/hardware/t14-g4-first-boot.md` — cold-power-to-shell recipe
  (#1004).
- `design/hardware/quirks.md §2.5` — T14 G4 UART chassis quirk row.

---

*Landed 2026-08-11 at R28.M2 (#1003).*
