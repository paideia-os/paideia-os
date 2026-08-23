#!/usr/bin/env bash
# tools/run-smoke-hw.sh — R28.M2 #1002
#
# Real-hardware smoke harness for the paideia-mvp.img MVP boot
# artifact (see tools/build-image.sh, R28.M1 #998). Complements
# tools/run-smoke.sh (QEMU/TCG fingerprint verifier) with a
# side-channel serial-log fingerprint check the operator runs against
# a paideia kernel booting on the T14 G4 (primary MVP target — see
# design/hardware/t14-g4-first-boot.md).
#
# ---------------------------------------------------------------------
# Role and division of labor
# ---------------------------------------------------------------------
#
# This script does NOT drive the T14 G4 boot: firmware handoff +
# real-mode Startup + UEFI + kernel come up under the physical machine's
# clock and are not scriptable from the operator's dev box. What this
# script DOES:
#
#   1. Refuses to run unless PAIDEIA_HW_SMOKE=1 is exported by the
#      operator (prevents accidental invocation from pre-push / CI-
#      like contexts).
#   2. Locates a USB-serial adapter on the operator's dev box
#      (/dev/ttyUSB0 by default; override with PAIDEIA_HW_SERIAL_DEV).
#   3. Configures the tty for 115200 8N1 (matches R16.M4 kernel UART
#      init — see design/kernel/r16-m4-001-uart-rx-init.md and
#      design/kernel/serial-console-fallback.md).
#   4. Captures serial output for a bounded window
#      (PAIDEIA_HW_SMOKE_TIMEOUT seconds; default per-mode).
#   5. Runs the same in-order contains-check that run-smoke.sh does,
#      against the mode's fingerprint file under tests/hw/.
#
# The operator's job is orthogonal: cold-power the T14 G4 (or hit the
# reset button on the dock) once this script prints
# "waiting for serial output on <dev>" so the capture window overlaps
# the boot sequence.
#
# ---------------------------------------------------------------------
# Hardware attachment (T14 G4 -> operator dev box)
# ---------------------------------------------------------------------
#
# The T14 G4 chassis exposes NO debug UART header (per
# design/hardware/quirks.md §2.5). Two attachment paths work in
# practice:
#
#   A. USB-C dock DB-9 (recommended). Lenovo ThinkPad Universal USB-C
#      Dock (Gen 2) exposes an RS-232 DB-9 on the back; the T14 G4's
#      firmware UART/BMC/OXPCIe910 chain is not standardized, so this
#      path acts as a general-purpose null-modem console instead. Wire
#      a USB-serial adapter (FT232, CH340, CP2102) between the dock's
#      DB-9 and the operator's dev box.
#
#   B. USB-serial dongle on the operator side + null-modem cable to a
#      second machine's DB-9 (rarely useful for a laptop; noted for
#      symmetry with server BMC setups).
#
# Pinout for a DB-9 null-modem (bare minimum: TX/RX/GND cross):
#
#           OPERATOR                              T14 DOCK
#           TX (pin 3) ------------------------> RX (pin 2)
#           RX (pin 2) <------------------------ TX (pin 3)
#           GND (pin 5) <---------------------- > GND (pin 5)
#
# Full-nine-wire (adds RTS/CTS + DTR/DSR + DCD) is not required at
# 115200 8N1 with no hardware flow control (the kernel does not assert
# RTS/DTR).
#
# ---------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------
#
#   boot   — verify the boot chain reaches the shell prompt.
#            Fingerprint: tests/hw/expected-hw-boot.txt
#            Success = "PaideiaOS R" banner ... "SHELL START" ... "$ "
#
#   pdxfs  — verify /etc/hello is readable from the mounted rootfs.
#            Operator types `cat /etc/hello` at the prompt.
#            Fingerprint: tests/hw/expected-hw-pdxfs.txt
#            Success = "hello from paideia" appears post-cat.
#
#   net    — verify e1000e brings up + ARP table populated.
#            Operator types `arp` (once available) or observes the
#            kernel's boot-time e1000e probe fingerprint.
#            Fingerprint: tests/hw/expected-hw-net.txt
#            Success = "E1000E LINK UP" + "ARP CACHE" markers.
#
#   all    — run boot, then pdxfs, then net sequentially (single power-
#            on; between-mode reboot NOT required as long as the
#            operator remembers to run each interactive step).
#
#   boot_r28_hw_smoke
#          — R28.M4 (#1008) composite per-subsystem fingerprint walk.
#            One capture window, one fingerprint file
#            (tests/hw/expected-hw-r28-composite.txt) that concatenates
#            §1 (boot) + §2 (pdxfs mount) + §3 (net probe/reset) + §4
#            (USB probe/reset/slot) lines from tools/hw-smoke-
#            fingerprints.md. NO interactive tail — the composite
#            answers "did the cold-boot substrate come up?" without
#            operator keypresses / peer-host pings / cat-etc-hello.
#            Individual pdxfs/net/usb modes still exist for the
#            interactive tails. See tools/hw-smoke-fingerprints.md §5
#            for the per-subsystem breakdown.
#
#   r51_m8_bdev
#          — R51.M8-006 (#1680) closing HW witness for the unified
#            BDEV path. Additionally gated by PAIDEIA_R51_M8_HW=1 (on
#            top of the script-wide PAIDEIA_HW_SMOKE=1) because this
#            mode drives a real mount+write+flush+unmount+remount+read
#            cycle against the T14 G4's internal NVMe scratch volume —
#            an operator running plain `boot`/`all` should never
#            trigger it by accident. Fingerprint file:
#            tests/hw/r51-nvme-t14g4.golden. Full recipe:
#            tools/hw-smoke-r51-nvme-t14g4.md.
#
# ---------------------------------------------------------------------
# Exit codes
# ---------------------------------------------------------------------
#
#   0    — fingerprint check passed
#   1    — fingerprint mismatch (line-in-order check failed)
#   2    — serial adapter not found or not readable
#   3    — PAIDEIA_HW_SMOKE gate not set
#   4    — stty/timeout/cat prerequisite missing
#   77   — mode not implemented yet (soft-skip; matches tests/hw/
#          fingerprint absent)
#  124   — capture window elapsed with no serial output at all
#          (adapter attached but T14 never booted / firmware hung)
#
# ---------------------------------------------------------------------
# Environment knobs
# ---------------------------------------------------------------------
#
#   PAIDEIA_HW_SMOKE          — must be "1" to run at all (safety gate).
#   PAIDEIA_R51_M8_HW         — must ALSO be "1" to run the `r51_m8_bdev`
#                               mode (see above; an extra gate on top of
#                               PAIDEIA_HW_SMOKE for this one mode since
#                               it writes to the internal NVMe volume).
#   PAIDEIA_HW_SERIAL_DEV     — tty device path (default /dev/ttyUSB0).
#   PAIDEIA_HW_SMOKE_TIMEOUT  — capture window in seconds (default per
#                               mode: boot=45, pdxfs=60, net=60, all=180).
#   PAIDEIA_HW_SMOKE_LOG      — where to write captured serial bytes
#                               (default /tmp/paideia-hw-smoke.log).
#   PAIDEIA_HW_SMOKE_BAUD     — baud rate (default 115200 — matches
#                               R16.M4 kernel UART init; do not change
#                               unless the kernel COM1 init is retuned).

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")"
MODE="${1:-}"

# -----------------------------------------------------------------------------
# Usage / help.
# -----------------------------------------------------------------------------
usage() {
    cat <<'USAGE'
run-smoke-hw — real-hardware serial-fingerprint check for the T14 G4
               (or any other target with a USB-serial attach) after the
               operator boots the paideia-mvp.img USB stick.

Usage:
  PAIDEIA_HW_SMOKE=1 tools/run-smoke-hw.sh {boot|pdxfs|net|usb|all|boot_r28_hw_smoke}
  tools/run-smoke-hw.sh {-h|--help}

Modes:
  boot    Verify boot chain reaches shell prompt.
  pdxfs   Verify /etc/hello is readable from the mounted rootfs.
          (operator types `cat /etc/hello` after the prompt appears)
  net     Verify e1000e link up + ARP table populated.
          (operator issues a `ping`-style command from userspace once
          such tooling exists; at R28.M2 the kernel probe fingerprint
          alone is the acceptance surface)
  usb     Verify xHCI probe + reset + slot enable + HID Boot Protocol
          keypresses land as HID KEY <ascii> in the log.
          (operator types "hello" on the attached USB keyboard during
          the capture window)
  all     Run boot, pdxfs, net, usb sequentially (single power-on).
  boot_r28_hw_smoke
          R28.M4 #1008 composite per-subsystem fingerprint. One
          capture window; no interactive tail. Concatenates the
          boot / pdxfs-mount / net-probe-reset / usb-probe-reset
          lines from tools/hw-smoke-fingerprints.md §5.
  r51_m8_bdev
          R51.M8-006 #1680 closing HW witness: unified BDEV path
          (mount+write+flush+unmount+remount+read) against the T14
          G4's internal NVMe scratch volume. Requires BOTH
          PAIDEIA_HW_SMOKE=1 and PAIDEIA_R51_M8_HW=1. Fingerprint:
          tests/hw/r51-nvme-t14g4.golden. Recipe:
          tools/hw-smoke-r51-nvme-t14g4.md.

Guard:
  Refuses to run without PAIDEIA_HW_SMOKE=1 exported. This prevents
  accidental invocation from pre-push / CI hooks — the fingerprint
  files under tests/hw/ are stubs until first-light on the T14 G4
  produces the real boot log to seed them.

Environment knobs:
  PAIDEIA_HW_SERIAL_DEV      Serial device (default /dev/ttyUSB0).
  PAIDEIA_HW_SMOKE_TIMEOUT   Capture window in seconds (per-mode default).
  PAIDEIA_HW_SMOKE_LOG       Capture file (default /tmp/paideia-hw-smoke.log).
  PAIDEIA_HW_SMOKE_BAUD      Baud (default 115200 — matches R16.M4 UART).

Operator workflow (typical `boot` invocation):
  1. Attach USB-serial adapter to the T14 G4's dock DB-9 or a null-
     modem cable (see file header for pinout).
  2. Plug the operator side into your dev box (usually /dev/ttyUSB0).
  3. Run:  PAIDEIA_HW_SMOKE=1 tools/run-smoke-hw.sh boot
  4. When the script prints "waiting for serial output on ...", cold-
     power the T14 G4 (or hit reset) and let it boot from the paideia-
     mvp.img USB stick per design/hardware/t14-g4-first-boot.md.
  5. Fingerprint check runs against tests/hw/expected-hw-boot.txt
     after the capture window closes (or exit-early when the last
     fingerprint line appears — reserved for future refinement).

See also:
  design/kernel/serial-console-fallback.md   — screen/tio/picocom recipes.
  design/hardware/t14-g4-first-boot.md       — cold-power-to-shell walkthrough.
  tools/nvme-hw-smoke.md                     — GDB-driven NVMe HW witness (#908).
  tools/xhci-keyboard-smoke.md               — HID Boot Keyboard HW witness.
  tools/hw-smoke-r51-nvme-t14g4.md            — R51.M8-006 unified BDEV HW witness (#1680).

Exit codes:
  0=pass  1=fingerprint mismatch  2=no serial adapter  3=gate not set
  4=missing prerequisite  77=mode not implemented  124=no serial output
USAGE
}

if [[ -z "${MODE}" || "${MODE}" == "-h" || "${MODE}" == "--help" ]]; then
    usage
    exit 0
fi

# -----------------------------------------------------------------------------
# Gate: PAIDEIA_HW_SMOKE=1 required.
# -----------------------------------------------------------------------------
if [[ "${PAIDEIA_HW_SMOKE:-0}" != "1" ]]; then
    cat >&2 <<'MSG'
run-smoke-hw: refusing to run without PAIDEIA_HW_SMOKE=1.

This harness reads bytes from a live USB-serial adapter that is expected
to be attached to a T14 G4 booting the paideia-mvp.img image. Running it
in a CI / pre-push / QEMU-only context would either time out (no bytes
arrive) or, worse, misread bytes from an unrelated tty device.

Re-run with:

    PAIDEIA_HW_SMOKE=1 tools/run-smoke-hw.sh <mode>

Or read the file header for the full operator workflow.
MSG
    exit 3
fi

# -----------------------------------------------------------------------------
# Prerequisite tools.
# -----------------------------------------------------------------------------
for tool in stty timeout cat; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "run-smoke-hw: missing prerequisite: ${tool}" >&2
        exit 4
    fi
done

# -----------------------------------------------------------------------------
# Mode dispatch + fingerprint / timeout defaults.
# -----------------------------------------------------------------------------
FINGERPRINT_FILE=""
DEFAULT_TIMEOUT=45
case "${MODE}" in
    boot)
        FINGERPRINT_FILE="${REPO_ROOT}/tests/hw/expected-hw-boot.txt"
        DEFAULT_TIMEOUT=45
        ;;
    pdxfs)
        FINGERPRINT_FILE="${REPO_ROOT}/tests/hw/expected-hw-pdxfs.txt"
        DEFAULT_TIMEOUT=60
        ;;
    net)
        FINGERPRINT_FILE="${REPO_ROOT}/tests/hw/expected-hw-net.txt"
        DEFAULT_TIMEOUT=60
        ;;
    usb)
        FINGERPRINT_FILE="${REPO_ROOT}/tests/hw/expected-hw-usb.txt"
        DEFAULT_TIMEOUT=60
        ;;
    boot_r28_hw_smoke)
        # R28.M4 #1008 composite mode. One capture window walks every
        # per-subsystem fingerprint documented in tools/hw-smoke-
        # fingerprints.md §5. No interactive tail — operator does NOT
        # type at the prompt during the capture window.
        FINGERPRINT_FILE="${REPO_ROOT}/tests/hw/expected-hw-r28-composite.txt"
        DEFAULT_TIMEOUT=240
        ;;
    r51_m8_bdev)
        # R51.M8-006 (#1680) closing HW witness. Additional gate on
        # top of the script-wide PAIDEIA_HW_SMOKE=1: this mode drives
        # a real mount+write+flush+unmount+remount+read cycle against
        # the T14 G4's internal NVMe scratch volume (see
        # tools/hw-smoke-r51-nvme-t14g4.md), so an operator running
        # the plain `boot`/`all` modes should never trigger it by
        # accident.
        if [[ "${PAIDEIA_R51_M8_HW:-0}" != "1" ]]; then
            cat >&2 <<'MSG'
run-smoke-hw[r51_m8_bdev]: this mode additionally requires PAIDEIA_R51_M8_HW=1.

This mode drives a real mount+write+flush+unmount+remount+read cycle
against the T14 G4's internal NVMe scratch volume (data loss on that
volume is expected — do not point it at a partition you want to keep).
See tools/hw-smoke-r51-nvme-t14g4.md for the full recipe. Re-run with:

    PAIDEIA_HW_SMOKE=1 PAIDEIA_R51_M8_HW=1 tools/run-smoke-hw.sh r51_m8_bdev
MSG
            exit 3
        fi
        FINGERPRINT_FILE="${REPO_ROOT}/tests/hw/r51-nvme-t14g4.golden"
        DEFAULT_TIMEOUT=120
        ;;
    all)
        # `all` recurses into the four sub-modes in order, sharing the
        # cold-power window; sub-mode timeouts accumulate.
        rc=0
        for sub in boot pdxfs net usb; do
            echo "run-smoke-hw[all]: === sub-mode: ${sub} ==="
            PAIDEIA_HW_SMOKE=1 bash "${BASH_SOURCE[0]}" "${sub}"
            sub_rc=$?
            if [[ ${sub_rc} -ne 0 && ${sub_rc} -ne 77 ]]; then
                rc=${sub_rc}
                echo "run-smoke-hw[all]: sub-mode ${sub} failed (rc=${sub_rc}); aborting" >&2
                exit ${rc}
            fi
        done
        echo "run-smoke-hw[all]: OK (or SKIP for any mode whose fingerprint file is not seeded yet)"
        exit 0
        ;;
    *)
        echo "run-smoke-hw: unknown mode '${MODE}'" >&2
        usage >&2
        exit 1
        ;;
esac

TIMEOUT="${PAIDEIA_HW_SMOKE_TIMEOUT:-${DEFAULT_TIMEOUT}}"
SERIAL_DEV="${PAIDEIA_HW_SERIAL_DEV:-/dev/ttyUSB0}"
CAPTURE_LOG="${PAIDEIA_HW_SMOKE_LOG:-/tmp/paideia-hw-smoke.log}"
BAUD="${PAIDEIA_HW_SMOKE_BAUD:-115200}"

# -----------------------------------------------------------------------------
# Serial adapter presence check.
# -----------------------------------------------------------------------------
# Checked BEFORE fingerprint file readiness so a caller without any
# real hardware attached always sees the "no serial adapter detected"
# path (the AC #1002 requires). The soft-skip-on-missing-fingerprint
# path only triggers when the operator DOES have an adapter attached
# but the tests/hw/ file has not yet been seeded from first-light.
if [[ ! -e "${SERIAL_DEV}" ]]; then
    cat >&2 <<MSG
run-smoke-hw[${MODE}]: no serial adapter detected at ${SERIAL_DEV}.

Attach a USB-serial adapter (FT232 / CH340 / CP2102) to the operator
dev box, wired via null-modem to the T14 G4 dock's DB-9 (see file
header for pinout). Then re-run.

Override the device path if it enumerated elsewhere (e.g. /dev/ttyUSB1,
/dev/ttyACM0):

    PAIDEIA_HW_SMOKE=1 PAIDEIA_HW_SERIAL_DEV=/dev/ttyACM0 tools/run-smoke-hw.sh ${MODE}

Check enumeration with:  dmesg | tail -20   (right after plugging in)
                          lsusb              (see FTDI / QinHeng entry)
                          ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null
MSG
    exit 2
fi

if [[ ! -r "${SERIAL_DEV}" || ! -w "${SERIAL_DEV}" ]]; then
    cat >&2 <<MSG
run-smoke-hw[${MODE}]: ${SERIAL_DEV} not readable/writable by this user.

Add your user to the dialout group (Debian/Ubuntu) or uucp (Arch) and
re-log:

    sudo usermod -a -G dialout \$USER    # then log out + log back in

Verify with:  groups | grep -E 'dialout|uucp'
MSG
    exit 2
fi

# -----------------------------------------------------------------------------
# Fingerprint file readiness (checked after adapter presence).
# -----------------------------------------------------------------------------
# Absent = mode is planned but not yet seeded from a real T14 first-boot;
# treat as SKIP (rc=77) so `all` mode can proceed through remaining modes.
if [[ ! -f "${FINGERPRINT_FILE}" ]]; then
    cat <<MSG
run-smoke-hw[${MODE}]: SKIP — fingerprint file not seeded yet.

  expected: ${FINGERPRINT_FILE}

The fingerprint contents are seeded from the first successful T14 G4
boot log capture. Until that happens, this mode soft-skips (rc=77) so
CI-adjacent contexts do not fail on the missing file, matching the
run-smoke.sh convention for not-yet-wired witnesses (e.g. the R22.M6
boot_r22_msix_ir_round_robin skip-echo mode).

To seed: capture a real boot serial log, extract the deterministic
lines the kernel emits for this mode, and write them to the fingerprint
file (one grep-substring per line, in-order-appearance check).
MSG
    exit 77
fi

# -----------------------------------------------------------------------------
# Configure the tty: BAUD 8N1, no flow control, raw.
# -----------------------------------------------------------------------------
# Rationale: kernel COM1 init (src/kernel/boot/uart.pdx step 7 +
# src/kernel/core/uart/rx_init.pdx IER=0x01) leaves the line in 8-bit
# words, no parity, 1 stop bit, no hardware handshake. `raw` disables
# host-side line-cooking so binary-clean bytes reach the log.
#
# `stty` is the operator-side mirror of the kernel's UART init; the two
# must agree byte-for-byte or the log fills with framing errors.
if ! stty -F "${SERIAL_DEV}" \
        "${BAUD}" \
        cs8 -cstopb -parenb \
        -crtscts -ixon -ixoff \
        raw -echo \
        >/dev/null 2>&1; then
    echo "run-smoke-hw[${MODE}]: stty configuration failed on ${SERIAL_DEV}" >&2
    exit 2
fi

# -----------------------------------------------------------------------------
# Capture window.
# -----------------------------------------------------------------------------
rm -f "${CAPTURE_LOG}"
cat <<MSG
run-smoke-hw[${MODE}]: waiting for serial output on ${SERIAL_DEV}
run-smoke-hw[${MODE}]:   baud=${BAUD} timeout=${TIMEOUT}s log=${CAPTURE_LOG}
run-smoke-hw[${MODE}]:   fingerprint=${FINGERPRINT_FILE}

*** Cold-power the T14 G4 (or hit reset) NOW.
    Firmware -> BootX64.EFI -> kernel_main -> INIT -> shell should
    stream over the wire within ${TIMEOUT} seconds.
MSG

# `timeout` bounds the capture window; SIGTERM after ${TIMEOUT}s lets
# `cat` flush cleanly. Exit code 124 means the window elapsed (still a
# fingerprint-check candidate — the boot may have completed inside the
# window). Exit code 143 is SIGTERM propagation from timeout, same
# meaning; both are treated as "capture done, now verify".
if command -v stdbuf >/dev/null 2>&1; then
    timeout --preserve-status "${TIMEOUT}" stdbuf -oL cat "${SERIAL_DEV}" > "${CAPTURE_LOG}"
else
    timeout --preserve-status "${TIMEOUT}" cat "${SERIAL_DEV}" > "${CAPTURE_LOG}"
fi
CAT_RC=$?

# Exit codes we treat as "capture window closed cleanly":
#   0    — cat returned normally (unlikely; serial usually only EOFs on
#          adapter unplug)
#   124  — GNU timeout raised SIGTERM after window (expected)
#   143  — SIGTERM propagated through --preserve-status (expected)
if [[ ${CAT_RC} -ne 0 && ${CAT_RC} -ne 124 && ${CAT_RC} -ne 143 ]]; then
    echo "run-smoke-hw[${MODE}]: serial capture failed rc=${CAT_RC}" >&2
    exit 2
fi

# Zero bytes captured = adapter attached but nothing came in = 124.
if [[ ! -s "${CAPTURE_LOG}" ]]; then
    cat >&2 <<MSG
run-smoke-hw[${MODE}]: no serial bytes captured in ${TIMEOUT}s.

Likely causes:
  * T14 G4 never booted (BIOS boot-order still SSD-first? UEFI Only?
    Secure Boot still enabled? See design/hardware/t14-g4-first-boot.md
    §3 BIOS setup checklist).
  * TX/RX crossed wrong on the null-modem cable.
  * Wrong tty device path (${SERIAL_DEV}); some adapters enumerate as
    /dev/ttyACM0 instead of /dev/ttyUSB0.
  * Wrong baud (${BAUD}); the kernel R16.M4 UART init is 115200 8N1 —
    do not override PAIDEIA_HW_SMOKE_BAUD unless COM1 init is retuned.
MSG
    exit 124
fi

# -----------------------------------------------------------------------------
# Fingerprint check (same in-order contains-check as tools/run-smoke.sh).
# -----------------------------------------------------------------------------
log_content="$(cat "${CAPTURE_LOG}" 2>/dev/null || echo "")"
line_num=0
search_offset=0

while IFS= read -r fp_line || [[ -n "${fp_line}" ]]; do
    ((line_num++))
    # Skip blank / comment lines (`#`-prefixed) in the fingerprint file
    # so operators can annotate the file inline.
    if [[ -z "${fp_line}" || "${fp_line:0:1}" == "#" ]]; then
        continue
    fi
    remaining="${log_content:search_offset}"
    if [[ "${remaining}" == *"${fp_line}"* ]]; then
        prefix="${remaining%%"${fp_line}"*}"
        search_offset=$((search_offset + ${#prefix} + ${#fp_line}))
    else
        cat >&2 <<MSG
run-smoke-hw[${MODE}]: fingerprint line ${line_num} NOT found in serial log after position ${search_offset}.
  missing:  '${fp_line}'
  log size: $(stat -c%s "${CAPTURE_LOG}" 2>/dev/null || echo 0) bytes
  log path: ${CAPTURE_LOG}
MSG
        exit 1
    fi
done < "${FINGERPRINT_FILE}"

echo "run-smoke-hw[${MODE}]: OK — fingerprint matched (${line_num} lines checked)"
exit 0
