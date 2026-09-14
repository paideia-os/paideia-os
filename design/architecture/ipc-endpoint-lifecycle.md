# ξ-03 — IPC Endpoint Lifecycle

## Purpose

This is ξ-03 in the architecture-doc wave alongside `design/architecture/kernel-cap-taxonomy.md` (ξ-01, capability kind taxonomy) and `design/architecture/syscall-table-v2.md` (ξ-02, syscall surface). Where those two document the kind enum and the syscall table as standing structures, this document walks one capability kind — `KIND_IPC_ENDPOINT` (base kind 5) — end to end: how an endpoint capability is minted, how a message actually moves from sender to receiver through the kernel, what happens when `sys_ipc_recv`'s `timeout` argument is used, and what happens to an endpoint and any task blocked on it when a process dies.

The authoritative design documents for the substrate this doc synthesizes are `design/ipc/userspace-server-substrate.md` (the M1–M6 build-out: tail encoding, framing, the server-process model, loader cap-seeding) and `design/ipc/wait-free-dataflow.md` (the longer-horizon SPSC/session-typed channel design that the R20b substrate is a phase-1 approximation of). This document does not re-derive either; it cites them and adds the parts neither states directly — the real mint wiring status, and the orphan-handling gap that only becomes visible by reading the process-death path against the endpoint table.

## Endpoint identity and rights

Base kind 5 (`KIND_IPC_ENDPOINT`) is a base kind in the closed 16-kind enum, not a derived kind — see `design/architecture/kernel-cap-taxonomy.md` for where it sits in that enum. Its `target_ptr` descriptor field is a packed "tail": `src/kernel/core/cap/kind_endpoint.pdx:19-23`.

| Bits | Field | Meaning |
|---|---|---|
| [15:0] | `endpoint_id` | index into the 128-row endpoint table (0..127) |
| [17:16] | `direction` | 0=send, 1=recv, 2=bidi, 3=reserved (rejected by the validator) |
| [23:18] | reserved | must be zero |
| [63:24] | reserved | future: credit_bytes / session ptr |

`endpoint_tail_encode` / `endpoint_tail_decode_id` / `endpoint_tail_decode_dir` / `endpoint_tail_valid` are pure mask/shift helpers with no side effects (`src/kernel/core/cap/kind_endpoint.pdx:108-210`). `endpoint_tail_valid` additionally bounds-checks `endpoint_id < 128` and rejects `direction == 3`.

Rights are a 4-bit subset of the base `Rights.RIGHT_*` space, aliased locally for clarity (`kind_endpoint.pdx:78-81`):

| Right | Value | Meaning |
|---|---|---|
| `R_IPC_READ` | 0x01 | permits `sys_ipc_recv` |
| `R_IPC_WRITE` | 0x02 | permits `sys_ipc_send` |
| `R_IPC_INVOKE` | 0x08 | gate bit required alongside either of the above |
| `R_IPC_ALL` | 0x0B | READ\|WRITE\|INVOKE |

Convention: servers hold READ\|INVOKE, clients hold WRITE\|INVOKE, supervisors hold ALL (`kind_endpoint.pdx:48-51`). Full detail — including the `endpoint_rights_valid` subset check — lives in that file; it is not restated here.

## Minting an endpoint

### `endpoint_cap_mint`: gate-only, and it stays that way

`endpoint_cap_mint(tail, rights)` (`src/kernel/core/cap/kind_endpoint.pdx:257-289`) runs exactly two pure validators in sequence — `endpoint_tail_valid` then `endpoint_rights_valid` — and returns `ENDPOINT_MINT_OK` (0) or one of two `ENDPOINT_MINT_BAD_*` codes. **It never calls `cap_mint_write` and never touches `cap_table`.** The file's own header comment (`kind_endpoint.pdx:53-61`) attributes this to a stated precondition: "the actual descriptor slab write is deferred until `cap_revoke` grows a real body."

That precondition has since been met and the wiring still did not happen. `cap_revoke` gained a real body at R31.M1-1589 (`src/kernel/core/cap/revoke.pdx:119-141`) — it now decodes a handle to a slot and delegates to `cap_revoke_slot`. But `revoke.pdx`'s own header is explicit that this real body changed nothing about reachability: "**THIS FUNCTION HAS NO CALLER**... `cap_revoke` is... unreachable from any syscall path" (`revoke.pdx:80-105`). Every revocation the running kernel actually performs enters one layer down, at `cap_revoke_slot`, from `cap_owner_sweep_revoke` on process death or from a kind's own audited revoke — never from `cap_revoke` itself, and by extension never from anything that would have justified wiring `endpoint_cap_mint` to a real slab write.

Cross-checked directly against the only live mint path (below): `sys_svc_lookup_body` does not call `endpoint_cap_mint` at all. It calls `endpoint_tail_encode` (the pure packer, not the validating gate) and then `cap_mint_write` directly (`src/kernel/core/syscall/handlers/sys_svc_lookup.pdx:258-290`), skipping both `endpoint_tail_valid` and `endpoint_rights_valid` entirely. **Finding, stated precisely: `endpoint_cap_mint` is gate-only scaffolding with no caller anywhere in the kernel tree outside its own witness coverage, and its wiring is not blocked on `cap_revoke`'s body status — that status changed and the wiring did not follow.** The boot witness in `kernel_main.pdx` installs its witness endpoint cap via `cap_mint_write` directly, exercising `endpoint_cap_mint` only alongside, for validator coverage (`kind_endpoint.pdx:59-61`).

### The real mint path: `sys_svc_lookup`

`sys_svc_lookup` (sysno 43, `src/kernel/core/syscall/handlers/sys_svc_lookup.pdx`) is the one live syscall that mints a `KIND_IPC_ENDPOINT` capability in userspace-reachable code:

1. Bounds-gate `name_len` in `[1, 31]`; walker-bounce the name string from user VA into a kernel scratch (`user_read_bytes_via_walk`) (:202-220).
2. `svc_lookup_row(name, name_len)` resolves the name against `_svc_broker_table`; miss → `-ENOENT` (:222-227).
3. Read the packed broker row word: low 16 bits = `endpoint_id`, bits [63:32] = `rights_gate` (:230-237).
4. Derive `direction` from `rights_gate`'s low two bits — READ+WRITE → BIDI, READ-only → RECV, else SEND (:239-256).
5. `endpoint_tail_encode(endpoint_id, direction)` — the pure packer (:258-261).
6. Linear-scan `cap_table` for the first slot with `kind == KIND_NULL`; exhaustion → `-ENOSPC` (:263-281).
7. `cap_mint_write(slot, KIND_IPC_ENDPOINT=5, rights_gate, tail)` — the real descriptor write (:283-290).

No tail or rights validation runs on this path beyond what the broker row already encodes at registration time; the `endpoint_id` and `direction` derivation are trusted because they come from a kernel-internal broker table, not from user input. Only the *name* crosses the user/kernel boundary here.

## Send/recv/reply data flow

### Storage: one row + one page per endpoint, single message in flight

The endpoint table is 128 fixed rows of 48 bytes each in `.bss` (`src/kernel/core/ipc/endpoint_table.pdx:19-33`, geometry constants at :120-122):

| Offset | Field | Purpose |
|---|---|---|
| +0 | `id`(u16) / `in_use`(u8) / `flags`(u8) / reserved(u32) | liveness + redundant id |
| +8 | `owner_tcb` | receiver TCB pointer (unused at R20b) |
| +16 | `payload_buf_pa` | bound 1:1 by id to a 4 KiB page in `_ipc_payload_arena` |
| +24 | `pending_hdr` | doubles as the full/empty discriminator — 0 = empty |
| +32 | `waiter_tcb` | TCB parked in `sched_block` on this endpoint's recv |
| +40 | driver-binding word (R29.M7-005) | slot/incarnation/dead-latch for driver-owned endpoints |

Each endpoint carries exactly **one** message slot — a single 8-byte header plus one 4 KiB payload page, not a queue (`endpoint_table.pdx:68-93`). A second send while a message is still pending is rejected with EAGAIN rather than buffered.

### Send (`sys_ipc_send`, sysno 42)

`sys_ipc_send_body` (`src/kernel/core/syscall/handlers/sys_ipc_send.pdx:164-252`):

1. `endpoint_is_dead(id)` — if the endpoint's driver-binding dead latch is set, return `-ECONNRESET` before publishing anything (:194-197, R29.M7-005 / #1048).
2. `user_bounce_send(id, hdr_va, payload_va, payload_len)`, which internally walker-copies the user payload into `_ipc_payload_arena[id]` and then calls `endpoint_write_pending(id, hdr, payload_ptr, payload_len)` (:199-209). `endpoint_write_pending` gates `payload_len <= 4088`, gates the row live, gates `pending_hdr == 0` (else EAGAIN), `rep_movsb`s the payload into the arena, then stores `hdr` into `pending_hdr` **last** — payload-before-header is the publish barrier (`endpoint_table.pdx:490-521,86-93`).
3. On success, `endpoint_lookup(id)` re-resolves the row, reads `waiter_tcb` at +32; if non-null, clears the slot **before** calling `sched_wake` (clear-before-wake, matching `uart_rx_notify` §3.4) (:211-235).
4. Return 0. A send with no waiter parked just publishes and returns — the message sits in the single slot until a `recv` drains it.

There is no "target not currently waiting" distinct case beyond this: if nobody is parked, the message is buffered in the one-slot arena, not dropped, and not blocking the sender. If a message is already pending (row full) and nobody has drained it, a new send gets EAGAIN rather than blocking or overwriting.

### Recv (`sys_ipc_recv`, sysno 40)

`sys_ipc_recv_body` (`src/kernel/core/syscall/handlers/sys_ipc_recv.pdx:171-295`), retry loop:

1. `endpoint_is_dead(id)` gate, same ChannelDead check as send, run at the top of every retry (:203-206).
2. `user_bounce_recv` → `endpoint_take_pending`: reads `pending_hdr`; if zero, returns `PENDING_TAKE_EMPTY` (-1). Otherwise copies `hdr` out, `rep_movsb`s the payload out of the arena into the caller's buffer, then zeroes `pending_hdr` **last** (mirror of the write-side ordering) (:208-228, `endpoint_table.pdx:594-682`).
3. If empty: `endpoint_lookup(id)` → row; install `endpoint.waiter_tcb = _current_tcb` at +32 and `_current_tcb.wait_endpoint_id = id` at TCB+120; call `sched_block` (:230-254). `sched_block` flips state RUNNABLE→WAITING(2) and switches away.
4. On wake: defensively clear both wait-slots (belt-and-suspenders — the primary clear is send's clear-before-wake), then `jmp` back to the top of the retry loop (:256-273).

## Timeout semantics

`design/user/syscall-table.md` documents sysno 40 as taking `r10 = timeout`. **There is no timeout implementation in the recv body.** `sys_ipc_recv_body`'s actual signature is `(id, user_hdr_va, user_payload_va, user_payload_max) -> u64` — four arguments, all consumed by the substrate logic above (`sys_ipc_recv.pdx:171`). No fifth argument is read, no timer-wheel deadline is armed, and `grep -rn timeout src/kernel/core/ipc/ src/kernel/core/syscall/handlers/sys_ipc*.pdx` finds no hits inside any IPC handler or the endpoint table — every `timeout`/`timeout_ns`/`timeout_ms` hit elsewhere in `src/kernel/core/ipc/` belongs to unrelated device-facing channels (`vk_surface_channel.pdx`, `vello_render_channel.pdx`, `usb_transfer_channel.pdx`, `display_sync_channel.pdx`, `vk_present_feedback_channel.pdx`) that implement their own polling/deadline logic against different primitives, not against `sys_ipc_recv`.

`sched_block` is an unconditional, unbounded wait (no `SCHED_WAIT_TIMER_NS`-style deadline is passed to it from this path, unlike `sys_sched_wait_ns`). Concretely: **a caller of `sys_ipc_recv` on an empty, non-dead endpoint blocks until a wake source fires — a real send (`sys_ipc_send`'s `sched_wake`) or a ChannelDead reap (`driver_restart_reap_endpoints`'s `sched_wake`) — with no timeout=0 non-blocking-poll mode and no expiry.** If the design intends `timeout=0` as non-blocking and non-zero as a bounded wait, none of that is implemented; the syscall-table row's `timeout` argument is currently dead ABI — accepted by no caller, read by no callee.

## Orphan handling

Process death is centralized in `driver_death_notify(pid)` (`src/kernel/core/driver/process_death.pdx:337-539`), called from the fault and `sys_exit` paths. It runs two independent sweeps:

1. **Owner-column sweep** — `cap_owner_sweep_revoke(pid, gen)` (`process_death.pdx:357-384`, defined at `src/kernel/core/cap/owner.pdx:751+`), unconditional for every dying process, scans `cap_owner[0..256)` for an exact `(pid, generation)` match and calls `cap_revoke_slot(slot)` on each hit.
2. **Driver-row sweep** — `driver_death_find_slot` + `driver_restart_node`, gated on the dying pid actually owning a registered driver row (`process_death.pdx:394-417`). This is the only path that reaches `driver_restart_reap_endpoints`.

### `cap_revoke_slot`'s per-kind dispatch does not include `KIND_IPC_ENDPOINT`

`cap_revoke_slot` (`src/kernel/core/cap/owner.pdx:464-748`) dispatches on the descriptor's `kind` field to a per-kind audited revoke for exactly nine derived kinds: `0x150` (`KIND_OP_REGION`, plus its lineage cascade), `0x152`–`0x15c` (`KIND_I2C_BUS`, `KIND_I2C_SLAVE`, `KIND_GPIO_LINE`, `KIND_FW_SESSION`, `KIND_EC_QUERY`, `KIND_THERMAL_ZONE`, `KIND_BATTERY`, `KIND_COOLING_DEVICE`, `KIND_BACKLIGHT`, `KIND_HID_DEVICE`, `KIND_HID_EVENT`) (:494-530). Base kind `5` (`KIND_IPC_ENDPOINT`) is **not** in that list, so a revoked endpoint capability falls to the generic path (`cap_own_rv_generic`, :696-723): emit an audit record with the real kind, then zero the three `cap_table` descriptor words. **This clears the capability (the holder's descriptor) but never touches `_ipc_endpoint_table` — it does not call `endpoint_free`, does not call `endpoint_mark_dead`, and does not wake `waiter_tcb`.** The endpoint row survives, still allocated, exactly as it was before the holder died.

### Only driver-bound endpoints get a wake-on-death path

`driver_restart_reap_endpoints(driver_slot)` (`src/kernel/core/driver/restart.pdx:621-729`) is the only code that calls `endpoint_mark_dead` in response to a death. It scans all 128 rows for ones whose binding word (`endpoint_table.pdx:684-707`, set only by an explicit `endpoint_bind_driver(id, driver_slot, incarnation)` call) names the dying `driver_slot`, and for each: `endpoint_mark_dead` (latch dead, detach `waiter_tcb`), emit `DRV_AUDIT_EV_CHANDEAD`, then `sched_wake` the detached waiter if one existed. The woken receiver's next retry through `sys_ipc_recv_body` hits the `endpoint_is_dead` gate at the top of the loop and returns `-ECONNRESET` (`sys_ipc_recv.pdx:203-206`) instead of re-blocking forever.

This reap only fires when `driver_death_find_slot` resolves the dying pid to a registered driver-table row (`process_death.pdx:394-401`) — i.e., only for processes that were explicitly bound into `_driver_table` and whose serving endpoint was explicitly `endpoint_bind_driver`-ed to that slot. An endpoint minted purely through `sys_svc_lookup`'s broker path (§Minting above) is never bound to a driver slot by that path alone; nothing in `sys_svc_lookup_body` or `svc_broker.pdx`'s registration calls `endpoint_bind_driver`. **Consequence: a client blocked in `sched_block` on `sys_ipc_recv` against a server endpoint whose serving process dies is only unblocked if that server process happens to also be a registered driver-table row with that endpoint explicitly bound to it. For any other server process, the client hangs in `sched_block` with no remaining wake source** — the exact hang class #1048's ChannelDead mechanism was built to close, but closed only along the driver-table axis, not along the general "any process holding a receive-side IPC endpoint cap died" axis. The owner-column sweep (which does run for every process) has no kind-5 case to notice this at all.

A symmetric gap exists for a client dying while its reply is expected: nothing marks the client's own endpoint capabilities dead from the server's perspective, but since the server does not block waiting on a specific client's liveness (only on its own recv queue), this direction does not hang — it simply means a completed reply into a since-dead client's endpoint sits in the arena until overwritten or the row is otherwise freed.

## Worked example

A client resolves and talks to a named service end to end:

1. Client calls `sys_svc_lookup("svc.some-name", 13)`. Dispatch walker-copies the name, `svc_lookup_row` resolves it against the broker table (populated at server registration time — see `src/kernel/core/ipc/svc_broker.pdx`), and a `KIND_IPC_ENDPOINT` capability (WRITE|INVOKE, direction=SEND) lands in the client's first free `cap_table` slot (`sys_svc_lookup.pdx:190-320`).
2. Client calls `sys_ipc_send(slot, hdr_va, payload_va, len)`. `sys_ipc_send_body` checks the endpoint isn't dead, publishes payload-then-header into the endpoint's single slot, and wakes the server if it was already parked in `sched_block` (`sys_ipc_send.pdx:164-252`).
3. Server, having earlier called `sys_ipc_recv` on the same `endpoint_id` (with its own READ|INVOKE capability, minted analogously via the same broker/mint path) and found it empty, is parked in `sched_block`; the send's `sched_wake` returns it to RUNNABLE, and its retry loop now finds `pending_hdr != 0` and drains the message (`sys_ipc_recv.pdx:171-295`).
4. Server processes the request and calls `sys_ipc_reply(id_or_reply_endpoint, hdr_va, payload_va, len)`. `sys_ipc_reply_body` walker-reads the low 4 header bytes, asserts bit 7 of `op` is set (rejects with `-EINVAL` otherwise), optionally reroutes to a distinct `reply_endpoint_id` carried in the header (dual-endpoint mode, R20b.M6-003), then delegates straight into `sys_ipc_send_body` against the resolved target (`sys_ipc_reply.pdx:181-263`).
5. Client, parked in its own `sys_ipc_recv` on the reply endpoint, wakes and drains the reply the same way step 3 describes.

`elevate_broker.pdx` is a second real (if only partly built out) consumer reachable the same way: it registers the well-known name `"svc.elevate-broker"` into the broker table via `elevate_broker_register(endpoint_id)` so any process holding `sys_svc_lookup` authority can resolve it, and exposes `elevate_broker_dispatch` as the wire-op entry point for the elevation-request protocol defined in `ipc/elevate_channel.pdx` — at the substrate-prep stage read here, dispatch recognizes the ops but returns a stub result for all of them (`src/kernel/core/ipc/elevate_broker.pdx:1-40`); the full daemon body is deferred to a later milestone per that file's own header.

## Open gaps

- **`endpoint_cap_mint` has no caller.** Confirmed by reading both `kind_endpoint.pdx` and the one live mint path (`sys_svc_lookup_body`, which calls `cap_mint_write` directly). This is not a transient state waiting on `cap_revoke`, as the file's own comment implies — `cap_revoke` has a real body now and nothing changed.
- **`sys_ipc_recv`'s documented `timeout` argument (`design/user/syscall-table.md` row 40, `r10`) is unimplemented.** The four-argument body signature has no room for it; `sched_block` is called with no deadline. There is no timeout=0-is-nonblocking convention in force; every recv on an empty, live endpoint blocks unconditionally.
- **Orphan handling only covers driver-table-bound endpoints.** `cap_revoke_slot`'s per-kind dispatch has no case for base kind 5, so the general owner-column death sweep neither frees nor dead-latches an orphaned endpoint row. Only `driver_restart_reap_endpoints`, reachable exclusively through the driver-table binding + restart cascade, wakes a blocked waiter with an error. A receiver blocked on a non-driver server process's death has no wake source and hangs indefinitely.
- **Single in-flight message per endpoint, no queue.** By design at R20b (`endpoint_table.pdx:60-66`); a second sender while one message is pending gets EAGAIN, not buffering or blocking. `design/ipc/wait-free-dataflow.md` describes the longer-horizon SPSC/session-typed replacement; this substrate is the phase-1 stand-in.
- **No concurrency/ABA guard on endpoint alloc/free** — explicitly deferred to R21+ SMP (`endpoint_table.pdx:60-66`, `kind_endpoint.pdx` design notes).
- **No handle generation** — `cap_revoke`'s own header documents that a revoked-and-re-minted slot is indistinguishable from the original to a stale handle holder, defended only by the kind check at each gate (`revoke.pdx:57-77`). This applies to `KIND_IPC_ENDPOINT` slots as much as any other kind.
