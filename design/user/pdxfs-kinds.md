# PdxFS v1 — Kernel-Kind Coverage Audit

**Status.** Living document.  Opened at R48b substrate-prep (#1625) as
the presence audit of the R42 PdxFS substrate that the R49/R50 tools
depend on.  Amended whenever a new kind lands over the FS layer.

**Scope.** Enumerates every capability kind that the userspace R49/R50
tools (`pkg`, `cp`, `mv`, `rm`, `edit`, `cat`, `ls`, snapshot suite)
will ask the kernel for authority to touch.  For each kind: whether it
is landed, which module owns it, and if it is missing what the
follow-up issue name should be.

Sibling documents:

* `design/architecture/next-wave-derived-kinds.md` — the master
  derived-kind catalog (this doc is a filtered view scoped to PdxFS).
* `design/user/model.md` — the identity + authority model whose files
  the PdxFS kinds are the substrate for.
* `design/tooling/r49-r50-plan.md` — the R49/R50 tool plan whose per-
  tool substrate requirements this audit closes off.

---

## 1  R42 substrate presence audit

The R42 milestones (M1–M5) landed the CoW walker + journal + snapshot
+ nvme-write path in `src/kernel/core/fs/pdxfs/`.  As of R48b the
following modules are present and wired:

| R42 milestone | Purpose                              | Module                                                        | Issue         |
|:--------------|:-------------------------------------|:--------------------------------------------------------------|:--------------|
| M1-001        | CoW per-block refcount table         | `core/fs/pdxfs/refcount.pdx`                                  | #1380         |
| M1-002        | CoW read path (snapshot chain walk)  | `core/fs/pdxfs/cow_read.pdx`                                  | #1381         |
| M1-003        | CoW write path (allocate + link)     | `core/fs/pdxfs/cow_write.pdx`                                 | #1382         |
| M1-004        | CoW garbage-collection pass          | `core/fs/pdxfs/cow_gc.pdx`                                    | #1383         |
| M2-001        | Write-ahead log                      | `core/fs/pdxfs/wal.pdx`                                       | #1384         |
| M2-002        | Journal commit + fence primitives    | `core/fs/pdxfs/journal_fence.pdx`                             | #1385         |
| M2-003        | Journal replay on mount              | `core/fs/pdxfs/journal_replay.pdx`                            | #1386         |
| M2-004        | CRC32C checksum + tear detection     | `core/fs/pdxfs/journal_csum.pdx`                              | #1387         |
| M3-001        | Snapshot create + name registry      | `core/fs/pdxfs/snap_create.pdx`                               | #1388         |
| M3-002        | Snapshot diff                        | `core/fs/pdxfs/snap_diff.pdx`                                 | #1389         |
| M3-003        | Snapshot read-only mount             | `core/fs/pdxfs/snap_mount_ro.pdx`                             | #1390         |
| M3-004        | Snapshot prune                       | `core/fs/pdxfs/snap_prune.pdx`                                | #1391         |
| M4-002        | Upgrade dry-run                      | `core/fs/pdxfs/upgrade_dryrun.pdx`                            | #1393         |
| M4-003        | PdxFS-lite read-only compat          | `core/fs/pdxfs/lite_reader.pdx`                               | #1394         |
| M4-004        | Upgrade to v1                        | `core/fs/pdxfs/upgrade_v1.pdx`                                | #1394         |
| M5-001        | NVMe write path integration          | `core/fs/pdxfs/nvme_write.pdx`                                | #1396         |
| M5-002        | Durability (fsync-analog + barrier)  | `core/fs/pdxfs/durability.pdx`                                | #1397         |

**Verdict.** The R42 substrate is *present-audited*: every M1..M5
milestone has a landed module in `src/kernel/core/fs/pdxfs/`, and each
module carries its own boot witness under `tests/kernel/fs/pdxfs/` or
its `§0` document tie-back.  Nothing is silently missing.

**Adjacent files** — outside `pdxfs/` proper but load-bearing for the
same substrate:

* `core/fs/vfs_open.pdx`, `vfs_close.pdx`, `vfs_read.pdx`,
  `vfs_write.pdx` — the VFS layer above the CoW walker.
* `core/fs/vnode_pool.pdx`, `vops.pdx` — vnode substrate.
* `core/fs/fd_table.pdx`, `fd_inherit.pdx`, `fd_cloexec.pdx` — file-
  descriptor table + inherit / cloexec semantics.
* `core/fs/mount.pdx`, `path.pdx`, `backend_registry.pdx` — mount table
  + path lookup + backend registration.
* `core/fs/pdxfs_lite/` and `core/fs/tmpfs/` — the two alternate
  backends the walker cohabits with.

---

## 2  Landed KIND_PDXFS_* coverage

| Kind                     | Value  | Base kind                 | Landed by | Module                                | Notes                                                                                              |
|:-------------------------|:-------|:--------------------------|:----------|:--------------------------------------|:---------------------------------------------------------------------------------------------------|
| `KIND_PDXFS_FILE`        | 0x195  | `KIND_MEMORY = 4`         | R48b (#1623) | `core/cap/kind_pdxfs_file.pdx`     | One file authority.  Row: `{inode_no, byte_len, mode_bits, created_ns, mtime_ns, refcount}`.       |
| `KIND_PDXFS_TXN`         | 0x196  | `KIND_MEMORY = 4`         | R48b (#1624) | `core/cap/kind_pdxfs_txn.pdx`      | One in-flight transaction — the grouping unit for pkg / cp / mv / rm.                              |

Both kinds derive over `KIND_MEMORY` for the same reason `KIND_DMA_
DOMAIN` (#1036) does: an FS object is a page-shaped thing whose reach
cannot widen beyond the parent's memory authority.  Row layouts, mint
gates, failure taxonomies, and witnesses are the module's §0 material.

---

## 3  Kinds the R49/R50 tools will need that are NOT yet landed

Enumerated so a future round can pick them up rather than rediscover
them.  Each entry is a *presence gap*, not a bug — the R49/R50 tool
plan explicitly lands them as they are needed, not up front.

### 3.1 Directory-shaped authority

**Need.** `ls`, `cd`, `mkdir`, `find` want a per-directory cap distinct
from the per-file cap so that a subtree can be shared without granting
authority over its parent.

**Proposal.** `KIND_PDXFS_DIR` derived over `KIND_PDXFS_FILE`.  A
directory *is* a file at the CoW walker's abstraction layer (kind=DIR
in the mode nibble), so this derivation is a *refinement*, not a new
tree.  Row inherits the parent's fields and adds `entry_count:u32`.
File a follow-up issue at R49.M1 opening (`R49: KIND_PDXFS_DIR
derivation over KIND_PDXFS_FILE`).

**Interim.** Tools may hold a plain `KIND_PDXFS_FILE` whose mode_bits
mark it as a directory, and inspect the mode via `PFF_OP_QUERY_MODE`.
This works for read-only enumeration; write operations that mutate the
entry table (`mkdir`, `rm -r`) need the refined kind.

### 3.2 Symlink authority

**Need.** `readlink`, `ln -s`, `cp -a` want a per-symlink cap so a
holder can dereference or replace the link without holding the target's
authority.

**Proposal.** `KIND_PDXFS_SYMLINK` derived over `KIND_PDXFS_FILE`.
Same shape as the DIR refinement, plus `target_path_id:u32` referring
to a name-store row.  Follow-up issue at R49.M2.

**Interim.** Tools may inspect the file-type nibble of a
`KIND_PDXFS_FILE`'s mode_bits.

### 3.3 Mount-scoped authority

**Need.** `mount`, `umount`, `df` want to name a mount without holding
authority over any file in it.

**Proposal.** `KIND_PDXFS_MOUNT` derived over `KIND_MEMORY`.  Row:
`{mount_id, root_inode_no, backend_id, flags}`.  Follow-up issue at
R50.M1 (mount management is out of scope for R49 tools which operate
on the currently-mounted root only).

**Interim.** The mount table `_mount_table` in `core/fs/mount.pdx` is
supervisor-only at R48b; tools have no path to it.

### 3.4 Snapshot-view authority

**Need.** `snap-view`, `snap-diff`, and every R50 tool that reads
through a specific snapshot generation want a cap that names one
snapshot rather than the whole snap registry.

**Proposal.** `KIND_PDXFS_SNAPSHOT` derived over `KIND_PDXFS_FILE`
(refinement: the snapshot's root inode is a KIND_PDXFS_FILE with the
snapshot's generation stamped in an extended tail).  Follow-up issue
at R50.M2.

**Interim.** `snap_mount_ro.pdx` (#1390) exposes a read-only mount of
one snapshot which appears at the VFS layer as a directory tree; tools
that want *view semantics* (as opposed to *mount semantics*) still need
the refined kind above.

### 3.5 Refcount-drop authority (kernel-side, no userspace equivalent)

The `refcount` field in `KIND_PDXFS_FILE`'s row is bumped/dropped by
the CoW walker (`cow_read.pdx`, `cow_write.pdx`) at page boundaries.
No userspace tool needs to hold authority to change it.  This is a
kernel-internal invariant, listed here only so a future audit does not
mistake the absence for a gap.

---

## 4  Discipline for landing a new PdxFS kind

When R49/R50 (or a later round) adds one of §3's kinds:

1. **Register the numeric tag** in `src/kernel/core/cap/kind.pdx`, in
   the R48b reserved band (`0x197`+).  Update
   `design/architecture/next-wave-derived-kinds.md` §"R48b substrate-
   prep" in the same commit.
2. **Land the module** under `src/kernel/core/cap/kind_pdxfs_<name>.pdx`
   with the standard set of primitives (`_table` + `_stats`, rights
   validator, tail alloc / valid / free, row accessors, mint walker,
   cap_revoke, cap_handler).
3. **Wire dispatch** in `core/cap/invoke.pdx` (`cmp rcx, <tag>; je
   call_kind_pdxfs_<name>`).
4. **Add chatter tag** in `core/cap/tags.pdx`.
5. **Bump `aud_kind_valid` upper bound** in
   `core/audit/audit_schema.pdx` if the new tag exceeds the current
   bound.
6. **Confine tables** in `tools/build.sh` (`ec_confine_one` on
   `_pdxfs_<name>_table` and `_stats`).
7. **Add witness** under `tests/kernel/cap/kind_pdxfs_<name>_synth.pdx`,
   wired into `src/kernel/boot/witness/r30_platform.pdx` and its
   fingerprint into `tests/r17/shell-shutdown.golden`.
8. **Update this document** with a row in §2 and a §3 subsection
   removal if the new kind fills a listed gap.

The R48b substrate-prep round (#1623..#1628) is the reference
implementation of steps 1–8; a new round can copy its shape.
