# Command-functor `SchemasSig` Body Parser (R222.M1)

**Status:** v0.1 (R222.M1 — paideia-os#2658)
**Date:** 2026-10-14
**Author:** softarch (Wave UMB-W26)
**Scope:** The parser-tier primitive that turns a `schemas_sig { ... -> ... }` body (the first functor parameter of every semantic-shell command module, per SH-D5) into two separate field-descriptor arrays — one for the command's input record shape, one for its output record shape. Interacts with `libpdx-pds-parser` R221.M1 (UTF-8/NFC parser-tier wrapper) upstream and `src/kernel/core/term/schema_fmt.pdx` R129.M4 (schema-driven formatter type codes) laterally.

---

## 1. Why this exists

`design/terminal/semantic-shell-language-plan.md` section "R222 — Command-module functor surface + registry client (SH-D5)" tasks R222.M1 with:

> **`SchemasSig` signature body** — ML signature naming the schemas a command may consume and produce; typed by `schema-registry.md` fingerprints.

The grammar is a tiny subset of paideia-as functor-signature syntax:

```
module Find(Schemas : SchemasSig)(...) : CommandSig = struct ... end

signature SchemasSig = schemas_sig { path: path -> name: str, size: u64 }
```

Where the body of `schemas_sig { ... }` names the fields the command consumes (left of `->`) and produces (right of `->`), each annotated with a type from a small M1 subset. Later R222 milestones feed the resulting field-descriptor arrays into:

- the elaborator's per-command record (R222.M3 REPL dispatch),
- the schema-registry fingerprint pipeline (R222.M8 serialization for `describe <cmd>`),
- the runtime record match (R222.M3 `_ss_match_record` wiring).

R222.M1 (this landing) delivers:

1. the parser-tier primitive `_ss_parse_body` that consumes the body between `{` and `}` and emits two field-descriptor arrays, and
2. the frozen-signature stub `_ss_match_record` so M3 can replace the body without an ABI break.

**Why a satellite library, not kernel-side.** The shell runs in user space and the field-descriptor arrays are produced once at functor-elaboration time; the kernel-side schema registry consumes them via a flat byte-blob syscall at M2+. There is no reason to spend kernel-side state budget on a per-functor parser. The same pattern R221.M1 (`utf8_nfc.pdx`) uses, as a sibling module of `libpdx-pds-parser`.

---

## 2. Grammar

```
SchemasSigBody := WS* FieldList? WS* "->" WS* FieldList WS*
               | WS* "->" WS* FieldList WS*            (empty input)
FieldList      := Field (WS* "," WS* Field)*
Field          := identifier WS* ":" WS* type_name
identifier     := [A-Za-z_] [A-Za-z0-9_]*              (length 1..13)
type_name      := one of
                       u64 | i64 | str | hex
                     | hash32 | tsc
                     | path | pid
WS             := 0x20 | 0x09 | 0x0A | 0x0D
```

### 2.1 Three legal forms

1. **Both lists non-empty** (the typical command):

   ```
   path: path, flags: u64 -> name: str, size: u64, mtime: tsc
   ```

2. **Empty input** (producer-only commands like `pwd`, `env`):

   ```
   -> dir: path
   ```

3. **Rich input, scalar output** (predicate-shaped commands):

   ```
   file: path, pattern: str -> hits: u64
   ```

### 2.2 Explicit non-grammar at M1

- The leading `schemas_sig` keyword and the surrounding `{` / `}` are **not** part of the input. The caller (a later R222 milestone's lexer / AST pass) locates the braces and hands only the inner bytes to `_ss_parse_body`.
- The output list MUST be non-empty: a command that produces no record output declares `-> status: u64` or similar. R222.M2 may relax this when `CommandSig`'s `output_schema = None` is wired through, at which point the grammar becomes `FieldList? WS* "->" WS* FieldList?` and the parser emits a zero-field output schema with just an END terminator.
- No nested type expressions, option types, list types, or default values. Those are M2+ when `CommandSig` is parsed.
- No comments inside the body. The pds-lang lexer upstream of this parser strips comments before the brace-matched body is extracted.
- No trailing comma. The ambient paideia-as style is comma-separated with no trailing comma, and the field-list grammar enforces that.

---

## 3. Public API

### 3.1 `_ss_parse_body`

```
_ss_parse_body(bytes_ptr, bytes_len,
               out_in_schema_ptr,  out_in_cap,
               out_out_schema_ptr, out_out_cap)   -> errno
```

- `rdi` = `bytes_ptr`             — pointer to the first body byte.
- `rsi` = `bytes_len`              — body length in bytes, NOT including the braces.
- `rdx` = `out_in_schema_ptr`      — pointer to the input-schema output buffer.
- `rcx` = `out_in_cap`             — input-schema buffer capacity in bytes.
- `r8`  = `out_out_schema_ptr`     — pointer to the output-schema output buffer.
- `r9`  = `out_out_cap`            — output-schema buffer capacity in bytes.
- `rax` = `errno` ∈ { `SS_OK`, `SS_ERR_SYNTAX`, `SS_ERR_UNKNOWN_TYPE`, `SS_ERR_TOO_MANY_FIELDS` }

Each output buffer receives a packed array of 16-byte field descriptors terminated by an `SS_TYPE_END` sentinel. See §4 for the descriptor layout.

**Capacity requirement.** Each side must be at least `SS_SCHEMA_SIDE_MIN = 528` bytes (`(SS_MAX_FIELDS + 1) * 16`) if the caller wants to support the maximum field count. A caller with a smaller budget gets `SS_ERR_TOO_MANY_FIELDS` the moment the schema exceeds its budget; no partial-write guarantee is given at that boundary.

### 3.2 `_ss_match_record`

```
_ss_match_record(sig_schema_ptr, sig_schema_len, record_ptr) -> errno
```

- `rdi` = `sig_schema_ptr`
- `rsi` = `sig_schema_len`
- `rdx` = `record_ptr`
- `rax` = `SS_UNIMPLEMENTED` (= 0x2A03) at R222.M1

The signature is frozen now so R222.M3 can swap in the full field-by-field type-code compare without an ABI break. **Any M1 caller MUST treat `SS_UNIMPLEMENTED` as "not yet reachable, do not depend on"** — the dispatch path at M1 should never invoke this stub.

### 3.3 Status-code taxonomy

| Code                       | Value   | Meaning |
|----------------------------|---------|---------|
| `SS_OK`                    | `0`     | parse succeeded; both schemas fully written |
| `SS_ERR_SYNTAX`            | `0x2A00`| bad grammar at the current cursor |
| `SS_ERR_UNKNOWN_TYPE`      | `0x2A01`| `type_name` not in the M1 set |
| `SS_ERR_TOO_MANY_FIELDS`   | `0x2A02`| per-side field count exceeds `SS_MAX_FIELDS` (32), or a caller-provided cap is too small to hold the schema + its END terminator |
| `SS_UNIMPLEMENTED`         | `0x2A03`| `_ss_match_record` M1 stub return |

The band `0x2A00..0x2AFF` is reserved for R222 cmd-functor parser codes. It is disjoint from every other packed-status band in the paideia-os tree:

- R221 parser-tier wrapper (`0x2700..0x27FF`),
- R129.M4 schema_fmt (`0x1900..0x19FF`),
- R135.M5 wit_bridge (`0x1C00..0x1CFF`),
- user-space 0xFFFFExxx error-band slices.

A grep at landing confirms disjointness:

```sh
grep -rE '0x2A0[0-9A-F]' paideia-os/{src,tools,design,tests}
```

returns hits only inside this module and this design doc.

---

## 4. Field descriptor layout

Each field is 16 bytes:

```
offset  size  field                 notes
------  ----  --------------------  --------------------------------------
   0     1    field_type (u8)       SS_TYPE_END (0) or SS_TYPE_* (1..9)
   1     1    name_len   (u8)       0 .. SS_NAME_MAX (= 13)
   2    14    name_inline           ASCII identifier, zero-padded to 14 B
                                    (SS_TYPE_END entries carry zeros here)
```

### 4.1 Stride-16 justification

Stride 16 is a power of two so descriptor addressing uses `shl rN, 4` — no 2-op `imul r, imm` (per the paideia-as encoder-pitfall log). Width-16 is tight enough that a 32-field schema plus END terminator fits in `SS_SCHEMA_SIDE_MIN = 528` bytes; shells seat one scratch buffer per side (either on stack or in the elaborator's per-session arena).

The 14-byte inline name is deliberate: no pointer dereference during fingerprinting, no name-arena management, and 14 bytes covers every cmd-functor field name observed in the semantic-shell plan examples (`name`, `size`, `path`, `inode`, `mtime`, `tag`, `hash`, `status`, `ticks`, …). The hard cap of 13 characters (`SS_NAME_MAX`) leaves one byte for a trailing NUL that fingerprinters may prepend for cheap C-string handling.

### 4.2 Type code numbering

| Name     | Code  | Shared with                  | Record-side in-slot size |
|----------|------:|------------------------------|-------------------------:|
| `u64`    | `1`   | `SF_TYPE_U64` (R129.M4)      | 8 B                      |
| `i64`    | `2`   | `SF_TYPE_I64`                | 8 B                      |
| `str`    | `3`   | `SF_TYPE_STR`                | 8 B (ptr48 \| len16)     |
| `hex`    | `4`   | `SF_TYPE_HEX`                | 8 B                      |
| `hash32` | `5`   | `SF_TYPE_HASH32`             | 32 B                     |
| `tsc`    | `6`   | `SF_TYPE_TSC`                | 8 B                      |
| `path`   | `8`   | *new at R222.M1*             | 8 B (ptr48 \| len16)     |
| `pid`    | `9`   | *new at R222.M1*             | 8 B                      |

Code 7 is deliberately **skipped** to stay aligned with R129.M4's reserved `SF_TYPE_IMAGE` slot. A later R222 landing that adds `SS_TYPE_IMAGE` will reuse code 7 and the two type systems stay byte-interchangeable at the dispatch byte.

### 4.3 Why `path` and `pid` are new

- **`path`** is distinct from `str` because the elaborator wants to apply path-shaped capability derivations (R133 cap-flow) at argument binding. A `str` argument carries no path-ness guarantee; a `path` argument elaborates to a path-rooted capability derivation at functor instantiation time.
- **`pid`** is distinct from `u64` so the typed-record ring (R135.M4) can emit a `pid` field with a `pid.ns` namespace tag at serialization time (R222.M8), and so a later remote-shell wire landing can rewrite pids across session boundaries without inspecting field names.

Both are 8-byte-wide values on the wire so a sibling `_sf_fmt_cell` dispatch adds a one-line case per type (`SF_TYPE_PATH` passthrough to `_sf_itoa_u64` for an inode-id or a str copy; `SF_TYPE_PID` passthrough to `_sf_itoa_u64`) without a stride change.

---

## 5. Parser mechanism

The parser is a tiny state machine with two phases and one shared field-body sub-walk. Register map (6 callee-save pushes + 24-byte stack scratch; `rsp%16==0` steady at every nested CALL):

| Reg          | Role                                          |
|--------------|-----------------------------------------------|
| `rbx`        | `bytes_ptr`                                   |
| `rbp`        | `bytes_len`                                   |
| `r12`        | `cursor` (byte offset into body)              |
| `r13`        | `current_out_ptr` (switches at phase boundary) |
| `r14`        | `current_out_cap` (remaining bytes)           |
| `r15`        | `fields_in_current` (per-side counter)        |
| `[rsp +  0]` | `out_out_schema_ptr`                          |
| `[rsp +  8]` | `out_out_cap`                                 |
| `[rsp + 16]` | phase tag (0 = INPUT, 1 = OUTPUT)             |

### 5.1 INPUT phase

```
INPUT_ENTRY:
    cursor = skip_ws(cursor)
    if peek(cursor..cursor+2) == "->":
        cursor += 2
        emit SS_TYPE_END to in_schema
        goto PHASE_SWITCH
    parse_field(INPUT)
    repeat:
        cursor = skip_ws(cursor)
        peek = bytes[cursor]
        if peek == ',': cursor += 1; parse_field(INPUT); continue
        if peek == '-' and bytes[cursor+1] == '>':
            cursor += 2
            emit SS_TYPE_END to in_schema
            goto PHASE_SWITCH
        error SS_ERR_SYNTAX
```

### 5.2 PHASE_SWITCH

Writes an `SS_TYPE_END` descriptor to the input-schema buffer. Rebinds `r13`/`r14`/`r15` to the output-schema buffer and resets `fields_in_current` to zero. Confirms the output buffer has capacity for at least one real field plus a terminator (32 bytes); otherwise `SS_ERR_TOO_MANY_FIELDS`.

### 5.3 OUTPUT phase

```
OUTPUT_ENTRY:
    parse_field(OUTPUT)
    repeat:
        cursor = skip_ws(cursor)
        if cursor == bytes_len:
            emit SS_TYPE_END to out_schema
            return SS_OK
        peek = bytes[cursor]
        if peek == ',': cursor += 1; parse_field(OUTPUT); continue
        error SS_ERR_SYNTAX
```

### 5.4 `parse_field` sub-walk

Shared between both phases via the phase-tag spill at `[rsp + 16]`:

```
parse_field(phase):
    guard: fields_in_current < SS_MAX_FIELDS, else SS_ERR_TOO_MANY_FIELDS
    guard: current_out_cap >= 2 * SS_FIELD_DESC_BYTES, else SS_ERR_TOO_MANY_FIELDS
    cursor = skip_ws(cursor)
    ident_start = cursor
    expect byte in [A-Za-z_]; else SS_ERR_SYNTAX
    while byte in [A-Za-z0-9_]: cursor += 1
    ident_len = cursor - ident_start
    if ident_len == 0 or ident_len > SS_NAME_MAX: SS_ERR_SYNTAX
    cursor = skip_ws(cursor)
    expect ':'; else SS_ERR_SYNTAX
    cursor += 1
    cursor = skip_ws(cursor)
    type_start = cursor
    expect byte in [A-Za-z_]; else SS_ERR_SYNTAX
    while byte in [A-Za-z0-9_]: cursor += 1
    type_len = cursor - type_start
    type_code = _sch_sig_classify_type(bytes_ptr + type_start, type_len)
    if type_code == SS_UNKNOWN_TYPE: SS_ERR_UNKNOWN_TYPE
    write 16-byte descriptor:
        [current_out_ptr + 0]       = type_code
        [current_out_ptr + 1]       = ident_len
        [current_out_ptr + 2 .. 2+ident_len) = ident bytes
        [current_out_ptr + 2+ident_len .. 16) = zero
    current_out_ptr += 16
    current_out_cap -= 16
    fields_in_current += 1
    goto {INPUT_AFTER_FIELD, OUTPUT_AFTER_FIELD} based on phase tag
```

### 5.5 Stack alignment

- Entry `rsp % 16 == 8` (SysV, after the implicit CALL that reached us).
- Six callee-save pushes: `rsp % 16` stays at `8` after each pair; after six pushes it is `8` again (`8 + 6 × (-8) mod 16 = 8`).
- `sub rsp, 24` for the three scratch slots: `rsp % 16 = (8 - 24) mod 16 = 0`.
- Both nested calls (`_sch_sig_skip_ws`, `_sch_sig_classify_type`) run with `rsp % 16 == 0`, satisfying SysV alignment.
- Epilogue: `add rsp, 24; pop r15; ...; pop rbx; ret`.

### 5.6 Encoder-pitfall posture

Reproduced from the module header (recorded here for ongoing audit per `feedback_pdx_encoder_pitfalls.md`):

- No `test rN, rN` — every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64` — every mask is imm8 or imm32.
- No 2-op `imul r, imm` — field-stride is `shl rN, 4` (× 16).
- No multiline `pub let = "..."` — single-line justifications.
- Module basename `SchemasSig` matches `schemas_sig.pdx`.
- Labels prefixed `sch_sig_` (never `loop` / `if` / `let` / `fn` / `ret` — reserved paideia-as keywords). `ss_` was NOT used because `ss_` is already a prefix fragment in `lite_reader.pdx` (`lit_ss_`), `slot_lifecycle.pdx` (`xhci_ss_`), `dp_altmode.pdx` (`dpam_ss_`), `microbench.pdx` (`mb_ss_`), and others; the public API already owns the `_ss_*` entry-point namespace.
- All `cmp reg, imm` immediates ≤ `0x2A03 < 0x80000000`, so direct `cmp reg, imm32` is sign-extension-safe. No MOVABS staging.
- Byte loads via `mov_b` (zero-extends into the full qword); byte stores via `mov_b [dst + idx], reg` (register-indexed, same shape as `libpdx-audit`'s `audit_file_sink` and `utf8_nfc.pdx`'s fast-path copy).

---

## 6. Interactions with sibling modules

### 6.1 R221.M1 (`utf8_nfc.pdx`) upstream

The caller is expected to have already run the input bytes through `_u8n_decode_and_normalize` before handing them to `_ss_parse_body`. The parser may therefore assume:

- the bytes are RFC 3629-well-formed UTF-8,
- the bytes are in NFC form.

Because the grammar accepts only ASCII identifiers and ASCII punctuation (`,`, `:`, `->`, `{`, `}`), the parser only ever inspects the ASCII subset of its input. Non-ASCII bytes inside an identifier fall through to `SS_ERR_SYNTAX` via the ident-cont byte-class check (none of `0x80..0xFF` is in `[A-Za-z0-9_]`), which is correct: a user-authored field name must be ASCII at the current language level.

### 6.2 R129.M4 (`schema_fmt.pdx`) lateral

The type-code numbering is deliberately shared across the two modules so a cmd-functor's output_schema can be rendered by `_schema_fmt_render` after a one-pass copy of the field_type bytes. The 14-byte inline name needs a pass-through widen into schema_fmt's 30-byte name slot (R222.M2 bridge). The byte layout at offset 0 and 1 (type then name_len) is already identical; only the name_inline widen is new work.

### 6.3 R222.M2 (`CommandSig`) consumer

Consumes two `SchemasSig` arrays per command, hashes them via `schema-registry.md` fingerprints, and seats them into the elaborator's per-command record. The hash input is the full 16-byte-per-field byte sequence up to (but not including) the `SS_TYPE_END` terminator — a byte-identical hash across host and kernel-side consumers because the inline-name representation is pointer-free.

### 6.4 R222.M3 (REPL dispatch) consumer

Calls `_ss_match_record` at each command invocation to validate incoming records against the signature. M3 therefore blocks on M2+ wiring the full match body; the stub signature at M1 ensures the ABI shape is pinned.

### 6.5 R131.M1 (user-space UTF-8 primitives) non-dependency

This module does **not** call `_norm_nfc` or `utf8_decode_cp` directly; the normalisation pass is the caller's responsibility (R221.M1's `_u8n_decode_and_normalize`). Keeping the UTF-8 dependency one level upstream mirrors the compositional pattern elsewhere in the library (R221.M4+ lexer calls `_u8n_decode_and_normalize` once per line, then feeds the bytes forward).

---

## 7. Forward path

| Milestone | Scope | How it uses R222.M1 output |
|-----------|-------|----------------------------|
| R222.M2   | `CommandSig` body parser | Consumes the two field-desc arrays this module produces; wraps them into the `CommandSig` record alongside `arguments`, `flags`, `effects`, `required_capabilities`. |
| R222.M3   | REPL dispatch | Replaces this module's `_ss_match_record` stub with a full field-by-field type-code compare over the record stream. |
| R222.M4   | `ArgSpec` + `FlagSpec` | Shares the type set via `SS_TYPE_*` mirror constants in those modules; no new type codes needed. |
| R222.M5   | Registry client | Reads a serialized form of the field-desc arrays from `/system/shell/commands.toml`; the on-disk form is the same byte sequence this module writes, with an endian-tagged header. |
| R222.M8   | Serialization for `describe <cmd>` | Round-trips the field-desc arrays through the queryable form; the 14-byte inline name is a stable primary key for the per-field record. |

---

## 8. Testing posture (R222.M1)

R222.M1 lands with the parser only. Test fixtures land under R222.M9 (not scheduled yet) and will cover:

1. **Golden parses** — each of the three legal forms (§2.1) parses to a byte-expected field-desc byte sequence.
2. **Type coverage** — one fixture per type (`u64`, `i64`, `str`, `hex`, `hash32`, `tsc`, `path`, `pid`), each landing the right type code.
3. **Error taxonomy** — one fixture per error code (`SS_ERR_SYNTAX`, `SS_ERR_UNKNOWN_TYPE`, `SS_ERR_TOO_MANY_FIELDS`), with the cursor at the right byte on each failure.
4. **Boundary cases** — empty input list; the exactly-32-field maximum; the exactly-13-character maximum identifier; whitespace between every token; multiple consecutive whitespace characters.
5. **Capacity exhaustion** — small cap values that trigger `SS_ERR_TOO_MANY_FIELDS` on the Nth field.
6. **UTF-8 non-ASCII rejection** — a body containing `π: u64` or similar fails with `SS_ERR_SYNTAX` because `π` (U+03C0, bytes `0xCF 0x80`) is not in `[A-Za-z0-9_]`.

Until R222.M9 lands these as a fuzz corpus, R222.M2's canary (`FileSchema` / `RawByteChunk@0.1` elaboration from the plan's M1 acceptance line) exercises the full parse path once.

---

## 9. Open follow-ups

- **R222.M? SS_TYPE_IMAGE wiring.** Once R129.M4's reserved type-7 slot lands as `SF_TYPE_IMAGE`, this module adds the mirror `SS_TYPE_IMAGE = 7` constant plus a 6-char `"image"` arm in `_sch_sig_classify_type` and a lateral note here. No ABI break; code 7 is already reserved.
- **R222.M? Nested type expressions.** `list<T>`, `option<T>`, and `tuple<T, U>` land when `CommandSig`'s richer argument types (R222.M4 `ArgSpec`) are parsed. The grammar extension is a one-production addition to `type_name`; the field-desc layout grows a sub-type tail. The 14-byte inline name becomes a 2-byte count + N-byte sub-type-code sequence; backward-compat is preserved via the `field_type` byte at offset 0 (new type codes 10..31 reserved).
- **R222.M? Allow empty output list.** When `CommandSig`'s `output_schema = None` is wired through, the parser accepts `path: path ->` (no output fields). The current M1 implementation returns `SS_ERR_SYNTAX` on this body. The fix is a two-line relaxation at `sch_sig_pb_output_first_field` plus a doc update to §2.2.

---

## 10. References

- paideia-os#2485 — R221 umbrella (parser-tier library).
- paideia-os#2658 — THIS ticket, R222.M1 `SchemasSig` body.
- paideia-os#2651 — R221.M1 UTF-8/NFC parser-tier wrapper (upstream dependency).
- paideia-os#2607 — R129.M4 schema_fmt (type-code numbering).
- paideia-os#2630 — R135.M5 wit_bridge (sibling pattern: WIT type set, length-switched classify).
- `design/terminal/semantic-shell.md` section 6 — Command modules (SH-D5).
- `design/terminal/semantic-shell-language-plan.md` section "R222 — Command-module functor surface + registry client" — the full R222.M1..M8 milestone sequence.
- `design/shell/parser-utf8-nfc.md` — the R221.M1 design doc; this doc mirrors its section shape.
- `design/shell/schema-driven-formatter.md` — the R129.M4 design doc; type-code numbering source of truth.
- `feedback_pdx_encoder_pitfalls.md` — the encoder-pitfall posture reproduced in §5.6.
