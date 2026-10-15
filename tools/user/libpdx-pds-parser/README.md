# libpdx-pds-parser

paideia-os shared library: parser-tier wrappers over the kernel-side
`libpdx-unicode-tables` substrate. The .pdx library that `pds-lang`
(the semantic-shell language — R221..R229) and the shell's lexer
link against for Unicode-aware input processing.

## Purpose

paideia-os's semantic shell parses user input through a cascade:
raw bytes → UTF-8 decode + NFC normalise → grapheme cluster iterator
→ context-tracking lexer → unified AST. Each stage has substrate
primitives available in `libpdx-unicode-tables` (R131), but calling
those primitives directly from the parser means every parser-level
call site becomes its own ad-hoc wrapper over the byte-level codec.
This library closes that gap: one wrapper per stage, each tuned for
the parser's call-site shape (bulk input, hot-path ASCII, needs the
normalised bytes before lexing).

The library is a passive linker artifact: every entry point is a
pure leaf (`_u8n_quick_check_ascii`) or a leaf that delegates to
`libpdx-unicode-tables` (`_u8n_decode_and_normalize`). It makes no
syscall, binds no ambient service, holds no capability of its own
(see `caps.decl` for the full absence manifest).

## Status

**R221.M1 landed — v1.1.0.** UTF-8 decoder + NFC normalizer with the
ASCII fast-path heuristic.
**R223.M1 landed — v1.1.0.** Pipeline-stage parser (`cmd | cmd | ...`
tokeniser with quoting + escape handling).
**R224.M1 landed — v1.5.0.** Lambda literal grammar
(`\x:u64 -> ...` / `\(x:u64, y:u64) -> ...`): LambdaHeader + Param
descriptor emitter, body bytes copied verbatim for R224.M2
expression parse.
See [`STATUS.md`](STATUS.md) for the per-milestone roadmap; R221.M2+,
R223.M2+, R224.M2+ remain in follow-up issues.

## API surface

Every function returns a single `u64` register per paideia-as
calling convention; multi-value returns pack into a single register
per the shape documented at each site.

### R221.M1 — UTF-8 decoder + NFC normaliser

| Function | Signature | Return |
|---|---|---|
| `Utf8Nfc::_u8n_quick_check_ascii` | `(bytes_ptr: u64, bytes_len: u64) -> u64` | `1` iff every byte `< 0x80`, else `0`. Zero-length input returns `1`. |
| `Utf8Nfc::_u8n_decode_and_normalize` | `(bytes_ptr: u64, bytes_len: u64, out_ptr: u64, out_cap: u64) -> u64` | `(bytes_written << 32) \| status`; status in `{U8N_OK, U8N_ERR_INVALID_UTF8, U8N_ERR_OUT_TOO_SMALL, U8N_ERR_NORMALIZE_FAIL}` |

#### U8N_* status codes (`src/utf8_nfc.pdx` Section 1)

| Name | Value | Meaning |
|---|---|---|
| `U8N_OK` | `0` | Decode + normalise succeeded; `bytes_written` carries NFC byte count |
| `U8N_ERR_INVALID_UTF8` | `0x2700` | Input is not RFC 3629 well-formed UTF-8 |
| `U8N_ERR_OUT_TOO_SMALL` | `0x2701` | `out_cap` smaller than NFC output |
| `U8N_ERR_NORMALIZE_FAIL` | `0x2702` | Reserved for post-M1 normaliser-internal failure (never returned at M1) |

### R223.M1 — Pipeline stage parser

| Function | Signature | Return |
|---|---|---|
| `Pipeline::_pl_parse` | `(bytes_ptr: u64, bytes_len: u64, out_ptr: u64, out_cap: u64) -> u64` | `(n_stages << 32) \| status`; status in `{PL_OK, PL_ERR_TOO_MANY_STAGES, PL_ERR_TOO_MANY_ARGS, PL_ERR_UNTERMINATED_QUOTE, PL_ERR_EMPTY_STAGE, PL_ERR_OUT_TOO_SMALL}` |
| `Pipeline::_pl_emit_word` | `(stage_ptr: u64, offset: u64, len: u64, word_slot: u64) -> u64` | `PL_OK` or `PL_ERR_TOO_MANY_ARGS`; internal helper |

#### PL_* status codes (`src/pipeline.pdx` Section 1)

| Name | Value | Meaning |
|---|---|---|
| `PL_OK` | `0` | Parse succeeded; `n_stages` is the number of 64-byte `PipelineStage` records written. |
| `PL_ERR_TOO_MANY_STAGES` | `0x2B00` | > `PL_MAX_STAGES` (16) `\|`-delimited stages. |
| `PL_ERR_TOO_MANY_ARGS` | `0x2B01` | > `PL_MAX_ARGS` (8) argv per stage (cmd_name separate). |
| `PL_ERR_UNTERMINATED_QUOTE` | `0x2B02` | Open `"` or `'` at end-of-input. |
| `PL_ERR_EMPTY_STAGE` | `0x2B03` | Consecutive `\|\|`, leading `\|`, or trailing `\|`. |
| `PL_ERR_OUT_TOO_SMALL` | `0x2B04` | `out_cap` smaller than the stage buffer the input needs. |

#### `PipelineStage` record (64 bytes)

| Offset | Size | Field | Type |
|---:|---:|---|---|
| 0 | 4 | `cmd_name_offset` | u32 (byte offset into input) |
| 4 | 2 | `cmd_name_len` | u16 |
| 6 | 2 | `n_args` | u16 (0..`PL_MAX_ARGS`) |
| 8 | 32 | `argv_offsets[8]` | u32[8] |
| 40 | 16 | `argv_lens[8]` | u16[8] |
| 56 | 2 | `flags` | u16 (bit 0 `HAS_ESCAPES`, bit 1 `HAS_QUOTES`) |
| 58 | 6 | `_reserved[6]` | u8[6] (zero at M1) |

### R224.M1 — Lambda literal grammar

| Function | Signature | Return |
|---|---|---|
| `LambdaLit::_ll_parse` | `(bytes_ptr: u64, bytes_len: u64, out_ptr: u64, out_cap: u64) -> u64` | `(bytes_written << 32) \| status`; status in `{LL_OK, LL_ERR_SYNTAX, LL_ERR_TOO_MANY_PARAMS, LL_ERR_UNKNOWN_TYPE, LL_ERR_OUT_TOO_SMALL, LL_ERR_NO_ARROW}` |
| `LambdaLit::_ll_parse_param` | `(bytes_ptr: u64, bytes_len: u64, cursor_in: u64, param_write_ptr: u64) -> u64` | `(new_cursor << 32) \| status`; cross-fn helper |
| `LambdaLit::_ll_skip_ws` | `(bytes_ptr: u64, bytes_len: u64, cursor_in: u64) -> u64` | advanced cursor past SP/TAB/LF/CR |
| `LambdaLit::_ll_classify_type` | `(ident_ptr: u64, ident_len: u64) -> u64` | one of `LL_TYPE_U64`..`LL_TYPE_PID` or `LL_UNKNOWN_TYPE` |

#### LL_* status codes (`src/lambda_lit.pdx` Section 1)

| Name | Value | Meaning |
|---|---|---|
| `LL_OK` | `0` | Parse succeeded; `bytes_written = 32 + n_params*32 + body_len`. |
| `LL_ERR_SYNTAX` | `0x2C00` | Grammar mismatch at ident, `:`, `(`, `)`, or `,`. |
| `LL_ERR_TOO_MANY_PARAMS` | `0x2C01` | `> LL_MAX_PARAMS` (8). |
| `LL_ERR_UNKNOWN_TYPE` | `0x2C02` | `type_name` not in the M1 set (u64/i64/str/hex/hash32/tsc/path/pid). |
| `LL_ERR_OUT_TOO_SMALL` | `0x2C03` | `out_cap < 32 + n_params*32 + body_len`. |
| `LL_ERR_NO_ARROW` | `0x2C04` | ParamList terminator was not `->`. |

#### `LambdaHeader` record (32 bytes)

| Offset | Size | Field | Type |
|---:|---:|---|---|
| 0 | 4 | `magic` | u32 (= `LL_HEADER_MAGIC = 0x44424D4C` / `'LMBD'`) |
| 4 | 2 | `n_params` | u16 (0..`LL_MAX_PARAMS`) |
| 6 | 2 | `flags` | u16 (reserved; 0 at M1) |
| 8 | 4 | `body_offset` | u32 (= 32 + n_params*32; offset within out) |
| 12 | 4 | `body_len` | u32 (opaque body byte count) |
| 16 | 16 | `reserved[16]` | u8[16] (zero at M1; M2+: effect-row id, cap-row id) |

#### `Param` descriptor (32 bytes each)

| Offset | Size | Field | Type |
|---:|---:|---|---|
| 0 | 1 | `type_code` | u8 (`LL_TYPE_*`, 1..9 with 7 reserved) |
| 1 | 1 | `name_len` | u8 (1..`LL_NAME_MAX` = 13) |
| 2 | 14 | `name_inline[14]` | u8[14] (ASCII; zero-padded past `name_len`) |
| 16 | 16 | `reserved[16]` | u8[16] (zero at M1; M2+: default-value, closure-capture, destructure) |

## Fast-path strategy

`_u8n_decode_and_normalize` begins by calling
`_u8n_quick_check_ascii`. On a pure-ASCII input (every byte
`< 0x80`), it does a byte-for-byte copy from input to output — correct
because every ASCII code point is a trivially-well-formed 1-byte
UTF-8 scalar AND a fixed point of NFC (no `U+0000..U+007F` code
point has a canonical decomposition, nor appears as the mark of
any such decomposition). On a non-ASCII input, it delegates to
`libpdx-unicode-tables::Normalize::_norm_nfc`.

The ASCII fast path is strictly stronger than
`libpdx-unicode-tables::IpcNfc::_ipc_nfc_check`'s `0xCC/0xCD`
presence check: it gates both the full UTF-8 validator and the
NFC pass, where the IPC heuristic gates only the NFC pass. The
parser's hot path (pipeline tokens, builtin names, ASCII paths)
dominates the input distribution, so the fast path pays off.

## Linker dependencies

`Utf8Nfc::_u8n_decode_and_normalize` references the external symbol
`_norm_nfc` from `libpdx-unicode-tables::Normalize` (R131.M3). A
consumer linking this library passes
`--extra-obj-dir tools/user/libpdx-unicode-tables/build-out` to
`paideia-as link` so the symbol resolves. If the consumer wants
only `_u8n_quick_check_ascii` (no nested call), it can link this
library standalone.

`Pipeline::_pl_parse` has no external linker dependencies; it only
CALLs the module-private `_pl_emit_word`.

`LambdaLit::_ll_parse` has no external linker dependencies; it only
CALLs the module-private `_ll_skip_ws`, `_ll_classify_type`, and
`_ll_parse_param` (the last of which in turn CALLs `_ll_skip_ws` and
`_ll_classify_type`).

## Build

```sh
cd tools/user/libpdx-pds-parser
bash tools/build.sh
```

Requires `paideia-as >= 0.21.0`. The script auto-resolves the
assembler via `$PAIDEIA_AS` env var, the sibling paideia-os checkout,
or `$PATH`.

## Design docs

- `design/shell/parser-utf8-nfc.md` — R221.M1 interaction model with
  the R131 Unicode substrate, fast-path heuristic rationale,
  forward path to R221.M2+.
- `design/shell/pipeline-stage-parser.md` — R223.M1 grammar, state
  machine, `PipelineStage` layout, interactions with R129.M5
  renderer `as` syntax and R222 cmd-functor dispatch.
- `design/shell/lambda-literal-grammar.md` — R224.M1 grammar,
  LambdaHeader + Param record layout, interactions with R222.M1
  SchemasSig (shared type codes), forward path to R224.M2 expression
  parse + R224.M3 effect polymorphism.

## References

- `tools/user/libpdx-unicode-tables/src/utf8.pdx` — R131.M1 UTF-8
  primitives (`utf8_decode_cp`, `utf8_is_valid`, `utf8_count_cp`,
  `utf8_encode_cp`).
- `tools/user/libpdx-unicode-tables/src/normalize.pdx` — R131.M3
  normaliser (`_norm_nfc`, `_norm_nfd`, `_norm_nfkc`, `_norm_nfkd`).
- `tools/user/libpdx-unicode-tables/src/ipc_nfc.pdx` — R131.M8
  IPC-boundary NFC hook (sibling fast-path heuristic).
- `design/terminal/semantic-shell-language-plan.md` §4 R221 — parser
  milestone table.
- `design/terminal/semantic-shell.md` SH-D9.4 — "lexer sees
  NFC-form input".

## License

MIT. See [`LICENSE`](LICENSE).
