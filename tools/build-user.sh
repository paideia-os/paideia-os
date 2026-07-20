#!/usr/bin/env bash
# Build the PaideiaOS user shell binary (R15-m1-003 / #515).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PAIDEIA_AS="$("${REPO_ROOT}/tools/find-paideia-as.sh")"
USER_SRC="${REPO_ROOT}/src/user"
BUILD_DIR="${REPO_ROOT}/build/user"
LINK_SCRIPT="${USER_SRC}/link.ld"

if [[ ! -f "${LINK_SCRIPT}" ]]; then
    echo "user linker script missing: ${LINK_SCRIPT}" >&2
    exit 1
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

OBJECTS=()
while IFS= read -r -d '' pdx; do
    rel="${pdx#"${USER_SRC}"/}"
    obj="${BUILD_DIR}/${rel%.pdx}.o"
    mkdir -p "$(dirname "${obj}")"
    echo "[build-user] paideia-as ${rel} -> ${obj#"${BUILD_DIR}"/}"
    "${PAIDEIA_AS}" build --emit elf64 "${pdx}" -o "${obj}"
    OBJECTS+=("${obj}")
done < <(find "${USER_SRC}" -name '*.pdx' -print0 | sort -z)

if [[ ${#OBJECTS[@]} -eq 0 ]]; then
    echo "no .pdx files found under ${USER_SRC}" >&2
    exit 1
fi

echo "[link-user] ld -T link.ld -> shell.elf"
ld -nostdlib --warn-common --fatal-warnings \
    -T "${LINK_SCRIPT}" \
    -o "${BUILD_DIR}/shell.elf" \
    "${OBJECTS[@]}"

echo "[objcopy-user] shell.elf -> shell.bin"
objcopy -O binary "${BUILD_DIR}/shell.elf" "${BUILD_DIR}/shell.bin"

echo "[verify-user] byte-pattern canary on shell.elf"
"${REPO_ROOT}/tools/verify-syscall-shim.sh" "${BUILD_DIR}/shell.elf"

echo "[verify-user] byte-shape canary on strlen/memcmp in shell.elf"
"${REPO_ROOT}/tools/verify-user-string.sh" "${BUILD_DIR}/shell.elf"

echo "[ok] ${BUILD_DIR}/shell.elf"
echo "[ok] ${BUILD_DIR}/shell.bin"
