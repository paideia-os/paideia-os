# Non-milestone issue #1244 — unsafe-block call-expression statements silently emit out of source order

**Repo**: paideia-os/paideia-as | **Milestone**: none (correctness hardening) | **HEAD**: `e6036df` (v0.18 closed + #1228 + #1230 landed; 5026/0 workspace tests green)
**Filed by**: debugger during #1242 diagnosis of the reverted #996 HashMapU64U64 stdlib revival (2026-07-15).
**Root vector**: two sequential emission passes over an unsafe block's statement stream, coordinated only by ordering of the outer function calls in `cmd_build.rs`, with **no shared `emission_order` counter**. Raw asm (UnsafeWalker) writes `emission_order: 0`; call statements (`emit_pending_unsafe_bodies` → `emit_action_stmt` → `emit_inst`) write a monotonic value >= 1. The final-.text sort key is `(emission_order, node_id)`, so every call-expression statement inside a mixed unsafe block lands after **all** of that block's raw asm — including its own `ret`.

## 1. TL;DR

Two-pass emission is the wrong architecture for a construct whose members must retain source order. Fix: **one interleaved walk of `arena.children(unsafe_id)` in source order per pending Unsafe IR node**, with a **single shared `emission_order` counter** advanced monotonically as each child (raw asm *or* call statement) is emitted.

The advertised pattern in #1088 says an unsafe block may mix raw asm and call-expression statements freely; the emission pipeline broke that contract silently the moment a call statement was not the last stmt.

Nothing needs to be minted: `next_emission_order` already exists on `EmitPassState`; the encoder's `(emission_order, node_id)` sort in `paideia-as-emitter-pe/src/text_emitter.rs:91-93` already delivers correct .text ordering once every instruction gets a source-position emission_order stamp.

## 2. Root cause — file:line

### 2.1 UnsafeWalker writes `emission_order: 0` at every raw-asm insertion site

`crates/paideia-as-elaborator/src/unsafe_walker.rs` — three insertion points inside `process_instruction_stmt`, all hardcoded:

| Site | Line | Path |
|---|---|---|
| A | 1143 | imm64-expand, `Instruction { …, emission_order: 0 }` (needs_expansion=false path) |
| B | 1160 | imm64-expand, fallback path |
| C | 1177 | Normal path (majority of raw asm — no expansion, no width retarget) |

All three write literal `0` into the freshly-constructed `Instruction` and insert it via `arena.instructions_mut().insert(ir_node_id, inst)`. The IR node id is a **fresh `IrKind::Placeholder`** allocated at line 1079, *not* the lowered `IrKind::RawInstruction` child of the Unsafe node — so the block's IR children and the actual instruction-side-table keys are two different identity spaces (§4.2 discusses unifying them).

### 2.2 `emit_pending_unsafe_bodies` runs sequentially, uses `emit_inst`'s monotonic counter

`crates/paideia-as-elaborator/src/emit_walker.rs:847-914` (`emit_pending_unsafe_bodies`): iterates `arena.children(unsafe_id)` in source order, and for `IrKind::Action` children calls `emit_action_stmt(child, arena, typer)` (`emit_block_body.rs:1622`), which routes to `emit_call_stmt` (`emit_call.rs:893`) → `emit_call_args_and_call` → `emit_inst` (`emit_walker.rs:162-185`). Every `emit_inst` call does:

```rust
inst.emission_order = self.state.next_emission_order;
self.state.next_emission_order += 1;
```

By the time `emit_pending_unsafe_bodies` runs (from `cmd_build.rs:948`, *after* `UnsafeWalker::run` at line 902 and *after* the entire `emit_walker.walk(...)` traversal at line 878), `next_emission_order` has already consumed some range `[1, N)`. So call-statement instructions get emission_order values >= N, while every raw asm instruction sits at emission_order=0.

### 2.3 The encoder's sort — where the silent miscompile becomes .text

`crates/paideia-as-emitter-pe/src/text_emitter.rs:88-93`:

```rust
// We collect and sort by (emission_order, node_id) to ensure deterministic order
// across invocations (HashMap iteration is not ordered) and to break virtual-IrNodeId
// collisions (#1140: sibling functions with identical synthetic IDs).
let mut entries: Vec<(u32, IrNodeId)> =
    table.entries().iter().map(|(k, v)| (v.emission_order, *k)).collect();
entries.sort();
```

Lexicographic sort. All raw asm (emission_order=0) sorts before all call-stmt marshalling instructions (emission_order>=N), regardless of the source order of the enclosing block. Node-id tiebreak within emission_order=0 happens to preserve source order for pure-asm blocks (UnsafeWalker allocs its Placeholder ids in the order it walks `block: [ast_stmt_id]`, which *is* source order) — which is why every pure-asm fixture at HEAD (~800+ tests exercising `unsafe { block: {...} }`) has never tripped this.

### 2.4 Why pure-asm blocks work today and #1088-shape blocks silently misbehave

- Pure-asm block: all children `emission_order=0`; sort tiebreaks by node_id ascending; UnsafeWalker walks in source order → node_ids are source-ordered → correct.
- Block with any call-expression statement: raw asm at emission_order=0 (any positions relative to call statements in source), calls at emission_order>=N. The sort places all calls **after** all raw asm — regardless of whether they appeared before or after each other in source.

The bug is symmetric: a call statement *before* raw asm gets emitted *after* the raw asm; a call statement *between* two raw asm blocks gets emitted *after* both. The block's own `ret` (a raw asm at emission_order=0) always precedes the call, so the call becomes unreachable — the observed hashmap-collision-probe symptom.

## 3. Why the two-pass structure exists today

Reading `cmd_build.rs:890-960` and the prose in `emit_walker.rs:842-846`, the sequence was landed as issue #1088's follow-up wiring, keeping the earlier phase-5 `UnsafeWalker` intact and *adding* a routing pass for statement-expression children. The comment at `emit_walker.rs:788-794` explicitly names the escape hatch — `sync_state_instructions_to_arena` was retro-fitted to catch instructions emitted by `emit_action_stmt` — but it addresses **presence in the side table**, not **ordering vs. sibling raw asm**. #1088's AC was "compiles + no U1614 + CALL bytes present in .text" (see `tests/build_emit/unsafe_call_stmt_diagnostic.rs:31-65`), and none of those checks look at *where in .text* the call bytes sit. So the ordering bug never fired.

The debugger's #1242 disassembly of a live #996 fixture is the first empirical observation of the reorder.

## 4. Fix — interleave into a single source-order pass, share the emission_order counter

### 4.1 Approach (concept)

Delete the "two passes coordinated by call order in `cmd_build.rs`" pattern. Instead, per pending Unsafe IR node, walk `arena.children(unsafe_id)` **once** in source order and dispatch each child to its emitter, threading a **single** `emission_order` counter (the existing `EmitPassState::next_emission_order`) through **both** kinds of emission. Raw asm and call statements now interleave at their true source positions in .text.

This mirrors #1241's fix for label offset drift (labels must anchor at their true source-position offset) and is architecturally the same principle: **any construct whose semantics depend on source order must have exactly one emission pass whose iteration order matches source order**.

### 4.2 Concrete change — files, functions, deltas

Three coordinated edits. LOC estimate: ~120 net lines changed, split across three files. No new crates, no new IR variants, no new diagnostics. The design decision is entirely a plumbing rearrangement.

#### 4.2.1 `crates/paideia-as-elaborator/src/unsafe_walker.rs`

**Change `process_instruction_stmt`** to:
1. Accept `next_emission_order: &mut u32` (or equivalently `&mut EmitPassState`; the field access via a narrow borrow is preferred to keep coupling minimal).
2. Accept an `ir_node_id: IrNodeId` argument for the storage key **instead of** allocating a fresh `Placeholder` on line 1079. This unifies raw asm identity: the RawInstruction IR child of Unsafe (already 1-1 with the AST stmt id via the block's Vec) becomes the instruction-side-table key.
3. Replace all three `emission_order: 0` sites (lines 1143, 1160, 1177) with `emission_order: *next_emission_order` followed by `*next_emission_order += 1`.

**Split `UnsafeWalker::run`** into two entry points:
- `collect_labels(...)` — the pass-1 label scan already inside `run` (lines 604-654). Runs first, top-level, per unsafe block; populates `all_labels` and returns.
- `process_stmt(&mut arena, &ast, stmt_id, ir_child_id, ...)` — pub(crate) helper that dispatches a single stmt: for `StmtInstruction`, calls the modified `process_instruction_stmt`; for `StmtLabel`, updates the pending-label queue against the *next* instruction id; for `StmtExpr`, does nothing (the caller — EmitWalker — will route it). Returns the emitted IR id (or `None`).

**Delete** the pass-2 loop (lines 663-766) that today processes instructions per unsafe block. Its work moves into EmitWalker per §4.2.2.

Thread `ast_to_ir: &HashMap<NodeId, IrNodeId>` (from `lower.rs:129`) into whatever remains of `UnsafeWalker::run` — needed to look up the RawInstruction IR child id given an AST stmt id inside `process_stmt`. Availability at the call site is confirmed: `lowering.ast_to_ir` is passed to `EffectRowWalker::run` (`cmd_build.rs:253`) and `CapWalker::run` (`cmd_build.rs:268`) — just extend the same wire to UnsafeWalker.

#### 4.2.2 `crates/paideia-as-elaborator/src/emit_walker.rs`

**Rewrite `emit_pending_unsafe_bodies` (lines 847-914)** as the single interleaved dispatcher:

```rust
pub fn emit_pending_unsafe_bodies(
    &mut self,
    pending: Vec<u32>,
    arena: &mut IrArena,
    ast: &AstArena,
    ast_to_ir: &HashMap<NodeId, IrNodeId>,
    source_map: &SourceMap,
    // … existing UnsafeWalker inputs: record_layouts, instr_mode, features, unsafe_body_to_lambda …
    typer: Option<&paideia_as_types::TypeInterner>,
) -> (HashMap<String, u32>, HashMap<String, IrNodeId>, Vec<Option<IrNodeId>>, Vec<Diagnostic>) {
    // Pass 1: collect labels per block (existing pre-pass logic, moved here or delegated
    // to UnsafeWalker::collect_labels).

    // Pass 2 (the fix): iterate children in source order, one shared counter.
    for id_u32 in pending {
        let Some(unsafe_id) = IrNodeId::new(id_u32) else { continue };

        // Existing #1139 lambda-param re-registration.
        if let Some(&lid) = self.state.unsafe_body_to_lambda.get(&id_u32) { … }

        let mut block_first_instr: Option<IrNodeId> = None;
        let mut pending_labels: Vec<String> = Vec::new();

        // #1241-analogue: source-order walk, one dispatcher, one counter.
        let children: Vec<IrNodeId> = arena.children(unsafe_id).iter().copied().collect();
        for child in children {
            let Some(node) = arena.get(child) else { continue };
            match node.kind {
                IrKind::RawInstruction => {
                    // Look up the corresponding AST stmt id (via reverse of ast_to_ir,
                    // or via a per-block zip of block[] with arena.children(unsafe_id)
                    // — they are 1-1 in source order per lower/children.rs:209).
                    let ast_stmt_id = /* zip lookup */;
                    let emitted = UnsafeWalker::process_stmt(
                        arena, ast, ast_stmt_id, /*ir_node_id=*/ child,
                        &mut self.state.next_emission_order,
                        // … threaded config …
                    );
                    // Alias pending labels + track lambda_first_instr, same policy as today.
                }
                IrKind::Placeholder => {
                    // StmtLabel → collect into pending_labels via existing helper.
                }
                IrKind::Action => {
                    self.emit_action_stmt(child, arena, typer);
                    // emit_action_stmt → emit_call_stmt → emit_inst, which already
                    // consumes and advances self.state.next_emission_order. Same counter.
                    // First emitted instruction for lambda_first_instr is handled by
                    // emit_inst's pending_first_instr_lambda mechanism at emit_walker.rs:180-183.
                }
                IrKind::Var | IrKind::Literal => { /* no side effect — skip */ }
                _ => self.push_typed_diag_u1614(node.span, /* … */),
            }
        }
    }

    // Existing sync at the end.
    self.sync_state_instructions_to_arena(arena);

    (all_labels, label_to_instr, first_instrs, diags)
}
```

Signature change: return type widens to include the outputs that `UnsafeWalker::run` used to return (`all_labels`, `label_to_instr`, `first_instrs`, `diags`) so `cmd_build.rs` sees the same downstream data. This is a mechanical re-plumbing, not a semantics change.

#### 4.2.3 `crates/paideia-as/src/cmd_build.rs`

At lines 894-952, replace the two adjacent calls (`UnsafeWalker::run` then `emit_walker.emit_pending_unsafe_bodies`) with a single call to the merged pass. Everything currently done between them — collecting `unsafe_labels`, `label_to_instr`, `first_instrs`, wiring `lambda_first_instr` — moves into (or continues to be returned by) the merged pass. The `pending` clone that today feeds both calls collapses to a single consume.

Net LOC in cmd_build: ~30 fewer lines (fewer temporaries, one call instead of two).

### 4.3 Invariant enforced by the fix

Every instruction that lands in `arena.instructions()` from within an unsafe block has a monotonically increasing `emission_order` value that reflects its position in the source-order iteration of `arena.children(unsafe_id)`. Combined with the encoder's `(emission_order, node_id)` sort, this guarantees the .text bytes come out in source order — no matter how raw asm and call statements interleave.

Formalizing this as a comment above the sort in `text_emitter.rs:88` ("emission_order is a source-position anchor; all emitters MUST bump the shared counter monotonically") is a small doc addition worth pairing with the fix — it converts the current implicit contract into an explicit one for future emitter contributors.

## 5. Test canaries

Four fixtures, one per failure mode plus one guard against regression of the working case:

### 5.1 `tests/build-emit/unsafe_call_stmt_order_call_before_ret.pdx`

Direct #1244 repro (matches the issue body's `bump()` / `counter` example).

```pdx
module UnsafeCallStmtOrderCallBeforeRet = structure {
  pub let mut counter : u64 = 0

  let bump : () -> () !{} @{} = fn(_: ()) -> unsafe {
    effects: {}, capabilities: {}, justification: "side effect",
    block: {
      lea r15, [rip + counter]
      mov qword [r15], 1
      ret
    }
  }

  pub let entry : () -> u64 !{} @{} = fn(_: ()) -> unsafe {
    effects: {}, capabilities: {}, justification: "call before ret",
    block: {
      bump()
      lea r15, [rip + counter]
      mov rax, [r15]
      ret
    }
  }
}
```

Test asserts (via `text_bytes`): CALL opcode (0xE8) appears **before** RET (0xC3) in `entry`'s function slice. Analogous to `pa_r19_1100_gap1_unsafe_call_args.pdx`'s byte-order witness pattern but scoped to the unsafe-block interleave case.

Currently: fails (CALL after RET).

### 5.2 `tests/build-emit/unsafe_call_stmt_order_call_between_asm.pdx`

Interleave form: `mov; call; mov; ret`. Verifies the call anchors between the two raw-asm regions rather than sinking to the end.

```pdx
module UnsafeCallStmtOrderCallBetween = structure {
  pub let mut hits : u64 = 0

  let tick : () -> () !{} @{} = fn(_: ()) -> unsafe { … block: { lea r15, [rip + hits]; mov qword [r15], 1; ret } }

  pub let entry : () -> u64 !{} @{} = fn(_: ()) -> unsafe {
    effects: {}, capabilities: {}, justification: "call between asm",
    block: {
      mov rax, 0
      tick()
      lea r15, [rip + hits]
      mov rax, [r15]
      ret
    }
  }
}
```

Asserts (again on `text_bytes`): first MOV opcode(s), then CALL, then LEA/MOV, then RET. A direct byte-position ordering check is sufficient.

Currently: fails (MOV rax,0 + LEA + MOV rax,[…] + RET + then CALL).

### 5.3 `tests/build-emit/unsafe_call_stmt_order_multi_calls.pdx`

Multiple call statements interleaved with raw asm — mirrors the #996 hashmap collision-probe workload that surfaced the bug:

```pdx
block: {
  put(1, 100)
  put(2, 200)
  put(1, 101)     // collision on key=1
  put(2, 201)     // collision on key=2
  lea r15, [rip + acc]
  mov qword [r15], 0
  ret
}
```

Asserts: exactly four 0xE8 opcodes appear before any of the trailing raw-asm bytes. Guards against a partial-fix regression where interleaving works for one call but not several.

Currently: fails (all four calls after RET).

### 5.4 `tests/build-emit/unsafe_pure_asm_order_regression.pdx` (guard for the *working* case)

A pure-asm unsafe block with three instructions and one label — must continue to emit in exact source order after the fix lands. Prevents accidental regression of the ~800 pure-asm test surface if the new interleaved pass mis-implements the RawInstruction path.

```pdx
let entry : () -> u64 !{} @{} = fn(_: ()) -> unsafe {
  … block: {
    mov rax, 0x1122334455667788
    lea rbx, [rip + entry]
    lbl_end:
    ret
  }
}
```

Asserts: `mov` opcode bytes appear first, then `lea`, then `ret`; label `lbl_end` anchors at the `ret` byte offset (label offset check via ELF symbol table or a dedicated harness).

Currently: passes. Must continue to pass — this is the safety net.

### 5.5 Retire the pattern hidden by the workaround

`tests/build-emit/hashmap_u64_collisions.pdx` (per issue body) was rewritten to manual `mov rdi, …; mov rsi, …; call hashmap_u64_put` sequences to sidestep the bug. Once #1244 lands, this fixture should be **restored to the natural `hashmap_u64_put(k, v);` form** — a mechanical un-workaround that also serves as a real-world integration canary for the fix (differential: byte-identical .text before and after the un-workaround).

## 6. Backtrack candidates

Ordered by likelihood of surfacing during implementation, most likely first.

### 6.1 Label targets that reference forward-declared labels

Today's UnsafeWalker does a two-pass structure explicitly to support forward label references (see the comments at `unsafe_walker.rs:602-660`: pass 1 collects, pass 2 emits + validates). The merged pass MUST preserve this: label collection is a separate first sub-pass over the same children iterator, before the source-order emission sub-pass starts. Skipping this and inlining collection into the same walk breaks forward `jmp lbl_end` inside the block. **Fix**: keep collection as a pre-pass per Unsafe block; only merge the *emission* passes.

### 6.2 `lambda_first_instr` ownership shift

Today's UnsafeWalker sets `block_first_instr` on the first raw asm it processes (`unsafe_walker.rs:704`). After the fix, the first instruction in source order may be a call-statement's marshal MOV (emitted via `emit_inst` from inside `emit_call_stmt`). `emit_inst` already claims `lambda_first_instr` via the `pending_first_instr_lambda` mechanism (`emit_walker.rs:180-183`). The merged pass must arm `pending_first_instr_lambda` for the enclosing lambda **before** the source-order loop over each block's children starts, so whichever child fires first (raw asm inside `process_stmt` — needs a new emit_inst-style arm-hook — or call statement via `emit_action_stmt` → `emit_inst`) claims the first-instruction slot.

If instead the intent is "first *raw* asm remains the lambda entry" (matching today), that must be an explicit policy in the merged pass, not accidental. Recommend: **first child in source order wins** — matches user intuition.

### 6.3 `resolve_var_operands` timing

`cmd_build.rs:973-983` runs `resolve_var_operands` after both walkers. It relies on `arena.instructions()` being populated with `Operand::Var` entries. The merged pass still writes into `arena.instructions_mut()` (raw asm) and `self.state.instructions` (calls, then synced via `sync_state_instructions_to_arena`). No change to `resolve_var_operands` invocation; keep the same call site position.

### 6.4 Emission_order interaction with the peephole optimizer

`crates/paideia-as-ir/src/opt/branch_hint.rs` and `opt/pool_constants.rs` mutate `arena.instructions_mut()` at optimization time. They preserve `emission_order` on the instructions they touch, and any new instructions they synthesize inherit some emission_order. Confirm (spot check `branch_hint.rs:139-179`) that no optimizer path zeroes emission_order. If any does, that becomes a separate follow-up hardening — but no evidence of that in the current code.

### 6.5 Cross-block ordering vs. non-unsafe emissions

Today's `next_emission_order` counter is bumped by all `emit_inst` calls across all functions. So the emission_order values assigned to unsafe-block raw asm (per the fix) will be *higher* than the values used by the surrounding non-unsafe emit path (which runs in `walk_inner`). The node-id tiebreaker then determines cross-function ordering.

This is fine as long as function symbol boundaries in the ELF are computed from **per-function offset ranges** (via `function_offsets`) rather than from a global monotonic order — and they are (per `#1140` and the existing symbol-table logic in `elf.rs`). Spot-check that a sample two-function fixture — one with unsafe, one without — still produces two separate function symbols with correct byte ranges after the fix. This is likely fine but worth a smoke test on a canary before merging.

### 6.6 `Operand::LabelRef` / `Operand::SymbolRef` validation is inside `process_instruction_stmt`

Lines 963-1022 of `unsafe_walker.rs` validate LabelRef and SymbolRef operands. When we move the label-collection pre-pass, the validation must still see the fully-populated `labels` map — so the pre-pass runs first across **all** children of the current block, then the emission sub-pass starts. The design does this; verify at implementation time.

### 6.7 Debug-assertion prints

The current `unsafe_walker.rs:726-730` has a `cfg!(debug_assertions)` print announcing StmtExpr deferral. After the fix, StmtExpr is no longer deferred — remove the print or convert it to reflect the new dispatch site.

## 7. Fix scope estimate

- `unsafe_walker.rs`: ~50 net lines changed (split `run`; add `process_stmt` helper; thread counter into `process_instruction_stmt`; delete pass-2 loop; unify identity to RawInstruction ir_node_id).
- `emit_walker.rs`: ~60 net lines changed (rewrite `emit_pending_unsafe_bodies` as the unified dispatcher; move label pre-pass call in; expand return signature).
- `cmd_build.rs`: ~30 fewer lines (single call replaces the two-step).
- Fixtures: 4 new `.pdx` files (~15 lines each), 3 new integration tests (~40 lines each). Retire the manual workaround in `hashmap_u64_collisions.pdx`.

Total: ~250 LOC touched, ~150 LOC added net. Zero new IR variants, zero new diagnostics.

## 8. Contract addition

Add a doc comment above `text_emitter.rs:88` making the current sort's semantics an explicit contract, not an internal detail:

> `emission_order` is a **source-position anchor**. Every instruction that reaches this table must carry a monotonically-increasing value assigned at the time of its emission, in strict source-position order relative to sibling instructions within its enclosing function/unsafe-block. Emitters that share the same enclosing scope MUST bump a shared counter (`EmitPassState::next_emission_order`) as they emit. The `(emission_order, node_id)` sort here is the sole ordering authority for .text; there is no rewrite pass downstream.

This documents the invariant #1244 uncovered and gives future contributors a single place to point when reviewing new emission sites.

## 9. Deeper prereq gap discovered

**Raw asm inside unsafe blocks bypasses `emit_inst`.** Every other emitter in the pipeline routes through `EmitWalker::emit_inst` (`emit_walker.rs:162`), which assigns `emission_order`, records `instr_to_lambda`, and arms `pending_first_instr_lambda`. UnsafeWalker inserts directly into `arena.instructions_mut()`, bypassing all three centralized concerns:

- `emission_order`: broken (the direct cause of #1244).
- `instr_to_lambda`: patched manually at lines 1148/1165/1182 of `unsafe_walker.rs` (three sites, easy to drift on future refactor).
- `pending_first_instr_lambda` / `lambda_first_instr`: handled by a *separate* `first_instrs` vector and post-hoc wiring at `cmd_build.rs:928-942` — divergent mechanism from the main emit path's `emit_inst` arming.

The deep fix is to route UnsafeWalker's raw asm through `emit_inst` too — either by making `emit_inst` a free-standing helper on `EmitPassState` (moving it off `EmitWalker`) or by having UnsafeWalker synthesize `Instruction` values and hand them to `EmitWalker::emit_inst` via the merged pass. This eliminates three sources of drift and gives the elaborator a single instruction-insertion channel.

**Recommendation**: Land #1244 with the minimum fix (interleave + shared counter, per §4) so the silent miscompile stops shipping now. File a follow-up ("unify raw-asm insertion through `emit_inst`") to close the deeper structural gap — it's a refactor, not a bug. The #1244 fix as designed here is compatible with the follow-up: whatever function ends up owning the emission_order bump can keep the semantics identical.

## 10. Reviewer checklist for the implementation PR

1. `next_emission_order` is bumped exactly once per instruction inserted into `arena.instructions()` — no double-bump on the imm64-expand path, no zero-writes anywhere.
2. Pass 1 label collection runs to completion before the emission sub-pass begins, per Unsafe block (forward-label support preserved).
3. `arena.children(unsafe_id)` and `block: Vec<NodeId>` are consumed in the same iteration order (zip); one-to-one correspondence explicitly asserted (or documented as a lower.rs invariant with a compile-time-adjacent comment reference).
4. `sync_state_instructions_to_arena` is called before `resolve_var_operands` — position preserved.
5. The retired manual workaround in `hashmap_u64_collisions.pdx` produces byte-identical .text after the fix as before, confirming the fix's semantic equivalence for that fixture.
6. All four new canaries pass; all existing 5026 tests pass.
7. The doc comment on `text_emitter.rs:88` documents the source-position-anchor contract.
