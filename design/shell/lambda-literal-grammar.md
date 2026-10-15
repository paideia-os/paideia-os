# Lambda literal grammar (R224.M1)

Status: landed 2026-10-14 at `tools/user/libpdx-pds-parser/src/lambda_lit.pdx`.
Upstream: paideia-os#2675 (R224.M1 of the lambda-lang umbrella,
paideia-os#2488). Substrate: R221.M1 UTF-8/NFC (paideia-os#2651),
R222.M1 SchemasSig (paideia-os#2658; shared type-code namespace).

## 1. Problem

The paideia-shell semantic-pipeline model treats lambdas as **first-
class literal values** that flow through pipes alongside records,
numbers, and strings (per `design/terminal/semantic-shell.md` §2.1
and the R224 wave table in
`design/terminal/semantic-shell-language-plan.md`). A user types:

    ls | filter \f:path -> file_size(f) > 1.MB
    reduce \(a:u64, b:u64) -> a + b
    find . | sort by \f:path -> f.mtime desc

The parser-tier primitive at R224.M1 is the one that turns the
backslash-prefixed byte sequence into a structured
`(LambdaHeader, Param[], body_bytes)` triple that later milestones
consume: R224.M2 walks the opaque body against the Expr grammar,
R224.M3 infers an effect row, R224.M4 attaches a capability row.

M1 is deliberately **just the header**: it recognises the
`\` + ParamList + `->` prefix and copies the trailing bytes
verbatim. Parsing the body expression is M2's job; this split keeps
the M1 landing small enough to land cleanly in one wave and lets M2
focus on the Expr tree without re-walking the parameter header.

## 2. Grammar

ABNF-style, with `WS = SP | TAB | LF | CR` as whitespace:

    Lambda      := WS* "\" WS* ParamList WS* "->" Expr
    ParamList   := SingleParam | "(" WS* MultiParam? WS* ")"
    SingleParam := Param
    MultiParam  := Param (WS* "," WS* Param)*
    Param       := identifier WS* ":" WS* type_name
    identifier  := [A-Za-z_] [A-Za-z0-9_]*          (len 1..13)
    type_name   := u64 | i64 | str | hex | hash32 | tsc | path | pid
    Expr        := <opaque bytes, parsed at R224.M2>

Three forms exist, all accepted at M1:

| Form | n_params | Example |
|---|---:|---|
| Single param, no parens | 1 | `\x:u64 -> x + 1` |
| Multi param, parens + commas | 1..8 | `\(x:u64, y:u64) -> x + y` |
| Empty params, parens only | 0 | `\() -> rand()` |

Grammar deliberately rejected at M1 (deferred to later milestones):

- **Record destructuring**: `\{name, size}:file -> ...` — the
  pattern-matcher ingress lands at R224.M5.
- **Multi-char operator type names**: `\x: Option<u64> -> ...` — the
  generic surface lands at R224.M3 effect polymorphism, which
  introduces the `<...>` type-param delimiter.
- **Type inference for params**: `\x -> x + 1` with the type elided —
  the HM pass at R225.M1 does the inference once the full lambda
  AST exists; M1 requires an explicit type annotation on every
  parameter.
- **Default values**: `\x:u64 = 0 -> ...` — the Param reserved slot
  carries 16 B of M2+ scratch (default-value pointer + closure-
  capture bit); the parser syntax arrives at R224.M2 alongside Expr.

## 3. Record layout

### 3.1 LambdaHeader (32 bytes)

| Off | Size | Field | Type | Meaning |
|---:|---:|---|---|---|
| 0 | 4 | `magic` | u32 | `LL_HEADER_MAGIC = 0x44424D4C` (`'LMBD'` little-endian: bytes `L M B D` at offsets 0..3). Validates the record on read-back. |
| 4 | 2 | `n_params` | u16 | 0..`LL_MAX_PARAMS` (= 8). |
| 6 | 2 | `flags` | u16 | Bit flags. Reserved; 0 at M1. M2+ bits: `HAS_CLOSURE_CAPTURE`, `IS_LET_REC`, `HAS_EFFECT_ROW`, `HAS_CAP_ROW`. |
| 8 | 4 | `body_offset` | u32 | Byte offset within the out buffer where the opaque body begins. Equals `32 + n_params * 32` on success. |
| 12 | 4 | `body_len` | u32 | Byte length of the opaque body (= `bytes_len - cursor-after-arrow`). |
| 16 | 16 | `reserved[16]` | u8[16] | Zeroed at M1. M2+: bytes `[16..24]` = effect-row id u64 (R224.M3); bytes `[24..32]` = capability-row id u64 (R224.M4). |

### 3.2 Param descriptor (32 bytes each)

| Off | Size | Field | Type | Meaning |
|---:|---:|---|---|---|
| 0 | 1 | `type_code` | u8 | `LL_TYPE_U64` (1), `LL_TYPE_I64` (2), `LL_TYPE_STR` (3), `LL_TYPE_HEX` (4), `LL_TYPE_HASH32` (5), `LL_TYPE_TSC` (6), `LL_TYPE_PATH` (8), or `LL_TYPE_PID` (9). Code 7 is reserved (mirrors R129.M4 `SF_TYPE_IMAGE`'s reserved slot). |
| 1 | 1 | `name_len` | u8 | 1..`LL_NAME_MAX` (= 13). |
| 2 | 14 | `name_inline[14]` | u8[14] | ASCII identifier, zero-padded past `name_len`. |
| 16 | 16 | `reserved[16]` | u8[16] | Zeroed at M1. M2+: bytes `[16..24]` = default-value pointer / destructure-pattern id u64; byte `[24]` = closure-capture flag u8; bytes `[25..26]` = pattern-descriptor index u16; bytes `[26..32]` reserved. |

### 3.3 Layout rationale

**Stride 32 everywhere.** The LambdaHeader and the Param descriptor
are both 32 bytes, so the Param array uses `shl rN, 5` for
`n_params * 32` address computation — never `imul r, imm` (per
`feedback_pdx_encoder_pitfalls`). The 32-byte Param stride is bigger
than SchemasSig's 16-byte field descriptor because a lambda param
needs more M2+ scratch than a cmd-functor record field (closure
capture, default value, destructuring, effect-row seed).

**14 B inline name.** Mirrors R222.M1 SchemasSig's descriptor and is
sufficient for every lambda-param name observed in the semantic-
shell language-plan examples (`f`, `x`, `y`, `path`, `name`, `size`,
`inode`, `mtime`, `tag`, `hash`). Avoids the pointer+len
indirection that would otherwise require a sibling buffer and a
dereference walk during name lookup.

**Magic in the header.** Lets R224.M2 and downstream code validate
the header on read-back (a corrupted or truncated out buffer fails
the `cmp [ptr+0], 0x44424D4C` check). SchemasSig and Pipeline do
not carry magic bytes — their consumer always holds the matching
module-id already — but the lambda surface is passed through pipes
and across process boundaries at R224.M6, so a defensive magic is
cheap insurance.

**body_offset in OUT buffer, not input.** The out buffer is
**self-contained** — a caller can hand the written image onwards
without also handing the original input bytes. The body-copy pass
at the end of `_ll_parse` does a byte-for-byte copy from the input
to the out buffer; `body_offset = 32 + n_params * 32` so a reader
walks straight through header → params → body with no indirection.

## 4. State machine

```
                                 skip_ws
                                     │
                     ┌───────────────┼───────────────┐
                     │                               │
                   '\' ?                      everything else
                     │                               │
                   consume                        LL_ERR_SYNTAX
                     │
                 skip_ws
                     │
         ┌───────────┴───────────┐
         │                       │
       '(' ?                 ident char ?
         │                       │
       consume              SingleParam
       skip_ws                   │
         │                       │
       ')' ?                parse_param
         │                       │
      consume          ┌─────────┴─────────┐
       (empty)         │                   │
         ↓          OK                   SYNTAX / UNKNOWN
      after_params      │                   │
                        └───────────────────┤
                            after_params    │
                                            ↓
                                       error path
                           ─────────────────
                       (multi-param non-empty branch)
                   parse_param → ','? → parse_param
                             ↘    ↙
                              ')' consume
                                 │
                               after_params
                                 │
                             skip_ws
                                 │
                              '-' then '>' ?
                                 │
                               consume
                                 │
                           body = rest of input
                                 │
                       capacity + body-copy
                                 │
                            write_header
                                 │
                              epilogue
                      (bytes_written << 32) | LL_OK
```

Error flow: every parse-time failure jumps to a shared epilogue that
unwinds the 24-byte scratch frame and six callee-save pops; `rax`
carries the `LL_ERR_*` code packed as `(0 << 32) | status`.

## 5. Public API

The register plan and ABI are frozen at this landing so M2+ can
replace the body without an ABI break.

```
_ll_parse(rdi, rsi, rdx, rcx) -> rax
    rdi = bytes_ptr
    rsi = bytes_len
    rdx = out_ptr
    rcx = out_cap
    rax = (bytes_written << 32) | status

_ll_parse_param(rdi, rsi, rdx, rcx) -> rax
    rdi = bytes_ptr
    rsi = bytes_len
    rdx = cursor_in
    rcx = param_write_ptr
    rax = (new_cursor << 32) | status

_ll_skip_ws(rdi, rsi, rdx) -> rax
    rdi = bytes_ptr
    rsi = bytes_len
    rdx = cursor_in
    rax = new_cursor

_ll_classify_type(rdi, rsi) -> rax
    rdi = ident_ptr
    rsi = ident_len
    rax = LL_TYPE_* (1..9, 7 reserved) or LL_UNKNOWN_TYPE (0xFF)
```

Status codes (`LL_ERR_*`, 0x2C00..0x2C04):

| Code | Value | Meaning |
|---|---|---|
| `LL_OK` | `0` | Parse succeeded; `bytes_written = 32 + n_params*32 + body_len`. |
| `LL_ERR_SYNTAX` | `0x2C00` | Grammar mismatch at ident, `:`, `(`, `)`, or `,`. |
| `LL_ERR_TOO_MANY_PARAMS` | `0x2C01` | `> LL_MAX_PARAMS` (8). |
| `LL_ERR_UNKNOWN_TYPE` | `0x2C02` | `type_name` not in the M1 set. |
| `LL_ERR_OUT_TOO_SMALL` | `0x2C03` | `out_cap < 32 + n_params*32 + body_len`. |
| `LL_ERR_NO_ARROW` | `0x2C04` | ParamList terminator was not `->`. |

`LL_ERR_NO_ARROW` is a dedicated code (not folded into `SYNTAX`) so
the shell's error reporter can point the diagnostic directly at the
missing-arrow site rather than at a generic "something went wrong".

## 6. Capacity + bound-check matrix

Every write to the out buffer is guarded. The main parse's capacity
check is layered:

| Guard point | Expression | Fails with |
|---|---|---|
| Prologue | `out_cap < 32` | `LL_ERR_OUT_TOO_SMALL` |
| Before each Param | `(param_write_ptr + 32 - out_ptr) > out_cap` | `LL_ERR_OUT_TOO_SMALL` |
| Before each Param | `n_params >= 8` | `LL_ERR_TOO_MANY_PARAMS` |
| After arrow | `(32 + n_params*32 + body_len) > out_cap` | `LL_ERR_OUT_TOO_SMALL` |

Every per-param guard runs **before** the sub-walk writes anything,
so a failure leaves the out buffer at the last committed param
descriptor plus zeros for the uncommitted ones (the caller may
ignore the top 32 bits of `rax` on error, but partial writes are
not catastrophic — the descriptor layout is a self-describing
sequence).

## 7. Interactions

### 7.1 R221.M1 (UTF-8/NFC)

Callers run the input bytes through `_u8n_decode_and_normalize` so
this module may assume (a) valid UTF-8, (b) NFC-form. Because the
grammar accepts only ASCII identifiers and ASCII punctuation
(`\`, `(`, `)`, `,`, `:`, `->`, WS), the parser only ever inspects
the ASCII subset of its input. Non-ASCII bytes inside an identifier
fall through to `LL_ERR_SYNTAX` via the ident byte-class check (none
of 0x80..0xFF is in `[A-Za-z0-9_]`). Non-ASCII bytes in the body
are copied VERBATIM at M1 (opaque bytes); R224.M2 will walk them
through the Expr grammar.

### 7.2 R222.M1 (SchemasSig, shared type codes)

Byte-for-byte identical type-code numbering:

| Name | Value | SchemasSig | LambdaLit |
|---|---|---|---|
| u64 | 1 | SS_TYPE_U64 | LL_TYPE_U64 |
| i64 | 2 | SS_TYPE_I64 | LL_TYPE_I64 |
| str | 3 | SS_TYPE_STR | LL_TYPE_STR |
| hex | 4 | SS_TYPE_HEX | LL_TYPE_HEX |
| hash32 | 5 | SS_TYPE_HASH32 | LL_TYPE_HASH32 |
| tsc | 6 | SS_TYPE_TSC | LL_TYPE_TSC |
| path | 8 | SS_TYPE_PATH | LL_TYPE_PATH |
| pid | 9 | SS_TYPE_PID | LL_TYPE_PID |

Code 7 is reserved in both modules to keep alignment with R129.M4
`SF_TYPE_IMAGE`. A later pass that compares a lambda parameter's
declared type against a cmd-functor record field's type reads the
two bytes directly and `cmp`s them — no translation layer.

The two modules do **not** share code: SchemasSig carries its own
`_sch_sig_classify_type` leaf; this module carries `_ll_classify_type`.
Duplication is intentional at M1 so neither module becomes a
build-order dependency of the other.

### 7.3 R223.M1 (Pipeline)

A lambda literal that appears as a pipeline-stage argv word is
parsed FIRST by Pipeline at the lexer tier (which emits one span
per `|`-delimited stage) and then handed, span-by-span, to this
module at the lambda-token tier. The two parsers never share a
cursor; they operate on the same NFC-normalised input buffer but
at different depth plies.

A quoted lambda inside a pipeline stage (`\x:u64 -> x + "a | b"`)
is bareword-split by Pipeline on the unescaped `|` character — the
caller must either escape the `|` (`\|`) or wrap the lambda in a
pipeline-level quote context. R224.M6 (first-class pipeline value)
revisits this: the pipeline tokeniser gains a "lambda-recognising"
mode that balances backslashes against the next `->` tail,
sidestepping the quoting ritual.

### 7.4 R224.M2 (Expression parse)

Consumes the `(body_offset, body_len)` slot on the LambdaHeader.
Walks the opaque bytes against the Expr grammar and emits an
expression AST into a sibling buffer. Does NOT re-walk the Param
descriptors — those are consumed intact by both M2 (name-lookup
table) and M3 (effect-row inference seed).

### 7.5 R224.M3 / M4 (effect, capability rows)

The LambdaHeader's `reserved[16]` tail is partitioned at M3/M4:

- Bytes `[16..24]`: effect-row id u64 (R224.M3). Zero at M1 means
  "no row inferred yet".
- Bytes `[24..32]`: capability-row id u64 (R224.M4). Zero at M1
  means "no row inferred yet".

The reservation is wide enough to hold the id directly rather than
a pointer, so a reader need not dereference a sibling table.

### 7.6 R224.M5 (nested lambda, let-rec)

Scoping is a POST-parse concern — the parser does not maintain a
symbol table. R224.M5 walks the nested-lambda AST emitted by M2
and computes scope boundaries + shadowing rules; the `IS_LET_REC`
flag bit lives in the LambdaHeader `flags` u16 for recursion
tagging.

### 7.7 R224.M6 (lambda as first-class pipeline value)

A lambda flows through `|` as a pointer into its backing out
buffer. The pipeline-stage ABI materialiser (R223.M2) at that
point learns to recognise the `LMBD` magic and reserve a slot for
the full image rather than treating it as a bareword. Shell
sessions that want to serialise a lambda across a process boundary
rely on the self-contained out buffer (header + params + body),
which travels as a flat byte blob.

### 7.8 R224.M7 (linear/affine substructural propagation)

A lambda closing over a linear value is itself linear per Walker
2005. The propagation runs over the elaborated AST (not the parse-
tier image), so this module's output shape is unchanged; only the
R224.M4 cap-row id slot will reflect the propagated row.

## 8. Encoder discipline

Standard paideia-as pitfalls (`feedback_pdx_encoder_pitfalls`):

- No `test rN, rN`. Zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64`. All masks fit in imm32 (0xFF, 0xFFFF).
- No 2-op `imul r, imm`. The `n_params * 32` multiply is
  `shl rN, 5`; the `len * 1` is implicit (no multiply at all).
- No multiline `pub let = "..."`. Every justification is a single
  logical line.
- Module basename `LambdaLit` matches `lambda_lit.pdx`.
- All `cmp reg, imm32` immediates fit in imm32 with bit 31 clear
  (ASCII literals ≤ 0x7F, type codes ≤ 9, status codes ≤ 0x2C04,
  constants ≤ 32). No MOVABS staging.
- Byte loads via `xor rax, rax; mov_b rax, [base + idx]` (zero-
  extends into the full qword). Byte stores via `mov_b [dst + disp],
  rax` with the source always `rax` (precedent: SchemasSig
  `_ss_parse_body` line 954, Pipeline `_pl_emit_word` line 408).
- u16 stores via two `mov_b` byte writes (low byte, high byte);
  `mov_w` short-form is not used in this repo.
- u32 stores via `mov_d [dst + disp], rax` (precedent: Pipeline
  `_pl_emit_word`, libpdx-argv `emit_parse_error`).

**Labels** are prefixed `ll_` for `_ll_parse`, `ll_sw_` for
`_ll_skip_ws`, `ll_ct_` for `_ll_classify_type`, `ll_pp_` for
`_ll_parse_param`. The `ll_` prefix is grep-confirmed disjoint from
every existing paideia-os label namespace — the kernel's `lam.pdx`
Linear Address Masking primitives use the three-letter `lam_` prefix,
not `ll_`.

**Stack frame alignment** at every nested CALL site:

| Function | Pushes | Scratch | Total offset | `rsp % 16` at CALL |
|---|---:|---:|---:|---:|
| `_ll_skip_ws` | 0 | 0 | 0 | 8 (pure leaf, no CALL) |
| `_ll_classify_type` | 0 | 0 | 0 | 8 (pure leaf, no CALL) |
| `_ll_parse_param` | 5 | 16 | 56 | 0 |
| `_ll_parse` | 6 | 24 | 72 | 0 |

Entry `rsp % 16 == 8` (post-CALL convention). After the push/scratch
sequence, `rsp % 16 == 0`, matching the SysV ABI requirement for a
nested CALL instruction (`rsp % 16 == 0` **at** the CALL, meaning
the called function sees `rsp % 16 == 8` after its own return address
pushes).

## 9. Return-code namespace

The `LL_*` codes live in 0x2C00..0x2CFF, carved out of the former
"R225.M* reserved" 0x2C00..0x2EFF slice (as documented in
`pipeline.pdx`'s namespace map at the R223.M1 landing time). The
split:

| Range | Owner | Status |
|---|---|---|
| `0x2C00..0x2C04` | R224.M1 LambdaLit | landed |
| `0x2C05..0x2CFF` | R224.M2+ | reserved |
| `0x2D00..0x2D03` | R225.M1 HM core | landed (parallel wave) |
| `0x2D04..0x2DFF` | R225.M2+ | reserved |
| `0x2E00..0x2E04` | R226.M1 Datalog | landed (parallel wave) |
| `0x2E05..0x2EFF` | R226.M2+ | reserved |

Disjoint from:

- `0x1900..0x19FF` (R129.M4 schema_fmt)
- `0x1C00..0x1CFF` (R135.M5 wit_bridge)
- `0x2700..0x27FF` (R221.M1 utf8_nfc)
- `0x2A00..0x2AFF` (R222.M1 SchemasSig)
- `0x2B00..0x2BFF` (R223.M1 Pipeline)
- `0xFFFFECD?..EDF` (shell codes)
- `0xFFFFEC40..42` (kernel-side Pipeline module)

Grep confirmation at landing time:

```
grep -rE '0x2C0[0-4]' paideia-os/{src,tools,design,tests}
  -> hits only in
       tools/user/libpdx-pds-parser/src/lambda_lit.pdx
       tools/user/libpdx-pds-parser/caps.decl
       design/shell/lambda-literal-grammar.md    (this file)
```

The xHCI driver's `0x2C00` constant (`XHCI_ADDRESS_DEVICE_CTRL_NC_BASE`,
in `src/kernel/core/drivers/xhci/slot.pdx`) is a hardware register
encoding, not a packed-status code — it lives in a disjoint
namespace (device-register, not user-space packed return).

## 10. Caller flow

```
input: byte buffer `src` (NFC-normalised)
output: byte buffer `dst` (caller-allocated; see sizing below)

1. Choose `dst_cap`.
     Minimum:   32  bytes      (header only, impossible to be valid)
     Realistic: 32 + 8*32 + <body_len>  = 288 + body_len
                  (header + 8 param slots + body)
     Shell default sizing: 1024 B works for every lambda observed
                           in the semantic-shell language-plan
                           examples; larger budgets support the
                           R224.M5 nested-lambda case.

2. Call:
     rax = _ll_parse(src_ptr, src_len, dst_ptr, dst_cap)

3. Dispatch:
     status  = rax & 0xFFFFFFFF
     written = rax >> 32

     if status == LL_OK:
         // Walk the output: header at dst_ptr[0..32];
         // params at dst_ptr[32..32+n_params*32];
         // body at dst_ptr[body_offset..body_offset+body_len].
     elif status in (LL_ERR_SYNTAX, LL_ERR_UNKNOWN_TYPE,
                     LL_ERR_NO_ARROW):
         // Point the diagnostic at the current cursor site.
     elif status == LL_ERR_TOO_MANY_PARAMS:
         // User exceeded 8-param surface.
     elif status == LL_ERR_OUT_TOO_SMALL:
         // Caller must grow the dst buffer.
```

## 11. Representative test corpus

Deferred to R224.M7 (per the umbrella decomposition), but the
representative OK/error cases that corpus will cover:

| # | Input | Expected status | n_params | Notes |
|--:|---|---|---:|---|
| 1 | `\x:u64 -> x + 1` | `LL_OK` | 1 | Single param, no parens |
| 2 | `\(a:u64, b:u64) -> a + b` | `LL_OK` | 2 | Multi param, two |
| 3 | `\() -> rand()` | `LL_OK` | 0 | Empty multi-param |
| 4 | `\(a:u64, b:i64, c:str, d:hex, e:hash32, f:tsc, g:path, h:pid) -> ...` | `LL_OK` | 8 | Full param surface |
| 5 | `\f:path -> f.size` | `LL_OK` | 1 | 1-char ident, type_name = `path` |
| 6 | `\x:u64->x` | `LL_OK` | 1 | No whitespace |
| 7 | `  \  x : u64  ->  x` | `LL_OK` | 1 | WS tolerance everywhere |
| 8 | `\x:u64\n->\nx` | `LL_OK` | 1 | LF treated as WS |
| 9 | `\(a:u64,b:u64,c:u64,d:u64,e:u64,f:u64,g:u64,h:u64,i:u64) -> ...` | `LL_ERR_TOO_MANY_PARAMS` | | 9 params exceeds 8 |
| 10 | `\x:complex128 -> x` | `LL_ERR_UNKNOWN_TYPE` | | type_name not in M1 set |
| 11 | `x:u64 -> x` | `LL_ERR_SYNTAX` | | Missing leading `\` |
| 12 | `\x u64 -> x` | `LL_ERR_SYNTAX` | | Missing `:` |
| 13 | `\x:u64 x` | `LL_ERR_NO_ARROW` | | Missing `->` |
| 14 | `\x:u64 -` | `LL_ERR_NO_ARROW` | | Partial arrow at EOI |
| 15 | `\(x:u64 -> x` | `LL_ERR_SYNTAX` | | Missing `)` |
| 16 | `\(x:u64, -> x` | `LL_ERR_SYNTAX` | | Trailing `,` before `)` |
| 17 | `\x012345678901234:u64 -> x` | `LL_ERR_SYNTAX` | | ident_len > 13 |
| 18 | `\:u64 -> x` | `LL_ERR_SYNTAX` | | Empty ident |
| 19 | `\x: -> x` | `LL_ERR_SYNTAX` | | Empty type_name |
| 20 | `\x:u64 -> x`, `dst_cap=16` | `LL_ERR_OUT_TOO_SMALL` | | Below header size |

The corpus must also verify, for every OK case:

- The 32-byte LambdaHeader has `magic == 0x44424D4C` at offset 0.
- `n_params` at offset 4 matches the declared count.
- `body_offset == 32 + n_params * 32`.
- `body_offset + body_len == bytes_written`.
- Each 32-byte Param descriptor has `type_code` in the valid set,
  `name_len` in `1..13`, `name_inline` zero-padded past `name_len`,
  and `reserved[16]` all-zero.
- The body bytes match the input bytes after the arrow verbatim.

## 12. Forward path

- **R224.M2** — Expression parser consumes the `(body_offset,
  body_len)` slot; emits an Expr AST into a sibling buffer.
- **R224.M3** — Effect-row inference seats the inferred row id into
  LambdaHeader bytes `[16..24]`.
- **R224.M4** — Capability-row typing seats the inferred row id into
  LambdaHeader bytes `[24..32]`.
- **R224.M5** — Nested lambda + let-rec scoping walks the AST emitted
  by M2 + the Param descriptors emitted here.
- **R224.M6** — First-class pipeline value integrates with R223
  stage ABI; pipeline recognises the `LMBD` magic and reserves a
  slot for the full image.
- **R224.M7** — Linear/affine propagation and 20-test parser corpus
  gate close.

## 13. References

- `tools/user/libpdx-pds-parser/src/lambda_lit.pdx` — the module.
- `tools/user/libpdx-pds-parser/src/schemas_sig.pdx` — R222.M1
  SchemasSig, shared type-code namespace.
- `tools/user/libpdx-pds-parser/src/pipeline.pdx` — R223.M1 Pipeline,
  precedent for the packed-status return shape and the pipeline-tier
  caller flow.
- `tools/user/libpdx-pds-parser/caps.decl` — error-band taxonomy
  and disjointness proof.
- `design/terminal/semantic-shell-language-plan.md` §R224 — lambda
  surface milestone table.
- `design/terminal/semantic-shell.md` §2.1 — lambda-literal syntax
  specification (both `\args -> body` and `{ |args| body }` forms;
  R224.M1 implements the former, with the latter deferred to a
  later milestone that unifies the two forms into a single AST).
- Walker 2005, "Substructural Type Systems" — the linear/affine
  propagation rule used at R224.M7.
