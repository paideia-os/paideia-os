# Changelog -- libpdx-pds-parser

All notable changes to this library are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) +
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.22.0] -- 2026-10-15

Wave 124: R221.M7 parser fuzz harness + R223.M3 where/filter/by
combinator parser. R222.M7 (legacy /bin/sh shim) deferred to a
dedicated user-binary wave (scope lives in src/user/, not this
satellite).

### Added

- `src/fuzz_harness.pdx` module `FuzzHarness` (R221.M7, paideia-os#2657):
  single-entry `_fh_drive(bytes, len)` survivability harness feeding
  the full parser pipeline (NFC → grapheme → ctx-lexer → pipeline /
  datalog / lambda). Error band 0x4A00..0x4A01.
- `src/filter_op.pdx` module `FilterOp` (R223.M3, paideia-os#2668):
  parses `where { |it| body }`, `filter { |it| body }`, `by expr`
  into 32B FilterOp record (magic 'FILT'); predicate stored as body
  byte span (no _ll_parse call at M3). Error band 0x4C00..0x4C09.
- `design/shell/parser-fuzz-corpus.md` (R221.M7 spec).
- `design/shell/where-filter-op.md` (R223.M3 spec).

### Changed

- `src/lib.pdx`: version 1.21.0 → 1.22.0; `LPX_PDS_PARSER_M7_READY`
  and `LPX_PDS_PARSER_R223_M3_READY` both flipped to 1; module-
  filename / upstream-issues / design-doc comments extended.
- `caps.decl`: added full 0x4A00..0x4AFF (R221.M7) and 0x4C00..0x4CFF
  (R223.M3) band sections + Wave 124 linker-dep entries.

## [1.21.0] -- 2026-10-15

Wave 123 R225.M4 arm: effect-row unification + rank-restricted
quantifier (P10) well-formedness validator. Dispatched as a solo
arm after the Wave 123 R221.M6 + R222.M6 pair at 1.20.0; the
parallel-CHANGELOG discipline consolidates this stanza at wave
close (per-primitive scratch at `.plans/scratch/CHANGELOG-R225M4.md`).
The arm touches disjoint `.bss` state (`_eu_label_scratch` 128 B),
a disjoint error band (`0x4900..0x49FF`), a disjoint label prefix
(`eu_`), and its own design doc (`design/shell/effect-row-
unification.md`) — shared surfaces are limited to the top-of-file
`lib.pdx` manifest, this CHANGELOG, and `STATUS.md`.

### R225.M4 -- EffectUnify

Effect rows obey a MONOTONE lattice: a lambda typed `!{io}` can
safely be re-typed `!{io, mem}` because adding effects is harmless
at the use-site. The typechecker needs the LEAST-UPPER-BOUND (set
union with ROW_VAR tail propagation) operation, NOT Rémy's
structural-equality pivot (which refuses to unify `!{io}` with
`!{mem}`). This landing lands the dedicated row-arithmetic entry
point `_eu_unify` plus a fold wrapper `_eu_least` and a scheme-
shape validator `_eu_check_rank` (P10 rank restriction).

### Added

- `src/effect_unify.pdx` module `EffectUnify` (R225.M4,
  paideia-os#2685): three public entry points over the shared
  R225.M2 singleton `_hm_pool`.
  - `_eu_unify(row_a, row_b) -> packed_u64` — JOIN two effect
    rows. Phase 1a walks row_a collecting packed label ids into
    `_eu_label_scratch` and notes any ROW_VAR tail; Phase 1b
    walks row_b appending past Phase 1a's count; Phase 2 builds
    the join by prepending each unique label onto a fresh
    `_rt_row_empty` or `_rt_row_var` tail, using `_rt_row_select`
    for dedup. Returns `(joined_row_ref << 32) | status`.
  - `_eu_check_rank(scheme_ptr, scheme_len) -> status` — validate
    a HmCore scheme byte stream against the P10 rank restriction.
    At M4 (single outer ∀ in the wire format): header consistency
    (`scheme_len == 8 + 4*n_bound_vars + 16*n_body_nodes`),
    `n_bound_vars <= 64`, `n_body_nodes in [1..128]`, and every
    body node's kind in `{TYVAR=1, TYCON=2, TYAPP=3, TYROW=4}`.
    Pure byte walker; no nested CALL.
    `EU_ERR_RANK_RESTRICTED_VIOLATION` reserved for the M4.1
    nested-quantifier wire-format extension.
  - `_eu_least(rows_ptr, n) -> packed_u64` — fold `_eu_unify`
    across N rows (associative + commutative, so fold order
    irrelevant). Caps `n` at `EU_MAX_JOIN_ARITY=16`.
- 128-byte .bss scratch (`_eu_label_scratch`, 32 u32 packed-
  label-id slots) for the Phase 1 raw-collect buffer. Disjoint
  from `_hm_subst_table`, `_er_parse_scratch`, `_cr_parse_scratch`.
- Error band 0x4900..0x4907 (eight slots used; 0x4908..0x49FF
  reserved for M4.1+): EU_OK (0), EU_ERR_KIND_MISMATCH (0x4900),
  EU_ERR_POOL_FULL (0x4901), EU_ERR_RANK_RESTRICTED_VIOLATION
  (0x4902 — reserved for M4.1), EU_ERR_BAD_SCHEME (0x4903),
  EU_ERR_EMPTY_ARRAY (0x4904), EU_ERR_TOO_MANY (0x4905),
  EU_ERR_ROWVAR_OCCURS (0x4906 — reserved for M4.2),
  EU_ERR_UNIFY_INCONSISTENT (0x4907 — reserved for M4.2).
- Pure in-process; no KIND surface; no external linker dependency;
  no cross-library dependency.
- Label prefix `eu_` (grep-confirmed free of linker-visible symbol
  collisions; disjoint from every sibling satellite's prefix:
  `u8n_`, `gi_`, `wp_`, `cl_`, `ast_`, `sm_`, `sch_sig_`,
  `cmd_sig_`, `fi_`, `afs_`, `cmdreg_`, `dm_`, `pl_`, `rp_`,
  `ll_`, `cc_`, `er_`, `cr_`, `ls_`, `hm_`, `rt_`, `dl_`, `se_`,
  `te_`).
- Intra-library dependency on R225.M2 RowTypes at five symbols
  (`_rt_find`, `_rt_row_empty`, `_rt_row_var`, `_rt_row_extend`,
  `_rt_row_select`) and on R225.M1 HmCore's `_hm_pool` .bss
  symbol (via `lea r11, [rip + _hm_pool]` for node-address
  computation on walked cursors).
- Reused opaque-u32 label identity contract: `_eu_unify`'s dedup
  check compares arg0 u32 directly, so it works equally for
  R224.M3 effect-labels AND R224.M4 capability-labels — the
  module is already structurally ready for the R225.M4.3
  capability-row-join parallel landing.

### Changed

- `src/lib.pdx`: flipped `LPX_PDS_PARSER_R225_M4_READY` from 0 to
  1; bumped MINOR 20 -> 21; module-filename comment extended with
  `src/effect_unify.pdx at R225.M4`; upstream-issues doc comment
  picks up `paideia-os#2685 (R225.M4 EffectUnify)`; design-doc
  comment picks up `design/shell/effect-row-unification.md`.
- `caps.decl`: added the full 0x4900..0x49FF band section (eight
  slots + reservation note + pack-shape); the R225.M4 landing
  paragraph in the per-milestone catalogue; the grep-disjointness
  confirmation line for `0x490[0-7]\b`; the full linker-dependency
  entry (intra-library deps on `_rt_find`, `_rt_row_empty`,
  `_rt_row_var`, `_rt_row_extend`, `_rt_row_select`, and the
  `_hm_pool` .bss symbol); Wave-123 band-adjacency note extended
  to mention `(status & 0xFF00) == 0x4900` effect-row-join / rank-
  check faults; R225.M2 reservation note clarified that R225.M4
  landed in a disjoint band rather than subdividing the 0x3600
  band.
- `STATUS.md`: filled in R225.M4 EffectUnify in the current-
  milestones summary; added the R225.M4 subsection with the two
  landed checklist items (`src/effect_unify.pdx`, design doc) and
  the deferred 30-test proptest harness as R225.M4-003; appended
  `effect_unify` + `effect_unify-M4.1+` rows to the error-band
  accounting table; bumped the file's `**Version:**` line to
  1.21.0.

### Design doc

- `design/shell/effect-row-unification.md`: 12 sections (scope,
  operational semantics, public API, pool-reuse, rank-restricted
  quantifiers, encoder discipline, 30-test acceptance corpus,
  error-band layout, forward path, co-landing discipline, linker
  dependencies, references). The 30-test corpus is decomposed
  into 18 `_eu_unify` tests, 8 `_eu_check_rank` tests, and 4
  `_eu_least` tests; the proptest harness is deferred to
  R225.M4.9 per the umbrella's shared R225.M9 landing.

### Compatibility

- Additive; no entry-point signature changes to R225.M1/M2.
- The three public entries follow the parser-tier packed-u64
  convention: high 32 = row_ref (0 on error), low 32 = status
  band 0x4900..0x4907.
- Pool budget: `_eu_unify` can consume up to ~17 pool slots per
  call (1 tail + up to 16 unique ROW_EXTs after dedup); the
  128-slot shared pool must have headroom at every call site.
  The typechecker driver that invokes `_eu_least` across N rows
  must plan for ~16N worst-case node consumption.

### Deferred to R225.M4.1+

- M4.1 wire-format extension landing nested-quantifier body nodes
  (new `HM_KIND_FORALL = 5` kind); `EU_ERR_RANK_RESTRICTED_VIOLATION`
  becomes reachable.
- M4.2 inner-subterm Rémy unify arm in `_eu_unify` (pivot
  bindings for `rho_a := rho_fresh` / `rho_b := rho_fresh`);
  reserves `EU_ERR_ROWVAR_OCCURS` and `EU_ERR_UNIFY_INCONSISTENT`.
- M4.3 capability-row join parallel (R224.M4 CapRow consumer).
- M4.4 per-session effect-label alphabet override hook.
- M4.5 row-fingerprint caching (per-REPL turn LRU).
- M4.6 hybrid record/effect arrow typing.
- M4.9 30-test proptest corpus + fingerprint goldens (deferred
  per the umbrella's shared R225.M9 harness landing).

## [1.20.0] -- 2026-10-15

Wave 123 joint landing: R222.M6 DispatchMode (paideia-os#2663) +
R221.M6 SpanMap (paideia-os#2656) land in parallel. Each softarch
arm declared 1.20.0 as its per-primitive version per the parallel-
CHANGELOG discipline; main consolidates both into this single
stanza at wave close. The two arms touch disjoint `.bss` state
(`_dm_*` vs `_sm_*`), disjoint error bands (`0x4800..0x48FF` vs
`0x4700..0x47FF`), disjoint label prefixes (`dm_` vs `sm_`), and
disjoint design docs — their only shared surfaces are the top-of-
file lib.pdx manifest and this CHANGELOG.

### R222.M6 -- DispatchMode

Load-time light-vs-heavy dispatch classifier for the semantic shell.
Reads a command's declared resource needs (`resource_mask` u32 at
offset 84 of the R222.M2 CommandSig record), decides LIGHT (elaborate
in-process) vs HEAVY (spawn a separate process), bumps per-decision
counters, and indirect-calls one of two disjoint weak-import function-
pointer slots.

### Added

- `src/dispatch_mode.pdx` module `DispatchMode` (R222.M6,
  paideia-os#2663): five public entry points over three u64 scalar
  state slots + two weak-import function-pointer slots.
  - `_dm_init() -> ()` -- idempotent boot hook; zero-fills the five
    u64 slots (`_dm_light_fn`, `_dm_spawn_fn`, `_dm_light_count`,
    `_dm_heavy_count`, `_dm_last_decision`). .bss zero-init at
    program load already satisfies this; the explicit init supports
    test-time counter resets. Pure leaf.
  - `_dm_register_light(fn_ptr) -> errno` -- publishes `fn_ptr` into
    `_dm_light_fn`. Returns `DM_OK` on success, `DM_ERR_NULL_FN`
    (0x4803) on nil. Pure leaf.
  - `_dm_register_spawn(fn_ptr) -> errno` -- publishes `fn_ptr` into
    `_dm_spawn_fn`. Returns `DM_OK` on success, `DM_ERR_NULL_FN`
    (0x4803) on nil. Pure leaf.
  - `_dm_classify(cs_body, cs_len) -> decision_or_err` -- validates
    the CommandSig record (`cs_body != 0`, `cs_len >= 128`, magic
    `'CSIG' == 0x47495343` at offset 0), reads `resource_mask` u32
    at offset 84, ANDs with `DM_HEAVY_MASK` (`0x3C` =
    `NET|EXEC|LONG_RUNNING|HIGH_MEM`), and returns `DM_LIGHT` (0)
    iff the result is 0; `DM_HEAVY` (1) otherwise. Pure leaf.
  - `_dm_dispatch(cs_body, cs_len, mat_body, mat_len) -> packed_u64`
    -- validates the FunctorInstance materialization record
    (`mat_body != 0`, `mat_len >= 64`), CALLs `_dm_classify`, bumps
    the matching decision counter, writes `_dm_last_decision`, loads
    the matching weak-import slot, and indirect-calls it with
    `(cs_body, cs_len, mat_body, mat_len)`. Pack: bits `[15:0]`
    status, bit `[16]` decision (`0`=LIGHT, `1`=HEAVY), bits
    `[63:32]` downstream errno on `*_FAILED` paths.
- Resource-mask bit layout (R222.M6 ABI): `DM_BIT_FS_READ` (0x01),
  `DM_BIT_FS_WRITE` (0x02), `DM_BIT_NET` (0x04), `DM_BIT_EXEC`
  (0x08), `DM_BIT_LONG_RUNNING` (0x10), `DM_BIT_HIGH_MEM` (0x20).
  Heavy mask (`DM_HEAVY_MASK` = 0x3C) = `NET | EXEC | LONG_RUNNING
  | HIGH_MEM`. The classifier encodes the mask AND as a single
  `and r64, imm8` instruction (0x3C fits in imm8 with bit 7 clear,
  per `feedback_pdx_encoder_pitfalls` -- precedent
  `grapheme_iter.pdx:335` `and r11, 0xFF`).
- Two weak-import function-pointer slots in .bss (`_dm_light_fn`,
  `_dm_spawn_fn`), both nil at session boot. The pdx dialect lacks
  linker-level weak imports; the function-pointer slot is the
  convention. Mirrors R133.M5 `_tcg_check_fn` / R133.M6
  `_sc_dispatch_fn` byte-for-byte minus the klog_s1 emits.
- Three u64 counters in .bss (`_dm_light_count`, `_dm_heavy_count`,
  `_dm_last_decision`) as the dispatch fingerprint. User-space
  satellite modules in `libpdx-pds-parser` have no klog surface;
  a counter-based fingerprint is the parser-tier precedent.
- Error band 0x4800..0x48FF (seven slots used; 0x4807..0x48FF
  reserved for R222.M6.1+): `DM_OK` (0), `DM_LIGHT` (0),
  `DM_HEAVY` (1), `DM_ERR_BAD_RECORD` (0x4800),
  `DM_ERR_NO_LIGHT_FN` (0x4801), `DM_ERR_NO_SPAWN_FN` (0x4802),
  `DM_ERR_NULL_FN` (0x4803), `DM_ERR_LIGHT_FAILED` (0x4804),
  `DM_ERR_SPAWN_FAILED` (0x4805), `DM_ERR_BAD_MAT` (0x4806).
- CommandSigHeader offset carve-out at [+84..+88) for `resource_mask`
  u32. R222.M2 reserved the 44-byte tail at [+84..+128) "for
  R222.M3+ (effect-row id, cap-row id, source span, etc.)" so this
  claim does not disturb any landed R222.M2..M5 reader of the
  header. No ABI break; existing readers that stop at offset 84
  (`flags u32`) see no change in the bytes they consume. The
  fingerprint pipeline (R222.M8) already covers the full 128-byte
  header verbatim, so the new field is included in the record's
  fingerprint by construction.
- Pure in-process; no KIND surface; no external linker dependency;
  no cross-library dependency; no intra-library linker dependency.
- Label prefix `dm_` (grep-confirmed unique against the parser-
  tier modules' 22 prior prefixes; the lone `dm_*` labels in the
  tree (`dm_pud_divide_setup` / `dm_fail` in `src/user/dmesg.pdx`)
  are function-scoped and do not share a linker-visible namespace).

### Changed

- `tools/user/libpdx-pds-parser/src/lib.pdx`: flipped
  `LPX_PDS_PARSER_R222_M6_READY` from 0 to 1; bumped MINOR 19 -> 20;
  module-filename comment extended with `src/dispatch_mode.pdx at
  R222.M6`; upstream-issues doc comment picks up `paideia-os#2663
  (R222.M6 DispatchMode)`; design-doc comment picks up
  `design/shell/light-heavy-dispatch.md`.
- `tools/user/libpdx-pds-parser/caps.decl`: added the full
  0x4800..0x48FF band section (seven slots + reservation note),
  the R222.M6 landing paragraph to the per-milestone catalogue
  (dispatch-mode classifier + indirector + weak-import seams +
  CommandSigHeader resource_mask offset), the grep-disjointness
  confirmation line for `0x480[0-6]\b`, and the R222.M6 linker-
  dependency entry (NO external linker deps; no cross-library dep;
  no intra-library dep; two weak-import function-pointer slots nil
  at session boot; cs_body / cs_len / mat_body / mat_len handed in
  as opaque caller-managed pointer args).

### Design doc

- `design/shell/light-heavy-dispatch.md` -- resource-mask bit
  layout, LIGHT vs HEAVY decision rule, weak-import seam rationale
  (two slots not one, mirroring the R133.M5 / R133.M6 precedent),
  public API, status-code taxonomy (band 0x4800..0x48FF),
  fingerprint surface (three u64 counters observable by a smoke-
  mode asserter), encoder-pitfall discipline (no `test`, no
  `and r, imm64`, no 2-op `imul r, imm`, no multiline `pub let`,
  `dm_` label prefix), register-liveness note (r11 clobbered
  across nested CALLs; survivors in r12..r15 or .bss), 4-command
  acceptance test (`where` + `sort` -> LIGHT; `find` + `grep` ->
  HEAVY), forward path through R222.M6.1 (prologue pad audit),
  R222.M6.5 (commands.toml `#resource` bind), R222.M6.6 (per-cost
  budget violation code), R222.M7 (fuzz corpus), R222.M8
  (`describe <cmd>` renders resource_mask as a human-readable
  string).

### Notes

- The 0x4700..0x47FF band is reserved for the parallel Wave-123
  R221.M6 span-mapping NFC variant arm. DispatchMode's 0x4800..
  0x48FF carve-out sits on a kilo-step boundary disjoint from
  every prior landed wave's bands.
- `_dm_classify` is a pure predicate suitable for consumption by
  planners, cost estimators, and smoke-mode asserters that want
  the policy decision without triggering the invocation half.
- `_dm_dispatch` separates classification from invocation so
  either half can be audited independently; the two u64 counters
  record the classification half and the indirect-call return
  pack records the invocation half.
- Two weak-import slots (`_dm_light_fn` + `_dm_spawn_fn`) permit
  shell variants that register only one seam (a refusal shell
  that rejects HEAVY commands by leaving `_dm_spawn_fn` nil, or
  a sandbox shell that only spawns and never runs in-process).
  Both failure modes have dedicated error codes
  (`DM_ERR_NO_LIGHT_FN` / `DM_ERR_NO_SPAWN_FN`).
- 4-command acceptance anchor (per the design doc §9): after the
  sequence `where`, `sort`, `find`, `grep`, the counters observe
  `_dm_light_count == 2`, `_dm_heavy_count == 2`,
  `_dm_last_decision == 2` (HEAVY). The proptest harness
  (`tests/proptest_dispatch_mode.pdx`) is deferred to R222.M7.

### R221.M6 -- SpanMap

R221.M6 of the parser-tier Unicode + lexer umbrella (paideia-os#2485,
decomposed into paideia-os#2656 for this M6) — SOURCE-SPAN TRACKING
ACROSS NFC NORMALIZATION: a sparse delta list of
`(nfc_offset_u32, src_offset_u32)` pairs that preserves the Q-A5
invariant that every AST node points back into the ORIGINAL
caller-supplied source bytes, not the NFC-normalised output. Lets a
downstream diagnostic quote `src[src_offset..]` so the error message
reflects what the user actually typed.

### Added

- `src/span_map.pdx` module `SpanMap` (R221.M6, paideia-os#2656):
  four public entry points over a 1024-slot `.bss` pair pool.
  - `_sm_init() -> ()` — hard-reset of `_sm_pair_count` (one u64
    scalar). `.bss` zero-init at boot already satisfies the cold-
    start identity-map state. Idempotent. Pure leaf.
  - `_sm_record_pair(nfc_offset, src_offset) -> errno` — append
    one monotonic pair at slot `_sm_pair_count` and bump the count.
    Enforces strict monotonicity (new `nfc_offset` AND `src_offset`
    both strictly > prev); defensive catch for `_sm_from_u8nfc`
    walker bugs. Pure leaf.
  - `_sm_lookup(nfc_offset) -> src_offset` — binary-search the
    pair array for the largest `pair.nfc_offset <= nfc_offset`;
    return `pair.src + (nfc_offset - pair.nfc)` or `nfc_offset`
    verbatim on empty-table / below-first-pair queries (identity
    map). Pure leaf.
  - `_sm_from_u8nfc(bytes_src, src_len, bytes_nfc, nfc_len) ->
    errno` — rebuild the span map in one pass. CALLs `_sm_init`
    first; walks both buffers byte-by-byte; on divergence decodes
    the UTF-8 scalar length from the NFC lead byte, advances the
    NFC cursor, scans src for the next matching byte, and records
    the pair. 5 callee-save pushes + `sub rsp, 16` → `rsp%16 == 0`
    at every nested CALL (`_sm_init`, `_sm_record_pair`).
- 8-byte pair record: nfc_offset u32 at [+0], src_offset u32 at
  [+4]. 8-byte stride uses `shl r, 3` (smallest stride in the
  parser-tier; precedent for `shl r, 3` on an 8-byte-stride struct
  pool is new to this landing).
- 1024-slot `.bss` table (`_sm_pairs`, 8192 B, @align(8));
  pair-count scalar (`_sm_pair_count` u64, @align(8)).
- Error band `0x4700..0x47FF` (4 slots used; `0x4704..0x47FF`
  reserved for M6.1+ follow-ups): `SM_OK` (0), `SM_ERR_POOL_FULL`
  (`0x4700`), `SM_ERR_NON_MONOTONIC` (`0x4701`), `SM_ERR_OOB_OFFSET`
  (`0x4702`, reserved), `SM_ERR_BAD_INPUT` (`0x4703`).
- Pure in-process; no KIND surface; no external linker dependency;
  no cross-library dependency; no intra-library linker-visible
  dependency at raw M6 (the AST wire-up to `_sm_lookup` is deferred
  to R221.M6.1).
- Label prefix `sm_` with per-function suffix (`sm_i_`, `sm_rp_`,
  `sm_lu_`, `sm_fnfc_`); grep-confirmed free of linker-visible
  symbol collisions.
- UTF-8 scalar-length decoding uses only `cmp rN, imm32-safe` byte-
  range tests; the 0x80..0xBF continuation-byte-in-lead-slot and
  0xF8+ fallback paths both map to L=1 defensively.
- Register-liveness note: r11 is clobbered by nested CALL per SysV
  ABI; in `_sm_from_u8nfc` the state that must survive CALL is
  placed in the callee-save set (rbx=src_ptr, r12=src_len,
  r13=nfc_ptr, r14=nfc_len, r15=nc) plus the stack local
  `[rsp + 0]` holding `sc`.

### Changed

- `src/lib.pdx`: flipped `LPX_PDS_PARSER_M6_READY` from 0 to 1;
  module-filename comment extended with `src/span_map.pdx at
  R221.M6`; upstream-issues doc comment picks up `paideia-os#2656
  (R221.M6 SpanMap)`; design-doc comment picks up
  `design/shell/span-map-nfc.md`.
- `caps.decl`: added the full `0x4700..0x47FF` band section (4
  slots + reservation note), the R221.M6 landing paragraph to the
  per-milestone catalogue, the `grep -rE '0x470[0-3]\b'`
  disjointness-proof line, and the R221.M6 linker-dependency entry
  (NO external linker dep; NO intra-library linker-visible dep at
  raw M6; the AST wire-up at `_sm_lookup` lands at R221.M6.1).
  Updated the parallel R222.M6 DispatchMode section's "0x4700..0x47FF
  reserved for the parallel SpanMap arm" placeholder to the current
  state ("landed above").

### Design doc

- `design/shell/span-map-nfc.md` — sparse delta list structure,
  worked example (a-acute composition), pool + `.bss` layout,
  public API, status codes, resync heuristic (M6 initial + bounded-
  window M6.1 follow-up), correctness envelope, register plan,
  encoder-pitfall discipline, linker + wire-up, 100-sample
  acceptance corpus (deferred to R221.M7 fuzz-corpus milestone),
  forward path (R221.M6.1 AST wire-up + bounded-window; R225.M7
  HM-mismatch diagnostics; R229.M3-dispatch error-path threading),
  ABI freeze.

### Design notes

- Span map = sparse delta list: pairs record positions AT WHICH the
  two cursors diverge by a fresh amount; BETWEEN consecutive pairs
  both cursors advance byte-for-byte. Lookup = binary search for
  largest preceding pair + delta add.
- Pure ASCII input NEVER triggers a pair (R221.M1's fast branch is
  byte-for-byte identity); the identity map holds throughout and
  `_sm_lookup` short-circuits on empty-table.
- Pool cap 1024 pairs is sized ~10× the typical pds-lang line input
  pair count. Over-cap signals an adversarial input and returns
  `SM_ERR_POOL_FULL`; the 1024 recorded pairs remain queryable.
- Resync heuristic (M6 initial): on divergence, decode UTF-8 scalar
  length from the NFC lead byte, advance NFC cursor by that length,
  scan src for the next matching byte, record pair. Correct for
  canonical-composition cases (Latin + combining marks). Bounded-
  window cross-check deferred to R221.M6.1.

### Linker dependencies

- No external cross-library dependency; no intra-library linker-
  visible dependency at raw M6. The AST module (R221.M5) stores
  spans as `src_offset` / `src_length` u32 fields that currently
  index into the NFC output; a downstream consumer that wants pre-
  NFC spans calls `_sm_lookup(src_offset)` to refine the offset
  before quoting source bytes. R221.M6.1 (AST wire-up at
  `_ast_render`) will introduce a one-way intra-library dependency
  where `ast.pdx` CALLs `_sm_lookup`; no cross-library dependency
  is planned at that milestone either.

## [1.19.0] -- 2026-10-15

Wave 122 joint landing: R222.M5 CmdRegistry (paideia-os#2662) +
R224.M5 LetScope (paideia-os#2679) + R221.M5 Ast (paideia-os#2655)
land in parallel. Each softarch arm declared 1.19.0 as its per-
primitive version per the parallel-CHANGELOG discipline; main
consolidates all three into this single stanza at wave close. The
three arms touch disjoint `.bss` state (`_cmdreg_*` vs the
LetScope `.bss` vs `_ast_*`), disjoint error bands
(`0x4500..0x45FF` vs the LetScope band vs `0x4400..0x44FF`),
disjoint label prefixes (`cmdreg_` vs the LetScope prefix vs
`ast_`), and disjoint design docs — their only shared surfaces are
the top-of-file lib.pdx manifest and this CHANGELOG.

### R222.M5 -- CmdRegistry

Per-session command-registry client that resolves `<name> <args>...`
into a `(cs_body_ref, functor_ref)` tuple at every REPL dispatch.
Companion to R222.M1..M4 which land the four per-command signature
records (SchemasSig, CommandSig, FunctorInstance, ArgFlagSpec); this
M5 wires them together through a hash-indexed catalogue populated at
session start.

### Added

- `src/cmd_registry.pdx` module `CmdRegistry` (R222.M5,
  paideia-os#2662): five public entry points over a 128-slot .bss
  hash table with 48-byte entry stride.
  - `_cmdreg_init() -> ()` -- idempotent boot hook; zero-fills
    `_cmdreg_entries` (6144 B = 128 x 48), clears
    `_cmdreg_count_system` / `_cmdreg_count_user`, sets
    `_cmdreg_init_state := 1`. Pure leaf.
  - `_cmdreg_fnv1a64(ptr, len) -> hash` -- pure-leaf FNV-1a 64 over
    caller bytes; byte-for-byte identical to R222.M2
    `_cmd_sig_fnv1a64` and R222.M3 `_fi_fnv1a64` (same offset basis
    0xCBF29CE484222325 + prime 0x100000001B3), so a downstream
    consumer that compares name_hash values across the three parser-
    family modules is guaranteed numerical equality.
  - `_cmdreg_register(scope, name, name_len, cs_body_ref,
    functor_ref) -> errno` -- validates scope in {0, 1} and
    name_len in [1, CMDREG_NAME_MAX=16]; CALLs `_cmdreg_init` +
    `_cmdreg_fnv1a64`; linear-probes from `hash mod 128` and claims
    the first unoccupied slot; writes the 48-byte entry (name_hash
    u64, cs_body_ref u64, functor_ref u64, scope u8, flags u8,
    name_len u8, reserved u8, name_inline u8[16], reserved u32);
    bumps the per-scope cursor.
  - `_cmdreg_lookup(name, name_len, out_entry_ptr) -> errno` --
    CALLs `_cmdreg_init` + `_cmdreg_fnv1a64`; walks the probe chain
    up to 128 attempts; on name_hash match, picks SCOPE_USER (1) over
    SCOPE_SYSTEM (0) when both exist on the chain; writes the winning
    entry base address to `*out_entry_ptr` on OK, 0 on error.
  - `_cmdreg_dump(out, out_cap) -> (bytes_written << 32) | status`
    -- walks slot 0..127, copying each occupied entry's 48 bytes into
    the caller buffer; returns OUT_TOO_SMALL on insufficient capacity.
- 48-byte entry record: name_hash u64 (FNV-1a 64), cs_body_ref u64
  (opaque), functor_ref u64 (opaque), scope u8 (0=system, 1=user),
  flags u8, name_len u8 (1..16), reserved u8, name_inline `[u8; 16]`
  (zero-padded past name_len), reserved u32. 48-byte stride uses
  `shl idx, 5` (* 32) + `shl idx, 4` (* 16) summed into a scratch
  register -- never 2-op `imul r,imm` (per feedback_pdx_encoder_pitfalls).
- 128-slot .bss table (`_cmdreg_entries`, 6144 B, @align(8)); scope
  cursors (`_cmdreg_count_system`, `_cmdreg_count_user`); boot
  sentinel (`_cmdreg_init_state`).
- Error band 0x4500..0x45FF (6 slots used; 0x4506..0x45FF reserved
  for R222.M6+ follow-ups): CMDREG_OK (0), CMDREG_ERR_NOT_FOUND
  (0x4501), CMDREG_ERR_BAD_SCOPE (0x4502), CMDREG_ERR_BAD_NAME
  (0x4503), CMDREG_ERR_TABLE_FULL (0x4504), CMDREG_ERR_OUT_TOO_SMALL
  (0x4505).
- Pure in-process; no KIND surface; no external linker dependency;
  no cross-library dependency.
- Label prefix `cmdreg_` (grep-confirmed free of linker-visible
  symbol collisions; disjoint from the parser-family's `cr_`
  prefix which is TAKEN by R224.M4 CapRow).
- Hash-slot mod uses `shl r, 57; shr r, 57` to isolate low 7 bits
  (= hash mod 128) -- never `and r, imm64` (per
  feedback_pdx_encoder_pitfalls). Precedent: row_types.pdx
  `shl r, 40; shr r, 40` for low-24-bit idx masking.
- Lazy-init discipline: every public API that READS the table CALLs
  `_cmdreg_init` at its first instruction after the SysV prologue
  (Wave 120 lesson, reaffirmed at Wave 121 across R224.M3 EffectRow
  + R224.M4 CapRow).

### Changed

- `src/lib.pdx`: flipped `LPX_PDS_PARSER_R222_M5_READY` from 0 to 1;
  bumped MINOR 18 -> 19; module-filename comment extended with
  `src/cmd_registry.pdx at R222.M5`; upstream-issues doc comment
  picks up `paideia-os#2662 (R222.M5 CmdRegistry)`; design-doc
  comment picks up `design/shell/command-registry-client.md`.
- `caps.decl`: added the full 0x4500..0x45FF band section (6 slots +
  reservation note), the R222.M5 landing paragraph to the per-
  milestone catalogue, the grep-disjointness confirmation line for
  `0x450[1-5]\b` (with explicit note that 0x4500 as the APIC ICR
  INIT delivery-mode base in src/kernel/core/apic/init_sipi.pdx
  sits in a disjoint semantic namespace), and the R222.M5 linker-
  dependency entry (NO external linker deps; no cross-library dep;
  no cross-module CALL into command_sig.pdx or functor_instance.pdx
  -- cs_body_ref and functor_ref are handed in as opaque u64 handles
  by the caller).

### Design doc

- `design/shell/command-registry-client.md` -- hash-table rationale
  (closed addressing + linear probe for predictable O(1) lookup
  on a 128-slot table scanned with ≤50 μs/call for 5-command
  fixtures), 48-byte entry layout, user-shadow override rule
  (preferring SCOPE_USER over SCOPE_SYSTEM on a name_hash tie),
  TOML-free M5 boundary (the kernel-side cmd_registry_parser.pdx
  at R123.M2 landed earlier; M5 reads a pre-flattened byte buffer
  of entries), encoder-pitfall discipline (no `test`, no
  `and r,imm64`, no 2-op `imul r,imm`, no multiline `pub let`,
  `shl idx,5 + shl idx,4` stride, `cmdreg_` label prefix),
  register-liveness note (r11 clobbered across nested CALLs;
  survivors in r12..r15 or stack), lazy-init discipline (every
  reader CALLs `_cmdreg_init` at entry), forward path through
  R222.M6 (commands.toml bind), R222.M7 (fuzz corpus),
  R222.M8 (`describe <cmd>` serialization).

### R221.M5 -- Ast

R221.M5 of the parser-tier Unicode + lexer umbrella (paideia-os#2485,
decomposed into paideia-os#2655 for this M5) — UNIFIED AST SUM TYPE:
one `SyntaxNode` sum spanning pipeline, datalog, lambda, record and
literal sub-languages over a singleton 8 KiB bump-pointer node pool
with Q-A5 source-span invariants on every node.

### Added

- `src/ast.pdx` module `Ast` (R221.M5, paideia-os#2655): seven
  public entry points over a 256-slot `.bss` SyntaxNode pool.
  - `_ast_init() -> ()` — hard-reset of three scalar `.bss`
    singletons (`_ast_pool_next`, `_ast_src_ptr`, `_ast_src_len`);
    idempotent in the trivial sense (re-zeroing an already-zero
    state is a no-op). Pure leaf.
  - `_ast_set_source(bytes_ptr, bytes_len) -> ()` — stash caller-
    supplied source-byte buffer for span-copy render. Pure leaf.
  - `_ast_alloc(kind, src_offset, src_length) -> node_ref` — bump-
    allocate one 32-byte slot and populate `kind` + Q-A5 span
    fields; pool_idx 0 reserved as nil sentinel; returns 0 on
    pool-full. Pure leaf with inlined lazy-init (precedent:
    `_rt_alloc_node`). `AST_ERR_POOL_FULL` on `_ast_pool_next >=
    AST_POOL_CAP` (256).
  - `_ast_set_payload_u32(node_ref, payload) -> ()` — overwrite
    the u32 `payload_u32` slot at [+12] of the given node. Silent
    no-op on out-of-range `node_ref` (void return).
  - `_ast_set_child_ref(node_ref, child_array_ref) -> ()` —
    overwrite the u64 `child_ref` slot at [+16]. Silent no-op on
    out-of-range `node_ref`.
  - `_ast_set_extra_ref(node_ref, extra_ref) -> ()` — overwrite
    the u64 `extra_ref` slot at [+24]. Silent no-op on out-of-
    range `node_ref`.
  - `_ast_render(node_ref, out, out_cap) -> (bytes_written << 32)
    | status` — span-copy the N bytes at `_ast_src_ptr +
    src_offset` into `out`. Returns packed_u64 with the byte count
    in the high 32 and `AST_OK` (0) / `AST_ERR_*` in the low 32.
- 32-byte SyntaxNode record stride: `kind` u16, `flags` u16,
  `src_offset` u32, `src_length` u32, `payload_u32` u32, `child_ref`
  u64, `extra_ref` u64. 32-byte stride matches `shl r, 5` for slot
  addressing. Every node carries a Q-A5 source span so diagnostics
  can point into the source without walking the parent chain.
- SyntaxKind enum with family / subkind nibble layout:
  - Pipeline family (`0x0100..0x01FF`): `AST_SK_PIPELINE_ROOT`,
    `AST_SK_STAGE`, `AST_SK_PIPE`, `AST_SK_REDIRECT`,
    `AST_SK_HOSTNAME_ANNOT`.
  - Datalog family (`0x0200..0x02FF`): `AST_SK_DATALOG_BLOCK`,
    `AST_SK_FACT`, `AST_SK_RULE`, `AST_SK_ATOM`, `AST_SK_GOAL`,
    `AST_SK_RULE_HEAD`, `AST_SK_RULE_BODY`.
  - Lambda family (`0x0300..0x03FF`): `AST_SK_LAMBDA`,
    `AST_SK_PARAM`, `AST_SK_BODY`, `AST_SK_LET`, `AST_SK_LET_REC`,
    `AST_SK_CAPTURE_LIST`, `AST_SK_EFFECT_ROW`, `AST_SK_CAP_ROW`.
  - Record family (`0x0400..0x04FF`): `AST_SK_RECORD`,
    `AST_SK_FIELD`, `AST_SK_FIELD_SELECTOR`.
  - Literal family (`0x0500..0x05FF`): `AST_SK_LIT_INT`,
    `AST_SK_LIT_STR`, `AST_SK_LIT_BOOL`, `AST_SK_LIT_PATH`,
    `AST_SK_LIT_HASH32`, `AST_SK_IDENT`.
- Error band `0x4400..0x44FF` (six slots used: `AST_ERR_POOL_FULL`
  `0x4400`, `AST_ERR_BAD_REF` `0x4401`, `AST_ERR_BAD_KIND` `0x4402`,
  `AST_ERR_OUT_TOO_SMALL` `0x4403`, `AST_ERR_SPAN_OOB` `0x4404`,
  `AST_ERR_NO_SOURCE` `0x4405`; 250 slots reserved for M5.1+).
- `.bss` state: `_ast_node_pool : [u8; 8192] @align(8)`,
  `_ast_pool_next : u64 @align(8)`, `_ast_src_ptr : u64 @align(8)`,
  `_ast_src_len : u64 @align(8)`. All stores via `lea r11,
  [rip + sym]; mov [r11+disp], reg` (precedent: `_cl_init`,
  `_rt_alloc_node`).
- Pure-leaf discipline: all seven entry points have zero callee-
  save pushes, zero stack frames, zero nested CALLs. The allocator
  inlines the lazy-init (`cmp _ast_pool_next, 0; jne have; mov
  rax, 1; have:`) rather than CALLing `_ast_init`, avoiding the
  alignment-math prologue and the register-save of rdi/rsi/rdx
  across the call site.
- Label prefix `ast_` with per-function suffix (`ast_i_`,
  `ast_ss_`, `ast_al_`, `ast_sp_`, `ast_sc_`, `ast_se_`,
  `ast_r_`); grep-confirmed disjoint from every sibling parser-
  tier module's label namespace and from paideia-as reserved
  keywords.
- `design/shell/unified-ast.md` (R221.M5 spec; 10-example fixture
  subset of the 100-sample round-trip anchor at §9; forward path
  through R221.M5.1 child-aware render, R221.M5.2 kind-table
  enforcement, R221.M6 span-mapping NFC, R221.M7 fuzz corpus,
  R225.M3+ typechecker, R229.M3-dispatch evaluator; §11 ABI-freeze
  note).

### Changed

- `src/lib.pdx`: `LPX_PDS_PARSER_M5_READY` flipped from 0 to 1;
  module-filename and upstream-issues comment extended for the new
  module + the new design doc. Version stays at 1.19.0 per the
  Wave 122 parallel-arm consolidation convention.
- `caps.decl`: added the full `0x4400..0x44FF` band section (six
  slots used + 250 reserved); added the `grep -rE '0x440[0-5]\b'`
  disjointness-proof line; added the `R221.M5 (ast.pdx)` linker-
  dependency note (no external dep, no intra-library dep at M5);
  swapped the R221.M4 note's "R221.M5 will add" wording for the
  current state ("R221.M5 is the first intra-library consumer of
  Token records; the AST module itself does not CALL into CtxLexer
  at the link level").

### Design notes

- Round-trip strategy: every node carries its EXACT source span.
  `_ast_render` emits the N bytes at `_ast_src_ptr + src_offset`
  verbatim. The ROOT's span covers `[0, input_len)`, so
  `_ast_render(root, ...)` is a straight span-copy — trivially
  byte-identical. A child-aware render that walks `child_ref` and
  concatenates child spans is architecturally compatible with the
  same ABI; M5 lands the simpler span-copy variant.
- Pool_idx 0 is reserved as the "nil" sentinel: a 0 return from
  `_ast_alloc` signals pool exhaustion; a 0 `child_ref` /
  `extra_ref` means "no reference". Valid handles are 1..255. The
  allocator inlines a lazy-check so a zero sentinel bumps to 1 on
  first use (skip reserved idx 0; precedent: `_rt_alloc_node`).
- Reset between parses: callers hard-reset via `_ast_init`. The
  previously-allocated SyntaxNode records remain in the backing
  byte array but become unreachable because every valid handle
  must satisfy `node_ref < _ast_pool_next`; a stale handle fails
  this check and becomes a silent no-op in the setters,
  `AST_ERR_BAD_REF` in `_ast_render`.

### Linker dependencies

- No external cross-library dependency; no intra-library linker-
  visible dependency at M5. The AST is a self-contained arena the
  parser-tier downstream fills from CtxLexer R221.M4 Token records
  by VALUE through the caller-passed args rather than a cross-
  module CALL. R225.M3+ typechecker landings will CALL
  `_ast_set_extra_ref` from this module to write HmCore type-pool
  pool_idx into the SyntaxNode's extra_ref slot; no cross-library
  dependency is planned.

### R224.M5 -- LetScope

R224.M5 of the lambda-lang umbrella (paideia-os#2488, decomposed
into paideia-os#2679 for this M5) -- NESTED LAMBDA + `let` /
`let rec` SCOPING: a user-space parser-tier working-memory
substrate backing standard Hindley-Milner shadowing on a stack-of-
frames pool. A 128-slot ring of 32-byte scope frames (slot 0 is
the null-sentinel so `parent_frame_ref == 0` means "no enclosing
scope"); each frame records one lexical binding and chains to its
enclosing frame via a `parent_frame_ref` u32. The chain-walk
resolver (`_ls_resolve`) hits the first byte-level name match
inner-first, so shadowing is natural (the inner binding of a
name wins within its lexical scope). Recursion is enabled by
`let rec` pre-pushing the self-frame BEFORE the elaborator types
the RHS; mutual recursion by pre-pushing N `let rec` frames over
the common parent before any RHS is typed.

#### Added

- `src/let_scope.pdx` module `LetScope` (R224.M5, paideia-os#2679):
  seven public entry points over a 128-slot .bss frame pool with
  32-byte stride.
  - `_ls_init() -> ()` -- idempotent boot hook; reserves slot 0 as
    the null-sentinel by setting `_ls_frame_next := 1` on a cold
    .bss. Pure leaf.
  - `_ls_push_let(parent, name_ptr, name_len, type_scheme_ref)
     -> frame_ref` -- thin wrapper: sets r8 = 1 (SCOPE_LET), CALLs
    `_ls_push_impl`.
  - `_ls_push_letrec(parent, name_ptr, name_len, type_scheme_ref)
     -> frame_ref` -- same shape; sets r8 = 2 (SCOPE_LETREC).
  - `_ls_push_lambda(parent, name_ptr, name_len, type_scheme_ref)
     -> frame_ref` -- same shape; sets r8 = 3 (SCOPE_LAMBDA).
  - `_ls_push_impl(parent, name_ptr, name_len, type_scheme_ref,
     kind) -> frame_ref` -- module-private helper; validates
    `name_len` in [1..16] and `kind` in [1..3], checks pool-not-
    full, writes the 32-byte header (kind u16, flags u16, parent
    u32, name_inline u8[16], name_len u8, 3 reserved u8,
    type_scheme_ref u32), bumps `_ls_frame_next`, returns the
    pre-increment slot index. Lazy-init idempotent at entry
    (Wave 120 lesson).
  - `_ls_resolve(frame_ref, name_ptr, name_len) -> packed_u64` --
    walks the parent chain inner-first comparing name_len then
    bytes; on first match returns `(type_scheme_ref << 32) |
    LS_OK`. On chain-end (cursor == 0) returns
    `LS_ERR_NOT_FOUND` (0x4601); on cursor >= 128 or kind==0
    mid-walk returns `LS_ERR_BAD_FRAME` (0x4602); on bad input
    name_len returns `LS_ERR_BAD_NAME` (0x4603). Lazy-init
    idempotent at entry.
  - `_ls_pop(frame_ref) -> parent_frame_ref` -- pure-leaf accessor
    reading the stored parent u32 at `&_ls_frame_pool +
    frame_ref*32 + 4`. Does NOT reclaim the slot (frames are
    append-only within a parse pass).
- Frame record layout (32 B stride, `shl r,5`): kind u16 at +0,
  flags u16 at +2, parent u32 at +4, name_inline u8[16] at +8,
  name_len u8 at +24, 3 reserved u8 at +25..+27, type_scheme_ref
  u32 at +28. Three kinds share one record; only the kind-byte
  discriminator differs. The `type_scheme_ref` u32 payload is
  caller-opaque: at raw M5 it is a HmCore pool_idx; at the M5.1
  wire-up a TypeEnv scheme_id is used instead (flags bit 0
  discriminates).
- Pool geometry: `_ls_frame_pool : [u8; 4096] @align(8)` (128
  slots x 32 B); `_ls_frame_next : u64 @align(8)` next-free
  cursor (1..128 after init). Slot 0 reserved as the null-
  sentinel so `parent_frame_ref == 0` reads as "top-level, no
  enclosing scope". Pool-full is `_ls_frame_next >= 128`.
- Error band 0x4600..0x46FF (five slots used: `LS_ERR_POOL_FULL`
  0x4600, `LS_ERR_NOT_FOUND` 0x4601, `LS_ERR_BAD_FRAME` 0x4602,
  `LS_ERR_BAD_NAME` 0x4603, `LS_ERR_BAD_KIND` 0x4604; 251 slots
  reserved for M5.1+). Diagnostic-family mapping:
  `E0830_NAME_NOT_FOUND` = 0x4601,
  `E0831_BAD_FRAME` = 0x4602,
  `E0832_BAD_NAME` = 0x4603,
  `E0833_POOL_FULL` = 0x4600,
  `E0834_BAD_KIND` = 0x4604.
- NO external cross-library linker dependency; NO intra-library
  linker dependency at raw M5. LetScope stores the `type_scheme_ref`
  u32 as an opaque payload and does not call into HmCore, TypeEnv,
  RowTypes, or any sibling module. All seven public entry points
  can be linked standalone.
- Label prefix `ls_` with per-function suffix (`ls_ini_`,
  `ls_pi_`, `ls_pl_`, `ls_plr_`, `ls_pla_`, `ls_r_`, `ls_po_`).
  Grep-confirmed disjoint from every sibling parser-tier module
  in this library (u8n_, gi_, wp_, cl_, sch_sig_, cmd_sig_, fi_,
  afs_, pl_, rp_, ll_, cc_, er_, cr_, hm_, rt_, dl_, se_, te_,
  cmdreg_, ast_).
- `design/shell/let-in-scoping.md` (R224.M5 spec; 12-test
  acceptance corpus enumerated at §7 covering 10 OK cases
  (basic let, nested lets, shadowing, let-rec self-rec, let-rec
  + lambda, lambda shadowing, three-level nesting, pop-returns-
  parent) + 4 error cases (not-found, pool-full, bad-frame, bad-
  name)).

#### Changed

- `src/lib.pdx`: `LPX_PDS_PARSER_R224_M5_READY` flipped from 0 to 1
  (version bump 1.18.0 -> 1.19.0 shared with the parallel R221.M5
  Ast and R222.M5 CmdRegistry arms of Wave 122); module-filename
  comment extended with `src/let_scope.pdx at R224.M5`; upstream-
  issues comment extended with `paideia-os#2679 (R224.M5
  LetScope)`; design-doc list extended with
  `design/shell/let-in-scoping.md`.
- `caps.decl`: added the full 0x4600..0x46FF band section (five
  slots used, 251 reserved for M5.1+), the R224.M5 landing
  paragraph in the per-milestone catalogue (replacing the former
  R224.M5+ forward-reference comment with the landed R224.M5 entry
  + the still-reserved R224.M6+ comment), the `0x460[0-4]\b`
  grep-disjointness confirmation line, the R224.M5 linker-
  dependency entry (NO external cross-library dep, NO intra-
  library dep at raw M5), and the scope-family .bss disjointness
  note appended to the CmdRegistry closing paragraph.
- `STATUS.md`: R224.M5 moved from "deferred" to "landed"; the R224
  wave checklist gains the M5 row with items R224.M5-001..009
  (001..004 landed, 005..009 deferred); the error-band accounting
  table gains the `let_scope` + `let_scope-M5.1+` rows.

#### Design notes

- Standard HM shadowing chosen over Q-A5a (flat lexical name
  table; rejected because of O(n) scope-pop rehash cost on frame
  exit) and Q-A5b (persistent scope-env records; rejected because
  parse-tree reuse is not a current workflow and copy-on-push cost
  would dominate at R224 grammar sizes).
- The pool mirrors R225.M1 HmCore's own frame-indexed convention
  (slot 0 reserved as null-sentinel; 1-indexed usable slots; pool-
  full checked against the slot-count ceiling). Resolve shadowing
  falls out naturally from the inner-first chain walk; no explicit
  shadowing-aware predicate is needed in the resolve loop.
- The three public push wrappers each `sub rsp, 8` for SysV
  alignment, set `r8 = kind` to the literal 1/2/3, CALL
  `_ls_push_impl`, `add rsp, 8`, RET. The shared helper avoids
  triple-maintaining the ~60-instruction push body; the kind byte
  flows through r8 (SysV 5th arg slot) with no caller-side
  rewrite.
- The `type_scheme_ref` u32 is stored and returned verbatim at
  raw M5 so the R229.M4+ REPL dispatch can choose between a HmCore
  pool_idx (monomorphic) and a TypeEnv scheme_id (polymorphic)
  via the flags byte. M5.1 wires the flag.
- `_ls_pop` is a convenience accessor that does NOT reclaim the
  slot; the enclosing cursor is restored by the AST driver which
  held it in a local register BEFORE the push. The pool is
  append-only within a parse pass. M5.4 lands a compacting pop
  if the use-case firms up.
- Wave 120 lazy-init lesson replicated at every public API that
  reads OR writes the frame pool. `_ls_pop` deliberately skips
  the init call because a never-pushed pool has every parent u32
  as .bss zero, which equals the correct "top-level" sentinel.

#### Linker dependencies

- No external cross-library dependency; no intra-library linker-
  visible dependency at raw M5. LetScope stores the
  `type_scheme_ref` u32 as an opaque payload; the HM-dispatch and
  TypeEnv-cache interpretation happens at the R229.M4+ REPL layer
  which reads the resolve-returned u32 and routes to the right
  substrate.
- All seven public entry points can be linked against a bare
  parser-tier object graph; no `--extra-obj-dir` is introduced
  for this M5.

## [1.18.0] -- 2026-10-15

Wave 121 joint landing: R221.M4 CtxLexer (paideia-os#2654) +
R224.M4 CapRow (paideia-os#2678) land in parallel. Each softarch
arm declared 1.18.0 as its per-primitive version per the
parallel-CHANGELOG discipline; main consolidates both into this
single stanza at wave close. The two arms touch disjoint `.bss`
state (`_cl_*` vs `_cr_*`), disjoint error bands
(`0x4200..0x42FF` vs `0x4300..0x43FF`), disjoint label prefixes
(`cl_` vs `cr_`), and disjoint design docs — their only shared
surfaces are the top-of-file lib.pdx manifest and this CHANGELOG.

### R221.M4 -- CtxLexer

R221.M4 of the parser-tier Unicode + lexer umbrella (paideia-os#2485,
decomposed into paideia-os#2654 for this M4) -- CONTEXT-TRACKING
LEXER: a single-pass byte walker over the NFC-normalised pds-lang
surface that captures pipeline / datalog / lambda tier membership
once at lex time, so every downstream pass walks a context-tagged
token stream without re-deducing the enclosing tier.

### Added

- `src/ctx_lexer.pdx` module `CtxLexer` (R221.M4,
  paideia-os#2654): six public entry points over a 16-level `.bss`
  context stack.
  - `_cl_init() -> ()` -- boot hook; zero-fills `_cl_stack` (16 B),
    `_cl_depth` (u64), `_cl_last_kind` (u64). Pure leaf.
  - `_cl_push_ctx(ctx) -> errno` -- validate `ctx <= 2`, bounds-check
    depth, write stack byte + bump depth. `CL_ERR_BAD_CTX` on `ctx > 2`,
    `CL_ERR_STACK_OVERFLOW` on `depth == 16`.
  - `_cl_pop_ctx() -> (ctx<<32)|status` -- decrement depth, read
    byte at pre-decrement top. `CL_ERR_STACK_UNDERFLOW` on empty.
  - `_cl_current_ctx() -> ctx` -- `stack[depth-1]` iff `depth>0`,
    else `CTX_PIPELINE`.
  - `_cl_lex_token(bytes, len, cursor, out_tok) -> (new_cursor<<32)|status`
    -- pure-leaf single-token lexer; emits one 16-byte Token record
    tagged with current context, inlines stack-mutating side effects
    on `{` (push BEFORE emit) and `}` (emit THEN pop).
  - `_cl_tokenize(bytes, len, out, out_cap) -> (bytes_written<<32)|status`
    -- walks the whole input, 5-push + 16-pad frame around one
    nested CALL into `_cl_lex_token` per iteration. Full-u64 status
    compare on nested rax via `shl 32; shr 32` (Wave 118 lesson,
    avoids `and rN, imm64`).
- 17-value TOK_* enum: `TOK_EOF (0)`, `TOK_IDENT (1)`, `TOK_NUMBER
  (2)`, `TOK_STRING (3)`, `TOK_PIPE (4)`, `TOK_ARG_DELIM (5)`,
  `TOK_LBRACE (6)`, `TOK_RBRACE (7)`, `TOK_LPAREN (8)`,
  `TOK_RPAREN (9)`, `TOK_COMMA (10)`, `TOK_KW_DATALOG (11)`,
  `TOK_ARROW (12)`, `TOK_COLON (13)`, `TOK_DOT (14)`,
  `TOK_RULE_ARROW (15)`, `TOK_QUERY_ARROW (16)`.
- 3-value CTX_* enum: `CTX_PIPELINE (0)`, `CTX_DATALOG (1)`,
  `CTX_LAMBDA (2)`.
- 16-byte Token record stride: kind u16, ctx u8, flags u8,
  src_offset u32, src_length u32, payload u32. 16-byte stride =
  `shl r,4` slot addressing (precedent: RowTypes TyNode).
- Context-switch rule set:
  - `{` with prev kind `TOK_KW_DATALOG` -> push `CTX_DATALOG`.
  - `{` with lookahead (past SP/TAB, NOT past LF/CR) finding `|`
    -> push `CTX_LAMBDA`.
  - `{` otherwise -> push COPY of current context (brace-balancing
    invariant: every `{` pushes something so every `}` has a
    matching entry).
  - `}` emits with ctx = pre-pop (inner) then pops. Unmatched `}` at
    depth==0 -> `CL_ERR_UNMATCHED_BRACE`.
  - `|` in CTX_PIPELINE -> `TOK_PIPE`; in CTX_LAMBDA ->
    `TOK_ARG_DELIM`; in CTX_DATALOG -> `CL_ERR_PIPE_IN_DATALOG`.
- M4 grammar scope: identifier `[A-Za-z_][A-Za-z0-9_]*` with the
  one keyword `datalog` (7-byte compare); decimal number
  `[0-9]+`; double-quoted string with `\"` / `\\` escapes;
  single-char punctuators `.`, `(`, `)`, `,`, `{`, `}`;
  two-byte lookaheads `->`, `:-`, `?-`; bare `:` emits
  `TOK_COLON`. Any other byte (control, UTF-8 high byte,
  misplaced punctuator including bare `-` or `?`) returns
  `CL_ERR_SYNTAX` with new_cursor at the fault.
- Error band `0x4200..0x42FF` (eight slots used: `CL_ERR_SYNTAX`
  0x4200, `CL_ERR_STACK_OVERFLOW` 0x4201,
  `CL_ERR_STACK_UNDERFLOW` 0x4202, `CL_ERR_UNMATCHED_BRACE`
  0x4203, `CL_ERR_PIPE_IN_DATALOG` 0x4204,
  `CL_ERR_UNTERMINATED_STRING` 0x4205, `CL_ERR_OUT_TOO_SMALL`
  0x4206, `CL_ERR_BAD_CTX` 0x4207; 247 slots reserved for M4.1+).
- `.bss` state: `_cl_stack : [u8; 16] @align(8)`,
  `_cl_depth : u64 @align(8)`, `_cl_last_kind : u64 @align(8)`.
  All stores via `lea r11, [rip + sym]; mov [r11+disp], reg`
  (precedent: `_er_init`, `_se_init`).
- Pure-leaf discipline:
  - `_cl_init` / `_cl_push_ctx` / `_cl_pop_ctx` / `_cl_current_ctx`:
    zero pushes; no stack frame; no nested CALL.
  - `_cl_lex_token`: five callee-save pushes
    (rbx/r12/r13/r14/r15); zero `sub rsp` because no nested CALL.
    Stack-manipulation side effects on `{` and `}` are inlined via
    direct `.bss` writes.
  - `_cl_tokenize`: five callee-save pushes + `sub rsp, 16` for two
    local slots (cursor_in, tok_count); ONE nested CALL per
    iteration into `_cl_lex_token`. Entry rsp%16==8; prologue sum
    40 + 16 = 56 B -> rsp%16==0 at the nested CALL (SysV).
- Label prefix `cl_` with per-function suffix (`cl_ini_`,
  `cl_pp_`, `cl_pp_po_`, `cl_cu_`, `cl_lt_`, `cl_tz_`); grep-
  confirmed disjoint from `cc_` (R224.M2 ClosureCapture internal
  helpers), `cs_` (R222.M2 CommandSig public entry points),
  `clo_` (R224.M2 ClosureCapture internal helpers), and from
  paideia-as reserved keywords (`loop`, `if`, `let`, `fn`,
  `ret`, `done`).
- `design/shell/ctx-tracking-lexer.md` (R221.M4 spec; 40-example
  fixture enumerated at §10 covering five pipeline-only, ten
  datalog-only, ten lambda-only, and ten nested / cross-context
  cases including all seven error paths).

### Changed

- `src/lib.pdx`: version 1.17.0 -> 1.18.0;
  `LPX_PDS_PARSER_M4_READY` flipped from 0 to 1; module-filename
  and upstream-issues comment extended for the new module + the new
  design doc.
- `caps.decl`: added the full 0x4200..0x42FF band section (eight
  slots used, 247 reserved for M4.1+), the R221.M4 landing
  paragraph in the per-milestone catalogue (replacing the former
  R221.M4 "pure byte-walker; no KIND" forward-reference comment),
  the `0x420[0-7]\b` grep-disjointness confirmation line, the
  R221.M4 linker-dependency entry (NO cross-library dep; NO intra-
  library dep -- the lexer is fully self-contained at M4, using
  only its own `.bss` state and the caller-supplied input / output
  buffers), and the Wave 121 kilo-step disjointness note (R221.M4
  at 0x4200..0x42FF past the R224.M3 EffectRow 0x4000..0x40FF
  carve-out and the reserved R133.M6 kernel-parallel 0x4100..
  0x41FF slot).
- `STATUS.md`: R221.M4 moved from "deferred" to "landed"; the R221
  M-table gains the M4 checklist; the error-band accounting table
  gains the `ctx_lexer` + `ctx_lexer-M4.1+` rows and marks the
  former `lexer` reservation at 0x2730..0x274F as superseded by
  the kilo-step carve-out.

### Design notes

- Context model chosen so `{` and `}` tokens BOTH carry the INNER
  context byte: `{` emits post-push (ctx = pushed) and `}` emits
  pre-pop (ctx = being-closed). The brace tokens thus discriminate
  a datalog-closing `}` from a lambda-closing `}` by a single byte
  load, which is the shape R221.M5 AST and R225.M3+ typecheck will
  dispatch on.
- `datalog` is the only keyword at M4; the 7-byte compare is
  inlined (no classifier table). R221.M5 may widen the keyword
  set, but the ONE context-switch keyword at the lexer tier is
  stable (lambda enters by `{|` lookahead, not by a keyword).
- Lambda-detection lookahead is bounded by LF/CR OR non-SP/TAB
  byte -- no explicit N-token ceiling needed because the practical
  lambda header fits on one source line. The spec's "within N
  tokens" phrase from the brief is realised as "any WS run on the
  current line between `{` and the first non-WS byte".
- Stack-overflow at depth==16 is a parser-grammar cap, not a lexer
  limitation. Practical pds-lang nesting (lambda inside datalog
  inside pipeline) reaches depth 3; the 16-level ceiling leaves
  headroom for machine-generated input.
- `_cl_lex_token` is a pure LEAF (no nested CALL) by design: inlining
  the stack ops avoids five `_cl_*_ctx` call sites per token and
  keeps register-liveness simple (r11 never clobbered mid-token;
  r12..r15 preserved across the entire call).

### Linker dependencies

- NO cross-library linker dependency.
- NO intra-library dependency -- the lexer is fully self-contained
  at M4 and uses only its own `.bss` state and the caller-supplied
  input / output buffers. (R221.M5 unified-AST landing will add an
  intra-library consumer that READS Token records; this M4 landing
  freezes the record ABI.)

### R224.M4 -- CapRow

R224.M4 of the lambda-lang umbrella (paideia-os#2488, decomposed
into paideia-os#2678 for this M4) -- CAPABILITY-ROW TYPING: a
parser-tier capability-row sub-grammar and an environment-mask
covering check layered over R225.M2 Rémy row polymorphism, dual
with R224.M3 EffectRow. Lambdas carry capability rows
(`A -> B !{eff} @{read, write}`) that the type-checker checks
against the invoking environment's capability mask; the missing-cap
rejection anchor case (`_cr_check_env(parsed("@{read}"), 0)`)
returns `CR_ERR_MISSING_CAP` packed with the offending label id
-- the `E0820_MISSING_CAP` diagnostic family.

#### Added

- `src/cap_row.pdx` module `CapRow` (R224.M4, paideia-os#2678):
  capability-row sub-grammar for the paideia-shell lambda surface,
  following Q-A2 "substructural capability lattice". Seven public
  entry points:
  - `_cr_init() -> ()` -- lazy-populate the 32-slot label-intern
     table (10 primitives + 22 user-declared slots) from the
     160-byte static source table `_cr_primitive_init`. Idempotent
     (count-non-zero short-circuit). Called from the entry of every
     public API that reads the label table, per the Wave 120
     lazy-init lesson from R224.M3 EffectRow.
  - `_cr_label_lookup(ptr, len) -> packed_u64` -- linear scan over
     `_cr_label_table[0..count)`; returns `(tag << 24) | idx` on
     hit, `0xFFFFFFFF` on miss.
  - `_cr_label_intern(ptr, len) -> packed_u64` -- lookup-then-
     extend; allocates a user-declared slot (`tag = 1`) when the
     table has room and the name fits in 12 bytes; returns
     `0xFFFFFFFF` on table-full or over-long.
  - `_cr_skip_ws(bytes, len, cursor) -> cursor` -- pure-leaf WS
     walker over the WS class {0x20, 0x09, 0x0A, 0x0D}.
  - `_cr_parse(bytes, len, out_row_ref) -> status` -- parses
     `WS* @ WS* { LabelList? } ` and builds the resulting
     RowTypes row via `_rt_row_empty` / `_rt_row_var` /
     `_rt_row_extend`; writes the final pool_idx to
     `*out_row_ref`. Returns `CR_OK` or `CR_ERR_SYNTAX` /
     `CR_ERR_UNKNOWN_CAP` / `CR_ERR_POOL_FULL`.
  - `_cr_check_env(required_row, env_mask) -> packed_u64` --
     environment-mask covering check: for every ROW_EXT label in
     `required_row` tests `(env_mask >> idx) & 1`. Bit clear ->
     packs the offending label id in the high 32 bits and sets
     low 32 to `CR_ERR_MISSING_CAP` (0x4303) -- the
     `E0820_MISSING_CAP` diagnostic. Anchor acceptance:
     `_cr_check_env(parsed("@{read}"), 0)` returns
     `(0x00_000000 << 32) | 0x4303 = 0x00000000_00004303`.
  - `_cr_render(row_ref, out, out_cap) -> packed_u64` -- round-
     trips the row back to `@{L1, L2, ..., rho}` source syntax.
     Returns `(bytes_written << 32) | status`.
- Ten primitive capability labels at table slots 0..9: `read`
  (idx 0), `write` (idx 1), `exec` (idx 2), `net` (idx 3), `fs`
  (idx 4), `cap_mint` (idx 5), `cap_grant` (idx 6), `kalloc`
  (idx 7), `ipc` (idx 8), `trap` (idx 9). Tag 0 = primitive,
  1 = user-declared. Slot 9's name `trap` is identical in bytes to
  R224.M3 EffectRow slot 4 `trap`; the two tables are per-module
  (`_er_label_table` vs `_cr_label_table`) and the word is
  contextually distinguished by the owning annotation sigil
  (`!{trap}` vs `@{trap}`).
- Pool encoding: a capability row IS a RowTypes row
  (HM_KIND_TYROW = 4). The RowTypes `arg0` label-hash slot
  carries a packed `(tag << 24) | idx` label id (same convention
  as R224.M3 EffectRow); `arg1` field-type slot is 0 (cap labels
  are nullary); `arg2` is the pool_idx of the rest-of-row.
- Label-table layout: 32 slots x 16-byte stride = 512 B .bss. Per
  slot: `[+0] len (u8), [+1] tag (u8), [+2..3] reserved (u16 zero),
  [+4..15] name (u8[12] right-padded with zero)`.
- Row-variable convention: identifiers whose first three bytes are
  `'r','h','o'` are row-variable tails (same precedent as R224.M3;
  none of the ten primitive capability labels starts with "rho").
- Error band 0x4300..0x43FF (ten slots used: `CR_ERR_SYNTAX` 0x4300,
  `CR_ERR_UNKNOWN_CAP` 0x4301, `CR_ERR_LABEL_TABLE_FULL` 0x4302,
  `CR_ERR_MISSING_CAP` 0x4303, `CR_ERR_POOL_FULL` 0x4304,
  `CR_ERR_OUT_TOO_SMALL` 0x4305, `CR_ERR_KIND_MISMATCH` 0x4306,
  `CR_ERR_UNSATISFIABLE_ROW` 0x4307, `CR_ERR_INFLATED_ROW` 0x4308,
  `CR_ERR_UNKNOWN_ROWVAR` 0x4309; 246 slots reserved for M4.1+).
  Diagnostic-family mapping: `E0820_MISSING_CAP` = 0x4303,
  `E0821_UNSATISFIABLE_ROW` = 0x4307,
  `E0822_UNKNOWN_CAP` = 0x4301, `E0823_INFLATED_ROW` = 0x4308.
- Two intra-library linker dependencies (R225.M2 RowTypes:
  `_rt_row_empty`, `_rt_row_var`, `_rt_row_extend`, `_rt_find`;
  R225.M1 HmCore `_hm_pool` .bss symbol for node-address
  arithmetic on walked cursors). No cross-library dependency.
  (CapRow does NOT call `_rt_row_select`; the env-mask covering
  check is a direct bit test on the packed-id-extracted idx.)
- `_cr_parse_scratch : [u8; 64]` dedicated module-local scratch
  (16 u32 packed-label-id slots) -- deliberately disjoint from
  R225.M1 `_hm_subst_table`, R225.M2's `[384..512)` restrict/
  concat slice, AND R224.M3 `_er_parse_scratch` so effect-row and
  capability-row parse can be invoked from the same shell turn.
- Label prefix `cr_` with per-function suffix (`cr_ini_`,
  `cr_look_`, `cr_int_`, `cr_sw_`, `cr_p_`, `cr_ce_`, `cr_r_`);
  grep-confirmed disjoint from the parallel `cl_` (R221.M4
  CtxLexer) and every sibling parser-tier module in this library.
- `design/shell/capability-row-typing.md` (R224.M4 spec; 20-test
  acceptance corpus enumerated at §7, 8-lambda adversarial anchor
  at cases 11-18).

#### Changed

- `src/lib.pdx`: `LPX_PDS_PARSER_R224_M4_READY` flipped from 0 to 1
  (version bump shared with the R221.M4 arm above); module-filename
  comment extended with `src/cap_row.pdx at R224.M4`; upstream-
  issues comment extended with `paideia-os#2678 (R224.M4 CapRow)`;
  design-doc list extended with
  `design/shell/capability-row-typing.md`.
- `caps.decl`: added the full 0x4300..0x43FF band section (ten
  slots used, 246 reserved for M4.1+), the R224.M4 landing
  paragraph in the per-milestone catalogue (replacing the former
  R224.M4+ forward-reference comment), the `0x430[0-9]\b` grep-
  disjointness confirmation line, and the R224.M4 linker-
  dependency entry (two intra-library deps on RowTypes four-symbol
  surface + HmCore `_hm_pool`; no cross-library dep).
- `STATUS.md`: R224.M4 moved from "deferred" to "landed"; the R224
  wave checklist gains the M4 row; the error-band accounting table
  gains the `cap_row` + `cap_row-M4.1+` rows.

#### Design notes

- Q-A2 "substructural capability lattice" chosen over Q-A2a
  (effect+capability conflation; rejected because effects and
  caps have opposite subtyping directions), Q-A2b (flat set
  bitmask; rejected because it closes the open-row discipline),
  and Q-A2c (nominal cap handles; rejected because the surface
  syntax can't be hand-typed without kernel-minted handles).
- The capability-row annotation sigil is `@` (0x40), disjoint
  from R224.M3 EffectRow's `!` (0x21). A lambda type may carry
  both annotations in either order (`!{io} @{read}` or
  `@{read} !{io}`); the LambdaLit splice-point at M4.5 is where
  the ordering convention is enforced.
- Env-mask covering uses a reg+reg `and r, r` after a
  `shl r, cl` to build the per-idx mask (shift-by-cl is encoder-
  validated per `pdxfs/allocator.pdx`, `hda/widget_graph.pdx`,
  `tb/trusted_device.pdx` precedent). This avoids any
  `and rN, imm64` which is the pitfall-listed forbidden form.
- Open-row tails at M4 are optimistically treated as `CR_OK`; a
  dedicated M4.2 landing tightens the open-row discipline
  (ROW_VAR tail against a closed env must bind the row-var to
  the empty row before the covering check concludes OK).
- Per-row-var naming is deferred to M4.3; every ROW_VAR renders
  as a bare "rho" at M4.
- Q-A2 substructural-lattice enforcement (linear caps cannot
  repeat at a call site) is deferred to M4.7; raw M4 treats every
  row-ext as a nominal label.
- Wave 120 lazy-init lesson (R224.M3 EffectRow's debugger-patch
  pattern) is replicated at every CapRow public API that reads
  the label table: `_cr_label_lookup`, `_cr_label_intern`,
  `_cr_parse`, `_cr_check_env`, and `_cr_render` all call
  `_cr_init` idempotently at entry so a direct caller may invoke
  the surface without a separate boot step.

#### Linker dependencies

- Intra-library: `_rt_row_empty`, `_rt_row_var`, `_rt_row_extend`,
  `_rt_find` (R225.M2 RowTypes); `_hm_pool` .bss symbol (R225.M1
  HmCore).
- No external cross-library dependency.
- All seven public entry points can be linked against the
  RowTypes/HmCore objects that R225.M1/M2 already consume.

## [1.17.0] -- 2026-10-15

R224.M3 of the lambda-lang umbrella (paideia-os#2488, decomposed
into paideia-os#2677 for this M3) -- EFFECT POLYMORPHISM: a parser-
tier effect-row sub-grammar and a width-covariant subtype check
layered over R225.M2 Rémy row polymorphism. Lambdas carry effect
rows (`A -> B !{io, mem, rho}`) that the type-checker tracks across
invocations; the pure-argument rejection anchor case
(`_er_check_subtype({io}, {})`) returns
`ER_ERR_IMPURE_PASSED_PURE` packed with the offending label id.
Lands in parallel with Wave 120's R221.M3 WidthPass (1.16.0 above)
and the parallel R133.M5 kernel-side `pds_typecheck_gate` arm (no
parser-lib surface).

### Added

- `src/effect_row.pdx` module `EffectRow` (R224.M3,
  paideia-os#2677): effect-polymorphic row sub-grammar for the
  paideia-shell lambda surface, following Q-A3 "all effects in
  rows". Six public entry points:
  - `_er_init() -> ()` -- lazy-populate the 32-slot label-intern
     table (6 primitives + 26 user-declared slots) from the
     96-byte static source table `_er_primitive_init`.
     Idempotent (count-non-zero short-circuit).
  - `_er_label_lookup(ptr, len) -> packed_u64` -- linear scan over
     `_er_label_table[0..count)`; returns `(tag << 24) | idx` on
     hit, `0xFFFFFFFF` on miss.
  - `_er_label_intern(ptr, len) -> packed_u64` -- lookup-then-
     extend; allocates a user-declared slot (`tag = 1`) when the
     table has room and the name fits in 12 bytes; returns
     `0xFFFFFFFF` on table-full or over-long.
  - `_er_skip_ws(bytes, len, cursor) -> cursor` -- pure-leaf WS
     walker over the WS class {0x20, 0x09, 0x0A, 0x0D}.
  - `_er_parse(bytes, len, out_row_ref) -> status` -- parses
     `WS* ! WS* { LabelList? } ` and builds the resulting
     RowTypes row via `_rt_row_empty` / `_rt_row_var` /
     `_rt_row_extend`; writes the final pool_idx to
     `*out_row_ref`. Returns `ER_OK` or `ER_ERR_SYNTAX` /
     `ER_ERR_UNKNOWN_LABEL` / `ER_ERR_POOL_FULL`.
  - `_er_check_subtype(sub_row, sup_row) -> packed_u64` -- width-
     covariant subtype: for every ROW_EXT label in `sub_row` demands
     the label be present in `sup_row` via `_rt_row_select`.
     Returns `ER_OK` on success; on failure packs the offending
     label id in the high 32 bits and sets low 32 to
     `ER_ERR_IMPURE_PASSED_PURE` (0x4003). Anchor acceptance:
     `_er_check_subtype({io}, {})` returns
     `(0x00_000000 << 32) | 0x4003`.
  - `_er_render(row_ref, out, out_cap) -> packed_u64` -- round-
     trips the row back to `!{L1, L2, ..., rho}` source syntax.
     Returns `(bytes_written << 32) | status`.
- Six primitive effect labels at table slots 0..5: `io` (idx 0),
  `sysreg` (idx 1), `mem` (idx 2), `caps` (idx 3), `trap` (idx 4),
  `allocates` (idx 5). Tag 0 = primitive, 1 = user-declared.
- Pool encoding: an effect row IS a RowTypes row (HM_KIND_TYROW = 4).
  The RowTypes `arg0` label-hash slot carries a packed
  `(tag << 24) | idx` label id (24-bit idx with 32-slot cap; 8-bit
  tag) rather than an FNV-1a 32 hash; the row-aware unifier
  `_rt_row_unify` handles both interpretations verbatim because
  label identity reduces to a 32-bit `cmp` on `arg0`. The RowTypes
  `arg1` field-type slot is 0 (effect labels are nullary; two zero
  pool_idx values match trivially at `_rt_row_unify`'s identity
  check).
- Label-table layout: 32 slots x 16-byte stride = 512 B .bss. Per
  slot: `[+0] len (u8), [+1] tag (u8), [+2..3] reserved (u16 zero),
  [+4..15] name (u8[12] right-padded with zero)`.
- Row-variable convention: any identifier whose first three bytes
  are `'r','h','o'` is a row-variable tail (no reserved-word
  table). `rho`, `rho_1`, `rho_tail`, `rhotable` are all row-vars.
- Error band 0x4000..0x40FF (eight slots used: ER_ERR_SYNTAX at
  0x4000, UNKNOWN_LABEL 0x4001, LABEL_TABLE_FULL 0x4002,
  IMPURE_PASSED_PURE 0x4003, POOL_FULL 0x4004, OUT_TOO_SMALL 0x4005,
  KIND_MISMATCH 0x4006, UNKNOWN_ROWVAR 0x4007; 248 slots reserved
  for M3.1+ follow-ups).
- Two intra-library linker dependencies (R225.M2 RowTypes:
  `_rt_row_empty`, `_rt_row_var`, `_rt_row_extend`, `_rt_find`,
  `_rt_row_select`; R225.M1 HmCore `_hm_pool` .bss symbol for
  node-address arithmetic on walked cursors). No cross-library
  dependency.
- `_er_parse_scratch : [u8; 64]` dedicated module-local scratch
  (16 u32 packed-label-id slots) -- deliberately disjoint from
  R225.M1 `_hm_subst_table` and R225.M2's `[384..512)` restrict/
  concat slice so effect-row parse and record-row restrict/concat
  can be reviewed and evolved independently.
- Label prefix `er_` with per-function suffix (`er_ini_`,
  `er_look_`, `er_int_`, `er_sw_`, `er_p_`, `er_cs_`, `er_r_`).
- `design/shell/effect-polymorphism.md` (R224.M3 spec; 20-test
  acceptance corpus enumerated at §7).

### Changed

- `src/lib.pdx`: version 1.16.0 -> 1.17.0;
  `LPX_PDS_PARSER_R224_M3_READY` flipped from 0 to 1; module-
  filename and upstream-issues comment extended for the new
  module + the new design doc.
- `caps.decl`: added the full 0x4000..0x40FF band section (eight
  slots used, 248 reserved for M3.1+), the R224.M3 landing
  paragraph in the per-milestone catalogue (replacing the former
  R224.M3+ forward-reference comment), the `0x400[0-7]\b` grep-
  disjointness confirmation line (with explicit notes on 0x4000
  as the `OpenType ScriptList` canonical offset, AArch64 PA/MTE
  instruction family bit, boot-trampoline base, and ACPI opcode
  neighbourhood all sitting in disjoint semantic namespaces), the
  Wave 120 kilo-step disjointness note (R224.M3 at 0x4000..0x40FF
  on a new boundary past the R221.M3 WidthPass 0x3F00..0x3FFF
  carve-out and the R133.M5 reserved 0x3E00..0x3EFF kernel slot),
  and the R224.M3 linker-dependency entry (two intra-library deps
  on RowTypes/HmCore; no cross-library dep).
- `STATUS.md`: R224.M3 moved from "deferred" to "landed"; the
  R224 wave checklist gains the M3 row; the error-band accounting
  reconciled for the landed 0x4000..0x40FF carve-out plus the
  reserved 0x4008..0x40FF tail.

### Design notes

- Q-A3 "all effects in rows" chosen over Q-A3a (intrinsic set;
  closes the universe at compile time, breaks user-declared
  effects at M3.6+), Q-A3b (monadic lift; HM-polymorphism-over-m
  not available at M3, ergonomics break one-arrow-two-rows
  symmetry), and Q-A3c (effect+capability conflation;
  intentionally kept separate because R224.M4 lands a parallel
  capability row on the same arrow).
- Width-covariant subtyping is the correct direction because an
  arrow's effect row describes what the function MAY DO; a
  consumer that is willing to accept MORE effects can safely use
  a function that performs FEWER. The producer (sub) is thus
  obligated to be a subset of the consumer's permission (sup).
- Open-row tails at M3 are optimistically subsumed; a dedicated
  M3.2 landing tightens the open-row discipline (sub tail
  ROW_VAR against a closed sup must bind the row-var to the
  empty row before the subsume can conclude OK).
- Per-row-var naming is deferred to M3.3; every ROW_VAR
  renders as a bare "rho" at M3.
- `_er_declare` user-declared-effect intern surface is deferred
  to M3.6; raw M3 treats intern-miss on a non-primitive as
  ER_ERR_UNKNOWN_LABEL.

### Linker dependencies

- Intra-library: `_rt_row_empty`, `_rt_row_var`, `_rt_row_extend`,
  `_rt_find`, `_rt_row_select` (R225.M2 RowTypes); `_hm_pool`
  .bss symbol (R225.M1 HmCore).
- No external cross-library dependency.
- All six public entry points can be linked against the
  RowTypes/HmCore objects that R225.M1/M2 already consume.

## [1.16.0] -- 2026-10-15

R221.M3 of the parser-tier Unicode + lexer umbrella
(paideia-os#2485, decomposed into paideia-os#2653 for this M3) --
TR#11 WIDTH PASS: a parser-tier East-Asian-Width column classifier
and cluster-aware column accumulator that drives cursor-advance and
column-math for the pds-lang REPL line editor and the terminal grid
renderer.

### Added

- `src/width_pass.pdx` module `WidthPass` (R221.M3,
  paideia-os#2653): TR#11 column classifier + cluster-aware
  accumulator over the R221.M2 TR#29 cluster graph and the
  R131.M5 substrate `_width_char`.
  - `_wp_char_width(cp) -> width_u64` -- delegates to substrate
     `_width_char` for the primary classification; overlays an
     18-range parser-tier A-class table in `.rodata` iff the
     active locale amb state is 2 (East-Asian locale).
  - `_wp_cluster_width(bytes, bytes_len) -> width_u64` -- decodes
     the cluster's base cp via substrate `utf8_decode_cp` and
     classifies via `_wp_char_width`. Combining marks after the
     base are width-0 by substrate classification, so a cluster's
     TR#11 width is its base's width per TR#11 §5.
  - `_wp_cols(bytes, bytes_len) -> (cols << 32) | status` --
     walks the input one TR#29 cluster at a time via R221.M2
     `_gi_next_cluster` and sums per-cluster widths. Partial
     accumulator is still meaningful on INVALID_UTF8.
  - `_wp_locale_amb_width() -> u64` -- reads the `.bss` singleton
     `_wp_locale_amb_state` (stored as `width - 1` so .bss
     zero-init decodes to the Western-locale narrow default) and
     returns `width` in {1, 2}.
  - `_wp_set_locale_amb(width) -> status` -- validates the input
     is in {1, 2} and writes `_wp_locale_amb_state := width - 1`.
     Rejection returns `WP_ERR_BAD_LOCALE_WIDTH` (0x3F01).
- 18-range A-class overlay table in `.rodata` (144 B aligned to 8)
  covering Latin-1 Supplement, Latin Extended-A, spacing modifiers,
  Greek + Coptic, Cyrillic, General Punctuation (coarse), Super /
  subscripts, Letterlike Symbols, Number Forms, Arrows, Mathematical
  Operators, Enclosed Alphanumerics, Box Drawing + Block Elements,
  Geometric Shapes, Miscellaneous Symbols, Dingbats (coarse), and
  Heavy-large-circle neighbourhood (U+2B55..U+2B59).
- `.bss` singleton `_wp_locale_amb_state : u64` (aligned to 8).
- Error band 0x3F00..0x3FFF (two slots used: WP_ERR_INVALID_UTF8
  at 0x3F00 and WP_ERR_BAD_LOCALE_WIDTH at 0x3F01; 254 slots
  reserved for M3.1+ follow-ups: locale-amb precise table,
  Hangul-Jamo scalar handling, TR#14 line-break integration).
- Three external linker symbols (`_width_char` and `utf8_decode_cp`
  from libpdx-unicode-tables; `_gi_next_cluster` intra-library from
  R221.M2). No new KIND surface; no new ambient capability.
- Label prefix `wp_` with per-function suffix (`wp_cw_`, `wp_cl_`,
  `wp_co_`, `wp_la_`, `wp_sl_`).
- `design/shell/width-pass-tr11.md` (R221.M3 spec).

### Changed

- `src/lib.pdx`: version 1.15.0 -> 1.16.0;
  `LPX_PDS_PARSER_M3_READY` flipped from 0 to 1; module-filename
  and upstream-issues comment extended for the new module + the new
  design doc.
- `caps.decl`: added the full 0x3F00..0x3FFF band section (two
  slots used, 254 reserved for M3.1+), the R221.M3 landing paragraph
  in the per-milestone catalogue (replacing the forward-reference
  comment), the `0x3F0[0-1]\b` grep-disjointness confirmation line
  (with explicit notes on 0x3F8..0x3FF as COM1 I/O ports and
  0x3F00..0x3FFF as the DW_AT_hi_user DWARF vendor-attribute bound
  sitting in disjoint semantic namespaces), the R221.M3 linker-
  dependency entry (`_width_char` + `utf8_decode_cp` cross-library;
  `_gi_next_cluster` intra-library), and the Wave 119.5 kilo-step
  disjointness note (R221.M3 at 0x3F00..0x3FFF; 0x3E00..0x3EFF
  reserved for the parallel R133.M5 kernel arm).
- `STATUS.md`: M3 moved from "deferred" to "landed"; error-band
  accounting table reconciled for landed R221.M2 (0x3800..0x3803)
  + R221.M3 (0x3F00..0x3F01) slots and the matching reserved
  carve-outs.

## [1.15.0] -- 2026-10-15

Wave 119 parallel landing: R222.M4 (ArgSpec + FlagSpec typing). Lands
alongside R229.M3 TypeEnv (1.14.0 above) and the parallel R133.M4
kernel-side arm (no parser-lib surface).

### Added

- `src/arg_flag_spec.pdx` module `ArgFlagSpec` (R222.M4,
  paideia-os#2661): HM-typed argument + flag descriptors +
  invocation-time type-checker.
  - `_afs_parse_arg_spec_body(bytes, bytes_len, out, out_cap)
     -> (bytes_written << 32) | status` -- parses `arg : NAME : TYPE
     [? ...]*` decls into 32-byte ArgSpec records (magic 'ARGS',
     pos u16, flags u16 OPTIONAL/VARIADIC, type_code u8, name_len u8,
     name_inline `[u8; 14]`, default_ref u64).
  - `_afs_parse_flag_spec_body(bytes, bytes_len, out, out_cap)
     -> (bytes_written << 32) | status` -- parses `flag : --LONG [,
     -S] [: TYPE] [+]` decls into 32-byte FlagSpec records (magic
     'FLAG', flags u16 TAKES_VALUE/REPEATABLE, short_char u8,
     long_len u8, long_name `[u8; 14]`, type_code u8).
  - `_afs_check_invocation(args_body, args_len, flags_body,
     flags_len, invocation, inv_len) -> status` -- walks the
     ArgDesc stream of a FunctorInstance (R222.M3) materialization
     record against the ArgSpec + FlagSpec records, promoting
     mismatches to packed-status diagnostics referenced to each
     ArgDesc's `(ref_ptr, length)` source span.
  - Pure-leaf helpers: `_afs_skip_ws`, `_afs_classify_type` (mirrors
     R222.M1 SchemasSig byte-for-byte), `_afs_parse_as_type`
     (per-type byte-run validator).
  - Type codes AFS_TYPE_* (U64=1, I64=2, STR=3, HEX=4, HASH32=5,
     TSC=6, PATH=8, PID=9) mirror SchemasSig SS_TYPE_* and
     FunctorInstance FI_TYPE_* byte-for-byte.
  - Error band 0x3C00..0x3C0A (11 slots: SYNTAX, UNKNOWN_TYPE,
     TOO_MANY_ARGS, TOO_MANY_FLAGS, OUT_TOO_SMALL, BAD_INVOCATION,
     TYPE_MISMATCH, MISSING_REQUIRED, UNKNOWN_FLAG, FLAG_NO_VALUE,
     EXTRA_POS). Slots 0x3C0B..0x3CFF reserved for R222.M5+.
- Record layout notes:
  - Both records are strict 32 bytes (power-of-2 stride for
    `shl rN, 5`). The brief's trailing `reserved[4]` on ArgSpec and
    `reserved[11]` on FlagSpec would have overflowed the stated
    32-byte total; this landing shrinks the FlagSpec trailer to
    `reserved[9]` and drops the ArgSpec trailer entirely.
  - HASH32 wire shape = `"0x" + exactly 16 hex digits` (64-bit
    identity hash, matching FNV-1a 64 used elsewhere in R222).
- Pure in-process; no KIND surface; no external linker dependency.
- Label prefix `afs_` (grep-confirmed free of linker-visible symbol
  collisions; libpdx-audit's audit_file_sink uses the same prefix for
  FUNCTION-LOCAL labels, which do not cross the object-graph
  boundary).
- `design/shell/arg-flag-spec-typing.md` (R222.M4 spec).

### Changed

- `src/lib.pdx`: version 1.14.0 -> 1.15.0;
  `LPX_PDS_PARSER_R222_M4_READY` flipped to 1; module-filename list
  and upstream-issues comment extended for the new module + the new
  design doc.
- `caps.decl`: added the full 0x3C00..0x3CFF band section, the
  R222.M4 landing paragraph to the per-milestone catalogue, the
  `0x3C0[0-9A]\b` grep-disjointness confirmation line (with explicit
  note that 0x3C00 as the fp16 bit pattern for 1.0 in scrgb /
  hdr10_transform / scrgb_synth sits in a disjoint semantic
  namespace), and the R222.M4 linker-dependency entry (NO external
  linker deps; no cross-library dep; no cross-module CALL into
  functor_instance.pdx -- the invocation record is consumed BY VALUE
  through the caller-passed byte pointer).

## [1.14.0] -- 2026-10-15

R229.M3 of the semantic-shell REPL evaluator umbrella
(paideia-os#2493, decomposed into paideia-os#2721 for this M3) --
TYPE-ENVIRONMENT THREADING: a per-session scheme store keyed by
`(session_id, scheme_id)` plus a memoised specialisation cache keyed
by `(session_id, scheme_id, type_vector_hash)`. The piece R229.M2
(SessionEnv) deferred: SessionEnv stores a u32 type_ref and leaves
the interpretation to the REPL dispatch; for a POLYMORPHIC binding
`let id = \x. x : forall a. a -> a`, the type_ref is now a TypeEnv
scheme_id (SessionEnv scheme_kind = SE_SCHEME_BLOB = 2), and
`_te_specialize` returns a cached monomorphic body on repeat uses
within the same session.

### Added

- `src/type_env.pdx` module `TypeEnv` (R229.M3, paideia-os#2721):
  session-scoped scheme store + specialisation cache.
  - `_te_init_session(session_id) -> errno` -- zero the per-session
    scheme row (4096 B), cache row (1024 B), and head row (8 B).
  - `_te_insert_scheme(session_id, scheme_body, scheme_len,
     out_scheme_id) -> errno` -- append-only insert at the session's
    scheme_count; writes 1-based scheme_id via out pointer.
  - `_te_specialize(session_id, scheme_id, type_vec_hash,
     out_body_ref) -> errno` -- hit the 64-entry cache row on
    `(valid, scheme_id, hash)` match; on miss, call
    `_hm_instantiate` (R225.M1 cross-module) and cache the result at
    cache_cursor (round-robin FIFO over 64 slots). Propagates
    HM_ERR_* as TE_ERR_HM_* (0x3D05/0x3D06/0x3D07/0x3D08).
  - `_te_evict_scheme(session_id, scheme_id) -> errno` -- tombstone
    the scheme slot (kind := EMPTY) and invalidate every matching
    cache entry (valid := 0); scheme_count is NOT decremented
    (append-only, like SessionEnv).
- Scheme slot layout (256 B stride, TE_SCHEME_SLOT_BYTES): kind u8,
  flags u8, reserved u16, scheme_len u32, scheme_body u8[248].
- Cache entry layout (16 B stride, TE_CACHE_ENTRY_BYTES): valid u8,
  reserved u8[3], scheme_id u32, hash u32, body_ref u32.
- Working-memory singleton `.bss` state:
  - `_te_scheme_pool : [u8; 32768] @align(8)` -- 8 sessions x 4096 B.
  - `_te_cache_pool  : [u8; 8192]  @align(8)` -- 8 sessions x 1024 B.
  - `_te_head_table  : [u8; 64]    @align(8)` -- 8 x 8-byte head rows
    (scheme_count u8 + cache_cursor u8 + reserved u8[6]).
- Error band 0x3D00..0x3D08 (9 slots: TE_OK, TE_ERR_BAD_SESSION,
  TE_ERR_BAD_SCHEME_ID, TE_ERR_NOT_FOUND, TE_ERR_TOO_MANY,
  TE_ERR_BAD_LEN, TE_ERR_HM_POOL_FULL, TE_ERR_HM_MISMATCH,
  TE_ERR_HM_OUT_TOO_SMALL, TE_ERR_HM_OCCURS). Slots 0x3D09..0x3DFF
  reserved for R229.M4+.
- `design/shell/type-env-threading.md` (R229.M3 spec).

### Changed

- `src/lib.pdx`: version 1.13.0 -> 1.14.0;
  `LPX_PDS_PARSER_R229_M3_READY` flipped to 1; module-filename list
  and upstream-issues comment extended for the new module + the new
  design doc. (`LPX_PDS_PARSER_R229_M3_READY` semantics tightened:
  originally labelled "REPL dispatch + full-scheme storage"; the
  full-scheme storage half lands HERE as TypeEnv, with the dispatch
  half deferred to the kernel-side REPL layer -- the lib flag now
  reads "Type-environment threading (scheme store + specialisation
  cache)".)
- `caps.decl`: added the R229.M3 TypeEnv paragraph to the per-
  milestone catalogue; added the full 0x3D00..0x3DFF band section;
  added the `0x3D0[0-8]` grep-disjointness confirmation line; added
  the R229.M3 linker-dependency note (NO external cross-library
  dep; intra-library dep on hm_core.pdx `_hm_instantiate` only).
- `STATUS.md`: version 1.13.0 -> 1.14.0; R229.M3 added to the
  Current milestones paragraph; R229.M3 checklist filled out; the
  Error-band accounting table gains a `type_env` row.

### Design notes

- SessionEnv's existing `scheme_kind == SE_SCHEME_BLOB (2)` tag is
  now operational: the REPL dispatch at R229.M3+ allocates TypeEnv
  scheme_ids and writes them into SessionEnv Binding records' u32
  type_ref payload. On lookup, dispatch reads scheme_kind; if 2, it
  calls `_te_specialize` to materialise a monomorphic body. On
  unset, dispatch calls `_te_evict_scheme` BEFORE
  `_se_unset_binding` so the cache is scrubbed first.
- Specialisation cache is round-robin FIFO (64 entries per session,
  one write cursor per session in head[sid*8+1]). A read-heavy
  session where the same polymorphic binding is used repeatedly
  with the same instantiations hits the cache; a session that
  cycles through more than 64 distinct instantiations rotates the
  oldest out. This is a conservative baseline; R229.M5+ may swap
  for an LRU once the eviction cost is observed.
- Scheme storage is append-only + tombstone-evict (no compaction at
  M3): a session that evicts and re-inserts a scheme consumes two
  scheme_id slots. 16 slots per session comfortably seats the
  15-turn test from paideia-os#2721. Compaction is R229.M5+.
- `_te_specialize` is the ONE nested-CALL function in TypeEnv; the
  Wave-118 lesson (full-u64 cmp on CALL return) is honoured on the
  `_hm_instantiate` status check, and the two post-CALL `.bss`
  accesses reload `_te_head_table` + `_te_cache_pool` via fresh
  `lea r11, [rip+sym]` because the nested CALL clobbers r11.

### Notes

- No new kernel KIND dependency.
- `_te_insert_scheme` + `_te_evict_scheme` are pure-leaf scanners
  (6-push callee-save frames, no `sub rsp` pad). `_te_specialize`
  takes a `sub rsp, 8` for its body_idx local AND to align
  rsp%16==0 at the nested `_hm_instantiate` CALL.
- Fingerprint emission deferred to R229.M3-dispatch (same posture
  as SessionEnv at R229.M2); the structured TE_* enum is the
  observation point until a REPL-dispatch asserting-smoke-mode
  golden lands.

## [1.13.0] -- 2026-10-15

Wave 118 parallel landing: R221.M2 (TR#29 grapheme cluster iterator)
+ R222.M3 (functor instantiation materialization record). R133.M3
(kernel-side import graph traversal + cycle detection) also lands in
the same wave; it has no parser-lib surface.

### Added

- `src/grapheme_iter.pdx` module `GraphemeIter` (R221.M2,
  paideia-os#2652): TR#29 grapheme-cluster boundary iterator.
  - `_gi_next_cluster(bytes, bytes_len, cursor_byte) -> (next_cursor, status)`
  - `_gi_prev_cluster(bytes, bytes_len, cursor_byte) -> (prev_cursor, status)`
  - `_gi_tokenize_args(bytes, bytes_len, out, out_cap) -> (n_tokens, status)`
  - ASCII fast path (pure leaf); slow path routes through
    libpdx-unicode-tables `_gc_next` for the Latin+emoji baseline.
  - Error band 0x3800..0x3803 (INVALID_UTF8, OUT_TOO_SMALL,
    TOO_MANY_TOKENS, BAD_CURSOR).
- `src/functor_instance.pdx` module `FunctorInstance` (R222.M3,
  paideia-os#2660): functor-instantiation materialization record.
  - `_fi_instantiate(inv, inv_len, cs, cs_len, out, out_cap) -> (bytes_written, status)`
  - `_fi_elaborate_args(mat, mat_len, cs_body, cs_len) -> status`
  - 64B header (magic 'FINS') + 32B arg descriptors (up to 16 args).
  - Error band 0x3900..0x3906.
- `design/shell/grapheme-cluster-boundaries-tr29.md` (R221.M2 spec).
- `design/shell/functor-instantiation.md` (R222.M3 spec).
- `design/kernel/pds-import-graph.md` (R133.M3 spec, kernel-side).

### Changed

- `src/lib.pdx`: version 1.12.0 -> 1.13.0; `LPX_PDS_PARSER_M2_READY`,
  `LPX_PDS_PARSER_R222_M3_READY` flipped to 1; module-filename list
  and upstream-issues comment extended for the two new modules + the
  two new design docs.
- `caps.decl`: added full 0x3800..0x38FF (R221.M2) and
  0x3900..0x39FF (R222.M3) band sections; added disjointness note
  + grep-confirmation lines; added R221.M2 and R222.M3 linker-
  dependency entries (R221.M2 depends on libpdx-unicode-tables
  `_gc_next`; R222.M3 has no external deps).

## [1.12.0] -- 2026-10-14

R229.M2 of the semantic-shell REPL evaluator umbrella (paideia-os#2493,
decomposed into paideia-os#2720 for this M2) -- SESSION-SCOPED
BINDINGS: a per-session persistent map `name -> (scheme_kind,
type_ref, value_ref)` that threads the HM-inferred type scheme AND
the evaluator's value reference across REPL turns. R229.M1
(src/kernel/core/shell/repl_loop.pdx) landed the per-cycle state
machine; R229.M2 (THIS landing) lands the piece R229.M1 deferred so a
`let x = find . | count` on turn N resolves `x` identically on turns
N+1..N+20..session end or explicit `unset x`.

### Added

- `src/session_env.pdx` module `SessionEnv`: user-space parser-tier
  primitive that owns the per-session binding store.
  - `_se_init() -> ()` -- boot hook, defensive 64-byte scrub of
    `_se_head_table`.
  - `_se_init_session(session_id) -> errno` -- attaches / resets the
    1024-byte per-session row and clears its head counter.
  - `_se_insert_binding(session_id, name_ptr, name_len,
     scheme_kind, type_ref, value_ref) -> errno` -- last-wins insert
    with linear-scan name match; appends at head on miss, overwrites
    scheme_kind/type_ref/value_ref in place on hit.
  - `_se_lookup_binding(session_id, name_ptr, name_len,
     out_type_ref_ptr, out_value_ref_ptr) -> errno` -- first-match
    lookup; each out pointer is independently nullable (`0` = skip).
  - `_se_unset_binding(session_id, name_ptr, name_len) -> errno` --
    zero-cost tombstone (kind := 0, name_len := 0); type_ref /
    value_ref left intact.
- Record layout (32 B stride, SE_BINDING_BYTES): kind u8, name_len
  u8, scheme_kind u8, flags u8, type_ref u32, name_inline [u8;16],
  value_ref u64.
- Working-memory singleton `.bss` state:
  `_se_env_pool : [u8; 8192] @align(8)` (8 sessions x 1024 bytes),
  `_se_head_table : [u8; 64] @align(8)` (8 x u64).
- Capacity caps: `SE_MAX_SESSIONS = 8`, `SE_MAX_BINDINGS = 32` per
  session, `SE_NAME_MAX = 16` bytes inline.
- Error band `0x3700..0x37FF` (R229.M2 SessionEnv):
  - `SE_OK = 0`
  - `SE_ERR_BAD_SESSION = 0x3700`
  - `SE_ERR_BAD_NAME = 0x3701`
  - `SE_ERR_TOO_MANY = 0x3702`
  - `SE_ERR_NOT_FOUND = 0x3703`
  - `SE_ERR_BAD_SCHEME_KIND = 0x3704`
  Slots 0x3705..0x37FF reserved for M3+ (HM_POOL_FULL proxy,
  TOMBSTONE_EXHAUSTED on compaction, EXPORTED_IMMUTABLE on M4+
  cross-session rebind).
- Pure in-process; no KIND surface; no external linker dependencies.
- Label prefix `se_` (disjoint from `ss_` / `sh_` / `sj_` / `hf_` /
  `cr_` / `rl_` kernel namespaces and the parser-tier `u8n_` /
  `pl_` / `rp_` / `ll_` / `cc_` / `hm_` / `rt_` / `dl_` /
  `sch_sig_` / `cmd_sig_` namespaces).

### Changed

- `src/lib.pdx` bumps `LPX_PDS_PARSER_VERSION_MINOR` 11 -> 12 and
  adds the R229 feature-gate block
  (`LPX_PDS_PARSER_R229_M1_READY = 0` -- kernel-side; no lib surface,
   `LPX_PDS_PARSER_R229_M2_READY = 1`, M3..M6 reserved).
- `caps.decl` adds R229 to the Waves roster, adds the R229.M2
  landing paragraph + the R229.M3+ forward note to the per-milestone
  catalogue, adds the `0x3700..0x37FF` R229.M2 band entry, promotes
  the pre-reserved 0x3700..0x37FF note to a landed carve-out,
  appends the `0x370[0-4]` grep-disjointness confirmation line, and
  adds the R229.M2 linker-dependency note (pure-leaf; no cross-
  library dep; no cross-module call -- SessionEnv STORES a HmCore
  pool index but does not DEREFERENCE it).
- `STATUS.md` records R229.M2 as landed with the three-item
  milestone checklist (001 module, 002 design doc, 003 20-turn
  smoke corpus deferred to R229.M3).

### Design notes

- `design/shell/session-env.md` -- the Why (R229.M1 held cycle
  state; M2 holds session state); the 32-byte binding record
  (kind + name_len + scheme_kind + flags + type_ref u32 +
  name_inline [u8;16] + value_ref u64); the 8-session x 32-slot pool
  geometry; the 1024-byte per-session row stride (`shl r,10`);
  state semantics (insert / lookup / unset); the type-environment
  threading pseudo-code for R229.M3+ REPL dispatch; the return band
  disjointness proof; the 6-push pure-leaf scanner frame; the
  fingerprint matrix (5 OK tags, allowlisted until R229.M3 lands
  with asserting smoke-mode goldens); the forward path through
  R229.M3..R229.M6+.

### Notes

- `_se_init` is a plain init hook with no state inspection; the boot
  wiring will go into `src/kernel/boot/kernel_main.pdx` at R229.M3,
  immediately after `_rl_init` (R229.M1) and before `_hf_init`
  (R127.M7). This landing does NOT wire the boot order -- the
  parser-tier satellite does not know its own boot position.
- The 20-turn test cited in paideia-os#2720 lands as the asserting
  smoke-mode golden at R229.M3 (`smoke/session-env-m3.golden.txt`);
  M2 is substrate-only and allowlists its five OK fingerprints with
  R229.M3 as the retire condition.
- A caller that only wants the type (M3 typecheck pass) or only
  wants the value (M3+ fast evaluator path) passes a null pointer
  for the other out slot of `_se_lookup_binding`. The null-pointer
  convention mirrors R127.M4 `_shell_history_scan`.

## [1.11.0] -- 2026-10-14

R225.M2 of the semantic-shell typechecker umbrella (paideia-os#2489,
decomposed into paideia-os#2683 for this M2) -- ROW TYPES: Remy-style
row polymorphism for records with named fields, layered additively
over R225.M1's HmCore TypeNode pool. The second R225 wave on the
parser-tier satellite introduces a new node KIND
(`HM_KIND_TYROW = 4`) with three subkinds (ROW_EMPTY, ROW_EXT,
ROW_VAR), the field-extension / restriction / selection /
concatenation primitive family, and a row-aware general unifier that
correctly handles nested rows inside TyApp subterms (notably the
`record(row)` wrapper).

### Added

- `src/row_types.pdx` module `RowTypes`: parser-tier primitive family
  that recognises row types layered over HmCore's singleton
  `_hm_pool`. Eleven public entry points land at M2:
  - `_rt_find(idx) -> idx` -- extends `_hm_find`'s resolved-chain
    walk to cover ROW_VAR nodes (kind=4, subkind=2). Pure leaf.
  - `_rt_label_hash(ptr, len) -> u32-hash` -- FNV-1a 32 over caller
    bytes. Pure leaf. Uses `shl rax, 32; shr rax, 32` to defensively
    truncate the hash to 32 bits after each `mul rcx` (the FNV
    algorithm is defined mod 2^32).
  - `_rt_alloc_node() -> pool_idx` -- reserves one 16-byte slot in
    the shared `_hm_pool`, zero-fills it, bumps `_hm_pool_next`.
    Pure leaf. 0 return on pool-full.
  - `_rt_row_empty() -> pool_idx` -- allocates ROW_EMPTY (closed
    tail).
  - `_rt_row_var() -> pool_idx` -- allocates ROW_VAR with a fresh
    var_id from `_hm_var_next` (shared counter with hm_core).
  - `_rt_row_extend(label_hash, field_type_idx, rest_row_idx) ->
    pool_idx` -- allocates a ROW_EXT node whose arg0 is the label
    hash, arg1 is the field-type pool_idx, arg2 is the rest-row
    pool_idx.
  - `_rt_record_type(row_idx) -> pool_idx` -- allocates
    `TyApp(TyCon(RECORD, arity=1), row_idx)`.
  - `_rt_row_select(row_idx, label_hash, out_type_idx_ptr) -> errno`
    -- walks the row chain and writes the matching field's type
    pool_idx to `*out_type_idx_ptr`. Returns `RT_ERR_LABEL_MISSING`
    on EMPTY or VAR tail without a prior match.
  - `_rt_row_restrict(row_idx, label_hash, out_type_idx_ptr,
    out_rest_idx_ptr) -> errno` -- rebuilds the row with the matched
    extension spliced out. Reconstruction allocates fresh ROW_EXT
    nodes for every prefix field; the original row is preserved.
    Bounded at `RT_MAX_PREFIX_FIELDS = 10` fields of prefix.
  - `_rt_row_concat(row_a, row_b) -> packed((idx << 32) | status)` --
    appends row_a's fields onto row_b, rejecting the result when
    row_a terminates in a ROW_VAR tail (`RT_ERR_CLOSED_ROW`) or when
    any row_a label collides with a row_b label (`RT_ERR_LABEL_DUP`).
  - `_rt_row_unify(a_idx, b_idx) -> errno` -- row-aware recursive
    unifier. Dispatches on (kind_a, kind_b): both TyVar / both TyCon
    delegate to `_hm_unify`; both TyApp recurse on children (since
    they may themselves be rows); both TyRow use the Remy pivot on
    label mismatch. Self-recursive AND cross-recursive with
    `_hm_unify`.
  - 16-byte TyRow node layout: `[+0]` kind=4; `[+1]` arity (0 / 2 / 0
    for EMPTY / EXT / VAR); `[+2]` subkind (0 / 1 / 2 for EMPTY /
    EXT / VAR); `[+3]` flags (reserved for M4 effect-row annotation);
    `[+4]` arg0 (label_hash u32 / var_id u32 / 0); `[+8]` arg1
    (field-type pool_idx u32 / 0 / 0); `[+12]` arg2 (rest-row
    pool_idx / resolved pool_idx / 0). The +12 slot is shared with
    hm_core's HM_OFF_RESOLVED so `_rt_find` walks TyVar and ROW_VAR
    chains with one loop body.
  - New TyCon: `RT_CON_RECORD = 10`, arity 1 -- wraps a row into a
    type via `TyApp(TyCon(RECORD, 1), row)`. Con_id 9 is left
    unassigned as a deliberate gap between hm_core's binary range
    (1..8) and this unary wrapper, held for R225.M3's Datalog bridge.
  - Error band `0x3600..0x36FF` (R225.M2 RowTypes):
    `RT_OK = 0`, `RT_ERR_LABEL_MISSING = 0x3600`,
    `RT_ERR_LABEL_DUP = 0x3601`, `RT_ERR_POOL_FULL = 0x3602`,
    `RT_ERR_KIND_MISMATCH = 0x3603`, `RT_ERR_CLOSED_ROW = 0x3604`,
    `RT_ERR_OCCURS = 0x3605` (reserved; M4+ full row-occurs check),
    `RT_ERR_MISMATCH = 0x3606`.
  - Scratch usage: `_hm_subst_table[384..512)` for the restrict /
    concat prefix-field collection (10 entries of 8 bytes each). The
    slice is disjoint from hm_core's `_hm_instantiate` use of
    `[0..512)` and `_hm_generalise`'s split `[0..256)` + `[256..512)`
    because row-flavoured work and type-scheme work never happen
    inside the same shell turn.
  - Pure in-process; no KIND surface; no cross-library linker
    dependency. INTRA-library dependency on R225.M1 at two symbols:
    `_hm_unify` (called from `_rt_row_unify`'s TyVar/TyCon arms) and
    the shared `.bss` symbols `_hm_pool` / `_hm_pool_next` /
    `_hm_var_next`.
  - Label prefix `rt_` (unique against sibling parser-tier modules
    in this library: `u8n_`, `sch_sig_`, `cmd_sig_`, `pl_`, `rp_`,
    `ll_`, `cc_`, `hm_`, `dl_`, `se_`).

### Changed

- `src/lib.pdx` flips `LPX_PDS_PARSER_R225_M2_READY` from 0 to 1 and
  co-bumps `LPX_PDS_PARSER_VERSION_MINOR` (parallel R224.M2 + R225.M2
  + R229.M2 arms of Wave 117 land in a single consolidated version
  bump; this stanza is the per-primitive scratch per the parallel-
  wave CHANGELOG discipline and main consolidates at wave close).
  The module-filename comment is extended with `src/row_types.pdx at
  R225.M2`; the upstream-issues doc comment picks up
  `paideia-os#2683 (R225.M2 RowTypes)`.
- `caps.decl` adds the `0x3600..0x36FF` R225.M2 band entry (seven
  slots), the R225.M2 landing paragraph to the per-milestone
  catalogue (describing the row-walker + Remy unifier shape), the
  row_types entry in the linker-dependencies catalogue (NO cross-
  library deps; intra-library deps on `_hm_unify` + `_hm_pool` /
  `_hm_pool_next` / `_hm_var_next`), and the `0x360[0-6]` grep-
  disjointness confirmation line. The R225.M2+ typechecker-follow-
  ups paragraph retroactively splits into R225.M2 (now landed) and
  R225.M3+ (still reserved).
- `STATUS.md`: adds the R225 typechecker checklist section (listing
  M1 as previously landed and M2 as landed with this wave, M3..M10
  deferred); extends the error-band accounting table with the
  `row_types` + `row_types-M3+` rows.

### Design notes

- `design/shell/row-types-remy.md` (NEW): grammar extension, TyRow
  node layout, interaction with HmCore's shared pool, Remy pivot
  algorithm, status-code taxonomy (0x3600..0x36FF), encoder-pitfall
  discipline, stack-frame accounting (max recursion ~7.1 KiB), 40-
  test corpus enumeration (deferred to R225.M9), forward path
  through R225.M3+ (predicate-type bridge, effect rows, cross-
  context flow, rank-restricted enforcement, error-span attribution),
  references to Remy 1992 "Projective ML" and Pottier-Remy 2005
  "The essence of ML type inference".

### Linker dependencies

- `src/row_types.pdx` has NO cross-library linker dependency.
  INTRA-library dependency on R225.M1 (hm_core.pdx) at the symbols
  `_hm_unify`, `_hm_pool`, `_hm_pool_next`, and `_hm_var_next` --
  the shared type-graph pool + the canonical pure-HM unifier that
  `_rt_row_unify` delegates to on TyVar and TyCon arms. All eleven
  public entry points of row_types.pdx can be linked alongside
  hm_core.pdx standalone (no further cross-module dependency closes
  until R225.M3's SchemasSig bridge lands).

## [1.10.0] -- 2026-10-14

R224.M2 of the semantic-shell lambda-lang umbrella (paideia-os#2488,
decomposed into paideia-os#2676 for this M2) -- CLOSURE CAPTURE: the
explicit `[binding, binding, ...]` capture list that signals the
lambda will cross a process boundary (Q13 hybrid pipeline
serialization) and enumerates the per-binding capture mode. Lands as
the second R224 wave on the parser-tier satellite, companion to
R224.M1 LambdaLit (which parses the `\params -> body` header).

### Added

- `src/closure_capture.pdx` module `ClosureCapture`: parser-tier
  primitive that recognises a `[binding, binding, ...]` capture list
  and emits a flat 32-byte ClosureCaptureHeader followed by up to 16
  x 32-byte Binding descriptors.
  - `_cc_parse(bytes_ptr, bytes_len, out_ptr, out_cap) -> packed_u64`
    -- public entry point. Parses `[` + `Binding (',' Binding)*` +
    `]` where each Binding is `identifier (':' type_name)?`. The
    optional `:type_name` suffix selects BY_VALUE capture (sender
    serializes using the declared type); the bare-name form selects
    BY_REF capture (receiver resolves the name against its own
    session scope). Returns `(bytes_written << 32) | status`.
  - `_cc_parse_binding(bytes_ptr, bytes_len, cursor_in, write_ptr) ->
    packed_u64` -- cross-function helper that parses one Binding
    and writes a 32-byte Binding descriptor at write_ptr. Returns
    `(new_cursor << 32) | status`.
  - `_cc_skip_ws(bytes_ptr, bytes_len, cursor) -> new_cursor` --
    pure leaf whitespace skipper. Mirrors R224.M1 LambdaLit /
    R222.M1 SchemasSig / R226.M1 Datalog / R223.M2 RecordProjection
    skippers byte-for-byte so the whitespace discipline is a shared
    property of the pds-lang family.
  - `_cc_classify_type(ident_ptr, ident_len) -> type_code` -- pure
    leaf length-switched classifier over the eight M2-known type
    names (u64, i64, str, hex, hash32, tsc, path, pid). Byte-for-
    byte parallel to R224.M1 `_ll_classify_type` and R222.M1
    `_sch_sig_classify_type`.
  - ClosureCaptureHeader (32 B): magic u32 `'CCAP' = 0x50414343`,
    n_bindings u16, flags u16 (bit 0 = HAS_BY_VALUE, bit 1 =
    IS_EMPTY), bindings_offset u32 (= 32), bindings_len u32 (=
    n_bindings * 32), reserved `[u8; 16]`.
  - Binding descriptor (32 B each): type_code u8 (0 = untyped/BY_REF
    or 1..9 for CC_TYPE_* mirroring LL_TYPE_* / SS_TYPE_*), name_len
    u8, name_inline `[u8; 14]`, mode u8 (CC_MODE_BY_REF = 0 /
    CC_MODE_BY_VALUE = 1), reserved `[u8; 15]`.
  - Grammar M2 scope: `[binding (',' binding)*]`, empty `[]` legal
    (sets IS_EMPTY flag), max 16 bindings per list
    (CC_MAX_BINDINGS), max 14-byte identifier (CC_NAME_MAX).
  - Error band `0x3500..0x35FF` (R224.M2 ClosureCapture):
    - `CC_OK = 0`
    - `CC_ERR_SYNTAX = 0x3500`
    - `CC_ERR_TOO_MANY_BINDINGS = 0x3501`
    - `CC_ERR_UNKNOWN_TYPE = 0x3502`
    - `CC_ERR_OUT_TOO_SMALL = 0x3503`
    - `CC_ERR_NO_OPEN = 0x3504`
    - `CC_ERR_NO_CLOSE = 0x3505`
  - Pure in-process; no KIND surface; no external linker
    dependencies.
  - Label prefix `clo_` (grep-confirmed free of collision across
    `paideia-os/{src,tools,design,tests}` at R224.M2 landing time;
    `cc_*` was NOT chosen because `cc_scan`/`cc_denied`/`cc_bad_sysno`
    in `src/kernel/core/syscall/cap_check.pdx` collide at the grep
    level even though paideia-as labels are function-local). The
    public API still owns the `_cc_*` symbol namespace.

### Changed

- `src/lib.pdx` bumps `LPX_PDS_PARSER_VERSION_MINOR` 9 -> 10 and
  flips `LPX_PDS_PARSER_R224_M2_READY` from 0 to 1. Module-filename
  list + upstream-issues doc comment extended with the new file.
- `caps.decl` adds the `0x3500..0x35FF` R224.M2 band entry, R224.M2
  consumed_kinds landing paragraph (reconciled with the superseded
  R224.M2 expression-parse-only description), grep-disjointness
  confirmation for `0x350[0-5]`, and the R224.M2 linker-dependency
  note (pure-leaf; one-way intra-library CALL into _cc_skip_ws /
  _cc_classify_type / _cc_parse_binding; the R224.M2.5 integration
  pass will add a one-way intra-library dependency where lambda_lit's
  _ll_parse calls _cc_parse).
- `STATUS.md` R224.M2 checklist landed; error-band accounting table
  extended with the closure_capture row.

### Design notes

- `design/shell/closure-capture.md` -- grammar, record layout,
  BY_REF vs BY_VALUE semantics (Q13 hybrid serialization), capacity
  / bound-check matrix, interaction with R224.M1 LambdaLit (R224.M2.5
  integration pass), R222.M1 SchemasSig (shared type codes), R223.M5
  wire-format sink (BY_VALUE serializer), R225.M5 cross-context type
  flow (BY_REF receiver lookup).

### Reconciliation note

The parent brief's R224.M2 title is "Closure over pipeline-scope
bindings" and the acceptance is "15-test corpus of intra- and cross-
process closures." This landing provides the PARSER tier -- the
syntactic surface, the capture-list descriptor emission, and the
error taxonomy. The runtime half (serializer, deserializer, by-ref
name-resolution against the receiver's session scope) rides a
separate landing on the kernel-side closure-arena substrate when
R220.M7 is uplifted; those tests gate on the end-to-end runtime,
not on the parser-tier descriptor shape this landing freezes. The
parser-tier descriptor-emission is the ABI frozen at this M2 so the
runtime half can layer additively without a re-parse.

## [1.9.0] -- 2026-10-14

R222.M2 of the semantic-shell cmd-functor umbrella (paideia-os#2486,
decomposed into paideia-os#2659 for this M2) -- COMMANDSIG: the
cmd-functor-identity block that declares a command's human-readable
name, required capability set (up to 8 (name, rights) pairs),
SemVer-shaped version, and stability tier. Lands as the second R222
wave on the parser-tier satellite, companion to R222.M1 SchemasSig
(which declared the command's input + output record SHAPES).

### Added

- `src/command_sig.pdx` module `CommandSig`: parser-tier primitive
  that recognises a `command_sig { ... }` body and emits a flat
  128-byte CommandSigHeader followed by up to 8 x 32-byte CapDecl
  descriptors.
  - `_cs_parse_body(bytes_ptr, bytes_len, out_ptr, out_cap) -> packed_u64`
    -- public entry point. Parses whitespace-separated `name :
    "..."`, `cap : <name> : 0x<rights>`, `version : "..."`, and
    `stability : (stable | experimental | deprecated)` decls in any
    order (duplicates land last-wins; max 8 cap decls per sig).
    Returns `(bytes_written << 32) | status`.
  - `_cmd_sig_skip_ws(bytes_ptr, bytes_len, cursor) -> new_cursor`
    -- pure leaf ASCII-whitespace skipper. Mirrors SchemasSig /
    LambdaLit / Datalog leaves byte-for-byte so the whitespace
    discipline is a shared property of the pds-lang family.
  - `_cmd_sig_fnv1a64(ptr, len) -> u64` -- pure leaf FNV-1a 64 hash
    over the cap-name bytes. Uses `mul rcx` (one-op unsigned mul)
    with the standard 64-bit FNV prime (0x100000001B3) loaded via
    `mov rN, imm64`; the one-op mul form is distinct from the
    pitfall-listed 2-op `imul r, imm`.
  - CommandSigHeader (128 B): magic u32 'CSIG' (= 0x47495343),
    n_caps u8, stability u8, name_len u8, version_len u8,
    name_inline `[u8; 48]`, version_inline `[u8; 16]`, caps_offset
    u32, caps_len u32, flags u32 (has-name / has-version /
    has-stability bits), reserved `[u8; 44]`.
  - CapDecl descriptor (32 B each): name_hash u64 (FNV-1a 64 of
    the full cap name; identity hash preserving names past the
    16-byte inline window), rights u64 (bitmask parsed from
    HEX_RIGHTS), name_inline `[u8; 16]` (first 16 bytes of the cap
    name, zero-padded, truncated past 16 chars).
  - Grammar M2 scope: `name` len 1..48 printable ASCII in quotes,
    `cap` ident 1..48 chars + `0x<hex>` rights (1..16 hex digits),
    `version` len 1..16 printable ASCII in quotes, `stability`
    unquoted keyword from the fixed `{stable, experimental,
    deprecated}` set. Max 8 cap decls per sig (CS_MAX_CAPS).
  - Error band `0x3300..0x33FF` (R222.M2 CommandSig):
    - `CS_OK = 0`
    - `CS_ERR_SYNTAX = 0x3300`
    - `CS_ERR_TOO_MANY_CAPS = 0x3301`
    - `CS_ERR_UNKNOWN_STABILITY = 0x3302`
    - `CS_ERR_OUT_TOO_SMALL = 0x3303`
  - Pure in-process; no KIND surface; no external linker
    dependencies.
  - Label prefix `cmd_sig_` (not `cs_` -- `cs_*` is already used by
    203 kernel-side labels + 30 user-space labels across the repo,
    grep-confirmed at R222.M2 landing time). The public API still
    owns the `_cs_*` entry-point namespace since that is a distinct
    "with-underscore prefix" convention.

### Changed

- `src/lib.pdx` bumps `LPX_PDS_PARSER_VERSION_MINOR` 8 -> 9 and
  adds the R222 feature-gate block
  (`LPX_PDS_PARSER_R222_M1_READY = 1`,
   `LPX_PDS_PARSER_R222_M2_READY = 1`, M3..M8 reserved).
- `caps.decl` adds the `0x3300..0x33FF` R222.M2 band entry,
  R222.M1 + R222.M2 consumed_kinds landing notes, grep-disjointness
  confirmation for `0x330[0-3]`, and R222.M1 / R222.M2 linker-
  dependency notes (both are pure-leaf; no external deps).

### Design notes

- `design/shell/cmd-functor-command-sig.md` -- grammar, record
  layout, interaction with R222.M1 SchemasSig + R227.M2 cap-decl
  checker + R133.M2 container header pragma gate.

## [1.8.0] -- 2026-10-14

R223.M2 of the semantic-shell pipeline-lang umbrella (paideia-os#2487,
decomposed into paideia-os#2667 for this M2) -- RECORD PROJECTION:
the `select FIELDS` / `project FIELDS` pipeline operators that filter
the typed-record stream by field name. Lands as the second R223 wave
on the parser-tier satellite. The 1.7.0 slot is reserved for a
parallel landing in the same wave.

### Added

- `src/record_projection.pdx` module `RecordProjection`: parser-tier
  primitive that reads a comma-separated field-name list and emits
  a flat array of 16-byte `FieldSelector` records.
  - `_rp_parse_select(bytes_ptr, bytes_len, out_ptr, out_cap) -> packed_u64`
    -- public entry point for the `select FIELDS` operator. Emits
    FieldSelector records with flags = 0. Returns
    `(n_fields << 32) | status`.
  - `_rp_parse_project(bytes_ptr, bytes_len, out_ptr, out_cap) -> packed_u64`
    -- public entry point for the `project FIELDS` operator. Emits
    FieldSelector records with flags = `RP_FLAG_PROJECT` (= 1). At
    M2 the semantics are identical to `_rp_parse_select`; the
    per-field flag survives for R223.M3's differentiation between
    `select` (reorder) and `project` (drop-unselected).
  - `_rp_parse_impl(bytes_ptr, bytes_len, out_ptr, out_cap, flags_byte) -> packed_u64`
    -- shared body of the two public wrappers; writes `flags_byte`
    into each FieldSelector's flags slot.
  - `_rp_skip_ws(bytes_ptr, bytes_len, cursor_in) -> new_cursor`
    -- pure leaf whitespace skipper (SP/TAB/LF/CR). Mirrors
    SchemasSig's `_sch_sig_skip_ws` byte-for-byte.
  - FieldSelector record (16 B): `name_len` u8, `flags` u8,
    `name_inline` `[u8; 14]`.
  - Grammar: `argv_body := WS* field_name (WS* ',' WS* field_name)* WS*`;
    `field_name := [A-Za-z_] [A-Za-z0-9_]*` with byte length
    `1..RP_NAME_MAX = 14`.
  - Return codes `RP_OK = 0`, `RP_ERR_SYNTAX = 0x3400`,
    `RP_ERR_TOO_MANY_FIELDS = 0x3401`,
    `RP_ERR_OUT_TOO_SMALL = 0x3402`.
  - Shape constants `RP_FIELD_SELECTOR_BYTES = 16`,
    `RP_NAME_MAX = 14`, `RP_MAX_FIELDS = 32`, plus field-offset
    constants (`RP_OFF_NAME_LEN`, `RP_OFF_FLAGS`, `RP_OFF_NAME_INLINE`)
    and the flag bit `RP_FLAG_PROJECT = 0x01`.
- `src/lib.pdx` module `LibpdxPdsParser`: flipped
  `LPX_PDS_PARSER_R223_M2_READY` from 0 to 1; minor version bump
  1.6.0 -> 1.8.0 (the 1.7.0 slot is reserved for a parallel landing
  in the same wave).
- `caps.decl`: 0x3400..0x34FF error-band reservation for R223.M2;
  disjointness proof updated against R221 utf8_nfc (0x2700..),
  R222 schemas_sig (0x2A00..), R223.M1 pipeline (0x2B00..),
  R224 lambda_lit (0x2C00..), R225 hm_core (0x2D00..), R226 datalog
  (0x2E00..), and the kernel-side Pipeline module's 0xFFFFEC40..42
  band. The two R223 submodules carve out disjoint bands so a
  downstream dispatcher's compound error path can distinguish
  outer-pipeline faults from inner-projection faults.
- `STATUS.md`: R223.M2 checklist landed; error-band accounting
  table extended with the record_projection row and the pipeline
  slice reservation retargeted from M2+ to M3+.

### Design doc

- `design/shell/pipeline-record-projection.md` (NEW): grammar,
  FieldSelector layout rationale (16 B stride with 14 B inline name
  parallel to SchemasSig's 13 B slot plus the extra byte freed by
  having no type_code), capacity/bound-check matrix, interaction
  with R129.M4 schema_fmt (fields that pass projection are the
  fields the formatter sees), interaction with R222.M1 SchemasSig
  (bare name vs name:type declarations), interaction with R223.M1
  Pipeline (post-pass on the stage's argv bytes), forward path to
  R223.M3 differentiation of select vs project semantics,
  status-code namespace reservation (0x3400..0x34FF), representative
  OK/error cases (deferred corpus to R223.M7).

### Linker dependencies

- `src/record_projection.pdx` adds NO external linker dependency;
  `_rp_parse_select` and `_rp_parse_project` are 1-nested-call
  wrappers that CALL the module-private `_rp_parse_impl`, which in
  turn CALLs the module-private `_rp_skip_ws` leaf; all three (plus
  the two wrappers) live in the same object. All four public entry
  points can be linked standalone.

## [1.6.0] -- 2026-10-14

R224.M1 + R225.M1 + R226.M1 consolidated under Wave 114 — three
parallel softarch landings on the parser-tier satellite:

- R224.M1 (paideia-os#2675): `src/lambda_lit.pdx` module `LambdaLit`
  — lambda-literal grammar parser. Error band 0x2C00..0x2C04.
- R225.M1 (paideia-os#2682): `src/hm_core.pdx` module `HmCore` —
  Hindley-Milner algorithm W core (unify, instantiate, generalise).
  Error band 0x2D00..0x2D03.
- R226.M1 (paideia-os#2692): `src/datalog.pdx` module `Datalog` —
  Datalog parser (facts/rules/queries). Error band 0x2E00..0x2E04.

Three concurrent softarch waves bumped `LPX_PDS_PARSER_VERSION_MINOR`
from 4 to 6 in parallel; main consolidated to a single 1.6.0 entry
at wave close. Prior 1.5.0 stanza (R224 only) merged into this one.

## [1.5.0-superseded] -- 2026-10-14

R224.M1 of the semantic-shell lambda-lang umbrella (paideia-os#2488,
decomposed into paideia-os#2675 for this M1). Superseded by the
consolidated 1.6.0 entry above.

### Added

- `src/lambda_lit.pdx` module `LambdaLit`: parser-tier primitive that
  recognises `\x:u64 -> ...` or `\(x:u64, y:u64) -> ...` lambda
  literal headers and emits a flat (LambdaHeader + Param array + opaque
  body) byte image.
  - `_ll_parse(bytes_ptr, bytes_len, out_ptr, out_cap) -> packed_u64`
    -- the public entry point. Parses `\` + ParamList + `->` + Expr,
    writing LambdaHeader (32 B) at out_ptr, n_params Param descriptors
    (32 B each) at [out_ptr + 32..], and the opaque body bytes
    verbatim after that. Returns `(bytes_written << 32) | status`.
  - `_ll_parse_param(bytes_ptr, bytes_len, cursor_in, param_write_ptr)
    -> packed_u64` -- cross-function helper that parses one Param
    (identifier WS* ':' WS* type_name) and writes a 32-byte Param
    descriptor. Returns `(new_cursor << 32) | status`.
  - `_ll_skip_ws(bytes_ptr, bytes_len, cursor_in) -> new_cursor`
    -- pure leaf whitespace skipper (SP/TAB/LF/CR). Mirrors the
    SchemasSig and Datalog skippers in shape.
  - `_ll_classify_type(ident_ptr, ident_len) -> type_code`
    -- pure leaf length-switched dispatcher over the eight M1-known
    type names (u64, i64, str, hex, hash32, tsc, path, pid). Mirrors
    SchemasSig's `_sch_sig_classify_type` byte-for-byte so lambda
    param types and cmd-functor record field types share the dispatch
    byte.
  - LambdaHeader record (32 B): magic u32 `'LMBD'=0x44424D4C`,
    n_params u16, flags u16, body_offset u32, body_len u32, reserved
    `[u8; 16]`.
  - Param descriptor (32 B each): type_code u8, name_len u8,
    name_inline `[u8; 14]`, reserved `[u8; 16]`.
  - Grammar M1 subset: SingleParam no-parens form (`\x:u64 -> ...`)
    plus MultiParam parens form (`\(x:u64, y:u64) -> ...`), including
    the empty `\() -> ...` zero-param case for suspended computations.
    Record-destructuring patterns and multi-char operator type names
    are deferred to R224.M5.
  - Return codes `LL_OK = 0`, `LL_ERR_SYNTAX = 0x2C00`,
    `LL_ERR_TOO_MANY_PARAMS = 0x2C01`,
    `LL_ERR_UNKNOWN_TYPE = 0x2C02`,
    `LL_ERR_OUT_TOO_SMALL = 0x2C03`,
    `LL_ERR_NO_ARROW = 0x2C04`.
  - Shape constants `LL_HEADER_BYTES = 32`, `LL_PARAM_BYTES = 32`,
    `LL_NAME_MAX = 13`, `LL_MAX_PARAMS = 8`,
    `LL_HEADER_MAGIC = 0x44424D4C`, plus header + param field-offset
    constants (`LL_OFF_*`, `LL_PARAM_OFF_*`) and the type-code
    constants (`LL_TYPE_U64`..`LL_TYPE_PID`) that mirror SchemasSig's
    SS_TYPE_* byte-for-byte.
- `src/lib.pdx` module `LibpdxPdsParser`: added
  `LPX_PDS_PARSER_R224_M1_READY` feature flag (set to 1) + reserved
  R224.M2..M7 flags (set to 0); minor version bump 1.4.0 -> 1.5.0.
- `caps.decl`: 0x2C00..0x2CFF error-band reservation for R224.M*;
  disjointness proof updated against R221 utf8_nfc (0x2700..),
  R222 schemas_sig (0x2A00..), R223 pipeline (0x2B00..),
  R225 hm_core (0x2D00..), R226 datalog (0x2E00..), and the kernel-
  side Pipeline module's 0xFFFFEC40..42 band. Pipeline.pdx's
  comment-level 0x2C00..0x2EFF R225 reservation is superseded in
  favour of this per-wave carve-out (R224 at 0x2C00..0x2CFF, R225 at
  0x2D00..0x2DFF, R226 at 0x2E00..0x2EFF).
- `STATUS.md`: R224 wave + R224.M1 checklist landed; error-band
  accounting table extended.

### Design doc

- `design/shell/lambda-literal-grammar.md` (NEW): grammar, state
  machine, record layout rationale (32 B header + 32 B Param stride,
  14 B inline name parallel to SchemasSig), reserved-tail accounting
  for M2+ (effect-row id, cap-row id, closure-capture bits,
  destructuring-pattern descriptors), capacity/bound-check matrix,
  interaction with R221.M1 UTF-8/NFC, R222.M1 SchemasSig (shared type
  codes), R223.M1 Pipeline (lambda as pipeline argv word), forward
  path to R224.M2 expression parse + R224.M3 effect polymorphism +
  R224.M4 capability-row typing + R224.M5 nested-lambda scoping +
  R224.M6 first-class pipeline value + R224.M7 linear/affine
  substructural propagation, caller flow, status-code namespace
  reservation (0x2C00..0x2CFF), 20-test parser corpus representative
  cases (deferred to R224.M7 fuzz corpus milestone).

### Linker dependencies

- `src/lambda_lit.pdx` adds NO external linker dependency; `_ll_parse`
  only calls the three module-private helpers (`_ll_skip_ws`,
  `_ll_classify_type`, `_ll_parse_param`); `_ll_parse_param` in turn
  calls `_ll_skip_ws` and `_ll_classify_type`.

## [1.4.0] -- 2026-10-14

R226.M1 of the semantic-shell datalog umbrella (paideia-os#2490,
decomposed into paideia-os#2692 for this M1).

### Added

- `src/datalog.pdx` module `Datalog`: parser-tier primitive that
  turns a `datalog { ... }` program's body bytes into a flat array
  of 48-byte `Clause` records.
  - `_dl_parse(bytes_ptr, bytes_len, out_clauses_ptr, out_cap) -> packed_u64`
    -- the top-level driver that loops over whitespace-separated
    clauses, dispatches to Head / Body parse paths based on first-
    non-ws peek (`?` -> Query, else Fact-or-Rule), and returns
    `(n_clauses << 32) | status`.
  - `_dl_skip_ws(bytes_ptr, bytes_len, cursor_in) -> new_cursor`
    -- pure leaf whitespace skipper (SP/TAB/LF/CR).
  - `_dl_scan_ident_or_var(bytes_ptr, bytes_len, cursor_in) -> packed`
    -- pure leaf [A-Za-z0-9_] continuation scanner; returns
    `(len << 32) | new_cursor`.
  - `_dl_scan_number(bytes_ptr, bytes_len, cursor_in) -> packed`
    -- pure leaf decimal-digit scanner; returns
    `(len << 32) | new_cursor`.
  - `_dl_scan_string(bytes_ptr, bytes_len, cursor_in) -> packed`
    -- pure leaf double-quoted string scanner with `\"` / `\\`
    escape handling; returns `(len << 32) | status` (quotes
    included in the span).
  - `_dl_scan_body(bytes_ptr, bytes_len, cursor_in) -> packed`
    -- pure leaf body walker that advances to the terminating `.`
    at paren-depth 0 outside any string; returns
    `(body_len << 32) | (n_atoms << 16) | status`.
  - Clause record (48 B): kind u8, predicate_name_offset u32,
    predicate_name_len u16, n_terms u16, n_body_atoms u16,
    term_offsets[4] u32[4], term_lens[4] u16[4], body_offset u32,
    body_len u16, three reserved slots.
  - Grammar M1 subset: Fact / Rule / Query, with Head := identifier
    `(` TermList `)` and Body := Atom (`,` Atom)*; Term in
    {variable, identifier, number, string}; variable starts
    `[A-Z]`, identifier starts `[a-z_]`.
  - Return codes `DL_OK = 0`, `DL_ERR_SYNTAX = 0x2E00`,
    `DL_ERR_TOO_MANY_CLAUSES = 0x2E01`,
    `DL_ERR_TOO_MANY_TERMS = 0x2E02`,
    `DL_ERR_UNTERMINATED_STRING = 0x2E03`,
    `DL_ERR_OUT_TOO_SMALL = 0x2E04`.
  - Shape constants `DL_CLAUSE_SIZE = 48`, `DL_MAX_CLAUSES = 256`,
    `DL_MAX_TERMS = 4`, plus kind encodings and field-offset
    constants.
- `src/lib.pdx` module `LibpdxPdsParser`: added
  `LPX_PDS_PARSER_R226_M1_READY` feature flag (set to 1) + reserved
  R226.M2..M11 flags (set to 0); minor version bump 1.1.0 -> 1.4.0
  (the 1.2 and 1.3 slots are reserved for R222.M1 SchemasSig and
  R227.M1 pds container which landed earlier in Wave 113 without a
  lib.pdx bump; this bump brings the manifest up to current wave
  parity).
- `caps.decl`: 0x2E00..0x2EFF error-band reservation for R226.M*;
  disjointness proof updated against R221 utf8_nfc (0x2700..),
  R222 schemas_sig (0x2A00..), R223 pipeline (0x2B00..),
  R225-reserved (0x2C00..0x2DFF), and the kernel-side Pipeline
  module's 0xFFFFEC40..42 band.
- `STATUS.md`: R226 wave + R226.M1 checklist landed; error-band
  accounting table extended.

### Design doc

- `design/shell/datalog-parser.md` (NEW): grammar, state machine,
  Clause record layout + spec reconciliation note (48 B stride with
  trailing term_lens[4] + body_len + _reserved2 reconciles the
  parent brief's 48 B total against the 36 B of named fields),
  term-span semantics, body-span + n_body_atoms counting rules,
  capacity/bound-check matrix, interaction with R127.M7
  history_facts substrate (forward-path for R226.M3 evaluator),
  caller flow, status-code namespace reservation (0x2E00..0x2EFF),
  40-test corpus representative cases (deferred to R226 fuzz
  milestone).

### Linker dependencies

- `src/datalog.pdx` adds NO external linker dependency; `_dl_parse`
  only calls the five module-private helpers (`_dl_skip_ws`,
  `_dl_scan_ident_or_var`, `_dl_scan_number`, `_dl_scan_string`,
  `_dl_scan_body`).

## [1.1.0] -- 2026-10-14

R223.M1 of the semantic-shell pipeline-lang umbrella
(paideia-os#2487, decomposed into paideia-os#2666 for this M1).

### Added

- `src/pipeline.pdx` module `Pipeline`: parser-tier pipeline-stage
  tokeniser that turns `cmd1 arg | cmd2 arg | cmd3 arg` into a flat
  array of 64-byte `PipelineStage` records.
  - `_pl_parse(bytes_ptr, bytes_len, out_ptr, out_cap) -> packed_u64`
    -- the four-state tokeniser (WS / BARE / DQ / SQ) that commits
    one record per `|`-delimited segment and returns
    `(n_stages << 32) | status`.
  - `_pl_emit_word(stage_ptr, offset, len, word_slot) -> u64` --
    internal helper that writes one (offset, len) pair into either
    the cmd_name slot (`word_slot == PL_SLOT_CMD = 0xFFFF`) or
    `argv[word_slot]` (`word_slot ∈ 0..7`), updating the stage's
    `n_args` u16 for argv writes.
  - Quoting: `"double-quoted"` honours `\"` escape; `'single-quoted'`
    is literal (no escapes); bareword honours `\|` escape.
  - Return codes `PL_OK = 0`, `PL_ERR_TOO_MANY_STAGES = 0x2B00`,
    `PL_ERR_TOO_MANY_ARGS = 0x2B01`,
    `PL_ERR_UNTERMINATED_QUOTE = 0x2B02`,
    `PL_ERR_EMPTY_STAGE = 0x2B03`,
    `PL_ERR_OUT_TOO_SMALL = 0x2B04`.
  - Shape constants `PL_STAGE_SIZE = 64`, `PL_MAX_STAGES = 16`,
    `PL_MAX_ARGS = 8`, plus field-offset constants (`PL_OFF_*`) and
    flag bits (`PL_FLAG_HAS_ESCAPES`, `PL_FLAG_HAS_QUOTES`).
- `src/lib.pdx` module `LibpdxPdsParser`: added `LPX_PDS_PARSER_R223_M1_READY`
  feature flag (set to 1); minor version bump 1.0.0 -> 1.1.0.
- `caps.decl`: 0x2B00..0x2BFF error-band reservation for R223.M*;
  disjointness proof updated against the kernel-side Pipeline
  module's 0xFFFFEC40..42 band.
- `STATUS.md`: R223 wave + R223.M1 checklist landed; error-band
  accounting table extended.

### Design doc

- `design/shell/pipeline-stage-parser.md` (NEW): grammar, state
  machine, record layout + spec reconciliation note (64 B stride
  with 6-byte reserved tail reconciles the parent brief's
  `(64B)` + `[u8; 14]` arithmetic clash), word-span semantics,
  capacity/bound-check matrix, interaction with R129.M5 renderer-
  override `as` syntax (post-pass on last-stage argv tail stays
  after pipeline parse), interaction with R222 cmd-functor
  signature matching, caller flow, status-code namespace
  reservation (0x2B00..0x2BFF), 30-test corpus representative
  cases (deferred to R223.M7).

### Linker dependencies

- `src/pipeline.pdx` adds NO external linker dependency; `_pl_parse`
  only calls the module-private `_pl_emit_word`.

## [1.0.0] -- 2026-10-14

R221.M1 of the semantic-shell parser-tier Unicode umbrella
(paideia-os#2485, decomposed into paideia-os#2651 for this M1).

### Added

- `src/utf8_nfc.pdx` module `Utf8Nfc`: parser-tier UTF-8 decoder +
  NFC normalizer wrapper tuned for the pds-lang / semantic-shell
  parser call site.
  - `_u8n_quick_check_ascii(bytes_ptr, bytes_len) -> u64` -- pure-leaf
    O(n) byte scan returning `1` iff every byte `< 0x80`, else `0`.
    Zero-length input returns `1` (vacuously ASCII and NFC).
  - `_u8n_decode_and_normalize(bytes_ptr, bytes_len, out_ptr, out_cap)
    -> packed_u64` -- entry point that first calls
    `_u8n_quick_check_ascii`. On ASCII input, byte-copies to the
    output buffer (correct because every ASCII code point is a
    trivially-well-formed 1-byte UTF-8 scalar AND a fixed point of
    NFC). On non-ASCII input, delegates to
    `libpdx-unicode-tables::Normalize::_norm_nfc` (R131.M3) and
    translates its three-value status (`0`/`1`/`2`) into the
    four-value `U8N_*` taxonomy.
  - Return codes `U8N_OK = 0`, `U8N_ERR_INVALID_UTF8 = 0x2700`,
    `U8N_ERR_OUT_TOO_SMALL = 0x2701`,
    `U8N_ERR_NORMALIZE_FAIL = 0x2702` (reserved for post-M1
    normaliser-internal failure; never returned at M1).

- `src/lib.pdx` module `LibpdxPdsParser`: version triple and
  per-milestone feature-ready flags for feature-gating consumers.

- `caps.decl`: cap-free entry-point surface declaration + error-band
  taxonomy (0x2700..0x27FF reserved for parser-tier packed-status
  codes).

- `README.md`, `STATUS.md`, `LICENSE`: library scaffold.

### Linker dependencies

- `_norm_nfc` from `libpdx-unicode-tables::Normalize` (R131.M3).
  Consumers link both libraries with
  `--extra-obj-dir tools/user/libpdx-unicode-tables/build-out`.

### Design doc

- `design/shell/parser-utf8-nfc.md` (NEW).
