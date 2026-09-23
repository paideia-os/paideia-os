#!/usr/bin/env bash
# tools/boot/hw-smokes/boot_r113_m8_kbd_qemu.sh -- Wave ν (α–τ plan)
#
# QEMU-approximation half of paideia-os#2418 ("External-USB-keyboard
# input smoke on T14").  The issue's honest closure requires physical
# T14 G4 hardware with a real USB HID boot keyboard attached; this
# script pins the KERNEL-side code-path signal (xHCI probe + attach +
# PORTSC.CCS detection) so a regression there fails visibly without
# waiting for a T14 boot session.
#
# INVOCATION
#   * PAIDEIA_VGA is not required (default `none` is fine -- this
#     smoke exercises xHCI, not graphics).
#   * `-device qemu-xhci -device usb-kbd` synthesise a real xHCI
#     controller (PCI class 0x0C / subclass 0x03 / prog_if 0x30) with
#     a HID boot-keyboard on one of its root-hub ports.  QEMU's
#     xhci implementation already lands (R34 -- see kernel_main.pdx
#     §R111.M5-017 xhci_attach_all).
#
# The witness that emits the fingerprint is src/kernel/boot/witness/
# r113_m8_kbd_qemu_witness.pdx (see its file header for what it
# proves and what it explicitly does NOT prove).
#
# USAGE
#   bash tools/boot/hw-smokes/boot_r113_m8_kbd_qemu.sh
#
# EXIT CODES
#   0   -- "R113 M8-038 KBD QEMU OK" appeared in the serial log.
#   1   -- kernel booted, no fingerprint (or FAIL fingerprint) within
#          the timeout.
#   77  -- environment prerequisite missing (no kernel build, no
#          qemu-system-x86_64) -- skip cleanly, matching tools/run-
#          smoke.sh's convention.
#
# The `-device qemu-xhci -device usb-kbd` pair passes through
# run-qemu.sh's `"$@"` tail unchanged.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TIMEOUT="${BOOT_R113_M8_KBD_TIMEOUT:-10}"

if [[ ! -f "${REPO_ROOT}/build/kernel.elf" ]]; then
    echo "boot_r113_m8_kbd_qemu: kernel not built; run tools/build.sh first" >&2
    exit 77
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "boot_r113_m8_kbd_qemu: qemu-system-x86_64 not found; skipping" >&2
    exit 77
fi

LOG_FILE="$(mktemp)"
trap 'rm -f "${LOG_FILE}"' EXIT

timeout "${TIMEOUT}" \
    "${REPO_ROOT}/tools/run-qemu.sh" \
        -device qemu-xhci \
        -device usb-kbd \
    >"${LOG_FILE}" 2>&1
QEMU_RC=$?

# 124 is expected on the happy path -- init's later fork/exec cycles
# block indefinitely well past the witness's own early emission.
# The fingerprint alone decides pass/fail.
if [[ ${QEMU_RC} -ne 0 && ${QEMU_RC} -ne 124 ]]; then
    echo "boot_r113_m8_kbd_qemu: qemu-system-x86_64 exited ${QEMU_RC} (not a timeout)" >&2
fi

if grep -q "R113 M8-038 KBD QEMU OK" "${LOG_FILE}"; then
    echo "boot_r113_m8_kbd_qemu: R113 M8-038 KBD QEMU OK found"
    exit 0
fi

echo "boot_r113_m8_kbd_qemu: OK marker NOT found within ${TIMEOUT}s" >&2
echo "--- serial log ---" >&2
cat "${LOG_FILE}" >&2
exit 1
