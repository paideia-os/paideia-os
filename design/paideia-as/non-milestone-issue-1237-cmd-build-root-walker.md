# Non-milestone issue #1237 — cmd_build.rs walks from `IrNodeId::new(1)` but the real root is bottom-up allocated last

**Repo**: paideia-os/paideia-as | **Milestone**: none (correctness hardening) | **HEAD**: `1953c7e` (post-#1019 revert; #994 workaround in place)
**Filed by**: debugger during #994 completion (root cause of `CapturesTable` silently empty for lambdas past the first).
**Root vector**: `crates/paideia-as/src/cmd_build.rs:633` seeds every top-level `IrWalker` (`LinearityWalker`, `EffectRowWalker`, `CapWalker`) with `IrNodeId::new(1)` on the assumption that node 1 is the enclosing `Module`. It isn't. `lower_ast_to_ir` mirrors the parser's bottom-up allocation order, so `Module` lands among the last-allocated IDs and node 1 is typically a leaf (the module-name `Ident`) with no children. Every diagnostic that requires the walker to reach a real `Lambda`/`Let`/`Perform`/`App` therefore silently never fires from the CLI. #994 shipped a narrow workaround (`find_outermost_root()` + throwaway walk sink) that populates `CapturesTable` only.

## 1. TL;DR

Do the surgical fix. Replace `IrNodeId::new(1)` at three walker seed sites with `find_outermost_root(&lowering.ir)` (the same helper #994 already proved correct), delete the throwaway capture-walk, and drain analyzed captures directly from the primary `LinearityWalker`. Estimate: **~30 net LOC in `crates/paideia-as/src/cmd_build.rs` alone**, no test corpus edits, no walker changes.

The phased "fix root, sweep corpus, triage new diagnostics" approach the issue text imagines does not describe today's reality. Today the surface area of newly-surfaced diagnostics is **empirically zero from the CLI** because every S/F/C code depends on payloads (`lin_class`, `perform_ops`, `handle_effects`, `lambda_declared`, `app_required`, …) that phase-1 lowering does not populate yet. The bug is dormant. Fixing it now is cheap and it removes the trap for m3/m5 payload wiring.

## 2. Affected sites (walker seeds)

`crates/paideia-as/src/cmd_build.rs`:

| # | Line | Walker | Notes |
|---|---|---|---|
| 1 | 633 | Guard: `if let Some(ir_root_id) = IrNodeId::new(1) { … }` | Wraps sites 2–4 and the #994 throwaway walk. |
| 2 | 640 | `walk(&mut linearity_walker, &lowering.ir, ir_root_id, &mut ctx)` | Should be `real_root_id`. |
| 3 | 713 | `walk(&mut effect_walker,   &lowering.ir, ir_root_id, &mut ctx)` | Should be `real_root_id`. |
| 4 | 719 | `walk(&mut cap_walker,      &lowering.ir, ir_root_id, &mut ctx)` | Should be `real_root_id`. |
| 5 | 666–694 | #994 throwaway `capture_walker` from `find_outermost_root(&lowering.ir)` | Delete after fix; primary `LinearityWalker` already covered the subtree. |
| 6 | 1008 | `dispatch::dispatch(&mut lowering.ir, ir_root_id, …)` | Not a walker: every `OptPass::apply` in `crates/paideia-as-ir/src/opt/*.rs` currently ignores `function_root` (`_function_root: IrNodeId`) — iterates `InstructionSideTable` directly. No change needed today; note for m9 hardening. |

Total walker seeds to migrate: **3**. Total supporting edits: **1 guard rewrite + 1 workaround deletion**. No other `IrNodeId::new(1)` in `cmd_build.rs` is a walker seed (the `src/cmd_build/{elf,pe}.rs` and `cmd_build/tests.rs` occurrences are diagnostic constructors and unit-test dummy arenas — irrelevant).

## 3. Diagnostic surface area — the actual risk profile

The issue text warns that fixing the root will "newly surface previously-suppressed diagnostics" across the corpus. This is not what the code says today.

### 3.1 Every walker's diagnostic emission is payload-gated

- **`LinearityWalker`** (`crates/paideia-as-elaborator/src/check_linearity.rs`)
  - `S0900`/`S0901` require `node.lin_class ∈ {Linear, Ordered, Affine}` (`check_linearity.rs:77-107`, `validate_scope`).
  - `S0902` (leaked shadow) requires an *outer* binding with `Linear|Ordered` (`check_shadowing_leak`, line 283).
  - `S0904` requires `LinClass::Affine` (`check_multi_arm_consume`, line 332).
  - `S0907` (illegal capture) requires `(CaptureKind::Consume, LinClass::Linear|Ordered)` and closure `lin_class ∉ {Linear, Affine}` (`check_lambda.rs:75-81`).
  - **But** `crates/paideia-as-elaborator/src/lower.rs:137` documents `lin_class = LinClass::Unrestricted` (default), and no lowering code path mutates it — the only `d.lin_class = LinClass::…` assignments in the workspace live in **test files** (`check_linearity.rs` unit tests, `arena.rs::get_mut_allows_elaborator_to_update_class_and_effects`, `pretty.rs` fixtures). Real corpus IR carries `LinClass::Unrestricted` everywhere.
  - Corollary: correcting the walker root today produces **zero** new S-code diagnostics from real fixtures. The existing CLI regression test `build_linear_double_use_compiles_but_doesnt_fire_walker` (`crates/paideia-as/tests/codegen/cli.rs:417`) documents this exact limitation and expects clean exit.

- **`EffectRowWalker`** (`crates/paideia-as-elaborator/src/effect_walker.rs`)
  - `F1100`/`F1101`/`F1105`/`F1106` all read from injection HashMaps: `perform_ops`, `handle_effects`, `call_declared_rows`, `handler_impls`, `effect_decls`, `pure_contexts`.
  - `cmd_build.rs:614-617` states plainly: "walkers run with empty injection tables (from CLI), so only diagnostics that depend on kind-only IR will fire. Real effect (F1100, F1101, F1105, F1106) and capability (C1300) diagnostics require per-node payloads that arrive in m3/m5."
  - Corollary: zero new F-code diagnostics from real fixtures.

- **`CapWalker`** (`crates/paideia-as-elaborator/src/cap_walker.rs:80-158`)
  - `C1300` only fires if `lambda_declared.get(&id)` returns `Some`; injection is empty in CLI.
  - Corollary: zero new C-code diagnostics from real fixtures.

### 3.2 Test-corpus census

- 1,092 `.pdx` fixtures across `crates/`, `tests/`, `examples/`.
- 465 Rust test files across 16 crates.
- Zero CLI-driven fixtures expect S/F/C diagnostics today (`grep -rln 'S09..\|F110[0-6]\|C1300' crates/paideia-as/tests/` returns only `codegen/cli.rs` and `build_emit/closure_type.rs`, neither of which asserts firing).
- Every walker unit test lives in the walker's own crate and constructs its arena by hand, setting `lin_class`/injection tables explicitly. Those tests do not go through `cmd_build`, so they are unaffected.

**Concrete new-diagnostic surface area if we fix the root today: 0.**

## 4. Design recommendation — surgical, one-pass

### 4.1 Sketch of the change (~30 LOC net in `cmd_build.rs`)

```rust
// Determine the real root: bottom-up allocation puts the enclosing Module
// among the *last*-allocated nodes, so `IrNodeId::new(1)` is a leaf ident
// with no children. `find_outermost_root` returns the unique node that is
// not listed as a child of any other node (highest-numbered on tie).
if let Some(root_id) = find_outermost_root(&lowering.ir) {
    // 1. LinearityWalker: drain analyzed captures from the same instance —
    //    #994's second walk is no longer needed.
    let mut linearity_walker = LinearityWalker::new();
    {
        let mut ctx = paideia_as_ir::WalkerCtx::new(&source_map, &mut walker_sink);
        walk(&mut linearity_walker, &lowering.ir, root_id, &mut ctx);
    }
    for (lambda_raw_id, captured) in linearity_walker.into_analyzed_captures() {
        if let Some(lambda_id) = IrNodeId::new(lambda_raw_id) {
            let analyzed = captured.iter().map(|c| paideia_as_ir::AnalyzedCapture {
                symbol: c.symbol,
                kind: match c.kind {
                    paideia_as_elaborator::CaptureKind::Reference => 0,
                    paideia_as_elaborator::CaptureKind::Value => 1,
                    paideia_as_elaborator::CaptureKind::Consume => 2,
                },
            }).collect();
            lowering.ir.captures_mut().insert(lambda_id, analyzed);
        }
    }

    paideia_as_elaborator::convert_closure_lets(
        &arena, &mut lowering.ir, &lowering.ast_to_ir, &mut walker_sink);

    // 2. EffectRowWalker
    {
        let mut ctx = paideia_as_ir::WalkerCtx::new(&source_map, &mut walker_sink);
        let mut effect_walker = EffectRowWalker::new();
        walk(&mut effect_walker, &lowering.ir, root_id, &mut ctx);
    }
    // 3. CapWalker
    {
        let mut ctx = paideia_as_ir::WalkerCtx::new(&source_map, &mut walker_sink);
        let mut cap_walker = CapWalker::new();
        walk(&mut cap_walker, &lowering.ir, root_id, &mut ctx);
    }
    // ... rest of EmitWalker path unchanged, still keyed off `root_id`.
}
```

`find_outermost_root` already handles the degenerate (empty arena) case by returning `None`, so the outer guard covers both "empty IR" and "cyclic/malformed IR" without a separate `is_empty` check. The comment block at `cmd_build.rs:646-665` should be replaced with a two-line reminder about bottom-up allocation and a pointer to this doc.

### 4.2 Why not phase A/B/C?

The three-phase plan (fix → sweep → triage) is the right template *when* payload wiring is landed. Today it would grade **zero regressions** and expend a workerbee pass on paperwork. The phased plan is deferred until the m3 effect/handler wiring and the m5 lin-class-from-syntax wiring both land — at that point the sweep would be a `find_outermost_root`-based sanity script, not a real triage exercise. Filing that follow-up task is the correct action *after* the surgical fix ships:

> Follow-up task (m3-close): when `lower_ast_to_ir` sets `lin_class` from `linear`/`ordered`/`affine`/`unique` type modifiers in real fixtures, walk `examples/*.pdx` with a debug printer that counts fired S/F/C codes; add an expect-failure fixture for each newly-eligible diagnostic and land per-code assertions.

That work belongs to whichever milestone brings payloads online; scoping it into #1237 conflates a walker-plumbing bug with a semantic-analysis rollout.

### 4.3 Optimizer dispatch (line 1008)

`dispatch::dispatch` is called with `IrNodeId::new(1)` but every `OptPass::apply` in `crates/paideia-as-ir/src/opt/*.rs` marks the `function_root` argument as `_`-prefixed and iterates the arena or `InstructionSideTable` directly. Leave the CLI seed as-is for now; when passes gain a real function-scope contract (m9 hardening), migrate to `find_outermost_root` at the same time.

## 5. Migration plan

1. **Edit `cmd_build.rs`** per §4.1. Net diff ≈ +15 / −45 LOC (the deletion of the multi-paragraph #994 comment and the throwaway `capture_walker` dominates the reduction).
2. **Update the CLI limitation comment** at `cmd_build.rs:614-617` to say: "walkers now traverse the real IR subtree; diagnostic firing remains gated by payload injection (m3/m5)."
3. **Retain the existing CLI regression test** `build_linear_double_use_compiles_but_doesnt_fire_walker` unchanged — its behaviour post-fix is identical (still exits 0 because `lin_class` remains `Unrestricted`). Its comment is even more accurate afterwards.
4. **Add one new CLI regression test** that constructs a `.pdx` fixture whose IR would deterministically expose the wrong-root bug: a module with two lambdas, verifying `arena.captures().len() == 2`. Today the #994 workaround already makes this pass; after the fix it exercises the primary walker.
5. **Cargo workspace test** (`cargo test --workspace`) is the acceptance gate. No fixture edits should be required; if any test starts failing, that failure is legitimate signal of a payload-carrying corner (unlikely per §3) and should be triaged in-line, not deferred.
6. **Close #1237** referencing this doc.
7. **File a follow-up** as described in §4.2 tagged with the m3 milestone.

## 6. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| A hand-built test arena somewhere seeds `lin_class`/injection tables *and* runs through `cmd_build` | Low | New S/F/C diagnostic surfaces | `grep -rn 'lin_class\s*=' crates/ | grep -v tests/` returns no lowering-path assignments — all live in tests that use their own walker driver, not `cmd_build`. |
| `find_outermost_root` returns a non-Module node for a malformed arena | Very low | Walker traverses subtree that misses top-level items | Empty-arena path already skips; a cyclic arena is a lowering bug and should surface elsewhere. `find_outermost_root` prefers highest-numbered unreferenced node, matching bottom-up allocation. |
| Follow-up sweep gets forgotten | Medium | Payloads land, new bugs escape | File the follow-up issue as part of closing #1237, tag it to the m3 milestone. |

## 7. Tractability

- **Surgical fix (§4.1)**: one workerbee pass. Straightforward mechanical edit, single file, ~30 LOC, no cross-crate churn, no fixture edits, existing test suite validates. Verification tempo: unchanged.
- **Phased fix (as issue text imagines)**: not tractable in one pass, and unnecessary today because §3 shows zero new diagnostics fire. Defer until m3/m5 wiring lands.

Recommendation: **land the surgical fix now**, file the follow-up sweep for m3-close.
