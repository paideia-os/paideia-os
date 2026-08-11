# PaideiaOS — Hardware Quirks Database

**Status:** Seed v0.1
**Opened:** 2026-08-10 (R20 close, issue #824)
**Provenance:** anchor rows from `design/roadmap/r18-plus-bare-metal.md` §7 (public Lenovo PSREF for T14 G4 Intel + Intel SDM defaults); **not yet confirmed against physical hardware.**

---

## 0. Purpose

Record per-machine deviations from spec-nominal behavior that the
kernel and drivers must accommodate. This is the counterpart to
`design/acpi/vendor-quirks.md` (which scopes the ACPICA userspace
bubble's vendor-quirk corpus for firmware AML); this file scopes
**kernel-observable** quirks that are handled without ACPICA — static
ACPI table oddities, CPU errata, chipset behavior, timer / interrupt
delivery quirks, MMIO addressing surprises.

Rows are added when discovered on real hardware. Any row landed
before a physical bring-up on the target unit is marked
`PROVISIONAL` and carries the source citation used to anchor it. The
row is promoted to `CONFIRMED` on the round-closure PR that first
observes the behavior on the actual hardware.

---

## 1. Row schema

Each machine gets a section. Within the section, one row per quirk
using the following columns:

| Column           | Meaning |
|------------------|---------|
| Subsystem        | Kernel area affected (ACPI, LAPIC, HPET, PCIe, USB, ...). |
| Quirk            | One-line summary of the deviation. |
| Impact           | What breaks (or degrades) if the quirk is not handled. |
| Handling         | Code / config that accommodates the quirk. `NONE` if the quirk is documented but not yet worked around. |
| Status           | `PROVISIONAL` (anchor from public spec, not yet observed) / `CONFIRMED` (observed on the physical unit) / `WORKED-AROUND` (handling code has landed and been validated). |
| Round observed   | Round-milestone where the quirk was first hit. `—` for provisional rows. |
| Source           | Data-sheet page, forum thread, git commit, or "first-boot on unit S/N XXXX" for confirmed rows. |

---

## 2. Thinkpad T14 Gen 4 (Intel Raptor Lake — MVP target)

Provenance: public Lenovo PSREF for T14 G4 Intel (2023 release) +
Intel Raptor Lake datasheets + generic ACPI 6.5 default behavior. All
rows below are `PROVISIONAL` until first-light captures the actual
firmware behavior. First-light is queued for R21+ post the R19 stub
landing an ELF loader.

### 2.1 ACPI static tables

| Subsystem | Quirk | Impact | Handling | Status | Round observed | Source |
|-----------|-------|--------|----------|--------|----------------|--------|
| ACPI-FADT | Reset via GAS at PCI I/O port 0xCF9; `RESET_VALUE = 0x06` (full-reset bit + system-reset bit). | R21 shutdown path must fall back to 0xCF9 write if FADT `RESET_REG` is absent or invalid. | `src/kernel/acpi/fadt.pdx` §fadt_parse resolves `reset_port` from GAS; a 0-reset_port already triggers the 0xCF9 fallback comment (#815 justification). Reset value 0x06 vs 0x02 (soft-reset-only) will be captured. | PROVISIONAL | — | Intel PCH datasheet §5.10 default reset control; typical for Lenovo Insyde BIOS on Raptor Lake. |
| ACPI-MADT | `local_apic_address` typically 0xFEE00000 (default); expect zero or one Type-5 LAPIC-address-override entries. | If Type-5 overrides to a non-default MMIO base, R18 `_ap_apic_ids` and R20 `phase1_acpi_info.lapic_base_pa` must consume the overridden value (already handled by `madt.pdx`). | Handled: `madt.pdx` walks Type-5 overrides per ACPI 6.5 §5.2.12.8. | PROVISIONAL | — | ACPI 6.5 §5.2.12.8; T14 G4 first-light will confirm whether a Type-5 override is emitted. |
| ACPI-MADT | Raptor Lake U/P has P-cores + E-cores; expect Type-9 x2APIC entries (32-bit APIC ID) rather than Type-0 LAPIC entries for at least the E-cores at high APIC-ID values (>= 256). | R18 hard-coded `_ap_apic_ids: [u8; 4]` (8-bit) was the R18 stopgap; R20.M2 (#813) already replaced it with u32 from `madt_parse_x2apics`. | Handled: `core/smp/madt_topology.pdx` iterates Type-9 alongside Type-0. | PROVISIONAL | — | Intel Raptor Lake §3.1 topology. |
| ACPI-MCFG | Single PCIe segment (seg=0); ECAM base typically `0xE0000000` on Intel Client PCH. | R21+ PCIe enumeration must consume `phase1_acpi_info.mcfg_seg0_base_pa`. Multi-segment code paths are latent (`_mcfg_segments[16]` slot). | Handled: `mcfg.pdx` extracts seg 0 + up to 16 segments; consumer wiring pending R21+ PCIe bring-up. | PROVISIONAL | — | Intel Raptor Lake §4 PCH ECAM. |
| ACPI-HPET | Counter block base typically `0xFED00000`; block_id 0x8086A701 (Intel HPET revision) is the widespread pattern; min_tick around 0x5DC (14318180 femtoseconds ≈ 14.3 ns period, matching the 69.841 MHz reference). | R21 timer-substrate work consumes HPET as an early wall-clock. Actual `min_tick` may differ; parser is length-agnostic. | Handled: `hpet.pdx` returns `counter_base_pa`, `block_id`, `min_tick` via `hpet_info`. | PROVISIONAL | — | Intel HPET spec + widespread Raptor Lake T14/T15/T16 dumps in Linux ARB. |
| ACPI-FADT | `PM_TMR_BLK` typically at I/O port `0x1808`, 32-bit counter (TMR_VAL_EXT=1 in FADT flags on Raptor Lake). | R21 timer calibration cross-checks PM_TMR against TSC; a 24-bit-only wrap would need a shorter calibration window. | Handled: parser resolves `pm_tmr_port` via X_PM_TMR_BLK preferred-form path (#815); consumer TBD. | PROVISIONAL | — | Intel PCH datasheet §26 PMC. |

### 2.2 Interrupts and topology

| Subsystem | Quirk | Impact | Handling | Status | Round observed | Source |
|-----------|-------|--------|----------|--------|----------------|--------|
| IOAPIC | Typically 2 IOAPICs on Raptor Lake mobile (one per PCH IOH-adjacent block); MCFG-seg-0-adjacent GSI ranges. | R21 IOAPIC bring-up must handle N >= 2 IOAPICs; already accommodated by R20.M2's Type-1 entry walker. | Handled: `madt.pdx` walks all Type-1 entries into `_madt_ioapics`. | PROVISIONAL | — | Intel PCH datasheet §11. |
| APIC | Hybrid P/E-core topology — CPUID leaf 0x1A returns `HYBRID_P` for P-cores, `HYBRID_E` for E-cores, `HYBRID_LP_E` never used on T14 G4 (LP-E cores are Meteor Lake+). | R18.M6-001 (#779) already emits per-AP hybrid tag; R23+ scheduler policy will consume it. | Handled at fingerprint level; scheduler consumer deferred. | PROVISIONAL | — | Intel Raptor Lake datasheet §3.2. |

### 2.3 CPU + memory

| Subsystem | Quirk | Impact | Handling | Status | Round observed | Source |
|-----------|-------|--------|----------|--------|----------------|--------|
| CPU-features | AVX-512 disabled at core level on all consumer Raptor Lake (E-core absence of AVX-512 forces disable on P-cores too, per Intel BIOS default). | R21 XSAVE state size sizing must handle AVX-2-max, not AVX-512-max. Simpler bring-up. | To be programmed: R21.M1 XSAVE support-mask reads CPUID 0xD.EAX; will naturally exclude AVX-512 slots. | PROVISIONAL | — | Intel Raptor Lake spec update; well-known post-2022. |
| NUMA | Single NUMA node; SRAT will report one proximity domain covering all cores + all RAM. | R25+ NUMA-aware allocator is trivial; no interleave. | To be programmed when SRAT parser lands (R21+ or R25). | PROVISIONAL | — | LPDDR5 soldered single-package. |
| LAM | Meteor Lake+ feature; T14 G4 (Raptor Lake) does NOT support LAM. Software-LAM fallback per `design/capabilities/linearity-and-tags.md` required. | R35+ software-LAM lands to accommodate; MVP capability tagging on T14 G4 will use software emulation. | To be programmed. | PROVISIONAL | — | Intel ISA extensions reference. |

### 2.4 Storage + peripherals

| Subsystem | Quirk | Impact | Handling | Status | Round observed | Source |
|-----------|-------|--------|----------|--------|----------------|--------|
| VMD | Intel VMD Controller enabled by default; NVMe appears behind VMD as a `pci-domain`-style controller rather than bare PCIe. R22 PCI enumerator (bus-0 recursive descent) cannot see the drive as a first-class endpoint while VMD is on — VMD hides its children behind a proprietary indirection. | R24 NVMe bring-up cannot see the drive with VMD enabled unless a VMD driver exists (deferred R37+). R22 PCI enumerator sees a RAID/VMD container rather than the NVMe controller. **MVP recipe is: BIOS Setup → Storage → Intel VMD Controller → Disabled before any R22 PCI enum / R23 driver-plane / R24 NVMe boot.** Verification: post-VMD-off `pci_enumerate_all(0)` records an NVMe controller at approximately `00:0E.0` instead of the VMD RAID container. | PROVISIONAL | — | Lenovo Insyde BIOS default (T14 G4). `design/roadmap/r18-plus-bare-metal.md` §7 + `design/roadmap/r19-t14-g4-boot-guide.md` §3. Elevated in scope at R22.M6-001 (#870) to add the R22 PCI-enumerator impact + explicit BIOS toggle path + first-light verification recipe. |
| USB | 2× TB4 + 2× USB-A + 1× USB-C 3.2; all under xHCI. | R26 xHCI driver targets single controller. | To be programmed. | PROVISIONAL | — | Lenovo PSREF. |
| Ethernet | Intel i219-LM PHY (on-board, PCH-integrated). | R27 e1000e-family driver. | To be programmed. | PROVISIONAL | — | Lenovo PSREF. |
| Wi-Fi / Bluetooth | Intel AX211 (Wi-Fi 6E + BT 5.2) integrated CNVi. | Deferred to R41+ per §0 constitutional decision. | Not on critical line. | PROVISIONAL | — | Lenovo PSREF. |

### 2.5 Debug + observability

| Subsystem | Quirk | Impact | Handling | Status | Round observed | Source |
|-----------|-------|--------|----------|--------|----------------|--------|
| UART | No debug UART on the chassis; Intel DCI over USB-C possible with a debug dongle. | R21+ panic-log path cannot rely on serial output on physical HW; must fall back to framebuffer-photo. | R23.M3 (#884) landed: `klog_panic` step 3.7 emits a bold-red `*** PANIC ***` banner via `fb_console_puts`, then `klog_ring_dump_panic`'s busy loop mirrors every ring byte to `fb_console_putchar`. Photograph-recoverable per the R23 closure retro § "Real-Hardware Verification Procedure" — a phone photo of a frozen T14 G4 screen captures banner + full ring dump. Row promotes `PROVISIONAL → WORKED-AROUND` at T14 first-visual-output; formerly documented `design/roadmap/r18-plus-bare-metal.md` §7 R28 fallback. | PROVISIONAL | — | Modern ThinkPad chassis inventory. |

---

## 3. Adding a new machine

When a new physical target enters the mix (e.g. a framework 13, a
generic i7 desktop, an Ampere Altra board):

1. Add a `## N. <Machine name>` section under §2.
2. Populate `PROVISIONAL` rows from public sources (data sheet,
   Lenovo/Dell/HP PSREF equivalent, Intel/AMD spec update).
3. On first-boot, replace `PROVISIONAL` with `CONFIRMED` for each
   observation and cite the round-milestone + git commit.
4. When kernel code lands to work around the quirk, replace
   `CONFIRMED` with `WORKED-AROUND` and cite the fix commit.

---

## 4. Related documents

- `design/acpi/vendor-quirks.md` — vendor-quirk corpus for the R34
  ACPICA userspace bubble (AML-side quirks).
- `design/roadmap/r18-plus-bare-metal.md` §7 — anchor T14 G4 hardware
  inventory + BIOS setup.
- `design/roadmap/r19-t14-g4-boot-guide.md` — operator guide for the
  R19 first-light attempt.
- `tools/capture-t14-g4-acpi.md` — how to capture the raw ACPI tables
  this document's rows anchor against.
- `tests/kernel/acpi/fixtures/t14g4/README.md` — where the captured
  .bin files land.
- `tools/capture-t14-g4-pci.md` — how to capture the PCI device tree
  this document's PCI-plane rows anchor against (added at R22.M6-002
  #871).
- `tests/kernel/pci/fixtures/t14g4/README.md` — where the captured
  PCI config-space blobs land (added at R22.M6-002 #871).

---

*Seeded 2026-08-10 at R20 close. Rows will move `PROVISIONAL` →
`CONFIRMED` as physical bring-up happens.*

*Updated 2026-08-11 at R22.M6 close (#870, #874) — VMD row §2.4
expanded with the R22-PCI-enumerator impact + explicit BIOS toggle
+ first-light verification recipe. No rows promoted to CONFIRMED at
this pass; R22 ran entirely under QEMU-TCG (no VT-d emulation, no
hybrid P/E topology, no x2APIC). Promotion pass queued for the T14
G4 first-light in R23+.*

*Updated 2026-08-11 at R23.M3 close (#884, #885) — §2.5 UART row
"Handling" column now points at the R23.M3 fb-panic path
(`k_panic_fb_banner` + `klog_ring_dump_panic` fb mirror). The row
stays `PROVISIONAL` until first-visual-output confirms the banner +
ring dump render legibly on the T14 G4 eDP panel; on that day the
row promotes to `WORKED-AROUND`. See
`design/round-retrospectives/r23-closure.md` §
"Real-Hardware Verification Procedure" for the acceptance recipe. No
new rows added at this pass; R23 ran entirely under `qemu -kernel`
(no UEFI/OVMF harness yet — fb subsystem is dormant on that boot
path by design).*
