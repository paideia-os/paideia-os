# PaideiaOS — IPC Schema: `battery_channel`

**Status:** Design v1.0 (kernel-side schema + packers landed; wire framing
deferred — see §7)
**Date:** 2026-08-17
**Round:** R31.M3-002 (issue #1100)
**Companion:** `design/roadmap/next-wave-softarch.md` §5 R31.M3,
`design/ipc/driver-audit-schema.md` (one-way stream template),
`src/kernel/core/ipc/battery_channel.pdx` (this schema, in code),
`src/kernel/core/cap/kind_battery.pdx` (the row this channel narrates).

---

## 1. Purpose

`battery_channel : Channel(BatteryChannelSchema)` is the endpoint a
monitoring UI or a power-policy supervisor speaks to when it wants a
battery's live state. Three operations exist and no more:

- **`READ_STATE`** (RPC): one request, one reply — the row's currently
  cached percent, state ordinal, voltage and lifetime report count.
- **`STATE_CHANGED`** (stream event): pushed when the monitor observes a
  transition of the state ordinal (`DISCHARGING → CHARGING`, `CHARGING →
  FULL`, `DISCHARGING → CRITICAL`, …).
- **`LOW_WARNING`** (stream event): pushed when the monitor observes the
  percent crossing DOWN through the installed low-warning threshold.
  Re-armed only after the percent recovers above threshold + hysteresis;
  a pack flapping around the threshold does not emit one event per
  sample.

Two properties motivate the whole schema:

1. **The RPC reply is a single `u64`.** A reply that spans multiple
   words has an ordering across the words that the wire must preserve;
   a reply that is one word is atomic against every reader that reads
   it as a word. §3 explains the packing.

2. **The stream events carry the OBSERVATION, not the AUTHORITY.**
   A `LOW_WARNING` carries a percent and the threshold that produced it.
   A subscriber that reads `LOW_WARNING` and interprets it as
   *"shut down"* has invented a policy the channel does not contain. §4
   states the intent and §5 lists the deferrals in the language
   `kind_battery.pdx` §4 uses.

---

## 2. Endpoint and direction

- **Server:** `battery_monitor` — the process (kernel-side scaffold at
  R31.M3) that holds `R_BATTERY_READ | R_BATTERY_REPORT` over one or
  more `KIND_BATTERY` capabilities.
- **Clients:** any process holding a subscription handle. A subscription
  handle carries neither `R_BATTERY_REPORT` nor `RIGHT_MINT`, so a
  client cannot install a report through the same channel it reads
  one.
- **RPC direction:** request/reply, one-shot. No `read_state` is
  streaming.
- **Event direction:** server-to-client only. Clients do not push events
  and there is no acknowledgement opcode — the server clears its own
  pending-flag word when it dispatches the event, so an event that was
  never dispatched is still pending on the next sample.
- **Substrate at R31.M3:** the schema (this document + its `.pdx`
  companion). A cross-process endpoint is deferred (§7): the schema
  lands first because the packer/unpacker are the load-bearing
  documented artefacts and no consumer exists yet — `kind_battery.pdx`
  §4 records that fact and `battery_monitor` scaffolds it.

---

## 3. `READ_STATE` reply layout

One `u64`, packed as follows:

| Bits    | Field       | Meaning |
|---------|-------------|---------|
| `[7:0]`   | `percent`    | 0..100 inclusive, or `BATTERY_PCT_NONE` (0xFF) if no report has installed since row creation or last revoke. |
| `[15:8]`  | `state`      | State ordinal, 0..`BATTERY_STATE_MAX` (5). |
| `[31:16]` | `voltage_mv` | Voltage in millivolts, 0..`BATTERY_VOLTAGE_MV_MAX` (25000). Zero means "never reported". |
| `[63:32]` | `reports`    | Lifetime successful-report count for the row (32 bits; saturates at `0xFFFFFFFF`). |

Field boundaries are chosen so the sentinels are unambiguous: `percent
== 0xFF` fits in one byte and does not collide with the legal 0..100
range; `voltage_mv == 0` is the "never reported" sentinel that
`battery_voltage_valid` refuses to admit as a fresh report; `reports ==
0` means the row exists and has no report yet, which is
distinguishable from a dead row because a dead-row query is refused by
the RPC gate before it reaches the packer at all.

`BATTERY_CH_DECODE_BAD` (`0xFFFFFFFFFFFFFFFF`) is the reply the packer
returns for a caller that asked for a slot naming no live row. It is
outside the field-decomposition of any legal packed reply — every
legal reply has at least the `state` byte inside `[15:8]` == 0..5, so
the `0xFF` byte in `[15:8]` cannot appear.

The unpackers `battery_channel_reply_percent`, `_state`, `_voltage`,
`_reports` are the ONLY route from the packed word back into fields.
A caller extracting bits by hand is a caller whose extraction can
drift from the packer's meaning; the four unpackers exist so that a
future re-packing (a 12-bit percent, say, when battery reports arrive
as deci-percent) changes both halves in one commit.

---

## 4. Stream events

### 4.1 `STATE_CHANGED` payload

| Bits    | Field       | Meaning |
|---------|-------------|---------|
| `[7:0]`   | `prev_state` | The state ordinal before the transition. |
| `[15:8]`  | `new_state`  | The state ordinal after the transition. `prev == new` is never emitted. |
| `[23:16]` | `percent`    | Current percent at the moment of the transition (0..100). |
| `[47:24]` | `voltage_mv` | Current voltage at the transition (24 bits). |
| `[63:48]` | reserved     | Zero on the wire; a receiver that observes a non-zero value MUST refuse the event (no silent masking — §6). |

The event carries BOTH endpoints of the transition, not just the new
state, because a subscriber that missed a prior event still needs to
know what changed. A payload that carried only `new_state` would
require the subscriber to keep its own cached prior — which is
precisely the cache the monitor exists to be.

### 4.2 `LOW_WARNING` payload

| Bits    | Field       | Meaning |
|---------|-------------|---------|
| `[7:0]`   | `percent`    | The percent at the crossing (0..100). |
| `[15:8]`  | `threshold`  | The installed low-warning threshold (0..100). |
| `[31:16]` | `voltage_mv` | Current voltage (16 bits, sufficient for the 25000 mV domain). |
| `[63:32]` | reserved     | Zero; refused if non-zero, as above. |

Carrying the threshold alongside the percent means a subscriber
comparing two `LOW_WARNING` events over time can detect that the
operator re-tuned the threshold without querying the server for it —
which is what lets a display say "5% (was 10%)" rather than "5% (was
5%?)" after a policy update.

Re-arming discipline: once fired, `LOW_WARNING` does not fire again
until the percent has climbed above `threshold + BATTERY_MONITOR_LOW_HYST_PCT`
(hysteresis, currently 3). A pack sitting at threshold with 1% ripple
would otherwise emit one event per sample forever, which is the
class of bug §6 refuses to admit under the guise of "warn again".

---

## 5. What this schema does NOT carry

Stated plainly, in the manner of `kind_battery.pdx` §4:

- **Nothing shuts the machine down.** `LOW_WARNING` is a report, not
  an authority. The shutdown consumer of `BATTERY_STATE_CRITICAL` does
  not exist yet (`kind_battery.pdx` §4, `kind_thermal_zone.pdx` §6).
- **Nothing tunes the row's design capacity, index or chemistry.**
  Those are set once at mint by `battery_cap_mint`; the RPC surface
  exposes them via `KIND_BATTERY` op-codes, not via this channel.
- **Nothing draws current, opens a charge control, or writes an EC
  register.** The channel narrates a battery. Every write path lives
  behind `KIND_EC_QUERY` and `KIND_BATTERY`, and the subscription
  handle carries no right that reaches either.
- **Nothing subscribes across a reboot.** The pending-flag word is
  `.bss` (see `battery_monitor.pdx`); a boot with a subscribed
  supervisor still gets no events for the transitions the pack made
  while the machine was off.

---

## 6. Refusal taxonomy

Codes are packed into the same `0xFFFFFExx` band the rest of the
kernel uses, disjoint from every other block:

| Code           | Meaning |
|----------------|---------|
| `BATTERY_CH_OK`               | `0` — accepted. |
| `BATTERY_CH_BAD_OP`           | `0xFFFFFE5F` — op ordinal outside the enumeration. |
| `BATTERY_CH_BAD_EV`           | `0xFFFFFE5E` — event ordinal outside the enumeration. |
| `BATTERY_CH_BAD_PERCENT`      | `0xFFFFFE5D` — percent outside `[0, 100]`. |
| `BATTERY_CH_BAD_STATE`        | `0xFFFFFE5C` — state ordinal outside the enum. |
| `BATTERY_CH_BAD_VOLTAGE`      | `0xFFFFFE5B` — voltage past `BATTERY_VOLTAGE_MV_MAX` for a payload field. |
| `BATTERY_CH_BAD_RESERVED`     | `0xFFFFFE5A` — a reserved field carried a non-zero bit. |
| `BATTERY_CH_DECODE_BAD`       | `0xFFFFFFFFFFFFFFFF` — the packer's positional "no legal reply" sentinel. |

Refusal codes are DISTINCT from the reply sentinel. The reply
sentinel means "there is no row to describe", the refusal codes name
which gate refused which byte; a caller that collapsed the two would
lose the ability to distinguish a dead slot from a corrupt payload.

---

## 7. Wire framing and cross-process substrate

Not delivered at R31.M3 and deliberately named as an omission:

- **Endpoint substrate.** There is no `KIND_IPC_ENDPOINT` bound to
  this schema yet. The RPC packer and the event packers are callable
  from a monitor server, which is what makes the schema usable at all
  before a userspace client exists; adding an endpoint is adding a
  transport, not a semantics change.
- **Frame envelope.** The `Frame` header (see
  `src/kernel/core/ipc/frame.pdx`) already carries `opcode`,
  `subject` and `length`; the mapping is `opcode = BATTERY_CH_OP_*`
  for requests and `opcode = BATTERY_CH_EV_*` for events, `subject =
  cap_table slot of the KIND_BATTERY handle`, `length = 8`. That
  mapping lives here so the endpoint issue does not have to invent
  one.
- **Reply latency budget.** `READ_STATE` reads one row; the packer is
  a straight-line function with no allocation. A budget will land
  with the endpoint issue.

None of these omissions is silent. Each one has a distinct issue in
the R31 queue and the module header of `battery_channel.pdx` §4
mirrors this list.

---

## 8. Test replay

The issue asks for "test replay from Linux capture". Deferred at
R31.M3-002 and stated here rather than left to be discovered: the
capture format is a two-column log (percent, mv, state) sampled at
1 Hz; the replay reader is a userspace tool the round has not yet
built, and no reader in this tree consumes the pack-format above. The
kernel-side witness (`tests/kernel/ipc/battery_channel_synth.pdx`)
asserts the packers and unpackers round-trip against six named
{percent, state, mv, reports} tuples, which is what makes the schema
replayable when the reader arrives — replay against a schema whose
packer disagrees with its unpacker is replay against nothing.
