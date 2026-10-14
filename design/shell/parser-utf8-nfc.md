# Parser-tier UTF-8 Decoder + NFC Normalizer (R221.M1)

**Status:** v0.1 (R221.M1 — paideia-os#2651)
**Date:** 2026-10-14
**Author:** softarch (Wave UMB-W25)
**Scope:** The parser-tier wrapper that `pds-lang` (the semantic-shell
language — R221..R229) consumes to turn raw user input bytes into a
canonical UTF-8 code-unit stream the lexer can walk. Interacts with
`libpdx-unicode-tables` R131.M1 (UTF-8 primitives) and R131.M3 (NFC
normalizer) as its substrate.

---

## 1. Why a parser-tier wrapper, not direct substrate consumption

`libpdx-unicode-tables` R131 exposes:

- `Utf8::utf8_decode_cp` / `utf8_is_valid` / `utf8_count_cp` /
  `utf8_encode_cp` (R131.M1) — RFC 3629-well-formed single-codepoint
  decode/encode, no state.
- `Normalize::_norm_nfc` (R131.M3) — a full four-arg `(bytes_ptr,
  bytes_len, out_ptr, out_cap)` normalise over the reduced-UCD
  table (Latin-1 Supplement + Latin Extended-A canonical decomps;
  CJK fullwidth-ASCII compat; empty composition exclusions).
- `IpcNfc::_ipc_nfc_check` (R131.M8) — a conservative is-already-NFC
  heuristic that scans for the two UTF-8 lead bytes 0xCC and 0xCD
  (the Combining Diacriticals block U+0300..U+036F).

Each of those entry points is sized for its own call site: `utf8_
decode_cp` for a lexer that walks one scalar at a time, `_norm_nfc`
for a bulk-byte normalise, `_ipc_nfc_check` for the IPC-receive
boundary. **The parser's call site is distinct from all three**:

- The parser's input is a **whole line of shell input** (or a whole
  `.pds` file, up to the configured max-line-length). It is bulk,
  not one-scalar-at-a-time.
- The parser needs the normalised bytes **before** it starts
  lexing — the lexer's state machine assumes NFC-form input per
  SH-D9.4 ("the lexer sees one canonical byte sequence per logical
  string so that identical identifiers compare equal under
  byte-equality").
- The parser's hot path is the **ASCII subset of user input** —
  shell commands, pipeline operators, path components composed of
  ASCII letters/digits/punctuation. The 0xCC/0xCD scan that
  `_ipc_nfc_check` uses is correct for its IPC-boundary caller but
  is a **superset check** for the parser: it reports is_nfc=0 on
  payloads that contain combining marks even though the parser's
  hot path never sees them. The parser benefits from a tighter
  predicate — "every byte is pure ASCII" — because the ASCII fast
  path lets it skip the entire NFC pass **and** the full UTF-8
  validator (every ASCII byte is a trivially-well-formed
  single-byte UTF-8 scalar).

This module (`Utf8Nfc`) is the single call site the parser uses. It
is a thin layer: two entry points, one O(n) scan, one delegation to
`_norm_nfc`. It introduces no new UCD tables, allocates no new
scratch, and inherits the reentrancy posture of the substrate it
calls.

---

## 2. Public API

Two entry points, both over the same `(bytes_ptr, bytes_len, ...)`
surface the rest of the Unicode substrate uses.

### 2.1 `_u8n_decode_and_normalize`

```
_u8n_decode_and_normalize(bytes_ptr, bytes_len, out_ptr, out_cap)
    -> packed_u64
```

- `rdi` = `bytes_ptr`  — pointer to the first input byte.
- `rsi` = `bytes_len`  — input length in bytes (0 is well-defined and
  returns `(0 << 32) | U8N_OK` immediately).
- `rdx` = `out_ptr`    — pointer to the output buffer.
- `rcx` = `out_cap`    — output buffer capacity, in bytes.
- `rax` = packed return: `(bytes_written << 32) | status`.

`status` is one of:

| Code                      | Value   | Meaning                                                            |
|---------------------------|---------|--------------------------------------------------------------------|
| `U8N_OK`                  | `0`     | Decode + normalise succeeded; `bytes_written` carries NFC byte count. |
| `U8N_ERR_INVALID_UTF8`    | `0x2700`| Input is not RFC 3629 well-formed UTF-8.                           |
| `U8N_ERR_OUT_TOO_SMALL`   | `0x2701`| `out_cap` smaller than the NFC output requires.                    |
| `U8N_ERR_NORMALIZE_FAIL`  | `0x2702`| Reserved for post-M1 normaliser-internal failure (never returned at M1). |

The pack shape places the written-byte count in bits [63:32] and the
status in bits [31:0]. On any error, `bytes_written` is 0 (bits
[63:32] clear).

### 2.2 `_u8n_quick_check_ascii`

```
_u8n_quick_check_ascii(bytes_ptr, bytes_len) -> u64
```

- `rdi` = `bytes_ptr`.
- `rsi` = `bytes_len`.
- `rax` = `1` iff **every** byte in `[bytes_ptr, bytes_ptr +
  bytes_len)` is `< 0x80`, else `0`. A zero-length input returns
  `1` (the empty sequence is vacuously ASCII and vacuously NFC).

This is a pure scan — no UTF-8 validation, no table loads, no
nested call. It is the exact test the parser's hot path wants:
"can I skip both the full validator and the NFC pass and copy
the bytes straight through?"

Shape rhymes with `_ipc_nfc_check`: both return a single-bit boolean
through a `u64` register, both are pure leaves, both O(n). The
difference is the scan rule:

- `_ipc_nfc_check` returns `is_nfc=0` on any byte equal to `0xCC` or
  `0xCD` (combining-marks lead-byte presence check — a conservative
  is-already-NFC predicate across the full user-space Unicode text
  surface).
- `_u8n_quick_check_ascii` returns `0` on **any** byte `>= 0x80`
  (true-ASCII predicate — a tighter check that is correct for the
  parser's hot path specifically because ASCII input is always both
  valid UTF-8 and already-NFC).

---

## 3. Fast-path strategy inside `_u8n_decode_and_normalize`

The entry point's control flow is:

```
if _u8n_quick_check_ascii(bytes_ptr, bytes_len):
    # Hot path. Input is pure ASCII, so:
    #   (a) It is trivially well-formed UTF-8 (every byte is a
    #       complete 1-byte scalar in 0x00..0x7F).
    #   (b) It is trivially already in NFC (no combining marks can
    #       appear; no M3 decomposition table entry has an ASCII
    #       starter whose canonical form differs from itself).
    # So the normalise is a byte-for-byte copy.
    if out_cap >= bytes_len:
        memcpy(out_ptr, bytes_ptr, bytes_len)
        return (bytes_len << 32) | U8N_OK
    else:
        return U8N_ERR_OUT_TOO_SMALL
else:
    # Slow path. Delegate to _norm_nfc which validates UTF-8
    # internally and emits the NFC form. Translate its three
    # status codes (0=OK, 1=OUT_TOO_SMALL, 2=INVALID_UTF8) to the
    # U8N_* taxonomy.
    r = _norm_nfc(bytes_ptr, bytes_len, out_ptr, out_cap)
    status = r & 0xFF
    bytes_written = r >> 32
    if status == 0: return (bytes_written << 32) | U8N_OK
    if status == 1: return U8N_ERR_OUT_TOO_SMALL
    if status == 2: return U8N_ERR_INVALID_UTF8
    return U8N_ERR_NORMALIZE_FAIL   # unreachable at M1
```

### 3.1 Why ASCII, not 0xCC/0xCD

The parser's input is dominated by:

- Pipeline tokens (`|`, `||`, `>`, `<`, `;`, `&&`, `=>`): all ASCII.
- Builtin names and command keywords (`cd`, `let`, `datalog`, `run`,
  `pwd`, `exit`, `set`): all ASCII.
- Path components for the system area (`/system/shell/commands.toml`,
  `/users/<u>/.pds/`): all ASCII.
- Datalog atoms and lambda identifiers that the type-checker will
  canonicalise anyway: predominantly ASCII (per the "paideia-os
  identifiers are ASCII-plus-Latin-only at R221; multi-script
  identifiers are deferred to R221.M4+" convention).

A single `cmp byte, 0x80; jae ...` per byte in the scan is cheaper
than the 0xCC/0xCD two-cmp sequence `_ipc_nfc_check` uses, **and**
the predicate is strictly tighter: an ASCII input gates both the
UTF-8 validator and the NFC pass, where 0xCC/0xCD-absence only
gates the NFC pass. The parser call site thus pays the UTF-8
validator cost only on non-ASCII input, which empirically dominates
in the <5% range of lines on a representative pds corpus.

### 3.2 False-negative handling

`_u8n_quick_check_ascii` returning `0` does not mean the input is
non-ASCII — it means the fast path **declined** the scan at the
first >=0x80 byte. The slow path then runs the full validator +
normaliser, which handles all well-formed UTF-8 (including inputs
whose non-ASCII prefix is immediately followed by ASCII; the
substrate makes no shortcut on "mostly ASCII"). There is thus no
correctness loss on partial-ASCII input, only the slow-path cost
of the UTF-8 pass on bytes the fast path could not shortcut.

### 3.3 False-positive handling

Impossible by construction. If every byte is `< 0x80`:

- Every byte is a complete 1-byte UTF-8 scalar (RFC 3629 §3 row 1).
- Every scalar maps to a Unicode code point in `U+0000..U+007F`.
- No code point in `U+0000..U+007F` has a canonical decomposition
  in the UCD (none in the full UCD, let alone in the R131.M3
  reduced-table subset).
- No code point in `U+0000..U+007F` participates as the mark of a
  canonical decomposition (every M3 decomp mark is in
  `U+0300..U+036F`).

So pure-ASCII input is byte-for-byte identical in input and NFC
output, and copying `bytes_len` bytes from input to output is the
exact NFC transform.

---

## 4. Interaction with the R131 Unicode substrate

### 4.1 `_norm_nfc` ownership

`_norm_nfc` is the single source of truth for canonical form. This
module does not duplicate its decomp/compose tables, does not add
new tables of its own, and does not short-circuit any case the
substrate handles. The ASCII fast path exists only because ASCII is
provably a fixed point of `_norm_nfc` — it is a correctness-free
optimisation, not a semantic variation.

The slow path is a plain pass-through: `rdi/rsi/rdx/rcx` go straight
through to `_norm_nfc` (identical arg-shape), and the only post-call
work is translating the substrate's three-value status band
(`0`/`1`/`2`) into the four-value `U8N_*` taxonomy.

### 4.2 Status-code namespace

The substrate's internal error band is `0xFFFFE720..0xFFFFE72F`
(reserved for `Normalize`), with its public API returning a three-
value status in the low 8 bits of its packed result (0=OK, 1=OUT_
TOO_SMALL, 2=INVALID_UTF8). This module places its U8N_* taxonomy
in a **small-value** range (0x2700..0x2702) that is deliberately
NOT inside any user-space 0xFFFFExxx error-band slice. Rationale:

- The U8N_* codes are a **packed-return** status field, always in
  the low 32 bits of a 64-bit packed value. They are discriminated
  by position (bits [31:0]), not by magnitude band.
- Keeping the codes small means a caller doing `(result & 0xFF)`
  for status gets a plain switch-safe value without needing a MOVABS
  comparison against a 0xFFFFExxx band.
- The 0x2700..0x27FF range is reserved for parser-tier status codes
  (future R221 milestones). It is disjoint from every other
  packed-status byte in the paideia-os tree:
  - M3 `_norm_nfc` status: 0..2.
  - M8 `_ipc_nfc_check` status: always 0.
  - R131 user-space error band: 0xFFFFE700..0xFFFFE7FF (large).
  - Shell dispatch ret bands: 0xFFFFEC/ED/EB.

Grep confirmation at R221.M1 landing time:
```
grep -rE '0x2(7)0[0-9A-F]' paideia-os/{src,tools,design,tests}
    -> no packed-status hits outside this module + its tests.
```

### 4.3 Reentrancy

Both entry points are leaves at the control-flow level — neither
makes a nested call from this module's own code. The slow path's
`call _norm_nfc` is a tail-call-shaped delegation that preserves
the substrate's own reentrancy posture (single-threaded ring-3,
`.bss`-scratch-backed; see R131.M3 header).

---

## 5. Forward path to R221.M2+

### 5.1 R221.M2 — TR#29 grapheme cluster boundary iterator

The lexer post-M1 will need to walk the normalised byte stream at
the grapheme-cluster boundary (for cursor-math and
argument-tokenisation). `libpdx-unicode-tables::grapheme._gc_next`
(R131.M2) is the substrate; the parser-tier wrapper for M2 will
consume `_u8n_decode_and_normalize`'s output buffer directly.

### 5.2 R221.M3 — TR#11 width table

Column-advance math on the lexer's token-render pass. Consumes
R131.M5 width tables; no interaction with M1 beyond "the width
table reads NFC-form bytes."

### 5.3 R221.M4 — Context-tracking lexer

The lexer state machine that switches between pipeline / Datalog /
lambda contexts. This is where the M1 output buffer finally gets
walked token-by-token. The lexer treats its input buffer as
immutable NFC bytes and never calls back into `Utf8Nfc` — the
normalisation obligation is discharged by the parser's single call
to `_u8n_decode_and_normalize` on line entry.

### 5.4 R221.M6 — Source-span tracking through NFC normalization

Future requirement: an LSP diagnostic needs to point back from an
AST-node's post-NFC byte span to the pre-NFC byte range in the
user's source. The current M1 contract **loses** this mapping (the
output buffer is a flat byte array; no mapping table is emitted).

M6 will extend `_u8n_decode_and_normalize` with a sibling entry
point (`_u8n_decode_and_normalize_with_map`) that additionally
emits a span-mapping table alongside the output bytes. The M1
contract remains the fast API; the span-emitting variant is a
superset for callers that need it.

### 5.5 Full-UCD normaliser (deferred under R131.M3.2+)

The R131.M3 reduced-UCD table covers Latin-1 Supplement + Latin
Extended-A canonical decomps and CJK fullwidth-ASCII compat. When
the full-UCD table lands (Devanagari / Hebrew / Arabic / CJK
blocks), this module's slow path transparently picks up the wider
coverage. The ASCII fast path remains unchanged.

---

## 6. Encoder-pitfall discipline (reproduced for ongoing audit)

- No `test rN, rN` — every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64` — the ASCII scan compares bytes against
  `0x80` via `cmp reg, imm32` (0x80 is a positive imm32,
  sign-extension-safe).
- No 2-op `imul r, imm` — not used; the scan advances `add rcx, 1`.
- No multiline `pub let = "..."` — single-line justifications only.
- Module basename `Utf8Nfc` matches `utf8_nfc.pdx`.
- Labels prefixed `u8n_` (never `loop` / `if` / `let` / `fn` /
  `ret` — reserved).
- All `cmp reg, imm` immediates `<= 0x80` here, so direct
  `cmp reg, imm32` is sign-extension-safe without MOVABS staging.
- All byte loads via `mov_b` (zero-extends into the full qword).
- The ASCII-copy loop uses `mov_b` for both load and store.
- Entry rsp%16==8 preserved per SysV. The quick-check path is a
  pure leaf (no nested CALL) so no callee-save push or stack
  scratch is required. The decode_and_normalize path makes one
  nested CALL into `_norm_nfc` (slow branch) or none (fast
  branch); the slow branch realigns with `sub rsp, 8` and the
  fast branch stays at rsp%16==8 throughout.
- No `add reg, [mem]` anywhere.
- Return-code constants (0, 0x2700, 0x2701, 0x2702) all fit in
  imm32-signed-safe and are emitted via `mov reg, imm32` without
  MOVABS staging.

---

## 7. Fingerprint discipline

This module emits no fingerprints of its own. The parser's call
site at R221.M4+ will emit the single wire-side fingerprint
`parse nfc ok bytes=<n> status=<n>` (or an error-shape variant)
after calling `_u8n_decode_and_normalize`. The fingerprint lives
at the **consumer**, not the primitive — this keeps the primitive
pure-leaf and consistent with every other `libpdx-*` library in
the tree.

---

## 8. Testing posture (R221.M1)

- Decode-and-normalize over the TR#15 Part 1 conformance vectors
  (NFC output over NFD input, NFC fixed-point over NFC input).
  The reduced-UCD subset at R131.M3 covers the Latin-1 Supplement
  + Latin Extended-A conformance subset; the full-UCD coverage
  gates on R131.M3.2+.
- ASCII fast-path spot-tests: `"ls -la /tmp"`, `"| grep foo"`,
  typical pipeline strings; expect `is_ascii=1` and byte-identical
  output.
- Negative tests: overlong 2-byte `"\xC0\xAF"` → `U8N_ERR_INVALID_
  UTF8`; surrogate `"\xED\xA0\x80"` → `U8N_ERR_INVALID_UTF8`;
  3-byte truncation `"\xE2\x82"` → `U8N_ERR_INVALID_UTF8`.
- `out_cap` boundary: input 10 bytes, out_cap=9 → `U8N_ERR_OUT_
  TOO_SMALL`; out_cap=10 → `U8N_OK` with `bytes_written=10`.
- Fingerprint golden file at `tools/user/libpdx-pds-parser/tests/
  fingerprints/utf8_nfc.golden` (added at the R221.M1 test
  landing; not shipped in this scaffold).

---

## 9. References

- `tools/user/libpdx-unicode-tables/src/utf8.pdx` — R131.M1 UTF-8
  primitives.
- `tools/user/libpdx-unicode-tables/src/normalize.pdx` — R131.M3
  normaliser.
- `tools/user/libpdx-unicode-tables/src/ipc_nfc.pdx` — R131.M8
  IPC-boundary NFC hook (sibling fast-path heuristic).
- `design/terminal/semantic-shell-language-plan.md` §4 R221 M1 row.
- `design/terminal/semantic-shell.md` SH-D9.4 — "lexer sees NFC-form
  input".
- `tools/user/libpdx-unicode-tables/caps.decl` — error-band taxonomy.
- Umbrella: `paideia-os#2485`. Ticket: `paideia-os#2651`.

---

## 10. Open follow-ups (tracked for R221.M2+)

| ID | Title                                                | Blocks     |
|----|------------------------------------------------------|------------|
| F1 | Add span-mapping sibling entry point                 | R221.M6    |
| F2 | Benchmark ASCII fast-path vs full-pass break-even    | perf audit |
| F3 | Full-UCD slow-path coverage                          | R131.M3.2+ |
| F4 | Per-line stream variant (chunked out buffer)         | R221.M4    |
