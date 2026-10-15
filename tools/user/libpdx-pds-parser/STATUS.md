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
datalog / lambda tiers) -- landed. R221.M5 (Ast: unified SyntaxNode
sum type over a 256-slot bump-pointer pool with Q-A5 source-span
invariants) -- landed. R221.M6 (SpanMap: sparse delta list that
preserves Q-A5 source-byte offsets across UTF-8 -> NFC
normalization; 1024-slot 8-byte pair pool, binary-search lookup,
one-pass lockstep-walk constructor) -- landed. R222.M1 (SchemasSig parser) --
landed. R222.M2 (CommandSig parser) -- landed. R222.M3
(FunctorInstance: instantiation materialization record) -- landed.
R222.M4 (ArgFlagSpec: HM-typed arg + flag descriptors and
invocation checker) -- landed. R222.M5 (CmdRegistry: per-session
command-registry client with user-shadow override) -- landed.
R222.M6 (DispatchMode: light-vs-heavy classifier +
indirector over `resource_mask` at CommandSigHeader+84, two
weak-import function-pointer seams `_dm_light_fn` /
`_dm_spawn_fn`) -- landed.
R223.M1 (Pipeline stage parser) --
landed. R223.M2 (RecordProjection: select/project FIELDS) --
landed. R224.M1 (LambdaLit grammar) -- landed. R224.M2
(ClosureCapture list parser) -- landed. R224.M3 (EffectRow:
effect-polymorphic row sub-grammar + width-covariant subtype check
per Q-A3) -- landed. R224.M4 (CapRow: capability-row sub-grammar
over Q-A2 substructural lattice + env-mask covering check with
E0820-family diagnostic) -- landed. R224.M5 (LetScope: nested
lambda + let / let-rec scope-frame pool with inner-first parent-
chain resolve per standard HM shadowing, E0830-family diagnostic)
-- landed. R225.M1 (HM algorithm W core) -- landed.
R225.M2 (RowTypes: Remy-style row polymorphism) -- landed.
R225.M4 (EffectUnify: effect-row JOIN with ROW_VAR tail
propagation + rank-restricted-quantifier P10 well-formedness
validator; three-entry surface `_eu_unify` / `_eu_check_rank` /
`_eu_least` over the shared R225.M2 pool) -- landed. R226.M1
(Datalog parser) -- landed. R229.M2 (SessionEnv: session-scoped
bindings) -- landed. R229.M3 (TypeEnv: type-environment threading
= scheme store + specialisation cache) -- landed. R229.M4
(JobControl: per-shell-session 32-slot Job table backing
`cmd &` / `fg %n` / `bg %n` / `jobs`; four-state lifecycle NEW /
RUNNING / STOPPED / DONE under a 48-byte row stride; six public
entry points over singleton `.bss`) -- landed. R223.M4
(SortGroupReduce: standard `sort by` / `group by` / `reduce`
aggregation combinators under a shared 32-byte record; four public
entry points, zero `.bss`) -- landed. R224.M6 (PipelineLambda:
32-byte boxed lambda value threading literal / closure env /
effect row / capability row through `|`; four public entry points
over caller-supplied pool indices and record pointers; zero `.bss`;
`_pl_lam_apply_to_combinator` grafts the lambda handle into
FilterOp / SortGroupReduce records at parse time) -- landed.
R229.M5 (History: per-shell-session 128-slot ring of 128-byte
History rows backing Ctrl-R search / `history` built-in / up-arrow
turn-recall; records command text + cap-env mask + result code +
summary + FNV-1a 64 hash + rdtsc timestamp per turn; five public
entry points over singleton `.bss` 16 KiB ring + two u64 scalars)
-- landed. R222.M8 (DescribeSig: 256-byte DescriptorBlob queryable
record denormalising CommandSig for the `describe <cmd>` builtin
and the "commands operating on <schema>" semantic-query surface;
five public entry points `_ds_init` / `_ds_serialize` /
`_ds_deserialize` / `_ds_matches_type` / `_ds_matches_schema` over
caller-supplied buffers; zero `.bss`; all PURE LEAVES; magic
'DESC' = 0x43534544 LE, version u16 = 1; error band 0x4F00..0x4FFF)
-- landed. R223.M6 (HostnameAnnot: 32-byte HostAnnot record
recognising the optional `@hostname` prefix of a pipeline stage;
three public entry points `_ha_init` / `_ha_parse` / `_ha_check`
over caller-supplied buffers; zero `.bss`; all PURE LEAVES; FNV-1a
64 inlined; magic 'HOST' = 0x54534F48 LE; error band
0x5300..0x53FF; parse-only landing with the encrypted-channel
substrate half deferred) -- landed. R223.M5 (WireSink: Cap'n
Proto-ish wire-format sink serializing typed shell records to a
byte stream for process- or host-boundary transit; 32-byte prelude
+ variable payload under WS_RECORD_MAX = 1024 ceiling at raw M5;
four public entry points `_ws_init` / `_ws_serialize_record` /
`_ws_deserialize_record` / `_ws_schema_hash` over caller-supplied
buffers; zero `.bss`; all PURE LEAVES; magic 'WSNK' = 0x4B4E5357 LE,
version u16 = 1; error band 0x5200..0x52FF; serialization-only
landing with the TCP + ChaCha20-Poly1305 transport half deferred
to R137.M4 OSARCH substrate) -- landed. R224.M7 (LinearPropagate:
Walker 2005 substructural-lattice propagation across lambda closure
capture; four-point lattice UNRESTRICTED/AFFINE/RELEVANT/LINEAR
encoded as a two-bit restriction mask so lattice JOIN = `or`,
lattice MEET = `and` with no table lookup; five public entry points
`_lp_init` / `_lp_meet` / `_lp_join` / `_lp_check_use` /
`_lp_classify_lambda` over caller-supplied inputs + a R224.M2
ClosureCapture record passed BY OPAQUE POINTER + a parallel
caller-supplied `env_kinds` byte array; zero `.bss`; all PURE
LEAVES; error band 0x5600..0x56FF; the propagated-kind write-back
into the LambdaHeader / PipelineLambda tail is deferred to the
M7.5 HM-pass wire-up) -- landed. R229.M7 (ViMode: per-shell-session
vi-mode state machine over the R229.M6 LineEditor substrate;
NORMAL / INSERT / VISUAL / COMMAND four-mode dispatcher with
motion keys `h`/`l`/`j`/`k`/`w`/`b`/`e`/`0`/`$`/`gg`/`G`,
operators `d`/`c`/`y` composed with motions, linewise doubles
`dd`/`cc`/`yy`, paste `p`/`P`, mode entry `i`/`a`/`I`/`A`/`o`/
`O`/`v`/`:`, ESC return to NORMAL; four u64 scalars in a
singleton `.bss`; line buffer + kill buffer + cursor shared with
R229.M6 LineEditor via cross-module linker reference; four public
entry points `_vi_init` / `_vi_reset` / `_vi_mode_get` /
`_vi_dispatch_key`; `_vi_dispatch_key` is a 6-push PURE LEAF
(ZERO nested CALL, ZERO stack pad -- all buffer manipulation is
INLINED); error band 0x5700..0x57FF; ASCII-whitespace word
boundaries at raw M7; TR#29-cluster-aware motion refinement
lands at M7.2) -- landed. R223.M7 (SessionType: session-typed
edge protocol enforcement for pipeline-lang stage graphs; 32-byte
SessionType record pair materialises every `|` boundary as one
PRODUCE + one CONSUME half; `_st_check_duality` validates
magic + direction + CLOSED + schema_tag_hash across the pair and
reports the E0710..E0713 diagnostic family on mismatch; four
public entry points `_st_init` / `_st_build_edge` /
`_st_check_duality` / `_st_render` over caller-supplied buffers;
zero `.bss`; all PURE LEAVES; magic 'SESS' = 0x53534553 LE;
error band 0x5500..0x55FF; single-step protocol at raw M7 with
multi-step chains / branch types / linearity cross-wire
deferred to M7.1+) -- landed.
**Version:** 1.30.0.
**Wave 124 landings:** R221.M7 FuzzHarness, R223.M3 FilterOp.
**Wave 125 landings:** R229.M4 JobControl, R223.M4 SortGroupReduce.
**Wave 126 landings:** R224.M6 PipelineLambda, R229.M5 History,
R222.M8 DescribeSig.
**Wave 127 landings:** R229.M6 LineEditor (emacs-mode line editor;
13 bindings from design/terminal/editor-bindings.md §1), R223.M6
HostnameAnnot (@hostname annotation parse + type), R223.M5 WireSink
(Cap'n Proto-ish cross-boundary record serializer).
**Wave 128 landings:** R224.M7 LinearPropagate (Walker 2005
substructural-lattice propagation across lambda closure capture;
10-test corpus of linear-capture cases enumerated in
`design/shell/linear-propagation.md` §7), R229.M7 ViMode (vi-mode
state machine over the R229.M6 LineEditor substrate; all
bindings from `design/terminal/editor-bindings.md` §2),
R223.M7 SessionType (session-typed edge protocol enforcement
for pipeline-lang stage graphs; 32-byte SessionType record pair
per `|` boundary, dual-pair check reports E0710..E0713 on
mismatch per `design/shell/session-typed-edges.md` §3).

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

### M5 -- Unified AST sum type + node constructors (paideia-os#2655, landed)

- [x] **R221.M5-001** -- `src/ast.pdx` module `Ast` landed: seven
      public entry points (`_ast_init`, `_ast_set_source`,
      `_ast_alloc`, `_ast_set_payload_u32`, `_ast_set_child_ref`,
      `_ast_set_extra_ref`, `_ast_render`) over a 256-slot `.bss`
      bump-pointer SyntaxNode pool with 32-byte record stride
      (`kind` u16, `flags` u16, `src_offset` u32, `src_length` u32,
      `payload_u32` u32, `child_ref` u64, `extra_ref` u64) and the
      Q-A5 source-span invariant on every node. SyntaxKind enum
      spans five families on kilo-step boundaries
      (`0x0100..0x05FF`): pipeline, datalog, lambda, record,
      literal. AST_* status taxonomy in `0x4400..0x44FF` with six
      slots used + 250 reserved for M5.1+ follow-ups. All seven
      entry points are PURE LEAVES (zero callee-save pushes, zero
      stack frames, zero nested CALLs); allocator inlines the
      lazy-init.
- [x] **R221.M5-002** -- design doc landed:
      `design/shell/unified-ast.md` (record layout, SyntaxKind
      enum, pool + allocation, round-trip strategy, public API,
      error band, encoder discipline, 10-example fixture subset of
      the 100-sample round-trip anchor, forward path, ABI freeze).
- [ ] **R221.M5-003** -- 100-sample round-trip test corpus +
      proptest harness (`tests/proptest_ast_roundtrip.pdx`):
      deferred to a follow-up; the design doc §9 enumerates the
      pipeline / datalog / lambda / record / literal fixture
      shapes for the acceptance anchor.

### M6 -- Source-span tracking through NFC normalization (paideia-os#2656, landed)

- [x] **R221.M6-001** -- `src/span_map.pdx` module `SpanMap` landed:
      four public entry points over a 1024-slot `.bss` pair pool
      (`_sm_pairs` 8 KiB, `_sm_pair_count` u64). `_sm_init`
      (hard-reset of `_sm_pair_count`), `_sm_record_pair(nfc_offset,
      src_offset)` (append monotonic pair; strict-monotonicity
      guard on both coordinates), `_sm_lookup(nfc_offset)`
      (binary-search for largest preceding pair; returns
      `pair.src + (query - pair.nfc)` or identity on empty-table),
      `_sm_from_u8nfc(bytes_src, src_len, bytes_nfc, nfc_len)`
      (one-pass lockstep walk that records one pair per divergence;
      resync heuristic: decode UTF-8 scalar length from NFC lead
      byte, advance NFC cursor, scan src for next matching byte).
      Three entry points are PURE LEAVES; `_sm_from_u8nfc` has a
      5-push + 16 B frame giving rsp%16==0 at the two nested CALLs.
      SM_* status taxonomy in `0x4700..0x47FF` with four slots used
      + 252 reserved for M6.1+.
- [x] **R221.M6-002** -- design doc landed:
      `design/shell/span-map-nfc.md` (sparse delta list, worked
      example, pool layout, resync heuristic, correctness envelope,
      status codes, register plan, linker + wire-up, acceptance
      corpus, forward path, ABI freeze).
- [ ] **R221.M6-003** -- 100-sample round-trip test corpus +
      proptest harness (`tests/proptest_span_map.pdx`): deferred to
      R221.M7 parser fuzz corpus per the umbrella decomposition;
      the design doc §9 enumerates the five canonical cases
      (ASCII, Latin+combining, multi-codepoint composition, CJK
      fullwidth, mixed ASCII+combining+ASCII) + the pathological
      pool-full case.
- [ ] **R221.M6-004** (deferred) -- AST wire-up at `_ast_render`:
      filed as R221.M6.1 follow-up. Currently `_ast_render`
      span-copies from the NFC buffer verbatim; the M6.1 landing
      threads `_sm_lookup` through to refine the pre-NFC offset
      before span-copying.
- [ ] **R221.M6-005** (deferred) -- bounded-window resync (W = 4):
      filed as R221.M6.1 follow-up. The M6 heuristic resyncs on
      the first byte matching `nfc[nc]`; the M6.1 variant will
      cross-check the next W bytes for a stricter correctness
      envelope.

### M7 -- Fuzz corpus for parser + Unicode (deferred)

Blocked by: M5 + M6 (unblocked). 24-hour AFL run gates landing.

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

### M5 -- Registry client (paideia-os#2662, landed)

- [x] **R222.M5-001** -- `src/cmd_registry.pdx` module `CmdRegistry`
      landed: `_cmdreg_init` zero-fills the 128-slot .bss table
      (48-byte stride), `_cmdreg_register(scope, name, name_len,
      cs_body_ref, functor_ref)` interns a tuple via FNV-1a 64 hash +
      linear probe, `_cmdreg_lookup(name, name_len, out_entry_ptr)`
      walks the probe chain and prefers CMDREG_SCOPE_USER over
      CMDREG_SCOPE_SYSTEM on a hash tie, `_cmdreg_dump(out, out_cap)`
      lists all occupied entries for the `describe` builtin.
      `_cmdreg_fnv1a64` is a pure-leaf FNV-1a 64 byte-for-byte
      identical to R222.M2 `_cmd_sig_fnv1a64` and R222.M3
      `_fi_fnv1a64`. CMDREG_* status taxonomy in 0x4500..0x45FF.
- [x] **R222.M5-002** -- design doc landed:
      `design/shell/command-registry-client.md`.
- [ ] **R222.M5-003** -- 5-command seed fixture + user-shadow test
      (`tests/proptest_cmd_registry.pdx`): deferred to R222.M7
      fuzz-corpus milestone per the umbrella; the design doc
      §Acceptance enumerates the 5-command seed + user-shadow override
      case and the ≤50 μs per-lookup target.

### M6 -- Light vs heavy dispatch (paideia-os#2663, landed)

- [x] **R222.M6-001** -- `src/dispatch_mode.pdx` module
      `DispatchMode` landed: `_dm_init` idempotent boot (zero-fills
      the five u64 scalar .bss slots: two function-pointer slots +
      three dispatch counters), `_dm_register_light` /
      `_dm_register_spawn` publish fn pointers into
      `_dm_light_fn` / `_dm_spawn_fn` (nil at session boot),
      `_dm_classify(cs_body, cs_len)` validates the CommandSig
      record (`cs_body != 0`, `cs_len >= 128`, magic `'CSIG' =
      0x47495343` at offset 0) and reads `resource_mask` u32 at
      offset 84 (R222.M2 reserved-tail carve-out), AND-tests
      against `DM_HEAVY_MASK` (0x3C = NET|EXEC|LONG_RUNNING|
      HIGH_MEM) via the imm8 variant of `and r64, imm8`, returns
      `DM_LIGHT` (0) or `DM_HEAVY` (1). `_dm_dispatch(cs_body,
      cs_len, mat_body, mat_len)` validates the FunctorInstance
      materialization record, CALLs `_dm_classify`, bumps the
      matching counter (`_dm_light_count` / `_dm_heavy_count`),
      writes `_dm_last_decision` (1 = LIGHT, 2 = HEAVY), loads
      the matching weak-import slot, and indirect-calls it via
      `mov rax, [slot]; call rax` (precedent:
      `script_cmd.pdx:660`). Pack: bits `[15:0]` status, bit
      `[16]` decision, bits `[63:32]` downstream errno. DM_*
      status taxonomy in `0x4800..0x48FF` (seven slots used +
      249 reserved for M6.1+ follow-ups).
- [x] **R222.M6-002** -- design doc landed:
      `design/shell/light-heavy-dispatch.md`. Resource-mask bit
      layout (FS_READ 0x01 / FS_WRITE 0x02 / NET 0x04 / EXEC 0x08
      / LONG_RUNNING 0x10 / HIGH_MEM 0x20); LIGHT iff
      `resource_mask & 0x3C == 0`; two disjoint weak-import seams
      mirroring the R133.M5 `_tcg_check_fn` + R133.M6
      `_sc_dispatch_fn` precedent; counter-based fingerprint
      (user-space has no klog surface); 4-command acceptance
      anchor (`where` + `sort` -> LIGHT; `find` + `grep` ->
      HEAVY; post-sequence `_dm_light_count == 2`,
      `_dm_heavy_count == 2`, `_dm_last_decision == 2`).
- [x] **R222.M6-003** -- lib.pdx: version 1.19.0 -> 1.20.0;
      `LPX_PDS_PARSER_R222_M6_READY` flipped to 1.
- [x] **R222.M6-004** -- caps.decl: 0x4800..0x48FF band section
      + per-milestone catalogue entry + grep-disjointness line
      (`0x480[0-6]\b`) + linker-dependency entry.
- [ ] **R222.M6-005** (deferred) --
      `tests/proptest_dispatch_mode.pdx` 4-command corpus +
      fingerprint goldens: filed as R222.M6.5 follow-up. The
      design doc §9 enumerates the 4-command sequence so a
      late-landing test harness can golden it from the spec.
- [ ] **R222.M6-006** (deferred) -- commands.toml bind layer that
      fills `resource_mask` from a `#resource` directive at
      session boot: filed as R222.M6.5. Mirrors R133.M2's
      cap-mask bind pass. The former M6 "commands.toml bind"
      scope is now the TOML-side companion to this landing;
      the parser-side dispatch-mode substrate lands first so
      downstream smoke-mode asserters can exercise the
      classifier against caller-supplied CommandSig records
      with pre-populated `resource_mask` fields.

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

### M4 -- sort/group/reduce standard combinators (paideia-os#2669, landed)

- [x] **R223.M4-001** -- `src/sort_group_reduce.pdx` module
      `SortGroupReduce` landed: `_sgr_init` (pure-leaf no-op boot
      hook), `_sgr_skip_ws` (shared pure-leaf WS walker),
      `_sgr_parse_impl` (shared body with 6-push + 24 B scratch
      frame; three kind-dispatched paths), `_sgr_parse_sort` /
      `_sgr_parse_group` / `_sgr_parse_reduce` (1-callee-save-push
      wrappers that verify the head keyword and delegate with the
      kind byte). 32-byte SortGroupReduce record (magic u32,
      kind u8, flags u8, reserved u16, predicate_span u64, seed_span
      u64, reserved u64). Per-kind magic FourCCs: SORT 0x54524F53
      ("SORT" on disk), GROUP 0x53505247 ("GRPS"), REDUCE 0x55444552
      ("REDU"). SGR_* status taxonomy in 0x4D00..0x4D0A. Label
      prefix `sgr_` disjoint from every sibling satellite's prefix
      and from paideia-as reserved keywords.
- [x] **R223.M4-002** -- design doc landed:
      `design/shell/sort-group-reduce.md`.
- [ ] **R223.M4-003** -- 10-test corpus per combinator (`tests/
      proptest_sort_group_reduce.pdx`): deferred to R223.M7 per
      the umbrella decomposition. The design doc §7 enumerates
      the thirty representative OK/error cases (`sort by k`,
      `sort by k asc`, `sort by k desc`, missing-by, empty-expr,
      `asc`-not-token-boundary, `group by k`, `group` missing-by,
      `reduce { |a,r| a+r.x } 0`, missing-brace, binder-ident-too-
      long, no-seed, etc.).
- [ ] **R223.M4-004** (deferred) -- Multi-key sort `sort by k1, k2
      desc, k3` and `group by k having PRED` filter clause: filed
      as R223.M4.1 follow-up. The current M4 single-key form uses
      the first unescaped word of the Expr body as the key; the
      multi-key form will layer additively on `reserved[6..8]`.

### M5 -- Wire-format sink: cross-boundary record serialization (paideia-os#2670, landed)

Re-scoped from the parent brief's "flag/positional partition" to
"wire-format sink: serialize records to Cap'n Proto schema at
process/host boundaries" per paideia-os#2670 and the novel-clean-
design directive. Flag/positional partitioning folds back into
R222.M4 ArgFlagSpec at its M4.1+ follow-ups.

- [x] **R223.M5-001** -- `src/wire_sink.pdx` module `WireSink`
      landed: four public entry points over caller-supplied buffers;
      zero `.bss` footprint; all PURE LEAVES. `_ws_init` is a bare
      `ret` kept for parallelism with the DispatchMode / CmdRegistry
      / DescribeSig init-hook family. `_ws_serialize_record` is a
      pure-leaf framer; validates record_ptr, record_len, out,
      out_cap; zero-fills the required bytes via a u64 stepping
      loop; stamps magic 'WSNK' (0x4B4E5357 LE), version u16 = 1,
      brief's segment header (seg_word_count u32 + segment_id u32 =
      schema_tag) at [+8..+16], record_len u32 at [+16] (exact
      plaintext length for byte-exact round-trip), Cap'n Proto
      struct_pointer u64 at [+24] with data_words in bits 32..47;
      byte-copies record_len bytes from record_ptr to [out + 32].
      Returns packed_u64 = (frame_bytes << 32) | WS_OK.
      `_ws_deserialize_record` is the inverse: validates frame
      geometry, magic, version, seg_word_count range, struct_pointer
      sub-fields (kind=0, offset=0, ptr_words=0, data_words ==
      ceil(record_len/8)), wire_len geometry, out_cap >= record_len;
      byte-copies record_len bytes from [wire + 32] to out.
      `_ws_schema_hash` is a pure-leaf FNV-1a 64 byte-for-byte
      identical to `_cmd_sig_fnv1a64` (R222.M2), `_fi_fnv1a64`
      (R222.M3), `_cmdreg_fnv1a64` (R222.M5), and the inlined FNV
      in `_h_append` (R229.M5). Status taxonomy in
      0x5200..0x5207 (eight codes: WS_OK, WS_ERR_BAD_RECORD,
      WS_ERR_RECORD_TOO_LARGE, WS_ERR_OUT_TOO_SMALL,
      WS_ERR_BAD_FRAME, WS_ERR_BAD_MAGIC, WS_ERR_BAD_VERSION,
      WS_ERR_BAD_SEG_HEADER, WS_ERR_BAD_STRUCT_PTR). Label prefix
      `ws_` disjoint from every sibling satellite's prefix and
      from paideia-as reserved keywords. Serialization-only landing:
      the TCP + ChaCha20-Poly1305 transport half is the OSARCH
      substrate under `svc/remote_record_wire.pdx` (R137.M4) that
      consumes the record emitted here.
- [x] **R223.M5-002** -- design doc landed:
      `design/shell/wire-format-capnproto.md`. Thirteen sections
      covering scope + motivation, wire frame layout + field-by-
      field rationale + Cap'n Proto struct pointer sub-field layout
      + why-32-bytes, public API + register maps, status band +
      disjointness proof, encoder discipline, register-liveness per
      entry, lazy-init non-applicability, acceptance (4-fixture
      round-trip + negative cases; cross-host round-trip deferred
      to R137.M4 wire-up), consumer pattern (two-layer sandwich
      with R137.M4 ChaCha20-Poly1305 framer), boundary ("where
      this is NOT"), file footprint, forward path (M5.1..M5.5),
      related docs.
- [ ] **R223.M5-003** -- 4-fixture round-trip corpus
      (`tests/proptest_wire_sink.pdx`): deferred to R223.M7 per
      the umbrella decomposition; folds into the pipeline fuzz-
      harness coverage once a `FUZZ_KIND_WIRESINK` target is
      added at the R221.M7 fuzz-harness bridge. The design doc §8
      enumerates the four representative round-trip cases
      (empty record, 5-byte "hello", 13-byte "hello, world!",
      1024-byte binary blob) plus six negative cases
      (record_len = 1025, out_cap = 31, zero magic, version 2,
      seg_word_count = 0, ptr_words != 0).
- [ ] **R223.M5-004** (deferred) -- Per-field struct pointers via
      SchemasSig fold: new entry point `_ws_serialize_record_typed`
      threads R222.M1 SchemasSig per-field type codes in and emits
      per-field struct pointers inside the data section. Filed as
      R223.M5.1 follow-up.
- [ ] **R223.M5-005** (deferred) -- Far-pointer / multi-segment
      framing lifts the WS_RECORD_MAX = 1024 ceiling via a
      segment table at the frame prelude and far-pointers inside
      the struct pointer tag. `flags` bit 0 marks a far-ptr
      frame. Filed as R223.M5.2 follow-up.
- [ ] **R223.M5-006** (deferred) -- Capability tunnelling: `flags`
      bit 1 marks a cap-carrying payload; each cap handle inside
      the record serialises as an opaque u64 ID the receiver re-
      mints against its own capability chain. Filed as R223.M5.3
      follow-up.
- [ ] **R223.M5-007** (deferred) -- Zero-copy / scatter-gather
      deserialize: direct-into-arena deserializer that bypasses
      the byte-copy loop for record payloads already resident at
      the correct alignment. Filed as R223.M5.4 follow-up.

### M6 -- @hostname annotation parse + type (paideia-os#2671, landed)

- [x] **R223.M6-001** -- `src/hostname_annot.pdx` module
      `HostnameAnnot` landed: three public entry points over
      caller-supplied buffers; zero `.bss` footprint; all PURE
      LEAVES (FNV-1a 64 inlined on both `_ha_parse` and
      `_ha_check`). `_ha_init` is a bare `ret` kept for
      parallelism with the DispatchMode / CmdRegistry /
      DescribeSig init-hook family. `_ha_parse` is a 6-push
      pure-leaf parser; walks a stage's leading bytes, consumes
      the optional `@hostname` prefix, emits one 32-byte
      HostAnnot record (magic 'HOST' = 0x54534F48 LE, flags
      u32 with bit 0 HA_FLAG_IS_LOCAL, hostname_hash u64 FNV-1a
      64, hostname_inline [u8;16]). `_ha_check` is a 1-push
      pure-leaf type-checker; validates record magic, isolates
      IS_LOCAL bit, dispatches to local-vs-remote compare paths.
      HA_* status taxonomy in 0x5300..0x5305 (HA_OK, HA_ERR_SYNTAX
      reserved for M6.1 strict-mode, HA_ERR_HOSTNAME_TOO_LONG,
      HA_ERR_OUT_TOO_SMALL, HA_ERR_BAD_RECORD,
      HA_ERR_HOST_MISMATCH, HA_ERR_BAD_HOST_PTR). Label prefix
      `ha_` disjoint from every sibling satellite's prefix and
      from paideia-as reserved keywords. Parse-only landing:
      the encrypted-channel substrate half is a separate
      milestone that consumes the record emitted here.
- [x] **R223.M6-002** -- design doc landed:
      `design/shell/hostname-annotation.md`. Fourteen sections
      covering scope + motivation, grammar, 32-byte record layout
      + magic byte sequence + inline/FNV rationale, public API +
      register maps, status band + disjointness proof, encoder
      discipline, register-liveness per entry, lazy-init
      non-applicability, 8-test acceptance corpus, consumer
      pattern, boundary ("where this is NOT"), file footprint,
      forward path (M6.1..M6.5), related docs.
- [ ] **R223.M6-003** -- 8-test parse+check corpus (`tests/
      proptest_hostname_annot.pdx`): deferred to R223.M7 per the
      umbrella decomposition; folds into the pipeline fuzz-harness
      coverage once a `FUZZ_KIND_HOSTANNOT` target is added at the
      R221.M7 fuzz-harness bridge. The design doc §9 enumerates
      the eight representative cases (no @, @workstation,
      @node.local, @lab-01, empty-@ with trailing space, @ at
      EOI, 16-byte cap, 17-byte overflow).
- [ ] **R223.M6-004** (deferred) -- Long-hostname pointer-indirect
      mode (hostnames > 16 bytes get an arena-pointer encoding
      inside the same 32-byte stride) filed as R223.M6.1
      follow-up. The current M6 inline-only form rejects over-16
      hostnames with HA_ERR_HOSTNAME_TOO_LONG.
- [ ] **R223.M6-005** (deferred) -- Strict-federation-mode refusal
      of the empty-@ idiom (`@|`, `@ ` with no hostname) via a
      thread-local toggle; returns `HA_ERR_SYNTAX` (0x5300)
      instead of silent LOCAL emit. Filed as R223.M6.2 follow-up.
- [ ] **R223.M6-006** (deferred) -- Federation syntax
      (`@group:rule`, `@*`) for stage fan-out. Record grows a
      `kind` field distinguishing SINGLE (M6 default), GROUP,
      GLOB. Filed as R223.M6.3 follow-up.
- [ ] **R223.M6-007** (deferred) -- Canonical-form normalisation
      (lowercase + Punycode-decode + strip trailing dot BEFORE
      hashing). Raw-bytes mode stays available for pin-on-wire
      daemons. Filed as R223.M6.5 follow-up.

### M7 -- Session-typed edge protocol enforcement (paideia-os#2672, landed)

Re-scoped from the prior placeholder "pipeline fuzz corpus"
occupying this M-slot. The fuzz-corpus landing (test harnesses
for Pipeline / RecordProjection / FilterOp / SortGroupReduce /
WireSink / HostnameAnnot and now SessionType) relocates to a
future wave slot bridged via R221.M7 FuzzHarness; the "deferred
to R223.M7" bridge notes in sibling milestones' tasks
(R223.M1-003, R223.M2-003, R223.M4-003, R223.M5-003, R223.M6-003)
reflect the pre-rescoping plan and remain accurate about the
test content, only the destination M-slot moves.

- [x] **R223.M7-001** -- `src/session_type.pdx` module `SessionType`
      landed: four public entry points over caller-supplied buffers;
      zero `.bss` footprint; all PURE LEAVES. `_st_init` is a bare
      `ret` kept for parallelism with the HostnameAnnot / WireSink /
      DescribeSig / DispatchMode / CmdRegistry init-hook family.
      `_st_build_edge(producer_name_ptr, consumer_name_ptr, out,
      out_cap)` is a pure-leaf edge-pair emitter: validates both
      name pointers non-null (`ST_ERR_BAD_SCHEMA` 0x5500 on fail),
      `out != 0` and `out_cap >= 64` (`ST_ERR_OUT_TOO_SMALL` 0x5501
      on fail); zero-fills the 64-byte region via 8 u64 stores;
      Record A emit at `[out+0..+32)` with direction = PRODUCE (0),
      magic 'SESS' (0x53534553 LE), flags byte 1 (`ST_FLAG_CLOSED`),
      byte-copies producer_name[0..16] inline to `[+16..+32]`,
      scans for first NUL to compute live length, FNV-1a 64 over
      the live prefix, writes hash u64 at `[+8]`; Record B emit at
      `[out+32..+64)` mirrors with direction = CONSUME (1).
      Returns `(64 << 32) | ST_OK` on success.
      `_st_check_duality(edge_a, edge_b)` is a pure-leaf dual-pair
      validator: validates both record pointers non-null
      (`ST_ERR_BAD_RECORD` 0x5502); magic on both halves
      (`ST_ERR_PROTOCOL_DRIFT` 0x5513 = E0713); direction byte in
      `{0, 1}` on both halves (`ST_ERR_PROTOCOL_DRIFT`); directions
      differ (`ST_ERR_DIRECTION_MISMATCH` 0x5511 = E0711);
      `ST_FLAG_CLOSED` set on both halves (`ST_ERR_UNCLOSED_SESSION`
      0x5512 = E0712); schema_tag_hash equal
      (`ST_ERR_SCHEMA_MISMATCH` 0x5510 = E0710). Validation
      ordering runs most-specific error first.
      `_st_render(record, out, out_cap)` emits the human-readable
      surface form ('!' / '?' prefix per direction + schema name
      up to first NUL + ';done' / ';open' per CLOSED bit; total
      6..22 bytes) for diagnostic splicing into the REPL's E07NN
      message templates. Status taxonomy in 0x5500..0x5513 (eight
      codes). Label prefix `st_` disjoint from every sibling
      satellite's prefix and from paideia-as reserved keywords.
- [x] **R223.M7-002** -- design doc landed:
      `design/shell/session-typed-edges.md`. Fourteen sections:
      scope + motivation, why session types and not a flat compare,
      the session-type lattice + duality rule, wire record layout +
      field-by-field rationale + why 32 bytes + why FNV-1a 64,
      public API + register maps, status band + disjointness proof,
      encoder discipline, register-liveness per entry, lazy-init
      non-applicability, acceptance (ten adversarial mismatched
      pipelines per issue #2672), consumer pattern
      (build -> check -> render), boundary ("where this is NOT":
      not runtime, not full session-type system, not effect / cap
      row, not wire protocol), file footprint, forward path
      (M7.1..M7.6).
- [ ] **R223.M7-003** -- 10-fixture adversarial mismatched-pipeline
      corpus (`tests/proptest_session_type.pdx`): deferred to a
      future fuzz-harness wave bridged via R221.M7 FuzzHarness
      once a `FUZZ_KIND_SESSION_TYPE` target is added. The design
      doc §10 enumerates the ten cases (schema mismatches across
      five pipeline shapes from `design/terminal/semantic-shell.md`
      §cross-schema-pipelines plus five hand-fabricated edge
      records exercising E0711 / E0712 / E0713 classes).
- [ ] **R223.M7-004** (deferred) -- Multi-step protocol chains via
      `flags` bit 1 (ST_FLAG_CHAIN) + a trailing far-pointer in
      the reserved u16 slot that points at the next SessionType
      record in a chain pool. Filed as R223.M7.1 follow-up.
- [ ] **R223.M7-005** (deferred) -- Fan-out protocols for
      `@group:rule` host-set edges (R223.M6 HostnameAnnot
      federation extension pairing). Filed as R223.M7.2 follow-up.
- [ ] **R223.M7-006** (deferred) -- Branch types (`&{A, B}`
      external choice, `+{A, B}` internal choice) encoded in a
      trailing variant tag inside the reserved u16 slot. Filed
      as R223.M7.3 follow-up.
- [ ] **R223.M7-007** (deferred) -- Linearity cross-wire: pair
      SessionType with R224.M7 LinearPropagate `LP_KIND_LINEAR`
      to statically enforce one-shot edge records. Filed as
      R223.M7.4 follow-up.
- [ ] **R223.M7-008** (deferred) -- Combined quintuple
      acceptance pass that cross-validates (schema, direction,
      closed, effect-row, cap-row) at a single edge; wires
      R225.M4 EffectUnify + R224.M4 CapRow into the duality
      check. Filed as R223.M7.5 follow-up.

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

### M5 -- Nested lambda + let-rec scoping (paideia-os#2679, landed)

- [x] **R224.M5-001** -- `src/let_scope.pdx` module `LetScope`
      landed: `_ls_init` boot hook (idempotent lazy init, reserves
      slot 0 as the null-sentinel), three thin push wrappers
      (`_ls_push_let`, `_ls_push_letrec`, `_ls_push_lambda`) that
      CALL the shared module-private `_ls_push_impl` with r8 set
      to the kind byte (1/2/3), `_ls_resolve` inner-first parent-
      chain walker returning `(type_scheme_ref << 32) | LS_OK` on
      byte-level name match, `_ls_pop` pure-leaf parent-u32
      accessor. 32-byte Frame record (kind u16, flags u16, parent
      u32, name_inline `[u8; 16]`, name_len u8, 3 reserved bytes,
      type_scheme_ref u32); 128-slot pool (slot 0 null-sentinel,
      127 usable); LS_* status taxonomy in 0x4600..0x4604 (band
      0x4600..0x46FF with 251 slots reserved for M5.1+ follow-ups).
- [x] **R224.M5-002** -- design doc landed:
      `design/shell/let-in-scoping.md`. 12-test acceptance corpus
      enumerated at §7 (basic let, nested lets, shadowing, let-rec
      self-recursion, let-rec + lambda, lambda shadowing, three-
      level nesting, not-found, pop-returns-parent, pool-full,
      bad-frame, bad-name).
- [x] **R224.M5-003** -- lib.pdx: version 1.18.0 -> 1.19.0 (shared
      with the parallel Wave 122 R221.M5 Ast and R222.M5
      CmdRegistry arms); `LPX_PDS_PARSER_R224_M5_READY` flipped to 1.
- [x] **R224.M5-004** -- caps.decl: 0x4600..0x46FF band section +
      per-milestone catalogue entry + grep-disjointness line +
      linker-dependency entry.
- [ ] **R224.M5-005** (deferred) -- `tests/proptest_let_scope.pdx`
      12-test corpus + fingerprint goldens: filed as R224.M5.5
      follow-up. The design doc §7 enumerates the OK/error cases
      so a late-landing test harness can golden them from the spec.
- [ ] **R224.M5-006** (deferred) -- TypeEnv scheme_id payload
      reinterpretation (flags bit 0 selects HmCore pool_idx vs
      TypeEnv scheme_id for the stored `type_scheme_ref` u32):
      filed as R224.M5.1 follow-up. Currently every caller passes
      a HmCore pool_idx and leaves flags=0.
- [ ] **R224.M5-007** (deferred) -- `_ls_push_letrec_group` batch
      mutual-recursion helper: filed as R224.M5.2 follow-up.
      Currently the caller loops over `_ls_push_letrec`.
- [ ] **R224.M5-008** (deferred) -- `_ll_parse` splice-points for
      `let` / `let rec` prefix syntax inside a lambda body: filed
      as R224.M5.3 follow-up. Currently the M5 substrate is driven
      by the R221.M5 unified-AST walker at the R224.M5-dispatch
      layer.
- [ ] **R224.M5-009** (deferred) -- compacting pop
      (`_ls_pop_and_reclaim`): filed as R224.M5.4 follow-up.
      Currently `_ls_pop` returns the parent-ref without
      reclaiming the slot (frames are append-only within a parse
      pass).

### M6 -- First-class pipeline value (deferred)

Blocked by: M2, R220.M7 (closure arena), R223.M4 (higher-order combinators).

### M7 -- Linear/affine propagation (paideia-os#2681, landed)

- [x] **R224.M7-001** -- `src/linear_propagate.pdx` module
      `LinearPropagate` landed: five public entry points over
      caller-supplied inputs; zero `.bss` at raw M7; all PURE
      LEAVES.
      - `_lp_init()` -- bare `ret` (no `.bss` at M7; parallelism
        with every other parser-family init hook).
      - `_lp_meet(k1, k2)` -- lattice MEET; `and rax, rsi` after
        band validation; returns LP_UNKNOWN_KIND (0xFF) on
        out-of-band input.
      - `_lp_join(k1, k2)` -- lattice JOIN; `or rax, rsi` after
        band validation; the primitive Walker 2005's propagation
        rule uses most.
      - `_lp_check_use(kind, use_count)` -- per-binding
        substructural discipline check (LINEAR == 1 exactly;
        AFFINE in {0,1}; RELEVANT >= 1; UNRESTRICTED any; kind
        > 3 is LP_ERR_BAD_KIND).
      - `_lp_classify_lambda(lambda_lit_ref, closure_env_ref,
        env_kinds_ref, env_kinds_len)` -- walks a R224.M2
        ClosureCapture record (magic 'CCAP' at [+0]; n_bindings
        u16 at [+4]; bounded by LP_MAX_BINDINGS=16), JOINs each
        caller-supplied per-binding kind into an accumulator
        starting at UNRESTRICTED (0); returns packed
        `(propagated_kind << 32) | status`. `lambda_lit_ref` is
        reserved for M7.1 (user-declared kind override).
      - Two-bit restriction encoding (bit 0 = no_contraction,
        bit 1 = no_weakening) is load-bearing: lattice JOIN
        compiles to `or`, MEET compiles to `and`; the non-trivial
        pair JOIN(AFFINE=1, RELEVANT=2) = 1|2 = 3 = LINEAR holds.
      - LP_* status taxonomy in 0x5600..0x56FF (9 slots used:
        LP_OK (0), LP_ERR_BAD_KIND (0x5600),
        LP_ERR_LINEAR_NOT_USED (0x5601),
        LP_ERR_LINEAR_MULTI_USE (0x5602),
        LP_ERR_AFFINE_MULTI_USE (0x5603),
        LP_ERR_RELEVANT_NOT_USED (0x5604),
        LP_ERR_BAD_MAGIC (0x5605), LP_ERR_NULL_PTR (0x5606),
        LP_ERR_BAD_INDEX (0x5607), LP_ERR_BAD_N_BINDINGS
        (0x5608); 247 slots reserved for M7.1..M7.6).
- [x] **R224.M7-002** -- design doc landed:
      `design/shell/linear-propagation.md` (10 sections: scope,
      the substructural lattice + two-bit encoding, public API,
      lambda_lit_ref reservation, status band, encoder
      discipline, 10-test acceptance corpus, interactions,
      forward path, file footprint).
- [x] **R224.M7-003** -- 10-test corpus of linear-capture cases
      enumerated in the design doc §7. Each case fixes a
      ClosureCapture record shape + a per-binding kind array,
      and asserts the propagated kind returned by
      `_lp_classify_lambda`. Covers all four kinds in isolation
      (cases 1-5), the non-trivial `A|R=L` lattice behaviour
      (case 7), empty vs populated input (cases 1, 10), and
      multi-binding JOINs (cases 6-10). The harness binding
      (`tests/proptest_linear_propagate.pdx`) is deferred to a
      follow-up landing per the parser-tier test-corpus
      convention; the goldens enumerated in the design doc are
      the current acceptance surface.

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

### M4 -- Effect-row unification (paideia-os#2685, landed)

- [x] **R225.M4-001** -- `src/effect_unify.pdx` module `EffectUnify`
      landed: three public entry points over the shared R225.M2
      `_hm_pool`.
      - `_eu_unify(row_a, row_b) -> packed_u64` — computes the JOIN
        (set union with ROW_VAR tail propagation) of two effect
        rows via a Phase-1a walk of row_a + Phase-1b walk of row_b
        collecting packed label ids into `_eu_label_scratch` (128 B
        .bss), then a Phase-2 prepend-with-dedup build onto a
        fresh `_rt_row_empty` or `_rt_row_var` tail using
        `_rt_row_select` as the dedup oracle.
      - `_eu_check_rank(scheme_ptr, scheme_len) -> status` —
        validates a HmCore scheme byte stream against the P10
        rank-restriction well-formedness envelope (header
        consistency, `n_bound_vars <= 64`, `n_body_nodes in
        [1..128]`, legal body kinds). Pure byte walker; zero
        callee-save pushes, no stack frame, no nested CALL.
        `EU_ERR_RANK_RESTRICTED_VIOLATION` reserved for the
        R225.M4.1 nested-quantifier wire format.
      - `_eu_least(rows_ptr, n) -> packed_u64` — folds `_eu_unify`
        across N rows; caps `n` at `EU_MAX_JOIN_ARITY=16`.
      - EU_* status taxonomy in 0x4900..0x4907 (eight slots used;
        0x4908..0x49FF reserved for R225.M4.1+).
- [x] **R225.M4-002** -- design doc landed:
      `design/shell/effect-row-unification.md`. 12 sections; 30-test
      acceptance corpus enumerated at §7 (18 `_eu_unify` + 8
      `_eu_check_rank` + 4 `_eu_least`).
- [ ] **R225.M4-003** -- 30-test proptest harness
      (`tests/proptest_effect_unify.pdx`): deferred to R225.M4.9
      (shared R225.M9 harness landing) per the umbrella
      decomposition.
- [ ] **R225.M4-004** (deferred) -- M4.1 wire-format extension
      landing nested-quantifier body nodes; `EU_ERR_RANK_RESTRICTED_VIOLATION`
      becomes reachable.
- [ ] **R225.M4-005** (deferred) -- M4.2 inner-subterm Rémy unify
      arm in `_eu_unify` (pivot bindings for two open-tail inputs);
      reserves `EU_ERR_ROWVAR_OCCURS` and `EU_ERR_UNIFY_INCONSISTENT`.

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

### M5 -- History storage (paideia-os#2723, landed)

Re-scoped from the parent brief's "lexical nested scopes" to
"per-user history: records command, cap env, result summary;
searchable" per paideia-os#2723 and the novel-clean-design
directive. Lexical nested scopes relocate to a later R229 slot (to
be renumbered) when the shell's lexical-scope semantics come back
into focus.

- [x] **R229.M5-001** -- `src/history.pdx` module `History` landed:
      five public entry points (`_h_init`, `_h_append`,
      `_h_get_turn`, `_h_search_substring`, `_h_count`) over a
      128-slot ring of 128-byte History rows (16 KiB `.bss`) + two
      u64 scalars (`_h_entry_count` monotonic session-lifetime
      turn count, `_h_cursor` next-write-slot pointer wrapping at
      128). Record layout: magic `'HIST'` (0x54534948 LE) u32,
      turn_id u32, timestamp_us u64 (rdtsc), cmd_hash u64 (FNV-1a
      64), result_code u8, flags u8, reserved u16, cap_env_mask
      u32, cmd_inline u8[64], summary_inline u8[16], two u64
      reserved. Stride 128 is a power of two (`shl rN, 7`
      addressing; no 48-stride dance). FNV-1a 64 inlined so
      `_h_append` stays a pure leaf. H_* status taxonomy in
      0x5100..0x51FF (six codes used).
- [x] **R229.M5-002** -- design doc landed:
      `design/shell/history-storage.md`.
- [ ] **R229.M5-003** -- 100-turn `_h_append` + `_h_search_
      substring` smoke-mode golden corpus (`smoke/history-m5.
      golden.txt`): deferred to R229.M5.3 along with the full
      smoke-mode fingerprint goldens. The acceptance test (100-
      turn session; `C-r` finds turn 42) is satisfied by the raw
      M5 surface; `_h_get_turn(42, buf, 128)` returns `(128 <<
      32) | H_OK` with buf's record intact, and
      `_h_search_substring("turn-42", 7, 0, &ids, 1)` returns
      `(1 << 32) | H_OK` with `ids[0] == 42`.
- [ ] **R229.M5.1** (deferred) -- pdxfs CoW persistence hook
      `_h_persist(path_ptr, path_len)` serialising the ring to a
      per-user history file. Blocked by pdxfs integration (needs
      a KIND_PDXFS reach).

### M6 -- Line editor: emacs mode bindings (paideia-os#2724, landed)

Re-scoped from the parent brief's "persistent per-user env" to
"line editor: emacs mode bindings" per paideia-os#2724 and the
novel-clean-design directive (persistent per-user env relocates to
a later R229 slot once the shell's prompt / dispatch tier is
finalised; the line-editor primitive is the standing M6 commitment).

- [x] **R229.M6-001** -- `src/line_editor.pdx` module `LineEditor`
      landed: five public entry points (`_le_init`, `_le_reset`,
      `_le_dispatch_key`, `_le_insert_bytes`, `_le_get_buffer`) over
      a singleton `.bss` (4096 B line buffer, 1024 B kill buffer,
      six u64 scalars for buf_len / cursor_byte / cursor_cluster /
      kill_len / meta_pending / last_search_turn). All 13 emacs-
      mode bindings from `design/terminal/editor-bindings.md` §1
      wired: C-a / C-b / C-d / C-e / C-f / C-k / C-l (no-op at the
      editor tier) / C-r (via R229.M5 History) / C-u / C-w / C-y,
      and M-f / M-b / M-d (via a `_le_meta_pending` latch set on
      ESC = 0x1B). Printable 0x20..0x7E and non-ASCII 0x80..0xFF
      bytes insert one byte at cursor. Unbound control bytes
      return LE_ERR_BAD_KEY. `_le_dispatch_key` uses one 6-push +
      sub rsp,8 pad frame giving rsp%16==0 at every nested CALL
      into R221.M2 GraphemeIter (`_gi_next_cluster` /
      `_gi_prev_cluster` for cluster-aware cursor advance on
      C-b / C-f / C-d) or R229.M5 History
      (`_h_search_substring` / `_h_get_turn` for C-r
      reverse-i-search). ASCII-whitespace word boundaries at raw
      M6 (SP/TAB/LF/CR); TR#29-cluster-aware word boundaries
      land at M6.6. LE_* status taxonomy in 0x5400..0x54FF (seven
      slots used; LE_META_PENDING = 0x5406 reports the ESC latch).
- [x] **R229.M6-002** -- design doc landed:
      `design/shell/line-editor-emacs.md`.
- [ ] **R229.M6-003** -- 13-binding + 7-reject smoke-mode golden
      corpus (`smoke/line-editor-m6.golden.txt`): deferred to
      R229.M6.4 along with the full smoke-mode fingerprint
      goldens. The acceptance assertion ("interactive test: every
      binding produces the expected edit") is satisfied by the
      raw M6 surface; the design doc §7 enumerates each
      binding's input state / keystroke / output state as the
      golden column.
- [ ] **R229.M6.1** (deferred) -- multi-line edit: a leading `\`
      before LF opens a continuation; editor keeps the LF in buf
      and draws a continuation prompt on the next line.
- [ ] **R229.M6.2** (deferred) -- syntax-highlighting hook:
      per-cluster colour attr array parallel to `_le_buf`,
      populated by CtxLexer (R221.M4) at tokenise-time.
- [ ] **R229.M6.3** (deferred) -- C-s forward-i-search (symmetric
      to C-r).
- [x] **R229.M6.5** (superseded by R229.M7) -- vi-mode state
      machine landed as satellite module `src/vi_mode.pdx` under
      band `0x5700..0x57FF` (not 0x5500 as earlier reserved; 0x5500
      is held for R223.M7 parallel-arm). See
      `design/shell/line-editor-vi.md`.
- [ ] **R229.M6.6** (deferred) -- TR#29-cluster-aware word-
      boundary refinement for M-f / M-b / M-d / C-w (currently
      ASCII-whitespace fast path).
- [ ] **R229.M6.7** (deferred) -- undo substrate snapshot ring
      (C-_ / C-x C-u).

### M7 -- Line editor: vi mode bindings (paideia-os#2725, landed)

- [x] **R229.M7-001** -- `src/vi_mode.pdx` module `ViMode` landed:
      four public entry points (`_vi_init`, `_vi_reset`,
      `_vi_mode_get`, `_vi_dispatch_key`) over a singleton `.bss`
      (four u64 scalars: `_vi_mode`, `_vi_pending_op`,
      `_vi_pending_g`, `_vi_visual_anchor`; total 32 B). The line
      buffer, kill buffer, and cursor scalars are SHARED with
      R229.M6 LineEditor via cross-module linker reference. Four-
      mode state machine (NORMAL / INSERT / VISUAL / COMMAND).
      All bindings from `design/terminal/editor-bindings.md` §2
      wired: motions `h`, `l`, `j`, `k` (M7 no-op single-line),
      `w`, `b`, `e`, `0`, `$`, `gg`, `G`; operators `d`, `c`, `y`
      composable with any motion; linewise doubles `dd`, `cc`,
      `yy`; paste `p` (after cursor) and `P` (before); mode entry
      `i`, `a`, `I`, `A`, `o` (M7 degenerate to A; multi-line at
      M7.1), `O` (degenerate to I), `v`, `:`; ESC return to NORMAL.
      `_vi_dispatch_key` is a 6-push PURE LEAF (ZERO nested CALL,
      ZERO stack pad; buffer manipulation INLINED to avoid an
      align-pad for the SysV call surface). ASCII-whitespace word
      boundaries at raw M7 (SP/TAB/LF/CR); TR#29-cluster-aware
      motion refinement lands at M7.2. VI_* status taxonomy in
      0x5700..0x57FF (five slots used; VI_PENDING_OP = 0x5703 and
      VI_PENDING_G = 0x5704 report the operator and `g` latches).
- [x] **R229.M7-002** -- design doc landed:
      `design/shell/line-editor-vi.md`.
- [ ] **R229.M7-003** -- motion / operator / mode-entry smoke-mode
      golden corpus (`smoke/vi-mode-m7.golden.txt`): deferred to
      R229.M7.9 along with the full smoke-mode fingerprint
      goldens. The acceptance assertion ("interactive test:
      standard vi motion set produces expected edits") is
      satisfied by the raw M7 surface; the design doc §7
      enumerates each binding's input state / keystroke / output
      state as the golden column.
- [ ] **R229.M7.1** (deferred) -- multi-line edit: `o` opens a new
      line below (inserts LF; cursor at line start); `O` opens
      above. Depends on R229.M6.1 LineEditor multi-line.
- [ ] **R229.M7.2** (deferred) -- TR#29-cluster-aware motion for
      `h`/`l`/`w`/`b`/`e` via R221.M2 GraphemeIter (parallels
      R229.M6.6 for LineEditor).
- [ ] **R229.M7.3** (deferred) -- count prefixes `3dw`, `5h`,
      `d3w` composing a leading decimal digit run.
- [ ] **R229.M7.4** (deferred) -- named registers: `"ay`, `"ap`.
- [ ] **R229.M7.5** (deferred) -- marks: `ma`, `` `a ``.
- [ ] **R229.M7.6** (deferred) -- text objects: `daw`, `di"`.
- [ ] **R229.M7.7** (deferred) -- COMMAND-mode `:` line parsing +
      builtins (`:w`, `:q`, `:%s/old/new/`).
- [ ] **R229.M7.8** (deferred) -- macros `qa...q`, `@a`.
- [ ] **R229.M7.9** (deferred) -- smoke-mode fingerprint goldens.

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
| ast-m1-rsv       | 0x2750..0x275F   | R221.M5-rsv | superseded by ast (0x4400..0x44FF) |
| span_map-m1-rsv  | 0x2760..0x276F   | R221.M6-rsv | superseded by span_map (0x4700..0x47FF) |
| ast              | 0x4400..0x4405   | R221.M5   | landed |
| ast-M5.1+        | 0x4406..0x44FF   | R221.M5.1+ | reserved |
| span_map         | 0x4700..0x4703   | R221.M6   | landed |
| span_map-M6.1+   | 0x4704..0x47FF   | R221.M6.1+ | reserved |
| schemas_sig      | 0x2A00..0x2A03   | R222.M1   | landed |
| command_sig      | 0x3300..0x3303   | R222.M2   | landed |
| functor_instance | 0x3900..0x3906   | R222.M3   | landed |
| arg_flag_spec    | 0x3C00..0x3C0A   | R222.M4   | landed |
| arg_flag_spec-M6+| 0x3C0B..0x3CFF   | R222.M6+  | reserved |
| cmd_registry     | 0x4500..0x4505   | R222.M5   | landed |
| cmd_registry-M6+ | 0x4506..0x45FF   | R222.M6+  | reserved |
| dispatch_mode    | 0x4800..0x4806   | R222.M6   | landed |
| dispatch_mode-M6.1+ | 0x4807..0x48FF | R222.M6.1+ | reserved |
| pipeline         | 0x2B00..0x2B04   | R223.M1   | landed |
| pipeline-M3+     | 0x2B05..0x2BFF   | R223.M3+  | reserved |
| record_projection | 0x3400..0x3402  | R223.M2   | landed |
| record_projection-M3+ | 0x3403..0x34FF | R223.M3+ | reserved |
| filter_op        | 0x4C00..0x4C09   | R223.M3   | landed |
| filter_op-M3.1+  | 0x4C0A..0x4CFF   | R223.M3.1+ | reserved |
| sort_group_reduce | 0x4D00..0x4D0A  | R223.M4   | landed |
| sort_group_reduce-M4.1+ | 0x4D0B..0x4DFF | R223.M4.1+ | reserved |
| lambda_lit       | 0x2C00..0x2C04   | R224.M1   | landed |
| lambda_lit-M2+   | 0x2C05..0x2CFF   | R224.M2+  | reserved |
| closure_capture  | 0x3500..0x3505   | R224.M2   | landed |
| closure_capture-M3+ | 0x3506..0x35FF | R224.M3+ | reserved |
| effect_row       | 0x4000..0x4007   | R224.M3   | landed |
| effect_row-M3.1+ | 0x4008..0x40FF   | R224.M3.1+ | reserved |
| cap_row          | 0x4300..0x4309   | R224.M4   | landed |
| cap_row-M4.1+    | 0x430A..0x43FF   | R224.M4.1+ | reserved |
| let_scope        | 0x4600..0x4604   | R224.M5   | landed |
| let_scope-M5.1+  | 0x4605..0x46FF   | R224.M5.1+ | reserved |
| hm_core          | 0x2D00..0x2D03   | R225.M1   | landed |
| hm_core-M3+      | 0x2D04..0x2DFF   | R225.M3+  | reserved |
| row_types        | 0x3600..0x3606   | R225.M2   | landed |
| row_types-M3+    | 0x3607..0x36FF   | R225.M3+  | reserved |
| effect_unify     | 0x4900..0x4907   | R225.M4   | landed |
| effect_unify-M4.1+ | 0x4908..0x49FF | R225.M4.1+ | reserved |
| datalog          | 0x2E00..0x2E04   | R226.M1   | landed |
| datalog-M2+      | 0x2E05..0x2EFF   | R226.M2+  | reserved |
| session_env      | 0x3700..0x3704   | R229.M2   | landed |
| session_env-M3+  | 0x3705..0x37FF   | R229.M3+  | reserved |
| type_env         | 0x3D00..0x3D08   | R229.M3   | landed |
| type_env-M4+     | 0x3D09..0x3DFF   | R229.M4+  | reserved |
| job_control      | 0x4E00..0x4E06   | R229.M4   | landed |
| job_control-M4.1+ | 0x4E07..0x4EFF  | R229.M4.1+ | reserved |
| history          | 0x5100..0x5105   | R229.M5   | landed |
| history-M5.1+    | 0x5106..0x51FF   | R229.M5.1+ | reserved |
| line_editor      | 0x5400..0x5406   | R229.M6   | landed |
| line_editor-M6.1+ | 0x5407..0x54FF  | R229.M6.1+ | reserved |
| hostname_annot   | 0x5300..0x5305   | R223.M6   | landed |
| hostname_annot-M6.1+ | 0x5306..0x53FF | R223.M6.1+ | reserved |
| wire_sink        | 0x5200..0x5207   | R223.M5   | landed |
| wire_sink-M5.1+  | 0x5208..0x52FF   | R223.M5.1+ | reserved |
| vi_mode          | 0x5700..0x5704   | R229.M7   | landed |
| vi_mode-M7.1+    | 0x5705..0x57FF   | R229.M7.1+ | reserved |

Codes live in the parser-tier packed-status range (0x2700..0x2EFF
slice). Disjoint from every user-space `0xFFFFExxx` error band in
the paideia-os tree (see `caps.decl` for the full disjointness
proof).
