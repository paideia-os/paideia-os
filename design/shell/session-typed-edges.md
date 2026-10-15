# Session-typed edges for pipeline-lang stage graphs

Upstream: paideia-os#2672 (R223.M7, parser-tier primitive).
Umbrella: paideia-os#2487 (R223 pipeline-lang).
Module: `tools/user/libpdx-pds-parser/src/session_type.pdx`.
Status band: `0x5500..0x55FF`.
Status: landed Wave 128, 2026-10-15.

Related:
- `design/shell/pipeline-stage-parser.md` -- R223.M1 Pipeline stage parser.
- `design/shell/cmd-functor-schemas-sig.md` -- R222.M1 SchemasSig: the
  schema name universe this module hashes.
- `design/shell/effect-row-unification.md` -- R225.M4 EffectUnify:
  the effect-row counterpart of the schema-duality rule.
- `design/shell/row-types-remy.md` -- R225.M2 RowTypes: the Remy-style
  row lattice that pairs with the session-type lattice.

## 1. Scope and why this exists

R223.M1 (`pipeline.pdx`) lands the stage-level lexer. R223.M2
(`record_projection.pdx`) lands `select` / `project`. R223.M3
(`filter_op.pdx`) lands `where`. R223.M4 (`sort_group_reduce.pdx`)
lands the aggregation triple. R223.M5 (`wire_sink.pdx`) lands the
Cap'n Proto-ish wire frame. R223.M6 (`hostname_annot.pdx`) lands
`@hostname`. All six landings operate on records flowing through the
pipeline. None of them STATICALLY ENFORCES that a producer stage's
output schema matches what the consumer stage can receive.

R223.M7 (THIS doc) lands that enforcement. The intuition is the
standard session-type / pi-calculus duality rule: a sender's protocol
`!X; done` is dual to a receiver's protocol `?X; done` iff both halves
name the same schema `X` and both halves close. An edge
type-checks iff its two halves are duals of each other.

A pipeline edge therefore materialises as two 32-byte SessionType
records at parse time:

- Record A -- producer-side half, direction = PRODUCE (`!`), schema =
  producer-output-schema.
- Record B -- consumer-side half, direction = CONSUME (`?`), schema =
  consumer-input-schema.

The acceptance adversarial test (per issue #2672): ten pipelines each
wired with mismatched producer / consumer schemas across their edges
all fail type-check with the E0710 family of diagnostics.

## 2. Why session types and not a flat type-signature compare

A naive scheme stamps each stage with an output-record schema and a
next-stage input-record schema and at `|` runs `stage[i].out ==
stage[i+1].in` with a flat structural compare. That works today but
does not extend to the two directions the pipeline-lang roadmap
already names:

**(a) Multi-step protocols.** `find . @remote | sort by size | reduce
by group` is dual-closed over three edges today; the next-wave roadmap
adds `@remote` fan-out that opens a sub-protocol (`!send; ?ack;
!payload; done`) on each edge. A session type names an ORDERED
PROTOCOL that a flat compare can never capture because the compare
conflates "schema" with "whole protocol".

**(b) Direction encoding.** The user's semantic-shell plan has
`& reduce` running the reduce side as CONSUMER (receiving records) and
`| reduce` running it as PRODUCER (seeding its own records). A flat
schema compare cannot distinguish `!X` from `?X` -- both have schema
X but opposite direction. The session-type discipline makes the
direction the first classifier a check consults.

At raw M7 the protocol is a single step each side (`!X; done` on one
half, `?X; done` on the other) because the acceptance test targets
single-edge mismatch. Room for multi-step chaining via a trailing
far-pointer is reserved in `flags` bit 1 for a R223.M7.1+ follow-up.

## 3. Session-type lattice

The lattice at M7 has exactly two inhabitants per edge-half:

```
PRODUCE  (`!`)   direction byte 0
CONSUME  (`?`)   direction byte 1
```

Dual compute: `PRODUCE . dual = CONSUME`, `CONSUME . dual = PRODUCE`.

An edge `(a, b)` type-checks iff:

```
a.magic == 'SESS'
b.magic == 'SESS'
a.direction + b.direction == 1          (one PRODUCE, one CONSUME)
a.schema_tag_hash == b.schema_tag_hash
a.flags & CLOSED == CLOSED
b.flags & CLOSED == CLOSED
```

A violation of any clause reports the most-specific error:

```
magic drift (either half)       -> E0713  PROTOCOL_DRIFT (0x5513)
direction out of {0, 1}         -> E0713  PROTOCOL_DRIFT
directions equal                -> E0711  DIRECTION_MISMATCH (0x5511)
flag CLOSED missing             -> E0712  UNCLOSED_SESSION (0x5512)
schema_tag mismatch             -> E0710  SCHEMA_MISMATCH (0x5510)
```

Validation order is magic -> direction -> closed -> schema so the
E0713 drift error subsumes everything that could follow (a non-magic
record is not a SessionType).

### Why a 32-byte record and not a tagged union

A 32-byte stride matches every sibling R223 record (`PipelineStage`
is 64-byte; `HostAnnot` is 32-byte; `FilterRecord` is 32-byte). The
layout aligns the FNV hash on an 8-byte boundary and keeps enough
tail bytes (`schema_name_inline[16]`) for every schema name observed
in the semantic-shell language plan (`FileRec`, `Signal`, `TokenRec`,
`Entry`, `Record`, `Stat`, ...).

An M7.1+ multi-step extension carves a trailing u64 far-pointer in
the reserved `flags` bit 1 slot that points at a further SessionType
record; the chain terminates at the first record with `CLOSED` set.
The raw-M7 single-step shape is the chain-of-length-1 case.

### Why FNV-1a 64 for the schema tag

Byte-for-byte identical hash function across seven prior parser-tier
leaves (`_cmd_sig_fnv1a64`, `_fi_fnv1a64`, `_cmdreg_fnv1a64`,
`_ws_schema_hash`, inlined in `_ha_parse` and `_ha_check` and
`_h_append`). A schema name registered via R222.M2 CommandSig hashes
byte-identically here, so a cross-module edge-duality check consults
the pre-computed CommandSig hash without a byte-by-byte name compare.

Collision probability at a per-session catalogue of ~1,000 schemas is
`2^-33` (birthday approximation `1000^2 / 2^64`); a session that hits
a collision reports it via the registry's dedup pass at session boot
and the user retitles. The same cost model applies here as at R222.M5.

## 4. Wire record layout (32 B)

```
offset size  field                  type        notes
------ ----- ---------------------- ----------- --------------------------
 0x00    4   magic                  u32         'SESS' LE (0x53534553)
 0x04    1   direction              u8          0 = PRODUCE (!),
                                                1 = CONSUME (?)
 0x05    1   flags                  u8          bit 0 = CLOSED,
                                                bit 1 = CHAIN (M7.1+),
                                                bits 2..7 = reserved
 0x06    2   reserved               u16         zeroed; M7.1+ variant tag
 0x08    8   schema_tag_hash        u64         FNV-1a 64 of schema name
 0x10   16   schema_name_inline     [u8; 16]    ASCII identifier, zero-pad
```

Edge-pair width = 2 x 32 B = 64 B. A caller buffer of 64 B holds one
complete edge; a longer buffer holds a chain of edges concatenated.

## 5. Public API

Four entry points over caller-supplied buffers. Zero `.bss` state.
All pure leaves.

### 5.1 `_st_init() -> ()`

Idempotent lazy boot hook. Body is a bare `ret`. Reserved for a
later landing that adds `.bss` (per-session edge counters, a
schema-tag intern table, a per-session duality-fault counter).

Register map: `() -> rax` (ignored).

### 5.2 `_st_build_edge(producer_name_ptr, consumer_name_ptr, out, out_cap) -> packed_u64`

Emits two 32-byte SessionType records back-to-back at `out[0..64)`
from two schema names. The first record is the PRODUCE half on
`producer_name`; the second is the CONSUME half on `consumer_name`.

```
rdi = producer_name_ptr   (ptr to 16-byte zero-padded ASCII name)
rsi = consumer_name_ptr   (ptr to 16-byte zero-padded ASCII name)
rdx = out                 (ptr to >= 64 B caller buffer)
rcx = out_cap             (byte capacity of out)
rax = (bytes_written << 32) | status
```

Status taxonomy on failure:
```
ST_ERR_BAD_SCHEMA         0x5500   producer_name_ptr == 0 OR
                                   consumer_name_ptr == 0
ST_ERR_OUT_TOO_SMALL      0x5501   out == 0 OR out_cap < 64
```

The schema-name live length is the position of the first NUL byte
within `[name_ptr + 0..+16)`, capped at 16. The FNV hash is computed
over the live prefix; the inline 16-byte name field is byte-copied
verbatim including the zero padding beyond the first NUL.

### 5.3 `_st_check_duality(edge_a, edge_b) -> status`

Validates two SessionType records form a dual pair.

```
rdi = edge_a            (ptr to first 32-B record)
rsi = edge_b            (ptr to second 32-B record)
rax = ST_OK | ST_ERR_*
```

Status taxonomy:
```
ST_OK                       0        dual pair confirmed
ST_ERR_BAD_RECORD           0x5502   edge_a == 0 OR edge_b == 0
ST_ERR_SCHEMA_MISMATCH      0x5510   E0710: schema_tag_hash differs
ST_ERR_DIRECTION_MISMATCH   0x5511   E0711: both halves same direction
ST_ERR_UNCLOSED_SESSION     0x5512   E0712: CLOSED bit missing on
                                     one or both halves
ST_ERR_PROTOCOL_DRIFT       0x5513   E0713: magic mismatch OR
                                     direction byte > 1
```

The REPL's error reporter maps each E07NN code to a canonical
diagnostic string:

```
E0710  "edge-schema mismatch: producer sends `<prod>`, consumer
       expects `<cons>`"
E0711  "edge-direction mismatch: both halves are <dir>; a pipeline
       edge requires one producer and one consumer"
E0712  "edge session is open; expected `;done` at both halves"
E0713  "edge record carries unexpected magic / direction; not a
       SessionType"
```

### 5.4 `_st_render(record, out, out_cap) -> packed_u64`

Renders a readable surface form into out. Format:

```
<prefix><schema_name><suffix>
```

- `prefix` is `!` (0x21) for direction=0 or `?` (0x3F) for direction=1.
- `schema_name` is bytes at `[record + 16..+32)` up to the first NUL
  (0..16 bytes).
- `suffix` is `;done` (5 bytes) iff CLOSED is set, otherwise `;open`.

Total bytes written = 1 + schema_len + 5 (6..22 bytes).

```
rdi = record            (ptr to 32-B record)
rsi = out               (ptr to caller buffer)
rdx = out_cap           (byte capacity of out)
rax = (bytes_written << 32) | status
```

Status taxonomy:
```
ST_ERR_BAD_RECORD         0x5502   record == 0
ST_ERR_OUT_TOO_SMALL      0x5501   out == 0 OR out_cap < required
ST_ERR_PROTOCOL_DRIFT     0x5513   magic mismatch OR direction > 1
```

Examples:
```
!FileRec;done                direction=0, schema="FileRec", CLOSED
?Signal;done                 direction=1, schema="Signal", CLOSED
!FileRec;open                direction=0, schema="FileRec", NOT CLOSED
?;done                       direction=1, empty-name edge
```

## 6. Status band  --  `0x5500..0x55FF`

| code                        | hex      | meaning                             |
|-----------------------------|----------|-------------------------------------|
| ST_OK                       | 0        | success on every entry point        |
| ST_ERR_BAD_SCHEMA           | 0x5500   | NULL producer / consumer name ptr   |
| ST_ERR_OUT_TOO_SMALL        | 0x5501   | out NULL / capacity too small       |
| ST_ERR_BAD_RECORD           | 0x5502   | NULL record ptr                     |
| ST_ERR_SCHEMA_MISMATCH      | 0x5510   | E0710: schema_tag differs           |
| ST_ERR_DIRECTION_MISMATCH   | 0x5511   | E0711: same direction both halves   |
| ST_ERR_UNCLOSED_SESSION     | 0x5512   | E0712: CLOSED bit missing           |
| ST_ERR_PROTOCOL_DRIFT       | 0x5513   | E0713: bad magic / direction        |

Reserved for M7.1+:
```
0x5503..0x550F  build / validate faults (far-ptr chain errors,
                variant-tag errors, intern-table collisions)
0x5514..0x55FF  branch and linearity diagnostics (&-choice,
                +-offer, affinity violations)
```

The 0x5500..0x55FF band carves a one-kilo-step past Wave 127's
0x5400..0x54FF (R229.M6 LineEditor), 0x5300..0x53FF (R223.M6
HostnameAnnot), 0x5200..0x52FF (R223.M5 WireSink). The parallel
Wave 128 arms sit at 0x5600..0x56FF (R224.M7 LinearPropagate) and
0x5700..0x57FF (R229.M7 ViMode); the three arms' bands are mutually
disjoint so a downstream compound-error dispatcher can discriminate
"session-type substrate faulted" from "linear-propagate substrate
faulted" from "vi-mode substrate faulted" via a single
`shr r, 8; cmp r, 0x55` idiom.

The band displaces the prior soft reservation "deferred Vi-mode state
machine" (R229.M6.5 forward-path note in LineEditor); R229.M7 Vi-mode
has already relocated to 0x5700..0x57FF by its own carve-out comment
(see `vi_mode.pdx` line 184).

## 7. Encoder discipline (absolute)

Standard paideia-as PDX discipline:

- No `test rN, rN` -- every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64` -- the CLOSED-flag mask uses imm8 `and rax, 1`.
- No 2-op `imul rN, imm` -- FNV multiply uses one-op `mul rcx`.
- No multiline `pub let = "..."` -- single-line justifications.
- Module basename `SessionType` matches `session_type.pdx`.
- Labels prefixed `st_` (grep-confirmed unique against every landed
  parser-tier label prefix: `u8n_`, `gi_`, `wp_`, `sch_sig_`,
  `cmd_sig_`, `fi_`, `afs_`, `pl_`, `rp_`, `ll_`, `cc_`, `er_`,
  `cr_`, `cmdreg_`, `hm_`, `rt_`, `dl_`, `se_`, `te_`, `cl_`, `dm_`,
  `fo_`, `sgr_`, `jc_`, `fh_`, `ast_`, `sm_`, `ls_`, `lex_`, `eu_`,
  `h_`, `pl_lam_`, `ds_`, `le_`, `ha_`, `ws_`).
- Byte loads via `xor rN, rN; mov_b rN, [base + idx]` (zero-extend).
- Byte stores via `mov_b [dst + disp], reg`.
- u32 loads via `xor rN, rN; mov_d rN, [base + disp]`.
- u32 stores via `mov_d [dst + disp], reg`.
- u64 loads/stores via plain `mov`.
- No chained-displacement addressing: `[base + off + idx]` is
  precomputed into a scratch via `add` first, then dereferenced via
  `[rN + 0]`. The two FNV loops and both name-copy loops precompute
  the three-term address into `r9` or `r11` before the byte access.

### Immediate-encoding safety

All `cmp reg, imm` immediates:
- 0 (zero-check); 1 (bool / CLOSED bit); 16 (schema-name max); 32
  (record stride); 64 (edge-pair size); 0x21 (`!`); 0x3B (`;`); 0x3F
  (`?`); 0x53534553 (magic); 0x5500..0x5513 (status codes);
  0x64 (`d`); 0x65 (`e`); 0x6E (`n`); 0x6F (`o`); 0x70 (`p`); field
  offsets 0, 4, 5, 8, 16, 32, 36, 37, 40, 48.

Every immediate fits imm32 with bit 31 clear (0x53534553 < 0x80000000),
so `cmp reg, imm32` sign-extends safely to the full qword and no
MOVABS staging is required for the comparison itself.

### FNV constants

Loaded via REX.W + MOV encoding (10-byte MOVABS):
```
0xCBF29CE484222325   -- FNV-1a 64 offset basis
0x100000001B3        -- FNV-1a 64 prime
```

Precedent for the REX.W+MOV encoding of these two constants is
established in six prior leaves (`_cmd_sig_fnv1a64`, `_fi_fnv1a64`,
`_cmdreg_fnv1a64`, `_ws_schema_hash`, `_ha_parse`, `_ha_check`).

## 8. Register-liveness per entry

Every entry is a pure leaf; `r11` is used freely as the three-term
address-precompute scratch because no CALL fires.

- **`_st_init`**: bare `ret`. No regs touched.
- **`_st_build_edge`**: 4 inputs in `rdi`, `rsi`, `rdx`, `rcx`;
  scratch in `rax`, `r8`, `r9`, `r10`, `r11`. 4 callee-save pushes:
  `rbx` (= producer_name base, held across the two record emits),
  `rbp` (= consumer_name base, same), `r12` (= out base, held
  unchanged across all stores), `r13` (reserved for an M7.1+
  chain-pointer carry; XOR'd to zero at M7). `r10` is the write
  index (dies each loop). `rax` is the FNV accumulator during the
  hash loops and the return packer. `rcx` holds the FNV prime
  across each hash loop (reloaded for the second).
- **`_st_check_duality`**: 2 inputs in `rdi`, `rsi`; scratch in `rax`,
  `rcx`, `rdx`, `r8`, `r9`. No pushes; no stack frame. `rax` carries
  the status code at every return site.
- **`_st_render`**: 3 inputs in `rdi`, `rsi`, `rdx`; scratch in
  `rax`, `r8`, `r9`, `r10`, `r11`. 3 callee-save pushes: `rbx` (=
  record base), `r12` (= out base), `r13` (= schema_len across the
  capacity check and the copy loops).

## 9. Lazy-init non-applicability

Not applicable at M7: this module holds no `.bss` state. Every
SessionType record is caller-owned on all three operational paths;
the hash operates as a pure byte walk over a caller-supplied name
buffer. `_st_init` is a bare `ret` placeholder.

A later landing that adds `.bss` (per-session edge counters, a
schema-tag intern table, a per-session duality-fault counter) will
flesh out `_st_init` behind the same name without an ABI break.

## 10. Acceptance -- ten adversarial mismatched pipelines

The acceptance brief (issue #2672) requires ten mismatched pipelines
to each fail type-check with the E0710 family of diagnostics. The
corpus (deferred to the eventual R223 fuzz landing per the umbrella
decomposition) covers:

| # | pipeline                                | mismatch       | expected diagnostic |
|---|-----------------------------------------|----------------|---------------------|
| 1 | `find \| sort by name`                  | `FileRec` vs `Entry` schema | E0710 |
| 2 | `ls \| reduce by group`                 | `FileRec` vs `GroupKey` schema | E0710 |
| 3 | `tokens \| sort by size`                | `TokenRec` vs `FileRec` schema | E0710 |
| 4 | `stat \| describe <cmd>`                | `Stat` vs `DescribeArgs` schema | E0710 |
| 5 | `history \| filter by `size>0``         | `HistoryRec` vs `FileRec` schema | E0710 |
| 6 | `find \|\| sort`                        | empty stage, direction skew | E0711 |
| 7 | manual: both halves PRODUCE             | fabricated edge with two `!X` | E0711 |
| 8 | manual: open producer, closed consumer  | CLOSED missing on first half | E0712 |
| 9 | manual: zeroed first bytes              | magic mismatch | E0713 |
| 10| manual: direction byte 7                | direction out of {0,1} | E0713 |

Cases 1..5 are drawn from the semantic-shell language plan examples
in `design/terminal/semantic-shell.md` §cross-schema-pipelines; cases
6..10 are fabricated edge records that exercise the four distinct
E07NN classes.

Each case:
1. The parser builds an edge pair via `_st_build_edge(prod, cons, ...)`.
2. `_st_check_duality(a, b)` is called.
3. The expected status code is one of `0x5510`, `0x5511`, `0x5512`,
   `0x5513`.
4. `_st_render(a, ...)` and `_st_render(b, ...)` yield the surface
   form for the REPL's error reporter to splice into the E07NN
   diagnostic.

## 11. Consumer pattern

A downstream pipeline type-checker calls three entry points per edge:

```pdx
// At pipeline-parse time, between stage[i] and stage[i+1]:
packed_u64 res = _st_build_edge(
    stage_out_schema_name,     // 16-B zero-padded buffer
    stage_in_schema_name,      // 16-B zero-padded buffer
    edge_record_buffer,        // 64-B caller buffer (two 32-B records)
    64);
if (res & 0xFFFFFFFF != 0) {
    // Build failure (OOM / bad input). Report ST_ERR_BAD_SCHEMA /
    // ST_ERR_OUT_TOO_SMALL to the user.
    return;
}

u64 ok = _st_check_duality(
    edge_record_buffer + 0,    // Record A: PRODUCE
    edge_record_buffer + 32);  // Record B: CONSUME
if (ok != 0) {
    // E07NN family: splice _st_render of both records into the
    // diagnostic and route to the REPL's error reporter.
    char buf_a[32], buf_b[32];
    packed_u64 ra = _st_render(edge_record_buffer, buf_a, 32);
    packed_u64 rb = _st_render(edge_record_buffer + 32, buf_b, 32);
    emit_diagnostic(ok, buf_a, ra >> 32, buf_b, rb >> 32);
}
```

The buffer sits in the type-checker's per-session arena; it never
leaves the shell process at M7 (M7.1+ serialises an edge pair into
a WireSink frame for remote-pipeline fan-out).

## 12. Boundary -- where this is NOT

- Not a RUNTIME TYPE-CHECK. The dual-pair validation runs at
  pipeline-parse time; once a pipeline type-checks, M7 does not
  re-validate at every record delivery. (M7.1+ wires a per-delivery
  magic sanity check behind the `R223.M7_RUNTIME_GUARD` build flag.)
- Not a FULL SESSION-TYPE SYSTEM. The lattice at M7 has two
  inhabitants and one dual rule; a proper session-type system has
  external / internal choice (`&{A, B}`, `+{A, B}`), recursive
  session types (`mu X. !int; X`), and higher-order session
  passing. Those extensions land at M7.3 onward.
- Not an EFFECT or CAPABILITY TYPE. R224.M3 (EffectRow) and R224.M4
  (CapRow) carry the orthogonal typing axes. A pipeline edge's full
  type is the quintuple (schema, direction, closed, effect-row,
  cap-row); M7 enforces the first three; the latter two run through
  R225.M4 EffectUnify. (A follow-up at M7.5 wires a combined
  acceptance pass that cross-validates all five axes at a single
  edge.)
- Not a WIRE PROTOCOL. The 32-byte record is an INTRA-PROCESS
  typing artifact. R223.M5 WireSink's `_ws_serialize_record` is the
  cross-boundary serializer; M7.1+ serialises an edge pair into
  one WireSink frame for remote-pipeline fan-out.

## 13. File footprint

| path                                                | role                       |
|-----------------------------------------------------|----------------------------|
| `tools/user/libpdx-pds-parser/src/session_type.pdx` | module source              |
| `design/shell/session-typed-edges.md`               | THIS doc                   |
| `tools/user/libpdx-pds-parser/caps.decl`            | +catalogue + error-band    |
| `tools/user/libpdx-pds-parser/src/lib.pdx`          | +feature-ready flag flipped |
| `tools/user/libpdx-pds-parser/CHANGELOG.md`         | +1.29.0 R223.M7 stanza     |
| `tools/user/libpdx-pds-parser/STATUS.md`            | +R223.M7 landing section   |
| `.plans/scratch/CHANGELOG-R223M7.md`                | per-primitive scratch      |

## 14. Forward path

- **R223.M7.1** -- Multi-step protocol chains. `flags` bit 1 (CHAIN)
  marks a record whose `reserved` u16 holds the index of the next
  SessionType record in a chain pool. The dual-check walks both
  chains in lockstep until a `CLOSED` record is reached on both
  sides.
- **R223.M7.2** -- Fan-out protocols for `@group:rule` host-set
  edges (R223.M6 federation extension). Pairs with HostnameAnnot's
  kind=GROUP record.
- **R223.M7.3** -- Branch types. External choice `&{A, B}`
  (consumer picks which schema it will receive) and internal
  choice `+{A, B}` (producer picks which schema it will send).
  Encoded in a trailing variant tag inside `reserved`.
- **R223.M7.4** -- Linearity cross-wire. Once R224.M7
  LinearPropagate lands fully, an edge becomes statically
  one-shot: the type-checker refuses a second use of the same
  edge-pair record. Pairs with LinearPropagate's `LP_KIND_LINEAR`.
- **R223.M7.5** -- Combined quintuple acceptance pass that
  cross-validates (schema, direction, closed, effect-row,
  cap-row) at a single edge; wires R225.M4 EffectUnify + R224.M4
  CapRow into the duality check.
- **R223.M7.6** -- 10-fixture adversarial corpus (per §10) under
  `tests/proptest_session_type.pdx`; folds into the R221.M7 fuzz
  harness bridge once a `FUZZ_KIND_SESSION_TYPE` target is added.
