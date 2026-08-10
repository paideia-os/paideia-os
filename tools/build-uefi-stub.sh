#!/usr/bin/env bash
# tools/build-uefi-stub.sh — R19-M1-001 (#783)
#
# Build the paideia-native UEFI EFI application stub. Consumes the pdx
# sources under src/boot/ and produces a PE32+ .efi image loadable by UEFI
# firmware (LoadImage per UEFI 2.10 §II-2.1.1).
#
# The stub is a *separate* artifact from build/kernel.elf: the kernel is the
# post-ExitBootServices target; this stub is the pre-ExitBootServices bring-up
# code that discovers the memmap/GOP/ACPI/TPM, exits Boot Services, and jumps
# to the kernel. R19.M1 lands only the entry point + handoff slots; wrappers
# grow at M2+.
#
# Design note on output format: paideia-as `--target uefi-x86_64` invokes the
# paideia-as-emitter-pe crate directly and produces a PE32+ COFF image with
# the EFI application subsystem code (10). No objcopy(1) conversion step is
# required — the PE emitter is native. Historically we scoped an objcopy
# fallback (`objcopy -O pei-x86-64 --subsystem efi_application`) in case the
# PE emitter was ELF-only; it is not, and the fallback path is dead.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PAIDEIA_AS="$("${REPO_ROOT}/tools/find-paideia-as.sh")"

BOOT_SRC="${REPO_ROOT}/src/boot"
BUILD_UEFI_DIR="${REPO_ROOT}/build/uefi"

if [[ ! -d "${BOOT_SRC}" ]]; then
    echo "[build-uefi-stub] FAIL: src/boot/ missing" >&2
    exit 1
fi

mkdir -p "${BUILD_UEFI_DIR}"

# uefi_types.pdx contains only constants (no code, no data). It is included
# for documentary provenance of the offset table; the stub compiles as a
# single translation unit at R19.M1. When R19.M2 grows the stub across
# multiple .pdx files, this loop will fan out over BOOT_SRC/*.pdx and link
# the resulting objects.
STUB_SRC="${BOOT_SRC}/uefi_stub.pdx"
STUB_EFI="${BUILD_UEFI_DIR}/uefi_stub.efi"

if [[ ! -f "${STUB_SRC}" ]]; then
    echo "[build-uefi-stub] FAIL: ${STUB_SRC} missing" >&2
    exit 1
fi

echo "[build-uefi-stub] paideia-as --target uefi-x86_64 uefi_stub.pdx -> uefi_stub.efi"
"${PAIDEIA_AS}" build --target uefi-x86_64 "${STUB_SRC}" -o "${STUB_EFI}"

# Sanity: file(1) must recognize the artifact as a PE32+ EFI application.
FILE_KIND="$(file -b "${STUB_EFI}")"
case "${FILE_KIND}" in
    *"PE32+ executable (EFI application) x86-64"*)
        echo "[build-uefi-stub] OK: ${STUB_EFI} (${FILE_KIND})"
        ;;
    *)
        echo "[build-uefi-stub] FAIL: ${STUB_EFI} is not PE32+ EFI application: ${FILE_KIND}" >&2
        exit 2
        ;;
esac
