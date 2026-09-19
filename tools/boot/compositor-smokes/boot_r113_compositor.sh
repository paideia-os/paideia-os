#!/usr/bin/env bash
# tools/boot/compositor-smokes/boot_r113_compositor.sh -- COMP-QM-01
#
# Wave β β-02 (paideia-os compositor QEMU bring-up). Boots the kernel
# with COMPOSITOR_INIT=1 and asserts the "COMP INIT OK" fingerprint
# lands on the serial wire, emitted by src/user/compositor/selftest.pdx
# (Wave β β-01) once init forks+execs /bin/compositor_selftest.
#
# Authority: design/testing/compositor-qemu-smoke-plan.md §4 SSS-01.
# This was previously a design-stage stub (exit 77) pending gap G5 --
# "tools/run-qemu.sh and kernel_main.pdx have no COMPOSITOR_INIT_ENABLE
# gate or equivalent init-time compositor bring-up sequencing". That
# gap is closed as of Wave β: the compositor self-check now runs on
# every boot (see tools/run-qemu.sh's COMPOSITOR_INIT= composition-site
# comment for why the fingerprint does not actually depend on the
# COMPOSITOR_INIT=1 env var today -- it is exported here anyway per the
# task brief, and to give a real, already-named guest-visible fw_cfg
# entry for a future runtime cmdline parser to consume without a
# script change).
#
# Usage: tools/boot/compositor-smokes/boot_r113_compositor.sh
# Exit codes:
#   0   -- "COMP INIT OK" found in the serial log (ordered substring).
#   1   -- kernel booted but the fingerprint did not appear before
#          TIMEOUT, or QEMU exited without producing it.
#   77  -- environment/prerequisite not met (no kernel build, no
#          qemu-system-x86_64) -- skip cleanly, matching
#          tools/run-smoke.sh's convention.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TIMEOUT="${BOOT_R113_TIMEOUT:-10}"

if [[ ! -f "${REPO_ROOT}/build/kernel.elf" ]]; then
    echo "boot_r113_compositor: kernel not built; run tools/build.sh first" >&2
    exit 77
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "boot_r113_compositor: qemu-system-x86_64 not found; skipping" >&2
    exit 77
fi

LOG_FILE="$(mktemp)"
trap 'rm -f "${LOG_FILE}"' EXIT

# COMPOSITOR_INIT=1 per the task brief -- see tools/run-qemu.sh's own
# comment on this flag for why the fingerprint's appearance does not
# actually depend on it today (the self-check runs unconditionally).
COMPOSITOR_INIT=1 timeout "${TIMEOUT}" \
    "${REPO_ROOT}/tools/run-qemu.sh" >"${LOG_FILE}" 2>&1
QEMU_RC=$?

# timeout's 124 is expected on the happy path too: init's later
# fork+exec cycles (/bin/sh with no injected stdin, in particular) can
# block indefinitely well past compositor_selftest's own early exit,
# so this script does not treat 124 as a hard failure -- only the
# fingerprint's presence decides pass/fail.
if [[ ${QEMU_RC} -ne 0 && ${QEMU_RC} -ne 124 ]]; then
    echo "boot_r113_compositor: qemu-system-x86_64 exited ${QEMU_RC} (not a timeout)" >&2
fi

if grep -q "COMP INIT OK" "${LOG_FILE}"; then
    echo "boot_r113_compositor: COMP INIT OK found"
    exit 0
fi

echo "boot_r113_compositor: COMP INIT OK NOT found within ${TIMEOUT}s" >&2
echo "--- serial log ---" >&2
cat "${LOG_FILE}" >&2
exit 1
