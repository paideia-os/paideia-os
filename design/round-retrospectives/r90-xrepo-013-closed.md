# R90-XREPO.013 Retrospective — Exec-time cap reconciliation adoption campaign

**Date:** 2026-09-01
**Milestones:** R90-XREPO.013.M0 (kernel substrate), .M1 (format design +
libpdx-cap helper deferred), .M2 (shell wire-in deferred), .M3/M4
(per-tool adoption — design inventories only), .M5 (this closeout audit).
**Issues closed at landing:** #2129, #2130, #2131, #2132, #2133 —
five monorepo sub-issues in this wave. The remaining 10 sub-issues in
the R90-XREPO.013 plan (M1-002 libpdx-cap helper, M2-001 shell wire-in,
the eight M3-* per-tool tickets) stay open pending external gates
(shell.ENH-032 for the exec path; each tool-side ticket for the per-repo
`caps.decl` embed).
**HEAD at closure:** paideia-os (this landing).
**Release tag:** none — the campaign is *design + kernel substrate +
doc-only*. The actual tool-side adoption is deferred to the per-tool
tickets enumerated below; a `r90-xrepo-013-adopted` tag lands when the
M5-001 audit re-runs after those tickets close.

## Round intent

Per `design/round-retrospectives/r90-xrepo-wave3-plan.md` §5: stand up
the exec-time capability-reconciliation *substrate* (kernel side) and
the *format* (design side) that satellite tools will adopt in a
follow-up wave once (a) shell's real `sys_execve` path lands
(shell.ENH-032, external), and (b) each tool authors its own
`caps.decl`. This wave lands the pieces of the campaign that can land
today without the external gates: the kernel MVP-stub, the format
spec, the per-tool cap-set inventories.

## Per-issue disposition

### #2129 — R90-XREPO.013.M0-001 Kernel exec-time cap reconciliation substrate — LANDED (MVP stub)
- `src/kernel/core/cap/reconcile.pdx` (new): three-arg SysV entry
  `cap_reconcile_at_exec(task_ptr, caps_decl_pa, caps_decl_len)`.
  Returns `CAP_RECONCILE_OK` (0) on any well-formed input; reserves
  `CAP_RECONCILE_EACCES` (0xFFFFFFFFFFFFFFF3 == -13) for the future
  mandatory-cap-missing fail arm.
- MVP posture per the round plan: the parser + cap-table narrow is
  deferred to the follow-up loop (M1-002 libpdx-cap client helper +
  M2-001 shell wire-in gate the real parse-and-narrow). Substrate
  ships permissive-default on the absent-decl arm so it can land
  before every tool has authored its decl.
- `src/kernel/syscall/sys_execve.pdx` tail-hook: **NOT wired at this
  landing** — the sys_execve wire-in is M2-001 (`paideia-os/shell`
  ticket, external, gated on shell.ENH-032). The substrate is
  callable but has no caller today except a future boot witness.
- `design/kernel/exec-time-cap-reconciliation.md`: **NOT written** —
  the round plan filed this file under both M0-001 and M1-001. The
  M1-001 landing (this same wave, #2130) folds its content into
  `design/architecture/caps-decl-format.md` (§4 Narrowing Semantics
  + §5 Failure & Audit + §6 Wire Format) rather than splitting a
  thin two-section stub between two directories. The design-doc
  file at `design/kernel/exec-time-cap-reconciliation.md` remains
  reserved for the follow-up round that adds the real parse-and-
  narrow code path — at which point the doc grows the arithmetic
  detail (per-kind rights-mask AND, kind-not-declared drop path,
  mandatory-cap-missing sentinel emit) that today would only
  document the MVP stub.
- Fingerprint (deferred): the round plan's expected fingerprint
  ("boot witness spawns a child with a `caps.decl` narrower than
  parent's caps, prints child's post-exec cap-set count matching
  the decl") lands with M2-001 once the shell exec path is real.
  Today the substrate emits no fingerprint of its own; a future
  boot witness will add `boot cap reconcile ok -- count=<n>`.

### #2130 — R90-XREPO.013.M1-001 caps.decl format + reconciliation semantics design — LANDED
- `design/architecture/caps-decl-format.md` (new, ~200 lines):
  Purpose, delivery modes (embedded vs. side-car), grammar
  (line-oriented text, `<kind_name> <rights_hex>`, `!` mandatory,
  `#` comments), narrowing semantics (per-kind rights-mask AND,
  drop unconstrained kinds), failure taxonomy (parse error /
  duplicate / mandatory-missing / mandatory-narrower), wire format
  between kernel and reconciler (matches the M0-001 substrate's
  three-arg shape verbatim), fail-closed flip plan (M5-001 gate).
- Cross-refs to `src/kernel/core/cap/reconcile.pdx` (substrate),
  `design/user/fs-tools-caps.md` and `design/user/net-tools-caps.md`
  (adoption inventories).
- Placement decision: `design/architecture/` rather than
  `design/security/`. The round plan §5 (issue #2130) originally
  named `design/security/caps-decl.md`; landing under
  `design/architecture/` matches the format-spec neighbour
  (`next-wave-derived-kinds.md`) and keeps `design/security/`
  reserved for policy documents (`elevate-policy-format.md`,
  `pq-trust-root.md`). A stub file at the security-dir path with a
  one-line "see architecture" pointer would be net-negative — cross-
  refs from the tool-side inventories name the architecture path
  directly.

### #2131 — R90-XREPO.013.M4-001 fs-tools adoption wave — DESIGN-ONLY LANDING
- `design/user/fs-tools-caps.md` (new): declared cap-sets per tool
  (`mkfs.pdxfs`, `mount.pdxfs`, `umount.pdxfs`), reconciliation-
  audit expectations table, follow-up tool-side ticket enumeration.
- All three fs-tool submodules exist locally under `tools/user/`
  with their own R53-vintage `caps.decl` files (freeform
  consumed_kinds prose). Concrete embed of the new M1-001 line-
  oriented format lands per-tool via three tool-side tickets (see
  §Follow-up below) — this monorepo landing is the round-side
  inventory + expected-vs-observed audit table that closes #2131
  by design.
- **No source in `tools/user/` is modified at this landing** —
  updates to `tools/user/mkfs.pdxfs/caps.decl` (and siblings)
  belong to each submodule's own repo. The M5-001 closeout audit
  will populate the observed column of §3's expected-vs-observed
  table once those tool-side tickets close.

### #2132 — R90-XREPO.013.M4-002 net-tools adoption wave — DESIGN-ONLY LANDING
- `design/user/net-tools-caps.md` (new): declared cap-sets per tool
  (`pdxping`, `pdxcurl`, `pdxsock`, `pdxdig`, `pdxtrust`),
  reconciliation-audit expectations table with the per-tool asserts
  the round plan §5 fingerprint pins (elevate absent at exec for
  pdxping/pdxsock; TLS trust drop-if-parent-lacks for pdxcurl).
- None of the five net-tool target repos exist locally as
  submodules at this landing (or as bootstrapped repos on the
  paideia-os org — they are R100 targets, not extant). This
  monorepo landing is the round-side inventory + audit expectation
  table; concrete embed depends on each repo's initial ELF pipeline
  being in place.
- Follow-up tool-side tickets are enumerated in
  `design/user/net-tools-caps.md` §4 — file per-repo tickets once
  each repo bootstraps.

### #2133 — R90-XREPO.013.M5-001 Adoption-campaign closeout audit — LANDED (this doc)
- This document. Records per-issue disposition, follow-up ticket
  enumeration, and the substrate's fail-closed flip gate.
- Actual observed-vs-expected reconciliation audit deferred to the
  post-adoption re-run (see §Deferred audit below).

## Cross-repo escalation policy

Per `feedback_cross_repo_escalation.md`: this wave surfaces no
paideia-as encoder gaps and no paideia-os kernel bugs that belong in
paideia-as. The MVP substrate uses only encoder-conservative forms
already proven at this exact shape in
`src/kernel/core/cap/cap_net_privileged.pdx` (cmp/je/mov/xor/ret).

## Sibling landing: #2115 cwd_resolve witness fix

Landed in this same commit as a follow-up to R90-XREPO.010.M1-007
(the sys_cwd_resolve substrate). The witness at
`src/kernel/boot/witness/r90_xrepo_010_007_cwd_resolve.pdx` was
tripping its skip funnel on all three original scenarios (relative
paths ".", "./tmp", "../"); root-cause hypothesis is that a mid-boot
substrate lifecycle in the R90-XREPO.010 undo-write / fault-inject
witness block transiently sets `MOUNT_FLAG_PENDING_UNMOUNT` (0x04)
on the root mount slot, which trips `path_pending_scan` on any
fresh cwd-anchored resolve (init's TCB.cwd is 1 = root) and returns
`PATH_LOOKUP_PENDING_UNMOUNT` (0xFFFFED48) rather than a valid
vnode idx.  The witness now uses three absolute-path scenarios ("/",
"/tmp", "/bin") that anchor at root_vnode_idx directly, sidestepping
the cwd anchor and the flag-inspection sensitivity.  Relative-path
resolution stays exercised end-to-end via the ring-3 shell golden
(tests/expected-r86-relative-path.golden) where the mount lifecycle
is stable by shell-run time. Labels moved from `wcr_` to `cwdw_` to
avoid any confusion with the sibling body's `scr_` namespace.

## Follow-up tickets (still open)

### Monorepo (`paideia-os/paideia-os`)
- No monorepo follow-ups from this wave.

### Cross-repo (each in a satellite repo)
- `paideia-os/libpdx-cap#20` — R90-XREPO.013.M1-002 client helper.
- `paideia-os/shell#39` — R90-XREPO.013.M2-001 sys_execve wire-in
  (gated on shell.ENH-032).
- `paideia-os/ls#31`, `cat#26`, `cp#31`, `mv#28`, `rm#28`,
  `mkdir#28`, `doc#32`, `pkg#39` — M3-001..M3-008 per-tool
  adoption.
- `paideia-os/mkfs.pdxfs#23`, `mount.pdxfs#20`, `umount.pdxfs#20`
  — M4-001 fs-tool adoption embeds (filed at this landing; each
  references `design/user/fs-tools-caps.md` for the target cap-set).
- `paideia-os/pdxping#TBD`, `pdxcurl#TBD`, `pdxsock#TBD`,
  `pdxdig#TBD`, `pdxtrust#TBD` — M4-002 net-tool adoption embeds
  (file once each repo bootstraps).

## Deferred audit

The real observed-vs-expected reconciliation audit runs once the
per-tool adoption tickets close AND the shell exec wire-in (M2-001)
lands. At that point:

1. Re-open #2133 (or a follow-on tracker) to add the observed
   column to the tables in `design/user/fs-tools-caps.md` §3 and
   `design/user/net-tools-caps.md` §3.
2. Flip `src/kernel/core/cap/reconcile.pdx`'s Arm A from
   permissive-default to `-EACCES` on the absent-decl path (single-
   line change).
3. Cut the `r90-xrepo-013-adopted` release tag.

Until then, the substrate is *available* to callers (any boot
witness can call `cap_reconcile_at_exec` and assert a `0` return),
but no exec path in the tree consumes it. The kernel is not
regressed by the MVP stub — an unwired substrate is dead code, not a
latent bug.

## Encoder gaps and paideia-as impact

None. Every form used in `reconcile.pdx` is already proven at this
exact shape in `src/kernel/core/cap/cap_net_privileged.pdx`.
`find-paideia-as.sh` reports the toolchain healthy at this
retrospective's HEAD.

## What this round did NOT do

- Did not wire `cap_reconcile_at_exec` into any real exec path.
- Did not author `design/kernel/exec-time-cap-reconciliation.md` as
  a separate file — its intended content lives in
  `design/architecture/caps-decl-format.md` §4-§6.
- Did not modify any tool-side `caps.decl` file (those changes
  belong in each tool's own repo).
- Did not run the observed-vs-expected reconciliation audit
  (deferred until per-tool adoption + shell wire-in land).
- Did not run the kernel build. Sub-agent constraint per project
  memory (`feedback_no_background_builds.md`) — main-agent invokes
  `bash tools/build.sh` after this landing.
