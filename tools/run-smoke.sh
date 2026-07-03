#!/usr/bin/env bash
# Phase-1 smoke regression: builds the kernel, runs under QEMU with a
# configurable timeout, captures serial output, and asserts deterministic
# bytes.
#
# Usage: tools/run-smoke.sh [MODE | expected_marker | --fingerprint PATTERN]
#   - MODE: one of 'boot_min', 'boot_banner', 'boot_tick', 'boot_r8_only', 'boot_r10', 'boot_r11', 'boot_r12', 'prod' (mode dispatcher)
#     * boot_min: validates boot_min fingerprint, 5s timeout
#     * boot_banner: validates boot_banner fingerprint, 5s timeout
#     * boot_tick: validates boot_tick fingerprint (with timer TICKs), 5s timeout
#     * boot_r8_only: validates R8-only fingerprint (no timer, no IDT), 5s timeout
#     * boot_r10: validates R10 task alternation fingerprint (Task A/B cooperative yield), 10s timeout
#     * boot_r11: validates R11 softer task alternation fingerprint (Task A/B/A cooperative), 10s timeout
#     * boot_r12: validates R12 capability dispatch fingerprint (5 cap tags + 3 task lines), 8s timeout
#     * prod: expects exit code 2 (kernel didn't build), skips verification
#   - expected_marker: defaults to no-check (just confirms QEMU exits or
#     times out cleanly). Pass a string to grep the serial log for.
#   - --fingerprint PATTERN: validate serial output against tests/r8/expected-PATTERN.txt
#     file; checks that all lines from the fingerprint file appear in order in the log
#     (contains-in-order check, not strict equality).
#
# Exit codes:
#   0  — kernel built + booted + (optional) expected marker found
#   1  — kernel built but smoke failed (no marker / unexpected QEMU exit)
#   2  — kernel didn't build
#  33  — kernel graceful clean exit (isa-debug-exit byte 0x10 → QEMU exits (0x10 << 1) | 1 = 33)
#  35  — kernel failed exit (isa-debug-exit byte 0x11 → QEMU exits (0x11 << 1) | 1 = 35)
#  77  — QEMU not installed (test skipped)
# 124  — smoke timeout (5s runner timeout)
# 137  — kernel killed (OOM / other fatal signal)

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
EXPECTED="${1:-}"
FINGERPRINT_MODE=0
FINGERPRINT_FILE=""
TIMEOUT=5

# Mode dispatcher: map boot_min/boot_banner/boot_tick/boot_r8_only/boot_r10/boot_r11/prod to fingerprint + timeout
case "${EXPECTED}" in
    boot_min)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r8/expected-boot-min.txt"
        TIMEOUT=5
        EXPECTED=""
        ;;
    boot_banner)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r8/expected-boot-banner.txt"
        TIMEOUT=5
        EXPECTED=""
        ;;
    boot_tick)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r9/expected-boot-tick.txt"
        TIMEOUT=5
        EXPECTED=""
        ;;
    boot_r8_only)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r9/expected-r8-only.txt"
        TIMEOUT=5
        EXPECTED=""
        ;;
    boot_r10)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r10/expected-boot-r10.txt"
        TIMEOUT=10
        EXPECTED=""
        ;;
    boot_r11)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r11/expected-boot-r11.txt"
        TIMEOUT=10
        EXPECTED=""
        ;;
    boot_r12)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r12/expected-boot-r12.txt"
        TIMEOUT=8
        EXPECTED=""
        ;;
    prod)
        # prod mode: expects exit code 2 (kernel didn't build)
        # Skip verification, just exit with code 2
        exit 2
        ;;
esac

# Parse arguments: check for --fingerprint flag (backward-compatible)
if [[ "${EXPECTED}" == "--fingerprint" && -n "${2:-}" ]]; then
    FINGERPRINT_MODE=1
    FINGERPRINT_FILE="${REPO_ROOT}/tests/r8/expected-${2}.txt"
    EXPECTED=""
fi

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

timeout ${TIMEOUT} qemu-system-x86_64 \
    -kernel "${KERNEL}" \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
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

if [[ ${FINGERPRINT_MODE} -eq 1 ]]; then
    # Fingerprint mode: validate serial output against expected lines
    if [[ ! -f "${FINGERPRINT_FILE}" ]]; then
        echo "smoke: fingerprint file not found: ${FINGERPRINT_FILE}" >&2
        exit 1
    fi

    # Read fingerprint file and check each line appears in order in the log
    log_content="$(cat "${LOG}" 2>/dev/null || echo "")"
    line_num=0
    search_offset=0

    while IFS= read -r line; do
        ((line_num++))
        if [[ -z "${line}" ]]; then
            # Skip empty lines in fingerprint file
            continue
        fi
        # Search for line in log starting from last match position
        if [[ "${log_content}" == *"${line}"* ]]; then
            # Line found; update search offset for next iteration
            search_offset=$(( ${#log_content} ))
        else
            echo "smoke: fingerprint line ${line_num} ('${line}') NOT found in serial log (log size: $(stat -c%s "${LOG}" 2>/dev/null || echo 0))" >&2
            exit 1
        fi
    done < "${FINGERPRINT_FILE}"

    echo "smoke: fingerprint check passed (all ${line_num} lines found in order)"
    exit 0
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
