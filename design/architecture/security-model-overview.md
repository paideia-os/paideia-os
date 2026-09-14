# Security Model Overview

## Purpose

This is the capstone of a five-document wave synthesizing paideia-os's
security posture into one narrative. It does not re-derive or restate
the detailed tables its sibling documents already own:

- `design/architecture/syscall-table-v2.md` — the syscall-by-syscall
  capability-gate table (sysno, arity, effects, gate) and the
  "Ambient-Authority Tension" section this document's §2 draws its
  sysno list directly from.
- `design/architecture/kernel-cap-taxonomy.md` — the full `KIND_*`
  enumeration, base-kind vs. derived-kind space, and per-kind
  mint/query/revoke op surfaces.
- `design/architecture/ipc-endpoint-lifecycle.md` — the full lifecycle
  of a `KIND_IPC_ENDPOINT` capability: tail encoding, acquisition via
  `svc_lookup`, send/recv/reply, and what happens to blocked peers when
  an endpoint's owner dies.

What this document adds is the connective tissue between those tables:
what the capability model is designed to be, where it actually stands
today (including the ambient-authority carve-out, stated plainly rather
than softened), how a capability is narrowed on derivation, what
revocation and its cascade actually do, how `caps.decl` narrows
authority at `sys_execve`, how the elevate-broker fails closed, and
what is and is not yet real about post-quantum signature verification.
Every claim below cites a file and, where useful, a line, so it can be
checked against the source rather than trusted as paraphrase. Where a
mechanism is designed but not implemented, or implemented as a
fail-closed stub, that is stated as such — this is a young kernel, and
several security primitives are scaffolding with a real gate already
wired in front of them.

## §1 The capability model as designed

The intended end-state has one governing rule: **no ambient authority**.
Every kernel-mediated resource is reached through a capability — a
24-byte descriptor `{kind: u64, rights: u64, target_ptr: u64}` stored in
a 256-slot `cap_table` (the stride-24 slot address arithmetic every
kind's gate repeats is shown at
`src/kernel/core/cap/kind_endpoint.pdx:264-269`). No fd number, pid, or
global object name is supposed to confer authority on its own; `kind`
names which `KIND_*` handler owns the slot, `rights` is a bitmask
subset-checked against a per-kind `R_<KIND>_ALL` ceiling, and
`target_ptr` is a kind-specific "tail" (for `KIND_IPC_ENDPOINT` it packs
an `endpoint_id` plus a send/recv/bidi direction,
`kind_endpoint.pdx:18-30`; for derived kinds such as `KIND_SURFACE`
(0x1B8) it is a row index into a kind-owned table,
`kind_surface.pdx:162-172` — full taxonomy in
`design/architecture/kernel-cap-taxonomy.md`).

Two structural properties recur across every kind file and are the
load-bearing mechanics of "no ambient authority":

- **Kind-first gating.** Every accessor checks `descriptor.kind ==
  KIND_X` before touching rights or the row — `kind_surface.pdx`'s
  `surface_row_valid` (349-371) and `kind_endpoint.pdx`'s
  `ipc_slot_to_endpoint` (343-384) share this shape. A stale or
  wrong-kind slot fails the same way a never-minted slot does.
- **Generation / liveness headers on derived rows.** An `in_use` bit
  plus a generation counter in the row header (e.g.
  `kind_surface.pdx:148-160`) means a destroyed-then-reused row does
  not silently hand a stale reference the new occupant's identity —
  `surface_destroy` bumps generation before clearing `in_use`
  (`kind_surface.pdx:1005-1013`).

Least privilege is meant to be enforced structurally, not by
convention, at two boundaries: mint time (a capability can only ever
authorize minting a *narrower* one — §3) and process-exec time (a
tool's authored `caps.decl` one-way-narrows whatever it inherited — §5).
In this design, a resource with no capability naming it is simply
unreachable — there is no fallback path through a global identifier.

## §2 The capability model as it exists today

That end-state is not what the syscall table shows. Per
`design/architecture/syscall-table-v2.md`'s syscall-by-syscall table and
its own "Ambient-Authority Tension" section, the capability-gated
syscalls are a minority of the surface:

- **Actually capability-gated:** the IPC family (`ipc_recv`/`ipc_reply`/
  `ipc_send`/`svc_lookup`, sysnos 40-43), the PdxFS transaction/file
  family (`pdxfs_txn_open`/`pdxfs_open`/`pdxfs_dir_readnext`,
  70-72, and `pdxfs_txn_commit`/`pdxfs_txn_abort`/`pdxfs_undo_write`/
  `volume_mint`, 104-107 and 114), the R105 GUI block
  (`framebuffer_create`/`framebuffer_map`/`page_flip`/
  `page_flip_wait`/`display_hotplug_subscribe`, 109-113), and
  `icmp_echo` (103, gated on `R_NET_PRIVILEGED_PROTOCOL`).
- **Running on ambient authority, with no cap-table lookup at
  dispatch at all:** the entire legacy POSIX-shaped core (`read`,
  `write`, `open`, `close`, `dup2`, `getpid`, `fork`, `execve`, `exit`,
  `wait4` — sysnos 0-3, 32, 39, 56, 59-61), the whole VFS metadata block
  (`stat`/`getdents`/`mkdir`/`rmdir`/`unlink`/`rename`, 77-82), the
  entire BSD-socket surface (`socket` through `getsockname`, 87-102),
  and several newer, non-legacy syscalls that were nonetheless never
  wired to a cap check: `taskinfo` (83), `mountinfo` (84), `chdir`/
  `getcwd` (85-86), `pdxfs_stat_by_inode` (106), `display_enumerate`
  (108), `semantic_send` (115), `sched_wait_ns` (116), and
  `cwd_resolve` (517).

This is a real deviation from a pure capability-based model, not a
documentation gap, and not something to soften into "coverage is still
growing evenly." As `syscall-table-v2.md` states it: the low-numbered
syscalls were frozen early (R15.M4) to keep userland ports mechanical
against Linux numbering, and later additions have largely followed
whichever sibling syscall they extend rather than being audited against
the capability discipline the newer subsystems (IPC, PdxFS transactions,
GUI) already enforce. Notably, the gap is not confined to the frozen
legacy block — `taskinfo`, `mountinfo`, `pdxfs_stat_by_inode`,
`display_enumerate`, `semantic_send`, and `sched_wait_ns` are all
syscalls numbered *above* the legacy core, added alongside
capability-native subsystems, and still shipped ambient. "Newer" is not
a proxy for "capability-gated" anywhere in this table.

Two mechanisms partially compensate for this gap without closing it:
`caps.decl` (§5) narrows a *process's* held capabilities at exec time
regardless of which syscalls it goes on to call, and `cap_invoke`
(sysno 4) is the one syscall whose gate is fully capability-driven,
resolved per-kind inside the call rather than at the dispatch shim. But
neither retrofits a cap check onto `read`, `open`, `stat`, `socket`, or
any of the other ambient sysnos above — a task holding an fd, a pid, or
a bare path string can still act on it directly. This tension is
tracked further in §8.

## §3 Derivation

There is no single generic `cap_derive(parent, ...)` entry point in the
kernel. `grep -rln "cap_derive" src/kernel/core/cap/` returns only files
that *reference* the concept in comments (`kind_op_region.pdx`,
`kind_i2c_slave.pdx`, `kind_acpi_event.pdx`, `kind_ec_query.pdx`) — none
of them, nor any other file in that directory, defines a function
literally named `cap_derive`. Derivation is instead implemented
per-kind, as a **derivation gate** function conventionally named
`<kind>_check_parent_<parent-kind>`, called at the top of that kind's
own `*_cap_mint_inner`. This is real, exercised code — not a stub —
and every derived kind in the taxonomy implements the pattern. Worked
examples:

- `kind_sig_key.pdx:271-305` (`sig_key_check_parent_memory`) requires
  `parent.kind == KIND_MEMORY (4)` and `parent.rights & RIGHT_MINT`.
- `kind_elevate_channel.pdx`'s parent-endpoint gate requires
  `parent.kind == KIND_IPC_ENDPOINT (5)`, but deliberately does *not*
  require `RIGHT_MINT` on that parent — per the file's own §0 rationale,
  the broker's own mint gate on the request side is what confers
  authority to drive an elevation flow, not mere possession of a plain
  endpoint cap to talk to it.
- `kind_i2c_slave.pdx:493` (`i2cs_check_parent_bus`) requires the parent
  to carry a *derived* bus tag rather than the raw base `KIND_DEVICE`,
  so a generic device cap cannot mint a bus-rate-validated slave — the
  same distinction `opregion_cap_derive` draws for ACPI operation
  regions.
- `kind_op_region.pdx:185` states the general rule explicitly in-tree:
  **"DERIVE IS MONOTONE"** — a child's rights and reach must be a
  subset of what the parent capability already proves, never a
  superset.

So "narrower" is checked two ways depending on the kind: a **rights
subset** check against the parent's rights bitmask (the universal case,
matching §1's design intent), and a **kind-appropriate structural
narrowing** of the parent's identifying parameters — the child's
target/address/bus/GSI is *inherited* from the parent's own row rather
than accepted as a caller-supplied argument, so a child cannot
misreport which resource its authority traces back to (see
`kind_acpi_event.pdx`'s GSI-inheritance comment, which names this the
same discipline as `opregion_cap_derive`'s address-space inheritance).
What does not exist is a single reusable primitive — each kind
hand-writes its own gate against its own parent-kind rule, consistent
with the taxonomy's "closed 16-kind base enum, open derived-kind
lattice" design (`kind_endpoint.pdx:32-37`, `kernel-cap-taxonomy.md`
§2).

## §4 Revocation

`src/kernel/core/cap/revoke.pdx` implements `cap_revoke(handle) -> u64`
(lines 119-141). This is explicitly resolved, not assumed: the file's
own header comments (9-18, 80-110) describe both its current state and
its history, and are summarized rather than restated here.

**`cap_revoke`'s real body landed at R31.M1-1589** (#1589). It decodes
`slot = handle & 0xFF`, delegates to `cap_revoke_slot`
(`src/kernel/core/cap/owner.pdx:464`), and returns that dispatcher's
code verbatim. `cap_revoke_slot` in turn dispatches on the slot's
descriptor kind: `KIND_OP_REGION` (0x150) runs
`opregion_cascade_revoke_by_parent` before its own audited revoke
because operation regions are the one transitive kind whose cascade is
an iterated fixed point; kinds 0x152-0x157 each call their own audited
revoke (the same symbol their lineage cascades call, so an owner sweep
leaves the identical audit trail a lineage teardown would); every other
kind takes a generic path that clears the three descriptor words and
emits a `DRV_AUDIT_EV_REVOKE` record (`owner.pdx:467`). The owner
column is cleared in every case, including a refused per-kind revoke,
because the column records *who held* the slot, and a dead process's
key must not survive on it. **A revoke_cascade *does* exist and *does*
run today** — it is just not one generic tree-walk invoked from
`cap_revoke` itself, but a family of per-kind cascade functions
(`user_cap_revoke_cascade` in `kind_user.pdx:844-900`,
`opregion_cascade_revoke_by_parent` in `kind_op_region.pdx`, and
equivalents for the other transitive kinds) that `cap_revoke_slot`
threads through. `kind_user.pdx`'s cascade is the clearest worked
example: revoking a user row recurses into every live row whose
`delegated_by_key` matches, freeing descendants before the row itself,
and is explicitly idempotent on an already-dead child so a large
cascade's inner recursion cannot double-free a node the outer walk also
reaches (`kind_user.pdx:844-900`).

**The `kind_endpoint.pdx` deferred-body note is resolved: the real body
has landed.** `kind_endpoint.pdx`'s mint gate previously said the real
descriptor-slab write was "deferred until `cap_revoke` grows a real
body" — that body landed at R31.M1-1589, so the blocking condition
named in that comment no longer holds. Whether `KIND_IPC_ENDPOINT`'s own
mint path was subsequently re-pointed at `cap_mint_write` is a separate
question from whether `cap_revoke` has a real body, and was not
re-verified line-by-line in this pass against the current
`kind_endpoint.pdx` mint call sites — flagged in §8 rather than assumed.

**What is genuinely still a gap:** `cap_revoke` has **no caller in any
shipped syscall path** (`revoke.pdx:80-105`, stated verbatim by the
file's own comment: "There is no `call cap_revoke` anywhere in
`src/kernel/`; the only invocations in the tree are direct calls from
witnesses"). Every revocation the running kernel actually performs
today enters one layer down, at `cap_revoke_slot` — from
`cap_owner_sweep_revoke` on process death, from a kind's own audited
revoke, or from a lineage cascade. `cap_revoke` becomes reachable only
once a syscall takes a bare *handle*, which needs the handle-layout
question settled first (see below). And there is **no generation
check**: the current handle layout is 8 bits (`bits[7:0]`) with no room
for a generation field, so `cap_revoke` given a stale handle to a slot
that was revoked and re-minted **to the same kind** cannot tell the two
apart — the per-kind row accessors defend against this at the row level
(tail-valid plus generation checks, e.g. `kind_surface.pdx`'s
`SURFACE_GEN_MISMATCH`), but the generic handle path does not, because
there is nowhere in an 8-bit handle to put a generation
(`revoke.pdx:58-77`, `design/capabilities/handle-layout.md`).

Per-kind revoke leaves (`sig_key_cap_revoke`, `elevate_channel_cap_revoke`,
`surface_destroy`, etc.) consistently distinguish "never existed"
(`*_BAD_SLOT`) from "already revoked" (`*_REVOKE_ALREADY` /
`*_DESTROY_ALREADY`) — a deliberate repeated pattern across the
taxonomy, not incidental, and the same idempotence property the
cascade functions themselves rely on to tolerate a child a parent
cascade already freed.

**Bottom line:** revocation and its cascade are implemented and real —
this is not aspirational — but they are reached exclusively through
slot-based, lifecycle-triggered, or kind-internal paths. The
generic, handle-based `cap_revoke` entry point is dead code by the
project's own admission, pending a handle-layout decision that would
let a syscall call it safely.

## §5 Exec-time narrowing

`design/architecture/caps-decl-format.md` specifies the mechanism that
narrows a child process's capability set at `sys_execve`
(R90-XREPO.013.M1-001, #2130; kernel substrate in
`src/kernel/core/cap/reconcile.pdx`, #2129). In summary — see that
document for the full grammar, wire format, and failure/audit table:
every tool declares its maximum capability set in a `caps.decl` file
(embedded in `.rodata.caps_decl` or a side-car at
`/etc/caps/<toolname>.decl`); at exec the kernel computes
`C[kind] = P[kind] AND D[kind]` per kind — narrow-only, never
widening — and a `!`-prefixed mandatory line whose narrowed result
falls short of the declared rights fails the exec with `-EACCES`.
Malformed or duplicate declarations reject the whole file rather than
partially parsing. The decl itself is a signed input in the tool's
`manifest.pdxsig`, so tampering with a shipped decl is meant to fail
signature verification before the reconciler ever runs — though see §7
on how much load that "signed" currently bears in practice.

This is the single strongest concrete instrument for closing the §2 gap
that exists today, precisely because it applies uniformly regardless of
which syscall-numbering era (legacy ambient or capability-native) a
tool's own code path happens to use: a tool that never held
`KIND_TCP_SOCKET` at exec time cannot manufacture socket authority later
just because `socket()`/`bind()`/`connect()` (87-91) themselves perform
no cap check. It narrows the *process*, not the syscall table — which
is also its limit: two co-resident tools that both declared
`KIND_PDXFS_FILE` are still mutually unconstrained by any per-syscall
gate on `read`/`write`/`open` once both hold the cap kind, because
those syscalls do not consult the cap table at all. `caps.decl` is also
still mid-rollout: `caps-decl-format.md` §5.1 records that the
substrate currently treats an absent decl as permissive (`0`, not
`-EACCES`) until every tool in the R90-XREPO.013 M3/M4 tables ships one,
tracked by the M5-001 closeout audit — a single-line flip in
`reconcile.pdx` that has not yet happened.

## §6 Privilege elevation

The elevate broker (`svc.elevate-broker`) mediates privilege escalation
over `KIND_ELEVATE_CHANNEL` (0x191, derived over `KIND_IPC_ENDPOINT`;
`src/kernel/core/cap/kind_elevate_channel.pdx`). A client that wants a
narrow, time-bounded escalation (the sudo-replacement flow,
`design/user/model.md` §5) first resolves an endpoint cap to the broker
via `svc_lookup` — so reaching the broker at all sits behind the same
IPC capability gate as any other service — then mints a channel row
carrying one in-flight request through
`REQUESTED -> APPROVED|DENIED -> EXPIRED|REVOKED`. `R_MINT` is
deliberately absent from the channel's own rights set, so an approved
request cannot itself become a factory for further grants.

Two independent layers implement the fail-closed posture:

1. **Static policy pre-check**
   (`src/kernel/core/user/elevate_policy.pdx`, R48.M7-002 #1550) — a
   signed table of auto-approval rules consulted before interactive
   approval. Its own header states the posture directly: "A policy row
   that fails signature verification at boot is DROPPED from the table
   (not partially trusted): a policy the boot verifier cannot prove is
   authorized MUST NOT auto-approve anything." A request matching no
   row falls through to interactive approval rather than defaulting to
   allow.
2. **Broker dispatch fails closed on I/O failure** — the real broker
   body, `elevate_broker_serve_one`
   (`src/kernel/core/ipc/elevate_broker.pdx`, R90-XREPO.011.M1-003
   #2122), reads `/system/policy` from tmpfs and parses it
   first-match-wins. Per its own justification: "Any I/O failure
   (missing `/system`, missing policy, `tmpfs_read` sentinel)
   short-circuits to `ELVC_STATE_DENIED` per §3 fail-closed." An
   unreadable or missing policy file denies the request; it does not
   fall back to permitting it.

The broker's actual v1 scope is narrower than "mediates privilege
elevation" might suggest, and its own comments say so plainly rather
than leaving it to be discovered: it treats **every** request as
targeting `/system/` regardless of the request's real target, because
the `KIND_ELEVATE_CHANNEL` row layout carries no target-path field yet
(widening to a real handle is deferred to v2,
`design/security/elevate-broker.md` §4); role resolution is coarse
(`pid == 1` matches role `INIT`, anything else matches only the
wildcard `*`; `ADMIN`/`OWNER` roles never match anything at v1, per
`design/security/elevate-policy-format.md` §2.2). So today's elevate
broker fails closed correctly within a scope that is itself
intentionally narrow and explicitly documented as a v1-only
approximation of the eventual per-target model — a design choice, not
a silent limitation.

## §7 PQ signature discipline

**The design-level posture is genuinely post-quantum, not classical
with an aspiration attached.** `design/security/pq-trust-root.md`
(PQ-Q1/PQ-Q3) specifies hybrid-by-default cryptography throughout: every
signature is `classical ‖ PQ` — Ed25519 + ML-DSA-65 (NIST L3) for
release/operational signing, SLH-DSA-128s (NIST L1, hash-based) for the
boot chain, SLH-DSA-256s (NIST L5, hash-based, ceremonial) for the
long-lived root — and every key exchange is hybrid X25519 + ML-KEM-1024
(NIST L5). This vocabulary is not confined to the design doc: the
kernel's own capability substrate names it concretely.
`src/kernel/core/cap/kind_sig_key.pdx` (`KIND_SIG_KEY`, 0x1A3) is stated
in its own header to be "the runtime authority for ONE ML-DSA-65
public-key handle," and `elevate_policy.pdx`'s 96-byte signed-row
format reserves a 32-byte `sig_slice` field explicitly documented as
"the first 32 bytes of ML-DSA sig."

**The implementation status is the opposite of the design posture: the
verify step is not yet a working verifier anywhere it is wired in.**
Two concrete, in-tree facts, not inference:

- `src/kernel/core/fs/pdxfs/sig_verify.pdx`'s `sig_hash_verify_stub`
  unconditionally returns `INODE_TAIL_HASH_MISMATCH` (0xFFFFED1C)
  because paideia-as has no `blake3_hash32` kernel-callable primitive
  yet — the file names this a "CONFIRMED cross-repo gap," and its own
  comment calls the stub "UNIMPL... fail-closed by design: no caller
  can be silently told a signature block's hash matched when no hash
  was ever computed." The ML-DSA-65 verify step proper is also, by the
  same file's own account, "not yet a real accept path," and is
  unreachable regardless because the hash pre-check always fails
  first.
- `src/kernel/core/fs/pdxfs_lite/verify.pdx`'s `ml_dsa_verify_stub` is
  the inverse failure mode: it **unconditionally returns 1 (pass)**,
  a placeholder occupying the symbol slot until the real R32 ML-DSA-65
  primitive at `src/kernel/core/crypto/ml_dsa/verify.pdx` lands. It is
  documented as compile-time-dead under
  `Features.CRYPTO_ML_DSA_ENABLED=0` at R25.M5 — inert scaffolding, not
  a live accept-everything hole, but also not a verifier. The same
  file's dev-bypass superblock check (R25-M5-001, #929) accepts a
  superblock iff its 3400-byte signature field is bytewise all zero —
  it rejects a garbage signature even under dev-bypass, so the bypass
  is "verify nothing is present" rather than "verify nothing at all,"
  but it performs no cryptographic verification either.

So the algorithm choice — ML-DSA-65 / SLH-DSA / ML-KEM-1024, real
NIST-standard names, chosen and documented at the design layer — is not
a placeholder in the sense of "someday we will pick a PQ scheme"; that
decision is made. What remains aspirational is the *executing verifier*:
no in-tree code today performs a real BLAKE3 hash check or a real
lattice-based ML-DSA-65 signature verification. Every load-bearing PQ
verify path currently resolves to a fail-closed stub (deny) or an inert
dead branch (pass, but unreachable in shipped configuration). §5's claim
that `caps.decl`'s manifest is a "signed input" should be read in this
light: the manifest *format* and its declared coverage are real, but the
cryptographic verification behind "signed" is not yet load-bearing
anywhere in the exec path. `pq-trust-root.md` §0.3 additionally records
that TPM 2.0 PQ primitives (ML-DSA/SLH-DSA in `swtpm`) are themselves
aspirational as of mid-2026, so the software-enclave path — not the TPM
— is the intended near-term load-bearing PQ signer even once the
verifier itself lands.

## §8 Open architectural debt

Concrete, not diplomatic — each item below is a specific gap this
survey found, with its evidence file:

- **Ambient-authority syscall surface (the largest single gap).**
  Per `design/architecture/syscall-table-v2.md`, the legacy POSIX-shaped
  core (sysnos 0-3, 32, 39, 56, 59-61), the VFS metadata block (77-82),
  the entire BSD-socket surface (87-102), and several newer syscalls
  (83, 84, 85-86, 106, 108, 115, 116, 517) run with **no cap-table
  lookup at dispatch**. Only the IPC family (40-43), the PdxFS
  transaction/file family (70-72, 104-107, 114), the R105 GUI block
  (109-113), and `icmp_echo` (103) are actually capability-gated. This
  is frozen-by-design for the legacy block (R15.M4, Linux-numbering
  compatibility) but is *not* explained for the newer additions — they
  simply were not audited against the discipline the IPC/PdxFS/GUI
  subsystems already enforce. No round or issue currently owns closing
  this; it is left open by `syscall-table-v2.md` itself as this
  document's opening problem.
- **`cap_revoke` has no syscall caller.** The handle-based generic
  revoke path (`src/kernel/core/cap/revoke.pdx:80-105`) is real,
  landed code (R31.M1-1589, #1589) that nothing in production calls;
  every actual revocation flows through `cap_revoke_slot` via
  lifecycle or kind-internal triggers. It becomes reachable only once
  a handle-taking revoke syscall exists, which depends on the next
  item.
- **Handle-layout has no generation field.** An 8-bit handle
  (`bits[7:0]`) cannot distinguish a live capability from a stale
  handle to a slot that was revoked and re-minted to the *same* kind
  (`revoke.pdx:58-77`). Resolving this is tracked at
  `design/capabilities/handle-layout.md` and gates the previous item.
- **`kind_endpoint.pdx`'s mint-path wiring to `cap_revoke` is stale
  and unconfirmed.** Its comment deferring the real descriptor-slab
  write "until `cap_revoke` grows a real body" predates R31.M1-1589,
  which landed that body; whether `KIND_IPC_ENDPOINT`'s mint call sites
  were subsequently updated was not re-verified line-by-line in this
  pass and should be checked directly before being relied on.
- **`caps.decl` absent-decl policy is still permissive.**
  `design/architecture/caps-decl-format.md` §5.1 records that an image
  with no decl is currently accepted (`0`, not `-EACCES`); the flip to
  fail-closed is a single line in `reconcile.pdx` gated on the
  R90-XREPO.013 M5-001 closeout audit completing across every tool in
  the M3/M4 tables, which has not happened yet.
- **Elevate-broker v1 target scoping is a real limitation, not just a
  documentation gap.** Every request is treated as targeting
  `/system/` regardless of its actual target, because the
  `KIND_ELEVATE_CHANNEL` row carries no target-path field yet; per-role
  resolution is coarse (`INIT`/`*` only — `ADMIN`/`OWNER` never match).
  Widening to a real per-target handle is deferred to v2
  (`design/security/elevate-broker.md` §4).
- **PQ signature verification is not wired to a real primitive
  anywhere in the exec/boot/manifest path.** `sig_hash_verify_stub`
  (`src/kernel/core/fs/pdxfs/sig_verify.pdx`) is fail-closed but
  blocked on a cross-repo BLAKE3 primitive (`blake3_hash32`) that does
  not yet exist in paideia-as. `ml_dsa_verify_stub`
  (`src/kernel/core/fs/pdxfs_lite/verify.pdx`) unconditionally passes
  but is compile-time-dead under `CRYPTO_ML_DSA_ENABLED=0`. The real
  R32 primitive at `src/kernel/core/crypto/ml_dsa/verify.pdx` does not
  exist in the tree under that path as of this survey. Until both land,
  every "signed" claim in this document's §5 and §6 (manifest.pdxsig,
  signed policy rows) is a format-and-coverage guarantee only, not a
  cryptographic one.
- **TPM PQ extension is itself aspirational.** `pq-trust-root.md` §0.3
  states plainly that TPM 2.0 PQ primitives (ML-DSA/SLH-DSA in
  `swtpm`) are not yet real as of mid-2026; the software-enclave, not
  the TPM, is the actual near-term load-bearing PQ signing surface,
  which has its own dependency on the ML-DSA verify primitive above.
