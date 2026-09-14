# PaideiaOS Ecosystem Status

**Snapshot:** 2026-09-13 (sixth refresh — post-mega-session: ~150 issues landed across 35+ dispatch waves since the 2026-09-12 refresh; paideia-os monorepo alone closed 111 issues, dropping from 10 open to 3; every one of the 46 satellite repos surveyed now sits at 0-1 open issues).
**Refresh command:** `ECOTABLE` — three-table shape (libraries / tools / reverse-dependency matrix) preserved from the 2026-09-12 restructure.

This document is a cross-repo readiness map: every library and every tool that ships in the PaideiaOS image, scored on the same 4-level maturity scale, sorted so the highest-blast-radius under-built repos surface first.

## Delta since 2026-09-12 (fifth refresh)

- **paideia-os monorepo: 10 open → 3 open.** The remaining three (`#2418`–`#2420`) are all R113.M8 real-hardware witnesses (external-USB-keyboard smoke, direct-scanout, multi-surface composite — all on a physical T14/Iris Xe unit). Nothing in kernel, compositor, or QEMU smoke path blocks them; they are pure operator-driven hardware-in-loop verification (`design/hardware/t14-real-hw-smoke-scope.md`). R113 GPU-native compositor milestones M1–M7 are formally closed (36/40 issues); `#2380` closed as a docs-only umbrella retrospective.
- **Org-wide backlog drain.** All 14 libraries and all 32 satellite tool repos surveyed this refresh report **0 open issues** (one exception: `mkfs.pdxfs` at 1). This is a genuine clean-backlog snapshot, not an artifact of missed search — verified via `gh issue list --state open` per repo.
- **The cat/mv/rm/doc "schedule-closure" walk-backs (flagged 2026-09-12) are now genuinely recovered upstream.** Each had an explicit in-repo walk-back commit ("v1.0.0 emits no linked ELF, executes no syscall" / "zero syscalls, undefined entry symbol") followed by real `_start` + syscall-body landings and fresh tags: `cat` v1.2.1-A, `mv` v1.3.0, `rm` v1.3.0 (+ SECURITY fail-closed EACCES), `doc` v1.1.0 (fixed the actual multi-page render-loop bug, not just re-tagged). **Caveat:** this monorepo's pinned submodule SHAs for `cat`/`cp`/`mv`/`rm`/`doc`/`shell`/`libpdx-argv` still point at commits near their old v1.0.0/v1.1.0 tags — the upstream recovery exists but has **not yet been pulled** into this tree's submodule pins. Since none of these ship via the satellite path today (boot uses the `src/user/*.pdx` in-tree twins), this is a housekeeping gap, not a boot-blocking one — but it must be bumped before any in-tree→satellite cutover.
- **`shell` (satellite) moved furthest without its tag catching up.** v1.0.0 was walked back in prose (shell#37: "a wire-format encoder suite … zero syscalls"), but since then real `shell_main`+REPL, fork/exec, job control (bg/fg/jobs), tab completion, history, and line editing all landed. Tag is still v1.0.0; manifest reads 0.2.0. **Do not score this repo from its tag.** The satellite is now formally adopted as a `.gitmodules` submodule (Wave 20, fix `paideia-os#2438`) — the standing "not adopted" hazard from the last refresh is closed.
- **A second, unreconciled compositor implementation surfaced.** The satellite `svc-compositor` (v1.4.0) and `svc-wm` (v1.1.0-src) independently landed real window-table/tiling/render-loop/input-pump bodies this session — but **neither repo's commit history references** the concurrent kernel-side backtrack (`sys_sched_wait_ns` timer wheel, `KIND_A11Y_NODE` dispatch, `KIND_FRAMEBUFFER`/`KIND_SEAT` cap handlers, `KIND_SURFACE` mint-argument packing) or the 25 new kernel-tree unit/integration tests under `tests/kernel/{compositor,postui-desktop}/`. That kernel-tree work backs a **separate, in-tree** compositor: `src/user/compositor/*.pdx` (35 library modules — surface_commit, layer_tree, tiling_bsp, damage_kind, etc., the "PWP" vocabulary). Both are real code; **neither is a bootable desktop.** The in-tree library has no `fn main` anywhere and `tools/build-user.sh` explicitly excludes `compositor/`, `a11y/`, `color/`, `ime/`, `input_server/`, `ui/` from the link step; `postui-desktop`'s `entry.pdx` is a skeleton that `init` never forks/execves. This is a second instance of the in-tree-vs-satellite hazard (#33 from the last refresh, which only enumerated `cat/cp/mkdir/mv/rm/dispatch/tokenizer`) — recommend extending `design/user/in-tree-vs-satellite-transition.md` to cover the compositor stack.
- **A third undocumented duplicate pair: `ls`.** The satellite `paideia-os/ls` repo (not previously tracked in the transition doc) is now at v1.3.0 with real cwd-relative resolve, `-R` recursion, and an `LsListRecord@0.1` semantic-pipe wire — ahead of the in-tree `ls.pdx`, which only gained its flag suite (Waves 9+10) this session. Not adopted as a submodule; boot still uses the in-tree copy.
- **In-tree binaries moved substantially.** `syscall_shim` coverage widened from stopping-at-95 to including sysno 118 (`sys_sendto`, `cap_reconcile_at_exec`) via a 22-wrapper wave (`cd97f77`) — reclassified PARTIAL → FUNCTIONAL. `rootfs_seed` promoted `/bin/ls`, `/bin/cat`, `/bin/ps` from 9-byte stub payloads to real embedded ELFs (R113 `#2441`); `/bin/mount` and `/bin/true` remain 9-byte stubs — still PARTIAL, but 2-of-7 stub rather than 4-of-7. `tokenizer` gained quote/`\`-escape/`$VAR` expansion (Wave 17, fix `#2457`) — PARTIAL → FUNCTIONAL (pipe/`;`/`&` operators still absent). `shell` (in-tree) gained line editing (Wave 14, fix `#2450`). `init`'s PID-1 shutdown path was fixed from a silent `sys_exit(0)` to panic-or-halt (Wave 19, fix `#2442`) — a real correctness fix, since PID-1 exiting "successfully" masked boot failures. `elevate_broker_daemon` gained a real M3 policy-table dispatch for `ELV_OP_REQ` (Wave LL) — STUB → PARTIAL; `ELV_OP_APR`/`ELV_OP_EXP` remain M2 stub replies.
- **MATURE bar tightened.** This refresh scores MATURE only where a repo combines a real tagged release, a clean test/consumer story, and no known correctness gap; several repos the 2026-09-12 refresh called 🟢+ (`libpdx-audit`, `libpdx-elevate`, `libpdx-volume`, `libpdx-schema-registry`, `libpdx-semantic-pipe`, `postui`, `mkfs.pdxfs`, `mount.pdxfs`, `umount.pdxfs`, `pkg`) are rescored FUNCTIONAL this cycle — each has a genuine, real implementation, but each also carries an explicit self-disclosed gap (stub signature verification, a recent revert/re-fix, an "unsigned/-src" release marker, or a stale-tag-vs-CHANGELOG drift). `libpdx-cap`, `libpdx-argv`, `paideia-as`, and `dispatch` (in-tree) keep MATURE — no self-disclosed gap surfaced for any of the four.
- **Tagging-discipline drift** (separate from functional maturity): `cp` (CHANGELOG at 1.3.0, tag still v1.2.0) and `mkfs.pdxfs` (CHANGELOG at 1.1.5, tag still `r64v2-closed`) have shipped code ahead of their last cut tag.

## Legend

| Level | Symbol | Meaning |
|---|:-:|---|
| STUB | 🔴 | Scaffold only, does not execute; or explicit stub-reply for the primary op. |
| PARTIAL | 🟡 | Real body for some surfaces; a named milestone, op, or code path is still stub/WEAK-stub. |
| FUNCTIONAL | 🟢 | Executes its primary use case correctly end-to-end; gaps are in polish, secondary flags, or an explicitly disclosed sub-feature. |
| MATURE | 🟢+ | Tagged release + real test/consumer story + no self-disclosed correctness or scope gap. |

Sort within each table: **Maturity ASC** (STUB first), then **Dependent count DESC**.

**OS changes needed** counts *open* issues in `paideia-os/paideia-os` this subject requires before finishing its own milestones. The monorepo carries **3 open issues** (`#2418`–`#2420`), all R113.M8 hardware-only witnesses; none gate any listed subject's own progress, so every row below reads 0.

---

## Table 1 — Libraries

| Repo | Maturity | Status | Dependent repos | OS changes | Summary |
|---|:-:|:-:|---|:-:|---|
| [`libpdx-config`](https://github.com/paideia-os/libpdx-config) | STUB | 🔴 | 3 (pkg, shell, pdxtrust) | 0 | Bare `/etc` key=value/[section] parser. 2 commits, no version tag — earliest-stage repo in the org. |
| [`libpdx-net`](https://github.com/paideia-os/libpdx-net) | PARTIAL | 🟡 | 9 (fetch, pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust, remote, pkg) | 0 | **v0.5.0.** Real TCP/endian/`inet_pton`/DNS query-parse substrate; crypto layer (Ed25519 verify, ChaCha20-Poly1305) explicitly still scaffold. |
| [`libpdx-semantic-pipe`](https://github.com/paideia-os/libpdx-semantic-pipe) | FUNCTIONAL | 🟢 | 17 | 0 | **v1.1.1.** Real `Registry.bind`, wire-version end-to-end, golden wire-format fixture. Own v1.1.0 commit titled "release honesty" — walked back an earlier overstated claim. |
| [`libpdx-schema-registry`](https://github.com/paideia-os/libpdx-schema-registry) | FUNCTIONAL | 🟢 | 10 | 0 | Real register/lookup/list, content-hash dedup, elevate-gated writes — but has never had a version tag cut despite substantive M2–M4 features. |
| [`libpdx-audit`](https://github.com/paideia-os/libpdx-audit) | FUNCTIONAL | 🟢 | 10 | 0 | **v1.1.1.** Real file-sink + `audit_append_leaf`; that primitive was shipped, reverted, and re-fixed in three consecutive commits this session — functional but shows recent instability. |
| [`libpdx-elevate`](https://github.com/paideia-os/libpdx-elevate) | FUNCTIONAL | 🟢 | 8 | 0 | **v1.1.2** (unreleased HEAD already reads 1.2.0). Real `cap_narrow`, broker witness, fail-closed logic, idle cap-reap; signing explicitly "STUB sigs pending v0.33 crypto." |
| [`libpdx-font`](https://github.com/paideia-os/libpdx-font) | FUNCTIONAL | 🟢 | 6 | 0 | **v1.0.1-src.** Real 8x16/16x32 glyph rendering + metrics + UTF-8 fallback, smoke-tested; explicitly "unsigned" source-form release. |
| [`libpdx-gfx`](https://github.com/paideia-os/libpdx-gfx) | FUNCTIONAL | 🟢 | 6 | 0 | **v1.0.0-src.** Real `KIND_SURFACE` fill-rect/line/glyph primitives, smoke-tested; unsigned source-form. |
| [`postui`](https://github.com/paideia-os/postui) | FUNCTIONAL | 🟢 | 6 (postui-dmesg/hex/top, shell, edit, doc) | 0 | **postui-v1.0.0.** Full 30-variant widget smoke matrix, real downstream consumers; last 8 pre-tag commits are stub→live flips. |
| [`libpdx-url`](https://github.com/paideia-os/libpdx-url) | FUNCTIONAL | 🟢 | 5 | 0 | **v1.0.0-src.** RFC 3986 parsing, real vector suite + xorshift64 fuzz target; unsigned source-form. |
| [`libpdx-event`](https://github.com/paideia-os/libpdx-event) | FUNCTIONAL | 🟢 | 4 | 0 | **v1.0.1-src.** Real blocking `event_next`, subscribe/poll, focus-cache; 5 integration-test drivers. |
| [`libpdx-volume`](https://github.com/paideia-os/libpdx-volume) | FUNCTIONAL | 🟢 | 3 | 0 | **v1.1.5.** Snapshots, quotas, encryption, multivol all real; sig-verify remains stub. |
| [`paideia-as`](https://github.com/paideia-os/paideia-as) | MATURE | 🟢+ | 42 (every satellite) | 0 | **v0.36.0.** Assembler compiler. 1 open issue. God-file refactor phase 2 ongoing. |
| [`libpdx-cap`](https://github.com/paideia-os/libpdx-cap) | MATURE | 🟢+ | 30 (every tool) | 0 | **v1.1.0.** Real runnable test harness (8-stage `CAP_BAD_SLOT` coverage), exec-time reconciliation client, migration guide. Caught and withdrew a bad v1.0.0 cut before shipping v1.0.1. |
| [`libpdx-argv`](https://github.com/paideia-os/libpdx-argv) | MATURE | 🟢+ | 26 | 0 | **v1.2.0.** Subcommand dispatch, enum validation, overflow/null-page hardening; 45 issues closed via consolidation waves. |

---

## Table 2 — Tools (satellite + in-tree merged)

`sat` = git submodule or unadopted satellite clone under `tools/user/` (or a standalone org repo); `in-tree` = `src/user/<name>.pdx`; `both` = duplicated across the two shipping models (see Delta above for the three known pairs: coreutils, `ls`, and the compositor stack).

| Repo/Binary | Location | Maturity | Status | OS changes | Summary |
|---|:-:|:-:|:-:|:-:|---|
| `postui-desktop` | in-tree | STUB | 🔴 | 0 | Skeleton `entry.pdx` + launcher/status-bar/terminal-widget modules and 5 real test files, but no process-spawn wire — `init` never forks/execves it; excluded from `tools/build-user.sh`'s link step. |
| [`svc-compositor`](https://github.com/paideia-os/svc-compositor) | sat | PARTIAL | 🟡 | 0 | **v1.4.0.** Real window table, damage/commit decode, 60Hz render loop, focus-routed input pump, screenshot/query; scanout blit is a WEAK-stub (canned 1920x1080). Does not yet consume the new kernel-side `KIND_SURFACE`/`KIND_FRAMEBUFFER`/`KIND_SEAT` cap-handler wiring. |
| [`svc-wm`](https://github.com/paideia-os/svc-wm) | sat | PARTIAL | 🟡 | 0 | **v1.1.0-src.** Real tiling (attach/detach/divide), decoration, Alt+Space/Alt+Tab/Alt+F4 dispatch; `KIND_INPUT_FOCUS` mint floor-only/ENOSYS on a documented kernel syscall-arity gap. |
| `compositor` (in-tree library) | in-tree | PARTIAL | 🟡 | 0 | 35 real PWP-vocabulary modules (`surface_commit`, `layer_tree`, `tiling_bsp`, `damage_kind`, …) backed by a now-complete kernel cap_invoke wiring (`KIND_SURFACE` mint packing, `KIND_FRAMEBUFFER`/`KIND_SEAT` handlers, `KIND_A11Y_NODE` dispatch, `sys_sched_wait_ns`) and 25 new unit/integration tests — but **no `fn main` exists anywhere in the directory** and it is explicitly excluded from the link step. Real code, zero linked entry point. |
| [`mkfs.pdxfs`](https://github.com/paideia-os/mkfs.pdxfs) | sat | PARTIAL | 🟡 | 0 | Tag stuck at `r64v2-closed` (CHANGELOG at 1.1.5 — drift). Core format + `--dry-run` real; elevate gate on block-device format is a refusal-emit stub, not real acquire/require (cross-repo blocked). 1 open (`#26`). |
| [`fetch`](https://github.com/paideia-os/fetch) | sat | PARTIAL | 🟡 | 0 | **v1.0.0.** Real HTTP/1.1 GET over raw TCP, IPv4-literal host only; no HTTPS/redirects/POST; 2 commits total. |
| [`pdxclock`](https://github.com/paideia-os/pdxclock) | sat | PARTIAL | 🟡 | 0 | **v1.2.0.** Real argv/render/close-on-quit/semantic-pipe logic; window-request + blit rendering are WEAK-stub pending confirmed compositor wiring. |
| [`pdxdig`](https://github.com/paideia-os/pdxdig) | sat | PARTIAL | 🟡 | 0 | **v1.4.0.** Real CLI surface + rcode/validate/loop-guard logic; actual query resolution is a WEAK-stub sentinel — no real DNS I/O yet. |
| [`pdxping`](https://github.com/paideia-os/pdxping) | sat | PARTIAL | 🟡 | 0 | **v1.2.0.** Real CLI/schema/audit scaffolding, smoke-tested against mocks; elevate gate fail-closed-always, ICMP echo fixed-RTT WEAK-stub — doesn't ping a real host end to end. |
| [`pdxterm`](https://github.com/paideia-os/pdxterm) | sat | PARTIAL | 🟡 | 0 | **v1.3.0.** Real grid, ANSI/CSI/SGR parser, scrollback, keyboard LUT, tested; `KIND_PTY` spawn request wired but discloses "no dispatch body in the kernel tree yet" — no real shell backend. |
| [`pdxwatch`](https://github.com/paideia-os/pdxwatch) | sat | PARTIAL | 🟡 | 0 | **v1.2.3.** Real CPU/mem widget bars render into their own framebuffer; not yet link-wired to `libpdx-gfx`/`libpdx-font`. A v1.2.2 hotfix retracted a fabricated consumer-integration claim. |
| [`ping`](https://github.com/paideia-os/ping) | sat | PARTIAL | 🟡 | 0 | **v0.5.0 / r80-closed.** DNS-resolve and ICMP-echo are explicit WEAK stubs (hardcoded 8.8.8.8, fixed 1ms RTT); closed CLOSED with the WEAK caveats retained, not resolved. |
| `rootfs_seed` | in-tree | PARTIAL | 🟡 | 0 | `/bin/ls`, `/bin/cat`, `/bin/ps` promoted to real embedded ELFs (R113 `#2441`, up from 4-of-7 stub); `/bin/mount` + `/bin/true` remain 9-byte `"R57 stub\n"` payloads. Manifest still frozen at 7 entries. |
| `elevate_broker_daemon` | in-tree | PARTIAL | 🟡 | 0 | M3 landed: real 8-slot policy-table scan for `ELV_OP_REQ` (allow/deny, fail-closed on no match). `ELV_OP_APR`/`ELV_OP_EXP` remain M2 stub replies (`ELVB_DISPATCH_STUB`). |
| `mkdir` | both | PARTIAL | 🟡 | 0 | **v1.4.0.** Core single-dir create + `--json` real and released; `-p`/`-m` are explicitly "planning only, no src/ changes." |
| [`edit`](https://github.com/paideia-os/edit) | sat | FUNCTIONAL | 🟢 | 0 | **v0.6.0.** Real gap buffer, raw-mode TTY, dirty-line render, save/load, modal `:w`/`:q`/`:wq`/`:e` colon commands. |
| [`line`](https://github.com/paideia-os/line) | sat | FUNCTIONAL | 🟢 | 0 | **v1.2.0.** ed-style REPL/buffer/fileio closed end-to-end (R63 closure retrospective). |
| [`pdxcurl`](https://github.com/paideia-os/pdxcurl) | sat | FUNCTIONAL | 🟢 | 0 | **v1.4.1.** Real GET/POST, `--output`, `--data`, redirect matrix, audit-only path, smoke tests; TLS wrap is WEAK-stub (plaintext even under `--trust=cap`), blocked on R32. |
| [`pdxpaint`](https://github.com/paideia-os/pdxpaint) | sat | FUNCTIONAL | 🟢 | 0 | **v1.1.0.** Real 640x480 canvas, Bresenham strokes, 8-swatch palette, 16-slot undo ring, save-roundtrip smoke tests. |
| [`pdxtrust`](https://github.com/paideia-os/pdxtrust) | sat | FUNCTIONAL | 🟢 | 0 | **v1.2.0.** Real import/list/show/remove, duplicate-import gate, audit + semantic-pipe wire, 3 real smoke tests. Hashing still FNV-1a-64 placeholder for BLAKE3. |
| [`remote`](https://github.com/paideia-os/remote) | sat | FUNCTIONAL | 🟢 | 0 | **v0.5.0 / r85-closed.** Real ML-KEM-768 handshake + ChaCha20-Poly1305 channel backing an actual remote shell + rcopy. Disclosed gap: rdtsc-derived (non-CSPRNG) KEM randomness. |
| [`doc`](https://github.com/paideia-os/doc) | both | FUNCTIONAL | 🟢 | 0 | **v1.1.0** (walked back from v1.0.0). Genuine recovery: fixed the real bug where the render loop ran once instead of iterating pages; added `--pager`, `--color`, schema-wire. |
| [`shell`](https://github.com/paideia-os/shell) | both | FUNCTIONAL | 🟢 | 1 | Tag **v1.0.0** (stale — walked back in shell#37; manifest reads 0.2.0). Real `shell_main`+REPL, fork/exec, job control, tab completion, history, line editing, `cd -`. Now adopted as a `.gitmodules` submodule (Wave 20). Do not score from the tag. |
| [`pdxsock`](https://github.com/paideia-os/pdxsock) | sat | FUNCTIONAL | 🟢 | 0 | **v1.2.2.** UDP client, TCP mirror-echo, non-blocking poll drain, 128KiB large-transfer + refuse-second tests all real and passing. Disclosed gap: no true full-duplex stdin↔socket. |
| [`cat`](https://github.com/paideia-os/cat) | both | FUNCTIONAL | 🟢 | 0 | **v1.2.1-A** (walked back from v1.0.0 — "emits no linked ELF, executes no syscall"). Real recovery: `_start`/argv/open/read/write, schema-wire, semantic-pipe, 7-row errno fixture. |
| [`mv`](https://github.com/paideia-os/mv) | both | FUNCTIONAL | 🟢 | 0 | **v1.3.0** (walked back from v1.0.0 — no `_start` frame). Real `sys_rename`, multi-source, cwd-relative, `-i`, txn wire. Elevate-cascade dispatcher wiring still deferred. |
| [`rm`](https://github.com/paideia-os/rm) | both | FUNCTIONAL | 🟢 | 0 | **v1.3.0.** Real recursive walker + `sys_unlink`/`sys_rmdir` body; v1.3.0 adds SECURITY fail-closed EACCES (exit 13). Txn status/free still stubbed pending syscall allocation. |
| [`cp`](https://github.com/paideia-os/cp) | both | FUNCTIONAL | 🟢 | 0 | Tag v1.2.0 (CHANGELOG at 1.3.0 — tagging drift). A real `cp -r` data-loss bug (exit 0, copied nothing) was found and fixed with a real recursive walker + outer TXN wrap. `-p` remains design-only. |
| [`ls`](https://github.com/paideia-os/ls) | both | FUNCTIONAL | 🟢 | 0 | **v1.3.0.** Real cwd-relative resolve, `-R` recursion (depth-capped 32), `LsListRecord@0.1` semantic-pipe wire. Not previously tracked as an in-tree/satellite pair — newly surfaced this refresh. |
| [`mount.pdxfs`](https://github.com/paideia-os/mount.pdxfs) | sat | FUNCTIONAL | 🟢 | 0 | `r64v2-closed`. Real dry-run gate + mount-point resolvability ordering fix; core mount path works. |
| [`umount.pdxfs`](https://github.com/paideia-os/umount.pdxfs) | sat | FUNCTIONAL | 🟢 | 0 | `r64v2-closed`. Real fail-closed elevate gate on `/system` unmount (independent classifier, exit 9). |
| [`pkg`](https://github.com/paideia-os/pkg) | sat | FUNCTIONAL | 🟢 | 0 | **v1.3.0.** Real install/remove/list, dry-run, dual ML-DSA-65 signature verification, audit output; txn-scoped unlink pipeline for remove. |
| [`postui-dmesg`](https://github.com/paideia-os/postui-dmesg) | sat | FUNCTIONAL | 🟢 | 0 | Real kernel-log tail/page UI; fixed a severity-band collision and a real LEVEL_* mislabeling. No version tag cut. |
| [`postui-hex`](https://github.com/paideia-os/postui-hex) | sat | FUNCTIONAL | 🟢 | 0 | Real hex-dump viewer; fixed a real info-disclosure OOB defect and a missing default I/O buffer that silently blocked the view. No version tag cut. |
| [`postui-top`](https://github.com/paideia-os/postui-top) | sat | FUNCTIONAL | 🟢 | 0 | Real sparkline/top view; fixed a debugger-caught latent stride-vs-Rect.w clamp bug before any live caller hit it. No version tag cut. |
| `init` | in-tree | FUNCTIONAL | 🟢 | 0 | Three real fork+execve cycles; PID-1 shutdown fixed from silent `sys_exit(0)` to panic-or-halt (Wave 19, `#2442`). Still hardcoded 3-daemon manifest, no supervisor/respawn. |
| `syscall_shim` | in-tree | FUNCTIONAL | 🟢 | 0 | Coverage widened from stopping-at-95 to including sysno 118 via a 22-wrapper wave; `sys_ipc_recv`/`sys_ipc_reply`/`sys_mkdir` (40/41/79) still inlined by two callers rather than shimmed. |
| `tokenizer` | in-tree | FUNCTIONAL | 🟢 | 0 | Gained `'`/`"` quoting, `\`-escape, `$VAR` expansion (Wave 17, `#2457`). `;`/`&`/`\|` operators still absent. |
| `shell` (in-tree) | both | FUNCTIONAL | 🟢 | 0 | Gained backspace/DEL/Ctrl-U line editing (Wave 14, `#2450`). Boot-early bring-up shell for the kernel-seeded `/bin/sh` first-execve; no pipes/redirection/signals/`$VAR` yet at this layer. |
| `ls` (in-tree) | both | FUNCTIONAL | 🟢 | 0 | Gained `-a`/`-l`/`-1`/`-F` flag suite (Waves 9+10). |
| `ps` | in-tree | FUNCTIONAL | 🟢 | 0 | Gained `-a`/`-e`/`-f` flag suite (Wave 12, `#2453`). |
| `touch` | in-tree | FUNCTIONAL | 🟢 | 0 | Unchanged: one file only, no `utime`. |
| `dispatch` | in-tree | MATURE | 🟢+ | 0 | 7+ builtins, PATH-prefix resolve with `sys_stat` probe, envp-sourced PATH (Waves 15+16), `exec_child` with redirects, `sys_getdents`-based `help /bin` listing. No self-disclosed gap. |

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
| **`compositor` (in-tree lib, unlinked)** | — | — | — | — | postui-desktop (skeleton, unspawned) | — |
| **`rootfs_seed` payloads** | ls, cat, ps (real ELFs) | mount (still stub bytes) | — | — | — | sh (kernel-seeded real ELF) |

**Reading the matrix.**
- **`libpdx-net`** (9 consumers, PARTIAL) is now the single widest-fanout under-built subject in the ecosystem — every R100 net-facing CLI is capped at PARTIAL until its TLS/crypto layer lands.
- **The compositor stack is real on both legs (kernel + satellite) but reconciled on neither.** `syscall_shim`'s fanout now includes the in-tree `compositor` library (both consume the newly-landed cap handlers), while `svc-compositor`/`svc-wm` remain a parallel, unwired satellite track. Closing this requires a design decision (extend `in-tree-vs-satellite-transition.md`), not more code on either side alone.
- **`elevate_broker_daemon`'s promotion from STUB to PARTIAL** partially unblocks the elevate-stack column — `ELV_OP_REQ` policy checks are now real, but every `libpdx-elevate` consumer still waits on `ELV_OP_APR`/`ELV_OP_EXP` for the full approve/expire lifecycle.

---

## Notes on this snapshot

- **The walk-back discipline is holding.** `cat`, `mv`, `rm`, and `doc` each self-disclosed their own prior schedule-closure tag in-repo before re-cutting a real one — this is the intended outcome of the 2026-09-12 refresh's "every 1.0.0 tag needs a QEMU end-to-end fixture" recommendation, now visibly operating as a norm across the org.
- **Two structural hazards, not one.** The known in-tree-vs-satellite duplication (`cat/cp/mkdir/mv/rm`, `dispatch`/`tokenizer`) is joined this refresh by two more: `ls` (satellite now ahead of in-tree) and the compositor stack (kernel/in-tree library vs. `svc-compositor`/`svc-wm`, further apart than any coreutil pair — different processes, different repos, zero shared commits).
- **The org has no live blocking cross-repo issue right now.** The 2026-09-12 refresh's standing `libpdx-elevate#38` ↔ `libpdx-audit#31` block is gone (`audit_append_leaf` landed, reverted, and re-fixed this session); no equivalent single-issue block was found this cycle.
- **Remaining paideia-os work is hardware-gated, not software-gated.** All 3 open monorepo issues need a physical T14/Iris Xe unit; nothing pending blocks on more QEMU-side kernel or userland work.

_Last refreshed: 2026-09-13 (sixth refresh — post-mega-session; monorepo 10→3 open; org-wide issue backlog drained to ~0; two new duplicate-implementation hazards surfaced: `ls` and the compositor stack)._ — send the `ECOTABLE` command to Claude Code in this project to rebuild.
