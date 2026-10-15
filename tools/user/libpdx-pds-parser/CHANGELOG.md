# Changelog -- libpdx-pds-parser

All notable changes to this library are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) +
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] -- 2026-10-14

R223.M1 of the semantic-shell pipeline-lang umbrella
(paideia-os#2487, decomposed into paideia-os#2666 for this M1).

### Added

- `src/pipeline.pdx` module `Pipeline`: parser-tier pipeline-stage
  tokeniser that turns `cmd1 arg | cmd2 arg | cmd3 arg` into a flat
  array of 64-byte `PipelineStage` records.
  - `_pl_parse(bytes_ptr, bytes_len, out_ptr, out_cap) -> packed_u64`
    -- the four-state tokeniser (WS / BARE / DQ / SQ) that commits
    one record per `|`-delimited segment and returns
    `(n_stages << 32) | status`.
  - `_pl_emit_word(stage_ptr, offset, len, word_slot) -> u64` --
    internal helper that writes one (offset, len) pair into either
    the cmd_name slot (`word_slot == PL_SLOT_CMD = 0xFFFF`) or
    `argv[word_slot]` (`word_slot ∈ 0..7`), updating the stage's
    `n_args` u16 for argv writes.
  - Quoting: `"double-quoted"` honours `\"` escape; `'single-quoted'`
    is literal (no escapes); bareword honours `\|` escape.
  - Return codes `PL_OK = 0`, `PL_ERR_TOO_MANY_STAGES = 0x2B00`,
    `PL_ERR_TOO_MANY_ARGS = 0x2B01`,
    `PL_ERR_UNTERMINATED_QUOTE = 0x2B02`,
    `PL_ERR_EMPTY_STAGE = 0x2B03`,
    `PL_ERR_OUT_TOO_SMALL = 0x2B04`.
  - Shape constants `PL_STAGE_SIZE = 64`, `PL_MAX_STAGES = 16`,
    `PL_MAX_ARGS = 8`, plus field-offset constants (`PL_OFF_*`) and
    flag bits (`PL_FLAG_HAS_ESCAPES`, `PL_FLAG_HAS_QUOTES`).
- `src/lib.pdx` module `LibpdxPdsParser`: added `LPX_PDS_PARSER_R223_M1_READY`
  feature flag (set to 1); minor version bump 1.0.0 -> 1.1.0.
- `caps.decl`: 0x2B00..0x2BFF error-band reservation for R223.M*;
  disjointness proof updated against the kernel-side Pipeline
  module's 0xFFFFEC40..42 band.
- `STATUS.md`: R223 wave + R223.M1 checklist landed; error-band
  accounting table extended.

### Design doc

- `design/shell/pipeline-stage-parser.md` (NEW): grammar, state
  machine, record layout + spec reconciliation note (64 B stride
  with 6-byte reserved tail reconciles the parent brief's
  `(64B)` + `[u8; 14]` arithmetic clash), word-span semantics,
  capacity/bound-check matrix, interaction with R129.M5 renderer-
  override `as` syntax (post-pass on last-stage argv tail stays
  after pipeline parse), interaction with R222 cmd-functor
  signature matching, caller flow, status-code namespace
  reservation (0x2B00..0x2BFF), 30-test corpus representative
  cases (deferred to R223.M7).

### Linker dependencies

- `src/pipeline.pdx` adds NO external linker dependency; `_pl_parse`
  only calls the module-private `_pl_emit_word`.

## [1.0.0] -- 2026-10-14

R221.M1 of the semantic-shell parser-tier Unicode umbrella
(paideia-os#2485, decomposed into paideia-os#2651 for this M1).

### Added

- `src/utf8_nfc.pdx` module `Utf8Nfc`: parser-tier UTF-8 decoder +
  NFC normalizer wrapper tuned for the pds-lang / semantic-shell
  parser call site.
  - `_u8n_quick_check_ascii(bytes_ptr, bytes_len) -> u64` -- pure-leaf
    O(n) byte scan returning `1` iff every byte `< 0x80`, else `0`.
    Zero-length input returns `1` (vacuously ASCII and NFC).
  - `_u8n_decode_and_normalize(bytes_ptr, bytes_len, out_ptr, out_cap)
    -> packed_u64` -- entry point that first calls
    `_u8n_quick_check_ascii`. On ASCII input, byte-copies to the
    output buffer (correct because every ASCII code point is a
    trivially-well-formed 1-byte UTF-8 scalar AND a fixed point of
    NFC). On non-ASCII input, delegates to
    `libpdx-unicode-tables::Normalize::_norm_nfc` (R131.M3) and
    translates its three-value status (`0`/`1`/`2`) into the
    four-value `U8N_*` taxonomy.
  - Return codes `U8N_OK = 0`, `U8N_ERR_INVALID_UTF8 = 0x2700`,
    `U8N_ERR_OUT_TOO_SMALL = 0x2701`,
    `U8N_ERR_NORMALIZE_FAIL = 0x2702` (reserved for post-M1
    normaliser-internal failure; never returned at M1).

- `src/lib.pdx` module `LibpdxPdsParser`: version triple and
  per-milestone feature-ready flags for feature-gating consumers.

- `caps.decl`: cap-free entry-point surface declaration + error-band
  taxonomy (0x2700..0x27FF reserved for parser-tier packed-status
  codes).

- `README.md`, `STATUS.md`, `LICENSE`: library scaffold.

### Linker dependencies

- `_norm_nfc` from `libpdx-unicode-tables::Normalize` (R131.M3).
  Consumers link both libraries with
  `--extra-obj-dir tools/user/libpdx-unicode-tables/build-out`.

### Design doc

- `design/shell/parser-utf8-nfc.md` (NEW).
