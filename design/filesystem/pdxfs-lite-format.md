# PdxFS-lite v0 — On-disk Format

**Status:** Draft v0.1
**Date:** 2026-08-11
**Round:** R25 (PdxFS-lite persistent FS MVP)
**Milestone:** R25.M1 — On-disk format + superblock
**Issues:** #911 (this doc), #912 (superblock struct), #913 (read+validate), #914 (UUID handling)

**Successor:** PdxFS v1 (R40, CoW-PQ) — one-way migration tool documented in §7.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| PDXL-D1 | Fixed 4096-byte block size | Matches NVMe LBA formatting used in R24 fixtures; matches ML-DSA-65 sig footprint (3309 B) with room in the block. |
| PDXL-D2 | Extent-based (no CoW at M1) | Cheapest allocation; keeps R25 to ~30 issues. CoW-PQ deferred to R40. |
| PDXL-D3 | Signature scope: **superblock only** at R25 | Per-extent signing adds ML-DSA cost to every write; deferred to R40 (see §5.4). |
| PDXL-D4 | Fixed 128-byte inodes | 32 inodes per 4 KiB block, uniform stride, no packed-struct decode. |
| PDXL-D5 | Fixed 256-byte dentries | Aligns to L1 cache line; 240-byte name = long enough for the MVP shell. |
| PDXL-D6 | 8 inline extents per inode + 1 indirect ptr | Covers the MVP shell's small files without indirect fetch; overflow chains via `indirect_lba`. |
| PDXL-D7 | Superblock UUID assigned at mkfs, verified at mount | Fingerprint for logs + panic screens; prevents cross-image mount confusion. |
| PDXL-D8 | Little-endian everywhere | Matches x86_64 native, matches every other on-disk struct in the repo (tmpfs inode pool, NVMe SQE/CQE). |

---

## 1. Superblock (block 0 — 4096 bytes)

The superblock lives at LBA 0 (first 4 KiB). Signed as a single unit by an ML-DSA-65 signature (R32 crypto or dev-mode stub via #929 at M5).

### 1.1 Byte layout

| Offset | Size | Field                | Type          | Notes                                           |
|-------:|-----:|----------------------|---------------|-------------------------------------------------|
| 0      | 4    | `magic`              | u32 LE        | `0x4C584450` = `"PDXL"` (ASCII, little-endian)  |
| 4      | 4    | `version`            | u32 LE        | `1` at R25.M1                                   |
| 8      | 16   | `uuid`               | u8[16]        | RFC 4122 v4 (per §4)                            |
| 24     | 4    | `block_size`         | u32 LE        | `4096`                                          |
| 28     | 4    | `_pad0`              | u32           | zero at mkfs                                    |
| 32     | 8    | `itable_lba`         | u64 LE        | LBA of first inode-table block                  |
| 40     | 8    | `itable_bcount`      | u64 LE        | Inode-table span in 4 KiB blocks                |
| 48     | 8    | `extent_area_lba`    | u64 LE        | LBA of extent-bitmap area                       |
| 56     | 8    | `extent_area_bcount` | u64 LE        | Extent bitmap span in 4 KiB blocks              |
| 64     | 8    | `root_ino`           | u64 LE        | Root inode-table index (v0: always 1)           |
| 72     | 624  | `_reserved`          | u8[624]       | Zeroed at mkfs; reserved for future fields.     |
| 696    | 3400 | `sig`                | u8[3400]      | ML-DSA-65 signature of bytes `[0, 696)` (§5)    |
| **Total** | **4096** | | | Fills one 4 KiB block exactly.               |

### 1.2 Fields — semantics

- **`magic`** — Distinguishes a PdxFS-lite superblock from arbitrary block content. Verified byte-for-byte at mount.
- **`version`** — `1` at R25. A superblock with a different version is rejected at mount with `EFTYPE` (mismatch is never a silent upgrade — the R40 PdxFS v1 migration tool must rewrite version+magic explicitly).
- **`uuid`** — 128-bit filesystem identifier, generated at mkfs. Verified at mount (see §4).
- **`block_size`** — Fixed `4096` at R25. Rejected at mount if different — the R25 IO path assumes 4 KiB LBAs (matches NVMe fixture format).
- **`itable_lba` / `itable_bcount`** — Location + size of the inode-table region. `itable_bcount * 32` = maximum inode count.
- **`extent_area_lba` / `extent_area_bcount`** — Location + size of the extent-allocation bitmap. Each bit represents one 4 KiB data block.
- **`root_ino`** — Root directory's inode-table index. Fixed at `1` in v0 (index 0 is the invalid-inode sentinel, matching tmpfs discipline).
- **`_reserved`** — Reserved for future fields (mount-flags, generation counter, snapshot cursor for R40 migration). Zero at mkfs.
- **`sig`** — ML-DSA-65 signature covering bytes `[0, 696)` (all fixed fields, excluding `sig` itself). ML-DSA-65 signatures are 3309 B; the extra 91 B of slack tolerates a future format extension (e.g., signed-and-witnessed sig envelope) without a version bump.

### 1.3 Signature scope

The signature covers exactly the fixed-field prefix `[0, 696)`. Rationale:

- **Excludes `sig` itself.** Trivial (self-signing is undefined).
- **Excludes `_reserved`.** Future-field additions must extend the signed region explicitly by bumping `version`.
- **Covers all mount-critical fields.** An attacker who tampers with `itable_lba` to redirect metadata reads is caught at mount.

Not covered at R25 (per PDXL-D3): inode-table bytes, extent-map bytes, data-block bytes. Per-extent signing lands at R40 (PdxFS v1).

---

## 2. Inode table

The inode table is a contiguous run of 4 KiB blocks starting at `itable_lba`. Each inode is 128 B (32 inodes per block).

### 2.1 Byte layout — `struct pdxfs_inode` (128 B)

| Offset | Size | Field         | Type    | Notes                                       |
|-------:|-----:|---------------|---------|---------------------------------------------|
| 0      | 2    | `mode`        | u16 LE  | POSIX-ish type + perms (see §2.2)           |
| 2      | 2    | `uid`         | u16 LE  | Owner UID (v0: always 0)                    |
| 4      | 2    | `gid`         | u16 LE  | Group GID (v0: always 0)                    |
| 6      | 2    | `_pad0`       | u16     | Zero                                        |
| 8      | 8    | `size`        | u64 LE  | File size in bytes                          |
| 16     | 8    | `atime`       | u64 LE  | Access time (ns since epoch — TSC or CLOCK_MONOTONIC in R26+) |
| 24     | 8    | `mtime`       | u64 LE  | Modify time                                 |
| 32     | 8    | `ctime`       | u64 LE  | Change (status) time                        |
| 40     | 64   | `extent[8]`   | 8 × 8-B | Inline extents (see §2.3)                   |
| 104    | 8    | `indirect_lba`| u64 LE  | LBA of an indirect-extent block or 0        |
| 112    | 2    | `link_count`  | u16 LE  | Hard-link count                             |
| 114    | 10   | `_pad1`       | u8[10]  | Zero                                        |
| 124    | 4    | `checksum`    | u32 LE  | CRC32C of bytes `[0, 124)` (verified at inode load) |
| **Total** | **128** | | | 32 inodes per 4 KiB block.                |

### 2.2 `mode` field encoding

Top 4 bits = file type; bottom 12 bits = POSIX-style permissions.

| Type nibble | Meaning     |
|:-----------:|-------------|
| `0x1`       | regular     |
| `0x2`       | directory   |
| `0x4`       | symlink (deferred to R25.M4+) |
| `0xF`       | unused-slot sentinel |

Slot 0 is reserved (invalid-inode sentinel — matches tmpfs discipline). Slot 1 is the root directory. Slots 2..N are dynamically allocated by mkfs and by runtime create.

### 2.3 Extents — inline `extent[8]`

Each inline extent is 8 bytes:

| Offset | Size | Field       | Type   | Notes                       |
|-------:|-----:|-------------|--------|-----------------------------|
| 0      | 8    | `start_lba` | u64 LE | LBA of first block; `0` = unused |

Extent length is not stored inline at R25.M1 — every inline extent is exactly **one 4 KiB block**. This bounds a single inode's inline capacity to `8 × 4 KiB = 32 KiB`. Overflow uses `indirect_lba`.

Rationale: variable-length extents require an allocator bookkeeping pass at mkfs that R25.M1 doesn't need. Larger extents (up to `2^32 - 1` blocks) become worthwhile at R25.M4 (compress+encrypt path) and land there.

**R25.M4 upgrade path:** the 8-byte slot will re-partition as `{start_lba u32, len_blocks u32}` when the writable path grows. This is a *format* change (breaking) and lands with a superblock `version=2` bump; no in-place upgrade for images written under `version=1`.

### 2.4 Indirect block

`indirect_lba` points to one 4 KiB block containing an array of 8-byte extent descriptors with the same layout as `extent[8]`. That gives `4096 / 8 = 512` additional extents, i.e., `512 × 4 KiB = 2 MiB` per inode when the inline slots overflow.

Double-indirect blocks are **not** part of v0. A file that would exceed `32 KiB + 2 MiB ≈ 2.03 MiB` returns `ENOSPC` from write. This satisfies the MVP shell (`ls`, `cat`, small text files); larger files land with PdxFS v1 or a v0.2 extension.

---

## 3. Extent bitmap (allocation)

A packed bitmap starting at `extent_area_lba`. Bit `i` corresponds to data block `i` (measured in 4 KiB units). `1` = allocated, `0` = free.

- **Bitmap coverage:** `extent_area_bcount * 4096 * 8` bits = same number of 4 KiB data blocks.
- **Allocation policy:** first-fit at R25.M1 (single-word `bsf` scan matching the tmpfs inode-slot allocator). Buddy/bin allocator deferred to R25.M6+.
- **Concurrency:** single-writer at R25 (VFS holds FS lock across allocate + commit-to-superblock). Multi-writer scans + `lock_or_atomic` lands with R25.M6 + R26.

The bitmap itself is NOT signed at R25. Corruption is caught indirectly (an inode's extent lands on a block that a scan reports as free after fsck), never by cryptographic verification of the bitmap.

---

## 4. UUID handling (#914)

### 4.1 Generation at mkfs

`sb_generate_uuid(out: *u8[16])` produces an RFC 4122 v4 UUID:

- Bytes 0..8: 64-bit TSC sample (little-endian).
- Bytes 8..16: second TSC sample XORed with a caller-supplied seed (currently constant 0xA5A5... — deferred to a real CSPRNG via #929 M5+).
- Byte 6: overwrite with `0x40 | (byte6 & 0x0F)` — version field = 4.
- Byte 8: overwrite with `0x80 | (byte8 & 0x3F)` — RFC 4122 variant.

RDRAND is not used at R25.M1 (no encoder yet; adds a paideia-as gap). The TSC-based path is deterministic-in-principle but non-repeating in practice — mkfs is a one-time per-image operation, so a lower-entropy source is acceptable at MVP. #929 M5 upgrades to a real CSPRNG.

### 4.2 Verification at mount

`sb_uuid_match(sb: *pdxfs_sb, expected_uuid: *u8[16]) -> bool` — bytewise compare of the two 16-byte UUIDs (two u64 compares). Returns `1` on match, `0` on mismatch.

Called at mount time when the caller provides an expected UUID (e.g., `mount -o uuid=<X>`). If no expected UUID is given, the superblock's UUID is simply logged in the mount fingerprint (`PDXL_MOUNT uuid=<X>` klog line).

---

## 5. Mount flow (R25.M1 subset)

```
pdxfs_lite_mount(blkdev, expected_uuid?)
  ├── pdxfs_lite_read_superblock(blkdev, &sb)     # #913 — this M1
  │     └── nvme_read_blocking(nsid, 0, 8, buf_pa)
  │     └── verify magic == "PDXL"
  │     └── verify version == 1
  │     └── verify block_size == 4096
  ├── (R25.M5 #929) verify_ml_dsa_signature(&sb.sig, &sb[0..696])   # DEFERRED
  ├── if expected_uuid: sb_uuid_match(&sb, expected_uuid)
  ├── klog("PDXL_MOUNT uuid=... itable=... root_ino=1")
  └── register with VFS as backend_id = PDXFS_LITE
```

At R25.M1 the flow lands only through the third step (`sb_validate` returning success). VFS wire-up + signature verification land at R25.M2 and R25.M5 respectively.

---

## 6. Error handling

| Error       | Trigger                                       |
|-------------|-----------------------------------------------|
| `EFTYPE`    | `magic != "PDXL"` OR `version != 1` OR `block_size != 4096` |
| `EIO`       | NVMe read of LBA 0 returns non-zero status    |
| `EINVAL`    | `itable_lba == 0` OR `extent_area_lba == 0` OR `root_ino == 0` |
| `ESIGFAIL`  | (R25.M5+) ML-DSA signature verification fails |
| `EUUIDMISMATCH` | Expected UUID given, doesn't match sb.uuid |

Numeric encodings match the R25.M2 VFS-error return convention (u16 in `[0x0001, 0xFFFF)` with `0` = success).

---

## 7. Migration path to PdxFS v1 (R40)

PdxFS-lite is explicitly a one-way stepping stone. A `pdxfs-lite2v1` host-side tool at R40 will:

1. Mount the v0 image read-only.
2. Walk every inode, extract file contents.
3. Rewrite into a fresh PdxFS v1 image (CoW-PQ per `design/filesystem/cow-design.md`).
4. Rewrite the superblock at offset 0 with the v1 magic (`"PDX1"`), leaving v0 blocks unreferenced.

No in-place upgrade path. The v0 format is frozen at R25 close; version-bump inside v0 is an operational escape hatch, not a normal case.

---

## 8. Test surfaces (R25.M1)

- **Symbol existence:** `sb_validate`, `pdxfs_lite_read_superblock`, `sb_generate_uuid`, `sb_uuid_match` — all `pub` and reachable in `build/kernel.elf`.
- **Layout constants:** `PDXFS_SB_MAGIC`, `PDXFS_SB_VERSION`, `PDXFS_SB_SIZE`, `PDXFS_SB_SIG_OFFSET`, `PDXFS_SB_SIG_LEN`, `PDXFS_SB_UUID_OFFSET`.
- **No boot fingerprint yet.** Mount + validation runs against a fixture at R25.M2 (`boot_r25_pdxfs_mount` smoke).

Fixture generation (for R25.M2): a host-side `mkfs.pdxfs-lite` binary that materialises a valid v0 image against a QEMU NVMe backing file. Lands with #916 (R25.M2).

---

## 9. Cross-references

- `design/roadmap/r18-plus-bare-metal.md` §R25 — round-level scope.
- `design/filesystem/cow-design.md` — R40 successor format overview.
- `design/filesystem/phase1-bootfs.md` — pre-R16 stopgap (superseded by tmpfs at R16, superseded here at R25 for persistence).
- `src/kernel/core/fs/vnode.pdx` — VFS entry point that PdxFS-lite will register with at R25.M2.
- `src/kernel/core/drivers/nvme/sync.pdx` — `nvme_read_blocking` used by `pdxfs_lite_read_superblock`.
