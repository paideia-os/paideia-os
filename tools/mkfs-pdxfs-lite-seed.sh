#!/usr/bin/env bash
# tools/mkfs-pdxfs-lite-seed.sh — R28-M1-003 (#1000)
#
# Wraps tools/mkfs-pdxfs-lite.sh (R25.M3) with a seeding pass that populates
# the freshly-formatted image with the R28 MVP demo layout:
#
#   /                        (inode 1, root, allocated by mkfs)
#   /etc                     (inode 2, dir)
#   /etc/hello               (inode 3, regular, contents from --hello-text)
#   /bin                     (inode 4, dir)
#   /bin/sh                  (inode 5, regular, contents = --shell-elf)
#
# The mkfs-pdxfs-lite.sh script leaves the image in the well-known M3 state:
# empty root inode + extent bitmap covering only the FS metadata blocks
# (LBAs 0..9). The seeding pass here allocates data blocks by extending the
# bitmap in-place, writes inode-table slots 2..5, and stitches dentries into
# each directory's data block.
#
# -----------------------------------------------------------------------------
# On-disk layout after seeding
# -----------------------------------------------------------------------------
#
#   LBA 0        superblock (unchanged from mkfs)
#   LBA 1..8     inode table (slot 0 = zero; slot 1 = root; slots 2..5 seeded)
#   LBA 9        extent bitmap (bits 0..(9+data_blocks-1) set)
#   LBA 10       root dir data (dentries: "etc", "bin")
#   LBA 11       /etc dir data (dentries: ".", "..", "hello")
#   LBA 12       /etc/hello file data (--hello-text)
#   LBA 13       /bin dir data (dentries: ".", "..", "sh")
#   LBA 14..N    /bin/sh file data (--shell-elf split into 4 KiB extents)
#
# All inode checksums are re-computed to match src/kernel/core/fs/pdxfs_lite/
# inode.pdx (pdxl_inode_checksum) — same FNV-style rot-and-add mix as mkfs.
#
# The seeding python inlines that hash function; the two implementations must
# stay in lockstep. If either the inode layout or the hash constants move, the
# kernel will reject every non-root inode at load time. Guarded by the two
# checksum-cover assertions at the top of the python block.
#
# -----------------------------------------------------------------------------
# Deferred to R28.M2 or later
# -----------------------------------------------------------------------------
#
#   - /etc/motd (issue-body optional file; add here when the mount path lands).
#   - init.elf, true.elf, child_hello.elf (R14B+ shell child processes).
#   - Symlinks (PdxFS-lite v0 has no symlink support until R25.M4+).
#   - CoW / snapshot metadata (deferred to PdxFS v1 at R40).
#
# -----------------------------------------------------------------------------
# Reserved-label discipline (kernel-side mirror)
# -----------------------------------------------------------------------------
#
# The kernel readdir layout is: [inode_id u64][name_len u16][type u8][pad5][name u8[240]].
# This tool emits that layout byte-for-byte.
#
# Exit 0 on success, 1 on any error.

set -euo pipefail

usage() {
  cat <<'USAGE'
mkfs-pdxfs-lite-seed — build a PdxFS-lite v0 image and seed it with the R28 MVP layout.

Usage:
  tools/mkfs-pdxfs-lite-seed.sh --output <file> --shell-elf <file> [options]

Required:
  --output <file>       Destination image path.
  --shell-elf <file>    Path to the shell ELF (becomes /bin/sh).

Options:
  --size <mb>           Image size in MiB. Default: 128.
  --hello-text <str>    Contents of /etc/hello. Default: "hello from paideia\n".
  -h, --help            Print this help and exit.

Exit status: 0 on success, 1 on any error.
USAGE
}

REPO_ROOT="$(git rev-parse --show-toplevel)"

OUT_PATH=""
SHELL_ELF=""
SIZE_MB=128
HELLO_TEXT="hello from paideia
"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)      OUT_PATH="${2:?}"; shift 2 ;;
    --shell-elf)   SHELL_ELF="${2:?}"; shift 2 ;;
    --size)        SIZE_MB="${2:?}"; shift 2 ;;
    --hello-text)  HELLO_TEXT="${2:?}"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)  echo "mkfs-pdxfs-lite-seed: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$OUT_PATH" || -z "$SHELL_ELF" ]]; then
  echo "mkfs-pdxfs-lite-seed: --output and --shell-elf are required" >&2
  usage >&2
  exit 1
fi

if [[ ! -f "$SHELL_ELF" ]]; then
  echo "mkfs-pdxfs-lite-seed: shell ELF not found: $SHELL_ELF" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Phase 1 — mkfs (leaves image in M3-empty state).
# -----------------------------------------------------------------------------

echo "[mkfs-pdxfs-lite-seed] phase 1: mkfs (empty root)"
bash "${REPO_ROOT}/tools/mkfs-pdxfs-lite.sh" \
    --output "${OUT_PATH}" \
    --size "${SIZE_MB}" \
    --dev-key-only

# -----------------------------------------------------------------------------
# Phase 2 — seed via python (byte-builder, layout constants mirror the format
# doc and superblock/inode/readdir.pdx modules).
# -----------------------------------------------------------------------------

echo "[mkfs-pdxfs-lite-seed] phase 2: seeding /etc, /etc/hello, /bin, /bin/sh"

export OUT_PATH SHELL_ELF HELLO_TEXT

python3 - <<'PY'
import os, sys, struct

# --- Layout constants (must match design/filesystem/pdxfs-lite-format.md and
#     src/kernel/core/fs/pdxfs_lite/{superblock,inode,readdir}.pdx). ---------

BLOCK_SIZE            = 4096

# Inode table.
ITABLE_LBA            = 1
IN_SIZE               = 128
INODES_PER_BLOCK      = BLOCK_SIZE // IN_SIZE            # 32

# Inode field offsets.
IN_MODE_OFF           = 0
IN_UID_OFF            = 2
IN_GID_OFF            = 4
IN_SIZE_OFF           = 8
IN_ATIME_OFF          = 16
IN_MTIME_OFF          = 24
IN_CTIME_OFF          = 32
IN_EXTENTS_OFF        = 40
IN_INDIRECT_OFF       = 104
IN_LINK_COUNT_OFF     = 112
IN_CHECKSUM_OFF       = 124
IN_CHECKSUM_COVER     = 124
IN_EXTENT_COUNT       = 8

# Extent bitmap.
EA_LBA                = 9

# Directory-entry (readdir.pdx).
DENT_SIZE             = 256
DENT_INODE_OFF        = 0
DENT_NAMELEN_OFF      = 8
DENT_TYPE_OFF         = 10
DENT_NAME_OFF         = 16
DENT_NAME_MAX         = 240

# File-type nibbles (top 4 bits of mode).
TYPE_REGULAR          = 0x1
TYPE_DIRECTORY        = 0x2

# Dirent type bytes.
DTYPE_REG             = 1
DTYPE_DIR             = 2

# Checksum constants (must match inode.pdx PDXL_HASH_INIT/PDXL_HASH_MIX).
PDXL_HASH_INIT        = 0xCBF29CE484222325
PDXL_HASH_MIX         = 0x9E3779B97F4A7C15
U64_MASK              = 0xFFFFFFFFFFFFFFFF
U32_MASK              = 0xFFFFFFFF

def pdxl_inode_checksum(inode: bytes) -> int:
    assert len(inode) >= IN_CHECKSUM_COVER
    acc = PDXL_HASH_INIT
    for i in range(31):
        (word,) = struct.unpack_from("<I", inode, i * 4)
        acc = (acc ^ word) & U64_MASK
        acc = (((acc << 5) & U64_MASK) | (acc >> 59)) & U64_MASK
        acc = (acc + PDXL_HASH_MIX) & U64_MASK
    return acc & U32_MASK

def make_inode(*, mode, size_bytes, extent_lbas, link_count):
    ino = bytearray(IN_SIZE)
    struct.pack_into("<H", ino, IN_MODE_OFF,       mode)
    struct.pack_into("<H", ino, IN_UID_OFF,        0)
    struct.pack_into("<H", ino, IN_GID_OFF,        0)
    struct.pack_into("<Q", ino, IN_SIZE_OFF,       size_bytes)
    struct.pack_into("<Q", ino, IN_ATIME_OFF,      0)
    struct.pack_into("<Q", ino, IN_MTIME_OFF,      0)
    struct.pack_into("<Q", ino, IN_CTIME_OFF,      0)
    if len(extent_lbas) > IN_EXTENT_COUNT:
        raise ValueError(
            f"inode needs {len(extent_lbas)} extents; v0 max inline is "
            f"{IN_EXTENT_COUNT}. Indirect-block seeding is not implemented "
            f"in R28.M1 seeder — split into a smaller file or extend the "
            f"seeder before landing large files."
        )
    for i, lba in enumerate(extent_lbas):
        struct.pack_into("<Q", ino, IN_EXTENTS_OFF + i * 8, lba)
    struct.pack_into("<Q", ino, IN_INDIRECT_OFF,   0)
    struct.pack_into("<H", ino, IN_LINK_COUNT_OFF, link_count)
    struct.pack_into("<I", ino, IN_CHECKSUM_OFF,
                     pdxl_inode_checksum(bytes(ino)))
    return bytes(ino)

def make_dirent(*, inode_id, name, kind):
    if not (1 <= len(name) <= DENT_NAME_MAX):
        raise ValueError(f"dirent name length {len(name)} out of [1, {DENT_NAME_MAX}]")
    d = bytearray(DENT_SIZE)
    struct.pack_into("<Q", d, DENT_INODE_OFF,   inode_id)
    struct.pack_into("<H", d, DENT_NAMELEN_OFF, len(name))
    struct.pack_into("<B", d, DENT_TYPE_OFF,    kind)
    d[DENT_NAME_OFF:DENT_NAME_OFF + len(name)] = name.encode("ascii")
    # Remainder of name field stays zero (NUL-terminated by construction).
    return bytes(d)

def dir_block(entries):
    # entries is a list of make_dirent() outputs. One 4 KiB block == 16 slots;
    # the R28.M1 seeder emits at most one data block per directory.
    if len(entries) > BLOCK_SIZE // DENT_SIZE:
        raise ValueError(
            f"directory has {len(entries)} entries but one block holds "
            f"{BLOCK_SIZE // DENT_SIZE}. Multi-block directory seeding is "
            f"not implemented in R28.M1 — split the directory or extend "
            f"the seeder."
        )
    buf = bytearray(BLOCK_SIZE)
    for i, e in enumerate(entries):
        buf[i * DENT_SIZE:(i + 1) * DENT_SIZE] = e
    return bytes(buf)

# --- Inputs. ----------------------------------------------------------------

out_path   = os.environ["OUT_PATH"]
shell_path = os.environ["SHELL_ELF"]
hello_text = os.environ["HELLO_TEXT"].encode("utf-8")

with open(shell_path, "rb") as f:
    shell_bytes = f.read()

shell_len = len(shell_bytes)
shell_blocks = (shell_len + BLOCK_SIZE - 1) // BLOCK_SIZE
if shell_blocks > IN_EXTENT_COUNT:
    sys.stderr.write(
        f"mkfs-pdxfs-lite-seed: shell.elf is {shell_len} bytes "
        f"({shell_blocks} blocks); v0 inline-extent max is {IN_EXTENT_COUNT} "
        f"blocks = {IN_EXTENT_COUNT * BLOCK_SIZE} bytes. "
        f"Indirect-block seeding is a follow-on task; shrink shell or "
        f"extend the seeder.\n"
    )
    sys.exit(1)

# --- Allocate data-block LBAs. ---------------------------------------------

# The M3 mkfs consumes LBAs 0..9 (superblock + 8 itable blocks + bitmap).
next_lba = 10

root_dir_lba   = next_lba;               next_lba += 1
etc_dir_lba    = next_lba;               next_lba += 1
hello_lba      = next_lba;               next_lba += 1
bin_dir_lba    = next_lba;               next_lba += 1
shell_lbas     = list(range(next_lba, next_lba + shell_blocks))
next_lba      += shell_blocks

# --- Build directory data blocks. -------------------------------------------

# Root: v0 does not force "." on root (root's ".." refers to root itself per
# format §2.5.2; the readdir.pdx sentinel is inode_id==0). Emit only the
# user-visible entries.
root_block = dir_block([
    make_dirent(inode_id=2, name="etc", kind=DTYPE_DIR),
    make_dirent(inode_id=4, name="bin", kind=DTYPE_DIR),
])
root_size = 2 * DENT_SIZE

# Non-root directories: emit "." and ".." per format §2.5.1 so readdir output
# matches POSIX-ish expectations. Path resolution (namei.pdx) does not
# require them, but readdir consumers do.
etc_block = dir_block([
    make_dirent(inode_id=2, name=".",     kind=DTYPE_DIR),
    make_dirent(inode_id=1, name="..",    kind=DTYPE_DIR),
    make_dirent(inode_id=3, name="hello", kind=DTYPE_REG),
])
etc_size = 3 * DENT_SIZE

bin_block = dir_block([
    make_dirent(inode_id=4, name=".",     kind=DTYPE_DIR),
    make_dirent(inode_id=1, name="..",    kind=DTYPE_DIR),
    make_dirent(inode_id=5, name="sh",    kind=DTYPE_REG),
])
bin_size = 3 * DENT_SIZE

# --- Build inodes. ----------------------------------------------------------

DIR_MODE = ((TYPE_DIRECTORY & 0xF) << 12) | 0o755
REG_MODE = ((TYPE_REGULAR   & 0xF) << 12) | 0o644
EXE_MODE = ((TYPE_REGULAR   & 0xF) << 12) | 0o755

# Root: was mkfs'd empty; overwrite slot 1 with the populated version.
root_inode  = make_inode(mode=DIR_MODE, size_bytes=root_size,
                         extent_lbas=[root_dir_lba], link_count=2)
etc_inode   = make_inode(mode=DIR_MODE, size_bytes=etc_size,
                         extent_lbas=[etc_dir_lba], link_count=2)
hello_inode = make_inode(mode=REG_MODE, size_bytes=len(hello_text),
                         extent_lbas=[hello_lba], link_count=1)
bin_inode   = make_inode(mode=DIR_MODE, size_bytes=bin_size,
                         extent_lbas=[bin_dir_lba], link_count=2)
shell_inode = make_inode(mode=EXE_MODE, size_bytes=shell_len,
                         extent_lbas=shell_lbas, link_count=1)

# --- Rewrite bitmap: mark data blocks allocated. ---------------------------

# Load bitmap block (LBA 9).
with open(out_path, "r+b") as f:
    f.seek(EA_LBA * BLOCK_SIZE)
    bitmap = bytearray(f.read(BLOCK_SIZE))
    for lba in ([root_dir_lba, etc_dir_lba, hello_lba, bin_dir_lba] + shell_lbas):
        bitmap[lba // 8] |= 1 << (lba & 7)

    # --- Rewrite inode table blocks (only touch block 0 of the itable —
    #     inodes 1..5 all live in the first itable LBA since INODES_PER_BLOCK
    #     is 32). Read-modify-write for safety.
    f.seek(ITABLE_LBA * BLOCK_SIZE)
    itblock0 = bytearray(f.read(BLOCK_SIZE))
    for slot, inode_bytes in ((1, root_inode),
                              (2, etc_inode),
                              (3, hello_inode),
                              (4, bin_inode),
                              (5, shell_inode)):
        off = slot * IN_SIZE
        itblock0[off:off + IN_SIZE] = inode_bytes

    # Rewrite the modified metadata blocks.
    f.seek(ITABLE_LBA * BLOCK_SIZE); f.write(itblock0)
    f.seek(EA_LBA * BLOCK_SIZE);     f.write(bitmap)

    # Data blocks (variable-length payloads padded to BLOCK_SIZE by dir_block).
    f.seek(root_dir_lba * BLOCK_SIZE); f.write(root_block)
    f.seek(etc_dir_lba  * BLOCK_SIZE); f.write(etc_block)

    # /etc/hello: zero-pad the block explicitly (image already has zeros in
    # the untouched tail, but be defensive against reallocated LBAs).
    hello_block = bytearray(BLOCK_SIZE)
    hello_block[:len(hello_text)] = hello_text
    f.seek(hello_lba * BLOCK_SIZE); f.write(hello_block)

    f.seek(bin_dir_lba * BLOCK_SIZE); f.write(bin_block)

    # /bin/sh: split shell_bytes into 4 KiB extents; pad the tail block.
    for i, lba in enumerate(shell_lbas):
        start = i * BLOCK_SIZE
        chunk = shell_bytes[start:start + BLOCK_SIZE]
        buf = bytearray(BLOCK_SIZE)
        buf[:len(chunk)] = chunk
        f.seek(lba * BLOCK_SIZE); f.write(buf)

sys.stderr.write(
    f"mkfs-pdxfs-lite-seed: seeded {out_path} — "
    f"/etc/hello ({len(hello_text)} B), "
    f"/bin/sh ({shell_len} B in {shell_blocks} extents at LBAs {shell_lbas[0]}..{shell_lbas[-1]})\n"
)
PY

echo "[mkfs-pdxfs-lite-seed] OK: ${OUT_PATH}"
exit 0
