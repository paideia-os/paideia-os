# Grapheme cluster boundary iterator (TR#29, parser-tier)

**Issue:** paideia-os#2652 (R221.M2) — parent umbrella paideia-os#2485.
**Module:** `tools/user/libpdx-pds-parser/src/grapheme_iter.pdx` (`GraphemeIter`).
**Substrate:** `tools/user/libpdx-unicode-tables/src/grapheme.pdx` R131.M2
(`_gc_next`, `_gc_classify`), UCD-15.1 Latin + emoji baseline.
**Error band:** `0x3800..0x38FF` (parser-tier packed status).
**Date:** 2026-10-14.

## 1. Why a parser-tier wrapper

R131.M2 (`_gc_next`) already walks a UTF-8 byte slice by extended
grapheme cluster per UAX #29 Rev. 15. That substrate is the correct
tier for every byte-level TR#29 question. What it does **not** give
callers out-of-the-box:

1. **Cursor-position math for the line editor.** `_gc_next` advances
   forward only. The pds-lang REPL line editor needs both forward
   (`→`, `Alt-f`) and backward (`←`, backspace, `Alt-b`) movement at
   cluster granularity so a diacritic sticks to its base when the
   user backspaces.
2. **Argument tokenization that respects clusters.** The pds-lang
   tokenizer (and the pipeline / lambda parsers that layer on it)
   splits on ASCII whitespace, but it must never emit a token whose
   span starts or ends mid-cluster. Delegating to `_gc_next` ensures
   that an emoji ZWJ sequence or a Latin diacritic cluster is one
   token even when the display-width logic later counts it as one
   column.
3. **A single error band disjoint from the substrate's.** `_gc_next`
   returns its errors in the low 8 bits of a packed `(cursor << 32) |
   status` word with `status ∈ {0=OK, 1=EOF, 2=INVALID_UTF8}`. Those
   small-value codes are easy to collide with when a parser-tier
   caller multiplexes several substrates. The parser-tier wrapper
   lifts the invalid-UTF-8 code into the `0x3800..0x38FF` slice so
   the pds-lang REPL dispatcher's compound error path can
   discriminate "substrate-level UTF-8 fault" from "parser-tier
   grapheme fault" without further context.

The parser-tier wrapper is thin: four entry points, each a few dozen
instructions of fast-path logic plus a slow-path call into the
substrate. The ASCII fast path (bytes `0x20..0x7E` except the eight
whitespace / control bytes handled below) lets the hot path for
`.pdx` source — which is 95%+ ASCII identifiers, operators, and
punctuation — avoid the substrate's seed-and-extend state machine
entirely.

## 2. Public API

```
_gi_next_cluster(bytes_ptr, bytes_len, cursor_byte)   -> packed_u64
_gi_prev_cluster(bytes_ptr, bytes_len, cursor_byte)   -> packed_u64
_gi_count_clusters(bytes_ptr, bytes_len)              -> packed_u64
_gi_tokenize_args(bytes_ptr, bytes_len, out_ptr, out_cap) -> packed_u64
```

### 2.1 `_gi_next_cluster`

- `rdi = bytes_ptr`, `rsi = bytes_len`, `rdx = cursor_byte`.
- Advances the cursor by one grapheme cluster.
- Returns `(next_cursor << 32) | status` with
  - `status = GI_STATUS_OK (0)` → `next_cursor` is the byte offset
    one past the end of the cluster at `[cursor_byte, next_cursor)`.
  - `status = GI_STATUS_EOF (1)` → `cursor_byte >= bytes_len`;
    `next_cursor == cursor_byte`.
  - `status = GI_ERR_INVALID_UTF8 (0x3800)` → the input was not
    well-formed UTF-8 at `cursor_byte`; `next_cursor == cursor_byte`
    unchanged (the caller may skip one byte and retry).

### 2.2 `_gi_prev_cluster`

- `rdi = bytes_ptr`, `rsi = bytes_len`, `rdx = cursor_byte`.
- Walks the input backward one cluster. Because UTF-8 is
  variable-width and TR#29 clusters are variable-cluster-length, the
  only universal correctness oracle is to walk FORWARD from byte 0
  tracking the last boundary strictly less than `cursor_byte`.
  The ASCII fast path short-circuits that walk in the common case.
- Returns `(prev_cursor << 32) | status` with
  - `status = GI_STATUS_OK (0)` → `prev_cursor` is the largest
    cluster boundary strictly less than `cursor_byte`.
  - `status = GI_STATUS_BOF (1)` → `cursor_byte == 0`;
    `prev_cursor == 0`.
  - `status = GI_ERR_BAD_CURSOR (0x3803)` → `cursor_byte > bytes_len`;
    `prev_cursor == 0`.
  - `status = GI_ERR_INVALID_UTF8 (0x3800)` → the slow forward walk
    hit an undecodable byte before reaching `cursor_byte`;
    `prev_cursor == 0`.

### 2.3 `_gi_count_clusters`

- `rdi = bytes_ptr`, `rsi = bytes_len`.
- Counts clusters in the full input. Internal loop uses the same
  forward walker; delegates to the substrate per cluster.
- Returns `(count << 32) | status` with
  - `status = GI_STATUS_OK (0)` → `count` is the cluster count.
  - `status = GI_ERR_INVALID_UTF8 (0x3800)` → any sub-sequence failed
    to decode; `count == 0`.

### 2.4 `_gi_tokenize_args`

- `rdi = bytes_ptr`, `rsi = bytes_len`, `rdx = out_ptr`,
  `rcx = out_cap`.
- Splits the input into argv tokens at **ASCII-whitespace clusters**
  (SP `0x20`, TAB `0x09`, LF `0x0A`, CR `0x0D`). A single CR LF
  cluster counts as one whitespace separator (GB3). Every non-ASCII
  byte is considered part of a token.
- Emits one `GI_TOKEN_BYTES`-stride record per token into
  `out_ptr`. The record layout is
  ```
  offset  size  field
  ------  ----  ----------------------------------------------------
    0      4   byte_offset   u32 -- offset into bytes_ptr
    4      4   byte_len      u32 -- byte length of the token span
    8      4   flags         u32 -- bit 0: GI_TOK_FLAG_NON_ASCII
   12      4   reserved      u32 -- zeroed
  ```
  Total 16 B per token (`GI_TOKEN_BYTES`).
- Returns `(n_tokens << 32) | status` with
  - `status = GI_STATUS_OK (0)` → `n_tokens` is the number of
    emitted token records.
  - `status = GI_ERR_INVALID_UTF8 (0x3800)` → walker hit an
    undecodable byte; the partial write is undefined and should be
    discarded.
  - `status = GI_ERR_OUT_TOO_SMALL (0x3801)` → `out_cap <
    (needed_tokens * 16)`.
  - `status = GI_ERR_TOO_MANY_TOKENS (0x3802)` → more than
    `GI_MAX_TOKENS = 64` tokens appeared in the input.

Empty input (`bytes_len == 0`) and all-whitespace input both return
`(0 << 32) | GI_STATUS_OK` — the caller interprets zero tokens as
"nothing to run".

## 3. ASCII fast path (correctness)

### 3.1 `_gi_next_cluster`

```
if cursor_byte >= bytes_len:          return (cursor, EOF)
b0 = bytes[cursor_byte]
if b0 >= 0x80:                        delegate to _gc_next
if cursor_byte + 1 == bytes_len:      return (cursor + 1, OK)
b1 = bytes[cursor_byte + 1]
if b1 >= 0x80:                        delegate to _gc_next
if b0 == 0x0D and b1 == 0x0A:         return (cursor + 2, OK)       -- GB3
return (cursor + 1, OK)                                               -- GB999 / GB4 / GB5
```

**Proof sketch.** When both `b0` and `b1` are strictly less than
`0x80`, each is a self-contained 1-byte UTF-8 scalar in the ASCII
range. The TR#29 property of every ASCII code point is in
`{CR, LF, Control, Other}`:

| b0 | b1 | TR#29 rule | cluster bytes |
|---|---|---|---|
| ASCII printable | ASCII printable | GB999 (default break) | 1 |
| ASCII printable | ASCII control/CR/LF | GB5 (break before Control/CR/LF) | 1 |
| ASCII control | anything | GB4 (break after Control/CR/LF) | 1 |
| CR | LF | GB3 (CR × LF) | 2 |
| CR | not LF | GB4 (break after CR) | 1 |
| LF | anything | GB4 (break after LF) | 1 |

Returning `cursor + 2` iff `b0 == CR AND b1 == LF`, else `cursor + 1`
is exact for every (b0, b1) pair where both are ASCII. The fast path
is sound and complete over its guard (`b0 < 0x80 AND b1 < 0x80`).

The slow path delegates to `_gc_next` and then translates the
substrate's `status == 2` (INVALID_UTF8) into the parser-tier
`0x3800` code; `status ∈ {0, 1}` passes through unchanged.

### 3.2 `_gi_prev_cluster`

```
if cursor_byte == 0:                           return (0, BOF)
if cursor_byte > bytes_len:                    return (0, BAD_CURSOR)
bp = bytes[cursor_byte - 1]
if bp < 0x20 or bp >= 0x7F:                    delegate to slow forward walk
if cursor_byte == 1:                           return (0, OK)
bpp = bytes[cursor_byte - 2]
if bpp >= 0x80:                                delegate to slow forward walk
return (cursor_byte - 1, OK)
```

**Proof sketch.** When `bp` is in `0x20..0x7E` (ASCII printable,
non-control) **and** `bpp` is also strictly less than `0x80` (ASCII,
not a multi-byte continuation), the cluster boundary at
`cursor_byte - 1` is well-defined by GB999 and no earlier byte could
be part of the same cluster. The two guards exclude:

- CR/LF (which may form a CR LF cluster with the previous byte).
- Control bytes (whose rules we leave to the substrate).
- A multi-byte lead or continuation at `cursor_byte - 2` (which
  could mean `bp` is actually part of a larger cluster that extends
  before `cursor_byte - 1`, or that `cursor_byte - 2` is a combining
  mark continuation attached to a base before it).
- `bp >= 0x80` (clearly not ASCII; could be a combining mark lead
  byte like 0xCC/0xCD or a ZWJ `0xE2 0x80 0x8D`).

The slow path walks forward from byte 0 using `_gi_next_cluster`,
tracking the largest `next_cursor` strictly less than `cursor_byte`.
Termination: each iteration advances by ≥ 1 byte (the substrate
never returns `next_cursor == cursor` on OK), so the loop finishes
in at most `bytes_len` iterations.

### 3.3 `_gi_count_clusters`

The counter walks forward using `_gc_next` directly (one CALL per
cluster), summing OK returns. The ASCII fast path is embedded in
`_gi_next_cluster`, not here, because the inner loop is dominated by
the CALL cost either way; running the fast path through a direct
inline would duplicate the whole decode staircase. The design keeps
the counter dumb: let it delegate per step so the substrate's
Hangul-stub M2.1 landing picks up for free.

### 3.4 `_gi_tokenize_args`

The tokenizer calls `_gi_next_cluster` in a loop over the input,
testing the first byte of each cluster against the four ASCII
whitespace bytes `{0x20, 0x09, 0x0A, 0x0D}`. On a whitespace cluster
boundary the in-progress token (if any) is emitted and a new one
starts after the whitespace. A non-whitespace cluster appends to the
in-progress token span; any byte in the cluster with the high bit
set sets `GI_TOK_FLAG_NON_ASCII` in the token's flags.

The CR LF cluster (two bytes) is treated as a single whitespace
separator — the first byte is `0x0D` and clusters that start with CR
are always whitespace separators.

## 4. UCD subset

### 4.1 Delegated to the substrate

The TR#29 property table (`CR`, `LF`, `Control`, `Extend`, `ZWJ`,
`Regional_Indicator`, `Pictographic`, `Other`) is **not re-declared**
here. The substrate's `_gc_classify` already walks the reduced
Latin + emoji baseline (UCD-15.1 pin via `LPX_UNICODE_UCD_VERSION`),
and `_gc_next` applies the GB1..GB13 rule gates over it. The
parser-tier wrapper's only new table is the ASCII-fast-path
property byte described next.

### 4.2 ASCII property table (shipped in `.rodata`)

`_gi_ascii_prop_table : [u8; 128]` maps each ASCII byte to one of:

| value | meaning | bytes |
|---|---|---|
| `0` | `GI_PROP_PRINT` (word byte; default) | `0x20..0x7E` minus WS |
| `1` | `GI_PROP_WHITESPACE` | `0x09, 0x0A, 0x0D, 0x20` |
| `2` | `GI_PROP_CONTROL` | `0x00..0x1F` minus WS, and `0x7F` |

The tokenizer uses `_gi_ascii_prop_table[b]` instead of four
sequential `cmp` immediates. At 100 kchar/s throughput target, one
table load (one cache-line fill the first time, zero cost thereafter)
beats three branches on cold-cache input. The table is 128 bytes;
`caps.decl`'s linker-dependency clause stays "no cross-library
dependency" because the table lives in the module's own `.rodata`.

### 4.3 No new UCD data

Latin + CJK + emoji + Hangul coverage is **inherited** from the
substrate's R131.M2 table (`_gc_classify`'s range dispatch). The
parser-tier wrapper does not ship a GraphemeBreakProperty.txt
subset of its own — the substrate's existing coverage is the right
tier for every multi-byte property check.

## 5. Register plan

### 5.1 `_gi_next_cluster`

- Fast path: pure leaf, no callee-save push, no frame. Caller-save
  (`rax`, `r11`) only.
- Slow path: `sub rsp, 8; call _gc_next; translate; add rsp, 8; ret`.
  Entry `rsp%16==8`, `sub rsp, 8` → `rsp%16==0` pre-CALL (SysV
  requirement). All status comparisons use imm32-safe immediates
  (`0`, `1`, `2`, `0x3800`).

### 5.2 `_gi_prev_cluster`

- Fast path: pure leaf (same shape as `_gi_next_cluster`).
- Slow path: 5 callee-save pushes (`rbx, r12, r13, r14, r15 = 40 B`).
  Entry `rsp%16==8`, +40 → `rsp%16==(8-40)%16==0` pre-CALL. No pad.
  - `rbx` = `bytes_ptr`
  - `r12` = `bytes_len`
  - `r13` = `cursor_byte` (target)
  - `r14` = walker (current position)
  - `r15` = `last` (largest boundary strictly less than target)

### 5.3 `_gi_count_clusters`

- 4 callee-save pushes (`rbx, r12, r13, r14 = 32 B`) + `sub rsp, 8`
  pad. Entry `rsp%16==8`, +40 → `rsp%16==0` pre-CALL.
  - `rbx` = `bytes_ptr`
  - `r12` = `bytes_len`
  - `r13` = walker
  - `r14` = count

### 5.4 `_gi_tokenize_args`

- 5 callee-save pushes (`rbx, r12, r13, r14, r15 = 40 B`) +
  `sub rsp, 16` for two local qwords. Entry `rsp%16==8`, +56 →
  `rsp%16==0` pre-CALL.
  - `rbx` = `bytes_ptr`
  - `r12` = `bytes_len`
  - `r13` = walker (cursor)
  - `r14` = `out_ptr` base
  - `r15` = `tok_start` (walker position when the current token
    began; `0xFFFFFFFF_FFFFFFFF` when between tokens)
  - `[rsp+0]` = `out_cap`
  - `[rsp+8]` = `n_tokens` (counter; also used to compute write
    offset `n_tokens * 16`)

## 6. Status-code namespace

| code | mnemonic | returned by |
|---|---|---|
| `0` | `GI_STATUS_OK` | all |
| `1` | `GI_STATUS_EOF` | `_gi_next_cluster` |
| `1` | `GI_STATUS_BOF` | `_gi_prev_cluster` (status discriminated by the opcode's return context) |
| `0x3800` | `GI_ERR_INVALID_UTF8` | all |
| `0x3801` | `GI_ERR_OUT_TOO_SMALL` | `_gi_tokenize_args` |
| `0x3802` | `GI_ERR_TOO_MANY_TOKENS` | `_gi_tokenize_args` |
| `0x3803` | `GI_ERR_BAD_CURSOR` | `_gi_prev_cluster` |

The `0x3800..0x38FF` slice is disjoint from every other parser-tier
and user-space packed-status range in the paideia-os tree. Slots
`0x3804..0x38FF` are reserved for M3+ error kinds (per-token width
budget, Hangul-cluster split, SpacingMark attach, etc.).

## 7. Encoder discipline (paideia-as)

- **No `test rN, rN`.** Every zero-check is `cmp reg, 0; je/jne`.
- **No `and rN, imm64`.** The ASCII high-bit guard uses
  `cmp rN, 0x80; jae ...` which fits imm32 sign-safe. The low-byte
  status mask uses `and rN, 0xFF` (imm32 safe). The `0xFFFFE710`
  substrate sentinel is never compared against directly — the
  substrate's `_gc_next` returns a packed 32-bit status in the low
  byte (`0/1/2`), not the error band.
- **No 2-op `imul r, imm`.** Token-stride `* 16` is `shl rN, 4`.
- **No multiline `pub let = "..."`.** Every justification is a
  single logical line.
- **Module basename** `grapheme_iter.pdx` matches `module
  GraphemeIter`.
- **Labels prefixed `gi_`** (`gi_nc_` for `_gi_next_cluster`,
  `gi_pc_` for `_gi_prev_cluster`, `gi_cc_` for `_gi_count_clusters`,
  `gi_tk_` for `_gi_tokenize_args`). Disjoint from the parser-tier
  `u8n_`, `pl_`, `rp_`, `ll_`, `cc_`, `clo_`, `hm_`, `rt_`, `dl_`,
  `sch_sig_`, `cmd_sig_`, `se_` namespaces, and from every reserved
  keyword (`loop`, `if`, `let`, `fn`, `ret`, `done`).
- **All `cmp reg, imm` immediates** `≤ 0x3803 < 0x80000000` so
  direct `cmp reg, imm32` is sign-extension-safe. No MOVABS staging.
- **Byte loads** via `mov_b rN, [base + idx]` (zero-extends into
  full qword; sidesteps the "high bits dirty" trap).
- **Byte stores** via `mov_b [base + disp], rN` (register-indexed
  byte store, same shape as libpdx-audit `audit_file_sink`).
- **u32 stores** via `mov_d [base + disp], rN`.
- **r11 is NEVER held across a nested CALL** — values that survive
  go in `r12..r15` or stack.

## 8. Representative TR#29 test vectors

The 15-item verification corpus is deferred to R221.M7 (fuzz
corpus); the design doc enumerates the representative cases this
module's state machine must handle correctly:

### 8.1 Pure ASCII
- `""` → 0 clusters, next(0) = EOF, prev(0) = BOF.
- `"a"` → 1 cluster, next(0) = 1, prev(1) = 0.
- `"abc"` → 3 clusters, next(0)=1, next(1)=2, next(2)=3, prev(3)=2.
- `"a b"` → 3 clusters, tokenize → 2 tokens ("a", "b").
- `" a "` → 3 clusters, tokenize → 1 token ("a").

### 8.2 ASCII with CR LF
- `"a\r\nb"` → 3 clusters (a, CR LF, b), tokenize → 2 tokens
  ("a", "b"). Also tests GB3.
- `"\r\n"` → 1 cluster, next(0) = 2 (via substrate), prev(2) = 0.
- `"\r"` → 1 cluster, next(0) = 1, prev(1) = 0.

### 8.3 Latin diacritics (combining marks)
- `"é"` (`"e" + U+0301`, bytes `0x65 0xCC 0x81`) → 1 cluster,
  next(0) = 3 (substrate's GB9 extend), prev(3) = 0, tokenize →
  1 token with `GI_TOK_FLAG_NON_ASCII` set.
- `"é f̂"` → 2 clusters per side, tokenize → 2 tokens.

### 8.4 Emoji ZWJ sequence
- `"\u{1F468}\u{200D}\u{1F469}"` (man + ZWJ + woman, UTF-8 bytes
  `F0 9F 91 A8 E2 80 8D F0 9F 91 A9`) → 1 cluster, next(0) = 11
  (substrate's GB11). This passes through the slow path entirely.

### 8.5 Regional indicator flag
- `"\u{1F1EB}\u{1F1F7}"` (RI "FR" flag, UTF-8 bytes `F0 9F 87 AB
  F0 9F 87 B7`) → 1 cluster, next(0) = 8 (substrate's GB12).

### 8.6 Error paths
- `"\xC0\x00"` (invalid UTF-8 lead) → `_gi_next_cluster(0)` →
  `(0 << 32) | 0x3800`.
- `"a\xC0"` (ASCII then invalid) → `_gi_next_cluster(0)` returns 1
  (ASCII path); `_gi_next_cluster(1)` returns `(1 << 32) | 0x3800`.
- `_gi_prev_cluster(bytes_len=4, cursor_byte=99)` → `(0 << 32) |
  0x3803`.

### 8.7 Throughput goal

The 100 kchar/s target on QEMU is met by the ASCII fast path: on a
pure-ASCII input, `_gi_next_cluster` is six instructions (bounds +
load + ASCII check + load + CR-LF check + return), approximately
3 ns/cluster on a modern core. 100,000 clusters/sec = 10 µs/cluster
budget; the fast path is ~300× faster than the budget on the hot
path. The slow path (non-ASCII) is bounded by the substrate's
cluster speed (~15 ns/cluster per the R131.M2 fingerprint), still
well inside the budget.

## 9. Interaction with other modules

- **R221.M1 Utf8Nfc** (`utf8_nfc.pdx`): this module consumes the
  NFC-normalised output buffer produced by `_u8n_decode_and_normalize`.
  Combining marks are already in canonical order after NFC, so the
  substrate's `_gc_next` sees the canonical byte stream.
- **R221.M3 width pass** (not landed): will consume this module's
  cluster boundaries + the per-cluster TR#11 width classification to
  produce the display-column cursor map. The tokenizer's
  `GI_TOK_FLAG_NON_ASCII` is a hint for M3's hot path (any token
  with the flag clear is guaranteed one-column-per-byte).
- **R221.M4 context-tracking lexer** (not landed): calls
  `_gi_tokenize_args` to split the NFC-normalised line into argv
  tokens, then runs its context-tracking state machine over the
  resulting record array.
- **R223.M1 Pipeline / R222.M* cmd-functor / R224.M1 LambdaLit**:
  these already receive post-NFC input. The grapheme-aware
  tokenizer complements, not replaces, their argv parsing — pipeline
  stages still split on `|`, and lambda params still split on `,`.
  `_gi_tokenize_args` is specifically for the LINE EDITOR's
  cursor-math + argv-ish word splitting; pipeline parsers use their
  own grammar.
- **Substrate `_gc_next` / `_gc_classify`** (R131.M2,
  libpdx-unicode-tables): resolved at link time via `--extra-obj-dir
  tools/user/libpdx-unicode-tables/build-out`. The parser-tier
  module adds the same linker-flag requirement as R221.M1 Utf8Nfc.

## 10. Forward path

- **R221.M3 TR#11 width pass.** Adds per-cluster width using
  libpdx-unicode-tables's `_width_char` / `_width_str`. This module
  stays authoritative for cluster boundaries; M3 only annotates them.
- **R221.M4 context-tracking lexer.** Consumes the token stream
  this module emits; the per-token `GI_TOK_FLAG_NON_ASCII` bit
  short-circuits the ASCII-only branches of the lexer's rune-class
  dispatch.
- **R221.M5 unified AST.** AST node spans are byte offsets into the
  original NFC-normalised buffer; cluster boundaries from this
  module ensure every span starts and ends on a cluster boundary
  (invariant checked at M5's build time).
- **R221.M6 span-mapping NFC variant.** The pre-NFC → post-NFC byte
  map is composable with this module's cluster boundaries, so an
  LSP hover query at a pre-NFC character position can resolve to the
  containing post-NFC cluster.
- **R221.M7 parser fuzz corpus.** The 15-case TR#29 corpus listed
  in §8 lands as `tests/proptest_grapheme_iter.pdx` alongside the
  R221.M1 fuzz corpus.

## 11. References

- Unicode Technical Report #29 Rev. 15,
  https://www.unicode.org/reports/tr29/tr29-43.html (grapheme break
  rules GB1..GB13 + GB999).
- UCD 15.1 pin: `tools/user/libpdx-unicode-tables/src/lib.pdx`
  `LPX_UNICODE_UCD_VERSION_MAJOR = 15, _MINOR = 1`.
- Substrate design doc:
  `design/terminal/libpdx-unicode-tables.md` §4 (R131.M2).
- Parser-tier parent brief:
  `design/terminal/semantic-shell-language-plan.md` §4 R221.
