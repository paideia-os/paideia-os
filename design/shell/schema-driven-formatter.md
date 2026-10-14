# Schema-driven formatter — design

**Umbrella:** paideia-os R129 ("render: Kitty + fallback pipeline").
**Milestone:** R129.M4 (paideia-os#2607, Wave UMB-W18).
**Status:** landed 2026-10-14.
**Module:** `src/kernel/core/term/schema_fmt.pdx`.

## 1. Position in the terminal substrate

```
          +-----------------------+     +-------------------------+
          | R129.M1   XTGETTCAP   |     | R129.M2  Kitty graphics |
          |  capability probe     |     |  APC-G bitmap emitter   |
          +-----------+-----------+     +------------+------------+
                      |                              |
                      | caps hint (ASCII? colour?)   | wire path for
                      |                              | SF_TYPE_IMAGE
                      v                              | (future)
          +-----------------------+                  |
          | R129.M3  ANSI-256     |                  |
          |  tabular renderer     |                  |
          +-----------+-----------+                  |
                      ^                              |
                      | ___________________________  |
                      ||                           | |
          +-----------------------+                | |
          | R129.M4  schema       |                | |
          |  dispatcher (this)    +----------------+ |
          +-----------+-----------+                  |
                      ^                              |
                      |                              |
          +-----------+-----------+                  |
          | R135.M4  typed-record |                  |
          |  stream (natural      |------------------+
          |  consumer)            |
          +-----------------------+
```

R129.M4 is **not** a renderer. It is a dispatch layer that:

1. Reads a typed-record stream (R135.M4) and a schema describing each
   record's columnar interpretation.
2. Formats each cell into the packed byte-grid M3 consumes.
3. Hands the grid to `_ansi256_table_render` for the actual TX work.
4. Propagates M3's return code unchanged (`AT_OK` / `AT_ERR_*` in the
   `0x18xx` band, distinct from M4's own `0x19xx` band).

A future wave adds `SF_TYPE_IMAGE` (type-id 7), which skips the M3 cell
path entirely and routes to `_kitty_image_rgba` (R129.M2) for bitmap
columns. The dispatcher ladder leaves a comment at type 7 for that
landing; the two-line addition is a Kitty-graphics capability probe
plus the `_kitty_image_rgba` call.

## 2. Public API

```
_schema_fmt_render(tty_fd, schema_ptr, records_ptr, record_count, flags)
                    -> errno
```

| Argument       | Register | Semantics                                     |
|----------------|----------|-----------------------------------------------|
| `tty_fd`       | rdi      | Forwarded identity (M3 bypasses to uart_putc) |
| `schema_ptr`   | rsi      | Pointer to 32B-per-field descriptor table     |
| `records_ptr`  | rdx      | Pointer to packed typed-record byte block     |
| `record_count` | rcx      | 0..SF_MAX_RECORDS (128)                       |
| `flags`        | r8       | `AT_FLAG_*` bit-mask forwarded verbatim to M3 |
| return         | rax      | `SF_OK` / `SF_ERR_*` / propagated `AT_ERR_*`  |

Return bands:

- `0`           — `SF_OK` (both M4 and M3 success)
- `0x1800..`    — `AT_ERR_*` propagated from M3 (M3's TOO_MANY_COLS,
                  TOO_MANY_ROWS, BAD_DESC)
- `0x1900`      — `SF_ERR_SCHEMA_TOO_WIDE` (width 0 or > 32 for some
                  field)
- `0x1901`      — `SF_ERR_UNKNOWN_TYPE` (field type outside 1..6)
- `0x1902`      — `SF_ERR_BAD_RECORD` (field_count == 0 or
                  record_count > 128)

The band separation lets a diagnostic shell lift the whole range
`0x1800..0x19FF` without disambiguating which layer failed.

## 3. Schema descriptor layout

Each field is 32 bytes. Up to 32 fields; the schema ends at the first
field with `field_type == 0` (SF_TYPE_END) or at slot 32.

| Offset | Size | Field          | Notes                                   |
|-------:|-----:|----------------|-----------------------------------------|
|      0 |    6 | `name_ptr`     | low-48-bit pointer to the header text   |
|      6 |    2 | `name_len`     | u16 header length                       |
|      8 |    1 | `field_type`   | 0 = END; 1..6 = SF_TYPE_*; 7 reserved   |
|      9 |    1 | `align`        | AT_ALIGN_LEFT (0) / RIGHT (1) / CENTER (2) |
|     10 |    2 | `width`        | u16 cell width in bytes, 1..32          |
|     12 |    2 | `color_hint`   | reserved for M5 per-column SGR          |
|     14 |    2 | `pad`          | zero at caller                          |
|     16 |    8 | `reserved[8]`  | reserved for M5+                        |
|     24 |    8 | `pad[8]`       | zero at caller                          |

The 32-byte stride matches natural cache-line thirds and leaves clean
room for an M5 bump that may introduce `fg_color: u8`, `bg_color: u8`
and `trunc_glyph: u16` in the reserved region without rebuilding the
descriptor from scratch.

The first 8 bytes (`name_ptr | name_len << 48`) **exactly match** M3's
own column-descriptor row-0 shape, so `_sf_build_col_desc` is a direct
8-byte copy for that half.

## 4. Record stream layout

Records are a flat byte block, `record_count` records, each of
`rec_stride` bytes. `rec_stride` is the sum of per-type in-record
sizes:

| Field type       | In-record bytes | Encoding                              |
|------------------|----------------:|---------------------------------------|
| SF_TYPE_U64      |               8 | native u64                            |
| SF_TYPE_I64      |               8 | native i64 (two's complement)         |
| SF_TYPE_STR      |               8 | low-48-bit ptr | hi-16-bit length    |
| SF_TYPE_HEX      |               8 | native u64 (printed as hex)           |
| SF_TYPE_HASH32   |              32 | 32 raw bytes (printed as hex, inline) |
| SF_TYPE_TSC      |               8 | TSC ticks (converted via `_tsc_hz`)   |

`SF_TYPE_STR`'s packed `{ptr | len}` representation deliberately
mirrors the pointer-tagged shape M3 uses for header-text pointers,
which lets a producer share one `{ptr48, len16}` builder across header
and body cells.

`SF_TYPE_HASH32`'s raw-byte inline layout keeps the stride predictable
and avoids an indirection; a shell that owns short hashes (16-byte
truncated SHA-256, 12-byte CRC) still ships them as a 32-byte block
zero-padded on the right.

## 5. Dispatch table

Each cell dispatches as follows. The destination is always a
`width`-byte slice of M3's row scratch; `_sf_space_pad` fills any
remainder with 0x20 so M3 reads exactly `width` bytes per cell.

| Type            | Helper              | Output example (width ≥ natural) |
|-----------------|---------------------|----------------------------------|
| SF_TYPE_U64     | `_sf_itoa_u64`      | `18446744073709551615`           |
| SF_TYPE_I64     | `_sf_itoa_i64`      | `-9223372036854775808`           |
| SF_TYPE_STR     | inline byte copy    | `the string, truncated at width` |
| SF_TYPE_HEX     | `_sf_itoa_hex`      | `0xdeadbeefcafef00d` (18 chars)  |
| SF_TYPE_HASH32  | `_sf_itoa_hash32`   | `9fcf...` (up to 64 chars)       |
| SF_TYPE_TSC     | `_sf_fmt_tsc`       | `12345.678 ms` or `<ticks> t`    |

Over-wide output is truncated from the right by every formatter. The
caller sizes columns conservatively; a hash truncated to 16 chars
still shows the first 8 bytes of the hash, enough for a human-eyeball
match. A TSC cell narrower than `0.000 ms` (8 chars) silently drops
the trailing unit.

### 5.1 TSC conversion

```
us = ticks * 1_000_000 / _tsc_hz
ms_int  = us / 1000
ms_frac = us % 1000
output  = "<ms_int>.<frac3> ms"
```

The 64-bit truncated `imul rax, rcx` with `rcx = 1_000_000` is safe
for ticks up to `2^63 / 10^6` ~ 9.2e12, i.e. ~3000 seconds at a 3 GHz
TSC. No shell table legitimately prints a tick count beyond that
window; a future auto-chunking path would belong at R21.

The pre-calibration path (`_tsc_hz == 0`) emits `<ticks> t` so that a
boot-time shell listing still reports measurement data in raw tick
units. Downstream dashboards normalise once calibration completes.

### 5.2 Reserved type 7 — `SF_TYPE_IMAGE`

Pre-wired dispatcher position; current wave returns len 0 (falls
through to the defensive-zero branch). The future landing shape:

```
sfd_image:
  mov rdi, [rbp + 0]       ; image RGBA ptr (u48 | hi16 unused)
  mov rsi, [rbp + 8]       ; width / height packed
  // Capability probe: _kitty_graphics_available(tty_fd)
  // If positive: _kitty_image_rgba(ptr, w, h, flags)
  //              then write a single-space placeholder cell for M3
  //              (so the grid alignment stays sane).
  // If negative: write "[WxH]" string into the M3 cell.
```

The two-line addition does not disturb the M4 wire ABI or the row-
scratch sizing (an image column occupies a `width`-byte M3 cell like
any other field).

## 6. Memory sizing

| Buffer               | Size (bytes) | Purpose                             |
|----------------------|-------------:|-------------------------------------|
| `_sf_col_desc`       |          512 | M3 column descriptor table (32×16)  |
| `_sf_row_scratch`    |      131 072 | Packed row grid (128×32×32)         |
| `_sf_itoa_scratch`   |           32 | Shared itoa reversal buffer         |

Total .bss: ~128 KiB. Comparable to other kernel-scale buffers in
`src/kernel/core/` (see `grep -r "uninit @align"`). The worst-case
grid is capped by `AT_MAX_ROWS × AT_MAX_COLS × SF_MAX_CELL_WIDTH`;
typical shell use (`jobs`, `ls`, metrics) stays under 1 KiB of the
scratch.

## 7. Interaction with R135.M4 typed-record stream

R135.M4 (paideia-os#2629) lands the shell-side typed-record producer.
Its wire format is **exactly** the record stream M4 consumes:

- Each record is a flat byte block of `rec_stride` bytes.
- Per-field in-record widths follow Section 4's table.
- Strings are packed as `{ptr48 | len16}` into 8 bytes; the pointer
  lives in a per-session capability-protected string arena.

This means a shell plugin that produces typed records can ship them
directly to `_schema_fmt_render` with its matching schema; no
conversion pass is needed. The producer typically:

```
// Allocate a scratch block of record_count * rec_stride bytes.
// For each record:
//   For each field:
//     Write field's in-record bytes at the running offset.
// Call _schema_fmt_render(tty_fd, &schema, &records, record_count, flags).
```

The symmetric contract keeps schema evolution tractable: adding a
field appends 32 bytes to the schema and extends the record stride
by the new field's in-record size. Older consumers that ignore the
new field continue to work on the prefix.

## 8. Interaction with R129.M3

M4 **always** calls `_ansi256_table_render`. There is no bypass or
alternate renderer at this wave. The flags M4 forwards to M3:

- `AT_FLAG_ASCII` — M3's UTF-8 / ASCII box-glyph choice.
- `AT_FLAG_NO_COLOR` — M3 suppresses all SGR.
- `AT_FLAG_ALT_ROWS` — M3 shades alternating data rows.
- `AT_FLAG_NO_HEADER_BG` — M3 omits header background highlight.

M4 adds no flags of its own at this wave. A future `SF_FLAG_` namespace
will land alongside `SF_TYPE_IMAGE` for behaviour unique to the
dispatcher (uppercase hex, trailing-ellipsis truncation, per-column
colour from `color_hint`).

M3's descriptor shape is honoured byte-for-byte: `_sf_build_col_desc`
emits exactly the same 16-byte-per-column format M3 reads directly.
This means an M3 unit test can be fed an M4-built descriptor as input
without any adapter.

## 9. Interaction with R129.M2 Kitty graphics (future)

The intended path for `SF_TYPE_IMAGE`:

1. Caller writes a schema field with `field_type = SF_TYPE_IMAGE`, a
   `width` in cell columns, and a record containing
   `{rgba_ptr, w_px, h_px}`.
2. M4 probes `_kitty_graphics_available(tty_fd)`.
3. On a positive probe: M4 writes a `width`-wide ASCII space cell into
   the M3 grid (so the surrounding box glyphs still align), then after
   M3 renders the row (or before — the APC-G stream is cursor-neutral
   under Kitty's semantics) emits `_kitty_image_rgba` targeting the
   same row offset.
4. On a negative probe: M4 writes `[WxH]` ASCII into the cell.

This split lets a Kitty-capable terminal show real images inline while
preserving a well-formed layout on anything else.

## 10. Encoder-pitfall discipline

Standard set from `~/.claude/.../memory/MEMORY.md` → `pdx encoder
pitfalls`:

- No `test rN, rN` — all zero tests use `cmp rN, 0; j{e,ne}`.
- No 2-op `imul rN, imm`. All multiplications use reg-reg `imul rN, rN`
  (M3's `_ansi256_table_render` justification cites `imul rax, r15` as
  proven; M4 uses the same shape with r13 / r14 as the multipliers).
- No `and rN, imm64`. All masks are imm8 (`0xFF`, `0xF`, `0x0F`) or
  imm32 (`0xFFFF`).
- Signed compares (`jl`, `jge`) avoided — the sign test in
  `_sf_itoa_i64` uses the bit-63 unsigned shift trick instead.
- `neg rN` avoided — negation in `_sf_itoa_i64` is `xor rax, rax; sub
  rax, r12; mov r12, rax`.
- Module basename `SchemaFmt` matches file basename `schema_fmt.pdx`.
- Reserved-label prefixes: `sfu_` (u64), `sfi_` (i64), `sfh_` (hex),
  `sfhh_` (hash32), `sft_` (tsc), `sfp_` (pad), `sfd_` (dispatcher),
  `sfbc_` (build col desc), `sfr_` (render). None collide with M3's
  `at*_` family, M2's `kg_` family, or M1's `xt_` family.
- All large immediates loaded into registers before use (e.g.
  `mov rcx, 1_000_000; imul rax, rcx`).

## 11. Stack discipline

All functions use the SysV x86_64 convention: entry `rsp%16 == 8`, so
after a 2n-byte push block the state alternates and nested calls
require a per-call `sub rsp, 8` only when the running push count is
even.

| Function              | Pushes | Scratch | Steady `rsp%16` | Per-call pad |
|-----------------------|-------:|--------:|-----------------|--------------|
| `_sf_space_pad`       |      0 |       0 | 8               | — (leaf)     |
| `_sf_itoa_u64`        |      6 |       0 | 8               | — (leaf)     |
| `_sf_itoa_i64`        |      3 |       0 | 0               | none         |
| `_sf_itoa_hex`        |      6 |       0 | 8               | — (leaf)     |
| `_sf_itoa_hash32`     |      5 |       0 | 0               | — (leaf)     |
| `_sf_fmt_tsc`         |      6 |       8 | 0               | none         |
| `_sf_fmt_cell`        |      5 |       0 | 0               | none         |
| `_sf_build_col_desc`  |      3 |       0 | 0               | — (leaf)     |
| `_schema_fmt_render`  |      6 |      56 | 0               | none         |

Each entry carries a `justification` paragraph in the `.pdx` reciting
this calculation. The row-scratch slot in `_sf_fmt_tsc` holds the
`ms_frac` remainder across the nested `_sf_itoa_u64` call that would
otherwise clobber `rdx`.

## 12. Call-graph

```
_schema_fmt_render
   |
   +-- _sf_build_col_desc           (once; descriptor marshaling)
   |
   +-- loop r in 0..record_count:
   |     loop f in 0..field_count:
   |       _sf_fmt_cell(type, src, dst, width, flags)
   |          |
   |          +-- _sf_itoa_u64      (U64, HEX fallback, TSC fallback)
   |          +-- _sf_itoa_i64 --> _sf_itoa_u64
   |          +-- _sf_itoa_hex
   |          +-- _sf_itoa_hash32
   |          +-- _sf_fmt_tsc --> _sf_itoa_u64
   |          (STR path inlined)
   |       _sf_space_pad(dst, len, width)
   |
   +-- _ansi256_table_render        (M3 wire path)
          |
          +-- _at_emit_border, _at_emit_header_row, _at_emit_data_row,
              _at_tx_byte, _at_tx_u64_dec, _at_tx_box, _at_tx_set_color,
              _at_tx_reset, _at_emit_cell, _at_tx_pad
                 |
                 +-- uart_putc
```

M4 never calls `uart_putc` directly; M3 remains the sole TX funnel for
the ANSI-256 tabular wire. This preserves M3's "every byte funnels
through uart_putc" invariant unchanged.

## 13. Caller recipe

A shell producer plugs in as follows:

```
// 1. Build / own a schema (statically or on the stack).
//    One SF_FIELD_DESC_BYTES slot per field; terminate with SF_TYPE_END
//    or fill all 32 slots.
schema[0] = { name_ptr: "PID",     name_len: 3,  field_type: 1 /*U64*/,
              align: 1 /*RIGHT*/,  width: 5,     color_hint: 0, ... }
schema[1] = { name_ptr: "COMMAND", name_len: 7,  field_type: 3 /*STR*/,
              align: 0 /*LEFT*/,   width: 24,    color_hint: 0, ... }
schema[2] = { name_ptr: "WALL",    name_len: 4,  field_type: 6 /*TSC*/,
              align: 1 /*RIGHT*/,  width: 14,    color_hint: 0, ... }
schema[3] = { field_type: 0 /*END*/, ... }

// 2. Marshal records as a tight byte block.
//    pid (u64) + { cmd_ptr48 | cmd_len16 } (u64) + ticks (u64) per row.
//    rec_stride = 8 + 8 + 8 = 24 bytes/record.

// 3. Call.
err = _schema_fmt_render(tty_fd, &schema, &records, record_count, flags)

// 4. On err != 0, log and fall back to a plain-ASCII dump.
```

The producer never calls into M3 directly, which keeps the M3 contract
(fixed-width packed grid, up to 128 rows × 32 cols) encapsulated behind
the schema abstraction.

## 14. Follow-on work

- R129.M5 — per-column SGR via `color_hint` (needs M3 to grow a per-
  column fg/bg emit path, which M3's descriptor already reserves for
  under the `fg_color` / `bg_color` bytes).
- R129.M6 — `SF_TYPE_IMAGE` dispatch via M2's `_kitty_image_rgba`.
- R129.M7 — ellipsis truncation glyph (`SF_FLAG_ELLIPSIS` forwarded
  into formatter per-call).
- R129.M8 — streaming / incremental emit for long result sets (lifts
  the 128-row cap by chunking the record stream across multiple M3
  calls that share one open border frame).
- R129.M9 — proportional / auto-fit widths; schema would carry a
  `min_width` and `max_width` instead of a single `width`.

Each follows the same schema-first discipline: the dispatcher owns
type semantics; M3 owns the box-and-cell wire; M2 owns the bitmap
wire; M1 owns the capability probe.

## 15. Tests (future)

Standing kernel-smoke pattern (see
`design/testing/compositor-test-runner.md` for the harness shape):

- A pure-fallback smoke that calls `_schema_fmt_render` with a 3-field
  schema and 4 synthetic records, asserts the resulting UART output
  against a golden hex transcript. Covers the four non-STR formatters.
- A string-cell smoke with a varying-length `SF_TYPE_STR` input to
  verify ptr48/len16 unpacking and width-based truncation.
- A hash32 smoke with a canonical 32-byte input to verify both the
  full-64-char path and a truncated (width = 16) path.
- A TSC smoke that pre-publishes a mock `_tsc_hz` and asserts the
  `<ms>.<frac3> ms` format; a sibling smoke that leaves `_tsc_hz`
  at 0 and asserts the `<ticks> t` fallback.

Tests land alongside R135.M4 (paideia-os#2629) so the typed-record
producer and consumer are exercised together.
