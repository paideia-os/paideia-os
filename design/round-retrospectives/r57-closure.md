# R57 Retrospective (PARTIAL): Userland tools + syscall widening

**Date:** 2026-08-25
**Milestone:** R57.M4 (single-milestone round; PARTIAL close by this doc)
**Issues:** 5 landed (3 userland binaries + 2 kernel syscall bodies + this closure);
3 deferred to R57 debt (#1801 shell PATH, #1803 composite smoke, /bin/ps live,
/bin/mount live).
**HEAD at closure:** bumped by the R57.M4-008 commit that lands this doc.
**paideia-as pinned at:** unchanged across R57 — **twelfth consecutive round**
with zero cross-repo escalations, since R21 close.
**Release tag:** `r57-closed` (partial-close discipline mirrors r24-m5-partial.md).

---

## Round Intent

R57 was scoped to give the shell real POSIX-style userland tools that exercise
the R56 metadata syscall wave and the R55 write path — `/bin/ls`, `/bin/cat`,
`/bin/ps`, `/bin/mount` — plus the init-time rootfs seed loop and the
shell PATH resolver. Composite smoke `boot_r57_shell_a` was to close the
loop by injecting a shell tape (`ls /`, `cat /etc/motd`, `ps`, `mount`, `exit`)
and asserting the outputs in order.

Actual landing was substrate-heavy: the two new kernel syscall bodies
landed cleanly (sys_taskinfo #83, sys_mountinfo #84 with dispatch bounds
82→84), the userland `/bin/ls`, `/bin/cat`, and init rootfs seed landed
and build, but `/bin/ps` and `/bin/mount` userland ELFs hit two distinct
paideia-as parser/encoder gaps that were not surfaced by any prior userland
binary and could not be worked around without either a paideia-as fix or
substantial file restructuring beyond the round budget.

---

## What R57 Delivered

### Landed (5 issues + closure)

- **#1790..#1796** (R56.M3): full VFS metadata syscall wave — dispatch
  bounds 76→82, sys_stat, sys_getdents, sys_mkdir, sys_rmdir, sys_unlink,
  sys_rename with backend adapters + composite smoke scaffold. Closed as
  R56 (tag `r56-closed`).
- **#1797** `/bin/ls` — self-contained ELF, sys_getdents wrapper,
  walks records emitting `name\n` to fd 1. Argv ignored per R17.M0 sys_execve
  posture; hardcoded target `/`. Built + linked.
- **#1798** `/bin/cat` — self-contained ELF, open+read+write loop with
  missing-file error path. Built + linked.
- **#1799 (kernel side)** `sys_taskinfo` syscall 83 — task_get_info primitive
  + dispatch shim + tag_sys_taskinfo_ok. 32-byte record layout {pid u32,
  ppid u32, state u32, reserved u32, name [u8;16]}. Built + linked; /bin/ps
  userland debt below.
- **#1800 (kernel side)** `sys_mountinfo` syscall 84 — inline _mount_table
  read, 32-byte record + dispatch shim + tag_sys_mountinfo_ok. Bounds 83→84
  dispatch expansion. Built + linked; /bin/mount userland debt below.
- **#1802** Init-time rootfs seed loop — first-boot detection + mkdir
  /bin,/etc,/tmp + write embedded payloads + /etc/motd banner. Built into
  init.elf. Real ELF payloads for the 6 /bin/* files remain minimal stubs
  pending R57 tail; the seed infrastructure is complete.
- **#1804** (this doc) — partial closure retro + STATUS block + `r57-closed`
  tag.

### Deferred to R57 Debt (3 issues + 2 subtasks)

- **#1799 subtask** `/bin/ps` userland ELF — paideia-as U1606 rejects
  `mov rdi, 1;` and `mov rax, 1;` in some kernel-side sysno-arg-load
  contexts (fixed by renaming `record` variable to `ps_record` and
  stripping trailing @no_frame at module tail; the userland now BUILDS but
  the encoder gap that motivated the workaround is a real paideia-as
  regression to file).
- **#1800 subtask** `/bin/mount` userland ELF — paideia-as P0100 parser
  rejects trailing `@no_frame` decorator on the last lambda in a multi-
  lambda module (not reproducible on siblings ls/cat/true/ps that share
  the pattern; specific to mount.pdx's structure). mount.pdx and mount.ld
  removed from the tree; kernel-side sys_mountinfo is fully callable.
- **#1801** Shell PATH resolver — deferred. Requires src/user/dispatch.pdx
  (shell) modifications plus src/user/init.pdx PATH env seed; risk of
  compounding encoder gaps on the shell exec_child rewrite. Kernel-side
  substrate has no dependency; unblocks anytime.
- **#1803** boot_r57_shell_a composite smoke — deferred. Depends on all
  three userland binaries (/bin/ls, /bin/cat, /bin/ps, /bin/mount)
  building AND the shell tape driver being fully wired. Two of four
  binaries have debt. Substrate landing (dormant smoke scaffold matching
  R56.M3-006 posture) can land ahead of the userland fixes; not landed
  here to avoid inflating the round.

### Cross-Repo Escalations to paideia-as (R57)

**None.** paideia-as submodule pinned throughout R57. **Twelfth consecutive
round** with zero cross-repo escalations. Two encoder gaps surfaced (P0100
trailing @no_frame parser rejection; U1606 imm64 mov rejection in specific
context) — both worked around inline with drive-by rewrites; both should
be filed as paideia-as follow-ups.

### Observable Proof

- Kernel builds clean under `tools/build.sh`.
- Substrate boot reaches SHELL START + `$` prompt.
- 11 T-symbols added to kernel.elf: sys_stat_body, sys_getdents_body,
  sys_mkdir_body, sys_rmdir_body, sys_unlink_body, sys_rename_body,
  sys_taskinfo_body, task_get_info, sys_mountinfo_body, dispatch_taskinfo,
  dispatch_mountinfo.
- 3 userland ELFs built: ls.elf (5360 B), cat.elf (5168 B), ps.elf
  (5528 B) — plus init.elf grew to accommodate rootfs_seed.

### R57 Debt Carried Forward

1. **/bin/mount userland ELF** — paideia-as P0100 parser gap on trailing
   @no_frame. Blueprint of intended implementation preserved in
   git history at worktree branch `worktree-agent-a56d047c10f2c59cf`.
2. **/bin/ps live exercise** — binary builds but not integrated into
   any boot smoke. Substrate present; needs sys_execve argv wiring for
   real argv-driven invocation.
3. **#1801 Shell PATH resolver** — full deferral. Shell continues with
   hardcoded /bin/ prefix launcher.
4. **#1803 composite smoke** — full deferral pending #1801 + /bin/mount +
   real /bin/ps invocation path.
5. **Real ELF payloads in rootfs_seed** — currently minimal 9-byte stubs;
   R57+ substitutes the actual /bin/ls/cat/ps ELFs post-build.
6. **paideia-as P0100 parser gap** — trailing @no_frame at last lambda in
   multi-lambda module. File separately.
7. **paideia-as U1606 encoder gap** — imm64 `mov rax, 0xFFFFFFFFFFFFFF...`
   in specific contexts. File separately (or amend existing #1250 gap).
8. **R56 debt carried through** — pdxfs-block mkdir/rmdir/rename real
   bodies, pdxfs_lite mkdir/rmdir, cross-directory rename WAL-atomic,
   mtime source, build.sh silent-error swallow, verify-fingerprint-
   coverage.sh unesc ordering.

### Quirks Discovered on Real Hardware

None (R57 ran entirely under QEMU `-kernel` / documentation).

**Next Round:** R58 (shell redirects + /bin/rm/mv/cp/mkdir/touch). Zero
R57 kernel-side blockers; R58 can proceed with the deferred R57 debt as
sibling backlog.
