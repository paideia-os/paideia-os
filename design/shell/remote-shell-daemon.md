# svc.remote-shell daemon — R137.M1

**Status:** landed (R137.M1, Wave UMB-W19, paideia-os#2633)
**File:** `src/kernel/core/svc/remote_shell.pdx`
**Depends on:** `endpoint_alloc_at`, `svc_register`, `klog_s1` / `klog_s1_x1`, `rdtsc`
**Depended on by:** R137.M2 (ML-KEM-768 + X25519 hybrid handshake + KIND_REMOTE_SHELL), R137.M3 (wire-protocol framing against rx/tx rings)

---

## 1 Why a daemon?

R137 is the umbrella for **cross-host pipeline transport** — the paideia-os answer to "a shell on this box takes input from a shell on another box, with no POSIX inheritance in the authentication path." A connection is an aggregate of:

- the remote 4-tuple (`remote_ip`, `remote_port`, `local_port`),
- the hybrid-KEM session slot (opaque pointer into the ML-KEM-768 session table landed by R137.M2),
- two independent buffer-ring offsets (rx, tx — the ring substrate itself lands in R137.M3),
- the lifecycle state and flag word,
- byte counters (`bytes_rx`, `bytes_tx`),
- a 64-byte display name,
- the TSC at mint time.

None of these have an obvious home on the task struct, and the KEM session slot is a cross-cutting cryptographic session that outlives any single syscall. A dedicated row pool keyed by `conn_id` keeps the remote-shell state off the task hot path and gives R137.M2 a stable id (`conn_id in [0, 4)`) to mint `KIND_REMOTE_SHELL` capabilities against.

Shape mirrors `svc.jail-supervisor` (R135.M1) one-for-one: a bringup entry that claims a specific endpoint via `endpoint_alloc_at` + `svc_register`, a small row pool with a linear scan for find-free, and a direct-call API for in-kernel callers that lifts to a `cap_invoke` dispatch surface in the next milestone.

---

## 2 Service identity

| field                              | value                   |
|------------------------------------|-------------------------|
| Service name                       | `svc.remote-shell`      |
| Name length                        | 16 bytes                |
| Endpoint id                        | **24** (see §Endpoint-choice) |
| Broker row                         | `svc_register("svc.remote-shell", 16, 24)` |
| klog subsystem                     | `SUBSYS_NET_` (`net`)   |
| Bringup return-code band           | `RS_OK = 0`, `RS_ERR_* = 0x1D00..`, `RS_BRINGUP_* = 0xFFFFEBD6..` |

The `SUBSYS_NET_` tag is deliberate: unlike the other svc.* daemons (which log under `cap` or `user`), this one is network-facing and audit greps for `net` should see its activity.

---

## 3 Row layout — 256 bytes per row, 4 rows

Each row is 256 bytes = 32 u64. Stride 256 is a power of two so row addressing uses `shl rax, 8` — no `imul r, imm` (an encoder gap, see `feedback_pdx_encoder_pitfalls`).

The task row-shape directive specifies these logical fields:

```
remote_ip         : u32
remote_port       : u16
local_port        : u16
state             : u32
flags             : u32
kem_session_slot  : u64
rx_ring_offset    : u32
tx_ring_offset    : u32
bytes_rx          : u64
bytes_tx          : u64
name              : [u8; 64]
created_tsc       : u64
reserved          : [u8; 128]
```

Packed storage (all u64 lanes; no sub-word writes outside the name byte-copy):

| offset | u64 word       | contents                                                        |
|--------|----------------|-----------------------------------------------------------------|
| `+0`   | `ep_lo`        | `remote_ip` (low 32) \| `remote_port` (bits 32..47) \| `local_port` (bits 48..63) |
| `+8`   | `sf`           | `state` (low 32) \| `flags` (high 32)                            |
| `+16`  | `kem_session_slot` | opaque u64, written by R137.M2                                |
| `+24`  | `ring`         | `rx_ring_offset` (low 32) \| `tx_ring_offset` (high 32), written by R137.M3 |
| `+32`  | `bytes_rx`     | received byte counter (incremented by R137.M3's wire parser)    |
| `+40`  | `bytes_tx`     | transmitted byte counter                                        |
| `+48 .. +111` | `name[0..63]` (8 u64 words) | 64-byte display name, last byte reserved for NUL   |
| `+112` | `created_tsc`  | rdtsc sample taken at mint time                                 |
| `+120` | `in_use`       | 0 = row free, 1 = row allocated (authoritative free/live gate)  |
| `+128 .. +255` | `reserved[128]` | slack for R137.M2 handshake-context parking (ML-KEM-768) |

Row-addressed capacity: `RS_POOL_MAX = 4` connections. 4 × 256 = 1024 bytes = 128 u64. The `in_use` field at `+120` (not `remote_ip`) is the authoritative free/live gate: `.bss` zero-init gives us the FREE sentinel for free at real boot.

### Why pack `ep_lo` into a single u64

Three sub-word writes (`mov_d` + two `mov_w`) would need the paideia-as sub-word store encoder, which has edge cases around displaced indexing (see `shell_session.pdx` ss_cr_name_loop header). Packing the whole remote endpoint into one u64 lets us use a single `mov [row+0], r9` store with no sub-word emit discipline — the entire 4-tuple's variable half lands atomically.

### Why keep `kem_session_slot` opaque at M1

The slot is only meaningful once R137.M2's KEM session allocator exists. Validating a slot id at M1 would require either (a) stubbing the allocator (defeats the purpose of M1 as substrate-only) or (b) accepting any u64 and failing silently later (worse). Keeping the field as a transparent u64 that this layer never reads lets R137.M2 write it in without a row-width migration.

### Why 128 bytes of slack

ML-KEM-768's public-key hash (32B), chaining key (32B) and session-salt (variable, 32–64B) fit comfortably in 128 bytes with room for a few state machine fields. If the handshake stack ends up needing more, R137.M2 can either:

1. Spill into a separate KEM session row (the clean path), or
2. Negotiate a row-width bump as part of the M2 landing.

Either way, R137.M1 does not pre-commit the choice.

---

## 4 State machine

Five states, named by ordinal:

| ordinal | name          | invariant                                                           |
|---------|---------------|---------------------------------------------------------------------|
| 0       | `INIT`        | Row allocated by `_remote_shell_accept`; TCP 3-way complete; hybrid-KEM handshake not started; connection carries NO authenticated session key. |
| 1       | `HANDSHAKE`   | ML-KEM-768 + X25519 hybrid handshake in flight. Set by R137.M2 when it allocates the KEM session slot and writes it into `[+16]`. |
| 2       | `ESTABLISHED` | Hybrid handshake complete; session key derived; wire-protocol frames flowing on the rx/tx rings. Set by R137.M2 at Encaps/Decaps success. |
| 3       | `CLOSING`     | Orderly teardown initiated (either peer). Rings may still have in-flight frames; new writes refused. Set by R137.M3 at FIN or by an admin-side `_remote_shell_set_state` call at M1 witness time. |
| 4       | `CLOSED`      | Rings drained, KEM session slot released, row AWAITING `_remote_shell_close()`. A subsequent `_close()` frees the row. |

### Transition policy

**M1 posture:** permissive. `_remote_shell_set_state` validates `state < RS_STATE_MAX = 5` and writes it unconditionally.

**Strict matrix** (lifts into R137.M2):

```
INIT       --> HANDSHAKE | CLOSING
HANDSHAKE  --> ESTABLISHED | CLOSING
ESTABLISHED --> CLOSING
CLOSING    --> CLOSED
CLOSED     --> (terminal; next step is _close)
```

The strict matrix lands with R137.M2 because that is where the handshake state machine OWNS the `HANDSHAKE -> ESTABLISHED` transition and the test harness has enough primitives to exercise it end-to-end. R137.M1's permissive posture is a witness convenience: a smoke test can shunt a freshly-accepted row from INIT straight to CLOSING to probe the close path without wiring the whole handshake stack.

---

## 5 Public API

### `_remote_shell_init() -> RS_OK | RS_BRINGUP_*`

Boot hook. Claims `endpoint_alloc_at(24)` then `svc_register("svc.remote-shell", 16, 24)`. On endpoint refusal returns `RS_BRINGUP_EP_FAIL` **without** calling `svc_register` (the "do not partially install the row" discipline from R48-PREP-005.M1 / R90-XREPO.012.M2-002). On register refusal returns `RS_BRINGUP_REG_FAIL`.

Fingerprints:
- Success: `REMOTE_SHELL INIT OK` (no KV)
- EP fail: `REMOTE_SHELL INIT FAIL errno=0xFFFFEBD6`
- REG fail: `REMOTE_SHELL INIT FAIL errno=0xFFFFEBD7`

### `_remote_shell_accept(remote_ip, remote_port, local_port, name_ptr, name_len) -> packed u64`

Mint a fresh connection row. Steps:

1. `rs_find_free() -> conn_id`. If `RS_ID_NONE`, return `RS_ERR_POOL_FULL`.
2. Pack `ep_lo = remote_ip | (remote_port << 32) | (local_port << 48)` into `[row+0]`.
3. Zero `sf`, `kem_session_slot`, `ring`, `bytes_rx`, `bytes_tx`.
4. Byte-copy up to `min(name_len, 63)` bytes from `name_ptr` with trailing NUL. Pre-advance the destination pointer by `RS_OFF_NAME` (= 48) to sidestep the unsupported `mov_b [reg+reg*1+off], reg` store form (same technique as `shell_session.pdx` ss_cr_name_loop and `jail_supervisor.pdx` js_cr_name_loop).
5. Sample `rdtsc` → `created_tsc` at `[row+112]`.
6. Set `in_use = 1` LAST.
7. Emit `REMOTE_SHELL ACCEPT OK cid=0x<hex>`.
8. Return `(conn_id << 2) | RS_OK`.

Packed return: `conn_id << 2` lives in `[0, 16)` which is disjoint from every `RS_ERR_*` value (all `>= 0x1D00`), so a caller treating the whole u64 as an error-or-id tagged value never collides.

### `_remote_shell_set_state(conn_id, state) -> errno`

Write the state field in `[row+8]` low 32 bits of the `sf` word without touching `flags` (high 32). Shift-trick decompose: load `r9 = sf`, `shr r9, 32` (r9 = flags), `shl r9, 32` (flags in high 32, low 32 cleared), `or r9, state`, store back. No `imm64` bitmask required.

Returns:
- `RS_OK` on success
- `RS_ERR_BAD_ID` if `conn_id` is out of range or row is not `in_use`
- `RS_ERR_BAD_STATE` if `state >= RS_STATE_MAX`

Fingerprints: `REMOTE_SHELL STATE OK cid=0x<hex>` or `REMOTE_SHELL STATE REJ errno=0x<hex>`.

### `_remote_shell_close(conn_id)`

Mark a row free. Validates `conn_id` via `rs_row_in_use`; zeros `ep_lo`, `sf`, `kem_session_slot`, `bytes_rx`, `bytes_tx`; clears `in_use` LAST so a concurrent scan either sees the live row or a fully-free row (ordering mirrors `js_destroy` / `ss_destroy`).

The `kem_session_slot` zeroing is **critical** defence-in-depth: a stale KEM session slot on an empty row MUST NOT leak into a subsequent `_accept`. R137.M2's KEM session allocator will refuse an index that is not in use, but this layer owns the "closed row has no residual KEM authority" invariant.

Fields deliberately left to the NEXT `_accept` to overwrite: ring offsets, name, `created_tsc`. The scanning invariants above (`in_use` is the authoritative gate) prevent any stale observation.

---

## 6 Return codes

| name                   | value        | emits                                 |
|------------------------|--------------|---------------------------------------|
| `RS_OK`                | `0`          | success                               |
| `RS_ERR_POOL_FULL`     | `0x1D00`     | all 4 rows in use                     |
| `RS_ERR_BAD_ID`        | `0x1D01`     | conn_id out of range or row not in_use |
| `RS_ERR_BAD_STATE`     | `0x1D02`     | state >= RS_STATE_MAX                  |
| `RS_BRINGUP_EP_FAIL`   | `0xFFFFEBD6` | `endpoint_alloc_at(24)` refused        |
| `RS_BRINGUP_REG_FAIL`  | `0xFFFFEBD7` | `svc_register` refused                 |

All `RS_ERR_*` codes fit `imm32` with bit 31 clear, so `mov rax, imm32` emits the 7-byte zero-extending form (never `and r11, imm64`). Band audit (2026-10-14): `grep -rnE '0x1D0[0-2]\b' src/kernel/` returns zero hits outside this file. Clean band.

The bringup codes take `D6/D7` in the free `EBC8..EBDF` band, adjacent to `jail_supervisor`'s `D4/D5` and `shell_session`'s `D2/D3`.

---

## 7 Interaction with R137.M2 (handshake) + R137.M3 (wire)

At M1 `_remote_shell_accept` lands a row with `kem_session_slot = 0` and `state = RS_STATE_INIT`. R137.M2's handshake entrypoint will:

1. Call `_remote_shell_set_state(conn_id, RS_STATE_HANDSHAKE)`.
2. Allocate a KEM session row via the (to-be-landed) KEM session allocator, write its index into `[row+16]` via a dedicated `_remote_shell_bind_kem_slot` helper (M2 lands this).
3. Drive the ML-KEM-768 + X25519 hybrid Encaps/Decaps round-trip.
4. On success, call `_remote_shell_set_state(conn_id, RS_STATE_ESTABLISHED)`; on failure, call it with `CLOSING` and let the eventual `_close()` free the row.

R137.M3's wire-protocol parser attaches to the row's ring offsets AFTER `state == RS_STATE_ESTABLISHED`. The parser is responsible for bumping `bytes_rx` / `bytes_tx`; this daemon never touches those counters at M1 (they remain at `.bss` zero until M3 wires them).

The daemon is deliberately AGNOSTIC about the KEM primitive at M1: `kem_session_slot` is a u64 opaque to this layer, validated nowhere. This matches the `shell_session.pdx` / `jail_supervisor.pdx` pattern of a daemon owning a row's SHAPE while the kind handler at the next milestone owns the row's SEMANTICS.

---

## 8 Security posture

R137.M1's posture is **"trust the caller for shape"**:

- No validation of `remote_ip`, `remote_port` or `local_port`. The TCP stack (deferred into R137.M2's accept path) is the trusting party; this daemon records the values the stack hands it.
- No validation of `kem_session_slot`. The daemon does NOT touch the slot at M1 — it is written in by R137.M2's handshake entrypoint. A caller that writes a nonsensical slot id gets a nonsensical row, but no capability escalation (the slot is consulted only by R137.M2+ code that owns the KEM session table and will refuse invalid ids there).
- No validation that `_remote_shell_set_state` is reached via a capability. At M1 the direct-call API is the only surface; ring-3 callers cannot reach it until `KIND_REMOTE_SHELL` + the `cap_invoke` dispatch arm land in R137.M2.

The ML-KEM-768 hybrid handshake (deferred to R137.M2) is the **authoritative cryptographic gate** between a connected TCP endpoint and a session key the remote peer can derive. Nothing in R137.M1 authenticates a remote peer; a row in `RS_STATE_INIT` without a subsequent `HANDSHAKE -> ESTABLISHED` progression carries NO authority and the wire-protocol parser (R137.M3) is contractually required to refuse I/O against any row whose `state < ESTABLISHED`.

### Why ML-KEM-768 and not just X25519

The project's post-quantum posture (CLAUDE.md: "post-quantum") requires the shared secret derivation to survive a quantum adversary. ML-KEM-768 (NIST FIPS 203) is the standardised KEM for the NIST-II security category; the hybrid `ML-KEM-768 || X25519` keeps the X25519 safety net for the classical-adversary case while adding post-quantum resistance. R137.M2 lands the full handshake stack.

---

## 9 Endpoint-choice: 24, not 23

**The task directive is `endpoint 23`**, chosen for symmetry with classical telnet (TCP port 23).

**Endpoint 23 is already claimed** by `src/kernel/boot/witness/r31_respawn.pdx` at sub-test 5 (post-#1609 endpoint-resurrection witness, header L250-280): the witness invokes `endpoint_alloc_at(23)` at every boot and expects it to succeed unconditionally. Claiming endpoint 23 at daemon init (which runs before `witness_r31_respawn`) would race the witness and trip its first-level stage-12 assertion.

**R137.M1 therefore takes endpoint 24**, which is the lowest free endpoint id after the current 20/21/22 svc.* contingent and still below the first witness-reserved id (23). The TCP wire-protocol listener (R137.M3) can and should still bind to TCP port 23 on the external listen socket — the endpoint number is an internal kernel-IPC routing index, unrelated to the external TCP port.

**Retiring endpoint 24 to 23** is a separate decision that requires either:

- Renumbering the `r31_respawn` witness's endpoint reserve to 25+ (coordinated with `design/drivers/witness-slot-plan.md`'s running tally), **or**
- A boot-order change that admits the daemon's bringup AFTER `witness_r31_respawn`.

Neither belongs on R137.M1's critical path.

---

## 10 Boot wiring

`kernel_main.pdx` picks this up with ONE new call AFTER `_jail_supervisor_init` and BEFORE `witness_r30_platform`:

```
call _cap_minter_init;           // ENDPOINT 20, R125.M2
call _syscall_rights_table_init; // R125.M4 cap-check table
call _shell_session_init;        // ENDPOINT 21, R127.M1
call _shell_history_init;        // R127.M4
call _shell_jobs_init;           // R127.M6
call _jail_supervisor_init;      // ENDPOINT 22, R135.M1
call _remote_shell_init;         // ENDPOINT 24, R137.M1 (this)
call witness_r30_platform;       // R30 platform witness cascade
```

Placement rationale: AFTER the daemon bringups above (so the broker table has every other `svc.*` row published before this one registers) and BEFORE `witness_r30_platform` (so a future platform witness that spins up a remote-shell client / server task sees the row).

---

## 11 Fingerprint allowlist entries

All four `REMOTE_SHELL * OK` fingerprints are added to `tools/verify-fingerprint-coverage.sh`'s allowlist with the retire-when-R137.M2-lands reason. Each entry explains:

1. Which function emits it,
2. Why no production path reaches it at M1 (no TCP accept path; no `KIND_REMOTE_SHELL` cap-invoke surface),
3. What landing event retires it (R137.M2 wires the cap-invoke dispatch arm + hybrid handshake + TCP accept wire-up).

| fingerprint              | emitter                     | retires at |
|--------------------------|-----------------------------|------------|
| `REMOTE_SHELL INIT OK`   | `_remote_shell_init`        | R137.M2 (smoke-mode golden)   |
| `REMOTE_SHELL ACCEPT OK` | `_remote_shell_accept`      | R137.M2 (TCP accept path + cap-invoke) |
| `REMOTE_SHELL STATE OK`  | `_remote_shell_set_state`   | R137.M2 (handshake state-machine driver) |
| `REMOTE_SHELL CLOSE OK`  | `_remote_shell_close`       | R137.M2 (cap-invoke CLOSE op) |

The `FAIL` / `REJ` tags are opaque to the coverage gate (regex matches bare word `OK`), so no allowlist entries are needed for them.

---

## 12 Encoder discipline

Labels are prefixed `rs_` (remote-shell) to stay clear of `ss_` (`svc/shell_session.pdx`), `cmnt_` (`svc/cap_minter.pdx`), `js_` (`svc/jail_supervisor.pdx`), `sh_` (`svc/shell_history.pdx`), `sj_` (`svc/shell_jobs.pdx`) and the broader `s_` family. No reserved paideia-as keyword overlap (reserved: `loop` / `if` / `let`).

Encoder-pitfall posture (`feedback_pdx_encoder_pitfalls`):

- `cmp rN, 0` (never `test rN, rN`).
- `shl rN, 8` to compose row-base `* 256` stride (never `imul r, imm`).
- `mov rax, imm32` (never `and r11, imm64`).
- Single-line `pub let name = "..."`.
- Module basename `RemoteShell` matches file basename `remote_shell.pdx` (ddc requires exact match).
- Fingerprint `[u8; N]` with `N = string length + 1` (NUL counts).

Shift-trick for sub-word rewrites (`_remote_shell_set_state`):

```
mov r9, [row+8]       ; sf = state (lo) | flags (hi)
shr r9, 32            ; r9 = flags only
shl r9, 32            ; flags in high 32, low 32 = 0
or  r9, new_state     ; low 32 <- new_state
mov [row+8], r9       ; store
```

No `imm64` bitmask required. Mirrors the shift-trick in `jail_supervisor.pdx`'s `_jail_supervisor_spawn_check` / `_spawn_unbump` / `_child_exit` child_state rewrites.

### Stack discipline (SysV, entry rsp%16==8)

| function                       | pushes       | sub rsp | result       |
|--------------------------------|--------------|---------|--------------|
| `_remote_shell_init`           | 1 (`r12`)    | 0       | call-ready   |
| `rs_row_base`                  | 0 (pure leaf)| 0       | no-call      |
| `rs_row_in_use`                | 0 (pure leaf)| 0       | no-call      |
| `rs_find_free`                 | 0 (pure leaf)| 0       | no-call      |
| `_remote_shell_accept`         | 5 (`rbx, r12..r15`) | 16 | call-ready + 1 spill slot |
| `_remote_shell_set_state`      | 2 (`rbx, r12`) | 0     | call-ready   |
| `_remote_shell_close`          | 1 (`rbx`)    | 0       | call-ready   |

The `_accept` spill at `[rsp+0]` holds the unclamped `name_len` across the `rs_find_free` call so the clamp-to-63 can happen after allocation (keeps the find-free hot path at zero callee-save overhead).

---

## 13 Observability

Stats array `_remote_shell_stats : [u64; 16]` (`.bss` zero-init, bump-only):

| slot | name                       | bumped by                           |
|------|----------------------------|-------------------------------------|
| 0    | `RS_ST_INIT_OK`            | `_remote_shell_init` success        |
| 1    | `RS_ST_INIT_EP_FAIL`       | `_remote_shell_init` EP refusal     |
| 2    | `RS_ST_INIT_REG_FAIL`      | `_remote_shell_init` REG refusal    |
| 3    | `RS_ST_ACCEPT_OK`          | `_remote_shell_accept` success      |
| 4    | `RS_ST_ACCEPT_FULL`        | `_remote_shell_accept` pool full    |
| 5    | `RS_ST_SET_STATE_OK`       | `_remote_shell_set_state` success   |
| 6    | `RS_ST_SET_STATE_REJ`      | `_remote_shell_set_state` refusal   |
| 7    | `RS_ST_CLOSE_OK`           | `_remote_shell_close` success       |
| 8    | `RS_ST_CLOSE_REJ`          | `_remote_shell_close` refusal       |
| 9..15| reserved                   | R137.M2+                            |

Slots `9..15` are reserved for R137.M2 (handshake-start, handshake-OK, handshake-fail, wire-RX-bytes, wire-TX-bytes, state-ESTABLISHED-count, state-CLOSING-count — likely but not pinned).

Fingerprints emitted (klog subsystem `net`):

- `REMOTE_SHELL INIT OK`
- `REMOTE_SHELL INIT FAIL errno=0x<hex>`
- `REMOTE_SHELL ACCEPT OK cid=0x<hex>`
- `REMOTE_SHELL ACCEPT REJ errno=0x<hex>`
- `REMOTE_SHELL STATE OK cid=0x<hex>`
- `REMOTE_SHELL STATE REJ errno=0x<hex>`
- `REMOTE_SHELL CLOSE OK cid=0x<hex>`
- `REMOTE_SHELL CLOSE REJ errno=0x<hex>`

---

## 14 What R137.M1 does NOT do

Explicit non-goals for M1 (all land in M2+):

- **No TCP integration.** The daemon has no bind-to-port, no accept socket. R137.M2 wires the TCP accept path into `_remote_shell_accept`.
- **No KEM session allocation.** `kem_session_slot` is an opaque u64 at M1. R137.M2 lands the ML-KEM-768 + X25519 hybrid handshake and the KEM session table.
- **No wire-protocol framing.** `rx_ring_offset` / `tx_ring_offset` are zero. R137.M3 lands the byte-ring substrate and attaches a wire parser.
- **No `KIND_REMOTE_SHELL` kind.** The kind registration + cap-invoke dispatch arm land in R137.M2.
- **No ring-3 reachability.** Only in-kernel direct-call. R137.M2's cap-invoke surface is the first ring-3 reach.
- **No strict state-transition matrix.** M1 posture is permissive. R137.M2 lifts to a strict matrix.
- **No duplicate suppression on `_accept`.** Two `_accept` calls with the same `(remote_ip, remote_port, local_port)` mint two rows. R137.M2's handshake can observe cryptographic identity rather than TCP identity and reject duplicates there.
- **No row persistence across reboot.** Rows are `.bss` and lost on every boot. Session persistence (if ever) would require an orthogonal landing wave.

---

## 15 Open questions for R137.M2

- **Should `_accept` reject duplicate remote 4-tuples?** The handshake can distinguish retries from parallel sessions by cryptographic identity, so M2 may want duplicate suppression at the daemon layer anyway.
- **Should the row carry a receive-timeout?** TCP keepalive is one option; a daemon-level timer that force-transitions `HANDSHAKE -> CLOSING` after N seconds is another.
- **Does the KEM session table live inside the row (`reserved[128]`) or in a separate pool?** Separate pool is cleaner but adds an allocator step; in-row keeps allocation deterministic but ties the KEM state's lifetime to the connection's row.

None of these block R137.M1 landing; each is a specific R137.M2 question.

---

## References

- `src/kernel/core/svc/remote_shell.pdx` — the daemon.
- `src/kernel/boot/kernel_main.pdx` — boot hook at the `_jail_supervisor_init` → `_remote_shell_init` → `witness_r30_platform` seam.
- `src/kernel/core/svc/jail_supervisor.pdx` — the daemon this one is modeled on (one-for-one shape).
- `src/kernel/core/svc/shell_session.pdx` — the name-copy byte-loop idiom.
- `src/kernel/boot/witness/r31_respawn.pdx` — why endpoint 24, not 23 (header L250-280).
- `tools/verify-fingerprint-coverage.sh` — allowlist entries for the four `OK` tags.
- `feedback_pdx_encoder_pitfalls` — the encoder discipline this daemon observes.
