#!/usr/bin/env bash
# tools/build-uefi-stub.sh — R19.M1/M2/M3 build driver
#
# Builds the paideia-native UEFI EFI application stub and smoke-checks every
# sibling documentation .pdx under src/boot/. Produces a PE32+ .efi image
# loadable by UEFI firmware (LoadImage per UEFI 2.10 §II-2.1.1).
#
# Design note on the two-pass shape (updated R19.M3):
#
#   paideia-as v0.20.1 build --target uefi-x86_64 accepts one .pdx input per
#   invocation and does not yet fan out multi-file link (paideia-as
#   enhancement pa-r19-multi-file-link, tracked in the R19 preflight
#   retrospective). The R19 pre-EBS boot path therefore lives in a single
#   merged translation unit (src/boot/uefi_stub.pdx) that inlines the
#   M1/M2/M3 wrappers; the sibling files (uefi_alloc.pdx, uefi_locate.pdx,
#   ..., uefi_gop.pdx, uefi_acpi.pdx, ...) are standalone-compilable
#   documentation companions that this script smoke-compiles to /tmp
#   individually to catch drift between them and the merged translation
#   unit at build time. When multi-file link lands, this script will
#   collapse to a single fan-out over all *.pdx files.
#
# Design note on output format: paideia-as `--target uefi-x86_64` invokes the
# paideia-as-emitter-pe crate directly and produces a PE32+ COFF image with
# the EFI application subsystem code (10). No objcopy(1) conversion step is
# required — the PE emitter is native.

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

STUB_SRC="${BOOT_SRC}/uefi_stub.pdx"
STUB_EFI="${BUILD_UEFI_DIR}/uefi_stub.efi"

if [[ ! -f "${STUB_SRC}" ]]; then
    echo "[build-uefi-stub] FAIL: ${STUB_SRC} missing" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Pass 1: smoke-compile every standalone documentation .pdx under src/boot/.
# -----------------------------------------------------------------------------
#
# Each companion file is required to standalone-compile so that any drift
# between the merged uefi_stub.pdx and its documentation counterparts
# surfaces as a build failure. Outputs go to /tmp and are discarded — the
# only signal we care about is exit status.
#
# The merged uefi_stub.pdx itself is skipped in this pass; pass 2 runs it
# through the real build.

SMOKE_TMP="$(mktemp -d -t uefi-stub-smoke.XXXXXX)"
trap 'rm -rf "${SMOKE_TMP}"' EXIT

echo "[build-uefi-stub] smoke-check standalone .pdx companions under src/boot/"
while IFS= read -r -d '' pdx; do
    base="$(basename "${pdx}" .pdx)"
    if [[ "${base}" == "uefi_stub" ]]; then
        continue
    fi
    out="${SMOKE_TMP}/${base}.efi"
    if ! "${PAIDEIA_AS}" build --target uefi-x86_64 "${pdx}" -o "${out}" 2>&1; then
        echo "[build-uefi-stub] FAIL: standalone-compile of ${pdx#"${REPO_ROOT}"/} failed" >&2
        exit 1
    fi
    echo "[build-uefi-stub]   OK: ${pdx#"${REPO_ROOT}"/}"
done < <(find "${BOOT_SRC}" -maxdepth 1 -name '*.pdx' -print0 | sort -z)

# -----------------------------------------------------------------------------
# Pass 2: build the merged uefi_stub.pdx into the real .efi artefact.
# -----------------------------------------------------------------------------

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

# -----------------------------------------------------------------------------
# Pass 3: verify the R19.M3 discovery flow is wired into efi_main.
# -----------------------------------------------------------------------------
#
# The merged stub's efi_main MUST call each of the five R19.M3 probes. We
# grep the disassembled .text for the CALL sites — a direct `E8 imm32` from
# efi_main into another function in the same translation unit is exactly
# what we expect to see after the paideia-as PE-emitter fixes at #1292 +
# #1293. The check counts CALL instructions in .text; a regression that
# silently dropped the M3 wiring would show up as too few CALLs.

if ! command -v objdump >/dev/null 2>&1; then
    echo "[build-uefi-stub] SKIP: objdump not available — cannot verify call-site count"
else
    CALL_COUNT="$(objdump -d "${STUB_EFI}" 2>/dev/null | grep -cE $'\tcall ')"
    if [[ "${CALL_COUNT}" -lt 8 ]]; then
        echo "[build-uefi-stub] FAIL: expected >= 8 CALL sites in .text (efi_main dispatches + wrapper indirects), found ${CALL_COUNT}" >&2
        exit 3
    fi
    echo "[build-uefi-stub] OK: ${CALL_COUNT} CALL sites in .text (efi_main dispatches + wrapper indirects)"
fi
