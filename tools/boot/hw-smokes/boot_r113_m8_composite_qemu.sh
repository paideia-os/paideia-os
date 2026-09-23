#!/usr/bin/env bash
# tools/boot/hw-smokes/boot_r113_m8_composite_qemu.sh -- Wave ν (α–τ plan)
#
# QEMU-approximation half of paideia-os#2420 ("Multi-surface composite
# witness on Iris Xe").  The issue's honest closure requires Iris Xe
# GPU BLEND / SF programming; this script pins the KERNEL-side code-
# path signal that (a) the R113 M1-001 KIND_SURFACE mint substrate
# handles three back-to-back mints and (b) three CPU-side tile blits
# into non-overlapping LFB regions round-trip pixel-wise.
#
# INVOCATION
#   * PAIDEIA_VGA=std attaches QEMU's Bochs stdvga LFB.
#   * The witness (src/kernel/boot/witness/r113_m8_composite_qemu_
#     witness.pdx) mints three surfaces (100x100 each, format=1),
#     blits sentinels 0x11111111 / 0x22222222 / 0x33333333 into
#     regions (50,50) / (300,300) / (600,500), reads back one center
#     pixel per region, then destroys all three rows.
#
# USAGE
#   bash tools/boot/hw-smokes/boot_r113_m8_composite_qemu.sh
#
# EXIT CODES
#   0   -- "R113 M8-040 COMPOSITE QEMU OK" appeared in the serial log.
#   1   -- kernel booted, no fingerprint (or FAIL fingerprint) within
#          the timeout.
#   77  -- environment prerequisite missing.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TIMEOUT="${BOOT_R113_M8_CO_TIMEOUT:-10}"

if [[ ! -f "${REPO_ROOT}/build/kernel.elf" ]]; then
    echo "boot_r113_m8_composite_qemu: kernel not built; run tools/build.sh first" >&2
    exit 77
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "boot_r113_m8_composite_qemu: qemu-system-x86_64 not found; skipping" >&2
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
    echo "boot_r113_m8_composite_qemu: qemu-system-x86_64 exited ${QEMU_RC} (not a timeout)" >&2
fi

if grep -q "R113 M8-040 COMPOSITE QEMU OK" "${LOG_FILE}"; then
    echo "boot_r113_m8_composite_qemu: R113 M8-040 COMPOSITE QEMU OK found"
    exit 0
fi

echo "boot_r113_m8_composite_qemu: OK marker NOT found within ${TIMEOUT}s" >&2
echo "--- serial log ---" >&2
cat "${LOG_FILE}" >&2
exit 1
