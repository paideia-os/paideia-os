# PaideiaOS Ecosystem Status

**Snapshot:** 2026-09-02.
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

**OS changes needed** is the count of *open* issues in the `paideia-os/paideia-os` monorepo that this satellite requires before it can finish its own open milestones. It is derived by grepping this satellite's open issues for `Blocked by paideia-os/paideia-os#NNNN` cross-references and counting distinct kernel-side dependencies. A value of 0 means the satellite is not currently gated on any monorepo change. **As of this snapshot the monorepo carries 0 open issues** — the retransmit-loopback fast-path (`#2221`) landed at 13:08 UTC, and the three volume-cap follow-ups (`#2223` `KIND_VOLUME_SNAPSHOT`, `#2224` `KIND_KEK`, `#2225` `sys_volume_mint` at sysno 114) landed at 14:10 UTC. Every "OS changes needed" column therefore reads 0 in this refresh.

**Dependent repos** is the count of other satellites in the org whose issues, plans, or design docs reference this repo as a build-time or run-time dependency. Where the count is small (≤5), the dependents are listed inline; otherwise only the count is shown to keep the table readable.

Library maturity scores are inherited from `design/library-status.md` (this repo's canonical library tracker, which is refreshed by a different pass and stays independently maintained). Tool maturity scores are computed here from a fresh audit — commit count, release tags, per-milestone `open:closed` ratio, presence of `caps.decl`, and whether any downstream design doc treats the tool as landed.

---

## Table 1 — Libraries

| Repo | Maturity | Status | Dependent repos | OS changes needed | Summary |
|---|:-:|:-:|---|:-:|---|
| [`libpdx-net`](https://github.com/paideia-os/libpdx-net) | `[█░░░░]` | 🔴 | 9 (pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust, fetch, ping, remote, pkg) | 0 | TCP/UDP wrappers, DNS resolver, TLS 1.3 raw-pubkey client, HTTP/1.1 client. Blocks the entire R100 network-tools wave. Scaffold-only (2 commits, 22 open across M1..M5); paideia-as v0.28.1 crypto substrate now complete (mldsa65_sign + mldsa65_verify + Ed25519 + X25519 + HMAC/HKDF + SHA-256). |
| [`libpdx-font`](https://github.com/paideia-os/libpdx-font) | `[█░░░░]` | 🔴 | 6 (libpdx-gfx, svc-wm, pdxterm, pdxclock, pdxwatch, pdxpaint) | 0 | Bitmap glyph store + text metrics (8x16 v1, matches kernel `fb_font`). R102 CPU-side text stack; emits `FontMetricsRecord@0.1`. Scaffold-only (2 commits, 11 open across M1..M5). |
| [`libpdx-gfx`](https://github.com/paideia-os/libpdx-gfx) | `[█░░░░]` | 🔴 | 6 (svc-compositor, svc-wm, pdxterm, pdxclock, pdxwatch, pdxpaint) | 0 | CPU-side BGRA8888 graphics primitives (rect, blit, line, glyph) into a `KIND_SURFACE`-backed pixel buffer. Compositor commit + damage tracking. Scaffold-only (2 commits, 13 open across M1..M5). |
| [`postui`](https://github.com/paideia-os/postui) | `[█░░░░]` | 🔴 | 6 (postui-dmesg, postui-hex, postui-top, shell, edit, doc) | 0 | Ratatui-inspired TUI library, cap-based, semantically-queryable, `KIND_TUI_CANVAS` backend. 40 open across postui.M1..M5. Blocks all three postui reference apps and the shell/edit/doc TUI layer. |
| [`libpdx-url`](https://github.com/paideia-os/libpdx-url) | `[█░░░░]` | 🔴 | 5 (libpdx-net, pdxcurl, pkg, fetch, remote) | 0 | RFC 3986 URL parser + validator (http/https only, no embedded credentials). Pure userspace; scaffold-only (2 commits, 11 open across M1..M5). |
| [`libpdx-event`](https://github.com/paideia-os/libpdx-event) | `[█░░░░]` | 🔴 | 4 (svc-wm, pdxterm, pdxwatch, pdxpaint) | 0 | Client-side input event routing (subscribe to input events on a window handle). Emits `InputEventRecord@0.1`. Scaffold-only (2 commits, 11 open across M1..M5). |
| [`libpdx-config`](https://github.com/paideia-os/libpdx-config) | `[█░░░░]` | 🔴 | 3 (pkg, shell, pdxtrust) | 0 | `/etc` key=value config parser. Only 2 commits; R74 milestone bookkeeping-closed but repo body is a scaffold. |
| [`libpdx-cap`](https://github.com/paideia-os/libpdx-cap) | `[████░]` | 🟡 | 30 (every tool + libpdx-audit + libpdx-elevate) | 0 | Capability marshalling. `v1.0.1` tagged 2026-09-01 (ENH-008 caller-owned re-entrant variants). 1 open (`#20`), externally blocked on `shell.ENH-032`. |
| [`libpdx-argv`](https://github.com/paideia-os/libpdx-argv) | `[███░░]` | 🟡 | 26 (every CLI tool) | 0 | CLI arg parsing (text + semantic-schema invocation). `v1.0.0` tagged; Enhancement v1.1 wave carries 11 open (2 original + 9 additional). |
| [`libpdx-audit`](https://github.com/paideia-os/libpdx-audit) | `[███░░]` | 🟡 | 10 (rm, mv, cp, mkfs.pdxfs, mount.pdxfs, umount.pdxfs, pkg, pdxtrust, pdxcurl, pdxping) | 0 | Audit-first emit to `/system/audit/*.log` (I5 invariant). `v1.0.0` tagged; 0 open. |
| [`libpdx-schema-registry`](https://github.com/paideia-os/libpdx-schema-registry) | `[████░]` | 🟡 | 10 (libpdx-semantic-pipe, ls, cat, doc, pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust, pkg) | 0 | Schema registry client-facade. 12 commits, 0 open. M1..M4 all closed 2026-09-01; M5 signed release deferred (FNV-1a-64 hash placeholder pending BLAKE3 intrinsic). |
| [`libpdx-elevate`](https://github.com/paideia-os/libpdx-elevate) | `[████░]` | 🟡 | 8 (rm, mkfs.pdxfs, mount.pdxfs, umount.pdxfs, pkg, pdxtrust, pdxping, pdxcurl) | 0 | Client-side elevate protocol helper. `v1.0.0` tagged. Cascade fully closed 2026-09-01 (`3e54a8e`); kernel broker at `2225b18`. 0 open. |
| [`libpdx-volume`](https://github.com/paideia-os/libpdx-volume) | `[████░]` | 🟡 | 3 (mkfs.pdxfs, mount.pdxfs, umount.pdxfs) | 0 | `KIND_VOLUME` helpers + PDXB codec + mount_table. **`v1.1.1`** tagged 2026-09-02 (v1.1.0 landed 16 primary tickets `#16-#31` closing LV.M1-polish through LV.M6-multivol-ordering; v1.1.1 patched `#32`+`#33`). 0 open on-repo; 7 downstream adoption tickets outstanding across the three volume tools. |
| [`paideia-as`](https://github.com/paideia-os/paideia-as) | `[█████]` | 🟢 | 42 (every other satellite in the org) | 0 | Assembler compiler (Rust, self-hosted target). **`v0.28.1`** tagged 2026-09-02 (mldsa65_verify intrinsic, `#1347`). Full TLS 1.3 crypto substrate now shipped: SHA-256, HMAC/HKDF, X25519, Ed25519, MLDSA65 sign + verify. 1 open (`#1346` ECDSA-P256 classical bridge, no milestone). |
| [`libpdx-semantic-pipe`](https://github.com/paideia-os/libpdx-semantic-pipe) | `[█████]` | 🟢 | 17 (postui + shell + every schema-emitting tool) | 0 | Schema-typed pipe endpoints over `KIND_IPC_ENDPOINT`. `v1.0.0` tagged. 6 open across the v2.0 adoption-unblock wave + R90-XREPO.012 `bind_by_name` real path. |

---

## Table 2 — Tools

| Repo | Maturity | Status | Dependent repos | OS changes needed | Summary |
|---|:-:|:-:|---|:-:|---|
| [`svc-compositor`](https://github.com/paideia-os/svc-compositor) | `[█░░░░]` | 🔴 | 5 (svc-wm, pdxterm, pdxclock, pdxwatch, pdxpaint) | 0 | The compositor. Sole holder of the `KIND_FB_SCANOUT` cap; window table, 60 Hz render loop, input pump, screenshot query. Scaffold-only (2 commits, 16 open across M1..M5); R101–R105 kernel wave landed. |
| [`svc-wm`](https://github.com/paideia-os/svc-wm) | `[█░░░░]` | 🔴 | 4 (pdxterm, pdxclock, pdxwatch, pdxpaint) | 0 | Window manager (separate process from svc-compositor). Tiling policy, focus, keyboard shortcuts, `KIND_INPUT_FOCUS` mint. Scaffold-only (2 commits, 12 open across M1..M5). |
| [`edit`](https://github.com/paideia-os/edit) | `[█░░░░]` | 🔴 | 0 | 0 | vi-like modeless TUI editor. Scaffold (1 commit, 7 open); R71 milestone gated on postui. |
| [`fetch`](https://github.com/paideia-os/fetch) | `[█░░░░]` | 🔴 | 0 | 0 | HTTP GET client over TCP. Scaffold (1 commit, 3 open); blocked on `libpdx-net`.M4. Kernel TCP loopback path unblocked (`#2221` closed 2026-09-02). |
| [`line`](https://github.com/paideia-os/line) | `[█░░░░]` | 🔴 | 0 | 0 | ed-style scriptable line editor. Scaffold (1 commit, 7 open); R63 milestone open. |
| [`pdxclock`](https://github.com/paideia-os/pdxclock) | `[█░░░░]` | 🔴 | 0 | 0 | Reference clock (smallest useful window app). 128x48 HH:MM:SS window updating once per second. Scaffold-only (2 commits, 7 open); R102 reference app. |
| [`pdxcurl`](https://github.com/paideia-os/pdxcurl) | `[█░░░░]` | 🔴 | 0 | 0 | Improved-curl CLI (cap-native, PQ-preferring, audit-first). Scaffold (2 commits, 19 open across M1..M5); blocked on `libpdx-net`.M3/M4 + `KIND_TLS_TRUST`. Kernel TCP path unblocked. |
| [`pdxdig`](https://github.com/paideia-os/pdxdig) | `[█░░░░]` | 🔴 | 0 | 0 | DNS query CLI (A-record only at v1; `--type`/`--server` overrides). Scaffold (2 commits, 15 open); blocked on `libpdx-net`.M2 + `SOCK_DGRAM` socket-family extension. |
| [`pdxpaint`](https://github.com/paideia-os/pdxpaint) | `[█░░░░]` | 🔴 | 0 | 0 | Reference paint app (pointer routing, drag events, full-surface persistent state). Scaffold-only (2 commits, 10 open); R102 reference app. |
| [`pdxping`](https://github.com/paideia-os/pdxping) | `[█░░░░]` | 🔴 | 0 | 0 | ICMP echo CLI. Scaffold (2 commits, 13 open); blocked on `sys_icmp_echo` (sysno 96) + `R_NET_PRIVILEGED_PROTOCOL` elevate class. |
| [`pdxsock`](https://github.com/paideia-os/pdxsock) | `[█░░░░]` | 🔴 | 0 | 0 | General TCP/UDP client + server (netcat-adjacent). Scaffold (2 commits, 14 open); TCP path buildable now (post-`#2221` close); UDP mode gated on `SOCK_DGRAM`. |
| [`pdxterm`](https://github.com/paideia-os/pdxterm) | `[█░░░░]` | 🔴 | 0 | 0 | Framebuffer terminal emulator; graphical alternative to the UART TTY. Spawns `/bin/shell` over `KIND_PTY`. Scaffold-only (2 commits, 12 open); R102 reference app. |
| [`pdxtrust`](https://github.com/paideia-os/pdxtrust) | `[█░░░░]` | 🔴 | 0 | 0 | Trust-anchor management CLI (mints `KIND_TLS_TRUST` caps from `.pubkey` files, Ed25519 v1). Scaffold (2 commits, 15 open); blocked on `KIND_TLS_TRUST` cap kind landing kernel-side. |
| [`pdxwatch`](https://github.com/paideia-os/pdxwatch) | `[█░░░░]` | 🔴 | 0 | 0 | System-monitor GUI (graphical peer of `postui-top`): CPU bar-per-core, memory tri-color, network sparkline. Scaffold-only (2 commits, 10 open); R102 reference app. |
| [`ping`](https://github.com/paideia-os/ping) | `[█░░░░]` | 🔴 | 0 | 0 | Legacy R80 ping tool. 1 commit, 3 open; superseded by `pdxping` — likely to be retired. |
| [`remote`](https://github.com/paideia-os/remote) | `[█░░░░]` | 🔴 | 0 | 0 | Secure shell + remote copy with ML-KEM handshake. Scaffold (1 commit, 7 open); blocked on `libpdx-net`.M3. Kernel TCP path unblocked. |
| [`cat`](https://github.com/paideia-os/cat) | `[█████]` | 🟢 | 0 | 0 | File read/concatenate (schema-passthrough on semantic pipes). `v1.0.0`. 7 open (Enhancement v1.x + R90-XREPO.013 `caps.decl`). |
| [`cp`](https://github.com/paideia-os/cp) | `[█████]` | 🟢 | 0 | 0 | Copy with PdxFS undo record (I5 invariant). `v1.0.0`; M5 closed. 4 open (Enhancement v1.1 + R90-XREPO.013). |
| [`doc`](https://github.com/paideia-os/doc) | `[█████]` | 🟢 | 0 | 0 | Documentation viewer (structured `.pdxdoc`, semantic-pipe emission). `v1.0.0`. 10 open (R79 + v0.5 post-audit reset + R90-XREPO.013). |
| [`ls`](https://github.com/paideia-os/ls) | `[█████]` | 🟢 | 0 | 0 | Directory listing (emits `PdxFsDirEntry[]` records). `v1.0.0`; M5 closed. 36 commits, 20 open (9 ENH-wave + R90-XREPO.012/013). |
| [`mkdir`](https://github.com/paideia-os/mkdir) | `[█████]` | 🟢 | 0 | 0 | Directory create. `v1.0.0`. 38 commits, 4 open (Enhancement v1.x + R90-XREPO.013). |
| [`mkfs.pdxfs`](https://github.com/paideia-os/mkfs.pdxfs) | `[█████]` | 🟢 | 0 | 0 | PdxFS-on-block volume formatter (PDXB superblock + WAL + bitmap + root inode). `r64v2-closed`; 3 open (R90-XREPO.013 `caps.decl` + libpdx-volume v1.1 accessor adoption + LV.M4 `--quota`/LV.M5 `--encrypt` flags). |
| [`mount.pdxfs`](https://github.com/paideia-os/mount.pdxfs) | `[█████]` | 🟢 | 0 | 0 | Volume mount tool (`sys_mount` + `PdxFsMountRecord` audit). `r64v2-closed`; 5 open (R90-XREPO.013 `caps.decl` + libpdx-volume v1.1 accessor adoption + LV.M2-003 elevate-cap wire-through + LV.M3 `--snapshot` + LV.M4 quota / LV.M5 `--passphrase-fd` / LV.M6 dep-graph refusal). |
| [`mv`](https://github.com/paideia-os/mv) | `[█████]` | 🟢 | 0 | 0 | Move with PdxFS undo + destructive-op audit. `v1.0.0`. 7 open (Enhancement v1.x + R90-XREPO.013). |
| [`pkg`](https://github.com/paideia-os/pkg) | `[█████]` | 🟢 | 0 | 0 | Package manager (dual-signed manifests, elevate-integrated). `pkg-v1.0.0`; 34 commits, 15 open (R70 MVP + Enhancement v1.x + R90-XREPO.013). Mirror path now buildable (post-`#2221` close). |
| [`rm`](https://github.com/paideia-os/rm) | `[█████]` | 🟢 | 0 | 0 | Remove with undo + destructive-op audit + elevate for system paths. `v1.0.0`. 7 open (Enhancement v1.x + R90-XREPO.013). |
| [`shell`](https://github.com/paideia-os/shell) | `[█████]` | 🟢 | 0 | 0 | Paideia shell (semantic-pipes aware, elevate-integrated). `v1.0.0`. 23 open (R66 polish + R73 tier-2 + v2.0 real-exec-substrate + R90-XREPO.013). |
| [`umount.pdxfs`](https://github.com/paideia-os/umount.pdxfs) | `[█████]` | 🟢 | 0 | 0 | Volume unmount (`sys_umount` + WAL CLEAN checkpoint). `r64v2-closed`; 2 open (R90-XREPO.013 `caps.decl` + libpdx-volume v1.1 accessor adoption). |

Reference apps (`postui-dmesg`, `postui-hex`, `postui-top`) and the umbrella `paideia-os` monorepo are intentionally omitted per the classification rule.

---

## Table 3 — Dependency-impact matrix

For each library, what breaks (or needs re-verification) on a breaking or minor-behavior-change release.

| Updated repo | Downstream libraries | Downstream tools | Kernel-side hits |
|---|---|---|---|
| `libpdx-argv` | (none directly) | cat, cp, doc, edit, fetch, line, ls, mkdir, mkfs.pdxfs, mount.pdxfs, mv, pdxclock, pdxcurl, pdxdig, pdxpaint, pdxping, pdxsock, pdxterm, pdxtrust, pdxwatch, ping, pkg, remote, rm, shell, umount.pdxfs | 0 |
| `libpdx-audit` | libpdx-elevate (audit on elevate events), libpdx-volume (mount records) | rm, mv, cp, mkfs.pdxfs, mount.pdxfs, umount.pdxfs, pkg, pdxtrust, pdxcurl, pdxping | 0 |
| `libpdx-cap` | libpdx-audit, libpdx-elevate, libpdx-semantic-pipe | every tool (all 28) | 0 |
| `libpdx-config` | (none directly) | pkg (mirror list), shell (rc), pdxtrust (system trust dir) | 0 |
| `libpdx-elevate` | libpdx-audit (audit on elevate events) | rm, mkfs.pdxfs, mount.pdxfs, umount.pdxfs, pkg, pdxtrust, pdxping, pdxcurl | 0 |
| `libpdx-event` | (none directly) | svc-wm, pdxterm, pdxwatch, pdxpaint | 0 |
| `libpdx-font` | libpdx-gfx (glyph blit) | svc-wm, pdxterm, pdxclock, pdxwatch, pdxpaint | 0 |
| `libpdx-gfx` | (none directly) | svc-compositor, svc-wm, pdxterm, pdxclock, pdxwatch, pdxpaint | 0 |
| `libpdx-net` | libpdx-url (net consumes url for HTTPS validation) | pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust, fetch, ping, remote, pkg (future) | 0 |
| `libpdx-schema-registry` | libpdx-semantic-pipe (`bind_by_name` real path) | ls, cat, doc, pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust, pkg (future emitters) | 0 |
| `libpdx-semantic-pipe` | postui (TUI widget emissions), libpdx-schema-registry (co-dep on bind path) | shell, ls, cat, doc, mv, cp, rm, mkfs.pdxfs, mount.pdxfs, umount.pdxfs, pkg, pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust | 0 |
| `libpdx-url` | libpdx-net (HTTPS URL parsing) | pdxcurl, pkg, fetch, remote | 0 |
| `libpdx-volume` | (none directly) | mkfs.pdxfs, mount.pdxfs, umount.pdxfs | 0 |
| `paideia-as` | libpdx-argv, libpdx-audit, libpdx-cap, libpdx-config, libpdx-elevate, libpdx-event, libpdx-font, libpdx-gfx, libpdx-net, libpdx-schema-registry, libpdx-semantic-pipe, libpdx-url, libpdx-volume, postui | every tool (all 28) | 0 |
| `postui` | (none directly) | postui-dmesg, postui-hex, postui-top, shell (TUI layer), edit, doc | 0 |

### Reading the matrix

- **Row scope.** A row's downstream cells list every satellite that would need at least a re-verify pass on a minor-behavior release of the updated repo. A *breaking* release additionally forces every downstream to bump its submodule pin and re-run its own M4 smoke.
- **Kernel-side hits.** A library update forces a monorepo change when the library's ABI touches a kernel-owned surface — a `KIND_*` dispatch table, a syscall number, a daemon name, an audit record shape. With the monorepo at exactly **0 open issues** as of this snapshot, every row scores 0. All previously-open R91–R99 (networking) and R101–R105 (GUI) kernel work has landed under `net-wave-closed` and `gui-wave-closed`; the volume-cap follow-ups (`#2223` `KIND_VOLUME_SNAPSHOT` at `0x1B3`, `#2224` `KIND_KEK` at `0x1B4`, `#2225` `sys_volume_mint` at sysno 114) closed alongside the retransmit-loopback fix `#2221` on 2026-09-02.
- **Transitive.** These are direct dependencies only. `libpdx-cap` transitively touches every kernel surface via the downstream tools, but the matrix records only the surfaces `libpdx-cap` itself binds against.

---

## Notes on this snapshot

- **The monorepo is at 0 open.** `#2221` (retransmit-loopback fast-path — RX fingerprint, TCB zombies, witness leaks) landed at 13:08 UTC. `#2223`/`#2224`/`#2225` (the libpdx-volume v1.1 kernel cascade: `KIND_VOLUME_SNAPSHOT` at cap-kind `0x1B3`, `KIND_KEK` at `0x1B4`, `sys_volume_mint` at sysno 114) landed at 14:10 UTC. This is the second time the monorepo has hit zero-open in R100-era history.
- **paideia-as reached v0.28.1** on 2026-09-02: v0.28.0 shipped mldsa65_sign and closed the umbrella `#1336`; v0.28.1 (`#1347`) adds mldsa65_verify to the `MlDsa65` trait, completing the ML-DSA-65 sign+verify pair. The TLS 1.3 crypto substrate is now fully assembled for `libpdx-net`: SHA-256, HMAC/HKDF, X25519, Ed25519, MLDSA65 sign+verify. 1 open (`#1346` ECDSA-P256 classical bridge, no milestone).
- **libpdx-volume shipped v1.1.1** on 2026-09-02. v1.1.0 (16 primary tickets `#16-#31`) closed six new milestones — **LV.M1-polish**, **LV.M2-hardening**, **LV.M3-snapshots**, **LV.M4-quotas**, **LV.M5-encryption**, **LV.M6-multivol-ordering** — plus filed four external follow-ups (`paideia-as#1347`, `paideia-os#2223/#2224/#2225`, all now closed). v1.1.1 patched `#32`+`#33`. Repo is 0-open; the library moves 3 → 4 🟡 to reflect the v1.1 API cleanup (accessors + `lpv_strerror` + public consts) + snapshot/quota/encryption/dep-graph surfaces, held below 🟢 because the three downstream volume tools haven't yet adopted the v1.1 surface.
- **Volume-tool cascade (7 open).** The v1.1.0 audit filed adoption tickets against `mkfs.pdxfs` (+2 → 3 open), `mount.pdxfs` (+4 → 5 open), and `umount.pdxfs` (+1 → 2 open) covering (a) libpdx-volume v1.1 accessor adoption, (b) LV.M2-003 elevate-cap wire-through, (c) LV.M3 `--snapshot=<snap-cap>` read-only mount, and (d) LV.M4 quota + LV.M5 `--encrypt`/`--passphrase-fd` + LV.M6 dep-graph refusal. All three tools retain their `r64v2-closed` 🟢 baseline.
- **Nine R102 GUI-cluster scaffolds** (`libpdx-font`, `libpdx-gfx`, `libpdx-event`, `svc-compositor`, `svc-wm`, `pdxterm`, `pdxclock`, `pdxwatch`, `pdxpaint`) remain at 2 commits + LICENSE + README + M1..M5 open. None are gated on the monorepo — the R101–R105 kernel work has landed. The 116 open issues across those nine repos are the sole remaining path to a working PaideiaOS GUI stack. Recommended investment order: `libpdx-net` (unblocks R100 network-tools wave) → R102 GUI cluster.
- **libpdx-elevate** completed its M4 cascade (satellite `3e54a8e`; kernel broker `2225b18`), moving 3 → 4 🟡. Zero open issues; awaiting only the M5 signed release.
- **libpdx-schema-registry** shipped M1..M4 in a single-day sweep (12 commits, `be0ae09` → `020e697`), 1 → 4 🟡. FNV-1a-64 hash placeholder held pending a paideia-as BLAKE3 intrinsic.
- **libpdx-cap** cut `v1.0.1` (ENH-008 additive re-entrant variants at `f472530`), 3 → 4 🟡. `#20` remains open, externally blocked on `shell.ENH-032`.
- **`libpdx-config`** has only 2 commits and no `v1.0.0` tag; despite both R74 milestone issues being closed, the repo body is a scaffold. Scored 🔴 to reflect actual code state rather than milestone bookkeeping.
- **`ping`** (R80-era) and **`pdxping`** (R100) coexist in the org; only the latter is on the R100 landing path. `ping` is likely to be retired but has not been formally deprecated in an issue.
- **`libpdx-net`** remains the single largest cross-repo escalation surface. With the paideia-as v0.28.1 crypto substrate complete and the monorepo at 0 open, its 22 M1..M5 issues are the last blocker for `pdxcurl`, `pdxdig`, `pdxping`, `pdxsock`, `pdxtrust`, `fetch`, `ping`, `remote`, and the `pkg` mirror path.
- **`paideia-os` monorepo** is deliberately excluded from Tables 1 and 2 per the classification rule. With no open kernel issues, every satellite's "OS changes needed" column reads 0 and every Table 3 "Kernel-side hits" cell reads 0 in this refresh.

---

*Refresh: send the `ECOTABLE` command to Claude Code in this project to rebuild.*
