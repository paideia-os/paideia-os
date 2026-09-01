# R65 v2 Retrospective: /home/operator persistent-mount pipeline

**Date:** 2026-09-01
**Milestone:** R65v2.M1 (7 issues, paideia-os #1979–#1985)
**HEAD at closure:** paideia-os (this landing) — builds on `2dd9df9`
(R64v2 volume-tooling close: `libpdx-volume`/`mkfs.pdxfs`/`mount.pdxfs`/
`umount.pdxfs` v1.0.0, `dispatch_mount`/`dispatch_umount` rewire).
**Release tag:** `r65v2-closed` on paideia-os.

## Round intent

R65 v1's own design doc (`design/user/persistent-home.md`, pre-rewrite)
closed with everything past its §3 (envp) marked design-only, deferred
behind the R64 volume-tooling chain. That chain closed for real in
R64v2 (`design/round-retrospectives/r64-closure-v2.md`): `libpdx-volume`,
`mkfs.pdxfs`, `mount.pdxfs`, `umount.pdxfs` all shipped v1.0.0, and the
kernel's `dispatch_mount`/`dispatch_umount` wire (`274c93b`) plus the
`VOL_OP_QUERY_HANDLE_COUNT`/`PMT_OP_QUERY_SLOT_COUNT`/`PMT_OP_REMOVE_ROW`
cap-op stubs (`2dd9df9`) unblocked the ABI edge. R65v2's job was to
actually spend that substrate: wire init's boot-time probe + mount, wire
the shell's chdir-on-entry, and build the two-phase persistent-home
smoke the R65 v1 doc had only sketched — while also fixing a phantom-
landing discrepancy the R65 v1 doc itself introduced (see #1979 below).

## Per-issue disposition

### #1976 R64v2.POS-001 (bin_seeds) — LANDED (prior round)
Closed by `design/round-retrospectives/r64-closure-v2.md`. Recapped
here only because R65v2.M1-001 (#1979) directly depends on it: the
`/bin/mkfs.pdxfs` and `/bin/mount.pdxfs` tmpfs seeds this issue landed
are exactly what makes the new `boot_r65_persistent_home` smoke able to
exec those tools from the shell at all.

### #1977 R64v2.POS-002 (doc/user-guide/volume-tools.md) — LANDED (prior round)
Closed by `design/round-retrospectives/r64-closure-v2.md`. No R65v2
dependency beyond the general volume-tool documentation baseline it
established.

### #1978 R64v2.POS-003 (round retro) — LANDED (prior round)
`design/round-retrospectives/r64-closure-v2.md` itself. Superseded as
"the most recent retro" by this document, not amended.

### #1979 R65v2.M1-001 (init.pdx probe + mount) — LANDED
`src/user/init.pdx` extended after the existing `rootfs_seed_run` call
and before the first fork+exec:

- Two `sys_stat` probes (`/var/pdxfs/home.img` file target, `/dev/nvme0`
  device target), both always run so the device-over-file priority rule
  can see both results before choosing.
- On either present: `sys_mount(src, mp="/home/operator", backend_id=5)`.
  On success (`rax < 8`): one of two fixed fingerprint lines fires
  (`init home mount ok [legacy: INIT HOME MOUNT OK] -- src=<path>
  mp=/home/operator backend=PDXFS_BLOCK`). On failure or absence: silent
  fallback to tmpfs — never boot-blocking.
- **Also landed, as a necessary correction, not scope creep:** the R65
  v1 design doc claimed `_init_envp`/`HOME=/home/operator` envp wiring
  (R65.M1-002, #1918) was already real. It was not — `src/user/init.pdx`
  had no such construction and passed `envp=NULL` at all three execve
  sites. Without it, #1981's shell chdir-on-entry would have had nothing
  to read and would have been a permanent no-op. This landing completes
  the envp wiring for real: `_init_envp` populated once at `_start`, all
  three execve sites (`/bin/child_hello`, `/bin/sh`,
  `/bin/elevate_broker_daemon`) now load real `rdx`.
- **Also landed:** the `sys_stat` and `sys_mount` userland syscall
  trampolines in `src/user/syscall_shim.pdx` — neither existed before
  this round. `sys_mount`'s arity-5 SysV→SYSCALL shuffle required
  reverse-engineering `entry.pdx`'s own register shuffle (`mov r8, r10;
  mov rcx, rdx; mov rdx, rsi; mov rsi, rdi; pop rdi`) against
  `dispatch_mount`'s landed shape to discover that the 5th argument
  (`backend_id`) must ride in raw `r9`, not the SysV-conventional `r8`
  — `r8` gets clobbered mid-shuffle before dispatch ever reads it.
- Fingerprint allowlisted in `tools/verify-fingerprint-coverage.sh`:
  fires only when a target is present AND `sys_mount` succeeds, neither
  of which holds on the default tmpfs boot (see #1980's disposition for
  why `sys_mount` itself still refuses).

### #1980 R65v2.M1-002 (device-target upgrade path) — LANDED (as code, tracked as debt upstream)
Metadata issue: no separate implementation task existed to close beyond
what #1979 already landed. The device-over-file preference *code* is
real (§2 step 3 of the persistent-home.md rewrite). What remains
genuinely deferred is everything upstream of that preference: there is
no devfs in this tree, so `/dev/nvme0` never actually resolves as a
path, and `sys_mount`'s own `backend_id=5` arm is an unconditional
`UNIMPL` stub (`sys_mount.pdx`) pending a dev-path→`bdev_cap` resolver.
Both are R51/R52 scope, not R65v2 scope. Documented in
`design/user/persistent-home.md` §2.1/§6 per this issue's own ask.

### #1981 R65v2.M1-003 (shell chdir-on-entry) — LANDED
`src/user/shell.pdx`'s `_start` captures `envp` (rdx) as its very first
instruction (before the entry-witness `sys_debug_puts` can clobber it),
then — after `dispatch_init`, before the first prompt — scans up to 16
`envp` entries for a `HOME=` prefix (byte-compare via the codebase's
established `xor+mov_b` zero-extension idiom) and calls the real
`sys_chdir` (sysno 85, R86.M1-002 #1955) on a match. No fingerprint: a
scan miss or a failed `sys_chdir` both leave the shell at `/`, which is
already `task_new`'s own default (R86.M1-006, #1959) — there is nothing
to explicitly fall back to, and `sys_chdir`'s own existing success
fingerprint already proves a real hit. The R65 v1 plan's intended
`shell cwd init ok` fingerprint is dropped as redundant (documented in
the persistent-home.md rewrite §4) rather than landed as originally
sketched.

### #1982 R65v2.M1-004 (boot smoke) — LANDED, Phase 1 only
`tools/run-smoke.sh`'s new `boot_r65_persistent_home` mode, real
ring-3 exercise through the interactive shell (same shape as
`boot_r64v2_tools`/`boot_r86_relative_path`): `mkdir /home`, `mkdir
/home/operator` (neither directory is tmpfs-seeded by default — a
tree-wide grep of `rootfs_seed.pdx`/`bin_seeds.pdx`/
`rootfs_dir_seeds.pdx` confirms only `/bin`, `/etc`, `/tmp`, `/share`,
`/pkgs`, `/system`, `/journal` are seeded), `mkfs.pdxfs --dry-run
/var/pdxfs/home.img`, `mount.pdxfs --dry-run cap:volume:0x0001
/home/operator`, `touch /home/operator/probe.txt`, `exit`. Golden
(`tests/r65v2/expected-persistent-home-phase1.golden`) asserts both
`sys mkdir ok` occurrences, both tools' dry-run preview fragments
(`PdxFsFormatRecord@0.1 { target: ...`, `PdxFsMountRecord@0.1 { volume:
...`, `result_code: DRY_RUN }`), and the final `REAPED`.

**Phase 2 (reboot, read `/home/operator/probe.txt` back, assert
contents survived) is not implemented at all** — not merely gated
behind an env var, unlike everything else in this milestone. Under
tmpfs there is no way for a second QEMU boot to observe the first
boot's writes (no `--with-disk`-shaped backing image exists for tmpfs
the way it does for PDXB in `boot_r53_round_trip_phase1/phase2`), so a
literal Phase 2 implementation today would be a permanently-failing
assertion — a red smoke forever, not a regression signal. Deferred
whole to R51/R52, when a real pdxfs-block rootfs makes a genuine
two-phase harness buildable.

### #1983 R65v2.M1-005 (pre-push gate) — LANDED
`tools/pre-push`'s `PAIDEIA_R65_PERSIST=1` opt-in gate running
`boot_r65_persistent_home`, mirroring the `PAIDEIA_R53_DISK` /
`PAIDEIA_R86_CWD` opt-in shape exactly (same "why opt-in, not default
matrix" rationale: this smoke's entire point is a target the default
tmpfs-rootfs 14-mode matrix does not have).

### #1984 R65v2.M1-006 (persistent-home.md rewrite) — LANDED
`design/user/persistent-home.md` fully rewritten: §2 (mount-at-boot
path) now describes real code with a new §2.1 explaining exactly why
`sys_mount` still fails today (an honest, load-bearing distinction —
the probe's fallback is the *expected*, exercised outcome, not an
untested edge case); §3 (envp) corrected to describe what's actually in
the tree, including the phantom-landing note; §4 (shell chdir)
rewritten to describe the real scan+chdir logic and explains why the
originally-planned fingerprint was dropped; §6 (honest scope block)
restructured into three tiers — real-and-reachable, real-but-currently-
unreachable-by-design, and genuinely-deferred — so a reader cannot
mistake "the code exists" for "the behavior fires on a normal boot."
No remaining phantom `#1730` citations in this file (verified by
re-reading the full rewrite; the historical citation is preserved only
inside the explanatory dependency-chain diagram in §2.2, correctly
framed as a fixed historical event, not a live blocker).

### #1985 R65v2.M1-007 (round retro + tag) — THIS DOC
Closes the round. `r65v2-closed` tag cut on paideia-os at this commit.

## Debt inventory (carried forward)

1. **`sys_mount`'s `backend_id=5` dev-path resolver** — `sys_mount.pdx`'s
   own `UNIMPL` stub. Needs a devfs walk + stat to turn a `/dev/*` (or,
   per this round's honest scope note, a `/var/pdxfs/*.img` file) path
   into a `bdev_cap`. Blocks every real (non-dry-run) mount this round's
   probe or `mount.pdxfs` itself could otherwise complete. R51/R52
   scope. Not hardware-gated for the file-target case; hardware-gated
   for the device-target case.
2. **No devfs at all** — `/dev/nvme0` never resolves as a lookup-able
   path in this tree. The device-target probe branch (#1979/#1980) is
   real code, exercised only once a devfs exists. R51/R52 scope.
3. **`boot_r65_persistent_home` Phase 2** — not implemented (see #1982
   disposition above), pending a `--with-disk`-shaped pdxfs-block
   harness analogous to `boot_r53_round_trip_phase1/phase2`. R51/R52
   scope.
4. **`mkfs.pdxfs` device-target write path** — carried over from the
   R64v2 retro's own debt item 4 (`cap:blkdev:...` write stubbed
   pending `sys_cap_query`). Unaffected by this round; still real
   debt on the eventual device-target mount path.
5. **`mount.pdxfs`'s own mismatched ABI** (its `mount_op.pdx`'s "KERNEL
   GAP #2") — `mount.pdxfs` itself still issues the aspirational cap-
   slot ABI (`rdi=narrowed_volume_slot`, ...) against the real 5-
   argument path-based `sys_mount_shim`, which is not what
   `sys_mount_body` actually expects. This round did not touch
   `mount.pdxfs`'s own call site (out of the paideia-os monorepo's
   scope — that's a satellite-repo fix); init.pdx's own new `sys_mount`
   trampoline uses the CORRECT real ABI, so this gap is isolated to
   `mount.pdxfs`'s interactive/scripted path, not the boot-time probe
   this round landed. Tracked here for visibility, not owned by this
   round.
6. **`libpdx-elevate` broker cap for CLI tools** — carried over from the
   R64v2 retro's own debt item 3. Unaffected by this round.

## Observable proof

Every default boot (tmpfs rootfs, no `--with-disk`) still reaches
`SHELL START` with no regression from this round's `init.pdx`/
`shell.pdx` changes — the new home-mount probe and the new envp/chdir
logic are additive code paths that fall through to the pre-existing
boot behavior on the default tmpfs boot (no target present, so no
`sys_mount` is even attempted; `HOME` is now set but chdir to it lands
on the same tmpfs root `/home/operator` would have to exist under
anyway — it does not by default, so `sys_chdir` fails closed and the
shell stays at `/`, byte-identical to pre-R65v2 behavior).

`boot_r65_persistent_home` (opt-in, `PAIDEIA_R65_PERSIST=1`) is the
round's new positive-path proof: real `sys_execve` of `/bin/mkfs.pdxfs`
and `/bin/mount.pdxfs` from the real shell, both dry-run preview lines
landing on the wire, `result_code: DRY_RUN }` proving `mount.pdxfs`'s
own dry-run gate fired rather than an elevation/bad-cap/kernel-error
branch, `REAPED` closing the sequence.

*Build/boot verification for this round is main's responsibility per
the paideia-os loop discipline (softarch does not invoke
`tools/build.sh` or `tools/run-smoke.sh`) — the fingerprint lines and
register-shuffle derivations above are architecture-level claims backed
by direct reading of `entry.pdx`/`dispatch.pdx`/`sys_mount.pdx`, not by
an observed boot log at authoring time.*

**Next round:** R51/R52 (persistent pdxfs-block rootfs) is now the
single dependency blocking every remaining item in the debt inventory
above except item 5 (which belongs to the `mount.pdxfs` satellite repo)
and item 6 (a dedicated elevate-broker round). Landing R51/R52 turns
this round's §2.1 `UNIMPL` stub into a real resolver, makes the two
`init home mount ok` fingerprints reachable for the first time, and
makes `boot_r65_persistent_home` Phase 2 buildable.
