# PaideiaOS — IPC Schema: `codec_query_channel`

**Status:** Design v1.0 (kernel-side schema + packers landed; wire framing and server deferred — see §7)
**Date:** 2026-08-18
**Round:** R33.M2-005 (issue #1146)
**Companion:** `src/kernel/core/ipc/codec_query_channel.pdx` (this schema, in code), `src/kernel/core/drivers/hda/verbs.pdx` (per-verb wrappers this channel dispatches to on the server side), `src/kernel/core/drivers/hda/widget_graph.pdx` and `src/kernel/core/drivers/hda/pin_config.pdx` (the two typed records the GET operations enumerate against), `src/kernel/core/cap/kind_audio_controller.pdx` (the row a supervisor holds when mediating this channel).

---

## 1. Purpose

`codec_query_channel : Channel(CodecQueryChannelSchema)` is the endpoint an audio server (or a diagnostic supervisor) speaks to when it wants to enumerate an Intel HDA codec's widgets and pins, or to install a per-widget control (pin control byte, amp gain, amp mute). Five RPCs exist and no more:

- **`GET_WIDGETS`** (RPC): one request naming a codec address, one reply carrying the count of widget rows the driver has populated for that codec. The reply is a scalar count; enumeration of individual widget records goes through the widget-graph read seams (`hda_widget_graph_row_*`) on the SERVER side, which the client reaches through its own capability. A single-scalar reply keeps this channel's frame at one `u64`.
- **`GET_PINS`** (RPC): one request, one reply — the count of pin-complex widgets (widget_type = `HDA_WG_TYPE_PIN_COMPLEX` = 4) among the codec's rows. Same shape as `GET_WIDGETS`.
- **`SET_PIN_CTL`** (RPC): one request carrying `(codec_addr, node_id, ctl_byte)`. Dispatches to `hda_verb_set_pin_ctl` on the server side. Reply is a status ack.
- **`SET_GAIN`** (RPC): one request carrying `(codec_addr, node_id, gain, side)`. Dispatches to `hda_verb_set_amp_gain` with an appropriately-packed 16-bit payload. Reply is a status ack.
- **`SET_MUTE`** (RPC): one request carrying `(codec_addr, node_id, mute_bit, side)`. Dispatches to `hda_verb_set_amp_gain` with the mute bit set. Reply is a status ack.

No events. Codec state changes (unsolicited responses per HDA §7.3.6) will land in a sibling channel when R33.M4 plumbs them.

Three properties motivate the whole schema:

1. **Every request and every reply is one `u64`.** A reply that spans multiple words has an ordering across words a consumer must preserve; a one-word reply is atomic against every reader that reads it as a word. §3 documents the bit layout.

2. **The channel carries the effect row `!{codec_read, codec_write}`.** The three SET operations require `codec_write`; the two GET operations require `codec_read` only. The distinction is a session-authority decision the audio-server holds against its own capability set — not encoded on the wire, because encoding it would let a client claim authority it did not receive.

3. **The channel narrates a QUERY / CONFIGURE relationship. It does not read verb responses directly and it does not own the widget graph.** The server-side handlers dispatch to `hda_verb_*` (which today return `DEFERRED_HARDWARE` — see `verbs.pdx` §4) and `hda_widget_graph_row_*` (which today reads a table populated by whatever binds it — see `widget_graph.pdx` §4). A subscriber that receives a reply and infers the codec has moved has invented an authority the schema does not carry.

## 2. Endpoint and direction

- **Server:** the audio server (a userspace supervisor holding `R_CODEC_READ | R_CODEC_WRITE` over one or more `KIND_AUDIO_CONTROLLER` capabilities, absent at R33.M2).
- **Clients:** any process holding a subscription handle. The handle carries neither `R_CODEC_WRITE` nor `RIGHT_MINT`, so a client cannot install a control through the handle it queries state on unless the mint policy granted both.
- **RPC direction:** request/reply, one-shot. All five ops are one round-trip.
- **Event direction:** none. R33.M4 (`unsolicited responses`) will add a sibling channel for jack-detect / codec-side interrupts.
- **Substrate at R33.M2:** the schema (this document + its `.pdx` companion). A cross-process endpoint is deferred (§7).

## 3. Bit layout

### 3.1 GET_WIDGETS request (op 0x01, one word)

```
bits    63:16       15:8         7:0
        ├──────────┼───────────┼───────────┤
value   reserved   codec_addr   op = 0x01
```

Reserved bits [63:16] are refused by the packer AND by the unpacker per §5. `codec_addr` is bounded to `[0, 15]` (per HDA §7.3).

### 3.2 GET_PINS request (op 0x02, one word)

Same shape as GET_WIDGETS with op = 0x02.

### 3.3 SET_PIN_CTL request (op 0x03, one word)

```
bits    63:32     31:24     23:16     15:8         7:0
        ├────────┼─────────┼─────────┼───────────┼───────────┤
value   reserved  ctl_byte  node_id   codec_addr  op = 0x03
```

`ctl_byte` is the u8 pin control register value (per HDA §7.3.3.13: bit 5 = out_enable, bit 6 = hp_enable, bit 7 = in_enable, bits [4:0] = VRef select). No semantic gate here — the register accepts any of the 256 patterns and imposes its own consistency at read; the packer's job is width, not policy.

### 3.4 SET_GAIN request (op 0x04, one word)

```
bits    63:32     31       30:24   23:16     15:8         7:0
        ├────────┼────────┼───────┼─────────┼───────────┼───────────┤
value   reserved  side     gain    node_id   codec_addr  op = 0x04
```

`gain` is a 7-bit field (per HDA §7.3.3.7). `side` is 1 bit (0 = left, 1 = right). The server-side handler packs a 16-bit payload combining `gain` with the appropriate direction/side/index bits and dispatches to `hda_verb_set_amp_gain`.

### 3.5 SET_MUTE request (op 0x05, one word)

```
bits    63:26     25     24     23:16     15:8         7:0
        ├────────┼──────┼──────┼─────────┼───────────┼───────────┤
value   reserved  side   mute   node_id   codec_addr  op = 0x05
```

`mute` is 1 bit (0 = unmute, 1 = mute). `side` is 1 bit.

### 3.6 GET_WIDGETS / GET_PINS reply (one word)

```
bits    63:32     31:8      7:0
        ├────────┼─────────┼───────────┤
value   reserved  count     op (echoed: 0x01 or 0x02)
```

`count` is a 24-bit field, ceiling `2^24`. A codec with more than 16M widgets is beyond the spec's addressable node space (u8) — the ceiling is deliberately loose so a future spec revision can widen without a schema version bump on the count field alone.

### 3.7 SET_ACK reply (op 0xF0, one word)

```
bits    63:8       7:0
        ├─────────┼───────────┤
value   status     op = 0xF0
```

`status` is a 56-bit code. The three SET RPCs share one ack shape; the ack's op byte is `0xF0`, distinct from the request op block `0x01..0x05`, so a dispatcher switching on the byte cannot route a reply as a fresh request.

## 4. Refuse, never clamp

The packers enforce every field's width EXACTLY:

- `codec_addr` outside `[0, 15]` → `BAD_ADDR`.
- `node_id` outside `[0, 255]` → `BAD_NODE`.
- `ctl_byte` outside `[0, 255]` → `BAD_PAYLOAD`.
- `gain` outside `[0, 127]` → `BAD_PAYLOAD`.
- `side` outside `{0, 1}` → `BAD_PAYLOAD`.
- `mute_bit` outside `{0, 1}` → `BAD_PAYLOAD`.
- `count` outside `[0, 2^24)` → `BAD_COUNT`.
- Any reserved bit non-zero on the unpacker path → `BAD_RESERVED`.

The alternative — silent truncation — has different consequences per field. A truncated `codec_addr` would let a caller submit a `SET_MUTE` to address 0 while thinking they were addressing 16; a truncated `gain` would silently drop bit 7 from a value of 128, halving the intended attenuation and rendering an amplifier that hushes an output the user expected loud.

## 5. Reserved bits are refused, not masked

Same discipline as `hid_event_stream_channel.pdx` §2 and `sensor_read_channel.pdx` §2: a reserved field that a receiver silently masks is a field a later revision cannot use. A `SET_PIN_CTL` frame with 32 free bits in the upper half is where a caller-supplied VRef override, or a per-verb "post-write GET" flag, would be smuggled without a schema version bump.

## 6. Error taxonomy (0xFFFFFCC0..CF)

Sixteen-wide, disjoint from every other in-tree band. Placed inside the HDA cluster (`0xFFFFFC40..CF`) deliberately — this schema narrates codec state, and a code threaded up through the RPC path can name which HDA subsystem produced it. `Verbs` occupies `0xFFFFFCB0..BF`, `WidgetGraph` occupies `0xFFFFFC90..9F`, `PinConfig` occupies `0xFFFFFCA0..AF`, `CodecDiscovery` occupies `0xFFFFFC80..8F`.

## 7. Deferrals

None of the following is in this milestone's scope:

- **No server.** No process holds this channel at R33.M2. When the audio-server substrate lands (R33.M4 or later), the packers and unpackers here are what the two ends will exchange.

- **No unsolicited-response channel.** Jack-detect events, codec-side interrupts, and hot-plug transitions all arrive as unsolicited RIRB responses (HDA §7.3.6). These will live in a sibling channel with a `0x8x` event ordinal block; adding events to `codec_query_channel` would break the "no events" invariant this schema depends on to keep its dispatcher simple.

- **No batch / streaming form of GET_WIDGETS.** The scalar-count reply forces a client that wants per-widget details to make one round-trip per widget (through `hda_widget_graph_row_*` on the server side, mediated by a KIND_AUDIO_CONTROLLER capability). A batched form would need multi-word replies and is a straightforward extension when a live driver populates the graph and a compositor's needs justify the wire-frame complexity.

- **No `GET_PIN_CFG` op.** The `default_cfg` register decoded by `pin_config.pdx` is a per-pin, one-shot value; a `GET_PIN_CFG` op would either take a `node_id` (widening the schema) or bundle the reply with `GET_PINS` (breaking one-word replies). Both are legitimate designs and both belong in R33.M3 with the live driver, not R33.M2.

- **No effect-row enforcement.** The `!{codec_read, codec_write}` effect row on the session is a design-time annotation; paideia-as does not yet type-check effect rows on cross-process channels. The audio-server-side handler will hold the enforcement when the server lands; today the schema documents the discipline the server will implement.
