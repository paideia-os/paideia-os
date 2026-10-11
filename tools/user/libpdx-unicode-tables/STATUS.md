# libpdx-unicode-tables -- status

**Wave:** R131 (semantic shell -- Unicode substrate umbrella,
paideia-os#2480)
**Current milestone:** M1 (UTF-8 decode/encode primitives) -- landed.
**Version:** 1.0.0.

See the R131 M-table in the umbrella issue (paideia-os#2480) for the
upstream wave-level design; this file tracks the per-milestone
landing checklist as it closes locally.

## Milestone checklist

### M1 -- UTF-8 primitives (paideia-os#2612, landed)

- [x] **M1-001** -- scaffold + module boundary: landed. Four source
      files (`src/lib.pdx` module `LibpdxUnicodeTables`,
      `src/utf8.pdx` module `Utf8`), `caps.decl`, `README.md`,
      `tools/build.sh`, `tests/fingerprints/utf8.golden`,
      `CHANGELOG.md`, `LICENSE`.
- [x] **M1-002** -- `utf8_decode_cp` real body: landed. RFC 3629 §3 +
      §4 well-formed UTF-8 decoder with 1/2/3/4-byte dispatch,
      sub-range gating on 0xE0/0xED/0xF0/0xF4 leads, and the five
      distinct `UTF8_*` return codes (BAD_UTF8, TRUNCATED, OVERLONG,
      BAD_CP, DST_TOO_SMALL) in the band 0xFFFFE700..0xFFFFE704.
- [x] **M1-003** -- `utf8_encode_cp` real body: landed. Inverse of
      the decoder with the same RFC 3629 §3 well-formed encoding;
      refuses surrogates (U+D800..U+DFFF) and > U+10FFFF via
      `UTF8_BAD_CP`; refuses short `dst_cap` via `UTF8_DST_TOO_SMALL`.
- [x] **M1-004** -- `utf8_is_valid` real body: landed. Walks the
      byte range by calling `utf8_decode_cp` repeatedly; returns 1
      iff every code point decodes cleanly, else 0.
- [x] **M1-005** -- `utf8_count_cp` real body: landed. Walks the
      byte range and returns the code-point count; propagates the
      first `UTF8_*` error code on malformed input (partial count
      discarded, `wc -m`-style refusal).

### M2 -- Streaming decoder iterator (planned)

- [ ] `utf8_decode_iter_begin(src_ptr, src_len) -> handle`
- [ ] `utf8_decode_iter_next(handle) -> packed | UTF8_* | EOF`
- [ ] `utf8_decode_iter_end(handle) -> void`
- [ ] Opaque-handle convention this library will own (initial sketch:
      a 24-byte struct `{src_ptr, src_len, pos}` the caller allocates
      and the primitives walk; no cap, no syscall).

### M3 -- UTF-16 bridge (planned)

- [ ] `utf8_offset_to_utf16(src_ptr, src_len, utf8_off) -> utf16_off`
- [ ] `utf16_offset_to_utf8(src_ptr, src_len, utf16_off) -> utf8_off`
- [ ] `utf8_offset_to_utf32` / `utf32_offset_to_utf8`
- [ ] Mirror of the paideia-as-unicode `lsp_bridge` module.

### M4 -- Stream validators (planned)

- [ ] `utf8_validate_stream` -- fail-fast whole-buffer validator.
- [ ] `utf8_validate_stream_recover` -- walks past the first
      malformed byte and reports every error offset, matching
      `paideia-as-unicode::Utf8Decoder::next`'s per-byte recovery.

### M5 -- Grapheme-cluster boundaries (planned)

- [ ] UCD-pinned GraphemeBreakProperty table (embedded `[u8; N]`).
- [ ] `grapheme_boundary_next(src_ptr, src_len, pos) -> next_pos`.

### M6 -- Normalization (planned)

- [ ] UCD-pinned DerivedNormalizationProps + decomposition tables.
- [ ] `norm_nfc` / `norm_nfd` in-place over caller-allocated buffer.

## Compatibility posture

M1's four `pub let` bindings and the `UTF8_*` return band
(0xFFFFE700..0xFFFFE704) are the library's FROZEN API. The remaining
11 slots in the 16-wide error band (0xFFFFE705..0xFFFFE70F) are
reserved for M2..M6 and will NOT shuffle the five M1 codes; a
consumer compiled against v1.0.0 keeps working at every future
version until an eventual v2.0.0 pivot (not planned).
