# R49 + R50 — Unified Tooling Wave (Architecture Half, §1–§4)

**Status:** proposal (2026-08-21, osarch Round 1 of a 2-round planning wave)
**Companion:** `design/tooling/plan.md` (Tier-3 catalogue + invariants I1–I7), `design/tooling/priority-and-release.md` (round/priority table).
**Depends on:** paideia-os kernel through R48 (user management: `KIND_USER = 0x190`, elevate protocol via `KIND_IPC_ENDPOINT` frames at `elevate_channel.pdx` / `elevate_policy.pdx` / `user_events_journal.pdx`); R42-scheduled PdxFS v1 (`KIND_PDXFS_FILE`, `KIND_PDXFS_TXN`); R41 semterm engine + resultset (commits `92ee50c` and `251cd7c`); G1–G6 GPU-native GUI stack; paideia-as ≥ v0.33-crypto-kdf (Argon2id + ChaCha20-Poly1305 + ML-DSA-65 verify).
**Round 2 owner:** softarch — extends this doc with a §5 that lists per-tool milestones, issues, and internal module structure. This §1–§4 is the source of record for the 9 tool repos + 5 shared-library repos main will create after softarch closes.
**Scope:** the 9 P0 tools that ship across the R49 (pkg, shell, doc) and R50 (ls, cat, cp, mv, rm, mkdir) tooling waves, plus the 5 shared libraries that block them.

---

## 0. Reading order

- §1 executive summary — the 9 tools' P0 role, the substrate they now stand on, the load-bearing invariants that distinguish them from GNU coreutils.
- §2 cross-tool boundaries + dependency DAG — direct-vs-shape dependencies, cross-repo deps on paideia-os and paideia-as, note that this doc is the authoritative source for the repo-creation wave.
- §3 shared cross-tool libraries — the 5 R49-wave libraries (libpdx-cap, libpdx-semantic-pipe, libpdx-argv, libpdx-audit, libpdx-elevate); each has a repo, a responsibility, a consumer list, a wave assignment.
- §4 per-tool architectural summary + KIND references — for each of the 9 tools: repo name, one-line purpose, kernel KINDs consumed, KINDs the tool introduces (for softarch to allocate ordinals), semantic-pipe schemas emitted on stdout, cap requirements at invocation, undo/audit obligations.

Round 2 (softarch) will extend with §5–§8 (per-tool milestones + issues + module structure + risks).

---

## 1. Executive summary

R49 and R50 are the first two tooling waves after the R48 user-management substrate closed. Together they ship 9 P0 tools — `pkg`, `shell`, `doc` (R49) and `ls`, `cat`, `cp`, `mv`, `rm`, `mkdir` (R50) — plus 5 shared libraries that every tool in the ecosystem will import. This is the minimum viable user experience: after both waves land, a founder or delegated user can boot into a semantic terminal, install a signed package, view its docs, and perform the six coreutils operations that make a filesystem tractable. Every subsequent tool — the ~86 tools in the Tier-3 catalogue at `design/tooling/plan.md` §5 — inherits the substrate this wave establishes.

The nine tools do not reimplement GNU coreutils. The catalogue names are chosen for muscle memory (D3 in `design/tooling/plan.md`), but the behaviours differ on three load-bearing axes. First, every tool emits both text and typed-schema records on its stdout (D2 semantic pipes) so downstream consumers can filter, sort, or plot by schema field rather than by column-slicing text; the pipe is a subclass of `KIND_IPC_ENDPOINT` (base kind 5 from R20b) carrying a schema handle alongside the byte stream. Second, every install and every destructive operation ships a signed manifest (D4) validated with the paideia-as v0.33 crypto substrate (ML-DSA-65 dual-signature per `design/user/model.md` §2 + the R48.M7 elevate-request codec at `src/kernel/core/ipc/elevate_channel.pdx`); nothing runs as a setuid analog, and nothing installs a binary the user has not explicitly consented to via the per-operation elevate flow. Third, every operation — read as well as write — journals to `/system/audit/user-events/` before it emits any user-visible output (D3 audit-first, upgrading I5 undo from "destructive ops are reversible" to "every operation is discoverable"); `rm` and `mv` and `cp --over-existing` additionally journal an undo record on PdxFS v1 (I5), but every tool's participation in the audit graph is a first-class obligation, not an optional flag.

The wave splits into two rounds because `pkg` blocks every other tool by construction: no tool can be installed until the package manager exists, and every tool ships as a signed package. `shell` and `doc` follow `pkg` because `shell` is the process that spawns the coreutils and `doc` reads the `.pdxdoc` files every tool ships as its `--help` back-end. Once `pkg`, `shell`, and `doc` are runnable at end of R49, the six coreutils in R50 begin in parallel — they are shape-alike, share the same cap-request template, and each has a small enough scope that a single-tool team can carry it to first release inside a wave. The 5 shared libraries (`libpdx-cap`, `libpdx-semantic-pipe`, `libpdx-argv`, `libpdx-audit`, `libpdx-elevate`) all land in R49 because they block every R50 tool; the ~6 additional libraries the full plan calls for (pdx-regex, pdx-time, pdx-help, pdx-color, pdx-tls, libpaideia-ui) land at R51+ when the tools that need them (grep, less, GUI variants) begin.

---

## 2. Cross-tool boundaries and dependency graph

### 2.1 Direct-vs-shape dependency taxonomy

Two dependency kinds are tracked in this section, distinguished because they have different consequences at repo-creation time:

- **Direct (must-have).** Tool X links (or dynamically dispatches through the loader-seeded cap slot) code from tool Y or library L; X cannot ship until Y/L exists at a specified version. `ls --long` cannot render a file's owner until `libpdx-cap` can decode a `KIND_USER` tail, so `ls` has a direct dependency on `libpdx-cap ≥ 0.1`.
- **Shape (needs the same convention).** Tool X and tool Y both consume the same kernel primitive and therefore must interpret it identically, but neither links the other. `cp` and `mv` both read `KIND_PDXFS_FILE` inode metadata; a divergent decode would let `cp file1 dir/ && mv dir/file1 file2` produce a file with mismatched provenance. Shape dependencies are cheap to violate silently, expensive to detect, and are surfaced here so softarch's Round 2 can bind them via a shared library — usually `libpdx-cap` or `libpdx-semantic-pipe`.

### 2.2 The R49 + R50 DAG

```
                                paideia-as v0.33-crypto-kdf
                                (Argon2id + ChaCha20-Poly1305 + ML-DSA-65 verify)
                                        │
                                        ▼
                    ┌───────────────────────────────────────┐
                    │  paideia-os kernel through R48        │
                    │    KIND_IPC_ENDPOINT   (R20b, base 5) │
                    │    KIND_USER           (R48.M1, 0x190)│
                    │    elevate_channel     (R48.M7)       │
                    │    elevate_policy      (R48.M7)       │
                    │    user_events_journal (R48.M7)       │
                    │    KIND_PDXFS_FILE     (R42, TBD)     │
                    │    KIND_PDXFS_TXN      (R42, TBD)     │
                    │    loader InitCap seed (R20b.M4)      │
                    └───────────────┬───────────────────────┘
                                    │
      ┌─────────────────────────────┼─────────────────────────────┐
      ▼                             ▼                             ▼
libpdx-cap              libpdx-semantic-pipe          libpdx-argv   libpdx-audit   libpdx-elevate
      │                             │                     │              │              │
      └──────────────┬──────────────┴──────┬──────────────┴──────────────┴──────────────┘
                     │                     │
                     ▼                     ▼
                   pkg  ────────────────► shell
                    │                       │
                    │                       ▼
                    │                     doc
                    │                       │
                    │   R49 close ══════════╧═══════════════════════════════════
                    │
                    ├─────────► ls
                    ├─────────► cat
                    ├─────────► cp     (also needs shell for interactive prompts)
                    ├─────────► mv     (also needs shell)
                    ├─────────► rm     (also needs shell)
                    └─────────► mkdir  (also needs shell)
                                        R50 close
```

### 2.3 The three ordering rules the DAG encodes

**Rule 1 — `pkg` blocks everything.** `pkg` is the tool that installs every other tool. It ships bootstrapped: the first-ever install builds `pkg` from source with the paideia-as toolchain (`paideia-as build /tmp/pkg.pdx -o /tmp/pkg`), then `pkg install pkg` self-installs the signed binary. From that point every subsequent tool arrives via `pkg install <name>`. This means every R49 and R50 tool has a hard dependency on `pkg` reaching self-install (its `T-P0-WAVE-1` scope in `design/tooling/plan.md` §10) before its own release. `shell` and `doc` are the exceptions only in the sense that they can be built and locally-run from source during R49 without going through `pkg install`; every tool from R50 onward is installed only via signed package.

**Rule 2 — `shell` blocks `doc`.** `doc` reads `.pdxdoc` files that every tool ships as its `--help` back-end. It is invoked as `doc <tool>` from within a running shell process, and its output goes through the semantic pipe (rendered text layer for interactive readers; typed `PdxDocEntry[]` records for downstream `query` or `pipeviz` tools that arrive at R59). `doc` therefore needs `shell` to reach a runnable state — the shell's line reader, the shell's stdout binding for `KIND_TTY`, the shell's cap-environment propagation — before it has a runtime to render into. In terms of the DAG this is a direct dependency on `shell ≥ 0.1`.

**Rule 3 — coreutils can all begin in parallel once `shell` is runnable.** `ls`, `cat`, `cp`, `mv`, `rm`, `mkdir` share the same invocation shape (a `shell`-spawned child process, receiving its caps via the loader's InitCap sidecar plus any caps passed from the shell's cap environment) and the same output shape (typed schema records on stdout, rendered text as a display hint). No coreutils tool depends on another. Softarch's Round 2 will split R50 into six milestones running concurrently once `shell` publishes its `SPAWN OK` fingerprint on the smoke matrix; each of the six can carry its own team through issue-file-through-first-release without cross-blocking.

### 2.4 Cross-repo dependencies

**On paideia-os (this repo).** Every R49 and R50 tool depends on kernel APIs that were closed by R48. `KIND_IPC_ENDPOINT` (R20b, base kind 5) is the pipe substrate. `KIND_USER` (R48.M1-001, `kind_user.pdx` at `pub let KIND_USER : u64 = 0x190`) is the identity root every tool checks before it opens a file. The elevate protocol at `src/kernel/core/ipc/elevate_channel.pdx` + `src/kernel/core/user/elevate_policy.pdx` + `src/kernel/core/user/user_events_journal.pdx` is the R48.M7 substrate `pkg` uses to request temporary caps for `pkg install`. The loader's InitCap sidecar (R20b.M4-001 at `src/kernel/core/loader/init_caps.pdx`) is how each tool receives its initial cap set from `shell` at exec time. **PdxFS v1** (`KIND_PDXFS_FILE`, `KIND_PDXFS_TXN`) is scheduled at R42 in `design/tooling/priority-and-release.md` §Release-code legend but has not landed in the current kernel — there is no `kind_pdxfs_file.pdx` in `src/kernel/core/cap/` at HEAD (2026-08-21). Softarch Round 2 must call out this substrate gap in §5: either PdxFS v1 lands in a substrate round scheduled before R49 close (recommended, since `pkg install` writes `/pkgs/<name>-<version>/` and needs a journaled write path), or the R49 wave slips.

**On paideia-as (submodule).** `pkg` and `libpdx-elevate` need the crypto primitives bundled at paideia-as v0.33-crypto-kdf per `design/user/model.md` §11.2: Argon2id-KDF (to unlock the user's passphrase-sealed `user_sk` before signing a dual-sig-verified package manifest), ChaCha20-Poly1305 (for AEAD in the same path), and ML-DSA-65 verify (to check the two signatures — author + paideia_root — on every `manifest.pdxsig`). The v0.33 bundle is filed at paideia-as issues #1302–#1306 per the memory index (`project_paideia_as_bootstrap`). Softarch Round 2 must confirm the version at which each primitive is exposed as a paideia-as stdlib intrinsic before R49 tools can lock the dependency.

**On paideia-os design docs.** `design/user/model.md` binds the identity model this wave enforces; `design/tooling/plan.md` D1–D5 binds the invariants; `design/tooling/priority-and-release.md` schedules the waves; `design/ipc/typed-handoff.md` binds the schema-version discipline the semantic pipe uses. Any change to those four docs during the R49 or R50 windows must be reflected here.

### 2.5 This doc as the repo-creation authority

After softarch's Round 2 extends this doc with per-tool milestones and issue titles, **main** (the user) will:

1. Create 9 public repos under `github.com/paideia-os/`: `pkg`, `shell`, `doc`, `ls`, `cat`, `cp`, `mv`, `rm`, `mkdir`.
2. Create 5 public repos under `github.com/paideia-os/`: `libpdx-cap`, `libpdx-semantic-pipe`, `libpdx-argv`, `libpdx-audit`, `libpdx-elevate`.
3. File ~15 issues per tool (softarch will draft titles in §5).
4. File ~10 issues per shared library (softarch will draft titles in §5).

The 14 repos are the union of §3 (5 libraries) and §4 (9 tools). This document — after Round 2 — is the source of record: no tool repo is created without a §4 entry here; no library repo is created without a §3 entry here. Deviations are filed as amendments to this doc, not as bare repo creations.

---

## 3. Shared cross-tool libraries

The 5 libraries below block the R49 wave: no tool ships until its dependencies here reach v0.1. Each library gets its own public repo under `github.com/paideia-os/`, its own `caps.decl` (libraries mint no caps themselves; the file declares which caps their clients must supply), and its own signed release manifest.

The 5 chosen here are the R49-blockers — they are the minimum set that lets the 9 tools compile, link, and pass the smoke matrix. The full plan (`design/tooling/plan.md` §7) additionally names `pdx-regex`, `pdx-time`, `pdx-help`, `pdx-color`, `pdx-tls`, `semantic-term-core`, and `libpaideia-ui`; those are R50-optional or R51-wave dependencies and are called out in the "Ships in wave" column below rather than treated as R49-blockers.

### 3.1 `libpdx-cap` — capability marshalling for tool invocations

**Repo:** `paideia-os/libpdx-cap`
**Ships in wave:** R49 (blocks every tool).
**Responsibility.** Serialize, transport, and deserialize a capability across the process boundary between a caller (`shell`) and a callee (a tool). The kernel primitive is `sys_cap_transfer` (part of the R20b IPC substrate); `libpdx-cap` is the userspace-side idiom for pack/unpack + rights-narrowing at the send site + rights-check at the receive site. Concretely it exposes: `cap_pack(slot, narrow_rights) → wire_form`, `cap_unpack(wire_form) → slot`, and `cap_manifest_verify(caps.decl, received_caps) → OK | MISSING | EXTRA`. It also carries the `caps.decl` parser that every tool ships (per invariant I6 in `design/tooling/plan.md` §4.2); if a tool's `caps.decl` says it needs `KIND_PDXFS_FILE(read, subtree=<home>)` and the shell passed a `KIND_PDXFS_FILE(read, subtree=/system)`, `cap_manifest_verify` refuses at exec.
**Consumers.** All 9 tools; the shell (as sender) and every callee tool (as receiver). Plus `libpdx-elevate` at §3.5, which builds its `ElevateRequest` records on top of `libpdx-cap` wire form.
**Interaction with existing kernel code.** Reads the descriptor layout at `src/kernel/core/cap/descriptor.pdx`; the wire form matches the InitCap sidecar record shape at `src/kernel/core/loader/init_caps.pdx` (`slot:u16, kind:u16, rights:u32, target_ptr:u64`, 16 bytes, 8-byte aligned) so a `shell → tool` handoff can be carried by the same loader hook that seeds `init`'s caps.

### 3.2 `libpdx-semantic-pipe` — schema-typed pipe endpoints

**Repo:** `paideia-os/libpdx-semantic-pipe`
**Ships in wave:** R49 (blocks every tool that emits typed output — 8 of 9).
**Responsibility.** Wrap a `KIND_IPC_ENDPOINT` (base kind 5, R20b tail encoding at `src/kernel/core/cap/kind_endpoint.pdx`) so that both ends of a pipe agree on a schema before the first byte of payload flows. Semantic pipes are the D2 wire format from `design/tooling/plan.md` §3: three concurrent layers (rendered text, typed schema records, cap list). This library implements the framing: the R20b 8-byte header (`op:u8, ver:u8, flags:u16 LE, payload_len:u32 LE` at `src/kernel/core/ipc/frame.pdx`) carries a `flags` bit indicating "typed record follows", and the payload prefix is a `schema_hash: [u8;32]` (BLAKE3-truncated schema fingerprint) followed by the record body. A consumer that does not know the schema drops the record and falls through to the text-layer line; a consumer that does know the schema decodes it directly, in-process, without JSON re-encoding.
**Consumers.** 8 of 9 tools (all except `mkdir`, whose output is a stderr-only diagnostic under I4). Also `libpdx-audit` at §3.4, whose audit records travel on a semantic pipe to the audit journal at `/system/audit/user-events/`.
**Key design point.** The schema handle is per-*pipe*, not per-*message*; the sending tool declares its output schema once at `libpdx_semantic_pipe_bind(fd, schema_id)` (checked against the tool's `caps.decl`), and every subsequent frame is validated against the bound schema. This matches the R48.M7 pattern in `elevate_channel.pdx` where one pending-hdr slot carries a typed-message-count invariant (`endpoint_take_pending` / `endpoint_write_pending` are the single-in-flight primitives). The library is the userspace-side rules the kernel primitives enforce.

### 3.3 `libpdx-argv` — CLI argument parsing

**Repo:** `paideia-os/libpdx-argv`
**Ships in wave:** R49 (blocks every tool with a CLI surface — all 9).
**Responsibility.** Implement the D3 flag grammar from `design/tooling/plan.md` §3: long flags primary, short flags one-per-hyphen (never clustered), typed flag arguments (`--older-than 7d`, `--size > 1MB`), the 9-flag standard vocabulary from I3 (`--help`, `--version`, `--dry-run`, `--json`, `--schema`, `--verbose`, `--quiet`, `--color=`, `--no-cap:<name>`). Also implements the invocation surface for D2: the tool can be called with `argv` (text CLI) or with a typed-schema record (semantic-pipe invocation from another tool that already knows the callee's `--schema` shape). Both paths converge on the same internal `ParsedArgs` structure, so a tool's implementation code never asks whether it was called from a text shell or from another tool.
**Consumers.** All 9 tools; also `libpdx-elevate` (parses `elevate 'pkg install ls' --for 60s`).
**Non-consumers.** The shell itself does not use `libpdx-argv` for its interactive line-reader — that is `semantic-term-core` territory (R41 semterm engine, already landed at commits `92ee50c`/`251cd7c`). `libpdx-argv` handles the *child process's* argv, not the shell's line editor.

### 3.4 `libpdx-audit` — audit-first output

**Repo:** `paideia-os/libpdx-audit`
**Ships in wave:** R49 (blocks every tool per D3 audit-first upgrade of I5).
**Responsibility.** Every user-facing operation — including *read* operations, not just destructive ones — emits an audit record to `/system/audit/user-events/` *before* it emits any user-visible output. This is a strict upgrade of `design/tooling/plan.md` I5 (which required only destructive-op undo journaling): D3 audit-first from §1 of this document means every tool journals every operation, and the shell renders a `--verbose` mode that displays the audit ID next to each output line. The library exposes `audit_begin(op_name, args) → audit_id`, `audit_record_output(audit_id, output_schema, output_hash)`, and `audit_commit(audit_id, exit_code)`. The three-call shape mirrors the kernel's own transaction pattern at `KIND_PDXFS_TXN` (once PdxFS v1 lands per §2.4): begin → record → commit, with commit failure invalidating the whole record.
**Consumers.** All 9 tools. Also the shell, which appends a per-command audit record before exec and a per-command exit-status record after wait.
**Interaction with existing kernel.** Writes through `sys_ipc_send` (R20b.M3-002 at `src/kernel/core/syscall/handlers/sys_ipc_send.pdx`) into an endpoint bound to the `svc.audit-journal` broker name (R20b.M1-003 at `src/kernel/core/ipc/svc_broker.pdx`). The audit-journal service itself is a supervisor process; its schema matches the `UEJ_KIND_*` constants at `src/kernel/core/user/user_events_journal.pdx` (which already defines `UEJ_KIND_ELEVATE = 5` for elevate events, and softarch will extend with `UEJ_KIND_TOOL_INVOKE`, `UEJ_KIND_TOOL_OUTPUT`, `UEJ_KIND_TOOL_EXIT` in Round 2). The pre-output audit-write is a non-optional gate: if the audit journal is full or the service is unreachable, the tool refuses to emit output — exit code 3 (system error per I4). This is intentionally strict; a tool that can suppress its own audit trail is a category of attack the D3 upgrade forecloses.

### 3.5 `libpdx-elevate` — client-side elevate protocol helper

**Repo:** `paideia-os/libpdx-elevate`
**Ships in wave:** R49 (blocks `pkg`; every other tool uses it only for optional `--elevate` flags).
**Responsibility.** Build an `ElevateRequest` frame using the R48.M7 codec at `src/kernel/core/ipc/elevate_channel.pdx` (`elv_pack_request` at line 174, `elv_cap_mask_valid` at 117, `elv_duration_valid` at 144), send it to the founder's approval channel via the `svc.elevate-broker` broker name, block on the reply, and hand the caller a `Cap<KIND_ELEVATE_RESPONSE>` with a bounded lifetime. Also implements automated retry against the elevate-policy table at `src/kernel/core/user/elevate_policy.pdx`: if the founder registered an auto-approve rule for a matching op-pattern + cap-mask + duration, the request satisfies from the policy table without hitting a human. The library is the userspace-side idiom that translates a call site's intent ("I want to install a package; I need `KIND_PDXFS_FILE(write, /pkgs)` for 60 seconds") into a wire-conformant elevate request the kernel's codec will accept.
**Consumers.** `pkg` (the primary consumer; every `pkg install` runs through `libpdx-elevate`); optionally `mv` and `cp` if the target crosses a per-user-subtree boundary that would exceed the caller's cap scope; optionally `rm` if the target is under `/system/`.
**Non-consumers.** `ls`, `cat`, `mkdir` — these operations do not cross user boundaries and never need per-op elevation.
**Note on KIND.** The user's brief refers to `KIND_ELEVATE_REQUEST` as an R48.M7 kernel KIND; the actual R48.M7 substrate does *not* introduce a new base or derived KIND — elevate messages travel on `KIND_IPC_ENDPOINT` frames using the codec at `elevate_channel.pdx` (see kernel-code check at §4.1 for the full list of kinds that were and were not introduced by R48.M7). `libpdx-elevate` is where the request/response payload gets its semantic type. Softarch Round 2 should decide whether to introduce a derived `KIND_ELEVATE_CHANNEL` over `KIND_IPC_ENDPOINT` for schema-level distinctness at the receive side; if introduced, its ordinal is a Round-2 allocation.

### 3.6 Libraries NOT in the R49 blocker set

For traceability against `design/tooling/plan.md` §7, the libraries listed there but not in this section are deferred:

| Library | Deferred to | Why not R49 |
|---------|-------------|------------|
| `pdx-regex` | R51 | First consumer is `grep` at R51; not needed for R49/R50. |
| `pdx-time` | R54 | First consumer is `date` at R54; `ls --long` renders mtime via `libpdx-cap`-level integer formatting until then. |
| `pdx-help` | Rolled into `libpdx-argv` for R49 | `--help` for the 9 tools is text-only in R49; hyperlinked rich help arrives with `doc` R51 upgrades. |
| `pdx-color` | R51 | Color output for R49/R50 tools uses ANSI SGR directly through R23 fb-console; `pdx-color` unifies the palette when `less` and `grep` add multiple output styles. |
| `pdx-tls` | Post-TCP round (est. R43–R46 per priority-and-release.md caveat) | No R49/R50 tool crosses the network. |
| `semantic-term-core` | Already lands with R41 semterm; already commit `92ee50c` / `251cd7c` | Not new. |
| `libpaideia-ui` | R60+ | R49/R50 tools are TUI-only per D1 (Tier-3 scope explicitly excludes GUI variants of coreutils). |

---

## 4. Per-tool architectural summary + KIND references

Nine sections below, one per tool. Each carries: repo name, one-line purpose, kernel KINDs consumed, KINDs the tool would introduce (for softarch to allocate ordinals in Round 2), semantic-pipe schemas emitted on stdout, cap requirements at invocation, undo/audit obligations. Cross-tool shape dependencies (from §2.1) are called out inline where they exist.

### 4.1 `pkg` — the package manager

**Repo:** `paideia-os/pkg`
**Purpose.** Install, upgrade, remove, list, and audit signed tool packages from `pkgs.paideia-os` and mirrors; the tool that bootstraps every other tool.
**Existing kernel KINDs consumed.**
- `KIND_USER` (0x190, R48.M1 at `src/kernel/core/cap/kind_user.pdx`) — the identity under which the install is being performed; `pkg` checks quota against the tail's `quota_bytes` before extracting.
- `KIND_IPC_ENDPOINT` (base kind 5, R20b at `src/kernel/core/cap/kind_endpoint.pdx`) — pipe to the elevate broker and to the audit journal.
- `KIND_PDXFS_FILE`, `KIND_PDXFS_TXN` (R42, TBD) — for `/pkgs/<name>-<version>/` extraction; the TXN cap is opened once per install so a partial install rolls back cleanly. **Substrate note:** neither KIND exists in the current kernel; the R42 landing is a hard prerequisite for `pkg`'s v0.1.
- Elevate protocol via the R48.M7 codec at `src/kernel/core/ipc/elevate_channel.pdx` — every `pkg install` requests `KIND_PDXFS_FILE(write, /pkgs)` + `KIND_NETWORK(fetch, pkgs.paideia-os)` + `KIND_SIGNATURE(verify, paideia_root_pk)` for a bounded duration (per `design/user/model.md` §5.1 example).
**New KINDs introduced.**
- `KIND_PACKAGE_MANIFEST` (proposed, derived over `KIND_PDXFS_FILE`) — a per-package cap that binds a `manifest.pdxsig` file to a specific dual-signature verification result; holding this cap proves both signatures verified without a re-verify at every open. Softarch Round 2 allocates the ordinal.
- `KIND_PACKAGE_REPO` (proposed, derived over `KIND_NETWORK`) — a per-repo cap; holding it grants fetch rights to exactly that repo's URL prefix. Rate-limited via the elevate-policy substrate.
**paideia-as v0.33-crypto dependency.** Direct — every `pkg install` invokes `ml_dsa_65_verify` twice (author sig + paideia_root sig) on `manifest.pdxsig`; every `pkg install --from-source` invokes `argon2id_kdf` to unlock the user's `user_sk` for the source-tree-signature check.
**Semantic-pipe schemas emitted.** `PackageManifest[]` on `pkg list --available`; `InstallProgressRecord[]` on `pkg install` (one record per stage: resolved, verified-author, verified-root, cap-audit, installed); `KeyFingerprintRecord[]` on `pkg keys list`.
**Cap requirements at invocation.** `Cap<KIND_USER>` (self); no filesystem write cap at invocation — write caps are acquired per-install via `libpdx-elevate`. This is deliberate: `pkg` never runs with ambient write authority on `/pkgs/`.
**Undo/audit obligations.** Every install and every remove journals to `/system/audit/user-events/pkg-<ts>-<audit_id>.pdxevent` (via `libpdx-audit`). Every install additionally journals an undo record to PdxFS v1 so `undo pkg install ls` reverses to the prior `/bin/ls` symlink target (I5). `pkg remove` writes an undo record whose replay is `pkg install <name>@<the-removed-version>`.

### 4.2 `shell` — the semantic-native command shell

**Repo:** `paideia-os/shell`
**Purpose.** Successor to R17 shell, schema-native; the process that reads user commands, spawns tool processes with the caller's cap environment narrowed per the callee's `caps.decl`, threads text-and-schema-and-cap layers through pipes, and hosts the `mux` splits (once `mux` arrives at R57).
**Existing kernel KINDs consumed.**
- `KIND_USER` (0x190) — the session cap; every child process inherits a sub-cap derived from this via `libpdx-cap`.
- `KIND_IPC_ENDPOINT` (base kind 5) — the pipe primitive; every `|` in a pipeline mints one via `sys_svc_lookup` (R20b.M3-003 at `src/kernel/core/syscall/handlers/sys_svc_lookup.pdx`) or a direct `sys_ipc_recv`/`sys_ipc_send` pair.
- `KIND_TTY` (existing, base kind slot in the pre-R48 catalogue — softarch Round 2 confirms the ordinal from `src/kernel/core/cap/` at HEAD) — the terminal-render binding; the shell holds a `KIND_TTY(write)` and delegates a sub-cap to each child.
- Loader InitCap sidecar (R20b.M4-001 at `src/kernel/core/loader/init_caps.pdx`) — the shell writes an InitCap blob for each child that binds the child's cap slots at exec.
- `KIND_PDXFS_FILE` (R42) — for reading `.pds` scripts (per `design/terminal/pds-format.md`) and for writing `~/.history/` (session history persistence).
**New KINDs introduced.**
- `KIND_SHELL_SESSION` (proposed, derived over `KIND_USER`) — a shell's session cap; a delegated sub-cap for `mux` splits and for `remote`-shell nesting (R56+). Softarch Round 2 allocates the ordinal.
**paideia-as v0.33-crypto dependency.** Indirect — the shell does not sign or verify; it delegates to `pkg` and `libpdx-elevate` when the user runs those commands.
**Semantic-pipe schemas emitted.** `ShellPromptRecord` on interactive prompt; `CommandCompletion[]` for tab-completion suggestions (schema-registry-driven per `design/terminal/semantic-shell.md` SH-D7); `HistoryEntry[]` for `history` queries. The shell also *forwards* every child's schema pipe unchanged to the pipeline consumer — the shell is a semantic-pipe passthrough, not a schema-erasing byte stream (this is D2 literal from `design/tooling/plan.md`).
**Cap requirements at invocation.** `Cap<KIND_USER>` (session cap from the login path per `design/user/model.md` §2.2); `Cap<KIND_TTY(write)>` (from the terminal); `Cap<KIND_PDXFS_FILE(read, /system/bin)>` (to `exec` installed tools).
**Undo/audit obligations.** Every command execution journals a `ShellCommandRecord` to the audit journal before `sys_execve` (via `libpdx-audit`); the record is closed with the child's exit code after `wait`. Interactive history writes to `~/.history/` are PdxFS v1 CoW-journaled so a `undo history clear` restores the prior file.

### 4.3 `doc` — the interactive documentation reader

**Repo:** `paideia-os/doc`
**Purpose.** The `.pdxdoc` reader; renders long-form documentation (man-equivalent per `design/tooling/plan.md` I7) with cross-reference navigation, POSIX-difference annotations, and inline example gallery. Emitted by every tool's `--help`; invoked directly as `doc <tool>`.
**Existing kernel KINDs consumed.**
- `KIND_USER` (0x190) — invoker identity for audit records.
- `KIND_IPC_ENDPOINT` (base kind 5) — semantic-pipe output.
- `KIND_TTY(write)` — rendered text output; ANSI SGR for highlight, paginated per terminal height.
- `KIND_PDXFS_FILE(read, /system/doc)` (R42) — reads `.pdxdoc` files from the docs subtree.
**New KINDs introduced.** None. `doc` operates entirely on existing filesystem primitives + the pipe primitive.
**paideia-as v0.33-crypto dependency.** None.
**Semantic-pipe schemas emitted.** `PdxDocEntry[]` — one per section of the current doc, so `doc <tool> | query "section-title ~= 'Examples'"` works. `PdxDocReference[]` — the cross-reference graph, so `pipeviz` (R59) can render doc-to-doc dependency diagrams.
**Cap requirements at invocation.** `Cap<KIND_USER>`, `Cap<KIND_TTY(write)>`, `Cap<KIND_PDXFS_FILE(read, /system/doc)>`.
**Undo/audit obligations.** Every doc-read journals a `DocReadRecord` per the D3 audit-first upgrade (this is a read operation that must still be audited so a supervisor can later reconstruct which docs the user consulted before taking a destructive action). No undo — `doc` is idempotent.

### 4.4 `ls` — list directory

**Repo:** `paideia-os/ls`
**Purpose.** Render directory contents as text and as typed schema records. Behaviour differs from POSIX `ls` in three ways: schema output is first-class, cap-annotations are visible (each entry's per-user cap tail is rendered in `--long`), and colorization comes from the file's declared MIME/schema, not from POSIX file-type bits.
**Existing kernel KINDs consumed.**
- `KIND_USER` — invoker identity.
- `KIND_PDXFS_FILE(read, <target>)` (R42) — the directory being listed; the tool's cap request narrows to exactly the argument path (never ambient-authority).
- `KIND_TTY(write)` — rendered text.
- `KIND_IPC_ENDPOINT` — schema pipe.
**New KINDs introduced.** None. `ls` is a pure consumer.
**paideia-as v0.33-crypto dependency.** None.
**Semantic-pipe schemas emitted.** `PdxFsDirEntry[]` — one record per file, fields `{name, kind (file|dir|symlink|special), size:u64, mtime:i128, owner:KIND_USER_ref, cap_tail_hash:[u8;32], schema_id: Option<u32>}`. The `owner` field is a *capability reference* (a `libpdx-cap` handle), not a uid integer — this is D2 literal at the schema level: the downstream `query` tool can filter by `owner == alice` without ever converting to a text name.
**Cap requirements at invocation.** `Cap<KIND_USER>`, `Cap<KIND_TTY(write)>`, `Cap<KIND_PDXFS_FILE(read, <arg-path>)>`. Missing the last one exits with code 4 (cap denied per I4).
**Undo/audit obligations.** Journals `DirListRecord` per read. No undo (read-only).

### 4.5 `cat` — concatenate and print files

**Repo:** `paideia-os/cat`
**Purpose.** Read one or more files and emit their contents to stdout, both as raw bytes (text layer) and — when the file declares a schema in its `.pdxfs` metadata — as typed records on the semantic-pipe layer.
**Existing kernel KINDs consumed.**
- `KIND_USER` — invoker.
- `KIND_PDXFS_FILE(read, <target>)` (R42) — the file(s) being read; one cap per argument.
- `KIND_TTY(write)` — rendered text.
- `KIND_IPC_ENDPOINT` — schema pipe.
**New KINDs introduced.** None.
**paideia-as v0.33-crypto dependency.** None.
**Semantic-pipe schemas emitted.** If the file declares a schema via its `.pdxfs` attribute, `cat` streams that schema's records directly. If the file has no declared schema, `cat` emits `RawByteChunk[]` (fields `{offset:u64, bytes:[u8]}`) so downstream tools can still window the stream by byte range without re-tokenizing. Shape dependency on `libpdx-semantic-pipe` §3.2 for the schema-hash prefix.
**Cap requirements at invocation.** `Cap<KIND_USER>`, `Cap<KIND_TTY(write)>`, one `Cap<KIND_PDXFS_FILE(read, <arg-path>)>` per argument.
**Undo/audit obligations.** Journals `FileReadRecord` per file. No undo.

### 4.6 `cp` — copy files and directories

**Repo:** `paideia-os/cp`
**Purpose.** Copy a file or directory from source to destination, preserving cap tails where the destination user is authorized to hold them, journaling an undo record if the copy overwrites an existing target.
**Existing kernel KINDs consumed.**
- `KIND_USER` — invoker; the copy asserts destination-user-write authority via a cap tail check.
- `KIND_PDXFS_FILE(read, <source>)`, `KIND_PDXFS_FILE(write, <dest-parent>)` (R42).
- `KIND_PDXFS_TXN` (R42) — one transaction opened over the whole `cp` invocation; a per-file failure rolls back every already-written destination file, so a partial-`cp` never leaves an incoherent tree.
- `KIND_IPC_ENDPOINT` — schema pipe (for `--verbose` progress records).
**New KINDs introduced.** None.
**paideia-as v0.33-crypto dependency.** None directly; if the source file's inode signature (PdxFS v1 signed-inode field per `design/user/model.md` §10.2) is present, `cp` calls `libpdx-cap` to re-sign the destination inode under the invoker's `user_sk` — which requires the passphrase to be currently unlocked, and gracefully degrades to unsigned copy with a `--verbose` diagnostic if not.
**Semantic-pipe schemas emitted.** `CopyProgressRecord[]` — one per file copied (or per N MiB block on large files), fields `{src_path, dst_path, bytes_copied, bytes_total, elapsed_ns}`.
**Cap requirements at invocation.** `Cap<KIND_USER>`, `Cap<KIND_PDXFS_FILE(read, <src>)>`, `Cap<KIND_PDXFS_FILE(write, <dst-parent>)>`, `Cap<KIND_PDXFS_TXN>`. If `dst-parent` is outside the invoker's user subtree, `cp` invokes `libpdx-elevate` to request a bounded `KIND_PDXFS_FILE(write, <dst-parent>)` from the destination-subtree's owner.
**Undo/audit obligations.** Every `cp` journals a `CopyRecord` to the audit journal. Every `cp` that overwrites an existing target journals an undo record on PdxFS v1 (I5): `undo cp <same-args>` restores the pre-copy destination file. Every `cp` opens exactly one `KIND_PDXFS_TXN`; commit or abort is atomic.

### 4.7 `mv` — move or rename files

**Repo:** `paideia-os/mv`
**Purpose.** Move a file or directory from source to destination, journaling an undo record for the reversal, transaction-atomic across the source-unlink and destination-link steps.
**Existing kernel KINDs consumed.**
- `KIND_USER` — invoker.
- `KIND_PDXFS_FILE(write, <source-parent>)`, `KIND_PDXFS_FILE(write, <dest-parent>)` (R42).
- `KIND_PDXFS_TXN` (R42) — one transaction over `mv`'s whole invocation; source-unlink + dest-link atomic.
- `KIND_IPC_ENDPOINT` — schema pipe (for `--verbose`).
**New KINDs introduced.** None.
**paideia-as v0.33-crypto dependency.** Same signed-inode consideration as `cp` §4.6 — if the source has a PdxFS v1 signature, `mv` preserves it (unchanged path from the invoker's key perspective, since `mv` is a rename in the invoker's own subtree; cross-subtree moves fall to the same re-sign or degrade-with-diagnostic path as `cp`).
**Semantic-pipe schemas emitted.** `MoveRecord[]` — one per file moved, fields `{src_path, dst_path, was_rename:bool, was_cross_device:bool}`. The `was_cross_device` distinction matters: cross-device `mv` degrades to `cp + rm` internally, still transactional but with a warning that the operation is not O(1).
**Cap requirements at invocation.** `Cap<KIND_USER>`, `Cap<KIND_PDXFS_FILE(write, <src-parent>)>`, `Cap<KIND_PDXFS_FILE(write, <dst-parent>)>`, `Cap<KIND_PDXFS_TXN>`. Cross-user-boundary moves invoke `libpdx-elevate` on the destination side, same shape as `cp` §4.6.
**Undo/audit obligations.** Every `mv` journals a `MoveRecord` to the audit journal. Every `mv` writes an undo record on PdxFS v1 whose replay is `mv <dst> <src>`. Every `mv` opens exactly one `KIND_PDXFS_TXN`.

### 4.8 `rm` — remove files and directories

**Repo:** `paideia-os/rm`
**Purpose.** Remove one or more files or directories, journaling every removal to PdxFS v1's trash subtree so `undo` can restore within the retention window (default 24 hours per I5).
**Existing kernel KINDs consumed.**
- `KIND_USER` — invoker.
- `KIND_PDXFS_FILE(write, <target-parent>)` (R42) — the parent directory being modified; note `rm` requires write on the parent, not on the target itself (POSIX-canonical, preserved).
- `KIND_PDXFS_TXN` (R42) — one transaction over the whole invocation; a partial-`rm` never leaves half-deleted state.
- `KIND_IPC_ENDPOINT` — schema pipe.
**New KINDs introduced.** None.
**paideia-as v0.33-crypto dependency.** None. The trash-subtree write does re-sign the trashed inode under the invoker's `user_sk` so the audit chain remains verifiable through `undo`; this uses whatever signing path the user has unlocked at session start.
**Semantic-pipe schemas emitted.** `RemoveRecord[]` — one per file removed, fields `{path, size:u64, was_dir:bool, trash_handle:[u8;32]}`. The `trash_handle` is the PdxFS v1 trash-subtree entry that `undo` reads to restore.
**Cap requirements at invocation.** `Cap<KIND_USER>`, `Cap<KIND_PDXFS_FILE(write, <target-parent>)>`, `Cap<KIND_PDXFS_TXN>`. `rm` under `/system/` invokes `libpdx-elevate` (as does `rm -rf` where any prefix crosses out of the invoker's subtree).
**Undo/audit obligations.** Every `rm` journals a `RemoveRecord` to the audit journal *and* writes an undo record on PdxFS v1 whose replay reconstructs the file from the trash subtree. The undo record has a retention deadline (24h default) after which the trash-subtree entry is garbage-collected and the undo becomes ENOENT-with-diagnostic. `rm --wipe` (per `design/user/model.md` §7.1 semantics) shreds the trash entry immediately, still journaled to audit but with an audit-record flag noting the shred so a later forensic reader knows the file was intentionally unrecoverable.

### 4.9 `mkdir` — create directories

**Repo:** `paideia-os/mkdir`
**Purpose.** Create one or more directories, with `-p` (create-parents), with the invoker's cap tail attached to each created directory. Simpler shape than the other coreutils because there is nothing to undo but a directory-remove.
**Existing kernel KINDs consumed.**
- `KIND_USER` — invoker; the created directory's cap tail records this user as owner.
- `KIND_PDXFS_FILE(write, <target-parent>)` (R42).
- `KIND_PDXFS_TXN` (R42) — one transaction; `-p` creating a multi-level path is atomic across all created levels.
- `KIND_IPC_ENDPOINT` — schema pipe (for `--verbose` and for the `CreatedDirRecord` emit).
**New KINDs introduced.** None.
**paideia-as v0.33-crypto dependency.** None.
**Semantic-pipe schemas emitted.** `CreatedDirRecord[]` — one per directory created, fields `{path, parent_txn_id, owner:KIND_USER_ref}`. Text layer per I4: `mkdir` still prints a diagnostic on stderr for `-v` mode, and on error always.
**Cap requirements at invocation.** `Cap<KIND_USER>`, `Cap<KIND_PDXFS_FILE(write, <target-parent>)>`, `Cap<KIND_PDXFS_TXN>`.
**Undo/audit obligations.** Journals a `CreateDirRecord` to the audit journal. The PdxFS v1 undo record is a `RemoveRecord` whose replay is `rmdir <path>` — the reversal is the primitive `mkdir` inverts. Since `mkdir` is idempotent under `-p`, `undo mkdir -p a/b/c` only removes the levels that this specific invocation created (the TXN log distinguishes pre-existing from newly-created).

---

## 5. (softarch Round 2)

*This section is a placeholder for softarch's Round 2 extension.* Round 2 responsibilities:

- **§5.1 through §5.9** — per-tool milestone breakdown: each tool gets ~3 milestones (typically M1 = repo scaffolding + `caps.decl` + basic invocation; M2 = happy-path implementation with audit + schema emission; M3 = error paths, elevate integration, retention window), and each milestone gets ~5 issue titles.
- **§5.10 through §5.14** — per-library milestone breakdown for the 5 §3 libraries; each gets ~2 milestones + ~5 issue titles.
- **§6** — KIND ordinal allocation for the new derived kinds proposed in §4 (`KIND_PACKAGE_MANIFEST`, `KIND_PACKAGE_REPO`, `KIND_SHELL_SESSION`, and optionally `KIND_ELEVATE_CHANNEL`); each allocation checks the free-ordinal space against `src/kernel/core/cap/` at HEAD and against every kind_*.pdx file's `pub let ... : u64 = 0x...` header.
- **§7** — internal module structure for each tool (which `.pdx` files, which `paideia-as` module boundaries).
- **§8** — risk register: known-unknowns per tool + per library, including the substrate-gap flag on `KIND_PDXFS_FILE`/`KIND_PDXFS_TXN` (§2.4 R42 landing not yet confirmed at HEAD).

---

*End of §1–§4. Ready for softarch Round 2.*
