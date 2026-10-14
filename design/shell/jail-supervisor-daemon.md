# svc.jail-supervisor — WASI-jail cap-env + syscall allowlist daemon

**Status:** M1 skeleton, 2026-10-13.
**Umbrella:** paideia-os R135 ("WASI-jail: a sandboxed execution environment for WASI / WebAssembly modules running on paideia-os").
**Milestone:** R135.M1 (paideia-os #2626, Wave UMB-W15).
**Companion substrates:**
- [cap_minter.pdx](../../src/kernel/core/svc/cap_minter.pdx) (R125.M2 svc.* bringup reference)
- [shell_session.pdx](../../src/kernel/core/svc/shell_session.pdx) (R127.M1 svc.* row-pool / direct-call-API reference)
- [kind_cap_env.pdx](../../src/kernel/core/cap/kind_cap_env.pdx) (R125.M1 cap-env substrate; the daemon's `cap_env_slot` field names rows here)
- [syscall/cap_check.pdx](../../src/kernel/core/syscall/cap_check.pdx) (R125.M4 cap-check dispatch-layer gate; the jail gate chains AFTER it)
**Companion module:** [jail_supervisor.pdx](../../src/kernel/core/svc/jail_supervisor.pdx) (this landing)

---

## Table of contents

1. Why a daemon (not a per-task field)
2. WASI-jail semantics (novel + clean posture)
3. Service identity
4. Public API
   - 4.1 `_jail_supervisor_init() -> u64`
   - 4.2 `_jail_supervisor_create(pid, cap_env_slot, syscall_mask_lo, syscall_mask_hi, name_ptr, name_len) -> packed u64`
   - 4.3 `_jail_supervisor_check_syscall(pid, sysno) -> errno`
   - 4.4 `_jail_supervisor_destroy(jail_id) -> errno`
5. Row layout (128 bytes per row, 8 rows)
6. Syscall allowlist design
   - 6.1 Mask shape and the 128-bit choice
   - 6.2 Interaction with R125.M4 cap-check (jail check happens AFTER cap-check)
   - 6.3 Fail-closed on unmaskable sysnos
7. State machine
8. Return code band
9. Boot wiring
10. Dispatch arm reservation (R135.M2 KIND_JAIL)
11. Observability
12. Encoder-pitfall posture
13. Follow-on work (R135.M2+)

---

## 1. Why a daemon (not a per-task field)

A WASI jail is an aggregate of five fields: `(pid, cap_env_slot,
syscall_mask [128 bits], lifecycle_state, display_name)`. Only one of
those — `pid` — is already in the task struct. The remaining four are
jail-specific and have no obvious home on the task row without widening
it for every task, including the 99 % that will never run WASI (every
kernel task, every driver worker, every shell command).

A dedicated row pool keyed by `jail_id` buys three things:

1. The jail state stays off the task hot path. A kernel task's syscall
   entry does not pay for a jail check it will never need; the
   dispatcher's jail-check preamble is a bounded (8-row) scan that
   returns pass-through in one iteration against a cold cache line.
2. R135.M2 has a stable id (jail_id in [0, 8)) to mint a `KIND_JAIL`
   capability against.
3. The teardown path (`_destroy`) is one row-clearing call, not a
   scatter of nullified task-struct fields.

The shape is a straight copy of `svc.shell-session` (R127.M1):
`endpoint_alloc_at` + `svc_register` at bringup, a small `.bss` row
pool walked by a linear find-free scan, and a direct-call in-kernel
API that R135.M2 lifts to a `cap_invoke` dispatch surface.

## 2. WASI-jail semantics (novel + clean posture)

The WASI spec (preview-2) prescribes a POSIX-shaped surface: `fd_read`,
`fd_write`, `path_open`, etc., with capability-style preopens. paideia-
os's WASI-jail does **not** mint a POSIX-shaped fd universe inside the
jail; it mints a *cap-env* (the R125.M1 substrate) that holds the WASI
preopens as capabilities and a **syscall allowlist** that constrains
what the jailed task can even *attempt*.

The design bias (feedback_novel_clean_design): paideia-os's "WASI
runtime" is a thin WASM interpreter / JIT that runs its byte code,
calls into the host for every WASI function, and translates each WASI
call into one or more cap_invokes against the jail's cap-env. The
syscall allowlist is a **second line of defence**:

- A WASI runtime bug that smuggles a non-WASI syscall through (say,
  the runtime makes a direct `syscall 0x60` because the JIT emitted
  machine code it shouldn't) is caught by the jail gate.
- The gate is **mask-driven**, not call-site enumerated: the shell /
  launcher decides which sysnos a jail may touch at mint time, and
  the kernel enforces it on every syscall.

The mask is pinned at 128 bits (sysnos 0..127) because the paideia-os
syscall dispatch table (`src/kernel/core/syscall/dispatch.pdx`) today
indexes sysnos in [0, 137] with a bounds check at 138. R135.M3 may
widen the mask (to 256 bits or an explicit extension word) if a
future dispatch table admits a jailed-WASI sysno in the 128..255 band;
today the strict-closed posture matches "WASI by default sees a POSIX-
shaped tiny universe, not the full paideia-os syscall surface".

## 3. Service identity

| Field          | Value                                                 |
|----------------|-------------------------------------------------------|
| Service name   | `svc.jail-supervisor`                                 |
| Name length    | 19 bytes                                              |
| Endpoint id    | 22                                                    |
| Bringup entry  | `_jail_supervisor_init()` in `jail_supervisor.pdx`    |
| Boot hook      | `kernel_main.pdx` after `_shell_session_init`, before `witness_r30_platform` |
| Return code 0  | `JS_OK`                                               |
| Return code 1+ | `JS_ERR_*` (0x1500..0x1503)                           |
| Bringup codes  | `JS_BRINGUP_EP_FAIL` 0xFFFFEBD4, `_REG_FAIL` D5       |

Endpoint id 22 is the next free id in the kernel-side svc.* reservation
band (16 = elevate-broker, 17 = audit-journal, 18 = schema-registry,
19 reserved, 20 = cap-minter, 21 = shell-session, 22 = jail-supervisor).
The free band `0xFFFFEBC8..0xFFFFEBDF` noted in `cmd_invoke.pdx`
provides the bringup error codes; `cap_minter` uses D0/D1 and
`shell_session` uses D2/D3, so `jail_supervisor` takes D4/D5.

## 4. Public API

### 4.1 `_jail_supervisor_init() -> u64`

Boot hook. Called from `kernel_main.pdx` once, immediately after
`_shell_session_init`. Two-phase bringup:

1. `endpoint_alloc_at(22)`. On refusal → `JS_BRINGUP_EP_FAIL`
   **without** calling `svc_register` (the broker row never names an
   endpoint id we did not claim).
2. `svc_register("svc.jail-supervisor", 19, 22)`. Any non-zero return
   maps to `JS_BRINGUP_REG_FAIL`.

On success emits `JAIL_SUPERVISOR INIT OK`. On refusal emits
`JAIL_SUPERVISOR INIT FAIL errno=0x<hex>`.

### 4.2 `_jail_supervisor_create(pid, cap_env_slot, syscall_mask_lo, syscall_mask_hi, name_ptr, name_len) -> packed u64`

Mint a fresh jail row. SysV calling convention; six args (all in
registers under the SysV ABI: rdi/rsi/rdx/rcx/r8/r9).

**Validation** (fail-fast):
- `pid != 0` → else `JS_ERR_BAD_PID`.
- `_jail_supervisor_lookup(pid) == JS_ID_NONE` → else `JS_ERR_BAD_PID`
  (a pid can own at most one jail; duplicate mint attempts are
  programming errors in the launcher).
- `js_find_free()` succeeds → else `JS_ERR_POOL_FULL`.

**Row init** (in this order):
```
row.pid              = pid
row.cap_env_slot     = cap_env_slot
row.syscall_mask_lo  = syscall_mask_lo
row.syscall_mask_hi  = syscall_mask_hi
row.state            = JS_STATE_INIT (0)   // high 32 bits (flags) also 0
row.name[0..63]      = byte-copy up to min(name_len, 63)
row.name[clamped]    = 0 (trailing NUL)
row.in_use           = 1                    // LAST write
```

The `in_use` write lands LAST so a concurrent scanner (there is none at
M1, but R135.M2's dispatch-layer gate is a concurrent reader) either
sees FREE or fully-initialised; the ordering mirrors `_shell_session_
destroy` and the broker row-free discipline.

**Return** (packed u64):
```
result = (jail_id << 2) | status
```

On success `status == JS_OK (0)`, so `result == jail_id << 2`
(recoverable via `shr rax, 2`). Jail ids live in [0, 8), so
`jail_id << 2` is in [0, 32) — disjoint from every `JS_ERR_*` value
(all ≥ 0x1500) so a caller that treats the whole u64 as an error-or-id
tagged value never collides.

On success emits `JAIL_SUPERVISOR CREATE OK pid=0x<hex>`; on refusal
emits `JAIL_SUPERVISOR CREATE REJ errno=0x<hex>`.

### 4.3 `_jail_supervisor_check_syscall(pid, sysno) -> errno`

The syscall-dispatch pre-check gate for jailed callers. **Not yet
wired in from `src/kernel/core/syscall/dispatch.pdx`** — the wiring is
R135.M2. At M1 this is the direct-call API the launcher can exercise
from the kernel side for a harness, and the entry point the R135.M2
dispatch gate will call.

Four outcomes:

| Case | Pid in pool? | sysno | mask bit | Return                     | Stats          | Fingerprint              |
|------|--------------|-------|----------|----------------------------|----------------|--------------------------|
| (a)  | No           | *     | *        | `JS_OK`                    | PASSTHROUGH    | (none; silent fast path) |
| (b)  | Yes          | <128  | set      | `JS_OK`                    | CHECK_OK       | (none)                   |
| (c)  | Yes          | ≥128  | n/a      | `JS_ERR_SYSCALL_DENIED`    | CHECK_DENIED   | `DENIED OK pid= sysno=`  |
| (d)  | Yes          | <128  | clear    | `JS_ERR_SYSCALL_DENIED`    | CHECK_DENIED   | `DENIED OK pid= sysno=`  |

Case (a) is the common fast path: the vast majority of syscalls come
from non-jailed tasks, so the scan terminates on the first iteration
without a pool hit and returns `JS_OK` in a tight path. Case (a) does
**not** emit a fingerprint because that would spam the klog at every
syscall of every un-jailed process.

Case (c) is a fail-closed decision: see §6.3.

### 4.4 `_jail_supervisor_destroy(jail_id) -> errno`

Mark a row free. Validate `jail_id` via `js_row_in_use`
(`JS_ERR_BAD_ID` on out-of-range or already-free); zero `pid`,
`mask_lo`, `mask_hi` (defence-in-depth: a stale non-zero mask on an
empty row cannot be observed by `check_syscall` before `in_use` is
set, but zeroing tightens the "destroyed jail has no residual
authority" invariant); then clear `in_use` LAST so a concurrent scan
either sees the live row or a fully-free row.

Fingerprints: `JAIL_SUPERVISOR DESTROY OK jid=0x<hex>` on success,
`DESTROY REJ errno=0x<hex>` on `JS_ERR_BAD_ID`.

## 5. Row layout (128 bytes per row, 8 rows)

| Offset | Width | Field              | Notes                                   |
|-------:|------:|--------------------|-----------------------------------------|
|   0    | u64   | `pid`              | owning process pid (0 reserved)         |
|   8    | u64   | `cap_env_slot`     | R125.M1 KIND_CAP_ENV row index          |
|  16    | u64   | `syscall_mask_lo`  | bits 0..63 of allowlist                 |
|  24    | u64   | `syscall_mask_hi`  | bits 64..127                            |
|  32    | u32+u32 | `state` + `flags` | low 32 = state, high 32 reserved        |
|  40    | 64 B  | `name[0..63]`      | 63 usable bytes + trailing NUL          |
| 104    | u64   | reserved           | R135.M2 slack (creation tick / parent)  |
| 112    | u64   | `in_use`           | 0 = free, 1 = allocated                 |
| 120    | u64   | reserved           | R135.M2 slack (KIND_JAIL rights mask)   |

Pool: 8 × 128 = 1024 bytes = 128 u64. Stride 128 is a power of two so
row addressing uses `shl rax, 7` (no `imul`; feedback_pdx_encoder_
pitfalls item 3).

The `in_use` field at `+112` (not `pid`) is the authoritative live-row
gate. Pid 0 is still rejected at mint time to keep `check_syscall`'s
zero-pid fast-path check honest (a zero pid can never match a live
row because mint refused it).

## 6. Syscall allowlist design

### 6.1 Mask shape and the 128-bit choice

The mask is 128 bits split across two u64 halves. Bit N (counted from
bit 0 of `syscall_mask_lo`, continuing into bit 0 of `syscall_mask_hi`
at index 64) indicates that sysno N is **permitted** for this jail.

Why 128 bits:

- The paideia-os syscall dispatch table (`dispatch.pdx`) today indexes
  sysnos in [0, 137]; sysnos [128, 137] are the audit-journal / IPC-
  reply outliers that no WASI runtime has business touching, so a 128-
  bit cutoff is a cleanly defensible fail-closed line.
- A single `shl rN, cl` suffices for bit extraction when the mask fits
  in two u64 halves; a wider mask would need either multi-word shift
  (encoder-pitfall-adjacent) or a byte-indexed table lookup.
- 128 bits per row is 16 bytes of the 128-byte row — a reasonable
  budget; the row still has 64 bytes of name and ~40 bytes of slack
  for R135.M2+ extensions.

Extraction (`check_syscall` low-half path):
```
mov r11, [rax + 16]      ; syscall_mask_lo
mov rcx, r12             ; shift count = sysno (sysno < 64 branch)
mov r9,  1
shl r9,  cl              ; r9 = 1 << sysno
and r11, r9
cmp r11, 0
je  js_cs_deny
```

### 6.2 Interaction with R125.M4 cap-check (jail check happens AFTER cap-check)

The dispatcher's preamble cascade (R135.M2 integrates):

```
syscall_dispatch
  \_ cap-check preamble            (R125.M4; refuses if cap missing)
  \_ jail-check preamble           (R135.M2; this file at M1)
  \_ main bounds check + handler
```

The order is deliberate:

1. **cap-check first**: `_syscall_rights_table_init` publishes a
   table in `.bss` indexed by sysno giving the required right. The
   check is a single table lookup against the caller's cap-env — O(1)
   with excellent cache locality. An un-capped caller is refused
   before we touch the jail pool at all.
2. **jail-check second**: a jailed caller that *does* hold the cap is
   still refused if the jail mask does not grant that sysno. This
   catches a WASI runtime that minted the right cap but tried to
   smuggle a non-WASI sysno through — a defence-in-depth posture.
3. **main bounds check + handler**: the existing dispatch path.

A jailed caller that lacks the cap is refused by (1) with a cap-check
errno, not by (2) with `JS_ERR_SYSCALL_DENIED`. The two refusals are
observably different in the klog (`SYSCALL CAP_CHECK REJ` vs
`JAIL_SUPERVISOR DENIED OK`) so a smoke-mode golden can distinguish
them.

### 6.3 Fail-closed on unmaskable sysnos

A jailed caller invoking `sysno >= 128` is refused with
`JS_ERR_SYSCALL_DENIED` because the 128-bit mask does not cover their
sysno. Allowing them by default (because "the mask doesn't say no")
would be a trivial escape: a WASI runtime bug or malicious jailed
module could reach sysnos [128, 137] purely because they're outside
the mask's representable range.

The strict-closed posture matches the paideia-os design bias that
WASI runs in a **narrower** universe than POSIX, not a wider one. If
a future R135.M3 landing needs to admit a sysno in [128, 255] for a
jailed WASI runtime, the fix is to widen the mask (to 256 bits or an
explicit extension word in the row's reserved slack at `+104`/`+120`),
not to leak sysnos through the current window.

## 7. State machine

R135.M1 states (name = ordinal):

- `JS_STATE_INIT` = 0 — freshly created, WASI module not yet handed
  the entry point.
- `JS_STATE_ACTIVE` = 1 — WASI module executing.
- `JS_STATE_TERMINATED` = 2 — post-exit; row stays live until
  `_destroy` is called so the launcher parent can scrape exit status.

Transitions at M1 are permissive (any X → any Y with Y < `JS_STATE_
MAX` = 3) because `_jail_supervisor_set_state` is not yet in the M1
public API (reserved for R135.M2). The state field is written to
`JS_STATE_INIT` at mint time; subsequent transitions land with
R135.M2.

## 8. Return code band

| Code                 | Value  | Meaning                                 |
|----------------------|-------:|-----------------------------------------|
| `JS_OK`              | 0x0000 | success / passthrough                   |
| `JS_ERR_POOL_FULL`   | 0x1500 | all 8 rows in use                       |
| `JS_ERR_BAD_ID`      | 0x1501 | `jail_id` out of range or row free      |
| `JS_ERR_SYSCALL_DENIED` | 0x1502 | jailed caller, sysno not permitted   |
| `JS_ERR_BAD_PID`     | 0x1503 | `pid == 0` or duplicate                 |

Band audit (2026-10-13): `grep -rnE '0x150[0-3]\b' src/kernel/
2>/dev/null` → zero hits in the production tree before this landing.
Clean band; R135.M2+ may extend to 0x1504..0x150F while retaining
the first four as pinned.

Bringup codes:

| Code                   | Value       | Meaning                             |
|------------------------|------------:|-------------------------------------|
| `JS_BRINGUP_EP_FAIL`   | 0xFFFFEBD4  | `endpoint_alloc_at(22)` refused     |
| `JS_BRINGUP_REG_FAIL`  | 0xFFFFEBD5  | `svc_register` refused              |

Adjacent to `shell_session`'s EBD2/EBD3 pair in the free EBC8..EBDF
band noted in `cmd_invoke.pdx`.

## 9. Boot wiring

`kernel_main.pdx` picks this up with one new call after
`_shell_session_init` and before `witness_r30_platform`:

```
call _cap_minter_init;           // ENDPOINT 20, R125.M2
call _syscall_rights_table_init; // R125.M4 cap-check table
call _shell_session_init;        // ENDPOINT 21, R127.M1
call _jail_supervisor_init;      // ENDPOINT 22, R135.M1 (this file)
call witness_r30_platform;       // R30 platform witness cascade
```

Placement rationale: after the prior three svc.* bringups (broker
table already has every svc.* row published before the jail
supervisor registers) and before the R30 witness block (so a future
platform witness that spawns a WASI jail task sees the svc.jail-
supervisor row).

## 10. Dispatch arm reservation (R135.M2 KIND_JAIL)

At R135.M1 there is **no** `cap_invoke` dispatch arm for `KIND_JAIL`.
R135.M2 adds:

1. `KIND_JAIL` registration in `src/kernel/core/cap/kind_jail.pdx`
   (new file; mirror shape of `kind_shell_session.pdx`).
2. Op numbers:
   - `JAIL_OP_CREATE` = 1
   - `JAIL_OP_DESTROY` = 2
   - `JAIL_OP_CHECK_SYSCALL` = 3 (used only by the dispatcher-side
     wiring; never a user-reachable op)
   - `JAIL_OP_SET_STATE` = 4
3. Rights mask bits: `R_JAIL_CREATE`, `R_JAIL_DESTROY`,
   `R_JAIL_SET_STATE` (CHECK_SYSCALL is kernel-internal; no caller
   needs a right for it).
4. Frame-body dispatcher in `src/kernel/core/cap/cap_invoke.pdx` that
   routes each op to the direct-call API in this file.
5. Dispatch-layer gate in `src/kernel/core/syscall/dispatch.pdx` that
   calls `_jail_supervisor_check_syscall(current_pid, sysno)` AFTER
   the R125.M4 cap-check preamble and before the main bounds check.

Named-IPC callers (if any arrive before R135.M2) route through the
broker:

```
endpoint_id = svc_lookup("svc.jail-supervisor")  // = 22
send CREATE / CHECK_SYSCALL / DESTROY frame to endpoint_id
receive REPLY
```

## 11. Observability

`_jail_supervisor_stats` is a `[u64; 16]` counter array (bumped by
`js_note(slot)`); slots currently in use:

| Slot | Name                   | Bumped by                                |
|-----:|------------------------|------------------------------------------|
| 0    | `JS_ST_INIT_OK`        | `_jail_supervisor_init` success          |
| 1    | `JS_ST_INIT_EP_FAIL`   | `_init` EP refusal                       |
| 2    | `JS_ST_INIT_REG_FAIL`  | `_init` REG refusal                      |
| 3    | `JS_ST_CREATE_OK`      | `_create` success                        |
| 4    | `JS_ST_CREATE_FULL`    | `_create` pool-full                      |
| 5    | `JS_ST_CREATE_BAD_PID` | `_create` bad-pid / dup                  |
| 6    | `JS_ST_CHECK_PASSTHROUGH` | `_check_syscall` pid-not-in-pool      |
| 7    | `JS_ST_CHECK_OK`       | `_check_syscall` permit                  |
| 8    | `JS_ST_CHECK_DENIED`   | `_check_syscall` deny                    |
| 9    | `JS_ST_DESTROY_OK`     | `_destroy` success                       |
| 10   | `JS_ST_DESTROY_REJ`    | `_destroy` bad-id                        |

Slots 11..15 reserved for R135.M2+ (set-state witness, cap-invoke
dispatch hit counts, etc.).

Fingerprint tags (OK-matching so the coverage gate indexes them):

- `JAIL_SUPERVISOR INIT OK`
- `JAIL_SUPERVISOR INIT FAIL` (opaque to gate)
- `JAIL_SUPERVISOR CREATE OK`
- `JAIL_SUPERVISOR CREATE REJ` (opaque)
- `JAIL_SUPERVISOR DENIED OK` (OK-wording is intentional; a deny is
  the daemon's expected business outcome)
- `JAIL_SUPERVISOR DESTROY OK`
- `JAIL_SUPERVISOR DESTROY REJ` (opaque)

All four OK tags are allowlisted in `tools/verify-fingerprint-
coverage.sh` with a retire-when-R135.M2-lands reason; the gate itself
is the honesty test — any OK fingerprint that becomes reachable from
a production path will refuse to stay allowlisted.

## 12. Encoder-pitfall posture

Labels are prefixed `js_` (jail-supervisor) to stay clear of `ss_`
(shell_session), `cmnt_` (cap_minter), `ks_` (kind_shell_session) and
the broader `s_` family. No reserved paideia-as keyword overlap
(reserved: `loop` / `if` / `let`).

Discipline items (feedback_pdx_encoder_pitfalls):

- `cmp rN, 0` (never `test rN, rN`).
- `shl rN, 7` to compose row-base × 128 stride (never `imul r, imm`).
- `shl rN, cl` for variable-amount shift in the mask-bit extraction
  (encoded; proven in `uefi_phys_seed.pdx` L327/L396 and `pdxfs_lite/
  alloc.pdx` L233/L388).
- `mov rax, imm32` for all error codes (never `and r11, imm64`).
- Single-line `pub let name = "..."`.
- Module basename `JailSupervisor` matches file basename
  `jail_supervisor.pdx` (ddc exact-match requirement).
- Fingerprint `[u8; N]` with N = string length + 1 (NUL counts).

Stack discipline (SysV, entry rsp%16==8):

| Function                      | Pushes | sub rsp |
|-------------------------------|-------:|--------:|
| `_jail_supervisor_init`       |      1 |       0 |
| `_jail_supervisor_lookup`     |      0 |       0 |
| `_jail_supervisor_create`     |      5 |      16 |
| `_jail_supervisor_check_syscall` |   2 |       8 |
| `_jail_supervisor_destroy`    |      1 |       0 |

Each landing re-centres `rsp % 16 == 0` at every nested call.

## 13. Follow-on work (R135.M2+)

R135.M2 ("WASI-jail cap-invoke dispatch + syscall-dispatch gate wire-
up"):
1. `kind_jail.pdx` with `KIND_JAIL` registration (new file).
2. `cap_invoke` arm routing each op to the direct-call API.
3. Dispatch-layer gate in `src/kernel/core/syscall/dispatch.pdx`
   calling `_jail_supervisor_check_syscall` after cap-check.
4. First smoke-mode golden exercising a jailed caller against both
   an allowed sysno (permit) and a denied sysno (`JAIL_SUPERVISOR
   DENIED OK`).

R135.M3 ("WASI-jail lifecycle manager + state-transition rules"):
1. `_jail_supervisor_set_state` with the R127.M3-style tightened
   transitions (INIT → ACTIVE → TERMINATED; no backward edges except
   `_destroy`).
2. Launcher-parent task that owns the jail's lifecycle, mints the
   jail at exec time, and tears it down at exit.
3. Optional: widen the syscall mask to 256 bits if a jailed WASI
   runtime needs a sysno in [128, 255].

R135.M4 ("WASI-jail cap-env freeze posture"):
1. Interaction with the R125.M1 `cap_env_freeze` op: a jail's cap-env
   should be frozen at the point `_jail_supervisor_create` returns
   (the WASI runtime must not mint new caps against its own cap-env;
   fresh caps come from the launcher parent via `svc.cap-minter`).
2. Audit test that confirms no `cap_env_insert` lands against a
   jailed task's cap-env after mint.

R135.M5+ (umbrella close): KIND_JAIL rights-mask propagation at
`sys_execve` for a WASM-flavoured ELF entry (parallels the R125.M3
`.caps.decl` loader), and the launcher-side CLI surface
(`jail --mask 0x... --name foo module.wasm`) that mints a jail from
the shell.
