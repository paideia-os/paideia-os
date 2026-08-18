# PaideiaOS — IPC Schema: `hid_event_stream`

**Status:** Design v1.0 (kernel-side schema + packers landed; wire framing
and endpoint substrate deferred — see §7)
**Date:** 2026-08-17
**Round:** R32.M3-004 (issue #1128)
**Companion:** `design/ipc/backlight-channel-schema.md` (sibling one-word
schema), `src/kernel/core/ipc/hid_event_stream_channel.pdx` (this schema,
in code), `src/kernel/core/drivers/hid/event_stream.pdx` (the fanout the
schema narrates, #1127), `src/kernel/core/cap/kind_hid_event.pdx` (the
subscription record a subscriber holds).

---

## 1. Purpose

`hid_event_stream : Channel(HidEventStreamSchema)` is the FANOUT that
every HID producer publishes into and every HID subscriber observes
from. Four stream events exist and no more today:

- **`KBD_PRESS`** (event): a key transitioned from released to
  pressed. Payload: `scancode` (16 bits).
- **`KBD_RELEASE`** (event): a key transitioned from pressed to
  released. Payload: `scancode` (16 bits).
- **`MOUSE_MOVE`** (event): a pointer delta was reported. Payload:
  `dx`, `dy` as signed 16-bit ordinals, both bounded by INT16.
- **`MOUSE_CLICK`** (event): a mouse button changed state. Payload:
  `button` (8 bits), `edge` (0 = release, 1 = press).

Three properties motivate the whole schema:

1. **Every payload is one `u64`.** A payload that spans multiple words
   carries an ordering across words a receiver must preserve; a
   one-word payload is atomic against every reader that reads it as
   a word. §3 documents the bit layout.

2. **The event type is in the HIGH byte.** A dispatcher switching on
   the type byte cannot accidentally route a scancode value or a
   button number as an event type without crossing the `0x80` line
   (the event ordinals are `0x81..0x84`).

3. **The stream itself is schema-agnostic.** `event_stream.pdx` treats
   `payload` as an opaque `u64`; producers pack through this schema
   before publishing, and receivers unpack through this schema after
   receiving. A schema growth (a new event type, an added field)
   does not require a stream change.

---

## 2. Endpoint and direction

- **Producers:** any kernel driver holding `hid_event_stream_publish`
  reach. Today: USB HID class driver (once wired), I²C-HID driver
  (`src/kernel/core/drivers/i2c_hid/`), and a future Bluetooth HID
  driver. See `event_stream.pdx` §1 for the multi-transport merge
  argument.
- **Subscribers:** any process holding a `KIND_HID_EVENT` capability
  (`cap/kind_hid_event.pdx`) whose row records a matching
  `event_type_mask`. The subscription is registered against the
  stream by `hid_event_stream_subscribe(slot)`.
- **Direction:** producer-to-subscriber only. There is no
  subscriber-side push of events, and no acknowledgement opcode; a
  subscriber that missed events knows so by comparing its own
  received-count to the stream's monotone `seq` (event_stream.pdx §0).
- **RPCs:** none. This is a pure stream schema; there are no
  request/reply pairs.
- **Substrate at R32.M3:** the schema (this document + its `.pdx`
  companion) plus the fanout scaffold (event_stream.pdx). A
  cross-process endpoint enqueue is deferred to R32.M4 (§7).

---

## 3. Event layouts

Payload fields are packed into a single `u64`. The HIGH byte
(bits `[63:56]`) holds the event-type ordinal, in the `0x81..0x84`
range so that a dispatcher switching on the type byte cannot route
a payload byte as an event type without crossing the `0x80` line.

### 3.1 `KBD_PRESS`

| Bits    | Field      | Meaning |
|---------|------------|---------|
| `[63:56]` | `type` = `0x81` | event ordinal |
| `[55:16]` | reserved   | Zero on the wire; the packer refuses non-zero here rather than masking. |
| `[15:0]`  | `scancode` | HID Usage ID from the Keyboard/Keypad usage page (§4). |

The packer is **arity 1** and pinned by `tools/build.sh`. A second
parameter would be a modifier bitmap or a repeat count; both are
receiver-side observations and admitting them into the payload would
let a producer force the receiver's modifier interpretation with no
receiver-side modifier tracking involved.

### 3.2 `KBD_RELEASE`

Same layout as `KBD_PRESS` with `type = 0x82`. A `KBD_RELEASE` with
no matching prior `KBD_PRESS` is a receiver-side observation (missed
frame, subscriber joined mid-stream) that the schema does not encode
into the payload — the honest observable is the seq gap.

### 3.3 `MOUSE_MOVE`

| Bits    | Field      | Meaning |
|---------|------------|---------|
| `[63:56]` | `type` = `0x83` | event ordinal |
| `[55:32]` | reserved   | Zero on the wire; refused if non-zero. |
| `[31:16]` | `dy`       | Vertical delta, signed 16-bit. Positive is down (screen-space Y increases downward). |
| `[15:0]`  | `dx`       | Horizontal delta, signed 16-bit. Positive is right. |

Callers pass `dx`/`dy` as `u64` with the sign extended. The packer
refuses any value outside int16's range, treating `INT16_MIN` and
`INT16_MAX` as INCLUSIVE bounds — a mouse that reports extreme
deltas is not lying; a mouse that reports beyond them is.

The unpackers `hid_event_stream_ch_mouse_dx` /
`hid_event_stream_ch_mouse_dy` sign-extend their result back to a
`u64`-hosted int16 so a caller who computes `rax + rbx` against
another sign-extended int16 gets the right answer.

### 3.4 `MOUSE_CLICK`

| Bits    | Field      | Meaning |
|---------|------------|---------|
| `[63:56]` | `type` = `0x84` | event ordinal |
| `[55:9]`  | reserved   | Zero on the wire; refused if non-zero. |
| `[8]`     | `edge`     | `0` = release, `1` = press. |
| `[7:0]`   | `button`   | Vendor-numbered button (`0`=primary/left, `1`=secondary/right, `2`=middle, `3..7` = vendor side buttons). |

The packer's contract is **refuse, not clamp**:

- A `button` above 8 bits is `BAD_BUTTON`. Eight bits covers every
  side-button vendor number a T14 G4 mouse advertises; a value that
  does not fit is the caller feeding raw bytes from something else.
- An `edge` other than 0 or 1 is `BAD_EDGE`. Accepting 2 or higher
  would let a receiver treat "double-click" or "hover" as either a
  press or a release depending on which arm it fell through, and
  there is no correct answer to that. No enum widening happens
  silently.

---

## 4. Event-class mapping

The four events map onto `kind_hid_event.pdx`'s four event-mask
classes in the obvious way. `event_stream.pdx`'s
`publish(event_type, payload)` takes `event_type` as the class bit
and dispatches to subscribers whose mask contains that bit:

| Event ordinal (`type` byte) | `event_type` class bit | Class name |
|-----------------------------|------------------------|------------|
| `0x81` `KBD_PRESS`          | `HID_EVT_KEY`     `0x01` | Keyboard |
| `0x82` `KBD_RELEASE`        | `HID_EVT_KEY`     `0x01` | Keyboard |
| `0x83` `MOUSE_MOVE`         | `HID_EVT_POINTER` `0x02` | Pointer |
| `0x84` `MOUSE_CLICK`        | `HID_EVT_POINTER` `0x02` | Pointer |

`HID_EVT_TOUCH` (`0x04`) and `HID_EVT_SENSOR` (`0x08`) have no event
types defined at R32.M3 (see §7). A future touch event (`TOUCH_CONTACT`)
and a future sensor event (`SENSOR_SAMPLE`) each take the next free
ordinal in the `0x8_` range and add themselves in the same commit
that adds the class-bit mapping.

---

## 5. What this schema does NOT carry

Stated plainly, in the manner of `kind_hid_event.pdx` §3:

- **Nothing routes an event across a process boundary.** The
  fanout (`event_stream.pdx`) matches subscribers and increments per-
  subscriber delivery counters; the enqueue into the subscriber's
  `KIND_IPC_ENDPOINT` queue is R32.M4's. A subscriber holding a
  `KIND_HID_EVENT` capability at R32.M3 knows what its subscription
  is; it does not yet observe the events themselves.
- **Nothing translates a scancode into a character.** That is a
  keymap, a locale, and a modifier tracker — receiver-side, above
  this schema. The schema carries the scancode; a character is the
  receiver's derivation.
- **Nothing tracks modifier state or key-repeat.** Modifier state is
  a synthesis of `KBD_PRESS`/`KBD_RELEASE` history that the receiver
  performs; encoding it in the payload would let one producer's view
  of shift-state force the receiver's interpretation.
- **Nothing tracks click-count for double-click.** Time-based
  gestures are receiver-side; the schema carries the individual
  edges.
- **Nothing sends touch or sensor events.** Two mask classes
  (`HID_EVT_TOUCH`, `HID_EVT_SENSOR`) are reserved for R32.M4+ and
  no event ordinal exists for them today.
- **Nothing survives a reboot.** The stream is memoryless — a boot
  with a subscribed process still receives no events for keys
  pressed while the machine was off.

---

## 6. Refusal taxonomy

Codes are packed into the `0xFFFFFEC0..0xFFFFFECF` band, disjoint
from every other block: `event_stream` (#1127) owns
`0xFFFFFEB0..BF`, DPAUX backlight `0xFFFFFEA0..AF`, `KIND_HID_EVENT`
`0xFFFFFE90..9F`, `KIND_HID_DEVICE` `0xFFFFFE80..8F`.

| Code                                | Meaning |
|-------------------------------------|---------|
| `HID_EVT_STREAM_CH_OK`              | `0` — accepted. |
| `HID_EVT_STREAM_CH_BAD_EV`          | `0xFFFFFECF` — event ordinal outside the enumeration. |
| `HID_EVT_STREAM_CH_BAD_SCANCODE`    | `0xFFFFFECE` — scancode does not fit 16 bits. |
| `HID_EVT_STREAM_CH_BAD_DELTA`       | `0xFFFFFECD` — dx or dy outside INT16. |
| `HID_EVT_STREAM_CH_BAD_BUTTON`      | `0xFFFFFECC` — button does not fit 8 bits. |
| `HID_EVT_STREAM_CH_BAD_EDGE`        | `0xFFFFFECB` — edge is neither 0 nor 1. |
| `HID_EVT_STREAM_CH_BAD_RESERVED`    | `0xFFFFFECA` — a reserved bit range was non-zero. |
| `HID_EVT_STREAM_CH_DECODE_BAD`      | `0xFFFFFFFFFFFFFFFF` — packer positional "no legal payload" sentinel. |

Refusal codes are DISTINCT from the packer sentinel. A caller that
collapsed the two would lose the ability to distinguish a wrong-arity
call from a bad field.

---

## 7. Wire framing and cross-process substrate

Not delivered at R32.M3-004 and deliberately named as an omission:

- **Endpoint enqueue.** `event_stream.pdx` counts matched deliveries
  per subscriber but does not enqueue bytes into the subscriber's
  `KIND_IPC_ENDPOINT`. R32.M4 wires that enqueue in the same commit
  that plumbs HID over the endpoint transport; until then, the
  `hid_event_stream_delivered_by(slot)` counter is the honest
  observable that says "the fanout matched this subscriber N times".
- **Frame envelope.** The `Frame` header
  (`src/kernel/core/ipc/frame.pdx`) already carries `opcode`,
  `subject` and `length`; the mapping will be
  `opcode = HID_EVT_STREAM_CH_EV_*` for the event ordinal,
  `subject = cap_table slot of the KIND_HID_EVENT handle`,
  `length = 8`.
- **Touch and sensor events.** `HID_EVT_TOUCH` and `HID_EVT_SENSOR`
  are reserved on the mask side but have no event ordinals here.
  R32.M4+ defines `TOUCH_CONTACT` and `SENSOR_SAMPLE` (or a family
  per axis).
- **Per-transport tagging.** The `event_stream.pdx` §1 argument for a
  singular fanout depends on the payload carrying the transport
  identity when a subscriber needs it. That extension is a §3.x
  layout change on the affected events (a `transport` byte in the
  currently reserved range), not a stream change.
- **Backpressure.** The stream scaffold has no ring — publish counts
  and returns immediately. R32.M4 lands the ring, its depth, and
  the tail-drop counters the ACPI event stream carries
  (`evt_stream.pdx` §backpressure).

---

## 8. Test replay

The kernel-side witnesses
(`tests/kernel/drivers/hid/event_stream_synth.pdx` and
`tests/kernel/ipc/hid_event_stream_channel_synth.pdx`) assert:

- The four packers round-trip against named
  `{scancode}`, `{dx, dy}`, `{button, edge}` tuples — which is what
  makes the schema replayable when a reader arrives. Replay against
  a schema whose packer disagrees with its unpacker is replay
  against nothing.
- Event-type dispatch: unpacking a `KBD_PRESS` scancode out of a
  `MOUSE_MOVE` payload is `DECODE_BAD`, not the low 16 bits of `dx`.
- Reserved-bit refusal: a payload with any reserved bit set is
  refused by `hid_event_stream_ch_payload_reserved_ok`.
- Signed-axis discipline: `MOUSE_MOVE(-1, 32767)` round-trips to
  `(-1, 32767)`; `MOUSE_MOVE(32768, 0)` and `MOUSE_MOVE(-32769, 0)`
  are refused.
- Edge discipline: `MOUSE_CLICK(0, 2)` is refused with `BAD_EDGE`.
