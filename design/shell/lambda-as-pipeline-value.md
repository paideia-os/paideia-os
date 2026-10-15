# Lambda as first-class pipeline value — R224.M6

Parent: paideia-os#2488. Milestone: paideia-os#2680.

## Scope

A lambda is a VALUE in the semantic shell: it can be bound in a
`let`, stored in a session variable, passed to a combinator (`filter`,
`sort`, `reduce`), and piped through `|` just like any other typed
record. R224.M6 lands the parser-tier substrate for that semantic
reality: a 32-byte **PipelineLambda** record that packs a lambda's
four parser-tier handles (literal, closure env, effect row,
capability row) into a single boxed value, plus three APIs over it:

- `_pl_lam_box` — build a PipelineLambda from four pool indices.
- `_pl_lam_unbox` — decompose a PipelineLambda into its four indices.
- `_pl_lam_apply_to_combinator` — thread a PipelineLambda reference
  into a FilterOp / SortGroupReduce combinator record so the HM pass
  resolves the predicate against the boxed lambda rather than
  re-parsing the body byte span.

The acceptance driver for the issue brief is the end-to-end example:

```
find . | filter { |f| f.size > 1.MB } | sort by { |f| f.size } desc
```

At parse time each `|`-stage emits its own record (FilterOp +
SortGroupReduce). When a lambda flows AS A VALUE through the pipe
(rather than as a literal inside a combinator's body span), the
upstream stage emits a PipelineLambda record and the downstream
stage calls `_pl_lam_apply_to_combinator` to graft the lambda handle
into the combinator's reserved tail. The HM pass (R225) then
elaborates the combinator against the boxed lambda's type scheme.

## Why a 32-byte box (not a direct byte span)

Three options were considered:

1. **Byte-span handoff (status quo pre-M6).** Each combinator stores
   `predicate_lambda_ref = (body_offset << 32) | body_len` as a byte
   span into the original source. Pro: no new record type. Con: a
   lambda bound to a `let` variable or stored in a session variable
   needs a reparse at every re-use because the source bytes are
   long gone.
2. **Direct LambdaLit pool reference.** Combinators store a u32
   pool index straight into R224.M1's LambdaLit pool. Pro: one
   indirection. Con: no slot for the closure env, effect row,
   capability row — a lambda value is more than a bare literal
   handle.
3. **Boxed 32-byte PipelineLambda record (CHOSEN).** Carries all
   four handles plus a flag byte and reserved tail for M6.1+
   growth. Pro: one uniform 32-byte stride that composes with every
   R223 pipeline-stage POST-pass record (FilterOp 32 B,
   SortGroupReduce 32 B); supports future rank-restriction and
   cross-session serialisation without an ABI break. Con: slightly
   more parse-time work to allocate.

Option 3 wins because the pipeline-stage POST-pass taxonomy already
pays the 32-byte stride cost on every stage; threading a lambda
value through the SAME stride keeps the dispatcher's walker loop
free of per-record-type branching, and the four u32 slots give the
HM pass the structural handles it needs without a byte-span reparse.

## PipelineLambda record (32 B)

```
0x00 u32  magic              = 'PLAM' (0x4D414C50 LE)
0x04 u16  flags
                              bit 0 = PL_LAM_FLAG_CLOSURE
                                      (set iff closure_env_idx != 0)
                              bit 1 = PL_LAM_FLAG_HAS_EFFECT
                                      (set iff effect_row_idx != 0)
                              bit 2 = PL_LAM_FLAG_HAS_CAP
                                      (set iff cap_row_idx != 0)
                              bits 3..15 reserved
0x06 u16  reserved           = 0
0x08 u32  lambda_lit_idx     — R224.M1 LambdaLit pool idx (opaque at
                               M6)
0x0C u32  closure_env_idx    — R224.M2 ClosureCapture pool idx (0 if
                               no captures)
0x10 u32  effect_row_idx     — R224.M3 EffectRow / R225.M2 RowTypes
                               pool idx (0 if pure)
0x14 u32  cap_row_idx        — R224.M4 CapRow / R225.M2 RowTypes
                               pool idx (0 if ambient)
0x18 u64  reserved           = 0 (reserved for M6.1+: closure arena
                                  ref, HM scheme id, source span)
```

Total: 32 B.

**Layout note.** The parent brief sketches a 40-byte shape with four
u64 slots. The pool indices themselves are u32-wide (every pool in
this library — HmCore, RowTypes, LambdaLit, ClosureCapture — caps at
<2^31 entries), so the record collapses to 32 B. The 8-byte reserved
tail at offset 24 holds any future u64-wide handle without an ABI
break (consumers probe via field offsets, not sizeof).

## Public API

- `_pl_lam_init()` — idempotent boot hook. No `.bss` state at M6; the
  body is a bare `ret`.
- `_pl_lam_box(ll_idx, cc_idx, er_idx, cr_idx, out, out_cap)` —
  packs the four u32 pool indices into a 32-byte record at `out`.
  Validates each idx fits in u32 (high 32 bits zero); refuses
  `out == 0` or `out_cap < 32`. Returns `(32 << 32) | PL_LAM_OK` on
  success.
- `_pl_lam_unbox(record, record_len, out_ll, out_cc, out_er, out_cr)`
  — reads a PipelineLambda record and writes its four u32 indices
  (zero-extended to u64) into the caller-supplied out slots. Any
  out-ptr may be 0 to skip writing that field.
- `_pl_lam_apply_to_combinator(pipelam, pipelam_len, comb, comb_len)`
  — validates the PipelineLambda magic + combinator magic, writes
  the PipelineLambda's `lambda_lit_idx` into `[comb + 28]`, and sets
  the "lambda-sourced predicate" flag bit in the combinator's flags
  byte:
    - FilterOp:            `flags u8 at +17`, bit 1 (0x02).
    - SortGroupReduce:     `flags u8 at +5`,  bit 2 (0x04).

Both poke locations sit in slots the parent records explicitly
reserved for M3.1+ / M4.1+ follow-ups and are available at raw M6.

## Status band

`0x5000..0x50FF`. Nine slots used at M6:

- `PL_LAM_OK                        = 0`
- `PL_LAM_ERR_SYNTAX                = 0x5000` (reserved for M6.2
  `_pl_lam_parse_literal`)
- `PL_LAM_ERR_OUT_TOO_SMALL         = 0x5001`
- `PL_LAM_ERR_BAD_MAGIC             = 0x5002`
- `PL_LAM_ERR_RECORD_TOO_SMALL      = 0x5003`
- `PL_LAM_ERR_NULL_OUT              = 0x5004` (reserved for a future
  strict-mode unbox)
- `PL_LAM_ERR_BAD_COMBINATOR        = 0x5005`
- `PL_LAM_ERR_COMBINATOR_TOO_SMALL  = 0x5006`
- `PL_LAM_ERR_NULL_RECORD           = 0x5007`
- `PL_LAM_ERR_BAD_INDEX             = 0x5008`

Slots `0x5009..0x50FF` reserved for M6.1+ (closure-arena allocation
faults, cross-session recover faults, rank-restriction violations,
etc.).

Disjoint from every prior landed band (0x4A00 FuzzHarness, 0x4C00
FilterOp, 0x4D00 SortGroupReduce, 0x4E00 JobControl, 0x4F00 reserved
for the parallel R222.M8 Wave 125 arm).

## Acceptance

The end-to-end driver sentence is:

```
find . | filter { |f| f.size > 1.MB } | sort by { |f| f.size } desc
```

Parse-time behaviour per stage:

1. `find .` emits one PipelineStage record (R223.M1). No lambda.
2. `filter { |f| f.size > 1.MB }` emits one FilterOp record (R223.M3)
   with its predicate body stored as a byte span. If the enclosing
   context already has a PipelineLambda for that predicate (e.g.
   because the lambda was bound to a `let`), the dispatcher calls
   `_pl_lam_apply_to_combinator` to graft the box onto the FilterOp
   record.
3. `sort by { |f| f.size } desc` emits one SortGroupReduce record
   (R223.M4). Same lambda-wire-up as step 2 if applicable.

A per-turn fingerprint is produced by hashing the 32-byte
PipelineLambda record (if emitted) + the two combinator records.
The three records contain the lambda handle, the body byte span, the
sort direction, and the combinator kinds, so the fingerprint
uniquely identifies the parse outcome.

The 8-test acceptance corpus (deferred to R223.M7 fuzz-corpus
follow-up) covers:

1. `_pl_lam_box` with all four indices nonzero → flags = 0x07.
2. `_pl_lam_box` with closure_env_idx = 0 → flag bit 0 clear.
3. `_pl_lam_box` with effect_row_idx = 0 → flag bit 1 clear.
4. `_pl_lam_box` with cap_row_idx = 0 → flag bit 2 clear.
5. `_pl_lam_unbox` round-trip against step 1 → all four out slots
   equal the input indices.
6. `_pl_lam_apply_to_combinator` on a FilterOp record → bytes 28..32
   of the FilterOp record carry the lambda_lit_idx; FilterOp flags
   bit 1 is set.
7. `_pl_lam_apply_to_combinator` on a SortGroupReduce SORT record →
   bytes 28..32 carry the idx; SortGroupReduce flags bit 2 is set.
8. `_pl_lam_apply_to_combinator` with a combinator magic not in
   {FILT, SORT, GRPS, REDU} → returns `PL_LAM_ERR_BAD_COMBINATOR`
   (0x5005) and does NOT modify the combinator record.

## Interactions

- **R223.M3 FilterOp** — destination record shape for `_pl_lam_apply_
  to_combinator`'s FILT path.
- **R223.M4 SortGroupReduce** — destination record shape for the
  SORT / GRPS / REDU paths.
- **R224.M1 LambdaLit** — source of the `lambda_lit_idx` pool
  references.
- **R224.M2 ClosureCapture** — source of the `closure_env_idx` pool
  references.
- **R224.M3 EffectRow** — source of the `effect_row_idx` pool
  references.
- **R224.M4 CapRow** — source of the `cap_row_idx` pool references.
- **R224.M5 LetScope** — orthogonal. A PipelineLambda carries only
  the lambda's own handles; the enclosing `let` chain is walked
  through `lambda_lit_idx -> LambdaLit record -> Param list` at HM
  time, not through this record.
- **R225 HM** — instantiates a PipelineLambda consumer at the
  combinator-expected shape: `fn (Record) -> bool` (FilterOp),
  `fn (Record) -> Comparable` (SORT), `fn (Record) -> Hashable`
  (GROUP), `fn (A, Record) -> A` with seed `A` (REDUCE).

## Encoder discipline

Standard across the pds-parser family:

- No `test rN, rN`; use `cmp reg, 0; je/jne`.
- No `and rN, imm64`; masks fit in imm8 (bit flags 0x01..0x04) or
  imm32 (status codes, magic FourCCs — all with bit 31 clear).
- No 2-op `imul r, imm`; no stride-indexed arithmetic in this module.
- No multiline `pub let = "..."`; single-line justifications.
- Module basename `PipelineLambda` matches `pipeline_lambda.pdx`.
- Public symbols `_pl_lam_*`; internal labels `pl_lam_*`. The prefix
  is grep-disjoint from pipeline.pdx's `pl_` prefix because of the
  extra two bytes `lam_`.
- Byte loads via `xor rax, rax; mov_b rax, [base + idx * 1]` with
  explicit `*1` scale.
- Byte stores via `mov_b [dst + imm_disp], reg` with constant
  displacement.
- u32 loads via `xor rax, rax; mov_d rax, [base + imm_disp]`.
- u32 stores via `mov_d [dst + imm_disp], reg`.
- u64 zero-fill of the 32-byte record uses four `mov [dst + disp],
  rax` with rax = 0.
- OR-into-byte uses imm8 flag mask (fits in `or r64, imm8`).
- All four public entry points are PURE LEAVES: zero callee-save
  pushes, zero stack frame, zero nested CALL. The SysV scratch set
  (rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11) carries every live
  value; `r11` is used freely as the OR-into-byte staging register
  because no nested CALL exists.

## Forward path

- **M6.1** — closure environment materialisation helper that walks
  `closure_env_idx` and emits the Serializable Binding array for
  cross-process invocation.
- **M6.2** — one-shot `_pl_lam_parse_literal` that parses a lambda
  source span, allocates the LambdaLit + ClosureCapture handles,
  and returns a fully-boxed PipelineLambda in one call.
- **M6.3** — cross-session serialisation (`_pl_lam_render` /
  `_pl_lam_recover`) threaded through R229.M6 persistent env.
- **M6.4** — rank-restriction propagation (dual with R225.M6);
  refuses PipelineLambda whose scheme has rank > 1 at any
  combinator-consume site.

## References

- `design/terminal/semantic-shell-language-plan.md` §4 R224 row M6
- `tools/user/libpdx-pds-parser/src/pipeline_lambda.pdx`
- `tools/user/libpdx-pds-parser/src/lambda_lit.pdx` (R224.M1)
- `tools/user/libpdx-pds-parser/src/closure_capture.pdx` (R224.M2)
- `tools/user/libpdx-pds-parser/src/effect_row.pdx` (R224.M3)
- `tools/user/libpdx-pds-parser/src/cap_row.pdx` (R224.M4)
- `tools/user/libpdx-pds-parser/src/filter_op.pdx` (R223.M3)
- `tools/user/libpdx-pds-parser/src/sort_group_reduce.pdx` (R223.M4)
