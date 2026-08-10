#!/usr/bin/env bash
# tools/verify-atomics.sh — R18-M3-003 / #770
#
# Byte-level witness that src/kernel/core/sync/atomic.pdx encodes the
# LOCK CMPXCHG / LOCK XADD / XCHG / MFENCE mnemonics to their Intel-SDM
# canonical byte sequences after the full paideia-as -> ELF -> objdump
# round trip.
#
# What this catches (that paideia-as's own unit tests do NOT):
#   - a regression in the tools/paideia-as submodule pin that ships a
#     broken encoder for one of these mnemonics without the paideia-as
#     unit tests being run,
#   - a surrounding compiled-context change (register-allocator picking
#     a different scratch register, prologue insertion, effect-lowering
#     inserting an extra instruction) that silently perturbs the emitted
#     bytes for a kernel primitive whose byte layout is load-bearing for
#     the atomic contract (e.g., an "F0 REX.W" that becomes "REX.W" with
#     no LOCK — the instruction still assembles, still runs, and silently
#     loses cross-CPU atomicity).
#
# Complementary to opcode-canary.sh: that script catches BinOp miscompiles
# in scalar arithmetic (AND vs ADD); this one catches atomic-mnemonic
# regressions in the same style but for the SMP substrate.
#
# Expected fixtures: tests/kernel/atomics/expected-bytes.txt
# Format per line: SYMBOL|EXPECTED_HEX|DESCRIPTION
#
# Exit codes:
#   0 — all assertions pass
#   1 — one or more assertions fail
#   2 — build failed (kernel did not compile)
#   3 — fixture missing / malformed

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
FIXTURE="${REPO_ROOT}/tests/kernel/atomics/expected-bytes.txt"
OBJ="${REPO_ROOT}/build/core/sync/atomic.o"

if [[ ! -f "${FIXTURE}" ]]; then
    echo "verify-atomics: FAIL fixture not found: ${FIXTURE}" >&2
    exit 3
fi

# Build if the object is missing or stale w.r.t. the source. The build
# invocation matches opcode-canary.sh: silence normal chatter, surface
# only failure.
if [[ ! -f "${OBJ}" ]] \
   || [[ "${REPO_ROOT}/src/kernel/core/sync/atomic.pdx" -nt "${OBJ}" ]]; then
    "${REPO_ROOT}/tools/build.sh" >/dev/null 2>&1 || {
        echo "verify-atomics: build failed" >&2
        exit 2
    }
fi

if [[ ! -f "${OBJ}" ]]; then
    echo "verify-atomics: FAIL object not found after build: ${OBJ}" >&2
    exit 2
fi

fail=0
checked=0
while IFS='|' read -r symbol expected_hex description; do
    # Skip comments and blank lines.
    [[ -z "${symbol}" || "${symbol}" =~ ^[[:space:]]*# ]] && continue

    if [[ -z "${expected_hex}" ]]; then
        echo "verify-atomics: FAIL malformed fixture row for symbol=${symbol}" >&2
        fail=1
        continue
    fi

    dis=$(objdump -d --disassemble="${symbol}" "${OBJ}" 2>/dev/null)
    if [[ -z "${dis}" ]]; then
        echo "verify-atomics: FAIL symbol not found: ${symbol}" >&2
        fail=1
        continue
    fi

    # objdump prints the raw bytes column between the address (col 1)
    # and the mnemonic (col 3+), tab-separated. Grep the whole
    # disassembly for the expected byte sequence: -F for fixed-string
    # match (no regex surprises with hex like "0f"), single lookup per
    # symbol keeps the script fast.
    if ! grep -qF "${expected_hex}" <<<"${dis}"; then
        echo "verify-atomics: FAIL ${symbol}: missing bytes '${expected_hex}' (${description})" >&2
        echo "  actual disassembly:" >&2
        sed 's/^/    /' <<<"${dis}" >&2
        fail=1
        continue
    fi

    checked=$((checked + 1))
done < "${FIXTURE}"

if [[ ${fail} -eq 0 ]]; then
    echo "verify-atomics: OK ${checked}/${checked} byte assertions passed"
fi

exit "${fail}"
