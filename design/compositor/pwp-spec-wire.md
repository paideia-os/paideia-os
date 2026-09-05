# PWP protocol spec — wire framing + opcode table

**Status:** Wave-0 protocol-freeze draft. Second of the four G7.M1 PWP freeze drafts.
**Issue:** paideia-os#2243 (`G7-M1-002`), milestone `g7-compositor-protocol`.
**Round:** G7. **Size:** M.
**Depends on:** G7-M1-001 (vocabulary index, `pwp-spec-vocabulary.md`, paideia-os#2242, landed).
**Adjacent:** G7-M1-003 (atomic-commit lifecycle, `pwp-spec-lifecycle.md`, paideia-os#2244, in progress — this document ratifies its §6 opcode reservation as final). G7-M1-004 (freeze-review record, `pwp-spec-freeze-review.md`, paideia-os#2245, in progress).
**Date:** 2026-09-05.
**Scope:** the PWP wire header, payload alignment, message-size ceiling, transport binding, opcode-numbering discipline, and the request/event opcode table for every G7–G11 primitive landed as of this writing. No KIND catalogue (owned by #2242), no atomic-commit state machine (owned by #2244).

**Dispatch-metadata reconciliation (recorded, not left silent).** This document's dispatch brief named round `G7`/milestone `M8`/slug `G7-M8-001`/file `design/compositor/pwp-wire-framing.md`. The actual GitHub issue #2243 body, and all four sibling documents in this family (`pwp-spec-vocabulary.md` §5, `no-extension-policy.md`, `pwp-version-cadence.md`, `pwp-spec-lifecycle.md` header — the last two landed in this same wave, concurrently with this file), consistently cite this document as `G7-M1-002` at path `design/compositor/pwp-spec-wire.md`. Slug `G7-M8-001` already belongs to a different, closed issue (#2273, T14 hw-smoke-g7.md). This document uses the issue-body/sibling-consistent identity throughout; it does not use the dispatch brief's filename or slug. This mirrors the precedent `pwp-spec-freeze-review.md`'s own header sets for an analogous dispatch/cross-reference mismatch on that sibling.

Related documents (read-only from this doc's viewpoint):
- `design/compositor/pwp-spec-vocabulary.md` §2 (kind catalogue), §3 (derivation graph), §4 (linearity table) — the capability identities this wire names but does not redefine.
- `design/compositor/pwp-spec-lifecycle.md` §2, §5, §6 — the `KIND_PWP_COMMIT_TXN` schema and its provisional opcode reservation, ratified as final at §3.6 below.
- `design/compositor/no-extension-policy.md` — the closed-vocabulary discipline this opcode table is frozen under.
- `design/compositor/pwp-version-cadence.md` §5 — the additive-only field-growth contract §2.3 below wires into the payload layout.
- `design/ipc/userspace-server-substrate.md` §3–§4 — `KIND_IPC_ENDPOINT`'s own framing and per-transfer ceiling, which this wire's frames ride inside.
- `design/roadmap/next-wave-synthesis.md` §4 — pitfalls P1, P2, P4, P6, P10, P11 cited throughout.

---

## §1. Scope & motivation

PWP is the single wire protocol between one compositor process (`svc-compositor`) and every client. This document fixes the byte-level shape every opcode payload is framed in, the numbering discipline that keeps the opcode space closed, and the concrete opcode table the G7–G11 primitives landed so far actually need. It is deliberately narrow: it does not restate KIND semantics (`pwp-spec-vocabulary.md`'s job) and does not restate the commit state machine (`pwp-spec-lifecycle.md`'s job) — it names the bytes and the numbers those two documents' concepts travel as.

The framing exists to answer one question a toolkit author asks first: "given a byte buffer off the wire, how do I find the opcode, how much do I read, and which object does it name?" — in eight bytes, unconditionally, for every message PWP ever carries. Wayland answers the same question in the same eight bytes (§5); PWP keeps that proven shape and changes only the field order and what "opcode" is allowed to mean, for reasons §5 makes precise.

---

## §2. Wire framing

### §2.1 Header (8 bytes, fixed, every frame)

```
offset  field       type    notes
0       opcode      u16 LE  full 16-bit opcode; category is opcode & 0xFF00 (§3.1)
2       length      u16 LE  total frame length in bytes, header included
4       object_id   u32 LE  target KIND_* row id, or 0 (§2.2)
8       payload     —       length-8 bytes; see §2.3
```

`length` is an unsigned 16-bit field: its representable ceiling is 65535 bytes, one byte short of a round 64 KiB. This document uses "64 KiB" only as the colloquial ceiling the issue title uses; the binding number every implementation checks against is **65535**, giving a payload capacity of 65527 bytes. A frame with no payload sets `length = 8` exactly.

### §2.2 `object_id` and the mint bootstrap

`object_id` names the KIND_* row (or `KIND_PWP_COMMIT_TXN`, §2.4) the frame targets — the surface, the commit accumulator, the window, the popup, the txn. It is `0` (reserved, never a live id) on a request that mints a fresh object, since the id does not exist until the compositor assigns it. Every such request carries a `client_nonce:u32` as the first field of its payload; the compositor's corresponding `*_CREATED`/`*_OPENED`/`*_BEGUN`/`*_MAPPED` event echoes `client_nonce` and carries the newly-assigned id in the *event's own* `object_id` header field. Every later frame naming that object uses the assigned id directly. This is the one correlation mechanism the wire needs; it is not opcode-specific.

Field-naming convention used throughout §3: a payload field suffixed `_kind_id` is a bare integer naming an object the recipient already has independent authority over (established by a prior mint reply or by the frame's own `object_id`). A field suffixed `_cap_ref` is an actual capability, transferred via the underlying `KIND_IPC_ENDPOINT`'s cap-grant path alongside the framed bytes (design commitment (d), §4) — never a bare integer a receiver dereferences ambiently.

### §2.3 Payload alignment and additive growth

Every payload begins with a 4-byte prefix — `payload_version:u16 LE`, `payload_size:u16 LE` (total payload bytes, prefix included) — except opcodes with no payload at all (`length == 8`), which omit it. This is the wire-level anchor for `pwp-version-cadence.md` §5 shape 4 (a new field appended past the current size prefix is additive; a reader at an earlier minor truncates at its own compiled `payload_size` and ignores the tail). Every multi-byte field beyond the prefix sits at an offset that is a multiple of its own width (u16 at even offsets, u32 at 4-byte offsets, u64 at 8-byte offsets); every payload's total size, prefix included, is padded to a multiple of 8 bytes. Consequently `length` is always `8`, or `8 + 8k + 4` rounded up to `8 + 8(k+1)` — in practice: always `8` or a multiple of 8 no smaller than 16.

### §2.4 `object_id` width exception — `KIND_PWP_COMMIT_TXN`

`pwp-spec-lifecycle.md` §2 types `txn_id` as a full `u64` (server-assigned, monotonic, unique for the connection's lifetime), wider than the 32-bit `object_id` header field every other kind uses. The four `TXN_COMMIT_*` opcodes (§3.6) resolve this the same way every other mint does: the header's `object_id` carries the low 32 bits of `txn_id` (sufficient in practice — a wraparound needs 2^32 live-or-recent txns on one connection), and the payload's first field after the version/size prefix carries the full 64-bit `txn_id` as the authoritative value. Every other `*_kind_id` in this document is `u32`, matching every landed `.pdx`'s own row-index width (`surface_kind_id`, `window_kind_id`, `commit_txn_id`, `popup_kind_id`, ...).

### §2.5 Transport binding

Every PWP connection is exactly two `KIND_IPC_ENDPOINT` capabilities (`design/ipc/userspace-server-substrate.md` §3), never one bidirectional endpoint:

- **Request endpoint** (client → compositor): client holds `R_IPC_WRITE | R_IPC_INVOKE`; compositor holds `R_IPC_READ | R_IPC_INVOKE`. Carries opcodes `0x0000..0x0FFF` (§3).
- **Event endpoint** (compositor → client): rights reversed. Carries opcodes `0x1000..0x1FFF`.

**No reply-inline.** The compositor never calls `sys_ipc_reply` on the request endpoint. Every response to a request — success, failure, or an unsolicited notification — is a frame on the event endpoint, correlated by `object_id` (§2.2). This applies uniformly, including to the version-tuple handshake (`pwp-version-cadence.md` §4): `PWP_HELLO` is the first request-endpoint frame; `PWP_HELLO_ACCEPT`/`_MAJOR_MISMATCH`/`_MINOR_TOO_NEW` are event-endpoint frames, not an inline reply on the same exchange, keeping the whole protocol — connection setup included — uniformly unidirectional in both directions. (The hello frames themselves are out of this table's scope; they are `pwp-version-cadence.md` §4's.) `pwp-spec-lifecycle.md` §6 describes `commit_begin`/`commit_attach`/`commit_apply`/`commit_abort` as "request/reply-shaped" — that description is the *logical* relationship; §3.6 below pins the wire realization as event-correlated, per this rule, not as an inline reply.

The compositor registers the request endpoint under `svc.compositor` via the standard broker (`design/ipc/userspace-server-substrate.md` §3.3); the event endpoint is minted per-connection at `PWP_HELLO_ACCEPT` time and its capability is granted to the client alongside that event frame — it has no well-known name, since it is per-connection, not a shared service.

### §2.6 Relationship to the `KIND_IPC_ENDPOINT` substrate ceiling

`design/ipc/userspace-server-substrate.md` §4.1–§4.2 caps one `sys_ipc_send`/`sys_ipc_recv` transfer at 4088 payload bytes inside one endpoint's single 4 KiB page (single in-flight message per endpoint at the current substrate revision). A PWP frame whose `length` exceeds that ceiling — legal per §2.1's 65535-byte bound, and expected for e.g. a `DAMAGE_ADD` frame with a long rect list — is segmented across consecutive `sys_ipc_send` calls on the same direction-tagged endpoint and reassembled by the receiver's dispatch loop using the PWP `length` field as the authoritative frame boundary, not any one transfer's `payload_len`. This segmentation is invisible above the PWP client/compositor library boundary, the same way TCP segmentation is invisible above a stream socket; it introduces no continuation opcode and no fragment header, which would itself be exactly the kind of extra wire negotiation design commitment (b) forecloses. Bulk pixel data never rides this path at all — buffer contents move via `buffer_cap_ref` (§2.2, §3.3), never inlined in a frame — so in practice only large `DAMAGE_ADD` rect lists and `A11Y_SUBTREE_ATTACH`-adjacent payloads approach the multi-transfer case.

---

## §3. Opcode table

### §3.1 Assignment discipline

```
0x0000 .. 0x0FFF   client → compositor requests
0x1000 .. 0x1FFF   compositor → client events
0x2000 .. 0xFFFF   RESERVED — no extension ever mints here (no-extension-policy.md §2)
```

Within each half, the high byte selects a category; the low byte selects an opcode within it. Categories mirror 1:1 across the halves — category `N`'s events sit at `0x1N00..0x1NFF` wherever category `N`'s requests sit at `0x0N00..0x0NFF`:

| Range (req / evt)       | Category         |
|--------------------------|------------------|
| `0x0000-0x00FF` / `0x1000-0x10FF` | surface (incl. the cross-cutting txn sub-block, §3.6) |
| `0x0100-0x01FF` / `0x1100-0x11FF` | buffer |
| `0x0200-0x02FF` / `0x1200-0x12FF` | a11y |
| `0x0300-0x03FF` / `0x1300-0x13FF` | ime |
| `0x0400-0x04FF` / `0x1400-0x14FF` | popup |
| `0x0500-0x05FF` / `0x1500-0x15FF` | workspace |
| `0x0600-0x06FF` / `0x1600-0x16FF` | present-feedback |
| `0x0700-0x07FF` / `0x1700-0x17FF` | input-focus |
| `0x0800-0x0FFF` / `0x1800-0x1FFF` | open — next category claimed here at a future minor bump (`pwp-version-cadence.md` §5 shape 3) |

Every opcode assigned below is mandatory at every PWP minor that carries it (`no-extension-policy.md` §3 item 6) — there are no "SHOULD-implement" slots.

### §3.2 Two-tier commit model — reading the table below

Two landed/landing primitives interact and are easy to conflate: `KIND_SURFACE_COMMIT` (`pwp-spec-vocabulary.md` §2.2, landed as `surface_commit.pdx`) is a **per-surface** accumulator — mint it, accumulate buffer/damage/geometry, flush it — and is fully self-sufficient for a single-surface update. `KIND_PWP_COMMIT_TXN` (`pwp-spec-lifecycle.md` §2, not yet landed) is an **outer envelope** that batches N already-accumulated per-object changes (across surfaces, and across non-surface classes: workspace switch, focus, a11y, IME) into one atomic apply-or-abort. A client updating one ordinary surface never touches the txn opcodes at `0x00F0-0x00F3`; a client that needs several objects to land in the same frame does. Once a `KIND_SURFACE_COMMIT` is attached to an open txn (`TXN_COMMIT_ATTACH`, change class `surface_commit`), a direct `SURFACE_COMMIT_FLUSH` against that same `commit_txn_id` is refused (`SURFACE_COMMIT_OWNED_BY_TXN`) — the two paths are mutually exclusive per accumulator, exactly as `pwp-spec-lifecycle.md` §5's "transferring its ownership without consuming it yet" implies.

### §3.3 Request table (client → compositor, `c→s`)

| Opcode | Dir | Name | Args (payload, after version/size prefix) | Returns via |
|--------|-----|------|---------|-------------|
| `0x0000` | c→s | `SURFACE_CREATE` | `color_profile_id:u32`, `client_nonce:u32` | `0x1000 SURFACE_CREATED` |
| `0x0001` | c→s | `SURFACE_COMMIT_OPEN` | (`object_id`=surface_kind_id), `client_nonce:u32` | `0x1001 SURFACE_COMMIT_OPENED` |
| `0x0002` | c→s | `DAMAGE_ADD` | (`object_id`=commit_txn_id), `rect_count:u16`, `rects[](x,y,w,h):u16×4×N` | n/a — accumulates on the open commit; visible at flush |
| `0x0003` | c→s | `SURFACE_COMMIT_FLUSH` | (`object_id`=commit_txn_id) | `0x1600 PRESENT_FEEDBACK` (ok) / `0x1002 SURFACE_COMMIT_REFUSED` (fail) |
| `0x0004` | c→s | `SURFACE_DESTROY` | (`object_id`=surface_kind_id) | `0x1003 SURFACE_DESTROYED` |
| `0x0100` | c→s | `BUFFER_ATTACH` | (`object_id`=commit_txn_id), `buffer_cap_ref`, `wait_timeline_id:u32`, `wait_value:u64`, `signal_timeline_id:u32`, `signal_value:u64`, `damage_hint:u32` | n/a — accumulates; recycle signal rides `signal_timeline`, out-of-band |
| `0x0200` | c→s | `A11Y_SUBTREE_ATTACH` | (`object_id`=window_kind_id), `a11y_tree_cap_ref`, `client_nonce:u32` | `0x1200 A11Y_SUBTREE_ATTACHED` |
| `0x0300` | c→s | `IME_PROVIDER_BIND` | (`object_id`=session_kind_id), `lang_tag:u32` | `0x1300 IME_PROVIDER_BOUND` |
| `0x0400` | c→s | `POPUP_MAP` | `parent_window_kind_id:u32`, `anchor(x,y,w,h):i16×4`, `anchor_edge:u8`, `gravity:u8`, `offset(dx,dy):i16×2`, `seat_kind_id:u32`, `grab_serial:u32`, `client_nonce:u32` | `0x1400 POPUP_MAPPED` |
| `0x0401` | c→s | `POPUP_DISMISS` | (`object_id`=popup_kind_id) | `0x1401 POPUP_DISMISSED` |
| `0x0500` | c→s | `WORKSPACE_SWITCH_REQUEST` | (`object_id`=output_kind_id), `from_ws:u32`, `to_ws:u32`, `txn_id:u64` (0 = apply immediately) | `0x1500 WORKSPACE_SWITCHED` |
| `0x0600` | c→s | `PRESENT_FEEDBACK_REQUEST` | (`object_id`=surface_kind_id), `subscribe:u8` | `0x1600 PRESENT_FEEDBACK` (streamed) |
| `0x0700` | c→s | `FOCUS_REQUEST` | (`object_id`=window_kind_id), `seat_kind_id:u32`, `txn_id:u64` (0 = immediate) | `0x1700 FOCUS_GRANTED` / `0x1701 FOCUS_REFUSED` |
| `0x00F0` | c→s | `TXN_COMMIT_BEGIN` | `slack_frames:u8` (0-3), `client_nonce:u32` | `0x10F0 TXN_BEGUN` |
| `0x00F1` | c→s | `TXN_COMMIT_ATTACH` | (`object_id`=txn_id low32), `txn_id:u64`, `change_class:u8` (§3.6), `staged_ref:u32` | `0x10F1 TXN_ATTACHED` |
| `0x00F2` | c→s | `TXN_COMMIT_APPLY` | (`object_id`=txn_id low32), `txn_id:u64` | `0x10F2 TXN_APPLIED` |
| `0x00F3` | c→s | `TXN_COMMIT_ABORT` | (`object_id`=txn_id low32), `txn_id:u64` | `0x10F3 TXN_ABORTED` |

`0x0800-0x0EFF` and `0x00F4-0x00FF` are open within the request half — the former for a future category, the latter as headroom `pwp-spec-lifecycle.md` §6 explicitly reserved for additive txn-lifecycle growth.

### §3.4 Event table (compositor → client, `s→c`)

| Opcode | Dir | Name | Fields (payload, after version/size prefix) | Terminal? |
|--------|-----|------|---------|-----------|
| `0x1000` | s→c | `SURFACE_CREATED` | `client_nonce:u32`, `surface_kind_id:u32` (new object_id) | terminal |
| `0x1001` | s→c | `SURFACE_COMMIT_OPENED` | `client_nonce:u32`, `commit_txn_id:u32` (new object_id) | terminal |
| `0x1002` | s→c | `SURFACE_COMMIT_REFUSED` | `reason:u32` (`ALREADY_FLUSHED` / `OWNED_BY_TXN` / `BAD_TIMELINE` / ...) | terminal |
| `0x1003` | s→c | `SURFACE_DESTROYED` | (`object_id`=surface_kind_id that died) | terminal |
| `0x1200` | s→c | `A11Y_SUBTREE_ATTACHED` | `tree_kind_id:u32`, `status:u32` | terminal |
| `0x1300` | s→c | `IME_PROVIDER_BOUND` | `provider_kind_id:u32`, `status:u32` | terminal |
| `0x1301` | s→c | `IME_COMMIT_STRING` | (`object_id`=session_kind_id), `commit_seq:u64`, `text_offset:u32`, `text_len:u32` | terminal per composition round |
| `0x1400` | s→c | `POPUP_MAPPED` | `client_nonce:u32`, `popup_kind_id:u32` (new object_id), `placed_rect(x,y,w,h):i16×4` | terminal |
| `0x1401` | s→c | `POPUP_DISMISSED` | `dismiss_cause:u32` (explicit / outside-click / parent-destroyed) | terminal (fans out along the dismiss chain) |
| `0x1500` | s→c | `WORKSPACE_SWITCHED` | `switch_seq:u64`, `to_ws:u32` | terminal; broadcast to every surface bound on the affected output |
| `0x1600` | s→c | `PRESENT_FEEDBACK` | (`object_id`=surface_kind_id), `target_time:u64`, `actual_time:u64`, `refresh_period:u64`, `present_id:u64`, `classification:u8` (0=`ON_TIME`,1=`LATE`,2=`DROPPED`,3=`VBLANK`) | not terminal — repeats every present until unsubscribe/destroy |
| `0x1700` | s→c | `FOCUS_GRANTED` | (`object_id`=window_kind_id), `route_kind_id:u32` (new `KIND_INPUT_ROUTE`), `seat_kind_id:u32` | terminal |
| `0x1701` | s→c | `FOCUS_REFUSED` | (`object_id`=window_kind_id), `reason:u32` | terminal |
| `0x10F0` | s→c | `TXN_BEGUN` | `client_nonce:u32`, `txn_id:u64` (new object_id, low32 mirrored in header), `frame_deadline:u64` | terminal |
| `0x10F1` | s→c | `TXN_ATTACHED` | `status:u32` (`OK` / `TXN_SURFACE_BUSY` / `TXN_DEADLINE_MISSED`, per `pwp-spec-lifecycle.md` §3.2/§3.3) | terminal |
| `0x10F2` | s→c | `TXN_APPLIED` | `status:u32` (`APPLIED` / a per-change validation failure sentinel) | terminal |
| `0x10F3` | s→c | `TXN_ABORTED` | `cause:u32` (explicit / `DEADLINE_MISSED`) | terminal |

### §3.5 A11y note — no per-frame opcode

Per-frame accessibility-tree deltas are **not** a separate opcode. `pwp_a11y_wire.pdx` (#2306) already lands the design: a 32-byte inline payload rides attached to every `SURFACE_COMMIT_FLUSH` (or, batched, to `TXN_COMMIT_APPLY`) frame, so the tree mutation and the pixel commit apply under the same atomic boundary — never as two messages that could race. `A11Y_SUBTREE_ATTACH` (`0x0200`) covers only the rarer one-shot bind of a toolkit-authored tree at window creation (`a11y_bind_at_mint.pdx`, #2305); the common case (compositor autobinds an empty tree at mint) never touches the wire at all. This wire-level fact is itself an anti-Wayland commitment — see §4.

### §3.6 Ratifying the `pwp-spec-lifecycle.md` §6 reservation

`pwp-spec-lifecycle.md` §6 reserves `0x00F0-0x00FF` for `KIND_PWP_COMMIT_TXN` lifecycle opcodes and explicitly grants this document renumbering authority before landing. §3.3/§3.4 above accept that reservation **as final, unchanged** — `commit_begin`→`TXN_COMMIT_BEGIN` (`0x00F0`), `commit_attach`→`TXN_COMMIT_ATTACH` (`0x00F1`), `commit_apply`→`TXN_COMMIT_APPLY` (`0x00F2`), `commit_abort`→`TXN_COMMIT_ABORT` (`0x00F3`). These four are cross-cutting (they gate workspace/focus/a11y/IME changes, not only surface state) despite sitting in the surface category's numeric range; that placement is kept rather than moved to a dedicated category, since `0x0800-0x0FFF` remains fully open for the next real category and moving four already-reserved slots for numbering symmetry alone is not a correctness or headroom concern. The `change_class` enum in `TXN_COMMIT_ATTACH`'s payload is `0=surface_commit, 1=buffer_attach, 2=damage, 3=geometry, 4=workspace_switch, 5=focus_router, 6=a11y_subtree, 7=ime_provider_bind`, verbatim from `pwp-spec-lifecycle.md` §5's eight change classes; values `8-255` are open for additive minor-bump classes.

---

## §4. Anti-Wayland design commitments

**(a) No extension mechanism.** There is no `wl_registry`-equivalent runtime enumeration and no per-interface opcode namespace. Opcode meaning is global and closed (§3.1); `xdg_*` / `wp_*` / vendor-prefixed globals have no landing surface on this wire at all. Enforced at the framing layer: a frame naming an opcode outside the current minor's table is a parse-time protocol violation, not an "unrecognised extension, skip." See `no-extension-policy.md` §2, §5.

**(b) No protocol negotiation.** The only capability-negotiation channel is the single `(major, minor)` tuple at connection setup (`pwp-version-cadence.md` §4); §2.5 above confirms even that handshake obeys the same "reply is an event" discipline as every other exchange, so there is no separate wire shape for connection setup versus steady-state traffic. There is no in-band feature probe opcode anywhere in §3.

**(c) Atomic-commit lifecycle is a first-class KIND, not a per-request state machine.** `KIND_SURFACE_COMMIT` and `KIND_PWP_COMMIT_TXN` (§3.2, #2244) are capabilities with an explicit mint→accumulate→flush/apply lifecycle enforced by the LINEAR discipline itself, not a `pending`/`current` double-buffered state machine living as mutable fields on a persistent object (contrast Wayland's `wl_surface`, which carries pending state as ambient mutable fields the client can only reason about via the spec text, not the type). A PWP client cannot double-commit or read torn pending state because the accumulator capability that would let it do either is consumed at flush.

**(d) All state changes flow through cap-mint, not mutable per-object state.** Every wire mutation targets either a freshly-minted LINEAR capability (`KIND_SURFACE_COMMIT`, `KIND_PWP_COMMIT_TXN`, `KIND_INPUT_ROUTE`, `KIND_IME_SESSION`) or an explicit capability transfer (`*_cap_ref` fields, §2.2) — never a bare "set field X on object Y" opcode against ambient shared state. `DAMAGE_ADD`/`BUFFER_ATTACH` look like field-setters but are not: both target the object_id of a LINEAR accumulator that exists only between `SURFACE_COMMIT_OPEN` and its flush, and both are void once that accumulator is consumed.

**(e) A11y rides inline with the pixel commit, never as a sidecar protocol.** §3.5's inline-payload design is the wire-level enforcement of pitfall P4 (`pwp-spec-vocabulary.md` §2.21, `pwp_a11y_wire.pdx` #2306): there is no independent "a11y update" opcode a screen reader's frame could race against the pixel frame it describes, unlike AT-SPI's out-of-band D-Bus channel alongside Wayland's `wl_surface.commit`.

---

## §5. Rationale + citations

**Wayland's wire header — the proven shape, retained.** Wayland's message header is `[object_id:u32][opcode:u16][size:u16]` — object id first, then a packed opcode+size word, 8 bytes total, unchanged since 2008 and never a source of Wayland's interop problems. PWP keeps the same three fields and the same 8-byte footprint (§2.1) but reorders them: `[opcode:u16][length:u16][object_id:u32]`, opcode first. This is not cosmetic. In Wayland, an opcode is only meaningful *relative to the object's bound interface* — opcode `0` means something different on every interface, and interface identity is resolved dynamically through `wl_registry`. That per-interface opcode indirection is precisely the mechanism that makes an extension "free" to define: a new interface simply owns its own opcode-0-upward space, with no central registry to reserve a number in. PWP's opcode-first header is the structural expression of the opposite decision: one 16-bit number, meaningful *without* first resolving `object_id` to anything, drawn from one closed, monopoly-numbered table (§3.1). There is no interface layer left for an extension to attach a private opcode space to. The field reorder is the anti-extension-mechanism commitment, made visible in the byte layout itself, not merely asserted in policy text.

**Wayland's extension mechanism — the failure mode retired.** `no-extension-policy.md` §6.1 already catalogues the ~100+ `wp-*`/`zwp-*`/`xdg-*`/vendor-prefixed protocols Wayland accumulated by 2025, the per-compositor implementation-subset problem, and the "renamed at v2" episode (`wp-linux-explicit-synchronization-v1` → `linux-drm-syncobj-v1`). This document's opcode table is the wire-level artifact that makes the "closed vocabulary" commitment concrete and auditable: `git log` on §3's tables is the complete history of every wire-visible capability PWP has ever carried, mirroring the auditability property `no-extension-policy.md` §4.1 claims.

**[[project_novel_clean_design]] posture.** PaideiaOS's standing bias is to prefer a novel, research-grounded design over inherited POSIX/Wayland/X11 shape and to retire frozen decisions rather than preserve them for compatibility's sake. This document exercises that bias twice: reordering a 17-year-stable wire header field for a structural reason (above), and choosing an explicit two-tier commit-capability model (§3.2) over Wayland's implicit double-buffered pending state, at the cost of one extra mint call per surface update that a client library amortizes once and every caller never sees again.

---

## §6. Consumers

Opcodes are traceable to the landed (or, for `TXN_*`, landing-in-this-wave) `.pdx`/design-doc source that defines the capability each frame ultimately targets:

| Category | Opcodes | Source |
|----------|---------|--------|
| surface | `0x0000-0x0004`, `0x1000-0x1003` | `src/user/compositor/surface_kind.pdx` (G7-M2-001, #2246), `surface_commit.pdx` (G7-M2-002, #2248), `surface_geometry.pdx` (G7-M2-003, #2250) |
| surface / buffer | `0x0100`, `0x1100` (open) | `src/user/compositor/surface_buffer_bind.pdx` (#2252) |
| surface / damage | `0x0002` | `src/user/compositor/damage_kind.pdx` (#2294, G9) |
| txn (surface sub-block) | `0x00F0-0x00F3`, `0x10F0-0x10F3` | `design/compositor/pwp-spec-lifecycle.md` (G7-M1-003, #2244) — `KIND_PWP_COMMIT_TXN`, not yet landed as `.pdx` |
| a11y | `0x0200`, `0x1200`, inline commit payload (§3.5) | `src/user/compositor/a11y_bind_at_mint.pdx` (#2305), `pwp_a11y_wire.pdx` (#2306), `src/user/a11y/tree_kind.pdx` (G10-M1-001, #2302) |
| ime | `0x0300`, `0x1300`, `0x1301` | `src/user/ime/session_kind.pdx` (G11-M1-001, #2314), `provider_kind.pdx` (G11-M2-001, #2315), `src/user/compositor/ime_router.pdx` (G11-M3-001, #2316) |
| popup | `0x0400-0x0401`, `0x1400-0x1401` | `src/user/compositor/xdg_shell_popup.pdx` (#2265), `window_kind.pdx` (G7-M3-001, #2254) |
| workspace | `0x0500`, `0x1500` | `src/user/compositor/workspace_kind.pdx` (G9-M1-001, #2288), `workspace_switch.pdx` (#2289) |
| present-feedback | `0x0600`, `0x1600` | `src/user/compositor/present_feedback_kind.pdx` (#2297), `present_feedback_classifier.pdx` (#2299) |
| input-focus | `0x0700`, `0x1700-0x1701` | `src/user/input_server/focus_router.pdx` (G8-M2-002, #2278), `route_kind.pdx` (G8-M2-001) |

Every row above is a G7–G11 landing this document's opcode table makes wire-addressable for the first time — none of the cited `.pdx` files are themselves wired into `cap_invoke_dispatch` from the PWP wire yet; that wiring is the future `svc-compositor` reference-implementation landing this freeze surface exists to unblock.

---

*End of wire framing + opcode table. Vocabulary index at #2242 (landed); atomic-commit lifecycle at #2244; freeze-review sign-off gate at #2245.*
