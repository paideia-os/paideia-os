# R90-XREPO.010 Retrospective: R42 PdxFS Syscall Substrate Live

**Date:** 2026-09-01
**Milestone:** R90-XREPO.010.M1 (single-milestone round; 8 sub-issues)
**Parent tracker:** paideia-os #1996 (R90-XREPO.002 R42 PdxFS syscall
substrate completion for satellite tool consumers).
**Plan pointer:** `design/round-retrospectives/r90-xrepo-wave3-plan.md`
§2.
**Closes:** paideia-os #2116 (this doc, plus the syscall-table refresh
and the consolidated pdxfs-syscalls.md reference).
**HEAD at closure:** paideia-os `3219699` (in-tree; this doc + the
syscall-table refresh + `design/kernel/pdxfs-syscalls.md` are the only
changes).
**Release tag recommendation:** none this round — one carried-forward
witness fix (#2115) remains; a `r90-xrepo-010-closed` tag becomes
appropriate once #2115's 3-scenario witness lands green.

---

## §1. What shipped — per-issue rundown (M1-001..M1-007)

### #2109 — R90-XREPO.010.M1-001 KIND_PDXFS_FILE `READ_BYTES` op — CLOSED

Landed at `147c1da`.

`kind_pdxfs_file.pdx` gained `PFF_OP_READ_BYTES = 7`: a multi-arg
cap-invoke op using a descriptor page (`op_arg[63:12] = desc_page_addr`,
`[11:8]` reserved, `[7:0] = opcode`). The 32-byte descriptor carries
`{offset, count, dst_ptr, dst_len_cap}`; the body bounds-clamps against
`dst_len_cap` + EOF and delegates to `tmpfs_read`. Rights gate:
`R_PDXFS_FILE_READ (0x001)`.

Boot witness `r90_xrepo_010_pdxfs_read_bytes.pdx` seeds a tmpfs file,
mints a KIND_PDXFS_FILE cap, invokes READ_BYTES, byte-compares.

Fingerprints firing: `pdxfs file read bytes ok [legacy: PDXFS FILE
READ BYTES OK] off=<off> len=<n>` (per-call) + `boot pdxfs read bytes
ok -- ino=<n> bytes=8` (witness rollup).

No new sysno — consumers hold KIND_PDXFS_FILE from `sys_pdxfs_open`
(sysno 71) and invoke through `sys_cap_invoke` (sysno 4).

### #2110 — R90-XREPO.010.M1-002 `sys_pdxfs_stat_by_inode` — CLOSED

Landed at `24bed63`. Sysno **106**.

32-byte output record `{mode_bits, size_bytes, mtime_ns, ctime_ns}`.
Mode synthesized from tmpfs type nibble: `S_IFREG|0o644 (0x81A4)` for
REG, `S_IFDIR|0o755 (0x41ED)` for DIR. `mtime_ns = _tick_count *
10_000_000` (UEJ convention). `ctime_ns` reserved zero.

Witness `r90_xrepo_010_002_stat_by_inode.pdx` cross-checks all four
fields against seed constants.

Fingerprints firing: `sys pdxfs stat by inode ok [legacy: SYS PDXFS
STAT BY INODE OK]` + `boot pdxfs stat ok -- ino=<n> size=<n>`.

`ls -l` column coverage delivered by this landing (with sysnos 71 +
72): mode / size / mtime. Owner / group / nlink still pending future
record-shape evolutions.

### #2111 — R90-XREPO.010.M1-003 `sys_pdxfs_txn_commit` / `sys_pdxfs_txn_abort` — CLOSED

Landed at `147c1da`. Sysnos **104** / **105**.

Commit path: `pdxfs_txn_row_of_slot` → `pdxfs_txn_commit_wal` (writes
`JOP_COMMIT` + `BD_OP_FLUSH` via the mounted volume's
KIND_BLOCK_DEVICE) → `pdxfs_txn_row_transition(OPEN → COMMITTED)` →
`PXT_ST_COMMITS++`.

Abort path: `pdxfs_txn_abort_wal` (writes `JOP_ABORT`) →
`pdxfs_txn_row_transition(OPEN → ABORTED)` → `PXT_ST_ABORTS++`. The
per-record undo-body replay wire-up landed one commit later at
`24bed63` (paired with M1-004 landing the substrate).

Witness `r90_xrepo_010_003_pdxfs_txn_lifecycle.pdx` runs both
scenarios (commit + abort) per boot.

Fingerprints firing: `sys pdxfs txn commit ok [legacy: SYS PDXFS TXN
COMMIT OK] txn=0`, `sys pdxfs txn abort ok [legacy: SYS PDXFS TXN
ABORT OK] txn=1`, `boot pdxfs txn lifecycle ok [legacy: BOOT PDXFS
TXN LIFECYCLE OK]`.

Two deferred sub-scopes captured in the handler headers:
- Row release + cap-slot clear on commit are deferred to a future
  `sys_pdxfs_txn_close` (§7 open follow-on).
- Idempotence on double-commit is by construction (state gate refuses
  a second commit with `-EINVAL`); the parent-issue "no crash"
  criterion is met via the state gate rather than an explicit
  fingerprint.

### #2112 — R90-XREPO.010.M1-004 `sys_pdxfs_undo_write` persistence — CLOSED

Landed at `24bed63`. Sysno **107**.

New substrate `src/kernel/core/fs/pdxfs/undo.pdx`: per-row 4 KiB undo
buffer + 32-record cap × 16 rows (one per KIND_PDXFS_TXN row); `.bss`-
resident. `pdxfs_txn_undo_append(row, inode, off, len, kbuf_ptr)` +
`pdxfs_txn_undo_replay(row)` (LIFO order, called from
`sys_pdxfs_txn_abort`).

Handler is a 5-arg body (SysV-shuffled by the dispatch shim) that
takes a KERNEL VA for `kbuf_ptr`; the dispatch shim performs the KPTI
bounce for user callers into a bounded per-call kernel scratch, while
boot witnesses pass `.rodata` pointers directly.

Witness `r90_xrepo_010_004_pdxfs_undo_write.pdx` runs the full recipe:
seed content A, `undo_write(A)`, overwrite with B, abort, assert
content == A after replay.

Fingerprints firing: `sys pdxfs undo write ok txn=0 len=16`, `sys
pdxfs undo replay ok txn=0 entries=1`, `boot pdxfs undo ok -- count=1`.

Closes the I5 invariant at the **syscall** layer for cp / mv / rm.
Crash-safety of undo records across boot is DEFERRED (see §5 below);
`.bss` residency loses staged pre-images across a crash between
`undo_write` and `abort`.

### #2113 — R90-XREPO.010.M1-005 `sys_pdxfs_fault_inject` — CLOSED

Landed at `c32e9e1`. Sysno **527** (out-of-band).

Four fault classes hooked into the substrate:
`WAL_WRITE_FAIL (1)` at `wal_append`, `INODE_ALLOC_FAIL (2)` at
`tmpfs_inode_alloc`, `EXTENT_ALLOC_FAIL (3)` at `tmpfs_write` (before
`phys_alloc`), `UNDO_APPEND_FAIL (4)` at `pdxfs_txn_undo_append`.
Class 0 disarms; single-shot semantics (an arm is consumed by the
next traversal of the named site).

Boot flag `_pdxfs_fault_enabled`: refuses to arm with `-EPERM` when
zero (release-build gate; `pdxfs_fault_enable()` called from
`kernel_main` immediately before the witness at every build today —
release-mode enforcement deferred).

Dispatch out-of-band: explicit `cmp rdi, 527 / je
dispatch_pdxfs_fault_inject` before the linear `cmp rdi, 107 / ja
dispatch_enosys` bounds gate. Rationale documented in
`design/kernel/pdxfs-fault-inject.md` §5.

Witness `r90_xrepo_010_005_pdxfs_fault_inject.pdx` arms + fires
WAL_WRITE_FAIL + INODE_ALLOC_FAIL, observes fired-then-cleared.

Fingerprints firing: `sys pdxfs fault inject armed class=1`, `sys
pdxfs fault fired class=1`, `sys pdxfs fault inject armed class=2`,
`sys pdxfs fault fired class=2`.

### #2114 — R90-XREPO.010.M1-006 Real multi-entry readdir — CLOSED

Landed at `24bed63`. Sysno **72** (existing — replaces stub body; no
new number).

`pdxfs_dir_iter.pdx` grew from the 3-entry hard-coded stub (R42-PREP-
008 #1630) to a real tmpfs child-chain walker. u16 cursor, per-row
counter, EOD-first + EOD-silent paths (a trailing poll returns 0
without re-emitting the `rows=<n>` fingerprint). Cursor field
persisted in the KIND_PDXFS_DIR row via `mov_w` with base+disp
addressing (paideia-as has no proven `mov_w` indexed store).

Record layout unchanged (128-byte `{inode, kind, name_len,
name[..32]}`); readnext contract identical to the stub. Name-len
capped at `PDXFS_DIR_TMPFS_NAME_MAX = 32`.

Witness (existing readnext witness) fires `sys pdxfs readdir ok
[legacy: SYS PDXFS READDIR OK] rows=<n>` once per EOD-first
transition. A separate 5-entry scenario in the M1-006 landing seeds
5 REG files, asserts first-EOD `rows=5`.

### #2115 — R90-XREPO.010.M1-007 `sys_cwd_resolve` body (sysno 517) — OPEN (witness partial)

Design half landed at `13a279c` (Option A frozen in `design/user/
cwd-semantics.md`). Body landed at `3219699`. Sysno **517**
(out-of-band).

Body reads user `path_ptr` via the dispatch shim's KPTI bounce,
resolves via `mount_root_vnode` + `path_resolve` against fresh
`[_current_tcb + TASK_OFF_CWD]` per the Option-A rule, composes the
canonical absolute form via a parent-chain walk (leading `/` +
`_vnode_name_table` components joined by `/`), writes NUL-terminated
to `abs_out_ptr` (up to `abs_out_cap` bytes). `SYS_CWD_RESOLVE_MAX_
DEPTH = 32`. Returns strlen (excluding NUL). The `path_len_hint`
field the earlier design skeleton proposed was dropped — the walker
sizes the path via NUL.

**Witness partial (#2115 stays OPEN).** The 3-scenario witness
`r90_xrepo_010_007_cwd_resolve.pdx` takes the SKIP branch after
scenario 1 (skip reason=1 stage=2) — **1 of 3 scenarios actually
runs**. The body itself is green: `sys cwd resolve ok len=2` fires
on the one scenario that runs. The two skipped scenarios need
diagnostic follow-on before #2115 can close; see §7.

Dispatch out-of-band: explicit `cmp rdi, 517 / je
dispatch_cwd_resolve` before the linear bounds gate, ordered before
sysno 527 to keep the ascending numeric order the rest of the switch
chain follows.

---

## §2. New syscalls landed by this round

Five new sysnos landed to the linear dispatch chain, plus two
out-of-band reservations went LIVE:

| # | Name | Landed by |
|---|------|-----------|
| 104 | `sys_pdxfs_txn_commit` | R90-XREPO.010.M1-003 (#2111) |
| 105 | `sys_pdxfs_txn_abort`  | R90-XREPO.010.M1-003 (#2111) |
| 106 | `sys_pdxfs_stat_by_inode` | R90-XREPO.010.M1-002 (#2110) |
| 107 | `sys_pdxfs_undo_write` | R90-XREPO.010.M1-004 (#2112) |
| 517 | `sys_cwd_resolve` (out-of-band; body green, witness partial) | R90-XREPO.010.M1-007 (#2115) |
| 527 | `sys_pdxfs_fault_inject` (out-of-band) | R90-XREPO.010.M1-005 (#2113) |

**Total new sysnos: 6** (four contiguous, two out-of-band).

**Cross-round context (not owned by this round but landed on the same
smoke boot):**

- sysno 96 remains a `sendto` reservation (per `design/networking/
  r91-plan.md` §17) — not yet implemented.
- sysno **103** = `sys_icmp_echo` landed one commit earlier at
  `477beb6` under R100-PREP-003 (#2009). Not part of R90-XREPO.010's
  scope, but shows up between the pre-existing dispatch bounds
  (previously 95) and the R90-XREPO.010 additions (104..107). The
  bounds widening for R90-XREPO.010 rides on the 95→103 widening that
  R100-PREP-003 already performed.

**Prompt cross-check note.** The task briefing listed sysno 96 as
`icmp_echo`; the source of truth in `dispatch.pdx` and `syscall-table.
md` places `icmp_echo` at sysno **103**, and sysno 96 remains reserved
for `sendto`. This retrospective goes with the source of truth.

---

## §3. New KIND ordinals

**None added by this round.** R90-XREPO.010 is a syscall-substrate
round; every landing extends kernel-side FS and syscall dispatch, not
the capability-kind catalogue.

For cross-round context on kind churn observed on the same smoke boot
(neither owned nor blocked by this round):

- `KIND_TLS_TRUST = 0x1A7` landed at R100-PREP-001 (#2007, commit
  `cdf582d`) — supersedes the pre-existing R91.M1-001 `KIND_NIC`
  placeholder at that ordinal.
- `KIND_NIC = 0x1AD` landed at R91.M1-001 (#2011, commit `c32e9e1`,
  same commit as this round's M1-005) — reallocated to the next free
  tag past the R91–R99 networking reservation block.

Both are recorded in `design/architecture/next-wave-derived-kinds.md`
(0x1A7 and 0x1AD entries) under their own rounds.

---

## §4. New fingerprints (`X ok [legacy: X OK]` texts)

Every fingerprint below is emitted on the default smoke boot at
paideia-os `3219699` unless otherwise flagged. Grouped by sub-issue.

### From M1-001 (KIND_PDXFS_FILE READ_BYTES)

- `pdxfs file read bytes ok [legacy: PDXFS FILE READ BYTES OK]`
  (`tag_pdxfs_file_read_bytes_ok`; `kind_pdxfs_file.pdx`).
- `boot pdxfs read bytes ok --` (`tag_boot_pfrb_ok`; witness).
- `boot pdxfs read bytes fail` (`tag_boot_pfrb_fail`; witness failure
  path — legacy-uppercase not applicable, no `OK` token).

### From M1-002 (stat_by_inode)

- `sys pdxfs stat by inode ok [legacy: SYS PDXFS STAT BY INODE OK]`
  (`tag_sys_pdxfs_stat_by_inode_ok`).
- `boot pdxfs stat ok --` (`tag_boot_pdxfs_stat_ok`).

### From M1-003 (txn_commit / txn_abort)

- `sys pdxfs txn commit ok [legacy: SYS PDXFS TXN COMMIT OK]`
  (`tag_sys_pdxfs_txn_commit_ok`).
- `sys pdxfs txn abort ok [legacy: SYS PDXFS TXN ABORT OK]`
  (`tag_sys_pdxfs_txn_abort_ok`).
- `boot pdxfs txn lifecycle ok [legacy: BOOT PDXFS TXN LIFECYCLE OK]`
  (`tag_boot_pdxfs_txn_lc_ok`).

### From M1-004 (undo_write)

- `sys pdxfs undo write ok [legacy: SYS PDXFS UNDO WRITE OK]`
  (`tag_sys_pdxfs_undo_write_ok`).
- `sys pdxfs undo replay ok [legacy: SYS PDXFS UNDO REPLAY OK]`
  (`tag_sys_pdxfs_undo_replay_ok`).
- `boot pdxfs undo ok --` (`tag_boot_pdxfs_undo_ok`).

### From M1-005 (fault_inject)

- `sys pdxfs fault inject armed [legacy: SYS PDXFS FAULT INJECT
  ARMED]` (`tag_sys_pdxfs_fault_inject_armed`).
- `sys pdxfs fault fired [legacy: SYS PDXFS FAULT FIRED]`
  (`tag_sys_pdxfs_fault_fired`).
- `boot pdxfs fault inject ok --` (`tag_boot_pdxfs_fault_inject_ok`).

### From M1-006 (real readdir)

- `sys pdxfs readdir ok [legacy: SYS PDXFS READDIR OK]`
  (`tag_sys_pdxfs_readdir_ok` in `pdxfs_dir_iter.pdx`) — the
  fingerprint text is unchanged from the stub landing; the body
  behind it changed.

### From M1-007 (cwd_resolve — body green; witness partial)

- `sys cwd resolve ok [legacy: SYS CWD RESOLVE OK]`
  (`tag_sys_cwd_resolve_ok`) — fires per successful body invocation.
- `boot cwd resolve ok --` (`tag_boot_cwd_resolve_ok`) — witness
  rollup; fires on the one scenario that currently runs.

**Total new `X ok [legacy: X OK]` fingerprints:** 10 (10 per-call /
witness pairs, minus the readdir re-use = 10 net texts). All are
allowlist-clean per `tools/verify-fingerprint-coverage.sh` (checked
against `24bed63` + `c32e9e1` + `3219699` diffs).

---

## §5. Deferred sub-scopes (per-issue accounting)

Every closed sub-issue closed a scoped piece of work; several bounded
follow-on scopes were explicitly deferred inside the handler headers
or design docs. Consolidated here so a satellite consumer knows the
sharp edges.

- **#2109 (READ_BYTES).** A sysno-shaped wrapper `sys_pdxfs_read` is
  NOT introduced by this landing — consumers hold the KIND_PDXFS_FILE
  cap already and reach the op via `sys_cap_invoke`. A future
  syscall-shaped wrapper is an ergonomic ask, not a functional gap.
- **#2110 (stat_by_inode).** Three of the six `ls -l` columns
  delivered; owner / group / nlink await future output-record-shape
  evolutions. `ctime_ns` reserved zero at this landing.
- **#2111 (txn_commit / txn_abort).**
  - Row release + cap-slot clear on commit deferred to a future
    `sys_pdxfs_txn_close` (see §7).
  - Idempotence on double-commit is by state gate (`-EINVAL`), not by
    a "already committed" fingerprint.
- **#2112 (undo_write).** Crash-safety of the undo records is
  DEFERRED. Records live in kernel `.bss`; a crash between
  `undo_write` and `abort` loses staged pre-images. Widening to fold
  undo into the PdxFS journal is a follow-on (see §7).
- **#2113 (fault_inject).**
  - Cross-boot persistence of an arm — deferred (matches undo-log's
    `.bss` posture).
  - Multi-class arm (bitfield of armed classes) — deferred to the
    first caller that needs to force two failure classes in one op.
  - `PAIDEIA_FAULT_INJECT=1` cmdline / build-mode gate for
    `pdxfs_fault_enable()` — deferred to a release-mode enforcement
    pass.
- **#2114 (readdir).**
  - Widening the 128-byte readnext record beyond `{inode, kind,
    name_len, name[..32]}` — deferred until a real consumer needs
    the extra columns; the M1-002 stat path took the widen-only-
    inside-stat branch by design.
  - Directory `..` and `.` synthesis for readdir — not yet spec'd as
    an on-chain entry; consumer path resolvers handle `.` / `..`
    already via `path_resolve` fast-paths.
- **#2115 (cwd_resolve).**
  - **3-scenario witness partial** (see §7): 1 of 3 scenarios
    currently runs; the two skipped need diagnostic follow-on. #2115
    stays OPEN pending witness fix. The body itself is green.
- **#2116 (this doc).** No functional deferral. Consolidated docs
  land clean.

---

## §6. Downstream unblock inventory

Satellites now able to proceed on the R90-XREPO.010 substrate:

| Consumer | Sub-issue enabled | Was blocked on |
|----------|-------------------|----------------|
| `doc` — `doc.ENH-022` `file_read_stub` → real read | M1-001 (READ_BYTES) | file-content read via KIND_PDXFS_FILE |
| `cat` — full file read (last kernel-side constraint lifted) | M1-001 (READ_BYTES) | same as above |
| `ls` — `ls -l` mode/size/mtime columns | M1-002 (stat_by_inode) | 3 of 6 `ls -l` columns still awaited a stat call |
| `cp` — `cp.ENH-002/003/007` partial-txn rollback proofs | M1-003 + M1-004 + M1-005 | txn lifecycle + undo persistence + controlled-failure harness |
| `mv` — `mv.ENH-003` undo semantics; `mv.ENH-001` stack-imbalance-under-fault harness | M1-003 + M1-004 + M1-005 | same as cp |
| `rm` — `rm.ENH-005` partial-txn rollback proof | M1-003 + M1-004 + M1-005 | same as cp |
| `ls` (recursive) / `cp -r` / recursive traversals | M1-006 (real readdir) | 3-entry stub prevented iteration beyond three names |
| `mv` / `rm` / `cp` relative-path resolution consistency | M1-007 design (Option A frozen) | design ambiguity — every satellite can code against the invariant today even before sysno 517's witness fully greens |
| Every path-touching consumer needing realpath | M1-007 body | no realpath primitive |

Note the layering: the design half of M1-007 already unblocks satellite
work (they can code against the frozen Option-A rule), while the body-
plus-witness half unblocks a syscall-driven realpath call. A satellite
depending on the body's fingerprint may want to wait for the #2115
witness fix (§7) before treating sysno 517 as smoke-green.

---

## §7. Open follow-ons

Sub-issue-adjacent work explicitly not landed in R90-XREPO.010 that
belongs on the next-round backlog before satellite consumers push
harder against this substrate:

1. **#2115 3-scenario witness fix (OPEN).** The
   `r90_xrepo_010_007_cwd_resolve.pdx` witness takes SKIP after
   scenario 1 (skip `reason=1 stage=2`). The body is green
   (fingerprint fires on the one scenario that runs), but two of the
   three planned scenarios (relative `foo`, `./foo`, `sub/foo` — the
   parent-issue-required diversity check) do not currently exercise
   the body. Follow-on scope: diagnose the SKIP branch, un-gate
   scenarios 2 + 3, land a green boot with `rows=3` (or equivalent
   scenario-count fingerprint). Closes #2115.

2. **`sys_pdxfs_txn_close` (NEW ISSUE — recommended).** Both the
   `sys_pdxfs_txn_commit` (sysno 104) and `sys_pdxfs_txn_abort`
   (sysno 105) bodies leave the KIND_PDXFS_TXN row + cap slot in
   place after the state transition. A satellite consumer running
   many txns in sequence eventually exhausts the 16-row pool. The
   scope: add a `sys_pdxfs_txn_close(cap_slot)` (proposed sysno 108)
   that releases the row and zeros the cap slot; refuse
   `-EINVAL` on a row still OPEN. Sizing: single-arg, one new
   dispatch case, one new fingerprint. File as R90-XREPO.010's first
   follow-on sub-issue.

3. **Undo-log crash safety (widening).** Fold `undo_write` records
   into the PdxFS journal so a crash between `undo_write` and `abort`
   does not lose staged pre-images. Documented as deferred in
   `sys_pdxfs_undo_write.pdx` header + `r90-xrepo-wave3-plan.md` §2's
   "log format documented in design; readback is deferred to a
   future round". File as a follow-on when a satellite consumer
   actually needs crash-safe undo (cp / mv / rm at their current
   maturity accept the `.bss` posture).

4. **Fault-inject release-mode gate.** `pdxfs_fault_enable()` is
   called unconditionally from `kernel_main` today; a follow-on that
   reads a `PAIDEIA_FAULT_INJECT=1` cmdline arg or a
   `_kernel_build_mode == 0` check gates the enable off in release
   builds. Documented in `design/kernel/pdxfs-fault-inject.md` §3.

5. **`sys_pdxfs_read` sysno-shaped wrapper (ergonomic ask).** A
   direct-sysno wrapper over `PFF_OP_READ_BYTES` would let a
   consumer call `sys_pdxfs_read(fd, buf, count)` in the standard
   `read(2)` shape without minting a KIND_PDXFS_FILE cap and
   invoking through `sys_cap_invoke`. Not strictly needed — every
   consumer today can reach the op — but reduces the boilerplate
   `cat` / `doc` currently ship.

---

## §8. Observable proof

The full R90-XREPO.010 fingerprint set fires on every default boot at
paideia-os `3219699`, ordered by witness dispatch order in
`kernel_main`:

1. `pdxfs file read bytes ok ... off=<off> len=8`
2. `boot pdxfs read bytes ok -- ino=<n> bytes=8`
3. `sys pdxfs txn commit ok ... txn=0`
4. `sys pdxfs txn abort ok ... txn=1`
5. `boot pdxfs txn lifecycle ok ...`
6. `sys pdxfs stat by inode ok ...`
7. `boot pdxfs stat ok -- ino=<n> size=<n>`
8. `sys pdxfs undo write ok ... txn=0 len=16`
9. `sys pdxfs undo replay ok ... txn=0 entries=1`
10. `boot pdxfs undo ok -- count=1`
11. `sys pdxfs fault inject armed class=1`
12. `sys pdxfs fault fired class=1`
13. `sys pdxfs fault inject armed class=2`
14. `sys pdxfs fault fired class=2`
15. `boot pdxfs fault inject ok -- count=2`
16. `sys cwd resolve ok len=2` (scenario 1 only — see §7)
17. `boot cwd resolve ok --` (scenario 1 only — see §7)

Plus the pre-existing `sys pdxfs readdir ok rows=<n>` fingerprint,
now backed by the real M1-006 body (5-entry seed scenario asserts
`rows=5`).

---

## §9. Cross-repo escalations

None found for this round. Every landing was monorepo-side. The
paideia-as toolchain hit two encoder-conservative asks in-flight
that were handled inline without a paideia-as round-trip:

- `PDX_STR` extractor requires `let ... = "..."` on ONE line
  (softarch split in an intermediate iteration produced a stale
  allowlist; fixed inline).
- `M0305` rejects PascalCase module names with pure-digit segments —
  two witness modules renamed
  (`R90Xrepo010PdxfsReadBytes` → `R90XrepoPdxfsReadBytes`;
  `PdxfsTxnLifecycleWitness` → `R90XrepoPdxfsTxnLifecycle`).

Both are documented in the M1-001/M1-003 commit message tail
(`147c1da`); neither warrants a paideia-as issue at this maturity —
they are naming discipline the paideia-os side now understands and
applies consistently.

---

## §10. References

- `design/round-retrospectives/r90-xrepo-wave3-plan.md` §2 — the
  R90-XREPO.010 plan this round executed against.
- `design/kernel/pdxfs-syscalls.md` — consolidated PdxFS syscall
  reference produced by #2116 (this round).
- `design/user/syscall-table.md` — refreshed by #2116 to include
  every new sysno.
- `design/user/cwd-semantics.md` — frozen Option-A anchor rule
  (M1-007 design half).
- `design/kernel/pdxfs-fault-inject.md` — full fault-injection
  deep dive (M1-005).
- paideia-os commits: `147c1da` (M1-001 + M1-003), `24bed63` (M1-002 +
  M1-004 + M1-006), `c32e9e1` (M1-005 + R91.M1-001 co-landed),
  `3219699` (M1-007 body + R91.M1-002 co-landed), `13a279c` (M1-007
  design half).
- paideia-os issues: #2109 (CLOSED), #2110 (CLOSED), #2111 (CLOSED),
  #2112 (CLOSED), #2113 (CLOSED), #2114 (CLOSED), #2115 (OPEN —
  witness partial), #2116 (this doc).
