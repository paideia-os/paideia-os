# Source-span tracking across NFC normalization (R221.M6)

**Status:** v0.1 (R221.M6 — paideia-os#2656)
**Date:** 2026-10-15
**Author:** softarch (Wave 123)
**Scope:** Preserve source-level byte offsets across UTF-8 → NFC
normalization so AST nodes (R221.M5 Ast) point back to the original
pre-NFC caller-supplied source bytes (Q-A5 invariant). Interacts with
`libpdx-pds-parser` R221.M1 (`Utf8Nfc`) and R221.M5 (`Ast`); produces a
sparse `(nfc_offset, src_offset)` delta list consumed by LSP
diagnostics and `_ast_render` span-copy paths.

Upstream: paideia-os#2485 (R221 parser-tier Unicode + lexer umbrella),
paideia-os#2656 (R221.M6 THIS landing). Substrate:

- `tools/user/libpdx-pds-parser/src/utf8_nfc.pdx` (R221.M1 — the
  decoder+normalizer whose output buffer the AST walks).
- `tools/user/libpdx-pds-parser/src/ast.pdx` (R221.M5 — the AST pool
  whose SyntaxNodes carry `src_offset`/`src_length` fields that
  currently index INTO the NFC-form buffer).

Consumers (post-M6):

- R221.M7 parser fuzz corpus — property-tests the round-trip
  (`src -> nfc -> span-map -> back-mapped src_offset` matches the
  input span).
- R229.M3-dispatch REPL diagnostics — quotes `src[src_offset..]` so
  error messages reflect what the user actually typed, not the
  normalised form.
- R225.M7 HM-mismatch diagnostics — point into source via
  `_sm_lookup` to carve "mismatched type at <src_offset>, <src_len>".

---

## 1. Why

NFC composition can MERGE multiple source codepoints into one NFC
codepoint. The canonical example:

```
src:  'a' (0x61) + U+0301 COMBINING ACUTE ACCENT (0xCC 0x81)
      -> 3 source bytes.
nfc:  U+00E1 LATIN SMALL LETTER A WITH ACUTE   (0xC3 0xA1)
      -> 2 NFC bytes.
```

An AST node that quotes the composed character at `nfc_offset = 0`
with `nfc_length = 2` must map back to `src_offset = 0`,
`src_length = 3` for a user-visible diagnostic to quote what the user
typed. Direct offset-to-offset mapping does not work because the two
sides have different byte strides across the composed region.

The Q-A5 invariant (per `design/terminal/semantic-shell-language-plan.md`)
says every parser output must preserve a byte-level link back to the
original source. R221.M1's output discards that link; R221.M5 Ast
stores span fields that reference the NFC output; R221.M6 (THIS
landing) adds the sideband table that lets any consumer refine the
NFC-side offsets back to source-side offsets without walking a parent
chain.

---

## 2. Public API

Four entry points, in `module SpanMap`.

### 2.1 `_sm_init`

```
_sm_init() -> ()
```

- No args; no return.
- Zeroes `_sm_pair_count`; leaves `_sm_pairs` byte array unchanged
  (stale bytes past slot count are unreachable).
- Idempotent (re-zeroing an already-zero state is a no-op).
- Pure leaf.

Called externally at harness boot and between round-trip test
iterations; called internally by `_sm_from_u8nfc` at entry so each
new normalization starts with a fresh table.

### 2.2 `_sm_record_pair`

```
_sm_record_pair(nfc_offset: u64, src_offset: u64) -> errno
```

- `rdi` = `nfc_offset` (low 32 stored at pair [+0]).
- `rsi` = `src_offset` (low 32 stored at pair [+4]).
- `rax` = `errno` ∈ {`SM_OK`, `SM_ERR_POOL_FULL`,
  `SM_ERR_NON_MONOTONIC`}.

Append one pair at slot `_sm_pair_count` and bump the count. Enforces
**strict** monotonicity: when count > 0, both the new `nfc_offset`
AND the new `src_offset` must be strictly greater than the previous
pair's values. This catches `_sm_from_u8nfc` bugs early and simplifies
the lookup invariant.

Pure leaf.

### 2.3 `_sm_lookup`

```
_sm_lookup(nfc_offset: u64) -> src_offset: u64
```

- `rdi` = queried `nfc_offset`.
- `rax` = mapped `src_offset`.

Binary-searches the pair array for the largest `pair.nfc_offset <=
nfc_offset`. Returns `pair.src + (nfc_offset - pair.nfc)`. When the
table is empty or the query is strictly less than every pair's
`nfc_offset`, returns `nfc_offset` itself (identity map; the ASCII
fast path never touches the pair table).

Pure leaf.

### 2.4 `_sm_from_u8nfc`

```
_sm_from_u8nfc(bytes_src: u64, src_len: u64,
               bytes_nfc: u64, nfc_len: u64) -> errno
```

- `rdi` = `bytes_src` — pre-NFC source buffer.
- `rsi` = `src_len`  — source length in bytes.
- `rdx` = `bytes_nfc` — post-NFC byte buffer (R221.M1 output).
- `rcx` = `nfc_len`  — NFC length in bytes.
- `rax` = `errno` ∈ {`SM_OK`, `SM_ERR_BAD_INPUT`, `SM_ERR_POOL_FULL`,
  `SM_ERR_NON_MONOTONIC`}.

Rebuild the span map in one pass. CALLs `_sm_init` first, walks both
buffers in lockstep, records one pair per divergence boundary. The
resync heuristic is specified in §5.

**Not** a pure leaf. 5 callee-save pushes + 16-byte local frame →
`rsp%16 == 0` at every nested CALL.

---

## 3. Span map as a sparse delta list

A span map is an array of `(nfc_offset_u32, src_offset_u32)` pairs
stored in strictly monotonic order. Each pair records a position AT
WHICH the two cursors have diverged by a fresh amount. BETWEEN
consecutive pairs, both cursors advance in BYTE-FOR-BYTE lockstep
(that is, `nfc[i] == src[i + delta]` where `delta = pair.src -
pair.nfc` for the preceding pair, or zero if no pair applies).

**Lookup formula.** Given a queried `nfc_offset`:

1. Binary-search for the largest `pair[i].nfc_offset <= nfc_offset`.
2. If no pair applies (query < `pair[0].nfc_offset` or table empty):
   return `nfc_offset` unchanged (identity map).
3. Otherwise: `src_offset = pair[i].src + (nfc_offset -
   pair[i].nfc)`.

### 3.1 Worked example (a-acute)

Input:

```
src bytes:  0x61  0xCC  0x81             (3 bytes)
nfc bytes:  0xC3  0xA1                   (2 bytes)
```

After `_sm_from_u8nfc`:

```
pair_count = 1
pair[0] = (nfc = 2, src = 3)
```

Lookups:

| Query (nfc) | Result (src) | Reason |
|-------------|--------------|--------|
| 0           | 0            | No pair applies; identity.
| 1           | 1            | No pair applies; identity (query < pair[0].nfc).
| 2           | 3            | pair[0] applies; src = 3 + (2 - 2) = 3.
| 5           | 6            | pair[0] applies; src = 3 + (5 - 2) = 6.

### 3.2 Pure-ASCII input

A pure-ASCII input triggers NO pair recording (byte equality holds
throughout; `_sm_from_u8nfc`'s inner loop never enters the divergence
branch). The pair table stays empty and `_sm_lookup` short-circuits
on the empty-table identity path. Zero overhead for the hot path.

### 3.3 Multiple composed regions

Composed regions are additive: each divergence appends one pair with
cumulatively updated `(nfc, src)` offsets. The strict-monotonicity
check in `_sm_record_pair` is defensive insurance against a walker
bug that records out-of-order pairs.

---

## 4. Pool and `.bss` layout

```
_sm_pairs       : [u8; 8192]  (1024 slots x 8-byte pair stride)
_sm_pair_count  : u64         (current number of valid pairs)
```

Pair record (8 B):

```
offset  size  field
------  ----  --------------------------------------------
 0      4     nfc_offset   u32  (NFC-side cursor at divergence)
 4      4     src_offset   u32  (pre-NFC cursor at divergence)
```

Slot addressing uses `shl r, 3` (power-of-two stride; the smallest
in the parser-tier). The 8 KiB cap for the pair pool matches the
~1 KiB-of-pairs ceiling expected per typical pds-lang line input: 100
lines of 100 bytes with heavy combining-mark use would land ~100
pairs. The 1024-slot ceiling absorbs ~10x headroom with no runtime
cost (pool is `.bss`; the 8 KiB does not grow the binary).

### 4.1 Pool growth story

If a future wave exceeds 1024 pairs per parse (unlikely for
line-oriented shell input; realistic for a megabyte-sized `.pds` file
containing dense combining-mark use), R221.M6.1 may widen the pair
field u32→u64 OR grow the pool cap at a MAJOR version bump. The ABI
of `_sm_lookup` and `_sm_from_u8nfc` is designed to accept u64 args
even at M6 so a widening is additive.

---

## 5. Resync heuristic (M6 initial)

On a byte-level divergence `nfc[nc] != src[sc]`, `_sm_from_u8nfc`:

1. Decodes the UTF-8 scalar length `L` from the lead byte at
   `nfc[nc]`:

   | Byte range    | `L` |
   |---------------|-----|
   | `0x00..0x7F`  | 1   |
   | `0x80..0xBF`  | 1   (continuation-byte fallback) |
   | `0xC0..0xDF`  | 2   |
   | `0xE0..0xEF`  | 3   |
   | `0xF0..0xF7`  | 4   |
   | `0xF8..0xFF`  | 1   (invalid-lead fallback) |

2. Advances `nc := nc + L` (past the current NFC scalar).
3. If `nc >= nfc_len`, sets `sc := src_len` (every remaining source
   byte is composed into the preceding NFC region).
4. Otherwise scans `src[sc..src_len)` byte-by-byte for the next byte
   equal to `nfc[nc]`. The first match is treated as the resync
   point; `sc` is set to that index.
5. Records the pair `(nc, sc)` via `_sm_record_pair`.

### 5.1 Correctness envelope

The heuristic is **correct** for canonical-composition cases where
NFC merges K consecutive source codepoints into one NFC codepoint
(the dominant case: Latin + combining marks). It is **not**
byte-exact under adversarial inputs where the next-matching src byte
is a coincidence rather than the true resync point.

A bounded-window variant that cross-checks the next W bytes
(e.g. W = 4) is filed as **R221.M6.1**. For M6 the heuristic is
sufficient:

- Pure ASCII input never triggers the resync branch (byte equality
  holds throughout; the pair table stays empty).
- The dominant combining-mark case (`a` + U+0301 → á; `ñ`; `ü`;
  etc.) resyncs to the first post-composition byte, which IS the
  correct re-alignment because the composed region's tail is a byte
  sequence that does not re-appear inside the composed region's
  source bytes.
- A diagnostic that quotes `src[src_offset..]` for one scalar may
  land on an adjacent cluster boundary rather than the exact pre-NFC
  byte; this is acceptable at the ERROR-REPORT granularity
  `unified-ast.md` §9 §Round-trip documents.

### 5.2 Reference algorithm (pseudo-code)

```
_sm_from_u8nfc(src, src_len, nfc, nfc_len):
    _sm_init()
    nc, sc = 0, 0
    while nc < nfc_len and sc < src_len:
        if nfc[nc] == src[sc]:
            nc, sc = nc + 1, sc + 1
            continue
        L = utf8_scalar_len(nfc[nc])      # 1..4 from lead-byte table
        nc += L
        if nc >= nfc_len:
            sc = src_len
        else:
            sync = nfc[nc]
            while sc < src_len and src[sc] != sync:
                sc += 1
        errno = _sm_record_pair(nc, sc)
        if errno != SM_OK:
            return errno
    return SM_OK
```

Edge cases:

- `src_len == 0` and `nfc_len == 0`: no iterations; return `SM_OK`
  with an empty table (lookup returns identity for every query).
- `src_len == 0` and `nfc_len > 0`: first iteration bails on
  `sc >= src_len`; empty table; a lookup against any non-zero
  `nfc_offset` returns the same offset (incorrect for the strict
  semantics but harmless given the caller contract that `nfc_len`
  cannot exceed `src_len` under correct NFC behavior — the fast
  branch of `_u8n_decode_and_normalize` always copies byte-for-byte,
  so `nfc_len <= src_len` always).
- Null `src` or `nfc`: `SM_ERR_BAD_INPUT` without touching the pool.

---

## 6. Status codes

Error band `0x4700..0x47FF`.

| Code                   | Value   | Trigger                                |
|------------------------|---------|----------------------------------------|
| `SM_OK`                | `0`     | Success.                                |
| `SM_ERR_POOL_FULL`     | `0x4700`| `_sm_record_pair`: `pair_count >= 1024`. |
| `SM_ERR_NON_MONOTONIC` | `0x4701`| `_sm_record_pair`: nfc or src offset not strictly > previous. |
| `SM_ERR_OOB_OFFSET`    | `0x4702`| Reserved for M6.1+ (u64-width pair fields; length overflow guard). |
| `SM_ERR_BAD_INPUT`     | `0x4703`| `_sm_from_u8nfc`: null `src_ptr` or `nfc_ptr`. |

Slots `0x4704..0x47FF` reserved for M6.1+ (per-pair invalid UTF-8
code, bounded-window resync exhaustion, cross-NFC-form interop).

Disjoint from every other packed-status band in `caps.decl`:

- `0x4400..0x44FF` R221.M5 Ast (Wave 122 landed).
- `0x4500..0x45FF` R222.M5 CmdRegistry (Wave 122 landed).
- `0x4600..0x46FF` R224.M5 LetScope (Wave 122 landed).
- `0x4800..0x48FF` reserved for the parallel R133.M? kernel-side
  arm of Wave 123 (if any).

A compound-error dispatcher discriminates `(status & 0xFF00) ==
0x4700` for span-map faults.

---

## 7. Register plan + encoder discipline

Per `feedback_pdx_encoder_pitfalls` cited at every softarch dispatch.

### 7.1 Pure leaves (`_sm_init`, `_sm_record_pair`, `_sm_lookup`)

- Zero callee-save pushes; zero stack frame; zero nested CALLs.
- Scratch only in rax/rcx/rdx/r8/r9/r10/r11 (caller-save).
- RIP-relative LEA via `lea r11, [rip + sym]`.
- Byte and u32 loads via `xor rN, rN; mov_b rN, [addr]` and `xor rN,
  rN; mov_d rN, [addr]` (zero-extend into full qword).

### 7.2 `_sm_from_u8nfc` frame

- Pre-prologue null-pointer guards (bare `ret` with `rax =
  SM_ERR_BAD_INPUT`).
- 5 callee-save pushes:

  | Reg | Value         |
  |-----|---------------|
  | rbx | `src_ptr`     |
  | r12 | `src_len`     |
  | r13 | `nfc_ptr`     |
  | r14 | `nfc_len`     |
  | r15 | `nc`          |

- `sub rsp, 16` for two local slots:
  - `[rsp + 0]` = `sc` (src cursor; stack-held because we are already
    at 5 callee-save regs).
  - `[rsp + 8]` = pad.

- Entry `rsp%16 == 8` (SysV). After 5 pushes: `rsp%16 == 0`. After
  `sub rsp, 16`: `rsp%16 == 0`. Pre-CALL `rsp%16 == 0` as required.

- r11 is NEVER held across a nested CALL — state survives in r12..r15
  and `[rsp + 0]`.

### 7.3 Immediates

All `cmp` immediates fit `imm32` with bit 31 clear:

- `0`, `1`, `1024` (pool cap).
- `0x80`, `0xC0`, `0xE0`, `0xF0`, `0xF8` (UTF-8 lead-byte boundaries).
- `0x4700`, `0x4701`, `0x4702`, `0x4703` (status codes).

No `MOVABS` staging needed; no `and r, imm64`; no 2-op `imul r, imm`.

### 7.4 Addressing

Every operand is `[reg]`, `[reg + disp]`, or `[base + idx]`. No
three-term chains like `[reg + idx + disp]` (Wave 120+121 lesson).

---

## 8. Linker + wire-up

- No external cross-library dependency.
- No intra-library linker-visible dependency at M6 raw. The AST
  (R221.M5) stores spans as `src_offset` / `src_length` u32 fields
  that currently index into the NFC output; a downstream consumer
  that wants pre-NFC spans calls `_sm_lookup(src_offset)` to refine
  the offset before quoting source bytes.
- Expected consumer wiring at **R221.M6.1**: a downstream AST walker
  calls `_sm_from_u8nfc` once per parse (right after
  `_u8n_decode_and_normalize`) and then calls `_sm_lookup` whenever
  it needs to quote source bytes.

The ABI at this landing freezes:

- `(_sm_init, _sm_record_pair, _sm_lookup, _sm_from_u8nfc)` entry
  points.
- 8-byte pair stride (u32 nfc + u32 src).
- 1024-slot pool cap.
- Error band `0x4700..0x47FF`.
- `_sm_lookup` identity-map semantics on empty-table or
  below-first-pair queries.

A MINOR version bump (1.20.x → 1.21.0) may land M6.1 widening the pair
fields to u64 under a parallel entry-point surface
(`_sm_lookup64`, `_sm_from_u8nfc64`). A MAJOR version bump is NOT
required for M6.1.

---

## 9. Acceptance (deferred-fuzz) corpus

The 100-sample round-trip acceptance anchor (shared with R221.M5
Ast's 100-sample fixture) exercises `_sm_from_u8nfc` and `_sm_lookup`
on:

1. Pure-ASCII shell lines (`ls | wc`, `cat foo | grep bar`): expect
   empty pair table; identity lookup.
2. Latin + combining marks (`café`, `naïve`): expect
   one pair at the composed-character boundary; lookup past the
   boundary returns the correct source offset.
3. Multi-codepoint composition (`ṣ` = s + dot-below):
   expect one pair.
4. CJK fullwidth-ASCII (precomposed; NFC-stable): expect zero pairs
   (NFC is idempotent on CJK fullwidth per R131.M3 UCD subset).
5. Mixed ASCII + combining + ASCII (`café bar`): expect one
   pair in the middle; lookups before and after the pair resolve
   correctly.
6. Pathological: 1025 combining-mark pairs in a single line (synthetic
   stress). Expect `SM_ERR_POOL_FULL` on pair 1025; the 1024 recorded
   pairs are still queryable.

Property-test harness lands at `tests/proptest_span_map.pdx` as part
of R221.M7 parser fuzz corpus (deferred).

### 9.1 Round-trip property

For every well-formed input `src`:

```
nfc := _u8n_decode_and_normalize(src)
_sm_from_u8nfc(src, src_len, nfc, nfc_len) == SM_OK
forall nfc_off in [0, nfc_len]:
    src_off = _sm_lookup(nfc_off)
    assert src_off in [0, src_len]
    assert src_off == direct_byte_mapping(nfc_off, src, nfc)
```

Where `direct_byte_mapping` is the reference oracle (a slower
Python-like scalar-by-scalar walker that reconstructs the pair
table). The property holds BYTE-EXACTLY for the canonical cases §9
items 1–5; items past the resync-heuristic correctness envelope
(adversarial coincident-byte inputs) hold up to the "nearest cluster
boundary" granularity documented in `unified-ast.md` §9.

---

## 10. Forward path

- **R221.M6.1**: bounded-window resync (W = 4) + per-pair UTF-8
  invalid-sequence code (new slot in the 0x4700..0x47FF band).
- **R221.M6.2**: AST wire-up — `_ast_render` optionally refines
  `src_offset` via `_sm_lookup` before span-copying from the source
  buffer. Gated by a flag bit in the SyntaxNode's `flags` u16.
- **R221.M7**: 100-sample fuzz corpus + fingerprint goldens for the
  five canonical cases.
- **R225.M7**: HM-mismatch diagnostics quote source via `_sm_lookup`
  so error messages reflect the user's typed input, not the
  normalised form.
- **R229.M3-dispatch**: REPL evaluator's error path threads
  `_sm_lookup` on every parse failure to point at the exact source
  byte that triggered the fault.

---

## 11. ABI freeze

The four public entry points, the 8-byte pair stride, the 1024-slot
pool cap, and the `0x4700..0x47FF` error band freeze AT this landing.
Follow-up M6.x may ONLY:

- Reinterpret `SM_ERR_OOB_OFFSET` (reserved slot).
- Add new status codes within `0x4704..0x47FF`.
- Land parallel u64-width entry points under new names.

Changing the pair stride, moving a field, or renaming an entry point
requires a MAJOR version bump of `libpdx-pds-parser` (2.0.0) and an
explicit umbrella-level migration note.
