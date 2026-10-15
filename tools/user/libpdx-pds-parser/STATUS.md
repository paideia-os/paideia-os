# libpdx-pds-parser -- status

**Waves:**
- R221 (semantic shell -- parser-tier Unicode and lexer umbrella,
  paideia-os#2485)
- R223 (pipeline-lang umbrella, paideia-os#2487)
**Current milestones:** R221.M1 (UTF-8 decoder + NFC normalizer) --
landed. R223.M1 (Pipeline stage parser) -- landed.
**Version:** 1.1.0.

See the R221 M-table in the umbrella issue (paideia-os#2485) and in
`design/terminal/semantic-shell-language-plan.md` §4 R221 for the
upstream wave-level design; this file tracks the per-milestone
landing checklist as it closes locally.

## Milestone checklist

### M1 -- UTF-8 decoder + NFC normalizer (paideia-os#2651, landed)

- [x] **M1-001** -- scaffold + module boundary: landed. Source files
      (`src/lib.pdx` module `LibpdxPdsParser`, `src/utf8_nfc.pdx`
      module `Utf8Nfc`), `caps.decl`, `README.md`, `CHANGELOG.md`,
      `STATUS.md`, `LICENSE`.
- [x] **M1-002** -- `_u8n_quick_check_ascii` landed: pure-leaf O(n)
      scan returning `1` iff every byte `< 0x80`, else `0`.
- [x] **M1-003** -- `_u8n_decode_and_normalize` landed: fast ASCII
      byte-copy path + slow delegation to `_norm_nfc`; four-value
      `U8N_*` return taxonomy.
- [x] **M1-004** -- design doc landed:
      `design/shell/parser-utf8-nfc.md`.
- [ ] **M1-005** -- test corpus + fingerprint goldens: deferred to a
      follow-up (`tests/proptest_utf8_nfc.pdx`,
      `tests/fingerprints/utf8_nfc.golden`); the design doc §8
      enumerates the TR#15 Part 1 subset, ASCII spot-tests,
      negative malformed-UTF-8 cases, and `out_cap` boundary cases.

### M2 -- TR#29 grapheme cluster boundary iterator (deferred)

Blocked by: M1 (consumes `_u8n_decode_and_normalize`'s output
buffer) + `libpdx-unicode-tables::grapheme._gc_next` (R131.M2, which
is landed).

### M3 -- TR#11 width table pass (deferred)

Blocked by: M2 + `libpdx-unicode-tables::width._width_char` /
`_width_str` (R131.M5, which is landed).

### M4 -- Context-tracking lexer (Pipeline / Datalog / Lambda) (deferred)

Blocked by: M2, M3, and `paideia-as` stdlib R220.M3.

### M5 -- Unified AST sum type + node constructors (deferred)

Blocked by: M4.

### M6 -- Source-span tracking through NFC normalization (deferred)

Blocked by: M1 + M5. Will add a sibling entry point
`_u8n_decode_and_normalize_with_map` that emits a span-mapping
table alongside the output bytes.

### M7 -- Fuzz corpus for parser + Unicode (deferred)

Blocked by: M5. 24-hour AFL run gates landing.

## R223 pipeline-lang checklist

### M1 -- Pipeline stage parser + `|` operator (paideia-os#2666, landed)

- [x] **R223.M1-001** -- `src/pipeline.pdx` module `Pipeline` landed:
      `_pl_parse` + `_pl_emit_word`, 64-byte stage record, PL_* status
      taxonomy in 0x2B00..0x2BFF.
- [x] **R223.M1-002** -- design doc landed:
      `design/shell/pipeline-stage-parser.md`.
- [ ] **R223.M1-003** -- 30-test parser corpus
      (`tests/proptest_pipeline.pdx`): deferred to R223.M7 per the
      umbrella decomposition; the design doc §12 enumerates the
      representative OK/error cases that corpus will cover.

## Error-band accounting

| Band             | Range            | Milestone | Status |
|------------------|------------------|-----------|--------|
| utf8_nfc         | 0x2700..0x2702   | R221.M1   | landed |
| grapheme_iter    | 0x2710..0x271F   | R221.M2   | reserved |
| width_pass       | 0x2720..0x272F   | R221.M3   | reserved |
| lexer            | 0x2730..0x274F   | R221.M4   | reserved |
| ast              | 0x2750..0x275F   | R221.M5   | reserved |
| span_map         | 0x2760..0x276F   | R221.M6   | reserved |
| pipeline         | 0x2B00..0x2B04   | R223.M1   | landed |
| pipeline-M2+     | 0x2B05..0x2BFF   | R223.M2+  | reserved |

Codes live in the parser-tier packed-status range (0x2700..0x2BFF
slice). Disjoint from every user-space `0xFFFFExxx` error band in
the paideia-os tree (see `caps.decl` for the full disjointness
proof).
