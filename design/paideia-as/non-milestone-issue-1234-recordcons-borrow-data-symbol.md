# Non-milestone issue #1234 — RecordCons `Borrow` field targeting data symbol (`[u8; N]` global)

**Repo**: paideia-os/paideia-as | **Milestone**: none (backtrack cleanup from #998) | **HEAD**: `856a2ce` (#1113 followup landed; 5029/0 workspace tests green)
**Filed by**: softarch during #998 (Str stdlib) pre-emit gap analysis; downgraded to type-only + ptr-form accessors when the workerbee could not populate module-level Str constants (`Str { ptr: &hello_bytes, len: 5u64 }`).
**Blocks**: full end-to-end #998 fixture set — `str_hello_const.pdx`, `str_two_consts_distinct.pdx`, `str_empty_const.pdx`, and both runtime canaries (`str_hello_len_returns_5`, `str_byte_at_returns_h`).

## 1. TL;DR

`crates/paideia-as/src/cmd_build/addr_of.rs:55-66` unconditionally rejects any resolved `SymbolKind` other than `Function` with **T0536** ("address-of target is not a function; data-symbol addr-of not supported in v0.17"). The helper is called from **two** structurally distinct sites in `cmd_build.rs` (both inside the PA-R17-003 pre-emit AddrOfSideTable pass):

| Call site | Line | Context | Correct policy |
|---|---|---|---|
| top-level `let x = &sym` | 1387 | LHS declared as function pointer | `FunctionOnly` (existing) |
| RecordCons field `Str { ptr: &sym, … }` | 1419 | LHS field declared as `*u8` / `*T` | **`FunctionOrObject`** |

The RecordCons field call site reuses the strict helper — so `&hello_bytes` fires T0536 despite the field's declared type (`*u8`) legitimately wanting a data-symbol address. Every layer *downstream* of the AddrOfSideTable populate step is already symbol-kind-agnostic (§3). One parameterization + one call-site change unblocks the entire #998 module-Str-constant path.

Nothing needs to be minted: `AddrOfMeta`, `RelocSpec::with_width`, `encode_record_cons`, the ELF `Abs64` mapping, and the PE `data_symbol_offsets` reloc patcher already treat function and object symbols uniformly.

## 2. Root cause — file:line

### 2.1 The strict reject site

`crates/paideia-as/src/cmd_build/addr_of.rs:55-66` (inside `extract_var_name_from_operand`):

```rust
if let Some(sym_kind) = sym_kind {
    if sym_kind != paideia_as_ir::SymbolKind::Function {
        let diag = Diagnostic::error(
            DiagnosticCode::new(Category::T, Severity::Error, 536).expect("T0536 is valid"),
        )
        .message("address-of target is not a function; data-symbol addr-of not supported in v0.17")
        .with_span(operand_node.span)
        .finish();
        let _ = sink.emit(diag);
        return None;
    }
    Some(var_name)
}
```

Message text ("v0.17") is stale — we are on v0.18. That comment is a fingerprint: the helper was introduced when only fn-ptr targets had a wired emit path; the RecordCons Borrow field pass (#1074, v0.18-early) reused it without re-scoping the check.

### 2.2 Two structurally distinct call sites reuse the same strict helper

`crates/paideia-as/src/cmd_build.rs`:

| Site | Line | Node context | AC on target kind |
|---|---|---|---|
| A | 1387 | top-level `Let` whose `rhs` is `Borrow` | function only (LHS ty is fn-ptr) |
| B | 1419 | RecordCons field is `Borrow` (record_context=`Some((rc_ir_id, field_idx0))`) | function **or** object |

Site B is inside the `for rhs_id in &children` loop that iterates RecordCons children (skipping the `type_name` at index 0). The `record_context` discriminator is already built into `addr_of_entries: Vec<(IrNodeId, IrNodeId, String, Option<(IrNodeId, usize)>)>` at cmd_build.rs:1371 — but not threaded into the pre-check.

### 2.3 Test `fnptr_addr_of_reject_data_symbol` pins the strict Site A behavior

`crates/paideia-as/tests/milestone/pa17_003_fnptr_addr_of.rs:270-300` asserts that `let bad : (u64) -> u64 = &some_data` fails with T0536. This test is **correct as-is** — it exercises Site A (top-level Let with fn-ptr LHS type), not Site B. It must remain green.

## 3. Downstream is uniform — no additional gaps

Each layer between AddrOfSideTable and the linker is symbol-kind-agnostic today:

| Layer | File:line | Behavior on data symbol |
|---|---|---|
| `AddrOfMeta` shape | `paideia-as-ir/src/addr_of.rs:15` | `{ symbol: String, addend: i64 }` — no kind field |
| RecordCons encodable-kind filter | `paideia-as-elaborator/src/data_encoder.rs:394` | `SUPPORTED_FIELD_KINDS` includes `IrKind::Borrow` |
| RecordCons reloc emit | `cmd_build.rs:1917-1943` | `RelocSpec::with_width(offset, meta.symbol, W64, meta.addend)` |
| ELF reloc kind mapping | `cmd_build/elf.rs:353` | `W64 → Abs64` unconditionally |
| PE data-symbol reloc | `cmd_build/pe.rs:206-234` | `data_symbol_offsets` patches `IMAGE_REL_BASED_DIR64` from any symbol in `.rodata`/`.data`/`.bss` |
| Cross-file (unresolved) | `addr_of.rs:69-85` | Already permits unresolved well-formed names — that path is name-only, kind-independent |

Verified: the pre-emit reject is the **only** kind-gated node between the parser and the writer for Borrow-in-RecordCons.

## 4. Fix — one policy parameter, one call-site change

### 4.1 New enum in `addr_of.rs`

```rust
/// Policy governing which resolved SymbolKinds are accepted as address-of targets.
#[derive(Copy, Clone, Eq, PartialEq, Debug)]
pub(super) enum AddrOfPolicy {
    /// Top-level `let x = &sym` — LHS declared as fn-ptr; reject non-Function with T0536.
    FunctionOnly,
    /// RecordCons field `S { f: &sym }` — LHS field type may be `*T` or fn-ptr; accept
    /// Function or Object. Undefined names still fall through to the cross-file path.
    FunctionOrObject,
}
```

### 4.2 Threaded into `extract_var_name_from_operand`

```rust
pub(super) fn extract_var_name_from_operand(
    operand_id: IrNodeId,
    lowering: &LoweringResult,
    source_map: &SourceMap,
    file: FileId,
    policy: AddrOfPolicy,        // NEW
    sink: &mut VecSink,
) -> Option<String> { … }
```

Body change at lines 55-66:
```rust
if let Some(sym_kind) = sym_kind {
    let ok = match policy {
        AddrOfPolicy::FunctionOnly     => sym_kind == SymbolKind::Function,
        AddrOfPolicy::FunctionOrObject => matches!(sym_kind, SymbolKind::Function | SymbolKind::Object),
    };
    if !ok { /* emit T0536 with policy-appropriate message */ return None; }
    Some(var_name)
} else { /* unchanged cross-file path */ }
```

### 4.3 Call-site changes in `cmd_build.rs`

| Site | Line | New arg |
|---|---|---|
| A (top-level Let Borrow) | 1387 | `AddrOfPolicy::FunctionOnly` |
| B (RecordCons Borrow field) | 1419 | `AddrOfPolicy::FunctionOrObject` |

### 4.4 What is intentionally NOT in scope

- **Field-type / target-kind pairing**: rejecting `Str { ptr: &fn_symbol, … }` when field is declared `*u8`, or `S { fptr: &data_symbol }` when field is a fn-ptr. Layout side-table erases `*T` element type to width-8 today (`struct_registry.rs:252`). File **#1234b** if desired; not required for #998 module-Str constants.
- **Addend support** (`& sym + N`): stays 0 for now; matches the existing top-level-Let path.
- **Message text cleanup** on T0536: update to "address-of target must be a function or object; got …" — trivial, folded into 4.2.

## 5. Test canaries (delivered with the fix)

Six new tests + one regression audit:

| # | File | Kind | Assertion |
|---|---|---|---|
| 1 | `crates/paideia-stdlib/pdx/str_hello_const.pdx` | build-emit fixture (already in #998 design §4) | 16-byte `.rodata`, W64 reloc at offset 0 → `hello_bytes`, `len` bytes = `05 00 00 00 00 00 00 00` |
| 2 | `crates/paideia-as/tests/build_emit/record_borrow_data_symbol.rs` | build-emit test | asserts fixture 1 emits exactly one reloc, targeting `hello_bytes` |
| 3 | `tests/build-emit/str_hello_len.pdx` + `crates/paideia-as/tests/runtime/str/str_hello_len_returns_5.rs` | runtime canary | drives fixture 1 into an executable that returns `hello_str.len` in RAX; expect `5` |
| 4 | `tests/build-emit/str_byte_at.pdx` + `.../str_byte_at_returns_h.rs` | runtime canary | RAX = `0x68` (`'h'`) via unsafe-asm ptr-deref-and-index over `hello_str.ptr` |
| 5 | `crates/paideia-stdlib/pdx/str_two_consts_distinct.pdx` | build-emit fixture | two Str constants, two rodata reloc sites, disjoint `.rodata` symbols |
| 6 | `crates/paideia-as/tests/milestone/pa_r18_1234_recordcons_data_borrow.rs` | regression pin | (a) fixture 1 builds green; (b) `pa17_003_fnptr_addr_of::fnptr_addr_of_reject_data_symbol` still fails with T0536 (Site A strict path preserved) |

The load-bearing failing-today canary is **#1** — it is the exact fixture the #998 design lists as required and the workerbee downgraded away from. Once #1234 lands, #1 and #3 unlock the #998 re-uplift.

Discriminator: fixture #6a **must** fail on `HEAD=856a2ce` and pass after the fix; fixture #6b **must** pass on both HEAD and after the fix — this pair discriminates the policy change from an accidental cross-site relaxation.

## 6. LOC estimate

| Deliverable | LOC est. |
|---|---:|
| `addr_of.rs` policy enum + parameterized helper + message update | ~35 |
| `cmd_build.rs` two call-site edits | ~8 |
| Fixture #1 (`str_hello_const.pdx`) | ~10 |
| Fixture #5 (`str_two_consts_distinct.pdx`) | ~14 |
| Build-emit test #2 | ~55 |
| Runtime canaries #3 + #4 (drivers + Rust harnesses) | ~140 |
| Regression pin #6 (2 sub-tests) | ~60 |
| CHANGELOG entry (v0.18 mid-release addition) | ~4 |
| **Total** | **~325** |

Content-only (excluding runtime-harness boilerplate): ~110 LOC.

## 7. Prereq gaps — none

Every downstream layer is proven ready (§3). No infrastructure minting required. No parser, elaborator, encoder, or emitter changes. No new IR kind, no new side-table, no new attribute vocabulary.

The one soft dependency — expression-position `*p` deref returning a scalar (#998b) — is **not** on the critical path here: canary #3 reads `.len` via `FieldAccess(Deref(Var))` (already working), and canary #4 reads `*(hello_str.ptr)` via unsafe-asm (also already working).

## 8. Follow-ups (do not block #1234)

- **#1234b** — Field-type ↔ target-kind pairing check (reject `S { fnptr_field: &data_sym }` and `S { ptr_field: &function }`). Requires threading declared field type from `record_layout_table` into the pre-emit pass; ~80 LOC.
- **#998f** (already tracked) — After #1234 lands, re-uplift the #998 module-Str constant fixtures (`str_hello_const`, `str_two_consts_distinct`, `str_empty_const`) from downgraded / deferred to shipped.
- **#1234c** — Stale-message audit: T0536 sites still referencing "v0.17" or "not supported" wording after policy change.

## 9. Discipline

- softarch (this note) → workerbee (implements §4 + §5) → debugger (verifies §5#6a fails on HEAD, passes after fix; §5#6b passes on both).
- iced-x86 round-trip: no new emit paths; §3 reloc pipeline is exercised by existing #1074/#1157/#988v2 tests, now extended to Object kind.
- Additive-only surface change: new pub(super) enum `AddrOfPolicy` in the private `addr_of` submodule — no public API delta.
- Mid-release: CHANGELOG entry under v0.18 unreleased/hotfix; no workspace.version bump.
