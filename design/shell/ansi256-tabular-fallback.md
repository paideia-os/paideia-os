# ANSI-256 tabular fallback renderer (R129.M3)

Issue: paideia-os#2606
Wave:  UMB-W17
Lands: 2026-10-13

## 1 Why

R129 is the paideia-os umbrella for terminal-capability features.
R129.M1 (Wave UMB-W15, paideia-os#2604) landed the XTGETTCAP DCS
round-trip helper.  R129.M2 (Wave UMB-W16, paideia-os#2605) landed
the Kitty graphics APC emitter -- a wire format for the three
terminal emulators that answer the RGB cap (iTerm2, Kitty, WezTerm).

M3 covers the other half of the universe.  xterm, gnome-terminal,
foot, konsole, Windows Terminal, Mintty, early-boot EFI consoles,
and every terminal piped through `tmux`/`screen` or captured to a
serial log do NOT render inline bitmaps -- but every one of them
DOES speak ANSI-256 colour (`\e[38;5;Nm` / `\e[48;5;Nm`) and UTF-8
box-drawing (`U+2500 .. U+257F`).

M3 is the fallback a kernel-side helper reaches for when it has
tabular data (a `jobs` listing, a per-container memory map, a
semantic-query result, a syscall-tracer dump, a Perf-sink histogram)
and it either does not know the terminal is Kitty-capable or it
knows the terminal is not.  The shell command `jobs` is the
canonical first consumer: at R127.M5 (Wave UMB-W16) it already
builds a job table; M3 lets `jobs` render it legibly.

Target rendering:

```
      ┌─────┬──────────────┬──────────┐
      │ PID │ COMMAND      │  STATE   │
      ├─────┼──────────────┼──────────┤
      │ 142 │ ls -la       │ RUNNING  │
      │ 143 │ grep foo     │ WAITING  │
      │ 144 │ cat big.log  │ RUNNING  │
      └─────┴──────────────┴──────────┘
```

Degraded ASCII rendering (under `AT_FLAG_ASCII`, no UTF-8 glyphs):

```
      +-----+--------------+----------+
      | PID | COMMAND      |  STATE   |
      +-----+--------------+----------+
      | 142 | ls -la       | RUNNING  |
      | 143 | grep foo     | WAITING  |
      | 144 | cat big.log  | RUNNING  |
      +-----+--------------+----------+
```

Under `AT_FLAG_NO_COLOR`, the SGR escapes are suppressed and the
output is pure byte-safe ASCII (or UTF-8 under the default glyph
set), suitable for serial-log capture and `grep`-friendly piping.

## 2 Public API

```
  _ansi256_table_render(
      tty_fd        : u64,   // forwarded identity at M3 (uart_putc only)
      rows_ptr      : *u8,   // packed byte records; row stride = sum of widths
      row_count     : u64,   // 0..AT_MAX_ROWS = 128
      cols_desc_ptr : *Desc, // array of 16-byte column descriptors
      col_count     : u64,   // 1..AT_MAX_COLS = 32
      flags         : u64    // AT_FLAG_* bit mask
  ) -> u64  // errno
```

Return codes (banded in `0x18xx`; the band is otherwise unused):

| Value   | Symbol                  | Meaning                                    |
| ------- | ----------------------- | ------------------------------------------ |
| 0x0000  | `AT_OK`                 | emission complete                          |
| 0x1800  | `AT_ERR_TOO_MANY_COLS`  | col_count > 32                             |
| 0x1801  | `AT_ERR_TOO_MANY_ROWS`  | row_count > 128                            |
| 0x1802  | `AT_ERR_BAD_DESC`       | cols_desc_ptr == NULL or col_count == 0    |

## 3 Column descriptor

Each column descriptor is a packed 16-byte record:

```
  offset  size  field              encoding
  ------  ----  -----------------  --------------------------------------
  0       6     header_name_ptr    low 48 bits of u64 at [desc+0]
  6       2     header_len         bits 48..63 of u64 at [desc+0]
                                   (equivalently: u64 >> 48)
  8       2     width              bits 0..15 of u64 at [desc+8]
                                   (equivalently: u64 & 0xFFFF)
  10      2     align_flags        bits 16..31 of u64 at [desc+8]
  12      1     fg_color           bits 32..39 of u64 at [desc+8]
                                     (reserved -- not emitted at M3)
  13      1     bg_color           bits 40..47 of u64 at [desc+8]
                                     (reserved -- not emitted at M3)
  14      2     reserved           must be 0
```

The pointer sits in the low 48 bits of the first qword because
canonical x86-64 kernel pointers are 48-bit (bits 47..0 virtual,
bits 63..48 either sign-extended or zero in the lower half of the
address space).  Fitting it alongside the 16-bit length lets the
descriptor stay cache-friendly at 16 bytes.

Alignment selectors (`align_flags`):

| Value | Symbol             | Behaviour                                    |
| ----- | ------------------ | -------------------------------------------- |
| 0     | `AT_ALIGN_LEFT`    | data at the left edge; padding on the right  |
| 1     | `AT_ALIGN_RIGHT`   | padding on the left; data at the right edge  |
| 2     | `AT_ALIGN_CENTER`  | padding split half/half (left gets `pad/2`)  |
| >= 3  | *fallback*         | treated as left-align                        |

### 3.1 Row stride

Rows are packed back-to-back with no padding:
`row_stride = sum(col[0..col_count].width)`.
Each row's bytes are read in column order; the renderer trusts the
caller to NUL-pad or space-pad short strings and does NOT look for
NUL terminators within a cell.  Short strings do not shrink the
emitted cell: the emitter always writes `width` bytes of data (then
pads to column width for alignment).

## 4 Capability detection (interaction with R129.M1)

R129.M3 does NOT probe anything by itself.  Capability detection
is the caller's job and lives one layer above:

1. Call `_xtgettcap_probe(tty_fd, "Co", ...)` once per session.
2. Parse the response:
   * `"256"`, `"16777216"`, or any decimal >= 256 -> colour-capable
   * `"8"`, `"16"`, no response, or malformed -> suppress colour
3. Call `_xtgettcap_probe(tty_fd, "U8", ...)` once per session.
   * `"1"` -> UTF-8 safe
   * `"0"`, no response, or malformed -> ASCII fallback
4. Pack the two results into the `flags` argument:
   * `(~utf8) * AT_FLAG_ASCII | (~color256) * AT_FLAG_NO_COLOR`
5. Pass the packed flags to `_ansi256_table_render`.

For the common case where the caller does not want to pay the
~100 ms XTGETTCAP round-trip, probing can be skipped entirely:
the UTF-8 default + 256-colour default render correctly on every
mainstream modern terminal, and the two degraded modes exist
precisely for the one shot per session where capability sniffing
is cheap enough to be worth it.

### 4.1 Three-level palette ladder

The `flags` argument encodes three colour tiers:

| Flags                        | Rendering                                     |
| ---------------------------- | --------------------------------------------- |
| 0 (default)                  | UTF-8 box + ANSI-256 fg/bg (header + alt-row) |
| `AT_FLAG_ASCII`              | ASCII box + ANSI-256 fg/bg                    |
| `AT_FLAG_NO_COLOR`           | UTF-8 box, no SGR                             |
| `AT_FLAG_ASCII` + `NO_COLOR` | ASCII box, no SGR -- plain byte-safe output   |

A fourth tier -- 16-colour (ANSI `\e[3Nm` / `\e[4Nm`, N in 0..7) --
is NOT implemented at M3.  A 16-colour terminal that cannot speak
256-colour should be run under `AT_FLAG_NO_COLOR`; the information
density gain of 16 over NO_COLOR is small and the detection logic
is proportionally more work.  R129.M4+ can add it.

## 5 Box-drawing glyphs

The renderer uses eleven glyphs from the Unicode "Box Drawing"
block (`U+2500..U+257F`), each three UTF-8 bytes:

| Index | Codepoint | Glyph | Bytes          | Role                       |
| ----- | --------- | ----- | -------------- | -------------------------- |
| 0     | U+2500    | ─     | E2 94 80       | horizontal run             |
| 1     | U+2502    | │     | E2 94 82       | vertical run               |
| 2     | U+250C    | ┌     | E2 94 8C       | top-left corner            |
| 3     | U+2510    | ┐     | E2 94 90       | top-right corner           |
| 4     | U+2514    | └     | E2 94 94       | bottom-left corner         |
| 5     | U+2518    | ┘     | E2 94 98       | bottom-right corner        |
| 6     | U+252C    | ┬     | E2 94 AC       | T down (top intersection)  |
| 7     | U+2534    | ┴     | E2 94 B4       | T up (bottom intersection) |
| 8     | U+2524    | ┤     | E2 94 A4       | T left (right-side cross)  |
| 9     | U+251C    | ├     | E2 94 9C       | T right (left-side cross)  |
| 10    | U+253C    | ┼     | E2 94 BC       | 4-way intersection         |

Under `AT_FLAG_ASCII`, each glyph collapses to a single byte:
`-` for horizontal, `|` for vertical, `+` for everything else.

### 5.1 Border layout

A rendered table has three horizontal borders and `row_count`
data rows:

* **Top border**:    `TL ─...─ T_DOWN ─...─ TR \n`
* **Mid separator**: `T_RIGHT ─...─ CROSS ─...─ T_LEFT \n`
  (one of these, between the header row and the first data row)
* **Bottom border**: `BL ─...─ T_UP ─...─ BR \n`

Each inter-column stretch of `─` spans `width + 2` glyphs: the `+2`
absorbs the one-space lead and one-space trail that every data /
header cell carries.

### 5.2 Why box-drawing, not just dashes

A pure `-+` ASCII rendering is legible but visually noisy.  Modern
terminals render U+2500 at the baseline of the character cell with
no inter-cell gap, producing an unbroken rule across the row.  The
cost is three bytes per glyph instead of one; at 32 columns and 128
rows this is ~3 KiB per table render, well within the per-call
UART budget.

## 6 Colour palette

Default colours (ANSI-256):

| Name                       | Code | Rendered       | Role                        |
| -------------------------- | ---- | -------------- | --------------------------- |
| `AT_DEFAULT_HEADER_FG`     | 15   | bright white   | header text foreground      |
| `AT_DEFAULT_HEADER_BG`     | 24   | deep blue      | header row background       |
| `AT_DEFAULT_ALT_BG`        | 236  | dark grey      | alt-row background          |

Rendering sequence (header):

```
  \e[48;5;24m\e[38;5;15m  │ PID │ COMMAND │ STATE │  \e[0m \n
```

Rendering sequence (alt-row data, under `AT_FLAG_ALT_ROWS`):

```
  \e[48;5;236m  │ 143 │ grep foo │ WAITING │  \e[0m \n
```

A non-alt data row omits the leading `\e[48;5;...m` entirely and
emits only the cell bytes + box glyphs.  The trailing `\e[0m` is
emitted on every data row that opened an SGR (i.e. on alt rows)
and skipped otherwise.

Palette rationale: dark blue (`24`) is readable on both white
and black terminal backgrounds and does not clash with the three
other canonical paideia tooling colours (red / green / yellow for
error / ok / warn).  Grey (`236`) is subtle enough to be legible
on both dark and light terminal defaults without pulling focus
from the data.

### 6.1 Per-column fg/bg (reserved for M4)

The descriptor's `fg_color` and `bg_color` bytes are read but
**not acted upon** at M3.  They are reserved for an R129.M4 wave
that will per-column-colour both header and data cells, needed by
the `jobs` command once it wants to tint PID columns by state
(RUNNING = green, WAITING = yellow, STOPPED = red).

M4 will act on these fields with a simple rule: zero means "use
default / inherit", non-zero means "override to this ANSI-256
code".  Current callers passing all zeros will continue to work
unchanged.

## 7 Capacity bounds

```
  AT_MAX_COLS  = 32
  AT_MAX_ROWS  = 128
```

### 7.1 Why 32 columns

The paideia-os shell's widest realistic tabular listing is the
syscall tracer's register dump (16 GPRs x 2 columns = 32 fields
per row).  Anything wider is better served by streaming prose
output or by piping through a pager.  At 16 bytes per descriptor,
32 columns is 512 bytes of descriptor table, comfortably within
the shell's command-buffer slab.

### 7.2 Why 128 rows

128 is the single-screen pager ceiling on a 128-line display and
matches the shell-session job-table ceiling
(`SJ_MAX_JOBS` = 32 at R127.M5, with headroom for four historical
snapshots per invocation).  Larger listings should paginate at the
caller's layer; the renderer is a single-call, single-emit atom.

### 7.3 UART wall-time

At 115200 baud, 8N1 framing, the UART tops out at ~11.5 KB/s.  A
32-column x 128-row table at an average cell width of 12 chars
emits ~55 KiB on the wire (including SGR escapes), which is ~5
seconds.  The paideia-os terminal substrate is designed for sub-
10-row interactive output; larger renderings are rare and the
latency is accepted.

## 8 Alignment and padding

For a cell with `data_len <= cell_width`:

```
  LEFT   : <data><space * (width - data_len)>
  RIGHT  : <space * (width - data_len)><data>
  CENTER : <space * ((width - data_len) / 2)>
           <data>
           <space * (width - data_len - (width - data_len) / 2)>
```

For `data_len > cell_width`, the emitter hard-cuts at `cell_width`
with no truncation glyph.  A future wave can add an ellipsis
(`…` or `...`), but the hard-cut matches the C `printf("%.Ns", s)`
convention and keeps the column width promise honest.

The one-space lead and one-space trail outside the cell content
are emitted by the row-level loop (`_at_emit_header_row` and
`_at_emit_data_row`), NOT by the cell helper.  The cell helper
only aligns within the cell_width budget.

## 9 Scratch allocation

Unlike R129.M2, M3 does not need a large staging slab.  The only
`.bss` consumer is a 32-byte decimal-digit reversal scratch for the
itoa helper (`_at_dec_scratch`):

| Symbol              | Size (bytes) | Purpose                                  |
| ------------------- | -----------: | ---------------------------------------- |
| `_at_dec_scratch`   | 32           | decimal reversal for `_at_tx_u64_dec`    |

Everything else (the box-drawing lookup tables) is immutable
`.rodata` and does not consume `.bss` budget.

## 10 Supported encoder subset

The module uses only paideia-as mnemonics proven at prior landings:

```
  mov, mov_b, lea, add, sub, and, or, xor, shl, shr, imul, div,
  cmp, je, jne, jb, jbe, ja, jae, jmp, call, ret, push, pop
```

Explicitly avoided (per the recurring pdx encoder pitfall memo):

* `test rN, rN`                 -> replaced with `cmp rN, 0; j{e,ne}`
* 2-op `imul rN, imm`           -> reg-reg `imul rN, rN` only
* `and rN, imm64`               -> every mask fits in imm8 or imm32
                                   (`0x01`, `0x02`, `0x04`, `0x08`,
                                   `0xFF`, `0xFFFF`)
* multiline `pub let = "..."`   -> every declaration single-line
* `mov rN, [rip + sym]`         -> every RIP-relative load is
                                   `lea rN, [rip + sym]` followed by
                                   a `mov_b` / `mov` through rN

Module basename `Ansi256Table` matches the file name
`ansi256_table.pdx`.

### 10.1 Label discipline

Nine prefixes keep namespaces non-colliding across sibling modules
and avoid pdx-level reserved keywords (`loop`, `if`, `let`, `fn`,
`else`, `return`, `module`, `pub`, ...):

```
  atd_   _at_tx_u64_dec
  atb_   _at_tx_box
  atc_   _at_tx_set_color  (local)
  atC_   _at_tx_reset      (uppercase C to disambiguate from atc_)
  atp_   _at_tx_pad
  ate_   _at_emit_cell
  atH_   _at_emit_border   (uppercase H to disambiguate from atf_)
  atf_   _at_emit_header_row
  ati_   _at_emit_data_row
  atR_   _ansi256_table_render
```

None of these clash with pdx-level reserved keywords.

## 11 Scope boundaries

### 11.1 M3 does NOT

* dispatch on `tty_fd`.  Every byte goes through `uart_putc`;
  the parameter is accepted and ignored, parity with the
  XTGETTCAP probe (M1) and the Kitty emitter (M2).
* probe terminal capability.  Callers gate upstream (section 4).
* emit per-column fg/bg SGR.  Descriptor fields are reserved
  for M4.
* truncate with a glyph.  Over-long cells are hard-cut.
* support multi-line cells.
* paginate.  Oversized inputs return `AT_ERR_TOO_MANY_ROWS` /
  `AT_ERR_TOO_MANY_COLS`.
* flip raw mode on behalf of the caller.  The TX-only path is
  cooked-mode safe (the TTY line discipline inspects RX only).
* retry on partial-write.  `uart_putc` is a blocking polled write.
* log fingerprints.  Emission is silent on the klog.

### 11.2 Follow-up tickets

* **R129.M4** -- per-column fg/bg SGR emission from descriptor
  fields; truncation glyph.
* **R129.M5** -- 16-colour fallback palette for 8/16-colour
  terminals (one tier above `AT_FLAG_NO_COLOR`).
* **R129.M6** -- streaming / incremental build-up (append-row API,
  for a `tail -f`-like use case).
* **R129.M7** -- multi-line cell support.

## 12 Reference call example

A three-column `jobs` table with four rows:

```
  Column descriptors (48 bytes):
    [0] "PID"      len=3  width=5  align=RIGHT   fg=0 bg=0
    [1] "COMMAND"  len=7  width=14 align=LEFT    fg=0 bg=0
    [2] "STATE"    len=5  width=10 align=CENTER  fg=0 bg=0

  Rows (packed, row_stride = 5 + 14 + 10 = 29 bytes):
    row[0] = "  142" "ls -la        " " RUNNING  "
    row[1] = "  143" "grep foo      " " WAITING  "
    row[2] = "  144" "cat big.log   " " RUNNING  "
    row[3] = "  145" "sleep 10      " " STOPPED  "

  Call:
    _ansi256_table_render(
      tty_fd = 0,
      rows_ptr = rows,
      row_count = 4,
      cols_desc_ptr = cols,
      col_count = 3,
      flags = AT_FLAG_ALT_ROWS
    )
```

Wire emission (abbreviated; actual UART output is 90-ish bytes
per row at this width):

```
  ┌─────┬──────────────┬──────────┐\n
  \e[48;5;24m\e[38;5;15m
  │ PID │    COMMAND   │  STATE   │
  \e[0m\n
  ├─────┼──────────────┼──────────┤\n
  │  142│ ls -la       │ RUNNING  │\n
  \e[48;5;236m
  │  143│ grep foo     │ WAITING  │
  \e[0m\n
  │  144│ cat big.log  │ RUNNING  │\n
  \e[48;5;236m
  │  145│ sleep 10     │ STOPPED  │
  \e[0m\n
  └─────┴──────────────┴──────────┘\n
```

Returns `AT_OK` (0).

## 13 Testing

QEMU-level smoke (R129.M3 does not add a new smoke phase; it is
covered under the R129 umbrella smoke that already drives the Kitty
emitter):

1. The kernel's `jobs` command (R127.M5) builds a job table.
2. R127.M6 (future) will add a `--pretty` flag that routes the
   job table through `_ansi256_table_render` with
   `AT_FLAG_ALT_ROWS` set.
3. A smoke-level grep on the serial-log output asserts the
   presence of the `U+2500` byte pattern (`E2 94 80`) in the
   expected header-row position.

Local-only tests at M3 (`tools/run-smoke.sh`):

* unit: calling the renderer with `col_count > 32` returns
  `0x1800`.
* unit: `col_count == 0` returns `0x1802`.
* unit: `row_count > 128` returns `0x1801`.
* integration: a 3x4 table with the sample above produces a
  deterministic serial-log transcript (byte-for-byte match
  against a golden file).

## 14 Relationship to the three terminal-capability layers

```
  R129.M1 (xtgettcap.pdx)       -- cap probe (DCS round-trip)
    |
    v
  R129.M2 (kitty_graphics.pdx)  -- bitmap emit (APC envelope, RGBA)
    |                              uses M1 for RGB-cap gating
    v
  R129.M3 (ansi256_table.pdx)   -- tabular fallback (SGR + box)
                                   uses NO M1 probe directly;
                                   caller feeds flags
```

The three modules are independent emitters; they share the same
`uart_putc` sink and the same encoder-pitfall discipline, and they
each carry a 32-byte itoa scratch (`_xt_dec_scratch` was never
needed by M1; `_kg_dec_scratch` by M2; `_at_dec_scratch` by M3).
A future wave can factor the itoa helper into a shared
`src/kernel/core/term/term_fmt.pdx`; M3 keeps the shape local to
avoid cross-module coupling at this landing.
