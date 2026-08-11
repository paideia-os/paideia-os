# Tooling Priority + Earliest Credible Release

**Companion to:** `design/tooling/plan.md` (Tier 3, ~95 tools).
**Purpose:** for every tool in the catalogue, name its priority (P0/P1/P2) and the earliest round by which the substrate it depends on is stable enough for implementation to *begin*. Implementation-begin, not release: tools take 1–3 weeks each; a P0 first-wave tool that "begins at R48" typically has its 1.0 signed release 2–8 weeks later.

## Release-code legend

The tools waves are grafted onto the round schedule from `design/roadmap/next-wave-synthesis.md`:

| Round | What lands | Why it gates tools |
|-------|-----------|-------------------|
| R27 | UDP + IPv4 | networking-touching tools cannot start |
| R28 | MVP-v0.1 | baseline (already landed 2026-08-11) |
| R38 | Wi-Fi AX211 | remote-network tools usable off-Ethernet |
| R42 | PdxFS v1 | **I5 undo** is enforceable; any destructive-op tool defers here |
| R44 | semantic-terminal-gui | GUI variants of tools become possible |
| R47 | VMD driver + all drivers closed | full T14 G4 substrate; last driver-round finishes |
| R48 | **T0** — first tooling wave | bootstrap tools (`pkg`, `shell`, `doc`) begin here |
| R49 | **T1** — coreutils survival | ls/cat/cp/mv/rm/mkdir |
| R50 | **T2** — filesystem power | grep/find/less |
| R51 | **T3** — Paideia introductions | caps/undo/tutor/gallery |
| R52 | **T4** — editor | `edit` (3 wk Ergonomics-heavy) |
| R53–R58 | **T5–T10** — P1 rolling | 6 rounds absorb the ~40 P1 tools |
| R59+ | **T11+** — P2 long tail | remaining ~38 P2 tools, demand-driven |

The T-rounds are named for tracking; they're not new architectural rounds like R29–R47. A T-round is a scheduling bucket, not a substrate landing.

## First-slice ordering (17 P0 tools, R48–R52)

| Wave | Round | Tools | Wall-clock |
|------|-------|-------|-----------|
| Wave 1 | R48 | `pkg`, `shell`, `doc` | ~3 wk |
| Wave 2 | R49 | `ls`, `cat`, `cp`, `mv`, `rm`, `mkdir` | ~5 wk |
| Wave 3 | R50 | `grep`, `find`, `less` | ~3 wk |
| Wave 4 | R51 | `caps`, `undo`, `tutor`, `gallery` | ~3 wk |
| Wave 5 | R52 | `edit` | ~3 wk |

## P1 phasing (R53–R58, ~40 tools)

| Round | Bucket | Tools |
|-------|--------|-------|
| R53 | sysadmin daily | `ps`, `kill`, `df`, `mount`, `journal`, `svc`, `date`, `reboot` |
| R54 | text-processing + shell power | `sort`, `uniq`, `head`, `tail`, `wc`, `diff`, `patch`, `pack`, `perms` |
| R55 | network core | `ping`, `net`, `fetch`, `remote`, `rcopy`, `user`, `pass` |
| R56 | comms | `mail`, `matrix`, `chat`, `clip`, `vault`, `mux` |
| R57 | productivity | `calc`, `note`, `agenda`, `task`, `snapshot`, `history` |
| R58 | Paideia-native follow-ons | `query`, `schema`, `journal-x`, `provenance`, `pipeviz` |

## P2 long tail (R59+, ~38 tools, demand-driven)

Filled in as users request. No fixed ordering. Includes: `rmdir`, `ln`, `touch`, `tree`, `locate`, `cut`, `tr`, `tee`, `live`, `du`, `sysmsg`, `disk`, `fmt`, `get`, `fw`, `ipcfg`, `group`, `cal`, `line`, `stream`, `rewrite`, `render`, `fold`, `expand`, `iconv`, `irc`, `timer`, `alarm`, `pomo`, `dict`, `unit`, `weather`, `feed`, `todo`, `web`, `bookmark`, `pastebin`.

## Full per-tool table

Read this as: **"tool X could earliest begin implementation at round Y."** A `†` marks tools that could technically start earlier but hold for a dependency's UX polish (usually the semantic-terminal frontend at R41/R44).

### Category A — filesystem + core utilities (25)

| Tool | Prio | Earliest | Depends on |
|------|------|----------|-----------|
| `pkg` | P0 | R48 | R42 PdxFS v1 (installs journal to snapshots), R27 network (repo fetch) |
| `ls` | P0 | R49 | R28 baseline |
| `cat` | P0 | R49 | R28 baseline |
| `cp` | P0 | R49 | R42 (I5 undo of overwrite) |
| `mv` | P0 | R49 | R42 (I5 undo) |
| `rm` | P0 | R49 | R42 (I5 undo — key case) |
| `mkdir` | P0 | R49 | R28 baseline |
| `rmdir` | P1 | R54 | R42 |
| `ln` | P1 | R54 | R42 |
| `touch` | P1 | R54 | R28 |
| `perms` | P1 | R54 | R29 (KIND_HW slot) + R42 |
| `find` | P0 | R50 | R28 (typed queries — R29 caps a plus but not required) |
| `locate` | P2 | R59+ | R42 (index in snapshot-aware store) |
| `tree` | P2 | R59+ | R28 |
| `grep` | P0 | R50 | R28 (pdx-regex shared lib, self-contained) |
| `sort` | P1 | R54 | R28 |
| `uniq` | P1 | R54 | R28 |
| `head` | P1 | R54 | R28 |
| `tail` | P1 | R54 | R28 |
| `wc` | P1 | R54 | R28 |
| `cut` | P2 | R59+ | R28 |
| `tr` | P2 | R59+ | R28 |
| `less` | P0 | R50 | R23 fb-console (color) + R41 sem-terminal |
| `tee` | P2 | R59+ | R28 |
| `pack` | P1 | R54 | R42 (I5 on extract-over-existing) |

### Category B — sysadmin (25)

| Tool | Prio | Earliest | Depends on |
|------|------|----------|-----------|
| `ps` | P0 | R53 | R28 (process abstraction from R15 already lands) |
| `live` | P1 | R56 | R41 sem-terminal (redraw loop), R37 GPU stats (optional) |
| `kill` | P0 | R53 | R28 |
| `mount` | P1 | R53 | R42 PdxFS v1 (mount source of truth) |
| `df` | P1 | R53 | R42 |
| `du` | P2 | R59+ | R42 |
| `sysmsg` | P1 | R55 | R25 (klog already there, wrapper) |
| `journal` | P1 | R53 | R42 (journal storage) |
| `svc` | P1 | R53 | R29 driver lifecycle FSM |
| `disk` | P2 | R59+ | R24 NVMe + R42 |
| `fmt` | P2 | R59+ | R42 (create PdxFS partitions) |
| `remote` | P1 | R55 | R27 UDP + TCP (arrives R43–R45 est.) + TLS lib |
| `rcopy` | P1 | R55 | same as `remote` |
| `net` | P1 | R55 | R27, R38 Wi-Fi |
| `ping` | P1 | R55 | R27 ICMP |
| `fetch` | P1 | R55 | TCP + TLS |
| `get` | P2 | R59+ | TCP + TLS |
| `fw` | P2 | R59+ | R27 |
| `ipcfg` | P2 | R59+ | R38 (Wi-Fi cfg needs AX211) |
| `user` | P1 | R55 | R42 (user-record store) |
| `group` | P2 | R59+ | R42 |
| `pass` | P1 | R55 | R42, ML-DSA-65 lib (from R32) |
| `date` | P1 | R53 | R28 (HPET + TSC-deadline already) |
| `cal` | P2 | R59+ | R28 |
| `reboot` | P1 | R53 | R28 (kernel shutdown path exists) |

### Category C — text processing + editors (10)

| Tool | Prio | Earliest | Depends on |
|------|------|----------|-----------|
| `edit` | P0 | R52 | R41 sem-terminal, R42 (undo), R29 (cap-aware file open) |
| `line` | P2 | R59+ | R28 |
| `stream` | P2 | R59+ | R28 (pdx-regex) |
| `rewrite` | P2 | R59+ | R42 (I5 on in-place edit) |
| `diff` | P1 | R54 | R28 |
| `patch` | P1 | R54 | R42 |
| `render` | P2 | R59+ | R41 sem-terminal (ANSI SGR), G5 SDF text (GUI variant) |
| `fold` | P2 | R59+ | R28 |
| `expand` | P2 | R59+ | R28 |
| `iconv` | P2 | R59+ | R28 |

### Category D — comms + productivity (25)

| Tool | Prio | Earliest | Depends on |
|------|------|----------|-----------|
| `mail` | P1 | R56 | TCP + TLS + `vault` for creds |
| `irc` | P2 | R59+ | TCP + TLS |
| `matrix` | P2 | R59+ | TCP + TLS, olm/megolm equivalent |
| `chat` | P2 | R59+ | R28 (local IPC only) |
| `calc` | P1 | R57 | R28 |
| `note` | P1 | R57 | R42 (persistence + tags) |
| `agenda` | P1 | R57 | R42, `pdx-time` |
| `task` | P1 | R57 | R42, R41 sem-terminal |
| `timer` | P2 | R59+ | R28 |
| `alarm` | P2 | R59+ | R28 (LAPIC timer sufficient) |
| `pomo` | P2 | R59+ | R28 |
| `dict` | P2 | R59+ | R42 (local dict store) |
| `unit` | P2 | R59+ | R28 |
| `weather` | P2 | R59+ | TCP + TLS |
| `feed` | P2 | R59+ | TCP + TLS |
| `todo` | P2 | R59+ | R42 |
| `clip` | P1 | R56 | R42 (persistence), R29 (cap on clipboard content) |
| `vault` | P1 | R56 | R42, ML-DSA-65 (R32) |
| `web` | P2 | R59+ | TCP + TLS, G5 SDF (GUI variant) |
| `mux` | P1 | R56 | R41 sem-terminal |
| `shell` | P0 | R48 | R41 sem-terminal, R42 (history persistence) |
| `history` | P1 | R57 | R42 |
| `bookmark` | P2 | R59+ | R42 |
| `pastebin` | P2 | R59+ | R42 |
| `snapshot` | P1 | R57 | R42 (thin wrapper on the FS primitive) |

### Category E — Paideia-native new tools (10)

| Tool | Prio | Earliest | Depends on |
|------|------|----------|-----------|
| `caps` | P0 | R51 | R29 KIND_HW + all downstream caps stabilized |
| `undo` | P0 | R51 | R42 PdxFS v1 (the core substrate for I5) |
| `provenance` | P1 | R58 | R42 (audit-log persistence) + R29 (per-op provenance record) |
| `query` | P1 | R58 | R41 sem-terminal (schema-aware pipe), all P0 tools that emit schemas |
| `schema` | P1 | R58 | R41 (schema library) |
| `journal-x` | P1 | R58 | R42 audit-log storage |
| `doc` | P0 | R48 | R28 (needs no substrate beyond baseline) |
| `tutor` | P0 | R51 | `doc` + `shell` |
| `gallery` | P0 | R51 | `doc` |
| `pipeviz` | P1 | R58 | R44 sem-terminal-gui (visualization is GUI-heavy) |

## Round-summary chart

```
R28 (baseline, done)  ┐
R29 (driver substrate)│  substrate rounds
...                   │  — no tooling begins here
R42 (PdxFS v1)        │  — tools with I5-undo now viable
R44 (sem-term-gui)    │  — GUI variants viable
R47 (VMD + driver-end)┘
─────────────────────────────
R48   T0 wave 1       — pkg, shell, doc
R49   T1 wave 2       — ls, cat, cp, mv, rm, mkdir
R50   T2 wave 3       — grep, find, less
R51   T3 wave 4       — caps, undo, tutor, gallery
R52   T4 wave 5       — edit
─────────────────────────────
R53–R58 T5–T10        — ~40 P1 tools rolling
R59+   T11+           — ~38 P2 tools demand-driven
```

## Caveat on TCP + TLS

Several rows above cite "TCP + TLS." Neither is currently on the next-wave milestone catalogue — R27 delivered UDP/ICMP/IPv4 only, and the current plan does not have a TCP round scoped. Any tool that requires network beyond UDP (mail, irc, matrix, fetch, remote, rcopy, get, weather, feed, web) is blocked on a future round that introduces TCP + TLS 1.3 + ML-KEM. Best-current-estimate: this lands as an interim round somewhere in R43–R46 (parallel with G-series). This document uses "TCP + TLS" as a placeholder; the milestone will be filed separately.

## What this document is not

- Not a schedule commitment. Rounds are 4–6 wk each estimated, but overruns propagate.
- Not a strict ordering within a wave. Within Wave 1 R48, `pkg` obviously precedes `shell` and `doc`, but the fine sub-ordering is a call for the implementer.
- Not a substitute for `plan.md`. This is the phasing companion; the design decisions and invariants live there.
