# Lambda closure-capture list (R224.M2)

Status: landed 2026-10-14 at `tools/user/libpdx-pds-parser/src/closure_capture.pdx`.
Upstream: paideia-os#2676 (R224.M2 of the lambda-lang umbrella,
paideia-os#2488). Substrate: paideia-os#2675 (R224.M1 LambdaLit),
paideia-os#2651 (R221.M1 UTF-8/NFC), paideia-os#2658 (R222.M1
SchemasSig; shared type-code namespace).

## 1. Problem

The paideia-shell treats lambdas as first-class pipeline values
(per `design/terminal/semantic-shell.md` §2.1 and the R224 wave of
`design/terminal/semantic-shell-language-plan.md`). A lambda written
on the command line may stay in-process for its entire lifetime, OR
it may be shipped across a process boundary — either because the
pipeline runs an `@hostname` stage (R223.M6, cross-host), or because
the receiving stage is a jailed worker (R229 session jail), or
because the user explicitly `send`s the lambda to a sibling session.

The two cases require **different capture semantics**:

- **In-process** — the lambda runs in the same address space as the
  pipeline scope that produced it. Free variables resolve by
  reference: the HM pass (R225.M1+) walks the lambda body, identifies
  free variables, and threads them through the enclosing environment
  as ordinary variable bindings. No serialization is involved; the
  closure arena (R220.M7) holds pointers into the pipeline scope.
  **This is the default**, no syntax required.

- **Cross-process** — the lambda crosses a trust boundary. Pointers
  into the sender's address space are meaningless on the receiver;
  the capture must be **serialized** onto the wire. The user has to
  tell the parser WHICH bindings to serialize AND how — because
  "walk the body and serialize every free variable" would be unsafe
  (unbounded transitive closure, undefined type for complex values,
  silent send of secrets).

Q13 in `design/01-foundational-decisions.md` chose **hybrid pipeline
serialization**: shared schema, in-process by-reference, serialized
at host/trust boundaries. The explicit capture list makes the
serialization decision visible and auditable at the syntax layer.

R224.M2 (this milestone) is the **parser tier** of that decision: it
turns the `[binding, binding, ...]` syntax into a flat descriptor
array that downstream milestones (R224.M3 effect-row inference,
R224.M4 capability-row typing, R224.M6 first-class pipeline value,
R225.M5 cross-context type flow) consume.

## 2. Grammar

ABNF-style, with `WS = SP | TAB | LF | CR` as whitespace:

    CaptureList := WS* "[" WS* BindingList? WS* "]"
    BindingList := Binding (WS* "," WS* Binding)*
    Binding     := identifier (WS* ":" WS* type_name)?
    identifier  := [A-Za-z_] [A-Za-z0-9_]*          (len 1..14)
    type_name   := u64 | i64 | str | hex | hash32 | tsc | path | pid

Three cases of a binding:

| Form | Mode | Meaning |
|---|---|---|
| `name` | `BY_REF` | Sender ships only the name on the wire. Receiver resolves `name` against ITS own session-local scope. Only sound when the type checker (R225.M5) verifies the receiver holds a binding under that name. |
| `name:type` | `BY_VALUE` | Sender serializes the current value of `name` using `type`. Receiver deserializes into a fresh session-local binding of the same name. Values cross the trust boundary; the sender's cap-row must hold `serialize-of-type-X` for each listed type (R224.M4). |

An empty list `[]` is legal and sets the `IS_EMPTY` flag; a lambda
with `[]` has no captures but IS marked as cross-process (useful for
pure functions sent to remote workers).

Grammar deliberately rejected at M2 (deferred to later milestones):

- **Nested capture** — `[outer_name=[inner_name]]` — the recursive
  per-level dispatch arrives at R224.M5 (nested-lambda scoping).
- **Mode-explicit syntax** — `[ref name, val name:type]` — the
  implicit mode (bare = ref, typed = value) is the M2 surface; an
  explicit `ref`/`val` keyword is a possible M3+ ergonomic.
- **Default values for by-value captures** — `[name:u64 = 0]` — the
  descriptor's reserved tail carries 15 B of M3+ scratch for a
  future default-pointer slot.
- **Linear/affine capture classification** — `[uniq name:path]` — the
  Walker 2005 propagation rule lands at R224.M7, which widens the
  mode byte to a 3-value {ref, value, linear-value} set.

## 3. Record layout

### 3.1 ClosureCaptureHeader (32 bytes)

| Off | Size | Field | Type | Meaning |
|---:|---:|---|---|---|
| 0 | 4 | `magic` | u32 | `CC_HEADER_MAGIC = 0x50414343` (`'CCAP'` little-endian). Validates the record on read-back. |
| 4 | 2 | `n_bindings` | u16 | 0..`CC_MAX_BINDINGS` (= 16). |
| 6 | 2 | `flags` | u16 | Bit 0 = `HAS_BY_VALUE` (set iff at least one Binding has `mode = BY_VALUE`); bit 1 = `IS_EMPTY` (set iff `n_bindings == 0`); bits 2..15 reserved. |
| 8 | 4 | `bindings_offset` | u32 | Byte offset within the out buffer where the Binding array begins. Equals 32 on success. |
| 12 | 4 | `bindings_len` | u32 | Byte length of the Binding array (= `n_bindings * 32`). |
| 16 | 16 | `reserved[16]` | u8[16] | Zeroed at M2. M3+: bytes `[16..24]` = effect-row seed id u64 (R224.M3); bytes `[24..32]` = capability-row seed id u64 (R224.M4). |

### 3.2 Binding descriptor (32 bytes each)

| Off | Size | Field | Type | Meaning |
|---:|---:|---|---|---|
| 0 | 1 | `type_code` | u8 | 0 (`CC_TYPE_UNTYPED`, mode=BY_REF) OR 1..9 (`CC_TYPE_*`, mode=BY_VALUE). Code 7 reserved (mirrors R129.M4 `SF_TYPE_IMAGE` reservation). |
| 1 | 1 | `name_len` | u8 | 1..`CC_NAME_MAX` (= 14). |
| 2 | 14 | `name_inline[14]` | u8[14] | ASCII identifier, zero-padded past `name_len`. |
| 16 | 1 | `mode` | u8 | `CC_MODE_BY_REF` (0) or `CC_MODE_BY_VALUE` (1). Derived from the presence (or absence) of the `: type_name` suffix. |
| 17 | 15 | `reserved[15]` | u8[15] | Zeroed at M2. M3+: byte `[17]` = per-binding effect-flag; byte `[18]` = linear/affine marker (R224.M7); bytes `[19..32]` = source span + future scratch. |

### 3.3 Layout rationale

**Stride 32 everywhere.** Both ClosureCaptureHeader and Binding are
32 bytes, so the Binding array uses `shl rN, 5` for `n_bindings * 32`
address computation — never `imul r, imm` (per
`feedback_pdx_encoder_pitfalls`).

**14 B inline name.** Matches R224.M1 LambdaLit's Param name_inline
byte-for-byte so a downstream `name_eq(param, capture)` compare reads
the two spans directly without a widen. Also 1 byte wider than R222.M1
SchemasSig's 13 B slot (which packs a reserved tail byte) because
captures are observed to use longer, more descriptive names than
cmd-functor fields do (`accum`, `history_entry`, `shared_ctx` versus
`size`, `inode`).

**Magic in the header.** Lets R224.M3+ validate the CC image on
read-back (a corrupted or truncated out buffer fails the
`cmp [ptr+0], 0x50414343` check). The lambda header carries its own
magic too; both get validated when R224.M2.5 integrates the two
images into one lambda-literal byte image.

**Mode byte at `+16`, not packed into `type_code`.** Keeping mode a
distinct byte at a stable offset lets a downstream pass read it with
one `mov_b` without masking; packing it into bit 7 of `type_code`
would save 1 B per descriptor but would require every reader to
`and rax, 0x7F` to recover the type and `shr rax, 7` to recover the
mode, which is extra encoder discipline (feedback_pdx_encoder_pitfalls
forbids `and r, imm64` and prefers imm8/imm32 masks only), and the
`+16` slot already lives in the 16-byte scratch tail that was
reserved anyway.

## 4. State machine

```
                             skip_ws
                                │
                              '[' ?
                                │
                            consume
                                │
                             skip_ws
                                │
                 ┌──────────────┼──────────────┐
                 │                             │
               ']' ?                      ident char ?
                 │                             │
             consume                     parse_binding
                 │                             │
            empty list                   OK → skip_ws
                 ↓                             │
            header_write           ┌───────────┴───────────┐
                                   │                       │
                                 ',' ?                   ']' ?
                                   │                       │
                                consume                 consume
                                   │                       │
                              skip_ws + loop         header_write
```

Each parsed Binding appends 32 B to the out buffer at
`out_ptr + 32 + n_bindings * 32`. After `]` is consumed, the header
goes down at `out_ptr + 0..32` and the total `bytes_written =
32 + n_bindings * 32`.

Error flow: every parse-time failure jumps to a shared epilogue that
unwinds the 24-byte scratch frame and six callee-save pops; `rax`
carries the `CC_ERR_*` code packed as `(0 << 32) | status`.

## 5. Public API

```
_cc_parse(rdi, rsi, rdx, rcx) -> rax
    rdi = bytes_ptr
    rsi = bytes_len
    rdx = out_ptr
    rcx = out_cap
    rax = (bytes_written << 32) | status

_cc_parse_binding(rdi, rsi, rdx, rcx) -> rax
    rdi = bytes_ptr
    rsi = bytes_len
    rdx = cursor_in
    rcx = write_ptr
    rax = (new_cursor << 32) | status

_cc_skip_ws(rdi, rsi, rdx) -> rax
    rdi = bytes_ptr
    rsi = bytes_len
    rdx = cursor_in
    rax = new_cursor

_cc_classify_type(rdi, rsi) -> rax
    rdi = ident_ptr
    rsi = ident_len
    rax = CC_TYPE_* (1..9, 7 reserved) or CC_UNKNOWN_TYPE (0xFF)
```

Status codes (`CC_ERR_*`, 0x3500..0x3505):

| Code | Value | Meaning |
|---|---|---|
| `CC_OK` | `0` | Parse succeeded; `bytes_written = 32 + n_bindings * 32`. |
| `CC_ERR_SYNTAX` | `0x3500` | Grammar mismatch at ident, `:`, `,`, or peek after ident. |
| `CC_ERR_TOO_MANY_BINDINGS` | `0x3501` | `> CC_MAX_BINDINGS` (16). |
| `CC_ERR_UNKNOWN_TYPE` | `0x3502` | `type_name` not in the M2 set. |
| `CC_ERR_OUT_TOO_SMALL` | `0x3503` | `out_cap < 32 + n_bindings * 32`. |
| `CC_ERR_NO_OPEN` | `0x3504` | First non-whitespace byte was not `[`. |
| `CC_ERR_NO_CLOSE` | `0x3505` | EOI before matching `]`. |

`CC_ERR_NO_OPEN` and `CC_ERR_NO_CLOSE` are dedicated codes (not folded
into `SYNTAX`) so the shell's error reporter can point the diagnostic
directly at the missing-bracket site rather than at a generic
"something went wrong" (parallel to R224.M1's `LL_ERR_NO_ARROW`).

## 6. Capacity + bound-check matrix

| Check | Point in flow | Error |
|---|---|---|
| `out_cap >= 32` | Prologue, before any write | `CC_ERR_OUT_TOO_SMALL` |
| `write_ptr + 32 - out_ptr <= out_cap` | Before each parse_binding call | `CC_ERR_OUT_TOO_SMALL` |
| `n_bindings < 16` | Before each parse_binding call | `CC_ERR_TOO_MANY_BINDINGS` |
| `ident_len >= 1` | After ident scan | `CC_ERR_SYNTAX` |
| `ident_len <= 14` | After ident scan | `CC_ERR_SYNTAX` |
| `type_len >= 1` | After type_name scan (typed branch) | `CC_ERR_SYNTAX` |
| `classify_type != UNKNOWN` | After classify | `CC_ERR_UNKNOWN_TYPE` |
| `cursor < bytes_len` at each peek | Loop body | `CC_ERR_NO_CLOSE` or `CC_ERR_SYNTAX` |

Order matters: the capacity + max-bindings checks happen BEFORE
`parse_binding` runs so a cap-exceeded or over-wide case fails
without a partial write (the descriptor zero-fill, if it had already
run inside parse_binding, is a semantic no-op on an uncommitted
slot).

## 7. Interaction with other modules

### 7.1 R221.M1 (UTF-8/NFC)

Caller is expected to have run the input bytes through
`_u8n_decode_and_normalize`. The grammar accepts only ASCII
identifiers and ASCII punctuation (`[`, `]`, `,`, `:`, WS), so
non-ASCII bytes inside an identifier fall through to
`CC_ERR_SYNTAX` via the ident byte-class check (none of 0x80..0xFF
is in `[A-Za-z0-9_]`).

### 7.2 R222.M1 (SchemasSig)

Type codes `CC_TYPE_*` mirror `SS_TYPE_*` byte-for-byte. The two
modules do NOT share code (SchemasSig carries its own
`_sch_sig_classify_type`; this module carries `_cc_classify_type`);
the duplication is intentional so neither module becomes a build-
order dependency of the other.

### 7.3 R224.M1 (LambdaLit)

Shares the type-code dispatch byte with LambdaLit (both mirror
SchemasSig). The two modules operate at **adjacent plies** of the
same lambda surface:

- R224.M1 recognises `\params -> body` (the HEADER + param array).
- R224.M2 recognises `[binding, binding, ...]` (the CAPTURE list).

At the full combined grammar level the two combine as:

    Lambda := WS* "\" WS* CaptureList? WS* ParamList WS* "->" Expr

The integration pass that stitches the two parsers together is
**R224.M2.5** (filed as an umbrella follow-up, not landed at this
M2). Until R224.M2.5 lands, a caller invokes `_cc_parse` and
`_ll_parse` independently against the appropriate byte spans.

### 7.4 R223.M5 (wire-format sink)

The `BY_VALUE` partition of the Binding array drives the serializer
at the host/trust boundary. For each `BY_VALUE` binding, R223.M5's
wire sink reads `type_code` + `name_inline` + the current binding
value from the sender's session scope, picks a type-specific marshal
routine, and emits a `(name, type, value)` triple onto the wire.

The `BY_REF` partition is emitted as `(name)` only — the receiver's
R223.M5 wire-format source performs a session-scope lookup to bind
the name on reception.

### 7.5 R224.M3 (effect-row inference)

Reads `n_bindings` + the per-binding `mode` byte to seed an effect
row for the lambda. A `BY_VALUE` binding adds a `serialize-type-X`
effect; a `BY_REF` binding adds an `env-lookup` effect. The HM pass
at R225.M4 unifies these seeds against the lambda body's inferred
effect row.

### 7.6 R224.M4 (capability-row typing)

Reads the `BY_VALUE` partition to require the sender's cap-row
holds the `serialize-of-type-X` capability for each listed type;
reads the `BY_REF` partition to require the receiver's cap-row
holds `resolve-by-name`. Diagnostic class `E0820` references the
Binding offset within the CC image.

### 7.7 R225.M5 (cross-context type flow)

The `BY_REF` partition induces a lookup against the receiver's
session-scope type environment; a missing binding emits an
`E0710`-family diagnostic. The `BY_VALUE` partition induces fresh
type environment entries at the receiver side using the declared
`type_name`.

## 8. Representative 15-test corpus

Deferred to the R224.M2.5 landing per the umbrella decomposition.
The corpus will cover (acceptance from paideia-os#2676):

### Intra-process closures (BY_REF-only; 7 cases)

1. Empty list `[]` — n_bindings=0, HAS_BY_VALUE=0, IS_EMPTY=1.
2. Single bare `[acc]` — n_bindings=1, mode=BY_REF, type_code=0.
3. Three bare `[acc, sum, count]` — n_bindings=3, all BY_REF.
4. Padded whitespace `[  acc  ,  sum  ]` — same shape, cursor
   consumption follows the ws skipper.
5. Mixed newlines `[\n  acc,\n  sum\n]` — grammar tolerates all WS.
6. Max 16 `[a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p]` — accepted at capacity.
7. Over 16 `[a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q]` — rejected with
   `CC_ERR_TOO_MANY_BINDINGS`.

### Cross-process closures (BY_VALUE present; 8 cases)

8. Single typed `[n:u64]` — n_bindings=1, mode=BY_VALUE,
   type_code=1, HAS_BY_VALUE=1.
9. Multi typed `[n:u64, p:path, h:hash32]` — n_bindings=3, all
   BY_VALUE, type_codes {1,8,5}.
10. Mixed modes `[acc, n:u64, p:path]` — n_bindings=3, modes
    {REF, VAL, VAL}, HAS_BY_VALUE=1.
11. All eight types in order `[a:u64, b:i64, c:str, d:hex, e:hash32,
    f:tsc, g:path, h:pid]` — n_bindings=8, type_codes {1,2,3,4,5,6,
    8,9}.
12. Over-long name `[verylongidentifier:u64]` (18 chars) — rejected
    with `CC_ERR_SYNTAX` (name_len > 14).
13. Unknown type `[n:complex]` — rejected with
    `CC_ERR_UNKNOWN_TYPE`.
14. Missing close `[n:u64` — rejected with `CC_ERR_NO_CLOSE`.
15. Missing open `n:u64]` — rejected with `CC_ERR_NO_OPEN`.

Each test's acceptance pattern is:
- OK cases: `status == CC_OK`, `bytes_written == 32 + n_bindings*32`,
  magic bytes at `[+0..+4] == 0x50414343`, `n_bindings` field matches
  expected, every Binding descriptor's name_inline matches expected
  bytes.
- Error cases: `status == expected`, `bytes_written` is unexamined.

## 9. Namespace reservation

Error band `0x3500..0x35FF` is reserved for R224.M2 ClosureCapture
across all its M-landings. R224.M1 (LambdaLit) owns a disjoint
`0x2C00..0x2CFF` band — the two R224 submodules do not share status
codes because a downstream dispatcher's compound error path must
distinguish "the lambda header faulted" from "the explicit capture
list faulted".

Future carve-outs within `0x3506..0x35FF`:

- R224.M3: per-binding effect-row inference failures
  (`CC_ERR_EFFECT_MISMATCH`, `CC_ERR_EFFECT_ROW_SATURATED`).
- R224.M4: per-binding capability-row typing failures
  (`CC_ERR_CAP_MISSING`, `CC_ERR_CAP_INSUFFICIENT_RIGHTS`).
- R224.M5: let-rec recursive capture (`CC_ERR_LET_REC_CYCLE`).
- R224.M7: linear/affine propagation violation
  (`CC_ERR_LINEAR_DUPLICATE`, `CC_ERR_AFFINE_DISCARDED`).

## 10. Forward path

- **R224.M2.5** — integrate `_cc_parse` into `_ll_parse` so a lambda
  with an explicit capture list parses in one call. The merged
  shape produces a combined output image (CC header + Bindings +
  LambdaHeader + Params + body bytes) with cross-pointers in the
  LambdaHeader reserved tail.
- **R224.M3** — effect-row inference reads the per-binding mode
  byte to stamp effect-row seeds.
- **R224.M4** — capability-row typing reads the BY_VALUE partition
  to require serialize-of-type-X capabilities.
- **R224.M5** — nested lambda + let-rec unification with capture.
- **R224.M6** — first-class pipeline value runtime consumes the
  BY_VALUE partition via R223.M5 wire-format sink.
- **R224.M7** — Walker 2005 linear/affine propagation across capture.
- **R225.M5** — cross-context type flow uses the BY_REF partition
  to drive session-scope lookup.
