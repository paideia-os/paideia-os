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

**M1 landed — v1.0.0.** UTF-8 decoder + NFC normalizer with the
ASCII fast-path heuristic for the parser hot path. See
[`STATUS.md`](STATUS.md) for the per-milestone roadmap; M2..M7
remain in follow-up issues.

## API surface (M1)

Every function returns a single `u64` register per paideia-as
calling convention; multi-value returns pack into a single register
per the shape documented at each site.

| Function | Signature | Return |
|---|---|---|
| `Utf8Nfc::_u8n_quick_check_ascii` | `(bytes_ptr: u64, bytes_len: u64) -> u64` | `1` iff every byte `< 0x80`, else `0`. Zero-length input returns `1`. |
| `Utf8Nfc::_u8n_decode_and_normalize` | `(bytes_ptr: u64, bytes_len: u64, out_ptr: u64, out_cap: u64) -> u64` | `(bytes_written << 32) \| status`; status in `{U8N_OK, U8N_ERR_INVALID_UTF8, U8N_ERR_OUT_TOO_SMALL, U8N_ERR_NORMALIZE_FAIL}` |

### Status codes (`src/utf8_nfc.pdx` Section 1)

| Name | Value | Meaning |
|---|---|---|
| `U8N_OK` | `0` | Decode + normalise succeeded; `bytes_written` carries NFC byte count |
| `U8N_ERR_INVALID_UTF8` | `0x2700` | Input is not RFC 3629 well-formed UTF-8 |
| `U8N_ERR_OUT_TOO_SMALL` | `0x2701` | `out_cap` smaller than NFC output |
| `U8N_ERR_NORMALIZE_FAIL` | `0x2702` | Reserved for post-M1 normaliser-internal failure (never returned at M1) |

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

`_u8n_decode_and_normalize` references the external symbol
`_norm_nfc` from `libpdx-unicode-tables::Normalize` (R131.M3). A
consumer linking this library passes
`--extra-obj-dir tools/user/libpdx-unicode-tables/build-out` to
`paideia-as link` so the symbol resolves. If the consumer wants
only `_u8n_quick_check_ascii` (no nested call), it can link this
library standalone.

## Build

```sh
cd tools/user/libpdx-pds-parser
bash tools/build.sh
```

Requires `paideia-as >= 0.21.0`. The script auto-resolves the
assembler via `$PAIDEIA_AS` env var, the sibling paideia-os checkout,
or `$PATH`.

## Design doc

- `design/shell/parser-utf8-nfc.md` — R221.M1 interaction model with
  the R131 Unicode substrate, fast-path heuristic rationale,
  forward path to R221.M2+.

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
