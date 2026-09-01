# Volume tools: mkfs.pdxfs, mount.pdxfs, umount.pdxfs

**Status:** Landed at R64v2 (paideia-os#1976/#1977). This document
describes the end-to-end walkthrough for bringing a PDXB volume online
and keeping it mounted across a reboot. **All three tools are real,
runnable `/bin` ELFs inside a default paideia-os boot** — see §6
"Current state, how to run it, and known limits" for the exact
invocation, what still stubs out, and how the pipeline is wired
together.

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

## 6. Current state, how to run it, and known limits

**As of R64v2 (paideia-os#1976/#1977), `mkfs.pdxfs`, `mount.pdxfs`, and
`umount.pdxfs` are real, runnable ELFs inside a default paideia-os
boot.** Each tool is a satellite repo under `tools/user/` (git
submodule, pinned to its `r64v2-closed` tag), linked against three
shared-library submodules (`libpdx-volume`, `libpdx-audit`,
`libpdx-elevate` — link-only; none of the three ships a `/lib`
artifact of its own) by `tools/build.sh`'s `r64v2-tools` step, embedded
into the kernel image by `tools/userbin_embed.S`, and tmpfs-seeded to
`/bin/mkfs.pdxfs`, `/bin/mount.pdxfs`, `/bin/umount.pdxfs` at boot by
`src/kernel/boot/witness/bin_seeds.pdx`'s `bs_mkfs_pdxfs_seed` /
`bs_mount_pdxfs_seed` / `bs_umount_pdxfs_seed` blocks — the same
tmpfs-seed pattern every other `/bin` tool (`ls`, `cat`, `mkdir`, …)
uses. `tools/run-smoke.sh`'s `boot_r64v2_tools` mode exercises the real
end-to-end path: the interactive shell forks + execves
`/bin/mkfs.pdxfs --dry-run /tmp/t.img`, and the boot log is checked
against `tests/r64v2/expected-tools-mkfs-dry-run.golden`.

A kernel-side boot witness *cannot* exercise this directly —
`sys_execve_shim`'s path-based execve validates its path/argv/envp
arguments against the *current task's* real page tables, and no user
task exists yet at the point in boot where a witness would run (the
same limitation `src/kernel/boot/witness/r86_relative_path.pdx`
documents for `sys_chdir`/`sys_getcwd`). `src/kernel/boot/witness/
r64v2_tools.pdx` is therefore a dormant symbol-linkage scaffold, wired
into `kernel_main.pdx` for build-time proof this file compiles and
links, but the real proof is the smoke test above running through the
actual shell.

### How to use them

At the shell prompt, once boot reaches `$`:

```
$ mkfs.pdxfs --dry-run /tmp/t.img
PdxFsFormatRecord@0.1 { target: /tmp/t.img, label: , journal_size: 1024, dry_run: true }
```

`--dry-run` never opens or writes the target — it only argv-parses,
classifies the target (`/`, `~`, or `.` prefix → file target; a
`cap:blkdev:` prefix → device-cap target, see below), and prints the
preview record. Dropping `--dry-run` performs the real file-target
write pipeline described in §2.1–§2.5 above; `mount.pdxfs` and
`umount.pdxfs` follow the same `--dry-run`-first convention.

### Current stubs and known limits

These apply regardless of whether the tool is reached from a real
paideia-os boot or run under its own repo's test driver — they are
substrate gaps, not something this round's ELF-linking work changed:

- **Device-target (`cap:blkdev:...`) writes are stubbed.** No
  `sys_cap_query`-equivalent syscall, no block-granularity write
  syscall, and no osarch-minted `KIND_BLOCK_DEVICE` cap exist yet for
  a standalone CLI tool to use. `mkfs.pdxfs --dry-run` against a
  device-cap target prints the preview and exits; a real write returns
  `FR_RESULT_DEVICE_TARGET_STUB`.
- **Elevation always fails closed.** None of the three tools holds a
  `KIND_ELEVATE_CHANNEL` broker-endpoint capability, so every
  `libpdx-elevate` request they make is denied by construction (not a
  bug — there is no broker wiring for standalone tools yet, tracked at
  paideia-os#1997). This blocks any real `/system`, `/boot`, `/dev`, or
  cross-user mount from actually elevating; `/mnt/**` mounts (§2.2)
  need no elevation and are unaffected.
- **Superblock signing uses a placeholder all-zero seed.** Every
  signature `mkfs.pdxfs` produces is well-formed (`pdxb_sign_
  superblock` via `libpdx-volume`) but verifies against no real key. A
  `libpdx-key`-equivalent seed loader does not exist yet.
- **`libpdx-semantic-pipe` framing stays line-based.** `svc.schema-
  registry` (paideia-os#2000) is inert, so every record prints its
  `# semantic-pipe emit deferred` header before falling back to the
  plain `sys_write` rendering shown above — real structural framing
  waits for that service.
- **Umount's `IN_USE` check is conservative-not-safe.** Real per-volume
  handle-count tracking (`VOL_OP_QUERY_HANDLE_COUNT`) and real
  mount-table row removal (`PMT_OP_REMOVE_ROW`) are both stub bodies on
  the kernel side (`0`-returning cap-invoke ops); they close the ABI
  edge `mount.pdxfs`/`umount.pdxfs` call through, not the underlying
  tracking.

**Debt inventory:** the full, itemized list above (plus hardware-gated
and out-of-R64-scope items) lives in the round retrospective,
`design/round-retrospectives/r64-closure-v2.md` §"Debt inventory
(carried forward)" — written when items #1976/#1977 were still HELD;
this section supersedes that doc's "paideia-os wrappers" entries now
that the ELF-linking + embedding + seeding pipeline has landed.

**Per-repo detail:** each tool's own `CHANGELOG.md` is the authoritative
source for its milestone history and repo-local known-deferred-substrate
notes — `mkfs.pdxfs/CHANGELOG.md`, `mount.pdxfs/CHANGELOG.md`,
`umount.pdxfs/CHANGELOG.md`, and `libpdx-volume/CHANGELOG.md` (all under
`tools/user/<repo>/` once the submodules are checked out). paideia-os
does not mirror their internal milestone tracking.
