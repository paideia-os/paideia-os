# HM Algorithm W Core — R225.M1

**Issue:** paideia-os#2682  
**Umbrella:** R225 (unified HM typechecker across pipeline / lambda / Datalog, paideia-os#2489)  
**Satellite:** `tools/user/libpdx-pds-parser` (user-space; `src/hm_core.pdx`)  
**Upstream substrate:** none (self-contained; the pool and scratch
regions are singleton `.bss`)  
**Status at this landing:** M1 lands the Damas–Milner 1982 kernel
(unification + occurs-check + instantiation + generalisation) over a
reduced type grammar (nullary + binary type constructors). M2+ layer
row types, Datalog predicate types, effect rows, rank-restriction, and
error-span attribution on top of the same pool.

---

## 1 · Scope and motivation

The semantic-shell plan
(`design/terminal/semantic-shell-language-plan.md` §R225) specifies a
**single unified Hindley–Milner inferencer** that types all three
sub-languages the shell exposes:

- the **pipeline** sub-language, where every stage reads and writes
  typed records with named fields;
- the **lambda** sub-language (`\x. e`), where closures carry an
  effect row (`!{mem, …} @{cap, …}`);
- the **Datalog** sub-language, where predicate arities and term types
  are drawn from the kernel schema registry.

M1 is the "pure Damas–Milner kernel" that all three sub-languages
share. It implements four primitives:

- `_hm_fresh_var()` mints a new type variable with a unique id;
- `_hm_unify(a, b)` is Robinson unification over the type graph,
  with an occurs-check;
- `_hm_instantiate(scheme, out_idx)` fresh-instantiates a universally
  quantified type scheme into the pool;
- `_hm_generalise(ty, env, out_scheme)` lifts a monotype to a scheme,
  quantifying over free vars that do **not** appear in the current
  environment.

Row types, pipeline-record shapes, effect-row inference, span
attribution, and the full typecheck pipeline are deliberately
deferred to R225.M2–M10. This milestone is the *substrate* those
later milestones layer over; its ABI is frozen now so the layered
constructions can land independently.

The implementation lives user-space because the shell itself runs in
user space. The pool is a singleton `.bss` region of 2 KiB (128
`TypeNode` slots) plus 512 B of scratch; a single REPL turn's type
work fits comfortably in that budget. (A long-running session may
retire the pool between turns via a scoped reset hook — R229.M3.)

---

## 2 · Type grammar

### 2.1 Monotypes

M1's monotype grammar is the smallest set that admits the pure lambda
subset of Damas–Milner:

```
τ ::= α                  (TyVar)
    | C                  (TyCon,  nullary, arity = 0)
    | C(τ, τ)            (TyCon,  binary,  arity = 2) via TyApp
```

- A **type variable** `α` carries a `var_id` (a monotonically-minted
  u32) and a *resolved* field. Unresolved means `resolved = 0`;
  resolved means `resolved` holds a pool index into some other node,
  which the `_hm_find` walk follows transitively.
- A **nullary type constructor** `C` names a ground type: `u64`,
  `i64`, `str`, `bool`, `path`, `pid`.
- A **binary type constructor** `C(τ₁, τ₂)` names an application. M1
  defines two: `fn` (function type `A → B`) and `tuple` (`A × B`).
  Higher-arity tuples nest TyApp: `tuple(A, tuple(B, C))`.

The three "node kinds" (`TyVar`, `TyCon`, `TyApp`) collectively form
the type graph in the pool. A function type `A → B` is modelled as
`TyApp(TyApp(TyCon(fn), A), B)` — curry-encoded so every TyApp arm is
binary and the unification algorithm reuses the generic TyApp code
path.

### 2.2 Type-constructor registry

M1 defines eight `HM_CON_*` codes:

| Name  | Code | Arity | Semantics                       |
|-------|------|-------|---------------------------------|
| u64   | 1    | 0     | unsigned 64-bit integer         |
| i64   | 2    | 0     | signed 64-bit integer           |
| str   | 3    | 0     | UTF-8 string (opaque at M1)     |
| bool  | 4    | 0     | boolean                          |
| path  | 5    | 0     | filesystem / Datalog path        |
| pid   | 6    | 0     | process identifier               |
| fn    | 7    | 2     | function type, `fn(arg, ret)`    |
| tuple | 8    | 2     | pair; k-ary via nesting (M2+)    |

The low codes 1–6 intentionally share integer slots with
`SchemasSig::SS_TYPE_*` (R222.M1) at the ground level, so a future
R225.M3 schema bridge can transfer field type codes through a thin
1:1 remap without a widen pass. The two naming spaces are otherwise
disjoint: no byte position collides.

### 2.3 Type schemes

A **scheme** is a universally quantified monotype:

```
σ ::= ∀α₁ … αₙ. τ
```

Schemes are the output of `_hm_generalise` and the input to
`_hm_instantiate`. M1 serialises them as a flat byte stream so the
caller can keep schemes in its own buffer (per-session env, per-let
binding scratch, …) without touching the HM pool directly:

```
scheme bytes:
  [+0]   u32  n_bound_vars        (count of ∀-quantified vars)
  [+4]   u32  n_body_nodes        (count of body nodes; ≥ 1)
  [+8]   u32[n_bound_vars]        bound_var_ids   (ascending)
  [+8 + 4·n_bound_vars]
         TypeNode[n_body_nodes]   body            (16-byte stride)
```

`body[0]` is the scheme root. TyApp body nodes carry
**body-relative** indices in `arg0/arg1` (0..n_body_nodes-1), so a
scheme is position-independent and can be freely copied between
buffers. TyVar body nodes distinguish two cases via a flag:

- **Bound** (`HM_VARFLAG_EXTERNAL = 0`): `arg0` holds a `var_id`
  listed in `bound_var_ids`; on instantiation the body node becomes a
  fresh TyVar with a new `var_id` minted at that moment.
- **External** (`HM_VARFLAG_EXTERNAL = 1`): `arg0` holds a live-pool
  `pool_idx`; on instantiation the body node becomes a TyVar whose
  `resolved` field points at that pool node, so the external
  identity (an env-tracked variable, say) is preserved verbatim and
  further unification runs through the same union-find root.

The external-ref form is the Damas–Milner "free variable in the
scheme" case: a free TyVar in τ that is **also** in the type
environment is not quantified by generalise, so instantiations of
different sites that mention it must still unify as the same
variable.

---

## 3 · Pool and scratch representation

### 3.1 Pool layout (singleton `.bss`)

The pool is 2 KiB of `.bss` holding 128 fixed-size `TypeNode` slots.
Pool index `0` is reserved as the "null" sentinel so a TyVar's
`resolved = 0` can unambiguously mean "unresolved" without aliasing a
valid pool slot. Valid indices are therefore 1..127 (127 usable
nodes). The next-free counter `_hm_pool_next` lazy-initialises to 1
on the first allocation (`.bss` is zero-initialised at load time, so
"never allocated" and "pool empty" are the same observed state).

Each `TypeNode` is 16 bytes:

```
offset | size | field    | content
-------+------+----------+---------------------------------------------
+0     | u8   | kind     | 1 = TyVar, 2 = TyCon, 3 = TyApp (0 = unused)
+1     | u8   | arity    | TyCon declared arity; TyApp = 2; TyVar = 0
+2     | u8   | depth    | occurs-check short-circuit hint (0 at mint)
+3     | u8   | flags    | TyVar bit 0 = HM_VARFLAG_EXTERNAL (scheme-only)
+4     | u32  | arg0     | TyVar: var_id; TyCon: con_id;
       |      |          | TyApp: left pool_idx
+8     | u32  | arg1     | TyApp: right pool_idx; 0 for TyVar/TyCon
+12    | u32  | resolved | TyVar: 0 (unresolved) OR pool_idx of
       |      |          | substitution target; 0 for TyCon/TyApp
```

Stride 16 means node-address arithmetic is `shl idx, 4; add base`
(never 2-op `imul r, imm`, per the paideia-as encoder pitfalls memo).
`.bss` zero-initialisation means every slot starts with
`kind = HM_KIND_UNUSED = 0`, so a stray read of an unallocated node
is detectable rather than silently indistinguishable from a TyVar
whose var_id and resolved happen to be zero.

### 3.2 Scratch table (512 B)

`_hm_subst_table` is 512 B used as role-specific scratch per entry
point. Role usage is **disjoint across concurrent callers** because
no M1 call path is re-entrant (user-space, single-threaded shell;
`_hm_unify` and `_hm_occurs` recurse via the C stack, not the
scratch).

| Caller            | Range (bytes) | Shape                              |
|-------------------|---------------|------------------------------------|
| `_hm_instantiate` | 0..512        | bound-var map: `u64` per bound var, up to 64 entries. For bound-var slot `j`, `scratch[j*8 ..  j*8+8)` holds the fresh var_id minted for that generalised variable. |
| `_hm_generalise`  | 0..256        | pool→body map: `u16` per pool slot (128 entries). Sentinel `0xFFFF` = unvisited. |
| `_hm_generalise`  | 256..512      | env-var list: `u32` per entry, up to 64 entries. Lists the TyVar var_ids reachable through the env roots. |

### 3.3 Var-id counter

`_hm_var_next` is a u64 `.bss` slot holding the next var_id to mint.
It starts at 0 (`.bss` zero-init) and increments monotonically; no
reuse within a process. `_hm_fresh_var` reads it, writes a TyVar
node with `arg0 = var_id`, and bumps the counter. `_hm_instantiate`
likewise bumps by `n_bound_vars` once per instantiation and uses the
pre-bump base + offset `j` as fresh ids.

---

## 4 · Algorithms

### 4.1 `_hm_find`

Standard union-find root walk: given a pool index, follow the
`resolved` chain while the current node is a TyVar whose `resolved`
is non-zero. The implementation is a flat iterative loop — no
path-compression write-back in M1 (reads are cheap; the pool is at
most 127 nodes, so chain length is bounded by 127 in the pathological
case). Path compression is a trivially-added M2 optimisation if the
property harness (R225.M9) reports hot paths.

```
find(idx):
  loop:
    node = pool[idx]
    if node.kind ≠ TyVar: return idx
    if node.resolved == 0: return idx
    idx := node.resolved
```

### 4.2 `_hm_occurs`

Recursive DFS asking "does `var_idx` appear anywhere in the type
reachable from `root_idx` (after find)?". Called from `_hm_unify`
*before* binding a TyVar, so a cyclic unification like `α = α → β` is
caught before the pool graph grows a cycle.

```
occurs(var_idx, root_idx):
  cur = find(root_idx)
  if cur == var_idx: return true
  switch pool[cur].kind:
    TyVar, TyCon: return false
    TyApp:        return occurs(var_idx, cur.arg0)
                      || occurs(var_idx, cur.arg1)
```

Max recursion depth is bounded by pool size (127). Each frame is 7
pushes + 8-byte align slot = 56 B, so worst-case stack usage is
≈ 7 KiB — well within the user-space default stack budget.

### 4.3 `_hm_unify` (Robinson 1965 / Damas–Milner 1982)

```
unify(a, b):
  a := find(a); b := find(b)
  if a == b: return OK
  if kind(a) == TyVar:
    if occurs(a, b): return OCCURS
    pool[a].resolved := b
    return OK
  if kind(b) == TyVar:
    if occurs(b, a): return OCCURS
    pool[b].resolved := a
    return OK
  if kind(a) ≠ kind(b): return MISMATCH
  if kind(a) == TyCon:
    if con_id(a) ≠ con_id(b)  or  arity(a) ≠ arity(b):
      return MISMATCH
    return OK                       # nullary; nothing to recurse on
  # Both are TyApp.
  err := unify(pool[a].arg0, pool[b].arg0)
  if err ≠ 0: return err
  return unify(pool[a].arg1, pool[b].arg1)
```

Short-circuit identity (`a == b`) and the occurs-check are the only
expensive-feeling steps; both are O(size of type) and both are
hitting the same 2 KiB pool so cache behaviour is excellent. The
"union-by-rank" refinement from classical union-find is not applied
in M1 — pool size is too small for the saving to show up in a
property harness, and the implementation complexity isn't justified.

### 4.4 `_hm_instantiate`

Given a scheme σ = ∀α₁ … αₙ. τ, make a fresh copy of τ in the pool
with each αᵢ replaced by a fresh TyVar:

```
instantiate(scheme, out_idx_ptr):
  validate scheme header (lengths, bounds)
  pool-cap gate (pool_next + n_body_nodes ≤ 128)
  mint n_bound_vars fresh var_ids into scratch
  allocate n_body_nodes contiguous pool slots at pool_base
  for i in 0..n_body_nodes:
    src = body[i]
    dst = pool[pool_base + i]
    switch src.kind:
      TyVar:
        if HM_VARFLAG_EXTERNAL set:
          dst = TyVar(resolved = src.arg0)   # redirect to live pool
        else:
          j = index of src.arg0 in bound_var_ids
          dst = TyVar(var_id = scratch[j], resolved = 0)
      TyCon:
        dst = TyCon(con_id = src.arg0, arity = src.arity)
      TyApp:
        dst = TyApp(left  = pool_base + src.arg0,
                    right = pool_base + src.arg1)
  *out_idx_ptr := pool_base
  return OK
```

The body copy is linear in `n_body_nodes`. Fresh var minting is a
single bump of `_hm_var_next` by `n_bound_vars` rather than n
individual increments — amortised bookkeeping.

### 4.5 `_hm_generalise`

Given a monotype τ (pool index) and the current type environment
(a list of pool indices held by the caller's bindings), compute the
set of free TyVars of τ, subtract those that appear in env, and emit
a scheme whose bound set is the difference.

M1's implementation is a four-pass sweep over the pool:

1. **Pool→body map.** Mark `find(root)` with body_idx 0. Fixed-point
   sweep: for each visited TyApp, assign body_idx to its (find'd)
   children; also mark intermediate TyVar nodes whose find root is
   visited as aliases to the same body_idx. Repeat until no changes.
   Fixed-point convergence is bounded by pool depth, which is
   bounded by pool size (127) — O(n²) worst case, trivially fast.
2. **Env-var enumeration.** For each env entry, `find` its root and,
   if that root is a TyVar, append its `var_id` to the env-var list
   in scratch[256..512). M1's env-closure is restricted to the find
   roots directly (not the full transitive closure through env TyApps);
   this is a *conservative* under-approximation of the environment's
   free-var set — it may let through more quantifiers than are
   strictly safe for principal types. R225.M4 widens this to the
   full transitive closure once effect-row vars force the issue
   (the design `semantic-shell-language-plan.md` R225 M4 row calls
   this out explicitly).
3. **Scan + capacity gate.** Walk pool_idx 1..pool_next, counting
   bound TyVars (visited roots whose var_id is NOT in env-vars). As
   we count, stream the bound var_ids directly into the output
   buffer at offset 8. If the running total of required bytes
   exceeds `out_cap`, abort with `HM_ERR_OUT_TOO_SMALL`.
4. **Body emission.** For each visited pool root (unique), emit a
   body node at `body_base + body_idx * 16`:
   - TyVar in env: `HM_VARFLAG_EXTERNAL`, `arg0 = pool_idx`.
   - TyVar not in env (bound): flags = 0, `arg0 = var_id`.
   - TyCon: copy `con_id` + `arity`.
   - TyApp: translate child pool indices to body-relative indices
     via the pool→body map.

The DFS pre-order of pass 1 makes body[0] the scheme root — stable
across repeat calls with the same type graph. This is the property
R225.M9's harness exercises directly.

---

## 5 · Status codes

Reserved error band `0x2D00..0x2DFF` (R225 typechecker; see
`caps.decl` "Error band 0x2D00..0x2DFF" section):

| Name                   | Code    | Returned by                                           |
|------------------------|---------|-------------------------------------------------------|
| `HM_OK`                | 0       | all entry points on success                           |
| `HM_ERR_OCCURS`        | 0x2D00  | `_hm_unify` on cyclic unification                     |
| `HM_ERR_MISMATCH`      | 0x2D01  | `_hm_unify` on con/arity mismatch; also `_hm_instantiate` on malformed scheme (bad var-id, out-of-range body idx, unknown kind); also `_hm_generalise` on invalid env entry |
| `HM_ERR_POOL_FULL`     | 0x2D02  | `_hm_fresh_var` (via return `0`), `_hm_instantiate`   |
| `HM_ERR_OUT_TOO_SMALL` | 0x2D03  | `_hm_instantiate` (scheme header inconsistent), `_hm_generalise` (output buffer too small) |

Slots `0x2D04..0x2DFF` are reserved for R225.M2+ (row-type
mismatches, effect-row saturation, rank-2 refusal, missing predicate
schema, etc.).

The band is disjoint from every other user-space packed-status
range: `caps.decl` prints the full disjointness proof and the
`grep -rE '0x2D0[0-3]'` confirmation line.

---

## 6 · Interaction with the broader umbrella

- **R221 parser-tier Unicode (`utf8_nfc.pdx`, `lexer.pdx`).** The HM
  pool is downstream of the lexer — a type-check pipeline reads AST
  nodes from R221.M5's arena allocator and constructs HM TypeNodes
  via R225.M1 primitives. The two libraries do not touch each
  other's buffers.
- **R222 cmd-functor (`schemas_sig.pdx`).** The eight M1 TyCon codes
  share the low six integers with `SS_TYPE_*`. R225.M3 (Datalog
  predicate types) will bridge SchemasSig field descriptor arrays
  into HmCore types via a 1:1 remap table.
- **R223 pipeline-lang (`pipeline.pdx`).** The HM pool represents
  pipeline-stage types once R225.M2 lands row types; M1 is the
  substrate but does not itself hold pipeline shapes.
- **R224 lambda-lang (`lambda_lit.pdx`).** The HM pool represents
  lambda arrow types directly via `HM_CON_FN`. The lambda typer
  (R225.M4) runs over R224's AST and consumes M1's unify + instantiate.
- **R226 Datalog (`datalog.pdx`).** Datalog predicate signatures are
  resolved against the kernel schema registry (`schema-registry.md`)
  via R225.M3's bridge; term types then enter the shared HM pool.
- **R227 `.pds` module loading.** The in-arena HM pool is created
  once per module; at module boundary the top-level let-bindings are
  generalised (via `_hm_generalise`) and the scheme bytes are stored
  as the module's exported type environment.
- **R229 REPL evaluator.** The session-scoped type environment
  (R229.M3) threads schemes across turns. Per-turn transient
  TypeNodes are retired via a scoped reset hook (M2+).

---

## 7 · Encoder-pitfall discipline

Enforced throughout `src/hm_core.pdx`:

- **No `test r, r`** — every zero-check is `cmp reg, 0; je/jne`.
- **No `and r, imm64`** — the single flag mask (`HM_VARFLAG_EXTERNAL`)
  is `and r, 1`, an imm8 that trivially fits imm32.
- **No 2-op `imul r, imm`** — node-address arithmetic uses
  `shl r, 4` for 16-byte stride; u32 subscripts use `shl r, 2`; u64
  via `shl r, 3`; u16 via `shl r, 1`.
- **No multiline `pub let = "..."`** — justifications are single-line.
- **Module basename `HmCore` matches `hm_core.pdx`.**
- **Labels prefixed `hm_`** — never collides with the reserved
  `loop`/`if`/`let`/`fn`/`ret` keywords, nor with the other R221/R222/
  R223/R224/R226 parser-tier modules in this library (`u8n_`,
  `sch_sig_`, `pl_`, `ll_`, `dl_`).
- **cmp-imm sign safety.** All immediates compared against are small
  (`0, 1, 2, 3, 4, 8, 16, 64, 128, 256`, error codes `0x2D00..0x2D03`,
  sentinel `0xFFFF`). Every value fits imm32 with bit 31 clear so
  direct `cmp reg, imm32` is sign-extension safe.
- **Sized loads/stores.** Byte loads: `xor r, r; mov_b r, [addr]`.
  u32 loads: `xor r, r; mov_d r, [addr]` (zero-extends per SDM
  Vol.1 §3.4.1.1). u64 loads: plain `mov r, [addr]`. u32 stores:
  `mov_d`. u16 "stores": two `mov_b` writes (low/high byte); u16
  "reads": two `mov_b` + a `shl r, 8; or` fold.
- **Cross-module `.bss` writes** via the `lea r11, [rip + sym];
  mov [r11], rax` idiom (precedent in `audit_record.pdx` and
  `mkfs.pdxfs/refusal.pdx`).
- **Self-recursive calls.** `_hm_unify` and `_hm_occurs` call
  themselves via the symbol table (`call _hm_unify` resolves to the
  same symbol at link time; the paideia-as linker treats same-module
  symbol references identically to cross-module ones).

---

## 8 · Stack-frame accounting

| Function          | Pushes | Scratch   | rsp % 16 at nested CALL |
|-------------------|--------|-----------|-------------------------|
| `_hm_find`        | 0      | 0         | pure leaf (no CALL)     |
| `_hm_fresh_var`   | 0      | 0         | pure leaf (no CALL)     |
| `_hm_occurs`      | 5 × 8  | 0         | 0  (entry 8 + 40 → 0)   |
| `_hm_unify`       | 6 × 8  | +8 (pad)  | 0  (entry 8 + 56 → 0)   |
| `_hm_instantiate` | 6 × 8  | +24 (3)   | 0  (entry 8 + 72 → 0)   |
| `_hm_generalise`  | 6 × 8  | +56 (7)   | 0  (entry 8 + 104 → 0)  |

(For `_hm_occurs`, 5 × 8 = 40 bytes alone gives `rsp % 16 == 0` with
no pad required; the function's own CALLs to `_hm_find` and
self-recursive `_hm_occurs` therefore see an aligned stack. For
`_hm_unify`, 6 × 8 = 48 bytes leaves `rsp % 16 == 8`, so a single
8-byte align pad brings nested CALLs into alignment. The two
larger frames `_hm_instantiate` and `_hm_generalise` fold the pad
into their scratch slot counts (24 = 16 + 8 and 56 = 48 + 8).)

Nested CALL alignment is satisfied for every call site: `_hm_find`
and self-recursive `_hm_unify` / `_hm_occurs` all see `rsp % 16 == 0`.

Max recursion depth: bounded by pool size (127). Worst-case stack:
7 KiB (`_hm_occurs`), 8 KiB (`_hm_unify`) — both well within the
user-space default stack budget.

---

## 9 · Test corpus (R225.M9 harness)

Deferred to R225.M9. The spec at `semantic-shell-language-plan.md`
§R225.M1 calls for a **100-test corpus of Damas–Milner examples**;
the harness landing (M9) will seed that corpus with:

- the twelve canonical Damas–Milner 1982 examples (polymorphic
  identity, `let twice = \f. \x. f (f x) in …`, church-encoded naturals,
  …);
- 24 arrow-type unification cases (success + mismatch);
- 10 occurs-check cases (`α = α → β` and its generalisations);
- 20 instantiate-fresh-copy cases (varying `n_bound_vars`,
  shared-var-id in body);
- 20 generalise-env-filter cases (varying env depth);
- 14 negative cases (pool-full, out-too-small, bad scheme header).

M1 lands only the primitives; the harness exercises them through
the pdx-level FFI once R225.M9 opens.

---

## 10 · Forward path

| Milestone  | Addition                                                                     | Notes                                                                                                               |
|------------|------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------|
| R225.M2    | Pipeline-record row types (Rémy 1992)                                        | Introduces `HM_CON_ROW_*` codes and a row-unification arm that reuses the TyApp branch; no M1 ABI change.           |
| R225.M3    | Datalog predicate types via the schema registry                              | Adds a bridge from `SchemasSig` to `HmCore` through a 1:1 remap table.                                              |
| R225.M4    | Effect-row unification                                                       | Widens the generalise env-closure walk to the full transitive closure.                                              |
| R225.M5    | Cross-context type flow (lambda ↔ pipeline ↔ Datalog)                        | Builds on M2 + M3 + M4; no new primitives.                                                                          |
| R225.M6    | Rank-restricted let-polymorphism                                             | Adds a scheme-depth counter + a rank-2 refusal path in `_hm_generalise`.                                            |
| R225.M7    | Error reporting + source-span attribution                                    | Wraps every `HM_ERR_*` return with a span from the caller's AST; the HM internals stay unchanged.                   |
| R225.M9    | 100-test property harness                                                    | Exercises M1 primitives directly; introduces the per-turn fingerprint.                                              |
| R229.M3    | Session-scoped type-environment threading                                    | Introduces a scoped pool-reset hook so a long REPL session retires per-turn transient nodes.                        |

Every subsequent R225 milestone layers *additively* over M1: no
M1 entry point changes signature; no `HM_ERR_*` code is relocated;
no field offset in `TypeNode` is renumbered. ABI frozen at this
landing.

---

## 11 · Upstream references

- Robinson, J. A. (1965) *A machine-oriented logic based on the
  resolution principle.* JACM 12(1).
- Damas, L. and Milner, R. (1982) *Principal type-schemes for
  functional programs.* POPL '82.
- Rémy, D. (1992) *Projective ML.* Deferred to R225.M2.
- `design/terminal/semantic-shell-language-plan.md` §R225 (the
  umbrella decomposition).
- `design/terminal/semantic-shell.md` §SH-D2 (the type-system
  design decision).
- `tools/paideia-as/CHANGELOG.md` 0.36.31 ff — the paideia-as
  Rust-hosted HM implementation (`paideia-as-shell-hm`), which
  provided the reference semantics for this user-space pdx port.
