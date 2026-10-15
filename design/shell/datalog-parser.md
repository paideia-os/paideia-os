# Datalog parser (R226.M1)

**Status:** v0.1 (R226.M1 — paideia-os#2692)
**Date:** 2026-10-14
**Author:** softarch (Wave UMB-W27)
**Scope:** The user-space parser-tier module that turns a datalog
program's raw body bytes into a flat array of 48-byte `Clause`
records that the R226 evaluator (M3) consumes. Lands in
`libpdx-pds-parser` at
`tools/user/libpdx-pds-parser/src/datalog.pdx`.

---

## 1. Position in the parser substrate

```
                 raw datalog program bytes
                           |
                           v
       +------------------------------------------+
       | R221.M1  Utf8Nfc::_u8n_decode_and_       |
       |          normalize   (UTF-8 + NFC)       |
       +---------------------+--------------------+
                             |
                             v  NFC-form bytes
       +------------------------------------------+
       | R226.M1  Datalog::_dl_parse  (THIS)      |
       +---------------------+--------------------+
                             |
                             v  Clause[0..n]
                 +-----------+-----------+
                 |                       |
                 v                       v
       +---------------+       +--------------------+
       | R226.M2  pred-|       | R226.M3  bottom-up |
       | type resolver |       | semi-naive eval    |
       | (schema       |       | over R127.M7       |
       |  registry)    |       | history_facts      |
       +---------------+       +--------------------+
                                        |
                                        v
                             +--------------------+
                             | R226.M4  magic-set |
                             | rewriting; M11     |
                             | per-query          |
                             | fingerprint        |
                             +--------------------+
```

R221.M1 lands the UTF-8 + NFC pre-pass that this module's input
contract assumes. R221.M4 (the context-tracking lexer, not yet
landed) is a separate, richer lexer for the pds-lang BODY; this
module is deliberately NARROWER — a datalog-only parser that
handles exactly the `Clause+` outer grammar, exposes head terms as
raw `(offset, len)` spans, and holds the body as a single
`(body_offset, body_len)` span for M2+ to re-parse on demand.

## 2. Grammar (M1 subset)

```
Program    := Clause+
Clause     := Fact | Rule | Query
Fact       := Head "."
Rule       := Head ":-" Body "."
Query      := "?-" Body "."
Head       := identifier "(" TermList ")"
Body       := Atom ("," Atom)*
Atom       := identifier "(" TermList ")"
TermList   := Term ("," Term)*
Term       := variable | identifier | number | string
variable   := [A-Z] [A-Za-z0-9_]*
identifier := [a-z_] [A-Za-z0-9_]*
number     := [0-9]+
string     := "..." (double-quoted; honours \" and \\ escapes)
WS         := 0x20 | 0x09 | 0x0A | 0x0D
```

### 2.1 Minimal examples

| Input                                               | Clauses | Shape                                                      |
|-----------------------------------------------------|---------|------------------------------------------------------------|
| `parent(alice, bob).`                               | 1       | Fact, pred=`parent`, n_terms=2                             |
| `parent(X, Y) :- father(X, Y).`                     | 1       | Rule, pred=`parent`, n_terms=2, n_body_atoms=1             |
| `?- parent(X, bob).`                                | 1       | Query, n_body_atoms=1                                      |
| `edge(1,2). edge(2,3). ?- edge(X,Y).`               | 3       | Fact, Fact, Query                                          |
| `grandp(X,Z) :- parent(X,Y), parent(Y,Z).`          | 1       | Rule, pred=`grandp`, n_terms=2, n_body_atoms=2             |
| `has_name("Alice, Bob").`                           | 1       | Fact, pred=`has_name`, n_terms=1 (comma inside string)     |
| `?- fact(_, _, _, _, 1).`                           | 1       | Query, n_body_atoms=1                                      |

### 2.2 Deferred to R226.M2+

The following are explicitly OUT OF SCOPE at M1:

- `?var` and `$expr` sigils (M2+ will add them to Term).
- Negation (`!atom(X)`) and the stratification check (M5).
- Aggregation (`count(X)`, `sum(X)`, …) (M6).
- `datalog { ... }` block delimiters — the caller strips the
  outer `{` / `}` before handing the inner bytes to this module.
- Per-atom body parsing — M1 holds the body as a single
  `(body_offset, body_len, n_body_atoms)` tuple and M3's evaluator
  re-parses atoms as it walks them.

### 2.3 Dialect notes

- Nullary predicates (`foo().`) are permitted at M1 so a datalog
  program can represent propositional facts (useful for the
  "session startup" ambient facts the R226.M8 EDB will land).
  Strict `TermList := Term (',' Term)*` would reject these; the
  parser instead accepts an empty TermList and records n_terms=0.
- An empty body (`?-.` or `foo() :- .`) is accepted by the parser
  with `n_body_atoms = 0`; the evaluator (M3) is responsible for
  diagnosing a semantically useless empty-body query/rule.

## 3. Clause record layout (48 bytes)

```
offset  size  field
------  ----  -------------------------------------------------------
   0     1   kind                 u8  -- 1=Fact, 2=Rule, 3=Query
   1     3   _reserved0           u8[3]
   4     4   predicate_name_off   u32
   8     2   predicate_name_len   u16
  10     2   n_terms              u16  (head term count; 0..4)
  12     2   n_body_atoms         u16  (body atom count; 0..65535)
  14     2   _reserved1           u16
  16    16   term_offsets[4]      u32[4]
  32     8   term_lens[4]         u16[4]
  40     4   body_offset          u32
  44     2   body_len             u16
  46     2   _reserved2           u16
```

Total: 48 B (`DL_CLAUSE_SIZE`). Fits in 3/4 of an x86 cache line;
two clauses span ≤ 2 cache lines on a 64-byte line.

### 3.1 Spec reconciliation

The parent brief (paideia-os#2692) specifies the Clause record as
a 48-byte record carrying `{kind: u8, reserved: [u8;3],
predicate_name_offset: u32, predicate_name_len: u16, n_terms: u16,
n_body_atoms: u16, reserved: u16, term_offsets: [u32;4],
body_offset: u32}`. Summing the named fields:

```
1 + 3 + 4 + 2 + 2 + 2 + 2 + 16 + 4 = 36 bytes
```

That leaves 12 bytes trailing the 48-byte stride. This module
spends those 12 bytes on three slots that would otherwise force the
evaluator to re-scan the input:

- `term_lens[4]` (8 B) — the evaluator cannot extract a head term's
  byte span from the input buffer in O(1) without either (a) a
  companion length array or (b) re-scanning the TermList for each
  comma. (a) is 8 B of record stride and amortises to zero
  per-query cost; (b) is a per-query re-scan that defeats the
  purpose of structured records.
- `body_len` (2 B) — the evaluator cannot know how far into the
  input the body extends without either (a) a stored length or
  (b) scanning for the terminating `.` on every body walk. (a) is
  2 B; (b) is a per-rule-use scan.
- `_reserved2` (2 B) — reserved for M2+ (e.g., negation marker,
  stratum-id in the stratified-negation pass).

The externally-observable property (`out_cap / 48 = max_clauses`)
is preserved verbatim; the brief's field names, widths, and total
stride all match the record laid down here.

### 3.2 Kind encodings

| kind    | value | Which fields are populated?                                       |
|---------|-------|-------------------------------------------------------------------|
| Fact    | 1     | predicate_name_*, term_offsets[], term_lens[], n_terms            |
| Rule    | 2     | predicate_name_*, term_offsets[], term_lens[], n_terms, body_*    |
| Query   | 3     | body_offset, body_len, n_body_atoms (no head)                     |

For a Query, `predicate_name_offset = 0`, `predicate_name_len = 0`,
and `n_terms = 0`; the evaluator reads body_* instead. For a Fact,
`body_offset = 0`, `body_len = 0`, `n_body_atoms = 0`.

### 3.3 Term-span semantics

Each `(term_offsets[i], term_lens[i])` pair indexes the ORIGINAL
caller-supplied bytes buffer at
`[bytes_ptr + term_offsets[i], bytes_ptr + term_offsets[i] + term_lens[i])`.

- Variable (`X`): offset = position of 'X', len = 1.
- Identifier (`alice`): offset = position of 'a', len = 5.
- Number (`42`): offset = position of '4', len = 2.
- String (`"a,b"`): offset = position of opening `"`, len = 5 —
  **quotes INCLUDED** so the evaluator distinguishes identifier
  `foo` from literal `"foo"` without re-reading a type byte.

### 3.4 Body-span semantics

For a Rule or Query, `body_offset` points at the first
non-whitespace byte AFTER the `:-` or `?-` separator; `body_len`
extends up to (but NOT including) the terminating `.`.

`n_body_atoms` is counted as `comma_count_at_depth_0 + 1` when the
body span is non-empty, else 0. Commas inside a string literal
(`"..."` with `\"` / `\\` escapes) or inside a parenthesised
TermList are NOT counted.

Example: body `member(X, Y), parent(Y, Z)`:
- paren-depth 0 at the top-level `,` between `)` and `parent`,
- comma count at depth 0 = 1, so n_body_atoms = 2.

Example: body `has_name("Alice, Bob")`:
- paren-depth is >= 1 across the whole string literal,
- comma inside the string is in STRING state, not counted,
- comma count at depth 0 = 0, so n_body_atoms = 1.

## 4. State machine

### 4.1 Driver

The driver is a hand-rolled recursive-descent loop. Each iteration:

1. `_dl_skip_ws` to advance past inter-clause whitespace.
2. If cursor at EOI → finish successfully.
3. Admit the next clause slot (buffer capacity + hard clause cap).
4. Peek first non-ws byte:
   - `?` → parse Query (`?-` prefix + Body + `.`).
   - lowercase or `_` → parse Fact or Rule (Head then `.` or
     `:-` Body `.`).
   - else → `DL_ERR_SYNTAX`.
5. Zero-fill the 48-byte Clause slot.
6. Write the clause fields.
7. Advance the clause pointer by 48 B, bump `n_clauses_written`.
8. Loop.

### 4.2 Term scanner

The term scanner is dispatched by first-byte class after a leading
`_dl_skip_ws`:

| First byte class       | Scanner called           | Span includes       |
|------------------------|--------------------------|---------------------|
| `[A-Z]` (uppercase)    | `_dl_scan_ident_or_var`  | Variable name       |
| `[a-z_]` (lower/`_`)   | `_dl_scan_ident_or_var`  | Identifier name     |
| `[0-9]` (digit)        | `_dl_scan_number`        | Decimal digits      |
| `"` (double-quote)     | `_dl_scan_string`        | Opening + closing `"` |
| other                  | DL_ERR_SYNTAX            | —                   |

`_dl_scan_ident_or_var` returns the same span for both variables
and identifiers; the driver uses the first-byte class to distinguish
them when a downstream pass (R226.M2 schema resolution) needs the
distinction.

### 4.3 Body scanner (`_dl_scan_body`)

The body scanner is a two-register state machine over
(state, paren_depth):

```
STATE_NORMAL (0):
  '.'  at paren_depth==0 -> terminator, return
  ','  at paren_depth==0 -> n_atoms++
  '('                    -> paren_depth++
  ')'  at paren_depth>0  -> paren_depth--     (floor-clamp)
  '"'                    -> state=STRING
  WS, other              -> advance

STATE_STRING (1):
  '"'                    -> state=NORMAL
  '\\'                   -> state=STRING_ESC
  other                  -> advance

STATE_STRING_ESC (2):
  any                    -> state=STRING      (consume one byte)
```

EOI handling:

| At EOI, state == | Return                              |
|------------------|-------------------------------------|
| NORMAL           | `DL_ERR_SYNTAX` (no closing `.`)    |
| STRING           | `DL_ERR_UNTERMINATED_STRING`        |
| STRING_ESC       | `DL_ERR_UNTERMINATED_STRING`        |

On success, the scanner returns `(body_len << 32) | (n_atoms << 16) | DL_OK`
where `body_len` is the span length up to the terminator (exclusive)
and `n_atoms` is as described in §3.4.

## 5. Return shape

```
rax = (n_clauses << 32) | status
```

| Status                        | Hex value | Meaning                                                 |
|-------------------------------|-----------|---------------------------------------------------------|
| `DL_OK`                       | 0         | Full program parsed; n_clauses populated.               |
| `DL_ERR_SYNTAX`               | 0x2E00    | Grammar mismatch (e.g., missing `.`, bad first byte).   |
| `DL_ERR_TOO_MANY_CLAUSES`     | 0x2E01    | Program exceeds `DL_MAX_CLAUSES` (256).                 |
| `DL_ERR_TOO_MANY_TERMS`       | 0x2E02    | A Head has more than `DL_MAX_TERMS` (4) terms.          |
| `DL_ERR_UNTERMINATED_STRING`  | 0x2E03    | `"..."` open at EOI.                                    |
| `DL_ERR_OUT_TOO_SMALL`        | 0x2E04    | `out_cap < (n_clauses + 1) * 48`.                       |

Empty input (`bytes_len == 0` or all-whitespace) returns
`(0 << 32) | DL_OK = 0`: zero clauses, no error.

On any error, `n_clauses` is the count of clauses fully written
BEFORE the fault point. Callers treat the partial write as
discarded.

## 6. Status-code namespace reservation

DL_* codes live in `0x2E00..0x2EFF`, disjoint from every other
user-space packed-status range in the paideia-os tree:

| Range            | Owner                              |
|------------------|------------------------------------|
| 0x2700..0x27FF   | libpdx-pds-parser R221 Utf8Nfc     |
| 0x2A00..0x2AFF   | libpdx-pds-parser R222 SchemasSig  |
| 0x2B00..0x2BFF   | libpdx-pds-parser R223 Pipeline    |
| 0x2C00..0x2DFF   | libpdx-pds-parser R225 (reserved)  |
| 0x2E00..0x2EFF   | libpdx-pds-parser R226 Datalog     |
| 0x2F00..0x2FFF   | libpdx-pds-parser R227 (reserved)  |

Verified at R226.M1 landing time:

```
$ grep -rE '0x2E0[0-4]' paideia-os/{src,tools,design}
```

returns hits only in `caps.decl`, `src/datalog.pdx`, and this file.

## 7. Capacity / bound-check matrix

| Dimension               | Constant             | Error on overflow         |
|-------------------------|----------------------|---------------------------|
| Clauses per program     | `DL_MAX_CLAUSES=256` | `DL_ERR_TOO_MANY_CLAUSES` |
| Terms per Head          | `DL_MAX_TERMS=4`     | `DL_ERR_TOO_MANY_TERMS`   |
| Clause stride           | `DL_CLAUSE_SIZE=48`  | —                         |
| Output buffer capacity  | `out_cap`            | `DL_ERR_OUT_TOO_SMALL`    |
| Input byte count        | `bytes_len`          | implicit (EOI handling)   |

A caller sizing the out buffer for an N-clause program allocates
`N * DL_CLAUSE_SIZE = N * 48` bytes. The parser never writes past
the admission-checked `out_end = out_ptr + out_cap`.

Head term cap rationale: history_facts (R127.M7) carries four
semantic positions `(session_id, cmd_hash, exit_code, argc)` before
the fact row's tsc_start / tsc_end / argv_blob slabs; the standard
"query by one of those four" shape is the M1 target. A predicate
needing >4 args decomposes to two atoms joined on a shared variable
(`big_pred(A, B, C, D, E, F) :- pred_a(A, B, C, X), pred_b(X, D, E, F)`),
which M1 encodes cleanly as a 4-term Head plus a 2-atom body.

## 8. Interaction with R127.M7 history_facts

The first production R226.M3 evaluator runs over the history-facts
fact store at `src/kernel/core/svc/history_facts.pdx` (R127.M7).
That store is a per-session 128-entry ring of 64-byte audit-shaped
fact rows:

```
(session_id : u32, cmd_hash : u32, tsc_start : u64, tsc_end : u64,
 exit_code : i32,  argc : u32,     argv_blob_offset : u32, flags : u32)
```

### 8.1 Example query flow

Input program (strings = user input):

```
?- fact(_, _, _, _, 1).
```

M1 parser output (one Clause record):

```
kind                = 3 (Query)
predicate_name_*    = (0, 0)
n_terms             = 0
body_offset         = 3     (first non-ws byte after "?-")
body_len            = 20    ("fact(_, _, _, _, 1)")
n_body_atoms        = 1
```

M3 evaluator (future):

1. Reads body slab at `bytes_ptr + body_offset` for 20 bytes.
2. Splits body on top-level commas (1 atom here).
3. Walks the atom: ident `fact`, 5 term-slots.
4. Looks up `fact` in the schema registry (M2) → arity 5
   predicate backed by the history-facts kernel service.
5. Term 5 is a number `1` → dispatches to `_hf_query_by_exit(1)`.
6. Streams the matching 64-byte fact rows to the renderer.

### 8.2 Supported query predicates (M3 target)

| Datalog shape                      | Kernel verb                   | R127.M7 band |
|------------------------------------|-------------------------------|--------------|
| `fact(S, _, _, _, _)`              | `_hf_query_by_session(S)`     | HF_ST_Q_SES  |
| `fact(_, H, _, _, _)`              | `_hf_query_by_cmd_hash(H)`    | HF_ST_Q_HASH |
| `fact(_, _, _, _, E)`              | `_hf_query_by_exit(E)`        | HF_ST_Q_EXIT |

Compound predicates (e.g., `fact(2, _, _, _, != 0)`) decompose by
the M3 planner into a scan + inline filter; the kernel surface
stays the three primitive verbs documented in R127.M7 §3.

## 9. Test corpus plan (deferred to R226 fuzz milestone)

### 9.1 OK cases (round-trip)

1. `parent(alice, bob).` — minimal Fact.
2. `foo().` — nullary Fact.
3. `edge(1, 2).` — number terms.
4. `has_name("Alice").` — string term.
5. `has_name("Alice, Bob").` — string term with embedded comma.
6. `has_name("quote\"escape").` — `\"` escape.
7. `has_name("back\\slash").` — `\\` escape.
8. `grandparent(X, Z) :- parent(X, Y), parent(Y, Z).` — Rule w/ 2 body atoms.
9. `?- parent(X, bob).` — single-atom Query.
10. `?- parent(X, Y), ancestor(Y, bob).` — multi-atom Query.
11. `parent(X, Y) :- father(X, Y).` — single-atom Rule body.
12. `parent(X, Y) :- father(X, Y). parent(X, Y) :- mother(X, Y).` — 2 Rules.
13. `edge(1,2). edge(2,3). ?- edge(X,Y).` — 2 Facts + Query.
14. Program with leading whitespace / newlines / tabs between clauses.
15. Program with `_` identifier-only term (`_underscore_var`).
16. `fact(session_1, hash_abc, 0, 0, 0).` — identifier terms only.
17. `foo(a, b, c, d).` — exactly `DL_MAX_TERMS = 4` terms.
18. `fact(_, _, _, _, _).` — all wildcards (treated as idents).
19. 256-clause program (fits at `DL_MAX_CLAUSES`).
20. Query body with nested parens: `?- outer(f(X), Y).` — paren-depth tracking.

### 9.2 Error cases

| Input                                | Expected error                        |
|--------------------------------------|---------------------------------------|
| `parent(X, Y`                        | `DL_ERR_SYNTAX` (missing `)` and `.`) |
| `parent(X, Y) :- `                   | `DL_ERR_SYNTAX` (empty body + EOI)    |
| `foo(a, b, c, d, e).`                | `DL_ERR_TOO_MANY_TERMS` (5 > 4)       |
| `has_name("abc`                      | `DL_ERR_UNTERMINATED_STRING`          |
| `has_name("abc\`                     | `DL_ERR_UNTERMINATED_STRING`          |
| 257 clauses                          | `DL_ERR_TOO_MANY_CLAUSES`             |
| `.foo(X).`                           | `DL_ERR_SYNTAX` (`.` first)           |
| `?- `                                | `DL_ERR_SYNTAX` (EOI after `?-`)      |
| `?foo(X).`                           | `DL_ERR_SYNTAX` (missing `-`)         |
| `foo X).`                            | `DL_ERR_SYNTAX` (missing `(`)         |
| out_cap=47 (1 B short of 1 clause)   | `DL_ERR_OUT_TOO_SMALL`                |
| out_cap=48, 2-clause input           | `DL_ERR_OUT_TOO_SMALL` (on 2nd)       |

The error corpus has 40 cases total when the fuzz milestone adds
mutation-generated variants.

## 10. Encoder discipline

- Module basename `Datalog` matches `datalog.pdx`.
- Labels prefixed `dl_` for `_dl_parse`, `dl_sw_` for `_dl_skip_ws`,
  `dl_si_` for `_dl_scan_ident_or_var`, `dl_sn_` for `_dl_scan_number`,
  `dl_ss_` for `_dl_scan_string`, `dl_sb_` for `_dl_scan_body`.
  All prefixes stay clear of paideia-as reserved keywords
  (`loop`, `if`, `let`, `fn`, `ret`, `done`).
- No `test rN, rN` — every zero-check is `cmp reg, 0` or
  `cmp reg, imm32`.
- No `and rN, imm64` — mask operations use imm32-safe values
  (`0xFF`, `0xFFFF`, `0xFFFFFFFF`).
- No 2-op `imul r, imm` — term-slot stride uses `shl r, 2` (×4)
  and `shl r, 1` (×2).
- No multiline `pub let = "..."` — single-line justifications.
- Byte loads via `xor rax, rax; mov_b rax, [base + idx * 1]` with
  explicit `*1` scale (paideia-as #1248 + U1606 mitigation per
  libpdx-audit audit_file_sink and libpdx-pds-parser Pipeline).
- u32 stores via `mov_d [base + disp], reg` (per libpdx-argv +
  libpdx-pds-parser Pipeline precedent).
- u16 stores via two `mov_b` byte stores (low byte, high byte);
  `mov_w` short-form is not used in this repo.
- u64 zero-fill of a fresh 48-byte Clause via six `mov [r15 + disp], rax`
  with `rax = 0`.
- All `cmp reg, imm` immediates (<= `0x2E04`) fit in imm32 and are
  sign-safe. No MOVABS staging.

## 11. Stack discipline (SysV, entry `rsp%16 == 8`)

| Function                   | Prologue                       | Nested CALL rsp%16 |
|----------------------------|--------------------------------|--------------------|
| `_dl_skip_ws`              | 0 pushes, no frame             | n/a (leaf)         |
| `_dl_scan_ident_or_var`    | 0 pushes, no frame             | n/a (leaf)         |
| `_dl_scan_number`          | 0 pushes, no frame             | n/a (leaf)         |
| `_dl_scan_string`          | 0 pushes, no frame             | n/a (leaf)         |
| `_dl_scan_body`            | 0 pushes, no frame             | n/a (leaf)         |
| `_dl_parse`                | 5 pushes + `sub rsp, 48` = 88  | 0 (aligned)        |

Entry `rsp%16 == 8`; `_dl_parse` adds 88 bytes to reach
`rsp%16 == 0` before each nested CALL. Every helper is a pure
leaf (zero callee-save pushes, zero nested CALLs) so no helper
disturbs the alignment of its caller.

## 12. Caller flow

```
   /* 1. Allocate the out buffer. */
   const size_t max_clauses = 64;
   uint8_t clauses[max_clauses * 48];

   /* 2. Call the parser. */
   uint64_t packed = _dl_parse(
       bytes_ptr, bytes_len,
       clauses, sizeof(clauses));

   uint32_t n_clauses = packed >> 32;
   uint32_t status    = packed & 0xFFFFFFFFu;

   if (status != 0) { /* handle error */ return; }

   /* 3. Walk the clause records. */
   for (uint32_t i = 0; i < n_clauses; i++) {
       const uint8_t *c = clauses + i * 48;
       uint8_t  kind      = c[0];
       uint32_t pred_off  = *(uint32_t *)(c + 4);
       uint16_t pred_len  = *(uint16_t *)(c + 8);
       uint16_t n_terms   = *(uint16_t *)(c + 10);
       uint16_t n_body    = *(uint16_t *)(c + 12);
       /* ... */
   }
```

The parser never mutates `bytes_ptr`; the per-term and per-body
spans refer to the caller's input buffer verbatim. The caller is
responsible for keeping the input buffer alive as long as the
clause records reference it.

## 13. Forward path

| Milestone  | What it adds                                     | Depends on |
|------------|--------------------------------------------------|------------|
| R226.M2    | Predicate-type resolution against R220.M4 schema | R226.M1    |
| R226.M3    | Bottom-up semi-naive evaluator over R127.M7      | R226.M2    |
| R226.M4    | Magic-set rewriting (Beeri & Ramakrishnan 1991)  | R226.M3    |
| R226.M5    | Stratified negation                              | R226.M3    |
| R226.M6    | Aggregation library (count/sum/min/max/avg)      | R226.M3    |
| R226.M7    | Graph-traversal via TypedGraph effect            | R226.M3    |
| R226.M8    | Session-local EDB (assert/retract)               | R226.M3    |
| R226.M9    | Query-time type-check + rejection                | R226.M2    |
| R226.M10   | Progress emission for long queries               | R226.M3    |
| R226.M11   | Per-query fingerprint                            | R220.M10   |

M2 adds body re-parsing: the evaluator re-splits the body span on
top-level commas (same state machine as `_dl_scan_body` but with
per-atom head + TermList extraction) and type-checks each atom's
TermList against the schema registry. The Clause record stride stays
48 bytes; M2's atom records are allocated in a sibling arena.

## 14. Open questions (resolved for M1)

- **Q: Should the parser build a nested atom list for Body at M1,
  rather than deferring to M2?**
  A: No. M1's goal is a flat Clause record that one 48-byte copy
  seats. Deferring body atoms to M2 keeps the parser's output
  structure flat and defers the evaluator's internal representation
  to the pass that owns it.
- **Q: Should strings include their enclosing quotes in the stored
  span?**
  A: Yes. The evaluator distinguishes `foo` (identifier) from
  `"foo"` (string literal) by the first byte of the span (`"` vs
  alpha/underscore). Storing without quotes would force the
  evaluator to carry a per-term type byte, bloating the record.
- **Q: What's the correct behavior for `foo()` (nullary head)?**
  A: Accept with n_terms = 0. Datalog folklore permits propositional
  predicates and the R226.M8 EDB will need them for ambient facts.
- **Q: Should `?- ` with an empty body be a syntax error at the
  parser tier?**
  A: No. The parser records n_body_atoms = 0 and lets the evaluator
  diagnose the semantically empty query. Keeping the parser
  policy-light (and the evaluator policy-heavy) is consistent with
  the pipeline parser's deferral of `cp 'as' 'bs'` tail detection
  to the R129.M5 post-pass.

## 15. References

- design/terminal/semantic-shell-language-plan.md R226 table.
- design/shell/history-datalog-substrate.md (R127.M7 substrate).
- design/shell/pipeline-stage-parser.md (sibling parser-tier
  module; shape precedent for the 4-state tokeniser and packed
  return convention).
- design/shell/cmd-functor-schemas-sig.md (R222.M1 SchemasSig;
  shape precedent for pure-leaf scan helpers over an NFC-form
  input buffer).
- Abiteboul, Hull, Vianu, *Foundations of Databases*, Chapter 12
  (standard Datalog semantics; M3 is scored against this corpus).
- Beeri, Ramakrishnan, "On the Power of Magic", *J. Logic
  Programming*, 1991 (M4 rewriting).
