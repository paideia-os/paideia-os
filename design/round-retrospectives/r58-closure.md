# R58 Retrospective (DEFERRED): Shell polish — redirects + /bin/rm/mv/cp/mkdir/touch

**Date:** 2026-08-25
**Milestone:** R58.M5 (single-milestone round; DEFERRED close by this doc)
**Issues:** 1 landed (this closure); 6 deferred to R58 debt.
**HEAD at closure:** bumped by the R58.M5-007 commit that lands this doc.
**paideia-as pinned at:** unchanged — **thirteenth consecutive round**
with zero cross-repo escalations, since R21 close.
**Release tag:** `r58-closed` (deferred-close discipline, mirrors R57 partial).

---

## Round Intent

R58 was scoped to give the shell POSIX redirect syntax (`>`, `>>`, `<`) and
five essential file-management binaries (`/bin/rm`, `/bin/mv`, `/bin/cp`,
`/bin/mkdir`, `/bin/touch`). All five binaries would exercise R56.M3 metadata
syscalls (unlink, rename, open+O_CREAT, mkdir) via userland ELFs following
the R57.M4 /bin/ls, /bin/cat, /bin/ps pattern.

---

## R58 Deferral Rationale

R57 landing surfaced **two paideia-as parser/encoder gaps** in userland
context that persist unfixed at paideia-as HEAD:

1. **P0100 trailing @no_frame** — parser rejects `} @no_frame` at the last
   lambda in a multi-lambda module (not reproducible on siblings that share
   the pattern). Blocked /bin/mount ELF at R57.M4-004 landing.
2. **U1606 imm64 mov** — encoder rejects `mov rax, 0xFFFFFFFFFFFFFFFE` in
   specific contexts. Blocked /bin/ps first-cut at R57.M4-003; workaround
   via r10 staging landed but is invasive.

Both gaps are systemic to userland .pdx patterns and every R58 binary
(rm/mv/cp/mkdir/touch) would land into the same friction pattern. R57
consumed substantial round budget on encoder-gap workarounds; R58 makes
the pragmatic call to defer the userland binaries as a batch until:

- paideia-as fixes the two gaps upstream, OR
- a paideia-os codegen recipe (macro / helper module / pre-check) exists
  that structurally avoids the failing shapes.

Neither prerequisite has landed yet.

---

## R58 Debt Carried Forward

- **#1805 Shell redirect syntax** (`>`, `>>`, `<`) — tokenizer + dispatch
  modifications. Shell code carries additional encoder-gap risk beyond
  new-file userland binaries. Deferred.
- **#1806 /bin/rm** — sys_unlink wrapper.
- **#1807 /bin/mv** — sys_rename wrapper (same-directory only per R56.M3
  posture).
- **#1808 /bin/cp** — open+read+write copy loop.
- **#1809 /bin/mkdir + /bin/touch** — sys_mkdir + sys_open O_CREAT
  wrappers.
- **#1810 boot_r58_shell_b composite smoke** — needs #1805..#1809.
- **R57 debt inherited** (unchanged): /bin/mount, /bin/ps live exercise,
  #1801 shell PATH resolver, #1803 composite smoke, real ELF payloads in
  rootfs_seed.

All kernel-side substrate for R58 (sys_unlink, sys_rename, sys_mkdir,
sys_open+O_CREAT) is already present from R56.M3 (#1793 sys_mkdir/rmdir,
#1794 sys_unlink/rename) and earlier landings. R58 has zero kernel-side
blockers; the gap is purely userland-toolchain.

---

## Cross-Repo Escalations to paideia-as (R58)

**None.** paideia-as pinned unchanged. **Thirteenth consecutive round**
zero escalations. Both blocking encoder gaps are documented in R57
retrospective; formal paideia-as issue filings deferred to a paideia-as
maintenance cycle.

## Observable Proof

Kernel unchanged from R57 close. Substrate boot reaches SHELL START +
`$` prompt.

## Quirks Discovered on Real Hardware

None (R58 ran under QEMU `-kernel`).

**Next Round:** R59 (operator shell walkthrough + pre-push gate). Zero
R58 kernel-side blockers; R59 documentation work is independent of R58
userland binaries.
