# PaideiaOS — IPC Schema: `acpi_supervisor` RPCs

**Status:** Design v0.1 (wire code deferred — see §7)
**Date:** 2026-08-10
**Round:** R20.M4 (issue #821)
**Companion:** `design/acpi/no-aml-in-kernel.md` (#822), `src/kernel/core/cap/acpi_cap.pdx` (#819)

---

## 1. Purpose

Specify the request/reply record shapes exchanged between the userspace
`acpi_supervisor` server (holder of the sole `KIND_ACPI` capability) and
any client that needs a parsed view of an ACPI static table. Serves
issue #821's acceptance criterion "typed request/reply records:
AcpiEnumReq/Rep, AcpiMadtReq/Rep, AcpiMcfgReq/Rep, AcpiHpetReq/Rep" and
"Wire format compatible with existing IPC msg framing."

The schema is authoritative even though the wire encoder/decoder code
is deferred (see §7). Once IPC framing arrives with variable-length
message support and named endpoints, this document dictates the record
layouts the code must implement.

---

## 2. Server identity and endpoint discovery

- **Server name:** `svc.acpi` (well-known service name; resolvable
  through the yet-to-land service-broker capability).
- **Server binary:** `src/user/acpi_supervisor/main.pdx` (deferred; see §7).
- **Capability held:** exactly one `KIND_ACPI` capability, minted by
  the kernel at boot from `boot_env_t.rsdp_pa` (see `acpi_cap.pdx`),
  handed to the supervisor via the initial capability-transfer slot
  reserved for it in the process's CSpace.
- **Endpoint:** a `KIND_IPC_ENDPOINT` cap opened at supervisor init
  and registered with the service broker under `svc.acpi`.

---

## 3. Message framing

Every request and reply is prefixed by an 8-byte header:

```
+------+------+------+------+------+------+------+------+
|  op  |  ver | flags (2B) |     payload_len (u32)      |
+------+------+------+------+------+------+------+------+
```

| Field         | Width | Description |
|---------------|-------|-------------|
| `op`          | u8    | RPC opcode (see §4). |
| `ver`         | u8    | Schema version — starts at 1. |
| `flags`       | u16   | Reserved; MUST be 0 in v1. |
| `payload_len` | u32 LE | Payload byte count, exclusive of header. Max 4096 (bounded by the wait-free dataflow slot size — `design/ipc/wait-free-dataflow.md`). |

Header size: **8 bytes.**
All multi-byte scalars are **little-endian**, matching x86-64 and the
raw ACPI-table byte order.

Reply framing is identical; a reply's `op` is the request `op` with
bit 7 set (`op | 0x80`).

---

## 4. Opcode table (v1)

| Opcode | Symbol                | Req  →  Rep record types                    |
|--------|-----------------------|---------------------------------------------|
| 0x01   | `ACPI_OP_ENUMERATE`   | `AcpiEnumReq`  →  `AcpiEnumRep`             |
| 0x02   | `ACPI_OP_GET_MADT`    | `AcpiMadtReq`  →  `AcpiMadtRep`             |
| 0x03   | `ACPI_OP_GET_MCFG`    | `AcpiMcfgReq`  →  `AcpiMcfgRep`             |
| 0x04   | `ACPI_OP_GET_HPET`    | `AcpiHpetReq`  →  `AcpiHpetRep`             |
| 0x05   | `ACPI_OP_GET_FADT`    | `AcpiFadtReq`  →  `AcpiFadtRep`             |
| 0x7F   | `ACPI_OP_ERROR`       | *(unused as request)* → `AcpiErrorRep`      |

Opcodes 0x06–0x7E are reserved for future static-table exposures
(SRAT, SLIT, DMAR, IVRS). Opcodes 0x80–0xFF are reserved for reply
sentinels only.

---

## 5. Record layouts

All records are **fixed-layout** for the request side (small,
scalar-only). Reply records for enumeration and MADT carry an inline
variable-length trailing region whose length is announced by the
header's `payload_len`.

### 5.1 `AcpiEnumReq` — 0 bytes payload

The request carries no fields.

**Assertion:** `sizeof(AcpiEnumReq) == 0`.

### 5.2 `AcpiEnumRep` — variable

```
+------------+-----------------------------------------+
| n_tables u16 |  table_desc[n_tables]                 |
+------------+-----------------------------------------+
```

Each `table_desc` is 24 bytes:

| Offset | Field       | Width | Description |
|--------|-------------|-------|-------------|
| +0     | `sig`       | 4B    | 4-char signature ("APIC","MCFG","HPET","FACP","XSDT","RSDT",…) |
| +4     | `revision`  | u8    | SDT header `revision` byte |
| +5     | `reserved`  | 3B    | Zero-pad |
| +8     | `phys_addr` | u64   | Physical address of the table image |
| +16    | `length`    | u32   | SDT header `length` field |
| +20    | `oem_id`    | 4B    | First 4 bytes of the OEMID (truncated for record compactness) |

**Assertion:** `sizeof(table_desc) == 24`.
**Reply payload_len** = `2 + n_tables * 24`.

### 5.3 `AcpiMadtReq` — 0 bytes payload

**Assertion:** `sizeof(AcpiMadtReq) == 0`.

### 5.4 `AcpiMadtRep` — variable

```
+------------+------------+---------+-----------------+
| n_lapics u16 | n_ioapics u16 | n_isos u16 | trailing |
+------------+------------+---------+-----------------+
```

Trailing region carries three parallel arrays in this order:
1. `n_lapics × 12` bytes — one `LapicDesc` per Local APIC.
2. `n_ioapics × 12` bytes — one `IoapicDesc` per I/O APIC.
3. `n_isos × 12` bytes — one `IsoDesc` per Interrupt Source Override.

`LapicDesc` (12 bytes):

| Offset | Field         | Width | Description |
|--------|---------------|-------|-------------|
| +0     | `acpi_uid`    | u8    | Processor UID |
| +1     | `apic_id`     | u8    | LAPIC ID |
| +2     | `flags`       | u16   | Bit 0 = enabled, bit 1 = online-capable |
| +4     | `reserved`    | 8B    | Zero-pad (aligns to 12 total) |

`IoapicDesc` (12 bytes):

| Offset | Field       | Width | Description |
|--------|-------------|-------|-------------|
| +0     | `ioapic_id` | u8    |             |
| +1     | `reserved`  | 3B    | Zero-pad    |
| +4     | `mmio_addr` | u32   | IOAPIC MMIO base |
| +8     | `gsi_base`  | u32   | Global system interrupt base |

`IsoDesc` (12 bytes):

| Offset | Field       | Width | Description |
|--------|-------------|-------|-------------|
| +0     | `bus`       | u8    | 0 = ISA     |
| +1     | `source`    | u8    | ISA IRQ line |
| +2     | `reserved`  | 2B    | Zero-pad    |
| +4     | `gsi`       | u32   | Global system interrupt |
| +8     | `flags`     | u16   | MPS INTI flags (polarity/trigger) |
| +10    | `reserved2` | 2B    | Zero-pad    |

**Assertions:**
`sizeof(LapicDesc) == 12`, `sizeof(IoapicDesc) == 12`, `sizeof(IsoDesc) == 12`.
Reply `payload_len` = `6 + 12 * (n_lapics + n_ioapics + n_isos)`.

### 5.5 `AcpiMcfgReq` — 0 bytes payload

**Assertion:** `sizeof(AcpiMcfgReq) == 0`.

### 5.6 `AcpiMcfgRep` — variable

```
+---------------+-----------------------------------+
| n_segments u16 |  segment_desc[n_segments]        |
+---------------+-----------------------------------+
```

`segment_desc` (16 bytes):

| Offset | Field         | Width | Description |
|--------|---------------|-------|-------------|
| +0     | `ecam_base`   | u64   | Physical base of the segment's ECAM window |
| +8     | `segment`     | u16   | PCI segment group number |
| +10    | `bus_start`   | u8    | First bus in segment |
| +11    | `bus_end`     | u8    | Last bus in segment |
| +12    | `reserved`    | 4B    | Zero-pad |

**Assertion:** `sizeof(segment_desc) == 16`.
Reply `payload_len` = `2 + n_segments * 16`.

### 5.7 `AcpiHpetReq` — 0 bytes payload

**Assertion:** `sizeof(AcpiHpetReq) == 0`.

### 5.8 `AcpiHpetRep` — 24 bytes fixed

| Offset | Field           | Width | Description |
|--------|-----------------|-------|-------------|
| +0     | `mmio_base`     | u64   | HPET MMIO base (physical) |
| +8     | `period_fs`     | u64   | Counter period in femtoseconds |
| +16    | `vendor_id`     | u16   | From block id |
| +18    | `comparator_ct` | u8    | Number of comparators |
| +19    | `hpet_number`   | u8    | Sequence number |
| +20    | `min_tick`      | u16   | Minimum tick (in main-counter units) |
| +22    | `page_protect`  | u8    | Page-protection attribute |
| +23    | `reserved`      | u8    | Zero-pad |

**Assertion:** `sizeof(AcpiHpetRep) == 24`.

### 5.9 `AcpiFadtReq` — 0 bytes payload

### 5.10 `AcpiFadtRep` — 32 bytes fixed

| Offset | Field            | Width | Description |
|--------|------------------|-------|-------------|
| +0     | `pm1a_evt_blk`   | u32   | PM1a Event Block I/O port |
| +4     | `pm1b_evt_blk`   | u32   | PM1b Event Block I/O port (0 if none) |
| +8     | `pm_tmr_blk`     | u32   | PM Timer Block I/O port |
| +12    | `reset_reg_addr` | u64   | Reset register address (GAS-decoded) |
| +20    | `reset_value`    | u8    | Byte to write to reset register |
| +21    | `reset_space_id` | u8    | GAS address-space ID |
| +22    | `century`        | u8    | RTC CMOS century-register index (0 = absent) |
| +23    | `reserved`       | u8    | Zero-pad |
| +24    | `flags`          | u64   | Copy of FADT bit-flags word |

**Assertion:** `sizeof(AcpiFadtRep) == 32`.

### 5.11 `AcpiErrorRep` — 8 bytes fixed

| Offset | Field       | Width | Description |
|--------|-------------|-------|-------------|
| +0     | `err_code`  | i32   | Errno-style negative value (–EPERM, –ENOENT, –EINVAL, …) |
| +4     | `context`   | u32   | Opcode that produced the error; zero if pre-dispatch |

**Assertion:** `sizeof(AcpiErrorRep) == 8`.

Sent in place of a normal reply whenever:
- the client's capability lacks `R_ACPI_READ` (→ –EPERM),
- the requested table is absent (→ –ENOENT),
- the request `ver` is unsupported (→ –EINVAL),
- `payload_len` exceeds the framing bound (→ –E2BIG).

---

## 6. Wire-round-trip invariants

The following invariants MUST hold once the wire code lands (§7):

1. **Round-trip identity:** for every request/reply pair, encode(decode(bytes))
   is byte-identical to `bytes`.
2. **Size assertion:** every `sizeof(*)` value in §5 is a compile-time
   constant checked with `static_assert`-equivalent build-time predicates.
3. **Version monotonicity:** a v2 schema may only *add* opcodes and
   *append* fixed-offset fields — never renumber, resize, or reorder.
4. **Little-endian on wire:** matches x86-64 and raw ACPI-table byte
   order; no byte swaps.
5. **Zero-copy hot path:** `ACPI_OP_ENUMERATE` and `ACPI_OP_GET_*`
   replies MUST be constructable by the supervisor by copying directly
   out of the KIND_ACPI-mapped physical range, with parsing but no
   allocation on the reply path.

---

## 7. Why the code is deferred (paideia-os current state)

Landing wire code today would require infrastructure that does not yet
exist in paideia-os:

| Missing infrastructure | Where it will land |
|------------------------|--------------------|
| Framed variable-length IPC messages (current `channel.pdx` is a single 8-byte-slot SPSC ring — see `src/kernel/core/ipc/channel.pdx`) | Later IPC round; `design/ipc/phase1-api.md` §1 sketches the shape. |
| Named service broker (`svc.acpi` endpoint discovery) | Later userspace round; no design doc yet. |
| Userspace server process model + capability-injection at boot | R20.M4 blocker documented as separate paideia-os issue; supersedes issue #820. |
| Compile-time `static_assert` for record sizes | paideia-as feature (not yet implemented; workaround is a build-time smoke fixture that computes the size and traps on mismatch). |

Consequently:
- The **schema in this document is authoritative** — future code MUST
  match it byte-for-byte.
- Issue **#821 lands as this design doc**; the wire-code sub-task
  reopens once the framing + broker prerequisites are in place.
- Issue **#820 (the supervisor server binary) is deferred entirely**;
  see the paideia-os blocker issue filed alongside this round.

---

## 7a. The notification stream — producer landed at R30.M2-006 (#1059)

Everything in §§1–7 is **request/reply**: a client asks, the supervisor
answers. `Notify` is the one flow that runs the other way, and it does not
fit the RPC shape, so it does not use it.

### The producer does not send

The AML evaluator (`src/user/aml/aml_ctl.pdx`) **enqueues to a bounded
32-entry ring and returns**. It never sends and never waits. The reason is
in `design/acpi/aml-evaluator.md` §18 and it is worth restating here,
because it constrains what this schema may later specify: `Notify` appears
inside firmware-controlled loops, so an evaluator that sent synchronously
would let a table stall the supervisor, and a `Notify` issued while the
supervisor is handling a notification would deadlock — the drainer is not
draining, because it is inside the evaluator trying to enqueue.

So the supervisor's own loop is: evaluate → drain the ring → send. The
send is a separate step with separate error handling, and a slow or absent
consumer **cannot** back-pressure the interpreter.

### What this schema must therefore carry

Delivery is **lossy by construction** — the ring tail-drops when full —
and any future `ACPI_OP_EVENT` record must make that loss *localisable*
rather than merely countable:

| offset | field | type | note |
|--------|-------|------|------|
| +0 | `sequence` | u64 | monotonic offer number; **a gap means dropped events** |
| +8 | `target_path` | u32 | interned absolute namespace path |
| +12 | `object_type` | u8 | 6 Device / 12 Processor / 13 ThermalZone |
| +13 | `notify_value` | u8 | the ACPI notification value |
| +14 | `flags` | u16 | bit 0 — a drop occurred immediately before this |
| +16 | `drops_total` | u64 | producer's cumulative drop count at enqueue |

A consumer that sees `sequence` jump by more than one re-enumerates the
affected bus; without the sequence it would have to re-enumerate
everything on any non-zero drop count, which is the difference between a
recoverable drop and a useless one.

Full derived-kind row — base kind, rights bitmask, why no `INVOKE` right
— in `design/architecture/next-wave-derived-kinds.md`,
`KIND_ACPI_EVENT = 0x21`. The capability mint and the drain loop are
R30.M4's; only the producer and the record shape are fixed today.

---

## 8. Cross-references

- `design/ipc/phase1-api.md` — the target IPC framing shape.
- `design/ipc/wait-free-dataflow.md` — the wait-free channel that will
  carry these RPCs when it lands.
- `design/acpi/no-aml-in-kernel.md` — sibling guardrail (#822).
- `src/kernel/core/cap/acpi_cap.pdx` — the KIND_ACPI derived capability
  that the supervisor holds (#819).
- `src/kernel/acpi/*.pdx` — the R20.M1–M3 static-table parsers whose
  output the supervisor re-exposes over the wire.
