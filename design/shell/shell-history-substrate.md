# Shell history storage substrate (R127.M4)

Issue: paideia-os#2600
Wave:  UMB-W15
Lands: 2026-10-13

## 1 Why

A REPL loop needs a bounded, in-kernel ring of the commands it has
dispatched. R127 originally reserved `history_head` + `history_tail`
fields in the shell_session row (R127.M1 §1) precisely so a later
milestone could land this. R127.M2 (KIND_SHELL_SESSION op surface) and
R127.M3 (raw-mode TTY substrate) finished the capability-shaped reach;
M4 lands the storage, the direct-call API, and three cap-invoke ops.

M4 keeps the TTY-side READLINE / up-arrow / Ctrl-R flow entirely out
of scope — R127.M5 (job control + the shell parent's actual dispatch
loop) is the first wave with a production caller. M4 is pure substrate:
the ring is populated and queryable, but no shipped command path writes
or reads it yet. The INIT fingerprint is the only reach R127.M4 adds
to the smoke-mode wire; APPEND / READ fingerprints trip only when the
dispatch loop that R127.M5 lands first drives a command through.

Design posture (feedback_novel_clean_design): the shell session, not
the file descriptor, owns the history anchor, exactly mirroring the
raw-mode flag landing (R127.M3). POSIX bash's per-shell `HISTFILE` is
retired in favour of a kernel-held ring whose only reach is through
the KIND_SHELL_SESSION cap.

## 2 Geometry

```
  per-entry stride  = 128 bytes                           (shl 7)
  per-session ring  = 128 entries x 128 bytes = 16 KiB    (shl 14)
  pool              = 8 sessions x 16 KiB    = 128 KiB
```

Backing storage: `_shell_history_rings : [u8; 131072]` in `.bss`,
@align(64) so the first ring (session 0) sits on a cache-line boundary
and session N's ring starts at `(N << 14)` from the pool base — no
`imul r, imm` is ever needed to address a slot.

### 2.1 Entry layout

```
  [+0]   len         (u16)   bytes-to-read in cmd_bytes (0 .. 126)
  [+2]   cmd_bytes   [u8; 126]  the command text (ASCII; terminator
                               is NOT stored — len is authoritative)
```

126 bytes is the hard cap at M4. Shells rarely emit a line that long
(the one-line pattern plus one or two args sits well under 100 bytes),
and the 126 clamp means every stride stays at a 128-byte power-of-two
for the encoder's `shl r, 7` idiom. An over-long command is truncated:
`len = 126`, `cmd_bytes[0..123]` = first 123 bytes of input,
`cmd_bytes[123..126]` = `"..."` (three ASCII `0x2E` bytes). The three
trailing bytes are the audit signal that truncation happened.

### 2.2 Ring semantics (invariant: `0 <= head - tail <= 128`)

`history_head` and `history_tail` on the shell_session row are u64
monotonic counters that NEVER wrap in realistic lifetime (2^64 ops at
1 GHz = 584 years). Slot indices are the low 7 bits:

```
  write_slot = history_head & 0x7F                       (shl 7 + add)
  read_slot(i_from_head) = (history_head - 1 - i) & 0x7F
```

Append semantics:

```
  entry[write_slot] <- {len, cmd}
  history_head += 1
  if (history_head - history_tail) > 128:
      history_tail = history_head - 128      // evict oldest
```

Count semantics:

```
  count = history_head - history_tail       // in [0, 128]
```

Note: after the first eviction, the ring holds exactly 128 entries;
`count` saturates at 128 regardless of how many more appends arrive.
Count is NOT (`head - tail) mod 128`, because the invariant above
already keeps `head - tail` in `[0, 128]`; the mod is a documentation
artifact for a reader who assumed wrap-based head/tail.

### 2.3 Alternatives considered

A wrap-based head/tail with a separate "full" flag was rejected
because the flag bit would consume one more u64 on each row and
complicate the eviction check (a two-field compare at every append).
A 127-element ring (sacrificing one slot for the `head == tail` empty
sentinel) was rejected because the task directive pins 128 slots.
The monotonic-counter design uses the full 128 slots AND keeps the
empty/full disambiguation implicit in the counter difference.

A per-entry linked list over a slab was rejected (R127 is substrate-
grade; a slab allocator with lineage tracking is a R128+ Phase-3
rewrite target per kind_shell_session.pdx §7). The fixed-geometry
ring is correctness-cheap: no allocator reach, no concurrent-free
hazard, and the entire pool scrubs in one `.bss` zero at boot.

## 3 Return band

```
  SH_OK                = 0
  SH_ERR_BAD_SESSION   = reuse SS_ERR_BAD_ID = 0x1102
  SH_ERR_OUT_TOO_SMALL = 0x1106
  SH_ERR_EMPTY         = 0x1107
```

Band audit at landing (2026-10-13):
`grep -rnE '0x110[6-7]\b' src/kernel/` -> zero hits in the production
tree. Clean band; R127.M5+ may extend to 0x1108..0x110F while
retaining the first two SH_* as pinned.

`SH_ERR_BAD_SESSION` deliberately aliases `SS_ERR_BAD_ID = 0x1102`
(R127.M1 band) so a caller may test either name — the two bands are
subsets of the shell-session namespace. The alias convention mirrors
R127.M3's `SS_RAW_ERR_BAD_SESSION`.

All fit imm32 with bit 31 clear so `mov rax, imm32` emits the 7-byte
zero-extending form.

### 3.1 Packed READ return

`_shell_history_read` returns a packed u64:

```
  result = (bytes_written << 32) | status
```

On success, `status == SH_OK (0)`, so `result == bytes_written << 32`
and the caller recovers `bytes_written` by right-shifting 32 bits.
`bytes_written` is in `[0, 126]`, so `bytes_written << 32` lies in
`[0, 126 << 32)` — disjoint from every `SH_ERR_*` value (all have
bits [31:0] in `[0x1102, 0x1107]` with bits [63:32] zero) so a caller
that treats the whole u64 as an error-or-length tagged value never
collides.

On error, `bytes_written = 0`, so `result == status`.

## 4 Public API

```
  _shell_history_init() -> ()
  _shell_history_append(session_id, cmd_ptr, cmd_len) -> errno
  _shell_history_read(session_id, index_from_head, out_ptr, out_cap)
                                                      -> packed u64
  _shell_history_count(session_id) -> count            // 0 on bad sid
```

### 4.1 `_shell_history_init`

Boot hook. Defensive scrub of `_shell_history_stats` (14 u64 slots
widened for future ops). `.bss` already zero-inits the ring at real
boot; the stats scrub covers a chaos-restart re-entry. Emits
`SHELL_HISTORY INIT OK` on completion. Signature `() -> ()` matches
`kind_shell_session_init` one-for-one.

Boot wiring: `src/kernel/boot/kernel_main.pdx`, immediately after
`_shell_session_init` (ENDPOINT 21). The pair lands as a two-step
cascade so an audit grep sees `SHELL_SESSION INIT OK` then
`SHELL_HISTORY INIT OK` in subsystem order.

### 4.2 `_shell_history_append`

Validates `session_id` via `ss_row_in_use`. Loads `history_head` /
`history_tail` from `[row + 24]` / `[row + 32]`. Clamps `cmd_len` to
126; on truncation also writes `cmd_bytes[123..126] = "..."` so the
audit tag is visible in a dumped ring. Byte-copies into the ring
entry, bumps `history_head`, evicts if `head - tail > 128`, writes
both counters back, emits `SHELL_HISTORY APPEND OK sid=0x<hex>
len=<dec>`.

Rights required at the cap-invoke surface: `R_KS_WRITE` — same class
as `KS_OP_SET_STATE`.

### 4.3 `_shell_history_read`

Validates `session_id`. Returns `SH_ERR_EMPTY` if `index_from_head >=
count`. Computes `read_slot = (head - 1 - index) & 0x7F`. Loads the
entry's `len` from `[entry + 0]` (u16, zero-extended). Returns
`SH_ERR_OUT_TOO_SMALL` if `len > out_cap`. Byte-copies `len` bytes
from `[entry + 2]` to `out_ptr`. Returns packed `(len << 32) | SH_OK`.

Rights required: `R_KS_READ` — same class as `KS_OP_READ_STATE` /
`KS_OP_READ_NAME`.

Pointer safety at M4 is restricted to the dispatcher's existing
posture: `out_ptr != 0`. Page-fault safety (what happens if the page
is unmapped) is deferred to the ring-3 syscall gate that lands with
R128's KIND_SHELL_SESSION user ABI. At M4 the handler assumes the
caller is a supervisor-reach task that passed in-kernel sanitation.

### 4.4 `_shell_history_count`

Pure read. Validates `session_id`; on invalid returns 0 (a dropped
session's count is zero, which is a safe sentinel because a caller
that reaches COUNT on a bad sid would also fail on APPEND / READ
with `SH_ERR_BAD_SESSION`). Loads `history_head` and `history_tail`;
returns `head - tail`.

Rights required: `R_KS_READ`.

## 5 Cap-invoke dispatch

Three new ops on `KIND_SHELL_SESSION`:

```
  KS_OP_HISTORY_APPEND = 5     R_KS_WRITE
  KS_OP_HISTORY_READ   = 6     R_KS_READ
  KS_OP_HISTORY_COUNT  = 7     R_KS_READ
```

`KS_OP_MAX` bumps from 4 to 7. The dispatch bounds check `cmp r10, 7
; ja ks_hn_bad_op` admits every valid ordinal.

### 5.1 Payload encoding

```
  APPEND  target_ptr[15:0]  = session_id
          target_ptr[63:16] = cmd_ptr (48 bits; user-half canonical)
          op_arg[7:0]       = KS_OP_HISTORY_APPEND (5)
          op_arg[63:8]      = cmd_len (56 bits; 126-clamped by helper)

  READ    target_ptr[15:0]  = session_id
          target_ptr[31:16] = index_from_head (16 bits)
          target_ptr[63:32] = out_cap (32 bits)
          op_arg[7:0]       = KS_OP_HISTORY_READ (6)
          op_arg[63:8]      = out_ptr (56 bits; user-half canonical)

  COUNT   target_ptr[15:0]  = session_id
          target_ptr[63:16] = 0 (reserved; non-zero -> KS_ERR_BAD_OP)
          op_arg[7:0]       = KS_OP_HISTORY_COUNT (7)
          op_arg[63:8]      = 0 (reserved; non-zero -> KS_ERR_BAD_OP)
```

Any op_arg[63:8] violation on a reserved slot refuses with
`KS_ERR_BAD_OP`, matching the existing READ_STATE / SET_STATE posture.

### 5.2 Error translation

```
  SH_OK                 -> KS_OK
  SH_ERR_BAD_SESSION    -> KS_ERR_BAD_SESSION
  SH_ERR_OUT_TOO_SMALL  -> KS_ERR_BAD_OP
  SH_ERR_EMPTY          -> KS_ERR_BAD_OP
  (other non-zero)      -> KS_ERR_BAD_SESSION (defensive)
```

READ's packed return threads through unchanged on success (status
bits are zero so the shift yields `bytes_written`); on error, the
helper's return already matches an SH_ERR_* code and the handler
translates per the table above.

## 6 Encoder discipline

Labels prefixed `sh_` (shell-history) stay clear of `ss_`
(shell_session) and `svc_` (ipc/svc_broker). Pitfall posture
(feedback_pdx_encoder_pitfalls):

* `cmp rN, 0` (never `test rN, rN`)
* `shl rN, 7`  for entry-stride compose
* `shl rN, 14` for ring-base compose (128 fits imm8)
* `and rN, 0x7F` for slot-index mask (fits imm32)
* `mov rax, imm32` for all error codes
* `mov_w rax, [addr]` / `mov_w [addr], rax` for u16 len load/store
  (proven in `src/kernel/acpi/mcfg.pdx` and `src/kernel/acpi/hpet.pdx`)
* `mov_b` for byte-wise cmd copy (proven in `shell_session.pdx`
  name-copy loop)
* single-line `pub let name = "..."`
* module basename `ShellHistory` matches file basename
  `shell_history.pdx`
* fingerprint `[u8; N]` with N = len(string) + 1 (NUL counts)

### 6.1 Stack discipline (SysV, entry rsp%16==8)

```
  _shell_history_init        1 push  (r12 across klog_s1)
  _shell_history_count       1 push  (rbx = session_id)
  _shell_history_append      5 pushes (rbx, r12, r13, r14, r15)
                             + sub rsp, 16 (8-byte stack-arg slot
                                            for klog_s1_x1_d1 + pad)
  _shell_history_read        5 pushes + sub rsp, 16
```

5 pushes = +40; entry %16==8 -> %16==0 at the row-base calls. Adding
`sub rsp, 16` -> %16==0 at the klog_s1_x1_d1 call site. The stack-
arg slot sits at `[rsp + 0]`; the pad at `[rsp + 8]` is unused.

## 7 Observability

`_shell_history_stats : [u64; 14]` holds per-op counters:

```
  SH_ST_INIT_OK       = 0    init-path success
  SH_ST_APPEND_OK     = 1    successful append
  SH_ST_APPEND_REJ    = 2    bad session on append
  SH_ST_APPEND_TRUNC  = 3    append whose cmd_len > 126 (sub-case of OK)
  SH_ST_READ_OK       = 4    successful read
  SH_ST_READ_REJ      = 5    bad session / empty / out-too-small
  SH_ST_READ_EMPTY    = 6    sub-case of READ_REJ for EMPTY
  SH_ST_COUNT_OK      = 7    count returned a live row
  SH_ST_COUNT_REJ     = 8    count returned 0 on bad session
  SH_ST_EVICT         = 9    append that caused tail advance
  // 10..13 reserved for R127.M5 (job-control substrate)
```

Only `SHELL_HISTORY INIT OK`, `SHELL_HISTORY APPEND OK`, and
`SHELL_HISTORY READ OK` trip the fingerprint-coverage gate. The REJ
tags are opaque to the gate (no bare `OK` token). COUNT emits no
fingerprint (pure read, no side effect worth a wire-visible line).

## 8 Fingerprints + allowlist

```
  SHELL_HISTORY INIT OK      (always fires on boot)
  SHELL_HISTORY APPEND OK    (unreachable at M4; R127.M5 drives)
  SHELL_HISTORY READ OK      (unreachable at M4; R127.M5 drives)
```

Allowlist entries land in `tools/verify-fingerprint-coverage.sh` with
retire-when-R127.M5-job-control-lands reason. R127.M5 is the first
wave with a shell parent task that drives the dispatch loop; its
smoke-mode goldens assert each of these end-to-end.

## 9 Interaction with R127 earlier milestones

R127.M1 (svc.shell-session daemon):
  * The row-pool fields `history_head` (`[+24]`) and `history_tail`
    (`[+32]`) are the exact anchors M4 populates. M1 pre-zeroed both
    at `_shell_session_create`; M4 never touches these before
    `ss_row_in_use` confirms the row is live.
  * `_shell_session_destroy` zeroes neither field (M1 §destroy
    comment); M4 is correct against this because `destroy` clears
    `in_use` and the ring entries become unreachable (count returns
    0 on `ss_row_in_use == 0`).
  * `ss_row_in_use` is the only R127.M1 symbol this landing calls.

R127.M2 (KIND_SHELL_SESSION cap):
  * Adds three ops (APPEND / READ / COUNT) on the same kind. The
    `KS_OP_MAX` bound bumps from 4 to 7.
  * `_ks_stats` already widened to 16 slots at R127.M3; new slots
    [9..15] carry KS_ST_HISTORY_* counters.

R127.M3 (raw-mode TTY substrate):
  * No interaction. The raw_mode_flags at `[+44]` is disjoint from
    the history anchors at `[+24]` / `[+32]`.

## 10 Follow-ons

R127.M5 (job control + shell parent dispatch loop):
  * Wires `_shell_history_append` into the shell parent's exec path
    so every dispatched command lands on the ring. Lands the first
    smoke-mode golden exercising APPEND end-to-end.
  * Wires `_shell_history_read` into an up-arrow / Ctrl-R binding on
    the TTY line-discipline path. Lands the first READ smoke-mode
    golden.
  * Retires the three allowlist entries this landing adds.

R128 (ring-3 syscall ABI for KIND_SHELL_SESSION):
  * Lands user-pointer sanitation on `cmd_ptr` / `out_ptr`. Current
    M4 posture is supervisor-reach only; a bad pointer page-faults
    into the paging gate rather than being caught at the dispatcher.

R128+ (slab allocator rewrite):
  * May retire the fixed-geometry pool in favour of a per-session
    slab with lineage tracking. The direct-call API stays stable; the
    backing storage is an implementation detail hidden behind
    `_shell_history_append` / `_shell_history_read` / `_shell_history_count`.
