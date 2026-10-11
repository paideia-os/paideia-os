# libpdx-unicode-tables -- status

**Wave:** R131 (semantic shell -- Unicode substrate umbrella,
paideia-os#2480)
**Current milestone:** M2 (grapheme-cluster iterator) -- landed.
**Version:** 1.1.0.

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

### M2 -- Grapheme-cluster iterator (paideia-os#2613, landed)

- [x] **M2-001** -- `_gc_classify(cp)` real body: landed. Maps a
      decoded UTF-8 code point to one of eight TR#29 property
      values: OTHER, CR, LF, CONTROL, EXTEND, ZWJ,
      REGIONAL_INDICATOR, PICTOGRAPHIC. Straight-line range
      dispatch; no UCD table yet (ranges hand-coded for the Latin
      diacritic + emoji baseline).
- [x] **M2-002** -- `_gc_next(bytes_ptr, bytes_len, cursor_byte)`
      real body: landed. TR#29 Rev-15 state machine with
      seed-and-extend loop. Status codes: 0=OK, 1=EOF, 2=INVALID_UTF8.
      Mid-cluster INVALID returns OK with the cluster ending just
      before the malformed byte (ICU-style recovery).
- [x] **M2-003** -- `_gc_count(bytes_ptr, bytes_len)` real body:
      landed. Repeated `_gc_next` to EOF; returns the cluster count
      on success or `GC_INVALID_UTF8` (0xFFFFE710) on any malformed
      sub-sequence (partial count discarded, `wc -m`-style).
- [x] **M2-004** -- Fingerprint goldens: `tests/fingerprints/grapheme.golden`
      with 10 TAG lines (ab, a_acute, a_acute_b, crlf, lfcr,
      flag_pair, family, empty, single, leading_extend).
- [x] **M2-005** -- Proptest witnesses:
      `tests/proptest_grapheme.pdx` with 5 invariants (round-trip,
      monotone, count agreement, EOF status, invalid UTF-8
      propagation) and umbrella `pgc_run_all`.
- [x] **M2-006** -- Benches: `benches/grapheme.pdx` with two
      fixtures (ASCII fast path, GB11 family emoji); `tools/build.sh`
      extended to compile `benches/*.pdx`.

**M2 limitations (stubbed; tracked for M2.1+ follow-up tickets):**

- GB6/GB7/GB8 (Hangul syllable composition): no-op. Needs UCD
  HangulSyllableType.txt table.
- GB9a (SpacingMark): empty property set. Needs UCD
  GraphemeBreakProperty.txt table.
- GB9b (Prepend): empty property set. Needs UCD
  GraphemeBreakProperty.txt table.
- Pictographic range: single-range approximation
  (U+1F300..U+1F9FF) in place of the ~1500-cp
  Extended_Pictographic set. Covers every emoji in the M2
  fingerprint goldens; a sparser-trie landing is M2.2 work.
- Extend range: Latin combining diacritics only
  (U+0300..U+036F); Hebrew / Arabic / Devanagari combining
  marks are not yet recognised.

### M3 -- Streaming decoder iterator (planned)

- [ ] `utf8_decode_iter_begin(src_ptr, src_len) -> handle`
- [ ] `utf8_decode_iter_next(handle) -> packed | UTF8_* | EOF`
- [ ] `utf8_decode_iter_end(handle) -> void`
- [ ] Opaque-handle convention this library will own (initial sketch:
      a 24-byte struct `{src_ptr, src_len, pos}` the caller allocates
      and the primitives walk; no cap, no syscall).

### M4 -- UTF-16 bridge (planned)

- [ ] `utf8_offset_to_utf16(src_ptr, src_len, utf8_off) -> utf16_off`
- [ ] `utf16_offset_to_utf8(src_ptr, src_len, utf16_off) -> utf8_off`
- [ ] `utf8_offset_to_utf32` / `utf32_offset_to_utf8`
- [ ] Mirror of the paideia-as-unicode `lsp_bridge` module.

### M5 -- Stream validators (planned)

- [ ] `utf8_validate_stream` -- fail-fast whole-buffer validator.
- [ ] `utf8_validate_stream_recover` -- walks past the first
      malformed byte and reports every error offset, matching
      `paideia-as-unicode::Utf8Decoder::next`'s per-byte recovery.

### M6 -- Normalization (planned)

- [ ] UCD-pinned DerivedNormalizationProps + decomposition tables.
- [ ] `norm_nfc` / `norm_nfd` in-place over caller-allocated buffer.

## Compatibility posture

M1's four `pub let` bindings and the `UTF8_*` return band
(0xFFFFE700..0xFFFFE704) are the library's FROZEN API. The remaining
11 slots in the 16-wide error band (0xFFFFE705..0xFFFFE70F) are
reserved for later milestones and will NOT shuffle the five M1
codes; a consumer compiled against v1.0.0 keeps working at every
future version until an eventual v2.0.0 pivot (not planned).

M2 adds two `pub let` bindings (`_gc_next`, `_gc_count`) plus the
one-code error band 0xFFFFE710..0xFFFFE71F (first slot used:
`GC_INVALID_UTF8` at 0xFFFFE710). The three status codes
(GC_STATUS_OK=0, GC_STATUS_EOF=1, GC_STATUS_INVALID_UTF8=2) are
packed into the low 32 bits of `_gc_next`'s return; the next_cursor
in the high 32 bits is unsigned. M2 is additive and preserves every
M1 symbol unchanged -- v1.1.0 is backward-compatible with v1.0.0.
