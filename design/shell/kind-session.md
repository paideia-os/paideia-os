# KIND_SHELL_SESSION — cap-invoke surface over the shell-session row pool

**Status:** M2 skeleton, 2026-10-13.
**Umbrella:** paideia-os #2478 lineage (R127, REPL session process + history storage).
**Milestone:** R127.M2 (paideia-os #2598, Wave UMB-W12).
**Companion module:** [kind_shell_session.pdx](../../src/kernel/core/cap/kind_shell_session.pdx) (this landing).
**Depends on:**
- [shell_session.pdx](../../src/kernel/core/svc/shell_session.pdx) (R127.M1, Wave UMB-W11) — the row pool + direct-call API.
- [kind.pdx](../../src/kernel/core/cap/kind.pdx) §KIND_SHELL_SESSION — registry entry.
- [invoke.pdx](../../src/kernel/core/cap/invoke.pdx) `call_kind_shell_session` — dispatch arm.
- [cap-minter-daemon.md](cap-minter-daemon.md) — svc.cap-minter DERIVE path reaches a KIND_SHELL_SESSION parent to narrow READ-only children.

---

## Table of contents

1. Purpose and scope
2. Naming — why `KindShellSession` and not `KindSession`
3. Ordinal choice — 0x1A9
4. Derivation — over KIND_IPC_ENDPOINT
5. Descriptor layout
6. Ops surface
   - 6.1 `SESSION_OP_LOOKUP_BY_PID` (op 0)
   - 6.2 `SESSION_OP_READ_STATE` (op 1)
   - 6.3 `SESSION_OP_SET_STATE` (op 2)
   - 6.4 `SESSION_OP_READ_NAME` (op 3)
7. Rights
8. Mint helper — supervisor-reach only
9. Return code band
10. Interaction with R127.M1 daemon
11. Interaction with R127.M3 — history and lifecycle manager
12. Future ops reserved in the [4, 15] band
13. Encoder-pitfall posture
14. Observability
15. Follow-on work

---

## 1. Purpose and scope

R127.M1 landed the kernel-side daemon that owns one or more running
shell REPL sessions (`svc.shell-session`, endpoint 21). Its direct-call
API — `_shell_session_create`, `_shell_session_lookup`,
`_shell_session_set_state`, `_shell_session_destroy` — is reachable
only from in-kernel bringup paths. Ring-3 processes have no way to
inspect a session's state, resolve a `pid` to a `session_id`, or
rename a session without crossing into supervisor code.

R127.M2 (this landing) closes that gap by introducing a
`KIND_SHELL_SESSION` capability. A ring-3 holder of such a cap reaches
four ops through the standard `cap_invoke` dispatch surface:

- `SESSION_OP_LOOKUP_BY_PID` — resolve a pid to a `session_id`
- `SESSION_OP_READ_STATE` — read a session's lifecycle state
- `SESSION_OP_SET_STATE` — write a session's lifecycle state
- `SESSION_OP_READ_NAME` — read the session's 64-byte display name

The mint path is supervisor-only (see §8). A derived child cap, with
rights narrowed through `svc.cap-minter`, is the standard ring-3 way
for one shell session to delegate a read-only view to a subordinate
task (e.g., a status widget that watches `state` transitions).

The scope of this milestone is strictly the cap-invoke surface and
the mint helper. No new row fields, no new state transitions, no
history storage — those land with R127.M3.

---

## 2. Naming — why `KindShellSession` and not `KindSession`

The umbrella directive specified the module name `KindSession` and
file name `kind_session.pdx`. Both are already taken by **R113.M5-022
(paideia-os #2402, Sep 2026)**, which defined `KindSession` /
`KIND_SESSION = 0x1BC` as the user-login session substrate
(LOGIN / ACTIVE / LOCKED / EXITED lifecycle, derived over
KIND_IPC_ENDPOINT, seat ownership).

The two kinds are semantically unrelated:

| Kind                  | Ordinal | Base kind         | Row-pool substrate       | Lifecycle                       |
|-----------------------|---------|-------------------|--------------------------|---------------------------------|
| `KIND_SESSION`        | 0x1BC   | KIND_IPC_ENDPOINT | login-session row[]      | LOGIN / ACTIVE / LOCKED / EXITED |
| `KIND_SHELL_SESSION`  | 0x1A9   | KIND_IPC_ENDPOINT | svc.shell-session row[]  | INIT / ACTIVE / SUSPENDED / TERMINATED |

The paideia-as encoder enforces basename ↔ module-name case-fold
match (`kind_shell_session.pdx` ↔ `KindShellSession`), so a second
`module KindSession` declaration would collide at link time
regardless of its file path. We therefore adopt the longer
`KindShellSession` name across the board — the KIND constant, the
module, the ops, the rights, the error band — and prefix every
helper with `ks_` to stay clear of the login-session's `session_*`
helper namespace.

The task directive's `SESSION_OP_*` / `R_SESSION_*` identifiers are
remapped in the implementation to `KS_OP_*` / `R_KS_*` for the same
reason; aliases are deliberately NOT exported, so a future caller
that imports both modules cannot accidentally cross the two
namespaces.

---

## 3. Ordinal choice — 0x1A9

An audit of the KIND registry at 2026-10-13 (`grep -rnE "= 0x1A[5-F]
\|= 0x1B0\b" src/ --include="*.pdx"`) returned:

| Slot | Occupant                       | Source                                 |
|------|--------------------------------|----------------------------------------|
| 0x1A5 | `KIND_PDXFS_MOUNT_TABLE`      | R53-PREP-001 (#1728)                   |
| 0x1A6 | `KIND_TUI_CANVAS`             | R89.M1-002 (#1989)                     |
| 0x1A7 | `KIND_TLS_TRUST`              | R100-PREP-001 (#2007)                  |
| 0x1A8 | `KIND_UDP_SOCKET`             | R93.M1 reservation (comment-only, live use at kind_mbim_session) |
| **0x1A9** | *reserved for `KIND_PACKET_FILTER` (R96)* — **CLAIMED HERE** | kind.pdx L3025 comment |
| 0x1AA | *reserved for `KIND_TLS_CONN` (R97)* | kind.pdx L3026 comment            |
| 0x1AB | `KIND_TCP_SOCKET`             | fix#2005 renumber                      |
| 0x1AC | `KIND_TCP_LISTENER`           | fix#2005 renumber                      |
| 0x1AD | `KIND_NIC`                    | R91.M1-001 (#2011)                     |
| 0x1AE | `KIND_DISPLAY_BACKEND`        | R101.M3                                |
| 0x1AF | `KIND_FRAMEBUFFER`            | COMP-IMPL-03                           |
| 0x1B0 | `KIND_PAGE_FLIP`              | R104.M4-001                            |

The umbrella directive restricted the search to `0x1A5..0x1B0`.
Every slot in that window is live EXCEPT `0x1A9` and `0x1AA`, both
of which are **comment-reserved** for networking kinds that have
not landed. A tree-wide `grep -rnE '= 0x1A9\b|= 0x1AA\b' src/`
returned ZERO declarations.

This landing claims **0x1A9**. The planned networking kinds reseat to
`0x1BD..0x1BF` (free M5 follow-on slots per
[kind_session.pdx](../../src/kernel/core/cap/kind_session.pdx)'s
reservation table line 73) or to `0x1B5..0x1B7` (user G6 reservations
that have likewise not materialised). The authoritative reseating
record lives in the updated reservation block in
[kind.pdx](../../src/kernel/core/cap/kind.pdx)'s
`KIND_TLS_TRUST` section.

Rationale for 0x1A9 over 0x1AA:

- 0x1A9 is cache-adjacent to the FS / crypto / TTY cluster
  (0x1A4..0x1A6) at the same 128-byte cache line boundary; the shell
  session semantically clusters with the TTY and the mount table more
  than with the networking kinds across the 0x1AA boundary.
- 0x1AA leaves a one-slot gap for a networking kind whose derivation
  (KIND_TLS_CONN over KIND_NIC) crosses the networking cluster
  boundary already.

**No audit ceiling bump is needed.** `aud_kind_valid` already covers
`0x140..0x1AC` (per
[audit_schema.pdx](../../src/kernel/core/audit/audit_schema.pdx)
L369), so 0x1A9 falls within the live range.

---

## 4. Derivation — over KIND_IPC_ENDPOINT

A shell session is a rendez-vous between three parties:

1. The **shell parent task** (reads from `tty_fd`, launches cmd-modules
   under `cap_env_slot`).
2. The **user REPL** (writes to `tty_fd` on behalf of a running
   command).
3. The **session daemon** (owns the row, serves lookup / state / name
   / destroy against it).

All three communicate over endpoints, so `KIND_IPC_ENDPOINT` (slot 5)
is the correct runtime base kind. This matches the precedent set by
every prior session-shaped kind in the tree:

- `KIND_FW_SESSION` (0x155)
- `KIND_MBIM_SESSION` (0x181)
- `KIND_SESSION` (0x1BC, user-login)

As every KIND_IPC_ENDPOINT-derived kind recognises
(see `kind_fw_session.pdx` §KIND HALF for the canonical write-up of
the #1075 lesson), the kind half of the gate is **empty on its own**:
every endpoint in the machine satisfies `kind == KIND_IPC_ENDPOINT`,
the shell's stdout included.

The second half of the gate for `KIND_SHELL_SESSION` is
`ss_row_in_use(target_ptr[15:0]) == 1` — a kernel-held row that only
the R127.M1 daemon writes. The row id in the descriptor's
`target_ptr[15:0]` MUST correspond to a live row, or every op refuses
with `KS_ERR_BAD_SESSION`.

---

## 5. Descriptor layout

The 24-byte `cap_table` descriptor shape (per
[mint.pdx](../../src/kernel/core/cap/mint.pdx) `cap_mint_write`):

```
[+0]   kind         = 0x1A9                   (KIND_SHELL_SESSION)
[+8]   rights       = subset of R_KS_ALL      (0x007)
[+16]  target_ptr   = row_id in bits [15:0]   (0..SS_POOL_MAX-1 = 0..7)
       target_ptr[63:16]                       reserved for a future
                                               generation counter
                                               (R127.M3 may fold a
                                               48-bit monotonic
                                               generation here so a
                                               destroyed-and-realloc
                                               slot is distinguishable
                                               from a stale cap)
```

The row itself lives in
[shell_session.pdx](../../src/kernel/core/svc/shell_session.pdx)'s
`_shell_session_pool[]` (8 rows × 128 bytes). This file does NOT
allocate a parallel pool.

Row-field offsets this handler reaches:

- `[row_base + 40]` — state field (low 32 bits of a u64 whose high
  32 are the reserved generation counter)
- `[row_base + 48 .. +111]` — 64-byte name field
  (last byte is the trailing NUL guaranteed by `_shell_session_create`)
- `[row_base + 112]` — `in_use` byte (not read here; validated
  through the `ss_row_in_use` helper)

---

## 6. Ops surface

The op ordinal lives in `op_arg[7:0]`. The semantics of `target_ptr`
and `op_arg[63:8]` vary by op (per `cap_handler_dek` precedent).

### 6.1 `SESSION_OP_LOOKUP_BY_PID` (op 0) — `R_KS_READ`

```
INPUT:
  target_ptr          = pid (FULL u64, not a row id)
  op_arg[7:0]         = 0
  op_arg[63:8]        = 0   (payload reserved; refused if non-zero)

OUTPUT (rax):
  session_id (0..7)   on hit
  KS_ERR_BAD_SESSION  on miss

DELEGATE:
  _shell_session_lookup(pid). The SS_ID_NONE sentinel (0xFF) is
  translated to KS_ERR_BAD_SESSION before return. The two bands are
  disjoint — session_id lives in [0, 8), KS_ERR_BAD_SESSION = 0x1110
  — so a caller treating the whole u64 as an error-or-id tagged
  value never collides.
```

### 6.2 `SESSION_OP_READ_STATE` (op 1) — `R_KS_READ`

```
INPUT:
  target_ptr[15:0]    = session_id
  target_ptr[63:16]   = 0 (reserved for generation counter)
  op_arg[7:0]         = 1
  op_arg[63:8]        = 0

OUTPUT (rax):
  state (0..3)        on live row
  KS_ERR_BAD_SESSION  if ss_row_in_use(session_id) == 0

GATE:
  ss_row_in_use(session_id).

READ:
  Low 32 bits of [row_base + 40]. The high 32 bits are the reserved
  generation counter — IGNORED here. Zero-extend low 32 via a plain
  `and rax, 0xFFFFFFFF`.
```

### 6.3 `SESSION_OP_SET_STATE` (op 2) — `R_KS_WRITE`

```
INPUT:
  target_ptr[15:0]    = session_id
  op_arg[7:0]         = 2
  op_arg[15:8]        = new_state ordinal (0..3; SS_STATE_MAX
                        exclusive)
  op_arg[63:16]       = 0 (refused if non-zero)

OUTPUT (rax):
  KS_OK                    on success
  KS_ERR_BAD_SESSION       on bad session_id or free row
  KS_ERR_BAD_OP            on bad new_state

DELEGATE:
  _shell_session_set_state(session_id, new_state).

RETURN TRANSLATION:
  SS_OK            -> KS_OK
  SS_ERR_BAD_ID    -> KS_ERR_BAD_SESSION
  SS_ERR_BAD_STATE -> KS_ERR_BAD_OP
  (other non-zero) -> KS_ERR_BAD_SESSION (defensive fallback)
```

### 6.4 `SESSION_OP_READ_NAME` (op 3) — `R_KS_READ`

```
INPUT:
  target_ptr[15:0]    = session_id
  op_arg[7:0]         = 3
  op_arg[63:8]        = destination user-virtual pointer (56 bits).
                        User-half canonical addresses on x86_64 are
                        at most 47 significant bits (bit 47 clear),
                        so a right-shift by 8 recovers any valid
                        ring-3 pointer without loss.

OUTPUT (rax):
  KS_OK               on live row AND out_ptr != 0
  KS_ERR_BAD_SESSION  otherwise

GATE:
  ss_row_in_use(session_id) AND out_ptr != 0.

WRITE:
  Eight u64 stores from [row_base + 48 + N*8] to [out_ptr + N*8]
  for N = 0..7. The 64th byte (at [out_ptr + 63]) is the trailing
  NUL that _shell_session_create guarantees in the name field.

POINTER SAFETY POSTURE AT M2:
  Only out_ptr != 0 is checked. Page-fault safety (what happens if
  out_ptr lands in an unmapped page) is deferred to the ring-3
  syscall ABI gate that lands with R128's KIND_SHELL_SESSION user
  surface. At M2 the caller is a supervisor-reach task.
```

---

## 7. Rights

```
R_KS_READ      = 0x001   LOOKUP_BY_PID, READ_STATE, READ_NAME
R_KS_WRITE     = 0x002   SET_STATE
R_KS_LIFECYCLE = 0x004   reserved for a future DESTROY op (R127.M3+);
                         a narrowed child cap that drops LIFECYCLE
                         cannot destroy the row.
R_KS_ALL       = 0x007   subset test in ks_rights_valid.
```

Rights are op-grained, matching the convention in
[kernel-cap-taxonomy.md](../architecture/kernel-cap-taxonomy.md) §4:
narrowed children drop rights to constrain reach.

Typical narrowing patterns:

- A session-aware status widget (watches state transitions) holds a
  child cap with `R_KS_READ` only.
- A session controller (foreground/background flipper) holds a child
  cap with `R_KS_READ | R_KS_WRITE`.
- The shell parent task holds a cap with `R_KS_ALL` and may DESTROY
  the row once R127.M3 lands the lifecycle op.

---

## 8. Mint helper — supervisor-reach only

```
kind_shell_session_mint_body(shell_session_row_id, rights,
                             out_slot_ptr) -> errno
```

The ONLY path to a `KIND_SHELL_SESSION` cap at M2. No cap-invoke op
reaches it — a ring-3 holder of a `KIND_SHELL_SESSION` cap may
DERIVE a narrowed child via `svc.cap-minter` (R125.M2) but may not
mint a fresh cap from scratch. The supervisor paths that reach the
mint helper are:

1. **The R127.M1 daemon's `_shell_session_init` hand-off path.** A
   future wiring may auto-mint one `KIND_SHELL_SESSION` per created
   row with `R_KS_ALL` and hand the resulting slot id to the shell
   parent task's cap-env; today the mint is called by the shell
   parent itself at task-launch time.

2. **A boot smoke harness** that validates the mint path returns a
   usable slot before the first `cap_invoke` dispatch.

### Reserved cap_table range

`KIND_SHELL_SESSION` mints land in `[KS_SLOT_BASE, KS_SLOT_LIMIT) =
[184, 192)`. Eight slots — exactly `SS_POOL_MAX` — so one mint per
`shell_session` row AT MOST without churn.

The reservation sits **below** `svc.cap-minter`'s `[192, 256)`
derived-cap range so a `cap_minter DERIVE` on a `KIND_SHELL_SESSION`
parent lands a child in `[192, 256)` above the mint range. A slab
allocator with lineage tracking (R128.M*+ Phase-3 rewrite) retires
both reservations.

### Mint failure taxonomy

```
KS_OK               descriptor written, *out_slot_ptr set
KS_ERR_BAD_SESSION  shell_session_row_id out of range or row free
                    (per ss_row_in_use)
KS_ERR_RIGHTS       rights not a subset of R_KS_ALL
KS_MINT_ENOSPC      [KS_SLOT_BASE, KS_SLOT_LIMIT) exhausted
```

### Mint flow

1. `ss_row_in_use(shell_session_row_id)` — else `KS_ERR_BAD_SESSION`
2. `ks_rights_valid(rights)` — else `KS_ERR_RIGHTS`
3. `ks_find_free_cap_slot()` scan `[184, 192)` — else `KS_MINT_ENOSPC`
4. `cap_mint_write(slot, KIND_SHELL_SESSION, rights, shell_session_row_id)`
5. `[out_slot_ptr] = slot`
6. Emit `KIND_SHELL_SESSION MINT OK sid=0x<hex>` via `klog_s1_x1`
7. Bump `KS_ST_MINTS`; return `KS_OK`

---

## 9. Return code band

Pinned at `0x1110..0x1113`. Band audit at 2026-10-13:
`grep -rnE "0x111[0-9A-F]\b" src/kernel/` → zero hits. Clean band.

```
KS_OK                 = 0
KS_ERR_BAD_SESSION    = 0x1110
KS_ERR_BAD_OP         = 0x1111
KS_ERR_RIGHTS         = 0x1112
KS_MINT_ENOSPC        = 0x1113   (mint-helper-only; not reachable from
                                  cap_invoke)
```

All four codes fit `imm32` with bit 31 clear, so `mov rax, imm32`
emits the 7-byte zero-extending form (no `and r11, imm64` encoder
gap).

The band is adjacent to R127.M1's `0x1101..0x1104` shell-session
daemon return band (`SS_ERR_POOL_FULL`, `SS_ERR_BAD_ID`,
`SS_ERR_BAD_PID`, `SS_ERR_BAD_STATE`) with a `0x1105..0x110F`
gap reserved for intra-daemon extensions. The two bands are strictly
disjoint so a caller handling return values from both the direct-call
API and the cap-invoke surface never misinterprets a code.

---

## 10. Interaction with R127.M1 daemon

The R127.M1 direct-call API is UNCHANGED by this landing:

| R127.M1 symbol               | Callers at M2                                 |
|------------------------------|-----------------------------------------------|
| `_shell_session_init`        | kernel_main bringup                           |
| `_shell_session_create`      | shell parent task (in-kernel bringup)         |
| `_shell_session_lookup`      | `ks_op_lookup_by_pid` (THIS LANDING) +
|                              | existing R127.M1 in-kernel sites              |
| `_shell_session_set_state`   | `ks_op_set_state` (THIS LANDING) +
|                              | existing R127.M1 in-kernel sites              |
| `_shell_session_destroy`     | shell parent task (not yet exposed via cap)   |
| `ss_row_in_use` (helper)     | `ks_op_read_state`, `ks_op_read_name`,
|                              | `kind_shell_session_mint_body`                |
| `ss_row_base` (helper)       | (unused this landing; address compute is
|                              | inlined in `ks_op_read_state` and
|                              | `ks_op_read_name` for one fewer frame)        |
| `_shell_session_pool` (data) | address-of in inlined row-base compute        |

The handler NEVER reaches `_shell_session_create` or
`_shell_session_destroy` directly — row lifecycle at M2 is still a
direct-call-only responsibility of the shell parent task. R127.M3
introduces the lifecycle op (DESTROY) under `R_KS_LIFECYCLE` that
closes this gap.

---

## 11. Interaction with R127.M3 — history and lifecycle manager

R127.M3 tightens the state transition graph that R127.M1 left
permissive:

```
INIT       -> ACTIVE
ACTIVE     -> SUSPENDED | TERMINATED
SUSPENDED  -> ACTIVE | TERMINATED
TERMINATED -> (terminal; destroy only)
```

The tightened transitions land as a **cap-invoke-level validation
in `ks_op_set_state`**, not as a direct-call-level change in
`_shell_session_set_state`. The reasoning: in-kernel callers may need
to force a transition (e.g., bringup teardown that resets a row to
INIT before freeing it), but ring-3 callers must obey the state
graph. The M2 `ks_op_set_state` currently passes through whatever
R127.M1 returns, which at M1 is permissive (any state < 4). The M3
upgrade inserts a transition check between the rights gate and the
`_shell_session_set_state` delegation.

R127.M3 also introduces a **history-anchor op** — likely op 4
(APPEND_LINE, requires `R_KS_WRITE`) and op 5 (READ_LAST_LINE,
requires `R_KS_READ`) — writing / reading the per-session history
ring buffer anchored at `[row + 24]` (`history_head`) and `[row + 32]`
(`history_tail`). The op band `[4, 15]` is RESERVED here for M3; the
handler's op bounds check will widen to `KS_OP_MAX = 5` (or higher)
without disturbing the four M2 ops.

The `R_KS_LIFECYCLE` right (0x004) is reserved for M3's DESTROY op
(op 6?). A narrowed child cap that drops `R_KS_LIFECYCLE` cannot
destroy the row; a shell parent task holding `R_KS_ALL` can.

---

## 12. Future ops reserved in the [4, 15] band

| op | name                       | right          | milestone  |
|----|----------------------------|----------------|------------|
| 4  | `SESSION_OP_APPEND_HISTORY`| R_KS_WRITE     | R127.M3    |
| 5  | `SESSION_OP_READ_HISTORY`  | R_KS_READ      | R127.M3    |
| 6  | `SESSION_OP_DESTROY`       | R_KS_LIFECYCLE | R127.M3    |
| 7  | `SESSION_OP_FORK`          | R_KS_LIFECYCLE | R128?      |
| 8  | `SESSION_OP_READ_TTY_FD`   | R_KS_READ      | TBD        |
| 9  | `SESSION_OP_READ_CAP_ENV`  | R_KS_READ      | TBD        |
| 10 | `SESSION_OP_READ_PID`      | R_KS_READ      | TBD        |

All ten slots fit in the four low bits of `op_arg[7:0]`; the top
four bits remain unused and refused by the dispatcher's bounds
check. R130+ may widen to 32 ops if the shell exposes more
inspection points.

---

## 13. Encoder-pitfall posture

Per [feedback_pdx_encoder_pitfalls](https://github.com/snunezcr/paideia-as)
(user auto-memory): the paideia-as encoder has a handful of pinned
gaps this landing deliberately sidesteps.

- **No `test rN, rN`**. Every zero-compare is `cmp rN, 0` followed by
  `je` / `jne`.
- **No 2-op `imul r, imm`**. Row-stride 128 compose as `shl rax, 7`;
  cap_table stride 24 composes as `(slot<<3) + (slot<<4)`.
- **No `and r11, imm64`**. All error codes fit `imm32` with bit 31
  clear (`0x1110..0x1113`); the 56-bit-pointer right-shift in
  `cap_handler_shell_session`'s op-3 arm uses `shr r10, 8` with no
  immediate masking.
- **Single-line `pub let name = "..."`**. Every tag string is one
  line including its NUL terminator.
- **Fingerprint `[u8; N]` sizes count the NUL**:
  - `KIND_SHELL_SESSION INIT OK\0` → 27 bytes
  - `KIND_SHELL_SESSION HANDLER OK\0` → 30 bytes
  - `KIND_SHELL_SESSION HANDLER REJ\0` → 31 bytes
  - `KIND_SHELL_SESSION MINT OK\0` → 27 bytes
  - `KIND_SHELL_SESSION MINT REJ\0` → 28 bytes
- **Module basename match**. `kind_shell_session.pdx` ↔
  `module KindShellSession` (case-folded, underscores dropped).
- **No reserved labels**. The `ks_` family stays clear of `loop`,
  `if`, `else`, etc.

Stack discipline (SysV, entry `rsp%16==8`):

| Function                           | Pushes | Sub rsp | %16 at nested call |
|------------------------------------|--------|---------|--------------------|
| `kind_shell_session_init`          | 1 (r12)| 0       | 0                  |
| `ks_note`                          | 0      | 0       | pure leaf          |
| `ks_rights_valid`                  | 0      | 0       | pure leaf          |
| `ks_decode_sid`                    | 0      | 0       | pure leaf          |
| `ks_op_lookup_by_pid`              | 2      | 8       | 0                  |
| `ks_op_read_state`                 | 2      | 8       | 0                  |
| `ks_op_set_state`                  | 2      | 8       | 0                  |
| `ks_op_read_name`                  | 3      | 8       | 0                  |
| `cap_handler_shell_session`        | 3      | 0       | 0                  |
| `ks_find_free_cap_slot`            | 0      | 0       | pure leaf          |
| `kind_shell_session_mint_body`     | 4      | 8       | 0                  |

---

## 14. Observability

`_ks_stats[8]` — one u64 per bucket (defensive scrub in
`kind_shell_session_init`):

```
[0] KS_ST_INIT_OK          incremented once per boot
[1] KS_ST_LOOKUP_OK        incremented on each live LOOKUP_BY_PID hit
[2] KS_ST_LOOKUP_MISS      incremented on each LOOKUP_BY_PID miss
[3] KS_ST_READ_STATE_OK    incremented on each live READ_STATE
[4] KS_ST_SET_STATE_OK     incremented on each successful SET_STATE
[5] KS_ST_READ_NAME_OK     incremented on each successful READ_NAME
[6] KS_ST_REFUSED          incremented on every refuse funnel
                           (any op, any gate)
[7] KS_ST_MINTS            incremented on each successful mint
```

Fingerprints emitted (one per outcome):

- `KIND_SHELL_SESSION INIT OK` (bringup, no KV)
- `KIND_SHELL_SESSION MINT OK sid=0x<hex>` (mint success)
- `KIND_SHELL_SESSION MINT REJ errno=0x<hex>` (mint failure)

The per-op handlers do NOT emit per-call fingerprints — the volume
would dwarf other kernel log sources and the `_ks_stats` counters
already supply the aggregate observability. R128+ may add a
rate-limited fingerprint for repeated REFUSED cases if a particular
failure mode becomes operationally interesting.

---

## 15. Follow-on work

- **R127.M3 — history + lifecycle manager.** Ops 4..6 (APPEND_HISTORY,
  READ_HISTORY, DESTROY) and the tightened state transition graph.
  See §11.
- **R128 ring-3 syscall ABI.** User-space entry point that wraps
  `cap_invoke(KIND_SHELL_SESSION_cap, op_arg, target_ptr)` so a
  shell task may issue `SESSION_OP_READ_NAME` with a page-faultable
  out_ptr. The syscall gate validates out_ptr against the task's
  page tables before the dispatch.
- **R128 cap_minter lineage.** Rewrites `svc.cap-minter`'s reserved-
  range allocator (currently `[192, 256)`) to a slab allocator with
  lineage tracking; `KIND_SHELL_SESSION`'s own `[184, 192)` reserved
  range retires at the same milestone.
- **R130 pid wire format change.** If paideia-os widens `pid` beyond
  u64 (unlikely but tracked), the `SESSION_OP_LOOKUP_BY_PID` payload
  encoding needs to carry the extra bits — probably by moving pid
  to `op_arg[63:0]` and reserving `target_ptr` for a different
  purpose. The ordinal numbering survives such a change.
- **Networking slot reseating.** The networking kinds that originally
  reserved `0x1A9` (`KIND_PACKET_FILTER`) and `0x1AA`
  (`KIND_TLS_CONN`) must land at `0x1BD..0x1BF` or `0x1B5..0x1B7`
  per the reservation comment in
  [kind.pdx](../../src/kernel/core/cap/kind.pdx)'s `KIND_TLS_TRUST`
  block.

---

## References

- [paideia-os #2478 umbrella](https://github.com/snunezcr/paideia-os/issues/2478) — R127 lineage
- [paideia-os #2597](https://github.com/snunezcr/paideia-os/issues/2597) — R127.M1 (daemon substrate)
- [paideia-os #2598](https://github.com/snunezcr/paideia-os/issues/2598) — R127.M2 (this landing)
- [paideia-os #2402](https://github.com/snunezcr/paideia-os/issues/2402) — R113.M5-022 (login-session `KIND_SESSION`)
- [kernel-cap-taxonomy.md](../architecture/kernel-cap-taxonomy.md) §4 — rights discipline
- [next-wave-derived-kinds.md](../architecture/next-wave-derived-kinds.md) — derived-kind registry policy
- [shell-session-daemon.md](shell-session-daemon.md) — R127.M1 companion
- [cap-minter-daemon.md](cap-minter-daemon.md) — R125.M2 svc.cap-minter DERIVE path
