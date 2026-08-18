# PaideiaOS -- IPC Schema: `audio_routing_channel`

**Status:** Design v1.0 (kernel-side schema + packers landed; wire framing
deferred -- see §7)
**Date:** 2026-08-18
**Round:** R33.M5-001 (issue #1157)
**Companion:** `design/roadmap/next-wave-softarch.md` §3 R33.M5,
`design/ipc/pcm-ring-channel-schema.md` (peer session-typed channel),
`src/kernel/core/ipc/audio_routing_channel.pdx` (this schema, in code),
`src/kernel/core/cap/kind_audio_route.pdx` (the row this channel narrates),
`src/user/audio_supervisor.pdx` (the ring-3 process that owns this endpoint).

---

## 1. Purpose

`audio_routing_channel : Channel(AudioRoutingChannelSchema)` is the endpoint
the audio supervisor speaks to when a client asks it to establish, tear
down, or modulate ONE routing edge in the audio graph. Four RPCs exist and
no more:

- **`CREATE_ROUTE`** (RPC): one request naming `(source_stream_slot,
  dest_pcm_slot, gain_q15, mute)`; the supervisor mints a
  `KIND_AUDIO_ROUTE` capability on behalf of the caller and returns its
  slot in the ack.
- **`DESTROY_ROUTE`** (RPC): one request naming `route_slot`; the
  supervisor revokes the route.
- **`SET_GAIN`** (RPC): one request naming `(route_slot, new_gain_q15)`;
  the supervisor asks the kind to update the row's gain.
- **`SET_MUTE`** (RPC): one request naming `(route_slot, new_mute)`; the
  supervisor asks the kind to update the row's mute bit.

Three properties motivate the whole schema:

1. **Every request and every reply is one `u64`.** A reply that spans
   multiple words has an ordering across words that the wire must
   preserve; a one-word reply is atomic against every reader that reads
   it as a word. §3 states the bit layout.

2. **The channel carries the effect row `!{audio_route_mint,
   audio_route_report}`.** `CREATE_ROUTE` and `DESTROY_ROUTE` need the
   supervisor's `RIGHT_MINT`/`RIGHT_REVOKE` over `KIND_AUDIO_ROUTE`;
   `SET_GAIN`/`SET_MUTE` need the client's own capability to carry
   `RIGHT_REPORT`. The distinction is an authority decision the
   supervisor holds against its own capability set -- not encoded on
   the wire, because encoding it would let a client claim authority it
   did not receive.

3. **The channel narrates a CONNECTIVITY relationship. It does NOT
   carry PCM samples.** Samples cross the ring named by each
   participating `KIND_PCM_STREAM`; the routing channel decides WHICH
   producer's samples reach WHICH consumer at what mixer level, no more
   and no less. A subscriber that receives a `SET_GAIN` ack and infers
   its stream has audio has invented an authority the schema does not
   carry.

---

## 2. Endpoint and direction

- **Server:** `audio_supervisor` -- the userspace process that holds
  `R_AUDIO_ROUTE_ALL` over the set of `KIND_AUDIO_ROUTE` capabilities
  currently minted (initially none) and `RIGHT_MINT` over
  `KIND_IPC_ENDPOINT` for the routing endpoint it publishes.
- **Clients:** any process holding a subscription handle. A subscription
  handle carries neither `R_AUDIO_ROUTE_MINT` nor `RIGHT_MINT`, so a
  client cannot mint its own route through the same channel it modulates
  one.
- **RPC direction:** request/reply, one-shot. All four ops are one
  round-trip.
- **Event direction:** none at R33.M5. A future milestone may add a
  sibling channel for xrun/underflow notifications along the routes;
  today the pcm_ring_channel §XRUN_NOTIFY already carries that signal
  at the stream level and no analogue exists at the route level.
- **Substrate at R33.M5:** the schema (this document + its `.pdx`
  companion), the userspace supervisor process (`src/user/audio_supervisor.pdx`),
  and its endpoint id (`5`, sidecar-seeded). The compositor-facing wire
  half is deferred (§7).

---

## 3. Bit layout

### 3.1 `CREATE_ROUTE` request (op `0x20`, one word)

```
bits    63:48     47:32       31:24        23:16      15:8         7:0
        reserved  gain_q15    mute[0]      dest_slot  source_slot  op=0x20
```

Reserved bits [63:48] are refused by the packer AND by the unpacker per
§5. `source_slot` and `dest_slot` must not equal each other (the SELF_LOOP
refusal happens at the kind's mint, not at the packer). `gain_q15` is a
signed 16-bit fixed-point value in the range `[-32768, +32767]`.

### 3.2 `DESTROY_ROUTE` request (op `0x21`, one word)

```
bits    63:16     15:8         7:0
        reserved  route_slot   op=0x21
```

### 3.3 `SET_GAIN` request (op `0x22`, one word)

```
bits    63:32     31:16      15:8         7:0
        reserved  gain_q15   route_slot   op=0x22
```

### 3.4 `SET_MUTE` request (op `0x23`, one word)

```
bits    63:17     16         15:8         7:0
        reserved  mute       route_slot   op=0x23
```

### 3.5 Replies (op `0xF0..0xF3`)

```
CREATE_ACK   op = 0xF0  { route_slot[15:8], status[63:16] }
DESTROY_ACK  op = 0xF1  { status[63:8] }
SET_GAIN_ACK op = 0xF2  { status[63:8] }
SET_MUTE_ACK op = 0xF3  { status[63:8] }
```

Op ordinals for requests occupy `0x20..0x23`; replies `0xF0..0xF3` so a
dispatcher switching on the byte cannot route a reply as a request.

---

## 4. Effect row and capability discipline

The session type is:

```
audio_routing : Channel {
  !{ audio_route_mint, audio_route_report }
  { create_route(src, dst, gain, mute),
    destroy_route(route),
    set_gain(route, gain),
    set_mute(route, mute) }*
}
```

The `!{audio_route_mint, audio_route_report}` effect row names the two
authorities the session CARRIES: the supervisor's mint authority (for
`CREATE_ROUTE`/`DESTROY_ROUTE`) and the client's report authority (for
`SET_GAIN`/`SET_MUTE`, both of which change a row's dynamic state).

---

## 5. Reserved bits are refused, never masked

Every packed frame has RESERVED bit ranges. The packers refuse a payload
with any set. Same argument as `codec_query_channel` §2 and
`pcm_ring_channel` §2.

---

## 6. Refuse, never clamp

- `source_slot` or `dest_slot` not in `[0, 255]` -> `BAD_SLOT`.
- `gain_q15` not in `[-32768, +32767]` -> `BAD_GAIN` (packer refuses; the
  kind's own validator refuses the identical set of values).
- `mute` not in `{0, 1}` -> `BAD_MUTE`.
- Unknown op -> `BAD_OP`.

Clamping would erase the distinction between "the caller asked for a
value in range" and "the packer decided a value for them".

---

## 7. Deferrals

- **Wire framing.** The kernel schema lands the pack/unpack + validator
  discipline; the actual cross-process endpoint (`svc.audio_routing`)
  publishes at R33.M5-001 via the `audio_supervisor` userspace process,
  but the compositor-side wire half connecting to it is scaffolded and
  the observable seam is the schema round-trip.
- **Bulk route mutation.** No `CREATE_MANY` or `DESTROY_MANY`; a
  compositor that wants to tear down N routes calls `DESTROY_ROUTE` N
  times. A bulk op would need its own reply shape and its own audit
  discipline; the four one-at-a-time ops are sufficient for the R33
  audio graph.
- **XRUN / UNDERRUN events.** These belong on the pcm_ring_channel per
  its `XRUN_NOTIFY` op; nothing about the routing edge is what
  underflows.

---

## 8. Error codes `0xFFFFFCA0..0xFFFFFCAF`

Disjoint from `PCM_RING_*` (0xFFFFFCB0..BF) and every other channel band.
