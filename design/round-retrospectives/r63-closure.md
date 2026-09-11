# R63 Retrospective: `line` -- ed-style scriptable line editor MVP

**Date:** 2026-09-11
**Milestone:** R63.M1 (single-milestone round; FULL close by this doc)
**Round scope:** New user-space satellite repo `paideia-os/line` -- an
`ed`-shaped scriptable line editor. Category C tier-1 per
`design/tooling/plan.md`; roadmap slot per
`design/roadmap/post-r60-daily-use-roadmap.md` §R63.
**Issues:** 4 closed on the `line` satellite (#3 buffer, #4 fileio, #5
REPL, #6 fingerprints) + 1 closed on the monorepo (paideia-os#1868
kernel-side embed) + 1 hotfix (line#12 buffer.pdx capabilities) + 1
closure (this doc, line#7); 3 open with landed code but unclosed
tickets (#1 bootstrap, #2 grammar, #8 v1.1-A real-body) -- see
"Ticket hygiene" below.
**HEAD at closure:** bumped by the monorepo commit landing this doc.
**paideia-as pinned at:** unchanged from R63 open.
**Release tag:** `r63-closed` applied to `paideia-os/line` HEAD (main
cuts the tag after this commit lands).

---

## Round Intent

R63 was scoped as the smallest daily-use unlock beyond R60 shell
polish: a scriptable line editor in the `ed(1)` tradition that any
downstream tool (scripts, patch flows, config edits) can drive without
a full-screen TUI. The tool was allowed to grow in a new satellite
repo (`paideia-os/line`) rather than the monorepo per the
Category C repo-split discipline; only the kernel-side seed hook
(embedding the built `line.elf` at `/bin/line` via the R61 tmpfs-seed
extension) lived in `paideia-os`.

---

## R63 Landed

- **line#3 (R63.M1-003)** -- `src/buffer.pdx`: fixed pool of 512 lines
  * 256 bytes; public API `buffer_insert_line` / `buffer_delete_line`
  / `buffer_replace_line` / `buffer_get_line_ptr` / `buffer_get_line_len`
  / `buffer_last_addr` / `buffer_cursor_get` / `buffer_cursor_set`.
  1-based addressing per POSIX ed §Addressing; cursor persists across
  ops; sentinel band `0xFFFFFFFFFFFFFF01..03` disjoint from fileio's
  `..11..13`.
- **line#4 (R63.M1-004)** -- `src/fileio.pdx`: `fileio_write_buffer`
  (`w <path>`, `O_CREAT|O_WRONLY|O_TRUNC` = `0x241`, mode `0644`) and
  `fileio_read_file` (`e <path>`, `O_RDONLY`) with 4 KiB streaming
  read + `'\n'`-split + residual carry. Progress guard against a line
  spanning a full chunk with no `'\n'`.
- **line#5 (R63.M1-005)** -- `src/main.pdx` interactive REPL: `:`
  prompt, per-byte `sys_read(0, ...)` line reader, address+command
  tokenizer, dispatch of `a i d c p w q Q . , $` and bare address.
  Fingerprint + `LineEditRecord@0.1` emit sites moved from the
  retired v1.1-A batch tail to the `q` handler; wire format unchanged.
  EOF-on-fd-0 with empty accumulator is an implicit `q`. Every
  buffer/fileio sentinel path emits a single `?\n` (matches ed's
  single-character error convention) and returns to the prompt --
  never `sys_exit` mid-session.
- **line#6 (R63.M1-006)** -- `line ok -- lines=<N>\n` fingerprint on
  the happy-path tail via three fd-1 sys_writes (prefix +
  `line_print_u64_dec` + newline); `LINE PARSE FAIL\n` rodata
  declared. Exit-status inventory frozen at
  `{0=OK, 2=usage, 3=READ FAIL, 4=WRITE FAIL, 5=PARSE FAIL}`.
- **paideia-os#1868 (R63.M1-007)** -- `src/kernel/bin_seeds.pdx`
  extension embedding `line.elf` at `/bin/line` via the R61 tmpfs-seed
  symbol-pair + `witness_bin_seeds` shape. Landed 2026-08-25.
- **line#7 (R63.M1-008)** -- this closure retro + `r63-closed` tag on
  the `line` satellite.

## R63 Ancillaries (out-of-M1 scope, landed during the round)

- **line#8 v1.1-A** -- real-body extraction retiring the M1-001 STUB;
  wired `sys_open`/`sys_read`/`sys_close` + `sys_open(O_CREAT|
  O_WRONLY|O_TRUNC)`/`sys_write`/`sys_close`. Landed at `3edfa6f`
  (ticket left OPEN inadvertently; see Ticket hygiene).
- **line#9 v1.1-B** -- `LineEditRecord@0.1` (56 B, schema tag
  `0x656E694C69644500`) via `sys_semantic_send` (SC+ ID 115). Closed.
- **line#10 v1.1-C** -- CHANGELOG + `manifest.pdxproj` bump 1.1.0-B →
  1.1.0 release closer. Closed.

## Cross-Repo Escalation to paideia-as (R63)

- **paideia-as#1413** -- `P0154 (missing capabilities field) reports
  error but exits 0`. Root cause of the line#12 hotfix: the initial
  `src/buffer.pdx` landing omitted the required `capabilities: {},`
  field on all 8 public function declarations, and `paideia-as build
  --emit elf64` reported `P0154` for each but exited 0, so
  `tools/build.sh` treated the tree as green. Discovered by the W41
  retrospective debugger sweep 2026-09-10; hotfixed at line#12
  (field-insertion patch). paideia-as#1413 remains open as an encoder
  diagnostic-severity → process-exit bug -- until it lands, every
  `.pdx` source in the org needs the softarch to eyeball `capabilities:`
  by hand. First cross-repo escalation from a `line`-side landing.

## What went well

- **Repo split cleanly separated the tool from the substrate.** The
  M1-001..006 arc lived entirely in the satellite; the paideia-os
  monorepo touched only `bin_seeds.pdx` at R63.M1-007. No monorepo
  churn for tool-internal changes.
- **Sentinel-band discipline.** buffer's `0x01..0x03` and fileio's
  `0x11..0x13` sub-bands mean the REPL can pattern-match the low byte
  back to the module of origin without cross-module coupling; new
  modules pick the next band by convention.
- **`LineEditRecord@0.1` shape landed early (v1.1-B) with an honest
  scope statement.** Field-additive future rounds (edit_count, files_*
  wire) do not require a schema bump.

## What went wrong

- **`buffer.pdx` shipped without `capabilities: {}` and the build
  reported green.** Silent-exit-0 on P0154 masked the parse failures
  for four days across three subsequent landings (#4, #5, #6)
  before the W41 sweep caught it. The hotfix is done (line#12); the
  encoder bug (paideia-as#1413) is still open and blocks a full
  paideia-as-side guarantee.
- **Ticket hygiene drift.** Tickets #1 (M1-001 bootstrap), #2
  (M1-002 grammar), and #8 (v1.1-A) are still OPEN on the tracker
  even though their code landed and downstream work built on it.
  M1-002 in particular is subsumed by the M1-005 REPL landing --
  every command in the grammar is now dispatched. These should be
  closed as part of the tag-cut on `line`.

## Follow-ups

- **line#1 / #2 / #8** -- close as part of the r63-closed tag cut
  (their code is landed; the tickets are stale). Not blocking the
  tag; treat as a housekeeping sweep.
- **line#11** -- `.gitignore` hygiene for `build-out/`, `*.o`,
  `*.bin`, `*.elf`; not R63 scope, carries into R64 debt.
- **paideia-as#1413** -- encoder exit-code fix. Every satellite
  softarch must eyeball `capabilities:` presence until this lands.

## Tag disposition

**`r63-closed` is justified now.** All M1-001..006 code paths are
landed and interactively exercised; paideia-os#1868 kernel-side
embed is closed; the line#12 hotfix restored buffer.pdx to a
parseable state. The three open tickets (#1/#2/#8) are ticket-
tracker artifacts, not scope debt -- their code is in the tree and
downstream landings built on it. Main cuts `r63-closed` on the
`line` satellite after this commit lands.
