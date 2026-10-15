# Effect-row unification — R225.M4

**Issue:** paideia-os#2685
**Umbrella:** R225 (unified HM typechecker across pipeline / lambda / Datalog, paideia-os#2489)
**Satellite:** `tools/user/libpdx-pds-parser` (user-space; `src/effect_unify.pdx`)
**Upstream substrate:**
- R225.M2 RowTypes (`design/shell/row-types-remy.md`, `src/row_types.pdx`) — the Rémy row primitives + the shared singleton `_hm_pool` + the row-aware allocators + `_rt_find`/`_rt_row_select`.
- R225.M1 HmCore (`design/shell/hm-algorithm-w-core.md`, `src/hm_core.pdx`) — the scheme wire format consumed by `_eu_check_rank`.
- R224.M3 EffectRow (`design/shell/effect-polymorphism.md`, `src/effect_row.pdx`) — the packed-id ROW_EXT encoding (label id in arg0) that EffectUnify reuses as an opaque u32 identity.

**Design axes:**
- **J1 — join not pivot.** Effect rows obey a MONOTONE lattice: a lambda typed `!{io}` can safely be re-typed `!{io, mem}` because adding effects to the inferred row is harmless at the use-site. The operation needed is the LEAST-UPPER-BOUND (set union with ROW_VAR tail propagation), not Rémy's structural-equality pivot. `_eu_unify` is a disjoint second row-arithmetic entry point from R225.M2's `_rt_row_unify`.
- **P10 — rank-restricted quantifiers.** Type schemes may bind row variables only at the OUTERMOST arrow; nested rows cannot generalize. `_eu_check_rank` enforces this via a well-formedness pass over the HmCore scheme wire format.

**Status at this landing:** M4 lands the three public entry points (`_eu_unify`, `_eu_check_rank`, `_eu_least`), the error band 0x4900..0x49FF (eight slots used, slots 0x4908..0x49FF reserved for M4.1+), and the design doc. The 30-test proptest corpus is enumerated in §7 and deferred to R225.M4.9 per the umbrella decomposition.

---

## 1 · Scope and motivation

The semantic-shell plan (`design/terminal/semantic-shell-language-plan.md` §R225.M4) specifies that lambdas carry **effect rows** attached to their arrows (`A -> B !{row}`) that the type-checker tracks across invocations. R224.M3 EffectRow lands the row-encoding grammar; R225.M4 (THIS landing) lands the **unification operation** the typechecker applies when effects must flow across a join point:

- A pipeline stage that reads a file (`!{io}`) feeds a pipeline stage that mutates memory (`!{mem}`) — the composed pipeline's effect row must be `!{io, mem}`.
- A `let` binding whose RHS has effect row `!{io, rho_a}` is used in a body with inferred row `!{mem, rho_b}` — the `let`'s effect row must be `!{io, mem, rho_fresh}`.
- A pattern-match arm with effect row `!{io}` and a sibling arm with row `!{}` yield a case-expression row `!{io}`.

The operation performed in each of these cases is the **join** (set union with ROW_VAR tail propagation), NOT Rémy's structural-equality unification. Record rows unify by pivot because records carry PER-LABEL FIELD TYPES — `{a: u64, b: str}` is distinct from `{a: u64}` and the user is DECLARING the shape. Effect rows carry no per-label payload (an effect label IS the effect) and the user DECLARES THE MINIMUM — the inferred row grows monotonically.

Three design axes considered:

- **J1a — pivot everywhere.** Reuse `_rt_row_unify` for effect rows. **Rejected.** The Rémy pivot refuses to unify `{io}` with `{mem}` (returns RT_ERR_CLOSED_ROW because EMPTY vs ROW_EXT doesn't pivot). The caller would have to interpose a translation layer that first wraps every effect row with a fresh ROW_VAR tail so the pivot succeeds — a workaround that silently converts the semantic error into noise.
- **J1b — join at the enclosing arrow.** Store effect rows directly on the arrow TyCon with a per-arrow accumulator; join at every substitution step. **Rejected.** The storage model complicates the HmCore pool layout (arrows gain a 32-bit tail slot) and the join must be re-run every time the arrow is encountered; a dedicated primitive on the row itself is cleaner.
- **J1c — join primitive on effect rows.** A new row-arithmetic entry point `_eu_unify` that walks both inputs and emits a joined row. **Chosen** (this landing). Reuses R225.M2's row-graph pool, allocators, resolve-chain walker, and label-identity contract verbatim; adds no new node layout.

Rank restriction (P10) is a WELL-FORMEDNESS requirement on HmCore schemes: when the typechecker's generalisation step (R225.M6) later lifts an effect row's row-variable into a scheme's bound-var list, that lift must only happen at the OUTERMOST arrow. A nested scheme that re-quantifies the same row-var would be rank-2, breaking HM's decidability guarantee. At M4 the HmCore wire format exposes only ONE outer ∀, so the check is a well-formedness validator; the reserved `EU_ERR_RANK_RESTRICTED_VIOLATION` return code lights up at M4.1 when nested-quantifier body nodes land.

---

## 2 · Operational semantics of the join

### 2.1 Lattice shape

Effect rows form a lattice:

```
    (open row with every alphabet label)   top
             .
             .
       (open row with k labels)       mid
             .
             .
          (closed empty row {})        bot
```

Order: `R1 ⊑ R2` iff `labels(R1) ⊆ labels(R2)` AND (`tail(R1) = ∅` OR `tail(R2) = ρ`). The JOIN `R1 ⊔ R2` is the LEAST row above both: label set is the union; tail is open iff either input is open.

The lattice is monotone over substitution: binding a row-var `ρ := R` where `R` adds labels yields a greater row. The join is thus commutative and associative, matching the semilattice structure the typechecker's inference loop needs.

### 2.2 Worked examples

| row_a                | row_b                | join                     |
|----------------------|----------------------|--------------------------|
| `!{}`                | `!{}`                | `!{}`                    |
| `!{io}`              | `!{}`                | `!{io}`                  |
| `!{io}`              | `!{io}`              | `!{io}` (dedup)          |
| `!{io}`              | `!{mem}`             | `!{io, mem}`             |
| `!{io, mem}`         | `!{mem, trap}`       | `!{io, mem, trap}`       |
| `!{io, rho}`         | `!{}`                | `!{io, rho}`             |
| `!{io}`              | `!{mem, rho}`        | `!{io, mem, rho}`        |
| `!{io, rho_a}`       | `!{mem, rho_b}`      | `!{io, mem, rho_fresh}`  |

The last line is the ONLY case that mints a fresh ROW_VAR: when both inputs carry open tails. Semantically the two row-vars `rho_a` and `rho_b` can be independently extended, so the join row's tail must be a fresh row-var that is strictly greater than either (and will unify downwards into both via a subsequent `_rt_row_unify` call on the pivot).

At M4 we DO NOT emit the pivot bindings `rho_a := rho_fresh` and `rho_b := rho_fresh` — the raw join just produces the fresh-var tail. The pivot bindings are a job for the enclosing type-checker, which calls `_eu_unify` as one step in a longer chain and separately maintains the row-var substitution. M4.2 lands the "inner subterm unification" wire-up that WOULD call `_rt_row_unify` on the pivot during `_eu_unify`; it reserves `EU_ERR_UNIFY_INCONSISTENT` and `EU_ERR_ROWVAR_OCCURS`.

### 2.3 Dedup discipline

The input rows may legally contain duplicate labels (R224.M3 EffectRow's parser does NOT dedup at M3; see `design/shell/effect-polymorphism.md` §M3.1 for the deferred dedup check). `_eu_unify` MUST produce a dedup'd output: `!{io, io}` joined with `!{mem}` must emit `!{io, mem}`, not `!{io, io, mem}`.

The implementation performs dedup during the BUILD phase: as each label is prepended onto the accumulator, `_rt_row_select` is called on the current accumulator with the candidate label; if `RT_OK` returns, the label is already present and the prepend is skipped.

Dedup cost is O(k²) where k is the total raw-collect count (≤ 32). At typecheck time this is negligible; the walk + build is bounded by the shared pool budget (128 slots).

---

## 3 · Public API

```
_eu_unify(row_a: u64, row_b: u64) -> packed_u64
    rdi = row_a       (pool_idx of the first effect row)
    rsi = row_b       (pool_idx of the second effect row)
    rax = (joined_row_ref << 32) | status

_eu_check_rank(scheme_ptr: u64, scheme_len: u64) -> status
    rdi = scheme_ptr  (byte pointer to a HmCore scheme stream)
    rsi = scheme_len  (byte length of the scheme)
    rax = EU_OK (0) or EU_ERR_BAD_SCHEME (0x4903)

_eu_least(rows_ptr: u64, n: u64) -> packed_u64
    rdi = rows_ptr    (ptr to a u32 array of n row pool_idx values)
    rsi = n           (count; 0..EU_MAX_JOIN_ARITY (16))
    rax = (joined_row_ref << 32) | status
```

All three return values pack the result row's pool_idx (u32) into the high 32 bits and the status band 0x4900..0x4907 (u32) into the low 32 bits. On error the high 32 bits are zero so the caller can detect error cleanly via `shl rax, 32; shr rax, 32; cmp rax, 0; je ok`.

---

## 4 · Pool-reuse discipline

EffectUnify shares R225.M2's singleton `_hm_pool` (128 x 16-byte slots) via:

| Dependency           | Call site                               | Role                             |
|----------------------|-----------------------------------------|----------------------------------|
| `_rt_find`           | `_eu_unify` walk-cursor resolve         | Follow ROW_VAR resolved chain    |
| `_rt_row_empty`      | `_eu_unify` build phase (closed tail)   | Mint closed empty-row node       |
| `_rt_row_var`        | `_eu_unify` build phase (open tail)     | Mint fresh ROW_VAR               |
| `_rt_row_extend`     | `_eu_unify` build phase (per label)     | Prepend ROW_EXT with packed id   |
| `_rt_row_select`     | `_eu_unify` build phase (dedup check)   | Reject already-present label     |
| `_hm_pool` (.bss)    | Walk-time node_addr computation         | `lea r11, [rip + _hm_pool]`      |

The arg0 u32 slot of a ROW_EXT node is interpreted as an OPAQUE packed label id — EffectUnify does NOT decode the `(tag << 24) | idx` R224.M3 encoding, so the identity comparison reduces to a 32-bit `cmp` on arg0 which works equally for R224.M3 effect-labels AND R224.M4 capability-labels (so the module is already structurally ready for the R225.M4.3 capability-row-join parallel landing).

The subkind byte at `[+2]` is the authoritative EMPTY/EXT/VAR discriminator in both flavours.

---

## 5 · Rank-restricted quantifiers (P10)

### 5.1 Statement

A HmCore type scheme is a flat byte stream:

```
[+0]   u32  n_bound_vars
[+4]   u32  n_body_nodes
[+8]   u32[n_bound_vars]        bound_var_ids  (sorted ascending)
[+8 + 4*n_bound_vars]
       TypeNode[n_body_nodes]   body           (16-byte stride)
```

P10 requires: **row variables may be bound only at the OUTERMOST ∀**. A rank-2 scheme would bind a row-var inside a nested quantifier body — e.g. a type like `∀α. (∀ρ. τ → τ)` where `ρ` is quantified beneath the outer arrow — which breaks HM's decidability guarantee.

### 5.2 M4 enforcement

At M4 the HmCore wire format carries a SINGLE outer ∀. Every bound var listed in `bound_var_ids` is at the outermost quantifier by construction. The check therefore reduces to a well-formedness validation:

1. `scheme_len >= EU_SCHEME_HDR_BYTES (8)`.
2. `n_bound_vars <= EU_SCHEME_MAX_BOUND (64)`.
3. `n_body_nodes in [1 .. EU_SCHEME_MAX_BODY (128)]`.
4. `scheme_len == 8 + 4*n_bound_vars + 16*n_body_nodes`.
5. Every body node's kind byte is in `{HM_KIND_TYVAR=1, HM_KIND_TYCON=2, HM_KIND_TYAPP=3, HM_KIND_TYROW=4}`.

Any violation returns `EU_ERR_BAD_SCHEME`. The `EU_ERR_RANK_RESTRICTED_VIOLATION` code is RESERVED for the M4.1 wire-format extension that lands a new body-node kind (e.g. `HM_KIND_FORALL = 5`) carrying a nested `bound_var_ids` list; THIS pass learns to descend into the inner scheme and refuse any bound-var declaration whose kind resolves to `HM_KIND_TYROW` with `RT_SUBKIND_VAR`.

### 5.3 Why the raw-M4 check still matters

Even without a reachable `RANK_RESTRICTED_VIOLATION`, the well-formedness validator catches:

- **Truncated schemes** — a byte stream shorter than its header declares.
- **Overrun schemes** — a byte stream longer than its header declares (trailing garbage).
- **Oversized schemes** — `n_bound_vars > 64` is HmCore's hard upper bound; `n_body_nodes > 128` exceeds the pool budget by construction.
- **Garbage kind bytes** — a node with kind outside `{1, 2, 3, 4}` would silently misbehave in `_hm_unify` / `_rt_row_unify`.

This matches the "defense in depth" discipline the R225 band uses: every entry point validates its byte-level input before interpreting it.

---

## 6 · Encoder discipline (paideia-as pitfalls)

- **No `test rN, rN`** — every zero-check is `cmp reg, 0; je/jne`.
- **No `and rN, imm64`** — scheme-length math uses `shl r, 2` for u32 arrays and `shl r, 4` for 16-byte node arrays; subkind check is a direct `cmp r, 1`.
- **No 2-op `imul r, imm`** — 16-byte node stride is `shl r, 4`; 4-byte u32 scratch stride is `shl r, 2`.
- **No multiline `pub let = "..."`** — single-line justifications.
- Module basename `EffectUnify` matches `effect_unify.pdx`.
- Label prefix `eu_` (unique against the sibling parser-tier modules: `u8n_`, `gi_`, `wp_`, `cl_`, `ast_`, `sch_sig_`, `cmd_sig_`, `fi_`, `afs_`, `cmdreg_`, `pl_`, `rp_`, `ll_`, `cc_`, `er_`, `cr_`, `ls_`, `hm_`, `rt_`, `dl_`, `se_`, `te_`). Never bare `loop`/`if`/`let`/`fn`/`ret`.
- All `cmp reg, imm` immediates (0, 1, 2, 3, 4, 8, 16, 32, 64, 128, status codes 0x4900..0x4907) fit imm32 with bit 31 clear.
- Byte loads via `xor r,r; mov_b r,[base + idx * 1]`; u32 loads via `xor r,r; mov_d r,[addr]`; u64 loads via plain `mov`.
- Cross-module `.bss` writes via `lea r11, [rip + sym]; mov [r11], rax` (precedent: `audit_record.pdx`, `row_types.pdx`).
- Register-liveness: r11 is clobbered by every nested CALL. Every value that must survive a nested CALL lives in r12..r15 (callee-save) or on the stack-frame scratch slot. `_eu_unify` holds the current label in r13 across each `_rt_row_select` / `_rt_row_extend` call.

---

## 7 · Acceptance corpus (30-test)

The 30-test proptest harness lives at `tests/proptest_effect_unify.pdx` (deferred to R225.M4.9 per the umbrella decomposition). The enumeration below is authoritative for the forthcoming test discovery.

### 7.1 `_eu_unify` acceptance (18 tests)

1. **UN-01** — `join({}, {})` = `{}`. Verify empty + empty collapses to a single ROW_EMPTY node.
2. **UN-02** — `join({io}, {})` = `{io}`. Single-label vs empty.
3. **UN-03** — `join({}, {io})` = `{io}`. Reverse of UN-02 (commutativity spot-check).
4. **UN-04** — `join({io}, {io})` = `{io}`. Dedup collapse on identical label.
5. **UN-05** — `join({io}, {mem})` = `{io, mem}`. Two disjoint singletons.
6. **UN-06** — `join({io, mem}, {io, mem})` = `{io, mem}`. Full-set dedup.
7. **UN-07** — `join({io, mem}, {mem, trap})` = `{io, mem, trap}`. Partial overlap.
8. **UN-08** — `join({io, mem, caps}, {trap, allocates, sysreg})` = `{io, mem, caps, trap, allocates, sysreg}`. Six-element disjoint union (covers all primitives).
9. **UN-09** — `join({io, rho_a}, {})` = `{io, rho_a}` (semantically; the actual tail is a FRESH ROW_VAR because `_eu_unify` cannot preserve rho_a's identity — see §2.2). Verify fresh-var tail is minted on the open side.
10. **UN-10** — `join({}, {io, rho_b})` = `{io, rho_fresh}`. Symmetric to UN-09.
11. **UN-11** — `join({io, rho_a}, {mem, rho_b})` = `{io, mem, rho_fresh}`. Both sides open; fresh var minted.
12. **UN-12** — `join({io}, {io, rho_b})` = `{io, rho_fresh}`. One side open with dup label.
13. **UN-13** — `join({io, io}, {mem})` = `{io, mem}`. Input row contains a duplicate (allowed by R224.M3 M3-raw); dedup must still fire.
14. **UN-14** — `join` on a row with `KIND_MISMATCH` on the cursor (manually-constructed TyApp pool node, not a TyRow): returns `(0 << 32) | EU_ERR_KIND_MISMATCH (0x4900)`.
15. **UN-15** — `join` with 16 labels in row_a + 1 label in row_b (total raw = 17): succeeds, dedup produces at most 17 unique labels (OK if the user-declared alphabet admits).
16. **UN-16** — `join` with 16 labels in row_a + 16 labels in row_b (total raw = 32, at the cap): succeeds iff dedup collapses enough to fit the pool; otherwise returns `EU_ERR_POOL_FULL (0x4901)` on build.
17. **UN-17** — `join` with 17 labels in row_a: returns `EU_ERR_TOO_MANY (0x4905)` (per-row cap exceeded).
18. **UN-18** — `join` with 16 unique labels in row_a + 17 labels in row_b: returns `EU_ERR_TOO_MANY (0x4905)` on the second row's 17th label (per-row cap).

### 7.2 `_eu_check_rank` acceptance (8 tests)

19. **CR-01** — Monomorphic scheme (n_bound=0, n_body=1, body=TyCon(u64)): returns `EU_OK`.
20. **CR-02** — Polymorphic identity scheme (n_bound=1, bound_var_ids=[0], n_body=1, body=TyVar(0)): returns `EU_OK`.
21. **CR-03** — Row-polymorphic scheme (n_bound=1, bound_var_ids=[0], n_body=4, body = TyApp(TyApp(TyCon(fn), TyVar(0)), TyRow(VAR, 0))): returns `EU_OK` at M4 (the row-var is at outermost quantifier by wire-format construction).
22. **CR-04** — Truncated scheme (scheme_len = 6, header says n_body=1): returns `EU_ERR_BAD_SCHEME (0x4903)`.
23. **CR-05** — Overrun scheme (scheme_len = 32, header declares size 24): returns `EU_ERR_BAD_SCHEME`.
24. **CR-06** — Oversized bound-var list (n_bound=65): returns `EU_ERR_BAD_SCHEME`.
25. **CR-07** — Oversized body-node list (n_body=129): returns `EU_ERR_BAD_SCHEME`.
26. **CR-08** — Body node with illegal kind byte (e.g. kind=7): returns `EU_ERR_BAD_SCHEME`.

### 7.3 `_eu_least` acceptance (4 tests)

27. **LE-01** — `least([])` = `(0 << 32) | EU_ERR_EMPTY_ARRAY (0x4904)`. Empty input rejected.
28. **LE-02** — `least([{io}])` = `{io}`. Single-row identity.
29. **LE-03** — `least([{io}, {mem}, {trap}])` = `{io, mem, trap}`. Three-row fold.
30. **LE-04** — `least` on 17 rows: returns `EU_ERR_TOO_MANY (0x4905)` (join-arity cap).

### 7.4 Fingerprint discipline

Each test's expected output is the TRIPLE (final rax status, row's packed label set, tail flavour) which the harness renders as a stable 32-byte fingerprint. The 30-test corpus's goldens live in `tests/fingerprints/effect_unify.golden`.

---

## 8 · Error-band layout

`EU_*` codes occupy the 0x4900..0x49FF band (eight slots used at M4):

| Constant                              | Value   | Meaning                                                         |
|---------------------------------------|---------|-----------------------------------------------------------------|
| `EU_OK`                               | `0`     | Operation succeeded.                                            |
| `EU_ERR_KIND_MISMATCH`                | `0x4900` | A walked cursor's kind byte is not `HM_KIND_TYROW (4)`.         |
| `EU_ERR_POOL_FULL`                    | `0x4901` | HmCore pool exhausted during `_rt_row_var` / `_rt_row_extend`.  |
| `EU_ERR_RANK_RESTRICTED_VIOLATION`    | `0x4902` | Reserved for M4.1 nested-quantifier wire format.                |
| `EU_ERR_BAD_SCHEME`                   | `0x4903` | Scheme byte stream malformed (header/body/bounds).              |
| `EU_ERR_EMPTY_ARRAY`                  | `0x4904` | `_eu_least` with `n == 0`.                                      |
| `EU_ERR_TOO_MANY`                     | `0x4905` | Per-row label cap (16) or join-arity cap (16) exceeded.         |
| `EU_ERR_ROWVAR_OCCURS`                | `0x4906` | Reserved for M4.2 inner-subterm Rémy unify arm (row-var cycle). |
| `EU_ERR_UNIFY_INCONSISTENT`           | `0x4907` | Reserved for M4.2 inner-subterm Rémy unify arm (type conflict). |

Slots 0x4908..0x49FF reserved for R225.M4.1+ follow-ups (effect-flow error chains, label-alphabet domain errors, per-session effect-decl collision diagnostics).

The 0x4900..0x49FF carve-out sits on a kilo-step boundary disjoint from every prior landed wave's bands:

- Wave 121: 0x4000..0x40FF R224.M3 EffectRow, 0x4200..0x42FF R221.M4 CtxLexer, 0x4300..0x43FF R224.M4 CapRow.
- Wave 122: 0x4400..0x44FF R221.M5 Ast, 0x4500..0x45FF R222.M5 CmdRegistry, 0x4600..0x46FF R224.M5 LetScope.
- Wave 123 (parallel R221.M6 + R222.M6 arms): 0x4700..0x47FF, 0x4800..0x48FF.

A compound-error dispatcher reads `(status & 0xFF00) == 0x4900` to attribute an EffectUnify fault; the eight slots within the band disambiguate the specific failure mode.

---

## 9 · Forward path

- **R225.M4.1** — HmCore wire-format extension landing nested-quantifier body nodes (new `HM_KIND_FORALL = 5` kind with per-node `bound_var_ids` list). THIS is where `EU_ERR_RANK_RESTRICTED_VIOLATION` becomes reachable: `_eu_check_rank` learns to descend and refuse any inner bound-var declaration whose kind resolves to `HM_KIND_TYROW` + `RT_SUBKIND_VAR`.
- **R225.M4.2** — Inner-subterm Rémy unify arm in `_eu_unify`. When both inputs carry open tails, bind `rho_a := rho_fresh` and `rho_b := rho_fresh` via `_rt_row_unify` on each pivot. Reserves `EU_ERR_ROWVAR_OCCURS` (row-var cycle during pivot) and `EU_ERR_UNIFY_INCONSISTENT` (per-pivot type-level conflict bubbled up from `_rt_row_unify`).
- **R225.M4.3** — Capability-row join (parallel to effect-row join; R224.M4 CapRow uses the same encoding). The implementation is already alphabet-generic; the parallel landing is a renaming exercise.
- **R225.M4.4** — Per-session effect-label alphabet override: when a session declares additional effect labels via a future `_er_declare` (R224.M3.6), the join result labels remain valid (packed-id identity preserved by the opaque u32 comparison).
- **R225.M4.5** — Row-fingerprint caching: a per-REPL turn LRU keyed on `(row_a, row_b)` + hashed label-set signatures, so repeated joins across a tight REPL loop skip the walk/build cost. The cache invariant: a stable `(row_a_shape, row_b_shape) -> row_result` map that survives per-turn pool-reset.
- **R225.M4.6** — Hybrid record/effect typing: an arrow `(A -> B !{row})` carrying BOTH a per-arg record-row and an effect-row. The typechecker's unify driver chains `_rt_row_unify` on the record-row with `_eu_unify` on the effect-row; this landing provides the mechanism.
- **R225.M4.9** — 30-test proptest corpus + fingerprint goldens (per §7).

---

## 10 · Co-landing / parallel discipline

R225.M4 lands in a Wave-123 parallel-dispatch batch alongside R221.M6 and R222.M6 (parent brief). The three arms touch:

- **Disjoint .bss state:** `_eu_label_scratch` (128 B) is a fresh carve-out; no aliasing with any prior satellite's scratch.
- **Disjoint error bands:** 0x4900..0x49FF is unused prior to this landing; sibling R221.M6 arm uses 0x4700..0x47FF; sibling R222.M6 arm uses 0x4800..0x48FF.
- **Disjoint label prefix:** `eu_` is unique against every satellite's prefix (`u8n_`, `gi_`, `wp_`, `cl_`, `ast_`, `sch_sig_`, `cmd_sig_`, `fi_`, `afs_`, `cmdreg_`, `pl_`, `rp_`, `ll_`, `cc_`, `er_`, `cr_`, `ls_`, `hm_`, `rt_`, `dl_`, `se_`, `te_`).
- **Disjoint design docs:** this file; sibling arms have their own docs.
- **Shared surfaces:** only `src/lib.pdx` manifest and `CHANGELOG.md` / `STATUS.md`; the parallel-CHANGELOG scratch at `.plans/scratch/CHANGELOG-R225M4.md` isolates this arm's stanza draft which main consolidates at wave close.

---

## 11 · Linker dependencies

`libpdx-pds-parser.R225.M4` (`effect_unify.pdx`) has NO external cross-library linker dependencies. It introduces TWO intra-library dependencies:

- **R225.M2 RowTypes** (`row_types.pdx`) — called at:
  - `_rt_find` — resolve a walk cursor through the TyVar / ROW_VAR resolved chain. `_eu_unify` calls this at the head of every walk loop iteration.
  - `_rt_row_empty` — allocate the closed tail of the join row (`_eu_unify` build phase when neither input carries ROW_VAR tail).
  - `_rt_row_var` — allocate the fresh ROW_VAR tail of the join row (`_eu_unify` build phase when at least one input carries ROW_VAR tail).
  - `_rt_row_extend` — prepend a ROW_EXT with packed label id onto the accumulator (`_eu_unify` build phase, once per unique label).
  - `_rt_row_select` — dedup check against the current accumulator (`_eu_unify` build phase).

- **R225.M1 HmCore** (`hm_core.pdx`) — touches ONLY the shared `.bss` row-graph pool indirectly, via the R225.M2 primitives above. The `_hm_pool` `.bss` symbol IS loaded by this module's `_eu_unify` via `lea r11, [rip + _hm_pool]` to compute node addresses on walked cursors (same precedent as EffectRow + CapRow).

`_eu_check_rank` is a pure byte walker over caller-supplied data; no cross-module reference.

`_eu_least` calls `_eu_unify` intra-module; no cross-module reference.

All three public entry points can be linked against the RowTypes/HmCore objects that R225.M1/M2 already consume; no new cross-library dependency is introduced.

`consumed_kinds`: none. Effect rows are pure type-level artefacts; no KIND surface is touched by this module (effect lattice evaluation runs purely in parse/typecheck time, not against the kernel's cap table or any other KIND surface).

---

## 12 · References

- Rémy, D. (1992). *Projective ML.* ACM LISP and Functional Programming.
- Damas, L.; Milner, R. (1982). *Principal type-schemes for functional programs.* POPL.
- Leijen, D. (2017). *Type Directed Compilation of Row-Typed Algebraic Effects.* POPL.
- Lindley, S.; Cheney, J. (2012). *Row-based Effect Types for Database Integration.* TLDI.
- paideia-os#2683 — R225.M2 RowTypes design and implementation.
- paideia-os#2677 — R224.M3 EffectRow design and implementation.
- paideia-os#2682 — R225.M1 HmCore design and implementation.
- paideia-os#2489 — R225 typechecker umbrella issue.
