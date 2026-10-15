# Unified AST sum type (R221.M5)

Upstream: paideia-os#2485 (R221 parser-tier Unicode + lexer umbrella),
paideia-os#2655 (R221.M5 THIS landing). Substrate:

- `tools/user/libpdx-pds-parser/src/utf8_nfc.pdx` (R221.M1 — NFC input).
- `tools/user/libpdx-pds-parser/src/ctx_lexer.pdx` (R221.M4 —
  context-tagged 16-byte Token stream).
- `tools/user/libpdx-pds-parser/src/pipeline.pdx` (R223.M1 —
  pipeline-stage descriptor emitter).
- `tools/user/libpdx-pds-parser/src/datalog.pdx` (R226.M1 — datalog
  clause-record emitter).
- `tools/user/libpdx-pds-parser/src/lambda_lit.pdx` (R224.M1 — lambda
  header / param-list emitter).

Consumers (post-M5):

- R225.M3+ typechecker — walks the AST to issue HM constraints,
  reading `kind`, `payload_u32`, `child_ref` and `extra_ref`.
- R229.M3-dispatch REPL dispatch — reads the pipeline-root subtree
  to route commands, routes lambda nodes through the evaluator.
- R221.M6 span-mapping NFC — refines `src_offset`/`src_length` to a
  pre-NFC byte stream so error diagnostics quote the user's original
  input.
- R221.M7 parser fuzz corpus — exercises `_ast_render` for byte-
  identical round-trip on the 100-sample acceptance anchor.

## 1. Why

The three pds-lang sub-languages (pipeline, datalog, lambda) all
share an identifier / literal / punctuator surface and only diverge
at a handful of production rules (per R221.M4 §1). Keeping three
disjoint AST types across the shell would duplicate 90% of the
semantic surface — identifier equivalence, span bookkeeping, child
walking, type-pool wiring — and would require every downstream pass
(typecheck, evaluator, LSP) to dispatch three times.

R221.M5 lands ONE `SyntaxNode` sum type that spans:

- pipeline stages (`ls | wc`) → `AST_SK_PIPELINE_ROOT` + child
  `AST_SK_STAGE` + `AST_SK_PIPE`.
- datalog clauses (`parent(X,Y) :- father(X,Y)`) → `AST_SK_RULE`
  with `AST_SK_RULE_HEAD` + `AST_SK_RULE_BODY` children.
- lambda literals (`{ |x| x+1 }`) → `AST_SK_LAMBDA` with
  `AST_SK_PARAM` + `AST_SK_BODY` children; closure-captures,
  effect-rows, and capability-rows get their own `AST_SK_*`
  siblings.
- record literals / projections → `AST_SK_RECORD` + `AST_SK_FIELD`.
- scalar literals → `AST_SK_LIT_INT`, `AST_SK_LIT_STR`, etc.

Every node carries a 32-byte record so downstream passes dispatch on
`kind` once and walk `child_ref` / `extra_ref` with a single
addressing form.

## 2. Record layout (32 B)

```
offset  size  field
------  ----  ---------------------------------
 0x00    2    kind         u16   (AST_SK_* code)
 0x02    2    flags        u16   (reserved; 0 at M5)
 0x04    4    src_offset   u32   (Q-A5 source span start)
 0x08    4    src_length   u32   (Q-A5 source span length)
 0x0C    4    payload_u32  u32   (small literal OR child count)
 0x10    8    child_ref    u64   (pool_idx of first child; 0 = leaf)
 0x18    8    extra_ref    u64   (type-tagged aux; 0 at alloc)
```

The 32-byte stride matches `shl r, 5` for slot addressing (power of
two). Sibling modules use 16 B / `shl r, 4`; R221.M5 doubles the
stride because the AST node needs two u64 refs AND a 2×u32 span AND
a u32 payload AND the u16 kind + flags — none of which fit a 16-byte
slot. `_ast_render`'s span-copy loop reads `src_offset` and
`src_length` as two u32 loads (`xor rN,rN; mov_d rN,[node+disp]`).

### Field semantics

- **kind**: SyntaxKind code (see §3). Written at `_ast_alloc` time.
- **flags**: reserved u16; the Q-A5 "synthetic span" bit (bit 0)
  marks nodes whose span was reconstructed rather than copied
  verbatim from the lexer; a renderer-override bit (bit 1) selects
  an alternate pretty-print rule at R129.M5+. Unused at M5.
- **src_offset / src_length**: Q-A5 invariant — EVERY node has one.
  A diagnostic can point at `[src_offset, src_offset+src_length)`
  of the original caller-supplied source bytes without walking the
  parent chain.
- **payload_u32**: small-literal inline slot. For `AST_SK_LIT_INT`
  it carries the parsed integer (if ≤ 2^32-1); for `AST_SK_LIT_BOOL`
  it carries 0/1; for a composite node it may hold a child count.
- **child_ref**: pool_idx of the first child (0 = leaf). Sibling
  walk goes via each child's `extra_ref` (low 32 = next-sibling
  pool_idx). This matches the linked-list traversal pattern that
  `pipeline.pdx` and `datalog.pdx` already emit over their flat
  descriptor arrays.
- **extra_ref**: type-tagged auxiliary pointer. Interpretation is
  `kind`-dependent (type-pool pool_idx for Lit/Ident, next-sibling
  pool_idx for list nodes, hash index for Record).

## 3. SyntaxKind enum

Four-nibble layout: top 8 bits = FAMILY, low 8 bits = SUBKIND.

```
0x0100..0x01FF  pipeline family
  AST_SK_PIPELINE_ROOT   = 0x0100
  AST_SK_STAGE           = 0x0101
  AST_SK_PIPE            = 0x0102
  AST_SK_REDIRECT        = 0x0103
  AST_SK_HOSTNAME_ANNOT  = 0x0104

0x0200..0x02FF  datalog family
  AST_SK_DATALOG_BLOCK   = 0x0200
  AST_SK_FACT            = 0x0201
  AST_SK_RULE            = 0x0202
  AST_SK_ATOM            = 0x0203
  AST_SK_GOAL            = 0x0204
  AST_SK_RULE_HEAD       = 0x0205
  AST_SK_RULE_BODY       = 0x0206

0x0300..0x03FF  lambda family
  AST_SK_LAMBDA          = 0x0300
  AST_SK_PARAM           = 0x0301
  AST_SK_BODY            = 0x0302
  AST_SK_LET             = 0x0303
  AST_SK_LET_REC         = 0x0304
  AST_SK_CAPTURE_LIST    = 0x0305
  AST_SK_EFFECT_ROW      = 0x0306
  AST_SK_CAP_ROW         = 0x0307

0x0400..0x04FF  record family
  AST_SK_RECORD          = 0x0400
  AST_SK_FIELD           = 0x0401
  AST_SK_FIELD_SELECTOR  = 0x0402

0x0500..0x05FF  literal family
  AST_SK_LIT_INT         = 0x0500
  AST_SK_LIT_STR         = 0x0501
  AST_SK_LIT_BOOL        = 0x0502
  AST_SK_LIT_PATH        = 0x0503
  AST_SK_LIT_HASH32      = 0x0504
  AST_SK_IDENT           = 0x0505
```

Reserved for M6+:

```
0x0600..0x06FF  diagnostics  (ERROR, MISSING)
0x0700..0x07FF  module/import  (MODULE, IMPORT, USE)
0x0800..0x08FF  type expressions  (TYARG, TYAPP, TYROW)
```

Families carved on kilo-step boundaries so a downstream dispatcher
can discriminate at a glance via `shr r, 8; cmp r, imm8`.

## 4. Pool + allocation

The AST node pool is a SINGLETON 8 KiB `.bss` byte array (256 slots
of 32 B). Pool_idx 0 is reserved as the "nil" sentinel: a 0 return
from `_ast_alloc` signals pool exhaustion; a 0 `child_ref` /
`extra_ref` means "no reference". Valid handles are 1..255.

```
pub let mut _ast_node_pool : [u8; 8192] = uninit @align(8)
pub let mut _ast_pool_next : u64        = uninit @align(8)
pub let mut _ast_src_ptr   : u64        = uninit @align(8)
pub let mut _ast_src_len   : u64        = uninit @align(8)
```

A bump pointer `_ast_pool_next` tracks the next available slot.
`_ast_init` resets it to 0; the allocator inlines a lazy-check so a
zero sentinel bumps to 1 on first use (skip reserved idx 0;
precedent: `_rt_alloc_node` in `row_types.pdx`).

### Reset between parses

Callers hard-reset via `_ast_init` (which zeroes `pool_next`,
`src_ptr`, `src_len`). The previously-allocated SyntaxNode records
remain in the backing byte array but become unreachable because
every valid handle must satisfy `node_ref < _ast_pool_next`; a stale
handle fails this check and becomes a silent no-op in the setters,
`AST_ERR_BAD_REF` in `_ast_render`.

For the acceptance test's 100-sample loop:

1. `_ast_init()`
2. `_ast_set_source(input_bytes_ptr, input_bytes_len)`
3. Build the AST via `_ast_alloc` + `_ast_set_*`.
4. `_ast_render(root_node_ref, out, out_cap)` → verify bytes-identical.
5. Loop to step 1 for the next input.

The pool is thus LOCAL to one input and the fuzz corpus never races
two parses against the same singleton — a serial loop is sufficient
at M5. A future M6+ landing may wire per-session pool arrays if the
LSP bridge wants concurrent AST walks.

## 5. Round-trip strategy  (Q-A5 acceptance anchor)

Every node carries its EXACT source span `[src_offset, src_offset +
src_length)`. `_ast_render` emits the N bytes at
`_ast_src_ptr + src_offset` verbatim.

For the acceptance test:

```
input:  "ls | wc"
AST:
  root  = _ast_alloc(AST_SK_PIPELINE_ROOT, 0, 7)
          .child_ref = stage1_ref
  stage1 = _ast_alloc(AST_SK_STAGE, 0, 2)   // "ls"
  pipe   = _ast_alloc(AST_SK_PIPE, 3, 1)    // "|"
  stage2 = _ast_alloc(AST_SK_STAGE, 5, 2)   // "wc"
  // Set sibling links via extra_ref (parser-side convention):
  _ast_set_extra_ref(stage1_ref, pipe_ref)
  _ast_set_extra_ref(pipe_ref,   stage2_ref)

_ast_render(root, out, 7)
  -> packed_u64 = (7 << 32) | AST_OK
  -> out[0..7] == "ls | wc"  (byte-identical)
```

The ROOT's span covers `[0, input_len)`, so `_ast_render(root, ...)`
is a straight span-copy of the whole input — trivially byte-identical.
A child-aware render that walks `child_ref` and concatenates child
spans is architecturally compatible with the same ABI: the walker
short-circuits on composite nodes and only copies spans at leaves.
M5 lands the simpler span-copy variant; a follow-up M (deferred to
R221.M5.1) may extend `_ast_render` to walk `child_ref` chains for
sub-tree pretty-print; the ABI stays frozen.

## 6. Public API

```
_ast_init()                                   -> ()
_ast_set_source(bytes_ptr: u64, bytes_len: u64) -> ()
_ast_alloc(kind: u64, src_offset: u64, src_length: u64) -> node_ref: u64
_ast_set_payload_u32(node_ref: u64, payload: u64) -> ()
_ast_set_child_ref(node_ref: u64, child_array_ref: u64) -> ()
_ast_set_extra_ref(node_ref: u64, extra_ref: u64) -> ()
_ast_render(node_ref: u64, out: u64, out_cap: u64) -> packed_u64
```

Register maps (SysV): see `src/ast.pdx` section 4+. All seven are
PURE LEAVES (zero callee-save pushes, zero stack frames, zero
nested CALLs). The allocator inlines the lazy-init to avoid an
alignment-math prologue around a `_ast_init` call.

Setter error discipline: `_ast_set_payload_u32` / `_ast_set_child_ref`
/ `_ast_set_extra_ref` validate `node_ref` is in `[1,
_ast_pool_next)` and silently no-op on out-of-range. The void
return has no error-code surface; the caller is expected to pass the
handle it just received from `_ast_alloc`, which the module trusts.

## 7. Error band `0x4400..0x44FF`

```
AST_OK                 : 0
AST_ERR_POOL_FULL      : 0x4400   _ast_alloc: _ast_pool_next >= 256.
AST_ERR_BAD_REF        : 0x4401   _ast_render: node_ref == 0 or
                                  node_ref >= _ast_pool_next.
AST_ERR_BAD_KIND       : 0x4402   reserved for M5.1+ kind-table
                                  enforcement (M5 trusts caller).
AST_ERR_OUT_TOO_SMALL  : 0x4403   _ast_render: out_cap < src_length.
AST_ERR_SPAN_OOB       : 0x4404   _ast_render: src_offset +
                                  src_length > _ast_src_len.
AST_ERR_NO_SOURCE      : 0x4405   _ast_render: _ast_src_ptr == 0.
```

Band carved on a new kilo-step boundary past R224.M4 CapRow
(`0x4300..0x43FF`). Slots `0x4406..0x44FF` reserved for M5.1+
follow-ups: kind-table enforcement (`AST_ERR_BAD_KIND`), cycle-
detect on `child_ref` walks, synthetic-span discipline, child-aware
render diagnostics.

Disjoint from every other R221 submodule band:

- R221.M1 (`utf8_nfc`)   `0x2700..0x27FF`
- R221.M2 (`grapheme_iter`) `0x3800..0x38FF`
- R221.M3 (`width_pass`) `0x3F00..0x3FFF`
- R221.M4 (`ctx_lexer`)  `0x4200..0x42FF`

The five R221 submodules do not share status codes because a
downstream dispatcher's compound error path must distinguish "the
decoder faulted" from "the cluster iterator faulted" from "the
width pass faulted" from "the context-tracking lexer faulted" from
"the AST allocator / renderer faulted".

## 8. paideia-as encoder discipline

- No `test rN, rN` — every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64` — all masks are imm8 / imm32.
- No 2-op `imul r, imm` — 32-byte stride is `shl r, 5`.
- No multiline `pub let = "..."` — single-line justifications.
- Module basename `Ast` matches `ast.pdx`.
- Labels prefixed `ast_` with per-function suffix (`ast_i_`,
  `ast_ss_`, `ast_al_`, `ast_sp_`, `ast_sc_`, `ast_se_`, `ast_r_`);
  disjoint from every sibling parser-tier module's label namespace
  and from paideia-as reserved keywords (`loop`, `if`, `let`, `fn`,
  `ret`, `done`).
- All `cmp reg, imm` immediates (0, 1, 256, 0x4400..0x4405) fit
  imm32 and are sign-safe (bit 31 clear).
- Byte loads via `xor rax, rax; mov_b rax, [base + idx * 1]`.
- u32 stores via `mov_d`; u32 loads via `xor rN,rN; mov_d rN,[addr]`.
- u16 stores via two `mov_b` byte stores (low, high via `shr 8`).
- u64 stores via plain `mov [base + disp], reg`.
- All public entry points are PURE LEAVES — zero callee-save pushes,
  zero stack frames, zero nested CALLs. The allocator inlines the
  lazy-init rather than calling `_ast_init`; precedent is
  `_rt_alloc_node` in `row_types.pdx`.
- No chained-displacement operands `[reg + a + b]` — every address
  is `[reg + disp]` or `[reg + idx * 1]` (Wave 120+121 lesson).

## 9. Fixture scenarios (M5 acceptance anchor subset)

The acceptance test enumerates 100 pds-lang inputs that each
round-trip through parse → render. A sampling of ten:

```
#   input                                   kind path
1   ls                                      PIPELINE_ROOT -> STAGE
2   ls | wc                                 PIPELINE_ROOT -> STAGE PIPE STAGE
3   ls > out.txt                            PIPELINE_ROOT -> STAGE REDIRECT
4   datalog { fact(42). }                   PIPELINE_ROOT -> DATALOG_BLOCK -> FACT
5   datalog { p(X,Y) :- q(X,Y). }           PIPELINE_ROOT -> DATALOG_BLOCK -> RULE
6   datalog { ?- parent(X,alice). }         PIPELINE_ROOT -> DATALOG_BLOCK -> GOAL
7   { |x| x }                               PIPELINE_ROOT -> LAMBDA -> PARAM, BODY
8   { |x: u64| x + 1 }                      PIPELINE_ROOT -> LAMBDA -> PARAM(u64), BODY
9   { |x| x } !{io} @{filesystem}           PIPELINE_ROOT -> LAMBDA -> ..., EFFECT_ROW, CAP_ROW
10  { name: "alice", age: 42 }              PIPELINE_ROOT -> RECORD -> FIELD, FIELD
```

Each case:

1. Call `_ast_init()`.
2. Call `_ast_set_source(input, input_len)`.
3. Allocate a `PIPELINE_ROOT` with span `[0, input_len)`.
4. Allocate subtree nodes with correct spans; link via
   `_ast_set_child_ref` and `_ast_set_extra_ref`.
5. Call `_ast_render(root, out, out_cap)`.
6. Assert `out[0..input_len] == input[0..input_len]` and
   `(rax >> 32) == input_len` and `(rax & 0xFFFFFFFF) == 0`.

## 10. Forward path

- **R221.M5.1**: child-aware render (walk `child_ref`, concatenate
  child spans, optional separator injection for pretty-print).
- **R221.M5.2**: kind-table enforcement — `_ast_alloc` rejects
  unknown kinds with `AST_ERR_BAD_KIND`.
- **R221.M6**: span-mapping NFC — refine `src_offset` / `src_length`
  to pre-NFC byte addresses so diagnostics quote the user's original
  input (not the normaliser's output).
- **R221.M7**: parser fuzz corpus — the 100 sample anchor plus
  property-test harness (`tests/proptest_ast_roundtrip.pdx`).
- **R225.M3+**: typechecker walks `kind` + `child_ref`, writes HM
  pool_idx into `extra_ref` as a type-pool handle.
- **R229.M3-dispatch**: evaluator reads `kind == AST_SK_PIPELINE_ROOT`
  as the top-level entry, routes children into functor dispatch.

## 11. ABI freeze

The 32-byte record stride and the 7-field layout freeze AT this
landing. Follow-up Ms may ONLY:

- Reinterpret the `flags` u16 bits (reserved slots).
- Add new SyntaxKind codes within the already-reserved families
  (`0x0100..0x05FF`) or the reserved extension families
  (`0x0600..0x08FF`).
- Reinterpret the `payload_u32` slot per kind.
- Reinterpret the `extra_ref` u64 slot per kind.

Changing the record stride, moving a field, or renaming a public
API entry point requires a MAJOR version bump of `libpdx-pds-parser`
(2.0.0) and an explicit umbrella-level migration note. R221.M5 is
expected to carry this ABI across the whole R221..R229 wave.
