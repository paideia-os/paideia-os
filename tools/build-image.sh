#!/usr/bin/env bash
# tools/build-image.sh — R28-M1-001 (#998)
#
# The R28 MVP demo image builder. Orchestrates the four R25/R19-era tools
# into a single command that produces a bootable removable-media image:
#
#   1. Build the kernel      (tools/build.sh                 -> build/kernel.elf)
#   2. Build the UEFI stub   (tools/build-uefi-stub.sh       -> build/uefi/uefi_stub.efi)
#   3. Build the userland    (tools/build-user.sh            -> build/user/{shell,init,true,child_hello}.elf)
#   4. Build the rootfs blob (tools/mkfs-pdxfs-lite-seed.sh  -> build/mvp/rootfs.pdxfs)
#   5. Assemble the ESP      (tools/build-uefi-image.sh      -> build/mvp/paideia-mvp.img)
#      with PDXFS_LITE_IMG=rootfs.pdxfs so the ESP includes /paideia/rootfs.pdxfs.
#
# Output: build/mvp/paideia-mvp.img — a partitionless FAT32 ESP image that
# firmware can boot directly. Copy verbatim to a USB stick (`dd if=... of=/dev/sdX
# bs=4M conv=fsync`) for real-hardware bring-up.
#
# -----------------------------------------------------------------------------
# Deferred to R28.M2+
# -----------------------------------------------------------------------------
#
#   - .iso hybrid form (mkisofs / xorriso -isohybrid-gpt-basdat) — the raw
#     .img is USB-bootable today; a .iso adds DVD-bootability at negligible
#     marginal cost but requires xorriso, which we do not yet gate a build
#     on. Land in M2 when the real-HW smoke path calls for it.
#   - Reproducible build (bit-identical .img for same source hash). The
#     mkfs + mtools chain uses fresh UUIDs and creation timestamps; a
#     --deterministic flag (fixed UUID, fixed mformat -N) lands with the
#     R28 reproducibility issue when we open it.
#   - Signed PAIDEIA.EFI (#1001). See design/security/pe-secure-boot-signing.md
#     for the full deferral rationale (paideia-as PE Certificate Table +
#     PKCS#7 wrap + ML-DSA sign are all R32/R33 scope).
#
# Exit 0 on success, non-zero on any error.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BUILD_DIR="${REPO_ROOT}/build"
MVP_DIR="${BUILD_DIR}/mvp"
KERNEL_ELF="${BUILD_DIR}/kernel.elf"
STUB_EFI="${BUILD_DIR}/uefi/uefi_stub.efi"
SHELL_ELF="${BUILD_DIR}/user/shell.elf"
ROOTFS_IMG="${MVP_DIR}/rootfs.pdxfs"
MVP_IMG="${MVP_DIR}/paideia-mvp.img"

# CLI — small on purpose; the tool is not a knob-heavy replacement for the
# component scripts.
ROOTFS_SIZE_MB="${ROOTFS_SIZE_MB:-32}"
SKIP_BUILDS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-builds)
      # Assume kernel.elf / uefi_stub.efi / shell.elf are already up-to-date.
      # Useful when iterating on the image-assembly step alone.
      SKIP_BUILDS=1; shift ;;
    --rootfs-size)
      ROOTFS_SIZE_MB="${2:?}"; shift 2 ;;
    -h|--help)
      cat <<'USAGE'
build-image — assemble the PaideiaOS MVP demo image.

Usage:
  tools/build-image.sh [options]

Options:
  --skip-builds        Skip kernel/stub/user rebuilds (assume up-to-date).
  --rootfs-size <mb>   PdxFS-lite blob size in MiB (default 32).
  -h, --help           Print this help.

Output:
  build/mvp/paideia-mvp.img  — bootable FAT32 ESP image (USB-writable).
  build/mvp/rootfs.pdxfs     — PdxFS-lite blob (also embedded in the ESP).
USAGE
      exit 0 ;;
    *)
      echo "build-image: unknown argument: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "${MVP_DIR}"

# -----------------------------------------------------------------------------
# Phase 1 — component builds.
# -----------------------------------------------------------------------------

if [[ ${SKIP_BUILDS} -eq 0 ]]; then
    echo "[build-image] phase 1a: kernel"
    bash "${REPO_ROOT}/tools/build.sh"

    echo "[build-image] phase 1b: UEFI stub"
    bash "${REPO_ROOT}/tools/build-uefi-stub.sh"

    echo "[build-image] phase 1c: userland (shell, init, true, child_hello)"
    bash "${REPO_ROOT}/tools/build-user.sh"
fi

# Preconditions from Phase 1 (or the operator's --skip-builds contract).
for f in "${KERNEL_ELF}" "${STUB_EFI}" "${SHELL_ELF}"; do
    if [[ ! -f "${f}" ]]; then
        echo "[build-image] FAIL: required artifact missing: ${f}" >&2
        echo "[build-image]       drop --skip-builds or run the component script." >&2
        exit 1
    fi
done

# -----------------------------------------------------------------------------
# Phase 2 — PdxFS-lite root-filesystem blob (#1000).
# -----------------------------------------------------------------------------

echo "[build-image] phase 2: seeded PdxFS-lite blob"
bash "${REPO_ROOT}/tools/mkfs-pdxfs-lite-seed.sh" \
    --output "${ROOTFS_IMG}" \
    --shell-elf "${SHELL_ELF}" \
    --size "${ROOTFS_SIZE_MB}"

# -----------------------------------------------------------------------------
# Phase 3 — assemble the ESP (#999 branded path + fallback path) and embed
# the rootfs blob at /paideia/rootfs.pdxfs.
# -----------------------------------------------------------------------------

echo "[build-image] phase 3: FAT32 ESP with /EFI/BOOT + /EFI/PAIDEIA + /paideia/rootfs.pdxfs"
PDXFS_LITE_IMG="${ROOTFS_IMG}" bash "${REPO_ROOT}/tools/build-uefi-image.sh"

# The R19 tool writes to build/uefi/paideia-esp.img — move (not copy: sparse
# semantics) into build/mvp/paideia-mvp.img so the MVP artifact has the
# canonical path documented in the R28 roadmap.
ESP_IMG="${BUILD_DIR}/uefi/paideia-esp.img"
if [[ ! -f "${ESP_IMG}" ]]; then
    echo "[build-image] FAIL: build-uefi-image.sh produced no ${ESP_IMG}" >&2
    exit 1
fi

cp --sparse=always "${ESP_IMG}" "${MVP_IMG}"

# -----------------------------------------------------------------------------
# Report.
# -----------------------------------------------------------------------------

echo "[build-image] OK"
echo "[build-image]   rootfs: ${ROOTFS_IMG} ($(stat -c %s "${ROOTFS_IMG}") bytes)"
echo "[build-image]   image:  ${MVP_IMG} ($(stat -c %s "${MVP_IMG}") bytes)"
echo "[build-image]   file(1) image: $(file -b "${MVP_IMG}")"
echo
echo "[build-image] Boot in QEMU (OVMF):"
echo "[build-image]   qemu-system-x86_64 -bios /usr/share/OVMF/OVMF_CODE.fd \\"
echo "[build-image]     -drive file=${MVP_IMG},format=raw,if=none,id=usb1 \\"
echo "[build-image]     -device usb-storage,drive=usb1 -usb"
echo
echo "[build-image] Write to USB:"
echo "[build-image]   sudo dd if=${MVP_IMG} of=/dev/sdX bs=4M conv=fsync status=progress"
