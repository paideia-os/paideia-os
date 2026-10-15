# Pipeline record projection (R223.M2)

**Status:** v0.1 (R223.M2 — paideia-os#2667)
**Date:** 2026-10-14
**Author:** softarch (Wave UMB-W29)
**Scope:** The user-space parser-tier module that reads the ARGV
bytes of a pipeline stage whose head word is `select` or `project`
and emits a flat array of 16-byte `FieldSelector` records — one per
named field — which downstream passes consume to filter the typed-
record stream by field name. Lands in `libpdx-pds-parser` at
`tools/user/libpdx-pds-parser/src/record_projection.pdx`.

---

## 1. Position in the pipeline-lang substrate

```
                 raw user input bytes
                           |
                           v
       +------------------------------------------+
       | R221.M1  Utf8Nfc::_u8n_decode_and_       |
       |          normalize   (UTF-8 + NFC)       |
       +---------------------+--------------------+
                             |
                             v  NFC-form bytes
       +------------------------------------------+
       | R223.M1  Pipeline::_pl_parse             |
       |          (cmd1 arg | cmd2 arg | ...)     |
       +---------------------+--------------------+
                             |
                             v  PipelineStage[0..n]
                 +-----------+-----------+
                 |                       |
                 v                       v
       +---------------+       +--------------------+
       | cmd_name =    |       | other stages flow  |
       | "select" or   |       | through unchanged  |
       | "project" ?   |       | to R222 functor    |
       +------+--------+       | dispatcher         |
              | yes            +--------------------+
              v
       +------------------------------------------+
       | R223.M2  RecordProjection::              |
       |            _rp_parse_select / _project   |
       |          (THIS)                          |
       +---------------------+--------------------+
                             |
                             v  FieldSelector[0..k]
       +------------------------------------------+
       | R223.M2+ projection pass:                |
       |   walks the typed-record stream, emits   |
       |   only the (name, bytes) pairs whose     |
       |   names match the FieldSelector array    |
       +---------------------+--------------------+
                             |
                             v  reduced typed-record stream
       +------------------------------------------+
       | R129.M4  schema_fmt renderer             |
       +------------------------------------------+
```

R223.M1 lands the lexer-tier pipeline parser that turns a shell
input line into `PipelineStage` records. R223.M2 (THIS) is a
POST-pass on stages whose head word is `select` or `project`: the
caller inspects each stage's `cmd_name_offset`/`cmd_name_len` span,
matches it against the two reserved operator names, and hands the
stage's argv bytes to this module. The parser treats the whole
argv span as one flat byte stream and reads a comma-separated field
name list.

The projection PASS itself — the stage dispatcher that walks each
incoming record and emits only the selected fields — is a separate
R223.M2+ landing (not covered here). This module is the PARSER
only. The pass's input is this module's `FieldSelector` array; its
output is the reduced record stream that reaches the formatter.

## 2. Grammar

```
argv_body := WS* field_name ( WS* ',' WS* field_name )* WS*
field_name := [A-Za-z_] [A-Za-z0-9_]*       (byte length 1..RP_NAME_MAX)
WS         := 0x20 | 0x09 | 0x0A | 0x0D
```

Where `RP_NAME_MAX = 14`. The grammar accepts both uniform
`select name1, name2, name3` (one argv token with the whole list
inside) and segmented `select name1 , name2 , name3` (five argv
tokens separated by the pipeline tokeniser) — the module reads the
whole span as one flat stream and the comma-separated grammar is
uniform regardless of how the outer tokeniser split the bytes.

### 2.1 Minimal examples

| Input (argv bytes)              | n_fields | Fields emitted            |
|---------------------------------|---------:|---------------------------|
| `name`                          | 1        | `name`                    |
| `name1, name2`                  | 2        | `name1`, `name2`          |
| `  name1 ,  name2 ,  name3 `    | 3        | `name1`, `name2`, `name3` |
| `_underscore_start, mixedCase`  | 2        | `_underscore_start`, `mixedCase` |

### 2.2 Rejected cases

| Input                      | Status                              |
|----------------------------|-------------------------------------|
| `` (empty)                 | `RP_ERR_SYNTAX`                     |
| `   ` (whitespace only)    | `RP_ERR_SYNTAX`                     |
| `,name`                    | `RP_ERR_SYNTAX` (leading comma)     |
| `name,`                    | `RP_ERR_SYNTAX` (trailing comma)    |
| `name1,,name2`             | `RP_ERR_SYNTAX` (consecutive)       |
| `name1 name2`              | `RP_ERR_SYNTAX` (missing comma)     |
| `9bad_name`                | `RP_ERR_SYNTAX` (digit-first)       |
| `name_longer_than_14bytes` | `RP_ERR_SYNTAX` (over-long name)    |
| 33 valid names             | `RP_ERR_TOO_MANY_FIELDS`            |
| `out_cap < 16`             | `RP_ERR_OUT_TOO_SMALL`              |

## 3. FieldSelector record (16 bytes)

```
  offset  size  field
  ------  ----  -----------------------------------------------------
    0      1   name_len     u8    1 .. RP_NAME_MAX (= 14)
    1      1   flags        u8    bit 0 = RP_FLAG_PROJECT (project op),
                                  bits 1..7 reserved; 0 for `select`.
    2     14   name_inline  [u8; 14]  ASCII identifier, zero-padded.

  total: 16 B (RP_FIELD_SELECTOR_BYTES)
```

### 3.1 Design rationale

**Stride is a power of two.** 16 B is `shl rN, 4` for field-index
arithmetic; no 2-op `imul r, imm` (per `feedback_pdx_encoder_pitfalls`).
Max 32 fields (`RP_MAX_FIELDS`) fits in `32 * 16 = 512` bytes;
shells seat the output buffer on stack or in the elaborator's
per-session arena. The projection PASS pays no further allocation
cost.

**Name is inline, not pointer+len.** The selector array is byte-
identical when hashed into a projection fingerprint, and the
downstream projection pass does not need to dereference back into
the pipeline source bytes to compare. This mirrors SchemasSig's
inline-name shape.

**Name max is 14, not SchemasSig's 13.** SchemasSig (R222.M1)
chose `SS_NAME_MAX = 13` because it stores the name in a 14-byte
slot AFTER a 1-byte `name_len` and a 1-byte `type_code` — i.e. the
first two bytes carry the length + type and bytes 2..15 carry the
name. RecordProjection has NO type_code (every selector is "just
a name" — the field types are already pinned by the input record's
schema), so the second byte goes to `flags` and the full 14 bytes
starting at offset 2 are usable for the name. The two modules
produce different descriptor shapes and are deliberately NOT
interchangeable.

**Flags byte is per-field, not per-call.** All fields in one call
carry the SAME flag byte (the parser writes it), but the per-field
granularity means a future consumer that wants to UNION a `select`
and a `project` output could do so without a separate per-record
tag. At R223.M2, the only valid flag value is 0 (`select`) or 1
(`project` = `RP_FLAG_PROJECT`); bits 1..7 are reserved.

### 3.2 Comparison with SchemasSig's descriptor

```
SchemasSig FieldDesc (R222.M1):          RecordProjection FieldSelector (R223.M2):
  [+0]  field_type   u8   (1..9)           [+0]  name_len     u8   (1..14)
  [+1]  name_len     u8   (0..13)          [+1]  flags        u8   (bit 0)
  [+2]  name_inline  [u8; 14]              [+2]  name_inline  [u8; 14]
   16 B total                               16 B total
```

Both are 16 B. Both use byte 0 for a tag + byte 1 for a length +
bytes 2..15 for a 14-byte inline name. The ONLY differences:

- SchemasSig puts type at byte 0 and length at byte 1;
  RecordProjection puts length at byte 0 and flags at byte 1.
  (The byte-0 "primary tag" differs because SchemasSig's primary
  question is "what TYPE is this field?" whereas RecordProjection's
  primary question is "what IS this field name?" — the length comes
  first because scanning the name_inline buffer needs the length
  before the type/flags.)
- SchemasSig uses an END-sentinel terminator; RecordProjection does
  NOT — the array length is the packed-u64 return `n_fields`. (The
  projection pass takes `(fields_ptr, n_fields)` as an explicit
  pair.)

## 4. State machine

```
     +-------------+
     |  parse_field|<--- entry: n_fields=0
     +------+------+<--- comma-reentry: after ','
            |
            v
      +----------+
      | skip_ws  |
      +----+-----+
           |
           v
      cursor == EOI? ----yes---> RP_ERR_SYNTAX
           |
           no
           v
      first byte in [A-Za-z_]? ---no---> RP_ERR_SYNTAX
           |
           yes
           v
      scan ident while [A-Za-z0-9_]
           |
           v
      len == 0?     ----yes---> RP_ERR_SYNTAX
      len > 14?     ----yes---> RP_ERR_SYNTAX
           |
           no
           v
      field_count >= 32? ---yes---> RP_ERR_TOO_MANY_FIELDS
      cap_remaining < 16?---yes---> RP_ERR_OUT_TOO_SMALL
           |
           no
           v
      write FieldSelector
      n_fields++; out += 16; cap -= 16
           |
           v
      +----------+
      | skip_ws  |
      +----+-----+
           |
           v
      cursor == EOI? ----yes---> RP_OK, (n_fields << 32) | 0
           |
           no
           v
      peek == ',' ? ----no----> RP_ERR_SYNTAX
           |
           yes
           v
      advance past ','; jump to parse_field
```

The state machine is a tight hand-coded loop that calls
`_rp_skip_ws` at every word boundary. The ident scan uses
hand-coded byte-class ranges to avoid a bitmap lookup (which would
require a `and reg, imm64` that `feedback_pdx_encoder_pitfalls`
forbids). The field-count and capacity guards sit at the top of
every parse_field iteration so an over-full output is caught before
the write.

## 5. Capacity and bound-check matrix

| Guard                           | Site                           | Code                        |
|---------------------------------|--------------------------------|-----------------------------|
| `out_cap >= 16`                 | prologue                       | `cmp r14, 16; jb rp_err_oos`|
| `out_cap >= 16`                 | top of each parse_field        | `cmp r14, 16; jb rp_err_oos`|
| `n_fields < 32`                 | top of each parse_field        | `cmp r15, 32; jae rp_err_too_many` |
| `cursor < bytes_len`            | after first skip_ws            | `cmp r12, rbp; jae rp_err_syntax` |
| first byte in [A-Za-z_]         | ident start                    | 5 cmp-imm32 branches        |
| continuation byte in id set     | ident loop                     | 7 cmp-imm32 branches        |
| `name_len > 0`                  | ident_done                     | `cmp r11, 0; je rp_err_syntax` |
| `name_len <= 14`                | ident_done                     | `cmp r11, 14; ja rp_err_syntax` |
| peek == `,` after field         | post-field skip_ws             | `cmp rax, 0x2C; jne rp_err_syntax` |

All `cmp reg, imm` immediates (ASCII literals 0x20..0x7F, numeric
constants 14, 16, 32) fit in `imm32` with bit 31 clear, so direct
`cmp reg, imm32` is sign-extension-safe. No `test`, no `and imm64`,
no 2-op `imul r, imm`, no `mov_w` short-form, no multiline let.

## 6. Register plan and stack frame

### 6.1 `_rp_skip_ws` (pure leaf)

Zero pushes, no stack frame, no nested CALL. Register plan: `rax`
walks the cursor; `rcx` holds each peeked byte.

### 6.2 `_rp_parse_impl` (core; 1 nested call site)

```
  rbx = bytes_ptr
  rbp = bytes_len
  r12 = cursor
  r13 = current_out_ptr (walks by 16 after each field)
  r14 = cap_remaining
  r15 = n_fields written so far

  [rsp +  0] = flags_byte  (spilled from r8 across nested calls)
  [rsp +  8] = alignment pad (unused)
  [rsp + 16] = alignment pad (unused)
```

Prologue: 6 callee-save pushes + `sub rsp, 24` scratch.

Alignment: entry rsp%16==8; after 6 × 8 = 48 B pushes, rsp%16==8;
after `sub rsp, 24`, rsp%16==0. Nested CALLs into `_rp_skip_ws`
land aligned.

### 6.3 `_rp_parse_select` and `_rp_parse_project` (1-nested-call wrappers)

```
  sub rsp, 8;        // align: entry %16==8 -> %16==0
  mov r8, <flag>;    // 0 for select, 1 for project
  call _rp_parse_impl;
  add rsp, 8;
  ret;
```

No callee-save pushes needed because the wrappers do not use any
callee-save registers themselves and the implementation does its
own prologue/epilogue.

## 7. Interactions

### 7.1 R129.M4 schema_fmt (formatter)

The formatter consumes a typed-record stream plus a schema
descriptor and renders each record. R223.M2's RecordProjection
output is a **PREFILTER**: the fields that pass projection are the
fields the formatter sees. The formatter is projection-unaware —
the projection PASS walks each incoming record, emits only the
selected `(name, bytes)` pairs, and hands the reduced record on
to the formatter.

This means the schema the formatter uses must either (a) match the
POST-projection record (a reduced schema with only the selected
fields), or (b) be the full input schema with the formatter
skipping unselected fields. (b) is simpler and is the R223.M2+
projection pass's intended shape; (a) requires a `schema_fmt`
reduction pass that R129.M4 does not currently provide.

### 7.2 R222.M1 SchemasSig (functor signatures)

SchemasSig parses `name: type` **DECLARATIONS**, not bare `name`
**SELECTORS**. The two modules are deliberately separate: SchemasSig
emits 16-byte descriptors with a `type_code` byte, whereas
RecordProjection emits 16-byte descriptors with a `flags` byte and
NO type (the field types are already pinned by the input record's
schema). Downstream consumers that need both — e.g. a projection
pass that wants type information to render — carry a
`(FieldSelector, type_code)` pair in their own per-field view model
rather than conflating the two record shapes.

### 7.3 R223.M1 Pipeline (upstream)

This module is a POST-pass on the `PipelineStage` records that
R223.M1 emits. The caller identifies a stage whose cmd_name
matches `select` or `project` (a byte-exact comparison against the
two reserved operator names), concatenates its
`argv_offsets[]`/`argv_lens[]` spans into a flat byte buffer (or
passes a single argv span directly when the whole list is one
quoted token), and calls the matching entry point.

A pipeline like `ls | select name, size | wc` yields three stages:

1. `ls` — ordinary functor dispatch (R222.M*).
2. `select name, size` — DETECTED as projection stage; argv bytes
   `name, size` handed to `_rp_parse_select`; result is a 2-element
   FieldSelector array `[{name_len=4, flags=0, "name"},
   {name_len=4, flags=0, "size"}]`; stage replaced in the plan by a
   projection pass carrying that array.
3. `wc` — ordinary functor dispatch.

### 7.4 R223.M3 (future differentiation of select vs project)

At R223.M2 the two operators are semantically equivalent: both
mean "pick these fields from the input stream". R223.M3 will
differentiate:

- `project FIELDS` — DROP every input field whose name is NOT in
  the FieldSelector array; preserve the input ORDER of the kept
  fields; preserve input types verbatim.
- `select FIELDS` — PICK the fields in the FieldSelector array's
  ORDER (possibly reordering vs the input); may also layer
  select-as-rename or select-as-cast in future M4+ waves.

The current M2 flag byte is the only wire-level change needed; the
downstream dispatcher reads bit 0 of each FieldSelector's flags
byte and routes to either the reordering (select) or the
drop-unselected (project) path at that time. Nothing in THIS
module changes at M3 — the parser's output ABI is frozen now.

## 8. Status-code namespace

RP_* codes live in `0x3400..0x34FF`, disjoint from every other
user-space packed-status range in the paideia-os tree. The band
sits ABOVE the contiguous R221..R226 block (which stops at
`0x2EFF`) rather than reusing the adjacent `0x2B05..0x2BFF` slice
of R223.M1's pipeline band — the two R223 submodules remain
error-disjoint so a downstream dispatcher's compound error path
can distinguish outer-pipeline faults from inner-projection
faults.

The gap `0x2F00..0x33FF` is reserved for R227+ parser-tier
primitives (pds container header parse, pipeline-record row types,
Datalog predicate-type bridge, etc.) that will land before
R223.M3's semantic split. Slots `0x3403..0x34FF` are reserved for
R223.M3+ (differentiation; wildcards; name aliases; etc.).

Grep confirmation at R223.M2 landing time:

```
grep -rE '0x340[0-2]' paideia-os/{src,tools,design,tests}
  -> no packed-status hits outside src/record_projection.pdx,
     this file, and caps.decl. 0x3400 as a Unicode code point in
     libpdx-unicode-tables/src/width.pdx, as a boot-witness stage
     marker in tests/kernel/drivers/hda/bdl_synth.pdx and
     tests/kernel/cap/owner_sweep_synth.pdx, and 0x34000 as a cap
     manifest flag in src/kernel/boot/witness/r29_registry.pdx are
     NOT packed-status codes and sit in disjoint semantic
     namespaces.
```

## 9. Representative test corpus (deferred to R223.M7)

The 20-test parser corpus deferred to R223.M7 will cover:

| # | Input                              | Expected                        |
|---|------------------------------------|---------------------------------|
| 1 | `name` (select)                    | 1 field, flags=0                |
| 2 | `name` (project)                   | 1 field, flags=1                |
| 3 | `a, b, c, d, e`                    | 5 fields                        |
| 4 | `  a  ,  b  `                      | 2 fields                        |
| 5 | `a,b,c`                            | 3 fields, no interior ws        |
| 6 | `_underscore`                      | 1 field, `_underscore`          |
| 7 | `mixedCase123`                     | 1 field                         |
| 8 | 32 valid names                     | 32 fields, RP_OK                |
| 9 | 33 valid names                     | RP_ERR_TOO_MANY_FIELDS          |
|10 | `` (empty)                         | RP_ERR_SYNTAX                   |
|11 | `   ` (whitespace only)            | RP_ERR_SYNTAX                   |
|12 | `,name`                            | RP_ERR_SYNTAX                   |
|13 | `name,`                            | RP_ERR_SYNTAX                   |
|14 | `name1,,name2`                     | RP_ERR_SYNTAX                   |
|15 | `name1 name2`                      | RP_ERR_SYNTAX                   |
|16 | `9bad`                             | RP_ERR_SYNTAX                   |
|17 | 15-byte name                       | RP_ERR_SYNTAX (over NAME_MAX)   |
|18 | 14-byte name                       | 1 field, OK                     |
|19 | out_cap = 15                       | RP_ERR_OUT_TOO_SMALL            |
|20 | `name1, name2` with out_cap = 32   | 2 fields, OK                    |

## 10. Caller flow

```
// Pseudocode: the stage dispatcher's projection branch.
if (stage.cmd_name == "select" || stage.cmd_name == "project") {
    // Concatenate argv spans into a flat buffer (or pass single span).
    bytes = concat(stage.argv_offsets[], stage.argv_lens[]);

    FieldSelector fields[32];
    u64 result;

    if (stage.cmd_name == "select") {
        result = _rp_parse_select(bytes.ptr, bytes.len,
                                  &fields[0], sizeof(fields));
    } else {
        result = _rp_parse_project(bytes.ptr, bytes.len,
                                   &fields[0], sizeof(fields));
    }

    status = result & 0xFFFFFFFF;
    n_fields = result >> 32;

    if (status != RP_OK) {
        // Report the parse error at the stage's source span.
        return error(status, stage.source_span);
    }

    // Replace the stage in the plan with a projection pass that
    // carries (fields, n_fields).
    plan.replace(stage, projection_pass(fields, n_fields));
}
```

## 11. Forward path

- **R223.M3** — select-vs-project semantic differentiation
  (reorder vs drop-unselected). This module's output ABI is frozen
  now; M3 lands the DISPATCHER, not a new parser.
- **R223.M4** — select-as-rename (`select name as alias, ...`) and
  select-as-cast (`select name:i64, ...`). The grammar extends to
  allow an optional `as <alias>` or `:<type>` tail per field; the
  FieldSelector grows two reserved slots (currently in bits 1..7
  of flags) to carry the alias/type hints.
- **R223.M5** — wildcards (`select *`, `project *_count`). The
  FieldSelector grows a `kind` byte (bit 1 of flags) distinguishing
  LITERAL from WILDCARD; the name_inline carries the pattern.
- **R223.M6** — composite operators (`select FIELDS by GROUP`) via
  nested RecordProjection calls. No parser-tier change needed;
  this is a dispatcher-tier composition.
- **R223.M7** — 20-test parser corpus + fuzz run.

## 12. paideia-as encoder discipline

Full list in the module docstring. In brief:

- No `test rN, rN` — every zero-check is `cmp reg, 0`.
- No `and rN, imm64` — every mask is `imm8` or `imm32`.
- No 2-op `imul r, imm` — the 16-byte stride uses `add r13, 16`
  after each field, not an indexed multiply.
- No multiline `pub let = "..."` — single-line justifications.
- Module basename `RecordProjection` matches `record_projection.pdx`.
- Labels prefixed `rp_`, `rp_sw_`, `rp_sel_`, `rp_proj_` —
  disjoint from paideia-as reserved keywords and from every other
  label prefix in libpdx-pds-parser.
- All `cmp reg, imm` immediates fit in `imm32` with bit 31 clear.
- Byte loads via `xor rax, rax; mov_b rax, [base + idx * 1]`.
- Byte stores via `mov_b [dst + disp], reg`.
- `_rp_skip_ws` is a pure leaf.
- `_rp_parse_select` / `_rp_parse_project` are 1-nested-call
  wrappers with `sub rsp, 8` alignment.
- `_rp_parse_impl` has a 6-push + 24 B scratch frame.

---

Upstream: paideia-os#2487 (R223 umbrella), paideia-os#2667 (THIS
ticket, R223.M2). Substrate: paideia-os#2666 (R223.M1 pipeline
stage parser). Companion: `tools/user/libpdx-pds-parser/
src/record_projection.pdx` (the implementation).
