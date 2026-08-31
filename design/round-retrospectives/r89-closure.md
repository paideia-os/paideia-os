# R89 Retrospective: KIND_TUI_CANVAS live

**Date:** 2026-08-31
**Milestone:** R89.M1 (single-milestone round)
**Issues:** 6 landed (#1988, #1989, #1990, #1991, #1992, #1993); this
doc closes #1994.
**HEAD at closure:** paideia-os c1f4403 (in-tree, this doc is the only
change).
**Release tag:** `r89-closed` recommended — every M1 acceptance
fingerprint is emitted at every default boot; two carried-forward
items exist (see debt inventory), neither hardware-gated, neither
blocking downstream rounds.

## Round intent

Per `design/roadmap/rows-4-5-6-scoping.md` §R89 and `docs/design.md`
in the paideia-os/postui repo: land the kernel-side half of
`KIND_TUI_CANVAS` — a capability that gives a userspace terminal-UI
process a client-writable back buffer of cells, presenting a diffed
ANSI stream to a bound `KIND_TTY` sink under a per-canvas rights
gate. The scope was substrate + dispatch + present-path only; the
postui daemon (client-side widget tree, event pump, theme resolver)
is a separate round.

## Per-issue disposition

### #1988 — R89.M1-001 kind_tui_canvas.pdx substrate — LANDED
`kind_tui_canvas.pdx` (330L at first landing): ordinal `0x1A6`, 8-row
pool at 64 B/row, mint gate validating (memory_slot, tty_slot,
rows|cols, cell_bytes), rights R_TUI_* {PRESENT/RESIZE/CLEAR/INVOKE},
revoke path, failure band `0xFFFFEB10..0x1F`, `_tui_state`,
`_tui_row_pool`. Substrate landed clean at commit `166ea72`.

### #1989 — R89.M1-002 cap_handler_tui_canvas dispatch — LANDED
`cap_handler_tui_canvas.pdx` (~200L): eight-op dispatch —
PRESENT/RESIZE/CLEAR stubbed; QUERY_ROWS/COLS/ID/TTY_ID +
DEBUG_PRINT real. Wired into `cap_invoke_dispatch`. Landed at
`bef24fe`.

### #1990 — R89.M1-003 cell diff + ANSI emit path — LANDED
`src/kernel/core/tui/canvas_present.pdx` (~640L new) + PRESENT arm
now real (`cap_handler_tui_canvas.pdx`). Five functions:
`tui_present_body` (orchestrator), `tui_diff_row` (per-row back/front
min/max scan), `tui_emit_row` (cursor position + SGR-coalesced cell
emit + back→front copy), `tui_emit_dec`, `tui_emit_byte`. Back and
front buffers live inside the `memory_slot`'s KIND_MEMORY(4) byte
range (`2*rows*cols*16`), reached via `cap_table[memory_slot].
target_ptr` — no per-row layout change on the 64-byte canvas row.
CELL_WRITE is intentionally not a kernel op (clients write cells
directly into the mapped back buffer per the design doc). Landed at
`c83e0fe`. Fingerprint `tui canvas present ok -- canvas=<id>
rows_dirty=<N> bytes=<M>` via `klog_s1_d3`.

### #1991 — R89.M1-004 damage/stat bookkeeping — LANDED
`_tui_stats : [u64;8] @align(64)` mirroring `_tty_stats` byte-for-
byte, plus four leaf helpers (`tui_stats_bump_mints/revokes/
presents/refused`) and bump wiring in every counted path. Refused
convention preserved from `_tty_stats`: mint failure funnel bumps
once; revoke failures and dispatch denials do NOT bump. One-writer
confinement gate in `tools/build.sh` restricts writes to
`kind_tui_canvas.o`. Landed at `61cd83b`.

### #1992 — R89.M1-005 boot witness — LANDED (self-verifying)
`src/kernel/boot/witness/r89_tui_canvas.pdx` (335L new): mints
KIND_MEMORY + KIND_IPC_ENDPOINT parents at cap slots 122/121, mints
a 4×8 canvas over that memory + a KIND_TTY sink, writes 32 U+2588
Blocks (white-on-black RGB) directly into the back buffer, invokes
PRESENT, snapshots `tty_row_bytes` before/after and asserts
`delta == bytes_total == 152` — an exact byte count derived from
the design (24 cursor + 32 SGR coalesced + 96 UTF-8 glyphs). Revokes
canvas + scrubs both parent slots on every path (success + every
`tuiw_fail_stage` branch). Landed at `c1f4403`. Fingerprint `boot tui
canvas ok -- canvas=1 bytes=152` observed at 0.51s of every default
boot, with the real ANSI stream `\x1b[1;1H\x1b[0;38;2;255;255;255;
48;2;0;0;0m████████\x1b[2;1H████████\x1b[3;1H████████\x1b[4;1H
████████` visible on serial.

### #1993 — R89.M1-006 design doc — LANDED
`design/kernel/kind-tui-canvas.md`: kernel-side header commentary at
`kind_tty.pdx` depth. Landed at `0a69e0f`.

### #1994 — R89.M1-007 round closure retro — this document

## Cross-repo escalations

None found. `KIND_TTY`'s post-#1986 posture (TTY_OP_READ + raw/cooked
mode toggle) was already in place before R89 opened; R89 consumes
that surface without needing further paideia-as changes.

## Observable proof

Every default boot emits, in order:
1. `INFO cpu0 cap : tui canvas mint ok canvas_id=0x1` (0.509s)
2. Raw ANSI stream: `\x1b[1;1H\x1b[0;38;2;255;255;255;48;2;0;0;0m
   ████████\x1b[2;1H████████\x1b[3;1H████████\x1b[4;1H████████`
3. `INFO cpu0 cap : tui canvas present ok canvas=1 rows_dirty=4
   bytes=152` (0.510s)
4. `INFO cpu0 boot : boot tui canvas ok -- canvas=1 bytes=152`
   (0.511s)

The 152-byte total is not asserted only in a comment: the witness
kernel itself gates on `cmp delta, 152; jne <fail>` before ever
reaching the success klog call. A regression in either the diff
scan, the SGR coalescer, the byte accounting, or the KIND_MEMORY
target_ptr resolution would fail the boot rather than silently emit
the wrong count.

## Debt inventory (carried forward)

1. **SGR modifier bit-position mapping** (`canvas_present.pdx`'s
   header) — the design doc lists the eight `mods` flags in prose
   order only (BOLD, ITALIC, UNDERLINE, DIM, CROSSED_OUT, SLOW_BLINK,
   RAPID_BLINK, REVERSED) with no bit-position table. #1990 assigned
   bit0..bit7 to that prose order verbatim and mapped each to its
   standard ANSI SGR code. **Needs confirmation** against postui's
   eventual CELL_WRITE encoder before postui ships a client that
   sets these bits, or the two sides will disagree about which bit
   means BOLD. Not hardware-gated; a single doc alignment PR against
   `paideia-os/postui`'s `docs/design.md` closes it.

2. **`kind_tui_canvas_init` runs after `witness_r89_tui_canvas`**
   (`kernel_main.pdx:1021` vs `:1344`) — the pool/id-counter reset
   happens after the witness's mint. Harmless today (witness fully
   revokes its own row before returning; the reset zeroes an already-
   empty pool), but latent: if a second real canvas mints at boot
   between the witness and the reset, it would see a non-zero
   id-counter that the reset then clobbers. Fix is one line — move
   the reset up before witness dispatch — but out of scope for R89
   and unlikely to matter until R90+ userspace mints canvases at boot.

**Next round:** neither item above blocks R90. The Wave-4 rows in
`design/roadmap/rows-4-5-6-scoping.md` (R90.M1 postui daemon skeleton,
R66v2 KIND_TTY consumer alignment, R42 syscall substrate completion)
can proceed on the existing sequencing; item (1) becomes real work
only once postui ships a client that sets `mods` bits, item (2) only
once a boot-time userspace mint appears.
