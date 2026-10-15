# Type-environment threading (R229.M3)

Issue: paideia-os#2721
Wave:  UMB-W30
Lands: 2026-10-15
Umbrella: paideia-os#2493 (R229 REPL evaluator loop)

## 1 Why

R229.M2 (`src/session_env.pdx`, `design/shell/session-env.md`) landed
the per-session binding store, a 32-slot name map that threads a
u32 `type_ref` across turns. For a MONOMORPHIC binding `let x : u64 =
42` the `type_ref` IS the HmCore pool index (SessionEnv
`scheme_kind = SE_SCHEME_DIRECT = 1`): one slot read reconstructs
the type with no further work.

Three realities force a second substrate:

1. The semantic-shell language has **first-class polymorphism**
   (R224.M1 lambdas + R225.M1 HM Algorithm W). `let id = \x. x` has
   principal type `forall a. a -> a`. HmCore stores types as
   TypeNodes (TyVar / TyCon / TyApp) but carries NO quantifier mark
   on a node -- only the SCHEME wire format (header + bound_var_ids
   + body nodes, read by `_hm_instantiate`) is quantified. The one
   u32 `type_ref` in SessionEnv cannot carry a scheme.

2. **Specialisation cost scales with REPL turn count**. Every use of
   `id` at a monomorphic context forces an `_hm_instantiate` call
   that walks the body, rebases pool indices and mints fresh vars.
   Two uses of `id` at `id : u64 -> u64` on turns N and N+1 would
   repeat identical work -- a REPL that keeps a session alive for
   hundreds of turns pays this cost linearly.

3. **R225.M1's instantiate CANNOT be the storage substrate**: it
   READS a scheme byte stream and WRITES into the HmCore pool. It
   does not retain the scheme bytes after the call, and the pool
   itself is bounded at 128 nodes -- a session that let-binds twenty
   polymorphic functions would exhaust the pool after the first few
   instantiations if each one reserved its own body.

R229.M3 lands the two co-domain pieces that resolve this:

- **Scheme store**: a per-session scheme table keyed by `scheme_id`
  (1..TE_MAX_SCHEMES = 16). The scheme bytes persist across turns.
  SessionEnv marks a polymorphic binding with
  `scheme_kind = SE_SCHEME_BLOB = 2`, and the `type_ref` u32 is the
  TypeEnv scheme_id (not an HmCore pool_idx).

- **Specialisation cache**: a per-session cache row of 64 entries
  keyed by `(scheme_id, type_vec_hash)`. Each entry holds the
  `_hm_instantiate` result (an HmCore pool_idx) so repeat uses of
  the same binding at the same monomorphic context skip the
  instantiation walk entirely.

Design posture (`feedback_novel_clean_design`): a POSIX shell has
exactly one type ("string"), one binding store ("exported
environment variables"), and no concept of specialisation.
Semantic-shell retires all three and splits the resulting
substrate across SessionEnv (name -> opaque u32) and TypeEnv (u32
-> type scheme + cached instantiations). The split is NOT
accidental: it keeps SessionEnv a pure-leaf scanner (no HmCore
dependency; cross-cutting changes to the type system never touch
the binding store), and keeps TypeEnv self-contained around the
one external it DOES need (`_hm_instantiate`).

## 2 Scope

### R229.M3 (this landing)

* Per-session scheme store at `(sid, scheme_id) -> scheme_bytes`.
* Per-session specialisation cache at
  `(sid, scheme_id, type_vec_hash) -> body_type_ref`.
* Public API: `_te_init_session`, `_te_insert_scheme`,
  `_te_specialize`, `_te_evict_scheme`.
* Error band `0x3D00..0x3DFF` (second R229 user-space band after
  SessionEnv's `0x3700..0x37FF`).
* Lives in the parser-tier satellite library
  (`tools/user/libpdx-pds-parser/src/type_env.pdx`) alongside HmCore
  (R225.M1) and SessionEnv (R229.M2) -- the scheme bytes TypeEnv
  stores are read via HmCore's `_hm_instantiate`, so geographic
  co-location keeps the two linked in one object graph.

### Deferred

* Parsing of `let NAME = EXPR : forall ... . TY` surface syntax --
  R229.M3-dispatch (kernel-side) reads a line_buf, calls the HM
  typechecker over the lambda AST, and dispatches into either
  `_se_insert_binding` (monomorphic) or
  `_te_insert_scheme` + `_se_insert_binding` (polymorphic) at the
  right points. The parser-tier library has no line_buf dependency.
* Cache-eviction policy beyond round-robin FIFO -- a session that
  cycles through more than 64 distinct instantiations rotates the
  oldest out. R229.M5+ may swap for LRU once eviction cost is
  observed in a long-running session.
* Scheme-slot compaction -- `_te_evict_scheme` is a tombstone that
  does NOT decrement scheme_count. A session that evicts and
  re-inserts a scheme burns two slot ids; 16 slots per session
  seats the 15-turn test comfortably. Compaction is R229.M5+.
* Cross-session exported schemes -- the `flags` byte in each slot is
  reserved for an "exported" bit at R229.M4; the current call paths
  reject implicit cross-session reads.
* Persisted scheme catalogue over pdxfs -- R229.M6+.

## 3 Scheme-slot layout -- 256 bytes

```
  [+0]   kind         (u8)   TE_SLOT_EMPTY (0) or TE_SLOT_ACTIVE (1)
  [+1]   flags        (u8)   reserved; 0 at M3. M4 reserves bit 0 for
                             "exported across sessions" and bit 1 for
                             "immutable (set-once)".
  [+2]   reserved     (u16)  padding to align scheme_len at +4.
  [+4]   scheme_len   (u32)  1..TE_SCHEME_PAYLOAD_MAX (248).
  [+8]   scheme_body  [u8;248]  HmCore scheme wire format:
                                 u32 n_bound_vars
                                 u32 n_body_nodes
                                 u32[n_bound_vars] bound_var_ids
                                 TypeNode[n_body_nodes] body (16-byte stride)
```

Total: 256 B (`TE_SCHEME_SLOT_BYTES`).

Stride 256 is a power of two so slot addressing is `shl rN, 8` --
never 2-op `imul r, imm` (`feedback_pdx_encoder_pitfalls`).

Scheme payload cap is 248 B = 8 B header + up to ~15 body nodes
(worst case: 0 bound vars + 15 body nodes = 8 + 15*16 = 248), or 8
B header + up to 10 bound vars + ~12 body nodes (8 + 40 + 200 =
248). This comfortably seats the semantic-shell's realistic scheme
shapes (short pipelines of width-2 polymorphic combinators).

### 3.1 Per-session scheme row

```
  slot 0  [0..256)    TE_SCHEME_SLOT_BYTES
  slot 1  [256..512)
  ...
  slot 15 [3840..4096)
```

Total per-session: 16 slots x 256 B = 4096 B
(`TE_SCHEME_ROW_BYTES`).

### 3.2 Scheme pool (8 sessions)

```
  session 0  [0..4096)       TE_SCHEME_ROW_BYTES
  session 1  [4096..8192)
  ...
  session 7  [28672..32768)
```

Total scheme pool: 8 x 4096 = 32768 B (`TE_SCHEME_POOL_BYTES`).

Session base = `_te_scheme_pool + sid * 4096` -- `shl rN, 12`.

## 4 Cache-entry layout -- 16 bytes

```
  [+0]   valid        (u8)   TE_CE_EMPTY (0) or TE_CE_ACTIVE (1)
  [+1]   reserved     (u8[3]) padding to u32 alignment.
  [+4]   scheme_id    (u32)  1..TE_MAX_SCHEMES.
  [+8]   hash         (u32)  caller-supplied type-vector hash
                             (typically FNV-1a 32 over the ordered
                             sequence of HmCore pool indices for the
                             use site's monomorphic argument types;
                             the shell layer picks the hash function).
  [+12]  body_ref     (u32)  HmCore _hm_pool index (1..127) returned
                             by `_hm_instantiate` on the first
                             insertion.
```

Total: 16 B (`TE_CACHE_ENTRY_BYTES`). Stride is a power of two so
addressing is `shl rN, 4`.

### 4.1 Per-session cache row

64 entries x 16 B = 1024 B (`TE_CACHE_ROW_BYTES`). Session base =
`_te_cache_pool + sid * 1024` -- `shl rN, 10`.

### 4.2 Cache pool (8 sessions)

8 x 1024 = 8192 B (`TE_CACHE_POOL_BYTES`).

## 5 Head-table -- 64 bytes

8 sessions x 8 B/row. Per session:

```
  [+0]   scheme_count (u8)   0..TE_MAX_SCHEMES (16). Append cursor
                             (also the first-free slot index at insert).
  [+1]   cache_cursor (u8)   0..TE_MAX_CACHE_ENTRIES (64). Round-
                             robin write index into the cache row on
                             insert.
  [+2]   reserved     (u8[6])
```

Head row base = `_te_head_table + sid * 8` -- `shl rN, 3`.

## 6 State semantics

### 6.1 Insert

`_te_insert_scheme(sid, scheme_body, scheme_len, out_scheme_id)` is
APPEND-ONLY at the session's `scheme_count` cursor. On TE_OK:

- `_te_scheme_pool[sid*4096 + count*256]` becomes an ACTIVE slot
  carrying the caller's scheme bytes.
- `out_scheme_id` receives `count + 1` (1-based; scheme_id 0 is
  reserved as "no scheme").
- `scheme_count` is bumped to `count + 1`.

The counter is NOT compacted on evict. A session that `_te_insert_
scheme` -> `_te_evict_scheme` -> `_te_insert_scheme` burns two
slot IDs: the first id is permanently retired. The 16-slot cap
accommodates up to 16 polymorphic bindings total per session (over
the full session lifetime).

### 6.2 Specialize

`_te_specialize(sid, scheme_id, type_vec_hash, out_body_ref)`:

1. **Cache hit** (fast path): scans the 64 cache entries for
   `(valid == ACTIVE, scheme_id == rsi, hash == rdx32)`. First
   match wins. On hit: `*out_body_ref = cached body_ref` and return
   TE_OK with no `_hm_instantiate` call. Typical hit latency: ~60
   cmp instructions + 1 u32 load.

2. **Cache miss**: resolve scheme slot. If `kind != ACTIVE` return
   TE_ERR_NOT_FOUND. Call `_hm_instantiate(scheme_body, scheme_len,
   &local_body_idx)`. On HM_OK: `*out_body_ref = local_body_idx`,
   insert `(ACTIVE, scheme_id, hash, body_idx)` into the cache at
   `cache_cursor`, bump cursor mod 64. On HM_ERR_*: translate to
   TE_ERR_HM_* and return without caching.

The cache insert at `cache_cursor` overwrites whatever was there,
regardless of its contents (round-robin FIFO). A session that
cycles through more than 64 distinct `(scheme_id, hash)` pairs
rotates the oldest entries out; a session with high repeat hits
and a narrow instantiation range keeps the same entries indefinitely.

### 6.3 Evict

`_te_evict_scheme(sid, scheme_id)`:

1. Scheme slot kind := EMPTY (zero-cost tombstone; scheme bytes
   left intact for potential replay/debug, but no entry point
   reads them past the kind check).
2. Walk all 64 cache entries. For each entry with `scheme_id ==
   rsi`, write `valid := 0`. This is NECESSARY: a future
   `_te_specialize` on the same scheme_id would hit the stale
   cache entry and return a body_ref that may now point into a
   recycled HmCore pool region.
3. `scheme_count` is NOT decremented.

### 6.4 Init session

`_te_init_session(sid)`:

- Zero the per-session scheme row (4096 B / 512 u64 stores).
- Zero the per-session cache row (1024 B / 128 u64 stores).
- Zero the per-session head row (8 B / 1 u64 store).

Idempotent -- repeated calls on the same sid are safe. The REPL
loop at R229.M4+ wires `_te_init_session` into the session create
cascade (step N+1 after `_se_init_session`), and into the destroy
cascade (same relative position).

## 7 Interaction with SessionEnv

The REPL dispatch at R229.M3-dispatch (kernel-side, not landed in
THIS library) is where the two parser-tier primitives weave
together on a `let x = EXPR` cycle. Pseudo-code:

```
on `let x = EXPR` at (sid, N):
    parse EXPR -> AST
    type_check AST -> ty_idx + env_free_vars
    if is_polymorphic(ty_idx, env_free_vars):
        # Emit a scheme (R225.M1 _hm_generalise).
        _hm_generalise(ty_idx, env_ptr, env_len, scheme_buf, scheme_cap)
        # Install in TypeEnv.
        _te_insert_scheme(sid, scheme_buf, scheme_len, &scheme_id)
        # Install in SessionEnv with scheme_kind = SE_SCHEME_BLOB.
        _se_insert_binding(sid, "x", 1, 2 /*SE_SCHEME_BLOB*/,
                           scheme_id /*type_ref*/, value_ref)
    else:
        _se_insert_binding(sid, "x", 1, 1 /*SE_SCHEME_DIRECT*/,
                           ty_idx /*type_ref*/, value_ref)

on `unset x` at (sid, N):
    _se_lookup_binding(sid, "x", 1, &type_ref, &value_ref)  # read first
    # If polymorphic, evict the scheme + cache before unsetting the name.
    scheme_kind = read scheme_kind byte from the Binding record
    if scheme_kind == SE_SCHEME_BLOB:
        _te_evict_scheme(sid, type_ref)
    _se_unset_binding(sid, "x", 1)

on use of free name `x` in an expression at (sid, N+k):
    _se_lookup_binding(sid, "x", 1, &type_ref, &value_ref)
    scheme_kind = read scheme_kind byte from the Binding record
    if scheme_kind == SE_SCHEME_DIRECT:
        # Monomorphic: type_ref IS the HmCore pool_idx.
        body_type = type_ref
    else:  # SE_SCHEME_BLOB
        hash = fnv1a32(use_site_argument_types)
        _te_specialize(sid, type_ref, hash, &body_type)
    # Proceed with HM unification using body_type.
```

The dispatch layer OWNS the hash function. TypeEnv treats the hash
as an opaque u32 identity key; a shell layer that wants different
cache granularity (e.g. coarser hash to force more sharing, or
finer hash including effect rows) can swap the hash computation
without changing TypeEnv.

## 8 Return-band disjointness

The TypeEnv band `0x3D00..0x3DFF` sits disjoint from every other
packed-status range in the paideia-os tree:

* `0x2700..0x27FF` -- utf8_nfc (R221.M1)
* `0x2A00..0x2AFF` -- schemas_sig (R222.M1)
* `0x2B00..0x2BFF` -- pipeline (R223.M1)
* `0x2C00..0x2CFF` -- lambda_lit (R224.M1)
* `0x2D00..0x2DFF` -- hm_core (R225.M1) -- the four codes
                      `0x2D00/0x2D01/0x2D02/0x2D03` are what
                      `_te_specialize` translates to TE_ERR_HM_*.
* `0x2E00..0x2EFF` -- datalog (R226.M1)
* `0x3000..0x30FF` -- repl_loop (R229.M1, kernel-side RL_*)
* `0x3300..0x33FF` -- command_sig (R222.M2)
* `0x3400..0x34FF` -- record_projection (R223.M2)
* `0x3500..0x35FF` -- closure_capture (R224.M2)
* `0x3600..0x36FF` -- row_types (R225.M2)
* `0x3700..0x37FF` -- session_env (R229.M2)
* `0x3800..0x38FF` -- grapheme_iter (R221.M2)
* `0x3900..0x39FF` -- functor_instance (R222.M3)
* `0x3A00..0x3BFF` -- R133.M3 / M4 kernel-side (import graph +
                      resolution cache)
* `0x3C00..0x3CFF` -- R222.M4 ArgSpec (reserved)
* `0x3D00..0x3DFF` -- **type_env** (R229.M3, THIS)

Grep confirmation at landing time:

```
grep -rE '0x3D0[0-8]\b' paideia-os/{src,tools,design,tests}
  -> no packed-status hits outside tools/user/libpdx-pds-parser/
     src/type_env.pdx + tools/user/libpdx-pds-parser/caps.decl +
     design/shell/type-env-threading.md.
```

## 9 Stack discipline

| Function              | Pushes       | Scratch    | rsp%16 at nested CALL      |
|-----------------------|--------------|------------|----------------------------|
| `_te_init_session`    | 0            | 0          | pure leaf (no CALL)        |
| `_te_insert_scheme`   | 6 x 8        | 0          | pure leaf (no CALL)        |
| `_te_specialize`      | 6 x 8        | 1 x 8      | 0 at `_hm_instantiate` CALL|
| `_te_evict_scheme`    | 6 x 8        | 0          | pure leaf (no CALL)        |

The pure-leaf scanners omit the usual `sub rsp, 8` align pad
because they make no nested CALLs; the 6-push shape leaves rsp
balanced at `ret`.

`_te_specialize` adds `sub rsp, 8` -- one 8-byte local for the
`body_idx` u64 slot passed to `_hm_instantiate`, AND the 8-byte
pad brings rsp%16==0 at the nested CALL (entry rsp%16==8; 6 pushes
= 48 B leave %16==8; `sub rsp, 8` brings %16==0).

Register-liveness: r11 is caller-save under SysV, so the nested
CALL to `_hm_instantiate` clobbers whatever `lea r11, [rip + sym]`
pattern we loaded pre-CALL. The post-CALL cache-insert path
reloads `_te_cache_pool` and `_te_head_table` via fresh `lea` --
NOT via a stashed r11 (`feedback_pdx_encoder_pitfalls` register-
liveness audit, Wave 118 lesson).

## 10 Encoder posture

- G1 -- u32 stores via `mov_d`; u8 stores via `mov_b`; u64 stores
  via plain `mov`; u32 loads via `xor + mov_d`; byte loads via
  `xor + mov_b`.
- Row addressing -- `shl r, 12` (scheme session base) / `shl r, 10`
  (cache session base) / `shl r, 8` (scheme slot stride) /
  `shl r, 4` (cache entry stride) / `shl r, 3` (head-table).
  Never `imul r, imm`.
- u32 masking of a u64 register for `cmp` or `mov_d` writeback uses
  `shl r, 32; shr r, 32` (same pattern row_types `_rt_label_hash`
  uses to force a 32-bit truncation).
- Flag masks -- not required at M3 (flags byte is always 0 and
  the valid byte is binary {0, 1}).
- Reserved labels -- every label prefixed `te_` (disjoint from
  `ss_` / `sh_` / `sj_` / `hf_` / `cr_` / `rl_` kernel namespaces
  and the parser-tier `u8n_` / `pl_` / `rp_` / `ll_` / `cc_` /
  `hm_` / `rt_` / `dl_` / `sch_sig_` / `cmd_sig_` / `se_` / `fi_`
  / `gi_` namespaces). No bare `loop`/`if`/`let`/`fn`/`ret`/`done`.
- `.bss` writes via `lea r11, [rip + sym]; mov [r11 + disp], reg`;
  r11 is reloaded via fresh `lea` after every nested CALL in
  `_te_specialize`.
- Scheme byte-copy -- precomputed destination base in `rsi`
  (`mov rsi, r14; add rsi, 8`) with store form `mov_b [rsi + r10 *
  1], rax` to sidestep the `mov_b [reg + reg + off], reg` encoder
  gap documented in `shell_history.pdx` L440. Loads with the
  three-term form (`mov_b rax, [r12 + r10 * 1]`) are supported per
  `command_sig.pdx` precedent.

## 11 Fingerprint matrix

```
TYPE_ENV INIT_SESSION OK      per-sid     _te_init_session
TYPE_ENV INSERT_SCHEME OK     per-let     _te_insert_scheme hit (append)
TYPE_ENV SPECIALIZE HIT OK    per-ref     _te_specialize cache-hit
TYPE_ENV SPECIALIZE MISS OK   per-ref     _te_specialize cache-miss -> _hm_instantiate -> cache
TYPE_ENV EVICT OK             per-unset   _te_evict_scheme hit
```

M3 does NOT emit fingerprints on error paths (the error enum is
the structured observation point; a REJ fingerprint per-call would
flood klog when a shell free-name walks through the specialize-
miss-then-slot-empty path during normal evaluation). All five OK
tags allowlist to retire at R229.M3-dispatch when the kernel-side
REPL layer lands with asserting smoke-mode goldens.

## 12 Fifteen-turn golden (R229.M3-dispatch pre-requisite)

The acceptance test for paideia-os#2721 is a 15-turn session that
exercises the specialisation cache end-to-end. The sequence (to be
asserted when the kernel-side REPL dispatch lands):

```
turn 01  let id = \x. x                      -- insert scheme (forall a. a -> a)
turn 02  let dup = \x. (x, x)                -- insert scheme (forall a. a -> (a,a))
turn 03  id 42                               -- specialize id at a := u64 (miss)
turn 04  id "hello"                          -- specialize id at a := str (miss)
turn 05  id 42                               -- specialize id at a := u64 (HIT)
turn 06  dup 1                               -- specialize dup at a := u64 (miss)
turn 07  dup "world"                         -- specialize dup at a := str (miss)
turn 08  id 7                                -- specialize id at a := u64 (HIT)
turn 09  dup 7                               -- specialize dup at a := u64 (HIT)
turn 10  let compose = \f. \g. \x. f (g x)   -- insert scheme (forall a b c. ...)
turn 11  compose id id                       -- specialize compose (miss)
turn 12  unset id                            -- evict scheme 1 + 4 cache entries
turn 13  id 42                               -- SessionEnv lookup fails (not re-tested)
turn 14  dup 42                              -- specialize dup at a := u64 (HIT survives)
turn 15  compose id id                       -- SessionEnv lookup of `id` fails
```

Observations the golden MUST assert:

1. After turn 02 scheme_count = 2; after turn 10 scheme_count = 3.
2. After turn 05 the (id, u64-hash) cache entry is HIT (no new
   `_hm_instantiate` call fingerprint; verify via klog gap).
3. After turn 09 the (dup, u64-hash) cache entry is HIT.
4. After turn 12 the TYPE_ENV EVICT fingerprint fires AND the two
   `(id, *)` cache entries are gone (verifiable by observing a
   following `id *` would miss, if it ran).
5. After turn 14 the (dup, u64-hash) cache survives the id-evict.
6. After turn 15 the SessionEnv-side `id` lookup returns
   `SE_ERR_NOT_FOUND` (no stale TypeEnv read).
7. `_hm_pool_next` grows strictly through turns 03/04/06/07/10/11
   (one body per cache miss) and remains flat through 05/08/09/14
   (cache hits do NOT grow the pool).

Observation 7 is the direct witness that memoised specialisations
are being reused -- the whole point of the ticket's acceptance
sentence "specializations correctly reused".

## 13 Forward path

- **R229.M4** -- Session teardown cascade. `_shell_session_destroy`
  (R127.M6) gains a step 7+1 that calls `_te_init_session(sid)` to
  scrub the row before sid-reuse. Exported-scheme flag goes live
  (slot flags bit 0).
- **R229.M5** -- Lexical nested scopes: a stack of SessionEnv rows
  per session; TypeEnv's scheme ids remain session-flat (nested
  scopes do not create fresh schemes, they create fresh name
  shadows pointing at existing schemes). This forward-compatibility
  is baked in by not keying TypeEnv on name.
- **R229.M6** -- Persistent per-user env: scheme bytes written to
  pdxfs at session close; replayed on next login. The scheme wire
  format carried on disk is identical to the in-memory format, so
  no transformation layer is needed.
- **R229.M-dispatch** -- the kernel-side REPL dispatch at
  `src/kernel/core/shell/repl_loop.pdx` (R229.M1's state machine)
  reads a parsed line, calls the HM typechecker (R225.M1), decides
  monomorphic vs polymorphic, and routes into SessionEnv +
  TypeEnv. The dispatch layer is NOT part of this library -- it
  owns the per-turn free-name resolution policy and the hash
  function for type-vector keys.

## 14 Upstream

- paideia-os#2493 (R229 REPL evaluator umbrella)
- paideia-os#2721 (THIS ticket, R229.M3 Type-environment threading)
- paideia-os#2720 (R229.M2 SessionEnv -- substrate below)
- paideia-os#2682 (R225.M1 HmCore -- `_hm_instantiate` target)
- paideia-os#2719 (R229.M1 REPL loop state machine)
- paideia-os#2683 (R225.M2 RowTypes -- future row-polymorphic
  scheme bodies, forward-compatible wire format)

Design-doc neighbours:

- `design/shell/repl-loop-scaffold.md` (R229.M1)
- `design/shell/session-env.md` (R229.M2)
- `design/shell/hm-algorithm-w-core.md` (R225.M1)
- `design/shell/row-types-remy.md` (R225.M2)
