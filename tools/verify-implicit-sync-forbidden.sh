#!/usr/bin/env bash
# tools/verify-implicit-sync-forbidden.sh -- G1.M1-005 (#1431) +
# G1.M3-005 (#1441)
#
# P1 INVARIANT ENFORCEMENT: no code path in the paideia-os tree
# may commit a frame or present a buffer without pairing that
# handoff with a KIND_DISPLAY_TIMELINE (timeline_id, value). The
# G-round rests on P1; without a structural refusal this script
# encodes, a future patch could silently bring implicit sync back
# and every subsequent modeset would tear.
#
# TWO CHECKS:
#
# (1) FORBIDDEN SYMBOLS. The set of legacy DRM-era symbols whose
#     mere presence is a P1 violation because their semantics
#     REQUIRE implicit sync:
#
#         commit_frame_no_sync    (any DRM implicit-fence commit)
#         present_now_implicit    (any implicit-fence present)
#         drmModePageFlip         (DRM legacy page-flip API)
#         atomic_commit_nofence   (atomic without explicit fence)
#
#     Any .pdx file containing any of these tokens fails the
#     build. The set is enumerated (not a regex on "sync") so a
#     legitimate identifier like "no_implicit_sync_here" is not
#     flagged.
#
# (2) COMMIT/PRESENT PAIRING. Every source file that defines a
#     symbol matching `commit_frame` or `present_flush` must also
#     reference `KIND_DISPLAY_TIMELINE` or `dpt_row_signal` or
#     `dpy_timeline_wait_le` in the same file. This is the coarse
#     structural check that keeps the P1 argument honest without
#     needing a real semantic analyzer -- a file that commits a
#     frame without touching the timeline substrate is by
#     construction implicit.
#
# EXEMPTIONS: the two files that IMPLEMENT the primitive
# themselves (kind_display_timeline.pdx and drivers/dpy/timeline
# .pdx) are exempted from check (2) -- they define the substrate
# rather than consume it.
#
# THE SCRIPT IS ADVISORY UNTIL LANDED IN build.sh, at which point
# a fail exits non-zero and the build refuses to link. Standalone
# invocation:
#
#   bash tools/verify-implicit-sync-forbidden.sh
#
# See G1.M1-005 (#1431) and G1.M3-005 (#1441) for the argument.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${REPO_ROOT}/src"

# The exempt files (implementing the substrate).
EXEMPT_COMMIT_PAIRING=(
    "src/kernel/core/cap/kind_display_timeline.pdx"
    "src/kernel/core/drivers/dpy/timeline.pdx"
    "src/kernel/core/ipc/display_sync_channel.pdx"
    "src/kernel/core/drivers/dpy/atomic_commit.pdx"
    "src/kernel/core/drivers/dpy/vrr.pdx"
    "src/kernel/core/ipc/vrr_channel.pdx"
    "src/kernel/core/ipc/modeset_channel.pdx"
    "src/kernel/core/cap/kind_modeset_txn.pdx"
)

# The forbidden symbols. Any file containing any of these tokens
# is a P1 violation.
FORBIDDEN_SYMBOLS=(
    "commit_frame_no_sync"
    "present_now_implicit"
    "drmModePageFlip"
    "atomic_commit_nofence"
)

FAIL=0

# CHECK 1: forbidden symbols.
for sym in "${FORBIDDEN_SYMBOLS[@]}"; do
    hits=$(grep -rln "${sym}" "${SRC}" 2>/dev/null || true)
    if [[ -n "${hits}" ]]; then
        echo "[implicit-sync-forbidden] FAIL: forbidden symbol '${sym}' found:" >&2
        echo "${hits}" | sed 's/^/    /' >&2
        FAIL=1
    fi
done

# CHECK 2: commit / present pairing.
#
# For every file defining a `commit_frame` or `present_flush`
# symbol that is NOT on the exempt list, require the file to
# also reference KIND_DISPLAY_TIMELINE or dpt_row_signal or
# dpy_timeline_wait_le.
while IFS= read -r pdx; do
    rel="${pdx#"${REPO_ROOT}/"}"

    # Skip exempt.
    for ex in "${EXEMPT_COMMIT_PAIRING[@]}"; do
        if [[ "${rel}" == "${ex}" ]]; then
            continue 2
        fi
    done

    if ! grep -qE 'commit_frame|present_flush' "${pdx}"; then
        continue
    fi

    if ! grep -qE 'KIND_DISPLAY_TIMELINE|dpt_row_signal|dpy_timeline_wait_le' "${pdx}"; then
        echo "[implicit-sync-forbidden] FAIL: ${rel} commits or presents a" >&2
        echo "    frame but does not reference the KIND_DISPLAY_TIMELINE" >&2
        echo "    substrate. P1 (no implicit sync) requires every buffer" >&2
        echo "    handoff to name a (timeline_id, value)." >&2
        echo "    See design/roadmap/next-wave-synthesis.md §4 P1." >&2
        FAIL=1
    fi
done < <(find "${SRC}" -name '*.pdx')

if [[ ${FAIL} -ne 0 ]]; then
    echo "[implicit-sync-forbidden] one or more P1 violations found. Refusing." >&2
    exit 1
fi

echo "[implicit-sync-forbidden] P1 acceptance clean (no implicit-sync code paths)"
