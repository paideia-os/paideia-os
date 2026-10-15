# Predicate-type resolution against the schema registry (R226.M2)

**Status:** v0.1 (R226.M2 — paideia-os#2693)
**Date:** 2026-10-15
**Author:** softarch (Wave UMB-W28)
**Scope:** The user-space parser-tier primitive that, given the
Clause records R226.M1 produces, resolves each predicate's typed
signature, auto-registers user-defined predicates on first use, and
validates per-position argument types at every call site. Lands in
`libpdx-pds-parser` at
`tools/user/libpdx-pds-parser/src/predicate_types.pdx`.

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
      | R226.M1  Datalog::_dl_parse              |
      +---------------------+--------------------+
                            |
                            v  Clause[0..n]
      +------------------------------------------+
      | R226.M2  PredicateTypes::_pt_* (THIS)    |
      |                                          |
      |   _pt_register : (name, arity, types)    |
      |                  -> PredicateRecord      |
      |   _pt_lookup   : (name) -> record|miss   |
      |   _pt_check_call: (record, call-shape)   |
      |                  -> OK|arity|type|...    |
      +---------------------+--------------------+
                            |
                            v  typed predicate refs
      +------------------------------------------+
      | R226.M3  bottom-up semi-naive evaluator  |
      +------------------------------------------+
```

R226.M1 lands the datalog parser — a byte-walker that emits a flat
array of 48-byte `Clause` records keeping each head term as a raw
`(byte_offset, byte_len)` span over the caller's input. The parser is
deliberately UNTYPED: it does not know which predicates have been
declared, their arity, or the per-position type each call must
satisfy. R226.M2 (this module) closes that gap WITHOUT touching the
R226.M1 parser's surface — the two layers are composed by the caller
(the shell's datalog elaborator; R226.M3 or an adjacent landing).

## 2. Record layout — 64 bytes per PredicateRecord

| offset | size | field              | contents                                      |
|-------:|-----:|--------------------|-----------------------------------------------|
|      0 |    4 | `magic`            | u32 — `'PRTY'` little-endian = `0x59545250`.  |
|      4 |    2 | `arity`            | u16 — `0..PT_MAX_ARITY (= 32)`.               |
|      6 |    2 | `flags`            | u16 — bit 0 `PT_FLAG_USER_DEFINED`.           |
|      8 |    8 | `name_hash`        | u64 — FNV-1a 64 of the name bytes.            |
|     16 |   16 | `name_inline`      | ASCII identifier, zero-padded to 16 bytes.    |
|     32 |   32 | `arg_type_codes`   | u8[32] — SchemasSig type codes per argument.  |

Total: **64 bytes**, aligned to 8. Stride is a power of two so pool
addressing uses `shl rN, 6` — never 2-op `imul r, imm`
(`feedback_pdx_encoder_pitfalls`).

### 2.1 Stride reconciliation note

The parent brief listed the record as "Record 48B" but then specified
field offsets up to `0x40` (= 64 decimal) with
`u8[32] arg_type_codes at 0x20..0x40` AND stated an arity cap of 32.
The two constraints together are only satisfiable at **stride 64**,
not stride 48: an 8-byte-header + 16-byte-inline-name + 32-byte-per-
argument-code record cannot fit in 48 bytes. This landing honours
the field-offset AND arity-cap commitments (both externally
observable) at the cost of a 16-byte widening on the stride constant,
which bumps the pool footprint from the brief's implied 6144 B to
8192 B. The 48 B hint in the brief is treated as a transcription slip.

### 2.2 Type-code set

`arg_type_codes[i]` carries one of eleven codes:

| code | mnemonic           | source                   | meaning                       |
|-----:|--------------------|--------------------------|-------------------------------|
|    1 | `SS_TYPE_U64`      | R222.M1 SchemasSig       | 64-bit unsigned integer.      |
|    2 | `SS_TYPE_I64`      | R222.M1                  | 64-bit signed integer.        |
|    3 | `SS_TYPE_STR`      | R222.M1                  | NFC-form UTF-8 string.        |
|    4 | `SS_TYPE_HEX`      | R222.M1                  | hex-literal (0x…) u64 slot.   |
|    5 | `SS_TYPE_HASH32`   | R222.M1                  | 32-bit identity hash in u64.  |
|    6 | `SS_TYPE_TSC`      | R222.M1                  | TSC timestamp u64.            |
|    8 | `SS_TYPE_PATH`     | R222.M1                  | pdxfs path handle.            |
|    9 | `SS_TYPE_PID`      | R222.M1                  | 8-byte PID.                   |
|   10 | `PT_TYPE_VAR`      | R226.M2 (THIS)           | Datalog variable (`X`).       |
|   11 | `PT_TYPE_WILD`     | R226.M2 (THIS)           | underscore placeholder (`_`). |

Codes 0 (`SS_TYPE_END`) and 7 (reserved `SF_TYPE_IMAGE` slot) are
explicitly disallowed as `arg_type_codes[i]` inputs — the module
returns `PT_ERR_BAD_TYPE_CODE` on either.

`PT_TYPE_VAR` and `PT_TYPE_WILD` are parser-tier extensions that only
appear on the datalog-call side (either expected or actual). They do
NOT appear in a schema-registry declaration.

## 3. Pool — singleton `.bss`

```
_pt_predicates      : [u8; 8192]  @align(8)   // 128 slots × 64 B.
_pt_predicate_count : u64          @align(8)
_pt_init_state      : u64          @align(8)
```

The pool is a **dense array** — slot `i` lives at offset `i * 64` from
the base. Lookup is a **linear scan** over `0..n` with early exit on
`name_hash` match. A dense pool trades asymptotic lookup cost for:

- No open-addressing collisions / tombstones to reason about.
- No rehash step at a growth threshold.
- One-pass serialisation to the kernel-side schema registry wire
  format (R220.M4) when that lands.
- Cache-friendly iteration order: every slot occupied up to `count`,
  slots past `count` zero.

A linear scan over 128 × 64 B of hot cache is roughly 10 ns on T14
Gen 4 (two L1-dcache lines per slot, no indirection). Datalog
elaboration happens O(programs) times per shell turn — well below
the point where an open-addressed hash table pays its own complexity.

If production call-rates ever outgrow the linear scan, an M2.1+
landing may introduce an open-addressed hash table **without an
API break** (callers only see record pointers and error codes).

## 4. Public API

```
_pt_init() -> ()
_pt_register(name_ptr, name_len, arity, arg_types_ptr, flags) -> errno
_pt_lookup(name_ptr, name_len, out_record_ptr) -> errno
_pt_check_call(predicate_record, actual_args_ptr,
               actual_n_args, actual_type_codes) -> status
```

### 4.1 `_pt_init`

Zero-fills the 8192-byte pool, clears the counter, marks the state
flag initialised. **Idempotent** — a second call is a bare `ret` via
the sentinel check. Pure leaf.

### 4.2 `_pt_register`

Register a predicate. On a duplicate `name_hash`, this call is a
**no-op** returning `PT_OK` — the auto-register path on body atoms
is idempotent by design because the same predicate name appears many
times in a program.

Guards (in order):
1. `name_ptr != 0` → else `PT_ERR_BAD_PTR` (`0x6400`).
2. `name_len in [1..16]` → else `PT_ERR_BAD_NAME` (`0x6401`).
3. `arity <= 32` → else `PT_ERR_BAD_ARITY` (`0x6402`).
4. If `arity > 0`: `arg_types_ptr != 0` → else `PT_ERR_BAD_PTR`.
   For each `i`, `arg_types_ptr[i] in {1..6, 8..11}` → else
   `PT_ERR_BAD_TYPE_CODE` (`0x6404`).
5. Lazy-init (`call _pt_init`).
6. `name_hash = FNV-1a 64(name_ptr, name_len)` (`call _pt_fnv1a64`).
7. Linear-scan existing records; on `name_hash` match return `PT_OK`.
8. If `_pt_predicate_count == 128` → `PT_ERR_POOL_FULL` (`0x6403`).
9. Allocate slot `[_pt_predicate_count]`; zero-fill 64 bytes; stamp
   magic, arity, flags, name_hash, name_inline (zero-padded),
   arg_type_codes (zero-padded past arity).
10. Bump `_pt_predicate_count`.

### 4.3 `_pt_lookup`

Look up a predicate by name. On hit, byte-copies the 64-byte record
into `out_record_ptr`. On miss, writes **64 zero bytes** at
`out_record_ptr` (defensive — a miss still returns a well-defined
record so a caller that reads `out_record_ptr->magic` after a miss
sees `0`, not stack garbage) and returns `PT_ERR_UNKNOWN_PREDICATE`
(`0x6412`) = `E0902`.

### 4.4 `_pt_check_call`

Validate a call site's arity + per-position type codes against the
predicate's resolved signature.

```
expected_arity = record.arity
actual_arity   = actual_n_args
if expected_arity != actual_arity:
    return PT_ERR_ARITY_MISMATCH    # E0900

for i in 0..expected_arity:
    expected = record.arg_type_codes[i]
    actual   = actual_type_codes[i]
    if expected in {PT_TYPE_VAR, PT_TYPE_WILD}: continue
    if actual   in {PT_TYPE_VAR, PT_TYPE_WILD}: continue
    if expected == actual: continue
    return PT_ERR_TYPE_MISMATCH     # E0901

return PT_OK
```

The `actual_args_ptr` argument is OPAQUE at R226.M2 — kept in the
signature so that an R226.M3+ landing can attach per-position source
spans (via a parallel array of Clause.term_offsets) to each type-
mismatch diagnostic without an ABI break.

### 4.5 Compatibility rule

The compatibility rule is **symmetric**: a wildcard on either side
matches. This is a conscious trade-off:

- `PT_TYPE_VAR` on the expected side admits a predicate whose
  signature declaration leaves one position open to any ground
  type — rare in practice but needed for schema-registry declarations
  that model polymorphic observers (e.g. `exit_nonzero(X : var)`).
- `PT_TYPE_VAR` on the actual side admits a call site that passes a
  Datalog variable (`parent(X, bob)`), which must match the
  predicate's ground type at that position.
- `PT_TYPE_WILD` on either side admits the datalog `_` placeholder.

At M2.2 the compatibility rule may be TIGHTENED (expected-side
wildcard removal) once the schema-registry wire format forbids
polymorphic positions. The public API is stable across that change.

## 5. Status taxonomy — band `0x6400..0x64FF`

| code     | mnemonic                     | diagnostic family |
|---------:|------------------------------|-------------------|
|      `0` | `PT_OK`                      | —                 |
| `0x6400` | `PT_ERR_BAD_PTR`             | —                 |
| `0x6401` | `PT_ERR_BAD_NAME`            | —                 |
| `0x6402` | `PT_ERR_BAD_ARITY`           | —                 |
| `0x6403` | `PT_ERR_POOL_FULL`           | —                 |
| `0x6404` | `PT_ERR_BAD_TYPE_CODE`       | —                 |
| `0x6410` | `PT_ERR_ARITY_MISMATCH`      | **E0900**         |
| `0x6411` | `PT_ERR_TYPE_MISMATCH`       | **E0901**         |
| `0x6412` | `PT_ERR_UNKNOWN_PREDICATE`   | **E0902**         |
| `0x6413` | `PT_ERR_BAD_RECORD`          | —                 |

Slots `0x6405..0x640F` reserved for M2.1+ register/lookup
diagnostics; `0x6414..0x64FF` reserved for M2.2+ check-call
diagnostics (per-position subsumption rule refinement,
implicit-coercion warn-level, open-world unknown-predicate relax).

Band `0x6400..0x64FF` sits directly above:

- `0x6100..0x61FF` R225.M9 proptest_hm (landed Wave 132).
- `0x6200..0x62FF` R227.M6 version_pragma (landed Wave 132).
- `0x6300..0x63FF` reserved for the parallel R225.M10 arm (not
  yet landed).

The next kilo-step band `0x6500..0x65FF` is R227.M7 ScriptCache
(landed in the same parallel-arm set as this R226.M2 landing).

## 6. Interactions

### R226.M1 Datalog parser

The caller feeds `_dl_parse` output's per-head and per-body-atom
predicate name spans into `_pt_register` / `_pt_lookup`. **No direct
call from this module into `datalog.pdx`** — the parser is pure and
the stitching happens one layer up. This is deliberate: the R226.M3
evaluator will drive the composition over its own fixpoint loop.

### R222.M1 SchemasSig

The `SS_TYPE_*` codes 1..9 are reused verbatim as the first eight
positions of the `PT_TYPE_CODE_MAX` set. A schema-registry
declaration (R220.M4+) that uses a SchemasSig field descriptor can
feed its `field_type` byte into `_pt_register`'s `arg_types_ptr`
array with no translation.

### R220.M4 Schema registry (kernel-side; NOT yet landed)

At R226.M2 the registry wire-up is **deferred**: there is no live
kernel-side predicate catalogue yet. The elaborator is expected to
AUTO-REGISTER every predicate on first-use, stamping
`PT_FLAG_USER_DEFINED` on the record. The post-R220.M4 landing will
add a startup pass that pre-registers kernel-known predicates with
their SchemasSig type codes (and clears `PT_FLAG_USER_DEFINED`). The
public API is stable across that change.

### R225.M3 HM Datalog bridge

Deferred. R225.M3 (not yet landed) will layer the HM type-graph
over this module's PredicateRecord: a predicate position typed
`SS_TYPE_U64` here will bridge to `HM_CON_U64` in `hm_core`'s
TyCon registry. This module stays agnostic to the bridge — the
HM pool is a separate .bss region owned by `hm_core.pdx`.

## 7. Forward path

| milestone  | content                                                               |
|------------|-----------------------------------------------------------------------|
| R226.M2.1  | Open-world catalogue: `PT_FLAG_OPEN_WORLD` bit distinguishes          |
|            | "declared but never used" from "used before declared".                |
| R226.M2.2  | Subsumption rule: `PT_TYPE_HASH32` subsumes `PT_TYPE_U64` at calls.   |
| R226.M3    | Bottom-up semi-naive evaluator — consumes `_pt_lookup` and            |
|            | `_pt_check_call` as the type-arrival gate.                            |
| R226.M9    | Query-time type-check — per-query planner emits E09NN diagnostics.    |
| R220.M4    | Schema-registry wire-up — startup pass pre-registers kernel-known.    |
| R225.M3    | HM Datalog bridge — layered on top of this module's records.          |

## 8. 30-test corpus (acceptance anchor)

The acceptance clause for R226.M2 is a **30-test corpus** that drives
`_pt_register` / `_pt_lookup` / `_pt_check_call` through its full
decision table. The corpus itself lands as a satellite under
`tests/shell/predicate-types/` — deferred to R226.M2.3 along with
the AFL++ shim (same raw-vs-corpus split as R221.M7 FuzzHarness and
R225.M9 ProptestHm). The 30 cases enumerated for the corpus are:

**Group A — register (10 cases):**

| # | input                                                           | result                   |
|---|-----------------------------------------------------------------|--------------------------|
| 1 | `register("parent", 6, 2, [STR, STR], USER)`                    | `PT_OK` + slot 0 filled. |
| 2 | re-`register("parent", 6, 2, [STR, STR], USER)`                 | `PT_OK` (idempotent).    |
| 3 | `register("exit_nonzero", 12, 1, [U64], USER)`                  | `PT_OK` + slot 1 filled. |
| 4 | `register("fact", 4, 5, [U64, HASH32, TSC, TSC, I64], 0)`       | `PT_OK` + slot 2 filled. |
| 5 | `register("", 0, 0, 0, 0)`                                      | `PT_ERR_BAD_NAME`.       |
| 6 | `register("x", 1, 33, 0, 0)`                                    | `PT_ERR_BAD_ARITY`.      |
| 7 | `register("x", 1, 1, 0, 0)`                                     | `PT_ERR_BAD_PTR`.        |
| 8 | `register("x", 1, 1, [7], 0)` (reserved IMAGE)                  | `PT_ERR_BAD_TYPE_CODE`.  |
| 9 | `register("x", 1, 1, [12], 0)` (past PT_TYPE_CODE_MAX)          | `PT_ERR_BAD_TYPE_CODE`.  |
|10 | 128 unique names registered → 129th                             | `PT_ERR_POOL_FULL`.      |

**Group B — lookup (10 cases):**

| #  | input                                            | result                        |
|----|--------------------------------------------------|-------------------------------|
| 11 | `lookup("parent", 6, &rec)`                      | `PT_OK` + rec matches slot 0. |
| 12 | `lookup("not_there", 9, &rec)`                   | `PT_ERR_UNKNOWN_PREDICATE`.   |
| 13 | `lookup(0, 6, &rec)`                             | `PT_ERR_BAD_PTR`.             |
| 14 | `lookup("x", 1, 0)`                              | `PT_ERR_BAD_PTR`.             |
| 15 | `lookup("", 0, &rec)`                            | `PT_ERR_BAD_NAME`.            |
| 16 | `lookup("x" * 17, 17, &rec)`                     | `PT_ERR_BAD_NAME`.            |
| 17 | lookup after 50 registers — scan terminates     | O(50) scan, correct record.   |
| 18 | lookup miss leaves `rec` zero-filled             | `rec.magic == 0`.             |
| 19 | lookup hit's rec.magic                           | `== 0x59545250` ('PRTY').     |
| 20 | lookup hit's name_inline                         | zero-padded past name_len.    |

**Group C — check_call (10 cases):**

| #  | input                                                           | result                       |
|----|-----------------------------------------------------------------|------------------------------|
| 21 | call `parent(STR, STR)` vs `parent/2 (STR, STR)`                | `PT_OK`.                     |
| 22 | call `parent(STR)` vs `parent/2`                                | `PT_ERR_ARITY_MISMATCH`.     |
| 23 | call `parent(U64, STR)` vs `parent/2 (STR, STR)`                | `PT_ERR_TYPE_MISMATCH`.      |
| 24 | call `parent(VAR, STR)` vs `parent/2 (STR, STR)`                | `PT_OK` (actual wildcard).   |
| 25 | call `parent(STR, WILD)` vs `parent/2 (STR, STR)`               | `PT_OK` (actual wildcard).   |
| 26 | call `parent(STR, STR)` vs record whose magic was zeroed        | `PT_ERR_BAD_RECORD`.         |
| 27 | call with `predicate_record == 0`                               | `PT_ERR_BAD_PTR`.            |
| 28 | call with `actual_n_args > 0` and `actual_type_codes == 0`      | `PT_ERR_BAD_PTR`.            |
| 29 | call `fact(U64, HASH32, TSC, TSC, I64)` vs `fact/5` (same)      | `PT_OK`.                     |
| 30 | call `fact(U64, HASH32, TSC, TSC, I64, I64)` vs `fact/5`        | `PT_ERR_ARITY_MISMATCH`.     |

The 30-test corpus is the acceptance anchor the parent brief
specified; the raw M2 landing delivers the harness surface
(`_pt_*` entry points) that the corpus will drive. Corpus itself
lands at M2.3.

## 9. paideia-as encoder discipline

Standard parser-tier lesson set (`feedback_pdx_encoder_pitfalls`):

- No `test rN, rN` — every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64` — flags u16 mask uses `shl r, 48; shr r, 48`.
- No 2-op `imul r, imm` — 64-byte stride is `shl r, 6`; FNV-1a 64
  uses `mul rcx` (one-op unsigned mul).
- No multiline `pub let = "..."` — single-line justifications.
- Module basename `PredicateTypes` matches `predicate_types.pdx`.
- Labels prefixed `pt_` (unique against every landed parser-tier
  label prefix). Per-function suffix: `pt_ini_`, `pt_reg_`, `pt_lk_`,
  `pt_cc_`, `pt_fnv_`.
- All `cmp reg, imm` immediates fit imm32 with bit 31 clear.
- Byte loads via `xor r,r; mov_b r,[addr + idx * 1]` (explicit `*1`
  per libpdx-pds-parser Pipeline + libpdx-audit precedent).
- u32 stores via `mov_d`; u16 stores via two `mov_b` byte stores;
  u8 stores via `mov_b [dst], rN`.
- Cross-module `.bss` writes via `lea r11, [rip + sym]; mov [r11], rax`.
- No three-term addressing — every `[base + idx + disp]` precomputes
  address via `mov r10, base; add r10, idx; add r10, disp;
  mov_b dst, [r10]`.
- `_pt_fnv1a64` and `_pt_check_call` are pure leaves (zero pushes;
  no stack frame; no nested CALL).
- `_pt_init` is a pure leaf.
- `_pt_register` and `_pt_lookup` each hold a 6-push callee-save frame
  + `sub rsp, 32` / `sub rsp, 8` pad for `rsp%16==0` at every nested
  CALL into `_pt_init` and `_pt_fnv1a64`.

## 10. Register-liveness

Per the lessons from `feedback_pdx_encoder_pitfalls` and the Wave 132
debugger patch that moved `_pth_generate`'s byte-copy source pointer
off `r12`:

- Every value that must survive a nested CALL lives in `rbx..r15`
  (callee-save) or on the stack frame.
- `r11` is clobbered by every nested CALL — the module reloads
  `_pt_predicates`, `_pt_predicate_count`, and `_pt_init_state` via
  `lea r11, [rip + sym]` inside each loop body.
- Scratch-frame slots store `slot_idx`, `i`, and `entry_addr` across
  the nested CALLs in `_pt_register`.

## 11. Cross-references

- `design/shell/datalog-parser.md` — the parser R226.M2 consumes.
- `design/shell/cmd-functor-schemas-sig.md` — the SS_TYPE_* codes
  this module reuses.
- `design/shell/hm-algorithm-w-core.md` — the type-graph the eventual
  R225.M3 bridge will connect to.
- `design/terminal/semantic-shell-language-plan.md` — the §R226
  umbrella.
- `feedback_pdx_encoder_pitfalls` — the encoder-discipline lessons.
- `feedback_paideia_as_reserved_labels` — the reserved-keyword set.
