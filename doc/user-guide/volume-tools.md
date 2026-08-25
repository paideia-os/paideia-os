# Volume tools: mkfs.pdxfs, mount.pdxfs, umount.pdxfs

**Status:** Design-complete, tool repos in progress. This document
describes the *intended* end-to-end walkthrough for bringing a PDXB
volume online and keeping it mounted across a reboot. **As of this
writing (R64), none of the three tools are runnable inside a paideia-os
boot** — see §6 Scope and current blockers before assuming any command
below actually works today.

**Design reference:** `design/tooling/volume-tooling-ux.md` (R53
softarch half) is the authoritative CLI/argv/semantic-record spec this
walkthrough summarizes. Read that document for the full flag surface,
failure taxonomy, and audit/elevate discipline; this document is the
narrower "what does an operator actually type" companion.

---

## 1. What the three tools do

| Tool           | Role                                                              |
|----------------|--------------------------------------------------------------------|
| `mkfs.pdxfs`   | Writes a fresh PDXB v1 superblock + empty allocator bitmap + empty WAL journal + root inode onto a target (file or block-device cap). |
| `mount.pdxfs`  | Attaches an already-formatted `KIND_VOLUME` to a VFS mount point via `sys_mount`, appending a row to the kernel's mount table. |
| `umount.pdxfs` | Reverses a mount: flushes dirty pages, drives the WAL to a CLEAN checkpoint, removes the mount-table row. |

A fourth artifact, `libpdx-volume`, is a shared library the three CLIs
link against (superblock encode/parse, signing helpers, mount-table
snapshot reader) — it is not itself a command an operator runs.

All four live in their own repos under `github.com/paideia-os/`:
`mkfs.pdxfs`, `mount.pdxfs`, `umount.pdxfs`, `libpdx-volume`. None of
their `.pdx` sources are part of this (`paideia-os/paideia-os`)
monorepo.

---

## 2. End-to-end walkthrough (intended)

The full lifecycle an operator exercises is: format a target, mount
it, write files onto it, cleanly unmount it, remount it later, and read
the files back — proving the data survived the mount/unmount cycle
(and, ultimately, a reboot).

### 2.1 Format a fresh image

```
$ mkfs.pdxfs --label=homevol /home/founder/home.img
```

This writes a PDXB superblock, a zeroed allocator bitmap, an empty
1024-block (4 MiB) journal ring, and inode #1 as an empty root
directory, onto `/home/founder/home.img`. On success it emits exactly
one `PdxFsFormatRecord@0.1` semantic record on stdout (see
`design/tooling/volume-tooling-ux.md` §3.5 for the full field list).
Because no `--sig-key` was given and the target is file-backed, the
superblock is written unsigned — fine for the dev workflow described
here; a production device-cap target requires signing (§3.4 of the
design doc).

If `home.img` already looks like a PDXB or PdxFS-lite superblock, the
tool refuses without `--force` (see the design doc §3.3's three-gate
refusal check) so a careless re-run never silently nukes a live
volume.

### 2.2 Mount it

```
$ mount.pdxfs cap:volume:0x0002 /mnt/home
```

`mount.pdxfs` resolves the `KIND_VOLUME` cap (produced by a prior
device-probe or, for a file-backed image opened this session, by the
tool's own open-and-mint step), narrows it to `mount+query`, and calls
`sys_mount`. Two audit records are journaled — an INTENT record before
the syscall, a RESULT record after — sharing an `audit_id` so a
supervisor can always pair "what was attempted" with "what happened"
even if the process crashes mid-call. Mounting under `/mnt/**` needs no
elevate; mounting under `/system`, `/boot`, `/dev`, or another user's
home tree does (see the design doc §4.2's mount-point-class table).

### 2.3 Write files

Once mounted, ordinary tools work unchanged — this is the point of the
"substrate flip" described in the design doc §6. `cp`, `touch`,
`mkdir`, `echo … > file` all already talk to the VFS layer; they simply
now land on a real, journaled backing store instead of tmpfs:

```
$ mkdir /mnt/home/founder
$ echo "hello, persistent world" > /mnt/home/founder/greeting.txt
```

### 2.4 Unmount cleanly

```
$ umount.pdxfs /mnt/home
```

`umount.pdxfs` checks for open handles (refuses with `IN_USE` unless
`--force` or `--lazy` is given), then flushes dirty cache pages, drains
in-flight transactions, advances the journal checkpoint pointer past
the last committed record, and finally sets the superblock's
`clean-unmount` bit before removing the mount-table row. This is what
lets the next mount's boot-time probe skip WAL replay entirely (see
`design/filesystem/volume-fs-substrate.md` §4.3's idempotent-replay
note) — a clean unmount is strictly faster to remount than a
crash-recovered one.

### 2.5 Remount and read back

```
$ mount.pdxfs cap:volume:0x0002 /mnt/home
$ cat /mnt/home/founder/greeting.txt
hello, persistent world
```

The superblock's `clean-unmount` bit tells the probe no replay is
needed; the file written in §2.3 reads back byte-identical. This
mount→write→unmount→remount→readback cycle is the acceptance criterion
for "a volume actually persists data" — not merely "the tool ran
without crashing."

---

## 3. Semantic records

Every successful invocation of all three tools emits a typed record on
its semantic-pipe stdout (`PdxFsFormatRecord@0.1`,
`PdxFsMountRecord@0.1`, `PdxFsUnmountRecord@0.1`), registered in the
schema registry so shell pipelines can consume them structurally rather
than by scraping text. Full field lists live in
`design/tooling/volume-tooling-ux.md` §7.

---

## 4. Failure handling

Each tool distinguishes cap-denial (exit 4) from data-integrity
refusals (exit 5 — signature invalid, journal corrupt, already
mounted, in-use without `--force`) from plain syscall errors (exit 3).
See the design doc §4.4 and §5.6 for the full per-tool failure
taxonomies. The rule of thumb an operator should carry: exit 5 always
means "something about the *data* looked wrong or in-use," never "you
lack permission."

---

## 5. Audit trail

All three tools journal via `libpdx-audit` **before** any user-visible
output or destructive syscall. A `--force` override is never silent:
the audit record for an overridden refusal carries `force_override:
true` alongside the list of gates that would have refused, so "did
anyone ever bypass a safety gate on this volume" is a single grep over
the audit journal (design doc §8.1).

---

## 6. Scope and current blockers (read this before trying any command above)

**None of §2's commands are runnable inside a paideia-os boot today.**
Two independent gaps stand between this document's walkthrough and an
operator actually typing these commands at the `$` prompt:

1. **The tool ELFs do not exist inside paideia-os's tmpfs.** `mkfs.pdxfs`,
   `mount.pdxfs`, and `umount.pdxfs` are separate repos
   (`paideia-os/mkfs.pdxfs`, `paideia-os/mount.pdxfs`,
   `paideia-os/umount.pdxfs`, plus the shared `paideia-os/libpdx-volume`)
   outside this monorepo's scope. Seeding their built ELFs into
   paideia-os's init-time `/bin` seed loop (mirroring the R57.M4-006
   pattern documented at `design/user/rootfs-seed-inventory.md`) is
   tracked as **R64.M1-005 (#1905)** and is blocked on those repos each
   producing a buildable ELF first.
2. **The tool repos themselves are blocked on a paideia-as host-tools
   build gap.** `libpdx-volume`'s superblock signing helper
   (`pdxb_sign_superblock`) needs paideia-as's `mldsa65_sign` intrinsic,
   and the broader mkfs-pdxb host-tools toolchain has an open build gap
   tracked as **paideia-as #1730**. Until that lands, the tool repos'
   own M2/M3 milestones (real superblock write, signing) cannot close,
   which is upstream of #1905 above.

Put together: this document is accurate about *what the tools are
designed to do* (§1–§5, sourced from the frozen R53 design), but the
walkthrough in §2 is aspirational until both the paideia-as toolchain
gap and the paideia-os tmpfs-seed extension (#1905) close. The R64
closure retrospective (`design/round-retrospectives/r64-closure.md`)
tracks this doc as the one piece of R64 that *could* land today, with
the seed step and any live smoke deferred behind it.

**What is real today:** the design (§1–§5, unchanged from R53), and the
four repo scaffolds themselves (each may have landed M1/M2 milestones
independently — check each repo's own CHANGELOG for its current state,
since paideia-os does not track their internal milestone progress).
