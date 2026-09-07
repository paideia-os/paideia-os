# PaideiaOS Ecosystem Status

**Snapshot:** 2026-09-07 (fourth refresh — paideia-as v0.34.0/v0.35.0 god-file phase 1 + postui v1.0.0 satellite drain + kernel klog fix + sys_semantic_send @115 + KIND_TUI_CANVAS live).
**Refresh command:** `ECOTABLE` — issued to Claude Code in this project, rebuilds the tables end-to-end from a fresh `gh` audit of the `paideia-os` org.

This document is a cross-repo readiness map: every library and every tool in the `paideia-os` GitHub org, scored on the same 5-segment maturity scale, sorted so the highest-blast-radius under-built repos surface first.

## Recent session activity (since the 2026-09-06 snapshot)

- **postui hit `v1.0.0` and drained all three reference-app satellites.** postui itself tagged `postui-v1.0.0` (Ratatui-inspired, full widget parity, 24-bit truecolor, `KIND_TUI_CANVAS` render backend). Three consumer apps landed clean issue drains:
  - **postui-hex `#7`+`#8`** closed in one commit (`b6c961c`): `view_hexdump` OOB defense against `fileio_read` writing `-errno` into `buffer_len` (info-disclosure vector), plus `caps.decl` consistency pass.
  - **postui-dmesg `#8`** closed (`932f3c1`): `view_tabs` relabeled `Emerg`→`Panic`, `view_tabs_match` rewritten against real kernel `LEVEL_*` integers (0=PANIC, 1=ERROR, 2=WARN, 3=INFO) rather than fabricated syslog priorities.
  - **postui-top `#8`** closed (`4ebaf35`) with a debugger-catch follow-up (`e8d5379`): `view_sparkline` clamps `value_count` on `Rect.w`-derived `bw`, not on `cols` — the debugger caught that the original Phase B fix would have silently reintroduced the same stale-display defect for any future caller passing a sub-rect narrower than full canvas.
- **paideia-as jumped v0.33.1 → v0.34.0 → v0.35.0** in two back-to-back releases:
  - **v0.34.0**: unsigned `mul reg64` mnemonic (`1bf149b`, closes `#1398`) — full-128-bit `rdx:rax = rax * reg` product. postui immediately consumed it in `fx_mul`/`fx_scale` (`fd94bf8`, closes `postui#43`), swapping the prior truncating `imul rax, rcx; shr rax, 32` (|A|·|B|<1.0 restricted) for the real full-product `mul rcx; shr rax, 32; shl rdx, 32; or rax, rdx` path (bits [32..96)).
  - **v0.35.0** (`9ff3ee9`): **god-file refactor phase 1** landed as a coordinated batch — `stdlib_lowering.rs`, `cmd_build.rs`, `instruction.rs` → mod dirs (`6f6316a`, closes `#1400`/`#1401`/`#1402`), `unsafe_walker.rs` → mod dir (`0571aa1`, closes `#1403`), `emit_lambda.rs` → mod dir (`af85f90`, closes `#1404`). Internal Rust refactor only; no `.pdx`-visible ABI change.
  - Also this session: **ECDSA-P256 sign+verify intrinsic** (`8be5d56`, closes `#1346`) closes out the classical bridge that had carried across the last three snapshots; **effect-row inference at call sites** (`7bf8935` + `fb921c2`, v0.25.M2 followups); retrospective release notes for v0.25 + v0.26..v0.32 + v0.33 (`b73cde1`, `1985642`, `89a293a`).
- **paideia-as god-file refactor phase 2 is in flight (Wave X).** Phase 2 covers `encode.rs`, `parse_primary`, `let_item`, `emit_enum_match`, `emit_block_body`, `emit_walker`, `term_eval`. First landing is already in origin/main: `let_item.rs` → mod dir (`a7fe1a5`, closes `#1408`). The other six are staged/scheduled but not yet cut into a tag. Marked **WIP** — expect a v0.36.x cut when phase 2 closes.
- **Wave Y follow-up drain** (this session): the six-way cross-repo close-out that swept postui + its three consumers to zero-or-near-zero open, plus a monorepo kernel klog fix. Net: postui satellite class dropped from a combined 4+ open issues to (`postui`: 1, `postui-top`: 0, `postui-dmesg`: 1, `postui-hex`: 1) — the remaining opens are all newly-filed forward-looking tickets, not carried-over debt.
- **Kernel klog reader corrected**: `paideia-os#2351` (`0fc0e2d`) — `klog_ring_read_tail` now returns the newest-N bytes rather than the oldest live-window slice. Load-bearing for `postui-dmesg`'s tail viewer; the fix is transparent to every other consumer.
- **New R107 wave kernel work** landed in the monorepo:
  - `sys_semantic_send` syscall at **sysno 115** (`71a15fb`, closes `#2350`, R107-M0-001) — kernel-facing schema-typed emit primitive; the natural client wrapper is `libpdx-semantic-pipe`.
  - `sys_mount` `SM_BACKEND_PDXFS_BLOCK` real body (`916b5e2`, R107.M1) — the file-bdev mount body that the prior snapshot's `#2345` had escalated forward.
- **ls drained 7 → 2 open** since the last snapshot: `caps.decl`, schema-hash migration, cwd-relative resolve, real owner row, single/multi-path listing all closed; only `#39` (total-line semantic record) and `#35` (full `-R` recursion) remain.
- **paideia-os monorepo moved 2 → 4 open**: closed `#2345`; opened `#2347` (shell-shutdown.golden fingerprint ordering defect at line 168), `#2348` (`libpdx-volume` 7 undefined symbols block r64v2-tools link post-`#2346`), `#2349` (TB TRUSTED DEVICE OK fingerprint not firing in current boot, blocks `#2347`). `#2341` (R106 shell satellite M1) carries over. None of the four are library-ABI-forced kernel changes; every Table 3 "OS changes needed" cell still reads 0.

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

**OS changes needed** is the count of *open* issues in the `paideia-os/paideia-os` monorepo that this satellite requires before it can finish its own open milestones. The monorepo carries **4 open issues** (`#2341`, `#2347`, `#2348`, `#2349`), none of which force an ABI-visible kernel change any satellite is gated on, so every column below still reads 0.

**Dependent repos** counts other satellites in the org whose issues, plans, or design docs reference this repo as a build-time or run-time dependency. Where the count is small (≤5), the dependents are listed inline; otherwise only the count is shown.

Library maturity scores are inherited from `design/library-status.md`; tool scores are computed here from a fresh audit (commit count, release tags, per-milestone `open:closed` ratio, `caps.decl` presence, downstream design-doc treatment), weighed against actual code-body evidence.

---

## Table 1 — Libraries

| Repo | Maturity | Status | Dependent repos | OS changes needed | Summary |
|---|:-:|:-:|---|:-:|---|
| [`libpdx-net`](https://github.com/paideia-os/libpdx-net) | `[█░░░░]` | 🔴 | 9 (pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust, fetch, ping, remote, pkg) | 0 | TCP/UDP wrappers, DNS resolver, TLS 1.3 raw-pubkey client, HTTP/1.1 client. Blocks the entire R100 network-tools wave. Scaffold-only (2 commits, 22 open across M1..M5, unchanged); crypto substrate now covers MLDSA65 (FIPS 204) + ML-KEM-768 (FIPS 203) + ECDSA-P256 (v0.35 close-out). |
| [`libpdx-font`](https://github.com/paideia-os/libpdx-font) | `[█░░░░]` | 🔴 | 6 (libpdx-gfx, svc-wm, pdxterm, pdxclock, pdxwatch, pdxpaint) | 0 | Bitmap glyph store + text metrics (8x16 v1, matches kernel `fb_font`). R102 CPU-side text stack; emits `FontMetricsRecord@0.1`. Scaffold-only (2 commits, 11 open, unchanged). |
| [`libpdx-gfx`](https://github.com/paideia-os/libpdx-gfx) | `[█░░░░]` | 🔴 | 6 (svc-compositor, svc-wm, pdxterm, pdxclock, pdxwatch, pdxpaint) | 0 | CPU-side BGRA8888 graphics primitives into `KIND_SURFACE`-backed pixel buffer. Compositor commit + damage tracking. Scaffold-only (2 commits, 13 open, unchanged). |
| [`libpdx-url`](https://github.com/paideia-os/libpdx-url) | `[█░░░░]` | 🔴 | 5 (libpdx-net, pdxcurl, pkg, fetch, remote) | 0 | RFC 3986 URL parser + validator (http/https only, no embedded credentials). Pure userspace; scaffold-only (2 commits, 11 open, unchanged). |
| [`libpdx-event`](https://github.com/paideia-os/libpdx-event) | `[█░░░░]` | 🔴 | 4 (svc-wm, pdxterm, pdxwatch, pdxpaint) | 0 | Client-side input event routing (subscribe to input events on a window handle). Emits `InputEventRecord@0.1`. Scaffold-only (2 commits, 11 open, unchanged). |
| [`libpdx-config`](https://github.com/paideia-os/libpdx-config) | `[█░░░░]` | 🔴 | 3 (pkg, shell, pdxtrust) | 0 | `/etc` key=value config parser. 2 commits; R74 milestone bookkeeping-closed but repo body is a scaffold. 0 open. |
| [`libpdx-cap`](https://github.com/paideia-os/libpdx-cap) | `[████░]` | 🟡 | 30 (every tool + libpdx-audit + libpdx-elevate) | 0 | Capability marshalling. `v1.0.1`. 1 open (`#20`, exec-time reconciliation client helper) — unblocked, awaiting implementation. |
| [`libpdx-argv`](https://github.com/paideia-os/libpdx-argv) | `[████░]` | 🟡 | 26 (every CLI tool; 9 real consumers today) | 0 | CLI arg parsing (text + semantic-schema invocation). **v1.1.0**, 14 open (unchanged). |
| [`libpdx-audit`](https://github.com/paideia-os/libpdx-audit) | `[████░]` | 🟡 | 10 (rm, mv, cp, mkfs.pdxfs, mount.pdxfs, umount.pdxfs, pkg, pdxtrust, pdxcurl, pdxping) | 0 | Audit-first emit to `/system/audit/*.log`. **v1.1.1**; 1 open — `#31` `audit_append_leaf` (`!{mem}`-only leaf primitive requested by `libpdx-elevate` LE.M2-002 to avoid propagating `sysreg`/`sched` effects downstream). Same load-bearing cross-repo block as prior snapshot. |
| [`libpdx-schema-registry`](https://github.com/paideia-os/libpdx-schema-registry) | `[████░]` | 🟡 | 10 | 0 | Schema registry client-facade. 12 commits, 0 open, unchanged. FNV-1a-64 hash placeholder pending `paideia-as#1392` BLAKE3 intrinsic. |
| [`libpdx-elevate`](https://github.com/paideia-os/libpdx-elevate) | `[████░]` | 🟡 | 8 (rm, mkfs.pdxfs, mount.pdxfs, umount.pdxfs, pkg, pdxtrust, pdxping, pdxcurl) | 0 | Client-side elevate protocol helper. **v1.1.2**, 12 → 13 open (one new follow-up ticket this session). Remaining load-bearing: LE.M2 real-audit-swap (`#38`, **blocked on `libpdx-audit#31`**), LE.M4 duration-ceilings/reap, LE.M6 signed audit sink (blocked transitively on same primitive), LE.M1 leftovers. |
| [`libpdx-volume`](https://github.com/paideia-os/libpdx-volume) | `[████░]` | 🟡 | 3 (mkfs.pdxfs, mount.pdxfs, umount.pdxfs) | 0 | `KIND_VOLUME` helpers + PDXB codec + mount_table. **v1.1.5**, 0 open. Note: monorepo-side `#2348` reports 7 undefined symbols from this library blocking r64v2-tools link — a build-glue mismatch, not a library defect. |
| [`postui`](https://github.com/paideia-os/postui) | `[█████]` | 🟢 | 6 (postui-dmesg, postui-hex, postui-top, shell, edit, doc) | 0 | Ratatui-inspired TUI library, cap-based, semantically-queryable, `KIND_TUI_CANVAS` render backend. **`postui-v1.0.0` tagged this session** — full widget parity, 24-bit truecolor. Consumed `paideia-as` v0.34.0 `mul reg64` in `fx_mul` (`fd94bf8`, closes `#43`). 1 open (`#41`, `tcc_resize`/`clear`/`debug_print` extra-arg shuffle silently dropped by frozen 2-arg `sys_cap_invoke` ABI — kernel-side follow-up, not a library defect). **Maturity moved 🔴 → 🟢 this refresh.** |
| [`paideia-as`](https://github.com/paideia-os/paideia-as) | `[█████]` | 🟢 | 42 (every other satellite in the org) | 0 | Assembler compiler (Rust, self-hosted target). **v0.33.1 → v0.34.0 → v0.35.0** this session. v0.34.0: `mul reg64` mnemonic (`#1398`). v0.35.0: **god-file refactor phase 1** — 5 files → mod dirs (`#1400`/`#1401`/`#1402`/`#1403`/`#1404`; SHAs `6f6316a`, `0571aa1`, `af85f90`, `9ff3ee9`); internal Rust refactor, no `.pdx`-visible ABI change. Plus ECDSA-P256 intrinsic (`#1346`) closed. **Phase 2 (`encode.rs`, `parse_primary`, `let_item`, `emit_enum_match`, `emit_block_body`, `emit_walker`, `term_eval`) is Wave X WIP** — first landing (`let_item.rs`, `a7fe1a5`, closes `#1408`) already in origin/main. 6 open. |
| [`libpdx-semantic-pipe`](https://github.com/paideia-os/libpdx-semantic-pipe) | `[█████]` | 🟢 | 17 (postui + shell + every schema-emitting tool) | 0 | Schema-typed pipe endpoints over `KIND_IPC_ENDPOINT`. `v1.0.0`, 6 open, unchanged. **New rebuild trigger this session:** `sys_semantic_send` @sysno 115 (monorepo `71a15fb`, closes `#2350`, R107-M0-001) — the natural client-side wrapper landing site. |

---

## Table 2 — Tools

| Repo | Maturity | Status | Dependent repos | OS changes needed | Summary |
|---|:-:|:-:|---|:-:|---|
| [`svc-compositor`](https://github.com/paideia-os/svc-compositor) | `[█░░░░]` | 🔴 | 5 (svc-wm, pdxterm, pdxclock, pdxwatch, pdxpaint) | 0 | Sole holder of `KIND_FB_SCANOUT`; window table, 60 Hz render loop, input pump, screenshot query. Scaffold-only (2 commits, 16 open, unchanged); kernel-side R101–R106 substrate landed prior sessions. |
| [`svc-wm`](https://github.com/paideia-os/svc-wm) | `[█░░░░]` | 🔴 | 4 (pdxterm, pdxclock, pdxwatch, pdxpaint) | 0 | Window manager. Tiling policy, focus, keyboard shortcuts, `KIND_INPUT_FOCUS` mint. Scaffold-only (2 commits, 12 open, unchanged). |
| [`shell`](https://github.com/paideia-os/shell) | `[██░░░]` | 🔴 | 0 | 0 | Paideia shell. Scoring reflects the `v1.0.0` retroactive walk-back from the prior snapshot (zero syscalls, no `shell_main` entry point). 23 → 21 open this session (`#41`/`#42` tokenizer/dispatcher/test-infra tickets still active as R106 shell-satellite work). |
| [`edit`](https://github.com/paideia-os/edit) | `[█░░░░]` | 🔴 | 0 | 0 | vi-like modeless TUI editor. Scaffold (1 commit, 7 open, unchanged); R71 milestone gated on postui — **postui just hit v1.0.0**, so this gate is now released. |
| [`fetch`](https://github.com/paideia-os/fetch) | `[█░░░░]` | 🔴 | 0 | 0 | HTTP GET client over TCP. Scaffold (1 commit, 3 open, unchanged); blocked on `libpdx-net`.M4. |
| [`line`](https://github.com/paideia-os/line) | `[█░░░░]` | 🔴 | 0 | 0 | ed-style scriptable line editor. Scaffold (1 commit, 7 open, unchanged); R63 milestone open. |
| [`pdxclock`](https://github.com/paideia-os/pdxclock) | `[█░░░░]` | 🔴 | 0 | 0 | Reference clock (smallest useful window app). Scaffold-only (2 commits, 7 open, unchanged); R102 reference app. |
| [`pdxcurl`](https://github.com/paideia-os/pdxcurl) | `[█░░░░]` | 🔴 | 0 | 0 | Cap-native, PQ-preferring, audit-first curl. Scaffold (2 commits, 19 open, unchanged); blocked on `libpdx-net`.M3/M4 + `KIND_TLS_TRUST`. |
| [`pdxdig`](https://github.com/paideia-os/pdxdig) | `[█░░░░]` | 🔴 | 0 | 0 | DNS query CLI (A-record v1). Scaffold (2 commits, 15 open, unchanged); blocked on `libpdx-net`.M2 + `SOCK_DGRAM`. |
| [`pdxpaint`](https://github.com/paideia-os/pdxpaint) | `[█░░░░]` | 🔴 | 0 | 0 | Reference paint app. Scaffold-only (2 commits, 10 open, unchanged); R102. |
| [`pdxping`](https://github.com/paideia-os/pdxping) | `[█░░░░]` | 🔴 | 0 | 0 | ICMP echo CLI. Scaffold (2 commits, 13 open, unchanged); blocked on `sys_icmp_echo` (sysno 96) + `R_NET_PRIVILEGED_PROTOCOL` elevate class. |
| [`pdxsock`](https://github.com/paideia-os/pdxsock) | `[█░░░░]` | 🔴 | 0 | 0 | General TCP/UDP client + server. Scaffold (2 commits, 14 open, unchanged); TCP path buildable; UDP mode gated on `SOCK_DGRAM`. |
| [`pdxterm`](https://github.com/paideia-os/pdxterm) | `[█░░░░]` | 🔴 | 0 | 0 | Framebuffer terminal emulator. Scaffold-only (2 commits, 12 open, unchanged); R102 reference app. |
| [`pdxtrust`](https://github.com/paideia-os/pdxtrust) | `[█░░░░]` | 🔴 | 0 | 0 | Trust-anchor management CLI. Scaffold (2 commits, 15 open, unchanged); blocked on `KIND_TLS_TRUST` kernel-side. |
| [`pdxwatch`](https://github.com/paideia-os/pdxwatch) | `[█░░░░]` | 🔴 | 0 | 0 | System-monitor GUI (graphical peer of `postui-top`). Scaffold-only (2 commits, 10 open, unchanged); R102 reference app. |
| [`ping`](https://github.com/paideia-os/ping) | `[█░░░░]` | 🔴 | 0 | 0 | Legacy R80 ping. Superseded by `pdxping`; likely retired. |
| [`remote`](https://github.com/paideia-os/remote) | `[█░░░░]` | 🔴 | 0 | 0 | Secure shell + remote copy with ML-KEM handshake. Scaffold (1 commit, 7 open, unchanged); blocked on `libpdx-net`.M3. Crypto substrate ready (ML-KEM-768 in v0.33.x). |
| [`cat`](https://github.com/paideia-os/cat) | `[█████]` | 🟢 | 0 | 0 | File read/concatenate. `v1.0.0`. 7 open, unchanged. |
| [`cp`](https://github.com/paideia-os/cp) | `[█████]` | 🟢 | 0 | 0 | Copy with PdxFS undo record. `v1.0.0`. 4 open, unchanged. |
| [`doc`](https://github.com/paideia-os/doc) | `[█████]` | 🟢 | 0 | 0 | Documentation viewer. `v1.0.0`. 10 open, unchanged. |
| [`ls`](https://github.com/paideia-os/ls) | `[█████]` | 🟢 | 0 | 0 | Directory listing (emits `PdxFsDirEntry[]`). **v1.1.1**. 7 → 2 open this session — only `#39` (total-line semantic record) and `#35` (full `-R` recursion) remain. |
| [`mkdir`](https://github.com/paideia-os/mkdir) | `[█████]` | 🟢 | 0 | 0 | Directory create. `v1.0.0`. 4 open, unchanged. |
| [`mkfs.pdxfs`](https://github.com/paideia-os/mkfs.pdxfs) | `[█████]` | 🟢 | 0 | 0 | PdxFS-on-block formatter. `v1.1.3`. 1 open — `#26` `LE-001` elevate gate, blocked on `tools/build.sh`'s R64v2 link line excluding `libpdx-elevate`. |
| [`mount.pdxfs`](https://github.com/paideia-os/mount.pdxfs) | `[█████]` | 🟢 | 0 | 0 | Volume mount tool. `v1.1.3`. **0 open** — fully clean. |
| [`mv`](https://github.com/paideia-os/mv) | `[█████]` | 🟢 | 0 | 0 | Move with PdxFS undo + destructive-op audit. `v1.0.0`. 8 open — `#29` `LE-001` elevate-adoption ticket carries from prior snapshot. |
| [`pkg`](https://github.com/paideia-os/pkg) | `[█████]` | 🟢 | 0 | 0 | Package manager. `pkg-v1.0.0`. 16 open — includes `#40` `LE-001` rename ticket for retired `elevate_client_request` call site. |
| [`rm`](https://github.com/paideia-os/rm) | `[█████]` | 🟢 | 0 | 0 | Remove with undo + destructive-op audit. `v1.0.0`. 9 open — two elevate-migration tickets (`#29` `_require`+`acquire`, `#30` `cap_derive`+`revoke_cascade` for `rm -r`). |
| [`umount.pdxfs`](https://github.com/paideia-os/umount.pdxfs) | `[█████]` | 🟢 | 0 | 0 | Volume unmount. `v1.1.2`. **0 open** — fully clean. |

Reference apps (`postui-dmesg`, `postui-hex`, `postui-top`) and the umbrella `paideia-os` monorepo are omitted from Table 2 per the classification rule; the postui satellite drain is captured in "Recent session activity" and Table 3 (row 5).

---

## Table 3 — Session-scoped dependency-impact matrix

For each substrate round landed since the 2026-09-06 snapshot, which satellites are affected. Cells use one of: **unaffected** / **consumes / no rebuild needed** / **rebuild required** / **landed against**.

| # | Substrate round | SHA / tag | postui stack | libpdx-semantic-pipe | CLI tools (cat/ls/mv/rm/cp/…) | Volume trio | libpdx-elevate / libpdx-audit | Net stack | GUI (R102) | shell |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | **paideia-as v0.35.0** god-file refactor phase 1 (5 files → mod dirs; `#1400`/`#1401`/`#1402`/`#1403`/`#1404`) | `6f6316a`, `0571aa1`, `af85f90`, `9ff3ee9` (tag `v0.35.0`) | landed against v0.35 (internal, no ABI change) | landed against v0.35 | landed against v0.35 | landed against v0.35 | landed against v0.35 | landed against v0.35 | landed against v0.35 | landed against v0.35 |
| 2 | **paideia-as v0.34.0** unsigned `mul reg64` mnemonic (`#1398`) | `1bf149b` (tag `v0.34.0` via `f0050dd`) | landed against v0.34 (postui `fd94bf8` `fx_mul` full-128-bit path) | unaffected | unaffected | unaffected | unaffected | unaffected (crypto uses BigInt loops, not scalar mul) | unaffected | unaffected |
| 3 | **paideia-os `#2351`** `klog_ring_read_tail` newest-N-bytes fix | `0fc0e2d` | rebuild required — postui-dmesg is the sole consumer of `klog_ring_read_tail`; the fix cleanly lands on its `klog_poll.pdx` path | consumes / no rebuild needed | unaffected | unaffected | unaffected | unaffected | unaffected | consumes / no rebuild needed (shell reads klog through a different path) |
| 4 | **sys_semantic_send @sysno 115** (R107-M0-001, `#2350`) | consumes via `libpdx-semantic-pipe` — no direct rebuild | rebuild required — natural client-side wrapper landing site for the new syscall | consumes / no rebuild needed (all schema-emitting tools inherit once wrapper adopts) | consumes / no rebuild needed | unaffected | unaffected | unaffected | consumes / no rebuild needed |
|   | | `71a15fb` | | | | | | | | |
| 5 | **KIND_TUI_CANVAS live** (R89.M1 wave, cap dispatch + cell diff + ANSI emit + damage/stat + boot witness) + **KIND_TTY termios** (R90-XREPO.004) | `bef24fe`, `c83e0fe`, `61cd83b`, `c1f4403`, `6b050a2`, `f6ae45a` | landed against monorepo HEAD — postui v1.0.0 render backend consumes `KIND_TUI_CANVAS`; postui-hex/dmesg/top drained against it this session (`b6c961c`, `932f3c1`, `4ebaf35`+`e8d5379`) | unaffected | unaffected | unaffected | unaffected | unaffected | consumes / no rebuild needed (R102 GUI stack will use `KIND_SURFACE`, not `KIND_TUI_CANVAS`) | consumes / no rebuild needed — shell will use `KIND_TTY` termios once the R106 shell-satellite `#2341` lands |

### Reading the matrix

- **"landed against v0.X"** means the release is cut and the satellite's own tree has already picked it up (either as a submodule bump or via direct consumption of the new primitive).
- **"consumes / no rebuild needed"** means the change is transparent — the satellite uses the substrate through a client-side wrapper (typically `libpdx-semantic-pipe` or a cap-kind handler) and inherits the fix at next rebuild without any code change.
- **"rebuild required"** means the satellite needs a real code change (a submodule bump alone won't pick up the new behavior).
- **"unaffected"** means the substrate change doesn't reach the satellite's surface.
- **God-file phase 2 (Wave X, WIP)** is deliberately excluded from this matrix — `let_item.rs` has landed (`a7fe1a5`, closes `#1408`) but `encode.rs`, `parse_primary`, `emit_enum_match`, `emit_block_body`, `emit_walker`, `term_eval` are still in flight; the matrix will pick them up next refresh when v0.36.x cuts.

---

## Notes on this snapshot

- **postui hitting v1.0.0 + reference-app drain is the session's headline.** The three reference apps (postui-hex, postui-dmesg, postui-top) drained their outstanding correctness issues in one wave (`b6c961c`, `932f3c1`, `4ebaf35`+`e8d5379`), and the debugger-catch on postui-top (`e8d5379` clamps on `Rect.w`-derived `bw` rather than SysV-arg `cols`) is a good illustration of the "debugger every iteration" discipline paying real dividends — a naive re-fix would have silently reintroduced the same defect for sub-rect callers.
- **paideia-as god-file refactor phase 1 shipped in a single tag.** The v0.35.0 batch bundled five separate `mod dir` refactors (`stdlib_lowering.rs`, `cmd_build.rs`, `instruction.rs`, `unsafe_walker.rs`, `emit_lambda.rs`) under one workspace-version bump. Internal Rust reshaping only; no `.pdx`-visible ABI change, which is why every downstream cell in Table 3 row 1 reads "landed against v0.35" rather than requiring a rebuild pass.
- **Phase 2 is explicitly WIP (Wave X).** `let_item.rs` (`a7fe1a5`, closes `#1408`) has already landed on origin/main; `encode.rs`, `parse_primary`, `emit_enum_match`, `emit_block_body`, `emit_walker`, `term_eval` are still to come. Expect a v0.36.x cut when phase 2 closes; the ecosystem-status refresh at that point will roll them into Table 3.
- **`libpdx-elevate`↔`libpdx-audit` audit-swap escalation is still the one load-bearing cross-repo block.** `libpdx-elevate#38` (LE.M2-002) cannot swap its journal calls to real `libpdx-audit` primitives until `libpdx-audit#31` (`audit_append_leaf`, `!{mem}`-only leaf) lands. `libpdx-elevate` M6 (`#33`,`#34`) blocked transitively. This is the standing "next fix" per the cross-repo escalation convention — unchanged this session.
- **`sys_semantic_send` @115 is the load-bearing new syscall this session.** It is the client-facing surface `libpdx-semantic-pipe` will wrap; every schema-emitting tool downstream inherits the new path transparently once the wrapper lands. R107-M0-001 is the round-tag; the wrapper adoption is the next visible ecosystem move.
- **`ls` drain from 7 → 2 open** completes the v1.1.x wave for that tool: `caps.decl`, schema-hash migration, cwd-relative resolve, real owner rows, and single/multi-path listing all closed. Only two forward-looking tickets remain (`#39` total-line semantic record, `#35` full `-R`).
- **paideia-os monorepo moved 2 → 4 open**: `#2345` closed (R107.M1 real body landed); `#2347`, `#2348`, `#2349` opened as R107 close-out debt. None ABI-forced; every satellite's "OS changes needed" column and every Table 3 cell for kernel-forced work still reads 0.
- **Nine R102 GUI-cluster scaffolds** (`libpdx-font`, `libpdx-gfx`, `libpdx-event`, `svc-compositor`, `svc-wm`, `pdxterm`, `pdxclock`, `pdxwatch`, `pdxpaint`) unchanged at 2 commits each. **Recommended investment order** is unchanged: (1) `libpdx-net` (unblocks R100 network-tools wave — 22 open); (2) `libpdx-elevate`↔`libpdx-audit` audit-swap (`#31`); (3) R102 GUI cluster userland bodies, kernel-side substrate now well ahead.
- **`edit`'s gate is released** — `postui-v1.0.0` shipped this session, so the sole external blocker on `edit`'s R71 milestone is gone; the 7 open items on `edit` are now the actual work.
- **`libpdx-schema-registry`** unchanged at 0 open, 🟡; FNV-1a-64 hash placeholder still held pending `paideia-as#1392` BLAKE3 intrinsic.

---

_Last refreshed: 2026-09-07 (fourth refresh — paideia-as v0.34.0/v0.35.0 god-file phase 1 + postui v1.0.0 satellite drain + kernel klog fix + sys_semantic_send @115)_ — send the `ECOTABLE` command to Claude Code in this project to rebuild.
