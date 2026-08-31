#!/usr/bin/env bash
# tools/compile-one.sh — one paideia-as invocation, safe under xargs -P.
#
# Called by tools/build.sh's parallel compile loop (perf #3). Arguments:
#   $1  absolute path to source .pdx
#   $2  path prefix to strip when computing the .o location
#       (KERNEL_SRC for kernel .pdx, REPO_ROOT for tests/kernel .pdx)
#
# Environment (inherited from parent build.sh):
#   PAIDEIA_AS       — compiler binary
#   BUILD_DIR        — build output root
#   BUILD_SH         — the parent build.sh path (dependency mtime check)
#   NO_INCREMENTAL   — if non-empty, always compile
#
# Exit non-zero on any failure; parent xargs propagates that.

set -euo pipefail

pdx="$1"
strip_prefix="$2"

rel="${pdx#"${strip_prefix}"/}"
obj="${BUILD_DIR}/${rel%.pdx}.o"

mkdir -p "$(dirname "${obj}")"

if [[ -z "${NO_INCREMENTAL:-}" \
      && -f "${obj}" \
      && ! "${pdx}" -nt "${obj}" \
      && ! "${BUILD_SH}" -nt "${obj}" \
      && ! "${PAIDEIA_AS}" -nt "${obj}" ]]; then
    exit 0
fi

echo "[build] paideia-as ${rel} -> ${obj#"${BUILD_DIR}"/}"
"${PAIDEIA_AS}" build --emit elf64 "${pdx}" -o "${obj}"
