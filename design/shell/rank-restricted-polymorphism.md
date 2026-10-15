# Rank-Restricted Let-Polymorphism Enforcement (P10)

**Issue:** paideia-os#2687 (R225.M6)
**Umbrella:** paideia-os#2489 (R225 HM typechecker)
**Satellite:** `tools/user/libpdx-pds-parser/src/rank_check.pdx`
**Status:** landed Wave 129.
**Design-tier wave convention:** per
`design/terminal/semantic-shell-language-plan.md` §R225 and the
Novel-Clean-Design directive (prefer standard-HM rank-1 over the
System-F generality that Haskell adopts with `-XRankNTypes`; the
user-facing surface stays first-order unification-friendly).

## 1. Scope and motivation

Standard Hindley–Milner (Milner 1978 §4; Damas–Milner POPL 1982
§3.2) is a *rank-1* language: every type scheme has the shape

```
σ ::= ∀a_1 ... a_n. τ
```

where `τ` is a monotype — no `∀` under an arrow. A *rank-2* scheme

```
∀a_1 ... a_n. (∀b_1 ... b_m. τ_arg) → τ_result
```

carries a nested quantifier in the arrow's domain, which first-order
unification cannot resolve without higher-order matching (undecidable
in general; Huet 1973). System F (Girard 1972) lifts this restriction
at the cost of explicit type abstraction / application syntax; Haskell
exposes rank-2+ behind `-XRankNTypes` + required annotations at the
boundary (Peyton Jones, Vytiniotis, Weirich, Shields JFP 2007
"Practical type inference for arbitrary-rank types").

paideia-shell commits to **rank-1 by default** because:

1. **Soundness-first.** First-order unification in `_hm_unify` has
   principal types; higher-rank schemes defeat principality and
   require type annotations the shell user did not write.
2. **Diagnostics-first.** A nested `∀` with no annotation produces
   a crisp refusal pointing at the exact binding (`E0980`), rather
   than a cascading "ambiguous type variable" error two files away.
3. **Novel-but-grounded.** We are explicit about the research
   lineage (Milner / Damas-Milner / Peyton-Jones) and the escape
   hatch (M6.3 annotation-at-boundary surface syntax) rather than
   silently inheriting a POSIX-shaped language that mixes untyped
   dynamic dispatch with rank-N soundness holes.

R225.M6 lands the **enforcement side**: a pure byte walker that
traverses the HmCore scheme AST and rejects any body node carrying a
`TYFORALL` / `TYSCHEME` constructor. At the raw M6 wire format the
walker is forward-facing (today's HmCore wire format tops out at
`TYROW = 4`); the moment the M4.1 wire-format extension lands
nested-quantifier body nodes, this gate catches them before they
reach `_hm_unify`.

## 2. Why a dedicated walker (not a flag on `_hm_generalise`)

`_hm_generalise` (R225.M1) emits a scheme and knows the free TyVars
it quantified; it could in principle refuse to generalise when its
RHS would need rank-2. We instead land a *separate* walker because:

- **Composability.** The elaborator may synthesise a scheme that is
  rank-1 by construction, then thread it through `_te_insert_scheme`,
  then specialise via `_te_specialize` → `_hm_instantiate`, then
  re-generalise at an outer `let`. The rank check is a *post-condition*
  that applies anywhere a scheme crosses a module boundary.
- **Diagnostic locality.** The surface rejection sits at the
  binding, not inside `_hm_generalise`'s TyVar walk. The user sees
  "this `let` binding needs a rank-2 scheme; add an annotation" —
  not "typecheck failed deep inside algorithm W".
- **M4.1 symmetry.** `_eu_check_rank` (R225.M4) already validates
  the P10 rank constraint over the SAME wire format as a shape check
  (its `EU_ERR_RANK_RESTRICTED_VIOLATION` slot is reserved for the
  M4.1 nested-quantifier form). R225.M6's `_rc_check_scheme` extends
  that walker with the ACTIVE rejection semantics; the two modules
  share a diagnostic family (0x4902 EffectUnify-reserved vs 0x5810
  RankCheck-active) so a dispatcher can tell "shape malformed" apart
  from "rank-2 refused".

## 3. The rank-1 definition in HmCore wire-format terms

A scheme is a flat byte stream (per `src/hm_core.pdx` §SCHEME WIRE FORMAT):

```
[+0]   u32  n_bound_vars
[+4]   u32  n_body_nodes
[+8]   u32[n_bound_vars]   bound_var_ids   (sorted ascending)
[+8 + 4*n_bound_vars]
       TypeNode[n_body_nodes]   body       (16-byte stride each)
```

The *outer* `∀` is encoded in the header's `bound_var_ids` array —
the elaborator mints fresh TyVar ids and lists them here. The body
nodes represent `τ` (the quantified monotype). A rank-1 scheme has
*only* monotype constructors in its body:

```
HM_KIND_TYVAR    = 1
HM_KIND_TYCON    = 2
HM_KIND_TYAPP    = 3
HM_KIND_TYROW    = 4   (R225.M2 Rémy-row extension)
```

A rank-2 scheme would carry a *nested* quantifier under some body
node — which requires an EXTENSION to the wire format:

```
HM_KIND_TYFORALL = 5   (reserved for R225.M4.1 wire-format extension)
HM_KIND_TYSCHEME = 6   (reserved for R225.M4.1 wire-format extension)
```

The current `_hm_generalise` cannot emit kinds 5 or 6 (its switch
only has arms for 1..4); so a well-formed scheme produced by today's
elaborator ALWAYS passes `_rc_check_scheme`. The validator is
forward-facing: the moment the M4.1 extension lands and the body
can carry a nested quantifier, this walker rejects it unless the
caller supplies an explicit annotation that bypasses the gate (the
annotation itself materialises the rank-2 scheme OUT OF BAND via a
separate `_hm_build_rank2_scheme` entry at M6.3).

## 4. The rank violation discriminator

`_rc_check_scheme` walks body nodes and dispatches on the kind byte:

| kind | name       | action                                              |
|------|------------|-----------------------------------------------------|
| 1    | TYVAR      | continue                                            |
| 2    | TYCON      | continue                                            |
| 3    | TYAPP      | continue                                            |
| 4    | TYROW      | continue                                            |
| 5    | TYFORALL   | reject — see sub-dispatch                           |
| 6    | TYSCHEME   | reject — see sub-dispatch                           |
| other| (unknown)  | reject with `RC_ERR_BAD_SCHEME`                     |

The sub-dispatch for kinds 5/6 discriminates:

- `i == 0` (the root body node) → `RC_ERR_NESTED_FORALL` (0x5811 =
  E0981). The header already carries the single outer `∀`; a root
  quantifier body node means the scheme is doubly-quantified at the
  root (`∀a. ∀b. τ` with both quantifiers in the body position),
  which is a wire-format bug the elaborator should never emit.

- `i > 0` (some non-root body node) → `RC_ERR_RANK_TOO_HIGH` (0x5810
  = E0980). The quantifier sits under *some* parent body node, which
  is the standard rank-2 refusal case — the user needs an explicit
  annotation at the function boundary.

A finer-grained discriminator (`RC_ERR_PREDICATIVE_VIOLATION` 0x5812
when the parent is a type constructor rather than a function arrow)
is **deferred to R225.M6.2** because the current TyApp body node
encoding does not expose head-discrimination (M4.1 wire-format
extension adds the `arity` byte usage to distinguish "function
application" from "type-constructor application").

## 5. Composite entry `_rc_check_binding`

The LetScope frame kind discriminates binding generalisation
semantics (per `src/let_scope.pdx` §HM STANDARD SEMANTICS):

- `SCOPE_LAMBDA` (3) — lambda parameter. **Not** generalised per
  standard HM (parameters are monotype-typed; generalisation happens
  at `let` boundaries only). `_rc_check_binding` returns `RC_OK`
  without walking the scheme bytes.
- `SCOPE_LET` (1) — `let x = e in body`. Generalised iff `e`'s type
  has no free TyVars bound by the enclosing scope. Rank check
  applies to the resulting scheme.
- `SCOPE_LETREC` (2) — `let rec f = e in body`. `f` is in scope on
  its own RHS; generalisation defers until the RHS is typed.
  Rank check applies to the resulting scheme.

`_rc_check_binding(scope_kind, scheme_ptr, scheme_len)` centralises
this three-way dispatch so each HM-elaborator call site does not
have to replicate the lambda-param short-circuit. The signature uses
*explicit* scope_kind + scheme bytes rather than a LetScope frame
pointer because raw M6 does not have a materialiser from a HmCore
pool_idx to a scheme byte stream (`type_scheme_ref` in a frame is
caller-opaque: HmCore pool_idx or TypeEnv scheme_id). M6.4 wires the
frame dereference once the materialiser lands.

## 6. Status band and diagnostic mapping

Band `0x5800..0x58FF` (eight slots used; `0x5814..0x58FF` reserved for
M6.1+ follow-ups):

| code     | name                              | diagnostic              | meaning                                       |
|----------|-----------------------------------|-------------------------|-----------------------------------------------|
| 0        | `RC_OK`                           | —                       | scheme passes the rank gate                   |
| 0x5800   | `RC_ERR_BAD_SCHEME`               | —                       | scheme byte stream malformed (shape fault)    |
| 0x5810   | `RC_ERR_RANK_TOO_HIGH`            | E0980                   | nested `∀` under some body node (rank-2+)     |
| 0x5811   | `RC_ERR_NESTED_FORALL`            | E0981                   | nested `∀` at the root (double-quantified)    |
| 0x5812   | `RC_ERR_PREDICATIVE_VIOLATION`    | E0982                   | reserved for M6.2 (head-discriminated reject) |
| 0x5813   | `RC_ERR_UNANNOTATED_BOUNDARY`     | E0983                   | reserved for M6.3 (annotation-at-boundary)    |

**Disjointness proof.** The band is disjoint from every landed
packed-status range in the paideia-os tree:

- parser-tier bands at R221 (0x2700, 0x3800, 0x3F00, 0x4200, 0x4400,
  0x4700, 0x4A00), R222 (0x2A00, 0x3300, 0x3900, 0x3C00, 0x4500,
  0x4800, 0x4F00), R223 (0x2B00, 0x3400, 0x4C00, 0x4D00, 0x5200,
  0x5300, 0x5500), R224 (0x2C00, 0x3500, 0x4000, 0x4300, 0x4600,
  0x5000, 0x5600), R225 (0x2D00, 0x3600, 0x4900), R226 (0x2E00),
  R229 (0x3000, 0x3700, 0x3D00, 0x4E00, 0x5100, 0x5400, 0x5700).
- Grep at landing time: `grep -rE '0x58(0[0]|1[0-3])\b'
  paideia-os/{src,tools,design,tests}` returns no prior hits (band
  virgin).

## 7. Public API

Register maps (SysV):

```
_rc_init()                                               -> rax (ignored)
_rc_check_scheme(scheme_ptr, scheme_len)                 -> rax
_rc_check_binding(scope_kind, scheme_ptr, scheme_len)    -> rax
```

- `_rc_init` — bare `ret`. Raw M6 holds NO `.bss` state; kept for
  parallelism with the parser-family init-hook convention so an M6.1
  landing that adds `.bss` (per-REPL-turn violation counter) does
  not break the API.

- `_rc_check_scheme(rdi, rsi) -> rax` — pure byte walker. Zero
  callee-save pushes; no stack frame; no nested CALL. Returns
  packed status in rax (not packed with a payload — the walker is
  decision-only).

- `_rc_check_binding(rdi, rsi, rdx) -> rax` — composite entry. Zero
  callee-save pushes + `sub rsp, 8` (align) + single intra-module
  nested CALL to `_rc_check_scheme`. Returns the delegate's status
  verbatim on SCOPE_LET / SCOPE_LETREC; `RC_OK` on SCOPE_LAMBDA
  short-circuit; `RC_ERR_BAD_SCHEME` on out-of-range scope_kind.

## 8. Dependencies

**No cross-library linker dependencies.** `_rc_init` and
`_rc_check_scheme` touch only caller-supplied pointer args; the
scheme byte stream is passed in by the caller as a flat buffer (no
cross-module CALL into HmCore or any other library). `_rc_check_binding`
calls `_rc_check_scheme` intra-module. All three public entry points
can be linked standalone against a bare parser-tier object graph.

**No intra-library linker dependencies at raw M6.** The scheme wire
format constants (`HM_KIND_*`, `HM_SCHEME_*`) are duplicated as
module-local constants (precedent: every parser-family satellite
that mirrors HmCore / row_types / effect_row constants). The M6.4
LetScope-frame dereferencing landing introduces a one-way dep on
`_ls_resolve` + a HmCore scheme-materialiser (yet to land).

## 9. Acceptance — 20-test adversarial corpus

Deferred to `tests/proptest_rank_check.pdx` (R225.M6.5 follow-up).
The twenty representative cases this harness will exercise:

**Well-formed rank-1 schemes (10 cases; expected `RC_OK`):**

1. `∀. int → int` — zero bound vars; one TyCon body node for `int`;
   trivial monotype. Scheme bytes = `0, 1, {TYCON(con_id=1)}`.
2. `∀a. a → a` — identity. One bound var; three body nodes:
   TYAPP(0,1), TYVAR(bound 0), TYCON(fn arrow).
3. `∀a b. a → b` — pair. Two bound vars; three TyApp/TyVar nodes.
4. `∀a. list a → list a` — polymorphic list. TyApp of TyCon list
   over TyVar.
5. `∀a. {foo: a, bar: int, rho}` — Rémy row (R225.M2 TyRow kind).
6. `∀. () → ()` — nullary. Both arrow operands are TyCon unit.
7. `∀. (int, str) → bool` — concrete triplet.
8. `∀a. ∀. a → a` (bound-vars = {a} but 2nd ∀ empty) — degenerate
   empty-nested; passes because body is still monotype.
9. `∀a. ref a → ()` — side-effect-sentinel; TyCon ref + TyVar a.
10. `∀a. (a → a) → a → a` — fixed-point combinator shape; monotype
    body (arrow with arrows under it, no ∀).

**Rank-boundary rejections (10 cases; expected non-OK):**

11. `∀. ∀a. a → a` body = TYFORALL at root → `RC_ERR_NESTED_FORALL`.
12. `∀a. a → ∀b. b → b` → nested `∀` under outer arrow →
    `RC_ERR_RANK_TOO_HIGH`.
13. `∀a. (∀b. b → b) → a → a` → inner `∀b` as arrow domain →
    `RC_ERR_RANK_TOO_HIGH`.
14. `∀a. list (∀b. b)` → predicative-polymorphism violation (nested
    ∀ as TyApp arg) — raw M6 reports `RC_ERR_RANK_TOO_HIGH` (M6.2
    refines to `RC_ERR_PREDICATIVE_VIOLATION`).
15. `∀a b. ∀c. a → b → c` → nested forall at body root with outer
    bound-vars → `RC_ERR_NESTED_FORALL`.
16. Malformed header: `scheme_len = 7` → `RC_ERR_BAD_SCHEME` (header
    truncated).
17. `n_bound_vars = 65` → `RC_ERR_BAD_SCHEME` (exceeds bound).
18. `n_body_nodes = 0` → `RC_ERR_BAD_SCHEME` (empty body).
19. `scheme_len` mismatch with header-computed size →
    `RC_ERR_BAD_SCHEME`.
20. Body node with unknown kind byte (e.g. 7, 42, 0xFF) →
    `RC_ERR_BAD_SCHEME`.

The ten rejection cases are the acceptance anchor from the issue
brief ("20-test corpus of rank-boundary cases; each rejected with
`E0980`-family diagnostic") — the ten accepted cases are the
negative control that proves the walker does not over-reject.

## 10. Encoder discipline

All paideia-as pitfalls (per `feedback_pdx_encoder_pitfalls`) are
addressed:

- **No `test rN, rN`.** Every zero-check is `cmp reg, 0; je/jne`.
- **No `and r11, imm64`.** Band values 0x5800..0x58FF fit imm32 with
  bit 31 clear.
- **No 2-op `imul r, imm`.** 16-byte node stride is `shl r, 4`;
  4-byte u32 scratch stride is `shl r, 2`.
- **No multiline `pub let = "..."`.** Single-line justifications.
- **Module basename matches file.** `RankCheck` ↔ `rank_check.pdx`.
- **Fingerprint tag size.** No fingerprint emission at raw M6
  (M6.1 landing adds the per-REPL-turn violation counter and its
  fingerprint stanza).
- **Register liveness.** `_rc_check_scheme` is a pure leaf (zero
  nested CALL; r11 scratch-free). `_rc_check_binding` has one
  nested CALL + `sub rsp, 8` for SysV alignment; no callee-save
  push needed because the three argument registers rdi/rsi/rdx are
  either consumed verbatim or overwritten by the delegate call
  setup.
- **Label prefix.** `rc_` — grep-confirmed unique against every
  landed parser-tier prefix.

## 11. Forward path

| milestone | scope                                                        |
|-----------|--------------------------------------------------------------|
| R225.M6.1 | `.bss` violation counter + per-REPL-turn fingerprint         |
| R225.M6.2 | `RC_ERR_PREDICATIVE_VIOLATION` wire-up (needs M4.1 head bit) |
| R225.M6.3 | `RC_ERR_UNANNOTATED_BOUNDARY` wire-up (needs R224 syntax ext)|
| R225.M6.4 | `_rc_check_binding` dereferences a LetScope frame directly   |
| R225.M6.5 | 20-test adversarial corpus + fingerprint goldens             |

## 12. Related docs

- `design/shell/hm-algorithm-w-core.md` — R225.M1 HmCore scheme wire
  format + unify/instantiate/generalise kernel.
- `design/shell/effect-row-unification.md` — R225.M4 EffectUnify's
  `_eu_check_rank` shape-validator precedent.
- `design/shell/let-in-scoping.md` — R224.M5 LetScope frame layout
  and SCOPE_LAMBDA/SCOPE_LET/SCOPE_LETREC discriminators.
- `design/shell/row-types-remy.md` — R225.M2 Rémy-row primitives +
  shared `_hm_pool`.
- `design/shell/type-env-threading.md` — R229.M3 TypeEnv scheme
  store + specialisation cache.
- `design/terminal/semantic-shell-language-plan.md` §R225 — the
  umbrella roadmap carrying the P10 constraint.

## 13. ABI freeze

Three public entry points at raw M6:

- `_rc_init()                                             -> ()`
- `_rc_check_scheme(scheme_ptr: u64, scheme_len: u64)     -> u64`
- `_rc_check_binding(scope_kind: u64, scheme_ptr: u64, scheme_len: u64) -> u64`

Status codes `0x5800..0x5813` are stable; `0x5814..0x58FF` reserved
for M6.1+ follow-ups. Kind constants (`RC_HM_KIND_*`) mirror HmCore
and are frozen with the HmCore wire format; the M4.1 extension
adds kinds 5/6 which this module already recognises and rejects.
