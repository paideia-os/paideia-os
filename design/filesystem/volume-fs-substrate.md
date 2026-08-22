# R52 — PdxFS-on-Block: Volume Filesystem Substrate (softarch half)

**Status:** proposal (2026-08-21, softarch of a two-part R51/R52 planning wave)
**Companion (osarch):** `design/kernel/nvme-ahci-block-substrate.md` — the HW half (NVMe queue-pair driver, AHCI port driver, `KIND_BLOCK_DEVICE` cap kind, DMA-domain consent, IOMMU/IOVA wiring). This document depends on the `KIND_BLOCK_DEVICE` cap ops set (`BD_OP_READ_LBA`, `BD_OP_WRITE_LBA`, `BD_OP_FLUSH`, `BD_OP_TRIM`, `BD_OP_QUERY`) and does not redesign that KIND.
**Depends on:** paideia-os kernel through R48b substrate-prep (`KIND_PDXFS_FILE = 0x195`, `KIND_PDXFS_TXN = 0x196`, `KIND_TTY = 0x197`) and R42 PdxFS scaffold family (`core/fs/pdxfs/{wal,journal_fence,journal_replay,journal_csum,cow_read,cow_write,cow_gc,refcount,nvme_write,durability,snap_*,upgrade_*,lite_reader}.pdx`); the R16.M1 mount table (`core/fs/mount.pdx`); the R17 backend registry (`core/fs/backend_registry.pdx`); paideia-as ≥ v0.33-crypto-kdf (ML-DSA-65 verify) for signed-inode tails.
**Also depends on (companion):** `KIND_BLOCK_DEVICE` from osarch's R51 (ordinal owned by osarch; softarch does not allocate it here).
**Sibling documents to keep in step:**
- `design/filesystem/cow-design.md` — the R40+ CoW-PQ architecture this document is the block-backed realisation of.
- `design/filesystem/pdxfs-lite-format.md` — the R25 on-disk template (superblock, extent bitmap, 128-B inode, 256-B dentry) reused with the CoW walker's block layout replacing the extent-file model.
- `design/user/pdxfs-kinds.md` — the R48b coverage audit whose §2 will gain the KINDs listed in §6 of this document.
- `design/tooling/r49-r50-plan.md` — the R49/R50 tools this substrate unblocks (`pkg install` becomes a real journaled multi-write; `cp`, `mv`, `rm`, `mkdir` become real mutations rather than STUB counters).
- `design/architecture/next-wave-derived-kinds.md` — the master derived-kind catalogue.

---

## 0. Reading order

- §1 scope + goal — what "first real volume filesystem" means; what is deliberately not being brought up (compat FSes, mmap, symlinks, ACLs).
- §2 on-disk layout — PdxFS-on-block v1 superblock, allocator, inode table, journal region, signed-inode tail, endianness/alignment.
- §3 volume manager — probe, mount table extension, root selection, multi-volume.
- §4 journal + TXN semantics — WAL shape, barrier discipline, recovery on mount, wiring `KIND_PDXFS_TXN` mutating ops to the journal.
- §5 block cache — sizing, replacement policy, read-ahead, write-back gates.
- §6 KIND integration — how `KIND_PDXFS_FILE` gains a backing-store field, how `KIND_PDXFS_TXN` STUBs become real, and the four new KINDs (`KIND_BLOCK_CACHE`, `KIND_VOLUME`, `KIND_INODE_HANDLE`, `KIND_SIG_KEY`) softarch allocates in the 0x1A0+ band.
- §7 milestone breakdown — R52.M1..M8, 4-6 issue titles each.
- §8 cross-repo dependencies — paideia-as encoder gaps (ML-DSA-65 sign, BLAKE3-XOF, atomic sector primitives).
- §9 out-of-scope — mmap, symlinks/hardlinks, xattrs, ACLs, quotas, snapshots-persistence.

---

## 1. Scope and goal

### 1.1 What "first real volume filesystem" means

The three PdxFS backends live today at `src/kernel/core/fs/`: `tmpfs/` (R16, RAM-backed, cleared on reboot), `pdxfs_lite/` (R25, single-writer extent FS designed but not fully block-backed in-kernel), and `pdxfs/` (R42, CoW+WAL+snapshot scaffolds whose "device" is a BSS ring inside `nvme_write.pdx`). None of the three today mounts a real persistent volume: every kernel boot begins with an empty root, `pkg install` writes to tmpfs, and every mutation vanishes on shutdown.

R52 closes that gap. Its deliverable is a boot in which the kernel:

1. Probes every `KIND_BLOCK_DEVICE` the R51 driver family made available (NVMe namespace, AHCI port).
2. Reads block 0 of each device; validates the PdxFS-on-block v1 superblock magic + version + signature.
3. Registers each valid volume in the mount table under a new `MOUNT_BACKEND_PDXFS_BLOCK = 5` discriminant.
4. Selects one volume as root (from a bootloader-passed hint or a signed root-selector cap in `KIND_VOLUME`'s tail — see §3.3).
5. Replays the on-disk WAL: every committed transaction reissues, every uncommitted record discards.
6. Serves `open` / `read` / `write` / `create` / `unlink` / `rename` from the block-backed pdxfs walker; every mutation goes through the journal; every commit is durable across reboot.
7. Reboots and re-mounts the volume: every file present at last unmount is present now, byte-identical, with per-inode signature verified.

The R42 scaffolds are the substrate; R52 is the wire-through that replaces every BSS-backed ring with a `KIND_BLOCK_DEVICE`-backed extent, replaces the `wal.pdx` scaffold WAL with an on-disk WAL region, and replaces the `nvme_write.pdx` scaffold ring with real SQ submissions through the block-device cap.

### 1.2 What R52 is deliberately NOT

- **Not a Unix-compatibility layer.** R52 mounts PdxFS-on-block v1 only. Read-only ext4 support, if ever, is a much later round — and probably never (see §1.3). There is no `read-only mount type=ext4` path in the mount table extension.
- **Not `mmap`.** Cache coherence with page-mapped file contents is a hard problem for a CoW journaled FS; the R52 read/write path is copy-in-copy-out through the block cache. `mmap` is deferred to R56+ (once the block cache's page identity aligns with `KIND_PAGE` allocation).
- **Not symlinks or hardlinks.** The R48b `KIND_PDXFS_FILE` tail already carries a refcount, but the on-disk directory format at R52 gives every dentry exactly one inode reference. `KIND_PDXFS_SYMLINK` was called out as a §3.2 gap in `design/user/pdxfs-kinds.md`; that lands at a later round.
- **Not extended attributes, ACLs, or quotas.** The inode tail has fixed shape; xattr storage would need a per-inode indirect block. Deferred.
- **Not snapshot persistence.** The R42 `snap_create.pdx` / `snap_diff.pdx` / `snap_mount_ro.pdx` / `snap_prune.pdx` modules exist at the walker layer as scaffolds; making snapshot generations survive reboot needs a snapshot-region layout in the superblock. That layout is sketched in §2.1 but the walker wire-through is deferred to R53.

### 1.3 Compat FS position

The user brief asks whether R52 should bring up a compatibility FS (ext4-ro) or bring up PdxFS-on-block first.

**Recommendation: PdxFS-on-block first, ext4 never.** The PaideiaOS thesis is a clean-slate substrate. Every design document from `01-foundational-decisions.md` Q4 through `design/filesystem/cow-design.md` §0 is explicit that the FS is a new one, not a rehabilitation of a Unix-lineage layout. An ext4 reader in the kernel would be a permanent complexity tax with no forward path — the same complexity that installers and dual-boot workflows would justify on other systems has no home in a system that boots off a signed root volume it wrote itself. A userspace ext4 reader tool (as a `pkg install ext4-import`) is fine at any future round; a kernel-side compat FS is out.

### 1.4 One-paragraph mental model

Every persistent artefact in R52 is a **block** of the size the underlying `KIND_BLOCK_DEVICE` reports (fixed 4096 for the R51 NVMe/AHCI drivers). A **volume** is one `KIND_BLOCK_DEVICE` whose block 0 parses as a PdxFS-on-block v1 **superblock**. The superblock names four **regions**: the **inode table** (fixed-size inode records), the **block allocator bitmap** (one bit per data block), the **journal** (a preallocated extent holding a ring of transaction records), and the **data region** (everything else). An **inode** is a 128-byte on-disk record naming the CoW chain of blocks that carry a file's content. A **transaction** is a WAL-fenced group of block writes that either lands wholesale or does not land at all; on mount, the walker replays the WAL to reach a consistent state. A **file cap** (`KIND_PDXFS_FILE`) in memory now carries an on-disk inode reference (block + slot) instead of only the R48b in-memory row; a **transaction cap** (`KIND_PDXFS_TXN`) is the identity a WAL record links back to.

---

## 2. On-disk layout — PdxFS-on-block v1

The layout is a block-backed realisation of `design/filesystem/pdxfs-lite-format.md`'s R25 template modified for CoW walking and signed-inode-tail semantics. Every field is little-endian; every region starts on a 4096-byte boundary; every 8-byte field is 8-byte aligned.

### 2.1 Superblock (LBA 0, exactly 4096 bytes)

| Offset | Size | Field                | Type      | Notes                                                                    |
|-------:|-----:|----------------------|-----------|--------------------------------------------------------------------------|
| 0      | 4    | `magic`              | u32 LE    | `0x42584450` = `"PDXB"` (PdxFS Block-backed; distinct from `"PDXL"` at R25). |
| 4      | 4    | `version`            | u32 LE    | `1` at R52.M1.                                                          |
| 8      | 16   | `uuid`               | u8[16]    | RFC 4122 v4; assigned at mkfs.                                          |
| 24     | 4    | `block_size`         | u32 LE    | `4096`; rejected at mount if different.                                 |
| 28     | 4    | `flags`              | u32 LE    | bit0 clean-unmount; bit1 root-volume; bit2 read-only mount hint.        |
| 32     | 8    | `total_blocks`       | u64 LE    | Total 4KB blocks the volume spans (matches `BD_OP_QUERY` LBA count).    |
| 40     | 8    | `itable_lba`         | u64 LE    | First block of inode-table region.                                      |
| 48     | 8    | `itable_bcount`      | u64 LE    | Inode-table span in blocks. Max inodes = `itable_bcount * 32` (§2.3).   |
| 56     | 8    | `alloc_lba`          | u64 LE    | First block of allocator bitmap region.                                 |
| 64     | 8    | `alloc_bcount`       | u64 LE    | Allocator bitmap span in blocks.                                        |
| 72     | 8    | `journal_lba`        | u64 LE    | First block of journal region.                                          |
| 80     | 8    | `journal_bcount`     | u64 LE    | Journal span in blocks (WAL ring capacity).                             |
| 88     | 8    | `data_lba`           | u64 LE    | First block of the data region.                                         |
| 96     | 8    | `data_bcount`        | u64 LE    | Data-region span in blocks.                                             |
| 104    | 8    | `root_inode`         | u64 LE    | Root directory's inode index (v0: fixed at `1`).                        |
| 112    | 8    | `mount_gen`          | u64 LE    | Monotonically bumped on each mount; readers cache-check against this.   |
| 120    | 8    | `snap_head`          | u64 LE    | Reserved for R53 snapshot-persistence; zero at R52 mkfs.                |
| 128    | 32   | `sig_key_hash`       | u8[32]    | BLAKE3 fingerprint of the ML-DSA-65 public key that signed inodes.       |
| 160    | 536  | `_reserved`          | u8[536]   | Zeroed at mkfs; reserved for future fields (must stay zero at mount).   |
| 696    | 3400 | `sig`                | u8[3400]  | ML-DSA-65 signature covering bytes `[0, 696)`. (3309 B sig + 91 B slack.)|
| **Total** | **4096** |             |            | Fills one block exactly.                                                 |

**Discipline.**
- `magic` distinguishes a block-backed v1 volume from either the R25 lite-format (`"PDXL"`) or arbitrary block content. A `"PDXL"` block is a mount-time refusal at R52 (a user's next step is `mkfs --upgrade` — see §4.5).
- `sig_key_hash` binds the volume to a specific signing key at mkfs time. Every inode's tail signature verifies against this key; mount refuses if `sig_key_hash` does not match the key material the loader passed in `KIND_SIG_KEY` (see §6.4).
- `_reserved` MUST be zero at mount. A non-zero reserved byte indicates a from-the-future superblock; refuse rather than silently ignore.
- `sig` scope is bytes `[0, 696)`. This excludes `sig` itself and excludes `_reserved`. Adding a field means bumping `version` and re-writing `sig`.

### 2.2 Block allocator — bitmap, not extents

**Recommendation: fixed-size bitmap.** One bit per 4KB data block, packed into the allocator region. Total allocator cost = `data_bcount / 8` bytes. For a 1 TiB volume with 256M data blocks: 32 MiB of bitmap, or 8192 blocks. Loaded into cache lazily; only the bitmap blocks covering an active allocation range are resident.

Rationale (extent-based rejected):
- **CoW writes are per-block, not per-extent.** The R42 `cow_write.pdx` scaffold writes one block per allocation; there is no batching site where an extent record would be cheaper than a bit flip.
- **Free-space fragmentation is bounded by the block cache's read-ahead policy** (§5.4), not by an allocator format decision. An extent allocator would add on-disk complexity to solve a problem the read side already solves.
- **Recovery is simpler.** WAL replay of "allocated block N" is a single bit-set operation. An extent allocator's replay must reconstruct a tree.
- **The R25 lite-format used bitmap allocation for the same reasons** (`design/filesystem/pdxfs-lite-format.md` PDXL-D2). R52 keeps that choice.

The allocator maintains a per-volume in-memory hint pointing at the last-allocated block plus a small stack of recently-freed blocks (LIFO, so freshly-freed blocks are reallocated preferentially for CoW-write locality). Both hints are ephemeral; on mount, the allocator scans the bitmap once to seed the hint from the first free block.

### 2.3 Inode table — fixed slab, 128 B per inode

The inode table is `itable_bcount` blocks of 32 inodes each, packed. Inode 0 is the invalid-inode sentinel; inode 1 is the root directory (v0 discipline). At mkfs the inode-table size is chosen from the volume size using the ratio `data_bcount / 256` (one inode per 256 data blocks, giving 1 file per MiB on average) capped at `2^32` inodes.

**Per-inode layout (128 B):**

| Offset | Size | Field           | Type      | Notes                                                                       |
|-------:|-----:|-----------------|-----------|-----------------------------------------------------------------------------|
| 0      | 8    | `header`        | u64 LE    | `in_use[63:56]`, `file_type[55:48]`, `mode_bits[15:0]` (mirrors R48b tail).  |
| 8      | 8    | `inode_no`      | u64 LE    | Self-index; redundant with position but simplifies inode-cache decode.       |
| 16     | 8    | `byte_len`      | u64 LE    | Current file length ceiling.                                                |
| 24     | 8    | `created_ns`    | u64 LE    | Birth timestamp.                                                            |
| 32     | 8    | `mtime_ns`      | u64 LE    | Last modification timestamp.                                                |
| 40     | 8    | `refcount`      | u64 LE    | On-disk hardlink count (userspace-visible).                                  |
| 48     | 8    | `root_block`    | u64 LE    | Root of this inode's CoW block chain (LBA of first block-tree node).         |
| 56     | 8    | `cow_gen`       | u64 LE    | CoW generation at which `root_block` was last rewritten.                     |
| 64     | 8    | `content_hash`  | u64 LE    | BLAKE3-truncated hash of the CoW-tree root (used by `content_hash_cap`).     |
| 72     | 24   | `sig_prefix`    | u8[24]    | First 24 bytes of the ML-DSA-65 signature over bytes `[0, 72)`.              |
| 96     | 32   | `sig_hash`      | u8[32]    | BLAKE3 hash of the full 3309-byte signature; the signature lives out-of-line.|
| **Total** | **128** |             |            | 32 inodes per 4KB block.                                                     |

**Signed-inode tail — how it fits.** An ML-DSA-65 signature is 3309 B, far larger than the 128-B inode. The inode holds two references to the signature: the low-24-byte prefix (`sig_prefix`) for fast tear-detection, and the BLAKE3 hash of the full signature (`sig_hash`) for authenticated retrieval. The full signature lives in a per-inode **signature block** in the data region, allocated at inode-write time. Verification path:
1. Read the inode block; check `sig_prefix` matches the prefix of the signature block the walker fetches.
2. Read the signature block; verify `blake3(sig_bytes) == sig_hash`.
3. Verify the full signature against the inode-content hash (bytes `[0, 72)`) using the volume's `sig_key_hash` public key.

Rationale for splitting: inline signatures would blow up the inode table by 26x (128 B → 3437 B) for a field almost never on the hot path. The out-of-line block with two integrity anchors (prefix + hash) preserves tear-detection without the space penalty.

**Directory inodes.** For a directory inode, `root_block` points to the root of a CoW-tree of **dentry blocks**. A dentry block holds 16 dentries (256 B each, matches R25 PDXL-D5): `{u64 inode_no, u64 name_len, u8 name[240]}`. The 240-byte name matches the R42-PREP-008 kernel-visible entry layout at `sys_pdxfs_dir_readnext` (104-byte visible name, but the on-disk dentry has room for the longer names R49's `pkg` uses). Directories with more than 16 entries chain dentry blocks through the CoW-tree.

### 2.4 Journal region — write-ahead log ring

The journal is a preallocated block extent starting at `journal_lba` and spanning `journal_bcount` blocks (default 1024 blocks = 4 MiB). It is the on-disk realisation of `src/kernel/core/fs/pdxfs/wal.pdx`'s BSS ring.

**Journal block layout (each of the 1024 blocks):**

| Offset | Size | Field           | Type      | Notes                                                          |
|-------:|-----:|-----------------|-----------|----------------------------------------------------------------|
| 0      | 4    | `record_magic`  | u32 LE    | `0x4A424E4C` = `"JBNL"` (journal block).                       |
| 4      | 4    | `record_count`  | u32 LE    | Number of records packed into this block.                       |
| 8      | 8    | `seq`           | u64 LE    | Sequence number of the first record in this block.              |
| 16     | 8    | `prev_lba`      | u64 LE    | LBA of the previous journal block in the chain.                  |
| 24     | 8    | `checkpoint`    | u64 LE    | LBA of the oldest journal block a mount replay must still read. |
| 32     | 4056 | `records[]`    | packed     | Records, laid out sequentially (see below).                     |
| 4088   | 8    | `csum`          | u64 LE    | CRC32C of bytes `[0, 4088)` concatenated with `seq`.             |
| **Total** | **4096** |          |             |                                                                 |

**Record layout (variable-length, 8-byte aligned):**

| Offset | Size | Field           | Type      |
|-------:|-----:|-----------------|-----------|
| 0      | 8    | `record_hdr`    | u64 LE    | `op[7:0]` + `flags[15:8]` + `payload_len[47:16]` (LE).           |
| 8      | 8    | `txn_id`        | u64 LE    | `KIND_PDXFS_TXN` row's txn_id (matches the `KIND_PDXFS_TXN` tail).|
| 16     | N    | `payload`       | u8[N]     | Op-specific (see below).                                          |

**Op codes** (mirror `PXT_OP_*` at `kind_pdxfs_txn.pdx`):

- `JOP_BEGIN` (1) — payload: `{mode:u8, snap_gen:u64}`; opens a transaction on-disk.
- `JOP_BLOCK_WRITE` (2) — payload: `{lba:u64, block_data:u8[4096]}`; a CoW block write in this transaction.
- `JOP_INODE_WRITE` (3) — payload: `{inode_no:u64, inode_bytes:u8[128]}`; an inode rewrite.
- `JOP_BITMAP_SET` (4) — payload: `{bit_no:u64}`; allocator bit flip.
- `JOP_BITMAP_CLEAR` (5) — payload: `{bit_no:u64}`; allocator bit unflip.
- `JOP_DENTRY_ADD` (6) — payload: `{dir_inode:u64, name_len:u32, name[]:u8, target_inode:u64}`; directory entry add.
- `JOP_DENTRY_DEL` (7) — payload: `{dir_inode:u64, name_len:u32, name[]:u8}`; directory entry unlink.
- `JOP_COMMIT` (8) — payload: `{final_content_hash:u64}`; fence marker matching `PXT_OP_COMMIT`.
- `JOP_ABORT` (9) — payload: empty; fence marker matching `PXT_OP_ABORT`.

**Barrier discipline** (see also §4.2):
1. Every `JOP_BLOCK_WRITE` / `JOP_INODE_WRITE` / `JOP_BITMAP_*` / `JOP_DENTRY_*` record is written to the journal (through the block cache with `BD_OP_FLUSH` between the payload write and the CSUM word).
2. `JOP_COMMIT` is written only after every earlier record in the transaction has completed. `KIND_PDXFS_TXN`'s state transitions from OPEN to COMMITTED only after the JOP_COMMIT record is durable.
3. After JOP_COMMIT is durable, the walker may then write the corresponding data-region blocks (block_data, inode_bytes, bitmap words). These "in-place" writes are idempotent: replay is safe.
4. On checkpoint (§4.3), the checkpoint pointer advances past records whose in-place writes are all durable. Journal space reclaims when the checkpoint advances.

### 2.5 Data region

Everything from `data_lba` to `data_lba + data_bcount` is a raw pool of 4KB blocks. Its layout is not filesystem-visible; the allocator bitmap is authoritative. A block may be:
- A CoW-tree interior node (block pointers).
- A file-content block.
- A dentry block (directory content).
- A signature block (one per inode; §2.3).
- Free (bitmap bit == 0).

The R42 `cow_read.pdx` / `cow_write.pdx` walker's abstraction over block chains is preserved wholesale; only the "read block N" and "write block N" bottom ops change from `nvme_write.pdx`'s BSS ring to `KIND_BLOCK_DEVICE` `BD_OP_READ_LBA` / `BD_OP_WRITE_LBA` invocations mediated by the block cache (§5).

### 2.6 Endianness and alignment

- **Little-endian everywhere**, matching x86_64 native and every other on-disk struct in the repo.
- **Every 8-byte field is 8-byte aligned relative to its block.** No packed structs across block boundaries.
- **Every block starts on a 4096-byte boundary.** Whether or not the physical NVMe LBA size is 4096 (the R51 driver reports it via `BD_OP_QUERY`), the FS-visible block size is fixed at 4096; the driver's DMA path issues one, two, or eight 512-B ops per FS block as needed.
- **In-memory decode.** No in-memory struct type mirrors an on-disk block layout. Every field is fetched via a per-offset accessor with a hard-coded shift/mask, in the same discipline as `KIND_PDXFS_FILE`'s `pdxfs_file_row_*` accessors at `kind_pdxfs_file.pdx`. This avoids the C-style "packed struct" trap and keeps every fetch grep-able.

---

## 3. Volume manager

### 3.1 Discovery — probe every KIND_BLOCK_DEVICE at mount-init

At boot, after the R51 driver family has registered its devices, a new module `src/kernel/core/fs/pdxfs/probe.pdx` iterates the kernel's list of live `KIND_BLOCK_DEVICE` capabilities:

1. For each device cap, issue `BD_OP_QUERY` to learn the LBA count and physical block size.
2. Issue `BD_OP_READ_LBA(0)` to fetch block 0.
3. Check the `magic == 0x42584450` and `version == 1`.
4. Verify the superblock signature against the loader-supplied `KIND_SIG_KEY` (or refuse if no key has been loaded — see §6.4).
5. If all checks pass, allocate a `KIND_VOLUME` row (§6.1), record the device cap + parsed superblock summary, and add the volume to the volume registry.

The probe module is idempotent: probing a device twice at the same mount_gen finds the existing row rather than duplicating it. This matters because R51's `KIND_BLOCK_DEVICE` may be re-minted on driver bounce (a driver crash that respawns re-mints the device caps; the probe runs after every mint).

**Failure modes are non-fatal.** A device whose block 0 is not a PdxFS-on-block v1 superblock is skipped, not an error — the block might be another filesystem's superblock, or unformatted, or the "install medium" the user boots off. The probe emits a `dmesg` chatter line per device (`PDXFS PROBE BAD_MAGIC lba=0 dev=<cap>`) so an operator can distinguish "no PdxFS on this device" from "the device failed to read".

### 3.2 Mount table extension

`src/kernel/core/fs/mount.pdx` currently supports five backend discriminants: `NONE=0`, `TMPFS=1`, `DEVFS=2`, `PROCFS=3`, `TTY=4`. R52.M5 extends this with:

- `MOUNT_BACKEND_PDXFS_BLOCK = 5` — the block-backed PdxFS v1.

The mount-table entry layout is unchanged; the 16-bit reserved field at bits `[48:64]` per `mount.pdx` §Layout constants is populated with the `KIND_VOLUME` row index for `PDXFS_BLOCK` mounts, giving the mount table a stable pointer back to the volume registry. `backend_registry.pdx`'s `backend_ops_table` dispatch gains a `cmp rdi, 5; je bot_pdxfs_block` arm returning the address of a new `_pdxfs_block_vops` table (mirrors `_tmpfs_vops` shape).

Mount slot 0 (the ROOT slot) is reserved for the root volume (§3.3). Additional volumes take slots 1..7; the current 8-slot limit is preserved. R53 may widen the mount table if multi-namespace boots exceed 7 non-root volumes.

### 3.3 Root volume selection

At bring-up, the kernel must choose one probed volume as the root. Three inputs are consulted, in order:

1. **Bootloader hint (authoritative if present).** The R11 bootloader passes a `root_volume_uuid` field in its handoff record; if any probed volume's `uuid` matches, that volume is root. This is the primary path — a signed bootloader knows exactly which volume it validated.
2. **Superblock flag `bit1 root-volume`.** In dev/test flows where no bootloader hint is present, the probe picks the first volume whose superblock flag says "I am a root". A dev-mode mkfs script sets this flag; a signed-bootloader mkfs does not (the bootloader carries the identity).
3. **Fallback: single-device disambiguation.** If exactly one volume was probed and neither of the above yielded a choice, that volume is root. If more than one volume was probed and neither yielded a choice, boot panics with a `PDXFS ROOT AMBIGUOUS` message and lists the UUIDs.

Once root is chosen, its `KIND_VOLUME` row is installed at mount slot 0 with `MOUNT_FLAG_VALID | MOUNT_FLAG_ROOT`, and the root inode (index 1) is opened as the root directory vnode.

### 3.4 Multi-volume support

Non-root volumes are mounted lazily: they exist in the volume registry from probe time, but no mount slot is populated until a userspace `sys_mount` call (R53 syscall — deferred; R52 root-only is enough for smoke) or a boot-time auto-mount policy names them. This matches the discipline that mount is an authoritative act, not an implicit side effect of probe.

The volume registry is a 16-row table (`_pdxfs_volume_table`) at `core/fs/pdxfs/volume_registry.pdx`, each row: `{uuid[16], device_slot:u16, superblock_summary:{itable_lba, alloc_lba, journal_lba, data_lba, root_inode, mount_gen}, mount_slot:u16, refcount:u32}`. The 16-row cap matches the analogous limits at `KIND_PDXFS_FILE` (16 rows) and `KIND_PDXFS_TXN` (16 rows).

---

## 4. Journal + TXN semantics

### 4.1 WAL semantics — recap and R52 additions

The R42 `wal.pdx` scaffold established the "append → fsync → then-write" invariant. R52 preserves the semantic; the "fsync" is now realised as:

1. `BD_OP_WRITE_LBA` to the journal block (through the block cache, marked write-through for journal blocks — never write-back).
2. `BD_OP_FLUSH` to force the device queue to complete the write.
3. Compare-and-swap the WAL head pointer to advance past the just-fsynced record.

The WAL ring is now the journal region (§2.4); its capacity is `journal_bcount * (records-per-block)`, roughly 4096 records per MiB of journal for average record sizes. Journal-full pressure triggers a checkpoint (§4.3), not a mount failure.

### 4.2 Barrier discipline

The R51 `KIND_BLOCK_DEVICE`'s `BD_OP_FLUSH` is the primitive; softarch does not redesign its semantic here. The FS-side rules are:

- **Every journal write is followed by BD_OP_FLUSH before its checksum word is written.** This closes the "torn write" window: a torn journal block has an inconsistent `csum` and is rejected at replay.
- **Every JOP_COMMIT is followed by BD_OP_FLUSH before the corresponding data-region writes begin.** This is the wire-through of the R42 `journal_fence.pdx` fence semantic.
- **BD_OP_FLUSH is issued via the block-device cap's own op, not synthesised in the FS.** If the device is one whose write-order is naturally sequential (a queue-of-one NVMe SQ), the flush is cheap; the FS pays the flush cost regardless, and the driver optimises when it can.

### 4.3 Recovery on mount

The mount path in `probe.pdx` §3.1 step 5 continues with:

6. Read the last journal block (identified by the WAL head at last unmount, stored in-memory only; on cold boot, scan the journal region for the block with the highest `seq`).
7. Walk backwards through the `prev_lba` chain until reaching the block named by `checkpoint`. This is the replay range.
8. Walk forwards through the replay range, per-block CSUM-verifying. A CSUM failure truncates the replay range at that block (a torn write at the head is discarded).
9. For each record in the surviving range:
   - `JOP_BEGIN` marks the txn_id open in a small replay-side transaction table.
   - `JOP_BLOCK_WRITE` / `JOP_INODE_WRITE` / `JOP_BITMAP_*` / `JOP_DENTRY_*` records are buffered against the txn_id.
   - `JOP_COMMIT` releases the buffered writes to the in-place data region.
   - `JOP_ABORT` discards the buffered writes.
   - A txn_id that reached end-of-replay without a `JOP_COMMIT` or `JOP_ABORT` is treated as aborted (its buffered writes discard).
10. Advance the `checkpoint` pointer to the block after the last replayed COMMIT and rewrite the superblock's `flags` with the clean-unmount bit set.

Recovery is idempotent: replaying a range whose in-place writes already happened is a no-op (the writes are byte-identical). This is why `JOP_BLOCK_WRITE` records carry the full 4096-B block payload — recovery does not need to walk the CoW tree to reconstruct what was written.

### 4.4 Wiring KIND_PDXFS_TXN mutating ops to the journal

Today, `kind_pdxfs_txn.pdx`'s `PXT_OP_CREATE` / `PXT_OP_RENAME` / `PXT_OP_UNLINK` handlers bump a per-op counter and return `PXT_STUB_OK`. R52.M6 replaces the STUB body with a real walker invocation:

- **PXT_OP_CREATE.** Payload: parent_dir_inode + name + mode. Walker: allocate a fresh inode number from the inode-table free list; construct a fresh inode record; write `JOP_INODE_WRITE` for the fresh inode + `JOP_DENTRY_ADD` for the parent-directory entry + `JOP_BITMAP_SET` for the inode-table bit (if a new inode-table block is needed). All records join the txn_id from the cap-handler's row.
- **PXT_OP_RENAME.** Payload: old_dir_inode + old_name + new_dir_inode + new_name. Walker: `JOP_DENTRY_DEL(old)` + `JOP_DENTRY_ADD(new)`. Atomicity comes from both records being in the same txn — either both replay or neither does.
- **PXT_OP_UNLINK.** Payload: dir_inode + name. Walker: fetch the target inode; decrement refcount; if refcount reaches 0, walk the CoW tree and issue `JOP_BITMAP_CLEAR` for every block; `JOP_INODE_WRITE` with `in_use = 0`; `JOP_DENTRY_DEL` for the directory entry.

`PXT_OP_COMMIT` becomes: write `JOP_COMMIT` to the journal + BD_OP_FLUSH + transition the row state from OPEN to COMMITTED. `PXT_OP_ABORT` becomes: write `JOP_ABORT` to the journal + BD_OP_FLUSH + transition to ABORTED. The R48b state transition helper `pdxfs_txn_row_transition` is preserved; the new work happens before it.

The `PXT_STUB_OK` (`0xFFFFEBFB`) sentinel is retired at R52.M6-CLOSE; every mutating op now returns `PXT_OK` on success or a real errno on failure. Tools that were pattern-matching on `PXT_STUB_OK` (per `libpdx-cap`) fall through the `PXT_OK` arm cleanly (both are non-error).

### 4.5 Interaction with existing tooling

- **`pkg install`** currently writes to tmpfs and calls `PXT_OP_CREATE` for each file, getting `PXT_STUB_OK`. R52.M6 makes those calls real; the R49-scheduled `pkg install pkg` self-install is the M8 round-trip smoke (§7.8).
- **`cp` / `mv` / `rm` / `mkdir`** from R50 will begin returning real journaled mutations once M6 lands. R50's per-tool witnesses gain a "surviving reboot" line item (`design/tooling/r49-r50-plan.md` §5's per-tool M8 gets a smoke assertion that a file created before reboot is present after reboot).
- **`mkfs.pdxfs`** is a new userspace tool that lands in R52.M2 (not R49/R50). It formats a raw block device: writes the superblock, zeroes the allocator bitmap, initialises the inode table (inode 0 sentinel + inode 1 root directory), sets journal checkpoint = journal_lba. `mkfs.pdxfs --upgrade` reads an R25 lite-format superblock (`"PDXL"`) and rewrites it to `"PDXB"` with a fresh journal region carved from the tail; this is the migration path for any early-bring-up volumes formatted before R52.

---

## 5. Block cache (page cache)

### 5.1 Sizing and identity

A single per-volume block cache: `_pdxfs_block_cache[VOLUME_MAX]`, each cache a fixed pool of 256 cache slots × 4096 B = 1 MiB per volume, 16 MiB total (16-volume ceiling matches the volume registry). This is a conservative M7 sizing that lets the smoke matrix run in QEMU with 128 MiB of RAM; R53 may widen to a per-volume allocator hint.

Each cache slot: `{lba:u64, state:u8, gen:u16, refcount:u16, data[4096]}`, aligned to 4096. State byte values: `CS_EMPTY=0`, `CS_CLEAN=1`, `CS_DIRTY=2`, `CS_WRITEBACK=3`, `CS_LOCKED=4` (in-flight read/write with the block device).

### 5.2 Replacement — CLOCK, not LRU

**Recommendation: CLOCK (second-chance).** LRU with 256 slots would need a 256-entry doubly-linked list touched on every hit; CLOCK maintains a single per-slot reference bit that hardware/kernel updates cheaply and evicts by scanning a hand pointer. For a fixed-slot cache with high hit rates on hot working sets (directory blocks, inode-table blocks), CLOCK's approximation to LRU is close enough and the update discipline is one bit per hit rather than a link splice.

Rationale (LRU rejected):
- **LRU list surgery is a hazard site.** Every hit rewires the head-of-list pointer; concurrent-hit races require locking (a per-cache spinlock) that CLOCK sidesteps.
- **CLOCK's eviction fits the cache-line discipline** of `kind_*` tables in the substrate: a single scan word, atomically bit-cleared per revolution, is grep-able for correctness. LRU's list requires whole-file mental holding.

### 5.3 Write-back vs write-through

- **Journal blocks: write-through.** Every journal write follows §4.2's barrier discipline; the cache never lazy-writes a journal block.
- **Data-region blocks: write-back.** After JOP_COMMIT has been fsynced, in-place data-region writes go to the cache and are flushed by the writeback pass on a periodic tick or on cache pressure. The writeback pass issues `BD_OP_FLUSH` after every N=32 writes to bound the crash-loss window.
- **Inode-table blocks: write-through when part of a transaction commit, write-back otherwise.** An inode-table block whose modified bit belongs to an uncommitted txn is never written back — the journal record is the durable copy.

### 5.4 Read-ahead

A single-block-ahead read-ahead: on `BD_OP_READ_LBA(N)`, if the cache does not already hold LBA `N+1`, issue a low-priority prefetch. This is enough for sequential-scan workloads (directory reads, file reads) without the complexity of a real read-ahead window heuristic. The R42 CoW walker's block chains are not naturally sequential, so a wider window would be wasted on scattered fetches.

### 5.5 mmap — deferred

R52 does not offer mmap. The block cache's slot pool is not the same as `KIND_PAGE`'s allocation pool; mapping a cache slot into a user page table would require either a cache-to-page-table binding (a fourth state alongside CLEAN/DIRTY/WRITEBACK) or a copy from cache to a fresh page (which defeats mmap's zero-copy point). R56+ addresses this by unifying the cache slot pool with `KIND_PAGE`; R52 keeps read/write copy-in-copy-out.

---

## 6. Integration with existing KINDs

### 6.1 KIND allocations (softarch band: 0x1A0..0x1AF)

osarch has claimed 0x198..0x19F for HW KINDs at R51 (see companion doc). Softarch takes 0x1A0..0x1A7 for FS KINDs at R52; 0x1A8..0x1AF are reserved for R53 (snapshots-persistence, symlinks, xattr).

| KIND                    | Ordinal | Base kind             | Purpose                                                                 |
|:------------------------|:--------|:----------------------|:------------------------------------------------------------------------|
| `KIND_VOLUME`           | 0x1A0   | `KIND_MEMORY = 4`     | One mounted volume; carries device_slot, uuid, root_inode, mount_gen.   |
| `KIND_BLOCK_CACHE`      | 0x1A1   | `KIND_MEMORY = 4`     | One per-volume cache handle; ops FLUSH, INVALIDATE, PIN, UNPIN.         |
| `KIND_INODE_HANDLE`     | 0x1A2   | `KIND_PDXFS_FILE = 0x195` | Short-lifetime cached inode; refinement of PDXFS_FILE with in-mem seat. |
| `KIND_SIG_KEY`          | 0x1A3   | `KIND_MEMORY = 4`     | ML-DSA-65 public key handle for signed-inode-tail verification.         |
| _(reserved)_            | 0x1A4   |                       | R52.M8 growth slot — held for a superblock-only cap if §6.3 needs one.  |
| _(reserved)_            | 0x1A5..0x1A7 | | R53 slots (snapshot persistence, symlink, xattr).                       |

**Ordinal negotiation.** If osarch's HW KIND round claims more than 0x198..0x19F, softarch's band shifts to 0x1A8+; main will reconcile at the merge. This document assumes 0x1A0..0x1A7 is available; every ordinal reference below is by symbolic name so a shift is a mechanical rename.

**KIND_SUPERBLOCK — folded into KIND_VOLUME.** The task brief asks about a distinct `KIND_SUPERBLOCK`. Softarch's recommendation: fold it into `KIND_VOLUME`. The superblock is a per-volume artefact whose lifetime matches the volume mount; a separate cap would have zero use sites where a caller holding a `KIND_VOLUME` did not already hold every superblock query op. `KIND_VOLUME`'s ops include the superblock reads (`VOL_OP_QUERY_UUID`, `VOL_OP_QUERY_INODE_COUNT`, `VOL_OP_QUERY_FREE_BLOCKS`, `VOL_OP_QUERY_SIG_KEY_HASH`); a distinct KIND would be denormalisation.

### 6.2 KIND_PDXFS_FILE — add backing-store field

The R48b `KIND_PDXFS_FILE` row is `{header, inode_no, byte_len, mode_bits, created_ns, mtime_ns, refcount}` = 48 B. R52 extends the row to 64 B by adding two fields at the end:

- `[+48]  volume_slot: u64` — the `_pdxfs_volume_table` row index this file's inode lives in. `0xFF` for an in-memory-only file (tmpfs compatibility).
- `[+56]  inode_lba: u64` — the on-disk LBA of the inode-table block containing this file's inode. `0` if `volume_slot == 0xFF`.

Row-size widening is a controlled change: the R48b substrate-prep discipline in `design/user/pdxfs-kinds.md` §4 step 8 requires updating the file's `_pdxfs_file_table` bounds check + the confine-one list in `tools/build.sh`. R52.M4 makes this change; the existing 16-row cap is preserved (16 × 64 = 1024 B).

Backward compatibility: the R48b callers that instantiate a file row without the two new fields (tmpfs paths) set them to `0xFF, 0`; the accessors are additive.

### 6.3 KIND_PDXFS_TXN — wiring, no row shape change

The R48b `KIND_PDXFS_TXN` row already carries `snap_gen`, `wal_off`, and `bytes_touched`; R52 does not change the row shape. What changes is the walker body behind the CREATE / RENAME / UNLINK / COMMIT / ABORT op arms (see §4.4). The `wal_off` field, currently a nominal number, becomes the actual on-disk WAL byte offset of the transaction's first record — a stable identifier the replay walker uses to skip records that landed before this txn.

### 6.4 KIND_SIG_KEY — how the volume knows its signer

At boot, the loader passes an ML-DSA-65 public key material as a `KIND_SIG_KEY` cap to the FS init module. The `KIND_SIG_KEY` row: `{key_hash:[u8;32], key_material_lba:u64, key_type:u8}` where `key_type = 1` means ML-DSA-65 (other post-quantum algorithms reserved for future). The key material itself lives out-of-line at `key_material_lba` in a per-cap block (like inode signatures).

Volume mount cross-checks `superblock.sig_key_hash == KIND_SIG_KEY.key_hash`; a mismatch refuses the mount with `VOL_MOUNT_KEY_MISMATCH`. This forecloses the "attacker swaps the volume under a running kernel" attack: even if an attacker replaces the device backing, the mount will not accept a volume whose signer differs from the one the loader authorised.

The key-material fetch + verify path is in a separate module `src/kernel/core/fs/pdxfs/sig_verify.pdx` (R52.M5). It is the sole call site for the paideia-as ML-DSA-65 verify intrinsic (see §8.1).

### 6.5 KIND_BLOCK_CACHE — supervisor-only

The block cache handle is supervisor-only (no userspace cap holder). Its ops (`BC_OP_FLUSH`, `BC_OP_INVALIDATE`, `BC_OP_PIN`, `BC_OP_UNPIN`) are called by the walker; user-visible caching is invisible. Reserving the KIND here is defensive: R55+ may want a userspace-side cache-stats query, and a KIND slot pre-allocated avoids a re-shape then.

---

## 7. Milestone breakdown

R52.M1..M8, each a commit-scale chunk with 4-6 issue titles.

### 7.1 R52.M1 — Superblock format freeze + on-disk layout doc

- `R52.M1-001 Freeze PDXB superblock layout at 4096 bytes`
- `R52.M1-002 Land src/kernel/core/fs/pdxfs/superblock.pdx (offsets + accessors)`
- `R52.M1-003 Land design/filesystem/volume-fs-substrate.md (this document)`
- `R52.M1-004 Cross-reference PDXB layout from cow-design.md + pdxfs-lite-format.md`
- `R52.M1-005 Boot witness: hard-coded superblock bytes parse cleanly`

### 7.2 R52.M2 — Superblock read/write + mkfs.pdxfs tool

- `R52.M2-001 Land core/fs/pdxfs/superblock_read.pdx (LBA-0 fetch + magic/version/sig gates)`
- `R52.M2-002 Land core/fs/pdxfs/superblock_write.pdx (mkfs primitive; signs bytes [0, 696))`
- `R52.M2-003 Land userspace tool mkfs.pdxfs (formats a block-device cap into a fresh volume)`
- `R52.M2-004 Land mkfs.pdxfs --upgrade (PDXL → PDXB rewrite path)`
- `R52.M2-005 Smoke: mkfs → probe → mount refuses because inode table not initialised (M4 gate)`
- `R52.M2-006 Boot witness: probe finds one PDXB volume; fingerprint the UUID`

### 7.3 R52.M3 — Block allocator (bitmap) + free-space tracking

- `R52.M3-001 Land core/fs/pdxfs/allocator.pdx (bitmap read/write, alloc_hint, free stack)`
- `R52.M3-002 Land BITMAP_SET / BITMAP_CLEAR primitives + WAL record encoders`
- `R52.M3-003 Land allocator-scan-on-mount (seed alloc_hint from first free bit)`
- `R52.M3-004 Land tools/pdxfsck (free-space verify against inode block references)`
- `R52.M3-005 Boot witness: alloc 8 blocks + free 4 + verify hint moved`

### 7.4 R52.M4 — Inode table + inode lookup + KIND_INODE_HANDLE

- `R52.M4-001 Widen KIND_PDXFS_FILE row from 48 to 64 bytes (add volume_slot, inode_lba)`
- `R52.M4-002 Land core/fs/pdxfs/inode_table.pdx (read, write, allocate-fresh, scrub)`
- `R52.M4-003 Register KIND_INODE_HANDLE (0x1A2) refining KIND_PDXFS_FILE`
- `R52.M4-004 Land inode_no → (inode_lba, slot_in_block) resolver`
- `R52.M4-005 Land sig-tail read + BLAKE3 hash verify + prefix-match tear detect`
- `R52.M4-006 Boot witness: alloc inode 42 + mkfs-time root inode 1 both fetch cleanly`

### 7.5 R52.M5 — Journal WAL + recovery on mount + KIND_VOLUME mount

- `R52.M5-001 Register KIND_VOLUME (0x1A0) + KIND_SIG_KEY (0x1A3)`
- `R52.M5-002 Land core/fs/pdxfs/journal_ondisk.pdx (JBNL block layout + record encoders)`
- `R52.M5-003 Rewrite journal_replay.pdx to walk on-disk JBNL blocks (replaces BSS scaffold)`
- `R52.M5-004 Land core/fs/pdxfs/volume_registry.pdx + probe.pdx`
- `R52.M5-005 Extend mount.pdx with MOUNT_BACKEND_PDXFS_BLOCK = 5 + backend_registry dispatch`
- `R52.M5-006 Boot witness: mount root volume + replay 3 committed txns + panic-clean checkpoint advance`

### 7.6 R52.M6 — Wire KIND_PDXFS_TXN mutating ops through journal

- `R52.M6-001 Rewrite kind_pdxfs_txn.pdx PXT_OP_CREATE to emit JOP_INODE_WRITE + JOP_DENTRY_ADD`
- `R52.M6-002 Rewrite PXT_OP_RENAME to emit JOP_DENTRY_DEL + JOP_DENTRY_ADD`
- `R52.M6-003 Rewrite PXT_OP_UNLINK to walk CoW tree + emit JOP_BITMAP_CLEAR + JOP_INODE_WRITE + JOP_DENTRY_DEL`
- `R52.M6-004 Rewrite PXT_OP_COMMIT to emit JOP_COMMIT + BD_OP_FLUSH + row transition`
- `R52.M6-005 Rewrite PXT_OP_ABORT to emit JOP_ABORT + row transition (no data writes)`
- `R52.M6-006 Retire PXT_STUB_OK sentinel + update libpdx-cap decoders`

### 7.7 R52.M7 — Block cache (read + write-back) + read-ahead

- `R52.M7-001 Land core/fs/pdxfs/block_cache.pdx (256-slot CLOCK, per-volume)`
- `R52.M7-002 Register KIND_BLOCK_CACHE (0x1A1) supervisor-only`
- `R52.M7-003 Wire cache into cow_read.pdx + cow_write.pdx (replaces nvme_write scaffold ring)`
- `R52.M7-004 Land write-back tick + BD_OP_FLUSH cadence (every 32 writes)`
- `R52.M7-005 Land single-block-ahead prefetch on BD_OP_READ_LBA`
- `R52.M7-006 Boot witness: 1024-block sequential read + cache-hit ratio ≥ 0.75`

### 7.8 R52.M8 — Full round-trip smoke

- `R52.M8-001 tools/run-smoke.sh: mkfs.pdxfs on a QEMU-attached blank NVMe device`
- `R52.M8-002 Boot from that device + verify root mount + verify root inode readable`
- `R52.M8-003 pkg install pkg (journaled write of every pkg file) + commit`
- `R52.M8-004 Unmount cleanly (checkpoint advance + clean-unmount flag set)`
- `R52.M8-005 Reboot + remount + verify every pkg file byte-identical + verify every signature`
- `R52.M8-006 Fingerprint the round-trip in tests/r52/round-trip.golden (matches R48b golden discipline)`

---

## 8. Cross-repo dependencies

### 8.1 paideia-as encoder gaps

R52 depends on the following paideia-as intrinsics reaching stability. Any gap becomes a paideia-as issue filed against a matching phase per `feedback_cross_repo_escalation`:

- **ML-DSA-65 sign + verify.** Superblock signing at mkfs (M2), inode signing at inode-write (M6), inode verify at read (M4). The `paideia-as ≥ v0.33-crypto-kdf` bundle exposes verify per `design/tooling/r49-r50-plan.md` §2.4; **sign is the R52 blocker gap** — mkfs cannot produce a valid superblock signature without it. Softarch flags: paideia-as needs a `mldsa65_sign(msg_ptr, msg_len, sk_ptr, sig_out_ptr) → sig_len` intrinsic before R52.M2 opens.
- **BLAKE3-XOF or BLAKE3-hash-32.** For `sig_hash` (inode M4), `content_hash` (inode M4), and the volume `sig_key_hash` (mkfs M2). Paideia-as likely has BLAKE3-hash-32 from R41 semantic-terminal work; softarch to verify — if not, a paideia-as `blake3_hash32(msg_ptr, msg_len, out_ptr) → ()` intrinsic is R52.M1's paideia-as-side dependency.
- **CRC32C.** Journal-block checksums (M5). Paideia-as has this from R42's `journal_csum.pdx` work; no gap expected.
- **Atomic 8-byte writes across sector boundaries.** The R51 driver family handles device-side atomicity; the FS side's assumption is that a single-block write is atomic at the device layer (the block either fully arrives or does not, and a torn write is CSUM-detectable). No new paideia-as intrinsic needed.

### 8.2 osarch coordination points

- **KIND ordinal band.** Softarch takes `0x1A0..0x1A7`; osarch takes `0x198..0x19F`. If osarch's HW KIND count exceeds 8, softarch shifts to `0x1A8+`.
- **`KIND_BLOCK_DEVICE` op set.** Softarch depends on `BD_OP_READ_LBA`, `BD_OP_WRITE_LBA`, `BD_OP_FLUSH`, `BD_OP_QUERY`. `BD_OP_TRIM` is nice-to-have (M6 unlink could TRIM freed blocks) but not blocking; if osarch defers TRIM, softarch defers §4.4's UNLINK-path TRIM issuance to R53.
- **Discovery timing.** Softarch's probe (§3.1) runs after every `KIND_BLOCK_DEVICE` mint. Osarch's driver reset semantic must ensure the device is quiesced (queue empty, BD_OP_QUERY answers correctly) before the mint fires; softarch depends on this ordering.
- **DMA-domain consent.** The block cache's read/write buffers must live in `KIND_PAGE` allocations that the block-device driver's DMA-domain (`KIND_DMA_DOMAIN` from R29.M5) is authorised to touch. Softarch's cache allocator (M7-001) requests pages from a DMA-safe allocator; osarch to expose which allocator that is.

### 8.3 Bootloader coordination

The R11 bootloader must be extended to pass a `root_volume_uuid: u8[16]` field in its handoff record. Filed as a bootloader-issue in the R52.M5 wave; if the bootloader change slips, softarch falls back to the superblock `bit1 root-volume` flag (§3.3), which the M8 smoke uses regardless.

---

## 9. What R52 does NOT do

Explicit non-scope, so a future round can pick these up rather than rediscover them:

- **`mmap`.** Cache-slot to page-table mapping is R56+ once cache and `KIND_PAGE` unify.
- **Symlinks and hard links.** `KIND_PDXFS_SYMLINK` (per `design/user/pdxfs-kinds.md` §3.2) is R53; hardlinks need the on-disk inode refcount already there but need dentry-count discipline the R52 dentry format does not check.
- **Extended attributes (xattr).** The 128-B inode has no xattr slot; adding one is R54 (per-inode indirect xattr block reference).
- **ACLs.** POSIX-style ACLs are not on the roadmap; PdxFS's capability model at `KIND_PDXFS_FILE` + `KIND_USER` supersedes them.
- **Quotas.** Per-user block quotas would need a per-user counter block; R55+.
- **Snapshot persistence.** The R42 snapshot walker exists (`snap_create.pdx` etc.); wiring it to a persistent snapshot-region layout in the superblock is R53. The `snap_head` field in the superblock (§2.1) is reserved for this.
- **Multi-volume mount via userspace `sys_mount`.** R52 mounts root only; non-root volumes are discovered by probe but not mounted until R53.
- **Compat filesystems (ext4-ro, FAT).** Never in-kernel. A userspace importer as a `pkg install` is fine at any future round.
- **Encryption at rest.** Signed-inode-tail is R52; per-block encryption is R54+ (needs `KIND_KEK` and per-block IV discipline).
- **Compression.** `design/filesystem/compression-catalog.md` picks zstd/LZ4/XZ; wire-through is a per-inode `compression_cap` attribute R54+.
- **Multi-device pool (RAID-like).** `design/filesystem/multi-device-pool.md` exists as a design sketch; wire-through is R55+.

---

## Appendix A — Module inventory (new files R52 lands)

Under `src/kernel/core/fs/pdxfs/`:
- `superblock.pdx` (M1), `superblock_read.pdx`, `superblock_write.pdx` (M2)
- `allocator.pdx` (M3)
- `inode_table.pdx`, `sig_verify.pdx` (M4)
- `journal_ondisk.pdx`, `volume_registry.pdx`, `probe.pdx` (M5)
- `block_cache.pdx` (M7)

Under `src/kernel/core/cap/`:
- `kind_volume.pdx`, `kind_sig_key.pdx` (M5)
- `kind_block_cache.pdx` (M7)
- `kind_inode_handle.pdx` (M4)

Modified files (edit, not replace):
- `src/kernel/core/cap/kind.pdx` — new KIND ordinal constants (0x1A0..0x1A3)
- `src/kernel/core/cap/kind_pdxfs_file.pdx` — row widening (M4)
- `src/kernel/core/cap/kind_pdxfs_txn.pdx` — real mutating op bodies (M6)
- `src/kernel/core/fs/mount.pdx` — MOUNT_BACKEND_PDXFS_BLOCK = 5
- `src/kernel/core/fs/backend_registry.pdx` — dispatch arm for backend 5
- `src/kernel/core/fs/pdxfs/wal.pdx` — thin wrapper over journal_ondisk.pdx (BSS ring retires)
- `src/kernel/core/fs/pdxfs/nvme_write.pdx` — thin wrapper over block_cache.pdx (BSS ring retires)
- `src/kernel/core/fs/pdxfs/journal_replay.pdx` — walks on-disk JBNL blocks (M5)
- `src/kernel/core/audit/audit_schema.pdx` — bump `aud_kind_valid` upper bound to 0x1A3
- `tools/build.sh` — `ec_confine_one` on every new `_*_table` / `_*_stats`
- `src/kernel/boot/witness/r52_platform.pdx` — new file per §7 M-per-M witnesses
- `tests/r52/*.golden` — per-milestone fingerprints (mirrors R48b `tests/r17/shell-shutdown.golden` discipline)

## Appendix B — Discipline for landing a new PdxFS-on-block KIND

Mirrors `design/user/pdxfs-kinds.md` §4, extended for the block-backed substrate:

1. **Register the numeric tag** in `src/kernel/core/cap/kind.pdx` in the R52 reserved band (0x1A0..0x1A7). Update `design/architecture/next-wave-derived-kinds.md` §"R52 volume-fs" in the same commit.
2. **Land the module** under `src/kernel/core/cap/kind_<name>.pdx` with the standard primitives (`_table` + `_stats`, rights validator, tail alloc/valid/free, row accessors, mint walker, cap_revoke, cap_handler).
3. **Wire dispatch** in `core/cap/invoke.pdx`.
4. **Add chatter tag** in `core/cap/tags.pdx`.
5. **Bump `aud_kind_valid` upper bound** in `core/audit/audit_schema.pdx` if the new tag exceeds the current bound.
6. **Confine tables** in `tools/build.sh` (`ec_confine_one` on `_<name>_table` and `_<name>_stats`).
7. **Add witness** under `tests/kernel/cap/kind_<name>_synth.pdx`, wired into `src/kernel/boot/witness/r52_platform.pdx` and its fingerprint into `tests/r52/round-trip.golden`.
8. **Update `design/user/pdxfs-kinds.md`** §2 (or `design/architecture/next-wave-derived-kinds.md`) with the new row.
9. **If the KIND touches block-device I/O:** cross-reference the osarch `KIND_BLOCK_DEVICE` op set in the module's §0 header so the read/write barrier discipline (§4.2 of this doc) is grep-able from the module.
