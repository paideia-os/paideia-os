# Parser fuzz corpus — R221.M7

Parent: paideia-os#2485. Milestone: paideia-os#2657.

## Scope

Survivability harness that drives the full parser-tier pipeline
against adversarial inputs — malformed UTF-8, malformed NFC, deeply
nested delimiters, zero-length and oversized inputs. Per
`semantic-shell.md` §15.6, the parser must not crash on any input;
any downstream status code is a well-defined return value and NOT a
fuzz failure.

## Harness module

`tools/user/libpdx-pds-parser/src/fuzz_harness.pdx` module `FuzzHarness`:

- `_fh_drive(bytes, len) -> packed_u64` — single entry point. Feeds
  the input through `_u8n_decode_and_normalize` (into `_fh_nfc_buf`,
  cap 32 KiB), then `_gi_count_clusters`, `_cl_init` + `_cl_tokenize`
  (into `_fh_tok_buf`, cap 8 KiB), `_pl_parse` (into `_fh_pl_buf`,
  cap 1 KiB), `_dl_parse` (into `_fh_dl_buf`, cap 2 KiB), `_ll_parse`
  (into `_fh_ll_buf`, cap 1 KiB). On any status error from the NFC
  stage the parser arm falls back to the raw bytes so parser
  tolerance of malformed UTF-8 is also exercised. Pre-entry guards:
  `len == 0` → `FH_OK stage=0`; `bytes == 0 && len > 0` →
  `FH_ERR_NULL_INPUT`; `len > FH_MAX_INPUT_BYTES (16384)` →
  `FH_ERR_INPUT_TOO_LARGE`.

## Error band

`0x4A00..0x4AFF`. Two slots used at M7:

- `FH_ERR_NULL_INPUT = 0x4A00`
- `FH_ERR_INPUT_TOO_LARGE = 0x4A01`

Slots `0x4A02..0x4AFF` reserved for M7.1+ (stage-wise swallowed-error
histograms, AFL/libfuzzer bridge, 24h-run crash-trace capture).

## Corpus layout

Seed corpus checked in under `tests/shell/parser-fuzz/seeds/` across
these categories (filed as R221.M7.1 corpus landing):

- **utf8/** — truncated 2-/3-/4-byte sequences, overlong encodings,
  surrogate codepoints, invalid continuation bytes.
- **nfc/** — precomposed vs decomposed mismatches, broken combining-
  mark sequences, stacked combining marks exceeding the shipped UCD
  canonical-composition table.
- **delim/** — deeply nested `{{{...}}}`, `[[[...]]]`, mismatched
  braces, lambda-in-datalog-in-pipeline-in-lambda.
- **edge/** — null bytes, CR/LF variants, BOM, 10 KiB+ inputs,
  zero-length.

## Acceptance

24-hour AFL run against `_fh_drive` finds no crash. The seed corpus
is the starting population; AFL mutations build out from there.
Corpus taxonomy and run-script are deferred to R221.M7.1.

## References

- `semantic-shell.md` §15.6
- `tools/user/libpdx-pds-parser/src/fuzz_harness.pdx`
- `tools/user/libpdx-pds-parser/caps.decl` (band 0x4A00..0x4AFF)
