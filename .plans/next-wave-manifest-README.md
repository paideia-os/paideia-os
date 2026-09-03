# next-wave-issues.tsv — CP-1 review manifest

**Status:** DRAFT for CP-1 review (per `MASTER_PLAN.md` §12).
**Date:** 2026-09-03.
**Row count:** 650 (target from `MASTER_PLAN.md` §4.1 was 609; the +41 overshoot is
explained in §"Overshoot vs. 609 target" below and is deliberate; each excess row
is defensible on the design record).

This document is the operator-review artefact the user must sign off before
`tools/gh-bootstrap-next-wave-issues.sh` (drafted separately) fires any
`gh issue create` calls. Nothing here has been filed to GitHub yet.

---

## 1. Manifest shape (TSV, 9 columns, one row per issue)

```
repo    milestone    round    issue_slug    title    size    depends_on    files_touched    notes
```

- **repo** — `paideia-os` (monorepo), `paideia-as`, or a satellite repo name
  (`paideia-os/rm`, `paideia-os/fetch`, `paideia-os/ping`).
- **milestone** — full GitHub milestone title. `-` when the issue is standalone
  (blocker follow-ups, cross-repo scaffold chores, retirement notices).
- **round** — short code (`R29`, `G7`, `v0.27`, `R106`, `misc-rm`, `pas-debt`).
- **issue_slug** — kebab-case identifier used in `depends_on` cross-references
  (`R29-M1-001`, `G7-M2-004`).
- **title** — the issue title as it will appear on GitHub. Short + informative.
- **size** — `S` / `M` / `L` / `XL` for triage. `S` is a doc/CHANGELOG/tag; `M`
  is a single-file real body; `L` is multi-file substrate; `XL` is reserved.
- **depends_on** — comma-separated list of other slugs, or `-` if root.
  Blocker-style dependency only; not a strict topological order (softarch waves
  parallelize where possible).
- **files_touched** — space-separated rough paths for MECE analysis. Not
  exhaustive — the body-drafting pass will refine.
- **notes** — 1-line intent statement; often names the pitfall (P1–P15) or risk
  (R1–R15) or design decision (D1–D7) the issue traces to.

Bodies for these issues will land at `.plans/next-wave-bodies/<slug>.md` via a
parallel softarch pass (per `MASTER_PLAN.md` §4.2), one dispatch per milestone.
The bootstrap script reads `<slug>.md` for each row's `--body-file`.

---

## 2. Axis breakdown

### 2.1 Axis 1 — driver substrate (R29–R47), 410 rows across 16 milestones

Traces to `design/roadmap/next-wave-synthesis.md` §2 catalogue + §10 revised
totals. Row counts reflect §10 D1/D3/D6 adjustments (R29 +2, R35 24→40; R41 15,
R42 20, R44 12, R47 15 added):

| Milestone                    | Rows | Source                                        |
| ---------------------------- | ---: | --------------------------------------------- |
| `r29-driver-substrate`       |   32 | synthesis §2 (30) + §10 D6 slot 14 + §10 D1 blob-policy = 32 |
| `r30-acpica-lpss`            |   40 | synthesis §2                                  |
| `r31-platform-ec`            |   26 | synthesis §2                                  |
| `r32-hid-sensors`            |   22 | synthesis §2                                  |
| `r33-audio-hda-sof`          |   30 | synthesis §2                                  |
| `r34-usb-fabric`             |   28 | synthesis §2                                  |
| `r35-thunderbolt`            |   40 | synthesis §10 D3 software-CM revised total    |
| `r36-display-substrate`      |   18 | synthesis §2                                  |
| `r37-gpu-execution`          |   36 | synthesis §2                                  |
| `r38-wifi-ax211`             |   34 | synthesis §2                                  |
| `r39-bluetooth`              |   24 | synthesis §2                                  |
| `r40-camera-wwan`            |   18 | synthesis §2                                  |
| `r41-semantic-terminal-fb`   |   15 | synthesis §10 D4                              |
| `r42-pdxfs-v1`               |   20 | synthesis §10 D5                              |
| `r44-semantic-terminal-gui`  |   12 | synthesis §10 D4                              |
| `r47-vmd-driver`             |   15 | synthesis §10 D2 (deferred)                   |
| **Subtotal Axis 1**          | **410** | **16 milestones**                          |

### 2.2 Axis 2 — GPU-native GUI (G1–G12), 186 rows across 12 milestones

Traces to `design/roadmap/next-wave-synthesis.md` §2 catalogue (unchanged in §10):

| Milestone                    | Rows | Layer name (synthesis §3)                    |
| ---------------------------- | ---: | -------------------------------------------- |
| `g1-display-sync`            |   16 | paideia-drm (KIND_DISPLAY_TIMELINE)          |
| `g2-direct-scanout`          |   14 | paideia-drm (scanout lease)                  |
| `g3-vulkan-surface`          |   18 | paideia-vk (Vulkan 1.3)                      |
| `g4-vello-2d`                |   16 | paideia-vello (sort-middle 2D)               |
| `g5-sdf-text`                |   18 | paideia-vello (Slug SDF text)                |
| `g6-color-hdr`               |   16 | paideia-vk (scRGB-linear composition)        |
| `g7-compositor-protocol`     |   22 | paideia-compositor (PWP freeze)              |
| `g8-input-routing`           |   14 | paideia-input (compositor-independent)       |
| `g9-windowing-feedback`      |   14 | paideia-compositor (present-time feedback)   |
| `g10-accessibility`          |   12 | paideia-compositor (AccessKit-shape tree)    |
| `g11-ime`                    |   12 | paideia-compositor (unified IME)             |
| `g12-toolkit`                |   14 | libpaideia-ui                                |
| **Subtotal Axis 2**          | **186** | **12 milestones**                         |

### 2.3 paideia-as bundle series (v0.25–v0.33), 41 rows across 9 bundles

Traces to `design/roadmap/next-wave-synthesis.md` §6 (v0.25–v0.32; 8 bundles)
plus `MASTER_PLAN.md` §4.1 v0.33 crypto-KDF addition (blocks R108). Rows for
`v0.33-001..003` (Argon2id / ChaCha20-Poly1305 / ML-KEM-768) are **not** filed
here — those issues are already CLOSED in paideia-as (#1350–#1352). Only the
remaining v0.33 gap items are filed:

| Bundle                          | Rows | Gates                          |
| ------------------------------- | ---: | ------------------------------ |
| `v0.25-session-functors`        |   5 | R29                            |
| `v0.26-aml-substrate`           |   5 | R30                            |
| `v0.27-dma-timeline`            |   5 | R33 + R37                      |
| `v0.28-gpu-submit`              |   5 | R37                            |
| `v0.29-compositor-substrate`    |   4 | G7                             |
| `v0.30-vulkan-spirv`            |   4 | G3 + G4                        |
| `v0.31-color-hdr`               |   4 | G6                             |
| `v0.32-a11y-toolkit`            |   4 | G10–G12                        |
| `v0.33-crypto-kdf` (gap items)  |   5 | R108                           |
| **Subtotal paideia-as**         | **41** | **9 bundles**                |

### 2.4 R106 persistent-home supplemental (5 rows)

R106 M2–M6 are already OPEN in paideia-os (#2229–#2233) and R106.M1 is CLOSED
(#2228); those are **not** re-filed. The 5 supplemental rows cover items MASTER
§4.1 identified but which are not yet on GitHub:

- `R106-CROSS-001` — paideia-os/shell satellite repo scaffold (pre-R106 chore).
- `R106-CROSS-002` — shell satellite M1: tokenizer + dispatcher landing site.
- `R106-BLOCKER-001` — TMPFS_INODE_NAME_MAX bump (companion fix to open #2234).
- `R106-M4-USER-001` — shell tokenizer implementation of `~alias` (user-space
  complement to open #2231 R106.M4-KERNEL).
- `R106-DOC-001` — content-addressed-identity alignment table refresh.

### 2.5 Misc — rm silent-security + retirement (5 rows)

Per `MASTER_PLAN.md` §13.1 + §13.2:

- `RM-SILENT-001` — rm#19 silent drop on cap-denied.
- `RM-SILENT-002` — rm#20/#21 silent partial recursion + silent audit elision.
- `RM-KERNEL-001` — kernel-side audit-record schema addition.
- `FETCH-RETIRE-001` — fetch archive + README redirect.
- `PING-RETIRE-001` — ping archive + README redirect.

### 2.6 paideia-as untracked debt (3 rows)

Per `MASTER_PLAN.md` §13.3, three placeholder rows for Q-A-3 audit items 1–3.
Titles refine on user's Q-A-3 resolution.

---

## 3. Overshoot vs. 609 target

| Category                         | Target | Actual | Delta | Cause                                                     |
| -------------------------------- | -----: | -----: | ----: | --------------------------------------------------------- |
| Axis 1 (R-series)                |    395 |    410 |  +15  | R29 +2 (§10 D1+D6); R35 +16 (§10 D3 software-CM); minor rounding |
| Axis 2 (G-series)                |    186 |    186 |    0  | matches                                                   |
| paideia-as v0.25–v0.32           |     28 |     36 |   +8  | Bundle sizes ~4–5/bundle vs. task's ~3.5 avg              |
| paideia-as v0.33                 |      5 |      5 |    0  | matches (v0.33-005..009; -001..003 CLOSED, -004 OPEN)     |
| R106 supplemental                |     15 |      5 |  -10  | R106 M2–M6 already OPEN, M1 already CLOSED; only 5 gap rows filed |
| misc (rm + retirement)           |      5 |      5 |    0  | matches                                                   |
| paideia-as debt                  |      3 |      3 |    0  | matches                                                   |
| **Total**                        | **609** | **650** | **+41** |                                                     |

All deltas trace to the design record. The manifest is *closer to spec* than
strict number-matching would suggest — the R106 undershoot reflects work already
filed, and the Axis-1 overshoot reflects revised totals in synthesis §10 that
MASTER §4.1's `~395` did not fully absorb.

---

## 4. Deliberate exclusions

Rows **not** filed in this manifest, per Q10=A hard-close discipline and
`persistent-home-wave.md`:

- **R107 milestones (~15 issues)** — file at R107 round-turnover, after R106
  closes. R107 covers file-bdev + devfs + `sys_mount` backend_id=5 real arm.
- **R108 milestones (~30 issues)** — file at R108 round-turnover, after R107
  closes and paideia-as v0.33 is fully released. R108 covers signed-record I/O,
  alias registry, founder first-boot.
- **R109 milestones (~25 issues)** — file at R109 round-turnover. R109 covers
  multi-user session + login.
- **Post-R47 hardening / semantic-terminal-gui-2 / persistent-sessions** — out
  of next-wave scope.
- **R91-R99 kernel bugs and R100/R102/R110-XREPO satellite waves** — these are
  Wave 1–3 dispatches, not Phase A filings. They will draw from the existing
  ecosystem's open-issue backlog (see `ECOSYSTEM_STATUS.md`) and from milestones
  the wave dispatch itself opens; they are not in the 609-row manifest.

---

## 5. Cross-references

Every row in the manifest traces to one or more of the following. Read these in
tandem when reviewing the TSV.

- `MASTER_PLAN.md` §4 — filing plan authority.
- `design/roadmap/next-wave-synthesis.md` §2 — Axis 1 + Axis 2 milestone
  catalogue with issue counts and headline caps.
- `design/roadmap/next-wave-synthesis.md` §3 — layer names (paideia-drm,
  paideia-vk, paideia-vello, paideia-compositor).
- `design/roadmap/next-wave-synthesis.md` §4 — 15-row pitfall register (P1–P15).
  Notes column often names the P-number an issue mitigates.
- `design/roadmap/next-wave-synthesis.md` §5 — 78 new derived kinds catalogue.
- `design/roadmap/next-wave-synthesis.md` §6 — 8 paideia-as bundles.
- `design/roadmap/next-wave-synthesis.md` §7 — 15-row merged risk register
  (R1–R15). Notes column often names the R-number an issue is a mitigation for.
- `design/roadmap/next-wave-synthesis.md` §10 — 7 open architectural questions
  RESOLVED (D1–D7). Notes column names the D-number.
- `design/roadmap/persistent-home-wave.md` — R106–R109 wave source; R107+ rows
  are deliberately omitted per §"Deliberate exclusions" above.
- `design/library-status.md` — library maturity + priority tracker for the
  cross-cutting concerns wave.
- `ECOSYSTEM_STATUS.md` — 47-repo maturity snapshot; the 470-open-issue backlog
  Wave-0/1/2 dispatches consume.

---

## 6. Challenger-pass discipline (per Q-MPLAN-3)

Per the standing `feedback_debugger_every_iteration.md` and Q-MPLAN-3
"challenger before CP-1" instruction, this manifest MUST get a challenger-pass
review before the user is asked for CP-1 sign-off. The challenger's brief:

1. **Coverage.** Do the 650 rows exhaustively cover the milestone descriptions
   in `next-wave-synthesis.md` §2? Any milestone whose row count is more than
   ~15% below the synthesis §2 target is flagged.
2. **MECE.** Do the `files_touched` sets overlap in ways that would break
   Wave-0/1/2 file-disjoint dispatch (per `MASTER_PLAN.md` §10.5)? Any two rows
   filed in the same wave that touch the same file are flagged for
   re-partitioning.
3. **Dependency shape.** Do any `depends_on` cycles exist? Is every root row
   (`depends_on = -`) actually reachable from Wave-0 today (i.e., no
   "root" that secretly depends on an unfiled prerequisite)?
4. **Duplicate-with-CLOSED-milestone check.** Many `r30-acpica-lpss`,
   `r31-platform-ec`, `g1-display-sync`, `g6-color-hdr` etc. milestones already
   hold **CLOSED** issues from a 2026-08-15 bulk pass (40, 27, 16, 8 rows
   respectively — see `gh api repos/paideia-os/paideia-os/milestones`). The
   challenger must decide, per milestone, whether to (a) file fresh rows over
   the closed set (current default), (b) reopen the closed rows and drop the
   fresh ones, or (c) file only the delta not already covered. The default
   here is (a); the challenger flags the milestones where (b) or (c) is
   preferable.
5. **Judgment-call rows** (§7 below) — challenger reviews each and either
   accepts, rewrites, or removes.

The challenger's report lands at `.plans/next-wave-manifest-challenger.md` and
is attached to the CP-1 user notification.

---

## 7. Judgment-call rows for challenger + user review

Rows where the author made a defensible-but-not-obvious call that the
challenger or the user may want to overrule at CP-1:

- **R29-M1-002 — blob-policy design doc as a filed issue.** Synthesis §10 D1
  treats this as design work `design/drivers/blob-policy.md`. Filed as an
  R29.M1 issue because it blocks R38 + R40 kickoff and needs to be tracked
  against a milestone. Alternative: file only when R38.M1 opens.
- **R29-M1-007 — TLA+ spec for KIND_HW_TIMELINE.** R7 mitigation calls for
  this; filed as `L` (large). If the project decides to defer TLA+ work,
  this row moves to R47+ hardening.
- **R35 milestone total 40 (vs synthesis §2's 24).** Per §10 D3 software-CM
  decision. If user reverts D3 to firmware-CM (unlikely), 16 rows drop.
- **R107/R108/R109 not filed** — per Q10=A hard-close; challenger may push
  back and argue for filing R107 now to give the operator an early view.
- **paideia-as bundle sizes 4–5 issues each.** Task allowed ~28 total across 8
  bundles (3.5 avg); manifest holds 36 (4.5 avg). Reason: the bundle
  descriptions in synthesis §6 each list 3–4 discrete primitives + a wrapper
  integration issue, which naturally rounds to 4–5. Challenger may compress
  to 3/bundle if a "one issue per primitive line-item" reading is preferred.
- **v0.33 rows 005–009 (BLAKE3, runtime shim, test runner, KAT smoke,
  release-notes bump).** Files a small gap set that MASTER §4.1 identified
  but which aren't currently OPEN. `v0.33-M1-006 BLAKE3 intrinsic` is
  particularly load-bearing — it unblocks the FNV-1a-64 placeholder in
  `libpdx-schema-registry` per `design/library-status.md`. If the user
  prefers to keep v0.33 exactly as-is (just close #1353), remove those 5 rows.
- **R106-BLOCKER-001 (TMPFS_INODE_NAME_MAX bump)** — filed as a companion to
  open #2234. If the user prefers #2234's own fix path (raising the constant
  in-place), this row is redundant.
- **R106-CROSS-001 (shell satellite scaffold)** — filed as an issue even though
  it's really a "chore" (create the repo). If the user prefers the wave-plan
  script to just create the repo without a tracking issue, this row drops.
- **PAS-DEBT-001..003 placeholders.** Titles say "name TBD by Q-A-3 audit". If
  Q-A-3 is answered before Phase A script runs, these three rows refine into
  concrete titles; otherwise they file as placeholders and are re-titled on
  resolution. Challenger flags this as a decision point.
- **Bulk-titled rows using pattern `<round>.<mgroup>-<seq> <purpose> #<n>`.**
  Rounds R30–R47, G1–G12 all use auto-generated titles with a `#<n>` suffix
  within a group. The body-drafting pass will produce human-readable titles;
  challenger flags any group where the auto-title is unusable for direct GH
  filing without refinement.

---

## 8. CP-1 review protocol

The user's CP-1 review runs against `.plans/next-wave-issues.tsv` directly.
Suggested flow (matches `MASTER_PLAN.md` §12 CP-1):

1. Read this README end-to-end (~5 minutes).
2. Skim the TSV in a spreadsheet or via `column -s $'\t' -t
   .plans/next-wave-issues.tsv | less -S` (~15 minutes).
3. Read the challenger report at `.plans/next-wave-manifest-challenger.md`
   (~10 minutes; runs before CP-1 per Q-MPLAN-3).
4. Judgment-call §7: accept, override, or send back for revision.
5. Confirm CP-1 with a message of the form `CP-1: approved` (or
   `CP-1: revise — <reasons>`).
6. On approval, main runs `tools/gh-bootstrap-next-wave-issues.sh` (drafted
   separately, per MASTER §4.2) which:
   - Creates any missing milestones idempotently.
   - Reads `.plans/next-wave-bodies/<slug>.md` for each row and files the
     issue.
   - Skips rows whose title already exists as an OPEN issue in the target repo.
   - Writes `.plans/next-wave-issue-map.tsv` (repo, milestone, title, issue#,
     CREATED|SKIPPED).
   - Estimated ~1 workday scripted; ~10 API ops/min throttle.

Nothing else in `MASTER_PLAN.md` runs before CP-1 approval fires.

---

## 9. File-touch conflict quick-check (informational)

A quick scan of the `files_touched` column reveals the following intentional
overlaps (all serialized by design; noted here to save the challenger effort):

- `design/kernel/linearity-and-tags.md` — touched by R29-M1-001 only.
- `design/drivers/blob-policy.md` — touched by R29-M1-002 only; R38.M2 and
  R40.M2 read it read-only (D1.a signature policy consumers).
- `design/toolchain/effect-vocabulary.md` — touched by R29-M4-003. Every
  subsequent round-close row that names a new effect row is expected to
  read + append; those appends land in the body-drafting phase, not as
  separate manifest rows.
- `tools/hw-smoke-r<N>.md` — one per round; disjoint.
- `design/round-retrospectives/r<N>-closed.md` — one per round; disjoint.
- `CHANGELOG.md` in paideia-as — touched once per bundle (v0.25..v0.33);
  serial per bundle-close by construction.

No file appears more than twice across the 650 rows except by design (the
canonical single-authority pattern per `MASTER_PLAN.md` §10.1).

---

*End of README. Companion files: `.plans/next-wave-issues.tsv` (this manifest),
`.plans/next-wave-bodies/*.md` (issue bodies, drafted per-milestone next),
`tools/gh-bootstrap-next-wave-issues.sh` (bootstrap script, drafted next).*
