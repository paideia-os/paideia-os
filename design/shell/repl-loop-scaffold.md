# REPL evaluator loop scaffold (R229.M1)

Issue: paideia-os#2719
Wave:  UMB-W28
Lands: 2026-10-14

## 1 Why

R127 landed the shell-session row pool (R127.M1), the raw-mode TTY
substrate (R127.M3), the per-session history ring (R127.M4), the job
table (R127.M5), and the teardown cascade (R127.M6).  The pieces that
describe *what* a shell session owns are now in the kernel.  R229
("REPL evaluator loop") lands the piece that describes *how* a session
executes: a per-session state machine that owns one read/eval/write
cycle at a time.

R229.M1 lands the state machine substrate only:

* a 128-byte per-session REPL row that holds the current cycle's state
  ordinal and a 112-byte line-accumulation buffer,
* three direct-call entry points (`_rl_init_session`, `_rl_tick`,
  `_rl_emit_prompt`),
* a boot hook (`_rl_init`) that scrubs the stats pool and emits one
  INIT fingerprint.

The actual *eval* dispatch (what happens between PARSED and WRITING)
is deferred to R229.M2+.  M1's `_rl_tick` only accepts bytes in the
READING state and transitions to PARSED when it sees a newline; the
caller never drives beyond that at M1.  R229.M3+ hands the accumulated
line_buf to pds-lang (R230) for evaluation.

Design posture (feedback_novel_clean_design): the shell session —
not a tty-side `readline` library — owns the line discipline that
turns bytes into a parsed command.  POSIX bash's cooked-tty +
userspace-readline split is retired in favour of a kernel-held state
machine whose only reach is a cap-invoke op (deferred to R229.M4+).
The byte path is: TTY input ISR → `_rl_tick` → PARSED → eval
dispatch → `_rl_emit_prompt`.  No userspace readline buffer; no
cooked-mode kernel line discipline; just the state machine.

## 2 Row layout — 128 bytes per session

```
  [+0]    state            (u32)   one of RL_STATE_* ordinals
  [+4]    line_buf_head    (u32)   next-write index in line_buf
                                   (0 .. RL_LINE_MAX = 112)
  [+8]    line_buf         [u8; 112]  bytes accumulated since the
                                      last PROMPT, LF-included on the
                                      final byte
  [+120]  reserved         [u8; 8]    .bss-zero sentinel; R229.M2+
                                     reinterprets the low 4 bytes as
                                     a parse-cursor index and the high
                                     4 bytes as last-tsc for debounce
```

Total: 4 + 4 + 112 + 8 = 128 bytes.  Pool: 8 rows × 128 B = 1024 B.
Stride 128 is a power of two so row addressing is `shl rax, 7` — no
`imul r, imm`.  Row 0 lands on a cache-line boundary via `@align(64)`.

The 112-byte `line_buf` is the hard cap at M1.  A terminal line that
reaches it before a newline arrives trips `RL_ERR_LINE_OVERFLOW` and
the row transitions to IDLE (the diagnostic data stays in the buffer
until the next `_rl_init_session` or `_rl_emit_prompt`).  R229.M2+
may widen the buffer; the state machine does not depend on the exact
cap.

### 2.1 Alternatives considered

A dynamically-grown line buffer was rejected: an 8-row ×
dynamic-length allocator reach at every byte is a correctness hazard
in an ISR context (allocator locks + possible page fault inside IRQ
handler).  The 112-byte fixed cap keeps the state machine inside the
scheduler's single-slot ISR budget.

Co-locating the REPL state on the shell_session row itself was
rejected because the shell_session row is already at its 128-byte
budget (R127.M1 reserved only a single u64 slot at [+120], which
R127.M5 reclaimed as `active_job_pid`).  A separate pool keyed by
the same session_id keeps the two concerns decoupled.

A per-session linked list of "input events" was rejected (R229 is
substrate-grade; a lineage-tracking log is a R234+ auditability
target).  The fixed-geometry row is correctness-cheap and the entire
pool scrubs in one `.bss` zero at boot.

## 3 State machine

```
   RL_STATE_PROMPT      = 0
   RL_STATE_READING     = 1
   RL_STATE_PARSED      = 2
   RL_STATE_EVAL        = 3
   RL_STATE_WRITING     = 4
   RL_STATE_IDLE        = 5
   RL_STATE_TERMINATED  = 6
   RL_STATE_MAX         = 7           (exclusive upper bound)
```

Transitions (M1 permissive — any valid state may hold through tick,
but only READING accepts a byte; `_rl_emit_prompt` only accepts
PROMPT or IDLE):

```
   (init)        -> PROMPT                  _rl_init_session
   PROMPT        -> READING                 _rl_emit_prompt
   READING       -> READING                 _rl_tick (byte != 0x0A, head < 112)
   READING       -> PARSED                  _rl_tick (byte == 0x0A)
   READING       -> IDLE                    _rl_tick (overflow)
   PARSED, EVAL, WRITING                    held at M1; R229.M2+ drives
   IDLE          -> READING                 _rl_emit_prompt
   any           -> TERMINATED              _rl_terminate_session (M2+)
```

M1 is deliberately permissive on the forward chain (PARSED → EVAL →
WRITING → IDLE).  Those edges are the eval-dispatch surface that
R229.M2 lands; keeping the state ordinals pinned at M1 means M2 only
adds the transition code and does not re-pin ordinals, which would
break every allowlist entry downstream.

### 3.1 Why 7 states (not 3 or 10)

Three states (READ / EVAL / PRINT) is the classical REPL shape, but
it conflates PROMPT (prompt-about-to-be-emitted) with READING (bytes
being accepted) and WRITING (bytes being drained to the TTY) with
IDLE (between cycles).  The telemetry-grade separation lets the TTY
ISR distinguish "the loop is ready for a byte" from "the loop is
holding on an eval"; a byte that arrives during EVAL is a type-error
rather than silently queued.

Ten states (one per pds-lang evaluation phase: lex / tokenize /
parse / typecheck / lower / execute / stdout / stderr / cleanup /
flush) was rejected because the TTY ISR does not need that
granularity — it only cares whether a byte is a valid input right
now.  The 7-state partition is the Pareto point: enough to carry
the "ready for byte" vs "busy" distinction without burdening the
ISR with eval-internal detail.

## 4 Return band

```
   RL_OK                  = 0
   RL_ERR_BAD_SESSION     = reuse SS_ERR_BAD_ID = 0x1102
   RL_ERR_LINE_OVERFLOW   = 0x3000
   RL_ERR_STATE           = 0x3001
```

Band audit at landing (2026-10-14):
`grep -rnE '0x300[0-1]\b' src/kernel/` → one hit in
`src/kernel/core/drivers/xhci/configure_ep.pdx` as an xHCI command
*register value*, not an error code — disjoint namespace.  Clean
band; R229.M2+ may extend to 0x3002..0x300F while retaining the
first two RL_* as pinned.

All fit imm32 with bit 31 clear so `mov rax, imm32` emits the 7-byte
zero-extending form.

`RL_ERR_BAD_SESSION` deliberately aliases `SS_ERR_BAD_ID = 0x1102`
(R127.M1 band) so a caller may test either name — the two bands are
subsets of the shell-session namespace.  The alias convention mirrors
R127.M3's `SS_RAW_ERR_BAD_SESSION`, R127.M4's `SH_ERR_BAD_SESSION`,
R127.M5's `SJ_ERR_BAD_SESSION`, and so on.

### 4.1 Packed `_rl_tick` return

```
   result = (new_state << 32) | status
```

On success `status == RL_OK (0)`, so `result == new_state << 32` and
the caller recovers `new_state` by right-shifting 32 bits.  `new_state`
is in [0, 7) so `new_state << 32` lies in `[0, 7 << 32)` — disjoint
from every `RL_ERR_*` value (all have bits [31:0] in `[0x1102, 0x3001]`
with bits [63:32] zero) so a caller that treats the whole u64 as an
error-or-state tagged value never collides.

On error the state field still carries the row's resulting state
(e.g. a line-overflow trips the row to IDLE and reports it), so a
caller that logs `(result >> 32)` always logs the *post-tick* state
regardless of the OK/error path.

## 5 Public API

```
   _rl_init() -> ()
   _rl_init_session(session_id) -> errno
   _rl_tick(session_id, input_byte) -> packed u64
   _rl_emit_prompt(session_id) -> errno
```

### 5.1 `_rl_init`

Boot hook.  Defensive scrub of `_rl_stats` (16 u64 = 128 bytes).
`.bss` already zero-inits the pool at real boot; the stats scrub
covers a chaos-restart re-entry.  Emits `REPL_LOOP INIT OK` on
completion.  Signature `() -> ()` matches `_shell_history_init` /
`_shell_jobs_init` one-for-one.

Boot wiring: `src/kernel/boot/kernel_main.pdx`, immediately after
`_shell_history_init` (R127.M4) and before `_hf_init` (R127.M7).  The
pair lands as a two-step cascade so an audit grep sees `SHELL_HISTORY
INIT OK` then `REPL_LOOP INIT OK` in subsystem order.

The pool backing (`_rl_pool`, 1 KiB) is NOT scrubbed — `.bss` is
already zero at real boot, and a slot is live only when its row has
been `_rl_init_session`'d (which rewrites every field).  A stale
row is unreachable via the public API.

### 5.2 `_rl_init_session`

Attaches a REPL state slot to the shell_session row.  Validates
`session_id` via `ss_row_in_use` (R127.M1).  On a live session row:

* writes `state = RL_STATE_PROMPT (0)` at `[row + 0]`,
* writes `line_buf_head = 0` at `[row + 4]`,
* zeroes `line_buf[0..112]` (14 u64 stores),
* zeroes the reserved slot at `[row + 120]`.

The full-row scrub costs 16 u64 stores — well under the 128-byte
cache-line budget for a single row.  Emits `REPL_LOOP INIT_SESSION
OK sid=0x<hex>` on completion.

Returns `RL_OK` on success, `RL_ERR_BAD_SESSION` on an invalid or
free session row.

Rights required at the (deferred) cap-invoke surface: `R_KS_WRITE` —
same class as `KS_OP_SET_STATE`.

### 5.3 `_rl_tick`

Feeds one input byte to the state machine.  The caller is the TTY
input ISR (R128+ deferred wire-up).

Semantics:

* `state == READING` AND `line_buf_head < 112`:
  * writes `input_byte` at `[row + 8 + head]`,
  * bumps `line_buf_head`,
  * if `input_byte == 0x0A` (LF): transitions `state := PARSED`
    and emits `REPL_LOOP TICK OK sid=0x<hex> state=0x02`;
  * otherwise stays in READING and does NOT emit a fingerprint
    (ISR hot path — fingerprint on state transition only).
* `state == READING` AND `line_buf_head == 112`:
  * does NOT write the byte,
  * transitions `state := IDLE`,
  * emits `REPL_LOOP TICK REJ sid=0x<hex> errno=0x3000`,
  * returns `(IDLE << 32) | RL_ERR_LINE_OVERFLOW`.
* `state != READING` (any of PROMPT, PARSED, EVAL, WRITING, IDLE,
  TERMINATED):
  * does NOT touch any field,
  * emits `REPL_LOOP TICK REJ sid=0x<hex> errno=0x3001`,
  * returns `(current_state << 32) | RL_ERR_STATE`.
* invalid `session_id`:
  * emits `REPL_LOOP TICK REJ sid=0x<hex> errno=0x1102`,
  * returns `(0 << 32) | RL_ERR_BAD_SESSION`.

The "no fingerprint on byte-accept-staying-in-READING" policy is
load-bearing: a 115200-baud serial port can deliver ~11.5 kB/s of
bytes, so a per-byte klog call would dominate the ISR cost.
Transitions are the audit-relevant events; the stats counter
(`RL_ST_TICK_BYTE`) bumps on every byte and gives the aggregate
rate for free.

Rights required at the (deferred) cap-invoke surface: `R_KS_WRITE`.

### 5.4 `_rl_emit_prompt`

Signals that the prompt has been emitted (or should be emitted — M1
does not actually write to the TTY; R229.M2+ adds the `tty_write`
hook).  Validates `session_id` via `ss_row_in_use`.  On a live
session row:

* if `state == PROMPT` or `state == IDLE`:
  * clears `line_buf_head` to 0 (fresh line),
  * transitions `state := READING`,
  * emits `REPL_LOOP EMIT_PROMPT OK sid=0x<hex>`,
  * returns `RL_OK`;
* otherwise:
  * emits `REPL_LOOP EMIT_PROMPT REJ sid=0x<hex> errno=0x3001`,
  * returns `RL_ERR_STATE`.

The IDLE case is the normal "finished writing output, going back to
read the next command" path — R229.M2's WRITING → IDLE → PROMPT →
READING drives it.  The PROMPT case is the first-prompt-after-init
path driven by the shell parent after `_rl_init_session`.

Rights required at the (deferred) cap-invoke surface: `R_KS_WRITE`.

## 6 Interaction with R127 and the forward path

R127.M1 (`shell_session.pdx`): the session row holds the primary
identity (pid, tty_fd, cap_env, state ordinal, name).  The REPL row
holds the *cycle* state (what the state machine is doing right now)
and the accumulating line_buf.  The two rows are keyed by the same
session_id so a caller that holds a KIND_SHELL_SESSION cap reaches
both substrates through the same cap-invoke dispatch.

R127.M4 (`shell_history.pdx`): after `_rl_tick` returns with
`state == PARSED`, R229.M2 will call `_shell_history_append(sid,
line_buf, line_buf_head)` BEFORE transitioning to EVAL.  The history
ring is the user-visible audit; the fact store (R127.M7) picks up
the structured record at EVAL exit (R229.M3+).

R127.M5 (`shell_jobs.pdx`): the EVAL state at R229.M2 may mint a
job row and transition WRITING → IDLE while the job runs; the job's
exit signals back via the scheduler to re-advance to PROMPT.
Interaction with job foreground/background: a backgrounded job
keeps the REPL state at READING (the shell is ready for the next
command) while the job runs; a foregrounded job transitions to EVAL
and the shell waits.  This is spelled out in detail at R229.M4
(job-REPL interleaving); M1 is scaffold only.

R127.M6 (session teardown): `_shell_session_destroy` already
cascades through jobs / history / raw_mode / active_job.  R229.M2+
adds a cascade step 7 that transitions the REPL row to TERMINATED
and clears `line_buf_head`.  M1 does not land this step — a stale
REPL row is unreachable once the session row's `in_use` goes to 0
(the REPL row has no independent `in_use` field; it borrows the
session's).

### 6.1 Forward path to pds-lang evaluation (R229.M3+)

R229.M2 lands the eval-dispatch surface: a `_rl_dispatch(sid)` call
that reads the row's `line_buf[0..line_buf_head]`, hands it to the
pds-lang lexer (R230.M1) and transitions EVAL → WRITING on parse
success.  The parse result is a pds-lang AST; the evaluator (R230.M3)
walks the AST and prints its result to the session's TTY.

R229.M3+ wires `_rl_dispatch` to `functor_invoke` (R123) so a parsed
command like `echo hello` resolves through the KIND_CMD_MODULE
dispatch table to the actual functor implementation.  At that point
the REPL loop is end-to-end: a byte path from the UART ISR to a
pds-lang evaluation to a kernel-side command functor to stdout.

### 6.2 Why ISR calls directly into `_rl_tick` (not through a message queue)

A message queue between the TTY ISR and the REPL loop was the first
alternative considered.  It was rejected on two grounds:

1. **ISR budget.**  The scheduler's ISR budget is ~1 μs per byte at
   115200 baud; a queue enqueue + context switch to a kernel-side
   REPL thread would blow that budget on every byte.  A direct call
   into `_rl_tick` is 10..30 cycles on the fast path (byte accepted,
   stay in READING).

2. **State machine lives in one place.**  A queue would need its
   own back-pressure policy (what happens when the queue fills?)
   and its own ordering guarantee (is the queue FIFO per-session or
   global?).  The direct call makes the state machine the single
   source of truth: back-pressure *is* `RL_ERR_LINE_OVERFLOW`;
   ordering *is* the sequence of `_rl_tick` calls from the ISR.

A future wave may re-introduce a bounded queue between the ISR and
the state machine *inside* the TTY driver (for buffering during a
page-fault stall), but that is a TTY-driver concern, not a REPL-loop
concern.

## 7 Encoder discipline

Labels are prefixed `rl_` to stay clear of `ss_` (shell_session),
`sh_` (shell_history), `sj_` (shell_jobs), `hf_` (history_facts),
`cr_` (cmd_registry), and the broader `s_` family.  Encoder-pitfall
posture (feedback_pdx_encoder_pitfalls):

* `cmp rN, 0` (never `test rN, rN`),
* `shl rN, 7` to compose row-base × 128 stride (never `imul r, imm`),
* `mov rax, imm32` for every return code (never `and r11, imm64`),
* `mov_b [reg + reg*1], reg` for the single-byte write into
  `line_buf[head]` (proven in `svc/shell_session.pdx` name-copy),
* single-line `pub let name = "..."` for every fingerprint tag,
* module basename `ReplLoop` matches file basename `repl_loop.pdx`,
* fingerprint `[u8; N]` with `N = len(string) + 1` (NUL counts).

Stack discipline (SysV, entry `rsp%16==8`):

```
   _rl_init                   1 push  (r12 across klog_s1)
   _rl_init_session           2 pushes + sub rsp, 8 (klog_s1_x1)
   _rl_tick                   5 pushes (rbx, r12, r13, r14, r15)
   _rl_emit_prompt            2 pushes + sub rsp, 8 (klog_s1_x1)
```

The hot path (`_rl_tick`) uses 5 pushes without `sub rsp` — 5 × 8 =
40, entry 8 → 48 total = `rsp%16==0` at every nested call.  The cold
paths (`_rl_init_session`, `_rl_emit_prompt`) use 2 pushes + 8-byte
pad to land on 32-byte alignment and reserve a stack-arg slot that
is unused today (future `klog_s1_x1_d1` upgrade without re-shaping
the frame).

## 8 Fingerprint matrix

```
   REPL_LOOP INIT OK                   boot        _rl_init
   REPL_LOOP INIT_SESSION OK           per-sid     _rl_init_session OK
   REPL_LOOP INIT_SESSION REJ          per-sid     _rl_init_session REJ
   REPL_LOOP TICK OK                   per-xition  _rl_tick READING -> PARSED
   REPL_LOOP TICK REJ                  per-error   _rl_tick overflow / bad state
   REPL_LOOP EMIT_PROMPT OK            per-prompt  _rl_emit_prompt OK
   REPL_LOOP EMIT_PROMPT REJ           per-error   _rl_emit_prompt REJ
```

Only the four `OK` tags are extracted by the fingerprint-coverage gate
(the regex matches the bare word `OK`); the three `REJ` tags are
opaque to the gate so no allowlist entry is required for them.

Allowlist at landing: all four `OK` tags are unreachable from any
production path at M1 because no shell parent task drives the REPL
state machine yet (the dispatch loop that would call `_rl_init_session`
+ `_rl_emit_prompt` + `_rl_tick` lands at R229.M2).  All four retire
from the allowlist when R229.M2 lands with asserting smoke-mode
goldens.

## 9 Observability counters

```
   RL_ST_INIT_OK             = 0
   RL_ST_INIT_SESSION_OK     = 1
   RL_ST_INIT_SESSION_REJ    = 2
   RL_ST_TICK_BYTE           = 3     // every accepted byte (hot)
   RL_ST_TICK_PARSED         = 4     // READING -> PARSED transitions
   RL_ST_TICK_OVERFLOW       = 5     // line-overflow trips
   RL_ST_TICK_BAD_STATE      = 6     // tick in non-READING
   RL_ST_TICK_BAD_SESSION    = 7
   RL_ST_EMIT_PROMPT_OK      = 8
   RL_ST_EMIT_PROMPT_REJ     = 9
   // slots 10..15 reserved for R229.M2+ eval-dispatch counters
```

`RL_ST_TICK_BYTE` is the "I'm alive" counter the TTY ISR increments
on every byte accepted (vs. the state-transition counters which only
bump on the audit-relevant events).  Dividing `RL_ST_TICK_PARSED` by
`RL_ST_TICK_BYTE` gives an average command-length-in-bytes datapoint
for free.

## 10 Verification posture

M1 has no asserting smoke-mode golden.  The four OK fingerprints are
allowlisted upstream in `tools/verify-fingerprint-coverage.sh` with
reasons that cite R229.M2 as the retire condition.

R229.M2 will land one smoke mode (`smoke/repl-loop-m2.golden.txt`)
that:

1. runs `_rl_init_session(0)` after boot,
2. runs `_rl_emit_prompt(0)` and asserts `EMIT_PROMPT OK`,
3. drives `_rl_tick(0, 'l')`, `_rl_tick(0, 's')`, `_rl_tick(0, '\n')`
   and asserts `TICK OK state=0x02` (PARSED),
4. drives `_rl_dispatch(0)` (M2 adds this) and asserts the eval
   returns through to `IDLE`,
5. runs `_rl_emit_prompt(0)` a second time and asserts the next
   `EMIT_PROMPT OK` fingerprint.

At that point all four M1 allowlist entries retire.  M1's job is
ONLY to land the state machine shape so the ordinals stay pinned
across the M2+ landings.
