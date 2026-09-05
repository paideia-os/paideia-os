# R106 Retrospective: persistent /home substrate (single-user path)

**Date:** 2026-09-05
**Milestones:** R106.M1 (founder placeholder constant, #2228),
R106.M2 (init HOME envp, #2229), R106.M3 (retire /home/operator
hardcode, #2230), R106.M4-KERNEL (shell integration surface, #2231),
R106.M4-USER (tokenizer ~alias, #2342), R106.M5 (persistent-home
smoke, #2232 — ESCALATED), R106.M6 (this closure, #2233).
**Issues closed at landing:** #2228, #2229, #2230, #2231, #2342, #2232.
**HEAD at closure:** paideia-os (this landing).
**Release tag:** `r106-closed` on the landing commit.
**Escalation filed:** #2345 (R106->R107: pull file-bdev forward).

## Round intent

R106 was the persistent-home wave: retire the last inline `/home/
operator` string, name the founder home path by content-addressed
fingerprint (placeholder value for now, real fingerprint at R108),
and prove the path actually persists across a reboot cycle. The
placeholder posture was the deliberate wedge — do the identity
substitution work in R106 so that R108 can flip one constant when
the real trust fingerprint lands instead of touching every consumer.

R106 is a substrate + smoke round. The `.pdx` deltas are small; the
value is in the invariant (one source of truth for the founder home
path) and the wire (envp HOME actually reaching the shell's chdir).

## Per-milestone disposition

### R106.M1 -- founder placeholder constant -- LANDED (#2228)

* `src/user/founder_constants.pdx` module introduced.
* `fc_placeholder_home_path` = `/home/deadbeef00…00` (70 bytes, no
  trailing slash; 64-hex fingerprint placeholder).
* `PAIDEIA_FOUNDER_FP_PLACEHOLDER` = the 64 hex chars alone.
* `tools/build-user.sh` links `founder_constants.pdx` into
  `INIT_OBJECTS` so init.pdx can `lea` the symbol directly.
* Single source of truth — every downstream consumer references
  these symbols rather than duplicating the byte pattern.

### R106.M2 -- init HOME envp -- LANDED (#2229)

* `src/user/init.pdx` fork_exec_shell envp constructor extended:
  the existing `HOME=/home/operator` entry retargeted in place to
  `HOME=<fc_placeholder_home_path>` via a runtime byte-copy loop.
  envp count stays at 2 (`PATH`, `HOME`, NULL); no third entry.
* `src/user/shell.pdx` was already length-agnostic when scanning
  envp for `HOME=` — no code change, just a documentation comment
  affirming the retargeting is safe.
* `sys_chdir` wire (SC+ ID 85, kernel body under
  core/syscall/sys_chdir.pdx) was already end-to-end since
  R86.M1-002 (#1955) + R65v2.M1-003 (#1981) — no fallback path
  needed.
* Fingerprint `init home envp ok [legacy: INIT HOME ENVP OK]`
  fires on every boot post-M2 and cross-checked in run-smoke.

### R106.M3 -- retire /home/operator hardcode -- LANDED (#2230)

* Grep sweep of `src/` and `tests/` for the literal string.
* `src/user/init.pdx`: 6 sites — the rodata literal `home_mount_
  point : [u8; 15] = "/home/operator\0"` was deleted; the sys_mount
  call now `lea`s `fc_placeholder_home_path` directly (length 70).
  Two mount-success fingerprint arrays had their embedded
  `mp=/home/operator` field rewritten to a static placeholder token
  `mp=/home/<fp>` — never the real hex value — so R108.M2's
  fingerprint swap needs no re-edit here.
* `src/user/syscall_shim.pdx`, `src/user/shell.pdx`,
  `src/user/founder_constants.pdx`: comment-only literal removals.
* `tools/verify-fingerprint-coverage.sh`: two allowlist keys
  retargeted to the new marker text (mandatory — the marker
  content legitimately changed).
* `design/user/etc-layout.md`, `content-addressed-identity.md`:
  documentation corrections; historical predecessor mentions in
  wave/round-retrospective docs kept intact.
* `grep -rn '/home/operator' src/ tests/` returns 0 matches.

### R106.M4-KERNEL -- shell integration surface -- LANDED (#2231)

* `src/user/dispatch.pdx` +316L: new `dispatch_from_tokenizer_
  stream` entrypoint consuming an 80-byte fixed-shape token
  record (opcode + arg_count + 8× arg_ptrs). Preserves the
  existing string dispatch path byte-identical.
* Granular `cd` errors — `DFT_CD_NO_ARG` (`E_CD_NO_ARG`),
  `DFT_CD_NOT_A_DIR`, `DFT_CD_NOT_FOUND` — distinct from the
  generic `DFT_OPCODE_INVALID` refusal.
* Fingerprint `dispatch from tokenizer ok`. Failure band
  0xFFFFE920..927 (8 codes used, 8 reserved).

### R106.M4-USER -- tokenizer ~alias -- LANDED (#2342)

* `src/user/tokenizer.pdx` +219L: new `TOK_TILDE_ALIAS` token
  type + `HOME_MARKER` + `E_ALIAS_UNRESOLVED` sentinels.
* Scanner recognizes `~` at token-start (never mid-token), captures
  the following alnum+underscore run as the alias name, emits
  `TOK_TILDE_ALIAS` with the payload.
* Stub resolver `tokenizer_resolve_alias(name_ptr, name_len)`:
  bare `~` returns `HOME_MARKER`; any named alias returns
  `E_ALIAS_UNRESOLVED`. Dispatch-time envp walking is a future
  landing.
* Documented limitation: `~docs/foo` currently tokenizes as two
  tokens (the tilde-run boundary treats `/` as a word terminator).

### R106.M5 -- persistent-home smoke -- ESCALATED (#2232 -> #2345)

* Phase A (boot, write probe, shut down clean) and Phase B (boot
  again, read probe back) both require `sys_mount` `backend_id=5`
  (`SM_BACKEND_PDXFS_BLOCK`) to actually mount a block-backed
  pdxfs volume.
* Confirmed against `src/kernel/core/syscall/sys_mount.pdx:333`
  (per-file justification comment) that the backend=5 arm is
  currently a two-instruction stub returning
  `SYS_MOUNT_UNIMPL_PDXFS_BLOCK` (0xFFFFED63).
* Per this milestone's own escalation instruction, filed #2345
  ("R106->R107 escalation: pull file-bdev forward"). The
  two-phase smoke lands post-#2345.
* R106.M5 closed with escalation reference rather than left open
  as blocked — the escalation is the R106.M5 deliverable in this
  posture.

### R106.M6 -- round closure -- THIS LANDING (#2233)

* This retrospective (`design/round-retrospectives/r106-
  closed.md`).
* `STATUS.md` updated with the R106 close entry.
* Git tag `r106-closed` on the closing commit.
* R107 milestone opened + first-milestone issue filed (#2345
  itself is the M1 candidate; further R107 issues to be filed
  when scope is fixed).
* paideia-as submodule NOT bumped — R106 pulled in no
  paideia-as-side deliverables (the v0.33 crypto bundle in
  task #377 targets R108).

## What shipped vs the plan

Delivered per plan: M1 constant, M2 envp, M3 hardcode retire, M4
integration surfaces (both kernel and user).

Escalated: M5 persistent-home smoke — the underlying block-fs mount
substrate was not real, and per the milestone's own escalation
instruction the correct disposition is a filed R107 blocker rather
than a forced landing over the stub.

Deferred: named-alias resolution beyond bare `~` (blocked on
dispatch-time envp walking) and `~name/path` compound tokenization
(blocked on tokenizer state machine widening). Both filed as
future landings — not on the R106 critical path.

## Cross-repo cascades

None. R106 stayed inside `paideia-os`. The v0.33 crypto bundle
sitting under task #377 continues in paideia-as parallel to R106
and does not gate this round's close.

## Fingerprints landed

Six new markers PASS the coverage gate (784 emitted / 617 asserted
/ 168 allowlisted):

* `init home envp ok`
* `dispatch from tokenizer ok`
* `tokenizer tilde alias ok`
* two `init home mount ok` markers retargeted from mp=/home/
  operator to mp=/home/<fp> placeholder tokens
* R107 escalation captured in #2345 (no fingerprint yet — lands
  with the real backend=5 body)

## Post-round posture

`SHELL START` + `$` prompt still reached on every boot.
`init home envp ok` fires unconditionally at init spawn.
`grep -rn '/home/operator' src/ tests/` returns 0.
R107 milestone is open with #2345 as its first entry.

R106 closes.
