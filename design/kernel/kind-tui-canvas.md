# KIND_TUI_CANVAS

Ordinal `0x1A6`. Capability-gated, memory-backed double-buffered cell
grid with kernel-side damage diffing, sitting on top of `KIND_TTY`.
Rendering substrate for postui (`paideia-os/postui`) and any future
TUI application that needs frame-based redraws with sub-frame
correctness.

## Derivation

Over `KIND_MEMORY` (= `KIND_PAGE`, 4), following the precedent set by
`kind_gpu_bo.pdx` (`0x174`) and `kind_display_plane.pdx` (`0x173`):
the kernel never trusts a ring-3 canvas blob directly; it trusts the
`KIND_MEMORY` holder that had authority over those bytes. A canvas
additionally names — and validates at mint — a `tty_slot` referencing
a live `KIND_TTY` row (`tty_tail_valid`), so a canvas is always
provably wired to a real TTY sink; a memory revocation OR a TTY
revocation cascades into the canvas becoming unusable.

Contrast with `KIND_TTY` (derives over `KIND_IPC_ENDPOINT`): a TTY sink
is a conversation with a server, while a canvas is a buffer with a
rendering target — same distinction `kind_gpu_bo` (memory-derived)
draws against `kind_display_output`/`kind_display_mode`
(server-conversation-shaped) elsewhere in the tree.

## Row layout (64 bytes, one cache line)

Mirrors `kind_tty`'s six-word discipline; eight words here.

| Off | Field         | Semantics |
|-----|---------------|-----------|
| +0  | header        | `in_use[63:56] \| reserved[55:0]` |
| +8  | canvas_id     | u64, server-assigned; refused == 0 at mint |
| +16 | memory_slot   | u64, the `KIND_MEMORY(4)` slot backing the cell grid |
| +24 | tty_slot      | u64, the `KIND_TTY` row this canvas emits ANSI into |
| +32 | rows \| cols  | `rows[63:32] \| cols[31:0]` (both ≤ `TUI_DIM_MAX = 4096`, same ceiling `TTY_ROWS_MAX`/`TTY_COLS_MAX` already use) |
| +40 | cell_bytes    | u64, = `16` (`CELL_BYTES`); recorded so a future cell-format revision can version-check existing rows |
| +48 | presents      | u64, running `PRESENT`-op count (kernel-side stat) |
| +56 | reserved      | u64, flags (mode bits reserved for future use) |

## Backing buffer layout

Inside the `memory_slot`'s byte range, sized `2 * rows * cols *
CELL_BYTES` and mapped writable into the client's address space at mint:

```
[0, N)     back buffer  — client-writable scratch; every widget's draw()
                          writes here every frame
[N, 2N)    front buffer — kernel-owned "last emitted" snapshot; the
                          client never writes here directly
```

where `N = rows * cols * 16`. A 240x67 terminal gives `N = 257,280`
bytes; two such regions ~500 KiB per canvas — trivially page-mappable
and nowhere near the `KIND_MEMORY` allocator's practical ceiling.

## Cell wire format (16 bytes, `CELL_BYTES`)

| Off | Field    | Type     | Semantics |
|-----|----------|----------|-----------|
| +0  | symbol   | [4]u8    | up to 4 UTF-8 bytes (one grapheme under the v1 width-table model); zero-padded if shorter |
| +4  | fg       | [3]u8    | 24-bit truecolor (r, g, b) |
| +7  | bg       | [3]u8    | 24-bit truecolor (r, g, b) |
| +10 | mods     | u8       | bitflags: BOLD\|ITALIC\|UNDERLINE\|DIM\|CROSSED_OUT\|SLOW_BLINK\|RAPID_BLINK\|REVERSED |
| +11 | reserved | [5]u8    | zero; future use (9th modifier, hyperlink id) |

No 16-color or 256-palette tier stored or emitted — 24-bit truecolor
only, per the frozen postui design constraint.

## Rights

Mirrors `R_TTY_*` bit-assignment style.

| Bit    | Name           | Purpose |
|--------|----------------|---------|
| 0x002  | R_TUI_PRESENT  | diff + emit a frame (the "write" analogue) |
| 0x008  | R_TUI_INVOKE   | query ops (rows, cols, id, tty_id) |
| 0x010  | R_TUI_RESIZE   | `TUI_OP_RESIZE` / `TUI_OP_CLEAR` |
| 0x020  | R_TUI_REVOKE   | teardown the row |
| 0x200  | R_TUI_MINT     | derive a narrower child (reserved; no v1 caller) |
| 0x400  | R_TUI_OBSERVE  | debug printer |
| 0x63A  | R_TUI_ALL      | union of all defined rights |

## Ops

Signature `cap_handler_tui_canvas(rights, target_ptr, op_arg) -> u64`
— same three-`u64` dispatch shape as `cap_handler_tty`.

| Ord | Op                    | Rights          | Behavior |
|-----|-----------------------|-----------------|----------|
| 0   | TUI_OP_PRESENT        | R_TUI_PRESENT   | Scan back vs. front buffer; per dirty row compute `(min_col, max_col)`; for each dirty run, emit `CSI row;col H` + one SGR sequence per fg/bg/mods change + the run's UTF-8 symbol bytes via `TTY_OP_WRITE` on the row's `tty_slot`; copy back→front for the rows just emitted; bump `presents` |
| 1   | TUI_OP_QUERY_ROWS     | R_TUI_INVOKE    | Returns `rows` |
| 2   | TUI_OP_QUERY_COLS     | R_TUI_INVOKE    | Returns `cols` |
| 3   | TUI_OP_QUERY_ID       | R_TUI_INVOKE    | Returns `canvas_id` |
| 4   | TUI_OP_QUERY_TTY_ID   | R_TUI_INVOKE    | Returns underlying `tty_id` via `tty_row_id(tty_slot)` |
| 5   | TUI_OP_RESIZE         | R_TUI_RESIZE    | Re-derive `rows`/`cols` on a terminal-resize event; re-maps the backing region (fresh mint under the hood, old row revoked) |
| 6   | TUI_OP_CLEAR          | R_TUI_RESIZE    | Mark every cell in front buffer as a blank sentinel, forcing the next `PRESENT` to be a full repaint (used after `RESIZE` and on first frame) |
| 7   | TUI_OP_DEBUG_PRINT    | R_TUI_OBSERVE   | Debug hook, no side effect beyond the existing `TTY_OP_DEBUG_PRINT` pattern |

## Failure taxonomy

A new disjoint 16-wide band, `0xFFFFEC40..0xFFFFEC4F` — the next free
band after `KIND_TTY`'s `0xFFFFEC30..0xFFFFEC3F`, with the same
named-constant discipline.

| Sentinel                | Meaning |
|-------------------------|---------|
| `TUI_MINT_BAD_MEMORY`   | `memory_slot` not a live `KIND_MEMORY(4)` |
| `TUI_MINT_BAD_TTY`      | `tty_slot` not a live `KIND_TTY` (tail_valid check failed) |
| `TUI_MINT_BAD_DIMS`     | rows or cols == 0 or > `TUI_DIM_MAX = 4096` |
| `TUI_MINT_BAD_SIZE`     | `memory_slot`'s byte range < `2 * rows * cols * CELL_BYTES` |
| `TUI_BAD_SLOT`          | invoke on a non-live row |
| `TUI_BAD_RIGHTS`        | rights row doesn't hold the op's required bit |
| `TUI_TAIL_ENOSPC`       | tty-side backpressure during PRESENT emit |
| `TUI_REVOKE_ALREADY`    | double-revoke |

## Why `cap_invoke` is control-plane-only, not per-cell

The `(rights, target_ptr, op_arg)` triple `cap_handler_tty` and
`cap_handler_tui_canvas` share cannot carry a cell write's payload (16
bytes of cell data + a row/col address) in one call, and even if it
could, a full-screen redraw is thousands of cells — thousands of
syscalls per frame is not a tolerable per-frame cost.

Following the `kind_gpu_bo`/`kind_display_plane` precedent exactly:
the cell payload lives in a **directly memory-mapped** region named
by the `KIND_MEMORY` parent; `cap_invoke` is reserved for the handful
of *control* transitions (PRESENT, RESIZE, CLEAR, query, revoke) that
must be capability-checked. This is both the security-correct shape
(matches every other buffer-backed cap in the tree) and the only one
fast enough for 60 Hz-class redraw rates.

## Implementation files (per R89.M1 milestone)

- `src/kernel/core/cap/kind_tui_canvas.pdx` (R89.M1-001) — row + mint
- `src/kernel/core/cap/cap_handler_tui_canvas.pdx` (R89.M1-002) — dispatch
- `src/kernel/core/tui/canvas_present.pdx` (R89.M1-003) — cell diff + ANSI emit
- `src/kernel/core/tui/canvas_damage.pdx` (R89.M1-004) — damage bookkeeping
- `src/kernel/boot/witness/r89_tui_canvas.pdx` (R89.M1-005) — mint + Block draw + PRESENT smoke

## Fingerprint golden

Per the standard runtime-string convention (plain English, `[legacy:
UPPERCASE]` suffix where a boot smoke observes it):

```
tui canvas mint ok    [legacy: TUI CANVAS MINT OK]
tui canvas present ok [legacy: TUI CANVAS PRESENT OK]
tui canvas resize ok  [legacy: TUI CANVAS RESIZE OK]
tui canvas revoke ok  [legacy: TUI CANVAS REVOKE OK]
```

## Cross-refs

- Postui-side design authority: `paideia-os/postui` `docs/design.md`
  §2.1.
- `src/kernel/core/cap/kind_tty.pdx` — precedent header commentary
  depth; row-layout discipline; op-table shape.
- `src/kernel/core/cap/kind_gpu_bo.pdx` — precedent for memory-derived
  buffer caps.
- `src/kernel/core/cap/kind_display_plane.pdx` — precedent for
  ordinal-adjacent memory-derived caps.
