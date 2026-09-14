# R80 Retrospective: `ping` -- floor-scope ICMP echo tool MVP

**Date:** 2026-09-13
**Milestone:** R80.M1 (single-milestone round; FULL close by this doc)
**Round scope:** New user-space satellite repo `paideia-os/ping` -- a
minimal `ping <host>` command distinct from the full-featured
`paideia-os/pdxping` (design/networking/r100-user-tools-plan.md, R100
wave). A companion `R80.M1-006` closure issue was filed identically
on `paideia-os/fetch` (same round, sibling satellite); this doc closes
only the `ping` side.
**Issues:** 3 closed on the `ping` satellite (#1 bootstrap, #2 DNS
resolve + ICMP echo + RTT loop, #3 this closure).
**HEAD at closure:** `ping` main branch, commit landing this
document's companion STATUS.md update.
**paideia-as pinned at:** unchanged from R80 open.
**Release tags:** `v0.5.0` (M1-002 landing) and `r80-closed` (this
closure) both applied to `paideia-os/ping` HEAD.

---

## Wave-label note

`ping`'s own tracker files every issue under an `R80.M1-*` prefix,
while the repo's `STATUS.md` header and every design cross-reference
name the design-doc round as **R100**
(`design/networking/r100-user-tools-plan.md`). Both are correct and
name different things: **R100** is the design round `ping` and its
siblings (`pdxping`, `libpdx-net`, `fetch`, ...) were scoped under in
this monorepo's design tree; **R80** is the dispatch-wave label this
repo's issue tracker was seeded under. This retrospective preserves
that distinction rather than silently reconciling the two numbers --
a future reader diffing `ping`'s issue history against
`r100-user-tools-plan.md` should not mistake the mismatch for a
filing error.

## Round Intent

R80.M1 scoped the smallest useful ICMP-shaped command a shell tree
can offer before the full `pdxping` client (sequence numbers, real
RTT timing, packet-loss statistics, CLI flags) lands under its own
R100 milestones. `ping` exists to give scripts and interactive
sessions a tiny, dependency-free `ping <host>` verb; it was
deliberately allowed to ship two honest WEAK stubs rather than block
on either a real DNS resolver or a real per-task ICMP capability
grant, neither of which is in scope for a floor-level tool.

## R80 Landed

- **ping#1 (R80.M1-001)** -- repo bootstrap: `README.md`, `LICENSE`
  (MIT), `CHANGELOG.md`, `caps.decl` (`KIND_USER` + `KIND_TTY`, both
  mandatory -- deliberately no network-capability kind, since neither
  network-shaped operation makes a real syscall at this milestone),
  `tools/build.sh` + `link.ld` (mirrors `tools/user/pdxsock`'s
  satellite-linking template, `paideia-as >= 0.36.0`),
  `manifest.pdxsig` (source-form dual-sign manifest, every
  hash/signature slot a documented `PENDING` placeholder).
- **ping#2 (R80.M1-002)** -- `ping <host>`: DNS-resolve + ICMP-echo +
  RTT loop. `src/main.pdx` (module `Main`, single `_start` entry
  point): argc gated to exactly 2 (host argument required but its
  bytes never read at this floor scope), then a fixed 4-iteration
  loop writing the literal line `reply from 8.8.8.8 rtt=1ms\n` to fd 1
  each time, then `sys_exit(0)`. Usage refusal (argc != 2) writes a
  diagnostic to fd 2 and exits 2. Tagged `v0.5.0`.
- **ping#3 (R80.M1-006)** -- this closure: STATUS.md round-closure
  section, this retrospective, and the `r80-closed` tag.

## Honest-scope statement (carried from STATUS.md / README.md)

Both of `ping`'s network-shaped operations are honest WEAK stubs, for
two structurally different reasons:

1. **DNS resolve is a library-linkage gap.** `libpdx-net.net_resolve`
   is not yet linkable from a satellite repo, so `ping` always
   reports the fixed answer `8.8.8.8` regardless of the host argument.
2. **ICMP echo is a structural gate, not a missing library.** The
   kernel's `sys_icmp_echo` (SC+ ID 103) admits exactly two callers at
   this wave (boot context and PID 1) via
   `cap_check_r_net_privileged_protocol`; any ordinary ring-3 process
   gets `-EPERM` on every real call, unconditionally. Calling the
   syscall and discarding the `-EPERM` would look like real I/O
   happened when it did not -- strictly worse than the honest fixed
   `rtt=1ms` floor answer.

Neither stub is expected to become real inside `ping` itself: a real
resolver lands with `libpdx-net`'s own milestones, and a real
per-task ICMP grant is a kernel-side capability question entirely
outside this tool's scope. `paideia-os/pdxping` is where the full,
non-stubbed feature set belongs.

## What went well

- **Two-issue floor scope stayed honest under time pressure.** Rather
  than fabricate a resolver or silently swallow `-EPERM` from a real
  `sys_icmp_echo` call, both stubs are documented in three places
  (`README.md`, `STATUS.md`, `src/main.pdx`'s own header) with the
  *reason* each is a stub, not just the fact. No fingerprint or exit
  code claims capability the tool does not have.
- **Clean tracker hygiene.** Unlike `paideia-os/line`'s R63 closure
  (`design/round-retrospectives/r63-closure.md`), which had to flag
  three stale-but-landed OPEN tickets at tag-cut time, every `ping`
  M1 issue (#1, #2, #3) closes cleanly against code that actually
  landed under that issue number -- no ticket-hygiene sweep was
  needed here.
- **caps.decl's negative-space documentation.** The file explicitly
  states what capability kind is *not* declared and why (no network
  kind, because neither stub makes a real network syscall) rather
  than leaving the omission for a reviewer to puzzle out.

## What went wrong

- **Wave-label mismatch (R80 vs. R100) went unremarked until this
  closure.** `STATUS.md`'s header named R100 from the start, but
  every issue title used R80 without cross-referencing the other
  number anywhere in the repo. Not a functional defect -- both
  numbers were independently correct -- but a reader relying on issue
  titles alone would not discover the R100 design doc without this
  retrospective's note. Recorded in `STATUS.md`'s new "Wave-label
  note" section so it does not recur silently at the next milestone.

## Follow-ups

- **Real DNS resolution** lands with `libpdx-net`'s own milestones,
  once that library is linkable from satellite repos. Tracked in
  `libpdx-net`'s own issue tracker, not `ping`'s.
- **Real per-task ICMP capability grant** is a kernel-side capability
  design question (extending `cap_check_r_net_privileged_protocol`
  past boot-context/PID-1) entirely outside `ping`'s scope. No issue
  filed against `ping` for this; any future work belongs to
  `paideia-os/pdxping` or a kernel-side capability round.
- **Wave-label reconciliation.** If a future dispatch wave re-seeds
  this tracker, consider naming issues with the design round (R100)
  rather than the dispatch-wave label (R80) to avoid the mismatch
  this closure had to document after the fact.

## Tag disposition

**`r80-closed` is justified now.** All R80.M1 issues (#1, #2, #3) are
closed against landed, tagged code (`v0.5.0`); the honest-scope
stubs are documented in three independent locations; no ticket-
hygiene drift exists. Main cuts `r80-closed` on the `ping` satellite
after this commit lands.
