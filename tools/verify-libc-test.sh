#!/usr/bin/env bash
# Build-time integration verifier for R17.M1 libc-lite user primitives.
# Runs all R17.M1-phase canaries (verify-user-string.sh, verify-user-errno.sh,
# verify-syscall-shim.sh, verify-user-io.sh) and emits "LIBC TEST OK" if all pass.
# This serves as a build-time closure check that complements the in-kernel witness.
# Exit status: 0 (success, all verifiers pass) or 1 (any verifier fails).
set -euo pipefail

ELF="${1:-build/user/shell.elf}"

if [[ ! -f "$ELF" ]]; then
    echo "R17 LIBC TEST FAIL" >&2
    echo "ELF file not found: $ELF" >&2
    exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
TOOLS_DIR="${REPO_ROOT}/tools"

# Array of verifiers that comprise the full R17.M1 libc-lite test suite.
VERIFIERS=(
    "verify-syscall-shim.sh"
    "verify-user-string.sh"
    "verify-user-errno.sh"
    "verify-user-io.sh"
)

echo "[libc-test] Running R17.M1 verifier chain..."
FAIL=0

for verifier in "${VERIFIERS[@]}"; do
    verifier_path="${TOOLS_DIR}/${verifier}"
    if [[ ! -f "$verifier_path" ]]; then
        echo "[FAIL] verifier not found: $verifier_path" >&2
        FAIL=1
        continue
    fi

    echo "[libc-test] invoking $verifier..."
    if ! "$verifier_path" "$ELF"; then
        echo "[FAIL] $verifier failed" >&2
        FAIL=1
    fi
done

if (( FAIL == 0 )); then
    echo "LIBC TEST OK"
    exit 0
else
    echo "R17 LIBC TEST FAIL" >&2
    exit 1
fi
