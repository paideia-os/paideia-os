# Changelog -- libpdx-pds-parser

All notable changes to this library are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) +
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
