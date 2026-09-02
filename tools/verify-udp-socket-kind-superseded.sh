#!/usr/bin/env bash
# tools/verify-udp-socket-kind-superseded.sh -- R93.M2-001 (paideia-os #2049)
#
# Build-time grep gate: the pre-R30-numbering-scheme
# UdpSocketCap.KIND_UDP_SOCKET = 0x50 is DEPRECATED (R100-PREP-002
# #2008 retirement banner in src/kernel/core/cap/udp_socket_cap.pdx).
# No new code outside udp_socket_cap.pdx may declare or read
# KIND_UDP_SOCKET as 0x50 -- the modern value is
# Kind.KIND_UDP_SOCKET = 0x1A8 (net/udp_socket.pdx, cap/kind.pdx).
#
# A stale reference must FAIL LOUDLY here rather than silently alias
# the new meaning through module-level constant shadowing.
#
# Allowed occurrences (all in the deprecation-banner file):
#   src/kernel/core/cap/udp_socket_cap.pdx
#
# Everything else that pairs `KIND_UDP_SOCKET` with `0x50` on the
# same line (or within a 3-line window) exits non-zero and names the
# offending file so the author can update the value to 0x1A8 or move
# the code to the modern KIND_UDP_SOCKET semantics.
#
# Exit codes:
#   0 - clean (no offending references outside the allowlist)
#   1 - stale reference found
#   2 - script misuse
set -uo pipefail

if [[ $# -gt 0 ]]; then
    echo "usage: $0" >&2
    exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_ROOT="${REPO_ROOT}/src"

if [[ ! -d "${SRC_ROOT}" ]]; then
    echo "[verify-udp-socket-kind-superseded] src/ tree missing at ${SRC_ROOT}" >&2
    exit 2
fi

ALLOWED_FILE="src/kernel/core/cap/udp_socket_cap.pdx"

# Find every .pdx file under src/kernel that mentions KIND_UDP_SOCKET
# on the same line as 0x50 (with or without decoration). Use plain
# grep to keep the check portable across GNU/BSD grep.
STALE=$(
    grep -RIl --include='*.pdx' 'KIND_UDP_SOCKET' "${SRC_ROOT}" 2>/dev/null \
    | while IFS= read -r f; do
        if grep -q -E 'KIND_UDP_SOCKET.*0x50|0x50.*KIND_UDP_SOCKET' "$f"; then
            rel="${f#${REPO_ROOT}/}"
            if [[ "$rel" != "$ALLOWED_FILE" ]]; then
                printf '%s\n' "$rel"
            fi
        fi
    done
)

if [[ -n "$STALE" ]]; then
    echo "[verify-udp-socket-kind-superseded] STALE KIND_UDP_SOCKET=0x50 references found:" >&2
    echo "$STALE" >&2
    echo "" >&2
    echo "The pre-R30 KIND_UDP_SOCKET=0x50 value is retired." >&2
    echo "Modern value: Kind.KIND_UDP_SOCKET = 0x1A8 (net/udp_socket.pdx)." >&2
    echo "See src/kernel/core/cap/udp_socket_cap.pdx for the retirement banner." >&2
    exit 1
fi

echo "[verify-udp-socket-kind-superseded] clean (no stale 0x50 references outside allowlist)"
exit 0
