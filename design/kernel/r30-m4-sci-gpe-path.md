# R30.M4 — the SCI / GPE interrupt path

Issues: **#1066** (SCI ISR install as `KIND_HW_INTERRUPT`), **#1067** (GPE
dispatch table + registration). Followed by #1068 (SCI event stream) and
#1069 (notify → subscriber routing), both of which build on the event
ring described here.

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

No new `KIND_*`. The SCI is a GSI, and `KIND_HW_INTERRUPT` (R29.M1,
tag `0x140`, tail `{gsi, cpu_affinity_mask, edge_or_level}`) is already
exactly the capability that grants one. `next-wave-derived-kinds.md`
needs no new row; `edge_or_level = 1` is the SCI's value.

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
