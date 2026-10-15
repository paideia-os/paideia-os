# Cross-context type flow — Datalog <-> pipeline-record seam (R225.M5)

**Status:** v0.1 (R225.M5 — paideia-os#2686)
**Date:** 2026-10-15
**Author:** softarch (Wave 134 R225.M5 arm)
**Scope:** The user-space parser-tier primitive that materializes a
flat, cache-line-sized bridge record describing one cross-context
escape between Datalog's variable surface and the pipeline sub-
language's row-typed record surface. Lands in `libpdx-pds-parser`
at `tools/user/libpdx-pds-parser/src/ctx_flow.pdx`.

---

## 1. Position in the parser substrate

```
                raw pds-lang program bytes
                          |
                          v
      +------------------------------------------+
      | R221  Utf8Nfc + CtxLexer                 |
      +---------------------+--------------------+
                            |
        +-------------------+---------------------+
        v                                         v
   +---------+                               +---------+
   | datalog |                               | pipeline|
   | R226.M1 |                               | R223.M1 |
   +----+----+                               +----+----+
        |                                         |
        v   per-term type codes                   v   row fields
   +---------+                               +---------+
   | R226.M2 |                               | R225.M2 |
   | PredTy  |                               | RowTypes|
   +----+----+                               +----+----+
         \                                       /
          \                                     /
           v                                   v
                   R225.M5 CtxFlow (THIS)
                 ------------------------------
                 _cxf_derive_datalog_to_pipeline
                 _cxf_derive_pipeline_to_datalog
                 _cxf_check
                 ------------------------------
                            |
                            v
               typed bridge record for the
               elaborator / HM solver / Datalog
               evaluator seam
```

The semantic shell mixes three sub-languages inside the same turn
(pipeline, lambda, datalog). A Datalog variable (`?X`) that escapes
to pipeline context MUST take the typed argument slot of the
predicate it binds against; conversely a pipeline record (whose
shape is an R225.M2 row type) that flows into a `datalog { ... }`
block must be re-interpreted as a ground datalog term whose per-
field type is read off the row.

R226.M2 PredicateTypes (landed Wave 133) carved the predicate-side
substrate: a 64-byte PredicateRecord with the predicate's arity
and per-position type codes. R225.M2 RowTypes (landed Wave 118)
carved the pipeline-side substrate: a shared type-graph pool whose
row nodes expose fields via `_rt_row_select`. R225.M5 (this module)
closes the seam at the parser tier — a caller-driven surface that
emits one 64-byte CtxFlow record per bridge value.

The three layers (R226.M2 PredicateTypes, R225.M2 RowTypes,
R225.M5 CtxFlow) do not depend on each other via a single mega-
API; the caller (the shell's HM semantic elaborator, R225.M8+) is
the compositor. R225.M5 CALLs _rt_label_hash and _rt_row_select
INSIDE _cxf_derive_pipeline_to_datalog because the row-field
resolution is a mechanical consequence of the field name and the
pool. R225.M5 does NOT call into predicate_types.pdx — the caller
has already resolved the predicate via `_pt_lookup` and hands us
the record by pointer.

## 2. Record layout — 64 bytes per CtxFlow

| offset | size | field                 | contents                                       |
|-------:|-----:|-----------------------|------------------------------------------------|
|      0 |    4 | `magic`               | u32 — `'CTXF'` little-endian = `0x46585443`.   |
|      4 |    1 | `direction`           | u8 — `0` DATALOG_TO_PIPELINE / `1` PIPELINE_TO_DATALOG. |
|      5 |    1 | `flags`               | u8 — reserved for M5.1+ annotation bits.       |
|      6 |    2 | `reserved`            | u16 — zero at raw M5.                          |
|      8 |    8 | `src_type_ref`        | u64 — source type-ref (see §2.1).              |
|     16 |    8 | `dst_type_ref`        | u64 — derived destination type-ref (see §2.1). |
|     24 |   32 | `bridge_name_inline`  | u8[32] — bridge name, zero-padded.             |
|     56 |    8 | `reserved`            | u64 — zero at raw M5.                          |

Total: **64 bytes** (one x86-64 cache line), aligned to 8. Stride is
a power of two so a future pool over these records can be addressed
via `shl rN, 6` with no 2-op `imul r, imm` (`feedback_pdx_encoder_
pitfalls`). The record is pure data; the module owns NO `.bss`
pool for it. On all three public entries the record is caller-owned.

Magic `'CTXF'` = bytes `0x43 0x54 0x58 0x46` on disk; as a little-
endian `u32` reads as `0x46585443`. Bit 31 is clear so direct
`mov r, imm32` and `cmp r, imm32` are sign-safe.

### 2.1 src_type_ref / dst_type_ref interpretation

The two type-ref slots are polymorphic along the `direction` axis:

- **direction = 0 (DATALOG_TO_PIPELINE):**
  - `src_type_ref` = pointer to the resolved R226.M2
    `PredicateRecord` (magic `'PRTY'` at `[+0]`). The caller
    resolved it via `_pt_lookup` BEFORE invoking us.
  - `dst_type_ref` = the SchemasSig / PT_TYPE_* type code
    (`SS_TYPE_U64 = 1 .. PT_TYPE_WILD = 11`) in the low 8 bits;
    upper 56 bits zero.
- **direction = 1 (PIPELINE_TO_DATALOG):**
  - `src_type_ref` = HmCore pool_idx (u32 payload zero-extended)
    naming the row-type node (TyRow ROW_EXT / ROW_VAR / ROW_EMPTY).
  - `dst_type_ref` = HmCore pool_idx (u32 payload zero-extended)
    naming the per-field type node, resolved via R225.M2
    `_rt_row_select`.

The two slots are deliberately `u64` even though direction=0's
`dst_type_ref` carries only a byte and direction=1's slots carry
only u32 pool_idx values: the extra width future-proofs the ABI
when R225.M8+ HM bridge introduces a typed-u64 cross-ref format
or when R225.M5.2+ adds mixed sign-tagged refs.

### 2.2 Stride reconciliation note

Unlike R226.M2's 48-vs-64 stride reconciliation, the parent brief
for R225.M5 cleanly specifies 64 bytes end-to-end: `bridge_name_
inline[32]` at `[+24]` ends at `[+56]`, and the terminal reserved
`u64` sits at `[+56..+64)`. 64 is both a power of two (so a future
pool uses `shl rN, 6`) and one cache line (so a record never
straddles).

## 3. Pool — none (caller-owned records)

R225.M5 owns NO `.bss` state. Every record is caller-owned on all
three public entries. The derive entries read ONLY caller-supplied
pointer args and the shared HmCore pool via R225.M2's primitives.
The check entry reads ONLY the caller-supplied 64-byte record.

`_cxf_init` is a bare `ret`. Kept for parallelism with the parser-
family init-hook convention (`_st_init` R223.M7, `_ha_init` R223.M6,
`_ws_init` R223.M5, `_ds_init` R222.M8, `_dm_init` R222.M6,
`_cmdreg_init` R222.M5).

## 4. Public API

### 4.1 `_cxf_init() -> ()`

Bare `ret`. Pure leaf.

### 4.2 `_cxf_derive_datalog_to_pipeline(predicate_record, arg_idx, var_name_ptr, var_name_len, out, out_cap) -> status`

Register map (SysV x64):

| arg               | reg | notes                                                            |
|-------------------|-----|------------------------------------------------------------------|
| `predicate_record`| rdi | ptr to R226.M2 64-byte PredicateRecord (`'PRTY'` at `[+0]`).     |
| `arg_idx`         | rsi | `0..arity-1`; validated against predicate's u16 arity at `[+4]`. |
| `var_name_ptr`    | rdx | ASCII name bytes of the ?var (without the leading `?`).           |
| `var_name_len`    | rcx | 1..32.                                                           |
| `out`             | r8  | 64-byte caller-owned scratch.                                    |
| `out_cap`         | r9  | bytes; must be >= 64.                                            |
| return            | rax | `CXF_OK` or `CXF_ERR_*`.                                         |

Flow (pure leaf — zero pushes, no stack frame, no nested CALL):

1. `out != 0` (`BAD_PTR` 0x6600).
2. `out_cap >= 64` (`OUT_TOO_SMALL` 0x6605).
3. `predicate_record != 0` (`BAD_PTR`).
4. `magic == 'PRTY'` at `[predicate_record + 0]` (`BAD_RECORD` 0x6601).
5. `arg_idx < arity` where `arity` is the u16 at `[+4]` (`BAD_ARG_IDX` 0x6603).
6. `var_name_ptr != 0`, `var_name_len in [1..32]` (`BAD_PTR` / `BAD_NAME` 0x6604).
7. Load `type_code = u8 at [predicate_record + 32 + arg_idx]`;
   validate `type_code in [1..11]` (`BAD_TYPE_CODE` 0x6609).
8. Zero-fill 64 bytes at `out` via 8 `u64` stores.
9. Stamp fields:
   - `[+0]` magic `'CTXF'` (`mov_d`).
   - `[+4]` direction = 0 (`mov_b`).
   - `[+5]` flags = 0 (`mov_b`).
   - `[+8]` src_type_ref = `predicate_record` (plain `mov`).
   - `[+16]` dst_type_ref = `type_code` zero-extended (plain `mov`).
   - `[+24..+24+var_name_len]` byte-copy from `var_name_ptr`;
     zero-padded past len from the zero-fill above.
10. Return `CXF_OK`.

### 4.3 `_cxf_derive_pipeline_to_datalog(row_type_ref, field_name_ptr, field_name_len, out, out_cap) -> status`

Register map (SysV x64):

| arg               | reg | notes                                                       |
|-------------------|-----|-------------------------------------------------------------|
| `row_type_ref`    | rdi | HmCore pool_idx. Caller unwraps outer TyApp wrapping.       |
| `field_name_ptr`  | rsi | ASCII identifier bytes of the field label.                  |
| `field_name_len`  | rdx | 1..32.                                                      |
| `out`             | rcx | 64-byte caller-owned scratch.                               |
| `out_cap`         | r8  | bytes; must be >= 64.                                       |
| return            | rax | `CXF_OK` or `CXF_ERR_*`.                                    |

Flow (6-push callee-save frame + `sub rsp, 16` scratch = 64 B total):

1. Save args into callee-save registers (rbx = row_type_ref,
   rbp = field_name_ptr, r12 = field_name_len, r13 = out,
   r14 = out_cap).
2. Validate `out != 0`, `out_cap >= 64`, `field_name_ptr != 0`,
   `field_name_len in [1..32]`, `row_type_ref != 0`
   (`BAD_PTR` 0x6600 / `BAD_NAME` 0x6604 / `OUT_TOO_SMALL` 0x6605 /
   `BAD_ROW` 0x6607).
3. `label_hash := _rt_label_hash(field_name_ptr, field_name_len)`
   (stored in r15 across the next CALL).
4. Zero scratch slot `[rsp + 0]`; call
   `_rt_row_select(row_type_ref, label_hash, &scratch)`.
   On `RT_ERR_LABEL_MISSING` (0x3600) or any other non-zero
   status return `CXF_ERR_UNKNOWN_FIELD` (0x6606).
5. Load `field_type_pool_idx := [rsp + 0]`.
6. Zero-fill 64 bytes at `out` via 8 u64 stores.
7. Stamp fields:
   - `[+0]` magic `'CTXF'` (`mov_d`).
   - `[+4]` direction = 1 (`mov_b`).
   - `[+5]` flags = 0 (`mov_b`).
   - `[+8]` src_type_ref = `row_type_ref` (plain `mov`).
   - `[+16]` dst_type_ref = `field_type_pool_idx` (plain `mov`).
   - `[+24..+24+field_name_len]` byte-copy from `field_name_ptr`.
8. Return `CXF_OK`.

Stack-alignment accounting: entry `rsp%16 == 8`; after 6 pushes
`rsp%16 == 8`; after `sub rsp, 16` `rsp%16 == 0` at both nested
CALLs (`_rt_label_hash`, `_rt_row_select`).

### 4.4 `_cxf_check(ctxflow_record, record_len) -> status`

Register map (SysV x64):

| arg               | reg | notes                                                  |
|-------------------|-----|--------------------------------------------------------|
| `ctxflow_record`  | rdi | ptr to a 64-byte CtxFlow record.                       |
| `record_len`      | rsi | capacity in bytes; must be >= 64.                      |
| return            | rax | `CXF_OK` or `CXF_ERR_*`.                               |

Flow (pure leaf):

1. `ctxflow_record != 0` (`BAD_PTR` 0x6600).
2. `record_len >= 64` (`BAD_LEN` 0x6608).
3. magic u32 at `[+0]` == `'CTXF'` (`BAD_RECORD` 0x6601).
4. direction u8 at `[+4]` in `{0, 1}` (`BAD_DIRECTION` 0x6602).
5. src_type_ref u64 at `[+8]` != 0 (`BAD_SRC_REF` 0x660A).
6. dst_type_ref u64 at `[+16]` != 0 (`BAD_SRC_REF` 0x660A).
7. Return `CXF_OK`.

The record's `bridge_name_inline` / `reserved` bytes are NOT
structurally inspected — the caller is responsible for name
hygiene (UTF-8 validation, duplicate-detection, etc.).

## 5. Status taxonomy — band `0x6600..0x66FF`

| code     | mnemonic                     | notes                                 |
|---------:|------------------------------|---------------------------------------|
|      `0` | `CXF_OK`                     | —                                     |
| `0x6600` | `CXF_ERR_BAD_PTR`            | NULL ptr where non-NULL required.     |
| `0x6601` | `CXF_ERR_BAD_RECORD`         | Magic mismatch (PRTY or CTXF).        |
| `0x6602` | `CXF_ERR_BAD_DIRECTION`      | `direction` not in `{0, 1}`.          |
| `0x6603` | `CXF_ERR_BAD_ARG_IDX`        | `arg_idx >= arity`.                   |
| `0x6604` | `CXF_ERR_BAD_NAME`           | Name len 0 or > 32.                   |
| `0x6605` | `CXF_ERR_OUT_TOO_SMALL`      | `out_cap < 64`.                       |
| `0x6606` | `CXF_ERR_UNKNOWN_FIELD`      | Row-select miss.                      |
| `0x6607` | `CXF_ERR_BAD_ROW`            | `row_type_ref == 0`.                  |
| `0x6608` | `CXF_ERR_BAD_LEN`            | `record_len < 64` on check.           |
| `0x6609` | `CXF_ERR_BAD_TYPE_CODE`      | type-code out of `[1..11]`.           |
| `0x660A` | `CXF_ERR_BAD_SRC_REF`        | src or dst slot zero on check.        |

Slots `0x660B..0x66FF` reserved for M5.1+ diagnostics (open-tail
row-var relax, recursive-escape warn-level, subsumption rule
refinement for cross-context subtyping, bridge-name UTF-8
validation, PredicateRecord-arg-type-code vs row-field-type cross-
validation when the HM bridge M5.2+ lands).

Band `0x6600..0x66FF` sits above:

- `0x6500..0x65FF` R227.M7 ScriptCache (landed Wave 133).
- `0x6400..0x64FF` R226.M2 PredicateTypes (landed Wave 133).
- `0x6300..0x63FF` R225.M10 CheckFingerprint (landed Wave 133).
- `0x6200..0x62FF` R227.M6 VersionPragma (landed Wave 132).
- `0x6100..0x61FF` R225.M9 ProptestHm (landed Wave 132).

The next kilo-step band `0x6700..0x67FF` stays reserved for a
future R225 wave arm.

Grep confirmation at R225.M5 landing time:

```
grep -rE '0x66[0-9A-F]{2}' paideia-os/{src,tools,design,tests}
  -> no packed-status hits outside src/ctx_flow.pdx, caps.decl,
     this file, STATUS.md, and .plans/scratch/CHANGELOG-R225M5.md.
```

## 6. Interactions

### 6.1 R226.M2 PredicateTypes (`predicate_types.pdx`)

The direction=0 derive path reads a caller-supplied PredicateRecord
IN-PLACE: validates magic at `[+0]`, reads u16 arity at `[+4]`,
reads one u8 type code at `[+32 + arg_idx]`. **No direct call** from
this module into `predicate_types.pdx`; the caller resolved the
record via `_pt_lookup` BEFORE invoking us.

Three R226.M2 constants are DUPLICATED as `pub let` literals so
this module links standalone against predicate_types.pdx's own
`pub let` set:

- `CXF_PT_RECORD_MAGIC = 0x59545250` (`'PRTY'`).
- `CXF_PT_OFF_ARITY = 4`.
- `CXF_PT_OFF_ARG_TYPE_CODES = 32`.
- `CXF_PT_TYPE_CODE_MAX = 11`.

### 6.2 R225.M2 RowTypes (`row_types.pdx`)

The direction=1 derive path CALLs `_rt_label_hash(ptr, len)` to
compute the FNV-1a 32 label hash, then `_rt_row_select(row_idx,
label_hash, &out)` to walk the row chain. These are intra-library
CALLs across module linker scopes (precedent: `_rt_row_unify` calls
`_hm_unify` from the sibling R225.M1 `hm_core.pdx` the same way).

One R225.M2 return code is DUPLICATED as a `pub let` literal:

- `CXF_RT_ERR_LABEL_MISSING = 0x3600` (returned by `_rt_row_select`
  on a row-chain exhaustion).

### 6.3 R222.M1 SchemasSig (`schemas_sig.pdx`)

The type-code set in the direction=0 derive path uses the
`SS_TYPE_*` numbering `1..6, 8, 9` verbatim as the low 8 bits of
`dst_type_ref`. `PT_TYPE_VAR = 10` and `PT_TYPE_WILD = 11` are the
parser-tier M2 extensions (defined in `predicate_types.pdx`) that
this module accepts without translation on derive. No direct call.

### 6.4 R225.M8+ HM semantic elaborator (NOT yet landed)

The caller of all three entry points. Walks the AST, drives the
per-escape derive calls, stashes each returned CtxFlow record
beside its typing-env entry, and plumbs the bridge records into
the diagnostic reporter's E09NN / E07NN family when a mismatch
surfaces.

### 6.5 R226.M3 bottom-up semi-naive evaluator (NOT yet landed)

Consumes the direction=1 derived field types to confirm the in-flow
record satisfies the predicate's typed slot at datalog entry.
Reads the CtxFlow record's `dst_type_ref` and cross-checks against
the predicate's `arg_type_codes[arg_idx]`.

## 7. Forward path

| milestone  | content                                                               |
|------------|-----------------------------------------------------------------------|
| R225.M5.1  | Open-tail row-var relax: direction=1 derive binds a fresh TyVar to    |
|            | a row-var tail instead of returning `UNKNOWN_FIELD`.                  |
| R225.M5.2  | HM-bridge cross-validation: `_cxf_check` gains an optional magic-     |
|            | level `expect` check that verifies the derived dst_type_ref is       |
|            | compatible with the expected type at the escape site.                 |
| R225.M5.3  | 25-test corpus landing under `tests/shell/cross-context/` + AFL++    |
|            | shim (mirrors the R221.M7 + R225.M9 split).                           |
| R225.M8    | HM semantic elaborator: consumes the three public entries on every    |
|            | datalog-escape and every pipeline-into-datalog recognition point.     |
| R226.M3    | Bottom-up semi-naive evaluator: reads direction=1 derived field       |
|            | types to confirm in-flow records satisfy the predicate's slot.        |

## 8. 25-test corpus (acceptance anchor)

The acceptance clause for R225.M5 is a **25-test corpus** that
drives `_cxf_derive_datalog_to_pipeline` / `_cxf_derive_pipeline_
to_datalog` / `_cxf_check` through its full decision table. The
corpus itself lands as a satellite under
`tests/shell/cross-context/` — deferred to R225.M5.3 along with
the AFL++ shim (same raw-vs-corpus split as R221.M7 FuzzHarness,
R225.M9 ProptestHm, and R226.M2 PredicateTypes M2.3). The 25
cases enumerated for the corpus are:

**Group A — datalog_to_pipeline (10 cases):**

| # | input                                                                                   | result                     |
|---|-----------------------------------------------------------------------------------------|----------------------------|
| 1 | `derive_d2p(parent/2 [STR, STR], arg_idx=0, "X", 1, out, 64)`                           | `OK`; dst=STR (3); dir=0.  |
| 2 | `derive_d2p(parent/2 [STR, STR], arg_idx=1, "Y", 1, out, 64)`                           | `OK`; dst=STR (3).         |
| 3 | `derive_d2p(fact/5 [U64, HASH32, TSC, TSC, I64], arg_idx=2, "T", 1, out, 64)`           | `OK`; dst=TSC (6).         |
| 4 | `derive_d2p(parent/2, arg_idx=2, ...)` (arg_idx == arity)                               | `BAD_ARG_IDX` (0x6603).    |
| 5 | `derive_d2p(parent/2, arg_idx=5, ...)` (arg_idx > arity)                                | `BAD_ARG_IDX`.             |
| 6 | `derive_d2p(predicate_record=0, ...)`                                                   | `BAD_PTR` (0x6600).        |
| 7 | `derive_d2p(zeroed-record, ...)` (magic != 'PRTY')                                      | `BAD_RECORD` (0x6601).     |
| 8 | `derive_d2p(parent/2, 0, var_name_ptr=0, 1, out, 64)`                                   | `BAD_PTR`.                 |
| 9 | `derive_d2p(parent/2, 0, "X" * 33, 33, out, 64)`                                        | `BAD_NAME` (0x6604).       |
|10 | `derive_d2p(parent/2, 0, "X", 1, out, 60)` (out_cap < 64)                               | `OUT_TOO_SMALL` (0x6605).  |

**Group B — pipeline_to_datalog (10 cases):**

| #  | input                                                                                | result                     |
|----|--------------------------------------------------------------------------------------|----------------------------|
| 11 | `derive_p2d(row {name: str, age: u64}, "name", 4, out, 64)`                          | `OK`; dst=pool_idx(str).   |
| 12 | `derive_p2d(row {name: str, age: u64}, "age", 3, out, 64)`                           | `OK`; dst=pool_idx(u64).   |
| 13 | `derive_p2d(row {}, "name", 4, out, 64)` (empty row)                                 | `UNKNOWN_FIELD` (0x6606).  |
| 14 | `derive_p2d(row {name: str}, "missing", 7, out, 64)`                                 | `UNKNOWN_FIELD`.           |
| 15 | `derive_p2d(row_var_tail, "name", 4, out, 64)` (ROW_VAR tail)                        | `UNKNOWN_FIELD` (M5.1 relax).|
| 16 | `derive_p2d(row {name: str}, 0, 4, out, 64)` (name_ptr == 0)                         | `BAD_PTR` (0x6600).        |
| 17 | `derive_p2d(row {name: str}, "name", 0, out, 64)` (name_len == 0)                    | `BAD_NAME` (0x6604).       |
| 18 | `derive_p2d(row {name: str}, "x"*33, 33, out, 64)` (name_len > 32)                   | `BAD_NAME`.                |
| 19 | `derive_p2d(row_type_ref=0, "name", 4, out, 64)`                                     | `BAD_ROW` (0x6607).        |
| 20 | `derive_p2d(row {name: str}, "name", 4, out, 60)` (out_cap < 64)                     | `OUT_TOO_SMALL` (0x6605).  |

**Group C — check (5 cases):**

| #  | input                                                                                | result                     |
|----|--------------------------------------------------------------------------------------|----------------------------|
| 21 | `check(record_from_case_1, 64)`                                                      | `OK`.                      |
| 22 | `check(record_with_zeroed_magic, 64)`                                                | `BAD_RECORD` (0x6601).     |
| 23 | `check(record_with_direction=2, 64)`                                                 | `BAD_DIRECTION` (0x6602).  |
| 24 | `check(record_with_zero_src, 64)`                                                    | `BAD_SRC_REF` (0x660A).    |
| 25 | `check(record_with_len=60, 60)`                                                      | `BAD_LEN` (0x6608).        |

The 25-test corpus is the acceptance anchor the parent brief
specified; the raw M5 landing delivers the harness surface
(`_cxf_*` entry points) that the corpus will drive. Corpus itself
lands at M5.3.

## 9. paideia-as encoder discipline

Standard parser-tier lesson set (`feedback_pdx_encoder_pitfalls`):

- No `test rN, rN` — every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64` — the only mask we need is `shl r, 48; shr r, 48`
  to isolate the low 16 bits of the arity scratch (defensive).
- No 2-op `imul r, imm` — no multiplication in this module.
- No multiline `pub let = "..."` — single-line justifications.
- Module basename `CtxFlow` matches `ctx_flow.pdx`.
- Labels prefixed `cxf_` (unique against every landed parser-tier
  label prefix). Per-function suffix: `cxf_ini_`, `cxf_dp_`,
  `cxf_pd_`, `cxf_ck_`.
- All `cmp reg, imm` immediates (`0, 1, 11, 32, 64, 0x3600, 0x6600..
  0x660A, 0x46585443, 0x59545250`) fit imm32 with bit 31 clear.
  `'CTXF' = 0x46585443` has bit 30 set but bit 31 clear so direct
  `mov r, imm32` + `cmp r, imm32` are sign-safe. `'PRTY' =
  0x59545250` also has bit 31 clear.
- Byte loads via `xor r, r; mov_b r, [addr]` (zero-extends into the
  full qword; paideia-as #1248 + U1606 mitigation).
- u32 stores via `mov_d`; u16 stores via two `mov_b`; u8 stores
  via `mov_b`; u64 stores via plain `mov`.
- No three-term addressing — every `[base + idx + disp]` precomputes
  the address via `mov r10, base; add r10, idx; add r10, disp;
  mov_b dst, [r10]`.
- `_cxf_init` is pure leaf (bare `ret`).
- `_cxf_derive_datalog_to_pipeline` is pure leaf (reads caller
  buffers only; writes caller-supplied out; no CALL).
- `_cxf_check` is pure leaf.
- Only `_cxf_derive_pipeline_to_datalog` holds a callee-save frame
  — 6 pushes + `sub rsp, 16` = 64 B. Nested CALLs: `_rt_label_hash`,
  `_rt_row_select`.

## 10. Register-liveness

Per the lessons from `feedback_pdx_encoder_pitfalls` and the Wave
132 debugger patch that moved `_pth_generate`'s byte-copy source
pointer off `r12`:

- Every value that must survive a nested CALL in
  `_cxf_derive_pipeline_to_datalog` lives in `rbx..r15` (callee-
  save) or on the stack frame.
- The scratch slot at `[rsp + 0]` is a u64 reserved for
  `_rt_row_select`'s out param — zeroed BEFORE the CALL so a
  defensive non-zero status still leaves a well-defined slot.
- `r11` is treated as caller-save and never crossed over any CALL;
  the pure-leaf paths use it freely as a short-term scratch (type
  code carrier in `_cxf_dp_`, byte-copy scratch everywhere).
- `_cxf_derive_pipeline_to_datalog` sets `r15` (`label_hash`)
  AFTER the first CALL (`_rt_label_hash`) and uses it as the second
  CALL arg (`_rt_row_select`) — r15 is callee-save so the second
  CALL cannot clobber it.

## 11. Cross-references

- `design/shell/row-types-remy.md` — the R225.M2 row-type substrate
  this module's direction=1 path consumes via `_rt_row_select`.
- `design/shell/predicate-type-resolution.md` — the R226.M2
  PredicateRecord shape this module's direction=0 path reads.
- `design/shell/datalog-parser.md` — the R226.M1 parser that
  emits the Clause records upstream of a direction=0 derive.
- `design/shell/pipeline-record-projection.md` — the R223.M2
  record-projection surface that produces the row types this
  module's direction=1 path consumes.
- `design/shell/hm-algorithm-w-core.md` — the R225.M1 type-graph
  the eventual R225.M8 HM semantic elaborator will connect to via
  this module's bridge records.
- `design/terminal/semantic-shell-language-plan.md` — the §R225
  umbrella's cross-context flow clause (M5).
- `feedback_pdx_encoder_pitfalls` — the encoder-discipline lessons.
- `feedback_paideia_as_reserved_labels` — the reserved-keyword set.
