# PaideiaOS — IPC Schema: `driver_hotplug_channel`

**Status:** Design v0.1 (wire code deferred — see §7)
**Date:** 2026-08-12
**Round:** R29.M2-003 (issue #1025)
**Companion:** `design/drivers/framework.md` §7 (Hot-plug protocol),
`design/ipc/acpi-supervisor-schema.md` (framing template),
`src/kernel/core/driver/hotplug_schema.pdx` (schema constants).

---

## 1. Purpose

Specify the record shapes streamed over `driver_hotplug_channel` from a
bus driver (PCI enumerator, xHCI hub monitor, LPSS bus driver, …) to
the userspace **driver-loader** process (holder of `Cap<KIND_DRIVER>`
minter authority). Serves the R29.M2-003 acceptance criterion:
"session-typed schema; `Cap<KIND_DEVICE>` payload; supervisor emits on
probe".

Per `design/roadmap/next-wave-softarch.md` §3 R29 the channel is a
**stream** (not RPC) — the sender fires-and-forgets, the loader drains.
Ordering per (bus, device) is preserved; cross-bus ordering is
supervisor-defined.

---

## 2. Endpoint and direction

- **Sender:** any bus-driver process (one per bus segment; PCI /
  xHCI-root / LPSS / thunderbolt / …). Holds a `KIND_HW`-family cap
  for the bus and a *send* handle on `driver_hotplug_channel`.
- **Receiver:** `svc.driver_loader` (well-known name via the
  R20b broker). Holds the *recv* handle plus `Cap<KIND_DRIVER>` mint
  authority.
- **Framing:** the 8-byte header from `design/ipc/frame.pdx`
  (`FRAME_HEADER_SIZE = 8`); `op` at byte 0, `ver` at byte 1,
  `reply_endpoint_id` at bytes 2..3 (unused for this stream — MUST
  be 0), `payload_len` at bytes 4..7 (little-endian).

Because the channel is one-way there are **no reply opcodes** —
`op & 0x80` is reserved (MUST be 0 in v1).

---

## 3. Opcode table (v1)

| Opcode | Symbol                       | Req record          |
|--------|------------------------------|---------------------|
| 0x01   | `DRV_HP_OP_DEVICE_ARRIVED`   | `DrvHpArrivedReq`   |
| 0x02   | `DRV_HP_OP_DEVICE_DEPARTED`  | `DrvHpDepartedReq`  |

Opcodes 0x03..0x7E reserved for future arrivals (`device_reprobe`,
`bus_reset_complete`); 0x7F is reserved for a `DRV_HP_OP_ERROR`
telemetry sentinel; 0x80..0xFF are the reply-bit range — unused here
per §2.

---

## 4. Record layouts

All records are fixed-layout (no variable trailers in v1). Multi-byte
scalars are little-endian.

### 4.1 `DrvHpArrivedReq` — 24 bytes fixed

| Offset | Field         | Width | Description |
|--------|---------------|-------|-------------|
| +0     | `bdf`         | u16   | PCI Bus/Device/Function packed as `(bus:8, dev:5, fn:3)`. For non-PCI buses, `bus` is the bus-driver-assigned segment id, `dev`/`fn` are the address on that segment. |
| +2     | `reserved0`   | u16   | Zero-pad; MUST be 0 in v1. |
| +4     | `vendor_id`   | u16   | Device vendor id (PCI VID; USB idVendor; ACPI HID hash). |
| +6     | `device_id`   | u16   | Device id (PCI DID; USB idProduct; ACPI CID hash). |
| +8     | `class_code`  | u32   | Class code (PCI `class << 16 | subclass << 8 | prog_if`; USB bDeviceClass in low byte). |
| +12    | `reserved1`   | u32   | Zero-pad; MUST be 0 in v1. |
| +16    | `device_cap`  | u64   | Cap-slot index of a `Cap<KIND_DEVICE>` freshly-minted by the sender against the loader's cap table (out-of-band cap-transfer via `KIND_DRIVER` mint authority; sender revokes on error). |

**Assertion:** `sizeof(DrvHpArrivedReq) == 24`.
Request `payload_len` = 24.

### 4.2 `DrvHpDepartedReq` — 8 bytes fixed

| Offset | Field       | Width | Description |
|--------|-------------|-------|-------------|
| +0     | `bdf`       | u16   | Same encoding as arrival. |
| +2     | `reserved0` | u16   | Zero-pad; MUST be 0 in v1. |
| +4     | `reason`    | u32   | `0 = graceful`, `1 = surprise_removal`, `2 = bus_reset`, `3 = probe_reject`. Extensible; loader treats unknown reasons as `1`. |

**Assertion:** `sizeof(DrvHpDepartedReq) == 8`.
Request `payload_len` = 8.

`device_cap` is **not** re-transmitted on departure — the loader looked
it up via `(bdf, sender-id)` in its own registry when the arrival
landed; the sender is responsible for revoking its send-side handle
once the departure is drained by the loader (dual-ack via the R29.M6
audit channel).

---

## 5. Constants (mirrored in `hotplug_schema.pdx`)

```
DRV_HP_SCHEMA_VERSION       = 1
DRV_HP_OP_DEVICE_ARRIVED    = 0x01
DRV_HP_OP_DEVICE_DEPARTED   = 0x02
DRV_HP_SIZEOF_ARRIVED       = 24
DRV_HP_SIZEOF_DEPARTED      = 8
DRV_HP_ARRIVED_OFF_BDF          = 0
DRV_HP_ARRIVED_OFF_VENDOR       = 4
DRV_HP_ARRIVED_OFF_DEVICE       = 6
DRV_HP_ARRIVED_OFF_CLASS_CODE   = 8
DRV_HP_ARRIVED_OFF_DEVICE_CAP   = 16
DRV_HP_DEPARTED_OFF_BDF         = 0
DRV_HP_DEPARTED_OFF_REASON      = 4
DRV_HP_DEPART_REASON_GRACEFUL   = 0
DRV_HP_DEPART_REASON_SURPRISE   = 1
DRV_HP_DEPART_REASON_BUS_RESET  = 2
DRV_HP_DEPART_REASON_PROBE_REJ  = 3
```

---

## 6. Wire-round-trip invariants

1. **Round-trip identity:** `encode(decode(bytes)) == bytes` on both
   record types (fixed-layout guarantees byte identity).
2. **Little-endian on wire:** matches x86-64 native.
3. **Version monotonicity:** v2 may add opcodes and append fields but
   never renumber, resize, or reorder existing ones.
4. **Cap ownership on arrival:** the `device_cap` slot MUST be a
   linear-typed derivation from a `KIND_HW` cap the sender holds; the
   loader takes ownership on receipt. Double-arrival for the same
   `(bdf, sender-id)` is a schema violation (loader emits a
   `DRV_HP_OP_ERROR` sidecar via the R29.M6 audit channel).
5. **Loss discipline:** the channel is not lossy at v1 — the endpoint
   uses the wait-free single-in-flight ring from R20b. R29.M7's
   chaos-restart harness will exercise sender-side back-pressure.

---

## 7. Why the code is deferred (paideia-os current state)

The paideia-os R29.M2-003 landing publishes constants only:
- **`hotplug_schema.pdx`** — opcode + size + offset + reason constants,
  no encoder/decoder yet (framing lives in `ipc/frame.pdx`; per-payload
  packers land with R29.M3 registry v2 which needs these constants first).
- **No supervisor emit path** — the PCI enumerator (#860) exists as a
  design placeholder; the actual `device_arrived` emit will land with
  R29.M3 alongside the loader-side drain loop.
- **No `Cap<KIND_DEVICE>` mint helper** — `driver_cap.pdx` (`KIND_DRIVER`)
  is the closest today; the R29.M5 `KIND_DMA_DOMAIN` work extends the
  device-cap family, at which point the `device_cap` field in
  `DrvHpArrivedReq` binds to a concrete cap kind.

Consequently the schema in this document is **authoritative**; future
code MUST match it byte-for-byte.

---

## 8. Cross-references

- `design/drivers/framework.md` §7 — hot-plug protocol prose.
- `design/ipc/frame.pdx` — 8-byte header framing.
- `design/ipc/userspace-server-substrate.md` §4 — endpoint discipline.
- `design/architecture/next-wave-derived-kinds.md` §KIND_HW — parent
  cap family for the `device_cap` payload.
- `src/kernel/core/driver/hotplug_schema.pdx` — schema constants.
- `src/kernel/core/driver/lifecycle.pdx` — the FSM the loader drives
  once an arrival is matched to a driver binary.
