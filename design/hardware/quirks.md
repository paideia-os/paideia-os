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
| ACPI-FADT / PMBASE | Intel Client PCH (Alder Lake / Raptor Lake) programs the ACPI PMBASE at `0x1800` (I/O), so PM_TMR lands at `0x1808` (PMBASE+0x08). Divergent from the QEMU PIIX4 default of PMBASE=`0x600` / PM_TMR=`0x608` — the divergence is why R21 timer bring-up resolves the port via FADT parse (`fadt.pdx` X_PM_TMR_BLK preferred-form path per #815) rather than a hard-coded constant. RTC CMOS index register at `0x70`/`0x71` is spec-standard on both PCH and QEMU-PIIX4. | R21+ timer/RTC substrate on physical HW must consume the FADT-derived port; a hard-coded 0x608 constant would silently talk to CMOS-adjacent unrelated I/O on the real PCH. | Handled at parser: `fadt.pdx` yields `pm_tmr_port` via GAS X_PM_TMR_BLK. Consumer wiring is R21+ timer bring-up; the constant `0x608` in `src/kernel/boot/kernel_main.pdx §PM_TMR-note` is the QEMU-PIIX4 baseline only and is not used by the FADT-aware path. | PROVISIONAL | — | Intel PCH datasheet §26 PMC (PMBASE offset defaults). QEMU PIIX4 default per `hw/isa/piix4.c`. Cross-reference `src/kernel/acpi/fadt.pdx` §fadt_parse. |

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
| VMD | Intel VMD Controller enabled by default; NVMe appears behind VMD as a `pci-domain`-style controller rather than bare PCIe. R22 PCI enumerator (bus-0 recursive descent) cannot see the drive as a first-class endpoint while VMD is on — VMD hides its children behind a proprietary indirection. | R24 NVMe bring-up cannot see the drive with VMD enabled unless a VMD driver exists (deferred R37+). R22 PCI enumerator sees a RAID/VMD container rather than the NVMe controller. **SEVERITY: LOAD-BEARING.** The BIOS toggle is the single blocker for the entire R24 NVMe substrate — without it `nvme_probe` records zero controllers, every downstream substrate step (identify / io_queues / dispatch / read_blocking) is unreachable, and the R24 HW smoke `nvme_hw_smoke_witness` (R24.M6 #908) takes the SKIP-on-no-controllers branch instantly. **MVP recipe is: BIOS Setup → Storage → Intel VMD Controller → Disabled before any R22 PCI enum / R23 driver-plane / R24 NVMe boot.** Full operator recipe with BIOS toggle path + GDB attach + witness-invocation ceremony at `tools/nvme-hw-smoke.md` §1.2.1 (R24.M6-001 #908). Verification: post-VMD-off `pci_enumerate_all(0)` records an NVMe controller at approximately `00:0E.0` instead of the VMD RAID container, and `nvme_probe` fingerprint reads `NVME PROBE N=1`. | PROVISIONAL | — | Lenovo Insyde BIOS default (T14 G4). `design/roadmap/r18-plus-bare-metal.md` §7 + `design/roadmap/r19-t14-g4-boot-guide.md` §3. Elevated in scope at R22.M6-001 (#870) to add the R22 PCI-enumerator impact + explicit BIOS toggle path + first-light verification recipe. Re-elevated at R24.M6-001 (#908) with a `SEVERITY: LOAD-BEARING` note + cross-reference to `tools/nvme-hw-smoke.md §1.2.1` (the operator recipe) + `tests/kernel/drivers/nvme/hw_smoke.pdx` (the witness that verifies the toggle worked). |
| USB | 2× TB4 + 2× USB-A + 1× USB-C 3.2; all under xHCI. | R26 xHCI driver targets single controller. | R26 substrate landed across M1–M6: probe (class 0x0C/0x03/0x30) + BIOS handoff (USBLEGSUP) + reset + cmd/event ring + MSI-X + doorbell + PORTSC + port reset + slot enable/address/disable + input context + DCBAAP + Configure Endpoint (EP1 IN Interrupt with HID boot defaults) + transfer ring + Control Transfers + `SET_PROTOCOL(0)` Boot Protocol + HID Usage -> ASCII keymap + report parser + HID -> TTY bridge + PSCE hotplug handler. Full driver-attach ceremony + IRQ walker over event ring deferred to R27. | PROVISIONAL | — | Lenovo PSREF; R26.M6 (#970) anchor. |
| USB-HID | Boot Protocol keyboard: EP1 IN Interrupt 8-byte reports; wValue=0 SET_PROTOCOL selects Boot mode; usage codes 0x04..0x38 map to standard US ASCII. | R26 assumes: (a) chassis keyboard enumerates cleanly under Boot Protocol; (b) 8-byte report format; (c) US layout; (d) modifier byte bits 1|5 = Shift. | R26.M6 (#965/#966/#967) landed the keymap + report parser + TTY bridge. Live capture from physical T14 chassis keyboard deferred to R27 driver-attach + IRQ walker. Promotion to CONFIRMED at T14 first-keystroke pass per `tools/xhci-keyboard-smoke.md §3`. | PROVISIONAL | — | USB HID 1.11 §B.1 Boot Keyboard; T14 G4 chassis keyboard enumerates under internal xHCI root complex per Lenovo PSREF. |
| USB-Topology | The T14 G4 internal keyboard sits behind a chassis-internal 4-port USB 2.0 hub that ACPI enumerates as a child device of the primary xHCI root complex (PCH ports mapped through the LPC/eSPI bridge). Boot Protocol keyboard enumerates cleanly through the hub — the R26.M5 SET_PROTOCOL(0) + report-parser wire is 4-port-hub transparent because xHCI addresses each device by slot ID after the hub-side reset. | R27+ driver-attach walker must not assume the chassis keyboard is a root-port device — it will report a non-zero `parent_hub_slot` and a `route_string` per xHCI 1.2 §4.5.1. R26.M6 code already carries the slot ID + address plumbing agnostic of hub topology. | Handled at protocol level (slot-ID + route-string are opaque to the Boot Protocol emit path). Verification queued at R27 driver-attach + T14 first-keystroke per `tools/xhci-keyboard-smoke.md §3`. | PROVISIONAL | — | USB 2.0 §11 hub class + xHCI 1.2 §4.5.1 route strings; T14 G4 chassis USB topology per Lenovo PSREF (four USB-A + four USB-C + one internal keyboard/trackpoint hub). Cross-reference R26.M6 (#970). |
| Ethernet | Intel i219-LM PHY (on-board, PCH-integrated). | R27 e1000e-family driver. | Handled: R27.M1-M6 (#971-#997) landed probe + RX/TX rings + MSI-X + ARP + IPv4 + ICMP echo reply + UDP port-7. Live-wire on T14 G4 physical NIC deferred to R28.M2 HW smoke (`tools/run-smoke-hw.sh net` per #1002). | PROVISIONAL | — | Lenovo PSREF; Intel Ethernet Controller I219 datasheet. |
| Ethernet-PHY | Intel PCH i219 MDIC (MDIO/MDC Control) register access to the on-board PHY has a Intel-PCH-documented ~500 us settle window after each register write. The e1000e Linux driver and Intel FreeBSD driver both poll MDIC.READY (bit 28) with an upper bound of 640 iterations spaced at ~1 us — a naive "write and read back immediately" pattern loses the response and returns the previous register's value. | R27 e1000e PHY init on physical T14 G4 must poll MDIC.READY after each `E1000_MDIC` write; the initial R27.M1 substrate landed the ready-bit polling loop but the timing was calibrated against QEMU-e1000e which returns READY on the first re-read. Real HW will need the full 640-iteration polling loop to settle. | To be programmed at first-light: bump the MDIC ready-poll loop bound in `src/kernel/core/drivers/nic/i219_phy.pdx` (or file if divergence from QEMU manifests during `PAIDEIA_HW_SMOKE=1 tools/run-smoke-hw.sh net` per #1002). | PROVISIONAL | — | Intel Ethernet Controller I219 datasheet §7.4.2 (MDIC register); Intel PCH-H/PCH-P Datasheet Volume 2 §33 (LAN Connect / MDIO timing). Cross-reference Linux `drivers/net/ethernet/intel/e1000e/phy.c e1000e_read_phy_reg_mdic`. |
| Wi-Fi / Bluetooth | Intel AX211 (Wi-Fi 6E + BT 5.2) integrated CNVi. | Deferred to R41+ per §0 constitutional decision. | Not on critical line. | PROVISIONAL | — | Lenovo PSREF. |

### 2.5 Debug + observability

| Subsystem | Quirk | Impact | Handling | Status | Round observed | Source |
|-----------|-------|--------|----------|--------|----------------|--------|
| UART | No debug UART on the chassis; Intel DCI over USB-C possible with a debug dongle. | R21+ panic-log path cannot rely on serial output on physical HW; must fall back to framebuffer-photo. | R23.M3 (#884) landed: `klog_panic` step 3.7 emits a bold-red `*** PANIC ***` banner via `fb_console_puts`, then `klog_ring_dump_panic`'s busy loop mirrors every ring byte to `fb_console_putchar`. Photograph-recoverable per the R23 closure retro § "Real-Hardware Verification Procedure" — a phone photo of a frozen T14 G4 screen captures banner + full ring dump. Acceptance recipe now formalized at `design/testing/panic-fb-photograph-recovery.md` (R28.M3 #1005) with operator quick-reference at `tools/panic-fb-recovery-smoke.md`. Row promotes `PROVISIONAL → WORKED-AROUND` at T14 first-visual-output execution of §4 in the recipe; formerly documented `design/roadmap/r18-plus-bare-metal.md` §7 R28 fallback. | PROVISIONAL | — | Modern ThinkPad chassis inventory. |

### 2.6 Display + framebuffer

| Subsystem | Quirk | Impact | Handling | Status | Round observed | Source |
|-----------|-------|--------|----------|--------|----------------|--------|
| GOP-Pixel-Format | Intel Iris Xe integrated graphics on the T14 G4 exposes the UEFI Graphics Output Protocol with `PixelFormat = PixelBlueGreenRedReserved8BitPerColor` (EFI_PIXEL_BGR_8888 = 1), 32 bpp, natively BGR-in-memory-byte-order (`0x00_RR_GG_BB` when written as a little-endian u32). This matches the QEMU stdvga default, so R23's `fb_glyph.pdx` + `fb_console.pdx` code paths (which hard-assume BGR_8888) transfer directly from QEMU-OVMF to real HW without a per-pixel channel swap. Panel native resolution is 1920x1080 (native eDP); post-GOP the LFB pitch is expected to equal `width * 4` bytes (no scanline padding — Iris Xe honors GOP's `PixelsPerScanLine == HorizontalResolution` on the eDP output). | R23.M2 rasterizer would render inverted colours (blue-red swapped) if the GOP handoff surfaced RGB_8888 instead of BGR_8888. Similarly, a `pitch > width * 4` (scanline padding) would tile the console at the wrong stride and shred every glyph. Both cases would show at the T14 first-panel-output moment; neither is expected but both need first-light confirmation. | Handled at fingerprint level: `fb_console_init` reads `_boot_env.fb_pixel_format`, `.fb_pitch`, `.fb_width`, `.fb_height` and could refuse to init on a non-BGR_8888 handoff. Currently the code path assumes BGR_8888 unconditionally per the QEMU-OVMF baseline. Promotion to CONFIRMED at T14 first-panel-output (see `design/testing/panic-fb-photograph-recovery.md §4`); on RGB_8888 detection, an R28.M4+ per-pixel channel-swap fast-path lands. | PROVISIONAL | — | UEFI 2.10 §12.9 (GOP protocol, PixelFormat enum); Intel Iris Xe Graphics Reference Vol 4 §3 Display. R23.M2 code path anchor: `src/kernel/core/drivers/fb_glyph.pdx` justification note (BGR_8888 assumption). #793 GOP spec cross-reference. |

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

*Updated 2026-08-11 at R24.M6 close (#908, #910) — §2.4 VMD row
enriched with a `SEVERITY: LOAD-BEARING` note that flags the BIOS
toggle as the single blocker for the entire R24 NVMe substrate,
plus cross-references to `tools/nvme-hw-smoke.md §1.2.1` (the
operator recipe) + `tests/kernel/drivers/nvme/hw_smoke.pdx` (the
witness `nvme_hw_smoke_witness` that verifies the toggle worked).
The row stays `PROVISIONAL` — promotion to `CONFIRMED` happens at
the R24 HW smoke live run on the T14 G4 per
`tools/nvme-hw-smoke.md` §3. No new rows added at this pass; R24
ran entirely under `qemu -kernel` (no MCFG surface → PCI enumerator
drains empty → nvme_probe returns 0 → every downstream NVMe
substrate step takes the SKIP branch). See
`design/round-retrospectives/r24-closure.md` § "Real-Hardware
Verification Procedure" for the summary.*

*Updated 2026-08-11 at R28.M3 close (#1005, #1006, #1007) — four
new rows appended reflecting substrate landings from R23-R27:*

- *§2.1 — ACPI-FADT / PMBASE row: Intel Client PCH ships PMBASE at
  I/O `0x1800` (PM_TMR at `0x1808`), divergent from QEMU-PIIX4
  default `0x600`. Motivates the FADT-parse-not-hard-code posture
  from #815.*
- *§2.4 — USB-Topology row: the T14 G4 chassis keyboard sits behind
  a 4-port hub as an xHCI descendant; slot-ID + route-string
  plumbing per xHCI 1.2 §4.5.1 lands agnostic of the hub.*
- *§2.4 — Ethernet-PHY row: i219 MDIC access has an Intel-PCH-
  documented ~500 us settle window; R27.M1 substrate's ready-poll
  loop may need bound-bump on real HW.*
- *§2.5 — UART row Handling column cross-references the new formal
  acceptance recipe at `design/testing/panic-fb-photograph-
  recovery.md` + `tools/panic-fb-recovery-smoke.md` (both #1005).*
- *§2.6 — new subsection: Display + framebuffer. GOP-Pixel-Format
  row asserts BGR_8888 32bpp @ 1920x1080 native eDP for Iris Xe on
  T14 G4. If GOP surfaces RGB_8888 instead at first-light, R28.M4+
  swap fast-path required.*

*No rows promoted at this pass; R28.M3 ran entirely under `qemu
-kernel` + documentation. Promotions queued for the T14 G4 first-
panel-output moment (see `design/testing/hw-regression-matrix.md`
§6 T14 G4 column TODO cells).*
