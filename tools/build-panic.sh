#!/usr/bin/env bash
# Build the PaideiaOS panic kernel.
# M8-001 (#706): Dedicated build for kernel-panic.elf that links panic entry point.
#
# Invokes paideia-as on every .pdx file under src/kernel/, links the
# resulting objects via src/kernel/link-panic.ld using boot_stub_panic.S,
# produces build/kernel-panic.elf.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PAIDEIA_AS="$("${REPO_ROOT}/tools/find-paideia-as.sh")"
BUILD_DIR="${REPO_ROOT}/build"
KERNEL_SRC="${REPO_ROOT}/src/kernel"
LINK_SCRIPT="${KERNEL_SRC}/link-panic.ld"

if [[ ! -f "${LINK_SCRIPT}" ]]; then
    echo "linker script missing: ${LINK_SCRIPT}" >&2
    exit 1
fi

mkdir -p "${BUILD_DIR}"

echo "[build-user] ensuring build/user/shell.bin (R15-M1-007 embed prerequisite)"
"${REPO_ROOT}/tools/build-user.sh"

echo "[boot-stub-panic] tools/boot_stub_panic.S -> boot_stub_panic.o (32+64-bit, as --64)"
BOOT_STUB_OBJ="${BUILD_DIR}/boot_stub_panic.o"
as --64 -o "${BOOT_STUB_OBJ}" "${KERNEL_SRC}/boot_panic/boot_stub_panic.S"

echo "[userbin] tools/userbin_embed.S -> userbin_embed.o"
USERBIN_OBJ="${BUILD_DIR}/userbin_embed.o"
( cd "${REPO_ROOT}" && as --64 -o "${USERBIN_OBJ}" tools/userbin_embed.S )

OBJECTS=()
while IFS= read -r -d '' pdx; do
    rel="${pdx#"${KERNEL_SRC}"/}"
    obj="${BUILD_DIR}/${rel%.pdx}.o"
    mkdir -p "$(dirname "${obj}")"
    echo "[build] paideia-as ${rel} -> ${obj#"${BUILD_DIR}"/}"
    "${PAIDEIA_AS}" build --emit elf64 "${pdx}" -o "${obj}"
    OBJECTS+=("${obj}")
done < <(find "${KERNEL_SRC}" -name '*.pdx' -print0 | sort -z)

OBJECTS=( "${BOOT_STUB_OBJ}" "${USERBIN_OBJ}" "${OBJECTS[@]}" )

if [[ ${#OBJECTS[@]} -eq 0 ]]; then
    echo "no .pdx files found under ${KERNEL_SRC}" >&2
    exit 1
fi

echo "[link] ld -T link-panic.ld -> kernel-panic.elf"
ld -nostdlib --warn-common --fatal-warnings -T "${LINK_SCRIPT}" -o "${BUILD_DIR}/kernel-panic.elf" "${OBJECTS[@]}"

echo "[audit] R_X86_64_32 relocations must not target high-VA (>= 0xffff800000000000) symbols"

NM_MAP="${BUILD_DIR}/.nm-panic.map"
SEC_MAP="${BUILD_DIR}/.sec-panic.map"

nm build/kernel-panic.elf | awk 'NF>=3 {print $3, $1}' > "${NM_MAP}"
readelf -SW build/kernel-panic.elf \
    | awk '$2 ~ /^[0-9]+\]$/ && $3 != "NULL" {print $3, $5}' > "${SEC_MAP}"

AUDIT_FAIL=0
for obj in "${OBJECTS[@]}"; do
    while IFS= read -r target; do
        [[ -z "${target}" ]] && continue
        if [[ "${target}" == .* ]]; then
            vma=$(awk -v s="${target}" '$1==s {print $2; exit}' "${SEC_MAP}")
        else
            vma=$(awk -v s="${target}" '$1==s {print $2; exit}' "${NM_MAP}")
        fi
        [[ -z "${vma}" ]] && continue
        if [[ "${vma}" == ffff8* ]]; then
            echo "[audit] FAIL: ${obj#"${BUILD_DIR}"/}: R_X86_64_32 -> ${target} @ 0x${vma}" >&2
            AUDIT_FAIL=1
        fi
    done < <(readelf -r "${obj}" 2>/dev/null \
             | awk '$3 == "R_X86_64_32" || $3 == "R_X86_64_32S" {print $5}' \
             | sort -u)
done

if [[ ${AUDIT_FAIL} -ne 0 ]]; then
    echo "[audit] R_X86_64_32 high-VA audit failed — see #490 census, #494 policy" >&2
    exit 1
fi
echo "[audit] R_X86_64_32 relocations clean (all targets low-VA)"

echo "[ok] ${BUILD_DIR}/kernel-panic.elf"
