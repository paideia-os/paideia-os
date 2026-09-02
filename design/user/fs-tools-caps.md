# fs-tools `caps.decl` Adoption Inventory

Round: R90-XREPO.013.M4-001 (paideia-os #2131). Companion of the
M0-001 kernel substrate (`src/kernel/core/cap/reconcile.pdx`) and the
M1-001 format design (`design/architecture/caps-decl-format.md`).

## 1. Scope

Three fs-admin tools ship with the `paideia-os` submodule set at
`tools/user/`:

- `mount.pdxfs` — mounts a formatted volume.
- `umount.pdxfs` — cleanly unmounts a mounted volume.
- `mkfs.pdxfs` — formats a raw block device or backing file.

Each already ships a rich prose `caps.decl` in its own repo (the R53
volume-tooling wave), authored in the freeform "consumed_kinds" style
that lists the KINDs the tool consumes and annotates each with the
milestone at which it was actually wired. The R90-XREPO.013.M4-001
adoption wave replaces those prose declarations with the
line-oriented grammar the M1-001 design ratifies, so the exec-time
reconciler can parse them mechanically.

**This document is design-only.** No source in `tools/user/` is
touched here. The concrete embed lands in each tool's own repo via a
per-tool follow-up ticket (see §4 below); this file is the round-side
inventory that (a) states each tool's declared cap-set in the new
format, (b) records the deferral to the tool-side ticket, and (c)
gives the M5-001 closeout audit the expected-vs-observed table.

## 2. Declared cap-sets (target `caps.decl` per tool)

Each block below is the *target* `caps.decl` for the named tool once
the M4-001 substrate lands and the tool-side ticket adopts the new
format. Mandatory (`!`) marks flow from each tool's minimum-viable
authority; optional rights flow from the M3-graded rights the tool
would exercise if held.

### 2.1 `mkfs.pdxfs`

```
# mkfs.pdxfs — formats a raw block device or backing file.
# Wave: R53 (design/tooling/volume-tooling-ux.md §2.1) +
#       R90-XREPO.013.M4-001 adoption.

!KIND_USER               0x001   # invoker attribution (audit)
!KIND_PDXFS_FILE         0x003   # READ + WRITE (file-backed target)
 KIND_BLKDEV             0x00F   # open+write+flush+query (device target)
 KIND_SIG_KEY            0x001   # superblock re-sign, placeholder seed
 KIND_IPC_ENDPOINT       0x001   # semantic-pipe stdout, deferred
```

Notes:
- `KIND_USER` and `KIND_PDXFS_FILE` are mandatory: mkfs cannot produce
  a valid superblock without invoker attribution and without a target
  to write.
- `KIND_BLKDEV` is optional because a file-target run never touches
  it. Device-target runs land under M3-005 (device-cap URI parsing)
  in mkfs.pdxfs's own repo; the exec-time narrow will trim the device
  cap out of the child's cap-set on a file-target invocation.
- `KIND_ELEVATE_CHANNEL` is deliberately **absent** — mkfs elevates
  on demand per the R90-XREPO.011 policy, never holds elevate at
  exec time. Matches the `rm` pattern the round plan §5 pins.

### 2.2 `mount.pdxfs`

```
# mount.pdxfs — mounts a formatted volume at a mount point.
# Wave: R53 (design/tooling/volume-tooling-ux.md §2.2) +
#       R90-XREPO.013.M4-001 adoption.

!KIND_USER                0x001   # invoker attribution (audit)
!KIND_VOLUME              0x003   # READ + INVOKE (mount narrow)
!KIND_PDXFS_MOUNT_TABLE   0x004   # APPEND_ROW after successful mount
 KIND_IPC_ENDPOINT        0x001   # semantic-pipe stdout, deferred
```

Notes:
- All three KINDs are mandatory: mount cannot proceed without an
  invoker identity, without a volume cap to mount, and without write
  authority on the mount-table row it will append.
- `KIND_ELEVATE_CHANNEL` is **absent** at exec time. `--force` on
  system paths (`/system/**`, `/boot/**`, `/dev/**`) triggers an
  on-demand elevate broker request per §4.2 of
  `design/tooling/volume-tooling-ux.md`; the elevate cap is never
  held ambiently.
- The KIND_VOLUME op-catalog gap (no `VOL_OP_MOUNT` ordinal, only
  `VOL_OP_QUERY_*`) does not affect the exec-time narrow — the decl
  reserves the rights band, the kind's op catalog can grow without a
  decl change.

### 2.3 `umount.pdxfs`

```
# umount.pdxfs — cleanly unmounts a mounted volume.
# Wave: R53 (design/tooling/volume-tooling-ux.md §2.3) +
#       R90-XREPO.013.M4-001 adoption.

!KIND_USER                0x001   # invoker attribution (audit)
!KIND_PDXFS_MOUNT_TABLE   0x006   # READ_ROW + LIST + (future) REMOVE_ROW
 KIND_VOLUME              0x00F   # flush+unmount (rights band, ops TBD)
 KIND_IPC_ENDPOINT        0x001   # semantic-pipe stdout, deferred
```

Notes:
- `KIND_USER` and `KIND_PDXFS_MOUNT_TABLE` are mandatory: umount must
  attribute audit and must be able to walk the mount table.
- `KIND_VOLUME` is *optional* because a `--dry-run` umount (target
  resolution only) never opens the volume; the real flush+unmount
  path (M2-003 in umount.pdxfs's own repo) does. The narrow keeps
  the cap out of dry-run child processes.
- Row-removal op (`PMT_OP_REMOVE_ROW`) is documented as a stub in
  the tool's own M2 landing; the decl reserves the rights band so
  the eventual op lands without a decl amendment.

## 3. Reconciliation-audit expectations

For each tool, the M5-001 closeout audit
(`design/round-retrospectives/r90-xrepo-013-closed.md` §Audit) will
run the tool under a parent process holding a *superset* of its
declared cap-set and record the post-reconciliation cap-set. Expected
vs. observed table (populated once tool adoption lands):

| Tool          | Parent-held kinds (superset)                                                  | Expected reconciled cap-set                                     |
|---------------|-------------------------------------------------------------------------------|-----------------------------------------------------------------|
| `mkfs.pdxfs`  | + `KIND_ELEVATE_CHANNEL`, + `KIND_TCP_SOCKET`                                 | 5 kinds as declared; elevate and tcp dropped                   |
| `mount.pdxfs` | + `KIND_ELEVATE_CHANNEL`, + `KIND_NIC`                                        | 4 kinds as declared; elevate and nic dropped                   |
| `umount.pdxfs`| + `KIND_ELEVATE_CHANNEL`, + `KIND_PDXFS_FILE`                                 | 4 kinds as declared; elevate and file dropped                  |

Each row asserts three properties: (a) all declared mandatory kinds
survive, (b) all declared optional kinds survive if the parent held
them, (c) every kind the parent held that the decl does not enumerate
is dropped.

## 4. Follow-up tickets (tool-side adoption)

The concrete `caps.decl` embed lands in each tool's own repo via
these tool-side tickets. They are filed at the same time this
inventory lands so the tool maintainers can pick them up:

| Ticket # | Repo                       | Title                                                            |
|----------|----------------------------|------------------------------------------------------------------|
| #23      | `paideia-os/mkfs.pdxfs`    | `Adopt R90-XREPO.013 caps.decl format (M4-001)`                  |
| #20      | `paideia-os/mount.pdxfs`   | `Adopt R90-XREPO.013 caps.decl format (M4-001)`                  |
| #20      | `paideia-os/umount.pdxfs`  | `Adopt R90-XREPO.013 caps.decl format (M4-001)`                  |

Each ticket references this document + `design/architecture/caps-decl-format.md`
for the format spec, and cites the M0-001 kernel substrate
(`src/kernel/core/cap/reconcile.pdx`) as the exec-time consumer.
Landing sequence: tool-side ticket lands the file, then updates its
`manifest.pdxsig` to list `caps.decl` as a signed input, then bumps
the tool's version.

## 5. Deferrals

- **KIND op-catalog gaps** (KIND_VOLUME missing `VOL_OP_MOUNT`,
  KIND_PDXFS_MOUNT_TABLE missing `REMOVE_ROW`) are noted in each
  tool's existing M2 caps.decl. The decl format reserves the rights
  band, so the op catalog can grow post-hoc without a decl amendment.
  Tracked in the round plan §5, not blocking on this adoption wave.
- **KIND_BLOCK_DEVICE vs. KIND_BLKDEV naming gap** (flagged in
  mkfs.pdxfs's own M1 caps.decl) is resolved in favor of the
  already-landed `KIND_BLKDEV = 0x42` per
  `design/hardware/nvme-ahci-tail-milestones.md` §3.1. The new decl
  uses `KIND_BLKDEV`.
- **KIND_SIG_KEY** stays declared (optional) at the decl level even
  though no code path binds one today: the field is a placeholder
  for the eventual real signing key, and reserving the decl entry
  now keeps the eventual bind a rights-narrow rather than a decl
  amendment.

## 6. See also

- `design/architecture/caps-decl-format.md` — the format spec.
- `src/kernel/core/cap/reconcile.pdx` — the kernel substrate.
- `design/tooling/volume-tooling-ux.md` — the R53 authoring wave.
- `design/user/net-tools-caps.md` — the net-tools sibling inventory.
- `design/round-retrospectives/r90-xrepo-013-closed.md` — the closeout audit.
