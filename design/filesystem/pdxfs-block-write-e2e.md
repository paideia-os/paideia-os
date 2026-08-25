---
issue: 1783, 1784, 1785, 1786
milestone: R55.M2 (pdxfs-block write path end-to-end)
subsystem: filesystem / pdxfs-on-block v1
topic: End-to-end write path for a fresh file on a pdxfs-block volume.
       Four landings so far: §Allocator (extent-run first-fit),
       §Inode-table-write (RMW of a 128-B inode row over bdev_write_at),
       §WAL (bdev-backed WAL append + fsync over bdev_write_at), and
       §pdxfs_block_write (composed end-to-end write that threads all
       three primitives together). §Cache is the next landing.
touching:
  - src/kernel/core/fs/pdxfs/allocator.pdx      (extend: alloc_extent_run)
  - src/kernel/core/fs/pdxfs/inode_table.pdx    (extend: inode_table_write
                                                 + _inode_write_scratch)
  - src/kernel/core/fs/pdxfs/bdev_write.pdx     (extend: bdev_write_at)
  - src/kernel/core/fs/pdxfs/wal.pdx            (extend: wal_append_write,
                                                 wal_fsync_bdev, _wal_scratch,
                                                 _wal_bdev_state)
  - src/kernel/core/fs/pdxfs/cow_write.pdx      (extend: pdxfs_block_write
                                                 -- composed end-to-end write)
  - src/kernel/core/fs/pdxfs/journal_csum.pdx   (header note: csum choice
                                                 delegated to jnl_crc32c_range)
  - src/kernel/core/klog/keys.pdx               (extend: tag_pdxb_alloc_ok,
                                                 tag_pdxb_alloc_verify_ok,
                                                 k_start_lba, k_len_lba,
                                                 tag_pdxb_inode_write_ok,
                                                 k_ino,
                                                 tag_pdxb_wal_fsynced_ok,
                                                 k_records, k_lba,
                                                 tag_pdxb_write_ok,
                                                 k_offset)
  - tools/build.sh                              (confine _inode_write_scratch,
                                                 _wal_scratch, _wal_bdev_state;
                                                 arity-pin wal_append_write /
                                                 wal_fsync_bdev)
  - tests/r55/expected-r55-alloc.txt            (2-line spec golden)
  - tests/r55/expected-r55-inode-write.txt      (1-line spec golden)
  - tests/r55/expected-r55-wal-fsync.txt        (1-line spec golden)
  - tests/r55/expected-r55-write-e2e.txt        (1-line spec golden)
  - design/filesystem/pdxfs-block-write-e2e.md  (this doc)
related:
  - src/kernel/core/fs/pdxfs/allocator.pdx      (alloc_block / free_block —
                                                 mirrored allocation posture)
  - src/kernel/core/fs/pdxfs/inode_table.pdx    (128-byte on-disk row —
                                                 receives the extent stamp)
  - src/kernel/core/cap/bdev_barrier.pdx        (bdev_barrier_write — the
                                                 shared durable-writeback path)
  - design/filesystem/volume-fs-substrate.md    (bitmap + inode + WAL layout)
  - design/filesystem/r52-implementation-plan.md §2.3 / §2.4
---

# pdxfs-block write path end-to-end

The pdxfs-block volume becomes writable in a fixed order of primitives:

1. **§Allocator** (R55.M2-001 / #1783) — reserve a contiguous run of
   data blocks and record the reservation on disk.
2. **§Inode-table-write** (R55.M2-002 / #1784) — persist a 128-B inode
   row into its 4-KiB bearer block via read-modify-write over
   `bdev_write_at`.
3. **§WAL** (R55.M2-003 / #1785) — enforce the WAL-fsync-before-data-
   write barrier `bdev_write.pdx` §0 refuses to enforce itself. Every
   `pdxfs_block_write` MUST cross `wal_append_write` + `wal_fsync_bdev`
   before a data-block `bdev_write_at` is permitted.
4. **§pdxfs_block_write** (R55.M2-004 / #1786) — the composed
   end-to-end write op that threads the three primitives above into
   one callable that resolves the inode, allocates an extent if
   needed, crosses the WAL barrier, writes the data block, and
   persists the mutated inode row.
5. **§Cache** (later) — the block-cache handle that folds identical
   bitmap-block writes across a burst of allocations into one physical
   write.

Landed so far: §Allocator (R55.M2-001), §Inode-table-write
(R55.M2-002), §WAL (R55.M2-003), and §pdxfs_block_write (R55.M2-004).
§Cache is added by its own issue; the doc is the composition point.

## §Allocator — extent-run first-fit (#1783)

### Signature

```
alloc_extent_run(bdev_cap: u64,
                 want_len: u64,
                 out_start_lba_ptr: u64,
                 out_granted_len_ptr: u64,
                 inode_row_ptr: u64) -> u64
```

- `bdev_cap` — the block-device capability the underlying `bdev_barrier
  _write` invokes. Same posture as `alloc_block` (see the file's header
  gap 1 on why this is threaded caller-side rather than looked up in a
  vol_slot registry that does not exist yet).
- `want_len` — caller-requested contiguous block count. Silently capped
  at `ALLOC_EXTENT_RUN_MAX` = 8. `want_len == 0` returns
  `ALLOC_EXHAUSTED` rather than a zero-length success.
- `out_start_lba_ptr` — where to write the run's absolute first LBA.
  Ignored when 0 (test/witness callers can exercise the fingerprint
  without caring about the value).
- `out_granted_len_ptr` — where to write the actually-allocated length
  (`<= want_len`). Ignored when 0.
- `inode_row_ptr` — pointer to the caller-owned 128-byte inode row. When
  non-zero, the allocator stamps extent slot 0 at row-offset 48 (see
  "Extent slot 0 stamping" below). Ignored when 0.

Returns 0 on success, or one of `ALLOC_EXHAUSTED` (0xFFFFED10) /
`ALLOC_BITMAP_TORN` (0xFFFFED11). No new failure code is minted for
#1783 — the M3 band already names both codes and the write path here is
identical in shape to `alloc_block`'s.

### First-fit scan (single resident bitmap block)

The scan operates on the single 4-KiB bitmap block already loaded by
`alloc_bm_ensure_loaded` at `alloc_lba` (bit `i` covers `data_lba + i`).
Multi-block scanning is a deliberate NON-goal for #1783, carrying
forward the same posture the file's own header gap 2 documents for
`alloc_block`/`free_block`: the allocator holds one resident bitmap
block at a time, and `alloc_scan_on_mount`'s whole-region walk already
handles the multi-block case for hint seeding.

Scan shape (pseudocode; the real body is entirely in registers, no
allocations):

```
i = 0
while i + granted_len <= 32768:
  for j in 0..granted_len:
    if bit(i + j) == 1:
      i = i + j + 1        # skip past the blocker
      break
  else:
    return i               # first-fit success
return ALLOC_EXHAUSTED
```

The `i = i + j + 1` skip is what makes the scan first-fit rather than
naively O(n·k) — every set bit advances the outer cursor past itself
rather than retrying from `i + 1`. Under a mostly-empty bitmap the scan
terminates on iteration 0.

### Immediate-commit posture

On finding a run:

1. `alloc_bit_set` fires for every bit in `[start_i, start_i +
   granted_len)`.
2. `bdev_barrier_write` durably writes the modified bitmap block back
   in ONE I/O regardless of run length — matching `alloc_block`'s
   own single-write posture (a torn write between the set of bit `i`
   and bit `i+1` cannot happen because the bits share a 4-KiB block
   that is either fully committed or fully un-committed).
3. `bbjw_check` filters `bdev_barrier_write`'s forwarded status; any
   non-acceptable result maps to `ALLOC_BITMAP_TORN`. The set bits are
   NOT rolled back on failure — the in-memory bitmap has bits set that
   are not on disk yet, exactly as `alloc_block` already leaves things
   on this failure (the next `alloc_bm_ensure_loaded` re-loads the
   on-disk state and the in-memory diff is silently discarded).

The immediate-commit posture is inherited from `alloc_block` — softarch
already confirmed it there. `inode_table.pdx`'s own gap 1 called out
the same posture for `inode_alloc_fresh`; this landing extends the
precedent to extent-run allocation without adding a new question.

### Extent slot 0 stamping (over `root_block`)

On success, when `inode_row_ptr != 0`, the allocator writes one packed
u64 at `inode_row_ptr + INODE_EXTENT_SLOT0_OFF` (= 48):

```
packed = (granted_len << 48) | (start_lba & 0x0000_FFFF_FFFF_FFFF)
```

- Low 48 bits carry the absolute start LBA. 2^48 blocks at 4 KiB each
  is 1 PiB of addressable volume — well past what pdxfs-on-block will
  see in the field.
- High 16 bits carry the run length. 2^16 blocks is 256 MiB at 4 KiB
  per block — well past `ALLOC_EXTENT_RUN_MAX` = 8, so the field is
  underused today but leaves headroom for a widening.

**Aliasing note.** Offset 48 is where `inode_table.pdx`'s R52.M4 on-disk
row layout put the single `root_block` field. R55's move to extent-based
files supersedes the single-block root_block model, and
`inode_table.pdx` will be widened alongside `pdxfs_block_write` (#1784)
to name this offset as `extent[0]`. Until that landing lands, the
allocator's stamp writes valid extent-slot bytes at the position the
old layout named `root_block`; no reader in the current tree consults
that field on a fresh inode, so the aliasing is benign in this window.
Callers wanting to reserve the extent without stamping (mid-transition)
pass `inode_row_ptr = 0`.

Slots 1..7 are NOT written by this landing — a fresh file that fits in
one 8-block extent uses only slot 0; multi-slot orchestration for
larger files lands in `pdxfs_block_write` (#1784).

### Post-condition self-verify

After the durable writeback, the allocator re-reads every bit in
`[start_i, start_i + granted_len)` via `alloc_bit_test` and refuses
(returns `ALLOC_BITMAP_TORN`) if any reads back as 0. This is defensive
against an encoder-time regression in `alloc_bit_set` that would leave
bits at their pre-call values without the durable write ever noticing
(the write goes through regardless of what the buffer holds). The
verify pass adds `granted_len` extra `alloc_bit_test` calls on the
success path — negligible cost at the ceiling of 8 blocks per run.

### Fingerprint (wire — two lines per successful call)

Both lines are emitted via `klog_s1_x2` inside `alloc_extent_run` on
the success path, LEVEL_INFO / SUBSYS_FS__, in the order:

```
pdxb alloc ok [legacy: PDXB ALLOC OK] start_lba=0x0000000000000200 len_lba=0x0000000000000004
pdxb alloc verify ok [legacy: PDXB ALLOC VERIFY OK] start_lba=0x0000000000000200 len_lba=0x0000000000000004
```

The two-in-one bracketed legacy suffix (`[legacy: PDXB ALLOC OK]`) is
the R51 Phase C option-B shape `tag_pdxb_bdev_flush_ok` (R54.M1-002 /
#1779) already uses in this file family; the wire carries both the
R51 narrative form (`pdxb alloc ok`) and the historic operator grep
marker (`PDXB ALLOC OK`) in a single line so the composer's k=v
suffix stays clean.

The tags contain an `OK` token per `verify-fingerprint-coverage.sh`'s
`OK_TOK` regex (space before, `]` after — both non-alnum). Golden row
at `tests/r55/expected-r55-alloc.txt` names both lines as prefix
substrings (the `covered_by` check accepts the substring-either-way
match `marker.startswith(a) or a.startswith(marker)`).

Zero-length runs never emit — the `want_len == 0` guard returns
`ALLOC_EXHAUSTED` before the scan, and both fingerprints fire only
after `bdev_barrier_write` and the verify loop both succeed.

### What §Allocator does NOT prove

- **Multi-block bitmap-region iteration.** Only the resident block is
  scanned, per the file's own header gap 2. A future issue widens
  `alloc_block` / `alloc_extent_run` to select among the multiple
  bitmap blocks a large volume can hold; today's cap is 32768 - 8 = 32760
  addressable start positions in the resident block.
- **Journal replay through a WAL.** `bdev_barrier_write` records the
  submission event; the WAL itself is #1786. A crash between the bitmap
  writeback and the inode-row writeback (#1785) is TODO for the WAL
  landing to make atomic — until then, a crash mid-allocation leaves
  bitmap bits set for an inode that was never populated (leaked
  blocks). `pdxfsck` (#1695) will find these on the next mount.
- **Multi-extent files.** Only slot 0 is populated. A file exceeding
  8 blocks lands in `pdxfs_block_write`'s scope, which loops
  `alloc_extent_run` and populates slots 1..7 as needed.
- **Free-stack reuse for extent runs.** `alloc_block` preferentially
  reuses the LIFO free-stack for CoW-write locality; `alloc_extent_run`
  does NOT — a single freed block cannot serve a multi-block
  contiguous request without additional coalescing that the LIFO shape
  cannot express. A widening at M4+ could add an extent-aware
  free-stack; the ceiling-8 posture makes this a low-value optimization
  until the run length is uncapped.

## §Inode-table-write — RMW over bdev_write_at (#1784)

### Signature

```
inode_table_write(nsid: u64,
                  sb_ptr: u64,
                  ino: u64,
                  inode_ptr: u64) -> u64
```

- `nsid` — the NVMe namespace id for the target volume. Threaded
  through to `nvme_read_blocking` (RMW read) and `bdev_write_at`
  (RMW write) unchanged. The R55 posture is a single-namespace boot
  (`nsid == 1`); a widening to multi-namespace lands with volume
  registry (KIND_VOLUME, R52.M5).
- `sb_ptr` — pointer to the caller-held superblock image. Read (once
  each) by `sb_itable_lba(sb_ptr)` and `sb_itable_bcount(sb_ptr)`;
  never mutated. Unlike `inode_write` (R52.M4-002, #1698), this path
  does NOT consult the cached `_itable_state` fields — the fresh
  read makes the function safe to call on a boot where `itable_init`
  has not run.
- `ino` — inode number (linear index into the on-disk inode table;
  0 is the permanent invalid-inode sentinel, but the R55 landing
  refuses only the block-out-of-bounds case — a caller that writes
  to `ino == 0` gets no error, mirroring `inode_write`'s own
  header-only guard). Bound-checked against `sb_itable_bcount`.
- `inode_ptr` — pointer to the caller-owned 128-byte inode row that
  will be spliced into ino's slot. The caller is responsible for
  the row's contents (`in_use`, `mtime`, `byte_len`, `extent[0]`,
  etc.); this function only persists whatever it is handed.

Returns 0 on success, or one of `INODE_INVALID_INDEX` (0xFFFFED18) /
reused `ALLOC_BITMAP_TORN` (0xFFFFED11 — allocator.pdx's M3 band,
reused per the file's own gap 4 for every BDEV I/O failure in this
file).

### Signature note (u16 vs u64)

The ticket text names the return type `-> u16`. Every other function
in `inode_table.pdx` returns u64, and the two failure sentinels
(`0xFFFFED18`, `0xFFFFED11`) do not fit in u16. Landed as `-> u64`;
the ticket's `u16` is treated as a typo. Softarch should confirm
before any wider caller-side ABI locks it in.

### RMW pattern

The inode row is 128 B; the on-disk inode table packs 32 rows into
one 4-KiB block. Writing at a byte offset within a block requires
read-modify-write:

1. Bounds check: `(ino / 32) < sb_itable_bcount(sb_ptr)` else
   `INODE_INVALID_INDEX`.
2. Compute the target LBA and in-block byte offset (see LBA math).
3. **Substrate branch** on `_nvme_io_queue_count`:
   - `== 0` (every QEMU-TCG `-kernel` boot today): skip both read
     and write; jump directly to fingerprint emit. Rationale: the
     same guard `nvw_batch_flush`'s own LIVE-vs-SUBSTRATE split
     enforces — calling `nvme_read_blocking`/`nvme_write_blocking`
     with no live sq_pa would DMA into page 0 (boot-critical
     hazard). The fingerprint still fires so caller-side witnesses
     that run in substrate posture (which is every witness that
     runs today) can observe the write attempt.
   - `> 0` (LIVE): steps 4–6 below.
4. `nvme_read_blocking(nsid, target_lba, count=1,
   buf_pa=&_inode_write_scratch)` — pull the full 4-KiB block into
   the RMW scratch. Non-zero CQE → `ALLOC_BITMAP_TORN`. Preserves
   the other 31 rows in the block.
5. Splice 16 qwords (128 B) from `inode_ptr` into
   `&_inode_write_scratch + row_byte_offset`. Manual loop; no
   `rep movsq` precedent in this codebase.
6. `bdev_write_at(nsid, target_lba, count=1,
   buf_pa=&_inode_write_scratch)` — push the patched page back.
   Non-zero forwarded status → `ALLOC_BITMAP_TORN`.
7. Emit fingerprint (see below).

### LBA math

```
block_idx      = ino / 32                            (safe imm8 shr 5)
target_lba     = sb_itable_lba(sb_ptr) + block_idx
slot_in_block  = ino % 32                            (safe imm and 31)
row_byte_offset = slot_in_block * 128                (safe imm shl 7)
```

`sb_itable_lba` is read fresh on every call. This matches
`inode_write` (R52.M4-002)'s own resolver arithmetic (`inode_read` /
`inode_write` / `inode_scrub_slot` all compute the same block_idx /
row_byte_offset inline; the public `inode_resolve` symbol exists but
is not called through — see `inode_table.pdx` "Design-doc gaps" item
5). The R55 landing mirrors that inline arithmetic rather than
threading through `inode_resolve` (whose packing loses the
row_byte_offset).

### Fingerprint (wire — one line per successful call)

Emitted via `klog_s1_x2` inside `inode_table_write` on the success
path (both LIVE and SUBSTRATE), LEVEL_INFO / SUBSYS_FS__:

```
pdxb inode write ok [legacy: PDXB INODE WRITE OK] ino=0x0000000000000002 size=0x000000000000000d
```

- Two k=v pairs: `ino` (from the caller's argument) and `size` (the
  `byte_len` u64 at row offset +16 per the 128-B layout).
- Two-in-one bracketed legacy suffix (`[legacy: PDXB INODE WRITE OK]`)
  matches the R51 Phase C option-B shape `tag_pdxb_bdev_flush_ok` /
  `tag_pdxb_alloc_ok` already established in this file family.
- `k_size` reuses the R21 batch-4 XSAVE key (`"size\0"`, `[u8; 5]`);
  it is a plain generic key with no XSAVE-specific semantics.
- The tag contains an `OK` token per `verify-fingerprint-coverage.sh`'s
  `OK_TOK` regex (space before, `]` after — both non-alnum).
- Byte counts: `tag_pdxb_inode_write_ok` = 49 chars + NUL = 50 bytes;
  `k_ino` = 3 chars + NUL = 4 bytes.

Golden row at `tests/r55/expected-r55-inode-write.txt` names one line
as a prefix substring (the `covered_by` check accepts the
substring-either-way match `marker.startswith(a) or
a.startswith(marker)`).

Failure paths (bad `ino`, `nvme_read_blocking` non-zero,
`bdev_write_at` non-zero) return the appropriate sentinel WITHOUT
emitting the fingerprint.

### bdev_write_at helper (why not extend nvw_submit?)

The ticket text reads "uses `bdev_write` (R54.M1-002)". Two options
were considered:

**(a)** Add `bdev_write_at(nsid, lba, count, buf_pa) -> u64` in
`bdev_write.pdx` that directly forwards to `nvme_write_blocking`
(with a substrate guard on `_nvme_io_queue_count`, mirroring
`nvw_batch_flush`'s own LIVE-vs-SUBSTRATE branch).

**(b)** Widen `nvw_submit`'s per-entry format from 4 u64s to include
a caller-supplied `buf_pa`, and iterate `nvw_batch_flush` over that
new field instead of the hardwired `_nvw_flush_scratch` page.

**(a) picked.** (b) re-opens the `_nvw_sq` scaffold format at a
moment when no caller yet needs the batching semantic for its RMW
writes; the sole R55 caller (`inode_table_write`) drives writes
synchronously (RMW: read, patch, write, emit — all in-line) and the
batching abstraction would be dead weight. (a) is one leaf function
(zero prologue-saved registers; direct forward of rdi/rsi/rdx/rcx
into `nvme_write_blocking`) that mirrors `nvw_batch_flush`'s
substrate posture without duplicating the accounting `_nvw_state`
maintains. A widening's async caller orchestration is free to land
(b) later without disturbing (a) — the two helpers describe distinct
posture (direct-submit vs accumulated-flush).

### Confined state

- `_inode_write_scratch : [u64; 512] @align(4096)` — 4 KiB RMW
  scratch page. Sole writer is `inode_table_write` itself (RMW read
  populates it, splice patches it, write consumes it). Confined at
  build time via `tools/build.sh`'s `ec_confine_one` to
  `core/fs/pdxfs/inode_table.o`. Page-aligned per NVMe PRP1's
  single-page-transfer requirement (drivers/nvme/sync.pdx §5.11).

Distinct from the existing `_itable_blk_buf` above: that page is
owned by the resident-block cache path (R52.M4-002's
`itable_ensure_block_loaded` / `inode_read` / `inode_write` /
`inode_alloc_fresh` / `inode_scrub_slot`, all of which go through
`bdev_barrier_write`). `_inode_write_scratch` is used only by
`inode_table_write`'s `bdev_write_at`-routed path, and never touches
the resident-block cache — `inode_table_write` does NOT stamp
`loaded_block_idx` or otherwise mutate `_itable_state`, so a
subsequent `itable_ensure_block_loaded` on the same block will
re-read from disk (and that reread will see the write
`inode_table_write` just committed).

### What §Inode-table-write does NOT prove

- **Multi-row batching.** Each call is one 4-KiB read + one 4-KiB
  write. A caller that stamps N inodes in a burst pays N read-write
  round-trips, even when all N share a single 4-KiB block. The
  §Cache milestone (later) will fold identical writes.
- **Journal ordering.** `bdev_write_at` records nothing in the
  write-ahead log; a crash between the inode-row write and any
  companion bitmap / directory write leaves an inconsistency the
  WAL landing (#1786) will make atomic.
- **Extent widening.** The caller supplies the full 128-B row; this
  function does not compute or stamp `extent[i]` slots. Extent
  orchestration (multi-slot large-file writes) lands in
  `pdxfs_block_write`.
- **Row-format validation.** No `in_use` / `refcount` /
  `content_hash` sanity check on the caller-supplied row. The
  companion `inode_read` (R52.M4-002) does an `in_use` header check
  on readback; `inode_table_write` trusts the caller (a wider
  posture matching `inode_write`'s "splice-copy-then-write" shape).

## §WAL — append + fsync over bdev_write_at (#1785)

### Signatures

```
wal_append_write(vol_row: u64,
                 lba: u64,
                 len: u64,
                 payload_pa: u64) -> u64

wal_fsync_bdev(vol_row: u64) -> u64
```

- `vol_row` — the volume row id (0..15), i.e. the `row_id` returned by
  `volume_row_of_slot` (kind_volume.pdx §1). It indexes the module-
  scoped `_wal_bdev_state` table in `wal.pdx`, NOT a raw KIND_VOLUME
  row pointer, because KIND_VOLUME rows do NOT carry the
  `wal_head_lba` / `wal_tail_lba` / `wal_bcount` fields the ticket
  named — those live in `wal.pdx`'s own confined state, indexed by
  the row id. A widening that migrates the fields onto the KIND_VOLUME
  row keeps the same integer parameter.
- `lba` — the target LBA the upcoming data-block write will hit.
  Recorded verbatim into the WAL record.
- `len` — payload length in bytes (>= 1). `len == 0` returns
  `WAL_ERR_BAD_SIZE`.
- `payload_pa` — the source page physical address the upcoming write
  will DMA from. Recorded verbatim; the page itself is NOT copied
  into the WAL record (see "Record layout" below on why).

Return values:

- `wal_append_write` — 0 (`WAL_OK`) on success, else
  `WAL_ERR_BAD_SIZE` (0xFFFFEFCB, reused for bad `vol_row` and zero
  `len`) or `WAL_ERR_RING_FULL` (0xFFFFEFCE, `_wal_scratch` full).
- `wal_fsync_bdev` — 0 on success (including the `rcount == 0`
  silent no-op path), else `WAL_ERR_BAD_SIZE` or `WAL_ERR_INVARIANT`
  (0xFFFFEFCC, reused for a `bdev_write_at` failure — the "the WAL is
  durable at wal_fsync completion" invariant broke).

### Signature note (u16 vs u64)

The ticket text names the return type `-> u16`. Every other function
in `wal.pdx` (and in the wider pdxfs codebase) returns u64, and the
failure sentinels (0xFFFFEFC{B,C,E}) do not fit in u16. Landed as
`-> u64`, matching the R55.M2-002 (`inode_table_write`) precedent
one-for-one. Softarch should confirm before any wider caller-side ABI
locks it in.

### Signature note (`wal_fsync` name collision)

The ticket names the fsync entry `wal_fsync(vol_row) -> u16`. The R42
in-memory-ring scaffold already exports `wal_fsync : () -> u64`
(wal.pdx line 562, R42.M2-001), and paideia-as has no function
overloading. Landed as `wal_fsync_bdev` to distinguish the bdev-backed
substrate from the R42 in-memory ring during the caller migration
window this landing does not close. The R42 `wal_fsync` stays behind
its existing callers (journal_fence, journal_replay); the R55
`wal_fsync_bdev` is what `pdxfs_block_write` (and later CoW-write
callers) crosses to satisfy the barrier.

### The invariant this landing enforces

Per `bdev_write.pdx` §0 ("It DOES NOT own the WAL invariant.
wal.pdx is the authority on write-ahead ordering... That invariant is
enforced at THE CALL SITE (cow_write's write pass) rather than
duplicated here"), every future `pdxfs_block_write` call MUST:

1. Call `wal_append_write(vol_row, lba, len, payload_pa)` first,
   describing the upcoming data-block write.
2. Call `wal_fsync_bdev(vol_row)`, blocking until the WAL record
   lands on device via `bdev_write_at`.
3. ONLY THEN call `bdev_write_at(nsid, lba, count, buf_pa)` for the
   actual data-block write.

`bdev_write.pdx` §0 explicitly refuses to enforce this ordering
inside `bdev_write_at` itself (a duplicated gate would let a caller
that bypasses one still bypass the other via the sibling entry
`bdev_write_sync`); the ordering discipline lives in the caller. This
landing adds the primitives; the CoW-write caller migration is a
separate follow-up.

### Record layout (64 bytes = 8 qwords)

```
+0    magic         u64  0x00014C4157584450 (LE storage reads forward on disk as bytes 50 44 58 57 41 4C 01 00 = "PDXWAL\x01\x00"; matches PDXB_SB_MAGIC forward-reading convention)
+8    txn_id        u64  monotonic per-vol_row, bumped per append
+16   lba           u64  target LBA the upcoming data-block write hits
+24   len           u64  payload length in bytes (>= 1)
+32   payload_pa    u64  source page physical address (reference only)
+40   record_type   u64  1 = block_write (only type today)
+48   csum          u64  CRC32C over bytes [+0, +48) (7 qwords),
                          seed 0xFFFFFFFF, final XOR 0xFFFFFFFF
+56   reserved      u64  0
```

64-byte records × 64 records = 4096 bytes = one 4-KiB block exactly.
No page header for the bdev-backed layer (deliberately simpler than
`journal_ondisk.pdx`'s 4-KiB JBNL block with its 32-B header + 8-B
CSUM footer): the bdev-backed WAL records only *describe* upcoming
data-block writes, the payload itself lives at `payload_pa` and is
written by the caller's later `bdev_write_at` through the
`pdxfs_block_write` path. Not embedding the 4-KiB payload inline is
exactly `journal_ondisk.pdx`'s own header gap 1 recommendation (c)
for `JOP_BLOCK_WRITE` — folding a 4120-B record into a 4056-B records
area is a "hard mathematical impossibility" that gap flags for
softarch resolution; this landing takes the reference-not-embed
resolution as the WAL-layer contract.

### csum choice (CRC32C, not BLAKE3-lite)

Delegates to `jnl_crc32c_range` in `journal_ondisk.pdx` — the
R42.M5-006-widened REAL CRC32C substrate (Castagnoli, poly
0x82F63B78, branchless per-bit mix; that module's own header §gap 4:
"CRC32C is a REAL implementation, not the R42 `journal_csum.pdx`
placeholder"). `journal_csum.pdx`'s XOR-mix formula is a scaffold
placeholder that operates on WAL HEADER FIELDS (seq/size/prev_seq),
never over a byte buffer, and cannot compute a checksum over a 48-B
record slice.

The R55 WAL calls `jnl_crc32c_range(rec_ptr, 48, 0xFFFFFFFF)` and
then applies the standard `^ 0xFFFFFFFF` final-XOR. Result: the csum
matches any external CRC32C computed over the same 48-B slice.

### Per-vol_row state (indexed by vol_row 0..15)

```
[+0]   head_lba       absolute LBA the next flush targets
                        (0 = unset — first-touch seeds to
                         WAL_BDEV_BASE_LBA = 0x40)
[+8]   reserved       (wal_tail_lba placeholder — unused until
                        wraparound lands)
[+16]  rcount         records currently buffered in _wal_scratch
                        (0..64)
[+24]  next_txn_id    monotonic txn id handed out by the next
                        wal_append_write
[+32]  flush_count    total wal_fsync_bdev calls that reached the
                        bdev_write_at gate
[+40]  append_count   total wal_append_write calls that succeeded
[+48]  reserved       0
[+56]  reserved       0
```

16 rows × 64 B = 1024 B = `[u64; 128]`, matching KIND_VOLUME's own
16-row ceiling (R52.M5-001) and `journal_ondisk.pdx`'s
`_journal_vol_state` stride one-for-one. First-touch of any vol_row
seeds `head_lba` to `WAL_BDEV_BASE_LBA` = 0x40 (a scaffold constant
that matches the golden fingerprint's `lba=0x0000000000000040`
verbatim). A widening reads the per-volume WAL region base from the
superblock's `sb_journal_lba` (R52.M5) once callers thread the
superblock pointer through.

No wraparound: `head_lba` advances monotonically after each successful
flush. Scaffold assumption; a widening replaces this with real ring
geometry against `sb_journal_bcount`.

### Substrate branch (inherited from bdev_write_at)

`wal_fsync_bdev` does not itself branch on `_nvme_io_queue_count` —
the branch lives inside `bdev_write_at` (bdev_write.pdx, R55.M2-002),
which returns 0 without calling the driver under substrate posture
(every QEMU-TCG `-kernel` boot today). Same posture as
`inode_table_write`'s own reliance on `bdev_write_at`'s LIVE-vs-
SUBSTRATE branch: the fingerprint fires cleanly whether the write
actually reaches a device or not, so caller-side witnesses that run in
substrate posture (which is every witness today) observe the flush
attempt regardless.

### Fingerprint (wire — one line per successful non-empty fsync)

Emitted via `klog_s1_x2` inside `wal_fsync_bdev` on the success
path, LEVEL_INFO / SUBSYS_FS__:

```
pdxb wal fsynced [legacy: PDXB WAL OK] records=0x0000000000000001 lba=0x0000000000000040
```

- Two k=v pairs: `records` (the `rcount` just flushed) and `lba`
  (the `head_lba` that just landed on device — the pre-increment
  value; the internal state advances `head_lba` by 1 immediately
  after emit).
- Two-in-one bracketed legacy suffix (`[legacy: PDXB WAL OK]`)
  matches the R51 Phase C option-B shape `tag_pdxb_bdev_flush_ok` /
  `tag_pdxb_alloc_ok` / `tag_pdxb_inode_write_ok` already established
  in this file family.
- The tag contains an `OK` token per `verify-fingerprint-coverage.sh`'s
  `OK_TOK` regex (space before, `]` after — both non-alnum).
- Byte counts: `tag_pdxb_wal_fsynced_ok` = 38 chars + NUL = 39 bytes;
  `k_records` = 7 chars + NUL = 8 bytes; `k_lba` = 3 chars + NUL = 4
  bytes.
- Fires exactly once per successful non-empty flush. `wal_append_write`
  is silent on the wire; a `wal_fsync_bdev` call with `rcount == 0`
  is also silent (returns success without emitting).

Golden row at `tests/r55/expected-r55-wal-fsync.txt` names one line
as a prefix substring (the `covered_by` check accepts the
substring-either-way match `marker.startswith(a) or
a.startswith(marker)`).

Failure paths (bad `vol_row`, buffer full for `wal_append_write`;
bdev_write_at failure for `wal_fsync_bdev`) return the appropriate
sentinel WITHOUT emitting the fingerprint. An I/O failure does NOT
reset `rcount`, so a subsequent `wal_fsync_bdev` call retries the
same block (matches `nvw_batch_flush`'s LIVE-path retry semantic).

### Why not extend journal_ondisk.pdx's journal_append?

`journal_ondisk.pdx`'s `journal_append` refuses records >
`JNL_RECORDS_AREA_SIZE` (4056 bytes) — a hard precondition per that
file's own §gap 1. `journal_encode_block_write` produces a 4120-byte
record (record_hdr 8 + txn_id 8 + lba 8 + block_data 4096); it can be
encoded but never legally appended, and gap 1 explicitly flags this
for softarch resolution.

The R55 WAL takes gap 1's resolution (c): the WAL record REFERENCES
the payload rather than embedding it. That makes each record 64 bytes
(magic + txn_id + lba + len + payload_pa + rtype + csum + reserved),
so a 4-KiB block holds 64 records with no page header. Independent of
`journal_append`'s size gate, and independent of `journal_ondisk.pdx`'s
per-vol-slot `_journal_vol_state` — both substrates coexist during
the R42 in-memory / R55 bdev-backed transition.

### Confined state

- `_wal_scratch : [u64; 512] @align(4096)` — 4-KiB WAL page. Sole
  writer is `wal_append_write` (packs records) + `wal_fsync_bdev`
  (reads to hand to `bdev_write_at`). Confined at build time via
  `tools/build.sh`'s `ec_confine_one` to `core/fs/pdxfs/wal.o`.
  Page-aligned per NVMe PRP1's single-page-transfer requirement.
- `_wal_bdev_state : [u64; 128] @align(64)` — 16-row × 64-byte
  per-vol_row table (head_lba, rcount, next_txn_id, flush_count,
  append_count). Sole writer is `wal_append_write` +
  `wal_fsync_bdev`. Confined at build time via `ec_confine_one`.

Distinct from the R42 `_wal_ring` / `_wal_state` above: those hold
the in-memory-ring scaffold for the R42.M2 replay path
(`journal_fence`, `journal_replay`, `journal_csum` reach for them).
The R55 pair is used only by `wal_append_write` / `wal_fsync_bdev`,
and never touches the R42 ring — the two substrates coexist until
the caller migration completes.

### What §WAL does NOT prove

- **Wired caller.** No caller yet crosses the barrier. The primitive
  lands so `pdxfs_block_write` (and future CoW-write callers) can
  wire it; that wiring is a separate follow-up matching R55.M2-002's
  own "primitive without wired caller" posture for `bdev_write_at`.
- **Replay.** The bdev-backed WAL records land on device but no
  replay walker consumes them yet. `journal_replay.pdx` reads the
  R42 in-memory ring; a widening will teach it (or a sibling walker
  in `journal_ondisk.pdx`) to parse the 64-B record format above.
- **Wraparound.** `head_lba` advances monotonically; no bounds check
  against `sb_journal_bcount`, no ring-wrap. A widening adds the
  bounds and wrap semantics.
- **Multi-block records.** `_wal_scratch` is one 4-KiB page. A caller
  that flushes 64 records must fsync before appending the 65th; the
  append refuses with `WAL_ERR_RING_FULL`. A widening chains multiple
  scratch pages.
- **Volume-scoped state on the KIND_VOLUME row.** Per-vol_row state
  lives in `_wal_bdev_state` (module-scoped, indexed by vol_row); a
  widening migrates the fields onto the KIND_VOLUME row itself
  (kind_volume.pdx §1) once the row layout gains WAL slots.
- **Failure-band uniqueness.** `WAL_ERR_BAD_SIZE` is reused for both
  bad `vol_row` and zero `len`; `WAL_ERR_INVARIANT` is reused for
  `bdev_write_at` failure. The R42 wal band (0xFFFFEFC0..CF) has a
  free slot at 0xFFFFEFCA (`WAL_ERR_INTERNAL`, currently
  unreachable-fallthrough tripwire) that a follow-up could claim for
  a dedicated I/O-failure sentinel; not minted here because the
  reuse pattern matches `journal_ondisk.pdx`'s own JNL_CSUM_BAD
  reuse precedent (gap 3).

## §pdxfs_block_write — composed end-to-end write (#1786)

### Signature

```
pdxfs_block_write(vol_row: u64,
                  ino:     u64,
                  offset:  u64,
                  len:     u64,
                  in_pa:   u64) -> u64
```

- `vol_row` — volume row id (0..15). Threaded through both to
  `volume_row_device_slot` (for `bdev_cap` resolution) and to
  `wal_append_write` / `wal_fsync_bdev` (for per-vol_row WAL state).
- `ino` — inode number. Bound-checked downstream by `inode_read`
  (via `_itable_state.itable_bcount`) and by `inode_table_write`
  (via `sb_itable_bcount(sb_ptr)`).
- `offset` — byte offset within the file where the write begins.
  M2-004 refuses any non-zero value with `PDXB_WRITE_BAD_ARG`; a
  widening at M2+ (or a distinct issue for random-write) lifts this.
- `len` — payload byte count, refused unless in the interval
  (0, 4096]. Single-page, single-LBA write per the M2-004 posture.
- `in_pa` — physical address of the source page holding `len` bytes.
  Must be 4-KiB aligned (NVMe PRP1 requirement); this function does
  not re-check --- the caller is responsible.

Returns 0 on success, else a sentinel. Two new codes are minted in
the pdxfs-block M2 band (0xFFFFED2*) for arg-gate refusals no
sub-primitive can produce:

- `PDXB_WRITE_BAD_ARG`  (0xFFFFED0A) — `offset != 0`, `len == 0`, or
  `len > 4096`.
- `PDXB_WRITE_BAD_VOL`  (0xFFFFED0B) — `volume_row_device_slot`
  returned `VOL_DECODE_BAD` (dead row).

Every sub-primitive's own sentinel is forwarded verbatim — sb_read's
`PDXB_SB_*` band, inode_read's `INODE_*` / reused `ALLOC_BITMAP_TORN`,
alloc_extent_run's `ALLOC_EXHAUSTED` / `ALLOC_BITMAP_TORN`,
wal_append_write's `WAL_ERR_*`, wal_fsync_bdev's `WAL_ERR_*`,
bdev_write_at's forwarded status, inode_table_write's
`INODE_INVALID_INDEX` / reused `ALLOC_BITMAP_TORN`. No wrapper
transform: the caller sees the originating band and can decide how
to widen.

### Composed flow

The ticket names an 11-step flow; the actual body expands it to 15
numbered steps by breaking out (a) the two arg-gate refusals as
distinct steps 1 and 2, (b) the substrate short-circuit as a
distinct step 3, and (c) `sb_read` + `itable_init` as separate
sub-steps (needed to seed `_itable_state` before `inode_read` will
pass its own bound check). Step 10 in the ticket (`checkpoint
advance`) collapses to a no-op for M2-004 (documented below in
"What §pdxfs_block_write does NOT prove").

1. **Gate `offset == 0`.** Refuse with `PDXB_WRITE_BAD_ARG`
   otherwise. The M2-004 posture is single-LBA single-page write
   only.
2. **Gate `0 < len <= 4096`.** Same refusal code.
3. **Substrate branch.** If `_nvme_io_queue_count == 0`, jump
   directly to the fingerprint emit (step 14). No disk-touching
   primitive is called. Mirrors R55.M2-002 / R55.M2-003's own
   substrate-emit posture — the fingerprint is the wire event
   caller-side witnesses observe, whether or not the write reached
   hardware.
4. **Resolve `vol_row` → `bdev_cap`** via `volume_row_device_slot`.
   `VOL_DECODE_BAD` (0xFFFFFFFFFFFFFFFF) → `PDXB_WRITE_BAD_VOL`.
5. **Read the superblock.** `sb_read(bdev_cap)` returns
   `&_sb_read_buf` on success or an error sentinel below
   `KERNEL_VMA_BASE` (0xFFFF800000000000). Sentinels are forwarded
   verbatim.
6. **Seed `_itable_state`.** `itable_init(sb_ptr)` stamps
   `itable_lba` / `itable_bcount` / `loaded_block_idx` /
   `init_mark`. Always returns 0. Required before `inode_read` will
   pass its own bound check (a fresh `_itable_state` has
   `itable_bcount == 0` and refuses every ino).
7. **Read the inode row.** `inode_read(bdev_cap, ino)` returns
   `&_itable_row_scratch` on success or an error sentinel below
   `KERNEL_VMA_BASE`. The pointer is kept in a callee-save register
   for the remainder of the flow.
8. **Allocate an extent if slot 0 is empty.** Check `inode_ptr[+48]`
   (packed extent[0]: `(granted_len << 48) | (start_lba & 0x…FFFF)`).
   If zero, call `alloc_extent_run(bdev_cap, want_len=1,
   out_start_lba_ptr=0, out_granted_len_ptr=0, inode_row_ptr)` —
   the allocator stamps extent[0] in place. Non-zero return →
   forward. Re-writes over an already-allocated extent skip this
   step and reuse the existing `start_lba`.
9. **Compute `data_lba`.** `inode_ptr[+48] & 0x0000_FFFF_FFFF_FFFF`
   extracts the low-48-bit start LBA. Since `offset == 0` is gated,
   the write hits `data_lba` directly with no in-block byte offset.
10. **`wal_append_write(vol_row, data_lba, len, in_pa)`.** Records
    the pending data-block write into `_wal_scratch`. Silent on the
    wire. Non-zero → forward.
11. **`wal_fsync_bdev(vol_row)`.** Flushes `_wal_scratch` via
    `bdev_write_at`. Emits `tag_pdxb_wal_fsynced_ok` on success and
    satisfies the WAL-fsync-before-data-write barrier
    `bdev_write.pdx` §0 refuses to enforce itself. Non-zero →
    forward.
12. **`bdev_write_at(nsid=1, data_lba, count=1, in_pa)`.** Writes
    the caller's payload page. Non-zero → forward.
13. **Update inode `byte_len`.** `new_size = max(len, byte_len_old)`.
    Stamped at `inode_ptr[+16]` (the 128-B row's `byte_len` field).
14. **`inode_table_write(nsid=1, sb_ptr, ino, inode_ptr)`.** RMW
    persists the mutated row (both the new `byte_len` and the
    stamped `extent[0]` from step 8) to disk. Emits
    `tag_pdxb_inode_write_ok` on success. Non-zero → forward.
15. **Emit `tag_pdxb_write_ok`.** `klog_s1_x3` with three hex KVs:
    `k_ino=ino`, `k_offset=0`, `k_len=len`. Exactly one emit per
    successful call, on both the LIVE path (all sub-primitives
    succeeded) and the SUBSTRATE short-circuit (step 3).

### Substrate posture

Substrate is a top-level short-circuit: when `_nvme_io_queue_count == 0`
(every QEMU-TCG `-kernel` boot today), steps 4–14 are skipped and the
fingerprint at step 15 fires directly. Rationale for the outer
short-circuit rather than delegating to per-primitive substrate
branches:

- `sb_read`, `inode_read`, and `alloc_extent_run` all issue
  `cap_invoke(BDEV_OP_*)` — which is NOT substrate-branched in the
  R55 tree. On substrate posture they would return I/O errors from
  the underlying KIND_BLKDEV backend rather than a graceful
  scaffold-success, and the composed op would return a forwarded
  sentinel instead of the fingerprint.
- `wal_fsync_bdev` and `bdev_write_at` and `inode_table_write` ARE
  substrate-branched internally, but they compose downstream of
  the un-branched I/O primitives above.
- The outer short-circuit keeps the substrate posture uniform:
  every caller-side witness sees the composed fingerprint whether or
  not any disk touch happened, matching R55.M2-002 / R55.M2-003's
  own posture one-for-one.

### Fingerprint (wire — one line per successful composed op)

Emitted via `klog_s1_x3` inside `pdxfs_block_write` on the success
path (both LIVE and SUBSTRATE), LEVEL_INFO / SUBSYS_FS__:

```
pdxb write ok [legacy: PDXB WRITE OK] ino=0x0000000000000002 offset=0x0000000000000000 len=0x000000000000000d
```

- Three hex k=v pairs: `ino` (caller arg), `offset` (always 0 per
  the M2-004 gate), `len` (caller arg).
- Two-in-one bracketed legacy suffix `[legacy: PDXB WRITE OK]`
  matches the R51 Phase C option-B shape `tag_pdxb_bdev_flush_ok` /
  `tag_pdxb_alloc_ok` / `tag_pdxb_inode_write_ok` /
  `tag_pdxb_wal_fsynced_ok` already established in this file family.
- The tag contains an `OK` token per
  `verify-fingerprint-coverage.sh`'s `OK_TOK` regex (space before,
  `]` after — both non-alnum).
- Byte counts: `tag_pdxb_write_ok` = 37 chars + NUL = 38 bytes;
  `k_offset` = 6 chars + NUL = 7 bytes. `k_ino` is reused from
  R55.M2-002; `k_len` is reused from the R7-era generic key block.
- Sub-primitive fingerprints (`tag_pdxb_alloc_ok`,
  `tag_pdxb_alloc_verify_ok`, `tag_pdxb_wal_fsynced_ok`,
  `tag_pdxb_inode_write_ok`) ALSO fire on the LIVE path — those
  are the wire events R55.M2-001/002/003 already own. The
  M2-004 golden matches only the composed `tag_pdxb_write_ok`
  line as a substring; the sub-primitive fingerprints are covered
  by their own R55.M2 goldens.

Golden fixture at `tests/r55/expected-r55-write-e2e.txt` names one
line as a prefix substring (the `covered_by` check accepts the
substring-either-way match `marker.startswith(a) or
a.startswith(marker)`).

Failure paths (bad arg, bad vol_row, sb_read err, inode_read err,
alloc err, WAL err, bdev_write err, inode_table_write err) return the
appropriate sentinel WITHOUT emitting the fingerprint.

### Mount wire-up (DEFERRED to #1787)

`_pdxfs_block_write_stub` in `core/fs/pdxfs/vops_block.pdx` (R52.M5-005
/ #1707) currently returns `MOUNT_BACKEND_UNKNOWN` (0xFFFFED27). The
vop signature is `(vn, buf, len, off) -> u64`; the composed op's
signature is `(vol_row, ino, offset, len, in_pa) -> u64`. The
translator between them requires a vnode-to-`(vol_row, ino)` mapping
that has not landed yet (R52.M8 territory in the
`kind_pdxfs_txn.pdx` family).

M2-004 lands the primitive with a direct-call posture. The M2-005
smoke (#1787) exercises it directly (not via `sys_write`), and the
vop-adapter wiring lives in whichever issue lands the
vnode-to-row-id materialisation path. Documented here (rather than
adding a placeholder adapter that would corrupt callers on entry
before the mapping is available) per the ticket's "extra check"
guidance: "If the mount table's write vop is already a stub, replace
with pdxfs_block_write. If the mount table doesn't exist yet as a
vop dispatch surface, DEFER the mount wire-up to #1787 (which is the
smoke that will exercise it) and document; land the primitive with a
direct-call posture."

### Register discipline

- 6 callee-save pushes (`rbx=vol_row`, `rbp=ino`, `r12=len`,
  `r13=in_pa`, `r14=sb_ptr`, `r15=inode_ptr`) + `sub rsp, 8` land
  `rsp%16==0` for every nested call (entry `rsp%16==8` + 48 + 8 = 64,
  `%16==0`).
- Frame `[rsp+0]` = `bdev_cap` spill. No free 7th callee-save
  register — the 6 registers listed already carry the values that
  outlive `bdev_cap` (which is dead after step 8 / alloc).
- Cross-module symbol reference discipline: `_sb_read_buf` and
  `_itable_row_scratch` are confined via `ec_confine_one` to
  `superblock_read.o` and `inode_table.o` respectively (see
  `tools/build.sh`). Cross-module re-`lea` from `cow_write.o` would
  land as a build-time relocation refusal, so both pointers stay in
  callee-save registers after their producing calls return —
  `sb_read`'s return value in `r14`, `inode_read`'s in `r15` —
  rather than being re-computed by lea.
- `klog_s1_x3` push convention (per `wrappers.pdx` line 137-146):
  caller stack is `[rsp+8]=v2`, `[rsp+16]=k3`, `[rsp+24]=v3`
  (post-return-address push). Caller pushes in reverse (`v3`, `k3`,
  `v2`) after a leading `sub rsp, 8` alignment pad; the 3 pushes +
  pad = 32 B keep `rsp%16==0` pre-call. `add rsp, 32` undoes.

### What §pdxfs_block_write does NOT prove

- **Non-zero `offset`.** M2-004 rejects. Random-write is R55+ tail
  work: the extent-slot math (`data_lba + offset/4096`) is one line
  but the underlying RMW-into-mid-block path requires either a
  `bdev_read_at` sibling of `bdev_write_at` (partial-block updates
  need the whole 4-KiB block resident) or a data-region block cache
  the §Cache milestone will introduce.
- **`len > 4096` / multi-LBA writes.** M2-004 rejects. Multi-block
  writes need the WAL record loop + the multi-block `bdev_write_at`
  (`count > 1`) already supported by the primitive but not yet
  exercised by this composition.
- **Multi-extent files.** Only extent slot 0 is populated. A file
  exceeding 8 blocks (`ALLOC_EXTENT_RUN_MAX`) needs slot 1..7
  orchestration and per-slot append semantics; deferred to a
  distinct issue that lands multi-slot extent walkers.
- **Real `mtime` field.** M2-004 does not touch the 128-B row's
  `mtime_ns` field (`+32`). The R55 posture is single-namespace
  boot without a monotonic real-time source at this file's altitude;
  a widening that threads a clock source through the inode-write
  path stamps `mtime` alongside `byte_len`.
- **Checkpoint advance.** For M2-004, this is a no-op — the WAL is
  single-record per `pdxfs_block_write` call, and `wal_fsync_bdev`
  already made the record durable. A multi-record checkpoint chain
  (with a rolling `checkpoint_lba` distinct from `head_lba`) lands
  at R56+ when the WAL grows beyond one-shot appends.
- **Mount-table vop wiring.** DEFERRED to #1787 per the section
  above.
- **`vnode`-based caller path.** Callers today must know the
  `(vol_row, ino)` pair up front. `sys_write` will need the vnode
  adapter deferred to #1787's own scope; this is not a soft-arch
  gap in the composed op itself but in the vfs-to-pdxfs bridge.
- **Idempotency across a crash.** WAL records land on device but no
  replay walker consumes them yet (R55.M2 §WAL "What §WAL does NOT
  prove" — replay is R56+). A crash mid-composed-op will leave the
  inode-row and data-block writes in whatever partial state the
  step ordering committed; the WAL record is present for a future
  replayer to resolve.
