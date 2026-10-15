# Row Types — Rémy-style — R225.M2

**Issue:** paideia-os#2683  
**Umbrella:** R225 (unified HM typechecker across pipeline / lambda / Datalog, paideia-os#2489)  
**Satellite:** `tools/user/libpdx-pds-parser` (user-space; `src/row_types.pdx`)  
**Upstream substrate:** R225.M1 HmCore (`design/shell/hm-algorithm-w-core.md`,
`src/hm_core.pdx` — the shared TypeNode pool and the pure-HM unifier).  
**Status at this landing:** M2 lands the Rémy 1992 row-polymorphism
extension over the HmCore pool: a new `HM_KIND_TYROW = 4` node kind
(three subkinds — ROW_EMPTY, ROW_EXT, ROW_VAR), the field extension
/ restriction / selection / concatenation primitive family, and a
row-aware general unifier that recurses correctly through TyApp
subterms whose children may themselves be rows (notably the `record`
wrapper). R225.M3+ layer additional row shapes (Datalog predicate
types, effect rows) over the same substrate.

---

## 1 · Scope and motivation

The semantic-shell plan
(`design/terminal/semantic-shell-language-plan.md` §R225.M2) specifies
Rémy-style **row polymorphism** for the pipeline sub-language's
record-with-named-fields values: a pipeline stage produces a record
`{a: τ₁, b: τ₂, …}` and downstream stages can read some fields,
project a subset, extend with new fields, or concatenate two records.
The typechecker must assign **principal types** to those operations —
every well-typed program has a most-general type that is unique up
to row-variable renaming.

Rémy's 1992 "Projective ML" formulation keeps the HM core intact
and adds a second kind of type variable (**row variables** `ρ`)
plus a composite **row** type:

```
τ ::= α          (type variable)
    | C          (type constructor)
    | C(τ, τ)    (type application)
    | record(ρ)  (NEW — record wrapper)

ρ ::= ∅                (empty row)
    | ℓ : τ ; ρ'        (row extension)
    | ρ_var             (row variable)
```

R225.M2's job is to materialise this grammar in the HmCore pool
without disturbing M1's frozen ABI. The three primitives Rémy
specifies — **select**, **restrict**, and (implicit via Rémy's row
unification) **extend** — all appear as public entry points, plus a
**concatenation** primitive the shell's record-literal surface
requires.

The implementation lives user-space because the shell itself runs in
user space, alongside the HmCore pool. The pool is **shared** with
hm_core: a row node occupies one 16-byte slot in the same singleton
`_hm_pool` as a TyVar / TyCon / TyApp node, so row operations and
pure HM operations draw from a common 128-slot budget. The
`_rt_alloc_node` helper mirrors `_hm_fresh_var`'s lazy-init +
pool-full discipline byte-for-byte.

---

## 2 · Type grammar extension

### 2.1 Node kind + subkind codes

M1 defined three node kinds: `HM_KIND_TYVAR = 1`, `HM_KIND_TYCON = 2`,
`HM_KIND_TYAPP = 3`. M2 adds a fourth:

```
HM_KIND_TYROW = 4
```

A TyRow node discriminates its row-flavour via the `[+2]` byte (M1
calls this slot `depth` for its own occurs-check short-circuit; it
is zero at all M1 call sites so M2 can safely repurpose it):

| Subkind code | Name           | Semantics                                     |
|--------------|----------------|-----------------------------------------------|
| 0            | `ROW_EMPTY`    | the closed empty row ∅                        |
| 1            | `ROW_EXT`      | an extension `ℓ:τ ; ρ'`                       |
| 2            | `ROW_VAR`      | a row variable `ρ_var`                        |

Future row sub-languages reserve higher subkind codes:

| Code  | Reserved for                                              | Milestone |
|-------|-----------------------------------------------------------|-----------|
| 3     | predicate-arity row (Datalog)                             | R225.M3   |
| 4..7  | effect-row flavours (open-row effect inference)           | R225.M4   |
| 8..15 | capability-row flavours                                   | R225.M4   |

The subkind byte stays below 0x80 so a sign-extended compare against
imm32 is unambiguous.

### 2.2 TyRow node layout (16-byte shared stride)

A TyRow node reuses the exact TypeNode stride M1 defined, so a
mixed-kind pool walk visits row nodes at the same offsets as TyVar /
TyCon / TyApp nodes:

```
offset | size | field    | content
-------+------+----------+---------------------------------------------
+0     | u8   | kind     | 4 (RT_KIND_TYROW)
+1     | u8   | arity    | 0 (EMPTY/VAR) or 2 (EXT)
+2     | u8   | subkind  | 0=EMPTY, 1=EXT, 2=VAR (M2); 3+ reserved
+3     | u8   | flags    | reserved for M4 effect-row annotation
+4     | u32  | arg0     | EXT: label hash (FNV-1a 32)
       |      |          | VAR: var_id (shared with _hm_var_next)
       |      |          | EMPTY: 0
+8     | u32  | arg1     | EXT: field-type pool_idx
       |      |          | VAR: 0
       |      |          | EMPTY: 0
+12    | u32  | arg2     | EXT: rest-row pool_idx
       |      |          | VAR: resolved pool_idx (0 = unresolved)
       |      |          | EMPTY: 0
```

**The +12 slot is shared with hm_core's `HM_OFF_RESOLVED`.** This is
the key design choice that lets `_rt_find` walk a mixed TyVar + ROW_VAR
chain with one implementation: both substitution targets live at the
same byte offset, and both are 0 when unresolved. A TyVar can bind
to a TyRow (hm_core's `_hm_unify` writes `a.resolved := b` without
inspecting `b`'s kind), and a ROW_VAR can bind to a ROW_EXT, both via
the same `mov_d [node + 12], target_idx` idiom.

### 2.3 New type constructor: `record`

M2 adds one TyCon:

```
RT_CON_RECORD = 10, arity 1
```

A record type is:

```
record(ρ) ≡ TyApp(TyCon(RECORD, arity=1), ρ)
```

The `TyApp` wrapper is the standard hm_core unary application form —
left child is the `TyCon(RECORD)`, right child is the row. The
`_rt_row_unify` TyApp arm recurses on both children: it compares the
TyCon identities (match) and then recurses into the row children via
the row-specific arm.

Con_id 9 is left **unassigned** as a deliberate gap between hm_core's
binary range (1..8) and this unary wrapper. R225.M3 may take 9 for a
Datalog-ground-type wrapper if the schema registry's byte alignment
needs it.

### 2.4 Label identity: FNV-1a 32

Row-extension nodes identify their field by a **32-bit label hash**
(FNV-1a, `offset_basis = 0x811C9DC5`, `prime = 0x01000193`).
Rationale:

- **32-bit value fits cleanly into `arg0`** without a two-word pool
  allocation per row-ext node. (FNV-1a 64 — as `command_sig.pdx` uses
  for cap-name identity — would consume all of `arg0`+`arg1`, leaving
  no slot for the field type.)
- **Collisions are negligible per row.** For a 32-field record, the
  birthday-paradox collision probability is < 2.4 × 10⁻⁷. A hash
  collision inside a single row's field set would require the two
  colliding labels to be bytewise distinct AND land at the same 32-bit
  FNV-1a output — vanishingly rare for ASCII identifiers.
- **FNV-1a 32 is the natural truncation of FNV-1a 64**, and both
  compute mod 2^32 (resp. 2^64) with the same byte-fold loop shape.
  `_rt_label_hash` reuses `command_sig.pdx`'s FNV-1a 64 encoder
  pattern with the 32-bit prime and a `shl rax, 32; shr rax, 32`
  truncation after every multiply.
- **The caller can side-check label text** on the rare collision
  (store the original name alongside the hash in a higher-level
  record-descriptor array) — M2 does not force or forbid this; the
  pure parser-tier primitive just preserves the hash.

The `shl / shr` truncation is defensive against the pdx encoder
sign-extending `mov r64, imm32` when `imm32` has bit 31 set (which
`0x811C9DC5` does). Rather than guess the encoder's chosen encoding,
`_rt_label_hash` unconditionally zeros the top 32 bits after each
`mul rcx`.

---

## 3 · Pool and scratch usage

### 3.1 Shared pool

Row nodes live in the **same** `_hm_pool` as hm_core's TypeNode
population. Pool capacity (128 slots, idx 0 reserved) is the shared
budget — a long chain of row extensions competes for pool space with
a long chain of TyApp applications.

`_rt_alloc_node` is a pure-leaf allocator that mirrors `_hm_fresh_var`
byte-for-byte except for the final write (`_rt_alloc_node` zero-fills
the slot and returns; the caller writes kind/subkind/arg0/arg1/arg2
according to the row-flavour it is building). It bumps the shared
`_hm_pool_next` counter.

### 3.2 Scratch slice [384..512)

`_hm_subst_table` is 512 B total; hm_core's R225.M1 landing documents
these existing uses:

| Caller            | Range (bytes) | Shape                                      |
|-------------------|---------------|--------------------------------------------|
| `_hm_instantiate` | 0..512        | bound-var fresh-id map (u64 per entry; 64) |
| `_hm_generalise`  | 0..256        | pool→body u16 map                          |
| `_hm_generalise`  | 256..512      | env-var u32 list                           |

R225.M2 carves a **disjoint** slice at `[384..512)` for the restrict /
concat prefix-field collection:

```
_hm_subst_table[384 + j * 8 .. 384 + j * 8 + 8)
  u32 label_hash
  u32 field_type_idx
```

The slice holds up to `RT_MAX_PREFIX_FIELDS = 10` entries (80 bytes;
48 bytes of tail reserved for M3+ per-entry source-span attribution
once R225.M7 lands). The disjointness holds because:

- `_hm_instantiate` and `_hm_generalise` run during the HM pass over
  the parsed AST.
- `_rt_row_restrict` and `_rt_row_concat` run during row-shape
  rewrites that are part of the HM pass's TyApp recursion (via
  `_rt_row_unify`) **but** they never allocate scheme-scratch during
  the row operation — they consume raw type pool indices only.
- The two scratch regimes are therefore sequentially disjoint within
  one HM pass.

### 3.3 Var-id counter

Row-vars draw from the **same** `_hm_var_next` counter that TyVars
use (`_rt_row_var` reads it, writes the pre-bump value into
`arg0`, bumps). The unified var-id namespace means a scheme-generalise
walk (R225.M1) can enumerate every "free row-var" by the same
mechanism it enumerates "free type-var" — the discriminator is the
owning node's `kind` byte, not the var_id. This is deliberate: a
scheme that quantifies over both a type-var and a row-var is
represented in M1's scheme wire format without a format change.

---

## 4 · Algorithms

### 4.1 `_rt_find`

Standard union-find root walk, extended to recognise ROW_VAR nodes:

```
find(idx):
  loop:
    node = pool[idx]
    if node.kind == TyVar: follow_resolved
    if node.kind == TyRow and node.subkind == ROW_VAR: follow_resolved
    else: return idx
  follow_resolved:
    if node.arg2 == 0: return idx
    idx := node.arg2
```

Path compression is deferred to R225.M9's harness feedback. Max chain
length is bounded by pool size (127).

### 4.2 `_rt_label_hash`

```
hash(bytes):
  h = 0x811C9DC5           # offset basis
  h = h & 0xFFFFFFFF        # defensive truncation
  for byte in bytes:
    h ^= byte
    h = (h * 0x01000193) mod 2^32
  return h
```

Pure leaf. All multiplies are one-op `mul rcx` with the prime in rcx
(same shape as `command_sig.pdx`'s FNV-1a 64). After every multiply,
`shl rax, 32; shr rax, 32` zeros the high 32 bits so the next
`xor rax, byte` operates on a canonical 32-bit value.

### 4.3 Row allocators

- `_rt_row_empty`: alloc + write `(kind=4, subkind=0)`.
- `_rt_row_var`: alloc + write `(kind=4, subkind=2, arg0=fresh_var_id)`.
- `_rt_row_extend(label, ftype_idx, rest_idx)`: alloc + write
  `(kind=4, arity=2, subkind=1, arg0=label, arg1=ftype_idx,
    arg2=rest_idx)`.
- `_rt_record_type(row_idx)`: alloc TyCon(RECORD, arity=1), then alloc
  TyApp whose left=TyCon and right=row_idx. On either allocation
  failing, returns 0 (caller interprets as "pool full").

### 4.4 `_rt_row_select`

```
select(row, label):
  cursor = row
  loop:
    cursor = find(cursor)
    if cursor.kind ≠ TyRow:      return LABEL_MISSING
    if cursor.subkind == EMPTY:  return LABEL_MISSING
    if cursor.subkind == VAR:    return LABEL_MISSING  # conservative
    # EXT
    if cursor.arg0 == label:
      *out_type_idx = cursor.arg1
      return OK
    cursor := cursor.arg2
```

The ROW_VAR tail returns `LABEL_MISSING` **conservatively** at M2. In
principle an open-tailed row *could* grow a field with the queried
label on later unification, but a `select` site should not force that
decision. The caller (pipeline-stage dispatch at R222.M3+) is expected
to run `_rt_row_unify` against the expected row shape first, then
`_rt_row_select` the fields it needs — this seats the row shape and
makes the walk deterministic.

### 4.5 `_rt_row_restrict`

Two-phase:

**Phase 1 — walk + collect.** Iterate the row chain; for each
ROW_EXT whose label does not match, store `(label, field_type_idx)` in
scratch[384 + j*8 .. +8). On match, record the matched field_type_idx
into `*out_type_idx_ptr` and the next-tail into a working register.

**Phase 2 — rebuild in reverse order.** Starting from the next-tail
as the accumulator, pop entries from scratch in reverse insertion
order. For each popped `(label, field_type_idx)`, allocate a fresh
ROW_EXT whose `arg2` is the current accumulator and whose `arg0`/
`arg1` are the popped pair. Update the accumulator to the new
pool_idx. The final accumulator value is the restricted-row root; it
is written to `*out_rest_idx_ptr`.

Bounded at `RT_MAX_PREFIX_FIELDS = 10` prefix fields. Over-wide
records (> 11 fields total, with the match near the tail) return
`LABEL_MISSING` — the bound is a scratch-space constraint, not a
grammar constraint. The grammar admits arbitrary-width rows; a wider
record would need a larger scratch allocation (R225.M3 widens this to
16 fields with a double-scratch pass).

### 4.6 `_rt_row_concat`

```
concat(row_a, row_b):
  Phase 1: walk row_a; collect every (label, ftype) into scratch
           until ROW_EMPTY (ok) or ROW_VAR (CLOSED_ROW) or kind
           mismatch (LABEL_MISSING).
  Phase 2: for each collected label, _rt_row_select(row_b, label).
           If any returns OK, LABEL_DUP.
  Phase 3: start accumulator = row_b; for j = n-1 down to 0, alloc
           ROW_EXT with (label_j, ftype_j, accumulator); accumulator
           := new_idx.
  Return (accumulator << 32) | OK.
```

Concatenation refuses a ROW_VAR-tailed left operand because the row
shape would be ambiguous: the "fields of row_a" would include an
unknown prefix lurking inside the row-var. R225.M5 widens this to
accept open-tail concatenation under the "cross-context flow"
umbrella.

### 4.7 `_rt_row_unify`

The core of Rémy's algorithm. Full dispatch:

```
unify(a, b):
  a = find(a); b = find(b)
  if a == b: OK
  k_a = kind(a); k_b = kind(b)

  # Pure HM arms delegate.
  if k_a == TyVar OR k_b == TyVar:  return _hm_unify(a, b)
  if k_a == TyCon and k_b == TyCon: return _hm_unify(a, b)

  # Mixed kinds: mismatch.
  if k_a != k_b: return KIND_MISMATCH

  # Both TyApp: recurse on children (do NOT delegate to _hm_unify's
  # TyApp arm, which would descend without row-awareness).
  if k_a == TyApp:
    err = unify(a.left, b.left)
    if err: return err
    return unify(a.right, b.right)

  # Both TyRow: Rémy branch.
  s_a = subkind(a); s_b = subkind(b)

  if s_a == EMPTY and s_b == EMPTY: return OK

  if s_a == VAR:
    # Occurs-check deferred to M4 (bounded chain depth; see §7).
    a.arg2 := b
    return OK
  if s_b == VAR:
    b.arg2 := a
    return OK

  if s_a == EMPTY and s_b == EXT: return CLOSED_ROW
  if s_b == EMPTY and s_a == EXT: return CLOSED_ROW

  # Both EXT.
  if a.label == b.label:
    err = unify(a.ftype, b.ftype)
    if err: return err
    return unify(a.rest, b.rest)

  # Rémy pivot: alloc a fresh row-var; split both sides through it.
  rho_fresh = _rt_row_var()
  pivot_a   = _rt_row_extend(b.label, b.ftype, rho_fresh)
  pivot_b   = _rt_row_extend(a.label, a.ftype, rho_fresh)
  err = unify(a.rest, pivot_a)
  if err: return err
  return unify(b.rest, pivot_b)
```

### 4.8 Why the TyApp arm cannot delegate

Hm_core's `_hm_unify` on both-TyApp:

```
unify_tyapp(a, b):
  err = _hm_unify(a.left, b.left)   # recurses via _hm_unify
  if err: return err
  return _hm_unify(a.right, b.right)
```

If either of those children is a row, `_hm_unify`'s own kind dispatch
has no TyRow arm — it falls through to its "unknown kind MISMATCH"
path. So `_rt_row_unify` must own the TyApp recursion when either
subterm is row-involving. The guard "either subterm is row-involving"
is costly to check cheaply, so M2 takes the simpler contract:
**`_rt_row_unify` is always safe for any type pair, and `_hm_unify`
is safe only for pure-HM subterms**. Callers that know their type pair
contains no rows can call `_hm_unify` directly for the micro-win
(e.g. a pure-arithmetic lambda); callers unsure call `_rt_row_unify`.

---

## 5 · Status codes

Reserved error band `0x3600..0x36FF` (R225.M2 RowTypes; see
`caps.decl` "Error band 0x3600..0x36FF" section):

| Name                   | Code    | Returned by                                                              |
|------------------------|---------|---------------------------------------------------------------------------|
| `RT_OK`                | 0       | all primitives on success                                                 |
| `RT_ERR_LABEL_MISSING` | 0x3600  | `_rt_row_select`, `_rt_row_restrict`, `_rt_row_concat` (prefix-walk kind-mismatch) |
| `RT_ERR_LABEL_DUP`     | 0x3601  | `_rt_row_concat` on collision                                             |
| `RT_ERR_POOL_FULL`     | 0x3602  | any allocator (shared `_hm_pool` is 128 slots)                            |
| `RT_ERR_KIND_MISMATCH` | 0x3603  | `_rt_row_unify` when kind(a) ≠ kind(b) at a non-TyVar site                |
| `RT_ERR_CLOSED_ROW`    | 0x3604  | `_rt_row_unify` on EMPTY vs EXT; `_rt_row_concat` on ROW_VAR tail         |
| `RT_ERR_OCCURS`        | 0x3605  | reserved for M4+ full row-occurs check                                    |
| `RT_ERR_MISMATCH`      | 0x3606  | field-type unification failure bubbled through nested `_rt_row_unify`     |

Slots `0x3607..0x36FF` are reserved for R225.M3+ (predicate-type
bridge mismatches, effect-row saturation, rank-2 refusal, span
attribution codes).

The band is disjoint from every other user-space packed-status range:
`caps.decl` prints the full disjointness proof and the
`grep -rE '0x360[0-6]'` confirmation line.

---

## 6 · Interaction with the broader umbrella

- **R225.M1 HmCore.** M2 is the first additive layer over M1's pool.
  No M1 entry point changes; no M1 status code is relocated; no
  field offset in the shared `TypeNode` is renumbered. The ABI stays
  frozen.
- **R222.M1 SchemasSig.** A pipeline stage's declared input/output
  record shape (parsed by `_ss_parse_body`) will be mapped to a row
  type via a thin bridge: each field descriptor becomes a ROW_EXT
  node; the field type comes from the shared type-code namespace
  (`SS_TYPE_U64 = 1` matches `HM_CON_U64 = 1`). The bridge is
  R222.M3's responsibility.
- **R223.M1 Pipeline / R223.M2 RecordProjection.** The `select
  FIELDS` and `project FIELDS` operators consume a row at the
  pipeline-record type level; `_rt_row_restrict` is the primitive
  the dispatcher calls for each projected-out field.
- **R224.M1 LambdaLit.** A lambda whose body produces a record type
  returns a `record(ρ)` type. The HM pass at R225.M4+ computes the
  row from the body's field writes; the lambda's declared return
  type (if any) is unified against the inferred row via
  `_rt_row_unify`.
- **R226.M1 Datalog.** Datalog predicate signatures resolve to row-of-
  tuples at R225.M3; the row-side infrastructure (this module) is a
  dependency.
- **R227 `.pds` module loading.** Top-level module-level records
  (e.g. an exported module's record of bindings) are row-typed; the
  module boundary generalises over any free row-var in the exported
  surface via R225.M1's `_hm_generalise` plus the row-aware body
  walk R225.M2 introduces here.
- **R229 REPL evaluator.** The REPL's `type` command shows a
  variable's inferred type; for a record value the printer walks the
  row chain via `_rt_find` + `_rt_row_select`.

---

## 7 · Encoder-pitfall discipline

Enforced throughout `src/row_types.pdx`:

- **No `test r, r`** — every zero-check is `cmp reg, 0; je/jne`.
- **No `and r, imm64`** — the only mask we need is 32-bit; implemented
  via `shl rax, 32; shr rax, 32` to sidestep any imm-sign-extension
  edge, and `and r, 1` for the single flag bit (imm8-trivially-safe).
- **No 2-op `imul r, imm`** — 16-byte stride uses `shl r, 4`; u32 and
  u64 strides use `shl r, 2` and `shl r, 3`; the FNV-1a 32 multiply
  uses `mul rcx` with the prime in rcx (one-op unsigned mul, same
  shape as `command_sig.pdx`'s FNV-1a 64).
- **No multiline `pub let = "..."`** — justifications single-line.
- **Module basename `RowTypes` matches `row_types.pdx`.**
- **Labels prefixed `rt_`** — unique against the sibling parser-tier
  modules in this library (`u8n_`, `sch_sig_`, `cmd_sig_`, `pl_`,
  `rp_`, `ll_`, `cc_`, `hm_`, `dl_`, `se_`) and never bare
  `loop`/`if`/`let`/`fn`/`ret`.
- **cmp-imm sign safety.** All immediates compared against are
  small (`0, 1, 2, 3, 4, 10, 16, 128`, error codes `0x3600..0x3606`).
  Every value fits imm32 with bit 31 clear so direct `cmp reg, imm32`
  is sign-extension safe. The FNV-1a 32 offset basis `0x811C9DC5`
  has bit 31 set and is only used as an **operand to `mov`**, never
  to `cmp`; the subsequent `shl/shr` dance makes it canonical.
- **Sized loads/stores.** Byte loads via `xor r, r; mov_b r, [addr]`
  (zero-extend). u32 loads via `xor r, r; mov_d r, [addr]`
  (zero-extend per SDM Vol.1 §3.4.1.1). u64 loads via plain `mov`.
  u32 stores via `mov_d`; byte stores via `mov_b`.
- **Cross-module `.bss` reads/writes** via the `lea r11,
  [rip + sym]; mov [r11], rax` idiom (precedent: hm_core.pdx itself
  writes `_hm_pool_next` this way; this module extends the pattern
  to the cross-module reader side).
- **Register-liveness lesson.** `r11` is clobbered by every nested
  `CALL`. In the recursive functions (`_rt_row_unify`,
  `_rt_row_select`, `_rt_row_restrict`, `_rt_row_concat`), every
  value that must survive a nested CALL lives in `r12..r15`
  (callee-save) or on the stack frame; `r11` is only used for the
  `lea r11, [rip + sym]` loads immediately before each read/write and
  is never read after the next CALL.
- **Self-recursion via symbol-table resolution.** `_rt_row_unify`
  (and self-recursive `_rt_row_restrict`, `_rt_row_concat`,
  `_rt_row_select`) call themselves via the same symbol-reference
  shape used for cross-module calls (`call _rt_row_unify` resolves to
  the same symbol at link time; the paideia-as linker treats same-
  module symbol references identically to cross-module ones).

### 7.1 Row-occurs check deferral

M2 does **not** run a dedicated row-occurs check on ROW_VAR binding
(`_rt_row_unify`'s `s_a == VAR` / `s_b == VAR` arms write `arg2 :=
other` without walking the opposite side). Correctness argument:

- The pool is a DAG by construction: every row-ext child was
  allocated BEFORE the parent ext (allocation is monotonic; `_hm_pool_next`
  only grows). A row-var cannot be bound to a row chain that cycles
  back to itself unless a prior binding already introduced the cycle,
  which M2 forbids by the pool allocation order.
- A row-var binding to its own find-root is caught by the `a == b`
  identity check at step (1) of `_rt_row_unify`.
- Rémy's full occurs-check matters when row-var elimination can
  create cycles through row-record wrappers (`record(ρ_a)` and
  `record(ρ_b)` unifying with `ρ_a = ρ_b`). The TyApp arm of
  `_rt_row_unify` recurses into the row children directly, so a
  cycle would require the row chain itself to loop, which the pool
  DAG structure prevents.

R225.M4 lands a full `_rt_row_occurs` once effect-row interactions
with capability-row annotations make the current conservative
argument fail. The `RT_ERR_OCCURS = 0x3605` slot is reserved
accordingly.

---

## 8 · Stack-frame accounting

| Function           | Pushes  | Scratch  | rsp % 16 at nested CALL     |
|--------------------|---------|----------|------------------------------|
| `_rt_find`         | 0       | 0        | pure leaf (no CALL)          |
| `_rt_label_hash`   | 0       | 0        | pure leaf (no CALL)          |
| `_rt_alloc_node`   | 0       | 0        | pure leaf (no CALL)          |
| `_rt_row_empty`    | 0       | +8 pad   | 0  (entry 8 + 8 → 0)         |
| `_rt_row_var`      | 0       | +8 pad   | 0  (entry 8 + 8 → 0)         |
| `_rt_row_extend`   | 3 × 8   | 0        | 0  (entry 8 + 24 → 0)        |
| `_rt_record_type`  | 2 × 8   | +8 pad   | 0  (entry 8 + 24 → 0)        |
| `_rt_row_select`   | 3 × 8   | +8 pad   | 0  (entry 8 + 32 → 0)        |
| `_rt_row_restrict` | 6 × 8   | +8 pad   | 0  (entry 8 + 56 → 0)        |
| `_rt_row_concat`   | 6 × 8   | +24 (3)  | 0  (entry 8 + 72 → 0)        |
| `_rt_row_unify`    | 6 × 8   | +8 pad   | 0  (entry 8 + 56 → 0)        |

Nested CALL alignment is satisfied for every call site. The
`_rt_row_unify` function has the deepest cross-recursive call tree
(itself + `_hm_unify` + `_rt_find` + `_rt_row_var` + `_rt_row_extend`);
each call sees a 16-byte-aligned stack.

Max recursion depth: bounded by pool size (127). Worst-case stack
usage: ≈ 7.1 KiB on `_rt_row_unify` (56-byte frame × 127) — well
within the user-space default stack budget. Cross-recursion with
`_hm_unify` (56-byte frame × 127 shared with `_rt_row_unify` across
alternating levels) does not deepen the worst case since each level
descends into a strict subterm (occurs-check-equivalent reasoning on
the pool DAG).

---

## 9 · Test corpus (R225.M9 harness)

Deferred to R225.M9. The spec at `semantic-shell-language-plan.md`
§R225.M2 calls for a **40-test row-inference corpus**; the harness
landing (M9) will seed that corpus with:

### 9.1 Positive cases (24 tests)

- **Bare row construction** (3 tests): empty row; single-field row;
  three-field row.
- **Select hits** (4 tests): first-field hit; middle-field hit;
  last-field hit; through a ROW_VAR tail that has been resolved to a
  concrete row.
- **Restrict** (4 tests): remove first field; remove middle field;
  remove last field; restrict a 10-field prefix (boundary).
- **Concat** (4 tests): empty onto 3-field; 3-field onto empty; 2-
  field onto 3-field disjoint; 1-field onto 9-field (near-boundary).
- **Record wrapper** (2 tests): `record(empty)`; `record(1-field)`.
- **Unification same-label** (3 tests): single-field match; multi-
  field match in same order; multi-field match in reversed order
  (Rémy pivot not needed because fields are permutable).
- **Unification Rémy pivot** (2 tests): two singleton rows with
  disjoint labels (unification introduces a fresh row-var); two
  three-field rows with disjoint-label prefix.
- **Unification open-tail** (2 tests): closed row vs open-tail row
  with matching prefix (binds row-var to closed-empty); two open-tail
  rows with disjoint-label prefix (binds row-vars through the pivot).

### 9.2 Negative cases (16 tests)

- **Select miss** (3 tests): empty row; open-tail row; row with
  different labels only.
- **Restrict miss** (2 tests): label not in row; over-wide prefix
  (> `RT_MAX_PREFIX_FIELDS`).
- **Concat collision** (2 tests): same single label on both sides;
  overlapping multi-field sets.
- **Concat open-tail refusal** (1 test): row_a has ROW_VAR tail →
  CLOSED_ROW.
- **Unification closed vs ext** (2 tests): empty vs 1-field;
  3-field vs 2-field with 3-field being closed and 2-field being
  closed.
- **Unification kind mismatch** (2 tests): row vs TyCon; row vs
  TyApp of non-record.
- **Pool-full** (2 tests): row chain exceeds pool capacity;
  `_rt_record_type` fails on first alloc; `_rt_record_type` fails on
  second alloc.
- **Field-type mismatch** (2 tests): same-label but field types are
  distinct TyCons; same-label but field types are distinct TyApp
  constructors.

R225.M9 seeds the full 40-test corpus with golden fingerprints; the
R229.M3 session-env binding retires the per-turn transient nodes
between test runs.

---

## 10 · Forward path

| Milestone  | Addition                                                              | Notes                                                                                                               |
|------------|-----------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------|
| R225.M3    | Datalog predicate types via schema registry                           | New subkind `3` (predicate-arity row) layered over the TyRow kind; no M2 ABI change.                                |
| R225.M4    | Effect-row unification + full `_rt_row_occurs`                        | New subkind range `4..7` (effect-row flavours); upgrades the conservative no-op occurs path to a true DFS walk.     |
| R225.M5    | Cross-context type flow (lambda ↔ pipeline ↔ Datalog)                 | Builds on M2 + M3 + M4; widens `_rt_row_concat` to accept open-tail left operand under a row-var-equality side rule.|
| R225.M6    | Rank-restricted let-polymorphism (row-aware)                          | `_hm_generalise`'s body walk inspects row-nodes for rank-2 nesting; adds a rank counter.                            |
| R225.M7    | Error reporting + source-span attribution                             | Every `RT_ERR_*` return wraps with a span from the caller's AST; the row internals stay unchanged.                  |
| R225.M9    | 40-test row-inference corpus                                          | Exercises M2 primitives directly; introduces the per-turn fingerprint.                                              |
| R229.M3    | Session-scoped type-environment threading                             | Introduces a scoped pool-reset hook so a long REPL session retires per-turn transient rows.                         |

Every subsequent R225 milestone layers *additively* over M2: no M2
entry point changes signature; no `RT_ERR_*` code is relocated; no
field offset in the TyRow node is renumbered. ABI frozen at this
landing.

---

## 11 · Upstream references

- Rémy, D. (1992) *Projective ML.* ACM Transactions on Programming
  Languages and Systems 14(3). The canonical row-polymorphism paper
  with the kinded formulation (type variables and row variables as
  disjoint sorts).
- Pottier, F. and Rémy, D. (2005) *The essence of ML type inference.*
  Chapter 10 of "Advanced Topics in Types and Programming Languages"
  (Pierce, ed.), MIT Press. Textbook presentation of the row-
  unification algorithm with the pivot construction.
- Leijen, D. (2005) *Extensible records with scoped labels.* Trends
  in Functional Programming 6. Alternative formulation (allowing
  duplicate labels through label scoping); M2 does **not** adopt this
  variant — the pipeline-record surface requires unique labels per
  record.
- `design/terminal/semantic-shell-language-plan.md` §R225.M2 (the
  umbrella decomposition).
- `design/terminal/semantic-shell.md` §SH-D2 (the type-system
  design decision).
- `design/shell/hm-algorithm-w-core.md` §4 (the R225.M1 Hindley-
  Milner kernel this module layers over).
- `design/shell/pipeline-stage-parser.md` §SH-D5 (pipeline-record
  surface that drives the row-type demand).
- `design/shell/cmd-functor-schemas-sig.md` §SH-D5 (the record-shape
  parser that R222.M3 will bridge into row types).
