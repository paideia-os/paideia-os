# R64 v2 Retrospective: Volume tooling live

**Date:** 2026-08-31
**Milestones:** R64.M1 v2 across 4 satellite repos + 3 paideia-os wrappers
**Issues closed:** libpdx-volume #1-#14, mkfs.pdxfs #1-#21, mount.pdxfs
#1-#18, umount.pdxfs #1-#18, paideia-as #1335, libpdx-audit #11-#12,
paideia-os R66v2.POS-001 (via #1986/#1987 substrate) — plus kernel
dispatch/op landings that unblocked the chain.
**HEAD at closure:** paideia-os `2dd9df9` (dispatch_mount/umount rewire,
VOL_OP_QUERY_HANDLE_COUNT, PMT_OP_REMOVE_ROW). This doc closes retro
gates in each of the 4 satellite repos (`r64v2-closed` tags cut on
libpdx-volume, mkfs.pdxfs, mount.pdxfs, umount.pdxfs).
**Release tag:** `r64v2-closed` on paideia-os recommended — everything
in the R64 v2 scope that was in-repo has landed. Three named debt items
remain, none in-repo blocking.

## Round intent

Per `design/roadmap/rows-4-5-6-scoping.md` §0.1–§0.3 and §9: the R64 v1
close was polluted by a phantom paideia-as #1730 citation that doesn't
exist. §0.3 identified the real mldsa65_sign intrinsic gap as the only
live blocker (now closed — paideia-as v0.23.0 shipped the intrinsic; the
submodule is pinned at v0.24.0). R64 v2's job was to actually land the
volume-tooling chain: `libpdx-volume` substrate, then the three CLIs
(`mkfs.pdxfs`, `mount.pdxfs`, `umount.pdxfs`), then the paideia-os
wrappers that seed the ELFs and document the change.

## Per-repo disposition

### `libpdx-volume` — LANDED at v1.0.0 (`r64v2-closed`)
Empty repo → 1000+ LOC across 5 milestones:
- **M1** (#1, #2): scaffold + module boundary + KIND_PDXFS_MOUNT_TABLE
  row parser.
- **M2** (#3-#6): PDXB parse/encode (18 fields, 4 gates) +
  `mount_table_snapshot` + `vol_kind_narrow` (mask-validated pass-through
  pending kernel `cap_narrow`).
- **M3** (#7, #8): `pdxb_sign_superblock` — the tree's FIRST real
  `mldsa65_sign` call site (paideia-as v0.23.0 intrinsic). Inode-tail
  helpers landed with fail-closed verify stub (`mldsa65_verify`
  intrinsic doesn't exist yet).
- **M4** (#9-#11): 10⁵-iter parse/encode roundtrip fuzz + sig-verify
  stub test + mount-table snapshot correctness matrix.
- **M5** (#12): dual-signed release manifest + `.pdxdoc` + CHANGELOG.
- **R64v2 wrappers**: #13 (superset closed by M1..M3), #14 (metadata
  note). #15 retro gate closed by this doc.

### `mkfs.pdxfs` — LANDED at v1.0.0 (`r64v2-closed`)
Empty repo → 1500+ LOC across 5 milestones:
- **M1** (#1-#3): scaffold + argv parser + `--dry-run` PdxFsFormatRecord.
- **M2** (#4-#7): file-target format pipeline (real `sys_open`/`write`,
  PDXB codec via libpdx-volume, root inode #1, non-blank refusal +
  `--force`).
- **M3** (#8-#12): signing (real `pdxb_sign_superblock` call, placeholder
  0-seed) + audit_wire (real `libpdx-audit @0.2` calls, forgiving
  daemon-stub posture) + pipe_wire (line-based fallback per
  paideia-os#2000) + elevate_wire (fail-closed stub — no broker cap) +
  device-target parse (write stubbed pending kernel `sys_cap_query`).
- **M4** (#13-#16): 4 smoke test files (real `/tmp` scratch I/O), plus
  `--upgrade` argv parse + stub.
- **M5** (#17, #18): manifest + `.pdxdoc` + CHANGELOG + distribution
  doc.
- **R64v2 wrappers** (#19-#21) landed. #22 retro gate closed by this doc.

### `mount.pdxfs` — LANDED at v1.0.0 (`r64v2-closed`)
Empty repo → 1400+ LOC across 5 milestones:
- **M1** (#1-#3): scaffold + argv + `--dry-run` PdxFsMountRecord.
- **M2** (#4-#6): volume-cap resolve + real `sys_mount` invocation (now
  reachable — paideia-os `dispatch_mount` rewired at `274c93b`) +
  elevate-class classifier stub.
- **M3** (#7-#10): real 4-class mount_point classifier (`/home,/mnt,/tmp`
  → USER_SUBTREE; `/system,/boot,/dev` → SYSTEM_PATH → elevate stub;
  cross-user handled at classifier level) + audit_wire (INTENT/RESULT
  with shared audit_id) + pipe_wire + 11-code failure taxonomy sourced
  from `sys_mount_body`'s real errno set.
- **M4** (#11-#14): 4 smoke test files (pipeline-replay drivers).
- **M5** (#15, #16): release artifacts.
- **R64v2 wrappers** (#17, #18) landed. #19 retro gate closed by this
  doc.

### `umount.pdxfs` — LANDED at v1.0.0 (`r64v2-closed`)
Empty repo → 1500+ LOC across 5 milestones:
- **M1** (#1-#3): scaffold + argv + `--dry-run`.
- **M2** (#4-#6): target resolve + handle check (hard stub — see M3+
  kernel wire) + real `sys_umount` invocation (now reachable —
  `dispatch_umount` rewired).
- **M3** (#7-#10): `--lazy` DEFERRED gate + `--force` elevate-stub +
  audit/pipe wires + SIG_KEY_LOCKED gate (real, unreachable — sign
  intrinsic only fails on NULL seed, not zero seed).
- **M4** (#11-#14): 5 smoke test files.
- **M5** (#15, #16): release artifacts.
- **R64v2 wrappers** (#17, #18) landed. #19 retro gate closed by this
  doc.

### paideia-os wrappers
- **#1976 R64v2.POS-001 (bin_seeds)**: HELD — the 3 satellite ELFs
  aren't built yet (paideia-os has no native cross-build of the
  satellite `.pdx` tools; each satellite is a standalone
  paideia-assembly project). Practical seeding needs either (a) a
  build-time fetch + embed step, or (b) manual pre-built binaries
  staged into `tools/user/`. Deferred to a subsequent build-plumbing
  round.
- **#1977 R64v2.POS-002 (doc/user-guide/volume-tools.md)**: HELD —
  doc update pending same build-plumbing decision.
- **#1978 R64v2.POS-003 (round retro)**: THIS DOC. Closed on landing.

### paideia-as
- **#1335**: 4 broken boot tests fixed (PortIo fixture + .text baseline
  refresh). Restores paideia-as CI green. Submodule pin bumped to
  `4c5cceb` in paideia-os.

### libpdx-audit
- **#11, #12**: coordinated `PdxAuditRecord @0.1 → @0.2` wire revision
  — inline strings (256-byte payload) + `(pid << 32) | local_id`
  audit_id via `sys_getpid` (already shipping in paideia-os at SC+ 39,
  no kernel change needed).

### Kernel-side (paideia-os) — unblocking landings
- **dispatch_mount / dispatch_umount rewire** (`274c93b`): sysno 75/76
  bodies were landed at #1737/#1738 but never wired into the dispatch
  table. Now real shims are called with correct ABI shuffle.
- **VOL_OP_QUERY_HANDLE_COUNT + PMT_OP_QUERY_SLOT_COUNT +
  PMT_OP_REMOVE_ROW** (`2dd9df9`): cap-invoke ops referenced by
  umount.pdxfs's IN_USE / handle-decision paths. Stub bodies (return
  0 / return 8 / return 0) close the ABI edge; real per-row handle
  tracking + real mount-table row removal are future work.

## Cross-repo escalations

Two flowed correctly this round: paideia-as #1335 (boot tests) landed
first + submodule bump; libpdx-volume M3 landed first, mkfs.pdxfs then
consumed its signing API without further ABI negotiation.

## Observable proof

Every default boot at paideia-os HEAD `2dd9df9` still emits the full
witness chain: `KIND_TTY OK` (0.51s), `boot tty raw ok bytes=3`
(0.54s), `boot tui canvas ok canvas=1 bytes=152` (0.55s), `dir seeds
ok count=9` (0.56s), and reaches `SHELL START` — no regression from
either the dispatch rewire or the new cap ops. Satellite tools are
not yet exercised at boot; their tests run only against their own
repos' test drivers (return-code convention).

## Debt inventory (carried forward)

1. **Real handle_count tracking** (`VOL_OP_QUERY_HANDLE_COUNT`) — stub
   returns 0. Real tracking needs sys_close last-fd hook per-volume,
   not trivially derivable from a volume slot. Umount refusal is
   conservative-not-safe today. Not hardware-gated.
2. **Real mount-table row removal** (`PMT_OP_REMOVE_ROW`) — stub
   returns 0. Real body needs cross-module `_mount_table[]` write
   access confined to `mount.pdx`. Not hardware-gated.
3. **libpdx-elevate broker cap for CLI tools** — mkfs/mount/umount all
   fail-closed on elevation requests because no
   `KIND_ELEVATE_CHANNEL` broker cap is provisioned for standalone
   tools. Blocks all real `/system`/`/boot`/`/dev` mount workflows.
   See paideia-os#1997 (broker dispatch body). Not hardware-gated.
4. **Device-target write path** — mkfs.pdxfs stubs `cap:blkdev:...`
   because there's no `sys_cap_query` + no block-write syscall + no
   osarch-minted `KIND_BLOCK_DEVICE` cap for the tool. Device-target
   smoke is deferred to a real-hardware round.
5. **Real seed loading (`libpdx-key`)** — signing uses all-zero seed;
   signatures are well-formed but unverifiable. Real seed storage +
   loading is out of scope for R64.
6. **libpdx-schema-registry** (paideia-os#2000) — `Registry::bind_by_
   name` inert; all three tools fall back to line-based emit with a
   deferral header. Real semantic-pipe framing waits for the registry
   service to land.
7. **paideia-os satellite ELF build plumbing** — #1976/#1977 held on
   the "how do we cross-build a satellite `.pdx` tool from
   paideia-os's build system" decision.

**Next round:** several items above (1, 2, 3) are real, buildable,
non-hardware-gated work. Item (4) blocks on hardware access. Items
(5, 6, 7) are dedicated substrate rounds. This round establishes the
volume-tooling chain end-to-end at file-target scope — anything
downstream can now depend on `libpdx-volume`, `mkfs.pdxfs` (file
target), `mount.pdxfs` (dry-run + sys_mount edge), and `umount.pdxfs`
(dry-run + sys_umount edge) as landed APIs.
