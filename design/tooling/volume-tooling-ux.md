# R53 (softarch half) — Volume Tooling UX: mkfs.pdxfs + mount.pdxfs + umount.pdxfs + libpdx-volume

**Status:** proposal (2026-08-22, softarch half of the R53 volume-tooling wave)
**Companion (osarch):** `design/kernel/*` — QEMU `--with-disk` wiring, kernel-side `sys_mount` / `sys_umount` syscall bodies, boot-time PDXB probe → rescue-shell fallback, `KIND_BLOCK_DEVICE` mint semantics for VirtIO/NVMe backing. This document is the user-side half. Overlap with the osarch half is limited to the two coordination points at §12 (syscall ordinals + mkfs argv contract).
**Depends on:**
- `design/filesystem/volume-fs-substrate.md` (R52) — PDXB superblock format, `KIND_VOLUME = 0x1A0`, `KIND_INODE_HANDLE = 0x1A2`, `KIND_SIG_KEY = 0x1A3`, on-disk WAL, bitmap allocator, ML-DSA-65 signed superblock + inode tails.
- `design/tooling/r49-r50-plan.md` (R49/R50 tool wave) — `caps.decl` discipline (I6), semantic-pipe framing, `libpdx-audit` audit-first pattern, `libpdx-elevate` bounded-lifetime grant idiom, five-milestone (M1..M5) per-repo rubric.
- `design/user/pdxfs-kinds.md` — PdxFS KIND coverage audit; §2 gains rows for `KIND_PDXFS_MOUNT_TABLE` on landing this plan.
- `design/user/model.md` §5.1 + §10.2 — elevate-request semantics, signed-inode field.

**Sibling documents to keep in step:**
- `design/filesystem/volume-fs-substrate.md` §7 (R52 milestones) — this doc's §9 R53 milestones open **after** R52.M2 (superblock write) lands so mkfs.pdxfs has a superblock encoder to link.
- `design/tooling/r49-r50-plan.md` §5 (per-tool detail) — mirrors the same shape at smaller cardinality (3 tools + 1 library instead of 9+5).
- `design/tooling/plan.md` D1–D5 + I1–I7 — invariants preserved wholesale.
- `design/architecture/next-wave-derived-kinds.md` — adds `KIND_PDXFS_MOUNT_TABLE` row on landing.

---

## 0. Reading order

- §1 scope + goal — three actions (create image, format image, mount); three CLIs; one shared library.
- §2 tool inventory — repos, one-line purpose, wave placement.
- §3 mkfs.pdxfs CLI — argv, target taxonomy (file vs cap URI), refuse-non-blank gate, sig-key path, semantic-record emission.
- §4 mount.pdxfs CLI — argv, rights required, elevate policy per mount-point class, audit-first + failure taxonomy.
- §5 umount.pdxfs CLI — argv, in-use rejection, --force + --lazy semantics, journal-must-be-CLEAN gate.
- §6 interaction with pkg/shell/R49/R50 tools — substrate flip; zero new tool code required to activate.
- §7 semantic records — three record schemas + schema-registry registration.
- §8 audit + elevate discipline — retention, refused-record shape, elevate matrix per mount-point class.
- §9 milestone breakdown — R53.M1..M5 across three tools + one library.
- §10 first end-to-end smoke — QEMU boot → rescue → mkfs → mount → cp → umount → reboot → cat, with per-stage fingerprints.
- §11 out-of-scope — LVM/RAID/snapshots-persistence/encryption/quota/ACLs deferred to R54+.
- §12 coordination points for main — the two things that need osarch/main sync before R53.M1 opens.

---

## 1. Scope and goal

### 1.1 What "bringing a volume online" means

R52 (softarch half of the block-substrate wave) lands the *in-kernel* substrate: superblock format, WAL journal on-disk layout, bitmap allocator, inode-table walker, `KIND_VOLUME` + `KIND_INODE_HANDLE` + `KIND_SIG_KEY` cap kinds, boot-time probe + root-selection. What R52 does **not** land is a user-facing path to (a) create a fresh volume on a device, (b) format an existing device or image file with a PDXB superblock, or (c) mount a discovered `KIND_VOLUME` at an arbitrary mount point after boot. Without those three actions there is no path from "a blank disk was attached" to "my files are stored on it"; the only volumes ever mounted are the ones the loader picked at boot.

R53 (this doc's wave) closes that user-facing gap with three CLIs and one shared library. A founder (or `pkg install`, or a boot-time init service, or a rescue shell after a probe failure) uses these three tools in exactly this order:

1. **Create image** — either "attach a physical device to QEMU" (osarch's `--with-disk` handles this) or `pkg install ...` allocates a file-backed image inside an existing mounted volume. Not a tool; a prerequisite.
2. **Format image** — `mkfs.pdxfs [flags] <target>` writes a fresh PDXB superblock + empty allocator bitmap + empty journal + root inode. Emits `PdxFsFormatRecord@0.1` on stdout.
3. **Mount** — `mount.pdxfs <volume-cap> <mount-point>` calls `sys_mount`, updates the kernel-side mount table, emits `PdxFsMountRecord@0.1`.

And the reversal:

4. **Unmount** — `umount.pdxfs <mount-id | mount-point>` calls `sys_umount`, flushes dirty pages, drives the journal to a CLEAN checkpoint, emits `PdxFsUnmountRecord@0.1`.

### 1.2 What R53 is deliberately NOT

- **Not multi-device pools.** `design/filesystem/multi-device-pool.md` sketches a RAID-like layout across N devices; R53 mounts exactly one `KIND_BLOCK_DEVICE` per `KIND_VOLUME`. LVM-style logical volumes are out.
- **Not snapshot persistence tooling.** R52 defers snapshot-region persistence to R54; there is no `snap-create.pdxfs` / `snap-restore.pdxfs` tool in this wave.
- **Not encryption-at-rest tooling.** Signed-inode-tail is present at R52; per-block encryption ("encrypted at rest") is R54+ and needs a `KIND_KEK` we do not yet allocate.
- **Not quota or ACL tooling.** Quotas need a per-user counter block; ACLs collide with the capability model at `KIND_PDXFS_FILE` + `KIND_USER`. Both deferred to R55+.
- **Not `fsck.pdxfs`.** A read-only scrub tool that verifies inode signatures + walks the free-space bitmap is a natural sibling of these three, but its scope (understand every walker invariant, report + optionally repair) is a wave of its own. R53 stubs it as a follow-up.

### 1.3 One-paragraph mental model

The **target** of `mkfs.pdxfs` is either a filesystem-path (`/home/founder/foo.img`, the dev workflow — no root required, no signing required at v0) or a `KIND_BLKDEV` cap URI (`cap:blkdev:0x0042`, the production workflow — root required via elevate, mandatory signing). The mkfs tool refuses to overwrite a non-blank target unless `--force`. On success, the tool emits exactly one `PdxFsFormatRecord@0.1` on its semantic-pipe stdout. The **argument** to `mount.pdxfs` is a `KIND_VOLUME` cap URI (produced by the boot-time probe or by a device-attach event) plus a mount-point path; the tool bounds its rights request to `KIND_VOLUME:mount` + `KIND_PDXFS_MOUNT_TABLE:write` and — if the mount point is under `/system`, `/boot`, or `/dev` — invokes `libpdx-elevate` before calling `sys_mount`. The **argument** to `umount.pdxfs` is either a mount id (produced by the mount record) or the mount-point path; the tool rejects if any handle is still open (unless `--force` + elevate), then drives the journal through a CLEAN checkpoint before returning. All three tools journal through `libpdx-audit` *before* any user-visible output, and all three emit typed semantic records the shell forwards unchanged through pipelines.

---

## 2. Tool inventory — three new tool repos + one shared library

Four new public repos under `github.com/paideia-os/` on landing R53. Repository shape mirrors R49/R50 (paideia-as manifest at root, `caps.decl` at root, `src/` for module tree, `.pdxdoc` shipped for `doc <tool>` back-end, dual-signed `manifest.pdxsig` at release).

### 2.1 `mkfs.pdxfs` — write a fresh PDXB volume onto a target

**Repo:** `paideia-os/mkfs.pdxfs`
**Purpose.** Format a blank block-device cap or a blank/existing image file with a fresh PDXB v1 superblock, empty allocator bitmap, empty journal ring, and a single root-inode entry (inode #1 as directory).
**Existing kernel KINDs consumed.**
- `KIND_USER` (0x190) — invoker identity for audit + for the sig-key-owner check.
- `KIND_PDXFS_FILE(read+write, <path>)` — when target is a filesystem path; one cap per invocation.
- `KIND_BLOCK_DEVICE` (osarch, R51, ordinal 0x198–0x19F band per §12) — when target is a device cap URI; the tool holds an `open+write+flush+query` sub-cap.
- `KIND_SIG_KEY` (0x1A3, R52) — the signing key material used to sign the superblock byte range `[0, 696)`.
- `KIND_IPC_ENDPOINT` — semantic pipe.
- `KIND_ELEVATE_CHANNEL` (0x191) — only when the target is a device cap and the invoker's default capability set does not include `KIND_BLOCK_DEVICE(write, <dev>)`.
**New KINDs introduced.** None. mkfs uses R52-allocated cap kinds; no ordinal request.
**Ships in wave:** R53.M1..M5.

### 2.2 `mount.pdxfs` — attach a KIND_VOLUME to a mount point

**Repo:** `paideia-os/mount.pdxfs`
**Purpose.** Take a probed `KIND_VOLUME` cap and mount it at a VFS path via `sys_mount`. Bounds rights, walks the elevate-policy table for privileged mount points, journals audit records both before (INTENT) and after (RESULT) the syscall.
**Existing kernel KINDs consumed.**
- `KIND_USER` (0x190) — invoker.
- `KIND_VOLUME` (0x1A0, R52) — the volume to mount; the tool never re-verifies the superblock (R52.M5 already did) but does check the tail's `mount_gen` matches what the probe last set.
- `KIND_PDXFS_MOUNT_TABLE` (**new — 0x1A5**, allocated by this doc) — write authority to append a mount-table row.
- `KIND_ELEVATE_CHANNEL` (0x191) — per mount-point-class table in §8.
- `KIND_IPC_ENDPOINT` — semantic pipe + audit journal.
**New KINDs introduced.**
- `KIND_PDXFS_MOUNT_TABLE = 0x1A5` (derived over `KIND_MEMORY = 4`) — one row per active mount; write authority is bounded to "append a mount entry from a validated KIND_VOLUME"; read authority is broadly granted so `df` and `mount --list` can enumerate.

  Row shape: `{mount_id: u64, volume_uuid: [u8;16], mount_point_id: u32 (name-store ref), backend_id: u8, flags: u32, mount_gen: u64, invoker_user: [u8;32] (KIND_USER key hash)}` = 64 bytes; 8-row cap matches the R52 mount-table 8-slot limit at `core/fs/mount.pdx`. Ordinal `0x1A5` lands in the R52 softarch band (0x1A0..0x1A7) filling the reserved slot noted at `design/filesystem/volume-fs-substrate.md` §6.1. If osarch's R51 HW-KIND count shifts softarch's band, `0x1A5` renames symbolically per that doc's §6.1 "Ordinal negotiation" clause.
**Ships in wave:** R53.M1..M5.

### 2.3 `umount.pdxfs` — detach a mount

**Repo:** `paideia-os/umount.pdxfs`
**Purpose.** Reverse a mount. Reject if any file handle is still open on the volume (unless `--force` + elevate). Flush dirty pages, drive the WAL to a CLEAN checkpoint, then remove the mount-table row.
**Existing kernel KINDs consumed.**
- `KIND_USER` — invoker.
- `KIND_PDXFS_MOUNT_TABLE` — write (to remove the row).
- `KIND_VOLUME` — for the flush + CLEAN-checkpoint driver.
- `KIND_ELEVATE_CHANNEL` — only for `--force` and only when the mount point is under `/system`, `/boot`, or `/dev`.
- `KIND_IPC_ENDPOINT` — semantic pipe + audit journal.
**New KINDs introduced.** None.
**Ships in wave:** R53.M1..M5.

### 2.4 `libpdx-volume` — client-side volume helpers

**Repo:** `paideia-os/libpdx-volume`
**Purpose.** The single shared library the three CLIs (and future `df`, `fsck.pdxfs`) all link. Ships:
- **`vol_kind_mint(dev_cap) → Cap<KIND_VOLUME>`** — client-side helper that calls the kernel's mint helper against a probed `KIND_BLOCK_DEVICE`; used by `mount.pdxfs` when a probed device has a valid superblock but no `KIND_VOLUME` was minted at boot (a hot-plugged device).
- **`vol_kind_narrow(vol_cap, ops_mask) → Cap<KIND_VOLUME>`** — narrows a `KIND_VOLUME` cap to a subset of `{mount, query, flush, snapshot}` ops; used by `mount.pdxfs` to hand `sys_mount` a cap containing exactly `mount` + `query`.
- **`pdxb_parse_superblock(bytes) → PdxbSuperblockSummary | Err`** — read-only parser for the 4096-byte superblock into a memory struct (offsets from R52 §2.1). Used by `mkfs.pdxfs --dry-run` (to display what would be written) and by `mount.pdxfs --verbose` (to display the volume UUID + free-block count before mounting).
- **`pdxb_encode_superblock(fields) → [u8; 4096]`** — inverse of the parser. Used by `mkfs.pdxfs`.
- **`pdxb_sign_superblock(bytes, sig_key_cap) → [u8; 4096]`** — writes the ML-DSA-65 signature into offset `[696, 4096)`. Depends on paideia-as ≥ v0.33 for the `mldsa65_sign` intrinsic (called out as a blocker gap at R52.M2 dependency-list, `design/filesystem/volume-fs-substrate.md` §8.1).
- **`mount_table_snapshot() → Vec<MountTableRow>`** — client-side read of `KIND_PDXFS_MOUNT_TABLE`; used by `umount.pdxfs` when resolving a mount-point string to a mount_id, and (later) by `df` for its output.
**Ships in wave:** R53.M1..M5. Blocks all three tools (their M2 cannot open until libpdx-volume.M2 closes).

---

## 3. `mkfs.pdxfs` CLI

### 3.1 Argv surface

```
mkfs.pdxfs [--force] [--label=<str>] [--journal-size=<n_blocks>] [--dry-run] [--verbose] [--sig-key=<key-cap-uri>] <target>
```

- `<target>` is either:
  - a filesystem path (e.g. `/home/founder/foo.img`) — dev workflow, file-backed, no root, no signing required at v0 (see §3.4);
  - a `KIND_BLKDEV` cap URI (e.g. `cap:blkdev:0x0042`) — production workflow, elevate-required, signing mandatory.
- `--force` — overwrite a non-blank target (see §3.3).
- `--label=<str>` — attach a UTF-8 label to the volume (stored in the superblock's `_reserved` region, first 24 bytes; per §3.5).
- `--journal-size=<n_blocks>` — set journal ring capacity in 4KiB blocks (default 1024 = 4 MiB, matches R52 §2.4 default).
- `--dry-run` — parse the target, compute the superblock, print the `PdxFsFormatRecord@0.1` that *would* be emitted, but do not write. Semantic-pipe output on stdout is identical to a real run except for a `dry_run: true` field.
- `--verbose` — write additional human-readable lines to stderr per stage (probe target, allocate journal region, sign superblock, write superblock, write allocator bitmap zeroes, write root inode, close).
- `--sig-key=<key-cap-uri>` — override the default signing key (defaults to the invoker's user_sk, unlocked at session start per `design/user/model.md` §2). Required when target is a device cap (see §3.4).

### 3.2 Target-taxonomy resolution

The tool inspects `<target>` at parse time and dispatches to one of two code paths:

- **File-backed path.** If `<target>` begins with `/`, `~`, or `.`, resolve to a filesystem path. Open a `KIND_PDXFS_FILE(read+write, <path>)` cap via `libpdx-cap`; if the file does not exist, create it (parent-directory write-authority required) and `truncate` to a caller-specified length via `--size=` (default 128 MiB, matching the R52.M8 smoke). This path emits a `file_backed: true` field in the format record.
- **Device-cap URI.** If `<target>` begins with `cap:blkdev:`, resolve to a `KIND_BLOCK_DEVICE` cap by looking it up in the invoker's cap environment (set by `shell`'s InitCap seed). If the invoker does not hold write authority on the device, the tool invokes `libpdx-elevate` requesting `KIND_BLOCK_DEVICE(write, <dev>)` for a 30-second window (matches `pkg install`'s elevate pattern per `design/user/model.md` §5.1). This path emits `file_backed: false`.

Any other prefix is a parse error (exit 2, invalid argument). No implicit /dev-style resolution — every cap URI is explicit.

### 3.3 Non-blank-target refusal

**Discipline.** Before writing anything, mkfs reads the first 4096 bytes of the target and inspects:

1. The first 4 bytes. If they match `0x42584450` (`"PDXB"`), the target already holds a PDXB superblock. Refuse without `--force`.
2. The first 4 bytes. If they match `0x4C584450` (`"PDXL"`, R25 PdxFS-lite format), refuse and suggest `--upgrade` (a follow-up flag deferred to R53.M4 that reads a PDXL superblock and rewrites it to PDXB — the migration path per `design/filesystem/volume-fs-substrate.md` §4.5).
3. Any other non-zero-filled first-block content. Refuse with a `NON_BLANK` diagnostic that hex-dumps the first 32 bytes of the target so the operator can identify what they were about to overwrite.

With `--force`, mkfs proceeds regardless — but emits an audit `REFUSED_OVERRIDDEN` sub-record listing every gate that would have refused (see §8.1). This is deliberate: `--force` bypasses the refusal but never the audit trail. A supervisor replaying the audit journal can always answer "was a blank target being formatted, or was live data being nuked?"

### 3.4 Signing discipline

- **File-backed target, no `--sig-key`.** Superblock is written *unsigned* (the `sig` region at offset `[696, 4096)` is left zeroed). Mount will refuse this volume unless the invoker also boots with `--allow-unsigned-volumes` (a rescue-shell-only kernel flag scheduled at R52.M5). This makes file-backed volumes usable for the dev workflow without requiring key unlock, but does not silently produce a volume that could be mistaken for a production one.
- **File-backed target, with `--sig-key`.** Superblock is signed using the named key. This is the path a founder uses to prepare a signed image for later dd-to-device.
- **Device-cap target.** `--sig-key` is mandatory (defaults to the invoker's user_sk if unlocked; explicit failure if locked). Refusal without a key is by design: a device-cap volume that is not signed cannot be booted from and cannot serve as a `/system` mount, so signing is a one-way ratchet the tool enforces at format time rather than at mount time.

Signing uses `libpdx-volume.pdxb_sign_superblock`, which calls the paideia-as `mldsa65_sign` intrinsic (see §12 coordination point 2 — this is the paideia-as-side blocker gap R52.M2 dependency-list already flagged; R53.M1-mkfs.pdxfs cannot open until it lands).

### 3.5 Semantic-pipe output

Exactly one `PdxFsFormatRecord@0.1` record on stdout, plus verbose-mode stderr chatter. Record shape:

```
PdxFsFormatRecord@0.1 {
  target_kind:      enum { FILE_BACKED, DEVICE_CAP }
  target_uri:       string  # filesystem path, or cap URI
  block_size:       u32     # always 4096 at R53
  total_blocks:     u64
  journal_blocks:   u64     # from --journal-size, default 1024
  itable_blocks:    u64     # computed from total_blocks per R52 §2.3
  data_blocks:      u64
  uuid:             [u8;16] # RFC 4122 v4
  label:            string  # from --label, empty if unset
  sig_key_hash:     [u8;32] # BLAKE3 of the signing pubkey, or all-zeroes if unsigned
  signed:           bool
  invoker_user:     KIND_USER_ref
  ts_ns:            i128    # UTC-nanoseconds
  dry_run:          bool
  refused_gates:    Vec<enum{ NON_BLANK_PDXB, NON_BLANK_PDXL, NON_BLANK_OTHER }>
                            # non-empty only when --force overrode a refusal
}
```

The `label` field carries the `--label` value up to 24 bytes (fits into the reserved region per R52 §2.1); longer labels truncate with a stderr warning.

---

## 4. `mount.pdxfs` CLI

### 4.1 Argv surface

```
mount.pdxfs [--ro] [--noexec] [--verbose] [--dry-run] <volume-cap> <mount-point>
```

- `<volume-cap>` — a `KIND_VOLUME` cap URI (e.g. `cap:volume:0x0002`); looked up in the invoker's cap environment. Fails with exit 4 (cap denied) if not held.
- `<mount-point>` — a VFS path where the volume should attach.
- `--ro` — mount read-only; the mount-table row's flag byte is written with `MOUNT_FLAG_READONLY`.
- `--noexec` — mount with the executable bit cleared per-inode at open (VFS-layer flag, not on-disk).
- `--verbose` — stderr chatter per stage (elevate request, sys_mount, mount-table row append, semantic-pipe emit).
- `--dry-run` — parse both args, print the `PdxFsMountRecord@0.1` that would be emitted with `result_code: DRY_RUN`, do not call `sys_mount`.

### 4.2 Rights required + elevate discipline

The tool's `caps.decl` requests:
- `KIND_USER` — always.
- `KIND_VOLUME(mount+query, <cap-uri-from-argv>)` — narrowed to the specific volume, not "all volumes".
- `KIND_PDXFS_MOUNT_TABLE(write)` — write authority to append one row.
- `KIND_IPC_ENDPOINT` — for semantic pipe + audit journal + optional elevate broker.

Elevate is invoked based on the mount-point-class table:

| Mount-point pattern         | Elevate needed?         | Rationale                                                    |
|-----------------------------|-------------------------|--------------------------------------------------------------|
| `/system/**`                | Always                  | System-owned tree; only founder or delegated user may modify.|
| `/boot/**`                  | Always                  | Bootloader-visible tree; sig-key rotation risk.              |
| `/dev/**`                   | Always                  | Device-scoped tree; misuse defeats DMA-domain consent.       |
| `/mnt/**`                   | Never                   | General-purpose mount playground; user-owned by convention.  |
| `/home/<$user>/**`          | Never                   | Own-subtree.                                                 |
| `/home/<$other>/**`         | Founder-only elevate    | Cross-subtree; needs owner consent via elevate.              |
| `/tmp/**`                   | Never                   | Session-scoped.                                              |
| Anywhere else               | Founder-only elevate    | Conservative default: unknown-class needs approval.          |

Auto-approve paths land in the R48 `elevate_policy.pdx` table (extended in §5.0 of the R49/R50 plan as `R48-PREP-005`). A founder registers "auto-approve mount.pdxfs on /system if the volume is signed by paideia_root_pk" and the elevate call satisfies from the policy table without a human hop.

### 4.3 Audit-first + INTENT/RESULT record pattern

`mount.pdxfs` writes **two** audit records per invocation:

1. **INTENT (before sys_mount).** `PdxFsMountRecord@0.1` with `result_code: INTENT` and every argv + resolved cap detail. Journaled before any syscall touches the mount table. This exists so a mount that hangs or crashes leaves a durable trace.
2. **RESULT (after sys_mount).** Same record shape, `result_code:` set to the actual outcome (OK, or a failure code from §4.4). Journaled after `sys_mount` returns.

The two records share an `audit_id` field so the audit-journal reader can pair them. This is a light extension of `libpdx-audit`'s three-call API from R49 (which pairs a single `audit_begin` with a single `audit_commit`); the mount case needs a mid-op record because the syscall itself is the fence.

### 4.4 Failure taxonomy

| Code                         | Meaning                                                                              |
|------------------------------|--------------------------------------------------------------------------------------|
| `OK`                         | Mount succeeded; row appended to mount table.                                        |
| `SIG_INVALID`                | Superblock signature does not verify against the volume's declared sig-key.          |
| `SIG_KEY_UNKNOWN`            | Loader did not seed a `KIND_SIG_KEY` matching `superblock.sig_key_hash`.             |
| `JOURNAL_CORRUPT`            | WAL replay found a torn block outside the tolerated tail; unsafe to mount.          |
| `ALREADY_MOUNTED`            | Volume's UUID already appears in the mount table (with a different mount point).     |
| `MOUNT_POINT_EXISTS`         | Path already has something mounted at it (union-mount not supported at R53).         |
| `MOUNT_POINT_MISSING`        | Path does not exist (mkdir it first, or use `--create-parents` at a future round).   |
| `NO_PERMISSION`              | Invoker's caps do not include what §4.2 requires and elevate refused/timed out.      |
| `SYSCALL_ERROR`              | `sys_mount` returned an errno not covered above; hex-dumped in the record.           |
| `DRY_RUN`                    | `--dry-run` set; nothing was mounted.                                                |

Each code maps to a distinct exit-code range in the tool's exit-status contract (I4): 0 for OK, 2 for MOUNT_POINT_*, 3 for SYSCALL_ERROR, 4 for NO_PERMISSION, 5 for SIG_INVALID + SIG_KEY_UNKNOWN + JOURNAL_CORRUPT + ALREADY_MOUNTED. This is a deliberate choice: signature-invalid is not "cap denied" (that would be exit 4) — it is a data-integrity refusal (exit 5, "volume rejected").

---

## 5. `umount.pdxfs` CLI

### 5.1 Argv surface

```
umount.pdxfs [--lazy] [--force] [--verbose] [--dry-run] <mount-id | mount-point>
```

- `<mount-id>` — the u64 id from a prior `PdxFsMountRecord@0.1`'s `mount_id` field.
- `<mount-point>` — a VFS path; the tool resolves to a mount_id by scanning the mount table via `libpdx-volume.mount_table_snapshot`.
- `--lazy` — defer the actual unmount until every open handle closes; the mount-table row transitions to `PENDING_UNMOUNT` immediately, `UNMOUNTED` when the last handle drops. See §5.4.
- `--force` — override the "handles still open" refusal (see §5.3). Elevate-required.
- `--verbose` — per-stage stderr chatter.
- `--dry-run` — check refusals + rights, print the `PdxFsUnmountRecord@0.1` that would be emitted with `result_code: DRY_RUN`, do not call `sys_umount`.

### 5.2 Rights required

`caps.decl`:
- `KIND_USER`.
- `KIND_PDXFS_MOUNT_TABLE(read+write)` — read to resolve mount-point → id; write to remove the row.
- `KIND_VOLUME(flush+unmount, <resolved-cap>)` — the tool resolves the volume cap by looking up the mount-table row.
- `KIND_ELEVATE_CHANNEL` — only for `--force` on mount points under `/system`, `/boot`, `/dev` (mirrors mount.pdxfs's table).
- `KIND_IPC_ENDPOINT` — semantic pipe + audit journal.

### 5.3 In-use rejection

Before calling `sys_umount`, the tool queries the volume for open handle count (`KIND_VOLUME.VOL_OP_QUERY_HANDLE_COUNT`, a new op added by R53.M2 to R52's `KIND_VOLUME` op set). If nonzero:

- Without `--force` and without `--lazy`: refuse with `IN_USE`; the record's `open_handles` field carries the count. Exit code 5 (data-integrity refusal, same category as mount's SIG_INVALID — an unmount that would drop data is a data-integrity issue).
- With `--lazy`: mark the mount-table row `PENDING_UNMOUNT` and return OK immediately. The kernel's mount-table maintainer removes the row when the handle count reaches zero (§5.4).
- With `--force` and elevate: skip the handle-count gate and proceed — but every currently-open handle transitions to a "revoked" state, and subsequent I/O on it returns `EIO`. Every revoked handle is listed in the record's `revoked_handles` field so the audit trail names what was cut. Force-unmount is a supervisor recovery action, not a normal path.

### 5.4 Lazy semantics

The `--lazy` path mirrors Linux `umount -l` but is implemented differently: rather than the kernel holding a per-mount "pending" flag consulted on every open, the R52 mount table gains a `MOUNT_FLAG_PENDING_UNMOUNT` bit. The lookup path in `core/fs/path.pdx` treats a `PENDING_UNMOUNT` mount as "not present for new opens" while still serving existing open handles. When the last handle closes, the kernel-side mount-table maintainer removes the row and fires a `PdxFsUnmountRecord@0.1` with `result_code: OK` and `deferred: true` — the umount tool's initial record had `result_code: PENDING`, and the deferred completion record shares its `mount_id` for correlation.

### 5.5 Journal-CLEAN gate

Every non-force umount drives the WAL through a clean-checkpoint transition before removing the mount-table row:

1. Cache is flushed (`KIND_BLOCK_CACHE.BC_OP_FLUSH` — supervisor-only, invoked by the walker).
2. Any in-flight transactions on the volume are drained: OPEN → COMMITTED (by their owners), or OPEN → ABORTED (if the owner is gone).
3. The checkpoint pointer in the last journal block advances past the last committed record.
4. The superblock's `flags` byte gets `bit0 clean-unmount` set + resigned + rewritten. This is the signal boot-time probe checks to distinguish "clean last unmount, replay not needed" from "crash, replay every uncheckpointed record".
5. The mount-table row is removed.

If step 4 fails (e.g. the sig-key is not unlocked at unmount time), the tool refuses with `SIG_KEY_LOCKED` — cleanup happened, but the superblock cannot be updated to reflect it. `--force` bypasses this, leaving the volume in the "as-if-crashed" state that the next mount's replay will handle correctly (idempotent replay per R52 §4.3).

### 5.6 Record shape

`PdxFsUnmountRecord@0.1`:

```
PdxFsUnmountRecord@0.1 {
  audit_id:              u64      # links INTENT + RESULT + (lazy) DEFERRED
  mount_id:              u64
  volume_uuid:           [u8;16]
  mount_point:           string
  invoker_user:          KIND_USER_ref
  dirty_pages_flushed:   u64      # count of dirty cache slots the flush drained
  txns_drained:          u32      # committed + aborted
  journal_state:         enum { CLEAN, DIRTY_FORCED, SIG_KEY_LOCKED }
  result_code:           enum { OK, IN_USE, NO_PERMISSION, SIG_KEY_LOCKED,
                                SYSCALL_ERROR, DRY_RUN, INTENT, PENDING }
  open_handles:          u32      # nonzero on IN_USE
  revoked_handles:       Vec<u64> # populated on --force
  deferred:              bool     # true when the DEFERRED completion record fires
  ts_ns:                 i128
}
```

---

## 6. Interaction with `pkg`, `shell`, and other R49/R50 tools

R53 is a substrate flip. The user-facing R49/R50 tools are already written to talk to `KIND_PDXFS_FILE` + `KIND_PDXFS_TXN` at their abstract cap layer; what changes at R53 is *what the walker does when those caps mutate*. Specifically:

- **`pkg install <foo>`.** At R49, `pkg install` writes to whatever backend the mount table has at `/system/packages/` — which, until R52 lands, is tmpfs (in-memory, lost on reboot). Once R52 lands and R53's `mount.pdxfs` attaches a real volume at `/system`, `pkg install` writes to the real journaled backing store. The `pkg` binary itself does not change; the difference is that `pkg install foo && reboot && ls /system/packages/` now shows `foo` after the reboot, whereas before R52+R53 it did not. No tool code changes.
- **`ls /mnt/pdxb`.** At R49, `ls` calls `sys_pdxfs_dir_readnext` (R42-PREP-008, `design/user/pdxfs-kinds.md` §3.1). At R52 that syscall's body is now backed by a real volume walker rather than the three-entry stub; the ABI is unchanged, so `ls` observes real entries.
- **`cp a b` on a mounted volume.** At R49, `cp` opens a `KIND_PDXFS_TXN`, calls the walker, commits. At R52 the walker's mutations land in a real on-disk WAL; the atomicity guarantee `cp` already advertised (all-or-nothing) becomes true across reboots, not just across process crashes.
- **`shell`'s `~/.history/`.** At R49, the shell writes history through `KIND_PDXFS_FILE(write, ~/.history/)`. At R52+R53 this is durable across reboot if `/home` is on a mounted volume.

The point is: no R49/R50 tool needs a new milestone or an amended `caps.decl` to benefit from R53. The substrate flip is the activation. The one caveat is `pkg install pkg` self-install (§7.8 of the R52 plan): its round-trip smoke assertion (a file created before reboot is present after reboot) becomes a *real* test only once R53's mkfs+mount+umount let a smoke script format+mount+unmount its own volume. §10 below is that smoke.

---

## 7. Semantic records (schema registry)

Three record schemas ship with this wave. Each is registered in the schema registry (the R25 substrate; per `svc.schema-registry` in R49 plan §5.11) at R53.M3 and pipeable via `libpdx-semantic-pipe`.

### 7.1 `PdxFsFormatRecord@0.1`

See §3.5 for the field list. Version `0.1` fingerprint (BLAKE3-truncated 32 bytes) lands as a constant in `libpdx-volume` at M3-001. Backward-compat rule: `@0.1` → `@0.2` will add fields only at the tail; consumers ignore fields whose offset exceeds the version's known list.

### 7.2 `PdxFsMountRecord@0.1`

Fields:
```
PdxFsMountRecord@0.1 {
  audit_id:      u64
  mount_id:      u64         # populated on RESULT, zero on INTENT
  volume_uuid:   [u8;16]
  volume_cap_uri: string
  mount_point:   string
  flags:         u32         # RO, NOEXEC, ...
  invoker_user:  KIND_USER_ref
  result_code:   enum        # OK / SIG_INVALID / SIG_KEY_UNKNOWN /
                             #   JOURNAL_CORRUPT / ALREADY_MOUNTED /
                             #   MOUNT_POINT_EXISTS / MOUNT_POINT_MISSING /
                             #   NO_PERMISSION / SYSCALL_ERROR /
                             #   DRY_RUN / INTENT
  elevate_id:    Option<u64> # populated when libpdx-elevate was invoked
  ts_ns:         i128
}
```

### 7.3 `PdxFsUnmountRecord@0.1`

See §5.6.

### 7.4 Schema-registry registration

All three schemas register at R53.M3-*-002 for each tool, referencing the fingerprint constants in `libpdx-volume`. The schema-registry is a userspace service (per R49 §5.11 note); if it lands after R53 opens, the tools fall through to text-layer output for that period and the schema-typed layer activates on registry availability.

---

## 8. Audit + elevate discipline

### 8.1 Audit-first, always

Every one of the three tools journals via `libpdx-audit` **before** emitting anything on stdout or completing any syscall. mkfs's record is one-shot (`audit_begin` → `audit_commit`); mount's is INTENT+RESULT (two records sharing an audit_id); umount's is INTENT+RESULT plus (for `--lazy`) a DEFERRED completion record.

Refusal records are first-class: if mkfs refuses because the target is non-blank, an audit record is written with `refused_gates: [NON_BLANK_PDXB]` and exit code 5. If `--force` overrides that refusal, the record is written with the same `refused_gates` list plus a `force_override: true` field. A supervisor auditing "was any live data ever nuked" grep-friendly-queries `refused_gates != [] && force_override == true`.

### 8.2 Elevate matrix (mount.pdxfs + umount.pdxfs --force)

Per §4.2 for mount and §5.2 for umount. Auto-approve policy candidates a founder is expected to register at boot:

- `auto-approve mount.pdxfs on /system if superblock signed by paideia_root_pk`
- `auto-approve mount.pdxfs on /home/**/mnt/** for own subtree` (implicit — no elevate at all)
- `auto-approve umount.pdxfs --force on /mnt/**` (rescue path)
- `no auto-approve on /boot or /dev` (always human-in-loop)

These are registered via `elevate_policy.pdx`'s existing table (R48.M7) — R53 does not extend the policy schema, only registers rows.

### 8.3 Retention

- **Format records** retained forever. Formatting a volume is a destructive act whose provenance may be needed years later (a founder investigating "who created this volume" reads the format record's `invoker_user + ts_ns`).
- **Mount records** retained 30 days. Frequently-remounted volumes (a USB stick attached daily) would flood the journal otherwise.
- **Unmount records** retained 30 days. Same reasoning.
- **Refusal records with `force_override: true`** retained forever (regardless of the underlying op class). This is the audit surface for "someone bypassed a safety gate".

Retention policy is enforced by the user_events_journal maintainer (per R48.M7 substrate); R53 registers the three new UEJ kinds:
- `UEJ_KIND_VOL_FORMAT = 10` (retain forever)
- `UEJ_KIND_VOL_MOUNT = 11` (retain 30d)
- `UEJ_KIND_VOL_UNMOUNT = 12` (retain 30d)

Registration lands as `R53-PREP-000` (§9.0), a paideia-os main-repo issue that must land before R53.M1 opens (mirrors the `R49-PREP-006` pattern from R49/R50 plan §5.0).

---

## 9. Milestone breakdown

R53.M1..M5 across four repos, mirroring R49/R50 discipline (M1 scaffold, M2 real body, M3 semantic-pipe + audit + elevate, M4 tests + smoke, M5 signed release). Each tool ships 15 issues; the library ships 12; substrate-prep contributes 3. **Total: 15×3 + 12 + 3 = 60 issues**.

The wave negotiates with osarch's R53 half at §12 coordination point 1: if osarch schedules `sys_mount` + `sys_umount` for a later kernel wave, R53 tools slip until then. As of 2026-08-22 the plan assumes osarch delivers those two syscalls in the same wave (R53 kernel half).

### §9.0 Substrate prep (paideia-os main repo, before R53.M1 opens)

```
paideia-os.R53-PREP-000 UEJ_KIND_VOL_FORMAT/MOUNT/UNMOUNT constants + retention-policy rows in user_events_journal.pdx
paideia-os.R53-PREP-001 KIND_PDXFS_MOUNT_TABLE = 0x1A5 derived-kind + witness (`src/kernel/core/cap/kind_pdxfs_mount_table.pdx`)
paideia-os.R53-PREP-002 mount.pdx: gain MOUNT_FLAG_PENDING_UNMOUNT bit + path.pdx lookup respects it (backs mount.pdxfs --lazy)
```

**Ordering.** R53-PREP-000 blocks libpdx-volume.M2; R53-PREP-001 blocks mount.pdxfs.M2 + umount.pdxfs.M2; R53-PREP-002 blocks umount.pdxfs.M3 (--lazy path). Main tracks these as a "R53-substrate" GitHub milestone on the paideia-os repo, and the R53 tool wave is gated on 100% closure.

### §9.1 `mkfs.pdxfs` (paideia-os/mkfs.pdxfs) — 15 issues

**M1 — Design + skeleton.** Scaffold + caps.decl (KIND_USER, KIND_PDXFS_FILE for file targets, KIND_BLOCK_DEVICE placeholder for device targets, KIND_SIG_KEY placeholder). Argv parsing (`--force`, `--label`, `--journal-size`, `--dry-run`, `--verbose`, `--sig-key`, `<target>`). First runnable: `mkfs.pdxfs --dry-run /tmp/foo.img` prints the format record it *would* emit.

**M2 — Core implementation.** Real superblock encoder via libpdx-volume.pdxb_encode_superblock; write superblock + zero allocator bitmap + init journal ring + write root inode. Non-blank refusal gate (§3.3). File-backed target path only.

**M3 — Device-target + signing + semantic-pipe + audit + elevate.** Device-cap target resolution + KIND_BLOCK_DEVICE narrowing. Superblock signing via libpdx-volume.pdxb_sign_superblock. Semantic-pipe emission of `PdxFsFormatRecord@0.1`. libpdx-audit journaling (audit-first). libpdx-elevate request for device-cap targets when invoker lacks KIND_BLOCK_DEVICE(write).

**M4 — Tests + smoke.** File-target happy path, device-target happy path (against QEMU virtio disk), non-blank refusal matrix (PDXB, PDXL, other), --force override + audit trail correctness, --dry-run correctness, --upgrade path (PDXL → PDXB, per R52 §4.5).

**M5 — Signed release.** Dual-signed manifest.pdxsig for mkfs.pdxfs v1.0, CHANGELOG entry, .pdxdoc for `doc mkfs.pdxfs`, mirror push.

**Issues:**
```
mkfs.pdxfs.M1-001 scaffold + caps.decl (KIND_USER + KIND_PDXFS_FILE + KIND_BLOCK_DEVICE placeholder + KIND_SIG_KEY placeholder)
mkfs.pdxfs.M1-002 argv surface via libpdx-argv (--force, --label, --journal-size, --dry-run, --verbose, --sig-key, <target>)
mkfs.pdxfs.M1-003 first runnable: --dry-run against a file target prints the format record it would emit
mkfs.pdxfs.M2-001 target-taxonomy resolver: file path vs cap:blkdev: URI dispatch
mkfs.pdxfs.M2-002 write superblock + zero allocator bitmap + init journal ring (file-backed target only)
mkfs.pdxfs.M2-003 write root inode #1 as empty directory (uses libpdx-volume inode encoders)
mkfs.pdxfs.M2-004 non-blank refusal gate (§3.3): PDXB / PDXL / other-content diagnostics
mkfs.pdxfs.M3-001 device-cap target path + KIND_BLOCK_DEVICE(write) narrowing
mkfs.pdxfs.M3-002 superblock signing via libpdx-volume.pdxb_sign_superblock (mandatory on device targets)
mkfs.pdxfs.M3-003 semantic-pipe: PdxFsFormatRecord@0.1 schema bind + emit
mkfs.pdxfs.M3-004 libpdx-audit: pre-write journal record (retain-forever UEJ_KIND_VOL_FORMAT)
mkfs.pdxfs.M3-005 libpdx-elevate: KIND_BLOCK_DEVICE(write, <dev>) request when invoker lacks it
mkfs.pdxfs.M4-001 file-target happy path smoke (format → mount refused because unsigned → mount --allow-unsigned OK)
mkfs.pdxfs.M4-002 non-blank refusal matrix + --force override + audit-trail assertion
mkfs.pdxfs.M4-003 device-target smoke against QEMU virtio disk (--with-disk flag from osarch)
mkfs.pdxfs.M4-004 --upgrade path: PDXL → PDXB rewrite (per R52 §4.5)
mkfs.pdxfs.M5-001 dual-signed manifest.pdxsig + CHANGELOG-1.0 + .pdxdoc for doc mkfs.pdxfs
mkfs.pdxfs.M5-002 mirror push to pkgs.paideia-os
```
(count: 18; trim in Round-2 refinement if needed, else keep as 18 — this tool has more discrete gates than most)

### §9.2 `mount.pdxfs` (paideia-os/mount.pdxfs) — 15 issues

**M1 — Design + skeleton.** Scaffold + caps.decl (KIND_USER, KIND_VOLUME placeholder, KIND_PDXFS_MOUNT_TABLE placeholder, KIND_ELEVATE_CHANNEL placeholder). Argv (`--ro`, `--noexec`, `--verbose`, `--dry-run`, `<volume-cap>`, `<mount-point>`). First runnable: `--dry-run` prints the mount record with `result_code: DRY_RUN`.

**M2 — Core implementation.** Real body: resolve volume cap → narrow via libpdx-volume.vol_kind_narrow → call sys_mount → append mount-table row. File-backed → root-only mount for smoke.

**M3 — Elevate + audit-first INTENT/RESULT + semantic-pipe.** Mount-point-class table (§4.2). Elevate on /system, /boot, /dev, /home/<other>. INTENT record before sys_mount, RESULT record after. `PdxFsMountRecord@0.1` schema bind. Failure-taxonomy encoding (§4.4).

**M4 — Tests + smoke.** Happy-path mount for each class (user, /mnt, /system-with-elevate, /home-other-with-elevate). Failure matrix (each of the 8 failure codes). --dry-run correctness. Elevate-timeout path. Sig-invalid rejection (mount a volume whose sig-key was rotated).

**M5 — Signed release.** Dual-signed manifest, .pdxdoc, mirror push.

**Issues:**
```
mount.pdxfs.M1-001 scaffold + caps.decl (KIND_USER + KIND_VOLUME + KIND_PDXFS_MOUNT_TABLE + KIND_ELEVATE_CHANNEL)
mount.pdxfs.M1-002 argv surface via libpdx-argv (--ro, --noexec, --verbose, --dry-run, <volume-cap>, <mount-point>)
mount.pdxfs.M1-003 first runnable: --dry-run prints PdxFsMountRecord with result_code: DRY_RUN
mount.pdxfs.M2-001 volume cap resolution + narrow via libpdx-volume.vol_kind_narrow
mount.pdxfs.M2-002 real sys_mount invocation + mount-table row append via KIND_PDXFS_MOUNT_TABLE
mount.pdxfs.M2-003 user-subtree mount path (no elevate; /home/$user + /mnt + /tmp)
mount.pdxfs.M3-001 mount-point-class table (§4.2) + libpdx-elevate integration for /system, /boot, /dev, cross-user
mount.pdxfs.M3-002 INTENT record before sys_mount + RESULT record after (shared audit_id)
mount.pdxfs.M3-003 semantic-pipe: PdxFsMountRecord@0.1 schema bind + emit
mount.pdxfs.M3-004 failure-taxonomy encoding (§4.4): map every kernel errno + policy-refusal to a distinct result_code
mount.pdxfs.M4-001 happy-path smoke: /mnt user-owned mount, no elevate
mount.pdxfs.M4-002 elevate-required smoke: /system mount with auto-approve policy + human-approve fallback
mount.pdxfs.M4-003 failure-matrix smoke: sig-invalid, journal-corrupt, already-mounted, mount-point-exists, no-permission
mount.pdxfs.M4-004 elevate-timeout path: request times out (30s default) → exit 4 with clean audit trail
mount.pdxfs.M5-001 dual-signed manifest.pdxsig + CHANGELOG-1.0 + .pdxdoc for doc mount.pdxfs
mount.pdxfs.M5-002 mirror push
```

### §9.3 `umount.pdxfs` (paideia-os/umount.pdxfs) — 15 issues

**M1 — Design + skeleton.** Scaffold + caps.decl (KIND_USER, KIND_PDXFS_MOUNT_TABLE, KIND_VOLUME, KIND_ELEVATE_CHANNEL placeholder). Argv (`--lazy`, `--force`, `--verbose`, `--dry-run`, `<mount-id | mount-point>`). First runnable: `--dry-run` on a mount-point prints the record.

**M2 — Core implementation.** Mount-point → mount_id resolution via libpdx-volume.mount_table_snapshot. Handle-count query via KIND_VOLUME.VOL_OP_QUERY_HANDLE_COUNT. IN_USE refusal path. Non-force happy path: cache flush → txn drain → CLEAN checkpoint → superblock re-sign+rewrite → row remove.

**M3 — --lazy + --force + audit-first + semantic-pipe.** --lazy path: mark row PENDING_UNMOUNT, return PENDING; DEFERRED completion record fires when handle count reaches zero (§5.4). --force path: elevate + handle-revoke. INTENT/RESULT audit records. `PdxFsUnmountRecord@0.1` schema bind.

**M4 — Tests + smoke.** Happy-path (no handles open). IN_USE refusal + audit trail. --lazy correctness (row transitions PENDING → UNMOUNTED after handle close). --force correctness (revoked handles listed in record). SIG_KEY_LOCKED refusal. --dry-run correctness.

**M5 — Signed release.** Dual-signed manifest, .pdxdoc, mirror push.

**Issues:**
```
umount.pdxfs.M1-001 scaffold + caps.decl (KIND_USER + KIND_PDXFS_MOUNT_TABLE + KIND_VOLUME + KIND_ELEVATE_CHANNEL)
umount.pdxfs.M1-002 argv surface via libpdx-argv (--lazy, --force, --verbose, --dry-run, <mount-id | mount-point>)
umount.pdxfs.M1-003 first runnable: --dry-run against a mount point prints PdxFsUnmountRecord
umount.pdxfs.M2-001 mount-point → mount_id resolution via libpdx-volume.mount_table_snapshot
umount.pdxfs.M2-002 KIND_VOLUME.VOL_OP_QUERY_HANDLE_COUNT wiring + IN_USE refusal (exit 5)
umount.pdxfs.M2-003 non-force happy path: cache flush + txn drain + CLEAN checkpoint + superblock resign+rewrite + row remove
umount.pdxfs.M3-001 --lazy path: PENDING_UNMOUNT flag + DEFERRED completion record on last handle close
umount.pdxfs.M3-002 --force path: libpdx-elevate + handle-revoke + revoked_handles list in record
umount.pdxfs.M3-003 semantic-pipe: PdxFsUnmountRecord@0.1 schema bind + emit (INTENT + RESULT + DEFERRED)
umount.pdxfs.M3-004 SIG_KEY_LOCKED refusal path (superblock cannot be re-signed → refuse without --force)
umount.pdxfs.M4-001 happy-path smoke: unmount /mnt with no open handles → volume clean
umount.pdxfs.M4-002 IN_USE refusal smoke: open handle blocks umount without --force / --lazy
umount.pdxfs.M4-003 --lazy correctness: umount deferred until last handle closes; DEFERRED record fires
umount.pdxfs.M4-004 --force correctness: revoked handles named in record; subsequent I/O returns EIO
umount.pdxfs.M5-001 dual-signed manifest.pdxsig + CHANGELOG-1.0 + .pdxdoc for doc umount.pdxfs
umount.pdxfs.M5-002 mirror push
```

### §9.4 `libpdx-volume` (paideia-os/libpdx-volume) — 12 issues

**M1 — Design + skeleton.** Scaffold + module boundary. `vol_kind_mint`, `vol_kind_narrow`, `pdxb_parse_superblock`, `pdxb_encode_superblock` stubs.

**M2 — Core parse + encode.** Full superblock parse (every offset in R52 §2.1) + encode (inverse). `mount_table_snapshot` reads KIND_PDXFS_MOUNT_TABLE and returns Vec<MountTableRow>.

**M3 — Signing helpers.** `pdxb_sign_superblock` via paideia-as mldsa65_sign intrinsic. Inode-tail signature helpers (used by future fsck.pdxfs).

**M4 — Tests + fuzz.** Parse-encode round-trip fuzz (10^5 random superblock field values → encode → parse → asserts equal). Sig-verify against a known-signed superblock. Mount-table-snapshot correctness with 1..7 rows.

**M5 — Signed release.** Dual-signed release, .pdxdoc, mirror push.

**Issues:**
```
libpdx-volume.M1-001 scaffold + module boundary (vol_kind_mint, vol_kind_narrow, pdxb_parse_superblock, pdxb_encode_superblock stubs)
libpdx-volume.M1-002 KIND_PDXFS_MOUNT_TABLE row-layout parser (matches R53-PREP-001)
libpdx-volume.M2-001 pdxb_parse_superblock: every offset in R52 §2.1 → PdxbSuperblockSummary
libpdx-volume.M2-002 pdxb_encode_superblock: inverse of parse; canonical byte layout
libpdx-volume.M2-003 mount_table_snapshot: read KIND_PDXFS_MOUNT_TABLE + return Vec<MountTableRow>
libpdx-volume.M2-004 vol_kind_narrow: narrow ops_mask on KIND_VOLUME (matches R52 op catalog)
libpdx-volume.M3-001 pdxb_sign_superblock via paideia-as mldsa65_sign intrinsic
libpdx-volume.M3-002 inode-tail sig helpers (used by future fsck.pdxfs; deferred consumer)
libpdx-volume.M4-001 parse-encode round-trip fuzz (10^5 random superblock field values)
libpdx-volume.M4-002 sig-verify against a known-signed superblock fixture
libpdx-volume.M4-003 mount_table_snapshot correctness matrix (0 rows, 1 row, 7 rows, full 8 rows)
libpdx-volume.M5-001 dual-signed release + .pdxdoc + mirror push
```

### §9.5 Wave summary

| Repo             | Issues | M1 opens after                            | M5 closes                                        |
|------------------|-------:|-------------------------------------------|--------------------------------------------------|
| libpdx-volume    | 12     | R53-PREP-000, R53-PREP-001                | Prereq for the three tools' M2                   |
| mkfs.pdxfs       | 18     | libpdx-volume.M1                           | Signed 1.0 shipped to pkgs.paideia-os            |
| mount.pdxfs      | 16     | libpdx-volume.M1 + R53-PREP-001            | Signed 1.0 shipped                                |
| umount.pdxfs     | 16     | libpdx-volume.M1 + R53-PREP-001 + R53-PREP-002 | Signed 1.0 shipped                            |
| Substrate prep   | 3      | (paideia-os main repo, before any tool)   | Blocks R53 wave gate                              |
| **Total**        | **65** |                                           |                                                  |

---

## 10. First end-to-end smoke

The wave's acceptance test — the QEMU-driven scenario that turns "the three tools exist" into "the three tools work" — is an eight-stage round-trip that mkfs+mount+cp+umount+reboot+cat exercises against a fresh 128 MiB QEMU-attached disk. Each stage lands a fingerprint line in `tests/r53/shell-shutdown.golden` (mirrors R48b golden discipline; osarch owns the boot fingerprints, R53 tools own the shell fingerprints).

### 10.1 Scenario

```
Stage 1: QEMU boot with --with-disk /tmp/blank.img (128 MiB, all zeros)
         Expected: kernel PDXB probe finds no valid superblock → drops into rescue shell
         Fingerprint: PDXFS PROBE NO_VOLUMES_FOUND
                     RESCUE_SHELL_READY

Stage 2: rescue> mkfs.pdxfs --label=root cap:blkdev:0x0002
         Expected: signs superblock, writes bitmap+journal+root inode, emits PdxFsFormatRecord
         Fingerprint: MKFS_PDXFS OK uuid=<hex> label=root signed=true
                     AUDIT UEJ_KIND_VOL_FORMAT ts=<ns>

Stage 3: rescue> pdx_probe --refresh                    # osarch tool, re-probes attached devices
         Expected: probe now finds a valid PDXB superblock, mints KIND_VOLUME
         Fingerprint: PDXFS PROBE FOUND uuid=<hex> cap=cap:volume:0x0001

Stage 4: rescue> mount.pdxfs cap:volume:0x0001 /mnt
         Expected: /mnt now backed by the volume; PdxFsMountRecord INTENT+RESULT emitted
         Fingerprint: MOUNT_PDXFS INTENT mount_point=/mnt volume=cap:volume:0x0001
                     MOUNT_PDXFS OK mount_id=<u64>
                     AUDIT UEJ_KIND_VOL_MOUNT ts=<ns>

Stage 5: rescue> cp /etc/hello /mnt/hello
         Expected: cp opens KIND_PDXFS_TXN, writes to real WAL, commits
         Fingerprint: CP OK txn_id=<u64> src=/etc/hello dst=/mnt/hello

Stage 6: rescue> umount.pdxfs /mnt
         Expected: cache flushed, journal CLEAN checkpoint, superblock re-signed, row removed
         Fingerprint: UMOUNT_PDXFS INTENT mount_point=/mnt
                     UMOUNT_PDXFS OK dirty_flushed=<n> journal_state=CLEAN
                     AUDIT UEJ_KIND_VOL_UNMOUNT ts=<ns>

Stage 7: reboot (QEMU restart, same --with-disk /tmp/blank.img)
         Expected: kernel PDXB probe now finds the volume; osarch's boot-time
                   auto-mount policy (if any is registered for this uuid) mounts it
         Fingerprint: PDXFS PROBE FOUND uuid=<same hex> clean_unmount=true
                     PDXFS VOLUME MOUNTED at boot /mnt volume=cap:volume:0x0001

Stage 8: rescue> cat /mnt/hello
         Expected: contents byte-identical to /etc/hello on the original boot
         Fingerprint: CAT OK bytes=<same as /etc/hello>
                     ROUND_TRIP OK
```

### 10.2 Failure modes each stage catches

- **Stage 2 fail** = mkfs.pdxfs bug (superblock encoder, signing, or bitmap init).
- **Stage 3 fail** = osarch probe not integrating with mkfs output (either magic mismatch or sig-verify failing).
- **Stage 4 fail** = mount.pdxfs bug or KIND_PDXFS_MOUNT_TABLE not landed.
- **Stage 5 fail** = R52 walker wire-through (mount points to real volume, but cp still hits stub backend).
- **Stage 6 fail** = journal-checkpoint discipline broken (dirty pages not flushed, or superblock's clean-unmount bit not set).
- **Stage 7 fail** = boot-time probe not respecting clean-unmount bit, or superblock signature was corrupted by umount's re-sign.
- **Stage 8 fail** = WAL replay missed a record, or CoW-tree corruption slipped past the checkpoint fence.

The end-to-end guarantee is exactly the R52.M8 round-trip smoke restated in R53's user-visible primitives.

---

## 11. What R53 does NOT do

- **LVM-style logical volumes.** One `KIND_BLOCK_DEVICE` per `KIND_VOLUME`. Splitting a device or spanning multiple devices under one volume is R55+ (per `design/filesystem/multi-device-pool.md`).
- **RAID.** No mirroring, no striping, no parity. Same deferral as multi-device pools.
- **Snapshots (persistence tooling).** R52 defers snapshot-region persistence to R54; a `snap.pdxfs create` / `snap.pdxfs restore` CLI wave lands with it.
- **Encryption-at-rest tooling.** No `mkfs.pdxfs --encrypt` at R53. When R54+ lands `KIND_KEK`, a follow-up flag adds it here.
- **Quotas.** `design/user/model.md`'s per-user `quota_bytes` field is applied at file-open time, not enforced through a volume-side quota-block; no volume-scoped quota tool ships here.
- **ACLs.** Capability model at `KIND_PDXFS_FILE` + `KIND_USER` supersedes; no `getfacl`/`setfacl`.
- **`fsck.pdxfs`.** A read-only scrub tool. Its scope is a wave of its own; libpdx-volume ships the parse helpers so a future fsck.pdxfs can link them, but no fsck CLI in R53.
- **`df` / `du`.** Space-reporting tools; deferred to R54 to accompany fsck.pdxfs. libpdx-volume ships `mount_table_snapshot` so a future df can enumerate mounts.
- **Compat FSes.** Never in-kernel; ext4/FAT importers as userspace `pkg install` at any future round, not this wave.
- **`mount --bind`, union mounts, overlays.** No union semantics at the mount table (R52's mount table is single-slot-per-path); a bind-mount tool would require a mount-table shape change deferred to R55+.

---

## 12. Coordination points for main

Two synchronisation points between this doc (softarch, user side) and osarch's parallel R53 half (QEMU wiring + `sys_mount`/`sys_umount` kernel bodies + boot-time PDXB probe + rescue-shell fallback). Both must land before R53.M1 opens.

### 12.1 Syscall ordinals

Softarch needs three ordinals in the syscall table:

- `sys_mount(vol_cap_slot: u16, mount_point_ptr: u64, mount_point_len: u32, flags: u32) → u64` — return is the mount_id on success, negative errno on failure. Called by mount.pdxfs.M2-002.
- `sys_umount(mount_id: u64, flags: u32) → u64` — return 0 on success, negative errno on failure. `flags` carries `UMOUNT_FLAG_LAZY` and `UMOUNT_FLAG_FORCE`. Called by umount.pdxfs.M2-003.
- `sys_pdxfs_query_handle_count(vol_cap_slot: u16) → u64` — return open handle count on the volume. Called by umount.pdxfs.M2-002 (implements KIND_VOLUME.VOL_OP_QUERY_HANDLE_COUNT).

**Recommendation.** Osarch allocates these in the R42-PREP ordinal band (currently 71 = sys_pdxfs_open, 72 = sys_pdxfs_dir_readnext per `design/user/pdxfs-kinds.md` §3.1). Softarch proposes 73 / 74 / 75 in that band; main reconciles with osarch's actual allocation. If osarch has already claimed those numbers for other ops, softarch shifts to the next contiguous triple and updates `libpdx-volume.M2-005` (a new issue) accordingly.

### 12.2 mkfs.pdxfs argv contract

Osarch's rescue-shell + boot-time init path (which is where the smoke's Stage 2 invocation actually runs) needs to know **exactly** what argv mkfs.pdxfs will accept, because the rescue shell may script mkfs before the shell itself has a full libpdx-argv-style completion layer. Softarch commits to the §3.1 argv shape:

```
mkfs.pdxfs [--force] [--label=<str>] [--journal-size=<n_blocks>] [--dry-run] [--verbose] [--sig-key=<key-cap-uri>] <target>
```

- Long-flags-only (short flags not accepted at R53; matches R49/R50 discipline).
- `<target>` is positional, always last, always required.
- Exit codes: 0=OK, 2=argv parse error, 3=system error (out of memory, sig-key intrinsic missing), 4=cap denied (no elevate), 5=data-integrity refusal (non-blank without --force, or signing failed).

Osarch's rescue shell writes its Stage-2 script against this contract at R53-PREP-001-osarch. Any post-M2 flag additions to mkfs.pdxfs land at M4 or later (never M2/M3), so the boot-time contract stays stable during the bring-up wave.

### 12.3 Not overlap points (osarch owns solo)

- **QEMU `--with-disk` wiring.** Osarch's tools/run-smoke.sh addition; softarch consumes it in the Stage-1 fingerprint but does not define it.
- **`KIND_BLOCK_DEVICE` mint semantics.** Osarch's R51 substrate; softarch narrows against it via libpdx-volume but does not redesign the mint.
- **Boot-time PDXB probe → rescue-shell fallback.** Osarch's boot-init path; softarch's tools run *after* the fallback is hit.
- **Auto-mount policy at boot.** If a founder registers "auto-mount volume uuid=X at /system", that policy lives in the osarch boot-init substrate. R53's mount.pdxfs is invoked interactively; the auto-mount case reuses mount.pdxfs's core logic but from a different call site (osarch's init service, not the shell). No shape difference.

---

## Appendix A — Repo inventory (four new public repos on landing R53)

| Repo                            | Wave | Purpose (one line)                                                             |
|---------------------------------|------|--------------------------------------------------------------------------------|
| `paideia-os/mkfs.pdxfs`         | R53  | Format a target with a fresh PDXB superblock + empty journal + root inode.     |
| `paideia-os/mount.pdxfs`        | R53  | Attach a KIND_VOLUME cap to a mount point via sys_mount, with elevate + audit.  |
| `paideia-os/umount.pdxfs`       | R53  | Detach a mount, drive journal CLEAN, remove mount-table row.                    |
| `paideia-os/libpdx-volume`      | R53  | Shared client-side superblock parse/encode/sign + mount-table snapshot library. |

---

## Appendix B — Discipline for landing a new volume-side tool

When R54 (or later) adds `fsck.pdxfs` / `df` / `du` / `snap.pdxfs`:

1. **Reuse `libpdx-volume`** for every PDXB-parse and every KIND_VOLUME/KIND_PDXFS_MOUNT_TABLE interaction. Never re-implement the superblock parser.
2. **Emit a `PdxFs<Verb>Record@<ver>` semantic record** on stdout with the standard `audit_id + invoker_user + ts_ns + result_code` skeleton.
3. **Follow the audit-first invariant** — journal via libpdx-audit *before* any user-visible output. For multi-stage ops, use INTENT/RESULT pairs (like mount.pdxfs); for one-shot ops, use `audit_begin` + `audit_commit` (like mkfs.pdxfs).
4. **Follow the mount-point-class table** for elevate discipline (§4.2). Do not add ad-hoc elevate policies; extend the table.
5. **Register a new UEJ_KIND** if the op is not already covered by UEJ_KIND_VOL_FORMAT/MOUNT/UNMOUNT. Retention policy: destructive-op-forever, non-destructive-op-30d.
6. **Update this document** with a §2 row + a §7 record schema + a §9 milestone block.

R53's three tools are the reference; a new tool copies the shape.
