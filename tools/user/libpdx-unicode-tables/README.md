# libpdx-unicode-tables

paideia-os shared library: user-space UTF-8 / UTF-16 / grapheme-cluster
/ normalization primitives for the shell (pds), the lexer, and every
other ring-3 tool that walks text. The paideia-os-side `.pdx` analog
of what [paideia-as-unicode](../../paideia-as/crates/paideia-as-unicode/)
exposes on the Rust side.

## Purpose

paideia-os's shell (pds, R131..R139) decides to walk text at the
code-point boundary and above — paths, filenames, pipeline tokens,
command-module registry keys, every value threaded through a semantic
pipe. Doing that on raw byte slices quickly turns every tool into its
own RFC 3629 implementation plus its own ad-hoc "is this a well-formed
Unicode scalar?" check. This library closes that gap at the user-space
boundary: one copy of the UTF-8 decoder, one copy of the UCD-pinned
tables, one copy of the fingerprint contract — all linked by every
pds / builtin / command module.

The library is a passive linker artifact: every entry point is a pure
leaf operating on caller-supplied raw pointers. It makes no syscall,
binds no ambient service, holds no capability of its own
(`caps.decl` for the full absence manifest).

The Rust-side analog (`paideia-as-unicode::Utf8Decoder`) handles the
build-time path — the shell's lexer at R221.M4 is a Rust-hosted
service. This library handles the ring-3 execution path — every pds
command module written in `.pdx` consumes it directly.

## Status

**M1 landed — v1.0.0.** Four core UTF-8 primitives (decode, encode,
is_valid, count_cp) with full RFC 3629 §3 + §4 well-formedness gating
(overlong, surrogate, out-of-range all rejected). See
[`STATUS.md`](STATUS.md) for the per-milestone roadmap; M2..M6 remain
in follow-up issues.

## API surface (M1)

Every function returns a single `u64` register per paideia-as
calling-convention; multi-value returns pack into a single register
per the shape documented at each site.

| Function | Signature | Return |
|---|---|---|
| `Utf8::utf8_decode_cp` | `(src_ptr: u64, src_len: u64) -> u64` | success packs `(cp << 32) \| (bytes << 24)`; failure returns one of `UTF8_BAD_UTF8` / `UTF8_TRUNCATED` / `UTF8_OVERLONG` / `UTF8_BAD_CP` (`0xFFFFE700..0xFFFFE703`) |
| `Utf8::utf8_encode_cp` | `(cp: u64, dst_ptr: u64, dst_cap: u64) -> u64` | `bytes_written` (1..4) on success; `UTF8_BAD_CP` (surrogate or > U+10FFFF) or `UTF8_DST_TOO_SMALL` (`0xFFFFE704`) on failure |
| `Utf8::utf8_is_valid` | `(src_ptr: u64, src_len: u64) -> u64` | 1 iff every code point decodes cleanly, else 0 |
| `Utf8::utf8_count_cp` | `(src_ptr: u64, src_len: u64) -> u64` | code-point count on success; the first `UTF8_*` error band code encountered on failure (partial count discarded, matching `wc -m`-style refusal) |

Caller discrimination idiom (bits [31:24] of the packed decode result
are `bytes_consumed` in 1..4 on success, `0xFF` on every error-band
code):

```
mov r11, rax
shr r11, 24
and r11, 0xFF
cmp r11, 4
ja  <error>
```

A naive `cmp rax, 0xFFFFE700; jae <error>` is **unsafe** here: for any
`cp >= 1` the packed success value exceeds the error band
numerically. See the module header in [`src/utf8.pdx`](src/utf8.pdx)
for the full rationale.

Error band 0xFFFFE700..0xFFFFE70F (16-wide aligned user-space slice,
first 5 slots used at M1, 11 reserved for M2+):

| Code | Name | Meaning |
|---|---|---|
| 0xFFFFE700 | `UTF8_BAD_UTF8` | Bad lead byte, or non-continuation byte where one was required |
| 0xFFFFE701 | `UTF8_TRUNCATED` | `src_len` shorter than the lead byte's declared sequence length |
| 0xFFFFE702 | `UTF8_OVERLONG` | RFC 3629 §4 overlong 2/3/4-byte encoding (`0xC0`/`0xC1` lead, `0xE0` + byte1<0xA0, `0xF0` + byte1<0x90) |
| 0xFFFFE703 | `UTF8_BAD_CP` | Surrogate (U+D800..U+DFFF) or > U+10FFFF |
| 0xFFFFE704 | `UTF8_DST_TOO_SMALL` | `dst_cap` < bytes required to encode the given code point |

## Milestone roadmap

- **M1** — UTF-8 decode/encode primitives (this ticket, paideia-os#2612).
- **M2** — Streaming decoder iterator (`utf8_decode_iter_begin/next/end`)
  for the shell's R221.M4 lexer-equivalent on the pdx side.
- **M3** — UTF-16 bridge (`utf8_offset_to_utf16` /
  `utf16_offset_to_utf8`) for LSP consumers, mirroring the Rust-side
  `lsp_bridge` module.
- **M4** — Stream validators (fail-fast and fail-recover variants).
- **M5** — Grapheme-cluster boundary scanner (requires the UCD-pinned
  `GraphemeBreakProperty` table).
- **M6** — Normalization (NFC / NFD; requires the UCD-pinned
  `DerivedNormalizationProps` + `UnicodeData` decomposition tables).

See [`STATUS.md`](STATUS.md) for the full checklist.

## UCD pin

Unicode 15.1.0, mirroring the paideia-as-unicode crate's `UCD_VERSION`
constant. Any UCD-generated table landed by a later milestone (M5
grapheme-break, M6 normalization) MUST be regenerated from the pinned
version; a reader can gate on `LPX_UNICODE_UCD_VERSION` (encoded as
`(major << 16) | (minor << 8) | 0 = 0x0F0100` for 15.1.0) to detect
UCD drift between the Rust-side generator and the pdx-side consumer.

## Build

```
tools/build.sh
```

Builds every `src/*.pdx` into `build-out/*.o`. Requires paideia-as
>= 0.21.0 (resolves `$PAIDEIA_AS`, then the paideia-os sibling, then
`$PATH`). No link step at M1 — this library emits per-module `.o`
objects for downstream satellites to link against via
`--extra-obj-dir`, matching the libpdx-volume convention.

## Further reading

- [`src/utf8.pdx`](src/utf8.pdx) — module `Utf8`: the four primitives
  with full RFC 3629 citations, encoder-discipline notes, and the
  caller-discrimination idiom.
- [`src/lib.pdx`](src/lib.pdx) — module `LibpdxUnicodeTables`:
  version triple, UCD pin, per-milestone feature-ready flags.
- [`caps.decl`](caps.decl) — capability floor manifest (empty at M1).
- [`STATUS.md`](STATUS.md) — per-milestone checklist.
- [`tests/fingerprints/utf8.golden`](tests/fingerprints/utf8.golden) —
  the fingerprint-format contract a downstream test driver materialises.
- The paideia-as-unicode crate at
  `tools/paideia-as/crates/paideia-as-unicode/` — the Rust-side
  mirror; this library's return shapes, UCD pin, and milestone
  structure deliberately parallel it.

## License

MIT — see [`LICENSE`](LICENSE).
