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

## 5. Per-tool + per-library milestone breakdown (softarch Round 2)

Round 2 extends §1–§4 with: (a) a §5.0 substrate-prep gate that must land before any R49 tool starts; (b) §5.1–§5.9 per-tool M1–M5 milestone plans + ~15 issue titles per tool; (c) §5.10–§5.14 per-library M1–M5 milestone plans + ~10 issue titles per library; (d) a KIND ordinal allocation block distributed across the tool sections that need them, summarised in §5.15.

**Milestone rubric (identical across all 14 items).** M1 lands the repo scaffolding, `caps.decl`, and the paideia-as build harness; M2 lands the happy-path core; M3 lands the semantic-pipe schema + `libpdx-audit` integration + (where applicable) `libpdx-elevate` retry paths; M4 lands the tests, the smoke matrix, and the pre-release fuzzers; M5 lands the dual-signed `manifest.pdxsig`, the CHANGELOG-1.0 entry, and the mirror push to `pkgs.paideia-os`. A tool is *runnable* at end of M2, *audit-conformant* at end of M3, *ship-testable* at end of M4, and *released* at end of M5. The five milestones map 1:1 to five GitHub milestones per repo — no tool may cross a milestone boundary before its predecessor closes.

**Issue-title conventions.** Titles follow the `<Tool>.M<N>-<NNN>` pattern (e.g. `pkg.M1-001`). NNN restarts at 001 per milestone. Titles are one line, imperative mood, and reference the specific `.pdx` file, `caps.decl` clause, or design-doc section they land against — the same shape as this repo's own `R48.M7-001 …` titles at commits `92ee50c` and `251cd7c`. Round 2 authors these titles; main files them at repo-creation time.

**KIND ordinal reservations (summary; details inline).** The following derived-kind ordinals are reserved out of the post-R48 free space (R48.M1 took 0x190 for `KIND_USER`; G6 closed at 0x18F). Four new derived kinds land across R49; ordinals 0x195–0x19F stay unallocated for R50-and-beyond tools that emerge from Round-2 refinements:

| Ordinal | KIND | Derived over | Introduced by | Wave |
|---------|------|--------------|---------------|------|
| 0x191 | `KIND_ELEVATE_CHANNEL` | `KIND_IPC_ENDPOINT` (base 5) | `libpdx-elevate` §5.14 | R49 |
| 0x192 | `KIND_PACKAGE_REPO` | `KIND_NETWORK` (existing) | `pkg` §5.1 | R49 |
| 0x193 | `KIND_PACKAGE_MANIFEST` | `KIND_PDXFS_FILE` (R42) | `pkg` §5.1 | R49 |
| 0x194 | `KIND_SHELL_SESSION` | `KIND_USER` (0x190) | `shell` §5.2 | R49 |

Ordinal allocation is contiguous from 0x191 to keep the derived-kind block dense (matches R48.M1 which took the first slot after G6). No R50 tool introduces a new KIND at its v1.0 — the coreutils are strict consumers of R42 PdxFS kinds + `KIND_USER` + `KIND_IPC_ENDPOINT`. If Round-2 refinements uncover a coreutil KIND need, its ordinal comes from 0x195–0x19F.

---

### §5.0 Substrate prep required before R49 wave starts

Round 1 §2.4 flagged two substrate gaps in the current kernel at HEAD (2026-08-21) that block the entire R49 wave. Softarch confirms: `ls src/kernel/core/cap/kind_*.pdx | grep -E 'pdxfs|elevate'` returns nothing — neither `KIND_PDXFS_FILE` nor `KIND_PDXFS_TXN` exists, and there is no explicit `KIND_ELEVATE_CHANNEL` derived kind over the R48.M7 IPC codec. These must be filed against `paideia-os` (this repo) as blockers on R49, not as work inside any tool repo.

**Substrate gate — must close before pkg.M1 opens.**

Issues (filed against `paideia-os` main repo):

```
paideia-os.R42-PREP-001 KIND_PDXFS_FILE — derived-kind + witness (`src/kernel/core/cap/kind_pdxfs_file.pdx`, ordinal reserved from R42 block)
paideia-os.R42-PREP-002 KIND_PDXFS_TXN  — derived-kind + witness (`src/kernel/core/cap/kind_pdxfs_txn.pdx`, ordinal reserved from R42 block)
paideia-os.R42-PREP-003 KIND_PDXFS_FILE + KIND_PDXFS_TXN — schema headers + Cap<> narrowing tests
paideia-os.R48-PREP-004 KIND_ELEVATE_CHANNEL = 0x191 — derived-kind over KIND_IPC_ENDPOINT (`src/kernel/core/cap/kind_elevate_channel.pdx`); rebind existing R48.M7 codec to mint through the new kind
paideia-os.R48-PREP-005 elevate broker registration under svc.elevate-broker + auto-approve policy table wiring for KIND_ELEVATE_CHANNEL
paideia-os.R49-PREP-006 svc.audit-journal broker registration + UEJ_KIND_TOOL_INVOKE / UEJ_KIND_TOOL_OUTPUT / UEJ_KIND_TOOL_EXIT constants in user_events_journal.pdx
```

**Ordering.** R42-PREP-001 through -003 must land before pkg.M1-001 opens; R48-PREP-004 through -005 must land before libpdx-elevate.M2-001 opens; R49-PREP-006 must land before libpdx-audit.M2-001 opens. Main tracks these six as a "R49-substrate" GitHub milestone on the paideia-os repo, and the R49 tooling wave is gated on that milestone reaching 100%.

---

### §5.1 `pkg` (repo `paideia-os/pkg`)

**Milestones.**
- **M1 — Design + skeleton.** Scaffold the repo (paideia-as manifest, `caps.decl` with `KIND_USER` + `KIND_IPC_ENDPOINT` + placeholder for elevate-broker binding), draft the on-disk package manifest format (extends `design/tooling/plan.md` §6.3 with the dual-signature block), and land the argv surface (`install`, `remove`, `list`, `verify`, `keys`) parsed through `libpdx-argv`. First runnable shape: `pkg list` reads `/system/packages/` and prints installed names.
- **M2 — Core implementation.** Real `pkg_install` body: fetch → sig-verify (both ML-DSA-65 signatures via paideia-as v0.33 intrinsic) → unpack into `KIND_PDXFS_TXN` scope → journal-fence → atomic rename into `/pkgs/<name>-<version>/`. `pkg remove` writes the reverse-symlink undo record. Bootstrapped self-install path: `pkg install pkg` runs against a from-source build.
- **M3 — Semantic-pipe / audit integration.** `PackageManifest[]`, `InstallProgressRecord[]`, and `KeyFingerprintRecord[]` schemas bound via `libpdx-semantic-pipe`. Every subcommand journals through `libpdx-audit` before any output. `libpdx-elevate` integration: `pkg install` requests `KIND_PDXFS_FILE(write, /pkgs)` + `KIND_NETWORK(fetch, pkgs.paideia-os)` + `KIND_SIGNATURE(verify, paideia_root_pk)` for a 60s window (matches `design/user/model.md` §5.1 example).
- **M4 — Tests + smoke.** Bootstrap test (install pkg via pkg from a from-source build), sig-mismatch rejection tests (author sig bad, root sig bad, both bad), quota-exceeded refusal, elevate-timeout retry, partial-install rollback via TXN abort. QEMU smoke matrix: install → list → verify → remove → verify absent.
- **M5 — 1.0 signed release.** Dual-signed `manifest.pdxsig` for pkg v1.0, CHANGELOG-1.0 entry, `pkgs.paideia-os` mirror push, `pkg keys` documentation of the paideia_root_pk fingerprint, `.pdxdoc` file for `doc pkg`.

**New KINDs allocated.** `KIND_PACKAGE_MANIFEST = 0x193` (derived over `KIND_PDXFS_FILE`); `KIND_PACKAGE_REPO = 0x192` (derived over `KIND_NETWORK`). Both minted by `pkg` internally; downstream consumers hold sub-caps. Ordinal definitions land in `paideia-os/pkg/src/kind_package_manifest.pdx` and `paideia-os/pkg/src/kind_package_repo.pdx` and are cross-referenced from the kernel's kind registry via the R20b InitCap sidecar (no kernel-side .pdx files needed; the kinds are userspace-defined derived kinds).

**Cross-repo dependencies.** pkg.M1 depends on §5.0 substrate (R42-PREP-001..003) closed; pkg.M2 depends on libpdx-cap.M2, libpdx-semantic-pipe.M1, libpdx-argv.M2; pkg.M3 depends on libpdx-elevate.M3 (elevate-broker path), libpdx-audit.M2, and paideia-as v0.33-crypto tag reachable via the toolchain; pkg.M5 depends on doc.M2 (needs `doc pkg` reachable before release).

**Issues (~15):**

```
pkg.M1-001 scaffold paideia-as manifest + caps.decl (KIND_USER + KIND_IPC_ENDPOINT baseline)
pkg.M1-002 argv surface: install, remove, list, verify, keys — parse via libpdx-argv
pkg.M1-003 draft package manifest format (extends design/tooling/plan.md §6.3, dual-sig block)
pkg.M2-001 KIND_PACKAGE_MANIFEST = 0x193 — derived-kind alloc + mint helper
pkg.M2-002 KIND_PACKAGE_REPO = 0x192 — derived-kind alloc + fetch-rights narrowing
pkg.M2-003 pkg_install body: fetch → ml_dsa_65_verify ×2 → KIND_PDXFS_TXN unpack → rename
pkg.M2-004 pkg_remove body: reverse-symlink undo record + PdxFS trash-subtree entry
pkg.M2-005 self-install bootstrap: pkg install pkg against from-source build
pkg.M3-001 semantic-pipe: PackageManifest[] schema bind + emit on pkg list
pkg.M3-002 semantic-pipe: InstallProgressRecord[] per install stage
pkg.M3-003 libpdx-audit: pre-output journal on every subcommand
pkg.M3-004 libpdx-elevate: KIND_PDXFS_FILE(write,/pkgs) request with 60s window
pkg.M4-001 sig-mismatch matrix (author bad, root bad, both bad — all refuse)
pkg.M4-002 partial-install rollback via KIND_PDXFS_TXN abort
pkg.M4-003 QEMU smoke: install → list → verify → remove → verify absent
pkg.M5-001 dual-signed manifest.pdxsig for pkg v1.0 + CHANGELOG entry
pkg.M5-002 pkgs.paideia-os mirror push + .pdxdoc for doc pkg
```

---

### §5.2 `shell` (repo `paideia-os/shell`)

**Milestones.**
- **M1 — Design + skeleton.** Scaffold repo + `caps.decl` (KIND_USER, KIND_IPC_ENDPOINT, KIND_TTY, InitCap sidecar). Land the line reader (interactive prompt reads a line, echoes to KIND_TTY) and the smallest exec path (`sh -c '/bin/echo hi'` finds `/bin/echo` in the InitCap-seeded path, calls `sys_execve`, waits, prints exit code). No pipeline support yet.
- **M2 — Core implementation.** Full pipeline (`a | b | c`) minting one `KIND_IPC_ENDPOINT` per `|`; caps environment propagation using `libpdx-cap` to narrow per-child rights per each callee's `caps.decl`; `.pds` script execution (per `design/terminal/pds-format.md`); history file at `~/.history/` written via `KIND_PDXFS_FILE(write)`. `KIND_SHELL_SESSION = 0x194` minted at session start.
- **M3 — Semantic-pipe / audit integration.** Passthrough behaviour: each child's schema pipe is forwarded unchanged to the pipeline consumer (D2 literal). Tab-completion schema (`CommandCompletion[]`) via `libpdx-semantic-pipe`. Every command journals `ShellCommandRecord` via `libpdx-audit` before `sys_execve`; exit-code closes the record after `wait`. Interactive prompt schema (`ShellPromptRecord`).
- **M4 — Tests + smoke.** Pipeline correctness matrix (2-stage, 3-stage, cross-schema, schema-mismatch drop-through), caps-narrowing test (child receives no cap not declared in its caps.decl), audit-first invariant (child cannot emit before audit record is durable), `.pds` script test suite. QEMU smoke: interactive login → prompt → `ls | cat` → history-persist.
- **M5 — 1.0 signed release.** Dual-signed release, CHANGELOG, `.pdxdoc` for `doc shell`, mirror push. Shell binds itself to `svc.login-shell` broker name for the login path to find it.

**New KINDs allocated.** `KIND_SHELL_SESSION = 0x194` (derived over `KIND_USER`). Minted by `shell` at session start; sub-caps handed to `mux` splits and nested `remote`-shell processes at R56+.

**Cross-repo dependencies.** shell.M1 depends on §5.0 substrate; shell.M2 depends on libpdx-cap.M2 (cap narrowing at exec) and libpdx-argv.M2 (children's argv); shell.M3 depends on libpdx-semantic-pipe.M2 (passthrough shape) and libpdx-audit.M2; shell.M5 depends on doc.M2. `doc` in turn depends on shell.M4 for its runtime — this is the one direct cycle in the R49 DAG, broken by shell.M4 (test-complete but pre-release) unblocking doc.M1.

**Issues (~15):**

```
shell.M1-001 scaffold + caps.decl (KIND_USER + KIND_TTY + KIND_IPC_ENDPOINT + InitCap seed)
shell.M1-002 line reader against KIND_TTY (read line, echo, edit keys via R41 semterm engine)
shell.M1-003 minimal exec: sys_execve + wait + exit-code print
shell.M2-001 KIND_SHELL_SESSION = 0x194 — mint at session start, derive sub-caps for children
shell.M2-002 pipeline: mint KIND_IPC_ENDPOINT per `|`, splice into child stdin/stdout
shell.M2-003 caps environment propagation via libpdx-cap (narrow per callee caps.decl)
shell.M2-004 .pds script executor per design/terminal/pds-format.md
shell.M2-005 ~/.history/ persistence via KIND_PDXFS_FILE(write) CoW journal
shell.M3-001 semantic-pipe passthrough: child schema forwarded unchanged (D2 literal)
shell.M3-002 CommandCompletion[] schema for tab-completion (SH-D7)
shell.M3-003 ShellCommandRecord via libpdx-audit before sys_execve; close on wait
shell.M4-001 caps-narrowing violation matrix (child receives cap not in its caps.decl → reject)
shell.M4-002 audit-first invariant test (child cannot emit before audit is durable)
shell.M4-003 QEMU smoke: login → prompt → ls | cat → history persists across reboot
shell.M5-001 dual-signed release + svc.login-shell broker registration
shell.M5-002 .pdxdoc for doc shell + mirror push
```

---

### §5.3 `doc` (repo `paideia-os/doc`)

**Milestones.**
- **M1 — Design + skeleton.** Scaffold + `caps.decl` (KIND_USER, KIND_TTY, KIND_PDXFS_FILE(read, /system/doc), KIND_IPC_ENDPOINT). Parse `.pdxdoc` file format (per `design/tooling/plan.md` I7); render a single doc's plain text to KIND_TTY. No cross-references, no pagination, no schema output — just text.
- **M2 — Core implementation.** Pagination by terminal height (queries KIND_TTY for rows). Cross-reference navigation (in-doc links, followed by hotkey). ANSI SGR highlight for section headers, code blocks, cross-refs. POSIX-difference annotations rendered inline where the `.pdxdoc` declares them.
- **M3 — Semantic-pipe / audit integration.** `PdxDocEntry[]` schema per doc section; `PdxDocReference[]` for the cross-reference graph. `doc pkg | query "section-title ~= 'Examples'"` returns just the examples section. `DocReadRecord` journaled via `libpdx-audit` on every read (audit-first upgrade of I5 — reads are journaled too).
- **M4 — Tests + smoke.** Rendering test suite (well-formed `.pdxdoc` inputs), malformed-doc rejection, missing-file diagnostic (exit 4 per I4 — cap denied is distinct from not-found), pagination correctness at multiple terminal heights. QEMU smoke: `doc ls` renders; `doc missing` returns clean not-found.
- **M5 — 1.0 signed release.** Dual-signed release, `.pdxdoc` for `doc doc` (self-referential), mirror push.

**New KINDs allocated.** None. `doc` is a pure consumer of R42 filesystem kinds and R20b IPC kinds.

**Cross-repo dependencies.** doc.M1 depends on shell.M4 (needs a runnable shell as its invocation host); doc.M2 depends on libpdx-argv.M2; doc.M3 depends on libpdx-semantic-pipe.M2 + libpdx-audit.M2; doc.M5 depends on `.pdxdoc` files existing in `/system/doc/` for at least pkg, shell, and doc itself (all three shipping their .pdxdoc in their own M5).

**Issues (~15):**

```
doc.M1-001 scaffold + caps.decl (KIND_USER + KIND_TTY + KIND_PDXFS_FILE(read,/system/doc))
doc.M1-002 .pdxdoc file-format parser per design/tooling/plan.md I7
doc.M1-003 plain-text render of a single doc section to KIND_TTY (no pagination yet)
doc.M2-001 pagination by KIND_TTY-reported terminal height
doc.M2-002 cross-reference navigation (in-doc links + hotkey follow)
doc.M2-003 ANSI SGR highlight (headers, code blocks, cross-refs)
doc.M2-004 POSIX-difference annotation inline rendering
doc.M3-001 PdxDocEntry[] schema per section — libpdx-semantic-pipe bind
doc.M3-002 PdxDocReference[] schema for cross-ref graph
doc.M3-003 DocReadRecord via libpdx-audit before render (audit-first for reads)
doc.M4-001 rendering test suite against well-formed .pdxdoc corpus
doc.M4-002 malformed-doc rejection matrix
doc.M4-003 missing-file diagnostic returns exit 4 (cap denied ≠ not found)
doc.M4-004 QEMU smoke: doc ls renders; doc missing returns clean not-found
doc.M5-001 dual-signed release + .pdxdoc for doc doc (self-referential)
doc.M5-002 mirror push + integration with `<tool> --help` back-end wiring
```

---

### §5.4 `ls` (repo `paideia-os/ls`)

**Milestones.**
- **M1 — Design + skeleton.** Scaffold + `caps.decl` (KIND_USER, KIND_TTY, KIND_PDXFS_FILE(read,<arg>), KIND_IPC_ENDPOINT). Argv surface (`ls [-l|-a|-h|--json|--schema|--color=…] <path>...`) via libpdx-argv. First runnable: `ls .` prints entry names to KIND_TTY, one per line.
- **M2 — Core implementation.** `-l` long-format rendering (kind, size, mtime, owner via `KIND_USER_ref` decoded through libpdx-cap); `-a` (hidden files); `-h` (human-readable size); coloring driven by declared schema/MIME, not POSIX file-type bits (per Round-1 §4.4).
- **M3 — Semantic-pipe / audit integration.** `PdxFsDirEntry[]` emission on stdout (schema-bound before first byte); owner field carries a cap reference, not a text uid. `DirListRecord` via libpdx-audit.
- **M4 — Tests + smoke.** Coloring correctness against known-schema fixtures; owner-render correctness for multi-user quota-share subtrees; empty-dir + missing-dir + cap-denied exit-code matrix; `ls --schema` output validates against libpdx-semantic-pipe golden.
- **M5 — 1.0 signed release.** Dual-signed release, `.pdxdoc` for `doc ls`, mirror push.

**New KINDs allocated.** None.

**Cross-repo dependencies.** ls.M1 depends on §5.0 substrate + shell.M4; ls.M2 depends on libpdx-cap.M3 (KIND_USER_ref decode); ls.M3 depends on libpdx-semantic-pipe.M2 + libpdx-audit.M2; ls.M5 depends on pkg.M4 (packages install path so `pkg install ls` works).

**Issues (~15):**

```
ls.M1-001 scaffold + caps.decl
ls.M1-002 argv surface via libpdx-argv (ls [-l|-a|-h|--json|--schema] <path>...)
ls.M1-003 first runnable: entry-name print to KIND_TTY
ls.M2-001 -l long-format layout (kind, size, mtime, owner)
ls.M2-002 owner-column via KIND_USER_ref decode through libpdx-cap
ls.M2-003 -a hidden-files toggle + -h human-readable size
ls.M2-004 coloring driven by declared schema/MIME (not POSIX file-type bits)
ls.M3-001 PdxFsDirEntry[] schema bind + emit on stdout
ls.M3-002 owner field emits as cap ref, not text uid (D2 literal)
ls.M3-003 DirListRecord via libpdx-audit before first byte
ls.M4-001 coloring test against known-schema fixture corpus
ls.M4-002 owner-render correctness for multi-user quota subtree
ls.M4-003 exit-code matrix (empty=0, missing=2, cap-denied=4)
ls.M4-004 --schema output validates against libpdx-semantic-pipe golden
ls.M5-001 dual-signed release + .pdxdoc
ls.M5-002 mirror push + verify `pkg install ls` works end-to-end
```

---

### §5.5 `cat` (repo `paideia-os/cat`)

**Milestones.**
- **M1 — Design + skeleton.** Scaffold + `caps.decl` (KIND_USER, KIND_TTY, KIND_PDXFS_FILE(read,<arg>) per argument, KIND_IPC_ENDPOINT). Argv surface (`cat [-n|-A|--schema] <file>...`) via libpdx-argv. First runnable: `cat <file>` reads and writes to KIND_TTY.
- **M2 — Core implementation.** Multi-file concatenation, `-n` line numbering, `-A` non-printable-visible rendering, streaming read (never buffers full file in memory), stdin passthrough (`cat` with no args, reading from KIND_IPC_ENDPOINT stdin).
- **M3 — Semantic-pipe / audit integration.** If the input file's `.pdxfs` metadata declares a schema, `cat` streams that schema's records directly on stdout (schema-typed passthrough). If no schema, emits `RawByteChunk[]` (offset + bytes). `FileReadRecord` via libpdx-audit per file.
- **M4 — Tests + smoke.** Multi-file order-preservation; schema-typed passthrough against known-schema input; RawByteChunk chunking at 64KiB boundaries; large-file streaming test (no OOM on files > RAM); stdin-piping test through shell.
- **M5 — 1.0 signed release.** Dual-signed release, `.pdxdoc`, mirror push.

**New KINDs allocated.** None.

**Cross-repo dependencies.** cat.M1 depends on §5.0 substrate + shell.M4; cat.M3 depends on libpdx-semantic-pipe.M2 (schema-typed passthrough is a passthrough case, symmetric with shell's) + libpdx-audit.M2; cat.M5 depends on pkg.M4.

**Issues (~15):**

```
cat.M1-001 scaffold + caps.decl (one KIND_PDXFS_FILE cap per file arg)
cat.M1-002 argv surface via libpdx-argv (cat [-n|-A|--schema] <file>...)
cat.M1-003 first runnable: single-file KIND_TTY output
cat.M2-001 multi-file concatenation (arg-order preserved)
cat.M2-002 -n line-numbering + -A non-printable rendering
cat.M2-003 streaming read (never buffer full file; 64KiB chunk)
cat.M2-004 stdin passthrough when argv empty (read from KIND_IPC_ENDPOINT)
cat.M3-001 schema-typed passthrough: if file declares schema, forward records
cat.M3-002 RawByteChunk[] emission for schemaless files
cat.M3-003 FileReadRecord via libpdx-audit per file, before first byte
cat.M4-001 multi-file order-preservation test
cat.M4-002 schema-typed passthrough against known-schema fixture
cat.M4-003 large-file streaming test (>RAM, no OOM)
cat.M4-004 stdin-piping test (a | cat | b through shell pipeline)
cat.M5-001 dual-signed release + .pdxdoc
cat.M5-002 mirror push
```

---

### §5.6 `cp` (repo `paideia-os/cp`)

**Milestones.**
- **M1 — Design + skeleton.** Scaffold + `caps.decl` (KIND_USER, KIND_PDXFS_FILE(read,<src>), KIND_PDXFS_FILE(write,<dst-parent>), KIND_PDXFS_TXN, KIND_IPC_ENDPOINT). Argv surface (`cp [-r|-v|--dry-run|--over-existing] <src>... <dst>`) via libpdx-argv. First runnable: single-file `cp a b` opens both caps, opens a TXN, copies bytes, commits.
- **M2 — Core implementation.** Recursive `-r`, cap-tail preservation (per `design/user/model.md` §10.2 signed-inode field — re-sign at destination under invoker's user_sk if unlocked, else graceful degrade with `--verbose` diagnostic), single-TXN atomicity across the whole invocation (partial-cp rollback), `--over-existing` undo record on PdxFS v1.
- **M3 — Semantic-pipe / audit integration.** `CopyProgressRecord[]` per file (or per N MiB block on large files). `CopyRecord` via libpdx-audit. `libpdx-elevate` retry when `dst-parent` crosses a per-user-subtree boundary that exceeds the invoker's scope.
- **M4 — Tests + smoke.** Single-file, multi-file, recursive, over-existing (undo replayed), TXN-abort mid-copy (all destination bytes unwound), cross-subtree elevate flow (auto-approve + human-approve paths), signed-inode preservation across same-user copy, signed-inode degrade across cross-user copy.
- **M5 — 1.0 signed release.** Dual-signed release, `.pdxdoc`, mirror push.

**New KINDs allocated.** None.

**Cross-repo dependencies.** cp.M1 depends on §5.0 substrate + shell.M4; cp.M2 depends on libpdx-cap.M3 (signed-inode helpers); cp.M3 depends on libpdx-semantic-pipe.M2, libpdx-audit.M2, and libpdx-elevate.M3 (elevate retry); cp.M5 depends on pkg.M4.

**Issues (~15):**

```
cp.M1-001 scaffold + caps.decl (src read cap + dst-parent write cap + TXN cap)
cp.M1-002 argv surface via libpdx-argv (cp [-r|-v|--dry-run|--over-existing])
cp.M1-003 first runnable: single-file cp a b in single TXN
cp.M2-001 recursive -r walk with per-file cap request
cp.M2-002 cap-tail preservation: re-sign at destination under invoker user_sk if unlocked
cp.M2-003 graceful signed-inode degrade with --verbose diagnostic when key locked
cp.M2-004 single-TXN atomicity across whole invocation (partial rollback)
cp.M2-005 --over-existing PdxFS v1 undo record
cp.M3-001 CopyProgressRecord[] schema bind + per-file emit
cp.M3-002 CopyRecord via libpdx-audit
cp.M3-003 libpdx-elevate retry on cross-subtree dst-parent
cp.M4-001 TXN-abort mid-copy: verify all destination bytes unwound
cp.M4-002 cross-subtree elevate flow (auto-approve + human paths)
cp.M4-003 signed-inode preservation (same-user) + degrade (cross-user)
cp.M5-001 dual-signed release + .pdxdoc
cp.M5-002 mirror push
```

---

### §5.7 `mv` (repo `paideia-os/mv`)

**Milestones.**
- **M1 — Design + skeleton.** Scaffold + `caps.decl` (KIND_USER, KIND_PDXFS_FILE(write,<src-parent>), KIND_PDXFS_FILE(write,<dst-parent>), KIND_PDXFS_TXN, KIND_IPC_ENDPOINT). Argv surface (`mv [-v|-i|--dry-run] <src>... <dst>`) via libpdx-argv. First runnable: same-directory rename `mv a b` opens TXN, unlinks source, links dest, commits.
- **M2 — Core implementation.** Cross-directory move (same device — single TXN), cross-device move (degrades to cp+rm internally, still single TXN with a diagnostic that operation is not O(1)), signed-inode preservation (same as cp §5.6 — same-user preserves, cross-user degrades gracefully).
- **M3 — Semantic-pipe / audit integration.** `MoveRecord[]` per file with `was_rename` and `was_cross_device` flags. `MoveRecord` via libpdx-audit. Every `mv` writes a PdxFS v1 undo record whose replay is `mv <dst> <src>`. `libpdx-elevate` for cross-user boundary moves on the destination side.
- **M4 — Tests + smoke.** Same-dir rename (O(1) path); cross-dir same-device move (link-unlink atomicity); cross-device degrade path; TXN-abort mid-move (source restored, no dest); undo replay correctness; cross-user elevate flow.
- **M5 — 1.0 signed release.** Dual-signed release, `.pdxdoc`, mirror push.

**New KINDs allocated.** None.

**Cross-repo dependencies.** mv.M1 depends on §5.0 substrate + shell.M4; mv.M2 depends on cp.M2 (shared cross-device fallback logic — factored into libpdx-cap or a shared file-move helper module during Round-2 refinement); mv.M3 depends on libpdx-semantic-pipe.M2, libpdx-audit.M2, libpdx-elevate.M3; mv.M5 depends on pkg.M4.

**Issues (~15):**

```
mv.M1-001 scaffold + caps.decl (src-parent + dst-parent write caps + TXN cap)
mv.M1-002 argv surface via libpdx-argv (mv [-v|-i|--dry-run])
mv.M1-003 first runnable: same-dir rename in single TXN
mv.M2-001 cross-directory same-device move (link-unlink atomic in TXN)
mv.M2-002 cross-device move via cp+rm internal fallback (still single TXN)
mv.M2-003 was_cross_device diagnostic on --verbose
mv.M2-004 signed-inode preservation (same-user rename) + graceful degrade (cross-user)
mv.M3-001 MoveRecord[] schema bind (was_rename, was_cross_device flags)
mv.M3-002 MoveRecord via libpdx-audit before commit
mv.M3-003 PdxFS v1 undo record (replay is mv <dst> <src>)
mv.M3-004 libpdx-elevate for cross-user-boundary dst
mv.M4-001 TXN-abort mid-move: source restored, no dest artifact
mv.M4-002 undo replay correctness across all four cases (same-dir, cross-dir, cross-dev, cross-user)
mv.M4-003 QEMU smoke: mv a b; undo mv a b; ls verifies
mv.M5-001 dual-signed release + .pdxdoc
mv.M5-002 mirror push
```

---

### §5.8 `rm` (repo `paideia-os/rm`)

**Milestones.**
- **M1 — Design + skeleton.** Scaffold + `caps.decl` (KIND_USER, KIND_PDXFS_FILE(write,<target-parent>), KIND_PDXFS_TXN, KIND_IPC_ENDPOINT). Argv surface (`rm [-r|-f|-v|--wipe|--dry-run] <path>...`) via libpdx-argv. First runnable: single-file remove opens TXN, moves file to trash subtree, commits.
- **M2 — Core implementation.** Recursive `-r` walk (leaf-first order in TXN), `-f` force (no per-file confirmation), 24-hour default retention deadline metadata on trash-subtree entry, `--wipe` shred (immediate trash-entry unlink + best-effort byte-overwrite where the underlying device supports it).
- **M3 — Semantic-pipe / audit integration.** `RemoveRecord[]` with `path`, `size`, `was_dir`, `trash_handle` fields. `RemoveRecord` via libpdx-audit. PdxFS v1 undo record with replay reconstructing from trash subtree. `libpdx-elevate` for targets under `/system/` or crossing invoker's subtree.
- **M4 — Tests + smoke.** Single-file, recursive, force, wipe (verify trash-entry unlinked + audit flag set), TXN-abort mid-remove (no files removed), undo within retention window succeeds, undo after retention window returns clean ENOENT-with-diagnostic, `/system/` elevate flow.
- **M5 — 1.0 signed release.** Dual-signed release, `.pdxdoc`, mirror push.

**New KINDs allocated.** None.

**Cross-repo dependencies.** rm.M1 depends on §5.0 substrate + shell.M4; rm.M2 depends on the PdxFS v1 trash-subtree substrate (part of R42-PREP-003); rm.M3 depends on libpdx-semantic-pipe.M2, libpdx-audit.M2, libpdx-elevate.M3; rm.M5 depends on pkg.M4.

**Issues (~15):**

```
rm.M1-001 scaffold + caps.decl (target-parent write cap + TXN cap)
rm.M1-002 argv surface via libpdx-argv (rm [-r|-f|-v|--wipe|--dry-run])
rm.M1-003 first runnable: single-file remove via trash-subtree move in TXN
rm.M2-001 recursive -r leaf-first walk under single TXN
rm.M2-002 -f force flag (skip per-file confirmation)
rm.M2-003 24h retention deadline metadata on trash-subtree entry
rm.M2-004 --wipe: immediate trash-entry unlink + best-effort byte overwrite
rm.M3-001 RemoveRecord[] schema bind (path, size, was_dir, trash_handle)
rm.M3-002 RemoveRecord via libpdx-audit before trash-move
rm.M3-003 PdxFS v1 undo record (replay reconstructs from trash)
rm.M3-004 libpdx-elevate for /system/ + cross-subtree targets
rm.M4-001 TXN-abort mid-remove: no files removed
rm.M4-002 undo within retention window succeeds
rm.M4-003 undo after retention window returns ENOENT-with-diagnostic (not silent)
rm.M4-004 --wipe audit flag correctness (forensic reader can detect intentional shred)
rm.M5-001 dual-signed release + .pdxdoc
rm.M5-002 mirror push
```

---

### §5.9 `mkdir` (repo `paideia-os/mkdir`)

**Milestones.**
- **M1 — Design + skeleton.** Scaffold + `caps.decl` (KIND_USER, KIND_PDXFS_FILE(write,<target-parent>), KIND_PDXFS_TXN, KIND_IPC_ENDPOINT). Argv surface (`mkdir [-p|-v|--dry-run] <path>...`) via libpdx-argv. First runnable: single-level `mkdir a` opens TXN, creates directory with invoker's cap-tail as owner, commits.
- **M2 — Core implementation.** `-p` create-parents (multi-level path atomic within single TXN — either all levels created or none); pre-existing-dir handling under `-p` (no-op, not error); cap-tail write on every created directory (KIND_USER_ref of invoker embedded in inode).
- **M3 — Semantic-pipe / audit integration.** `CreatedDirRecord[]` per created directory (path, parent_txn_id, owner). `CreateDirRecord` via libpdx-audit. PdxFS v1 undo record whose replay is `rmdir <path>` — under `-p`, only the levels this invocation actually created are unwound (TXN log distinguishes newly-created from pre-existing).
- **M4 — Tests + smoke.** Single-level, multi-level `-p`, mixed pre-existing + new levels under `-p` (only new levels undone), TXN-abort mid-create (no dirs left), cap-tail correctness (owner matches invoker in every created inode).
- **M5 — 1.0 signed release.** Dual-signed release, `.pdxdoc`, mirror push.

**New KINDs allocated.** None.

**Cross-repo dependencies.** mkdir.M1 depends on §5.0 substrate + shell.M4; mkdir.M3 depends on libpdx-semantic-pipe.M2 + libpdx-audit.M2; mkdir.M5 depends on pkg.M4. mkdir has no elevate dependency — directories only created in the invoker's own subtree at v1.0.

**Issues (~15):**

```
mkdir.M1-001 scaffold + caps.decl (target-parent write cap + TXN cap)
mkdir.M1-002 argv surface via libpdx-argv (mkdir [-p|-v|--dry-run])
mkdir.M1-003 first runnable: single-level mkdir a in TXN with cap-tail as owner
mkdir.M2-001 -p create-parents: multi-level path atomic in single TXN
mkdir.M2-002 -p pre-existing dir handling (no-op, not error)
mkdir.M2-003 cap-tail write on every created directory (KIND_USER_ref in inode)
mkdir.M3-001 CreatedDirRecord[] schema bind (path, parent_txn_id, owner)
mkdir.M3-002 CreateDirRecord via libpdx-audit
mkdir.M3-003 PdxFS v1 undo record: replay is rmdir; -p unwinds only newly-created levels
mkdir.M4-001 single + multi-level test
mkdir.M4-002 mixed pre-existing + new under -p: undo removes only new levels
mkdir.M4-003 TXN-abort mid-create: no dirs left
mkdir.M4-004 cap-tail correctness (owner matches invoker in every created inode)
mkdir.M5-001 dual-signed release + .pdxdoc
mkdir.M5-002 mirror push
```

---

### §5.10 `libpdx-cap` (repo `paideia-os/libpdx-cap`)

**Milestones.**
- **M1 — Design + skeleton.** Scaffold + module boundary (`cap_pack`, `cap_unpack`, `cap_manifest_verify`, `caps.decl` parser). Wire format matches InitCap sidecar record shape (16 bytes, 8-byte aligned per R20b.M4). Baseline: pack + unpack round-trip preserves rights + kind + target_ptr.
- **M2 — Core implementation.** Full `cap_manifest_verify` (OK | MISSING | EXTRA against a callee's caps.decl); rights-narrowing at send site (caller cannot widen); rights-check at receive site (callee refuses cap outside its caps.decl).
- **M3 — Semantic-pipe / audit integration.** KIND_USER_ref decode helpers for `ls --long` and coreutils owner rendering. Signed-inode helpers used by cp/mv/rm (re-sign under invoker user_sk if unlocked).
- **M4 — Tests + smoke.** Round-trip fuzz (10^6 random cap shapes preserved), caps.decl parse-error corpus, rights-narrowing invariant (widening always rejected), receive-side extra-cap rejection, signed-inode re-sign correctness.
- **M5 — 1.0 signed release.** Dual-signed release, `.pdxdoc` for `doc libpdx-cap`, mirror push.

**Cross-repo dependencies.** libpdx-cap.M1 depends on the paideia-os kernel's KIND_USER (already at HEAD) and InitCap sidecar (already at HEAD). No R42 substrate dependency — libpdx-cap is the earliest library, it can start on day 1 of R49.

**Issues (~10):**

```
libpdx-cap.M1-001 scaffold + module boundary (cap_pack, cap_unpack, cap_manifest_verify)
libpdx-cap.M1-002 caps.decl parser (per design/tooling/plan.md invariant I6)
libpdx-cap.M2-001 cap_manifest_verify: OK | MISSING | EXTRA against callee caps.decl
libpdx-cap.M2-002 rights-narrowing at send site (widening → reject)
libpdx-cap.M2-003 rights-check at receive site (extra cap → reject)
libpdx-cap.M3-001 KIND_USER_ref decode helpers for ls --long owner rendering
libpdx-cap.M3-002 signed-inode helpers (re-sign under invoker user_sk if unlocked)
libpdx-cap.M4-001 round-trip fuzz (10^6 random cap shapes)
libpdx-cap.M4-002 caps.decl parse-error corpus + narrowing/extra-cap invariant matrix
libpdx-cap.M5-001 dual-signed release + .pdxdoc + mirror push
```

---

### §5.11 `libpdx-semantic-pipe` (repo `paideia-os/libpdx-semantic-pipe`)

**Milestones.**
- **M1 — Design + skeleton.** Scaffold + wrap `KIND_IPC_ENDPOINT`. R20b 8-byte header + BLAKE3-truncated schema_hash prefix (32 bytes). Baseline: `libpdx_semantic_pipe_bind(fd, schema_id)` binds schema once; subsequent frames validate against the bound schema.
- **M2 — Core implementation.** Sender side: bind + `send_record(rec)` serializes and prefixes with schema_hash. Receiver side: `recv_record(schema_id)` decodes into typed record when hash matches, falls through to text layer when it doesn't. Passthrough mode (shell + cat schemaless case): forwards records without decoding.
- **M3 — Semantic-pipe / audit integration.** Schema-registry lookup (schemas identified by 32-byte BLAKE3 truncated hash; registry is a userspace service, registered under `svc.schema-registry`). Version-tolerance rules (per `design/ipc/typed-handoff.md`).
- **M4 — Tests + smoke.** Bind → send → recv round-trip against known schemas; schema-mismatch drop-through to text layer; version-tolerance matrix (compatible upgrades accepted, incompatible rejected); passthrough correctness (bytes preserved exactly across shell pipeline).
- **M5 — 1.0 signed release.** Dual-signed release, `.pdxdoc`, mirror push.

**Cross-repo dependencies.** libpdx-semantic-pipe.M1 depends on libpdx-cap.M1 (pipe endpoints are caps); libpdx-semantic-pipe.M3 depends on the schema-registry service (deferred substrate — file as `paideia-os#new svc.schema-registry userspace service` if not planned elsewhere).

**Issues (~10):**

```
libpdx-semantic-pipe.M1-001 scaffold + wrap KIND_IPC_ENDPOINT with schema_hash prefix
libpdx-semantic-pipe.M1-002 libpdx_semantic_pipe_bind: one schema bind per endpoint
libpdx-semantic-pipe.M2-001 sender: send_record with BLAKE3 schema_hash prefix
libpdx-semantic-pipe.M2-002 receiver: recv_record with hash-match decode, fall-through to text
libpdx-semantic-pipe.M2-003 passthrough mode (shell + cat forward without decoding)
libpdx-semantic-pipe.M3-001 schema-registry lookup via svc.schema-registry broker
libpdx-semantic-pipe.M3-002 version-tolerance rules per design/ipc/typed-handoff.md
libpdx-semantic-pipe.M4-001 bind → send → recv round-trip against known schema corpus
libpdx-semantic-pipe.M4-002 schema-mismatch drop-through + version-tolerance matrix
libpdx-semantic-pipe.M5-001 dual-signed release + .pdxdoc + mirror push
```

---

### §5.12 `libpdx-argv` (repo `paideia-os/libpdx-argv`)

**Milestones.**
- **M1 — Design + skeleton.** Scaffold + long-flag primary grammar (per D3 in `design/tooling/plan.md`). Baseline: parse `--foo bar` and `--foo=bar` into a `ParsedArgs` struct.
- **M2 — Core implementation.** Short flags one-per-hyphen (never clustered — this is a break with GNU); typed flag arguments (`--older-than 7d`, `--size > 1MB`); the 9-flag standard vocabulary from I3; positional-argument list.
- **M3 — Semantic-pipe / audit integration.** Alternate invocation path: called from another tool via semantic-pipe typed record (schema-driven arg binding) converges on the same `ParsedArgs` struct. `--help` back-end integration with `doc <tool>`. `--schema` prints the tool's declared output schemas.
- **M4 — Tests + smoke.** Parse-correctness matrix (long, short, typed, positional, mixed), clustered-short-flag rejection (`-la` → error, per D3), typed-arg-parse-error diagnostics, `--help` render round-trip via doc.
- **M5 — 1.0 signed release.** Dual-signed release, `.pdxdoc`, mirror push.

**Cross-repo dependencies.** libpdx-argv.M1 has no library dependencies (pure userspace); libpdx-argv.M3 depends on libpdx-semantic-pipe.M2 (alternate invocation path) and doc.M2 (`--help` back-end); libpdx-argv.M5 depends on pkg.M4.

**Issues (~10):**

```
libpdx-argv.M1-001 scaffold + ParsedArgs struct + long-flag grammar (--foo bar / --foo=bar)
libpdx-argv.M1-002 short-flag grammar one-per-hyphen (clustered → reject, per D3)
libpdx-argv.M2-001 typed flag arguments (--older-than 7d, --size > 1MB)
libpdx-argv.M2-002 9-flag standard vocabulary from I3 (--help --version --dry-run --json --schema --verbose --quiet --color= --no-cap:)
libpdx-argv.M2-003 positional-argument list handling
libpdx-argv.M3-001 alternate invocation: typed schema record → ParsedArgs
libpdx-argv.M3-002 --help back-end integration with doc <tool>
libpdx-argv.M3-003 --schema prints tool's declared output schemas
libpdx-argv.M4-001 parse-correctness matrix + clustered-short-flag rejection tests
libpdx-argv.M5-001 dual-signed release + .pdxdoc + mirror push
```

---

### §5.13 `libpdx-audit` (repo `paideia-os/libpdx-audit`)

**Milestones.**
- **M1 — Design + skeleton.** Scaffold + three-call API (`audit_begin`, `audit_record_output`, `audit_commit`). Baseline: audit_begin returns an audit_id; audit_commit writes the completed record to `svc.audit-journal` via `sys_ipc_send`.
- **M2 — Core implementation.** Full record shape matching UEJ_KIND_TOOL_INVOKE / UEJ_KIND_TOOL_OUTPUT / UEJ_KIND_TOOL_EXIT (constants land in §5.0 R49-PREP-006). Failure semantics: if `svc.audit-journal` is unreachable or full, the calling tool refuses to emit output (exit 3 — system error per I4). Retry-with-backoff for transient broker unavailability (bounded — 3 retries then hard-fail).
- **M3 — Semantic-pipe / audit integration.** `audit_record_output` records a hash of the tool's output stream (BLAKE3-truncated) so a supervisor replaying the audit journal can verify what was seen at output time even if the output stream was ephemeral. Integration with shell's per-command journal (shell's `ShellCommandRecord` is the parent record; per-tool records are children linked by audit_id).
- **M4 — Tests + smoke.** Begin → record → commit round-trip; broker-unavailable refusal (tool exits 3, no output); backoff correctness (3 retries); parent-child linkage (shell's command record parents every child tool's record); audit journal replay against a known trace.
- **M5 — 1.0 signed release.** Dual-signed release, `.pdxdoc`, mirror push.

**Cross-repo dependencies.** libpdx-audit.M1 depends on §5.0 R49-PREP-006 (svc.audit-journal broker + UEJ_KIND_TOOL_* constants); libpdx-audit.M3 depends on shell.M2 (parent-child linkage) and libpdx-semantic-pipe.M2 (audit records travel on a semantic pipe).

**Issues (~10):**

```
libpdx-audit.M1-001 scaffold + three-call API (audit_begin, audit_record_output, audit_commit)
libpdx-audit.M1-002 audit_id allocation + svc.audit-journal broker binding
libpdx-audit.M2-001 record shape matches UEJ_KIND_TOOL_INVOKE/OUTPUT/EXIT
libpdx-audit.M2-002 failure semantics: broker unreachable → tool refuses output (exit 3)
libpdx-audit.M2-003 retry-with-backoff (bounded 3 retries, then hard-fail)
libpdx-audit.M3-001 audit_record_output writes BLAKE3-truncated output-stream hash
libpdx-audit.M3-002 parent-child linkage with shell ShellCommandRecord via audit_id
libpdx-audit.M4-001 broker-unavailable refusal test (tool exits 3, no output emitted)
libpdx-audit.M4-002 audit-journal replay correctness against known trace
libpdx-audit.M5-001 dual-signed release + .pdxdoc + mirror push
```

---

### §5.14 `libpdx-elevate` (repo `paideia-os/libpdx-elevate`)

**Milestones.**
- **M1 — Design + skeleton.** Scaffold + wrap the R48.M7 codec (`elv_pack_request` at `src/kernel/core/ipc/elevate_channel.pdx:174`, `elv_cap_mask_valid`, `elv_duration_valid`). Baseline: build a request struct, pack it, send to `svc.elevate-broker`, block on reply.
- **M2 — Core implementation.** Auto-approve path: consult `src/kernel/core/user/elevate_policy.pdx` for matching op-pattern + cap-mask + duration rule before human hop; human-approve path: block on founder response with a timeout (per-request configurable, default 30s). Response yields a `Cap<KIND_ELEVATE_CHANNEL>` (0x191, allocated in §5.15) with a bounded lifetime — cap self-invalidates at deadline.
- **M3 — Semantic-pipe / audit integration.** Every elevate request and every response journals via `libpdx-audit` to the user_events_journal (extends UEJ_KIND_ELEVATE, already at ordinal 5). Client-side retry loop for transient broker unavailability (bounded).
- **M4 — Tests + smoke.** Auto-approve match against policy table; auto-approve miss → human path; human-approve timeout → clean reject (exit 4); cap-lifetime enforcement (using the elevate cap past deadline → kernel rejects); dual-verified journal entry pair (request + response) landing in user_events_journal.
- **M5 — 1.0 signed release.** Dual-signed release, `.pdxdoc`, mirror push.

**Cross-repo dependencies.** libpdx-elevate.M1 depends on §5.0 R48-PREP-004 (`KIND_ELEVATE_CHANNEL = 0x191`) and R48-PREP-005 (broker registration + policy wiring); libpdx-elevate.M2 depends on libpdx-cap.M2 (cap narrowing for the returned KIND_ELEVATE_CHANNEL sub-caps); libpdx-elevate.M3 depends on libpdx-audit.M2.

**Issues (~10):**

```
libpdx-elevate.M1-001 scaffold + wrap elv_pack_request from R48.M7 codec
libpdx-elevate.M1-002 svc.elevate-broker binding + block-on-reply skeleton
libpdx-elevate.M2-001 auto-approve path: consult elevate_policy.pdx before human hop
libpdx-elevate.M2-002 human-approve path with timeout (default 30s, per-request configurable)
libpdx-elevate.M2-003 Cap<KIND_ELEVATE_CHANNEL=0x191> with bounded-lifetime self-invalidation
libpdx-elevate.M3-001 request + response journal via libpdx-audit (extends UEJ_KIND_ELEVATE)
libpdx-elevate.M3-002 retry-with-backoff for transient broker unavailability
libpdx-elevate.M4-001 auto-approve match/miss matrix against policy table
libpdx-elevate.M4-002 cap-lifetime enforcement test (using past deadline → kernel rejects)
libpdx-elevate.M5-001 dual-signed release + .pdxdoc + mirror push
```

---

### §5.15 KIND ordinal allocation summary + reservation pool

Four new derived KINDs allocated in §5.1, §5.2, and §5.14, distributed for locality (elevate first since it is the substrate every other tool uses; pkg's two contiguous; shell's last). The block 0x191–0x194 is filled; 0x195–0x19F stay unallocated as the R50-and-beyond reservation pool. Any Round-2 refinement or R51+ tool needing a new derived kind allocates from 0x195 upward. When 0x19F is reached, the next block opens at 0x1A0 (this doc will need an amendment then).

| Ordinal | KIND | Derived over | Repo home |
|---------|------|--------------|-----------|
| 0x191 | `KIND_ELEVATE_CHANNEL` | `KIND_IPC_ENDPOINT` (base 5) | paideia-os R48-PREP-004 (kernel) |
| 0x192 | `KIND_PACKAGE_REPO` | `KIND_NETWORK` (existing) | paideia-os/pkg |
| 0x193 | `KIND_PACKAGE_MANIFEST` | `KIND_PDXFS_FILE` (R42) | paideia-os/pkg |
| 0x194 | `KIND_SHELL_SESSION` | `KIND_USER` (0x190) | paideia-os/shell |
| 0x195–0x19F | *reserved* | — | Round-2 refinements + R50+ |

**KIND ordinal cross-check.** Before this doc merges, main runs `grep -rE 'pub let KIND_[A-Z_]+\s*:\s*u64\s*=\s*0x19[1-4]' src/kernel/core/cap/` and confirms zero matches (the four ordinals are unclaimed at HEAD). The four repos then land their KIND declarations as part of M1/M2 as scoped above; the kernel's kind-registry sidecar (if any exists at R49 close) discovers the new kinds via the R20b InitCap seed rather than through a kernel-side kind_*.pdx file, since these are userspace-defined derived kinds.

---

## 6. Round-2 close: substrate summary + next steps

**Substrate gaps flagged for main to address before R49 wave starts.**

1. **R42 PdxFS v1 substrate not present at HEAD.** `src/kernel/core/cap/kind_pdxfs_file.pdx` and `kind_pdxfs_txn.pdx` do not exist. Filed as `R42-PREP-001` through `R42-PREP-003` in §5.0. Blocks: pkg.M1, shell.M2 (`~/.history/` write), ls.M1, cat.M1, cp.M1, mv.M1, rm.M1, mkdir.M1. **All R49 tooling gated on R42-PREP milestone reaching 100%.**
2. **KIND_ELEVATE_CHANNEL not present at HEAD.** R48.M7 landed the codec + policy + journal without a distinct KIND; softarch Round 2 introduces `KIND_ELEVATE_CHANNEL = 0x191`. Filed as `R48-PREP-004` through `R48-PREP-005` in §5.0. Blocks: libpdx-elevate.M1 (and therefore pkg.M3 + cp.M3 + mv.M3 + rm.M3).
3. **svc.audit-journal broker registration + UEJ_KIND_TOOL_* constants not present at HEAD.** The user_events_journal has `UEJ_KIND_ELEVATE = 5`; adds needed for `UEJ_KIND_TOOL_INVOKE`, `UEJ_KIND_TOOL_OUTPUT`, `UEJ_KIND_TOOL_EXIT`. Filed as `R49-PREP-006`. Blocks: libpdx-audit.M2 (and therefore every tool's M3).
4. **svc.schema-registry userspace service.** libpdx-semantic-pipe.M3 references it; softarch Round 2 could not find planning for it in the current `design/` tree. Filed as a note on libpdx-semantic-pipe.M3-001 for main to trace: either it is already scheduled in a wave softarch missed (in which case cross-link the plan doc here in an amendment), or it needs a fresh issue against paideia-os main repo before R49 close.

**Repository creation checklist for main.** After the six §5.0 issues are filed and the four substrate gaps are triaged, main creates the 14 GitHub repos under `github.com/paideia-os/`:

R49-wave repos (blocking coreutils): `pkg`, `shell`, `doc`, `libpdx-cap`, `libpdx-semantic-pipe`, `libpdx-argv`, `libpdx-audit`, `libpdx-elevate` (8 repos).

R50-wave repos (coreutils, all can start in parallel once shell.M4 + all §5.10–§5.14 libs at M2): `ls`, `cat`, `cp`, `mv`, `rm`, `mkdir` (6 repos).

Then main files the ~200 issues drafted across §5.0–§5.14 (145 tool issues + 50 library issues + 6 substrate-prep issues = 201 total; per-repo counts range from 10 for the smallest library to 17 for pkg + rm).

---

*End of §5. Ready for main to create the 14 GitHub repos and file the ~150 issues from §5.*
