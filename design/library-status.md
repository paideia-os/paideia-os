# paideia-os libraries — completion + priority tracker

Snapshot: 2026-09-01.
Source: `ListAgents` + `gh` audit of `paideia-os/libpdx-*` and adjacent library repos.

Columns:
- **Completion**: 1 (scaffold only) → 5 (signed release, downstream consumers landed).
- **Priority**: 1 (nothing depends) → 5 (blocks many downstream repos or the project vision).
- **Open Issues**: `gh issue list --state open` count.
- **Blocks downstream**: what stalls if this library doesn't ship.

Sort: Priority DESC, then Completion ASC (highest-priority under-built rises first).

| Repo | Completion | Priority | Open Issues | Summary | Blocks downstream |
|---|:-:|:-:|:-:|---|---|
| **libpdx-net** | 1 | 5 | 22 | TCP/UDP wrappers + DNS resolver + TLS 1.3 (raw pubkey) | pdxcurl, pdxdig, pdxsock, pdxping.M2, fetch |
| **libpdx-schema-registry** | 1 | 5 | 1 | Schema registry service + client (svc.schema-registry) | Every semantic-pipe consumer (ls, cat, doc, pdxcurl, postui, all schema-emitting tools) |
| **libpdx-audit** | 3 | 5 | 0 | Audit-first emit to `/system/audit/*.log` (I5 invariant) | Every destructive-op tool (rm, mv, cp, mkfs, mount, umount, pkg) |
| **libpdx-cap** | 3 | 5 | 2 | Capability marshalling for tool invocations | Every satellite tool that mints/consumes caps |
| **libpdx-elevate** | 3 | 5 | 1 | Client-side elevate protocol helper | Every privileged tool (rm system paths, mkfs, pdxping, pdxcurl) |
| **libpdx-semantic-pipe** | 5 | 5 | 6 | Schema-typed pipe endpoints over KIND_IPC_ENDPOINT | postui + shell + every schema-emitting tool |
| **paideia-as** | 5 | 5 | 1 | Assembler compiler (Rust, self-hosted target) | Every .pdx compilation everywhere |
| **postui** | 1 | 4 | 40 | Ratatui-inspired TUI library, cap-based, semantically-queryable | postui-dmesg/hex/top + shell/edit/doc TUI layer |
| **libpdx-volume** | 3 | 4 | 0 | KIND_VOLUME helpers + PDXB codec + mount_table | mkfs.pdxfs, mount.pdxfs, umount.pdxfs, persistent-home |
| **libpdx-url** | 1 | 3 | 11 | RFC 3986 URL parser (http/https, no credentials) | pdxcurl, pkg mirror URLs, remote, fetch |
| **libpdx-argv** | 3 | 3 | 2 | CLI arg parsing (text + semantic-schema invocation) | Every CLI tool |
| **libpdx-config** | 1 | 2 | 0 | `/etc` key=value config parser | A few config-consuming tools |

## In-flight investment (2026-09-01)

- **libpdx-schema-registry** — completion sweep in progress. See §"libpdx-schema-registry sweep" below.
- **libpdx-net** — recommended next; not yet started.

## libpdx-schema-registry sweep

Started 2026-09-01. Target: raise completion 1 → 4 (skip M5 signed release for now).

### Baseline state

- Repo created 2026-09-01, MIT, single README pointing at `design/round-retrospectives/r90-xrepo-wave3-plan.md`.
- 1 open issue: `#1 R90-XREPO.012.M1-001 Create libpdx-schema-registry repo scaffolding` (milestone R90-XREPO.012).
- No M2..M5 issues filed for this repo yet — only the cross-repo Wave 3 R90-XREPO.012 issues (which live in paideia-os, libpdx-semantic-pipe, ls, cat, doc) reference this library.

### Sweep plan

1. **M1 (scaffolding)** — issue #1 alone: repo layout, module skeleton, encoder-conservative build stanza, cross-repo import wiring against paideia-as.
2. **M2 (real body)** — file 3-5 new issues: schema-registry protocol (register/lookup/list ops), in-memory store, IPC endpoint wiring against `svc.schema-registry`, fingerprint discipline.
3. **M3 (audit + elevate + semantic-pipe emit)** — file 3-5 new issues: audit-first record on register/lookup, elevate-broker gating on register (schema authors are trusted), semantic-pipe record shape.
4. **M4 (tests + smoke)** — file 2-3 new issues: unit tests via cargo (Rust harness or `.pdx` fixture), boot smoke witness.
5. Skip M5 for now.

### Status log

| Date | Milestone | Issue | State |
|---|---|---|---|
| 2026-09-01 | M1 | #1 (scaffold) | in-progress (softarch dispatched) |
