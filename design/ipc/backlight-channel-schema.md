# PaideiaOS — IPC Schema: `backlight_channel`

**Status:** Design v1.0 (kernel-side schema + packers landed; wire framing
deferred — see §7)
**Date:** 2026-08-17
**Round:** R31.M5-002 (issue #1107)
**Companion:** `design/ipc/battery-channel-schema.md` (sibling one-word
schema), `src/kernel/core/ipc/backlight_channel.pdx` (this schema, in
code), `src/kernel/core/cap/kind_backlight.pdx` (the row this channel
narrates), `src/kernel/core/drivers/backlight_pwm.pdx` and
`src/kernel/core/drivers/backlight_dpaux.pdx` (the two backend drivers
this channel does not touch, per §5).

---

## 1. Purpose

`backlight_channel : Channel(BacklightChannelSchema)` is the endpoint a
compositor or a display-policy supervisor speaks to when it wants a
backlight's currently reported level, wants to install a new one, or
wants to observe brightness transitions. Three RPCs exist and no more:

- **`GET`** (RPC): one request, one reply — the row's currently cached
  `current_brightness` and lifetime `reports` count.
- **`SET`** (RPC): one request; carries a proposed ordinal in the
  row's `[brightness_min, brightness_max]` domain. Per
  `kind_backlight.pdx` §3 the request is REFUSED-OR-INSTALLED — the
  packer of the request refuses any level a controller could not
  legitimately carry (out of 16 bits, reserved bits set), the RPC
  handler on the server side installs the level as a report against
  the row and NOTHING CLAMPS. A supervisor sending 200 to a
  100-ceiling panel is told, not silently pinned.
- **`GET_RANGE`** (RPC): one request, one reply — the row's
  `brightness_min` and `brightness_max`, so a subscriber does not have
  to invent one range for a panel whose firmware advertised another.

And one stream event:

- **`BRIGHTNESS_CHANGED`** (stream event): pushed when the compositor
  installs a report and the previous cached ordinal was different from
  the new one. `prev == new` is never emitted (a "changed" payload
  that did not change is a lie the receiver would count as a
  transition).

Two properties motivate the whole schema:

1. **Every reply and payload is one `u64`.** A reply that spans
   multiple words carries an ordering across words a receiver must
   preserve; a one-word reply is atomic against every reader that
   reads it as a word. §3 documents the bit layout.

2. **The channel narrates a CONTROLLER'S CACHED LEVEL. It does not
   drive a PWM duty cycle or a DP-AUX byte.** Those live in the two
   backend drivers (`backlight_pwm.pdx`, `backlight_dpaux.pdx` per
   #1108/#1109), and both of them are scaffolds — the write path is
   `gated:hardware` and refuses with `DEFERRED_HARDWARE` today. A
   subscriber that reads a `BRIGHTNESS_CHANGED` and infers the panel
   moved has invented an authority the schema does not carry. §5
   states the intent.

---

## 2. Endpoint and direction

- **Server:** the compositor process (or an eventual `backlight_monitor`
  scaffold, absent at R31.M5) that holds
  `R_BACKLIGHT_READ | R_BACKLIGHT_REPORT` over one or more
  `KIND_BACKLIGHT` capabilities.
- **Clients:** any process holding a subscription handle. A
  subscription handle carries neither `R_BACKLIGHT_REPORT` nor
  `RIGHT_MINT`, so a client cannot install a report through the
  subscription channel it observes one from.
- **RPC direction:** request/reply, one-shot. `GET`/`SET`/`GET_RANGE`
  are all one round-trip.
- **Event direction:** server-to-client only. There is no client-side
  push of events, and no acknowledgement opcode.
- **Substrate at R31.M5:** the schema (this document + its `.pdx`
  companion). A cross-process endpoint is deferred (§7).

---

## 3. RPC layouts

Level fields are 16 bits, since `kind_backlight.pdx` declares
`BACKLIGHT_LEVEL_UPPER = 65535` (one 16-bit PWM covers every panel).

### 3.1 `GET` reply

| Bits    | Field     | Meaning |
|---------|-----------|---------|
| `[15:0]`  | `current`  | Current cached ordinal in `[brightness_min, brightness_max]`, or `BACKLIGHT_LEVEL_NONE` (0xFFFF) if no report has installed since row creation. |
| `[47:16]` | `reports`  | Lifetime successful-report count (32 bits; saturates at `0xFFFFFFFF`). |
| `[63:48]` | reserved   | Zero on the wire. |

### 3.2 `SET` request payload

| Bits    | Field    | Meaning |
|---------|----------|---------|
| `[15:0]`  | `level`   | Proposed ordinal (16 bits). |
| `[63:16]` | reserved | Zero on the wire; the packer refuses non-zero here rather than masking. |

The packer's contract is REFUSE-OR-INSTALL: a level that does not fit
16 bits is refused with `BAD_LEVEL`; non-zero reserved bits are
refused with `BAD_RESERVED`. THE PACKER DOES NOT CLAMP against
`[brightness_min, brightness_max]` — that gate lives on the receiving
end (`backlight_report_install` in `kind_backlight.pdx` §3), and
clamping in the packer would let a supervisor's out-of-range SET
succeed silently as the top intensity. The two refusals are DISTINCT
codes so a caller threading them up can name which gate refused.

### 3.3 `GET_RANGE` reply

| Bits    | Field     | Meaning |
|---------|-----------|---------|
| `[15:0]`  | `min`      | `brightness_min` of the row. |
| `[31:16]` | `max`      | `brightness_max` of the row. |
| `[63:32]` | reserved   | Zero on the wire. |

The packer refuses `max <= min` with `BAD_RANGE`. A panel whose
advertised range degenerates to a point has an unusable control
surface — a receiver acting on such a reply computes intensities in a
one-value domain — and neither the packer nor the receiver has any
business inventing a broader range.

---

## 4. Stream events

### 4.1 `BRIGHTNESS_CHANGED` payload

| Bits    | Field    | Meaning |
|---------|----------|---------|
| `[15:0]`  | `prev`    | Ordinal cached before the transition. |
| `[31:16]` | `new`     | Ordinal cached after the transition. `prev == new` is never emitted. |
| `[63:32]` | reserved | Zero on the wire; refused if non-zero. |

The event carries BOTH endpoints of the transition for the same
reason `STATE_CHANGED` on the battery side does: a subscriber that
missed a prior event still needs to know what changed. Sending only
`new` would require every subscriber to keep its own cached prior —
which is precisely the cache the compositor is.

There is no hysteresis, no threshold, and no re-arm logic. A ramp
that installs 10 reports over 100 ms is 10 events; a subscriber that
wants to sample the ramp at a lower rate keeps its own prior.

---

## 5. What this schema does NOT carry

Stated plainly, in the manner of `kind_backlight.pdx` §4:

- **Nothing drives a panel.** `SET` is a REPORT installation on the
  row, not a bus transaction. The write paths live in
  `src/kernel/core/drivers/backlight_pwm.pdx` (#1108) and
  `src/kernel/core/drivers/backlight_dpaux.pdx` (#1109), and both
  return `DEFERRED_HARDWARE` today — no MMIO or AUX transaction runs
  in this tree at all. When the MMIO capability wires up, the
  compositor calls the driver AFTER a successful `SET`; the channel
  does not learn about that call and does not report on it.
- **Nothing sets a brightness from an ambient sensor, a lid event,
  or a thermal reading.** Those associations are policy, and policy
  is ring 3's — see `kind_cooling_device.pdx` §4 for the analogous
  refusal on the cooling side.
- **Nothing tunes the row's brightness_min or brightness_max.** Those
  are set once at mint by `backlight_cap_mint`; the row's static
  identity is not exposed on this channel at all (a caller wanting
  the min/max at boot uses `KIND_BACKLIGHT` `QUERY_MIN`/`QUERY_MAX`
  ops).
- **Nothing subscribes across a reboot.** No pending-flag word
  survives; a boot with a subscribed supervisor still gets no events
  for transitions that happened while the machine was off.

---

## 6. Refusal taxonomy

Codes are packed into the `0xFFFFFE80..0xFFFFFE8F` band, disjoint
from every other block: `KIND_BACKLIGHT` owns `0xFFFFFE70..7F`,
`BatteryMonitor` owns `0xFFFFFE60..6F`, `BatteryChannel` owns
`0xFFFFFE50..5F`, and the two new drivers (#1108/#1109) claim
`0xFFFFFE90..9F` and `0xFFFFFEA0..AF`.

| Code                                | Meaning |
|-------------------------------------|---------|
| `BACKLIGHT_CH_OK`                   | `0` — accepted. |
| `BACKLIGHT_CH_BAD_OP`               | `0xFFFFFE8F` — op ordinal outside the enumeration. |
| `BACKLIGHT_CH_BAD_EV`               | `0xFFFFFE8E` — event ordinal outside the enumeration. |
| `BACKLIGHT_CH_BAD_LEVEL`            | `0xFFFFFE8D` — level does not fit 16 bits, or (for BRIGHTNESS_CHANGED) `prev == new`. |
| `BACKLIGHT_CH_BAD_RANGE`            | `0xFFFFFE8C` — `max <= min` on `GET_RANGE`. |
| `BACKLIGHT_CH_BAD_RESERVED`         | `0xFFFFFE8B` — a reserved field carried a non-zero bit. |
| `BACKLIGHT_CH_DECODE_BAD`           | `0xFFFFFFFFFFFFFFFF` — the packer's positional "no legal reply" sentinel. |

Refusal codes are DISTINCT from the reply sentinel. A caller that
collapsed the two would lose the ability to distinguish a dead row
from a corrupt payload.

---

## 7. Wire framing and cross-process substrate

Not delivered at R31.M5 and deliberately named as an omission:

- **Endpoint substrate.** There is no `KIND_IPC_ENDPOINT` bound to
  this schema yet. The three packers and the one event packer are
  callable from a compositor server, which is what makes the schema
  usable before a userspace client exists; adding an endpoint is
  adding a transport, not a semantics change.
- **Frame envelope.** The `Frame` header
  (`src/kernel/core/ipc/frame.pdx`) already carries `opcode`,
  `subject` and `length`; the mapping is `opcode =
  BACKLIGHT_CH_OP_*` for requests and `opcode =
  BACKLIGHT_CH_EV_BRIGHTNESS_CHANGED` for the event, `subject =
  cap_table slot of the KIND_BACKLIGHT handle`, `length = 8`.
- **Reply latency budget.** `GET` reads one row; the packer is a
  straight-line function with no allocation. A budget will land with
  the endpoint issue.

---

## 8. Test replay

Deferred at R31.M5-002. The kernel-side witness
(`tests/kernel/ipc/backlight_channel_synth.pdx`) asserts the packers
and unpackers round-trip against named `{current, reports}`,
`{min, max}`, `{prev, new}` and `{level}` tuples — which is what
makes the schema replayable when a reader arrives. Replay against a
schema whose packer disagrees with its unpacker is replay against
nothing.
