#!/usr/bin/env bash
# tools/run-uefi-ovmf.sh — R19.M5-002 (#802)
#
# Boots the paideia UEFI ESP image (build/uefi/paideia-esp.img) under
# QEMU + OVMF and verifies the boot fingerprint on serial. Success:
# the UEFI stub reaches ExitBootServices, jumps to kernel_main_uefi,
# and the kernel emits the R19.M4 "UEFI kernel_main entered" marker
# via the 16550 at 0x3F8.
#
# -----------------------------------------------------------------------------
# Exit codes
# -----------------------------------------------------------------------------
#
#   0    — fingerprint appeared on serial before timeout
#   1    — timeout OR fingerprint mismatch (last 40 log lines dumped)
#   2    — dependency missing (QEMU or OVMF); no fingerprint attempted
#   77   — SKIP: OVMF not installed (compatibility with automake test convention)
#
# -----------------------------------------------------------------------------
# OVMF path discovery
# -----------------------------------------------------------------------------
#
# OVMF file locations vary by distro:
#
#   Debian / Ubuntu (ovmf package):
#     /usr/share/OVMF/OVMF_CODE_4M.fd   + OVMF_VARS_4M.fd     (split, 4 MiB)
#     /usr/share/OVMF/OVMF_CODE.fd      + OVMF_VARS.fd        (split, 2 MiB)
#   Fedora / RHEL (edk2-ovmf package):
#     /usr/share/edk2/ovmf/OVMF_CODE.fd + OVMF_VARS.fd
#   Arch (edk2-ovmf):
#     /usr/share/edk2-ovmf/x64/OVMF_CODE.fd + OVMF_VARS.fd
#   NixOS (OVMF):
#     /run/current-system/sw/share/OVMF/OVMF_CODE.fd
#   Alternatively a merged /usr/share/qemu/OVMF.fd is common as a
#   monolithic firmware (code + vars in one blob); usable via -bios.
#
# We try each in order until we find a valid CODE/VARS pair or a
# merged blob. `PAIDEIA_UEFI_OVMF_CODE` and `PAIDEIA_UEFI_OVMF_VARS`
# env vars override discovery (for users with a custom edk2 build).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BUILD_DIR="${REPO_ROOT}/build"
BUILD_UEFI_DIR="${BUILD_DIR}/uefi"
IMG_PATH="${BUILD_UEFI_DIR}/paideia-esp.img"
LOG_PATH="${BUILD_UEFI_DIR}/ovmf-serial.log"

TIMEOUT_SEC="${PAIDEIA_UEFI_OVMF_TIMEOUT:-30}"
# Default marker is the R19.M5-achievable one: efi_main's ConOut hello
# banner. The R20 kernel-side "UEFI kernel_main entered" marker
# requires an ELF loader that R20 lands — until then the finalizer's
# push-ret jumps to a stale LMA (kernel.elf is not loaded at that PA
# under M5) and the CPU stumbles until UEFI's #UD handler fires.
# Users testing R20+ pass PAIDEIA_UEFI_OVMF_MARKER="UEFI kernel_main entered".
EXPECTED_MARKER="${PAIDEIA_UEFI_OVMF_MARKER:-paideia boot: entry ok}"

# -----------------------------------------------------------------------------
# Dependency: qemu-system-x86_64.
# -----------------------------------------------------------------------------

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "[run-uefi-ovmf] FAIL: qemu-system-x86_64 not installed" >&2
    exit 2
fi

# -----------------------------------------------------------------------------
# Dependency: OVMF firmware.
# -----------------------------------------------------------------------------

OVMF_CODE=""
OVMF_VARS=""
OVMF_MERGED=""

# Env overrides win.
if [[ -n "${PAIDEIA_UEFI_OVMF_CODE:-}" ]]; then
    OVMF_CODE="${PAIDEIA_UEFI_OVMF_CODE}"
    OVMF_VARS="${PAIDEIA_UEFI_OVMF_VARS:-}"
fi

if [[ -z "${OVMF_CODE}" ]]; then
    for candidate_code in \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/edk2/ovmf/OVMF_CODE.fd \
        /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
        /run/current-system/sw/share/OVMF/OVMF_CODE.fd; do
        if [[ -f "${candidate_code}" ]]; then
            OVMF_CODE="${candidate_code}"
            # VARS blob lives next to CODE with matching suffix.
            case "${candidate_code}" in
                *OVMF_CODE_4M.fd)  OVMF_VARS="${candidate_code%OVMF_CODE_4M.fd}OVMF_VARS_4M.fd" ;;
                *OVMF_CODE.fd)     OVMF_VARS="${candidate_code%OVMF_CODE.fd}OVMF_VARS.fd" ;;
            esac
            break
        fi
    done
fi

# Merged-blob fallback (usable via -bios).
if [[ -z "${OVMF_CODE}" ]]; then
    for candidate_merged in \
        /usr/share/qemu/OVMF.fd \
        /usr/share/ovmf/OVMF.fd; do
        if [[ -f "${candidate_merged}" ]]; then
            OVMF_MERGED="${candidate_merged}"
            break
        fi
    done
fi

if [[ -z "${OVMF_CODE}" && -z "${OVMF_MERGED}" ]]; then
    echo "[run-uefi-ovmf] SKIP: OVMF firmware not found on this host" >&2
    echo "[run-uefi-ovmf]       install one of:" >&2
    echo "[run-uefi-ovmf]         Debian/Ubuntu:  apt install ovmf" >&2
    echo "[run-uefi-ovmf]         Fedora:         dnf install edk2-ovmf" >&2
    echo "[run-uefi-ovmf]         Arch:           pacman -S edk2-ovmf" >&2
    echo "[run-uefi-ovmf]       or set PAIDEIA_UEFI_OVMF_CODE / PAIDEIA_UEFI_OVMF_VARS" >&2
    exit 77
fi

# -----------------------------------------------------------------------------
# Ensure ESP image is built and current.
# -----------------------------------------------------------------------------

if [[ ! -f "${IMG_PATH}" ]]; then
    echo "[run-uefi-ovmf] ESP image missing — building via build-uefi-image.sh"
    bash "${REPO_ROOT}/tools/build-uefi-image.sh"
fi

# -----------------------------------------------------------------------------
# Assemble QEMU invocation.
# -----------------------------------------------------------------------------
#
# Baseline flags:
#   -M q35            — modern chipset; UEFI firmware assumes q35 or i440fx
#   -m 512            — 512 MiB RAM; enough for OVMF + kernel + a
#                       comfortable EFI memmap
#   -smp 1            — single-CPU for first-light; R19 kernel doesn't
#                       enter APs post-EBS yet
#   -serial stdio     — 16550 output pipes to our stdin, which we
#                       capture into ${LOG_PATH}
#   -nographic        — no window; -serial stdio still emits to console
#   -no-reboot        — halt on triple-fault instead of rebooting
#   -drive ...        — ESP image as a virtio-blk block device (UEFI
#                       finds it via the file protocol from the ESP)

QEMU_ARGS=(
    -machine q35
    -m 512
    -smp 1
    -no-reboot
    -serial stdio
    -display none
    -drive "if=none,file=${IMG_PATH},format=raw,id=hd0"
    -device "virtio-blk-pci,drive=hd0"
)

# Firmware attachment: prefer split CODE/VARS (writable VARS via a
# per-run copy so we don't dirty the system firmware), fall back to
# merged -bios.

if [[ -n "${OVMF_CODE}" ]]; then
    if [[ -n "${OVMF_VARS}" && -f "${OVMF_VARS}" ]]; then
        OVMF_VARS_COPY="${BUILD_UEFI_DIR}/OVMF_VARS-run.fd"
        cp "${OVMF_VARS}" "${OVMF_VARS_COPY}"
        QEMU_ARGS+=(
            -drive "if=pflash,format=raw,unit=0,file=${OVMF_CODE},readonly=on"
            -drive "if=pflash,format=raw,unit=1,file=${OVMF_VARS_COPY}"
        )
        echo "[run-uefi-ovmf] firmware: split CODE=${OVMF_CODE} VARS=${OVMF_VARS_COPY}"
    else
        # Split CODE with missing VARS is unusable; try merged fallback.
        if [[ -n "${OVMF_MERGED}" ]]; then
            QEMU_ARGS+=(-bios "${OVMF_MERGED}")
            echo "[run-uefi-ovmf] firmware: merged ${OVMF_MERGED} (CODE without matching VARS)"
        else
            echo "[run-uefi-ovmf] FAIL: found ${OVMF_CODE} but no matching VARS or merged OVMF.fd" >&2
            exit 2
        fi
    fi
else
    QEMU_ARGS+=(-bios "${OVMF_MERGED}")
    echo "[run-uefi-ovmf] firmware: merged ${OVMF_MERGED}"
fi

# -----------------------------------------------------------------------------
# Run under timeout, capture serial output.
# -----------------------------------------------------------------------------

echo "[run-uefi-ovmf] launching QEMU (timeout ${TIMEOUT_SEC}s, expected marker: '${EXPECTED_MARKER}')"

rm -f "${LOG_PATH}"

# `timeout` sends SIGTERM after TIMEOUT_SEC. -k adds SIGKILL after 3s
# grace period. Redirect QEMU's serial stdio into the log; also tee to
# stderr so operators watching interactively see the boot chatter.
# `|| true` because timeout(1) exits 124 on timeout; we still want to
# grep the captured log.
timeout -k 3 "${TIMEOUT_SEC}" qemu-system-x86_64 "${QEMU_ARGS[@]}" \
    </dev/null >"${LOG_PATH}" 2>&1 || true

# -----------------------------------------------------------------------------
# Verify fingerprint appeared.
# -----------------------------------------------------------------------------

if grep -qF -- "${EXPECTED_MARKER}" "${LOG_PATH}"; then
    echo "[run-uefi-ovmf] PASS: fingerprint '${EXPECTED_MARKER}' found on serial"
    exit 0
fi

echo "[run-uefi-ovmf] FAIL: fingerprint '${EXPECTED_MARKER}' NOT found within ${TIMEOUT_SEC}s" >&2
echo "[run-uefi-ovmf]       last 40 lines of ${LOG_PATH}:" >&2
tail -n 40 "${LOG_PATH}" >&2 || echo "  (log empty)" >&2
exit 1
