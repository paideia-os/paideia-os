# PaideiaOS -- IPC Schema: `hub_topology_channel`

**Status:** Design v1.0 (kernel-side schema + packers landed; wire framing
deferred -- see §7)
**Date:** 2026-08-18
**Round:** R34.M1-004 (issue #1170)
**Companion:** `design/roadmap/next-wave-softarch.md` §3 R34.M1,
`src/kernel/core/ipc/hub_topology_channel.pdx` (this schema, in code),
`src/kernel/core/cap/kind_usb_hub.pdx` (the row this channel narrates),
`src/kernel/core/drivers/usb/hub_fsm.pdx` (the per-port state machine
whose transitions this channel streams),
`src/kernel/core/drivers/usb/hub_driver.pdx` (the descriptor decoder).

---

## 1. Purpose

`hub_topology_channel : Channel(HubTopologyChannelSchema)` is the endpoint
the USB class driver publishes device-attach, device-detach and per-port
status change events on. Three event frames exist and no more:

- **`DEVICE_ATTACHED`** (event): one frame naming `(hub_slot, port,
  speed)`; sent when the class driver observes a downstream port
  transitioning DISCONNECTED -> CONNECTED and completing enumeration
  through CONFIGURED (per `hub_fsm.pdx`).
- **`DEVICE_DETACHED`** (event): one frame naming `(hub_slot, port)`;
  sent when the class driver observes a port transitioning back to
  DISCONNECTED from any live state.
- **`PORT_STATUS_CHG`** (event): one frame naming `(hub_slot, port,
  event_kind)`; sent for intermediate transitions (RESET_START,
  ADDRESSED, CONFIGURED) so a subscriber can render enumeration
  progress without inferring it from the terminal frames.

Three properties motivate the whole schema:

1. **Every event is one `u64`.** A frame that spanned multiple words
   would have an ordering across words the wire must preserve; one
   word is atomic against every reader.

2. **The channel carries the effect row `!{hub_status_recv}`.** A
   subscriber that receives frames must hold the `hub_status_recv`
   effect on the endpoint's own capability; the class driver that
   publishes must hold the mint bit on the same endpoint. Because
   the effect row is on the CHANNEL and not on any frame, a
   subscriber that receives a `DEVICE_ATTACHED` cannot claim it also
   held authority to receive `PORT_STATUS_CHG` — both come through
   the same session, so both are present or neither is.

3. **The channel narrates a TOPOLOGY relationship. It does NOT carry
   a USB device capability.** The class driver mints the
   `KIND_USB_DEVICE` (and, for a downstream hub, `KIND_USB_HUB`) as
   its own action; the topology channel names the (hub_slot, port)
   pair a subscriber can then look up. A subscriber that receives a
   `DEVICE_ATTACHED` and infers it may talk to the device has
   invented an authority the schema does not carry.

---

## 2. Endpoint and direction

- **Server:** the ring-3 USB class driver — the process that holds
  `R_USB_HUB_INVOKE` over each `KIND_USB_HUB` capability and
  `R_USB_DEVICE_INVOKE` over each `KIND_USB_DEVICE` it enumerated,
  plus `RIGHT_MINT` over the `KIND_IPC_ENDPOINT` for the topology
  endpoint it publishes.
- **Clients:** any process holding a subscription handle carrying the
  `hub_status_recv` effect.
- **Direction:** publish-only (server -> subscribers). No RPC on this
  channel at R34.M1.
- **Substrate at R34.M1:** the schema (this document + its `.pdx`
  companion). The publisher-side wire half is scaffolded — the class
  driver will consume it when R34.M2 lands.

---

## 3. Bit layout

### 3.1 `DEVICE_ATTACHED` frame (op `0x40`, one word)

```
bits    63:32     31:24  23:16  15:8       7:0
        reserved  speed  port   hub_slot   op=0x40
```

`speed` is the ordinal from `KIND_USB_DEVICE` §4 (`LOW=1`, `FULL=2`,
`HIGH=3`, `SUPER=4`). `hub_slot` is the cap_table slot of the
`KIND_USB_HUB` the port belongs to. `port` is the 0-based port
index (0..15).

### 3.2 `DEVICE_DETACHED` frame (op `0x41`, one word)

```
bits    63:24     23:16  15:8       7:0
        reserved  port   hub_slot   op=0x41
```

### 3.3 `PORT_STATUS_CHG` frame (op `0x42`, one word)

```
bits    63:32     31:24  23:16  15:8       7:0
        reserved  event  port   hub_slot   op=0x42
```

`event` is the ordinal from `hub_fsm.pdx` (`CONNECT=1`,
`RESET_START=2`, `ADDRESSED=3`, `CONFIGURED=4`, `DISCONNECT=5`).

Op ordinals occupy `0x40..0x42`, disjoint from
`audio_routing_channel`'s `0x20..0x23`.

---

## 4. Effect row and capability discipline

The session type is:

```
hub_topology : Channel {
  !{ hub_status_recv }
  { device_attached(hub_slot, port, speed)
  | device_detached(hub_slot, port)
  | port_status_change(hub_slot, port, event_kind) }*
}
```

The `!{hub_status_recv}` effect names the ONE authority the session
carries — the subscriber's right to be told about topology events on
the hubs the class driver has already gated access to. Because the
mint half lives on the endpoint (the class driver holds `RIGHT_MINT`)
and the receive half lives on the effect (subscribers hold
`hub_status_recv`), a subscriber cannot smuggle an event into the
stream, and the class driver cannot receive an event on the same
channel it publishes on.

---

## 5. Reserved bits are refused, never masked

Every packed frame has reserved bit ranges. The packers refuse a
payload with any set. Same argument as `codec_query_channel` §2 and
`pcm_ring_channel` §2 and `audio_routing_channel` §5.

---

## 6. Refuse, never clamp

- `hub_slot` not in `[0, 255]` -> `BAD_SLOT`.
- `port` not in `[0, 15]` -> `BAD_PORT` (`hub_fsm.pdx`'s
  `HUB_FSM_MAX_PORTS`).
- `speed` not in `[LOW, SUPER]` -> `BAD_SPEED`.
- `event` not in `[CONNECT, DISCONNECT]` -> `BAD_EVENT`.
- Unknown op -> `BAD_OP`.

Clamping would erase the distinction between "the caller asked for a
value in range" and "the packer decided a value for them".

---

## 7. Deferrals

- **Wire framing.** The kernel schema lands the pack/unpack +
  validator discipline. The publisher/subscriber wire wiring (the
  actual svc endpoint published as `svc.hub_topology`) is R34.M2
  work.
- **Bulk topology snapshots.** A subscriber that comes up late may
  want the current hub graph; that is a REQUEST on a DIFFERENT
  session (a topology-query channel not designed here). The event
  stream deliberately does not support "replay" — a subscriber that
  missed an event was not subscribed at the time, and reconstructing
  history from an event stream builds a router the class driver
  never authorised.
- **Hub-level events beyond port status.** Hub power state changes,
  overcurrent conditions, and TT-buffer overruns are per-hub events
  that don't fit the (hub_slot, port, ...) shape. A sibling channel
  handles those (not designed here).

---

## 8. Error codes `0xFFFFFC90..0xFFFFFC9F`

Disjoint from `AUDIO_ROUTING_*` (0xFFFFFCA0..AF), `HUB_FSM_*`
(0xFFFFFCB0..BF), `HUB_DRV_*` (0xFFFFFCC0..CF) and every other
channel band.
