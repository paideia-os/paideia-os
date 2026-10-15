# Shell job-control substrate (R229.M4)

Issue:        paideia-os#2722
Umbrella:     paideia-os#2493 (R229 REPL evaluator)
Wave:         125 (first arm)
Lands:        2026-10-15
Depends on:   R229.M1 (REPL loop state machine, kernel-side,
                       src/kernel/core/shell/repl_loop.pdx)
              R229.M2 (SessionEnv, parser-tier,
                       tools/user/libpdx-pds-parser/src/session_env.pdx)
              R229.M3 (TypeEnv, parser-tier,
                       tools/user/libpdx-pds-parser/src/type_env.pdx)
Companion:    [job_control.pdx](../../tools/user/libpdx-pds-parser/src/job_control.pdx)
Mirrors:      [shell_jobs.pdx](../../src/kernel/core/svc/shell_jobs.pdx)
              (R127.M5 kernel-side; see
               [job-control-primitives.md](job-control-primitives.md))

---

## Table of contents

1. [Why this module exists](#1-why-this-module-exists)
2. [Scope at R229.M4](#2-scope-at-r229m4)
3. [State machine](#3-state-machine)
4. [Record layout (48 bytes)](#4-record-layout-48-bytes)
5. [Pool geometry](#5-pool-geometry)
6. [Public API](#6-public-api)
7. [Return-code band 0x4E00..0x4EFF](#7-return-code-band-0x4e000x4eff)
8. [Fingerprint matrix](#8-fingerprint-matrix)
9. [Encoder posture](#9-encoder-posture)
10. [Boundary with R127.M5 (kernel side)](#10-boundary-with-r127m5-kernel-side)
11. [Forward path](#11-forward-path)
12. [References](#12-references)

---

## 1. Why this module exists

R229 (REPL evaluator umbrella) wraps the shell's per-turn PROMPT /
READING / PARSED / EVAL / WRITING / IDLE state machine. R229.M1
landed the per-cycle driver (kernel-side `repl_loop.pdx`); R229.M2
landed the per-session binding store; R229.M3 landed the type-scheme
store + specialisation cache. The piece every evaluator-side
dispatch surfaces on `cmd &` / `fg %n` / `bg %n` / `jobs` is still
missing: a working-memory table of in-flight jobs under the current
shell session, scoped to the user's REPL rather than the kernel's
scheduler.

The kernel already carries a job substrate — R127.M5 at
`src/kernel/core/svc/shell_jobs.pdx` records `(session_id,
primary_pid)` pairs under the kernel-side shell-session table. That
is the ground truth. **But the SHELL also needs its own view**:

* The shell owns the pre-schedule `NEW` state. The kernel sees a
  job only once it is actually scheduled.
* The shell owns the raw `command_inline` bytes the user typed. The
  kernel sees a thread, not a command.
* The shell owns `_jc_fg_tid` — the current foreground tid the TTY
  router dispatches stdin to on each `_rl_tick`. The kernel does
  not route TTY input.
* The shell makes the `fg` / `bg` decision locally. Those are
  user-space state transitions; the kernel is informed via the
  scheduler-side mirror call that follows.

R229.M4 lands the shell's view. It is **not** a reimplementation of
R127.M5 — it is a sibling table that pairs with it at the
R229.M5 scheduler wire-up.

## 2. Scope at R229.M4

**In scope:**

* 32-slot Job-row pool (48 bytes per row) with magic-marker
  liveness.
* NEW / RUNNING / STOPPED / DONE state machine with
  scheduler-driven and user-driven transition paths.
* `_jc_submit` for the `cmd &` fast path (background launch).
* `_jc_bg` / `_jc_fg` for `bg %n` / `fg %n` built-ins.
* `_jc_list` for the `jobs` built-in and the prompt-count helper.
* `_jc_update_state` as the single-point scheduler callback.
* `_jc_fg_tid` scalar for the TTY-router foreground route.

**Out of scope (deferred):**

* **R229.M4.1** — `_jc_list_all` variant that INCLUDES DONE rows
  (for a `jobs -a` option).
* **R229.M4.2** — `_jc_set_tid(job_id, tid)` once R229.M5
  scheduler wire populates `slot.tid` separately from state
  transitions.
* **R229.M4.3** — proptest harness + fingerprint goldens for the
  10-job acceptance test (`tests/proptest_job_control.pdx`;
  `tests/fingerprints/job_control.golden`).
* **R229.M5** — KIND_JOB cap-invoke surface + kernel-side
  `_shell_jobs_set_state` reconciliation wire.
* **R229.M6+** — compacting pool reuse; `cmd_body_ref` string
  arena; multi-session partitioning.

## 3. State machine

```
  NEW  --(_jc_update_state ->RUNNING)--> RUNNING
                                        ^   |   \
                                        |   |    \--(update_state ->DONE)
                                        |   v            |
                                        |  STOPPED       v
                                        |   | ^        DONE  (terminal)
                                        |   | |          ^
                                        |   | +--(_jc_bg / _jc_fg)
                                        |   |
                                        |   +--(update_state ->DONE)
                                        |
                                        +--(update_state ->STOPPED)
```

Allowed transitions (full table):

| from     | to       | caller                 | notes                        |
|----------|----------|------------------------|------------------------------|
| NEW      | RUNNING  | `_jc_update_state`     | scheduler-side first schedule |
| NEW      | STOPPED  | `_jc_update_state`     | pre-schedule preempt (rare)  |
| NEW      | DONE     | `_jc_update_state`     | failed to start              |
| RUNNING  | STOPPED  | `_jc_update_state`     | preempt / signal / ^Z        |
| RUNNING  | DONE     | `_jc_update_state`     | exit                         |
| STOPPED  | RUNNING  | `_jc_bg` / `_jc_fg`    | user `bg` / `fg`             |
| STOPPED  | RUNNING  | `_jc_update_state`     | scheduler-side resume        |
| STOPPED  | DONE     | `_jc_update_state`     | killed while stopped         |

Rejected (returns `JC_ERR_BAD_STATE`):

* Any transition from `DONE` (terminal).
* Any transition to `NEW` (`NEW` is set only by `_jc_submit`).
* Any no-op (cur == new).
* Any transition with `new_state > 3`.

### Why the no-op is rejected

A scheduler-side double-dispatch (e.g. the scheduler reports
RUNNING twice) is a bug in the scheduler, not a legitimate state
rewrite. Rejecting it surfaces the bug via `JC_ERR_BAD_STATE` at
the call site rather than silently masking it.

### `_jc_bg` vs `_jc_fg` vs `_jc_update_state`

Both `_jc_bg` and `_jc_fg` perform STOPPED -> RUNNING, so why
three entry points?

* `_jc_bg` sets `mode := BACKGROUND` and drops `_jc_fg_tid` if the
  slot owned the fg route.
* `_jc_fg` sets `mode := FOREGROUND` and writes `_jc_fg_tid :=
  slot.tid`.
* `_jc_update_state(id, RUNNING)` is the scheduler-side callback
  that reports a resume event. It does NOT touch `mode` or
  `_jc_fg_tid`.

The three paths are not interchangeable from the caller's
perspective, so they get distinct ABI surfaces.

## 4. Record layout (48 bytes)

```
+0x00  u32   magic              'JOBS' (0x53424F4A LE); 0 = free slot
+0x04  u32   job_id             1-based (= pool_idx + 1)
+0x08  u8    state              NEW=0 / RUNNING=1 / STOPPED=2 / DONE=3
+0x09  u8    mode               FOREGROUND=0 / BACKGROUND=1
+0x0A  u8    flags              reserved; 0 at M4
+0x0B  u8    reserved           0
+0x0C  u32   tid                scheduled thread id (0 at M4)
+0x10  u8[16] command_inline    bytes 0..min(cmd_len, 16); zero-padded
+0x20  u64   cmd_body_ref       opaque u64 (0 at M4; M5+ arena offset)
+0x28  u32   reserved           0
+0x2C  u32   reserved           0
```

### Why 48 bytes

48 = 32 + 16 so slot addressing uses `(idx<<5) + (idx<<4)` (two
shifts + one add). This is the same stride pattern R222.M5
`cmd_registry.pdx` uses for its 48-byte entries. Never 2-op
`imul r, imm` (paideia-as encoder gap; see
`feedback_pdx_encoder_pitfalls`).

### Why magic='JOBS' not a bool flag

`.bss` zero-init already satisfies "slot is free" when `magic == 0`.
Using a 4-byte magic sentinel means a chaos restart or a
mis-aligned read never falsely identifies a slot as live. The CJK
Unicode codepoint 0x4E00 occupies the same first-byte space but is
disjoint when read as a u32 LE at the slot's `+0x00`.

### Why `job_id` stored in the slot

A caller holding a `job_id` from a prior `_jc_submit` can
cross-check the slot's recorded `job_id` on a later `_jc_bg` /
`_jc_fg` / `_jc_update_state` to catch a stale-id-after-reap race.
R229.M4 does NOT yet validate this (the slot is reaped only on a
subsequent `_jc_submit` that reuses it, so an immediate `_jc_bg
%n` after a DONE sees the DONE state and gets `JC_ERR_BAD_STATE`
naturally); R229.M4.2+ adds the cross-check.

## 5. Pool geometry

```
_jc_jobs       : [u8; 1536]  @align(8)   32 slots x 48 bytes
_jc_job_count  : u64         @align(8)   append-cursor hint
_jc_fg_tid     : u64         @align(8)   current fg tid (0 if none)
```

Slot base = `_jc_jobs + idx * 48` via `(idx<<5) + (idx<<4)`.

`_jc_job_count` is bumped only on a brand-new allocation (magic was
0 before the write). A slot recycled from state DONE does NOT bump
the counter. This gives the "ever-allocated" count rather than
the live count; the live count comes from `_jc_list` output
(bytes_written / 48).

`_jc_fg_tid` is read by the TTY-router at every `_rl_tick`:

```
if _jc_fg_tid == 0:          route stdin to the shell itself
else:                        route stdin to _jc_fg_tid
```

At R229.M4, `_jc_fg` always writes 0 (because `slot.tid == 0`
until R229.M5 wire-up). The TTY-router behaviour is therefore
unchanged at M4; the wire exists so M5 can light it up without an
ABI change.

## 6. Public API

| Entry point                                             | Signature                                                     |
|---------------------------------------------------------|---------------------------------------------------------------|
| `_jc_init()`                                            | `() -> ()`                                                    |
| `_jc_submit(cmd_ptr, cmd_len, mode_u8, out_job_id_ptr)` | `(u64, u64, u64, u64) -> u64` (errno)                         |
| `_jc_bg(job_id)`                                        | `(u64) -> u64` (errno)                                        |
| `_jc_fg(job_id)`                                        | `(u64) -> u64` (errno)                                        |
| `_jc_list(out, out_cap)`                                | `(u64, u64) -> u64` (packed bytes_written << 32 \| status)    |
| `_jc_update_state(job_id, new_state)`                   | `(u64, u64) -> u64` (errno)                                   |

Signatures are frozen at M4 so R229.M4.1+ (`_jc_list_all`,
`_jc_set_tid`) layers additively.

### Prompt count

The shell's prompt renderer calls `_jc_list` with a small stack
buffer, divides the returned low-32-bits of `(bytes_written << 32)
| status` by 48, and renders the count:

```
let packed = _jc_list(scratch, 1536)
let status = packed & 0xFFFFFFFF
let bytes  = packed >> 32
if status == JC_OK:
  prompt_prefix(" [", bytes / 48, "]")
```

Because `_jc_list` filters DONE rows, the prompt count tracks only
NEW / RUNNING / STOPPED jobs. A completed job disappears from the
prompt as soon as `_jc_update_state(id, DONE)` lands.

## 7. Return-code band 0x4E00..0x4EFF

| Code     | Name                        | Returned by                                                             |
|----------|-----------------------------|-------------------------------------------------------------------------|
| 0        | `JC_OK`                     | success                                                                 |
| 0x4E00   | `JC_ERR_POOL_FULL`          | `_jc_submit` with all 32 slots in a non-DONE, magic='JOBS' state        |
| 0x4E01   | `JC_ERR_BAD_ID`             | job_id == 0 or > 32 or slot.magic != 'JOBS'                             |
| 0x4E02   | `JC_ERR_BAD_STATE`          | transition rejected by the state machine                                |
| 0x4E03   | `JC_ERR_BAD_MODE`           | `_jc_submit` with mode not in {0, 1}                                    |
| 0x4E04   | `JC_ERR_BAD_CMD`            | `_jc_submit` with cmd_ptr == 0 or cmd_len == 0                          |
| 0x4E05   | `JC_ERR_OUT_TOO_SMALL`      | `_jc_list` out_cap would be exceeded by the next 48-byte copy           |
| 0x4E06   | `JC_ERR_BAD_OUT_PTR`        | `_jc_submit` with out_job_id_ptr == 0                                   |

Slots 0x4E07..0x4EFF reserved for R229.M4.1+.

### Band disjointness proof

```
$ grep -rE '0x4E0[0-6]\b' paideia-os/{src,tools,design,tests}
# ↳ hits only this file + caps.decl + job_control.pdx
```

Adjacent parser-tier bands:
* 0x4C00..0x4CFF — R223.M3 FilterOp
* 0x4D00..0x4DFF — parallel-reserved for R223.M4 (pipeline @hostname)
* 0x4E00..0x4EFF — **R229.M4 JobControl (THIS)**
* 0x4F00..0x4FFF — reserved for the next parallel-arm

## 8. Fingerprint matrix

```
JOB SUBMIT OK             per-cmd      _jc_submit alloc path
JOB SUBMIT POOL_FULL      per-cmd      _jc_submit on 32-slot exhaust
JOB TRANSITION NEW->RUN   per-event    _jc_update_state 0 -> 1
JOB TRANSITION RUN->STOP  per-event    _jc_update_state 1 -> 2
JOB TRANSITION RUN->DONE  per-event    _jc_update_state 1 -> 3
JOB TRANSITION STOP->RUN  per-event    _jc_update_state 2 -> 1
JOB TRANSITION STOP->DONE per-event    _jc_update_state 2 -> 3
JOB BG OK                 per-cmd      _jc_bg STOPPED -> RUNNING
JOB FG OK                 per-cmd      _jc_fg STOPPED -> RUNNING
JOB LIST OK               per-cmd      _jc_list emit
```

M4 does NOT itself emit fingerprints — the module stays pure parser-
tier, and the `klog_s1_*` wrapper lives at the R229.M4+ REPL
dispatch layer. The dispatch layer wires one fingerprint per
`_jc_update_state` call, so the 10-job acceptance test
(R229.M4.3 proptest harness) can golden the state-transition log.

Expected acceptance-test shape (10 jobs x transition fingerprint):

```
JOB SUBMIT OK           job_id=1
JOB TRANSITION NEW->RUN job_id=1
JOB SUBMIT OK           job_id=2
JOB TRANSITION NEW->RUN job_id=2
...
JOB SUBMIT OK           job_id=10
JOB TRANSITION NEW->RUN job_id=10
JOB TRANSITION RUN->STOP job_id=3    (user ^Z-equivalent)
JOB BG OK                job_id=3
JOB TRANSITION RUN->DONE job_id=1
...
```

Error-path fingerprints are NOT emitted on the hot path (same
discipline as SessionEnv R229.M2): the error enum is the structured
observation point.

## 9. Encoder posture

* **No `test rN, rN`** — every zero-check is `cmp reg, 0; je/jne`.
* **No `and rN, imm64`** — every mask is imm8 or imm32.
* **No 2-op `imul r, imm`** — slot stride 48 uses
  `mov tmpA, idx; mov tmpB, idx; shl tmpA, 5; shl tmpB, 4;
  add tmpA, tmpB` (cmd_registry.pdx precedent).
* **No multiline `pub let = "..."`** — single-line justifications.
* **Module basename `JobControl`** matches `job_control.pdx`.
* **Labels prefixed `jc_`** — grep-disjoint from every other
  parser-tier and kernel-tier label namespace.
* **All `cmp reg, imm` immediates** (0, 1, 2, 3, 16, 32, 48,
  0x4E00..0x4E06, 0x53424F4A) fit imm32 with bit 31 clear.
* **Byte loads** via `xor rax, rax; mov_b rax, [base + disp]`.
* **u32 loads** via `xor rax, rax; mov_d rax, [base + disp]`.
* **u32 stores** via `mov_d [dst + disp], reg`.
* **u64 stores** via plain `mov [dst + disp], reg`.
* **`.bss` writes** via `lea r11, [rip + sym]; mov [r11 + disp],
  reg`.
* **Name copy / zero-pad** — precomputed destination base in `rsi`
  (`mov rsi, r15; add rsi, 16`) with the store form
  `mov_b [rsi + r10 * 1], rax` to sidestep the
  `mov_b [reg + reg + off], reg` encoder gap documented in
  `session_env.pdx` §Name copy.

### Stack-frame discipline

| Function              | Pushes       | Scratch     | rsp%16 at nested CALL      |
|-----------------------|--------------|-------------|------------------------------|
| `_jc_init`            | 0            | 0           | pure leaf (no CALL)          |
| `_jc_submit`          | 6 x 8        | 0           | pure leaf (no CALL)          |
| `_jc_bg`              | 0            | 0           | pure leaf (no CALL)          |
| `_jc_fg`              | 0            | 0           | pure leaf (no CALL)          |
| `_jc_list`            | 4 x 8        | 0           | pure leaf (no CALL)          |
| `_jc_update_state`    | 0            | 0           | pure leaf (no CALL)          |

Every entry point is a pure leaf; no `sub rsp, 8` align pad is
required. R229.M5 wire-up may convert the scanners into nested-
CALL shapes once the scheduler-side callback propagates through a
cross-module jump; at that point an 8-byte align pad adds in.

## 10. Boundary with R127.M5 (kernel side)

R127.M5 (`src/kernel/core/svc/shell_jobs.pdx`) landed the KERNEL's
job table at Wave UMB-W16:

* 64-byte rows, 32-slot pool.
* States `{RUNNING, PAUSED, COMPLETED, FAILED}`.
* Keyed by `(session_id, job_id, primary_pid)`.
* Return-code band 0x1600..

R229.M4 JobControl (THIS module) lives in USER space, parser-tier
satellite library:

* 48-byte rows, 32-slot pool.
* States `{NEW, RUNNING, STOPPED, DONE}`.
* Keyed by `job_id` (session-flat at M4).
* Return-code band 0x4E00..

The two tables are intentional mirrors with different scopes:

| aspect                  | R127.M5 (kernel)                | R229.M4 (user)                   |
|-------------------------|---------------------------------|----------------------------------|
| session binding         | per-session (one row = one job) | session-flat (M4; M5+ partition) |
| pre-schedule NEW state  | not represented                 | represented (job in NEW)         |
| command_inline bytes    | not stored                      | stored                           |
| TTY foreground route    | not stored                      | `_jc_fg_tid` scalar              |
| scheduler integration   | ground truth (cap-invoke)       | passive mirror                   |
| cap surface             | KIND_SHELL_SESSION,KIND_JOB@M6  | none (pure in-process)           |

**Reconciliation at R229.M5:** the scheduler-side event callback
dispatches EVERY lifecycle event through BOTH tables:

```
on_schedule_event(session_id, job_id, kernel_state):
  # Kernel-side mirror:
  _shell_jobs_set_state(kernel_row_id,
    kernel_state_from_shell(SHELL_STATE))

  # User-side mirror (this module):
  _jc_update_state(job_id,
    shell_state_from_kernel(kernel_state))
```

M4 lands only the user-side call. The kernel-side wire follows at
M5. The parallel structure keeps the two tables grep-disjoint and
individually reviewable; a bug in one does not corrupt the other.

### State mapping (kernel ↔ user)

| kernel R127.M5    | user R229.M4             | notes                        |
|-------------------|--------------------------|------------------------------|
| (not present)     | NEW                      | pre-schedule only            |
| RUNNING           | RUNNING                  | direct mapping               |
| PAUSED            | STOPPED                  | terminology reconciled       |
| COMPLETED         | DONE                     | exit status folded           |
| FAILED            | DONE                     | failure folded; exit status  |
|                   |                          | lives in the `flags` byte    |

## 11. Forward path

* **R229.M4.1** — `_jc_list_all` variant that includes DONE rows
  (for a hypothetical `jobs -a` option).
* **R229.M4.2** — `_jc_set_tid(job_id, tid)` once R229.M5 wires
  the scheduler-side first-schedule callback.
* **R229.M4.3** — `tests/proptest_job_control.pdx` with the 10-job
  state-transition corpus; `tests/fingerprints/job_control.golden`
  with the per-event fingerprint matrix enumerated in §8.
* **R229.M5** — KIND_JOB cap-invoke surface; kernel-side
  `_shell_jobs_set_state` reconciliation wire;
  R229.M5.scheduler = R107.M12 integration.
* **R229.M5.1** — multi-session partitioning (per-session 8-slot
  sub-pool).
* **R229.M6+** — compacting pool reuse; `cmd_body_ref` string
  arena; persistent per-user job history for the "replay dead job"
  option.

## 12. References

* `tools/user/libpdx-pds-parser/src/job_control.pdx`
* `tools/user/libpdx-pds-parser/src/session_env.pdx` (R229.M2
  sibling)
* `tools/user/libpdx-pds-parser/src/type_env.pdx` (R229.M3 sibling)
* `src/kernel/core/shell/repl_loop.pdx` (R229.M1 kernel driver)
* `src/kernel/core/svc/shell_jobs.pdx` (R127.M5 kernel-side table)
* `design/shell/repl-loop-scaffold.md` (R229 umbrella design)
* `design/shell/session-env.md` (R229.M2 sibling design)
* `design/shell/type-env-threading.md` (R229.M3 sibling design)
* `design/shell/job-control-primitives.md` (R127.M5 kernel-side
  design)
* `design/terminal/semantic-shell-language-plan.md` §R229
* paideia-os#2493 (R229 umbrella)
* paideia-os#2722 (THIS ticket)
