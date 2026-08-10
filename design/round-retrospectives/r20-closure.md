// R20 Retrospective: ACPI Static-Table Foundation

**Date:** 2026-08-10
**Milestone:** R20.M1–R20.M5 (all closed; M5 = closure milestone this doc + #823)
**Issues:** 19 landed (#805–#822 + #823 fixture harness + #824 closure); 17 implementation, 1 deferred (#820), 2 closure (#823 + #824)
**HEAD at closure:** (bumped by the R20.M5 commit that lands this doc)
**paideia-as pinned at:** `b0cb6f3` — unchanged across R20 (no cross-repo escalation this round)

---

## Round Intent

R20 was scoped as the ACPI static-table foundation round per
`design/roadmap/r18-plus-bare-metal.md` §R20. The five milestones
threaded the RSDP → XSDT → per-table parsers → typed handoff record
→ userspace boundary in order:

- **M1:** RSDP scan + XSDT walker + checksum + SIG4 constants.
- **M2:** MADT sub-entry parsers + MADT-driven AP topology (retires the
  R18.M1 hard-coded `_ap_apic_ids` stopgap).
- **M3:** MCFG + FADT + HPET parsers + GAS decoder + `phase1_acpi_info`
  512-byte handoff record.
- **M4:** `KIND_ACPI` derived capability scaffold + IPC schema doc +
  "no-AML-in-kernel" hard guardrail.
- **M5:** T14 G4 fixture harness (this milestone: #823) + closure
  retrospective (#824).

Pillar 3 target: give the kernel exactly the static-table view it
needs to bring up SMP + IOAPIC + HPET + PCIe ECAM + power-management
ports, and no more. Every AML-adjacent responsibility is punted to
the R34 userspace ACPICA bubble.

---

## What Shipped

### R20.M1 — Static-table foundation (4 issues: #805–#808)

- **#805 RSDP scanner** — `src/kernel/acpi/rsdp.pdx` with
  `acpi_rsdp_scan_range` (byte-scan for `"RSD PTR "` on 16-byte
  boundaries) and `acpi_find_rsdp` (fast-path via `boot_env_t.rsdp_pa`,
  fallback to EBDA + 0xE0000–0xFFFFF legacy scan).
- **#806 XSDT walker** — `src/kernel/acpi/xsdt.pdx`. `acpi_xsdt_find`
  (linear scan by SIG4) + `acpi_xsdt_iter` (full enumeration
  callback). Trust boundary: caller checksums the XSDT header before
  invoking (checksum lives in #807, not fused in).
- **#807 Checksum primitive + SIG4 constants** — `src/kernel/acpi/
  checksum.pdx` `acpi_checksum_ok` (u8-sum mod 256 == 0); `sdt_hdr.pdx`
  `SIG_APIC`, `SIG_MCFG`, `SIG_FACP`, `SIG_HPET`, `SIG_XSDT` u32 LE
  constants.
- **#808 Synthetic fixtures for M1** — `tests/kernel/acpi/rsdp_synth.pdx`
  and `xsdt_synth.pdx`; hand-checksummed 36-byte RSDP v2 blob and a
  3-entry XSDT drive both parsers end-to-end (GDB-invocable via
  `call acpi_rsdp_synth_witness` / `call acpi_xsdt_synth_witness`).

**Closure commit:** `0e37855`.

### R20.M2 — MADT sub-entry parsers + AP topology (5 issues: #809–#813)

- **#809 madt_parse_lapics** — Type-0 walker into `_madt_lapics` array
  (uid + apic_id + flags). Skips flags-disabled entries at the
  topology consumer.
- **#810 madt_parse_ioapics** — Type-1 walker into `_madt_ioapics`
  (id + base + gsi_base).
- **#811 madt_parse_isos** — Type-2 walker into `_madt_isos` (bus +
  source + gsi + flags). ISA IRQ → GSI remapping records.
- **#812 madt_parse_x2apics** — Type-9 walker into `_madt_x2apics`
  (x2apic_id + flags + uid). x2APIC 32-bit IDs for high-ID cores.
  Type-5 LAPIC-address-override is folded into `madt_topology`.
- **#813 madt_topology / topology_seed_from_madt** —
  `core/smp/madt_topology.pdx` merges Type-0 + Type-9 into a unified
  `_ap_apic_ids: [u32; N]`. Retires R18.M1's hard-coded `[u8; 4]`
  stopgap. Filters out the BSP APIC ID + flags-disabled entries.
- **Synthetic MADT fixture** — `tests/kernel/acpi/madt_synth.pdx`
  (174-byte fabricated MADT covering 4 LAPICs + 2 IOAPICs + 3 ISOs +
  Type-5 override + 2 x2APICs).

**Closure commit:** `594beda`.

### R20.M3 — MCFG + FADT + HPET + GAS + phase1 handoff (5 issues: #814–#818)

- **#814 MCFG parser** — `src/kernel/acpi/mcfg.pdx`. `mcfg_parse_segments`
  extracts up to 16 PCIe segments into `_mcfg_segments`;
  `mcfg_ecam_base_for_segment` is the seg-id lookup helper.
- **#815 FADT parser** — `src/kernel/acpi/fadt.pdx`. `fadt_parse`
  extracts SCI_INT, PM1a/1b_CNT_BLK, PM_TMR_BLK, PM_TMR_LEN, CENTURY,
  RESET_REG + RESET_VALUE, and the X_ preferred-form overrides
  (`X_PM1a_CNT_BLK`, `X_PM_TMR_BLK`). Length-gated for ACPI 1.0 / 2.0+
  / 6.x compat. Encoder-gap workarounds: G1 (mov_d) + G4 (full-reg
  compares) applied inline.
- **#816 HPET parser** — `src/kernel/acpi/hpet.pdx`. `hpet_parse`
  extracts counter_base (via GAS), block_id, min_tick (byte-load-
  recombined to sidestep the misaligned u16 at HPET+53), hpet_number.
- **#817 GAS decoder** — `src/kernel/acpi/gas.pdx`. `gas_read` +
  `gas_is_valid` helpers. Handles unaligned u64 loads at GAS+4 per
  SDM Vol.3 §7.1.1.
- **#818 phase1_acpi_info handoff** — `src/kernel/acpi/phase1_info.pdx`.
  512-byte typed record (@align(8)) with fadt_info + hpet_info +
  MCFG seg0 base + LAPIC base + topology counts (ap_count,
  x2apic_count, iso_count, ioapic_count) + has_hpet/has_mcfg/has_fadt
  flags + 360 bytes reserved for R21+ (PPTT / SRAT / IORT / TPM2). NOT
  yet wired to `kernel_main` — R20.M4 will do that.
- **Synthetic fixtures for M3** — `mcfg_synth.pdx` (2-entry MCFG),
  `fadt_synth.pdx` (244-byte FADT with X_ form override),
  `hpet_synth.pdx` (56-byte HPET + GAS validity-failure probe).

**Closure commit:** `60df1d7`.

### R20.M4 — Kernel↔userspace boundary (4 issues: #819–#822; #820 deferred)

- **#822 no-AML-in-kernel guardrail** — `design/acpi/no-aml-in-kernel.md`
  design doc (pillars 3+6+Q5 rationale + forbidden-token set) +
  `tools/lint-no-kernel-aml.sh` grep-based enforcement (two-shape
  matcher: LOOSE for aml/dsdt/ssdt, TIGHT for acpica; comment-stripped;
  runs in <1s). Wired into `tools/build.sh` and the pre-push hook as
  gate #1 (before the assembler pass — a violation fails fast). Kernel
  currently clean, lint passes on 0 matches.
- **#819 KIND_ACPI derived capability** — `src/kernel/core/cap/
  acpi_cap.pdx` (KIND_ACPI as a derived kind following the DriverCap
  pattern; base = KIND_PAGE = 4; derived tag = 0x20). Exposes
  R_ACPI_READ (READ-only; write/mint/exec forbidden), `rights_valid`,
  `range_valid` (≤ 2 MiB bound), and `acpi_cap_mint` (gate-only). Full
  descriptor write deferred until `cap_revoke`'s real body lands.
- **#821 IPC schema for acpi_supervisor** — `design/ipc/
  acpi-supervisor-schema.md`. Typed AcpiEnum / AcpiMadt / AcpiMcfg /
  AcpiHpet request/reply records. 8-byte header + LE payload +
  reserved-must-be-zero fields. Wire code deferred with server binary.
- **#820 acpi_supervisor server binary — DEFERRED** to blocker issue
  #1015 (userspace-server substrate: named endpoints, service broker,
  variable-length IPC message support, initial-capability-transfer
  slot). Rationale in the M4 landing commit; #820 is the ONLY R20
  issue that could not close intra-round, and its dependencies are
  independently roadmapped for R21+.

**Closure commit:** `41ae161`.

### R20.M5 — Fixture harness + closure (2 issues: #823 + #824)

- **#823 T14 G4 fixture harness** — three pieces landed at R20 close:
  - `tools/parse-acpi-fixture.sh` — host-side harness. Validates a
    fixture directory contains the expected six ACPI table binaries
    (`rsdp.bin`, `xsdt.bin`, `apic.bin`, `mcfg.bin`, `facp.bin`,
    `hpet.bin`), verifies each file's SIG4 header, reports
    present/missing counts. `--help` prints inline usage. Exit codes
    document the pre-capture (WARN, exit 0) vs post-capture (FAIL,
    exit 3 on SIG mismatch) states.
  - `tools/capture-t14-g4-acpi.md` — operator-side capture recipe.
    Boot Linux on the T14 G4, `dd if=/sys/firmware/acpi/tables/<TBL>
    of=/tmp/t14g4-acpi/<tbl>.bin`, transfer, `git add`. Includes
    BIOS-setup crossref to R19 §3 and firmware-provenance capture
    (`dmidecode` with serial-redaction reminder).
  - `tests/kernel/acpi/t14_g4_fixture.pdx` — compilable placeholder.
    Reserves the marker strings (`ACPI T14G4 OK\n\0` /
    `ACPI T14G4 FAIL\n\0`) and a 256-byte expected-values slot;
    documents the enabling conditions (fixture files present +
    `.incbin` wrapper landed + `machine_id` dispatch wired). Compiles
    clean under `tools/build.sh` with no runtime symbols beyond the
    reserved byte arrays.
  - `tests/kernel/acpi/fixtures/t14g4/README.md` — the fixture
    directory's own manifest (expected files, sig table, validation
    recipe, "why no fixtures yet" note).
  - **Status:** GATED ON HARDWARE. R20 delivers the harness slot;
    the first physical capture happens alongside R21+ bring-up when
    the operator has serial + boot access on the T14 G4. Fixtures
    directory is empty-with-README at R20 close.
- **#824 R20 closure retrospective + quirks-db seed** — this document.
  Also seeds `design/hardware/quirks.md` with 15 `PROVISIONAL` rows
  anchored against public Intel + Lenovo PSREF data (§Quirks below).
  STATUS.md gets an R20 (and backfill R19) section.

---

## Cross-Repo Escalations to paideia-as

**None this round.** paideia-as remained pinned at `b0cb6f3` (the tip
that landed at R19 close, carrying the PE emitter #1292 + #1293 fixes)
for all of R20's five milestones. Every encoder-gap workaround R20
needed had already been documented (G1: `mov_d` for u32 stores; G4:
full-register compares) and was applied inline in the parser sites.

The `v0.21` paideia-as tag that R19 preflight scoped remains uncut;
`design/round-retrospectives/r19-preflight.md` documented the piecewise
delivery via 23 untagged commits. R20 did not add pressure to cut the
tag — the parsers landed comfortably against the existing encoder
surface.

Zero R20-round-time paideia-as issues filed. Continues the pattern
established late in R18 that stable paideia-as tips can carry
multi-round kernel work with no cross-repo churn.

---

## Deferrals

### #820 (acpi_supervisor userspace binary) → blocker #1015

The M4 landing commit filed **#1015** as the tracked blocker. #820's
own acceptance criteria (server binary, IPC endpoint registration,
initial-cap-transfer slot) require substrate that does not yet exist
in `src/user/`:

1. **Named-endpoint IPC.** Current IPC (`src/kernel/core/ipc/`) uses
   channel handles minted per-pair; the "service broker resolves
   `svc.acpi` → endpoint" pattern needs a rendezvous cap that no round
   before R20 has scoped.
2. **Variable-length IPC message support.** The `acpi_supervisor`
   RPC replies (`AcpiEnumRep` in particular) return up to 4 KiB of
   packed subrecord data; current IPC framing is fixed-length per
   channel. The wait-free dataflow slot infrastructure exists but the
   framing layer needs the length header (#821 §3 documents the
   design).
3. **Initial capability transfer slot in process creation.** The
   `KIND_ACPI` capability minted at boot must be planted in the
   supervisor process's CSpace before its first schedule; the CSpace
   population path is user-round work.
4. **Userspace-executable substrate.** `src/user/` currently hosts
   only the shell (`user/shell/`); a second server binary needs a
   linkable + startable pattern the shell does not exercise.

None of these are R20 debt — they were always scoped for the
userspace-server round. #1015 aggregates them.

**Scoping rationale:** filing a fresh blocker (vs. bundling into
existing user-round issues) preserves the R20 audit trail. When #1015
closes and #820 is picked up, the retrospective for that round will
cite this deferral cleanly.

### Other in-flight items (not fresh R20 debt, but touching R20 surface)

- **phase1_acpi_gather wiring into kernel_main_uefi.** The R20.M3
  handoff record is DEFINED and OBSERVABLE (nm shows it as a global
  symbol) but the `kernel_main_uefi` entry does not yet invoke
  `phase1_acpi_gather(env, &_phase1_acpi_info)`. Deferred to R21.M1 as
  a natural adjunct to the R21 IOAPIC + LAPIC-per-AP work — R21
  consumes `phase1_acpi_info.ioapic_count` and `.lapic_base_pa` right
  out of the gate, so wiring the gather call at R21 open is more
  cost-effective than a same-round retrofit.

---

## Quirks Discovered on Real Hardware

**None this round.** R20 ran entirely under QEMU + OVMF with the
synthetic fixture set (`tests/kernel/acpi/*_synth.pdx`). Real T14 G4
first-boot remains queued behind R19's ELF-loader completion.

`design/hardware/quirks.md` is nonetheless seeded at R20 close with
**15 PROVISIONAL rows** anchored against public sources (Intel Raptor
Lake datasheets + Lenovo PSREF + Intel PCH default reset control per
`0xCF9` + widespread Linux ACPI-dump patterns for Raptor Lake mobile).
Every row is marked `PROVISIONAL` and will be promoted to `CONFIRMED`
during R21+ first-boot on the physical unit. The T14 G4 anchor rows
include:

- **ACPI-FADT** reset via GAS at PCI I/O port 0xCF9, RESET_VALUE=0x06
  (typical for Lenovo Insyde on Raptor Lake).
- **ACPI-MADT** local_apic_address default 0xFEE00000; expect zero or
  one Type-5 overrides.
- **ACPI-MCFG** single PCIe segment (seg=0); ECAM base typically
  0xE0000000.
- **ACPI-HPET** counter_base 0xFED00000, block_id 0x8086A701, min_tick
  ~0x5DC.
- **AVX-512 disabled at core level** (E-core absence forces P-core
  disable per Intel BIOS default on Raptor Lake).
- **LAM unavailable** on Raptor Lake (Meteor Lake+ feature) — R35
  software-LAM fallback required for capability tagging on this
  target.
- **VMD-on default** — R19 recipe already documents the required
  BIOS-off flip.
- **No debug UART** on chassis — R28 framebuffer-photo fallback.

Full row set at `design/hardware/quirks.md` §2.

---

## Regression Envelope

- All R18/R19 fingerprints (`boot_r8_only`, `boot_r10`, `boot_r11`,
  `boot_r12`, `boot_r12_denial`, `boot_r14b_hivma`, `boot_r14b_kpti`,
  `boot_r14b_ipi`, `boot_r14b_loader`, `boot_r17_shell_echo_hello`,
  `boot_r17_shell_multi_command`, `boot_r17_shell_shutdown`,
  `boot_r17_shell_child_process`, `boot_smp`) — byte-identical across
  every R20 commit.
- R20 adds no new pre-push mode. The static-table parsers live inside
  `src/kernel/acpi/` and are exercised only via the synthetic fixture
  witnesses (GDB-invocable; no automatic runtime hook until
  `kernel_main_uefi` calls `phase1_acpi_gather` at R21 open).
- `tools/lint-no-kernel-aml.sh` joins as a pre-push gate (#822) —
  first gate to run, ~<1s. The 14-mode QEMU matrix + no-AML lint +
  opcode-canary = 16/16 gates.

---

## What Surprised

1. **paideia-as required no cross-repo work all round.** R18 fired
   four escalations; R19 fired several; R20 fired zero. Every parser
   R20 needed was expressible in the R19-close encoder surface, with
   the two documented workarounds (G1 mov_d, G4 full-reg compares)
   applied inline. Lesson: once the encoder stabilizes for a family
   of instruction shapes (in this case, structured mem loads +
   length-gated integer arithmetic), a full round of parser work fits
   comfortably.

2. **The FADT length-gate discipline was more nuanced than expected.**
   ACPI has three effective length regimes: 1.0 (116 B, legacy PM ports
   only), 2.0+ (~244 B with X_ forms + reset), 6.x (>= 276 B with
   hypervisor + AArch64 fields R20 does not consume). `fadt.pdx` had to
   thread length-gated dispatch three ways: legacy always-present,
   reset-region-present, X_-form-present. The synthetic fixture at
   `fadt_synth.pdx` fabricates a 244-byte "ACPI 2.0-clean" example that
   exercises the X_-form-preferred policy; a real T14 G4 FADT will
   likely be >= 276 B and exercise a longer dispatch path.

3. **The MADT hardcoded `_ap_apic_ids: [u8; 4]` stopgap that R18 left
   in place turned out to have a subtle contract: it filtered out the
   BSP APIC ID before R18 ever saw it.** R20.M2's
   `topology_seed_from_madt` had to re-derive that filter (via reading
   CPUID EAX=1 to get the BSP APIC ID, then skipping matching entries).
   This is a good example of "stopgap encapsulates a policy nobody
   documented"; #813's justification block calls it out.

4. **phase1_acpi_info's 512-byte size + 360-byte reserved tail was
   sized without empirical guidance.** The struct is aligned for
   cache-line-friendly access (fadt_info + hpet_info sharing a 96-byte
   prefix) and leaves generous room for R21+ fields. Whether 360 bytes
   is enough for PPTT + SRAT + IORT + TPM2 + PCCT + whatever else R21+
   consumes will surface at R21.M1. If not, the struct grows to 1024 B
   without an ABI break because it is not yet in a stable IPC contract.

5. **The no-AML lint was harder to specify than to implement.** #822's
   design doc took ~4x the time of the shell script it enforces. The
   forbidden-token set is small (aml/dsdt/ssdt/acpica/\_SB_) but the
   comment-stripping rule + word-boundary rule for LOOSE vs. TIGHT
   matchers + rationale for each choice ran to 200+ lines of design.
   The lint script itself is ~80 lines including the header. Lesson:
   architectural guardrails are cheap to enforce and expensive to
   justify; the justification is what makes the guardrail last.

---

## What Worked (Round Discipline)

1. **The softarch → debugger loop shape held throughout.** No mid-round
   pauses; each milestone's kickoff was an architect+implement pass
   producing all sub-issue landings + fixtures, followed by a debugger
   pass that debugged failures. Zero workerbee invocations (per
   `feedback_paideia_os_loop_shape.md`).

2. **Continuous-tempo across five milestones.** Per
   `feedback_paideia_os_tempo.md`, R20 ran continuous with no
   between-milestone review pause. All 5 milestones closed within a
   single loop day.

3. **The synthetic fixture pattern from R18.M5 (`tlb_shootdown_race`)
   generalized cleanly.** Each R20 parser got a paired
   `<parser>_synth.pdx` fabricating a byte-valid table via hand-computed
   checksums, then invoking the parser through a `pub` witness. The
   synthetic tables are GDB-invocable and provide a fingerprint-level
   assurance that the parser encoder-lowering is right, ahead of any
   runtime wire-up. When the T14 G4 fixture harness lands runtime
   drive, the synthetic-fixture-witness pattern is the direct precursor.

## What Didn't Work

1. **Kernel-side `phase1_acpi_gather` didn't get wired into
   `kernel_main_uefi` during R20.M3.** In hindsight this is fine (R21
   consumes it on the same commit that wires it) but at M3 close the
   choice-not-to-wire was a soft decision made under continuous-tempo
   pressure, not a plan. A more disciplined pass would have opened a
   micro-issue for the wiring at M4 kickoff instead of implicitly
   deferring to R21.

2. **#820's deferral cost more schema-doc rework than expected.** The
   IPC schema at #821 was written assuming the server would land in
   R20; deferring the server forced a §7 "wire code deferred" boilerplate
   into the schema doc that will need cleanup when #1015 closes. Not a
   large cost, but a signal that "design + code together" is the
   preferred grain when both are in flight.

---

## Preflight for R21

**R21 (FPU/XSAVE + IOAPIC + MSI/MSI-X + HPET timing + x2APIC)** —
opens after R20 close. Draft preflight to land as
`design/round-retrospectives/r21-preflight.md` at R21.M1 kickoff. R21
needs from R20:

1. **`phase1_acpi_info` consumers.** `.lapic_base_pa` +
   `.mcfg_seg0_base_pa` + `.ioapic_count` are consumed at R21.M1
   (IOAPIC bring-up needs the MCFG-adjacent GSI map; LAPIC-per-AP full
   config needs the LAPIC MMIO base).
2. **`madt_topology.pdx` outputs.** `_ap_apic_ids: [u32; N]` (already
   consumed by R18.M1's INIT-SIPI-SIPI machinery, R21 adds the
   x2APIC-MSR ICR write path for `apic_id >= 256`); `_madt_ioapics`
   (R21.M1 IOAPIC MMIO probing); `_madt_isos` (R21.M2 ISA-IRQ remap
   for legacy timer/keyboard fallback).
3. **`phase1_acpi_gather` wiring.** R21.M1's first commit lands the
   `phase1_acpi_gather(env, &_phase1_acpi_info)` call in
   `kernel_main_uefi` (deferred from R20.M3 per §"What Didn't Work" #1).
4. **`fadt_info.pm_tmr_port`.** R21.M3 timer-substrate work
   cross-checks TSC calibration against PM_TMR for a wall-clock seed
   before HPET / TSC-deadline is authoritative.
5. **`hpet_info.counter_base_pa` + `.min_tick`.** R21.M4 HPET timing
   consumes both for the first non-TSC wall-clock.

**R21 does NOT need from R20:**

- ACPICA. R21 remains AML-free (per the R20.M4 guardrail).
- The R20.M4 userspace boundary. `KIND_ACPI` capability minting +
  `acpi_supervisor` server + IPC endpoints all remain deferred to the
  userspace-server substrate round (#1015). R21 consumes
  `phase1_acpi_info` directly from the kernel side because there is
  still no userspace to broker through.
- The T14 G4 fixture. R21 can (and should) do its first-boot on the
  T14 G4 alongside R21.M5 or R21.M6, at which point the operator
  captures the ACPI tables + populates the fixture directory (per
  `tools/capture-t14-g4-acpi.md`), and the T14 G4 fixture witness gets
  enabled per its file header.

**R21 blockers (external):**

- paideia-as `v0.21` tag remains uncut; R21 does not need a tag bump.
  If paideia-as #1290 lands intra-R21, opportunistic bump.
- No R20 debt blocks R21.

---

## R20 Debt Carried Forward

Ledger of items deferred past R20 close:

1. **#820 acpi_supervisor server binary** — gated on **#1015**
   (userspace-server substrate). Target: user-substrate round (post-R21;
   likely R23 or R24).
2. **`phase1_acpi_gather` wiring into `kernel_main_uefi`** — R21.M1
   first commit.
3. **T14 G4 fixture activation** — enables when the operator captures
   real .bin files. Blocked on physical hardware access; can happen at
   any R21+ boundary independently of round tempo.
4. **`phase1_acpi_info` growth headroom** — if 360-byte reserved tail
   is insufficient for R21+ (PPTT + SRAT + IORT + TPM2 + PCCT), grow
   the struct without ABI break. Assess at R21.M1.
5. **Quirks-db PROVISIONAL rows promotion** — 15 rows at R20 close;
   each promotes to CONFIRMED at first-boot on the T14 G4.

None of these regress R20 acceptance.

---

## Milestone Discipline Statement

R20 held to the round-tempo user preference: continuous loop across
all issues + milestones with no mid-round pause. 5 milestones closed
in one loop day; 18 issues landed (17 implementation + 1 closure) with
1 tracked deferral (#820 → #1015).

The `softarch → debugger` loop shape held throughout with zero
workerbee invocations.

Cross-repo escalation to paideia-as fired **zero times** during R20 —
the substrate was ready for every parser R20 needed. `paideia-as`
submodule pin `b0cb6f3` unchanged from R19 close.

---

## Next Round

**R21 (FPU/XSAVE + IOAPIC + MSI/MSI-X + x2APIC + HPET timing).** See
`design/roadmap/r18-plus-bare-metal.md` §R21. Preflight document to
land at R21.M1 kickoff as
`design/round-retrospectives/r21-preflight.md`.

R21 blockers: none from R20. Ready to open.

---

**Closure.** R20 ACPI static-table foundation — closed 2026-08-10.
