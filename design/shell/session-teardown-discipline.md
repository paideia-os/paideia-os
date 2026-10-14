# Shell session teardown discipline (R127.M6)

Issue:        paideia-os#2602
Wave:         UMB-W17
Lands:        2026-10-13
Depends on:   R127.M1 (shell-session daemon), R127.M3 (raw-mode TTY),
              R127.M4 (history ring), R127.M5 (jobs + active_job_pid),
              R135.M2 (sys_exit step 2.7 wiring precedent)
Supersedes:   nothing (greenfield; POSIX session/process-group cleanup
              is explicitly retired, see §2)
Companion:    [shell_session.pdx](../../src/kernel/core/svc/shell_session.pdx)
              [shell_jobs.pdx](../../src/kernel/core/svc/shell_jobs.pdx)
              [shell_history.pdx](../../src/kernel/core/svc/shell_history.pdx)
              [sys_exit.pdx](../../src/kernel/core/syscall/handlers/sys_exit.pdx)

---

## Table of contents

1. [Problem statement](#1-problem-statement)
2. [Why POSIX session cleanup is not inherited](#2-why-posix-session-cleanup-is-not-inherited)
3. [The paideia-os cascade model](#3-the-paideia-os-cascade-model)
   - 3.1 [Owners of session-attached state](#31-owners-of-session-attached-state)
   - 3.2 [Return band](#32-return-band)
4. [Cascade order](#4-cascade-order)
   - 4.1 [Jobs first, row release last](#41-jobs-first-row-release-last)
   - 4.2 [History: counters, not backing](#42-history-counters-not-backing)
   - 4.3 [Raw flags and active_job scrubs](#43-raw-flags-and-active_job-scrubs)
5. [Public API](#5-public-api)
   - 5.1 [`_shell_session_destroy` (extended)](#51-_shell_session_destroy-extended)
   - 5.2 [`_shell_session_teardown_notify`](#52-_shell_session_teardown_notify)
6. [Integration with `sys_exit` (step 2.65)](#6-integration-with-sys_exit-step-265)
7. [Idempotency and atomicity](#7-idempotency-and-atomicity)
8. [Fingerprint and observability](#8-fingerprint-and-observability)
9. [Deferred to R128+](#9-deferred-to-r128)

---

## 1. Problem statement

Between R127.M1 and R127.M5 a shell session accumulated **five**
in-kernel row footprints beyond its own slot in `_shell_session_pool`:

| Footprint                       | Added at | Where                                             |
|---------------------------------|----------|---------------------------------------------------|
| `history_head` / `history_tail` | M1       | `_shell_session_pool[row + 24 / 32]`              |
| `_shell_history_rings` slots    | M4       | `_shell_history_rings[sid * 16384 .. +16 KiB]`    |
| `raw_mode_flags`                | M3       | high 32 of `_shell_session_pool[row + 40]`        |
| rows in `_shell_jobs_pool`      | M5       | any row with high 32 of `[+0]` == this `sid`      |
| `active_job_pid`                | M5       | `_shell_session_pool[row + 120]`                  |

The R127.M1 `_shell_session_destroy` body only cleared `pid` and
`in_use`. Every later milestone layered state on top without
updating that teardown path. The resulting debt:

1. A reaped shell leaves job rows whose `session_id` points at a slot
   that `_shell_session_create` can and will reuse within the same
   boot — the next shell inherits the previous shell's zombies.
2. `history_head`/`history_tail` are per-row counters; a stale ring
   view bleeds the previous shell's commands into a new session when
   the slot recycles.
3. `raw_mode_flags` is in the high 32 of a u64 shared with `state`;
   the shift-anchor read in `_shell_session_get_raw` returns the
   previous shell's cooked/raw posture to the new shell.
4. `active_job_pid` can point at a pid the scheduler has already
   released or (worse) that the kernel has already recycled; the
   TTY byte-processing path then routes bytes to that pid.

R127.M6 lands the single cascade primitive that reclaims all five.
It is wired as a `sys_exit` hook so every shell-parent exit — graceful
or abnormal — pays the cost; a userspace call path (direct
`_shell_session_destroy` and the `KIND_SHELL_SESSION DESTROY` op)
also goes through the same cascade.

## 2. Why POSIX session cleanup is not inherited

POSIX sessions, process groups and `SIGHUP`-on-controlling-terminal-
loss are not retired because they are hard to implement — they are
retired because every one of them encodes a specific decision that
paideia-os's capability model answers differently:

- `setsid`/`setpgid` encode "group of pids" as a side table of
  globally-ordered identifiers (`sid`, `pgid`) that any process may
  look up and act on. paideia-os's analogue is `KIND_JOB` + the
  session row's `session_id` — a *capability* that must be held, not
  a number that can be invented.
- `SIGHUP` encodes "a dying terminal reaches up through a tree of
  pids and kills them." paideia-os routes TTY death through the
  capability holder (the shell parent); when its session row goes
  away, so does the TTY handle it minted, so does every job cap it
  minted under that session, by the capability model's own rules.
- `tcsetpgrp` encodes foreground as a per-tty attribute. paideia-os
  uses `active_job_pid` at `[row+120]` on the session row, mutable
  only by the holder of the session cap. The TTY itself is dumb.

The teardown this document defines is therefore not a port of POSIX
reaping. It is the direct consequence of the capability model:
when the row that owns the state goes away, the state goes away.
That is what §4 enumerates.

## 3. The paideia-os cascade model

### 3.1 Owners of session-attached state

| State                       | Owning row              | Reclaim verb                             |
|-----------------------------|-------------------------|------------------------------------------|
| job table rows              | `_shell_jobs_pool[j]`   | `_shell_jobs_destroy(j)` per matching row|
| history ring entries        | per-session ring        | zero `history_head` + `history_tail`     |
| raw-mode flags              | `[row+40]` high 32      | zero via shift-anchor                    |
| foreground job pointer      | `[row+120]`             | zero                                     |
| session row itself          | `_shell_session_pool`   | zero `pid` + `in_use`                    |

Three rows are **owned** by the session (jobs, history, session
itself); two are **fields** on the session row (raw flags, active
job). The cascade honours this: owned rows get a proper destroy
call that emits its own fingerprint; fields get a single store.

### 3.2 Return band

Two new codes, both in the SS band:

```
SS_TEARDOWN_OK            = 0        // alias of SS_OK
SS_TEARDOWN_NOT_SHELL_PID = 0x1108   // no-op success for non-shell pids
```

`SS_TEARDOWN_OK` deliberately aliases `SS_OK` so a caller that
treats "zero means fine" never needs to learn the new name.
`SS_TEARDOWN_NOT_SHELL_PID` is a dedicated code — not an error, not
a plain zero — because `sys_exit` calls this on **every** exit and
needs to tell "I tore down a session" from "there was nothing to
tear down." A plain zero would hide the distinction from the
fingerprint ring.

The band audit on 2026-10-13 (`grep -rnE '0x1108\b' src/kernel/`)
is clean; `0x1109..0x110F` remain reserved for R127.M7+.

## 4. Cascade order

### 4.1 Jobs first, row release last

The cascade reaps job rows BEFORE touching the session row because
`_shell_jobs_destroy` validates its argument against `sj_row_in_use`
which checks `primary_pid != 0` on the job row only; it does not
re-check whether the session the job claims to belong to is still
live. If we flipped the order — released the session row first,
then scanned jobs — a concurrent `_shell_session_create` could land
a new session on the just-freed slot and the subsequent job scan
would still match (the session_id on the stale job rows is the
numeric slot id, which the new session now owns). The job rows
would then be destroyed under the new session's identity.

Scanning jobs first takes a cost: 32 iterations of a comparison
loop on every teardown, including the common case of a shell with
zero jobs. The alternative — a per-session job linked list — is
rejected on the same ground that `shell_jobs.pdx` uses an open
array in the first place: it keeps the row at 64 bytes with
power-of-two stride, which is strictly cheaper per operation on
every path except this one.

### 4.2 History: counters, not backing

The 128 KiB `_shell_history_rings` backing is not zeroed. Two
reasons:

1. The ring is unreachable via the public API once
   `history_head == history_tail`. Both counters live on the
   session row; the cascade zeroes them in place. Any future
   `_shell_history_append` on a recycled session starts from
   `head == tail == 0` and writes slot 0 before reading anywhere;
   the ring entries are never read on a count-of-zero session.
2. The ring is 16 KiB per session, 128 KiB in total. A zero-fill
   on every exit is pure overhead on the dominant path (shell
   with modest history). An attacker that recycles a session slot
   and reads the ring would need both the KIND_SHELL_SESSION cap
   on the new session AND the capability model would have given
   them `history_head > 0` which the cascade guarantees it will not.

The pre-flush count (`history_head - history_tail`, clamped to
`[0, 128]`) is captured as `history_wiped` for the fingerprint.
This is observability only: nothing in the production path reads
it.

### 4.3 Raw flags and active_job scrubs

`raw_mode_flags` lives in the high 32 of `[row+40]` paired with the
`state` ordinal in the low 32. The shift-anchor idiom
(`shl 32; shr 32`) zeroes the high 32 while preserving the low 32
without hitting the `and r11, imm64` encoder gap. The scrub
restores the "cooked, with echo" default so a recycled session
starts in the shell's documented default posture rather than
inheriting the previous shell's raw-mode choice.

`active_job_pid` is a single aligned u64 at `[row+120]`. A single
`xor r9, r9; mov [r14 + 120], r9` is sufficient; there is no shared
field here to preserve.

## 5. Public API

### 5.1 `_shell_session_destroy` (extended)

```
_shell_session_destroy(session_id: u64) -> errno
```

Validates `session_id` via `ss_row_in_use`. On success:

1. Scans `_shell_jobs_pool[0..32)`; for each row where
   `primary_pid != 0` AND `(row[+0] >> 32) == session_id`, calls
   `_shell_jobs_destroy(job_id)` and increments `jobs_reaped`.
2. Loads `history_head - history_tail` into `history_wiped`;
   zeroes both counters.
3. Scrubs raw flags (shift-anchor).
4. Scrubs `active_job_pid`.
5. Zeroes `pid` at `[row+0]`.
6. Clears `in_use` at `[row+112]` LAST.

Emits two fingerprints at the tail:

- The legacy `SHELL_SESSION DESTROY OK sid=0x<hex>` for backward
  compatibility with the R127.M1 allowlist entry (deliberately
  kept to avoid a flag-day on `verify-fingerprint-coverage.sh`).
- The new `SHELL_SESSION TEARDOWN OK sid=0x<hex>
  jobs_reaped=<dec> history_wiped=<dec>` carrying the cascade
  counts.

Stack frame: four callee-save pushes (rbx, r12, r13, r14) plus
`sub rsp, 24` for the `klog_s1_x1_d2` stack-arg slots. The frame
is held for the entire body so every nested call sees `rsp%16==0`.

### 5.2 `_shell_session_teardown_notify`

```
_shell_session_teardown_notify(pid: u64) -> errno
```

The `sys_exit` entry point. Looks up the pid, and either forwards
to the extended `_shell_session_destroy` on a hit or returns
`SS_TEARDOWN_NOT_SHELL_PID` on a miss. Three return paths:

| Case                                    | Return                           |
|-----------------------------------------|----------------------------------|
| pid == 0                                | `SS_TEARDOWN_NOT_SHELL_PID`      |
| `_shell_session_lookup(pid)` is miss    | `SS_TEARDOWN_NOT_SHELL_PID`      |
| hit, destroy succeeds                   | `SS_TEARDOWN_OK` (= 0)           |
| hit, destroy races to BAD_ID            | `SS_ERR_BAD_ID`                  |

Single callee-save push. The BAD_ID case is benign (the row
cascaded on a previous call to this same function for the same
pid; the second call sees the row already free).

## 6. Integration with `sys_exit` (step 2.65)

`sys_exit_body` grows one step between the driver-death notify
(2.6) and the jail-child exit (2.7):

```
step 2.5    orphan_adopt(current->pid)
step 2.6    driver_death_notify(current->pid)
step 2.65   _shell_session_teardown_notify(current->pid)   ← R127.M6
step 2.7    _jail_supervisor_child_exit(current->pid)
```

Placement rationale:

- **After** `driver_death_notify`: a shell parent that was also a
  driver (unusual but possible) runs its R29 cascade first; the
  cascade's ChannelDead/DMA-domain-teardown effects should fire
  before any session row the task owned is swept.
- **Before** `_jail_supervisor_child_exit`: a shell living inside
  a jail reaps its own session cascades (which may reach into
  job rows) BEFORE the jail row itself goes away. The jail row
  carries the cap-env the shell's commands used to launch; if we
  reverse the order a job cascade that pokes any jail-rooted
  capability sees a freed row.
- **Before** the step 3+ parent-wake stores: every wake this
  syscall causes lands on one side of the state publish — the
  same discipline step 2.6 and step 2.7 already honour.

Register discipline on the hook site: 2 pushes (rdi, rsi; both
live downstream) plus `sub rsp, 8` for alignment. `rax = [rdi+0]`
reads the u32 pid; `mov rdi, rax` is the arg to the call. Return
value discarded — like 2.6, `sys_exit` has no way to refuse.

## 7. Idempotency and atomicity

**Idempotency** of `_shell_session_teardown_notify`: on a non-shell
pid (lookup miss) the function has no side effects beyond two
`ss_note` counter bumps. Called repeatedly on the same non-shell
pid, the only observable change is the counter values; nothing in
production reads those counters.

**Idempotency** of `_shell_session_destroy` after a successful
cascade: a second call sees `in_use == 0` from `ss_row_in_use` and
returns `SS_ERR_BAD_ID` with a REJ fingerprint. The cascade work is
not re-done. This is the right failure mode: a shell parent that
somehow calls `destroy` twice is a shell parent bug, and the
cascade's partial-work is the previous call's.

**Atomicity** is NOT guaranteed in M6:

- Each `_shell_jobs_destroy` is a single aligned store on its
  `primary_pid` field, atomic on its own.
- The session row's in_use is written LAST, after every field
  scrub, so a concurrent reader sees either a fully-live row or
  a fully-free row (the long-standing ss_row_in_use contract).
- But the pair "jobs cascade complete" + "session row free" is
  NOT atomic. A concurrent scanner that enumerates jobs and
  sessions could see jobs that still reference the dying
  session's slot even after the session row is freed.

M6 single-CPU IRQ context (dispatch_exit runs with IRQs disabled
in the current kernel posture) rules this out in practice; a
multi-CPU future with concurrent sys_exit will need either a
per-session rwlock or a `generation` counter on the session row
(the high 32 of `[+40]` was reserved for exactly this at R127.M1).
Both options are tractable; neither is prerequisite to M6.

## 8. Fingerprint and observability

The new fingerprint `SHELL_SESSION TEARDOWN OK sid=0x<hex>
jobs_reaped=<dec> history_wiped=<dec>` is emitted via
`klog_s1_x1_d2` (6-reg + 3-stack-arg wrapper). Stack args:
`[rsp+0] = jobs_reaped (dec)`, `[rsp+8] = &ss_k_history_wiped`,
`[rsp+16] = history_wiped (dec)`. The hex `sid` lives in `r8` per
the usual convention.

Three stats counters:

- `SS_ST_TEARDOWN_OK = 12`  — successful cascade completion.
- `SS_ST_TEARDOWN_NOTSH = 13` — `_shell_session_teardown_notify`
  returned `SS_TEARDOWN_NOT_SHELL_PID`.
- `SS_ST_TEARDOWN_NOTIFY = 14` — total entries into
  `_shell_session_teardown_notify` (incremented BEFORE the pid==0
  short-circuit so it counts every exit).

The `_shell_session_stats` array is 16 u64 wide (bumped at R127.M3
for the raw-mode slots); slot 15 remains reserved.

Allowlist entry in `tools/verify-fingerprint-coverage.sh`: the
`SHELL_SESSION TEARDOWN OK` entry documents three reach paths
(direct supervisor call, `KIND_SHELL_SESSION DESTROY` op, and
`sys_exit` step 2.65) and retires with the first smoke mode that
drives any one of them end-to-end.

## 9. Deferred to R128+

- A `generation` counter on the session row (high 32 of `[+40]`
  reserved at R127.M1) to make cascade/row-free pairs atomic on
  SMP.
- A `KIND_SHELL_SESSION TEARDOWN` cap-invoke op distinct from
  DESTROY, so a userspace supervisor can request cascade-with-
  counts without going through sys_exit. Current KIND_SHELL_SESSION
  DESTROY (R127.M2) calls `_shell_session_destroy` which now
  cascades implicitly; the explicit op is a surface-level
  convenience, not a semantic change.
- A `wait_result` channel on the session row so a user-mode
  parent can observe the cascade counts without parsing the klog.
  This belongs with R127.M7 (user-side `jobs` / `wait` builtins).
