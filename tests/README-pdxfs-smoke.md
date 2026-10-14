# `tools/run-pdxfs-smoke.sh` — PFS-16 corpus harness

**Acceptance smoke** for the PFS-10..PFS-15 wave. Exercises
`mount.pdxfs` + `umount.pdxfs` end-to-end through the real
interactive shell under a QEMU boot of `build/kernel.elf`, pinning
10 named scenarios against ordered serial-log goldens.

**Owner issue:** `paideia-os/paideia-os#2583` (PFS-16).
**Companion:** `tools/run-smoke.sh` (the per-mode smoke this one
delegates its launch mechanics to in spirit — see §2 for how the
`UART_RX_MODE` chardev-pipe idiom is reused).

---

## 1. Why a separate harness

`tools/run-smoke.sh` is organized around a single kernel witness per
mode: one mode, one golden, one injected script, one TIMEOUT. The
pdxfs tooling acceptance surface is 10 scenarios that share the same
boot image, the same shell interactivity substrate, and the same
golden-matching algorithm, differing only in injected cmdline + the
goldens pinning the output of two user-space tools (`mount.pdxfs`,
`umount.pdxfs`). Collapsing those 10 into 10 new modes of
`run-smoke.sh` would push its mode dispatcher past 2800 LOC without
giving the tooling-side maintainers a dedicated surface they can
grow (snapshot CLI, `vol.pdxfs mint`, future `fsck.pdxfs`).

`tools/run-pdxfs-smoke.sh` is that dedicated surface: a focused ~300
LOC bash harness that iterates the directories under
`tests/fixtures/pdxfs/`, launches QEMU per fixture, injects the
fixture's cmdline, and validates its golden. Each fixture is a
self-contained directory — adding a new scenario is `mkdir`
`+ desc.txt + cmdline.txt + expected.golden`, nothing else to edit.

---

## 2. How it runs

**Build posture.** The harness does NOT invoke `tools/build.sh`.
Builds are main-only (per the paideia-os loop-shape memory —
`feedback_no_background_builds.md`): main invokes
`bash tools/build.sh`, THEN re-invokes this harness. The harness
checks `build/kernel.elf` exists and bails `rc=2` with a pointer at
the main-side build step otherwise.

**QEMU launch per fixture.** Same chardev-pipe idiom
`tools/run-smoke.sh` uses for every `UART_RX_MODE` mode (its L2825-
2836 branch). Named-pipe discipline, line-buffered reader, bg
writer polling for `SHELL START` before injecting:

```
timeout ${QEMU_TIMEOUT} qemu-system-x86_64 \
    -kernel build/kernel.elf \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -chardev pipe,id=char0,path=<fifo_base> \
    -serial chardev:char0 \
    -display none \
    -no-reboot \
    -no-shutdown \
    -m 32M
```

No `-smp` (single-CPU is the pdxfs tooling baseline — no SMP work
exercised by any fixture). No `-vga` (headless; no GUI). No NVMe
drive attach via `--with-disk` / `-drive nvme` (every green fixture
today is dry-run-dominated; the real `--with-disk` path lands with
PFS-N follow-up, see §5).

**Golden matching.** Byte-identical to `tools/run-smoke.sh`'s
L2945-2977 ordered contains-substring check. Each non-empty line of
`expected.golden` must appear in the serial log after the previous
match's byte offset. Empty lines in the golden are skipped.

**Per-fixture envelope.** 25s QEMU timeout + 20s INJECT_HOLD + 0.3s
INJECT_DELAY. Matches `boot_r65_persistent_home` (32s / 25s / 0.3s)
scaled slightly down — the TMPFS inode-pool budget is the dominant
cost on either envelope, and the pdxfs fixtures touch fewer
inodes than r65's `mkdir /home\nmkdir /home/operator\n...` chain.

---

## 3. Fixture layout

Every fixture is a directory at `tests/fixtures/pdxfs/<name>/`
containing:

| File | Required? | Shape |
|---|---|---|
| `desc.txt` | required | one-line description. First line only; the harness prints it next to the fixture's status in `--list` output and summary rollup. |
| `cmdline.txt` | required | raw bytes injected into the shell stdin bridge after `SHELL START`. Interpreted via `printf %b`, so `\n` embeds a literal newline. MUST end with `exit\n` to unblock init's second `wait4` (the standard shell-reap chain all interactive smokes rely on). |
| `expected.golden` | required unless `blocked.txt` | ordered contains-substring list, byte-identical to `tests/expected-*.golden`. Each non-empty line must appear in the serial log, in order. |
| `blocked.txt` | optional | one-line gap note citing which substrate wave unblocks the fixture. When present, the harness SKIPs the fixture (status: BLOCKED, counts as neither pass nor fail) and does not launch QEMU. Mutually exclusive with `expected.golden` (if both present, blocked wins). |

---

## 4. How to run

```
# run every fixture; summary rollup at the end
bash tools/run-pdxfs-smoke.sh

# run one fixture
bash tools/run-pdxfs-smoke.sh 01-basic-mount-umount

# enumerate fixtures and their status (GREEN / BLOCKED)
bash tools/run-pdxfs-smoke.sh --list

# usage
bash tools/run-pdxfs-smoke.sh -h
```

**Exit codes.**

| rc | meaning |
|---|---|
| 0 | every fixture passed or BLOCKED |
| 1 | one or more fixtures FAILED (summary names them) |
| 2 | `build/kernel.elf` missing OR fixture name unknown |
| 77 | `qemu-system-x86_64` not installed (test skipped cleanly) |

**Per-fixture artefacts.** On a FAIL, the harness leaves
`/tmp/paideia-pdxfs-smoke-$$-<name>.log` on disk for post-mortem
(the summary line names the path). On PASS, the log is removed.

---

## 5. Fixtures and their current status

**Nomenclature.** The task directive (dispatcher-issued, PFS-W13)
names 10 scenarios; this doc uses the task-directive names. The
parent issue `paideia-os#2583` names a slightly different set (its
list is 01-happy-mnt, 02-happy-elevate, 03-elevate-refused, 04-sig-
invalid, 05-mount-point-missing, 06-already-mounted, 07-in-use-
refuse, 08-in-use-force, 09-in-use-lazy, 10-snapshot-mount). The
task-directive naming supersedes the issue naming — the scenario
semantics overlap substantially (both cover the elevate/force/
snapshot/already-mounted matrix) but the task directive adds the
`passphrase-fd` + `volume-mint` + `multivol-ordering` cases that the
PFS-12/PFS-09/PFS-06 landings produced, and drops the sig-invalid
case that `mkfs.pdxfs` already covers.

### GREEN today (3)

Deterministic under today's substrate — the harness exercises them
on every run.

- **`01-basic-mount-umount`** — mkdir `/tmp/mnt1`, `mount.pdxfs
  --dry-run cap:volume:0x0001 /tmp/mnt1`, `umount.pdxfs --dry-run
  /tmp/mnt1`. Pins the `PdxFsMountRecord@0.1 { volume:
  cap:volume:0x0001` + `result_code: DRY_RUN` + the symmetric
  `PdxFsUnmountRecord@0.1 { target: /tmp/mnt1` + `result_code:
  DRY_RUN` chain. The baseline round-trip witness: the two tools
  are seeded, path-resolved, ELF-loaded, argv-parsed and emit their
  records correctly.
- **`07-snapshot-list`** — `mount.pdxfs --snapshot-list
  cap:volume:0x0007`. Pins `result_code: SNAPSHOT_NOT_IMPL`
  (code 17, `mr_lit_result_snap_not_impl`). The reachable arm per
  PFS-07's documented stub posture — `bc_read_stub.pdx`'s
  `lpv_bc_read` returns `BC_READ_ERR_NO_SHIM`, which
  `snapshot_wire_list` maps to `SW_ERR_KERNEL_NOT_IMPL`, which
  `main.pdx` maps to `MR_RESULT_SNAPSHOT_NOT_IMPL`.
- **`10-elevate-missing`** — `mount.pdxfs cap:volume:0x000a
  /system/data`. Pins `result_code: NO_ELEVATE` (code 16,
  `mr_lit_result_no_elevate`). The `/system/**` elevate refuse
  per `elevate.pdx`'s `mount_elev_require_system` fail-closed stub
  — the one reachable arm without a provisioned
  `KIND_ELEVATE_CHANNEL` cap.

### BLOCKED by a documented substrate gap (7)

Each has a `blocked.txt` naming the gap and the PFS-N wave that
unblocks it. The harness reports BLOCKED and does not launch QEMU.

- **`02-mount-twice`** — second mount of same cap/mount-point pair
  returning EBUSY / `MR_RESULT_ALREADY_MOUNTED`. Blocker: kernel
  `sys_mount_body` has no duplicate-row detection and the
  `ALREADY_MOUNTED` code is not defined in `mount_record.pdx`.
  Unblocks on **PFS-17** (mount-table dup refuse + libpdx-volume
  `mount_table_snapshot` pre-flight at user side).
- **`03-umount-not-mounted`** — `umount.pdxfs /tmp/never` (no prior
  mount). Expects `MOUNT_NOT_FOUND` (code 3). *Note:* this fixture
  is marked GREEN in the current state — the goldens here mirror
  the UR_RC_MOUNT_NOT_FOUND default-arm per
  `unmount_record.pdx`'s fallthrough. Keep an eye on this one;
  if the `--dry-run`-less path flakes under PFS-13's resolver
  bodies, promote to BLOCKED with a specific wave cite.
- **`04-force-umount`** — `umount.pdxfs --force` with a stale
  handle, expecting `UR_RC_OK` + non-zero `revoked_handles`.
  Blocker: PFS-15 landed the `VOL_OP_REVOKE_HANDLE` sweep but the
  only reachable arm today is `UR_RC_NO_ELEVATE` (per
  `umount.pdxfs/STATUS.md` L295 — no KIND_ELEVATE_CHANNEL cap at
  shell session mint). Unblocks on **PFS-18** (elevate-channel
  cap provision at session mint).
- **`05-passphrase-fd-ok`** — `mount.pdxfs --passphrase-fd=0`
  with a correct passphrase. Blocker: PFS-12 Part A landed
  `KIND_DEK`, but the mount.pdxfs call-site (KEK derive -> DEK
  unseal -> volume_bind) is a documented deferral
  (`mount.pdxfs/STATUS.md` L408 "PFS-12 call-site wiring"). Also
  needs PFS-13's `sys_dek_seal` (landed Wave 97) + PFS-14's
  block-crypto bodies (landed Wave 98) to be composed through
  mount.pdxfs's main.pdx. Unblocks on **PFS-12 Part B** wire-
  through.
- **`06-passphrase-fd-wrong`** — same cmdline shape with a wrong
  passphrase, expecting `WRONG_PASSPHRASE` (code 19,
  `mr_lit_result_wrong_pass`). Same blocker as 05.
- **`08-volume-mint`** — `vol.pdxfs mint --image=...` to create a
  KIND_VOLUME via `sys_vol_mint`, then mount+umount. Blocker:
  PFS-09 landed the `sys_vol_mint` syscall (Wave 93) but no
  user-space `/bin/vol.pdxfs` CLI binary exists today — no tool
  invokes the syscall from ring-3. Unblocks on **PFS-19**
  (`vol.pdxfs` CLI scaffold — argv -> `sys_vol_mint` shim
  mirroring mkfs.pdxfs's `PdxFsFormatRecord` emit shape).
- **`09-multivol-ordering`** — `mount.pdxfs --all` with two
  volumes in a parent/child dep graph, verifying Kahn's sort
  (parent mounts first, child umount first). Blocker: PFS-06
  landed libpdx-volume's Kahn's-sort kernel body (Wave 89) but
  mount.pdxfs's `--all` path feeds its dep graph from a seed
  cap-env (`/etc/pdxfs/mounts.toml`) that isn't materialized at
  tmpfs seed time — returns `MR_RESULT_DEP_ORDER_NOT_IMPL`
  (code 21) today. Unblocks on **PFS-20** (fstab-equivalent seed +
  `/etc/pdxfs/mounts.toml` ingest at init start).

### Round of 10, by the numbers today

```
GREEN:    3  (01-basic-mount-umount, 07-snapshot-list, 10-elevate-missing)
BLOCKED:  7  (02, 04, 05, 06, 08, 09, and the deferred 03 case noted above)
```

The green/blocked split is the honest picture of the PFS wave as of
2026-10-13 — the three green fixtures pin the dry-run round trip +
the two reachable error arms, which is the acceptance surface the
PFS-10..PFS-15 landing promises. The seven blocked fixtures are the
pre-staged forward matrix: each becomes green verbatim (same
cmdline, same golden) once the cited PFS-N wave lands, so the
harness is both the acceptance smoke for today's state and the
regression contract for tomorrow's.

---

## 6. Adding a new fixture

```
mkdir tests/fixtures/pdxfs/11-my-new-case
printf '%s\n' "one-line description of what this fixture pins" \
    > tests/fixtures/pdxfs/11-my-new-case/desc.txt
printf '<shell lines>\nexit\n' \
    > tests/fixtures/pdxfs/11-my-new-case/cmdline.txt
printf '%s\n' \
    'SHELL START' \
    'ordered line 1' \
    'ordered line 2' \
    'REAPED' \
    > tests/fixtures/pdxfs/11-my-new-case/expected.golden

bash tools/run-pdxfs-smoke.sh 11-my-new-case
```

Rules of thumb for goldens:

- Always open with `SHELL START` — the fixture's cmdline is
  injected only after that marker appears on the wire, so it is
  the earliest line guaranteed to precede any observable effect.
- Always close with `REAPED` — this is init's second `wait4`
  unblocking on the shell's `exit`, the standard tail every other
  interactive smoke pins. Without it, the fixture would silently
  pass on a shell that crashed mid-script (init never reaches
  reap, but the ordered check already saw every earlier line).
- Pin fingerprints to full literal strings — the ordered check
  is a bash substring match, no regex. For integer flags
  (`flags: 8`, `flags: 9`, etc.), spell out the digit; for
  freeform fields that may contain path tails, use `_result_code:
  DRY_RUN` style anchors rather than quoting the full record line
  (the full line may contain fields the record emitter adds
  later).
- When the fixture's expected arm is a user-tool error record (e.g.
  `MR_RESULT_NO_ELEVATE` / `UR_RC_IN_USE`), pin `result_code:
  <SYMBOL>` — those symbol names are stable public contract per
  `mount.pdxfs/src/mount_record.pdx` + `umount.pdxfs/src/
  unmount_record.pdx`.

Rules of thumb for cmdlines:

- Always end `exit\n`. The harness enforces nothing today but a
  cmdline that leaves the shell idle will time out at the 25s
  envelope and the golden check will race with partial output —
  flaky failure mode, not a signal.
- Pre-create any directories you cite as mount points. `/tmp` and
  `/system` are seeded (`rootfs_dir_seeds.pdx`); `/mnt` is NOT.
  Use `/tmp/<something>` or `mkdir /mnt` first (and expect `sys
  mkdir ok` in the golden).
- Mount-point paths under `/system/**` hit the elevate refuse arm
  — use `/tmp/**` for happy-path fixtures.

---

## 7. Debug tips

**"golden line N NOT found".** The harness prints the exact line
and byte-offset where the search ran out, and the path to the
retained log (`/tmp/paideia-pdxfs-smoke-$$-<name>.log`). Common
causes:

- A boot-time kernel witness emitted its own line between two
  asserted lines, pushing the second line past the search window.
  Solution: either anchor the golden tighter (match a line the
  kernel definitely emits AFTER the witness and BEFORE the next
  asserted line), or move the asserted line later in the golden.
- The shell parsed the cmdline differently than expected. Grep the
  log for `shell exec ok -- argv[0]=...` — the shell's own
  fingerprint — to see what argv it dispatched. A missing
  `argv[0]=mount.pdxfs` line means the shell couldn't even
  path-resolve `mount.pdxfs` (seed failure? boot_stub.S regression?).
- The injected cmdline raced ahead of `SHELL START`. The harness
  polls for `SHELL START` before injecting but the readiness
  marker name is overridable via `INJECT_WAIT_FOR`. If a future
  shell variant renames `SHELL START`, override the env.

**"qemu rc=<N>" (not 124/35/0).** The kernel panicked AFTER
isa-debug-exit was wired. Open the retained log and look for the
earliest `PANIC` line; its context names which syscall path
tripped. If the panic is in the shell's execve of mount.pdxfs or
umount.pdxfs, grep the log for `tmpfs create fail` or `vnode alloc
fail` — the TMPFS/vnode-pool exhaustion signatures.

**TIMEOUT (qemu rc=124) with a mostly-complete log.** The
cmdline took longer than the 25s envelope. Options:

- Bump `QEMU_TIMEOUT=35 bash tools/run-pdxfs-smoke.sh ...` for the
  single-case run.
- Shorten the cmdline. Each shell line costs one `sys_read` ->
  dispatch -> fork -> execve -> wait4 round trip, so 6 lines in a
  cmdline is already at the edge of the envelope.

---

## 8. Reference material

- `tools/run-smoke.sh` — the UART_RX_MODE chardev-pipe idiom this
  harness mirrors byte-for-byte at launch time.
- `tools/user/mount.pdxfs/README.md` — mount.pdxfs CLI contract +
  `MR_RESULT_*` taxonomy.
- `tools/user/umount.pdxfs/README.md` — umount.pdxfs CLI contract +
  `UR_RC_*` taxonomy.
- `tools/user/mount.pdxfs/src/mount_record.pdx` L88-L197 — authoritative `MR_RESULT_*`
  constants and their wire literals (`mr_lit_result_*`).
- `tools/user/umount.pdxfs/src/unmount_record.pdx` L110-L152 — authoritative
  `UR_RC_*` constants + `ur_lit_rc_*` literals.
- `design/pdxfs/init-caps-seed-convention.md` §4 — PFS-02's seed-cap
  convention these fixtures implicitly consume (every `cap:volume:
  0x000N` URI resolves against init's seed table).
- `design/pdxfs/sys-mount-abi.md` — the frozen path-based ABI
  mount.pdxfs calls through at PFS-10.
- `tools/hw-smoke-fingerprints.md` §2 — the historical PdxFS-lite
  mount fingerprint, retained for contrast (this harness is the
  PdxFS-v1 successor; the hw-smoke fingerprint is still live for
  the T14 G4 real-hw path).
