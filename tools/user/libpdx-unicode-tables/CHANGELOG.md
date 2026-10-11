# Changelog -- libpdx-unicode-tables

All notable changes to this library are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) +
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
