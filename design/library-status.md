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
| **libpdx-schema-registry** | 4 | 5 | 0 | Schema registry client-facade (record types, register/lookup/list, audit + elevate hooks, wire spec) — M1..M4 shipped 2026-09-01 | Every semantic-pipe consumer (ls, cat, doc, pdxcurl, postui, all schema-emitting tools) |
| **libpdx-audit** | 3 | 5 | 0 | Audit-first emit to `/system/audit/*.log` (I5 invariant) | Every destructive-op tool (rm, mv, cp, mkfs, mount, umount, pkg) |
| **libpdx-cap** | 4 | 5 | 1 | Capability marshalling — ENH-008 (additive caller-owned re-entrant variants) shipped 2026-09-01 sat `f472530` | Every satellite tool that mints/consumes caps. #20 remains open (externally blocked on shell.ENH-032) |
| **libpdx-elevate** | 4 | 5 | 0 | Client-side elevate protocol helper — ALLOW/DENY/TIMEOUT reconciliation shipped 2026-09-01 sat `3e54a8e`; full kernel-side broker landed at `2225b18` | Every privileged tool (rm system paths, mkfs, pdxping, pdxcurl) |
| **libpdx-semantic-pipe** | 5 | 5 | 6 | Schema-typed pipe endpoints over KIND_IPC_ENDPOINT | postui + shell + every schema-emitting tool |
| **paideia-as** | 5 | 5 | 2 | Assembler compiler + crypto intrinsics. Sweep 2026-09-01: lexer `\xFF` fix (`v0.24.1`), SHA-256 (`v0.25.0`), HMAC/HKDF (`v0.26.0`), X25519 (`v0.27.0`). #1341 Ed25519 stalled (sc_muladd bit-off); #1336 umbrella open pending. | Every .pdx compilation everywhere + TLS 1.3 in R100 wave |
| **postui** | 1 | 4 | 40 | Ratatui-inspired TUI library, cap-based, semantically-queryable | postui-dmesg/hex/top + shell/edit/doc TUI layer |
| **libpdx-volume** | 3 | 4 | 0 | KIND_VOLUME helpers + PDXB codec + mount_table | mkfs.pdxfs, mount.pdxfs, umount.pdxfs, persistent-home |
| **libpdx-url** | 1 | 3 | 11 | RFC 3986 URL parser (http/https, no credentials) | pdxcurl, pkg mirror URLs, remote, fetch |
| **libpdx-argv** | 3 | 3 | 2 | CLI arg parsing (text + semantic-schema invocation) | Every CLI tool |
| **libpdx-config** | 1 | 2 | 0 | `/etc` key=value config parser | A few config-consuming tools |

## In-flight investment (2026-09-01)

- **libpdx-schema-registry** — completion sweep in progress. See §sweep below.
- **libpdx-cap** — #18 landed at satellite `f472530` (2026-09-01). Completion 3→4. #20 remains open (externally blocked).
- **libpdx-elevate** — cascade fully closed 2026-09-01. Kernel: #2117-#2120 leaves at `ede6179`, #2121 policy stamp, #2122 broker dispatch at `2225b18`. Satellite: #18 at `3e54a8e`. Completion 3→4. 0 open issues.
- **ls** — 10 new ENH issues filed (ls#32..41). Sweep 2026-09-01: 1/10 fully closed (ENH-019 `-F` flag), 9/10 partial-landed with commits (scaffolding + walker arms), blocked on cross-repo deps: #29 (path resolve), #24/#25/#30 (Long/Color/schema-registry wiring), plus new kernel-side gaps flagged in bodies (`sys_ttywinsize`, `sys_pdxfs_openat`, `sys_pdxfs_readlink`, `sys_pdxfs_stat_by_inode`).
- **libpdx-net** — recommended next; not yet started.
- **paideia-as** — sweep 2026-09-01. Closed: #1337 (`d194327` v0.24.1), #1338 SHA-256 (`bec881e` v0.25.0), #1339 HMAC/HKDF (`f8c739f` v0.26.0), #1340 X25519 (`a825f84` v0.27.0). Stalled: #1341 Ed25519 — sc_muladd bit-off in sign; umbrella #1336 stays open awaiting fix. Cargo test at HEAD: 63 lib + 11 int pass (0 fail, 1 ignored 1M-iter X25519). Paideia-os submodule pointer NOT bumped (main decision — 3 minor + 1 patch version jump is substantial).

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
| 2026-09-01 | M1 | #1 scaffold | closed `be0ae09` |
| 2026-09-01 | M2 | #2 record types | closed `a88ae08` |
| 2026-09-01 | M2 | #3 register+dedup | closed `2c7f4e9` |
| 2026-09-01 | M2 | #4 lookup | closed `0ed42ef` |
| 2026-09-01 | M2 | #5 list | closed `bd64dd6` |
| 2026-09-01 | M3 | #6 audit hook | closed `a21158f` |
| 2026-09-01 | M3 | #7 elevate gate | closed `483288e` |
| 2026-09-01 | M3 | #8 semantic-pipe wire | closed `c6c509b` |
| 2026-09-01 | M4 | #9 unit tests | closed `9df3cd5` |
| 2026-09-01 | M4 | #10 smoke witness | closed `020e697` |

**Sweep result:** completion 1 → 4. FNV-1a-64 hash placeholder (BLAKE3 intrinsic pending in paideia-as); R_SCHEMA_REGISTER = 0x40; wire spec landed as marshalling helpers only (Send/Recv routes through libpdx-semantic-pipe when a consumer wires it up).
