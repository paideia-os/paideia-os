# Remote Identity Mapping (R137.M5)

**Status:** Landed (Wave UMB-W23).
**Issue:** paideia-os#2637.
**Source:** `src/kernel/core/svc/remote_identity.pdx`.
**Companions:**
- `svc/remote_shell.pdx` (R137.M1, Wave UMB-W19) — the connection row
  pool `_remote_shell_pool` M5 validates `conn_id` against.
- `svc/remote_shell_handshake.pdx` (R137.M2, Wave UMB-W20) — the
  ML-KEM-768 handshake that transitions a row to ESTABLISHED. M5 runs
  AFTER a row is ESTABLISHED and takes no view of the handshake
  cryptography itself.
- `svc/federation_discovery.pdx` (R137.M3, Wave UMB-W21) — the
  federation / peer registry M5 cross-checks `(fed_id, peer_index)`
  against via `_fd_peer_lookup`.
- `svc/remote_record_wire.pdx` (R137.M4, Wave UMB-W22) — the
  ChaCha20-Poly1305 record framer. M4 decrypts a staged frame; M6
  dispatches it. M5 is the bridge between the two.
- `svc/cap_minter.pdx` (R125.M2) — the sub-cap derivation primitive
  M5 calls through to mint a peer's local principal.

## 1. What this layer provides

R137.M5 adds the **identity map** that bridges a cross-host peer's
wire-level handle to a local capability principal. Up to and including
M4, a frame arriving on a remote-shell connection decrypts into a
plaintext record that no M* layer knows how to run with the right
authority. M5 closes that gap by binding the wire-level triple

```
(conn_id, fed_id, peer_index)
```

to a `peer_env_slot` inside the server task's active capability
environment. The slot holds a sub-cap minted by `_cap_minter_derive`
against a parent slot the server task already owns and a rights mask
the server task approves at bind time. Narrow-only derivation (the
cap-minter's §4 invariant) ensures the sub-cap cannot widen authority
beyond what the server task itself may exercise.

A record arriving on `conn_id` consults the map via
`_ri_lookup_peer_env(conn_id)` before dispatch. The returned slot
becomes the **parent** cap for any downstream cap-check the dispatched
record would exercise (open-file, invoke, derive-deeper). A map miss
means **no principal registered for this connection** and the
dispatcher (M6+) refuses the record.

## 2. Trust-boundary posture

A record arriving over a cross-host wire carries **no ambient
authority** on the local kernel. The handshake (M2) proves the peer
completed an ML-KEM-768 exchange with a public key the local federation
registered (M3). That is a wire-level identity witness: it proves the
peer is who they claim to be across the network. It is **not** a
local-authority grant.

Granting local authority to a wire-level peer is a separate,
authored-by-server-task decision. M5 encodes that decision as a
one-shot bind call:

```
_ri_bind_peer_to_env(conn_id, fed_id, peer_index,
                     parent_cap_env_slot, rights_mask) -> packed u64
```

Semantically the server task is saying:
> "This peer, authenticated by (fed_id, peer_index), may act under the
> authority of my cap slot `parent_cap_env_slot`, narrowed to the
> rights in `rights_mask`."

The cap-minter enforces the narrow-only invariant: if `rights_mask` is
not a subset of `parent_rights`, the derive refuses with
`CM_ERR_RIGHTS_WIDEN`, which M5 surfaces as `RI_ERR_WIDEN`.

Three invariants hold across the surface:

1. **No bind can widen rights.** The cap-minter's narrow-only check
   fires BEFORE the ri_pool row is written. A policy error leaves the
   map untouched.
2. **A bind requires a live wire row.** `ri_check_rs_conn` verifies
   `_remote_shell_pool[conn_id].in_use` is set. A bind for a stale /
   closed row gets `RI_ERR_BAD_CONN` and no map state changes.
3. **A bind requires a registered peer.** `_fd_peer_lookup` is called
   with the supplied `(fed_id, peer_index)`. A miss gets
   `RI_ERR_BAD_PEER` and no map state changes.

A peer that completes M2 (wire-level identity proved) but is never
bound via M5 is **listen-only**: M4 send/recv works on the row, but
M6 will refuse to dispatch any record because the lookup misses.

## 3. API

### `_ri_bind_peer_to_env(conn_id, fed_id, peer_index, parent_cap_env_slot, rights_mask) -> packed u64`

Mint a sub-cap-env for the peer and record the binding.

- `conn_id` (u64 in `[0, RI_POOL_MAX)=4`) — remote-shell row id. MUST
  reference an in-use row in `_remote_shell_pool`.
- `fed_id` (u32-in-u64) — federation registry id. MUST reference a
  federation registered in `_fd_federation_pool`.
- `peer_index` (u64) — peer slot within the federation.
- `parent_cap_env_slot` (u64 in `[0, 6)`) — slot in the server task's
  active env holding the authority band the peer may act within.
- `rights_mask` (u64) — subset of parent's rights.

Returns packed `(peer_env_slot << 2) | status`:

- `peer_env_slot` is the slot id (`0..5`) in the server task's active
  env where the derived sub-cap now lives. On success `status ==
  RI_OK == 0`, so the whole word equals `peer_env_slot << 2` and the
  caller recovers via `rax >> 2`.
- `status == RI_ERR_BAD_CONN (0x1D01)` — `conn_id` out of range or
  remote-shell row free. Shared with `RS_ERR_BAD_ID` so the "no such
  connection" code is uniform across the remote-shell stack.
- `status == RI_ERR_BAD_PEER (0x1D30)` — `(fed_id, peer_index)` not
  registered, OR the cap-minter refused the derive with
  `CM_ERR_PARENT_INVALID` / `CM_ERR_ENV_FULL`. Both the "unknown peer"
  and "server env can't host the derive" cases collapse here because
  from the caller's perspective both mean "this peer cannot be bound
  as requested" — a resource / policy conflict.
- `status == RI_ERR_WIDEN (0x1D31)` — `rights_mask` is not a subset of
  the parent's rights. The cap-minter refused the derive.

### `_ri_lookup_peer_env(conn_id) -> env_slot | RI_SLOT_NONE`

Fast-path lookup used by the M6 dispatch arm.

- Returns `env_slot` in `[0, 6)` on hit.
- Returns `RI_SLOT_NONE == 0xFF` on miss. Both "`conn_id` out of
  range" and "`conn_id` valid but not bound" collapse to the same
  sentinel; from the dispatcher's perspective both mean "no principal
  for this record — refuse".

Pure leaf: no pushes, no stat bump, no fingerprint on the hot path.
One load for the `in_use` check and one load for the slot read.
M6's dispatcher may add its own telemetry around the lookup if
required.

### `_ri_revoke_peer_env(conn_id) -> errno`

Tear down a previously-bound mapping. Called from the deferred M6
wire-up of `_remote_shell_close`, and from any explicit revoke a
server task issues.

- `RI_OK` on success. The ri_pool row is zeroed; subsequent lookups
  on the same `conn_id` return `RI_SLOT_NONE`.
- `RI_ERR_BAD_CONN` if `conn_id` is out of range or the row is
  already free (idempotent revoke still reports the "no change"
  state).

M5 does **not** release the sub-cap in the cap-minter's `cap_table`.
The slot reclaims when the server task's active env is destroyed, or
when a later bind on the same `conn_id` overwrites the slot via a
fresh `_cap_minter_derive`. There is no `_cap_minter_revoke`
primitive at M5; adding one is a separate design decision tracked
under cap-minter-daemon.md §Forward-path and would deepen the
cap-table footprint.

## 4. Per-conn state

The `ri_pool` is a 4-row side table keyed by `conn_id`, matching
`_remote_shell_pool`'s row count. Row stride is 32 bytes (= 2^5):

| Offset | Field        | Size | Notes                              |
|--------|--------------|------|------------------------------------|
| +0     | `fed_id`     | u64  | low 32 = fed_id, hi 32 = 0         |
| +8     | `peer_index` | u64  | full 64 bits (bounded by registry) |
| +16    | `env_slot`   | u64  | low 8 = slot id (0..5), hi 56 = 0  |
| +24    | `in_use`     | u64  | 0 = free, 1 = bound                |

Total footprint 128 B. `.bss` zero-initialises at boot: every row is
free, no identity map is active until a server task binds.

**Publication contract.** On bind, the row's data fields (`fed_id`,
`peer_index`, `env_slot`) are written FIRST, then `in_use` is set LAST.
On revoke, the data fields are zeroed FIRST, then `in_use` is cleared
LAST. A concurrent scanner / lookup observing `in_use == 1` therefore
always sees fully-initialised data; one observing `in_use == 0` skips
the row entirely. Same invariant every other pool row in the
remote-shell stack obeys (RS, FED, JS, SS, SJ).

## 5. Interaction with M2 (handshake)

`_rsh_accept_server` / `_rsh_init_client` transition the row to
`RS_STATE_ESTABLISHED` and stamp `mlkem_ss`. Neither touches
`_ri_pool`: the handshake is an authentication primitive, not an
authorisation primitive.

After `ESTABLISHED` a server task MAY (but need not) call
`_ri_bind_peer_to_env`. The order is:

```
_rsh_accept_server  --> row.state = ESTABLISHED
_fd_peer_register   --> (fed_id, peer_index) known locally
_ri_bind_peer_to_env --> peer now has a local principal
_rrw_recv_frame + M6 dispatch
```

A row that completes M2 without M5 is still usable at M4 — the framer
decrypts whatever the peer sends — but the dispatch arm refuses the
plaintext.

## 6. Interaction with M3 (federation discovery)

`_fd_peer_lookup(fed_id, peer_index)` is M3's authentication-level
witness. M5 cross-checks the pair at bind time and refuses binds for
peers M3 does not know. This is a **policy gate at bind**, not a
per-recv check — the ri_pool caches the pair alongside the `env_slot`
so later wire activity does not re-walk the registry.

A peer removed from M3 AFTER bind retains the identity mapping until
an explicit `_ri_revoke_peer_env` call. M6+ MAY add a sweep that
revokes bindings whose M3 witness has disappeared, but M5 does not
take that view.

### Return-decode notes

`_fd_peer_lookup`'s success return is a packed u64:

```
bits [63..48] = status (FD_OK = 0)
bits [47..16] = remote_ip
bits [15.. 0] = remote_port
```

On error it returns a bare u64 `FD_ERR_BAD_FED (0x2102)` or
`FD_ERR_BAD_INDEX (0x2103)`. M5 decodes with two explicit
`cmp rax, 0x210X; je ri_bp_bad_peer` tests rather than a low-16 mask.
A zero-ip zero-port peer entry (which packs to `0 == FD_OK`) stays on
the hit path; a legitimate peer entry can never numerically collide
with the error codes because `_fd_peer_register` refuses `port == 0`
at register time.

## 7. Interaction with M4 (record wire) and the dispatcher at M6+

### What `_rrw_recv_frame` consults from M5

M4's `_rrw_recv_frame(conn_id, out_ptr, out_cap)` does **not** itself
consult the identity map. It decrypts the staged frame and writes the
plaintext record into the caller's buffer. The decrypt step is
cryptographic authenticity (the frame came from a peer that holds the
session key); it is **not** an authorisation step.

The identity consultation lives one layer up, in the M6 dispatch arm.
That dispatcher reads the plaintext record out of the caller buffer
and routes it to the kernel's record-type handler table (open-file,
invoke, mint-cap, …). BEFORE routing, M6 calls:

```
peer_slot = _ri_lookup_peer_env(conn_id)
if peer_slot == RI_SLOT_NONE:
    emit `DISPATCH REJ cid=0x... errno=0x1D30`
    return RI_ERR_BAD_PEER                 // dispatch-refused
// Install peer_slot as the AMBIENT parent for the handler's
// cap-check lookups.
_cap_minter_set_active_env(peer_env_handle)   // (see §8)
// Invoke the handler with `peer_slot` acting as the parent for any
// downstream _cap_minter_derive / cap-check call.
```

The split between **M4 decrypt** and **M6 identity + dispatch** is
deliberate:

- M4 can be tested with a mock peer that never calls M5 — crypto
  correctness is independently verifiable.
- M5 can be tested with a mock dispatch surface — bind / lookup /
  revoke works without needing to decrypt a frame.
- M6+ composes both: a dispatcher that fails to call either layer
  cannot land a record because M5 lookup misses OR M4 decrypt fails.

### Why not fold the lookup into recv_frame?

Three reasons:

1. **A record that fails cap-check is not necessarily a crypto
   failure.** Collapsing the lookup into `_rrw_recv_frame` would mean
   the only error code the framer can return is `RRW_ERR_AEAD_FAIL`,
   which loses the "frame was authentic, authority was wrong"
   distinction that operator diagnostics need.
2. **The ri_pool row is per-conn; the frame body is per-record.** A
   single conn may receive many records; the ri lookup is amortised
   across them. Folding it into recv_frame would re-walk the pool on
   every record, with no cache benefit.
3. **Tests.** Keeping the layers separable means M4 tests don't need
   to stand up a cap-minter env.

## 8. The active-env indirection

`_cap_minter_derive` operates on `_cap_minter_active_env[0]`, the
ambient "whose cap-env is this?" global. M5's bind path assumes the
server task has already set the active env to the task's own cap-env
BEFORE calling bind:

```
_cap_minter_set_active_env(server_env_handle)
_ri_bind_peer_to_env(conn_id, fed_id, peer_index,
                     parent_cap_env_slot, rights_mask)
```

The derive mints the sub-cap INTO the server task's env (so a future
cap-env destroy reclaims the slot). The `peer_env_slot` returned by
bind is the slot id WITHIN that env.

For M6 dispatch, two possible shapes exist:

- **A.** Keep the server task's env active during dispatch, and use
  `peer_env_slot` as the parent slot for every cap-check the handler
  triggers. The handler must only call `_cap_minter_derive` with
  `peer_env_slot` as the parent, never with the server task's own
  slots. This is simpler but puts the discipline on the handler.
- **B.** Mint a NEW cap-env for the peer at bind time, hold its
  handle in the ri_pool row, and `_cap_minter_set_active_env` to that
  handle on dispatch entry. The handler now sees a cap-env in which
  `peer_env_slot` is the ONLY starting authority, so a misbehaving
  handler cannot reach the server task's slots.

M5 lands shape A. Shape B is a forward-path (M6+) decision tracked
alongside the dispatcher work: it needs a cap-env fork primitive
`_cap_minter_fork_env` that cap_minter.pdx does not yet expose. The
ri_pool row layout reserves no field for a per-peer env handle, so
upgrading to shape B is a backward-compatible row-widening (grow
`RI_ROW_BYTES` to 64; stride becomes `shl 6`).

## 9. Failure-mode discipline (forward to M6)

| Return             | What it means                                               | M6 response                                               |
|--------------------|-------------------------------------------------------------|-----------------------------------------------------------|
| `RI_ERR_BAD_CONN`  | `conn_id` out of range OR row free.                         | Server-task bug. Log + tear down task's view of the conn. |
| `RI_ERR_BAD_PEER`  | `(fed_id, peer_index)` unknown OR server env can't host.    | Log + ask server task to supply a different parent slot.  |
| `RI_ERR_WIDEN`     | `rights_mask` not a subset of parent's rights.              | Log + REFUSE WITHOUT RETRY. Policy error, not resource.   |

A dispatcher that observes `RI_ERR_WIDEN` from `_ri_bind_peer_to_env`
MUST NOT retry the bind with a widened rights mask on behalf of the
peer — the server task is the policy authority, and a retry at the
dispatcher layer would be the dispatcher silently un-narrowing.

## 10. Observability

- **Stats:** `_ri_stats` (16 u64), slots:
    - `[0]` `RI_ST_BIND_OK`
    - `[1]` `RI_ST_BIND_BAD_CONN`
    - `[2]` `RI_ST_BIND_BAD_PEER`
    - `[3]` `RI_ST_BIND_WIDEN`
    - `[4]` `RI_ST_LOOKUP_HIT` (reserved; the lookup fast-path does not
      currently bump this slot — see §3)
    - `[5]` `RI_ST_LOOKUP_MISS` (reserved; same)
    - `[6]` `RI_ST_REVOKE_OK`
    - `[7]` `RI_ST_REVOKE_REJ`
    - `[8..15]` reserved for M6 dispatcher counters.
- **Fingerprints** (`SUBSYS_CAP_` channel):
    - `REMOTE_IDENTITY BIND OK cid=0x<hex>` on successful bind.
    - `REMOTE_IDENTITY BIND REJ errno=0x<hex>` on any bind error.
    - `REMOTE_IDENTITY REVOKE OK cid=0x<hex>` on successful revoke.
    - `REMOTE_IDENTITY REVOKE REJ errno=0x<hex>` on revoke error.
    - `REMOTE_IDENTITY LOOKUP OK` is reserved (not emitted) for an
      M6 dispatcher that wants per-lookup telemetry.

The channel is `SUBSYS_CAP_` (not `SUBSYS_NET_`) because the
identity map is a **capability authorisation** gate, not a transport
gate. An operator grepping the audit log for "a peer gained local
authority" wants the `cap` subsystem; one grepping for "a connection
was dropped" wants `net`.

## 11. Boot wiring

None. M5 declares no runtime bringup state:

- No `_ri_init` function.
- `_ri_pool` (128 B) and `_ri_stats` (128 B) are `.bss` and zero-init
  at real boot.
- No endpoint id is claimed; no `svc_register` call.
- No allowlist entry is added to the build gate.

Callers wire up at M6 (the dispatch arm consulting
`_ri_lookup_peer_env`) and at the server task's own post-handshake
bind-time entry.

## 12. Return band audit

Band `0x1D30..0x1D3F` was free as of 2026-10-14:

```
grep -rnE '0x1D3[0-9]\b' src/kernel/   # zero hits before this file
```

The band is disjoint from:

- `RS_*`  (0x1D00..0x1D02; remote_shell.pdx)
- `RSH_*` (0x1D10..0x1D13; remote_shell_handshake.pdx)
- `RRW_*` (0x1D20..0x1D23; remote_record_wire.pdx)
- `FD_*`  (0x2100..0x2103; federation_discovery.pdx)
- `CM_*`  (0x0F01..0x0F03; cap_minter.pdx)
- `SSD_*` (0x2300..0x2301; session_shutdown.pdx)
- `CA_*`  (0x2200..; cmd_audit.pdx)

All M5 codes (0x1D01 reused, 0x1D30, 0x1D31) fit `imm32` with bit 31
clear, so `mov rax, imm32` emits the zero-extending 7-byte form and
no `and r11, imm64` encoder gap applies.

## 13. Encoder discipline recap

- Labels prefixed `ri_` (service), `ri_bp_`, `ri_lk_`, `ri_rv_`
  (function-local).
- `cmp rN, 0` for every zero-test (never `test rN, rN`).
- Power-of-two stride shifts (`shl rax, 5` for `ri_pool`,
  `shl rax, 8` for `_remote_shell_pool` cross-check).
- `mov rax, imm32` for every error code; no `and r11, imm64`.
- FD error decode: explicit `cmp rax, 0x2102 / 0x2103` (not a mask).
- Single-line `pub let name = "…"`; no multi-line string literal.
- Module basename `RemoteIdentity` matches file basename
  `remote_identity.pdx`.
- Fingerprint `[u8; N]` with `N = len(string) + 1` (NUL counted).
- Register save discipline per function matches the stack-frame
  comments in `remote_identity.pdx`.

## 14. Forward path (M6+)

The deferred-to-M6 wire-up has three concrete pieces:

1. **Dispatcher consultation.** `_cap_invoke` dispatch arm for
   `KIND_FEDERATION` records calls `_ri_lookup_peer_env` BEFORE
   routing, as in §7.
2. **Revoke on close.** `_remote_shell_close` grows a hook that calls
   `_ri_revoke_peer_env(conn_id)` after state transitions to CLOSED.
   The ri row then flips to free; a subsequent accept on the same
   row id starts clean.
3. **Per-peer cap-env fork (optional).** If the discipline in §8
   proves too error-prone for handlers, cap_minter.pdx grows
   `_cap_minter_fork_env` and the ri row widens to carry a per-peer
   env handle. Shape A → shape B migration is incremental.

M5's API shape is forward-compatible with all three: the row is
addressable by `conn_id` alone, the lookup is O(1), and the revoke is
idempotent in the no-op direction.
