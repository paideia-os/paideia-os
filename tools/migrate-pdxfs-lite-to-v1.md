# PdxFS-lite v0 → PdxFS v1 (CoW-PQ) migration — design stub

**Owner issue:** #938 (R25.M7-002).
**Status:** Design stub landed at R25.M7 close; **tool implementation
lands at R40** (`design/filesystem/cow-design.md` closure boundary).
**Scope at R25:** documentation only — no tool code, no CI wiring.

---

## 0. Why a stub now?

The R25 round explicitly locks the PdxFS-lite v0 on-disk format as a
**one-way stepping stone** (per `design/filesystem/pdxfs-lite-format.md`
§7 and `design/roadmap/r18-plus-bare-metal.md` §0 decision 2). Every
image mkfs'd at R25 is expected to be migrated — not upgraded in-place
— to PdxFS v1 at the R40 boundary, or wiped and re-mkfs'd if the user
is willing to accept data loss.

Landing the migration-tool skeleton at R25 close (rather than at R40
open) fixes three commitments:

1. **The v0 format cannot secretly grow a v1-incompatible field.**
   Anything a future PdxFS v1 designer wants that isn't reflected in
   §3 of this document becomes their problem (either a redesign of
   the migrator, or a re-mkfs mandate for existing v0 images).
2. **The R40 preflight has a starting point.** The R40 kickoff can
   land as "implement the tool described in
   `tools/migrate-pdxfs-lite-to-v1.md`", not as a design pass.
3. **Rollback isn't offered.** Explicitly documenting v0→v1 as
   one-way removes the temptation to build a v1→v0 downgrade path in
   R40 or later. If we ever regret the R25 format, we regret the
   data, not the design.

---

## 1. Source format — PdxFS-lite v0

Governed by `design/filesystem/pdxfs-lite-format.md`. Summary for the
migrator's purposes:

- **Block size:** fixed 4096 B.
- **Superblock:** LBA 0. 4 KiB; magic `"PDXL"` (`0x4C584450`);
  version = 1; UUID at bytes 8..24; itable_lba / extent_area_lba /
  root_ino at fixed offsets; sig at [696, 4096) — ML-DSA-65 or
  dev-bypass all-zero.
- **Inode table:** contiguous block run at `itable_lba`. 128-byte
  inodes, 32 per block. Slot 0 reserved; slot 1 = root dir.
- **Extents:** 8 inline extents per inode (each `start_lba` u64,
  length always 1 block at MVP); 1 indirect extent block pointer
  (`indirect_lba`, 512 additional extent entries).
- **Extent bitmap:** packed bitmap at `extent_area_lba`; 1 bit =
  1 allocated 4 KiB data block.
- **Directories:** 256-byte dentries in the data blocks pointed at
  by the directory inode's extents; each dentry holds
  `{inode_id, name_len, name[240 max], type}`.
- **Signatures:** superblock only.
- **Journal:** none.
- **CoW:** none (write-in-place; R25.M6 returns EROFS pending #906).
- **Compression:** none.
- **Encryption:** none.
- **Multi-device pooling:** no (single blkdev only).

Everything above is stable across R25 close.

---

## 2. Target format — PdxFS v1 (CoW-PQ)

Governed by `design/filesystem/cow-design.md` (R40 round). Summary for
the migrator's purposes:

- **Block size:** likely 4096 B (matches R25 mkfs, matches most NVMe
  LBA formatting). The migrator MUST reject if v1 chooses a different
  size — a block-size change is a full data rewrite plus rebalancing,
  not a migration.
- **Superblock magic:** `"PDX1"` (distinct from v0's `"PDXL"`).
- **CoW:** every write allocates fresh blocks; the extent tree points
  at the new block; the old block enters the snapshot GC queue per
  `design/filesystem/snapshot-gc.md`.
- **Journal:** on-disk journal region at a fixed reserved offset; ID
  ordering per `design/filesystem/pdxfs-lite-format.md` §snapshot
  cursor (already reserved in v0 `_reserved` for exactly this).
- **Per-extent signing:** ML-DSA-65 signature on every extent (per
  `design/filesystem/pdxfs-lite-format.md` §5.4 promotion path); adds
  ~3.3 KiB per extent — v1 packs extents into signed batches to
  amortise.
- **Compression + encryption:** per-extent, algorithm negotiated in
  the extent descriptor's `flags` field.
- **Multi-device pooling:** yes (per `design/filesystem/multi-device
  -pool.md`); v0 images always migrate into a single-device v1 pool.

The migrator DOES NOT need every v1 field detail — the R40 spec can
grow between R25 close and R40 open; only the fields the migrator
writes (§3 below) are load-bearing here.

---

## 3. Migration approach

### 3.1 Overview

The migrator is a **host-side tool** (paideia-native binary running
under Linux, same shape as `tools/mkfs-pdxfs-lite.sh`) that:

1. Opens the source blkdev (or image file) **read-only**.
2. Allocates a fresh target blkdev (or image file) sized ≥ source +
   v1 overhead (superblock swap + journal region + snapshot GC ring
   + per-extent sig padding — call it ≥ 1.5 × source at MVP).
3. Walks every v0 inode, extract file bytes.
4. Rewrites into the target as v1 (fresh v1 inode table, fresh v1
   extent tree, fresh v1 dentries).
5. Stamps the target superblock with v1 magic (`"PDX1"`), signed
   with the v1 signing key.
6. Optionally deletes the source (`--replace-source`) or leaves it
   as archival read-only reference (default).

No in-place bit-flipping. The target is a fresh image; the migrator
is essentially `cat v0_img | mkfs.pdxfs-v1 --seed-from-tree=/dev/stdin`
plus per-file metadata restoration.

### 3.2 Superblock swap

The migrator writes v1's superblock in one operation as the last step
of the migration. Until that write lands, the target's LBA 0 contains
zeros (or garbage from the previous drive lifetime — the migrator
zero-fills first).

If the migrator is interrupted (power loss, kill -9) before this last
write:

- **Source is unchanged** (opened read-only from step 1).
- **Target has partial v1 tree in mid-LBA space + zero superblock.**
  Rerun the migrator; it detects the zero superblock and rewinds
  (`truncate` back to zero + start over). This IS the atomic
  boundary.

There is no v0-with-partial-v1 intermediate state that could be
mounted as either.

### 3.3 Inode remapping

v0 slot numbers do NOT survive migration. The v1 rewrite starts with
its own slot allocator; the migrator maintains an in-memory
`{v0_inode_id -> v1_inode_id}` table for the duration of the run so
that when it rewrites a v0 dentry, it substitutes the v1 slot for the
child.

Root inode is special: v0's slot 1 becomes v1's slot 1 by construction
(both formats reserve slot 0 as the invalid-inode sentinel and slot 1
as the root directory).

Hard-link preservation (v0's `link_count`) requires the migrator to
detect multi-link inodes (via a `{v0_inode_id -> visited_count}` set)
and reuse the already-written v1 slot on the second and later dentry
encounters. R25 MVP has no hard-link creation path (`create.pdx`
returns EROFS anyway), so a fresh R25 image never has `link_count > 1`
— but a future R25.x round might, and the migrator must be safe under
that case.

### 3.4 Extent copy

Every v0 extent (inline or indirect) resolves to one 4 KiB block of
file bytes. The migrator:

1. Reads the source block.
2. Verifies its CRC32C against the inode checksum field (v0 spec
   §2.1).
3. Writes it into a fresh v1 extent (which may compress it, encrypt
   it, sign it — the migrator opaquely hands the bytes to
   `pdxfs_v1_write_extent(vfile, offset, bytes)`; the v1 writer owns
   those transforms).
4. Records the v1 extent descriptor in the growing v1 inode's extent
   tree.

Empty extents (v0 `start_lba == 0`) are skipped — v1's sparse-file
support handles the gap natively.

### 3.5 Directories

v0 dentries are re-emitted as v1 dentries. Directory ordering is not
preserved (v1 may use a B-tree or hash table per
`design/filesystem/cow-design.md`; v0's linear scan order is
irrelevant). Every `readdir` after migration returns the same
**set** of entries but not necessarily the same order.

The MVP shell (`ls`, `cat`, `echo > file`) does not depend on dentry
order, so this is invisible at the user-visible layer for every
current R25 use case.

### 3.6 Timestamps

v0's `{atime, mtime, ctime}` fields copy through byte-for-byte
(both formats use ns-since-epoch u64). If v1 grows a `crtime` field
(creation time), the migrator fills it with `ctime` as the best
available approximation.

---

## 4. Safety — checksum every block

Every source block read gets its CRC32C recomputed and compared
against the inode's checksum field before the migrator hands the
bytes to the v1 writer. On mismatch:

- **Default:** abort the whole migration (fail-safe; the operator
  should fsck the source first).
- **`--tolerate-checksum-errors`:** log the affected inode + block +
  computed-vs-stored CRC to the migration report, substitute a
  zero-block for the corrupt block, continue. The migration report
  lists every substitution so the operator can restore from backup
  after the fact.

The v1 superblock is written LAST (§3.2). If any migration step
fails and the tool exits without writing the v1 superblock, the
target is unmountable-as-v1, and no one can accidentally trust it.

---

## 5. Cross-references

- `design/filesystem/pdxfs-lite-format.md` — v0 spec being migrated
  from.
- `design/filesystem/pdxfs-lite-format.md §7` — original migration
  paragraph this document elaborates.
- `design/filesystem/cow-design.md` — v1 spec being migrated to.
- `design/filesystem/snapshot-gc.md` — v1 snapshot GC that v0 has no
  counterpart for.
- `design/filesystem/multi-device-pool.md` — v1 multi-device that v0
  cannot represent.
- `design/roadmap/r18-plus-bare-metal.md §R40` — the round this tool
  lands in.
- `tools/mkfs-pdxfs-lite.sh` — the host-side tool this migrator will
  structurally mirror.
- `design/round-retrospectives/r25-closure.md` — R25-close retro that
  registers this document as a debt-with-owner.

---

## 6. What this document is NOT

- **Not a spec.** The v1 side of the mapping is stated at
  fill-in-the-blank fidelity — the v1 side becomes normative at R40
  open, and this document gets rewritten then to cite the real v1
  spec sections.
- **Not runnable.** No `tools/migrate-pdxfs-lite-to-v1.sh` exists at
  R25 close and is not scheduled to exist before R40. Any request
  for one before R40 is a round-scoping conversation.
- **Not a schema evolution mechanism.** Schema evolution within v0
  (e.g., v0.1 → v0.2 extent-descriptor repacking per
  `design/filesystem/pdxfs-lite-format.md §2.3`) has its own separate
  handling — `design/filesystem/schema-evolution.md` governs that
  path.

---

*Landed 2026-08-11 at R25.M7 (#938). Tool implementation lands at R40
per `design/roadmap/r18-plus-bare-metal.md`.*
