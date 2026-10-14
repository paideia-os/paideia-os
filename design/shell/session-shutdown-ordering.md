# Multi-session shutdown ordering (R139.M4)

> paideia-os `#2642` · Wave UMB-W22 · landing: `src/kernel/core/svc/session_shutdown.pdx`

This document captures the design behind the **wholesale** shutdown
coordinator introduced at R139.M4. It frames the problem the
coordinator solves, pins the ordering doctrine, explains the
idempotency guarantees, and traces the interaction with the per-session
teardown cascade that landed at R127.M6 (Wave UMB-W17).

---

## 1. Problem statement

### 1.1 Where R127.M6 stops

R127.M6 (`_shell_session_destroy` in `svc/shell_session.pdx`) landed the
**per-row** cascade: given one shell session, it reaps the jobs owned by
that session, flushes its history ring counters, scrubs its raw-mode
flags, zeroes its `active_job_pid`, zeroes its pid, and clears
`in_use` last (publication contract: a concurrent scanner must see
either a fully-live row or a fully-free row, never an interleaved
view).

That is the right shape for a single-session exit — the ordinary case
is `sys_exit` of a shell parent task invoking
`_shell_session_teardown_notify(pid)`, which cascades to
`_shell_session_destroy(sid)` on a lookup hit.

But a per-row cascade **cannot** be the right shape for:

- a clean **kernel shutdown** (sys_shutdown handler, R145+ landing),
- a **chaos-restart entry** sequencer (R150+ landing, replaying from
  the last audit chain tail),
- a **jail subtree exit** (one shell session plus everything spawned
  underneath it).

The reason is that four shutdown-relevant subsystems are **invisible**
to a loop over `SS_POOL_MAX`:

| Subsystem        | Pool                   | Why a session loop misses it                        |
|------------------|------------------------|-----------------------------------------------------|
| cmd_audit        | `_cmd_audit_pool`      | Ring of 128 records; many may be PENDING without an owner session row. |
| remote_shell     | `_remote_shell_pool`   | No `session_id` back-link at R137.M4.                |
| jail_supervisor  | `_jail_supervisor_pool`| Jail pid is a jailed child's pid, not necessarily the shell owner's. |
| shell_jobs       | `_shell_jobs_pool`     | A stale row with no live owning session is still an in-use job row.  |

R139.M4 lifts the discipline **wholesale**: an 8-step pipeline that
walks every subsystem in a specific order **before** invoking the
per-row cascade on each shell session.

### 1.2 Why ordering matters

Three concrete cross-dependency failure modes drive the ordering:

1. **Audit after session destroy would strand records.** If a PENDING
   `_cmd_audit_begin` is still open when its owning command's session
   is destroyed, the hash chain is left with a slot whose `this_hash`
   was never computed. A subsequent `_cmd_audit_verify` of a later
   record then fails the `prev_hash` cross-check against the gap.
   The forensic value of the audit log is destroyed by a shutdown
   that forgets to finalize PENDING first.

2. **Local session reply held hostage by remote-shell waiter.** A
   remote-shell connection in `RS_STATE_ESTABLISHED` holds a KEM
   session slot and (post R137.M3) a wire-record protocol pump that
   may be WAITING on a reply from a local session's command
   dispatcher. If the local session is destroyed first, the pump's
   reply path never arrives; worse, the connection row still holds
   a nonzero `kem_session_slot` that the next `_accept` could
   mis-attribute. Closing remote-shell **first** flushes any waiter
   before the local session's reply path is torn down.

3. **Job observing a half-destroyed jail.** A job's `sys_exit`-path
   syscall check (`_jail_supervisor_check_syscall`) walks jail rows.
   If a jail is partway through destruction when a job's exit path
   consults the row, the lookup is undefined. Destroying jails
   **before** reaping jobs eliminates the race: once a jail row's
   `in_use` is clear, no job's exit path considers it.

---

## 2. The ordering doctrine

The 8 steps of `_ssd_shutdown_all`:

```
                           +------------------------+
                           |  1. FLUSH audit chain  |
                           |     every PENDING slot |
                           +-----------+------------+
                                       |
                           +-----------v------------+
                           |  2. CLOSE remote-shell |
                           |     CLOSING -> CLOSED  |
                           +-----------+------------+
                                       |
                           +-----------v------------+
                           |  3. DESTROY jails      |
                           |     _jail_sup_destroy  |
                           +-----------+------------+
                                       |
                           +-----------v------------+
                           |  4. REAP jobs          |
                           |     _shell_jobs_destroy|
                           +-----------+------------+
                                       |
                           +-----------v------------+
                           |  5. FLUSH history ring |
                           |     head=0, tail=0     |
                           +-----------+------------+
                                       |
                           +-----------v------------+
                           |  6. SCRUB raw flags    |
                           |     shift-anchor hi32  |
                           +-----------+------------+
                                       |
                           +-----------v------------+
                           |  7. ZERO active_job_pid|
                           |     [row+120] = 0      |
                           +-----------+------------+
                                       |
                           +-----------v------------+
                           |  8. DESTROY sessions   |
                           |     _shell_session_... |
                           +------------------------+
```

### 2.1 Step rationale

**Step 1 — audit flush first.** Audit integrity dominates every other
concern because the audit chain is the only cross-shutdown forensic
record. Finalize every PENDING slot with a dedicated shutdown-synthetic
exit code (`SSD_SHUTDOWN_EXIT = 0xFFFFFFFF`) so a later verify can
distinguish *"command finished with exit=X"* from *"command interrupted
by shutdown"*. Only after step 1 completes may we touch any state the
audit records refer to (`cmd_hash`, `argv_hash`, `cap_env_fingerprint`
all live in the record itself, so the destroy of other subsystems does
not disturb the record contents — but a PENDING slot not finalized
BEFORE those subsystems unwind is a corrupted record forever).

**Step 2 — remote before local.** A remote-shell connection whose reply
path reaches a local session must be allowed to collapse first.
Transitioning each in-use row through `CLOSING` before `CLOSED`
preserves the state machine's monotonicity so an observer who scans
mid-shutdown sees either `ESTABLISHED` (not yet touched), `CLOSING`
(step 2 in flight), or `CLOSED` (step 2 complete) — never a direct
`ESTABLISHED -> CLOSED` jump that would skip the KEM-slot zero write
in the daemon-side listener.

**Step 3 — jails before jobs.** A jail's `check_syscall` is consulted
on every syscall by a jailed process; a job's exit path invokes a
syscall. Destroying jails first means a job's exit-path syscall check
either reads a live jail row or reads a cleanly-freed row with
`in_use == 0` (the pass-through path). Destroying jails after jobs
would create a window where a job's syscall check sees a jail row
whose `pid` or `syscall_mask` was partially scrubbed.

**Step 4 — jobs after jails, before shell_session.** A job row carries
`session_id` in `[row+0] >> 32`. Reaping jobs before the per-session
pre-scrub means step 5-7 see an already-clean jobs pool for the
sessions they're about to walk. Reaping jobs after the per-session
destroy would leave orphan job rows pointing at a freed session_id.

**Step 5 — history ring flush.** Head/tail counters cleared **first**
in the per-session scrub so a reader that races the scrub sees either
head/tail nonzero (ring still being read) or head==tail==0 (ring
flushed). The 128-KiB ring **backing** is NOT scrubbed; a stale slot
is unreachable once `head == tail` and a future `_shell_history_
append` overwrites on write. Scrubbing the backing on shutdown would
burn 128 KiB of unnecessary writes.

**Step 6 — raw-mode flags scrub.** The TTY line discipline reads
`row[+40]` high 32 bits to decide whether to deliver bytes raw or
through cbreak/echo. Clearing the hi32 before step 8 means that an
observer in the interval between step 7 and step 8 sees the session
behaving as a cooked-mode terminal (the safe default) rather than
with a stale raw bit set. The scrub uses the shift-anchor idiom
(`shl 32; shr 32`) to preserve the low 32 state ordinal without the
`and r11, imm64` encoder gap (`feedback_pdx_encoder_pitfalls`).

**Step 7 — active_job_pid zero.** `[row+120]` holds the primary pid
of the currently-foreground job under this session. Steps 3 (jail
destroy) and 4 (job reap) may have freed that pid's owner. Zeroing
active_job_pid **before** step 8 means a late observer sees a
canonical "no foreground job" row, not a dangling pid.

**Step 8 — shell_session destroy.** The final row release, which runs
the R127.M6 cascade internally. On this wholesale path the cascade is
**redundant** with steps 4-7 (every target field has already been
scrubbed) but step 8 is the sole authority for the "clear in_use
LAST" publication contract, so we route through it unconditionally.

### 2.2 Why step 8 keeps the cascade even on this path

A natural optimization would be to replace step 8 with a tight loop
that only clears `in_use`, bypassing R127.M6's inner cascade. We
**reject** this on three grounds:

1. **Single-authority principle.** The `in_use`-LAST publication
   contract has one owner (`_shell_session_destroy`). Duplicating the
   publish logic in a shortcut makes future hardening of the contract
   (R30 witness-side observation checks) brittle.

2. **No measurable cost.** The inner cascade's reap loop sees zero
   matching jobs (step 4 already freed them). Its history/raw/active-
   job scrubs re-zero already-zero fields. Total: 32 inert comparisons
   per session + 4 pointless stores. Negligible against the 8-row
   loop.

3. **Composability.** R145+ `sys_shutdown` is likely to want a
   platform-witness drill that calls `_ssd_shutdown_all` in isolation.
   Keeping step 8 as `_shell_session_destroy` means the witness can
   assert `SHELL_SESSION TEARDOWN OK` fingerprints exactly as it does
   today.

---

## 3. Idempotency

`_ssd_shutdown_all` is **safe to call twice**. On the second call:

- step 1: no slot has the PENDING bit; the loop is a scan with zero
  calls to `_cmd_audit_end`.
- step 2: every in-use remote-shell row was closed on the first call;
  `in_use == 0`; the loop skips every row.
- step 3-4: same shape — every in-use jail / job row is now free.
- step 5-7: no in-use shell_session row remains; the loop skips every
  row.
- step 8: no in-use shell_session row remains; the loop skips every
  row.

Result: SSD_OK with zero inner calls.

`_ssd_shutdown_subtree(sid)` is **safe to call twice** by the same
argument: the first call clears `in_use` on the session row via
`_shell_session_destroy`, and the second call fails the
`ss_row_in_use` check and returns SSD_OK on the no-op path.

---

## 4. Interaction with R127.M6 teardown cascade

R127.M6 and R139.M4 are **composable layers**:

| Layer       | Scope       | Entrypoint                      | Lifecycle event                                                    |
|-------------|-------------|---------------------------------|-------------------------------------------------------------------|
| R127.M6     | per-row     | `_shell_session_destroy`        | `sys_exit` of a shell parent (via `_shell_session_teardown_notify`) |
| R127.M6     | per-row     | `_shell_session_destroy`        | `KIND_SHELL_SESSION DESTROY` cap-invoke op                          |
| R139.M4     | wholesale   | `_ssd_shutdown_all`             | kernel shutdown, chaos-restart entry (future)                       |
| R139.M4     | subtree     | `_ssd_shutdown_subtree`         | jail-tree exit (future)                                             |

The two layers never duplicate authority:

- R127.M6 is the **sole** owner of a single row's cascade.
- R139.M4 is the **sole** owner of the cross-subsystem pipeline.
- R139.M4 step 8 calls R127.M6's entrypoint rather than reimplementing
  it.
- R127.M6 is unaware of R139.M4 (no reverse coupling); R127.M6 remains
  callable from `sys_exit` without touching the shutdown coordinator.

The redundancy in R139.M4's step 8 (R127.M6 scrubs fields that steps
5-7 already zeroed) is the price of layering — it buys us two
callers for R127.M6 (the sys_exit path and the shutdown coordinator)
without a flag parameter telling R127.M6 which caller it has.

---

## 5. Return codes

| Code                   | Hex    | Meaning                                                                                           |
|------------------------|--------|---------------------------------------------------------------------------------------------------|
| `SSD_OK`               | 0      | Pipeline completed cleanly.                                                                       |
| `SSD_ERR_AUDIT_FLUSH`  | 0x2300 | At least one PENDING audit record refused finalize (`_cmd_audit_end` returned non-OK).            |
| `SSD_ERR_PARTIAL`      | 0x2301 | At least one subsystem destroy returned non-OK. Shutdown continued best-effort through the rest. |

Precedence rule: audit-flush failure **dominates** partial. If both
conditions fire, the return value is `SSD_ERR_AUDIT_FLUSH` (audit
integrity is the top invariant). The underlying err_mask (bits ORed
across steps) is emitted as the `errno=0x<hex>` key-value of the
`SESSION_SHUTDOWN ALL OK` fingerprint so forensic traces capture both
conditions even when the return value only communicates the dominant
one.

Band audit (2026-10-14): `grep -rnE '0x230[0-9]\b' src/kernel/` yields
zero hits. 0x23xx is adjacent to the CA_* band (0x22xx) and disjoint
from every SS_* / SJ_* / RS_* / JS_* code.

---

## 6. Subtree variant notes

`_ssd_shutdown_subtree(root_session_id)` applies the same ordering,
filtered to one subtree root:

- **Step 1 (audit):** flush only records whose `session_id` field
  (`CA_OFF_SID = +40`, u32) matches `root_session_id`.
- **Step 2 (remote):** **SKIPPED.** Remote-shell rows have no
  `session_id` back-link at R137.M4. Flushing all connections on a
  subtree call would be wrong for the common "jail subtree exits
  but a different shell's remote connection stays live" scenario.
  **Evolution:** R139.M5+ (or R137.M5+) may add an explicit
  `RS_OFF_OWNER_SID` back-link, at which point subtree mode closes
  connections owned by the subtree root. The design doc for that
  back-link is deferred to the R137.M5 wave.
- **Step 3 (jails):** destroy jails whose `pid` matches the subtree
  root's owner pid. **One-level only at M4;** full parent/child jail
  tree walk via `JS_OFF_PARENT_JID` is deferred to R135.M3+ once the
  jail-tree-exit sequencer lands. A multi-level jail tree under a
  subtree root is still torn down bottom-up by that sequencer; M4
  only handles the top-level direct children.
- **Step 4 (jobs):** reap jobs whose `session_id` matches the subtree
  root.
- **Steps 5-7:** scrub only the root row.
- **Step 8:** destroy only the root row.

A subtree call with a `root_session_id` that is not in-use (e.g.
already destroyed by a concurrent `sys_exit`) returns `SSD_OK` on the
no-op path, matching R127.M6's `SS_TEARDOWN_NOT_SHELL_PID` softness
for sys_exit.

---

## 7. Call sites (planned)

R139.M4 lands no callers of `_ssd_shutdown_{all,subtree}`. Future
landings expected:

| Caller                                   | Entry                        | Milestone        |
|------------------------------------------|------------------------------|------------------|
| `sys_shutdown` handler                   | `_ssd_shutdown_all()`        | R145.M1+         |
| Chaos-restart entry sequencer            | `_ssd_shutdown_all()`        | R150.M1+         |
| Platform-witness shutdown drill (R30)    | `_ssd_shutdown_all()`        | R30 witness ext. |
| Jail-tree-exit sequencer                 | `_ssd_shutdown_subtree(sid)` | R135.M3+         |
| `KIND_JAIL` DESTROY op (cap-invoke)      | `_ssd_shutdown_subtree(sid)` | R135.M4+         |

All five retire the current fingerprint-coverage allowlist entries
(`SESSION_SHUTDOWN ALL OK`, `SESSION_SHUTDOWN SUB OK`) with asserting
smoke-mode goldens.

---

## 8. Encoder discipline summary

Per `feedback_pdx_encoder_pitfalls`, the implementation observes:

- `cmp rN, 0` for every zero test (never `test rN, rN`).
- Power-of-two strides for every pool: `shl 7` (128-byte rows for
  session/jail/audit), `shl 6` (64-byte job rows), `shl 8` (256-byte
  remote-shell rows). No `imul r, imm`.
- Error codes `0x2300` / `0x2301` and the shutdown-synthetic marker
  `0xFFFFFFFF` all fit `imm32` with bit 31 clear, so `mov rax, imm32`
  emits the 7-byte zero-extending form. No `and r11, imm64`.
- Raw-flags scrub uses the shift-anchor idiom (`shl 32; shr 32`) to
  clear the high 32 of a packed u64 without an `imm64` mask.
- Job session_id recovery uses `shr 32` on the packed `[row+0]` to
  isolate the high 32 bits.
- Module basename `SessionShutdown` matches file basename
  `session_shutdown.pdx`.
- Fingerprint `[u8; N]` sizes include the trailing NUL byte.
- All labels prefixed `ssd_` (`ssd_sa_` for `_ssd_shutdown_all`,
  `ssd_ss_` for `_ssd_shutdown_subtree`, `ssd_no_` for the stats
  helper).

Stack discipline (SysV, entry rsp%16==8):

- `_ssd_shutdown_all`: 2 pushes + `sub rsp, 8` → nested calls at %16==0.
- `_ssd_shutdown_subtree`: 4 pushes + `sub rsp, 8` → nested calls at %16==0.
- `ssd_note`: pure leaf, no pushes.

---

## 9. Observability

`_ssd_stats` (16 u64, `@align(64)`, `.bss` zero-init at boot) carries
11 counters at R139.M4; slots 11-15 reserved for M5+ extensions.

| Slot | Name                               | Bumped by                                              |
|------|------------------------------------|--------------------------------------------------------|
| 0    | `SSD_ST_SHUTDOWN_ALL_OK`           | tail of `_ssd_shutdown_all`                             |
| 1    | `SSD_ST_SHUTDOWN_SUB_OK`           | tail of `_ssd_shutdown_subtree`                         |
| 2    | `SSD_ST_AUDIT_FLUSHED`             | step 1 success per record                               |
| 3    | `SSD_ST_AUDIT_FLUSH_FAIL`          | step 1 failure per record                               |
| 4    | `SSD_ST_REMOTE_CLOSED`             | step 2 success per row                                  |
| 5    | `SSD_ST_JAILS_DESTROYED`           | step 3 success per row                                  |
| 6    | `SSD_ST_JOBS_REAPED`               | step 4 success per row                                  |
| 7    | `SSD_ST_HISTORY_FLUSHED`           | step 5 per session row                                  |
| 8    | `SSD_ST_RAW_SCRUBBED`              | step 6 per session row                                  |
| 9    | `SSD_ST_ACTIVE_JOB_ZEROED`         | step 7 per session row                                  |
| 10   | `SSD_ST_SESSIONS_DESTROYED`        | step 8 success per row                                  |

Fingerprints emitted:

- `SESSION_SHUTDOWN ALL OK errno=0x<hex>` — one per `_ssd_shutdown_all`
  call; the hex payload is the err_mask (0, 0x2300, 0x2301, or
  0x2300|0x2301).
- `SESSION_SHUTDOWN SUB OK sid=0x<hex>` — one per
  `_ssd_shutdown_subtree` call; the hex payload is the root session id.

Both are allowlisted in `tools/verify-fingerprint-coverage.sh` with
retirement conditions (first production caller + asserting golden).

---

## 10. Open design questions deferred

Captured here so follow-on waves find them:

- **Remote-shell `OWNER_SID` back-link** (R137.M5?). Lets subtree mode
  close only the connections owned by the subtree root.
- **Jail parent/child tree walk** (R135.M3?). Lets subtree mode walk a
  multi-level jail tree bottom-up rather than only the top-level
  children.
- **Chaos-restart replay semantics** (R150?). Should
  `_ssd_shutdown_all` always finalize PENDING audit records with the
  synthetic marker, or should it instead *preserve* PENDING for
  replay? R139.M4 chooses "finalize always"; R150 may invert if the
  replay sequencer wants to pick up mid-record.
- **sys_shutdown handler surface** (R145?). What ring-3 cap can call
  `_ssd_shutdown_all`? Likely `KIND_PLATFORM` with `R_SHUTDOWN`
  right.
- **Platform-witness drill coverage** (R30 ext). An R30 witness that
  spins up one shell session, one jail, one job, one remote
  connection, two PENDING audit records, then calls
  `_ssd_shutdown_all` and asserts that every subsystem's stats match
  the expected post-shutdown values.

---

## 11. Change log

- **R139.M4** (Wave UMB-W22, 2026-10-14): initial landing.
  `_ssd_shutdown_all` + `_ssd_shutdown_subtree` + `_ssd_stats` + this
  document. Allowlist entries added in
  `tools/verify-fingerprint-coverage.sh`.
