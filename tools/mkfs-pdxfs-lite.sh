#!/usr/bin/env bash
# tools/mkfs-pdxfs-lite.sh — R25-M3-001..004 (#920, #921, #922, #923)
#
# Host-side mkfs for PdxFS-lite v0. Emits a filesystem image that matches the
# on-disk layout frozen in design/filesystem/pdxfs-lite-format.md and the
# in-kernel constants in src/kernel/core/fs/pdxfs_lite/superblock.pdx +
# src/kernel/core/fs/pdxfs_lite/inode.pdx.
#
# Layout produced:
#   LBA 0        superblock (4 KiB) — magic "PDXL", version 1, block_size 4096,
#                fixed itable_lba=1 / itable_bcount=8 (256 inodes),
#                extent_area_lba=9 / extent_area_bcount=1 (32768-bit bitmap =
#                128 MiB coverage), root_ino=1. sig[3400] = zero (dev-key
#                bypass, per #929 M5 acceptance criterion).
#   LBAs 1..8    inode table (256 inodes, 128 B each). Slot 0 = zero
#                (invalid-inode sentinel per PDXL-D4 / tmpfs discipline).
#                Slot 1 = root directory (mode = (0x2 << 12) | perms,
#                link_count = 2, size = 0, extents = 0). Slots 2..255 zero.
#   LBA 9        extent bitmap (4 KiB = 32768 bits). Bits 0..9 = 1 (blocks
#                0..9 = superblock + 8 itable + bitmap self). All other bits 0.
#   LBAs 10..N   zero-filled data region (--size MiB - 10 * 4 KiB).
#
# Delegates precise byte emission to python3 (fixed-width struct.pack) — bash
# alone cannot reliably emit u16/u32/u64 LE at exact offsets. Python is used
# purely as a byte-builder, not as a program: all logic lives in this file.
#
# Exit 0 on success, 1 on any error.

set -euo pipefail

# -----------------------------------------------------------------------------
# CLI parsing (#923)
# -----------------------------------------------------------------------------

usage() {
  cat <<'USAGE'
mkfs-pdxfs-lite — create a PdxFS-lite v0 image.

Usage:
  tools/mkfs-pdxfs-lite.sh --output <file> [options]

Required:
  --output <file>       Destination image path.

Options:
  --size <mb>           Image size in MiB. Default: 128.
                        Must be >= 1 (10 blocks reserved for FS metadata).
  --uuid <hex>          32-char hex UUID (no dashes). Default: random via
                        /dev/urandom, stamped v4 per RFC 4122.
  --root-mode <octal>   POSIX permission bits for root dir (top nibble is
                        forced to 0x2 = directory). Default: 0755.
  --dev-key-only        Leave sig[3400] all-zero (kernel dev-mode bypass at
                        #929 M5 accepts this). Default: on. Present as a flag
                        for explicit-intent clarity; there is no non-dev-key
                        path in R25 (ML-DSA-65 lands at R32).
  -h, --help            Print this help and exit.

Exit status: 0 on success, 1 on any error.
USAGE
}

# Defaults.
SIZE_MB=128
OUT_PATH=""
UUID_HEX=""
ROOT_MODE_OCTAL="0755"
DEV_KEY_ONLY=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --size)
      SIZE_MB="${2:?--size needs a value}"; shift 2 ;;
    --output)
      OUT_PATH="${2:?--output needs a value}"; shift 2 ;;
    --uuid)
      UUID_HEX="${2:?--uuid needs a value}"; shift 2 ;;
    --root-mode)
      ROOT_MODE_OCTAL="${2:?--root-mode needs a value}"; shift 2 ;;
    --dev-key-only)
      DEV_KEY_ONLY=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "mkfs-pdxfs-lite: unknown argument: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

if [[ -z "$OUT_PATH" ]]; then
  echo "mkfs-pdxfs-lite: --output is required" >&2
  exit 1
fi

if ! [[ "$SIZE_MB" =~ ^[0-9]+$ ]] || (( SIZE_MB < 1 )); then
  echo "mkfs-pdxfs-lite: --size must be a positive integer (MiB)" >&2
  exit 1
fi

# Validate/generate UUID.
if [[ -z "$UUID_HEX" ]]; then
  # 16 bytes from urandom, hex-encoded.
  UUID_HEX="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi
UUID_HEX="${UUID_HEX//-/}"
if ! [[ "$UUID_HEX" =~ ^[0-9a-fA-F]{32}$ ]]; then
  echo "mkfs-pdxfs-lite: --uuid must be 32 hex chars (dashes optional)" >&2
  exit 1
fi

# Validate root mode (octal, <= 0o7777).
if ! [[ "$ROOT_MODE_OCTAL" =~ ^0?[0-7]{1,4}$ ]]; then
  echo "mkfs-pdxfs-lite: --root-mode must be octal (e.g., 0755)" >&2
  exit 1
fi

# Ensure output directory exists.
OUT_DIR="$(dirname -- "$OUT_PATH")"
if [[ ! -d "$OUT_DIR" ]]; then
  echo "mkfs-pdxfs-lite: output directory does not exist: $OUT_DIR" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Emit the image via python3. Python is a byte-builder here — all field values
# are passed in as env vars from bash, so the layout constants stay visible in
# one place per language.
# -----------------------------------------------------------------------------

export SIZE_MB OUT_PATH UUID_HEX ROOT_MODE_OCTAL DEV_KEY_ONLY

python3 - <<'PY'
import os, struct, sys

# --- Layout constants (must match design/filesystem/pdxfs-lite-format.md
#     and src/kernel/core/fs/pdxfs_lite/{superblock,inode}.pdx). --------------

BLOCK_SIZE            = 4096
PDXFS_SB_MAGIC        = 0x4C584450         # "PDXL" little-endian
PDXFS_SB_VERSION      = 1

# Superblock field offsets.
SB_MAGIC_OFF          = 0
SB_VERSION_OFF        = 4
SB_UUID_OFF           = 8
SB_BLOCK_SIZE_OFF     = 24
SB_ITABLE_LBA_OFF     = 32
SB_ITABLE_BCOUNT_OFF  = 40
SB_EA_LBA_OFF         = 48
SB_EA_BCOUNT_OFF      = 56
SB_ROOT_INO_OFF       = 64
SB_SIG_OFF            = 696
SB_SIG_LEN            = 3400
SB_SIGNED_LEN         = 696                # sig covers bytes [0, 696)

# Layout LBAs.
ITABLE_LBA            = 1
ITABLE_BCOUNT         = 8                  # 8 * 32 = 256 inodes
EA_LBA                = 9
EA_BCOUNT             = 1                  # 32768 bits = 128 MiB coverage
ROOT_INO              = 1

# Inode field offsets (128-byte inode).
IN_SIZE               = 128
IN_MODE_OFF           = 0                  # u16
IN_UID_OFF            = 2                  # u16
IN_GID_OFF            = 4                  # u16
IN_PAD0_OFF           = 6                  # u16
IN_SIZE_OFF           = 8                  # u64 (byte-size)
IN_ATIME_OFF          = 16
IN_MTIME_OFF          = 24
IN_CTIME_OFF          = 32
IN_EXTENTS_OFF        = 40                 # 8 * 8 B
IN_INDIRECT_OFF       = 104                # u64
IN_LINK_COUNT_OFF     = 112                # u16
IN_CHECKSUM_OFF       = 124                # u32
IN_CHECKSUM_COVER     = 124                # bytes [0, 124) hashed

# Checksum constants (must match inode.pdx PDXL_HASH_INIT/PDXL_HASH_MIX).
PDXL_HASH_INIT        = 0xCBF29CE484222325
PDXL_HASH_MIX         = 0x9E3779B97F4A7C15
U64_MASK              = 0xFFFFFFFFFFFFFFFF
U32_MASK              = 0xFFFFFFFF

# Mode encoding (from design §2.2): top nibble = type, bottom 12 = perms.
DIR_TYPE_NIBBLE       = 0x2                # directory

# --- Read inputs from env. --------------------------------------------------

size_mb        = int(os.environ["SIZE_MB"])
out_path       = os.environ["OUT_PATH"]
uuid_hex       = os.environ["UUID_HEX"]
root_mode_oct  = int(os.environ["ROOT_MODE_OCTAL"], 8)
dev_key_only   = int(os.environ["DEV_KEY_ONLY"]) != 0

image_bytes    = size_mb * 1024 * 1024
if image_bytes < 10 * BLOCK_SIZE:
    sys.stderr.write(
        f"mkfs-pdxfs-lite: --size {size_mb} MiB too small "
        f"(need >= {10 * BLOCK_SIZE // (1024 * 1024)} MiB for FS metadata)\n"
    )
    sys.exit(1)

# --- Build UUID (RFC 4122 v4 stamp on byte 6 + variant on byte 8). ----------

uuid_bytes = bytearray(bytes.fromhex(uuid_hex))
if len(uuid_bytes) != 16:
    sys.stderr.write("mkfs-pdxfs-lite: internal UUID length error\n")
    sys.exit(1)
uuid_bytes[6] = 0x40 | (uuid_bytes[6] & 0x0F)     # version 4
uuid_bytes[8] = 0x80 | (uuid_bytes[8] & 0x3F)     # RFC 4122 variant

# --- Build superblock (4 KiB). ---------------------------------------------

sb = bytearray(BLOCK_SIZE)
struct.pack_into("<I", sb, SB_MAGIC_OFF, PDXFS_SB_MAGIC)
struct.pack_into("<I", sb, SB_VERSION_OFF, PDXFS_SB_VERSION)
sb[SB_UUID_OFF:SB_UUID_OFF + 16] = uuid_bytes
struct.pack_into("<I", sb, SB_BLOCK_SIZE_OFF, BLOCK_SIZE)
# _pad0 (u32 @28) stays zero.
struct.pack_into("<Q", sb, SB_ITABLE_LBA_OFF,    ITABLE_LBA)
struct.pack_into("<Q", sb, SB_ITABLE_BCOUNT_OFF, ITABLE_BCOUNT)
struct.pack_into("<Q", sb, SB_EA_LBA_OFF,        EA_LBA)
struct.pack_into("<Q", sb, SB_EA_BCOUNT_OFF,     EA_BCOUNT)
struct.pack_into("<Q", sb, SB_ROOT_INO_OFF,      ROOT_INO)
# _reserved [72, 696) stays zero.
# sig [696, 4096) — dev-key stub: leave all-zero. The kernel's #929 M5 shim
# accepts sig[3400] == 0 under Features.PDXFS_DEV_KEY_ONLY (see M5 acceptance
# criterion tracked in the M3 close message).
if not dev_key_only:
    # No real-signing path lands until R32. Refuse silently rather than emit
    # a plausible-looking image that no reader will accept.
    sys.stderr.write(
        "mkfs-pdxfs-lite: real ML-DSA-65 signing not implemented (R32); "
        "re-run with --dev-key-only\n"
    )
    sys.exit(1)

# --- Build the root inode (128 B) with the M2 checksum algorithm. -----------
#
# Mirrors inode_checksum in src/kernel/core/fs/pdxfs_lite/inode.pdx (L174):
#   acc = PDXL_HASH_INIT
#   for i in 0..31:
#     word = *(u32*)(inode + i*4)             # LE u32
#     acc ^= word
#     acc = (acc << 5) | (acc >> 59)          # rot-left-5
#     acc += PDXL_HASH_MIX
#   return acc & 0xFFFFFFFF
#
# This runs OVER 124 bytes = 31 u32 words. Bytes [124, 128) are the checksum
# itself and are excluded from the cover.

def pdxl_inode_checksum(inode: bytes) -> int:
    assert len(inode) >= IN_CHECKSUM_COVER
    acc = PDXL_HASH_INIT
    for i in range(31):
        (word,) = struct.unpack_from("<I", inode, i * 4)
        acc = (acc ^ word) & U64_MASK
        acc = (((acc << 5) & U64_MASK) | (acc >> 59)) & U64_MASK
        acc = (acc + PDXL_HASH_MIX) & U64_MASK
    return acc & U32_MASK

itable = bytearray(ITABLE_BCOUNT * BLOCK_SIZE)          # 8 blocks = 256 inodes
# Slot 0 stays zero — invalid-inode sentinel per PDXL-D4.
# Slot 1 = root directory (#921).
root = bytearray(IN_SIZE)
root_mode = ((DIR_TYPE_NIBBLE & 0xF) << 12) | (root_mode_oct & 0x0FFF)
struct.pack_into("<H", root, IN_MODE_OFF,       root_mode)
struct.pack_into("<H", root, IN_UID_OFF,        0)
struct.pack_into("<H", root, IN_GID_OFF,        0)
struct.pack_into("<Q", root, IN_SIZE_OFF,       0)          # empty dir at MVP
struct.pack_into("<Q", root, IN_ATIME_OFF,      0)
struct.pack_into("<Q", root, IN_MTIME_OFF,      0)
struct.pack_into("<Q", root, IN_CTIME_OFF,      0)
# extent[8] @40..104 all zero (empty dir has no data blocks yet — CREATE at
# R25.M6 will allocate one via the extent bitmap).
struct.pack_into("<Q", root, IN_INDIRECT_OFF,   0)
struct.pack_into("<H", root, IN_LINK_COUNT_OFF, 2)          # "." + parent
# _pad1, _reserved all zero.
struct.pack_into("<I", root, IN_CHECKSUM_OFF,
                 pdxl_inode_checksum(bytes(root)))

# Place root at inode-slot 1 (offset 128 within the first itable LBA).
itable[IN_SIZE:2 * IN_SIZE] = root

# --- Build the extent bitmap (1 block = 4 KiB = 32768 bits). ---------------
#
# Bits 0..9 (blocks 0..9) marked allocated: LBA 0 = superblock, LBAs 1..8 =
# inode table, LBA 9 = bitmap itself. Bit ordering matches the packed-bitmap
# convention (bit i lives at byte i/8, mask 1 << (i & 7)).

bitmap = bytearray(EA_BCOUNT * BLOCK_SIZE)
for bit in range(0, 10):
    bitmap[bit // 8] |= 1 << (bit & 7)
# Sanity: byte 0 should be 0xFF, byte 1 should be 0x03.
assert bitmap[0] == 0xFF and bitmap[1] == 0x03

# --- Write the image (single pass; sparse-friendly via a final truncate). --

with open(out_path, "wb") as f:
    f.write(sb)          # LBA 0
    f.write(itable)      # LBAs 1..8
    f.write(bitmap)      # LBA 9
    # Trailing data region: zero-filled to reach image_bytes.
    written = BLOCK_SIZE + len(itable) + len(bitmap)
    if written > image_bytes:
        sys.stderr.write(
            "mkfs-pdxfs-lite: internal error — metadata exceeds image size\n"
        )
        sys.exit(1)
    # Truncate up to full size — creates a sparse tail on most filesystems.
    f.truncate(image_bytes)

sys.stderr.write(
    f"mkfs-pdxfs-lite: wrote {out_path} "
    f"({size_mb} MiB, uuid={uuid_hex[:8]}-{uuid_hex[8:12]}-{uuid_hex[12:16]}-"
    f"{uuid_hex[16:20]}-{uuid_hex[20:]}, root_mode=0o{root_mode_oct:04o}, "
    f"dev-key-only)\n"
)
PY

exit 0
