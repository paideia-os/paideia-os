# `where` / `filter` / `by` combinator — R223.M3

Parent: paideia-os#2487. Milestone: paideia-os#2668.

## Scope

Filter combinator parser; the predicate is a lambda from R224 (or
a `by expr` shorthand that desugars to the lambda form).

## Grammar

```
Filter        ::= 'where'  '{' PipeBinder Body '}'
                | 'filter' '{' PipeBinder Body '}'
                | 'by'     Expr
PipeBinder    ::= '|' Ident '|'
Body          ::= <any bytes until matching '}'>
Expr          ::= <paideia expression; e.g. 'size > 1.MB'>
```

The `by expr` shorthand transforms to
`where { |it| expr }` at parser emit time.

## FilterOp record (32 B)

```
0x00 u32  magic              = 'FILT' (0x544C4946 LE)
0x04 u32  pad                = 0
0x08 u64  predicate_lambda_ref  = (body_start << 32) | body_len
                                  (byte span of the opaque predicate body;
                                  body_start is relative to the pointer
                                  AFTER the stripped head keyword, i.e.
                                  bytes + 5 / +6 / +2 for where / filter /
                                  by; NOT a LambdaLit pool index. The HM
                                  pass runs _ll_parse over this span.)
0x10 u8   mode               = { where=0, filter=1, by=2 }
0x11 u8   flags              (bit 0 = HAS_BY)
0x12 u8[14] reserved
```

## Public API

- `_fo_init()` — reset module state.
- `_fo_parse_where(bytes, len, out, out_cap) -> packed_u64`
- `_fo_parse_filter(bytes, len, out, out_cap) -> packed_u64`
- `_fo_parse_by(bytes, len, out, out_cap) -> packed_u64`
- `_fo_parse_body(bytes, len, mode, out, out_cap) -> packed_u64` —
  internal shared body-parse.

Status in low 32 bits; bytes-written in high 32 bits on OK.

## Error band

`0x4C00..0x4CFF`. Ten slots used at M3; see `caps.decl`.

## Acceptance

15-test filter corpus (deferred to R223.M7 fuzz-corpus milestone)
covering well-typed and ill-typed predicates, `by` shorthand
desugaring, nested filters, empty bodies, and the four grammar-fault
paths (missing `{`, missing `}`, missing `|binder|`, missing `by`).

## References

- `design/terminal/semantic-shell-language-plan.md` §4 R223 row M3
- `tools/user/libpdx-pds-parser/src/filter_op.pdx`
- `tools/user/libpdx-pds-parser/src/lambda_lit.pdx` (R224.M1)
