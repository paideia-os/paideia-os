# svc.federation-discovery — R137.M3

**Status:** landed (R137.M3, Wave UMB-W21, paideia-os#2635)
**File:** `src/kernel/core/svc/federation_discovery.pdx`
**Depends on:** `klog_s1` / `klog_s1_x1`, `rdtsc`, `SUBSYS_NET_`
**Depended on by:** R137.M4 (cross-host record wire), R137.M5 (KIND_FEDERATION cap-invoke + `fd_authorise_handshake`)

---

## 1 Why a federation?

R137 is the umbrella for **cross-host pipeline transport** — the paideia-os answer to "a shell on this box takes input from a shell on another box, with no POSIX inheritance in the authentication path." The hybrid-KEM handshake landed in R137.M2 provides the cryptographic gate: Encaps/Decaps + BLAKE3 derive a per-connection session key against the peer's long-term ML-KEM-768 ek.

What the handshake does **not** do is answer the question *should this host be allowed to talk to that one in the first place?* Trust in paideia-os is capability-named — but the ML-KEM-768 ek that identifies a remote peer is a 1 184-byte blob, not a cap, and the kernel has no way to say "I was taught about this peer; I was not taught about that one" without a dedicated registry.

**A federation is a NAMED TRUST SET.** It is the opaque trust-boundary over which a handshake is allowed to proceed. Mechanically, a federation record pairs a `fed_id` (any nonzero u32 the caller picks) with up to eight `(remote_ip, remote_port, name)` tuples. A capability minted against a federation (R137.M5 lands this via `KIND_FEDERATION`) authorises the invoker to:

- enumerate the federation's peers (`_fd_peer_list` / `_fd_peer_lookup`),
- extend the federation with a new peer (`_fd_peer_register`),
- and (R137.M5) authorise a handshake against a specific peer in that federation (`fd_authorise_handshake`).

A **federation is not a routing table**. It does not know which network the peer is reachable on, which NIC to send on, or how to resolve the IP. Those are the wire framer's (R137.M4) problem. The registry's job is to say *this (ip, port) is in-scope for this federation.*

**A federation is not a group.** It is not a membership list. The invariant is "handshake proceeds only against a registered peer"; the invariant is **not** "members of this federation can introspect each other." Introspection is a separate right the cap minter grants or withholds.

---

## 2 Service identity

| field                              | value                                                     |
|------------------------------------|-----------------------------------------------------------|
| Service name                       | *(none at M3; direct-call API only)*                      |
| Endpoint id                        | *(none at M3; reserved for R137.M5)*                      |
| Broker row                         | *(none at M3; reserved for R137.M5)*                      |
| klog subsystem                     | `SUBSYS_NET_` (`net`)                                     |
| Return-code band                   | `FD_OK = 0`, `FD_ERR_* = 0x2100..0x2103`                  |

The lack of a broker row at M3 is deliberate. The registry is a data substrate; its authority surface (who may `fd_federation_register`?) belongs to the KIND_FEDERATION cap-minter that lands with R137.M5. Shipping a broker row now would mean exposing registration to any in-kernel caller that can `svc_lookup`, which is strictly weaker than the cap gate we want.

---

## 3 Row layouts — two pools, 64 bytes per row

### 3.1 Federation record (64 B)

```
fed_id       : u32   -- caller-chosen identifier (nonzero; 0 is FREE)
flags        : u32   -- reserved (R137.M5 bit 0 = "cap minted")
peer_count   : u32   -- # registered peers in this federation (< 8)
reserved     : u32   -- reserved
name         : [u8; 48]  -- display name (47 usable + NUL)
```

Packed storage (all u64 lanes):

| offset | u64 word     | contents                                                             |
|--------|--------------|----------------------------------------------------------------------|
| `+0`   | `fed_hdr0`   | `fed_id` (low 32) \| `flags` (high 32)                               |
| `+8`   | `fed_hdr1`   | `peer_count` (low 32) \| `reserved` (high 32)                        |
| `+16`  | `name[ 0.. 7]` | 8 bytes of display name                                            |
| `+24`  | `name[ 8..15]` | 8 bytes                                                            |
| `+32`  | `name[16..23]` | 8 bytes                                                            |
| `+40`  | `name[24..31]` | 8 bytes                                                            |
| `+48`  | `name[32..39]` | 8 bytes                                                            |
| `+56`  | `name[40..47]` | 8 bytes (last byte NUL)                                            |

`fed_id == 0` at `+0` is the **FREE sentinel**: `.bss` zero-init gives us FREE at boot without an explicit priming pass. Observable-last write ordering writes `fed_hdr0` **last** at registration so a concurrent scanner either sees FREE or fully-initialised.

### 3.2 Peer record (64 B)

```
fed_id          : u32   -- federation this peer belongs to (0 = FREE)
remote_ip       : u32   -- IPv4 address of peer host
remote_port     : u16   -- TCP port on peer host
status          : u16   -- 0=UNKNOWN, 1=REACHABLE, 2=UNREACHABLE
reserved        : u32   -- reserved
last_seen_tsc   : u64   -- rdtsc at last successful contact
name            : [u8; 40]  -- display name (39 usable + NUL)
```

**Deviation from directive:** the task directive specifies `name: [u8; 48]`, but the full field list sums to 72 B (not 64 B). The pragmatic resolution is to shrink the peer name to 40 B (39 usable + NUL) which preserves every other field and keeps the "64 B per row, power-of-two stride" invariant. Federation names stay at 48 B because the federation record's other fields leave exactly 48 B of row budget.

Packed storage:

| offset | u64 word       | contents                                                        |
|--------|----------------|-----------------------------------------------------------------|
| `+0`   | `peer_hdr0`    | `fed_id` (low 32) \| `remote_ip` (high 32)                      |
| `+8`   | `peer_hdr1`    | `remote_port` (bits 0..15) \| `status` (bits 16..31) \| reserved (bits 32..63) |
| `+16`  | `last_seen_tsc`| rdtsc sample at register time                                   |
| `+24`  | `name[ 0.. 7]` | 8 bytes of display name                                         |
| `+32`  | `name[ 8..15]` | 8 bytes                                                         |
| `+40`  | `name[16..23]` | 8 bytes                                                         |
| `+48`  | `name[24..31]` | 8 bytes                                                         |
| `+56`  | `name[32..39]` | 8 bytes (last byte NUL)                                         |

`fed_id == 0` at `+0` is the **FREE sentinel** for a peer row. `peer_hdr0` is written **last** at registration (same observable-last discipline as the federation record).

### 3.3 Pool geometry

| pool                   | rows | row size | total | alignment |
|------------------------|------|----------|-------|-----------|
| `_fd_federation_pool`  | 8    | 64 B     | 512 B | `@align(64)` (cache line) |
| `_fd_peer_pool`        | 64   | 64 B     | 4 KiB | `@align(4096)` (page frame) |

Peer rows are **slotted** by federation: the row index for the `k`-th peer of federation at slot `s` is `s * 8 + k`. This organisation keeps:

- `peer_count` on the federation record as the **next-free index** in that federation's 8-slot range,
- `peer_lookup(fed_id, index)` as a single find-by-fed-id scan + address arithmetic (no secondary peer scan), and
- deletion of a federation (R137.M5) as a tight zero of that federation's 8-slot range.

Row stride 64 is a power of two (`shl rax, 6`); the fed_slot → peer row base compute is `shl 9` (fed_slot × 512 = 8 × 64).

---

## 4 Public API

### 4.1 `_fd_init() -> errno`

Boot hook. Emits `FED_DISC INIT OK` and bumps `FD_ST_INIT_OK`. Returns `FD_OK` unconditionally.

`_fd_init` is lean because `.bss` zero-init puts every federation and peer slot's `fed_id` at 0 (the FREE sentinel), so no runtime priming is required. The function exists to:

1. emit a boot fingerprint (same posture as every other `svc.*` daemon),
2. provide a kernel_main.pdx hook point that R137.M5 can thicken (`endpoint_alloc_at` + `svc_register` + `kind_register(KIND_FEDERATION)`) without a kernel_main revision.

### 4.2 `_fd_federation_register(fed_id, name_ptr, name_len) -> errno`

Mint a federation row (or idempotent re-register).

- **`fed_id`** must be nonzero (`FD_ERR_BAD_FED` if 0).
- **Idempotent re-register:** if a federation with the same `fed_id` is already registered, returns `FD_OK` without updating the name or peer_count. Name updates would race the peer_count invariant with cross-cap registration ordering; R137.M5 may lift to a name-update API if the user story demands.
- **Name clamp:** `name_len` is clamped to `FD_FED_NAME_MAX = 47`; a NUL is written at the clamped length.
- **Pool exhaustion:** returns `FD_ERR_FED_FULL` when all 8 federation rows are in use AND no existing row matches `fed_id`.

### 4.3 `_fd_peer_register(fed_id, remote_ip, remote_port, name_ptr, name_len) -> errno`

Append a peer to `fed_id`'s 8-slot peer range.

- Validates `fed_id != 0` and `fed_id` is registered (`FD_ERR_BAD_FED` otherwise).
- Checks `federation.peer_count < 8` (`FD_ERR_PEER_FULL` otherwise).
- Writes the peer row at index `fed_slot * 8 + peer_count`:
  - `peer_hdr1 = remote_port | (FD_STATUS_UNKNOWN << 16) | 0` (status = UNKNOWN at register time; reachability probing is a separate R137.M5 concern).
  - `last_seen_tsc = rdtsc`.
  - `name` byte-copied up to `min(name_len, 39)` with trailing NUL.
  - `peer_hdr0 = fed_id | (remote_ip << 32)` is written **last** (observable-last).
- Increments the federation's `peer_count` (preserves `reserved` high 32 via shift-trick).

### 4.4 `_fd_peer_lookup(fed_id, index) -> packed u64`

Returns status + endpoint of the `index`-th peer in `fed_id`'s peer list, as a packed u64.

**Success encoding** (packed u64):

| bits    | field       |
|---------|-------------|
| `0..15` | `remote_port` (u16) |
| `16..47`| `remote_ip` (u32)   |
| `48..63`| `status` (u16)      |

**Error encoding:** raw errno (`FD_ERR_*` in `[0x2100, 0x2104)`) returned directly.

**Collision caveat:** a peer with `status == UNKNOWN (0)`, `remote_ip == 0`, and `remote_port in {0x2100, 0x2101, 0x2102, 0x2103}` would collide with the four error codes. Mitigation: the registering caller is responsible for not registering `0.0.0.0:0x210N` peers. R137.M5 lifts to a dedicated out-parameter form once the KIND_FEDERATION cap-invoke surface is in place and the one-u64 constraint is lifted.

**Errors:**
- `FD_ERR_BAD_FED` — `fed_id` not registered (or `== 0`).
- `FD_ERR_BAD_INDEX` — `index >= federation.peer_count`.

### 4.5 `_fd_peer_list(fed_id, out_ptr, out_cap) -> packed u64`

Writes up to `min(peer_count, out_cap)` packed peer entries into `out_ptr`. Each entry is a packed u64 with the same shape as `_fd_peer_lookup`'s success return. `out_cap` is in units of u64 entries (callers that want all peers should pass `out_cap == 8`).

**Success encoding** (packed u64):

| bits    | field    |
|---------|----------|
| `0..15` | `FD_OK` (= 0) |
| `16..47`| number of entries written (u32; `<= 8`) |

**Error encoding:** raw errno.

**Errors:**
- `FD_ERR_BAD_FED` — `fed_id` not registered (or `== 0`).

---

## 5 Return code band

| name                | value    | meaning                                          |
|---------------------|----------|--------------------------------------------------|
| `FD_OK`             | `0`      | success                                          |
| `FD_ERR_FED_FULL`   | `0x2100` | all 8 federation rows in use                     |
| `FD_ERR_PEER_FULL`  | `0x2101` | federation's 8 peer slots in use                 |
| `FD_ERR_BAD_FED`    | `0x2102` | `fed_id == 0` or not registered                  |
| `FD_ERR_BAD_INDEX`  | `0x2103` | `index >= federation.peer_count`                 |

All fit `imm32` with bit 31 clear, so `mov rax, imm32` emits the 7-byte zero-extending form (never `and r11, imm64`). Band audit (2026-10-14): `grep -rnE '0x210[0-3]\b' src/kernel/` finds pre-existing hits in `src/kernel/core/syscall/handlers/sys_execve_shim.pdx` (`mov rax, 0x2100`), but those are user-aspace frame-layout **offset** constants (`data_base + 0x2100`), not return-code values; they never flow into an errno comparison and so do not collide with the `FD_ERR_*` band's semantic meaning. Clean band for return-code purposes; R137.M5+ may extend to `0x2104..0x210F` while retaining the first four as pinned.

---

## 6 Interaction with R137.M2 (handshake) and R137.M4 (wire)

### 6.1 R137.M2 handshake

At M3 the R137.M2 handshake entries (`_rsh_server_keygen`, `_rsh_init_client`, `_rsh_accept_server`, `_rsh_derive_session_key`) do **not** consult this registry. The handshake proceeds against any ek the caller provides, authorised only by the ML-KEM-768 Encaps/Decaps round-trip.

R137.M5 (KIND_FEDERATION cap-invoke) lifts this to:

1. **`fd_authorise_handshake(fed_id, remote_ip, remote_port) -> errno`** — scans the federation's 8 peer rows for a match on `(remote_ip, remote_port)`. Returns `FD_OK` on hit, `FD_ERR_BAD_FED` on miss (indistinguishable at the public API from "no such federation" — intentional: a caller that is told "no such peer in that federation" learns nothing about whether the peer or the federation is the problem).

2. **`_rsh_init_client` / `_rsh_server_keygen` precondition.** Both are widened with a `fed_id` argument and call `fd_authorise_handshake(fed_id, remote_ip, remote_port)` before starting the ML-KEM round-trip. A failure here folds to `RSH_ERR_FED` (a new return code added to the handshake band at `0x1D12`).

Until (1) and (2) land, the federation registry is a **record-only substrate**: callers may register federations and peers for observability, but no handshake path consults the registry. This matches the "data substrate before policy" shape of R135.M1 (jail_supervisor's row pool pre-dated the syscall gate in R135.M3) and R127.M1 (shell_session rows pre-dated the TTY line-discipline flip in R127.M3).

### 6.2 R137.M4 wire framer

R137.M4 (cross-host record wire) uses the peer registry to resolve a `(fed_id, peer_index)` tuple into the `(remote_ip, remote_port)` the framer connects to. The packed-u64 return of `_fd_peer_lookup` is deliberately **wire-ready**: the framer unpacks three fields in constant time without an intermediate structure.

The wire framer may also call `_fd_peer_list` to iterate the entire peer list on a federation-level broadcast (`forall peers P in fed_id: send record R`), but each per-peer send still goes through the handshake and so is still gated by the R137.M5 `fd_authorise_handshake` call.

---

## 7 Security posture

R137.M3's security posture is **"trust the caller for shape"**:

- **No validation of `remote_ip` / `remote_port`.** The caller (R137.M5 cap-minter or a direct-call bootstrap path) is responsible for only registering peers it has out-of-band reason to trust. Garbage input yields a garbage row that the handshake refuses the moment it tries Encaps against an ek it does not have.

- **No validation of `fed_id` identity beyond "nonzero and in-pool".** Any in-kernel caller that can reach `_fd_federation_register` can mint a federation under any (nonzero) `fed_id`. The authority model at M3 is **"whoever registered a federation first owns its peer list"**; the idempotent-re-register posture of `_fd_federation_register` is a convenience for repeated bootstrap, not a trust transfer.

  R137.M5 lifts this to "the KIND_FEDERATION cap controls which `fed_id` it may register against" when the cap-invoke dispatch surface lands. At that point the direct-call API becomes a kernel-internal implementation detail and the cap is the sole authority surface.

- **No authentication of a peer at register time.** `status` is `UNKNOWN` until R137.M5's probe path promotes it to `REACHABLE` or `UNREACHABLE`. The probe is a shell-visible operation (not an automatic kernel background task) because paideia-os does not run kernel threads for user-triggered network discovery.

- **No `cap_invoke` surface at M3.** The direct-call API is the only surface and is reachable only from inside the kernel. Ring-3 callers cannot reach it until R137.M5 lands KIND_FEDERATION and its `cap_invoke` arm.

The **ML-KEM-768 hybrid handshake (R137.M2)** remains the authoritative cryptographic gate between a connected TCP endpoint and a session key the remote peer can derive. The federation registry at M3 **records which endpoints are in-scope** for a handshake; it does not itself prevent an out-of-scope handshake from succeeding. That gating is R137.M5's job.

---

## 8 Fingerprint emissions

| fingerprint              | emitted by                     | retires when |
|--------------------------|--------------------------------|--------------|
| `FED_DISC INIT OK`       | `_fd_init`                     | R137.M5 asserting smoke-mode golden |
| `FED_DISC FED_REG OK`    | `_fd_federation_register`      | R137.M5 cap-invoke FED_REG op       |
| `FED_DISC FED_REG REJ`   | `_fd_federation_register`      | (opaque to coverage gate)           |
| `FED_DISC PEER_REG OK`   | `_fd_peer_register`            | R137.M5 cap-invoke PEER_REG op      |
| `FED_DISC PEER_REG REJ`  | `_fd_peer_register`            | (opaque)                            |
| `FED_DISC LOOKUP OK`     | `_fd_peer_lookup`              | R137.M4 wire framer smoke golden    |
| `FED_DISC LOOKUP REJ`    | `_fd_peer_lookup`              | (opaque)                            |
| `FED_DISC LIST OK`       | `_fd_peer_list`                | R137.M5 cap-invoke LIST op          |
| `FED_DISC LIST REJ`      | `_fd_peer_list`                | (opaque)                            |

At M3 only `FED_DISC INIT OK` fires on every boot (via `_fd_init` in the `svc.*` bringup cascade). The remaining OK tags are present as `.rodata` tag literals inside the direct-call API functions but no production path invokes them. All five OK tags are allowlisted in `tools/verify-fingerprint-coverage.sh` with retirement conditions tied to R137.M4 or R137.M5.

---

## 9 Encoder discipline

Labels are prefixed `fed_` (NOT `fd_`). The `fd_` prefix is heavily used in the file-descriptor subsystem (`fd_table.pdx`, `fd_inherit.pdx`, `fd_cloexec.pdx`); a label collision would silently cross-ref at link time.

Public symbols retain the task-directive `_fd_` prefix (unambiguous as function names because the fd-subsystem's symbols are `fd_*` without the leading underscore for internal helpers and `sys_*` for syscall entries).

Module basename `FederationDiscovery` matches file basename `federation_discovery.pdx`.

Encoder-pitfall posture (`feedback_pdx_encoder_pitfalls`):

- `cmp rN, 0` (never `test rN, rN`).
- `shl rN, 6` for row stride 64; `shl rN, 9` for fed_slot × 512 = 8 × 64 base (never `imul r, imm`).
- Shift-trick (`shl rN, 32; shr rN, 32`) for 32-bit mask; `shl rN, 48; shr rN, 48` for 16-bit mask. Never `and r11, imm64`.
- Single-line `pub let name = "..."`.
- Fingerprint `[u8; N]` with `N = string length + 1` (NUL counts).

Stack discipline (SysV, entry rsp%16==8):

| function                   | pushes | sub rsp | nested calls |
|----------------------------|--------|---------|--------------|
| `fed_note`                 | 0      | 0       | leaf         |
| `fed_fed_row`              | 0      | 0       | leaf         |
| `fed_peer_row`             | 0      | 0       | leaf         |
| `fed_find_fed`             | 0      | 0       | leaf         |
| `fed_find_free_fed`        | 0      | 0       | leaf         |
| `_fd_init`                 | 1      | 0       | fed_note, klog_s1 |
| `_fd_federation_register`  | 4      | 8       | fed_find_fed, fed_find_free_fed, fed_note, klog_s1_x1 |
| `_fd_peer_register`        | 5      | 16      | fed_find_fed, fed_note, klog_s1_x1; spills name_len + clamped_len |
| `_fd_peer_lookup`          | 2      | 8       | fed_find_fed, fed_note, klog_s1_x1 |
| `_fd_peer_list`            | 4      | 8       | fed_find_fed, fed_note, klog_s1_x1 |

---

## 10 Smoke-mode goldens (deferred)

A proper end-to-end golden lands with R137.M5 (KIND_FEDERATION cap-invoke) and R137.M4 (wire framer), where every public verb has at least one production path exercising it:

1. **Bringup golden** — `FED_DISC INIT OK` fires on every boot (unconditional); already asserted by the fingerprint coverage gate.
2. **Registration golden** — a bootstrap task registers a `federation = "home"` with two peers (`192.168.1.10:9100`, `192.168.1.11:9100`), observing `FED_DISC FED_REG OK` + two `FED_DISC PEER_REG OK` lines.
3. **Lookup golden** — the shell's `peers` builtin invokes `_fd_peer_list(home)` and renders a two-row ANSI table; observes `FED_DISC LIST OK` + the rendered output.
4. **Authorise golden** (R137.M5) — a handshake against `192.168.1.10:9100` under cap `cap_home` succeeds; a handshake against `192.168.1.12:9100` (unregistered) under the same cap fails with `RSH_ERR_FED`.

Until (2)–(4) land, the registry is observed only through the boot fingerprint and the stats counters (`_fd_stats[FD_ST_*]`); the direct-call API's reject paths are reachable by a kernel smoke that mints a bad `fed_id` and asserts the errno.

---

## 11 Open questions for R137.M5

- **Status probe cadence.** Should the UNKNOWN → REACHABLE/UNREACHABLE transition be driven by a user-visible `peers probe` command, or by an automatic retry on handshake failure? Current preference: user-visible, because paideia-os does not run kernel background work for user network state.
- **Federation deletion.** Zeroing an 8-peer slot range is cheap but leaves the federation's `fed_id` live; a reclaim pass needs an explicit `_fd_federation_unregister(fed_id)`. Candidate error code: `FD_ERR_FED_BUSY = 0x2104` when a peer in the federation still has a live KEM session slot.
- **Name update.** The idempotent-re-register posture refuses to update the name. R137.M5 may expose `_fd_federation_rename(fed_id, name_ptr, name_len)` behind a dedicated cap right (`RIGHT_RENAME`) to admit the operation under explicit authority.
- **Wider federation (>8 peers).** The 8-peer-per-federation ceiling is a storage decision, not a protocol one. R137.M6+ can widen to 32 or 64 by growing the peer pool and adjusting the `fed_slot * N + peer_index` arithmetic (power-of-two N preserved for `shl`-based addressing).

---

## 12 Related work

- R137.M1 — `svc.remote-shell` daemon (per-connection state); `design/shell/remote-shell-daemon.md`.
- R137.M2 — ML-KEM-768 handshake (reduced to ML-KEM-only split); `design/shell/remote-shell-hybrid-kem.md`.
- R135.M1 — `svc.jail-supervisor` row pool (parallel shape).
- R127.M1 — `svc.shell-session` row pool (parallel shape).

Closes paideia-os#2635.
