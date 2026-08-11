# IOMMU Boot Toggle (Intel VT-d)

**Status:** Design + R22.M6 substrate landed; wire-up gated on R23
**Issue:** paideia-os#873
**Round / Milestone:** R22 / R22.M6-004
**Author (round-designer):** softarch (R22 close)

---

## 0. Purpose

The R22 rounds landed Intel VT-d substrate (M4: DMAR + register-set
+ root/context/SLPT + fault handler skeleton; M5: Interrupt
Remapping + IRT + IR-plane fault decoder) as compilable but
inert modules. No `GCMD.TE` write, no `SIRTP`, no live translation,
no interrupt remapping in effect. Devices continue to DMA to bare
host PAs and MSI/MSI-X messages continue to hit the LAPIC via
`0xFEE00000` without an IR handle indirection.

This document specifies the mechanism by which a future R23+
milestone flips the IOMMU from substrate-only to actually-enforcing,
and the R25+ migration from a compile-time flag to a runtime boot
command line.

## 1. R22.M6 mechanism: `Features.IOMMU_ENABLED`

The single MVP toggle is a compile-time constant defined in
`src/kernel/core/config/features.pdx`:

```
module Features = structure {
  pub let IOMMU_ENABLED : u64 = 0
  // 0 = VT-d substrate present but not brought online (R22.M6 default).
  // 1 = R23-experimental: full ceremony runs at boot.
}
```

Consumers reference it as `let flag : u64 = Features.IOMMU_ENABLED`
which resolves at assembly time — the branch to skip the ceremony
becomes an unconditional `jmp` after paideia-as constant-folds the
comparison. No `.data` footprint beyond the constant itself, no
per-boot branch penalty.

Flipping the flag requires a `tools/build.sh` rebuild. For MVP bring-up
this is acceptable: the primary use case is "R23 developer wants to
test the IOMMU-enabled path locally before landing the runtime
toggle", not "end user picks their preferred kernel config at boot".

## 2. Toggle values

| Value | State                                        | Shipping mode |
|-------|----------------------------------------------|---------------|
| `0`   | Substrate present, ceremony skipped          | R22.M6 default |
| `1`   | Full VT-d + IR enable at boot                | R23-experimental (not yet shipping) |

There is no `probe` value yet — probing (DMAR present? unit
capabilities?) already happens unconditionally under R22.M4 via
`dmar_parse_drhds` and `vtd_capabilities_dump`. The flag decides
whether to *act* on the probe result, not whether to *do* the probe.

R25+ may promote this to a 3-value enum (`off` / `probe` / `on`) once
the boot command-line parser lands and end-user configurability
matters. At R22.M6 the two-value form suffices.

## 3. R23 wire-up checklist

When R23 flips `IOMMU_ENABLED = 1`, the following code paths must
land in the same commit (or as a tight sequence with
`boot_r22_dma_fault_regression` as the acceptance gate):

1. **`phase1_acpi_gather` DMAR branch.** The R22.M4 `dmar.pdx` parser
   is symbol-linked but not yet called from `phase1_acpi_gather`.
   Wire the branch that populates `_phase1_acpi_info.has_dmar` +
   `_phase1_acpi_info.dmar.unit_base` from the DMAR ACPI table.

2. **`_vtd_base` population.** R22.M4 hardcoded `_vtd_base = 0xFED90000`
   as an Intel PCH MVP anchor. Replace with
   `_vtd_base = _phase1_acpi_info.dmar.unit_base` from step 1.

3. **`vtd_root_init` + `vtd_context_program` sweep.** For each
   published `KIND_PCI_DEV` cap (R22.M3), program its context-entry
   to point at a per-device SLPT root (initially identity-mapping
   the device's DMA buffers via `vtd_slpt_map`).

4. **`vtd_set_root` + `GCMD.TE` ceremony.** Write `RTADDR_REG`,
   edge-trigger `SRTP`, poll `GSTS.RTPS`, then set `GCMD.TE` and
   poll `GSTS.TES`. Order matters: `SRTP` must land before `TE`.

5. **Context-cache + IOTLB invalidation.** After `SRTP`, issue a
   global context-cache invalidation (`CCMD_REG` write with
   CIRG=global) and a global IOTLB invalidation (`IOTLB_REG` write
   with IIRG=global). Poll for completion via the respective
   invalidation-completion bits.

6. **`vtd_ir_init` + `SIRTP` + IRE ceremony.** R22.M5 substrate is
   ready; wire it into `kernel_main_uefi` after step 5. IRT-alloc
   at `_vtd_irt_va`; `IRTA_REG` write with `S=7`, `EIME=1`; edge-
   trigger `SIRTP`, poll `GSTS.IRTPS`; set `GCMD.IRE`, poll
   `GSTS.IRES`.

7. **`vtd_fault_dispatch` IDT wire.** Allocate a per-CPU vector from
   the R21.M4 vector pool (`vector_alloc_for_cpu`), program it into
   the VT-d fault-recording interrupt (`FEDATA_REG` +
   `FEADDR_REG`), and register the vector's IDT handler pointing at
   `vtd_fault_dispatch`. AP-side install mirrors the R14 KPTI-IDT
   AP-install pattern.

8. **Retire the SKIP guard in `dma_fault_regression.pdx`.** Once
   steps 1–7 land, flip the witness from SKIP mode to LIVE mode by
   deleting the M6 `if (Features.IOMMU_ENABLED == 0) return SKIP;`
   guard. The witness now fabricates BDF 0:1:0 with a bounded SLPT,
   triggers a deliberate out-of-domain DMA, and expects `FRR_REG`
   reason `0x22`.

9. **MSI-X → IR re-routing sweep.** Every existing `msix_program_entry`
   callsite (R21.M4 substrate) switches to `msix_program_entry_via_ir`
   (R22.M5 substrate) so all MSI/MSI-X message addresses go through
   the IR unit. R21.M4 non-IR path becomes a legacy fallback for
   `IOMMU_ENABLED = 0` boots.

## 4. R25+ migration to runtime boot command-line

The R22.M6 compile-time flag is a stepping stone. The full paideia-
native design (per `design/roadmap/r18-plus-bare-metal.md` §Pillar 5
sub-item "boot configurability") is:

- **UEFI path:** `boot_env.command_line : *u8` populated from the
  UEFI `LoadOptions` blob passed to `Image->LoadImage`. Kernel
  parses key=value pairs into a bounded slot in `_kernel_config`.
- **Multiboot2 path (legacy BIOS bring-up, not scoped to MVP):**
  `boot_env.command_line` populated from multiboot2 tag type 1
  (bootloader command line).
- **In-kernel parser:** simple `paideia.iommu=on|off|probe` grammar,
  with unknown keys ignored + logged via `klog_s1`.

The migration lands under R25 (userspace-init argument-passing
substrate) as a single commit that:

1. Adds `boot_env.command_line` slot + parser.
2. Rewrites `Features.IOMMU_ENABLED` from a compile-time constant to
   a runtime `_features_active` slab populated at boot from the
   parsed command line.
3. Deletes the compile-time constant in favor of the runtime slab.

Consumers change from `let flag = Features.IOMMU_ENABLED` (compile-
time) to `let flag = Features.get(FEATURE_IOMMU_ENABLED)` (runtime
read of the slab). The change is mechanical and localized to
consumers that reference the flag.

## 5. Testing matrix

Regression matrix once `IOMMU_ENABLED = 1` ships:

| Mode                 | Flag | boot_smp | boot_r22_pci_tree | boot_r22_dma_fault |
|----------------------|------|----------|-------------------|--------------------|
| M6 shipping (R22)    | `0`  | PASS     | PASS (SKIP)       | PASS (SKIP)        |
| R23 experimental     | `1`  | PASS     | PASS (device list)| PASS (LIVE OK)     |
| R23 rollback         | `0`  | PASS     | PASS (SKIP)       | PASS (SKIP)        |

The rollback row is load-bearing: R23's landing must preserve the
ability to build with `IOMMU_ENABLED = 0` and get an M6-equivalent
kernel. This is the "single-commit-revert boundary" property that
matches the R21.M5 x2APIC substrate discipline (substrate first,
enable later, both reversible).

## 6. Rationale

Why land the toggle at M6 rather than at R23 kickoff?

1. **Preflight surface for R23.** R23's first task is to consume the
   toggle. Landing the toggle now lets R23's design work reference
   a concrete `Features.IOMMU_ENABLED` symbol instead of a proposed
   one.

2. **Migration-path documentation.** The R25+ runtime-command-line
   migration path is easier to document + agree upon when the R22
   compile-time flag exists as an anchor. §4 above is concrete
   because §1 is concrete.

3. **DMA-fault regression fixture symmetry.** The R22.M6 witness at
   `tests/kernel/iommu/dma_fault_regression.pdx` needs a flag to
   check for its SKIP/LIVE dispatch. That flag is `IOMMU_ENABLED`.
   Landing the fixture without the flag would require the fixture
   to inline its own `if (0) …` sentinel — brittle and inconsistent
   with the design-doc-first R22 discipline.

## 7. Related documents

- `design/round-retrospectives/r22-closure.md` §"Preflight for R23"
  — the milestone that flips the flag.
- `src/kernel/core/config/features.pdx` — the flag registry (single
  source of truth for `IOMMU_ENABLED`).
- `tests/kernel/iommu/dma_fault_regression.pdx` — the M6 witness
  that the flag gates.
- `src/kernel/core/iommu/*` — R22.M4/M5 substrate that the flag
  brings online.
- `design/roadmap/r18-plus-bare-metal.md` §R23 — the next round
  where R23-experimental transitions to R23-shipping.
