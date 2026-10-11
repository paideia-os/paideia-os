# Changelog -- libpdx-unicode-tables

All notable changes to this library are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) +
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] -- 2026-10-11

R131.M2 of the semantic-shell Unicode umbrella (paideia-os#2480,
decomposed into paideia-os#2613 for this M2).

### Added

- `src/grapheme.pdx` module `Grapheme`: TR#29 (UAX #29 Rev 15)
  grapheme-cluster iterator over UTF-8.
  - `_gc_classify(cp) -> prop` -- maps a decoded code point to one
    of eight reduced TR#29 property values (OTHER, CR, LF,
    CONTROL, EXTEND, ZWJ, REGIONAL_INDICATOR, PICTOGRAPHIC).
  - `_gc_next(bytes_ptr, bytes_len, cursor_byte) -> packed_u64`
    -- advances by one grapheme cluster; returns
    `(next_cursor << 32) | status` with status in {0=OK, 1=EOF,
    2=INVALID_UTF8}. Mid-cluster INVALID_UTF8 is converted to
    OK with the cluster ending just before the malformed byte,
    matching ICU `BreakIterator`-style recovery.
  - `_gc_count(bytes_ptr, bytes_len) -> u64 | GC_*` -- total
    cluster count, or `GC_INVALID_UTF8` (0xFFFFE710) if any
    sub-sequence is malformed.
- `tests/fingerprints/grapheme.golden`: 10 TAG lines covering
  ASCII pairs, Latin diacritic (GB9), CRLF (GB3), reverse LFCR,
  regional-indicator flag pair (GB12/13), family emoji ZWJ chain
  (GB11), empty input, single ASCII, and leading-combining-mark.
- `tests/proptest_grapheme.pdx` module `ProptestGrapheme`: five
  invariant witnesses (round-trip, monotone, count agreement, EOF
  status, invalid-UTF8 propagation) plus umbrella `pgc_run_all`;
  fail codes in the 0xFFFFED6x band (extends the existing
  TestLexer-family bands).
- `benches/grapheme.pdx` module `BenchGrapheme`: two straight-line
  perf fixtures (`gcb_bench_ascii_8` for the ASCII fast path,
  `gcb_bench_family_emoji` for the GB11 state-machine hot path).
- `tools/build.sh` extended to compile `benches/*.pdx` alongside
  `src/*.pdx` and `tests/*.pdx`.

### Changed

- `src/lib.pdx`: version bump 1.0.0 -> 1.1.0;
  `LPX_UNICODE_VERSION_MINOR` = 1; `LPX_UNICODE_M2_READY` = 1;
  `lpx_unicode_feature_level()` now returns 2. The earlier M2
  "streaming decoder" slot has been pushed to M3 pending the
  opaque-handle convention; the per-milestone comments in
  `lib.pdx` reflect the shifted numbering.

### Error band

- 0xFFFFE710..0xFFFFE71F reserved for grapheme-layer error codes
  (one used at M2: `GC_INVALID_UTF8` = 0xFFFFE710). Disjoint from
  the M1 slice (0xFFFFE700..0xFFFFE70F) and every other band in
  the paideia-os tree.

### TR#29 scope (Rev 15 reduced-Latin+emoji baseline)

Rules IMPLEMENTED:

- GB1 (break at sot), GB2 (break at eot).
- GB3 (CR x LF -- no break between).
- GB4 (break after Control/CR/LF), GB5 (break before Control/CR/LF).
- GB9 (x Extend | ZWJ -- no break before combining or joiner).
- GB11 ((EP Extend*) ZWJ x EP -- emoji ZWJ chain).
- GB12/GB13 (RI pairs -- flag emoji).
- GB999 (default break).

Rules STUBBED at M2 (land at M2.x+ follow-ups):

- GB6/GB7/GB8 (Hangul syllable composition): no-op; needs UCD
  HangulSyllableType.txt.
- GB9a (SpacingMark): empty property set.
- GB9b (Prepend): empty property set.

Property tables approximated at M2:

- Extend = U+0300..U+036F (Latin combining diacritics only).
- Pictographic = U+1F300..U+1F9FF (single-range approximation of
  Extended_Pictographic; covers every emoji in the fingerprint
  goldens).

### Build

- paideia-as >= 0.21.0 required (unchanged from M1).
- `tools/build.sh` emits per-module `build-out/*.o` objects for
  `src/`, `tests/`, and `benches/`; no link step at M2 (downstream
  satellites link via `--extra-obj-dir`).

## [1.0.0] -- 2026-10-11

Initial release. R131.M1 of the semantic-shell Unicode umbrella
(paideia-os#2480, decomposed into paideia-os#2612 for this M1).

### Added

- Satellite scaffold under `tools/user/libpdx-unicode-tables/`:
  `src/lib.pdx` module `LibpdxUnicodeTables`, `src/utf8.pdx` module
  `Utf8`, `caps.decl`, `tools/build.sh`, `tests/fingerprints/utf8.golden`,
  `README.md`, `STATUS.md`, `LICENSE`.
- Four UTF-8 primitives in `src/utf8.pdx`:
  - `utf8_decode_cp(src_ptr, src_len) -> packed | UTF8_*`
  - `utf8_encode_cp(cp, dst_ptr, dst_cap) -> bytes | UTF8_*`
  - `utf8_is_valid(src_ptr, src_len) -> 1 | 0`
  - `utf8_count_cp(src_ptr, src_len) -> count | UTF8_*`
- Error band 0xFFFFE700..0xFFFFE70F (16-wide aligned user-space
  slice; 5 slots used, 11 reserved for M2+): `UTF8_BAD_UTF8`,
  `UTF8_TRUNCATED`, `UTF8_OVERLONG`, `UTF8_BAD_CP`,
  `UTF8_DST_TOO_SMALL`.
- Version / UCD-pin / per-milestone feature-ready constants in
  `src/lib.pdx` (`LPX_UNICODE_VERSION_*`, `LPX_UNICODE_UCD_VERSION =
  0x0F0100` for Unicode 15.1.0, `LPX_UNICODE_M{1..6}_READY`).
- Fingerprint-format contract at
  `tests/fingerprints/utf8.golden` (three contract lines: DECODE,
  ENCODE, VALID). Materialised later by whichever downstream test
  driver first links this library and has a klog capability.

### RFC compliance

- RFC 3629 §3 encoding form (1/2/3/4-byte UTF-8).
- RFC 3629 §4 well-formed byte sequences (sub-range gating on 0xE0,
  0xED, 0xF0, 0xF4 lead bytes to reject overlong encodings,
  surrogates, and code points > U+10FFFF).

### Build

- paideia-as >= 0.21.0 required (same floor as every other
  user-space satellite in the paideia-os tree).
- `tools/build.sh` emits per-module `build-out/*.o` objects; no link
  step at M1 (downstream satellites link via `--extra-obj-dir`).
