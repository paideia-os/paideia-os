## WIT-typed record bridge skeleton — M5 landing

**Status:** M5, 2026-10-14.
**Umbrella:** paideia-os R135 ("WASI-jail: a sandboxed execution environment
for WASI / WebAssembly modules running on paideia-os").
**Milestone:** R135.M5 (paideia-os #2630, Wave UMB-W19).
**Companion module:** [`wit_bridge.pdx`](../../src/kernel/core/wasi/wit_bridge.pdx)
**Companion substrates:**
- [`stdout_records.pdx`](../../src/kernel/core/wasi/stdout_records.pdx) (R135.M4 — the kernel-side typed-record ring the bridge feeds through `_stdout_records_register_schema`).
- [`wasi_args_conv.pdx`](../../src/kernel/core/wasi/wasi_args_conv.pdx) (R135.M3 — the twin side table for WASI argv / stdin).
- [`jail_supervisor.pdx`](../../src/kernel/core/svc/jail_supervisor.pdx) (R135.M1/M2 — the daemon that owns the per-jail cap-env + spawn-gate).
- [`schema_fmt.pdx`](../../src/kernel/core/term/schema_fmt.pdx) (R129.M4 — the downstream formatter whose `SF_TYPE_*` codes the bridge emits).

---

## Table of contents

1. Why a WIT bridge
2. WIT spec summary and M5 subset
3. Output format — `WB_FIELD_DESC` (32 bytes)
4. WIT → `SF_TYPE_*` mapping table
5. Public API
   - 5.1 `_wit_bridge_parse_type_decl(bytes_ptr, bytes_len, out_schema_ptr, out_schema_cap) -> packed u64`
   - 5.2 `_wit_bridge_register_module(pid, wit_type_decl_ptr, wit_type_decl_len) -> errno`
6. Return code band
7. Parse state machine
8. Interaction with R135.M4 (`stdout_records`) and R129.M4 (`schema_fmt`)
9. Encoder-pitfall posture
10. M5 → M6+ split and open questions

---

## 1. Why a WIT bridge

Paideia-os binaries will eventually declare their output record shape through
a direct typed-record syscall (not landed). For WASI modules — which run inside
R135's jail-supervisor sandbox and already use the component-model `wit`
interface-description language to declare their imports / exports — we need
a thin adapter that converts a WIT `record` type declaration into the
paideia-os schema shape used downstream by the R129.M4 formatter and the
R135.M4 stdout-record ring.

The alternative — forcing WASI modules to also emit a TSV schema header on
`stdout` at startup for `stdout_records.register_schema` — is a semantic
duplication: WIT already carries the field-name / field-type information
needed to drive the typed-record pipeline. A kernel-side bridge that reads
the WIT text once at module load eliminates the duplication and keeps the
WASI module's `stdout` purely about record payloads.

### Why in-kernel at this altitude

Three reasons line up with the companion substrates:

1. **Register-time only.** Parsing a WIT type decl happens once, at WASI
   module load (M6+ `execve` hook), never on the hot path. There is no
   per-write cost.
2. **Side-table pattern.** The parsed schema already lives in
   `_stdout_records_schemas` on the R135.M4 ring; the bridge produces the
   TSV form expected by `_stdout_records_register_schema` and the
   `SF_FIELD_DESC`-adjacent form expected by R129.M4. No new storage pool.
3. **Pure .pdx**, no user-space tooling, no round-trip through a daemon.
   The jail-supervisor spawn gate (R135.M1/M2) will call
   `_wit_bridge_register_module` directly after `caps_decl_apply` lands
   the WASI module in its jail.

### Why a skeleton at M5

The WIT spec covers variants, lists, flags, enums, resources, options,
results, tuples, and nested records; a full parser is a wave of work in
its own right. M5's charter is to land the parse surface, the output
descriptor shape, and the glue to R135.M4 — the subset that covers the
"flat record of scalars + strings" case which the overwhelming majority
of paideia-os-native WASI tools (`ls`, `ps`, `find`, `grep -c`, `stat`,
`df`) will emit. M6+ adds the complex-type stack.

---

## 2. WIT spec summary and M5 subset

### 2.1 WIT in one paragraph

The WebAssembly Interface Types language is a Rust-flavoured IDL for the
component model. A `.wit` file declares `interface` blocks containing
`type` aliases, `record` structural types, `variant` tagged unions,
`enum` symbolic unions, `flags` bit-fields, `resource` opaque handles,
and `func` signatures (import / export). Types compose: a record field
can be a record, a list, a result-of, an option-of, a tuple-of.

### 2.2 Full type set (reference, M5 does NOT handle)

The following are the WIT language's full carrier types; M5 handles only
the subset marked ✓ below.

| Category   | Keyword     | M5 | Deferred-to | Notes                      |
|------------|-------------|----|-------------|----------------------------|
| Primitive  | `bool`      | ✓  | —           | emitted as `SF_TYPE_U64`   |
| Primitive  | `u8`        | ✓  | —           | emitted as `SF_TYPE_U64`   |
| Primitive  | `u16`       | ✓  | —           | emitted as `SF_TYPE_U64`   |
| Primitive  | `u32`       | ✓  | —           | emitted as `SF_TYPE_U64`   |
| Primitive  | `u64`       | ✓  | —           | emitted as `SF_TYPE_U64`   |
| Primitive  | `s8`/`i8`   | ✓  | —           | emitted as `SF_TYPE_I64`   |
| Primitive  | `s16`/`i16` | ✓  | —           | emitted as `SF_TYPE_I64`   |
| Primitive  | `s32`/`i32` | ✓  | —           | emitted as `SF_TYPE_I64`   |
| Primitive  | `s64`/`i64` | ✓  | —           | emitted as `SF_TYPE_I64`   |
| Primitive  | `char`      | ✓  | —           | emitted as `SF_TYPE_STR`   |
| Primitive  | `string`    | ✓  | —           | emitted as `SF_TYPE_STR`   |
| Primitive  | `f32`,`f64` |    | M6          | needs `SF_TYPE_F64`        |
| Container  | `record`    | ✓* | —           | top-level only; no nesting |
| Container  | `variant`   |    | M6          | tagged union               |
| Container  | `enum`      |    | M6          | symbolic enum              |
| Container  | `flags`     |    | M6          | bit-field union            |
| Container  | `list<T>`   |    | M7          | needs ring entry extension |
| Container  | `tuple<..>` |    | M7          | positional fields          |
| Container  | `option<T>` |    | M7          | nullability                |
| Container  | `result<..>`|    | M7          | ok/err shape               |
| Opaque     | `resource`  |    | M8          | handle semantics           |
| Composite  | nested rec  |    | M8          | record inside record       |
| Grammar    | `interface` |    | M9          | type alias namespace       |
| Grammar    | `import`    |    | M9          | cross-module dep           |
| Grammar    | `export`    |    | M9          | cross-module dep           |
| Lexical    | `//` cmt    |    | M6          | line comments              |
| Lexical    | `/*..*/`    |    | M6          | block comments             |

(* M5 handles exactly one top-level `record` type decl per call; multiple
records or wrapping `interface { ... }` syntax is rejected with
`WB_ERR_UNSUPPORTED_TYPE`.)

### 2.3 M5 grammar (BNF)

```
TypeDecl   = ws* "record" ws+ Ident ws* "{" ws* FieldList? ws* "}" ws*
FieldList  = Field (ws* "," ws* Field)* (ws* ",")?
Field      = Ident ws* ":" ws* PrimType
PrimType   = "bool" | "char" | "string"
           | "u8" | "u16" | "u32" | "u64"
           | "s8" | "s16" | "s32" | "s64"
           | "i8" | "i16" | "i32" | "i64"
Ident      = IdentStart IdentChar*
IdentStart = ASCII letter | "_"
IdentChar  = ASCII letter | ASCII digit | "_" | "-"
ws         = ' ' | '\t' | '\n' | '\r'
```

Both WIT-canonical `s*` (signed) and C-flavoured `i*` are accepted; the
parser normalises both to `SF_TYPE_I64`. Comments are **not** supported
at M5 — a WIT decl with `//` or `/*..*/` returns `WB_ERR_PARSE`.

### 2.4 Example (round-trip)

Input WIT decl (62 bytes):

```
record FileEntry { name: string, size: u64, mode: u32 }
```

Produces three `WB_FIELD_DESC` entries (32 bytes each = 96 bytes) plus
one `SF_TYPE_END` terminator (32 bytes = 128 bytes total output):

```
desc[0] = { type=SF_TYPE_STR, name="name", name_len=4 }
desc[1] = { type=SF_TYPE_U64, name="size", name_len=4 }
desc[2] = { type=SF_TYPE_U64, name="mode", name_len=4 }
desc[3] = { type=SF_TYPE_END }
```

The register path additionally builds the TSV form
`name\tsize\tmode` (14 bytes, no trailing `\n`) and calls
`_stdout_records_register_schema(pid, "name\tsize\tmode", 14)`.

---

## 3. Output format — `WB_FIELD_DESC` (32 bytes)

The parse call writes a sequence of fixed-width descriptors to the output
buffer, terminated by one `SF_TYPE_END`-typed descriptor:

```
WB_FIELD_DESC (32 bytes = WB_FIELD_DESC_BYTES):
  [+0]   field_type   (u8)    SF_TYPE_END (0) | SF_TYPE_U64 (1) |
                              SF_TYPE_I64 (2) | SF_TYPE_STR (3)
  [+1]   name_len     (u8)    0 .. WB_NAME_MAX = 30
  [+2..+31]  name_inline (30 B)  ASCII field name, zero-padded.
                                  SF_TYPE_END entries carry zeros here.
```

Design choices:

- **Inline name** (vs. pointer back-ref into `bytes_ptr`): schema_fmt's
  current `SF_FIELD_DESC` layout packs `name_ptr` as a u48, which cannot
  address the top-half kernel VA where WIT decl bytes live. Rather than
  change `schema_fmt`'s layout, the bridge inlines the name directly into
  the descriptor at M5. A later milestone can swap to the `SF_FIELD_DESC`
  layout once a decision is made on name-arena provenance (see §10 Q2).
- **30-byte name cap** (vs. unlimited): the vast majority of WIT field
  names are ≤ 24 bytes (kebab-case, `name`, `size`, `mode`, `inode`,
  `blocks-allocated`, etc.). A 30-byte inline cap keeps the descriptor
  fixed-width, keeps the sum-of-widths calculation trivial, and matches
  SR_RECORD_PAYLOAD_MAX's "short identifier" posture. Over-long names
  return `WB_ERR_PARSE`.
- **Reusing `SF_TYPE_*` codes** (vs. a bridge-local enum): the bridge
  emits what the formatter expects on the wire; no code-point translation
  layer is needed. `SF_TYPE_END` is used verbatim as the schema terminator.
- **Fixed 32-byte stride** (vs. var-length): stride-32 keeps row addressing
  cheap (`shl rax, 5`) and matches the `SF_FIELD_DESC_BYTES = 32` width —
  so a future `_wit_bridge_to_sf_field_desc` conversion is a byte-copy
  with name-arena fixup, not a resize.

**Max output size.** For N fields plus the end terminator the bridge
writes `(N+1) * 32` bytes. With `WB_MAX_FIELDS = 32`, the ceiling is
`(32+1) * 32 = 1056` bytes. Callers that pass a smaller buffer get
`WB_ERR_OUT_TOO_SMALL` with `bytes_written = 0` (no partial writes
are retained; the caller resizes and retries).

---

## 4. WIT → `SF_TYPE_*` mapping table

| WIT keyword     | SF_TYPE_* code  | Rendering (per schema_fmt.pdx) |
|-----------------|-----------------|--------------------------------|
| `bool`          | `SF_TYPE_U64` (1) | decimal 0 / 1                |
| `u8`,`u16`,`u32`,`u64` | `SF_TYPE_U64` (1) | unsigned decimal     |
| `s8`,`s16`,`s32`,`s64` | `SF_TYPE_I64` (2) | signed decimal       |
| `i8`,`i16`,`i32`,`i64` | `SF_TYPE_I64` (2) | signed decimal       |
| `char`          | `SF_TYPE_STR` (3) | single UTF-8 glyph as string |
| `string`        | `SF_TYPE_STR` (3) | packed `ptr48 | len16` string |

M5 widens all unsigned primitives to `SF_TYPE_U64` (8-byte unsigned) and
all signed primitives to `SF_TYPE_I64` (8-byte signed) because the
R135.M4 ring stores payloads as tab-separated **raw ASCII** today — any
narrower representation would still render the same decimal in the
formatter. Native-width codes (SF_TYPE_U32, SF_TYPE_I16, …) land when the
binary record-stream path at R135.M7 arrives.

`SF_TYPE_HEX`, `SF_TYPE_HASH32`, `SF_TYPE_TSC` are not mapped from any
WIT primitive — they exist for native paideia-os emitters that know they
hold hashes or TSC ticks. A WASI module that wants hex rendering must
emit a `string` field with the hex-digit payload baked in.

---

## 5. Public API

### 5.1 `_wit_bridge_parse_type_decl(bytes_ptr, bytes_len, out_schema_ptr, out_schema_cap) -> packed u64`

Parse the textual WIT type decl at `bytes_ptr[0..bytes_len)` into a
sequence of `WB_FIELD_DESC` entries at `out_schema_ptr[0..out_schema_cap)`.

**Arguments (SysV):**
- `rdi = bytes_ptr`  — kernel pointer to WIT text; readable up to `bytes_len`.
- `rsi = bytes_len`  — byte count.
- `rdx = out_schema_ptr` — writable buffer.
- `rcx = out_schema_cap` — capacity in bytes.

**Returns (rax, packed u64):**
- bits [63..32] = `bytes_written` (0 on failure, descriptor-count × 32 on success).
- bits [31..0]  = status (`WB_OK` on success, `WB_ERR_*` on failure).

**Semantics:**
1. Scan `bytes_ptr[0..bytes_len)` through the §7 state machine.
2. On each primitive field, write a 32-byte descriptor at
   `out_schema_ptr + descriptors_written * 32`. Guard every write with a
   32-byte cap check; return `WB_ERR_OUT_TOO_SMALL` the first time the
   next write would exceed `out_schema_cap`.
3. On a successful parse close (`}` consumed), write one `SF_TYPE_END`
   terminator descriptor (same cap check applies).
4. Return `(bytes_written << 32) | WB_OK`.

### 5.2 `_wit_bridge_register_module(pid, wit_type_decl_ptr, wit_type_decl_len) -> errno`

Convenience wrapper: parse the WIT decl, derive the TSV field-name
schema, call `_stdout_records_register_schema`.

**Arguments (SysV):**
- `rdi = pid`
- `rsi = wit_type_decl_ptr`
- `rdx = wit_type_decl_len`

**Returns (rax):** errno (`WB_*` or `SR_*`).

**Semantics:**
1. Call `_wit_bridge_parse_type_decl(wit_type_decl_ptr, wit_type_decl_len,
   _wit_bridge_desc_scratch, 1056)` into the module-private descriptor
   scratch.
2. On parse error, return the `WB_ERR_*` status verbatim.
3. Walk the descriptors; for each non-END entry append `name_inline[0..name_len]`
   to `_wit_bridge_tsv_scratch`, separating with `\t`. No trailing `\n`.
4. Call `_stdout_records_register_schema(pid, _wit_bridge_tsv_scratch,
   tsv_len)` and return its `SR_*` status.
5. The TSV scratch length is bounded by SR_SCHEMA_MAX = 256; if the
   accumulated length would exceed it, abort before the call with
   `WB_ERR_PARSE` (overload: schema too wide for stdout_records).

**Reentrancy.** Both scratches are static .bss owned by the module;
`_wit_bridge_register_module` is **not reentrant** — it relies on the
kernel syscall lock held by the eventual M6 execve hook. A later wave
can shard the scratches per CPU if lock contention becomes a concern.

---

## 6. Return code band

The bridge owns `0x1C00..0x1Cff`:

```
WB_OK                   = 0
WB_ERR_PARSE            = 0x1C00
WB_ERR_UNSUPPORTED_TYPE = 0x1C01    variant/list/flags/enum/resource at M5
WB_ERR_OUT_TOO_SMALL    = 0x1C02    out_schema_cap exhausted
```

All fit imm32 with bit 31 clear so `mov rax, imm32` emits the 7-byte
zero-extending form (never `and r11, imm64`).

Error assignment table:

| Condition                                           | Code                    |
|-----------------------------------------------------|-------------------------|
| Unexpected byte in prolog (expected `record`)       | `WB_ERR_PARSE`          |
| Record name missing or not an ident                 | `WB_ERR_PARSE`          |
| Expected `{` not found                              | `WB_ERR_PARSE`          |
| Expected `:` after field name not found             | `WB_ERR_PARSE`          |
| Expected `,` or `}` after field value not found     | `WB_ERR_PARSE`          |
| Unterminated record (hit `bytes_len` mid-field)     | `WB_ERR_PARSE`          |
| Field name longer than `WB_NAME_MAX = 30`           | `WB_ERR_PARSE`          |
| Field count exceeds `WB_MAX_FIELDS = 32`            | `WB_ERR_PARSE`          |
| Type keyword not in M5 subset (`list`, `variant`, …)| `WB_ERR_UNSUPPORTED_TYPE` |
| Comments present (`//`, `/*`)                       | `WB_ERR_UNSUPPORTED_TYPE` |
| `interface { ... }` wrapping                        | `WB_ERR_UNSUPPORTED_TYPE` |
| Output buffer too small for next descriptor         | `WB_ERR_OUT_TOO_SMALL`  |
| TSV schema would exceed `SR_SCHEMA_MAX = 256`       | `WB_ERR_PARSE`          |

(`register_module` propagates `SR_*` from `_stdout_records_register_schema`
unchanged — `SR_ERR_BAD_PID`, `SR_ERR_RING_FULL`, `SR_ERR_SCHEMA_MISMATCH`.)

Rationale for a single parse code (`WB_ERR_PARSE` for all syntactic
failures) at M5: diagnostics are a formatter concern, and the kernel
is not emitting error-site offsets today. M6 can split this into a
richer band (`WB_ERR_EXPECT_RECORD`, `WB_ERR_EXPECT_LBRACE`, etc.) when
a diagnostic surface materialises.

---

## 7. Parse state machine

The parser is a single-pass left-to-right byte-driven DFA. States:

```
S_START           -> expect "record" keyword after ws
S_AFTER_RECORD    -> expect ws then ident (record name)
S_RECORD_NAME     -> consume ident chars
S_AFTER_NAME      -> expect ws then "{"
S_IN_BODY         -> expect ws then ident (field name) OR "}" to close
S_FIELD_NAME      -> consume ident chars
S_AFTER_FIELD     -> expect ws then ":"
S_AFTER_COLON     -> expect ws then type keyword
S_FIELD_TYPE      -> consume type keyword, then classify
S_AFTER_VALUE     -> expect ws then "," or "}"
S_DONE            -> accept, write SF_TYPE_END
```

The state machine is encoded as an index-into-input-driven loop in
`_wit_bridge_parse_type_decl`, with each state having its own label and
tail-jumping into the next state after consuming its input. Whitespace
is consumed inline inside every state that permits it.

### 7.1 Identifier scan

An ident scan at a given position `i`:
- Record start: `name_off = i`.
- Advance while byte is `[A-Za-z0-9_-]`.
- Stop at the first non-ident byte.
- Record end: `name_len = i - name_off`.
- Fail with `WB_ERR_PARSE` if `name_len == 0` or `name_len > WB_NAME_MAX`.

### 7.2 Type keyword classification

After an ident scan at the field-type position, the ident bytes are
compared against the ten M5-known type names:

```
"bool"  (4) -> SF_TYPE_U64
"char"  (4) -> SF_TYPE_STR
"string"(6) -> SF_TYPE_STR
"u8"    (2) -> SF_TYPE_U64
"u16"   (3) -> SF_TYPE_U64
"u32"   (3) -> SF_TYPE_U64
"u64"   (3) -> SF_TYPE_U64
"s8"    (2) -> SF_TYPE_I64   (also accepts "i8")
"s16"   (3) -> SF_TYPE_I64   (also accepts "i16")
"s32"   (3) -> SF_TYPE_I64   (also accepts "i32")
"s64"   (3) -> SF_TYPE_I64   (also accepts "i64")
```

A length-switched compare keeps the dispatch cheap: branch on `name_len`
first, then byte-compare the exact literal. Unknown idents at the
field-type position return `WB_ERR_UNSUPPORTED_TYPE` (the surface area
is "could be a complex type we don't support yet", not a syntactic error).

### 7.3 Whitespace skip

A helper state consumes any run of `' '`, `'\t'`, `'\n'`, `'\r'` and
returns the index of the first non-whitespace byte (or `bytes_len` if
the input is exhausted). Expressed inline inside each state as a tight
loop (no function call) to keep the stack frame flat.

### 7.4 Prolog keyword match

The `"record"` prolog is matched byte-by-byte against the input after
leading whitespace. A mismatch returns `WB_ERR_PARSE`. Shorter inputs
(bytes_len < 6) short-circuit to `WB_ERR_PARSE`.

### 7.5 Field count cap

The parser maintains a `fields_written` counter. When a field is about
to be committed and `fields_written == WB_MAX_FIELDS`, the parser
returns `WB_ERR_PARSE`. (The ceiling matches SF_MAX_FIELDS = 32.)

---

## 8. Interaction with R135.M4 (`stdout_records`) and R129.M4 (`schema_fmt`)

### 8.1 Register flow (M5)

Only `_wit_bridge_register_module` is reachable at M5, and only through
future call sites — M5 lands the entry points but does not wire them to
boot. Expected call flow at M6:

```
jail_supervisor.spawn (M6+)
  -> parse ELF .caps section (R15/R16)
  -> extract .wit_record text (new ELF section at M6)
  -> _wit_bridge_register_module(child_pid, wit_ptr, wit_len)
       -> _wit_bridge_parse_type_decl(... -> _wit_bridge_desc_scratch)
       -> build TSV in _wit_bridge_tsv_scratch
       -> _stdout_records_register_schema(child_pid, tsv_ptr, tsv_len)
  -> _wasi_args_register(child_pid, argv_blob, argv_len)
  -> aspace swap -> entry
```

### 8.2 Feed / drain unchanged

Once registered, the stdout record pipeline (M4's
`_stdout_records_feed` and `_stdout_records_drain`) is **unchanged**
by M5. The bridge only affects the register path; feed receives bytes,
drain copies records, both key on the pid lookup already in place.

### 8.3 Future wiring to schema_fmt

The `WB_FIELD_DESC` output of `_wit_bridge_parse_type_decl` is a
superset of `schema_fmt`'s per-field needs (type + name) but uses a
different name-pointer convention. A future
`_wit_bridge_to_sf_field_desc(wb_desc_ptr, name_arena_ptr,
sf_field_desc_ptr)` conversion copies each inline name into a
caller-provided name arena in the lower-half VA, packs
`name_arena_ptr | name_len` into the u48/u16 slot, and sets
`align/width/color_hint` to defaults. That conversion lands with the
first schema_fmt consumer in R135.M6 / R129.M5.

---

## 9. Encoder-pitfall posture

Standard discipline for the pdx encoder:

- `cmp rN, 0` for zero tests; never `test rN, rN` (encoder gap on
  symbol-indexed 2-operand `test`).
- `mov rax, imm32` for all `WB_*` and `SR_*` constants (bit 31 clear);
  never `and r11, imm64` (encoder gap).
- `shl rN, 5` for stride-32 descriptor addressing (never `imul r, imm`).
- `shl rax, 32` for packed-return hi half (imm8 operand).
- `cmp rN, N` byte-literal compares use imm32 encoding (bit 31 clear
  for all ASCII literals used: `'r'=0x72`, `'e'=0x65`, `'c'=0x63`,
  `'o'=0x6f`, `'d'=0x64`, `' '=0x20`, `'\t'=0x09`, `'\n'=0x0a`,
  `'\r'=0x0d`, `'{'=0x7b`, `'}'=0x7d`, `','=0x2c`, `':'=0x3a`,
  `'-'=0x2d`, `'_'=0x5f`, `'0'=0x30`, `'9'=0x39`, `'A'=0x41`,
  `'Z'=0x5a`, `'a'=0x61`, `'z'=0x7a`, `'8'=0x38`, `'6'=0x36`,
  `'1'=0x31`, `'3'=0x33`, `'2'=0x32`, `'4'=0x34`, `'5'=0x35`,
  `'7'=0x37`, `'u'=0x75`, `'i'=0x69`, `'s'=0x73`, `'b'=0x62`,
  `'h'=0x68`, `'l'=0x6c`, `'t'=0x74`, `'n'=0x6e`, `'g'=0x67`).
- Single-line `pub let name : T = expr`; no multi-line pub let.
- Module basename `WitBridge` matches file basename `wit_bridge.pdx`
  (ddc requires exact match).
- Labels prefixed `wb_` to stay clear of `sr_` (stdout_records),
  `wa_` (wasi_args), `js_` (jail_supervisor), `sf_` (schema_fmt),
  `at_` (ansi256-table), `ss_` (shell_session), `cmnt_` (cap_minter),
  `ks_` (kind_shell_session), `sh_` (shell_history).
- No reserved paideia-as keyword overlap (`loop`, `if`, `let`, `fn`,
  `else`, `match`, `module`, `structure`, `effects`, `capabilities`,
  `justification`, `block`, `unsafe`, `uninit`, `align`, `pub`, `mut`).

### 9.1 Stack discipline (SysV, entry rsp%16==8)

```
_wb_classify_type               0 pushes (pure leaf, scalar compares)
_wit_bridge_parse_type_decl     6 pushes + sub rsp, 8
                                (rbx=bytes_ptr, r12=bytes_len,
                                 r13=out_ptr,  r14=out_cap,
                                 r15=i_cursor, rbp=fields_written)
                                 even -> needs rsp,8 pad
_wit_bridge_register_module     3 pushes
                                (rbx=pid, r12=wit_ptr, r13=wit_len)
                                 odd -> aligned at nested calls
```

Nested calls: `_wit_bridge_register_module` calls
`_wit_bridge_parse_type_decl` then `_stdout_records_register_schema`.
`_wit_bridge_parse_type_decl` calls `_wb_classify_type` as a leaf.

---

## 10. M5 → M6+ split and open questions

### 10.1 What M5 lands

- Design doc (this file).
- `wit_bridge.pdx` with the four entry points
  (`_wb_classify_type`, `_wit_bridge_parse_type_decl`,
  `_wit_bridge_register_module`, plus any private helpers inlined).
- Return-code band `0x1C00..0x1Cff`.
- Static descriptor and TSV scratch buffers.
- No boot bringup, no fingerprint tags, no allowlist entries — the
  module is dead-code reachable only via the M6+ execve hook.

### 10.2 What M6+ adds

- M6: variant / enum / flags support; option<T> for nullable scalars;
  comment support; ELF `.wit_record` section parser; execve hook that
  calls `_wit_bridge_register_module` and emits the `wit convert ok
  kind=<n>` fingerprint on each successful register.
- M7: list<T> support (needs stdout_records ring entry extension to
  hold variable-length payloads); tuple<T,U,...>; result<T,E>.
- M8: nested record support; resource handles (needs cap system
  coupling to issue a handle id per resource).
- M9: multi-record WIT files, `interface { ... }` namespacing,
  `import` / `export` cross-module declarations.

### 10.3 Open questions

**Q1 — Should bool render as `true`/`false` or `1`/`0`?** M5 picks `0/1`
via `SF_TYPE_U64` because it keeps the mapping monomorphic and the
R135.M4 TSV substrate has no concept of a bool. M6 can add a
`SF_TYPE_BOOL` to render `true`/`false` if the UX demand arises.

**Q2 — Where do field-name bytes live for `SF_FIELD_DESC` wiring?**
`schema_fmt`'s `name_ptr` is u48, pointing into user-visible memory. The
WIT bytes live in the top-half kernel VA. Options:
  (a) copy names into a caller-provided name arena at convert time
      (chosen for M5's `WB_FIELD_DESC` inline design — M5 defers this);
  (b) widen `name_ptr` in `SF_FIELD_DESC` to 8-byte u64 (breaks M4
      binary layout);
  (c) sign-extend bit 47 on name_ptr unpacking (requires schema_fmt
      asm change).
Resolution deferred to R135.M6 or R129.M5, whichever arrives first.

**Q3 — Should the bridge validate field-name uniqueness?** The WIT spec
requires unique names within a record; M5 does not enforce this (the
cost is O(N²) and the WASI toolchain already rejects duplicates at
compile time). M6+ can add a dedup pass when ELF `.wit_record` becomes
the source of truth and the compile-time guard is lost.

**Q4 — How are nested-record collisions handled when they arrive at M8?**
Open. Candidates include flattening with dotted names (`addr.street`,
`addr.zip`) or declaring a single-level cap. Deferred.

**Q5 — Fingerprint shape for the M6 register event.** Issue text calls
for `wit convert ok kind=<n>` where `<n>` is the field count. The
fingerprint will land with the M6 execve hook, not M5 (M5 has no
reachable boot path).

**Q6 — Should the bridge accept both WIT-canonical `s32` and
C-flavoured `i32`?** M5 says yes (table in §2.3). The paideia-as toolchain
emits `i32` by convention; upstream wasm-tools emits `s32`. Accepting
both keeps authoring friction low.

**Q7 — Multi-call batching.** `_wit_bridge_parse_type_decl` is
single-shot (one record per call). If a `.wit_record` ELF section ever
holds multiple records, the caller loops with sliced input. M9 revisits
when `interface { ... }` wrapping arrives.
