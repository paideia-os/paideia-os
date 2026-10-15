# `sort by` / `group by` / `reduce` combinators — R223.M4

Parent: paideia-os#2487. Milestone: paideia-os#2669.

## Scope

Standard aggregation combinators over the typed-record stream flowing
through a pipeline. All three are parser-tier primitives in
`libpdx-pds-parser` that emit one 32-byte SortGroupReduce record per
pipeline stage; the HM pass (R225) elaborates the stored byte spans
into typed lambdas at type-check time; the pipeline-stage dispatcher
(R223.M4+) runs the lambdas against incoming records at execution
time.

```
ls | sort by size desc
ls | group by ext
ls | reduce { |acc, r| acc + r.size } 0
```

The three combinators share one 32-byte record because:

1. The pipeline-stage POST-pass taxonomy treats them as peer entries
   (standard functional idiom). A caller that wants to walk the parse
   output of all pipeline-stage POST-pass primitives in order iterates
   32-byte strides uniformly across FilterOp, SortGroupReduce, and
   future peers.
2. The parser-tier record discipline (16 or 32 bytes, powers of two)
   scales better by sharing one stride than by growing three disjoint
   16/24/40-byte shapes.
3. The `kind` byte at offset 4 provides a cheap per-record
   discriminator; the on-disk magic FourCC at offset 0 is per-kind so
   a hex-dump scan reads unambiguously.

## Grammar

```
Sort        ::= 'sort'   WS+ 'by' WS+ Expr (WS+ ('asc'|'desc'))?
Group       ::= 'group'  WS+ 'by' WS+ Expr
Reduce      ::= 'reduce' WS* '{' WS* '|' WS* Ident
                                     WS* ',' WS* Ident
                                     WS* '|' Body '}'
                WS+ SeedExpr
Ident       ::= [A-Za-z_] [A-Za-z0-9_]*       (len 1..SGR_NAME_MAX = 14)
Expr        ::= <opaque bytes; R224.M2 Expr grammar via R225 HM>
Body        ::= <any bytes until the first unescaped '}' (M4);
                 nested-brace balancing lands at M4.1>
SeedExpr    ::= <any bytes until EOI; CtxLexer-bounded>
WS          ::= 0x20 | 0x09 | 0x0A | 0x0D
```

Rejected:
- `sort`/`group` without a following `by` keyword.
- `sort`/`group` with an empty expression body after `by` (after
  trimming trailing WS and, for sort only, optional `asc`/`desc`
  suffix).
- `reduce` without a following `{`.
- `reduce { ...` without a matching `}`.
- `reduce { |...` whose binder prefix is not EXACTLY two
  comma-separated idents between a pair of `|`.
- A binder ident whose byte length exceeds `SGR_NAME_MAX` (14) or is
  empty.
- `reduce { ... }` with no non-WS seed expression after the closing
  `}` (seed is mandatory at M4; a reducer with no seed leaves the
  accumulator type ambiguous for R225 HM inference).

## SortGroupReduce record (32 B)

```
0x00 u32  magic           SORT  -> 0x54524F53 LE  (bytes 'S','O','R','T' on disk)
                          GROUP -> 0x53505247 LE  (bytes 'G','R','P','S' on disk)
                          REDU  -> 0x55444552 LE  (bytes 'R','E','D','U' on disk)
0x04 u8   kind            0 = SORT, 1 = GROUP, 2 = REDUCE
0x05 u8   flags           bit 0 = SGR_FLAG_DESC   (sort only; set
                                                   iff an explicit
                                                   `desc` suffix)
                          bit 1 = SGR_FLAG_HAS_SEED (reduce only;
                                                   always set for a
                                                   well-formed
                                                   REDUCE record)
                          bits 2..7 reserved
0x06 u16  reserved        zeroed; reserved for M4.1+
0x08 u64  predicate_span  (body_start << 32) | body_len; indexes the
                          CALLER-supplied bytes_ptr. body_start is
                          relative to the pointer AFTER the stripped
                          head keyword (bytes + 4 / +5 / +6 for sort
                          / group / reduce).
0x10 u64  seed_span       (seed_start << 32) | seed_len for REDUCE;
                          0 for SORT / GROUP (already zero-filled).
0x18 u64  reserved        zeroed; reserved for M4.1+
```

Total: 32 B (`SGR_RECORD_BYTES`).

### Magic reconciliation (parent brief)

The parent brief for R223.M4 reads:

```
magic — SORT='TROS'(0x53524F54 LE)
      / GRPS='SPRG'(0x53505247 LE)
      / REDU='UDER'(0x55444552 LE)
```

Storing u32 `0x53524F54` to memory LE yields on-disk bytes
`0x54,0x4F,0x52,0x53` = `"TORS"`, not `"SORT"`. The precedent
(`FilterOp`'s `'FILT'` magic: u32 `0x544C4946` → disk bytes `"FILT"`)
is to pick the four-byte ASCII tag that reads as the IDENTIFIER
when memory is scanned sequentially. This module stores:

- `SORT_MAGIC`  u32 = `0x54524F53`   (disk bytes `"SORT"`)
- `GROUP_MAGIC` u32 = `0x53505247`   (disk bytes `"GRPS"`)
- `REDUCE_MAGIC` u32 = `0x55444552`  (disk bytes `"REDU"`)

GROUP uses the four-byte tag `"GRPS"` rather than `"GROU"` (brief's
value matches) so the on-disk tag does not collide with other
FourCC prefixes in R221..R225. REDUCE uses `"REDU"` (brief's value
matches). SORT uses `"SORT"` (brief's hex was a transcription typo:
`0x53524F54` would spell `"TORS"`; the right u32 for `"SORT"` is
`0x54524F53`).

## Public API

- `_sgr_init()` — pure-leaf idempotent boot hook (no `.bss` at M4).
- `_sgr_skip_ws(bytes_ptr, bytes_len, cursor_in) -> cursor_out` —
  shared pure-leaf WS walker.
- `_sgr_parse_sort(bytes_ptr, bytes_len, out_ptr, out_cap) ->
  packed_u64`
- `_sgr_parse_group(bytes_ptr, bytes_len, out_ptr, out_cap) ->
  packed_u64`
- `_sgr_parse_reduce(bytes_ptr, bytes_len, out_ptr, out_cap) ->
  packed_u64`
- `_sgr_parse_impl(bytes_ptr, bytes_len, out_ptr, out_cap, kind) ->
  packed_u64` — internal shared body.

Status in low 32 bits; bytes-written (= 32 on success) in high 32
bits.

## Error band

`0x4D00..0x4D0A` (eleven codes); `0x4D0B..0x4DFF` reserved for M4.1+.

| Code     | Name                      | Meaning |
| -------- | ------------------------- | ------- |
| `0`      | `SGR_OK`                  | parse succeeded; 32B record emitted |
| `0x4D00` | `SGR_ERR_SYNTAX`          | grammar fault anywhere |
| `0x4D01` | `SGR_ERR_HEAD_MISMATCH`   | head keyword mismatch |
| `0x4D02` | `SGR_ERR_NO_BY`           | sort/group tail missing `by` |
| `0x4D03` | `SGR_ERR_EMPTY_BODY`      | expression body empty after trim |
| `0x4D04` | `SGR_ERR_NO_OPEN_BRACE`   | reduce tail did not start with `{` |
| `0x4D05` | `SGR_ERR_NO_CLOSE_BRACE`  | reduce reached EOI before `}` |
| `0x4D06` | `SGR_ERR_NO_PIPE`         | reduce binder prefix missing a `|` |
| `0x4D07` | `SGR_ERR_NAME_TOO_LONG`   | reduce binder ident > SGR_NAME_MAX (14) |
| `0x4D08` | `SGR_ERR_NO_SEED`         | reduce missing a seed expression |
| `0x4D09` | `SGR_ERR_BAD_KIND`        | impl called with kind > 2 |
| `0x4D0A` | `SGR_ERR_OUT_TOO_SMALL`   | out_cap < SGR_RECORD_BYTES (32) |

## Sort direction suffix handling

The optional `asc` / `desc` suffix is parsed as a trailing TOKEN
rather than a syntactic reduction because the preceding Expr body is
OPAQUE at parse time (its R224 Expr grammar is parsed later by
_ll_parse at HM time). The algorithm:

1. Set `body_end := bytes_len` (CtxLexer-bounded).
2. Trim trailing WS: while `body_end > body_start` and
   `byte[body_end - 1]` is WS, decrement `body_end`.
3. Attempt `desc` match (4 bytes): if the last four bytes before
   `body_end` are `d`,`e`,`s`,`c` AND the byte before them is WS or
   `body_start`, set the DESC flag and `body_end -= 4`; re-trim WS.
4. Else attempt `asc` match (3 bytes): same shape; DESC flag stays
   clear; `body_end -= 3`; re-trim WS.
5. Else: DESC flag stays clear (default ascending direction).
6. Verify `body_end > body_start`; else `SGR_ERR_EMPTY_BODY`.
7. Emit `predicate_span = (body_start << 32) | (body_end - body_start)`.

Edge cases covered:
- `sort by name_desc` — the `_desc` is PART of the identifier
  `name_desc`; the token-boundary check (preceding byte must be WS)
  fails, so `desc` is NOT stripped. The whole `name_desc` goes into
  the predicate span and DESC flag stays clear.
- `sort by size   desc   ` — leading WS between `by` and `size` is
  stripped by `_sgr_skip_ws`; trailing WS after `desc` is stripped
  by trim1; the `desc` suffix is matched (preceded by a WS run); the
  predicate span becomes `size` after trim2.
- `sort by foo desc asc` — only the LAST token is considered; the
  `asc` is stripped as the direction suffix (DESC flag stays clear),
  then the predicate span is `foo desc` with DESC flag CLEAR. The
  user that wrote `foo desc asc` presumably meant to express a
  compound expression; the parser does not second-guess.

## Reduce binder-pair handling

The brief lists the grammar as `PipeBinder PipeBinder` with
`PipeBinder ::= '|' Ident '|'`. The English note disambiguates:
"`reduce { |acc, r| ... } 0` uses TWO binders in the pipe prefix".
This module adopts the clarified form:

```
'|' WS* Ident WS* ',' WS* Ident WS* '|'
```

i.e. two comma-separated idents between a SINGLE pair of `|` — the
standard functional idiom (Ruby, Rust, Haskell `\acc r ->`) and
consistent with FilterOp's `BinderList` grammar. The two-pipe-pair
form `|acc| |r|` is NOT accepted at M4; a reducer attempting that
layout fails with `SGR_ERR_SYNTAX` on the comma check.

## Encoder discipline

Standard paideia-as encoder discipline (per
`feedback_pdx_encoder_pitfalls`):

- No `test rN, rN` — every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64` — every mask is imm8 or imm32.
- No 2-op `imul r, imm` — the module has no stride-indexed array
  arithmetic (one 32-byte record emit per entry point).
- No multiline `pub let = "..."` — single-line justifications.
- Module basename `SortGroupReduce` matches `sort_group_reduce.pdx`.
- Public symbols prefixed `_sgr_*`; internal labels prefixed `sgr_*`.
  The `sgr_` prefix is disjoint from every sibling satellite's
  prefix (`u8n_`, `gi_`, `wp_`, `cl_`, `ast_`, `sm_`, `sch_sig_`,
  `cmd_sig_`, `fi_`, `afs_`, `cmdreg_`, `dm_`, `pl_`, `rp_`, `fo_`,
  `ll_`, `cc_`, `er_`, `cr_`, `ls_`, `hm_`, `rt_`, `dl_`, `se_`,
  `te_`, `eu_`) and from paideia-as reserved keywords.
- All `cmp reg, imm` immediates fit in imm32 with bit 31 clear
  (ASCII literals, SGR_NAME_MAX = 14, SGR_RECORD_BYTES = 32, kind
  constants 0..2, status codes 0x4D00..0x4D0A, magic u32s). No
  MOVABS staging.
- Byte loads via `xor rax, rax; mov_b rax, [base + idx * 1]` with
  explicit *1 scale. Byte stores via `mov_b [dst + disp], reg` with
  constant displacement only (no `[reg + reg*1 + imm]` form — the
  encoder synthesises those via a scratch `add`).
- u32 stores via `mov_d [dst + disp], reg` (precedent: FilterOp
  magic write).
- `_sgr_init` and `_sgr_skip_ws` are pure-leaf — zero pushes, zero
  stack frame, zero nested CALL.
- `_sgr_parse_impl` has a 6 callee-save push + 24 B scratch frame:
  push rbx, rbp, r12, r13, r14, r15 (= 48 B) + sub rsp, 24. Entry
  rsp%16==8; +48 pushes = %16==8; +24 scratch = %16==0 at every
  nested CALL into `_sgr_skip_ws`.
- Public wrappers (`_sgr_parse_sort`, `_sgr_parse_group`,
  `_sgr_parse_reduce`) are 1-callee-save-push wrappers (push rbx +
  inline keyword verification + mov r8, <kind> + call _sgr_parse_
  impl + pop rbx + ret). Entry rsp%16==8; after push rsp%16==0; the
  nested CALL lands at callee entry rsp%16==8.
- r11 is NEVER held across a nested CALL (Wave 116 register-
  liveness lesson). Values that must survive a nested CALL live in
  rbx..r15 or on the stack.

## Acceptance (§7)

10-test corpus per combinator (3 x 10 = 30 cases), deferred to
R223.M7 fuzz-corpus milestone per the umbrella decomposition. The
corpus will cover:

### `sort` cases (10)

| # | Input                      | Expected                 |
| - | -------------------------- | ------------------------ |
| 1 | `sort by size`             | OK; kind=0; DESC=0; expr="size" |
| 2 | `sort by size asc`         | OK; kind=0; DESC=0; expr="size" |
| 3 | `sort by size desc`        | OK; kind=0; DESC=1; expr="size" |
| 4 | `sort by  f.size  desc  `  | OK; kind=0; DESC=1; expr="f.size" |
| 5 | `sort by name_desc`        | OK; kind=0; DESC=0; expr="name_desc" (not stripped) |
| 6 | `sort by`                  | SGR_ERR_EMPTY_BODY |
| 7 | `sortX by k`               | SGR_ERR_HEAD_MISMATCH |
| 8 | `sort k`                   | SGR_ERR_NO_BY (missing `by`) |
| 9 | `sort by   desc`           | SGR_ERR_EMPTY_BODY (expr is empty after `desc` strip) |
| 10 | `sort by k dEsC`          | OK; kind=0; DESC=0; expr="k dEsC" (case-sensitive; not stripped) |

### `group` cases (10)

| # | Input              | Expected                 |
| - | ------------------ | ------------------------ |
| 1 | `group by ext`     | OK; kind=1; expr="ext" |
| 2 | `group by f.ext`   | OK; kind=1; expr="f.ext" |
| 3 | `group by  k   `   | OK; kind=1; expr="k" (trimmed) |
| 4 | `group by\n ext`   | OK; kind=1; expr="ext" (LF-WS) |
| 5 | `group by`         | SGR_ERR_EMPTY_BODY |
| 6 | `groupX by k`      | SGR_ERR_HEAD_MISMATCH |
| 7 | `group k`          | SGR_ERR_NO_BY |
| 8 | `group by  `       | SGR_ERR_EMPTY_BODY |
| 9 | `group`            | SGR_ERR_HEAD_MISMATCH (len < 6) |
| 10 | `group  by k`     | OK; kind=1; expr="k" (two-space WS) |

### `reduce` cases (10)

| # | Input                              | Expected |
| - | ---------------------------------- | -------- |
| 1 | `reduce { \|a,r\| a + r.x } 0`       | OK; kind=2; HAS_SEED=1; expr="a + r.x "; seed="0" |
| 2 | `reduce {\|a,r\|a+r.x} 1`          | OK; kind=2; HAS_SEED=1 (no WS between `{` and `\|`) |
| 3 | `reduce { \|acc, rec\| f(acc,rec) } nil` | OK; two 3-letter + 3-letter idents |
| 4 | `reduce { \|a, r\| a + r.x }`      | SGR_ERR_NO_SEED (no seed after `}`) |
| 5 | `reduce { \|a, r\| }`              | SGR_ERR_EMPTY_BODY |
| 6 | `reduce { \|a\| a } 0`             | SGR_ERR_SYNTAX (one binder, expected two) |
| 7 | `reduce { \|a, r a + r.x } 0`      | SGR_ERR_NO_PIPE (missing closing `\|`) |
| 8 | `reduce \|a,r\| ... 0`             | SGR_ERR_NO_OPEN_BRACE |
| 9 | `reduce { \|a, verylongidentifier12345\| ... } 0` | SGR_ERR_NAME_TOO_LONG |
| 10 | `reduce { \|a, r\| a + r.x ` (no closing `}`) | SGR_ERR_NO_CLOSE_BRACE |

## Performance

Runtime throughput target `≥ 100 kg/s` (= 100 000 records/sec per
`design/terminal/semantic-shell.md` §14) is a THROUGHPUT target on
the downstream dispatch stage (R223.M4+ pipeline-stage dispatcher),
not on this parser-tier module. This module's cost is ONE 32-byte
record emit per stage parse (not per record flowing through the
pipeline); it runs at parse time, not at record-flow time.

The parse cost itself is dominated by three leaf-level cost
centers:

1. Head-keyword verification: 4..6 byte compares in a tight branch
   path; branch-predicted after the first few parses in a session.
2. `_sgr_skip_ws` calls: 2..6 per entry (sort: 2; group: 2; reduce:
   6). Each call is a tight 1..N byte-WS-class loop over the input.
3. Body / seed scan: linear byte walk to the terminator (`}` for
   reduce body; EOI for all three bodies and the reduce seed) plus
   a trailing-WS backward trim.

All three cost centers are O(N) in the input byte length with no
hidden multipliers. A typical pipeline-stage parse costs well under
10 µs on bare-metal AVX-512 host, consistent with the
`type-check of a typical 5-stage pipeline ≤ 10 ms` budget.

## References

- `design/terminal/semantic-shell-language-plan.md` §4 R223 row M4
- `design/terminal/semantic-shell.md` §14 (perf considerations)
- `tools/user/libpdx-pds-parser/src/sort_group_reduce.pdx`
- `tools/user/libpdx-pds-parser/src/filter_op.pdx` (R223.M3; shape
  precedent)
- `tools/user/libpdx-pds-parser/src/lambda_lit.pdx` (R224.M1;
  downstream parser for reduce bodies at HM time)
