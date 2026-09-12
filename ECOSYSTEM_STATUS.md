# PaideiaOS Ecosystem Status

**Snapshot:** 2026-09-12 (fifth refresh — osarch/re-scope wave: 18 subjects deep-scored; three prior 🟢 v1.0.0 tags (`cat`, `mv`, `doc`) unmasked as schedule-closure not functional; new local `tools/user/shell` scaffold surfaced; `pdxsock` promoted to FUNCTIONAL/TCP after v1.1-A→v1.2.2; 28 new issues recommended for main to file).
**Refresh command:** `ECOTABLE` — this rebuild is table-restructured per the 2026-09-12 directive (satellite + in-tree tools merged into Table 2; Table 3 rewritten as a reverse-dependency matrix).

This document is a cross-repo readiness map: every library and every tool that ships in the PaideiaOS image, scored on the same 4-level maturity scale, sorted so the highest-blast-radius under-built repos surface first.

## Delta since 2026-09-07 (fourth refresh)

- **Re-scope wave surfaced three quiet-regression tags.** Osarch found that `cat` v1.0.0, `mv` v1.0.0, and `doc` v1.0.0 were milestone-schedule closures, not functional. `cat`'s `FileRead`/`TtySink`/`PipeOut`/`AuditStub` are still stub-gated pending ENH-002 (#22) + ENH-001 (#28); `cat FOO` cannot print `FOO` in production. `mv`'s M5 tag never shipped a real `_start`/I4 exit frame (#18) and its eight `pdxfs_txn_*` trampolines are M2 stubs. `doc` v1.0.0 was retracted by a WALK-BACK NOTICE — the M1..M5 rollup was schedule closure; `file_read_stub` unconditionally returned "not found" and no `_start`/link produced an ELF. Recovery in progress: `doc` at 0.7.0 (functional render); `cp`/`mkdir`/`rm` promoted to genuine FUNCTIONAL (real 5-syscall bodies; cwd-relative resolve; real M1..M5 stack).
- **pdxsock jumped 🔴 STUB → 🟡 PARTIAL/🟢 FUNCTIONAL for TCP.** v1.1-A landed real `pdxsock_client_body`/`pdxsock_server_body` (sysnos 87–94); v1.1-B added `SockSessionRecord@0.1` semantic-pipe emit; v1.2.1 unfroze post-accept idle; v1.2.2 stopped fabricating UDP dry-run previews. TCP end-to-end works. UDP intentionally stubbed pending `R100-PREP-002`; TCP client is still half-duplex (needs `sys_poll` at sysno 102).
- **tools/user/shell local scaffold surfaced (untracked).** Live clone of `paideia-os/shell` at HEAD `c355368` (2026-09-10), 20+ landed commits. Real `shell_main`/`shell_repl_step`/`shell_argv_dispatch`, real fd-0 line reader via `sys_read`, real `O_APPEND` history persistence, fork-before-exec (shell#44). NOT in `.gitmodules` — adoption is the still-required paideia-os-side landing before the `sys_execve` cutover (see STATUS.md §ENH-008).
- **Four in-tree critical-path binaries re-scored.** `init` FUNCTIONAL (three real fork+execve cycles, but hardcoded 3-daemon manifest, no supervisor, PID-1 exits on shutdown); `rootfs_seed` PARTIAL (4 of 7 manifest entries still 9-byte "R57 stub\n" — /bin/ls, /bin/cat, /bin/ps, /bin/mount — waiting on R57.M4-007+ promotion); `syscall_shim` PARTIAL (coverage stops at sysno 95; sysnos 40, 41, 79, 96..115 inlined by every caller); `elevate_broker_daemon` explicit STUB (every op returns `ELVB_DISPATCH_STUB`); in-tree `shell` FUNCTIONAL (real REPL, no line editing/pipes/signal handling).
- **In-tree recently-touched tools re-scored.** `ls` FUNCTIONAL (v1.1 cwd resolve, no flags); `ps` FUNCTIONAL (real sys_taskinfo walk, no flags); `touch` FUNCTIONAL (one file, no utime); `dispatch` MATURE (7 builtins + PATH-prefix resolve); `tokenizer` PARTIAL (no quoting/escape/$VAR). ~~The satellite `tools/user/shell/src/tokenizer.pdx` R106.M1 already models the quote state machine and should be the port target rather than reinventing.~~
- **Structural hazard: in-tree vs. satellite duplication.** `src/user/{cat,cp,mkdir,mv,rm}.pdx` and `tools/user/{cat,cp,mkdir,mv,rm}/` are two live implementations of the same commands with divergent shipping models (kernel-embedded via `bin_seeds.pdx` vs. signed release manifest), no cutover plan, and no CI gate proving behavior compatibility. Same fork for `dispatch`/`tokenizer` vs. `tools/user/shell/`. This warrants a design-doc-level "in-tree vs. satellite transition" wave.
- **paideia-os monorepo moved 4 → 10 open** (all R113 GPU-native-desktop scaffolds: `#2380`, `#2407`–`#2411`, `#2417`–`#2420`). None gate the ecosystem re-scope subjects; none force ABI-visible kernel change. `#2429`–`#2434` closed via the 2026-09-11 tool-sweep batch.
- **Standing block unchanged:** `libpdx-elevate#38` (LE.M2-002 audit-swap) still blocks on `libpdx-audit#31` (`audit_append_leaf` leaf primitive).

## Legend

**Semaphore convention.** Each repo is scored on a 4-level maturity scale, then bucketed into a red/yellow/green semaphore:

| Level | Symbol | Meaning |
|---|:-:|---|
| STUB | 🔴 | Scaffold only, does not execute; or explicit stub-reply for the primary op. |
| PARTIAL | 🟡 | Real body for some surfaces; key milestones (M2+ typically) still stub or fake. |
| FUNCTIONAL | 🟢 | Executes correctly for stated M1..M3 milestones; gaps only in polish/M4-M5. |
| MATURE | 🟢+ | Signed release + tests + downstream consumers OK. |

Sort within each table: **Maturity ASC** (STUB first), then **Dependent count DESC** — highest-blast-radius under-built repos read first.

**OS changes needed** counts *open* issues in `paideia-os/paideia-os` that this subject requires before it can finish its own open milestones. The monorepo carries **10 open issues** (`#2380`, `#2407`–`#2411`, `#2417`–`#2420`), all R113 GPU-desktop; none force an ABI-visible kernel change any listed subject is gated on. Every column below reads 0.

---

## Table 1 — Libraries

| Repo | Maturity | Status | Dependent repos | OS changes | Summary |
|---|:-:|:-:|---|:-:|---|
| [`libpdx-net`](https://github.com/paideia-os/libpdx-net) | STUB | 🔴 | 9 (pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust, fetch, ping, remote, pkg) | 0 | TCP/UDP wrappers, DNS, TLS 1.3, HTTP/1.1. Blocks R100 wave. Scaffold-only (2 commits, 22 open, unchanged). |
| [`libpdx-font`](https://github.com/paideia-os/libpdx-font) | STUB | 🔴 | 6 (libpdx-gfx, svc-wm, pdxterm, pdxclock, pdxwatch, pdxpaint) | 0 | Bitmap glyph store + text metrics. R102 CPU-side text stack. Scaffold-only (2 commits, 11 open, unchanged). |
| [`libpdx-gfx`](https://github.com/paideia-os/libpdx-gfx) | STUB | 🔴 | 6 (svc-compositor, svc-wm, pdxterm, pdxclock, pdxwatch, pdxpaint) | 0 | CPU-side BGRA8888 into KIND_SURFACE-backed buffer. Compositor commit + damage. Scaffold-only (2 commits, 13 open). |
| [`libpdx-url`](https://github.com/paideia-os/libpdx-url) | STUB | 🔴 | 5 (libpdx-net, pdxcurl, pkg, fetch, remote) | 0 | RFC 3986 parser. Scaffold-only (2 commits, 11 open). |
| [`libpdx-event`](https://github.com/paideia-os/libpdx-event) | STUB | 🔴 | 4 (svc-wm, pdxterm, pdxwatch, pdxpaint) | 0 | Client-side input event routing. Scaffold-only (2 commits, 11 open). |
| [`libpdx-config`](https://github.com/paideia-os/libpdx-config) | STUB | 🔴 | 3 (pkg, shell, pdxtrust) | 0 | `/etc` key=value parser. Scaffold; 2 commits, 0 open. |
| [`libpdx-cap`](https://github.com/paideia-os/libpdx-cap) | MATURE | 🟢+ | 30 (every tool + libpdx-audit + libpdx-elevate) | 0 | Capability marshalling. **v1.0.1**. 1 open (`#20`, exec-time reconciliation helper — unblocked). |
| [`libpdx-argv`](https://github.com/paideia-os/libpdx-argv) | MATURE | 🟢+ | 26 (every CLI tool; 9 real consumers) | 0 | CLI arg parsing (text + semantic-schema). **v1.1.3** (bumped from v1.1.0 last snapshot). 2 open (was 14 — big drain since 2026-09-07). |
| [`libpdx-audit`](https://github.com/paideia-os/libpdx-audit) | MATURE | 🟢+ | 10 (rm, mv, cp, mkfs/mount/umount.pdxfs, pkg, pdxtrust, pdxcurl, pdxping) | 0 | Audit-first emit to `/system/audit/*.log`. **v1.1.1**. 1 open — `#31` `audit_append_leaf` `!{mem}`-only leaf, still the standing cross-repo block on `libpdx-elevate#38`. |
| [`libpdx-schema-registry`](https://github.com/paideia-os/libpdx-schema-registry) | FUNCTIONAL | 🟢 | 10 | 0 | Schema registry client-facade. 12 commits, 0 open, unchanged. FNV-1a-64 placeholder pending `paideia-as#1392` BLAKE3. |
| [`libpdx-elevate`](https://github.com/paideia-os/libpdx-elevate) | FUNCTIONAL | 🟢 | 8 (rm, mkfs/mount/umount.pdxfs, pkg, pdxtrust, pdxping, pdxcurl) | 0 | Client-side elevate protocol helper. **v1.1.2**. 5 open (was 13 — significant drain). LE.M2 real-audit-swap (`#38`) still blocked on `libpdx-audit#31`. |
| [`libpdx-volume`](https://github.com/paideia-os/libpdx-volume) | MATURE | 🟢+ | 3 (mkfs/mount/umount.pdxfs) | 0 | KIND_VOLUME helpers + PDXB codec + mount_table. **v1.1.5**. 0 open (clean). |
| [`postui`](https://github.com/paideia-os/postui) | MATURE | 🟢+ | 6 (postui-dmesg/hex/top, shell, edit, doc) | 0 | Ratatui-inspired TUI, 24-bit truecolor, KIND_TUI_CANVAS backend. **`v1.0.0`** (landed last snapshot). Unchanged this refresh. |
| [`paideia-as`](https://github.com/paideia-os/paideia-as) | MATURE | 🟢+ | 42 (every satellite in the org) | 0 | Assembler compiler. **v0.35.0** (god-file refactor phase 1). Phase 2 WIP: `let_item.rs` landed (`#1408`); `encode.rs`/`parse_primary`/`emit_enum_match`/`emit_block_body`/`emit_walker`/`term_eval` staged for v0.36.x. |
| [`libpdx-semantic-pipe`](https://github.com/paideia-os/libpdx-semantic-pipe) | MATURE | 🟢+ | 17 (postui + shell + every schema-emitting tool) | 0 | Schema-typed endpoints over KIND_IPC_ENDPOINT. `v1.0.0`, 6 open. Natural wrapper landing site for `sys_semantic_send @sysno 115` (paideia-os#2350 landed last snapshot). |

---

## Table 2 — Tools (satellite + in-tree merged)

The **Location** column names the authoritative source. `sat` = git submodule under `tools/user/`; `in-tree` = `src/user/<name>.pdx` in the monorepo; `both` = duplicated (structural hazard — see delta above).

| Repo/Binary | Location | Maturity | Status | Ships as | OS changes | Summary |
|---|:-:|:-:|:-:|:-:|:-:|---|
| [`svc-compositor`](https://github.com/paideia-os/svc-compositor) | sat | STUB | 🔴 | not seeded | 0 | Sole holder of KIND_FB_SCANOUT. Scaffold-only (2 commits, 16 open, unchanged). |
| [`svc-wm`](https://github.com/paideia-os/svc-wm) | sat | STUB | 🔴 | not seeded | 0 | Window manager. Scaffold-only (2 commits, 12 open). |
| [`elevate_broker_daemon`](/) | in-tree | STUB | 🔴 | `/bin/elevate_broker_daemon` | 0 | **Explicit stub per R48-PREP-005.M2** — every op returns `ELVB_DISPATCH_STUB` (0xFFFFEBFB). No policy, no queue, no expiry, no audit. Drainer is real. **M3/M4 promotion has no tracked monorepo issue.** |
| [`edit`](https://github.com/paideia-os/edit) | sat | STUB | 🔴 | not seeded | 0 | vi-like modeless TUI editor. Scaffold (1 commit, 7 open). Gate on postui released this cycle. |
| [`fetch`](https://github.com/paideia-os/fetch) | sat | STUB | 🔴 | not seeded | 0 | HTTP GET. Scaffold (1 commit, 3 open); blocked on `libpdx-net`.M4. |
| [`line`](https://github.com/paideia-os/line) | sat | STUB | 🔴 | not seeded | 0 | ed-style editor. Scaffold (1 commit, 7 open). |
| [`pdxclock`](https://github.com/paideia-os/pdxclock) | sat | STUB | 🔴 | not seeded | 0 | Reference clock. Scaffold (2 commits, 7 open). |
| [`pdxcurl`](https://github.com/paideia-os/pdxcurl) | sat | STUB | 🔴 | not seeded | 0 | Cap-native curl. Scaffold (2 commits, 19 open); blocked on `libpdx-net`.M3/M4. |
| [`pdxdig`](https://github.com/paideia-os/pdxdig) | sat | STUB | 🔴 | not seeded | 0 | DNS query CLI. Scaffold (2 commits, 15 open); blocked on `libpdx-net`.M2. |
| [`pdxpaint`](https://github.com/paideia-os/pdxpaint) | sat | STUB | 🔴 | not seeded | 0 | Reference paint app. Scaffold (2 commits, 10 open). |
| [`pdxping`](https://github.com/paideia-os/pdxping) | sat | STUB | 🔴 | not seeded | 0 | ICMP echo. Scaffold (2 commits, 13 open); blocked on `sys_icmp_echo` (sysno 96). |
| [`pdxterm`](https://github.com/paideia-os/pdxterm) | sat | STUB | 🔴 | not seeded | 0 | FB terminal emulator. Scaffold (2 commits, 12 open). |
| [`pdxtrust`](https://github.com/paideia-os/pdxtrust) | sat | STUB | 🔴 | not seeded | 0 | Trust-anchor management. Scaffold (2 commits, 15 open); blocked on KIND_TLS_TRUST. |
| [`pdxwatch`](https://github.com/paideia-os/pdxwatch) | sat | STUB | 🔴 | not seeded | 0 | System-monitor GUI. Scaffold (2 commits, 10 open). |
| [`ping`](https://github.com/paideia-os/ping) | sat | STUB | 🔴 | not seeded | 0 | Legacy R80 ping, superseded by pdxping. Likely retired. |
| [`remote`](https://github.com/paideia-os/remote) | sat | STUB | 🔴 | not seeded | 0 | Secure shell + remote copy. Scaffold (1 commit, 7 open); blocked on `libpdx-net`.M3. |
| `rootfs_seed` | in-tree | PARTIAL | 🟡 | init-linked | 0 | **4 of 7 manifest entries (/bin/ls,cat,ps,mount) still 9-byte "R57 stub\n" payloads** per R57.M0 promise; only /bin/sh + /bin/true carry real ELFs. Manifest frozen at 7 files; mv/rm/mkdir/cp/touch/echo/pwd/env absent; /etc has only motd. |
| `syscall_shim` | in-tree | PARTIAL | 🟡 | linker-embedded | 0 | Coverage stops at **sysno 95**. Sysnos 40, 41, 79 inlined by callers; entire 96..115 range (incl. `sys_semantic_send @115`) absent; unlink/rmdir/lseek/fstat/mmap/pipe/sigaction absent. |
| `tokenizer` | in-tree | PARTIAL | 🟡 | shell.elf module | 0 | Whitespace + redirect + `~` alias tagging only. **No quoting (`'`, `"`), no `\`-escape, no `$VAR`, no `;`/`&`/`\|`.** Satellite `tools/user/shell/src/tokenizer.pdx` (R106.M1) already models the quote state machine — port target. |
| [`cat`](https://github.com/paideia-os/cat) | both | PARTIAL | 🟡 | `/bin/cat` (in-tree via bin_seeds; sat @ v1.1.1-A Unreleased) | 0 | **Regression from prior 🟢 v1.0.0.** v1.0.0 was scaffold; v1.1-A added real `_start`+`cat.ld`, v1.1.1-A errno-mapped stderr; but file-I/O pipeline (FileRead/TtySink/PipeOut) stub-gated pending ENH-002 (#22) + ENH-001 (#28). `cat FOO` cannot print `FOO`. 9 open. |
| [`mv`](https://github.com/paideia-os/mv) | both | PARTIAL | 🟡 | `/bin/mv` (in-tree via bin_seeds) | 0 | **Regression from prior 🟢 v1.0.0.** v1.1-A wired real `sys_rename` + xdev copy+unlink; ENH-004 dst-clobber guard landed. But #18 (real `_start` + I4 exit) open — M5 v1.0.0 tag never shipped a real entry frame; eight `pdxfs_txn_*` trampolines M2 stubs. 10 open. |
| `init` | in-tree | FUNCTIONAL | 🟢 | init-linked | 0 | Three real fork+execve cycles (child_hello, /bin/sh, /bin/elevate_broker_daemon), tty0 setup, rootfs seed, home probe/mount, wait4. Hardcoded 3-daemon manifest, no supervisor abstraction, no respawn, no signal handling, PID-1 exits on `init_shutdown` via `sys_exit(0)`. |
| `shell` | in-tree | FUNCTIONAL | 🟢 | `/bin/sh` (kernel-seeded) | 0 | Real prompt/read/tokenize/dispatch/exec loop, HOME chdir on entry, EOF handling, external dispatch table. No line editing (backspace/DEL appended literally), no pipes/redirection, no signals, no `$VAR`, no history. |
| `ls` | in-tree | FUNCTIONAL | 🟢 | `/bin/ls` (in-tree via bin_seeds L765) | 0 | v1.1 userspace cwd resolve (ls#29 landed 2026-09-12); getdents walk + name-per-line. **No flags** (`-a`/`-l`/`-1`/`-F` deferred). |
| `ps` | in-tree | FUNCTIONAL | 🟢 | `/bin/ps` (in-tree via bin_seeds L1037) | 0 | Real `sys_taskinfo` walk, honest CMD from TCB.comm, real cpu_ticks/start. RSS deliberately dropped; no `%CPU` (no wall-clock sysno); no flags. |
| `touch` | in-tree | FUNCTIONAL | 🟢 | `/bin/touch` (in-tree via bin_seeds L1717) | 0 | argv[1] wired + honest fingerprint (#2433). One file only via `O_CREAT\|O_WRONLY`+close; **no utime**, no `-a`/`-m`/`-c`/`-r`/`-d`. NOT in rootfs_seed manifest — bin_seeds only. |
| [`doc`](https://github.com/paideia-os/doc) | sat | FUNCTIONAL | 🟢 | not seeded | 0 | **Recovered from v1.0.0 WALK-BACK.** 0.5.0 restored real read + real TTY drain + `_start`+link; 0.6.0 whole-document walk; 0.7.0 real `--help`/`--version`/`--color=*`. ENH-010 rendered-bytes smoke still open (#31). 8 open. |
| [`shell`](https://github.com/paideia-os/shell) | sat | FUNCTIONAL | 🟢 | not yet seeded (submodule not adopted) | 1 | **New in this table.** Live clone at `tools/user/shell/` HEAD `c355368`. Real `shell_main`/`shell_repl_step`/`shell_argv_dispatch`, real fd-0 line reader via `sys_read`, real `O_APPEND` history persistence, fork-before-exec (shell#44). NOT in `.gitmodules`. 7 open. |
| [`pdxsock`](https://github.com/paideia-os/pdxsock) | sat | FUNCTIONAL | 🟢 | not seeded | 0 | **Promoted from 🔴 STUB.** v1.1-A real TCP client/server (sysnos 87–94); v1.1-B `SockSessionRecord@0.1` semantic-pipe emit; v1.2.1 post-accept-idle fix; v1.2.2 UDP dry-run honesty. TCP end-to-end works; UDP intentionally stubbed. 7 open. |
| [`cp`](https://github.com/paideia-os/cp) | both | FUNCTIONAL | 🟢 | `/bin/cp` (in-tree via bin_seeds) | 0 | v1.1-A real 5-syscall body (open+read+write+close+stat); v1.1-B `sys_getcwd` cwd-resolve; v1.1-C doc-only atomicity retirement. `cp a b` works end-to-end. -p/-r deferred to v1.2. 6 open. |
| [`mkdir`](https://github.com/paideia-os/mkdir) | both | FUNCTIONAL | 🟢 | `/bin/mkdir` (in-tree via bin_seeds) | 0 | v1.1-A extraction (12+ files → 435 LOC), real sys_mkdir loop over argv positionals; v1.1-B userspace cwd-join. No flags (`-p`/`-m`/`-v` deferred to v1.2). 6 open. |
| [`rm`](https://github.com/paideia-os/rm) | both | FUNCTIONAL | 🟢 | `/bin/rm` (in-tree via bin_seeds) | 0 | Full M1-M5 stack landed with libpdx-audit/elevate/semantic-pipe wire-ins; 1.0.1 patch closed ENH-007 unknown-flag reject. Mutating PdxFS ops in walk.pdx still M2 skeleton-with-stub-tail (R42 substrate); three SECURITY holes open (#19–21). 8 open. |
| `dispatch` | in-tree | MATURE | 🟢+ | shell.elf module | 0 | 7 builtins (echo/exit/pwd/help/env/cd/clear), PATH-prefix resolve with sys_stat probe, exec_child with redirects, sys_getdents-based `help /bin` listing. Satellite `tools/user/shell/src/dispatch.pdx` is a distinct R49/R106 clean-start not yet cut over. |
| [`mkfs.pdxfs`](https://github.com/paideia-os/mkfs.pdxfs) | sat | MATURE | 🟢+ | not seeded | 0 | PdxFS-on-block formatter. **v1.1.4** (fix #29 dry-run silent exit). 2 open. |
| [`mount.pdxfs`](https://github.com/paideia-os/mount.pdxfs) | sat | MATURE | 🟢+ | not seeded | 0 | Volume mount. **v1.1.3**. **0 open** (clean). |
| [`umount.pdxfs`](https://github.com/paideia-os/umount.pdxfs) | sat | MATURE | 🟢+ | not seeded | 0 | Volume unmount. **v1.1.2**. **0 open** (clean). |
| [`pkg`](https://github.com/paideia-os/pkg) | sat | MATURE | 🟢+ | not seeded | 0 | Package manager. `pkg-v1.0.0`. 16 open (includes `#40` LE-001 rename). |

**Not scored here:** `builtins`, `child_hello`, `echo_client`, `echo_server`, `errno`, `founder_constants`, `io`, `string`, `true`, `pci_enumerator`, `acpi_supervisor`, `audio_supervisor`, `dmesg` — these are helper modules, test binaries, or supervisor daemons out of the CLI-tool re-scope scope. `postui-dmesg`, `postui-hex`, `postui-top`, and the umbrella `paideia-os` monorepo are omitted per the classification rule.

---

## Table 3 — Reverse-dependency matrix (who consumes what)

Row = producer; Row's cells = consumers grouped by cohort. Read: "if I break X, who feels it?"

| Producer | CLI tools | Filesystem tools | Elevate stack | Net stack | GUI/TUI | shell/dispatch |
|---|---|---|---|---|---|---|
| **`paideia-as`** | all | all | all | all | all | all |
| **`libpdx-argv`** | cat, cp, mv, rm, mkdir, ls, ps, touch, doc | mkfs, mount, umount | — | pdxsock, pdxcurl, pdxdig | — | shell (sat) |
| **`libpdx-cap`** | every tool | mkfs, mount, umount | libpdx-elevate, libpdx-audit | pdxsock, pdxcurl, pdxping | postui, svc-compositor | shell (sat), dispatch |
| **`libpdx-audit`** | rm, mv, cp | mkfs, mount, umount | libpdx-elevate | pdxcurl, pdxping | — | — |
| **`libpdx-elevate`** | rm | mkfs, mount, umount | — | pdxping, pdxcurl | — | — |
| **`libpdx-volume`** | — | mkfs, mount, umount | — | — | — | — |
| **`libpdx-net`** | fetch | — | — | pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust, remote, pkg | — | — |
| **`libpdx-schema-registry`** | cat, cp, mv, rm, ls, ps, doc | mkfs, mount, umount | libpdx-elevate | pdxsock, pdxcurl | postui | shell (sat) |
| **`libpdx-semantic-pipe`** | every schema-emitting tool | mkfs, mount, umount | libpdx-elevate | pdxsock, pdxcurl, pdxdig | postui | shell (sat), dispatch |
| **`postui`** | — | — | — | — | postui-dmesg, postui-hex, postui-top, edit, doc, postui-desktop | shell (sat) |
| **`libpdx-gfx`, `libpdx-font`, `libpdx-event`** | — | — | — | — | svc-compositor, svc-wm, pdxterm, pdxclock, pdxwatch, pdxpaint | — |
| **`syscall_shim` (in-tree)** | every in-tree `.pdx` binary | rootfs_seed (partial) | elevate_broker_daemon (partial) | echo_client, echo_server | — | shell (in-tree), init, dispatch |
| **`rootfs_seed` payloads** | ls, cat, ps (still stub bytes) | mount (still stub bytes) | — | — | — | sh (real ELF) |

**Reading the matrix.**
- The two producers whose repair is felt by the most consumers are **`syscall_shim`** and **`libpdx-cap`**. `syscall_shim`'s 96..115 gap means every downstream in-tree binary either lacks access or inlines the raw syscall; `libpdx-cap` is universal.
- The **`libpdx-elevate` → `libpdx-audit#31` cross-repo block** is now the standing single-issue-single-repo block for the entire audit-swap column (rm/mv/cp/mkfs/mount/umount/pkg/pdxtrust/pdxcurl/pdxping wait on it transitively).
- The **`libpdx-net` scaffold-only column** (9 consumers) is the largest concentrated debt on the ecosystem; nothing R100-shaped can advance until it lands M2.

---

## Recommended new issues (28, per repo)

Main to `gh issue create` these in a single wave. Group by repo.

### `paideia-os/cat` (2)
1. **cat: QEMU end-to-end smoke — `cat FOO` prints `FOO` on stdout** — witness that linked `cat.elf` reads a real disk file and drains real bytes to TTY; blocks on `#22`+`#28` but book the closeout now.
2. **cat: errno-mapping fixture — 7 diagnostic blobs fire from correct kernel errno** — v1.1.1-A errno table has no test; provoke each `-errno` at each syscall site and diff fd-2 payload.

### `paideia-os/cp` (2)
3. **cp: v1.2 planning — `-p` (permission preserve) + `-r` (recursive) placeholder issues** — no forward-looking issues exist; file so v1.2 milestone has trackable content.
4. **cp: regression test — dst-basename-only path relative to cwd (v1.1-B contract)** — no QEMU fixture asserts the `sys_getcwd` join lands at the right absolute path.

### `paideia-os/mv` (2)
5. **mv: R90 kernel-substrate wire for the eight `pdxfs_txn_*` trampolines** — parallel to cp#35; migrate from M2 stub returns onto real sysnos 70/104/105/107.
6. **mv: publish MoveRecord@0.2 schema fingerprint to libpdx-schema-registry** — ENH-004 bumped to v0.2 but no registry-publish path exists.

### `paideia-os/mkdir` (2)
7. **mkdir: v1.1-B `mkdir .` refusal smoke — assert `MK_DOT_CWD_NONSENSICAL` exit 1** — no fixture provokes this dedicated exit path.
8. **mkdir: v1.2 planning — `-p` (parent-creation) + `-m <mode>`** — STATUS names both deferred; neither filed.

### `paideia-os/rm` (2)
9. **rm: R90 kernel-substrate wire for mutating PdxFS ops** — parallel to cp#35; flip walk_recursive off trash-subtree stub onto real substrate.
10. **rm: v1.1-A real-body extraction (parallel to cat/cp/mkdir v1.1-A)** — every other coreutil ran the extraction; rm still ships eleven M1..M5 modules with mutating ops skeletonized.

### `paideia-os/doc` (1)
11. **doc: Rescue-plan tracker — WALK-BACK v1.0.0 marker → next signed-release path** — sequence the gates: ENH-010 rendered-bytes smoke (#31); R32 root key + `release --sign`; `--color=auto` isatty dep; re-tag policy (skip 1.0 vs. re-cut).

### `paideia-os/pdxsock` (1)
12. **pdxsock: TCP client full-duplex forwarding (sysno 102 `sys_poll`)** — retire half-duplex one-shot stdin read (M2-001 "Partially met"; follow-on "v1.1-A'" issue never filed).

### `paideia-os/paideia-os` (monorepo) (18)

**Adoption**
13. **paideia-os: adopt `tools/user/shell/` as `.gitmodules` submodule + wire `bin_seeds.pdx`** — live clone at HEAD `c355368` is untracked; STATUS §ENH-008 names this as the still-required paideia-os-side landing.

**init**
14. **init: retire remaining `<fp>` placeholder in fingerprint mount-ok strings** — R106.M3 retired functional consumers but two fingerprint lines still embed a literal placeholder in `mp=`.
15. **init: daemon supervisor abstraction to replace inline fork+exec cycles** — three cycles hardcoded; new daemons require editing `_start`; propose `InitServices` compile-time manifest + respawn policy.
16. **init: PID-1 should never exit; replace `init_shutdown` with panic-or-halt** — `sys_exit(0)` silently returns success on shutdown; unmasks silent-init-death boot failures.

**rootfs_seed**
17. **rootfs_seed: promote /bin/ls, /bin/cat, /bin/ps, /bin/mount from 9-byte stubs to real ELFs** — the R57.M4-007+ promotion never happened; only /bin/sh + /bin/true carry real ELFs today.
18. **rootfs_seed: expand manifest to include mv, rm, mkdir, cp, touch, echo, pwd, env** — manifest frozen at R57.M0 seven-file set.
19. **rootfs_seed: seed /etc/passwd, /etc/group, /etc/hostname, /etc/resolv.conf** — `/etc/` currently gets only `motd`; identity-shim files needed for POSIX-shaped consumers.

**syscall_shim**
20. **syscall_shim: add wrappers for sysnos 40, 41, 79 currently inlined by callers** — `sys_ipc_recv`/`sys_ipc_reply`/`sys_mkdir` inlined by elevate_broker_daemon + rootfs_seed.
21. **syscall_shim: add wrappers for sysnos 96..115 (kernel-landed but shim-absent)** — includes `sys_semantic_send @115`; add `tools/verify-syscall-shim-coverage.sh` gate.
22. **syscall_shim: add wrappers for unlink/rmdir/lseek/fstat/mmap/pipe/sigaction** — bodies exist per recent NUL-cap collateral commit; wrappers absent.

**elevate_broker_daemon**
23. **elevate_broker_daemon: promote M2 stub-reply to M3 roundtrip witness + M4 policy engine** — no monorepo issue tracks the promotion; all 10 open are R113 GPU.
24. **elevate_broker_daemon: fix stale slot-allocation table in loader-seeded-slot-allocation.md §3** — audio_supervisor now claims 14+15 contradicting the table; add drift-gate.

**shell (in-tree)**
25. **shell: line editing (backspace 0x08, DEL 0x7F) so line_buf survives typos** — currently appended verbatim.
26. **shell: pipe (`|`) and redirection (`>`, `<`, `>>`, `2>&1`) — extend tokenizer+dispatcher** — depends on `sys_pipe` shim wrapper.
27. **shell: SIGINT (Ctrl-C) handling so shell survives an aborted child** — depends on `sys_sigaction` shim wrapper.

**Tools**
28. **ls: implement -a / -l / -1 / -F flag suite** — argv scanner + `flags` u64 threaded through `ls_walk_top`; `-l` requires `sys_stat` per entry.
29. **ps: implement -a / -e / -f + `sys_clock_ticks` for %CPU** — no wall-clock sysno at R60; land, then wire.
30. **touch: multi-file argv + POSIX -a/-m/-c/-r/-d + `sys_utimensat`** — current handles exactly one target and does no timestamp manipulation.
31. **dispatch: envp-sourced PATH, pipeline (|), and background (&) tokens** — resolve_path hardcodes `["/bin/","/usr/bin/"]`.
32. **tokenizer: single-quote, double-quote, `\`-escape, `$VAR` expansion** — port shape from `tools/user/shell/src/tokenizer.pdx` R106.M1.

**Design-doc-level**
33. **design/user/in-tree-vs-satellite-transition.md — enumerate duplicates + handoff protocol + CI gate** — `src/user/{cat,cp,mkdir,mv,rm}.pdx` vs. `tools/user/{...}/` and `dispatch`/`tokenizer` vs. `tools/user/shell/`; no cutover plan; silent-drift risk on every future landing.

(Count: 33 concrete recommendations; core 28-issue wave is #1–#12 + #14–#27 + #33; the remaining 5 (#13, #28–#32) are the Wave 7 anchor items — see below.)

---

## Recommended Wave 7 target

**Two options; recommend #1.**

### Option 1 (recommended) — `syscall_shim` completeness sweep
Land issues **#20**, **#21**, **#22** in one wave. Rationale: `syscall_shim` is the widest-fanout PARTIAL subject in Table 3 (every in-tree `.pdx` binary consumes it). Coverage stopping at sysno 95 blocks issues #17, #23, #25, #26, #27, #28, #29, #30 from being implemented cleanly (each currently forces the caller to inline `mov rax, N; syscall`). A single wave that (a) enumerates every landed kernel handler in sysnos 40..115, (b) adds a wrapper per, (c) lands the `tools/verify-syscall-shim-coverage.sh` gate against future drift unlocks the entire "in-tree binary polish" cohort in one motion. Expected size: ~30 new wrappers, all mechanical, small blast radius (add-only). One softarch batch + debugger verify.

### Option 2 — `rootfs_seed` promotion + submodule adoption
Land issues **#13** (adopt `tools/user/shell` as submodule) + **#17** (promote /bin/ls/cat/ps/mount to real ELFs) + **#18** (expand manifest). Rationale: fastest visible-in-boot user impact — today, `sh` running `ls` on a fresh persistent FS immediately fails on ELF parse (real ELFs are only kernel-seeded for /bin/sh and /bin/true). This gives the shell a genuinely usable coreutils set at first boot. Cost: modest coordination with build-user.sh; must confirm authoritative source per `/bin/*` (in-tree vs. satellite) per hazard #33 before promoting.

Not recommended for Wave 7: `libpdx-net` (still 22 open + no crypto substrate work needed → too big a wave), `libpdx-elevate`↔`libpdx-audit#31` (single-issue, book as Wave 7.5), R102 GUI cluster (kernel-side substrate ready but userland scaffolds are 9-way scaffolds → too many parallel batches for one wave).

---

## Notes on this snapshot

- **Three v1.0.0 tags unmasked as schedule-closure.** `cat`/`mv`/`doc`'s 1.0.0 milestones were milestone-schedule closures, not proof-of-function. Debugger discipline going forward: every 1.0.0 tag needs a QEMU end-to-end fixture that proves the linked ELF does the tool's advertised primary op end-to-end before the tag can ship. Add this as a `paideia-as release --sign` precondition when R32 root key + signing substrate land.
- **Structural hazard on in-tree vs. satellite duplication** (#33) is the highest-severity architectural finding of this refresh. Without a design-doc-level cutover plan, every future landing to `src/user/*.pdx` silently drifts from its `tools/user/<name>/` twin.
- **`elevate_broker_daemon` promotion is unowned.** Explicit stub since R48-PREP-005.M2 (2026-08-22); no issue tracks M3/M4. Issue #23 books this.
- **`syscall_shim` is the sleeper bottleneck.** Not visible in per-repo backlog counts because it's a single in-tree file with no gh repo of its own; but it's the widest-fanout PARTIAL subject in Table 3. Wave 7 Option 1 addresses.

_Last refreshed: 2026-09-12 (fifth refresh — osarch re-scope wave; 3 v1.0.0 regressions unmasked; pdxsock promoted; tools/user/shell surfaced; 33 new issues recommended)._ — send the `ECOTABLE` command to Claude Code in this project to rebuild.
