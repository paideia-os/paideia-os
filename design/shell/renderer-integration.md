# Renderer integration (R229.M9)

Issue: paideia-os#2727
Wave:  129
Lands: 2026-10-15

## 1 Why this exists

`design/terminal/semantic-shell.md` §9 commits the PaideiaOS semantic
shell to a **three-tier rendering strategy**:

* **Kitty graphics protocol** for terminals that advertise it (iTerm2,
  Kitty, WezTerm) — inline bitmaps, structured tables with truecolor
  SGR, inline media.
* **ANSI-256 + Unicode box-drawing** for terminals that speak 256-color
  SGR but not Kitty graphics (xterm-256color, gnome-terminal, foot,
  konsole, Windows Terminal, Mintty, tmux-captured sessions, serial
  log capture).
* **ANSI-16 plain-ASCII fallback** for serial consoles and byte-safe
  pipe capture where even box-drawing codepoints are at risk.

The capability substrate is split across three M-landings in R129
(terminal-capability umbrella):

* R129.M1 (paideia-os#2604, landed): **XTGETTCAP DCS probe** — the
  kernel-side helper that asks the terminal which capabilities it
  advertises and fills a 32-byte TCAP record on kernel scratch.
* R129.M2 (paideia-os#2605, landed): **Kitty graphics APC emitter** —
  the kernel-side pixel-byte-to-APC wire-format emitter.
* R129.M3 (paideia-os#2606, landed): **ANSI-256 tabular fallback
  renderer** — the kernel-side SGR + Unicode box-drawing emitter.

R229.M9 (THIS landing, user-space, parser-tier library) is the
**dispatcher that routes bytes through those three emitters at write
time**. It owns the active capability record in `.bss` so the
semantic shell does not re-probe XTGETTCAP on every write; every
`_rd_render_*` entry point reads the installed kind byte and routes
accordingly.

Why the dispatcher lives in the parser-tier library and not in the
kernel: the shell's WRITE surface is composed over the parser-tier
record substrate (SessionEnv values; History turn summaries; typed
pipeline-stage outputs). The dispatcher sits closest to its callers;
the kernel-side emitters are opaque function-pointer slots the
dispatcher indirects through (M9.1 wire-up).

## 2 Capability record — 32 bytes

Fed to `_rd_set_capability` by the REPL at session boot. Record
stride is a power of two (32 = 1 << 5) so a future per-session multi-
cap table (one per attached TTY) can index via `shl idx, 5`.

| Offset | Width | Field           | Meaning |
| ------ | ----- | --------------- | ------- |
| 0x00   | u32   | `magic`         | 'TCAP' (0x50414354 LE) — reads as "TCAP" in a hex-dump sequential scan |
| 0x04   | u8    | `kind`          | `RD_TERM_KITTY=0`, `RD_TERM_ANSI256=1`, `RD_TERM_ANSI16=2` |
| 0x05   | u8    | `flags`         | bit 0 `TRUECOLOR`, bit 1 `ITALIC`, bit 2 `GRAPHICS` |
| 0x06   | u16   | reserved        | zero at M9 |
| 0x08   | u16   | `cols`          | terminal grid column count |
| 0x0A   | u16   | `rows`          | terminal grid row count |
| 0x0C   | u32   | reserved        | zero at M9 |
| 0x10   | u8[16]| `term_name_inline` | caller-supplied TERM env var or XTGETTCAP TN cap; zero-padded |

Magic 'TCAP' = 0x50414354 LE: byte[0]=0x54 'T', byte[1]=0x43 'C',
byte[2]=0x41 'A', byte[3]=0x50 'P'. Reads as "TCAP" in a hex-dump
sequential scan per the Wave 125 SortGroupReduce magic-reconciliation
lesson (byte-sequence readability over numeric prettiness). The
magic u32 fits in imm32 with bit 31 clear so direct `cmp reg, imm32`
is sign-extension-safe.

Why 32 bytes: enough for the kind + flags + grid dims + a short
TERM name inline, and small enough that four u64 moves copy the
whole record into `.bss`. The `term_name_inline` field is for
diagnostic / fingerprint use only; the dispatcher routes on `kind`
alone.

## 3 Column descriptor — 16 bytes

Fed to `_rd_render_table` as `cols_ref` (array of n_cols entries).

| Offset | Width | Field           | Meaning |
| ------ | ----- | --------------- | ------- |
| 0x00   | u16   | `width`         | target column width in cells (1..`RD_MAX_COL_WIDTH`=128) |
| 0x02   | u16   | `flags`         | bit 0 `RD_COL_LEFT_ALIGN` (default); bit 1 `RD_COL_RIGHT_ALIGN` |
| 0x04   | u32   | reserved        | zero at M9 |
| 0x08   | u8[8] | `name_inline`   | header text; zero-padded; rendered as the first row by M9.3 |

Column stride 16 is a power of two (`shl idx, 4` addressing; never
2-op `imul r, imm`).

## 4 Cell reference — 16 bytes

Fed to `_rd_render_table` as `rows_ref` (packed array of
n_rows * n_cols CellRef records, row-major so cell (i, j) lives at
`rows_ref + (i * n_cols + j) * 16`).

| Offset | Width | Field    | Meaning |
| ------ | ----- | -------- | ------- |
| 0x00   | u64   | `ptr`    | UTF-8 byte payload pointer; empty-cell: `ptr == 0` |
| 0x08   | u64   | `len`    | byte length (0..`RD_MAX_CELL_BYTES`=256; capped at render time) |

Stride 16 is a power of two (`shl idx, 4`). The row index multiply
uses `mul rN` (unsigned 64x64) rather than 2-op `imul r, imm` to
honour the paideia-as encoder discipline.

## 5 Public API

### 5.1 `_rd_init() -> ()`

Boot hook. Defensive scrub of the 32-byte `_rd_cap_record` + the
`_rd_ready` flag + a reserved u64 slot. `.bss` zero-init at program
load already satisfies the cold-boot semantic (`ready == 0` means
every render* returns `RD_ERR_NO_CAPABILITY`); the entry point
exists for test-time reset / chaos-restart. Pure leaf.

### 5.2 `_rd_set_capability(cap_record_ref) -> status`

```
rdi = cap_record_ref
rax = RD_OK / RD_ERR_BAD_PTR / RD_ERR_BAD_MAGIC / RD_ERR_BAD_KIND
```

Validates magic + kind, then copies 32 bytes into `_rd_cap_record`
via four u64 moves. Sets `_rd_ready = 1`. Pure leaf.

### 5.3 `_rd_render_record(record_ref, record_len, out, out_cap) -> packed_u64`

```
rdi = record_ref
rsi = record_len
rdx = out
rcx = out_cap
rax = (bytes_written << 32) | status
```

Routes one record's bytes through the active capability kind:

| kind      | envelope                                            | bytes_written |
| --------- | --------------------------------------------------- | ------------- |
| KITTY     | `\e_G;` (4 B) + record + `\e\\` (2 B)               | 6 + record_len |
| ANSI256   | `\e[38;5;255m` (11 B) + record + `\e[0m` (4 B)      | 15 + record_len |
| ANSI16    | record verbatim                                     | record_len    |

Guards: `record_ref != 0` (RD_ERR_BAD_RECORD); `record_len <=
RD_MAX_RECORD_BYTES=4096` (RD_ERR_BAD_RECORD); `out != 0`
(RD_ERR_BAD_PTR); `_rd_ready == 1` (RD_ERR_NO_CAPABILITY); `out_cap
>= needed` (RD_ERR_OUT_TOO_SMALL); `kind in {0, 1, 2}`
(RD_ERR_BAD_KIND; defensive — `_rd_set_capability` already validates
on install). Pure leaf.

### 5.4 `_rd_render_table(rows_ref, n_rows, cols_ref, n_cols, out, out_cap) -> packed_u64`

```
rdi = rows_ref
rsi = n_rows
rdx = cols_ref
rcx = n_cols
r8  = out
r9  = out_cap
rax = (bytes_written << 32) | status
```

Renders a 2D grid of UTF-8 cells with cluster-aware column
alignment via R221.M3 `_wp_cols`. Row shape:

```
| cell_0_padded | cell_1_padded | ... | cell_{n-1}_padded |\n
```

Per-cell padding:

1. CALL `_wp_cols(cell_ptr, cell_len)` → `(cell_cols << 32) | status`.
2. If `cell_ptr == 0` or `cell_len == 0`, cell_cols = 0 (no CALL).
3. pad_count = max(0, col.width − cell_cols). Overflow (cell_cols >
   col.width) emits zero padding; the full cell bytes are still
   written. M9.3 strict-mode will fault.
4. Emit cell bytes, then `pad_count` space bytes (LEFT_ALIGN default
   at M9; RIGHT_ALIGN deferred to M9.2 refinement).

Guards: `rows_ref != 0`, `cols_ref != 0`, `out != 0`
(RD_ERR_BAD_PTR); `n_cols in [1..RD_MAX_COLS=32]`
(RD_ERR_BAD_COL_COUNT); `n_rows in [0..RD_MAX_ROWS=256]`
(RD_ERR_BAD_ROW_COUNT); `_rd_ready == 1` (RD_ERR_NO_CAPABILITY);
out_cap must cover the running cursor at every emit
(RD_ERR_OUT_TOO_SMALL); `_wp_cols` must not report
WP_ERR_INVALID_UTF8 (RD_ERR_WIDTH_FAULT with partial bytes_written
preserved in high 32 bits).

Frame: 6-callee-save push (`rbx`=out_cursor, `rbp`=row_i,
`r12`=col_j, `r13`=rows_ref, `r14`=cols_ref, `r15`=out_base) + `sub
rsp, 24` for n_cols / out_cap / n_rows spill → `rsp%16==0` steady at
every nested CALL (entry `rsp%16==8`; 48 B pushes + 24 B pad = 72 B;
`(8 + 72) mod 16 = 0`).

Why not raw box-drawing at M9: Unicode line-drawing requires a
distinct per-kind branch (ANSI256 and KITTY use U+2500..257F; ANSI16
uses `+--+`); the ASCII-pipe shape isolates the capability-dispatch
+ width-pass wire-up from the box-drawing refinement so the two can
be goldened independently. The box-drawing layer lands at M9.2.

Why not raw truecolor SGR at M9: KITTY emission under M9 is the
APC-envelope wrapper around the ASCII shape; the full
`\e[38;2;r;g;bm` truecolor emission is a per-cell computation that
needs a schema-aware colour map (header row distinct from body
rows). The schema-driven layer lands at M9.3.

## 6 Status band — 0x5D00..0x5DFF

Nine slots used at R229.M9:

| Code                           | Value   | Meaning                                                       |
| ------------------------------ | ------- | ------------------------------------------------------------- |
| `RD_OK`                        | 0       | success                                                       |
| `RD_ERR_BAD_PTR`               | 0x5D00  | required pointer == 0                                         |
| `RD_ERR_OUT_TOO_SMALL`         | 0x5D01  | out_cap < bytes required for the kind's envelope + payload    |
| `RD_ERR_BAD_MAGIC`             | 0x5D02  | cap_record[+0..+4] != 'TCAP'                                  |
| `RD_ERR_BAD_KIND`              | 0x5D03  | kind byte outside {0, 1, 2}                                   |
| `RD_ERR_NO_CAPABILITY`         | 0x5D04  | render* called before set_capability or after init            |
| `RD_ERR_BAD_RECORD`            | 0x5D05  | record_ref == 0 or record_len > RD_MAX_RECORD_BYTES           |
| `RD_ERR_WIDTH_FAULT`           | 0x5D06  | `_wp_cols` returned WP_ERR_INVALID_UTF8 (partial preserved)   |
| `RD_ERR_BAD_COL_COUNT`         | 0x5D07  | n_cols outside [1..RD_MAX_COLS=32]                            |
| `RD_ERR_BAD_ROW_COUNT`         | 0x5D08  | n_rows outside [0..RD_MAX_ROWS=256]                           |

Slots `0x5D09..0x5DFF` reserved for M9.1+ follow-ups
(`RD_ERR_KERNEL_EMITTER_UNAVAILABLE` on an M9.1 wire-up when the
function-pointer slot is zero; `RD_ERR_BAD_CELL_LEN` on an M9.3
strict-mode cell-length cap; `RD_ERR_BAD_COL_WIDTH` on an M9.4
zero-width-column refusal; etc.).

### 6.1 Disjointness proof

Band `0x5D00..0x5DFF` is disjoint from the Wave 129 parallel-arm
bands `0x5B00..0x5BFF` and `0x5C00..0x5CFF` (held reservations for
future parallel landings), and from every other parser-tier packed-
status band:

```
0x27xx utf8_nfc          0x28xx (reserved)          0x29xx (reserved)
0x2Axx schemas_sig       0x2Bxx pipeline            0x2Cxx lambda_lit
0x2Dxx hm_core           0x2Exx datalog             0x33xx command_sig
0x34xx record_projection 0x35xx closure_capture     0x36xx row_types
0x37xx session_env       0x38xx grapheme_iter       0x39xx functor_instance
0x3Cxx arg_flag_spec     0x3Dxx type_env            0x3Exx effect_row
0x3Fxx width_pass        0x42xx ctx_lexer           0x43xx cap_row
0x44xx ast               0x45xx cmd_registry        0x46xx let_scope
0x47xx span_map          0x48xx dispatch_mode       0x49xx effect_unify
0x4Axx fuzz_harness      0x4Cxx filter_op           0x4Dxx sort_group_reduce
0x4Exx job_control       0x4Fxx describe_sig        0x50xx pipeline_lambda
0x51xx history           0x52xx wire_sink           0x53xx hostname_annot
0x54xx line_editor       0x55xx session_type        0x56xx linear_propagate
0x57xx vi_mode           0x58xx rank_check          0x59xx import_resolve
0x5Axx multi_line        0x5Bxx (reserved)          0x5Cxx (reserved)
0x5Dxx renderer          (THIS)
```

A downstream compound-error dispatcher can discriminate "the
renderer faulted" from every other sibling satellite's failure modes
by a single `shr r, 8; cmp r, 0x5D` idiom.

## 7 Encoder discipline (absolute)

* No `test rN, rN` — every zero-check is `cmp reg, 0; je/jne`.
* No `and rN, imm64` — every mask is imm8 or imm32; the low-byte
  mask `and rax, 0xFF` fits imm32 with bit 31 clear (not used in
  this module).
* No 2-op `imul r, imm` — the row*n_cols multiply uses `mul rN`
  (unsigned 64x64 single-operand) which the paideia-as encoder
  encodes without the 2-op pitfall. Cell stride (16) and column
  stride (16) use `shl rN, 4`.
* No multiline `pub let = "..."` — single-line justifications.
* Module basename `Renderer` matches `renderer.pdx`.
* Labels prefixed `rd_` with per-function suffix (`rd_ini_`,
  `rd_sc_`, `rd_rr_`, `rd_rt_`). Grep-confirmed disjoint from every
  landed parser-tier label prefix (`u8n_`, `gi_`, `wp_`, `cl_`,
  `ast_`, `sm_`, `ss_` / `sch_sig_`, `cmd_sig_`, `fi_`, `afs_`,
  `cmdreg_`, `dm_`, `ds_`, `pl_`, `pl_lam_`, `rp_`, `fo_`, `sgr_`,
  `ll_`, `cc_`, `er_`, `cr_`, `ls_`, `hm_`, `rt_`, `eu_`, `dl_`,
  `se_`, `te_`, `jc_`, `fh_`, `h_`, `le_`, `ha_`, `ws_`, `lp_`,
  `vi_`, `st_`, `ml_`, `rc_`, `ir_`) AND from the paideia-as
  reserved keyword set (`loop`, `if`, `let`, `fn`, `ret`, `done`).
* All `cmp reg, imm` immediates (0, 1, 2, 3, 4, 6, 11, 15, 16, 32,
  128, 256, 4096, status codes 0x5D00..0x5D08, byte literals 0x1B
  ESC, 0x5F '_', 0x47 'G', 0x3B ';', 0x5C '\\', 0x5B '[', 0x6D 'm',
  0x30 '0', 0x32 '2', 0x33 '3', 0x35 '5', 0x38 '8', 0x7C '|', 0x20
  SP, 0x0A LF, magic 0x50414354 'TCAP', WP band 0x3F00) fit imm32
  with bit 31 clear so direct `cmp reg, imm32` is sign-safe. No
  MOVABS staging.
* Byte loads via `xor rax, rax; mov_b rax, [base + idx * 1]`.
* u16 loads via `xor rax, rax; mov_w rax, [base + idx]`.
* u32 loads via `xor rax, rax; mov_d rax, [base + idx]`.
* u64 stores via plain `mov [dst + disp], reg`.
* `.bss` writes via `lea r11, [rip + sym]; mov [r11 + disp], reg`.
  `r11` is NEVER held across a nested CALL — every `.bss` / args
  reload re-stages via `lea r11, [rip + sym]`.
* `_rd_init`, `_rd_set_capability`, and `_rd_render_record` are
  PURE LEAVES — zero callee-save pushes, zero stack frame, zero
  nested CALL.
* `_rd_render_table` has one 6-push callee-save frame + `sub rsp,
  24` pad giving `rsp%16==0` at every nested CALL. The nested CALL
  is to `_wp_cols` (R221.M3) once per cell.

## 8 Register plans

### 8.1 `_rd_init` (pure leaf)

Zero pushes. Six `.bss` stores via `lea r11, [rip + sym]`. r11 and
rax are the only registers touched; rax is zeroed via `xor rax,
rax` once at prologue.

### 8.2 `_rd_set_capability` (pure leaf)

Zero pushes. Load u32 magic from `[rdi + 0]`; cmp against
0x50414354. Load u8 kind from `[rdi + 4]`; cmp against 2. Copy
four u64 words from `[rdi]` to `[_rd_cap_record]`. Set
`[_rd_ready]` = 1. Return `RD_OK` or one of the three error codes.

### 8.3 `_rd_render_record` (pure leaf)

Zero pushes. Guards + kind-byte load. Dispatch into one of three
blocks:

* `rd_rr_kitty`: emit 4-byte prelude, byte-copy loop, 2-byte tail.
* `rd_rr_ansi256`: emit 11-byte prelude, byte-copy loop, 4-byte tail.
* `rd_rr_ansi16`: byte-copy loop only.

Byte-copy loop uses `r8` as index, `r9` as dst_base, `rdi` as
src_base. Per-byte: `xor rax, rax; mov_b rax, [rdi + r8 * 1];
mov_b [r9 + r8 * 1], rax; add r8, 1`.

### 8.4 `_rd_render_table` (6-push + 24 B spill frame)

| Reg      | Role                                      |
| -------- | ----------------------------------------- |
| `rbx`    | out_cursor (byte count written so far)    |
| `rbp`    | row_i (0..n_rows)                         |
| `r12`    | col_j (0..n_cols)                         |
| `r13`    | rows_ref (saved input)                    |
| `r14`    | cols_ref (saved input)                    |
| `r15`    | out_base (saved input; for packing return)|
| `[rsp+0]`  | n_cols                                  |
| `[rsp+8]`  | out_cap                                 |
| `[rsp+16]` | n_rows                                  |

Caller-save registers (`rax`, `rcx`, `rdx`, `rsi`, `rdi`, `r8`,
`r9`, `r10`, `r11`) are freely clobbered across the nested CALL to
`_wp_cols`. The cell_addr is recomputed post-CALL via the mul
ladder (`mov rax, rbp; mov r9, [rsp+0]; mul r9; add rax, r12; shl
rax, 4; add rax, r13`) rather than spilled, trading a cheap mul
for one less stack slot.

## 9 Acceptance

Issue brief: "Test on Kitty + xterm-256color; both render tables
correctly."

The raw M9 acceptance anchors on three test paths:

### 9.1 KITTY path

Install a cap record with `kind = RD_TERM_KITTY (0)`. Call
`_rd_render_record(record_ref, record_len, out, out_cap)` on a
40-byte record. Expect:

* `out[0..4] == {0x1B, 0x5F, 0x47, 0x3B}` (`\e_G;`)
* `out[4..44] == record[0..40]` (byte-identical copy)
* `out[44..46] == {0x1B, 0x5C}` (`\e\\`)
* `rax == (46 << 32) | RD_OK`

### 9.2 ANSI256 path

Install a cap record with `kind = RD_TERM_ANSI256 (1)`. Call
`_rd_render_record` on the same 40-byte record. Expect:

* `out[0..11] == "\e[38;5;255m"`
* `out[11..51] == record[0..40]` (byte-identical copy)
* `out[51..55] == "\e[0m"`
* `rax == (55 << 32) | RD_OK`

### 9.3 Table render path (both kinds)

Install `kind = RD_TERM_ANSI16 (2)` (so no envelope wraps the
whole table — this isolates the width-pass + padding behaviour
from the capability envelope). Call `_rd_render_table` with:

* 2 columns, widths (10, 20).
* 3 rows: {"ls", "list files"}, {"cat", "concat files"}, {"grep",
  "match patterns"}.
* `_wp_cols` is used for each cell's visible column count.

Expect the output to be byte-identical to:

```
| ls         | list files           |
| cat        | concat files         |
| grep       | match patterns       |
```

(Trailing LF per row; cells padded to col.width with ASCII spaces.)

### 9.4 Negative cases

* `_rd_render_record` before `_rd_set_capability`: returns
  `RD_ERR_NO_CAPABILITY` (0x5D04).
* `_rd_set_capability` with wrong magic: returns `RD_ERR_BAD_MAGIC`
  (0x5D02).
* `_rd_set_capability` with kind == 3: returns `RD_ERR_BAD_KIND`
  (0x5D03).
* `_rd_render_table` with `n_cols == 0`: returns
  `RD_ERR_BAD_COL_COUNT` (0x5D07).
* `_rd_render_table` with a cell whose bytes are malformed UTF-8:
  `_wp_cols` returns `WP_ERR_INVALID_UTF8`; the dispatcher packs
  the partial bytes_written in high 32 bits and returns
  `RD_ERR_WIDTH_FAULT` (0x5D06).

The 7-fixture smoke-mode golden corpus (3 OK paths × 2 kinds + 4
negative cases) lands at `smoke/renderer-m9.golden.txt` under
M9.7 along with the full smoke-mode fingerprint goldens.

## 10 Consumer pattern

The REPL writes bytes through the dispatcher at every WRITING-mode
emit. Pseudo-code sketch:

```pdx
// Session boot (once).
let cap_record_scratch : [u8; 32] = ...
_xtgettcap_probe(cap_record_scratch, 32)   // R129.M1 (kernel-side)
_rd_set_capability(&cap_record_scratch)    // THIS module

// Per-prompt render.
_rd_render_record(prompt_bytes, prompt_len, out_buf, out_cap)

// Per-table render (e.g. `jobs` output).
_rd_render_table(rows, n_rows, cols, n_cols, out_buf, out_cap)
```

The dispatcher is session-local: at raw M9 the module holds exactly
one capability. A future landing (per-TTY multi-cap) grows
`_rd_cap_record` to a 4-slot array keyed by TTY fd; `_rd_set_
capability` takes a fd argument.

## 11 Where this is NOT

* NOT a bitmap emitter. The Kitty path at raw M9 emits the APC
  envelope but hands the full pixel-byte wire-up off to the
  kernel-side R129.M2 emitter (via the M9.1 function-pointer
  slots). This module routes BYTES, not PIXELS.
* NOT a schema-aware record formatter. Choosing "an Image record
  goes KITTY-bitmap; a File record goes ANSI256-table" is M9.3;
  raw M9 takes caller-supplied bytes verbatim.
* NOT a bidi renderer. TR#9 logical-vs-visual order is M9.5.
* NOT a parser. The dispatcher reads raw UTF-8 cell bytes; it does
  NOT tokenise or normalise. Callers are expected to pass NFC-
  normalised bytes.

## 12 File footprint

* `tools/user/libpdx-pds-parser/src/renderer.pdx` — the module
  itself (one `module Renderer = structure` block with four public
  entry points + 11 pub constants).
* `tools/user/libpdx-pds-parser/caps.decl` — band + catalogue +
  linker-dep entry under the R229 wave section.
* `tools/user/libpdx-pds-parser/src/lib.pdx` — feature-ready flag
  flip (`LPX_PDS_PARSER_R229_M9_READY = 1`) + version-triple bump +
  provenance comment extension.
* `tools/user/libpdx-pds-parser/CHANGELOG.md` — per-primitive
  stanza (consolidated from `.plans/scratch/CHANGELOG-R229M9.md` at
  Wave 129 close).
* `tools/user/libpdx-pds-parser/STATUS.md` — milestone-landing
  section + error-band accounting row.
* `design/shell/renderer-integration.md` — THIS doc.

## 13 Forward path

* **M9.1** Kernel-side emitter wire-up: two weak-import function-
  pointer slots (`_rd_kitty_fn`, `_rd_ansi256_table_fn`) populated at
  session boot; `_rd_render_record` / `_rd_render_table` indirect
  through those slots for full-fidelity Kitty APC + ANSI-256 SGR
  emission. Precedent: R222.M6 DispatchMode's `_dm_light_fn` /
  `_dm_spawn_fn` slots.
* **M9.2** Unicode box-drawing refinement: the table emitter's
  ASCII-pipe shape (`| cell | cell |`) upgrades to U+2500..257F
  line-drawing under ANSI256 and KITTY (plus an `AT_FLAG_ASCII`
  toggle to force ASCII under a serial-log capture).
* **M9.3** Schema-driven formatting: the dispatcher consults the
  record's SchemasSig body to pick a rendering (an `Image` record
  routes KITTY-bitmap; a `File` record routes ANSI256-table; a
  `MetricPoint` stream routes inline time-series plot).
* **M9.4** Per-command renderer override: the `as kind` suffix from
  `semantic-shell.md` §9.3 (`find . | as table`) injects a per-stage
  renderer-kind field that overrides the schema-driven choice.
* **M9.5** TR#9 bidi integration: a logical-vs-visual order pass
  before cells reach `_wp_cols`.
* **M9.6** Column-width heuristics: `col.width == 0` triggers an
  auto-fit pass — walk every cell in the column, call `_wp_cols`,
  take the max as the auto width (capped at `RD_MAX_COL_WIDTH`).
* **M9.7** Smoke-mode fingerprint goldens for the 7-fixture
  acceptance corpus (3 OK × 2 kinds + 4 negative).

## 14 Related docs

* `design/terminal/semantic-shell.md` §9 — umbrella rendering spec.
* `design/shell/kitty-graphics-emitter.md` (R129.M2) — Kitty APC
  wire format.
* `design/shell/ansi256-tabular-fallback.md` (R129.M3) — ANSI-256
  table SGR + Unicode box-drawing.
* `design/shell/width-pass-tr11.md` (R221.M3) — the cluster-aware
  column classifier this module calls.
* `design/shell/line-editor-emacs.md` (R229.M6) — the read-side
  substrate paired with the write-side substrate THIS module
  provides.
