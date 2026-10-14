# Shell job-control primitives (R127.M5)

Issue:        paideia-os#2601
Wave:         UMB-W16
Lands:        2026-10-13
Depends on:   R127.M1 (shell-session daemon), R127.M4 (history substrate),
              R125.M4 (syscall cap-check), R127.M3 (raw-mode TTY)
Supersedes:   nothing (greenfield; POSIX job control is explicitly retired)
Companion:    [shell_jobs.pdx](../../src/kernel/core/svc/shell_jobs.pdx)
              [shell_session.pdx](../../src/kernel/core/svc/shell_session.pdx)

---

## Table of contents

1. [Problem statement](#1-problem-statement)
2. [Why POSIX job control is not inherited](#2-why-posix-job-control-is-not-inherited)
3. [The paideia-os job model](#3-the-paideia-os-job-model)
   - 3.1 [Job as a first-class capability](#31-job-as-a-first-class-capability)
   - 3.2 [Job lifecycle state machine](#32-job-lifecycle-state-machine)
   - 3.3 [Transitions via cap-invoke ops, not signals](#33-transitions-via-cap-invoke-ops-not-signals)
   - 3.4 [Foreground semantics: `active_job_pid` routing](#34-foreground-semantics-active_job_pid-routing)
   - 3.5 [Background TTY output: deferred to M6](#35-background-tty-output-deferred-to-m6)
4. [Row layout (`shell_jobs.pdx`)](#4-row-layout-shell_jobspdx)
5. [Public API (direct-call surface)](#5-public-api-direct-call-surface)
6. [Interaction with substrates](#6-interaction-with-substrates)
   - 6.1 [R127.M1 shell-session](#61-r127m1-shell-session)
   - 6.2 [R125.M4 syscall cap-check](#62-r125m4-syscall-cap-check)
   - 6.3 [R127.M3 raw-mode TTY](#63-r127m3-raw-mode-tty)
   - 6.4 [R127.M4 history ring](#64-r127m4-history-ring)
7. [Return code band (0x1600)](#7-return-code-band-0x1600)
8. [Boot wiring](#8-boot-wiring)
9. [Observability](#9-observability)
10. [Encoder-pitfall posture](#10-encoder-pitfall-posture)
11. [Follow-on work (R127.M6+)](#11-follow-on-work-r127m6)
12. [References](#12-references)

---

## 1. Problem statement

A paideia-os REPL dispatches multiple commands over a single TTY. The shell
must be able to:

1. **Launch a command in the background** (`find /home &`) and return to the
   prompt before the command finishes.
2. **Pause a running command** and resume it later (`^Z`-equivalent, `jobs`,
   `fg`, `bg`).
3. **Promote a background job to the foreground** so its stdin / stdout are
   wired back to the TTY.
4. **Enumerate live jobs** under the current shell session.
5. **Wait synchronously** on a job's exit disposition.

Classical Unix solved these with four mechanisms: `SIGTSTP` / `SIGCONT`
signals, process groups, the TTY foreground pgrp, and the `wait*` family of
syscalls that scrape zombie process state. The combination is historical
sediment, not a clean design — see §2.

paideia-os needs the same user-visible outcomes (`&`, `fg`, `bg`, `jobs`,
`kill %<n>`) delivered through a clean capability-shaped substrate.

---

## 2. Why POSIX job control is not inherited

The novel-and-clean design posture (feedback_novel_clean_design) requires we
examine the POSIX mechanism and reject it on specific grounds, not merely by
reflex. The grounds:

### 2.1 Process groups are PDP-11 sediment

Process groups were invented in 4BSD circa 1980 to encode the hierarchy of
"all commands launched from one pipeline" so the controlling terminal could
deliver a signal (`^C`) to the entire group. The decision was constrained by
PDP-11 memory: each process could not afford its own TTY controller
reference, so the group id was the smallest integer that could serve as a
multiplexing index. The group / session / foreground-pgrp triple that
followed (`setsid`, `setpgid`, `tcsetpgrp`) is a layered patch on that
original index-economy constraint.

paideia-os has no memory constraint of that shape. A capability-typed
`Job` identifier is first-class and cheap. The group index is a 1980 answer
to a 1980 question.

### 2.2 Signals are a weak IPC primitive

A POSIX signal carries no payload beyond its ordinal, no return value,
no synchronous acknowledgement, and the handler runs in a race with the
mainline program state. `SIGTSTP` and `SIGCONT` land asynchronously on
whatever cycle the kernel chooses, so a program can observe partial state
right before the stop; `SIGCONT` has no "please resume from exactly where
you left off" contract — it is up to the program's handler to redo
whatever was in flight.

paideia-os's capability-invoke ABI (R125.M1 cap-env, R127.M2
KIND_SHELL_SESSION op surface) delivers each op as a synchronous,
return-value-carrying call. Pausing a job is therefore a well-typed
"transition this `Job` capability to `PAUSED`" call, not an asynchronous
signal.

### 2.3 TTY foreground pgrp is a race hazard

A classical shell has to perform `tcsetpgrp(fd, child_pgrp)` after `fork()`
but before `exec()` — the child cannot do it after exec because the TTY may
have moved on, and the parent cannot do it reliably because the child may
not yet have `setpgid`'d itself. Every shell carries elaborate
synchronisation (pipe barriers, retry loops) to work around the window.

paideia-os routes TTY input and output through a `Job` capability, and the
shell-session's single `active_job_pid` field is the authoritative routing
slot — there is no window during which the TTY is "between" owners because
transitioning foreground is an atomic write of that field (§3.4).

### 2.4 `wait*` scrapes zombie state

POSIX's `waitpid` reads the exit status from a `struct task_struct` that
has stayed alive specifically because the kernel knows a wait is pending.
This is a leaked implementation detail: processes exist in a "half-dead"
state so their status can be read. paideia-os's `Job` row has an explicit
`state` field with `COMPLETED` / `FAILED` ordinals; the exit disposition is
stored in `flags`, and the row stays live until `_shell_jobs_destroy`
explicitly frees it. There is no zombie.

### 2.5 What we keep

We keep the **user-visible verbs** (`&`, `fg`, `bg`, `jobs`, `kill %<n>`) —
the shell has to look like a shell. Every verb above is implemented in
terms of the clean substrate; the `.pdx` user-builtin that lands with
R127.M6 translates each one to a cap-invoke call against a `KIND_JOB`
capability.

---

## 3. The paideia-os job model

### 3.1 Job as a first-class capability

A `Job` is a first-class capability (`KIND_JOB`, reserved for a future
wave adjacent to R127.M2's `KIND_SHELL_SESSION`). The capability wraps:

- **One or more PIDs** that constitute the pipeline (R127.M5 lands only
  single-PID jobs; pipelines are an R127.M7+ extension that groups
  multiple PIDs under one `Job`).
- **The owning session_id** — a `Job` always belongs to exactly one
  `shell_session` row.
- **A primary PID** — the "head" of the pipeline (for a single-command
  job this is simply the only PID).
- **A current state** — `RUNNING` / `PAUSED` / `COMPLETED` / `FAILED`.
- **A flags word** — carries exit-code and disposition bits.
- **A display name** — up to 32 bytes of the original command line.

The holder of a `KIND_JOB` capability may invoke the op surface described
in §3.3 to pause / resume / move the job between foreground and background,
or wait on its completion.

### 3.2 Job lifecycle state machine

Four states; transitions are a clean DAG with no cycles across live rows:

```
         +---------+                 +---------+
     create   RUNNING  <--- PAUSE ---  PAUSED  |
     ------>          --- RESUME --->          |
         |         |                 |         |
         |         +-------+---------+         |
         |                 |                   |
         |     COMPLETE or FAIL                |
         |                 |                   |
         |                 v                   v
         |          +------------+      +------------+
         |          | COMPLETED  |      |  FAILED    |
         |          +------------+      +------------+
         |                 |                   |
         |              destroy             destroy
         |                 |                   |
         +---> (row free) <+---> (row free) <--+
```

The INIT ordinal is implicit — a row is minted directly into `RUNNING`.
The two terminal states (`COMPLETED` / `FAILED`) are reached when the
job's primary PID exits with a zero / non-zero disposition respectively.
`_shell_jobs_destroy` is the only path back to the free pool.

**M5 posture.** `_shell_jobs_set_state` validates both the row and the
target ordinal (`state < SJ_STATE_MAX`) but is **permissive** across the
state machine — any valid state may transition to any other valid state.
R127.M6 (KIND_JOB cap-invoke surface) tightens the transitions as above.

### 3.3 Transitions via cap-invoke ops, not signals

The ops reserved on the `KIND_JOB` capability (dispatch arm lands with
R127.M6):

| Ordinal | Op                | Semantics                                      |
| ------- | ----------------- | ---------------------------------------------- |
| 1       | `JOB_OP_PAUSE`    | Transition RUNNING -> PAUSED. Thread scheduler is told to stop issuing timeslices to the primary PID until a resume lands. |
| 2       | `JOB_OP_RESUME`   | Transition PAUSED -> RUNNING. Thread scheduler re-admits the primary PID to its run queue. |
| 3       | `JOB_OP_FOREGROUND` | Set `shell_session.active_job_pid = this.primary_pid`. Routes TTY input / output back to the primary PID (§3.4). |
| 4       | `JOB_OP_BACKGROUND` | Clear `shell_session.active_job_pid` iff it currently equals this job's primary_pid; else no-op. The shell is now the foreground reader again. |
| 5       | `JOB_OP_WAIT`     | Caller blocks until the job's state is `COMPLETED` or `FAILED`. Returns the exit disposition from the row's `flags` field. |

Each op is a synchronous cap-invoke returning `SJ_OK` or an `SJ_ERR_*`
code — no asynchronous signal delivery, no post-condition races. The
`JOB_OP_PAUSE` call returns only once the scheduler has acknowledged the
state transition and committed it to the primary PID's run queue; a
subsequent `JOB_OP_RESUME` sees the row in a well-defined state.

### 3.4 Foreground semantics: `active_job_pid` routing

The shell-session row (R127.M1 §1) has a reserved u64 at `[row + 120]`.
R127.M5 **re-interprets** this field as `active_job_pid`:

- Value `0` = **shell is foreground**. TTY input lands in the shell's own
  stdin and TTY output lands on the shell's own prompt.
- Value `P` where `P != 0` = the job whose `primary_pid == P` is
  foreground. TTY input routes to that PID's stdin; TTY output from that
  PID writes to the TTY directly, while TTY output from the shell is
  queued (R127.M6 extension) or dropped (R127.M5 posture; the shell
  simply does not write while a foreground job runs).

**Atomicity.** `JOB_OP_FOREGROUND` is a single `mov [row+120], primary_pid`
8-byte store. There is no "between owners" state; a reader either sees the
old owner or the new one.

**Why not a session field?** We considered storing `active_job_pid` as a
separate dedicated field in `shell_jobs` rows (one row would be flagged
`fg=1`). The session-side field wins because the TTY layer (R127.M3
raw-mode / R127.M4 history) already consults the shell-session row for
every byte it processes — adding one more field read to the hot path is
free, while cross-referencing a jobs row from the TTY would require a
scan.

### 3.5 Background TTY output: deferred to M6

M5 does **not** land a per-job TTY output ring. Background jobs that write
to stdout while another job is foreground see their output currently
dropped (the shell's output pipeline is single-reader at M5). R127.M6
lands a per-job output ring (shape: 2 KiB bounded ring per job, drain-on-
foreground semantics) so background jobs can accumulate output and have
it replayed when they are promoted to foreground.

The design is intentionally deferred — the single-reader M5 posture lets
the ring design wait on the real workload shape to settle, rather than
committing to a buffer size and overflow policy prematurely.

---

## 4. Row layout (`shell_jobs.pdx`)

Each row is 64 bytes = 8 u64. Stride 64 is a power of two so row addressing
uses `shl rax, 6` — no 2-op `imul` (feedback_pdx_encoder_pitfalls).

```
  [+0]    job_id (u32) | session_id (u32) << 32   -- one u64 store
  [+8]    primary_pid                              -- u64; 0 = row free sentinel
  [+16]   state (u32) | flags (u32) << 32          -- one u64 store
  [+24]   name[ 0.. 7]                             -- u64 word of 8 raw bytes
  [+32]   name[ 8..15]                             -- u64 word
  [+40]   name[16..23]                             -- u64 word
  [+48]   name[24..31]                             -- u64 word (32 total; last byte NUL)
  [+56]   created_tsc                              -- u64 (reserved at M5; populated at R127.M6)
```

Pool capacity: `SJ_POOL_MAX = 32` rows (jobs are more numerous than
sessions; 8 sessions × 4 average concurrent jobs = 32 slots). `32 × 64 =
2048 bytes = 256 u64`.

**Free sentinel.** `primary_pid == 0` is the authoritative "row free"
indicator; pid 0 is reserved by the shell contract so a live job never
holds that value. .bss zero-init gives us the free sentinel at real
boot; chaos-restart scrub is handled by `_shell_jobs_init`.

**Why pid-as-sentinel instead of an `in_use` word.** shell_session.pdx
uses an explicit `in_use` field at `[+112]` so pid 0 could in principle
be allowed in a future refactor. shell_jobs.pdx has no equivalent future;
pid 0 is permanently reserved by every OS layer below the shell, and the
row is 64 bytes — adding an `in_use` word would push to 72 bytes and
lose the clean `shl 6` stride.

---

## 5. Public API (direct-call surface)

```
_shell_jobs_init() -> ()
_shell_jobs_create(session_id, primary_pid, flags, name_ptr, name_len)
                                                           -> packed u64
_shell_jobs_lookup_by_pid(primary_pid) -> job_id | SJ_ID_NONE
_shell_jobs_set_state(job_id, new_state) -> errno
_shell_jobs_destroy(job_id) -> errno
```

**Packed return of `_shell_jobs_create`:**

```
   result = (job_id << 2) | status
```

On success `status == SJ_OK (0)`, so `result == job_id << 2`. Job ids live
in `[0, 32)` so `job_id << 2` lies in `[0, 128)` — disjoint from every
`SJ_ERR_*` value (all `>= 0x1600`), so a caller may treat the whole u64
as a tagged value without collision.

`_shell_jobs_lookup_by_pid` returns the raw job_id or `SJ_ID_NONE` (0xFF)
on miss — same convention as `_shell_session_lookup`.

**`_shell_session_set_active_job`.** The companion write on the
shell-session side:

```
_shell_session_set_active_job(session_id, job_pid) -> errno
```

Validates `session_id` via `ss_row_in_use` and writes
`[row + 120] = job_pid`. Called by `JOB_OP_FOREGROUND` and
`JOB_OP_BACKGROUND` (which passes `0`) at R127.M6; direct-call surface
at M5 so a kernel-side witness can exercise the write path.

---

## 6. Interaction with substrates

### 6.1 R127.M1 shell-session

The shell-session row at `[+120]` is re-interpreted as `active_job_pid`.
The low 32 / high 32 bits of `[+40]` (state / reserved) remain untouched.
No other field on the row changes meaning.

The `created_tsc` field on the jobs row carries forward the shell-
session's own creation idiom (future wave): a monotonic hardware tick
captured at mint lets a job age-sort pass identify stale rows.

### 6.2 R125.M4 syscall cap-check

A `JOB_OP_PAUSE` lands in the scheduler through a dedicated kernel
helper (R127.M6 wires it). The helper is invoked under the caller's
cap-env and the cap-check preamble (R125.M4) will refuse a caller that
lacks `R_SYS_SIGNAL`-equivalent rights on `KIND_JOB` — once R127.M6
lands the kind + the rights-table entry.

M5 adds **no** new entry to `_syscall_rights_table`. The jobs substrate
is reachable only through the direct-call API (in-kernel witnesses)
and, from userspace, through the cap-invoke surface added by R127.M6.

### 6.3 R127.M3 raw-mode TTY

The raw-mode flags on the shell-session row (`[row+44]`) control line
discipline. The TTY byte-processing path consults
`_shell_session_get_raw(session_id)` byte-by-byte. R127.M5 adds a sibling
consultation: `[row+120]` (the `active_job_pid`) tells the TTY where to
route each processed byte.

**No lock.** The two reads are of two different u64 words and need no
atomicity between them; a race on the two reads sees at worst one byte
delivered to the just-previous owner, which is the same latency a POSIX
`tcsetpgrp` race presents (and well under the ms-scale a human notices).

### 6.4 R127.M4 history ring

A job's command text is captured in the per-session history ring at
command-dispatch time (R127.M4 `_shell_history_append`). The job row's
`name[0..31]` field is a 32-byte truncated copy of the first 31 bytes of
the same command (plus trailing NUL) so a `jobs` enumeration can print
the command without re-reading the ring. The duplication is intentional:
the ring entry carries the full command (up to 126 bytes); the row's
name carries a short label for the enumeration.

---

## 7. Return code band (0x1600)

```
  SJ_OK                 = 0
  SJ_ERR_POOL_FULL      = 0x1600
  SJ_ERR_BAD_ID         = 0x1601
  SJ_ERR_BAD_STATE      = 0x1602
```

All fit `imm32` with bit 31 clear so `mov rax, imm32` emits the 7-byte
zero-extending form (never `and r11, imm64`). Band audit (2026-10-13):
`grep -rnE '0x160[0-2]\b' src/kernel/` returns zero hits in the
production tree — clean band. R127.M6+ may extend to `0x1603..0x160F`
while retaining the first three as pinned.

**Future reservations** (not landed at M5):
```
  SJ_ERR_BAD_PID        = 0x1603   (R127.M6; create rejects pid==0 or dup)
  SJ_ERR_NO_FG          = 0x1604   (R127.M6; BACKGROUND on a non-fg job)
  SJ_ERR_NOT_WAITABLE   = 0x1605   (R127.M6; WAIT on a RUNNING job in a
                                     non-blocking context)
```

---

## 8. Boot wiring

`kernel_main.pdx` picks up the jobs substrate with one new call right
after `_shell_history_init` (R127.M4), BEFORE `_jail_supervisor_init`:

```
  call _shell_history_init;    // R127.M4
  call _shell_jobs_init;       // R127.M5 (this landing)
  call _jail_supervisor_init;  // R135.M1
```

Placement rationale: the jobs substrate is a *library* (no endpoint
claimed), same posture as `_shell_history_init` — so it slots directly
after the other shell-side libraries and before the supervisor
daemons. An audit grep then sees the shell substrates in the order
`SHELL_SESSION -> SHELL_HISTORY -> SHELL_JOBS`.

---

## 9. Observability

The 16-slot `_shell_jobs_stats` counter array (per-row widening policy —
same shape as `_shell_history_stats`):

| Slot | Name                     | Bumped on                                 |
| ---- | ------------------------ | ----------------------------------------- |
| 0    | `SJ_ST_INIT_OK`          | Successful `_shell_jobs_init`             |
| 1    | `SJ_ST_CREATE_OK`        | Successful mint                           |
| 2    | `SJ_ST_CREATE_FULL`      | Pool-full rejection                       |
| 3    | `SJ_ST_STATE_OK`         | Successful set-state                      |
| 4    | `SJ_ST_STATE_BAD_ID`     | Set-state refused with BAD_ID             |
| 5    | `SJ_ST_STATE_BAD_STATE`  | Set-state refused with BAD_STATE          |
| 6    | `SJ_ST_LOOKUP_HIT`       | Lookup by pid resolved to a live row      |
| 7    | `SJ_ST_LOOKUP_MISS`      | Lookup by pid returned SJ_ID_NONE         |
| 8    | `SJ_ST_DESTROY_OK`       | Successful destroy                        |
| 9    | `SJ_ST_DESTROY_BAD_ID`   | Destroy refused with BAD_ID               |
| 10-15| reserved                 | R127.M6 (SJ_ST_PAUSE / RESUME / FG / BG / WAIT_WAKE) |

Fingerprints emitted at M5:

- `SHELL_JOBS INIT OK` — on every boot.
- `SHELL_JOBS CREATE OK jid=0x<hex> pid=0x<hex>` — on successful mint.
- `SHELL_JOBS CREATE REJ errno=0x<hex>` — on refusal.
- `SHELL_JOBS STATE OK jid=0x<hex> state=<dec>` — on successful set-state.
- `SHELL_JOBS STATE REJ errno=0x<hex>` — on refusal.
- `SHELL_JOBS DESTROY OK jid=0x<hex>` — on successful destroy.
- `SHELL_JOBS DESTROY REJ errno=0x<hex>` — on refusal.
- `SHELL_SESSION ACTIVE_JOB OK sid=0x<hex> pid=0x<hex>` — on
  `_shell_session_set_active_job` success.
- `SHELL_SESSION ACTIVE_JOB REJ errno=0x<hex>` — on refusal.

Only the `INIT OK` tag reaches the smoke-mode wire at M5 (the substrate
has no production caller yet). The other `OK` tags are allowlisted
upstream in `tools/verify-fingerprint-coverage.sh`; they retire from
the allowlist when R127.M6 lands the KIND_JOB op surface with an
asserting smoke-mode golden.

---

## 10. Encoder-pitfall posture

Standard discipline (feedback_pdx_encoder_pitfalls):

- `cmp rN, 0`              — never `test rN, rN`.
- `shl rN, 6`              — row-base stride 64 compose; never
                             2-op `imul r, imm`.
- `mov rax, imm32`         — all error codes (0x1600 band fits with
                             bit 31 clear); never `and r11, imm64`.
- Shift-anchor for low-32  — preserve state (low 32) across a flags
  preservation                write via `shl r11, 32; shr r11, 32`,
                              mirroring R127.M3 `_shell_session_set_raw`.
- Single-line `pub let name = "..."`.
- Module basename `ShellJobs` matches file basename `shell_jobs.pdx`.
- Fingerprint `[u8; N]` with N = string length + 1 (NUL counts).
- Label prefix `sj_` (shell-jobs) stays clear of `ss_` / `sh_` / `svc_` /
  `js_` (jail-supervisor) and the broader `s_` family. No reserved
  paideia-as keyword overlap (reserved: `loop` / `if` / `let`).

Stack discipline (SysV, entry `rsp%16==8`):

| Function                            | Push count | sub rsp |
| ----------------------------------- | ---------- | ------- |
| `_shell_jobs_init`                  | 1 (r12)    | 0       |
| `_shell_jobs_lookup_by_pid`         | 0 (leaf)   | 0       |
| `_shell_jobs_create`                | 5 (rbx r12 r13 r14 r15) | 16 (klog_s1_x1_d1 stack-arg slot + pad) |
| `_shell_jobs_set_state`             | 2 (rbx r12) | 8 (klog_s1_x1_d1 stack-arg) |
| `_shell_jobs_destroy`               | 1 (rbx)    | 0       |
| `_shell_session_set_active_job`     | 2 (rbx r12) | 0       |

Entry parity recovery: 8 + push_count * 8 + sub_rsp must land multiple-of-16
at every nested call site (SysV ABI).

---

## 11. Follow-on work (R127.M6+)

The R127.M5 landing is **substrate-only**. The following items are
deferred and listed here so the next milestone has a clean punch list:

1. **`KIND_JOB` kind registration** adjacent to `KIND_SHELL_SESSION`
   (R127.M2), with the five op ordinals from §3.3 and the rights-mask
   entries (`R_JOB_READ` / `R_JOB_PAUSE` / `R_JOB_WAIT` / etc.).
2. **Scheduler pause / resume hook**: the thread scheduler needs a
   capability-authenticated entry point so `JOB_OP_PAUSE` can halt the
   primary PID without going through a POSIX signal shim.
3. **TTY routing**: the TTY input / output path (R127.M3) consults
   `shell_session.active_job_pid` on every byte. R127.M6 wires that
   consultation; M5 only lands the routing field.
4. **Background output ring** (§3.5): a 2 KiB per-job output ring,
   drain-on-foreground semantics.
5. **Pipeline grouping**: multi-PID jobs under one `Job` capability
   (R127.M7).
6. **User-side builtins**: `.pdx` implementations of `fg`, `bg`, `jobs`,
   `kill %<n>` in `src/user/shell/` that translate each verb to a
   cap-invoke on a `KIND_JOB` capability (R121.M5 adjacent).
7. **Exit disposition capture**: the exit-handler path writes the exit
   code into the row's `flags` field (high 32 of `[row+16]`) and
   transitions `state` to `COMPLETED` or `FAILED` based on the code sign.

Each item is already issue-shaped as a decomposition under R127. The M5
substrate neither blocks nor pre-empts their design — it merely gives
them a stable row pool and return-code band to land against.

---

## 12. References

- design/shell/shell-session-daemon.md — R127.M1 row-pool substrate.
- design/shell/shell-history-substrate.md — R127.M4 ring substrate (shape
  template for R127.M5).
- design/shell/raw-mode-tty.md — R127.M3 raw-mode flag landing.
- design/shell/syscall-cap-check.md — R125.M4 cap-check preamble.
- src/kernel/core/cap/kind_shell_session.pdx — R127.M2 cap-invoke surface
  (shape template for R127.M6 KIND_JOB).
- src/kernel/core/svc/shell_session.pdx — R127.M1 daemon + the R127.M5
  `_shell_session_set_active_job` extension.
- src/kernel/core/svc/shell_jobs.pdx — the R127.M5 jobs substrate.
- feedback_novel_clean_design — the novel-over-POSIX bias this doc
  argues against §2.
- feedback_pdx_encoder_pitfalls — the encoder-discipline posture
  recited in §10.
