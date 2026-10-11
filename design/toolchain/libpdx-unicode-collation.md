# libpdx-unicode-tables Collation (R131.M4)

## Status

**Wave:** R131 (semantic shell -- Unicode substrate umbrella,
paideia-os#2480).
**Milestone:** M4 (UCA collation, UTS #10 reduced DUCET,
paideia-os#2615).
**Library version at landing:** 1.3.0.
**Date:** 2026-10-11.

## Scope

M4 adds the Unicode Collation Algorithm (per UTS #10 Rev. 46) to the
user-space Unicode library the shell, pds, and the GPU-native terminal
all link. Two public primitives:

```
_coll_compare(a_ptr, a_len, b_ptr, b_len) -> i64
_coll_sort_key(bytes_ptr, bytes_len, out_ptr, out_cap) -> packed_u64
```

Return shapes:

- `_coll_compare`: an i64 (-1 / 0 / 1). `-1` is the two's-complement
  all-ones pattern (0xFFFFFFFFFFFFFFFF) and compares as negative under
  signed `cmp`. Zero means equal under the reduced DUCET; positive
  means a > b.
- `_coll_sort_key`: `(out_bytes_written << 32) | status` with status in
  {0=OK, 1=OUT_TOO_SMALL, 2=INVALID_UTF8}. The materialised blob is
  byte-wise `memcmp`-comparable: two inputs' keys agree on
  `_coll_compare`'s sign.

Every function is a pure leaf-with-nested-call -- no capability bind,
no syscall.

M4 is the SECOND milestone of this library to carry a reduced UCD
table set (after M3 normalisation). Where M3 encoded the full
canonical / compatibility decomposition data for Latin-1 Supplement +
Latin Extended-A + Fullwidth-ASCII, M4 encodes a much thinner slice:
the DUCET's per-code-point `(L1, L2, L3)` weight triples for printable
ASCII plus a 13-entry combining-mark table.  The full DUCET
(allkeys.txt in Unicode 15.1.0) is ~27,000 entries; shipping all of it
at M4 would multiply the library's `.rodata` footprint by ~30x and
delay every consumer of the shell / pds / terminal sort path. The
reduced baseline suffices for the shell's own `ls`, pds's listing, and
the terminal's selection-sort primitives; later milestones (M4.2+)
grow the table set script by script.

## Pipeline (reduced UCA, 4 phases)

The implementation follows UTS #10 §9 (the four-phase pipeline) adapted
for the reduced DUCET.

### Phase 1: Normalise to NFD

Calls `_norm_nfd` into a 4-KiB `.bss` scratch buffer (`_coll_nfd_scratch`).
This decomposes precomposed letters (á, ć, ñ, ...) into base + mark
pairs so the classifier below never has to carry a precomposed-cp
table of its own. All four forms (NFC/NFD/NFKC/NFKD) agree on the base
collation element set after this step; using NFD specifically gives us
the UCA-canonical byte stream that matches CLDR root collation.

An empty input short-circuits to a 0-byte output here.

A UTF-8 error returns status=2 (INVALID_UTF8) to the caller of
`_coll_sort_key`. The compare path (`_coll_compare`) catches this and
substitutes a 0-length key for the invalid side, so the compare
always produces an order.

### Phase 2: Build Collation Elements

Walks the NFD byte stream one code point at a time via
`utf8_decode_cp`. For each cp:

1. Call `_coll_classify(cp)` to produce a packed `(L1, L2, L3)`
   triple.
2. Append the triple as a single u64 qword to the CE scratch array
   (`_coll_ce_scratch`, 8 KiB = 1024 x 8-byte entries).

Each CE is one qword:

```
bits [15:0]   L3   (0..0xFFFF, 0 == ignorable at this level)
bits [31:16]  L2   (0..0xFFFF, 0 == ignorable at this level)
bits [47:32]  L1   (0..0xFFFF, 0 == ignorable at this level)
bits [63:48]  reserved (zero)
```

CE-array overflow (count >= 1024) returns status=1 (OUT_TOO_SMALL),
treated by the caller as "input too long" rather than a UTF-8 fault.

### Phase 3: Form Sort Key

Three passes over the CE array, each pass producing one level of the
key:

```
pass 1: for each CE, if L1 != 0, emit big-endian u16(L1)
         emit u16(0x0000)                    -- L1 -> L2 separator
pass 2: for each CE, if L2 != 0, emit big-endian u16(L2)
         emit u16(0x0000)                    -- L2 -> L3 separator
pass 3: for each CE, if L3 != 0, emit big-endian u16(L3)
```

No trailing separator after L3.

Big-endian encoding is essential: it makes byte-wise `memcmp` agree
with weight comparison. A key's bytes thus split naturally into
levels at the 0x0000 markers, and a shorter level stream (e.g. no L2
diacritics on an all-ASCII input) still sorts correctly against a
longer stream because the 0x0000 separator is less than any non-zero
weight byte at that position.

Capacity gating is per-byte: on the first byte that would exceed
`out_cap`, the function returns status=1 (OUT_TOO_SMALL) with
`out_bytes_written=0`. The output buffer may contain partial state
at that point but the atomic-failure contract tells the caller to
ignore the output.

### Phase 4: Compare

The compare entry point (`_coll_compare`) materialises both inputs'
keys into two 8-KiB compare-local scratch buffers (one per side),
then calls `_coll_keycmp` for a byte-wise `memcmp` with a
shorter-wins tiebreaker. The result (-1, 0, 1) is returned directly
as the i64.

If either `_coll_sort_key` call returns a non-zero status, the
compare treats that side as having a 0-length key. A sort routine
embedded in a shell command path should never crash on bad bytes;
callers that need fail-fast UTF-8 validation should call
`utf8_is_valid` first.

## Reduced DUCET at M4

### ASCII printable U+0020..U+007E

The classifier branches over cp ranges and computes L1 algorithmically
inside each band:

```
U+0020 (space)        L1 = 0x0209         L2 = 0x0020  L3 = 0x0002
U+0021..U+002F        L1 = 0x0210 + (cp-0x21)*2  L2 = 0x0020  L3 = 0x0002
U+0030..U+0039 (digit) L1 = 0x1200 + (cp-0x30)*2  L2 = 0x0020  L3 = 0x0002
U+003A..U+0040        L1 = 0x0280 + (cp-0x3A)*2  L2 = 0x0020  L3 = 0x0002
U+0041..U+005A (A-Z)  L1 = 0x1C00 + (cp-0x41)*4  L2 = 0x0020  L3 = 0x0008
U+005B..U+0060        L1 = 0x0300 + (cp-0x5B)*2  L2 = 0x0020  L3 = 0x0002
U+0061..U+007A (a-z)  L1 = 0x1C00 + (cp-0x61)*4  L2 = 0x0020  L3 = 0x0002
U+007B..U+007E        L1 = 0x0320 + (cp-0x7B)*2  L2 = 0x0020  L3 = 0x0002
```

The letter stride is 4 (not 2) so each letter's L1 is distinct from
every other letter's L1 (e.g. 'a'=0x1C00, 'b'=0x1C04, 'c'=0x1C08, ...).
Upper and lower letters share L1 within each case band (0x1C00 for 'a'
and 'A' both), so they are L1-tied; the L3 difference (0x0002 vs
0x0008) breaks the tie with lowercase before uppercase, per UTS #10
§7.3 convention.

### Combining marks U+0300..U+036F

A 13-entry sparse `(cp, L2)` table covers every mark that appears in
the normalize module's canonical decomposition set:

| cp     | mark             | L2    |
| ------ | ---------------- | ----- |
| U+0300 | grave            | 0x0025 |
| U+0301 | acute            | 0x0024 |
| U+0302 | circumflex       | 0x0027 |
| U+0303 | tilde            | 0x002B |
| U+0304 | macron           | 0x0030 |
| U+0306 | breve            | 0x0028 |
| U+0307 | dot above        | 0x002E |
| U+0308 | dieresis         | 0x002F |
| U+030A | ring above       | 0x0032 |
| U+030B | double acute     | 0x0033 |
| U+030C | caron            | 0x0034 |
| U+0327 | cedilla          | 0x0054 |
| U+0328 | ogonek           | 0x0055 |

Marks in U+0300..U+036F not listed above receive the default L2
weight 0x0040. L1 is 0 for every mark (so they contribute nothing to
primary ordering), and L3 is 0x0002.

### Latin-1 Supp / Latin Ext-A (non-decomposing)

Letters in U+00A0..U+00FF and U+0100..U+017F that do NOT have a
canonical decomposition (Æ, Ø, Ð, þ, ß, Đ, Ħ, ı, Ł, ŋ, Œ, Ŧ, ...)
land here. Their L1 values fall into two fallback bands:

```
U+00A0..U+00FF  L1 = 0xF800 + (cp - 0xA0) * 2
U+0100..U+017F  L1 = 0xF900 + (cp - 0x100) * 2
```

Both are strictly above every ASCII letter's L1 (max 0x1C64 for 'z'),
so these characters sort after all ASCII in the DUCET order. A full
UCA landing (M4.2) places each in its proper DUCET position (e.g. Æ
between A and B); the baseline's grouping is correctness-safe but
locale-naive.

### Fallback bands

```
U+0180..U+02FF  L1 = 0xFE00 (constant)         -- Latin Ext-B+, phonetic
U+0370..        L1 = 0xFF00 (constant)         -- everything else
```

Fallback regions have L1 held constant across the range; code points
in them sort by their relative position in the input stream rather
than by any meaningful script order. Script-aware weighting lands at
M4.2 (Hangul, CJK), M4.3 (bidi, complex-shaping).

## Weight-table layout and encoding discipline

The DUCET lives in two forms inside `collation.pdx`:

1. **Algorithmic (ASCII bands and fallback bands):** no table at all.
   `_coll_classify` branches over cp ranges and computes `L1` with
   `(cp - range_base) * stride + L1_base`. Stride is either 2 (punct,
   latin-fallback bands) or 4 (letters); both are hoisted into
   `shl r, 1` or `shl r, 2` so paideia-as's "no `imul r, imm`"
   discipline is respected.

2. **Sparse (combining marks):** a 13-entry `(cp, L2)` pair table at
   stride 8 bytes per entry (two u32 fields). The table is sorted by
   cp so a linear scan is cache-friendly (fits easily in a single L1
   cache line) and terminates on first match. Table loads use `mov_d`
   (u32 zero-extend) matching the normalize module's precedent.

Both forms produce a packed CE qword `(L1 << 32) | (L2 << 16) | L3`
which the build-CE phase stores directly into the CE scratch. The
emit-key phase then extracts each level with shl/shr register-pair
idioms (never a `and r, imm64` mask, matching the paideia-as encoder
discipline).

## Forward path to full DUCET

The reduced baseline is a bridge, not a destination. The forward path
has four graded milestones:

- **M4.1 (contractions + expansions):** DUCET entries that are one-to-
  many (e.g. "ĳ" expanding to i,j CEs) or many-to-one (e.g.
  "ch" contracting to a single Czech CE). The baseline's one-cp-one-CE
  shape doesn't accommodate either; M4.1 lands a lookup-trie that
  supports both and extends the CE builder's state machine.
- **M4.2 (CJK + Hangul):** DUCET's implicit-weight algorithm (TR#10
  §10) for CJK; TR#10 §7.1.5 per-Hangul weighting. Both are
  table-driven in the real DUCET; adding them doubles the baseline's
  rodata footprint but keeps the pipeline shape unchanged.
- **M4.3 (bidi + complex-shaping scripts):** Arabic, Hebrew,
  Devanagari, Thai, and the presentation forms. These need bidi-aware
  CE construction and script-level L1 band placement; the shape of
  `_coll_classify` grows per-range.
- **M4.4 (CLDR tailorings):** per-locale deltas applied as patches to
  the root collation. Swedish "å after z"; German "ß = ss"; and so on.
  A small locale-tailoring table reorders / splits root CEs before the
  emit-key phase.

Beyond M4.4 (variable weighting, case level, numeric collation) are
tracked as M4.5+ in STATUS.md.

## Interaction with other modules

### M3 (normalize)

M4 depends on `_norm_nfd` for Phase 1. M3's limitations propagate:

- Any cp outside M3's decomposition table (Latin-1 Supp + Latin Ext-A
  + Fullwidth-ASCII) passes through NFD unchanged. If the cp is also
  outside M4's weight bands, it falls into the M4 fallback bands and
  sorts "somewhere after ASCII letters" in a way that is stable but
  not DUCET-correct.
- Hangul syllables (U+AC00..U+D7A3) are not decomposed by M3 (it uses
  table lookup, not the algorithmic L+V+T decomposition). M4 sees
  them as atomic cps and places them in the above-marks fallback
  band (L1 = 0xFF00). M4.2 fixes both: M3.2 lands the algorithmic
  Hangul decomp, M4.2 lands Hangul-specific collation weights.

### M1 (utf8)

M4 depends on `utf8_decode_cp` in both the NFD-input walk (Phase 2)
and transitively through `_norm_nfd` (Phase 1). The UTF-8 error-band
discrimination is identical to M3's: `rax`'s bits [31:24] are 0xFF on
any error. The compare path converts UTF-8 errors to "empty key" so
the ordering is defined for any byte input; `_coll_sort_key` returns
status=2 instead for callers that want to know.

## Scratch buffer accounting

Four `.bss` buffers, 28 KiB total:

```
_coll_nfd_scratch     4096 B   NFD byte output from Phase 1.
_coll_ce_scratch      8192 B   1024 CE qwords for Phase 2 output.
_coll_key_a_scratch   8192 B   Compare-side-A sort-key buffer.
_coll_key_b_scratch   8192 B   Compare-side-B sort-key buffer.
```

The NFD + CE scratch pair are shared between `_coll_sort_key` and
`_coll_compare`. Because `_coll_compare` calls `_coll_sort_key`
SEQUENTIALLY (first for side a, writing to `_coll_key_a_scratch` to
completion; then for side b), the second call cleanly overwrites the
first's NFD + CE scratch without affecting the already-materialised
`_coll_key_a`.

Reentrancy: single-threaded by construction (shell, pds, terminal all
ring-3, single-thread). A signal handler that calls `_coll_sort_key`
or `_coll_compare` while the main thread is partway through its own
call will corrupt the shared scratch. M4.5+ moves scratch to
caller-supplied workspace arguments; today's consumers do not have
that call shape.

## Return-shape discipline

Both public primitives follow the library's `(out_bytes << 32) |
status` / `-1/0/1` conventions established by M1 + M2 + M3:

```
_coll_sort_key returns u64:
    bits [63:32]  out_bytes_written  (0 on failure, >0 on success)
    bits [7:0]    status             (0=OK, 1=OUT_TOO_SMALL, 2=INVALID_UTF8)
    bits [31:8]   reserved           (always 0)

_coll_compare returns i64:
    -1  (0xFFFFFFFFFFFFFFFF)  a < b
     0  (0x0000000000000000)  a == b
     1  (0x0000000000000001)  a > b
```

The sign discrimination of `_coll_compare` uses signed `cmp` /
`jl`/`jg`/`jge`/`jle` branches, matching the `kernel::io::port_io`-
family convention for signed return paths.

## Test coverage

### Fingerprint goldens (8 cases)

See `tests/fingerprints/collation.golden`. The file header carries a
hand walk-through of each case's byte-level derivation from the CE
triples, so a future refactor can re-verify the goldens without a
full DUCET re-check.

Six CMP cases (AB, BA, AA, a_vs_A, a_vs_aacute, cafe_vs_café) exercise
L1, L1 reversal, L1 equality, L3-only tiebreak (case), and L2 tiebreak
(diacritic) in both the one-mark and the trailing-mark positions.

Two KEY cases (KEY_a, KEY_empty) exercise the three-level stream
emission and the empty-input short-circuit.

### Proptest witnesses (4 invariants)

See `tests/proptest_collation.pdx`:

- **Reflexivity:** `compare(x, x) == 0` for every x in a four-element
  witness set (ASCII 'a', ASCII 'b', 'á' NFC, "cafe"+U+0301).
- **Antisymmetry:** `compare(x, y) + compare(y, x) == 0` for three
  pairs: ('a', 'b'), ('a', 'á'), ('a', 'A').
- **Transitivity:** `compare('a','b') < 0 && compare('b','c') < 0 =>
  compare('a','c') < 0`.
- **Sort-key correctness:** `sign(compare('a', 'á')) ==
  sign(_coll_keycmp(sort_key('a'), sort_key('á')))`.

Umbrella `pnc_run_all` runs them all in declaration order; first
non-zero fail code wins.

Fail codes live in the 0xFFFFED8x band, extending the existing
`TestLexer` / `ProptestGrapheme` / `ProptestNormalize` family:

```
0xFFFFED81   PNC_FAIL_REFLEXIVITY
0xFFFFED82   PNC_FAIL_ANTISYMMETRY
0xFFFFED83   PNC_FAIL_TRANSITIVITY
0xFFFFED84   PNC_FAIL_SORT_KEY
```

### Benches

None at M4. A bench harness (`benches/collation.pdx`) lands at M4.1
alongside the contractions / expansions work, so the per-call cost of
the trie lookup can be compared to today's algorithmic classify.

## paideia-as encoder posture

Every rule in `src/normalize.pdx`'s header applies verbatim:

- No `test rN, rN`; every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64`; 0xFF and 0xFFFF masks are small positive imm32
  that sign-extend to their own value (so `and r, 0xFF` and
  `and r, 0xFFFF` are safe). The emit-key phase uses shl/shr
  register-pair idioms for 16-bit extraction to further sidestep any
  encoder edge case.
- No 2-op `imul r, imm`; CE indexing via `shl r, 3` (stride 8);
  mark-table indexing via `add r, 8` per linear-scan step.
- No multiline `pub let = "..."`.
- Module basename `Collation` matches `collation.pdx`.
- Labels prefixed `coll_`.
- MOVABS-into-register idiom for the error-band constants
  (0xFFFFE730, 0xFFFFE731).
- SysV alignment preserved through push count parity in every
  non-leaf function; see per-function headers in `collation.pdx`.
- No `add reg, [mem]` anywhere.

## Upstream links

- paideia-os#2480 (R131 Unicode umbrella).
- paideia-os#2612 (M1 UTF-8).
- paideia-os#2613 (M2 grapheme).
- paideia-os#2614 (M3 normalize).
- paideia-os#2615 (THIS M4 ticket).
- Rust-side analog: future `paideia-as-unicode::collation` module
  (M4.1+ lands this). The reduced DUCET format described here will
  be the Rust side's import target.

## References

- UTS #10 Rev. 46: Unicode Collation Algorithm.
  https://unicode.org/reports/tr10/
- Unicode 15.1.0 DUCET (allkeys.txt):
  https://www.unicode.org/Public/UCA/15.1.0/allkeys.txt
- CLDR root collation + per-locale tailorings:
  https://cldr.unicode.org/
