# libpdx-unicode-tables -- status

**Wave:** R131 (semantic shell -- Unicode substrate umbrella,
paideia-os#2480)
**Current milestone:** M8 (IPC-boundary NFC hook) -- landed.
**Version:** 1.7.0.

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

### M3 -- NFC/NFD/NFKC/NFKD normalization (paideia-os#2614, landed)

- [x] **M3-001** -- `src/normalize.pdx` scaffold + module `Normalize`,
      status / error / form-flag constants, scratch-buffer .bss
      allocation (1024 x 8-byte entries), decomposition table
      (255 entries x 3 u32 = 765 u32), CCC table (10 pairs x 2
      u32 = 20 u32).
- [x] **M3-002** -- `_norm_lookup_decomp(cp, use_compat) -> packed`
      real body: landed. Linear scan with pointer advance (stride
      12 bytes); early-exit on `table_cp > query`; `mark==0`
      entries are skipped on canonical lookups and surfaced on
      compat lookups.
- [x] **M3-003** -- `_norm_lookup_ccc(cp) -> ccc` real body:
      landed. Range-gate on U+0300..U+036F; linear scan of the
      sparse `_norm_ccc_table`; default 230 for marks not
      explicitly listed.
- [x] **M3-004** -- `_norm_lookup_compose(part0, part1) -> cp`
      real body: landed. Scans the canonical half of the decomp
      table (mark != 0 only); returns the precomposed cp when
      (part0, part1) matches an entry's (base, mark).
- [x] **M3-005** -- `_norm_decompose(src_ptr, src_len, use_compat)
      -> packed` real body: landed. Walks the input via
      `utf8_decode_cp`; for each cp looks up the (compat or
      canonical) decomposition and emits (cp, ccc) scratch
      entries; one-level decomposition (the table encodes
      fully-decomposed forms); scratch-overflow and UTF-8-error
      exits.
- [x] **M3-006** -- `_norm_sort_scratch(count) -> ()` real body:
      landed. Bubble sort within non-starter runs by CCC;
      starters terminate a run (TR#15 §12 Canonical Ordering
      Algorithm).
- [x] **M3-007** -- `_norm_compose_scratch(count) -> new_count`
      real body: landed. Left-to-right single-pass walk;
      (starter, non-starter) pairs reduced via
      `_norm_lookup_compose`; tombstone + compact pass at the
      end (TR#15 §13 Canonical Composition Algorithm reduced).
- [x] **M3-008** -- `_norm_encode_scratch(count, out_ptr, out_cap)
      -> packed` real body: landed. Walks scratch, emits each
      non-tombstoned cp via `utf8_encode_cp`; buffer-underrun
      returns status=1 (OUT_TOO_SMALL) with out_bytes=0 (atomic
      failure).
- [x] **M3-009** -- `_norm_core(form_flag, ...)` dispatcher +
      four public wrappers (`_norm_nfd`, `_norm_nfkd`,
      `_norm_nfc`, `_norm_nfkc`) landed. form_flag bit 0 = compat,
      bit 1 = compose.
- [x] **M3-010** -- Fingerprint goldens:
      `tests/fingerprints/normalize.golden` with 8 TAG lines
      (NFC_A_ACUTE, NFD_A_ACUTE_PRECOMPOSED, NFKC_FULLWIDTH,
      NFKD_FULLWIDTH, NFC_IDEMPOTENT, NFD_EMPTY, NFC_MULTIPLE,
      NFC_PASSTHROUGH).
- [x] **M3-011** -- Proptest witnesses:
      `tests/proptest_normalize.pdx` module `ProptestNormalize`
      with 4 invariants (idempotence, round-trip, UTF-8 validity,
      length bound) and umbrella `pnm_run_all`.

**M3 limitations (reduced UCD scope; follow-ups filed for M3.1+):**

- Canonical decomposition table carries ONLY Latin-1 Supplement
  (U+00C0..U+00FF) and Latin Extended-A (U+0100..U+017F); every
  entry is encoded in a single level (no two-level decomp
  recursion is wired, so Latin Extended-B precomposed forms that
  decompose through Latin-1 Supplement are not landed yet).
- Compatibility decomposition table carries ONLY fullwidth-ASCII
  (U+FF01..U+FF5E). Other NFKD-relevant blocks are deferred:
  compatibility ideographs, Arabic presentation forms,
  CJK Compatibility, Hangul fullwidth, Mathematical Alphanumeric
  symbols.
- Composition_Exclusions table is EMPTY. In the full UCD this is
  non-empty (singleton + non-starter decompositions, script-specific
  pairs); M3.2 lands the full list.
- CCC table carries only ~10 explicit entries plus a default of
  230 for anything in U+0300..U+036F not listed. The real UCD
  CCC assignments include 1 (overlay), 7 (nukta), 8 (hiragana
  voicing), 9 (virama), 10..199 (fixed classes), 200..240
  (reorder targets, iota subscript); M3.1 lands the full set.
- Scripts explicitly deferred to M3.2+: Devanagari (U+0900..097F),
  Hebrew (U+0590..05FF), Arabic (U+0600..06FF + presentation forms
  U+FB50..FDFF, U+FE70..FEFF), CJK Compatibility (U+F900..FAFF,
  U+2F800..2FA1F), Hangul syllables (U+AC00..D7A3) which TR#15
  §16 defines algorithmically rather than by table.
- Scratch buffer is static .bss (`_norm_scratch`, 8192 bytes).
  Overlapping calls -- including a signal handler mid-normalise
  -- corrupt the intermediate representation. The library is
  single-threaded by design; M3.3+ moves the scratch to a
  caller-supplied workspace argument.

### M4 -- UCA collation (paideia-os#2615, landed)

- [x] **M4-001** -- `src/collation.pdx` scaffold + module `Collation`,
      status / error-band / weight constants, four scratch buffers
      in .bss (NFD 4096 B, CE 8192 B = 1024 x 8-byte entries, two
      key-scratch buffers 8192 B each), 13-entry mark L2 table.
- [x] **M4-002** -- `_coll_lookup_mark(cp) -> L2` real body: landed.
      Linear scan over the 13-entry mark table at stride 8 bytes;
      returns `COLL_L2_MARK_DEFAULT` (0x0040) for unlisted marks in
      U+0300..U+036F.
- [x] **M4-003** -- `_coll_classify(cp) -> packed` real body:
      landed. Range tree over the ASCII bands (space, punct1-4,
      digits, letters-upper, letters-lower), combining-mark lookup
      (U+0300..U+036F), Latin-1 / Latin-Ext-A fallback bands,
      above-marks fallback. Packs (L1 << 32) | (L2 << 16) | L3.
- [x] **M4-004** -- `_coll_build_ces(src_ptr, src_len) -> packed`
      real body: landed. Walks UTF-8 bytes via `utf8_decode_cp`;
      for each cp calls `_coll_classify` and writes the packed CE
      qword to `_coll_ce_scratch[count]`. CE-array overflow at
      1024 entries returns status=1; UTF-8 error returns status=2.
- [x] **M4-005** -- `_coll_emit_key(count, out_ptr, out_cap)
      -> packed` real body: landed. Three level streams (L1/L2/L3)
      separated by u16 0x0000 sentinels; per-byte capacity gate;
      atomic failure on buffer underrun.
- [x] **M4-006** -- `_coll_sort_key(bytes_ptr, bytes_len, out_ptr,
      out_cap) -> packed` public entry point: landed. Driver:
      NFD -> build CEs -> emit key. Empty input returns status=0,
      0 bytes.
- [x] **M4-007** -- `_coll_keycmp(a_ptr, a_len, b_ptr, b_len)
      -> i64` real body: landed. Byte-wise memcmp with shorter-
      wins tiebreaker; returns -1 (via `xor rax,rax; sub rax,1`),
      0, or 1.
- [x] **M4-008** -- `_coll_compare(a_ptr, a_len, b_ptr, b_len)
      -> i64` public entry point: landed. Materialises both sort
      keys into the two compare-local scratch buffers, then calls
      `_coll_keycmp`. UTF-8 or OUT_TOO_SMALL on either input
      zeros that side's key length (treat as empty, don't crash).
- [x] **M4-009** -- Fingerprint goldens:
      `tests/fingerprints/collation.golden` with 8 TAG lines
      (CMP_AB, CMP_BA, CMP_AA, CMP_a_vs_A, CMP_a_vs_aacute,
      CMP_cafe_vs_café, KEY_a, KEY_empty).
- [x] **M4-010** -- Proptest witnesses:
      `tests/proptest_collation.pdx` module `ProptestCollation`
      with 4 invariants (reflexivity, antisymmetry, transitivity,
      sort-key correctness) and umbrella `pnc_run_all`.

**M4 limitations (reduced DUCET scope; follow-ups filed for M4.1+):**

- The reduced DUCET encoded in `collation.pdx` covers ONLY the
  printable ASCII range U+0020..U+007E (algorithmic weight bands)
  and the 13 explicit combining marks in `_coll_mark_table`
  (U+0300..U+036F); every other code point falls into one of
  four fallback bands (Latin-1 Supp, Latin Ext-A, high-fallback,
  above-marks). CJK (U+4E00..U+9FFF etc), Hangul (U+1100..,
  U+AC00..), Arabic (U+0600..), Hebrew (U+0590..), Devanagari
  (U+0900..), Thai (U+0E00..), and every other script are
  EXPLICITLY DEFERRED to M4.2+ follow-ups.
- Contractions (many-cp -> one CE) and expansions (one-cp -> many
  CEs) are NOT implemented; the baseline is strict one-cp-one-CE.
  M4.1 lands these.
- Composition_Exclusions handling in the NFD phase inherits M3's
  posture (empty set); non-empty exclusions land at M3.2 before
  M4 can take advantage of them.
- Variable weighting (L4 for whitespace / punctuation --
  shifted/blanked/non-ignorable variants) is NOT implemented.
  M4.3 target.
- Case level (L2.5): case information is folded into L3 at M4;
  a separate fine-grain case level is M4.4.
- Locale tailorings (CLDR root -> per-locale, e.g. Swedish á
  after z, German sharp s expansion to "ss") NOT implemented.
  M4.4 target.
- Scratch buffers are static .bss (`_coll_nfd_scratch`,
  `_coll_ce_scratch`, `_coll_key_a_scratch`, `_coll_key_b_scratch`,
  28 KiB total). Overlapping calls -- including a signal handler
  interrupting mid-compare -- corrupt the intermediate
  representation. The library is single-threaded by design;
  M4.5+ moves scratch to caller-supplied workspace arguments.
- UTF-8 or OUT_TOO_SMALL on EITHER input to `_coll_compare`
  treats that side as empty (no crash), orderable but silent.
  Fail-fast callers should run `utf8_is_valid` first.

### M5 -- Display width (paideia-os#2616, landed)

- [x] **M5-001** -- `src/width.pdx` scaffold + module `Width`, status
      constants (W_STATUS_OK=0, W_STATUS_INVALID_UTF8=2), error-band
      slice 0xFFFFE740..0xFFFFE74F (first slot used: `W_INVALID_UTF8`
      at 0xFFFFE740).
- [x] **M5-002** -- `_width_char(cp) -> u64` real body: landed.
      Straight-line range-dispatch classifier returning 0 (zero-width:
      C0 controls, C1 controls + DEL, Latin combining U+0300..036F,
      ZWJ U+200D, Variation Selectors U+FE00..FE0F), 2 (wide: nine
      CJK + Hangul + fullwidth + emoji bands), or 1 (narrow default).
      Pure leaf; no callee-save push.
- [x] **M5-003** -- `_width_str(bytes_ptr, bytes_len) -> packed_u64`
      real body: landed. Walks the input one grapheme cluster at a
      time via `_gc_next`, decodes the base cp of each cluster via
      `utf8_decode_cp`, calls `_width_char` on the base, accumulates
      in r14. Packed return `(total_width << 32) | status` with
      status in {0=OK, 2=INVALID_UTF8}. INVALID propagates the
      partial accumulator alongside status=2.
- [x] **M5-004** -- Fingerprint goldens: `tests/fingerprints/width.golden`
      with 8 TAG lines (W_ASCII, W_CJK, W_FULLWIDTH, W_COMBINING,
      W_EMOJI, W_MIXED, W_EMPTY, W_CONTROL).
- [x] **M5-005** -- Proptest witnesses:
      `tests/proptest_width.pdx` with 3 invariants (non-negative +
      status-OK on ASCII, additive-under-concatenation for ASCII,
      zero-input returns zero) and umbrella `pw_run_all`.
- [x] **M5-006** -- Design doc:
      `design/toolchain/libpdx-unicode-width.md`.

**M5 limitations (stubbed; tracked for M5.1+ follow-up tickets):**

- UAX #11 Ambiguous class (A) is treated as narrow. Locale-aware
  widening to 2 under East Asian locales lands at M5.1 via
  `_width_char_lc(cp, locale)` plus a locale constant table.
- Full UCD EastAsianWidth.txt load. The current hand-coded range
  table covers CJK + Hangul syllables + fullwidth + the emoji
  supplement blocks (U+1F300..1F9FF) but is NOT the ~140k-cp
  EastAsianWidth.txt. Myanmar, Khmer, Tibetan, Mongolian and
  other complex-shaping BMP scripts are deferred to M5.2.
- Extended_Pictographic approximated as the single range
  U+1F300..U+1F9FF (same approximation M2 Grapheme uses for
  PICTOGRAPHIC); a sparser-trie landing is M5.3 work.
- Hangul Jamo (U+1100..U+11FF, standalone L/V/T not composed into
  a syllable): currently narrow. TR#11 §5 widens L and V to 2
  independently of their syllable role. M5.4 target.

### M6 -- Bidi runs (paideia-os#2617, landed)

- [x] **M6-001** -- `src/bidi.pdx` scaffold + module `Bidi`, five
      BIDI_CLASS constants (L=0, R=1, N=2, AN=3, EN=4), three status
      codes (BIDI_STATUS_OK=0, BIDI_STATUS_OUT_TOO_SMALL=1,
      BIDI_STATUS_INVALID_UTF8=2), error-band slice
      0xFFFFE760..0xFFFFE76F (two slots used: `BIDI_INVALID_UTF8` at
      0xFFFFE760, `BIDI_OUT_TOO_SMALL` at 0xFFFFE761).
- [x] **M6-002** -- `_bidi_class(cp) -> u64` real body: landed.
      Straight-line range-dispatch classifier returning 0 (L: ASCII
      letters, Latin-1 letters U+00C0..00FF, Latin Ext-A/B
      U+0100..024F), 1 (R: Hebrew U+0590..05FF, Arabic U+0600..06FF
      except digits, Arabic Pres Forms-A U+FB50..FDFF), 2 (N: default
      fallback), 3 (AN: Arabic-Indic digits U+0660..0669 and extended
      U+06F0..06F9, peeled before the generic Arabic R range), 4
      (EN: ASCII digits U+0030..0039). Pure leaf; no callee-save push.
- [x] **M6-003** -- `_bidi_runs(bytes_ptr, bytes_len, out_runs_ptr,
      out_cap) -> packed_u64` real body: landed. Walks input one
      grapheme cluster at a time via `_gc_next`, classifies first cp
      of each cluster via `_bidi_class`, aggregates consecutive same-
      class clusters into monotone runs. 16-byte run entry
      {byte_start u32 LE, byte_end u32 LE, class u8, pad u8[7]}.
      Packed return `(runs_emitted << 32) | status` with status in
      {0=OK, 1=OUT_TOO_SMALL, 2=INVALID_UTF8}. OUT_TOO_SMALL commits
      partial output (caller resumes from last byte_end); INVALID
      discards the current open run (invariant: emitted runs end at
      valid cluster boundaries).
- [x] **M6-004** -- Fingerprint goldens: `tests/fingerprints/bidi.golden`
      with 8 TAG lines (BIDI_PURE_LTR, BIDI_PURE_RTL, BIDI_MIXED,
      BIDI_NUMBER, BIDI_ARABIC_DIGITS, BIDI_NEUTRAL, BIDI_EMPTY,
      BIDI_SINGLE_L); OUTPUT_HEX encodes concatenated 16-byte run
      entries (32 nibbles per run).
- [x] **M6-005** -- Proptest witnesses:
      `tests/proptest_bidi.pdx` with 3 invariants (coverage, non-empty,
      monotone class) and umbrella `pb_run_all`; fail codes in the
      0xFFFFEDCx band.
- [x] **M6-006** -- Design doc:
      `design/toolchain/libpdx-unicode-bidi.md`.

**M6 limitations (stubbed; tracked for M6.1+ follow-up tickets):**

- Reduced five-class BIDI_CLASS table only (L, R, N, AN, EN). The full
  UAX #9 class set has 23 values (AL distinct from R, NSM carved out
  of Hebrew/Arabic, ES/ET/CS for European number clustering, ON for
  brackets and math, WS/BN/B/S for whitespace and separators, and the
  LRE/RLE/PDF explicit embedding set). M6.1 target.
- AL (Arabic Letter) folded into R. In the full UAX #9 these resolve
  slightly differently (AL characters inherit paragraph direction when
  mixed with EN digits); M6.1 splits them.
- Hebrew cantillation marks and Arabic combining marks classified as
  R (parent block) rather than NSM (Non-Spacing Mark); works for pure-
  RTL runs but misclassifies mixed Hebrew-ASCII content with trailing
  combining marks. M6.1 target.
- Latin-1 Supplement entire U+00C0..00FF treated as L; in the full UCD
  U+00D7 (×) and U+00F7 (÷) are class ON (neutral). Minor; M6.1 refines.
- Paragraph-level resolution (TR#9 §P1): the first-strong-character
  algorithm determining sot direction is NOT implemented. The caller
  can approximate by inspecting the first non-N run. M6.2 target.
- Explicit directional embeddings (LRE / RLE / LRO / RLO / PDF / LRI
  / RLI / FSI / PDI, TR#9 §3.3.2): treated as N. Rare in terminal
  input today; M6.3 target.
- Mirroring pairs (TR#9 §3.4): brackets and paired characters that
  mirror inside an RTL run. Needs UCD BidiMirroring.txt. M6.4 target.

### M7 -- Locale registry (paideia-os#2618, landed)

- [x] **M7-001** -- `src/locale.pdx` scaffold + module `Locale`, eight
      locale_id constants (LOCALE_C=0, LOCALE_EN_US=1, LOCALE_EN_GB=2,
      LOCALE_JA_JP=3, LOCALE_ZH_CN=4, LOCALE_KO_KR=5, LOCALE_HE_IL=6,
      LOCALE_AR_SA=7), three status codes (LOCALE_STATUS_OK=0,
      LOCALE_STATUS_UNKNOWN=1, LOCALE_STATUS_MALFORMED=2), direction
      constants (LOCALE_DIR_LTR=0, LOCALE_DIR_RTL=1), ambiguous-width
      constants (LOCALE_AMBIG_NARROW=0, LOCALE_AMBIG_WIDE=1),
      error-band slice 0xFFFFE770..0xFFFFE77F (reserved; no slots
      consumed at M7 since every status is encoded in the packed
      return's low 8 bits).
- [x] **M7-002** -- `_locale_parse(tag_ptr, tag_len) -> packed_u64`
      real body: landed. Strict `xx-YY` five-byte parser:
      `tag_len == 5` gate, byte[2] separator gate (reject '_' as
      MALFORMED, require '-'), lowercase language bytes (A..Z ->
      +0x20) and uppercase region bytes (a..z -> -0x20), pack the
      four normalised bytes into a 4-byte key, dispatch over seven
      registry keys (en-US, en-GB, ja-JP, zh-CN, ko-KR, he-IL,
      ar-SA). Returns `(locale_id << 8) | status`. Pure leaf; no
      callee-save push.
- [x] **M7-003** -- `_locale_default() -> u64` real body: landed.
      Returns 0 (C / POSIX). Pure leaf.
- [x] **M7-004** -- `_locale_direction(locale_id) -> u64` real body:
      landed. Returns 1 (RTL) iff locale_id in {6, 7}; 0 (LTR)
      otherwise, including every id outside the baseline registry.
      Pure leaf.
- [x] **M7-005** -- `_locale_width_ambiguous_is_wide(locale_id)
      -> u64` real body: landed. Returns 1 (wide) iff locale_id in
      {3, 4, 5} (East Asian locales); 0 (narrow) otherwise. Pure
      leaf.
- [x] **M7-006** -- Fingerprint goldens:
      `tests/fingerprints/locale.golden` with 5 TAG lines
      (LOC_PARSE_EN, LOC_PARSE_JA, LOC_PARSE_HE, LOC_PARSE_UNKNOWN,
      LOC_PARSE_MALFORMED); OUTPUT_HEX encodes the packed u64 return
      (16 nibbles big-endian).
- [x] **M7-007** -- Proptest witnesses:
      `tests/proptest_locale.pdx` with 3 invariants (default
      well-defined, parse idempotent, direction totality) and
      umbrella `pl_run_all`; fail codes in the 0xFFFFEDDx band.
- [x] **M7-008** -- Design doc:
      `design/toolchain/libpdx-unicode-locale.md`.

**M7 limitations (stubbed; tracked for M7.1+ follow-up tickets):**

- Strict 5-byte `xx-YY` shape only. Shorter language-only tags
  (`en`, `ja`), 3-letter language codes (ISO 639-3), script subtags
  (`sr-Cyrl-RS`), variant subtags (`de-CH-1996`), and extension
  subtags (`en-US-u-ca-gregory`) are MALFORMED at M7. M7.1 lands the
  2-byte and 3-byte prefix path first (needed before environment-
  variable passthrough `LANG=en` stops surfacing MALFORMED on an
  otherwise legal POSIX value).
- Eight-entry baseline registry (C, en-US, en-GB, ja-JP, zh-CN,
  ko-KR, he-IL, ar-SA). Covers every direction / ambiguous-width
  class the M6 / M5 primitives distinguish today; a larger CLDR
  slice (es, fr, de, it, pt, ru, pl, nl, tr, vi, th, id, ms, hi, ...)
  lands at M7.4.
- Direction and ambiguous-wide only. Full locale axes (decimal
  separator, grouping separator, currency symbol, first-day-of-week,
  per-locale date / time patterns) are M7.4+ work.
- The eighth entry (C / POSIX) is reachable only through
  `_locale_default()`; the parser never resolves to it because its
  canonical tag is not `xx-YY`. A caller that wants to parse the
  literal strings `C` or `POSIX` into id=0 can intercept them above
  this library (shell dispatch, environment-variable parser).
- Error band 0xFFFFE770..0xFFFFE77F is reserved but holds no slots
  at M7; every status fits in the low 8 bits of the packed return.
  M7.1+ error kinds (LOCALE_TAG_TOO_LONG at M7.2, LOCALE_REGISTRY_FULL
  if the registry becomes caller-populated at M7.5) land as band
  values.

### M8 -- IPC-boundary NFC hook (paideia-os#2619, landed)

- [x] **M8-001** -- `src/ipc_nfc.pdx` scaffold + module `IpcNfc`,
      three status codes (IPC_NFC_STATUS_OK=0,
      IPC_NFC_STATUS_OUT_TOO_SMALL=1, IPC_NFC_STATUS_INVALID_UTF8=2),
      two is_nfc constants (IPC_NFC_NOT_NFC=0, IPC_NFC_IS_NFC=1),
      error-band slice 0xFFFFE780..0xFFFFE78F (reserved; no slots
      consumed at M8 since every status is encoded in the low 8
      bits of the packed return).
- [x] **M8-002** -- `_ipc_nfc_check(bytes_ptr, bytes_len) -> packed_u64`
      real body: landed. Single-pass byte scan for UTF-8 lead bytes
      0xCC and 0xCD (U+0300..U+037F combining-marks block). Any hit
      returns is_nfc=0; no hit returns is_nfc=1. Status always 0
      (no UTF-8 validation at the check layer). Pure leaf; no
      callee-save push; no stack frame.
- [x] **M8-003** -- `_ipc_nfc_apply(bytes_ptr, bytes_len, out_ptr,
      out_cap) -> packed_u64` real body: landed. Thin wrapper over
      M3's `_norm_nfc` (identical 4-arg signature; no arg-shuffle
      needed). Returns the normalise result unchanged. One nested
      CALL (`_norm_nfc`); `sub rsp, 8` + `add rsp, 8` for alignment.
- [x] **M8-004** -- Fingerprint goldens:
      `tests/fingerprints/ipc_nfc.golden` with 5 TAG lines
      (IPC_NFC_ASCII, IPC_NFC_PRECOMPOSED, IPC_NFC_DECOMPOSED,
      IPC_NFC_EMPTY, IPC_NFC_APPLY). Four check cases encoded as
      16-nibble big-endian packed u64; apply case encoded as the
      output bytes (same convention as normalize.golden).
- [x] **M8-005** -- Proptest witnesses:
      `tests/proptest_ipc_nfc.pdx` module `ProptestIpcNfc` with 3
      invariants (idempotence, check-apply agreement, ASCII fast
      path) and umbrella `pin_run_all`; fail codes in the
      0xFFFFEDEx band.
- [x] **M8-006** -- Design doc:
      `design/toolchain/libpdx-unicode-ipc-nfc.md`.

**M8 limitations (ring-3-only; tracked for M8.1+ follow-up tickets):**

- Kernel-side per-syscall hook in `sys_ipc_recv` NOT landed. The
  normaliser is a ring-3 library using .bss scratch and the M3
  decomp table (~3 KiB), neither of which the kernel's IPC fast
  path can call without duplicating the state or trampolining
  through userspace. The convention at M8 is "every IPC receiver's
  ring-3 glue calls `_ipc_nfc_apply` on each string field it
  parses". A VPC-side or pds-side wrapper that applies the hook
  uniformly across every channel's receive path is M8.1 target.
- Check is a CONSERVATIVE OVER-APPROXIMATION of NFC: it reports
  is_nfc=1 on inputs that are actually already NFC (correct), and
  MAY report is_nfc=0 on inputs that are also already NFC (e.g. a
  bare U+0300 combining mark with no preceding base). False
  negatives cost one no-op apply call; false positives cannot
  occur (every M3 decomposition entry's mark cp is in U+0300..036F
  whose UTF-8 lead is 0xCC/0xCD, exhaustively covered by the
  scan). The exact check that calls _norm_nfc and byte-compares
  against the input is landed as an opt-in `_ipc_nfc_check_exact`
  at M8.2.
- The scan does NOT widen for post-M3 decomposition table growth
  (Devanagari, Hebrew, Arabic, CJK -- planned for M3.2+). As M3
  grows, the check's scan loop must grow in lockstep with
  additional `cmp rax, 0xXX; je ipc_chk_not_nfc` lines for the
  new blocks' combining-mark UTF-8 lead bytes. M8.3 lands the
  M3.2-synchronised scan.
- The hook always normalises to NFC. If a future consumer site
  needs NFKC (compatibility fold -- e.g. a fullwidth-ASCII cleanup
  pass for Japanese IME input), that site must call `_norm_nfkc`
  directly. M8.4 lands `_ipc_nfkc_apply` as a sibling entry point
  if the demand materialises.

### M9 -- Streaming decoder iterator (planned)

- [ ] `utf8_decode_iter_begin(src_ptr, src_len) -> handle`
- [ ] `utf8_decode_iter_next(handle) -> packed | UTF8_* | EOF`
- [ ] `utf8_decode_iter_end(handle) -> void`
- [ ] Opaque-handle convention this library will own (initial sketch:
      a 24-byte struct `{src_ptr, src_len, pos}` the caller allocates
      and the primitives walk; no cap, no syscall).

### M10 -- UTF-16 bridge (planned)

- [ ] `utf8_offset_to_utf16(src_ptr, src_len, utf8_off) -> utf16_off`
- [ ] `utf16_offset_to_utf8(src_ptr, src_len, utf16_off) -> utf8_off`
- [ ] `utf8_offset_to_utf32` / `utf32_offset_to_utf8`
- [ ] Mirror of the paideia-as-unicode `lsp_bridge` module.

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

M3 adds four public bindings (`_norm_nfd`, `_norm_nfkd`,
`_norm_nfc`, `_norm_nfkc`) plus five internal helpers
(`_norm_lookup_decomp`, `_norm_lookup_ccc`, `_norm_lookup_compose`,
`_norm_decompose`, `_norm_sort_scratch`, `_norm_compose_scratch`,
`_norm_encode_scratch`, `_norm_core`), the normalize error band
0xFFFFE720..0xFFFFE72F (two slots used: `NORM_INVALID_UTF8_CODE`
at 0xFFFFE720, `NORM_OUT_TOO_SMALL_CODE` at 0xFFFFE721), the
three status codes (NORM_STATUS_OK=0, NORM_STATUS_OUT_TOO_SMALL=1,
NORM_STATUS_INVALID_UTF8=2), and the four form-flag constants
(NORM_FORM_NFD=0, NORM_FORM_NFKD=1, NORM_FORM_NFC=2,
NORM_FORM_NFKC=3). The status fits in the low 8 bits of the
packed return (0..2); the high 32 bits carry out_bytes_written
on success and 0 on failure. M3 is additive and preserves every
M1 + M2 symbol unchanged -- v1.2.0 is backward-compatible with
v1.1.0 and v1.0.0.

M4 adds two public bindings (`_coll_compare`, `_coll_sort_key`)
plus five internal helpers (`_coll_lookup_mark`,
`_coll_classify`, `_coll_build_ces`, `_coll_emit_key`,
`_coll_keycmp`), the collation error band 0xFFFFE730..0xFFFFE73F
(two slots used: `COLL_INVALID_UTF8` at 0xFFFFE730,
`COLL_OUT_TOO_SMALL` at 0xFFFFE731), and three status codes
(COLL_STATUS_OK=0, COLL_STATUS_OUT_TOO_SMALL=1,
COLL_STATUS_INVALID_UTF8=2) packed into the low 8 bits of
`_coll_sort_key`'s return. `_coll_compare` returns -1/0/1
directly as an i64 (the -1 bit pattern is 0xFFFFFFFFFFFFFFFF).
M4 is additive and preserves every M1 + M2 + M3 symbol
unchanged -- v1.3.0 is backward-compatible with v1.2.0,
v1.1.0, and v1.0.0.

M5 adds two public bindings (`_width_char`, `_width_str`), the
width error band 0xFFFFE740..0xFFFFE74F (one slot used:
`W_INVALID_UTF8` at 0xFFFFE740), and two status codes
(W_STATUS_OK=0, W_STATUS_INVALID_UTF8=2) packed into the low 8
bits of `_width_str`'s return. `_width_char` returns 0/1/2
directly as a u64 with no error band (the caller has already
decoded the cp). M5 is additive and preserves every
M1 + M2 + M3 + M4 symbol unchanged -- v1.4.0 is
backward-compatible with v1.3.0, v1.2.0, v1.1.0, and v1.0.0.

M6 adds two public bindings (`_bidi_class`, `_bidi_runs`), five
BIDI_CLASS constants (BIDI_L=0, BIDI_R=1, BIDI_N=2, BIDI_AN=3,
BIDI_EN=4), the bidi error band 0xFFFFE760..0xFFFFE76F (two slots
used: `BIDI_INVALID_UTF8` at 0xFFFFE760, `BIDI_OUT_TOO_SMALL` at
0xFFFFE761), and three status codes (BIDI_STATUS_OK=0,
BIDI_STATUS_OUT_TOO_SMALL=1, BIDI_STATUS_INVALID_UTF8=2) packed
into the low 8 bits of `_bidi_runs`'s return. `_bidi_class`
returns 0..4 directly as a u64 with no error band (the caller
has already decoded the cp). Each 16-byte run entry carries
byte_start (u32 LE), byte_end (u32 LE), class (u8), and seven
bytes of padding; the stride-16 layout lets callers index runs
with `shl i, 4`. M6 is additive and preserves every
M1 + M2 + M3 + M4 + M5 symbol unchanged -- v1.5.0 is
backward-compatible with v1.4.0, v1.3.0, v1.2.0, v1.1.0, and
v1.0.0.

M8 adds two public bindings (`_ipc_nfc_check`, `_ipc_nfc_apply`),
three status codes (IPC_NFC_STATUS_OK=0, IPC_NFC_STATUS_OUT_TOO_SMALL=1,
IPC_NFC_STATUS_INVALID_UTF8=2, same values as M3's Normalize status
codes), two is_nfc constants (IPC_NFC_NOT_NFC=0, IPC_NFC_IS_NFC=1), and
the ipc-nfc error band 0xFFFFE780..0xFFFFE78F (reserved; no slots used
-- every status fits in the low 8 bits of `_ipc_nfc_apply`'s packed
return, and `_ipc_nfc_check` never fails since it does no UTF-8
validation). `_ipc_nfc_check` returns `(is_nfc << 32) | status` with
is_nfc in {0, 1} and status always 0 at M8. `_ipc_nfc_apply` returns
`(out_bytes << 32) | status` with the same shape as `_norm_nfc` (it is
a direct pass-through). M8 is additive and preserves every
M1 + M2 + M3 + M4 + M5 + M6 + M7 symbol unchanged -- v1.7.0 is
backward-compatible with v1.6.0, v1.5.0, v1.4.0, v1.3.0, v1.2.0,
v1.1.0, and v1.0.0.

M7 adds four public bindings (`_locale_parse`, `_locale_default`,
`_locale_direction`, `_locale_width_ambiguous_is_wide`), eight
locale_id constants (LOCALE_C=0, LOCALE_EN_US=1, LOCALE_EN_GB=2,
LOCALE_JA_JP=3, LOCALE_ZH_CN=4, LOCALE_KO_KR=5, LOCALE_HE_IL=6,
LOCALE_AR_SA=7), three status codes (LOCALE_STATUS_OK=0,
LOCALE_STATUS_UNKNOWN=1, LOCALE_STATUS_MALFORMED=2), two direction
constants (LOCALE_DIR_LTR=0, LOCALE_DIR_RTL=1), two ambiguous-width
constants (LOCALE_AMBIG_NARROW=0, LOCALE_AMBIG_WIDE=1), seven
registry key constants (LOCALE_KEY_EN_US..LOCALE_KEY_AR_SA), and
the locale error band 0xFFFFE770..0xFFFFE77F (reserved; no slots
used -- every status fits in the low 8 bits of
`_locale_parse`'s packed return). `_locale_default`,
`_locale_direction`, and `_locale_width_ambiguous_is_wide` return
small enum values directly as u64 with no error band. M7 is
additive and preserves every M1 + M2 + M3 + M4 + M5 + M6 symbol
unchanged -- v1.6.0 is backward-compatible with v1.5.0, v1.4.0,
v1.3.0, v1.2.0, v1.1.0, and v1.0.0.
