# libpdx-unicode-tables Bidi (R131.M6)

## Status

**Wave:** R131 (semantic shell -- Unicode substrate umbrella,
paideia-os#2480).
**Milestone:** M6 (bidi runs, UAX #9 reduced five-class,
paideia-os#2617).
**Library version at landing:** 1.5.0.
**Date:** 2026-10-11.

## Scope

M6 adds the UAX #9 (Unicode Bidirectional Algorithm) run-level
classifier to the user-space Unicode library the shell, pds, and the
GPU-native terminal all link. The point of this milestone is to let a
consumer that draws text on a left-to-right monospace grid decompose a
mixed-direction input string into MONOTONE DIRECTIONAL RUNS so it can
reverse the glyph order inside each RTL run before laying it out. Two
public primitives:

```
_bidi_class(cp)                                           -> u64
_bidi_runs(bytes_ptr, bytes_len, out_runs_ptr, out_cap)   -> packed_u64
```

Return shapes:

- `_bidi_class`: a u64 in {0, 1, 2, 3, 4} naming one of five reduced
  UAX #9 BIDI_CLASS values. No error band -- the caller has already
  decoded the cp (via `utf8_decode_cp` or `_gc_next`), so a
  class-of-a-known-cp call cannot fail.
    - 0 = L   (Left-to-Right): Latin letters.
    - 1 = R   (Right-to-Left): Hebrew, Arabic letters, Arabic
          Presentation Forms-A.
    - 2 = N   (Neutral / default fallback): everything else.
    - 3 = AN  (Arabic Number): Arabic-Indic digits and extended
          Arabic-Indic digits.
    - 4 = EN  (European Number): ASCII digits.

- `_bidi_runs`: `(runs_emitted << 32) | status` with status in
  {0=OK, 1=OUT_TOO_SMALL, 2=INVALID_UTF8}. The runs_emitted field
  is the count of 16-byte run entries written to `out_runs_ptr`.
  On OUT_TOO_SMALL the field reflects the number of runs committed
  before capacity ran out (partial output IS committed; caller may
  resume from the last committed run's byte_end). On INVALID_UTF8
  the field reflects runs committed BEFORE the malformed byte; the
  current open run is DISCARDED (invariant: emitted runs end at
  valid cluster boundaries).

Both functions are pure leaf-with-nested-call -- no capability bind,
no syscall. `_bidi_class` is a pure leaf (no nested call at all);
`_bidi_runs` nests `_gc_next`, `utf8_decode_cp`, and `_bidi_class`.

M6 is the SIXTH milestone of this library and the SECOND one (after
M5 width) that encodes zero explicit UCD table entries and relies
entirely on range dispatch for its per-cp classifier. The full UAX #9
BIDI_CLASS property set is 23 classes across ~140,000 code points;
the reduced M6 baseline covers only the five classes above (L, R, N,
AN, EN) via ten hand-coded ranges in `_bidi_class`.

## Reduced BIDI_CLASS table (R131.M6 Latin + Arabic/Hebrew baseline)

### L (0) -- Left-to-Right

| Range            | Script / block                      | TR#9 class |
|------------------|-------------------------------------|------------|
| U+0041..U+005A   | ASCII uppercase                     | L          |
| U+0061..U+007A   | ASCII lowercase                     | L          |
| U+00C0..U+00FF   | Latin-1 Supplement letters          | L (mostly) |
| U+0100..U+024F   | Latin Extended-A + Latin Extended-B | L          |

The M6 baseline folds U+00D7 (×) and U+00F7 (÷) into L (the full UCD
assigns them class ON, "Other Neutral"); this is a minor divergence
documented in Further Work.

### R (1) -- Right-to-Left

| Range            | Script / block                      | TR#9 class     |
|------------------|-------------------------------------|----------------|
| U+0590..U+05FF   | Hebrew (letters + cantillation)     | R + NSM        |
| U+0600..U+06FF   | Arabic (except digits, see AN)      | AL + NSM       |
| U+FB50..U+FDFF   | Arabic Presentation Forms-A         | AL             |

The M6 baseline folds AL (Arabic Letter) into R and NSM (Non-Spacing
Mark) into the parent block's class; this is a simplification for the
reduced classifier and is documented in Further Work.

### AN (3) -- Arabic Number

| Range            | Script / block                      | TR#9 class |
|------------------|-------------------------------------|------------|
| U+0660..U+0669   | Arabic-Indic digits (٠..٩)          | AN         |
| U+06F0..U+06F9   | Extended Arabic-Indic digits (۰..۹) | AN         |

Both ranges nest inside the Arabic block (U+0600..U+06FF). The
classifier MUST check these before the generic Arabic R range, or
the digits would mis-classify as R. See the "Ordering" section.

### EN (4) -- European Number

| Range            | Script / block                      | TR#9 class |
|------------------|-------------------------------------|------------|
| U+0030..U+0039   | ASCII digits (0..9)                 | EN         |

### N (2) -- Neutral / default fallback

Every code point not in the four sets above. This includes ASCII
space + punctuation, Latin-1 non-letter cps outside U+00C0..U+00FF,
Greek (U+0370..U+03FF), Cyrillic (U+0400..U+04FF), every CJK block,
emoji, combining marks outside the Hebrew/Arabic ranges, control
characters, and every supplementary-plane cp.

In the full UAX #9 these decompose into finer classes (ES, ET, CS,
NSM, BN, B, S, WS, ON). The M6 baseline folds all of them into N for
run-level aggregation; M6.1 adds the split.

### Ordering

`_bidi_class` dispatches ranges in this order, with early return on
the first match:

```
EN (U+0030..0039)
L  (U+0041..005A)
L  (U+0061..007A)
L  (U+00C0..00FF)
L  (U+0100..024F)
R  (U+0590..05FF)
AN (U+0660..0669)
AN (U+06F0..06F9)
R  (U+0600..06FF)
R  (U+FB50..FDFF)
N  (default)
```

The AN ranges are checked BEFORE the generic Arabic R range because
the AN digits are nested inside the Arabic block; a straight-line
cascade with early return handles the overlap correctly.

## Pipeline (two phases)

`_bidi_class` is a straight-line range classifier -- no pipeline;
one branch per range. `_bidi_runs` adds two iteration layers:

### `_bidi_runs` state

```
cursor         -- byte offset into bytes_ptr (next cluster to read)
run_start      -- byte offset at which the current run began
run_class      -- BIDI_CLASS of the current run (0xFF = no run yet)
runs_emitted   -- number of 16-byte runs already written
```

### `_bidi_runs` iteration

```
loop:
  if cursor == bytes_len:
    goto flush
  (next_cursor, status) := _gc_next(bytes_ptr, bytes_len, cursor)
  if status == EOF:          goto flush
  if status == INVALID_UTF8: return (runs_emitted, INVALID_UTF8)
  cp         := utf8_decode_cp(bytes_ptr + cursor, bytes_len - cursor)
  class      := _bidi_class(cp)
  if run_class == 0xFF:          -- no current run
    run_class := class
    run_start := cursor
  else if class != run_class:    -- class change: flush + restart
    if runs_emitted == out_cap: return (runs_emitted, OUT_TOO_SMALL)
    emit {run_start, cursor, run_class} at out_runs[runs_emitted]
    runs_emitted += 1
    run_class := class
    run_start := cursor
  -- else: same class, extend implicitly
  cursor := next_cursor
  continue loop

flush:
  if run_class != 0xFF:
    if runs_emitted == out_cap: return (runs_emitted, OUT_TOO_SMALL)
    emit {run_start, cursor, run_class} at out_runs[runs_emitted]
    runs_emitted += 1
  return (runs_emitted, OK)
```

The grapheme-cluster iteration layer matters: for an input like
"a + U+0301" (precomposed á in NFD), `_gc_next` gives us ONE cluster
for the base + mark pair. Classifying only the FIRST cp of the
cluster gives the base's class (L for 'a'), and the combining mark
inside the cluster is implicitly subsumed. This agrees with the
intuition "a user-perceived character has a single bidi direction"
and avoids run-boundary spurious splits around combining marks.

### Run entry layout (16 bytes)

```
offset 0..3   byte_start (u32 LE)
offset 4..7   byte_end   (u32 LE)
offset 8      class      (u8)   -- 0=L, 1=R, 2=N, 3=AN, 4=EN
offset 9..15  padding    (u8[7]) -- zeroed
```

Stride 16 bytes = cache-line divisor; a caller indexes
`out_runs_ptr[i]` with `shl i, 4`. Written as two qword stores:

```
qword 0 at (out_runs + i*16 + 0)  = (byte_end << 32) | byte_start
qword 1 at (out_runs + i*16 + 8)  = class  (low byte; rest zero)
```

Both qwords are little-endian x86 stores, so the byte_start / byte_end
fields land at the specified offsets without any byte-swap.

## Error band

`BIDI_INVALID_UTF8` sits at 0xFFFFE760 and `BIDI_OUT_TOO_SMALL` at
0xFFFFE761, in the seventh 16-wide aligned user-space slot
(0xFFFFE760..0xFFFFE76F). The library's bands skip
0xFFFFE740..0xFFFFE74F (claimed by the adaptive_rate sample's policy
module, G9.M6) and sit above the M1..M5 slices. Two slots are used
at M6; the remaining 14 are reserved for later bidi-layer error kinds
(BIDI_PARAGRAPH_UNKNOWN at M6.2 once paragraph-level resolution lands;
BIDI_EMBEDDING_LIMIT_EXCEEDED at M6.3 once LRE/RLE/PDF stack-tracking
lands).

The public API packs the status code (0=OK, 1=OUT_TOO_SMALL,
2=INVALID_UTF8) into the low 8 bits of the packed return rather than
returning the raw band value, matching the `_norm_nf{c,d,kc,kd}` /
`_coll_sort_key` / `_width_str` convention. The internal band
constants are visible through `pub let BIDI_INVALID_UTF8` and
`BIDI_OUT_TOO_SMALL` for consumers wiring their own error-propagation
paths.

## OUT_TOO_SMALL recovery semantics

`_bidi_runs` DIVERGES from `_norm_nf{c,d,kc,kd}` / `_coll_sort_key`
on buffer-underrun behaviour:

- Normalize / collation: ATOMIC failure -- on OUT_TOO_SMALL the
  output buffer is left as the caller sees fit (contents past the
  underrun are stale), and `out_bytes_written == 0`. The caller
  re-invokes with a larger buffer; no partial progress is reusable.

- Bidi runs: PARTIAL commit -- on OUT_TOO_SMALL the output buffer
  holds every run successfully written before the capacity hit,
  and `runs_emitted` reports the count. The caller inspects
  `out_runs[runs_emitted - 1].byte_end` to find the resume point
  and re-invokes `_bidi_runs(bytes_ptr + resume, bytes_len - resume,
  out_runs + runs_emitted*16, out_cap - runs_emitted)`.

The divergence is deliberate: run arrays grow monotonically and have
a natural chunk boundary (the last emitted run), so partial commit
costs nothing and lets a consumer stream large inputs through a
small fixed-size buffer. Normalize / collation outputs are byte
streams without a reusable boundary mid-codepoint, so atomic failure
is the simpler contract.

## INVALID_UTF8 recovery semantics

`_bidi_runs` propagates INVALID_UTF8 by:

1. NOT flushing the current open run. Emitted runs always end at a
   valid cluster boundary (invariant preserved).
2. Returning the accumulated `runs_emitted` count (reflects runs
   committed BEFORE the malformed byte).
3. Setting status=2 in the low 8 bits.

A caller that wants fail-fast UTF-8 detection runs `utf8_is_valid`
first. A caller that wants to recover and reclassify past the
malformed byte can call `_bidi_runs` repeatedly, advancing
`bytes_ptr` past each INVALID offset -- the proptest documents the
pattern via its "class invariant" witnesses.

## Further work

| Milestone | Scope                                                                                              |
|-----------|----------------------------------------------------------------------------------------------------|
| M6.1      | Full 23-class BIDI_CLASS split (AL / NSM / ES / ET / CS / ON / WS / BN / B / S)                     |
| M6.2      | Paragraph-level resolution (TR#9 §P1 first-strong-character algorithm)                              |
| M6.3      | Explicit directional embeddings (LRE / RLE / LRO / RLO / PDF / LRI / RLI / FSI / PDI, TR#9 §3.3.2)   |
| M6.4      | Mirroring pairs (TR#9 §3.4; needs UCD BidiMirroring.txt)                                            |

### M6.1 full 23-class split

Expands `_bidi_class` to return every UAX #9 class. The reduced M6
baseline collapses:
- AL into R (Arabic Letter has a distinct NEUTRAL/NUMBER resolution
  rule in TR#9 §N0, but renders RTL exactly like R; M6 is close
  enough for run-level aggregation but wrong for the N0 rule).
- NSM into the parent block's class (Hebrew / Arabic cantillation
  marks classify as R rather than NSM, which is wrong for the N0
  rule but right for run-level grouping).
- ES / ET / CS / ON / WS / BN / B / S into N.

M6.1 lifts these restrictions. The reduced subset at M6 remains the
return value of a renamed `_bidi_class_reduced(cp)` for consumers
that only care about run-level direction.

### M6.2 paragraph-level resolution (TR#9 §P1)

Adds `_bidi_paragraph_direction(bytes_ptr, bytes_len) -> u64` that
runs the first-strong-character algorithm: scan the input, find the
first cp whose class is L / R / AL, and return its direction. If no
such cp is found, return L (the default). Needed for correctly
mirroring neutral characters (brackets, math symbols) in paragraphs
that start with a strong RTL character.

The current `_bidi_runs` emits raw class-grouped runs; a caller can
approximate paragraph direction by inspecting the first non-N run.
M6.2 formalises this.

### M6.3 explicit directional embeddings

Adds state tracking for the LRE / RLE / LRO / RLO / PDF / LRI / RLI
/ FSI / PDI set (TR#9 §3.3.2). These are rare in terminal input
today -- most text uses either implicit direction (L or R baseline)
or standalone cps -- but any content copy-pasted from a mixed-
direction document (an RTL email with an embedded LTR URL, say) uses
them. M6.3 lands a stack-tracking state machine with a depth limit
(TR#9 §3.3.2 §BD1 sets this at 125 levels; the M6.3 implementation
is likely to cap at 16 or 32 for terminal-ergonomic reasons).

### M6.4 mirroring pairs

Loads UCD BidiMirroring.txt and exposes
`_bidi_mirror(cp) -> cp_or_cp` for the ~700 bracket + math-symbol
pairs that mirror inside RTL runs. The caller (terminal renderer)
applies the mirror AFTER run reordering.

## Fingerprint goldens (8 TAG lines)

See `tests/fingerprints/bidi.golden` for the exact bytes. OUTPUT_HEX
encodes concatenated 16-byte run entries (32 hex nibbles per run)
rather than the packed u64 return; this gives the fingerprint maximal
discriminative power on each case's run array. Covered cases:

- **BIDI_PURE_LTR**: `"hello"` → 1 run `{0, 5, L=0}`. Exercises the
  single-run no-class-change path.
- **BIDI_PURE_RTL**: `"שלום"` (U+05E9, U+05DC, U+05D5, U+05DD; 8
  bytes) → 1 run `{0, 8, R=1}`. Each Hebrew letter is 2 UTF-8 bytes
  per RFC 3629; the 4-letter string spans bytes 0..8.
- **BIDI_MIXED**: `"abcשלום"` (11 bytes) → 2 runs `{0, 3, L=0}`,
  `{3, 11, R=1}`. Exercises the L→R class change at the boundary
  between ASCII and Hebrew.
- **BIDI_NUMBER**: `"123"` → 1 run `{0, 3, EN=4}`. Exercises the
  EN classification path.
- **BIDI_ARABIC_DIGITS**: `"٠١٢"` (U+0660, U+0661, U+0662; 6 bytes)
  → 1 run `{0, 6, AN=3}`. Exercises the AN classification path
  (digits peeled from the Arabic R block).
- **BIDI_NEUTRAL**: `" "` (ASCII space, 1 byte) → 1 run `{0, 1, N=2}`.
  Exercises the default fallback N class.
- **BIDI_EMPTY**: `""` → 0 runs (empty OUTPUT_HEX). Exercises the
  immediate-EOF path through `_gc_next`.
- **BIDI_SINGLE_L**: `"x"` (1 byte) → 1 run `{0, 1, L=0}`. Exercises
  the ASCII lowercase path for a minimal non-empty input.

## Proptest witnesses (3 invariants)

See `tests/proptest_bidi.pdx`. A single witness input "abcשלום"
(11 bytes) exercises every invariant on the same mixed-direction
string; the aggregator state machine is driven through its init,
extend, and flush paths once per invariant case:

- **Coverage** (`pb_case_coverage`): the emitted runs cover
  `[0, bytes_len)` exactly, with no gap and no overlap. For the
  witness: 2 runs, `run[0] = {0, 3, L}`, `run[1] = {3, 11, R}`.
  Checks that `run[0].byte_start == 0`, `run[0].byte_end == 3`,
  `run[1].byte_start == 3` (equal to `run[0].byte_end` -- no gap,
  no overlap), and `run[1].byte_end == 11` (equal to `bytes_len`).
- **Non-empty** (`pb_case_nonempty`): every emitted run has
  `byte_end > byte_start`. The aggregator never produces an empty
  run because a new run is initialised only on the first cluster
  of a new class and extended per cluster; `byte_end` at flush time
  is always strictly greater than `byte_start`. For the witness,
  both runs have end > start (3 > 0 and 11 > 3).
- **Monotone class** (`pb_case_monotone`): consecutive runs carry
  different class values. If `run[i].class == run[i+1].class`, the
  aggregator should have extended instead of flushing + restarting.
  For the witness, `run[0].class == L (0)` and `run[1].class == R
  (1)`, so 0 != 1 and the invariant holds.

Umbrella `pb_run_all` runs them all in declaration order; first
non-zero fail code wins.

Fail codes live in the 0xFFFFEDCx band, extending the existing
`TestLexer` / `ProptestGrapheme` / `ProptestNormalize` /
`ProptestCollation` / `ProptestWidth` family (skips the VKBench
EDAx and VKFeatures EDBx kernel bands):

```
0xFFFFEDC1   PB_FAIL_COVERAGE
0xFFFFEDC2   PB_FAIL_NONEMPTY
0xFFFFEDC3   PB_FAIL_MONOTONE
```

## Benches

None at M6. A bench harness (`benches/bidi.pdx`) lands at M6.1
alongside the full-23-class split, so the per-cp cost of the range
dispatch can be compared against the eventual sparse-trie lookup.

## paideia-as encoder posture

Every rule in `src/width.pdx`'s header applies verbatim:

- No `test rN, rN`; every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64`; the only masks used (0xFF for status / class
  / byte_start extraction, and 0xFFFFFFFF for u32 byte_start
  extraction in the proptest) fit imm32 sign-safe.
- No 2-op `imul r, imm`; the per-run output offset uses shift
  (`shl r11, 4` -- stride 16), never multiply.
- No multiline `pub let = "..."`.
- Module basename `Bidi` matches `bidi.pdx` (verified at write time;
  Wave 93's regression caught the same class of pitfall in the
  pdxb_mount module and the current task citation re-flags it).
- Labels prefixed `bidi_`.
- All `cmp reg, imm` immediates <= 0xFDFF (Arabic Pres Forms-A upper
  bound), well under 0x7FFFFFFF so direct `cmp` is sign-extension-safe.
  No MOVABS staging needed.
- SysV alignment preserved through push count parity:
  `_bidi_class` is a pure leaf with no pushes; `_bidi_runs` has
  five callee-save pushes (rbx, r12, r13, r14, r15) + sub rsp 32
  giving `(8 + 40 + 32) mod 16 == 0` pre-CALL.
- No `add reg, [mem]` anywhere.
- Output writes are qword-granular (two 8-byte stores per 16-byte
  run entry), so no byte writes either; `mov_b` is used only in the
  proptest's fixture-population path.

## Upstream links

- paideia-os#2480 (R131 Unicode umbrella).
- paideia-os#2612 (M1 UTF-8).
- paideia-os#2613 (M2 grapheme).
- paideia-os#2614 (M3 normalize).
- paideia-os#2615 (M4 collation).
- paideia-os#2616 (M5 width).
- paideia-os#2617 (THIS M6 ticket).
- Rust-side analog: future `paideia-as-unicode::bidi` module (M6.1+
  lands this). The reduced five-class format described here will be
  the Rust side's import target.

## References

- UAX #9 Rev. 48: Unicode Bidirectional Algorithm.
  https://unicode.org/reports/tr9/
- Unicode 15.1.0 DerivedBidiClass.txt:
  https://www.unicode.org/Public/15.1.0/ucd/extracted/DerivedBidiClass.txt
- Unicode 15.1.0 BidiBrackets.txt (for M6.4 mirroring):
  https://www.unicode.org/Public/15.1.0/ucd/BidiBrackets.txt
- Unicode 15.1.0 BidiMirroring.txt (for M6.4 mirroring):
  https://www.unicode.org/Public/15.1.0/ucd/BidiMirroring.txt
