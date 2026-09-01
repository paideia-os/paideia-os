# Persistent /home/operator — R65v2 design

**Status:** Real end-to-end at the *pipeline* level (probe → mount attempt
→ shell chdir), still tmpfs at the *storage* level. R65v2.M1-001 (#1979,
init-time probe + mount + envp), R65v2.M1-003 (#1981, shell chdir-on-entry)
and R65v2.M1-004 (#1982, boot smoke — Phase 1 only) are now real, landed
code, superseding the R65 v1 document this file replaces. `/home/operator`
does **not** yet survive a reboot: `sys_mount`'s `backend_id=5`
(`PDXFS_BLOCK`) arm remains an unconditional `UNIMPL` stub pending a devfs
dev-path resolver (§2.2), so every mount attempt today falls through to
the tmpfs fallback by design, not by omission. Read §6 before assuming
`/home/operator` actually persists anything today.

**Corrects a phantom landing:** the R65 v1 version of this document
claimed R65.M1-002 (init envp: `PATH`/`HOME`) was "real, landed code."
It was not — `src/user/init.pdx` at the time this round started had no
`_init_envp` construction and no non-NULL `rdx` at any of its three
execve sites, despite the design doc's claim. This is the same
documentation-vs-tree drift class `design/roadmap/rows-4-5-6-scoping.md`
§0.1 flagged for the phantom "paideia-as #1730" citation. This round
(R65v2.M1-001, #1979) completes the envp wiring for real, since #1981's
shell chdir-on-entry has nothing to read without it — see §3.

**Depends on:** `design/tooling/volume-tooling-ux.md` (R53, mkfs.pdxfs /
mount.pdxfs / umount.pdxfs / libpdx-volume design), `design/filesystem/
volume-fs-substrate.md` (R52, PDXB superblock + WAL format),
`design/user/execve-abi.md` (R62, real argv/envp on execve),
`design/user/rootfs-seed-inventory.md` (R57.M4-006, init-time /bin seed
loop this design's mount probe is sequenced alongside),
`design/round-retrospectives/r64-closure-v2.md` (R64v2, the volume-tool
ELF chain — `libpdx-volume`, `mkfs.pdxfs`, `mount.pdxfs`, `umount.pdxfs`
— that provides every userland-callable primitive this round's kernel-
side probe reuses).

---

## 1. Goal

Today, `/home/operator` (and everything under it) is backed by tmpfs:
in-memory, gone on every reboot. R65's goal is to make `/home/operator`
a real mount point backed by a persistent PDXB volume, so a file an
operator writes survives a reboot cycle — the same guarantee R53's
volume tools give any mount point, applied specifically to the home
directory every interactive session starts in.

This is deliberately narrow in scope: two specific targets (a file-
backed image at `/var/pdxfs/home.img`, or a device node at
`/dev/nvme0`), one specific mount point (`/home/operator`), probed once
at init time. It is not a general "any device, any mount point"
init-time automount facility — that is out of scope; see §5.

---

## 2. The mount-at-boot path (R65v2.M1-001, #1979 — REAL)

`src/user/init.pdx`'s `_start`, immediately after the existing
R57.M4-006 rootfs-seed loop (`call rootfs_seed_run`) and before the
first fork+exec cycle, now runs:

1. `sys_stat("/var/pdxfs/home.img")` — check the file-backed image path
   exists. This is the FILE target: the one `mkfs.pdxfs`'s R64v2 file-
   target pipeline (real `sys_open`/`write`, PDXB codec via
   `libpdx-volume`) can actually produce today.
2. `sys_stat("/dev/nvme0")` — check the device-cap target too. Both
   probes always run (not short-circuited), because step 3's priority
   rule needs to know whether the device target is ALSO present, not
   merely whether the file target already satisfied the "something to
   mount" question.
3. **Priority rule:** if the device target is present, prefer it over
   the file target, even when both exist. A real block device outlives
   a reboot more durably than a file hosted on today's tmpfs rootfs — a
   file-backed image is itself wiped on every boot unless and until a
   persistent rootfs (R51/R52) is under it, whereas a device node's
   *backing storage* is real hardware regardless of what's mounted at
   `/`. If neither target is present, init silently continues with the
   tmpfs-backed `/home/operator` — no probe failure is ever boot-
   blocking, mirroring the existing rootfs-seed loop's own "skip
   silently, keep booting" discipline. There is intentionally no klog
   trace on this skip path: userland has no privileged logging channel
   other than `sys_debug_puts`, and emitting on the ENOENT/default path
   would fire on every default tmpfs boot, which is exactly the
   ambient-noise problem the "fingerprint only on the interesting path"
   convention this codebase otherwise follows exists to avoid.
4. On either target present: `sys_mount(src_path, src_len, mp_path=
   "/home/operator", mp_len, backend_id=5)` — `PDXFS_BLOCK` per
   `sys_mount.pdx`'s own backend-id vocabulary. This is the real kernel
   `sys_mount_body`/`sys_mount_shim` (sysno 75, dispatch wire rewired
   real at paideia-os `274c93b`) — init is a second, privileged caller
   of the same entry point `mount.pdxfs` calls from userland (§4 of
   `design/tooling/volume-tooling-ux.md`).
5. On `sys_mount` success (return value in `[0..7]`, the mount-table
   slot index): emit one of two fixed rodata fingerprint lines —
   `init home mount ok [legacy: INIT HOME MOUNT OK] -- src=<path>
   mp=/home/operator backend=PDXFS_BLOCK` — selecting the file or
   device variant by which target was actually used. Both variants are
   compile-time-known literals (no dynamic path formatting exists in
   this userland tree).
6. On `sys_mount` failure (return `>= 8`, i.e. any `0xFFFFED6x`
   sentinel or negative errno): fall through silently to the tmpfs-
   backed `/home/operator` every boot already has. A missing or corrupt
   home volume is never a boot-blocking condition.

A new userland syscall wrapper pair (`src/user/syscall_shim.pdx`) makes
step 1/2/4 possible: `sys_stat` (sysno 77, arity 3, no ABI shuffle) and
`sys_mount` (sysno 75, arity 5, a two-register shuffle — SysV's `rcx`
→ raw `r10`, and, non-obviously, SysV's `r8` → raw `r9` rather than raw
`r8`, because `entry.pdx`'s own SYSCALL→SysV shuffle clobbers raw `r8`
with raw `r10`'s value before dispatch ever reads it, and only raw `r9`
survives untouched into `dispatch_mount`'s own `r9=a4=backend_id` slot
— see that trampoline's own header comment in `syscall_shim.pdx` for
the full wire trace). Neither trampoline existed before this round;
`mount.pdxfs`'s own `mount_op.pdx` targets a different, mismatched
aspirational cap-slot ABI (documented as its own "KERNEL GAP #2"), so
init's trampoline is the first real caller of the actual 5-argument
path-based `sys_mount` ABI.

### 2.1 Why `sys_mount` still fails today (backend_id=5 UNIMPL)

`sys_mount.pdx`'s own header documents `backend_id == 5` as a STUB arm:
resolving a device or file path into a `bdev_cap` needs a devfs walk +
stat that has not landed (`design/tooling/volume-lifecycle-mechanism.md`
§5.2 gap). The arm unconditionally returns `SYS_MOUNT_UNIMPL_PDXFS_BLOCK`
(`0xFFFFED63`) regardless of whether the path denotes a device node or a
plain file — the missing piece is the dev-path→cap resolver itself, not
anything specific to one kind of path. **This means every `sys_mount`
call this section's probe issues fails today, by design, honestly
documented** — the probe's own fallback-on-failure step (§2, step 6)
is not a hedge against a hypothetical bug; it is the expected outcome
of every default boot until R51/R52 lands the resolver.

### 2.2 Dependency chain

```
mkfs.pdxfs produces a PDXB image at /var/pdxfs/home.img
    (or, eventually, on /dev/nvme0 — R64v2's mkfs.pdxfs device-target
     write path is itself still stubbed pending sys_cap_query)
        │  REAL as of R64v2: libpdx-volume's pdxb_encode_superblock +
        │  pdxb_sign_superblock (mldsa65_sign intrinsic, paideia-as
        │  v0.24.0) + mkfs.pdxfs's file-target format pipeline.
        ▼
a valid, signed KIND_VOLUME superblock exists at the target
        │
        ▼
init's boot-time probe (§2, REAL) finds the target file/device via
sys_stat and calls sys_mount
        │  sys_mount ITSELF still refuses backend_id=5 (§2.1, UNIMPL)
        │  — the dev-path→bdev_cap resolver is the one remaining gap.
        ▼
/home/operator is a real, persistent mount point   ← NOT YET REACHED
```

Every box up to and including "init's boot-time probe... finds the
target" is now real. The single remaining gap is the devfs dev-path
resolver inside `sys_mount_body`'s own `backend_id == 5` arm — tracked
as R51/R52 scope, not an R65v2 item.

---

## 3. Environment prep: PATH + HOME (R65.M1-002 completion, R65v2.M1-001
##    #1979 — REAL)

Every process init execs now receives a real, non-empty environment.
`src/user/init.pdx` declares two rodata strings and a runtime-populated
pointer table:

```
init_env_path : "PATH=/bin:/usr/bin\0"   (19 bytes incl. NUL)
init_env_home : "HOME=/home/operator\0"  (20 bytes incl. NUL)
_init_envp    : [u64; 3] = uninit @align(8)
```

`_init_envp` is populated once, at `_start`, immediately after the
ring-3 proof-of-life marker and before any of init's three fork+exec
cycles run: `_init_envp[0] = &init_env_path`, `_init_envp[1] =
&init_env_home`, `_init_envp[2] = 0` (NULL terminator). This is the
same idiom `dispatch.pdx`'s `builtin_names`/`dispatch_init` table uses
(R17-m3-004, #624) — paideia-as data initializers accept literal bytes,
not label addresses, so a pointer array must be declared `uninit` and
filled via `lea`+`mov` at runtime.

All three of init's execve sites (`/bin/child_hello`, `/bin/sh`,
`/bin/elevate_broker_daemon`) now load `rdx` with `&_init_envp` instead
of zeroing it. This activates R62's previously-idle envp-marshalling
path in `sys_execve_shim`: the existing `sys execve argv ok -- argc=<N>
envc=<M>` fingerprint (`klog_s1_d2`) now fires with `envc=2` instead of
`envc=0` on every init-launched process — a pre-existing kernel-side
fingerprint that needed no changes of its own to start reporting the
real count.

**Note on HOME today:** `HOME=/home/operator` is a real environment
variable every child of init can read, and (§4) the shell now acts on
it — but until §2.1's devfs resolver lands, `/home/operator` itself
remains backed by tmpfs like the rest of the in-memory filesystem.
Chdir-ing to a real, existing tmpfs directory is a real, useful
improvement in its own right; it just does not yet carry the
*persistence* a successful mount would add.

---

## 4. Shell chdir-on-entry (R65v2.M1-003, #1981 — REAL)

`src/user/shell.pdx`'s `_start` now captures `envp` (delivered in `rdx`
per `design/user/execve-abi.md`) into a callee-save register as its
very first instruction — before the entry-witness `sys_debug_puts`
call, which is free to clobber `rdx` like any other caller-save
register. After `dispatch_init` and before the first prompt, it scans
up to 16 `envp` entries (the `execve-abi.md` hard cap) for one whose
first 5 bytes match `"HOME="` (byte-for-byte via the `xor reg,reg` +
`mov_b` zero-extension idiom this codebase uses everywhere a byte
comparison needs to avoid the paideia-as #1248 `cmp al, imm8` REX.W
ambiguity — here applied to a register-vs-register byte compare for
extra safety), and on a match calls the real `sys_chdir` syscall
(sysno 85, landed R86.M1-002 #1955) with the value pointer and its
strlen (capped at 255, matching `SYS_CHDIR_PATH_MAX-1`).

**No explicit "/" fallback is needed on any failure path** (absent
`envp`, no `HOME=` entry, scan-cap exhaustion, or a failed `sys_chdir`):
every task's `TASK_OFF_CWD` already defaults to the root vnode at
`task_new` construction time (R86.M1-006, #1959), so a shell that never
successfully `chdir`s is already sitting at `/`, which is exactly the
pre-R65v2 behaviour. This is why the original R65 v1 plan's intended
fingerprint (`shell cwd init ok -- cwd=<path>`) was dropped: there is
nothing to observably prove beyond what `sys_chdir`'s own existing
R86.M1-002 fingerprint (`klog_s1_x1`, `tag_sys_chdir_ok`) already emits
on a real success — adding a second, shell-side "I attempted this" line
would only restate that the shell ran, which `SHELL START` already
proves.

The R65 v1 plan's worry about a still-hypothetical `sys_chdir` syscall
(then provisionally tracked as "R86") is now moot: R86 landed for real
(`sys_chdir`/`sys_getcwd`, #1955/#1956), so this section simply calls
it.

---

## 5. Out of scope

- **General automount.** Only `/var/pdxfs/home.img` / `/dev/nvme0` →
  `/home/operator` is probed; there is no config-driven "mount every
  discovered volume at its declared mount point" facility. That is a
  superset of R53's `mount.pdxfs` tool itself (an interactive/scripted
  tool, not a boot policy engine) and is not proposed here.
- **Multiple users / multiple home volumes.** R65 targets the single
  `operator` account. Per-user home-volume selection needs the
  multi-user `KIND_USER` model work tracked elsewhere in
  `design/user/model.md`; out of scope here.
- **Encryption-at-rest for `/home`.** Same R54+ deferral
  `design/tooling/volume-tooling-ux.md` §1.2 already carries for every
  PDXB volume; nothing home-specific changes that.
- **`/dev` itself.** There is no devfs in this tree — `/dev/nvme0`
  never actually exists as a lookup-able path today (§2.1). The device-
  target probe branch is real *code*, exercised only once a devfs
  populates that path; see #1980 in §6.

---

## 6. Honest scope block

**What is real, in this monorepo, today:**
- `src/user/init.pdx`'s `_init_envp` construction and the three
  execve-site `rdx` loads (§3, R65.M1-002 completion, R65v2.M1-001
  #1979).
- `src/user/init.pdx`'s post-rootfs-seed home-mount probe: both
  `sys_stat` calls, the device-over-file priority rule, the `sys_mount`
  call, and both success/failure fingerprint arms (§2, R65v2.M1-001
  #1979).
- `src/user/syscall_shim.pdx`'s new `sys_stat` and `sys_mount`
  userland trampolines (§2), the first userland callers of either
  syscall's real ABI in this tree.
- `src/user/shell.pdx`'s envp capture + `HOME=` scan + `sys_chdir`
  call on entry (§4, R65v2.M1-003 #1981).
- `tools/run-smoke.sh`'s `boot_r65_persistent_home` mode — **Phase 1
  only**: drives `mkfs.pdxfs --dry-run` and `mount.pdxfs --dry-run`
  through the real interactive shell and asserts the resulting preview
  lines against `tests/r65v2/expected-persistent-home-phase1.golden`
  (R65v2.M1-004, #1982).
- `tools/pre-push`'s `PAIDEIA_R65_PERSIST=1` opt-in gate running that
  mode (R65v2.M1-005, #1983).

**What is real code but currently unreachable in the default boot
(by design, not by omission):**
- `sys_mount`'s `backend_id=5` (`PDXFS_BLOCK`) arm remains an
  unconditional `UNIMPL` stub (`sys_mount.pdx`, §2.1 above) pending a
  devfs dev-path resolver. Every `sys_mount` call this round's probe
  issues therefore fails today; the probe's silent-fallback behaviour
  on that failure is the expected, exercised path, not an untested
  edge case.
- The `init home mount ok` fingerprint pair is allowlisted in
  `tools/verify-fingerprint-coverage.sh` for exactly this reason — no
  boot mode can assert it until R51/R52 lands.

**What is still deferred, and why:**
- **PHASE 2** of `boot_r65_persistent_home` (reboot, then read
  `/home/operator/probe.txt` back and assert its contents survived) is
  **not implemented at all**, not merely gated. Under tmpfs, a second
  QEMU boot has no way to see the first boot's writes — there is no
  `--with-disk`-shaped backing image for tmpfs the way
  `boot_r53_round_trip_phase1/phase2` has for PDXB. Implementing Phase
  2 as a permanently-failing assertion would make the mode a
  permanently-red smoke rather than a real regression signal, so it
  is deferred whole, to be built once R51/R52 lands a real pdxfs-block
  rootfs and a `--with-disk`-shaped two-phase harness can be built for
  it, analogous to `boot_r53_round_trip_phase1/phase2`.
- **R65v2.M1-002 (#1980), the device-target upgrade path**, is
  metadata-only tracking: the code preference (device over file, §2
  step 3) already landed as part of #1979 — there is no separate
  device-target implementation task remaining. What's actually deferred
  is everything upstream of it: a real devfs, a real `/dev/nvme0` node,
  and `sys_mount`'s own dev-path resolver (§2.1). All three are R51/R52
  scope.
- **Real persistent storage under `/home/operator`**, full stop, is
  R51/R52 scope: a pdxfs-block rootfs (or an equivalent persistent
  mount substrate) is the prerequisite both §2.1's resolver and Phase 2
  of the boot smoke are waiting on.

See `design/round-retrospectives/r65-closure-v2.md` for the round's
full landed/deferred accounting and the `r65v2-closed` tag rationale.
