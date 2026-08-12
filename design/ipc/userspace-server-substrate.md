# PaideiaOS — Userspace-Server Substrate (R20b)

**Status:** Design v0.1
**Date:** 2026-08-11
**Round:** R20b (fresh milestone-cluster to unblock #1015)
**Unblocks:** #820 (acpi_supervisor server binary), #860 (pci_enumerator
userspace server), every post-R20 userspace daemon.
**Blocker issue:** #1015 (R20.M4 blocker: userspace-server infrastructure
gap defers #820).

---

## 0. Purpose and scope

Issue #1015 identifies four infrastructure gaps that block moving any
"supervisor" or "daemon" out of the kernel into ring-3. This document
fixes the concrete shapes for a **minimum-viable** substrate that closes
those gaps while remaining byte-compatible with the phase-1 sub-API of
`design/ipc/wait-free-dataflow.md` (§11.2). The four gaps map 1:1 to
milestones M1..M4; a fifth milestone (M5) is the closure witness.

**Non-goals for R20b.** Session types, functor-typed channels, slot-cap
economy, algebraic-effect dispatch, MCS scheduling-context donation,
cross-host bridge, and multiparty session types are all deferred to
later rounds. The wait-free-dataflow.md targets remain the north star;
R20b is the phase-1 bootstrap of the substrate the target consumes.

---

## 1. Substrate choice (IPC-Q1 for R20b)

Two candidates:

| Candidate | Verdict |
|-----------|---------|
| Extend the B6 SPSC ring into a multi-endpoint substrate | **Chosen.** |
| Ship the wait-free-dataflow primitive in one round | Rejected. |

**Justification.** wait-free-dataflow.md itself declares a phase-1 fallback (§11.2:
"NASM bootstrap with hand-traced linearity, no session types, no functor-typed
channels, no slot-cap economy, procedural DAG check"). Phase 1 is exactly what
R20b needs. Shipping full wait-free-dataflow requires phase-1 of the
substructural lattice, functors, and algebraic effects on the paideia-as
side (see §17 of the target doc for the interlock) — none of which have
landed. The chosen substrate is the phase-1 stepping stone; it is byte-
compatible with `Channel(BytesSchema)` for phase-2 migration insurance
(P1IPC-D7 in phase1-api.md §0).

---

## 2. Four substrate pieces (map to #1015 acceptance criteria)

| M | AC in #1015 | Delivers |
|---|-------------|----------|
| M1 | Named-endpoint mechanism | KIND_IPC_ENDPOINT tail encoding + broker/registry + `svc.<name>` lookup. |
| M2 | Framed variable-length IPC | 8-byte header per acpi-supervisor-schema §3 + per-endpoint 4 KiB payload buffer + slot layout. |
| M3 | Userspace-server process model | `sys_ipc_recv` / `sys_ipc_reply` syscalls + blocking-recv scheduler hook. |
| M4 | Loader capability-seed hook | `_init_caps` sidecar array + `loader_seed_caps` invoked pre-first-schedule. |
| M5 | (closure witness) | Trivial echo-server end-to-end fixture over the M1..M4 substrate. |

Sequencing: **M1 first** — every other piece is defined over `KIND_IPC_ENDPOINT`. M2 then M3 are independent (M2 fixes the payload format; M3 fixes the syscall surface; they meet in the server implementation of M5). M4 is orthogonal — it can land any time after M1 because the seed just mints a cap into a task's cap_table. M5 requires all four.

---

## 3. M1 — Named endpoint substrate

### 3.1 KIND_IPC_ENDPOINT — no new base kind

Base kind 5 (`KIND_IPC_ENDPOINT`) is already reserved in the closed 16-kind enum (`src/kernel/core/cap/kind.pdx`). The existing kernel handler (`src/kernel/core/cap/kind_ipc.pdx`) treats `target_ptr` as unused and wires OP_SEND / OP_RECV to a single global SPSC channel — this is the B6 MVP. R20b formalizes `target_ptr` as the endpoint tail:

```
 target_ptr  =  endpoint_id (bits 15:0)
             |  direction   (bits 17:16)      // 0=send, 1=recv, 2=bidi, 3=reserved
             |  reserved    (bits 23:18)      // MUST be zero
             |  reserved    (bits 63:24)      // future: credit_bytes / session pointer
```

The kernel keeps a small **endpoint table** (`_ipc_endpoint_table`, 128 entries, static .bss) indexed by `endpoint_id`. Each entry:

```
Endpoint (48 bytes, cache-line-aligned)
  +0    u16 endpoint_id           (redundant; helps audit)
  +2    u8  in_use                (1 = live, 0 = free)
  +3    u8  flags                 (bit 0 = has_pending_msg,
                                   bit 1 = has_pending_reply)
  +4    u32 reserved
  +8    u64 owner_tcb             (pointer to receiver's TCB, NULL until bound)
  +16   u64 payload_buf_pa        (4 KiB page holding the current in-flight message)
  +24   u64 pending_hdr           (8-byte header of the message in payload_buf_pa)
  +32   u64 waiter_tcb            (TCB blocked on this endpoint's recv, NULL if none)
  +40   u64 reserved              (future: session_state pointer)
```

No dynamic allocation at R20b: 128 endpoints × 48 bytes = 6 KiB total for the table; 128 × 4 KiB = 512 KiB for the payload-buffer arena (statically reserved).

### 3.2 Rights refinement

Base rights unchanged from `src/kernel/core/cap/rights.pdx`:

```
R_IPC_READ    (0x01)   = permit sys_ipc_recv (dequeue)
R_IPC_WRITE   (0x02)   = permit sys_ipc_send (enqueue)
R_IPC_INVOKE  (0x08)   = required for either op (gate bit)
R_IPC_ALL     (0x0B)   = READ | WRITE | INVOKE
```

The endpoint-cap holder's rights determine whether it can `recv`, `send`, or both. Servers hold `R_IPC_READ | R_IPC_INVOKE`; clients hold `R_IPC_WRITE | R_IPC_INVOKE`. A supervisor holds `R_IPC_ALL` to bootstrap both sides.

### 3.3 Broker / registry

A per-kernel table `_svc_broker_table` (32 entries, static .bss) maps `svc.<name>` → `endpoint_id`:

```
BrokerEntry (48 bytes)
  +0    u8[32]  name             (NUL-terminated, ≤ 31 chars)
  +32   u16     endpoint_id
  +34   u16     reserved
  +36   u32     rights_gate      (rights the broker mints when handing out the cap)
  +40   u64     reserved
```

Broker operations (kernel-only at M1; syscall wrapper at M1-003):
- `svc_register(name_va, name_len, endpoint_id, rights_gate) -> rc` — requires the caller to hold the endpoint cap.
- `svc_lookup(name_va, name_len) -> cap_slot` — mints a new cap in the caller's cap_table pointing at the registered endpoint with the broker's `rights_gate`.

### 3.4 What does not change in M1

- The B6 SPSC ring (`src/kernel/core/ipc/channel.pdx`) stays as-is — it becomes endpoint 0's underlying transport for backward compatibility with the existing `ipc_enqueue`/`ipc_dequeue` and the `boot_r12` smoke.
- `kind_ipc.pdx`'s OP_SEND/OP_RECV opcodes stay wire-compatible for cap-slot invocations that don't specify an endpoint_id (they fall through to endpoint 0).
- `KIND_IPC_PORT` (base 6) is untouched — it addresses a different port-mapped-I/O use case.

---

## 4. M2 — Framed variable-length IPC

### 4.1 Header (matches acpi-supervisor-schema.md §3 exactly)

```
+------+------+-------------+---------------------+
|  op  |  ver | flags (u16) |  payload_len (u32)  |
+------+------+-------------+---------------------+
   u8     u8     LE-16            LE-32
```

Header size: 8 bytes. All multi-byte scalars little-endian. `payload_len` MUST NOT exceed 4088 bytes (4096 − 8-byte header). Reply framing identical; a reply's `op` is the request `op | 0x80`.

### 4.2 Endpoint payload buffer

Each endpoint owns exactly one 4 KiB page (allocated at kernel boot in `_ipc_payload_arena`, static .bss). The page is layout as `[hdr:8 | payload:payload_len | pad]`. The kernel copies request bytes into the page on `sys_ipc_send`; the receiver reads them out on `sys_ipc_recv`; reply bytes overwrite the page on `sys_ipc_reply`. A single in-flight message per endpoint at R20b (no multi-slot ring). Multi-slot upgrade is a phase-2 concern (introduces the slot-cap economy).

### 4.3 Message boundary semantics

`sys_ipc_send(cap_slot, hdr, payload_va, payload_len)`:
1. Cap-lookup + rights-gate (R_IPC_WRITE | R_IPC_INVOKE).
2. Reject if `payload_len > 4088` (E2BIG).
3. Reject if endpoint's `flags.has_pending_msg` is set (EAGAIN — endpoint busy; upgrade to WOULD_BLOCK-and-wait in M3).
4. Write hdr into `endpoint.pending_hdr`.
5. Bounce user payload into `endpoint.payload_buf_pa` via `user_read_bytes_via_walk` (KPTI-aware, per the dispatch layer's #737 pattern).
6. Set `flags.has_pending_msg = 1`; wake `endpoint.waiter_tcb` if non-NULL.

`sys_ipc_recv(cap_slot, out_hdr_va, out_payload_va, out_payload_cap)`:
1. Cap-lookup + rights-gate (R_IPC_READ | R_IPC_INVOKE).
2. If `flags.has_pending_msg == 0`: set `endpoint.waiter_tcb = current`, `sched_block()`; on resume, retry.
3. Read `endpoint.pending_hdr` into user's `out_hdr_va` via `user_write_u64_via_walk`.
4. Read `min(hdr.payload_len, out_payload_cap)` bytes from `endpoint.payload_buf_pa` into `out_payload_va` via `user_write_bytes_via_walk`.
5. Clear `flags.has_pending_msg`.
6. Return `hdr.payload_len` (bytes actually available; user's copy may be short).

---

## 4.4 Same-endpoint request/reply resolution (R20b.M6-003, #1566)

**Problem.** §4.3 pins a single in-flight message per endpoint (single-slot
`pending_hdr` on the endpoint row). Under that discipline, a naive
same-endpoint request/reply pattern deadlocks the reply direction:

```
1. Server: sys_ipc_recv(ep=1)      // blocks, waiter=server
2. Client: sys_ipc_send(ep=1, req) // publishes; wakes server
3. Client: sys_ipc_recv(ep=1, ...) // endpoint holds req (not drained yet)
                                    //   → client drains its OWN request!
```

Even without the client racing itself, the *server* can accidentally drain
its own reply: after `sys_ipc_reply`, the endpoint's `pending_hdr` slot is
non-zero (holding the reply). The server loops back to `sys_ipc_recv` on
the same endpoint and immediately drains the reply as if it were a new
request — semantic corruption.

**Options considered.**

| Option | Mechanism | Cost | Verdict |
|---|---|---|---|
| A. Dual endpoints — reply header carries `reply_endpoint_id` | Client mints a reply endpoint; encodes its id in the request hdr; server's `sys_ipc_reply` publishes to that endpoint | 1 extra endpoint per client + header field | **Chosen (compact variant).** |
| B. Yield-hint on reply — scheduler cooperates | `sys_ipc_reply` sets a reply-pending bit, wakes client, force-yields server | Invasive scheduler-hint infra; still needs a second slot or lane discipline for reply | Rejected — scheduler churn without solving lane confusion. |
| C. Bounded ring per endpoint — request lane + reply lane | Two `pending_hdr` slots + two payload arenas per endpoint | 2× payload storage + lane discriminator arg on recv/reply | Rejected — larger memory footprint AND changes recv/reply syscall shape. |

**Chosen — Option A (compact variant).** The wire-format change is
minimized by *repurposing the reserved `flags` u16 field of the existing
8-byte header as `reply_endpoint_id`*. No header-size growth; no
`FRAME_MAX_PAYLOAD` reduction; no endpoint row-layout change (`pending_hdr`
stays 8 bytes at row +24). The trade-off is that the `flags` field
(previously reserved MUST-be-zero in v1) is no longer available for
future flag bits at v1 — a future v3 header that needs true flag bits
must widen the header explicitly. This is acceptable at R20b because
(1) no existing site consumed `flags` bits (§4.1 v1 pins `flags` = 0),
and (2) header widening is a v-bump-gated change the substrate can
absorb cleanly if it becomes necessary.

**Repurposed header layout (semantic v2, byte-compatible with v1):**

```
+------+------+-------------+---------------------+
|  op  |  ver | reply_ep_id |    payload_len      |
+------+------+-------------+---------------------+
   u8     u8     LE-16              LE-32
   +0     +1    +2..+3            +4..+7
```

`reply_endpoint_id` is a u16 in [0, 127]:
- `0` — **legacy "reply-on-source" semantic**. `sys_ipc_reply` publishes
  to the endpoint the *request* was received on (the endpoint identified
  by the reply's cap_slot). Preserves byte-compat with every R20b.M1..M5
  witness and every one-way message pattern. This is the SAME-ENDPOINT
  behavior; safe iff the caller sequences the send/reply/recv strictly
  (as every kernel-driven witness does).
- `[1, 127]` — **dual-endpoint semantic**. `sys_ipc_reply` publishes to
  the endpoint identified by `reply_endpoint_id`, regardless of the
  reply's cap_slot. The client's own reply endpoint receives the reply;
  the server's endpoint stays available for the next request; no
  same-endpoint race.

**Wire protocol — dual-endpoint round trip:**

1. Client mints (or is seeded, via `_init_caps` per M4-001) a *reply*
   endpoint (say `endpoint_id=2`) with `R_IPC_READ | R_IPC_INVOKE` in a
   distinct cap_slot (e.g. cap_slot 1).
2. Client encodes the request header with
   `reply_endpoint_id = 2` and calls
   `sys_ipc_send(server_cap_slot, hdr_va, payload_va, len)`.
3. Client calls `sys_ipc_recv(reply_cap_slot, hdr_va, payload_va, max)` —
   blocks on `endpoint_id=2`.
4. Server drains the request via `sys_ipc_recv(server_cap_slot, ...)`;
   sees `hdr.reply_endpoint_id = 2` in the drained hdr.
5. Server processes, sets `hdr.op |= 0x80` (`FRAME_OP_REPLY_BIT`),
   preserves `reply_endpoint_id = 2` in the hdr, and calls
   `sys_ipc_reply(server_cap_slot, hdr_va, payload_va, len)`.
6. `sys_ipc_reply_body` reads the first 4 bytes of the hdr via the
   KPTI-safe walker, extracts `reply_endpoint_id`, and — because it is
   non-zero — publishes to `endpoint_id=2` (client's reply endpoint),
   waking the client.
7. Client returns from `sys_ipc_recv` with the reply payload.
8. Server loops back to `sys_ipc_recv(server_cap_slot, ...)` — endpoint
   is empty (only the request lived there, and the reply went to a
   different endpoint), so server blocks cleanly for the next request.

**Capability model at R20b.** The server does not hold a cap for the
client's reply endpoint. The kernel trusts `hdr.reply_endpoint_id`
because the request came in on a valid cap the server holds — this is a
"reply back to whatever the request said" trust discipline. A future
round (R21+) can tighten this via an implicit reply-cap minted at
`sys_ipc_recv` time (granting the server one-shot `R_IPC_WRITE` on
`reply_endpoint_id`) or via explicit cap-transfer in the header. R20b
does neither and documents the trust discipline here.

**Impact on existing sites.**

- `frame.pdx` — u16 field at offset +2 renamed from `flags` to
  `reply_endpoint_id` in docs; accessor `frame_hdr_reply_endpoint_id`
  added as an alias for the byte-identical `frame_hdr_flags`.
- `sys_ipc_reply.pdx` — walker read grows from 1 byte (op) to 4 bytes
  (op + ver + reply_endpoint_id); bit-7 op check unchanged; new logic:
  if `reply_endpoint_id != 0` override the cap-resolved endpoint id.
- `sys_ipc_send.pdx` / `user_bounce.pdx` / `endpoint_table.pdx` — no
  functional change (hdr copy is still 8 bytes; publish/take semantics
  unchanged).
- All kernel-driven witnesses (M2/M3/M5) — pass `flags = 0` in
  `frame_encode`, which is now `reply_endpoint_id = 0`, which selects
  the legacy same-endpoint behavior. Their kernel-side sequential drive
  never triggered the race, so their behavior is preserved bit-exact.

**Witness — R20b.M6-003 (dual-endpoint kernel-driven roundtrip).** A new
witness in `kernel_main.pdx` (extends the M5-001 witness placement)
allocates two endpoints, drives the full 8-step protocol above
kernel-side (mirrors M5-001's discipline of direct
`sys_ipc_send_body` / `sys_ipc_recv_body` / `sys_ipc_reply_body`
calls against init's user_pml4), and emits
`R20b RPC ROUNDTRIP OK` on success. Proves the substrate fix without
requiring the loader + scheduler wiring for spawning two real
userspace tasks.

**Deferred (out of scope for R20b.M6-003).**

- **Real 2-task scheduler-driven roundtrip** — spawning both
  `echo_server` and `echo_client` as real userspace tasks with their
  `_init_caps` sidecars processed and letting the scheduler alternate
  them requires: (1) loader-side path to spawn tasks other than init
  at boot with their sidecars; (2) tmpfs seeding of both binaries;
  (3) init modifications to fork+exec each and wait4 both. The
  `src/user/echo_server.pdx` + `src/user/echo_client.pdx` source
  files land at R20b.M6-003 as the target-shape for this deferred
  witness, but their spawn wiring is a future round (R21+ once
  multi-task boot orchestration lands).
- **Reply-cap minting at recv** — kernel-mints a short-lived
  `R_IPC_WRITE` cap on `reply_endpoint_id` into the server's cap_table
  at `sys_ipc_recv` time, so `sys_ipc_reply` gates against a real cap.
  R21+.
- **Cap-transfer in header** — client transfers a `R_IPC_WRITE` cap on
  its reply endpoint via the header (session-type-shaped). R21+ session
  types round.

---

## 5. M3 — Server-process model

### 5.1 Syscall numbers

Both new syscalls fit in the `< 61` bound preserved by `tools/verify-syscall-dispatch.sh`:

```
40  sys_ipc_recv    (blocking receive on an endpoint)
41  sys_ipc_reply   (send a reply on an endpoint; alias of sys_ipc_send with bit-7 op flip)
42  sys_ipc_send    (send a request on an endpoint; new — no bit-7)
43  sys_svc_lookup  (svc.<name> → cap_slot; convenience)
```

Sysno 40..43 chosen contiguously; sysnos 5..11 and 14..31 remain reserved. `sys_ipc_send` and `sys_ipc_reply` share their body implementation; the wrapper differs only in the bit-7 assertion on `hdr.op`.

### 5.2 Blocking-receive scheduler hook

The existing `sched_block` primitive (already used by `sys_wait_body` per `syscall/dispatch.pdx` §dispatch_wait4) is the wait mechanism. State transitions:

```
Running --sys_ipc_recv (empty)---> WAITING_IPC  (tcb.wait_endpoint_id = eid)
WAITING_IPC --sys_ipc_send from producer--> RUNNABLE (runq_enqueue)
```

`WAITING_IPC` is a new state value; the runqueue path already skips non-RUNNABLE tasks. The wake path in `sys_ipc_send` finds the waiter via `endpoint.waiter_tcb` (single-waiter at R20b; a wait queue lands in a later round).

### 5.3 What does not change in M3

- Existing `sys_exit` / `sys_wait` / `sys_fork` termination + reap flow is untouched.
- The single-CPU / SMP scheduler substrate is unchanged; blocking is a per-TCB state flip that plays through the existing `runq_dequeue` / `runq_enqueue` primitives.
- The existing linear-flow user binaries (`init.pdx`, `shell.pdx`, `child_hello.pdx`, `true.pdx`) do not use any of the new syscalls; they continue to run identically.

---

## 6. M4 — Loader capability-seed hook

### 6.1 The sidecar array

Every userspace image that expects seeded caps declares an `_init_caps` array in its `.rodata`. Format:

```
InitCap (16 bytes)
  +0    u16 slot            (target slot in the task's cap_table, 0..255)
  +2    u16 kind            (KIND_* value, matches kind.pdx enum)
  +4    u32 rights          (RIGHTS_* mask)
  +8    u64 target_ptr      (kind-specific; for KIND_ACPI: the ACPI RSDP PA)

_init_caps_count : u16   (count of InitCap entries)
_init_caps       : InitCap[_init_caps_count]
```

The image publishes the two symbols; `elf_lite_load`'s post-load hook resolves them by name from the image's symbol table (or, for phase-1 simplicity, at a fixed offset in the image's `.init_caps` section).

### 6.2 Loader-hook signature

```
loader_seed_caps(task_ptr, image_base, image_len) -> rc
```

Called by `elf_lite_load` after `aspace_map` has mapped the image's segments and before the task is `runq_enqueue`d for the first time. The hook:
1. Locates `_init_caps` in the image (via `.init_caps` section or symbol lookup).
2. For each `InitCap`: calls `cap_mint_write(task_cap_table + slot*24, kind, rights, target_ptr)`.
3. On any failure: aborts image load (`ELF_CAP_SEED_FAILED`), so a mal-formed sidecar cannot leave a task with partial caps.

### 6.3 Kernel-side supervisor bootstrap

For R20b the `acpi_supervisor` server binary does not yet exist. The kernel boot path (M1-002 in the sub-issue set) manually mints the KIND_ACPI cap into a designated slot of the first server task's cap_table via the same `cap_mint_write` primitive that `loader_seed_caps` will use. This proves the plumbing; the sidecar-based path lands with the first real userspace supervisor.

---

## 7. M5 — Closure witness (echo server)

The end-to-end fixture that proves M1..M4 compose correctly:

1. Kernel boot: mint an endpoint cap for endpoint_id=1, register `svc.echo` → endpoint_id=1 in the broker.
2. Spawn a small userspace server (`src/user/echo_server.pdx`) whose `_init_caps` seeds slot 0 with the endpoint cap (R_IPC_READ | R_IPC_WRITE | R_IPC_INVOKE).
3. Server loop: `sys_ipc_recv(slot=0)` → echo hdr/payload back via `sys_ipc_reply(slot=0)`.
4. Client (init or a small test binary) calls `sys_svc_lookup("svc.echo")` → gets a client-side cap in some free slot; sends a request; reads the reply.
5. Boot fingerprint: `R20b ECHO ROUNDTRIP OK`.

---

## 8. Concrete shape summary (for the sub-issues)

| Symbol / constant | Value | File |
|---|---|---|
| `KIND_IPC_ENDPOINT` (base) | 5 | already in `kind.pdx` (unchanged) |
| Endpoint-tail: endpoint_id | target_ptr bits 15:0 | new: `kind_endpoint.pdx` |
| Endpoint-tail: direction | target_ptr bits 17:16 | new: `kind_endpoint.pdx` |
| `ENDPOINT_DIR_SEND` | 0 | new: `kind_endpoint.pdx` |
| `ENDPOINT_DIR_RECV` | 1 | new: `kind_endpoint.pdx` |
| `ENDPOINT_DIR_BIDI` | 2 | new: `kind_endpoint.pdx` |
| `R_IPC_READ` | 0x01 | already `rights.pdx` |
| `R_IPC_WRITE` | 0x02 | already `rights.pdx` |
| `R_IPC_INVOKE` | 0x08 | already `rights.pdx` |
| `R_IPC_ALL` | 0x0B | new: `kind_endpoint.pdx` |
| `_ipc_endpoint_table` | 128 × 48 B = 6 KiB | new: `ipc/endpoint_table.pdx` |
| `_ipc_payload_arena` | 128 × 4 KiB = 512 KiB | new: `ipc/payload_arena.pdx` |
| `_svc_broker_table` | 32 × 48 B = 1.5 KiB | new: `ipc/svc_broker.pdx` |
| Message header size | 8 bytes | new: `ipc/frame.pdx` |
| Max payload | 4088 bytes | new: `ipc/frame.pdx` |
| `sys_ipc_recv` | sysno 40 | new: `syscall/handlers/sys_ipc_recv.pdx` |
| `sys_ipc_reply` | sysno 41 | new: `syscall/handlers/sys_ipc_reply.pdx` |
| `sys_ipc_send` | sysno 42 | new: `syscall/handlers/sys_ipc_send.pdx` |
| `sys_svc_lookup` | sysno 43 | new: `syscall/handlers/sys_svc_lookup.pdx` |
| `TASK_STATE_WAITING_IPC` | new state value | `sched/state.pdx` |
| `_init_caps` sidecar format | InitCap[16 B] | new: `loader/init_caps.pdx` |
| `loader_seed_caps` | (task, image, len) → rc | new: `loader/seed_caps.pdx` |

---

## 9. Sequencing summary

```
              M1-001 KIND_IPC_ENDPOINT tail
                          │
              ┌───────────┴───────────┐
              ▼                       ▼
      M1-002 endpoint table      M2-001 payload arena
      M1-002b broker             M2-002 frame header
      M1-003 svc_lookup          M2-003 send/recv memcpy
              │                       │
              └───────────┬───────────┘
                          ▼
          M3-001 sys_ipc_recv (blocking)
          M3-002 sys_ipc_send + wake path
          M3-003 dispatch wiring for 40..43
                          │
                          ▼
          M4-001 InitCap sidecar
          M4-002 loader_seed_caps + wire-in
                          │
                          ▼
          M5-001 echo-server closure witness
```

The KIND_IPC_ENDPOINT foundation (M1-001) unblocks every branch. The M1 broker branch and the M2 framing branch can proceed in parallel across iterations once M1-001 lands. M3 depends on both. M4 is independent of M2/M3 but depends on M1 for slot semantics. M5 depends on M1..M4.

---

## 10. Cross-references

- `design/ipc/wait-free-dataflow.md` — target substrate; R20b is its phase-1 bootstrap.
- `design/ipc/phase1-api.md` — phase-1 fallback API sketch (P1IPC-D7 migration insurance).
- `design/ipc/acpi-supervisor-schema.md` — the first schema this substrate carries (once R20b lands, #820 unblocks).
- `design/capabilities/derived-kinds.md` — KIND_IPC_ENDPOINT stays a base kind; the direction refinement is a static-only discipline, not a derived-kind registration.
- `src/kernel/core/ipc/channel.pdx` — B6 MVP; kept intact.
- `src/kernel/core/cap/kind_ipc.pdx` — existing OP_SEND/OP_RECV handler; extended in M2 to consume the endpoint tail.
- `src/kernel/core/loader/elf_lite.pdx` — extended in M4 with the `loader_seed_caps` post-load hook.

---

*End of document.*
