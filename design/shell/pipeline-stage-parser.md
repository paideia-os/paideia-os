# Pipeline-stage parser (R223.M1)

**Status:** v0.1 (R223.M1 — paideia-os#2666)
**Date:** 2026-10-14
**Author:** softarch (Wave UMB-W26)
**Scope:** The user-space parser-tier module that turns a shell
input line like `cmd1 arg | cmd2 arg | cmd3 arg` into a flat array
of `PipelineStage` records that downstream passes (R222 cmd-functor
dispatch, R129.M5 renderer-override detector, R223.M2 planner-ABI
materialiser) consume. Lands in `libpdx-pds-parser` at
`tools/user/libpdx-pds-parser/src/pipeline.pdx`.

---

## 1. Position in the parser substrate

```
                 raw user input bytes
                           |
                           v
       +------------------------------------------+
       | R221.M1  Utf8Nfc::_u8n_decode_and_       |
       |          normalize   (UTF-8 + NFC)       |
       +---------------------+--------------------+
                             |
                             v  NFC-form bytes
       +------------------------------------------+
       | R223.M1  Pipeline::_pl_parse  (THIS)     |
       +---------------------+--------------------+
                             |
                             v  PipelineStage[0..n]
                 +-----------+-----------+
                 |                       |
                 v                       v
       +---------------+       +--------------------+
       | R222.M*  cmd- |       | R129.M5  renderer- |
       | functor sig   |       | override `as` tail |
       | matcher       |       | post-pass          |
       +---------------+       +--------------------+
                             |
                             v  planner-ready stage list
       +------------------------------------------+
       | R223.M2  _pl_materialise -> kernel-side  |
       |          Pipeline::pipeline_plan input   |
       +------------------------------------------+
```

R221.M1 lands the UTF-8 + NFC pre-pass that this module's input
contract assumes. R221.M4 (the context-tracking lexer, not yet
landed) is a separate, richer lexer for the pds-lang BODY; this
module is deliberately NARROWER — a shell-pipeline-only parser
that handles exactly the `cmd ... | cmd ...` outer-grammar and
leaves the per-stage argv as raw (offset, len) spans for a
downstream pass to interpret.

## 2. Grammar

```
pipeline  := stage ( '|' stage )*
stage     := word ( WS+ word )*
word      := bareword | dq_string | sq_string
bareword  := ( non_ws_byte | '\|' | '\"' )+
dq_string := '"' ( non_dq_byte | '\"' | '\\' )* '"'
sq_string := '\'' ( non_sq_byte )* '\''
WS        := ' ' | '\t'
```

Where `non_ws_byte` is any byte not in `{ SP, TAB, '|', '"', '\'' }`
(plus the backslash which is special-cased in `bareword`), and
`non_dq_byte` / `non_sq_byte` are any bytes other than the matching
closing quote.

### 2.1 Minimal examples

| Input                       | Stages | Argv per stage                     |
|-----------------------------|--------|------------------------------------|
| `ls`                        | 1      | cmd=`ls`                           |
| `ls -l`                     | 1      | cmd=`ls`, argv=[`-l`]              |
| `ls -l \| wc`               | 2      | cmd=`ls`,argv=[`-l`]; cmd=`wc`     |
| `echo "hello world"`        | 1      | cmd=`echo`, argv=[`hello world`]   |
| `echo 'can'\''t'`           | 1      | cmd=`echo`, argv=[`can't`] after unescape¹ |
| `echo a\|b`                 | 1      | cmd=`echo`, argv=[`a\|b`] (raw)    |
| `grep as file`              | 1      | cmd=`grep`, argv=[`as`,`file`]²    |
| `ls \| wc as table`         | 2      | …; stage[1] argv=[`as`,`table`]³   |

¹ The sq_string grammar does not honour `\'`; the SQ-close is any
`'`. In the example, the first `'` closes the sq-word, then the
`\'` is parsed as a bareword `\'` escape (`HAS_ESCAPES` set), then
the second `'` opens another sq-word. This matches POSIX
shell behaviour (`'can'\''t'` = three concatenated adjacent words
in POSIX; this parser emits them as a single argv only if downstream
re-concatenation is added — at M1 they are three argv entries, and
the downstream functor can glue them).

² `as` outside a tail position is an ordinary bareword; no renderer
is implied. The R129.M5 post-pass only strips the LAST stage's
tail-pair `("as", <name>)`.

³ Last stage's tail `("as", "table")` is caught by the R129.M5
post-pass, which decrements n_args by 2 and writes the renderer id
to a sibling slot.

## 3. State machine

Four-state tokeniser; state byte lives at `[rsp + 16]` in `_pl_parse`.

```
          +--------+   SP/TAB      +--------+
          |   WS   | ------------> |   WS   | (skip)
   start->|        |
          |        | --other---->  |  BARE  | (word_start = i)
          |        | --'"'---->    |   DQ   | (word_start = i+1,
          |        |                           HAS_QUOTES |=)
          |        | --'\''--->    |   SQ   | (same)
          |        | --'|'---->    commit stage, back to WS
          +--------+
                                   |
                                   v on SP/TAB      -> emit, state=WS
                   +--------+ ---  on '|'           -> emit, commit
                   |  BARE  | ---  on '\' + ('|'|'"'| other)
                   +--------+       -> consume both; HAS_ESCAPES |= on
                                      recognised escape

                   +--------+ ---  on '"'           -> emit, state=WS
                   |   DQ   | ---  on '\' + ('"'| other)
                   +--------+       -> consume both; HAS_ESCAPES |= on
                                      `\"`

                   +--------+ ---  on '\''          -> emit, state=WS
                   |   SQ   |      (no escapes at all; '\\' is literal)
                   +--------+
```

Terminal states (EOI dispatch):

| State at EOI | Dirty | stages_written | Result                        |
|--------------|:-----:|:---------------:|-------------------------------|
| WS           | 0     | 0               | PL_OK with n_stages = 0 (empty) |
| WS           | 0     | > 0             | **PL_ERR_EMPTY_STAGE** (trailing `|`) |
| WS           | 1     | *k*             | commit; PL_OK with n_stages = *k* + 1 |
| BARE         | *     | *               | emit trailing word; commit; PL_OK |
| DQ           | *     | *               | **PL_ERR_UNTERMINATED_QUOTE** |
| SQ           | *     | *               | **PL_ERR_UNTERMINATED_QUOTE** |

Where `dirty = 1` iff the current (not-yet-committed) stage has
been populated with at least one word (cmd_name slot set).

## 4. PipelineStage record

Fixed 64-byte stride, cache-line-sized. Layout matches the
`Pipeline` module's `PL_OFF_*` constants:

```
offset  size  field              type   notes
------  ----  ------------------ ------ ---------------------------------
  0      4   cmd_name_offset    u32    byte offset into input buffer
  4      2   cmd_name_len       u16    length of cmd_name span
  6      2   n_args             u16    0..PL_MAX_ARGS (8)
  8     32   argv_offsets[8]    u32[8] byte offsets into input buffer
 40     16   argv_lens[8]       u16[8] byte lengths of argv spans
 56      2   flags              u16    bitfield (below)
 58      6   _reserved[6]       u8[6]  zero at M1
------  ----
total   64   PL_STAGE_SIZE
```

Flag bits (`flags` u16):

| Bit | Name                  | Semantics                              |
|----:|-----------------------|-----------------------------------------|
| 0   | PL_FLAG_HAS_ESCAPES   | some word uses `\|` or `\"`; downstream un-escape needed |
| 1   | PL_FLAG_HAS_QUOTES    | some word was DQ or SQ at parse time (informational)     |
| 2..15 | reserved            | zero at M1                              |

### 4.1 Spec reconciliation (64 B vs. field list)

The parent brief (umbrella decomposition for #2666) writes
`PipelineStage (64B)` and `_reserved: [u8; 14]` in the same sentence.
The field list sums to 72 bytes (4 + 2 + 2 + 32 + 16 + 2 + 14), so
the two directives are arithmetically inconsistent. This module
resolves the inconsistency by:

* **Keeping 64 B** as the externally-observable stride. A caller
  computes `max_stages = out_cap / 64`; the 64-byte figure is the
  cache-line-friendly property worth preserving.
* **Trimming `_reserved` to 6 bytes** (indices 58..64). Every other
  field (widths, argv budget, flags u16) matches the brief
  verbatim.

The 6-byte reserved tail still carries three use-cases forward for
M2+ expansion without a layout break:

* a two-byte `redir_bits` (opens for `<`, `>`, `>>` operators at
  R223.M3+ without widening the record)
* a one-byte `stage_kind` tag (default/typed/annotated)
* a three-byte alignment slack kept for a future `at_hostname_offset`
  u24 (hostname-annotation feature for cross-host dispatch)

M2+ feature landings that need more than 6 reserved bytes must bump
`PL_STAGE_SIZE` to 128 and the version MAJOR (API break); until then
the 64-byte stride is a firm invariant.

### 4.2 Word-span semantics

Each (offset, len) pair indexes the ORIGINAL caller-supplied input
buffer at `[bytes_ptr + offset, bytes_ptr + offset + len)`. The
parser never allocates scratch; the record is a VIEW into the
caller's bytes.

| Source form      | offset points at   | len excludes           | HAS_ESCAPES / HAS_QUOTES |
|------------------|--------------------|-----------------------|---------------------------|
| bareword `foo`   | first byte `f`     | nothing               | --                        |
| bareword `a\|b`  | first byte `a`     | nothing (len = 4)     | HAS_ESCAPES               |
| `"a b"`          | first byte after `"` | closing `"`         | HAS_QUOTES                |
| `"a\"b"`         | first byte after `"` | closing `"`         | HAS_QUOTES, HAS_ESCAPES   |
| `'a b'`          | first byte after `'` | closing `'`         | HAS_QUOTES                |

Downstream un-escape (R223.M2 or shell integration) walks the
stored span and resolves `\|` → `|` and `\"` → `"` in-place or into
a scratch buffer. The parser never does this because the
destination buffer sizing is callee-specific; the parser's own
output is a flat records-of-views.

## 5. Public API

```
_pl_parse(bytes_ptr: u64, bytes_len: u64,
          out_ptr:   u64, out_cap:   u64) -> u64
```

Returns a packed `(n_stages << 32) | status` with status in:

| Code                        | Hex    | Meaning                                      |
|-----------------------------|-------:|----------------------------------------------|
| PL_OK                       | 0      | parse succeeded; `n_stages` ∈ 0..16          |
| PL_ERR_TOO_MANY_STAGES      | 0x2B00 | > PL_MAX_STAGES (16) stages requested        |
| PL_ERR_TOO_MANY_ARGS        | 0x2B01 | > PL_MAX_ARGS (8) argv per stage             |
| PL_ERR_UNTERMINATED_QUOTE   | 0x2B02 | DQ or SQ open at EOI                         |
| PL_ERR_EMPTY_STAGE          | 0x2B03 | `||`, leading `|`, or trailing `|`           |
| PL_ERR_OUT_TOO_SMALL        | 0x2B04 | `out_cap < (needed_stages * 64)`             |

```
_pl_emit_word(stage_ptr: u64, offset: u64,
              len:       u64, word_slot: u64) -> u64
```

Private helper (public linkage, internal use). Writes one (offset,
len) pair to either the `cmd_name_*` slots (when `word_slot ==
PL_SLOT_CMD = 0xFFFF`) or the `argv_*[word_slot]` slots
(`word_slot ∈ 0..7`). Returns `PL_OK` or `PL_ERR_TOO_MANY_ARGS`.

### 5.1 Return-value shape rationale

The `(count << 32) | status` packing matches the shape every other
packed-return primitive in `libpdx-pds-parser` uses (`U8N_*` in
`utf8_nfc.pdx`, and the shape libpdx-unicode-tables's `_norm_nfc`
exposes). A caller unpacks it with:

```
status   = result & 0xFFFFFFFF
n_stages = result >> 32
```

Both halves are always well-defined; on error, `n_stages` is the
count of stages committed BEFORE the fault (partial write; caller
should ignore the trailing partial stage).

## 6. Capacity + bound checks

| Check                                           | When               | Error                   |
|--------------------------------------------------|--------------------|-------------------------|
| `bytes_len == 0`                                 | entry              | PL_OK, n_stages = 0     |
| `out_cap < 64`                                   | entry              | PL_ERR_OUT_TOO_SMALL    |
| `stages_written >= PL_MAX_STAGES` on stage advance | at every `|`     | PL_ERR_TOO_MANY_STAGES  |
| `current_stage_end > out_end` on stage advance   | at every `|`       | PL_ERR_OUT_TOO_SMALL    |
| `word_slot >= PL_MAX_ARGS` on emit               | per word emit      | PL_ERR_TOO_MANY_ARGS    |
| state in {DQ, SQ} at EOI                         | end-of-input       | PL_ERR_UNTERMINATED_QUOTE |
| `dirty == 0` on `|`                              | at every `|`       | PL_ERR_EMPTY_STAGE      |
| `dirty == 0 && stages_written > 0` at EOI        | end-of-input       | PL_ERR_EMPTY_STAGE      |

Stage advance's TOO_MANY_STAGES check fires BEFORE the OOS check,
so a buffer provisioned exactly for `PL_MAX_STAGES * 64 = 1024`
bytes always reports TOO_MANY_STAGES on a 17-stage input (never
OOS); OOS is for callers who undersized the buffer below the
parser's own capacity floor.

## 7. Interaction with R129.M5 renderer-override `as`

The R129.M5 design (`design/shell/renderer-override-as-syntax.md`)
places the renderer selector at the TAIL of the last pipeline
stage's argv. R129.M5 explicitly states (§2.2):

> A pipeline like `cmd1 | cmd2 as table` applies the override to the
> **pipeline's final stdout**, not to cmd1's. … The parser already
> groups by `|` before stripping the trailing `as`; M5 inherits
> that behaviour.

This module satisfies that contract: it groups by `|` first and
leaves `as` + `<name>` as ordinary argv tokens on the last stage.
A separate post-pass (not landed at M1) runs the `argv[argc-2] ==
"as"` tail-match on `stages[k-1]`.

A `cmd1 as table | cmd2` with an intermediate `as` is not supported
by R129.M5 either, so this parser's "leave `as` as an argv token"
behaviour is adequate — the intermediate-stage `as` passes through
to the stage's command, which handles it as a normal argv.

## 8. Interaction with R222 cmd-functor signature matching

R222 (not yet landed) resolves each stage's `(cmd_name, n_args)`
tuple against a registered functor table. This module exposes:

* `cmd_name_offset`/`cmd_name_len` — the stage's resolvable name
  as a byte-span view.
* `n_args` — the raw argv count AFTER word splitting (and BEFORE
  the R129.M5 strip-pass and the R222 flag/positional partitioning).

A functor registration like:

```
register_functor("ls", { arity: variadic, caps_in: ..., caps_out: ... })
```

matches on `cmd_name` byte-equality. The downstream flag/positional
partitioning may further reduce `n_args` toward the functor's
declared positional arity; this module does not know about functor
signatures.

## 9. Caller flow

```
# 1. Allocate output buffer (sized for the parser's PL_MAX_STAGES).
out_cap   = PL_MAX_STAGES * PL_STAGE_SIZE   # = 16 * 64 = 1024
out_bytes = alloc(out_cap)

# 2. NFC-normalise the raw input (R221.M1).
nfc_buf = alloc(nfc_cap)
r = _u8n_decode_and_normalize(raw_ptr, raw_len, nfc_buf, nfc_cap)
status   = r & 0xFF
nfc_len  = r >> 32
if status != U8N_OK: handle_normalize_error(status)

# 3. Parse the pipeline.
r = _pl_parse(nfc_buf, nfc_len, out_bytes, out_cap)
status   = r & 0xFFFFFFFF
n_stages = r >> 32
if status != PL_OK: handle_parse_error(status, n_stages)

# 4. (Future) R129.M5 renderer-override post-pass on stages[n_stages-1].
# 5. (Future) R222 cmd-functor dispatch per stage.
# 6. (Future) R223.M2 planner materialise -> kernel Pipeline::pipeline_plan.
```

## 10. Encoder discipline (paideia-as)

The implementation obeys the pdx encoder's recurring-pitfall list
(see `.plans/pdx-encoder-pitfalls.md`):

* No `test rN, rN` — every zero-check is `cmp reg, 0` or
  `cmp reg, imm32`.
* No `and rN, imm64` — mask operations use imm32-safe values
  (0xFF, 0xFFFF, 0x7FFFFFFF).
* No 2-op `imul r, imm` — slot-index multiplies are `shl r, 2` or
  `shl r, 1`.
* No multiline `pub let = "..."` — every `justification:` string
  is a single line.
* Module basename matches file basename: module `Pipeline` ⇔
  `pipeline.pdx`.
* Labels prefixed `pl_` (main) and `pl_ew_` (emit helper) — no
  bare `loop`/`done`/`ret` which are keyword-adjacent.
* Byte loads via `xor rax, rax; mov_b rax, [base + idx * 1]`
  with explicit `*1` scale (U1606 mitigation per audit_file_sink
  precedent).
* u32 stores via `mov_d` (per emit_parse_error / pdxb_kek_derive
  precedent); u16 stores via two `mov_b` byte stores (low, high).
* All `cmp reg, imm` immediates ≤ 0x2B04 < 0x80000000, so direct
  `cmp reg, imm32` is sign-extension-safe. No MOVABS staging.
* `_pl_emit_word` is a pure leaf (no nested CALL); two-push
  prologue only.
* `_pl_parse` is NOT a pure leaf (CALLs `_pl_emit_word` from four
  word-emit sites). Prologue: 5 callee-save pushes (rbx, r12, r13,
  r14, r15 = 40 bytes) + `sub rsp, 48` for the local frame
  (48 bytes) = 88 bytes added. Entry `rsp % 16 == 8` + 88 bytes
  → `rsp % 16 == 0` at every nested CALL (SysV ABI requirement
  met).

## 11. Status-code namespace reservation

The `PL_*` codes live in `0x2B00..0x2BFF`, carved out of the
R223-wave slice of the parser-tier packed-status plan:

```
0x2700..0x27FF   R221.M1 Utf8Nfc           (landed)
0x2800..0x28FF   R221.M2 Grapheme (reserved)
0x2900..0x29FF   R133.M1 pds container reader (CT_ERR_*; landed Wave 113)
0x2A00..0x2AFF   R222.M1 SchemasSig body parser (SS_ERR_*; landed Wave 113)
0x2B00..0x2BFF   R223.M1 Pipeline PL_*     (THIS, landed)
0x2C00..0x2EFF   R223.M2..M* / R225.M* (reserved)
0x2F00..0x2FFF   R227.M* pds header pragmas (reserved)
```

Disjoint from every other user-space packed-status range in the
paideia-os tree. The kernel-side `Pipeline::PL_ERR_*` codes
(`0xFFFFEC40..42`) live in a wholly separate band and name a
different (planner-admission) module; the names are reused by
intent — the kernel band is for the kernel's pipeline admission
primitive, and the parser band is for the user-space parser. The
two never link together in a program.

## 12. Testing strategy (R223.M7 corpus)

The brief includes a 30-test parser corpus (R223.M7, not landed at
M1). Representative cases that corpus will cover:

**OK cases:**

| Input                              | Expected n_stages | Expected argv shapes             |
|------------------------------------|-------------------|----------------------------------|
| ``                                 | 0                 | --                               |
| `   ` (only whitespace)            | 0                 | --                               |
| `ls`                               | 1                 | cmd=`ls`, n_args=0               |
| `ls -l /tmp`                       | 1                 | cmd=`ls`, argv=[`-l`,`/tmp`]     |
| `a\|b\|c`                          | 1                 | cmd=`a\|b\|c` (literal)          |
| `a | b`                            | 2                 | …                                |
| `a | b | c`                        | 3                 | …                                |
| `echo "a b"`                       | 1                 | cmd=`echo`, argv=[`a b`]         |
| `echo 'a|b'`                       | 1                 | cmd=`echo`, argv=[`a|b`]         |
| `echo "a\"b"`                      | 1                 | argv=[`a\"b`], HAS_ESCAPES       |
| `grep -r "pattern" file1 file2`    | 1                 | n_args = 4                       |
| `cmd \| grep foo \| wc -l`         | 3                 | distinct stages                  |
| 16-stage pipeline                  | 16                | PL_OK                            |

**Error cases:**

| Input                            | Expected status            |
|----------------------------------|----------------------------|
| `\|`                             | PL_ERR_EMPTY_STAGE         |
| `cmd \|`                         | PL_ERR_EMPTY_STAGE         |
| `cmd \| \| cmd2`                 | PL_ERR_EMPTY_STAGE         |
| `cmd "unterminated`              | PL_ERR_UNTERMINATED_QUOTE  |
| `cmd 'unterminated`              | PL_ERR_UNTERMINATED_QUOTE  |
| 17-stage pipeline                | PL_ERR_TOO_MANY_STAGES     |
| 9-argv stage                     | PL_ERR_TOO_MANY_ARGS       |
| `out_cap == 32`                  | PL_ERR_OUT_TOO_SMALL       |

Every OK-case input must round-trip to a canonical form via the
sibling `_pl_render_canonical` entry point (R223.M6, not landed
here); the corpus's acceptance criterion (per brief §Acceptance)
is 30/30 round-trip equality.

## 13. Forward path

* **R223.M2** stage-ABI materialiser — walks `PipelineStage[]` into
  the kernel-side `Pipeline::pipeline_plan` input shape. Caps at
  the kernel's `PL_MAX_STAGES = 8`; stages > 8 fail at planner
  admission.
* **R223.M3** redirection operators `<`, `>`, `>>` added as
  per-stage bits in the reserved `redir_bits` u16 slot of the
  stage record (uses two of the 6 reserved bytes).
* **R223.M4** `@hostname` annotation on stages — stored as a
  `at_hostname_offset` u24 in another reserved slot; wires to R137
  remote-session dispatch.
* **R223.M5** flag-vs-positional partition per stage (reads
  functor registration from R222 to split argv into
  `--flag` prefix and positional tail).
* **R223.M6** canonical-form renderer `_pl_render_canonical` —
  pretty-prints a `PipelineStage[]` back to a string that round-
  trips through this parser.
* **R223.M7** 30-test parser corpus (acceptance test; §Acceptance
  of the parent brief).

---

## Upstream

* Umbrella: paideia-os#2487 (R223 pipeline-lang umbrella).
* This milestone: paideia-os#2666 (R223.M1).
* Substrate: paideia-os#2651 (R221.M1 Utf8Nfc).

## See also

* `design/shell/parser-utf8-nfc.md` — R221.M1 input-contract origin.
* `design/shell/renderer-override-as-syntax.md` — R129.M5 post-pass
  that consumes this module's output.
* `design/terminal/semantic-shell-language-plan.md` §4 R223 row M1
  — parent plan.
* `tools/user/libpdx-pds-parser/src/pipeline.pdx` — the real body.
