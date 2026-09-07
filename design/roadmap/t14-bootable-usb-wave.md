# R111 / R112 — T14 G4 Bootable USB Wave

**Status:** Proposal — osarch voice; pairs with an R112 softarch companion plan (not yet written; §10).
**Date:** 2026-09-07.
**Anchor issue (proposed):** paideia-os R111.M0 "T14 G4 bootable USB image — one `dd`, one boot, one `$` prompt".
**Round numbering:** R111 (osarch, odd) + R112 (softarch, even) per [[feedback-osarch-softarch-numbering]]. Grep-verified against `design/**/r1*-plan.md`, `design/round-retrospectives/`, and `MASTER_PLAN.md` (2026-09-07): R100/R101/R102 taken by the network-tools + graphics waves; R103-R105 taken by the R101 graphics split; R106-R109 taken by the persistent-home wave; R110 taken by the libpdx-semantic-pipe 2.0 XREPO cascade. R111 and R112 are the next free odd/even pair.
**Companion / supersedes:**
- `design/roadmap/r19-t14-g4-boot-guide.md` (R19.M5 UEFI stub first-light — predecessor; produces `paideia boot: entry ok` only).
- `design/hardware/t14-g4-first-boot.md` (R28.M2 MVP boot recipe — landed 2026-08-11 but reaches only the "UEFI kernel_main entered" banner because `kernel_main_uefi` never chains into `kernel_main_64`; §3 quantifies the gap).
- `design/roadmap/post-r60-daily-use-roadmap.md` §R67 — subsumed by this wave (R67 was 8-issue; this wave is the integrated 25-issue replacement).
- `design/roadmap/r18-plus-bare-metal.md` §7 — T14 G4 hardware inventory carried forward here.

**This document files no GitHub issues.** Main creates the umbrella + sub-issues after user approval, per [[feedback-aissue-command]] and [[feedback-paideia-os-loop-shape]].

---

## 0. What "shipped" means for this wave

The termination condition for R111 is a **single artifact + a single operator gesture**:

- **Artifact:** `build/mvp/paideia-t14.img` — a raw dd-able image, ~96-128 MiB, produced by `bash tools/mkimage.sh` (this wave folds `build-image.sh` + firmware bundling + GPT variant into one command).
- **Gesture:** `sudo dd if=build/mvp/paideia-t14.img of=/dev/sdX bs=4M conv=fsync; sync` → insert USB stick into T14 G4 → cold-power the T14 → tap F12 (or leave BIOS boot-order pre-set) → **unattended** boot to a `$` shell prompt, visible on either (a) attached USB-serial dongle at 115200 8N1 or (b) the T14's eDP internal display via GOP LFB console (dual-sink; whichever the operator has attached at cold-power).

"Unattended" is load-bearing: no operator input between power-on and prompt. No paideia-as rebuild on the target. No physical reset half-way. No debug tooling required.

Input at the `$` prompt is via **USB-A external keyboard** (attached to any T14 USB-A port; the built-in laptop keyboard is I²C-HID and stays gated on ACPICA per §7). If no external keyboard is attached, serial-console input over the USB-serial dongle is the operator's tty.

Storage for the rootfs is **PdxFS-lite blob embedded in the ESP** (as the R28.M2 recipe does today). Booting from the T14's internal NVMe is explicitly a **second termination condition** (§4.C, R111.M3-011) — mounting `/home` from internal NVMe is exercised in the same wave, but the boot chain does not require it. This preserves the "one dd, one boot" property even for a T14 whose internal SSD is encrypted with a Windows BitLocker volume the operator does not want touched.

---

## 1. Executive summary

R111 is a **consolidation wave, not a greenfield wave** (posture inherited from `design/graphics/r101-kernel-plan.md §0`). Every subsystem needed to reach the `$` prompt on real T14 G4 hardware exists in the tree today — SMP substrate (R18), ACPI static tables (R20), FPU/XSAVE (R21), PCIe ECAM + VT-d (R22), framebuffer console (R23), NVMe (R24/R51), PdxFS-lite (R25/R107), xHCI + HID (R26/R30), i219-LM ethernet (R27), image builder (R28), UEFI stub (R19), and the R107 file-bdev mount. The problem is not "missing drivers"; it is **integration and real-hardware exercise**.

Three specific integration gaps dominate the wave:

1. **`kernel_main_uefi` is a stub.** It prints "UEFI kernel_main entered", verifies the `.pdxsgn` section, seeds the phys bitmap, and halts. It never chains into `kernel_main_64` — the orchestrator that does IDT install, TSS, SMEP/SMAP/NX, APIC, LAPIC timer, scheduler bring-up, PCI enumeration, NVMe attach, xHCI attach, VFS mount, and INIT spawn. The R28.M2 recipe's "$ prompt" acceptance criterion was aspirational — end-to-end never worked on real hardware. **R111.M1-002 is the load-bearing bridge issue.**
2. **Every driver's "real-HW probe path" is untested.** The R24 NVMe driver was written against QEMU's ideal controller; the R26 xHCI driver was written against `qemu-xhci`; the R22 PCIe ECAM walker was tested against Q35's synthetic topology. Insyde firmware, Raptor Lake PCH device IDs, Samsung/WD/SK Hynix NVMe controller quirks, and the T14 G4's specific IOAPIC → GSI routing table are all unexercised. **Sub-wave B (R111.M2) is where the wave earns its keep.**
3. **The image builder does not bundle firmware blobs.** T14 G4 Intel needs at boot: Intel microcode update matching CPUID `0x0A06A4` (Raptor Lake-U B0 stepping) or its refresh, GuC firmware for Iris Xe Gen12.2 (`i915/tgl_guc_70.bin` naming; substitute the paideia-native path), HuC firmware likewise. Without microcode the CPU runs a stale erratum profile; without GuC the R77 modeset round has no runway. **Sub-wave F (R111.M6) lands the loader and the ESP layout convention; the R77 wave will actually wire GuC to submit rings.**

The wave is 25 sub-issues across 7 sub-waves + 1 umbrella issue, sized L (large but bounded — see §5). The critical path is A → B → C ∥ D → E → G (§6); F is parallel-safe against A/B/C/D/E and gates only on G's ESP layout. Estimated at ~10-14 dev-weeks at current continuous-loop tempo, contingent on physical T14 G4 access for hardware-in-loop smoke (§7 risk R4).

---

## 2. T14 variant + firmware audit

### 2.1 Variant decision — T14 G4 Intel Raptor Lake

Prompt permits AMD variant; osarch selects **T14 G4 Intel (Raptor Lake-U, i5-1335U or i7-1365U class)**. Justification (in load-bearing order):

1. **The entire baseline driver corpus is Intel-shaped.** `src/kernel/core/drivers/e1000e/` is Intel i219-LM. `src/kernel/core/drivers/wifi/` includes R38.M1 AX211 (Intel CNVi). `src/kernel/core/drivers/gpu/` and `src/kernel/core/drivers/dpy/` are Iris Xe / Gen12.2 targeted (GuC/HuC firmware bundling, DP-alt link training over TB4). `src/kernel/iommu/` (if present) is VT-d, not AMD-Vi.
2. **The R18+ roadmap §0.1 locked Intel as constitutional.** Overriding that decision is a memo, not a wave.
3. **AMD variant would add ~10 rounds of driver rewrite:** PSP firmware bring-up, AMD-Vi IOMMU driver, MEC-based Radeon graphics KMD (not GuC/HuC), AMD PSPTF Trust Firmware, different SATA/NVMe/xHCI PCI IDs, different EC (T14 G4 AMD uses a different Insyde firmware SKU), different Wi-Fi (Qualcomm/MediaTek where SKU'd).
4. **hwman coverage.** Available paideia-os hwman references are Intel-oriented per the R18+ inventory. Switching to AMD would trigger a new hwman round for AMD PSP + AMD-Vi + Zen4 CPUID topology.

Downside accepted: T14 G4 AMD operators cannot boot R111's image. They wait for a future R-round that lifts the driver corpus to AMD; that round is out of scope here.

### 2.2 Firmware / device-ID inventory (T14 G4 Intel Raptor Lake)

Every ID below is **provisional** until confirmed via `tools/capture-t14-g4-pci.md` and `tools/capture-t14-g4-acpi.md` on a physical unit — R111.M2-006 runs those captures against the target SKU and seeds `design/hardware/t14-g4-device-ids.md` (new file). The kernel probe tables consume that file so any SKU-specific drift lands in one place.

| Function              | Vendor:Device (typical)    | Class code       | Driver / substrate today                | Real-HW exercise gap                                          |
|-----------------------|----------------------------|------------------|-----------------------------------------|---------------------------------------------------------------|
| CPU                   | Intel Raptor Lake-U (CPUID 06_BAh, stepping 0-3) | — | R18 SMP substrate; R21 XSAVE/x2APIC     | Microcode update path (§4.F); HWP feedback loop (deferred to R31 EC) |
| PCH                   | Intel Raptor Point-U (integrated in SoC) | — | R22 ECAM base from MCFG                 | Insyde firmware quirks (partial BAR sizing, ext-cap edge cases)      |
| iGPU (Iris Xe Gen12.2) | 8086:A7A0..A7AF (SKU-dependent) | 03/00/00        | `drivers/gpu/`, `drivers/dpy/` (Iris Xe engine + topology + modeset + planes); `drivers/gfx/` today only has `bochs_stdvga` + `virtio_gpu` (QEMU-only) | GOP LFB direct scanout is R111.M4 scope; native KMS scanout deferred to R77 |
| xHCI (USB 3.2)        | 8086:51ED (Raptor Point-U USB) | 0c/03/30        | `drivers/xhci/` complete (probe, cmd/event rings, HID) | BIOS→OS handoff via USBLEGSUP under Insyde (§4.E)                    |
| NVMe                  | Samsung PM9A1 144d:a80a / WD SN740 15b7:5017 / SK Hynix PC901 1c5c:1a59 | 01/08/02 | `drivers/nvme/` complete (probe, identify, io_queue, prp, dma, irq, mdts) | Real MDTS clamp, vendor Identify quirks (§4.C)                       |
| Ethernet (i219-LM)    | 8086:1A1F (Raptor Lake i219-LM v13/v18/v19) | 02/00/00 | `drivers/e1000e/` (R27)                | Not boot-critical; keep on for post-boot ping smoke only              |
| Wi-Fi (AX211 CNVi)    | 8086:51F0                   | 02/80/00        | R38.M1 PCI probe + firmware load; no upper stack | **Explicitly out of scope** (§8)                                     |
| Bluetooth (via CNVi)  | shared radio with AX211     | 0d/11/01        | `drivers/bt/` scaffold                  | **Out of scope** (§8)                                                |
| Audio (HDA + ALC287)  | 8086:51CA (Raptor Point-U cAVS) | 04/03/00        | `drivers/hda/` scaffold, `drivers/audio/` | **Out of scope** (§8)                                                |
| Camera (IPU6)         | 8086:465D                   | 04/80/00        | `drivers/cam/` scaffold                 | **Out of scope** (§8)                                                |
| TB4 controller (on-die) | 8086:1137 or 8086:1138 (SKU-dependent) | 08/80/00 | `drivers/tb/` (NHI + tunnels + DMA attestation + CM) | Static topology only for R111 (no hot-plug UX); DP-alt tunnel out of scope (§8) |
| dTPM 2.0 or fTPM/PTT  | Infineon SLB9670 / Intel PTT | — (via ACPI TPM2) | R19.M3 `EFI_TCG2_PROTOCOL` PCR-extend  | Not boot-critical; log-only through this wave                        |
| Embedded Controller   | Lenovo Insyde EC behind ACPI EC + PECI | — (via ACPI) | `drivers/ec/` scaffold                 | Requires ACPICA — battery/thermal deferred to R29/R78 (§8)          |
| Keyboard (internal)   | I²C-HID (touch controller-shaped) | 0c/05/00 (via LPSS I²C) | `drivers/i2c_hid/` files landed but not wired | **Requires ACPICA (R29 / R78) — deferred (§8, cite R33 in next-wave-osarch)** |
| Trackpad (Synaptics)  | I²C-HID                     | 0c/05/00        | Same as above                           | **Out of scope** (§8)                                                |
| Fingerprint reader    | Goodix / Synaptics USB      | 0c/03/00 (HID)  | `drivers/hid/`                          | **Out of scope** (§8)                                                |

**ACPI capture surface** (via `tools/capture-t14-g4-acpi.md`, R111.M2-006): RSDP → XSDT → { MADT (LAPICs, IOAPICs, ISO overrides), MCFG (ECAM base per segment), FADT (PM1 / reset register), HPET, DMAR (VT-d), MADT x2APIC entries }. AML tables (DSDT / SSDT) are captured but not consumed by R111 — ACPICA slots R29 / R78 (§8).

### 2.3 Firmware blobs required at boot

For a first-boot image that avoids running with stale errata or headless GPU state:

| Blob                          | Path in ESP                             | Consumed by                              | Substrate today                            |
|-------------------------------|-----------------------------------------|------------------------------------------|--------------------------------------------|
| Intel CPU microcode           | `/paideia/firmware/intel-ucode/06-ba-04.bin` | R21 BSP + R18 AP bring-up (WRMSR IA32_BIOS_UPDT_TRIG) | None — R111.M6-022 lands the loader        |
| Iris Xe GuC firmware          | `/paideia/firmware/iris-xe-guc/adlp_guc_70.bin` (SKU-dependent) | R77 (out of scope) — bundle-only in R111 | `drivers/gpu/` has submit-ring code; GuC firmware upload gap |
| Iris Xe HuC firmware          | `/paideia/firmware/iris-xe-huc/adlp_huc_9.bin` | R77 (out of scope) — bundle-only in R111 | Same as GuC                                |
| Firmware manifest (sha256)    | `/paideia/firmware/MANIFEST.sig`        | `driver/blob_load.pdx` (R111.M6-023)     | `driver/blob_load.pdx` exists; verify hook is R111.M6-024 |

AX211 firmware, audio DSP firmware, IPU6 firmware, TPM firmware — none bundled at R111 because their consumers are out of scope (§8). The bundling convention is designed so R83 / R81 / R43 add rows to the manifest without redesigning the loader.

---

## 3. Gap analysis — have vs need

Every row cites the specific paideia-os module handling the QEMU case today and names the real-hardware delta. Rows without a specific delta are called out as "no gap".

| Subsystem                    | Have (QEMU path today)                                                                 | Need (T14 G4 real HW)                                                    | Wave slot     |
|------------------------------|----------------------------------------------------------------------------------------|--------------------------------------------------------------------------|---------------|
| UEFI stub → kernel entry     | `src/boot/uefi_stub.pdx` → `kernel_main_uefi` (halts at "UEFI kernel_main entered")   | Chain into `kernel_main_64` via a bridging routine that establishes higher-half paging under UEFI-map physmap ownership | R111.M1-002   |
| Higher-half paging under UEFI | `src/kernel/mm/uefi_phys_seed.pdx` seeds bitmap; no PML4 install                       | Install kernel PML4 mapping higher-half VMA → LMA before jump           | R111.M1-003   |
| ACPI static tables           | `src/kernel/acpi/*.pdx` + `src/kernel/core/acpi/*.pdx` — parses OVMF-provided tables   | Consume `boot_env_t.rsdp_pa` (already latched by R19); handle Insyde extension entries (proprietary vendor OEM tables prefix XSDT — they must be skipped, not misparsed) | R111.M1-004   |
| PCIe ECAM enumeration        | `src/kernel/core/pci/enum.pdx` walks Q35's flat topology                               | Full BDF walk across Raptor Lake PCH bridges; handle partial BAR-sizing where Insyde has pre-programmed BARs; extended-cap chain edge cases | R111.M2-005   |
| Device-ID capture            | Hardcoded QEMU IDs in probe tables                                                     | Populate `design/hardware/t14-g4-device-ids.md` from live capture; refactor probes to load table | R111.M2-006   |
| MSI-X vector allocation      | LAPIC MSI works direct on QEMU                                                         | Interrupt-remapping table via VT-d required before x2APIC MSI is stable on Raptor Lake client silicon; `src/kernel/iommu/` — verify IR table setup lands before first MSI-X programming | R111.M2-007   |
| IOAPIC GSI routing           | `src/kernel/core/apic/` + `src/kernel/boot/kernel_main.pdx` — IRQ 4 for UART, rest ad-hoc | Full GSI table from MADT ISO overrides; multiple IOAPICs on Raptor Point-U | R111.M2-008   |
| VMD collision                | N/A (QEMU does not model VMD)                                                          | Kernel refuses to boot with a witness "VMD ENABLED — turn off in BIOS Config→Storage" if VMD hides NVMe (per `design/hardware/quirks.md §2.4`) | R111.M2-009   |
| Insyde memmap key retry      | `src/boot/uefi_stub.pdx` finalizer already loops                                       | Verify retry count under Insyde variance (Raptor Lake SKU drift); tighten `_efi_memmap_retries` log | R111.M2-010   |
| NVMe controller attach       | `drivers/nvme/probe.pdx` against QEMU's ideal NVMe                                    | Real-HW probe against Samsung PM9A1 / WD SN740 / SK Hynix PC901; vendor Identify quirks; MDTS clamp verification | R111.M3-011   |
| NVMe first-boot ID           | `boot_env_t` currently silent on NVMe topology                                        | Enumerate first NVMe controller from PCIe walk; publish `KIND_BLKDEV` cap; log "NVMe CTL 0 OK vid=<v> did=<d> nn=<n>" | R111.M3-012   |
| PdxFS-lite mount             | R107 file-bdev mount landed against tmpfs-backed blob                                 | Mount PdxFS-lite from ESP-embedded blob (§0) as `/`; deferred mount of internal-NVMe `/home` per §6 stretch | R111.M3-013   |
| NVMe HW smoke fingerprint    | `tools/hw-smoke-r51-nvme-t14g4.md` — UNSEEDED, `gated:hardware`                       | Seed `tests/hw/expected-hw-nvme-t14g4.txt` from first successful physical run | R111.M3-014   |
| GOP framebuffer console      | `drivers/fb_console.pdx` + `fb_font.pdx` + `fb_glyph.pdx` + `fb_map.pdx` exist; consumers are QEMU-only (`drivers/gfx/bochs_stdvga`, `drivers/gfx/virtio_gpu`) | Consume `boot_env_t.gop_fb` (base, pitch, bpp, w, h); map WC via PAT; wire fb_console as dual-sink alongside serial | R111.M4-015   |
| Panic path FB dump           | `src/kernel/core/klog/` — serial only                                                  | Emit last-N klog ring to GOP LFB in panic handler (photograph-recoverable) | R111.M4-016   |
| xHCI attach                  | `drivers/xhci/probe.pdx` against qemu-xhci                                             | Real-HW probe on Raptor Point-U xHCI (8086:51ED); BIOS→OS handoff via USBLEGSUP under Insyde | R111.M5-017   |
| HID keyboard input           | `drivers/xhci/hid.pdx` + `hid_keymap.pdx` route to TTY input ring                     | Verify USB-A external keyboard on real T14 (USB-C keyboards over PD are stretch) | R111.M5-018   |
| Internal keyboard (i2c-HID)  | `drivers/i2c_hid/*.pdx` files exist but need ACPICA to enumerate                     | **Deferred (§8)** — internal keyboard stays dark until R29/R78          | —             |
| Firmware bundling            | None                                                                                   | ESP layout `/paideia/firmware/**`; MANIFEST.sig hashing; kernel loader; microcode WRMSR path | R111.M6-019..024 |
| Image builder                | `tools/build-image.sh` composes ESP + rootfs; no firmware; partitionless FAT32 only  | `tools/mkimage.sh` (new) folds in firmware + optional GPT-partitioned variant + signed manifest | R111.M7-025   |
| QEMU-fidelity smoke          | `bash tools/run-qemu.sh` = `-M pc` (Q35 in some invocations)                          | `bash tools/run-qemu.sh --t14-fidelity` = `-M q35` + `-bios OVMF_CODE_4M.fd` + `-device intel-iommu` + swtpm + `-cpu Alderlake-Server-noTSX` (closest CPU model to Raptor Lake in QEMU 8.x) | R111.M7-026   |
| Hardware-in-loop capture     | `tools/run-smoke-hw.sh` exists; fingerprint files empty                              | Operator-driven capture flow → `tests/hw/expected-hw-boot-t14g4-full.txt` seeded from first physical run | R111.M7-027   |

---

## 4. Wave breakdown

### 4.A — UEFI-to-kernel bridge (R111.M1)

Fixes the "$prompt is aspirational" gap. Without this sub-wave, nothing else matters — the UEFI path halts at 4 lines of output. Load-bearing.

- **R111.M1-001** — Umbrella issue. Cross-links every sub-issue. Body has the full sub-wave DAG (§6) and the operator-side smoke recipe (§7 style).
- **R111.M1-002** — Bridge `kernel_main_uefi` → `kernel_main_64`. Under UEFI-boot, after `verify_self` returns and the physmap is seeded, chain into `kernel_main_64` (currently only reachable via PVH direct-load). The bridge must (a) transfer physmap ownership to the R14+ `mm/` subsystem, (b) hand the ACPI RSDP through the R20 handoff record, (c) hand the GOP framebuffer descriptor through the R23 handoff record, (d) preserve the ML-DSA-65 measurement chain from R28.M1-004 `verify_self`. See `src/kernel/kernel_main_uefi.pdx` line 219 (`kernel_main_uefi_halt` — the halt this issue replaces).
- **R111.M1-003** — Higher-half paging under UEFI. `kernel_main_uefi` today executes at LMA (0x100000 placeholder); `kernel_main_64`'s .text is linked at higher-half VMA per `src/kernel/link.ld`. This sub-issue installs a bootstrap PML4 that maps VMA → LMA before the bridge jump, and hands ownership of the R14 identity-mapped low PML4 to the R14+ mm subsystem for teardown.
- **R111.M1-004** — ACPI RSDP consumption from `boot_env_t`. Delete the QEMU EBDA-scan fallback path from the UEFI boot; the RSDP is authoritative from `boot_env_t.rsdp_pa`. Log "ACPI RSDP @0x<pa> XSDT[<n>] MADT MCFG FADT HPET" — the R20 witness line, but seeded from the real firmware handoff.

### 4.B — Real-HW probe sub-wave (R111.M2)

Parallel-safe within the sub-wave; all four gate on M1. This is where the wave earns its keep — every substrate-round assumption gets crossed with real Insyde/Raptor-Lake behavior.

- **R111.M2-005** — PCIe ECAM real-HW walk. Extend `src/kernel/core/pci/enum.pdx` to handle Raptor Lake PCH bridge topology; verify BAR-sizing algorithm against Insyde's pre-programmed BARs (BIOS may leave some BARs in an "already sized" state that trips the standard write-1s-read-back sizing); walk extended capabilities (offset ≥ 0x100) for the DMAR / SR-IOV / ACS chains.
- **R111.M2-006** — Device-ID capture and probe-table refactor. Run `tools/capture-t14-g4-pci.md` + `tools/capture-t14-g4-acpi.md` against a physical T14 G4; commit outputs under `tests/hw/fixtures/t14-g4-pci.txt` + `tests/hw/fixtures/t14-g4-acpi.txt`; extract IDs into `design/hardware/t14-g4-device-ids.md`; refactor `drivers/{nvme,xhci,e1000e,gpu,dpy}/probe.pdx` to load probe tables from a common `drivers/probe_table.pdx` (new file, per-driver arrays already exist but scattered).
- **R111.M2-007** — MSI-X + interrupt-remapping. Verify `src/kernel/iommu/` sets up the VT-d IR table BEFORE the first MSI-X vector is programmed. Raptor Lake client silicon requires IR-mode MSI-X for reliability under x2APIC — bare MSI-X without IR is where the "phantom IRQ" class of Linux bugs originally lived. Fingerprint `IR TABLE OK entries=<n>` before the first `MSI-X VEC OK dev=<bdf> vec=<n>`.
- **R111.M2-008** — Full IOAPIC GSI routing from MADT ISO overrides. Retire the R16.M4 hard-coded IRQ-4-for-UART shortcut; walk MADT for LAPIC + IOAPIC + ISO override entries; publish GSI-to-vector map to the interrupt subsystem so PCIe device MSI programming can allocate vectors coherently.
- **R111.M2-009** — VMD boot-refuse. If PCI walk finds VMD (class `01/04/00`, vendor 8086, device 0x467F or 0xA77F depending on Raptor Point revision) enabled, halt with a fixed-format serial + FB message: `VMD ENABLED — reboot, BIOS setup, Config→Storage→Intel VMD Controller=Disabled. See design/hardware/quirks.md §2.4`. Better than silent failure.
- **R111.M2-010** — Insyde GetMemoryMap key-retry hardening. The R19 finalizer already loops on `EFI_INVALID_PARAMETER`; verify observed retry counts on Raptor Lake stay bounded (~2-4 on OVMF, unknown on Insyde). Tighten `_efi_memmap_retries` slot to publish the observed count; fail hard above 32.

### 4.C — Storage sub-wave (R111.M3)

Gates on M2 (needs PCIe walk to find the NVMe controller). Parallel-safe with M4.

- **R111.M3-011** — NVMe real-HW controller attach. Extend `drivers/nvme/probe.pdx` for Samsung PM9A1 (14E4:A80A), WD SN740 (15B7:5017), SK Hynix PC901 (1C5C:1A59). Confirm Identify Controller returns coherent NN, MDTS, VS ≥ 0x00010400 (NVMe 1.4). Handle vendor-specific Identify quirks (Samsung MDTS reporting has historically undercounted by one on some FW revs; clamp to reported MDTS-1 already lives in `drivers/nvme/mdts.pdx` — verify it triggers).
- **R111.M3-012** — First-NVMe enumeration + KIND_BLKDEV publication. On successful controller attach, mint the first controller's Namespace 1 as `KIND_BLKDEV`; log "NVMe CTL 0 OK vid=<v> did=<d> ns=1 lba_size=<b> cap=<c> GiB". Downstream consumers (R107 mount, R111.M3-013) discover the cap by iteration.
- **R111.M3-013** — Optional internal-NVMe rootfs (stretch). Boot path today mounts the ESP-embedded PdxFS-lite blob as `/`. If a KIND_BLKDEV cap exists AND a PDXB superblock is present at LBA 0 of Namespace 1, additionally mount it at `/home`. Absent the superblock, skip cleanly. Not required for the "$ prompt" acceptance witness; makes the demo useful. Verify against `design/user/persistent-home.md` (R107 wave landed the mount plumbing).
- **R111.M3-014** — Seed `tests/hw/expected-hw-nvme-t14g4.txt` from a live capture of `tools/hw-smoke-r51-nvme-t14g4.md` on the target unit. The fingerprint fields (superblock digest, itable digest, WAL-head LBA, `mount_gen`, `blkdev_row_family`) are documented there; this issue is the one that lifts the `gated:hardware` label to `confirmed`.

### 4.D — Display sub-wave (R111.M4)

Gates on M1 (needs the GOP framebuffer descriptor consumed from `boot_env_t`). Parallel-safe with M2, M3, M5.

- **R111.M4-015** — GOP LFB direct scanout to eDP. Consume `boot_env_t.gop_fb` (base, pitch, bpp, width, height) — the R19 stub already latched these; the QEMU path today has been consuming a virtio-gpu-provided FB instead. Map the LFB with write-combining via PAT (per `design/hardware/quirks.md` and `paideia-as v0.23`'s `@device_memory` type modifier). Wire the existing `drivers/fb_console.pdx` as the primary console sink; do NOT wait for Iris Xe KMS scanout (R77). Log "GOP FB @0x<pa> <w>x<h> bpp=<b> pitch=<p>" as fingerprint.
- **R111.M4-016** — Dual-sink console (serial ∥ FB). Kernel console writes fan out to both COM1 (existing) and the GOP LFB (via fb_console). Applies to boot banner, klog, INIT/SHELL output, `$` prompt. Operator sees the same bytes on eDP as on serial USB dongle. When no GOP FB is present (headless), the FB sink no-ops silently.
- **R111.M4-017** — Panic-path FB dump. On `panic()` — verify `src/kernel/core/klog/` panic handler — emit the last N (default 256) klog lines to the GOP LFB in a large-font, no-scroll layout so an operator without serial can photograph the state. Fingerprint the fact that the panic path visited the FB, not the state itself (state is variable).

### 4.E — Input sub-wave (R111.M5)

Gates on M2 (needs xHCI's PCI probe cap allocation) and on M4 for the console side; parallel-safe with M3.

- **R111.M5-018** — xHCI real-HW attach + BIOS→OS handoff under Insyde. Verify `drivers/xhci/bios_handoff.pdx` (USBLEGSUP.HC_BIOS_OWN → HC_OS_OWN transition) completes cleanly on Insyde firmware. Some Insyde revisions delay the transition; the spec allows up to 1 second — tighten the timeout to 2 seconds; log every 100 ms of wait so an operator can distinguish "firmware busy" from "firmware refuses". USB-A port enumeration first; USB-C data-mode enumeration second (USB-C PD negotiation is TB4-substrate, out of scope here — treat USB-C as USB-only for R111).
- **R111.M5-019** — HID boot-protocol keyboard on USB-A. Existing `drivers/xhci/hid.pdx` + `hid_keymap.pdx` + `hid_report.pdx` handle the parsing. Verify a real USB-A external keyboard (test corpus: any HID-boot-protocol-compatible keyboard) routes bytes into the TTY input ring (`src/kernel/core/tty/`). Fingerprint `HID KBD OK dev=<bdf> descriptor_len=<n>` on attach; per-keypress logging in verbose mode only.

### 4.F — Firmware bundling sub-wave (R111.M6)

Parallel-safe with A-E; gates on G's ESP layout only for the final integration. The intent is that Intel microcode is applied at first-boot; GuC/HuC blobs are staged on the ESP so R77 (Iris Xe modeset, out of scope here) can wire them without a second image-builder round.

- **R111.M6-020** — ESP firmware directory layout. Define `/paideia/firmware/{intel-ucode,iris-xe-guc,iris-xe-huc}/`. Filename convention: `<family>-<model>-<stepping>.bin` (microcode); `<pciid-hex>.bin` (GuC/HuC). Document in `design/loader/firmware-blob-esp-layout.md` (new file).
- **R111.M6-021** — Manifest format + hashing. `/paideia/firmware/MANIFEST.sig`: one line per blob, `<sha256> <path> <length>`. R111 ships unsigned (per `design/security/pe-secure-boot-signing.md` — signing lands at R32/R82); manifest itself is unsigned but tamper-detectable via `verify_self`'s .pdxsig hash chain once R82 lands.
- **R111.M6-022** — Kernel firmware-blob loader. Extend `src/kernel/core/driver/blob_load.pdx` to (a) traverse `/paideia/firmware/` at boot, (b) match blob names against CPUID (microcode) or PCI ID (GuC/HuC) probe tables, (c) verify sha256 against MANIFEST, (d) mint a `KIND_BLOB` cap per blob and stash it for the appropriate driver.
- **R111.M6-023** — Intel microcode WRMSR path. On BSP boot (after XSAVE init, before PCI enumeration): match CPUID `0x0A06BAh` (or the observed value from capture) to `/paideia/firmware/intel-ucode/<match>.bin`; verify signed by Intel per SDM Vol. 3 §9.11; WRMSR IA32_BIOS_UPDT_TRIG (0x79) with blob base; log "UCODE APPLIED rev=0x<n> family=<f> model=<m> stepping=<s>". On AP bring-up: apply same blob per AP. Refuse to boot if no matching microcode is present (fail loud, per `design/security/no-silent-fallback.md`).
- **R111.M6-024** — GuC/HuC blob staging (no consumer wiring). Load GuC + HuC blobs into KIND_BLOB caps by PCI-ID match; publish caps to the (empty for R111) Iris Xe scanout registry. R77 will consume; R111 verifies the load path with a fingerprint `GUC BLOB STAGED pciid=0x<v>:0x<d> bytes=<n>` only.

### 4.G — Image builder + smoke sub-wave (R111.M7)

Consolidates A-F into one operator command; gates on all prior sub-waves.

- **R111.M7-025** — `tools/mkimage.sh` (new; consolidates + wraps `build-image.sh`). Single command: rebuild kernel + stub + user + rootfs + firmware directory; assemble ESP; optionally partition-wrap in GPT (see M7-026); emit `build/mvp/paideia-t14.img` + `build/mvp/paideia-t14.img.sha256`. `--gpt` flag toggles GPT vs partitionless (default partitionless per §0). `--firmware-dir=<path>` overrides the built-in `/paideia/firmware/` staging area for operator-supplied blobs.
- **R111.M7-026** — GPT-partitioned image variant. Some BIOS revisions refuse partitionless USB HDD (they scan for GPT/MBR partition tables before recognizing the FAT header). Add an xorriso-based (or sfdisk + mkfs.vfat) path that produces a GPT with one ESP partition; boot behavior matches partitionless for firmware that accepts either. Fingerprint `file build/mvp/paideia-t14.img` matches `DOS/MBR boot sector; partition 1: EFI System (bootable)`.
- **R111.M7-027** — `bash tools/run-qemu.sh --t14-fidelity`. New invocation shape: `-M q35 -bios /usr/share/OVMF/OVMF_CODE_4M.fd -device intel-iommu,intremap=on -cpu Alderlake-Server-noTSX,+xsave,+pku,-la57 -smp 8,cores=8 -m 8192 -device virtio-scsi-pci -drive file=<img>,format=raw,if=none,id=usb1 -device usb-storage,drive=usb1`. This is not T14 fidelity — no QEMU CPU matches Raptor Lake exactly, no QEMU chipset matches Raptor Point-U — but it is measurably closer than the current `-M pc` invocation. Distinct fingerprint file `tests/expected-boot-t14-fidelity.txt`.
- **R111.M7-028** — Hardware-in-loop capture procedure. Extend `tools/hw-smoke-capture.sh` (new) to: (a) prompt operator to attach USB-serial + power on target; (b) run tio with logging; (c) after N seconds, save log to `/tmp/paideia-hw-boot-<utc-timestamp>.log`; (d) exec `tools/run-smoke-hw.sh boot --log=<path>` for fingerprint verification. Populate `tests/hw/expected-hw-boot-t14g4-full.txt` from the first successful physical run (per R28.M2 discipline: no invented fingerprints, unseeded is better than fake).
- **R111.M7-029** — Retrospective + round closure. Populate `design/round-retrospectives/r111-closure.md`. Advance `design/hardware/quirks.md` PROVISIONAL rows → CONFIRMED / WORKED-AROUND for every T14 G4 row exercised (§2.4 VMD, §2.5 UART, plus any newly-discovered quirks per §10). Tag `r111-closed` on paideia-os.

---

## 5. Per-sub-issue table

| ID              | Title                                              | Scope (1-2 sentences)                                                                                                     | Acceptance / witness                                                                | Size | Deps                       |
|-----------------|----------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------|------|-----------------------------|
| R111.M0         | T14 G4 bootable USB — umbrella                     | Cross-links every sub-issue. Owns the operator-side smoke recipe (§0 + §7).                                              | All sub-issues closed; `bash tools/mkimage.sh` → `dd` → boot on physical T14 → `$` prompt on serial ∥ eDP. | —    | —                          |
| R111.M1-002     | Bridge `kernel_main_uefi` → `kernel_main_64`       | Under UEFI, chain into `kernel_main_64` after physmap seed + verify_self. Hand RSDP + GOP FB + measurement chain via handoff record. | Serial + FB log shows R11-R60 subsystem init lines under UEFI boot (not just PVH). | XL   | —                          |
| R111.M1-003     | Higher-half paging under UEFI                       | Install bootstrap PML4 mapping higher-half VMA → LMA before bridge jump.                                                | Fingerprint `KERNEL PML4 INSTALLED higher_half_ok=1` before first higher-half call. | L    | R111.M1-002 (co-lands)    |
| R111.M1-004     | ACPI RSDP from `boot_env_t`                        | Delete EBDA-scan fallback for UEFI path; RSDP authoritative from firmware handoff.                                       | `ACPI RSDP @0x<pa> XSDT[<n>] MADT MCFG FADT HPET` line under UEFI.                | S    | R111.M1-002                |
| R111.M2-005     | PCIe ECAM real-HW walk                              | Handle Raptor Lake PCH bridge topology + Insyde pre-programmed BARs + extended-cap chain edge cases.                     | Full BDF tree logged; no `BAR SIZE FAIL` on real HW; ext-cap DMAR walk finds VT-d. | L    | R111.M1-002..004           |
| R111.M2-006     | Device-ID capture + probe-table refactor           | Run capture scripts on physical T14; commit fixture; extract IDs to `t14-g4-device-ids.md`; refactor probes.             | `tests/hw/fixtures/t14-g4-{pci,acpi}.txt` present; probe tables load from doc.     | M    | R111.M2-005                |
| R111.M2-007     | MSI-X + VT-d interrupt remapping                    | IR table set up before first MSI-X vector programmed.                                                                    | Fingerprint `IR TABLE OK entries=<n>` precedes every `MSI-X VEC OK`.               | L    | R111.M2-005                |
| R111.M2-008     | Full IOAPIC GSI routing from MADT ISO overrides    | Retire R16.M4 IRQ-4-hard-coded path; walk MADT for all overrides + LAPIC + IOAPIC entries.                              | Fingerprint `GSI MAP OK ioapics=<n> gsis=<m> overrides=<k>`; PCIe MSI vector allocation is coherent. | M    | R111.M1-004                |
| R111.M2-009     | VMD boot-refuse                                    | If PCI walk finds VMD (8086:467F / 8086:A77F) enabled, halt with fixed message on serial + FB.                          | Boot log: `VMD ENABLED — reboot, BIOS setup, ...` then clean halt (not crash).     | S    | R111.M2-005, M4-015        |
| R111.M2-010     | Insyde GetMemoryMap key-retry hardening            | Verify retry count bounded on Raptor Lake; publish observed count; fail hard above 32.                                  | Fingerprint `EFI MEMMAP RETRIES=<n>` in R19 finalizer path.                        | S    | —                          |
| R111.M3-011     | NVMe real-HW controller attach                     | Handle Samsung PM9A1 / WD SN740 / SK Hynix PC901 + vendor Identify quirks + MDTS clamp verification.                    | Identify Controller returns coherent; `NVMe CTL 0 OK vid=<v> did=<d> ns=<n>`.      | L    | R111.M2-005..008           |
| R111.M3-012     | KIND_BLKDEV publication for NS1                    | Mint first-controller-NS1 as KIND_BLKDEV; log with capacity.                                                             | Fingerprint `KIND_BLKDEV MINTED cap_slot=<s> lba_size=<b> cap_gib=<c>`.            | S    | R111.M3-011                |
| R111.M3-013     | Optional internal-NVMe `/home` mount               | If KIND_BLKDEV holds a PDXB superblock, mount at `/home`; otherwise skip cleanly.                                       | Cold boot → mount if present → `$` prompt; also `stat /home` succeeds if mounted.  | M    | R111.M3-011, M3-012        |
| R111.M3-014     | Seed `expected-hw-nvme-t14g4.txt`                  | Populate the fingerprint file from first physical capture.                                                              | File exists + non-empty; `PAIDEIA_HW_SMOKE=1 tools/run-smoke-hw.sh nvme` passes.   | S    | R111.M3-011..013           |
| R111.M4-015     | GOP LFB direct scanout to eDP                       | Consume `boot_env_t.gop_fb`; map WC via PAT; wire `fb_console` as primary FB sink.                                       | Fingerprint `GOP FB @0x<pa> <w>x<h> bpp=<b> pitch=<p>` + visible text on eDP.      | M    | R111.M1-002                |
| R111.M4-016     | Dual-sink console (serial ∥ FB)                     | Console writes fan out to COM1 + GOP LFB; graceful when either is absent.                                                | Same bytes visible on serial + FB from boot banner through `$` prompt.             | M    | R111.M4-015                |
| R111.M4-017     | Panic-path FB dump                                  | On `panic()`, emit last-N klog lines to GOP LFB in large-font, no-scroll layout.                                        | Deliberate panic (test injector) produces readable FB output; fingerprint hit.    | S    | R111.M4-015                |
| R111.M5-018     | xHCI real-HW attach + Insyde USBLEGSUP handoff     | Verify `bios_handoff.pdx` transition on Insyde; 2 sec timeout; per-100ms progress log.                                   | Fingerprint `XHCI OS OWN OK wait_ms=<n>` on real HW; USB-A + USB-C ports enum.    | L    | R111.M2-005, M2-007        |
| R111.M5-019     | HID keyboard on USB-A                               | Verify external USB-A keyboard routes to TTY input; `$` prompt accepts input.                                            | Type `true` at `$` prompt; shell fork+execve+wait4 completes.                     | S    | R111.M5-018                |
| R111.M6-020     | ESP firmware directory layout                       | Define `/paideia/firmware/{intel-ucode,iris-xe-guc,iris-xe-huc}/`; commit `design/loader/firmware-blob-esp-layout.md`. | Directory + naming convention documented; empty stubs at build time.               | S    | —                          |
| R111.M6-021     | Manifest format + hashing                           | `/paideia/firmware/MANIFEST` schema: `<sha256> <path> <length>` per line.                                                | Manifest present + valid on every mkimage output.                                  | S    | R111.M6-020                |
| R111.M6-022     | Kernel firmware-blob loader                         | Extend `driver/blob_load.pdx` to traverse `/paideia/firmware/`, match, verify, mint KIND_BLOB.                          | Fingerprint `FW BLOBS LOADED n=<n>` on boot.                                       | M    | R111.M6-021                |
| R111.M6-023     | Intel microcode WRMSR path                          | On BSP: CPUID → microcode blob → WRMSR IA32_BIOS_UPDT_TRIG. AP: same. Refuse boot if no match.                          | Fingerprint `UCODE APPLIED rev=0x<n> ...`; per-AP.                                 | M    | R111.M6-022, R111.M1-002   |
| R111.M6-024     | GuC/HuC blob staging (no wiring)                    | Load GuC + HuC into KIND_BLOB caps by PCI ID; publish (empty) to Iris Xe registry for R77.                              | Fingerprint `GUC BLOB STAGED pciid=... bytes=<n>` + `HUC BLOB STAGED ...`.         | S    | R111.M6-022                |
| R111.M7-025     | `tools/mkimage.sh`                                  | New command consolidating build-image.sh + firmware bundling + optional GPT.                                             | `bash tools/mkimage.sh` exits 0; emits `build/mvp/paideia-t14.img` + `.sha256`.  | M    | R111.M6-020..024           |
| R111.M7-026     | GPT-partitioned image variant                       | Add `--gpt` flag: xorriso or sfdisk+mkfs.vfat path producing GPT with one bootable ESP.                                  | `file build/mvp/paideia-t14.img` matches `partition 1: EFI System (bootable)`.    | S    | R111.M7-025                |
| R111.M7-027     | `bash tools/run-qemu.sh --t14-fidelity`             | New invocation: q35 + OVMF 4M + intel-iommu + Alderlake-Server-noTSX + `-smp 8` + `-m 8192`.                            | New fingerprint file `tests/expected-boot-t14-fidelity.txt` passes.               | S    | R111.M7-025                |
| R111.M7-028     | Hardware-in-loop capture procedure                  | `tools/hw-smoke-capture.sh` (new) drives tio capture → seeds `expected-hw-boot-t14g4-full.txt`.                          | Capture procedure documented + rehearsed; fingerprint file seeded.                 | M    | R111.M7-025, all above     |
| R111.M7-029     | Retrospective + round closure                       | `design/round-retrospectives/r111-closure.md`; promote quirks rows; `r111-closed` tag.                                   | Retro file present; quirks rows promoted; tag pushed.                              | S    | R111.M7-028                |

**Size legend:** S = 1-3 days, M = 3-7 days, L = 1-2 weeks, XL = 2-4 weeks (single issue only; likely split at kickoff).

**Total:** 25 sub-issues + 1 umbrella = 26 issues. Sits within the 15-30 target; skew high because §0 is a strict acceptance criterion.

---

## 6. Ordering DAG

```
                          R111.M1-002 (bridge, XL)
                                │
             ┌──────────────────┼──────────────────┐
             │                  │                  │
       R111.M1-003        R111.M1-004         (unblocks all
       (higher-half         (ACPI RSDP)         downstream)
        paging, L)              │
             │                  │
             └────────┬─────────┘
                      │
        ┌─────────────┼─────────────┬─────────────┐
        │             │             │             │
   R111.M2-005   R111.M2-008    R111.M4-015   R111.M6-020..024
   (PCIe ECAM)   (IOAPIC GSI)   (GOP LFB)     (firmware,
        │             │             │           parallel-safe)
        │             │             │
        ▼             ▼             ▼
   R111.M2-006   R111.M2-007    R111.M4-016
   (ID capture)  (MSI-X + IR)   (dual-sink)
        │             │             │
        │             │             ▼
        │             │        R111.M4-017
        │             │        (panic FB)
        │             │
        ▼             ▼
   R111.M2-009   R111.M2-010
   (VMD refuse)  (memmap retry)
        │
        ▼
   R111.M3-011 ────► R111.M3-012 ────► R111.M3-013
   (NVMe attach)     (KIND_BLKDEV)    (/home mount)
        │
        ▼
   R111.M3-014
   (fingerprint seed)

   R111.M5-018 (xHCI, needs M2-005 + M2-007)
        │
        ▼
   R111.M5-019 (HID keyboard)

Convergence:  everything ────► R111.M7-025 (mkimage) ────► R111.M7-026 (GPT variant)
                                                    │
                                                    ▼
                                           R111.M7-027 (--t14-fidelity)
                                                    │
                                                    ▼
                                           R111.M7-028 (HW capture)
                                                    │
                                                    ▼
                                           R111.M7-029 (retro + close)
```

**Parallelism:**

- **Wave A (serial):** M1-002 → M1-003 co-lands → M1-004.
- **Wave B (parallel, 5 tracks):** M2-005 ∥ M2-008 ∥ M4-015 ∥ M6-020..024 ∥ M2-010.
- **Wave C (parallel, 3 tracks):** M2-006 depends on M2-005; M2-007 depends on M2-005; M4-016 depends on M4-015.
- **Wave D (serial per track):** M3-011 → M3-012 → M3-013 → M3-014; M4-017 depends on M4-015; M5-018 → M5-019.
- **Wave E (serial convergence):** M7-025 → M7-026 → M7-027 → M7-028 → M7-029.

Ordering-constraint sources:
- Bridge (M1-002) is load-bearing per §1 gap 1.
- ACPI-first-then-PCIe is the R20→R22 invariant per r18-plus-bare-metal.md §9.
- MSI-X requires IR on Raptor Lake per hwman-adjacent references + Intel VT-d spec §5.
- xHCI depends on PCIe walk + IR (per R22 → R26 ordering in the same doc).
- Firmware loader (M6-022) needs no other sub-wave — designed parallel-safe.
- Everything converges at M7-025 because mkimage.sh consumes every prior artifact.

---

## 7. Risk register (top 5)

| # | Risk                                                                             | Impact | Likelihood | Mitigation                                                                                                                                       |
|---|-----------------------------------------------------------------------------------|--------|------------|--------------------------------------------------------------------------------------------------------------------------------------------------|
| R1 | **Bridge `kernel_main_uefi` → `kernel_main_64` reveals uncataloged higher-half assumptions.** kernel_main_64 has grown 60+ round-worths of assumptions about pre-existing PVH-path state (identity-mapped low PML4, RSDP already latched into a QEMU-derived slot, GOP FB already published by a QEMU device model). | High   | High       | R111.M1-002 is XL and expected to split at kickoff. Front-load a "audit uncataloged assumptions" bullet-list issue before code. Debugger runs after every softarch iteration per [[feedback-debugger-every-iteration]]. |
| R2 | **Insyde firmware quirks are undocumented and vary per BIOS revision.** Same T14 G4 SKU on BIOS R28ET40W vs R28ET42W may behave differently on USBLEGSUP, MemoryMap key retries, MSI-X vector allocation. | High   | Medium     | R111.M2-010 tightens observability (retry counts, wait times). §10 mandates capturing BIOS revision + SN in every hw-smoke fingerprint. Multi-BIOS-rev capture optional but recommended (`design/hardware/quirks.md` promotion criteria).           |
| R3 | **NVMe vendor drift.** Samsung/WD/SK Hynix each ship distinct Identify quirks; SN740 has known LBA-format reporting oddities under NVMe 1.4. Wave assumes any of the three passes M3-011. | Medium | Medium     | R111.M3-011 targets three specific controllers explicitly. If one fails, treat as scope-cut (drop from wave, file follow-on issue) rather than blocking. Fingerprint controller vid:did in every log line.        |
| R4 | **No physical T14 G4 access during the wave.** Every "gated:hardware" sub-issue stalls; wave cannot close.                                                                        | High   | Medium     | §7 open question 7 (from r18-plus-bare-metal.md §8) is not yet answered. Wave kickoff blocks on user confirming physical unit + serial cable + operator time. Under "no access" contingency, M1 + M2 + M4 + M6 land against QEMU-fidelity smoke only; M3-011/M5-018/M7-028 stay open until access.  |
| R5 | **Firmware blob provenance under MIT license.** GuC / HuC / microcode are Intel-proprietary redistributables. The paideia-os monorepo cannot embed them under MIT terms without violating Intel's redistribution license. | Medium | High       | R111.M6-020's ESP layout is designed so firmware blobs come from an **operator-supplied directory** at `mkimage.sh` time via `--firmware-dir=<path>` (M7-025), not from the paideia-os git tree. Document the sourcing recipe (`linux-firmware.git` extraction) in `design/loader/firmware-blob-esp-layout.md`. |

Second-tier risks (log-only, not gating): VMD detection false-positive on non-VMD SKUs (M2-009 must probe class before vendor, defensive); GPT variant refused by some BIOSes (M7-026 keeps partitionless default per §0); dual-sink console byte-interleaving under FB slow-path (M4-016 must lock or serialize).

---

## 8. Out of scope — explicit list

Every row here has a rationale plus a target R-round from `design/roadmap/next-wave-osarch.md` / `design/roadmap/post-r60-daily-use-roadmap.md`.

| Item                                              | Why deferred                                                                                                       | Target round               |
|---------------------------------------------------|-------------------------------------------------------------------------------------------------------------------|----------------------------|
| Wi-Fi upper stack (802.11 MAC, WPA3, DHCP)         | R38.M1 PCI probe + firmware load landed; upper stack is ~40 issues (net-wave-osarch R41 or post-r60 R83). Not required for `$` prompt.                             | R41 (osarch) or R83 (post-r60) |
| Bluetooth (HCI, L2CAP, GATT, A2DP, HFP)            | Shared radio with AX211; same defer as Wi-Fi. Also not required for `$`.                                          | R41 or R83                 |
| Audio (HDA controller + ALC287 codec + PCM ring)   | Prompt explicit: "though audio can be out of scope". Not required for `$`; scaffold exists.                       | R36 (osarch) or R81 (post-r60) |
| Camera IPU6 (MIPI CSI-2 + IPU6 firmware + pipeline) | Zero consumers in R111 boot path. Deferred entirely.                                                              | R43                        |
| Fingerprint reader (Goodix/Synaptics USB)          | Not authentication-critical for R111 (no signed login gate).                                                       | R43 (osarch) or R76 (post-r60) |
| TB4 hot-plug UX (dock connect/disconnect events)   | Static topology at boot is enough. Hot-plug is R42/R84 scope.                                                     | R42 or R84                 |
| DP-alt over TB4 (external display via dock)        | Same as TB4 hot-plug. Internal eDP via GOP LFB is sufficient.                                                      | R42                        |
| USB-C PD data negotiation                          | R111 treats USB-C as USB-only (data-mode enumeration), no PD dance.                                                | R42                        |
| Suspend / resume (ACPI S3, S0ix idle)              | Requires ACPICA (R29/R78) + EC (R31) + per-driver `suspend()` callbacks. Half-a-round on its own.                | R75                        |
| Iris Xe accelerated scanout (KMS + display engine) | R111 uses GOP LFB direct; native scanout is R77 scope. GuC/HuC blobs staged by M6-024 so R77 lands cleanly.        | R77                        |
| Internal keyboard (i2c-HID)                        | i2c-HID files exist but need ACPICA to discover the LPSS I²C controllers + I²C-HID device tree.                    | R29 / R78                  |
| Trackpad (Synaptics/ELAN I²C-HID)                  | Same ACPICA gate as internal keyboard.                                                                            | R33 / R76                  |
| TPM 2.0 measured boot enforcement                  | R19.M3 log-only latching present; enforcement (halt-on-fail) waits for R32/R82 crypto + KEK enrollment.            | R33 / R82                  |
| Signed EFI (Secure Boot enabled)                   | R28.M1-004 `verify_self` is log-only per `VERIFY_SELF_ENFORCE=0`. Real signing lands with R82.                    | R82                        |
| Wi-Fi/Bluetooth firmware blobs in image            | Bundling convention (M6-020) is designed to accept them, but no loader wires them in R111.                        | R41 / R83                  |
| AMD T14 G4 variant                                 | See §2.1: ~10 rounds of driver rewrite. Never explicitly slotted; a future R-wave.                                | TBD                        |

---

## 9. Cross-references

- **Kernel entry points:** `src/kernel/kernel_main_uefi.pdx` (R19.M4 stub, halts at line 219 — the load-bearing gap R111.M1-002 fills), `src/kernel/boot/kernel_main.pdx` (R11+ orchestrator, PVH-path today).
- **Bootstrap:** `src/kernel/boot/entry.pdx`, `src/kernel/boot/gdt.pdx`, `src/kernel/boot/handoff.pdx`, `src/kernel/boot/t14_g4_detect.pdx`.
- **UEFI stub:** `src/boot/uefi_stub.pdx` (referenced from prior recipes; the LMA-substitution finalizer that produces `paideia boot: entry ok`).
- **Image builder:** `tools/build.sh`, `tools/build-uefi-stub.sh`, `tools/build-uefi-image.sh`, `tools/build-image.sh` (existing composer), `tools/mkfs-pdxfs-lite-seed.sh`.
- **HW smoke:** `tools/run-smoke-hw.sh`, `tools/hw-smoke-r51-nvme-t14g4.md` (currently UNSEEDED — R111.M3-014 seeds it), `tools/capture-t14-g4-acpi.md`, `tools/capture-t14-g4-pci.md`.
- **ACPI subsystem:** `src/kernel/acpi/{rsdp,xsdt,madt,mcfg,fadt,hpet,gas,checksum,phase1_info,sdt_hdr,supervisor_dispatch}.pdx`; `src/kernel/core/acpi/{ec_route,ec_event,gpe_*}.pdx`.
- **PCIe:** `src/kernel/core/pci/{enum,enumerator_dispatch,header,config,bar,cap,ext_cap,msi,msix,publish}.pdx`.
- **Drivers touched:** `src/kernel/core/drivers/{nvme,xhci,i2c_hid,gpu,dpy,gfx,fb_console.pdx,fb_font.pdx,fb_glyph.pdx,fb_map.pdx,e1000e,tb}/`.
- **Firmware infrastructure:** `src/kernel/core/driver/{blob_load,keyring,sig_verify,sig_telemetry}.pdx` (extended in R111.M6).
- **Predecessor recipes:** `design/hardware/t14-g4-first-boot.md` (R28.M2 aspirational recipe), `design/roadmap/r19-t14-g4-boot-guide.md` (R19.M5 first-light).
- **HW quirks:** `design/hardware/quirks.md` (VMD row §2.4, UART row §2.5 — both to be promoted CONFIRMED at R111 close).
- **Roadmap context:** `design/roadmap/r18-plus-bare-metal.md` (constitutional R18-R28 slate), `design/roadmap/next-wave-osarch.md` (R29-R43 slate), `design/roadmap/post-r60-daily-use-roadmap.md` (R67 subsumed by this wave).
- **Constitutional / feedback:** [[feedback-osarch-softarch-numbering]], [[feedback-pillar-alignment]], [[feedback-debugger-every-iteration]], [[feedback-paideia-os-loop-shape]], [[feedback-aissue-command]], [[feedback-references]], [[feedback-novel-clean-design]].

---

## 10. Companion softarch wave (R112) — deliberately deferred

R112 is the softarch pair per the odd/osarch / even/softarch discipline. It is NOT drafted here; a separate osarch → softarch handoff writes it. Expected scope (from a distance):

- Userland tooling for image inspection (`pdxinspect-esp`, `pdxinspect-firmware-manifest`).
- ML-DSA-65 signing of `MANIFEST.sig` when R82 lands (defers into R112's own scope, not R111).
- `pdxfirst-boot` shell builtin: on first-ever boot of the image, capture BIOS revision + machine SN + serial log → optional `pdxfs://identity/first-boot.pdxbob` snapshot for reproducibility archives.
- `mkimage.sh` UX polish + shell-completion.
- Fingerprint-file diffing UX (`pdxsmoke-diff`).

The two waves synthesize per the R101/R102 discipline: each written independently, then a synthesis pass reconciles ordering + shared surfaces + cross-repo assembler asks.

---

## 11. Load-bearing paideia-as asks

None new. R111 lives entirely within the existing paideia-as encoder surface (v0.29.2 at HEAD per MASTER_PLAN.md §2.1); the bridge routine (M1-002) uses existing SysV / cross-module call primitives; the firmware loader (M6-022) uses existing slice + bounds accessor helpers from v0.22; the microcode WRMSR path (M6-023) uses the existing RDMSR/WRMSR typed wrapper from v0.21.

If R111 encounters an encoder gap mid-implementation, follow [[feedback-cross-repo-escalation]]: file paideia-as issue + fix + push + bump submodule, resume R111.

---

## 12. Wave close criteria

R111 closes when all of the following hold:

1. Every R111.M* sub-issue closed.
2. `bash tools/mkimage.sh` on a clean checkout produces `build/mvp/paideia-t14.img` + `.sha256`.
3. On QEMU q35 + OVMF, `bash tools/run-qemu.sh --t14-fidelity` boots to `$` prompt and matches `tests/expected-boot-t14-fidelity.txt`.
4. On physical T14 G4, `sudo dd if=... of=/dev/sdX bs=4M conv=fsync` + insert + cold boot reaches `$` prompt on serial + eDP FB (dual-sink) with **no operator input in between**.
5. `PAIDEIA_HW_SMOKE=1 tools/run-smoke-hw.sh all` passes against a captured serial log from the physical boot.
6. `tests/hw/expected-hw-boot-t14g4-full.txt` + `expected-hw-nvme-t14g4.txt` seeded (both currently empty / gated:hardware).
7. `design/hardware/quirks.md` PROVISIONAL rows §2.4 (VMD) + §2.5 (UART) promoted to CONFIRMED (or WORKED-AROUND with the specific workaround).
8. `design/round-retrospectives/r111-closure.md` written; `r111-closed` tag pushed; STATUS.md updated with R111 close block.

---

*Drafted 2026-09-07 by osarch. No issues filed. Awaits user approval + main-session dispatch per [[feedback-aissue-command]].*
