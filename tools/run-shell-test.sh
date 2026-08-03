#!/usr/bin/env bash
# tools/run-shell-test.sh — #635 (r17-m5-001)
#
# Serial-PTY driver: launch QEMU with kernel, drive the shell via scripted
# stdin lines, capture full transcript, optionally diff against a golden.
#
# The heavy lifting (pexpect PTY control, prompt sync) lives in the sibling
# _shell_test_driver.py — this wrapper only handles CLI parsing, build, and
# exit-code plumbing.
#
# Usage:
#   tools/run-shell-test.sh SCRIPT [--golden GOLDEN] [--timeout SECS] [--prompt STR]
#
# Args:
#   SCRIPT           newline-separated commands to send to the shell
#   --golden FILE    optional expected transcript (exact-match)
#   --timeout SECS   overall wall-clock (default 30)
#   --prompt STR     shell prompt to sync on (default "$ ")
#
# Exit codes:
#   0   — script executed (+ golden matched if given)
#   1   — golden mismatch or in-run error
#   2   — pre-flight failure (missing qemu / pexpect / kernel)
#  77   — dependency skip
# 124   — timeout

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT_FILE="${1:-}"
shift || true

if [[ -z "${SCRIPT_FILE}" ]]; then
    echo "usage: $0 SCRIPT [--golden GOLDEN] [--timeout SECS] [--prompt STR]" >&2
    exit 2
fi
if [[ ! -f "${SCRIPT_FILE}" ]]; then
    echo "run-shell-test: script file not found: ${SCRIPT_FILE}" >&2
    exit 2
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "run-shell-test: qemu-system-x86_64 not found; skipping" >&2
    exit 77
fi
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import pexpect' 2>/dev/null; then
    echo "run-shell-test: python3+pexpect not available; skipping" >&2
    exit 77
fi

if ! "${REPO_ROOT}/tools/build.sh" >/dev/null 2>&1; then
    echo "run-shell-test: kernel build failed" >&2
    exit 2
fi

KERNEL="${REPO_ROOT}/build/kernel.elf"
exec python3 "${REPO_ROOT}/tools/_shell_test_driver.py" \
    --kernel "${KERNEL}" \
    --script "${SCRIPT_FILE}" \
    "$@"
