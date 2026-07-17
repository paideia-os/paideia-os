# Issue #1239 — T0575 nested-closure invocation guard

**Status:** design (blocks re-implementation)
**Owner:** paideia-as
**Related:** #994 (closure lowering), #995 (closure-call lowering), #1233 (closure emit primitives)
**Prior attempt:** commit `2a4ee46`, reverted at `0988d7c` (detection never fired)

## 1. Restriction being enforced

Currently `emit_closure_call` (crates/paideia-as-elaborator/src/emit_lambda.rs:502) unconditionally clobbers `R14` via `mov r14, [r11 + 0]` to load the callee's env-ptr. If the caller is itself a closure body, its own env-ptr in `R14` is destroyed with no save/restore. Subsequent reads of any captured binding in the outer closure become undefined. Until R14 preservation ships (out of scope for #1239), any static occurrence of "closure body calls another closure" must be rejected with T0575.

## 2. Root cause of the reverted attempt

`2a4ee46` added a `check_nested_closure_invocation` hook inside `visit_lambda`'s `App` and `Action` arms, called AFTER `local_bindings.clear()` + `register_nested_lambda_params` + `register_closure_captures`, but BEFORE `emit_block_body`. Two combined defects prevented it from ever firing on the fixture:

1. **Wrong lookup timing.** The App-callee test relied on `local_bindings.get_home("g") == Some(BindingHome::Closure(_))`. But at the check point, the outer closure's `let g = <ClosureCons>` has not yet been walked by `emit_block_body`, so `insert_closure("g", …)` (emit_block_body.rs:504) has not run. The lookup returns `None`.

2. **Wrong child index in the structural fallback.** `search_action_for_closure_binding` iterated Action children looking for Lets, then read `let_children.first()` and matched against `IrKind::ClosureCons`. But statement-form Let nodes have children `[name_var, value, ty?]` — the RHS is at index **1**, not 0 (see emit_block_body.rs:927–929). Child[0] is a `Placeholder` name-var, never a `ClosureCons`, so the branch was dead.

Combined effect: neither the register-table path nor the arena walk ever identified `g` as a closure, `T0575` was never pushed, the test assertion (which only checked `output.stderr`, asserting nothing) still passed regardless. The revert removed a false-positive-free but false-negative-total gate.

## 3. Correct detection algorithm

Do **not** hook into `visit_lambda`. Run a dedicated pre-pass alongside `register_closure_body_symbols` and `precompute_caller_frame` in `EmitWalker::walk` (emit_walker.rs:511, 515-523). At that point:

* `closure_dispatch::convert_closure_lets` has already converted every closure-typed local `Lambda` into a `ClosureCons(Lambda)` wrapper and populated `arena.closure_meta()` (closure_dispatch.rs:206).
* No emission has begun — `local_bindings` is not yet populated, and we deliberately avoid depending on it.

### Algorithm (pure IR-structural, no register-state dependency)

```
for each Lambda L such that arena.closure_meta().get(L).is_some():
    inner_closure_names: Set<String> = {}
    walk L's body children[0] recursively, stopping at nested Lambda/Unsafe boundaries:
        if node is Let:
            let_children = arena.children(node)
            rhs_idx = if let_children.len() > 1 { 1 } else { 0 }         // matches emit_block_body.rs:928
            if let_children[rhs_idx] is ClosureCons:
                if let Some(name) = arena.binding_names().get(node):
                    inner_closure_names.insert(name)
    walk L's body children[0] a second time, stopping at nested Lambda/Unsafe boundaries:
        if node is App and children[0].kind in {Var, Placeholder}:
            if let Some(name) = arena.binding_names().get(children[0]):
                if inner_closure_names.contains(name):
                    fire T0575 with span of App node
                    record L in a T0575_reject set
                    break inner walk
```

`arena.closure_meta().get(L).is_some()` is the authoritative "L is a closure body" signal — populated for every closure body Lambda regardless of empty-captures degeneracy. The double walk is O(nodes-in-L-body) and the whole pass is O(arena.len()) once.

### Suppressing emission

After the pass, for every L in the reject set, gate `visit_lambda`'s entry:

```rust
if self.state.t0575_rejects.contains(&lambda_node_id.get()) { return; }
```

placed immediately after `register_nested_lambda_params` in `visit_lambda`. This blocks emission of both the outer closure's prologue and its body — otherwise a well-formed R14-clobbering call would still land in `.text` alongside the diagnostic.

### Why not the `closure_frame_meta`-based shortcut

A simpler variant would be "L has closure_meta AND `closure_frame_meta(L)` is `Some` with slots" — because `precompute_caller_frame` (emit_walker.rs:999) records nested-`ClosureCons` slots on L's own frame. But this fires even when the inner closure is defined and never invoked. That is a valid restriction to add, but broader than issue #1239, which specifically targets the invocation. Keep the App-walk step; it costs O(nodes) and precisely names the offending call site for the diagnostic span.

## 4. Fixture correctness

Existing fixture: `tests/build-emit/closure_type/closure_call_nested_invocation_diagnostic.pdx`

```
pub let entry : () -> u64 = fn () -> {
  let f : |u64| -> u64 = fn (x: u64) -> {
    let g : |u64| -> u64 = fn (y: u64) -> y + 1u64
    g(x)
  }
  f(41u64)
}
```

**Structurally correct** for detection: `f` is closure-typed (has `closure_meta`), `f`'s body has a `let g = <ClosureCons>`, and `f`'s body calls `g(x)` (App(Var(g), Var(x))). The algorithm above fires T0575 on the `g(x)` App node.

**Discriminating gap.** Neither `f` nor `g` captures anything, so the R14 clobber has no observable runtime consequence in this fixture — the detection is a static conservative rejection. For a truly discriminating fixture (proving the underlying bug rather than exercising the gate), add a companion `closure_call_nested_invocation_uses_capture.pdx` where the outer closure has a capture referenced AFTER the inner call:

```
pub let entry : () -> u64 = fn () -> {
  let c : u64 = 100u64
  let f : |u64| -> u64 = fn (x: u64) -> {
    let g : |u64| -> u64 = fn (y: u64) -> y + 1u64
    let z : u64 = g(x)
    z + c
  }
  f(41u64)
}
```

Here `f` captures `c` (via linearity/capture analysis), and `+ c` after `g(x)` would read `[r14 + 0]` after R14 was overwritten by the inner call. Under T0575 both fixtures must reject; without T0575 the second silently miscompiles.

## 5. Test assertion pattern

The current test computes `stderr` but asserts nothing (closure_type.rs:170–172). Correct assertion:

```rust
#[test]
fn closure_call_nested_invocation_diagnostic_rejects_t0575() {
    let input = build_emit_data("closure_type/closure_call_nested_invocation_diagnostic.pdx");
    let output = cargo_run(&["build", input.to_str().unwrap(), "--emit", "placeholder"]);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("T0575"),
        "expected T0575 diagnostic on nested closure invocation; stderr was:\n{}",
        stderr
    );
    assert!(!output.status.success(), "expected build failure on T0575");
}
```

Both assertions are load-bearing: `contains("T0575")` catches "diagnostic fires under the right code"; `!success()` catches "diagnostic actually blocks the build" (a warning-level path would let the build succeed with wrong codegen).

## 6. Catalog entry

Add to `crates/paideia-as-diagnostics/catalog.toml`, immediately after the existing `[diagnostic.T0571]` block (line 1509):

```toml
[diagnostic.T0575]
severity = "error"
category = "type"
title = "Nested closure invocation not yet supported"
brief = "closure body invokes another closure — outer env-ptr (R14) would be clobbered"
description = """
Issue #1239: A closure body contains an application of another closure-typed
binding. The closure-call ABI loads the callee's environment pointer into R14
via `mov r14, [r11 + 0]` at every call site (see emit_closure_call), which
destroys the outer closure's own env-ptr with no save/restore. Any subsequent
read of a captured binding in the outer closure would resolve against the
inner closure's environment. Until R14 preservation across closure calls
lands, this pattern is rejected statically. Workaround: hoist the inner
closure to a top-level `fn` (no environment) or restructure so the inner call
happens outside the outer closure's body.
"""
since = "0.18.0"
deprecated = false
```

## 7. Backtrack candidates

If the guard proves too broad in later development:

1. **Restrict to capturing-outer.** Fire T0575 only if `arena.closure_meta().get(L).captures.is_non_empty()`. Rationale: an outer closure with zero captures never reads R14, so the clobber is benign for that specific L. Cost: allows silent miscompile if the outer closure gains captures later without the fixture flagging it.
2. **Restrict to post-call capture reads.** Analyze whether any capture is read after the inner call in L's body. Precise but requires reaching-uses analysis on the IR.
3. **Warn instead of error.** Downgrade `severity = "warning"` — build succeeds with wrong code but user sees the risk. Not recommended; wrong-code paths belong behind errors.
4. **Fire on definition (broader).** Reject any closure body that contains a nested `ClosureCons` even without an App — catches unused inner closures too. Broader than #1239 but aligns with the current frame_meta shape (nested ClosureCons already allocates on the outer closure's own frame, an area untested by existing fixtures).

The primary implementation should ship option (0) — the algorithm as specified — and reserve (1)–(4) as follow-up levers if a legitimate pattern is later blocked.

## 8. LOC estimate and tractability

| Component | Location | LOC |
|---|---|---|
| catalog entry | catalog.toml @ ~1509 | ~15 |
| `t0575_code()` helper | emit_visit_lambda.rs top-of-file | ~5 |
| detection pass `check_nested_closure_invocations` | emit_walker.rs (new fn) | ~55 |
| pre-pass call | emit_walker.rs after line 523 | ~3 |
| reject-set state field | emit_pass_state.rs | ~3 |
| suppression gate | emit_visit_lambda.rs after line 251 | ~3 |
| test assertion tightening | tests/build_emit/closure_type.rs | ~6 |
| optional discriminating fixture | tests/build-emit/closure_type/ + wired test | ~20 |

**Total: ~110 LOC** (base) or ~130 LOC with discriminating fixture.

**Tractable in one workerbee pass:** yes, with the following non-negotiable acceptance test — a workerbee MUST run `cargo test --test build_emit closure_call_nested_invocation_diagnostic_rejects_t0575 -- --nocapture` and observe the stderr containing `"T0575"` BEFORE claiming success. The prior workerbee's failure mode was reporting completion without executing the discriminating assertion. The tightened test at §5 makes the assertion structural rather than observational, closing that loophole.
