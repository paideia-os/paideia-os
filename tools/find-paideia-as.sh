#!/usr/bin/env bash
# Locate the paideia-as binary the PaideiaOS build uses.
# Resolves to tools/paideia-as/target/release/paideia-as (git submodule).
# Verifies version >= 0.4.0.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SUBMODULE_BIN="${REPO_ROOT}/tools/paideia-as/target/release/paideia-as"
MIN_VERSION="0.4.0"

if [[ ! -d "${REPO_ROOT}/tools/paideia-as/.git" && ! -f "${REPO_ROOT}/tools/paideia-as/.git" ]]; then
    echo "paideia-as submodule not initialised" >&2
    echo "  run: git submodule update --init --recursive" >&2
    exit 1
fi

if [[ ! -f "${SUBMODULE_BIN}" ]]; then
    echo "paideia-as binary not built at ${SUBMODULE_BIN}" >&2
    echo "  build: (cd ${REPO_ROOT}/tools/paideia-as && cargo build --release -p paideia-as)" >&2
    exit 1
fi

VERSION=$("${SUBMODULE_BIN}" --version 2>/dev/null | awk '{print $NF}' || echo "unknown")
if [[ "${VERSION}" == "unknown" ]]; then
    echo "paideia-as binary at ${SUBMODULE_BIN} exists but --version failed" >&2
    exit 1
fi

# Lexicographic-sort-friendly: lowest first; MIN must come first if VERSION >= MIN.
LOWEST=$(printf '%s\n' "${MIN_VERSION}" "${VERSION}" | sort -V | head -1)
if [[ "${LOWEST}" != "${MIN_VERSION}" ]]; then
    echo "paideia-as ${VERSION} < ${MIN_VERSION}; rebuild submodule against a newer commit" >&2
    exit 1
fi

# Freshness gate: binary mtime must be >= submodule HEAD commit time.
# Prevents silent staleness when submodule advances but target/ wasn't rebuilt.
# (Surfaced by PA8-m1-002c #903: stale binary masqueraded as encoder bug.)
SUBMODULE_HEAD_TIME=$(git -C "${REPO_ROOT}/tools/paideia-as" log -1 --format=%ct HEAD 2>/dev/null || echo "0")
BINARY_TIME=$(stat -c %Y "${SUBMODULE_BIN}" 2>/dev/null || echo "0")
if [[ "${BINARY_TIME}" -lt "${SUBMODULE_HEAD_TIME}" ]]; then
    echo "paideia-as binary is older than submodule HEAD; rebuild required" >&2
    echo "  run: (cd ${REPO_ROOT}/tools/paideia-as && cargo build --release -p paideia-as)" >&2
    exit 1
fi

echo "${SUBMODULE_BIN}"
