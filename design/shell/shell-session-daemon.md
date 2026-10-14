# svc.shell-session — REPL session ownership daemon

**Status:** M1 skeleton, 2026-10-13.
**Umbrella:** paideia-os #2478 lineage (R127, REPL session process + history storage).
**Milestone:** R127.M1 (paideia-os #2597, Wave UMB-W11).
**Companion substrates:**
- [cap_minter.pdx](../../src/kernel/core/svc/cap_minter.pdx) (R125.M2 svc.* bringup reference)
- [kind_cap_env.pdx](../../src/kernel/core/cap/kind_cap_env.pdx) (R125.M1 cap-env substrate; the daemon's `cap_env_slot` field names rows here)
**Companion module:** [shell_session.pdx](../../src/kernel/core/svc/shell_session.pdx) (this landing)

---

## Table of contents

1. Why a daemon (not a per-task field)
2. Service identity
3. Public API
   - 3.1 `_shell_session_init() -> u64`
   - 3.2 `_shell_session_create(pid, tty_fd, cap_env_slot, name_ptr, name_len) -> packed u64`
   - 3.3 `_shell_session_lookup(pid) -> session_id | 0xFF`
   - 3.4 `_shell_session_set_state(session_id, state) -> errno`
   - 3.5 `_shell_session_destroy(session_id) -> errno`
4. Row layout (128 bytes per row, 8 rows)
5. State machine
   - 5.1 R127.M1 permissive transitions
   - 5.2 R127.M3 tightened transitions (planned)
6. Return code band
7. Boot wiring
8. Dispatch arm reservation (R127.M2)
9. Observability
10. Encoder-pitfall posture
11. Follow-on work (R127.M2+)

---

## 1. Why a daemon (not a per-task field)

A REPL session is an aggregate of six fields: `(pid, tty_fd, cap_env_slot,
history_head, history_tail, lifecycle_state, display_name)`. Only one of
those — `pid` — is already in the task struct. The remaining five are
shell-specific and have no obvious home on the task row without widening
it for every task, including those that never host a shell.

A dedicated row pool keyed by `session_id` buys three things:

1. The shell state stays off the task hot path.
2. R127.M2 has a stable id (session_id in [0, 8)) to mint a
   `KIND_SHELL_SESSION` capability against.
3. The teardown path (`_destroy`) is one row-clearing call, not a
   scatter of nullified task-struct fields.

The shape is a straight copy of `svc.cap-minter` (R125.M2):
`endpoint_alloc_at` + `svc_register` at bringup, a small `.bss` row pool
walked by a linear find-free scan, and a direct-call in-kernel API that
R127.M2 lifts to a `cap_invoke` dispatch surface.

**Design bias note (novel + clean).** The POSIX job-control shape
(`SIGSTOP` / `SIGCONT`, `tcsetpgrp`, foreground process groups) is
*not* carried in. R127.M3 decides the suspend verb — see §5.2.
Keeping it out of M1 avoids baking a POSIX inheritance into the
substrate before the surface has had a design pass.

## 2. Service identity

| Field          | Value                                                 |
|----------------|-------------------------------------------------------|
| Service name   | `svc.shell-session`                                   |
| Name length    | 17 bytes                                              |
| Endpoint id    | 21                                                    |
| Bringup entry  | `_shell_session_init()` in `shell_session.pdx`        |
| Boot hook      | `kernel_main.pdx` after `_cap_minter_init`, before `witness_r30_platform` |
| Return code 0  | `SS_OK`                                               |
| Return code 1+ | `SS_ERR_*` (0x1101..0x1104)                           |
| Bringup codes  | `SS_BRINGUP_EP_FAIL` 0xFFFFEBD2, `_REG_FAIL` D3        |

Endpoint id 21 sits in the kernel-side svc.* reservation band
(16 = elevate-broker, 17 = audit-journal, 18 = schema-registry,
19 reserved, 20 = cap-minter, 21 = shell-session). The free band
`0xFFFFEBC8..0xFFFFEBDF` noted in `cmd_invoke.pdx` provides the
bringup error codes; `cap_minter` uses D0/D1 (so shell-session takes
D2/D3 to stay adjacent to the sibling it mirrors).

## 3. Public API

### 3.1 `_shell_session_init() -> u64`

Boot hook. Shape mirrors `_cap_minter_init` one-for-one:

1. `endpoint_alloc_at(21)` — on refusal return `SS_BRINGUP_EP_FAIL`
   WITHOUT calling `svc_register`. The row never publishes a name
   against an endpoint id we did not claim.
2. `svc_register("svc.shell-session", 17, 21)` — translates its
   `{0=OK, 1=NAME_LEN, 2=DUP, 3=FULL}` return into `SS_OK` or
   `SS_BRINGUP_REG_FAIL`.

Fingerprint emission:
- Success: `SHELL_SESSION INIT OK` (no KV).
- EP fail / REG fail: `SHELL_SESSION INIT FAIL errno=0x<hex>`.

### 3.2 `_shell_session_create(pid, tty_fd, cap_env_slot, name_ptr, name_len) -> packed u64`

Mint a fresh session row.

**Args (SysV):**
- `rdi = pid` — must be non-zero.
- `rsi = tty_fd` — opaque (shell minted it against a KIND_IO_HANDLE).
- `rdx = cap_env_slot` — opaque env_handle (R125.M1 row index).
- `rcx = name_ptr` — readable up to `name_len` bytes. May be 0 iff
  `name_len == 0`.
- `r8  = name_len` — clamped to `SS_NAME_MAX = 63`.

**Returns (rax):**
- Success: `(session_id << 2) | SS_OK` = `session_id * 4`. Recover
  the id by `rax >> 2`.
- `SS_ERR_BAD_PID` — pid == 0, or a live row already holds this pid.
- `SS_ERR_POOL_FULL` — all 8 rows are in use.

**Pack / unpack contract.** Session ids are in `[0, 8)`, so
`session_id << 2` is in `[0, 32)` — disjoint from every
`SS_ERR_*` value (all `>= 0x1101`). A caller treating the whole
u64 as "error-or-id" never collides. On error `session_id` is 0,
so the packed result equals the raw errno.

**Validation order.**
1. `pid != 0` — else `SS_ERR_BAD_PID`.
2. `_shell_session_lookup(pid) != SS_ID_NONE` — else `SS_ERR_BAD_PID`
   (a pid may own at most one session).
3. `ss_find_free() != SS_ID_NONE` — else `SS_ERR_POOL_FULL`.

**Row init order.** `pid`, `tty_fd`, `cap_env_slot`, `history_head=0`,
`history_tail=0`, `state=INIT`, byte-copy of `name[0..clamped_len]`
with trailing NUL at `clamped_len`, and `in_use=1` **written last**
so a concurrent scanner either sees FREE or fully-initialised.

Fingerprint emission:
- Success: `SHELL_SESSION CREATE OK pid=0x<16-hex>`.
- Reject: `SHELL_SESSION CREATE REJ errno=0x<hex>`.

### 3.3 `_shell_session_lookup(pid) -> session_id | 0xFF`

Linear scan for the first row whose `in_use == 1` AND `pid` matches
the argument. Returns the session_id in `[0, 8)` on hit,
`SS_ID_NONE = 0xFF` on miss. Pure leaf; no fingerprint.

A `pid` of 0 can never match a live row because `_create` refuses
`pid == 0` at mint time. A caller that wants to pass through `pid=0`
as a "no session" sentinel can rely on this.

### 3.4 `_shell_session_set_state(session_id, state) -> errno`

Validate `session_id` (in `[0, 8)` AND row in use), validate state
(`< SS_STATE_MAX = 4`), write state into the low 32 bits of
`[row + 40]` preserving the high 32 bits (reserved generation
counter slot for R127.M2).

**Returns:**
- `SS_OK` — state written.
- `SS_ERR_BAD_ID` — session_id out of range or row not in use.
- `SS_ERR_BAD_STATE` — state `>= SS_STATE_MAX`.

Fingerprint emission:
- Success: `SHELL_SESSION STATE OK sid=0x<hex> state=<dec>`.
- Reject: `SHELL_SESSION STATE REJ errno=0x<hex>`.

The high-32-bit preservation is intentional: R127.M2 claims those
bits for a per-session generation counter so a cap minted against a
destroyed-then-recreated session_id can be told apart from a cap
minted against the original. M1 writes 0 into both halves at
`_create` time and preserves the high half on `_set_state`.

### 3.5 `_shell_session_destroy(session_id) -> errno`

Mark a row free. Validate `session_id`, zero `pid` first (defence-
in-depth so a stale read before the next `_create` cannot look like
a real session), then clear `in_use` LAST. The ordering mirrors the
broker row-free discipline (`svc_broker.pdx`) and the cap-env
destroy path (`kind_cap_env.pdx`).

**Returns:**
- `SS_OK` — row freed.
- `SS_ERR_BAD_ID` — session_id out of range or row already free.

Fingerprint emission:
- Success: `SHELL_SESSION DESTROY OK sid=0x<hex>`.
- Reject: `SHELL_SESSION DESTROY REJ errno=0x<hex>`.

**Fields not zeroed.** `tty_fd`, `cap_env_slot`, `history_head/tail`,
`state`, and the 64-byte name buffer are left as-is; the authoritative
"not populated" gate is `in_use == 0`, and the next `_create` of this
slot overwrites every field. The explicit `pid = 0` write defends
`_lookup` against seeing a stale pid between `_destroy` and
`_create`.

## 4. Row layout (128 bytes per row, 8 rows)

| Offset | Size | Field          | Notes                                      |
|-------:|-----:|----------------|--------------------------------------------|
|   +0   |  8   | `pid`          | 0 is reserved; refused with SS_ERR_BAD_PID |
|   +8   |  8   | `tty_fd`       | Opaque fd number                           |
|  +16   |  8   | `cap_env_slot` | R125.M1 env_handle                         |
|  +24   |  8   | `history_head` | R127.M3 populates; M1 writes 0             |
|  +32   |  8   | `history_tail` | R127.M3 populates; M1 writes 0             |
|  +40   |  8   | `state(u32) + reserved(u32)` | Low 32 = state; high 32 reserved for R127.M2 generation counter |
|  +48   | 64   | `name[0..63]`  | Byte-string with trailing NUL at byte min(name_len, 63) |
| +112   |  8   | `in_use`       | 0 = row free, 1 = row allocated            |
| +120   |  8   | `reserved`     | Slack for R127.M2 rights mask              |

Row-addressed capacity: `SS_POOL_MAX = 8`. 8 × 128 = 1024 bytes = 128
u64. Stride 128 = 2⁷ so row addressing uses `shl rax, 7` — no `imul`
(encoder gap feedback_pdx_encoder_pitfalls).

`.bss` zero-init gives us the FREE sentinel (`in_use = 0`) for free
at real boot. There is no explicit table-reset function at M1
(matching cap_minter, which also relies on .bss zero-init); R127.M2
may add one if the harness-restart story demands it.

## 5. State machine

### 5.1 R127.M1 permissive transitions

| Name       | Ordinal |
|------------|--------:|
| INIT       | 0       |
| ACTIVE     | 1       |
| SUSPENDED  | 2       |
| TERMINATED | 3       |

At M1 any state X may move to any state Y where `Y < SS_STATE_MAX`.
State `>= 4` is refused with `SS_ERR_BAD_STATE`. The permissive
posture is a deliberate choice: it lets the harness exercise every
transition without M1 having to make a design call on the suspend
verb (see §5.2 below).

### 5.2 R127.M3 tightened transitions (planned)

R127.M3 (shell lifecycle manager) will narrow this to:

```
INIT       -> ACTIVE
ACTIVE     -> SUSPENDED | TERMINATED
SUSPENDED  -> ACTIVE | TERMINATED
TERMINATED -> (terminal; only _destroy accepted)
```

The suspend verb is an open design question: ^Z and job control are
not a given on PaideiaOS. The novel-design directive
(`feedback_novel_clean_design`) favours retiring the POSIX job-
control shape rather than preserving it; R127.M3's design doc
decides between a cap-driven "suspend by revoking the stdin
forwarder" model and the inherited POSIX surface.

## 6. Return code band

| Symbol              | Value   | Meaning                                       |
|---------------------|--------:|-----------------------------------------------|
| `SS_OK`             | 0       | Success                                       |
| `SS_ERR_POOL_FULL`  | 0x1101  | All 8 rows in use                             |
| `SS_ERR_BAD_ID`     | 0x1102  | session_id out of range or row not in use     |
| `SS_ERR_BAD_PID`    | 0x1103  | pid == 0, or duplicate pid                    |
| `SS_ERR_BAD_STATE`  | 0x1104  | state >= 4                                    |
| `SS_BRINGUP_EP_FAIL`| 0xFFFFEBD2 | endpoint_alloc_at(21) refused              |
| `SS_BRINGUP_REG_FAIL`| 0xFFFFEBD3 | svc_register refused                      |

Band audit (2026-10-13): `grep -rnE '0x110[1-4]\b' src/kernel/`
returned zero hits in the production tree. Clean band; R127.M2+ may
extend to 0x1105..0x110F while retaining the first four as pinned.

## 7. Boot wiring

`kernel_main.pdx` adds one new call in the svc.* bringup cascade:

```
call elevate_broker_bringup;     // ENDPOINT 16, R48-PREP-005.M1
call schema_registry_bringup;    // ENDPOINT 18, R90-XREPO.012.M2
call _cap_minter_init;           // ENDPOINT 20, R125.M2
call _shell_session_init;        // ENDPOINT 21, R127.M1 (this landing)
call witness_r30_platform;       // R30 platform witness cascade
```

**Placement rationale.** Must run AFTER `_cap_minter_init` (so the
broker table already has every svc.* row published before the shell
daemon registers) and BEFORE `witness_r30_platform` (so a future
platform witness that spins up a shell task sees the
`svc.shell-session` row).

## 8. Dispatch arm reservation (R127.M2)

R127.M2 wires:

1. A `KIND_SHELL_SESSION` kind registration (numeric slot TBD;
   expected 0x5E as the next free slot after R125.M1 claimed 0x5D).
2. A `cap_handler_shell_session` module with four ops:
   - `SS_OP_LOOKUP_BY_PID` (read-only; returns session_id)
   - `SS_OP_GET_STATE` (read-only; returns state ordinal)
   - `SS_OP_SET_STATE` (mutating; routed through this daemon)
   - `SS_OP_DESTROY` (mutating; routed through this daemon)
3. The frame-body dispatcher on endpoint 21 for ring-3 callers that
   `svc_lookup("svc.shell-session")`. The frame layout is a sibling
   of the cap-minter DERIVE frame (parent slot + op code +
   per-op args).

M1 reserves no op numbers in `shell_session.pdx` itself — the op
constants will live in the R127.M2 landing's `cap_handler_shell_
session.pdx` alongside the dispatch arm, following the pattern
cap_minter / kind_cap_env established (reserving the op number in
the kind module while the arm itself lands in a sibling module).

Named-IPC callers at M1 route only through the direct-call API; the
`svc_lookup("svc.shell-session")` row exists so the test harness
can observe that `_init` published it, not so a running shell task
can bind.

## 9. Observability

Eight `_shell_session_stats` counters:

| Ordinal | Name                     |
|--------:|--------------------------|
| 0       | `SS_ST_INIT_OK`          |
| 1       | `SS_ST_INIT_EP_FAIL`     |
| 2       | `SS_ST_INIT_REG_FAIL`    |
| 3       | `SS_ST_CREATE_OK`        |
| 4       | `SS_ST_CREATE_FULL`      |
| 5       | `SS_ST_CREATE_BAD_PID`   |
| 6       | `SS_ST_STATE_OK`         |
| 7       | `SS_ST_DESTROY_OK`       |

Load-inc-store idiom (no `add reg, [mem]`). Bounds-guarded at the
top of `ss_note` so a future mis-caller passing an out-of-range
ordinal is dropped rather than smearing an adjacent counter.

Four `OK`-tagged fingerprints are extracted by the fingerprint-
coverage gate and allowlisted in
`tools/verify-fingerprint-coverage.sh` under
"Wave UMB-W11 R127.M1". Each retires when R127.M2's asserting
smoke-mode golden drives the matching verb end-to-end:

- `SHELL_SESSION INIT OK` — bringup success (fires every boot)
- `SHELL_SESSION CREATE OK` — mint path (fires on any _create call)
- `SHELL_SESSION STATE OK` — state write (fires on any _set_state)
- `SHELL_SESSION DESTROY OK` — teardown (fires on any _destroy)

## 10. Encoder-pitfall posture

Standard, per `feedback_pdx_encoder_pitfalls`:

- `cmp rN, 0` — never `test rN, rN`.
- `shl rN, 7` to compose the 128-byte row stride — never `imul r, imm`.
- `mov rax, imm32` for every error code in the 0x1101..0x1104 band
  — never `and r11, imm64`.
- The high-32 mask `0xFFFFFFFF00000000` is built via
  `mov r9, 0xFFFFFFFF; shl r9, 32` to avoid the `and r11, imm64`
  encoder gap.
- Every `pub let name = "..."` is single-line.
- Module basename `ShellSession` matches file basename
  `shell_session.pdx`.
- Every fingerprint `[u8; N]` has `N == string length + 1` with the
  trailing NUL explicitly counted.
- All labels are prefixed `ss_` (shell-session) to stay clear of
  `svc_` (ipc/svc_broker.pdx) and the broader `s_` family.

Stack discipline (SysV, entry rsp%16 == 8):

| Function                       | Pushes | sub rsp | At every nested call rsp%16 |
|-------------------------------|-------:|--------:|-----------------------------|
| `_shell_session_init`         |   1    |   0     | 0                           |
| `_shell_session_lookup`       |   0    |   0     | leaf                        |
| `_shell_session_create`       |   5    |   0     | 0                           |
| `_shell_session_set_state`    |   2    |   8     | 0 (frame held; stack-arg slot at [rsp+0]) |
| `_shell_session_destroy`      |   1    |   0     | 0                           |

## 11. Follow-on work (R127.M2+)

- **R127.M2** — `KIND_SHELL_SESSION` kind registration +
  `cap_handler_shell_session.pdx` with the four-op dispatch arm
  listed in §8. Retires the four `SHELL_SESSION * OK` allowlist
  entries behind asserting smoke-mode goldens.
- **R127.M3** — Shell lifecycle manager: tightens the state machine
  per §5.2 and makes the suspend verb a design decision. May claim
  the high-32-bit generation counter at `[row + 40 +4]` to let a cap
  minted against a destroyed-then-recreated session_id be told
  apart from a cap minted against the original.
- **R127.M4** — History ring buffer. Populates `history_head` /
  `history_tail` and provides `_shell_session_history_append` /
  `_shell_session_history_read` for the REPL to persist and recall
  input lines. Likely a per-session page allocated at
  `_create` time against the session's cap-env (`cap_env_slot`).

---

*This document is normative. Any divergence between it and
`src/kernel/core/svc/shell_session.pdx` is a bug in the code or the
doc — fix one or the other before landing a change that widens the
gap.*
