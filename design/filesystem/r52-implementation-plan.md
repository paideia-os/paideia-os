# R52 — PdxFS-on-Block Implementation Sequence

**Status.** Sequencing plan (2026-08-22). Authored by softarch after `design/filesystem/volume-fs-substrate.md` (the R52 architecture) and `design/hardware/nvme-and-disk-substrate.md` (the R51 substrate this consumes).
**Scope.** How to land the 46 R52 issues (#1681–#1726) in commit-scale order, with the R51 dependency gates that unblock each milestone, the failure-band assignments per subsystem, the paideia-as arity/prologue hazards flagged per module, and the per-milestone witness plan.
**Non-scope.** Redesign of any surface in `volume-fs-substrate.md`. Where this document names a design choice, it is quoting or narrowing the substrate doc, not reopening it.

---

## 0. Reading order

- §1 issue → milestone map (46 issues across 8 milestones).
- §2 milestone-by-milestone implementation order: files landed, inter-module dependencies, arity/prologue hazards, LoC estimate, witness fingerprint.
- §3 R51 dependency matrix (what BDEV op each R52 milestone requires).
- §4 failure-taxonomy bands (disjoint per-subsystem sub-slices within `0xFFFFED00..0xFFFFED4F`).
- §5 paideia-as caveats consolidated (arity ≤ 6, prologue alignment, `mov_b`, no `test`, label prefixes).
- §6 build-order graph (what main can parallelise, what must serialise).
- §7 witness plan and golden-file layout under `tests/r52/`.
- §8 LoC estimates for main's build planning.
- §9 explicit non-goals for this round.

---

## 1. Issue → milestone map (all 46 issues)

Bucketing exactly matches `volume-fs-substrate.md` §7. Every open issue in `R52 in:title` (as of 2026-08-22) is placed.

| M | Subsystem | Issues | Count |
|:--|:----------|:-------|:------|
| M1 | Superblock format freeze + on-disk layout doc | #1681, #1682, #1683, #1684, #1685 | 5 |
| M2 | Superblock read/write + mkfs.pdxfs tool | #1686, #1687, #1688, #1689, #1690, #1691 | 6 |
| M3 | Block allocator (bitmap) + free-space tracking | #1692, #1693, #1694, #1695, #1696 | 5 |
| M4 | Inode table + inode lookup + KIND_INODE_HANDLE | #1697, #1698, #1699, #1700, #1701, #1702 | 6 |
| M5 | Journal WAL + recovery + KIND_VOLUME mount | #1703, #1704, #1705, #1706, #1707, #1708 | 6 |
| M6 | Wire KIND_PDXFS_TXN mutating ops through journal | #1709, #1710, #1711, #1712, #1713, #1714 | 6 |
| M7 | Block cache (read + write-back) + read-ahead | #1715, #1716, #1717, #1718, #1719, #1720 | 6 |
| M8 | Full round-trip smoke | #1721, #1722, #1723, #1724, #1725, #1726 | 6 |
| | **Total** | | **46** |

M1–M4 own the on-disk-format primitives (superblock, allocator, inode table). M5–M6 own the runtime (journal, mount, TXN wiring). M7 layers the cache. M8 is the round-trip integration.

---

## 2. Per-milestone implementation order

Each milestone lists: (a) the R51 gate that must land first; (b) the issue-by-issue order the modules land in; (c) the files new/edited; (d) arity/prologue hazards flagged per module; (e) the fingerprint the milestone closes with; (f) the LoC ballpark.

### 2.1 R52.M1 — Superblock format freeze + on-disk layout doc

**R51 gate.** None. M1 is entirely design + a passive accessor module with hard-coded test bytes. It compiles and witnesses against a static fixture (`hard-coded superblock bytes parse cleanly`); no BDEV op is invoked.

**Implementation order.**
1. #1681 — Freeze PDXB superblock at 4096 bytes (design.md delta only; append §2.1 offset table to `volume-fs-substrate.md` if any offset needs to move; this issue is a no-op on code).
2. #1682 — Land `src/kernel/core/fs/pdxfs/superblock.pdx`: per-field accessors for the 20 fields of §2.1 (`sb_magic`, `sb_version`, `sb_uuid_lo/hi`, `sb_block_size`, `sb_flags`, `sb_total_blocks`, `sb_itable_lba/bcount`, `sb_alloc_lba/bcount`, `sb_journal_lba/bcount`, `sb_data_lba/bcount`, `sb_root_inode`, `sb_mount_gen`, `sb_snap_head`, `sb_sig_key_hash_ptr`, `sb_reserved_scan`, `sb_sig_ptr`). Each accessor takes `(sb_block_ptr) → value`, arity 1. Also `sb_sign_scope(sb_ptr) → (start_off:0, end_off:696)` helper.
3. #1683 — Publish `design/filesystem/volume-fs-substrate.md` (already landed — this issue closes on the design cite).
4. #1684 — Cross-reference the PDXB layout from `design/filesystem/cow-design.md` and `design/filesystem/pdxfs-lite-format.md` (design edits only).
5. #1685 — Boot witness: `src/kernel/boot/witness/r52_platform.pdx` gains a `wit_superblock_parse` fixture with a hand-coded 4 KiB byte array laid out per §2.1, calls every accessor from #1682, prints `PDXB SB_PARSE ok magic=42584450 ver=1 root=1`. Fingerprint → `tests/r52/superblock-parse.golden`.

**Files new.** `src/kernel/core/fs/pdxfs/superblock.pdx`, `src/kernel/boot/witness/r52_platform.pdx` (this witness file grows across M1..M8; created here).
**Files edited.** `tools/build.sh` (`ec_confine_one` on `_sb_field_ptrs` if any is defined; likely no table at M1).
**Arity hazards.** None — every accessor is 1-arg. `sb_sign_scope` returns two values, so encode as a 16-bit packed rax (`(end << 32) | start`) rather than two rets.
**LoC.** ~250 (superblock.pdx) + ~120 (witness M1 chunk).
**Fingerprint.** `PDXB SB_PARSE …` in `tests/r52/superblock-parse.golden`.

### 2.2 R52.M2 — Superblock read/write + mkfs.pdxfs tool

**R51 gate.** BDEV_OP_READ_LBA + BDEV_OP_WRITE_LBA + BDEV_OP_FLUSH — i.e. **R51.M3 (NVMe I/O) + R51.M4 (FLUSH)** must be landed. Without WRITE + FLUSH the mkfs primitive cannot persist a superblock; without READ the probe cannot fetch LBA 0. Softarch's smoke against QEMU NVMe requires the unified `KIND_BLKDEV` op set from R51.M7 to be dispatchable, but the compat-shim path (R24 mint form) is sufficient for M2 — R51.M7 is optional here as long as R51.M3+M4 are in.

**paideia-as gate.** ML-DSA-65 **sign** intrinsic (see §5.4). This is the R52-wide blocker for M2: `superblock_write.pdx` cannot produce a valid `sig` field without it. If sign is not landed by M2 opening, file the paideia-as issue per `feedback_cross_repo_escalation` and hold M2-002 until it lands (M1 remains landable without it).

**Implementation order.**
1. #1686 — `superblock_read.pdx`: `sb_read(bdev_cap) → sb_block_ptr | err`. Issues `BDEV_OP_READ_LBA(0)`, checks `magic == 0x42584450`, `version == 1`, `block_size == 4096`, `_reserved` zero-scan; returns typed error else. Errors in band M2 (§4).
2. #1687 — `superblock_write.pdx`: `sb_write(bdev_cap, sb_ptr, sig_sk_ptr) → err`. Fills fields from a passed layout descriptor row; calls the paideia-as `mldsa65_sign` intrinsic over bytes `[0, 696)`; writes `sig` at offset 696; issues `BDEV_OP_WRITE_LBA(0)` then `BDEV_OP_FLUSH`.
3. #1688 — Userspace `mkfs.pdxfs` tool under `src/userspace/pkg/mkfs.pdxfs/`: takes a block-device cap arg, computes the region layout from `BDEV_OP_QUERY_GEOM` (see LoC note), zeroes the allocator bitmap region + journal region + inode table region, writes inode 0 (invalid sentinel) + inode 1 (root dir), calls `sb_write`. Arity note: layout compute takes 4 inputs (`total_blocks`, `block_size`, `inode_ratio`, `journal_size_hint`) — sits at 4 args, fine.
4. #1689 — `mkfs.pdxfs --upgrade`: reads the LBA 0, checks for `"PDXL"` magic (R25 lite-format), reads its region table, rewrites as PDXB at the same offsets with a fresh journal region carved from the tail. Same signing flow.
5. #1690 — Smoke: `mkfs → probe → mount refuses` (because M4 has not yet initialised the inode table's sig-tail signing; the refusal is by design at this milestone). Wired as a smoke expected-error case in `run-smoke.sh` (main runs this; softarch never invokes it — see the "no background builds" discipline).
6. #1691 — Boot witness: probe finds one PDXB volume; fingerprint the UUID and print `PDXB PROBE ok dev=0 uuid=… mount_gen=1`. Fingerprint → `tests/r52/mkfs-probe.golden`.

**Files new.** `src/kernel/core/fs/pdxfs/superblock_read.pdx`, `src/kernel/core/fs/pdxfs/superblock_write.pdx`, `src/userspace/pkg/mkfs.pdxfs/{cmd_mkfs.pdx, cmd_upgrade.pdx, layout.pdx, main.pdx}`.
**Files edited.** `src/kernel/boot/witness/r52_platform.pdx` (M2 chunk).
**Arity hazards.**
- `sb_write` takes `(bdev_cap, sb_ptr, sig_sk_ptr)` = 3. Fine.
- `layout_compute` for mkfs: 4 inputs. Fine.
- Inside `superblock_write`, the sign call takes `(msg_ptr, msg_len, sk_ptr, sig_out_ptr)` = 4. Fine.
- **Hazard flagged for later use in M5:** if a probe wants to summarise `(itable_lba, alloc_lba, journal_lba, data_lba, root_inode, mount_gen)` in one call it hits 6 args exactly. Recommend passing a "summary row pointer" (arity 1) even at M2 to future-proof M5's `volume_registry` insertion path.
**LoC.** ~350 (sb_read) + ~400 (sb_write) + ~600 (mkfs.pdxfs tool + upgrade) + ~150 (witness M2 chunk) = ~1500.
**Fingerprint.** `PDXB PROBE …` in `tests/r52/mkfs-probe.golden`.

### 2.3 R52.M3 — Block allocator (bitmap) + free-space tracking

**R51 gate.** R51.M3 (READ/WRITE). FLUSH is not strictly required in M3 (bitmap writes will be replayed from the journal at M5), but the allocator's persistent state does depend on FLUSH landing during actual mutation; M3 leaves persistence to the journal (M5) and does not itself issue FLUSH.

**Implementation order.**
1. #1692 — `allocator.pdx`: bitmap read/write/scan, `alloc_hint : u64`, LIFO free stack of size 16. Public ops: `alloc_block(vol_slot) → lba | err`, `free_block(vol_slot, lba) → err`, `alloc_scan_on_mount(vol_slot) → err`. Arity all 1–2. Cache the current bitmap block in a 4 KiB scratch buffer per volume; only one bitmap block loaded at a time (§5.1's block cache is not yet available; the allocator holds its own dedicated block until M7).
2. #1693 — `BITMAP_SET` / `BITMAP_CLEAR` WAL record encoders (op codes 4 and 5 per §2.4). Encoders live in the allocator module until the journal module lands at M5; then the encoders relocate to `journal_ondisk.pdx`. This deliberate double-move is cheaper than a forward-declaring shim.
3. #1694 — Allocator-scan-on-mount: at mount time, scan the whole allocator region (up to 8192 blocks for a 1 TiB volume), find the first zero bit, seed `alloc_hint` from it. This is called by the mount path at M5; landing the primitive at M3 keeps the smoke self-contained.
4. #1695 — `tools/pdxfsck` userspace tool: reads every inode's `root_block` and walks the CoW-tree references, comparing against the allocator bitmap. Reports mismatches (allocated-but-unreferenced, referenced-but-unallocated). Runs after mkfs in the M2 smoke to prove the empty volume is consistent.
5. #1696 — Boot witness: allocate 8 blocks, free 4, verify `alloc_hint` moved and the LIFO stack has 4 entries. Fingerprint → `tests/r52/alloc-free-hint.golden`.

**Files new.** `src/kernel/core/fs/pdxfs/allocator.pdx`, `src/userspace/pkg/pdxfsck/{cmd_pdxfsck.pdx, walk_inodes.pdx, verify_bitmap.pdx, main.pdx}`.
**Files edited.** `src/kernel/boot/witness/r52_platform.pdx` (M3 chunk), `tools/build.sh` (`ec_confine_one _allocator_stats`, `ec_confine_one _allocator_freestack`).
**Arity hazards.**
- `alloc_block(vol_slot) → lba` at 1 arg. Fine.
- **Free-stack push**: `free_stack_push(vol_slot, lba)` = 2. Fine.
- **BITMAP_SET encoder** takes `(txn_id, bit_no, journal_head_lba, journal_head_off)` = 4 for the encoder itself. Fine.
**LoC.** ~500 (allocator.pdx) + ~350 (pdxfsck) + ~150 (witness M3 chunk) = ~1000.
**Fingerprint.** `PDXB ALLOC hint=… free_stack=…` in `tests/r52/alloc-free-hint.golden`.

### 2.4 R52.M4 — Inode table + inode lookup + KIND_INODE_HANDLE

**R51 gate.** R51.M3 (READ/WRITE). Sig-tail verify at #1701 also requires BLAKE3-hash-32 in paideia-as (probably already present from R41; softarch to verify at M1 open — see §5.4).

**Implementation order.**
1. #1697 — Widen `KIND_PDXFS_FILE` row from 48 to 64 bytes. Add `volume_slot:u64` at +48 and `inode_lba:u64` at +56. Update `_pdxfs_file_table` bounds check + `tools/build.sh` `ec_confine_one`. Backward-compat: tmpfs callers write `0xFF, 0`.
2. #1698 — `inode_table.pdx`: `inode_read(vol_slot, inode_no) → inode_row_ptr | err`, `inode_write(vol_slot, inode_no, inode_row_ptr) → err`, `inode_alloc_fresh(vol_slot) → inode_no | err`, `inode_scrub_slot(vol_slot, inode_no) → err`. The 128-B inode row is passed by pointer; individual field accessors mirror the `pdxfs_file_row_*` discipline. **Big hazard here** — see arity hazards below.
3. #1699 — Register `KIND_INODE_HANDLE = 0x1A2`. Standard cap-primitives module `src/kernel/core/cap/kind_inode_handle.pdx`. Row tail: `{header, vol_slot:u32, inode_no:u64, inode_lba:u64, slot_in_block:u8, cached_gen:u16}`. This is a short-lifetime handle over the in-memory inode cache.
4. #1700 — `inode_no → (inode_lba, slot_in_block)` resolver: pure arithmetic on the superblock's `itable_lba` + slot math (`inode_no / 32 → block offset`, `inode_no % 32 → slot`). Returns packed u64.
5. #1701 — Sig-tail read: fetch signature block at inode's `sig_hash` referent (a per-inode signature block in the data region — the inode's `sig_prefix` [24 B] and `sig_hash` [32 B] identify it). BLAKE3-verify `sig_hash == blake3(sig_block)`; prefix-tear detect `sig_prefix == sig_block[0..24]`; ML-DSA-65 verify signature against inode-content bytes `[0, 72)` and the volume's `sig_key_hash` public key.
6. #1702 — Boot witness: mkfs-time root inode 1 fetches cleanly, then allocate inode 42 (via `inode_alloc_fresh`), verify both re-read cleanly with signatures. Fingerprint → `tests/r52/inode-fetch.golden`.

**Files new.** `src/kernel/core/fs/pdxfs/inode_table.pdx`, `src/kernel/core/fs/pdxfs/sig_verify.pdx`, `src/kernel/core/cap/kind_inode_handle.pdx`.
**Files edited.** `src/kernel/core/cap/kind_pdxfs_file.pdx` (row widening), `src/kernel/core/cap/kind.pdx` (KIND_INODE_HANDLE ordinal), `src/kernel/core/cap/invoke.pdx` (dispatch arm), `src/kernel/core/cap/tags.pdx`, `src/kernel/core/audit/audit_schema.pdx` (bump `aud_kind_valid` upper bound to 0x1A2), `tools/build.sh` (`ec_confine_one` on new tables), witness M4 chunk.
**Arity hazards (this milestone is where paideia-as arity ≤ 6 bites hardest).**
- **`inode_write` on the 128-B row.** A naive call `inode_write(vol_slot, inode_no, header, byte_len, mtime_ns, refcount, root_block, cow_gen, content_hash, sig_prefix_ptr, sig_hash_ptr)` = **11 args** — impossible. **Design up front:** pass a single `inode_row_ptr` into a stack-allocated 128-B scratch, arity 3 (`vol_slot, inode_no, row_ptr`). The caller populates the scratch via per-field setters, then `inode_write` transfers to disk. This mirrors `KIND_PDXFS_FILE`'s `pdxfs_file_row_*` accessor discipline.
- **`inode_alloc_fresh`** returning `(inode_no, inode_lba, slot_in_block)` = 3 values. Pack into u64: `(slot_in_block << 56) | (inode_no << 32) | inode_lba_low32` — but if lba exceeds 32 bits (>16 TiB volume) this shatters. Recommended: pass a scratch `alloc_result_ptr` as an output arg (arity 2), fill 24 B there. Enforces the row-pointer discipline everywhere.
- **Sig-tail verify** takes `(inode_row_ptr, sig_key_hash_ptr, sig_key_material_ptr, sig_block_ptr, out_verify_result_ptr)` = 5. Fits.
- **Resolver arity note.** `inode_no → (inode_lba, slot_in_block)` returns 2 values in one u64; safe because slot fits in 8 bits.
**Prologue-alignment note.** `inode_table.pdx` will have long functions with large stack frames (128-B scratch + up to 3 sig scratches × 3309 B each = 10 KiB stack). Prologues must reserve 16-byte-aligned frames explicitly; do not rely on the encoder for anything beyond 128 B.
**LoC.** ~600 (inode_table.pdx) + ~300 (sig_verify.pdx) + ~350 (kind_inode_handle.pdx) + ~100 (row widening delta) + ~200 (witness M4 chunk) = ~1550.
**Fingerprint.** `PDXB INODE …` in `tests/r52/inode-fetch.golden`.

### 2.5 R52.M5 — Journal WAL + recovery on mount + KIND_VOLUME mount

**R51 gate.** R51.M3 (READ/WRITE) + R51.M4 (FLUSH). Mount without FLUSH cannot uphold `JOP_COMMIT` durability. **R51.M7 (unified `KIND_BLKDEV`)** is strongly recommended here: probe iterates every live `KIND_BLKDEV`, and family-agnostic dispatch simplifies the probe walker. If R51.M7 slips, probe can fall back to iterating only NVMe namespaces (R51.M2) — a functional but narrower substrate.

**Implementation order.**
1. #1703 — Register `KIND_VOLUME = 0x1A0` and `KIND_SIG_KEY = 0x1A3`. Standard cap-primitives modules `src/kernel/core/cap/kind_volume.pdx` and `src/kernel/core/cap/kind_sig_key.pdx`. Volume row per §3.4: 16-row table. SigKey row per §6.4.
2. #1704 — `journal_ondisk.pdx`: JBNL block layout (§2.4) with record encoders for all 9 op codes (`JOP_BEGIN`, `JOP_BLOCK_WRITE`, `JOP_INODE_WRITE`, `JOP_BITMAP_SET`, `JOP_BITMAP_CLEAR`, `JOP_DENTRY_ADD`, `JOP_DENTRY_DEL`, `JOP_COMMIT`, `JOP_ABORT`). CRC32C helper reused from R42's `journal_csum.pdx`. Head pointer maintained in a per-volume `_journal_head[vol_slot]` field. Relocate the M3 BITMAP_SET/BITMAP_CLEAR encoders here.
3. #1705 — Rewrite `journal_replay.pdx` (currently a BSS-scaffold) to walk on-disk JBNL blocks per §4.3. Backward walk to `checkpoint`, forward-replay per record type, discard uncommitted txns.
4. #1706 — `volume_registry.pdx` (16-row table) + `probe.pdx` (iterate every live `KIND_BLKDEV`, `BD_OP_READ_LBA(0)`, magic gate, register). Probe is idempotent (see §3.1 of the substrate).
5. #1707 — Extend `mount.pdx` with `MOUNT_BACKEND_PDXFS_BLOCK = 5`. Populate `_pdxfs_block_vops` shape (mirrors `_tmpfs_vops`). Wire `backend_registry.pdx` dispatch arm `cmp rdi, 5; je bot_pdxfs_block`.
6. #1708 — Boot witness: mount root volume, replay 3 committed txns pre-planted in the QEMU image, verify checkpoint advances, verify clean-unmount flag toggles. Fingerprint → `tests/r52/mount-replay.golden`.

**Files new.** `src/kernel/core/fs/pdxfs/journal_ondisk.pdx`, `src/kernel/core/fs/pdxfs/volume_registry.pdx`, `src/kernel/core/fs/pdxfs/probe.pdx`, `src/kernel/core/cap/kind_volume.pdx`, `src/kernel/core/cap/kind_sig_key.pdx`.
**Files edited.** `src/kernel/core/cap/kind.pdx` (ordinals 0x1A0 and 0x1A3), `src/kernel/core/cap/invoke.pdx`, `src/kernel/core/cap/tags.pdx`, `src/kernel/core/audit/audit_schema.pdx` (bump `aud_kind_valid` to 0x1A3), `src/kernel/core/fs/mount.pdx`, `src/kernel/core/fs/backend_registry.pdx`, `src/kernel/core/fs/pdxfs/journal_replay.pdx` (rewrite), `src/kernel/core/fs/pdxfs/wal.pdx` (thin wrapper over journal_ondisk), `tools/build.sh` (confine every new `_*_table` / `_*_stats`), witness M5 chunk.
**Arity hazards.**
- **JOP_BLOCK_WRITE encoder.** `journal_encode_block_write(vol_slot, txn_id, lba, block_data_ptr, journal_head_ptr, csum_out_ptr)` = **6 args** — sits at the limit. Recommend collapsing `journal_head_ptr` and `csum_out_ptr` into a "journal writer ctx" (row pointer), arity 4.
- **JOP_DENTRY_ADD encoder.** `journal_encode_dentry_add(vol_slot, txn_id, dir_inode, name_ptr, name_len, target_inode)` = **6 args**. Same collapse.
- **Probe.** `probe_one_bdev(bdev_cap) → vol_slot | err`, arity 1. Fine.
- **Volume-row insert.** `volume_row_insert(uuid_ptr, device_slot, superblock_summary_ptr, mount_slot)` = 4. Fine.
- **Mount-table row.** Already 6-arg-borderline in R48b; do NOT extend its shape at M5.
**Prologue-alignment note.** Journal encoders build a 4088-B block scratch on the stack; enforce 16-byte alignment on every prologue.
**Label-prefix note.** Do not use `loop`, `if`, `else`, `while`, `wal`, `fs`, `mount` as bare labels. Use `journal_replay_forward`, `probe_check_magic`, `mount_arm_slot0`, etc.
**LoC.** ~700 (journal_ondisk) + ~600 (journal_replay rewrite) + ~400 (volume_registry) + ~350 (probe) + ~450 (kind_volume) + ~350 (kind_sig_key) + ~250 (mount.pdx + backend_registry deltas) + ~250 (witness M5 chunk) = ~3350.
**Fingerprint.** `PDXB MOUNT replay=3 checkpoint=…` in `tests/r52/mount-replay.golden`.

### 2.6 R52.M6 — Wire KIND_PDXFS_TXN mutating ops through journal

**R51 gate.** R51.M3 (WRITE) + R51.M4 (FLUSH). Every COMMIT calls FLUSH.

**Implementation order.**
1. #1709 — Rewrite `kind_pdxfs_txn.pdx` `PXT_OP_CREATE` handler: allocate fresh inode (M4), construct 128-B inode record, emit `JOP_INODE_WRITE` + `JOP_DENTRY_ADD` + `JOP_BITMAP_SET` if new inode-table block. Return `PXT_OK` (was `PXT_STUB_OK`).
2. #1710 — `PXT_OP_RENAME`: emit `JOP_DENTRY_DEL(old)` + `JOP_DENTRY_ADD(new)`. Both records share txn_id → atomic replay.
3. #1711 — `PXT_OP_UNLINK`: walk CoW tree of target inode, emit `JOP_BITMAP_CLEAR` for every block, `JOP_INODE_WRITE` with `in_use = 0`, `JOP_DENTRY_DEL` for the dir entry.
4. #1712 — `PXT_OP_COMMIT`: emit `JOP_COMMIT` + `BD_OP_FLUSH` + row transition OPEN → COMMITTED. State transition uses existing R48b `pdxfs_txn_row_transition`.
5. #1713 — `PXT_OP_ABORT`: emit `JOP_ABORT` + row transition OPEN → ABORTED (no data-region writes).
6. #1714 — Retire `PXT_STUB_OK = 0xFFFFEBFB` sentinel from `kind_pdxfs_txn.pdx`; update `libpdx-cap` decoders to fall through `PXT_OK` arm cleanly.

**Files edited.** `src/kernel/core/cap/kind_pdxfs_txn.pdx` (5 op-arm rewrites), `src/userspace/lib/libpdx-cap/decoders.pdx` (sentinel retirement), witness M6 chunk.
**Arity hazards.**
- **`PXT_OP_UNLINK` walker.** `unlink_walk_cow_tree(vol_slot, txn_id, inode_no, root_block, journal_ctx_ptr)` = 5. Fine.
- **`PXT_OP_CREATE` handler on entry** already receives its full arg list packed as a "op_arg" u64 per the existing cap dispatch — no arity growth on the handler surface. Internal calls to `journal_encode_*` are 4-arg per M5's collapse.
**Prologue-alignment note.** Every op arm calls into journal encoders whose stack frames are >4 KiB; the outer op arms must reserve their own 128-B inode scratch on top. Enforce prologue alignment explicitly.
**Fingerprint.** No new milestone-close witness — M6 closes on the M8 round-trip. But a per-op fingerprint line is added to `tests/r52/txn-wire.golden` (5 lines, one per op).
**LoC.** ~800 (kind_pdxfs_txn.pdx new op bodies) + ~50 (libpdx-cap decoders) + ~150 (witness M6 chunk) = ~1000.

### 2.7 R52.M7 — Block cache (read + write-back) + read-ahead

**R51 gate.** R51.M3 (READ/WRITE) + R51.M4 (FLUSH). Cache writeback tick issues `BD_OP_FLUSH` every 32 writes.

**Implementation order.**
1. #1715 — `block_cache.pdx`: 256-slot CLOCK cache per volume. Slot shape per §5.1: `{lba:u64, state:u8, gen:u16, refcount:u16, data[4096]}`. State enum: `CS_EMPTY=0`, `CS_CLEAN=1`, `CS_DIRTY=2`, `CS_WRITEBACK=3`, `CS_LOCKED=4`. Hand pointer walks slots; per-slot reference bit cleared on eviction sweep.
2. #1716 — Register `KIND_BLOCK_CACHE = 0x1A1` (supervisor-only). Standard cap-primitives module `src/kernel/core/cap/kind_block_cache.pdx`. Ops: `BC_OP_FLUSH`, `BC_OP_INVALIDATE`, `BC_OP_PIN`, `BC_OP_UNPIN`.
3. #1717 — Wire cache into `cow_read.pdx` + `cow_write.pdx`. Replaces the `nvme_write.pdx` BSS-ring scaffold. Read path: check cache → if miss, `BD_OP_READ_LBA` → install in slot → CS_CLEAN. Write path: install in slot → CS_DIRTY → writeback drains later. Note: journal blocks bypass the cache (write-through discipline per §5.3).
4. #1718 — Write-back tick + `BD_OP_FLUSH` cadence. A per-volume writeback thread drains CS_DIRTY slots at a low-priority tick; every 32 writes issue a `BD_OP_FLUSH`.
5. #1719 — Single-block-ahead prefetch on `BD_OP_READ_LBA`. If cache does not already hold LBA `N+1`, issue a low-priority prefetch. Non-blocking; the prefetch is dropped silently if cache is full.
6. #1720 — Boot witness: 1024-block sequential read against a mkfs'd volume, assert cache-hit ratio ≥ 0.75 (prefetch working). Fingerprint → `tests/r52/cache-hitratio.golden`.

**Files new.** `src/kernel/core/fs/pdxfs/block_cache.pdx`, `src/kernel/core/cap/kind_block_cache.pdx`.
**Files edited.** `src/kernel/core/cap/kind.pdx` (ordinal 0x1A1), `src/kernel/core/cap/invoke.pdx`, `src/kernel/core/cap/tags.pdx`, `src/kernel/core/audit/audit_schema.pdx` (bump to 0x1A3 covers this), `src/kernel/core/fs/pdxfs/cow_read.pdx`, `src/kernel/core/fs/pdxfs/cow_write.pdx`, `src/kernel/core/fs/pdxfs/nvme_write.pdx` (thin wrapper over block_cache), `tools/build.sh` (`ec_confine_one _block_cache_slots _block_cache_stats _block_cache_hand`), witness M7 chunk.
**Arity hazards.**
- **Cache slot ops** take `(vol_slot, slot_id, lba, state, gen, refcount)` = **6 args** if written naively. **Design up front:** every slot mutation goes through a `slot_ptr → set_state/set_gen/set_refcount` accessor discipline, arity 2 each. This is the same pattern as inode-row accessors.
- **`cache_get(vol_slot, lba, out_slot_ptr_ptr) → hit_or_miss:u8`.** Arity 3. Fine.
- **CLOCK hand advance** is per-cache global state (arity 1: `vol_slot`).
**Prologue-alignment note.** The cache slot is 4128 B (4096 data + 32 header) — do not put a slot on the stack; slots live in `_block_cache_slots[vol_slot][slot_id]` static storage.
**LoC.** ~700 (block_cache.pdx) + ~350 (kind_block_cache.pdx) + ~300 (cow_read/cow_write rewrite deltas) + ~200 (witness M7 chunk) = ~1550.
**Fingerprint.** `PDXB CACHE seq=1024 hits=… ratio=…` in `tests/r52/cache-hitratio.golden`.

### 2.8 R52.M8 — Full round-trip smoke

**R51 gate.** R51.M8 (full mount round-trip) or at minimum R51.M3 + R51.M4 for a QEMU-only smoke. The T14 G4 first-hardware witness (#R51.M8-006) is not a hard prerequisite for the R52 QEMU smoke but the two share the `tests/hw/` fingerprint discipline; land R52's own goldens under `tests/r52/`.

**Implementation order.**
1. #1721 — Extend `tools/run-smoke.sh` to `mkfs.pdxfs` on a QEMU-attached blank NVMe device (`-drive if=none,file=blank.img,id=d1 -device nvme,id=nvme1,drive=d1`). Main runs this — softarch never invokes run-smoke.sh (per "no background builds").
2. #1722 — Boot from that device, verify root mount succeeds, verify root inode readable.
3. #1723 — `pkg install pkg`: journaled write of every pkg file, followed by `PXT_OP_COMMIT`. Uses the M6-wired TXN path.
4. #1724 — Unmount cleanly: `checkpoint_advance` moves past every committed record, `flags` gets bit0 (clean-unmount) set.
5. #1725 — Reboot + remount + verify every pkg file is byte-identical to the pre-reboot content, verify per-inode signature.
6. #1726 — Fingerprint the round-trip in `tests/r52/round-trip.golden` (mirrors the R48b golden discipline).

**Files new.** `tests/r52/round-trip.golden` (and any per-milestone golden not yet landed), possibly `tests/r52/smoke.pdx` if the smoke wants its own witness beyond the run-smoke.sh output.
**Files edited.** `tools/run-smoke.sh` (main-only), witness M8 chunk.
**Arity hazards.** None new; every op invoked at M8 has been arity-vetted at M4/M6.
**LoC.** ~200 (run-smoke.sh delta — main lands this, softarch drafts) + ~300 (witness M8 chunk) + ~150 (goldens across M1..M8) = ~650.
**Fingerprint.** `PDXB ROUND_TRIP mkfs=ok mount=ok pkg=<n> reboot=ok bytes=match sig=verify` in `tests/r52/round-trip.golden`.

---

## 3. R51 dependency matrix

Every R52 milestone gates on one or more R51 milestones. Main uses this to know when to unblock a given R52 wave.

| R52 milestone | R51.M1 (NVMe ctrl) | R51.M2 (NVMe ns) | R51.M3 (READ/WRITE) | R51.M4 (FLUSH/TRIM/recovery) | R51.M5 (AHCI ctrl+port) | R51.M6 (AHCI R/W/FLUSH) | R51.M7 (unified BDEV) | R51.M8 (round-trip) | Non-R51 gate |
|:--------------|:------------------:|:----------------:|:-------------------:|:----------------------------:|:-----------------------:|:-----------------------:|:---------------------:|:-------------------:|:-------------|
| R52.M1 | — | — | — | — | — | — | — | — | — |
| R52.M2 | required | required | **required** | **required** | — | — | recommended | — | **paideia-as ML-DSA-65 sign** |
| R52.M3 | required | required | **required** | — | — | — | recommended | — | — |
| R52.M4 | required | required | **required** | — | — | — | recommended | — | paideia-as BLAKE3-hash-32 (verify present) |
| R52.M5 | required | required | **required** | **required** | — | — | **recommended** (probe simplicity) | — | R11 bootloader `root_volume_uuid` hint (optional, fallback via flag) |
| R52.M6 | required | required | **required** | **required** | — | — | recommended | — | — |
| R52.M7 | required | required | **required** | **required** | — | — | recommended | — | — |
| R52.M8 | required | required | **required** | **required** | optional (AHCI smoke) | optional | recommended | **recommended** | — |

Reading rules:
- **required** — R52 milestone will not compile / boot / pass its witness without this R51 milestone landing first.
- **recommended** — R52 will land but a smoke will be narrower or a fallback path will be exercised.
- **—** — no dependency.

The narrow path: **R51.M1..M4 unblocks R52.M2..M7**. R51.M5..M7 (AHCI + unified) is not on the critical path for R52's PdxFS bring-up; if AHCI slips, R52 boots on NVMe-only until AHCI lands. R51.M8 is co-scheduled with R52.M8 (both are the same "first real mount" event from opposite sides).

---

## 4. Failure-taxonomy bands

R52's user brief allocates `0xFFFFED00..0xFFFFEDFF` — but that band is already ~60 % occupied by kind_user, kind_pdxfs_file, cicp, eotf, vello_renderer, vello_scene, and adjacent modules (grep audit run 2026-08-22). R52's disjoint sub-slice within the ED band is the two contiguous free windows `ED00..ED2F` and `ED40..ED4F` — 64 codes total, comfortably fitting 8 milestones × 8 codes each.

**Per-milestone assignment:**

| M | Band | Reserved | Example error names |
|:--|:-----|:---------|:--------------------|
| M1 | `0xFFFFED00..0xFFFFED07` | 8 | `SB_MAGIC_BAD (ED00)`, `SB_VERSION_BAD (ED01)`, `SB_BLOCK_SIZE_BAD (ED02)`, `SB_RESERVED_NONZERO (ED03)`, `SB_TOTAL_BLOCKS_ZERO (ED04)`, `SB_REGION_OVERLAP (ED05)`, `SB_ROOT_INODE_INVALID (ED06)`, `SB_SIG_SCOPE_INVALID (ED07)` |
| M2 | `0xFFFFED08..0xFFFFED0F` | 8 | `SB_READ_BDEV_ERR (ED08)`, `SB_SIGN_FAIL (ED09)`, `SB_WRITE_BDEV_ERR (ED0A)`, `SB_FLUSH_FAIL (ED0B)`, `MKFS_LAYOUT_FAIL (ED0C)`, `MKFS_ZERO_FAIL (ED0D)`, `MKFS_UPGRADE_MAGIC_BAD (ED0E)`, `MKFS_UPGRADE_ROOM_SHORT (ED0F)` |
| M3 | `0xFFFFED10..0xFFFFED17` | 8 | `ALLOC_EXHAUSTED (ED10)`, `ALLOC_BITMAP_TORN (ED11)`, `ALLOC_HINT_STALE (ED12)`, `FREE_BAD_BIT (ED13)`, `FREE_DOUBLE (ED14)`, `FREE_STACK_FULL (ED15)`, `ALLOC_SCAN_UNTERMINATED (ED16)`, `FSCK_BITMAP_MISMATCH (ED17)` |
| M4 | `0xFFFFED18..0xFFFFED1F` | 8 | `INODE_INVALID_INDEX (ED18)`, `INODE_HEADER_INUSE_BAD (ED19)`, `INODE_ALLOC_FRESH_EXHAUSTED (ED1A)`, `INODE_TAIL_PREFIX_TEAR (ED1B)`, `INODE_TAIL_HASH_MISMATCH (ED1C)`, `INODE_SIG_VERIFY_FAIL (ED1D)`, `INODE_RESOLVER_LBA_OVERFLOW (ED1E)`, `INODE_SLOT_BOUNDS (ED1F)` |
| M5 | `0xFFFFED20..0xFFFFED27` | 8 | `JNL_MAGIC_BAD (ED20)`, `JNL_CSUM_BAD (ED21)`, `JNL_CHECKPOINT_BEYOND_HEAD (ED22)`, `JNL_SEQ_OUT_OF_ORDER (ED23)`, `VOL_MOUNT_KEY_MISMATCH (ED24)`, `VOL_REGISTRY_FULL (ED25)`, `MOUNT_ROOT_AMBIGUOUS (ED26)`, `MOUNT_BACKEND_UNKNOWN (ED27)` |
| M6 | `0xFFFFED28..0xFFFFED2F` | 8 | `TXN_CREATE_INODE_EXHAUSTED (ED28)`, `TXN_RENAME_NO_SRC (ED29)`, `TXN_RENAME_DEST_EXISTS (ED2A)`, `TXN_UNLINK_REFCOUNT_UNDERFLOW (ED2B)`, `TXN_UNLINK_COW_WALK_FAIL (ED2C)`, `TXN_COMMIT_JNL_FULL (ED2D)`, `TXN_COMMIT_FLUSH_FAIL (ED2E)`, `TXN_ABORT_STATE_BAD (ED2F)` |
| M7 | `0xFFFFED40..0xFFFFED47` | 8 | `CACHE_SLOT_EXHAUSTED (ED40)`, `CACHE_STATE_BAD (ED41)`, `CACHE_PIN_UNDERFLOW (ED42)`, `CACHE_INVALIDATE_DIRTY (ED43)`, `CACHE_WRITEBACK_FLUSH_FAIL (ED44)`, `PREFETCH_QUEUE_FULL (ED45)`, `PREFETCH_LBA_OOB (ED46)`, `CACHE_GEN_TORN (ED47)` |
| M8 | `0xFFFFED48..0xFFFFED4F` | 8 | `SMOKE_MKFS_FAIL (ED48)`, `SMOKE_MOUNT_FAIL (ED49)`, `SMOKE_PKG_INSTALL_FAIL (ED4A)`, `SMOKE_UNMOUNT_FAIL (ED4B)`, `SMOKE_REMOUNT_FAIL (ED4C)`, `SMOKE_BYTE_MISMATCH (ED4D)`, `SMOKE_SIG_VERIFY_FAIL (ED4E)`, `SMOKE_GOLDEN_MISMATCH (ED4F)` |

**Discipline.**
- Bands ED30..ED3F, ED50..ED9F, EDA0..EDBF, EDC0..EDFF are OWNED by prior modules — R52 code MUST NOT return anything in those bands. Enforced by grep at commit time (add to `tools/build.sh` audit if any R52 return lands outside its assigned band).
- Ordering discipline within a band: 000 = "most common expected error", higher = rarer. Callers can chart-strip on the leading nibble.
- Bands ED30..ED3F stay owned by `kind_user` + `kind_pdxfs_file`; R52 does not reuse them even though `KIND_PDXFS_FILE` is edited at M4 (the widening does not introduce new error codes).

---

## 5. paideia-as caveats consolidated

### 5.1 Arity ≤ 6 hazards (per-module inventory)

Every function that would exceed 6 args if written naively. Design the row-pointer collapse at the module's first landing rather than refactoring later.

| Module | Function | Naive arity | Fix |
|:-------|:---------|:------------|:----|
| `inode_table.pdx` | `inode_write` | 11 (vol, no, header, byte_len, mtime, refcount, root_block, cow_gen, content_hash, sig_prefix_ptr, sig_hash_ptr) | Row-pointer discipline: `(vol_slot, inode_no, row_ptr)` = 3. Callers stage the 128-B scratch and use per-field setters. |
| `inode_table.pdx` | `inode_alloc_fresh` return | Returns 3 values (inode_no, inode_lba, slot_in_block) | Output-arg pointer to a 24-B `alloc_result` scratch. |
| `journal_ondisk.pdx` | `journal_encode_block_write` | 6 (vol, txn, lba, data_ptr, head_ptr, csum_out_ptr) | Collapse `head_ptr` + `csum_out_ptr` into "journal writer ctx" row pointer. Arity 4. |
| `journal_ondisk.pdx` | `journal_encode_dentry_add` | 6 (vol, txn, dir_inode, name_ptr, name_len, target_inode) | Same ctx-row collapse. |
| `journal_ondisk.pdx` | `journal_encode_inode_write` | 5 (vol, txn, inode_no, inode_bytes_ptr, ctx_ptr) | Fits at 5 with ctx collapse. |
| `block_cache.pdx` | `cache_slot_mutate` | 6 (vol, slot_id, lba, state, gen, refcount) | Per-field accessors, arity 2 each; never mutate all fields in one call. |
| `probe.pdx` | `volume_row_populate` | Would be 6+ if superblock summary passed as fields | Pass `superblock_summary_ptr` (arity 2 total with vol_slot). |
| `superblock_write.pdx` | `sb_populate_fields` | Would be 14+ (one per field) | Pass a `layout_descriptor_ptr` and let `sb_populate_fields` walk it internally. Arity 2. |

**Rule of thumb applied throughout R52:** if a function even *approaches* 5 arguments, refactor to a row-pointer pattern at first landing. This matches the R48b/R48b-substrate-prep discipline in `KIND_PDXFS_FILE`'s `pdxfs_file_row_*` accessors.

### 5.2 Prologue alignment

Multiple R52 modules build stack scratches larger than 128 B:
- `inode_table.pdx`: 128-B inode scratch + potentially 3 × 3309-B sig scratches (~10 KiB).
- `journal_ondisk.pdx`: 4088-B block scratch per encoder invocation.
- `sig_verify.pdx`: 3309-B sig scratch + hash scratch.
- `mkfs.pdxfs`: 4 KiB region-init scratches.

Every such prologue MUST reserve a 16-byte-aligned frame explicitly (`sub rsp, N` where N is a multiple of 16, plus a canary if the module opts in). Do not rely on the encoder's implicit alignment for anything beyond a 128-B frame.

### 5.3 mov_b syntax, no test, label prefixes

- **`mov_b` syntax.** State-byte writes in `block_cache.pdx` (`slot_ptr[state_off] = CS_DIRTY`) MUST use `mov_b [rdi + N], AL` — never `mov [rdi + N], al` (paideia-as encodes the latter differently for some address forms). Same discipline for the inode `in_use` byte at offset 0.
- **No `test` instruction.** Bit checks in `sb_flags` and `inode.header` MUST use `and rax, MASK; jz` or `bt`, never `test rax, MASK; jz`. Every R52 module that reads a bit follows this.
- **Label-prefix discipline.** Do NOT use bare `loop`, `if`, `else`, `while`, `wal`, `fs`, `mount`, `journal`, `replay`, `commit`, `abort`, `probe`, `mkfs`, `cache`, `alloc`, `free` as labels. Prefix every label with its function name: `journal_replay_forward`, `cache_hand_advance`, `mkfs_zero_bitmap`, `alloc_scan_next_bit`. Failure to prefix is a mount-time / boot-time crash (parser accepts the keyword-shadowing label and generates wrong code).

### 5.4 Cross-repo paideia-as gaps

Two hard blockers, one soft.

1. **ML-DSA-65 sign** (`mldsa65_sign(msg_ptr, msg_len, sk_ptr, sig_out_ptr) → sig_len`). Required at **R52.M2** (superblock signing). Verify is present (R33-crypto-kdf); sign is the gap. **Action:** softarch to file the paideia-as issue per `feedback_cross_repo_escalation` at R52.M1 landing. If sign slips, M2-002 (superblock_write) waits; M1 remains landable.
2. **BLAKE3-hash-32** (`blake3_hash32(msg_ptr, msg_len, out_ptr) → ()`). Required at **R52.M4** (inode sig-hash) and **R52.M2** (volume sig_key_hash). Likely present from R41 semantic-terminal work — **softarch to verify at R52.M1 landing** with a targeted grep. If absent, file paideia-as issue immediately (M1 blocks by grep, not by build).
3. **sfence around MMIO** (soft; R51-side gap already flagged in that doc §8.3). R52 does not issue MMIO directly — it goes through BDEV_OP_*. If R51 lands `sfence` discipline in its BDEV path, R52 inherits it for free.

---

## 6. Build-order graph

**Serial spine (must land in this order):**
```
R52.M1 → R52.M2 → R52.M3 → R52.M4 → R52.M5 → R52.M6 → R52.M7 → R52.M8
```

**Parallelisable substacks (given the spine):**
- **M2's mkfs userspace tool (#1688, #1689) can develop in parallel with M2's superblock_read/write kernel modules** (#1686, #1687) once M1 lands. They share only the on-disk layout constants (already published at M1).
- **M3's `pdxfsck` (#1695) can develop in parallel with M3's allocator (#1692–#1694)** — pdxfsck reads the on-disk format, which is fixed at M1; it does not depend on the allocator's runtime state.
- **M4's `KIND_INODE_HANDLE` registration (#1699) can develop in parallel with M4's `inode_table.pdx` (#1698)** — the cap module is standalone cap-primitives; the inode-table module owns the on-disk work.
- **M5's `journal_ondisk.pdx` (#1704) and `journal_replay.pdx` (#1705) share the JBNL block layout; land the layout constants first (part of #1704), then the two modules develop in parallel.**
- **M5's `KIND_VOLUME` / `KIND_SIG_KEY` registrations (#1703) can develop in parallel with `probe.pdx` / `volume_registry.pdx` (#1706)** — the caps are standalone.
- **M6's five op-arm rewrites (#1709–#1713) are independent once M5's journal encoders exist; they can land as five separate PRs if main prefers granular commits.**
- **M7's `KIND_BLOCK_CACHE` registration (#1716) can develop in parallel with `block_cache.pdx` (#1715).**

**Explicit anti-parallelism:**
- Do NOT begin M2 before M1 has landed the superblock accessors — every mkfs field-write goes through them.
- Do NOT begin M4 before M3 has landed the allocator — inode_alloc_fresh needs bitmap read access.
- Do NOT begin M5 before M4 has landed the inode table — probe.pdx's sig-verify path reads inode 1 (root).
- Do NOT begin M6 before M5 has landed journal_ondisk.pdx — every TXN op-arm calls its encoders.
- Do NOT begin M7 before M6 — cow_read.pdx / cow_write.pdx rewrites depend on the TXN wire being real, not stubs (otherwise the cache would be tested against a scaffold and give misleading numbers).
- Do NOT begin M8 before M7 — the round-trip smoke depends on write-back cache flushes for durability.

---

## 7. Witness plan and golden-file layout

Per the "no R prefix per output-strip policy" note in the task brief, fingerprint lines use the `PDXB` prefix, not `R52`.

| Milestone | Witness function | Fingerprint prefix | Golden file |
|:----------|:-----------------|:-------------------|:------------|
| M1 | `wit_superblock_parse` | `PDXB SB_PARSE …` | `tests/r52/superblock-parse.golden` |
| M2 | `wit_mkfs_probe` | `PDXB PROBE …` | `tests/r52/mkfs-probe.golden` |
| M3 | `wit_alloc_free_hint` | `PDXB ALLOC …` | `tests/r52/alloc-free-hint.golden` |
| M4 | `wit_inode_fetch` | `PDXB INODE …` | `tests/r52/inode-fetch.golden` |
| M5 | `wit_mount_replay` | `PDXB MOUNT …` | `tests/r52/mount-replay.golden` |
| M6 | (per-op line inside wit_mount_replay round 2) | `PDXB TXN …` (5 lines) | `tests/r52/txn-wire.golden` |
| M7 | `wit_cache_hitratio` | `PDXB CACHE …` | `tests/r52/cache-hitratio.golden` |
| M8 | `wit_round_trip` | `PDXB ROUND_TRIP …` | `tests/r52/round-trip.golden` |

All witness functions live in `src/kernel/boot/witness/r52_platform.pdx` (a single file that grows per milestone). Each function is called from the platform bring-up sequence's witness pass, prints its fingerprint line to the boot chatter, and appends to its golden.

**Golden discipline.** Mirrors R48b's `tests/r17/shell-shutdown.golden` shape: one line per assertion, each line hash-stable (no timestamps, no wall-clock ordinals). `mount_gen` is stable-per-boot but the golden's line uses `mount_gen=<n>` with `<n>` masked to `mount_gen=N` after fingerprint strip (already the R48b convention).

---

## 8. LoC estimates for main's build planning

Rough per-milestone LoC, so main knows what a build will chew on:

| Milestone | New LoC | Edited LoC | Total |
|:----------|--------:|-----------:|------:|
| M1 | ~370 (superblock.pdx + witness) | ~30 (build.sh) | ~400 |
| M2 | ~1500 (sb_read/write + mkfs.pdxfs + upgrade + witness) | ~50 (kind.pdx, tags, build.sh) | ~1550 |
| M3 | ~1000 (allocator + pdxfsck + witness) | ~30 (build.sh) | ~1030 |
| M4 | ~1550 (inode_table + sig_verify + kind_inode_handle + witness) | ~200 (kind_pdxfs_file widening + invoke + tags + audit + build.sh) | ~1750 |
| M5 | ~3350 (journal_ondisk + journal_replay + volume_registry + probe + kind_volume + kind_sig_key + witness) | ~400 (mount.pdx + backend_registry + kind.pdx + audit + build.sh) | ~3750 |
| M6 | ~1000 (kind_pdxfs_txn op bodies + libpdx-cap + witness) | ~50 (build.sh) | ~1050 |
| M7 | ~1550 (block_cache + kind_block_cache + cow_read/cow_write deltas + witness) | ~100 (kind.pdx + invoke + build.sh) | ~1650 |
| M8 | ~650 (run-smoke.sh delta + witness + goldens) | ~50 (Makefile + smoke wiring) | ~700 |
| **Total** | **~11,000** | **~900** | **~11,900** |

Build-cost profile: M5 is the biggest single milestone (~3.7 KLoC — journal + mount + two new KINDs is a lot of cap-primitives boilerplate). M2 is second (~1.5 KLoC, mkfs is a real userspace tool). M4 and M7 sit around 1.7 KLoC. M1/M6/M8 are ~1 KLoC or under. Main can budget accordingly for build turnaround.

---

## 9. Explicit non-goals for this round

Reiterating the substrate doc §9 with the sequencing-plan lens: none of the following gets a milestone in R52, so main should not chase them if a bug seems to demand one.

- **mmap.** R56+.
- **Symlinks / hardlinks.** R53.
- **Extended attributes / ACLs.** R54+.
- **Quotas.** R55+.
- **Snapshot persistence.** R53 (walker exists at R42; superblock has `snap_head` reserved at §2.1).
- **Multi-volume mount via `sys_mount`.** R53 (root-only at R52).
- **ext4/FAT compat.** Never in-kernel.
- **Encryption at rest.** R54+ (needs `KIND_KEK`).
- **Compression.** R54+ (per-inode `compression_cap` attribute).
- **Multi-device pool (RAID).** R55+.
- **SMART / health-log surface.** Deferred at R51's §M8 already; picked up R52+ in its own round (not R52 itself).

---

## Appendix A — Issue → PR expectations

Each of the 46 issues closes in exactly one PR, matched by the "Closes #NNNN" discipline (`feedback_github_closing_keywords` — one keyword per issue, not comma-joined). Milestone-close PRs cite ALL issues in that milestone, one `Closes #NNNN.` per line.

The commit style follows `feedback_compact_commit_messages`: subject line ≤ 72 chars, minimal bullets, no narrative body.

Example M1-close commit shape:
```
R52.M1: superblock format freeze + parse witness

- superblock.pdx: 4096-B PDXB layout accessors (§2.1 of substrate)
- witness: hard-coded byte fixture parses cleanly
- fingerprint: PDXB SB_PARSE in tests/r52/superblock-parse.golden

Closes #1681.
Closes #1682.
Closes #1683.
Closes #1684.
Closes #1685.
```

## Appendix B — What softarch hands to main at each milestone-close

Per the "no background builds" discipline (`feedback_no_background_builds`): softarch produces code + design edits, main runs `bash tools/build.sh` and, on success, commits. If a build fails, main hands the failure tail back to softarch (or the debugger agent). This document does not reserve softarch runs of build.sh anywhere.

Milestone-close handoff to main includes:
- List of files new/edited (per §2 above).
- The witness fingerprint line the milestone is expected to produce.
- The failure-band sub-slice the milestone claimed (per §4).
- The R51 dependency the milestone required (per §3).
- Any paideia-as gap the milestone hit (per §5.4).
