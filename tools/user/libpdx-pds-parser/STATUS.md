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
landed. R222.M1 (SchemasSig parser) -- landed. R222.M2 (CommandSig
parser) -- landed. R223.M1 (Pipeline stage parser) -- landed. R223.M2
(RecordProjection: select/project FIELDS) -- landed. R224.M1 (LambdaLit
grammar) -- landed. R224.M2 (ClosureCapture list parser) -- landed.
R225.M1 (HM algorithm W core) -- landed. R225.M2 (RowTypes: Remy-style
row polymorphism) -- landed. R226.M1 (Datalog parser) -- landed.
R229.M2 (SessionEnv: session-scoped bindings) -- landed.
**Version:** 1.12.0.

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

### M3 -- TR#11 width table pass (deferred)

Blocked by: M2 + `libpdx-unicode-tables::width._width_char` /
`_width_str` (R131.M5, which is landed).

### M4 -- Context-tracking lexer (Pipeline / Datalog / Lambda) (deferred)

Blocked by: M2, M3, and `paideia-as` stdlib R220.M3.

### M5 -- Unified AST sum type + node constructors (deferred)

Blocked by: M4.

### M6 -- Source-span tracking through NFC normalization (deferred)

Blocked by: M1 + M5. Will add a sibling entry point
`_u8n_decode_and_normalize_with_map` that emits a span-mapping
table alongside the output bytes.

### M7 -- Fuzz corpus for parser + Unicode (deferred)

Blocked by: M5. 24-hour AFL run gates landing.

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

### M3 -- Effect polymorphism (deferred)

Blocked by: M1 + paideia-as R220.M8 (open-row effect inference).
M3 subsumes the "expression body parser" sub-task (walks the opaque
body bytes `_ll_parse` emitted against the Expr grammar) because the
HM-pass at R225.M1+ needs the expression AST to seat effect-row
seeds. The sub-task is NOT a separately-numbered milestone -- it is
the parser half of M3 and lands with it.

### M4 -- Capability-row typing (deferred)

Blocked by: M3 + Q-A2 substructural lattice.

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

### M3 -- REPL dispatch + full-scheme storage (deferred)

Blocked by: M2 (SessionEnv substrate) + R225.M4 (effect-row
unification) + R221.M4 (context-tracking lexer).

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
| grapheme_iter    | 0x2710..0x271F   | R221.M2   | reserved |
| width_pass       | 0x2720..0x272F   | R221.M3   | reserved |
| lexer            | 0x2730..0x274F   | R221.M4   | reserved |
| ast              | 0x2750..0x275F   | R221.M5   | reserved |
| span_map         | 0x2760..0x276F   | R221.M6   | reserved |
| schemas_sig      | 0x2A00..0x2A03   | R222.M1   | landed |
| pipeline         | 0x2B00..0x2B04   | R223.M1   | landed |
| pipeline-M3+     | 0x2B05..0x2BFF   | R223.M3+  | reserved |
| record_projection | 0x3400..0x3402  | R223.M2   | landed |
| record_projection-M3+ | 0x3403..0x34FF | R223.M3+ | reserved |
| lambda_lit       | 0x2C00..0x2C04   | R224.M1   | landed |
| lambda_lit-M2+   | 0x2C05..0x2CFF   | R224.M2+  | reserved |
| closure_capture  | 0x3500..0x3505   | R224.M2   | landed |
| closure_capture-M3+ | 0x3506..0x35FF | R224.M3+ | reserved |
| hm_core          | 0x2D00..0x2D03   | R225.M1   | landed |
| hm_core-M3+      | 0x2D04..0x2DFF   | R225.M3+  | reserved |
| row_types        | 0x3600..0x3606   | R225.M2   | landed |
| row_types-M3+    | 0x3607..0x36FF   | R225.M3+  | reserved |
| datalog          | 0x2E00..0x2E04   | R226.M1   | landed |
| datalog-M2+      | 0x2E05..0x2EFF   | R226.M2+  | reserved |
| session_env      | 0x3700..0x3704   | R229.M2   | landed |
| session_env-M3+  | 0x3705..0x37FF   | R229.M3+  | reserved |

Codes live in the parser-tier packed-status range (0x2700..0x2EFF
slice). Disjoint from every user-space `0xFFFFExxx` error band in
the paideia-os tree (see `caps.decl` for the full disjointness
proof).
