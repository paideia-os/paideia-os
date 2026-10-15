# Datalog semi-naive evaluator (R226.M3)

**Status:** v0.1 (R226.M3 — paideia-os#2694)
**Date:** 2026-10-15
**Author:** softarch (Wave UMB-R226)
**Scope:** The user-space parser-tier primitive that drives the
bottom-up semi-naive fixpoint over the EDB / IDB fact store the
R226.M1 parser + R226.M2 predicate-type resolver feed. Lands in
`libpdx-pds-parser` at
`tools/user/libpdx-pds-parser/src/datalog_eval.pdx` (module
`DatalogEval`).

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
      | R226.M2  PredicateTypes::_pt_*           |
      +---------------------+--------------------+
                            |
                            v  typed predicate refs
      +------------------------------------------+
      | R226.M3  DatalogEval::_de_* (THIS)       |
      +---------------------+--------------------+
                            |
                            v  derived facts
      +------------------------------------------+
      | R226.M4+  magic-set rewriting, strat.    |
      |           negation, aggregation, ...     |
      +------------------------------------------+
```

The evaluator is caller-driven: the elaborator (owned by R226.M3+ or
an adjacent landing) walks R226.M1's Clause array; for each **Fact**
it classifies the term values via R226.M2's type codes and calls
`_de_add_fact`; for each **Rule** it stashes the body span via
`_de_add_rule`; and once the program is loaded calls
`_de_run_fixpoint` to drive the semi-naive loop to a stable IDB.
Queries are served by `_de_query`.

## 2. Semi-naive evaluation (standard Datalog literature)

Classical semi-naive evaluation (Abiteboul–Hull–Vianu, *Foundations
of Databases*, chap. 13; Bancilhon–Ramakrishnan, "Amateur's
Introduction to Recursive Query Processing Strategies", SIGMOD 1986)
keeps two fact sets per predicate:

| set    | contents                                              |
|--------|-------------------------------------------------------|
| IDB    | all facts derived so far (including the EDB seeds)    |
| delta  | facts newly derived in the LAST round only            |

Each round, for every rule `R = H :- B1, B2, ..., Bk`, the join

```
    (delta_B1 join IDB_B2 join ... join IDB_Bk)
  UNION
    (IDB_B1 join delta_B2 join IDB_B3 join ... join IDB_Bk)
  UNION
  ...
    (IDB_B1 join IDB_B2 join ... join delta_Bk)
```

is computed and the head-instantiated results that are not already in
IDB are added to a NEW delta. At the end of the round the new delta
is merged into IDB and promoted to the current delta. The fixpoint is
reached when the new delta is empty.

**Why "semi-naive" and not "naive":** the naive variant recomputes
every rule's full body-join against the full IDB each round, so each
previously-derived fact is re-derived once per round. Semi-naive
constrains the join to require AT LEAST one body-atom match from the
delta, which turns the round-cost into O(|delta|) rather than O(|IDB|)
— the standard asymptotic win on recursive queries (transitive
closure, same-generation, reachability).

## 3. Raw-M3 landing — scaffolding + storage, stub rule-firing

This module lands:

- The 64-byte Fact record format + 1024-slot IDB pool + 256-slot
  delta pool (both `.bss`, both `@align(8)`, both power-of-two slot
  strides so pool addressing uses `shl idx, 6`).
- The 32-byte Rule record format + 64-slot rule pool (`.bss`,
  `@align(8)`, `shl idx, 5` addressing).
- The five public entry points `_de_init`, `_de_add_fact`,
  `_de_add_rule`, `_de_run_fixpoint`, `_de_query` — their full ABI
  surface, their validation flow, and their status-code taxonomy.
- Three internal helpers: `_de_fnv1a64` (FNV-1a 64 hash;
  byte-for-byte mirror of the sibling parser-family FNV leaves),
  `_de_fact_eq` (eight-u64 compare of two Fact records),
  `_de_find_fact_in_idb` (linear scan + fact-equality dispatch).
- The semi-naive LOOP SHAPE in `_de_run_fixpoint` with a stub
  `_de_fire_rules_round` helper that reports "0 new facts derived"
  so the fixpoint converges in exactly one round for any initial
  fact set.

The non-trivial rule-firing lands in **R226.M3.1** behind the same
`_de_fire_rules_round` symbol — the public ABI
(`_de_run_fixpoint(out_round_count, out_fact_count) -> status`) is
stable across that extension. See §9 for the forward path.

### 3.1 Why this split

Three forces push the real join engine out of the raw-M3 landing:

1. **Body-span re-parse.** The rule-firing step needs to re-split a
   rule's body span into per-atom term vectors — a non-trivial walk
   through the body's `atom(T1, T2, ..., Tn), ...` structure that
   requires calling into R226.M1 `_dl_scan_body` and a (not yet
   extracted) per-atom helper.
2. **Per-position type check.** Each derived head must be filtered
   via R226.M2 `_pt_check_call` before admission to the new delta;
   that's a nested CALL per derived fact.
3. **40-test corpus.** The acceptance anchor on the ticket is
   "Standard Datalog test suite passes" (ancestor, reachability,
   transitive closure, same-generation). That corpus is 40+ tests,
   each a program-plus-expected-output pair; the appropriate landing
   target for that corpus is M3.2 (companion to M3.1), not folded
   into the primitive landing.

The raw-M3 landing keeps the public ABI frozen so the M3.1 extension
can swap in the real join engine without touching this module's
callers (R226.M4+ magic-set rewriter, R226.M11 per-query
fingerprint).

## 4. Fact record — 64 bytes

| offset | size | field               | contents                                        |
|-------:|-----:|---------------------|-------------------------------------------------|
|    0   |   4  | `magic`             | u32 — `'DFCT'` LE = `0x54434644`.               |
|    4   |   2  | `predicate_idx`     | u16 — 0..0xFFFF.                                |
|    6   |   2  | `arity`             | u16 — 0..`DE_MAX_ARITY` (= 8).                  |
|    8   |   8  | `arg_hash`          | u64 — FNV-1a 64 over the packed argument span.  |
|   16   |  48  | `arg_values_inline` | u8[48] — packed (type_code + raw bytes per arg).|

Total: **64 B** (`DE_FACT_BYTES`). Stride is a power of two so pool
addressing uses `shl idx, 6` — never 2-op `imul r, imm`
(`feedback_pdx_encoder_pitfalls`).

The `arg_values_inline` block is a byte-copy of the caller-supplied
packed-arg buffer, zero-padded past `arg_values_len`. Max arity 8 at
raw M3 (max 6 B per arg → 48 B). The 6-byte-per-arg budget comfortably
holds `(type_code u8, u32 inline value)` for the common type codes
and `(type_code u8, u8 reserved, u32 ref)` for the string / path / hex
codes.

## 5. Rule record — 32 bytes

| offset | size | field                 | contents                                        |
|-------:|-----:|-----------------------|-------------------------------------------------|
|    0   |   4  | `magic`               | u32 — `'DRUL'` LE = `0x4C555244`.               |
|    4   |   2  | `head_predicate_idx`  | u16.                                            |
|    6   |   2  | `n_body_atoms`        | u16 — 0 at raw M3 (M3.1 populates via re-parse).|
|    8   |   8  | `body_ptr`            | u64 — opaque into caller's buffer.              |
|   16   |   8  | `body_len`            | u64.                                            |
|   24   |   2  | `head_arity`          | u16 — 0..`DE_MAX_ARITY`.                        |
|   26   |   2  | `flags`               | u16 — reserved for M3.1 open-world / recursive. |
|   28   |   4  | `_reserved`           | u32 — zeroed; M3.1+ reserved.                   |

Total: **32 B** (`DE_RULE_BYTES`). Stride is a power of two so pool
addressing uses `shl idx, 5`.

The body span is **not copied** into the module — the caller owns the
backing bytes (precedent: R226.M1 parser stores
`Clause.body_offset` as an offset into the caller's buffer).

## 6. Pool — singleton `.bss`

```
_de_idb_facts     : [u8; 65536]   = uninit @align(8)   // 1024 * 64 B
_de_delta_facts   : [u8; 16384]   = uninit @align(8)   //  256 * 64 B
_de_rules         : [u8;  2048]   = uninit @align(8)   //   64 * 32 B
_de_idb_count     : u64           = uninit @align(8)
_de_delta_count   : u64           = uninit @align(8)
_de_rule_count    : u64           = uninit @align(8)
_de_round_count   : u64           = uninit @align(8)   // cumulative
_de_init_state    : u64           = uninit @align(8)   // 0 / 1
```

Total `.bss` footprint: **83,968 B** (65536 + 16384 + 2048 + 5·8).

Pool-full behaviour: IDB full → `DE_ERR_FACT_POOL_FULL`; delta full →
`DE_ERR_DELTA_POOL_FULL`; rules full → `DE_ERR_RULE_POOL_FULL`.
A fresh-session scrub via `_de_init` resets every pool and counter.
`_de_init_state` is a sentinel so the four entry points can lazy-init
without a boot-time orchestration hook.

### 6.1 Why 1024 / 256 / 64

The pool sizing reconciles three forces:

1. **Working-set target.** The semantic-shell's history-facts ring
   holds 128 facts per session (R127.M7); the R226 evaluator's
   working set across a single interactive datalog turn rarely
   exceeds a few hundred facts. 1024 IDB slots is 8× the base
   working set — enough headroom for standard
   transitive-closure-style queries over the ring without
   overflow.
2. **Delta capacity.** For a well-behaved recursive query, round N's
   delta is at most |new facts derived in round N| which is bounded
   by the join cardinality. 256 slots covers the standard
   transitive-closure benchmarks (reachability over a graph with
   ≤128 nodes derives ≤128·2 = 256 edges per round in the worst
   case).
3. **Rule capacity.** A standard datalog program has single-digit
   rule counts; 64 is 10× overhead.

M3.1+ callers that exceed these caps hit the explicit pool-full
status codes and can size up by swapping in a larger `.bss`
allocation at module build time.

## 7. Public API

### 7.1 `_de_init() -> ()`

Zero-fills `_de_idb_facts`, `_de_delta_facts`, `_de_rules`; clears
all counters; sets the init sentinel. Idempotent via the sentinel.
Pure leaf (no callee-save push, no stack frame, no nested CALL).

### 7.2 `_de_add_fact(predicate_idx, arity, arg_values_ptr, arg_values_len) -> errno`

- Validates `arity <= DE_MAX_ARITY` (= 8); else `DE_ERR_BAD_ARITY`.
- Validates `arg_values_len <= DE_ARG_VALUES_INLINE_BYTES` (= 48);
  else `DE_ERR_ARG_VALUES_TOO_BIG`.
- If `arg_values_len > 0`: validates `arg_values_ptr != 0`; else
  `DE_ERR_BAD_PTR`.
- Lazy-inits via `_de_init`.
- Builds a 64 B scratch Fact on-stack (magic / predicate_idx /
  arity / arg_hash from `_de_fnv1a64` / byte-copied arg_values).
- Linear-scans IDB via `_de_find_fact_in_idb`; on hit returns
  `DE_OK` (idempotent re-insert).
- Pool-full checks (IDB → `DE_ERR_FACT_POOL_FULL`; delta →
  `DE_ERR_DELTA_POOL_FULL`).
- Appends scratch to IDB at slot `_de_idb_count`; appends to delta
  at slot `_de_delta_count`; bumps both counters.

Frame: 6 callee-save pushes + `sub rsp, 72` scratch (64 B staged
Fact + 8 B align pad). `rsp%16==0` at every nested CALL.

### 7.3 `_de_add_rule(body_ptr, body_len, head_predicate_idx, head_arity) -> errno`

- Validates `body_ptr != 0` (`DE_ERR_BAD_PTR`), `body_len > 0`
  (`DE_ERR_ZERO_LEN`), `head_arity <= 8` (`DE_ERR_BAD_ARITY`).
- Lazy-inits via `_de_init`.
- Pool-full check (`DE_ERR_RULE_POOL_FULL`).
- Stamps a 32 B Rule record at
  `_de_rules + (_de_rule_count << 5)` (magic / head_predicate_idx /
  0 n_body_atoms / body_ptr / body_len / head_arity / 0 flags / 0
  reserved).
- Bumps `_de_rule_count`.

The body span is NOT copied — the caller retains ownership of the
backing bytes.

### 7.4 `_de_run_fixpoint(out_round_count, out_fact_count) -> status`

- Validates both out ptrs non-null.
- Lazy-inits.
- Loops:
  - If `_de_delta_count == 0` → break (fixpoint reached).
  - Call `_de_fire_rules_round` (M3 stub → 0 new facts).
  - Clear `_de_delta_count` to 0 (promote empty new delta).
  - Round counter += 1.
  - If round counter >= `DE_MAX_ROUNDS` (= 1024) →
    `DE_ERR_FIXPOINT_LIMIT`.
- Writes `*out_round_count` and `*out_fact_count`; bumps
  cumulative `_de_round_count`.
- Returns `DE_OK`.

At raw M3 the stub implies: `rounds == 1` on the first call after
any `_de_add_fact` sequence; `rounds == 0` on a repeat call with
no new adds. M3.1+ replaces the stub with the real join engine; the
public ABI is stable.

### 7.5 `_de_query(predicate_idx, out_facts, out_cap) -> packed_u64`

- Validates `out_facts != 0` (`DE_ERR_BAD_PTR`) and
  `out_cap >= 64` (`DE_ERR_OUT_TOO_SMALL`).
- Lazy-inits.
- `max_facts = out_cap >> 6`.
- Masks `predicate_idx` to low 16 via a shift pair.
- Linear scans IDB; copies each matching 64 B Fact into
  `out_facts + (n_written << 6)`; stops when `n_written == max_facts`
  or the scan exhausts.
- Returns `(n_written << 32) | DE_OK` on success; `(0 << 32) | <err>`
  on validation failure.

## 8. Status taxonomy — band `0x6700..0x67FF`

```
DE_OK                      = 0        operation succeeded.
DE_ERR_BAD_PTR             = 0x6700   NULL pointer where non-NULL required.
DE_ERR_BAD_ARITY           = 0x6701   arity > DE_MAX_ARITY (= 8).
DE_ERR_BAD_PREDICATE       = 0x6702   reserved for M3.1+ strict-idx check.
DE_ERR_FACT_POOL_FULL      = 0x6703   _de_idb_count == DE_IDB_SLOTS (= 1024).
DE_ERR_DELTA_POOL_FULL     = 0x6704   _de_delta_count == DE_DELTA_SLOTS (= 256).
DE_ERR_RULE_POOL_FULL      = 0x6705   _de_rule_count == DE_RULE_SLOTS (= 64).
DE_ERR_ARG_VALUES_TOO_BIG  = 0x6706   arg_values_len > 48.
DE_ERR_ZERO_LEN            = 0x6707   body_len == 0 on add_rule.
DE_ERR_NOT_INIT            = 0x6708   reserved for M3.1+ strict-init check.
DE_ERR_FIXPOINT_LIMIT      = 0x6709   run_fixpoint hit DE_MAX_ROUNDS.
DE_ERR_OUT_TOO_SMALL       = 0x670A   query: out_cap < 64.
```

Slots `0x670B..0x67FF` reserved for M3.1+ evaluator diagnostics
(predicate-not-registered, type-mismatch at rule-firing, body-span
re-parse syntax error, aggregator division-by-zero, etc.).

The `0x6700..0x67FF` carve-out sits directly above R227.M7 ScriptCache
(`0x6500..0x65FF`, landed) and skips the parallel-arm `0x6600..0x66FF`
slice held for the sibling R225.M5 cross-context type-flow arm.

Grep confirmation at R226.M3 landing time:

```
grep -rE '0x67[0-9A-F]{2}' tools/user/libpdx-pds-parser/
  -> hits only in src/datalog_eval.pdx, design/shell/datalog-semi-naive.md,
     caps.decl, STATUS.md, and the parallel R226M3 scratch CHANGELOG.
```

## 9. Forward path

| milestone  | content                                                                 |
|------------|-------------------------------------------------------------------------|
| R226.M3.1  | Rule-firing semantics inside `_de_fire_rules_round`: for each rule, re-parse the body span via R226.M1 `_dl_scan_body`; split into per-atom term vectors; drive delta-per-position join; filter derived heads via R226.M2 `_pt_check_call`; admit novel heads to new_delta + IDB. |
| R226.M3.2  | 40-test standard Datalog corpus (ancestor / reachability / same-generation / transitive closure); the acceptance anchor on this issue. |
| R226.M3.3  | Perf baseline: ≥1M facts/sec selective (per the acceptance). The baseline is measured against the M3.2 corpus with the M3.1 join engine; a sub-baseline M3.3.1 looks at the hash-join vs nested-loop constant factors. |
| R226.M4    | Magic-set rewriting: a pre-pass that rewrites rules against a goal-directed query plan. |
| R226.M5    | Stratified negation.                                                    |
| R226.M6    | Aggregation library.                                                    |
| R226.M7    | Typed-graph effect: EDB-materialising predicate signatures tied to the pdxfs graph substrate. |
| R226.M11   | Per-query fingerprint: consumes `_de_run_fixpoint` round / fact counts and emits `dlg.<query-id>.<n_results>` via the TurnFingerprint / CheckFingerprint pattern. |

## 10. paideia-as encoder discipline

- **No `test rN, rN`** — every zero-check is `cmp reg, 0`.
- **No `and rN, imm64`** — the one mask (low-16 isolate on
  `predicate_idx` in `_de_query`) uses a `shl 48 / shr 48` pair.
- **No 2-op `imul r, imm`** — fact stride is `shl r, 6`; rule
  stride is `shl r, 5`; the FNV helper uses the one-op `mul rcx`
  form.
- **No multiline `pub let = "..."`** — every justification is
  single-line.
- **Module basename** `DatalogEval` matches `datalog_eval.pdx`.
- **Label prefix** `de_` with per-function suffix (`de_ini_` init,
  `de_fnv_` FNV, `de_feq_` fact-equality, `de_ff_` find-fact,
  `de_af_` add-fact, `de_ar_` add-rule, `de_fr_` fire-rules,
  `de_rf_` run-fixpoint, `de_q_` query). Grep-confirmed virgin
  across `tools/user/libpdx-pds-parser/src/*.pdx`. Also disjoint
  from the paideia-as reserved-keyword set (`loop`, `if`, `let`,
  `fn`, `ret`, `done`).
- **All `cmp reg, imm` immediates** (0, 1, 2, 8, 16, 32, 48, 56,
  64, 256, 1024, 2048, 16384, 65536, 0xFFFF, magic 0x54434644,
  magic 0x4C555244, status 0x6700..0x670A) fit imm32 with bit 31
  clear so direct `cmp-imm32` is sign-safe.
- **Byte loads** via `xor rN,rN; mov_b rN,[addr + idx * 1]`.
- **u32 stores** via `mov_d`; **u16 stores** via two `mov_b` (low,
  high); **u64 stores** via plain `mov [dst], rax`.
- **The `-1` sentinel** returned by `_de_find_fact_in_idb` on miss
  loads via `mov rax, -1` (REX.W+MOV imm64); the comparison in
  `_de_add_fact` stages it into a scratch register and does a
  register-to-register compare (direct `cmp rN, -1` with
  bit-31-set immediate is sign-extension-unsafe).

## 11. Register-liveness

- `_de_fnv1a64`: holds `rax` (hash), `rcx` (prime constant), `r8`
  (ptr), `r9` (len), `r10` (i), `r11` (byte). Zero callee-save.
- `_de_init`: holds `r9` (pool base), `rcx` (i), `r10` (slot addr),
  `rax` (zero / 1), `r11` (symbol address). Zero callee-save.
- `_de_fact_eq`: holds `rax` / `rcx` (compare pair). Zero
  callee-save.
- `_de_find_fact_in_idb`: 4 callee-save (`rbx`, `r12`, `r13`,
  `r14`) + `sub rsp, 8` pad.
- `_de_add_fact`: 6 callee-save (`rbx`, `rbp`, `r12`, `r13`,
  `r14`, `r15`) + `sub rsp, 72` scratch (64 B staged Fact + 8 B
  align pad).
- `_de_add_rule`: 6 callee-save + `sub rsp, 8` pad.
- `_de_fire_rules_round`: zero callee-save (pure-leaf stub).
- `_de_run_fixpoint`: 6 callee-save + `sub rsp, 8` pad.
- `_de_query`: 6 callee-save + `sub rsp, 8` pad.

Every nested CALL fires with `rsp%16==0` steady.

## 12. Cross-references

- `design/shell/datalog-parser.md` — R226.M1 parser; emits the
  Clause records this module's caller walks.
- `design/shell/predicate-type-resolution.md` — R226.M2 predicate-
  type resolver; the caller feeds its `predicate_idx` into
  `_de_add_fact` / `_de_add_rule`.
- `design/shell/history-datalog-substrate.md` — R127.M7 kernel-side
  history-facts fact store; the forward-path EDB that R226.M3.1
  materialises into the IDB pool via a per-row `_de_add_fact` burst
  at session start.
- `feedback_pdx_encoder_pitfalls` — the paideia-as encoder-discipline
  canonical reference.
