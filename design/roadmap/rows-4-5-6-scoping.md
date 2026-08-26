# Rows 4–6 scoping: R64 volume tooling, R65 persistent home, R66 shell polish tier 1

**Date:** 2026-08-25
**HEAD at authoring:** paideia-os `44ff5eb` (per task briefing); `tools/paideia-as` submodule pinned at `037d826` (`paideia-as 0.22.0` + the movzx/movsx fix, see §0.2).
**Authors:** osarch + softarch combined pass.
**Source row spec:** `design/roadmap/post-r60-daily-use-roadmap.md` §R64/§R65/§R66 (authored 2026-08-25, HEAD `5778fd0` at that time — i.e. earlier the same day as this doc).
**Supersedes (partially):** `design/round-retrospectives/r64-closure.md`, `r65-closure.md`, `r66-closure.md` — those record what *v1* landed/deferred; this doc scopes *v2*, the wave that actually finishes the work.

This is **not** a from-scratch decomposition. Before writing a single new
issue, this pass audited every repo named in the task (`gh api
.../contents/src`, `gh issue list --state all`) and found that rows 4 and 6
already carry extensive, previously-filed issue sets — some fully open and
ready to implement, some closed-without-landing. §0 records that audit and
one load-bearing correction it surfaced. §1 is the executive summary. §2–§4
scope R64/R65/R66 against what is *actually* there, not what a prior
retrospective assumed was there. §5 is the combined cross-repo dependency
graph. §6 is the mechanical `gh` filing plan for the *net-new* issues this
doc actually introduces.

---

## §0. Corrigendum — read this before anything else

### 0.1 "paideia-as #1730" does not exist

Three prior documents in this monorepo — `r64-closure.md`,
`r65-closure.md`, and `design/user/persistent-home.md` §2.1/§6 — assert
that the volume-tooling chain is "blocked on paideia-as #1730 (mkfs-pdxb
host-tools build gap)". A closing comment on paideia-os issue #1916 (R65
mount step, closed 2026-08-25T20:06:25Z) repeats the same citation.

**`gh api repos/paideia-os/paideia-as/issues/1730` returns 404.** The
paideia-as repository's highest issue number as of this audit is **#1329**
(closed 2026-08-25T18:07:40Z). There is no issue #1730 in that repository,
open or closed, and no issue matching "host-tools build target" under any
search term (`host-tools`, `host target`, `linux elf`, `cross-compile`).

This is a fabricated/erroneous reference that has propagated across at
least four artifacts (three closure docs + one issue comment) without
anyone re-verifying it against the live tracker. Per this agent's own
reference-verification discipline, it is corrected here rather than
carried forward a fifth time. **Every future reference to this blocker
should point at §0.2/§0.3 below, not at "#1730".**

### 0.2 What the real, adjacent, now-*closed* blocker was

There is a real cross-repo chain that resembles the phantom citation
closely enough to explain how it got invented:

- **paideia-os #1861** (`R68.M1-001 paideia-as encoder gap: mkfs-pdxb
  round-trip fix`) — filed for **row 8 (R68, disk-path debt discharge)**,
  not row 4. Scope: "identify the exact instruction/encoding shape in
  paideia-as that breaks mkfs-pdxb round-trip witnesses... file the
  corresponding paideia-as issue, land the fix, bump the submodule."
  **CLOSED.**
- **paideia-as #1329** (`Encoder gap: movzx/movsx unreachable from .pdx
  source (mkfs-pdxb round-trip)`) — the escalation #1861 produced.
  Root cause: `Mnemonic::Movzx`/`Movsx` were fully encodable but missing
  from `MNEMONIC_TABLE` in `crates/paideia-as-elaborator/src/
  unsafe_walker.rs`, so no `.pdx` `unsafe` block could spell them. Fixed
  by adding both mnemonics + register-width recovery. **CLOSED
  2026-08-25T18:07:40Z.**
- The fix commit **is** the submodule's current pinned HEAD: `git -C
  tools/paideia-as log -1` shows `037d826 ... "Fix #1329: wire movzx/movsx
  into MNEMONIC_TABLE (mkfs-pdxb round-trip)"`, and
  `unsafe_walker.rs:338-339` now carries `("movzx", Mnemonic::Movzx)` /
  `("movsx", Mnemonic::Movsx)`. **The submodule bump this fix needed has
  already happened** — no action item remains here.

Critically, `src/tools/mkfs-pdxb/main.pdx` (the file `#1329`'s repro
compiles) is a **kernel-repo-internal** tool used to generate R54–R56
composite-smoke goldens (row 8's concern), not the `paideia-os/mkfs.pdxfs`
satellite repo this doc's row 4 scopes. These are two different `mkfs`
implementations. Conflating them is the second half of how the phantom
blocker got attached to row 4's tools: the *real*, now-closed encoder gap
lived on the row-8 tool; row 4's satellite tools were never actually
blocked by it, because they don't invoke `movzx`/`movsx` from `.pdx`
`unsafe` blocks at all — see §0.3 for what actually blocks them.

### 0.3 The real, still-open blocker for row 4

`libpdx-volume` issue #7 (`libpdx-volume.M3-001 pdxb_sign_superblock via
paideia-as mldsa65_sign intrinsic`) states plainly: "Write the ML-DSA-65
signature into superblock offset `[696, 4096)` via **paideia-as ≥ v0.33**
`mldsa65_sign` intrinsic." The installed submodule is **`paideia-as
0.22.0`**. A repo-wide search of `tools/paideia-as/crates/*` for
`mldsa65_sign` as a *compiler intrinsic* (the pattern used by the already-
shipped `cpuid_leaf` typed intrinsic, paideia-as #1283/#1298) finds
nothing — the only `mldsa*` hits are in `paideia-pq-sign`, a **host-side
Rust crate** paideia-as itself uses to dual-sign its own release
artifacts, not a callable-from-`.pdx` intrinsic. `gh issue list --search
mldsa65` against paideia-as returns zero results, open or closed: this
gap has never been filed.

This is the one genuine, currently-unresolved paideia-as prerequisite for
row 4's *device-target* signing path. It is inlined as a new issue spec in
§2.1 below (answering the task's "prefer (a): inline the exact
encoder/build-target-plumbing spec" instruction — the corrected version
of that instruction, since the gap it names does not exist under the name
it was given).

Note the scope of what this gap actually blocks: per
`design/tooling/volume-tooling-ux.md` §1.3, `mkfs.pdxfs`'s **file-path
target** (the dev workflow — `mkfs.pdxfs ./foo.img`) requires **no
signing at v0** and is entirely unblocked today. Only the **device-cap
target** (`cap:blkdev:...`, the production workflow `mount.pdxfs` needs
for anything under `/home`, `/system`, `/boot`) requires
`pdxb_sign_superblock`, and therefore requires this intrinsic. R64 v2's
implementation order (§2.2–§2.5) is sequenced to exploit this: the file-
target path across all four tools can be built, tested, and even used for
the R65 home mount (a file-backed image is a legitimate `KIND_VOLUME`,
just not one that satisfies the "mandatory signing" production posture) an
entire milestone ahead of the device-target path.

### 0.4 What is already filed — the actual state of each repo

| Repo | `src/` contents | Open issues | Closed issues | Milestone |
|---|---|---|---|---|
| `libpdx-volume` | `.gitkeep` only | 13 (M1–M5 + 1 `R64.M1-001` wrapper) | 0 | none named in listing |
| `mkfs.pdxfs` | `.gitkeep` only | 19 (M1–M5 + 1 `R64.M1-002` wrapper) | 0 | none named |
| `mount.pdxfs` | `.gitkeep` only | 17 (M1–M5 + 1 `R64.M1-003` wrapper) | 0 | none named |
| `umount.pdxfs` | `.gitkeep` only | 17 (M1–M5 + 1 `R64.M1-004` wrapper) | 0 | none named |
| `shell` (satellite) | 13 `.pdx` files, `v1.0.0` tagged | 10 (R66.M1-001..005 + R73.M1-002..006) | 16 (shell.M1-001..M5-002, the full v1.0.0 wave) | `R66 — shell polish tier 1` (#6), `R73` unnumbered here |
| `paideia-os` (R65 issues) | n/a | 0 of the 4 substantive R65 issues | **4 closed-as-deferred** (#1916, #1921, #1926, #1930) + 2 landed (#1918, #1935) + 1 retro (#1936) | n/a |

Three findings drive everything below:

1. **The four volume-tool repos have zero code and zero closed issues, but
   exhaustive M1–M5 issue breakdowns already exist (13–19 issues each,
   all open).** Re-filing a parallel "5–10 sub-issues per repo" plan per
   the task's literal ask would create duplicates that fight the existing,
   more detailed plan. §2 therefore does **not** re-decompose these tools;
   it audits the existing plan for correctness, fixes the one real
   blocker (§0.3), and adds only the small number of **sequencing/
   companion** issues actually missing (bin_seeds wiring, a real
   execution-tracking milestone, doc updates).
2. **R65's four substantive issues are `CLOSED`, not open** — closed
   *as deferred* on 2026-08-25T20:06:25Z with a comment citing the
   phantom #1730. Since a closed issue does not sit in a backlog waiting
   to be picked up, R65 v2 needs **fresh issues**, not reopened ones —
   filed against the corrected dependency chain (§0.2/§0.3, not #1730),
   and shrunk where a later landing (R86's real `sys_chdir`) already
   did part of the work (§3).
3. **R66's five issues (#17–21) are open, filed today, and target the
   `shell` satellite's own files** (`src/line_reader.pdx`,
   `src/shell.pdx`) — an architecturally distinct, cap-based,
   already-`v1.0.0`-released shell, not `src/user/shell.pdx` in this
   monorepo. §4 resolves the task's "design decision required" question
   using this discovery, and adds one real, previously-unnoticed kernel-
   side prerequisite (§4.3).

---

## §1. Executive summary of scope

| Row | Milestone(s) | Net-new issues this doc specifies | Reused (existing, unchanged) | Key blocker |
|---|---|---|---|---|
| R64 | 1 new milestone per repo (5 repos) + 1 paideia-as escalation milestone | 17 | 66 (13+19+17+17 across the 4 tool repos) | `mldsa65_sign` intrinsic (§0.3/§8, real, unfiled until this doc) |
| R65 | 1 milestone (paideia-os) | 7 | 0 (all 4 prior substantive issues closed-as-deferred, superseded) | R64 v2 device-target path (partially — file-target unblocks most of it now) |
| R66 | 1 milestone (shell) + 1 companion (paideia-os) | 3 | 5 (`#17`–`#21`, reused as-is) + 5 more (`R73.M1-002..006`, noted but out of this doc's scope) | KIND_TTY raw-mode/read gap (§4.3, real, newly identified) — no paideia-as-side gap (§8.4) |

**Totals this doc adds:** 27 net-new issues across 6 repos (`paideia-as`,
`libpdx-volume`, `mkfs.pdxfs`, `mount.pdxfs`, `umount.pdxfs`, `paideia-os`),
plus 1 new milestone in `shell` reusing its 5 pre-existing open issues
unmodified. **paideia-as specifically: 1 new milestone (`R64v2-XREPO`), 3
new issues (`R64v2.PAS-001..003`)** — see §8 for the full audit of every
paideia-as gap rows 4–6 could plausibly need, including the ones that
turned out **not** to exist.

---

## §2. Row 4 — R64 volume tooling completion (v2)

### 2.1 paideia-as — `mldsa65_sign` intrinsic (the one real blocker)

**New milestone:** `R64v2-XREPO — mldsa65_sign cross-repo escalation`
(a plain escalation milestone, not one of paideia-as's long-range `vX.YY`
roadmap milestones — see §8.3 for why forcing this into an existing
`vX.YY` slot would be wrong).

- **R64v2.PAS-001 — `mldsa65_sign` typed intrinsic for ML-DSA-65
  in-`.pdx` signing.**
  **Scope:** Expose `paideia-pq-sign::mldsa::sign_expanded_with_rnd` (host
  crate, already implemented at `crates/paideia-pq-sign/src/mldsa.rs:130`)
  as a compiler intrinsic callable from a `.pdx` `unsafe` block, following
  the typed-intrinsic pattern paideia-as #1283/#1298 established for
  `cpuid_leaf` (record-return marshalling: the intrinsic returns a
  `MlDsaSignature { bytes: [u8; N] }`-shaped record, not a raw register
  value, since a 3309-byte ML-DSA-65 signature cannot fit in RAX). Callers
  pass a 32-byte seed pointer + message pointer/length; the intrinsic
  handles `keygen_pk_from_seed` → `sign_expanded_with_rnd` internally so
  `.pdx` source never touches raw key material layout.
  **Files touched (paideia-as):**
  - `crates/paideia-as-elaborator/src/unsafe_walker.rs` (intrinsic
    recognition, mirroring the `cpuid_leaf` entry)
  - `crates/paideia-as-encoder/src/encode_instruction.rs` or a new
    `crates/paideia-as-encoder/src/intrinsics/mldsa.rs` (lowering to a
    call-out sequence, since ML-DSA-65 signing is not a single hardware
    instruction — likely lowered to a linked runtime-support call rather
    than inline-encoded, unlike `cpuid_leaf`)
  - `crates/paideia-pq-sign/src/mldsa.rs` (expose a `#[no_mangle] extern
    "C"` entry point the lowered call targets, if the call-out approach is
    used)
  - `CHANGELOG.md`, `Cargo.toml` workspace version bump to `0.23.0`
  **Fingerprint:** n/a (compiler-internal); downstream fingerprint is
  `libpdx-volume`'s own `pdxb_sign_superblock` test (#1329-style
  round-trip once wired).
  **Effort:** M (new intrinsic classes have historically run M–L per
  #1283's own history; scoping down from L because the host-side crypto
  primitive already exists — this is a marshalling/lowering problem, not
  a from-scratch crypto implementation).
  **Deps:** none. First issue of the R64 v2 wave; blocks
  `libpdx-volume.M3-001` (#7, already filed) and transitively
  `mkfs.pdxfs.M3-002` (#9, already filed).

- **R64v2.PAS-002 — version + CHANGELOG discipline for the above.**
  **Scope:** Per this project's paideia-as version discipline
  (workspace.version + git tag + CHANGELOG entry move together), tag
  `v0.23.0` on the commit landing R64v2.PAS-001 and update
  `find-paideia-as.sh`'s `MIN_VERSION` only if a *hard* dependency on the
  new intrinsic is added elsewhere in this same commit (it should not be
  — `MIN_VERSION` stays at whatever it already is; individual `.pdx`
  callers gate on the intrinsic's *presence*, not a blanket compiler-
  version floor).
  **Files touched:** `CHANGELOG.md`, git tag.
  **Fingerprint:** n/a.
  **Effort:** XS.
  **Deps:** R64v2.PAS-001.

- **R64v2.PAS-003 — Fix stale `v0.33` version-gate citation in
  `libpdx-volume` issue #7.**
  **Scope:** `libpdx-volume.M3-001` (#7) currently reads "via paideia-as
  ≥ v0.33 mldsa65_sign intrinsic." Per §8.3, paideia-as's actual
  `v0.33-crypto-kdf` milestone (5/5 issues closed) delivered Argon2id
  KDF + ChaCha20-Poly1305 AEAD + secure-random — **not** ML-DSA-65
  signing. That citation is stale/wrong the same way the "#1730" one
  was (§0.1) and should not be left to mislead a future reader. Correct
  `#7`'s body to point at `R64v2.PAS-001` / the `R64v2-XREPO` milestone
  instead of a version number.
  **Files touched:** none (issue-body edit in `libpdx-volume`, cross-repo
  from paideia-as's perspective — filed here since it's paideia-as's
  audit that surfaced the error, executed against the `libpdx-volume`
  repo).
  **Fingerprint:** n/a.
  **Effort:** XS.
  **Deps:** none.

### 2.2 libpdx-volume — execution-sequencing milestone

The existing 13 issues (`libpdx-volume.M1-001` through `.M5-001`, #1–#12,
plus wrapper `#13 R64.M1-001`) already cover: scaffold, mount-table row
parser, superblock parse/encode, `mount_table_snapshot`, `vol_kind_narrow`,
signing (blocked per §0.3/§2.1), inode-tail sig helpers, fuzz/sig-verify/
matrix tests, and dual-signed release. **These are correct and complete
as filed.** R64 v2 adds only the milestone wrapper and one contingency
issue:

**New milestone:** `R64 v2 — libpdx-volume execution`
(description: "Actually implement the 13 already-filed M1–M5 issues now
that the R64v2.PAS-001 signing-intrinsic blocker has a filed fix; track
completion of #1–#12 plus this milestone's own sequencing issue.")

- **R64v2.LPV-001 — Execution order note + non-signing-path milestone
  split.**
  **Scope:** Add a short note to each of `libpdx-volume.M2-*` issues
  (#3–#6, already filed) confirming they have **no dependency on
  R64v2.PAS-001** and can proceed immediately (parse/encode/snapshot/
  narrow all operate on already-defined byte layouts, no signing
  involved). Split `M3-001` (#7, signing) from `M3-002` (#8, inode-tail
  sig helpers, also signing-dependent) into an explicitly separate
  "signing-path" sub-track so the M2 track's 4 issues are not
  accidentally gated behind the intrinsic.
  **Files touched:** none (issue-metadata/comment only — this is a
  planning correction, not code).
  **Fingerprint:** n/a.
  **Effort:** XS.
  **Deps:** none.
- **R64v2.LPV-002 — Round-closure retro update once #1–#12 land.**
  **Scope:** Once all 12 pre-existing issues close, author
  `design/round-retrospectives/r64-closure-v2.md` in paideia-os (new file
  — the existing `r64-closure.md` stays as the honest record of v1's
  partial state; v2 gets its own retro rather than rewriting history) and
  cut `r64v2-closed` on this repo.
  **Files touched:** `design/round-retrospectives/r64-closure-v2.md`
  (paideia-os).
  **Fingerprint:** n/a.
  **Effort:** S.
  **Deps:** all of `libpdx-volume` M1–M5 (#1–#12).

### 2.3 mkfs.pdxfs — execution-sequencing milestone

19 issues already filed (`mkfs.pdxfs.M1-001` through `.M5-002`, #1–#18,
plus wrapper `#19 R64.M1-002`), covering: scaffold, argv surface,
`--dry-run`, target-taxonomy resolver, file-target format path, non-blank
refusal, device-cap path + `KIND_BLOCK_DEVICE` narrowing, signing (#9,
blocked per §0.3), semantic-pipe emission, audit journal, elevate request,
and the full M4 smoke matrix + M5 release. **Complete and correct as
filed.**

**New milestone:** `R64 v2 — mkfs.pdxfs execution`

- **R64v2.MKF-001 — File-target path is fully unblocked; sequence it
  first.**
  **Scope:** Confirm and document (issue comment + a line in
  `design/tooling/volume-tooling-ux.md` §3, cross-referenced) that
  `mkfs.pdxfs.M1-001..M2-004` (#1–#7, scaffold through non-blank refusal)
  and `.M4-001/.M4-002` (file-target smokes, #13–#14) have **zero
  dependency** on R64v2.PAS-001, and can produce a fully working
  `mkfs.pdxfs ./foo.img` today. This is the path R65's mount step can use
  as an interim, unsigned home-volume target (§3.1) while the device-
  target signing path (§2.1) lands separately.
  **Files touched:** none (planning/sequencing note).
  **Fingerprint:** n/a.
  **Effort:** XS.
  **Deps:** none.
- **R64v2.MKF-002 — Device-target smoke (`M4-003`, #15) explicitly
  gated on R64v2.PAS-001 + libpdx-volume `M3-001` (#7).**
  **Scope:** Add the explicit cross-repo dependency line to `#15`'s issue
  body (it currently reads "device-target smoke against QEMU virtio disk"
  with no blocker noted) so the existing M4 milestone doesn't appear
  falsely unblocked.
  **Files touched:** none (issue metadata).
  **Fingerprint:** n/a.
  **Effort:** XS.
  **Deps:** R64v2.PAS-001.
- **R64v2.MKF-003 — Round-closure retro update once #1–#18 land.**
  **Scope:** Same pattern as §2.2's `R64v2.LPV-002`.
  **Files touched:** `design/round-retrospectives/r64-closure-v2.md`
  (shared doc, this repo's section).
  **Fingerprint:** n/a.
  **Effort:** S.
  **Deps:** all of `mkfs.pdxfs` M1–M5.

### 2.4 mount.pdxfs — execution-sequencing milestone

17 issues already filed (#1–#16 + wrapper `#17`), covering: scaffold,
argv, `--dry-run`, volume-cap resolution via `vol_kind_narrow`, real
`sys_mount` + mount-table append, user-subtree path (no elevate),
mount-point-class table + elevate integration, audit INTENT/RESULT
records, semantic-pipe `PdxFsMountRecord@0.1`, failure-taxonomy encoding,
and the full M4/M5 smoke + release set. **Complete and correct as filed.**
This tool has **no dependency on §0.3's signing intrinsic at all** —
`sys_mount` operates on an already-formatted volume; it never signs
anything.

**New milestone:** `R64 v2 — mount.pdxfs execution`

- **R64v2.MNT-001 — Confirm zero dependency on R64v2.PAS-001; sequence
  fully in parallel with libpdx-volume/mkfs.pdxfs.**
  **Scope:** `mount.pdxfs`'s only real dependency is `libpdx-volume`'s
  `M1-002`/`M2-001..003` (mount-table parser, snapshot, narrow — #2, #4,
  #5, #6 — none signing-related) plus a formatted volume to mount
  (produced by either `mkfs.pdxfs`'s file- or device-target path).
  Document this in the issue tracker so `mount.pdxfs`'s M1–M3 work is not
  mistakenly sequenced behind the intrinsic fix.
  **Files touched:** none (planning note).
  **Fingerprint:** n/a.
  **Effort:** XS.
  **Deps:** none.
- **R64v2.MNT-002 — Round-closure retro update once #1–#16 land.**
  Same pattern as above.
  **Effort:** S. **Deps:** all of `mount.pdxfs` M1–M5.

### 2.5 umount.pdxfs — execution-sequencing milestone

17 issues already filed (#1–#16 + wrapper `#17`), covering: scaffold,
argv, `--dry-run`, mount-id resolution, handle-count query + `IN_USE`
refusal, non-force happy path (flush + CLEAN checkpoint + re-sign +
rewrite), `--lazy`/`--force` paths, `SIG_KEY_LOCKED` refusal, semantic-
pipe `PdxFsUnmountRecord@0.1`, and full M4/M5 smoke + release. **Complete
and correct as filed.** Note: `umount.pdxfs.M2-003` (#6, "superblock
resign+rewrite" on clean unmount) **does** touch `pdxb_sign_superblock`
and is therefore transitively gated on §0.3/§2.1 for the device-target
case — but not for the file-target case (an unsigned dev-workflow image
can be cleanly closed without re-signing, since it was never signed to
begin with).

**New milestone:** `R64 v2 — umount.pdxfs execution`

- **R64v2.UMT-001 — Flag `#6`'s conditional dependency on
  R64v2.PAS-001.**
  **Scope:** Add a note to `umount.pdxfs.M2-003` (#6) clarifying the
  re-sign step is a no-op / skipped for unsigned (file-target,
  dev-workflow) volumes and only exercises the real signing path once
  R64v2.PAS-001 lands — so `#6`'s *unsigned* happy path is not blocked
  today.
  **Files touched:** none (issue metadata).
  **Fingerprint:** n/a.
  **Effort:** XS.
  **Deps:** none.
- **R64v2.UMT-002 — Round-closure retro update once #1–#16 land.**
  Same pattern. **Effort:** S. **Deps:** all of `umount.pdxfs` M1–M5.

### 2.6 paideia-os — bin_seeds + doc + v2 closure

**New milestone:** `R64 v2 — paideia-os seed + doc completion`

- **R64v2.POS-001 — `bin_seeds.pdx`: seed `mkfs.pdxfs.elf`,
  `mount.pdxfs.elf`, `umount.pdxfs.elf` into tmpfs at `/bin/`.**
  This is the pre-existing, already-filed **#1905**, deferred at R64 v1
  close. Reused unmodified — its own blocker line ("each of the three
  tool repos must close their own M2 milestone first") already names the
  right condition; no re-filing needed, just re-open if closed, or leave
  open if still open (audit which — not confirmed in this pass since
  #1905 wasn't directly queried, but `r64-closure.md` records it as
  deferred/open at v1 close, not closed).
  **Files touched:** `src/kernel/boot/witness/bin_seeds.pdx`.
  **Fingerprint:** `bin seed ok -- file=/bin/mkfs.pdxfs bytes=<N>` (×3,
  per the R61 `bin_sh_seed` pattern).
  **Effort:** S.
  **Deps:** `mkfs.pdxfs`/`mount.pdxfs`/`umount.pdxfs` each reaching a
  buildable M2 (per #1905's own line — now concretely: their M2
  milestones, §2.3/§2.4/§2.5, none of which need R64v2.PAS-001).
- **R64v2.POS-002 — Update `doc/user-guide/volume-tools.md` §6 from
  "aspirational" to "real" once #1905 lands.**
  **Scope:** The existing doc (#1907, landed at v1) carries an explicit
  §6 scope block calling the walkthrough aspirational. Flip that section
  once the seed lands and the walkthrough is runnable end-to-end.
  **Files touched:** `doc/user-guide/volume-tools.md`.
  **Fingerprint:** n/a (doc-only).
  **Effort:** XS.
  **Deps:** R64v2.POS-001.
- **R64v2.POS-003 — Round v2 closure retro (paideia-os-side) +
  `r64v2-closed` tag across all 5 repos.**
  **Scope:** Author `design/round-retrospectives/r64-closure-v2.md`
  consolidating the 4 satellite-repo sub-retros (§2.2/§2.3/§2.4/§2.5's
  `LPV-002`/`MKF-003`/`MNT-002`/`UMT-002`) plus this repo's #1905/doc
  work. Tag `r64v2-closed` on all 5 repos **only once each has real,
  landed, buildable code** — per this wave's own discipline
  (§0.4's finding #1 is exactly the mistake to avoid repeating: v1 tagged
  `r64-closed` on paideia-os alone while the satellite repos had nothing).
  **Files touched:** `design/round-retrospectives/r64-closure-v2.md`.
  **Fingerprint:** n/a.
  **Effort:** S.
  **Deps:** R64v2.POS-001, R64v2.POS-002, and all four satellite repos'
  M1–M5 completion.

### 2.7 R64 cross-repo dependency graph

```
paideia-as: R64v2.PAS-001 (mldsa65_sign intrinsic)
    │
    ├─(gates)──► libpdx-volume #7 (M3-001 pdxb_sign_superblock)
    │                 │
    │                 └─(gates)──► mkfs.pdxfs #9 (M3-002 signing on device target)
    │                                     │
    │                                     └─(gates)──► mkfs.pdxfs #15 (M4-003 device-target smoke)
    │                                     └─(gates)──► umount.pdxfs #6's signed-reclose path
    │
    └─(does NOT gate)──► libpdx-volume #1–#6 (M1/M2, parse/encode/snapshot/narrow)
                              │
                              └─(gates)──► mkfs.pdxfs #1–#7,#13–14 (file-target path, M1/M2/M4-001/002)
                              └─(gates)──► mount.pdxfs #1–#16 (entire tool — no signing dependency at all)
                              └─(gates)──► umount.pdxfs #1–#16 minus the signed-reclose sub-case

mkfs.pdxfs file-target path (unblocked today)
    │
    └─(gates)──► paideia-os R64v2.POS-001 (bin_seeds — needs *a* buildable ELF,
                  file-target-only is sufficient for the seed step itself)
                     │
                     └─(gates)──► R65.M1-001-v2 (§3.1) — home mount can use a
                                  file-target image as an interim measure
```

**Reading this graph:** the only genuinely serial chain left is
`R64v2.PAS-001 → libpdx-volume#7 → mkfs.pdxfs#9 → mkfs.pdxfs#15`
(device-target signing). Every other box in all four satellite repos is
parallelizable starting now. This is the single most important
correction this doc makes to the prior wave's understanding: **R64 was
never blocked wall-to-wall on one paideia-as gap** — the four repos'
own already-filed issues have almost no signing-path dependency between
them, and three of the four tools (`libpdx-volume`, `mount.pdxfs`,
`umount.pdxfs`'s non-reclose path) are entirely unblocked today.

---

## §3. Row 5 — R65 persistent home mount (v2, paideia-os only)

Per §0.4 finding 2, the four substantive v1 issues (#1916 mount, #1921
shell cd, #1926 smoke, #1930 pre-push gate) are **closed**, not open —
closed-as-deferred with a comment citing the phantom #1730. This section
files fresh replacements, correctly chained, and shrunk where R86 already
did part of the work.

**New milestone:** `R65 v2 — persistent home mount live`

- **R65v2.M1-001 — `init.pdx`: probe + mount, targeting the file-target
  path first.**
  **Scope:** Per `design/user/persistent-home.md` §2, extend
  `src/user/init.pdx` after the existing `rootfs_seed_run` call: `sys_stat`
  a configured home-volume path, and — unlike v1's device-only framing —
  accept **either** a `/dev/nvme0` device-cap target **or** a file-backed
  image at a fixed path (e.g. `/var/pdxfs/home.img`), produced by
  `mkfs.pdxfs`'s already-unblocked file-target path (§2.3,
  `R64v2.MKF-001`). This lets R65 land and be smoke-tested well before
  R64's device-target signing chain (§2.7) closes, while still using the
  *same* `sys_mount` call the device path will use later — no throwaway
  code.
  **Files touched:** `src/user/init.pdx`.
  **Fingerprint:** `init home mount ok -- src=<path> mp=/home/operator
  backend=PDXFS_BLOCK` (new; distinct from `mount.pdxfs`'s own
  `mount ok --` fingerprint since init is a different caller).
  **Effort:** S.
  **Deps:** `mkfs.pdxfs` file-target path usable (§2.3), i.e. `mkfs.pdxfs`
  M1/M2 (#1–#7) landed; `mount.pdxfs` M1/M2 (#1–#6) landed for the actual
  `sys_mount` invocation pattern to mirror.
- **R65v2.M1-002 — Device-target upgrade path (tracked, not blocking).**
  **Scope:** Once R64's device-target signing chain (§2.7) closes, extend
  `R65v2.M1-001`'s probe to prefer a real `/dev/nvme0` device volume over
  the file-target fallback when both are present. This is explicitly a
  follow-up issue, not a v2-closing requirement — it exists so the
  file-target interim measure in `M1-001` has a named successor rather
  than becoming permanent debt.
  **Files touched:** `src/user/init.pdx`.
  **Fingerprint:** same as `M1-001`, `backend` field distinguishes source.
  **Effort:** S.
  **Deps:** R64v2.PAS-001 → libpdx-volume#7 → mkfs.pdxfs#9/#15 (§2.7's
  serial chain), R65v2.M1-001.
- **R65v2.M1-003 — Shell chdir-on-entry to `$HOME`, using the now-real
  `sys_chdir`.**
  **Scope:** R86 (#1959/#1960, already landed per this doc's setting)
  gave `src/user/dispatch.pdx` a real `cd_builtin` backed by `sys_chdir` +
  `sys_getcwd` against `TASK_OFF_CWD` — the exact prerequisite v1's
  `#1921` said it was waiting for. This issue is now purely mechanical:
  in `src/user/shell.pdx`'s `_start`, before the first prompt, read `HOME`
  from `envp` (populated by R65 v1's `#1918`, already landed) and invoke
  the same `sys_chdir` path `cd_builtin` uses.
  **Files touched:** `src/user/shell.pdx`.
  **Fingerprint:** `shell cwd init ok -- cwd=<path>` (the fingerprint v1's
  design doc already named at §4, never fired because `#1921` never
  landed real code).
  **Effort:** XS (per the design doc's own observation: "mechanically
  simple", and now genuinely unblocked rather than blocked-by-choice).
  **Deps:** R86 (`sys_chdir`, landed), R65 v1 `#1918` (envp `HOME`,
  landed). **No dependency on R65v2.M1-001** — chdir-ing to a path string
  works whether or not that path is actually a mount point; see next
  issue for why sequencing them together anyway.
- **R65v2.M1-004 — Boot smoke `boot_r65_persistent_home` (two-phase).**
  **Scope:** Cold boot → mount (`M1-001`'s file-target path) → shell
  chdir to `$HOME` (`M1-003`) → `touch /home/operator/hello` → clean
  unmount → reboot → remount → `stat /home/operator/hello` succeeds. This
  is the composite proof that `M1-001` and `M1-003` combined actually
  deliver persistence, not just two independently-working pieces.
  **Files touched:** `src/kernel/boot/witness/` (new witness file,
  naming per existing `pdxfs_first_mount.pdx`/`r55_write_e2e.pdx`
  convention — e.g. `r65_persistent_home_smoke.pdx`), `tests/`.
  **Fingerprint:** `boot r65 persist ok -- file=hello bytes=<N>
  cycles=2`.
  **Effort:** M.
  **Deps:** R65v2.M1-001, R65v2.M1-003, `umount.pdxfs` clean-unmount path
  (§2.5, unsigned case — no PAS-001 dependency for the file-target
  smoke).
- **R65v2.M1-005 — `PAIDEIA_R58_PERSIST=1`→ `PAIDEIA_R65_PERSIST=1`
  pre-push gate.**
  **Scope:** Wire the `boot_r65_persistent_home` smoke into
  `tools/run-smoke.sh` behind a `PAIDEIA_R65_PERSIST=1` env flag, per this
  project's standing local-only verification discipline (no CI/CD).
  **Files touched:** `tools/run-smoke.sh` (or its per-flag include,
  matching the existing `PAIDEIA_R55_DISK=1`/`PAIDEIA_R68_DISK=1`
  pattern).
  **Fingerprint:** n/a (gate, not a fingerprint itself).
  **Effort:** XS.
  **Deps:** R65v2.M1-004.
- **R65v2.M1-006 — Update `design/user/persistent-home.md` from
  "design-only" to "real", correcting the #1730 citations.**
  **Scope:** Rewrite §2, §4, and §6 of the existing design doc to reflect
  landed code, and remove the two "paideia-as #1730" citations at §2.1
  and §6, replacing them with the corrected chain from §0.2/§0.3 of this
  document.
  **Files touched:** `design/user/persistent-home.md`.
  **Fingerprint:** n/a (doc-only).
  **Effort:** XS.
  **Deps:** R65v2.M1-001 through M1-005 (documents their landed state).
- **R65v2.M1-007 — Round v2 closure retro + `r65v2-closed` tag.**
  **Scope:** `design/round-retrospectives/r65-closure-v2.md` (new — v1's
  `r65-closure.md` stays as the historical record), full landed/deferred
  accounting, explicit note that this closes out the `#1916/#1921/#1926/
  #1930` closed-as-deferred debt from v1.
  **Files touched:** `design/round-retrospectives/r65-closure-v2.md`.
  **Fingerprint:** n/a.
  **Effort:** S.
  **Deps:** all of the above.

### 3.1 R65 dependency graph

```
R65v2.M1-001 (init mount, file-target)
    ├─ needs: mkfs.pdxfs file-target path (§2.3, R64v2.MKF-001 track)
    ├─ needs: mount.pdxfs M1/M2 (§2.4, unblocked today)
    │
R65v2.M1-003 (shell chdir $HOME) ── independent, needs only R86 (landed) + #1918 (landed)
    │
    ├──┬─► R65v2.M1-004 (composite smoke) ─► R65v2.M1-005 (pre-push gate)
    │  │                                          │
R65v2.M1-001 ┘                                     ▼
                                          R65v2.M1-006 (doc) ─► R65v2.M1-007 (closure)

R65v2.M1-002 (device-target upgrade) — parked behind R64's full signing
    chain (§2.7); not on the v2 closing critical path.
```

The critical-path length for R65 v2 to *close* is now **4 issues deep**
(`M1-001`/`M1-003` in parallel → `M1-004` → `M1-005`/`M1-006` →
`M1-007`), all of which depend only on R64's already-unblocked file-target
track and R86 (already landed) — not on R64's signing chain at all. This
is a substantial de-risking versus v1's framing, which chained everything
through the (phantom) single blocker.

---

## §4. Row 6 — R66 shell polish tier 1 (v2)

### 4.1 Repo skeleton reality check

The task briefing frames `paideia-os/shell` as "the migration target" for
`src/user/shell.pdx`, implying an empty or early-stage satellite waiting
to receive a port. **That is not the current state.** `paideia-os/shell`
is at **`v1.0.0`**, tagged, with all 16 `shell.M1-001`..`M5-002` issues
**closed**, and 13 real `.pdx` source files:

`shell.pdx`, `line_reader.pdx`, `exec.pdx`, `session.pdx`,
`pipeline.pdx`, `pds.pdx`, `history.pdx`, `completion.pdx`,
`pipe_passthrough.pdx`, `command_record.pdx`, `broker_bind.pdx`,
`release_manifest.pdx`.

This is an **architecturally distinct shell** from `src/user/shell.pdx`:

| | `src/user/shell.pdx` (monorepo) | `paideia-os/shell` (satellite) |
|---|---|---|
| Size | 152 lines, 1 file | 13 files, ~230 KB source |
| Model | Byte-loop prompt/read/dispatch, direct `sys_execve` | Cap-based: `KIND_SHELL_SESSION` mint + per-child sub-cap narrowing at every exec |
| Piping | none | `pipeline_plan` — typed `KIND_IPC_ENDPOINT` caps per `\|` stage |
| History | none | CoW-journal encoder against `KIND_PDXFS_FILE`, wire-format frozen |
| Scripting | none | `.pds` script executor (`design/terminal/pds-format.md`) |
| Completion | none | Schema-registry-driven `CommandCompletion[]` semantic-pipe record |
| Audit | none | Audit-first invariant: child cannot emit before its `ShellCommandRecord` is durable (M4-002, tested) |
| Status | boots today, seeded at `/bin/sh`, used by `init.pdx`'s live fork/exec cycle | v1.0.0 released; M1–M3 substrate real, M2/M3's *runtime* wiring (KIND_TTY read, real pipe endpoints) still stubbed per `line_reader.pdx`'s own M1-SKELETON commentary |

The two are not "an old version and a migration target" — they are two
different products at different levels of the same idea, built to
different design docs (`design/kernel/r17-m3-*` vs `design/terminal/
semantic-shell.md` + `design/tooling/r49-r50-plan.md`).

### 4.2 Design decision: which becomes the source of truth?

**Decision: `paideia-os/shell` becomes the long-term source of truth.
`src/user/shell.pdx` is retained, not retired, as the minimal early-boot
shell until `paideia-os/shell`'s exec/session substrate is real enough to
take over that role — then it is deprecated to a rescue-shell fallback,
not deleted outright.**

Justification against the project's own pillars (multicore-first,
FP-disciplined, semantically-queryable terminal — `project_paideiaos_
vision` memory):

1. `paideia-os/shell`'s cap-narrowing-at-exec + audit-first invariants are
   the capability-security model the rest of the OS already commits to
   (`libpdx-elevate`, `libpdx-audit`, PDXB's own signed-inode-tail
   discipline). `src/user/shell.pdx` bypasses all of that — it is a
   bootstrap convenience, not a security-model peer.
2. `paideia-os/shell`'s `CommandCompletion[]` schema-registry design and
   its semantic-pipe framing for pipelines are exactly the
   "semantically-queryable terminal" pillar's shell-side half. `src/user/
   shell.pdx` has no schema concept at all.
3. **But** `paideia-os/shell`'s M2/M3 runtime substrate is still
   partially stubbed (`line_reader.pdx`'s `LR_STUB` return, `history.pdx`'s
   encoder-only landing) pending kernel-side primitives that, per this
   audit, are now mostly real: `KIND_TTY` exists (§4.3 identifies the one
   remaining gap in it), `KIND_PDXFS_FILE` write exists, `sys_execve`
   with real argv/envp exists (R62). The stub era this shell was designed
   against no longer fully applies — R66 v2 is partly a matter of wiring
   up what the kernel has since delivered.
4. Retiring `src/user/shell.pdx` **before** `paideia-os/shell`'s exec
   path is proven live under `init.pdx`'s actual fork/exec cycle would
   leave the monorepo unable to boot to an interactive prompt during the
   transition. It stays wired as `/bin/sh` until a `paideia-os/shell`-
   produced ELF is seeded and smoke-tested as a drop-in replacement — a
   follow-up round (provisionally R73+ or its own row), out of this
   document's scope, will do that cutover once `paideia-os/shell`'s own
   exec substrate (not part of R66 tier-1 polish) is real.

**This resolves the task's design-decision question as: neither a
straight "becomes source of truth, retire the other" nor a "cross-compile
back into paideia-os/build" — it is a staged handoff, gated on
substrate readiness the shell repo does not yet have, tracked as its own
future row rather than folded into R66's line-editing scope.**

### 4.3 Real, newly-identified kernel prerequisite: KIND_TTY has no read op

`src/kernel/core/cap/kind_tty.pdx` (921 lines) defines exactly six ops:
`TTY_OP_WRITE`, `TTY_OP_QUERY_ROWS`, `TTY_OP_QUERY_COLS`,
`TTY_OP_QUERY_ID`, `TTY_OP_QUERY_BYTES`, `TTY_OP_DEBUG_PRINT`. **There is
no `TTY_OP_READ` and no raw/cooked mode toggle** (no `ICANON`/`ECHO`-
equivalent). The monorepo's own `shell_read_line` sidesteps this entirely
by calling `sys_read(0, ...)` against the VFS fd path, not a `KIND_TTY`
cap invoke — but `paideia-os/shell`'s `line_reader.pdx` is designed
against `KIND_TTY` cap semantics (per its own M1 commentary: "reads one
keypress at a time from `KIND_TTY(read)`... echoes... to `KIND_TTY
(write)`"). R66.M1-001 (raw-mode tty input with ESC-sequence recognition,
already filed as open issue `#17` in the shell repo) **cannot fully land
against real input** without either (a) a kernel-side `TTY_OP_READ` +
raw-mode toggle, or (b) `paideia-os/shell` falling back to the VFS
`sys_read(0,...)` path like the monorepo shell does, abandoning the
cap-typed read.

This is a genuine gap this audit surfaced that no prior document names.
It needs one companion paideia-os issue:

**New milestone (paideia-os):** `R66 v2 — KIND_TTY raw-mode companion`

- **R66v2.POS-001 — `KIND_TTY`: add `TTY_OP_READ` + raw/cooked mode
  toggle.**
  **Scope:** Add a seventh op, `TTY_OP_READ` (ordinal 6), returning one
  buffered byte per invoke (or a short run, capped, mirroring `TTY_OP_
  WRITE`'s `R_TTY_WRITE` rights gate but with a new `R_TTY_READ` right),
  plus a mode bit (`TTY_OP_SET_RAW` / `TTY_OP_SET_COOKED`, ordinals 7/8)
  controlling whether the kernel's tty layer performs line-buffering/echo
  before bytes are visible to a reader — the byte-at-a-time,
  no-auto-echo behavior `line_reader.pdx`'s ESC-sequence recognizer
  needs.
  **Files touched:** `src/kernel/core/cap/kind_tty.pdx`.
  **Fingerprint:** `tty read ok -- bytes=<N> mode=<raw|cooked>`
  (`klog_s1_x1`-style, matching the file's existing fingerprint idiom at
  the `TTY_OP_WRITE`/query sites).
  **Effort:** M (new op + rights gate + mode-state field on the tty
  object + a boot/unit smoke).
  **Deps:** none — additive to an existing, landed cap kind.
- **R66v2.POS-002 — Boot smoke: `KIND_TTY` raw-mode round-trip.**
  **Scope:** A minimal witness proving `TTY_OP_SET_RAW` → `TTY_OP_READ`
  returns bytes without kernel-side echo/line-buffering, then
  `TTY_OP_SET_COOKED` restores prior behavior.
  **Files touched:** `src/kernel/boot/witness/` (new), `tests/`.
  **Fingerprint:** `boot tty raw ok -- bytes=<N>`.
  **Effort:** S.
  **Deps:** R66v2.POS-001.

### 4.4 Shell-repo milestone (reusing the existing 5 open issues)

**Milestone (already exists, reused as-is):** `R66 — shell polish tier 1`
(milestone #6 in `paideia-os/shell`), containing:

- `#17` `R66.M1-001` Raw-mode tty input path with ESC-sequence
  recognition — **now additionally depends on `R66v2.POS-001`** (§4.3);
  add that dependency line to the existing issue body.
- `#18` `R66.M1-002` Backspace erase on-screen.
- `#19` `R66.M1-003` History ring buffer + up/down recall.
- `#20` `R66.M1-004` Cursor-left/right in-place edit.
- `#21` `R66.M1-005` Design doc: `shell-line-editing.md`.

**No new issues needed here** — these five are correctly scoped, already
open, and only need the one dependency annotation onto `#17` this doc
identifies. What R66 v2 adds is the closure step v1 never got (§0.4
finding 3: the paideia-os-side closure placeholder `#1839` already closed
itself as a deferred-close, acknowledging no real work landed):

- **R66v2.SHL-001 — Round v2 closure retro (paideia-os side) once
  `#17`–`#21` all close.**
  **Scope:** `design/round-retrospectives/r66-closure-v2.md` in
  paideia-os (v1's `r66-closure.md`, a deferred-close placeholder, stays
  as-is), this time a **real** closure since it will report on actually-
  landed shell-repo code (verifiable via that repo's own tags/CHANGELOG,
  per v1's own stated discipline at `r66-closure.md` §"Why this is a
  deferred-close"). Tag `r66v2-closed` on `paideia-os/shell` once `#17`–
  `#21` close, and mirror the tag on paideia-os once this retro lands.
  **Files touched:** `design/round-retrospectives/r66-closure-v2.md`.
  **Fingerprint:** n/a.
  **Effort:** S.
  **Deps:** shell repo `#17`–`#21`, `R66v2.POS-001`/`002`.

(R73's tier-2 issues, `#22`–`#26`, already open in the same repo, are
noted here for completeness but are **out of this doc's scope** — row 6
is tier 1 only.)

---

## §5. Combined cross-repo dependency graph (rows 4–6)

```
paideia-as
  R64v2.PAS-001 (mldsa65_sign intrinsic)
      │
      ▼
libpdx-volume #7 (M3-001 signing) ──► mkfs.pdxfs #9 (M3-002 signing)
      │                                      │
      │                                      ▼
      │                              mkfs.pdxfs #15 (M4-003 device smoke)
      │                                      │
      ▼                                      ▼
  [device-target track — parked]     R65v2.M1-002 (device-target upgrade, parked)

libpdx-volume #1-6 (M1/M2, unblocked)
      │
      ▼
mkfs.pdxfs #1-7,#13-14 (file-target, unblocked) ──┐
      │                                            │
      ▼                                            ▼
mount.pdxfs #1-16 (unblocked, no signing dep) ──► R65v2.M1-001 (init mount, file-target)
      │                                                  │
      ▼                                                  │
umount.pdxfs #1-16 minus signed-reclose (unblocked) ──┐  │
                                                        ▼  ▼
                                              R65v2.M1-004 (composite smoke)
                                                        │
                                                        ▼
                                         R65v2.M1-005/006/007 (gate, doc, closure)

R86 (sys_chdir, ALREADY LANDED) ──► R65v2.M1-003 (shell chdir $HOME) ──► R65v2.M1-004 (joins above)

paideia-os KIND_TTY (existing, write+query only)
      │
      ▼
R66v2.POS-001 (TTY_OP_READ + raw mode) ──► R66v2.POS-002 (smoke)
      │
      ▼
shell#17 (R66.M1-001, raw-mode input) ──► #18 ──► #19 ──► #20 ──► #21
      │                                                            │
      └────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
                          R66v2.SHL-001 (v2 closure)
```

**Critical path across all three rows:** `R64v2.PAS-001` gates only the
device-target half of R64/R65 — it does **not** sit on the path to
closing either R64 v2 (file-target track alone can close 3 of 4 satellite
repos plus paideia-os's seed/doc issues) or R65 v2 (file-target mount is
sufficient for the composite smoke). R66 v2's critical path is entirely
independent of R64/R65, gated only on the newly-identified
`R66v2.POS-001` (KIND_TTY raw mode) and the five already-open shell-repo
issues.

---

## §6. Mechanical filing plan

Net-new issues only (existing issues referenced above are **not**
re-filed). Milestones are created first, then issues assigned to them.

```bash
# --- paideia-as ---
gh api repos/paideia-os/paideia-as/milestones -f title="R64v2-XREPO — mldsa65_sign cross-repo escalation" \
  -f description="Cross-repo escalation from paideia-os row 4 (R64 v2). See design/roadmap/rows-4-5-6-scoping.md §2.1 + §8 in paideia-os."
gh issue create --repo paideia-os/paideia-as --milestone "R64v2-XREPO — mldsa65_sign cross-repo escalation" \
  --title "R64v2.PAS-001 mldsa65_sign typed intrinsic for ML-DSA-65 in-.pdx signing" \
  --body "See design/roadmap/rows-4-5-6-scoping.md §2.1, §8.2."
gh issue create --repo paideia-os/paideia-as --milestone "R64v2-XREPO — mldsa65_sign cross-repo escalation" \
  --title "R64v2.PAS-002 Version/CHANGELOG discipline for mldsa65_sign intrinsic" \
  --body "See design/roadmap/rows-4-5-6-scoping.md §2.1, R64v2.PAS-002."
gh issue create --repo paideia-os/paideia-as --milestone "R64v2-XREPO — mldsa65_sign cross-repo escalation" \
  --title "R64v2.PAS-003 Fix stale v0.33 version-gate citation in libpdx-volume#7" \
  --body "See design/roadmap/rows-4-5-6-scoping.md §2.1, §8.3."

# --- libpdx-volume ---
gh api repos/paideia-os/libpdx-volume/milestones -f title="R64 v2 — libpdx-volume execution" \
  -f description="See design/roadmap/rows-4-5-6-scoping.md §2.2 in paideia-os."
gh issue create --repo paideia-os/libpdx-volume --milestone "R64 v2 — libpdx-volume execution" \
  --title "R64v2.LPV-001 Execution order note + non-signing-path milestone split" \
  --body "See design/roadmap/rows-4-5-6-scoping.md §2.2."
gh issue create --repo paideia-os/libpdx-volume --milestone "R64 v2 — libpdx-volume execution" \
  --title "R64v2.LPV-002 Round-closure retro update once #1-12 land" \
  --body "See design/roadmap/rows-4-5-6-scoping.md §2.2."

# --- mkfs.pdxfs / mount.pdxfs / umount.pdxfs: same pattern, milestones
#     "R64 v2 — mkfs.pdxfs execution" / "... mount.pdxfs ..." / "... umount.pdxfs ...",
#     issues R64v2.MKF-001..003 / R64v2.MNT-001..002 / R64v2.UMT-001..002 per §2.3/2.4/2.5.

# --- paideia-os (R64 seed/doc + R65 + R66 companion) ---
gh api repos/paideia-os/paideia-os/milestones -f title="R64 v2 — paideia-os seed + doc completion" ...
gh issue create --repo paideia-os/paideia-os --milestone "R64 v2 — paideia-os seed + doc completion" \
  --title "R64v2.POS-001 bin_seeds: seed mkfs/mount/umount.pdxfs ELFs (reopens/continues #1905)" ...
# ... R64v2.POS-002, R64v2.POS-003 similarly.

gh api repos/paideia-os/paideia-os/milestones -f title="R65 v2 — persistent home mount live" ...
# R65v2.M1-001 .. M1-007 per §3, each --milestone "R65 v2 — persistent home mount live"

gh api repos/paideia-os/paideia-os/milestones -f title="R66 v2 — KIND_TTY raw-mode companion" ...
# R66v2.POS-001, R66v2.POS-002 per §4.3

# --- shell (satellite): reuse existing milestone #6 "R66 — shell polish tier 1"; only
#     add the dependency note to #17, then file the closure issue once #17-21 land:
gh issue create --repo paideia-os/shell --milestone "R66 — shell polish tier 1" \
  --title "R66v2.SHL-001 Round v2 closure retro once #17-21 land" \
  --body "See design/roadmap/rows-4-5-6-scoping.md §4.4."
```

---

## §8. paideia-as issues for rows 4–6 — full audit, live-verified

An amendment to this scoping directive asked for an exhaustive
enumeration of every paideia-as issue rows 4–6 need, naming an expected
"#1730 (already open) — mkfs-pdxb host-tools build target" as the
starting point and a "best guess" milestone name `M07`. Per this project's
standing reference-verification discipline, every one of those claims was
re-checked live against the tracker before being written into this
section — twice for #1730, since the amendment asserted it as already-open
after this doc's own §0.1 had already found it 404ing. **The second check
returned the same 404.** What follows is the full, evidence-backed audit.

### 8.1 "#1730 (already open)" — re-verified, still does not exist

```
$ gh api repos/paideia-os/paideia-as/issues/1730
{"message":"Not Found", ...} — HTTP 404
```

Re-run at the amendment's request; result unchanged from §0.1. paideia-as's
highest issue number remains **#1329**. There is no open issue numbered
1730 in this repository. This is stated plainly rather than hedged,
because inlining a "full spec" for an issue confirmed not to exist would
be exactly the kind of fabrication this agent's own operating discipline
forbids — a corrected, evidence-backed alternative is given instead
(§8.2–§8.4).

### 8.2 The "host-tools build target" premise does not hold for row 4's tools

The amendment's expected gap describes a need to compile `.pdx` into a
Linux-host-executable ELF (`--host-target=x86_64-linux-elf` or a `build
--host` sub-command, linking against a `libpdx-host` syscall shim). Checked
directly against the live compiler and the satellite repos' own filed
issues:

- **`paideia-as build --help`** lists exactly four output selectors:
  `--emit {placeholder,elf64,pax,pe-coff}` and `--target
  {uefi-x86_64,elf-kernel-x86_64,elf-user-x86_64,pax-x86_64}`. None of
  these is a Linux-host target with a syscall-shim runtime. This confirms
  no such target exists today — the amendment's premise that one is
  needed is worth checking against what the tools actually are, below.
- **All three of `mkfs.pdxfs`/`mount.pdxfs`/`umount.pdxfs`'s own 53
  already-filed issues** (§0.4) describe a paideia-os ring-3 userland
  tool: `KIND_USER`, `KIND_PDXFS_FILE`, `KIND_BLOCK_DEVICE`,
  `KIND_ELEVATE_CHANNEL`, semantic-pipe records, `libpdx-audit` journal
  entries. Nowhere in any of the 53 issue bodies is there a mention of a
  host build, cross-compilation, or a Linux target. Per `design/tooling/
  volume-tooling-ux.md` §1.3, `mkfs.pdxfs`'s "file-target" workflow means
  a `KIND_PDXFS_FILE`-backed image path *on a running paideia-os
  instance*, not a Linux path compiled on a developer's laptop. **These
  three tools compile with the existing `--target elf-user-x86_64` —
  the same target every other userland tool (`ls`, `cat`, `ps`) already
  uses.** No new paideia-as target is required for them.
- **The one tool in this codebase that genuinely does need a
  host-executable build** is `src/tools/mkfs-pdxb/main.pdx` — a
  kernel-repo-internal helper (not the `mkfs.pdxfs` satellite) used to
  generate R54–R56 witness/golden fixtures, per row 8 (R68), not row 4.
  Its repro command in paideia-as #1329 was `paideia-as build --emit
  elf64 src/tools/mkfs-pdxb/main.pdx -o /tmp/main.o` — i.e. it already
  uses the existing raw `--emit elf64` selector (no special host target
  needed at the paideia-as CLI level at all) and links the result with a
  host toolchain via `tools/mkfs-pdxb.sh` (paideia-os #1861's own "Files
  touched" list). **This mechanism already exists, already works, and
  its one real defect (`movzx`/`movsx` unreachable, #1329) is already
  fixed and pinned** (§0.2). There is no open host-build gap here either.
- On the amendment's specific worry about capability/effect discipline
  being bypassed on host builds: since no host-Linux target exists, this
  does not arise for row 4. It *would* be a legitimate concern if a future
  round ever adds one (e.g. to let `mkfs-pdxb`-style helpers narrow
  their I/O the same way in-OS tools do) — flagged here as a design note
  for whoever eventually proposes such a target, not as a row 4 action
  item.

**Conclusion:** the "host-tools build target" gap does not exist for any
tool in rows 4–6, under any of the framings tried. §8.5 files nothing
against it, on the principle that a milestone should not be manufactured
to hold work nobody needs yet.

### 8.3 Encoder/instruction gaps — checked, none found beyond signing

Searched paideia-as's issue tracker and existing intrinsic surface for
every "common candidate" the amendment named:

- **Checksums:** `pa-r15-008: checksum-fold intrinsic` (#963) — closed,
  landed. The PDXB allocator bitmap / WAL checksum needs this class of
  op; already available.
- **Bitmap ops:** `pa-r16-008: bitmap-scan intrinsic` (#974) — closed,
  landed. Directly serves `mkfs.pdxfs`'s free-space bitmap
  initialization and `libpdx-volume`'s superblock parsing.
- **Endian/64-bit scalar ops:** `v0.15 NET-PRIMITIVES — bit ops,
  checksums, endian scalars` milestone — closed. `pa-r16-007-
  bytesops-typed-accessors` (#1063) — closed, gives typed field
  getters/setters at arbitrary byte widths, which is what a superblock/
  WAL-header codec needs for cross-field-width packing.
- **64-bit divide specifically:** no dedicated issue found under that
  term, but none of the three tools' 53 issues describe a division-heavy
  operation (mkfs's bitmap math is shift/mask-based per its own #4–#7;
  mount/umount do table lookups, not arithmetic division) — no evidence
  a gap exists here, and no issue is filed speculatively against it.
- **The signing intrinsic (§0.3/§2.1) is the only real, confirmed
  encoder-adjacent gap** — everything else these tools need is either
  already-landed intrinsics (above) or ordinary control-flow/data-move
  instructions the encoder has supported since well before Phase 6.

Since the kernel's own `src/kernel/core/fs/pdxfs/*.pdx` modules (which use
the *same* superblock/WAL/bitmap codec logic `libpdx-volume` mirrors into
userland) already compile and are part of HEAD, this is not merely
inference — the encoder surface these operations need has demonstrably
been exercised successfully already.

### 8.4 Shell raw-mode: kernel gap, not a paideia-as gap

The amendment asked whether `paideia-os/shell`'s line-editing needs "any
new syscall stub in paideia-as's libc-lite (raw-mode ioctl equivalent,
termios shim, cursor-position query)." Checked:

- PaideiaOS does not have a POSIX termios/ioctl layer at all — device
  control goes through the capability-invoke pattern (`cap_invoke`),
  confirmed as an **already-used, already-compiling** primitive across
  multiple kernel `.pdx` modules (`superblock_read.pdx`, `mkfs.pdx`,
  `cow_read.pdx`, `superblock_write.pdx`, `block_cache_prefetch.pdx`).
  There is no new *language-level* primitive to add in paideia-as for
  this — a `.pdx` module can already invoke an arbitrary op number against
  an arbitrary cap kind.
- What's actually missing is **kernel-side**: `src/kernel/core/cap/
  kind_tty.pdx` simply never grew a `TTY_OP_READ` or a raw/cooked mode
  bit (§4.3). This is a `paideia-os` issue (`R66v2.POS-001`, already
  specified in §4.3), not a paideia-as one.

**No paideia-as issue is filed for shell raw-mode input.** Filing one
would misattribute a kernel-capability gap to the compiler.

### 8.5 Net paideia-as filing tally

| # | Issue | Milestone | Effort |
|---|---|---|---|
| 1 | `R64v2.PAS-001` — `mldsa65_sign` typed intrinsic | `R64v2-XREPO` | M |
| 2 | `R64v2.PAS-002` — version/CHANGELOG discipline for the above | `R64v2-XREPO` | XS |
| 3 | `R64v2.PAS-003` — fix stale `v0.33` citation in `libpdx-volume#7` | `R64v2-XREPO` | XS |

**1 new milestone, 3 new issues.** No milestone or issue is filed for
"#1730" (does not exist), a host-tools build target (not needed by any
row-4 tool), additional encoder/instruction gaps (checked, none found),
or shell raw-mode syscall stubs (kernel-side gap, tracked in §4.3 instead).

---

## §9. Verification log (what was checked before writing this doc)

- `gh api repos/paideia-os/{libpdx-volume,mkfs.pdxfs,mount.pdxfs,
  umount.pdxfs,shell}/contents/src` — confirmed 4 of 5 satellites are
  `.gitkeep`-only, `shell` has 13 real files + `v1.0.0` tag.
- `gh issue list --repo paideia-os/{each of the 5} --state all` — full
  issue inventories, confirmed open/closed counts in §0.4's table.
- `gh api repos/paideia-os/paideia-as/issues/1730` — **404**, confirming
  the phantom reference.
- `gh issue view 1329/1861 --repo paideia-os/{paideia-as,paideia-os}` —
  confirmed the real, closed, adjacent chain (§0.2).
- `git -C tools/paideia-as log -1` + `grep movzx unsafe_walker.rs` —
  confirmed the submodule pin already carries the #1329 fix.
- `grep mldsa65 tools/paideia-as/crates/**` + `gh issue list --search
  mldsa65` (both repos) — confirmed the real, unfiled §0.3 gap.
- `gh issue view 1916/1921/1926/1930 --repo paideia-os/paideia-os` —
  confirmed all four are `CLOSED` (not open), with #1916's closing
  comment repeating the phantom #1730 citation.
- `grep TASK_OFF_CWD src/user/dispatch.pdx` + `grep cd_builtin` —
  confirmed R86's real `sys_chdir`-backed `cd_builtin`/`pwd_builtin`
  already landed, shrinking R65v2.M1-003 to a mechanical wire-up.
- `grep -n "TTY_OP" src/kernel/core/cap/kind_tty.pdx` — confirmed the
  six existing ops and the absence of a read op, surfacing §4.3.
- Read `design/tooling/volume-tooling-ux.md` §1–§2 and `design/user/
  persistent-home.md` in full — confirmed the file-target vs
  device-target distinction that unblocks most of R64/R65 today.
- Re-ran `gh api repos/paideia-os/paideia-as/issues/1730` a second time
  after the coordinator's amendment asserted it as "already open" —
  still **404** (§8.1).
- `gh api repos/paideia-os/paideia-as/milestones?state=all` (paginated,
  120 milestones) + `paideia-as build --help` — confirmed no `M07` (or
  any `M0x`) naming convention exists (all are `mN-*`/`phaseN-*`/`vX.YY-*`),
  and confirmed the compiler's actual `--target` list has no Linux-host
  entry (§8.2/§8.3).
- `gh api repos/paideia-os/paideia-as/milestones/120` (`v0.33-crypto-kdf`)
  + its 5 issues — confirmed this milestone shipped Argon2id/ChaCha20/
  secure-random, **not** ML-DSA-65 signing, exposing `libpdx-volume#7`'s
  "≥ v0.33" citation as stale (§2.1's new `PAS-003`, §8.3).
- `gh issue list --search checksum-fold|bitmap-scan|endian|termios|
  libpdx-host|host-target parity|x86_64-linux-elf|64-bit divide` against
  paideia-as — confirmed which candidate encoder gaps are already closed
  and which return zero results (§8.3/§8.4).
- `grep -rn cap_invoke src/kernel/core/fs/pdxfs/*.pdx` — confirmed the
  generic cap-invoke primitive paideia-as already supports, ruling out a
  new language-level stub for shell's raw-mode read (§8.4).
