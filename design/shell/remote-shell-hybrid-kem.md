# Remote-shell hybrid-KEM handshake (R137.M2)

**Issue:** paideia-os#2634 (umbrella #2482).
**Milestone:** R137.M2 — "Hybrid-KEM handshake".
**Scope posture:** **SPLIT.** M2 lands ML-KEM-768-only (reduced security:
PQ-safe but **not** forward-secure in the strong hybrid sense); M3-split
widens to X25519 + ML-KEM-768 once the X25519 FFI thunk lands in paideia-as.
**Follow-up:** `paideia-as#<X25519-FFI>` (file at submission; must land
before M3-split can proceed).

**Related:** `design/shell/remote-shell-daemon.md` (R137.M1 substrate);
`src/kernel/core/svc/remote_shell.pdx` (M1 state machine +
`kem_session_slot` reserved field).

---

## 1  Why hybrid? Why now?

paideia-os is a 2026-era microkernel that will outlive both
Shor-vulnerable classical cryptography (X25519 is a Diffie–Hellman
over the curve25519 group; it falls to a cryptographically-relevant
quantum computer running Shor's algorithm) **and** the current
confidence that FIPS-203 ML-KEM-768 is free of as-yet-unknown
classical attacks (lattice cryptanalysis is an active research field;
the standard is less than two years old). A **hybrid** KEM — combine
one classical primitive and one post-quantum primitive, derive the
session key from BOTH shared secrets — survives either leg being
individually broken: an attacker must break X25519 **and** ML-KEM-768
to recover a session key.

This is the standard IETF posture for 2025+ TLS and SSH: see
`draft-ietf-tls-hybrid-design` (ML-KEM-768 + X25519 for TLS 1.3) and
`draft-kampanakis-curdle-ssh-pq-ke` (SSH PQ hybrid). paideia-os
follows the same shape rather than inventing a new one.

### Why NOT just ML-KEM-768?

ML-KEM-768 (FIPS 203, finalised August 2024) provides IND-CCA2 security
assuming the Module-LWE problem is hard. Lattice cryptanalysis is a
younger research field than elliptic-curve cryptanalysis (Shor
notwithstanding) and the standard is new; a single-primitive
dependency on ML-KEM would be a cryptographic monoculture risk.
Hybrid is cheap and the belt-and-braces is worth the ~2 ms key-schedule
cost.

### Why NOT just X25519?

X25519 is efficient and well-studied, but a sufficiently advanced
quantum computer breaks it. paideia-os commits to being viable for
~20+ years of operation (per `design/00-feature-inventory.md`); a
non-trivial fraction of that lifetime is after plausible CRQC
timelines. A classical-only KEM is a known-wrong decision for a
long-lived OS.

---

## 2  Primitive audit — what's shippable in paideia-as today?

The kernel resolves extern-C crypto thunks against
`libpaideia_satellite_runtime.a` on the kernel link line (precedent:
`inode.pdx` L170; `schema_registry.pdx` L277; `kind_firmware_blob.pdx`
L477; `sys_dek_apply_body.pdx` L568). As of 2026-10-14:

| Primitive                           | FFI symbol                                 | Status |
|-------------------------------------|--------------------------------------------|--------|
| BLAKE3 hash (keyed + unkeyed)       | `paideia_crypto_blake3_hash{,_keyed}`      | **Available** (`paideia-as-crypto/src/blake3.rs`) |
| ML-KEM-768 KeyGen                   | `paideia_crypto_ml_kem_768_keygen`         | **Available** (`paideia-as-crypto/src/ffi/ml_kem_768.rs`) |
| ML-KEM-768 Encaps                   | `paideia_crypto_ml_kem_768_encaps`         | **Available** |
| ML-KEM-768 Decaps                   | `paideia_crypto_ml_kem_768_decaps`         | **Available** |
| ChaCha20-Poly1305 seal/open         | `paideia_crypto_chacha20_poly1305_{seal,open}` | **Available** |
| HKDF-SHA256                         | `paideia_crypto_hkdf_sha256`               | **Available** |
| Ed25519 verify                      | `paideia_crypto_ed25519_verify`            | **Available** |
| **X25519 scalarmult / keygen**      | **(none)**                                 | **GAP — Rust-side only** |
| CSPRNG / hardware RNG               | (none — Rust internal `rng::HardwareRng`)  | **Gap — not exposed** |

### X25519 gap

paideia-as **does** implement X25519 in Rust
(`paideia-as-crypto/src/curve/x25519.rs` — `x25519_scalarmult`,
`x25519_public_from_secret`, RFC 7748 conformant, ACVP-validated), but
does **not** expose it over the extern-C FFI. The hybrid-KEM
handshake requires calling X25519 from kernel `.pdx` code, which
means the Rust impl must be reachable via a `paideia_crypto_*`
symbol in `libpaideia_satellite_runtime.a`.

**M2 cannot land the full hybrid handshake.** Hence SPLIT.

### CSPRNG gap

ML-KEM-768 KeyGen requires two 32-byte seeds (`d`, `z`); Encaps
requires one (`m`). The paideia-as `rng::HardwareRng` wraps RDSEED
with RDRAND fallback but is not exposed over FFI. For M2 the handshake
API accepts **caller-provided seeds** — pushing the entropy decision
up to the wire-protocol layer (R137.M3), which can either (a) sample
`rdrand`/`rdseed` directly in `.pdx` via inline asm, or (b) consume
R137.M3's own randomness source (likely a per-session nonce schedule
seeded at TCP accept). This is NOT the final shape — M3 will own the
entropy decision — but it keeps M2's crypto module cleanly testable
with ACVP vectors.

**Follow-up ticket:** `paideia-os#<CSPRNG-FFI>` (file after this
lands) — expose a `paideia_crypto_rng_fill(out_ptr, len)` thunk over
RDSEED (fallback RDRAND).

---

## 3  Full handshake flow (M3-split target shape)

Server identity: hosts an ML-KEM-768 **long-term** keypair
`(ek_long, dk_long)` and an X25519 **long-term** keypair
`(xpub_long, xpriv_long)`. Client knows the server's two long-term
public keys out-of-band (R137.M4 pins them to a KIND_FINGERPRINT cap).

```
                                        Client                           Server
                                        ------                           ------
  Pre: knows (xpub_srv, ek_srv_long)
       from a prior pin.

  (1) Client ephemeral keygen
      Generate ephemeral x25519:
        (xpriv_eph, xpub_eph) = x25519_keygen(rand(32))
      Generate ML-KEM-768 encaps:
        seed_m = rand(32)
        (ct, mlkem_ss) = ml_kem_768_encaps(ek_srv_long, seed_m)
      Compute X25519 shared:
        x25519_ss = x25519_scalarmult(xpriv_eph, xpub_srv)
      Store (x25519_ss, mlkem_ss) in handshake slot.
      Send to server: (xpub_eph, ct).           ----- ClientHello ----->
                                                              Receive (xpub_eph, ct).

                                                      (2) Server derives
                                                          mlkem_ss = ml_kem_768_decaps(
                                                              dk_srv_long, ct)
                                                          x25519_ss = x25519_scalarmult(
                                                              xpriv_srv, xpub_eph)
                                                          Store (x25519_ss, mlkem_ss)
                                                          in its handshake slot.

                                                                                 <----- ServerAck ------
      (Optional ServerAck is a one-byte "I decaps'd successfully"
       marker; the client cannot send encrypted data until it knows the
       server has derived the same ss.)

  (3) BOTH sides derive session key
      session_key = BLAKE3(
          "paideia-rsh-v1" ||
          x25519_ss  ||    // 32 B
          mlkem_ss   )     // 32 B
      -> 32 B session key.
      Transition HANDSHAKE -> ESTABLISHED.

  (4) ChaCha20-Poly1305 session wire (R137.M3)
      Both sides seal/open their rx/tx frames with session_key.
```

**Why BLAKE3 and not HKDF?** HKDF-SHA256 is the TLS 1.3 default; it
has an Extract step (good for low-entropy IKMs) and an Expand step
(good for N parallel sub-keys). Our IKM here is already 64 bytes of
high-entropy shared secrets, and we need exactly one 32-byte session
key. BLAKE3 is a wide-pipe hash that behaves identically to HKDF's
Extract when the IKM is already uniform; the construction
`BLAKE3(context_string || ikm)` is cryptographically sound
(domain-separated KDF; see BLAKE3 §5 "deriving keys"). We prefer it
over HKDF for the simpler surface and the ~3× speed advantage. If
R137.M3 needs multiple sub-keys (rx-key and tx-key independently),
we switch to BLAKE3's keyed-hash mode (`paideia_crypto_blake3_hash_keyed`
with the session key as key).

**Why the `"paideia-rsh-v1"` domain separator?** Prevents cross-protocol
re-use: if a future paideia-os subsystem derives a key from the SAME
`(x25519_ss, mlkem_ss)` pair, it uses a different context string, and
the derived keys are cryptographically independent. The `-v1` suffix
reserves a cheap migration path if the derivation changes.

---

## 4  M2 reduced-security shape (SPLIT delivery)

The M2 landing swaps step (1)'s X25519 computation out and derives
the session key from the ML-KEM-only shared secret:

```
session_key = BLAKE3(
    "paideia-rsh-v1-mlkem-only" ||
    mlkem_ss)                      // 32 B
-> 32 B session key.
```

**Security posture (M2 reduced):** The session key is PQ-safe (an
attacker without `dk_srv_long` cannot derive it even with a CRQC).
The session key is **NOT forward-secure in the hybrid sense** — if
`dk_srv_long` later leaks, every past session can be recomputed from
the recorded ciphertexts. M3-split restores forward-secrecy via the
ephemeral X25519 (which provides perfect forward secrecy against
classical adversaries; the ephemeral private is deleted after
derivation).

The domain-separator differs (`paideia-rsh-v1-mlkem-only` vs the
future `paideia-rsh-v1`) so an M3-split rollout cannot accidentally
mistake an M2-era session key for a hybrid one. A caller that
derives at the wrong altitude gets uncoordinated session keys, which
breaks the AEAD and surfaces as a decrypt failure (fail-closed).

---

## 5  Public API (M2 SPLIT shape)

Four functions, all in `src/kernel/core/svc/remote_shell_handshake.pdx`
under `module RemoteShellHandshake`:

```
_rsh_server_keygen(conn_id, seed_d_32B, seed_z_32B, out_ek_1184B)
                                                             -> errno
  Server-side bringup: run ML-KEM-768 KeyGen with caller-supplied
  seeds; stash dk (2400B) in the handshake scratch region; set the
  connection's kem_session_slot = 1 (bound sentinel); transition
  INIT -> HANDSHAKE; write the 1184B public key to the caller's
  buffer (for transmission to the client).

_rsh_init_client(conn_id, server_ek_1184B, seed_m_32B, out_ct_1088B)
                                                             -> errno
  Client-side bringup: run ML-KEM-768 Encaps against the server's
  ek with the caller-supplied seed_m; stash the 32B shared secret
  in the handshake scratch region; set kem_session_slot = 1;
  transition INIT -> HANDSHAKE; write the 1088B ciphertext to the
  caller's buffer (for transmission to the server).

_rsh_accept_server(conn_id, client_ct_1088B)                 -> errno
  Server-side finalise: run ML-KEM-768 Decaps using the dk stashed
  by _rsh_server_keygen; stash the 32B shared secret; state is
  unchanged (still HANDSHAKE; derive_session_key does the final
  transition).

_rsh_derive_session_key(conn_id, out_session_key_32B)        -> errno
  Final step on both sides: BLAKE3("paideia-rsh-v1-mlkem-only" ||
  mlkem_ss) -> 32B session key; write to caller's buffer; transition
  HANDSHAKE -> ESTABLISHED.
```

M3-split will widen `_rsh_init_client` / `_rsh_accept_server` with
X25519 pointers and change `_rsh_derive_session_key`'s domain
separator; the state transitions and the four-function partition are
stable.

### Argument contract

All pointer arguments are kernel-mode, 8-byte-aligned, point to the
exact byte count listed in the signature, and are writable iff the
`out_*` prefix says so. The functions do no user-space pointer
validation at M2 — the direct-call API is kernel-only until R137.M4
mints KIND_REMOTE_SHELL caps with a ring-3 surface. R137.M4 will add
the `user_ptr_ok` + `user_read_bytes_via_walk` wrapper envelope.

### Return codes

```
RSH_OK            = 0           (success)
RSH_ERR_BAD_CONN  = 0x1D01      (REUSE of RS_ERR_BAD_ID — same conn_id
                                 validation path as the M1 daemon)
RSH_ERR_CRYPTO    = 0x1D10      (ML-KEM or BLAKE3 call returned non-zero)
RSH_ERR_STATE     = 0x1D11      (connection is not in the state this
                                 operation requires — e.g.
                                 _rsh_derive_session_key on an INIT
                                 or CLOSED row)
```

All fit imm32 with bit 31 clear so `mov rax, imm32` emits the 7-byte
zero-extending form (never `and r11, imm64`). Band `0x1D10..0x1D1F`
reserved for R137.M2+ handshake-side codes; band `0x1D00..0x1D0F`
remains the daemon's (per `remote_shell.pdx` §3 audit).

---

## 6  Row-slot layout — where the per-connection crypto state lives

The M1 daemon reserved a 128-byte slack region at `[conn_row+128]`
for exactly this purpose. M2 lays it out as:

```
  [+128..+160]  x25519_priv (32 B)   -- all zeros at M2; populated at
                                        M3-split
  [+160..+192]  x25519_pub  (32 B)   -- all zeros at M2
  [+192..+224]  mlkem_ss    (32 B)   -- ML-KEM shared secret (written
                                        by encaps on client side,
                                        by decaps on server side)
  [+224..+256]  slack       (32 B)   -- reserved for M3-split
                                        (likely: x25519_shared 32 B)
```

ML-KEM-768's 2400-byte decapsulation key does NOT fit in the row's
128 B slack. It lives in a separate `.bss` region
`_rsh_hs_scratch[conn_id * 4096]`, laid out as:

```
  _rsh_hs_scratch @align(4096) : [u8; 4 * 4096]        (16 KiB total)

  Per-conn 4096 B page:
    [+0..+2400]      dk (2400 B)   -- server dk; zero on client-only rows
    [+2400..+4096]   slack         -- reserved for future ek caching,
                                      transcript hash, etc.
```

The 4096-B stride is a power of two (`shl rax, 12`) — no `imul r, imm`
encoder gap (feedback_pdx_encoder_pitfalls). The scratch is aligned
to a page so a future reader-view (R137.M3+) can map it with a
single PTE if needed.

### kem_session_slot sentinel

The M1 daemon's `[conn_row+16]` kem_session_slot field is an opaque
u64 to the daemon layer. M2 uses it as a **boundness sentinel**:

- `0` = handshake slot not bound (M1 _accept state)
- `1` = handshake slot bound; crypto state at
  `_rsh_hs_scratch[conn_id * 4096]` and `[conn_row+128..+256]` is
  live.

M3-split may upgrade to a richer slot id (e.g., per-conn transcript
hash fingerprint) if we need to key an audit trail off it; the
sentinel-vs-rich-id upgrade is transparent to M1 (which never
inspects the field).

---

## 7  State transitions

```
                    _rsh_server_keygen
                    _rsh_init_client
     RS_STATE_INIT -----------------------> RS_STATE_HANDSHAKE
                                                   |
                              _rsh_accept_server   | (server only;
                              (no state change)    |  no-op on state)
                                                   v
                                            RS_STATE_HANDSHAKE
                                                   |
                              _rsh_derive_session_key
                                                   |
                                                   v
                                        RS_STATE_ESTABLISHED
```

Every public M2 handshake entry calls `_remote_shell_set_state`
to drive the transition. The M1 daemon's `_remote_shell_set_state`
is PERMISSIVE (accepts any valid state in [0, 5)); M2 enforces the
STRICT matrix at this layer by refusing `RSH_ERR_STATE` when the
pre-call state is wrong.

Pre-condition checks per function:

| Function                 | Required pre-state | Post-state   |
|--------------------------|--------------------|--------------|
| `_rsh_server_keygen`     | INIT               | HANDSHAKE    |
| `_rsh_init_client`       | INIT               | HANDSHAKE    |
| `_rsh_accept_server`     | HANDSHAKE          | HANDSHAKE    |
| `_rsh_derive_session_key`| HANDSHAKE          | ESTABLISHED  |

A caller that attempts to re-run `_rsh_server_keygen` on an already
HANDSHAKE row gets `RSH_ERR_STATE` — this is the daemon's defence
against a retry-replay attack where a torn-down handshake retains
some state (defence-in-depth; _remote_shell_close zeros the critical
fields anyway).

---

## 8  Security posture (M2)

### What M2 protects

**Confidentiality against classical passive adversary:** YES. An
attacker who sniffs the wire and never obtains `dk_srv_long` cannot
derive the session key (reduces to the IND-CCA2 security of
ML-KEM-768).

**Confidentiality against classical active adversary:** YES, provided
the client already knows the server's `ek_srv_long` (R137.M4 pins
this to a KIND_FINGERPRINT cap). M2 itself does NOT authenticate the
server's ek; a MITM that substitutes its own `ek_mitm` on the first
flow produces a session key the MITM knows and the server does not.
The authentication layer lands at R137.M4; M2's threat model
explicitly excludes active MITM.

**Confidentiality against future CRQC:** YES. ML-KEM-768 is
post-quantum IND-CCA2 under the Module-LWE assumption.

### What M2 does NOT protect

**Forward secrecy (classical sense):** NO. A later leak of
`dk_srv_long` lets the attacker recomputed every past session key
from recorded ciphertexts. This is the headline reason M2 is a
reduced-security SPLIT: the ephemeral X25519 in M3-split restores
forward secrecy.

**Monoculture risk:** NOT MITIGATED at M2. The entire session
depends on ML-KEM-768. If a future classical attack on Module-LWE
reduces its security, every M2-era session is retroactively broken.
M3-split's hybrid construction mitigates this.

**MITM / server authentication:** NOT PROTECTED at M2. See above —
R137.M4 lands this.

### Documented in-code

Every M2 handshake-path klog line emits `suite=mlkem-only` (not
`suite=hybrid`) so a wire-tap observer can tell at a glance that
this session is reduced-security. R137.M4's acceptance test will
grep the fingerprint for `suite=` and refuse any session that is
not `suite=hybrid` by that milestone.

---

## 9  Encoder discipline

Standard paideia-as pitfall posture (reserved-labels, no `imul r,imm`,
no `and r11, imm64` with bit-31-set imms, no `test r,r`, no
`add reg,[mem]`, no `mov_bzx`/`mov_wzx`, module basename exact match
to file basename):

- Module basename: `RemoteShellHandshake` ↔ file basename
  `remote_shell_handshake.pdx` (ddc requires exact match per
  feedback_pdx_encoder_pitfalls).
- Label prefix: `rsh_` (distinct from `rs_` — the M1 daemon's prefix
  — and from `ss_` / `js_` / `cmnt_` / `sh_` / `sj_`).
- Row-base stride 256 for the daemon rows (`shl rax, 8`); scratch
  stride 4096 for the handshake pages (`shl rax, 12`). Both are
  power-of-two; no `imul r, imm`.
- Error codes `0x1D10` / `0x1D11` fit imm32 with bit 31 clear.
  `0x1D01` (reused) is likewise clean.
- Fingerprint tags: lengths carry the +1 NUL (`[u8; N]` with
  N = `strlen() + 1`).

### Nested-call alignment

Every public entry is a non-leaf (nested extern-C crypto call). The
register plan preserves SysV `rsp % 16 == 0` at every nested call:

- `_rsh_server_keygen`: 4 callee-save pushes (rbx, r12, r13, r14) +
  `sub rsp, 8`; from entry `rsp%16==8` → `+32` → `%16==0` → `+8` →
  `%16==8`... wait, that's wrong. Let me recompute.
  Entry `rsp%16==8`. 4 pushes = +32 → `%16==8+32=40 mod 16 = 8`.
  Need `sub rsp, 8` to go to `0` for the call. OK: 4 pushes +
  `sub rsp, 8` → `rsp%16==0` at nested calls. 7 callee-save pushes
  would give `%16==1` → wrong; 5 pushes → `%16==9` → wrong. 4 or 6
  pushes work with `sub rsp, 8` padding.
- `_rsh_init_client`: same 4-push + 8-byte-pad shape.
- `_rsh_accept_server`: 2 callee-save pushes (rbx, r12) +
  `sub rsp, 8`; entry `%16==8` → `+16` → `%16==8` → `+8` → `%16==0`.
- `_rsh_derive_session_key`: 2 callee-save pushes + `sub rsp, 8`
  (same as accept).

All nested calls land at `rsp%16==0`. The epilogues `add rsp, 8`
before the `pop`s and `ret`.

---

## 10  M2 acceptance

The M2 landing proves:

1. The four public entries compile under paideia-as.
2. Each entry's state-transition guard is honoured: fingerprint
   `RSH STATE OK pre=0x<hex> post=0x<hex>` emits exactly once per
   successful transition; fingerprint `RSH STATE REJ errno=0x1D11`
   emits on pre-state mismatch.
3. A smoke witness that chains `_rsh_server_keygen` →
   `_rsh_init_client` → `_rsh_accept_server` →
   `_rsh_derive_session_key` (twice, once per side) produces
   byte-identical session keys at both ends.
4. The ACVP tcId-26 KeyGen vector reproduces through the FFI thunk
   (the paideia-as side's own test re-runs here as a kernel
   smoke) — this proves the kernel link line resolves
   `paideia_crypto_ml_kem_768_*` correctly.
5. The AEAD wire layer (R137.M3) does NOT depend on this file's
   internal state — the only coupling is the 32-byte session key
   via `_rsh_derive_session_key`.

**Not in M2:** no X25519 call site; no RNG call site (seeds are
caller-supplied); no KIND_REMOTE_SHELL cap arm; no AEAD wire; no
authentication.

**Issue 2634 closes** on M2 landing. M3-split spawns a new issue
(`paideia-os#<R137.M2-split>`) tracking the hybrid widening.

---

## 11  Follow-up tickets (filed with M2 landing)

- `paideia-as#<X25519-FFI>` — Expose
  `paideia_crypto_x25519_scalarmult(sk, pk, out) -> i64` and
  `paideia_crypto_x25519_public_from_secret(sk, out) -> i64` thunks
  over the existing Rust `curve::x25519` module. Pattern mirrors
  the ML-KEM thunk layout (`paideia-as-crypto/src/ffi/ml_kem_768.rs`).
  Required for R137.M2-split.
- `paideia-os#<CSPRNG-FFI>` — Expose
  `paideia_crypto_rng_fill(out_ptr, len) -> i64` over the paideia-as
  `rng::HardwareRng` (RDSEED with RDRAND fallback). Required so the
  kernel can sample entropy inside the handshake rather than relying
  on caller-supplied seeds. Required for R137.M3+.
- `paideia-os#<R137.M2-split>` — Widen `_rsh_init_client` and
  `_rsh_accept_server` with X25519 pointers; swap the derivation
  domain separator to `"paideia-rsh-v1"`. Blocked on the two
  tickets above.

---

## 12  References

- NIST FIPS 203 "Module-Lattice-Based Key-Encapsulation Mechanism
  Standard" (ML-KEM-512/768/1024), August 2024.
- Bernstein, D. J., "Curve25519: new Diffie-Hellman speed records",
  PKC 2006.
- RFC 7748 "Elliptic Curves for Security" (X25519 as the key-exchange
  primitive on curve25519), January 2016.
- IETF draft `draft-ietf-tls-hybrid-design` (hybrid KEM for TLS 1.3).
- IETF draft `draft-kampanakis-curdle-ssh-pq-ke` (hybrid PQ for SSH).
- O'Connor, J. et al., "BLAKE3: one function, fast everywhere", 2020.
  §5 "Deriving keys" documents the KDF construction we use.
- Paideia-OS internal: `design/security/pq-trust-root.md`
  (overarching PQ posture); `design/shell/remote-shell-daemon.md`
  (R137.M1 substrate); `design/terminal/semantic-shell-materialization-plan.md`
  §4 R137 row (umbrella).
