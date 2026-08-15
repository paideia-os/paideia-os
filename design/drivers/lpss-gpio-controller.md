# LPSS / PCH pad controller — probe, communities, and the pin map

**Round.** R30 — ACPICA userspace bubble + LPSS bus enablement
**Sub-milestone.** `R30.M6`
**Issues.** #1075 (`KIND_GPIO_LINE`), #1076 (probe + banks)

Sources of truth:

| | |
|---|---|
| `src/kernel/core/drivers/gpio/lpss_gpio.pdx` | probe, controller table, community table, the pin map |
| `src/kernel/core/drivers/gpio/gpio_io.pdx` | the register seam and its ordered trace |
| `src/kernel/core/cap/kind_gpio_line.pdx` | `KIND_GPIO_LINE`, and the only capability-bearing route to a pad address |
| `tests/kernel/drivers/gpio/lpss_gpio_synth.pdx` | boot witness — `R30 LPSS GPIO OK` |
| `tests/kernel/cap/gpio_cap_synth.pdx` | boot witness — `R30 KIND_GPIO OK` |
| `tools/build.sh` | `[gpio-confine]`, `[gpio-pin-confine]` |

---

## 1. Why this driver is held to a higher standard than the I²C one

R30.M5 spent five issues establishing that an I²C capability naming
address A cannot reach address B. The same argument applies here, and
the consequence of getting it wrong is categorically different.

On I²C, addressing the wrong device produces a **data error**. The wrong
peripheral answers, or none does, and a driver reads nonsense. Something
downstream notices.

On a pad controller, acting on the wrong pin produces a **physical state
change with no error path at all**. The pins a real pad controller owns
include device reset asserts, power-rail enables, write-protect straps
and firmware-flash control. There is no NACK, no arbitration loss, no
status bit that reports "that was the wrong pin". The pin becomes
whatever the last writer made it, and the first symptom appears
somewhere else entirely — a device that never came back from reset, a
rail that is off, a strap that no longer protects anything.

Two design consequences follow, and they shape everything below:

* **nothing is ever clamped.** Every out-of-range or unmapped input is
  refused. Clamping picks *some* pin, and on this part some pin is a
  reset line.
* **every number that participates in selecting a pad is confined**, not
  just the pin number. See §5.

---

## 2. Pin numbering is not pad indexing

Intel pad controllers organise pads into **communities**. Each community
has its own register window inside the controller's BAR, and its own
PADCFG region inside that window.

```
community  = the c with c.pin_base <= pin < c.pin_base + c.npins
pad_index  = pin - c.pin_base
reg offset = c.reg_off + c.padbar + pad_index * stride
```

The pin number the platform hands you is **absolute across the
controller**. The index that addresses a pad's registers is
**community-relative**.

For the first community `pin_base` is 0 and `pad_index == pin`. **The
mapping is the identity there and nowhere else.**

That single sentence is the trap this milestone exists to close. A
driver that forgets the subtraction:

* works perfectly on every pin of community 0;
* drives the **wrong pin** on every pin of every other community;
* produces no error, anywhere, ever.

A test suite that only exercises community 0 cannot distinguish the
correct implementation from the broken one. Both witnesses therefore
assert the mapping **outside community 0**, against independently
computed register offsets, and the capability witness asserts explicitly
against the two wrong answers the two plausible bugs produce:

| bug | offset for pin 29 in the fixture | why it looks fine |
|---|---|---|
| correct | `0x1000 + 0x700 + 5*16 = 0x1750` | — |
| never subtracts `pin_base` | `0x1000 + 0x700 + 29*16 = 0x18D0` | in-window, well-formed, belongs to a pad that may exist on a bigger part |
| always uses community 0 | `0x0000 + 0x600 + 5*16 = 0x650` | a **real pin already owned by another capability** |

This is also the mutation the witnesses were checked against: deleting
the `sub rax, rbx` in `lpss_gpio_resolve_pin` fails
`R30 LPSS GPIO OK` at stage 9 and `R30 KIND_GPIO OK` at stage 6.

---

## 3. Where the geometry comes from

Three facts define a community. They come from three different places
and the driver is careful about which is which.

### 3.1 Not readable — the platform describes it

The community's **register window offset**, its **pin base** and its
**pad count**. No register reports them. On a real machine they come
from the platform's description of the controller, which for R30 is
consumed by the userspace supervisor.

They are therefore *arguments* to `lpss_gpio_add_community`, and that
function's whole job is to refuse every description that cannot be true.

A per-SoC device-ID-to-geometry table was considered and rejected, for
the reason `lpss_probe.pdx` rejected a device-ID table — and more
sharply. A device-ID table's failure mode is a present, healthy,
unprobed controller and a silent log. A stale *geometry* table's failure
mode is worse: it does not fail to find the controller, it finds one and
gives it **the wrong pin map**.

### 3.2 Readable — ask the part

* **PADBAR** (community + `0x0C`): the PADCFG region's offset inside the
  community window. Read, never assumed. This is the discipline
  `lpss_probe.pdx` applied to `IC_COMP_TYPE`; a hardcoded PADCFG offset
  is a per-SoC table wearing a different hat.
* **REVID** (community + `0x00`): revision field `[23:16]`. At `0x94` and
  above the part carries four PADCFG registers per pad (stride 16);
  below it, two (stride 8). Deriving the stride from the part is what
  keeps the driver correct across a generation boundary without an edit
  — and a stride wrong by a factor of two puts *every* pad access on the
  wrong pad.

### 3.3 Every refusal, and why it is a refusal

| condition | code | why not repaired |
|---|---|---|
| controller not `IDENTIFIED` | `LPSS_GPIO_COMM_NOT_IDENTIFIED` | stride is 0; every pad in the community would map to the same register |
| `npins == 0`, `npins > 128`, or `pin_base + npins > 512` | `LPSS_GPIO_COMM_BAD_GEOM` | a community leaving the representable pin space produces capabilities whose recorded pin is not the pin asked for |
| pin range overlaps another community **of this controller** | `LPSS_GPIO_COMM_OVERLAP` | one absolute pin would have two register addresses; picking either silently is how a driver drives a pin it did not mean to |
| REVID reads 0 or all-ones | `LPSS_GPIO_ID_NO_PART` | a described community window with nothing behind it |
| PADBAR zero, misaligned, or outside the BAR | `LPSS_GPIO_ID_BAD_PADBAR` | a PADCFG region starting outside the window is not a community |
| `reg_off + padbar + npins*stride > bar_len` | `LPSS_GPIO_COMM_WINDOW` | a clipped community has pads whose registers fall outside the capability; every access would be refused with a range error naming the wrong problem |
| no free community row | `LPSS_GPIO_COMM_ENOSPC` | — |

**Overlap is checked per controller, not globally.** A machine with two
pad controllers numbers each one's pins from zero. A global check would
refuse the second controller's community 0 and make an ordinary board
unbootable — not a conservative failure.

**Ascending order is deliberately NOT required.** A description that
lists communities out of pin order is unusual but not wrong, and the
overlap check already makes first-match unambiguous. Refusing it would
be the same unnecessary failure #1071 declined to make when it scoped
the I²C address key to the bus.

---

## 4. Identification: the LPSS class code does not say which block this is

The candidate filter is the **same two class/subclass pairs**
`lpss_probe.pdx` uses — `(0x0C, 0x80)` and `(0x11, 0x80)` — and that is
deliberate. LPSS blocks present that way whether they are an I²C
controller, a UART or a pad controller. The class code cannot
distinguish them, so pretending otherwise would mean inventing a
discriminator that does not exist.

Stage 2 asks the part:

1. **`BAR0 + 0xFC == 0x44570140`** → this is a **DesignWare I²C core**,
   not a pad controller. Refused with its own code
   (`LPSS_GPIO_ID_IS_I2C`). This negative check is the only thing
   keeping the pad-controller driver off the I²C controller's
   registers, and "we found the I²C block while looking for the pad
   controller" is a far more useful sentence than "not recognised".
2. **REVID** must be neither 0 nor all-ones.
3. **PADBAR** must be non-zero, 4-byte aligned, and inside the BAR.

A read that the *seam* refuses is `LPSS_GPIO_IO_FAULT`, never collapsed
into `NO_PART`: "we were not allowed to read" and "we read and it was
empty" are different problems.

---

## 5. The register path

### 5.1 The BAR is reached through a capability

`lpss_gpio_bind_window` mints a `KIND_OP_REGION` root over the caller's
`KIND_MEMORY` authority, covering **exactly the extent the probe
measured** — inherited from the row, never an argument. If a caller
could supply the base, a holder of memory authority could mint itself a
window over any physical address and call it a pad controller.

Everything downstream reaches registers only through `gpio_io_read32` /
`gpio_io_write32`, which **re-resolve the capability slot on every
access**. Consequences, all asserted by the driver witness:

* revoking the window stops access immediately — no cached base;
* a slot whose window was revoked and then *reused* is caught too: the
  seam's per-access row-liveness check refuses `GPIO_IO_DEAD_ROW` even
  when the descriptor still looks like a window. A bind-time-only check
  would miss exactly this, and the hole would be the width of a revoke;
* a read-only window refuses writes (`GPIO_IO_NO_WRITE`) and stores
  nothing — on this part that is the line between a component that may
  *inspect* pin state and one that may *change* it;
* an offset outside the window is refused (`GPIO_IO_RANGE`), never
  clamped.

### 5.2 The ordered trace

The synthetic side of the seam is a plain cell array, and that is
honest: nothing this milestone touches is a non-storage register.
(GPI_IS, which is write-1-to-clear, arrives with #1078 — the issue that
drives it. Modelling it now would be modelling a register nothing
reads.)

What the trace buys is two claims final state cannot express:

* **ordering** — community 1's REVID was read *before* its PADBAR, i.e.
  the geometry was measured before it was accepted;
* **targeting and read-only-ness** — there is **no WRITE record** at
  `0x00`, `0x0C`, `0x1000` or `0x100C`. REVID, CAPLIST and PADBAR are
  read-only on the part, so a cell array would absorb such a write and
  then answer with it, and the fixture would be describing a controller
  it had itself configured.

Saturating rather than wrapping, and an atomic index reservation, for
the reasons `dw_io.pdx` gives — a wrapped or aliased trace makes an
ordering assertion say the opposite of the truth.

---

## 6. Tables

### `_lpss_gpio_ctrl[idx]` — 64 bytes, `LPSS_GPIO_MAX_CTRL = 4`

| off | field |
|---|---|
| `+0` | `in_use[7:0] | bus[15:8] | dev[23:16] | fn[31:24] | seg[47:32] | intel[55:48] | ncomm[63:56]` |
| `+8` | `bar0_pa` — measured at probe |
| `+16` | `bar0_len` — granted to the capability |
| `+24` | `window_slot` — the `KIND_OP_REGION`, or 0 |
| `+32` | `state` — `LPSS_GPIO_STATE_*` |
| `+40` | `controller_id` — `bdf_pack` key. **The join** to `KIND_GPIO_LINE`, and the cascade key |
| `+48` | `revid` — as read, 0 before identification |
| `+56` | `padcfg_stride` — 16 or 8, derived from `revid`, 0 before |

### `_lpss_gpio_comm[k]` — 32 bytes, `LPSS_GPIO_MAX_COMM = 16`, flat

| off | field |
|---|---|
| `+0` | `in_use[7:0] | ctrl_idx[15:8] | comm_id[23:16]` |
| `+8` | `reg_off` — community window offset within BAR0 |
| `+16` | `padbar` — PADCFG offset within the community window, **read from the part** |
| `+24` | `pin_base[15:0] | npins[31:16]` |

The table is **flat with an owner field** rather than a per-controller
array. A two-dimensional array fixes a per-controller community budget
at compile time, and the real distribution is lopsided — one controller
with five communities and another with one is ordinary. A flat table
spends the budget where the machine needs it.

There is **no allocation cursor**: `lpss_gpio_record` scans for a free
row and `lpss_gpio_ctrl_count` counts live ones. A counter and a table
are two places the same fact lives, and `lpss_gpio_release` frees a row
in the middle, which a bump cursor could not express without either
leaking the slot or disagreeing with the table.

Both tables are confined to `lpss_gpio.o` by `objdump -r` in
`tools/build.sh`.

---

## 7. Teardown

`lpss_gpio_release(idx)`, in this order and the order is not stylistic:

1. `gpio_line_cascade_revoke_by_controller(controller_id)` — **first**,
   while the controller row is still live. A line capability that
   outlived its controller is worse than an I²C slave that outlived its
   bus: a controller row can be reallocated by a later probe, and the
   surviving capability's recorded `controller_id` would then name
   *different silicon*.
2. `opregion_cap_revoke(window_slot)` — the register mapping dies with
   the controller, and any seam still bound to it starts refusing on the
   next access.
3. Zero this controller's community rows. A community row names its
   controller by **index**, so one that outlived its controller would
   attach itself to whatever the next probe put in that slot and apply
   one part's pin map to another.
4. Zero the controller row — free and scrub in one.

---

## 8. Where the pad controller actually lives on a T14 G4

On the T14 G4 the PCH pad controller is **described by platform
firmware** rather than enumerated as a PCI function. The consumer of
that description is R30's userspace supervisor and it is not this file.

The PCI path implemented here is real for the LPSS blocks that *are*
exposed as functions, and it is the enumeration #1076 was scoped to.
Both paths converge on `lpss_gpio_record`, which is why that allocator
is exported: the description-driven path adds a **caller**, not a second
table. Under QEMU an MCFG-absent boot leaves `_pci_device_count` at
zero, so the fingerprint reports `LPSS GPIO PROBE n=0`.

---

## 9. Failure taxonomy

`LPSS_GPIO_*` occupies `0xFFFFFF20..0xFFFFFF2F`; `GPIO_LINE_*`
occupies `0xFFFFFF10..0xFFFFFF1F`; `GPIO_IO_*` occupies
`0xFFFFFF08..0xFFFFFF0F`. Three adjacent, disjoint bands, and the
adjacency matters: all three layers refuse for structurally similar
reasons during a probe, and a shared band would make "which layer
refused" a guess.

The mapping sentinels are outside every band and there are **two** of
them — `GPIO_MAP_NO_CTRL` (`…FFFE`) and `GPIO_MAP_UNMAPPED` (`…FFFF`) —
because a mistyped controller id and a pin the part does not route are
different operator problems.

---

## 10. Change log

| Date | Issue | Change |
|---|---|---|
| 2026-08-15 | #1076 | Initial: probe, BAR-to-capability, two-stage identification with the DesignWare-I²C negative check, derived PADCFG stride, community description with six refusals, the pin map, `lpss_gpio_release`, the `gpio_io` seam with its ordered trace, and the `R30 LPSS GPIO OK` witness. |
