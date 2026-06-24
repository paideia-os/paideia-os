#!/usr/bin/env bash
# Build the PaideiaOS kernel.
#
# Invokes paideia-as on every .pdx file under src/kernel/, links the
# resulting objects via src/kernel/link.ld, produces build/kernel.elf.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PAIDEIA_AS="$("${REPO_ROOT}/tools/find-paideia-as.sh")"
BUILD_DIR="${REPO_ROOT}/build"
KERNEL_SRC="${REPO_ROOT}/src/kernel"
LINK_SCRIPT="${KERNEL_SRC}/link.ld"

if [[ ! -f "${LINK_SCRIPT}" ]]; then
    echo "linker script missing: ${LINK_SCRIPT}" >&2
    exit 1
fi

mkdir -p "${BUILD_DIR}"

echo "[boot-stub] tools/boot_stub.S -> boot_stub.o (32+64-bit, as --64)"
BOOT_STUB_OBJ="${BUILD_DIR}/boot_stub.o"
as --64 -o "${BOOT_STUB_OBJ}" "${REPO_ROOT}/tools/boot_stub.S"

OBJECTS=()
while IFS= read -r -d '' pdx; do
    rel="${pdx#"${KERNEL_SRC}"/}"
    obj="${BUILD_DIR}/${rel%.pdx}.o"
    mkdir -p "$(dirname "${obj}")"
    echo "[build] paideia-as ${rel} -> ${obj#"${BUILD_DIR}"/}"
    "${PAIDEIA_AS}" build --emit elf64 "${pdx}" -o "${obj}"
    OBJECTS+=("${obj}")
done < <(find "${KERNEL_SRC}" -name '*.pdx' -print0 | sort -z)

OBJECTS=( "${BOOT_STUB_OBJ}" "${OBJECTS[@]}" )

if [[ ${#OBJECTS[@]} -eq 0 ]]; then
    echo "no .pdx files found under ${KERNEL_SRC}" >&2
    exit 1
fi

# Symbol export now provides uart_init/uart_puts definitions
# tools/stubs.S is no longer needed for linking
# echo "[stub] tools/stubs.S — Phase-7-in-progress link stubs"
# STUBS_OBJ="${BUILD_DIR}/stubs.o"
# as --64 -o "${STUBS_OBJ}" "${REPO_ROOT}/tools/stubs.S"
# OBJECTS+=("${STUBS_OBJ}")

echo "[link] ld -T link.ld -> kernel.elf"
# paideia-as 0.6.0 doesn't yet emit top-level let-fn bindings as named ELF
# symbols (the encoder ships them as a synthetic `add_one` placeholder), so
# inter-file references like `call uart_init` show up as undefined PLT32
# relocations at link time. tools/stubs.S provides empty `ret` bodies for
# each placeholder symbol; ld resolves the PLT32 relocs against them. The
# kernel returns through these stubs at runtime (no UART, no init) but the
# image links and QEMU can load it. Real symbol-export lands in a later
# paideia-as phase.
ld -nostdlib -T "${LINK_SCRIPT}" -o "${BUILD_DIR}/kernel.elf" "${OBJECTS[@]}"

echo "[ok] ${BUILD_DIR}/kernel.elf"
