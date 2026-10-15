# Multi-line input for incomplete expressions (R229.M8)

**Status:** v1.0 (R229.M8 landing, Wave 129, paideia-os#2726).
**Upstream:** paideia-os#2493 (R229 umbrella), paideia-os#2726 (THIS).
**Sibling docs:** `design/shell/repl-loop-scaffold.md` (R229.M1 REPL
state machine — THIS module runs on every RET-commit before dispatch
to the parser), `design/shell/line-editor-emacs.md` (R229.M6
LineEditor — supplies the bytes MultiLine scans), `design/shell/
line-editor-vi.md` (R229.M7 ViMode — same input surface),
`design/shell/ctx-tracking-lexer.md` (R221.M4 CtxLexer — the full
tokeniser that runs AFTER MultiLine reports COMPLETE), `design/
terminal/editor-bindings.md` (shell key bindings).

## 1. Scope

R229.M8 lands the parser-tier substrate every READING-mode RET-commit
consults before deciding whether the shell dispatches the accumulated
bytes to the full parser (CtxLexer + Pipeline / Datalog / Lambda) or
redraws a continuation prompt and stays in READING.

Four sources of incompleteness are tracked:

| Priority | State | Trigger |
|---|---|---|
| 1 | `ML_STATE_INCOMPLETE_STR` | open `"` without matching close |
| 2 | `ML_STATE_INCOMPLETE_BRACE` | `{` count > `}` count |
| 3 | `ML_STATE_INCOMPLETE_PAREN` | `(` count > `)` count |
| 4 | `ML_STATE_INCOMPLETE_BACKSLASH` | trailing `\` before LF (outside a string) |
| — | `ML_STATE_COMPLETE` | everything balanced |

The priority ladder puts string-open at the top because the body of
an open string contains unresolved `{`, `}`, `(`, `)` the brace/paren
counters MUST NOT see. Once a `"` opens a string, every subsequent
byte is literal-body until a non-escaped `"` closes it.

Acceptance (per paideia-os#2726): a 15-expression multi-line test
corpus — each expression delivered one line at a time — reports the
right incompleteness after every non-final line and reports COMPLETE
after the final line. §5 enumerates the 15 expressions and the
expected per-line verdict trace.

### 1.1 Why this exists

Without MultiLine, every RET-commit must either immediately dispatch
to the full parser (and swallow a parse error if the expression is
incomplete) or require the user to escape every newline with `\`
(POSIX-shell-style). Both options are hostile to the shell's
multi-sublanguage surface:

- `datalog { fact(1). fact(2). }` is natural across lines.
- `|x| { ... }` lambda bodies are natural across lines.
- Pipeline stages with a nested lambda in `where { ... }` want to
  span lines without a trailing-`\` ritual.

MultiLine is a READING-tier heuristic that answers "did the user
finish a top-level expression?" with a single-pass ASCII-level byte
walker. The accumulated bytes are STILL handed to CtxLexer / full
parser once the top-level expression closes; MultiLine's counters
are a BUDGET APPROXIMATION of CtxLexer's `_cl_stack` + `_cl_depth`
for the subset of balanced tokens the READING-tier cares about.

### 1.2 Why NOT consult CtxLexer directly

The clean-design pass considered three alternatives:

1. **CtxLexer runs on every RET-commit; `_cl_depth > 0` ⇒ READING
   continues.** Rejected: CtxLexer runs over the NFC-normalised byte
   stream, not raw bytes, and its lazy-init path (lazy label-intern
   table population at R221.M4) touches 128 bytes of `.bss` on cold
   boot. A READING-tier heuristic should be a single-pass byte-walker
   with zero allocation and zero lazy-init cost.

2. **The full parser runs on every RET-commit; parse error ⇒
   continuation.** Rejected: parse errors have a rich diagnostic
   structure (span, suggestion, nearby-token) MultiLine's answer
   does not need and would be noise in the chaos path. The parser
   should run ONCE per expression commit, not once per line.

3. **MultiLine runs ONCE per RET-commit over raw bytes; CtxLexer
   runs ONCE per expression commit over the NFC-normalised bytes.**
   SELECTED: pure byte-walker with four scalars of state, no lazy-
   init, no allocation, and a straightforward priority ladder. The
   `{`, `}`, `(`, `)`, `"`, `\` bytes are all single-byte UTF-8, so
   raw-byte scanning gives the correct answer at ASCII speed.

A future M8.4 landing may fold the two by having MultiLine consult
CtxLexer's stack as a cross-check (klog_s1 fingerprint on
divergence); raw M8 keeps the two wholly disjoint.

## 2. Module shape

**File:** `tools/user/libpdx-pds-parser/src/multi_line.pdx`
**Module name:** `MultiLine`
**Status band:** `0x5A00..0x5AFF`
**Linker dependencies:** none. MultiLine is self-contained over
caller-supplied bytes and its own four `.bss` scalars.

MultiLine makes NO cross-module FUNCTION calls at raw M8: every
public entry point is a PURE LEAF (zero callee-save pushes, zero
stack frame, zero nested CALL). The REPL dispatcher is responsible
for snapshotting `_le_buf[0.._le_buf_len)` via `_le_get_buffer`
and handing (ptr, len) to `_ml_scan_line`.

### 2.1 Public API

| Entry | Signature | Return |
|---|---|---|
| `_ml_init` | `()` | `()` — pure-leaf scalar scrub (32 B) |
| `_ml_reset` | `()` | `()` — identical scrub (expression-boundary hook) |
| `_ml_scan_line` | `(bytes_ptr, len)` | `u8` state in rax low byte |
| `_ml_state` | `()` | `u8` state from current `.bss` |
| `_ml_continuation_prompt` | `(out, out_cap)` | `(bytes << 32) \| status` |

### 2.2 Static state (`.bss`, singleton)

| Symbol | Type | Semantics |
|---|---|---|
| `_ml_brace_depth` | `u64` | Signed brace nesting depth; clamped at 0 on underflow |
| `_ml_paren_depth` | `u64` | Signed paren nesting depth; clamped at 0 on underflow |
| `_ml_in_string` | `u64` | 0 iff not in a `"..."`; 1 iff open (low byte authoritative) |
| `_ml_backslash_pending` | `u64` | 0 or 1 (low byte authoritative) |

Cold-boot `.bss` zero-init already satisfies every invariant (every
scalar == 0 = COMPLETE ground state). `_ml_init` is a defensive
scrub for chaos-restart / test-time reset.

### 2.3 Status taxonomy

| Code | Hex | Returned by | Meaning |
|---|---|---|---|
| `ML_OK` | 0 | all | success |
| `ML_ERR_BAD_PTR` | 0x5A00 | continuation_prompt | out == 0 |
| `ML_ERR_OUT_TOO_SMALL` | 0x5A01 | continuation_prompt | out_cap < per-state byte count |
| `ML_ERR_BAD_STATE` | 0x5A02 | continuation_prompt | defensive; state outside 0..4 |

The band skips `0x5800..0x58FF` (reserved for the parallel-arm
R225.M6 landing) and `0x5900..0x59FF` (reserved for the parallel-
arm R227.M3 landing) per the Wave 129 band plan. `0x5A03..0x5AFF`
reserved for M8.1+ follow-ups.

### 2.4 Continuation-state values

| State | Hex | Prompt bytes | Prompt literal |
|---|---|---|---|
| `ML_STATE_COMPLETE` | 0 | 0 B (caller renders primary prompt) | — |
| `ML_STATE_INCOMPLETE_BRACE` | 1 | 3 B | `{> ` |
| `ML_STATE_INCOMPLETE_PAREN` | 2 | 3 B | `(> ` |
| `ML_STATE_INCOMPLETE_STR` | 3 | 3 B | `"> ` |
| `ML_STATE_INCOMPLETE_BACKSLASH` | 4 | 3 B | `\> ` |

Each non-COMPLETE prompt is three bytes: the marker (which echoes
the kind of incompleteness), `>`, then a space. The leading marker
lets the user see what the shell is waiting for without inspecting
the position.

## 3. Dispatch state machine

```
                        +-----------+
                        |  READING  |
                        +-----+-----+
                              |
                              v
                   (RET-commit: byte 0x0A/0x0D)
                              |
                              v
                 _le_get_buffer -> (bytes, len)
                              |
                              v
                  _ml_scan_line(bytes, len)
                              |
                              v
                     +--------+--------+
                     |                 |
                 state == 0        state != 0
                     |                 |
                     v                 v
              _ml_reset         _ml_continuation_
              dispatch to       prompt(out, cap)
              parser                  |
                                       v
                               append LF to _le_buf
                               redraw prompt
                               stay in READING
```

### 3.1 Byte-walker rules

For each byte in `bytes[0..len)`:

```
if in_escape:
    in_escape := 0        // consume one byte literal
elif in_string:
    if byte == '\':  in_escape := 1
    if byte == '"':  in_string := 0
    else:            no-op
else:
    if byte == '{':  brace_depth += 1
    if byte == '}':  brace_depth -= 1 (clamp at 0)
    if byte == '(':  paren_depth += 1
    if byte == ')':  paren_depth -= 1 (clamp at 0)
    if byte == '"':  in_string := 1
    else:            no-op
```

Note: `in_escape` is a per-call local; it resets to 0 at every
`_ml_scan_line` entry. The CROSS-LINE latch is only `_ml_in_string`
so an opening `"` on line N stays active on line N+1 until line
N+K's closing `"`.

### 3.2 Trailing-backslash post-pass

After the per-byte walk:

```
if len > 0 and in_string == 0 and bytes[len-1] == '\':
    backslash_pending := 1
else:
    backslash_pending := 0
```

The trailing-byte check runs OUTSIDE a string because a trailing
`\` inside a string becomes `ML_STATE_INCOMPLETE_STR` by the
priority ladder, not `ML_STATE_INCOMPLETE_BACKSLASH`.

### 3.3 Priority ladder

```
if in_string:              return ML_STATE_INCOMPLETE_STR
elif brace_depth > 0:      return ML_STATE_INCOMPLETE_BRACE
elif paren_depth > 0:      return ML_STATE_INCOMPLETE_PAREN
elif backslash_pending:    return ML_STATE_INCOMPLETE_BACKSLASH
else:                      return ML_STATE_COMPLETE
```

## 4. Correctness invariants

| Invariant | Enforced by |
|---|---|
| `_ml_brace_depth >= 0` | clamp-at-0 before `sub r9, 1` |
| `_ml_paren_depth >= 0` | clamp-at-0 before `sub r10, 1` |
| `_ml_in_string in {0, 1}` | low byte written only by two literal stores (0 or 1) |
| `_ml_backslash_pending in {0, 1}` | low byte written only by two literal stores (0 or 1) |
| state returned in `0..4` | priority ladder enumerates exactly five arms |
| `_ml_scan_line` purity | zero `.bss` outside the four scalars; zero pushes; zero CALL |
| `_ml_init` and `_ml_reset` idempotence | byte-identical scrubs |
| string body is NOT counted for `{`, `}`, `(`, `)` | priority ladder: in_string check gates default-parse branch |

## 5. Acceptance

**Interactive test** (per paideia-os#2726):

> 15-multi-line test corpus; each expression completes correctly.

The raw M8 surface satisfies this. The 15 expressions below drive
`_ml_scan_line` one line at a time; the "verdict after line N"
column enumerates the expected state after that call. The final
line of every expression returns `ML_STATE_COMPLETE` (0).

### 5.1 Fifteen-expression corpus

| # | Line 1 | Verdict | Line 2 | Verdict | Line 3 | Verdict |
|---|---|---|---|---|---|---|
| 1 | `ls -la` | COMPLETE | — | — | — | — |
| 2 | `let x = {` | BRACE (1) | `  1 + 2` | BRACE (1) | `}` | COMPLETE |
| 3 | `datalog {` | BRACE (1) | `  parent(a, b).` | BRACE (1) | `}` | COMPLETE |
| 4 | `|x| {` | BRACE (1) | `  x * 2` | BRACE (1) | `}` | COMPLETE |
| 5 | `echo "hello` | STR (3) | `world"` | COMPLETE | — | — |
| 6 | `echo \` | BACKSLASH (4) | `  "continued"` | COMPLETE | — | — |
| 7 | `(a + ` | PAREN (2) | ` b)` | COMPLETE | — | — |
| 8 | `where { |r|` | BRACE (1) | `  r.n > 0 }` | COMPLETE | — | — |
| 9 | `echo "x \"y\" z"` | COMPLETE | — | — | — | — |
| 10 | `echo "{open brace in string"` | COMPLETE | — | — | — | — |
| 11 | `{{nested` | BRACE (1) | `}}` | COMPLETE | — | — |
| 12 | `((deep))` | COMPLETE | — | — | — | — |
| 13 | `let s = "a` | STR (3) | `  b` | STR (3) | `  c"` | COMPLETE |
| 14 | `let f = |x| {` | BRACE (1) | `  let g = |y| {` | BRACE (2) | `  y } }` | COMPLETE |
| 15 | `}}}}` | COMPLETE | — | — | — | — |

Row-by-row rationale:

1. Flat pipeline: no nesting, no quote, no trailing `\` → COMPLETE.
2. `let` with a block literal: BRACE after line 1 and line 2;
   closing `}` on line 3 drops the counter to 0 → COMPLETE.
3. Datalog block: same brace shape as row 2.
4. Lambda with a block body: same brace shape.
5. String across lines: STR after line 1; closing `"` on line 2 →
   COMPLETE.
6. Explicit line-continuation `\`: BACKSLASH after line 1; next
   line has no trailing continuation and no other incompleteness
   → COMPLETE.
7. Open paren across lines: PAREN after line 1; closing `)` on
   line 2 → COMPLETE.
8. Pipeline stage with lambda body: BRACE after line 1; closing
   `}` on line 2 → COMPLETE.
9. String with escaped quotes: `\"` consumed by the in-escape
   latch (per-call); outer `"` opens and closes on the same line
   → COMPLETE.
10. Open brace inside a string is literal body (not counted); the
    quote closes on the same line → COMPLETE.
11. Nested braces on one line without close: BRACE after line 1
    (depth 2); line 2's `}}` drops to 0 → COMPLETE.
12. Doubled paren pair on one line: open and close balance →
    COMPLETE.
13. String across three lines: STR holds across every intermediate
    line until the closing `"` on line 3 → COMPLETE.
14. Nested lambdas: depth 2 after line 2; `y } }` on line 3 pops
    both braces → COMPLETE.
15. Extra closing braces at depth 0: clamp-at-0 keeps the counter
    at 0; no state change → COMPLETE.

Row 15 is the clamp-edge test. Rows 9 and 10 are the string-escape
and string-body tests. Row 13 exercises the cross-line string
latch across three lines. Row 14 exercises nested-depth tracking.

### 5.2 Fingerprint goldens

A smoke-mode asserter corpus landing at R229.M8.7 will replay the
15 above rows and compare the per-line state against a golden file
`smoke/multi-line-m8.golden.txt`. The raw M8 landing does NOT ship
a golden file; the design doc §5.1 is the authoritative acceptance
truth.

## 6. Encoder discipline

Per the paideia-as encoder pitfalls catalogued in the shell's build
discipline (`feedback_pdx_encoder_pitfalls`):

- No `test rN, rN` — every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64` — every mask is imm8 or imm32.
- No 2-op `imul r, imm` — no stride multiplies at this tier.
- No multiline `pub let = "..."` — single-line justifications.
- Module basename `MultiLine` matches `multi_line.pdx`.
- Labels prefixed `ml_` with per-function suffix (`ml_ini_`,
  `ml_rst_`, `ml_scan_`, `ml_st_`, `ml_cp_`). Disjoint from every
  landed parser-tier prefix.
- All `cmp reg, imm` immediates fit imm32 with bit 31 clear
  (0, 1, 2, 3, 4, status codes 0x5A00..0x5A02, byte literals 0x22
  `"`, 0x28 `(`, 0x29 `)`, 0x5C `\`, 0x7B `{`, 0x7D `}`). No
  MOVABS staging.
- Byte loads via `xor rax, rax; mov_b rax, [base + idx * 1]`.
- Byte stores via `mov_b [dst + idx], reg`.
- u64 stores via plain `mov [dst + disp], reg`.
- `.bss` writes via `lea r11, [rip + sym]; mov [r11], reg`.
- Every public entry point is a PURE LEAF (zero pushes, zero
  stack frame, zero nested CALL).
- `_ml_scan_line`'s per-iteration state lives in SysV caller-save
  scratch (rcx, rdx, r8, r9, r10, r11); no pushes required.
- r11 is used freely as `.bss` lea staging because no CALL exists
  to clobber it.

## 7. Forward path

| Milestone | What it adds |
|---|---|
| M8.1 | Heredoc `<<EOF ... EOF`; adds `ML_STATE_INCOMPLETE_HEREDOC = 5` + per-session heredoc-tag pool (16 x 16 B); status code `ML_ERR_HERE_DOC_UNCLOSED` at 0x5A03 |
| M8.2 | Nesting safety ceiling at 128; status code `ML_ERR_MAX_NEST_DEPTH` at 0x5A04 |
| M8.3 | Single-quote parallel `'...'` tracked alongside `"..."`; status code `ML_ERR_NESTED_QUOTE` at 0x5A05 |
| M8.4 | CtxLexer bridge: cross-check against `_cl_depth` / `_cl_stack[_cl_depth-1]`; klog_s1 "ML DEPTH DIVERGENCE ..." on mismatch |
| M8.5 | Expression-boundary undo ring: `_ml_reset` snapshots the just-dispatched expression byte image into a 16-slot ring |
| M8.6 | Nested bracket `[`/`]` tracking separate from `(`/`)` for per-record-stage projection syntax |
| M8.7 | Smoke-mode fingerprint goldens for the §5 acceptance corpus |
| M8.8 | Line-continuation `\<LF>` inside a string recognised as a cross-line marker that keeps the string open without the LF reaching the final string value |

None of the forward landings introduces a KIND surface this library
invokes against. The M8.4 CtxLexer bridge is the first forward
landing that introduces a one-way intra-library linker reference
(against R221.M4 CtxLexer's `_cl_depth` / `_cl_stack`); every other
landing stays self-contained over MultiLine's own `.bss`.

## 8. Boundary

MultiLine is PARSER-TIER by geography; it is NOT a full parser. The
following are explicitly out of scope at raw M8:

- Unicode awareness. MultiLine scans raw bytes, not NFC-normalised
  bytes. Every token it cares about (`{`, `}`, `(`, `)`, `"`, `\`)
  is a single-byte UTF-8 code point so the raw-byte scan is
  byte-equivalent to a code-point scan. Non-ASCII bytes with high
  bit set are literal body outside a string and literal body
  inside a string.
- Full tokenisation. MultiLine does NOT produce Token records. The
  accumulated bytes are STILL handed to CtxLexer (R221.M4) once
  the top-level expression closes.
- Grammar enforcement. MultiLine does not know that
  `datalog { fact . }` is a valid datalog block; it only tracks
  whether the braces balance. A `}` with no matching `{` is
  tolerated (counter clamps at 0); the full parser catches the
  semantic error later.
- Hint / spec production. MultiLine's job is to say whether to
  stay in READING, not to tell the user what the problem is. The
  continuation prompt's leading marker (`{`, `(`, `"`, `\`) is the
  only hint; the full parser's E-code taxonomy carries the richer
  diagnostic structure for a terminal commit.

## 9. File footprint

| File | Lines added | Lines removed |
|---|---|---|
| `tools/user/libpdx-pds-parser/src/multi_line.pdx` | ~630 | 0 |
| `tools/user/libpdx-pds-parser/src/lib.pdx` | 4 | 0 |
| `tools/user/libpdx-pds-parser/caps.decl` | ~160 | 0 |
| `tools/user/libpdx-pds-parser/STATUS.md` | ~75 | 0 |
| `tools/user/libpdx-pds-parser/CHANGELOG.md` | 0 | 0 (scratch file pulls in at Wave close) |
| `.plans/scratch/CHANGELOG-R229M8.md` | ~95 | 0 |
| `design/shell/multi-line-input.md` | ~390 | 0 |

The `tools/user/libpdx-pds-parser/CHANGELOG.md` consolidation stanza
lives under `.plans/scratch/CHANGELOG-R229M8.md` and is pulled into
the top-level CHANGELOG by main at Wave 129 close (per the
`feedback_paideia_as_parallel_changelog` convention).

## 10. Related

- `design/shell/repl-loop-scaffold.md` — R229.M1 REPL state machine.
  The RET-commit branch that drives MultiLine lives here.
- `design/shell/line-editor-emacs.md` — R229.M6 LineEditor. Supplies
  the `_le_buf[0.._le_buf_len)` byte range MultiLine scans.
- `design/shell/line-editor-vi.md` — R229.M7 ViMode. Same supplier
  of the byte range; MultiLine runs after RET-commit regardless of
  which editor mode produced the bytes.
- `design/shell/ctx-tracking-lexer.md` — R221.M4 CtxLexer. The full
  tokeniser that runs AFTER MultiLine reports COMPLETE.
- `design/shell/parser-fuzz-corpus.md` — R221.M7 FuzzHarness.
  MultiLine is a candidate for fuzz-driver inclusion in a later
  M8.7+ landing.
