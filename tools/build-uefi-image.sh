#!/usr/bin/env bash
# tools/build-uefi-image.sh — R19.M5-001 (#801)
#
# Assembles a bootable FAT32 ESP disk image containing the paideia UEFI
# stub + kernel ELF. Firmware discovers the removable-media default
# path /EFI/BOOT/BOOTX64.EFI (UEFI 2.10 §3.5.1) and hands control to
# our stub's efi_main; the stub then handoffs to kernel_main_uefi
# (LMA resolved at build-uefi-stub time — see tools/build-uefi-stub.sh
# §"LMA resolution").
#
# -----------------------------------------------------------------------------
# Output layout (inside build/uefi/paideia-esp.img)
# -----------------------------------------------------------------------------
#
#   /EFI/BOOT/BOOTX64.EFI    — UEFI removable-media default path
#                               (= build/uefi/uefi_stub.efi verbatim).
#   /paideia/kernel.elf      — the linked kernel image; loaded by the
#                               R20 loader that will consume the M5
#                               LMA-resolved handoff (M5 itself does
#                               not yet load this from ESP — the stub
#                               jumps to the pre-baked LMA of
#                               kernel_main_uefi, which is placed at
#                               that PA under -kernel-mode boot;
#                               keeping kernel.elf on the ESP now
#                               lets the R20 loader consume it
#                               without another disk-image landing).
#
# -----------------------------------------------------------------------------
# Filesystem tool: mtools preferred (no sudo, no loopback)
# -----------------------------------------------------------------------------
#
# mtools writes directly into a FAT image without needing a mount
# point or root privileges. If mtools is absent, we fall back to
# mkfs.vfat + a loopback mount (requires sudo). The mtools path is
# strongly preferred for CI-friendly bring-up.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BUILD_DIR="${REPO_ROOT}/build"
BUILD_UEFI_DIR="${BUILD_DIR}/uefi"
STUB_EFI="${BUILD_UEFI_DIR}/uefi_stub.efi"
KERNEL_ELF="${BUILD_DIR}/kernel.elf"
IMG_PATH="${BUILD_UEFI_DIR}/paideia-esp.img"
IMG_SIZE_MB=64

# R28-M1-002 (#999): the canonical branded path is /EFI/PAIDEIA/PAIDEIA.EFI;
# /EFI/BOOT/BOOTX64.EFI is the UEFI 2.10 §3.5.1 removable-media fallback and
# must exist so firmware that does not consult a stored BootOrder still finds
# the loader. FAT does not do true symlinks, so both entries are byte-identical
# copies of the same stub. NVRAM Boot#### entries added at first-run should
# point at PAIDEIA.EFI; BOOTX64.EFI is the "any-firmware" cold-start entry.
#
# R28-M1-003 (#1000): the PdxFS-lite rootfs blob, when built, is copied into
# the ESP at /paideia/rootfs.pdxfs so the kernel (R28.M2+ mount path) can find
# it via a fixed ESP-relative path without needing a partition-table scan.
# Empty by default so build-uefi-image.sh remains a standalone R19 tool; the
# R28 orchestrator (build-image.sh) sets PDXFS_LITE_IMG=<path> to include it.
PDXFS_LITE_IMG="${PDXFS_LITE_IMG:-}"

mkdir -p "${BUILD_UEFI_DIR}"

# -----------------------------------------------------------------------------
# Rebuild dependencies if missing.
# -----------------------------------------------------------------------------

if [[ ! -f "${KERNEL_ELF}" ]]; then
    echo "[build-uefi-image] kernel.elf missing — running build.sh"
    bash "${REPO_ROOT}/tools/build.sh"
fi

if [[ ! -f "${STUB_EFI}" ]]; then
    echo "[build-uefi-image] uefi_stub.efi missing — running build-uefi-stub.sh"
    bash "${REPO_ROOT}/tools/build-uefi-stub.sh"
fi

# Sanity: stub must be PE32+ EFI application.
STUB_KIND="$(file -b "${STUB_EFI}")"
case "${STUB_KIND}" in
    *"PE32+ executable (EFI application) x86-64"*) ;;
    *)
        echo "[build-uefi-image] FAIL: ${STUB_EFI} is not a PE32+ EFI application" >&2
        echo "[build-uefi-image]       file(1): ${STUB_KIND}" >&2
        exit 1
        ;;
esac

# -----------------------------------------------------------------------------
# R28-M1-004 (#1001): sign the stub with tools/sign-efi.sh (adds .pdxsgn/
# .pdxpk/.pdxsig sections consumed by kernel-side verify_self.pdx at
# boot). The signed .efi is what lands on the ESP under both the branded
# canonical path (/EFI/PAIDEIA/PAIDEIA.EFI) and the UEFI fallback path
# (/EFI/BOOT/BOOTX64.EFI). Skippable via NO_SIGN=1 for regression bisects.
# -----------------------------------------------------------------------------

SIGNED_STUB_EFI="${BUILD_UEFI_DIR}/uefi_stub.signed.efi"
NO_SIGN="${NO_SIGN:-0}"

if [[ "${NO_SIGN}" == "1" ]]; then
    echo "[build-uefi-image] WARN: NO_SIGN=1 — using unsigned stub; kernel will log 'EFI UNSIGNED (enforcement off)'" >&2
    SIGNED_STUB_EFI="${STUB_EFI}"
else
    echo "[build-uefi-image] sign-efi.sh -> ${SIGNED_STUB_EFI##*/}"
    "${REPO_ROOT}/tools/sign-efi.sh" \
        --in  "${STUB_EFI}" \
        --out "${SIGNED_STUB_EFI}"
fi

# -----------------------------------------------------------------------------
# Detect available filesystem-authoring tool.
# -----------------------------------------------------------------------------

HAVE_MTOOLS=0
HAVE_MKFS_VFAT=0

command -v mformat >/dev/null 2>&1 && \
    command -v mmd    >/dev/null 2>&1 && \
    command -v mcopy  >/dev/null 2>&1 && HAVE_MTOOLS=1

command -v mkfs.vfat >/dev/null 2>&1 && HAVE_MKFS_VFAT=1

if [[ ${HAVE_MTOOLS} -eq 0 && ${HAVE_MKFS_VFAT} -eq 0 ]]; then
    echo "[build-uefi-image] FAIL: neither mtools nor mkfs.vfat available" >&2
    echo "[build-uefi-image]       install one of:" >&2
    echo "[build-uefi-image]         Debian/Ubuntu:  apt install mtools dosfstools" >&2
    echo "[build-uefi-image]         Fedora:         dnf install mtools dosfstools" >&2
    echo "[build-uefi-image]         Arch:           pacman -S mtools dosfstools" >&2
    exit 2
fi

# -----------------------------------------------------------------------------
# Allocate raw image.
# -----------------------------------------------------------------------------

echo "[build-uefi-image] allocating ${IMG_SIZE_MB} MiB at ${IMG_PATH}"
rm -f "${IMG_PATH}"
# dd creates a sparse file; truncate is more portable and clearer.
truncate -s "${IMG_SIZE_MB}M" "${IMG_PATH}"

# -----------------------------------------------------------------------------
# Author the FAT32 filesystem + copy files.
# -----------------------------------------------------------------------------

if [[ ${HAVE_MTOOLS} -eq 1 ]]; then
    echo "[build-uefi-image] mformat ${IMG_PATH} (FAT32, no partition table)"
    # -F force FAT32; -i selects the image; :: is the drive root path.
    # -v PAIDEIA gives the volume label a human-readable name.
    # No partition table — OVMF's FAT driver reads the raw filesystem
    # off the drive (many firmware implementations accept both; the
    # partitionless form is smaller and simpler for a boot-only image).
    mformat -F -v PAIDEIA -i "${IMG_PATH}" ::

    echo "[build-uefi-image] mmd /EFI /EFI/BOOT /EFI/PAIDEIA /paideia"
    mmd -i "${IMG_PATH}" ::/EFI
    mmd -i "${IMG_PATH}" ::/EFI/BOOT
    mmd -i "${IMG_PATH}" ::/EFI/PAIDEIA
    mmd -i "${IMG_PATH}" ::/paideia

    echo "[build-uefi-image] mcopy ${SIGNED_STUB_EFI##*/} → /EFI/BOOT/BOOTX64.EFI (UEFI fallback)"
    mcopy -i "${IMG_PATH}" "${SIGNED_STUB_EFI}" ::/EFI/BOOT/BOOTX64.EFI

    # #999 branded canonical path — same bytes, different path. FAT has no
    # symlinks, so this is a real copy. Both entries are byte-identical
    # signed .efi files (R28-M1-004 #1001 — tools/sign-efi.sh has already
    # appended .pdxsgn/.pdxpk/.pdxsig sections; see design/security/
    # efi-signing.md for the R28→R32→R33 upgrade path).
    echo "[build-uefi-image] mcopy ${SIGNED_STUB_EFI##*/} → /EFI/PAIDEIA/PAIDEIA.EFI (branded canonical)"
    mcopy -i "${IMG_PATH}" "${SIGNED_STUB_EFI}" ::/EFI/PAIDEIA/PAIDEIA.EFI

    echo "[build-uefi-image] mcopy kernel.elf → /paideia/kernel.elf"
    mcopy -i "${IMG_PATH}" "${KERNEL_ELF}" ::/paideia/kernel.elf

    # #1000 rootfs blob (only if the orchestrator built one).
    if [[ -n "${PDXFS_LITE_IMG}" && -f "${PDXFS_LITE_IMG}" ]]; then
        echo "[build-uefi-image] mcopy ${PDXFS_LITE_IMG} → /paideia/rootfs.pdxfs"
        mcopy -i "${IMG_PATH}" "${PDXFS_LITE_IMG}" ::/paideia/rootfs.pdxfs
    fi

    echo "[build-uefi-image] mdir ::/EFI/BOOT (verification)"
    mdir -i "${IMG_PATH}" ::/EFI/BOOT
    echo "[build-uefi-image] mdir ::/EFI/PAIDEIA (verification)"
    mdir -i "${IMG_PATH}" ::/EFI/PAIDEIA
    echo "[build-uefi-image] mdir ::/paideia (verification)"
    mdir -i "${IMG_PATH}" ::/paideia
else
    # mkfs.vfat + loopback path — requires sudo. Kept as fallback for
    # hosts without mtools. Emits a warning so the intended primary
    # path (mtools) is easy to spot at review time.
    echo "[build-uefi-image] WARN: mtools not found — falling back to mkfs.vfat + loop mount (needs sudo)" >&2

    mkfs.vfat -F 32 -n PAIDEIA "${IMG_PATH}"

    MNT="$(mktemp -d -t paideia-esp.XXXXXX)"
    trap 'sudo umount "${MNT}" 2>/dev/null || true; rmdir "${MNT}" 2>/dev/null || true' EXIT

    sudo mount -o loop,uid="$(id -u)",gid="$(id -g)" "${IMG_PATH}" "${MNT}"
    mkdir -p "${MNT}/EFI/BOOT" "${MNT}/EFI/PAIDEIA" "${MNT}/paideia"
    cp "${SIGNED_STUB_EFI}" "${MNT}/EFI/BOOT/BOOTX64.EFI"
    cp "${SIGNED_STUB_EFI}" "${MNT}/EFI/PAIDEIA/PAIDEIA.EFI"
    cp "${KERNEL_ELF}" "${MNT}/paideia/kernel.elf"
    if [[ -n "${PDXFS_LITE_IMG}" && -f "${PDXFS_LITE_IMG}" ]]; then
        cp "${PDXFS_LITE_IMG}" "${MNT}/paideia/rootfs.pdxfs"
    fi
    sync
    sudo umount "${MNT}"
    rmdir "${MNT}"
    trap - EXIT
fi

# -----------------------------------------------------------------------------
# Sanity: image should be recognisable as a DOS/MBR filesystem.
# -----------------------------------------------------------------------------

IMG_KIND="$(file -b "${IMG_PATH}")"
echo "[build-uefi-image] file(1): ${IMG_KIND}"

case "${IMG_KIND}" in
    *"FAT"*|*"DOS/MBR"*) ;;
    *)
        echo "[build-uefi-image] WARN: image kind '${IMG_KIND}' is not obviously FAT — firmware may reject" >&2
        ;;
esac

# Size report.
IMG_SIZE="$(stat -c %s "${IMG_PATH}")"
echo "[build-uefi-image] OK: ${IMG_PATH} (${IMG_SIZE} bytes)"
