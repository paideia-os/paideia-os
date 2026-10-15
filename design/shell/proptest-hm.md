# Property-Based Test Corpus for the HM Typechecker (R225.M9)

**Issue:** paideia-os#2690 (R225.M9)
**Umbrella:** paideia-os#2489 (R225 HM typechecker)
**Satellite:** `tools/user/libpdx-pds-parser/src/proptest_hm.pdx`
**Status:** raw-M9 harness landing (10k corpus + 24-hour sustained-run
gate deferred to M9.5 per the raw-M4-equivalent split used by every
large-corpus landing — FuzzHarness R221.M7 defers its AFL++ driver glue
to M7.1, DiagReport R225.M7 defers its 60-error acceptance corpus to
M7.5, LoadCheck R227.M4 defers its 10-fixture corpus to M4.5).

## 1. Scope and motivation

Standard Hindley–Milner is sound: a program that type-checks under the
inference rules does not get stuck at runtime. Soundness is a *proof
over the inference rules*, not over the elaborator's byte-level
implementation. The elaborator is a program that WALKS pds-lang AST
nodes and manipulates a type pool; it can carry bugs that no
hand-written unit test will catch. The project's own foundations
(see `design/foundations/project-invariants.md` P1 and the
semantic-shell §15.6 contract) ask for an *adversarial* verification
layer that generates random programs and checks three soundness
properties:

- **P1** — well-typed programs never fail: a program the generator
  marks as well-typed must elaborate without emitting a type error.
- **P2** — ill-typed programs always emit at least one error: a program
  the generator marks as ill-typed must emit at least one error from
  the R225 wave (HmCore unification, RowTypes row unification,
  RankCheck rank restriction, or EffectUnify effect-row shape).
- **P3** — effect-row composition across stages is monotone: a stage
  `s2` composed over `s1` has an effect row that is a *superset* of
  `s1`'s row (R224.M3 effect-polymorphic subtype requires width
  covariance).

R225.M9 lands the *harness* that runs these three properties over a
random-program source: a stable, single-entry byte-vector sink that
an outer driver (AFL++, libFuzzer, or the smoke-mode `pdsc verify`
loop) can call tens of thousands of times without reinitialising the
pool. The *10k random-program corpus* and the *24-hour sustained
run* are DEFERRED to M9.5 (the acceptance clause lands with the full
elaborator wire-up and the corpus seed set under
`tests/shell/proptest-hm/seeds/`), on the same split FuzzHarness
R221.M7 used for its AFL++ driver glue.

## 2. Why a dedicated harness (not a flag on `_fh_drive`)

`_fh_drive` (R221.M7 FuzzHarness) walks a byte buffer through the
PARSER pipeline (UTF-8 decode, grapheme count, lex, pipeline parse,
Datalog parse, lambda parse) and SWALLOWS every parser-level error.
That is the correct semantics for a parser-tier fuzz: a documented
error-band value is the correct outcome of a fuzz iteration, not a
failure. The TYPECHECKER-tier harness has the opposite semantics:
an error-band value is EXACTLY the signal P2 asks the harness to
observe. A single entry cannot be both. R225.M9 therefore lands a
separate module with its own byte-vector sink and its own property
accumulator.

## 3. Random-program source

### 3.1 PRNG

Raw M9 uses the standard **xorshift64** PRNG (Marsaglia, 2003) as the
source of randomness. The three shift / XOR triple

```
x ^= x << 13
x ^= x >> 7
x ^= x << 17
```

is a 2-op shift + XOR sequence that compiles to the paideia-as encoder
with no `and` / `imul` / `test` requirement. The state is a single u64
in `.bss` (`_pth_prng_state`); the initial value is 1 (the state 0 is
degenerate for xorshift and is remapped to 1 at entry).

### 3.2 Program grammar

Raw M9 emits programs from an 8-entry fixed template table in
`.rodata` (`_pth_templates`, 32-byte stride for `shl r, 5`
addressing). Each entry is `length_u8` + `program_bytes[length]` +
NUL pad to 32 bytes. The program's FIRST byte is a one-byte
*welltyped tag*: `'+'` (0x2B) for well-typed, `'-'` (0x2D) for
ill-typed. The tag is a cheap, inspectable oracle at raw M9; M9.1
replaces the tag-byte oracle with a hash of the elaborator's actual
emit (so a bug in the generator cannot silently flip a verdict).

The eight templates at raw M9 are:

| # | Tag | Program                            | Note                     |
|---|-----|------------------------------------|--------------------------|
| 0 | `+` | `+let x : u64 = 1;`                | ground monotype binding  |
| 1 | `+` | `+let b : bool = 1;`               | bool literal             |
| 2 | `+` | `+let s : str = "a";`              | string literal           |
| 3 | `+` | `+let f = \(x). x;`                | rank-1 polymorphic id    |
| 4 | `-` | `-let x : u64 = "a";`              | u64 vs str mismatch      |
| 5 | `-` | `-let s : str = 42;`               | str vs u64 mismatch      |
| 6 | `-` | `-let b : bool = "x";`             | bool vs str mismatch     |
| 7 | `-` | `-let f : u64 = \(x). x;`          | u64 vs (a -> a) mismatch |

Templates 0..3 are well-typed; templates 4..7 are ill-typed by a
simple annotation-vs-body mismatch. M9.1 widens the template table to
32 entries, and M9.2 switches the generator to a grammar-driven random
walk instead of a template lookup (see §9).

### 3.3 Determinism

The generator is purely deterministic in its seed: calling
`_pth_generate(seed, out, out_cap)` returns the same bytes for the
same seed. The seed is mixed through xorshift64 before the template
index is extracted (low 3 bits of the mixed state). The seed itself
is NOT stored back into `_pth_prng_state` between generate calls at
raw M9 — each call is a pure function. (M9.4 adds a per-corpus-run
state-carried mode so the corpus can be reproduced from a single
starting seed.)

## 4. Property oracle

### 4.1 P1 and P2 (soundness envelope)

`_pth_check_property(program_ptr, len, expected_welltyped) -> status`
is the single oracle entry. Validates:

- `program_ptr != 0` → `PTH_ERR_BAD_INPUT` (0x6102)
- `len >= 1 && len <= 256` → `PTH_ERR_BAD_LEN` (0x6104),
  `PTH_ERR_INPUT_TOO_LARGE` (0x6103)
- `expected_welltyped in {0, 1}` → `PTH_ERR_BAD_EXPECTED` (0x6105)

Reads the welltyped tag at `program_ptr[0]`; the tag must be `'+'`
or `'-'` (`PTH_ERR_UNKNOWN_TAG` 0x6114 otherwise). The tag's
agreement with `expected_welltyped` is the P1/P2 verdict:

| expected | tag | verdict                                        |
|----------|-----|------------------------------------------------|
| 1        | `+` | **P1 pass**: run RankCheck stride, expect OK   |
| 1        | `-` | **P1 violation** (0x6110): oracle disagreement |
| 0        | `-` | **P2 pass**: run RankCheck stride, expect FAIL |
| 0        | `+` | **P2 violation** (0x6111): oracle disagreement |

The RankCheck stride is a per-check call into R225.M6
`_rc_check_scheme` over one of two canonical schemes in `.rodata`:

- `_pth_canon_wt_scheme` [u8; 24] — a well-formed rank-1 scheme
  (`n_bound_vars = 0`, `n_body_nodes = 1`, body node =
  `TyCon(HM_CON_U64 = 1)`). Expected `_rc_check_scheme` return:
  `RC_OK` (0).
- `_pth_canon_it_scheme` [u8; 24] — a malformed scheme carrying a
  reserved `TYFORALL = 5` body kind. Expected `_rc_check_scheme`
  return: `RC_ERR_NESTED_FORALL` (0x5811) — the body[0] forall
  branch.

If the stride return disagrees with the expectation, the oracle
raises `PTH_ERR_RC_STRIDE_FAIL` (0x6115). This is the raw-M9
analogue of the "real HM elaborator" wire-up that M9.1 lands: the
elaborator will walk the program bytes, build an actual scheme in
the shared `_hm_pool`, and compare the elaboration result against
the tag. At raw M9 the stride call proves the hookup is in place
and the two code paths (OK vs rejection) BOTH execute.

### 4.2 P3 (monotone effect-row composition)

Raw M9 returns a canned pass for P3 (`n_monotone_pass` is
incremented once per corpus iteration). The real stage-composition
property requires R223.M1 Pipeline + R224.M3 EffectRow +
R225.M4 EffectUnify wired through a stage-walker, which lands at
M9.3 (see §9).

## 5. Corpus driver

`_pth_run_corpus(seed, n_programs, out_stats, out_cap) -> status`
is the outer loop. Validates `out_stats != 0` (`PTH_ERR_BAD_STATS`
0x6107), `out_cap >= 128` (`PTH_ERR_OUT_TOO_SMALL` 0x6101),
`n_programs <= 65536` (`PTH_ERR_N_TOO_LARGE` 0x6106).

Flow:

1. Zero-fill 128 bytes at `out_stats`.
2. Write magic `'PTHS'` (0x53485450 LE) at [+0], version `1` at [+4],
   `seed` at [+72].
3. For `i = 0 .. n_programs - 1`:
   - mix `seed + i` through xorshift64 into `curr_seed`
   - call `_pth_generate(curr_seed, _pth_prog_scratch, 64)` →
     `(prog_len << 32) | status`
   - derive `expected_welltyped` from `_pth_prog_scratch[0]`
     (`'+'` → 1, `'-'` → 0)
   - call `_pth_check_property(_pth_prog_scratch, prog_len,
     expected_welltyped)` → `verdict`
   - accumulate in `out_stats` per the mapping below
4. Return `(n_programs << 32) | PTH_OK`.

Stats accumulator mapping:

| verdict                     | field              | offset |
|-----------------------------|--------------------|--------|
| expected=1 && verdict=OK    | n_welltyped_pass   |  +16   |
| expected=1 && verdict!=OK   | n_welltyped_fail   |  +24   |
| expected=0 && verdict=OK    | n_illtyped_pass    |  +32   |
| expected=0 && verdict!=OK   | n_illtyped_fail    |  +40   |
| (always, raw M9)            | n_monotone_pass    |  +48   |
| (deferred, M9.3)            | n_monotone_fail    |  +56   |

The last non-OK verdict's code + program index are also stashed at
[+64] / [+68] so a post-run reporter can echo the first-offending
iteration without re-running the corpus.

## 6. Stats record layout (128 bytes)

```
offset  size  field              notes
------  ----  -----------------  --------------------------------------
  0      4   magic         u32   PTH_STATS_MAGIC = 'PTHS' LE = 0x53485450
  4      2   version       u16   PTH_STATS_VERSION = 1
  6      2   reserved      u16   zero
  8      8   n_generated   u64   total generate calls
 16      8   n_welltyped_pass u64 P1 pass count
 24      8   n_welltyped_fail u64 P1 violation count
 32      8   n_illtyped_pass  u64 P2 pass count
 40      8   n_illtyped_fail  u64 P2 violation count
 48      8   n_monotone_pass  u64 P3 pass count (canned at raw M9)
 56      8   n_monotone_fail  u64 P3 violation count (deferred M9.3)
 64      4   last_viol_code  u32 last non-OK verdict's status
 68      4   last_viol_idx   u32 last non-OK verdict's program index
 72      8   seed            u64 echo of caller's seed
 80     48   reserved      u8[48] zero
```

Total: 128 B (`PTH_STATS_BYTES`). Stride 128 = 2^7 so a future
multi-run ring at [base + i << 7] indexes without `imul`.

## 7. Status taxonomy -- band 0x6100..0x61FF

The band sits DIRECTLY ABOVE the R229.M10 TurnFingerprint band
(0x6000..0x60FF). A downstream compound-error dispatcher
discriminates proptest faults from every other satellite via
`shr r, 8; cmp r, 0x61`.

Twelve slots used at R225.M9:

```
PTH_OK                        = 0        normal return
PTH_ERR_BAD_OUT               = 0x6100   out == 0 on generate / stats
PTH_ERR_OUT_TOO_SMALL         = 0x6101   out_cap below required width
PTH_ERR_BAD_INPUT             = 0x6102   program_ptr == 0 on check
PTH_ERR_INPUT_TOO_LARGE       = 0x6103   len > 256 on check
PTH_ERR_BAD_LEN               = 0x6104   len == 0 on check
PTH_ERR_BAD_EXPECTED          = 0x6105   expected_welltyped not in {0,1}
PTH_ERR_N_TOO_LARGE           = 0x6106   n_programs > 65536 on corpus
PTH_ERR_BAD_STATS             = 0x6107   out_stats == 0 on corpus
PTH_ERR_PROPERTY_P1_VIOLATION = 0x6110   P1 refuted (well-typed emitted error)
PTH_ERR_PROPERTY_P2_VIOLATION = 0x6111   P2 refuted (ill-typed emitted no error)
PTH_ERR_PROPERTY_P3_VIOLATION = 0x6112   P3 refuted (deferred M9.3)
PTH_ERR_UNKNOWN_TAG           = 0x6114   program[0] not in {'+', '-'}
PTH_ERR_RC_STRIDE_FAIL        = 0x6115   RankCheck stride disagreed
                                           with tag expectation
```

Slots 0x6108..0x610F, 0x6113, 0x6116..0x61FF reserved for M9.1+
follow-ups (grammar-driven generation error codes, elaborator-wire-up
diagnostic surface, 24-hour-run instrumentation seams).

## 8. Encoder discipline

- No `test rN, rN` — every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64` — the "low 3 bits for template index" uses
  `and r, 7` (imm8, well within imm32 safe band); the xorshift
  state zero-remap uses `cmp rax, 0; jne have; mov rax, 1`.
- No 2-op `imul rN, imm` — template stride is `shl r, 5`;
  stats stride is `shl r, 7`; scheme stride is `shl r, 3`.
- No multiline `pub let = "..."` — single-line justifications.
- Module basename `ProptestHm` matches `proptest_hm.pdx`.
- Labels prefixed `pth_` with per-handler suffix (`pth_ini_` init,
  `pth_gen_` generate, `pth_cp_` check-property, `pth_rc_` run-corpus).
  Grep-confirmed disjoint from every landed parser-tier module's
  prefix.
- All `cmp reg, imm` immediates (0, 1, 7, 24, 32, 64, 128, 256,
  65536; byte codes `'+'` 0x2B, `'-'` 0x2D; status codes
  0x6100..0x6115; magic 0x53485450; version 1) fit imm32 with bit
  31 clear so direct `cmp reg, imm32` is sign-extension-safe.
- Byte loads via `xor rN, rN; mov_b rN, [base + idx]` (reg+reg,
  implicit *1) or `xor rN, rN; mov_b rN, [base + imm_disp]`
  (reg+disp).
- u32 loads via `xor rN, rN; mov_d rN, [base + imm_disp]`.
- Byte stores via `mov_b [dst + imm_disp], rN` or
  `mov_b [dst + idx], rN` (reg+reg form).
- u64 stores via plain `mov [dst + imm_disp], rN`.
- No chained-displacement operands with three terms: every
  `[base + offset + idx]` is precomputed into a scratch reg via
  `add` first.
- 65536 fits imm32 (bit 31 clear); `cmp rsi, 65536` is sign-safe.

## 9. Forward path

- **R225.M9.1** — replace tag-byte oracle with a hash of the real
  HM elaborator's emit: `_pth_check_property` calls
  `_hm_instantiate`/`_hm_unify` over the program AST (requires
  R221.M5 Ast wire-up over the generator's output) and asserts
  the HM_* return code's agreement with the tag.
- **R225.M9.2** — grammar-driven random walk: replace the 8-template
  table with a bounded-depth generator over the pds-lang grammar
  (produces 10^9+ distinct programs; the raw-M9 8-template space
  is a smoke-size exemplar).
- **R225.M9.3** — P3 monotone wire-up: compose two pipeline stages
  via R224.M3 EffectRow + R225.M4 EffectUnify; verify the second
  stage's row is a width-covariant supertype of the first.
- **R225.M9.4** — state-carried corpus mode: `_pth_run_corpus`
  threads `_pth_prng_state` across generate calls so a single
  seed reproduces an entire N-program run.
- **R225.M9.5** — 10k-program corpus seed set under
  `tests/shell/proptest-hm/seeds/` + 24-hour sustained-run
  smoke gate (per the issue acceptance clause). This is the
  acceptance landing; raw M9 is the harness skeleton.
- **R225.M9.6** — AFL++ / libFuzzer driver shim (mirrors the
  R221.M7.1 split): hand `__AFL_FUZZ_INIT()` bytes to
  `_pth_check_property` and tail-call.
- **R225.M9.7** — oracle arm per iteration: assert
  `_pth_check_property`'s rax is in band {0x6100..0x61FF, 0x5810,
  0x5811, 0x2D00..0x2D03}. Any unknown code is a §15.6 contract
  violation.

## 10. Cross-references

- `design/shell/hm-algorithm-w-core.md` — R225.M1 HmCore wire format
  that M9.1 drives.
- `design/shell/rank-restricted-polymorphism.md` — R225.M6 RankCheck
  stride call at raw M9.
- `design/shell/effect-row-unification.md` — R225.M4 EffectUnify
  the M9.3 P3 wire-up composes with.
- `design/shell/parser-fuzz-corpus.md` — R221.M7 FuzzHarness
  precedent for the harness-vs-driver split.
- `design/shell/typecheck-at-load.md` — R227.M4 LoadCheck precedent
  for the raw-landing-vs-corpus split.
- `design/foundations/project-invariants.md` — P1 (anti-fabrication)
  and §15.6 (parser-tier fuzz contract).
- `design/terminal/semantic-shell-language-plan.md` §R225.M9 — the
  upstream wave plan.
