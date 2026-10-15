# libpdx-pds-parser -- status

**Waves:**
- R221 (semantic shell -- parser-tier Unicode and lexer umbrella,
  paideia-os#2485)
- R222 (cmd-functor umbrella, paideia-os#2486)
- R223 (pipeline-lang umbrella, paideia-os#2487)
- R224 (lambda-lang umbrella, paideia-os#2488)
- R225 (typechecker umbrella, paideia-os#2489)
- R226 (datalog umbrella, paideia-os#2490)
- R229 (REPL evaluator umbrella, paideia-os#2493)
**Current milestones:** R221.M1 (UTF-8 decoder + NFC normalizer) --
landed. R221.M2 (GraphemeIter: TR#29 grapheme-cluster boundary
iterator) -- landed. R221.M3 (WidthPass: TR#11 column classifier +
cluster-aware column accumulator with locale-amb overlay) --
landed. R221.M4 (CtxLexer: context-tracking lexer over pipeline /
datalog / lambda tiers) -- landed. R222.M1 (SchemasSig parser) --
landed. R222.M2 (CommandSig parser) -- landed. R222.M3
(FunctorInstance: instantiation materialization record) -- landed.
R222.M4 (ArgFlagSpec: HM-typed arg + flag descriptors and
invocation checker) -- landed. R223.M1 (Pipeline stage parser) --
landed. R223.M2 (RecordProjection: select/project FIELDS) --
landed. R224.M1 (LambdaLit grammar) -- landed. R224.M2
(ClosureCapture list parser) -- landed. R224.M3 (EffectRow:
effect-polymorphic row sub-grammar + width-covariant subtype check
per Q-A3) -- landed. R224.M4 (CapRow: capability-row sub-grammar
over Q-A2 substructural lattice + env-mask covering check with
E0820-family diagnostic) -- landed. R225.M1 (HM algorithm W core) -- landed.
R225.M2 (RowTypes: Remy-style row polymorphism) -- landed. R226.M1
(Datalog parser) -- landed. R229.M2 (SessionEnv: session-scoped
bindings) -- landed. R229.M3 (TypeEnv: type-environment threading
= scheme store + specialisation cache) -- landed.
**Version:** 1.18.0.

See the R221 M-table in the umbrella issue (paideia-os#2485) and in
`design/terminal/semantic-shell-language-plan.md` §4 R221 for the
upstream wave-level design; this file tracks the per-milestone
landing checklist as it closes locally.

## Milestone checklist

### M1 -- UTF-8 decoder + NFC normalizer (paideia-os#2651, landed)

- [x] **M1-001** -- scaffold + module boundary: landed. Source files
      (`src/lib.pdx` module `LibpdxPdsParser`, `src/utf8_nfc.pdx`
      module `Utf8Nfc`), `caps.decl`, `README.md`, `CHANGELOG.md`,
      `STATUS.md`, `LICENSE`.
- [x] **M1-002** -- `_u8n_quick_check_ascii` landed: pure-leaf O(n)
      scan returning `1` iff every byte `< 0x80`, else `0`.
- [x] **M1-003** -- `_u8n_decode_and_normalize` landed: fast ASCII
      byte-copy path + slow delegation to `_norm_nfc`; four-value
      `U8N_*` return taxonomy.
- [x] **M1-004** -- design doc landed:
      `design/shell/parser-utf8-nfc.md`.
- [ ] **M1-005** -- test corpus + fingerprint goldens: deferred to a
      follow-up (`tests/proptest_utf8_nfc.pdx`,
      `tests/fingerprints/utf8_nfc.golden`); the design doc §8
      enumerates the TR#15 Part 1 subset, ASCII spot-tests,
      negative malformed-UTF-8 cases, and `out_cap` boundary cases.

### M2 -- TR#29 grapheme cluster boundary iterator (deferred)

Blocked by: M1 (consumes `_u8n_decode_and_normalize`'s output
buffer) + `libpdx-unicode-tables::grapheme._gc_next` (R131.M2, which
is landed).

### M3 -- TR#11 width table pass (paideia-os#2653, landed)

- [x] **R221.M3-001** -- `src/width_pass.pdx` module `WidthPass`
      landed: `_wp_char_width` (substrate delegate + A-class
      overlay), `_wp_cluster_width` (base-cp decode + classify),
      `_wp_cols` (TR#29-walk accumulator), `_wp_locale_amb_width`
      and `_wp_set_locale_amb` locale-amb accessors. 18-range
      A-class overlay table in `.rodata` (144 bytes aligned to 8).
      WP_* status taxonomy in 0x3F00..0x3F01 (band 0x3F00..0x3FFF
      with 254 slots reserved for M3.1+ follow-ups).
- [x] **R221.M3-002** -- design doc landed:
      `design/shell/width-pass-tr11.md`.
- [ ] **R221.M3-003** -- 50-string visual test corpus +
      TR#11 conformance vectors (`tests/proptest_width_pass.pdx`):
      deferred to R221.M7 parser fuzz-corpus milestone per the
      umbrella decomposition; the design doc §9 enumerates the
      representative OK/error cases and the TR#11 conformance
      slice.

### M4 -- Context-tracking lexer (paideia-os#2654, landed)

- [x] **R221.M4-001** -- `src/ctx_lexer.pdx` module `CtxLexer`
      landed: `_cl_init` boot hook, `_cl_push_ctx` / `_cl_pop_ctx` /
      `_cl_current_ctx` pure-leaf stack primitives, `_cl_lex_token`
      pure-leaf single-token lexer, `_cl_tokenize` whole-input
      walker. 16-byte Token record (kind u16, ctx u8, flags u8,
      src_offset u32, src_length u32, payload u32); 16-level
      context stack in `.bss`; 17-value TOK_* enum covering the
      three tier languages; CL_* status taxonomy in
      0x4200..0x4207 (band 0x4200..0x42FF with 247 slots reserved
      for M4.1+ follow-ups).
- [x] **R221.M4-002** -- design doc landed:
      `design/shell/ctx-tracking-lexer.md`. 40-example fixture
      enumerated at §10 (five pipeline-only, ten datalog-only, ten
      lambda-only, ten nested / cross-context including error
      cases); the corpus will be goldened at R221.M7 parser fuzz.
- [ ] **R221.M4-003** (deferred) -- `tests/proptest_ctx_lexer.pdx`
      40-example fixture + fingerprint golden: filed as R221.M7
      follow-up per the umbrella decomposition; the design doc §10
      enumerates the parse-shape and error cases.
- [ ] **R221.M4-004** (deferred) -- `_cl_init` wire-up in the
      R229.M3-dispatch kernel-side REPL session boot alongside
      `_se_init` and `_te_init_session`: filed as R221.M4.5
      follow-up. The user-space parser-tier satellite does not know
      its own boot position.

### M5 -- Unified AST sum type + node constructors (deferred)

Blocked by: M4.

### M6 -- Source-span tracking through NFC normalization (deferred)

Blocked by: M1 + M5. Will add a sibling entry point
`_u8n_decode_and_normalize_with_map` that emits a span-mapping
table alongside the output bytes.

### M7 -- Fuzz corpus for parser + Unicode (deferred)

Blocked by: M5. 24-hour AFL run gates landing.

## R222 cmd-functor checklist

### M1 -- SchemasSig body parser (paideia-os#2658, landed)

- [x] `src/schemas_sig.pdx` module `SchemasSig` landed with
      `_ss_parse_body` + `_ss_match_record` stub, 16-byte field
      descriptor, SS_* status taxonomy in 0x2A00..0x2AFF.

### M2 -- CommandSig body parser (paideia-os#2659, landed)

- [x] `src/command_sig.pdx` module `CommandSig` landed with
      `_cs_parse_body` + `_cmd_sig_fnv1a64` leaf, 128-byte header +
      32-byte CapDecl, CS_* status taxonomy in 0x3300..0x33FF.

### M3 -- FunctorInstance materialization record (paideia-os#2660, landed)

- [x] `src/functor_instance.pdx` module `FunctorInstance` landed
      with `_fi_instantiate` + `_fi_elaborate_args`, 64-byte header
      + 32-byte ArgDesc stride, FI_* status taxonomy in
      0x3900..0x39FF.

### M4 -- ArgSpec + FlagSpec typing (paideia-os#2661, landed)

- [x] **R222.M4-001** -- `src/arg_flag_spec.pdx` module
      `ArgFlagSpec` landed: `_afs_parse_arg_spec_body` and
      `_afs_parse_flag_spec_body` emit 32-byte ArgSpec / FlagSpec
      records; `_afs_check_invocation` walks a FunctorInstance
      materialization record (R222.M3) against the specs; AFS_*
      status taxonomy in 0x3C00..0x3CFF. Three pure-leaf helpers
      (`_afs_skip_ws`, `_afs_classify_type`, `_afs_parse_as_type`).
- [x] **R222.M4-002** -- design doc landed:
      `design/shell/arg-flag-spec-typing.md`.
- [ ] **R222.M4-003** -- 20-test corpus of well-typed + ill-typed
      invocations (`tests/proptest_arg_flag_spec.pdx`): deferred to
      R222.M7 fuzz-corpus milestone per the umbrella; the design
      doc §Acceptance enumerates the 10 well-typed + 10 ill-typed
      representative cases.

### M5 -- Registry client (deferred)

Blocked by: M4 (consumes ArgSpec + FlagSpec records) + R222.M2
(CommandSig) + R222.M1 (SchemasSig). Reads commands.toml, materialises
the per-command spec quartet, hashes into the schema-registry
fingerprint.

### M6 -- commands.toml bind (deferred)

Blocked by: M5. Adds the `= <literal>` default-value grammar to
ArgSpec / FlagSpec.

### M7 -- cmd-functor fuzz corpus (deferred)

Blocked by: M4..M6 landed. 20-test parser corpus for each M in the
R222 wave (SchemasSig / CommandSig / FunctorInstance / ArgFlagSpec).

### M8 -- `describe <cmd>` serialization (deferred)

Blocked by: M4 + M5. Round-trips the (CommandSig + SchemasSig +
ArgSpec + FlagSpec) quartet through the queryable form.

## R223 pipeline-lang checklist

### M1 -- Pipeline stage parser + `|` operator (paideia-os#2666, landed)

- [x] **R223.M1-001** -- `src/pipeline.pdx` module `Pipeline` landed:
      `_pl_parse` + `_pl_emit_word`, 64-byte stage record, PL_* status
      taxonomy in 0x2B00..0x2BFF.
- [x] **R223.M1-002** -- design doc landed:
      `design/shell/pipeline-stage-parser.md`.
- [ ] **R223.M1-003** -- 30-test parser corpus
      (`tests/proptest_pipeline.pdx`): deferred to R223.M7 per the
      umbrella decomposition; the design doc §12 enumerates the
      representative OK/error cases that corpus will cover.

### M2 -- Record projection: select/project FIELDS (paideia-os#2667, landed)

- [x] **R223.M2-001** -- `src/record_projection.pdx` module
      `RecordProjection` landed: `_rp_parse_select` /
      `_rp_parse_project` 1-nested-call wrappers delegate to the
      module-private `_rp_parse_impl`; `_rp_skip_ws` is a pure leaf
      whitespace skipper. 16-byte FieldSelector record (name_len u8,
      flags u8, name_inline `[u8; 14]`). RP_* status taxonomy in
      0x3400..0x34FF.
- [x] **R223.M2-002** -- design doc landed:
      `design/shell/pipeline-record-projection.md`.
- [ ] **R223.M2-003** -- 20-test parser corpus
      (`tests/proptest_record_projection.pdx`): deferred to R223.M7
      per the umbrella decomposition; the design doc enumerates the
      representative OK/error cases (single select, multi select,
      multi project, over-long name, trailing comma, empty input,
      cap-exceeding list).

## R224 lambda-lang checklist

### M1 -- Lambda literal grammar (paideia-os#2675, landed)

- [x] **R224.M1-001** -- `src/lambda_lit.pdx` module `LambdaLit` landed:
      `_ll_parse` driver + three helpers (`_ll_skip_ws`,
      `_ll_classify_type`, `_ll_parse_param`), 32-byte LambdaHeader
      record + 32-byte Param descriptor, LL_* status taxonomy in
      0x2C00..0x2CFF, type codes mirroring R222.M1 SchemasSig
      byte-for-byte.
- [x] **R224.M1-002** -- design doc landed:
      `design/shell/lambda-literal-grammar.md`.
- [ ] **R224.M1-003** -- 20-test parser corpus
      (`tests/proptest_lambda_lit.pdx`): deferred to R224.M7 per the
      umbrella decomposition; the design doc enumerates the
      representative OK/error cases that corpus will cover (single
      param, multi param, zero param, over-long name, unknown type,
      bad arrow, cap-exceeding body, etc.).

### M2 -- Closure capture over pipeline-scope bindings (paideia-os#2676, landed)

- [x] **R224.M2-001** -- `src/closure_capture.pdx` module
      `ClosureCapture` landed: `_cc_parse` driver + three helpers
      (`_cc_skip_ws`, `_cc_classify_type`, `_cc_parse_binding`),
      32-byte ClosureCaptureHeader + 32-byte Binding descriptor,
      CC_* status taxonomy in 0x3500..0x35FF, type codes mirroring
      R224.M1 LambdaLit + R222.M1 SchemasSig byte-for-byte,
      BY_REF / BY_VALUE mode byte per binding (Q13 hybrid pipeline
      serialization opt-in).
- [x] **R224.M2-002** -- design doc landed:
      `design/shell/closure-capture.md`.
- [ ] **R224.M2-003** -- 15-test corpus of intra- and cross-process
      closures (`tests/proptest_closure_capture.pdx`): deferred to a
      follow-up on the R224.M2.5 integration landing per the umbrella
      decomposition; the design doc enumerates the representative
      OK/error cases (empty list, single bare, single typed, mixed,
      max-16, over-16, over-14-byte-name, unknown-type, missing-close,
      missing-open, trailing comma, leading comma, consecutive comma,
      bare-trailing-colon, empty-trailing-space).

### M2.5 -- Lambda-literal + capture-list integration (deferred)

Follow-up on R224.M2 landing: insert a `_cc_parse` call between the
backslash-consume and the ParamList dispatch inside R224.M1's
`_ll_parse`. The merged shape produces one call that recognises both
the capture list AND the parameter list. Not landed at R224.M2
because the parser-tier descriptor-emission ABI (frozen above) is
sufficient for M3+ consumers; integration is a cosmetic unification
rather than a semantic unlock.

### M3 -- Effect polymorphism (paideia-os#2677, landed)

- [x] **R224.M3-001** -- `src/effect_row.pdx` module `EffectRow`
      landed: `_er_init` (lazy-populate primitive labels),
      `_er_label_lookup` + `_er_label_intern` (32-slot intern
      table), `_er_skip_ws` (WS walker), `_er_parse`
      (`WS* ! WS* { LabelList? } ` grammar; builds a RowTypes
      row via `_rt_row_empty` / `_rt_row_var` / `_rt_row_extend`),
      `_er_check_subtype` (width-covariant subtype check with
      packed-label-id offending-label diagnostic;
      `ER_ERR_IMPURE_PASSED_PURE` at 0x4003 is the pure-arg
      rejection anchor), `_er_render` (round-trip to
      `!{L1, L2, ..., rho}` source syntax). ER_* status taxonomy
      in 0x4000..0x4007 (band 0x4000..0x40FF with 248 slots
      reserved for M3.1+ follow-ups).
- [x] **R224.M3-002** -- design doc landed:
      `design/shell/effect-polymorphism.md`. 20-test corpus
      enumerated at §7 (10 parse-shape, 10 subtype; anchor
      acceptance case `{io} ⊆ {}` → ER_ERR_IMPURE_PASSED_PURE
      with offending label 0 is case 13).
- [x] **R224.M3-003** -- lib.pdx: version 1.16.0 -> 1.17.0;
      `LPX_PDS_PARSER_R224_M3_READY` flipped to 1.
- [x] **R224.M3-004** -- caps.decl: 0x4000..0x40FF band section +
      per-milestone catalogue entry + grep-disjointness line +
      linker-dependency entry.
- [ ] **R224.M3-005** (deferred) -- `tests/proptest_effect_row.pdx`
      20-test corpus + fingerprint golden: filed as R224.M3.9
      follow-up. The design doc §7 enumerates the OK/error cases
      so a late-landing test harness can golden them from the
      spec.
- [ ] **R224.M3-006** (deferred) -- LambdaLit integration pass
      (`_ll_parse` consumes the optional `!{...}` suffix after
      the arrow + ResultType): filed as R224.M3.5 follow-up.
      Currently the M3 parser is invoked standalone by the
      downstream HM-type-check tier against a pre-isolated byte
      slice.
- [ ] **R224.M3-007** (deferred) -- `_er_declare` user-declared-
      effect intern surface: filed as R224.M3.6 follow-up.
      Currently intern-miss on a non-primitive label returns
      `ER_ERR_UNKNOWN_LABEL`.
- [ ] **R224.M3-008** (deferred) -- dedup check in `_er_parse`
      (`!{io, io}` returns SYNTAX): filed as R224.M3.1 follow-up.
      Currently duplicates pass through parse and are caught by
      R225.M2 Rémy unification as `RT_ERR_LABEL_DUP`.
- [ ] **R224.M3-009** (deferred) -- tightened open-row subtype
      discipline (open sub tail vs closed sup must bind the
      row-var to empty before subsume concludes OK): filed as
      R224.M3.2 follow-up. Currently open tails are
      optimistically subsumed.
- [ ] **R224.M3-010** (deferred) -- per-row-var naming in
      `_er_render`: filed as R224.M3.3 follow-up. Currently
      every `ROW_VAR` renders as bare `rho`.

### M4 -- Capability-row typing (paideia-os#2678, landed)

- [x] **R224.M4-001** -- `src/cap_row.pdx` module `CapRow`
      landed: `_cr_init` (lazy-populate primitive labels),
      `_cr_label_lookup` + `_cr_label_intern` (32-slot intern
      table), `_cr_skip_ws` (WS walker), `_cr_parse`
      (`WS* @ WS* { LabelList? } ` grammar; builds a RowTypes
      row via `_rt_row_empty` / `_rt_row_var` / `_rt_row_extend`),
      `_cr_check_env` (env-mask covering check with packed-label-id
      offending-cap diagnostic; `CR_ERR_MISSING_CAP` at 0x4303 is
      the missing-cap rejection anchor and the `E0820_MISSING_CAP`
      diagnostic), `_cr_render` (round-trip to
      `@{L1, L2, ..., rho}` source syntax). CR_* status taxonomy
      in 0x4300..0x4309 (band 0x4300..0x43FF with 246 slots
      reserved for M4.1+ follow-ups).
- [x] **R224.M4-002** -- design doc landed:
      `design/shell/capability-row-typing.md`. 20-test corpus
      enumerated at §7 (10 parse-shape, 10 env-check including the
      8-lambda adversarial acceptance anchor; anchor cases 11-18
      exercise `_cr_check_env({cap_i}, 0) == (packed_id_i << 32) |
      0x4303` for i in {read, write, exec, net, fs, cap_mint,
      cap_grant, kalloc}).
- [x] **R224.M4-003** -- lib.pdx: version 1.17.0 -> 1.18.0 (shared
      with the parallel R221.M4 CtxLexer landing of Wave 121);
      `LPX_PDS_PARSER_R224_M4_READY` flipped to 1.
- [x] **R224.M4-004** -- caps.decl: 0x4300..0x43FF band section +
      per-milestone catalogue entry + grep-disjointness line +
      linker-dependency entry.
- [ ] **R224.M4-005** (deferred) -- `tests/proptest_cap_row.pdx`
      20-test corpus + fingerprint golden: filed as R224.M4.9
      follow-up. The design doc §7 enumerates the OK/error cases
      so a late-landing test harness can golden them from the
      spec.
- [ ] **R224.M4-006** (deferred) -- LambdaLit integration pass
      (`_ll_parse` consumes the optional `@{...}` suffix after
      the arrow + ResultType, dual with M3.5): filed as R224.M4.5
      follow-up. Currently the M4 parser is invoked standalone by
      the downstream HM-type-check tier against a pre-isolated
      byte slice.
- [ ] **R224.M4-007** (deferred) -- `_cr_declare` user-declared-
      capability intern surface: filed as R224.M4.6 follow-up.
      Currently intern-miss on a non-primitive label returns
      `CR_ERR_UNKNOWN_CAP`.
- [ ] **R224.M4-008** (deferred) -- dedup check in `_cr_parse`
      (`@{read, read}` returns SYNTAX): filed as R224.M4.1 follow-
      up. Currently duplicates pass through parse and are caught
      by R225.M2 Rémy unification as `RT_ERR_LABEL_DUP`.
- [ ] **R224.M4-009** (deferred) -- Q-A2 substructural-lattice
      enforcement (linear caps cannot repeat at a call site):
      filed as R224.M4.7 follow-up. Currently every row-ext is
      treated nominally.
- [ ] **R224.M4-010** (deferred) -- kernel-side cap-mask bridge
      (reads per-session cap table): filed as R224.M4.8 follow-up.
      Currently the caller passes a precomputed `env_mask`.
- [ ] **R224.M4-011** (deferred) -- per-row-var naming in
      `_cr_render`: filed as R224.M4.3 follow-up. Currently every
      `ROW_VAR` renders as bare `rho`.

### M5 -- Nested lambda + let-rec scoping (deferred)

Blocked by: M2.

### M6 -- First-class pipeline value (deferred)

Blocked by: M2, R220.M7 (closure arena), R223.M4 (higher-order combinators).

### M7 -- Linear/affine propagation (deferred)

Blocked by: M4. 20-test parser corpus + fuzz run gate landing.

## R225 typechecker checklist

### M1 -- HM algorithm W core (paideia-os#2682, landed)

- [x] **R225.M1-001** -- `src/hm_core.pdx` module `HmCore` landed:
      `_hm_find` / `_hm_fresh_var` / `_hm_occurs` / `_hm_unify` /
      `_hm_instantiate` / `_hm_generalise` over a singleton 128-slot
      TypeNode pool. Robinson unification + occurs-check + scheme
      serialisation (wire format: n_bound_vars + n_body_nodes +
      bound_var_ids + body nodes). HM_* status taxonomy in
      0x2D00..0x2DFF.
- [x] **R225.M1-002** -- design doc landed:
      `design/shell/hm-algorithm-w-core.md`.
- [ ] **R225.M1-003** -- 100-test property harness
      (`tests/proptest_hm_core.pdx`): deferred to R225.M9 per the
      umbrella decomposition.

### M2 -- Pipeline-record row types (paideia-os#2683, landed)

- [x] **R225.M2-001** -- `src/row_types.pdx` module `RowTypes`
      landed: `_rt_find` extends the resolved-chain walk to
      HM_KIND_TYROW nodes; `_rt_alloc_node` reserves a 16-byte
      slot in HmCore's shared pool; `_rt_label_hash` (FNV-1a 32
      pure leaf) hashes the field name; `_rt_row_empty`,
      `_rt_row_var`, `_rt_row_extend` build ROW_EMPTY, ROW_VAR,
      ROW_EXT nodes respectively; `_rt_record_type` wraps a row
      with TyApp(TyCon(RECORD, arity=1), row); `_rt_row_select`,
      `_rt_row_restrict`, `_rt_row_concat` are the primitive
      field ops; `_rt_row_unify` is the Remy-style row-aware
      unifier (self-recursive and cross-recursive with
      `_hm_unify`). RT_* status taxonomy in 0x3600..0x36FF.
- [x] **R225.M2-002** -- design doc landed:
      `design/shell/row-types-remy.md`.
- [ ] **R225.M2-003** -- 40-test parser + inference corpus
      (`tests/proptest_row_types.pdx`): deferred to R225.M9 per the
      umbrella decomposition; the design doc section 9 enumerates the
      representative OK / error cases (bare row, open row with var
      tail, label match / miss, Remy pivot on label disagreement,
      extend / restrict / concat, record wrapper, nested rows inside
      TyApp, cross-kind mismatch, pool-full on long chain, etc.).

### M3 -- Datalog predicate types via schema registry (deferred)

Blocked by: M1 + R222.M1 (SchemasSig descriptor array) + R220.M4
(schema registry; paideia-as).

### M4 -- Effect-row unification (deferred)

Blocked by: M2 (reuses the Remy pivot verbatim; differentiator is a
disjoint ROW_SUBKIND_EFFECT_* subkind) + R220.M8 (open-row effect
inference; paideia-as).

### M5 -- Cross-context type flow (deferred)

Blocked by: M2 + M3.

### M6 -- Rank-restricted let-polymorphism (deferred)

Blocked by: R220.M11.

### M7 -- Error reporting with source spans + suggestions (deferred)

Blocked by: R220.M9 (LSP-embed).

### M8 -- LSP hover integration (deferred)

Blocked by: R220.M9.

### M9 -- Property-based test corpus (deferred)

Blocked by: M6. 10k random-program corpus + 24-hour run gate landing.
Will also seed the 40-test row-types corpus and the 100-test HM core
corpus deferred from M1 and M2.

### M10 -- Per-turn type-check fingerprint (deferred)

Blocked by: R220.M10 (fingerprint emission).

## R226 datalog checklist

### M1 -- Datalog parser: facts, rules, queries (paideia-os#2692, landed)

- [x] **R226.M1-001** -- `src/datalog.pdx` module `Datalog` landed:
      `_dl_parse` driver + five pure-leaf helpers (`_dl_skip_ws`,
      `_dl_scan_ident_or_var`, `_dl_scan_number`, `_dl_scan_string`,
      `_dl_scan_body`), 48-byte Clause record, DL_* status taxonomy
      in 0x2E00..0x2EFF.
- [x] **R226.M1-002** -- design doc landed:
      `design/shell/datalog-parser.md`.
- [ ] **R226.M1-003** -- 40-test parser corpus
      (`tests/proptest_datalog.pdx`): deferred to a dedicated fuzz-
      corpus milestone per the umbrella decomposition; the design
      doc §9 enumerates the representative OK/error cases that
      corpus will cover.

## R229 REPL evaluator checklist

### M1 -- REPL state machine (paideia-os#2719, kernel-side; no lib surface)

Lands at `src/kernel/core/shell/repl_loop.pdx`. Design doc:
`design/shell/repl-loop-scaffold.md`.

### M2 -- SessionEnv: session-scoped bindings (paideia-os#2720, landed)

- [x] **R229.M2-001** -- `src/session_env.pdx` module `SessionEnv`
      landed: `_se_init` + `_se_init_session` pure-leaf hooks,
      `_se_insert_binding` / `_se_lookup_binding` /
      `_se_unset_binding` 6-push pure-leaf scanners. 32-byte Binding
      record (kind u8, name_len u8, scheme_kind u8, flags u8,
      type_ref u32, name_inline `[u8;16]`, value_ref u64); 8-session
      x 32-slot pool; SE_* status taxonomy in 0x3700..0x37FF.
- [x] **R229.M2-002** -- design doc landed:
      `design/shell/session-env.md`.
- [ ] **R229.M2-003** -- 20-turn `let`/`unset`/lookup smoke-mode
      golden corpus (`smoke/session-env-m3.golden.txt`): deferred to
      R229.M3 (REPL dispatch), which is the first layer that drives
      SessionEnv from a production path. The design doc §10
      enumerates the seven steps the golden will assert.

### M3 -- Type-environment threading (paideia-os#2721, landed)

- [x] **R229.M3-001** -- `src/type_env.pdx` module `TypeEnv` landed:
      `_te_init_session` pure-leaf hook, `_te_insert_scheme` /
      `_te_evict_scheme` 6-push pure-leaf scanners, `_te_specialize`
      cache lookup + fallthrough to R225.M1 `_hm_instantiate` on
      miss. 256-byte Scheme slot (kind u8, flags u8, reserved u16,
      scheme_len u32, scheme_body u8[248]); 16-byte Cache entry
      (valid u8, reserved u8[3], scheme_id u32, hash u32, body_ref
      u32); 8-session x 16-scheme x 64-cache pool; TE_* status
      taxonomy in 0x3D00..0x3D08.
- [x] **R229.M3-002** -- design doc landed:
      `design/shell/type-env-threading.md`.
- [ ] **R229.M3-003** -- 15-turn polymorphic binding smoke-mode
      golden (specialisation reuse assertion): deferred to the
      kernel-side REPL dispatch layer (not R229.M3 of this library),
      which is the first path that drives TypeEnv from production
      input. The design doc enumerates the seven observations the
      golden will assert.

### M3-dispatch -- REPL dispatch wire-up (deferred, kernel-side)

Blocked by: M3 (TypeEnv substrate -- THIS landing) + R225.M4
(effect-row unification) + R221.M4 (context-tracking lexer).

### M4 -- Teardown cascade + exported bindings + hash index (deferred)

Blocked by: M3 + R127.M6 (session teardown wire).

### M5 -- Lexical nested scopes (deferred)

Blocked by: M3 + R224.M5 (nested lambda + let-rec).

### M6 -- Persistent per-user env (deferred)

Blocked by: M4 + pdxfs user profile schema.

## Error-band accounting

| Band             | Range            | Milestone | Status |
|------------------|------------------|-----------|--------|
| utf8_nfc         | 0x2700..0x2702   | R221.M1   | landed |
| grapheme_iter    | 0x3800..0x3803   | R221.M2   | landed |
| grapheme_iter-M3+| 0x3804..0x38FF   | R221.M3+  | reserved |
| width_pass       | 0x3F00..0x3F01   | R221.M3   | landed |
| width_pass-M3.1+ | 0x3F02..0x3FFF   | R221.M3.1+ | reserved |
| ctx_lexer        | 0x4200..0x4207   | R221.M4   | landed |
| ctx_lexer-M4.1+  | 0x4208..0x42FF   | R221.M4.1+ | reserved |
| lexer-m1-rsv     | 0x2730..0x274F   | R221.M4-rsv | superseded by ctx_lexer |
| ast              | 0x2750..0x275F   | R221.M5   | reserved |
| span_map         | 0x2760..0x276F   | R221.M6   | reserved |
| schemas_sig      | 0x2A00..0x2A03   | R222.M1   | landed |
| command_sig      | 0x3300..0x3303   | R222.M2   | landed |
| functor_instance | 0x3900..0x3906   | R222.M3   | landed |
| arg_flag_spec    | 0x3C00..0x3C0A   | R222.M4   | landed |
| arg_flag_spec-M5+| 0x3C0B..0x3CFF   | R222.M5+  | reserved |
| pipeline         | 0x2B00..0x2B04   | R223.M1   | landed |
| pipeline-M3+     | 0x2B05..0x2BFF   | R223.M3+  | reserved |
| record_projection | 0x3400..0x3402  | R223.M2   | landed |
| record_projection-M3+ | 0x3403..0x34FF | R223.M3+ | reserved |
| lambda_lit       | 0x2C00..0x2C04   | R224.M1   | landed |
| lambda_lit-M2+   | 0x2C05..0x2CFF   | R224.M2+  | reserved |
| closure_capture  | 0x3500..0x3505   | R224.M2   | landed |
| closure_capture-M3+ | 0x3506..0x35FF | R224.M3+ | reserved |
| effect_row       | 0x4000..0x4007   | R224.M3   | landed |
| effect_row-M3.1+ | 0x4008..0x40FF   | R224.M3.1+ | reserved |
| cap_row          | 0x4300..0x4309   | R224.M4   | landed |
| cap_row-M4.1+    | 0x430A..0x43FF   | R224.M4.1+ | reserved |
| hm_core          | 0x2D00..0x2D03   | R225.M1   | landed |
| hm_core-M3+      | 0x2D04..0x2DFF   | R225.M3+  | reserved |
| row_types        | 0x3600..0x3606   | R225.M2   | landed |
| row_types-M3+    | 0x3607..0x36FF   | R225.M3+  | reserved |
| datalog          | 0x2E00..0x2E04   | R226.M1   | landed |
| datalog-M2+      | 0x2E05..0x2EFF   | R226.M2+  | reserved |
| session_env      | 0x3700..0x3704   | R229.M2   | landed |
| session_env-M3+  | 0x3705..0x37FF   | R229.M3+  | reserved |
| type_env         | 0x3D00..0x3D08   | R229.M3   | landed |
| type_env-M4+     | 0x3D09..0x3DFF   | R229.M4+  | reserved |

Codes live in the parser-tier packed-status range (0x2700..0x2EFF
slice). Disjoint from every user-space `0xFFFFExxx` error band in
the paideia-os tree (see `caps.decl` for the full disjointness
proof).
