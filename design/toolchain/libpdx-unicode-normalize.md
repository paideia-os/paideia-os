# libpdx-unicode-tables Normalization (R131.M3)

## Status

**Wave:** R131 (semantic shell -- Unicode substrate umbrella,
paideia-os#2480).
**Milestone:** M3 (NFC/NFD/NFKC/NFKD normalization, paideia-os#2614).
**Library version at landing:** 1.2.0.
**Date:** 2026-10-11.

## Scope

M3 adds the four Unicode Normalization Forms (per UAX #15 Rev. 55) to
the user-space Unicode library the shell, pds, and the GPU-native
terminal all link. Four public primitives share one signature:

```
_norm_nfd (bytes_ptr, bytes_len, out_ptr, out_cap) -> packed_u64
_norm_nfkd(bytes_ptr, bytes_len, out_ptr, out_cap) -> packed_u64
_norm_nfc (bytes_ptr, bytes_len, out_ptr, out_cap) -> packed_u64
_norm_nfkc(bytes_ptr, bytes_len, out_ptr, out_cap) -> packed_u64
```

Return shape: `(out_bytes_written << 32) | status` with status in
{0=OK, 1=OUT_TOO_SMALL, 2=INVALID_UTF8}. Every function is a pure
leaf-with-nested-call -- no capability bind, no syscall.

M3 is the FIRST milestone of this library to carry a reduced UCD
table set. Earlier milestones (M1 UTF-8, M2 grapheme) got away with
hand-coded range tables because the TR#29 reduced-Latin-plus-emoji
set only needs seven property classes. Normalization needs real
tables: canonical / compatibility decomposition pairs, canonical
combining classes, and (in the full UCD) composition exclusions.

## Reduced UCD scope at M3

### Canonical decompositions (used by NFC + NFD + NFKC + NFKD)

* **Latin-1 Supplement** U+00C0..U+00FF -- 53 entries. Grave,
  acute, circumflex, tilde, dieresis, ring, cedilla over A/C/E/I/N/
  O/U/Y plus their lowercase variants.
* **Latin Extended-A** U+0100..U+017F -- 108 entries. Macron,
  breve, ogonek, dot, caron variants for most European languages.
  Entries without a canonical decomp in the UCD (Đ, Ħ, ı, Ł, ŋ, Œ,
  Ŧ, etc.) are omitted. The 94 Latin Extended-A entries that double-
  decompose via Latin-1 Supplement do not exist (the first
  double-decomposer is U+01DE in Latin Extended-B, which this
  baseline does not land), so the decomposer stays single-level.

Total: 161 canonical entries.

### Compatibility decompositions (NFKC/NFKD only)

* **Fullwidth-ASCII** U+FF01..U+FF5E -- 94 entries. Each maps to the
  corresponding ASCII code point by subtracting 0xFEE0 (so U+FF41
  maps to U+0061). Single-cp decomposition (no combining mark).

Total: 94 compatibility entries, flagged in the unified table by
`mark == 0`.

### Composition exclusions

**Empty** at M3. Every canonical decomposition is therefore
reversible by the composition step. The full-UCD landing at M3.2
reads Composition_Exclusions from
DerivedNormalizationProps.txt and gates the compose-step on it.

### CCC table

Sparse ~10-entry table of (cp, ccc) pairs covering the common
combining marks (U+0300..U+030E = 230, U+0327/U+0328 = 202). Any
cp in U+0300..U+036F not explicitly listed defaults to 230 (the
dominant value in that range per UCD). cps outside the range
return 0 (starter).

### Scripts deferred

Explicitly out of scope at M3 (tracked in STATUS.md's M3.1+
follow-ups):

* **Devanagari** (U+0900..097F) and other Indic scripts. Need the
  full Indic combining set and Nukta-reordering rules.
* **Hebrew** (U+0590..05FF). Niqqud ordering.
* **Arabic** (U+0600..06FF, presentation forms at U+FB50..FDFF,
  U+FE70..FEFF). Lam-alef compatibility decompositions.
* **CJK Compatibility** (U+F900..FAFF, U+2F800..2FA1F). Canonical
  decompositions for IDS variants.
* **Hangul syllables** (U+AC00..D7A3). TR#15 §16 defines these
  algorithmically (L+V+T math) rather than by table; landing is a
  code change at M3.2 not a data change.
* **Latin Extended-B** (U+0180..) and beyond. Extended precomposed
  diacritics.

## Four-phase algorithm (UAX #15 Rev 55 reduced)

Every public API call runs the same four phases:

1. **Decompose.** Walk the input one cp at a time via
   `utf8_decode_cp`. For each cp, look up the (compat or canonical)
   decomposition in the unified table:
   * No match -- emit (cp, ccc(cp)) as one scratch entry.
   * Match -- emit (part0, ccc(part0)), then (part1, ccc(part1))
     if part1 != 0 (compat singletons have part1 == 0 and emit
     just one entry).
   The reduced table encodes fully-decomposed forms, so a single
   lookup suffices per cp. The forward path to full UCD lands
   two-level decomp as a worklist at M3.2.

2. **Canonical ordering (TR#15 §12).** Bubble-sort runs of
   non-starter entries by CCC. Starters (ccc == 0) terminate a
   run; within each run, swap adjacent entries while
   `scratch[i].ccc > scratch[i+1].ccc`. For single-mark input
   this is a no-op; it is wired for correctness under multi-mark
   input the proptest length-bound invariant exercises.

3. **Composition (TR#15 §13, NFC + NFKC only).** Left-to-right
   single pass over the scratch. Maintain a "last starter" index.
   For each non-starter entry, call
   `_norm_lookup_compose(scratch[last_starter].cp,
   scratch[i].cp)`:
   * On hit -- replace scratch[last_starter] with (composed, 0),
     tombstone scratch[i] (set its CCC byte to 0xFF, keep cp for
     debuggability). The composed starter stays at last_starter
     and can match the NEXT non-starter in the same pass.
   * On miss -- advance.
   After the walk, run a compaction pass that slides non-tombstone
   entries down to produce a dense scratch for the encode phase.
   Composition_Exclusions being empty at M3 means every table
   match is composable; the full-UCD landing adds a per-entry
   exclusion check at M3.2.

4. **Encode.** For each non-tombstoned scratch entry (`ccc != 0xFF`),
   call `utf8_encode_cp(cp, out_ptr+pos, out_cap-pos)`. On buffer
   underrun (encode returns the UTF8_DST_TOO_SMALL band code
   0xFFFFE704), bail with status=1 and out_bytes=0 (atomic
   failure: nothing partial left in the output). On success,
   advance pos by bytes_written. Return
   `(out_bytes_written << 32) | 0`.

## Internal structure

```
_norm_nfd ─┐
_norm_nfkd ─┤
_norm_nfc  ─┼─> _norm_core(form_flag) ─┬─> _norm_decompose
_norm_nfkc ─┘                           ├─> _norm_sort_scratch
                                        ├─> _norm_compose_scratch   (C-forms only)
                                        └─> _norm_encode_scratch

_norm_decompose     ─> utf8_decode_cp, _norm_lookup_decomp, _norm_lookup_ccc
_norm_compose_scratch ─> _norm_lookup_compose
_norm_encode_scratch ─> utf8_encode_cp
```

`form_flag` is a two-bit value:
* bit 0 = compat (0 = canonical only, 1 = canonical + compat)
* bit 1 = compose (0 = D-form, 1 = C-form)

So NFD=0b00, NFKD=0b01, NFC=0b10, NFKC=0b11.

## Scratch buffer and reentrancy

The decomposed intermediate representation lives in a static .bss
buffer `_norm_scratch` (8 KiB, 1024 entries of 8 bytes each). Each
entry packs cp (low 32 bits) and CCC (high 32 bits), with CCC=0xFF
reserved as a tombstone sentinel (real CCC values are 0..240).

**Single-thread by construction.** Overlapping calls -- including
a signal handler invoking `_norm_nfc` while the main thread is
part-way through its own `_norm_nfc` -- corrupt the intermediate
scratch and may corrupt the output. The ring-3 consumers that link
this today all run on a single thread with no signal-handler path
through text processing. If multi-threading support lands at
R131.M5+, the scratch moves to a caller-supplied workspace
argument.

**Scratch capacity: 1024 entries.** For input bytes_len > 1024 the
decompose phase MAY overflow. Current behaviour: return
status=1 (OUT_TOO_SMALL). This treats scratch overflow as a
buffer-space exhaustion equivalent to the caller's out_cap being
too small -- a correctness-safe refusal, never a silent truncation.

## Public API return shape

Every public API returns one packed `u64`:

```
bits [63:32]  out_bytes_written   (0 on failure, >0 on success)
bits [7:0]    status              (0=OK, 1=OUT_TOO_SMALL, 2=INVALID_UTF8)
bits [31:8]   reserved            (always 0)
```

Caller discrimination:

```
mov r11, rax
and r11, 0xFF           -- r11 = status (0..2)
cmp r11, 0
jne <failure path>
shr rax, 32             -- rax = out_bytes_written on success
```

## Encoder pitfall notes

Normalisation hits the paideia-as assembler's imm-encoding corners
in these specific places; the softarch brief flagged each as a
re-hit risk and the normalize body cites every one at its gate.

### 1. Sort-step CCC compare

The sort step's `cmp ccc[i], ccc[i+1]` is a REGISTER-REGISTER
compare. The CCC values live in the high 32 bits of scratch
entries, extracted via `shr reg, 32`. All CCC values are 0..240
which fit comfortably in imm8 sign-safe range, so a direct
`cmp reg, imm` is also safe when needed (e.g. the starter check
`cmp ccc, 0; je ...`).

### 2. Tombstone sentinel

Tombstone is CCC==0xFF (255). Checked via `mov rbp, 0xFF; cmp rcx,
rbp; je ...`. 0xFF fits imm8 sign-safe (as i32 == 255, as i64 ==
255 after zero-extension via mov imm32), so `mov rbp, 0xFF` is
plain `mov r64, imm32`. The staging register is needed only for
the compare; `cmp reg, 0xFF` directly would also work since 0xFF
sign-extends identically from imm32.

### 3. Table lookup stride

The decomp table has 3 u32 values per entry (12 bytes). We use
pointer-advance (`add r10, 12`) rather than SIB indexing (there is
no `*12` scale factor in x86-64). Index-based access would require
`shl r11, 2; lea r11, [r11 + r11*2]; add r10, r11` to compute
`i*12`. Pointer-advance is shorter and avoids the 2-op imul
pitfall (brief rule: no 2-op `imul r, imm`).

### 4. Scratch stride

Scratch entries are 8 bytes. Index-to-offset is `shl r11, 3` (one
instruction). The 32-byte alignment of the .bss `_norm_scratch`
block (declared with `@align(8)` to match the entry stride)
guarantees the base pointer is 8-aligned; adding `i*8` to it
preserves alignment, so every `mov [r10], rax` is a naturally-
aligned 8-byte store.

### 5. 32-bit extracts

cp is in the low 32 bits of a scratch qword. We extract via the
pair `shl rdi, 32; shr rdi, 32` rather than `and rdi, 0xFFFFFFFF`
because 0xFFFFFFFF as imm32 sign-extends to -1 which would zero
nothing. The shift pair is semantically identical and
sign-extension-safe.

### 6. MOVABS for error-band constants

The internal error-band codes `NORM_INVALID_UTF8_CODE` (0xFFFFE720)
and `NORM_OUT_TOO_SMALL_CODE` (0xFFFFE721) are > 0x7FFFFFFF and
need MOVABS staging if ever written to a register for compare.
In practice the public API packs these into the status byte (0..2)
and never returns them raw, so the only sites that MOVABS these
constants are at the status-code export boundary (`pub let NORM_
INVALID_UTF8_CODE : u64 = 0xFFFFE720` and its sibling in the
header). The assembler emits MOVABS automatically there.

### 7. Argument shuffle in public wrappers

Each wrapper (`_norm_nfd` etc.) must shift its 4 args
(rdi,rsi,rdx,rcx) through to `_norm_core`'s 5-arg signature
(form_flag, src_ptr, src_len, out_ptr, out_cap). The shuffle
is unidirectional (highest-index first) so one register's new
value never clobbers a yet-to-be-moved earlier register:

```
mov r8,  rcx     # r8  <- out_cap
mov rcx, rdx     # rcx <- out_ptr
mov rdx, rsi     # rdx <- src_len
mov rsi, rdi     # rsi <- src_ptr
mov rdi, <form>  # rdi <- form_flag constant
```

## Fingerprint goldens

8 TAG lines at `tests/fingerprints/normalize.golden`:

| TAG | FORM | INPUT_HEX | OUTPUT_HEX | Covers |
|-----|------|-----------|------------|--------|
| NFC_A_ACUTE | NFC | 61CC81 | C3A1 | compose Latin-1 Sup |
| NFD_A_ACUTE_PRECOMPOSED | NFD | C3A1 | 61CC81 | decompose Latin-1 Sup |
| NFKC_FULLWIDTH | NFKC | EFBD81 | 61 | compat decompose single-cp |
| NFKD_FULLWIDTH | NFKD | EFBD81 | 61 | same, no-compose variant |
| NFC_IDEMPOTENT | NFC | C3A1 | C3A1 | NFC(NFC(x)) == NFC(x) |
| NFD_EMPTY | NFD | | | empty-input passthrough |
| NFC_MULTIPLE | NFC | 63616665CC81 | 636166C3A9 | multi-cp input |
| NFC_PASSTHROUGH | NFC | 68656C6C6F | 68656C6C6F | ASCII-only stable |

## Proptest invariants

Four invariants at `tests/proptest_normalize.pdx`:

* **Idempotence** -- NFC(NFC("a"+U+0301)) == NFC("a"+U+0301).
* **Round-trip** -- NFC(NFD(NFC(precomposed á))) == precomposed á.
* **UTF-8 validity** -- `utf8_is_valid` returns 1 on every form's
  output for the "a + U+0301" fixture.
* **Length bound** -- output.len <= 3 * input.len for NFC and NFD
  on the "cafe + U+0301" (6-byte) fixture.

Fail codes in the 0xFFFFED7x band (extends the existing TestLexer
family: 0xFFFFED6x is ProptestGrapheme).

## Forward path to full UCD (M3.1+)

* **M3.1** -- Full CCC table loaded from UCD UnicodeData.txt
  (field 3). About 230 non-zero entries from the full UCD.
* **M3.2** -- Full canonical decomposition table from UCD
  UnicodeData.txt (field 5, filtered to non-compat), including
  the multi-level entries that need the worklist decomposer.
  Also lands Composition_Exclusions from
  DerivedNormalizationProps.txt (singletons + non-starters +
  script-specific pairs).
* **M3.3** -- Hangul syllable decomp / compose via the TR#15 §16
  algorithmic path.
* **M3.4** -- Full compatibility decomposition table (Arabic
  presentation forms, CJK compatibility, Mathematical
  Alphanumeric symbols, fullwidth non-ASCII, Hangul fullwidth).

Every forward-path milestone preserves the M3 public API and the
0xFFFFE720..0xFFFFE72F error band; later milestones only extend
the table and relax the "reduced baseline" caveats in STATUS.md.

## Upstream

* paideia-os#2480 -- R131 Unicode substrate umbrella.
* paideia-os#2612 -- R131.M1 UTF-8 primitives.
* paideia-os#2613 -- R131.M2 grapheme-cluster iterator.
* paideia-os#2614 -- this M3 ticket.

Rust-side mirror (future): a `paideia-as-unicode::normalize`
module paralleling this library's reduced table set so the
compiler's string-literal normalization pass can run against the
same canonical representation shell / pds use at runtime.
