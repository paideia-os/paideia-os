# PaideiaOS — Semantic Shell Materialization Plan (osarch half)

**Status:** Draft v0.1
**Date:** 2026-09-23
**Author:** osarch (system-architecture half; a companion softarch document lands
in parallel covering parser + type-checker + Datalog evaluator + lambda
runtime + `.pds` surface — this document is the *substrate* half only).
**Scope:** The runtime substrate that turns the specification in
`design/terminal/semantic-shell.md` (SH-D1..SH-D12, 12 decisions across 880
lines) into runnable reality inside PaideiaOS. Covers pipeline transport,
capability threading, foreign-command bridge, REPL session model, Kitty
rendering, Unicode substrate, `.pds` loader, cross-host transport, and the
prerequisite fd-hygiene unblockers that gate everything.

**Naming discipline.** Round numbers follow the osarch-odd / softarch-even
paired-wave convention (see MASTER_PLAN and the reserved band R101..R114
already consumed by the graphics cascade). This document opens the R119
gate round, then walks the odd numbers R121, R123, R125, R127, R129, R131,
R133, R135, R137, R139, R141. Softarch's companion document will occupy the
adjacent even numbers R120, R122, R124, R126, R128, R130, R132, R134, R136,
R138, R140 for the language-surface work.

---

## 1. Executive summary

The PaideiaOS semantic shell is specified in exhaustive detail across 15
design documents and 12 SH-D decisions, but the running system today does
not implement any of it. `src/user/shell.pdx` (373 lines) plus
`src/user/dispatch.pdx` (1996 lines) is a POSIX-shaped tokenizer + builtin
table + fork/execve dispatcher with a half-working redirect scan and a
two-fork pipeline scaffold. `libpdx-schema-registry` and
`libpdx-semantic-pipe` are landed (0 open issues each), and the kernel-side
schema registry (`svc.schema-registry`, `KIND_SCHEMA_HANDLE = 0x1B2`) is up
per R90-XREPO.012 — so the substrate below the shell is real, but nothing
above it consumes any of that machinery for its data-plane. The renderer
fingerprints `SEMTERM GUI VELLO OK` fire but paint only a static test
surface; the R41 `SEMTERM*` scaffolds are named-only. The gap between spec
and reality is the entire point of this document.

The plan is organized as **twelve rounds spanning R119..R141**, each round
delivering one substrate slice with a concrete QEMU-observable acceptance
criterion and a well-defined dependency arrow. R119 is a small unblocker
round for the two open shell bugs (#2469 fd redirect and #2470 pipe
plumbing) — the entire cascade blocks on these because every downstream
round assumes fork/exec fd inheritance works. R121 lands the pipeline
runtime and Q13 hybrid serialization. R123..R125 land the command-module
loader and capability-at-exec threading. R127 lands the REPL session
process. R129..R131 land rendering and Unicode. R133..R135 land `.pds`
scripting and the WASM jail bridge. R137..R141 land cross-host transport,
multi-session coordination, and the perf/hardening baselines. The
softarch companion picks up the language surface in R120, R122, R124, R126,
R128, R130, R132, R134, R136, R138 and R140.

Total planned issues across the twelve rounds: **~318**, distributed
between the `paideia-os` monorepo, the (already-existing)
`libpdx-semantic-pipe` and `libpdx-schema-registry` satellites, and **five
new satellite repos** proposed here: `libpdx-pipeline-rt`,
`libpdx-shell-repl`, `libpdx-kitty-gfx`, `libpdx-unicode-tables` and
`libpdx-wasi-bridge`. Wall-clock at continuous AISSUE tempo is estimated
at **~4–5 weeks** including cross-repo submodule bumps, assuming the R110-
XREPO semantic-pipe 2.0 cascade lands first (it is an upstream dependency
for the wire-format changes R121 will require). Every round has an
acceptance criterion expressible either as a wire fingerprint the smoke
test greps for or as a QEMU-observable behaviour (a rendered pixel,
a piped byte, a returned record).

---

## 2. Prerequisite unblockers (R119)

Nothing else in this plan meaningfully lands until fork/exec fd hygiene
is correct. Both prereqs are already open as GitHub issues on the
paideia-os monorepo.

### 2.1 paideia-os#2469 — redirect creates file but content still lands on stdout

**Symptom (from the issue body).**
```
$ cat /etc/hostname > out          # fingerprint fires, out is created, out is empty, "paideia" still prints
$ echo hello > out                 # "hello > out" printed literally; no file
```

The `shell redirect ok -- argv[0]=cat op=> file=out` fingerprint fires
correctly (proving the argv-scrub side of dispatch.pdx runs), but the
dup2 that should retarget fd 1 for the child never actually rewires
stdout for the execve'd process. And the builtin echo path never
consumes the `>` token at all — it passes through to argv.

**Debugging entry points (concrete file/line targets).**
- `src/user/dispatch.pdx` around L1149..L1509 — the `exec_child` fork-
  then-execve path. Its redirect scan walks argv_buf for `>`/`>>`/`<`,
  calls sys_open, sys_dup2's the returned fd onto 1 (or 0), and left-
  compacts argv_buf so execve never sees the redirect tokens. Check:
  (a) is `sys_dup2` actually being invoked in the child before execve;
  (b) is the fd returned by sys_open getting closed before or after the
  dup2; (c) is the target-fd (1 or 0) being computed correctly for `>`
  vs `>>` vs `<`.
- `src/kernel/core/syscall/handlers/sys_dup2.pdx` (FILE_ID 807 per
  `src/kernel/core/klog/file_ids.pdx:2454`). Verify its 7-phase body
  writes the *source* vnode_idx into `task.fd_table[target_fd]` after
  refcount-holding, and does NOT install CLOEXEC-set entries as
  CLOEXEC-clear ones.
- `src/kernel/core/fs/fd_cloexec.pdx` — the CLOEXEC walker runs from
  `sys_execve_body`'s tail. If sys_dup2 accidentally sets bit 63 on
  the new slot (or fails to *clear* it inherited from the source),
  CLOEXEC fires on execve and the child sees stdout closed again.
  This is the most likely culprit.
- `src/kernel/core/loader/elf_lite.pdx` and
  `src/kernel/core/syscall/handlers/sys_execve.pdx` — verify the
  fd_table byte-copy happens *before* the aspace swap commits AND
  survives the swap.
- Shell builtin `echo` (in `src/user/builtins.pdx`) — verify it does
  NOT get the argv scrub applied (only the exec_child path does), so
  its redirect handling requires a separate builtin-side scan.

### 2.2 paideia-os#2470 — `ls | cat` produces no output

**Symptom.**
```
$ ls | cat                         # empty output
$ cat /etc/passwd | cat            # empty output
```

**Debugging entry points.**
- `src/user/dispatch.pdx` L1509..L1670 — the `exec_child_pipeline`
  path. Two forks + `sys_pipe` + dup2 dance for `producer | consumer`.
  Verify: (a) sys_pipe returns valid fds into `_dp_pipe_fds[0..1]`;
  (b) left child dup2's write_fd → 1, closes both raw pipe fds before
  execve; (c) right child dup2's read_fd → 0, closes both raw pipe fds
  before execve; (d) parent closes BOTH raw pipe fds after the two forks
  return, else the right child sees the pipe as never-closed and hangs
  on read.
- `src/kernel/core/syscall/handlers/sys_pipe.pdx` — verify its
  caller-owned output pair semantics match dispatch.pdx's expectation
  (`[0]=read_fd, [1]=write_fd`).
- `src/kernel/core/fs/pipe.pdx` (if it exists — likely the pipefs
  backend). Verify write-end-closed-EOF signaling to a reader.
- Wait4 ordering — the parent must wait4 BOTH children, not just one.
  If wait4 returns for the left child while the right is still
  buffering, we can lose the right child's output if the shell
  prematurely reprints the prompt.

### 2.3 R119 milestone table

| Milestone | Title | Task brief | Acceptance | Issues | Blocked-by | Repo |
|---|---|---|---|---|---|---|
| R119.M1 | fd-hygiene witness expansion | Add kernel-side klog witnesses at every sys_dup2 entry/exit, sys_pipe entry/exit, fd_cloexec walker per-slot decision, and fd_inherit walker per-slot decision. Land as `fd_hygiene_witness` bringup call in kernel_main. | Boot log carries at least one `fd dup2 ok src=<n> dst=<n> cloexec=<0|1>` line and one `fd pipe ok read=<n> write=<n>` line per shell command that uses them. | 6 | (none) | paideia-os |
| R119.M2 | #2469 root-cause & fix | Debug the redirect-inheritance failure using M1 witnesses. Land the fix. `> out` and `>> out` and `< in` all work for the external-command and builtin-echo paths. | Smoke test: `echo hi > out ; cat out` reads back `hi\n` and prints nothing to console; ditto for `cat /etc/hostname > h`. | 3 | R119.M1 | paideia-os |
| R119.M3 | #2470 root-cause & fix | Debug the pipe-output failure using M1 witnesses. Land the fix, including the wait4-both-children ordering. | Smoke test: `ls | cat` and `cat /etc/passwd | cat` produce byte-identical output to their non-piped counterparts. | 3 | R119.M1 | paideia-os |

**R119 issue count: 12.** No round in this document proceeds until R119.M3
lands. In particular, R121 assumes clean fd inheritance because the
pipeline runtime's boundary path is literally a chain of `sys_pipe` +
`sys_dup2` + `execve`. If R119 slips, the entire cascade stalls behind
it — this is the single most important gate.

---

## 3. Rounds R120..R141 — rationale

### R121 — Pipeline runtime & Q13 hybrid transport substrate

**Unblocks:** everything data-plane. Every subsequent round assumes a
typed record can travel across a `|`.

**Rationale.** SH-D3 requires two transports: intra-process by-capability
zero-copy (a `MemCap` handed forward through session-typed channels per
IPC-Q5) and cross-process/cross-host via Cap'n Proto serialized over the
IPC bridge's session-typed channel (per `wait-free-dataflow.md` §15). The
schema registry (already landed at R90-XREPO.012) provides the fingerprint;
`libpdx-semantic-pipe` already knows how to emit and consume records; but
**neither exists in a form that the shell can compose across pipeline
stages** — today the shell dispatches raw fork/exec pairs and the record
substrate is untouched by pipeline plumbing. R121 lands the missing seam:
a `PipelineEdge` capability kind whose two halves are the producer/
consumer ends of one session-typed channel, plus a boundary transport
that switches automatically between the in-process zero-copy path and
the Cap'n Proto serialized path.

**Q13 alternative-transport justification.** Cap'n Proto is the specified
boundary format (WF-D1). Alternatives evaluated:
- **FlatBuffers** — comparable zero-copy on reads but no built-in RPC
  layer; Cap'n Proto's RPC directly maps to our session-typed channel
  discipline. Reject.
- **Protobuf** — canonical but requires deserialization to touch fields.
  Zero-copy semantics are the whole point of Q13's "serialize only at
  the boundary" — Protobuf loses that. Reject.
- **Custom LAM-tagged Cap'n Proto subset** — the record slot in the wire
  format (`PipelineRecord.payload :Data`) is opaque; we can layer a
  LAM-preserving envelope on top for records that carry live capabilities
  cross-process without giving up Cap'n Proto's schema evolution rules.
  **Adopted as WF-D1.a in R121.M3 — the payload's outer 8 bytes carry
  LAM tag bits when `capabilities @3` list is non-empty.**

### R123 — Command-module functor loader + registry substrate

**Unblocks:** R125 (needs `required_capabilities` from command sig),
R133 (needs the same registry for script imports), R135 (needs the
foreign-command substrate binding).

**Rationale.** SH-D5 says commands are functors `module Cmd(Schemas:
SchemasSig)(...) : CommandSig`. The registry lives at
`/system/shell/commands.toml` (CRG-D1) and per-user override at
`/users/<u>/shell/commands.toml` (CRG-D4), each entry PQ-signed
(CRG-D3). Light commands (`where`, `sort`, `head`) run as in-process
functor calls; heavy commands (`find`, `grep`, `compile`) run as
separate processes; the loader chooses at load time (§6.2 of
semantic-shell.md). R123 lands (a) the on-disk registry parser
walking the CoW FS, (b) the PQ signature verification path per pillar
6, (c) the `KIND_CMD_MODULE` capability kind that a shell session
holds after a lookup, (d) the invoke ABI for both in-process and
out-of-process dispatch, (e) a bounded 256-entry in-memory registry
cache with LRU eviction. Cold-start budget: 20 ms REPL command-line
startup (per §14 semantic-shell.md perf table) implies the registry
lookup completes in single-digit milliseconds — hence the cache.

### R125 — Capability flow at exec

**Unblocks:** R135 (WASM jail needs the same minted-subcap discipline),
R137 (cross-host needs the identity-plus-caps package), R133 (`.pds`
capability declarations gate on this).

**Rationale.** SH-D6 requires that `run --grant fs.read.home cmd`
builds a capability environment for `cmd` that is a **subset** of
what the shell session holds, and that the subset is enforced at
syscall entry — not merely at the shell parser. Today `sys_execve`
delivers the parent's fd_table (per fd_inherit) but does no capability
sub-minting at all. R125 lands (a) the `run --grant` argument parser in
the shell, (b) a `svc.cap-minter` daemon in the supervisor that mints
sub-caps derived from the shell session's parent caps, (c) the
`caps.decl` region of the loaded ELF whose entries the loader compares
against the minted subset at execve time, (d) the KIND_CAP_ENV row
that a running process holds and that syscall entry points consult for
capability-gated syscalls. This is a first-class departure from POSIX
inheritance (per SH-D6 §7.5) and must be visible in the audit log.

### R127 — REPL as a session process

**Unblocks:** R129 (renderer needs a session-owned tty), R133 (script
loader wants the same session context), R139 (multi-session
coordination trivially).

**Rationale.** SH-D7 says every REPL is a process. Today a shell is a
single `/bin/sh` running fork/exec — there is no *session* concept. R127
lands (a) the `svc.shell-session` daemon that spawns a per-tty REPL
process, (b) the session's `KIND_SESSION` capability holding the
user's cap env + tty binding + history-store binding, (c) the history-
storage substrate (per HST-D1 — CoW FS at `/users/<u>/shell/history/`,
HST-D3 Cap'n Proto per-entry records), (d) job control (§8.5 of
semantic-shell.md — background pipelines run as scheduled threads
with their own pipeline; the session tracks active jobs), (e) the
line editor over the tty stream (delegated to the softarch line-editor
in R128; R127 lands only the substrate — the tty attach, the raw-mode
switch, the ANSI escape sink).

### R129 — Rendering pipeline (Kitty + fallback)

**Unblocks:** R131 (Unicode display width lives here), R135 (jail
output rendering goes through this pipeline).

**Rationale.** SH-D8 says Kitty graphics protocol native, ANSI-256 +
text fallback, no VT100. Today the semterm engine has G1..G6 stubs
that paint a Vello test surface only (per the graphics-g1-g6-landed
memory). The kernel-side compositor exists; the rendering path from a
pipeline record to a rendered surface does not. R129 lands (a) the
Kitty graphics protocol emitter (base64-encoded escape sequences per
KGP-D1..D5), (b) the XTGETTCAP terminal-capability probe (KGP-D5),
(c) the ANSI-256 fallback path with box-drawing Unicode for tables,
(d) the schema-driven formatter that picks table vs chart vs plain
based on the input record's schema (`§9.3 semantic-shell.md`), (e) the
per-command `| as table | as chart | as plain` override syntax.

### R131 — Unicode substrate (SH-D9, E13)

**Unblocks:** R129's grapheme-cluster-aware column-width, R133's
grapheme-cluster tokenization for scripts, R127's line-editor cursor
positioning, R137's NFC normalization at cross-host boundaries.

**Rationale.** SH-D9 requires UTF-8 everywhere, grapheme-cluster-aware
parsing per Unicode TR#29, UCA collation per UTS #10, and NFC
normalization at IPC boundaries. Today paideia-as ships an ASCII-shaped
tokenizer with byte-level string operations. This is the ambient
substrate: (a) UTF-8 decode/encode, (b) TR#29 grapheme cluster
boundary iterator, (c) UCA collation with locale key tables, (d)
NFC/NFD/NFKC/NFKD normalization tables, (e) TR#11 display-width
computation, (f) TR#9 bidirectional-text run computation, (g) the CoW
FS-backed locale registry per I18N-D2 (12 shipped locales: en-US,
en-GB, es, pt-BR, fr, de, ja, zh-CN, zh-TW, ko, ru, ar).

**Table storage.** UCA tables (CLDR-derived) are ~1.5 MiB per locale
uncompressed. Land at `/system/locale/<id>/collation.dat` per I18N §2
with a mmap'd read-only view — the shell session holds a
`KIND_LOCALE_TABLE` cap that gates access.

### R133 — `.pds` script loader + type-check-at-load

**Unblocks:** R135 (registered foreign commands may live in scripts),
R137 (a cross-host pipeline can be scripted).

**Rationale.** SH-D10 + pds-format.md — `.pds` files have shebang +
`#capability` + `#requires-paideia` + `#import` pragmas + body. R133
lands the loader substrate: (a) the parser (delegated to softarch R132
for the surface — R133 lands only the on-disk container: header parse,
capability-declaration extraction, import graph traversal, module
circularity detection per PDS-O2), (b) the capability-check gate at
load — declared capabilities must be a subset of invoker's; failure
aborts load; (c) the module registry alongside the command registry
(shared substrate with R123), (d) the pre-execution type-check
pathway that the softarch parser hooks into.

### R135 — WASM jail bridge (typed-wrapper substrate)

**Unblocks:** R137 (a cross-host stage may run a foreign command),
foreign-tool ecosystem in general.

**Rationale.** SH-D11 + Q9 + wasm-vm-jail.md. R135 does **not** port
wasmtime (that is scheduled in `design/runtime/wasm-vm-jail.md` phase 2
as JAIL-D1) — instead R135 lands the *bridge that will host it*: (a)
the `svc.jail-supervisor` daemon holding `vm_jail_cap` reservations,
(b) the per-jail process spawn path with fresh AS + fresh cap env
(JAIL-D6, JAIL-D7), (c) the argv/stdin conversion from pipeline
records for POSIX-style stubs, (d) the record-to-WIT-type conversion
skeleton for WASI Preview 2 component-model bindings (JAIL-D10 —
the concrete WIT bridge lands under `design/runtime/wit-bridge.md`
which is currently future-scheduled), (e) the WASI-fd-to-file-cap
mediation layer where wasmtime, once ported, will plug in. R135's
acceptance criterion is not a real WASM command; it is a
`svc.jail-supervisor mint ok pid=<n> caps=<n>` fingerprint when a
stub-command exec request arrives. Wasmtime's actual port is a
separate future round (deliberately outside this plan's scope, since
the port itself is well over 100 issues).

### R137 — Cross-host pipeline transport

**Unblocks:** distributed workflows generally; long-tail follow-ons in
R141.

**Rationale.** SH-D12 + cross-host-auth.md. R137 lands (a) the
`svc.remote-shell` daemon accepting hybrid-KEM handshakes per the PQ
doc, (b) the remote peer discovery via the federation-membership
capability from `capabilities/distributed.md`, (c) the record wire
translation across a bridge (reuses R121's Cap'n Proto boundary path
but adds the encryption layer), (d) the `@hostname stage-name` shell
syntax (surface delegated to softarch R136), (e) the remote-side
identity-mapping onto a per-user capability environment per CHA-D3,
(f) failure modes: bridge dies mid-stream → sender sees `ChannelDead`,
receiver sees `PeerVanished`, shell reports `pipe(@remote): peer
disconnected` and preserves prior records.

### R139 — Multi-session coordination + audit substrate

**Unblocks:** general multi-user hardening; not on the critical path
but required for parity with the semantic-shell.md multi-session.md
spec.

**Rationale.** MS-D1..MS-D4 — sessions are independent processes;
last-writer-wins per FS snapshot isolation; no shared state beyond
user's cap env. R139 lands (a) the per-session history segment write
discipline (each session tags its history entries with a session id
so multi-session merging is monotonic), (b) the "open file in another
session" detection (per MS-O1 UX guidance — the FS server exposes a
`current_holders(vnode)` op that the shell consults on open), (c) the
audit-log discipline for every command in every session (job-start,
job-end, cap-mint, cap-deny), (d) the session-shutdown ordering that
flushes history and closes tty gracefully.

### R141 — Perf baselines + observability + hardening

**Unblocks:** the plan's termination condition. Establishes the
numeric baselines the whole `perf-baselines.md` (currently future)
requires; enables the ongoing hardening loop.

**Rationale.** §14 of semantic-shell.md sets aspirational budgets: 20
ms REPL startup, 10 ms 5-stage type check, 200 ns intra-process record
pass, 1 µs cross-process record pass, 100 ms 1M-fact Datalog query, 50
ms tab completion, 50 ms Kitty image emit, 100 MB/s NFC normalization.
R141 lands (a) the microbenchmark harness that measures each of these
in situ under QEMU + on bare metal, (b) the fingerprint sink that
records numbers into `/system/perf/shell/<yyyy-mm-dd>.log`, (c) the
fuzz-testing entry points per §15.6, (d) capability-flow adversarial
tests per §15.5, (e) the initial baseline `perf-baselines.md` document.

---

## 4. Per-round milestone table

Each round lists 2–5 M-milestones; every milestone is one bulk-file
GitHub issue tranche. Issue counts are estimates for the initial
tranche; each milestone typically spawns follow-ups.

### R119 — fd-hygiene unblockers (see §2.3 above)

Total for R119: **12 issues**, all in the `paideia-os` monorepo.

### R121 — Pipeline runtime & Q13 hybrid transport substrate

| Milestone | Title | Task brief | Acceptance | Issues | Blocked-by | Repo |
|---|---|---|---|---|---|---|
| R121.M1 | KIND_PIPELINE_EDGE capability | Introduce a new kind (next slot past `KIND_SCHEMA_HANDLE`=0x1B2) representing one half of a session-typed pipeline channel. Row layout: 32 bytes = {schema_id u32, edge_id u32, endpoint_role u8 [prod|cons], rights u16, reserved u8, buddy_edge_id u32, session_pos u64}. Base derives from KIND_MEMORY. | Fingerprint `pipe edge mint ok kind=0x1B<X> schema_id=<n> role=<prod|cons>` fires on every `pipeline_edge_alloc` call under witness. | 4 | (none in R121) | paideia-os |
| R121.M2 | Intra-process by-cap zero-copy transport | Land the `pipe_edge_send(edge, MemCap)` / `pipe_edge_recv(edge) -> MemCap` primitives that ride wait-free-dataflow.md's session-typed SPSC. Slot-cap economy provides backpressure (IPC-Q8); no serialization. | Smoke: two in-process stages linked by a KIND_PIPELINE_EDGE pair pass 10k `PdxFsDirEntry@0.1` records in <2 ms wall (200 ns/record budget from §14 semantic-shell.md). Witnessed as `pipe intra ok records=10000 ns_avg=<n>`. | 5 | R121.M1 | paideia-os |
| R121.M3 | Cap'n Proto boundary transport + LAM envelope | Cross-process path: serialize `PipelineRecord` per wire-format.md (schema_id + schemaVersion + payload + capabilities + metadata). Add the LAM-preserving envelope in payload's first 8 bytes when `capabilities` list is non-empty. Land the Cap'n Proto encoder+decoder in `libpdx-pipeline-rt` (new satellite). | Smoke: `producer.pdx | boundary | consumer.pdx` across a process boundary passes 10k records at <10 ms wall (1 µs/record cross-process budget). Fingerprint `pipe boundary ok records=10000 lam_recs=<n>`. | 7 | R121.M2, R110-XREPO Phase A | new satellite `libpdx-pipeline-rt` v0.1.0 |
| R121.M4 | Session-type duality checker | At channel bind time, verify producer and consumer instantiate the same functor `Channel(Schema)`. Refuse mismatched schemas at bind. Refuse role mismatch (two producers, two consumers). | Smoke: attempted mismatch bind returns `PipelineErr::SchemaMismatch(prod_sid=<n>, cons_sid=<n>)`; audit logs `pipe bind rejected reason=schema_mismatch`. | 3 | R121.M1 | libpdx-pipeline-rt, paideia-os |
| R121.M5 | Pipeline runtime shell integration | Replace the current fork/exec-only dispatch in dispatch.pdx with a runtime that: (a) chooses in-process vs out-of-process per SH-D5 §6.2 command "weight" flag; (b) allocates KIND_PIPELINE_EDGE pairs for each `|`; (c) plumbs through legacy-fd fallback for foreign commands whose bridge is not yet online (R135). | Smoke: `find /etc | count` returns a typed integer record (not text bytes) rendered to console. Fingerprint `pipe integrated ok stages=<n>`. | 5 | R121.M3, R119.M3 | paideia-os |
| R121.M6 | Backpressure discipline verification | Adversarial test: a fast producer (`yes`-like) pipes into a slow consumer (`sleep-per-record`). Verify slot-cap economy paces the producer to consumer's drainage rate; no unbounded memory growth. | 5-minute run under QEMU: producer's memory RSS stays within ±16 KiB of steady-state; consumer's drainage rate matches producer's send rate. Fingerprint `pipe backpressure ok steady=<n>`. | 3 | R121.M2 | paideia-os |

**R121 issue count: 27.** Also: 15 follow-up issues on `libpdx-
semantic-pipe` v2.x for wire-format additions the LAM envelope needs
= **R121 grand total: ~42**.

### R123 — Command-module functor loader + registry substrate

| Milestone | Title | Task brief | Acceptance | Issues | Blocked-by | Repo |
|---|---|---|---|---|---|---|
| R123.M1 | KIND_CMD_MODULE capability | New kind for a loaded command module. Row layout: 48 bytes = {name[24], version_maj u16, version_min u16, functor_id u32, in_process u8, cap_env_ptr u64, refcount u32}. Derives from KIND_SCHEMA_HANDLE + KIND_MEMORY. | Fingerprint `cmd module mint ok name=<n> functor_id=<n>`. | 4 | (R119 gate) | paideia-os |
| R123.M2 | On-disk registry parser (`/system/shell/commands.toml`) | Walk the CoW FS TOML file per CRG-D1 format; verify each entry's PQ signature per CRG-D3; populate an in-memory registry cache (256 entries LRU). Per-user override at `/users/<u>/shell/commands.toml` shadows system. | Smoke: `list-commands` builtin prints all registered commands with their schemas + version + substrate. Fingerprint `cmd registry loaded system=<n> user=<n>`. | 6 | R123.M1 | paideia-os, libpdx-schema-registry (referenced) |
| R123.M3 | In-process functor invoke ABI | For light commands (`where`, `sort`, `head`, `count`), the invoke is a direct function-call ABI: rdi=stream_in_edge, rsi=argv_ptr, rdx=cap_env, rcx=stream_out_edge; effects declared in caps.decl. Land the ABI-conforming versions of the 8 light commands. | Smoke: each of `where`, `sort`, `head`, `count`, `each`, `filter`, `map`, `reduce` runs as a functor call; no fork; measured overhead <1 µs. Fingerprint `cmd invoke inproc ok name=<n> ns=<n>`. | 8 | R123.M2, R121.M2 | paideia-os |
| R123.M4 | Out-of-process functor invoke path | For heavy commands, fork+exec a new process; supervisor mints the KIND_CMD_MODULE for the child; child's caps.decl matches its declared subset. | Smoke: `find` runs as separate process, produces records into an edge, records reach the shell. Fingerprint `cmd invoke outproc ok name=find pid=<n>`. | 5 | R123.M3, R125.M2 | paideia-os |
| R123.M5 | Command discovery API | `svc.command-registry` exposes `find_by_input_schema(sid)`, `find_by_output_schema(sid)`, `find_by_capability(cap)`. Tab completion (R127) will consume this. | Smoke: `discover --input FileSchema` prints commands that consume FileSchema. Fingerprint `cmd discovery ok query=<n> results=<n>`. | 3 | R123.M2 | paideia-os |
| R123.M6 | Registry hot-reload | On `/system/shell/commands.toml` change (FS-watch cap), refresh in-memory cache atomically; running shell sessions transparently see new entries; running command invocations complete on old entries. | Smoke: modify `commands.toml`, wait 1 second, `list-commands` shows the change without shell restart. Fingerprint `cmd registry reloaded old=<n> new=<n>`. Closes CRG-O1. | 4 | R123.M2 | paideia-os |

**R123 issue count: 30.**

### R125 — Capability flow at exec

| Milestone | Title | Task brief | Acceptance | Issues | Blocked-by | Repo |
|---|---|---|---|---|---|---|
| R125.M1 | KIND_CAP_ENV capability | Represents a session's capability environment. Row layout: variable-len (16-byte header + N × 32-byte cap-rights records; N up to 128). Derives from KIND_MEMORY. | Fingerprint `cap env mint ok user=<n> caps=<n>`. | 3 | (R119 gate) | paideia-os |
| R125.M2 | `svc.cap-minter` sub-cap derivation daemon | On `run --grant <cap>` request from shell, verify the requested cap is a subset of the session's parent env; mint a derived sub-cap with tighter rights; return the derivation attestation for the audit log. | Smoke: `run --grant fs.read.home=/etc/hostname cat /etc/hostname` succeeds; without the grant `cat /etc/hostname` fails with `EPERM: no cap`. Fingerprint `cap mint ok parent=<n> derived=<n> rights=<n>`. | 6 | R125.M1 | paideia-os |
| R125.M3 | ELF caps.decl loader | Parse the `caps.decl` note-section of loaded ELF binaries per design/user/execve-abi.md; refuse execve if declared caps exceed what the parent minted. | Smoke: an ELF declaring an unrequested capability produces `EPERM: caps.decl exceeds minted env`. Fingerprint `caps.decl verified ok pid=<n> caps=<n>` or `caps.decl rejected pid=<n> excess=<n>`. | 5 | R125.M2 | paideia-os |
| R125.M4 | Syscall-entry cap check integration | Every capability-gated syscall (sys_open, sys_socket, sys_pipe, sys_mount, sys_bind, sys_connect, sys_recvmsg, sys_sendmsg, sys_ioctl) consults task's KIND_CAP_ENV before proceeding. Denials return `EPERM_CAP` and log to audit. | Smoke: a process without `fs.write` calling `sys_open(path, O_WRONLY)` returns `EPERM_CAP`; audit logs `syscall cap deny pid=<n> syscall=<n> cap=<n>`. | 8 | R125.M3 | paideia-os |
| R125.M5 | `run --grant` shell surface | The shell recognizes `--grant <cap>=<scope>` and `--grant <cap>` flags before the command name; extracts them from argv; forwards to `svc.cap-minter`; passes the resulting derived cap env to the child. | Smoke: `run --grant net.connect=example.com:443 curl-stub example.com/x` succeeds with only that outbound connect authorized; `run --grant net.connect=example.com:443 curl-stub google.com/y` fails with `EPERM_CAP`. Fingerprint `run grant ok caps=<n>`. | 4 | R125.M2 | paideia-os |
| R125.M6 | Capability-typed arguments | For `copy <src> <dst>`, the shell's argument parser identifies file-path arguments, resolves them via the FS graph, and mints `fs_read_on_src` + `fs_write_on_dst_dir` sub-caps that copy consumes. | Smoke: `copy /etc/hostname /tmp/h` succeeds without a `--grant`; the copy binary's audit trail shows it received exactly those two caps, no more. Fingerprint `run cap-typed args=<n> caps=<n>`. | 2 | R125.M2, R125.M5 | paideia-os |

**R125 issue count: 28.**

### R127 — REPL session process + history storage

| Milestone | Title | Task brief | Acceptance | Issues | Blocked-by | Repo |
|---|---|---|---|---|---|---|
| R127.M1 | `svc.shell-session` daemon | Per-tty session spawn; holds the KIND_SESSION cap; tracks lifetime. | Fingerprint `shell session bringup ok tty=<n> user=<n>`. | 4 | R125.M1 | paideia-os, new satellite `libpdx-shell-repl` v0.1.0 |
| R127.M2 | KIND_SESSION capability | Row layout: 96 bytes = {user_id u32, tty_id u32, cap_env_ptr u64, history_store_cap u64, active_jobs[8], cwd_vnode u64, env_vnode u64, reserved}. | Fingerprint `session mint ok user=<n> tty=<n> caps=<n>`. | 3 | R127.M1 | paideia-os |
| R127.M3 | Raw-mode tty substrate | Session sets tty to raw mode via a new `KIND_TTY` capability; hands the raw stream to the line editor (which is softarch's R128); on session exit restores cooked mode. | Smoke: session correctly transitions raw→cooked on Ctrl-D; tty stays consistent across a segfault (kernel-side restore on session-process death). Fingerprint `tty raw ok tty=<n>` / `tty cooked ok tty=<n>`. | 5 | R127.M2 | paideia-os |
| R127.M4 | History storage substrate | Per-user CoW file at `/users/<u>/shell/history/<session_id>.pdxlog`; each entry is Cap'n Proto `HistoryEntry` per HST §2.1 (timestamp, command, capabilityEnv, result, durationNanos, outputSchema). 10k-entry ring per session; older compacted. | Smoke: session runs 50 commands, session exit closes cleanly, next session reads back all 50 entries in order. Fingerprint `history append ok session=<n> entries=<n>`. | 6 | R127.M2, R125.M2 | paideia-os, libpdx-shell-repl |
| R127.M5 | Job control primitives | `bg`, `fg`, `jobs`, `kill %<n>` builtins that track scheduled-thread pipelines in KIND_SESSION.active_jobs. Background jobs continue receiving records via their own pipeline edges. | Smoke: `find /home &` returns to prompt; `jobs` shows `[1] running find /home`; `fg %1` waits for completion. Fingerprint `job bg ok id=<n> pid=<n>`. | 5 | R127.M2, R121.M5 | paideia-os |
| R127.M6 | Session teardown discipline | On tty hangup, session flushes pending history writes, drains open pipelines with a 1s grace, sends SIGKILL to any remaining child, releases KIND_SESSION. | Smoke: kill the tty PTY host; session process exits within 1.2s; audit records the reason. Fingerprint `session teardown ok session=<n> reason=<n>`. | 4 | R127.M4, R127.M5 | paideia-os |
| R127.M7 | Datalog-queryable history hook | Every HistoryEntry emits into a session-local extensional-database backing that the softarch Datalog evaluator (R128) will query. R127 lands only the tuple exposure; the evaluator is softarch's. | Smoke: R128 companion can read `history(?e), command(?e, "find")` via a session-scoped cap. Fingerprint `history tuple emit ok session=<n> tuple_sid=<n>`. Closes HST-O1 substrate half. | 5 | R127.M4 | libpdx-shell-repl |

**R127 issue count: 32.**

### R129 — Rendering pipeline (Kitty + fallback)

| Milestone | Title | Task brief | Acceptance | Issues | Blocked-by | Repo |
|---|---|---|---|---|---|---|
| R129.M1 | XTGETTCAP terminal probe | On session bringup, emit `\x1bP+q<hex>\x1b\\` for a couple of well-known caps (Kitty graphics `Smkx`, Sixel `Sixel`, 24-bit color `RGB`); parse the response; store in KIND_SESSION.tty flags. | Fingerprint `tty probe ok tty=<n> kitty=<0|1> sixel=<0|1> rgb=<0|1>`. | 3 | R127.M3 | paideia-os, new satellite `libpdx-kitty-gfx` v0.1.0 |
| R129.M2 | Kitty graphics protocol emitter | Emit `\x1b_G<params>;<base64>\x1b\\` sequences per KGP-D3 (PNG, JPEG, raw RGBA). Placement-based positioning (KGP-D2). ID-based addressing for later updates. | Smoke: emit a 128x128 PNG; QEMU screen shows the image (verified via framebuffer capture). Fingerprint `kitty emit ok id=<n> bytes=<n>`. | 6 | R129.M1 | libpdx-kitty-gfx |
| R129.M3 | ANSI-256 tabular fallback | For terminals without Kitty, render records as ANSI-256 colored tables using Unicode box-drawing (│ ─ ┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼). Column widths derived from record-schema field widths + observed data width. | Smoke: `find /etc | head 5 | as table` on a non-Kitty PTY renders a 5-row bordered table; verified via output-buffer capture. Fingerprint `ansi table ok rows=<n> cols=<n>`. | 5 | R129.M1, R131.M5 | libpdx-kitty-gfx |
| R129.M4 | Schema-driven formatter | For each output-schema `sid`, pick a default rendering: FileSchema → table with (name, size, modified); MetricPoint → time-series plot; Image → thumbnail strip; unknown → plain-text field-per-line. | Smoke: `find /etc` auto-renders as a table without an `| as table`. Fingerprint `render auto ok sid=<n> renderer=<n>`. | 4 | R129.M3, R121.M5 | paideia-os |
| R129.M5 | `as` renderer override syntax | Shell parses `| as table`, `| as chart by <field>`, `| as plain`, `| as json`; dispatches to the corresponding renderer. | Smoke: same input, three different renderings via `as`. Fingerprint `render override ok mode=<n>`. | 3 | R129.M4 | paideia-os |
| R129.M6 | Sixel fallback (KGP-O1) | When Kitty absent but Sixel present, emit Sixel escape sequences for raster output. Slower but broader terminal support. | Smoke: on a Sixel-only PTY, image renders correctly. Fingerprint `sixel emit ok bytes=<n>`. | 4 | R129.M2 | libpdx-kitty-gfx |
| R129.M7 | Inline-plot renderer (line/bar/sparkline) | For MetricPoint streams, render inline sparklines (Unicode `▁▂▃▄▅▆▇█` blocks) as ANSI fallback; render proper line/bar charts as Kitty PNG when available. | Smoke: `metrics show cpu | as chart` renders a sparkline OR a chart. Fingerprint `chart emit ok kind=<n> points=<n>`. | 5 | R129.M2, R129.M3 | libpdx-kitty-gfx |
| R129.M8 | Kitty-side interactive test app | A `kitty-probe` command that emits every Kitty feature we intend to use and greps its own re-read; used for regression. | Smoke test in tools/run-smoke.sh; fingerprint `kitty probe ok features=<n>`. | 4 | R129.M2 | paideia-os |

**R129 issue count: 34.**

### R131 — Unicode substrate

| Milestone | Title | Task brief | Acceptance | Issues | Blocked-by | Repo |
|---|---|---|---|---|---|---|
| R131.M1 | UTF-8 decode/encode primitives | Correct, branch-lean 4-byte-max-per-scalar decode; encode; error-mode configurable (replace with U+FFFD, reject, strict). | Smoke: WPT UTF-8 test corpus round-trips; malformed sequences flagged per RFC 3629. Fingerprint `utf8 decode ok cases=<n>`. | 3 | (R119 gate) | new satellite `libpdx-unicode-tables` v0.1.0 |
| R131.M2 | Grapheme-cluster iterator (TR#29) | Table-driven state machine per Unicode TR#29; handles ZWJ sequences, variation selectors, regional-indicator pairs, emoji-sequence classes. | Smoke: Unicode grapheme-cluster test file (GraphemeBreakTest.txt, ~700 cases) passes. Fingerprint `grapheme iter ok cases=<n>`. | 5 | R131.M1 | libpdx-unicode-tables |
| R131.M3 | NFC/NFD/NFKC/NFKD normalization | Standard canonical composition tables per UAX #15; NFC as the IPC-boundary default; NFKC/NFKD for identifier normalization. | Smoke: NormalizationTest.txt (~19k cases) passes. Fingerprint `norm ok form=<n> cases=<n>`. | 4 | R131.M1 | libpdx-unicode-tables |
| R131.M4 | UCA collation | Table-driven UCA per UTS #10 with default DUCET; locale tailoring parsed from CLDR tailorings per I18N-D4. | Smoke: CollationTest.txt subset for `en-US`, `de`, `zh-CN` passes. Fingerprint `uca sort ok locale=<n> cases=<n>`. | 5 | R131.M1 | libpdx-unicode-tables |
| R131.M5 | Display width (TR#11) | East Asian Width + emoji-presentation width computation for terminal cell counting. Grapheme-cluster-aware. | Smoke: cursor advances correct number of cells for `家族`, `👨‍👩‍👧‍👦`, `हिन्दी`, `أهلا`. Fingerprint `width calc ok chars=<n> cells=<n>`. | 3 | R131.M2 | libpdx-unicode-tables |
| R131.M6 | Bidi runs (TR#9) | Compute paragraph-level bidi runs; the renderer uses these to lay out RTL scripts. | Smoke: Arabic input renders in visual-RTL order in the line editor. Fingerprint `bidi runs ok chars=<n> runs=<n>`. | 3 | R131.M2 | libpdx-unicode-tables |
| R131.M7 | Locale registry substrate | Mount `/system/locale/<id>/` per I18N §2 with the 12 shipped locales (en-US, en-GB, es, pt-BR, fr, de, ja, zh-CN, zh-TW, ko, ru, ar); expose a KIND_LOCALE_TABLE cap for read. Downloadable locales per I18N-D3. | Smoke: `list-locales` shows 12 entries; each is mmap-readable via the cap. Fingerprint `locale registry ok count=<n>`. | 4 | R131.M4 | paideia-os |
| R131.M8 | IPC-boundary NFC hook | `libpdx-pipeline-rt` boundary encoder normalizes every `STR` field to NFC before Cap'n Proto serialization; the decoder verifies NFC on receive; violations fingerprint an audit entry. | Smoke: a record with a non-NFC string travels through a boundary → the receiver reads NFC; the sender's audit sink shows a `nfc renormalized field=<n>` entry. Fingerprint `pipe nfc hook ok fields=<n>`. | 3 | R131.M3, R121.M3 | libpdx-pipeline-rt |

**R131 issue count: 24.**

### R133 — `.pds` script loader + type-check-at-load

| Milestone | Title | Task brief | Acceptance | Issues | Blocked-by | Repo |
|---|---|---|---|---|---|---|
| R133.M1 | `.pds` container reader | Read shebang; extract `#capability`, `#requires-paideia`, `#import`, `#schema`, `#ascii` pragmas; hand the body off to the softarch parser (R132) via a fixed callback ABI. | Smoke: `pds-info some.pds` prints header contents. Fingerprint `pds header ok caps=<n> imports=<n>`. | 4 | R123.M2 | paideia-os |
| R133.M2 | Capability-declaration gate | On load, verify every `#capability` in the script is a subset of the invoker's session cap env. Refuse load on excess. | Smoke: a script declaring `#capability fs.write.system` when the invoker only has `fs.read.home` fails with `EPERM: script caps exceed env`. Fingerprint `pds cap check ok/rejected declared=<n> env=<n>`. | 3 | R133.M1, R125.M2 | paideia-os |
| R133.M3 | Import graph traversal + circularity detection | Follow `#import` transitively; detect cycles (per PDS-O2); build a dependency-ordered module list. | Smoke: circular imports fail with `PdsErr::ImportCycle(path=<n>)`. Fingerprint `pds import graph ok modules=<n> cycles=<n>`. | 4 | R133.M1 | paideia-os |
| R133.M4 | `#requires-paideia` version gate | Parse semver; compare against runtime version; refuse load on mismatch. | Smoke: `#requires-paideia >= 99.0` on a 0.x runtime fails with `PdsErr::VersionMismatch`. Fingerprint `pds version ok required=<n> have=<n>`. | 2 | R133.M1 | paideia-os |
| R133.M5 | Pre-execution type-check pipeline | Hand the parsed script body to the softarch type-checker (R132.M?); refuse execution on type errors; report source spans. | Smoke: a script with a pipeline mismatch fails with a type error that names the offending stage. Fingerprint `pds typecheck ok/rejected stages=<n>`. | 4 | R133.M1 (softarch R132 gate) | paideia-os |
| R133.M6 | Script execution as functor application | A loaded, checked script becomes an in-process functor call to a synthesized `ScriptCmd` — inherits the invoker's cap env narrowed by the script's `#capability` list. | Smoke: `pds run backup.pds` runs the example from pds-format.md §0 successfully. Fingerprint `pds run ok script=<n> duration_us=<n>`. | 3 | R133.M2, R133.M5 | paideia-os |

**R133 issue count: 20.**

### R135 — WASM jail bridge (typed-wrapper substrate)

| Milestone | Title | Task brief | Acceptance | Issues | Blocked-by | Repo |
|---|---|---|---|---|---|---|
| R135.M1 | `svc.jail-supervisor` daemon | Holds `vm_jail_cap` reservations per JAIL-D5; the shell's foreign-command dispatch requests jail creation via a well-known endpoint. | Fingerprint `jail supervisor bringup ok endpoint=<n>`. | 4 | R125.M2 | paideia-os, new satellite `libpdx-wasi-bridge` v0.1.0 |
| R135.M2 | Per-jail process spawn | Fresh AS + fresh cap env + fresh fd table per invocation (JAIL-D6). Resource budget defaults (JAIL-D7): 128 MiB memory, 100ms wall grace, 10 MiB/s I/O. | Smoke: a stub jail process spawns, prints its own pid + cap-env summary, exits cleanly. Fingerprint `jail spawn ok pid=<n> caps=<n>`. | 5 | R135.M1 | paideia-os |
| R135.M3 | argv/stdin conversion (POSIX-style stubs) | For a foreign command declared `substrate=wasm` `schema_input=none` `schema_output=string`, convert the shell's arg vector to a POSIX-style `argv[]` + `envp[]`, pipe an empty stdin. | Smoke: a stub `echo-in-jail` binary prints its argv; the parent reads it back. Fingerprint `jail argv convert ok args=<n>`. | 4 | R135.M2 | libpdx-wasi-bridge |
| R135.M4 | stdout → typed-record conversion | For `schema_output=string`, wrap stdout bytes into a `RawByteChunk@0.1` record stream that flows into R121's pipeline edge. | Smoke: `stub-echo | count-bytes` returns the correct byte count. Fingerprint `jail stdout convert ok bytes=<n> records=<n>`. | 4 | R135.M3, R121.M5 | libpdx-wasi-bridge |
| R135.M5 | WIT-typed record bridge skeleton | For future WASI Preview 2 component-model commands (JAIL-D10). Land the conversion skeleton — WIT type reader, WIT-to-PdxRecord and PdxRecord-to-WIT stubs, dispatcher hook. Actual wasmtime port deferred. | Smoke: a hand-written WIT type descriptor loads; conversion round-trip works for scalars. Fingerprint `wit convert ok kind=<n>`. | 5 | R135.M4 | libpdx-wasi-bridge |
| R135.M6 | WASI-fd-to-file-cap mediation | The bridge's fd_table maps WASI fds to KIND_FILE_CAP entries per JAIL §5.1. Reads/writes on a WASI fd invoke the FS server through the held cap; missing cap returns WASI errno `NOTCAPABLE`. | Smoke: a jail with a granted `fs.read=/etc/hostname` cap reads that file successfully; the same jail attempting `/etc/shadow` gets `NOTCAPABLE`. Fingerprint `wasi fd mediate ok reads=<n> denies=<n>`. | 4 | R135.M2, R125.M4 | libpdx-wasi-bridge |
| R135.M7 | Command-registry substrate wire-up | The `substrate=wasm` command-registry entries (per §12.3 semantic-shell.md) dispatch via R135's supervisor. The `substrate=vm` path remains deferred. | Smoke: adding `[command.stub-echo] substrate=wasm binary=/jail/stub/echo` to commands.toml, then `stub-echo hi` prints `hi`. Fingerprint `cmd substrate wasm ok name=<n>`. | 4 | R135.M6, R123.M4 | paideia-os |

**R135 issue count: 30.**

### R137 — Cross-host pipeline transport

| Milestone | Title | Task brief | Acceptance | Issues | Blocked-by | Repo |
|---|---|---|---|---|---|---|
| R137.M1 | `svc.remote-shell` daemon | Bring up an endpoint accepting cross-host pipeline connect requests. | Fingerprint `remote shell bringup ok endpoint=<n>`. | 3 | R121.M3 | paideia-os |
| R137.M2 | Hybrid-KEM handshake | Per PQ doc `design/security/pq-trust-root.md`, the two hosts perform the hybrid-KEM key exchange; derive a per-session symmetric key; wrap the Cap'n Proto stream in AEAD. | Smoke: two paideia-os VMs handshake; a subsequent record wire is encrypted (verified by tapping the wire). Fingerprint `remote handshake ok peer=<n> suite=<n>`. | 6 | R137.M1 | paideia-os |
| R137.M3 | Peer discovery via federation cap | The invoking session must hold a `federation_member` cap from `design/capabilities/distributed.md`; the cap names allowed remote hosts. Discovery uses the federation registry (a simple TOML at `/system/federation/hosts.toml` at first; a DNS-SRV variant deferred). | Smoke: `@known.host find /etc | head 1` connects; `@unknown.host find /etc | head 1` fails with `PeerErr::NotFederated`. Fingerprint `remote peer discover ok host=<n>` or `remote peer reject reason=<n>`. | 4 | R137.M2 | paideia-os |
| R137.M4 | Cross-host record wire | Extend R121.M3's Cap'n Proto encoder to travel over the encrypted channel; verify session-type duality across the boundary; NFC-normalize STR fields per R131.M8 before wire. | Smoke: a schema-typed record flows from local shell to remote and back. Fingerprint `remote record wire ok records=<n>`. | 5 | R137.M3, R121.M3 | paideia-os |
| R137.M5 | Remote-side identity mapping | On accept, the remote maps the local user's identity claim (per CHA-D2) to a remote-side per-user capability env; refuses if no mapping exists. | Smoke: an unmapped local user gets `RemoteErr::NoIdentityMapping`; a mapped one gets a session shell. Fingerprint `remote identity map ok local=<n> remote=<n>`. | 4 | R137.M2 | paideia-os |
| R137.M6 | Failure-mode discipline | Bridge dies mid-stream → sender sees `ChannelDead`, receiver sees `PeerVanished`; shell reports `pipe(@remote): peer disconnected after N records` and preserves prior records. | Smoke: kill the remote daemon mid-stream; local receives the message; already-transferred records remain in place. Fingerprint `remote pipe dead ok records=<n> reason=<n>`. | 4 | R137.M4 | paideia-os |

**R137 issue count: 26.**

### R139 — Multi-session coordination + audit substrate

| Milestone | Title | Task brief | Acceptance | Issues | Blocked-by | Repo |
|---|---|---|---|---|---|---|
| R139.M1 | Per-session history segmentation | Each session's history entries carry a `session_id` field; the reader merges segments in monotonic timestamp order. | Smoke: two concurrent sessions run 20 commands each; a subsequent single session reads back 40 entries interleaved by timestamp. Fingerprint `history multi merge ok sessions=<n> total=<n>`. | 3 | R127.M4 | paideia-os |
| R139.M2 | FS `current_holders(vnode)` op | The FS server exposes a query returning the pid list currently holding an fd to a vnode; the shell consults on open of an already-modified file for the MS-O1 UX warning. | Smoke: session A opens `/tmp/x` for write; session B opens same → sees warning; fingerprint `fs holders warn ok vnode=<n> pids=<n>`. | 4 | (R119 gate) | paideia-os |
| R139.M3 | Audit-log discipline for every command | Job-start, job-end, cap-mint, cap-deny events emit into `svc.audit-journal` per each session's KIND_AUDIT_SINK. Fields: session_id, timestamp, event_kind, principal, cap_ids. | Smoke: run 10 commands; audit journal contains 10 job-start + 10 job-end events. Fingerprint `audit shell events ok kind=<n> count=<n>`. | 5 | R127.M2 | paideia-os |
| R139.M4 | Session shutdown ordering | On tty hangup or Ctrl-D, session (a) drains pending history writes, (b) sends SIGHUP to active jobs, (c) waits 1s grace, (d) SIGKILLs stragglers, (e) closes tty, (f) releases KIND_SESSION. | Smoke: session with a running `sleep 30 &` exits cleanly on Ctrl-D within 1.2s; child receives SIGHUP first. Fingerprint `session shutdown ok grace_ms=<n> stragglers=<n>`. | 4 | R127.M6 | paideia-os |
| R139.M5 | Multi-session capability-env sharing | Two sessions for the same user hold pointers to the *same* KIND_CAP_ENV row (per MS-D4); a revoke in one is immediately visible in the other. | Smoke: session A revokes a cap → session B's next syscall touching it gets `EPERM_CAP`. Fingerprint `cap revoke propagate ok cap=<n> sessions=<n>`. | 3 | R125.M4 | paideia-os |
| R139.M6 | "Open file in another session" UX | Client-side of MS-O1 — the warning UI surface (delegated to softarch R138 for the actual prompt); R139 lands only the query hook and the warning-emit fingerprint. | Fingerprint `shell open warn ok vnode=<n> other_pid=<n>`. | 3 | R139.M2 | paideia-os |

**R139 issue count: 22.**

### R141 — Perf baselines + observability + hardening

| Milestone | Title | Task brief | Acceptance | Issues | Blocked-by | Repo |
|---|---|---|---|---|---|---|
| R141.M1 | Microbenchmark harness | A `pdxbench` command that measures each §14 budget: REPL startup, 5-stage type-check, intra-process record pass, cross-process record pass, tab completion, Kitty image emit, NFC throughput. | Smoke: `pdxbench` prints seven measurements. Fingerprint `pdxbench run ok metrics=7`. | 4 | (all prior rounds) | paideia-os |
| R141.M2 | Perf-sink logging | Every `pdxbench` run appends to `/system/perf/shell/<yyyy-mm-dd>.log` in a Cap'n Proto-serialized record stream. | Smoke: two runs → two entries readable via `pdxbench --show-history`. Fingerprint `perf sink write ok entries=<n>`. | 3 | R141.M1 | paideia-os |
| R141.M3 | Fuzz-testing entry points | Per §15.6 of semantic-shell.md — expose fuzz targets for the parser (softarch R120), for the boundary Cap'n Proto decoder (R121), for the WASI host-function bridge (R135). | Smoke: `tools/fuzz-shell.sh --minutes 5` produces no crash. Fingerprint `fuzz shell ok minutes=5 crashes=0`. | 3 | (all rounds) | paideia-os |
| R141.M4 | Capability-flow adversarial tests | Per §15.5 — a hand-written script attempts to use each disallowed capability; every attempt must be refused; the audit log must record each denial. | Smoke: 20-case adversarial suite passes with 20 denials. Fingerprint `cap adversarial ok cases=20 denials=20`. | 3 | R125.M4, R133.M2 | paideia-os |
| R141.M5 | `perf-baselines.md` initial document | Land the first baseline document at `design/terminal/perf-baselines.md` with measurements from R141.M1 on QEMU + on a reference bare-metal host (comparch to run bare-metal). | The doc lives at `design/terminal/perf-baselines.md`. Closes SH-O12. | 2 | R141.M2 | paideia-os |
| R141.M6 | Regression gate on smoke test | `tools/run-smoke.sh` gains a `--perf` mode that runs pdxbench and refuses to pass if any metric regresses more than 20% from the previous baseline. | Smoke: intentional 30% regression is caught. Fingerprint `smoke perf gate reject metric=<n>`. | 3 | R141.M5 | paideia-os |

**R141 issue count: 18.**

---

## 5. Cross-repo cascade shape

### 5.1 Repos touched

| Repo | Status today | Role in this cascade |
|---|---|---|
| **paideia-os** (monorepo) | active | Kernel side of every round; primary shell binary; supervisor daemons; all `svc.*` bringups |
| **libpdx-schema-registry** | landed (0 open) | Referenced by R123 (registry lookup), R121 (schema-id encoding); no new work here beyond version-pin bumps |
| **libpdx-semantic-pipe** | 6 open (R110-XREPO 2.0 pending) | R121 rides on top of the 2.0 wire format; ~15 follow-up issues expected here for LAM-envelope encoding, cross-host framing extension, NFC hook |
| **libpdx-pipeline-rt** (NEW) | to be created | Home of the R121 pipeline runtime: intra-process transport, boundary Cap'n Proto encode/decode, session-type checker |
| **libpdx-shell-repl** (NEW) | to be created | Home of R127 session substrate, history storage encoder/decoder, job control primitives |
| **libpdx-kitty-gfx** (NEW) | to be created | Home of R129 Kitty protocol emitter + ANSI fallback + Sixel + chart renderers |
| **libpdx-unicode-tables** (NEW) | to be created | Home of R131 UTF-8 + TR#29 + UCA + NFC + TR#11 + TR#9 + locale tables |
| **libpdx-wasi-bridge** (NEW) | to be created | Home of R135 jail bridge (WIT stub, WASI-fd mediation, argv/stdin converter). Wasmtime port lands in a *future* round outside this plan |

### 5.2 Cascade ordering (dependencies flow left → right)

```
                       R110-XREPO semantic-pipe 2.0
                                    │
                                    ▼
                                  R119 fd-hygiene unblock  ────────────┐
                                                                        │
                    ┌────────────┬────────────┬────────────┐            ▼
                    │            │            │            │        (all rounds gate on R119)
                    ▼            ▼            ▼            ▼
                  R121         R123         R125         R131
              (pipeline)    (registry)   (caps)      (unicode)
                    │            │            │            │
                    ├────────────┴──────┐     │            │
                    │                   ▼     ▼            │
                    │                    R127            │
                    │                (REPL session)     │
                    │                     │            │
                    ▼                     ▼            ▼
                  R135                  R129         R133
              (WASI bridge)         (renderer)   (.pds loader)
                    │                     │            │
                    └──────┬──────────────┴────────────┘
                           ▼
                         R137
                    (cross-host)
                           │
                           ▼
                         R139
                  (multi-session)
                           │
                           ▼
                         R141
                    (perf + hardening)
```

### 5.3 New-repo bring-up ordering

The five new satellite repos need to be created in this order:

1. **libpdx-pipeline-rt** — first, before R121.M3 can land; it consumes libpdx-schema-registry.
2. **libpdx-unicode-tables** — second, before R131.M1; it is a leaf dep with no downstream constraint.
3. **libpdx-kitty-gfx** — third, before R129.M1; depends on libpdx-unicode-tables (M5 width calc).
4. **libpdx-shell-repl** — fourth, before R127.M1; depends on libpdx-schema-registry.
5. **libpdx-wasi-bridge** — fifth, before R135.M1; depends on libpdx-pipeline-rt.

Each new repo follows the paideia-as-established layout: `Cargo.toml`-
free (all `.pdx`), workspace-versioned semver, `find-paideia-as.sh`
strict, CHANGELOG required per the paideia-as version discipline
memory. Each repo starts at 0.1.0 and moves along the standard PA
milestone lattice.

### 5.4 R110-XREPO ordering constraint

R121.M3 depends on `libpdx-semantic-pipe` shipping a **2.x** API that
exposes the payload's outer envelope for LAM tagging. That is the
R110-XREPO Phase-A design lock. Per MASTER_PLAN §9.2, R110-XREPO
Phase-A dispatches after Wave 3 M5 close (R100 + R102). If this
document lands into the queue *before* R110-XREPO Phase A completes,
R121.M3 blocks — R121.M1..M2 can proceed against the 1.x wire, but M3
onward gates on 2.0. This is called out in the risk register (§6.1).

---

## 6. Risk register

### 6.1 R110-XREPO 2.0 not yet cut when R121 starts

**Risk.** MASTER_PLAN schedules R110-XREPO Phase A after Wave 3 M5.
If this plan's R121 dispatches earlier, R121.M3 blocks.
**Mitigation.** Sequence: (a) do not dispatch R121 issues until R110-
XREPO Phase A design freeze completes; (b) alternatively, ship R121.M3
against the 1.x wire and migrate in-place when 2.0 lands (LAM
envelope becomes an outer wrapper rather than an inner byte range).
Adopt (a) unless the plan wall-clock demands (b).

### 6.2 Kitty protocol fragmentation

**Risk.** The Kitty graphics protocol has evolved; different terminal
emulators support different subsets. XTGETTCAP probing is not
universally supported.
**Mitigation.** R129.M1 falls back to a manual capability query on
XTGETTCAP failure; if the manual query also fails, assume ANSI-only.
R129.M6 (Sixel) covers a wider tail. Explicitly not-supported
terminals get plain-text fallback (SH-D8 §9.4 no-VT100 stance stands).

### 6.3 Unicode table size on boot

**Risk.** UCA collation tables at ~1.5 MiB per locale × 12 shipped =
~18 MiB — non-trivial in a kernel with a 4-KiB tmpfs baseline.
**Mitigation.** Locales are mmap'd read-only from the CoW FS, not
loaded to RAM at boot. Only the actively-set locale's collation table
is paged in; others page in on demand. Per HST/§14 semantic-shell.md
budget of 100 MB/s NFC normalization, the fast path is entirely
compute-bound and does not touch UCA tables.

### 6.4 Capability-env row size explosion

**Risk.** A KIND_CAP_ENV row of "variable-len up to 128 caps × 32 B"
= 4 KiB per session; multiplied by concurrent sessions plus every
minted sub-cap for every command invocation, this becomes hot memory.
**Mitigation.** Per-cap deduplication in the row layout: identical
caps referenced by multiple slots point to a shared cap-rights
descriptor. R125.M1 must land this dedup discipline in the initial
row layout rather than retrofit.

### 6.5 wasmtime port scope creep infecting R135

**Risk.** R135 explicitly does NOT port wasmtime — but reviewers may
push to land a working wasmtime alongside the bridge, doubling the
round's scope.
**Mitigation.** R135's acceptance criteria are all stub-based:
`stub-echo`, `stub-net`, hand-written WIT descriptors. Wasmtime port
is filed as a separate future round (working name R145 or later) with
its own 100+ issue estimate. Land R135 with stubs; wasmtime follows.

### 6.6 Cross-host federation trust model unspecified

**Risk.** R137.M3 depends on `design/capabilities/distributed.md`
for the federation-member capability. If that doc is thin, R137.M3
lands on a placeholder cap and later needs migration.
**Mitigation.** Before R137 dispatches, do a companion 2-issue plan
against `design/capabilities/distributed.md` to lock the federation
capability shape; land those first. Include a placeholder-TOML at
`/system/federation/hosts.toml` for initial bring-up; move to
signed federation membership when the doc lands.

### 6.7 The two prereq bugs are harder than they look

**Risk.** #2469 and #2470 involve CLOEXEC, refcount, wait4 ordering,
and pipe-fd inheritance — all classic sources of hard-to-repro fork/
exec bugs. If R119 takes 2 weeks instead of 3 days, the whole plan
slips.
**Mitigation.** R119.M1 (witness expansion) lands *first*, before
any fix attempt. Once every fd operation is visible in the boot log,
diagnosis time drops from days to hours. If R119 still slips, the
issue authors escalate to comparch for hardware-behavior confirmation
(VMX exit reasons for the pipe stall).

### 6.8 Perf budgets are aspirational; real numbers may miss

**Risk.** §14 of semantic-shell.md sets 200 ns intra-process record
pass. On QEMU without KVM this is easily 10-50× slower.
**Mitigation.** R141.M5 records both QEMU and bare-metal numbers.
Budgets are pass/fail on bare-metal; QEMU numbers are informational.
If bare-metal misses budget by more than 2×, a follow-up perf round
opens (working name R143 or later) rather than gating R141 close.

---

## 7. Totals and wall-clock

### 7.1 Issue count summary

| Round | Focus | Issues |
|---|---|---|
| R119 | fd-hygiene unblockers | 12 |
| R121 | Pipeline runtime + Q13 hybrid transport | 42 |
| R123 | Command-module functor loader + registry | 30 |
| R125 | Capability flow at exec | 28 |
| R127 | REPL session process + history | 32 |
| R129 | Rendering (Kitty + fallback) | 34 |
| R131 | Unicode substrate | 24 |
| R133 | `.pds` script loader | 20 |
| R135 | WASM jail bridge substrate | 30 |
| R137 | Cross-host pipeline transport | 26 |
| R139 | Multi-session + audit | 22 |
| R141 | Perf baselines + hardening | 18 |
| **Total (osarch half)** | | **318** |

The companion softarch document (R120, R122, R124, R126, R128, R130,
R132, R134, R136, R138, R140) will land the language-surface half —
parser, HM type checker with effect rows, Datalog evaluator (semi-
naive + magic-set + stratified negation), lambda evaluator with
closure conversion, LSP embedding, tab-completion surface. Estimated
softarch count: ~250. **Combined osarch + softarch estimate: ~570
issues.**

### 7.2 Wall-clock

At continuous AISSUE tempo (roughly one dispatch every 90 minutes for
substrate-heavy work, running the paideia-os autonomous loop shape
per feedback_paideia_os_loop_shape.md):

- **R119** — 3 days (small round, but debugging-heavy)
- **R121** — 6 days (largest round; new satellite repo bring-up)
- **R123** — 4 days
- **R125** — 4 days
- **R127** — 5 days (new satellite repo bring-up)
- **R129** — 5 days (new satellite repo bring-up)
- **R131** — 4 days (new satellite repo bring-up, tables-heavy)
- **R133** — 3 days
- **R135** — 4 days (new satellite repo bring-up)
- **R137** — 4 days
- **R139** — 3 days
- **R141** — 3 days

**Serial wall-clock: ~48 days = ~7 weeks.**

**With parallelism** — R131 (Unicode) is a leaf that runs alongside
anything; R123 + R125 can run parallel-plus-serial (they share the
KIND_CAP_ENV row but touch different call sites); R135 depends on
R125.M2 and R121.M5 but can otherwise proceed independently of R127
and R129. Realistic parallel schedule: **~4-5 weeks**.

**Termination condition.** The plan completes when R141.M6 lands
green — i.e. the smoke test's `--perf` mode passes with all seven
metrics within budget, the initial `perf-baselines.md` is committed,
and the softarch companion has closed its final round. At that
point, the semantic shell is materialized: a user typing `find . |
where ext == "pdf" | datalog { cited_by(?p, $it) } | sort by size
desc | head 10 | as chart` gets the expected chart on-screen, with
capability-flow enforced, Unicode-correct, cross-host-capable, and
audit-logged.

---

*End of document.*
