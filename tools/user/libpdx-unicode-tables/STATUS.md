# libpdx-unicode-tables -- status

**Wave:** R131 (semantic shell -- Unicode substrate umbrella,
paideia-os#2480)
**Current milestone:** M4 (UCA collation, UTS #10 reduced DUCET) -- landed.
**Version:** 1.3.0.

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

### M5 -- Streaming decoder iterator (planned)

- [ ] `utf8_decode_iter_begin(src_ptr, src_len) -> handle`
- [ ] `utf8_decode_iter_next(handle) -> packed | UTF8_* | EOF`
- [ ] `utf8_decode_iter_end(handle) -> void`
- [ ] Opaque-handle convention this library will own (initial sketch:
      a 24-byte struct `{src_ptr, src_len, pos}` the caller allocates
      and the primitives walk; no cap, no syscall).

### M6 -- UTF-16 bridge (planned)

- [ ] `utf8_offset_to_utf16(src_ptr, src_len, utf8_off) -> utf16_off`
- [ ] `utf16_offset_to_utf8(src_ptr, src_len, utf16_off) -> utf8_off`
- [ ] `utf8_offset_to_utf32` / `utf32_offset_to_utf8`
- [ ] Mirror of the paideia-as-unicode `lsp_bridge` module.

### M7 -- Stream validators (planned)

- [ ] `utf8_validate_stream` -- fail-fast whole-buffer validator.
- [ ] `utf8_validate_stream_recover` -- walks past the first
      malformed byte and reports every error offset, matching
      `paideia-as-unicode::Utf8Decoder::next`'s per-byte recovery.

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
