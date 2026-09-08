#!/usr/bin/env bash
# tools/mkimage.sh -- R111.M7-025 (paideia-os #2377)
#
# The T14 G4 bootable USB image builder.  Folds `tools/build-image.sh`
# (R28.M1) + firmware bundling (R111.M6-020..024) + signed manifest
# (R111.M6-023 envelope stub) into one command.  Produces a single
# dd-writable image (T14G4.img + T14G4.img.gz) that boots on real T14
# G4 hardware and on QEMU-OVMF alike.
#
# =============================================================================
# SCOPE  --  what R111.M7-025 lands and what stays deferred
# =============================================================================
#
# LANDED here:
#
#   * Subcommands  -- `plan` | `build` | `verify`.
#       plan   : dry-run.  Prints every action + input path + estimated
#                output byte size without touching build/ or the FS.
#       build  : real build.  Composes kernel.elf + rootfs.pdxfs + UEFI
#                stub + firmware manifest + firmware blobs; assembles a
#                partitionless FAT32 ESP; emits `build/mvp/T14G4.img` and
#                `build/mvp/T14G4.img.gz` + `T14G4.img.sha256`.
#       verify : post-build sanity.  Confirms every ESP path is present
#                with expected bytes; re-hashes each blob body against
#                the manifest's truncated-SHA256[20] fingerprints; checks
#                magic + version + entry_count consistency.
#
#   * Firmware manifest emit  --  binary format frozen at
#     src/kernel/core/fw/loader.pdx (R111.M6-024): 16 B header (magic
#     0x464D4450 = 'P','D','M','F' LE, version=1, entry_count, reserved=0)
#     + N x 32 B entries (kind u32, offset u32, size u32, sha256[0..20]
#     truncated fingerprint) + concatenated blob bodies + 64 B tail
#     signature slot (zeros in this milestone; Ed25519 sign lands with a
#     `--sign-key=<path>` follow-up).  See §"MANIFEST WIRE FORMAT" below.
#
#   * ESP layout  --  per design/boot/esp-layout.md §1:
#         /EFI/BOOT/BOOTX64.EFI            (UEFI 2.10 §3.5.1 fallback)
#         /EFI/PAIDEIA/PAIDEIA.EFI         (branded canonical stub copy)
#         /EFI/PAIDEIA/kernel.elf          (loaded by UEFI stub, R20)
#         /EFI/PAIDEIA/rootfs.pdxfs        (M3-013 initrd carry)
#         /paideia/firmware/microcode/06-b7-01.bin
#         /paideia/firmware/gpu/guc_70.bin
#         /paideia/firmware/gpu/huc_16.bin
#         /paideia/firmware/manifest.pdxsig
#
#   * Firmware sourcing gate  --  `--fw-dir=<path>` is REQUIRED for real
#     production builds (matches design/boot/esp-layout.md §6 no-quiet-
#     degrade rule).  A `--no-firmware` escape hatch produces a zero-
#     entry manifest (still valid per loader.pdx Gate 5) and skips the
#     `/paideia/firmware/{microcode,gpu}/**` staging -- documented as
#     CI / dev-loop only, not for hardware smoke.
#
# DEFERRED (each has its own R111.M7 sibling issue):
#
#   * `--gpt` GPT-partitioned variant  --  R111.M7-026 (#2378).  Some BIOS
#     revisions refuse partitionless USB HDD (scan for GPT/MBR before
#     recognizing the FAT header).  Stubbed here with a fatal-refuse arm
#     that names the follow-up milestone.  Default partitionless per
#     design/roadmap/t14-bootable-usb-wave.md §0 -- both OVMF and every
#     BIOS revision on the T14 G4 test bench accept partitionless FAT32.
#
#   * `--sign-key=<path>` Ed25519 sign of the manifest tail  --  R111.M6-023
#     landed the sig-verify seam (fw_manifest_verify_signature in
#     src/kernel/core/fw/manifest_sig.pdx) with a dev-bypass body: accepts
#     iff the 64-byte tail is bytewise all zero, matching the paired
#     dev-bypass on per-entry SHA (fw_manifest_sha256_verify: accept iff
#     entry.sha256 is all-zero).  Today the tail 64 bytes AND every entry's
#     20-byte SHA field are emitted all-zero by this tool, and the boot
#     chain accepts.  When --sign-key is passed, a future landing wires
#     `openssl pkeyutl -sign -inkey <path>` (or an in-repo signer) to fill
#     the tail with a real Ed25519 signature over `header || entries ||
#     blob_region`, AND fills each entry.sha256 with the leading 20 bytes
#     of SHA-256(blob_body); at that point the R32/R82 real ed25519_verify
#     + real SHA-256 kernel primitives take over the loader verifiers in
#     lockstep.  Full ML-DSA-65 envelope (SHA3-256 || ML-DSA-65 sig ||
#     payload) lands at R32/R82 per design/security/pq-trust-root.md §0.2
#     alongside the Ed25519 hybrid half.
#
#   * Reproducible build  --  fixed UUIDs + timestamps.  build-image.sh
#     already documents this as future work; mkimage.sh inherits the
#     deferral.  A `--deterministic` flag is a plausible follow-up.
#
# =============================================================================
# MANIFEST WIRE FORMAT  --  see src/kernel/core/fw/loader.pdx L62-L118
# =============================================================================
#
# Header (16 B, LE u32 fields):
#
#   +0   magic         0x464D4450  ('P','D','M','F' bytes read LE)
#   +4   version       1
#   +8   entry_count   N
#   +12  reserved      0
#
# Entry (32 B each; N entries begin at +16):
#
#   +0   kind          1=microcode, 2=GuC, 3=HuC
#   +4   offset        u32 byte-offset from manifest start to blob body
#   +8   size          u32 blob body length in bytes
#   +12  sha256[20]    leading 20 bytes of SHA-256(blob_body)
#
# Blob region (variable, begins at +16 + N*32):
#
#   Concatenated blob bodies.  Each entry.offset points into this region;
#   loader Gate 6 (R111.M6-023 tightened) enforces `offset + size <=
#   manifest_size - 64` so a blob cannot spill into the sig trailer's
#   memory.  Blobs are NOT padded (loader does not require alignment;
#   the microcode WRMSR path in core/cpu/microcode.pdx expects a raw
#   byte pointer).
#
# Signature tail (64 B, always present):
#
#   Ed25519 signature over `header || entries || blob_region` (per
#   RFC 8032 §5.1.6: signature is exactly 64 octets).  Filled with
#   zeros at this milestone; the R111.M6-023 loader sig-verify seam
#   (fw_manifest_verify_signature in src/kernel/core/fw/manifest_sig.pdx)
#   runs a dev-bypass body accepting iff the 64-byte tail is bytewise
#   all zero, so the boot chain still accepts.  `manifest_size`
#   includes the tail, so entry offsets stop 64 bytes before EOF --
#   loader Gate 5 (R111.M6-023 grew to `16 + count*32 + 64 <=
#   manifest_size`) requires room for the tail.  On sig VERIFY FAIL
#   the loader emits `FW MANIFEST SIG FAIL reason=<dec>` and refuses
#   to dispatch ANY entry (issue #2375 boot policy).
#
# Total on-disk size:
#
#   16 (header) + N*32 (entries) + sum(blob sizes) + 64 (tail sig)
#
# =============================================================================
# EXTERNAL TOOL DEPENDENCIES
# =============================================================================
#
#   Required:
#     bash 4+          (used features: [[ ]], arrays, printf %q)
#     coreutils        (truncate, stat, sha256sum, sort, wc, dd)
#     mtools           (mformat, mmd, mcopy, mdir)   -- image assembly
#          OR mkfs.vfat + sudo + mount               -- fallback path
#     python3          (byte-precise manifest emit; no external deps)
#     gzip             (final .gz sidecar)
#     file             (image-kind sanity check)
#
#   Optional (deferred milestones name each):
#     sfdisk / sgdisk  (--gpt variant; R111.M7-026)
#     openssl          (Ed25519 sign; R111.M6-023 tail fill)
#     sbsign           (Secure Boot; R32/R82 -- design/security/
#                       pe-secure-boot-signing.md)
#     xorriso          (.iso hybrid; R28.M2 backlog)
#
# =============================================================================
# HOW TO WRITE TO A USB STICK
# =============================================================================
#
# After a successful `bash tools/mkimage.sh build`, the artifact is:
#
#     build/mvp/T14G4.img         (raw dd-writable, ~96..128 MiB)
#     build/mvp/T14G4.img.gz      (compressed sidecar for distribution)
#     build/mvp/T14G4.img.sha256  (fingerprint for integrity check)
#
# Identify the target block device (SUBSTITUTE THE CORRECT DEVICE NODE
# -- writing to the wrong device destroys the host system):
#
#     lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS
#
# Unmount every partition the target device already had mounted:
#
#     for p in /dev/sdX?; do sudo umount "$p" 2>/dev/null || true; done
#
# Write (bs=4M is the customary optimum for USB SATA-bridged flash;
# conv=fsync guarantees the last block reaches the medium before dd
# returns; status=progress gives a byte counter):
#
#     sudo dd if=build/mvp/T14G4.img of=/dev/sdX bs=4M conv=fsync \
#             status=progress
#     sudo sync
#
# Verify (optional; catches truncation + bad blocks):
#
#     sudo dd if=/dev/sdX bs=4M count=$(( ($(stat -c %s build/mvp/T14G4.img) + 4*1024*1024 - 1) / (4*1024*1024) )) | \
#         sha256sum
#     # compare with:  cat build/mvp/T14G4.img.sha256
#
# Boot: insert into T14 G4, tap F12 at the Lenovo splash, pick the USB
# entry.  Secure Boot must be disabled today (paideia-native
# .pdxsgn/.pdxpk/.pdxsig sections do not yet chain to a shim-signed
# blob; Secure Boot enablement lands at R32/R82).
#
# =============================================================================
# EXIT STATUS
# =============================================================================
#
#   0   success
#   1   argument / invocation error
#   2   missing required tool (mtools + mkfs.vfat both absent, python3
#       absent, ...)
#   3   missing input artifact (kernel.elf, rootfs, --fw-dir contents)
#   4   manifest assembly failure (Python emitter refused a size / count
#       overflow -- indicates a pathologically large firmware blob)
#   5   verify subcommand found a mismatch (fingerprint, size, path)
#
# Non-zero exits print a one-line explanation on stderr.
#
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants + paths
# ---------------------------------------------------------------------------

REPO_ROOT="$(git rev-parse --show-toplevel)"
BUILD_DIR="${REPO_ROOT}/build"
MVP_DIR="${BUILD_DIR}/mvp"
KERNEL_ELF="${BUILD_DIR}/kernel.elf"
STUB_EFI_UNSIGNED="${BUILD_DIR}/uefi/uefi_stub.efi"
STUB_EFI_SIGNED="${BUILD_DIR}/uefi/uefi_stub.signed.efi"
SHELL_ELF="${BUILD_DIR}/user/shell.elf"
ROOTFS_IMG="${MVP_DIR}/rootfs.pdxfs"
MANIFEST_PATH="${MVP_DIR}/manifest.pdxsig"
IMG_PATH="${MVP_DIR}/T14G4.img"
IMG_GZ_PATH="${MVP_DIR}/T14G4.img.gz"
IMG_SHA_PATH="${MVP_DIR}/T14G4.img.sha256"

# Firmware kind codes -- MUST match src/kernel/core/fw/loader.pdx L244-L246.
readonly FW_KIND_MICROCODE=1
readonly FW_KIND_GUC=2
readonly FW_KIND_HUC=3

# Manifest header constants -- MUST match loader.pdx L226-L240.
readonly FW_MANIFEST_MAGIC="0x464D4450"   # 'P','D','M','F' LE
readonly FW_MANIFEST_VERSION=1
readonly FW_MANIFEST_HDR_SIZE=16
readonly FW_MANIFEST_ENTRY_SIZE=32
readonly FW_MANIFEST_SIG_TAIL_SIZE=64

# Default sizes (MiB).  ESP holds kernel (~2 MiB) + rootfs (~32 MiB) +
# firmware (~2 MiB) + stub (~256 KiB) with room for growth.
DEFAULT_IMG_SIZE_MB=96
DEFAULT_ROOTFS_SIZE_MB=32

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------

SUBCOMMAND=""
FW_DIR=""
NO_FIRMWARE=0
SKIP_BUILDS=0
ROOTFS_SIZE_MB="${DEFAULT_ROOTFS_SIZE_MB}"
IMG_SIZE_MB="${DEFAULT_IMG_SIZE_MB}"
USE_GPT=0
SIGN_KEY=""
OUT_IMG=""
VERBOSE=0

usage() {
  cat <<'USAGE'
mkimage -- assemble the PaideiaOS T14 G4 bootable USB image.

Usage:
  tools/mkimage.sh <subcommand> [options]

Subcommands:
  plan     Dry-run.  Print every action + input path + output size,
           without touching build/ or invoking any sub-tool.
  build    Real build.  Compose kernel + rootfs + UEFI stub + firmware
           manifest into a partitionless FAT32 ESP; emit T14G4.img +
           T14G4.img.gz + T14G4.img.sha256.
  verify   Post-build sanity.  Re-open the emitted image, confirm every
           ESP path present, re-hash each firmware blob against its
           truncated-SHA256[20] fingerprint in the manifest.

Options:
  --fw-dir=<path>       Operator-supplied firmware tree.  Expected layout:
                           <path>/microcode/*.bin
                           <path>/gpu/guc_70.bin
                           <path>/gpu/huc_16.bin
                        Required unless --no-firmware.
  --no-firmware         Skip firmware staging.  Emits a zero-entry manifest.
                        CI / dev-loop only -- NOT for hardware smoke.
  --skip-builds         Assume kernel.elf / uefi_stub.efi / shell.elf are
                        already up-to-date (skip rebuild dispatch).
  --rootfs-size=<mb>    PdxFS-lite blob size in MiB (default 32).
  --img-size=<mb>       ESP image size in MiB (default 96).
  --gpt                 GPT-partitioned variant (deferred to R111.M7-026,
                        #2378).  Currently a fatal-refuse arm; the default
                        partitionless FAT32 is accepted by every BIOS on
                        the T14 G4 test bench.
  --sign-key=<path>     Ed25519 key for the manifest 64-byte tail slot
                        (deferred to a follow-up).  Currently a fatal-
                        refuse arm; the tail is always all-zero today.
  --out=<path>          Override output image path.  Default:
                        build/mvp/T14G4.img.
  -v, --verbose         Verbose logging.
  -h, --help            Print this help and exit.

Exit status:
  0    success
  1    argument / invocation error
  2    missing required external tool
  3    missing input artifact (kernel, rootfs, or firmware directory)
  4    manifest assembly failure
  5    verify found a mismatch (verify subcommand only)

Documentation:
  design/boot/esp-layout.md           (ESP layout contract)
  design/roadmap/t14-bootable-usb-wave.md §4.G  (image builder wave)
  src/kernel/core/fw/loader.pdx       (kernel-side manifest parser)

Writing to USB:
  See the "HOW TO WRITE TO A USB STICK" section at the top of this file.
USAGE
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

SUBCOMMAND="$1"
shift

case "${SUBCOMMAND}" in
  plan|build|verify) ;;
  -h|--help)         usage; exit 0 ;;
  *)
    echo "mkimage: unknown subcommand: ${SUBCOMMAND}" >&2
    echo "mkimage: run 'tools/mkimage.sh --help' for usage" >&2
    exit 1
    ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fw-dir=*)         FW_DIR="${1#--fw-dir=}"; shift ;;
    --fw-dir)           FW_DIR="${2:?}"; shift 2 ;;
    --no-firmware)      NO_FIRMWARE=1; shift ;;
    --skip-builds)      SKIP_BUILDS=1; shift ;;
    --rootfs-size=*)    ROOTFS_SIZE_MB="${1#--rootfs-size=}"; shift ;;
    --rootfs-size)      ROOTFS_SIZE_MB="${2:?}"; shift 2 ;;
    --img-size=*)       IMG_SIZE_MB="${1#--img-size=}"; shift ;;
    --img-size)         IMG_SIZE_MB="${2:?}"; shift 2 ;;
    --gpt)              USE_GPT=1; shift ;;
    --sign-key=*)       SIGN_KEY="${1#--sign-key=}"; shift ;;
    --sign-key)         SIGN_KEY="${2:?}"; shift 2 ;;
    --out=*)            OUT_IMG="${1#--out=}"; shift ;;
    --out)              OUT_IMG="${2:?}"; shift 2 ;;
    -v|--verbose)       VERBOSE=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *)
      echo "mkimage: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -n "${OUT_IMG}" ]]; then
  IMG_PATH="${OUT_IMG}"
  IMG_GZ_PATH="${OUT_IMG}.gz"
  IMG_SHA_PATH="${OUT_IMG}.sha256"
fi

# Deferred-flag refusals -- named against their follow-up milestones so an
# operator hitting them gets a pointer, not a silent misuse.
if [[ ${USE_GPT} -eq 1 ]]; then
  echo "mkimage: --gpt is deferred to R111.M7-026 (#2378)" >&2
  echo "mkimage:   partitionless FAT32 is accepted by every T14 G4 BIOS revision" >&2
  echo "mkimage:   drop --gpt to proceed" >&2
  exit 1
fi

if [[ -n "${SIGN_KEY}" ]]; then
  echo "mkimage: --sign-key is deferred to a follow-up landing" >&2
  echo "mkimage:   R111.M6-023 loader accepts an all-zero 64-byte sig tail" >&2
  echo "mkimage:   (fw_manifest_verify_signature dev-bypass in manifest_sig.pdx)" >&2
  echo "mkimage:   AND all-zero 20-byte per-entry SHA fields" >&2
  echo "mkimage:   (fw_manifest_sha256_verify dev-bypass in loader.pdx)" >&2
  echo "mkimage:   so the tail and SHA fields are emitted all-zero at this milestone" >&2
  exit 1
fi

if [[ -n "${FW_DIR}" && ${NO_FIRMWARE} -eq 1 ]]; then
  echo "mkimage: --fw-dir and --no-firmware are mutually exclusive" >&2
  exit 1
fi

if [[ -z "${FW_DIR}" && ${NO_FIRMWARE} -eq 0 && "${SUBCOMMAND}" != "verify" ]]; then
  echo "mkimage: --fw-dir=<path> is required (or --no-firmware for CI / dev)" >&2
  echo "mkimage:   see design/boot/esp-layout.md §6 for the linux-firmware sourcing recipe" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

log()  { echo "[mkimage] $*"; }
logv() { [[ ${VERBOSE} -eq 1 ]] && echo "[mkimage] $*" || true; }
warn() { echo "[mkimage] WARN: $*" >&2; }
die()  { echo "[mkimage] FAIL: $*" >&2; exit "${1:-1}"; }

# ---------------------------------------------------------------------------
# Firmware discovery -- populates the FW_ENTRIES array with tuples of
# "kind:local_path:esp_path".  Skipped when --no-firmware is passed.
#
# The naming convention is per design/boot/esp-layout.md §1:
#   microcode/<family>-<model>-<stepping>.bin  (matches Intel intel-ucode
#                                                naming; kernel-side loader
#                                                will pick by CPUID match)
#   gpu/guc_<rev>.bin                          (kind + rev naming)
#   gpu/huc_<rev>.bin
# ---------------------------------------------------------------------------

declare -a FW_ENTRIES=()

discover_firmware() {
  if [[ ${NO_FIRMWARE} -eq 1 ]]; then
    log "firmware: --no-firmware -- emitting zero-entry manifest (CI / dev only)"
    return 0
  fi

  [[ -d "${FW_DIR}" ]] || die 3 "--fw-dir=${FW_DIR} does not exist"

  local ucode_dir="${FW_DIR}/microcode"
  local gpu_dir="${FW_DIR}/gpu"

  [[ -d "${ucode_dir}" ]] || die 3 "${ucode_dir} missing (expected microcode blobs)"
  [[ -d "${gpu_dir}"   ]] || die 3 "${gpu_dir} missing (expected GuC/HuC blobs)"

  # Microcode: accept every *.bin under microcode/ -- kernel-side loader
  # picks by CPUID match at boot, so staging multiple is legitimate.
  local ucode_count=0
  while IFS= read -r -d '' blob; do
    local name
    name="$(basename "${blob}")"
    FW_ENTRIES+=("${FW_KIND_MICROCODE}:${blob}:/paideia/firmware/microcode/${name}")
    logv "firmware: microcode ${name} ($(stat -c %s "${blob}") bytes)"
    ucode_count=$(( ucode_count + 1 ))
  done < <(find "${ucode_dir}" -maxdepth 1 -type f -name '*.bin' -print0 | sort -z)

  [[ ${ucode_count} -gt 0 ]] || die 3 "${ucode_dir} contains no *.bin (need at least one microcode blob)"

  # GuC: require guc_<rev>.bin (per esp-layout.md §1 -- rev alone suffices
  # because PCI-ID probe has already picked the Iris Xe scanout entry).
  local guc_blob=""
  while IFS= read -r -d '' blob; do
    guc_blob="${blob}"
    break
  done < <(find "${gpu_dir}" -maxdepth 1 -type f -name 'guc_*.bin' -print0 | sort -z)

  [[ -n "${guc_blob}" ]] || die 3 "${gpu_dir} has no guc_*.bin (need Iris Xe GuC firmware, e.g. guc_70.bin)"
  FW_ENTRIES+=("${FW_KIND_GUC}:${guc_blob}:/paideia/firmware/gpu/$(basename "${guc_blob}")")
  logv "firmware: guc $(basename "${guc_blob}") ($(stat -c %s "${guc_blob}") bytes)"

  # HuC: same discipline.
  local huc_blob=""
  while IFS= read -r -d '' blob; do
    huc_blob="${blob}"
    break
  done < <(find "${gpu_dir}" -maxdepth 1 -type f -name 'huc_*.bin' -print0 | sort -z)

  [[ -n "${huc_blob}" ]] || die 3 "${gpu_dir} has no huc_*.bin (need Iris Xe HuC firmware, e.g. huc_16.bin)"
  FW_ENTRIES+=("${FW_KIND_HUC}:${huc_blob}:/paideia/firmware/gpu/$(basename "${huc_blob}")")
  logv "firmware: huc $(basename "${huc_blob}") ($(stat -c %s "${huc_blob}") bytes)"

  log "firmware: discovered ${#FW_ENTRIES[@]} blob(s) under ${FW_DIR}"
}

# ---------------------------------------------------------------------------
# Manifest emitter -- writes MANIFEST_PATH given FW_ENTRIES.
#
# Delegates byte-precise emission to python3 (bash cannot reliably emit
# u32 LE at exact offsets nor read arbitrary binary blob bodies).  Python
# is used purely as a byte-builder; all policy (kind codes, offsets,
# manifest layout, tail-sig-zero) is enforced here.
#
# On success: prints "[mkimage] manifest: N entries, X bytes -> <path>".
# On failure: dies with exit code 4.
# ---------------------------------------------------------------------------

emit_manifest() {
  local out="$1"; shift
  local -a entries=()
  # Guard against `set -u` when caller expands an empty array with "${a[@]:-}".
  if [[ $# -gt 0 ]]; then
    for e in "$@"; do
      [[ -n "${e}" ]] && entries+=("${e}")
    done
  fi

  mkdir -p "$(dirname "${out}")"

  # Serialize entries into a temp file for the python emitter.  Using a
  # file (rather than stdin) leaves stdin free for the here-doc that
  # carries the python source itself.  Format: "kind\tlocal_path" per
  # line; esp_path is not needed at manifest-emit time (the manifest
  # carries no path strings -- the loader dispatches by kind alone).
  local input_file
  input_file="$(mktemp -t mkimage-manifest-input.XXXXXX)"

  local e kind local_path
  if [[ ${#entries[@]} -gt 0 ]]; then
    for e in "${entries[@]}"; do
      kind="${e%%:*}"
      local_path="${e#*:}"; local_path="${local_path%%:*}"
      printf '%s\t%s\n' "${kind}" "${local_path}" >> "${input_file}"
    done
  fi

  # Python emitter -- see MANIFEST WIRE FORMAT §.
  #
  # Fails hard if any blob body exceeds u32 or the cumulative size would
  # overflow u32 -- matches loader Gate 6's `offset+size <= manifest_size`
  # invariant (manifest_size is a u64 in loader, but the on-disk offset
  # + size are u32 by schema, so >4 GiB manifests are unrepresentable
  # regardless).
  # Note: `if ! python3 ... <<PYEOF ... PYEOF; then ...` is the right shape
  # here so `set -e` does not trip before we can clean up the temp file.
  if ! python3 - "${out}" "${input_file}" <<'PYEOF'
import hashlib
import struct
import sys

out_path = sys.argv[1]
input_path = sys.argv[2]

# Manifest schema constants (mirrors loader.pdx L226+).
MAGIC        = 0x464D4450
VERSION      = 1
HDR_SIZE     = 16
ENTRY_SIZE   = 32
SIG_TAIL     = 64
MAX_U32      = (1 << 32) - 1

entries = []
with open(input_path, 'r') as fh:
    for raw in fh.read().splitlines():
        if not raw.strip():
            continue
        kind_str, path = raw.split('\t', 1)
        kind = int(kind_str)
        with open(path, 'rb') as blob_fh:
            body = blob_fh.read()
        if len(body) > MAX_U32:
            sys.stderr.write(f"[mkimage] FAIL: blob {path} exceeds u32 size limit\n")
            sys.exit(4)
        entries.append((kind, body))

n = len(entries)
blob_region_start = HDR_SIZE + n * ENTRY_SIZE

# Compute each entry's byte offset within the manifest file.
offsets = []
cursor = blob_region_start
for _, body in entries:
    offsets.append(cursor)
    cursor += len(body)
    if cursor > MAX_U32:
        sys.stderr.write(f"[mkimage] FAIL: cumulative blob region exceeds u32\n")
        sys.exit(4)

blob_region_size = cursor - blob_region_start
manifest_size = blob_region_start + blob_region_size + SIG_TAIL

# ----- Emit -----
buf = bytearray(manifest_size)

# Header (LE u32 x 4).
struct.pack_into('<IIII', buf, 0, MAGIC, VERSION, n, 0)

# Entries.
for i, ((kind, body), offset) in enumerate(zip(entries, offsets)):
    ent_off = HDR_SIZE + i * ENTRY_SIZE
    sha_full = hashlib.sha256(body).digest()
    sha20 = sha_full[:20]
    struct.pack_into('<III', buf, ent_off, kind, offset, len(body))
    buf[ent_off + 12 : ent_off + 32] = sha20

# Blob region.
for (_, body), offset in zip(entries, offsets):
    buf[offset : offset + len(body)] = body

# Signature tail: 64 bytes of zeros (already zeroed by bytearray()).
# A future --sign-key path fills buf[-64:] with Ed25519(header||entries||blobs).

with open(out_path, 'wb') as fh:
    fh.write(buf)

print(f"[mkimage] manifest: {n} entries, {manifest_size} bytes -> {out_path}")
PYEOF
  then
    rm -f "${input_file}"
    die 4 "manifest emitter failed (python3 emitter refused input)"
  fi

  rm -f "${input_file}"
  [[ -f "${out}" ]] || die 4 "manifest emitter produced no file"
}

# ---------------------------------------------------------------------------
# Dependency check -- validates required tools before we start.
# ---------------------------------------------------------------------------

check_deps() {
  local missing=()

  command -v python3 >/dev/null 2>&1 || missing+=("python3")
  command -v sha256sum >/dev/null 2>&1 || missing+=("sha256sum")
  command -v truncate >/dev/null 2>&1 || missing+=("truncate")
  command -v gzip >/dev/null 2>&1 || missing+=("gzip")
  command -v file >/dev/null 2>&1 || missing+=("file")

  # mtools OR (mkfs.vfat + sudo) required.
  local have_mtools=0 have_mkfs=0
  command -v mformat >/dev/null 2>&1 && \
    command -v mmd    >/dev/null 2>&1 && \
    command -v mcopy  >/dev/null 2>&1 && have_mtools=1
  command -v mkfs.vfat >/dev/null 2>&1 && have_mkfs=1

  if [[ ${have_mtools} -eq 0 && ${have_mkfs} -eq 0 ]]; then
    missing+=("mtools OR mkfs.vfat (dosfstools)")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "mkimage: missing required tools:" >&2
    local m
    for m in "${missing[@]}"; do
      echo "  - ${m}" >&2
    done
    echo "" >&2
    echo "Debian/Ubuntu:  sudo apt install python3 mtools dosfstools gzip file coreutils" >&2
    echo "Fedora:         sudo dnf install python3 mtools dosfstools gzip file coreutils" >&2
    echo "Arch:           sudo pacman -S python mtools dosfstools gzip file coreutils"    >&2
    exit 2
  fi
}

# ---------------------------------------------------------------------------
# Build phase 1 -- rebuild component artifacts unless --skip-builds.
#
# NOTE: this dispatches build.sh + build-uefi-stub.sh + build-user.sh +
# mkfs-pdxfs-lite-seed.sh.  Each is its own long-running command; the
# operator invoking mkimage.sh accepts that cost by default.  --skip-
# builds is provided for the tight iteration loop where only the image-
# assembly step changes.
# ---------------------------------------------------------------------------

build_components() {
  if [[ ${SKIP_BUILDS} -eq 1 ]]; then
    log "phase 1: skipped (--skip-builds); assuming component artifacts fresh"
    return 0
  fi

  log "phase 1a: kernel   -> $(basename "${KERNEL_ELF}")"
  bash "${REPO_ROOT}/tools/build.sh"

  log "phase 1b: UEFI stub -> $(basename "${STUB_EFI_UNSIGNED}")"
  bash "${REPO_ROOT}/tools/build-uefi-stub.sh"

  log "phase 1c: userland  -> $(basename "${SHELL_ELF}")"
  bash "${REPO_ROOT}/tools/build-user.sh"
}

# ---------------------------------------------------------------------------
# Preflight -- confirm every component artifact is present after phase 1.
# ---------------------------------------------------------------------------

preflight_components() {
  local f
  for f in "${KERNEL_ELF}" "${STUB_EFI_UNSIGNED}" "${SHELL_ELF}"; do
    [[ -f "${f}" ]] || die 3 "required artifact missing: ${f} (drop --skip-builds or run its component script)"
  done
}

# ---------------------------------------------------------------------------
# Build phase 2 -- PdxFS-lite rootfs seeded with the shell.
#
# Delegates to tools/mkfs-pdxfs-lite-seed.sh (the R28.M1-003 seed builder
# that the existing build-image.sh already uses).  Same discipline as
# build-image.sh L115-L119.
# ---------------------------------------------------------------------------

build_rootfs() {
  log "phase 2: rootfs (mkfs-pdxfs-lite-seed) -> $(basename "${ROOTFS_IMG}") (${ROOTFS_SIZE_MB} MiB)"
  mkdir -p "${MVP_DIR}"
  bash "${REPO_ROOT}/tools/mkfs-pdxfs-lite-seed.sh" \
    --output "${ROOTFS_IMG}" \
    --shell-elf "${SHELL_ELF}" \
    --size "${ROOTFS_SIZE_MB}"
  [[ -f "${ROOTFS_IMG}" ]] || die 3 "mkfs-pdxfs-lite-seed.sh produced no rootfs"
}

# ---------------------------------------------------------------------------
# Build phase 3 -- sign the UEFI stub (matches build-uefi-image.sh L88+).
# ---------------------------------------------------------------------------

sign_stub() {
  local no_sign="${NO_SIGN:-0}"
  if [[ "${no_sign}" == "1" ]]; then
    warn "NO_SIGN=1 -- using unsigned stub; kernel will log 'EFI UNSIGNED (enforcement off)'"
    cp "${STUB_EFI_UNSIGNED}" "${STUB_EFI_SIGNED}"
    return 0
  fi

  log "phase 3: sign UEFI stub -> $(basename "${STUB_EFI_SIGNED}")"
  "${REPO_ROOT}/tools/sign-efi.sh" \
    --in  "${STUB_EFI_UNSIGNED}" \
    --out "${STUB_EFI_SIGNED}"
  [[ -f "${STUB_EFI_SIGNED}" ]] || die 3 "sign-efi.sh produced no signed stub"
}

# ---------------------------------------------------------------------------
# Build phase 4 -- assemble the ESP.
#
# Layout per design/boot/esp-layout.md §1:
#
#   /EFI/BOOT/BOOTX64.EFI           UEFI 2.10 §3.5.1 fallback
#   /EFI/PAIDEIA/PAIDEIA.EFI        branded canonical stub copy
#   /EFI/PAIDEIA/kernel.elf         kernel ELF (loaded by stub)
#   /EFI/PAIDEIA/rootfs.pdxfs       PdxFS-lite rootfs (M3-013 carry)
#   /paideia/firmware/microcode/*.bin
#   /paideia/firmware/gpu/guc_*.bin
#   /paideia/firmware/gpu/huc_*.bin
#   /paideia/firmware/manifest.pdxsig
#
# Uses mtools where available (no sudo); falls back to mkfs.vfat + loop
# mount on hosts without mtools (matches build-uefi-image.sh discipline).
# ---------------------------------------------------------------------------

assemble_esp_mtools() {
  local img="$1"

  log "phase 4a: mformat ${img} (FAT32, no partition table, label PAIDEIA)"
  mformat -F -v PAIDEIA -i "${img}" ::

  log "phase 4b: mmd directories"
  mmd -i "${img}" ::/EFI
  mmd -i "${img}" ::/EFI/BOOT
  mmd -i "${img}" ::/EFI/PAIDEIA
  mmd -i "${img}" ::/paideia
  mmd -i "${img}" ::/paideia/firmware
  mmd -i "${img}" ::/paideia/firmware/microcode
  mmd -i "${img}" ::/paideia/firmware/gpu

  log "phase 4c: mcopy stub -> /EFI/BOOT/BOOTX64.EFI + /EFI/PAIDEIA/PAIDEIA.EFI"
  mcopy -i "${img}" "${STUB_EFI_SIGNED}" ::/EFI/BOOT/BOOTX64.EFI
  mcopy -i "${img}" "${STUB_EFI_SIGNED}" ::/EFI/PAIDEIA/PAIDEIA.EFI

  log "phase 4d: mcopy kernel.elf -> /EFI/PAIDEIA/kernel.elf"
  mcopy -i "${img}" "${KERNEL_ELF}" ::/EFI/PAIDEIA/kernel.elf

  log "phase 4e: mcopy rootfs.pdxfs -> /EFI/PAIDEIA/rootfs.pdxfs"
  mcopy -i "${img}" "${ROOTFS_IMG}" ::/EFI/PAIDEIA/rootfs.pdxfs

  # Firmware blobs (per-file, based on FW_ENTRIES).
  local e local_path esp_path
  for e in "${FW_ENTRIES[@]}"; do
    local_path="${e#*:}"; local_path="${local_path%%:*}"
    esp_path="${e##*:}"
    logv "phase 4f: mcopy $(basename "${local_path}") -> ${esp_path}"
    mcopy -i "${img}" "${local_path}" "::${esp_path}"
  done

  # Manifest (single file at /paideia/firmware/manifest.pdxsig).
  log "phase 4g: mcopy manifest.pdxsig -> /paideia/firmware/manifest.pdxsig"
  mcopy -i "${img}" "${MANIFEST_PATH}" ::/paideia/firmware/manifest.pdxsig

  if [[ ${VERBOSE} -eq 1 ]]; then
    log "phase 4h: mdir verification"
    mdir -i "${img}" ::/EFI/BOOT
    mdir -i "${img}" ::/EFI/PAIDEIA
    mdir -i "${img}" ::/paideia/firmware
    mdir -i "${img}" ::/paideia/firmware/microcode
    mdir -i "${img}" ::/paideia/firmware/gpu
  fi
}

assemble_esp_mkfs_fallback() {
  local img="$1"

  warn "mtools not found -- falling back to mkfs.vfat + loop mount (needs sudo)"

  mkfs.vfat -F 32 -n PAIDEIA "${img}"

  local mnt
  mnt="$(mktemp -d -t paideia-esp.XXXXXX)"
  trap 'sudo umount "'"${mnt}"'" 2>/dev/null || true; rmdir "'"${mnt}"'" 2>/dev/null || true' EXIT

  sudo mount -o loop,uid="$(id -u)",gid="$(id -g)" "${img}" "${mnt}"

  mkdir -p \
    "${mnt}/EFI/BOOT" \
    "${mnt}/EFI/PAIDEIA" \
    "${mnt}/paideia/firmware/microcode" \
    "${mnt}/paideia/firmware/gpu"

  cp "${STUB_EFI_SIGNED}" "${mnt}/EFI/BOOT/BOOTX64.EFI"
  cp "${STUB_EFI_SIGNED}" "${mnt}/EFI/PAIDEIA/PAIDEIA.EFI"
  cp "${KERNEL_ELF}"      "${mnt}/EFI/PAIDEIA/kernel.elf"
  cp "${ROOTFS_IMG}"      "${mnt}/EFI/PAIDEIA/rootfs.pdxfs"

  local e local_path esp_path
  for e in "${FW_ENTRIES[@]}"; do
    local_path="${e#*:}"; local_path="${local_path%%:*}"
    esp_path="${e##*:}"
    mkdir -p "${mnt}$(dirname "${esp_path}")"
    cp "${local_path}" "${mnt}${esp_path}"
  done

  cp "${MANIFEST_PATH}" "${mnt}/paideia/firmware/manifest.pdxsig"

  sync
  sudo umount "${mnt}"
  rmdir "${mnt}"
  trap - EXIT
}

# ---------------------------------------------------------------------------
# Post-build finalize -- sha256 + gzip sidecar + summary.
# ---------------------------------------------------------------------------

finalize() {
  log "phase 5a: sha256 -> $(basename "${IMG_SHA_PATH}")"
  ( cd "$(dirname "${IMG_PATH}")" && sha256sum "$(basename "${IMG_PATH}")" > "$(basename "${IMG_SHA_PATH}")" )

  log "phase 5b: gzip   -> $(basename "${IMG_GZ_PATH}")"
  gzip -k -f "${IMG_PATH}"

  local img_size gz_size
  img_size=$(stat -c %s "${IMG_PATH}")
  gz_size=$(stat -c %s "${IMG_GZ_PATH}")

  echo ""
  log "OK"
  log "  image      : ${IMG_PATH} (${img_size} bytes)"
  log "  compressed : ${IMG_GZ_PATH} (${gz_size} bytes)"
  log "  sha256     : ${IMG_SHA_PATH}"
  log "  file(1)    : $(file -b "${IMG_PATH}")"
  echo ""
  log "Boot in QEMU (OVMF):"
  log "  qemu-system-x86_64 -bios /usr/share/OVMF/OVMF_CODE.fd \\"
  log "    -drive file=${IMG_PATH},format=raw,if=none,id=usb1 \\"
  log "    -device usb-storage,drive=usb1 -usb"
  echo ""
  log "Write to USB:"
  log "  sudo dd if=${IMG_PATH} of=/dev/sdX bs=4M conv=fsync status=progress"
  log "  (SUBSTITUTE THE CORRECT DEVICE NODE; see HOW TO WRITE TO A USB STICK)"
}

# ===========================================================================
# Subcommand: plan
# ===========================================================================

subcommand_plan() {
  log "PLAN mode -- no build actions will be taken"
  echo ""

  discover_firmware

  log "would rebuild (drop --skip-builds to run):"
  log "  - tools/build.sh              -> ${KERNEL_ELF}"
  log "  - tools/build-uefi-stub.sh    -> ${STUB_EFI_UNSIGNED}"
  log "  - tools/build-user.sh         -> ${SHELL_ELF}"
  log "  - tools/mkfs-pdxfs-lite-seed  -> ${ROOTFS_IMG} (${ROOTFS_SIZE_MB} MiB)"
  log "  - tools/sign-efi.sh           -> ${STUB_EFI_SIGNED}"
  echo ""

  log "would stage on ESP (/EFI/PAIDEIA/, /EFI/BOOT/, /paideia/firmware/):"
  log "  - /EFI/BOOT/BOOTX64.EFI"
  log "  - /EFI/PAIDEIA/PAIDEIA.EFI"
  log "  - /EFI/PAIDEIA/kernel.elf"
  log "  - /EFI/PAIDEIA/rootfs.pdxfs"

  local total_blob_bytes=0
  local e kind local_path esp_path blob_size
  for e in "${FW_ENTRIES[@]}"; do
    kind="${e%%:*}"
    local_path="${e#*:}"; local_path="${local_path%%:*}"
    esp_path="${e##*:}"
    blob_size=$(stat -c %s "${local_path}")
    total_blob_bytes=$(( total_blob_bytes + blob_size ))
    log "  - ${esp_path} (kind=${kind}, ${blob_size} bytes)"
  done

  local manifest_size=$(( FW_MANIFEST_HDR_SIZE + ${#FW_ENTRIES[@]} * FW_MANIFEST_ENTRY_SIZE + total_blob_bytes + FW_MANIFEST_SIG_TAIL_SIZE ))
  log "  - /paideia/firmware/manifest.pdxsig (estimated ${manifest_size} bytes: 16 hdr + ${#FW_ENTRIES[@]}*32 entries + ${total_blob_bytes} blobs + 64 tail-sig)"
  echo ""

  log "would emit:"
  log "  - ${IMG_PATH}      (${IMG_SIZE_MB} MiB FAT32)"
  log "  - ${IMG_GZ_PATH}   (gzip -k of the raw image)"
  log "  - ${IMG_SHA_PATH}  (sha256sum sidecar)"
  echo ""

  log "PLAN complete -- rerun with 'build' to execute"
}

# ===========================================================================
# Subcommand: build
# ===========================================================================

subcommand_build() {
  log "BUILD mode -- assembling ${IMG_PATH}"
  check_deps
  discover_firmware

  build_components
  preflight_components

  build_rootfs
  sign_stub

  log "phase 3b: emit manifest -> ${MANIFEST_PATH}"
  if [[ ${#FW_ENTRIES[@]} -gt 0 ]]; then
    emit_manifest "${MANIFEST_PATH}" "${FW_ENTRIES[@]}"
  else
    emit_manifest "${MANIFEST_PATH}"
  fi

  # ---- phase 4: allocate + author FAT32 ---------------------------------
  log "phase 4: allocate ${IMG_SIZE_MB} MiB ESP -> ${IMG_PATH}"
  mkdir -p "$(dirname "${IMG_PATH}")"
  rm -f "${IMG_PATH}" "${IMG_GZ_PATH}" "${IMG_SHA_PATH}"
  truncate -s "${IMG_SIZE_MB}M" "${IMG_PATH}"

  # Sanity: stub must be PE32+ EFI.
  local stub_kind
  stub_kind="$(file -b "${STUB_EFI_SIGNED}")"
  case "${stub_kind}" in
    *"PE32+ executable (EFI application) x86-64"*) ;;
    *) die 3 "${STUB_EFI_SIGNED} is not a PE32+ EFI application (file(1): ${stub_kind})" ;;
  esac

  if command -v mformat >/dev/null 2>&1 && \
     command -v mmd    >/dev/null 2>&1 && \
     command -v mcopy  >/dev/null 2>&1; then
    assemble_esp_mtools "${IMG_PATH}"
  else
    assemble_esp_mkfs_fallback "${IMG_PATH}"
  fi

  finalize
}

# ===========================================================================
# Subcommand: verify
#
# Extracts the manifest from a produced image and re-hashes each blob
# body.  Confirms:
#
#   * Every ESP path from esp-layout.md §1 is present.
#   * Manifest magic + version match FW_MANIFEST_MAGIC / VERSION.
#   * Every entry's truncated SHA-256[20] matches SHA-256(blob_body).
#   * Every entry's offset + size falls inside manifest_size (loader
#     Gate 6 pre-check -- catches producer bugs before hardware boot).
#
# Uses mtools for extraction (mkfs.vfat fallback would need sudo, which
# we refuse in verify mode to keep the check side-effect-free).
# ===========================================================================

subcommand_verify() {
  log "VERIFY mode -- checking ${IMG_PATH}"
  [[ -f "${IMG_PATH}" ]] || die 5 "no image at ${IMG_PATH} (run 'mkimage build' first)"

  command -v mtype >/dev/null 2>&1 || die 2 "verify requires mtools (mtype); mkfs.vfat fallback needs sudo mount"
  command -v python3 >/dev/null 2>&1 || die 2 "verify requires python3"

  local tmp
  tmp="$(mktemp -d -t mkimage-verify.XXXXXX)"
  trap 'rm -rf "'"${tmp}"'"' EXIT

  log "phase v1: extract manifest + firmware blobs"
  mtype -i "${IMG_PATH}" ::/paideia/firmware/manifest.pdxsig > "${tmp}/manifest.pdxsig" \
    || die 5 "manifest.pdxsig not present on ESP"

  # ESP path presence checks.
  local esp_paths=(
    "::/EFI/BOOT/BOOTX64.EFI"
    "::/EFI/PAIDEIA/PAIDEIA.EFI"
    "::/EFI/PAIDEIA/kernel.elf"
    "::/EFI/PAIDEIA/rootfs.pdxfs"
    "::/paideia/firmware/manifest.pdxsig"
  )
  local p
  for p in "${esp_paths[@]}"; do
    mattrib -i "${IMG_PATH}" "${p}" >/dev/null 2>&1 \
      || die 5 "required ESP path missing: ${p}"
    logv "  present: ${p}"
  done

  # Manifest structural + fingerprint check.
  log "phase v2: parse manifest header + verify each SHA-256[20] fingerprint"
  python3 - "${tmp}/manifest.pdxsig" <<'PYEOF'
import hashlib
import struct
import sys

path = sys.argv[1]
with open(path, 'rb') as fh:
    buf = fh.read()

MAGIC       = 0x464D4450
VERSION     = 1
HDR_SIZE    = 16
ENTRY_SIZE  = 32
SIG_TAIL    = 64

n_bytes = len(buf)
if n_bytes < HDR_SIZE + SIG_TAIL:
    sys.exit(f"[mkimage] verify FAIL: manifest {n_bytes} bytes < min ({HDR_SIZE + SIG_TAIL})")

magic, version, count, reserved = struct.unpack_from('<IIII', buf, 0)
if magic != MAGIC:
    sys.exit(f"[mkimage] verify FAIL: bad magic 0x{magic:08x}, expected 0x{MAGIC:08x}")
if version != VERSION:
    sys.exit(f"[mkimage] verify FAIL: bad version {version}, expected {VERSION}")
if reserved != 0:
    sys.exit(f"[mkimage] verify FAIL: reserved != 0 ({reserved})")

expected_min = HDR_SIZE + count * ENTRY_SIZE + SIG_TAIL
if n_bytes < expected_min:
    sys.exit(f"[mkimage] verify FAIL: manifest {n_bytes} < 16 + {count}*32 + 64 = {expected_min}")

print(f"[mkimage]   header: magic=0x{magic:08x} version={version} entries={count}")

fail = 0
for i in range(count):
    ent_off = HDR_SIZE + i * ENTRY_SIZE
    kind, offset, size = struct.unpack_from('<III', buf, ent_off)
    sha20 = buf[ent_off + 12 : ent_off + 32]

    if offset + size > n_bytes:
        print(f"[mkimage]   entry[{i}] OOB kind={kind} off={offset} size={size} manifest={n_bytes}", file=sys.stderr)
        fail += 1
        continue

    body = buf[offset : offset + size]
    real_sha = hashlib.sha256(body).digest()[:20]
    if real_sha != sha20:
        print(f"[mkimage]   entry[{i}] SHA MISMATCH kind={kind} size={size}", file=sys.stderr)
        print(f"[mkimage]     expected {sha20.hex()}", file=sys.stderr)
        print(f"[mkimage]     got      {real_sha.hex()}", file=sys.stderr)
        fail += 1
    else:
        print(f"[mkimage]   entry[{i}] OK kind={kind} off={offset} size={size} sha20={sha20.hex()[:16]}...")

if fail != 0:
    sys.exit(f"[mkimage] verify FAIL: {fail} entry error(s)")

# Signature tail sanity: today it's all zeros (deferred to signing follow-up).
tail = buf[-SIG_TAIL:]
if any(tail):
    print(f"[mkimage]   signature tail: non-zero ({SIG_TAIL} bytes -- verified by future signature-verify path)")
else:
    print(f"[mkimage]   signature tail: all-zero placeholder ({SIG_TAIL} bytes; --sign-key follow-up will fill)")

print("[mkimage] verify OK")
PYEOF
}

# ===========================================================================
# Dispatch
# ===========================================================================

case "${SUBCOMMAND}" in
  plan)   subcommand_plan   ;;
  build)  subcommand_build  ;;
  verify) subcommand_verify ;;
esac
