---
issue: 1998
milestone: R90-XREPO
subsystem: cap / drivers / tty
topic: KIND_TTY control surface — ops, rights, mode_flags layout, witnesses
touching:
  - src/kernel/core/cap/kind_tty.pdx
  - src/kernel/boot/witness/r66v2_tty_raw.pdx   (#1987)
  - src/kernel/boot/witness/r90_tty_termios.pdx (#1998, this issue)
  - src/kernel/boot/kernel_main.pdx             (witness wiring)
prereqs:
  - "#1631 (R30-PREP KIND_TTY substrate) — LANDED"
  - "#1986 (R66v2.POS-001 TTY_OP_READ + SET_RAW/SET_COOKED) — LANDED"
  - "#1987 (R66v2.POS-002 raw-mode round-trip witness) — LANDED"
consumers:
  - "doc.ENH-024 (satellite repo doc): pager needs echo-off + VMIN=1 + VTIME=0"
  - "shell.ENH-034 (satellite repo shell): line editor needs same + cursor-key parsing"
related:
  - design/tooling/r49-r50-plan.md §5 (original KIND_TTY substrate motivation)
  - src/kernel/core/klog/keys.pdx §tag_tty_read_ok / §tag_tty_mode_ok
---

# KIND_TTY — capability-side terminal sink

## 1. Purpose

`KIND_TTY = 0x197` is the cap-side runtime authority for one TTY
sink -- a terminal instance that accepts byte writes and reports its
row/column dimensions. Deriving over `KIND_IPC_ENDPOINT` (5) matches
the client-of-a-server shape the R49/R50 shell / cat / ls tools
expressed via `svc_lookup` on the tty server's registered name.

This document is the reference for the current op table, rights,
mode_flags layout, and boot witnesses. It supersedes the ad-hoc
splinters that had accumulated in kernel-side per-issue design notes
under `design/kernel/r16-m5-*` (which describe the *vops* layer,
below KIND_TTY) and `design/round-retrospectives/r66-closure.md`
(which was the R66v2 landing note only).

## 2. Rights

| Const           | Bit    | Confers                                                            |
|-----------------|--------|--------------------------------------------------------------------|
| `R_TTY_WRITE`   | 0x002  | `TTY_OP_WRITE` (bumps `bytes_written`, ret 0 at this landing)      |
| `R_TTY_INVOKE`  | 0x008  | Query ops (rows/cols/id/bytes) + mode-toggle + termios control     |
| `R_TTY_REVOKE`  | 0x010  | `tty_cap_revoke` — teardown the row                                |
| `R_TTY_READ`    | 0x080  | `TTY_OP_READ` — single-byte poll of raw UART RX ring (#1986)       |
| `R_TTY_MINT`    | 0x200  | Derive a narrower child (per-line / per-region — R49.M2)           |
| `R_TTY_OBSERVE` | 0x400  | `TTY_OP_DEBUG_PRINT`                                               |
| `R_TTY_ALL`     | 0x69A  | Union of the above                                                 |

`R_TTY_READ` is intentionally distinct from `R_TTY_INVOKE`: reading
keystrokes off the terminal input is a different authority from
reading the sink's own metadata (rows / cols / id / bytes_written).
A shell-child-process cap typically holds `R_TTY_WRITE` only and
cannot read the terminal back.

The termios control surface (echo, VMIN, VTIME, GET_ATTR) sits under
`R_TTY_INVOKE`: manipulating the sink's own line discipline is the
same authority as reading its own metadata, and neither implies
authority to read terminal input.

## 3. Op table

`op = op_arg & 0xFF`.

| Op                     | # | Rights needed    | Arg encoding                            | Returns                                          |
|------------------------|---|------------------|-----------------------------------------|--------------------------------------------------|
| `TTY_OP_WRITE`         | 0 | `R_TTY_WRITE`    | arity-one                               | 0 (bumps `bytes_written`)                        |
| `TTY_OP_QUERY_ROWS`    | 1 | `R_TTY_INVOKE`   | arity-one                               | rows                                             |
| `TTY_OP_QUERY_COLS`    | 2 | `R_TTY_INVOKE`   | arity-one                               | cols                                             |
| `TTY_OP_QUERY_ID`      | 3 | `R_TTY_INVOKE`   | arity-one                               | `tty_id`                                         |
| `TTY_OP_QUERY_BYTES`   | 4 | `R_TTY_INVOKE`   | arity-one                               | `bytes_written`                                  |
| `TTY_OP_DEBUG_PRINT`   | 5 | `R_TTY_OBSERVE`  | arity-one                               | 0                                                |
| `TTY_OP_READ`          | 6 | `R_TTY_READ`     | arity-one                               | byte 0..255, or `TTY_READ_EMPTY` (0xFFFFEC35)    |
| `TTY_OP_SET_RAW`       | 7 | `R_TTY_INVOKE`   | arity-one                               | 0 (mode_flags bit 0 := 1; emits `tag_tty_mode_ok`) |
| `TTY_OP_SET_COOKED`    | 8 | `R_TTY_INVOKE`   | arity-one                               | 0 (mode_flags bit 0 := 0; emits `tag_tty_mode_ok`) |
| `TTY_OP_SET_ECHO_ON`   | 9 | `R_TTY_INVOKE`   | arity-one                               | 0 (mode_flags bit 1 := 1)                        |
| `TTY_OP_SET_ECHO_OFF`  |10 | `R_TTY_INVOKE`   | arity-one                               | 0 (mode_flags bit 1 := 0)                        |
| `TTY_OP_GET_ATTR`      |11 | `R_TTY_INVOKE`   | arity-one                               | packed `mode_flags` word (§4)                    |
| `TTY_OP_SET_VMIN`      |12 | `R_TTY_INVOKE`   | value in `op_arg[15:8]`; bits 16..63 = 0 | 0 (mode_flags bits 8..15 := value)               |
| `TTY_OP_SET_VTIME`     |13 | `R_TTY_INVOKE`   | value in `op_arg[15:8]`; bits 16..63 = 0 | 0 (mode_flags bits 16..23 := value)              |

`TTY_OP_MAX = 13`.

### 3.1 Arg encoding

Ops 0..11 are strictly arity-one: any nonzero high bits of `op_arg`
are refused with `TTY_TAIL_BAD_ARG` (0xFFFFEC3E). Ops 12..13 encode
a byte value in bits 8..15 and additionally refuse bits 16..63; these
two ops are dispatched *before* the arity-one gate in `cap_handler_tty`
so the gate itself stays a plain "any high bit refused" check for the
other ops.

This asymmetric shape avoids expanding the `op_arg` grammar for the
whole op table (which would silently unpin every existing caller's
input validation) while still fitting the two termios ops that need
a value in one word.

### 3.2 Common failure codes

`0xFFFFEC30..0xFFFFEC3F` — one 16-wide band, disjoint from every
other R48b kind:

| Code       | Name                     |
|------------|--------------------------|
| 0xFFFFEC3F | `TTY_TAIL_ENOSPC`        |
| 0xFFFFEC3E | `TTY_TAIL_BAD_ARG`       |
| 0xFFFFEC3D | `TTY_MINT_BAD_PARENT`    |
| 0xFFFFEC3C | `TTY_MINT_BAD_RIGHTS`    |
| 0xFFFFEC3B | `TTY_MINT_BAD_ID`        |
| 0xFFFFEC3A | `TTY_MINT_BAD_ROWS`      |
| 0xFFFFEC39 | `TTY_MINT_BAD_COLS`      |
| 0xFFFFEC38 | `TTY_BAD_SLOT`           |
| 0xFFFFEC37 | `TTY_WRONG_KIND`         |
| 0xFFFFEC36 | `TTY_REVOKE_ALREADY`     |
| 0xFFFFEC35 | `TTY_READ_EMPTY`         |

## 4. `mode_flags` layout

The row's `mode_flags` word (offset +40, tail encoding) is the
termios-equivalent packed line-discipline state. Zero at mint, so
every freshly-minted sink defaults to *cooked / echo-off / VMIN=0 /
VTIME=0*.

| Bits    | Field             | Set by                          | Read by                       |
|---------|-------------------|---------------------------------|-------------------------------|
| 0       | raw (1) / cooked (0) | `TTY_OP_SET_RAW`/`SET_COOKED` (#1986) | `TTY_OP_GET_ATTR` / `tty_row_mode` |
| 1       | echo on (1) / off (0) | `TTY_OP_SET_ECHO_ON`/`SET_ECHO_OFF` (#1998) | ditto             |
| 2..7    | reserved          | —                               | —                             |
| 8..15   | VMIN (0..255)     | `TTY_OP_SET_VMIN` (#1998)       | ditto                         |
| 16..23  | VTIME (0..255) — POSIX deciseconds | `TTY_OP_SET_VTIME` (#1998) | ditto                    |
| 24..63  | reserved          | —                               | —                             |

Callers should treat the word as opaque and manipulate it via the
op table above; never encode bit offsets on the user side. The
internal helpers (`tty_row_mode_echo_set`, `tty_row_mode_vmin_set`,
`tty_row_mode_vtime_set`) all do a plain read-modify-write with an
inline mask, and there is no read-modify-write tear window because
`cap_handler_tty` is the only external gateway and its branches are
serialised by the caller.

## 5. Motivating consumers

| Consumer                    | Needs                                                                 |
|-----------------------------|-----------------------------------------------------------------------|
| `doc` pager (doc.ENH-024)   | `SET_RAW` + `SET_ECHO_OFF` + `SET_VMIN=1` + `SET_VTIME=0`             |
| `shell` line editor (shell.ENH-034) | Same, plus `SET_ECHO_ON` re-armed after the raw read for typed chars |
| `cat`, `ls` (R49/R50 tools) | `TTY_OP_WRITE` only — no changes here                                 |

Both interactive consumers use the same three-op preamble to enter
non-canonical mode (SET_RAW / SET_ECHO_OFF / SET_VMIN=1) and the
matching restore (SET_ECHO_ON / SET_COOKED). VTIME is stored but
not yet honoured by the READ path -- see §7.

## 6. Boot witnesses

Two witnesses fire in `kernel_main.pdx`'s `boot_continue_after_ring3`
cascade, in this order:

| Witness                    | Issue | Fingerprint                                | Proves                                                                                     |
|----------------------------|-------|--------------------------------------------|--------------------------------------------------------------------------------------------|
| `witness_r66v2_tty_raw`    | #1987 | `boot tty raw ok -- bytes=3`               | Three-byte ring-drain baseline via `SET_RAW` + three `TTY_OP_READ` + `TTY_READ_EMPTY` on drain |
| `witness_r90_tty_termios`  | #1998 | `boot tty termios ok -- attr=0x140500`     | Termios control surface (echo, VMIN, VTIME, GET_ATTR) + single-keypress raw-mode read       |

Neither fingerprint carries an uppercase `OK` token, so
`tools/verify-fingerprint-coverage.sh`'s `OK_TOK` extractor
does not treat them as markers requiring golden coverage or an
allowlist entry -- same posture as `tag_tsc_narrative`
(`core/time/tsc.pdx`) and the raw-mode witness that preceded this
one.

The `attr` value in #1998's fingerprint is the `mode_flags` word
captured at Stage 7 (after Stages 3..6 landed and before SET_RAW):
`0x140500` = VTIME 0x14 (20 decisec) | VMIN 0x05 | echo 0 | raw 0.
A future perturbation that mis-shifts SET_VMIN or SET_VTIME would
produce a wrong hex here, and any mode that pins the exact line
would catch it.

## 7. Deferred sub-scopes

`#1998` explicitly ships storage + round-trip semantics for the
termios ops; two follow-ups are noted in `kind_tty.pdx` Section 1b
as well:

* **VTIME timer wiring.** VTIME is stored by `SET_VTIME` and
  readable via `GET_ATTR`, but the `TTY_OP_READ` path does not yet
  arm a per-read timer that would return `TTY_READ_EMPTY` after
  VTIME deciseconds of idle. That needs scheduler-driven timeouts
  on the raw UART RX poll (a hook on the READ path calling into an
  eventual `sleep_until`/`wake_at` analogue). Landing that wiring
  is scoped as a follow-up once the scheduler exposes an
  absolute-deadline sleep primitive.

* **VMIN honoured by the READ path.** `TTY_OP_READ` is a single-byte
  poll at this landing; VMIN > 1 is stored but the READ handler
  still returns one byte at a time (or `TTY_READ_EMPTY`). A future
  multi-byte READ variant (or a batched loop inside the handler)
  is the real consumer of the stored VMIN value.

* **Cursor-key parsing hints.** Reserved bits 2..7 of `mode_flags`
  leave room for a parse-CSI-in-kernel flag (shell.ENH-034's line
  editor wants arrow-key -> cursor-move translation); not shipped
  in #1998 to keep the surface small enough to fit the current
  milestone.

None of these gaps blocks either motivating consumer's minimum
viable path: `doc`'s pager and `shell`'s line editor both need
`VMIN=1`/`VTIME=0` (single-byte immediate read), which the shipped
READ path already satisfies. The stored-but-unhonoured VMIN>1 and
VTIME>0 values give userspace a round-trip surface it can plumb
today, and remove the migration hazard of adding those fields to
the packed word later.
