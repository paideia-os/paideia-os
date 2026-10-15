# Session-scoped bindings (R229.M2)

Issue: paideia-os#2720
Wave:  UMB-W29
Lands: 2026-10-14
Umbrella: paideia-os#2493 (R229 REPL evaluator loop)

## 1 Why

R229.M1 (`src/kernel/core/shell/repl_loop.pdx`, `design/shell/repl-
loop-scaffold.md`) lands the per-session REPL state machine: PROMPT -
READING - PARSED - EVAL - WRITING - IDLE.  The state machine *drives*
one read-eval-write cycle at a time but owns NO state across cycles --
`line_buf_head` resets on every `_rl_emit_prompt`, and the row's 8-
byte reserved tail is scrubbed on every `_rl_init_session`.

A shell session is useful because *it remembers*.  The user types

    let x = find . | count

at turn N and expects `x` to resolve to the same count on turn N+1,
N+2, N+20.  POSIX bash threads this via `~/.bash_history` + an in-
process environment hash; neither carries types (bash variables are
strings, period), neither composes with the semantic-shell pipeline
substrate, and both retire the moment the session's parent process
dies.

R229.M2 lands the one piece R229.M1 deferred: a per-session binding
store that threads BOTH the HM-inferred *type scheme* and the
evaluator's *value reference* across turns.  A free name in turn N+k's
expression first resolves against the session env; a `let` on turn
N inserts; an `unset` on turn N removes.

Design posture (`feedback_novel_clean_design`): the type environment
is CO-DOMAIN with the value environment -- a binding `x : u64 = 42`
is one 32-byte row holding both the HmCore type-pool reference and
the value reference.  POSIX's "every variable is a string, type-
checked never" is retired.

## 2 Scope

### R229.M2 (this landing)

* Persistent map `name -> (scheme_kind, type_ref, value_ref)` keyed
  by `(session_id, name)`.
* Public API: `_se_init`, `_se_init_session`, `_se_insert_binding`,
  `_se_lookup_binding`, `_se_unset_binding`.
* Error band `0x3700..0x37FF` (first R229 user-space band).
* Lives in the parser-tier satellite library
  (`tools/user/libpdx-pds-parser/src/session_env.pdx`) alongside
  HmCore (R225.M1) and the lambda / pipeline / datalog parsers --
  the type-scheme reference it stores is interpreted through
  HmCore's pool, so geographic co-location keeps the two modules
  linked in one object graph.

### Deferred

* `_se_terminate_session` -- cascade-wires into R127.M6 (session
  teardown) when the REPL loop closes a session.  M2's `_se_init_
  session` idempotently scrubs a row, so re-use after a crash-
  restart is safe without an explicit terminator.
* Parsing of `let NAME = EXPR` and `unset NAME` surface syntax --
  R229.M3+ lands the REPL dispatch that reads a line_buf, drives
  the HM typecheck + evaluator, and calls `_se_insert_binding` /
  `_se_unset_binding` at the right points.
* Cross-session scope (shared / exported bindings) -- R229.M4+.
* Rename / shadow semantics beyond last-wins -- a `let x = 1; let
  x = 2` collapses to the second binding at M2; a lexically-scoped
  shadow (nested lambdas, let-rec) is R229.M5+.
* Full type-scheme storage (bodies with bound vars) -- M2 stores
  a single pool-reference per binding (`scheme_kind = 1`, direct
  TyVar / TyCon / TyApp pool index); a quantified `forall a. a ->
  a` scheme belongs in a schemes blob and arrives at R229.M3+
  with `scheme_kind = 2`.

## 3 Row layout -- 32 bytes per binding

```
  [+0]   kind         (u8)   SE_SLOT_EMPTY (0) or SE_SLOT_ACTIVE (1)
  [+1]   name_len     (u8)   1..SE_NAME_MAX (= 16); 0 on tombstone
  [+2]   scheme_kind  (u8)   SE_SCHEME_DIRECT (1) iff type_ref is a
                             HmCore pool_idx. Reserved 2 = SCHEME_BLOB
                             (M3+ full generalised schemes).
  [+3]   flags        (u8)   reserved; 0 at M2. M3+ reserves bit 0 for
                             "exported across sessions" and bit 1 for
                             "immutable (set-once)".
  [+4]   type_ref     (u32)  interpretation per scheme_kind:
                              = 1 -> HmCore _hm_pool index (1..127)
                              = 2 -> offset into a schemes blob [M3+]
  [+8]   name_inline  [u8;16]  bytes 0..name_len; zero-padded past.
  [+24]  value_ref    (u64)  OPAQUE 64-bit handle. The REPL dispatch
                             (R229.M3+) interprets:
                               -- u64 / i64 / bool: inline immediate
                               -- str / path: offset into a session-
                                  local string arena (R229.M4+)
                               -- pipeline / record / lambda: handle
                                  into the evaluator's value arena
                                  (R229.M4+)
                             SessionEnv does not inspect these bits;
                             it stores and returns them verbatim.
```

Total: 32 B (`SE_BINDING_BYTES`).

Stride 32 is a power of two so slot addressing is `shl rN, 5` -- no
2-op `imul r, imm` (`feedback_pdx_encoder_pitfalls`).

### 3.1 Per-session row

```
  slot 0  [0..32)     SE_BINDING_BYTES
  slot 1  [32..64)
  ...
  slot 31 [992..1024)
```

Total per-session: 32 slots x 32 B = 1024 B (`SE_SESSION_ROW_BYTES`).

### 3.2 Pool (8 sessions)

```
  _se_env_pool   [u8; 8192]    @align(8)   8 x 1024 B
  _se_head_table [u8; 64]      @align(8)   8 x u64 (next-free slot per session)
```

Session row base = `_se_env_pool + sid * 1024`.  `sid * 1024` is
`shl r, 10` -- one op.  Head counter for sid = `_se_head_table +
sid * 8` -- `shl r, 3`.

8 sessions matches R127.M1's `_ss_pool` capacity so SessionEnv is
geometrically coupled to shell_session: a session_id valid against
`ss_row_in_use` has a session-env slot and vice versa.  M3+ may lift
the cap to 16 if the shell-session row pool widens.

### 3.3 Capacity rationale

32 bindings per session is the Pareto point against the "20-turn
test" cited in paideia-os#2720: 20 turns with at most one `let` per
turn seats 20 bindings, well under the cap, with headroom for a
typical shell workflow of 5-10 live aliases plus the pipeline
transients.  The 1024-byte row fits in two cache lines (actually one
2-way-associative load pair on T14-G4 at 64 B/line) -- a linear scan
over a session's bindings prefetches cleanly.

A dynamic hash table was rejected: the 32-slot linear scan is
~100 ns worst-case at 3 GHz (32 x ~10 cycle byte compares) and
delivers a scrubbable row (one 128-u64 store on `_se_init_session`)
that a hash table could not match without an allocator reach, which
would wire SessionEnv to the heap substrate (R220.M7) that has not
landed.  R229.M4+ may introduce a secondary index (e.g. a 64-slot
open-addressed name-hash table alongside the linear array) once the
linear scan is proven too hot in practice.

A per-session arena (byte-stream of (name, type_ref, value_ref)
tuples) was rejected: variable-stride rows preclude the `shl r, 10`
addressing that fixed geometry gives, and would push arena-management
code into every lookup.  The 32-byte fixed row is the cheapest shape
that holds the four tagged fields without pointer chasing.

## 4 State semantics

### 4.1 Insert (`let x = expr`)

1. R229.M3+ REPL dispatch parses `let` + ident + `=` + Expr.
2. HM typechecks Expr against the current session env -- the type-
   check reader walks the SessionEnv to resolve free names (see 4.4).
3. Evaluator runs Expr, producing a `value_ref` + a HM pool index
   for the inferred type.
4. REPL dispatch calls `_se_insert_binding(sid, "x", 1,
   SE_SCHEME_DIRECT, type_pool_idx, value_ref)`.
5. SessionEnv scans slots 0..head for an existing name match:
   * HIT: overwrite the slot's scheme_kind, type_ref, value_ref
     (name_inline + name_len + kind stay). "Last-wins" shadow.
   * MISS: if `head < SE_MAX_BINDINGS` (32), write new slot at
     `head`, bump `head`.  Else return `SE_ERR_TOO_MANY`.
6. Return `SE_OK` on success.

### 4.2 Lookup (free-name resolution)

1. R229.M3+ typechecker / evaluator encounters a free name `x`.
2. Calls `_se_lookup_binding(sid, "x", 1, &out_type_ref, &out_val_ref)`.
3. SessionEnv scans slots 0..head for `kind == SE_SLOT_ACTIVE` and
   name-byte-match.
4. HIT: write `type_ref` and `value_ref` through the two out-pointers;
   return `SE_OK`.
5. MISS: return `SE_ERR_NOT_FOUND`.  The caller next falls through to
   the built-in-command namespace (R222 cmd_registry).

Order matters.  Session env takes precedence over built-ins -- a user
who `let ls = ...` shadows the built-in `ls` for THIS session only;
other sessions see the pristine built-in.  (R229.M4+ exports lift
cross-session bindings; the exported-flag bit distinguishes.)

### 4.3 Unset (`unset x`)

1. R229.M3+ REPL dispatch parses `unset` + ident.
2. Calls `_se_unset_binding(sid, "x", 1)`.
3. SessionEnv scans slots 0..head; on a match, writes `kind :=
   SE_SLOT_EMPTY (0)` and `name_len := 0`.  The slot is now a
   tombstone -- a future `let x = ...` MAY reuse it (M2 does NOT
   compact; the append-only `head` only grows).
4. MISS: return `SE_ERR_NOT_FOUND`.

A tombstone counts against the 32-slot cap at M2 -- a session that
does `let x; unset x; let y; unset y; ...` 32 times without reuse
exhausts the slots.  Compaction (reclaim tombstones on insert) is
R229.M3+.

### 4.4 Type-environment threading

The HM typecheck pass (R225.M1 HmCore + R225.M5 cross-context flow)
treats SessionEnv as the OUTERMOST let-env.  Pseudo-code the
R229.M3+ dispatch runs on a `let` turn:

```
  env  := load_session_env(sid)        -- walk slots 0..head,
                                           build an [name, pool_idx]
                                           array
  ty   := _hm_infer_expr(expr_ast, env)-- HM Algorithm W
  val  := _ev_eval_expr(expr_ast, env) -- the evaluator
  _se_insert_binding(sid, name, name_len, SE_SCHEME_DIRECT, ty, val)
```

The `env` walk is cheap: 32 slots * 32 B = one cache line pair, and
HmCore's `_hm_generalise` consumes an env list of pool indices as
its already-defined input format.  The output of inference is the
generalised scheme root pool_idx, which is what SessionEnv stores at
`type_ref`.

The HM pool itself (`_hm_pool` in `hm_core.pdx`) is a SHARED resource
across turns at R229.M2 -- the type_ref SessionEnv stores is a pool
index into the long-lived pool.  R229.M3 will land a pool-reset hook
that retires per-turn transient nodes (TyVars allocated during an
expression inference that did NOT end up bound into the final scheme);
until that lands, M2 accepts the pool growing slot-by-slot across
turns, bounded by the 127-node cap in HmCore.  Any turn that would
overflow the HM pool returns `HM_ERR_POOL_FULL` from the inference
layer; SessionEnv itself is unaware of HM pool state.

## 5 Return band

```
   SE_OK                  = 0
   SE_ERR_BAD_SESSION     = 0x3700
   SE_ERR_BAD_NAME        = 0x3701  -- name_len == 0 or > SE_NAME_MAX
   SE_ERR_TOO_MANY        = 0x3702  -- head == SE_MAX_BINDINGS on insert
   SE_ERR_NOT_FOUND       = 0x3703  -- lookup / unset miss
   SE_ERR_BAD_SCHEME_KIND = 0x3704  -- insert with scheme_kind not in {1, 2}
```

Band audit at landing (2026-10-14):

```
  grep -rE '0x370[0-4]\b' paideia-os/{src,tools,design,tests}
    -> no packed-status hits outside this file,
       tools/user/libpdx-pds-parser/src/session_env.pdx and
       tools/user/libpdx-pds-parser/caps.decl.
```

The 0x3700..0x37FF band sits above R224.M2 (0x3500..0x35FF) and
R225.M2 (0x3600..0x36FF) which land in the same Wave 117 batch.
Grep confirmation is run against the consolidated main branch after
all three arms merge, not against each individual arm's working tree
(the arms are disjoint by construction: 0x35 / 0x36 / 0x37 bands do
not alias).

Slots 0x3705..0x37FF reserved for:

* `SE_ERR_HM_POOL_FULL` (0x3705) -- M3+ when SessionEnv proxies the
  HM inference layer's pool-full and the REPL loop wants a dedicated
  session-env-tier code.
* `SE_ERR_TOMBSTONE_EXHAUSTED` (0x3706) -- M3+ compaction failure.
* `SE_ERR_EXPORTED_IMMUTABLE` (0x3707) -- M4+ cross-session rebind
  of an exported-immutable binding.
* Remainder reserved for R229.M5+.

All five M2 codes fit imm32 with bit 31 clear so `mov rax, imm32`
emits the 7-byte zero-extending form.

## 6 Public API

```
   _se_init() -> ()
   _se_init_session(session_id) -> errno
   _se_insert_binding(session_id, name_ptr, name_len,
                      scheme_kind, type_ref, value_ref) -> errno
   _se_lookup_binding(session_id, name_ptr, name_len,
                      out_type_ref_ptr, out_value_ref_ptr) -> errno
   _se_unset_binding(session_id, name_ptr, name_len) -> errno
```

### 6.1 `_se_init`

Boot hook.  Defensive scrub of `_se_head_table` (8 u64 = 64 B).
`.bss` already zero-inits the pool at real boot; the head-table
scrub covers a chaos-restart re-entry.  Signature `() -> ()` matches
`_rl_init` and `_shell_history_init` one-for-one.

Boot wiring: `src/kernel/boot/kernel_main.pdx`, immediately after
`_rl_init` (R229.M1) and before `_hf_init` (R127.M7).

Pure leaf -- zero pushes, no stack frame, no nested CALL.

### 6.2 `_se_init_session(session_id)`

Attaches / resets a session's env row.  Validates `session_id <
SE_MAX_SESSIONS` (8).  On a valid id:

* zeroes the 1024-byte row at `_se_env_pool + sid * 1024` (128 u64
  stores via a loop),
* writes `_se_head_table[sid] := 0`.

Returns `SE_OK` on success, `SE_ERR_BAD_SESSION` on `sid >= 8`.

The row is scrubbed every call -- a re-init of a live session wipes
every prior binding without consulting R127.M6's teardown cascade.
R229.M4+ may add a non-destructive re-attach that preserves exported
bindings; M2 is the simplest shape.

Pure leaf -- zero pushes, no stack frame, no nested CALL.

### 6.3 `_se_insert_binding(session_id, name_ptr, name_len, scheme_kind, type_ref, value_ref)`

Last-wins insert.  Validates:

* `session_id < 8`                   -> else `SE_ERR_BAD_SESSION`,
* `name_len >= 1 && name_len <= 16`  -> else `SE_ERR_BAD_NAME`,
* `scheme_kind in {1, 2}`            -> else `SE_ERR_BAD_SCHEME_KIND`.

(Byte-class validation of `name_ptr` -- i.e. is it a legal identifier
in `[A-Za-z_][A-Za-z0-9_]*`? -- is the CALLER's job; the parser
upstream of SessionEnv has already enforced the lexer-level class
check at R224.M1 / R221.M4.  SessionEnv treats the name bytes as
opaque.)

Walks slots 0..`_se_head_table[sid]` for a kind-active slot whose
`(name_len, name_inline[0..name_len])` match the input:

* HIT: overwrite `scheme_kind`, `type_ref`, `value_ref` in that slot.
  Return `SE_OK`.  Head counter unchanged.
* MISS: if head < 32, write a new slot at `head`:
  * `kind := SE_SLOT_ACTIVE (1)`,
  * `name_len := input name_len`,
  * `scheme_kind := input scheme_kind`,
  * `flags := 0`,
  * `type_ref := input type_ref`,
  * `name_inline[0..name_len] := input bytes; [name_len..16] := 0`,
  * `value_ref := input value_ref`,
  * `_se_head_table[sid] := head + 1`.
  Return `SE_OK`.
* MISS AND head == 32: return `SE_ERR_TOO_MANY`.

6-push frame (rbx = session_row_base, rbp = head, r12 = slot_cursor,
r13 = name_ptr, r14 = name_len, r15 = scratch); pure leaf; no sub rsp.

### 6.4 `_se_lookup_binding(session_id, name_ptr, name_len, out_type_ref_ptr, out_value_ref_ptr)`

Walks slots 0..head for the first active slot matching
`(name_len, name_inline[0..name_len])`.  On a hit, writes the
slot's `type_ref` u64 (zero-extended from u32) through
`out_type_ref_ptr` and the slot's `value_ref` u64 through
`out_value_ref_ptr`; returns `SE_OK`.  On a miss, returns
`SE_ERR_NOT_FOUND` without touching either out pointer.

Also returns:
* `SE_ERR_BAD_SESSION` on `sid >= 8`,
* `SE_ERR_BAD_NAME` on `name_len == 0 || name_len > 16`.

A caller that only wants the type (typecheck pass, M3+) passes
`out_value_ref_ptr == 0` -- a null pointer -- and the value write
is skipped.  Likewise, a caller that only wants the value (fast
evaluator path, M3+) passes `out_type_ref_ptr == 0`.  The two
pointers are independent; neither write happens on an error return.

(The convention "0 = skip" is identical to the kernel-side pattern
used by R127.M4 `_shell_history_scan`.)

6-push frame, pure leaf; no sub rsp.

### 6.5 `_se_unset_binding(session_id, name_ptr, name_len)`

Scans slots 0..head for a match; on a hit, writes
`kind := SE_SLOT_EMPTY (0)` and `name_len := 0`.  type_ref and
value_ref are LEFT INTACT (`feedback_novel_clean_design`: zero-
cost tombstone -- the caller can tombstone-forward-scan or compact
later; blanking those four words costs ten cycles for no observable
benefit at M2's capacity).  Returns `SE_OK` on hit,
`SE_ERR_NOT_FOUND` on miss, plus the same `BAD_SESSION` / `BAD_NAME`
guards as the other scanners.

6-push frame, pure leaf; no sub rsp.

## 7 Interaction with R127, R225, R229.M1

### 7.1 R127.M1 shell_session

The session row (R127.M1 `_ss_pool`) holds the session identity
(pid, tty_fd, cap_env, state ordinal, name).  SessionEnv holds the
per-session binding table.  Both are indexed by the same session_id
and sized to the same cap (8 slots).

### 7.2 R127.M6 session teardown

R127.M6's `_shell_session_destroy` cascades through jobs / history /
raw_mode / active_job.  R229.M4+ adds a cascade step 7 that calls
`_se_init_session(sid)` on the session being destroyed -- the init
hook is idempotent and the destructive scrub matches teardown
semantics.  M2 does NOT wire the cascade; the next `_se_init_session`
on sid-reuse scrubs the stale row.

### 7.3 R225.M1 HmCore

SessionEnv stores a HmCore pool index as `type_ref` when
`scheme_kind == SE_SCHEME_DIRECT (1)`.  The HM pool lives in
`hm_core.pdx` module HmCore's `.bss`; it is a sibling module in
the same object graph.  No cross-module dependency is introduced
in the linker sense -- SessionEnv does not call into HmCore; the
REPL dispatch layer (R229.M3+) does, and merely hands the pool_idx
through.

### 7.4 R229.M1 REPL loop

The REPL loop drives per-cycle state; SessionEnv holds per-session
state.  The two are decoupled: a tick in state READING does not
touch SessionEnv; a tick that transitions to PARSED does not touch
SessionEnv either.  Only the EVAL stage (R229.M3+) consults
SessionEnv.

## 8 Encoder discipline (ABSOLUTE)

Labels prefixed `se_` to stay disjoint from `ss_` (shell_session),
`sh_` (shell_history), `sj_` (shell_jobs), `hf_` (history_facts),
`cr_` (cmd_registry), `rl_` (repl_loop), and the parser-tier
`u8n_` / `pl_` / `rp_` / `ll_` / `hm_` / `dl_` / `sch_sig_` /
`cmd_sig_` namespaces.  Reserved paideia-as keyword avoidance
(`loop`, `if`, `let`, `fn`, `ret`, `done`): every label starts with
`se_` so none is a bare keyword.

* `cmp rN, 0` (never `test rN, rN`),
* `shl rN, 10` for session-row base (sid * 1024), `shl rN, 5` for
  slot stride (slot_idx * 32), `shl rN, 3` for head-table (sid * 8)
  -- never 2-op `imul r, imm`,
* `mov rax, imm32` for every return code (bands 0x3700..0x3704 all
  fit imm32 with bit 31 clear) -- never `and r11, imm64`,
* `mov_b [reg + reg*1], reg` for name-byte copy (proven in
  `record_projection.pdx` and `schemas_sig.pdx`),
* single-line `pub let name = "..."` for every constant,
* module basename `SessionEnv` matches file basename
  `session_env.pdx`,
* `.bss` zero-fill via `xor rax, rax; mov [addr + i*8], rax` loop
  over 128 u64 slots (128 iterations = 1024 bytes = one session row),
* cross-module `.bss` writes NOT used -- SessionEnv's `.bss` is
  private to this module.

Stack discipline (SysV, entry `rsp%16==8`):

```
   _se_init                   0 pushes  (pure leaf; small; caller-save only)
   _se_init_session           0 pushes  (pure leaf; caller-save only)
   _se_insert_binding         6 pushes  (rbx, rbp, r12, r13, r14, r15)
   _se_lookup_binding         6 pushes  (same)
   _se_unset_binding          6 pushes  (same)
```

The three scanners use 6 callee-save pushes with NO additional `sub
rsp` -- the frames are pure leaves (no nested CALL) so stack-align-
at-call is a non-concern; `ret` pops `rip` cleanly off a 48-byte-
pushed frame.  (R229.M3+ may convert the scanners to nested-call
shapes once the REPL dispatch layer calls them in a composed way;
at that point an 8-byte align pad adds in.)

## 9 Fingerprint matrix

```
   SESSION_ENV INIT OK               boot        _se_init
   SESSION_ENV INIT_SESSION OK       per-sid     _se_init_session
   SESSION_ENV INSERT OK             per-let     _se_insert_binding success
   SESSION_ENV LOOKUP OK             per-ref     _se_lookup_binding hit
   SESSION_ENV UNSET OK              per-unset   _se_unset_binding hit
```

M2 does NOT emit fingerprints on error paths -- the error enum alone
is the structured observation point; a REJ fingerprint per-call would
flood the klog when a shell free-name walks through the lookup-miss
path on its way to the built-in-command namespace.  R229.M4+ may add
`SESSION_ENV INSERT_FULL` on `SE_ERR_TOO_MANY` since that is a hard
cap event worth logging.

Allowlist at landing: all five `OK` tags unreachable from a
production path because no caller drives SessionEnv at M2 (the REPL
dispatch that would call these lands at R229.M3+).  Entries retire
when R229.M3 lands with an asserting smoke-mode golden over a 20-
turn `let` / `unset` / lookup trace.

## 10 Verification posture

M2 has no asserting smoke-mode golden.  The five OK fingerprints
are allowlisted upstream in `tools/verify-fingerprint-coverage.sh`
with reasons that cite R229.M3 as the retire condition.

R229.M3 (REPL dispatch) will land one smoke mode
(`smoke/session-env-m3.golden.txt`) that:

1. runs `_se_init_session(0)` after boot,
2. inserts `_se_insert_binding(0, "x", 1, 1, type_ref=5, value_ref=42)`
   and asserts `INSERT OK`,
3. looks up `_se_lookup_binding(0, "x", 1, &out_ty, &out_val)`
   and asserts `LOOKUP OK` + `(out_ty, out_val) == (5, 42)`,
4. re-inserts `_se_insert_binding(0, "x", 1, 1, type_ref=5, value_ref=99)`
   (last-wins) and re-looks-up, asserting `out_val == 99`,
5. unsets `_se_unset_binding(0, "x", 1)` and asserts `UNSET OK`,
6. looks up `_se_lookup_binding(0, "x", 1, ...)` and asserts
   `SE_ERR_NOT_FOUND`,
7. iterates steps 2+3 twenty times with distinct names
   (`x0`..`x19`) to validate the 20-turn test from paideia-os#2720,
   asserting each `LOOKUP OK` and that the final head counter == 20.

At that point all five M2 allowlist entries retire.  M2's job is
ONLY to land the substrate so the row shape and status band stay
pinned across the M3+ landings.

## 11 Forward path

* R229.M3  REPL dispatch -- the layer that reads line_buf (R229.M1),
  parses `let NAME = EXPR` / `unset NAME`, runs HM typecheck +
  evaluator, calls these entry points.  Adds the schemes-blob slot
  (`scheme_kind = 2`) for quantified schemes.
* R229.M4  Session teardown cascade step 7 -- wire
  `_shell_session_destroy` to `_se_init_session`.
* R229.M4+ Secondary hash index + tombstone compaction.
* R229.M4+ Cross-session exported bindings (`flags` bit 0).
* R229.M5+ Lexical nested scopes (lambda, let-rec).
* R229.M6+ Persistent per-user env (survives session close) --
  layered via a serialisation hook into the pdxfs user profile.

## 12 Upstream

* paideia-os#2493 (R229 REPL evaluator umbrella).
* paideia-os#2720 (THIS ticket, R229.M2 Session-scoped bindings).
* paideia-os#2719 (R229.M1 REPL loop state machine, substrate).
* paideia-os#2682 (R225.M1 HM core, the type-pool substrate).
