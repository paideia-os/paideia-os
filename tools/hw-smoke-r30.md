# R30 hardware smoke — operator recipe (T14 G4)

**Owner issues:** #1085 (fuzz corpus), #1086 (crash isolation), #1087
(performance budget), #1088 (DSDT/SSDT capture).
**Status:** **UNSEEDED.** Every procedure below is written to be run on a
real ThinkPad T14 Gen 4 and none of them has been run. No expected values
are recorded, because recording an expected value nobody measured is the
failure this file exists to avoid.

This follows the discipline of `tools/hw-smoke-fingerprints.md`: the recipe
lands before first light, and the expectations are filled in from a real
capture, at which point the corresponding check promotes from SKIP to LIVE.

---

## 0. Why this file has no numbers in it

Three of the four R30.M9 issues have a hardware half that this environment
cannot reach:

| Issue | Doable off-target | Needs the machine |
|---|---|---|
| #1085 | the fuzzer, the mutators, the invariants, the corpus | seeding the corpus from real tables |
| #1086 | the Global Lock abandon path and its fixtures | a real fault in a real bubble |
| #1087 | the deterministic work budget | any wall-clock figure at all |
| #1088 | the capture tooling and the fixture format | the captures themselves |

Writing plausible-looking numbers for the right-hand column would make
every downstream test that trusted them worthless. See
`design/acpi/perf-methodology.md` §1 and `design/acpi/fuzz-strategy.md` §6.

---

## 1. R30.M9-003 — the wall-clock method budget

**Blocked.** Do not attempt yet. The prerequisites are filed as their own
issue and are, in order:

1. A monotonic time source readable from ring 3 (no clock syscall exists
   today — the handler set is fifteen calls and none reads a clock).
2. Thread affinity in the scheduler, then core reservation, before
   "reserved LP-E core" means anything.
3. An on-target measurement mode in the acpi_supervisor.

**When those land, the procedure is:**

1. Boot the T14 G4 to the acpi_supervisor prompt per
   `design/hardware/t14-g4-first-boot.md`.
2. Pin the supervisor to an LP-E core. Confirm the pinning took by reading
   the per-CPU hybrid class (`PERCPU_OFF_HYBRID_CLASS`, +120; LP-E is
   class 3) — do not infer it from the core index, which is firmware-
   assigned and not stable across BIOS revisions.
3. Evaluate `\_SB.PCI0._STA` (or another argument-free method with no
   OperationRegion access) 1000 times, recording the clock around each
   `aml_eval_method`.
4. Record **min / median / p99 / max**, not the mean. The budget is a
   statement about the tail; a mean hides exactly the excursion that would
   miss a thermal deadline.
5. Record the **fuel cost** of the same method alongside the times. The
   pair is what makes a later regression attributable: fuel up means the
   interpreter got slower, fuel flat and time up means the machine did.

**Acceptance:** p99 < 2 ms. **Expected values: NOT YET MEASURED.**

Cross-check against the off-target deterministic baseline in
`design/acpi/perf-methodology.md` §2.1 — the simple-method fixture costs
**4 fuel steps at peak depth 3 in 1 frame**. If the on-target method costs
a wildly different number of steps, the two are not measuring comparable
work and the comparison is void.

---

## 2. R30.M9-002 — crash isolation on real hardware

**Partially blocked.** The Global Lock abandon path (P3) is implemented
and tested off-target; capability revocation on death (P2) has no trigger
wired yet. See `design/acpi/crash-isolation.md` §3.4.

**The P3 procedure, when a fault path exists:**

1. Boot to a state where the acpi_supervisor has attached the Global Lock
   (the EC is up; `\_GL` has been taken at least once).
2. Induce a fault in the bubble **while it holds the lock**. The narrow
   window is inside an EC transaction, so the injection has to be armed
   rather than timed.
3. Assert, from the kernel side:
   - the kernel is still up and the serial log continues;
   - the FACS lock word at **FACS + 0x10** has its Owned bit **clear**;
   - `GBL_STS` was raised if anything was Pending.
4. **Then leave the machine idle for 10 minutes and watch the fan.** This
   is the assertion that actually matters and it is not a register read:
   if the lock were stranded, firmware would stop managing thermals, and
   the observable is a fan that never spins up under load followed by a
   thermal trip.

**Do not skip step 4.** A cleared lock word proves we released it; only
the thermal behaviour proves firmware noticed.

**Expected values: NOT YET MEASURED.**

---

## 3. R30.M9-001 — seeding the fuzz corpus from real tables

Blocked on #1088. Once real DSDT/SSDT captures exist under
`tools/hw-captures/`:

1. Add each captured table as a fuzzer **seed**, not as a corpus entry —
   a seed is a mutation parent; a corpus entry is a pinned expected
   outcome, and a real table's outcome should be discovered, not asserted
   in advance.
2. Re-run the soak. Expect the corpus to grow substantially: vendor AML
   reaches constructs the synthetic seeds do not, which is the entire
   reason #1088 exists.
3. Any invariant trip found this way is a **real finding** against real
   firmware and should be filed on its own, not folded into a corpus
   update.

**Note the ordering constraint:** the arenas are sized for fixture scale
(512 nodes / 512 name words / 128 u64 slots). A full T14 G4 DSDT needs
roughly two orders of magnitude more. Seeding real tables will therefore
hit `AML_ERR_NODE_ARENA_FULL` (9) immediately — that is expected, is a
`.bss` sizing change and nothing else, and must be done **before** the
seeding is meaningful rather than treated as a fuzz finding.

---

## 4. R30.M9-004 (#1088) — capture procedure

See `tools/capture-t14-g4-acpi.md`, which already describes the capture
mechanics. What #1088 adds is **three BIOS revisions**, which means the
operator must:

1. Record the exact BIOS version string before each capture
   (`FADT`/`DSDT` OEM revision, and the vendor's own version string).
2. Capture **before** updating, at each revision — a capture cannot be
   re-taken once the firmware is replaced, and downgrades are not always
   permitted.
3. Store each capture under `tools/hw-captures/<bios-version>/` with the
   provenance recorded alongside it.

**Provenance is not optional metadata.** A table whose BIOS revision is
unknown cannot be used to answer the question #1088 exists to answer —
which is what changed between revisions.
