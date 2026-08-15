# PaideiaOS — IPC Schema: `i2c_transfer_channel`

**Round.** R30 — ACPICA userspace bubble + LPSS bus enablement
**Sub-milestone.** R30.M5
**Issue.** R30.M5-004 (#1073) — `i2c_transfer_channel` schema
(RPC `{write, read, write_read, smbus_op}`).
**Status.** Landed. Constants in
`src/kernel/core/drivers/i2c/xfer_schema.pdx`; engine in
`src/kernel/core/drivers/i2c/dw_xfer.pdx`; boot witness `R30 LPSS I2C OK`.

Companion: `design/drivers/lpss-i2c-controller.md` (#1072).

---

## 1. Purpose

A device driver holding a `Cap<KIND_I2C_SLAVE>` needs to move bytes to
and from exactly one peripheral on a shared bus. This schema is that
conversation.

It carries **four** opcodes and **no device address**, and the second
fact is the design.

---

## 2. Endpoint and direction

| | |
|---|---|
| Direction | device driver → LPSS I²C bus driver |
| Shape | request / reply, one reply per request |
| Session | opened by presenting a `Cap<KIND_I2C_SLAVE>`; **the capability is bound at open** |
| Reply convention | request opcode with bit 7 set (`0x81..0x84`), as `ipc/frame.pdx` and `driver_lifecycle_channel` |
| Version | v1 |

The bound capability is the session's identity. Every request carries
its handle so a multiplexing driver can hold several sessions, but the
handle names a capability — never an address.

---

## 3. The address comes from the capability. Always. Only.

`KIND_I2C_SLAVE` exists because I²C is a shared bus on which one
controller can address every peripheral. A capability that names one
address is isolation only if the address cannot come from anywhere else.

A request record with an `addr` field would make *"address a device
other than the one my capability names"* a **well-formed request** —
refusable by a check, and therefore refusable only for as long as
someone remembers to keep the check. The property this milestone must
preserve is stronger: the request is **unphrasable**.

Five things enforce it, at three different layers:

1. **The wire record has no address field**, and its two reserved fields
   are *must be zero*, so a later revision cannot quietly repurpose one
   without a decoder rejecting it.
2. **The four kernel primitives take a capability slot first and no
   address**:
   ```
   i2c_xfer_write      : (u64, u64, u64, u64)           -> u64
   i2c_xfer_read       : (u64, u64, u64, u64)           -> u64
   i2c_xfer_write_read : (u64, u64, u64, u64, u64, u64) -> u64
   i2c_smbus_op        : (u64, u64, u64, u64, u64)      -> u64
   ```
3. **The three identity resolvers are arity one**:
   `i2c_slave_addr_of_slot`, `i2c_slave_mode_of_slot`,
   `i2c_slave_bus_row_of_slot`.
4. **`tools/build.sh` pins all seven literal signature lines**
   (`[i2c-addr-confine]`), so a mutant that adds a parameter fails the
   **build**, not the review.
5. **Witness sub-test Q is the runtime half**: a neighbouring device's
   address is loaded into every register a smuggled parameter could
   arrive in, before each resolver call and before a real transfer, and
   the answer — and `IC_TAR` on the wire — is still `0x1A`.

### 3.1 Mode and bus row are each half of an address

The pin set covers three resolvers and not one, because on this bus the
address alone is not the address.

* **Addressing mode.** A 7-bit device at `0x1A` and a 10-bit device at
  `0x01A` are the same number and different byte sequences on the wire.
  A caller-supplied mode reaches the wrong one of the two while passing
  every address check.
* **Bus row.** Address `0x1A` on the touchpad controller and `0x1A` on
  the sensor hub are two devices on two pairs of wires. #1071
  deliberately scoped its uniqueness key to the bus so both can be
  minted; a caller-supplied controller would turn that *permission at
  mint* into a *confusion at transfer*.

---

## 4. Opcode table (v1)

| op | name | wire behaviour |
|---|---|---|
| `0x01` | `WRITE` | addressed write of `wr_len` bytes, STOP at the end |
| `0x02` | `READ` | addressed read of `rd_len` bytes, STOP at the end |
| `0x03` | `WRITE_READ` | `wr_len` bytes written, **REPEATED START**, `rd_len` bytes read, STOP |
| `0x04` | `SMBUS` | one of the SMBus protocols in §6 |

### 4.1 Why `WRITE_READ` is an opcode and not two requests

Nearly every register read on an I²C part is "write the register
pointer, then read". The two halves must **not** be separated by a STOP.

A STOP releases the bus. Another master may take it; the part may time
out its own internal pointer. The read that follows then returns a
different register's contents, **with no error anywhere**.

Expressed as two requests, the atomicity becomes the caller's problem —
and the caller cannot solve it, because it does not own the bus between
them. So it is one operation, and the engine emits:

```
[data]* (no STOP)   RESTART+READ   [READ]*   READ+STOP
```

### 4.2 `IC_TAR` is programmed every transfer and never cached

DesignWare will not accept a new target address while enabled, so
retargeting is disable → write `IC_TAR` → enable, with two more bounded
waits per transfer. Caching the last address would remove them.

It is not done, and not for performance reasons. A cached target is a
claim about controller state that survives every event that invalidates
it: a bus recovery, a re-run of bring-up, a second driver selecting the
same controller, a controller that reset itself. When the cache is
wrong, the transfer reaches the **wrong device** at full speed with no
error — and "the wrong device on this bus" is the single failure the
whole capability pair exists to prevent. A cache that is right 99.9 % of
the time buys two register writes and sells the milestone's only
guarantee.

Witness sub-test J asserts the disable → `IC_TAR` → enable ordering by
trace position, and that `IC_TAR` holds the **capability's** address.

---

## 5. Record layouts

### 5.1 `I2cXferReq` — 24 bytes fixed

| off | type | field |
|---|---|---|
| `+0` | u16 | `slave_cap` — `cap_table` slot of the `Cap<KIND_I2C_SLAVE>` |
| `+2` | u8 | `op` |
| `+3` | u8 | `smbus_proto` (op == SMBUS only; 0 otherwise) |
| `+4` | u8 | `smbus_command` (op == SMBUS only; 0 otherwise) |
| `+5` | u8 | `flags` — **reserved, MUST BE ZERO** |
| `+6` | u16 | `wr_len` |
| `+8` | u16 | `rd_len` |
| `+10` | u16 | `_reserved` — **MUST BE ZERO** |
| `+12` | u32 | `budget` — bounded-wait iteration budget; 0 = channel default |
| `+16` | u64 | `buf_offset` — offset into the session's shared buffer |

**No address field**, in any revision. The two must-be-zero fields exist
so a v2 that tried to add one would be rejected by a v1 decoder rather
than silently reinterpreted.

### 5.2 `I2cXferRep` — 16 bytes fixed

| off | type | field |
|---|---|---|
| `+0` | u16 | `slave_cap` — echoed |
| `+2` | u8 | `op \| 0x80` |
| `+3` | u8 | `_pad` |
| `+4` | u32 | `rc` |
| `+8` | u16 | `rd_len_actual` |
| `+10` | u16 | `_pad2` |
| `+12` | u32 | `abort_source` — raw `IC_TX_ABRT_SOURCE` on an abort, else 0 |

`abort_source` is carried because the core distinguishes sixteen abort
reasons and the three codes below collapse them. A caller debugging an
unfamiliar part wants to know it was `ABRT_HS_ACKDET` and not merely
"aborted". It is cleared at the start of every transfer, so a successful
transfer cannot report a previous one's abort and send someone hunting a
fault that was already handled.

---

## 6. SMBus protocols

| proto | name | expressed as |
|---|---|---|
| `0x01` | `BYTE_WRITE` | write `{command}` |
| `0x02` | `BYTE_READ` | read 1 |
| `0x03` | `BYTE_DATA_WRITE` | write `{command, data0}` |
| `0x04` | `BYTE_DATA_READ` | write `{command}` : **RESTART** : read 1 |
| `0x05` | `WORD_DATA_WRITE` | write `{command, data0, data1}` |
| `0x06` | `WORD_DATA_READ` | write `{command}` : **RESTART** : read 2 |

Each is a **delegation** to one of the three I²C primitives, not a
parallel implementation. That is the point: the rights checks, the
bounded waits, the abort handling and the repeated-START discipline
exist once, so an SMBus transfer cannot acquire a bug the I²C path does
not have. The two read-type protocols get their repeated START for free,
and they need it — an SMBus register read separated by a STOP is exactly
the transaction that returns a neighbouring register's contents on a
part that times out its pointer.

### 6.1 Refused, by name and with a reason

| proto | name | why |
|---|---|---|
| `0x00` | `QUICK` | SMBus Quick is address plus the R/W bit and **nothing else**. A DesignWare transaction begins when an entry is pushed into `IC_DATA_CMD`, and there is no entry meaning "start and stop with no data byte" — the core cannot emit it. Substituting a one-byte write would be a *different transaction on the wire*, and on parts that use Quick as an on/off switch it would write a byte into whatever register the part's pointer happened to hold. |
| `0x07` | `BLOCK_WRITE` | |
| `0x08` | `BLOCK_READ` | Block transfers carry their length in the first byte, so a block read must read one byte, learn the length, and continue — a **length discovered mid-transfer**. This schema has the caller declare lengths up front, and a schema that let a *device* choose how many bytes to write into a caller's buffer is a schema with a device-controlled length. Deferred until the session grows an explicit two-phase form. |

Refusal is `LPSS_I2C_SMBUS_UNSUPPORTED`, raised before any bus state is
touched.

---

## 7. Rights are checked per direction

#1071 reserved `READ` (0x001) and `WRITE` (0x002) in
`R_I2C_SLAVE_ALL = 0x41B` with nothing consuming them, specifically so a
capability minted before this landing would be **refused** a transfer
rather than silently acquiring one on the day the op appeared. This
milestone consumes them.

| operation | required |
|---|---|
| `WRITE` | `INVOKE \| WRITE` (0x00A) |
| `READ` | `INVOKE \| READ` (0x009) |
| `WRITE_READ` | `INVOKE \| READ \| WRITE` (0x00B) |
| `SMBUS` | `INVOKE` plus whatever the sub-protocol needs (§6, via `i2c_smbus_proto_rights`) |

Three distinct refusals, not one:

| code | meaning |
|---|---|
| `I2C_XFER_NO_INVOKE` | may not transact at all |
| `I2C_XFER_NO_READ_RIGHT` | this capability is write-only |
| `I2C_XFER_NO_WRITE_RIGHT` | this capability is read-only |

They are three sentences, not one, because a sensor a driver may read
but must never program is a real and common arrangement whose
enforcement should be legible when it fires.

### 7.1 `WRITE_READ` needs `WRITE` even though it reads

The command byte moves the device's internal register pointer, which is
a state change the device is still in afterwards. A read-only holder
must not be able to leave a shared part pointed somewhere its owner did
not choose. *"It is only a register pointer"* is precisely the argument
by which a device gets reconfigured by a component that was supposed to
be looking at it.

Witness sub-test P asserts it end to end: a read-only capability
performing `BYTE_DATA_READ` is refused `NO_WRITE_RIGHT`.

### 7.2 Refusal happens before any register is touched

`i2c_xfer_resolve` runs entirely over the capability table and the row
tables. Witness sub-test I calls `i2c_xfer_write` on a read-only
capability and asserts both the code **and** an empty access trace: a
denied caller must not be able to disturb the bus on its way to being
denied.

### 7.3 Gate order

```
slot < 256              → BAD_SLOT
kind == 0x153           → WRONG_KIND
rights & INVOKE         → NO_INVOKE
rights & READ  (if req) → NO_READ_RIGHT
rights & WRITE (if req) → NO_WRITE_RIGHT
slave row live          → BUS_LOST
parent bus row live     → BUS_LOST
controller attached     → NO_CONTROLLER
controller not wedged   → BUS_WEDGED
controller READY        → NOT_READY
```

Kind before rights: a slot whose slave capability was revoked and reused
for an unrelated kind would otherwise have *that* kind's rights word
tested for `READ` and could pass.

Wedged before READY, and before any register access, so a held bus costs
one table read per caller rather than a full timeout budget.

---

## 8. Every wait is bounded

I²C hangs are ordinary: a peripheral stretches SCL past anyone's
patience, a part is absent, a part NACKs mid-message, a driver dies
holding the bus.

Every wait counts iterations against the caller's budget and returns a
**distinct** code:

| code | wait |
|---|---|
| `I2C_XFER_TIMEOUT_TXFIFO` | no room to push a command |
| `I2C_XFER_TIMEOUT_RXFIFO` | a byte never arrived |
| `I2C_XFER_TIMEOUT_STOP` | the STOP never appeared |
| `LPSS_I2C_INIT_DISABLE_TIMEOUT` | the controller would not disable (retarget or bring-up) |
| `LPSS_I2C_INIT_ENABLE_TIMEOUT` | the controller would not enable |

`TIMEOUT_STOP` is the one that means the bus is probably still held,
which is why it is not folded into the others. The two enable codes are
**reused** by the retarget rather than duplicated: it is the identical
operation failing for the identical reason, and a third pair would
fragment the taxonomy without adding a fact.

Same fuel-budget discipline as the interpreter R30.M1 built, for the
same reason: an unbounded loop over an external input is a hang, and a
hang at boot is indistinguishable from a dead machine.

**The budget is an iteration count, not a wall-clock deadline.** Two
load-bearing reasons: it is exactly reproducible, so the witness can
drive a timeout on purpose and assert the code; and it does not depend
on TSC calibration, which at the point in boot where controllers come up
may not have run — a deadline from an uncalibrated TSC is either
instantaneous or infinite.

`I2C_XFER_MAX_LEN = 256` caps each direction. An unbounded length has
unbounded duration however tightly each individual wait is bounded, so
"every wait is bounded" would otherwise be true and useless. Zero length
is refused rather than treated as a no-op, because address-plus-STOP is
the Quick command this driver does not emit.

### 8.1 Abort is checked before every FIFO condition

Every wait loop tests for an abort **first**. An aborted core flushes and
*holds* its TX FIFO, so `TFNF` never rises again; a loop that only
watched `TFNF` would spend its whole budget waiting for space the abort
had already made unavailable — turning a NACK, which should be an
immediate clean error, into a timeout that says only "something took too
long". Same for the read path: a device that NACKs its address will
never deliver a byte.

---

## 9. NACK is an outcome, not a fault

No device at an address is a normal thing to discover.

DesignWare makes it easy to get wrong. On an abort the core raises
`IC_RAW_INTR_STAT.TX_ABRT`, latches a reason in `IC_TX_ABRT_SOURCE`, and
**flushes and holds the TX FIFO** — and stays that way until
`IC_CLR_TX_ABRT` is **read**. A path that returns the error without that
read leaves the next transfer, *by any driver*, facing a latched abort
it did not cause. The controller looks broken and the customary fix is a
reset that takes every other device on the bus down with it.

`dw_xfer_check_abort` therefore reads `IC_CLR_TX_ABRT` on **every**
abort path, before any decoding, so no decode branch can skip it.

Decoding — three different facts about the world, three codes:

| source bits | code | meaning |
|---|---|---|
| `[2:0]` (7-bit / 10-bit addr NACK) | `I2C_XFER_NACK_ADDR` | nothing is there |
| `[3]` (`ABRT_TXDATA_NOACK`) | `I2C_XFER_NACK_DATA` | something is there and rejected a byte |
| `[12]` (`ARB_LOST`) | `I2C_XFER_ARB_LOST` | another master won |
| anything else | `LPSS_I2C_ABORT_OTHER` | raw word in `abort_source` |

Witness sub-test M asserts both halves of "clean": the error surfaces
with the right code, `IC_CLR_TX_ABRT` appears in the access trace, the
abort bit and source word are clear afterwards, **and the very next
transfer on the same controller succeeds** — four aborts in a row, then
a working write.

---

## 10. A wedged bus

A peripheral that was mid-byte when its driver died can hold SDA low
forever. The bus is then unusable by everyone on it, and no amount of
controller configuration fixes it.

### 10.1 Tier 1 — implemented

`i2c_bus_recover(ctrl_idx)`:

1. set `IC_ENABLE.ABORT` — the core drives a STOP and terminates
   whatever it was doing;
2. wait (bounded) for the resulting `TX_ABRT`;
3. clear it through `dw_xfer_check_abort`, which also reads
   `IC_CLR_TX_ABRT` and releases the flush-held FIFO;
4. cycle the controller disabled → enabled, each with its own bounded
   wait.

This recovers every case where the **master** is the stuck party: our
own aborted transfer, a controller left mid-transaction by a driver that
died, a transfer abandoned by a timeout above.

The expected `TX_ABRT` here carries `ABRT_USER_ABRT` — our own abort
coming back — so `check_abort`'s decode lands on `ABORT_OTHER`, which is
the right answer. Success is judged by the enable cycle, not by that
code.

### 10.2 Tier 2 — deferred, and the reason is a missing authority

Freeing a peripheral that latched SDA low requires pulsing SCL up to
nine times with the controller detached from the pins, so the device
finishes the byte it thinks it is in and releases the line.

That is a **pin** operation. It needs mux control of the SCL pad, which
is `KIND_GPIO_LINE` — R30.M6, the next milestone. This driver holds no
pin authority, and manufacturing one here would mean a second unguarded
path to hardware of exactly the kind the window capability exists to
prevent.

### 10.3 The wedged state is handled, not unhandled

Four specific things:

* **Detected behaviourally** — three *consecutive* failed tier-1
  recoveries, not one. A single failed abort can be a transient
  arbitration loss against a peer master, and taking a recoverable
  machine down on the first one is not the conservative choice.
* **Latched** in the controller row's health word, so it survives.
* **Fails fast** — every entry point checks the latch first and returns
  `I2C_XFER_BUS_WEDGED` without touching a register, so one stuck
  peripheral does not convert into N drivers each burning a full
  timeout budget.
* **Has a named exit** — `lpss_i2c_unwedge`, whose intended caller is
  R30.M6's pin-level recovery. It refuses `LPSS_I2C_NOT_WEDGED` on a
  controller that was never latched, so it cannot be used as a general
  counter reset to make the three-strike budget unreachable.

A successful recovery clears the failure counter but deliberately does
**not** clear the latch: letting a lucky recovery silently un-wedge a
bus would hide one that is failing intermittently behind one that
recovered once.

Witness sub-test O walks the whole path: tier-1 success, one failure,
two failures, the third latching, a fast-failing transfer with an empty
access trace, `unwedge`, the second `unwedge` refused, and a working
transfer afterwards.

---

## 11. Error codes

`I2C_XFER_*` occupies `0xFFFFFF60..0xFFFFFF6F` — sixteen codes, the
exact width of the band. Disjoint from `DW_IO_*` `0xFFFFFF30..3F`,
`LPSS_I2C_*` `0xFFFFFF40..5F`, `I2C_SLAVE_*` `0xFFFFFF70..7F`,
`I2C_BUS_*` `0xFFFFFF83..8F`, and every other kind's band.

| code | name |
|---|---|
| `0xFFFFFF6F` | `I2C_XFER_BAD_SLOT` |
| `0xFFFFFF6E` | `I2C_XFER_WRONG_KIND` |
| `0xFFFFFF6D` | `I2C_XFER_NO_INVOKE` |
| `0xFFFFFF6C` | `I2C_XFER_NO_READ_RIGHT` |
| `0xFFFFFF6B` | `I2C_XFER_NO_WRITE_RIGHT` |
| `0xFFFFFF6A` | `I2C_XFER_BUS_LOST` |
| `0xFFFFFF69` | `I2C_XFER_NO_CONTROLLER` |
| `0xFFFFFF68` | `I2C_XFER_NOT_READY` |
| `0xFFFFFF67` | `I2C_XFER_BAD_LEN` |
| `0xFFFFFF66` | `I2C_XFER_TIMEOUT_TXFIFO` |
| `0xFFFFFF65` | `I2C_XFER_TIMEOUT_RXFIFO` |
| `0xFFFFFF64` | `I2C_XFER_TIMEOUT_STOP` |
| `0xFFFFFF63` | `I2C_XFER_NACK_ADDR` |
| `0xFFFFFF62` | `I2C_XFER_NACK_DATA` |
| `0xFFFFFF61` | `I2C_XFER_ARB_LOST` |
| `0xFFFFFF60` | `I2C_XFER_BUS_WEDGED` |

`I2C_XFER_ERR_FLOOR = 0xFFFFFF30`: every code this driver family can
return is at or above it, and no valid length, byte or row id is — so
one compare distinguishes an outcome from a refusal.

---

## 12. Wire-round-trip invariants

1. `rd_len_actual ≤ rd_len`, and equals it on `rc == 0`.
2. `abort_source != 0` **only** when `rc` is one of `NACK_ADDR`,
   `NACK_DATA`, `ARB_LOST`, `ABORT_OTHER`.
3. A request with a non-zero `flags` or `_reserved` is rejected by the
   decoder. This is what keeps §3's "no address field, in any revision"
   enforceable.
4. `budget == 0` means the channel default (`4096`), never "unbounded".
5. `op == SMBUS` is the only opcode for which `smbus_proto` and
   `smbus_command` may be non-zero.
6. Every reply's `slave_cap` equals its request's. The engine never
   substitutes a capability, and there is no operation that would let it.

---

## 13. What is deferred, and why

* **Wire encoders / decoders.** The constants and the kernel-side engine
  land here; the byte-level pack/unpack lands with the userspace
  `lpss_i2c_bus_driver` process (softarch §3 R30), for the reason
  `driver-lifecycle-schema.md` §7 gives — a wire encoder with no peer to
  decode it is untested surface. The engine's own contract is exercised
  directly by the boot witness, which is the half that carries the
  correctness argument.
* **SMBus block transfers** and **Quick** — §6.1.
* **PEC (packet error checking).** SMBus's CRC-8 trailer. It needs a
  per-protocol length that includes the trailer, i.e. the same two-phase
  form block transfers need.
* **Tier-2 bus recovery** — §10.2, waiting on `KIND_GPIO_LINE` (R30.M6).
* **Firmware-supplied SCL timing** — see
  `design/drivers/lpss-i2c-controller.md` §4.2 path (a).
* **Concurrent multi-controller operation** — see that document §8.

---

## 14. Cross-references

* `src/kernel/core/drivers/i2c/xfer_schema.pdx` — constants
* `src/kernel/core/drivers/i2c/dw_xfer.pdx` — engine
* `src/kernel/core/cap/kind_i2c_slave.pdx` — the bound capability
* `design/drivers/lpss-i2c-controller.md` — controller side (#1072)
* `design/ipc/driver-lifecycle-schema.md` — the schema-document shape
* `design/architecture/next-wave-derived-kinds.md` §`KIND_I2C_SLAVE`
