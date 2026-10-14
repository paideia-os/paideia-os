# Changelog -- libpdx-pds-parser

All notable changes to this library are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) +
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
