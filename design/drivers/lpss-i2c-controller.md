# PaideiaOS — LPSS I²C Controller: probe, BAR capability, bring-up

**Round.** R30 — ACPICA userspace bubble + LPSS bus enablement
**Sub-milestone.** R30.M5
**Issues.** R30.M5-003 (#1072) — controller PCI probe + BAR mapping.
**Status.** Landed. Boot witness `R30 LPSS I2C OK`.

Companion document: `design/drivers/i2c-transfer-schema.md` (#1073),
which specifies the `i2c_transfer_channel` RPC built on top of this.

---

## 1. What this milestone is responsible for

Between the capability pair `KIND_I2C_BUS` / `KIND_I2C_SLAVE` (#1070,
#1071) and any actual traffic on the wire there is a controller. This
milestone finds it, gets its registers behind a capability, confirms it
is the part we think it is, and brings it to a state in which a transfer
can happen.

Four claims, each of which is a different way to fail silently:

| Claim | The silent failure it prevents |
|---|---|
| Identify by the IP's own signature, not a device-ID table | A present, healthy, **unprobed** controller on a machine nobody had when the table was written. Nothing errors; the touchpad is simply dead. |
| The BAR is reached through a capability, per access | A cached physical address that outlives a revoke, and a second unguarded path to device registers alongside the one R30.M3 closed. |
| The divider is derived from a *stated* input clock or refused | Out-of-spec bus timing that works on a warm bench and fails on a cold boot. |
| Disable before configuring; poll the status, not the request | DesignWare **accepts and discards** configuration writes made while enabled. The controller then runs at a rate nobody chose. |

---

## 2. Identification: no device-ID table

### 2.1 Why not a table

A device-ID table is a claim about which silicon exists, and it is wrong
the moment a machine ships that its author had not seen. The T14 G4's
LPSS device IDs do not match a different Raptor Lake SKU, let alone a
Meteor Lake one.

The failure shape is the worst available: the controller is present and
healthy and simply not probed. Nothing errors, because nothing happened.

### 2.2 The two stages

**Stage 1 — candidate filter, by PCI class.** Cheap, no MMIO, admits a
superset:

```
class 0x0C  subclass 0x80    Serial bus controller, other
class 0x11  subclass 0x80    Signal processing controller, other
```

Both appear in the wild for LPSS blocks depending on how firmware
configured the PCH, so both are candidates. Deliberately loose: a false
candidate costs one register read, a missed one costs a dead device.

**Stage 2 — confirmation, by the IP's own identity register.** Every
Synopsys `DW_apb_i2c` instance ever synthesised reads back

```
IC_COMP_TYPE (BAR0 + 0xFC) == 0x44570140
```

regardless of vendor, wrapper, synthesis parameters or SoC generation.
That constant is the authoritative answer to "is this a DesignWare I²C
core", and it comes **from the part** rather than from a list someone
maintained. It is right on silicon nobody in this repository has seen.

Stage 2 is `dw_i2c_identify`; it needs the window capability and the
reset release first, so this file's probe stops at a candidate.

### 2.3 The one vendor-specific fact, and how it is gated

Intel's wrapper puts a reset/clock block at BAR0 + 0x200. The function
reset must be released (`0x7` → BAR0 + 0x204) before **any** DesignWare
register reads anything but zero — including `IC_COMP_TYPE`.

So the ordering inside `dw_i2c_identify` is load-bearing: release, then
read. Reversed, it rejects **every Intel controller on the machine**,
which presents as "this laptop has no I²C". The witness asserts the
order by trace position, not by outcome.

The reset write is gated on `vendor == 0x8086`, recorded in the
controller row at probe as `intel_wrapper` rather than assumed. A
non-Intel DesignWare instance on PCI skips it and goes straight to
stage 2.

### 2.4 A rejection is loud

A candidate that fails stage 2 goes to `LPSS_I2C_STATE_REJECTED` via
`lpss_i2c_reject`, which emits at **LEVEL_ERROR** with the BDF. A
class-matched device that is not the expected core is the single most
informative event this driver can produce on an unfamiliar machine: it
says "something is at this address and it is not what we expected",
which turns an unexplained dead touchpad into a one-line bug report. A
silent rejection is indistinguishable from never having probed.

---

## 3. The BAR is reached through a capability

### 3.1 The path

```
pci_enumerate_all           →  _pci_devices  (class/subclass/vendor/BDF)
lpss_i2c_probe              →  candidate rows + measured BAR0 {base, len}
lpss_i2c_bind_window        →  opregion_cap_mint_root(...) → cap slot
dw_io_bind(slot)            →  the seam records the SLOT
dw_io_read32 / dw_io_write32 →  re-resolve the slot on EVERY access
```

`opregion_cap_mint_root` is called with space `OPREG_SPACE_PCI_BAR`
(0x06), which `opregion_space_base_kind` classifies as memory-like, so
the mint **demands a `KIND_MEMORY` parent carrying `RIGHT_MINT`**. An
I/O-port holder cannot manufacture register reach.

### 3.2 Base and length are inherited, never argued

`lpss_i2c_bind_window(idx, mem_parent_slot, win_slot, rights)` takes no
base and no length. Both come from the row the probe measured.

If the caller supplied the base, a holder of memory authority could mint
itself a window over any physical address and call it an I²C
controller — which is the class of bug `KIND_OP_REGION` exists to
remove, reintroduced by its own client. This is #1070's
controller-identity discipline and R30.M4-003's GSI discipline applied
to a physical extent.

### 3.3 What re-resolving per access buys

The seam stores the **slot**, not the address. Four consequences:

* **Revoke works immediately.** The row goes dead, `opregion_row_base`
  returns `OPREG_DECODE_BAD`, every subsequent access is refused
  `DW_IO_DEAD_ROW`. There is no cached base to go stale into a
  still-working pointer.
* **A read-only window refuses writes.** Rights are re-read per access,
  so a later narrowing takes effect without anything having to notice.
  Witness sub-test E mints controller 1's window without `RIGHT_WRITE`
  and asserts `DW_IO_NO_WRITE` with nothing stored.
* **Offsets outside the window are refused, not clamped.** Clamping
  would convert a driver bug into a write to whichever register sat at
  the clamped offset.
* **There is no second path.** `tools/build.sh` asserts by `objdump -r`
  that no object under `core/drivers/i2c/` other than `dw_io.o`
  relocates against `opregion_row_base` / `opregion_row_len` — the only
  two functions in the kernel that can turn a capability into a physical
  address, since `_op_region_table` is itself confined to
  `kind_op_region.o`.

### 3.4 Sizing a BAR correctly

`pci_bar_size` writes all-ones into the BAR and reads back which bits
stuck. Its contract is that the caller disables the memory decoder
first, and nothing in the tree had done so. `lpss_i2c_bar0` clears
COMMAND bit 1 across the sizing and **restores the original word before
any refusal path**, so a rejected BAR cannot leave the decoder off and
take the device away from firmware as well as from us.

Refusals: absent BAR, an I/O BAR, or a decoded length below
`DW_REG_WINDOW_BYTES` (4 KiB). The length check is a refusal and not a
clamp: a window shorter than the register bank means the BAR was misread
or the part is not what we think, and a capability covering half a
controller is worse than none.

---

## 4. The divider, and where the input clock comes from

### 4.1 The problem

DesignWare does not take a bit rate. It takes SCL high and low counts in
periods of the core's input clock `ic_clk`. So programming a rate needs
two answers, and the second is the dangerous one:

1. What high/low times does the specification require? — a table.
2. **What is `ic_clk`?** — not discoverable from any register.

There is no register in the DesignWare core, in the Intel wrapper, or in
PCI configuration space that reports `ic_clk`. It is a property of the
SoC's clock tree, fixed at silicon design time. The three values Intel
has shipped are **100 MHz** (Sunrise Point through Raptor Lake — i.e.
the T14 G4), **120 MHz** (Broxton/Apollo Lake) and **133 MHz** (some
Atom parts).

### 4.2 Provenance ladder

| | Source | Status |
|---|---|---|
| (a) | **Firmware-supplied counts.** The platform carries per-controller methods (conventionally `SSCN`/`FMCN`/`FPCN`/`HSCN`) returning the HCNT/LCNT pair the board designer validated, with that board's pull-ups and trace capacitance already folded in. Strictly better than anything computable here, because rise/fall times are properties of the *board*. | **Deferred.** Needs the interpreter session R30.M1–M3 built plus a supervisor→kernel hop that does not exist. `dw_i2c_bringup` takes the clock as an argument precisely so this path, when it lands, is a different **caller** and not a different bring-up. |
| (b) | **Computed from a known `ic_clk`.** Implemented. The clock is an **explicit argument**, drawn from a closed domain of the three shipped values and validated by `dw_i2c_clk_valid`. | **Landed.** |
| (c) | **Unknown.** | **Refused.** `LPSS_I2C_INIT_CLK_UNKNOWN`, controller left disabled. It does not guess and does not fall back to (b) with an assumed value. |

Nothing in the code defaults to 100 MHz. (c) is a refusal because the
failure mode of a wrong divider is not an error — it is a bus that
clocks at the wrong rate, which works against a fast device on a short
trace at room temperature and fails against a slow device on a long
trace on a cold boot. That reproduces on the customer's desk and not on
ours. A controller that refuses to come up reproduces immediately.

### 4.3 The formula

```
hcnt = (ic_clk_khz * (t_high_ns + t_fall_ns) + 500000) / 1000000 - 3
lcnt = (ic_clk_khz * (t_low_ns  + t_fall_ns) + 500000) / 1000000 - 1
```

* `+500000` is round-to-nearest. At 100 MHz one count is 10 ns, and
  truncating costs up to a full count — 4 % of the Fast-mode-plus high
  time.
* `-3` and `-1` are the core's internal pipeline: DesignWare adds three
  `ic_clk` periods to the programmed high count and one to the low count
  before driving the pin.
* `t_fall_ns` is the board's fall-time allowance, **zero here and named
  rather than silently omitted**. Zero is the optimistic direction; a
  board with heavy capacitance needs path (a).

Specification symbol times (I²C-bus specification Rev. 7, Table 10):

| rate | t_high | t_low |
|---|---|---|
| 100 kHz | 4000 ns | 4700 ns |
| 400 kHz | 600 ns | 1300 ns |
| 1 MHz | 260 ns | 500 ns |
| 3.4 MHz | 60 ns | 120 ns |

Worked at `ic_clk` = 100 MHz, `t_fall` = 0 — **the exact values the
witness asserts**:

| rate | hcnt | lcnt |
|---|---|---|
| 100 kHz | 397 | 469 |
| 400 kHz | 57 | 129 |
| 1 MHz | 23 | 49 |
| 3.4 MHz | **3** | 11 |

### 4.4 The last row, and why High-speed is refused

DesignWare requires `hcnt ≥ 6`. High-speed's computed hcnt at 100 MHz is
**3**. A core programmed with 3 does not generate a 3.4 MHz clock; it
generates something else and reports nothing.

`dw_i2c_counts_valid` (hcnt ∈ [6, 65535], lcnt ∈ [8, 65535]) is the
guard, and it **refuses rather than clamps** — a clamped count is a
controller reporting success at a rate nobody asked for.

High-speed is additionally refused at bring-up for an independent
reason: it requires a master-code preamble and arbitration sequence this
milestone does not implement. Both refusals have distinct codes
(`LPSS_I2C_INIT_SPEED_UNSUPPORTED`, `LPSS_I2C_INIT_DIVIDER_RANGE`).

**Reachability note, stated rather than hidden:** with the two closed
domains as they stand — three clocks × three admitted rates — every
computed count is in range, so `INIT_DIVIDER_RANGE` is currently
unreachable *through bring-up*. It is a belt on the count computation
whose reachability returns the moment a fourth `ic_clk` or a fifth rate
is admitted. The substantive assertion (High-speed's hcnt is below the
minimum) is made directly against `dw_i2c_counts_valid` in witness
sub-test B.

### 4.5 SDA hold

`dw_i2c_sda_hold(ic_clk_khz)` = 300 ns worth of `ic_clk` periods,
floored at 1. At 100 MHz that is **30**.

The floor matters: `IC_SDA_HOLD` of zero releases SDA on the same edge
that drops SCL, and a receiver with any input delay samples the *next*
bit. That is data corruption without an error, on some devices and not
others.

---

## 5. Bring-up ordering

### 5.1 Why it is easy to get silently wrong

DesignWare latches `IC_CON`, the SCL count registers, `IC_SDA_HOLD` and
`IC_TAR` **only while disabled**. Writing them to an enabled controller
does not error — the write is accepted and **discarded**. The controller
then runs with its reset defaults, which for the count registers means a
rate nobody chose.

And "disabled" is not "`IC_ENABLE` was written 0". The core's enable is
asynchronous: `IC_ENABLE_STATUS.IC_EN` lags the request by up to
twenty-five bus cycles. A bring-up that writes `IC_ENABLE = 0` and
immediately writes `IC_CON` is racing the core — and wins on a fast
bench, loses on a cold boot with a slow `ic_clk`.

### 5.2 The sequence

```
 1.  IC_ENABLE      <- 0
 2.  poll IC_ENABLE_STATUS.IC_EN == 0          [bounded]
 3.  IC_INTR_MASK   <- 0            (polled driver, not interrupt-driven)
 4.  read IC_CLR_INTR                (drop anything firmware latched)
 5.  IC_CON         <- master | speed | restart_en | slave_disable
 6.  IC_{SS,FS}_SCL_{HCNT,LCNT} <- the computed divider
 7.  IC_SDA_HOLD    <- 300 ns of ic_clk periods
 8.  IC_TX_TL, IC_RX_TL <- 0
 9.  IC_DMA_CR      <- 0             (PIO; a stale DMA enable leaves the
                                      core waiting on a channel that is
                                      not coming)
10.  IC_ENABLE      <- 1
11.  poll IC_ENABLE_STATUS.IC_EN == 1          [bounded]
```

`IC_CON` always carries `IC_RESTART_EN` and `IC_SLAVE_DISABLE`. Neither
is a tuning knob:

* without `RESTART_EN` the core cannot emit a repeated START, and the
  combined write-then-read of #1073 — how essentially every register
  read on this machine works — degrades into STOP + START;
* a controller that also answers as a slave can be addressed by a peer
  master, which on a bus whose isolation story is per-device
  capabilities would be an authority nobody minted.

Fast-mode-plus uses the **FAST** speed encoding and the FS count
registers; the core has no separate Fast-plus field, only faster counts.

### 5.3 Only one bank is programmed

The bank the selected rate does not use keeps its reset values. The rate
is a property of the **bus capability**, validated at mint against the
four spec rates, so changing rate means holding a different capability
and re-running bring-up — not poking one register. A driver that could
switch banks at runtime could change the bus's rate without anyone
re-checking it against the slowest part on the wire.

### 5.4 `IC_TAR` is absent from bring-up

The target address belongs to a slave capability and is written per
transfer. See `design/drivers/i2c-transfer-schema.md` §4.

### 5.5 How the ordering is asserted

Final state cannot distinguish "disabled, configured, enabled" from
"configured while enabled, then toggled": both leave identical
registers, and the second silently discards the configuration on real
silicon. Only **positions** separate them.

Every access goes through `dw_io_read32` / `dw_io_write32`, which append
a `{op, offset, value}` record to an ordered trace. Witness sub-test F
asserts:

```
idx(write IC_ENABLE=0)  <  idx(read IC_ENABLE_STATUS)
                        <  idx(write IC_CON)
                        <  idx(write IC_FS_SCL_HCNT)
                        <  idx(write IC_ENABLE=1)
                        <  idx(read IC_ENABLE_STATUS)
```

plus the values of both `IC_ENABLE` writes, and that the SS bank is
untouched.

The trace **saturates rather than wraps** at 256 records, for
`gpe_io.pdx`'s reason: a wrapped ordering trace can present a
configuration write as preceding a disable it in fact followed, silently
inverting the strongest assertion in the milestone. Saturation instead
shows up as a count mismatch, which is a failure.

---

## 6. The register/logic seam

`src/kernel/core/drivers/i2c/dw_io.pdx` is the only object that touches
controller registers.

| mode | behaviour |
|---|---|
| `DW_IO_MODE_MMIO` (0, default from `.bss`) | `mfence` / 32-bit access / `mfence` at `base + off`, base resolved from the window capability. |
| `DW_IO_MODE_SYNTH` (1) | The same access against a 4 KiB RAM **device model**. |

**The capability checks run in both modes.** Only the final load/store
differs. If they were skipped under the synthetic window, the rights
assertions in the witness would be assertions about nothing.

### 6.1 The synthetic side is a device model, not a buffer

A plain RAM window would make most of the transfer engine untestable,
because the interesting DesignWare registers are not storage:

| register | modelled behaviour | why it must be modelled |
|---|---|---|
| `IC_CLR_TX_ABRT` (0x54) | read clears `RAW_INTR_STAT.TX_ABRT` and zeroes `IC_TX_ABRT_SOURCE` | This read is what releases the flush-held TX FIFO. Against a RAM cell, "a NACK must not wedge the controller" is unobservable. |
| `IC_CLR_STOP_DET`, `IC_CLR_INTR` | read-to-clear | A leftover `STOP_DET` makes the next transfer's wait return on the *previous* transfer's stop. |
| `IC_DATA_CMD` (0x10) | reads pop a seeded queue; `IC_STATUS.RFNE` falls when it empties | Otherwise every byte of a multi-byte read returns the same value and the length handling is tested by nothing. |
| `IC_ENABLE` (0x6C) | bit 0 propagates to `IC_ENABLE_STATUS` | The two must be separate cells, because the real enable is asynchronous — which is the whole reason bring-up polls the status. |
| `IC_ENABLE.ABORT` (bit 1) | raises `TX_ABRT` with `ABRT_USER_ABRT` | The only mechanism tier-1 bus recovery has. |
| `IC_DATA_CMD` write with `STOP` | raises `RAW_INTR_STAT.STOP_DET` | Lets the terminating wait complete for the *right* reason — because a STOP was commanded, not because a fixture poked a bit. An **aborted** command does not raise it, matching the core, which is what makes a driver that returns from a NACK without clearing the abort visibly wrong rather than accidentally fine. |

Two fixture-only knobs model the failures the driver must survive:

* `dw_io_synth_set_stuck(1)` — suppresses `IC_ENABLE` →
  `IC_ENABLE_STATUS` propagation. A controller that cannot change enable
  state is what a held bus looks like, and it is the only way to reach
  the bounded-wait failure paths. An unbounded spin is
  indistinguishable from a bounded one until the day the bus is held,
  and on that day the difference is a hung boot.
* `dw_io_synth_arm_nack(source)` — the next `IC_DATA_CMD` write aborts,
  one-shot. Arming rather than pre-poking is what makes it reachable at
  all: retargeting reads `IC_CLR_INTR`, which would wipe a pre-poked
  abort before the first byte was pushed.

### 6.2 `paideia-as#1312` does not apply

That issue is "port I/O carries no effect-row or capability coupling".
This module performs **no port I/O**. MMIO is the case R29.M2-002
already closed: `!{Mmio}` requires a matching `paideia.mmio` capability
at elaboration. The seam is still the right shape for the trace, and the
`KIND_OP_REGION` check here is a finer object than the language-level
capability.

---

## 7. Controller table

`_lpss_i2c_ctrl`, 8 rows × 64 B, confined to `lpss_probe.o` by
`objdump -r`.

| off | field |
|---|---|
| `+0` | `[7:0]` in_use · `[15:8]` bus · `[23:16]` dev · `[31:24]` fn · `[47:32]` seg · `[55:48]` intel_wrapper |
| `+8` | `bar0_pa` — measured at probe |
| `+16` | `bar0_len` — the extent granted to the capability |
| `+24` | `window_slot` — cap slot of the `KIND_OP_REGION`, or 0 |
| `+32` | `bus_row` — the `KIND_I2C_BUS` row this controller backs, or `0xFFFF` |
| `+40` | `state` |
| `+48` | `ic_clk_hz` — recorded at bring-up; the one divider input no register reports, so "which clock did we assume" stays answerable |
| `+56` | `[7:0]` wedged (latched) · `[15:8]` consecutive recover_fails |

`bus_row` is a **row id and not a cap slot**, per #1070: a slot can later
hold a different bus, a live row id cannot.

The confinement is why `state`, `clk`, the health word and the bus
attachment all have exported mutators rather than being poked from
`dw_init.o` / `dw_xfer.o` — the same device as
`i2c_bus_note_slave_added`.

### 7.1 States

```
FREE → CANDIDATE → WINDOWED → IDENTIFIED → READY
                        ↘ REJECTED   (IC_COMP_TYPE mismatch, logged)
```

### 7.2 `lpss_i2c_record` is exported, and why that is safe

It is the sole row allocator, called by both `lpss_i2c_probe` and the
boot witness. Exporting it does not weaken the confinement claim: **a
controller row confers no reach.** Nothing in the access path reads
`bar0_pa`; the only thing that turns an extent into the ability to touch
memory is `lpss_i2c_bind_window`, gated on a `KIND_MEMORY` capability
with `RIGHT_MINT` — and a caller who can reach that gate could call
`opregion_cap_mint_root` directly with any base it liked.

What the export buys is that the fixture allocates rows through the
**same** allocator the probe uses, rather than a test-only back door
that could drift from it.

---

## 8. One controller at a time

`dw_io` holds exactly one bound window, so every operation begins with
`dw_i2c_select(idx)` — a capability rebind, no register access.

Stated rather than hidden: this is a single-threaded boot-time posture,
and two CPUs driving two controllers concurrently would race on the
bound slot. When R30.M5 grows a per-controller driver process (softarch
§3 R30: one `lpss_i2c_bus_driver` per controller), the seam's single
binding becomes per-process state and the race disappears without any
caller changing. Making it per-controller state *now* would mean either
eight seams or a seam that takes an index — and a seam that takes an
index takes an address one refactor later.

Selection re-binds unconditionally rather than checking whether the
right window is already bound: "already bound" is cheap to believe and
expensive to be wrong about, and being wrong means writing controller
A's configuration into controller B.

---

## 9. Failure taxonomy

Two new bands, disjoint from each other and from every existing one
(`I2C_SLAVE_*` `0xFFFFFF70..7F`, `I2C_BUS_*` `0xFFFFFF83..8F`,
`ACPI_EVT_*` `0xFFFFFF90..9F`, `DRV_RESTART_*` `0xFFFFFFB5..BE`,
`OPREG_*` `0xFFFFFFC2..CF`, `DMA_*` `0xFFFFFFD5..DF`, `MSIX_*`
`0xFFFFFFE7..EF`, `HW_INT_*` `0xFFFFFFF7..FF`).

### `DW_IO_*` — the seam, `0xFFFFFF30..0xFFFFFF3F`

| code | name |
|---|---|
| `0xFFFFFF3F` | `DW_IO_UNBOUND` |
| `0xFFFFFF3E` | `DW_IO_WRONG_KIND` |
| `0xFFFFFF3D` | `DW_IO_DEAD_ROW` |
| `0xFFFFFF3C` | `DW_IO_NO_READ` |
| `0xFFFFFF3B` | `DW_IO_NO_WRITE` |
| `0xFFFFFF3A` | `DW_IO_RANGE` |
| `0xFFFFFF39` | `DW_IO_BAD_ARG` |

A failed **read** returns `DW_IO_FAULT = 0xFFFF…FF`, which cannot
collide with a value: every DesignWare register is 32 bits.

A refusal is **not traced**. The trace records accesses that reached the
device; tracing refusals would let a driver being denied every register
look, in the trace, exactly like one that is working.

### `LPSS_I2C_*` — probe, bring-up, recovery, `0xFFFFFF40..0xFFFFFF5F`

| code | name |
|---|---|
| `0xFFFFFF5F` | `LPSS_I2C_PROBE_ENOSPC` |
| `0xFFFFFF5E` | `LPSS_I2C_PROBE_BAD_IDX` |
| `0xFFFFFF5D` | `LPSS_I2C_PROBE_NO_BAR` |
| `0xFFFFFF5C` | `LPSS_I2C_PROBE_NOT_DESIGNWARE` |
| `0xFFFFFF5B` | `LPSS_I2C_WIN_BAD_PARENT` |
| `0xFFFFFF5A` | `LPSS_I2C_WIN_ALREADY` |
| `0xFFFFFF59` | `LPSS_I2C_WIN_UNBOUND` |
| `0xFFFFFF58` | `LPSS_I2C_INIT_CLK_UNKNOWN` |
| `0xFFFFFF57` | `LPSS_I2C_INIT_SPEED_UNSUPPORTED` |
| `0xFFFFFF56` | `LPSS_I2C_INIT_DIVIDER_RANGE` |
| `0xFFFFFF55` | `LPSS_I2C_INIT_DISABLE_TIMEOUT` |
| `0xFFFFFF54` | `LPSS_I2C_INIT_ENABLE_TIMEOUT` |
| `0xFFFFFF53` | `LPSS_I2C_INIT_NOT_IDENTIFIED` |
| `0xFFFFFF52` | `LPSS_I2C_BUS_ATTACH_BAD_ROW` |
| `0xFFFFFF51` | `LPSS_I2C_BUS_ATTACH_ALREADY` |
| `0xFFFFFF50` | `LPSS_I2C_IO_FAULT` |
| `0xFFFFFF4F` | `LPSS_I2C_RECOVER_TIMEOUT` |
| `0xFFFFFF4E` | `LPSS_I2C_RECOVER_FAILED` |
| `0xFFFFFF4D` | `LPSS_I2C_NOT_WEDGED` |
| `0xFFFFFF4C` | `LPSS_I2C_SMBUS_UNSUPPORTED` |
| `0xFFFFFF4B` | `LPSS_I2C_ABORT_OTHER` |
| `0xFFFFFF4A` | `LPSS_I2C_STATE_BAD` |
| `0xFFFFFF49` | `LPSS_I2C_IDENTIFY_ALREADY` |

The two enable timeouts are separate on purpose: "it would not turn off"
and "it would not turn on" have different causes (a held bus versus a
dead clock), and a shared code would say only that something took too
long. They are **reused** by the per-transfer retarget rather than
duplicated, because that is the identical operation failing for the
identical reason.

---

## 10. Guardrails

Added to `tools/build.sh`, running on every build including inside the
smoke matrix:

**`[i2c-mmio-confine]`** — `objdump -r` asserts

* no object under `core/drivers/i2c/` other than `dw_io.o` relocates
  against `opregion_row_base` / `opregion_row_len`;
* `_dw_io_mode`, `_dw_io_win_slot`, `_dw_io_synth_ram`, `_dw_io_trace`
  are relocated against from `dw_io.o` alone;
* `_lpss_i2c_ctrl` from `lpss_probe.o` alone;
* `_i2c_xfer_abort_src` from `dw_xfer.o` alone;

each with an anti-vacuity check that the owner *does* reference the
symbol, so a rename or a gutted module fails rather than passing
silently.

**`[i2c-addr-confine]`** — extended; see
`design/drivers/i2c-transfer-schema.md` §3.

Both were mutation-tested at landing: injecting a call to
`opregion_row_base` into `dw_init.pdx` fails the build with the stray
named, and widening any pinned signature fails with the expected
declaration printed.

---

## 11. Boot witness

`tests/kernel/drivers/i2c/lpss_i2c_synth.pdx §lpss_i2c_witness`,
sub-tests A..R (eighteen stages) — fingerprint **`R30 LPSS I2C OK`**.
Cap slots 46..55, disjoint from every other witness's set; both exits
unbind the seam, return it to real MMIO, reset all three tables and
clear the slots.

Placement in `kernel_main.pdx` is **after** `i2c_cap_witness_call`, not
free: both fixtures reset `_i2c_bus_table` and `_i2c_slave_table`, so
the other order would have the capability-pair witness wipe the rows
this one transacts against.

The **real** probe (`lpss_i2c_probe`) is called immediately after the
witness, for the same class of reason: the fixture resets
`_lpss_i2c_ctrl` on entry and exit, so probing first would have the
fixture's teardown erase the machine's real controller rows. Under QEMU
it is dormant (MCFG absent → zero devices → `LPSS I2C PROBE n=0`); on
the T14 G4 it is the first thing that sees the LPSS blocks.

---

## 12. Cross-references

* `src/kernel/core/drivers/i2c/dw_regs.pdx` — register map, divider math
* `src/kernel/core/drivers/i2c/dw_io.pdx` — seam, trace, device model
* `src/kernel/core/drivers/i2c/lpss_probe.pdx` — probe, rows, window mint
* `src/kernel/core/drivers/i2c/dw_init.pdx` — identify, bring-up
* `design/drivers/i2c-transfer-schema.md` — the transfer channel (#1073)
* `design/architecture/next-wave-derived-kinds.md` §`KIND_I2C_BUS`
* `src/kernel/core/cap/kind_op_region.pdx` — the window capability
* `src/kernel/core/acpi/gpe_io.pdx` — the seam pattern this follows
