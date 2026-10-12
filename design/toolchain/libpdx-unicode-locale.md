# libpdx-unicode-tables Locale (R131.M7)

## Status

**Wave:** R131 (semantic shell -- Unicode substrate umbrella,
paideia-os#2480).
**Milestone:** M7 (locale registry, BCP 47 subset,
paideia-os#2618).
**Library version at landing:** 1.6.0.
**Date:** 2026-10-11.

## Scope

M7 adds the LOCALE REGISTRY substrate to the user-space Unicode library
the shell, pds, and the GPU-native terminal all link. The point of this
milestone is to give the three primitives that need cultural policy
(collation at M4, width at M5, bidi at M6) a canonical place to look up
"what should I do for this locale?" without each primitive baking its
own locale table into its code. Four public primitives:

```
_locale_parse(tag_ptr, tag_len)              -> packed_u64
_locale_default()                            -> u64
_locale_direction(locale_id)                 -> u64
_locale_width_ambiguous_is_wide(locale_id)   -> u64
```

Return shapes:

- `_locale_parse`: `(locale_id << 8) | status` with status in
  {0=OK, 1=UNKNOWN, 2=MALFORMED}. The locale_id field is 0 on both
  UNKNOWN and MALFORMED (caller falls back to the default locale
  cleanly either way).
- `_locale_default`: a u64 holding the default locale_id (0 = C /
  POSIX). No error band -- the default is always well-defined.
- `_locale_direction`: a u64 in {0 (LTR), 1 (RTL)}. For any id outside
  the baseline registry [0, 8), returns 0 (soft fallback matching the
  "unknown id behaves like default" convention).
- `_locale_width_ambiguous_is_wide`: a u64 in {0 (narrow), 1 (wide)}.
  For any id outside the baseline registry, returns 0.

Every primitive is a pure leaf -- no capability bind, no syscall, no
nested call. The parser does inline byte normalization and key
compares; the policy accessors do inline range dispatch.

M7 is the SEVENTH milestone of this library and the FIRST one whose
public interface takes BYTE-STRING tags rather than code points or
byte buffers. The parser is a strict 5-byte subset of BCP 47
(`language-REGION` only, no script / variants / extensions); the
registry is an 8-entry baseline covering every direction / ambiguous-
width class the dependent primitives can observe.

## Reduced locale registry (R131.M7 baseline -- 8 locales)

| id | tag     | direction | ambiguous-wide |
|----|---------|-----------|----------------|
| 0  | C/POSIX | LTR       | narrow         |
| 1  | en-US   | LTR       | narrow         |
| 2  | en-GB   | LTR       | narrow         |
| 3  | ja-JP   | LTR       | wide           |
| 4  | zh-CN   | LTR       | wide           |
| 5  | ko-KR   | LTR       | wide           |
| 6  | he-IL   | RTL       | narrow         |
| 7  | ar-SA   | RTL       | narrow         |

The eight ids form a contiguous [0, 8) index. Every id is well-defined
on every policy accessor; ids >= 8 fall back to the default (LTR,
narrow) rather than returning an error band. The eighth entry (C /
POSIX) is reachable only through `_locale_default()`; the parser never
resolves to it because its canonical tag is not `xx-YY`. A caller that
wants to parse the literal strings `C` or `POSIX` into id=0 can
intercept them above this library (shell dispatch, environment-
variable parser).

### Why these eight

The eight entries cover every DIRECTION class (LTR, RTL) and every
UAX #11 AMBIGUOUS-WIDTH class (narrow, wide) that the M5 width
primitive and M6 bidi primitive distinguish today:

- **LTR + narrow**: C/POSIX, en-US, en-GB (Western baseline).
- **LTR + wide**: ja-JP, zh-CN, ko-KR (East Asian CJK locales where
  historical terminals widen ambiguous code points to 2 columns).
- **RTL + narrow**: he-IL, ar-SA (Semitic script baseline).
- **RTL + wide**: not in the baseline (no major RTL script shares the
  East Asian ambiguous-width tradition; a future locale would need an
  explicit opt-in).

Adding further locales (es, fr, de, ...) at M7 would not exercise any
new direction or width class; they are deferred to M7.4 alongside the
full CLDR axis set.

## Parser design

### Strict xx-YY shape

The M7 parser accepts the strict `xx-YY` five-byte shape only:

- exactly 2 letters for the language subtag
- exactly 1 literal `-` separator at byte offset 2
- exactly 2 letters for the region subtag

Both subtags are case-insensitive. The parser lowercases the language
bytes (A..Z -> a..z) and uppercases the region bytes (a..z -> A..Z)
before comparing against the registry, so inputs like "en-us",
"EN-US", "En-Us" all canonicalise to the same registry key.

### Length and separator failures

| condition                | status      | reason                                       |
|--------------------------|-------------|----------------------------------------------|
| `tag_len != 5`           | MALFORMED   | wrong shape; parser cannot proceed           |
| `tag[2] == '_'` (0x5F)   | MALFORMED   | explicit POSIX-separator rejection (below)   |
| `tag[2] != '-'` (0x2D)   | MALFORMED   | wrong shape                                  |

The `_` rejection is explicit rather than falling into the catch-all
"not '-' -> MALFORMED" branch so a caller passing `en_US` from a
`getenv("LANG")` value gets a loud diagnostic. The POSIX separator is
widespread (every GNU-ish `locale -a` lists `en_US.UTF-8`-style
entries) and treating it as MALFORMED rather than UNKNOWN forces the
caller to translate the POSIX form into BCP 47 form before calling the
parser, which is almost always what they want.

### Dispatch over seven keyed entries

A well-formed `xx-YY` input, after canonicalisation, becomes a 4-byte
key:

```
key = lang[0] | (lang[1] << 8) | (region[0] << 16) | (region[1] << 24)
```

The parser compares the computed key against seven inline constants
(one per keyed registry entry; the eighth entry -- C/POSIX -- has no
canonical `xx-YY` tag and is unreachable from the parser):

| tag    | lang bytes      | region bytes    | key           | id |
|--------|-----------------|-----------------|---------------|----|
| en-US  | 0x65 (e), 0x6E  | 0x55 (U), 0x53  | 0x53556E65    | 1  |
| en-GB  | 0x65 (e), 0x6E  | 0x47 (G), 0x42  | 0x42476E65    | 2  |
| ja-JP  | 0x6A (j), 0x61  | 0x4A (J), 0x50  | 0x504A616A    | 3  |
| zh-CN  | 0x7A (z), 0x68  | 0x43 (C), 0x4E  | 0x4E43687A    | 4  |
| ko-KR  | 0x6B (k), 0x6F  | 0x4B (K), 0x52  | 0x524B6F6B    | 5  |
| he-IL  | 0x68 (h), 0x65  | 0x49 (I), 0x4C  | 0x4C496568    | 6  |
| ar-SA  | 0x61 (a), 0x72  | 0x53 (S), 0x41  | 0x41537261    | 7  |

Every key is < 0x80000000 so `cmp reg, imm32` is sign-extension-safe
(the immediate's sign bit is 0, and the register holds a byte-
assembled positive value). No MOVABS staging is needed anywhere in
the parser.

Seven inline compares at the call site are faster than a table scan
for 7 entries (the cache lines are already hot; the inline chain
compiles to ~55 instructions, no memory access past the input bytes).
If the registry grows past ~16 entries in a future milestone, the
dispatch converts to a `.bss` table + linear scan at that point.

### Unknown vs malformed

A 5-byte input with hyphen at offset 2 whose key does not match any of
the seven known keys returns UNKNOWN (status=1, locale_id=0). The
caller treats UNKNOWN as "fall back to the default locale" cleanly
because locale_id=0 is already the default id. A caller that wants to
distinguish "I asked for ko-KR but the library doesn't know it" from
"the library resolved C/POSIX" inspects the status byte.

A well-formed 5-byte input whose BYTES don't look like letters at all
("12-34", "@!-+%") still gets UNKNOWN rather than MALFORMED. This is a
deliberate choice: the shape (length + separator) is well-formed; the
content is just unrecognised. Adding content validation (reject non-
letter language bytes) is M7.1 work alongside the 2-byte / 3-byte
language-only parse path.

## Policy accessors

Both policy accessors are pure range-dispatch leaves:

### Direction

```
_locale_direction(id):
  if 6 <= id <= 7: return 1 (RTL)
  else           : return 0 (LTR)
```

The RTL window is encoded as [6, 7] inclusive so unknown ids above 7
fall through to the LTR default. Below 6 is already LTR by the first
range check. Two comparisons, one branch per outcome.

### Ambiguous width

```
_locale_width_ambiguous_is_wide(id):
  if 3 <= id <= 5: return 1 (wide)
  else           : return 0 (narrow)
```

The wide window is encoded as [3, 5] inclusive (ja-JP, zh-CN, ko-KR);
unknown ids above 5 fall through to the narrow default. Two
comparisons, one branch per outcome.

The downstream width-aware consumer (`_width_char_lc(cp, locale)`,
landing at M7.1 alongside the UAX #11 ambiguous table) dispatches on
this value to decide whether an ambiguous-class code point contributes
1 or 2 columns to the display-width sum.

## Status code packing

`_locale_parse` returns the same packed shape as every other
multi-value primitive in this library:

```
bits [63:8]  locale_id  (0..7 on success; 0 on UNKNOWN or MALFORMED)
bits [7:0]   status     (0=OK, 1=UNKNOWN, 2=MALFORMED)
```

The status byte lives in the low 8 bits so a consumer can read it with
`and rax, 0xFF`. The locale_id lives above it so a consumer can read
it with `shr rax, 8`. Zero-id on failure is the convention used by
every other packed primitive in this library (the "ignore status,
read field" pattern degrades to default-fallback behaviour cleanly).

Hard failure vs soft failure:

- **Status 2 (MALFORMED)**: the input violated the `xx-YY` shape.
  The parser could not even classify the input as a tag. Hard failure;
  caller should surface it to the user (shell error, pds error dialog).
- **Status 1 (UNKNOWN)**: the input was well-formed but did not match
  any registry entry. Soft failure; caller may fall back to the default
  locale silently.
- **Status 0 (OK)**: the input matched a registry entry. Success.

## Error band

0xFFFFE770..0xFFFFE77F is reserved for locale-layer error codes but
holds no slots at M7 (every status fits in the low 8 bits of the
packed return). The slice jumps over 0xFFFFE750..0xFFFFE75F (M5 width,
one slot) and 0xFFFFE760..0xFFFFE76F (M6 bidi, two slots). Disjoint
from every other user-space band in the paideia-os tree.

Future error kinds that would land in this band:

- `LOCALE_TAG_TOO_LONG` at 0xFFFFE770: once variant subtags land at
  M7.2 the max length pushes past 5 bytes; a tag with length > the
  current max becomes TAG_TOO_LONG (distinct from UNKNOWN because
  the caller might want to truncate and retry).
- `LOCALE_REGISTRY_FULL` at 0xFFFFE771: if the registry becomes
  caller-populated at M7.5 (shell / pds / terminal register their
  own locales via `_locale_register`), a `_locale_register` call
  past the registry's capacity returns this code.
- `LOCALE_TAILORING_UNKNOWN` at 0xFFFFE772: once per-locale CLDR
  tailorings reach the collation pipeline at M4.4, a sort key built
  against a locale with no tailoring table returns this (distinct
  from the collation layer's own band).

## Further work

| Milestone | Scope                                                                                      |
|-----------|--------------------------------------------------------------------------------------------|
| M7.1      | Language-only parse (`en`, `ja`, `he`) + 3-letter language codes (ISO 639-3)               |
| M7.2      | Script subtag (`sr-Cyrl-RS`)                                                               |
| M7.3      | Variant + extension subtags (`de-CH-1996`, `en-US-u-ca-gregory`)                           |
| M7.4      | Full locale axes (decimal separator, grouping, currency, first-day-of-week); larger CLDR   |
| M7.5      | Caller-populated registry (`_locale_register`, `_locale_unregister`)                       |

### M7.1 language-only parse

Expands `_locale_parse` to accept 2-byte and 3-byte inputs
representing a language subtag with no region. Each language maps to
its first-registry-match locale (`en` -> `en-US`, `ja` -> `ja-JP`,
etc). Needed before environment-variable passthrough (`LANG=en`,
`LANG=ja`) stops surfacing MALFORMED on an otherwise legal POSIX
value. Also adds 3-letter language codes (ISO 639-3; legacy `iw-IL`
form maps to `he-IL`).

### M7.2 script subtag

Adds the three-subtag shape `language-SCRIPT-REGION` where SCRIPT is a
4-letter ISO 15924 code. Rare in M7 consumer sites but needed for the
vfx shell's RTL preview mode (Serbian cyrillic vs latin, Chinese
simplified vs traditional). The parser becomes length-flexible (6-11
bytes) and the key encoding widens to 8 bytes.

### M7.3 variant + extension subtags

Adds variant subtags (`de-CH-1996` pre-reform vs post-reform German)
and extension subtags (`en-US-u-ca-gregory` for calendar preference,
`en-US-u-nu-latn` for numbering system). These parse into optional
side-channels on the returned record; a consumer that doesn't care
reads only the base id as before.

### M7.4 full locale axes + larger CLDR

Grows the registry beyond 8 entries and adds policy accessors for the
remaining locale axes: decimal separator (`en-US` -> `.`, `de-DE` ->
`,`), grouping separator (`en-US` -> `,`, `de-DE` -> `.`, `fr-FR` ->
U+202F NARROW NO-BREAK SPACE), currency symbol, first-day-of-week.
The CLDR slice adds es, fr, de, it, pt, ru, pl, nl, tr, vi, th, id,
ms, hi at minimum.

### M7.5 caller-populated registry

Promotes the registry from a compile-time constant to a caller-
populated table. Needed when the shell / pds / terminal wants to
register user-defined locales (`en-US` with a custom first-day-of-week
override, say). Adds `_locale_register(tag_ptr, tag_len, policy_ptr)`
and `_locale_unregister(locale_id)`. The baseline eight entries remain
compile-time and are not unregisterable.

## Fingerprint goldens (5 TAG lines)

See `tests/fingerprints/locale.golden` for the exact bytes. OUTPUT_HEX
encodes the packed u64 return (16 nibbles big-endian). Covered cases:

- **LOC_PARSE_EN** (`"en-US"` = 65 6E 2D 55 53): canonical 5-byte
  input; dispatch hits the en-US key branch; returns id=1, status=0;
  packed value = 0x100.
- **LOC_PARSE_JA** (`"ja-JP"` = 6A 61 2D 4A 50): canonical 5-byte
  input; dispatch hits the ja-JP key branch; returns id=3, status=0;
  packed value = 0x300.
- **LOC_PARSE_HE** (`"he-IL"` = 68 65 2D 49 4C): canonical 5-byte
  input; dispatch hits the he-IL key branch; returns id=6, status=0;
  packed value = 0x600.
- **LOC_PARSE_UNKNOWN** (`"xx-YY"` = 78 78 2D 59 59): well-formed
  5-byte input; dispatch falls through every key; returns id=0,
  status=1; packed value = 0x001.
- **LOC_PARSE_MALFORMED** (`"en_US"` = 65 6E 5F 55 53): byte[2] is
  '_' (0x5F); separator-gate rejects; returns id=0, status=2; packed
  value = 0x002.

## Proptest witnesses (3 invariants)

See `tests/proptest_locale.pdx`. Three invariants cover the policy
contract:

- **Default well-defined** (`pl_case_default`): the composition
  `_locale_direction(_locale_default())` returns 0 (LTR). The default
  locale (C / POSIX) is defined, and its direction is well-defined,
  so the composition cannot fail. If it did -- say the default accessor
  returned an id outside the registry -- the direction accessor would
  still return 0 by the "unknown id falls through to LTR" rule, so this
  invariant doubles as a cross-check that the two accessors agree on
  the default's direction.
- **Parse idempotent** (`pl_case_idempotent`): two calls to
  `_locale_parse("en-US")` return the same packed value. If the parser
  has any hidden mutable state (a cache, a counter, a stray `.bss`
  write), the second call could diverge; the witness exercises the
  guarantee that the parser is a pure function.
- **Direction totality** (`pl_case_direction_totality`): for every id
  in [0, 8), `_locale_direction(id)` returns a value in {0, 1}. Walks
  the eight baseline ids one by one and asserts `rax <= 1` on each
  return. If a new id addition at M7.4 forgot to assign a direction,
  the registry entry would default to 0 (LTR), which still satisfies
  the totality property; this witness catches the stronger failure of
  returning a direction value outside the {0, 1} set.

Umbrella `pl_run_all` runs them in declaration order; first non-zero
fail code wins.

Fail codes live in the 0xFFFFEDDx band, extending the existing
`TestLexer` / `ProptestGrapheme` / `ProptestNormalize` /
`ProptestCollation` / `ProptestWidth` / `ProptestBidi` family (skips
the VKBench EDAx and VKFeatures EDBx kernel bands):

```
0xFFFFEDD1   PL_FAIL_DEFAULT
0xFFFFEDD2   PL_FAIL_IDEMPOTENT
0xFFFFEDD3   PL_FAIL_DIRECTION_TOTALITY
```

## Benches

None at M7. A bench harness (`benches/locale.pdx`) lands at M7.1
alongside the 2-byte / 3-byte language-only parse path so the per-tag
cost of the extended parser can be compared against the strict 5-byte
baseline.

## paideia-as encoder posture

Every rule in `src/bidi.pdx`'s header applies verbatim, with one
addition for the parser's byte-level tag normalisation:

- No `test rN, rN`; every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64`; the parser builds its 4-byte key via `shl +
  add` of lowercased / uppercased bytes; no mask is applied anywhere.
- No 2-op `imul r, imm`; every arithmetic step is `shl imm8 / add`.
- No multiline `pub let = "..."`.
- Module basename `Locale` matches `locale.pdx` (verified at write
  time; the regression Wave 93 caught in the pdxb_mount module and
  every subsequent softarch dispatch re-flags continues to apply).
- Labels prefixed `locale_`.
- All `cmp reg, imm` immediates <= 0x53556E65 (the en-US key value;
  < 0x80000000, so direct `cmp` is sign-extension-safe). ASCII
  constants (0x20, 0x2D, 0x41, 0x5A, 0x5F, 0x61, 0x7A) fit imm8. No
  MOVABS staging needed anywhere.
- All byte loads via `mov_b` (zero-extends into the full qword).
- SysV alignment preserved: every public entry point is a pure leaf
  (no nested CALL) so no callee-save push or stack-scratch is
  required. Entry rsp%16==8 is preserved into the `ret`.
- No `add reg, [mem]` anywhere.

## Upstream links

- paideia-os#2480 (R131 Unicode umbrella).
- paideia-os#2612 (M1 UTF-8).
- paideia-os#2613 (M2 grapheme).
- paideia-os#2614 (M3 normalize).
- paideia-os#2615 (M4 collation).
- paideia-os#2616 (M5 width).
- paideia-os#2617 (M6 bidi).
- paideia-os#2618 (THIS M7 ticket).
- Rust-side analog: future `paideia-as-unicode::locale` module (M7.1+
  lands this). The 8-entry baseline registry described here will be
  the Rust side's import target.

## References

- BCP 47 (RFC 5646): Tags for Identifying Languages.
  https://tools.ietf.org/html/rfc5646
- CLDR 44: Common Locale Data Repository (per-locale axes).
  https://cldr.unicode.org/index/downloads/cldr-44
- Unicode 15.1.0 LocaleDataExemplars (for the full axis set at M7.4):
  https://www.unicode.org/Public/cldr/44/common/main/
- UAX #11 Rev. 36 ambiguous-width class (consumer at M7.1 via
  `_width_char_lc`):
  https://unicode.org/reports/tr11/
- POSIX locale (`setlocale(3)`, `locale -a` output format): IEEE
  Std 1003.1-2017, §7.3 "Locale Definition".
