# PaideiaOS — IPC Schema: `sensor_read_channel`

**Status:** Design v1.0 (kernel-side schema + packers landed; wire framing
deferred — see §7)
**Date:** 2026-08-17
**Round:** R32.M5-003 (issue #1135)
**Companion:** `design/ipc/hid-event-stream-session.md` (sibling one-word
schema for HID keyboard/pointer/touch), `src/kernel/core/ipc/sensor_read_channel.pdx`
(this schema, in code), `src/kernel/core/cap/kind_sensor_channel.pdx`
(the row this session narrates), `src/kernel/core/drivers/sensor_hub.pdx`
(the scaffold driver whose samples this session carries).

---

## 1. Purpose

`sensor_read_channel : Channel(SensorReadChannelSchema)` is the endpoint
a display-auto policy, a screen-rotation service or a stabilisation
subsystem speaks to when it wants a stream of sensor samples of a
chosen class at a chosen rate. Three interactions exist and no more:

- **`SUBSCRIBE`** (request, no reply): one request carrying the sensor
  type (ALS / ACCEL / GYRO) and the desired rate in Hz. The reply is
  the KIND_SENSOR_CHANNEL capability the supervisor mints on the
  subscriber's behalf (kernel-mediated; the schema does not carry a
  reply frame for it).
- **`SAMPLE_STREAM`** (stream event, two u64 words per sample): the
  driver's next sample, downsampled to the subscription's `rate_hz`
  from the hub's native rate. Two words because a three-axis sample
  plus a monotonic timestamp does not fit one word (§3 spells the
  layout out).
- **`UNSUBSCRIBE`** (request, no payload, no reply): the subscriber
  is done. The KIND_SENSOR_CHANNEL revoke that the supervisor
  performs is the acknowledgement.

Three properties motivate the whole schema:

1. **Sample payloads are TWO `u64` words.** One does not fit a
   three-axis reading plus a timestamp without silently sacrificing
   axis width; two lets each axis stay `int16` and leaves 32 bits
   for the timestamp. §3 documents the bit layout.

2. **The event ordinal is in the HIGH BYTE of every word.** Both
   payload words carry 0x91 in bits [63:56] so a receiver reading
   only one word can still dispatch on the type byte. All ordinals
   sit in the 0x9x range (0x90 subscribe / 0x91 sample_stream /
   0x92 unsubscribe) so a dispatcher switching on the type byte
   cannot route a sensor payload as an HID event (0x8x block) or
   the reverse without noticing.

3. **The channel narrates a SUBSCRIPTION AND ITS SAMPLES. It does
   not drive the hub, and it does not mint the KIND_SENSOR_CHANNEL
   capability the subscription's identity lives in.** The mint is
   done by a supervisor at subscribe time and the row is what
   `cap/kind_sensor_channel.pdx` §1 governs; the sample values
   come from `drivers/sensor_hub.pdx`'s three arity-one seams
   (`sample_als`, `sample_accel`, `sample_gyro`). The schema is
   the wire face of the two, and nothing more.

## 2. Session type

```
sensor_read : Channel {
  subscribe(sensor_type : SensorType, rate_hz : u16) ->
    stream(SAMPLE_STREAM(ts : u32, x : i16, y : i16, z : i16))*
    unsubscribe
}
```

Where `SensorType = {ALS = 1, ACCEL = 2, GYRO = 3}` (kind
`kind_sensor_channel.pdx` §4). The star is Kleene: the subscriber
receives zero or more `SAMPLE_STREAM` events before it sends the
`unsubscribe`. There is no reply to `subscribe` or `unsubscribe` in
the schema — the KIND_SENSOR_CHANNEL mint and revoke are the
acknowledgements, and the schema does not encode either.

`rate_hz` is bounded to [1, SENSOR_RATE_MAX] Hz per
`kind_sensor_channel.pdx` §1. A rate that fits the schema but not the
mint bound is admitted by the schema and refused by the mint. That is
deliberate: the schema's job is wire encoding, the mint's is authority
arbitration, and folding the two would let a subscription's rate
budget depend on which side of the boundary rejected an out-of-range
value.

## 3. Bit layout

### 3.1 SUBSCRIBE_REQ (ordinal 0x90, one word)

```
bits    63:56  55:24     23:8      7:0
        ├─────┼─────────┼─────────┼─────────┤
value   0x90  reserved   rate_hz   sensor_type
        │             │         │
        │             │         │
        │             │         └── u8: 1..3 (ALS/ACCEL/GYRO)
        │             └──────────── u16: 1..SENSOR_RATE_MAX (1000)
        └────────────────────────── ordinal byte
```

Reserved bits [55:24] are refused by the packer AND by the unpacker,
per §5.

### 3.2 SAMPLE_STREAM (ordinal 0x91, TWO words)

```
word 0
bits    63:56  55:32       31:0
        ├─────┼───────────┼───────────┤
value   0x91  reserved     ts
                           │
                           └── u32 monotonic ticks

word 1
bits    63:56  55:48      47:32      31:16      15:0
        ├─────┼─────────┼──────────┼──────────┼──────────┤
value   0x91  reserved   z (i16)    y (i16)    x (i16)
```

Both words carry the ordinal in [63:56] so a receiver reading only one
word (a partial delivery, a peek) can dispatch on it. Reserved ranges
are refused by both packer and unpacker.

Timestamp precision is u32 monotonic ticks in the domain the driver
publishes; overflow wraps once every 2^32 ticks. A milestone that
lengthens the tick domain widens word 0 into a full 56-bit timestamp
by consuming the reserved [55:32] range; the schema version bump
happens in the same commit.

### 3.3 UNSUBSCRIBE_REQ (ordinal 0x92, one word)

```
bits    63:56  55:0
        ├─────┼─────────┤
value   0x92  reserved (zero)
```

No payload. See `sensor_read_ch_pack_unsubscribe`'s justification for
why arity ZERO is load-bearing: any parameter here would be a REASON
or a MODE the receiver's response does not depend on, and encoding
one would be a lie in the wire format.

## 4. Refuse, never clamp

The packers enforce every field's width EXACTLY:

- `sensor_type` outside {1, 2, 3} → `BAD_TYPE` (`kind_sensor_channel`
  §4 lists the enumeration; §5 refuses UNKNOWN and every value past
  the last real type).
- `rate_hz` outside [1, SENSOR_RATE_MAX] → `BAD_RATE`.
- `ts` outside u32 range → `BAD_TS`.
- Any axis outside int16 range → `BAD_AXIS`.
- Any reserved bit non-zero on the unpacker path → `BAD_RESERVED`.

The alternative — silent truncation — has different consequences per
field. A truncated rate would be pinned at the low or high boundary
depending on which bit was dropped, and the subscriber would count
against a budget different from the one it asked for. A truncated
axis is worse: the wrong prefix of a signed axis is an accelerometer
that reports sign-flipped values every time the wearer walks past
the acceleration ceiling, which no subscriber is watching for.

## 5. Reserved bits are refused, not masked

Same discipline as `hid_event_stream_channel.pdx` §2 and
`kind_backlight.pdx` REPORT reserved bits: a reserved field that a
receiver silently masks is a field a later revision cannot use. A
`SAMPLE_STREAM` word 0 with 24 free bits between the timestamp and
the type byte is where a caller-supplied UNITS tag or a subscriber-
side SEQUENCE would be smuggled; a `SUBSCRIBE_REQ` with 32 free bits
between rate and type is where a future option field belongs. Both
grow by consuming reserved space in a schema version bump, and the
version bump is when the code above changes; today's packers set
reserved to zero and today's unpackers refuse a non-zero value.

## 6. Error taxonomy (0xFFFFFEF0..FF)

Sixteen-wide, disjoint from every other in-tree band. `SensorHub`
occupies `0xFFFFFED0..DF`, `HidEventStreamChannel` occupies
`0xFFFFFEC0..CF`, `HidEventStream` occupies `0xFFFFFEB0..BF`, and
`KindSensorChannel` occupies `0xFFFFFEA0..AF`. Disjointness lets a
u64 threaded up through the pack/unpack chain still name the gate
that refused it.

## 7. Deferrals

None of the following is in this milestone's scope:

- **No fanout.** `hid_event_stream_publish` is what carries the
  payload today (through the HID event stream, on the SENSOR class
  bit — see `sensor_hub.pdx` §1); a follow-up milestone may add a
  dedicated sensor stream if the fanout patterns diverge. The
  session schema does not depend on which stream carries the bytes.
- **No cross-process byte transfer.** No `SEND` and no `RECV` runs
  through this schema in this tree. When the userspace substrate
  lands the transports for sensor subscriptions, the packers and
  unpackers here are what the two ends will exchange.
- **No timer.** The driver does not schedule sample publications
  today. When the gated:hardware milestone plumbs a real I²C-HID
  capability through `sensor_hub_bind`, the driver reads the hub at
  its native rate and downsamples per KIND_SENSOR_CHANNEL
  subscription's `rate_hz` — but no timer is armed in this tree.
- **No calibration or configuration op.** Per-axis offset, mounting
  orientation, per-sensor low-power mode: all subscriber-side or
  supervisor-side state, none encoded in the schema. If any of them
  becomes a wire field, it takes a new ordinal in the 0x9x block
  and one arm in every dispatcher that switches on the type byte.
