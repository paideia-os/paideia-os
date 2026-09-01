# PdxFS Syscall Surface — Consolidated Reference

**Round / issue:** R90-XREPO.010.M1-008 (paideia-os #2116).
**Parent:** R90-XREPO.010 substrate (#1996).
**Plan pointer:** `design/round-retrospectives/r90-xrepo-wave3-plan.md` §2.
**Round retrospective:** `design/round-retrospectives/r90-xrepo-010-substrate-live.md`.
**Companion docs (do not duplicate):**

- `design/user/syscall-table.md` — sysno registry (source of truth for
  the numbers, args, return semantics).
- `design/user/cwd-semantics.md` — the frozen relative-path anchor rule
  (Option A) every path-touching syscall obeys.
- `design/user/pdxfs-kinds.md` — capability-kind catalogue for
  `KIND_PDXFS_FILE`, `KIND_PDXFS_TXN`, `KIND_PDXFS_MOUNT_TABLE`.
- `design/kernel/pdxfs-fault-inject.md` — the deep dive on sysno 527
  (fault classes, boot flag, dispatch out-of-band cmp/je).
- `design/filesystem/pdxfs-lite-format.md` — the on-disk journal / WAL
  format the txn-lifecycle syscalls speak to.

---

## §1. Purpose

Single-page index of every PdxFS-adjacent syscall the paideia-os
kernel exposes at R90-XREPO.010 close, plus the one KIND_PDXFS_FILE
capability-invoke op (READ_BYTES) that landed in the same wave.
Consolidates the per-sub-issue design half of R90-XREPO.010.M1-001..
007 so a satellite tool consumer (cat, ls, cp, mv, rm, doc) can find
the full surface without walking eight commit messages.

Every entry gives: signature (kernel-side, after the dispatch shim's
SysV shuffle), return semantics, and the boot-witness fingerprint the
handler emits on the success path.

---

## §2. Surface at a glance

| # | Name | Introduced | Consumer role |
|---|------|-----------|---------------|
| 70 | `pdxfs_txn_open` | R42-PREP-007 | Open a WAL frame; returns KIND_PDXFS_TXN cap slot. |
| 71 | `pdxfs_open` | R42-PREP | Resolve `(vol_slot, path)` to a KIND_PDXFS_FILE cap. |
| 72 | `pdxfs_dir_readnext` | R42-PREP-008 + **R90-XREPO.010.M1-006** | Iterate directory entries. Stub → real body at .010.M1-006. |
| 77 | `stat` | R56.M3-001 | Path-based stat (via `path_resolve`). |
| 78 | `getdents` | R56.M3-001 | Directory dump. |
| 79..82 | `mkdir` / `rmdir` / `unlink` / `rename` | R56.M3-001 | Namespace mutations. |
| 104 | `pdxfs_txn_commit` | **R90-XREPO.010.M1-003** | Commit a KIND_PDXFS_TXN row (OPEN → COMMITTED). |
| 105 | `pdxfs_txn_abort` | **R90-XREPO.010.M1-003** | Abort a KIND_PDXFS_TXN row (OPEN → ABORTED); replay undo. |
| 106 | `pdxfs_stat_by_inode` | **R90-XREPO.010.M1-002** | 32-byte record: mode/size/mtime/ctime for an inode idx. |
| 107 | `pdxfs_undo_write` | **R90-XREPO.010.M1-004** | Stage a pre-image snapshot into the open txn's undo buffer. |
| 517 | `cwd_resolve` | **R90-XREPO.010.M1-007** | Realpath primitive; canonical absolute for the caller's cwd + path. |
| 527 | `pdxfs_fault_inject` | **R90-XREPO.010.M1-005** | Arm / disarm one PdxFS fault-injection class (test-only). |
| — | `cap_invoke(KIND_PDXFS_FILE, READ_BYTES=7)` | **R90-XREPO.010.M1-001** | Byte-range read via KIND_PDXFS_FILE (no new sysno). |

**Wave-added:** rows in **bold** landed in R90-XREPO.010 (#2109..
#2115); this doc consolidates them. The syscall numbers themselves
are the source of truth in `design/user/syscall-table.md` — this
table exists only to expose the PdxFS-shaped subset in one place.

---

## §3. Detailed entries — R90-XREPO.010 wave

### §3.1 KIND_PDXFS_FILE `PFF_OP_READ_BYTES` — cap-invoke op (no new sysno)

**Introduced by:** R90-XREPO.010.M1-001 (paideia-os #2109). Landed at
paideia-os `147c1da`.

**Contract (via `sys_cap_invoke` sysno 4):**

```
op_arg[7:0]   = PFF_OP_READ_BYTES = 7
op_arg[11:8]  = reserved (must be zero)
op_arg[63:12] = desc_page_addr (page-aligned physical address of the
                4-slot descriptor page)

Descriptor page (32 bytes at desc_page_addr):
  [+0]  u64 offset      -- byte offset into the file
  [+8]  u64 count       -- requested byte count
  [+16] u64 dst_ptr     -- destination buffer VA (caller's aspace)
  [+24] u64 dst_len_cap -- destination buffer capacity

Return (cap_invoke's ret): bytes_copied (0..count) or -errno.
Bounds are clamped against dst_len_cap AND file EOF; a caller
requesting past EOF gets bytes_copied == remaining_bytes with no
error. Rights required: R_PDXFS_FILE_READ (0x001).
```

**Fingerprint (emitted on every successful return, EOF included):**

```
pdxfs file read bytes ok [legacy: PDXFS FILE READ BYTES OK]
  off=<off> len=<bytes_copied>
```

`klog_s1_d2` under `SUBSYS_CAP_`, tag `tag_pdxfs_file_read_bytes_ok`
in `src/kernel/core/cap/kind_pdxfs_file.pdx`.

**Boot witness fingerprint:** `boot pdxfs read bytes ok -- ino=<n>
bytes=<n>` (`src/kernel/boot/witness/r90_xrepo_010_pdxfs_read_bytes.
pdx`; seeds a 4 KiB file, mints a KIND_PDXFS_FILE cap, invokes
READ_BYTES, byte-compares the returned buffer).

**Consumer.** Unblocks `doc.ENH-022` (`file_read_stub` → real read)
and lifts the last kernel-side constraint on `cat`. `sys_pdxfs_read`
(a sysno-shaped wrapper over this op) is *not* introduced by this
landing — consumers hold the KIND_PDXFS_FILE cap already (from sysno
71 `pdxfs_open`) and invoke `sys_cap_invoke` directly.

### §3.2 sysno 104 `sys_pdxfs_txn_commit`

**Introduced by:** R90-XREPO.010.M1-003 (paideia-os #2111). Landed at
paideia-os `147c1da`.

**Signature:** `sys_pdxfs_txn_commit(cap_slot: u64) -> u64`.

- `cap_slot` — KIND_PDXFS_TXN slot from `sys_pdxfs_txn_open` (sysno 70).
- Return: 0 on success, `-EBADF` on a bad cap slot, WAL / transition
  sentinels forwarded verbatim.

**Sequencing (body):** `pdxfs_txn_row_of_slot(cap_slot)` →
`pdxfs_txn_commit_wal(row_id)` writes `JOP_COMMIT` + `BD_OP_FLUSH`
via the mounted volume's KIND_BLOCK_DEVICE →
`pdxfs_txn_row_transition(row_id, OPEN → COMMITTED)` →
`PXT_ST_COMMITS++`.

**Deferred at this landing:**
- Per-record undo replay is **not** run on commit (undo replay only
  runs on abort — sysno 105).
- Row release + cap-slot clear are **not** done here — a future
  `sys_pdxfs_txn_close` (see `design/round-retrospectives/r90-xrepo-
  010-substrate-live.md` §7) drops the row + clears the slot.

**Fingerprint:** `sys pdxfs txn commit ok [legacy: SYS PDXFS TXN
COMMIT OK] txn=<row>` (`tag_sys_pdxfs_txn_commit_ok`).

### §3.3 sysno 105 `sys_pdxfs_txn_abort`

**Introduced by:** R90-XREPO.010.M1-003 (paideia-os #2111). Landed at
paideia-os `147c1da`; undo-replay wire-up landed at `24bed63` under
R90-XREPO.010.M1-004.

**Signature:** `sys_pdxfs_txn_abort(cap_slot: u64) -> u64`. Same
sentinels as commit.

**Sequencing (body):** row-resolve → `pdxfs_txn_abort_wal(row_id)`
writes `JOP_ABORT` → **`pdxfs_txn_undo_replay(row_id)`** replays every
undo record in the row's buffer **in REVERSE order** (last-in / first-
out; the ordering the I5 invariant requires) → row transition OPEN →
ABORTED → `PXT_ST_ABORTS++`.

**Fingerprints:**
- `sys pdxfs txn abort ok [legacy: SYS PDXFS TXN ABORT OK] txn=<row>`
  (`tag_sys_pdxfs_txn_abort_ok`).
- `sys pdxfs undo replay ok [legacy: SYS PDXFS UNDO REPLAY OK]
  txn=<row> entries=<n>` (`tag_sys_pdxfs_undo_replay_ok`) — one
  emission per abort even when `entries == 0`.

### §3.4 sysno 106 `sys_pdxfs_stat_by_inode`

**Introduced by:** R90-XREPO.010.M1-002 (paideia-os #2110). Landed at
paideia-os `24bed63`.

**Signature:** `sys_pdxfs_stat_by_inode(inode_no: u64, out_stat_ptr:
u64) -> u64`. Fills a 32-byte record at `out_stat_ptr`:

```
[+0]  u64 mode_bits    -- S_IFREG|0o644 (0x81A4) for REG; S_IFDIR|0o755
                          (0x41ED) for DIR
[+8]  u64 size_bytes   -- tmpfs inode's live byte count
[+16] u64 mtime_ns     -- _tick_count * 10_000_000 (UEJ convention)
[+24] u64 ctime_ns     -- reserved zero at this landing
```

Errors: `-EFAULT` on bad `out_stat_ptr`; `-ENOENT` on OOR `inode_no`
or an unallocated tmpfs slot.

**Fingerprint:** `boot pdxfs stat ok -- ino=<n> size=<n>`
(`tag_boot_pdxfs_stat_ok`) at the witness; per-call handler emits
`sys pdxfs stat by inode ok [legacy: SYS PDXFS STAT BY INODE OK]`.

**ls -l column coverage.** Together with `sys_pdxfs_open` (71) and
`sys_pdxfs_dir_readnext` (72), this blocks three of the six columns
`ls -l` needs: mode / size / mtime. Owner / group / nlink await
future evolutions of the output record shape.

### §3.5 sysno 107 `sys_pdxfs_undo_write`

**Introduced by:** R90-XREPO.010.M1-004 (paideia-os #2112). Landed at
paideia-os `24bed63`.

**Signature (5-arg body; dispatch shim performs SysV shuffle + KPTI
bounce for `kbuf_ptr`):**

```
sys_pdxfs_undo_write(cap_slot: u64,
                     inode_no: u64,
                     offset:   u64,
                     len:      u64,
                     kbuf_ptr: u64) -> u64
```

- `cap_slot` — KIND_PDXFS_TXN slot; row must be OPEN.
- `inode_no` — target tmpfs inode idx (low 16 bits at M1).
- `[offset, offset+len)` — the byte range whose pre-image is
  snapshotted; `0 < len <= 4064`.
- `kbuf_ptr` — KERNEL VA of the pre-image bytes. For a user caller
  the dispatch shim performs the KPTI bounce into a bounded kernel
  scratch; a boot witness passes a `.rodata` pointer directly.

Errors: `-EBADF` (bad cap slot), `-EINVAL` (row not OPEN, or bad
`len`), `-ENOSPC` (per-row buffer or record cap exhausted).

**Substrate (`src/kernel/core/fs/pdxfs/undo.pdx`):** 4 KiB per-row
buffer, 32-record per-row cap, 16 rows (one per KIND_PDXFS_TXN row).
`.bss`-resident today; a widening that folds these records into the
PdxFS journal is **DEFERRED** (see §7 of the round retro).

**Fingerprints:**
- `sys pdxfs undo write ok [legacy: SYS PDXFS UNDO WRITE OK]
  txn=<row> len=<n>` (`tag_sys_pdxfs_undo_write_ok`).
- `boot pdxfs undo ok -- count=<n>` (`tag_boot_pdxfs_undo_ok`) at the
  witness (A → undo(A) → B → abort → assert content == A).

**Contract for cp / mv / rm consumers.** Call `sys_pdxfs_undo_write`
**BEFORE** each mutation (write / unlink / rename). Commit path: no
replay. Abort path: the substrate replays every staged record in
reverse order on `sys_pdxfs_txn_abort` (sysno 105) — no consumer
action required.

### §3.6 sysno 72 `sys_pdxfs_dir_readnext` — real body (was 3-entry stub)

**Introduced by:** R42-PREP-008 (#1630) as a 3-entry stub. Real
multi-entry body landed at R90-XREPO.010.M1-006 (paideia-os #2114) at
paideia-os `24bed63`.

**Contract unchanged from the stub landing:** call once per entry, u16
cursor advanced per row; returns `1` (entry filled), `0` (EOD), or a
negative errno. Entry layout unchanged (`{inode, kind, name_len,
name[..32]}` at the 128-byte record boundary).

**Real body (`src/kernel/core/cap/pdxfs_dir_iter.pdx`):** walks the
directory inode's tmpfs child chain via `first_child` + `next_sibling`
links, resetting the u16 cursor to `0xFFFF` on first EOD and emitting
the fingerprint once per EOD-first transition (EOD-silent path returns
0 without re-emit, so the ring cannot fill with `rows=0` lines on
trailing polls).

**Fingerprint:** `sys pdxfs readdir ok [legacy: SYS PDXFS READDIR OK]
rows=<n>` (`tag_sys_pdxfs_readdir_ok`) — emitted once per EOD-first
transition. The witness seeds 5 REG files in a fresh directory and
asserts the first-EOD `rows=5`.

**Consumer unblocks:** `cp -r`, directory-aware `ls`, and every
recursive-traversal consumer.

### §3.7 sysno 517 `sys_cwd_resolve`

**Introduced by:** R90-XREPO.010.M1-007 (paideia-os #2115). Design
half landed at paideia-os `13a279c` (frozen Option A in
`design/user/cwd-semantics.md`); body landed at `3219699`.

**Signature (dispatch shim performs KPTI bounce for both user
pointers; body takes KERNEL VAs):**

```
sys_cwd_resolve(path_ptr:    u64,
                abs_out_ptr: u64,
                abs_out_cap: u64) -> u64
```

- `path_ptr` — user or kernel VA of the input path (absolute or
  relative). NUL-terminated; `PATH_MAX = 256`.
- `abs_out_ptr`, `abs_out_cap` — user or kernel VA of the output
  buffer + capacity. The composed canonical absolute path is written
  NUL-terminated (up to `abs_out_cap` bytes total).

Return: strlen (excluding NUL) on success, `-errno` on failure.

Errors: `-ENOENT` (path does not resolve or no root mounted);
`-ERANGE` (composed path + NUL exceeds `abs_out_cap`, or the
parent-chain walk exceeds `SYS_CWD_RESOLVE_MAX_DEPTH = 32`);
`-EFAULT` (dispatch-shim only; either user pointer refused).

**Anchor rule:** relative paths resolve against
`[_current_tcb + TASK_OFF_CWD]` (+160), read fresh at entry —
uniform with every other path-touching syscall per `design/user/
cwd-semantics.md` §2 (Option A).

**Fingerprint:** `sys cwd resolve ok [legacy: SYS CWD RESOLVE OK]
len=<n>` (`tag_sys_cwd_resolve_ok`); witness rollup `boot cwd
resolve ok --` (`tag_boot_cwd_resolve_ok`).

**Witness status (OPEN — carried forward from #2115).** The body is
green (fingerprint `sys cwd resolve ok len=2` fires); the 3-scenario
witness (`r90_xrepo_010_007_cwd_resolve.pdx`) takes the SKIP branch
after scenario 1, so 1 of 3 scenarios actually runs. #2115 stays
OPEN pending witness fix — see the round retro §5 / §7 and the
paideia-os issue body for the follow-on scope.

### §3.8 sysno 527 `sys_pdxfs_fault_inject`

**Introduced by:** R90-XREPO.010.M1-005 (paideia-os #2113). Landed at
paideia-os `c32e9e1`. Full design in `design/kernel/pdxfs-fault-
inject.md`.

**Signature:** `sys_pdxfs_fault_inject(class: u64) -> u64`.
Class 0 disarms; classes 1..4 arm one of `WAL_WRITE_FAIL`,
`INODE_ALLOC_FAIL`, `EXTENT_ALLOC_FAIL`, `UNDO_APPEND_FAIL`. Every
arm is single-shot: consumed by the next traversal of the named site.

Errors: `-EPERM` when the boot flag `_pdxfs_fault_enabled` is 0
(release-build gate); `-EINVAL` when `class > 4`.

**Dispatch out-of-band.** 527 sits far above the linear
`cmp rdi, 107 / ja dispatch_enosys` bounds gate. The landing adds an
explicit early `cmp rdi, 527 / je dispatch_pdxfs_fault_inject`
BEFORE the bounds gate rather than widening the gate to 527 (which
would collapse 108..526 into fall-through). Same posture as sysno
517's dispatch — see `dispatch.pdx` §handler-block header for the
grouped commentary.

**Fingerprints:** `sys pdxfs fault inject armed class=<n>`,
`sys pdxfs fault fired class=<n>`, `boot pdxfs fault inject ok --
count=<n>`.

---

## §4. Sequencing recipe — cp / mv / rm's I5 invariant

The R90-XREPO.010 wave closes the I5 (undo-on-failure) invariant at
the syscall layer for cp / mv / rm. The full recipe:

```
1. txn = sys_pdxfs_txn_open(vol_slot, flags)                 -- sysno 70
2. FOR each mutation:
     a. sys_pdxfs_undo_write(txn, inode, off, len, snapshot) -- sysno 107
     b. <perform the mutation via the appropriate write path>
3a. success => sys_pdxfs_txn_commit(txn)                     -- sysno 104
3b. failure => sys_pdxfs_txn_abort(txn)                      -- sysno 105
     -- pdxfs_txn_undo_replay runs automatically in the abort body
```

`sys_pdxfs_fault_inject` (527) is available to test harnesses under
the `_pdxfs_fault_enabled` boot flag to force step (2b) or the
underlying WAL/inode-alloc failure inside step (3), so partial-txn
rollback proofs (`cp.ENH-002/003/007`, `mv.ENH-001`, `rm.ENH-005`)
can be authored without a real ENOSPC.

---

## §5. What this doc does NOT own

- The **syscall numbers** — `design/user/syscall-table.md` is the
  source of truth for `#`, args, and return semantics. This doc
  paraphrases; drift is a bug in this doc, not the table.
- The **fault-injection deep dive** — `design/kernel/pdxfs-fault-
  inject.md` owns the fault-class definitions, boot flag policy, and
  dispatch out-of-band commentary. §3.8 above is a summary pointer.
- The **cwd-anchor invariant** — `design/user/cwd-semantics.md` owns
  the Option-A freeze. §3.7 above is a summary pointer.
- The **PdxFS journal / on-disk format** — `design/filesystem/pdxfs-
  lite-format.md` owns the WAL frames the txn-lifecycle syscalls
  emit.
- The **kind catalogue** — `design/user/pdxfs-kinds.md` owns
  KIND_PDXFS_FILE / KIND_PDXFS_TXN / KIND_PDXFS_MOUNT_TABLE
  descriptor shapes and rights bitmasks.
