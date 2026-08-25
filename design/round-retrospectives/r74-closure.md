# R74 Retrospective (PARTIAL): /etc configuration substrate

**Date:** 2026-08-25
**Milestone:** R74.M1 (single-milestone round; PARTIAL close by this
doc)
**Issues:** 3 landed (#1940 /etc layout freeze, #1943 doc, #1944 this
closure); 2 deferred (#1941 sysctl tool, #1942 init boot-time parse).
**HEAD at closure:** paideia-os 458daaa + this commit.
**Release tag:** `r74-closed` (partial-close discipline).

## R74 Landed

- **#1940 /etc layout freeze** — `design/user/etc-layout.md`. Five
  authoritative files: hostname, paideia.conf, motd, passwd. Shape +
  format constraints + rootfs-seed defaults. Frozen so future
  operators can parse older-HEAD volumes.
- **#1943 Operator getting-started doc** — `doc/user-guide/etc-
  configuration.md`. Sysctl workflow + sample paideia.conf +
  read/write/list/reset command surface. Cross-linked to R65
  persistent-home and rootfs_seed.pdx.
- **#1944** (this doc) — partial closure retro + `r74-closed` tag.

## R74 Deferred to libpdx-config satellite

- **#1941 sysctl tool** — depends on `paideia-os/libpdx-config`
  landing its `key = value` parser M1 issue. The tool itself is
  ~200 LOC of argv parsing + `sys_open`/`sys_read`/parse/`sys_write`,
  trivial once the parser exists. Deferred as `not planned` on the
  paideia-os monorepo issue; will re-open in libpdx-config repo.
- **#1942 Init boot-time parse** — depends on libpdx-config linkage
  into init.elf. Init today runs with compiled-in defaults per
  `doc/user-guide/etc-configuration.md` §Bootstrap sequence step 3.

## Cross-Repo Escalations

**None.** libpdx-config is a sibling repo, not a paideia-as
escalation.

## Observable Proof

Docs render cleanly. No kernel/user code changes at this round;
boot smoke unchanged from R72 partial (SHELL START + $ prompt +
ELEVATE BROKER OK).

## Debt Inventory

- libpdx-config: parser + sysctl tool implementation.
- paideia-os init.pdx: post-libpdx-config wiring to consume
  paideia.conf at boot (currently uses compiled-in defaults).
- No paideia-os monorepo code changes remaining for R74.

**Next round:** R78 (ACPICA/AML interpreter) or R81 (HDA audio) per
the post-R60 daily-use roadmap.
