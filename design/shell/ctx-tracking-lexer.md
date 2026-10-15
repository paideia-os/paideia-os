# Context-tracking lexer (R221.M4)

Upstream: paideia-os#2485 (R221 parser-tier Unicode + lexer umbrella),
paideia-os#2654 (R221.M4 THIS landing). Substrate:

- `tools/user/libpdx-pds-parser/src/utf8_nfc.pdx` (R221.M1 -- NFC input).
- `tools/user/libpdx-pds-parser/src/grapheme_iter.pdx` (R221.M2 -- cluster
  iterator used by R221.M3 WidthPass; NOT re-used here because the lexer
  classifies by code-unit boundaries at the ASCII subset).
- `tools/user/libpdx-pds-parser/src/width_pass.pdx` (R221.M3 -- column
  classifier, used by the REPL grid renderer, not by the lexer).

Consumers (post-M4):

- R221.M5 unified AST sum type -- consumes `(kind, ctx, span, payload)`
  records emitted by this module.
- R229.M3-dispatch kernel-side REPL dispatch -- feeds the first token
  into the type-env / session-env substrate.
- R225.M5 cross-context type flow -- walks the `ctx` byte on each
  token to decide whether a value crosses a pipeline/datalog/lambda
  boundary.

## 1. Why

The pds-lang semantic shell weaves three sub-languages into one
surface: the **pipeline tier** (`ls | wc`), the **datalog tier**
(`datalog { parent(X,Y) :- ... }`), and the **lambda tier**
(`{ |x| x+1 }`). Each tier reinterprets the same ASCII glyphs:

| glyph | pipeline        | datalog                 | lambda      |
|-------|-----------------|-------------------------|-------------|
| `|`   | stage pipe      | SYNTAX error            | arg delim   |
| `{`   | lambda / block  | datalog body opener     | nested      |
| `.`   | argv dot        | clause terminator       | path sep    |
| `->`  | n/a             | n/a                     | arrow       |
| `:-`  | n/a             | rule-head terminator    | n/a         |
| `?-`  | n/a             | query lead-in           | n/a         |

A single-pass byte-walking lexer that does not track the enclosing
context cannot emit `|` as the right kind. Rather than snaking tier
state through every downstream consumer, R221.M4 captures it ONCE at
lex-time: every emitted token carries a `ctx` byte, so the AST
builder (R221.M5), the type-check pass (R225.M3+), and the evaluator
dispatch (R229.M3-dispatch) all walk the same byte image without
re-deducing the enclosing tier.

Lexer-level tier tracking is also the minimum amount of context any
future error-reporting pass needs: a diagnostic "pipe `|` not legal
inside `datalog { ... }` body" is derivable from the token's own
`ctx` field without re-scanning the input.

## 2. Context model

Three context codes:

```
CTX_PIPELINE = 0   // outer / implicit; also the initial context
CTX_DATALOG  = 1   // inside datalog { ... }
CTX_LAMBDA   = 2   // inside lambda-literal { |args| body }
```

The lexer maintains a **16-byte stack** in `.bss` plus a `depth` word.
`depth == 0` means the stack is empty and the implicit outer context
is CTX_PIPELINE. Every open-brace `{` pushes; every close-brace `}`
pops. Three dispositions for `{`:

```
   datalog {         --> push CTX_DATALOG
   {  WS*  |         --> push CTX_LAMBDA
   { (otherwise)     --> push a COPY of the current context
                         (bare block-expression opener)
```

The third case is the brace-balancing invariant: every `{` pushes
SOMETHING so every `}` has a matching entry to pop. A `{` inside a
pipeline that opens a plain block (rare at M4; reserved for future
expression-grammar landings) stays in CTX_PIPELINE because its push
copies the outer context verbatim.

The `.bss` singleton is session-wide. A caller that re-enters the
lexer against a fresh input (e.g. the REPL after each turn) MUST
call `_cl_init` first to zero the stack, depth, and the last-kind
tracker (see §5.6). This mirrors the `_er_init`/`_se_init` boot-hook
discipline from R224.M3 EffectRow and R229.M2 SessionEnv.

Stack-overflow guard: push on a full stack (depth == 16) returns
`CL_ERR_STACK_OVERFLOW`. The 16-level ceiling is a parser-grammar
cap, not a lexer limitation; 16 is well above the practical nesting
depth of pds-lang (two nested lambdas inside a datalog body inside
a pipeline stage reaches depth 3). Pop on an empty stack (depth == 0)
returns `CL_ERR_STACK_UNDERFLOW` -- an unmatched `}` at top level.

## 3. Grammar scope (M4)

Tokens emitted at M4:

```
TOK_EOF          = 0
TOK_IDENT        = 1
TOK_NUMBER       = 2
TOK_STRING       = 3
TOK_PIPE         = 4    // '|' in CTX_PIPELINE
TOK_ARG_DELIM    = 5    // '|' in CTX_LAMBDA
TOK_LBRACE       = 6
TOK_RBRACE       = 7
TOK_LPAREN       = 8
TOK_RPAREN       = 9
TOK_COMMA        = 10
TOK_KW_DATALOG   = 11
TOK_ARROW        = 12   // '->'
TOK_COLON        = 13   // ':'
TOK_DOT          = 14   // '.'
TOK_RULE_ARROW   = 15   // ':-'
TOK_QUERY_ARROW  = 16   // '?-'
```

Lexical byte classes (ASCII only at M4; the input has already been
NFC-normalised by R221.M1, and the identifier/number/string classes
all sit entirely in the ASCII subset):

```
IDENT_START    := [A-Za-z_]
IDENT_CONT     := [A-Za-z0-9_]
DIGIT          := [0-9]
WS             := SP | TAB | LF | CR
```

Identifier bytes classified: the one keyword recognised at M4 is
`datalog`. Any seven-byte identifier whose bytes spell exactly
`d a t a l o g` is emitted as `TOK_KW_DATALOG`; every other
identifier is `TOK_IDENT`. This is sufficient to drive the
context-switch heuristic; a wider keyword table arrives in R221.M5
alongside the AST.

Numbers are decimal digit runs (`[0-9]+`). The payload slot is set
to zero at M4; R221.M5 reinterprets the span as a parsed integer.

Strings are `"..."` with the two documented escapes `\"` (literal
quote) and `\\` (literal backslash); any other `\X` passes both
bytes through verbatim. The emitted span EXCLUDES the surrounding
quotes but INCLUDES the escape bytes (the un-escape pass runs
downstream, same shape as pipeline.pdx's bareword/dq semantics).
Unterminated string returns `CL_ERR_UNTERMINATED_STRING`.

Multi-byte operators are recognised via one-byte lookahead:

```
'-' then '>'   -> TOK_ARROW         (len 2)
':' then '-'   -> TOK_RULE_ARROW    (len 2)
':' otherwise  -> TOK_COLON         (len 1)
'?' then '-'   -> TOK_QUERY_ARROW   (len 2)
'?' otherwise  -> CL_ERR_SYNTAX
'-' otherwise  -> CL_ERR_SYNTAX   (`-` is a reserved punctuator at M4;
                                   arithmetic '-' arrives at M5
                                   with the expression grammar.)
```

The `.`, `(`, `)`, `,`, `{`, `}` characters each emit their
single-char token with no lookahead.

Any other byte (control char, UTF-8 high byte, misplaced punctuator)
returns `CL_ERR_SYNTAX` with `new_cursor` set to the fault byte so
the diagnostic can point at the offending span.

## 4. Token record (16 B)

```
offset  size  field
------  ----  ---------------------------------
 0x00    2    kind                u16
 0x02    1    ctx                 u8   (CTX_* code)
 0x03    1    flags               u8   (reserved; 0 at M4)
 0x04    4    src_offset          u32
 0x08    4    src_length          u32
 0x0C    4    payload             u32  (0 at M4; M5 fills for num/string)
```

16-byte stride matches `shl r, 4` for slot addressing (precedent:
RowTypes TyNode). The emitted span `[src_offset, src_offset + src_length)`
indexes the ORIGINAL caller-supplied bytes buffer, verbatim.

For `TOK_LBRACE`: `ctx` is the context JUST PUSHED (the inner
context the `{` opens). For `TOK_RBRACE`: `ctx` is the context
JUST POPPED (the inner context being closed). Both brace tokens
thus carry the INNER context code, so a downstream dispatcher can
discriminate a lambda-closing `}` from a datalog-closing `}` by a
single byte load.

For `TOK_EOF`: `ctx` is whatever the stack says at EOI (depth==0
after a well-formed program closes all braces; depth>0 if the
caller stopped mid-way). The EOF span has length 0.

## 5. Public API

```
_cl_init() -> ()
_cl_push_ctx(ctx: u8) -> errno
_cl_pop_ctx() -> packed_u64   // (ctx << 32) | status
_cl_current_ctx() -> u8
_cl_lex_token(bytes, len, cursor, out_token) -> packed_u64
_cl_tokenize(bytes, len, out, out_cap) -> packed_u64
```

### 5.1 `_cl_init`

Zero-fills `_cl_stack` (16 B), `_cl_depth` (u64), and
`_cl_last_kind` (u64). Pure leaf; no CALL.

Mandatory boot hook. Every entry point SHORT-CIRCUITS on a
not-yet-initialised state by re-reading `.bss` zero (depth 0 =
CTX_PIPELINE), so an un-called `_cl_init` degrades gracefully to
"fresh pipeline session"; nonetheless the user-space wiring at
R229.M3-dispatch calls `_cl_init` at REPL-session boot alongside
`_se_init` / `_te_init_session`.

### 5.2 `_cl_push_ctx`

```
rdi = ctx code (0, 1, or 2)
rax = CL_OK on success,
      CL_ERR_BAD_CTX on ctx > 2,
      CL_ERR_STACK_OVERFLOW if depth == 16.
```

Public primitive for test harnesses. The internal lexer manages
the stack via direct `.bss` writes without calling this entry
point (register-pressure reason -- see §6).

### 5.3 `_cl_pop_ctx`

```
rax = (popped_ctx << 32) | status
```

Returns `CL_ERR_STACK_UNDERFLOW` on empty stack; otherwise
decrements depth, loads the pre-decrement top byte, and packs it
in the high 32 bits.

### 5.4 `_cl_current_ctx`

Returns the active context byte: `stack[depth-1]` if `depth > 0`,
else `CTX_PIPELINE`. Pure leaf.

### 5.5 `_cl_lex_token`

The lexer core. See §6 for the state machine.

```
rdi = bytes_ptr
rsi = bytes_len
rdx = cursor_in
rcx = out_token  (pointer to a 16-byte slot the lexer writes)
rax = (new_cursor << 32) | status
```

On success, `out_token[0..16]` is filled per §4 and
`new_cursor` points past the consumed bytes. On error, the token
record is NOT written and `new_cursor` points at the fault byte.

### 5.6 `_cl_tokenize`

Walks the whole input, writing successive 16-byte tokens to the
caller's output buffer until it emits a `TOK_EOF` or hits an error.

```
rdi = bytes_ptr
rsi = bytes_len
rdx = out_ptr
rcx = out_cap   (bytes; must be >= 16 for a sensible walk)
rax = (bytes_written << 32) | status
```

`bytes_written` is the number of 16-byte records committed BEFORE
the fault point (partial write on error; caller treats as prefix).

## 6. State machine (M4)

The lexer is a dispatch loop with the following top-level shape:

```
loop:
  skip WS (SP | TAB | LF | CR)
  if cursor == bytes_len: emit TOK_EOF; return
  classify first byte:
    [A-Za-z_]  -> ident / keyword run
    [0-9]      -> number run
    '"'        -> string
    '{'        -> dispatch_lbrace
    '}'        -> dispatch_rbrace
    '|'        -> dispatch_pipe
    '-' '>'    -> TOK_ARROW
    ':' '-'    -> TOK_RULE_ARROW
    ':'        -> TOK_COLON
    '?' '-'    -> TOK_QUERY_ARROW
    '.'        -> TOK_DOT
    '('        -> TOK_LPAREN
    ')'        -> TOK_RPAREN
    ','        -> TOK_COMMA
    otherwise  -> CL_ERR_SYNTAX
```

### 6.1 `dispatch_lbrace`

```
if _cl_last_kind == TOK_KW_DATALOG:
    push CTX_DATALOG
else:
    scan lookahead[cursor+1 ..] past SP/TAB (NOT past LF/CR):
      if next non-WS byte is '|': push CTX_LAMBDA
      else                      : push COPY of current context
emit TOK_LBRACE with ctx = (post-push, i.e. the inner context)
```

The lookahead is bounded by the first LF/CR OR end-of-input OR
the first non-space byte, so the worst-case walk is one line.
No separate token-count ceiling is needed; LF/CR terminates
regardless of how many bytes separate `{` from the possible `|`.

### 6.2 `dispatch_rbrace`

```
emit TOK_RBRACE with ctx = (pre-pop, i.e. the inner context)
if depth == 0: return CL_ERR_UNMATCHED_BRACE
else         : pop
```

The emit happens FIRST so the token carries the inner context
byte; the pop then unwinds the stack for the next lex call.

### 6.3 `dispatch_pipe`

```
switch current_ctx:
  CTX_PIPELINE : emit TOK_PIPE
  CTX_LAMBDA   : emit TOK_ARG_DELIM
  CTX_DATALOG  : return CL_ERR_PIPE_IN_DATALOG
```

### 6.4 last-kind tracking

`_cl_last_kind` is updated on every successful emit (including
EOF). The datalog-keyword heuristic in §6.1 reads this byte via a
single-qword `.bss` load. The initial zero (`TOK_EOF`) is also the
sentinel for "first call since init"; `{` as the first token of a
fresh session therefore cannot be a `datalog {` (the ident must
precede), so the heuristic correctly falls through to the lambda
lookahead on a start-with-brace input.

## 7. Error band (0x4200..0x42FF)

Nine slots used at M4; 247 slots reserved for M4.1+ follow-ups.

```
CL_OK                    : 0
CL_ERR_SYNTAX            : 0x4200   unrecognised byte / bad op lookahead
CL_ERR_STACK_OVERFLOW    : 0x4201   push on depth == 16
CL_ERR_STACK_UNDERFLOW   : 0x4202   pop on depth == 0
CL_ERR_UNMATCHED_BRACE   : 0x4203   '}' with depth == 0 at emit time
CL_ERR_PIPE_IN_DATALOG   : 0x4204   '|' token in CTX_DATALOG
CL_ERR_UNTERMINATED_STRING : 0x4205 '"' at EOI without closing '"'
CL_ERR_OUT_TOO_SMALL     : 0x4206   _cl_tokenize: out_cap not large enough
CL_ERR_BAD_CTX           : 0x4207   _cl_push_ctx: ctx > 2
```

The band carves a kilo-step boundary past R224.M3 EffectRow
(0x4000..0x40FF) and the reserved R133.M6 kernel-parallel slot
(0x4100..0x41FF). Slots 0x4208..0x42FF are reserved for M4.1+
(bad-UTF-8 byte in a code-point run, M5 keyword-set growth,
long-identifier cap, etc.).

Grep-disjointness confirmation at R221.M4 landing time:

```
grep -rE '0x420[0-7]\b' paideia-os/{src,tools,design,tests}
  -> no packed-status hits outside this file + src/ctx_lexer.pdx
     + caps.decl.
```

## 8. Register / stack-frame plan

### `_cl_lex_token` (pure leaf; no nested CALL)

```
Prologue:
  push rbx            // callee-save, scratch
  push r12            // callee-save, scratch
  push r13            // cursor
  push r14            // out_token pointer
  push r15            // start_offset snapshot

  mov rbx, rdi        // bytes_ptr
  mov r12, rsi        // bytes_len
  mov r13, rdx        // cursor
  mov r14, rcx        // out_token

Entry rsp%16 == 8; after 5 pushes rsp%16 == 0; no `sub rsp` needed
because there's no nested CALL. Scratch: rax, rcx, rdx, rdi, rsi,
r8, r9, r10, r11 (all SysV caller-save). r8 is used to carry the
emitted kind into the shared emit path.
```

Side-effect budget: at most two `.bss` writes per call
(`_cl_depth` + `_cl_stack[k]` on push, or `_cl_depth` on pop) plus
the `_cl_last_kind` write on emit. All via `lea r11, [rip+sym]`.

### `_cl_tokenize` (one nested CALL per iteration)

```
Prologue:
  push rbx            // bytes_ptr snapshot
  push r12            // bytes_len snapshot
  push r13            // out_ptr base
  push r14            // out_end (out_ptr + out_cap)
  push r15            // write cursor
  sub rsp, 16         // [rsp+0] = cursor_in; [rsp+8] = tok_count

Entry rsp%16 == 8; after 5 pushes + 16-pad rsp%16 == 0. Nested
CALLs into `_cl_lex_token` are rsp%16-aligned.
```

The loop:

```
  if write cursor + 16 > out_end: return (count<<32) | CL_ERR_OUT_TOO_SMALL
  _cl_lex_token(bytes, len, cursor_in, write_cursor)
  if status != CL_OK: return (count<<32) | status
  cursor_in := new_cursor
  write_cursor += 16; count += 1
  if emitted kind == TOK_EOF: return (count<<32) | CL_OK
  goto loop
```

Count INCLUDES the TOK_EOF record so a caller that walks the
output stops when it reads a 0 in the kind slot.

## 9. paideia-as encoder discipline

Per the pdx-encoder-pitfalls memo:

- No `test rN, rN`: every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64`: all masks are imm8 / imm32 (0xFF, 0xFFFF).
- No 2-op `imul r, imm`: stride multiplies are `shl r, 1` / `shl r, 4`.
- No multiline `pub let = "..."` -- all justifications are
  single-line.
- Module basename `CtxLexer` matches `ctx_lexer.pdx`.
- Labels prefixed `cl_` with per-function suffix (`cl_lt_`,
  `cl_ti_`, `cl_ip_`, `cl_pp_`, `cl_cu_`, `cl_tz_`); confirmed
  disjoint from `cc_`/`cs_`/`clo_` and from paideia-as reserved
  keywords (`loop`, `if`, `let`, `fn`, `ret`, `done`).
- All `cmp reg, imm` immediates `<= 0x42FF < 0x80000000`, so direct
  `cmp reg, imm32` is sign-extension-safe; no MOVABS staging.
- Byte loads via `xor rax, rax; mov_b rax, [base + idx * 1]`
  (explicit *1 scale per libpdx-audit audit_file_sink precedent).
- u32 stores via `mov_d [base + disp], reg` (precedent: Pipeline
  _pl_emit_word, libpdx-argv emit_parse_error).
- u16 stores via two `mov_b` byte stores (low byte, high byte);
  mov_w short-form is not used in this repo.

### Register-liveness

r11 is clobbered by any nested CALL (even into leaf helpers in
other modules such as `_u8n_decode_and_normalize` or
`_gi_next_cluster`). The lexer core at M4 does NOT make such calls
(it stays in the ASCII subset and does not re-normalise); if a
future landing adds a cross-module nested CALL, the register plan
must move the surviving state into r12..r15 before the call and
reload any `lea r11, [rip + sym]` addresses afterwards. This is
the standing lesson from Wave 118 (`_te_specialize`) and Wave 120
(`_er_label_lookup` lazy-init).

### Full-u64 status compares (Wave 118 lesson)

The `_cl_tokenize` dispatch on the nested `_cl_lex_token` status
compares the FULL rax (packed `(cursor<<32)|status`) against zero
after masking: the packed form is non-zero iff the cursor is
non-zero OR the status is non-zero. Masking: `mov r11, 0xFFFFFFFF;
and rax (status low 32), r11` is the pitfall-safe shape at the
32-bit mask boundary -- the mask fits in imm32 but is written via a
register to avoid `and rN, imm64` (even though 0xFFFFFFFF fits in
imm32, the encoder's imm32 path for `and` is bit-31-sensitive on
some operand widths; see pdx-encoder-pitfalls). An alternative is
`shl rax, 32; shr rax, 32` which has no imm field at all.

## 10. 40-example fixture (acceptance)

Enumerated here for the test harness that lands later (R221.M7
parser fuzz corpus); the design-doc enumeration is the spec that
corpus goldens from.

**Pipeline-only (5 cases, all tokens ctx=0):**

```
 1. ls | wc                               -> IDENT, PIPE, IDENT, EOF
 2. echo hello                            -> IDENT, IDENT, EOF
 3. find . -type f                        -> ERR_SYNTAX at '-' (M4 reserves)
 4. ls | wc | sort                        -> IDENT PIPE IDENT PIPE IDENT EOF
 5. foo.bar                               -> IDENT DOT IDENT EOF
```

**Datalog-only (10 cases; `datalog {` opens, `}` closes):**

```
 6. datalog { parent(a,b) }               -> KW_DATALOG LBRACE[ctx=1]
                                             IDENT[ctx=1] LPAREN IDENT COMMA
                                             IDENT RPAREN RBRACE[ctx=1] EOF
 7. datalog { parent(a,b). }              -> ...IDENT RPAREN DOT RBRACE EOF
 8. datalog { r(X):-p(X). }               -> KW_DATALOG LBRACE
                                             IDENT LPAREN IDENT RPAREN
                                             RULE_ARROW
                                             IDENT LPAREN IDENT RPAREN DOT
                                             RBRACE EOF
 9. datalog { ?-q(X). }                   -> KW_DATALOG LBRACE QUERY_ARROW ...
10. datalog { f(1,2). }                   -> ...NUMBER COMMA NUMBER...
11. datalog { f("a"). }                   -> ...STRING...
12. datalog { }                           -> KW_DATALOG LBRACE RBRACE EOF
13. datalog                               -> KW_DATALOG EOF
14. datalog { p | q }                     -> ERR_PIPE_IN_DATALOG
15. datalog { p(X,Y,Z). }                 -> three IDENT terms
```

**Lambda-only (10 cases; `{` with `|` lookahead opens CTX_LAMBDA):**

```
16. {|x| x }                              -> LBRACE[ctx=2] ARG_DELIM
                                             IDENT ARG_DELIM IDENT RBRACE EOF
17. { |x| x + 1 }                         -> ERR_SYNTAX at '+' (M4 reserves)
18. { |x,y| x }                           -> LBRACE ARG_DELIM IDENT COMMA
                                             IDENT ARG_DELIM IDENT RBRACE EOF
19. {|| x }                               -> LBRACE ARG_DELIM ARG_DELIM
                                             IDENT RBRACE EOF  (zero-arg)
20. { |x:u64| x }                         -> LBRACE ARG_DELIM IDENT COLON
                                             IDENT ARG_DELIM IDENT RBRACE EOF
21. filter { |x| x }                      -> IDENT[ctx=0] LBRACE[ctx=2]
                                             ARG_DELIM IDENT ARG_DELIM
                                             IDENT RBRACE[ctx=2] EOF
22. {|x|x}                                -> no-WS flavour of case 16
23. { |x| }                               -> empty body; LBRACE ARG_DELIM
                                             IDENT ARG_DELIM RBRACE EOF
24. {|f|{|x|f(x)}}                        -> nested lambda, depth 2 at inner
25. { ident_without_pipe }                -> LBRACE[ctx=0] IDENT[ctx=0]
                                             RBRACE[ctx=0] EOF
                                             (NOT a lambda: no '|')
```

**Nested / cross-context (10 cases):**

```
26. datalog { p(X). } | wc                -> KW_DATALOG LBRACE
                                             ... RBRACE PIPE[ctx=0] IDENT EOF
27. ls | datalog { p(X). }                -> IDENT PIPE KW_DATALOG LBRACE
                                             ... RBRACE EOF
28. { |x| datalog { p(x). } }             -> LBRACE[ctx=2]... KW_DATALOG
                                             LBRACE[ctx=1]... RBRACE[ctx=1]
                                             RBRACE[ctx=2] EOF
29. datalog { p({X}) }                    -> KW_DATALOG LBRACE[ctx=1]
                                             IDENT LPAREN LBRACE[ctx=1]
                                             (block, not lambda; no '|')
                                             IDENT RBRACE[ctx=1] RPAREN
                                             RBRACE EOF
30. { }                                   -> LBRACE[ctx=0] RBRACE[ctx=0] EOF
                                             (empty block in pipeline)
31. }                                     -> ERR_UNMATCHED_BRACE
32. {                                     -> LBRACE at EOI; depth=1 at EOF
                                             (not an error at lex-level;
                                             caller's job to notice)
33. "unterminated                         -> ERR_UNTERMINATED_STRING
34. @bad                                  -> ERR_SYNTAX at '@'
35. a_b_c                                 -> IDENT (underscore mid-ident)
36. _abc                                  -> IDENT (underscore start)
37. 1234                                  -> NUMBER
38. "a\"b"                                -> STRING with escape
39. "a\\b"                                -> STRING with escape
40. datalog{p(X).}                        -> no-WS flavour of case 7
                                             (NFC-normalised input strips
                                             no WS; the lexer tolerates
                                             the absence)
```

The 40 cases exercise every token kind in every reachable context,
both parse-success and all seven error codes. Case 24 drives the
stack to depth 2 and verifies the inner `}` pops to CTX_LAMBDA
before the outer `}` pops to CTX_PIPELINE.

## 11. Forward path

- R221.M5 unified AST -- consumes `(kind, ctx, src_offset, src_length,
  payload)` records.
- R221.M6 span-mapping NFC variant -- co-emits a byte-span map that
  the lexer can push through `src_offset` without re-decoding.
- R221.M7 parser fuzz corpus -- 24-hour AFL run against the
  tokeniser, including the 40 fixture cases above as seed inputs.
- R225.M3+ typechecker -- walks the token's `ctx` byte to decide
  predicate-vs-pipeline-record flow.
- R229.M3-dispatch -- wires `_cl_init` into the per-session boot
  alongside `_se_init` / `_te_init_session`.
