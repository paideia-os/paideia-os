# R47 Intel VMD hardware smoke — operator recipe (T14 G4)

**Owner issues:** #1420 (R47.M3-003, `gated:hardware`) — NVMe visible +
read/write on real VMD-on T14. #1426 (R47.M5-003, `gated:hardware`) —
end-to-end on real VMD-on T14 (probe + enumerate + config + msix + iommu
+ nvme).
**Status:** **UNSEEDED.** Every procedure below is written to be run on
a real ThinkPad T14 Gen 4 with the BIOS Intel VMD Controller setting
turned back ON, and no expected values are recorded, because recording
an expected value nobody measured is the failure this file exists to
avoid.

This follows the discipline of `tools/hw-smoke-r35-hotplug.md`,
`tools/hw-smoke-r34-isoch.md`, `tools/hw-smoke-r34.md`,
`tools/hw-smoke-r30.md` and `tools/hw-smoke-fingerprints.md`: the recipe
lands before first light, and the expectations are filled in from a
real capture, at which point the corresponding check promotes from SKIP
to LIVE.

---

## 0. Scope

This document is the operator-run recipe that promotes the VMD substrate
landed across R47.M1..M4 (issues #1412–#1423) from QEMU-OVMF structural
witnesses to real-hardware acceptance witnesses on the T14 G4. It
exercises the **VMD-on** BIOS configuration — the configuration
`design/hardware/quirks.md` §2.4 pinned as `SEVERITY: LOAD-BEARING` and
recommended DISABLED through R22..R46. R47 lifts that recommendation;
this recipe is the field verification.

The wires this smoke exercises:

- `src/kernel/core/drivers/vmd/probe.pdx` — VMD PCI class match +
  BAR extent decode, per Intel VMD spec §3.1.
- `src/kernel/core/drivers/vmd/endpoint_enum.pdx` — child endpoint
  enumeration through the virtual root complex.
- `src/kernel/core/drivers/vmd/root_complex.pdx` — ECAM-style
  aperture offset math for one child's config-space window.
- `src/kernel/core/drivers/vmd/msix_remap.pdx` — MSI-X translation
  from child vectors to host IRQ vectors.
- `src/kernel/core/drivers/vmd/hotplug.pdx` — attach/detach state
  transitions.
- `src/kernel/core/drivers/vmd/nvme_bridge.pdx` +
  `nvme_isolation.pdx` — R24 NVMe driver reuse on the virtual bus
  with per-endpoint queue-pair isolation.
- `src/kernel/core/drivers/vmd/iommu_domain.pdx` +
  `iommu_switch.pdx` — per-endpoint IOMMU domain assignment +
  in-flight switch bookkeeping.
- `src/kernel/core/cap/kind_vmd_endpoint.pdx` — KIND_VMD_ENDPOINT
  (0x185), one child endpoint's identity, derived over KIND_DEVICE.
- `src/kernel/core/ipc/vmd_config_channel.pdx` — the virtual
  config-space RPC schema.

None of the paths above are wired into `kernel_main_uefi` at boot —
they run only from the boot-witness chain in QEMU-OVMF
(`R30Platform`), which mints and scrubs its own synthetic fixtures.
There is no live PCIe binding that would attach the VMD probe to the
T14 G4's Intel VMD controller; that wiring is deferred.

---

## 1. Prerequisites

### 1.1 Hardware

- T14 G4 physical unit (Intel Raptor Lake, MVP target).
- An NVMe SSD in the M.2 slot the VMD controller aggregates. The
  factory Micron 2400 / Kioxia BG5 both apply.
- No dock required for this smoke.

### 1.2 BIOS Setup

- Enter BIOS Setup at boot (`F1` on Lenovo).
- Navigate to **Storage** or **Devices** — the exact path varies by
  BIOS revision.
- Set **Intel VMD Controller** to **Enabled**. This is the setting
  `design/hardware/quirks.md` §2.4 recommended DISABLED through
  R22..R46; R47 lifts that recommendation.
- Save and exit.

### 1.3 Software

- A build of paideia-os that includes every R47 landing (probe,
  enumerate, root complex, msix, hotplug, nvme bridge, nvme
  isolation, iommu domain, iommu switch, KIND_VMD_ENDPOINT,
  vmd_config_channel).
- A UEFI-bootable USB with the loader per
  `design/roadmap/r19-t14-g4-boot-guide.md`.

---

## 2. Procedure (M3 mid-round: NVMe visible + read/write)

1. Boot the T14 G4 from USB with VMD **Enabled**.
2. Watch the boot log for:
   - `R47 VMD PROBE OK`  — the controller is recognised.
   - `R47 VMD ENUM OK`   — at least one child was enumerated.
   - `R47 KIND_VMD_ENDPOINT OK` — the child cap was mintable.
3. Capture the observed member count and record it here:
   > **TODO on first light**: expected `member_count = <TBD>`.
4. Trigger the NVMe first-light path (via the R24 test harness pointed
   at the VMD-bridged controller). Record the fingerprint:
   `NVMEBRIDGE READ_BLOCKING SUCCESS`.
   > **TODO on first light**: fill in the expected LBA range and CRC.

## 3. Procedure (M5 end-to-end)

Runs the M3 procedure above, then:

5. Trigger a hot-unplug of the M.2 SSD via BIOS (or, if unavailable
   in hardware, via a controlled DEATTACH event on the same virtual
   endpoint). Record `R47 VMD HOTPLUG OK` (fingerprint of the
   dormant witness under a live wire).
6. Re-plug and verify a fresh `KIND_VMD_ENDPOINT` mint targets the
   same vbdf.
7. Verify IOMMU domain assignment is per-endpoint (the R47.M4
   ledger reports one distinct dma_domain per endpoint row) and
   record `R47 VMD IOMMU DOMAIN OK` under a live wire.

---

## 4. Expected fingerprints (all UNSEEDED)

- `R47 VMD PROBE OK` (source: `probe_synth.pdx`)
- `R47 VMD ENUM OK` (source: `endpoint_enum_synth.pdx`)
- `R47 KIND_VMD_ENDPOINT OK` (source: `vmd_endpoint_synth.pdx`)
- `R47 VMD ROOT COMPLEX OK` (source: `root_complex_synth.pdx`)
- `R47 VMD MSIX REMAP OK` (source: `msix_remap_synth.pdx`)
- `R47 VMD HOTPLUG OK` (source: `hotplug_synth.pdx`)
- `R47 VMD NVME BRIDGE OK` (source: `nvme_bridge_synth.pdx`)
- `R47 VMD NVME ISOLATION OK` (source: `nvme_isolation_synth.pdx`)
- `R47 VMD IOMMU DOMAIN OK` (source: `iommu_domain_synth.pdx`)
- `R47 VMD IOMMU SWITCH OK` (source: `iommu_switch_synth.pdx`)
- `R47 VMD IOMMU ADVERSARIAL OK` (source: `iommu_adversarial_synth.pdx`)
- `R47 VMD BIOS OFF OK` (source: `bios_off_fallback_synth.pdx`)
- `R47 VMD CONFIG CHAN OK` (source: `vmd_config_channel_synth.pdx`)

---

## 5. Promotion checklist

- [ ] Fill in `member_count` from field capture.
- [ ] Fill in NVMe LBA range + CRC.
- [ ] Promote `tests/kernel/drivers/vmd/hw_smoke_r47_placeholder.pdx`
      from a dormant stub to a live witness by registering it in a
      hardware-only witness chain (NOT in `R30Platform`).
- [ ] Close #1420 (M3 mid-round) with the M3 capture attached.
- [ ] Close #1426 (M5 end-to-end) with the M5 capture attached.

Until each item above is checked, both issues stay open with the
`gated:hardware` label, and the placeholder returns 0.
