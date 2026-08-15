# R30.M4 — the SCI / GPE interrupt path

Issues: **#1066** (SCI ISR install as `KIND_HW_INTERRUPT`), **#1067** (GPE
dispatch table + registration), **#1068** (SCI event stream as
`KIND_ACPI_EVENT`), **#1069** (notify → subscriber routing). §§1–10 are
the interrupt path as landed by #1066/#1067; §§11–15 are the routing
layer that #1068/#1069 built on top of it and that closes R30.M4.

---

## 1. The constraint the whole milestone is shaped by

A General Purpose Event fires and the platform's answer to "what does
that mean" is an AML control method — `_Lxx` for a level-triggered GPE,
`_Exx` for an edge-triggered one. Evaluating one of those is:

* interpreting bytecode, in an interpreter that lives in a **userspace**
  process (`design/acpi/no-aml-in-kernel.md`),
* potentially **milliseconds** long, and
* potentially **blocking**, because an EC OpRegion access is a
  handshake with a microcontroller that answers when it feels like it.

None of that can happen in an interrupt handler. So the ISR does the
bounded, non-blocking minimum and the meaning is resolved later, in
userspace, by the ACPI supervisor.

The bounded minimum is exactly five things per asserted GPE: read the
status, **mask**, **clear**, account, enqueue. Then one EOI for the whole
interrupt.

---

## 2. Module map

| File | Role |
|---|---|
| `src/kernel/acpi/fadt.pdx` | FADT parse; now yields `GPE0_BLK`, `GPE1_BLK`, both `_LEN`s and `GPE1_BASE` (and has corrected field offsets — §7) |
| `src/kernel/core/acpi/gpe_block.pdx` | Geometry validation + index → (block, byte, bit, port). **Pure**: no I/O anywhere in the module |
| `src/kernel/core/acpi/gpe_io.pdx` | The register-access seam. The only object in the kernel that issues `in`/`out` against a GPE register, and the only one that issues the EOI on this path |
| `src/kernel/core/acpi/gpe_table.pdx` | 256-row registration table, strike accounting, 32-slot ISR→supervisor event ring |
| `src/kernel/core/acpi/sci_isr.pdx` | `sci_isr_body`, and nothing else |
| `src/kernel/core/acpi/gpe_ack.pdx` | `gpe_enable` / `gpe_disable` / `gpe_clear_status` / `gpe_ack` — the supervisor side |
| `src/kernel/core/acpi/sci_route.pdx` | `SCI_INT` → (GSI, polarity, trigger) → IOAPIC RTE |
| `src/kernel/core/apic/ioapic_route.pdx` | Gained `ioapic_base_for_gsi`, extracted from `ioapic_route_irq_via_madt` so the SCI path and the ISA path cannot disagree about IOAPIC ownership |
| `tests/kernel/acpi/gpe_synth.pdx` | Boot witness, sub-tests A..K |
| `src/kernel/core/cap/kind_acpi_event.pdx` | **#1068.** `KIND_ACPI_EVENT` (tag `0x151`), derived over `KIND_HW_INTERRUPT` — §11 |
| `src/kernel/core/acpi/evt_stream.pdx` | **#1069.** The subscriber stream: bounded ring, source discrimination, routing pump, acknowledgement — §§12–13 |
| `src/kernel/core/acpi/sci_arm.pdx` | **#1069.** `sci_arm` / `sci_disarm` — the readiness-gated unmask, §14 |
| `tests/kernel/acpi/evt_route_synth.pdx` | **#1068/#1069** boot witness, sub-tests A..G — §15 |

#1066/#1067 needed no new `KIND_*`: the SCI is a GSI, and
`KIND_HW_INTERRUPT` (R29.M1, tag `0x140`, tail
`{gsi, cpu_affinity_mask, edge_or_level}`) is already exactly the
capability that grants one — `edge_or_level = 1` is the SCI's value.
#1068 adds one, `KIND_ACPI_EVENT`, and §11 is the argument for why it is
a distinct kind rather than a right on the interrupt.

---

## 3. The three orderings

### 3.1 Mask before clear, clear before EOI

The SCI is level-triggered and shareable — ACPI 6.5 §4.1 states it, and
it is not a platform default that firmware may quietly change.

A level-triggered line stays asserted while its source asserts it. EOI
without removing the assertion re-delivers immediately, forever. Clearing
the status bit removes it — but a status bit whose source is still
asserting re-sets the instant it is cleared. The hardware condition for
driving the SCI is `STS & EN`, so **clearing the enable bit first** is
what makes the clear stick.

Order in `sci_isr_body`, per status byte:

```
read STS ; read EN ; asserted = STS & EN
if asserted != 0:
    write EN  <- EN - asserted        (1) MASK
    write STS <- asserted             (2) CLEAR   (write-1-to-clear)
    per-bit accounting and enqueue
... after both blocks ...
EOI                                   (3) once, after every clear
```

The EOI is issued once, outside the block loop, so no acknowledgement can
precede any clear even on a multi-block platform.

### 3.2 Mask before enqueue

The mask write at step (1) precedes the whole per-bit loop, so it
precedes every enqueue. A GPE therefore has at most one outstanding
event, and only `gpe_ack` can produce another.

The evidence is not a comment. At enqueue time the ISR **re-reads** the
enable register through the same seam and stores the byte it gets back
in the event record's `enable_snapshot` field. That is what the register
said at the moment the record was created, not what the ISR meant to
write, and the witness asserts this GPE's bit is clear in it.

### 3.3 How the orderings are checked

Ordering claims cannot be checked from final state — both orderings
reach the same final state. `gpe_io.pdx` therefore has two modes:

* `GPE_IO_MODE_PORT` (0, the production default, from `.bss` zero-init) —
  real `in`/`out`, real `apic_eoi`.
* `GPE_IO_MODE_SYNTH` (1) — the same accesses against a 512-byte RAM
  window, each appended to an ordered trace, EOI recorded rather than
  written.

`sci_isr.pdx` is byte-identical in both modes; it does not know the mode
exists. The witness reads positions out of the trace and asserts
`mask_idx < clear_idx < eoi_idx`. Inverting the two writes in the ISR
makes the witness fail at stage 28 — verified, not assumed.

---

## 4. Storm protection

**Threshold: 8 consecutive assertions without an acknowledgement.**
Exceeding it retires the GPE — `GPE_ROW_F_PERM_MASKED` set, enable bit
never restored, one `drv_audit_emit` record, no event queued — and the
ISR continues.

Masking bounds the *re-entrant* case. It does not bound the case where
the supervisor evaluates the method, re-enables, and the source asserts
again immediately because the condition was never resolved. That is a
genuine recurrence, and clear-before-EOI is correct while the machine
makes no progress.

Why 8:

* It must exceed the longest legitimate burst. An EC servicing a thermal
  or lid event asserts once per query in a short sequence; ACPICA's
  threshold of 3 is known to retire such bursts on some machines.
* It must be small enough that a wedged line costs nothing. Eight ISR
  entries is microseconds.
* Retirement must not be silent (hence the audit record) and must not be
  a panic. Losing one GPE on a laptop with broken firmware is a degraded
  machine; livelocking on it is a dead one.

The retirement fires on the **transition** only (`strikes == 9`
exactly). A retired GPE that keeps asserting is still masked and cleared
every time — a level-triggered line that is not quiesced livelocks the
machine whatever the table believes — but it is not re-marked and emits
no further records. One retirement, one audit line.

Audit record: event `7` (`GPE_AUDIT_EV_STORM`), kind `0` (not a
capability transition, so `drv_audit_balance_since` / `_live_count` are
unaffected), subject = GPE index, principal = strike count, outcome `1`.

An asserted GPE with **no registered subscriber** is masked, cleared and
struck like any other but not queued: there is nobody to route the
record to, and unroutable records would let an unsubscribed storm evict
the reports a subscribed handler is waiting for. Its strikes still
accumulate, so it is retired on the same schedule.

---

## 5. Block / bit decomposition, and why wrong-block dispatch is
   unrepresentable

`GPE0_BLK` is `GPE0_BLK_LEN` bytes, split in half: status half first,
enable half second. So the block carries `(LEN/2)*8` events and GPE0 owns
indices `0 .. (GPE0_BLK_LEN/2)*8 - 1`. `GPE1_BLK` has the same shape and
its indices start at `GPE1_BASE` — an explicit FADT field, **not** a
continuation of GPE0's count. On platforms where firmware leaves a hole
the two differ, and conflating them dispatches the wrong handler with no
error anywhere.

`gpe_config_set` refuses:

| Condition | Code |
|---|---|
| Odd block length (no equal status/enable split) | `GPE_CFG_BAD_LEN` |
| Half-width > 32 bytes (256 events, the whole `u8` index space) | `GPE_CFG_BAD_LEN` |
| Non-zero length with a zero port, or both blocks empty | `GPE_CFG_BAD_ARG` |
| `GPE1_BASE < gpe0_count` | `GPE_CFG_OVERLAP` |
| `gpe0_count > 256`, `GPE1_BASE >= 256`, or `GPE1_BASE + gpe1_count > 256` | `GPE_CFG_RANGE` |

Every refusal leaves the configuration **fully cleared**, so a
half-written geometry that still reported `configured == 1` cannot exist.

The overlap gate is the load-bearing one. After a successful
configuration the two index ranges are disjoint *by construction*, so
`gpe_resolve`'s "test GPE0, then GPE1" is not a precedence rule that
could hide a GPE1 event: no index satisfies both tests. An index
satisfying neither is `GPE_RESOLVE_BAD` — there is deliberately no
fallback to block 0, because a fallback turns an out-of-range index into
somebody else's handler.

`gpe_resolve` packs `bit` into `[7:0]`, `byte` into `[15:8]`, `block`
into `[23:16]`; the all-ones sentinel is unambiguous because a valid
packing always leaves `[63:24]` clear.

---

## 6. Registration

`gpe_register(index, subscriber_id)`, gates in order:

| Gate | Code |
|---|---|
| Module not configured | `GPE_REG_UNCONFIGURED` |
| `gpe_resolve` cannot place the index | `GPE_REG_BAD_INDEX` |
| `subscriber_id == 0` | `GPE_REG_BAD_HANDLER` |
| Row already `IN_USE` | `GPE_REG_DUPLICATE` |

The range check is expressed as "the configured geometry can decompose
it", not `index < 256`: an index inside the 256-row table but outside
both blocks has no register bit. It also has to precede everything that
touches the table, since a duplicate check on an unbounded index would
read outside the 8 KiB object.

Duplicate registration is **refused**, not silently replaced: replacing
means one subscriber stops receiving events it believes it is still
subscribed to.

`gpe_unregister` bounds on `index < 256` rather than through
`gpe_resolve`, so a row registered under a geometry that has since been
replaced is still removable; otherwise it would be stranded and
`gpe_register` would then refuse it as a duplicate. Codes:
`GPE_REG_BAD_INDEX`, `GPE_REG_NOT_REGISTERED`.

**The table holds no code pointer.** It holds an opaque non-zero
subscriber identity that #1069 resolves to a userspace endpoint. There
is nothing in a row that a future change could plausibly turn into a
call from interrupt context.

---

## 7. SCI routing, and where the numbers come from

Nothing is hardcoded.

* `SCI_INT` comes from the FADT (offset **+46**, u16).
* The GSI, polarity and trigger come from the MADT's Interrupt Source
  Override entries when firmware declares them.
* The ACPI-specified SCI defaults — GSI = `SCI_INT`, **active low**,
  **level** — are used only where firmware has said nothing.

Polarity and trigger are taken from an ISO only on an **explicit** MPS
INTI encoding (`01` or `11`). `00` is "bus conformant" and `10` is
reserved. Bus-conformant on an ISA bus means active-high edge, which for
the SCI is wrong; firmware writing `00` is declining to state a
preference, and a declined preference must leave the ACPI default
standing. An edge-configured SCI loses every assertion arriving while
the line is already high — precisely the shared-level case the SCI
exists to handle. The GSI, by contrast, is taken from a matching ISO
unconditionally, because a remap is the whole reason overrides exist.

**The line is programmed MASKED at R30.M4.** Unmasking belongs to #1069.
Until a subscriber exists, a delivered event could only be retired by the
storm gate after eight assertions; delivering interrupts to a handler
whose only possible outcome is to burn the platform's GPEs is not
"working". The RTE mask bit is part of this milestone's contract and the
witness asserts it.

### 7.1 FADT field-offset correction (in this issue)

The R20.M3 FADT parser counted the SDT header as 40 bytes rather than 36
and placed `FIRMWARE_CTRL` at +40. That displaced `SCI_INT` (+56 instead
of +46) and the whole `PM_*_BLK` run, and put both `X_*` GAS reads inside
the wrong structures (`X_PM1a_CNT_BLK` is at +172, not +148;
`X_PM_TMR_BLK` is at +208, not +176). The R20 synthetic fixture was
fabricated to the same displaced layout, so the two agreed with each
other and with no real firmware; the real-firmware fixture that would
have caught it (`tests/kernel/acpi/fixtures/t14g4/facp.bin`) has not been
captured yet.

R30.M4 reads `SCI_INT` out of that structure, so it is corrected here
against ACPI 6.5 Table 5-33 and the fixture is moved with it. The fixture
had also never been *called* at boot — compiled and linked since R20,
never invoked — which is why the error survived four rounds. It is now
wired into `kernel_main` and fingerprinted as `ACPI FADT OK`.

---

## 8. How "no AML evaluation in the ISR" is structurally guaranteed

Three mechanisms, in increasing order of strength:

1. **Name check.** `tools/lint-no-kernel-aml.sh` refuses any build in
   which an AML-related identifier appears under `src/kernel/**`.
2. **Architecture.** The interpreter is a userspace process, reachable
   only by IPC, and `sci_isr.pdx` issues none. This depends on nobody
   adding a send.
3. **Call-graph check.** `tools/build.sh` reads `objdump -r` on
   `build/core/acpi/sci_isr.o` and requires the set of symbols it
   references to be a **subset** of an explicit allowlist:

   ```
   gpe_block_reg_bytes  gpe_block_status_base  gpe_block_enable_base
   gpe_block_index_base gpe_io_read8           gpe_io_write8
   gpe_io_eoi           gpe_lookup             gpe_note_strike
   gpe_mark_perm_masked gpe_mark_pending       gpe_event_enqueue
   drv_audit_emit
   ```

   Adding a call to an interpreter entry point, an IPC send, a scheduler
   yield, a lock or an allocator fails the build, by name, with the
   offending symbol printed. It also fails if the object has *no*
   relocations, so the check cannot pass vacuously on a gutted ISR.

(3) is why this is a guarantee rather than an intention: it does not
depend on anybody's diligence. It is simultaneously the boundedness
guarantee — every symbol on the list is a bounded, non-blocking leaf or
near-leaf, and nothing else can be called, so the ISR's two nested loops
(2 blocks × ≤32 bytes × 8 bits) are its entire cost.

`sci_isr.pdx` contains exactly one function for this reason. The
acknowledgement path lives in `gpe_ack.pdx` instead: an allowlist that
had to admit read-modify-write cycles on the enable register would leave
the ISR one edit away from re-enabling a GPE it had just masked.

Two further build guardrails accompany it:

* **Storage confinement** (`objdump -r`, same shape as the R30.M3
  OP-REGION check): `_gpe_cfg` only in `gpe_block.o`;
  `_gpe_dispatch_table` and `_gpe_event_ring` only in `gpe_table.o`;
  `_gpe_io_mode` and `_gpe_io_synth_ram` only in `gpe_io.o`.
* **Port-I/O confinement**: no object under `core/acpi/` other than
  `gpe_io.o` may contain an IN/OUT opcode.

---

## 9. paideia-as interaction

`in_al` / `out_al` carry **no effect-row or capability coupling**
(paideia-as#1312). Unlike `!{Mmio}`, which R29.M2-002 taught the
elaborator to require a matching capability for, a port access
type-checks under any effect row. GPE registers are port-mapped on this
platform, so the coupling would apply directly.

Nothing here is blocked by it. The two functions declare
`!{sysreg, mem} @{boot}` by convention, and the port-I/O confinement
check above is the substitute available today. When #1312 lands there is
exactly one object to apply the coupling to.

---

## 10. Witness

`tests/kernel/acpi/gpe_synth.pdx` §`gpe_dispatch_witness`, called from
`kernel_main` after `drv_audit_witness_done`, fingerprint
**`R30 GPE DISPATCH OK`**. Sub-tests A..K; on failure the stage number is
emitted as `line=<n>`.

Placement after the driver-audit witness is deliberate: the storm
sub-test asserts on the most recent audit record, and running earlier
would interleave storm records into the window that witness reads.

Required cases and where they are:

| Required | Stage |
|---|---|
| Clear-before-EOI ordering (access-order assertion) | 25–28 |
| Mask precedes clear | 28 |
| Mask set at the moment the event is queued | 29, 32 |
| GPE1 index resolves to the GPE1 block at the right bit | 12, 13, 15, 38–41 |
| Storm hits threshold, permanently masked, audit record, system survives | 42–47 |
| Registration rejects out-of-range and double-registration, distinct codes | 16–22 |
| Configuration refusals leave the module unconfigured | 1–5 |
| SCI polarity/trigger from overrides, ACPI default when firmware declines | 48–50 |
| RTE programmed level + active low + masked | 51–54 |
| `KIND_HW_INTERRUPT` minted for the SCI, level, correct GSI | 55–58 |

Negative control: inverting the mask/clear order in `sci_isr.pdx` makes
the witness fail at stage 28 and the smoke matrix go red. The assertion
is live.

The seam is returned to real port I/O on both the success and failure
exits, so a failed witness cannot leave the kernel addressing RAM in
place of the platform's GPE block.

---

## 11. `KIND_ACPI_EVENT` — the endpoint capability (#1068)

**Tag `0x151`.** Second entry in the R30 derived-kind block, adjacent to
`KIND_OP_REGION` (`0x150`). Above the 4-bit base-slot space, so
`core/cap/invoke.pdx` compares the full `u64` kind field and the branch
coexists with the slot-9 legacy `KIND_INTERRUPT` handler.

### 11.1 Why a distinct kind, derived over `KIND_HW_INTERRUPT`

The obvious alternative was a right on `KIND_HW_INTERRUPT` — "this
holder may also receive ACPI events". It was rejected because the two
authorities have different shapes and different lifetimes:

* A `KIND_HW_INTERRUPT` holder takes *delivery* of a line. That is a
  per-line authority and it is the driver's.
* A `KIND_ACPI_EVENT` holder *subscribes to the platform's event
  stream* and may *acknowledge* events on it, which is a **write to the
  GPE enable register**. That is a per-process authority and it is the
  ACPI supervisor's.

They are separately revocable in practice — a supervisor restart should
drop the subscription without disturbing whoever owns the SCI line —
and rights on one capability cannot express that.

But the derivation is not decoration either. The reach the endpoint
confers is *strictly downstream* of the SCI interrupt: no assertion
reaches the stream except through the ISR that interrupt's delivery
runs. A holder who could mint an endpoint without holding the interrupt
would have manufactured event reach out of nothing — it would be
entitled to receive, and to re-enable, a line it was never entitled to
take delivery of.

Hence the gate, `acpi_evt_check_parent_hw_int(parent_slot)`:
`cap_table[parent_slot].kind == 0x140` **and** `rights & RIGHT_MINT`.
Both, not either — the kind says the holder may service the line, `MINT`
says it may hand that authority onward. Same shape as
`msix_check_parent_hw_int` (#1022) and `opregion_check_parent_base`
(#1061), deliberately.

### 11.2 The GSI is inherited, never accepted

`acpi_evt_cap_mint` takes **no GSI argument**. It reads the parent
descriptor's `row_id` out of `target_ptr[15:0]` and asks
`hw_int_tail_decode_gsi` which line that capability actually names.

This is the same discipline `opregion_cap_derive` applies to the address
space, for the same reason: a field that identifies *what the parent is*
must come from the parent. An endpoint stamped with GSI 9 whose parent
names GSI 21 would pass the gate and then misreport, for its whole life,
which line its events came from — and that is the one fact a post-mortem
of a platform-event storm needs.

Witness stage 12 asserts it: nothing in the mint call names 9, and the
row reports 9.

### 11.3 Descriptor tail — row indirection

`{parent_slot:u8, gsi:u32, subscriber_id:u64, delivered:u64, acked:u64}`
does not fit a 64-bit `target_ptr`, so `target_ptr` holds a `row_id` into
a private 8-row table, as `KIND_HW_INTERRUPT` (#1019),
`KIND_HW_MSIX_VECTOR` (#1022), `KIND_DMA_DOMAIN` (#1036) and
`KIND_OP_REGION` (#1061) all do.

`_acpi_event_table[row_id]`, 32 bytes:

| Offset | Field | Notes |
|---|---|---|
| `+0` `[7:0]` | reserved | must be zero |
| `+0` `[15:8]` | `parent_slot` | the `KIND_HW_INTERRUPT` it derives from |
| `+0` `[47:16]` | `gsi` | **inherited** at mint |
| `+0` `[55:48]` | reserved | must be zero |
| `+0` `[63:56]` | `in_use` | allocator flag; `.bss` zero-init makes every row free at boot |
| `+8` | `subscriber_id` | opaque, non-zero |
| `+16` | `delivered` | records accepted for this endpoint, lifetime |
| `+24` | `acked` | successful acknowledgements, lifetime |

**Eight rows, not 256.** An endpoint is a per-*process* subscription.
Per-GPE fan-out is not done by minting one endpoint per GPE — it is done
by the `subscriber_id` the dispatch table already stores per GPE row,
carried on every record. Sizing for processes rather than event sources
is why eight is enough.

`delivered − acked` is the milestone's most useful single number: the
count of platform events this endpoint was told about and never finished.
That is the only observable that catches a GPE which is masked,
dispatched, handled and never re-enabled — see §13.3.

### 11.4 Name check

`tools/lint-no-kernel-aml.sh` matches `\baml`, `\bdsdt`, `\bssdt`,
`\bacpica([^a-zA-Z]|$)`, `\_SB_`, `\_SB.`. `KIND_ACPI_EVENT`,
`acpi_evt_*` and `_acpi_event_table` match none: `acpi` is not `acpica`
(the tight pattern needs the sixth character and a non-letter after it).
**Checked, not assumed** — #1569 records that `KIND_AML_SESSION` must
become `KIND_FW_SESSION` for exactly this reason, and the linter passes
green on this tree with the new kind in it.

### 11.5 Failure taxonomy — `0xFFFFFF90..0xFFFFFF9F`

A band disjoint from every other in tree (`chaos.pdx` owns
`0xFFFFFFA0..AD`, the GPE path `0xFFFFFFB5..BE`, `KIND_OP_REGION`
`0xFFFFFFC5..CF`, `KIND_DMA_DOMAIN` `0xFFFFFFD5..DF`).

| Code | Name | Raised when |
|---|---|---|
| `0xFFFFFF9F` | `ACPI_EVT_TAIL_ENOSPC` | no free row |
| `0xFFFFFF9E` | `ACPI_EVT_TAIL_BAD_ARG` | reserved header bits set, or zero subscriber |
| `0xFFFFFF9D` | `ACPI_EVT_MINT_BAD_PARENT` | **the derivation gate**: parent is not a live `KIND_HW_INTERRUPT`, or lacks `RIGHT_MINT` |
| `0xFFFFFF9C` | `ACPI_EVT_MINT_BAD_RIGHTS` | rights not a subset of `R_ACPI_EVT_ALL` (`0x618`) |
| `0xFFFFFF9B` | `ACPI_EVT_MINT_BAD_ARG` | slot ≥ 256, or a malformed header |
| `0xFFFFFF9A` | `ACPI_EVT_MINT_ENOSPC` | row table exhausted at mint |
| `0xFFFFFF99` | `ACPI_EVT_MINT_BAD_SUBSCRIBER` | subscriber identity is zero (the "no subscriber" sentinel) |
| `0xFFFFFF98` | `ACPI_EVT_REVOKE_BAD_SLOT` | slot ≥ 256 |
| `0xFFFFFF97` | `ACPI_EVT_REVOKE_WRONG_KIND` | descriptor is not `KIND_ACPI_EVENT` |
| `0xFFFFFF96` | `ACPI_EVT_REVOKE_ALREADY` | slot already null (idempotent) |
| `0xFFFFFF95` | `ACPI_EVT_NOT_READY` | acknowledgement attempted with no endpoint bound |
| `0xFFFFFF94` | `ACPI_EVT_BIND_BAD_CAP` | bind target is not a usable live endpoint with `RIGHT_INVOKE` |
| `0xFFFFFF93` | `ACPI_EVT_BIND_ALREADY` | the stream already has a consumer |
| `0xFFFFFF92` | `ACPI_EVT_NOT_BOUND` | unbind with nothing bound |
| `0xFFFFFF91` | `SCI_ARM_NOT_READY` | **the unmask ordering gate** — §14 |
| `0xFFFFFF90` | `SCI_ARM_PROGRAM_FAILED` | the redirection entry could not be programmed |
| `0xFFFF…FFFF` | `ACPI_EVT_DECODE_BAD` | dead row / malformed encoder input |

### 11.6 Ops

| Op | Code | Right | Returns |
|---|---|---|---|
| `QUERY_GSI` | 0 | `OBSERVE` | the inherited GSI |
| `QUERY_PARENT` | 1 | `OBSERVE` | parent `cap_table` slot |
| `QUERY_SUBSCRIBER` | 2 | `OBSERVE` | opaque identity |
| `QUERY_DELIVERED` | 3 | `OBSERVE` | lifetime deliveries |
| `QUERY_ACKED` | 4 | `OBSERVE` | lifetime acknowledgements |
| `QUERY_DEPTH` | 5 | `INVOKE` | stream depth |
| `QUERY_DROPS` | 6 | `INVOKE` | stream ring drops |

The gate is per-op, not per-entry: ops 0–4 read the endpoint's own
metadata, ops 5–6 read the *shared stream*. A monitor holding only
`OBSERVE` must not learn the platform's event rate from a capability that
only entitles it to introspect itself.

There is deliberately **no `DRAIN` or `ACK` op**. Draining copies a
64-byte record out, which a three-register invocation cannot express
without taking a destination pointer — and a destination pointer across
that boundary is exactly the aliasing the `_acpi_evt_ring` confinement
assertion exists to prevent.

---

## 12. The subscriber stream (#1069)

### 12.1 Two sources, and why conflating them would be a real bug

| Source | Means | Payload | Owes |
|---|---|---|---|
| `ACPI_EVT_SRC_GPE` (1) | hardware asserted; the ISR masked, cleared, struck and queued it | `a0` = GPE index, `a1` = enable byte read back at enqueue, `a2` = strikes | **an acknowledgement** — the GPE is masked until it arrives |
| `ACPI_EVT_SRC_NOTIFY` (2) | firmware executed `Notify(Object, Value)` during an evaluation | `a0` = target node, `a1` = value, `a2` = target object type | nothing — no hardware bit is masked |

The first means *"hardware wants attention and is holding its breath"*.
The second means *"firmware is telling you something changed"*. A
subscriber that could not tell them apart would either acknowledge
notifications — producing a stream of `GPE_ACK_NOT_PENDING` with no clue
why — or fail to acknowledge genuine GPEs, leaving them masked forever
with no error anywhere.

So `source` is field 0 of the record, and it is accompanied by a
**redundant** `flags` word carrying `ACPI_EVT_REC_F_NEEDS_ACK`. The
redundancy is deliberate: `source` says where the event came from,
`flags` says what the subscriber owes in return, and a future third
acknowledging source can set the flag without every existing subscriber
having to learn a new source number.

The `NOTIFY` side is the kernel-side landing point for the bounded
userspace notification ring (#1059, depth 32, tail-drop, per-entry offer
sequence). The supervisor drains its own ring and forwards through
`acpi_evt_notify`, so one stream carries the platform's whole event
picture without the kernel ever reading firmware bytecode state.

### 12.2 Record layout — 32 slots × 64 bytes

| Offset | Field |
|---|---|
| `+0` | `source` |
| `+8` | `subscriber` |
| `+16` | `a0` |
| `+24` | `a1` |
| `+32` | `a2` |
| `+40` | `seq` — the offer number this record *is* |
| `+48` | `flags` |
| `+56` | reserved |

Sixty-four bytes rather than the forty-eight the fields need, so the slot
index is a shift and each record is a whole cache line.

### 12.3 Backpressure — the third bounded ring, same discipline

This is the **third** bounded ring in the ACPI path (ISR→kernel in
`gpe_table.pdx`, firmware notifications in userspace, and this one). It
reuses their discipline rather than inventing one.

**Depth 32**, and the number is argued rather than copied. The
mask-before-enqueue rule means each GPE has *at most one* outstanding
event, so in-flight records are bounded by the number of *distinct*
unacknowledged GPEs. A platform with more than 32 distinct GPEs
simultaneously unacknowledged is a platform in a storm, which the storm
gate retires at 8 strikes each on a microsecond timescale. Going deeper
would not rescue that machine — it would delay the loss, enlarge the set
of stale records the subscriber eventually reads, and move the drop
further from the moment that caused it. 32 also matches both rings
upstream, so a reader who has understood one has understood all three.

**Tail-drop.** A full ring refuses the *new* record and keeps the old
ones. Overwrite-oldest turns bounded loss into *reordering* and erases
the first report of the condition that caused the overrun — the record an
operator most needs. Witness stage 50 asserts it directly: after 40
offers into 32 slots the retained records are offers 0–31, not 8–39.

**Two counters, not one.**

* `drops` — the ring was full. The subscriber is alive but behind.
* `unrouted` — there was nobody to route to: no endpoint bound, a GPE
  with no registered subscriber, or an unrecognised source.

Different problems, different fixes; summing them would make a wedged
subscriber and an absent one indistinguishable.

**Localisable.** *Every* offer — accepted, dropped or unrouted alike —
consumes one number from a monotonic `offered` counter, and accepted
records carry it as `seq`. A subscriber reading sequences 31 then 40
knows eight events were lost *between those two*. A sequence that only
counted acceptances would be gapless and therefore useless for exactly
the case it exists to diagnose.

**Accounting identity:**

```
offered == drained + depth + drops + unrouted
```

the #1059 identity with one extra term for the failure mode that ring
does not have. The witness asserts it at stages 49 and 54.

---

## 13. The round trip

### 13.1 The path

```
assert  -> ISR: mask, clear, strike, enqueue        (sci_isr.pdx)
        -> acpi_evt_pump: route into the stream     (evt_stream.pdx)
        -> subscriber drains, evaluates the method  (userspace)
        -> acpi_evt_ack                             (evt_stream.pdx)
        -> gpe_ack: clear strikes, clear pending,
           RE-ENABLE                                (gpe_ack.pdx)
```

### 13.2 The pump runs in task context, and that is the whole shape

`acpi_evt_pump` is deliberately **not** on the ISR's build-asserted
call-target allowlist. Every individual step it takes is bounded, so it
*could* have gone in the interrupt — and that is precisely why keeping it
out has to be a build failure rather than a convention. The allowlist
admits only bounded non-blocking leaves; routing consults three tables
and belongs on the other side of the boundary.

It is bounded twice over: the ISR ring holds at most 32 records, and an
explicit iteration cap of 32 makes the bound local, so a later change to
the ring depth cannot silently make the loop unbounded.

A `gpe_lookup` of 0 is **not** filtered by the pump. The offer is made
and refused as `unrouted`, so the no-subscriber case is counted in one
place rather than being invisible because the pump quietly skipped it.

### 13.3 The re-enable is the point

The ISR masks a GPE before queueing it so it cannot re-fire while its
handler is outstanding. A GPE that is masked, dispatched, handled and
never re-enabled is **a device that works exactly once**, and it produces
no error anywhere — the handler ran, the method evaluated, nothing
failed.

`acpi_evt_ack` is the only thing in the system that closes that loop, and
it increments `acked` **only on `GPE_OK`**, so the counter means *"the
GPE was re-enabled"* rather than *"an acknowledgement was attempted"*.
`delivered − acked` is the standing observable.

`gpe_ack`'s code is returned **unchanged** rather than collapsed into a
boolean, because `GPE_ACK_NOT_PENDING` is exactly what a subscriber gets
if it acknowledges a `NOTIFY`-sourced record by mistake, and that
diagnosis must survive the layer.

Witness stage 29 is the single assertion the milestone turns on: after
the acknowledgement, the GPE's enable bit is set again in the synthetic
register window. Stage 31 then asserts the consequence — the same GPE
asserts, is serviced, routed, drained and acknowledged a second time.

### 13.4 The no-subscriber case, loudly

Two halves, because there are two places "nobody is listening" can be
discovered:

1. **In the ISR**, when `gpe_lookup` returns 0. The GPE is masked,
   cleared and struck exactly as any other, and **not** queued — spending
   bounded ring slots on unroutable records would let an unsubscribed
   storm evict the reports a subscribed handler is waiting for. #1069
   added the other half: **one `drv_audit_emit` record** with event
   `GPE_AUDIT_EV_UNROUTED` (8), kind 0, subject = GPE index, outcome 0,
   emitted on the *transition only* (`strikes == 1`). An unroutable GPE
   is never acknowledged, so its strikes climb monotonically and this
   fires exactly once, followed eight assertions later by the storm
   retirement's own line. One report per condition — a report that fires
   on every assertion of a wedged line becomes the flood it is
   describing.

2. **In the stream**, when an offer carries the zero identity (or the
   endpoint is unbound). Counted as `unrouted`, never as `drops`.

**The ISR allowlist was not widened.** `drv_audit_emit` was already on it
for the storm path, so the unroutable report added zero call targets.
That was a constraint on the design, not a happy accident: the
alternative — a new `gpe_note_unroutable` leaf — would have been a
one-symbol widening, and a widening that is easy to justify once is the
kind that happens twice.

---

## 14. Unmask ordering (#1069)

#1066 programmed the redirection entry **masked** and recorded that
unmasking belonged here. The reason was not sequencing convenience: an
interrupt delivered into a system with no subscriber has two possible
outcomes and both are bad.

* Queued and never drained — the GPE stays masked (only an
  acknowledgement re-enables it) and the ring fills with records nobody
  will read.
* Not queued at all, because no subscriber is registered — the ISR masks,
  clears and strikes it, and after eight strikes the storm gate retires
  the GPE **permanently**. Boot would consume the platform's GPEs, one
  every eight assertions, before the supervisor process started.

### 14.1 The ordering

| Step | Operation | Effect |
|---|---|---|
| 1 | `gpe_config_*` | geometry known |
| 2 | `sci_route_install(masked = 1)` | ISR installed, **line quiet** (#1066) |
| 3 | `gpe_register(index, subscriber)` | per-GPE subscriber identities |
| 4 | `acpi_evt_cap_mint` | endpoint, derived from the SCI's own `KIND_HW_INTERRUPT` |
| 5 | `acpi_evt_bind` | **readiness becomes true** |
| 6 | `sci_arm` | **the unmask** |

`sci_arm` consults `acpi_evt_ready()` **first** and does not touch the
IOAPIC when it refuses, so a refused arm leaves the entry exactly as the
masked install left it.

### 14.2 What happens to a GPE that fires before any subscriber exists

**In the ordered boot path, nothing does** — the line is masked at the
IOAPIC before step 6, so the hardware is not listening yet. That is the
honest answer, and it is why the ordering is enforced rather than merely
documented.

**After** step 6, if the subscriber disappears (its endpoint is revoked,
which unbinds the stream — §14.4), events do fire and are dropped. That
case is not silent: `acpi_evt_unrouted` increments per offer, and the
ISR's `GPE_AUDIT_EV_UNROUTED` record names each GPE the first time it
asserts unsubscribed. Dropping an event nobody is listening for is
defensible; dropping it without saying so is not.

### 14.3 One resolver, called twice

`sci_route_install` takes `masked` as a parameter precisely so the arm
and the masked install share one resolution path. A second resolver would
be free to disagree, and the disagreement that matters is trigger mode:
an edge-configured SCI loses every assertion arriving while the line is
already high, which is the shared-level case the SCI exists to handle.

### 14.4 Revocation pushes, it does not poll

`acpi_evt_cap_revoke_inner` calls `acpi_evt_unbind_slot(slot)` **before**
freeing the row, so readiness falls in the same operation. There is no
window in which the stream believes it is bound to a descriptor that no
longer exists, and `acpi_evt_ready()` can stay a latched read instead of
a descriptor re-validation — which would have forced the `{cap}`
capability up the entire arming path. `acpi_evt_unbind_slot` compares the
slot before clearing, so revoking endpoint A cannot unbind endpoint B.

Disarming is *not* done by the unbind: a bookkeeping change must not
quietly reprogram an interrupt controller as a side effect.
`sci_disarm` is the explicit operation, and it is deliberately **not**
readiness-gated — refusing to quiet a line because the stream is already
unbound would make the one recovery a wedged system needs conditional on
the thing that wedged it.

---

## 15. Witness (#1068/#1069)

`tests/kernel/acpi/evt_route_synth.pdx` §`evt_route_witness`, called from
`kernel_main` immediately after `gpe_dispatch_witness`, fingerprint
**`R30 ACPI EVENT ROUTE OK`**. Sub-tests A..G; on failure the stage
number is emitted as `line=<n>`.

Placement after the GPE witness is **required**: sub-test D reads the
most recent driver-audit record and asserts it is this fixture's
`GPE_AUDIT_EV_UNROUTED` line, and the GPE fixture's storm retirement
writes a record of its own.

**No IOAPIC register is written.** Both `sci_arm` calls use an `SCI_INT`
of 2³², whose resolved GSI is the low 32 bits — zero — and
`sci_route_program` refuses a GSI of 0 before any MMIO. That is what lets
the readiness gate be exercised in *both* directions without the witness
reprogramming the platform's interrupt controller during boot.

| Required | Stage |
|---|---|
| Derivation gate refuses a `KIND_HW` parent | 4 |
| Derivation gate refuses a `KIND_HW_INTERRUPT` without `RIGHT_MINT` | 5 |
| Mint refuses bad rights / zero subscriber / bad slot | 6, 7, 8 |
| No refusal consumed a row | 9 |
| **GSI inherited from the parent, not accepted** | 12 |
| Unmask refused while unbound; armed flag stays clear | 15 |
| Bind refusals: wrong kind, out of range, double bind | 16, 18 |
| **Same arming call, different code once bound** — the gate passed | 19 |
| GPE asserts → ISR masks and queues | 21, 22, 23 |
| Routed to the registered subscriber | 24 |
| Record carries source / subscriber / index / snapshot / strikes / seq / flags | 25 |
| `delivered` incremented, `acked` not yet | 26 |
| **Acknowledgement RE-ENABLES the GPE** | **29** |
| `acked` incremented, strikes reset | 30 |
| **A handled GPE fires again** — full second round trip | 31 |
| Double acknowledgement refused | 32 |
| No-subscriber GPE: masked, struck, **not queued** | 33, 34, 35 |
| No-subscriber GPE: **one audit record naming it** | 36 |
| Masking one GPE leaves its neighbour's enable bit alone | 37 |
| Stream-side no-subscriber offer counted `unrouted`, not `drops` | 39 |
| Unknown source refused | 40 |
| Notification record: source 2, **no `NEEDS_ACK`**, payload intact | 41, 42 |
| **GPE and notification distinguishable on both discriminators** | 44 |
| Acknowledging a notification refused with a diagnostic code | 45 |
| Saturation: depth 32, drops 8, `unrouted` 0, offered 40 | 48 |
| Accounting identity holds | 49, 54 |
| **Tail-drop: the retained records are the FIRST 32** | 50 |
| Drained sequences contiguous 0..31 | 51 |
| **Sequence gap equals the drop count** — loss localised | 53 |
| Revoke unbinds: readiness falls with the row | 55 |
| Post-revoke offers refused and counted | 56 |
| Post-revoke acknowledgement refused `ACPI_EVT_NOT_READY` | 57 |
| Revoke idempotence + wrong-kind refusal | 58 |

**Negative control.** Removing the `call gpe_enable` from `gpe_ack` — the
single instruction that closes the round trip — makes the witness fail at
**stage 29** and prints `line=29`. Verified by building and booting that
mutation, not assumed. Every other assertion in the fixture still passed
under it, which is the point: a GPE that is masked, dispatched, handled
and never re-enabled looks *entirely healthy* from every other angle, and
stage 29 is the only thing in the system that notices.

Both exits return the seam to real port I/O, reset all three tables and
re-zero `cap_table` slots 17, 18 and 19 — outside the set every other
witness consumes.

### 15.1 Build guardrails touched

`tools/build.sh` gained three confinement assertions using the existing
`gpe_confine_one` helper (symbol must be referenced by its owner — the
vacuity guard — and by nothing else):

* `_acpi_event_table` → `core/cap/kind_acpi_event.o`
* `_acpi_evt_ring` → `core/acpi/evt_stream.o`
* `_acpi_evt_state` → `core/acpi/evt_stream.o`

The ISR call-target allowlist is **unchanged** — see §13.4.
