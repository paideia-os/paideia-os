# Line editor: emacs-mode bindings (R229.M6)

**Status:** v1.0 (R229.M6 landing, Wave 127, paideia-os#2724).
**Upstream:** paideia-os#2493 (R229 umbrella), paideia-os#2724 (THIS).
**Sibling docs:** `design/terminal/editor-bindings.md` (bindings
decision log, LE-D1..LE-D4), `design/shell/history-storage.md`
(R229.M5 History substrate backing C-r), `design/shell/grapheme-
cluster-boundaries-tr29.md` (R221.M2 GraphemeIter cursor-advance),
`design/shell/width-pass-tr11.md` (R221.M3 WidthPass column
renderer).

## 1. Scope

R229.M6 lands the user-space line-editor substrate backing the shell's
emacs-mode. All 13 bindings from `design/terminal/editor-bindings.md`
§1 are implemented as one dispatch call per keystroke:

| Binding | Byte | Action |
|---|---|---|
| C-a | 0x01 | Beginning of line |
| C-b | 0x02 | Back one grapheme cluster |
| C-d | 0x04 | Delete grapheme cluster under cursor |
| C-e | 0x05 | End of line |
| C-f | 0x06 | Forward one grapheme cluster |
| C-k | 0x0B | Kill to end of line |
| C-l | 0x0C | No-op (TTY driver owns screen clear) |
| C-r | 0x12 | Reverse-i-search over R229.M5 History |
| C-u | 0x15 | Kill to beginning |
| C-w | 0x17 | Kill previous whitespace-delimited word |
| C-y | 0x19 | Yank kill buffer |
| M-f | ESC 0x66 | Forward word |
| M-b | ESC 0x62 | Back word |
| M-d | ESC 0x64 | Delete word forward |

A line is at most 4096 bytes; the kill buffer is 1024 bytes. Both
limits are the raw-M6 commitment; a later M6.1+ landing may stage a
heap-arena extension when a terminal's wrapped-line threshold grows
past the inline buffer.

## 2. Module shape

**File:** `tools/user/libpdx-pds-parser/src/line_editor.pdx`
**Module name:** `LineEditor`
**Status band:** `0x5400..0x54FF`
**Linker dependencies:** `_gi_next_cluster`, `_gi_prev_cluster`
(R221.M2 GraphemeIter), `_h_search_substring`, `_h_get_turn`
(R229.M5 History) — intra-library resolvers; no cross-library and
no new KIND.

### 2.1 Public API

| Entry | Signature | Return |
|---|---|---|
| `_le_init` | `()` | `()` — pure-leaf scalar scrub |
| `_le_reset` | `()` | `()` — clear buffer + cursor (preserves kill) |
| `_le_dispatch_key` | `(key_u32) -> status` | one keystroke dispatch |
| `_le_insert_bytes` | `(ptr, len) -> status` | insert at cursor |
| `_le_get_buffer` | `(out, out_cap) -> (bytes<<32)\|status` | read |

### 2.2 Static state (`.bss`, singleton)

| Symbol | Type | Semantics |
|---|---|---|
| `_le_buf` | `[u8; 4096]` | Active edit line |
| `_le_buf_len` | `u64` | Valid bytes in `_le_buf` |
| `_le_cursor_byte` | `u64` | Byte offset of cursor (authoritative) |
| `_le_cursor_cluster` | `u64` | Grapheme-cluster offset (hint for width renderer) |
| `_le_kill_buf` | `[u8; 1024]` | Last killed span |
| `_le_kill_len` | `u64` | Valid bytes in `_le_kill_buf` |
| `_le_meta_pending` | `u64` | 1 iff last byte was ESC (0x1B); next dispatch is M-prefixed |
| `_le_last_search_turn` | `u64` | Most recent C-r hit (u32 turn_id in low 32 bits); 0 if none |

Cold-boot `.bss` zero-init already satisfies every invariant (empty
buffer, empty kill, cursor at 0, meta latch clear). `_le_init` is a
defensive scrub for chaos-restart.

### 2.3 Status taxonomy

| Code | Hex | Returned by | Meaning |
|---|---|---|---|
| `LE_OK` | 0 | all | success |
| `LE_ERR_BUF_FULL` | 0x5400 | insert / dispatch | would exceed 4096 B |
| `LE_ERR_BAD_PTR` | 0x5401 | insert / get | ptr/out == 0 |
| `LE_ERR_OUT_TOO_SMALL` | 0x5402 | get | out_cap < buf_len |
| `LE_ERR_BAD_KEY` | 0x5403 | dispatch | unbound control byte |
| `LE_ERR_UTF8` | 0x5404 | dispatch | GraphemeIter reported INVALID_UTF8 |
| `LE_ERR_BAD_LEN` | 0x5405 | insert | len == 0 |
| `LE_META_PENDING` | 0x5406 | dispatch | ESC latched; next byte is M-prefixed |

The band is disjoint from every other parser-tier packed-status band
in the paideia-os tree (see `caps.decl` R229.M6 note). `0x5407..
0x54FF` reserved for M6.1+ follow-ups.

## 3. Dispatch state machine

```
                       +---------+
                       | READING |
                       +----+----+
                            |
                            v
       (byte read; _le_dispatch_key(byte))
          |                 |                     |
          |                 |                     |
    (control byte)     (byte == 0x1B)        (printable)
          |                 |                     |
          v                 v                     v
   binding handler    set meta_pending       insert at cursor
          |             return LE_META          (shift-right,
          |              _PENDING                store, bump
          v                                     cursor + len)
      update                v                     |
      cursor /          +---+----+                v
      buf state         | ESC    |            LE_OK
          |             | latched|
          v             +---+----+
       LE_OK                |
                            v
                 (next dispatch sees
                  meta_pending == 1;
                  dispatches M-f/M-b/M-d;
                  clears latch)
```

On a successful RET-commit (byte 0x0A or 0x0D), the REPL loop
(R229.M1 kernel-side) reads the line out via `_le_get_buffer`,
appends to History via `_h_append`, then calls `_le_reset`. The
RET byte is intercepted by the REPL loop BEFORE `_le_dispatch_key`
sees it — this module's dispatcher does NOT bind LF/CR.

## 4. Per-binding register plan

`_le_dispatch_key` uses one 6-callee-save-push frame + 8-byte align
pad so every nested CALL (to `_gi_*` or `_h_*`) sits at rsp%16==0.
Entry rsp%16==8; `48 B push + 8 B pad = 56 B`; `(8+56) mod 16 == 0`.

| Register | Role |
|---|---|
| rbx | key_byte (saved input, low 8 bits) |
| rbp | kill_target_start (C-u/C-w) / scan cursor (M-*) |
| r12 | kill_target_end / phase2 cursor |
| r13 | scratch_1: packed return from `_gi_*` / buf base |
| r14 | scratch_2: inner cursor |
| r15 | scratch_3: buf_len cache / status staging |

`r11` is NEVER held across a nested CALL — every `lea r11, [rip +
sym]` re-stages immediately before each `.bss` load/store. `rax` /
`rcx` / `rdx` / `rsi` / `rdi` / `r8..r11` are caller-save and used
freely across call-site boundaries.

## 5. Correctness invariants

1. **Byte-length is authoritative:** `_le_cursor_byte` is always the
   source of truth. `_le_cursor_cluster` is a renderer hint; the
   width-pass column renderer may call `_wp_cols(buf, cursor_byte)`
   to re-derive the column count if the hint is stale.
2. **Cursor sits on a cluster boundary:** C-b / C-f / C-d route
   through R221.M2 so the cursor never splits a cluster. The
   per-byte insert path advances cursor_cluster by 1 only on ASCII
   lead bytes (< 0x80); multi-byte continuations leave the hint
   unchanged.
3. **Shift-right walks DOWN:** inserts shift `buf[cursor..buf_len)`
   right by the inserted length by walking from `tail_len-1` down
   to 0, so overlapping copies are aliasing-safe.
4. **Shift-left walks UP:** deletes shift `buf[end..buf_len)` left
   by the deleted length by walking from 0 up to `tail_count-1`,
   same aliasing discipline.
5. **Buffer-full is a soft error:** `LE_ERR_BUF_FULL` leaves the
   buffer unchanged. Callers may show a bell or line-wrap diagnostic.
6. **Kill buffer survives across lines:** `_le_reset` deliberately
   does NOT clear `_le_kill_buf` or `_le_kill_len`, matching
   emacs/readline convention (yank works into a fresh prompt).
7. **ESC is a latch, not a prefix:** `_le_dispatch_key` returns
   `LE_META_PENDING` after latching, so the caller can distinguish
   a dangling ESC (user hit Escape and nothing else) from a real
   M-prefixed binding. A follow-up dispatch within a short timeout
   consumes the latch; a long timeout triggers a caller-side
   "escape key only" interpretation (M6.1+).

## 6. C-r (reverse-i-search) flow

C-r is the only binding that reaches outside the editor's own
`.bss`:

1. Guard: `buf_len > 0` AND `buf_len <= 64` (History cmd_inline
   width). Otherwise silent OK.
2. Clear `_le_last_search_turn` to zero.
3. Call `_h_search_substring(buf, buf_len, 0,
   &_le_last_search_turn, 1)` — walks newest-first through
   History's live-ring window, finds the first turn whose
   cmd_inline contains `buf` as a substring.
4. On a hit (result_count > 0):
   - Read the matched turn_id u32 from `_le_last_search_turn[+0]`.
   - Call `_h_get_turn(turn_id, scratch, 128)` into a scratch
     window in the kill buffer's tail (bytes 896..1024).
   - Measure the inline length by scanning cmd_inline[0..64] for
     the first zero byte.
   - Overwrite `_le_buf[0..len)` with the inline, set
     `_le_buf_len := len`, `_le_cursor_byte := len`,
     `_le_cursor_cluster := 0`.
5. On a miss or on an error: silent OK (the UI shows no change).

The scratch region (bytes 896..1024 of the kill buffer) is a
deliberate reuse of a slot that is zeroed implicitly: before the
scratch write, we clear `_le_kill_len := 0` so the kill buffer is
semantically empty for the duration of the lookup. The acceptance
test corpus (M6.4) will verify that this reclamation does not
leak scratch bytes into a subsequent C-y.

## 7. Acceptance

The issue brief's acceptance is "interactive test: every binding
produces the expected edit." This translates to the per-binding
assertions:

| Binding | Input state | Keystroke | Output state |
|---|---|---|---|
| C-a | `hello world` cur=5 | 0x01 | cur=0 |
| C-e | `hello world` cur=0 | 0x05 | cur=11 |
| C-f | `héllo` cur=0 | 0x06 | cur=1 (one cluster past 'h') |
| C-f | `héllo` cur=1 | 0x06 | cur=3 (one cluster past 'é'; é is 2 bytes) |
| C-b | `héllo` cur=3 | 0x02 | cur=1 (back over 'é') |
| C-d | `hello` cur=0 | 0x04 | buf=`ello` cur=0 |
| C-k | `hello world` cur=5 | 0x0B | buf=`hello` kill=` world` |
| C-u | `hello world` cur=6 | 0x15 | buf=`world` kill=`hello ` cur=0 |
| C-w | `foo bar` cur=7 | 0x17 | buf=`foo ` kill=`bar` cur=4 |
| C-y | `foo ` cur=4 kill=`bar` | 0x19 | buf=`foo bar` cur=7 |
| C-r | buf=`ec` + History has `echo hi` | 0x12 | buf=`echo hi` cur=7 |
| M-f | `foo bar baz` cur=0 | 0x1B,0x66 | cur=3 |
| M-b | `foo bar baz` cur=11 | 0x1B,0x62 | cur=8 |
| M-d | `foo bar baz` cur=3 | 0x1B,0x64 | buf=`foo baz` cur=3 kill=` bar` |

Interactive verification: a smoke driver at R229.M6.4 will feed
every row above into `_le_dispatch_key` and compare the resulting
`_le_buf_len`, `_le_cursor_byte`, and `_le_kill_len` + first-16-
bytes against the golden column.

## 8. paideia-as encoder discipline

The module adheres to the ABSOLUTE discipline recorded in
`feedback_pdx_encoder_pitfalls`:

- No `test rN, rN` — zero-checks use `cmp reg, 0; je/jne`.
- No `and rN, imm64` — low-byte masks (`and rax, 0xFF`,
  `and rax, 0x7F`) fit imm8/imm32 sign-safe.
- No 2-op `imul r, imm` — no stride multiplies at the editor tier
  (buffers are byte-indexed; `_h_get_turn` returns a 128-byte
  record copied via `mov` without stride math).
- No multiline `pub let = "..."` — single-line justifications on
  every entry.
- Module basename `LineEditor` matches `line_editor.pdx`.
- Labels prefixed `le_`, with per-handler suffix (`le_ini_`,
  `le_rst_`, `le_ins_`, `le_gb_`, `le_disp_`). Disjoint from every
  sibling parser-tier namespace.
- Register-liveness: `r11` is never held across a nested CALL —
  every `.bss` access re-stages via `lea r11, [rip + sym]`.
- Frame shape: `_le_dispatch_key` has `6 push + sub rsp, 8 = 56 B`,
  giving rsp%16==0 at every nested CALL. The three leaf entries
  (`_le_init`, `_le_reset`, `_le_insert_bytes`, `_le_get_buffer`)
  are pure leaves with zero pushes.
- Buffer overlap discipline: inserts walk right-to-left; deletes
  walk left-to-right (see §5).

## 9. Forward path

| Milestone | Delivery |
|---|---|
| R229.M6.1 | Multi-line edit: leading `\` before LF opens a continuation; editor keeps LF in buf, draws continuation prompt |
| R229.M6.2 | Syntax-highlighting hook: parallel colour-attr array populated by CtxLexer (R221.M4) at tokenise-time |
| R229.M6.3 | C-s forward-i-search (symmetric to C-r) |
| R229.M6.4 | Smoke-mode asserter golden corpus (13 OK + 7 REJ tags) |
| R229.M6.5 | Vi-mode state machine (band 0x5500..0x55FF) — satellite to this file; see `design/terminal/editor-bindings.md` §2 |
| R229.M6.6 | TR#29-cluster-aware word-boundary refinement for M-f/M-b/M-d/C-w (currently ASCII-whitespace fast path) |

## 10. Where this is NOT

- **A terminal driver.** The TTY driver owns raw-mode byte input,
  prompt rendering, bell, and screen clear (C-l). This module
  mutates an in-memory buffer; the renderer reads the buffer at
  prompt-redraw time.
- **A completion engine.** The brief lists completion (TAB) under
  design/terminal/editor-bindings.md §1; completion is R229.M7+
  work backed by `CmdRegistry` (R222.M5) and `DescribeSig`
  (R222.M8). TAB falls through this module as a bound-byte
  rejection (LE_ERR_BAD_KEY) at raw M6; the TAB handler lands
  separately.
- **An undo substrate.** C-_ / C-x C-u (undo) are explicitly
  deferred; they need a snapshot ring whose shape is a R229.M6.7
  landing.

## 11. File footprint

- `tools/user/libpdx-pds-parser/src/line_editor.pdx` — new.
- `tools/user/libpdx-pds-parser/src/lib.pdx` — version bump, flag
  bit, catalogue.
- `tools/user/libpdx-pds-parser/caps.decl` — band note + per-module
  dependency section.
- `tools/user/libpdx-pds-parser/CHANGELOG.md` — Wave 127 entry.
- `tools/user/libpdx-pds-parser/STATUS.md` — milestone status +
  error-band row.
- `.plans/scratch/CHANGELOG-R229M6.md` — per-primitive scratch.
- `design/shell/line-editor-emacs.md` — THIS file.

## 12. Related

- `design/terminal/editor-bindings.md` — binding decisions (LE-D1..
  LE-D4).
- `design/shell/history-storage.md` — R229.M5 History substrate.
- `design/shell/grapheme-cluster-boundaries-tr29.md` — R221.M2
  GraphemeIter.
- `design/shell/width-pass-tr11.md` — R221.M3 WidthPass column
  renderer that will walk `_le_buf[0..cursor_byte)` on every prompt
  redraw.
- `design/shell/repl-loop-scaffold.md` — R229.M1 kernel-side state
  machine that drives this module.

*End of document.*
