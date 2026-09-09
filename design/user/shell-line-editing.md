# shell — interactive line editing (R66 M1)

**Wave:** R66 — shell polish tier 1
**Repo:** the shell satellite (`github.com/paideia-os/shell`) owns the
implementation; this document lives in the monorepo per the
`design/user/` locality convention (see `shell-io-redirection.md`,
`content-addressed-identity.md`).
**Milestone charter:** `design/roadmap/post-r60-daily-use-roadmap.md`
§R66 (lines 185–202).
**Companion kernel work:** R66v2 — `KIND_TTY` raw-mode substrate; see
§4.3 of `design/roadmap/rows-4-5-6-scoping.md` and the R66v2.POS-001
landing (paideia-os#1986, kernel commit `0e96c99`, closed 2026-08-31).
**Issues covered:** `paideia-os/shell#17` (raw-mode input path),
`paideia-os/shell#18` (backspace erase), `paideia-os/shell#19` (history
ring), `paideia-os/shell#20` (cursor-left/right), and this doc itself
at `paideia-os/shell#21` (R66.M1-005).

## 0. What this document pins

The exact shape of the shell's interactive line-editing loop after the
five R66 M1 issues land: how bytes flow through the raw-mode reader,
how ESC-sequences are classified, how the recognised key codes drive
the buffer + screen + history state, and how the whole subsystem sits
underneath the existing `Shell::shell_repl_step` REPL step without
re-plumbing it.

It is the reference doc R66.M1-001..R66.M1-004 (`#17`..`#20`) land
against. The paideia-os `#1986` (TTY_OP_READ) landing is treated as a
substrate seam — a future paideia-os issue flips
`LineReader::lr_read_one_byte`'s body from the fd-0 fallback to the
cap-typed invoke; nothing in this document changes when that flip
happens.

## 1. Scope

**In scope (R66 M1):**

- Raw-mode entry / exit around the interactive prompt (§2).
- ESC-sequence recogniser sufficient for the four arrow keys and
  backspace / DEL (§3).
- Key-code enum + dispatch table wired from the recogniser into
  the line-buffer + screen state (§4).
- Backspace erase-on-screen semantics — the `\b \b` triple — and the
  column-zero no-op (§5).
- History ring: a `[u8; 4096]` circular buffer keyed by newline, with
  up-arrow recalling the previous entry and down-arrow the next; recall
  redraws the current-line buffer in place (§6).
- In-place cursor movement: left / right arrow reposition an in-line
  cursor within the not-yet-submitted line; typed bytes at a non-end
  position insert rather than append, with a tail redraw (§7).
- The seam between the new line editor and the existing
  `Shell::shell_repl_step` per-line entry point (§8).

**Explicitly out of scope (deferred to R73 or later):**

- `^C` / `^Z` signal handling and process-group tracking. Belongs to
  R73.M1-002 (`paideia-os/shell#22`), which depends on the kernel-side
  SIGSTOP/SIGCONT floor tracked in the paideia-os monorepo.
- Tab completion — R73.M1-005 (`#25`), depends on `readdir` + `PATH`
  cache work not required for a tolerable editor.
- Word-wise motion (`M-b`, `M-f`), kill-line, reverse-i-search, and
  multi-line editing.  Every one of these can be added over the
  key-code dispatch table in §4 without changing the byte transport
  or ESC recogniser.
- History persistence to disk. `~/.history/` write-out landed at
  ENH-008 (`paideia-os/shell#35`) via `history_persist_flush`; the
  in-line editor here appends into the same in-memory ring
  `_sm_hist_buf` that flush drains, so no new persistence path is
  introduced.

## 2. Raw-mode TTY setup

### 2.1 Substrate reality (2026-09-08)

The paideia-os `KIND_TTY` (0x197) cap now exposes seven ops per
paideia-os#1986 (closed 2026-08-31, kernel commit `0e96c99`,
R66v2.POS-001):

| op ord | name                | right         | shape                     |
|--------|---------------------|---------------|---------------------------|
| 0..2   | (write / attach)    | `R_TTY_WRITE` | pre-existing              |
| 3      | `TTY_OP_SET_RAW`    | `R_TTY_CTRL`  | one-shot mode set         |
| 4      | `TTY_OP_SET_COOKED` | `R_TTY_CTRL`  | one-shot mode set         |
| 5      | (reserved)          |               |                           |
| 6      | `TTY_OP_READ`       | `R_TTY_READ`  | non-blocking poll, one byte|

`TTY_OP_READ` returns exactly one byte or `TTY_READ_EMPTY`
(`0xFFFFEC35`) on an empty ring; it never sleeps. Preserving the
shell's blocking-read contract therefore requires a busy-poll-with-
`sys_yield` around every `TTY_READ_EMPTY` return.

Two upstream pre-requisites remain before the shell satellite can flip
its transport (from the fd-0 VFS fallback to the cap-typed invoke):

1. `KIND_TTY` (`0x197`) must be added to `KIND_SEEDABLE_TABLE` in
   `src/kernel/core/cap/kind.pdx` (currently absent, L3450). Without
   this, the shell's `_init_caps` sidecar cannot self-request a
   `KIND_TTY(read)` cap.
2. `sys_yield` (SC+ ID 5) must be added to the shell's `Syscall` floor
   (`src/syscall.pdx` in the shell satellite, currently enumerates nine
   sysnos, none of which include yield). Without this, the shell has
   no way to yield-and-retry on `TTY_READ_EMPTY`.

Both are tracked as companion cross-repo issues; neither is a
prerequisite for landing #17..#20 today, because the fd-0 fallback is
already usable byte-at-a-time via `LineReader::lr_read_one_byte`
(shell.ENH-007 / `paideia-os/shell#34`).

### 2.2 The seam is unchanged by raw-mode

`LineReader::lr_read_one_byte` remains the SINGLE SEAM between the
line-editor and the byte transport (see the module header of
`src/line_reader.pdx` in the shell repo).  Raw-mode does **not**
introduce a second call site — the whole ESC-recogniser, key-code
dispatcher, backspace redraw, history recall, and cursor-motion body
sits *above* that seam and calls it once per byte. When the substrate
flip happens, the recogniser is untouched.

Under fd-0 fallback today, the kernel-side line discipline is
already effectively "byte at a time" — the kernel does not do POSIX
`ICANON` cooking; every `sys_read(0, buf, 1)` returns as soon as one
byte lands on the console ring, unaffected by the presence or absence
of a newline. Backspace and cursor keys therefore arrive at the reader
as their raw ASCII / CSI byte sequences without the shell issuing any
mode-set. When the substrate flip lands and `TTY_OP_SET_RAW` becomes
available, the mode set becomes a one-time call from `shell_main`
before the REPL loop begins, and `TTY_OP_SET_COOKED` becomes a paired
call on the EOF / exit path (an `@no_return` epilogue would leak the
raw-mode state to the next shell fork; the cooked restore is not
optional).

### 2.3 Entry / exit protocol (post-substrate)

The post-flip entry/exit protocol is:

```
shell_main:
  # ... argc/argv walk, session_mint ...
  if _sm_opt_c_cmd_ptr == 0 && isatty(fd 0):
      sys_cap_invoke(_sm_tty_cap_read, TTY_OP_SET_RAW)
  # ... REPL loop ...
  # On any exit path (EOF, exit builtin, fatal error):
      if raw_mode_was_set: sys_cap_invoke(_sm_tty_cap_read, TTY_OP_SET_COOKED)
      sys_exit(rc)
```

`isatty(fd 0)` here is a kernel query that today does not exist;
until it does, the substrate-flip issue is blocked. When the shell is
consuming a script (`-c` or positional `<script.pds>`) it does not
enter raw-mode — the ESC recogniser is skipped and reads flow through
the same `line_reader_read_line` in cooked-equivalent fallback mode.

The interactive detection question is orthogonal to the R66 body of
work; while the substrate is missing, the shell operates in the fd-0
fallback where the kernel is already in a raw-equivalent mode by
default. The recogniser handles both regimes transparently — an ESC
byte arrives as ESC in both.

## 3. ESC-sequence recognition

### 3.1 The bytes we recognise

R66 M1 recognises exactly five key codes, one of which is a bare byte
and four of which are CSI escape sequences:

| key         | wire bytes            | KEY_ constant             |
|-------------|-----------------------|---------------------------|
| Backspace   | `0x7F`                | `KEY_BACKSPACE`           |
| Up arrow    | `ESC` `[` `A`         | `KEY_UP`                  |
| Down arrow  | `ESC` `[` `B`         | `KEY_DOWN`                |
| Right arrow | `ESC` `[` `C`         | `KEY_RIGHT`               |
| Left arrow  | `ESC` `[` `D`         | `KEY_LEFT`                |
| (anything else printable ASCII 0x20..0x7E) | itself | `KEY_LITERAL(b)` |
| Newline     | `0x0A`                | `KEY_ENTER`               |
| Ctrl-D on empty line | `EOF`        | `KEY_EOF`                 |

Everything else (control bytes not in the above, unrecognised ESC
sequences, non-ASCII bytes) is dropped silently. A dropped byte does
not advance the cursor and does not modify the buffer; the recogniser
bumps `SH_ST_INPUT_DROPPED` (new slot, allocated in the History
0xFFFFEC6x band's shadow — see §11) and returns to the input state.

We do **not** recognise `ESC [ H` (Home) / `ESC [ F` (End) at M1; they
appear on most terminals and their landings become one-line dispatch
table additions in a follow-up. Word-wise motion (`ESC b`, `ESC f`)
similarly deferred. Function keys (`ESC O P` etc.) deferred.

### 3.2 State machine

The recogniser is a three-state DFA held in one `.bss` byte:

```
      any byte other than ESC
     ┌──────────────────────┐
     ▼                      │
   [S_GROUND] ── ESC ──► [S_ESC] ── '[' ──► [S_CSI] ── final ──┐
      ▲                      │   any other                     │
      │                      └───► drop, S_GROUND              │
      │                                                        │
      └────────────────────────────────────────────────────────┘
                          emit(key), back to S_GROUND
```

- **S_GROUND** is the resting state. A byte in `0x20..0x7E` emits
  `KEY_LITERAL(b)`. `0x0A` emits `KEY_ENTER`. `0x7F` emits
  `KEY_BACKSPACE`. `ESC` (`0x1B`) transitions to `S_ESC`. `0x04`
  (EOT / Ctrl-D) emits `KEY_EOF` **only if** the current line buffer
  is empty; otherwise it is dropped (a Ctrl-D mid-line is a POSIX
  quirk we deliberately do not import). Everything else drops.
- **S_ESC** is the "ESC has been seen, waiting on the sequence
  identifier" state. On `0x5B` (`'['`) transitions to `S_CSI`. On
  anything else, drops the byte, returns to `S_GROUND`. A bare `ESC`
  followed by a valid byte is not treated as a compound key — R66 M1
  makes no attempt to distinguish Meta-key sequences from lone ESC
  presses; this is a deliberate scope cut.
- **S_CSI** is the "ESC `[` has been seen, waiting on the CSI final
  byte" state. On `0x41` (`'A'`), `0x42` (`'B'`), `0x43` (`'C'`),
  `0x44` (`'D'`) emits `KEY_UP` / `KEY_DOWN` / `KEY_RIGHT` /
  `KEY_LEFT`. Everything else drops.

The DFA is bounded: a malformed sequence returns to `S_GROUND` within
at most two bytes. There is no state that can be stuck (a byte other
than `0x5B` in `S_ESC`, or anything not in `0x41..0x44` in `S_CSI`,
unconditionally returns to ground). A stuck-state test at the end of
each `line_reader_read_line` invocation is therefore unnecessary; the
loop naturally terminates on `KEY_ENTER` or `KEY_EOF`.

### 3.3 Why a DFA and not a lookup table

A table (`u8[256]` indexed by the current byte, `u8[256]` per state)
is measurably faster on a hot path but this path is human-typing rate.
The DFA is 20 lines of assembly and one `.bss` byte; the table is
768 bytes of `.rodata` and a bookkeeping module. The correctness
audit surface of the DFA is one grep; the table's is the byte-level
correctness of every column. We take the DFA and revisit only if
someone finds an actual paste-latency problem.

## 4. Key-code enum + dispatch table

### 4.1 KEY_ ordinals

Allocated in the `SR_` sub-band's shadow — the recogniser emits key
codes, not error codes, so a fresh sub-band `SK_` (0xFFFFECD0..)
holds them:

```
SK_NONE      = 0            # recogniser consumed a byte, no key emitted yet
                            # (mid-CSI, dropped, etc.)
SK_LITERAL   = 0xFFFFECD0   # low byte carries the literal ASCII code
                            # (encoded as SK_LITERAL | byte_in_low_16)
SK_ENTER     = 0xFFFFECD1
SK_BACKSPACE = 0xFFFFECD2
SK_UP        = 0xFFFFECD3
SK_DOWN      = 0xFFFFECD4
SK_LEFT      = 0xFFFFECD5
SK_RIGHT     = 0xFFFFECD6
SK_EOF       = 0xFFFFECD7
```

The literal encoding fuses the ASCII code into the low 8 bits of the
key code, and callers extract with `and rax, 0xFF` when they see the
`0xFFFFECD0` high tag. This lets the recogniser return a single `u64`
per byte without a paired output pointer, matching the calling
convention of every other `LineReader` helper.

### 4.2 Dispatch table

The line-editor loop reads one key code per iteration and routes:

```
  rax = line_editor_next_key()      # calls lr_read_one_byte 1..3 times
                                      # until a key is emitted
  switch rax:
    case SK_LITERAL | b:  le_insert_at_cursor(b)
    case SK_ENTER:        le_finalise_and_return()
    case SK_BACKSPACE:    le_erase_left()
    case SK_LEFT:         le_cursor_left()
    case SK_RIGHT:        le_cursor_right()
    case SK_UP:           le_history_prev()
    case SK_DOWN:         le_history_next()
    case SK_EOF:          le_return_eof()
```

`le_insert_at_cursor`, `le_erase_left`, `le_cursor_left`,
`le_cursor_right`, `le_history_prev`, `le_history_next` are the six
operations defined in §5..§7. `le_finalise_and_return` emits `\n` to
the terminal, appends the buffer bytes to the history ring (§6.4) and
returns the buffer length. `le_return_eof` returns `LR_ERR_EOF`.

Adding a new key (Home / End / word motion / kill-line) is one row in
the switch. Adding a new key that does not exist in the DFA (Home =
`ESC [ H`) is one row in §3.2's S_CSI final-byte table plus one row
here. The two additions are independent — the recogniser doesn't know
the semantics, the dispatcher doesn't know the wire bytes.

## 5. Backspace erase-on-screen

### 5.1 The `\b \b` triple

On `SK_BACKSPACE` the editor:

1. If the cursor is at column zero (buffer is empty OR cursor position
   equals zero after cursor motion), do nothing — no buffer change,
   no screen bytes emitted. Bump `SH_ST_INPUT_DROPPED` (§3.1).
2. Otherwise, delete the byte at `cursor - 1` from the buffer, shift
   the tail left by one (memmove of `buf[cursor..len]` → `buf[cursor-1..len-1]`),
   decrement `cursor` and `len` by one.
3. Emit `\b \b` (three bytes: back-space, space, back-space) to the
   terminal via `sys_write(1, ptr, 3)`. Physical effect: the cursor
   moves left one column, overwrites the erased glyph with a space,
   and moves back left again to sit under the space we just wrote.
4. If the cursor was **not** at end-of-line before the erase, we also
   need to redraw the tail; see §7 for the redraw protocol.

The `\b \b` triple works on every terminal that respects VT100
backspace, which is every terminal the shell will ever see. It does
**not** use `ESC [ D` for the left move — a bare `0x08` is smaller,
older, more portable, and does not trigger the S_CSI path if it were
somehow to loop back to us.

### 5.2 Column-zero no-op is deliberate

POSIX shells (bash, zsh) beep or flash on backspace-at-zero. We do
neither — the shell has no bell wiring at R66, and even when it does
(R73 territory), a silent no-op is less annoying and matches modern
GUI editor conventions. If a user hits backspace on an empty prompt
we drop the input; they can distinguish "did the shell see my key"
from a live `sys_write` echo because R66 does NOT echo dropped input
either.

### 5.3 Interaction with the prompt

The prompt (`$ `, emitted by `shell_main` before the read call) sits
to the left of the cursor. Backspace never crosses back into the
prompt, because the editor tracks cursor position within the line
buffer (not within the physical terminal column), and the "column
zero" check is against the buffer's own leftmost position. The
terminal's cursor is at prompt-end when `cursor == 0`; a backspace
at that position would visually appear to delete the prompt if it
succeeded, so refusing it at buffer-position zero is exactly right.

## 6. History ring

### 6.1 Storage

R66.M1-003 (`paideia-os/shell#19`) sizes the ring at 4096 bytes in the
issue text, but the shell repo already holds an 8192-byte in-memory
history buffer (`Shell::_sm_hist_buf`, `SM_HIST_RING_CAP = 8192`, see
`src/shell.pdx:400`) allocated at ENH-006 (`#33`) for the encoder
output. R66 M1 reuses this buffer without resizing — the 8 KiB
existing allocation is already twice the issue's minimum and is the
same buffer `history_persist_flush` drains to disk. Reallocating a
second 4-KiB history ring would create two sources of truth for
"what commands did the user run", so we do not.

The ring is a byte-oriented circular buffer indexed by newline. Each
committed line contributes:

- Its raw bytes (the buffer contents at the moment the user pressed
  Enter, WITHOUT the terminating newline — the ring is line-oriented,
  the newline is the separator, not part of the entry).
- A trailing `0x0A` byte to separate this entry from the next.

The `History::history_encode_record` wire format (`src/history.pdx`
§ WIRE FORMAT) is a **richer** persistence format — 24-byte header
plus command bytes plus padding — used by the disk-flush path. The
in-memory ring for arrow-key recall does NOT use that format; it
uses the flat `<cmd-bytes>\n<cmd-bytes>\n...` shape so the recall
walk is a linear back-scan for the previous `\n` boundary. The
persistence flush at REPL end continues to encode each entry into the
history wire format before writing.

### 6.2 Ring cursor semantics

Three `.bss` u64 singletons hold the ring state:

- `_sm_hist_head` — byte offset of the write cursor (where the NEXT
  entry's first byte will land). Modulo `SM_HIST_RING_CAP`.
- `_sm_hist_tail` — byte offset of the OLDEST entry's first byte;
  advances as the head wraps around and overwrites old data.
- `_sm_hist_recall_cursor` — during an active up/down walk, the
  offset of the currently-recalled entry's first byte. Reset to
  `_sm_hist_head` at the start of each new input line (i.e. after
  any `SK_ENTER` or after any `SK_LITERAL` typed while recalling —
  see §6.3 on the "recall commit" semantic).

The `history_encode_record` counter `SH_ST_HISTORY` (`Shell::SH_ST_HISTORY`,
slot 7) is unaffected by ring writes — it counts *persistence* attempts,
not *recall* activity. A new counter `SH_ST_RECALL` (slot 12, new
allocation in R66.M1-003) counts recall walks.

### 6.3 Up / down arrow semantics

**Up arrow (SK_UP):** walk the ring backwards to the previous entry:

1. If `_sm_hist_recall_cursor == _sm_hist_tail`, we are already at
   the oldest entry — no change, drop.
2. Otherwise, scan backwards from `_sm_hist_recall_cursor - 1`
   (modulo capacity) for the previous `0x0A` byte. The recalled
   entry starts one byte after that `0x0A` (or at `_sm_hist_tail`
   if we reached the tail without finding a newline, meaning we hit
   the oldest partial entry).
3. Copy the recalled bytes into `_sm_line_buf`, replacing whatever
   was there. Set `len` = length of recalled entry, `cursor` = `len`
   (cursor at end, so the next character typed appends normally).
4. Emit `\r` + `ESC [ K` (carriage return + clear-to-end-of-line) +
   the prompt + the recalled bytes to the terminal, in one
   `sys_write` call. `\r` returns to column zero, `ESC [ K` erases
   everything to the right (removing whatever was on-screen before),
   then the prompt and buffer are re-emitted.
5. Set `_sm_hist_recall_cursor` to the offset of the recalled
   entry's first byte.

**Down arrow (SK_DOWN):** walk forward.  If `_sm_hist_recall_cursor
== _sm_hist_head`, we are at the "empty draft" position — no change,
drop.  Otherwise scan forward for the next `0x0A`, and treat the
following entry as recalled; if we reach `_sm_hist_head`, we are back
at the empty draft and the buffer clears.

**Committing a recall:** typing any `SK_LITERAL` byte while recalling
promotes the recalled buffer to the current draft and resets
`_sm_hist_recall_cursor = _sm_hist_head`. The user's edit no longer
affects the historical entry (we do not implement history edit-in-place,
which is a bash-ism that surprises everyone the first time they
encounter it). Backspace and cursor motion during recall behave
identically to on the current draft — they edit `_sm_line_buf`
directly, and any further up-arrow walks from the modified draft;
`_sm_hist_recall_cursor` stays put until the next `SK_ENTER`, at
which point the (possibly edited) buffer commits as a fresh entry
and the recall cursor resets to the new head.

### 6.4 Committing a new entry

On `SK_ENTER`:

1. If the buffer is empty, we do NOT append to the ring (empty
   commands are not history-worthy).
2. Otherwise, copy `_sm_line_buf[0..len]` into the ring at
   `_sm_hist_head`, then append one `0x0A` byte. Advance
   `_sm_hist_head` by `len + 1` modulo capacity.
3. If the write would overrun `_sm_hist_tail`, advance
   `_sm_hist_tail` to the first byte after the next `0x0A`
   following the overwritten region. This preserves the invariant
   that every entry in the ring is either whole or has been
   entirely dropped — never truncated.
4. Reset `_sm_hist_recall_cursor = _sm_hist_head`.
5. Emit `\n` to the terminal, then return the buffer length to the
   caller (`shell_main`'s REPL loop), matching the pre-R66
   `line_reader_read_line` contract.

### 6.5 Fingerprint

R66.M1-003's fingerprint is `shell history ok -- entries=<N>`, emitted
by `sys_debug_puts` from a new helper `history_ring_witness` at the
END of every entry commit (§6.4 step 5, before the newline). `<N>` is
a live count of entries currently in the ring, computed by walking the
ring forward from `_sm_hist_tail` counting `0x0A` bytes. The count is
NOT cached — a walk of at most `SM_HIST_RING_CAP` (8192) bytes on
every commit is a hundred microseconds and the honest answer is worth
that.

The fingerprint is `-provenance-strip.md`-clean: it does not include a
milestone tag ("R66" or similar), matches the `component name ok --
kv=val` house shape from `design/policy/output-provenance-strip.md`.

## 7. Cursor-left / cursor-right in-place edit

### 7.1 Buffer + terminal state

Two `.bss` u64 slots hold the editor's state:

- `_sm_line_len` — number of buffer bytes currently allocated.
- `_sm_line_cursor` — position of the insertion point within the
  buffer, in the range `[0, _sm_line_len]`. `cursor == len` means
  "at end", the default position after any typed byte or history
  recall.

### 7.2 SK_LEFT

If `cursor == 0`, drop. Otherwise decrement `cursor` and emit `\b`
(a single 0x08 byte) to the terminal. The terminal's cursor moves
left by one; no buffer change.

### 7.3 SK_RIGHT

If `cursor == len`, drop. Otherwise emit `ESC [ C` (the CSI right-
move) to the terminal, then increment `cursor`. We use `ESC [ C`
rather than re-emitting the byte at the old cursor position because
re-emitting a byte would depend on that byte being printable — a
literal `\t` or `\a` at the cursor position would render very
differently on right-arrow than left-arrow does. `ESC [ C` is a
pure motion and always safe.

### 7.4 SK_LITERAL at non-end cursor

The interesting case: user has left-arrowed into a longer line and
types a byte in the middle.

1. Shift the buffer tail right by one:
   `buf[cursor+1..len+1] = buf[cursor..len]`.
2. Store the new byte at `buf[cursor]`.
3. Increment `cursor` and `len` by one.
4. Emit the byte + the tail bytes + a run of `\b` bytes equal to
   the tail length, in one `sys_write` call, so the terminal
   redraws the tail (including the newly-inserted byte at the old
   cursor position) and then walks the cursor back to sit just
   after the inserted byte.

Concrete example. Buffer is `hello`, cursor at position 2 (between
`e` and `l`). User types `X`:

- New buffer: `heXllo`, len 6, cursor 3.
- Emit: `X` + `llo` + `\b` + `\b` + `\b`.
- Terminal shows: `heXllo`, cursor sitting between `X` and the
  first `l`, exactly where the user expects it.

The one-`sys_write` compound is important — a per-byte write would
give the user a visible tearing artifact on slow terminals.

### 7.5 SK_BACKSPACE at non-end cursor

Analogous to §5, plus the tail redraw:

1. If `cursor == 0`, drop.
2. Shift tail left by one, decrement `cursor` and `len` by one.
3. Emit: `\b` + the new tail + ` ` (space) + `\b` bytes to walk
   the cursor back.

The trailing space overwrites the character that used to be the
rightmost, which the leftward shift would otherwise leave visible.

### 7.6 What about resize / wrap?

The editor assumes the terminal is wide enough to hold prompt + full
buffer on one line. Terminal-width detection is not part of R66 —
`ioctl(TIOCGWINSZ)` has no paideia-os analogue today. A line longer
than the terminal width will wrap at the terminal's discretion; on a
wrapped line, `\b` at column zero behaves platform-specifically
(most vt100-alikes will move up one row and to the last column;
some do not). We do not attempt to handle the wrapped case in R66;
the practical exposure is small since long lines are rare in
interactive use, and the eventual fix — reserve the wide-line
behavior for R73 alongside job control — is a natural bundling.

## 8. Interaction with `shell_repl_step`

`Shell::shell_repl_step(line_ptr, line_len)` is the per-line entry
point today (`src/shell.pdx:351`), invoked by `shell_main`'s REPL
loop with the buffer returned by `LineReader::line_reader_read_line`.

R66 does NOT modify `shell_repl_step`. The line editor's public
contract is unchanged: `line_reader_read_line(buf, buf_len)` returns
`bytes-written` on a successful line commit (Enter or EOF-with-buffer)
or an `LR_ERR_*` sentinel on failure. Every §2..§7 mechanism sits
INSIDE `line_reader_read_line`; the byte the REPL sees is the same
byte it would see without any of the R66 work.

The one visible change to the REPL loop is timing:
`line_reader_read_line` may now issue many `sys_write(1, ...)` calls
(for echoing typed bytes, backspace redraws, history recalls, cursor
moves) between the initial prompt write and the returned line. Prompt
emission (`sys_write(1, "$ ", 2)` in `shell_main`) is done ONCE, at
the top of each REPL iteration — the line editor's per-key echoes
never re-emit the prompt except during a history recall (§6.3 step 4),
where the recall's screen-clear-and-redraw requires it. Because the
recall's `\r` + `ESC [ K` scrubs the whole line, the caller's prompt
byte does NOT need to be preserved across the recall — the editor
holds the prompt string in a `.bss` cache slot (`_sm_prompt_str`, 2
bytes) and re-emits it as part of the recall bundle.

## 9. Counter discipline

Existing counters in `Shell::_shell_stats` (`src/shell.pdx:200..250`):

| slot | name              | R66 semantics                             |
|------|-------------------|-------------------------------------------|
| 0    | SH_ST_PROMPTS     | bumped once per `line_reader_read_line`   |
| 1    | SH_ST_LINES       | bumped once per successful commit         |
| 4    | SH_ST_ERRORS      | bumped on every reject / drop path        |
| 7    | SH_ST_HISTORY     | bumped by `history_encode_record` (unchanged) |

R66 adds two new counter slots (contiguous with the existing table
padding — the table is `[u64; 16]`; slots 12..15 are free):

| slot | name               | semantics                                 |
|------|--------------------|-------------------------------------------|
| 12   | SH_ST_RECALL       | bumped once per up/down arrow walk        |
| 13   | SH_ST_INPUT_DROPPED| bumped on every dropped byte (§3.1, §5.2, §7) |

The `SH_ST_PROMPTS - SH_ST_LINES - SH_ST_ERRORS == 0` invariant from
the module header holds unchanged; R66 keys neither commit lines nor
error out — they modify `_sm_line_buf` in place, and the commit path
(SK_ENTER) uses the same `LINES` bump as the pre-R66 successful-line
path.

## 10. Paideia-as conformance

The R66 M1 additions follow the same conformance profile as
`LineReader` and `History` in the shell repo:

- Every new function is a `pub let` in `module LineReader`, PascalCase
  basename, no directory prefix.
- No `test` mnemonic; `cmp reg, 0` for every zero-check.
- Every `cmp reg, imm` uses `imm <= 0x7FFFFFFF`. The largest raw
  immediate the editor compares against is `SM_LINE_BUF_CAP` (4096)
  and `SM_HIST_RING_CAP` (8192), both well inside the limit.
- Large immediates (the `SK_*` sentinels, `0xFFFFECDx`) are staged via
  `mov r10, imm64` before the compare, matching `History::` discipline.
- Byte reads use `xor rax, rax; mov_b rax, [ptr]` per the #1248
  mitigation. Byte writes use `mov_b [ptr], reg` (rax's low byte).
- Every callee-save push is matched by exactly one pop on every return
  path; `sub rsp, 8` is added when the callee-save count is even
  (0, 2, 4) to keep `rsp % 16 == 0` at every nested SysV call.
- Labels are prefixed by the function name (`le_ic_`, `le_el_`,
  `le_hp_`, `le_hn_`, `le_cl_`, `le_cr_`) — never bare `loop`, `if`,
  etc., which the encoder rejects as reserved words.

Cross-reference: `feedback_pdx_encoder_pitfalls.md` in project memory.

## 11. Return-code + counter allocations at a glance

New allocations R66 makes:

- `SK_*` key-code sub-band `0xFFFFECD0..0xFFFFECD7` (§4.1) — 8 codes
  in the previously-unused `0xFFFFECDx` slot. `SR_*` REPL codes
  already occupy `0xFFFFECF0..`; `LR_*` reader codes occupy
  `0xFFFFECE0..` per `line_reader.pdx`. `0xFFFFECDx` was free.
- `SH_ST_RECALL` (slot 12) and `SH_ST_INPUT_DROPPED` (slot 13) in
  `_shell_stats` (§9).
- `_sm_line_cursor` (u64), `_sm_hist_head` / `_sm_hist_tail` /
  `_sm_hist_recall_cursor` (u64 each) as `pub let mut` singletons in
  `module Shell`.
- `_sm_prompt_str` — a 2-byte `[u8; 2]` cache holding `"$ "` for the
  history-recall redraw path (§6.3 step 4). The literal already
  appears in `shell_main`'s prompt-write; the cache is a duplicate
  under a stable symbol so the recall bundle can `lea` it directly.
- The DFA state byte `_sm_edit_state` (`u8` in .bss, single byte
  holding `S_GROUND`/`S_ESC`/`S_CSI` = `0`/`1`/`2`).

## 12. Cross-references

**Monorepo (paideia-os/paideia-os):**
- `design/roadmap/post-r60-daily-use-roadmap.md` §R66 (charter).
- `design/roadmap/rows-4-5-6-scoping.md` §4.3 (KIND_TTY substrate gap).
- `design/user/shell-io-redirection.md` (style + section conventions).
- `design/user/syscall-table.md` (`sys_read`, `sys_write`; `sys_yield`
  TBD).
- `design/policy/output-provenance-strip.md` (fingerprint shape).
- `src/user/shell.pdx:39` (monorepo `shell_read_line` — the pattern
  the satellite's `line_reader_read_line` mirrors).
- `src/kernel/core/cap/kind.pdx` (KIND_TTY table; the KIND_SEEDABLE
  gap at L3450).

**Shell satellite (paideia-os/shell):**
- `src/line_reader.pdx` (host module for §2..§7).
- `src/shell.pdx` (host module for the `_sm_*` singletons + counters).
- `src/history.pdx` (persistence encoder unchanged; §6.4 flush
  interlocks with `history_persist_flush`).
- `design/architecture.md` §3.3 (fd-0-vs-KIND_TTY seam ledger).
- `caps.decl` — `KIND_TTY(read)` is already named per ENH-007 (`#34`)
  so the substrate flip does not require a manifest edit.

**Companion issues:**
- Substrate flip: paideia-os/paideia-os (new) — add `KIND_TTY` to
  `KIND_SEEDABLE_TABLE`; seed a `tty_cap_mint_inner` row for the
  shell at boot; add `sys_yield` (SC+ ID 5) to the shell's `Syscall`
  floor. Not a blocker for R66 M1 landing.
- R73.M1-002 (`paideia-os/shell#22`) — `^Z` / process-group tracking;
  layers over the recogniser as one new key code (`SK_STOP`) and one
  new dispatcher row.
- R73.M1-005 (`paideia-os/shell#25`) — tab completion; layers over the
  recogniser as one new key code (`SK_TAB`) and one new dispatcher
  row.
