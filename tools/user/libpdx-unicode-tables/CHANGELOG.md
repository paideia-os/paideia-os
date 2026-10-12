# Changelog -- libpdx-unicode-tables

All notable changes to this library are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) +
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.6.0] -- 2026-10-11

R131.M7 of the semantic-shell Unicode umbrella (paideia-os#2480,
decomposed into paideia-os#2618 for this M7).

### Added

- `src/locale.pdx` module `Locale`: BCP 47 locale registry
  substrate for the shell, pds, and the GPU-native terminal.
  - `_locale_parse(tag_ptr, tag_len) -> packed_u64` -- parses the
    strict `xx-YY` five-byte BCP 47 subset, canonicalises the
    language (lowercase) and region (uppercase) subtags, packs the
    four normalised bytes into a 4-byte key, dispatches over the
    seven keyed registry entries. Returns `(locale_id << 8) |
    status` with status in {0=OK, 1=UNKNOWN, 2=MALFORMED}. Pure
    leaf; no callee-save push.
  - `_locale_default() -> u64` -- returns 0 (C / POSIX). Pure leaf.
  - `_locale_direction(locale_id) -> u64` -- returns 1 (RTL) iff
    locale_id in {6, 7} (he-IL, ar-SA); 0 (LTR) otherwise, including
    every id outside the baseline registry. Pure leaf.
  - `_locale_width_ambiguous_is_wide(locale_id) -> u64` -- returns
    1 (wide) iff locale_id in {3, 4, 5} (ja-JP, zh-CN, ko-KR); 0
    (narrow) otherwise. Pure leaf.
  - Reduced locale registry at M7 (eight baseline entries):
    - id 0: C / POSIX (default) -- LTR, narrow-ambiguous.
    - id 1: en-US -- LTR, narrow-ambiguous.
    - id 2: en-GB -- LTR, narrow-ambiguous.
    - id 3: ja-JP -- LTR, wide-ambiguous.
    - id 4: zh-CN -- LTR, wide-ambiguous.
    - id 5: ko-KR -- LTR, wide-ambiguous.
    - id 6: he-IL -- RTL, narrow-ambiguous.
    - id 7: ar-SA -- RTL, narrow-ambiguous.
  - Parse semantics: strict 5-byte `xx-YY` only (length != 5 ->
    MALFORMED). Byte[2] separator gate: '_' (0x5F) is explicitly
    MALFORMED (surfaces the POSIX `en_US` style as a loud
    diagnostic); every non-'-' separator is MALFORMED. Case-
    insensitive via byte-level normalise before key compare. A
    well-formed 5-byte `xx-YY` with no registry hit is UNKNOWN
    (status=1, locale_id=0 -- caller falls back to default
    cleanly).
- `tests/fingerprints/locale.golden`: 5 TAG lines (LOC_PARSE_EN,
  LOC_PARSE_JA, LOC_PARSE_HE, LOC_PARSE_UNKNOWN, LOC_PARSE_MALFORMED)
  with byte-level walk-throughs documented in the file header.
  OUTPUT_HEX encodes the packed u64 return (16 nibbles big-endian).
- `tests/proptest_locale.pdx` module `ProptestLocale`: three
  invariant witnesses (default well-defined -- direction of default
  locale is LTR; parse idempotent -- two calls on the same input
  agree; direction totality -- every id in [0, 8) returns a
  direction in {0, 1}) plus umbrella `pl_run_all`; fail codes in
  the 0xFFFFEDDx band (extends the TestLexer / ProptestGrapheme /
  ProptestNormalize / ProptestCollation / ProptestWidth /
  ProptestBidi family).

### Changed

- `src/lib.pdx`: version bump 1.5.0 -> 1.6.0;
  `LPX_UNICODE_VERSION_MINOR` = 6; `LPX_UNICODE_M7_READY` = 1;
  `lpx_unicode_feature_level()` now returns 7. The per-milestone
  commentary in `lib.pdx` reflects the M7-promotes-up renumbering:
  locale registry took the M7 slot (was later in the earlier
  drafts) so the streaming decoder (now M8) and utf16 bridge (M9)
  slide down one.

### Error band

- 0xFFFFE770..0xFFFFE77F reserved for locale-layer error codes.
  Zero slots used at M7 (every status fits in the low 8 bits of
  the packed return). Jumps over the M5 slice
  (0xFFFFE750..0xFFFFE75F) and sits above the M6 slice
  (0xFFFFE760..0xFFFFE76F). Disjoint from the M1 (0xFFFFE700..0F),
  M2 (0xFFFFE710..1F), M3 (0xFFFFE720..2F), M4 (0xFFFFE730..3F),
  M5 (0xFFFFE750..5F), and M6 (0xFFFFE760..6F) slices and every
  other band in the paideia-os tree. Reserved for later locale-
  layer error kinds (LOCALE_TAG_TOO_LONG once length-flexible tags
  land at M7.2; LOCALE_REGISTRY_FULL if the registry becomes
  caller-populated at M7.5).

### BCP 47 scope (strict xx-YY five-byte baseline)

Phases IMPLEMENTED:

- Strict `language-REGION` parse with 2-letter language and 2-letter
  region, hyphen separator at byte offset 2.
- Case-insensitive subtag matching via byte-level lowercase /
  uppercase before key compare.
- Explicit MALFORMED on '_' separator (loud diagnostic for POSIX-
  style `en_US` input).
- Direction and ambiguous-width policy accessors for the eight-
  entry baseline registry.
- Status propagation (OK / UNKNOWN / MALFORMED) packed into the
  low 8 bits of the parser return, matching the
  `_norm_nf{c,d,kc,kd}` / `_coll_sort_key` / `_width_str` /
  `_bidi_runs` convention.

Phases STUBBED at M7 (land at M7.1+ follow-ups):

- Language-only parse (`en`, `ja`, `he`). M7.1 adds the 2-byte and
  3-byte prefix path; each language maps to its first-registry-match
  locale (en -> en-US, ja -> ja-JP, etc).
- 3-letter language codes (ISO 639-3, `iw-IL`-style legacy). M7.1
  target.
- Script subtag (`sr-Cyrl-RS`). M7.2 target.
- Variant subtags (`de-CH-1996`). M7.3 target.
- Extension subtags (`en-US-u-ca-gregory`). M7.3 target.
- Full locale axes (decimal separator, grouping separator,
  currency symbol, first-day-of-week, per-locale date / time
  patterns). M7.4+ target.
- Larger CLDR registry slice (es, fr, de, it, pt, ru, pl, nl, tr,
  vi, th, id, ms, hi, ...). M7.4 target.

### Build

- paideia-as >= 0.21.0 required (unchanged from M1..M6).
- `tools/build.sh` emits per-module `build-out/*.o` objects for
  `src/`, `tests/`, and `benches/`; no link step at M7 (downstream
  satellites link via `--extra-obj-dir`).

## [1.5.0] -- 2026-10-11

R131.M6 of the semantic-shell Unicode umbrella (paideia-os#2480,
decomposed into paideia-os#2617 for this M6).

### Added

- `src/bidi.pdx` module `Bidi`: UAX #9 (Unicode Bidirectional
  Algorithm) baseline run-level classifier over UTF-8.
  - `_bidi_class(cp) -> u64` -- maps a decoded code point to one of
    five reduced BIDI_CLASS values: 0 (L, Left-to-Right: ASCII
    letters, Latin-1 letters, Latin Extended-A/B), 1 (R,
    Right-to-Left: Hebrew, Arabic letters, Arabic Presentation
    Forms-A), 2 (N, Neutral / default fallback), 3 (AN, Arabic
    Number: Arabic-Indic and extended Arabic-Indic digits), 4 (EN,
    European Number: ASCII digits). Pure leaf classifier.
  - `_bidi_runs(bytes_ptr, bytes_len, out_runs_ptr, out_cap)
    -> packed_u64` -- iterates grapheme clusters via `_gc_next`,
    classifies first cp of each cluster, groups consecutive same-
    class clusters into monotone runs. Writes 16-byte run entries
    `{byte_start u32 LE, byte_end u32 LE, class u8, pad u8[7]}` to
    `out_runs_ptr`. Return shape `(runs_emitted << 32) | status`
    with status in {0=OK, 1=OUT_TOO_SMALL, 2=INVALID_UTF8}.
  - Reduced BIDI_CLASS scope at M6:
    - L (0): U+0041..U+005A, U+0061..U+007A (ASCII letters);
      U+00C0..U+00FF (Latin-1 Supplement letters, folds U+00D7/U+00F7
      into L); U+0100..U+024F (Latin Extended-A + Latin Extended-B).
    - R (1): U+0590..U+05FF (Hebrew entire block, folds cantillation
      marks into R); U+0600..U+06FF Arabic block except digits;
      U+FB50..U+FDFF (Arabic Presentation Forms-A).
    - AN (3): U+0660..U+0669 (Arabic-Indic digits);
      U+06F0..U+06F9 (Extended Arabic-Indic digits). Peeled from the
      Arabic R block before the generic Arabic range check fires.
    - EN (4): U+0030..U+0039 (ASCII digits).
    - N (2): everything else (default fallback) -- ASCII space,
      punctuation, Greek, Cyrillic, CJK, emoji, combining marks
      outside Hebrew / Arabic, control characters, and every
      supplementary-plane cp.
  - Aggregator semantics: OUT_TOO_SMALL commits PARTIAL output
    (caller may resume from the last committed run's byte_end).
    INVALID_UTF8 DISCARDS the current open run (invariant: emitted
    runs always end at a valid cluster boundary).
- `tests/fingerprints/bidi.golden`: 8 TAG lines (BIDI_PURE_LTR,
  BIDI_PURE_RTL, BIDI_MIXED, BIDI_NUMBER, BIDI_ARABIC_DIGITS,
  BIDI_NEUTRAL, BIDI_EMPTY, BIDI_SINGLE_L) with byte-level walk-
  throughs documented in the file header. OUTPUT_HEX encodes the
  concatenated 16-byte run entries (32 hex nibbles per run) rather
  than the packed u64 return, giving the fingerprint maximal
  discriminative power on each case's run array.
- `tests/proptest_bidi.pdx` module `ProptestBidi`: three invariant
  witnesses (coverage of [0, bytes_len) with no gaps/overlaps,
  non-empty runs, monotone class between consecutive runs) plus
  umbrella `pb_run_all`; fail codes in the 0xFFFFEDCx band (extends
  the TestLexer / ProptestGrapheme / ProptestNormalize /
  ProptestCollation / ProptestWidth family, skips the VKBench
  (EDAx) and VKFeatures (EDBx) kernel bands).

### Changed

- `src/lib.pdx`: version bump 1.4.0 -> 1.5.0;
  `LPX_UNICODE_VERSION_MINOR` = 5; `LPX_UNICODE_M6_READY` = 1;
  `lpx_unicode_feature_level()` now returns 6. The per-milestone
  commentary in `lib.pdx` reflects the M6-promotes-up renumbering:
  bidi runs took the M6 slot (was later in the earlier drafts) so
  the streaming decoder (now M7), utf16 bridge (M8), and stream
  validators (M9) slide down one.

### Error band

- 0xFFFFE760..0xFFFFE76F reserved for bidi-layer error codes
  (two used at M6: `BIDI_INVALID_UTF8` = 0xFFFFE760,
  `BIDI_OUT_TOO_SMALL` = 0xFFFFE761). Jumps over the M5 slice
  (0xFFFFE750..0xFFFFE75F). Disjoint from the M1 (0xFFFFE700..0F),
  M2 (0xFFFFE710..1F), M3 (0xFFFFE720..2F), M4 (0xFFFFE730..3F),
  and M5 (0xFFFFE750..5F) slices and every other band in the
  paideia-os tree. The public API return packs the status code
  (0=OK, 1=OUT_TOO_SMALL, 2=INVALID_UTF8) into the low 8 bits of
  the packed result rather than returning the raw band value,
  matching the _norm_nfX / _coll_sort_key / _width_str convention.

### UAX #9 scope (Rev. 48 reduced-five-class baseline)

Phases IMPLEMENTED:

- Per-cp classification over the four strong-direction / number
  classes above (L, R, AN, EN) with N as default fallback.
- Per-cluster aggregation via `_gc_next` + first-cp classification.
- Monotone run grouping (consecutive same-class clusters coalesce;
  class change triggers a run boundary).
- Status propagation (OK, OUT_TOO_SMALL, INVALID_UTF8) matching the
  rest of the library's packed-return convention.

Phases STUBBED at M6 (land at M6.1+ follow-ups):

- Full 23-class BIDI_CLASS split. The current five-class reduction
  is enough for Latin + Arabic + Hebrew runs but not for the per-
  paragraph reordering TR#9 §3.3 defines (AL distinct from R, NSM
  carved out of Hebrew/Arabic, ES/ET/CS for European number
  clustering, ON for brackets and math, WS/BN/B/S for whitespace
  and separators). M6.1 target.
- Paragraph-level resolution (TR#9 §P1). First-strong-character
  algorithm determining sot direction is NOT implemented; the
  caller can approximate by inspecting the first non-N run. M6.2
  target.
- Explicit directional embeddings (LRE / RLE / LRO / RLO / PDF /
  LRI / RLI / FSI / PDI, TR#9 §3.3.2). Treated as N at M6; rare in
  terminal input today. M6.3 target.
- Mirroring pairs (TR#9 §3.4). Brackets and paired characters that
  mirror inside an RTL run. Needs UCD BidiMirroring.txt. M6.4
  target.

### Build

- paideia-as >= 0.21.0 required (unchanged from M1 / M2 / M3 / M4
  / M5).
- `tools/build.sh` emits per-module `build-out/*.o` objects for
  `src/`, `tests/`, and `benches/`; no link step at M6 (downstream
  satellites link via `--extra-obj-dir`).

## [1.4.0] -- 2026-10-11

R131.M5 of the semantic-shell Unicode umbrella (paideia-os#2480,
decomposed into paideia-os#2616 for this M5).

### Added

- `src/width.pdx` module `Width`: UAX #11 (East Asian Width) baseline
  display-width classifier over UTF-8.
  - `_width_char(cp) -> u64` -- 0 (zero-width mark / control), 1
    (narrow default), or 2 (wide East Asian / emoji). Pure leaf
    classifier.
  - `_width_str(bytes_ptr, bytes_len) -> packed_u64` -- iterates
    grapheme clusters via `_gc_next`, decodes the base cp of each
    cluster via `utf8_decode_cp`, calls `_width_char` on the base,
    and accumulates per-cluster widths. Return shape
    `(total_width << 32) | status` with status in {0=OK,
    2=INVALID_UTF8}.
  - Reduced EAW scope at M5:
    - Width 0: C0 controls (U+0000..001F), DEL + C1 controls
      (U+007F..009F), Latin combining diacritics (U+0300..036F),
      ZWJ (U+200D), Variation Selectors (U+FE00..FE0F).
    - Width 2: CJK Symbols/Punctuation (U+3000..303E),
      Hiragana/Katakana (U+3041..30FF), CJK Unified Ext-A
      (U+3400..4DBF), CJK Unified (U+4E00..9FFF), Hangul Syllables
      (U+AC00..D7A3), CJK Compat (U+F900..FAFF), Fullwidth ASCII
      (U+FF01..FF60), Fullwidth signs (U+FFE0..FFE6), Emoji
      single-range (U+1F300..1F9FF, same range the M2 Grapheme
      classifier uses for PICTOGRAPHIC).
    - Width 1: everything else (narrow default).
  - Ambiguous width (UAX #11 class A) is treated as NARROW at the
    M5 baseline. Locale-sensitive handling (East Asian locales
    widen Ambiguous to 2) lands at M5.1 via a second entry point
    `_width_char_lc(cp, locale)`.
- `tests/fingerprints/width.golden`: 8 TAG lines (W_ASCII, W_CJK,
  W_FULLWIDTH, W_COMBINING, W_EMOJI, W_MIXED, W_EMPTY, W_CONTROL)
  with byte-level walk-throughs documented in the file header.
- `tests/proptest_width.pdx` module `ProptestWidth`: three invariant
  witnesses (non-negative width + status, additive-under-ASCII-
  concatenation, zero-input returns zero) plus umbrella
  `pw_run_all`; fail codes in the 0xFFFFED9x band (extends the
  TestLexer / ProptestGrapheme / ProptestNormalize /
  ProptestCollation family).

### Changed

- `src/lib.pdx`: version bump 1.3.0 -> 1.4.0;
  `LPX_UNICODE_VERSION_MINOR` = 4; `LPX_UNICODE_M5_READY` = 1;
  `lpx_unicode_feature_level()` now returns 5. The per-milestone
  commentary in `lib.pdx` reflects the M5-promotes-up renumbering:
  display width took the M5 slot (was later in the M2/M3/M4 drafts)
  so the streaming decoder (now M6), utf16 bridge (M7), and stream
  validators (M8) slide down one.

### Error band

- 0xFFFFE750..0xFFFFE75F reserved for width-layer error codes
  (one used at M5: `W_INVALID_UTF8` = 0xFFFFE750). Skips
  0xFFFFE740..0xFFFFE74F which is already claimed by the
  adaptive_rate sample's policy module (G9.M6). Disjoint from
  the M1 (0xFFFFE700..0F), M2 (0xFFFFE710..1F), M3 (0xFFFFE720..2F)
  and M4 (0xFFFFE730..3F) slices and every other band in the
  paideia-os tree. The public API return packs the status code
  (0=OK, 2=INVALID_UTF8) into the low 8 bits of the packed result
  rather than returning the raw band value, matching the
  _norm_nfX / _coll_sort_key / _gc_next convention.

### UAX #11 scope (Rev. 36 reduced-CJK+emoji baseline)

Phases IMPLEMENTED:

- Per-cp classification over the width-0 and width-2 ranges above.
- Per-cluster accumulation via `_gc_next` seed-and-sum.
- Status propagation (OK, INVALID_UTF8) matching the rest of the
  library's packed-return convention.

Phases STUBBED at M5 (land at M5.1+ follow-ups):

- Locale-sensitive Ambiguous handling. The baseline treats every
  Ambiguous cp as narrow; East Asian locales (ja, ko, zh) widen
  these to 2. M5.1 adds `_width_char_lc(cp, locale) -> u64` and a
  small locale constant table.
- Full UCD EastAsianWidth.txt load. Replaces the hand-coded range
  table in `_width_char` with a trie or sorted range lookup. The
  current CJK+emoji baseline covers every consumer site in the
  paideia-os tree today; a sparser-trie landing is M5.2 work.
- Extended_Pictographic trie (sparse, ~1500 cps) replacing the
  single-range approximation at U+1F300..U+1F9FF. Lands alongside
  M2.2's trie for the Grapheme classifier (shared data source).
- Hangul Jamo (U+1100..U+11FF). L (leading consonant) and V (vowel)
  are wide=2 at TR#11 even when standalone (not composed into a
  syllable); T (trailing) is narrow. M5.4 wires this.
- Scripts explicitly deferred to M5.2+: Myanmar (U+1000..109F),
  Khmer (U+1780..17FF), Tibetan (U+0F00..0FFF), Mongolian
  (U+1800..18AF), and other complex-shaping BMP scripts that have
  mixed width classes in the full UCD.

### Build

- paideia-as >= 0.21.0 required (unchanged from M1 / M2 / M3 / M4).
- `tools/build.sh` emits per-module `build-out/*.o` objects for
  `src/`, `tests/`, and `benches/`; no link step at M5 (downstream
  satellites link via `--extra-obj-dir`).

## [1.3.0] -- 2026-10-11

R131.M4 of the semantic-shell Unicode umbrella (paideia-os#2480,
decomposed into paideia-os#2615 for this M4).

### Added

- `src/collation.pdx` module `Collation`: UTS #10 Unicode Collation
  Algorithm (UCA) baseline over NFD-normalised UTF-8.
  - `_coll_compare(a_ptr, a_len, b_ptr, b_len) -> i64` -- lexicographic
    comparison by UCA sort key under the reduced DUCET. Returns -1
    (0xFFFFFFFFFFFFFFFF), 0, or 1.
  - `_coll_sort_key(bytes_ptr, bytes_len, out_ptr, out_cap)
    -> packed_u64` -- materialises a UCA sort key suitable for
    byte-wise memcmp. Return shape `(out_bytes << 32) | status`
    with status in {0=OK, 1=OUT_TOO_SMALL, 2=INVALID_UTF8}.
  - Internal helpers (also `pub` for the proptest's benefit):
    `_coll_lookup_mark`, `_coll_classify`, `_coll_build_ces`,
    `_coll_emit_key`, `_coll_keycmp`.
  - Reduced DUCET scope at M4:
    - ASCII printable U+0020..U+007E: algorithmic L1 bands
      (space / punct1-4 / digit / letter) with L2=0x0020 default
      and L3=0x0002 (lower) or L3=0x0008 (upper).
    - Combining marks U+0300..U+036F: 13 explicit (cp, L2) pairs
      covering every mark in the normalize module's canonical
      decomposition set; default L2=0x0040 for unlisted marks.
    - Latin-1 Supplement U+00A0..U+00FF and Latin Ext-A U+0100..
      U+017F non-decomposing cps: algorithmic fallback L1 bands
      placed strictly above every ASCII letter. (Decomposing cps
      never reach the classifier because the pipeline runs NFD
      first; they appear as base + mark pairs.)
  - Four .bss scratch buffers: `_coll_nfd_scratch` (4096 B),
    `_coll_ce_scratch` (8192 B, 1024 CEs x 8 B), `_coll_key_a_scratch`
    (8192 B), `_coll_key_b_scratch` (8192 B). Single-threaded by
    construction.
- `tests/fingerprints/collation.golden`: 8 TAG lines covering six
  CMP cases (AB, BA, AA, a_vs_A, a_vs_aacute, cafe_vs_café) and two
  KEY cases (KEY_a, KEY_empty). Walk-throughs documented in the
  file header show how each byte of the key is derived from the
  CE triplets.
- `tests/proptest_collation.pdx` module `ProptestCollation`: four
  invariant witnesses (reflexivity, antisymmetry, transitivity,
  sort-key correctness) plus umbrella `pnc_run_all`; fail codes in
  the 0xFFFFED8x band (extends the existing TestLexer /
  ProptestGrapheme / ProptestNormalize band family).

### Changed

- `src/lib.pdx`: version bump 1.2.0 -> 1.3.0;
  `LPX_UNICODE_VERSION_MINOR` = 3; `LPX_UNICODE_M4_READY` = 1;
  `lpx_unicode_feature_level()` now returns 4. The per-milestone
  commentary in `lib.pdx` reflects the M4-promotes-up renumbering:
  UCA collation took the M4 slot (was later in the M2/M3 drafts)
  so the streaming decoder (now M5), utf16 bridge (M6), and stream
  validators (M7) slide down one.

### Error band

- 0xFFFFE730..0xFFFFE73F reserved for collation-layer error codes
  (two used at M4: `COLL_INVALID_UTF8` = 0xFFFFE730,
  `COLL_OUT_TOO_SMALL` = 0xFFFFE731). Disjoint from the M1
  (0xFFFFE700..0F), M2 (0xFFFFE710..1F), M3 (0xFFFFE720..2F)
  slices and every other band in the paideia-os tree. The public
  API return packs the status code into the low 8 bits (0..2)
  rather than returning the raw band value, matching the
  _norm_nfX / _gc_next-style packed convention from M2/M3.

### UCA scope (UTS #10 Rev. 46 reduced-ASCII+Latin-combining baseline)

Phases IMPLEMENTED:

- Normalisation to NFD (via M3's `_norm_nfd`).
- Collation element construction (one CE per code point; no
  contractions or expansions at M4; algorithmic per-range
  classification + sparse mark-table lookup).
- Sort-key formation (three-level stream, big-endian u16 weights,
  0x0000 separator between levels, no trailing separator after L3).
- Byte-wise memcmp of sort keys with shorter-wins tiebreaker.

Phases STUBBED at M4 (land at M4.1+ follow-ups):

- CJK Unified Ideographs: need DUCET implicit-weight algorithm
  (TR#10 §10) or the pinyin/radical-stroke tailoring. M4.2 target.
- Hangul (Jamos U+1100..U+11FF, Syllables U+AC00..U+D7A3):
  TR#10 §7.1.5 per-Hangul weighting. M4.2 target.
- Bidi/RTL scripts (Arabic U+0600..U+06FF + presentation forms,
  Hebrew U+0590..U+05FF): currently fall into the generic Latin-
  Ext-and-above fallback. M4.3 target.
- Complex-shaping scripts (Devanagari U+0900..U+097F, Thai
  U+0E00..U+0E7F, etc.): same posture as bidi; M4.3 target.
- Locale tailorings (CLDR root -> per-locale deltas, e.g. Swedish
  á after z): the baseline is DUCET root collation only. M4.4
  target.
- Variable weighting (L4 for whitespace/punctuation):
  shifted/blanked/non-ignorable variants deferred. M4.3 target.
- Case level (L2.5): case folded into L3 at M4; a separate
  fine-grain case level is M4.4.
- Many-to-one contractions and one-to-many expansions in the
  DUCET: baseline is one-cp-one-CE. M4.1 lands these.

### Build

- paideia-as >= 0.21.0 required (unchanged from M1 / M2 / M3).
- `tools/build.sh` emits per-module `build-out/*.o` objects for
  `src/`, `tests/`, and `benches/`; no link step at M4 (downstream
  satellites link via `--extra-obj-dir`).

## [1.2.0] -- 2026-10-11

R131.M3 of the semantic-shell Unicode umbrella (paideia-os#2480,
decomposed into paideia-os#2614 for this M3).

### Added

- `src/normalize.pdx` module `Normalize`: UAX #15 Unicode
  Normalization Forms (NFC, NFD, NFKC, NFKD) over UTF-8.
  - `_norm_nfd(bytes_ptr, bytes_len, out_ptr, out_cap)
    -> packed_u64` -- canonical decomposition only.
  - `_norm_nfkd(bytes_ptr, bytes_len, out_ptr, out_cap)
    -> packed_u64` -- compatibility decomposition only.
  - `_norm_nfc(bytes_ptr, bytes_len, out_ptr, out_cap)
    -> packed_u64` -- canonical decomposition then composition.
  - `_norm_nfkc(bytes_ptr, bytes_len, out_ptr, out_cap)
    -> packed_u64` -- compatibility decomposition then
    composition.
  - Return shape `(out_bytes << 32) | status` with status in
    {0=OK, 1=OUT_TOO_SMALL, 2=INVALID_UTF8}.
  - Internal helpers (also `pub` for the proptest's benefit):
    `_norm_lookup_decomp`, `_norm_lookup_ccc`,
    `_norm_lookup_compose`, `_norm_decompose`,
    `_norm_sort_scratch`, `_norm_compose_scratch`,
    `_norm_encode_scratch`, `_norm_core`.
  - Reduced UCD scope at M3: Latin-1 Supplement (U+00C0..00FF)
    canonical decompositions, Latin Extended-A (U+0100..017F)
    canonical decompositions, Fullwidth-ASCII (U+FF01..FF5E)
    compatibility decompositions. Composition_Exclusions empty.
  - Static .bss scratch buffer `_norm_scratch` (8192 bytes, 1024
    entries x 8 bytes). Single-threaded by construction.
- `tests/fingerprints/normalize.golden`: 8 TAG lines covering
  the four forms and the four decomposition / composition /
  idempotence / passthrough shapes (NFC_A_ACUTE, NFD_A_ACUTE_
  PRECOMPOSED, NFKC_FULLWIDTH, NFKD_FULLWIDTH, NFC_IDEMPOTENT,
  NFD_EMPTY, NFC_MULTIPLE, NFC_PASSTHROUGH).
- `tests/proptest_normalize.pdx` module `ProptestNormalize`:
  four invariant witnesses (idempotence, round-trip,
  UTF-8 validity, length bound) plus umbrella `pnm_run_all`;
  fail codes in the 0xFFFFED7x band (extends the existing
  TestLexer / ProptestGrapheme band family).

### Changed

- `src/lib.pdx`: version bump 1.1.0 -> 1.2.0;
  `LPX_UNICODE_VERSION_MINOR` = 2; `LPX_UNICODE_M3_READY` = 1;
  `lpx_unicode_feature_level()` now returns 3. The per-milestone
  commentary in `lib.pdx` reflects the M3-promotes-up renumbering:
  normalization took the M3 slot (was M6 in the M2 draft) so the
  streaming decoder (now M4), utf16 bridge (M5), and stream
  validators (M6) slide down one.

### Error band

- 0xFFFFE720..0xFFFFE72F reserved for normalize-layer error codes
  (two used at M3: `NORM_INVALID_UTF8_CODE` = 0xFFFFE720,
  `NORM_OUT_TOO_SMALL_CODE` = 0xFFFFE721). Disjoint from the M1
  (0xFFFFE700..0F) and M2 (0xFFFFE710..1F) slices and every other
  band in the paideia-os tree. The public API return packs the
  status code into the low 8 bits (0..2) rather than returning
  the raw band value, matching the `_gc_next`-style packed
  convention from M2.

### UAX #15 scope (Rev 55 reduced-Latin+fullwidth baseline)

Phases IMPLEMENTED:

- Decomposition (canonical + compatibility, table-driven for the
  Latin + fullwidth baseline above).
- Canonical ordering (TR#15 §12 bubble sort within non-starter
  runs by CCC; starters terminate a run).
- Composition (TR#15 §13 reduced: left-to-right single pass over
  (starter, non-starter) pairs via composition-table lookup;
  Composition_Exclusions treated as empty).
- Encode back to UTF-8 (via `utf8_encode_cp`, atomic
  all-or-nothing on buffer underrun).

Phases STUBBED at M3 (land at M3.1+ follow-ups):

- Multi-level decomposition recursion (Latin Extended-B and
  beyond, when a precomposed form decomposes through another
  precomposed form). Current table encodes fully-decomposed
  entries so the decomposer stays single-level.
- Hangul syllable decomposition / composition (TR#15 §16
  algorithmic path, not table-driven; needs L/V/T math).
- Composition_Exclusions non-empty set.
- CCC values beyond the sparse ~10-entry Latin baseline + 230
  default for marks in U+0300..036F.

### Build

- paideia-as >= 0.21.0 required (unchanged from M1 / M2).
- `tools/build.sh` emits per-module `build-out/*.o` objects for
  `src/`, `tests/`, and `benches/`; no link step at M3 (downstream
  satellites link via `--extra-obj-dir`).

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
