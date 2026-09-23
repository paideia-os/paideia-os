#!/usr/bin/env bash
# tools/boot/hw-smokes/boot_r113_m8_scanout_qemu.sh -- Wave ν (α–τ plan)
#
# QEMU-approximation half of paideia-os#2419 ("Direct-scanout witness
# on Iris Xe").  The issue's honest closure requires Iris Xe silicon
# programming (DDI / TRANS / PIPE / PLANE); this script pins the
# KERNEL-side code-path signal that the Bochs stdvga LFB (the closest
# proxy QEMU can synthesise for a linear framebuffer) is mapped and
# round-trippable pixel-wise.
#
# INVOCATION
#   * PAIDEIA_VGA=std attaches QEMU's Bochs stdvga (0x1234/0x1111).
#     bochs_stdvga_probe + bochs_stdvga_modeset + bochs_lfb_map
#     already land in kernel_main.pdx §R101.M2-005.
#   * The witness (src/kernel/boot/witness/r113_m8_scanout_qemu_
#     witness.pdx) reads _bochs_stdvga_devices[0]+40 for the mapped
#     lfb_va, then round-trips 0xDEADBEEF at four spatially-
#     bracketed pixel positions.
#
# USAGE
#   bash tools/boot/hw-smokes/boot_r113_m8_scanout_qemu.sh
#
# EXIT CODES
#   0   -- "R113 M8-039 SCANOUT QEMU OK" appeared in the serial log.
#   1   -- kernel booted, no fingerprint (or FAIL fingerprint) within
#          the timeout.
#   77  -- environment prerequisite missing.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TIMEOUT="${BOOT_R113_M8_SO_TIMEOUT:-10}"

if [[ ! -f "${REPO_ROOT}/build/kernel.elf" ]]; then
    echo "boot_r113_m8_scanout_qemu: kernel not built; run tools/build.sh first" >&2
    exit 77
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "boot_r113_m8_scanout_qemu: qemu-system-x86_64 not found; skipping" >&2
    exit 77
fi

LOG_FILE="$(mktemp)"
trap 'rm -f "${LOG_FILE}"' EXIT

PAIDEIA_VGA=std \
timeout "${TIMEOUT}" \
    "${REPO_ROOT}/tools/run-qemu.sh" \
    >"${LOG_FILE}" 2>&1
QEMU_RC=$?

if [[ ${QEMU_RC} -ne 0 && ${QEMU_RC} -ne 124 ]]; then
    echo "boot_r113_m8_scanout_qemu: qemu-system-x86_64 exited ${QEMU_RC} (not a timeout)" >&2
fi

if grep -q "R113 M8-039 SCANOUT QEMU OK" "${LOG_FILE}"; then
    echo "boot_r113_m8_scanout_qemu: R113 M8-039 SCANOUT QEMU OK found"
    exit 0
fi

echo "boot_r113_m8_scanout_qemu: OK marker NOT found within ${TIMEOUT}s" >&2
echo "--- serial log ---" >&2
cat "${LOG_FILE}" >&2
exit 1
