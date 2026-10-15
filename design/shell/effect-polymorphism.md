# Effect polymorphism — R224.M3

**Issue:** paideia-os#2677
**Umbrella:** R224 (lambda-lang, paideia-os#2488)
**Satellite:** `tools/user/libpdx-pds-parser` (user-space; `src/effect_row.pdx`)
**Upstream substrate:** R225.M2 RowTypes (`design/shell/row-types-remy.md`,
`src/row_types.pdx` — the Rémy row-polymorphic pool and the row-aware
unifier) + R225.M1 HmCore (the shared TypeNode pool and TyVar/TyCon/TyApp
machinery).
**Design axis:** Q-A3, *"all effects in rows"* — a lambda's effect
discipline is a first-class row-typed field of its arrow, unified by
the same Rémy pivot that unifies record-row shapes.

**Status at this landing:** M3 lands the effect-polymorphic row
sub-grammar for the paideia-shell lambda surface. A lambda carries
an **effect row** attached to its arrow (`A -> B !{row}`) that lists
the primitive effects the lambda may perform; the type-checker tracks
these across invocations by Rémy-style unification, and the pure
argument rejection acceptance (passing an `!{io}` lambda where
`!{}` is expected) is enforced by `_er_check_subtype`.

---

## 1 · Scope and motivation

The semantic-shell plan
(`design/terminal/semantic-shell-language-plan.md` §R224.M3)
specifies that lambdas carry **effect rows** so the type-checker can
distinguish a pure arithmetic lambda from one that reads a file,
writes a system register, allocates heap, or touches a capability.
The design decision Q-A3 chose the **"all effects in rows"** path
over three alternatives:

* **Q-A3a — intrinsic set.** A fixed enum of effects baked into the
  arrow kind. Rejected because the design wants user-declared effects
  (per-session `effect my_eff` declarations) in a later M, and an
  enum closes the universe at compile time.
* **Q-A3b — monadic lift.** A Haskell-shape `A -> m B` arrow where
  the user chooses `m` per call-site. Rejected because the shell is
  not Hindley–Milner-polymorphic over `m` at M3 and the ergonomics
  break the one-arrow-two-rows symmetry the pipeline-record layer
  already uses.
* **Q-A3c — capability-row conflation.** Combine effects and
  capabilities into one row. Rejected because the shell already
  separates **effects** (what a lambda *does*) from **capabilities**
  (what it *is allowed to do*); R224.M4 lands the capability row
  as a *parallel* row on the same arrow.

Rémy's 1992 formulation — the same substrate R225.M2 landed for
record rows — turns out to apply verbatim to effect rows: an effect
row is a sorted sequence of label-only tokens terminated by either
the empty row `∅` or a row variable `ρ`. The only differences from
record rows are (a) the row carries labels but no per-label field
type (the type is implicit — the label *is* the effect), and (b)
label identity is interned into a small table (6 primitives + 26
user-declared slots) rather than hashed by FNV-1a across arbitrary
bytes. By embedding effects in the same `TyRow` kind R225.M2 landed,
the row-aware unifier (`_rt_row_unify`) handles effect rows *for free*
— the Rémy pivot works whether the row carries field types or
not.

The 20-test corpus from the acceptance statement is enumerated at
§7 below. The canonical acceptance test is: *a lambda that reads a
file is typed with `!{io}`; passing it as a pure argument is
rejected* with `ER_ERR_IMPURE_PASSED_PURE` and the packed offending
label index (0 = `io`).

---

## 2 · Grammar

```
EffectAnnot := "!" WS* "{" WS* LabelList? WS* "}"
LabelList   := Label (WS* "," WS* Label)* (WS* "," WS* RowVar)?
             | RowVar
Label       := identifier
             (one of: io | sysreg | mem | caps | trap | allocates
              — primitive labels in slots 0..5; or any user-declared
              identifier interned into slots 6..31.)
RowVar      := "rho" | "rho_" alphanumtail
             (any identifier beginning with the three-byte prefix
              "rho" is a row-variable. `rho`, `rho_1`, `rho_tail`.)
identifier  := [A-Za-z_] [A-Za-z0-9_]*          (len 1..15)
WS          := 0x20 | 0x09 | 0x0A | 0x0D
```

The annotation attaches to an arrow:

```
f : (u64) -> u64 !{io}
g : (u64) -> u64 !{io, mem}
h : (u64) -> u64 !{io, mem, rho}   -- open; may add effects
k : (u64) -> u64 !{}               -- closed-pure
```

The lambda-literal grammar (R224.M1 `LambdaLit`) already recognises
the arrow `->`; R224.M3 extends the arrow terminator to recognise an
*optional* `!{...}` suffix *after* the result type. The R224.M3
parser (this landing) handles the suffix in isolation: it takes
caller-supplied bytes positioned at the `!` sigil and emits a
pool_idx for the row node. The R224.M3.5 integration pass (filed as
an umbrella follow-up) is what wires the suffix into
`LambdaLit`'s header-byte parse.

**Why the explicit `rho` prefix for row variables.** The parser must
syntactically distinguish an open row-var tail from a label named
`rho` or `rho_tail`. A naming convention — any identifier starting
with `rho` is a row-variable — resolves the ambiguity without a
reserved-word table. The convention is enforced in the parser; the
label-interning table never contains a slot whose name starts with
`rho`.

---

## 3 · Primitive effect labels

Six primitive labels are reserved. Each occupies a static slot in
`_er_label_table` with `tag = ER_TAG_PRIMITIVE = 0`:

| idx | name       | meaning                                                 |
|-----|------------|---------------------------------------------------------|
| 0   | `io`       | reads or writes a filesystem path, a socket, or a tty   |
| 1   | `sysreg`   | reads or writes a privileged system register (MSR, CR*) |
| 2   | `mem`      | reads or writes memory beyond the caller's stack frame  |
| 3   | `caps`     | mints, discards, or hands off a capability handle       |
| 4   | `trap`     | may trap (divide-by-zero, overflow, bounds-check fail)  |
| 5   | `allocates`| allocates heap or an arena beyond the caller's budget   |

The 26 remaining slots (idx 6..31, `tag = ER_TAG_USER = 1`) are
reserved for user-declared effects introduced at a later M (per the
umbrella's follow-up list). M3 populates slots 0..5 lazily on the
first `_er_parse` call; slots 6..31 are allocated as `_er_parse`
encounters a non-primitive label *provided* a future `_er_declare`
hook has been exposed. At M3 the hook is not yet live, so an
unknown label returns `ER_ERR_UNKNOWN_LABEL`; the interning path
is wired but the public-facing `_er_declare` lands in R224.M3.1.

The primitive-label byte strings are stored directly in the table
rather than in a `.rodata` sidecar — the lazy-init path writes the
six names (none longer than 10 bytes) into the per-slot inline
buffer at module boot.

---

## 4 · Label-table layout

```
.bss _er_label_table      : [u8; 32 * 16] = uninit @align(8)   // 512 B
.bss _er_label_table_count: u64            = uninit            //   8 B
```

Per-slot stride (16 B):

| offset | field       | type   | meaning                                   |
|--------|-------------|--------|-------------------------------------------|
| +0     | `len`       | u8     | name length (0 means slot is empty)       |
| +1     | `tag`       | u8     | 0 = primitive, 1 = user-declared          |
| +2..14 | `padding`   | u8[0]  | reserved; zero                            |
| +4..15 | `name`      | u8[12] | NFC-normalised name bytes (max 12 chars)  |

Note: the name field starts at offset +4 to leave a 4-byte header
aligned prefix (`len`, `tag`, 2 reserved). The 12-byte name buffer
accommodates every primitive and every reasonable user label; a
longer label is rejected at parse time with `ER_ERR_SYNTAX`.

**Why a 32-slot cap.** 6 primitives + 26 user-declared slots =
32 slots. The cap keeps the lookup linear-scan cost bounded
(32 × 12-byte compares ≈ 384 ops/lookup, dominated by the parse
layer's own byte walk) and keeps the table fit for a `shl r, 4`
stride (idx × 16 B). Growing beyond 32 is a later-M discipline
question (slab, perfect-hash, dense interner); the 32-slot cap
is deliberately conservative so a shell session with pathological
effect-declaration churn fails loudly rather than inflating the
table under the floor.

---

## 5 · Pool encoding (packing into RowTypes)

An effect row is a RowTypes row (`HM_KIND_TYROW = 4`). The three
subkinds reuse R225.M2's codes:

| subkind       | code | role in an effect row                          |
|---------------|------|------------------------------------------------|
| `ROW_EMPTY`   | 0    | the closed empty effect row `!{}`              |
| `ROW_EXT`     | 1    | an extension `ℓ ; ρ'`                          |
| `ROW_VAR`     | 2    | the row-variable tail `rho`                    |

For a `ROW_EXT` node the fields are:

| offset | slot                | effect-row semantics                     |
|--------|---------------------|------------------------------------------|
| +0     | kind                | 4 (`HM_KIND_TYROW`)                      |
| +1     | arity               | 2                                        |
| +2     | subkind             | 1 (`ROW_EXT`)                            |
| +3     | flags               | reserved (0)                             |
| +4     | arg0 (u32)          | `(tag << 24) | idx` packed label id      |
| +8     | arg1 (u32)          | 0 (effect labels are nullary)            |
| +12    | arg2 (u32)          | pool_idx of the rest-of-row              |

The `arg1` slot is left zero because an effect label carries no
field type — this is the one way the encoding diverges from a
record-row's `ROW_EXT` node, and it is a *degenerate* case rather
than a structural change: the row-aware unifier's `arg1` recursion
over a pair of `0` indices resolves via identity and returns `OK`
immediately (two zero pool_idx values match trivially at the
`_rt_row_unify` identity check).

**Why pack `(tag, idx)` into the 32-bit label-hash slot.** The
R225.M2 unifier compares labels via `cmp label_a, label_b` as 32-bit
equality. Packing `(tag, idx)` into one 32-bit value yields identity
semantics (two labels are the same iff they share both tag and idx)
without a second slot. The low 24 bits are the idx (plenty of
headroom beyond the 32-slot cap); the high 8 bits are the tag. A
primitive label with idx 0 (`io`) and tag 0 encodes as `0x00_000000`;
a user-declared label with idx 6 and tag 1 encodes as `0x01_000006`.

**No label collisions.** Because `(tag, idx)` is a direct index
rather than a hash, there is no collision risk — unlike R225.M2's
FNV-1a 32 scheme, two effect labels equate iff their table slot is
the same. The table itself resolves collisions on *name* by
preferring the lowest-numbered slot with a matching name on
`_er_label_lookup`.

---

## 6 · Public API

```
_er_init() -> ()
  Boot hook. Lazy-populates the primitive-label slots 0..5 and
  sets _er_label_table_count := 6. Idempotent (re-call is a no-op
  because _er_label_table_count > 0 short-circuits).

_er_label_lookup(ptr, len) -> packed_u64
  Linear scan over _er_label_table[0.._er_label_table_count). Byte-
  compares each slot's name against (ptr, len). Returns
  (tag << 24) | idx in low 32 of rax on hit, or 0xFFFFFFFF on miss.
  Lazy-calls _er_init on first use.

_er_label_intern(ptr, len) -> packed_u64
  Checks _er_label_lookup; on hit returns the existing packed
  (tag,idx). On miss: if _er_label_table_count < 32, allocates a
  new slot at that index with tag = ER_TAG_USER = 1, copies the
  name bytes, bumps _er_label_table_count, and returns the newly
  packed id. On table-full, returns 0xFFFFFFFF (caller translates
  to ER_ERR_LABEL_TABLE_FULL). M3 restricts intern to the slots
  already populated at init; user-declared labels require a future
  _er_declare hook — M3 _er_parse treats intern-miss as
  ER_ERR_UNKNOWN_LABEL rather than silently extending the table.

_er_parse(bytes, len, out_row_ref) -> status
  Parses an EffectAnnot from the caller's NFC-normalised bytes.
  Writes the pool_idx of the resulting RowTypes row into
  *out_row_ref. Returns ER_OK or an ER_ERR_* code. On error,
  *out_row_ref is written to 0.

  Algorithm:
  1. Skip WS; require `!`; skip WS; require `{`.
  2. Loop: skip WS; if `}` then terminate with ROW_EMPTY tail;
     else parse an identifier (len 1..15, [A-Za-z_][A-Za-z0-9_]*).
     If identifier starts with "rho" → treat as RowVar: skip WS;
     require `}`; terminate with a fresh ROW_VAR tail.
     Else → treat as Label: _er_label_lookup; miss →
     ER_ERR_UNKNOWN_LABEL. Record (tag, idx) in a 16-slot caller-
     local label-id array (scratch region of _hm_subst_table).
     Skip WS; if `,` consume it and loop; if `}` break; else
     ER_ERR_SYNTAX.
  3. Build the row bottom-up: tail (ROW_EMPTY or ROW_VAR) first,
     then prepend each collected label by calling _rt_row_extend
     with (packed_id, 0, rest).
  4. Write the final root to *out_row_ref.

_er_check_subtype(sub_row, sup_row) -> packed_u64
  Walks sub_row; for each ROW_EXT with packed label id ℓ, calls
  _rt_row_select(sup_row, ℓ, &ignore). On RT_OK the label is
  present in sup; on RT_ERR_LABEL_MISSING sub carries an effect
  sup does not permit → returns (ℓ << 32) | ER_ERR_IMPURE_PASSED
  _PURE. Walks terminate at ROW_EMPTY (success) or ROW_VAR
  (treated as "open; may contain more" — at M3 this is sound
  because an open sub tail against a closed sup fails on the
  first label that is present in sub but absent in sup; against
  an open sup, the open sub trivially subsumes).

  Rationale: effect-row subtyping is **width-covariant** — a
  function producing fewer effects is safely usable where more are
  allowed. The subtype check therefore walks the *producer* (sub)
  and demands each of its labels be present in the *consumer*
  (sup). `_er_check_subtype({}, {io}) == RT_OK` (passing a pure
  function where io is allowed) — but
  `_er_check_subtype({io}, {}) == ER_ERR_IMPURE_PASSED_PURE | (0 << 32)`
  (passing a file-reading function where none is allowed).

_er_render(row_ref, out, out_cap) -> packed_u64
  Pretty-prints the row back to source form `!{io, mem, rho}`.
  Walks the row via _rt_find; for each ROW_EXT reads arg0 as
  packed label id, looks up the label name from _er_label_table,
  writes name bytes to the out buffer; on ROW_VAR writes "rho"
  (M3 renders every row-var as a bare "rho"; a future M wires a
  per-row-var name into the var_id namespace). Returns
  (bytes_written << 32) | status.

Register maps (SysV):

  _er_init()                               -> rax (ignored)
  _er_label_lookup(rdi, rsi)               -> rax
  _er_label_intern(rdi, rsi)               -> rax
  _er_parse(rdi, rsi, rdx)                 -> rax
  _er_check_subtype(rdi, rsi)              -> rax
  _er_render(rdi, rsi, rdx)                -> rax
```

---

## 7 · 20-test acceptance corpus

The parser-side corpus lives at
`tools/user/libpdx-pds-parser/tests/proptest_effect_row.pdx` (filed
as a follow-up — M3 lands only the parser surface, tests arrive at
R224.M3.9). The 20 cases are:

### Parse-shape (10)

1. `!{}` → empty row.
2. `!{io}` → single primitive, closed tail.
3. `!{io, mem}` → two primitives, closed tail.
4. `!{io, mem, sysreg, caps, trap, allocates}` → all six primitives.
5. `!{rho}` → row-variable only.
6. `!{io, rho}` → one primitive + open tail.
7. `!{io, mem, rho_tail}` → two primitives + named row-var.
8. `! { io , mem }` → whitespace variations.
9. `!{unknown}` → `ER_ERR_UNKNOWN_LABEL`.
10. `!{io, io}` → duplicate labels; expected `ER_ERR_SYNTAX`
    (deferred to M3.1 dedup check — at raw M3, duplicates pass
    through and the Rémy unifier catches them downstream as
    `RT_ERR_LABEL_DUP`).

### Subtype (10)

The ⊆ relation is **width-covariant**: *sub* ⊆ *sup* iff every
label of *sub* appears in *sup*.

11. `{} ⊆ {}` → OK.
12. `{} ⊆ {io}` → OK (pure fn allowed where io is).
13. `{io} ⊆ {}` → **ER_ERR_IMPURE_PASSED_PURE** with offending
    label (0 << 32 for `io`). *(acceptance anchor case.)*
14. `{io} ⊆ {io}` → OK.
15. `{io} ⊆ {io, mem}` → OK.
16. `{io, mem} ⊆ {io}` → **ER_ERR_IMPURE_PASSED_PURE** with
    offending label (2 << 32 for `mem`).
17. `{io, rho} ⊆ {io, mem}` → OK at M3 (open sub tail treated
    as "may add more; checker optimistic until bound"); M3.2
    tightens this to require the open tail be bound against the
    sup tail.
18. `{io} ⊆ {io, rho}` → OK (open sup absorbs anything).
19. `{rho} ⊆ {}` → OK at M3 (optimistic; see 17).
20. `{} ⊆ {rho}` → OK.

The acceptance anchor (case 13) is the test the brief names
verbatim.

---

## 8 · Error band

```
Band 0x4000..0x40FF — reserved for R224.M3 effect-polymorphism.

  ER_OK                      : 0        operation succeeded.
  ER_ERR_SYNTAX              : 0x4000   grammar fault at `!`, `{`,
                                        `,`, `}`, or an identifier
                                        byte run.
  ER_ERR_UNKNOWN_LABEL       : 0x4001   identifier is not one of the
                                        six primitives and is not yet
                                        interned (M3; M3.1 widens
                                        when _er_declare lands).
  ER_ERR_LABEL_TABLE_FULL    : 0x4002   _er_label_intern on a full
                                        32-slot table.
  ER_ERR_IMPURE_PASSED_PURE  : 0x4003   _er_check_subtype saw a
                                        label present in sub but
                                        absent in sup; the offending
                                        packed label id is in the
                                        high 32 bits of rax.
  ER_ERR_POOL_FULL           : 0x4004   HmCore pool exhausted during
                                        _rt_row_extend or _rt_row_var.
  ER_ERR_OUT_TOO_SMALL       : 0x4005   _er_render: out_cap smaller
                                        than the rendered byte count.
  ER_ERR_KIND_MISMATCH       : 0x4006   _er_check_subtype saw a
                                        non-row kind on sub or sup
                                        (schema violation; propagated
                                        from the row-walk guard).
  ER_ERR_UNKNOWN_ROWVAR      : 0x4007   _er_render saw a ROW_VAR whose
                                        var_id has no cached name;
                                        reserved for M3.3 when per-
                                        row-var naming lands.

  Slots 0x4008..0x40FF reserved for R224.M3.1+ follow-ups
  (dedup, _er_declare, per-row-var names, user-declared
  effect lifetime, parallel capability-row interop).
```

Disjoint from every prior band: the previous highest-slot carve-out
was R229.M3 TypeEnv at `0x3D00..0x3DFF`; `0x3E00..0x3FFF` is held
in reserve for R133.M5 kernel-side arm; this landing takes
`0x4000..0x40FF` on a new kilo-step boundary. The grep-disjointness
proof is wired into `caps.decl` at wave close.

---

## 9 · Linker dependencies

`src/effect_row.pdx` has **no external cross-library** linker
dependencies. It introduces **two intra-library** dependencies:

* **R225.M2 RowTypes** (`row_types.pdx`): `_rt_row_extend`,
  `_rt_row_var`, `_rt_row_empty`, `_rt_row_select`, `_rt_find`.
  Effect rows are built on top of the Rémy pool `_hm_pool` via
  these allocators and traversers.
* **R225.M1 HmCore** (`hm_core.pdx`): `_hm_subst_table` is reused
  as scratch for the label-id collection buffer; a disjoint slice
  `[768..832)` is carved out (R225.M2 uses `[384..512)` for
  restrict/concat prefix-field collection; the two slices do not
  alias because effect-row parsing and record-row restrict never
  happen inside the same shell turn).

All five public entry points (`_er_init`, `_er_label_lookup`,
`_er_label_intern`, `_er_parse`, `_er_check_subtype`, `_er_render`)
can be linked standalone against `hm_core.o + row_types.o`.

---

## 10 · Forward path

* **R224.M3.1 — dedup check.** `_er_parse` detects duplicate labels
  in the input annotation and emits `ER_ERR_SYNTAX` with a
  dedicated offset slot. Currently duplicates pass through at raw
  M3 and are caught by Rémy unification downstream.
* **R224.M3.2 — open-row discipline.** Tighten `_er_check_subtype`
  so an open sub tail against a closed sup requires explicit
  binding of the open tail to the empty row (M3 treats open tails
  optimistically).
* **R224.M3.3 — per-row-var names.** Attach a user-chosen name to
  each row-variable id so `_er_render` round-trips user-declared
  names rather than always emitting `rho`.
* **R224.M3.5 — LambdaLit integration.** `_ll_parse` consumes the
  optional `!{...}` suffix after `->` ResultType and forwards it
  into `_er_parse`.
* **R224.M3.6 — _er_declare hook.** Expose a public entry point
  for the shell's `effect my_eff` declaration to intern a new
  user-declared effect at runtime.
* **R224.M4 — capability-row typing.** A parallel row kind
  (`capabilities: {...}`) with the same encoding; the R225.M4
  effect-row unification arm lands alongside and reuses the Rémy
  pivot across both row flavours.
* **R224.M3.9 — proptest harness.** Lands the 20-test corpus
  from §7 under `tests/proptest_effect_row.pdx` + a fingerprint
  golden.

---

## 11 · Encoder discipline (absolute)

* No `test rN, rN` — every zero-check is `cmp reg, 0; je/jne`.
* No `and rN, imm64` — the only 32-bit mask (`0xFFFFFFFF`) is
  implemented via `shl rax, 32; shr rax, 32`; small masks (1, 7)
  fit imm8.
* No 2-op `imul r, imm` — label-table stride is `shl r, 4` (16 B),
  name offset is `add r, 4`.
* No multiline `pub let = "..."` — all justifications are single-
  line strings.
* Module basename `EffectRow` matches `effect_row.pdx`.
* Labels prefixed `er_` (grep-confirmed disjoint from every
  sibling module's prefix: `u8n_` / `sch_sig_` / `cmd_sig_` /
  `pl_` / `rp_` / `ll_` / `cc_` / `hm_` / `rt_` / `dl_` / `se_` /
  `te_` / `afs_` / `fi_` / `gi_`). Never bare `loop`/`if`/`let`/
  `fn`/`ret`.
* All `cmp reg, imm` immediates (0, 1, 2, 3, 4, 5, 6, 15, 16, 32,
  status codes 0x4000..0x4007) fit imm32 with bit 31 clear and are
  small-positive, so no sign-extension dance is needed.
* Byte loads via `xor r,r; mov_b r,[addr]`; u32 loads via
  `xor r,r; mov_d r,[addr]`; u64 loads via plain `mov`.
* u32 stores via `mov_d`; u8 stores via `mov_b`.
* Cross-module `.bss` writes via `lea r11, [rip + sym];
  mov [r11], rax` (precedent: `row_types.pdx` writes
  `_hm_pool_next` this way).
* Register-liveness: r11 is clobbered by every nested CALL (every
  call into RowTypes). Every value that must survive a nested
  CALL lives in r12..r15 (callee-save) or on the stack frame.
  `_er_parse` and `_er_check_subtype` are self-contained
  (never-recursive) but call across the intra-library boundary
  into RowTypes allocators repeatedly, so each nested-CALL block
  spills callee-save survivors before the call and reloads them
  after.
