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
| `libpdx-net` | `[█░░░░]` | 🔴 | 9 (pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust, fetch, ping, remote, pkg) | 5 | TCP/UDP wrappers, DNS resolver, TLS 1.3 raw-pubkey client, HTTP/1.1 client. Blocks the entire R100 network-tools wave. |
| `postui` | `[█░░░░]` | 🔴 | 6 (postui-dmesg, postui-hex, postui-top, shell, edit, doc) | 2 | Ratatui-inspired TUI library, cap-based, semantically-queryable. Blocks all reference apps and the shell/edit/doc TUI layer. |
| `libpdx-url` | `[█░░░░]` | 🔴 | 5 (libpdx-net, pdxcurl, pkg, fetch, remote) | 0 | RFC 3986 URL parser + validator (http/https only, no embedded creds). Pure userspace; no kernel gap. |
| `libpdx-config` | `[█░░░░]` | 🔴 | 3 (pkg, shell, pdxtrust) | 0 | `/etc` key=value config parser. Only two commits; scaffold only. |
| `libpdx-cap` | `[████░]` | 🟡 | 22 (every tool + libpdx-audit + libpdx-elevate) | 0 | Capability marshalling. ENH-008 (caller-owned re-entrant variants) shipped 2026-09-01. #20 externally blocked on `shell.ENH-032`. |
| `libpdx-argv` | `[███░░]` | 🟡 | 22 (every CLI tool) | 0 | CLI arg parsing (text + semantic-schema invocation). v1.0.0 tagged; v1.1 enhancement wave in flight (2 open). |
| `libpdx-schema-registry` | `[████░]` | 🟡 | 10 (libpdx-semantic-pipe, ls, cat, doc, pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust, pkg) | 0 | Schema registry client-facade. M1..M4 shipped 2026-09-01. M5 signed release deferred. |
| `libpdx-audit` | `[███░░]` | 🟡 | 10 (rm, mv, cp, mkfs.pdxfs, mount.pdxfs, umount.pdxfs, pkg, pdxtrust, pdxcurl, pdxping) | 0 | Audit-first emit to `/system/audit/*.log` (I5 invariant). v1.0.0 tagged. |
| `libpdx-elevate` | `[████░]` | 🟡 | 8 (rm, mkfs.pdxfs, mount.pdxfs, umount.pdxfs, pkg, pdxtrust, pdxping, pdxcurl) | 0 | Client-side elevate protocol helper. Cascade fully closed 2026-09-01 (`3e54a8e`); kernel broker at `2225b18`. |
| `libpdx-volume` | `[███░░]` | 🟡 | 3 (mkfs.pdxfs, mount.pdxfs, umount.pdxfs) | 0 | KIND_VOLUME helpers + PDXB codec + mount_table. r64v2-closed. |
| `paideia-as` | `[█████]` | 🟢 | 37 (every other repo in the org) | 0 | Assembler compiler (Rust, self-hosted target). 1111 commits; v0.24.0. `crypto-intrinsics-for-tls` milestone open (blocks `libpdx-net`). |
| `libpdx-semantic-pipe` | `[█████]` | 🟢 | 17 (postui + shell + every schema-emitting tool) | 0 | Schema-typed pipe endpoints over `KIND_IPC_ENDPOINT`. v1.0.0 tagged. 5 open in the v2.0 adoption-unblock wave. |

---

## Table 2 — Tools

| Repo | Maturity | Status | Dependent repos | OS changes needed | Summary |
|---|:-:|:-:|---|:-:|---|
| `edit` | `[█░░░░]` | 🔴 | 0 | 3 | vi-like modeless TUI editor. Repo scaffolded 2026-09-01; R71 milestone body pending. |
| `fetch` | `[█░░░░]` | 🔴 | 0 | 5 | HTTP GET client over TCP. Scaffold only; blocked on `libpdx-net`.M4 + kernel TLS crypto. |
| `line` | `[█░░░░]` | 🔴 | 0 | 2 | ed-style scriptable line editor. Scaffold only; R63 milestone body pending. |
| `pdxcurl` | `[█░░░░]` | 🔴 | 0 | 5 | Improved-curl CLI (cap-native, PQ-preferring). Blocked on `libpdx-net`.M3/M4 + `KIND_TLS_TRUST` + crypto intrinsics. |
| `pdxdig` | `[█░░░░]` | 🔴 | 0 | 2 | DNS query CLI. Blocked on `libpdx-net`.M2 + `SOCK_DGRAM` socket-family extension. |
| `pdxping` | `[█░░░░]` | 🔴 | 0 | 2 | ICMP echo CLI. Blocked on `sys_icmp_echo` (sysno 96) + `R_NET_PRIVILEGED_PROTOCOL` elevate class. |
| `pdxsock` | `[█░░░░]` | 🔴 | 0 | 1 | General TCP/UDP client + server (netcat-adjacent). TCP path buildable now; UDP mode gated on `SOCK_DGRAM`. |
| `pdxtrust` | `[█░░░░]` | 🔴 | 0 | 1 | Trust-anchor management CLI. Blocked on `KIND_TLS_TRUST` cap kind landing kernel-side. |
| `ping` | `[█░░░░]` | 🔴 | 0 | 2 | Legacy R80 ping tool. Scaffold only; superseded scope by `pdxping`; may be retired. |
| `remote` | `[█░░░░]` | 🔴 | 0 | 4 | Secure shell + remote copy with ML-KEM handshake. Scaffold only; blocked on `libpdx-net`.M3 + ML-KEM intrinsic. |
| `cat` | `[█████]` | 🟢 | 0 | 1 | File read/concatenate (schema-passthrough on semantic pipes). v1.0.0. R90-XREPO.013 caps.decl adoption open. |
| `cp` | `[█████]` | 🟢 | 0 | 1 | Copy with PdxFS undo record (I5 invariant). v1.0.0. R90-XREPO.013 open. |
| `doc` | `[█████]` | 🟢 | 0 | 1 | Documentation viewer (structured `.pdxdoc`, semantic-pipe emission). v1.0.0. Post-audit v0.5 wave has 3 open. |
| `ls` | `[█████]` | 🟢 | 0 | 2 | Directory listing (emits `PdxFsDirEntry[]` records). v1.0.0. R90-XREPO.012 + R90-XREPO.013 open. |
| `mkdir` | `[█████]` | 🟢 | 0 | 1 | Directory create. v1.0.0. R90-XREPO.013 caps.decl adoption open. |
| `mkfs.pdxfs` | `[█████]` | 🟢 | 0 | 0 | PdxFS-on-block volume formatter (PDXB superblock + WAL + root inode). r64v2-closed; 0 open. |
| `mount.pdxfs` | `[█████]` | 🟢 | 0 | 0 | Volume mount tool (`sys_mount` + `PdxFsMountRecord` audit). r64v2-closed; 0 open. |
| `mv` | `[█████]` | 🟢 | 0 | 1 | Move with PdxFS undo + destructive-op audit. v1.0.0. R90-XREPO.013 open. |
| `pkg` | `[█████]` | 🟢 | 0 | 1 | Package manager (dual-signed manifests, elevate-integrated). pkg-v1.0.0 tagged. R70 pending; R90-XREPO.013 open. |
| `rm` | `[█████]` | 🟢 | 0 | 1 | Remove with undo + destructive-op audit + elevate for system paths. v1.0.0. R90-XREPO.013 open. |
| `shell` | `[█████]` | 🟢 | 0 | 3 | Paideia shell (semantic-pipes aware, elevate-integrated). v1.0.0. v2.0 real-exec-substrate wave open (11 issues incl. ENH-032). |
| `umount.pdxfs` | `[█████]` | 🟢 | 0 | 0 | Volume unmount (`sys_umount` + WAL CLEAN checkpoint). r64v2-closed; 0 open. |

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
| `libpdx-net` | libpdx-url (net consumes url for HTTPS validation) | pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust, fetch, ping, remote, pkg (future) | `sys_socket` family (SC+ 87–94), `SOCK_DGRAM` extension (§12.1), `sys_icmp_echo` (§12.2, sysno 96), `KIND_TLS_TRUST` (§12.3), paideia-as TLS crypto intrinsics (SHA-256, HKDF, X25519, Ed25519) |
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

- **Volume tools** (`mkfs.pdxfs`, `mount.pdxfs`, `umount.pdxfs`) carry the `r64v2-closed` release tag rather than a `v1.0.0` version tag; the r64 v2 closure retrospective (`design/round-retrospectives/r64-closure-v2.md`) treats that tag as the equivalent signed release, so they score 🟢.
- **`libpdx-config`** has only 2 commits and no v1.0.0 tag; despite both R74 milestone issues being closed, the repo body is a scaffold. Scored 🔴 to reflect actual code state rather than milestone bookkeeping.
- **`ping`** (the R80-era tool) and **`pdxping`** (the R100 tool) coexist in the org; only the latter is on the R100 landing path. `ping` is likely to be retired but has not been formally deprecated in an issue.
- **`paideia-as`'s** `crypto-intrinsics-for-tls` milestone (1 open issue) is the single largest cross-repo escalation surface in the ecosystem today — its resolution unblocks `libpdx-net`.M3, which in turn unblocks the entire R100 network-tools wave (5 tool repos + `fetch`/`remote`/`ping`).

---

*Refresh: send the `ECOTABLE` command to Claude Code in this project to rebuild.*
