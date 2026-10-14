# Raw-mode TTY substrate (R127.M3)

Issue: paideia-os#2599
Wave:  UMB-W14
Lands:  2026-10-13

## 1 Why

A line-editing shell wants the TTY in cooked mode (ICANON + ECHO +
ICRNL + ONLCR — the current global default in `src/kernel/core/tty/`).
A full-screen program running under the shell (an editor, a pager, a
TUI tool) wants raw mode: no line discipline, no echo, no canonical
buffering, so every byte is delivered to the program the instant it
lands in the ring.

In a POSIX shell the knob is `termios` — a per-fd struct the program
flips with `tcsetattr`.  R127's novel-clean posture keeps the policy
on the SHELL SESSION (the thing that owns the REPL) rather than the
file descriptor.  Rationale:

* The shell session already carries `tty_fd`, `cap_env_slot`, history
  anchors and lifecycle state.  Line-discipline mode is of a piece.
* The KIND_SHELL_SESSION capability is already the cap-invoke gate the
  shell parent holds; adding a `SET_RAW` op is one more invocation
  against the cap the shell already carries.
* Terminal substrate (ldisc, echo, canonicalisation) still lives in
  `src/kernel/core/tty/`; this landing adds the per-session policy
  flags that a session-aware ldisc path will consult.  The flip of
  the ldisc path itself is a separate wave (§6).

M3 lands:

1. Three raw-mode policy flags stored in the shell_session row's
   previously-reserved high-32 slot at `[row+40]`.
2. Direct-call API `_shell_session_set_raw` / `_shell_session_get_raw`.
3. `KIND_SHELL_SESSION` op `KS_OP_SET_RAW = 4` + dispatch arm.
4. Fingerprints + allowlist entry.

M3 does NOT touch the TTY driver.  §6 lists the follow-up ticket.

## 2 Flag layout

The shell_session row (`src/kernel/core/svc/shell_session.pdx` §1) holds
a `state : u32 + reserved : u32` pair at `[+40]`, stored as one u64:

```
  [+40]   state (low 32) + reserved (high 32)
```

R127.M1's handback left the high 32 bits "reserved for a future
generation counter"; R127.M2's `cap_handler_shell_session READ_STATE`
op explicitly masks `and r12, 0xFFFFFFFF` on the loaded u64, so it
only reads the state field.  R127.M3 reinterprets the high 32 bits
as `raw_mode_flags`.  The split is still "one u64 at +40, low half
state, high half flags"; the swap of what the high half MEANS is a
semantic retitling, not a layout change.

```
  [+40]  state (u32)         low  32 bits   SS_STATE_*  (unchanged)
  [+44]  raw_mode_flags (u32) high 32 bits   NEW (R127.M3)
```

The documentary offset symbol `SS_OFF_RAW_FLAGS = 44` is defined for
future readers; the actual read-modify-write happens on the full u64
at `[+40]` so no new 32-bit store encoding is required.

### 2.1 Flag bits

Three flag bits are defined; the rest of the 32-bit field is
reserved-must-be-zero at set time:

```
  bit 0  SS_RAW_FLAG_RAW_MODE   raw mode   (bypass line discipline)
  bit 1  SS_RAW_FLAG_NO_ECHO    suppress ECHO (do not echo input bytes)
  bit 2  SS_RAW_FLAG_NO_CBREAK  disable cbreak (deliver bytes immediately,
                                 do not wait for a newline before completing a line)

  SS_RAW_FLAGS_VALID = 0x07   -- subset gate; any other bit = SS_RAW_ERR_BAD_FLAGS
```

Legal combinations:

* `0` — cooked mode (the current global default; set by zero-init at
  mint time so a freshly-created row is cooked).
* `0x07 (RAW_MODE | NO_ECHO | NO_CBREAK)` — a canonical "full raw"
  posture; what a TUI editor flips to.
* `0x02 (NO_ECHO alone)` — password prompt: still line-canonical, but
  silent.
* Any other bit combination in `[0x01..0x07]` is accepted but has
  undefined ldisc semantics until the TTY-side wave lands.  M3 enforces
  only "no reserved bits set".

### 2.2 Why three bits, not one

A single raw/cooked flag collapses three orthogonal behaviours.  A
password prompt (`NO_ECHO` without `RAW_MODE`) is still line-canonical
— the ENTER key still terminates the line and the shell still reads
one complete line at a time.  An editor (`RAW_MODE | NO_ECHO |
NO_CBREAK`) wants all three.  A command that just suppresses echo
during paste wants only `NO_ECHO`.  The three bits map to the three
POSIX termios bits that programs actually touch (ICANON ↔ RAW_MODE,
ECHO ↔ NO_ECHO, VMIN=1/VTIME=0 ↔ NO_CBREAK) and keep the choice
explicit at the cap-invoke boundary.

## 3 Direct-call API

### 3.1 `_shell_session_set_raw(session_id, flags) -> errno`

```
  rdi = session_id        -- in [0, SS_POOL_MAX = 8)
  rsi = flags             -- in [0, SS_RAW_FLAGS_VALID = 7]

  rax = SS_RAW_OK (0)              on success
      | SS_ERR_BAD_ID    (0x1102)  bad session_id OR row free
      | SS_RAW_ERR_BAD_FLAGS (0x1105) flags has a reserved bit set
```

Steps:

1. `ss_row_in_use(session_id)` — else SS_ERR_BAD_ID.
2. `flags <= 7` — else SS_RAW_ERR_BAD_FLAGS.
3. `row_base = pool + session_id << 7`.
4. Read-modify-write `[row+40]`: preserve low 32 (state), write high 32
   = flags.  Same shape as `_shell_session_set_state`'s preservation
   of the high 32 bits.
5. Bump `SS_ST_RAW_OK`; emit `SHELL_SESSION RAW OK sid=<hex> flags=<dec>`.
6. Return SS_RAW_OK.

Stack discipline (parallel to `_shell_session_set_state`): 2 callee-save
pushes (rbx = session_id, r12 = flags) + sub rsp, 8 (held throughout
the body — doubles as the klog_s1_x1_d1 stack-arg slot).  Entry
rsp%16==8; +2 pushes +8 = +24 → rsp%16==0 at every nested call.

### 3.2 `_shell_session_get_raw(session_id) -> flags | SS_ERR_BAD_ID`

```
  rdi = session_id

  rax = flags (0..7)   on live row
      | SS_ERR_BAD_ID (0x1102)   on bad id / free row
```

Pure read of the high 32 bits of `[row+40]`.  Shape mirrors
`ks_op_read_state`.  1 callee-save push (rbx = session_id) — entry
rsp%16==8; +1 push → %16==0 at every nested call.

Intended consumer: a session-aware TTY ldisc path (§6).  Not called
by any production kernel path in M3.

## 4 Cap-invoke op

### 4.1 `KS_OP_SET_RAW = 4`

* Rights: `R_KS_LIFECYCLE` (0x004).  A narrowed child cap that drops
  LIFECYCLE cannot flip raw mode.  This is deliberate: raw mode is a
  session-wide policy flip, not a per-op observation, and lives in
  the same rights class as DESTROY (which also lands under
  R_KS_LIFECYCLE in a future milestone).
* Payload:
  * `target_ptr[15:0] = session_id`
  * `target_ptr[63:16]` reserved (must be zero at mint; dispatcher
    does not re-check — the shell_session row id is 0..7, so the mint
    helper already enforced zero in the high 48).
  * `op_arg[7:0]  = op ordinal (4)`
  * `op_arg[15:8] = flags (0..7)`
  * `op_arg[63:16]` must be zero (dispatcher: `shr r10, 16; cmp r10, 0;
    jne ks_hn_bad_op`).
* Return (band at `cap/kind_shell_session.pdx` §6):
  * `KS_OK`
  * `KS_ERR_BAD_SESSION` — row free OR bad session_id
  * `KS_ERR_BAD_OP` — reserved bits non-zero OR flags out of range
  * `KS_ERR_RIGHTS` — caller lacks R_KS_LIFECYCLE

### 4.2 Return-code translation

```
  _shell_session_set_raw return    cap-invoke return
  -------------------------------- -------------------
  SS_RAW_OK (0)                 -> KS_OK
  SS_ERR_BAD_ID (0x1102)        -> KS_ERR_BAD_SESSION (0x1110)
  SS_RAW_ERR_BAD_FLAGS (0x1105) -> KS_ERR_BAD_OP (0x1111)
  (other non-zero, defensive)   -> KS_ERR_BAD_SESSION
```

Mirrors the `SET_STATE` translation exactly.

### 4.3 Dispatch arm shape

`cap_handler_shell_session` ladder gains one more entry:

```
  cmp r10, 4;
  je  ks_hn_op_set_raw;
```

Op bounds check bumped from `cmp r10, 3; ja ks_hn_bad_op` to
`cmp r10, 4; ja ks_hn_bad_op` via `KS_OP_MAX = 4` constant.

Handler block:

```
ks_hn_op_set_raw:
  // Rights gate: R_KS_LIFECYCLE (0x004).
  mov r10, rbx; and r10, 0x004;
  cmp r10, 0; je ks_hn_bad_rights;

  // op_arg[63:16] must be zero.
  mov r10, r13; shr r10, 16;
  cmp r10, 0; jne ks_hn_bad_op;

  // Decode sid, flags.
  mov rdi, r12; call ks_decode_sid;
  mov r11, rax;
  mov r10, r13; shr r10, 8; and r10, 0xFF;

  // Delegate.
  mov rdi, r11; mov rsi, r10; call ks_op_set_raw;
  jmp ks_hn_fp_ok;
```

## 5 Fingerprints

```
  SHELL_SESSION RAW OK   fires from _shell_session_set_raw success tail
                          (klog_s1_x1_d1, sid in hex, flags in dec)

  SHELL_SESSION RAW REJ  fires from _shell_session_set_raw bad-id / bad-flags
                          (klog_s1_x1, errno in hex)
```

The REJ tag has no bare word "OK" so the fingerprint-coverage gate
ignores it (same posture as every other REJ tag in the shell_session
family).  Only RAW OK needs an allowlist entry.

Stats slots widened: `_shell_session_stats` grows `[u64; 8]` →
`[u64; 16]` to carry `SS_ST_RAW_OK = 8` and `SS_ST_RAW_REJ = 9`.
`ss_note`'s bounds check bumps `cmp rdi, 8` → `cmp rdi, 16`.
`_ks_stats` grows the same way to carry `KS_ST_SET_RAW_OK = 8`;
`ks_note` bounds check bumps correspondingly.

## 6 TTY-side ldisc flip — DEFERRED

Current state of the TTY line discipline (`src/kernel/core/tty/`):

* `line_buffer.pdx` holds a single 256-byte accumulator with head /
  complete / read_cursor — one global state, not keyed by session.
* `process_input.pdx` is the per-byte cooked-mode router (echo via
  uart_putc, append via tty_line_append, CR→LF translate, backspace
  erase, BEL on overflow).  Explicitly notes it "does NOT ... support
  raw mode (bypasses this routine entirely)."
* `read.pdx` is the cooked-mode reader — reads from the line buffer
  only when `_tty_line_complete == 1`.
* There is NO session_id or shell_session row id visible to any of
  these paths.  The UART ring is global; the line buffer is global.

Making line discipline session-aware is a non-trivial restructure:

1. Thread `tty_fd → session_id` lookup (via the shell_session row
   pool) into `tty_process_input` and `tty_read_try`.
2. In raw mode: skip the cooked-mode router entirely; deliver each
   byte to the reader without accumulating into the line buffer.
3. In no-echo mode: skip the `uart_putc(byte)` echo call inside the
   cooked-mode router.
4. In no-cbreak mode: let `tty_read_try` deliver bytes without
   waiting for `_tty_line_complete`.

Each of (2)–(4) is a localised but load-bearing change on an often-
exercised kernel path (every typed byte).  The restructure needs its
own wave with its own witness.

**Follow-up ticket to file**: R127.M4 "TTY ldisc raw-mode flip" —
make `tty_process_input` and `tty_read_try` session-aware, consulting
`_shell_session_get_raw(sid)` via a thin `_tty_find_session_for_fd(fd)`
helper.  Owns the actual bypass semantics for all three bits.

M3 therefore lands the SUBSTRATE (API + cap-invoke op + policy flags
+ fingerprints) but the global TTY line discipline remains unchanged.
A ring-3 caller that invokes `KS_OP_SET_RAW` today receives `KS_OK` and
the flags are persisted on the row, but the TTY still runs cooked
mode until R127.M4 lands.  Allowlist entry for `SHELL_SESSION RAW OK`
is scoped to retire when R127.M4 lands with a smoke-mode golden
exercising the end-to-end flip.

## 7 Encoder-pitfall posture

Per `feedback_pdx_encoder_pitfalls`:

* `cmp rN, 0` never `test rN, rN`.
* `shl rax, 7` for row stride (never `imul r, imm`).
* `mov rax, imm32` for every error code — all three new codes
  (SS_RAW_OK = 0, SS_ERR_BAD_ID = 0x1102, SS_RAW_ERR_BAD_FLAGS =
  0x1105) fit imm32 with bit 31 clear.
* `[u8; N]` fingerprint tags with `N = len(string) + 1` (NUL counts):
  `SHELL_SESSION RAW OK` = 20 chars → N=21; `SHELL_SESSION RAW REJ`
  = 21 chars → N=22.
* Single-line `pub let` declarations.
* Module basename match: unchanged.

Stack discipline (SysV, entry rsp%16==8):

* `_shell_session_set_raw`: 2 pushes (rbx, r12) + sub rsp, 8  (held;
  doubles as klog_s1_x1_d1 stack arg).
* `_shell_session_get_raw`: 1 push (rbx).
* `ks_op_set_raw`: 2 pushes (rbx, r12) + sub rsp, 8 pad.

Labels prefixed `ss_sr_` (shell_session set_raw), `ss_gr_` (get_raw),
`ks_sr_` (kind_shell_session set_raw helper), `ks_hn_op_set_raw`
(dispatcher arm).

## 8 Band audit (2026-10-13)

```
  grep -rnE "0x1105\b" src/kernel/ 2>/dev/null  -> zero hits
  grep -rnE "0x1113\b" src/kernel/ 2>/dev/null  -> zero hits in SS band
```

SS band at R127.M1: 0x1101..0x1104 pinned, 0x1105..0x110F free.  M3
claims 0x1105.  KS band at R127.M2: 0x1110..0x1113 pinned, 0x1114..
0x111F free.  M3 does NOT extend KS; it reuses `KS_ERR_BAD_SESSION`
and `KS_ERR_BAD_OP` for the set_raw translation.

## 9 Boot wiring

No new boot calls.  `_shell_session_init` already fires at the same
place in `kernel_main.pdx`; `kind_shell_session_init` is still unwired
(R127.M2 landed the helper but didn't call it from kernel_main — a
separate R127.M4 cleanup can wire it when the TTY-side flip wave adds
its witness).

## 10 Cross-references

* `src/kernel/core/svc/shell_session.pdx` — R127.M1 row + direct API
* `src/kernel/core/cap/kind_shell_session.pdx` — R127.M2 cap-invoke
* `design/shell/shell-session-daemon.md` — R127.M1 design
* `design/shell/kind-session.md` — R127.M2 design
* `src/kernel/core/tty/` — ldisc substrate (R16.M5)
* `feedback_pdx_encoder_pitfalls` — encoder posture
