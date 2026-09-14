#!/usr/bin/env bash
# tools/run-qemu-tests.sh -- Wave π (π-04).
#
# Thin wrapper around tools/run-qemu.sh that boots the kernel-linked
# test-runner ELFs built by `tools/build.sh --compositor-tests`
# (design/testing/kernel-test-runner.md is the general pattern;
# design/testing/compositor-test-runner.md is the compositor instance)
# and checks each one's summary fingerprint on the serial log.
#
# Usage:
#   tools/run-qemu-tests.sh [--compositor] [--postui-desktop]
#
#   No suite flag runs every known suite. Exits 0 iff every requested
#   suite's runner both exists and reports zero failures; exits
#   non-zero on any missing runner, any timeout, or any reported
#   failure.
#
# KNOWN GAP (tracked, not silently papered over): a test-runner ELF
# built by `--compositor-tests` is a flat ring-3 user binary (entry at
# 0x00400000, linked against src/user/link.ld's own shape via its own
# test.ld) -- the SAME shape as shell.elf / true.elf / selftest.elf.
# It is not a bootable kernel image: it carries no PVH ELF note (the
# thing that lets tools/run-qemu.sh's `-kernel build/kernel.elf`
# invocation work directly, per that script's own comment), no GDT/
# paging setup, no SYSCALL MSR (STAR/LSTAR) configuration -- its
# `syscall` instructions require a running kernel underneath it, same
# as any other src/user/*.pdx binary. Every non-kernel ELF this
# monorepo runs under QEMU today (shell.elf, true.elf, selftest.elf,
# echo_client.elf, ...) reaches ring 3 by being embedded in the boot
# tmpfs seed and fork+exec'd from src/user/init.pdx AFTER the real
# kernel has booted -- see src/user/compositor/selftest.pdx's own
# header for the closest precedent (a one-function compositor-library
# smoke reached exactly this way).
#
# compositor-runner.elf is NOT yet wired into that seed+exec chain --
# doing so is out of this wave's five-item scope (build.sh flag +
# linker script + design docs + this wrapper + the pre-push hook, not
# a rootfs_seed.pdx / init.pdx change) and is tracked as the follow-up
# in design/testing/compositor-test-runner.md §4.
#
# Because that wiring is missing, THIS SCRIPT WOULD OTHERWISE FAIL ON
# EVERY INVOCATION -- and tools/.githooks/pre-push (Wave π π-05) calls
# it unconditionally whenever a push touches compositor code, which
# would make every future compositor commit unpushable until the gap
# closes. That is a worse defect than the one this wave is landing
# infrastructure to catch, so a preflight WIRED-check (below) runs
# before ever touching QEMU: if no boot-path source
# (src/user/init.pdx, src/user/rootfs_seed.pdx) references the runner
# by name, the suite prints SKIP and this script's own overall exit
# code stays 0 (does not block the caller) -- same "prerequisite not
# ready yet, don't fail the push over it" posture .githooks/pre-push
# already uses for e.g. its mkfs-pdxb-binary-missing preflight (rc 3)
# and the real-HW smoke's fingerprint-not-seeded case (rc 77); a SKIP
# is reported loudly on stdout, never swallowed silently. Once the
# embed+exec wiring lands (and references the runner's path/name
# somewhere in one of those two files, as any such wiring necessarily
# would), the preflight starts finding it, the SKIP branch stops
# firing, and this script starts actually booting + grepping for real
# -- no further change to this file needed.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BUILD_DIR="${REPO_ROOT}/build"
RUN_QEMU="${REPO_ROOT}/tools/run-qemu.sh"

# Bounded wait per suite -- mirrors tools/run-smoke.sh's own per-mode
# timeout convention (5-15s for the existing boot fixtures); a fresh
# suite gets a slightly more generous default since 20 pure-compute
# witnesses plus the surrounding kernel boot is more serial output
# than a single-fingerprint boot smoke. Override via env for a slow
# host.
TIMEOUT_S="${RUN_QEMU_TESTS_TIMEOUT:-30}"

# --- suite registry -----------------------------------------------------
# suite name -> runner ELF path -> summary-line prefix (grep, literal,
# no wildcards -- same ordered-substring discipline tools/run-smoke.sh
# uses for its own golden matching).
declare -A SUITE_ELF
declare -A SUITE_PREFIX
declare -A SUITE_WIRED_MARKER
SUITE_ELF[compositor]="${BUILD_DIR}/tests/compositor-runner.elf"
SUITE_PREFIX[compositor]="COMPOSITOR TESTS: "
# Grepped (fixed-string) against src/user/init.pdx + src/user/
# rootfs_seed.pdx to decide whether the boot path actually reaches
# this runner yet -- see the KNOWN GAP note above. Any real embed+exec
# wiring necessarily names the runner somewhere in one of those two
# files, so this is a reliable "has that follow-up landed" probe
# without hardcoding assumptions about ITS eventual shape.
SUITE_WIRED_MARKER[compositor]="compositor-runner"

# postui-desktop's runner does not exist yet (design/testing/
# kernel-test-runner.md §4 tracks it as a gap: the 5 existing
# tests/kernel/postui-desktop/*.pdx witnesses use real syscalls and
# per-file bespoke naming, not yet the uniform test_<name>_run shape a
# test_harness/main.pdx could dispatch generically). Registered here
# so this script's suite list, help text, and exit-code contract are
# already correct the day that runner lands -- adding it then is a
# two-line diff (an ELF path + a prefix), not a rewrite of this script.
SUITE_ELF[postui-desktop]="${BUILD_DIR}/tests/postui-desktop-runner.elf"
SUITE_PREFIX[postui-desktop]="POSTUI-DESKTOP TESTS: "
SUITE_WIRED_MARKER[postui-desktop]="postui-desktop-runner"

ALL_SUITES=(compositor postui-desktop)

# --- arg parsing ---------------------------------------------------------
REQUESTED=()
for arg in "$@"; do
    case "${arg}" in
        --compositor)
            REQUESTED+=(compositor)
            ;;
        --postui-desktop)
            REQUESTED+=(postui-desktop)
            ;;
        --help|-h)
            cat <<HELPEOF
tools/run-qemu-tests.sh -- boot kernel-test-runner ELFs, check summary fingerprints.

Usage: tools/run-qemu-tests.sh [--compositor] [--postui-desktop]

No suite flag runs every known suite (currently: ${ALL_SUITES[*]}).
Each suite requires its runner ELF to already be built:
  bash tools/build.sh --compositor-tests   # build/tests/compositor-runner.elf

Env:
  RUN_QEMU_TESTS_TIMEOUT=<seconds>   Per-suite QEMU wall-clock bound (default 30).
HELPEOF
            exit 0
            ;;
        *)
            echo "run-qemu-tests.sh: unrecognized argument '${arg}'" >&2
            exit 2
            ;;
    esac
done
if [[ ${#REQUESTED[@]} -eq 0 ]]; then
    REQUESTED=("${ALL_SUITES[@]}")
fi

# --- run each requested suite ---------------------------------------------
OVERALL_FAIL=0
ANY_SKIPPED=0

for suite in "${REQUESTED[@]}"; do
    elf="${SUITE_ELF[${suite}]}"
    prefix="${SUITE_PREFIX[${suite}]}"
    marker="${SUITE_WIRED_MARKER[${suite}]}"

    echo "[run-qemu-tests] ${suite}: checking ${elf#"${REPO_ROOT}"/}"

    # Preflight: is this suite's runner actually reachable from the
    # boot path yet? See the KNOWN GAP note above. A missing marker
    # means "not wired yet" -- SKIP, not FAIL, so a push touching
    # compositor code is never blocked on a follow-up integration step
    # this wave's five items do not include.
    if ! grep -Fq "${marker}" \
            "${REPO_ROOT}/src/user/init.pdx" \
            "${REPO_ROOT}/src/user/rootfs_seed.pdx" 2>/dev/null; then
        echo "[run-qemu-tests] SKIP ${suite}: not yet wired into the boot path"
        echo "  (no reference to '${marker}' in src/user/init.pdx or src/user/rootfs_seed.pdx --"
        echo "   see design/testing/compositor-test-runner.md §4 for the tracked follow-up)"
        ANY_SKIPPED=1
        continue
    fi

    if [[ ! -f "${elf}" ]]; then
        echo "[run-qemu-tests] FAIL ${suite}: runner ELF not built (${elf#"${REPO_ROOT}"/} missing)" >&2
        if [[ "${suite}" == "compositor" ]]; then
            echo "  build it first: bash tools/build.sh --compositor-tests" >&2
        fi
        OVERALL_FAIL=1
        continue
    fi

    LOG="$(mktemp)"
    # NOTE: boots the real kernel (build/kernel.elf) -- see this file's
    # own header KNOWN GAP note. ${elf} is not itself passed to QEMU;
    # its existence is checked above as a build-prerequisite gate, and
    # its serial fingerprint is what this loop greps for once the
    # embed+exec wiring (tracked follow-up) makes the kernel actually
    # run it during boot.
    if ! timeout "${TIMEOUT_S}s" "${RUN_QEMU}" < /dev/null > "${LOG}" 2>&1; then
        rc=$?
        if [[ ${rc} -eq 124 ]]; then
            echo "[run-qemu-tests] FAIL ${suite}: QEMU timed out after ${TIMEOUT_S}s" >&2
        else
            echo "[run-qemu-tests] FAIL ${suite}: tools/run-qemu.sh exited ${rc}" >&2
        fi
        OVERALL_FAIL=1
        rm -f "${LOG}"
        continue
    fi

    SUMMARY_LINE="$(grep -F "${prefix}" "${LOG}" | tail -1 || true)"
    rm -f "${LOG}"

    if [[ -z "${SUMMARY_LINE}" ]]; then
        echo "[run-qemu-tests] FAIL ${suite}: fingerprint '${prefix}' not found on serial log" >&2
        OVERALL_FAIL=1
        continue
    fi

    # Expected shape: "<PREFIX><pass> passed / <fail> failed"
    REST="${SUMMARY_LINE#"${prefix}"}"
    PASS_N="${REST%% passed*}"
    FAIL_N="${REST#* passed / }"
    FAIL_N="${FAIL_N%% failed*}"

    if [[ ! "${FAIL_N}" =~ ^[0-9]+$ ]] || [[ "${FAIL_N}" != "0" ]]; then
        echo "[run-qemu-tests] FAIL ${suite}: ${SUMMARY_LINE}" >&2
        OVERALL_FAIL=1
        continue
    fi

    echo "[run-qemu-tests] PASS ${suite}: ${PASS_N} passed / ${FAIL_N} failed"
done

if [[ ${OVERALL_FAIL} -ne 0 ]]; then
    echo "[run-qemu-tests] one or more suites failed" >&2
    exit 1
fi

if [[ ${ANY_SKIPPED} -ne 0 ]]; then
    echo "[run-qemu-tests] no failures; one or more suites skipped (not yet wired -- see above)"
    exit 0
fi

echo "[run-qemu-tests] all requested suites passed"
exit 0
