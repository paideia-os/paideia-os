# Non-milestone issue #1228 — BulkMemOps stdlib_lowering + RepStosb/RepMovsq (Phase 2 of #1064)

**Repo**: paideia-os/paideia-as | **Milestone**: none (Phase-2 follow-up to closed #1064) | **HEAD**: `1ba1d83` (v0.18 closed; 5002 tests green)
**Depends on**: #1064 Phase 1 (trait declaration landed in `crates/paideia-stdlib/pdx/bulkmem.pdx`), #1062 (`ArgConvention::SysVRegs`), #1034 (clobber tracking).
**Filed by**: softarch during v0.18 close-out sweep (2026-07-17).

## 1. Scope statement

Activate the four `BulkMemOps` methods (`memcpy`, `memset`, `memcpy_qwords`, `memset_qwords`) as splice-time lowering recipes. Deliver: two new zero-arity IR mnemonics (`RepStosb`, `RepMovsq`), their opcode encoders, unsafe-walker token wiring, opt-pass classifications, four `ArgConvention::SysVRegs` recipes in `stdlib_lowering.rs`, and canary fixtures. **Defer**: pre-existing `RepMovsb` arity anomaly (§6.1) and `RepStosq` estimated-size discrepancy (§6.2) — file separately, do not fold. **Defer**: automatic `cld` prologue (§6.3) — trait doc-comment already contracts DF-clear on entry.

## 2. Landed vs to-add — evidence

Absolute paths and line numbers as of HEAD `1ba1d83`.

### 2.1 Landed (Phase 1 + adjacent)

| Artefact | Path | Line | Status |
|----------|------|------|--------|
| `BulkMemOps` trait declaration | `crates/paideia-stdlib/pdx/bulkmem.pdx` | 11-16 | landed (#1064 Phase 1) |
| `Mnemonic::RepMovsb` variant | `crates/paideia-as-ir/src/instruction.rs` | 116 | landed (used by inline asm) |
| `Mnemonic::RepStosq` variant | `crates/paideia-as-ir/src/instruction.rs` | 182 | landed (.bss zeroing) |
| `ArgConvention::SysVRegs` machinery | `crates/paideia-as-elaborator/src/stdlib_lowering.rs` | 42-49 | landed (#1062) |
| SysVRegs splice at emit_call | `crates/paideia-as-elaborator/src/emit_call.rs` | 428-436, 723-755 | landed |
| Design doc: BulkMemOps section | `design/toolchain/stdlib-trait-lowering.md` | 150-163 | landed (declares recipes "deferred to Phase 2") |
| Encoder fn `encode_rep_stosq` | `crates/paideia-as-encoder/src/encode.rs` | 4527 | landed (F3 48 AB) |
| Encoder fn `encode_rep_movsb` | `crates/paideia-as-encoder/src/encode_instruction.rs` | 3266 | landed (F3 A4) |

### 2.2 To add (Phase 2 delta)

| Artefact | Path | Insertion point | Bytes / LOC |
|----------|------|-----------------|-------------|
| `Mnemonic::RepStosb` variant + doc | `crates/paideia-as-ir/src/instruction.rs` | after line 182 (`RepStosq`) | ~4 LOC |
| `Mnemonic::RepMovsq` variant + doc | `crates/paideia-as-ir/src/instruction.rs` | adjacent to `RepStosb` | ~4 LOC |
| `arity()` arms (both = 0) | `crates/paideia-as-ir/src/instruction.rs` | line 842-868 zero-arity block | ~2 LOC |
| `estimated_size()` arms | `crates/paideia-as-ir/src/instruction.rs` | near line 1155 `RepStosq => 2` | ~4 LOC (RepStosb=2, RepMovsq=3) |
| Encoder free fns | `crates/paideia-as-encoder/src/encode.rs` | after `encode_rep_stosq` (line 4527) | ~30 LOC |
| Dispatch arms + wrapper fns | `crates/paideia-as-encoder/src/encode_instruction.rs` | line 339 dispatch + fn adjacent to `encode_rep_stosq_inst` | ~50 LOC + 4 unit tests (~90 LOC) |
| Lexer/walker tokens | `crates/paideia-as-elaborator/src/unsafe_walker.rs` | after line 122 (`rep_stosq`) | ~2 LOC + 2 unit tests |
| opt/schedule.rs class | `crates/paideia-as-ir/src/opt/schedule.rs` | line 110 (`RepMovsb → Other`) | ~2 LOC |
| opt/unroll.rs unsafe list | `crates/paideia-as-ir/src/opt/unroll.rs` | line 87 (`RepMovsb =>`) | ~10 LOC (both new mnemonics guard) |
| Four SysVRegs recipes | `crates/paideia-as-elaborator/src/stdlib_lowering.rs` | after `BytesOps put_u64_be` (line 814) | ~180 LOC (4 recipes × ~45) |
| Recipe unit tests | `crates/paideia-as-elaborator/src/stdlib_lowering.rs::tests` | end of tests mod | ~120 LOC (4 tests) |
| Integration tests | new `crates/paideia-as-elaborator/tests/lowering/stdlib_bulkmem.rs` | + `mod stdlib_bulkmem;` in `lowering.rs` line 24 | ~200 LOC |
| Build-emit smokes | new `tests/build-emit/rep_stosb_smoke.pdx` + `rep_movsq_smoke.pdx` + Rust drivers `crates/paideia-as/tests/build_emit/{rep_stosb,rep_movsq}.rs` | + entries in `build_emit.rs` line 101-102 | ~2 × 260 LOC (mirror `rep_movsb.rs`) |

**Rough total**: ~950 LOC across 9 files (higher than the issue's 400-600 estimate because two encoder-canary drivers mirror the ~260-LOC `rep_movsb.rs`/`rep_stosq.rs` templates verbatim — mechanical, not design).

## 3. Encoder recipes

Both new mnemonics are zero-operand REP-string primitives; both share the `RepStosq` template.

### 3.1 `RepStosb` — `F3 AA`

Repeat store byte: RCX iterations of `[RDI] ← AL; RDI += 1; RCX -= 1`. Two bytes total (no REX; AA is byte form). Encoder mirrors `encode_rep_stosq` minus the 0x48 REX.W push. Dispatch wrapper enforces `operands.is_empty()` and emits `EncodeError::OperandCount` on violation — same pattern as `encode_rep_stosq_inst` at line 3981.

### 3.2 `RepMovsq` — `F3 48 A5`

Repeat move quadword: RCX iterations of `[RDI] ← [RSI]; RDI += 8; RSI += 8; RCX -= 1`. Three bytes (F3 prefix + REX.W + A5 opcode). Encoder is literally `[0xF3, 0x48, 0xA5]` push. Same 0-operand guard.

## 4. Lowering recipes (SysVRegs, arg-convention = pre-marshalled RDI/RSI/RDX)

Each recipe splices *after* `emit_call_args_and_call` has moved args into RDI/RSI/RDX, per the existing SysVRegs path at `emit_call.rs:723`. Every recipe begins with `mov rcx, rdx` because REP wants count in RCX; SysV puts arg-2 in RDX.

| Method | Recipe instruction sequence | Byte cost (post-encode) |
|--------|-----------------------------|-------------------------|
| `memcpy(dst,src,len)` | `mov rcx, rdx` ; `rep_movsb` | 3 + 2 = 5 |
| `memset(dst,val,len)` | `mov rax, rsi` ; `mov rcx, rdx` ; `rep_stosb` | 3 + 3 + 2 = 8 |
| `memcpy_qwords(dst,src,count)` | `mov rcx, rdx` ; `rep_movsq` | 3 + 3 = 6 |
| `memset_qwords(dst,val,count)` | `mov rax, rsi` ; `mov rcx, rdx` ; `rep_stosq` | 3 + 3 + 3 = 9 |

All four recipes use `ArgConvention::SysVRegs`, `labels: vec![]`. Structural template: exactly the `ChecksumOps::ipv4_checksum` recipe pattern (`stdlib_lowering.rs:865`) minus the label/Jcc plumbing. The `build_inst` / `make_ops` closure helpers copy cleanly.

**Contract carried in trait doc-comment** (`bulkmem.pdx` lines 3-9, already landed): DF must be clear at call site; `val: u64` upper bits ignored for byte memset (STOSB reads AL only). Recipes emit no CLD — caller is responsible.

## 5. Canary fixtures (5 total)

1. **Encoder round-trip** (`crates/paideia-as-encoder/src/encode_instruction.rs::tests`): `encode_rep_stosb_round_trips`, `encode_rep_stosb_rejects_operand`, `encode_rep_movsq_round_trips`, `encode_rep_movsq_rejects_operand`. Mirror `encode_rep_stosq_round_trips` at line 4668 verbatim, swapping byte constants.
2. **Build-emit smoke** (`tests/build-emit/rep_stosb_smoke.pdx`, `rep_movsq_smoke.pdx`): 4 lambda variants each (bare / after-cld / after-label / labeled-cld) mirroring `rep_movsb_smoke.pdx`. Drives parser → walker → encoder end-to-end; asserts `.text` contains the exact byte sequence.
3. **Recipe-shape unit tests** (`stdlib_lowering.rs::tests`): 4 tests, one per method, asserting `recipe.instructions.len() == 2 or 3`, first mnemonic is `Mov` with `(RCX,RDX)` operands, terminal mnemonic matches expected `Rep*`, `arg_convention == SysVRegs`. Style: copy `bytes_ops_get_u8_recipe_exists` (`stdlib_bytes.rs:14`).
4. **Integration lowering** (`tests/lowering/stdlib_bulkmem.rs`): 4 tests calling `lower_stdlib_method("BulkMemOps", ...)`. Pattern: exact copy of `stdlib_bytes.rs`.
5. **Runtime execution canary** (`tests/build-emit/bulkmem_runtime.pdx`, driven from a new `crates/paideia-as/tests/build_emit/bulkmem.rs`): three lambdas — `memcpy_100_bytes`, `rep_movsq_32_bytes` (i.e. 4 quadwords), `memset_0xAA_fill_64`. Static-linker + tiny runtime harness runs the ELF; asserts destination buffer bit-equals the expected pattern. This is the sole *observable* correctness canary; the four items above are structural.

## 6. Backtrack candidates (file, do not fold)

1. **`RepMovsb` arity misclassification** — declared under the *one-operand* block (`instruction.rs:895`) despite being semantically zero-arity (encoder rejects operands at line 3267). Cosmetic today; if #1064's caller ever synthesises `RepMovsb` with a placeholder operand, silent-encode risk. File as separate issue; **do not port the anomaly to `RepStosb`/`RepMovsq`**.
2. **`RepStosq` estimated-size = 2** (`instruction.rs:1155`) contradicts the 3-byte encoding `F3 48 AB` at `encode.rs:4527`. Under-reports `.text` size; probably harmless because the emitter re-measures on assembly, but branch-displacement heuristics may pick short encodings when they should not. New mnemonics: `RepStosb = 2` (correct), `RepMovsq = 3` (correct); file `RepStosq` correction as follow-up.
3. **Automatic `cld` prologue** — softarch's Phase 1 note carries "DF-clear" as a doc-comment contract only. Consider auto-prefixing each `Rep*` recipe with `cld` (1 byte) to make the contract self-enforcing. Trade-off: 1 wasted byte per call when caller already cleared DF; symmetric safety when they didn't. Recommend measuring after Phase 2 lands and paideia-os stdlib begins calling `memcpy` in hot paths.
4. **Clobber-tracking interaction (#1034)** — recipes clobber RCX, RSI, RDI, RAX (memset only), plus RDX (via the mov-to-rcx). Verify the SysVRegs splice path at `emit_call.rs:723` correctly records these in the caller's clobber set. If it does not, subsequent instructions in the caller that expected RCX to survive will silently break. Diff-drive check: add a test that calls `BulkMemOps::memcpy` between two live `let x = 5` bindings pinned to RCX.

## 7. Prereq gaps

None blocking. #1062 (`ArgConvention::SysVRegs`), #1034 (clobber tracking), #1064 Phase 1 (trait + design doc) all landed. Trait doc-comment for DF-clear contract is already in `bulkmem.pdx`. **Green light for a single PR of ~950 LOC.**
