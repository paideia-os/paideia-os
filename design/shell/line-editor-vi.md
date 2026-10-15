# Line editor: vi-mode bindings (R229.M7)

**Status:** v1.0 (R229.M7 landing, Wave 128, paideia-os#2725).
**Upstream:** paideia-os#2493 (R229 umbrella), paideia-os#2725 (THIS).
**Sibling docs:** `design/terminal/editor-bindings.md` (bindings
decision log, LE-D1..LE-D4), `design/shell/line-editor-emacs.md`
(R229.M6 LineEditor substrate — ViMode shares the line buffer, kill
buffer, and cursor with it), `design/shell/history-storage.md`
(R229.M5 History — reachable from the planned M7.7 COMMAND-mode
`:` builtins).

## 1. Scope

R229.M7 lands the user-space line-editor substrate backing the shell's
vi-mode as a SATELLITE module to R229.M6 LineEditor. All bindings
from `design/terminal/editor-bindings.md` §2 are implemented as one
dispatch call per keystroke under a MODAL state machine:

| Mode | Byte-value | Role |
|---|---|---|
| NORMAL | 0 | Default; keys interpreted as motions / operators / mode-entry |
| INSERT | 1 | Keys inserted as literal bytes; ESC returns to NORMAL |
| VISUAL | 2 | Motion extends selection; `d`/`c`/`y` operate on selection |
| COMMAND | 3 | `:` line editor (M7 stub; `:` parsing lands at M7.7) |

### 1.1 NORMAL-mode motions (byte table)

| Byte | Key | Action |
|---|---|---|
| 0x68 | `h` | cursor -= 1 (bounded >= 0) |
| 0x6C | `l` | cursor += 1 (bounded <= buf_len) |
| 0x6A | `j` | line down — M7 no-op (single-line) |
| 0x6B | `k` | line up — M7 no-op (single-line) |
| 0x77 | `w` | forward word (skip non-ws, then skip ws) |
| 0x62 | `b` | back word (step left; skip ws left; then skip non-ws left) |
| 0x65 | `e` | end-of-word (land on the last non-ws of the current/next word) |
| 0x30 | `0` | cursor := 0 |
| 0x24 | `$` | cursor := buf_len |
| 0x47 | `G` | cursor := buf_len |
| 0x67 | `g` | latch `_vi_pending_g = 1`; next `g` executes `gg` (cursor := 0) |

### 1.2 NORMAL-mode operators

| Byte | Key | Action |
|---|---|---|
| 0x64 | `d` | Latch `_vi_pending_op := 'd'`; next motion = delete span |
| 0x63 | `c` | Latch `_vi_pending_op := 'c'`; next motion = change span (delete + INSERT) |
| 0x79 | `y` | Latch `_vi_pending_op := 'y'`; next motion = yank span |

Operator-motion composition examples:

| Keys | Effect |
|---|---|
| `dw` | Delete to start of next word |
| `d$` | Delete to end of line |
| `d0` | Delete to beginning of line |
| `dG` | Delete to end of buffer |
| `cw` | Delete to start of next word; enter INSERT |
| `yw` | Yank to start of next word |
| `y$` | Yank to end of line |

### 1.3 NORMAL-mode linewise doubles

| Keys | Effect |
|---|---|
| `dd` | Yank whole buffer to kill; truncate `_le_buf_len := 0` |
| `cc` | Same as `dd` plus mode := INSERT |
| `yy` | Yank whole buffer to kill |

Linewise detection: when the pending-op byte equals the just-pressed
byte (same letter), the dispatcher short-circuits to the whole-buffer
path and clears the pending-op latch.

### 1.4 NORMAL-mode paste

| Byte | Key | Action |
|---|---|---|
| 0x70 | `p` | Insert `_le_kill_buf` at `min(cursor + 1, buf_len)` |
| 0x50 | `P` | Insert `_le_kill_buf` at `cursor` |

Both paths run inline shift-right over `_le_buf` and bump cursor
past the pasted span.

### 1.5 NORMAL-mode mode entry

| Byte | Key | Action |
|---|---|---|
| 0x69 | `i` | mode := INSERT; cursor stays |
| 0x61 | `a` | cursor := min(cursor + 1, buf_len); mode := INSERT |
| 0x49 | `I` | cursor := 0; mode := INSERT |
| 0x41 | `A` | cursor := buf_len; mode := INSERT |
| 0x6F | `o` | cursor := buf_len; mode := INSERT (M7 degenerate to A; multi-line at M7.1) |
| 0x4F | `O` | cursor := 0; mode := INSERT (M7 degenerate to I) |
| 0x76 | `v` | mode := VISUAL; `_vi_visual_anchor := cursor` |
| 0x3A | `:` | mode := COMMAND |

### 1.6 ESC (0x1B)

| Mode | Effect |
|---|---|
| NORMAL | Clear `_vi_pending_op` and `_vi_pending_g`; stay in NORMAL |
| INSERT | mode := NORMAL |
| VISUAL | mode := NORMAL; clear anchor |
| COMMAND | mode := NORMAL |

### 1.7 INSERT dispatch

| Byte range | Action |
|---|---|
| 0x1B | mode := NORMAL (handled above) |
| 0x20..0x7E | Inline shift-right at cursor + byte store; `buf_len += 1`; `cursor += 1`; `cursor_cluster += 1` |
| 0x80..0xFF | Inline shift-right at cursor + byte store; `buf_len += 1`; `cursor += 1`; `cursor_cluster` unchanged (continuation) |
| 0x00..0x1A (except ESC), 0x7F | `VI_ERR_BAD_KEY` |

A line is at most 4096 bytes; the kill buffer is 1024 bytes. Both
limits are inherited from R229.M6 LineEditor; a later M7.1+ landing
may stage a heap-arena extension when the LineEditor's wrapped-line
threshold grows past the inline buffer.

## 2. Module shape

**File:** `tools/user/libpdx-pds-parser/src/vi_mode.pdx`
**Module name:** `ViMode`
**Status band:** `0x5700..0x57FF`
**Linker dependencies:** `_le_buf`, `_le_buf_len`, `_le_cursor_byte`,
`_le_cursor_cluster`, `_le_kill_buf`, `_le_kill_len` (R229.M6
LineEditor `.bss` singletons) — intra-library data references; no
cross-library and no new KIND.

ViMode makes NO cross-module FUNCTION calls at raw M7: every edit
primitive (INSERT-mode byte insert, operator-motion delete-span,
yank-span byte copy, paste shift-right) is INLINED. This keeps
`_vi_dispatch_key` a PURE LEAF — zero stack-align pad is required
because no nested CALL exists.

### 2.1 Public API

| Entry | Signature | Return |
|---|---|---|
| `_vi_init` | `()` | `()` — pure-leaf scalar scrub (32 B) |
| `_vi_reset` | `()` | `()` — identical scrub (session-reset hook) |
| `_vi_mode_get` | `()` | u64 — current mode (0..3) |
| `_vi_dispatch_key` | `(key_u32) -> status` | one keystroke dispatch |

### 2.2 Static state (`.bss`, singleton)

| Symbol | Type | Semantics |
|---|---|---|
| `_vi_mode` | `u64` | Current mode: 0=NORMAL, 1=INSERT, 2=VISUAL, 3=COMMAND |
| `_vi_pending_op` | `u64` | Latched operator byte ('d'=0x64 / 'c'=0x63 / 'y'=0x79) in NORMAL mode; 0 iff no op pending |
| `_vi_pending_g` | `u64` | 1 iff the previous byte was `g` and we are awaiting the second `g` of `gg`; 0 otherwise |
| `_vi_visual_anchor` | `u64` | Byte offset at which VISUAL was entered; defines the selection anchor |

Cold-boot `.bss` zero-init already satisfies every invariant (mode
= NORMAL, no latches, no anchor). `_vi_init` and `_vi_reset` are
defensive scrubs for chaos-restart / session-reset.

### 2.3 Status taxonomy

| Code | Hex | Returned by | Meaning |
|---|---|---|---|
| `VI_OK` | 0 | all | success |
| `VI_ERR_BAD_KEY` | 0x5700 | dispatch | unbound byte in the active mode |
| `VI_ERR_BUF_FULL` | 0x5701 | dispatch | `p`/`P` or INSERT would exceed 4096 B |
| `VI_ERR_BAD_MODE` | 0x5702 | dispatch | defensive: `_vi_mode` out of 0..3 |
| `VI_PENDING_OP` | 0x5703 | dispatch | `d`/`c`/`y` latched; next byte is motion |
| `VI_PENDING_G` | 0x5704 | dispatch | first `g` latched; next byte, if `g`, is `gg` |

The band is disjoint from every other parser-tier packed-status band
in the paideia-os tree (see `caps.decl` R229.M7 note). `0x5705..
0x57FF` reserved for M7.1+ follow-ups.

## 3. Dispatch state machine

```
                       +---------+
                       | READING |
                       +----+----+
                            |
                            v
       (byte read; _vi_dispatch_key(byte))
                            |
                 +----------+-----------+
                 |          |           |
                 v          v           v
            NORMAL      INSERT      VISUAL / COMMAND
                 \         |         /
                  \        |        /
                   v       v       v
                 (per-mode handler mutates .bss)
                            |
                            v
                   VI_OK / VI_PENDING_* / VI_ERR_*
                            |
                            v
                  state := WRITING -> emit prompt -> READING
```

### 3.1 NORMAL-mode flow

1. Check `_vi_pending_g`: if 1, consume byte (execute `gg` iff byte
   is `g`, else cancel latch and dispatch normally).
2. Dispatch byte: ESC cancels pending state; mode-entry keys set
   LineEditor cursor + `_vi_mode`; operator keys latch
   `_vi_pending_op`; paste runs inline shift-right; motion keys
   compute target `c1` in a shared motion-apply block.
3. If `_vi_pending_op != 0`: apply operator over
   `[min(c0, c1), max(c0, c1))`; clear `_vi_pending_op`; iff op
   was `c`, set mode := INSERT.
4. Else: cursor := `c1`.

### 3.2 Operator-motion composition semantics

For a motion byte with `_vi_pending_op != 0`:

1. Snapshot `c0 := _le_cursor_byte` at motion-dispatch entry.
2. Compute motion target `c1` (same code path as motion-only).
3. Order `[lo, hi) := [min(c0, c1), max(c0, c1))`.
4. Yank `_le_buf[lo..hi)` to `_le_kill_buf` (clamped to 1024 B).
5. If op is `d` or `c`: shift-left `_le_buf[hi..buf_len)` to
   `_le_buf[lo..]`; `_le_buf_len -= (hi - lo)`;
   `_le_cursor_byte := lo`; `_le_cursor_cluster := 0`.
6. If op is `c`: `_vi_mode := INSERT`.
7. Clear `_vi_pending_op`.

### 3.3 VISUAL-mode flow

- Motion bytes move cursor; anchor stays in `_vi_visual_anchor`.
- `d`/`c`/`y` apply inline over `[min(anchor, cursor), max(anchor,
  cursor))` and leave VISUAL (mode := NORMAL for `d`/`y`; mode :=
  INSERT for `c`); anchor cleared.
- ESC returns to NORMAL and clears anchor.

### 3.4 COMMAND-mode flow (M7 stub)

- ESC returns to NORMAL.
- Every other byte is a silent no-op (VI_OK).

The actual `:` line parser lands at R229.M7.7.

## 4. Correctness invariants

| Invariant | Enforced by |
|---|---|
| `_vi_mode` ∈ {0, 1, 2, 3} | `.bss` zero-init + every mode-change writes a literal 0..3 |
| `_vi_pending_op` ∈ {0, 'd', 'c', 'y'} | ops are the only writers; cleared on every op-apply |
| `_vi_pending_g` ∈ {0, 1} | written only by the `g` latch and the consumer |
| `_vi_visual_anchor ≤ _le_buf_len` after `v` entry | anchor written at `v` dispatch; buffer-shrinking ops clear anchor via leave-VISUAL |
| `_le_cursor_byte ≤ _le_buf_len` after every motion | motion target clamping (`h` bounded ≥ 0; `l` bounded ≤ buf_len; others monotone-correct by construction) |
| `_le_buf_len ≤ 4096` after every edit | paste/insert guard with `VI_ERR_BUF_FULL` |
| `_le_kill_len ≤ 1024` after every yank | clamp before write |

## 5. Acceptance

**Interactive test** (per paideia-os#2725):

> Standard vi motion set produces expected edits.

The raw M7 surface satisfies this. The design doc §7 enumerates
each binding's input state / keystroke / output state as the
golden column; a smoke-mode fingerprint corpus lands at R229.M7.9.

Example traces (buffer `the quick brown fox`, cursor at offset 0):

| Keys | Result (buffer, cursor) |
|---|---|
| `w` | buffer unchanged; cursor := 4 (start of `quick`) |
| `w w` | cursor := 10 (start of `brown`) |
| `$` | cursor := 19 (end of line) |
| `0` | cursor := 0 |
| `dw` | buffer := `quick brown fox` (cursor at 0; `the ` to kill) |
| `d$` | buffer := `` (empty; `the quick brown fox` to kill) |
| `i a Esc` | buffer := `athe quick brown fox` (cursor at 1); mode := NORMAL |
| `yy` | buffer unchanged; kill := `the quick brown fox` |
| `G P` | cursor := 19 then paste before: buffer := `the quick brown foxthe quick brown fox`; cursor at 38 |
| `v w d` | from NORMAL at offset 0: enter VISUAL anchor=0; `w` extends cursor to 4; `d` deletes [0, 4) → buffer := `quick brown fox` |

## 6. paideia-as encoder discipline

Standard discipline (see module-header §ENCODER DISCIPLINE for the
full list). Highlights:

- No `test rN, rN`; every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64`; the low-byte mask `and rax, 0xFF` fits imm32
  with bit 31 clear.
- No 2-op `imul r, imm`.
- No multiline `pub let = "..."`.
- Module basename `ViMode` matches `vi_mode.pdx`.
- Labels prefixed `vi_` with per-handler suffixes (`vi_mw_` word-
  forward, `vi_mb_` word-back, `vi_me_` end-of-word, `vi_mao_`
  motion-apply-operator, `vi_lw_` linewise, `vi_paste_` paste,
  `vi_ins_` insert-byte, etc.). Disjoint from `le_` and every
  sibling parser-tier namespace.
- `_vi_dispatch_key` is a PURE LEAF: 6 callee-save pushes
  (rbx = key_byte, rbp = scratch1, r12 = c0 cursor-at-op-start,
  r13 = c1 motion target, r14 = buf_len, r15 = &buf) + ZERO
  nested CALL + ZERO stack pad. All buffer manipulation is inlined
  rather than CALL'd into R229.M6 LineEditor helpers, so no
  rsp-align pad is needed. r11 is used freely as a staging
  register because no nested CALL exists.

## 7. Forward path

| M | Addition |
|---|---|
| M7.1 | Multi-line `o`/`O` (depends on R229.M6.1 LineEditor multi-line) |
| M7.2 | TR#29-cluster-aware motion via R221.M2 GraphemeIter |
| M7.3 | Count prefixes `3dw`, `5h`, `d3w` |
| M7.4 | Named registers `"ay`, `"ap` |
| M7.5 | Marks `ma`, `` `a `` |
| M7.6 | Text objects `daw`, `di"` |
| M7.7 | COMMAND-mode `:` line parser + builtins `:w`, `:q`, `:%s` |
| M7.8 | Macros `qa...q`, `@a` |
| M7.9 | Smoke-mode fingerprint goldens |

## 8. Boundary

ViMode is PARSER-TIER by geography (same satellite library as
LineEditor) but is NOT itself a parser — the module reads modal
scalars and the LineEditor `.bss` for its edit primitives, and
never calls into the parser surface at edit time.

The REPL dispatcher (R229.M1, kernel-side) calls either
`_le_dispatch_key` (emacs mode) OR `_vi_dispatch_key` (vi mode)
per keystroke; the shell's `~/.paideia/shell-keys.toml`
`shell.line-editor.mode` setting selects which. The two paths
are mutually exclusive per LE-D1 / LE-D2 / LE-D3 in
`design/terminal/editor-bindings.md`.

## 9. File footprint

| File | Role | Added |
|---|---|---|
| `tools/user/libpdx-pds-parser/src/vi_mode.pdx` | ViMode module | yes |
| `design/shell/line-editor-vi.md` | This design doc | yes |
| `tools/user/libpdx-pds-parser/caps.decl` | R229.M7 catalogue + status band | updated |
| `tools/user/libpdx-pds-parser/src/lib.pdx` | `R229_M7_READY` flag; version bump | updated |
| `tools/user/libpdx-pds-parser/STATUS.md` | Wave 128 R229.M7 landing | updated |
| `tools/user/libpdx-pds-parser/CHANGELOG.md` | Wave 128 R229.M7 entry | consolidated at wave close from `.plans/scratch/CHANGELOG-R229M7.md` |

## 10. Related

- `design/terminal/editor-bindings.md` §2 — the authoritative
  vi-mode binding table this module implements.
- `design/shell/line-editor-emacs.md` — the R229.M6 LineEditor
  substrate whose `.bss` ViMode reuses.
- `design/shell/repl-loop-scaffold.md` — the R229.M1 PROMPT /
  READING / PARSED / EVAL / WRITING / IDLE state machine the
  dispatcher sits inside.
