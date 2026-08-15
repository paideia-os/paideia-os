# PaideiaOS — IPC Schema: `driver_lifecycle_channel`

**Status:** Design v0.1 (wire code deferred — see §7)
**Date:** 2026-08-12
**Round:** R29.M2-005 (issue #1027)
**Companion:** `design/drivers/framework.md` §5 (Driver lifecycle FSM),
`design/ipc/acpi-supervisor-schema.md` (framing template),
`src/kernel/core/driver/lifecycle.pdx` (kernel-side FSM primitives —
R29.M2-001 landing),
`src/kernel/core/driver/lifecycle_schema.pdx` (schema constants).

---

## 1. Purpose

Specify the request/reply record shapes exchanged between the userspace
**driver-lifecycle-supervisor** and each driver process it commands.
Serves the R29.M2-005 acceptance criterion: "session-typed schema;
timeouts + error codes; canonical example driver".

Each opcode drives one edge of the six-state FSM defined by
`src/kernel/core/driver/lifecycle.pdx` (see the whitelist encoded as
`DRIVER_LIFECYCLE_TABLE = 0x00000020101A1C12`, widened from
`0x00000020101A1C02` by R29.M7-001 (#1044) to admit the
`Init -> Stopping` abandon edge — see
`design/drivers/cascade-restart.md` §4.1). The kernel enforces
transition validity via `driver_lifecycle_transition`; the schema
below is the *userspace* protocol that carries the intent from
supervisor to driver plus the driver's ack back.

---

## 2. Endpoint and direction

- **Requester:** `svc.driver_lifecycle_supervisor`. Holds
  `Cap<KIND_DRIVER>` mint authority (for start) plus a *send* handle on
  the per-driver `driver_lifecycle_channel`.
- **Responder:** the driver process. Holds a *recv* handle plus a
  narrow `Cap<KIND_HW_*>` bundle for its device.
- **Framing:** the 8-byte header from `design/ipc/frame.pdx`;
  `reply_endpoint_id` at bytes 2..3 carries the supervisor's ack
  endpoint (dual-endpoint pattern per R20b.M6-003).
- **Reply-op bit:** `FRAME_OP_REPLY_BIT = 0x80`. Replies flip bit 7 of
  the request opcode: `DRV_LC_OP_START` (0x01) → reply op `0x81`.

---

## 3. Opcode table (v1)

Each opcode maps 1:1 onto an FSM transition edge from
`src/kernel/core/driver/lifecycle.pdx`:

| Opcode | Symbol                        | FSM edge                        | Req  →  Rep records                     |
|--------|-------------------------------|---------------------------------|-----------------------------------------|
| 0x01   | `DRV_LC_OP_START`             | `Init      → Running`           | `DrvLcStartReq`         → `DrvLcAckRep` |
| 0x02   | `DRV_LC_OP_INIT_DONE`         | driver-side ack of `START`      | `DrvLcInitDoneReq`      → `DrvLcAckRep` |
| 0x03   | `DRV_LC_OP_SUSPEND`           | `Running   → Suspended`         | `DrvLcSuspendReq`       → `DrvLcAckRep` |
| 0x04   | `DRV_LC_OP_RESUME`            | `Suspended → Running`           | `DrvLcResumeReq`        → `DrvLcAckRep` |
| 0x05   | `DRV_LC_OP_HANDOFF_BEGIN`     | `{Running,Suspended} → Handoff` | `DrvLcHandoffBeginReq`  → `DrvLcAckRep` |
| 0x06   | `DRV_LC_OP_STOP`              | `{Running,Suspended,Handoff} → Stopping` | `DrvLcStopReq` → `DrvLcAckRep` |

Opcodes 0x07..0x7E reserved for future edges (a hypothetical
`DRV_LC_OP_FREEZE` for hibernation lands here). Opcode 0x7F is
reserved for `DRV_LC_OP_ERROR` (an out-of-band error report from
driver → supervisor). Opcodes 0x80..0xFF are the reply-bit range.

`DRV_LC_OP_INIT_DONE` is the sole **driver-initiated** opcode in v1:
the driver signals init completion so the supervisor promotes its
kernel-side row from `Init` to `Running` via
`driver_lifecycle_transition(slot, DRIVER_STATE_RUNNING)`.

---

## 4. Record layouts

All request records are fixed-layout; the ack reply is a compact
error-code payload. Multi-byte scalars are little-endian.

### 4.1 `DrvLcStartReq` — 24 bytes fixed

| Offset | Field           | Width | Description |
|--------|-----------------|-------|-------------|
| +0     | `driver_slot`   | u16   | Slot index in `_driver_table` (0..31). |
| +2     | `reserved0`     | u16   | Zero-pad; MUST be 0 in v1. |
| +4     | `flags`         | u32   | Bit 0 = `restart_from_snapshot`. Bits 1..31 reserved. |
| +8     | `caps_manifest` | u64   | Kernel VA of the driver's cap-manifest region. |
| +16    | `timeout_ns`    | u64   | Absolute deadline for `INIT_DONE`; 0 = no timeout. |

### 4.2 `DrvLcInitDoneReq` — 8 bytes fixed

| Offset | Field         | Width | Description |
|--------|---------------|-------|-------------|
| +0     | `driver_slot` | u16   | Slot the driver was started at (echo). |
| +2     | `reserved0`   | u16   | Zero-pad. |
| +4     | `init_flags`  | u32   | Bit 0 = `wants_msix`. Reserved bits MUST be 0. |

### 4.3 `DrvLcSuspendReq` — 16 bytes fixed

| Offset | Field         | Width | Description |
|--------|---------------|-------|-------------|
| +0     | `driver_slot` | u16   | Target driver slot. |
| +2     | `power_state` | u8    | ACPI D-state (0=D0, 1=D1, 2=D2, 3=D3hot, 4=D3cold). |
| +3     | `reserved0`   | u8    | Zero-pad. |
| +4     | `reserved1`   | u32   | Zero-pad. |
| +8     | `timeout_ns`  | u64   | Suspend-quiescence deadline; 0 = no timeout. |

### 4.4 `DrvLcResumeReq` — 8 bytes fixed

| Offset | Field         | Width | Description |
|--------|---------------|-------|-------------|
| +0     | `driver_slot` | u16   | Target driver slot. |
| +2     | `reserved0`   | u16   | Zero-pad. |
| +4     | `resume_hint` | u32   | Bit 0 = `expedited` (skip probe re-scan). |

### 4.5 `DrvLcHandoffBeginReq` — 16 bytes fixed

| Offset | Field           | Width | Description |
|--------|-----------------|-------|-------------|
| +0     | `driver_slot`   | u16   | Outgoing driver slot. |
| +2     | `reserved0`     | u16   | Zero-pad. |
| +4     | `reserved1`     | u32   | Zero-pad. |
| +8     | `snapshot_cap`  | u64   | Cap slot of a `KIND_MEMORY` region into which the driver serializes its handoff state. |

### 4.6 `DrvLcStopReq` — 8 bytes fixed

| Offset | Field         | Width | Description |
|--------|---------------|-------|-------------|
| +0     | `driver_slot` | u16   | Target driver slot. |
| +2     | `reason`      | u8    | `0 = planned`, `1 = crash_replace`, `2 = device_departed`, `3 = policy`. |
| +3     | `reserved0`   | u8    | Zero-pad. |
| +4     | `grace_ms`    | u32   | Milliseconds to wait for a clean drain before the supervisor force-reaps. |

### 4.7 `DrvLcAckRep` — 8 bytes fixed

| Offset | Field           | Width | Description |
|--------|-----------------|-------|-------------|
| +0     | `driver_slot`   | u16   | Echo of request slot for correlation. |
| +2     | `reserved0`     | u16   | Zero-pad. |
| +4     | `rc`            | u32   | 0 = OK; else one of `DRV_LC_ACK_ERR_*` below. |

---

## 5. Error codes (mirrored in `lifecycle_schema.pdx`)

```
DRV_LC_ACK_OK                       = 0
DRV_LC_ACK_ERR_BAD_SLOT             = 1   // slot >= 32 OR not in_use
DRV_LC_ACK_ERR_INVALID_TRANSITION   = 2   // kernel rejected the edge
DRV_LC_ACK_ERR_TIMEOUT              = 3   // deadline expired before ack
DRV_LC_ACK_ERR_DEVICE_GONE          = 4   // MMIO returned all-1s during op
DRV_LC_ACK_ERR_CAP_MISSING          = 5   // driver lacks a required cap
DRV_LC_ACK_ERR_INTERNAL             = 6   // driver-side unexpected fault
```

Codes 1–2 correlate directly with `DRIVER_LIFECYCLE_ERR_BAD_SLOT`
(0xFFFFFF01) and `DRIVER_LIFECYCLE_ERR_INVALID_TRANSITION` (0xFFFFFF03)
returned by `driver_lifecycle_transition`. Codes 3–6 are userspace-side
failures the kernel cannot detect.

---

## 6. Wire-round-trip invariants

1. **Round-trip identity:** every request record is fixed-layout; the
   packed record is byte-identical to its decode.
2. **Reply-bit convention:** every response's `op` is
   `(request_op) | 0x80`. The dispatcher branches on the bit before
   record decode.
3. **Version monotonicity:** v2 may add opcodes 0x07..0x7E, or append
   trailing fields to existing records provided their `payload_len`
   grows in kind — existing offset assignments are frozen.
4. **Timeouts:** every request-carrying-a-deadline (start / suspend /
   stop) MUST set `timeout_ns` OR `grace_ms`; 0 = no timeout only for
   test / boot use.
5. **Kernel-side coupling:** every ack with `rc == DRV_LC_ACK_OK` MUST
   be preceded by a kernel-side `driver_lifecycle_transition` returning
   `DRIVER_LIFECYCLE_OK`. The R29.M2-004 fuzz witness enforces the
   kernel's half of this coupling directly against the FSM primitives.

---

## 7. Why the code is deferred (paideia-os current state)

The paideia-os R29.M2-005 landing publishes constants only:
- **`lifecycle_schema.pdx`** — opcode + size + offset + ack-error
  constants. No encoder/decoder yet (framing lives in `ipc/frame.pdx`;
  per-payload packers land with R29.M3 registry v2).
- **No supervisor process** — `svc.driver_lifecycle_supervisor` will
  be spawned by the phase-2 loader once R29.M3's per-driver ELF+PE
  gates land.
- **No driver-side dispatch loop** — the "canonical example driver"
  called for by the acceptance criterion is deferred to the R30
  `lpss_uart_driver` (the simplest post-MVP driver process); that
  driver will implement the six-op state machine on top of these
  constants as its own R30.M5 witness.

The schema in this document is **authoritative**; future code MUST
match it byte-for-byte.

---

## 8. Cross-references

- `design/drivers/framework.md` §5 — driver lifecycle FSM prose.
- `design/ipc/driver-hotplug-schema.md` — sister channel for
  device-arrival / departure that triggers `DRV_LC_OP_START`.
- `design/ipc/frame.pdx` — 8-byte header framing.
- `design/architecture/next-wave-derived-kinds.md` §Driver lifecycle
  FSM — kernel-side FSM constants + transition table.
- `src/kernel/core/driver/lifecycle.pdx` — the kernel primitives
  every ack correlates with.
- `src/kernel/core/driver/lifecycle_schema.pdx` — schema constants.
