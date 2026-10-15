# Changelog -- libpdx-pds-parser

All notable changes to this library are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) +
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
