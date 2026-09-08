#!/usr/bin/env bash
# tools/run-qemu-t14fidelity.sh -- R111.M7-026 (paideia-os #2378)
#
# T14 G4-fidelity QEMU smoke: boots the tools/mkimage.sh output
# (build/mvp/T14G4.img by default) under real UEFI (OVMF), on a
# guest topology tuned as close to a Lenovo ThinkPad T14 Gen 4 as the
# QEMU 8.x device model catalogue supports.  The only currently
# available paideia smoke that boots the ESP through real OVMF ->
# UEFI stub -> kernel_main_uefi -> higher-half bridge -> kernel_main_64
# -> init -> shell chain end to end.
#
# What this recipe changes relative to tools/run-qemu.sh (which boots
# a bare kernel ELF via QEMU's PVH `-kernel` fast path):
#
#   * real UEFI:    OVMF firmware + split CODE/VARS pflash pair
#                   instead of `-kernel` PVH direct-load.  Exercises
#                   the entire src/boot/uefi_stub.pdx + ExitBootServices
#                   + kernel_main_uefi bridge that the -kernel path
#                   trivially bypasses.
#   * real ESP:     the mkimage.sh output presented over a real
#                   USB storage stack (qemu-xhci + usb-storage), the
#                   closest QEMU model to how a T14 G4 sees a bootable
#                   USB stick.  A `-hda` shortcut would boot but skip
#                   both the xHCI attach and the FAT32 read-from-USB
#                   path that a real T14 hits.
#   * real chipset: -M q35 (T14 G4 chipset is Raptor Point-U; Q35 is
#                   the closest QEMU model with proper PCIe root
#                   complex + MSI-X + ECAM).  The default -M pc has
#                   no PCIe and no MCFG, both of which the R111.M2
#                   sub-wave depends on.
#   * real CPU:     -cpu Alderlake-Server-noTSX by default (closest
#                   QEMU 8.x model to Raptor Lake -- shares uarch
#                   family, PMU, XSAVE state components, IBRS/SSBD
#                   feature bits).  KVM users can pass PAIDEIA_T14_CPU=
#                   host for true feature parity when the host CPU is
#                   a Raptor Lake / Alder Lake part.
#   * real VT-d:    -device intel-iommu,intremap=on so R111.M2-007's
#                   MSI-X + interrupt-remapping bring-up actually has
#                   a DMAR to consume (bare Q35 without this flag
#                   publishes no DMAR and the sibling MSIX IR OFF arm
#                   fires, which is exactly the invariant the
#                   verify-fingerprint-coverage allowlist entry for
#                   `MSIX IR TABLE OK` names).
#   * real NVMe:    -device nvme,drive=nvme0 with a real backing
#                   image, giving the R111.M3-011..013 storage sub-
#                   wave an actual NVMe attach to exercise instead of
#                   the substrate skip arm the default -kernel matrix
#                   takes.
#   * real HID:     -device qemu-xhci + -device usb-kbd, so the
#                   R111.M5-017..019 USB attach + HID keyboard
#                   descriptor-parse cascade has real endpoints on
#                   the wire.  Same USB stack that carries the ESP.
#   * real audio:   -device intel-hda + -device hda-duplex.  Not
#                   strictly required for the shell-prompt witness
#                   this smoke asserts, but present so an operator
#                   iterating on R33..R39 audio paths on this same
#                   fidelity recipe does not have to re-fight the
#                   QEMU device catalogue.
#
# SUCCESS CRITERION
#
# The kernel reaches ring-3 and the shell prompt fires.  Serial-log
# check:
#
#   1) `SHELL START` -- src/user/shell.pdx L20 marker, emitted from
#      _start once init's fork+execve('/bin/sh') has transferred
#      control into the shell binary.  This is the earliest fingerprint
#      that proves the entire UEFI -> kernel -> init -> shell chain
#      landed.  The R111.M7-026 issue text calls it "PAIDEIA SHELL
#      START"; the literal on the wire is "SHELL START\n".
#
# In addition, on any run that made it that far, this recipe verifies
# every T14-real-HW-path fingerprint from earlier waves also reached
# the wire.  A run that hits SHELL START but drops one of these means
# a real-HW cascade regressed silently:
#
#   2) `UEFI EBS OK`         -- R111.M2-010 uefi_stub.pdx finalizer's
#                              ExitBootServices success line.
#   3) `ACPI RSDP HANDOFF OK`-- R111.M1-004 acpi/phase1_info.pdx line
#                              1 of the R20 witness, seeded from the
#                              firmware handoff (not the EBDA scan).
#   4) `FB CONSOLE OK`       -- R111.M4-015 devices/display/gop_fb_
#                              console.pdx bring-up line 1.
#
# All four are single-source pinned in tests/expected-t14-fidelity.golden
# (this landing's companion file) rather than duplicated as bash
# literals; that golden file is the one place to edit if the wire
# shape shifts.
#
# TIMEOUT
#
# 60 seconds by default (PAIDEIA_T14_TIMEOUT to override).  This is
# ~5x the boot_r17_init 8s bound because the extra work here
# (OVMF init + ExitBootServices retry loop + NVMe attach + xHCI
# port enumeration + intel-hda probe + VT-d DMAR walk) all runs
# BEFORE init even starts.  60s leaves headroom on a slow developer
# workstation.
#
# ENVIRONMENT
#
#   PAIDEIA_OVMF=<path>          Path to OVMF_CODE_4M.fd (or OVMF.fd
#                                merged).  When set, no discovery is
#                                performed; the file must exist.
#                                When unset, this script probes the
#                                same set of paths that
#                                tools/run-uefi-ovmf.sh probes
#                                (Debian/Ubuntu, Fedora, Arch,
#                                NixOS).  Setting PAIDEIA_OVMF is the
#                                recommended shape for CI / repeatable
#                                runs; discovery is a convenience.
#
#   PAIDEIA_OVMF_VARS=<path>     Optional matching VARS blob.  When
#                                PAIDEIA_OVMF names a *_CODE*.fd file
#                                and this is unset, derived by suffix
#                                substitution.
#
#   PAIDEIA_T14_IMG=<path>       Override for the mkimage.sh output
#                                path.  Defaults to
#                                build/mvp/T14G4.img.
#
#   PAIDEIA_T14_CPU=<qemu-cpu>   Override for -cpu (default
#                                Alderlake-Server-noTSX).  Set to
#                                `host` when running under KVM on a
#                                Raptor Lake / Alder Lake host for
#                                true feature parity; set to `max` on
#                                a non-KVM host that lacks the
#                                Alderlake-Server-noTSX model (older
#                                QEMU).
#
#   PAIDEIA_T14_TIMEOUT=<sec>    Serial-log wait timeout.  Default 60.
#
#   PAIDEIA_T14_NVME_IMG=<path>  Override for the backing NVMe image.
#                                Defaults to build/t14fidelity-nvme.img
#                                (16 MiB, zero-initialized on first
#                                run).  Use --wipe to force re-init.
#
#   PAIDEIA_SWTPM_SOCKET=<path>  When set to an existing UNIX socket
#                                served by swtpm(1), a -tpmdev
#                                emulator + -device tpm-crb pair is
#                                appended.  Left unset by default:
#                                requires a running swtpm daemon the
#                                operator started separately, which
#                                is out of scope for a QEMU-only
#                                smoke.  Real T14 G4 ships a real
#                                dTPM; this hook exists so that
#                                paideia's future TPM consumer waves
#                                (post-R32) can compose with this
#                                fidelity recipe without a fork.
#
# EXIT CODES
#
#   0   `SHELL START` observed AND every fingerprint from the golden
#       file appeared on serial before the timeout.
#   1   `SHELL START` observed but one or more golden fingerprints
#       missing (silent regression on a real-HW cascade path).
#   2   dependency missing (qemu-system-x86_64, OVMF, or the
#       tools/mkimage.sh output).  No boot attempted.
#   77  OVMF not installed and PAIDEIA_OVMF unset -- classic
#       skip-signal for "opt-in smoke that this host cannot run".
#  124  serial-log wait timed out without observing SHELL START.
#       The tail of the log is dumped to stderr.
#
# USAGE
#
#   # First-time setup on Debian / Ubuntu:
#   sudo apt install ovmf qemu-system-x86 qemu-utils
#   bash tools/mkimage.sh build --fw-dir=~/paideia-firmware
# (or `bash tools/mkimage.sh build --no-firmware` for CI without blobs)
#
#   # Run the fidelity smoke:
#   PAIDEIA_OVMF=/usr/share/OVMF/OVMF_CODE_4M.fd \
#     bash tools/run-qemu-t14fidelity.sh
#
#   # Force NVMe image re-init:
#   PAIDEIA_OVMF=/usr/share/OVMF/OVMF_CODE_4M.fd \
#     bash tools/run-qemu-t14fidelity.sh --wipe
#
#   # KVM host with a Raptor Lake CPU (true feature parity):
#   PAIDEIA_OVMF=/usr/share/OVMF/OVMF_CODE_4M.fd \
#   PAIDEIA_T14_CPU=host \
#     bash tools/run-qemu-t14fidelity.sh -enable-kvm
#
# Any positional arg after --wipe passes through verbatim to QEMU
# (matching tools/run-qemu.sh's convention), so `-d int,cpu_reset`
# etc. still work for interactive debugging.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BUILD_DIR="${REPO_ROOT}/build"
IMG_PATH="${PAIDEIA_T14_IMG:-${BUILD_DIR}/mvp/T14G4.img}"
LOG_PATH="${BUILD_DIR}/t14fidelity-serial.log"
GOLDEN_PATH="${REPO_ROOT}/tests/expected-t14-fidelity.golden"

TIMEOUT_SEC="${PAIDEIA_T14_TIMEOUT:-60}"
T14_CPU="${PAIDEIA_T14_CPU:-Alderlake-Server-noTSX}"
NVME_IMG="${PAIDEIA_T14_NVME_IMG:-${BUILD_DIR}/t14fidelity-nvme.img}"
NVME_IMG_SIZE_MB=16

WIPE=0

# ---- Argument parsing ------------------------------------------------
#
# --wipe consumed here; anything else forwarded to QEMU verbatim.
# `--help` prints the header block above via sed.

PASSTHROUGH=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --wipe)
            WIPE=1
            shift
            ;;
        --help|-h)
            sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            PASSTHROUGH+=("$1")
            shift
            ;;
    esac
done

# ---- Dependency checks -----------------------------------------------

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "[t14-fidelity] FAIL: qemu-system-x86_64 not installed" >&2
    exit 2
fi

if [[ ! -f "${IMG_PATH}" ]]; then
    echo "[t14-fidelity] FAIL: image missing at ${IMG_PATH}" >&2
    echo "[t14-fidelity]       run: bash tools/mkimage.sh" >&2
    echo "[t14-fidelity]       or set PAIDEIA_T14_IMG=<path> to an existing image" >&2
    exit 2
fi

if [[ ! -f "${GOLDEN_PATH}" ]]; then
    echo "[t14-fidelity] FAIL: golden fingerprint file missing at ${GOLDEN_PATH}" >&2
    exit 2
fi

# ---- OVMF discovery --------------------------------------------------
#
# Mirrors tools/run-uefi-ovmf.sh's discovery so an operator who has
# OVMF working there gets a first-try green boot here too.  Env
# override wins unconditionally; a set-but-missing PAIDEIA_OVMF fails
# hard rather than falling through to discovery (a caller who names a
# path expects that path to be honored).

OVMF_CODE=""
OVMF_VARS=""
OVMF_MERGED=""

if [[ -n "${PAIDEIA_OVMF:-}" ]]; then
    if [[ ! -f "${PAIDEIA_OVMF}" ]]; then
        echo "[t14-fidelity] FAIL: PAIDEIA_OVMF=${PAIDEIA_OVMF} does not exist" >&2
        exit 2
    fi
    case "${PAIDEIA_OVMF}" in
        *OVMF_CODE_4M.fd)
            OVMF_CODE="${PAIDEIA_OVMF}"
            OVMF_VARS="${PAIDEIA_OVMF_VARS:-${OVMF_CODE%OVMF_CODE_4M.fd}OVMF_VARS_4M.fd}"
            ;;
        *OVMF_CODE.fd)
            OVMF_CODE="${PAIDEIA_OVMF}"
            OVMF_VARS="${PAIDEIA_OVMF_VARS:-${OVMF_CODE%OVMF_CODE.fd}OVMF_VARS.fd}"
            ;;
        *OVMF.fd)
            # Merged blob (code + vars in one file) -- attach via -bios.
            OVMF_MERGED="${PAIDEIA_OVMF}"
            ;;
        *)
            # Unrecognized name; treat as CODE and require an
            # explicit PAIDEIA_OVMF_VARS.
            OVMF_CODE="${PAIDEIA_OVMF}"
            OVMF_VARS="${PAIDEIA_OVMF_VARS:-}"
            ;;
    esac
fi

if [[ -z "${OVMF_CODE}" && -z "${OVMF_MERGED}" ]]; then
    for candidate in \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/edk2/ovmf/OVMF_CODE.fd \
        /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
        /run/current-system/sw/share/OVMF/OVMF_CODE.fd; do
        if [[ -f "${candidate}" ]]; then
            OVMF_CODE="${candidate}"
            case "${candidate}" in
                *OVMF_CODE_4M.fd) OVMF_VARS="${candidate%OVMF_CODE_4M.fd}OVMF_VARS_4M.fd" ;;
                *OVMF_CODE.fd)    OVMF_VARS="${candidate%OVMF_CODE.fd}OVMF_VARS.fd" ;;
            esac
            break
        fi
    done
    if [[ -z "${OVMF_CODE}" ]]; then
        for candidate in \
            /usr/share/qemu/OVMF.fd \
            /usr/share/ovmf/OVMF.fd; do
            if [[ -f "${candidate}" ]]; then
                OVMF_MERGED="${candidate}"
                break
            fi
        done
    fi
fi

if [[ -z "${OVMF_CODE}" && -z "${OVMF_MERGED}" ]]; then
    echo "[t14-fidelity] SKIP: OVMF firmware not found" >&2
    echo "[t14-fidelity]       Debian/Ubuntu: apt install ovmf" >&2
    echo "[t14-fidelity]       Fedora:        dnf install edk2-ovmf" >&2
    echo "[t14-fidelity]       Arch:          pacman -S edk2-ovmf" >&2
    echo "[t14-fidelity]       or set PAIDEIA_OVMF=/path/to/OVMF_CODE.fd" >&2
    exit 77
fi

mkdir -p "${BUILD_DIR}"

# ---- NVMe backing image ---------------------------------------------
#
# A blank raw image (16 MiB) so the R111.M3-011..013 storage cascade
# has a real NVMe controller to attach.  Kept next to build/ rather
# than /tmp so it survives across smoke invocations for cross-boot
# state (matching tools/run-smoke.sh's --with-disk convention); pass
# --wipe to force re-init on the next boot.

if [[ ${WIPE} -eq 1 && -f "${NVME_IMG}" ]]; then
    rm -f "${NVME_IMG}"
fi

if [[ ! -f "${NVME_IMG}" ]]; then
    # Prefer qemu-img (creates a sparse raw); truncate fallback for
    # hosts without qemu-utils.
    if command -v qemu-img >/dev/null 2>&1; then
        qemu-img create -f raw "${NVME_IMG}" "${NVME_IMG_SIZE_MB}M" >/dev/null
    else
        truncate -s "${NVME_IMG_SIZE_MB}M" "${NVME_IMG}"
    fi
    echo "[t14-fidelity] created ${NVME_IMG} (${NVME_IMG_SIZE_MB} MiB, zero-init)"
fi

# ---- Firmware attachment --------------------------------------------
#
# Split CODE/VARS pair (per-run VARS copy so we do not dirty the
# system firmware -- OVMF writes to VARS on every boot to update the
# BootOrder / BootXXXX EFI variables).  Merged fallback for hosts
# where only /usr/share/qemu/OVMF.fd exists.

FIRMWARE_ARGS=()
if [[ -n "${OVMF_CODE}" ]]; then
    if [[ -n "${OVMF_VARS}" && -f "${OVMF_VARS}" ]]; then
        OVMF_VARS_COPY="${BUILD_DIR}/OVMF_VARS-t14fidelity-run.fd"
        cp "${OVMF_VARS}" "${OVMF_VARS_COPY}"
        FIRMWARE_ARGS=(
            -drive "if=pflash,format=raw,unit=0,file=${OVMF_CODE},readonly=on"
            -drive "if=pflash,format=raw,unit=1,file=${OVMF_VARS_COPY}"
        )
        echo "[t14-fidelity] firmware: split CODE=${OVMF_CODE} VARS=${OVMF_VARS_COPY}"
    elif [[ -n "${OVMF_MERGED}" ]]; then
        FIRMWARE_ARGS=(-bios "${OVMF_MERGED}")
        echo "[t14-fidelity] firmware: merged ${OVMF_MERGED} (fallback -- CODE had no matching VARS)"
    else
        echo "[t14-fidelity] FAIL: OVMF_CODE=${OVMF_CODE} but no matching VARS or merged OVMF.fd" >&2
        exit 2
    fi
else
    FIRMWARE_ARGS=(-bios "${OVMF_MERGED}")
    echo "[t14-fidelity] firmware: merged ${OVMF_MERGED}"
fi

# ---- Optional swtpm attachment --------------------------------------
#
# T14 G4 ships a real dTPM (Infineon SLB9673 on the LPC bus).  QEMU
# can emulate one via swtpm(1) speaking on a UNIX socket; the socket
# must be running before this script starts.  Opt-in via
# PAIDEIA_SWTPM_SOCKET; unset by default because starting swtpm
# out-of-band is out of scope for a self-contained smoke.  When the
# rest of the R32/R82 TPM consumer chain lands, this hook is where
# it plugs in.

TPM_ARGS=()
if [[ -n "${PAIDEIA_SWTPM_SOCKET:-}" ]]; then
    if [[ ! -S "${PAIDEIA_SWTPM_SOCKET}" ]]; then
        echo "[t14-fidelity] WARN: PAIDEIA_SWTPM_SOCKET=${PAIDEIA_SWTPM_SOCKET} is not a socket; skipping TPM attach" >&2
    else
        TPM_ARGS=(
            -chardev "socket,id=chrtpm,path=${PAIDEIA_SWTPM_SOCKET}"
            -tpmdev  "emulator,id=tpm0,chardev=chrtpm"
            -device  "tpm-crb,tpmdev=tpm0"
        )
        echo "[t14-fidelity] tpm: swtpm socket ${PAIDEIA_SWTPM_SOCKET}"
    fi
fi

# ---- QEMU invocation ------------------------------------------------
#
# Every device flag below is documented above in the header block.
# The ordering matters: xhci must come before usb-storage + usb-kbd
# because those two attach to it by bus id (xhci.0).

QEMU_ARGS=(
    # Chipset + firmware.
    -machine  q35
    -cpu      "${T14_CPU}"
    -smp      4
    -m        8G
    "${FIRMWARE_ARGS[@]}"

    # No graphical window; the FB witness runs entirely against the
    # GOP LFB the firmware provides.  Serial goes to stdio.
    -display  none
    -serial   stdio
    -no-reboot

    # VT-d: intremap=on because R111.M2-007's MSI-X + IR bring-up
    # requires the DMAR to have interrupt-remapping enabled or the
    # sibling MSIX IR OFF arm fires (which would fail the golden's
    # `MSIX IR TABLE OK` line -- once that line lands, which is
    # gated on this smoke).  caching-mode=on lets guests use their
    # own IOTLB invalidations, matching real T14 VT-d behavior.
    -device   "intel-iommu,intremap=on,caching-mode=on"

    # USB stack: real qemu-xhci controller, so R111.M5-017..019 has
    # a real xHCI to attach to.  ESP goes through it as a usb-storage
    # device (mimics T14 seeing a bootable USB stick).  Boot-protocol
    # keyboard is a usb-kbd on the same bus so R111.M5-019's HID
    # descriptor-parse path has an endpoint.
    -device   "qemu-xhci,id=xhci"
    -drive    "if=none,file=${IMG_PATH},format=raw,id=usb0"
    -device   "usb-storage,bus=xhci.0,drive=usb0,bootindex=1"
    -device   "usb-kbd,bus=xhci.0"

    # NVMe: real emulated controller with a blank backing image, so
    # the R111.M3-011..013 storage cascade has an attach target.
    -drive    "if=none,file=${NVME_IMG},format=raw,id=nvme0"
    -device   "nvme,drive=nvme0,serial=PDXT14FIDELITY0"

    # Audio: intel-hda + hda-duplex so R33..R39 audio witnesses can
    # compose with this recipe; not asserted by the shell-prompt
    # success criterion but harmless when unconsumed.
    -device   "intel-hda"
    -device   "hda-duplex"
)

# TPM (optional).
QEMU_ARGS+=("${TPM_ARGS[@]}")

# Operator passthrough (positional args after --wipe).
QEMU_ARGS+=("${PASSTHROUGH[@]}")

echo "[t14-fidelity] launching QEMU (timeout ${TIMEOUT_SEC}s)"
echo "[t14-fidelity]   image:   ${IMG_PATH}"
echo "[t14-fidelity]   cpu:     ${T14_CPU} (-smp 4 -m 8G)"
echo "[t14-fidelity]   success: '${SHELL_START_MARKER:=SHELL START}' on serial"

rm -f "${LOG_PATH}"

# `timeout` sends SIGTERM after TIMEOUT_SEC; -k 3 adds SIGKILL after
# a 3-second grace period so a wedged QEMU cannot outlive its wall.
# `|| true` because timeout(1) exits 124 on timeout; we still want to
# grep the captured log for post-hoc analysis.
timeout -k 3 "${TIMEOUT_SEC}" qemu-system-x86_64 "${QEMU_ARGS[@]}" \
    </dev/null >"${LOG_PATH}" 2>&1 || true

# ---- Fingerprint verification ---------------------------------------
#
# Two-tier check:
#   Tier 1: SHELL START must appear -- the shell-prompt witness.
#           Missing this means the boot did not reach ring-3.
#   Tier 2: every line of tests/expected-t14-fidelity.golden must
#           appear as an ordered substring of the log (matching
#           tools/run-smoke.sh's ordered-substring semantics).

if ! grep -qF -- "SHELL START" "${LOG_PATH}"; then
    echo "[t14-fidelity] FAIL: shell prompt did not fire (SHELL START missing) within ${TIMEOUT_SEC}s" >&2
    echo "[t14-fidelity]       last 40 lines of ${LOG_PATH}:" >&2
    tail -n 40 "${LOG_PATH}" >&2 || echo "  (log empty)" >&2
    exit 124
fi

# Ordered-substring golden check.  Read golden, walk log, each golden
# line must be found at or after the previous match's byte offset.
python3 - "${LOG_PATH}" "${GOLDEN_PATH}" <<'PYEOF'
import sys, io, os
log_path, golden_path = sys.argv[1], sys.argv[2]
with open(log_path, 'rb') as f:
    log = f.read()
with open(golden_path, 'r', encoding='utf-8') as f:
    golden = [ln.rstrip('\n') for ln in f if ln.strip() and not ln.startswith('#')]

cursor = 0
missing = []
for line in golden:
    needle = line.encode('utf-8')
    idx = log.find(needle, cursor)
    if idx < 0:
        missing.append(line)
    else:
        cursor = idx + len(needle)

if missing:
    sys.stderr.write("[t14-fidelity] FAIL: golden fingerprints missing (in order):\n")
    for m in missing:
        sys.stderr.write("  - " + m + "\n")
    sys.exit(1)
sys.exit(0)
PYEOF
GOLDEN_STATUS=$?

if [[ ${GOLDEN_STATUS} -ne 0 ]]; then
    echo "[t14-fidelity]       last 60 lines of ${LOG_PATH}:" >&2
    tail -n 60 "${LOG_PATH}" >&2 || echo "  (log empty)" >&2
    exit ${GOLDEN_STATUS}
fi

echo "[t14-fidelity] PASS: SHELL START + all golden fingerprints observed"
exit 0
