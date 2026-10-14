# Remote Record Wire (R137.M4)

**Status:** Landed (Wave UMB-W22).
**Issue:** paideia-os#2636.
**Source:** `src/kernel/core/svc/remote_record_wire.pdx`.
**Companions:**
- `svc/remote_shell.pdx` (R137.M1, Wave UMB-W19) — connection row pool.
- `svc/remote_shell_handshake.pdx` (R137.M2, Wave UMB-W20) — ML-KEM-768
  handshake that stamps `mlkem_ss` and transitions to `ESTABLISHED`.
- `svc/federation_discovery.pdx` (R137.M3, Wave UMB-W21) — federation /
  peer registry that an upcoming M5 wire path authorises against.

## 1. What this layer provides

R137.M4 adds the cryptographic framer for cross-host records flowing
between two peers that completed the R137.M2 handshake.  Each record
rides over a self-contained wire frame:

```
    0        4        8                   20                   20+L           36+L
    +--------+--------+-------------------+--------------------+--------------+
    | magic  | rec_len|      nonce         |  ciphertext (L)  |     tag      |
    | 'PDXR' |  u32   |     12 bytes       |                  |   16 bytes   |
    +--------+--------+-------------------+--------------------+--------------+
```

- `magic`         — four ASCII bytes `'P','D','X','R'` (little-endian u32
  = `0x52584450`).
- `record_len`    — plaintext length (u32 LE), bounded by
  `RRW_RECORD_MAX = 1024`.
- `nonce`         — 12 bytes = per-connection monotonic u64 counter
  (little-endian) followed by four zero bytes.
- `ciphertext`    — ChaCha20-Poly1305 seal of the record bytes under
  the connection's session key.
- `tag`           — the Poly1305 authentication tag (16 bytes).

Total frame overhead is `RRW_OVERHEAD = 36` bytes.

## 2. API

Two public entries drive the framer:

```
_rrw_send_record(conn_id, record_ptr, record_len) -> errno
_rrw_recv_frame (conn_id, out_ptr, out_cap) -> packed u64
```

Three accessors sit alongside for the deferred M5 transport:

```
_rrw_tx_slot    (conn_id) -> u64          // pointer to the TX frame slot
_rrw_rx_slot    (conn_id) -> u64          // pointer to the RX frame slot
_rrw_tx_frame_len(conn_id) -> u64         // bytes staged by last send_record
_rrw_rx_stage   (conn_id, frame_len) -> errno
                                           // transport (or test harness)
                                           // stamps the staged length
                                           // after depositing frame bytes
```

### `_rrw_send_record`

Validates connection, state, and record length; derives the session key;
builds the nonce; writes the frame header; calls
`paideia_crypto_chacha20_poly1305_seal` into the TX slot; advances the
counter; stamps `_rrw_tx_frame_lens[conn_id] = 36 + record_len`.  Returns
`RRW_OK` on success or one of the error codes below.

### `_rrw_recv_frame`

Reads the staged frame length from `_rrw_rx_frame_lens[conn_id]`, parses
the frame header, derives the session key, builds the AEAD params,
calls `paideia_crypto_chacha20_poly1305_open` into the caller's
`out_ptr`, clears the staged length on success, and returns a packed
`(bytes_decrypted << 32) | status`.

### Return codes

| Code                       | Hex       | Meaning                                                   |
|----------------------------|-----------|-----------------------------------------------------------|
| `RRW_OK`                   | `0x0000`  | success                                                   |
| `RRW_ERR_BAD_CONN`         | `0x1D01`  | `conn_id` out of range or row not `in_use` (alias of `RS_ERR_BAD_ID`) |
| `RRW_ERR_NOT_ESTABLISHED`  | `0x1D20`  | row state is not `RS_STATE_ESTABLISHED`                   |
| `RRW_ERR_FRAME_MALFORMED`  | `0x1D21`  | magic/len/geometry mismatch (send: `record_len > 1024`; recv: as per §4) |
| `RRW_ERR_AEAD_FAIL`        | `0x1D22`  | ChaCha20-Poly1305 seal/open returned nonzero (incl. tag mismatch), or BLAKE3 derive returned nonzero |
| `RRW_ERR_NONCE_EXHAUSTED`  | `0x1D23`  | counter saturated at `0xFFFFFFFFFFFFFFFF` before bump      |

All codes are imm32 with bit 31 clear so `mov rax, imm32` emits the
7-byte zero-extending form; no `and r11, imm64` needed anywhere.  Band
`0x1D20..0x1D2F` is reserved for M4+ record-wire codes; `0x1D00..0x1D0F`
is the M1 daemon's and `0x1D10..0x1D1F` is the M2 handshake's.

## 3. Session key derivation

The session key is NOT stashed on the row.  Each call to
`_rrw_send_record` / `_rrw_recv_frame` re-derives the 32-byte key via
BLAKE3 over the SAME input the M2 handshake would use:

```
    session_key = BLAKE3( "paideia-rsh-v1-mlkem-only" || mlkem_ss )
```

where `mlkem_ss` is the 32-byte ML-KEM-768 shared secret stamped at
`row[+192..+224]` by `_rsh_accept_server` (server) or `_rsh_init_client`
(client).  The context string is `rrw_kdf_ctx`, byte-for-byte equal to
`rsh_kdf_ctx` in the handshake module; both peers therefore converge on
the same key.

Rationale:

- **Statelessness.**  The derived key never persists beyond the single
  call that consumes it; `_rrw_sk_scratch` is a .bss region in-module.
  A compromised control flow that reads the scratch gets at most one
  record's worth of key material, and only during a live
  `_rrw_send_record` / `_rrw_recv_frame` window.
- **Convergence by construction.**  No handshake-time stash means no
  stash-stale window where the two peers hold different keys.
- **Zero coupling.**  The handshake's `_rsh_derive_session_key` runs
  once per handshake and returns the key to its caller; the record
  wire does not consume that return value, so the two layers do not
  share any writable state beyond `row[+192..+224]`.

The performance cost is one BLAKE3 of 57 bytes per record (one
compression plus a short finalisation).  At the M4 record ceiling
(`RRW_RECORD_MAX = 1024`) this is a sub-microsecond overhead per
record.  A cache lands with R137.M5 if measurement shows it matters.

## 4. Nonce discipline

The 12-byte AEAD nonce is `(counter as LE u64) || 0x00000000`:

```
     bytes: 0  1  2  3  4  5  6  7  8  9 10 11
     field:               counter               ||   zero pad
            little-endian u64                       four zero bytes
```

The counter is a per-connection monotonic u64 at `row[+224..+232]`.
`_rrw_send_record` reads the counter BEFORE sealing, uses it as the
nonce, then advances it with `counter + 1` after a successful seal.
A failed seal (AEAD error, nonce exhausted) does not consume nonce
space.  `_rrw_recv_frame` reads the nonce from the frame header
verbatim; it does NOT update any local counter (the receiver's view
of "which nonce is current" is dictated entirely by the sender).

### Exhaustion

The counter saturates at `0xFFFFFFFFFFFFFFFF`.  The next
`_rrw_send_record` returns `RRW_ERR_NONCE_EXHAUSTED` and does not seal
anything.  At the M4 record ceiling this is purely defensive: a sender
would need `2^64` sealed records (more records than fit in a `2^74`-byte
transport) to reach it.

### Where the counter lives

The row's post-mlkem_ss slack is reserved for `x25519_ss` in the hybrid-
handshake widening (see `design/shell/remote-shell-hybrid-kem.md`).  M4
occupies the FIRST eight bytes of that slack (`row[+224..+232]`) for
the nonce counter and leaves `row[+232..+256]` untouched.  The hybrid
landing (R137.M2-split) will migrate `x25519_ss` to a dedicated side
table rather than co-habit with the counter — same posture as the way
M2 pushed the ML-KEM-768 dk out to `_rsh_hs_scratch` because 2400 B does
not fit in the row's 128-byte slack.

## 5. Interaction with the M2 handshake and M3 federation

### M2 → M4 (handshake → record wire)

1. R137.M1 `_remote_shell_accept` lands a row with `state = INIT`,
   `kem_session_slot = 0`, counter = 0 (`.bss` zero).
2. R137.M2's handshake sequence takes the row through
   `INIT → HANDSHAKE → ESTABLISHED` and stamps `mlkem_ss` at
   `row[+192..+224]`.
3. M4's `_rrw_send_record` requires `ESTABLISHED` and reads `mlkem_ss`
   on each call to re-derive the session key; before `ESTABLISHED`
   `mlkem_ss` is zero and the derivation is cryptographically useless
   — the gate at step (1) refuses with `RRW_ERR_NOT_ESTABLISHED`
   before any crypto runs.

### M3 → M4 (federation → record wire)

The M4 framer does NOT itself consult the federation registry.  The
authorisation gate `fd_authorise_handshake` (R137.M5) lives UPSTREAM
of the M4 framer — a handshake that reaches `ESTABLISHED` for a peer
not registered in the invoker's federation is a handshake that should
not have proceeded in the first place.  M4 trusts M2's `ESTABLISHED`
state as a derived witness of a successful federation gate.

### M4 → M5 (record wire → TCP transport)

The actual TCP wire I/O is deferred.  `_rrw_send_record` leaves a
sealed frame in the per-conn TX slot and stamps the length in
`_rrw_tx_frame_lens[conn_id]`; the deferred M5 transport picks up the
frame, calls `tcp_send_segment` to transmit it, and zeros the length
to signal readiness for the next send.  Receive is symmetric: the
transport deposits a received frame into the RX slot, calls
`_rrw_rx_stage(conn_id, frame_len)` to stamp the length, then
`_rrw_recv_frame` consumes it and clears the stamp.

### M4 → M5 identity-mapping forward path

The frame carries NO identity today — the inbound record is attributed
to whoever `conn_id` resolves to (one of four accepted TCP peers).
R137.M5 lands two pieces that lift the identity:

1. **Per-connection auth cap** — a KIND_REMOTE_SHELL mint on
   `_remote_shell_accept` success binds the row to the invoker's
   capability chain; `_rrw_send_record` becomes a cap-gated op.
2. **Federation identity in AAD** — the frame's zero-length AAD today
   is reserved; M5 fills it with `(fed_id, invoker_cid, conn_id)` so
   a tampering transport that re-slot the frame to a different
   connection would fail the AEAD open.

## 6. Encoder discipline

Label prefix `rrw_` (distinct from `rsh_` / `rs_` / `fd_`).  Module
basename `RemoteRecordWire` matches file basename `remote_record_wire.pdx`.
Encoder-pitfall discipline:

- `cmp rN, 0` never `test rN, rN`;
- `shl rN, 8` for row stride 256, `shl rN, 11` for slot stride 2048 —
  never `imul r, imm`;
- `mov rax, imm32` for every error code (all codes bit-31-clear) —
  never `and r11, imm64`;
- `shl rax, 32` for the packed-return hi half (imm8 operand);
- single-line `pub let name = "..."` for the context string and tag
  literals;
- fingerprint `[u8; N]` with `N = len(string) + 1` (NUL counts);
- the module calls `paideia_crypto_blake3_hash` and
  `paideia_crypto_chacha20_poly1305_seal` / `_open` by direct name,
  matching the precedent set by `sys_dek_apply_body.pdx` L388 (the
  kernel link line already carries `libpaideia_satellite_runtime.a`).

Stack discipline — SysV, entry `rsp%16==8`:

| Function                   | Pushes   | `sub rsp` | Nested calls                                 |
|----------------------------|---------:|----------:|----------------------------------------------|
| `rrw_row_base`             | 0        | 0         | —                                            |
| `rrw_tx_slot_base`         | 0        | 0         | —                                            |
| `rrw_rx_slot_base`         | 0        | 0         | —                                            |
| `rrw_check_conn`           | 0        | 0         | —                                            |
| `rrw_check_established`    | 0        | 0         | —                                            |
| `rrw_note`                 | 0        | 0         | —                                            |
| `_rrw_tx_slot`             | 0        | 0         | —                                            |
| `_rrw_rx_slot`             | 0        | 0         | —                                            |
| `_rrw_tx_frame_len`        | 0        | 0         | —                                            |
| `_rrw_rx_stage`            | 1 (rbx)  | 0         | —                                            |
| `rrw_derive_sk`            | 0        | 8         | `paideia_crypto_blake3_hash`                 |
| `_rrw_send_record`         | 4        | 8         | check_conn, check_established, derive_sk, chacha20_poly1305_seal, note, klog_s1_x1 |
| `_rrw_recv_frame`          | 4        | 8         | check_conn, check_established, derive_sk, chacha20_poly1305_open, note, klog_s1_x1 |

## 7. Security review

### Known-good properties

- **Confidentiality** — ChaCha20 keystream derived from a BLAKE3-of-
  ML-KEM-768-SS seed; attacker without `mlkem_ss` cannot decrypt.
- **Integrity** — Poly1305 tag binds the whole ciphertext and the
  nonce; a flipped bit in the frame body fails `open`.
- **Replay rejection** — the nonce counter is monotonic and single-use;
  a replayed frame carries the same nonce and the receiver's `open`
  succeeds, BUT the application-level record ordering is a
  responsibility of the upcoming M5 wrapper (M4 is a wire primitive;
  it is a protocol primitive to detect ordering, not a cryptographic
  one).  A duplicate frame delivered twice decrypts to the same
  record both times.
- **Forward-secrecy posture** — matches the M2 handshake's
  mlkem-only split: a leak of `mlkem_ss` recovers every past session
  key (and every record ever sealed under this connection) because
  the derivation is deterministic from `mlkem_ss` alone.  The M2-
  split (hybrid X25519) adds forward secrecy once the X25519 FFI
  thunk ships.

### Known-weak properties

- **No AAD today.**  A transport that silently re-slots a frame from
  `conn_id=A` into `conn_id=B` would, before `open`, see a correct
  magic/len/geometry.  After `open` the record decrypts correctly
  because the key derivation keys only on `mlkem_ss` and not on
  `conn_id`.  M5 fills the AAD with `(fed_id, invoker_cid, conn_id)`
  to close this.
- **No session rekey.**  A long-lived connection with a very bursty
  pattern can reach `2^64` records in principle; the counter
  exhausts and the sender stops.  Rekey is an M5+ concern.
- **No wire-level fragmentation.**  `RRW_RECORD_MAX = 1024` fits in a
  single Ethernet frame; longer records are not supported.  The
  stdout_records substrate (R135.M4) caps records at `SR_RECORD_
  PAYLOAD_MAX = 120`, so M4's ceiling is comfortably above the
  immediate consumer's.

## 8. Fingerprint allowlist

Both `RRW SEND OK` and `RRW RECV OK` are allowlisted in
`tools/verify-fingerprint-coverage.sh` with the retirement note "lands
alongside R137.M5 asserting smoke-mode goldens".  At M4 no production
caller reaches `_rrw_send_record` / `_rrw_recv_frame`: the TCP wire
transport that would deposit RX frames and transmit TX frames is
deferred to R137.M5, and no `KIND_REMOTE_SHELL` cap-invoke surface
mints the capability a user task would hold to drive sends.

## 9. Boot wiring

None.  Every .bss region used by this layer is zero-init:

- `_rrw_tx_frames` / `_rrw_rx_frames` — the slot contents.
- `_rrw_tx_frame_lens` / `_rrw_rx_frame_lens` — the slot witnesses.
- `_rrw_stats` — the observability counters.
- `_rrw_sk_scratch` / `_rrw_nonce_scratch` / `_rrw_aead_scratch` /
  `_rrw_derive_input` / `_rrw_derive_output` / `_rrw_written` —
  per-call scratch regions, overwritten before each use.

The nonce counter at `row[+224..+232]` rides the sibling
`_remote_shell_pool` which is already .bss-zero-init; a fresh
`_remote_shell_accept` lands a row with counter = 0.

## 10. Acceptance (deferred to R137.M5)

- A pair of VM-local kernels completes the M2 handshake.
- Peer A calls `_rrw_send_record(conn_id, &record, L)`; the TX slot
  holds a well-formed 36+L-byte frame and `_rrw_tx_frame_lens[conn_id]
  = 36+L`.
- A test harness transfers the TX slot bytes into peer B's RX slot
  and calls `_rrw_rx_stage(conn_id_B, 36+L)`.
- Peer B calls `_rrw_recv_frame(conn_id_B, out, L)`; the returned
  packed u64 is `(L << 32) | 0` and `out[0..L]` byte-equals peer A's
  input `record`.
- A tampered byte in the sealed region flips the recv-side status to
  `RRW_ERR_AEAD_FAIL` with `bytes_decrypted = 0`.
- A send that exhausts the nonce counter returns
  `RRW_ERR_NONCE_EXHAUSTED` and leaves the TX slot untouched.
