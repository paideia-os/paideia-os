# Remote Failure Discipline (R137.M6)

**Status:** Landed (Wave UMB-W24).
**Issue:** paideia-os#2638.
**Source:** `src/kernel/core/svc/remote_failure.pdx`.
**Companions:**
- `svc/remote_shell.pdx` (R137.M1, Wave UMB-W19) — the connection row
  pool and lifecycle API (`_remote_shell_set_state`,
  `_remote_shell_close`) the cascade drives.
- `svc/remote_shell_handshake.pdx` (R137.M2, Wave UMB-W20) — the
  ML-KEM-768 + X25519 handshake. M6 does not call into it; it reads
  the ML-KEM shared-secret field at `row[+192..+224]` to zero it on
  cascade step 5.
- `svc/federation_discovery.pdx` (R137.M3, Wave UMB-W21) — the
  peer registry. Not called by M6; its stored (fed_id, peer_index)
  pair is reached indirectly through `_ri_lookup_peer_env`'s view of
  the identity map.
- `svc/remote_record_wire.pdx` (R137.M4, Wave UMB-W22) — the
  ChaCha20-Poly1305 record framer. M6 does not call into it; it
  classifies RRW_ERR_* codes that the framer returns.
- `svc/remote_identity.pdx` (R137.M5, Wave UMB-W23) — the
  (conn_id, fed_id, peer_index) → env_slot map. M6 calls
  `_ri_lookup_peer_env` (read) and `_ri_revoke_peer_env` (write) as
  cascade steps 1 and 3.
- `svc/cmd_audit.pdx` (R139.M3) — the forgery-resistant audit chain.
  M6 calls `_cmd_audit_begin` / `_cmd_audit_end` to write a record
  with the failure's full context as cascade step 2.

## 1. What this layer provides

R137.M6 adds the **failure discipline** that decides what to do when
an error fires on a cross-host remote-shell connection. Up through M5
the five callable surfaces (M1 pool, M2 handshake, M3 discovery, M4
wire, M5 identity) each return their own band of error codes but
**no layer decides what the kernel should do when one of them fires**.
A peer sends a frame whose Poly1305 tag does not verify — the record
framer returns `RRW_ERR_AEAD_FAIL` and no one decides whether that is:

- A once-off bit flip in flight (log, drop, continue),
- A replay attempt against a stale nonce (log, drop, counter it),
- A key compromise or active attack probe (revoke the peer, close the
  connection, audit the event with identity),
- A repeated failure that trips a per-conn circuit breaker (close
  without necessarily revoking identity).

Deciding what to do — "the failure discipline" — is a kernel-side
**policy** surface. M6 encodes it as a single consolidated module that
every upstream caller funnels into whenever an `RRW_ERR_*` fires on an
ESTABLISHED row.

The direct API is three functions:

```
_rf_handle_recv_err(conn_id, rrw_err) -> errno
_rf_handle_send_err(conn_id, rrw_err) -> errno
_rf_classify       (rrw_err)          -> failure_class
```

## 2. Trust-boundary posture

M6 does not change the trust-boundary stance set by M5. The handshake
proves wire-level identity; a bind grants local authority; a cascade
revokes it. Three invariants hold across the surface:

1. **The cascade cannot run against a stale row.** Both handlers call
   `rf_check_rs_conn` before classifying, so a conn_id that does not
   resolve to a live `_remote_shell_pool` row returns
   `RF_ERR_BAD_CONN` without touching the identity map, the audit
   chain, or any state transition.
2. **The audit record always carries the peer's identity if a binding
   exists at cascade time.** Step 1 of the cascade reads peer_env via
   `_ri_lookup_peer_env` **before** step 3 revokes it. A map miss
   (`RI_SLOT_NONE`) stamps `0xFF` into the record's
   `cap_env_fingerprint` field so an auditor can distinguish
   bound-and-revoked from never-bound.
3. **Zero'd key material never outlives in_use.** Step 5 zeroes
   `row[+192..+224]` (ML-KEM shared secret) and `row[+224..+232]`
   (nonce counter) **before** step 6's `_remote_shell_close` clears
   `in_use`. The row cannot be observed with `in_use == 0` **and**
   residual key material simultaneously.

## 3. Three-class failure taxonomy

`_rf_classify(rrw_err)` is a **pure leaf** that maps a bare
`RRW_ERR_*` value to a baseline class ordinal. The handler path
escalates that baseline using per-conn state **after** calling
classify.

### 3.1 Classes

| Class | Ordinal | Meaning |
|---|---|---|
| `RF_CLASS_TRANSIENT` | `0` | Single-shot error; log, bump counter, no cascade on first occurrence |
| `RF_CLASS_FATAL` | `1` | Unrecoverable without a fresh row; run cascade |
| `RF_CLASS_SECURITY` | `2` | Evidence of active attack; run cascade with distinct stat and audit argv_hash |
| `RF_CLASS_UNKNOWN` | `0x1D40` (== `RF_ERR_UNKNOWN_CLASS`) | Caller passed an rrw_err outside the band; caller gets the escape hatch |

The ordinal collision between `RF_CLASS_UNKNOWN` and
`RF_ERR_UNKNOWN_CLASS` is deliberate — the handler can surface
classify's unknown return directly as the handler's return errno
without a translation step.

### 3.2 Baseline rules (classify alone, no per-conn state)

| `rrw_err` | Baseline class | Rationale |
|---|---|---|
| `RRW_ERR_FRAME_MALFORMED` (`0x1D21`) | TRANSIENT | First-shot bit flip or truncated frame. No security semantics on its own. |
| `RRW_ERR_AEAD_FAIL` (`0x1D22`) | TRANSIENT | First-shot auth failure. Likely a replay or bit flip; repeat or identity presence escalates. |
| `RRW_ERR_NOT_ESTABLISHED` (`0x1D20`) | FATAL | Row is in the wrong state for I/O; nothing to retry. |
| `RRW_ERR_NONCE_EXHAUSTED` (`0x1D23`) | FATAL | We hit our own 2^64 limit; reusing a nonce would break AEAD authenticity. |
| `RRW_ERR_BAD_CONN` (`0x1D01`) | FATAL | conn_id does not resolve to a live row. |
| anything else | UNKNOWN | Return `RF_ERR_UNKNOWN_CLASS`. |

### 3.3 Handler-path escalation (per-conn state)

The handler bumps `_rf_pool[conn_id]` on every TRANSIENT and then
decides:

| Condition | Escalation |
|---|---|
| `rrw_err == AEAD_FAIL` **and** `_ri_lookup_peer_env != NONE` | TRANSIENT → SECURITY (first occurrence) |
| `_rf_pool[conn_id] >= 2` (repeat) | TRANSIENT → FATAL |
| otherwise | Stays TRANSIENT |

SECURITY is strictly stronger than FATAL: both run the cascade, but
SECURITY stamps a dedicated stat slot and (via `argv_hash = class`)
distinguishes attack-shaped events in the audit record.

### 3.4 Why AEAD_FAIL on bound identity jumps straight to SECURITY

An AEAD failure on an **unbound** connection is still suspicious, but
the server task's bind decision has not yet granted the peer any local
authority. The one-shot SECURITY escalation would be noise. On a
**bound** connection, the peer we granted local authority to is
failing to authenticate — strong evidence of key compromise or active
MitM. SECURITY fires on the first occurrence.

## 4. Cascade step ordering (invariant)

`rf_cascade(conn_id, rrw_err, class)` runs the six-step teardown. Each
step is defence-in-depth: a prior step's non-OK does not abort
subsequent steps. The earliest non-OK errno is latched in `r15` and
returned at the tail. The step order is **invariant** and documented
in the module header's §0; it is restated here for the design-doc
reader:

| Step | Action | Why this order |
|---|---|---|
| 1 | `peer_env = _ri_lookup_peer_env(conn_id)` | Must run **before** revoke so the audit record below carries the peer's local principal. Pure read; no state change. |
| 2a | `token = _cmd_audit_begin(...)` | Writes the record while identity is still live. Token = 0 (pool full) is latched but does not short-circuit. |
| 2b | `_cmd_audit_end(token, exit_code = rrw_err)` | Finalises the record and seals its BLAKE3 chain link. |
| 3 | `_ri_revoke_peer_env(conn_id)` | Clears the (fed_id, peer_index, env_slot, in_use) tuple. Idempotent — `RI_ERR_BAD_CONN` on no-binding is **not** latched. |
| 4 | `_remote_shell_set_state(conn_id, RS_STATE_CLOSING = 3)` | Row refuses re-establish and new I/O. |
| 5 | Zero `row[+192..+224]` (ML-KEM shared secret) and `row[+224..+232]` (nonce counter) | Defence-in-depth: no key material survives into `in_use == 0`. |
| 6 | `_remote_shell_close(conn_id)` | Zeroes structural fields and clears `in_use` LAST. Row is now free for a future `_accept`. |

### 4.1 Why the ordering cannot be loosened

- **Audit before revoke.** If revoke ran first, step 1's peer_env read
  would see `RI_SLOT_NONE` and the audit record would lose the
  identity of the peer that caused the event. Investigation later
  would hit a dead end.
- **Revoke before CLOSING.** If CLOSING ran first and revoke ran
  second, a race-raced follow-up frame from the same peer on the
  same conn_id could re-enter the handler in the narrow window where
  state == CLOSING but the identity map still binds. Revoking first
  closes that window.
- **Key zero before close.** If close ran first and key zero ran
  second, the row's `in_use` would be `0` while the ML-KEM shared
  secret still read non-zero through a cache-line probe. Zeroing
  first eliminates that window.
- **Close is step 6, not step 7.** Everything else needs the row to
  still read as `in_use == 1` for its own internal validation
  (`_remote_shell_set_state`, `_ri_revoke_peer_env`,
  `_cmd_audit_begin` are state-ful through our row-pool contract);
  close is the final discharge.

### 4.2 Error-latching discipline

```
r15 = RF_OK                 # init
step 2a token = 0           -> if r15 == RF_OK: r15 = CA_ERR_POOL_FULL (0x2200)
step 2b non-OK              -> if r15 == RF_OK: r15 = that errno
step 3  non-OK              -> NOT latched (revoke is idempotent)
step 4  non-OK              -> if r15 == RF_OK: r15 = that errno
step 5  (unconditional)     -> never fails
step 6  non-OK              -> if r15 == RF_OK: r15 = that errno
return r15
```

The handler never returns `RF_OK` on a partial cascade — a reader of
the handler's errno can tell "cascade ran clean" (`== 0`) from
"cascade ran with issues; see earliest step's code" (`!= 0`). The
cascade **always runs to completion** regardless; the return value is
diagnostic, not control-flow.

## 5. Interaction with M5 identity

The identity map is both an input and an output of the cascade:

- **Input:** step 1 reads peer_env **before** step 3 revokes it, so
  the audit record carries the local principal that was authorised to
  act for this peer. A map miss (`RI_SLOT_NONE`) is **not** an error
  — it means the connection was never bound to a local principal
  (e.g. the handshake completed but the server task never called
  `_ri_bind_peer_to_env`). The audit record then carries
  `peer_env = 0xFF` in `cap_env_fingerprint`.
- **Output:** step 3 calls `_ri_revoke_peer_env` regardless of whether
  a binding was present. Revoke is idempotent: the ri_pool row's
  `in_use` check short-circuits a free row to `RI_ERR_BAD_CONN` which
  the cascade **ignores** (does not latch into `r15`).

The escalation TRANSIENT → SECURITY on AEAD_FAIL is **predicated on
identity presence** (see §3.4). A SECURITY event is one where we
granted local authority and that authority is being used to send
unauthenticatable traffic — the strongest signal available at the
wire layer.

## 6. Return codes

| Code | Value | Who returns it |
|---|---|---|
| `RF_OK` | `0` | Transient (no cascade) **or** clean cascade completion |
| `RF_ERR_BAD_CONN` | `0x1D01` | `rf_check_rs_conn` miss (handler); reused alias of `RS_ERR_BAD_ID` |
| `RF_ERR_UNKNOWN_CLASS` | `0x1D40` | `_rf_classify` saw an rrw_err outside the known RRW_* band |

### 6.1 Band audit

`grep -rnE '0x1D4[0-9A-Fa-f]\b' src/kernel/` as of 2026-10-14 returned
only a stale documentary comment in `remote_identity.pdx` line 113
(claiming `FD_* (0x1D40..0x1D4F)` which is wrong — the FD band is
`0x2100..0x2103`). No code uses the band. M6 claims
`0x1D40..0x1D4F`.

### 6.2 Encoder posture

Both codes fit `imm32` with bit 31 clear, so `mov rax, imm32` emits
the 7-byte zero-extending form. No `and r11, imm64` ever appears in
this module.

## 7. Pool and stats

### 7.1 `_rf_pool` — per-conn fail counter

Four u64 rows (32 B total). Row addressing uses `shl rax, 3` (stride
8, power of two). Bumped on every TRANSIENT; read to drive the
"two in a row escalates to FATAL" rule.

**Known gap:** the counter is **not** reset on cascade. Step 6's
`_remote_shell_close` clears the row's `in_use`, so the counter
becomes stale but harmless. A future `_accept` of the same conn_id
should reset the counter — deferred to R137.M7 (the next milestone,
where the accept path reaches rf for the first time). The fail-safe
is that a stale counter only **escalates** rather than suppresses, so
a new session's first AEAD failure may spuriously escalate once.
Documented here so a future refactor sees the gap.

### 7.2 `_rf_stats` — 16-slot observability counter

| Slot | Name | Meaning |
|---|---|---|
| 0 | `RF_ST_RECV_TRANSIENT` | recv-side transient; no cascade |
| 1 | `RF_ST_RECV_FATAL` | recv-side fatal; cascade run |
| 2 | `RF_ST_RECV_SECURITY` | recv-side security escalation |
| 3 | `RF_ST_RECV_UNKNOWN` | classify returned unknown |
| 4 | `RF_ST_RECV_BAD_CONN` | conn_id check failed |
| 5 | `RF_ST_SEND_TRANSIENT` | send-side transient |
| 6 | `RF_ST_SEND_FATAL` | send-side fatal |
| 7 | `RF_ST_SEND_SECURITY` | send-side security |
| 8 | `RF_ST_SEND_UNKNOWN` | send-side unknown |
| 9 | `RF_ST_SEND_BAD_CONN` | send-side bad conn |
| 10 | `RF_ST_CASCADE_OK` | clean cascade completion |
| 11 | `RF_ST_CASCADE_PART` | partial cascade (earliest latched) |
| 12 | `RF_ST_CLASSIFY_OK` | known class returned |
| 13 | `RF_ST_CLASSIFY_UNKNOWN` | unknown class returned |

Slots 14 and 15 are reserved for M7's extensions (circuit-breaker
reset counts and per-federation aggregate rates).

## 8. Fingerprint tags

| Tag | Length | Purpose |
|---|---|---|
| `REMOTE_FAILURE RECV OK` | 22 chars + NUL (N=23) | Both handler tails — transient-no-cascade **and** dispatched-to-cascade (handler succeeded; cascade result propagates in `rax` separately) |
| `REMOTE_FAILURE RECV REJ` | 23 chars + NUL (N=24) | Handler returned a non-OK before dispatch |
| `REMOTE_FAILURE SEND OK` | 22 chars + NUL (N=23) | Send-side mirror |
| `REMOTE_FAILURE SEND REJ` | 23 chars + NUL (N=24) | Send-side mirror |
| `REMOTE_FAILURE CASCADE OK` | 25 chars + NUL (N=26) | Every cascade step returned its own OK |
| `REMOTE_FAILURE CASCADE REJ` | 26 chars + NUL (N=27) | Partial cascade; earliest step's errno in `errno=` KV |

The three `*OK` tags are added to `tools/verify-fingerprint-coverage.sh`
as unreachable-at-M6 allowlist entries. They retire with R137.M7
when the cap-invoke dispatch arm wires the handlers at the error-
return sites of `_rrw_send_record` / `_rrw_recv_frame`.

## 9. Wire-up contract (for R137.M7+)

M6 does **not** reach into `_rrw_send_record` or `_rrw_recv_frame` to
install itself. R137.M7's cap-invoke dispatch arm must add two call
sites:

```
// in _rrw_send_record, at the RRW_ERR_* return path:
mov rdi, <conn_id>
mov rsi, <rrw_err>
call _rf_handle_send_err
// propagate the handler's return as the invocation errno
```

```
// in _rrw_recv_frame, at the RRW_ERR_* return path:
mov rdi, <conn_id>
mov rsi, <rrw_err>
call _rf_handle_recv_err
```

The wire-up decision deferred to M7 is **what the invoker returns**
when the handler escalates. Three options:

1. **Return `RF_OK` on transient, pass handler errno otherwise.** The
   invoker treats a transient as "wire error, retry at upstream." This
   matches the handler's design intent.
2. **Always return the original rrw_err.** The handler is pure side
   effect; the invoker's response contract does not change. This is
   the lowest-risk wire-up.
3. **Return a composed errno that encodes both.** Over-engineered for
   M7; deferred to M8+ if ever needed.

M7's expected choice is (2): the handler is a policy sink; the
invoker's wire protocol does not grow a new return band. Documented
here so M7 does not re-litigate the question.

## 10. Known limitations and future work

- **Counter-reset gap:** `_rf_pool[conn_id]` persists across
  `_remote_shell_close` → `_accept` cycles. Addressed by R137.M7 when
  the accept path reaches rf for the first time; see §7.1.
- **Single-counter aggregation:** the counter counts all TRANSIENTs
  together. A future design may want to separate FRAME_MALFORMED and
  AEAD_FAIL into two counters so a mix of transient classes does not
  prematurely escalate.
- **No circuit-breaker reset path:** a conn_id that triggers one
  TRANSIENT and then runs cleanly for an hour still carries the
  counter. A time-based decay (TSC-anchored) would reset the counter
  on cold periods; deferred.
- **No per-federation aggregates:** a federation whose peers all show
  mild TRANSIENT noise is interesting but currently invisible — the
  stats are per-handler-side, not per-federation. Slots 14-15 are
  reserved for this.
- **Audit record payload is ad-hoc:** we repurpose
  `_cmd_audit_begin`'s five u64 fields: `session_id = conn_id`,
  `pid = 0xFFF (wire-layer sentinel)`, `cmd_hash = rrw_err`,
  `argv_hash = class`, `cap_env_fingerprint = peer_env_slot`. A
  dedicated audit-record kind for wire-layer failures (vs. command
  dispatch) would let a verifier filter without a magic `pid` match.
  Deferred to R139.M7+ when the audit chain itself grows typed records.

## 11. Verification plan

M6 lands with **no asserting smoke mode**: the three OK fingerprints
are allowlisted and the handler path is unreachable from any current
caller. Verification is per-call-site at review time:

1. **Band audit.** `grep -rnE '0x1D4[0-9A-Fa-f]\b' src/kernel/` at
   commit time returned exactly one stale documentary hit in
   `remote_identity.pdx` line 113 (the file called the
   `0x1D40..0x1D4F` band "FD_*" though the FD band actually lives at
   `0x2100..0x2103`). After this landing the same grep must return
   that same stale hit **plus** the new `0x1D40` usages inside
   `remote_failure.pdx` — and nothing else. The stale hit retires
   when the historical cross-reference in `remote_identity.pdx`
   is updated in a follow-up.
2. **Stack alignment.** All call-nested entries land `rsp%16==0`
   before every nested `call`:
    - `rf_cascade`: 5 pushes + `sub rsp, 16`. Entry `rsp%16==8`;
      after `+5*8 + 16 = 56` bytes, `rsp%16 == (8 - 56) mod 16 == 0`.
      Call-ready. ✓
    - `_rf_handle_recv_err` / `_rf_handle_send_err`: 3 pushes, no
      `sub rsp`. Entry `rsp%16==8`; after `+3*8 = 24` bytes,
      `rsp%16 == (8 - 24) mod 16 == 0`. Call-ready. ✓
    - `_rf_classify`: pure leaf for the common path; the three
      stat-bump branches use a one-off `push rax; call rf_note;
      pop rax` sequence (entry `%16==8`; +1 push = `%16==0`
      call-ready; pop restores before `ret`). ✓
3. **Band discipline.** Both error codes (`0x1D01`, `0x1D40`) have
   bit 31 clear and fit `imm32`; the file uses `mov rax, imm32`
   everywhere, never `and r11, imm64`.
4. **Classify unit shape.** `_rf_classify` is reachable without a
   live row (it reads no state), so an in-tree test harness could
   drive it directly on {0x1D01, 0x1D20, 0x1D21, 0x1D22, 0x1D23,
   0xDEAD} and assert the five known values plus unknown. Deferred
   to R137.M7 when a test harness lives alongside the wire-up.

## 12. Related issues and milestones

- Opens: paideia-os#2638 (this issue).
- Closes: paideia-os#2638.
- Successor: R137.M7 (cap-invoke dispatch arm; wires `_rf_handle_
  {send,recv}_err` at the two error-return sites).
- Verifies against: R139.M3 (`cmd_audit`) and R137.M5
  (`remote_identity`) through their respective smoke modes once M7
  lands.
