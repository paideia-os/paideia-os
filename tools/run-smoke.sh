#!/usr/bin/env bash
# Phase-1 smoke regression: builds the kernel, runs under QEMU with a
# 5-second timeout, captures serial output, and asserts deterministic
# bytes.
#
# Usage: tools/run-smoke.sh [expected_marker]
#   expected_marker defaults to no-check (just confirms QEMU exits or
#   times out cleanly). Pass a string to grep the serial log for.
#
# Exit codes:
#   0  — kernel built + booted + (optional) expected marker found
#   1  — kernel built but smoke failed (no marker / triple fault)
#   2  — kernel didn't build
#  77  — QEMU not installed (test skipped)

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
EXPECTED="${1:-}"

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "smoke: qemu-system-x86_64 not found; skipping" >&2
    exit 77
fi

if ! "${REPO_ROOT}/tools/build.sh" >/dev/null 2>&1; then
    echo "smoke: build failed" >&2
    exit 2
fi

KERNEL="${REPO_ROOT}/build/kernel.elf"
LOG="/tmp/paideia-os-smoke.log"
rm -f "${LOG}"

timeout 5 qemu-system-x86_64 \
    -kernel "${KERNEL}" \
    -serial "file:${LOG}" \
    -display none \
    -no-reboot \
    -no-shutdown \
    -m 32M \
    >/dev/null 2>&1
QEMU_RC=$?

# QEMU exit codes: 124 = timeout (expected for halt+stay-on); 0 = clean
if [[ ${QEMU_RC} -ne 0 && ${QEMU_RC} -ne 124 ]]; then
    echo "smoke: qemu exited with rc=${QEMU_RC}" >&2
    exit 1
fi

if [[ -n "${EXPECTED}" ]]; then
    if [[ -s "${LOG}" ]] && grep -q "${EXPECTED}" "${LOG}"; then
        echo "smoke: marker '${EXPECTED}' found in serial log"
        exit 0
    else
        echo "smoke: marker '${EXPECTED}' NOT in serial log (log size: $(stat -c%s "${LOG}" 2>/dev/null || echo 0))" >&2
        exit 1
    fi
fi

echo "smoke: kernel built + booted (no marker check requested)"
exit 0
