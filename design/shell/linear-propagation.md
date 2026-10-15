# Linear/affine propagation across lambda capture — R224.M7

**Issue:** paideia-os#2681
**Umbrella:** R224 (lambda-lang, paideia-os#2488)
**Satellite:** `tools/user/libpdx-pds-parser` (user-space; `src/linear_propagate.pdx`)
**Primary citation:** Walker, D. *Substructural Type Systems*, in
B. C. Pierce (ed.), *Advanced Topics in Types and Programming
Languages* (MIT Press, 2005), chapter 1.
**Related substrate:**
`design/shell/closure-capture.md` (R224.M2 ClosureCapture — the record
this module walks),
`design/shell/capability-row-typing.md` (R224.M4 CapRow — the Q-A2
substructural-lattice sibling),
`design/shell/let-in-scoping.md` (R224.M5 LetScope — the scope-pop
site at which the M7.2 wire-up calls `_lp_check_use`),
`design/shell/lambda-as-pipeline-value.md` (R224.M6 PipelineLambda —
the record that persists the propagated kind at M7.5).

**Design axis:** Q-A2 (substructural capability lattice) composed with
Walker 2005's propagation rule across lambda capture.

**Status at this landing:** M7 lands the lattice-aware primitives
`_lp_init` / `_lp_meet` / `_lp_join` / `_lp_check_use` /
`_lp_classify_lambda`. All five are pure leaves with no `.bss`. The
10-test acceptance corpus in §7 enumerates the linear-capture cases
and the expected propagated kind for each.

---

## 1 · Scope and motivation

A lambda that CLOSES OVER a linear binding cannot itself be
unrestricted — if a caller duplicated or dropped the lambda, the
linear binding inside it would be duplicated or dropped alongside,
violating its single-use discipline. Walker 2005 §1.3 captures this
constraint as a one-line propagation rule:

> If a function body `e` closes over free variables `x₁:τ₁, …, xₙ:τₙ`
> with substructural kinds `κ₁, …, κₙ`, then the function value has
> kind `κ₁ ⊔ κ₂ ⊔ … ⊔ κₙ` (lattice JOIN).

The semantic-shell language carries lambdas through pipelines, binds
them in `let` scopes, flows them across process boundaries. Each of
those is a point at which an UNRESTRICTED-tagged lambda is free to be
duplicated by the runtime (store it in a session variable; call it
twice; broadcast it) — and each of those is a point at which a LINEAR
or AFFINE binding closed over by the lambda would have its discipline
silently violated.

The elaborator must therefore CLASSIFY every lambda it elaborates and
PERSIST the kind through the parsing tier so the HM pass and the
runtime can refuse the duplicative operations downstream. R224.M7 is
the parser-tier substrate for that classification.

---

## 2 · The substructural lattice

Walker 2005 §1.3 names four substructural kinds along the two
independent structural rules of a Gentzen-style sequent calculus:

* **Weakening** (also "drop"): a bound variable can be discarded
  without using it.
* **Contraction** (also "dup"): a bound variable can be used more
  than once.

Each kind corresponds to one of the four possible subsets of
`{weakening, contraction}`:

| kind              | numeric | weakening? | contraction? | semantics            |
|-------------------|---------|------------|--------------|----------------------|
| UNRESTRICTED      | 0       | yes        | yes          | both allowed         |
| AFFINE            | 1       | yes        | NO           | use at-most-once     |
| RELEVANT          | 2       | NO         | yes          | use at-least-once    |
| LINEAR            | 3       | NO         | NO           | use exactly-once     |

The lattice ordering is "more-restrictive at the top":

```
                 LINEAR (3)
                /         \
         AFFINE (1)      RELEVANT (2)
                \         /
              UNRESTRICTED (0)
```

AFFINE and RELEVANT are INCOMPARABLE — neither restriction implies
the other. The lattice is therefore NOT a chain.

### 2.1 · The two-bit encoding

R224.M7 encodes each kind as a two-bit mask over the restriction set:

* `bit 0 == 1` ⇔ contraction (dup) is forbidden
* `bit 1 == 1` ⇔ weakening (drop) is forbidden

Mapping to the task's numeric encoding:

* UNRESTRICTED = `0b00` = 0
* AFFINE       = `0b01` = 1 (no dup; drop OK)
* RELEVANT     = `0b10` = 2 (dup OK; no drop)
* LINEAR       = `0b11` = 3 (no dup; no drop)

Under this encoding the lattice operations are single-instruction:

* `JOIN(a, b) = a | b` (union of restrictions — "the stronger kind")
* `MEET(a, b) = a & b` (intersection of restrictions — "the weaker
  kind")

Verifying the non-trivial pair:

* `JOIN(AFFINE=1, RELEVANT=2)   = 0b01 | 0b10 = 0b11 = LINEAR` — a
  closure capturing both an AFFINE binding and a RELEVANT binding
  cannot be duplicated (AFFINE forbids it) nor dropped (RELEVANT
  forbids it); the propagated kind is LINEAR.
* `MEET(AFFINE=1, RELEVANT=2)   = 0b01 & 0b10 = 0b00 = UNRESTRICTED` —
  the shared restriction set is empty.

The lattice-aware encoding is load-bearing: changing the numeric
values of the four kinds would require rewriting `_lp_join` and
`_lp_meet` to use a lookup table.

---

## 3 · Public API

Five entry points, all PURE LEAVES (zero callee-save pushes, zero
stack frame, zero nested CALL). Register discipline is SysV AMD64.

### 3.1 · `_lp_init() -> ()`

Idempotent boot hook. The module carries no `.bss` state at raw M7;
the init exists for uniformity with every other pds-parser submodule
(`_pl_lam_init` R224.M6, `_ds_init` R222.M8, `_ha_init` R223.M6,
`_ws_init` R223.M5). Body is a bare `ret`.

### 3.2 · `_lp_meet(k1, k2) -> kind_u8`

Lattice MEET. Returns `k1 & k2` zero-extended, or `LP_UNKNOWN_KIND`
(0xFF) if either input is > `LP_KIND_LINEAR` (3).

* `rdi = k1`
* `rsi = k2`
* `rax = kind_u8` (zero-extended)

### 3.3 · `_lp_join(k1, k2) -> kind_u8`

Lattice JOIN. Returns `k1 | k2` zero-extended, or `LP_UNKNOWN_KIND`
if either input is > 3. This is the primitive Walker 2005's
propagation rule uses most.

* `rdi = k1`
* `rsi = k2`
* `rax = kind_u8`

### 3.4 · `_lp_check_use(kind, use_count) -> status`

Per-binding substructural-use discipline check:

* `UNRESTRICTED` (0): any `use_count` admissible → `LP_OK`
* `AFFINE`       (1): `use_count` in {0, 1} → `LP_OK`; else
  `LP_ERR_AFFINE_MULTI_USE`
* `RELEVANT`     (2): `use_count >= 1` → `LP_OK`; else
  `LP_ERR_RELEVANT_NOT_USED`
* `LINEAR`       (3): `use_count == 1` → `LP_OK`;
  `use_count == 0` → `LP_ERR_LINEAR_NOT_USED`;
  `use_count > 1` → `LP_ERR_LINEAR_MULTI_USE`
* `kind > 3`           → `LP_ERR_BAD_KIND`

* `rdi = kind`
* `rsi = use_count`
* `rax = status`

### 3.5 · `_lp_classify_lambda(lambda_lit_ref, closure_env_ref, env_kinds_ref, env_kinds_len) -> packed_u64`

Walker 2005's propagation rule applied over the bindings of a R224.M2
`ClosureCapture` record.

* `rdi = lambda_lit_ref` — reserved for M7.1 (user-declared kind
  override); raw M7 does NOT dereference. The caller may pass 0.
* `rsi = closure_env_ref` — pointer to the `ClosureCapture` record
  (header + binding array). If 0, the lambda has no capture list and
  the propagated kind is UNRESTRICTED (empty-set JOIN).
* `rdx = env_kinds_ref` — pointer to a `u8[env_kinds_len]` array
  giving the substructural kind of each binding slot (parallel to the
  `ClosureCapture` binding array).
* `rcx = env_kinds_len` — length of the `env_kinds_ref` array; must
  be ≥ `n_bindings` or `LP_ERR_BAD_INDEX` fires.
* `rax = (propagated_kind << 32) | status`.

Walk shape:

```
if closure_env_ref == 0:
    return (0 << 32) | LP_OK                  # empty capture → UNRESTRICTED

magic = *(u32*)(closure_env_ref + 0)
if magic != 'CCAP' (0x50414343):
    return LP_ERR_BAD_MAGIC

n_bindings = *(u16*)(closure_env_ref + 4)
if n_bindings > LP_MAX_BINDINGS (16):
    return LP_ERR_BAD_N_BINDINGS

if n_bindings == 0:
    return (0 << 32) | LP_OK                  # empty capture list → UNRESTRICTED

if env_kinds_len < n_bindings:
    return LP_ERR_BAD_INDEX

if env_kinds_ref == 0:
    return LP_ERR_NULL_PTR

acc = LP_KIND_UNRESTRICTED (0)
for i in 0..n_bindings:
    kind = env_kinds_ref[i]
    if kind > 3:
        return LP_ERR_BAD_KIND
    acc |= kind                               # inline JOIN
return (acc << 32) | LP_OK
```

The parallel-array shape (binding records in the `ClosureCapture`
record; per-binding kinds in a caller-supplied byte array) deliberately
avoids a cross-module dependency on the `ClosureCapture` binding
stride. The elaborator synthesises each binding's kind from its
elaborated type scheme before calling.

---

## 4 · Why the lambda_lit_ref is reserved and not dereferenced

Raw M7 does not look at the `LambdaHeader` record because the header
does not yet carry a user-declared kind override byte. R224.M1
reserved a tail for M3+ scratch; a future M7.1 landing will carve one
u8 out of that tail for a caller-declared kind annotation (`\linear
x -> …`). When that lands, `_lp_classify_lambda` reads the override
byte and JOINs it with the propagated kind — the caller's declared
kind can TIGHTEN the propagated kind (if the caller declares LINEAR
over captures that would propagate to UNRESTRICTED, the lambda is
LINEAR) but it cannot LOOSEN it (if the captures propagate to LINEAR,
the lambda is LINEAR regardless of what the caller declares; the HM
pass refuses the declared mismatch).

Reserving the slot at the API floor rather than at M7.1 avoids an ABI
break at the splice-point.

---

## 5 · Status band

Error band `0x5600..0x56FF`, reserved for R224.M7 at this landing.
Nine slots used; 247 slots reserved for the M7.1..M7.6 follow-ups.

| name                       | code     | meaning                                      |
|----------------------------|----------|----------------------------------------------|
| `LP_OK`                    | 0        | operation succeeded                          |
| `LP_ERR_BAD_KIND`          | 0x5600   | input kind > 3                               |
| `LP_ERR_LINEAR_NOT_USED`   | 0x5601   | LINEAR binding with use_count == 0           |
| `LP_ERR_LINEAR_MULTI_USE`  | 0x5602   | LINEAR binding with use_count > 1            |
| `LP_ERR_AFFINE_MULTI_USE`  | 0x5603   | AFFINE binding with use_count > 1            |
| `LP_ERR_RELEVANT_NOT_USED` | 0x5604   | RELEVANT binding with use_count == 0         |
| `LP_ERR_BAD_MAGIC`         | 0x5605   | `closure_env_ref` magic != 'CCAP'            |
| `LP_ERR_NULL_PTR`          | 0x5606   | `env_kinds_ref` null with n_bindings > 0     |
| `LP_ERR_BAD_INDEX`         | 0x5607   | `env_kinds_len` < n_bindings                 |
| `LP_ERR_BAD_N_BINDINGS`    | 0x5608   | n_bindings > `LP_MAX_BINDINGS` (16)          |

Disjointness verified at landing time: `grep -rE '0x56[0-9A-F]{2}'
tools/user/libpdx-pds-parser/` returns no prior hits. The sibling
R223.M7 band at `0x5500..0x55FF` is reserved for the parallel-arm
primitive and is not touched by this landing.

---

## 6 · Encoder discipline (absolute)

All five entry points obey the paideia-as encoder discipline:

* No `test rN, rN` — every zero-check is `cmp reg, 0; je/jne`.
* No `and rN, imm64` — every mask is imm8 or imm32. The two-bit kind
  band fits in imm8 trivially.
* No two-operand `imul r, imm` — `_lp_classify_lambda`'s per-iteration
  index step is `add r9, 1` (byte stride for `env_kinds_ref` is 1, so
  no multiplication is needed).
* No multiline `pub let = "..."` — justifications are single-line.
* Module basename `LinearPropagate` matches `linear_propagate.pdx`.
* Public symbols prefixed `_lp_*`; internal labels prefixed `lp_*`
  with per-function suffixes: `lp_ini_`, `lp_mt_`, `lp_jn_`, `lp_cu_`,
  `lp_cl_`.
* The `lp_` prefix is grep-disjoint from every sibling satellite's
  prefix in this library.
* All `cmp reg, imm` immediates fit in imm32 with bit 31 clear so
  direct `cmp reg, imm32` is sign-extension safe. Status codes
  (0x5600..0x5608), lattice bounds (0, 1, 2, 3), binding cap
  (`LP_MAX_BINDINGS` = 16), and the `ClosureCapture` magic
  (0x50414343) all meet this bound.
* Byte loads via `xor rax, rax; mov_b rax, [base + idx * 1]` with
  explicit `*1` scale (U1606 mitigation precedent from
  `pipeline_lambda.pdx`).
* u16 reads via two `mov_b` byte reads: low byte at `[+4]`, high byte
  at `[+5]`, shifted and OR'd.
* u32 reads via `xor rax, rax; mov_d rax, [base + imm_disp]` (zero
  extends into the full qword so the subsequent `cmp` against the
  imm32 magic is sign-safe).
* `r11` is used freely as a staging register inside each entry point
  because NONE of the five entry points makes a nested CALL. The
  Wave 116 register-liveness lesson (`r11` is caller-saved and never
  crosses a CALL) is not binding here.

---

## 7 · Acceptance — 10-test corpus of linear-capture cases

Each case fixes a specific `ClosureCapture` record shape plus a
caller-supplied `env_kinds` byte array, and asserts the expected
propagated kind returned by `_lp_classify_lambda`.

The corpus deliberately covers all four kinds in isolation (cases
1–5), the non-trivial `A|R=L` lattice behaviour (case 7), empty vs
populated input (cases 1, 10), and multi-binding JOINs (cases 6–10).

| # | n_bindings | env_kinds              | expected kind | rationale                       |
|---|------------|------------------------|---------------|---------------------------------|
| 1 | 0          | — (`closure_env_ref=0`)| UNRESTRICTED  | empty capture, trivial          |
| 2 | 1          | [U]                    | UNRESTRICTED  | single U → U                    |
| 3 | 1          | [A]                    | AFFINE        | single A → A                    |
| 4 | 1          | [R]                    | RELEVANT      | single R → R                    |
| 5 | 1          | [L]                    | LINEAR        | single L → L                    |
| 6 | 2          | [U, L]                 | LINEAR        | JOIN(U,L) = 0\|3 = 3            |
| 7 | 2          | [A, R]                 | LINEAR        | JOIN(A,R) = 1\|2 = 3 (lattice)  |
| 8 | 3          | [U, U, U]              | UNRESTRICTED  | JOIN over Us is 0               |
| 9 | 3          | [U, A, R]              | LINEAR        | U\|A\|R = 0\|1\|2 = 3           |
|10 | 2          | [L, L]                 | LINEAR        | JOIN(L,L) = 3 (idempotent)      |

For each case the harness:

1. Builds a `ClosureCapture` record of the specified shape by calling
   `_cc_parse` on a synthesized `[binding, …]` source string whose
   bindings' types do not matter (raw M7 does not inspect them).
   For case 1, the harness passes `closure_env_ref = 0` directly and
   skips the parse.
2. Populates `env_kinds[0..n_bindings)` with the specified byte
   values and sets `env_kinds_len = n_bindings` (the harness
   deliberately matches the length so neither `LP_ERR_BAD_INDEX` nor
   `LP_ERR_NULL_PTR` fires).
3. Calls `_lp_classify_lambda(0, closure_env_ref, env_kinds_ref,
   env_kinds_len)` and asserts `status == LP_OK` and
   `(result >> 32) == expected_kind`.

Negative-path assertions (not in the headline-10 but exercised at
M7.3+ when the diagnostic surface lands):

* `_lp_classify_lambda` on a record whose magic ≠ 'CCAP' returns
  `LP_ERR_BAD_MAGIC`.
* `_lp_classify_lambda` with `env_kinds[i] = 4` for some i returns
  `LP_ERR_BAD_KIND`.
* `_lp_classify_lambda` with `env_kinds_len < n_bindings` returns
  `LP_ERR_BAD_INDEX`.
* `_lp_classify_lambda` with `env_kinds_ref = 0` and `n_bindings > 0`
  returns `LP_ERR_NULL_PTR`.
* `_lp_classify_lambda` on a record whose `n_bindings` > 16 returns
  `LP_ERR_BAD_N_BINDINGS`.
* `_lp_check_use` on a LINEAR binding with `use_count = 0` returns
  `LP_ERR_LINEAR_NOT_USED`; with `use_count = 2` returns
  `LP_ERR_LINEAR_MULTI_USE`.
* `_lp_check_use` on an AFFINE binding with `use_count = 2` returns
  `LP_ERR_AFFINE_MULTI_USE`.
* `_lp_check_use` on a RELEVANT binding with `use_count = 0` returns
  `LP_ERR_RELEVANT_NOT_USED`.
* `_lp_meet(4, 0)` and `_lp_join(0, 4)` both return `LP_UNKNOWN_KIND`
  (0xFF).

---

## 8 · Interactions with sibling modules

* **R224.M1 LambdaLit** — raw M7 does not dereference `lambda_lit_ref`;
  it is reserved for M7.1 (user-declared kind override).
* **R224.M2 ClosureCapture** — M7 reads ONLY the record header
  (`magic` u32 at `+0`, `n_bindings` u16 at `+4`); the binding array
  is not dereferenced because the per-binding kind is caller-supplied
  in parallel via `env_kinds_ref`.
* **R224.M3 EffectRow** — orthogonal. Effects are descriptive, this
  module is prescriptive. A lambda may be LINEAR and pure (`!{}`) at
  the same time.
* **R224.M4 CapRow** — the sibling Q-A2 "substructural capability
  lattice". Both modules share the two-bit restriction-set view; they
  differ in what they RESTRICT: CapRow restricts per-cap permissions;
  this module restricts per-binding use counts. Composition at M7.6+.
* **R224.M5 LetScope** — the elaborator-side M7.2 wire-up calls
  `_lp_check_use(kind, use_count)` at `_ls_pop` time. Raw M7 does not
  make this call itself.
* **R224.M6 PipelineLambda** — the propagated kind flows into the
  PipelineLambda record's reserved tail at M7.5 via a HM-pass wire-up.
* **R225 HM typechecker** — the HM pass synthesises each binding's
  kind from its elaborated type scheme and threads the resulting
  byte array through `_lp_classify_lambda`.

---

## 9 · Forward path

| landing   | surface                                                    |
|-----------|------------------------------------------------------------|
| M7.1      | LambdaHeader kind-override byte                            |
| M7.2      | LetScope wire-up: `_ls_pop` calls `_lp_check_use`          |
| M7.3      | `E0840_*` diagnostic family                                |
| M7.4      | Let-rec recursive-capture self-edge filter                 |
| M7.5      | PipelineLambda tail byte persists propagated kind          |
| M7.6      | CapRow / LinearPropagate composition                       |

None of the forward-path landings introduces a KIND surface this
library invokes against. The parser remains a passive linker artifact.

---

## 10 · File footprint

* `tools/user/libpdx-pds-parser/src/linear_propagate.pdx` — NEW, module
  `LinearPropagate`; five public entry points (`_lp_init`, `_lp_meet`,
  `_lp_join`, `_lp_check_use`, `_lp_classify_lambda`); zero `.bss`;
  all PURE LEAVES.
* `design/shell/linear-propagation.md` — THIS doc.
* `tools/user/libpdx-pds-parser/caps.decl` — adds the
  `0x5600..0x56FF` error-band section and the R224.M7 catalogue
  paragraph.
* `tools/user/libpdx-pds-parser/src/lib.pdx` — flips
  `LPX_PDS_PARSER_R224_M7_READY` from 0 to 1, bumps
  `LPX_PDS_PARSER_VERSION_MINOR`, adds `src/linear_propagate.pdx at
  R224.M7` to the module-filename list and
  `paideia-os#2681 (R224.M7 LinearPropagate)` to the upstream list.
* `tools/user/libpdx-pds-parser/CHANGELOG.md` — gets a new stanza at
  wave close (per-primitive scratch stanza at
  `.plans/scratch/CHANGELOG-R224M7.md`).
* `tools/user/libpdx-pds-parser/STATUS.md` — flips the R224.M7
  milestone row to landed.
