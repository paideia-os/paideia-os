# R64 Retrospective (PARTIAL): Volume-tools seeding + doc

**Date:** 2026-08-25
**Milestone:** R64.M1 (single-milestone round; PARTIAL close by this
doc)
**Issues:** 1 landed (#1907 volume-tools.md walkthrough) + 1 closure
(this doc, #1911); 1 deferred in paideia-os (#1905 bin_seeds ELF
seeding); 4 out of paideia-os scope (R64.M1-001..004, the
`libpdx-volume`/`mkfs.pdxfs`/`mount.pdxfs`/`umount.pdxfs` satellite
repos).
**HEAD at closure:** bumped by the commit that lands this doc.
**paideia-as pinned at:** unchanged (this round touches no kernel or
paideia-as-facing code).
**Release tag:** `r64-closed` (partial-close discipline; applied to the
paideia-os HEAD landing this doc only — see §Cross-Repo Tags below).

---

## Round Intent

R64 was scoped to close the loop on R53's volume-tooling design
(`design/tooling/volume-tooling-ux.md`): four satellite repos
(`libpdx-volume`, `mkfs.pdxfs`, `mount.pdxfs`, `umount.pdxfs`) each
producing a signed-release ELF, a paideia-os-side seed of those three
tool ELFs into the init-time `/bin` set (#1905), a user-facing
walkthrough doc (#1907), and a full-chain closure retro (#1911).

---

## R64 Landed (paideia-os scope)

- **#1907 R64.M1-006 — `doc/user-guide/volume-tools.md`** (new,
  ~200 lines). Full intended walkthrough: mkfs.pdxfs → mount.pdxfs →
  write files → umount.pdxfs → remount → readback, with command
  examples drawn from `design/tooling/volume-tooling-ux.md`'s frozen
  CLI surface. Carries an explicit §6 scope block stating the
  walkthrough is aspirational until #1905 and the upstream tool-repo
  chain close.
- **#1911 (this doc)** — partial closure retro + `r64-closed` tag on
  the paideia-os HEAD.

## R64 Deferred to Debt

- **#1905 R64.M1-005 — bin_seeds.pdx: seed mkfs.pdxfs/mount.pdxfs/
  umount.pdxfs ELFs.** Deferred. This issue's own dependency line names
  its blocker precisely: "mkfs.pdxfs R64.M1-002, mount.pdxfs R64.M1-003,
  umount.pdxfs R64.M1-004 must each produce a buildable ELF" — i.e. the
  three satellite repos must each close their own M2 (core
  implementation) milestone first. As of this closure, `libpdx-volume`'s
  `pdxb_sign_superblock` helper depends on paideia-as's `mldsa65_sign`
  intrinsic, and the broader mkfs-pdxb host-tools build path is gated
  on the open **paideia-as #1730** gap. Until that resolves, none of
  the three tool repos can close the milestone #1905 depends on.
- **R64.M1-001..004 (`libpdx-volume`, `mkfs.pdxfs`, `mount.pdxfs`,
  `umount.pdxfs`)** — these four issues live entirely in their
  respective satellite repos, not this monorepo. Per this wave's
  explicit discipline ("do not touch external repos"), no code in any
  of the four repos was inspected or modified from this session; their
  status is reported here only as inferred from the paideia-as #1730
  blocker their common signing-helper dependency shares.

## Cross-Repo Escalations to paideia-as (R64)

**One, pre-existing.** paideia-as #1730 (mkfs-pdxb host-tools build
gap) is not newly filed by this round — it is the blocker this
closure's deferral chain traces back to. No new escalation filed.

## Cross-Repo Tags

The originating issue (#1911) specifies cutting `r64-closed` "on all
four tool repos plus paideia-os." **This session tags paideia-os
only.** Tagging `libpdx-volume`, `mkfs.pdxfs`, `mount.pdxfs`, and
`umount.pdxfs` is out of scope for a paideia-os-only session per this
wave's "do not touch external repos" discipline, and — more
substantively — premature anyway, since none of those four repos has a
landed, buildable ELF yet (see above). Tagging them `r64-closed` now
would falsely imply a milestone-complete state. That step is left for
whichever session next works directly in those repos, once each has
something real to tag.

## Observable Proof

- `doc/user-guide/volume-tools.md` exists and accurately describes the
  R53 design surface (verified by cross-reference against
  `design/tooling/volume-tooling-ux.md` §3–§8 during authoring).
- No kernel or userland `.pdx` code changed this round — R64's
  paideia-os-side footprint is documentation only.
- `/bin/mkfs.pdxfs`, `/bin/mount.pdxfs`, `/bin/umount.pdxfs` do **not**
  appear in the tmpfs seed table (`src/kernel/boot/witness/bin_seeds.pdx`)
  as of this closure — consistent with #1905 being deferred, not
  silently half-landed.

## Debt Inventory at R64 Close

1. **#1905** — bin_seeds three-ELF seed. Blocked on the tool-repo
   chain below.
2. **R64.M1-001..004** — `libpdx-volume`/`mkfs.pdxfs`/`mount.pdxfs`/
   `umount.pdxfs` M2+ milestones. Out of paideia-os scope; blocked on
   paideia-as #1730.
3. **paideia-as #1730** — mkfs-pdxb host-tools build gap. The root
   blocker for the entire chain above. Tracked in paideia-as, not this
   repo.
4. **Tool-repo `r64-closed` tags** — deferred to whichever session next
   works directly in those four repos (see Cross-Repo Tags above).
5. Common with every prior round's carried debt: the tmpfs-seed
   extension for real `/bin/*` ELF payloads is the recurring
   prerequisite blocking composite smokes across R57–R64.

**Next Round:** R64 stays open at the tool-repo layer until paideia-as
#1730 resolves; #1905 becomes a mechanical follow-up (mirroring the
existing R57.M4-006 seed-table pattern) once it does. paideia-os-side
work resumes on R65 (persistent `/home/operator`), which is itself
gated on this same chain for its own M1-001 mount step — see
`design/round-retrospectives/r65-closure.md`.
