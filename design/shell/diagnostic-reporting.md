# Diagnostic Reporting with Source Spans + Suggestions (R225.M7)

**Issue:** paideia-os#2688 (R225.M7)
**Umbrella:** paideia-os#2489 (R225 HM typechecker)
**Satellite:** `tools/user/libpdx-pds-parser/src/diag_report.pdx`
**Status:** landed Wave 130.
**Design-tier wave convention:** per
`design/terminal/semantic-shell-language-plan.md` §R225 and the
Novel-Clean-Design directive (diagnostics-first — a nested type error
produces a span-anchored diagnostic with a mechanical suggestion when
one is derivable; the shell never silently falls through to a cascading
"ambiguous type variable" at a different site).

## 1. Scope and motivation

Every type error that leaves the elaborator (R225.M1 HmCore, R225.M2
RowTypes, R225.M4 EffectUnify, R225.M6 RankCheck, R225.M3 Datalog
predicate-type resolution when it lands) must carry four things so
the REPL and the LSP-embed consumer can render it without re-walking
the AST:

1. A **primary span** — byte-offset + byte-length into the *source*
   buffer (not the NFC-normalised intermediate; the Q-A5 invariant).
   This is the one span the diagnostic underlines.
2. An optional **secondary span** — the "related information" span
   pointing at e.g. the earlier colliding binding or the type
   declaration that fixed `expected` to a specific kind. Reserved at
   M7; wired at M7.3.
3. **Expected and actual type names** as 32-byte inline NUL-padded
   strings. Inline (not pointer-indirect) because the Diag record
   crosses a process boundary when the shell is talking to an LSP
   client over a UNIX-domain socket (R220.M9's planned transport),
   and we want no pointer-rewrite work on the far side.
4. A **suggestion** when the elaborator can derive one — a 32-byte
   inline NUL-padded string of the exact fix text (`parse(x)` to
   coerce a `str` to a `u64`; `wrap in \`Some\`` for an Option
   mismatch). Empty when none is derivable at raw M7; the M7.4 wire-up
   adds a `_dr_make_suggestion` helper that maps (code, expected,
   actual) triples to a suggestion string by table lookup.

R225.M7 lands the **record format + the two render surfaces + the
builder**. The suggestion-table and the queue head slot land at M7.1+.

## 2. Why a 128-byte flat record (not a pointer graph)

The alternative — a Diag struct of pointers into interned string
tables — would be smaller per record on the wire but requires every
consumer to understand the parser-tier's intern layout. In particular:

- **LSP transport.** The LSP client runs out-of-process (R220.M9).
  A pointer graph has to be serialised anyway; the flat record IS the
  serialisation, so there is no second format to maintain.
- **Session queue.** The M7.1 session-local diagnostic queue is a
  pointer-free pool indexed by `shl r, 7` (128-byte stride, power of
  two — no `imul`). A pointer graph would require per-session intern
  tables to live inside the queue's address space, defeating the
  queue's cross-session-reset guarantee.
- **Crash-safe dump.** On a hard refusal (`unreachable!` tripped),
  the kernel panic path can memcpy the last 16 diags out of the
  session's `.bss` queue into the kernel log without re-walking any
  pointer graph. 128B × 16 = 2 KiB, trivially within the kernel's
  panic-dump budget.
- **Novel-clean-design.** Haskell's `GHC.Hs.Dump` carries a tagged-
  union diagnostic that references source positions by `RealSrcSpan`
  which transitively references source buffers through a reader
  context. We adopt the opposite shape: span is byte-offset into a
  caller-supplied buffer (the Q-A5 invariant that span_map.pdx
  R221.M6 preserves across NFC); every string is inline; every record
  is self-contained.

The cost is per-record size (128 bytes vs ~40 for a pointer graph),
which at 128 diags/session is 16 KiB — well within the user-space
`.bss` budget the parser-tier already spends on `_h_rows` (R229.M5,
16 KiB).

## 3. Record wire format (128 bytes exactly)

| Offset | Field | Size | Notes |
| --- | --- | --- | --- |
| `0x00` | `magic` | u32 | `'DIAG'` LE = `0x47414944`. Discriminates against raw bytes. |
| `0x04` | `code` | u16 | E-number. E.g. `0x5810` = E0980_RANK_TOO_HIGH. |
| `0x06` | `severity` | u16 | 0=ERROR, 1=WARNING, 2=INFO, 3=HINT. LSP severity = +1. |
| `0x08` | `primary_src_offset` | u32 | Into caller's source buffer (Q-A5, not NFC-form). |
| `0x0C` | `primary_src_length` | u32 |  |
| `0x10` | `secondary_src_offset` | u32 | 0 at raw M7; set by `_dr_set_secondary` at M7.3. |
| `0x14` | `secondary_src_length` | u32 |  |
| `0x18` | `expected_type_name` | u8[32] | NUL-padded; render stops at first NUL. |
| `0x38` | `actual_type_name` | u8[32] | Same shape. |
| `0x58` | `suggestion_inline` | u8[32] | Empty (first byte NUL) = no suggestion clause. |
| `0x78` | `next_diag_ref` | u64 | 0 at raw M7; M7.1 queue link field. |

**Stride = 128 = `shl r, 7`.** A session queue of N diags addresses
slot `i` at `base + i << 7`. The 32-byte inline strings mirror the
R225.M1 TypeNode / R225.M2 ROW_EXT / R221.M4 Token record discipline
(fixed-size inline fields; never pointer indirection unless the
semantics require it).

**NUL-pad convention.** Each 32-byte string field holds a NUL-
padded C-style string. The render functions stop at the first NUL
byte on emit; a field with first byte NUL contributes nothing to the
rendered output (e.g. an empty `suggestion_inline` omits the entire
`; hint: ...` clause).

**Why bit-level field offsets.** The 128-byte record is poured through
process boundaries and goldened against `tests/goldens/diag/*.bin`
files at M7.5. Every field offset is one of {0, 4, 6, 8, 12, 16, 20,
24, 56, 88, 120} — all fit disp8 for the `mov_d [reg + imm]` /
`mov_b [reg + imm]` byte-level encoding. No `[reg + reg + imm]`
chained displacements (encoder discipline).

## 4. Severity axis + LSP mapping

Our severity axis matches the four-level diagnostic lattice:

| Our | Name | Semantics |
| --- | --- | --- |
| 0 | ERROR | Hard refusal; the elaborator cannot proceed. |
| 1 | WARNING | Non-fatal; the elaborator continues with a defensive default. |
| 2 | INFO | Explanatory annotation (e.g. "generalised to `∀a. a → a`"). |
| 3 | HINT | Mechanical suggestion the user might want to apply. |

The LSP 3.17 `Diagnostic.severity` axis uses 1-based values: 1=Error,
2=Warning, 3=Info, 4=Hint. The LSP renderer emits `severity = our + 1`.

## 5. Status band 0x5B00..0x5BFF

Carved on a kilo-step boundary past Wave 129's R229.M8 MultiLine
(0x5A00..0x5AFF). Grep-confirmed virgin at R225.M7 landing time
(`grep -rE '0x5B[0-9A-F]{2}' tools/user/libpdx-pds-parser/` returns
no prior hits; the sole landed `0x5B00` reference is in
`src/user/aml/aml_lex.pdx` R30.M1-001 as the AML opcode anchor
`ExtOpPrefix | 0x00`, which is not a packed-status band and does not
collide here).

| Code | Name | Diagnostic family |
| --- | --- | --- |
| 0  | `DR_OK` | render / build success |
| `0x5B00` | `DR_ERR_BAD_INPUT` | `out == 0` or caller pointer null |
| `0x5B01` | `DR_ERR_OUT_TOO_SMALL` | `out_cap < DR_RECORD_BYTES` on build |
| `0x5B02` | `DR_ERR_BAD_RECORD` | magic mismatch or `record_len < 128` on render |
| `0x5B03` | `DR_ERR_BAD_SEVERITY` | severity > 3 on build |
| `0x5B04` | `DR_ERR_RENDER_OVERFLOW` | render output exceeds `out_cap` |

Slots `0x5B05..0x5BFF` reserved for M7.1+ follow-ups (queue-full,
secondary-span-OOB, suggestion-table-miss, byte-offset-overflow on
line/column resolve).

## 6. Public API

### 6.1 `_dr_init() -> ()`

Bare `ret`. Raw M7 holds NO `.bss` state (every Diag record is
caller-owned; the session-local diagnostic queue head slot lands at
M7.1). Kept for parallelism with the parser-family init-hook
convention (`_rc_init` R225.M6, `_st_init` R223.M7, `_lp_init`
R224.M7, `_ha_init` R223.M6, `_ws_init` R223.M5, `_ds_init`
R222.M8, `_dm_init` R222.M6, `_cmdreg_init` R222.M5).

### 6.2 `_dr_build(code_sev, primary_off, primary_len, strings_ptr, out, out_cap)`

Populate a 128-byte Diag record at `out`.

| Reg | Name | Semantics |
| --- | --- | --- |
| rdi | `code_sev` | `(severity << 16) \| (code & 0xFFFF)` |
| rsi | `primary_off` | u32 byte offset into caller's source buffer |
| rdx | `primary_len` | u32 byte length of the primary span |
| rcx | `strings_ptr` | NULLable; else points at a 96-byte triple expected[32] + actual[32] + suggestion[32] |
| r8  | `out` | 128-byte destination buffer |
| r9  | `out_cap` | caller buffer capacity (must be >= 128) |

Returns `(DR_RECORD_BYTES << 32) | status` in `rax`.

**Why packed `code_sev`.** paideia-as's SysV x64 unsafe-body lambda
caps register-passed args at 6 (per
`tools/paideia-as/tests/build-emit/sysv_x64_7arg_unsafe_body_b1708.pdx`
and `design/compiler/lambda-arity-stack-spill.md` §4.4/§11: an unsafe
body suppresses the frame-pointer prologue that stack-passed args
would be read back through at `[rbp + N]`, so an unsafe-bodied lambda
with > 6 args is refused with B1708). The literal brief signature
`(code, severity, primary_off, primary_len, expected_ptr,
actual_ptr, suggestion_ptr, out, out_cap)` is 9 args. We pack code
and severity into one u64 (3 bits of severity + 16 bits of code; the
severity field inside the record is still u16) and bundle the three
32-byte string buffers into one `strings_ptr → [expected|actual|
suggestion]` triple. No field is lost; the caller fills the triple
with three memcpy's from the elaborator's intern tables and the
result is identical to passing them separately. The triple's byte
offsets are deterministic: `expected = +0`, `actual = +32`,
`suggestion = +64` — the record's own offsets at `+24`, `+56`, `+88`
differ because the record carries header fields before the strings.

**Zero-fill before populate.** `_dr_build` zero-fills all 128 bytes
before writing the specific fields. This guarantees `secondary_*`
and `next_diag_ref` default to 0 and the three string fields default
to all-NUL when `strings_ptr == 0`.

Pure leaf — zero callee-save pushes; no stack frame; no nested CALL.
The 96-byte strings copy is inlined as a byte-count loop over the
caller's buffer rather than a CALL into `_dr_h_emit_lit` so the
builder stays pure-leaf.

### 6.3 `_dr_render_lsp(record_ptr, record_len, out, out_cap)`

Serialize to one-line LSP-compatible JSON:

```json
{"range":{"start":{"line":0,"character":<N>},"end":{"line":0,
 "character":<N>}},"severity":<N>,"code":"E<hex4>",
 "message":"expected <exp>, got <act>; hint: <sug>"}
```

- `line` is always `0` at raw M7; M7.2 wires the UTF-8-aware
  byte-offset → line/column resolver and refines both start and end
  positions.
- `character` is the byte offset (start) or byte offset + length
  (end). The LSP spec is ambiguous on byte-vs-character offset
  interpretation; our byte-level emission is self-consistent and
  M7.2's wire-up refines to character offsets per LSP position
  semantics (specifically PositionEncodingKind.UTF16 or UTF8 per
  server negotiation).
- `severity` is `our + 1` (0..3 → 1..4).
- `code` is JSON-string-encoded `"E<hex4>"` rather than integer-
  encoded because LSP 3.17's `Diagnostic.code` accepts
  `integer | string` and the hex form groups directly with the
  band carved in `caps.decl`.
- Suggestion clause (` ; hint: ...`) is omitted when
  `suggestion_inline[0] == NUL`.

Returns `(bytes_written << 32) | status` in `rax`.

Register plan: 6 callee-save pushes (rbx/rbp/r12/r13/r14/r15 = 48 B) + `sub rsp, 8`;
entry rsp%16==8 → after prologue rsp%16==0 at every nested CALL
(into `_dr_h_emit_lit` / `_dr_h_emit_u16_hex` / `_dr_h_emit_u32_dec`
/ `_dr_h_emit_cstr`). r12 holds `out_cap` (immutable across calls);
r13 holds the cursor (updated after every emit).

### 6.4 `_dr_render_human(record_ptr, record_len, out, out_cap)`

Serialize to a compact single-line human form:

```
E<hex4> <SEV> at <dec_off>+<dec_len>: expected <exp>, got <act> (hint: <sug>)
```

- `<SEV>` is one of `ERR` / `WARN` / `INFO` / `HINT` (looked up in
  `_dr_sev_names` 4-byte stride).
- Hint clause omitted when `suggestion_inline[0] == NUL`.

Returns `(bytes_written << 32) | status` in `rax`.

Register plan: identical to `_dr_render_lsp`.

## 7. Internal helpers (module-private pure leaves)

```
_dr_h_emit_lit(src, src_len, out, out_cap, pos) -> new_pos
_dr_h_emit_cstr(src, max_bytes, out, out_cap, pos) -> new_pos
_dr_h_emit_u16_hex(value, out, out_cap, pos) -> new_pos
_dr_h_emit_u32_dec(value, out, out_cap, pos) -> new_pos
```

All four are pure leaves with 4–5 register args. Each returns the
new cursor position or the **sticky overflow sentinel** `out_cap + 1`
on buffer overflow. The sentinel is sticky because every subsequent
emit's probe `pos + width > out_cap` fires on the inflated `pos`.
The caller checks `cursor > out_cap` once at the end rather than
per-emit.

**Decimal emitter.** `_dr_h_emit_u32_dec` uses a greedy-subtraction
loop over the 10-entry `_dr_pow10` table (10^0 .. 10^9). For each
power, it iterates `while value >= pow: value -= pow; digit += 1`
and emits the digit when `digit > 0 OR already_emitted`. Zero emits a
single `'0'`. Max 10 digits for the u32 range (0..4_294_967_295).
Worst-case cost: 10 × 9 = 90 subtractions. The pdx `.pdx` dialect
does not expose `IDIV` / `MUL`, so greedy subtraction is the
canonical shape (vs. magic-constant multiplication, which would
need 128-bit `MUL` or `MULX`).

**Hex emitter.** `_dr_h_emit_u16_hex` writes exactly 4 nibbles
(uppercase 0-9A-F) by shifting the value right by 12 / 8 / 4 / 0 and
masking with 0xF, then indexing `_dr_hex_digits`.

**No chained displacements** anywhere; every address is computed
into a dedicated register (`mov; shl; add`) before the load/store.

## 8. Acceptance — 60-error test corpus

The acceptance corpus (filed as M7.5) enumerates 60 Diag records
across every landed error family. Each goldens two forms: the raw
128-byte record binary and the two rendered strings (LSP + human).

### 8.1 HM core (R225.M1) — 15 cases

1. `E2D00_OCCURS` on `λx. x x` — occurs-check fail.
2. `E2D01_MISMATCH` constructor on `u64` vs `str`.
3. `E2D01_MISMATCH` arity on `fn (u64 → u64)` vs `fn (u64 → u64 → u64)`.
4. `E2D02_POOL_FULL` on a 130-node graph.
5. `E2D03_OUT_TOO_SMALL` on scheme generalise overflowing out_cap.
6. HM mismatch with suggestion `parse(x)` for str → u64.
7. HM mismatch with suggestion `.to_string()` for u64 → str.
8. HM mismatch on nested TyApp (currying).
9. HM mismatch with empty suggestion.
10. HM mismatch with primary span at byte 0 (BOF).
11. HM mismatch with primary_len = 0 (defensive).
12. HM mismatch spanning a multi-byte UTF-8 cluster (`café`).
13. HM mismatch across a NFC composition boundary (`á` precomposed).
14. HM mismatch with 10-digit primary_off (near-u32-max).
15. HM mismatch with max-length expected + actual names (31 bytes each).

### 8.2 Row types (R225.M2) — 10 cases

16. `E3600_LABEL_DUP` on `{name: str, name: u64}`.
17. `E3601_LABEL_ABSENT` on project `{name}` from `{age}`.
18. `E3602_ROW_CYCLE` on self-referential row-var.
19. Row-restrict with suggestion `remove the duplicate field`.
20. Row-select with suggestion `use \`.name\` after \`select name\``.
21–25. Mixed row shapes crossing arity.

### 8.3 Effect unify (R225.M4) — 8 cases

26–33. Effect-row shape failures across `_eu_check_rank` + the
E0710..E0713 family. One case per `EU_ERR_*` slot.

### 8.4 Rank check (R225.M6) — 8 cases

34. `E0980_RANK_TOO_HIGH` on a nested-quantifier body node.
35. `E0981_NESTED_FORALL` on a root quantifier body node.
36. `RC_ERR_BAD_SCHEME` on scheme_len < 8.
37–41. Variants with different scheme byte-widths.

### 8.5 Capability row (R224.M4) — 6 cases

42–47. `E0820_MISSING_CAP` across the 10 primitive cap labels.

### 8.6 Session type (R223.M7) — 4 cases

48–51. E0710..E0713 one each.

### 8.7 Severity + render robustness — 9 cases

52. WARNING-severity record (sev=1).
53. INFO-severity record (sev=2).
54. HINT-severity record (sev=3).
55. Record with suggestion_inline empty (hint clause omitted).
56. Record with expected empty (expected `<nothing>` → suggestion
    emphasises the actual: "found str but no annotation at the
    binding").
57. Record with actual empty (actual `<nothing>` → suggestion
    emphasises the expected: "expected u64; got the empty
    pipeline").
58. Record with all three strings empty (minimum-length render).
59. LSP render output = 480 bytes (longest realistic case).
60. Human render output = 190 bytes.

Each case is a byte-for-byte golden under
`tests/goldens/diag/<case_id>.bin` + `.lsp.json` + `.human.txt`.
The property test harness lands at M7.5 (filed in R225.M9's shared
proptest harness, mirroring the R225.M1-003 / M2-003 / M4-003
deferrals).

## 9. Dependencies

### 9.1 Intra-library

Raw M7 has **no** intra-library cross-module linker reference. The
Diag record format is intentionally decoupled from the HmCore type
representation — the caller passes already-rendered 32-byte type
names, not pool indices. This decoupling lets the HM elaborator cache
rendered names across repeated instantiations of the same scheme
without touching the Diag path.

Forward-path intra-library edges (filed under M7.1+):

- M7.1: `.bss` queue head slot (zero cross-module).
- M7.2: `_dr_byte_offset_to_line_column(src_ptr, src_len, byte_off)`
  — pure byte walker over the source buffer; still no cross-module
  edge.
- M7.4: `_dr_make_suggestion(code, expected_ptr, actual_ptr, out,
  out_cap)` — adds a suggestion-table that mirrors the status-band
  carve-out: codes `0x2D01` → `parse(x)` / `.to_string()` /
  `wrap in Some`; codes `0x5810` → `annotate at the function
  boundary`; etc. The table lives in `_dr_suggestion_table`
  (.rodata) and does NOT cross a module boundary.

### 9.2 Cross-library

**None at raw M7.** The module is a self-contained byte emitter + a
self-contained record validator; it carries no `consumed_kinds` and
touches no external library's `.bss`.

Forward-path cross-library edges:

- M7.6: kernel-side wire-up at the REPL dispatch tier reads
  `_dr_render_human` for the terminal lane and `_dr_render_lsp` for
  the LSP transport lane. The kernel does not know this library's
  internal record layout; it only invokes the two render functions
  and copies the bytes they return out to the appropriate IPC
  endpoint. One-way dependency with no shared `.bss`.

## 10. Encoder discipline

Standard parser-tier discipline. No `test r,r`; no `and r, imm64`
(all masks fit imm32); no 2-op `imul r, imm` (strides are
`shl r, 7` for records, `shl r, 5` for 32-byte strings, `shl r, 2`
for u32 arrays, `shl r, 1` for u16); no multiline `pub let = "..."`;
module basename `DiagReport` matches `diag_report.pdx`; labels
prefixed `dr_` for the public entries and `dr_h_` for the helpers
(grep-confirmed disjoint from every landed parser-tier module).

**Chained displacements.** None. Every three-term address
(`base + idx * stride + disp`) is pre-computed into a dedicated
register via `mov; shl; add` before the memory operand consumes it.
Loads use `[reg + disp]` or `[base + idx]` (two-register form, no
displacement).

**Register-liveness.** `_dr_init` is bare `ret`. `_dr_build` is a
pure leaf (zero callee-save pushes; no stack frame; the 128-byte
zero-fill is 16 unrolled u64 stores, the 96-byte copy is a byte-count
loop — zero CALL). The two render entries push rbx/rbp/r12/r13/r14/
r15 (6 × 8 = 48 B, leaving rsp%16==8) and add `sub rsp, 8` to land at
rsp%16==0 after prologue (Wave 130 debugger fix) — all nested CALLs into the four helpers see
aligned stack per SysV. The four helpers are pure leaves (zero push,
zero CALL); their internal scratch is confined to the caller-save
set (rax/r9/r10/r11).

**r11 across CALLs.** r11 is caller-save under SysV and clobbered
by every nested CALL. In `_dr_render_human` and `_dr_render_lsp`,
r11 is used only AFTER the prologue and NEVER held across a CALL —
every per-emit scratch value lives in r14 or r15 (callee-save) or
is recomputed from `rbx` (record_ptr).

**Status-code immediate safety.** All status codes `0x5B00..0x5B04`
have bit 31 clear and encode as direct `mov r64, imm32` with sign-
extension safety (positive values). The magic `0x47414944` likewise
has bit 31 clear.

## 11. Forward path

- **M7.1** — session-local `.bss` queue (128 slots × 128 B = 16 KiB
  ring) + `_dr_push_queue(record_ptr)` + `_dr_drain_queue(out,
  out_cap, max_count)` + queue-head/next scalars.
- **M7.2** — `_dr_byte_offset_to_line_column(src_ptr, src_len,
  byte_off) -> packed(line_u32, col_u32)` — UTF-8-aware line / column
  resolver; `_dr_render_lsp` reads this and refines the `line` and
  `character` fields.
- **M7.3** — `_dr_set_secondary(record, off, len)` patcher.
- **M7.4** — `_dr_make_suggestion(code, expected_ptr, actual_ptr,
  out, out_cap)` — code-indexed suggestion table.
- **M7.5** — 60-error acceptance corpus + goldens.
- **M7.6** — kernel-side wire-up at the REPL dispatch tier
  (R229.M3-dispatch slot).
- **M7.7** — LSP transport side (lives in the R220.M9 LSP-embed
  work; this module stays decoupled through the `_dr_render_lsp`
  interface).

## 12. Related docs

- `design/shell/span-map-nfc.md` — R221.M6 SpanMap preserves the
  Q-A5 byte-offset invariant across NFC. The Diag record stores
  byte offsets into the SOURCE buffer, not the NFC-form buffer;
  callers compose `_dr_build` with `_sm_lookup` to translate.
- `design/shell/hm-algorithm-w-core.md` — R225.M1 HmCore error-code
  taxonomy (0x2D00..0x2DFF band) that supplies the `code` field.
- `design/shell/rank-restricted-polymorphism.md` — R225.M6
  RankCheck E0980 / E0981 diagnostic family (0x5810 / 0x5811).
- `design/shell/effect-row-unification.md` — R225.M4 EffectUnify
  E0710..E0713 family (0x4900..0x490F sub-slots).
- `design/shell/capability-row-typing.md` — R224.M4 CapRow
  E0820_MISSING_CAP family.
- `design/shell/session-typed-edges.md` — R223.M7 SessionType
  E0710..E0713 family.
- `design/terminal/semantic-shell-language-plan.md` §R225.M7 for the
  umbrella-level anchor.

## 13. ABI freeze

The 128-byte record wire format is **frozen** at R225.M7 landing.
Future M7.x landings MAY only:

- Populate currently-zero fields (secondary span, next_diag_ref,
  suggestion_inline).
- Add new status codes under `0x5B05..0x5BFF`.
- Add new render surfaces (new entries beside `_dr_render_lsp` /
  `_dr_render_human`).
- Refine the render output STRING shape, PROVIDED the LSP consumer
  can accept the refined shape (e.g. a non-zero `line` field in M7.2
  is accepted by every conformant LSP client).

Future M7.x landings MAY NOT:

- Move the magic field.
- Change severity encoding.
- Change record size.
- Change inline string widths.
- Add fields past offset 120 (the record ends at byte 127; byte 128
  and beyond are a NEW record if any).
