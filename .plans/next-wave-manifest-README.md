# next-wave-issues.tsv — CP-1 v2 review manifest

**Status:** DRAFT for CP-1 v2 review (per `MASTER_PLAN.md` §12).
**Date:** 2026-09-03.
**Row count:** 141 (down from v1's 650 after challenger-pass pruning; see §"What changed vs. v1" below).
**Prior version:** v1 at commit `d421c2b` (650 rows); a challenger pass identified 10 defects, all addressed here.

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
  (blocker follow-ups, cross-repo scaffold chores, umbrella issues).
- **round** — short code (`G6`..`G12`, `v0.25`..`v0.33`, `R106`, `pas-debt`).
- **issue_slug** — kebab-case identifier used in `depends_on` cross-references
  (`G7-M1-001`, `v0.25-M1-001`).
- **title** — the issue title as it will appear on GitHub. Short + informative.
  In v2 every G7–G12 title is hand-drafted per challenger §5.5.
- **size** — `S` / `M` / `L` / `XL` for triage. `S` is a doc/CHANGELOG/tag; `M`
  is a single-file real body; `L` is multi-file substrate; `XL` is reserved.
- **depends_on** — comma-separated list of other slugs, or `-` if root.
  Blocker-style dependency only; not a strict topological order (softarch waves
  parallelize where possible). **v2 rule:** must be a valid comma-separated
  slug list or `-`; prose entries are rejected (was 15 prose entries in v1).
- **files_touched** — space-separated rough paths for MECE analysis. **v2 rule:**
  within any single milestone, every row's `files_touched` must be disjoint
  from its siblings' — no two rows in the same milestone edit the same file.
- **notes** — 1-line intent statement; often names the pitfall (P1–P15) or risk
  (R1–R15) or design decision (D1–D7) the issue traces to.

Bodies for these issues will land at `.plans/next-wave-bodies/<slug>.md` via a
parallel softarch pass (per `MASTER_PLAN.md` §4.2), one dispatch per milestone.
The bootstrap script reads `<slug>.md` for each row's `--body-file`.

---

## 2. What changed vs. v1 (challenger findings applied)

A challenger pass on v1 (650 rows) found that ~510 of those rows duplicated
CLOSED GitHub work from the 2026-08-15 bulk pass (sample: `#1049` closed by
`ee3227d`; `#1289` closed by `d4793c2`). Refiling them would double-book done
work. v2 drops every row that CLOSED issues already cover.

### 2.1 Deletions (509 rows dropped)

| Bucket | v1 rows | v2 rows | Reason |
|---|---:|---:|---|
| R29–R47 driver substrate (16 milestones) | 410 | 0 | CLOSED on GH via 2026-08-15 bulk pass; tag with `next-wave-phase-a-covered` label instead — see §5.1 |
| G1–G5 GPU-native GUI foundation (5 milestones) | 82 | 0 | CLOSED on GH; same label plan |
| G6 color/HDR (partial) | 16 | 7 | Kept the 7-row output-transform + tonemap + reference-display delta not covered by CLOSED `#1509`..`#1516`; see §5.2 |
| R106 blocker follow-up | 5 | 4 | Dropped `R106-BLOCKER-001` — duplicate of open `#2234` Option 1 |
| rm silent-security (3 rows) + retirement (2 rows) | 5 | 0 | Dropped: existing open issues cover them; addressed in-place, no new rows — see §5.3 and §5.4 |
| paideia-as debt placeholders `PAS-DEBT-001..003` | 3 | 1 | Replaced with a single umbrella `PAS-DEBT-CATALOG` per Q-A-3 resolution — see §5.5 |
| **Deleted total** | **-509** | | |

### 2.2 Rewrites (88 rows rewritten in place)

| Bucket | v1 titles | v2 titles |
|---|---|---|
| G7–G12 (88 rows) | Auto-scaffolded with `#1 / #2 / #3` suffixes and shared per-M `files_touched` | Every title hand-drafted per challenger §5.5, and every row split onto a distinct sibling file (per-file MECE discipline; challenger §4) |

### 2.3 Normalisation (15 depends_on entries fixed)

Prose `depends_on` entries — `"R28 MVP xHCI"`, `"R22 VT-d+IR"`, `"G1..G6"`,
`"G7 + R32"`, `"G5 + G7"`, `"G7..G11"`, and others — either lived in rows that
are now deleted, or, for the survivors, were rewritten to reference in-manifest
slugs or `-` (with the external prerequisite noted in `notes`). Every remaining
`depends_on` is a valid comma-separated slug list or `-`.

### 2.4 Row-count reconciliation

| Bucket | v1 | v2 | Delta |
|---|---:|---:|---:|
| Axis 1 (R29–R47) | 410 | 0 | -410 |
| Axis 2 (G1–G5) | 82 | 0 | -82 |
| Axis 2 (G6 delta) | 16 | 7 | -9 |
| Axis 2 (G7–G12) | 88 | 88 | 0 (rewritten) |
| paideia-as v0.25–v0.33 | 41 | 41 | 0 |
| R106 supplemental | 5 | 4 | -1 |
| pas-debt | 3 | 1 | -2 |
| misc (rm + retire) | 5 | 0 | -5 |
| **Total** | **650** | **141** | **-509** |

Row-count target from the task was `~130-150`; v2 lands at **141**. The 88
G7–G12 rows carry across because that substrate is genuinely un-started.

---

## 3. Axis breakdown (v2)

### 3.1 G6 color/HDR delta — 7 rows

Kept only rows not covered by CLOSED `#1509`..`#1516`:

| Sub-group | Rows | Covers |
|---|---:|---|
| G6-M4 (HDR output transforms + `KIND_HDR_METADATA`) | 3 | HDR10 PQ, HLG, DV metadata |
| G6-M5 (tone-mapping LUT + `KIND_TONEMAP_LUT`) | 2 | LUT storage schema, BT.2408 reference curves |
| G6-M6 (reference-display metadata + BT.2100) | 2 | `KIND_REFERENCE_DISPLAY`, BT.2100 helpers |

**Ambiguity flag (for CP-1 v2 reviewer):** CLOSED `#1515` "EOTF/OETF pipeline
(sRGB, PQ, HLG, DolbyVision)" may partially overlap `G6-M4-003` KIND_HDR_METADATA
if its scope included metadata channels. The row is kept and marked
`AMBIGUOUS` in `notes`; reviewer should either drop it or confirm it as a
gap-fill.

### 3.2 G7–G12 GPU-native GUI stack — 88 rows

Titles hand-drafted per synthesis §2 layer descriptions and pitfall register.
Per-milestone breakdown:

| Milestone | Rows | Layer (synthesis §3) | Headline pitfalls mitigated |
|---|---:|---|---|
| `g7-compositor-protocol` | 22 | paideia-compositor (PWP freeze) | P1, P3, P8, P11; risk R1 |
| `g8-input-routing` | 14 | paideia-input | P2 |
| `g9-windowing-feedback` | 14 | paideia-compositor | P6 |
| `g10-accessibility` | 12 | paideia-compositor (a11y-tree) | P4 |
| `g11-ime` | 12 | paideia-compositor (IME) | P10 |
| `g12-toolkit` | 14 | libpaideia-ui + samples | — |

Every row's `files_touched` is disjoint from its milestone siblings (per-file
MECE discipline; see §4 below).

### 3.3 paideia-as v0.25–v0.33 bundles — 41 rows

Nine bundles carried across from v1 unchanged. Each bundle closes with
workspace-version bump + git tag + CHANGELOG entry per
`feedback_paideia_as_version_discipline.md`.

| Bundle | Rows | Gates |
|---|---:|---|
| `v0.25-session-functors` | 5 | R29 (CLOSED) |
| `v0.26-aml-substrate` | 5 | R30 (CLOSED) |
| `v0.27-dma-timeline` | 5 | R33 + R37 (CLOSED) |
| `v0.28-gpu-submit` | 5 | R37 (CLOSED) |
| `v0.29-compositor-substrate` | 4 | G7 |
| `v0.30-vulkan-spirv` | 4 | G3 + G4 (CLOSED) |
| `v0.31-color-hdr` | 4 | G6 (mostly CLOSED + delta) |
| `v0.32-a11y-toolkit` | 4 | G10–G12 |
| `v0.33-crypto-kdf` (gap items) | 5 | R108 |

### 3.4 R106 persistent-home supplemental — 4 rows

R106 M2–M6 are already OPEN in paideia-os (`#2229`..`#2233`) and R106.M1 is
CLOSED (`#2228`); those are not re-filed. The v1 supplemental set of 5 was
reduced to 4 by dropping `R106-BLOCKER-001` (duplicate of open `#2234`).

- `R106-CROSS-001` — paideia-os/shell satellite repo scaffold.
- `R106-CROSS-002` — shell satellite M1: tokenizer + dispatcher landing site.
- `R106-M4-USER-001` — shell tokenizer implementation of `~alias`.
- `R106-DOC-001` — content-addressed-identity alignment table refresh.

### 3.5 paideia-as untracked debt — 1 umbrella row

`PAS-DEBT-CATALOG` replaces v1's three `PAS-DEBT-001..003` placeholders per
challenger §5.6. This single `L`-sized umbrella issue commissions the
categorisation of pre-existing `build_emit` failures, parser gaps and intrinsic
TODOs, and files per-item sub-issues from its own body. Sub-issues do NOT
appear in this manifest.

---

## 4. MECE conflict quick-check (v2)

Every row's `files_touched` set is disjoint from every other row in the same
milestone. Verified programmatically:

```
awk -F'\t' 'NR>1 {print $2"\t"$8}' .plans/next-wave-issues.tsv \
  | sort | uniq -c | awk '$1>1 && $3!="-"'
```

returns no rows.

Cross-milestone reads (e.g., G8 input server reads a G7 KIND_WINDOW cap) are
expected and are recorded via `depends_on`, not treated as file conflicts.

---

## 5. Retirement / follow-up actions living OUTSIDE this manifest

These items are real work but are executed by hand or by scripts other than
the bootstrap; they are documented here so the CP-1 v2 reviewer can confirm
they will happen.

### 5.1 Label the CLOSED next-wave-covered set

Propose a `next-wave-phase-a-covered` label on `paideia-os/paideia-os` and
apply it to every CLOSED issue in the R29..R47 and G1..G5 milestones from the
2026-08-15 bulk pass, plus the 8 CLOSED G6.M1/M2 issues (`#1509`..`#1516`).
This is a one-shot `gh label create` + `gh issue edit --add-label` script;
NOT filed as a manifest row. Purpose: makes the retrospective queryable in
one filter.

### 5.2 G6 delta ambiguity (see §3.1)

Reviewer confirms or rejects `G6-M4-003`.

### 5.3 rm silent-security — address IN-PLACE

The 4 relevant issues are already OPEN in `paideia-os/rm` and are Wave-0
priorities. Address them directly; do NOT file new manifest rows.

- `rm#19` = `SECURITY: elevate gate matches unresolved argv bytes`
- `rm#20` = `SECURITY: --wipe takes no elevate hop on non-/system targets`
- `rm#21` = `SECURITY: blocked removals return exit 0 (fail-open reporting)`
- `rm#22` = `-r path emits no audit, schema, undo or retention records`

### 5.4 fetch + ping retirement

Do NOT file new retirement issues. Close the existing `#3` retrospective
issues in each repo manually when the retirement lands (per Q-MPLAN-4 =
manual archive). This is a Main-turn action after the retirement PR merges.

### 5.5 paideia-as debt catalog (Q-A-3 umbrella)

`PAS-DEBT-CATALOG` is the sole manifest entry for the debt work. The
sub-issues it files at triage time are excluded from this manifest by design
(they are the catalog's own output, sized after audit).

---

## 6. Deliberate exclusions (unchanged from v1)

Rows **not** filed in this manifest, per Q10=A hard-close discipline and
`persistent-home-wave.md`:

- **R107 milestones (~15 issues)** — file at R107 round-turnover.
- **R108 milestones (~30 issues)** — file at R108 round-turnover.
- **R109 milestones (~25 issues)** — file at R109 round-turnover.
- **Post-R47 hardening / semantic-terminal-gui-2 / persistent-sessions** — out
  of next-wave scope.
- **R91-R99 kernel bugs and R100/R102/R110-XREPO satellite waves** — Wave 1–3
  dispatches, not Phase A filings.

---

## 7. Cross-references

- `MASTER_PLAN.md` §4 — filing plan authority.
- `design/roadmap/next-wave-synthesis.md` §2 — Axis 2 milestone catalogue.
- `design/roadmap/next-wave-synthesis.md` §3 — layer names (paideia-drm,
  paideia-vk, paideia-vello, paideia-compositor).
- `design/roadmap/next-wave-synthesis.md` §4 — 15-row pitfall register
  (P1–P15).
- `design/roadmap/next-wave-synthesis.md` §5 — 78 new derived kinds.
- `design/roadmap/next-wave-synthesis.md` §6 — 8 paideia-as bundles.
- `design/roadmap/next-wave-synthesis.md` §7 — 15-row merged risk register
  (R1–R15).
- `design/roadmap/next-wave-synthesis.md` §10 — D1–D7 resolutions.
- `design/roadmap/persistent-home-wave.md` — R106–R109 wave source.
- `design/library-status.md` — library maturity tracker.
- `ECOSYSTEM_STATUS.md` — 47-repo maturity snapshot.

Prior challenger report (v1 pass) lives in this session's transcript; a
condensed record of its 10 findings is in §2 above.

---

## 8. What the CP-1 v2 reviewer should verify

1. **The 509 deletions are legitimate.** Spot-check a handful of R29/R35/G4
   rows to confirm the CLOSED-on-GH claim (sample: `gh issue view 1049` —
   should show CLOSED, closed by `ee3227d`).
2. **G6 delta ambiguity (§3.1).** Decide `G6-M4-003` keep vs. drop.
3. **G7–G12 titles read as substrate deliverables**, not as "row #1 of a
   set". Any title that says WHAT rather than WHERE-IN-A-SERIES is passing;
   any that still reads like a placeholder is a defect.
4. **Per-file MECE in G7–G12.** Run the awk one-liner in §4; confirm empty
   output.
5. **`depends_on` is all slugs or `-`.** Run:
   ```
   awk -F'\t' 'NR>1 {print $7}' .plans/next-wave-issues.tsv \
     | grep -vE '^(-|[A-Za-z0-9._,-]+)$'
   ```
   Should be empty.
6. **Row count.** `wc -l` should report `142` (141 rows + 1 header). If the
   count drifts, some row was double-added or lost.
7. **The five OUTSIDE-manifest follow-ups (§5).** Confirm they are agreed
   actions for Main / manual triage rather than gaps in the manifest.
8. **The umbrella substitution (§3.5).** Confirm you are content with a single
   `PAS-DEBT-CATALOG` row instead of three placeholders.

---

## 9. CP-1 review protocol (unchanged from v1)

The user's CP-1 review runs against `.plans/next-wave-issues.tsv` directly.
Suggested flow (matches `MASTER_PLAN.md` §12 CP-1):

1. Read this README end-to-end (~5 minutes).
2. Skim the TSV in a spreadsheet or via
   `column -s $'\t' -t .plans/next-wave-issues.tsv | less -S`
   (~10 minutes at 141 rows).
3. Read the challenger v2 report when it lands.
4. §8 verify list: accept, override, or send back for revision.
5. Confirm CP-1 v2 with a message of the form `CP-1: approved` (or
   `CP-1: revise — <reasons>`).
6. On approval, main runs `tools/gh-bootstrap-next-wave-issues.sh` (drafted
   separately, per MASTER §4.2) which:
   - Creates any missing milestones idempotently.
   - Reads `.plans/next-wave-bodies/<slug>.md` for each row and files the
     issue.
   - Skips rows whose title already exists as an OPEN issue in the target
     repo.
   - Writes `.plans/next-wave-issue-map.tsv` (repo, milestone, title, issue#,
     CREATED|SKIPPED).
   - Estimated ~1 workday scripted; ~10 API ops/min throttle.

Nothing else in `MASTER_PLAN.md` runs before CP-1 v2 approval fires.

---

*End of README v2. Companion files: `.plans/next-wave-issues.tsv` (this
manifest, 141 rows), `.plans/next-wave-bodies/*.md` (issue bodies, drafted
per-milestone next), `tools/gh-bootstrap-next-wave-issues.sh` (bootstrap
script, drafted next).*
