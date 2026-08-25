# R58 Retrospective (PARTIAL v2): Shell polish — redirects + /bin/rm/mv/cp/mkdir/touch

**Date:** 2026-08-25 (updated from initial deferred-close)
**Milestone:** R58.M5 (single-milestone round; PARTIAL close by this doc)
**Issues:** 5 landed + 1 deferred + 1 closure (this doc); previously all
6 substantive issues were deferred but paideia-as fixes (#1327 + #1328
landed at 09309ef) unblocked userland-tail on 2026-08-25.
**HEAD at closure:** bumped by the R58.M5-007 commit that lands this doc
(deb505b wave-1 + bf7a52d wave-2 introduced the substantive landings).
**paideia-as pinned at:** 09309ef (bumped from 4d0e7b3 during PREP,
resolving the P0100 + U1606 blockers documented below).
**Release tag:** `r58-closed` (partial-close discipline; supersedes the
initial deferred-close of the same tag).

---

## Round Intent (unchanged)

R58 was scoped to give the shell POSIX redirect syntax (`>`, `>>`, `<`)
and five essential file-management binaries (`/bin/rm`, `/bin/mv`,
`/bin/cp`, `/bin/mkdir`, `/bin/touch`). All five binaries exercise
R56.M3 metadata syscalls (unlink, rename, open+O_CREAT, mkdir) via
userland ELFs following the R57.M4 /bin/ls, /bin/cat, /bin/ps pattern.

---

## What Actually Landed (post-2026-08-25 reboot)

- **#1806 /bin/rm** — sys_unlink wrapper (SC+ 81). Self-contained ELF
  at `src/user/rm.pdx` + `src/user/rm.ld`. Fingerprint
  `rm ok -- path=/tmp/x`. Hardcoded M0 path per sys_execve §Non-Scope.
- **#1807 /bin/mv** — sys_rename wrapper (SC+ 82). Self-contained ELF
  at `src/user/mv.pdx` + `src/user/mv.ld`. r10 for 4th SysV→SYSCALL
  arg. Fingerprint `mv ok -- from=/tmp/a to=/tmp/b`.
- **#1808 /bin/cp** — open+read+write copy loop. Self-contained ELF
  at `src/user/cp.pdx` + `src/user/cp.ld`. O_TRUNC=0x80 (not 0x200
  which is O_APPEND — verified against `vfs_open.pdx` L37).
  Fingerprint `cp ok -- from=/tmp/a to=/tmp/b bytes=<N>` via
  `cp_print_u64_dec` (adapted from ps.pdx).
- **#1809 /bin/mkdir + /bin/touch** — two self-contained ELFs.
  Fingerprints `mkdir ok -- path=/tmp/newdir` and
  `touch ok -- path=/tmp/x`.
- **#1805 Shell redirect** — tokenizer recognizes `>`, `>>`, `<` as
  hard delimiters; exec_child does open+dup2+close on the child side
  before execve; argv_buf left-compacted so operator+filename don't
  reach exec. Fingerprint from child before execve. Design doc at
  `design/user/shell-io-redirection.md`. Post-fix: added
  `rd_apply_empty_argv` guard for redirect-only lines (debugger flagged
  NULL-deref in resolve_path).

## R58 Deferred to R60+ Debt

- **#1810 boot_r58_shell_b composite smoke** — needs the tmpfs seed to
  hold real /bin/* ELF payloads (kernel-side `bin_seeds.pdx` extension
  is separate work). Tools link and pass per-ELF PT_LOAD lints;
  running them at the interactive shell requires the seed to write
  their real ELFs instead of 9-byte stubs. Same deferral shape as
  R57's `/bin/mount` ELF at #1800.

## Cross-Repo Escalations to paideia-as (R58)

**Two** — filed and landed as part of the 2026-08-25 unblock:

1. **paideia-as #1327 (P0100)** — parser rejected `record` as a binding
   name at multi-lambda module tail. Root cause was NOT trailing
   `@no_frame` as R57 retro speculated; `record` had become a reserved
   keyword since paideia-as #637. Fix at paideia-as 2990651: extended
   `keyword_source_text` + `reserved_keyword_hint(kind, context)` helper.
2. **paideia-as #1328 (U1606)** — encoder rejected `add/sub r64, [mem]`
   base+disp and SIB forms. Fix at paideia-as 09309ef: 4 new helpers
   in encode.rs (03 /r for ADD, 2B /r for SUB) + emission-order tests.

paideia-as bumped 4d0e7b3 → 09309ef; three r10-staged workarounds in
`sys_mountinfo.pdx`, `sys_getdents.pdx`, `tmpfs/vops.pdx` reverted.

**Downstream cascade** on the bump: paideia-as 50301b2 (#1312) landed
between the two pins and enforces C1301 requiring `!{PortIo}` + `@{
paideia.port_io}` on any function using in/out mnemonics. 13 kernel /
user files patched to declare the effect + cap — see wave-1 commit
deb505b. Not a regression; this is the enforcement of a discipline
check that was previously silent.

## Observable Proof

Substrate boot reaches SHELL START + `$` prompt within 30s
(unchanged from R57). All 18 user ELFs now built at
`build/user/*.elf`, including 5 new R58 tool binaries. Per-ELF
`verify-user-image-extent.sh` PT_LOAD budget: each new tool 1-2/16
pages. Cap sidecar disjointness preserved. Fingerprint-coverage
verifier PASS (632 emitted markers, 610 asserted, 22 allowlisted).

## Quirks Discovered on Real Hardware

None — R58 ran under QEMU `-kernel` PVH.

**Next Round:** R59 (operator shell walkthrough) — walkthrough doc
landed at #1814 (`design/testing/operator-getting-started.md`);
composite orchestrator (#1812) + pre-push gate (#1813) still deferred
on the same tmpfs-seed real-payload block as #1810.
