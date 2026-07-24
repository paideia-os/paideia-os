#!/usr/bin/env bash
# Reproducibility canary for kernel builds (#669).
# Runs three clean builds; asserts byte-identical build/kernel.elf across all.
# Root cause is paideia-as #1253 (SparseSideTable HashMap iteration order).
# Until that lands + submodule bumps, this test will FAIL — which is the point.
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

HASHES=()
for i in 1 2 3; do
    echo "[repro] clean build $i/3..."
    rm -rf build
    if ! ./tools/build.sh >/dev/null 2>&1; then
        echo "[repro] FAIL — build $i itself failed"
        exit 2
    fi
    if [[ ! -f build/kernel.elf ]]; then
        echo "[repro] FAIL — build/kernel.elf missing after build $i"
        exit 2
    fi
    H=$(sha256sum build/kernel.elf | awk '{print $1}')
    HASHES+=("$H")
    echo "[repro] build $i sha256: $H"
done

# Assert all three hashes match
FIRST="${HASHES[0]}"
FAIL=0
for i in 1 2; do
    if [[ "${HASHES[$i]}" != "$FIRST" ]]; then
        FAIL=1
        break
    fi
done

if [[ $FAIL -eq 0 ]]; then
    echo "REPRODUCIBILITY OK ($FIRST)"
    exit 0
else
    echo "REPRODUCIBILITY FAIL — three-way hash mismatch:"
    printf '  build 1: %s\n' "${HASHES[0]}"
    printf '  build 2: %s\n' "${HASHES[1]}"
    printf '  build 3: %s\n' "${HASHES[2]}"
    echo "Root cause: paideia-as #1253 (SparseSideTable HashMap iteration)."
    echo "Fix path: upstream paideia-as fix + submodule bump."
    exit 1
fi
