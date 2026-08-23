#!/usr/bin/env bash
# tools/verify-r53-image-lifecycle.sh — R53.M4-002 (#1749)
#
# WHAT THIS POLICES
#
# The #1749 image-lifecycle block in tools/run-smoke.sh is the choke
# point between the --with-disk / --wipe flag pair (#1748 parser),
# the mkfs-pdxb.sh dev-host wrapper (#1731), and the QEMU -drive /
# -device attach that both `--with-disk` smoke launches (UART-RX
# variant + default/SMP variant) rely on. It has three invariants
# that, if broken, silently degrade the smoke to "attach a raw-zeros
# image and hope no one notices":
#
#   1. The block must call tools/mkfs-pdxb.sh. A regression that
#      inlined dd-only provisioning (like the legacy NVME_MODE=1
#      path does) would attach an image without a valid PDXB
#      superblock; the kernel probe (§4.2 of
#      design/tooling/volume-lifecycle-mechanism.md) would reject it
#      with BAD_MAGIC and the smoke would fall back to tmpfs —
#      still passing every OTHER golden, but never actually
#      exercising the disk path.
#
#   2. The block must read WITH_DISK and WIPE_DISK — the exact
#      variables the #1748 flag parser writes (parser at run-smoke.sh
#      near line 93). A rename on either side would silently make
#      --wipe a no-op (mkfs-on-missing still fires, but repeated
#      developer sessions never actually re-mkfs across content
#      corruption).
#
#   3. The DISK_ARGS array the block builds must be threaded into
#      BOTH QEMU launches. The UART-RX variant (chardev-pipe serial)
#      and the default/SMP variant are separate `timeout ... qemu-
#      system-x86_64 \` invocations; dropping DISK_ARGS from either
#      silently disables --with-disk for every smoke mode that goes
#      through that branch. UART_RX_MODE=1 is set by every R17.M5
#      interactive-shell mode and by the R16 UART RX mode, so a
#      missing thread would make any composed shell+disk smoke
#      pointless.
#
# Also asserts the default DISK_IMAGE_PATH follows the R53 task-spec
# fallback ladder — CLAUDE_JOB_DIR/tmp scratch first, /tmp path
# second — so parallel Claude jobs cannot stomp each other's image.
#
# Exit status: 0 on all checks green; 1 on any check failing.

set -uo pipefail

if REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    :
else
    REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fi
SMOKE="${REPO_ROOT}/tools/run-smoke.sh"

if [[ ! -r "${SMOKE}" ]]; then
    echo "verify-r53-image-lifecycle: cannot read ${SMOKE}" >&2
    exit 1
fi

fail() {
    echo "verify-r53-image-lifecycle: FAIL — $1" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# 1. Block calls tools/mkfs-pdxb.sh (invariant #1 above).
# ---------------------------------------------------------------------------

if ! grep -q 'tools/mkfs-pdxb\.sh' "${SMOKE}"; then
    fail "run-smoke.sh does not invoke tools/mkfs-pdxb.sh — the --with-disk lifecycle would attach a raw-zeros image and the kernel probe would reject it with BAD_MAGIC (falling back to tmpfs and silently defeating the smoke)"
fi

# ---------------------------------------------------------------------------
# 2. Block reads WITH_DISK + WIPE_DISK — the exact names #1748 writes.
# ---------------------------------------------------------------------------

if ! grep -Eq '\bWITH_DISK\b' "${SMOKE}"; then
    fail "run-smoke.sh has no WITH_DISK reference — the #1748 flag parser writes it; the #1749 lifecycle block must read it"
fi

if ! grep -Eq '\bWIPE_DISK\b' "${SMOKE}"; then
    fail "run-smoke.sh has no WIPE_DISK reference — the #1748 flag parser writes it on --wipe; the #1749 lifecycle block must read it to honor --wipe"
fi

# The parser must actually set both on the flag branches. Cheap check
# for the paired assignment lines (guards against a rename on the
# parser side).
if ! grep -q 'WITH_DISK=1' "${SMOKE}"; then
    fail "run-smoke.sh parser never sets WITH_DISK=1 — the --with-disk flag would not trigger the lifecycle block"
fi
if ! grep -q 'WIPE_DISK=1' "${SMOKE}"; then
    fail "run-smoke.sh parser never sets WIPE_DISK=1 — the --wipe flag would not trigger a re-mkfs"
fi

# ---------------------------------------------------------------------------
# 3. DISK_ARGS threaded into BOTH QEMU launches (invariant #3 above).
# ---------------------------------------------------------------------------

qemu_launch_count=$(grep -c '^\s*timeout \${TIMEOUT} qemu-system-x86_64 \\$' "${SMOKE}" || true)
if [[ "${qemu_launch_count}" -ne 2 ]]; then
    fail "expected exactly 2 QEMU launches in run-smoke.sh (UART-RX variant + default/SMP variant); found ${qemu_launch_count}. If a launch was refactored, this check needs to move with it."
fi

disk_args_thread_count=$(grep -c '"\${DISK_ARGS\[@\]}"' "${SMOKE}" || true)
if [[ "${disk_args_thread_count}" -lt 2 ]]; then
    fail "DISK_ARGS is threaded into fewer than 2 QEMU launches (found ${disk_args_thread_count}); --with-disk would be a no-op for the un-threaded launch"
fi

# ---------------------------------------------------------------------------
# 4. Default DISK_IMAGE_PATH follows the CLAUDE_JOB_DIR-first ladder.
# ---------------------------------------------------------------------------

if ! grep -q 'CLAUDE_JOB_DIR' "${SMOKE}"; then
    fail "run-smoke.sh has no CLAUDE_JOB_DIR reference — the #1749 spec puts the per-job scratch image under \${CLAUDE_JOB_DIR}/tmp so parallel jobs cannot stomp each other's image"
fi

if ! grep -q '/tmp/paideia-pdxb-smoke\.img' "${SMOKE}"; then
    fail "run-smoke.sh missing /tmp/paideia-pdxb-smoke.img fallback — the #1749 spec's second-tier default for non-job (developer shell) invocations"
fi

# ---------------------------------------------------------------------------
# 5. exit-3 diagnostic path from mkfs-pdxb.sh is handled explicitly.
# ---------------------------------------------------------------------------

# mkfs-pdxb.sh returns 3 when the mkfs-pdxb binary (#1730) is not built
# yet. The lifecycle block must catch that specifically and print a
# pointer at R53.M1-001 (#1730), not just a generic "mkfs failed" —
# the difference matters when a partial checkout has the wrapper but
# not the binary and the developer is trying to figure out what to
# build next.
if ! grep -Eq '\$\{?mkfs_rc\}?[[:space:]]+-eq[[:space:]]+3' "${SMOKE}"; then
    fail "run-smoke.sh does not special-case mkfs-pdxb.sh exit code 3 (binary not built yet) — the diagnostic path documented in mkfs-pdxb.sh line 44-46 would collapse into a generic failure"
fi

# ---------------------------------------------------------------------------
# All checks passed.
# ---------------------------------------------------------------------------

echo "verify-r53-image-lifecycle: OK (mkfs-pdxb.sh wired; WITH_DISK/WIPE_DISK read; DISK_ARGS threaded into both QEMU launches; CLAUDE_JOB_DIR default + /tmp fallback present; exit-3 diagnostic path preserved)"
exit 0
