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
BUILD_DIR="${REPO_ROOT}/build"
BUILD_UEFI_DIR="${BUILD_DIR}/uefi"
BUILD_GEN_DIR="${BUILD_DIR}/gen"
KERNEL_ELF="${BUILD_DIR}/kernel.elf"

# link.ld constant — must match src/kernel/link.ld KERNEL_VMA_BASE.
KERNEL_VMA_BASE="0xFFFF800000000000"

if [[ ! -d "${BOOT_SRC}" ]]; then
    echo "[build-uefi-stub] FAIL: src/boot/ missing" >&2
    exit 1
fi

mkdir -p "${BUILD_UEFI_DIR}" "${BUILD_GEN_DIR}"

STUB_SRC="${BOOT_SRC}/uefi_stub.pdx"
# NOTE: paideia-as M0305 enforces module-name == PascalCase(file_basename).
# Our merged module is `UefiStub`, so the generated file must be named
# `uefi_stub.pdx` — we simply place it under build/gen/ (different
# directory) so it doesn't shadow the source-controlled file.
STUB_GEN="${BUILD_GEN_DIR}/uefi_stub.pdx"
STUB_EFI="${BUILD_UEFI_DIR}/uefi_stub.efi"

if [[ ! -f "${STUB_SRC}" ]]; then
    echo "[build-uefi-stub] FAIL: ${STUB_SRC} missing" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# R19.M5: LMA resolution for kernel_main_uefi (M4-deferred #1).
# -----------------------------------------------------------------------------
#
# The merged uefi_stub.pdx declares _kernel_main_uefi_pa as a hard-coded
# placeholder (0x100000). M5 replaces that literal with the real load
# address of kernel_main_uefi extracted from build/kernel.elf, so the
# finalizer's `push _kernel_main_uefi_pa; ret` actually lands in kernel
# code post-EBS. Formula: LMA = VA - KERNEL_VMA_BASE, since link.ld
# lays kernel .text at VMA = 0xFFFF800000000000 + LMA (see the SECTIONS
# block in src/kernel/link.ld).
#
# The substitution is performed on a generated copy under build/gen/ so
# the source-controlled uefi_stub.pdx keeps the placeholder literal
# unchanged (making its diffability + standalone-compile discipline
# unaffected). The stub .efi is built from the generated copy.
#
# If kernel.elf is absent, build it first (build.sh) — a UEFI stub
# without a resolved LMA would boot to the placeholder 0x100000 and
# either land on firmware code or crash silently.

if [[ ! -f "${KERNEL_ELF}" ]]; then
    echo "[build-uefi-stub] kernel.elf missing — running build.sh first"
    bash "${REPO_ROOT}/tools/build.sh"
fi

if [[ ! -f "${KERNEL_ELF}" ]]; then
    echo "[build-uefi-stub] FAIL: build.sh did not produce ${KERNEL_ELF}" >&2
    exit 4
fi

# nm | awk with `exit` inside awk causes SIGPIPE on nm under pipefail;
# drop the `exit` and let awk drain nm. Multiple matches would still keep
# the first line only.
KERNEL_MAIN_UEFI_VA="$(nm --defined-only "${KERNEL_ELF}" \
    | awk '$3 == "kernel_main_uefi" {print $1}' | head -n1)"

if [[ -z "${KERNEL_MAIN_UEFI_VA}" ]]; then
    echo "[build-uefi-stub] FAIL: symbol kernel_main_uefi not found in ${KERNEL_ELF}" >&2
    echo "[build-uefi-stub]       (R19.M4 wiring lives in src/kernel/kernel_main_uefi.pdx — did it fail to link?)" >&2
    exit 4
fi

# Compute LMA = VA - KERNEL_VMA_BASE via bash arithmetic on hex.
# printf's %d format prints the decimal difference; %016x re-renders as hex.
KERNEL_MAIN_UEFI_LMA="$(printf '%016x' "$((0x${KERNEL_MAIN_UEFI_VA} - ${KERNEL_VMA_BASE}))")"

echo "[build-uefi-stub] kernel_main_uefi VA=0x${KERNEL_MAIN_UEFI_VA} → LMA=0x${KERNEL_MAIN_UEFI_LMA}"

# In-place placeholder substitution in the generated copy.
# The source line format is:
#   pub let mut _kernel_main_uefi_pa : u64 = 0x100000
# We rewrite the RHS literal to the extracted LMA. Anchored on the
# variable name + colon + type so we do not accidentally rewrite
# unrelated 0x100000 literals elsewhere (there are none today; the
# anchoring is defensive against future drift).
sed \
    -e "s|_kernel_main_uefi_pa : u64 = 0x100000|_kernel_main_uefi_pa : u64 = 0x${KERNEL_MAIN_UEFI_LMA}|" \
    "${STUB_SRC}" > "${STUB_GEN}"

# Verify substitution actually happened. sed(1) succeeds silently even
# when the pattern doesn't match — a regression that renamed the slot
# would produce a stub with the stale 0x100000 target and boot to nowhere.
if ! grep -qF "_kernel_main_uefi_pa : u64 = 0x${KERNEL_MAIN_UEFI_LMA}" "${STUB_GEN}"; then
    echo "[build-uefi-stub] FAIL: LMA substitution did not take — check placeholder in ${STUB_SRC}" >&2
    exit 5
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
#
# Note: we build the GENERATED copy (STUB_GEN), not STUB_SRC — the
# generated copy has the resolved kernel_main_uefi LMA substituted in.
# The source .pdx is untouched (retains the 0x100000 placeholder for
# documentation + standalone-compile).

echo "[build-uefi-stub] paideia-as --target uefi-x86_64 build/gen/uefi_stub.pdx -> uefi_stub.efi"
"${PAIDEIA_AS}" build --target uefi-x86_64 "${STUB_GEN}" -o "${STUB_EFI}"

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
