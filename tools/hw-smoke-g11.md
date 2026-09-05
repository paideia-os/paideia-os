# tools/hw-smoke-g11.md — G11 polyglot input bring-up recipe

Operator recipe for the G11 polyglot / IME hardware-only test,
per D7 `gated:hardware` discipline. Runs on a real ThinkPad T14
Gen4 (12th-gen + successors) with G5 SDF shaping, the G7
compositor's text-input surface, and G11-M1..M5 IME primitives
minted and reporting fingerprints from prior batches. Not run in
CI or QEMU.

Terminal doc for the G11 milestone. Closes #2314, #2315, #2316,
#2317, #2318, #2319, #2320, #2321, #2322, #2323, #2324, and this
one (#2325). Exercises the IME stack end-to-end: KIND_IME_SESSION
mint on a text-input surface (P10 mitigation), Latin n-gram
autocomplete, CJK Pinyin phonetic composition, Devanagari
conjunct clustering, BiDi Annex #9 level-run analysis on a mixed
Latin/Arabic paragraph, and atomic provider switch under the
compositor's single-router contract.

Marked `dormant` under CI — the IME witness sidecar sits in the
tree but is not called from the QEMU boot path. See section 6.

---

## 1. Purpose

Prove end-to-end polyglot input on real T14 Gen4 hardware. The
single boot exercises:

- `KIND_IME_SESSION` linear derived cap mint bound to a
  text-input surface at focus-enter (G11-M1-001 / #2314), P10
  gate refusing a second session against the same surface;
- `KIND_IME_PROVIDER` discovery + provider-switch protocol
  (G11-M1-002 / #2315) with the compositor as the exclusive IME
  router (G11-M1-003 / #2316);
- Latin n-gram autocomplete (G11-M2-001 / #2317) producing a
  ranked candidate window, and dead-key / compose sequences
  (G11-M2-002 / #2318) resolving to a single committed grapheme;
- CJK Pinyin phonetic engine (G11-M3-001 / #2319) mapping ASCII
  syllables to Hanzi candidates through the compose buffer;
- Indic InScript keymap (G11-M4-002 / #2322) driving the G5
  complex shaper's Devanagari conjunct rules (G11-M4-001 / #2321);
- BiDi UBA integration (G11-M5-001 / #2323) computing paragraph
  level runs and caret-anchor mirroring (G11-M5-002 / #2324).

The G5 SDF text substrate, G7 compositor, and G8 input-server
are pre-conditions, not part of the test matrix. R32 HID must
have claimed the keyboard through the input server.

## 2. Prerequisites

- Reference hardware: ThinkPad T14 Gen4 (or any laptop the
  fingerprint sheet lists) with an ISO/ANSI keyboard reachable
  through the input server (built-in or USB HID).
- Boot mode: `-kernel` via `boot_stub.S`, opted into the 14-mode
  matrix's `g11-ime` slot; loader sets `PAIDEIA_G11_SMOKE=1` in
  the `_init_caps` sidecar.
- G5 shaping bring-up passes; SDF atlas covers Latin, CJK,
  Devanagari, and Arabic glyphs for the sample strings.
- G7 first-window bring-up passes; sample app owns one
  `KIND_TEXT_INPUT_SURFACE` derived from its toplevel for T1's
  session to bind against.
- G8 input-routing bring-up passes; compositor is sole subscriber
  to keyboard events on the test seat.
- `KIND_IME_SESSION` and `KIND_IME_PROVIDER` substrates report
  init fingerprints on the boot log before the G11 witness runs.
- Provider bundles registered under G11-M1-002: Latin autocomplete
  + dead-key, CJK Pinyin, Indic InScript Devanagari, and a no-op
  passthrough (switch target in T5).
- USB serial cable + minicom/screen for the boot log.

## 3. Test matrix

Five sub-tests, run in order, one boot. Each emits a PASS
fingerprint or halts on a FAIL variant. The witness's synthetic
key injector drives keystrokes; the physical keyboard is claimed
only to prove seat wiring is live.

### T1: Latin autocomplete candidate window

Activate the Latin autocomplete provider on the text-input
surface. Inject prefix `paid`; the n-gram predictor (G11-M2-001)
produces a ranked candidate list. Witness reads the candidate
window's node count off the session composition buffer and
asserts N >= 3 (shipped corpus contains `paideia`, `paid`,
`paideutic` in the top-K).

- PASS: `G11 LATIN AUTOCOMPLETE OK candidates=<N>`
- FAIL: `G11 LATIN AUTOCOMPLETE FAIL stage=<no_session|no_provider|no_candidates|short_list> observed=<N>`

### T2: CJK Pinyin phonetic composition

Switch active provider to CJK Pinyin (G11-M3-001) via the
provider-switch protocol. Inject `ni` then select candidate 0;
the phonetic engine commits the top Hanzi (`ni3` -> U+4F60 `你`
under the shipped frequency-weighted dictionary). Witness reads
the committed codepoint off the commit event and asserts it lies
in CJK Unified Ideographs (U+4E00..U+9FFF).

- PASS: `G11 CJK PINYIN OK hanzi=<uni>`
- FAIL: `G11 CJK PINYIN FAIL reason=<no_switch|no_syllable|no_candidate|out_of_range> hanzi=<uni>`

### T3: Devanagari conjunct cluster

Switch active provider to Indic InScript Devanagari (G11-M4-002).
Inject the InScript sequence for conjunct `क्ष` (ka + virama +
ssa: U+0915 U+094D U+0937). The G5 shaper (invoked through the
IME commit path per G11-M4-001) resolves the cluster into its
ligated glyph run. Witness reads the committed grapheme cluster
off the composition buffer and asserts the UTF-8 byte sequence
matches `E0 A4 95 E0 A5 8D E0 A4 B7`.

- PASS: `G11 INDIC CONJUNCT OK output=<seq>`
- FAIL: `G11 INDIC CONJUNCT FAIL reason=<no_switch|no_virama|no_cluster|byte_mismatch> output=<seq>`

### T4: BiDi mixed-paragraph level-run analysis

Commit (via passthrough) the mixed paragraph
`hello مرحبا 123 world`. The G11-M5-001 UBA engine computes
paragraph level runs per Annex #9 P2/P3. Witness reads the
level-run vector off the session analysis buffer and asserts the
run count matches the expected UBA partitioning (N == 5: LTR
`hello `, RTL `مرحبا `, LTR `123`, RTL space, LTR `world`,
subject to whitespace-boundary rules).

- PASS: `G11 BIDI ANALYZE OK runs=<N>`
- FAIL: `G11 BIDI ANALYZE FAIL reason=<no_paragraph|no_analysis|run_count_mismatch> runs=<N>`

### T5: provider switch atomicity

With CJK Pinyin active (restored from T2 by the witness), issue
a provider-switch to passthrough mid-composition (compose buffer
non-empty). The G11-M1-002 protocol requires the switch to
(a) flush or discard the outgoing composition atomically per the
router's linear commit rule, (b) reject any keyboard event
between old-provider tear-down and new-provider mint, and (c)
emit a single provider-switch event carrying both endpoints.
Witness asserts the event's `old` and `new` language tags match
the pre/post state.

- PASS: `G11 PROVIDER SWITCH OK old=<lang> new=<lang>`
- FAIL: `G11 PROVIDER SWITCH FAIL reason=<no_switch|split_commit|dropped_event|tag_mismatch> old=<lang> new=<lang>`

## 4. Failure taxonomy

- `SKIP: no G5 shaper` — G5 SDF substrate not integrated; abort
  before T3 (T1, T2, T4, T5 still run).
- `SKIP: no G7 text surface` — no `KIND_TEXT_INPUT_SURFACE` for
  the sample app's toplevel; whole matrix skipped.
- `SKIP: no G8 seat` — input-server did not claim a keyboard
  seat; whole matrix skipped.
- `SKIP: no provider <lang>` — a required bundle (`latin`,
  `cjk-pinyin`, `indic-inscript-hi`, `passthrough`) missing from
  discovery; affected test only skipped.
- `G11 * FAIL ...` — one of the five test fingerprints; witness
  halts immediately.
- `#PF at <rip>` in the interval — page fault inside a session,
  provider dispatcher, shaper, or BiDi path; hard regression,
  capture serial and open a bug.
- `WATCHDOG G11 T<n>` — test failed to emit either PASS or FAIL
  before its per-test 2-second timeout (3-second for T3 to allow
  ligature lookup, 3-second for T4 to allow the UBA two-pass
  resolution); witness halts.

## 5. Success criteria

- All five tests pass in one boot, in order.
- Fingerprints appear on the serial log in the order T1, T2, T3,
  T4, T5.
- No `G11 * FAIL` line anywhere in the log.
- No `#PF` inside the G11 window (between the previous milestone
  CLOSE line and the G11 CLOSE line).
- No `WATCHDOG G11 T<n>` line.
- Serial log ends with:

      G11 CLOSE OK issues=2314,2315,2316,2317,2318,2319,2320,2321,2322,2323,2324,2325

## 6. Wiring pending

The KIND_IME_SESSION / KIND_IME_PROVIDER / compositor IME router
/ Latin / CJK / Indic / BiDi cap dispatchers landed in G11-M1..M5
are NOT yet wired into `src/kernel/boot/kernel_main.pdx`. The
future IME wire-body milestone (post-G11, deferred, not yet
filed) must:

- Register the G11 cap kinds (KIND_IME_SESSION, KIND_IME_PROVIDER)
  in the boot cap table (alongside G7 compositor caps once G7
  wire-body lands).
- Bind the compositor's IME router (`src/user/compositor/
  ime_router.pdx`) as the exclusive keyboard-event subscriber on
  every seat carrying a focused text-input surface.
- Register the shipped provider bundles (latin, cjk-pinyin,
  indic-inscript-hi, passthrough) with the discovery service at
  init-cap sidecar time.
- Add `PAIDEIA_G11_SMOKE=1` to the `tools/run-smoke.sh` mode
  matrix.
- Add the G11 witness call at the tail of the G11 block in the
  platform init file (mirroring G4/G5/G7/G8/G10 witness-wiring).

Until that milestone lands, this recipe is a specification for
the tester, not an executable procedure. The build-time gate in
`tools/build.sh` continues to pin the G11 cap-table writers to
their owner objects; the wire-body milestone must extend that
gate, not remove pins.

## 7. Reproduction command

Once the wire-body milestone lands, the T14 tester runs:

    PAIDEIA_G11_SMOKE=1 bash tools/run-smoke.sh

`PAIDEIA_G11_SMOKE` is not yet wired into `tools/run-smoke.sh`;
the mode matrix add is part of the wire-body milestone (see
section 6). Before that lands, the operator can manually patch
`_init_caps` in the loader sidecar to set the sentinel and boot
the T14 by hand — the witness will run against whatever G11
dispatchers are reachable, but the G5/G7/G8/provider-registration
pre-conditions still guard T1..T5.

---

## Notes

Failure of the QEMU-side dormant witnesses
(`kind_ime_session_synth.pdx`, `kind_ime_provider_synth.pdx`,
`latin_autocomplete_synth.pdx`, `latin_deadkey_synth.pdx`,
`cjk_phonetic_synth.pdx`, `indic_inscript_synth.pdx`,
`bidi_uba_synth.pdx`, `g11_integration_synth.pdx`) means this HW
smoke will not run either — the primitive has regressed. Fix the
QEMU witnesses first.

Cross-reference `tools/hw-smoke-g7.md` for the compositor
substrate the text-input surface derives from,
`tools/hw-smoke-g8.md` for the input-routing seat the IME router
claims, `tools/hw-smoke-g10.md` for the a11y bring-up whose
focus-change hook interlocks with the IME session focus events,
and `design/terminal/i18n-provider.md` for the locale-and-provider
data model the shipped bundles derive their language tags from.
