# PaideiaOS Ecosystem Status

**Snapshot:** 2026-09-01.
**Refresh command:** `ECOTABLE` — issued to Claude Code in this project, rebuilds the tables end-to-end from a fresh `gh` audit of the `paideia-os` org. (Saved in Claude's project memory as an on-demand rebuild trigger; nothing runs on a timer.)

This document is a cross-repo readiness map: every library and every tool in the `paideia-os` GitHub org, scored on the same 5-segment maturity scale, sorted so the highest-blast-radius under-built repos surface first.

## Legend

**Semaphore convention.** Each repo is scored on a 5-segment maturity bar `[█████]` → `[█░░░░]`, then bucketed into a red/yellow/green semaphore for at-a-glance triage:

| Bar | Segments | Status | Meaning |
|---|:-:|:-:|---|
| `[█████]` | 5 | 🟢 | Signed release + M5 closed + downstream consumers active. |
| `[████░]` | 4 | 🟡 | Tests landed + M4 closed. |
| `[███░░]` | 3 | 🟡 | Real body implemented + M2/M3 closed. |
| `[██░░░]` | 2 | 🔴 | Scaffold in + M1 closed. |
| `[█░░░░]` | 1 | 🔴 | Repo exists only (auto-README, no code body). |

Sort within each table: **Status ASC** (🔴 first), then **Dependent repos DESC** — the goal is to make the highest-blast-radius under-built repos read first.

**OS changes needed** is the count of *open* issues in the `paideia-os/paideia-os` monorepo that this satellite requires before it can finish its own open milestones. It is derived by grepping this satellite's open issues for `Blocked by paideia-os/paideia-os#NNNN` cross-references and counting distinct kernel-side dependencies. A value of 0 means the satellite is not currently gated on any monorepo change; a value of `n` means `n` kernel-side issues must land first (or a `caps.decl`/dispatch handler / syscall / KIND / intrinsic pending in the monorepo).

**Dependent repos** is the count of other satellites in the org whose issues, plans, or design docs reference this repo as a build-time or run-time dependency. Where the count is small (≤5), the dependents are listed inline; otherwise only the count is shown to keep the table readable.

Library maturity scores are inherited from `design/library-status.md` (this repo's canonical library tracker, which is refreshed by a different pass and stays independently maintained). Tool maturity scores are computed here from a fresh audit — commit count, release tags, per-milestone `open:closed` ratio, presence of `caps.decl`, and whether any downstream design doc treats the tool as landed.

---

## Table 1 — Libraries

| Repo | Maturity | Status | Dependent repos | OS changes needed | Summary |
|---|:-:|:-:|---|:-:|---|
| `libpdx-net` | `[█░░░░]` | 🔴 | 9 (pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust, fetch, ping, remote, pkg) | 5 | TCP/UDP wrappers, DNS resolver, TLS 1.3 raw-pubkey client, HTTP/1.1 client. Blocks the entire R100 network-tools wave. 22 open across M1..M5. |
| `postui` | `[█░░░░]` | 🔴 | 6 (postui-dmesg, postui-hex, postui-top, shell, edit, doc) | 2 | Ratatui-inspired TUI library, cap-based, semantically-queryable. 40 open across postui.M1..M5. Blocks all reference apps and the shell/edit/doc TUI layer. |
| `libpdx-url` | `[█░░░░]` | 🔴 | 5 (libpdx-net, pdxcurl, pkg, fetch, remote) | 0 | RFC 3986 URL parser + validator (http/https only, no embedded creds). Pure userspace; scaffold only (2 commits, 11 open). |
| `libpdx-config` | `[█░░░░]` | 🔴 | 3 (pkg, shell, pdxtrust) | 0 | `/etc` key=value config parser. Only 2 commits; R74 milestone bookkeeping-closed but repo body is a scaffold. |
| `libpdx-cap` | `[████░]` | 🟡 | 22 (every tool + libpdx-audit + libpdx-elevate) | 0 | Capability marshalling. v1.0.1 tagged 2026-09-01 (ENH-008 caller-owned re-entrant variants at `f472530`). #20 open, externally blocked on `shell.ENH-032`. |
| `libpdx-argv` | `[███░░]` | 🟡 | 22 (every CLI tool) | 0 | CLI arg parsing (text + semantic-schema invocation). v1.0.0 tagged; v1.1 enhancement wave has 2 open + 9 additional new issues (11 total open). |
| `libpdx-schema-registry` | `[████░]` | 🟡 | 10 (libpdx-semantic-pipe, ls, cat, doc, pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust, pkg) | 0 | Schema registry client-facade. 12 commits, 0 open. M1..M4 all closed 2026-09-01; M5 signed release deferred. |
| `libpdx-audit` | `[███░░]` | 🟡 | 10 (rm, mv, cp, mkfs.pdxfs, mount.pdxfs, umount.pdxfs, pkg, pdxtrust, pdxcurl, pdxping) | 0 | Audit-first emit to `/system/audit/*.log` (I5 invariant). v1.0.0 tagged; 0 open. |
| `libpdx-elevate` | `[████░]` | 🟡 | 8 (rm, mkfs.pdxfs, mount.pdxfs, umount.pdxfs, pkg, pdxtrust, pdxping, pdxcurl) | 0 | Client-side elevate protocol helper. Cascade fully closed 2026-09-01 (`3e54a8e`); kernel broker at `2225b18`. 0 open. |
| `libpdx-volume` | `[███░░]` | 🟡 | 3 (mkfs.pdxfs, mount.pdxfs, umount.pdxfs) | 0 | KIND_VOLUME helpers + PDXB codec + mount_table. `r64v2-closed` tag; 0 open. |
| `paideia-as` | `[█████]` | 🟢 | 37 (every other repo in the org) | 0 | Assembler compiler (Rust, self-hosted target). 1120 commits; **v0.28.0** (v0.24.1 lexer fix, v0.25.0 SHA-256, v0.26.0 HMAC/HKDF, v0.27.0 X25519, v0.28.0 Ed25519). Umbrella #1336 closed 2026-09-01; **0 open issues** — full TLS 1.3 crypto substrate landed, unblocking `libpdx-net` cascade. |
| `libpdx-semantic-pipe` | `[█████]` | 🟢 | 17 (postui + shell + every schema-emitting tool) | 0 | Schema-typed pipe endpoints over `KIND_IPC_ENDPOINT`. v1.0.0 tagged. 6 open across the v2.0 adoption-unblock wave + R90-XREPO.012 bind_by_name real path. |

---

## Table 2 — Tools

| Repo | Maturity | Status | Dependent repos | OS changes needed | Summary |
|---|:-:|:-:|---|:-:|---|
| `edit` | `[█░░░░]` | 🔴 | 0 | 3 | vi-like modeless TUI editor. 1 commit; R71 milestone has 7 open. |
| `fetch` | `[█░░░░]` | 🔴 | 0 | 5 | HTTP GET client over TCP. Scaffold (1 commit, 3 open); blocked on `libpdx-net`.M4 + kernel TLS crypto. |
| `line` | `[█░░░░]` | 🔴 | 0 | 2 | ed-style scriptable line editor. Scaffold (1 commit); R63 milestone has 7 open. |
| `pdxcurl` | `[█░░░░]` | 🔴 | 0 | 5 | Improved-curl CLI (cap-native, PQ-preferring). Scaffold (2 commits, 19 open across M1..M5); blocked on `libpdx-net`.M3/M4 + `KIND_TLS_TRUST`. |
| `pdxdig` | `[█░░░░]` | 🔴 | 0 | 2 | DNS query CLI. Scaffold (2 commits, 15 open); blocked on `libpdx-net`.M2 + `SOCK_DGRAM` socket-family extension. |
| `pdxping` | `[█░░░░]` | 🔴 | 0 | 2 | ICMP echo CLI. Scaffold (2 commits, 13 open); blocked on `sys_icmp_echo` (sysno 96) + `R_NET_PRIVILEGED_PROTOCOL` elevate class. |
| `pdxsock` | `[█░░░░]` | 🔴 | 0 | 1 | General TCP/UDP client + server (netcat-adjacent). Scaffold (2 commits, 14 open); TCP path buildable now; UDP mode gated on `SOCK_DGRAM`. |
| `pdxtrust` | `[█░░░░]` | 🔴 | 0 | 1 | Trust-anchor management CLI. Scaffold (2 commits, 15 open); blocked on `KIND_TLS_TRUST` cap kind landing kernel-side. |
| `ping` | `[█░░░░]` | 🔴 | 0 | 2 | Legacy R80 ping tool. 1 commit, 3 open; superseded by `pdxping` — likely to be retired. |
| `remote` | `[█░░░░]` | 🔴 | 0 | 4 | Secure shell + remote copy with ML-KEM handshake. Scaffold (1 commit, 7 open); blocked on `libpdx-net`.M3 + ML-KEM intrinsic. |
| `cat` | `[█████]` | 🟢 | 0 | 1 | File read/concatenate (schema-passthrough on semantic pipes). v1.0.0. 6 open (Enhancement v1.x + R90-XREPO.013 caps.decl). |
| `cp` | `[█████]` | 🟢 | 0 | 1 | Copy with PdxFS undo record (I5 invariant). v1.0.0; M5 closed. 4 open (Enhancement v1.1 + R90-XREPO.013). |
| `doc` | `[█████]` | 🟢 | 0 | 1 | Documentation viewer (structured `.pdxdoc`, semantic-pipe emission). v1.0.0. 9 open (R79 + v0.5 post-audit reset + R90-XREPO.013). |
| `ls` | `[█████]` | 🟢 | 0 | 2 | Directory listing (emits `PdxFsDirEntry[]` records). v1.0.0; M5 closed. 36 commits, 20 open (9 ENH-wave + R90-XREPO.012/013). |
| `mkdir` | `[█████]` | 🟢 | 0 | 1 | Directory create. v1.0.0. 38 commits, 4 open (Enhancement v1.x + R90-XREPO.013). |
| `mkfs.pdxfs` | `[█████]` | 🟢 | 0 | 0 | PdxFS-on-block volume formatter (PDXB superblock + WAL + root inode). `r64v2-closed`; 0 open. |
| `mount.pdxfs` | `[█████]` | 🟢 | 0 | 0 | Volume mount tool (`sys_mount` + `PdxFsMountRecord` audit). `r64v2-closed`; 0 open. |
| `mv` | `[█████]` | 🟢 | 0 | 1 | Move with PdxFS undo + destructive-op audit. v1.0.0. 7 open (Enhancement v1.x + R90-XREPO.013). |
| `pkg` | `[█████]` | 🟢 | 0 | 1 | Package manager (dual-signed manifests, elevate-integrated). `pkg-v1.0.0`; 34 commits, 15 open (R70 MVP + Enhancement v1.x + R90-XREPO.013). |
| `rm` | `[█████]` | 🟢 | 0 | 1 | Remove with undo + destructive-op audit + elevate for system paths. v1.0.0. 7 open (Enhancement v1.x + R90-XREPO.013). |
| `shell` | `[█████]` | 🟢 | 0 | 3 | Paideia shell (semantic-pipes aware, elevate-integrated). v1.0.0. 23 open (R66 polish + R73 tier-2 + v2.0 real-exec-substrate + R90-XREPO.013). |
| `umount.pdxfs` | `[█████]` | 🟢 | 0 | 0 | Volume unmount (`sys_umount` + WAL CLEAN checkpoint). `r64v2-closed`; 0 open. |

Reference apps (`postui-dmesg`, `postui-hex`, `postui-top`) and the umbrella `paideia-os` monorepo are intentionally omitted per the classification rule.

---

## Table 3 — Dependency-impact matrix

For each library, what breaks (or needs re-verification) on a breaking or minor-behavior-change release.

| Updated repo | Downstream libraries | Downstream tools | Kernel-side hits |
|---|---|---|---|
| `libpdx-argv` | (none directly) | cat, cp, doc, edit, fetch, line, ls, mkdir, mkfs.pdxfs, mount.pdxfs, mv, pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust, ping, pkg, remote, rm, shell, umount.pdxfs | (none) |
| `libpdx-audit` | libpdx-elevate (audit on elevate events), libpdx-volume (mount records) | rm, mv, cp, mkfs.pdxfs, mount.pdxfs, umount.pdxfs, pkg, pdxtrust, pdxcurl, pdxping | `svc.audit` daemon, `/system/audit/*.log` layout, `KIND_AUDIT_ENDPOINT` |
| `libpdx-cap` | libpdx-audit, libpdx-elevate, libpdx-semantic-pipe | every tool (all 22) | elevate-broker cap-narrowing path, `KIND_*` dispatch tables, exec-time cap reconciliation (`sys_exec_reconcile_caps`) |
| `libpdx-config` | (none directly) | pkg (mirror list), shell (rc), pdxtrust (system trust dir) | (none) |
| `libpdx-elevate` | libpdx-audit (audit on elevate events) | rm, mkfs.pdxfs, mount.pdxfs, umount.pdxfs, pkg, pdxtrust, pdxping, pdxcurl | `KIND_ELEVATE_CHANNEL` dispatch, `elevate_broker` daemon, `/system/policy` loader, `uej_append` audit journal |
| `libpdx-net` | libpdx-url (net consumes url for HTTPS validation) | pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust, fetch, ping, remote, pkg (future) | `sys_socket` family (SC+ 87–94), `SOCK_DGRAM` extension (§12.1), `sys_icmp_echo` (§12.2, sysno 96), `KIND_TLS_TRUST` (§12.3). Note: paideia-as v0.28.0 landed the full TLS crypto substrate (SHA-256, HKDF, X25519, Ed25519) 2026-09-01 — this row's assembler-side dependency is cleared. |
| `libpdx-schema-registry` | libpdx-semantic-pipe (`bind_by_name` real path) | ls, cat, doc, pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust, pkg (future emitters) | `KIND_SCHEMA_HANDLE` dispatch, `svc.schema-registry` daemon, `svc_broker` name-table entry |
| `libpdx-semantic-pipe` | postui (TUI widget emissions), libpdx-schema-registry (co-dep on bind path) | shell, ls, cat, doc, mv, cp, rm, mkfs.pdxfs, mount.pdxfs, umount.pdxfs, pkg, pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust | `KIND_IPC_ENDPOINT` dispatch, in-kernel pipe fast path |
| `libpdx-url` | libpdx-net (HTTPS URL parsing) | pdxcurl, pkg, fetch, remote | (none) |
| `libpdx-volume` | (none directly) | mkfs.pdxfs, mount.pdxfs, umount.pdxfs | `KIND_VOLUME` dispatch, `sys_mount`/`sys_umount`, PDXB superblock codec, mount_table |
| `paideia-as` | libpdx-argv, libpdx-audit, libpdx-cap, libpdx-config, libpdx-elevate, libpdx-net, libpdx-schema-registry, libpdx-semantic-pipe, libpdx-url, libpdx-volume, postui | every tool (all 22) | entire `paideia-os` kernel (every `.pdx` source in the monorepo goes through the same assembler; every intrinsic bump can force a boot-witness re-verify) |
| `postui` | (none directly) | postui-dmesg, postui-hex, postui-top, shell (TUI layer), edit, doc | `KIND_TUI_CANVAS` dispatch, framebuffer-stdlib intrinsics (paideia-as v0.23), input-pipeline event loop |

### Reading the matrix

- **Row scope.** A row's downstream cells list every satellite that would need at least a re-verify pass on a minor-behavior release of the updated repo. A *breaking* release additionally forces every downstream to bump its submodule pin and re-run its own M4 smoke.
- **Kernel-side hits.** A library update forces a monorepo change when the library's ABI touches a kernel-owned surface — a `KIND_*` dispatch table, a syscall number, a daemon name, an audit record shape. Rows with "(none)" are entirely userspace and can ship without touching `paideia-os/paideia-os`.
- **Transitive.** These are direct dependencies only. `libpdx-cap` transitively touches every kernel surface via the downstream tools, but the matrix records only the surfaces `libpdx-cap` itself binds against.

---

## Notes on this snapshot

- **paideia-as jumped v0.24.0 → v0.28.0 in one day** (2026-09-01): v0.24.1 (lexer `\xFF` fix), v0.25.0 (SHA-256), v0.26.0 (HMAC/HKDF), v0.27.0..v0.27.4 (X25519 + fixture/snapshot patches), v0.28.0 (Ed25519). Umbrella `crypto-intrinsics-for-tls` #1336 closed. **0 open issues** on the assembler — every TLS 1.3 crypto intrinsic `libpdx-net`.M3 needs is now available. The score stays 🟢 (already at the ceiling); the *practical* impact is the cross-repo unblock: `libpdx-net` M3 can begin without an upstream escalation.
- **libpdx-elevate** completed its M4 cascade (satellite `3e54a8e`; kernel broker `2225b18`), moving 3 → 4 🟡. Zero open issues; awaiting only the M5 signed release.
- **libpdx-schema-registry** shipped M1..M4 in a single-day sweep (12 commits, `be0ae09` → `020e697`), moving 1 → 4 🟡. FNV-1a-64 hash placeholder held pending a paideia-as BLAKE3 intrinsic.
- **libpdx-cap** cut `v1.0.1` (ENH-008 additive re-entrant variants at `f472530`), moving 3 → 4 🟡. #20 remains open, externally blocked on `shell.ENH-032`.
- **Volume tools** (`mkfs.pdxfs`, `mount.pdxfs`, `umount.pdxfs`) carry the `r64v2-closed` release tag rather than a `v1.0.0` version tag; the r64 v2 closure retrospective (`design/round-retrospectives/r64-closure-v2.md`) treats that tag as the equivalent signed release, so they score 🟢.
- **`libpdx-config`** has only 2 commits and no `v1.0.0` tag; despite both R74 milestone issues being closed, the repo body is a scaffold. Scored 🔴 to reflect actual code state rather than milestone bookkeeping.
- **`ping`** (the R80-era tool) and **`pdxping`** (the R100 tool) coexist in the org; only the latter is on the R100 landing path. `ping` is likely to be retired but has not been formally deprecated in an issue.
- **`libpdx-net`** is now the single largest cross-repo escalation surface. With the paideia-as crypto substrate landed, its 22 open issues (M1..M5) are the only blocker for `pdxcurl`, `pdxdig`, `pdxping`, `pdxsock`, `pdxtrust`, `fetch`, `ping`, `remote`, and the `pkg` mirror path. Recommended next investment.
- **`ls`** enhancement wave is in flight — 10 new ENH issues filed (`ls#32..41`) this cycle, 1 fully closed (ENH-019 `-F` flag), 9 partial-landed with commits and blocked on kernel-side gaps (`sys_ttywinsize`, `sys_pdxfs_openat`, `sys_pdxfs_readlink`, `sys_pdxfs_stat_by_inode` — the last landed today as monorepo #2110). Score remains 🟢 (v1.0.0 shipped, downstream `shell` consumes it) despite the temporary open-count spike.
- **`paideia-os` monorepo** is deliberately excluded from the tables per the classification rule; today's R90-XREPO.010 substrate landings (#2109 PDXFS READ_BYTES, #2111 txn commit/abort, #2115 design) sit in the ~120+ open issues remaining across R91–R99 + R90-XREPO waves.

---

*Refresh: send the `ECOTABLE` command to Claude Code in this project to rebuild.*
