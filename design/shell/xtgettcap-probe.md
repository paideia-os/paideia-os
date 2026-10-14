# XTGETTCAP terminal-capability probe (R129.M1)

Issue: paideia-os#2604
Wave:  UMB-W15
Lands: 2026-10-13

## 1 Why

PaideiaOS inherits a seat at the serial console the moment the kernel
unmasks IRQ 4.  What it inherits is a *byte pipe* -- a stream in and
out of a terminal emulator that may be anything from the minimal
pre-boot EFI firmware console to a modern wezterm, kitty, or alacritty
window hosting megapixel truecolor and kitty-graphics inline images.

The byte pipe says nothing about which end can do what.  If a GPU-
native paint call wants to pick between truecolor (24-bit) and 256-
colour palette, if a semantic-table renderer wants to decide between
line-drawing graphemes and raw ASCII, if a progressive-reveal animator
wants to query whether the emulator supports synchronised updates
(DECSET 2026), there is no way to tell except to ASK the far end.

xterm answered that fifteen years ago with
*XTGETTCAP* -- a Device Control String (DCS) that the terminal
treats as a termcap/terminfo lookup and replies to with a key=value
response in the same wire envelope.  Every mainstream Linux terminal
emulator today speaks it: xterm, konsole, iTerm2, kitty, wezterm,
foot, alacritty (through its termcap pass-through), ghostty.

R129 is the paideia-os umbrella for terminal-capability probing.  M1
lands the kernel-side helper that emits a probe sequence on a TTY,
drains the response from the UART rx ring under a bounded deadline,
parses the DCS envelope, and hands back a decoded value byte slice.

## 2 Wire protocol

The DCS envelope and selector are fixed; only the capability name
inside varies.

### 2.1 Query (host -> terminal)

```
  ESC P + q <cap-name-hex> ESC '\'
```

where

* `ESC`          = 0x1B
* `P`            = 0x50  (DCS introducer)
* `+ q`          = 0x2B 0x71  (xterm `GetTermcap/Terminfo` selector)
* `cap-name-hex` = ASCII capability name, each byte encoded as two
                   uppercase hex digits (e.g. `TN` -> `544E`)
* `ESC '\'`      = 0x1B 0x5C  (String Terminator / ST)

Example: querying `TN` (terminal name)

```
  1B 50 2B 71 54 4E 1B 5C
```

### 2.2 Response (terminal -> host)

```
  ESC P 1 + r <cap-name-hex> '=' <value-hex> ESC '\'    -- cap known
  ESC P 0 + r <cap-name-hex>              ESC '\'       -- cap unknown
```

The second byte of the DCS (position 2 of the response) carries a
*validity flag*: `1` (0x31) if the cap is known, `0` (0x30) if not.
The marker byte flips from `q` (query) to `r` (reply).  On a `1`-flag
response, the value is itself hex-encoded (so binary values, like
raw escape sequences in the `smcup`/`rmcup` entries, round-trip
through the ASCII envelope).

Example: wezterm's reply to the `TN` query above might be

```
  1B 50 31 2B 72 54 4E 3D 78 74 65 72 6D 1B 5C
   ESC  P '1'  +  'r' 'T' 'N' '='  x  t  e  r  m ESC  \
```

decoding to `TN=xterm`.

## 3 Supported caps at M1

M1 ships with hand-coded support (i.e. kernel callers know how to
*ask* and what the decoded answer *means*) for exactly four caps:

| Cap  | Semantics                            | Expected value         |
| ---- | ------------------------------------ | ---------------------- |
| `TN` | Terminal name                        | ASCII identifier       |
| `Co` | Number of displayable colours        | ASCII decimal (`8`..`16777216`) |
| `RGB`| 24-bit truecolor present             | ASCII decimal `8` (bits per channel) when supported, missing otherwise |
| `Tc` | Truecolor second query (fallback)    | Present when supported |

The probe helper itself is agnostic: the caller passes whatever cap
name it wants to query and the helper hands back the raw decoded
bytes.  The caps above are simply the ones R129.M2+ callers will
invoke; adding another is a one-line change at the call site.

## 4 Interaction with raw mode (R127.M3)

The DCS response can arrive at any time after the query is sent.
Under cooked mode (ICANON + ECHO + ICRNL + ONLCR, the current global
default) the response bytes are fed through `tty_process_input`:

* The response contains no `\r` or `\n`, so ICRNL is a no-op.
* ECHO is a problem: the terminal will see its own bytes echoed back
  on the TX line, and some emulators react to that by re-interpreting
  them as another query, racing their own buffer.
* ICANON is the hard failure: the response bytes get appended into
  `_tty_line_buf` and sit there until the user presses Enter.  No
  trailing `\n` means `_tty_line_complete` never flips, and
  `tty_read_try` reports empty forever.

R127.M3 (Wave UMB-W14, paideia-os#2599) stamped a per-shell-session
`raw_mode_flags` field at `shell_session[+44]` with three bits:

```
  bit 0  SS_RAW_FLAG_RAW_MODE
  bit 1  SS_RAW_FLAG_NO_ECHO
  bit 2  SS_RAW_FLAG_NO_CBREAK
```

The probe REQUIRES bit 0 to be set on the current shell session for
reliable operation.  The exact mechanism of the flip -- i.e. the
`tty_process_input` fast path that short-circuits ICANON+ECHO when
the current session's raw_mode is on -- is a separate wave (R127.M4,
not yet filed); until then the probe will work on a tree with no
competing `tty_read` call in flight (the common case during early
boot or inside a benchmark harness) because bytes land in
`_uart_rx_ring` from the ISR and the probe drains them directly.

### 4.1 M1 flow in prose

```
  1. Caller calls _shell_session_set_raw(sid, SS_RAW_FLAG_RAW_MODE)
     via the KS_OP_SET_RAW cap-invoke op.
  2. Caller calls _xtgettcap_probe(tty_fd, cap_ptr, cap_len,
                                     out_ptr, out_cap).
  3. Probe emits the DCS query, byte by byte, through uart_putc.
  4. Probe polls uart_rx_dequeue() in a bounded TSC loop (see §5).
  5. On the ESC '\' terminator, probe parses the envelope and
     hex-decodes the value segment into out_ptr (clamped to out_cap).
  6. Caller inspects (bytes_written, status) and decides whether to
     act on the decoded value.
  7. Caller calls _shell_session_set_raw(sid, 0) to restore cooked.
```

Step 7 is the caller's responsibility; the probe does NOT touch the
raw-mode flag.  A caller that forgets to restore cooked mode leaves
the shell in a usability-hostile state (echo off, no line editing).

## 5 Timeout policy

### 5.1 Budget

**100 ms** -- the xterm-community-recommended ceiling for XTGETTCAP
round-trip under direct serial attach.  Over nested PTY the number
can balloon to ~300 ms; at that point the probe is useful only
during a quiescent REPL idle, and we treat the ceiling as a tunable
in a later wave.

A terminal that does not answer within 100 ms is treated as "does
not implement this cap", not as a hard failure.  The caller's
disposition is: pick a safe conservative default (`Co=8`, no RGB,
etc.) and move on.

### 5.2 Mechanism

The deadline is implemented in TSC cycles, not in iteration counts.
This is deliberate:

* TSC is monotonic across the entire post-boot kernel epoch (modulo
  SMP migration, which R129.M1 does not care about because the probe
  pins its logical thread to the current core for the duration of
  the call -- a one-shot blocking helper).
* `_tsc_hz` is populated by `tsc_calibrate` very early in boot
  (`R21-M5-002`, kernel-main sequence before shell init), so a probe
  called from any live shell session has a calibrated clock.
* Iteration counts drift with CPU frequency scaling (not yet wired
  up in paideia-os, but trivially will be).  Cycle counts don't.

Pseudocode:

```
  cycles = _xt_timeout_cycles()      // = _tsc_hz / 10 (= 100 ms)
                                     //   or XT_FALLBACK_POLL_CAP if
                                     //   _tsc_hz is 0
  deadline = kread_tsc() + cycles

  resp_len = 0
  loop:
    byte = uart_rx_dequeue()
    if byte == DEQUEUE_EMPTY (0xFFFF):
      if kread_tsc() >= deadline:
        if resp_len == 0:
          return (0, XT_ERR_NO_RESPONSE)
        else:
          return (0, XT_ERR_TIMEOUT)
      continue
    _xt_resp_buf[resp_len++] = byte
    if resp_len >= 2
       and _xt_resp_buf[resp_len-2] == ESC
       and _xt_resp_buf[resp_len-1] == ST:
      break
    if resp_len == XT_RESP_MAX:
      return (0, XT_ERR_MALFORMED)
```

### 5.3 Fallback

If `_tsc_hz == 0` -- i.e. calibration bailed, which can happen on
very early boot or on QEMU configurations where the PM_TMR window
overshoots -- the helper falls back to `XT_FALLBACK_POLL_CAP` =
1e8 TSC cycles.  At ~3 GHz this is ~33 ms, well under the 100 ms
budget; the point is to keep the probe bounded rather than infinite.

### 5.4 TSC vs. interrupt

An interrupt-driven variant (ldisc notifies the probe via a futex-
like primitive, probe sleeps until data arrives or a oneshot timer
fires) is cleaner but much heavier to land:

* needs a per-session completion object
* needs a tsc_deadline timer slot allocated for the oneshot
* needs the ldisc fast path to recognise raw-mode and route bytes to
  the probe instead of _tty_line_buf
* needs sched_block / sched_wake plumbing specific to this helper

M1 skips all of that for a plain busy-poll.  The 100 ms budget is
cheap enough that even if the probe never finds its answer, the
caller just paid 100 ms once per session for cap discovery, which
is negligible compared to the shell startup envelope.  R129.M3+
can rewire to the interrupt path once the ldisc raw-mode fast path
lands under R127.M4.

## 6 Return packing

The helper returns a single u64 shaped as

```
   63                            32 31                            0
  +-------------------------------+------------------------------+
  |         bytes_written         |            status            |
  +-------------------------------+------------------------------+
```

* **bytes_written** -- the number of decoded value bytes written to
  `out_ptr`, clamped to `out_cap`.  Zero on error paths and on the
  cap-unknown success path.
* **status** -- one of

  | Value   | Symbol              | Meaning                                   |
  | ------- | ------------------- | ----------------------------------------- |
  | 0x0000  | XT_OK               | round-trip complete; value written if any |
  | 0x1400  | XT_ERR_NO_RESPONSE  | 100 ms elapsed with zero bytes received   |
  | 0x1401  | XT_ERR_MALFORMED    | response arrived but envelope invalid     |
  | 0x1402  | XT_ERR_TIMEOUT      | partial response, no ST terminator in time|

The 0x14xx band is otherwise unused and leaves room for
`XT_ERR_BAD_CAP`, `XT_ERR_BAD_FD`, etc. at R129.M2+.

A caller treats both XT_OK with bytes_written == 0 (cap unknown by
terminal) and XT_ERR_NO_RESPONSE (terminal silent) as "cap not
available"; it treats XT_ERR_MALFORMED as a protocol-level error
worth a one-time klog warning (not implemented at M1).

## 7 Non-reentrancy

The probe owns a single 256-byte static buffer (`_xt_resp_buf`) that
backs both the TX hex-encoded cap name and the RX response collector.
A second concurrent probe would corrupt this slab.

At M1 this is correct: there is one shell session, and the probe is
invoked synchronously from its REPL between commands.  R129.M2+ (per-
session probe) will move the slab onto the caller's stack or into a
per-session scratch slot carved from the shell_session row's reserved
tail.

The non-reentrancy is documented at the top of the module and the
helper does NOT guard against it with a lock -- the invariant is a
discipline, not a mechanism.

## 8 Supported encoder subset

The module uses only paideia-as mnemonics proven at prior landings:

```
  mov, mov_b, lea, add, sub, and, or, xor, shl, shr, cmp,
  je, jne, jb, jbe, ja, jae, jmp, call, ret,
  push, pop, rdtsc,  div, in_al, out_al
```

Explicitly avoided (per the recurring pdx encoder pitfall memo):

* `test rN, rN`                 -> replaced with `cmp rN, 0; j{e,ne}`
* 2-op `imul rN, imm`           -> not used (no multiply path)
* `and rN, imm64`               -> all masks fit in imm32 or imm8
* multiline `pub let = "..."`   -> every declaration single-line
* `mov rN, rip + sym`           -> every RIP-relative load is
                                   `lea rN, [rip + sym]` or
                                   `mov rN, [rip + sym]`

Module basename `Xtgettcap` matches the file name `xtgettcap.pdx`.
Label discipline: four prefixes keep the namespaces non-colliding
across sibling modules.

```
  xhe_     _xt_hex_encode
  xhd_     _xt_hex_decode
  xt_tc_   _xt_timeout_cycles
  xtp_     _xtgettcap_probe
```

None of these clash with pdx-level reserved keywords (`loop`, `if`,
`let`, `fn`, `else`, `return`, `module`, `pub`, ...).

## 9 Scope boundaries

### 9.1 M1 does NOT

* dispatch on `tty_fd`.  The parameter is accepted and ignored;
  every TX byte goes to `uart_putc`, every RX byte comes from
  `uart_rx_dequeue`.
* flip raw mode on behalf of the caller.
* retry on `XT_ERR_MALFORMED`.
* log fingerprints.  The probe is silent on the wire; a caller that
  wants a trace can wrap the call in its own klog.
* defend against concurrent probes (see §7).
* parse the cap-echo prefix of the response (bytes 5..`=`).  A
  future wave may compare the echoed cap name against the request
  for an extra sanity check.
* support non-M1 caps.  The helper is cap-agnostic; the test is
  "did the hex-decode succeed".

### 9.2 Follow-up tickets

* R129.M2 -- fd dispatch; vops-level TX/RX route (lets a second
  TTY, e.g. a secondary serial or a kitty PTY, be probed).
* R129.M3 -- interrupt-driven variant on top of the R127.M4 ldisc
  raw-mode fast path.
* R129.M4 -- cap discovery cache: lazy-populated per-session table of
  "do we know this cap already, don't re-probe".
* R127.M4  -- ldisc raw-mode fast path (the actual flip that makes
  the probe reliable under a live shell).

## 10 Reference wire example

A probe for `Co` against wezterm (COM1 attached via `-serial stdio`):

```
TX (host -> terminal):
  1B 50 2B 71 43 6F 1B 5C

RX (terminal -> host, approx 2-15 ms later):
  1B 50 31 2B 72 43 6F 3D 31 36 37 37 37 32 31 36 1B 5C
```

decoding to `Co=16777216` (24-bit truecolor).

Caller sees:
* `out_ptr[0..8]` = `"16777216"` (ASCII)
* return = `(8 << 32) | XT_OK` = `0x0000000800000000`

The caller then parses the ASCII integer at its own layer and
decides, say, that it can freely emit `ESC [ 38 ; 2 ; r ; g ; b m`
sequences in subsequent paint calls.
