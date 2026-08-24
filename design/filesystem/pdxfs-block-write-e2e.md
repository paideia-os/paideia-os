---
issue: 1783
milestone: R55.M2 (pdxfs-block write path end-to-end)
subsystem: filesystem / pdxfs-on-block v1
topic: End-to-end write path for a fresh file on a pdxfs-block volume.
       This landing (§Allocator) proves the extent-run first-fit
       primitive that pdxfs_block_write (#1784) and its later siblings
       (inode-table-write #1785, WAL #1786) will thread together into
       the full write path.
touching:
  - src/kernel/core/fs/pdxfs/allocator.pdx      (extend: alloc_extent_run)
  - src/kernel/core/klog/keys.pdx               (extend: tag_pdxb_alloc_ok,
                                                 tag_pdxb_alloc_verify_ok,
                                                 k_start_lba, k_len_lba)
  - tests/r55/expected-r55-alloc.txt            (2-line spec golden)
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

1. **§Allocator** (this landing, R55.M2-001 / #1783) — reserve a
   contiguous run of data blocks and record the reservation on disk.
2. **§Inode-table-write** (#1785, forward) — populate the inode row
   with the reserved extent and durably write the row's bearer block.
3. **§WAL** (#1786, forward) — carry the row + bitmap changes through
   the write-ahead log so a crash between (1) and (2) either replays
   both or neither.
4. **§Cache** (later) — the block-cache handle that folds identical
   bitmap-block writes across a burst of allocations into one physical
   write.

Only §Allocator is landed in this doc's first cut. §Inode-table-write /
§WAL / §Cache sections are added by their own issues; the doc is the
composition point.

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
