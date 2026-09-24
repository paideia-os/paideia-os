# PaideiaOS Ecosystem Status

**Snapshot:** 2026-09-23 (seventh refresh — post semantic-shell materialization planning; R119 shell-pipe milestone landed end-to-end; paideia-as v0.36.4 + v0.36.5 tagged; 35 tracking issues filed for the R119-R141 / R220-R229 semantic-shell arc).
**Refresh command:** `ECOTABLE` — three-table shape (libraries / tools / reverse-dependency matrix) preserved from the 2026-09-12 restructure.

This document is a cross-repo readiness map: every library and every tool that ships in the PaideiaOS image, scored on the same 4-level maturity scale, sorted so the highest-blast-radius under-built repos surface first. A Semantic-Shell Materialization overlay tracks the R119-R141 / R220-R229 arc at the top of the document.

## Semantic Shell Materialization (R119-R141 + R220-R229)

The semantic shell arc turns the shell from a UART-tethered REPL into a full multi-process, multi-stage, structured-pipeline environment. Two design artifacts drive it:

- `design/terminal/semantic-shell-materialization-plan.md` (osarch, 782L) — kernel + userland milestones R119-R141.
- `design/terminal/semantic-shell-language-plan.md` (softarch, 575L) — paideia-as language milestones R220-R229 required to author the shell in assembly with structured types.

**Progress overlay.**

| Milestone | Scope | Status | Notes |
|---|---|:-:|---|
| **R119** | shell pipe (`sys_pipe` + fd hygiene + redirect fix) | LANDED | `#2471` M1: `sys_pipe` kernel body + `pipe_backend` + fd-hygiene witnesses; sysno 22 dispatch arm; FILE_IDs 875-877. `#2472` M2: `#2469` redirect fix — 4 root causes fixed (conditional UART fast-path in `dispatch_write`; sys_dup2 + sys_write [3,32)→[0,32) gates; parent-side `apply_pre_dispatch_redirects`). `#2473` M3: pipe wire-up confirmed structurally correct at `#2451` landing; ENOSYS was solely because `sys_pipe` had no body. Added `shell pipe integrated ok stages=2` fingerprint. |
| **R121-R141** | multi-stage pipeline, background jobs, PID reap, signals, JSON pipe framing, cross-shell IPC, session lifecycle, etc. | PLANNED | 21 tracking issues filed. Blocked functionally by nothing; sequenced behind R119. |
| **R220.M4** | `Str::eq` in paideia-as | LANDED | v0.36.4. Closes `paideia-as#998b` + `#1418`. |
| **R220.M5** | `Str::hash` in paideia-as | LANDED | v0.36.4. Closes `paideia-as#998c` + `#1419`. |
| **R220.M6** | `HashMap<Str, u64>` two-tier resize | LANDED | v0.36.5. Closes `paideia-as#996b` + `#1420`. |
| **R220.M7** | closure-typed HashMap slot | IN FLIGHT | softarch active. |
| **R220.M8** | effect-row inference | IN FLIGHT | softarch active. Closes `paideia-as#1356`. |
| **R220.M1-M3, M9-M12** | remaining paideia-as core-type work | PLANNED | Tracked in R220 umbrella. |
| **R221-R229** | paideia-as milestones supporting shell authoring (pattern matching, ADT ergonomics, module system extensions, effect handlers, etc.) | PLANNED | 10 tracking issues filed. |

**Roll-up.** R119 fully LANDED (3/3 milestones). R220 at 3/12 LANDED (M4, M5, M6) + 2/12 IN FLIGHT (M7, M8) + 7/12 PLANNED. R121-R141 all PLANNED (21 issues). R221-R229 all PLANNED (10 issues).

## Delta since 2026-09-13 (sixth refresh)

- **R119 landed end-to-end.** `sys_pipe` kernel body + `pipe_backend` (`#2471`); redirect fd-inheritance fix (`#2472`, closes `#2469`); shell pipe wire-up confirmation + `stages=2` fingerprint (`#2473`, closes `#2470`). This retires the last standing "structural syscall-body gap" in the shell/pipe path.
- **New blocker: `paideia-os#2494` UART RX race.** Discovered while writing dynamic acceptance witnesses for `#2469` / `#2470`. Blocks dynamic (as opposed to fingerprint-only) acceptance of the redirect/pipe fixes; the fixes themselves are correct and the fingerprint witnesses fire, but human/QEMU-driven interactive verification cannot yet be trusted end-to-end. Filed as its own issue.
- **paideia-as tagged twice.** v0.36.4 (`Str::eq` + `Str::hash`, R220.M4+M5) → v0.36.5 (`HashMap<Str, u64>` two-tier resize, R220.M6). Both bumps pulled into paideia-os via submodule bumps (`5379007`, `cb9bdc9`). paideia-as scored **MATURE (v0.36.5)** this refresh; the God-file refactor phase 2 remains ongoing.
- **Semantic-shell arc formally opened.** 35 tracking issues filed: R119 (already closed by landings above), R121-R141 (21 osarch issues), R220-R229 (10+ softarch issues covering the paideia-as core-types + language-feature work the shell needs to be re-authored in assembly with structured types + effect rows). Design docs `semantic-shell-materialization-plan.md` (osarch, 782L) and `semantic-shell-language-plan.md` (softarch, 575L) committed to `design/terminal/`.
- **Coreutil no-slash + multi-arg fixes.** `#2462`–`#2466` closed a family of "no-slash relative path" + "multi-arg POSIX invocation" + "echo real path/bytes" defects across `sys_unlink`, `sys_rmdir`, `sys_mkdir`, `sys_chdir`, `sys_rename`, and the `mkdir` / `touch` / `rm` / `mv` / `cp` in-tree binaries. `sys_chdir` now queries the tmpfs backend for authoritative vnode type (`7822b43`); `sys_rename` handles no-slash paths + the `mv` prefix off-by-one (`ea868e3`).
- **Shell `execve` failure diagnostic.** `#2468` (`0e411eb`): shell now emits `sh: <cmd>: not found` on failed `execve`, replacing a silent-exit path that masked a class of user-visible errors.
- **Delta housekeeping.** The 2026-09-13 refresh's three "hardware-only R113.M8 witnesses" (`#2418`–`#2420`) remain open and hardware-gated — untouched this cycle by design. The in-tree-vs-satellite hazards (`cat/cp/mkdir/mv/rm/ls` coreutils; compositor stack) also remain untouched; none were on the critical path.

## Legend

| Level | Symbol | Meaning |
|---|:-:|---|
| STUB | 🔴 | Scaffold only, does not execute; or explicit stub-reply for the primary op. |
| PARTIAL | 🟡 | Real body for some surfaces; a named milestone, op, or code path is still stub/WEAK-stub. |
| FUNCTIONAL | 🟢 | Executes its primary use case correctly end-to-end; gaps are in polish, secondary flags, or an explicitly disclosed sub-feature. |
| MATURE | 🟢+ | Tagged release + real test/consumer story + no self-disclosed correctness or scope gap. |

Sort within each table: **Maturity ASC** (STUB first), then **Dependent count DESC**.

**OS changes needed** counts *open* issues in `paideia-os/paideia-os` this subject requires before finishing its own milestones. The monorepo carries **4 open issues** relevant to scoring: `#2418`–`#2420` (R113.M8 hardware-only witnesses; block no subject below) and `#2494` (UART RX race — blocks dynamic acceptance of R119.M2/M3 but not the fingerprint witnesses that already fire).

---

## Table 1 — Libraries

| Repo | Maturity | Status | Dependent repos | OS changes | Summary |
|---|:-:|:-:|---|:-:|---|
| [`libpdx-config`](https://github.com/paideia-os/libpdx-config) | STUB | 🔴 | 3 (pkg, shell, pdxtrust) | 0 | Bare `/etc` key=value/[section] parser. Earliest-stage repo in the org — unchanged this cycle. |
| [`libpdx-net`](https://github.com/paideia-os/libpdx-net) | PARTIAL | 🟡 | 9 (fetch, pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust, remote, pkg) | 0 | **v0.5.0.** Real TCP/endian/`inet_pton`/DNS query-parse substrate; crypto layer (Ed25519 verify, ChaCha20-Poly1305) still scaffold. Widest-fanout under-built library. |
| [`libpdx-semantic-pipe`](https://github.com/paideia-os/libpdx-semantic-pipe) | FUNCTIONAL | 🟢 | 17 | 0 | **v1.1.1.** Real `Registry.bind`, wire-version end-to-end, golden wire-format fixture. Own "release honesty" walk-back norm intact. |
| [`libpdx-schema-registry`](https://github.com/paideia-os/libpdx-schema-registry) | FUNCTIONAL | 🟢 | 10 | 0 | Real register/lookup/list, content-hash dedup, elevate-gated writes; no version tag cut despite substantive M2–M4 features. |
| [`libpdx-audit`](https://github.com/paideia-os/libpdx-audit) | FUNCTIONAL | 🟢 | 10 | 0 | **v1.1.1.** Real file-sink + `audit_append_leaf`; recent ship→revert→re-fix stability tremor holding steady. |
| [`libpdx-elevate`](https://github.com/paideia-os/libpdx-elevate) | FUNCTIONAL | 🟢 | 8 | 0 | **v1.1.2** (HEAD reads 1.2.0). Real `cap_narrow`, broker witness, fail-closed logic, idle cap-reap; signing still stubbed. |
| [`libpdx-font`](https://github.com/paideia-os/libpdx-font) | FUNCTIONAL | 🟢 | 6 | 0 | **v1.0.1-src.** 8x16/16x32 glyph rendering + metrics + UTF-8 fallback; unsigned source-form. |
| [`libpdx-gfx`](https://github.com/paideia-os/libpdx-gfx) | FUNCTIONAL | 🟢 | 6 | 0 | **v1.0.0-src.** `KIND_SURFACE` fill-rect/line/glyph primitives; unsigned source-form. |
| [`postui`](https://github.com/paideia-os/postui) | FUNCTIONAL | 🟢 | 6 | 0 | **postui-v1.0.0.** Full 30-variant widget smoke matrix, real downstream consumers. |
| [`libpdx-url`](https://github.com/paideia-os/libpdx-url) | FUNCTIONAL | 🟢 | 5 | 0 | **v1.0.0-src.** RFC 3986 parsing + xorshift64 fuzz; unsigned source-form. |
| [`libpdx-event`](https://github.com/paideia-os/libpdx-event) | FUNCTIONAL | 🟢 | 4 | 0 | **v1.0.1-src.** Real blocking `event_next`, subscribe/poll, focus-cache. |
| [`libpdx-volume`](https://github.com/paideia-os/libpdx-volume) | FUNCTIONAL | 🟢 | 3 | 0 | **v1.1.5.** Snapshots, quotas, encryption, multivol all real; sig-verify remains stub. |
| [`paideia-as`](https://github.com/paideia-os/paideia-as) | MATURE | 🟢+ | 42 (every satellite) | 0 | **v0.36.5.** `Str::eq` + `Str::hash` (v0.36.4), `HashMap<Str, u64>` two-tier resize (v0.36.5) — R220.M4+M5+M6 landed. God-file refactor phase 2 ongoing. R220.M7/M8 IN FLIGHT. |
| [`libpdx-cap`](https://github.com/paideia-os/libpdx-cap) | MATURE | 🟢+ | 30 (every tool) | 0 | **v1.1.0.** Real runnable test harness, exec-time reconciliation client, migration guide. |
| [`libpdx-argv`](https://github.com/paideia-os/libpdx-argv) | MATURE | 🟢+ | 26 | 0 | **v1.2.0.** Subcommand dispatch, enum validation, overflow/null-page hardening. |

---

## Table 2 — Tools (satellite + in-tree merged)

`sat` = git submodule or unadopted satellite clone under `tools/user/` (or a standalone org repo); `in-tree` = `src/user/<name>.pdx`; `both` = duplicated across the two shipping models.

| Repo/Binary | Location | Maturity | Status | OS changes | Summary |
|---|:-:|:-:|:-:|:-:|---|
| `postui-desktop` | in-tree | STUB | 🔴 | 0 | Skeleton `entry.pdx` + launcher/status-bar/terminal-widget modules; `init` never forks/execves it; excluded from `tools/build-user.sh` link step. |
| [`svc-compositor`](https://github.com/paideia-os/svc-compositor) | sat | PARTIAL | 🟡 | 0 | **v1.4.0.** Real window table, damage/commit decode, 60Hz render loop, focus-routed input pump, screenshot/query; scanout blit still WEAK-stub. Does not yet consume the kernel-side `KIND_SURFACE`/`KIND_FRAMEBUFFER`/`KIND_SEAT` wiring. |
| [`svc-wm`](https://github.com/paideia-os/svc-wm) | sat | PARTIAL | 🟡 | 0 | **v1.1.0-src.** Real tiling, decoration, Alt+Space/Alt+Tab/Alt+F4 dispatch; `KIND_INPUT_FOCUS` mint floor-only/ENOSYS on a documented kernel syscall-arity gap. |
| `compositor` (in-tree library) | in-tree | PARTIAL | 🟡 | 0 | 35 real PWP-vocabulary modules + 25 unit/integration tests + complete kernel cap_invoke wiring — but no `fn main` anywhere, excluded from link step. Real code, zero linked entry point. |
| [`mkfs.pdxfs`](https://github.com/paideia-os/mkfs.pdxfs) | sat | PARTIAL | 🟡 | 0 | Tag stuck at `r64v2-closed` (CHANGELOG at 1.1.5). Core format + `--dry-run` real; elevate gate on block-device format still refusal-emit stub. |
| [`fetch`](https://github.com/paideia-os/fetch) | sat | PARTIAL | 🟡 | 0 | **v1.0.0.** Real HTTP/1.1 GET over raw TCP, IPv4-literal only; no HTTPS/redirects/POST. |
| [`pdxclock`](https://github.com/paideia-os/pdxclock) | sat | PARTIAL | 🟡 | 0 | **v1.2.0.** Real argv/render/close-on-quit/semantic-pipe logic; window-request + blit still WEAK-stub. |
| [`pdxdig`](https://github.com/paideia-os/pdxdig) | sat | PARTIAL | 🟡 | 0 | **v1.4.0.** Real CLI surface; actual query resolution is a WEAK-stub sentinel. |
| [`pdxping`](https://github.com/paideia-os/pdxping) | sat | PARTIAL | 🟡 | 0 | **v1.2.0.** Real CLI/schema/audit scaffolding; elevate fail-closed, ICMP echo fixed-RTT WEAK-stub. |
| [`pdxterm`](https://github.com/paideia-os/pdxterm) | sat | PARTIAL | 🟡 | 0 | **v1.3.0.** Real grid, ANSI/CSI/SGR parser, scrollback, keyboard LUT; `KIND_PTY` spawn discloses "no dispatch body in kernel tree yet." |
| [`pdxwatch`](https://github.com/paideia-os/pdxwatch) | sat | PARTIAL | 🟡 | 0 | **v1.2.3.** CPU/mem widget bars render into own framebuffer; not link-wired to `libpdx-gfx`/`libpdx-font`. |
| [`ping`](https://github.com/paideia-os/ping) | sat | PARTIAL | 🟡 | 0 | **v0.5.0 / r80-closed.** DNS-resolve + ICMP-echo explicit WEAK stubs. |
| `rootfs_seed` | in-tree | PARTIAL | 🟡 | 0 | `/bin/ls`, `/bin/cat`, `/bin/ps` are real embedded ELFs; `/bin/mount` + `/bin/true` remain 9-byte stubs. Manifest frozen at 7 entries. |
| `elevate_broker_daemon` | in-tree | PARTIAL | 🟡 | 0 | M3 landed: real 8-slot policy-table scan for `ELV_OP_REQ`. `ELV_OP_APR`/`ELV_OP_EXP` remain M2 stub replies. |
| `mkdir` | both | PARTIAL | 🟡 | 0 | **v1.4.0.** Core single-dir create + `--json` real. Multi-arg POSIX invocation landed via `#2465` (`5730e0a`); `-p`/`-m` still planning-only. |
| [`edit`](https://github.com/paideia-os/edit) | sat | FUNCTIONAL | 🟢 | 0 | **v0.6.0.** Gap buffer, raw-mode TTY, dirty-line render, modal `:w`/`:q`/`:wq`/`:e`. |
| [`line`](https://github.com/paideia-os/line) | sat | FUNCTIONAL | 🟢 | 0 | **v1.2.0.** ed-style REPL closed end-to-end. |
| [`pdxcurl`](https://github.com/paideia-os/pdxcurl) | sat | FUNCTIONAL | 🟢 | 0 | **v1.4.1.** Real GET/POST, `--output`, `--data`, redirect matrix; TLS wrap WEAK-stub blocked on R32. |
| [`pdxpaint`](https://github.com/paideia-os/pdxpaint) | sat | FUNCTIONAL | 🟢 | 0 | **v1.1.0.** 640x480 canvas, Bresenham strokes, palette, undo ring. |
| [`pdxtrust`](https://github.com/paideia-os/pdxtrust) | sat | FUNCTIONAL | 🟢 | 0 | **v1.2.0.** Import/list/show/remove, duplicate-import gate, audit + semantic-pipe wire; FNV-1a-64 hash still placeholder for BLAKE3. |
| [`remote`](https://github.com/paideia-os/remote) | sat | FUNCTIONAL | 🟢 | 0 | **v0.5.0 / r85-closed.** Real ML-KEM-768 handshake + ChaCha20-Poly1305 remote shell + rcopy. rdtsc-derived KEM randomness disclosed. |
| [`doc`](https://github.com/paideia-os/doc) | both | FUNCTIONAL | 🟢 | 0 | **v1.1.0.** Real render loop, `--pager`, `--color`, schema-wire. |
| [`shell`](https://github.com/paideia-os/shell) | both | FUNCTIONAL | 🟢 | 1 | Tag **v1.0.0** (stale — walked back in shell#37; manifest reads 0.2.0). Real REPL, fork/exec, job control, tab completion, history, line editing. Adopted as `.gitmodules` submodule. |
| [`pdxsock`](https://github.com/paideia-os/pdxsock) | sat | FUNCTIONAL | 🟢 | 0 | **v1.2.2.** UDP client, TCP mirror-echo, non-blocking poll drain, 128KiB large-transfer. |
| [`cat`](https://github.com/paideia-os/cat) | both | FUNCTIONAL | 🟢 | 0 | **v1.2.1-A.** Real `_start`/argv/open/read/write, schema-wire, semantic-pipe, 7-row errno fixture. |
| [`mv`](https://github.com/paideia-os/mv) | both | FUNCTIONAL | 🟢 | 0 | **v1.3.0.** Real `sys_rename`, multi-source, cwd-relative, `-i`, txn wire. Prefix off-by-one closed via `#2462` (`ea868e3`); real byte-count echo via `#2466` (`d31b3fb`). |
| [`rm`](https://github.com/paideia-os/rm) | both | FUNCTIONAL | 🟢 | 0 | **v1.3.0.** Real recursive walker + `sys_unlink`/`sys_rmdir`; SECURITY fail-closed EACCES. Multi-arg POSIX invocation landed via `#2465`. |
| [`cp`](https://github.com/paideia-os/cp) | both | FUNCTIONAL | 🟢 | 0 | Tag v1.2.0 (CHANGELOG at 1.3.0 — tagging drift). Real `cp -r` walker + outer TXN wrap. Real byte-count echo via `#2466`. |
| [`ls`](https://github.com/paideia-os/ls) | both | FUNCTIONAL | 🟢 | 0 | **v1.3.0.** Real cwd-relative resolve, `-R` recursion, `LsListRecord@0.1` semantic-pipe wire. |
| [`mount.pdxfs`](https://github.com/paideia-os/mount.pdxfs) | sat | FUNCTIONAL | 🟢 | 0 | `r64v2-closed`. Real dry-run gate + mount-point resolvability ordering fix. |
| [`umount.pdxfs`](https://github.com/paideia-os/umount.pdxfs) | sat | FUNCTIONAL | 🟢 | 0 | `r64v2-closed`. Real fail-closed elevate gate on `/system` unmount. |
| [`pkg`](https://github.com/paideia-os/pkg) | sat | FUNCTIONAL | 🟢 | 0 | **v1.3.0.** Real install/remove/list, dry-run, dual ML-DSA-65 verification, txn-scoped unlink. |
| [`postui-dmesg`](https://github.com/paideia-os/postui-dmesg) | sat | FUNCTIONAL | 🟢 | 0 | Real kernel-log tail/page UI; severity-band + LEVEL_* mislabels fixed. |
| [`postui-hex`](https://github.com/paideia-os/postui-hex) | sat | FUNCTIONAL | 🟢 | 0 | Real hex-dump viewer; OOB info-disclosure + default I/O buffer fixed. |
| [`postui-top`](https://github.com/paideia-os/postui-top) | sat | FUNCTIONAL | 🟢 | 0 | Real sparkline/top view; stride-vs-Rect.w clamp bug caught pre-live. |
| `init` | in-tree | FUNCTIONAL | 🟢 | 0 | Three real fork+execve cycles; PID-1 shutdown fixed to panic-or-halt. Hardcoded 3-daemon manifest, no supervisor/respawn. |
| `syscall_shim` | in-tree | FUNCTIONAL | 🟢 | 0 | Coverage through sysno 118 (incl. `sys_pipe` at 22 landed R119.M1). `sys_ipc_recv`/`sys_ipc_reply`/`sys_mkdir` still inlined by two callers. |
| `tokenizer` | in-tree | FUNCTIONAL | 🟢 | 0 | Quote/escape/`$VAR` expansion landed. `;`/`&`/`\|` operators still absent — sequenced into R121-R141. |
| `shell` (in-tree) | both | FUNCTIONAL | 🟢 | 0 | Line editing landed; **redirect fd-inheritance fixed** via `#2472` (`30e784f`); **pipe wire integrated ok stages=2** via `#2473` (`e626cbf`). `sh: <cmd>: not found` diagnostic via `#2468` (`0e411eb`). Semantic-shell arc R121-R141 planned. |
| `ls` (in-tree) | both | FUNCTIONAL | 🟢 | 0 | `-a`/`-l`/`-1`/`-F` flag suite. |
| `ps` | in-tree | FUNCTIONAL | 🟢 | 0 | `-a`/`-e`/`-f` flag suite. |
| `touch` | in-tree | FUNCTIONAL | 🟢 | 0 | Multi-arg POSIX invocation via `#2465`; still one-file-at-a-time semantics per invocation-argument, no `utime`. |
| `dispatch` | in-tree | MATURE | 🟢+ | 0 | 7+ builtins, PATH-prefix resolve, envp-sourced PATH, `exec_child` with redirects, `sys_getdents`-based `help /bin`. |

**Not scored here:** `builtins`, `child_hello`, `echo_client`, `echo_server`, `errno`, `founder_constants`, `io`, `string`, `true`, `pci_enumerator`, `acpi_supervisor`, `audio_supervisor`, `dmesg` — helper modules, test binaries, or supervisor daemons outside the CLI/GUI-tool re-scope.

---

## Table 3 — Reverse-dependency matrix (who consumes what)

| Producer | CLI tools | Filesystem tools | Elevate stack | Net stack | GUI/TUI | shell/dispatch |
|---|---|---|---|---|---|---|
| **`paideia-as`** | all | all | all | all | all | all |
| **`libpdx-cap`** | every tool | mkfs, mount, umount | libpdx-elevate, libpdx-audit | pdxsock, pdxcurl, pdxping | postui, svc-compositor, svc-wm | shell (sat/in-tree), dispatch |
| **`libpdx-argv`** | cat, cp, mv, rm, mkdir, ls, ps, touch, doc | mkfs, mount, umount | — | pdxsock, pdxcurl, pdxdig | — | shell (sat) |
| **`libpdx-audit`** | rm, mv, cp | mkfs, mount, umount | libpdx-elevate | pdxcurl, pdxping | — | — |
| **`libpdx-elevate`** | rm | mkfs, mount, umount | elevate_broker_daemon (in-tree, IPC) | pdxping, pdxcurl | — | — |
| **`libpdx-net`** | fetch | — | — | pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust, remote, pkg | — | — |
| **`libpdx-semantic-pipe`** | every schema-emitting tool | mkfs, mount, umount | libpdx-elevate | pdxsock, pdxcurl, pdxdig | postui | shell (sat), dispatch |
| **`postui`** | — | — | — | — | postui-dmesg, postui-hex, postui-top, edit, doc | shell (sat) |
| **`libpdx-gfx`, `libpdx-font`, `libpdx-event`** | — | — | — | — | svc-compositor, svc-wm, pdxterm, pdxclock, pdxwatch, pdxpaint | — |
| **`syscall_shim` (in-tree)** | every in-tree `.pdx` binary | rootfs_seed | elevate_broker_daemon | echo_client, echo_server | compositor (in-tree lib) | shell (in-tree), init, dispatch |
| **`sys_pipe` + `pipe_backend` (kernel, R119)** | — | — | — | — | — | shell (in-tree, integrated `stages=2`); consumer surface widens once R121-R141 land |
| **`compositor` (in-tree lib, unlinked)** | — | — | — | — | postui-desktop (skeleton, unspawned) | — |
| **`rootfs_seed` payloads** | ls, cat, ps (real ELFs) | mount (still stub bytes) | — | — | — | sh (kernel-seeded real ELF) |

**Reading the matrix.**
- **`libpdx-net`** (9 consumers, PARTIAL) is still the single widest-fanout under-built subject in the ecosystem — every R100 net-facing CLI stays capped at PARTIAL until its TLS/crypto layer lands.
- **The compositor stack** remains real on both legs (kernel + satellite) but reconciled on neither. Untouched this cycle; sequenced behind the semantic-shell arc.
- **`elevate_broker_daemon`** still PARTIAL at M3; every `libpdx-elevate` consumer waits on `ELV_OP_APR`/`ELV_OP_EXP` for the full approve/expire lifecycle.
- **R119's pipe backend** appears as a new row: currently a single-consumer producer (in-tree shell). R121-R141 fan this out to every semantic-pipeline participant (multi-stage, JSON framing, cross-shell IPC).

---

## Notes on this snapshot

- **Semantic-shell arc opens.** With R119 fully landed, the shell can now execute `a | b` end to end. R121-R141 (osarch, 21 issues) plus R220-R229 (softarch, 10 issues) constitute the next multi-milestone push, formally sequenced and issue-tracked; R220 is the paideia-as blocker column (3/12 LANDED, 2/12 IN FLIGHT) — the shell cannot be re-authored in structured assembly until M4-M8 stabilize.
- **`#2494` UART RX race is a new class of blocker.** Not a syscall gap, not a body stub — a timing race that prevents dynamic (interactive) acceptance of R119.M2/M3 even though the fingerprint witnesses fire. Filed as its own paideia-os issue; must be closed before the semantic-shell arc's interactive milestones become acceptance-testable.
- **paideia-as version discipline held twice this cycle.** Both v0.36.4 and v0.36.5 followed the "workspace.version + git tag + CHANGELOG entry move together" rule; both pulled into paideia-os via clean submodule bumps.
- **The remaining monorepo backlog is 4 issues.** `#2418`–`#2420` remain hardware-gated (R113.M8). `#2494` is the only new software-side blocker on the critical path — and only for interactive acceptance, not for fingerprint witnessing.

_Last refreshed: 2026-09-23 (seventh refresh — R119 shell-pipe milestone LANDED; paideia-as v0.36.4 + v0.36.5 tagged; 35-issue semantic-shell arc (R119-R141 / R220-R229) opened; `#2494` UART RX race filed as new interactive-acceptance blocker)._ — send the `ECOTABLE` command to Claude Code in this project to rebuild.
