# R65 Retrospective (PARTIAL): Persistent /home/operator

**Date:** 2026-08-25
**Milestone:** R65.M1 (single-milestone round; PARTIAL close by this
doc)
**Issues:** 2 landed (#1918 init envp, #1935 design doc) + 1 closure
(this doc, #1936); 4 deferred (#1916 mount, #1921 shell cd-on-entry,
#1926 boot smoke, #1930 pre-push gate).
**HEAD at closure:** bumped by the commit that lands this doc (same
commit as R64's #1918-adjacent envp work, per this wave's combined
landing).
**paideia-as pinned at:** unchanged (R65's landed portion is
kernel/userland `.pdx` only — no paideia-as-facing change).
**Release tag:** `r65-closed` (partial-close discipline).

---

## Round Intent

R65 was scoped to make `/home/operator` a persistent mount point:
init-time probe + mount of `/dev/nvme0` (#1916), real `PATH`/`HOME`
environment prep for every init-launched process (#1918), shell
chdir-to-`$HOME` on entry (#1921), a `boot_r65_persistent_home`
composite smoke proving the mount survives a reboot (#1926), a
`PAIDEIA_R65_PERSIST=1` pre-push gate for that smoke (#1930), a design
doc (#1935), and this closure (#1936).

---

## R65 Landed

- **#1918 R65.M1-002 — Init env prep: PATH + HOME.**
  `src/user/init.pdx` gains `init_env_path`
  (`"PATH=/bin:/usr/bin\0"`), `init_env_home`
  (`"HOME=/home/operator\0"`), and a runtime-populated pointer table
  `_init_envp : [u64; 3]`. Populated once at `_start` (before any
  fork+exec cycle) via the same rodata-strings + `lea`/`mov`-populated
  idiom `dispatch.pdx`'s `builtin_names`/`dispatch_init` already uses
  (R17-m3-004, #624) — paideia-as data initializers take literal
  bytes, not label addresses, so the pointer array must be declared
  `uninit @align(8)` and filled at runtime. All three of init's
  execve sites (`/bin/child_hello`, `/bin/sh`,
  `/bin/elevate_broker_daemon`) now load `rdx` with `&_init_envp`
  instead of zeroing it, activating R62's (12a731a) previously-idle
  envp path. Fingerprint: the existing `sys execve argv ok --
  argc=<N> envc=<M>` (R62, `klog_s1_d2`) now fires with `envc=2`
  instead of `envc=0`.
- **#1935 R65.M1-006 — Design doc.**
  `design/user/persistent-home.md` (new, ~200 lines). Documents the
  intended init-time probe/mount sequence (#1916), the envp work above
  (real, §3), the shell chdir-on-entry design (#1921, deferred, §4),
  the dependency chain back to R64's volume-tooling ELF chain, and an
  explicit honest-scope block distinguishing what is real code from
  what is design-only.
- **#1936 (this doc)** — partial closure retro + `r65-closed` tag.

## R65 Deferred to Debt

- **#1916 R65.M1-001 — init.pdx: probe + mount /dev/nvme0 to
  /home/operator.** Deferred. Its own dependency line names the
  blocker: "R64 (mount.pdxfs / libpdx-volume tooling) must be landed
  so a mountable PDXB volume can exist" — traced through
  `design/round-retrospectives/r64-closure.md` to paideia-as #1730.
  There is currently no PDXB volume anywhere in the paideia-os boot
  path to mount.
- **#1921 R65.M1-003 — Shell cd builtin: chdir to $HOME on entry.**
  Deferred. Notably, this issue is *not* blocked by the same tool-repo
  chain as #1916 — `cd_builtin` (`src/user/dispatch.pdx`, R17-M4 #632)
  is a purely userland `_cwd_buf` write with no kernel-side existence
  check (no `sys_chdir` syscall exists yet; see
  `design/kernel/r17-m4-shell-builtins.md`). It is deferred by choice
  in this wave so that "cd to `$HOME`" lands together with a `$HOME`
  that resolves to a real, mounted directory (#1916) rather than a
  blindly-accepted path string, and so it can be revisited alongside
  the future `sys_chdir` syscall (provisionally tracked as R86 — see
  `design/user/persistent-home.md` §4).
- **#1926 R65.M1-004 — Boot smoke: boot_r65_persistent_home.**
  Deferred; depends on #1916 and #1921 both landing first (the smoke's
  entire premise is a real mount + real cd, then a reboot, then a
  real readback).
- **#1930 R65.M1-005 — PAIDEIA_R65_PERSIST=1 pre-push gate.**
  Deferred alongside #1926 (nothing to gate on yet).

## Cross-Repo Escalations to paideia-as (R65)

**None new.** R65's deferrals trace back to the same paideia-as #1730
gap R64 already surfaced; no additional escalation filed.

## Observable Proof

- `sys execve argv ok -- argc=<N> envc=2` now fires on all three of
  init's execve sites (`/bin/child_hello`, `/bin/sh`,
  `/bin/elevate_broker_daemon`), verifiable on the existing
  `bash tools/run-qemu.sh` boot tape once rebuilt — up from `envc=0`
  pre-landing.
- `HOME=/home/operator` and `PATH=/bin:/usr/bin` are real, readable
  environment strings in every init-launched child's address space
  (per the R62 execve-abi contract, `design/user/execve-abi.md`), even
  though `/home/operator` itself remains tmpfs-backed until #1916
  lands.
- `design/user/persistent-home.md` exists and cross-references
  `design/tooling/volume-tooling-ux.md`, `design/user/execve-abi.md`,
  and `design/user/rootfs-seed-inventory.md` accurately.

## Debt Inventory at R65 Close

1. **#1916** — init-time probe + mount. Blocked on R64's tool-repo
   chain (paideia-as #1730 upstream).
2. **#1921** — shell chdir-on-entry. Deliberately deferred alongside
   #1916 + the future R86 `sys_chdir` syscall.
3. **#1926** — composite smoke. Blocked on #1916 + #1921.
4. **#1930** — pre-push gate. Blocked on #1926.
5. Carried from R64: #1905 bin_seeds three-ELF seed; paideia-as #1730.

**Next Round:** R65's remaining four issues stay open behind the same
paideia-as #1730 → R64 tool-repo chain that gates R64's own closure.
The two items landed here (real envp, design doc) are independently
useful and do not need to be revisited when the chain unblocks — only
#1916/#1921/#1926/#1930 resume, in that dependency order.
