# Non-milestone issue #1230 — silent-fallthrough hardening for unrecognized operators

**Repo**: paideia-os/paideia-as | **Milestone**: none (correctness hardening) | **HEAD**: `0f21ee7` (v0.18 closed; 4995 tests green)
**Filed by**: debugger during #1229 comparison-op / #1000 pattern-guard fault injection (2026-07-17).
**Root vector**: three divergent operator-lexeme lists across two crates. Adding an operator to only some of them silently miscompiles.

## 1. TL;DR

The issue's fix direction option (2) — "central operator registry" — is the correct one. Option (1) alone ("harden the emit `_ =>` catch-all") is insufficient because the primary silent path never reaches that catch-all: `is_operator_callee` divergence routes an operator App to the *function-call* code path (`emit_call_expr`), which emits either a PLT-style external reference or a colliding intra-module call — neither of which trip the operator-dispatch `match`'s fallback.

Fix in two coordinated moves:

1. **Centralize the operator lexeme set** in `paideia-as-ir::operators` (new module) with a single `KNOWN_OPERATORS` constant + `is_operator(&str) -> bool` and per-arity classifiers (`is_binary_op`, `is_unary_op`). Replace all three current filters with delegated calls.
2. **Convert every operator-dispatch `match callee_name.as_str()` catch-all into a fail-loud T0540**, and add a compile-time-triggered invariant test that iterates `KNOWN_OPERATORS` × each dispatch site to prove full coverage before every push (drift-detector canary).

T-code reuse: extend T0540 (already the emit-dispatch catch-all); do not mint a new code. Detail-message discipline lets a grep on stderr localise the exact fallthrough site.

## 2. Sites audited

Absolute paths and line numbers as of HEAD 0f21ee7.

### 2.1 Filter sites (three divergent gatekeepers — the root cause)

| # | File | Line | Function / expr | Operators covered today |
|---|------|------|-----------------|-------------------------|
| A | `crates/paideia-as/src/cmd_build/identifier.rs` | 21 | `is_known_operator` (populate call_sites gate) | `\| & ^ << >> + - * / % ~ ! < > <= >= == !=` (17) |
| B | `crates/paideia-as-elaborator/src/emit_store_record.rs` | 1265 | `is_operator_callee` (emit-dispatch gate) | same 17 (must stay in lock-step with A) |
| C | `crates/paideia-as-elaborator/src/emit_visit_lambda.rs` | 598 | inline `matches!(name.as_str(), "\|" \| "&" \| ... )` (function-call vs operator gate in flat-lambda App path) | **only 12** — missing `< > <= >= == !=` |

C is the concrete drift: `>` is in A and B but *absent* from C. Any comparison-op App reaching this arm with a `Var|Placeholder` callee (see §3) is treated as a function call. Fix #1229 papers over the visible symptom by wiring `<` etc. into the dispatcher; #1230 removes the pattern class outright.

### 2.2 Dispatch sites (match arms with operator string; audit `_ =>`)

| # | File:line | Arm form | Fallback | Verdict |
|---|-----------|----------|----------|---------|
| D | `emit_store_record.rs:821-995` | primary BinOp dispatch (`match meta.callee_name.as_str()`) | `other =>` fires T0540 "unknown operator {}" | **GOOD** |
| E | `emit_store_record.rs:999` | shift-shape operand chooser (`if matches!(callee_name, "<<" \| ">>")`) | silent — non-matching path emits `(dest, arg1_dest)` instead | **SILENT** (see §3.2) |
| F | `emit_store_record.rs:1024-1030` | `if let Some(meta) = call_sites().get(expr_id)` | `else` fires T0540 "App {} has no call_sites entry" | **GOOD** |
| G | `emit_enum_match.rs:2047-2059` (Var,Var) | operator → mnemonic | `_ =>` fires T0562 | **GOOD** |
| H | `emit_enum_match.rs:2127-2139` (Var,Lit) | idem | `_ =>` fires T0562 | **GOOD** |
| I | `emit_enum_match.rs:2207-2219` (Lit,Var) | idem | `_ =>` fires T0562 | **GOOD** |
| J | `emit_enum_match.rs:2260-2272` (Lit,Lit) | operator → constant-fold | `_ =>` fires T0562 | **GOOD** |
| K | `emit_enum_match.rs:2290` outer shape switch | `_ =>` fires T0563 | **GOOD** |
| L | `emit_visit_lambda.rs:727-762` | (Var,Var) fast-path: only `<<`, `+` inline; other ops delegate to `emit_var_assign_expr_to_rax` | delegate → D catches | **GOOD (transitively)** |
| M | `emit_visit_lambda.rs:770-829` (Var,Lit) fast-path | idem; `_ => delegate` | delegate → D catches | **GOOD (transitively)** |
| N | `emit_visit_lambda.rs:838-887` (Lit,Var) fast-path | idem | delegate → D catches | **GOOD (transitively)** |
| O | `emit_visit_lambda.rs:889-901` shape catch-all | delegate to shared lowerer | delegate → D catches | **GOOD (transitively)** |
| P | `emit_block_body.rs:270-361` let-RHS App | `if is_operator_callee(...)` → operator emit; `else` → **treated as function call** via `emit_call_expr` | **SILENT** — filter B divergence emits a PLT ref |
| Q | `unsafe_walker/memory.rs:245-253` | `Some("+") \| Some("-") / Some("*") / _ => MalformedOperand` | `_ =>` errors | **GOOD** |
| R | `unsafe_walker/memory.rs:404-421` | `get_infix_op_name` canonicalizer | `_ => None` — consumers must check | **CONDITIONALLY GOOD** (every consumer checks today; see §5 backtrack) |
| S | `unsafe_walker/symbol_ref.rs:180` | `Some("+")/Some("-") / _ => return false` | well-defined "not a symbol_ref shape" | **GOOD (by design)** |

**Count of silent-fallthrough vectors identified: 3** (rows C, E, P). Rows R and S are latent risks worth annotating but not miscompile-live today.

## 3. Fix pattern

### 3.1 Central operator registry (new `paideia-as-ir::operators`)

```rust
// crates/paideia-as-ir/src/operators.rs
pub const KNOWN_OPERATORS: &[&str] = &[
    "|", "&", "^", "<<", ">>",
    "+", "-", "*", "/", "%",
    "~", "!",
    "<", ">", "<=", ">=", "==", "!=",
];
pub const BINARY_OPERATORS: &[&str] = &[/* everything except ~ ! */];
pub const UNARY_OPERATORS: &[&str] = &["~", "!"];

pub fn is_operator(s: &str) -> bool     { KNOWN_OPERATORS.binary_search(&s).is_ok() /* pre-sorted */ }
pub fn is_binary_op(s: &str) -> bool    { BINARY_OPERATORS.binary_search(&s).is_ok() }
pub fn is_unary_op(s: &str) -> bool     { UNARY_OPERATORS.binary_search(&s).is_ok() }
```

Consumers replace the three current filters with `paideia_as_ir::operators::is_operator(name)`:

- Filter A (`cmd_build/identifier.rs:21`): delete `is_known_operator`, import + call `is_operator`.
- Filter B (`emit_store_record.rs:1265`): delete `is_operator_callee`, import + call `is_operator`. Retain the `pub(crate)` alias for callers if churn is undesirable.
- Filter C (`emit_visit_lambda.rs:598`): replace inline `matches!` with `is_operator(name)`, inverting the sense to `if is_operator(name) { /* fall through to operator handling */ } else { /* function-call path */ }`.

### 3.2 Fail-loud dispatch fallthrough

Site E (`emit_store_record.rs:999`) currently reads:

```rust
let operands = if matches!(meta.callee_name.as_str(), "<<" | ">>") {
    /* (dest, cl) shape */
} else {
    /* (dest, arg1_dest) shape */
};
```

Replace with an explicit exhaustive `match` over the operator classes derived from the primary dispatch arm actually reached — or better, hoist operand-shape selection into a small helper `operand_shape_for(op) -> OperandShape` that reads from a single source of truth. Never let an unknown lexeme take the else branch by default.

Site P (`emit_block_body.rs:270`) needs the same delegation swap as C: an operator that misses filter B falls into the `else` branch and is emitted as `emit_call_expr(meta.callee_name, ...)`, minting an undefined external symbol. Post-centralization this cannot drift; before then, annotate the else branch with `debug_assert!(!is_operator(&meta.callee_name), "operator {} fell through to call path", meta.callee_name)`.

### 3.3 Fail-loud transitive gate

Rows L/M/N/O rely on delegation to site D. If a refactor ever inlines the fast paths (e.g., adds a `>` fast-path for the compare-and-branch pattern), the delegation could be lost. Prefer collapsing all four case-analysis arms in `emit_visit_lambda.rs:711-901` into a single call to `emit_var_assign_expr_to_rax` gated on `is_operator(name)`, keeping fast-path selection *inside* the shared lowerer. Follow-up refactor, not blocker.

## 4. Test canaries

Add `crates/paideia-as/tests/build_emit/operator_filter_drift_canaries.rs` and complementary unit tests in `paideia-as-ir`. Canary counts by category:

### 4.1 Drift-detector unit tests (in `paideia-as-ir::operators`)

- **C1** — `known_operators_sorted_for_binary_search`: asserts `KNOWN_OPERATORS` is monotonic (needed for `binary_search`).
- **C2** — `binary_and_unary_partition_covers_known`: `BINARY ∪ UNARY == KNOWN` and `BINARY ∩ UNARY == ∅`.

### 4.2 Coverage canary (drift-detector — critical)

- **C3** — `every_known_operator_has_emit_arm`: parametric test that programmatically drives each lexeme in `KNOWN_OPERATORS` through a minimal fixture `fn(a: u64, b: u64) -> a OP b` (for binary) / `fn(a: u64) -> OP a` (for unary) and asserts *neither* T0540 fires *nor* the build succeeds silently without emitting the expected mnemonic. Uses a golden mnemonic table `operator → expected Mnemonic` maintained beside `KNOWN_OPERATORS`.

### 4.3 Explicit-fail canaries (T0540 must fire)

- **C4** — `unregistered_operator_fires_t0540`: feeds a synthetic operator (e.g. `**` — not in `KNOWN_OPERATORS`) through the elaborator by monkey-patching the parser fixture text; asserts the build fails with T0540 mentioning the specific fallthrough site's detail message.
- **C5** — `comparison_op_returns_bool_not_shifted_value`: the debugger's original repro — `pub let entry : () -> u64 !{} @{} = fn(_ : ()) -> 3u64 > 1u64`. Post-fix: compiles to 1 (or 0 for `<`). Pre-fix (i.e. with `is_operator_callee` reverted): asserts T0540 fires instead of returning 6.

### 4.4 Opcode-canary extension

Extend `tools/opcode-canary.sh` (introduced in #1201) with a `compare-op` group:

- **C6** — bit-pattern assertion that `entry_gt` emits `39 XX` (cmp reg, reg) + `0f 9f XX` (setg r/m8) + `48 0f b6 XX` (movzx r64, r/m8), *not* `48 d3 XX` (shl reg, cl). Bit-level defense-in-depth for the exact reproducer.

**Total canary count: 6** (C1–C6). C1/C2 are millisecond-scale; C3 is the drift-detector and pays the largest maintenance dividend; C4/C5 are cheap negative tests; C6 is the byte-level backstop.

## 5. Backtrack candidates

Adjacent weak spots surfaced during the audit — file as separate issues if the maintainer chooses:

1. **`resolve_reg8` [4..=7] range gap** — noted in the source #1230 issue. `unsafe_walker` register canonicalization has a discontinuous mapping that could silently swap AH↔SPL / CH↔BPL under a future refactor. Same class of bug as the operator-filter divergence: a silent range-index mismatch. Suggested fix: exhaustive `match RegId { … }` with `_ => unreachable!()` in place of the current range check.
2. **`emit_visit_lambda.rs` case-analysis explosion** — 200+ lines of `(IrKind, IrKind)` cross-product with duplicated fast-paths for `<<`, `+`. As new operators land, the invariant that "unlisted operator falls through to shared lowerer" holds only by convention. Refactor to move fast-path selection *into* `emit_var_assign_expr_to_reg`, driven by a single `Option<FastPath> = fast_path_for(op, arg_shape)`.
3. **`unsafe_walker/memory.rs:404-421` canonicalizer** — returns `Option<&'static str>` for a fixed set of operators. If a future unsafe-block feature accepts a new operator (say, `<=>` for three-way compare), this returns `None` and every consumer takes an error path — but the SPECIFIC error path (`MalformedOperand`) is wrong. Suggested guardrail: derive from the same `KNOWN_OPERATORS` set with an `is_addr_expr_op(&str)` helper.
4. **`cmd_build.rs:794` combined identifier/operator filter** — `is_valid_identifier(&callee_text) || is_known_operator(&callee_text)` — a callee that is neither triggers no diagnostic, silently omits the call_sites entry, and the downstream emit path (F) fires a T0540 for the *missing entry*, not for the *malformed callee*. Detail-message quality issue, not a miscompile, but worth polishing to point at the parser rather than the emit site.

## 6. LOC estimate

| Category | Files | LOC |
|----------|-------|-----|
| New `paideia-as-ir::operators` module (impl + module wiring) | +1 file, `lib.rs` | ~40 |
| Filter A/B/C rewrite to delegate | 3 files | ~25 |
| Fail-loud fallthrough hardening (E, P debug_assert) | 2 files | ~15 |
| Unit tests C1/C2 (paideia-as-ir) | +1 module | ~30 |
| Drift-detector C3 (build_emit canary) | +1 file | ~120 |
| Negative canaries C4/C5 (build_emit) | 1 file, 2 fixtures | ~60 |
| Opcode-canary C6 extension | `tools/opcode-canary.sh` | ~20 |
| **Total** | **~9 files touched** | **~310 LOC** |

Non-controversial refactor; no CHANGELOG entry required (correctness hardening below the visible-behaviour surface). Do bump `paideia-as` version at whatever the next tag boundary is; the fix must land as a single atomic PR so filter A/B/C never coexist with the old divergent state on any branch that a downstream `paideia-os` submodule bump could pick up mid-flight.
