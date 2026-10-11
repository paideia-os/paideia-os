# libpdx-unicode-tables Width (R131.M5)

## Status

**Wave:** R131 (semantic shell -- Unicode substrate umbrella,
paideia-os#2480).
**Milestone:** M5 (display width, UAX #11 reduced EAW,
paideia-os#2616).
**Library version at landing:** 1.4.0.
**Date:** 2026-10-11.

## Scope

M5 adds the UAX #11 East Asian Width classifier to the user-space
Unicode library the shell, pds, and the GPU-native terminal all link.
Two public primitives:

```
_width_char(cp)                        -> u64 (0, 1, or 2)
_width_str(bytes_ptr, bytes_len)       -> packed_u64
```

Return shapes:

- `_width_char`: a u64 in {0, 1, 2}. No error band -- the caller has
  already decoded the cp (via `utf8_decode_cp` or `_gc_next`), so a
  width-of-a-known-cp call cannot fail. Zero means "contributes no
  columns" (combining mark, ZWJ, variation selector, control char).
  One is "a single monospace column" (narrow, the overwhelming default).
  Two is "two monospace columns" (wide East Asian ideographs, Hangul
  syllables, fullwidth characters, emoji).
- `_width_str`: `(total_width << 32) | status` with status in {0=OK,
  2=INVALID_UTF8}. The total is the sum of each grapheme cluster's
  base-cp width; combining marks contribute zero and never widen their
  cluster. On INVALID_UTF8 the total reflects what was accumulated
  before the malformed byte.

Both functions are pure leaf-with-nested-call -- no capability bind,
no syscall. `_width_char` is a pure leaf (no nested call at all);
`_width_str` nests `_gc_next`, `utf8_decode_cp`, and `_width_char`.

M5 is the FIFTH milestone of this library and the SECOND one (after
M3 normalisation) that could carry a large reduced-UCD table. Where
M3 encoded ~250 explicit decomposition entries for Latin-1 Supplement
+ Latin Extended-A + Fullwidth-ASCII, M5 encodes zero explicit entries
and relies entirely on range dispatch: the full UAX #11 EAW
EastAsianWidth.txt classes ~140,000 code points, but the reduced M5
baseline covers only the nine wide-script bands below. The reduced
baseline suffices for the shell's prompt renderer, pds's text-column
reflow, and the GPU-native terminal's grid builder on Western +
East-Asian text today; later milestones (M5.1+) grow the table set
script by script.

## Reduced EAW table (R131.M5 CJK + emoji baseline)

### Width 0 (zero-width)

| Range            | Property                | Rationale                                         |
|------------------|-------------------------|---------------------------------------------------|
| U+0000..U+001F   | C0 controls             | TR#11 class N; render as zero (no cursor advance) |
| U+007F..U+009F   | DEL + C1 controls       | TR#11 class N; same posture                        |
| U+0300..U+036F   | Latin combining marks   | TR#11 class A (as "non-spacing"); shared with M2  |
| U+200D           | ZWJ                     | TR#11 class N; joiner contributes no column       |
| U+FE00..U+FE0F   | Variation Selectors     | TR#11 class N; VS1..VS16 are non-spacing          |

### Width 2 (wide / fullwidth)

| Range             | Script / block                      | TR#11 class |
|-------------------|-------------------------------------|-------------|
| U+3000..U+303E    | CJK Symbols and Punctuation         | W           |
| U+3041..U+30FF    | Hiragana + Katakana                 | W           |
| U+3400..U+4DBF    | CJK Unified Ideographs Extension A  | W           |
| U+4E00..U+9FFF    | CJK Unified Ideographs              | W           |
| U+AC00..U+D7A3    | Hangul Syllables                    | W           |
| U+F900..U+FAFF    | CJK Compatibility Ideographs        | W           |
| U+FF01..U+FF60    | Fullwidth ASCII                     | F           |
| U+FFE0..U+FFE6    | Fullwidth signs (¢ £ ¥ ￦ ...)       | F           |
| U+1F300..U+1F9FF  | Emoji (Pictographic approx)         | W           |

### Width 1 (narrow default)

Every code point not in the two sets above: printable ASCII
(0x20..0x7E), Latin-1 Supplement non-controls, Latin Extended-A,
Greek, Cyrillic, Hebrew, Arabic, Devanagari, Thai and every other
BMP script, plus every supplementary-plane cp outside the emoji range.

## Pipeline (one phase)

`_width_char` is a straight-line range classifier -- no pipeline;
one branch per range. `_width_str` adds one iteration layer on top:

### `_width_str` iteration

```
cursor := 0
total  := 0
loop:
  (next_cursor, status) := _gc_next(bytes_ptr, bytes_len, cursor)
  if status == EOF:          return (total, OK)
  if status == INVALID_UTF8: return (total, INVALID_UTF8)
  cp              := utf8_decode_cp(bytes_ptr + cursor, bytes_len - cursor)
  w               := _width_char(cp)
  total           := total + w
  cursor          := next_cursor
  continue loop
```

The grapheme-cluster iteration layer matters: the TR#11-correct
answer for "a + U+0301" (precomposed á in NFD) is one column, not two.
`_gc_next` gives us one cluster for the base + mark pair; decoding
only the FIRST cp of the cluster gives the base's width (1 for 'a')
and the mark's zero-width contribution is implicit (we don't look at
it at all). This happens to agree with the alternative "iterate cps,
mark contributes 0" implementation; the cluster-first approach is
more TR#11-aligned and makes the "width of one user-perceived
character" semantics obvious.

## Error band

`W_INVALID_UTF8` sits at 0xFFFFE750, in the sixth 16-wide aligned
user-space slot (0xFFFFE750..0xFFFFE75F). The library's bands skip
0xFFFFE740..0xFFFFE74F because that slice is already claimed by the
adaptive_rate sample's policy module (`src/samples/adaptive_rate/
policy.pdx`, G9.M6 POLICY_* sentinels). The width band sits above the
M1 (0xFFFFE700..0F), M2 (0xFFFFE710..1F), M3 (0xFFFFE720..2F), and
M4 (0xFFFFE730..3F) library slices. Only one slot is used at M5; the
remaining 15 are reserved for later width-layer error kinds
(`W_LOCALE_UNKNOWN` once per-locale Ambiguous handling lands at M5.1).

The public API packs the status code (0=OK, 2=INVALID_UTF8) into the
low 8 bits of the packed return rather than returning the raw band
value, matching the `_norm_nf{c,d,kc,kd}` / `_coll_sort_key` /
`_gc_next` convention. The internal band constant is visible through
`pub let W_INVALID_UTF8` for consumers wiring their own
error-propagation paths.

## Ambiguous width policy

UAX #11 defines six classes: Narrow (Na), Halfwidth (H), Wide (W),
Fullwidth (F), Ambiguous (A), and Neutral (N). The reduced M5
baseline treats:

- **Na, H, N**: narrow (width 1) -- the default fallthrough.
- **W, F**: wide (width 2) -- the explicit width-2 ranges above.
- **A**: narrow (width 1) at M5 -- locale-insensitive.

The Ambiguous class covers code points whose terminal rendering is
locale-dependent: a Western terminal renders them in one column, a
CJK terminal renders them in two. UAX #11 §4 names examples (§, ‒,
box-drawing U+2500..U+257F, Greek letters as mathematical symbols).

The M5 posture is "treat Ambiguous as narrow unconditionally" because:

1. The three in-tree consumer sites (shell prompt, pds listing, GPU
   terminal grid) all run with a Western-locale default today.
2. Silently widening Ambiguous to 2 would misalign every Western
   terminal grid by half a column for every em-dash, box-drawing
   character, or Greek letter -- a visible regression for a theoretical
   future-locale correctness.
3. The locale-aware path lands at M5.1 (see Further Work) and
   introduces a second entry point rather than changing `_width_char`'s
   contract.

## Further work

| Milestone | Scope                                                                                           |
|-----------|-------------------------------------------------------------------------------------------------|
| M5.1      | Locale-sensitive Ambiguous handling via `_width_char_lc(cp, locale) -> u64`                      |
| M5.2      | Full UCD EastAsianWidth.txt load (sparse trie)                                                   |
| M5.3      | Extended_Pictographic trie (~1500 cps) replacing the single-range approximation                  |
| M5.4      | Hangul Jamo (U+1100..U+11FF) proper handling: L and V are wide standalone, T is narrow combining |

### M5.1 locale-sensitive Ambiguous

Adds a second entry point:

```
_width_char_lc(cp: u64, locale: u64) -> u64
```

The `locale` parameter is a 24-bit code taken from the paideia-os
locale constant table (ja_JP = 0x6A6170, zh_CN = 0x7A6863, ko_KR =
0x6B6F72, en_US = 0x656E7573, ...). For `locale` matching a listed
East Asian locale, Ambiguous cps return 2; otherwise 1.

The Ambiguous table itself (currently zero cps at M5) lands as a sparse
trie compiled IN as `[u8; N]` bindings, same shape as the normalize
decomposition table at M3.

### M5.2 full UCD EastAsianWidth.txt load

Replaces the hand-coded range table in `_width_char` with a sparser
trie. The current CJK + emoji baseline is enough for every consumer
site in the paideia-os tree today; M5.2 adds Myanmar, Khmer, Tibetan,
Mongolian, and other complex-shaping BMP scripts that have mixed
width classes in the full UCD.

### M5.3 Extended_Pictographic trie

Replaces the single range U+1F300..U+1F9FF with the sparse ~1500-cp
Extended_Pictographic property from UCD emoji-data.txt. Shared data
source with M2.2's Grapheme classifier trie.

### M5.4 Hangul Jamo

TR#11 §5 says L (leading consonant, U+1100..U+1159) and V (vowel,
U+1160..U+11A2) are wide=2 even when they appear standalone (not
composed into a syllable); T (trailing consonant, U+11A8..U+11F9) is
narrow because it's a combining form. M5.4 adds the three-range
dispatch to `_width_char`.

## Fingerprint goldens (8 TAG lines)

See `tests/fingerprints/width.golden` for the exact bytes. Covered
cases:

- **W_ASCII**: `"hello"` → 5. Five narrow ASCII cps, each width 1.
  Exercises the narrow default fallthrough.
- **W_CJK**: `"漢字"` (U+6F22 + U+5B57) → 4. Two cps in the
  U+4E00..U+9FFF CJK Unified Ideographs range.
- **W_FULLWIDTH**: `"ＡＢ"` (U+FF21 + U+FF22) → 4. Two cps in the
  U+FF01..U+FF60 Fullwidth ASCII range.
- **W_COMBINING**: `"a" + U+0301` → 1. One grapheme cluster: base
  'a' = 1, combining mark U+0301 = 0. Exercises the per-cluster
  accumulation (not per-cp).
- **W_EMOJI**: `"🙂"` (U+1F642) → 2. One cp in the U+1F300..1F9FF
  emoji range.
- **W_MIXED**: `"a漢"` → 3. Two clusters: 1 + 2.
- **W_EMPTY**: `""` → 0. Empty-input EOF path.
- **W_CONTROL**: `"a\x1Bb"` → 2. ESC (0x1B) is a C0 control; GB4/GB5
  split the input into three single-cp clusters ('a', ESC, 'b') with
  widths 1 + 0 + 1 = 2.

## Proptest witnesses (3 invariants)

See `tests/proptest_width.pdx`:

- **Non-negative** (`pw_case_nonneg`): `_width_str` returns status=0
  AND width=5 for the ASCII input "hello". The u64 return cannot
  numerically be negative, so this invariant collapses to "status is
  OK and the width equals the hand-computed sum". Guards against
  mis-classification of ASCII as width-0 (controls) or width-2
  (fullwidth) and against false-positive INVALID_UTF8 from
  `_gc_next`.
- **Additive** (`pw_case_additive`): `width("abc") == width("ab") +
  width("c") = 3` for ASCII inputs. Not true in general for Unicode
  because grapheme-cluster joining can merge a trailing EXTEND of
  the first string with the leading base of the second; for ASCII
  every cp except CR/LF starts its own cluster per GB999 so the
  invariant holds.
- **Empty** (`pw_case_empty`): `_width_str("", 0)` returns 0 (status
  and width both zero). Exercises `_gc_next`'s immediate-EOF path.

Umbrella `pw_run_all` runs them all in declaration order; first
non-zero fail code wins.

Fail codes live in the 0xFFFFED9x band, extending the existing
`TestLexer` / `ProptestGrapheme` / `ProptestNormalize` /
`ProptestCollation` family:

```
0xFFFFED91   PW_FAIL_NONNEG
0xFFFFED92   PW_FAIL_ADDITIVE
0xFFFFED93   PW_FAIL_EMPTY
```

## Benches

None at M5. A bench harness (`benches/width.pdx`) lands at M5.1
alongside the locale-sensitive Ambiguous work, so the per-call cost
of the range dispatch can be compared against the eventual trie
lookup.

## paideia-as encoder posture

Every rule in `src/grapheme.pdx`'s header applies verbatim:

- No `test rN, rN`; every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64`; the only mask used (0xFF for status extraction)
  fits imm32 sign-safe.
- No 2-op `imul r, imm`; the classifier uses only straight-line range
  dispatch (no indexing arithmetic), and `_width_str` accumulates via
  `add r14, rax`.
- No multiline `pub let = "..."`.
- Module basename `Width` matches `width.pdx`.
- Labels prefixed `w_`.
- All `cmp reg, imm` immediates <= 0x1F9FF (the emoji upper bound),
  well under 0x7FFFFFFF so direct `cmp` is sign-extension-safe.
  No MOVABS staging needed.
- SysV alignment preserved through push count parity:
  `_width_char` is a pure leaf with no pushes; `_width_str` has five
  callee-save pushes (rbx, r12, r13, r14, r15) giving
  `(8 + 40) mod 16 == 0` pre-CALL.
- No `add reg, [mem]` anywhere.

## Upstream links

- paideia-os#2480 (R131 Unicode umbrella).
- paideia-os#2612 (M1 UTF-8).
- paideia-os#2613 (M2 grapheme).
- paideia-os#2614 (M3 normalize).
- paideia-os#2615 (M4 collation).
- paideia-os#2616 (THIS M5 ticket).
- Rust-side analog: future `paideia-as-unicode::width` module (M5.1+
  lands this). The reduced EAW format described here will be the
  Rust side's import target.

## References

- UAX #11 Rev. 36: East Asian Width.
  https://unicode.org/reports/tr11/
- Unicode 15.1.0 EastAsianWidth.txt:
  https://www.unicode.org/Public/15.1.0/ucd/EastAsianWidth.txt
- UCD emoji-data.txt (Extended_Pictographic):
  https://www.unicode.org/Public/15.1.0/ucd/emoji/emoji-data.txt
- Markus Kuhn, "Unicode in East Asian text" (wcwidth background):
  https://www.cl.cam.ac.uk/~mgk25/ucs/wcwidth.c
