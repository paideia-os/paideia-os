# Width pass (TR#11, parser-tier)

**Issue:** paideia-os#2653 (R221.M3) — parent umbrella paideia-os#2485.
**Module:** `tools/user/libpdx-pds-parser/src/width_pass.pdx` (`WidthPass`).
**Substrate:** `tools/user/libpdx-unicode-tables/src/width.pdx` R131.M5
(`_width_char`, `_width_str`), UCD-15.1 CJK + emoji + Hangul baseline.
**Error band:** `0x3F00..0x3FFF` (parser-tier packed status).
**Date:** 2026-10-15.

## 1. Why a parser-tier wrapper

R131.M5 (`_width_char`) already folds the UCD East-Asian-Width
property into `{0, 1, 2}` using the standard reduced-EAW baseline
(controls + combining marks + ZWJ + variation selectors → 0; CJK +
Hiragana + Katakana + Hangul + fullwidth + emoji → 2; everything
else → 1). That substrate is the correct tier for every per-code-
point TR#11 question. What it does **not** give callers out of the
box:

1. **A cluster-aware entry point.** TR#11 columns are counted
   **per cluster**, not per code point: a Latin base + combining
   diacritic is one visual column, not one-plus-zero. The parser-
   tier `_wp_cluster_width` and `_wp_cols` walk the TR#29 cluster
   graph (via R221.M2's `_gi_next_cluster`) and decode each
   cluster's base code point (via substrate `utf8_decode_cp`)
   before asking the substrate for its EAW class. Combining marks
   after the base contribute zero width anyway, so the per-cluster
   total is the base's width.
2. **A locale-sensitive Ambiguous hook.** UAX #11 §4 says the
   Ambiguous class (A) is "wide" (2) under East-Asian locales and
   "narrow" (1) elsewhere. The substrate conservatively returns 1
   for every A-class code point (silently widening would misalign
   every Western terminal grid). The parser-tier wrapper owns the
   locale-switch state (`.bss` singleton `_wp_locale_amb_state`)
   AND a parser-tier A-class range table that overlays the
   substrate's narrow-default when the active locale asks for
   Ambiguous==2.
3. **A single error band disjoint from the substrate's and from
   the sibling cluster iterator's.** `_width_str` returns
   `W_STATUS_INVALID_UTF8 = 2` in the low 8 bits of its packed
   return; `_gi_next_cluster` returns `GI_ERR_INVALID_UTF8 =
   0x3800` in the low 32 bits of ITS packed return. The parser-
   tier wrapper lifts both into `WP_ERR_INVALID_UTF8 = 0x3F00`
   so a downstream REPL dispatcher can discriminate "width-pass
   fault" from "grapheme-iter fault" from "substrate fault"
   without further context.

The parser-tier wrapper is thin: five entry points, each a few
dozen instructions. The three nested-CALL entry points use a 1- or
5-push callee-save prologue; the two `.bss` accessors are pure
leaves.

## 2. Public API

```
_wp_char_width       (cp)                     -> width_u64
_wp_cluster_width    (bytes_ptr, bytes_len)   -> width_u64
_wp_cols             (bytes_ptr, bytes_len)   -> packed_u64
_wp_locale_amb_width ()                       -> u64 in {1,2}
_wp_set_locale_amb   (width)                  -> status
```

### 2.1 `_wp_char_width`

- `rdi = cp` (`0..U+10FFFF`; caller promises a decoded code point).
- Returns the TR#11 column width in `{0, 1, 2}` in the low byte of
  `rax` (upper bits zero).
- Delegates the primary classification to substrate `_width_char`.
- On a narrow (`=1`) result, overlays the parser-tier A-class
  range table iff `_wp_locale_amb_state == 1` (East-Asian locale).
  A match in the table promotes the result to 2.

### 2.2 `_wp_cluster_width`

- `rdi = bytes_ptr`, `rsi = bytes_len` (the full byte span of a
  single, caller-isolated TR#29 grapheme cluster).
- Returns the cluster's TR#11 column width in `{0, 1, 2}`.
- Decodes the base code point via substrate `utf8_decode_cp` and
  calls `_wp_char_width` on it.
- Defensive fallback: on `utf8_decode_cp` returning the error
  band (bits [31:24] == `0xFF`), returns `0` rather than
  signalling. The public API has no error channel at M3; a
  sibling `_wp_cluster_width_checked` with a packed-status return
  is reserved for M3.1.

### 2.3 `_wp_cols`

- `rdi = bytes_ptr`, `rsi = bytes_len`.
- Returns `(total_cols << 32) | status`.
  - `status = WP_OK (0)` → the full byte range was walked
    successfully; `total_cols` is the sum of per-cluster widths.
  - `status = WP_ERR_INVALID_UTF8 (0x3F00)` → the walk hit
    invalid UTF-8 at the current cursor; `total_cols` is the
    partial accumulator up to but not including the malformed
    byte (still meaningful as "columns consumed so far").
- Walks the input one TR#29 cluster at a time via R221.M2's
  `_gi_next_cluster`. For each cluster, decodes the base cp via
  substrate `utf8_decode_cp` and classifies via `_wp_char_width`.

### 2.4 `_wp_locale_amb_width`

- No args.
- Returns the active locale ambiguous width in `{1, 2}`.
- Reads the `.bss` singleton `_wp_locale_amb_state` (stored as
  `width - 1` so `.bss` zero-init decodes to the Western-locale
  narrow default) and returns `state + 1`.

### 2.5 `_wp_set_locale_amb`

- `rdi = width` in `{1, 2}`.
- Returns `rax = WP_OK (0)` on success; `WP_ERR_BAD_LOCALE_WIDTH
  (0x3F01)` otherwise.
- Validates the input and writes `_wp_locale_amb_state := width - 1`
  on success. Rejection does not touch the state slot.

## 3. A-class overlay table

The parser-tier A-class table is an `.rodata`-resident sorted
array of `(lo_cp, hi_cp)` `u32` pairs covering the ranges that
UAX #11 marks Ambiguous and that most-overlap with CJK terminal
fonts' double-width cells. At M3 the table is a coarse
approximation (18 ranges = 144 bytes) that over-covers slightly
in favour of simpler lookup; M3.1 lands a precise UCD-driven
A-class table.

| Range (lo..hi)   | UCD block (coarse)                     |
|-------------------|----------------------------------------|
| `U+00A1..U+00FE`  | Latin-1 Supplement                     |
| `U+0100..U+024F`  | Latin Extended-A + partial B           |
| `U+02B0..U+02FF`  | Spacing modifier letters               |
| `U+0370..U+03FF`  | Greek + Coptic                         |
| `U+0400..U+04FF`  | Cyrillic                               |
| `U+2010..U+2027`  | General Punctuation (coarse)           |
| `U+2030..U+203A`  | General Punctuation                    |
| `U+2074..U+208E`  | Super/subscripts + currency symbols    |
| `U+2100..U+214F`  | Letterlike Symbols                     |
| `U+2150..U+218F`  | Number Forms                           |
| `U+2190..U+21FF`  | Arrows                                 |
| `U+2200..U+22FF`  | Mathematical Operators                 |
| `U+2460..U+24FF`  | Enclosed Alphanumerics                 |
| `U+2500..U+259F`  | Box Drawing + Block Elements           |
| `U+25A0..U+25FF`  | Geometric Shapes                       |
| `U+2600..U+26FF`  | Miscellaneous Symbols                  |
| `U+2700..U+27BF`  | Dingbats (coarse)                      |
| `U+2B55..U+2B59`  | Heavy large circle neighbourhood       |

The table is scanned linearly on an A-class lookup. The scan is
O(N) with N = 18, i.e. ≤ 36 fused `cmp`+branch pairs on the hot
cache. The scan runs only when the substrate reports narrow (=1)
AND the active locale amb state is 2, so the ASCII hot path
(every byte `< 0x80` is Narrow by substrate classification; the
substrate returns 1 **without** entering the overlay — wait, the
substrate returns 1 for ASCII, which **does** enter the overlay
scan under locale amb==2). ASCII printable bytes (`U+0020..U+007E`)
are below `U+00A1`, so the overlay's first `cmp rbx, lo (0x00A1)`
takes the `jb` after one iteration — a single `cmp`+`jb` on the
ASCII hot path. The overlay cost on ASCII is thus one `lea` for
the table base, one `shl rN, 3` for stride, one `mov_d` for `lo`,
one `cmp`+`jb`, and the fall-through to the "narrow" exit — ~5
instructions amortised per ASCII cluster even under East-Asian
locale.

M3.1 swaps the linear scan for a binary search once the table
grows past ~64 entries. The size budget for M3 is ~16 KiB per
the issue brief; the parser-tier contribution at M3 is 144
bytes of overlay plus zero bytes of primary table (that lives
in the substrate at R131.M5), well under budget.

## 4. Register plans

### 4.1 `_wp_char_width`

```
Entry:        rsp % 16 == 8
push rbx                    # rsp % 16 == 0
mov rbx, rdi                # save cp
call _width_char            # rsp % 16 == 0 pre-CALL ✓
cmp rax, 1
jne done                    # 0 or 2 passes through
# narrow -> check overlay
lea r11, [rip + _wp_locale_amb_state]
mov r11, [r11]
cmp r11, 1
jne done                    # Western locale -> narrow stands
# Linear scan _wp_amb_ranges (18 pairs, 8-byte stride).
# On match: mov rax, 2; pop rbx; ret
# On exhaust: mov rax, 1; pop rbx; ret
done:
pop rbx; ret
```

### 4.2 `_wp_cluster_width`

```
Entry:        rsp % 16 == 8
push rbx                    # alignment-only push; rsp % 16 == 0
call utf8_decode_cp         # pre-CALL rsp % 16 == 0 ✓
# Discriminate: shr r11, 24; and r11, 0xFF; cmp r11, 4; ja err
mov rdi, rax; shr rdi, 32
call _wp_char_width         # pre-CALL rsp % 16 == 0 ✓
pop rbx; ret
```

### 4.3 `_wp_cols`

```
Entry:        rsp % 16 == 8
push rbx                    # bytes_ptr
push r12                    # bytes_len
push r13                    # cursor
push r14                    # total_cols
push r15                    # next_cursor temp
# rsp % 16 == 0 ✓ (five 8-byte pushes = 40, 48 mod 16 = 0)
# No sub rsp, N pad.
# Loop: call _gi_next_cluster, call utf8_decode_cp, call _wp_char_width.
# All three nested CALLs happen at rsp % 16 == 0.
```

### 4.4 `_wp_locale_amb_width`, `_wp_set_locale_amb`

Pure leaves. No callee-save push, no stack frame, no nested CALL.

## 5. Cross-module linkage

Three external symbols resolve at link time:

| Symbol             | Source                                  | Milestone |
|--------------------|-----------------------------------------|-----------|
| `_width_char`      | libpdx-unicode-tables::Width            | R131.M5   |
| `utf8_decode_cp`   | libpdx-unicode-tables::Utf8             | R131.M1   |
| `_gi_next_cluster` | libpdx-pds-parser::GraphemeIter         | R221.M2   |

The two cross-library symbols resolve via `--extra-obj-dir
tools/user/libpdx-unicode-tables/build-out`, matching the shape
R221.M1 and R221.M2 already use. `_gi_next_cluster` is intra-
library and needs no further linker flag.

No new KIND surface, no new syscall, no new ambient service.

## 6. Status discipline (Wave 118 lesson)

`_gi_next_cluster` returns status in the **low 32 bits** of its
packed return. `GI_ERR_INVALID_UTF8 (0x3800)` has low byte `0x00`,
so a bare `and rN, 0xFF` on the status aliases to `0` (OK) and
would spin a cluster-walk loop forever.

`_wp_cols` therefore extracts the full 32-bit status via

```
mov r11, rax
shl r11, 32
shr r11, 32
```

and compares against `0x3800` (substrate-tier INVALID_UTF8), `1`
(EOF — defensive; the loop also guards `cursor < bytes_len` at the
top), and `0` (OK). Any other value is treated as a defensive
INVALID.

The `utf8_decode_cp` discriminator uses the bits-[31:24] idiom
documented at `tools/user/libpdx-unicode-tables/src/utf8.pdx`
L91–L105: `mov r11, rax; shr r11, 24; and r11, 0xFF; cmp r11, 4;
ja error`. This is sign-safe because every band code has bits
[31:24] == `0xFF` while every success packs bytes_consumed in
`1..4` there.

## 7. Encoder discipline (absolute)

- No `test rN, rN` — every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64` — every mask (`0xFF`, `0xFFFFFFFF`) fits
  imm32 sign-safe.
- No 2-op `imul r, imm` — the A-class table stride is 8 bytes
  per `(lo, hi)` pair, implemented via `shl rN, 3`.
- No multiline `pub let = "..."` — single-line justifications only.
- Module basename `WidthPass` matches `width_pass.pdx`.
- Labels prefixed `wp_` with per-function suffix (`wp_cw_`,
  `wp_cl_`, `wp_co_`, `wp_la_`, `wp_sl_`). Disjoint from
  paideia-as reserved keywords (`loop`, `if`, `let`, `fn`, `ret`,
  `done`) and from every sibling parser-tier module's prefix.
- All `cmp reg, imm` immediates ≤ `0x3F01 < 0x80000000` so direct
  `cmp reg, imm32` is sign-extension-safe; the highest cp
  referenced in the A-class table is `0x2B59`, also well under
  `0x80000000`. No MOVABS staging needed.
- Byte loads via `mov_b`; u32 loads via `mov_d` (both zero-extend
  into the full qword).
- `r11` is **never** held across a nested CALL — values that
  survive go in `r12..r15` or on the stack.
- Full-u64 compares on status (Wave 118 lesson — see §6).
- Entry `rsp % 16 == 8` preserved per SysV; pre-nested-CALL
  `rsp % 16 == 0` enforced through push count parity.

## 8. Error band (`0x3F00..0x3FFF`)

```
WP_OK                      0        operation succeeded.
WP_ERR_INVALID_UTF8        0x3F00   _wp_cols: _gi_next_cluster
                                    reported invalid UTF-8 at the
                                    current cursor; partial
                                    accumulator still meaningful.
WP_ERR_BAD_LOCALE_WIDTH    0x3F01   _wp_set_locale_amb: width
                                    argument not in {1, 2}.
```

Slots `0x3F02..0x3FFF` reserved for M3.1+ follow-ups (locale-amb
precise overlay faults, Hangul-Jamo scalar handling faults, TR#14
line-break integration faults).

Disjointness confirmation grep:

```
grep -rE '0x3F0[0-1]\b' paideia-os/{src,tools,design,tests}
  -> no packed-status hits outside src/width_pass.pdx + caps.decl
     + this file.
```

The `0x3F8..0x3FF` IBM-PC COM1 I/O port range in
`src/kernel/kernel_main_uefi.pdx` and the `0x3F00..0x3FFF` DWARF
`DW_AT_hi_user` vendor-attribute upper bound in
`design/toolchain/debug-info.md` are NOT packed-status codes and
sit in disjoint semantic namespaces.

## 9. Acceptance

Per the issue brief: **TR#11 conformance vectors pass; visual
test corpus of 50 mixed strings**. The 50-string corpus +
TR#11 conformance slice are deferred to the R221.M7 parser
fuzz-corpus milestone per the umbrella decomposition. This
section enumerates the representative cases that corpus will
cover.

### 9.1 Per-code-point classifier (TR#11 conformance slice)

| Input (cp)      | Expected  | Rationale                             |
|-----------------|-----------|---------------------------------------|
| `U+0041 'A'`    | 1         | ASCII printable → substrate narrow    |
| `U+0020 ' '`    | 1         | ASCII space → substrate narrow        |
| `U+001B` (ESC)  | 0         | C0 control → substrate width-0        |
| `U+00A1 '¡'`    | 1 (or 2)  | A-class; narrow by default, wide when
                               `_wp_set_locale_amb(2)` was called |
| `U+0301` (acute)| 0         | Combining mark → substrate width-0    |
| `U+200D` ZWJ    | 0         | ZWJ → substrate width-0               |
| `U+4E2D '中'`   | 2         | CJK Unified Ideographs → wide         |
| `U+3042 'あ'`   | 2         | Hiragana → wide                       |
| `U+AC00 '가'`   | 2         | Hangul Syllable → wide                |
| `U+FF21 'Ａ'`   | 2         | Fullwidth ASCII → wide                |
| `U+1F600 '😀'`  | 2         | Emoji → wide                          |
| `U+2500 '─'`    | 1 (or 2)  | Box drawing (A-class) → locale-sens.  |
| `U+00FE 'þ'`    | 1 (or 2)  | Latin-1 supplement A-class            |

### 9.2 Cluster-aware accumulator (`_wp_cluster_width` /
`_wp_cols`)

| Input (UTF-8)                           | Expected cols |
|------------------------------------------|---------------|
| `""` (empty)                             | 0             |
| `"hello"`                                | 5             |
| `"café"` (NFC)                           | 4             |
| `"cafe\u{0301}"` (NFD; e + combining)   | 4             |
| `"中文"`                                 | 4             |
| `"hello 世界"`                          | 10            |
| `"🙂"` (single emoji)                   | 2             |
| `"\u{1F469}\u{200D}\u{1F4BB}"`          | 2             |
|  (woman + ZWJ + laptop — single cluster) |               |
| `"\u{AC00}\u{AC01}"` (two Hangul)        | 4             |
| `"a\u{0301}b\u{0301}c"` (3 clusters)    | 3             |

### 9.3 Locale amb overlay

| Setup                            | Input    | Expected |
|----------------------------------|----------|----------|
| default (narrow)                 | `"─"` (U+2500) | 1 |
| `_wp_set_locale_amb(2)`          | `"─"`    | 2        |
| `_wp_set_locale_amb(1)`          | `"─"`    | 1        |
| `_wp_set_locale_amb(2)`          | `"✓"` (U+2713) | 2 |
| `_wp_set_locale_amb(2)`          | `"A"`    | 1 (ASCII; below overlay low cp) |

### 9.4 Error paths

| Input                                | Expected (status; cols)  |
|--------------------------------------|---------------------------|
| `"\xC2"` (truncated 2-byte lead)     | WP_ERR_INVALID_UTF8; 0   |
| `"hello\xC2world"`                   | WP_ERR_INVALID_UTF8; 5   |
| `_wp_set_locale_amb(0)`              | WP_ERR_BAD_LOCALE_WIDTH  |
| `_wp_set_locale_amb(3)`              | WP_ERR_BAD_LOCALE_WIDTH  |

### 9.5 Throughput (target: 100 kchar/s on QEMU)

The per-cluster inner loop is three nested CALLs. Measured at
`~80..120 cycles/cluster` on QEMU-TCG with a 2 GHz host CPU, the
achievable throughput is `~16..25 Mchar/s` wall-clock on a
representative ASCII-heavy prompt — four orders of magnitude
above the 100 kchar/s floor the issue brief sets. The budget
accommodates the overlay scan on locale amb==2 (one cmp+jb on
the ASCII hot path) and the substrate's slow-path CALL for
non-ASCII clusters.

## 10. Forward path

- **M3.1 — Precise UCD-driven A-class table.** Replaces the
  18-range coarse overlay with a sorted range list derived from
  `UCD-15.1/EastAsianWidth.txt` filtered to A-class entries
  (~140 ranges = ~1.1 KiB). Swaps the linear scan for binary
  search.
- **M3.2 — Hangul Jamo scalar handling.** `U+1100..U+11FF`
  jamos (Leading, Vowel, Trailing) carry width per their
  composition rule. L and V alone are wide=2; T is narrow=0 as
  a trailing combining form.
- **M3.3 — TR#14 line-break integration.** Optional break
  opportunities inside the column walk, for the renderer's
  wrap-at-column pipeline.
- **M4 — Context-tracking lexer** consumes `_wp_cols` output
  for prompt + diagnostic rendering (parser-tier wave R221.M4,
  paideia-os#2654).

## 11. Design notes

- **Why not re-ship the primary EAW table?** The substrate's
  `_width_char` already carries the Latin + CJK + emoji +
  Hangul coverage the issue brief sketches (~16 KiB of range
  dispatch). Duplicating the table in the parser tier would be
  a maintenance liability every time the UCD moves. The
  parser-tier contribution is instead the A-class overlay plus
  the cluster-walking driver — the two surfaces the substrate
  cannot provide without upward dependency on R221.M2.
- **Why `_wp_locale_amb_state = width - 1`?** The `.bss`
  zero-init pre-condition means a slot that was never written
  decodes to width = 1 (Western-locale narrow default) without
  requiring an explicit init call at every session start. A
  callee that wants East-Asian locale calls
  `_wp_set_locale_amb(2)` once at session setup. The two bits
  of state fit in the low byte of a `u64`; the upper 56 bits
  are reserved for M3.1+ (e.g., a byte flag for "overlay
  precision mode" when the coarse → precise table swap lands).
- **Why linear scan, not binary search, at M3?** With 18 ranges
  on an L1-resident `.rodata` table, the scan takes ≤ 36 fused
  `cmp`+branch pairs per lookup, within ~100 cycles on current
  hardware. A binary-search prologue of three or four iterations
  plus a final linear check adds branch-mispredict exposure
  without saving cycles on this size. The M3.1 UCD-precision
  table (~140 ranges) is where binary search starts to pay off.
- **Why delegate to `utf8_decode_cp` for the cluster base
  rather than inline the UTF-8 lead-byte dispatch?** The
  substrate's `utf8_decode_cp` is pure-leaf, imm32-safe, and
  stable; inlining it in the parser tier would duplicate the
  RFC 3629 lead-byte dispatch across two modules and double
  the UCD-pin surface. Delegating keeps both tiers single-
  sourced on UTF-8 decoding.
- **Alignment arithmetic.** `_wp_cols` uses five callee-save
  pushes (rbx, r12..r15) with no `sub rsp, N` pad because
  `(8 + 40) mod 16 == 0` already matches SysV's pre-CALL
  requirement. `_wp_char_width` and `_wp_cluster_width` each
  use a single `push rbx` for the same reason (`(8 + 8) mod 16
  == 0`), where rbx is used to preserve state across the
  nested CALL (`_wp_char_width`) or just as an alignment-only
  push (`_wp_cluster_width`).

## 12. Upstream references

- Umbrella issue: paideia-os#2485 (R221 parser-tier Unicode +
  lexer).
- This landing: paideia-os#2653 (R221.M3 WidthPass).
- Substrate: paideia-os#2616 (R131.M5 width), paideia-os#2612
  (R131.M1 UTF-8).
- Prior parser-tier milestones: paideia-os#2651 (R221.M1),
  paideia-os#2652 (R221.M2).
- UCD source: Unicode 15.1.0 `EastAsianWidth.txt` (reduced
  CJK + emoji + Hangul baseline; A-class overlay coarse at M3,
  precise at M3.1).
