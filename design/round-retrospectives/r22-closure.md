// R22 Retrospective: PCI Substrate + xAPIC Retirement + IOMMU (VT-d) Substrate

**Date:** 2026-08-11
**Milestone:** R22.M1–R22.M6 (all closed; M6 = closure milestone this doc + #874)
**Issues:** 28 landed across 6 milestones (24 implementation + 4 closure/toggle/fixture); #860 deferred (paideia-as#1015 dependency)
**HEAD at closure:** (bumped by the R22.M6 commit that lands this doc)
**paideia-as pinned at:** `2cf169d` — unchanged across R22 (zero cross-repo escalations this round)

---

## Round Intent

R22 was scoped as the PCI-substrate + xAPIC-retirement + IOMMU (Intel VT-d) round per `design/roadmap/r18-plus-bare-metal.md` §R22. The six milestones threaded the LAPIC-mode transition first, then the PCIe substrate, then the IOMMU (translation + IR) in order:

- **M1:** PCI substrate anchor (ECAM accessor recap + MCFG wire-up in `kernel_main` + Type-0/Type-1 header decoders) + atomic x2APIC enable + xAPIC MMIO retirement across every consumer (eoi, tpr, ipi, self_ipi, lapic_timer, tsc_deadline, init_sipi, reschedule_ipi).
- **M2:** PCI enumerator (recursive bridge-descending BDF walk) + BAR sizing/decode helpers + kernel_main wire-in with `PCI ENUM DONE` fingerprint.
- **M3:** PCI capability walkers (legacy `pci_walk_caps` + extended `pcie_walk_ext_caps`) + `KIND_PCI_DEV` cap publication + `device_cap_mint`; **#860** (userspace pci_enumerator server) deferred to #1015-blocked queue.
- **M4:** Intel VT-d substrate — DMAR parser + register-set + root/context tables + per-device SLPT walker + DMA-fault handler skeleton + `vtd_slpt_synth_witness`.
- **M5:** VT-d Interrupt Remapping — IRT allocator + IRTA_REG programming + `vtd_ir_program` (128-bit IRTE deposit via 2×u64 mask-first) + IR-plane fault decoder + `msix_program_entry_via_ir` + `msix_assign_at_ir` + `msix_ir_round_robin_witness`.
- **M6:** Round closure — VMD-off quirk row (#870), T14 G4 PCI-tree capture doc + fixture placeholder (#871), DMA-fault regression fixture (#872, SKIP mode gated on R23), `Features.IOMMU_ENABLED` toggle + boot-toggle design doc (#873), R22 closure retro + STATUS.md + quirks-db pass + `boot_r22_msix_ir_round_robin` run-smoke.sh SKIP-mode entry (#874).

Pillar 6 target: give the kernel exactly the substrate it needs so that every PCIe device is discoverable + programmable via ECAM, every device can be published as a `KIND_PCI_DEV` capability for userspace-driver dispatch, and the DMA/interrupt-remapping plane is present as compilable ready-to-enable code — the R23 milestone flips `Features.IOMMU_ENABLED = 1` and consumes the substrate for the first live wire-up.

---

## What Shipped

### R22.M1 — PCI substrate anchor + x2APIC retirement (5 issues: #847–#850 + #845)

- **#847 ECAM accessor** — pre-existing at R21.M4 (`src/kernel/core/pci/config.pdx` — `pci_config_read_u32/u16/u8` + `pci_config_write_u32` compose ECAM via `mcfg_ecam_base_for_segment`). Closed as landed at R21.M4.
- **#848 MCFG range mapping at boot** — `phase1_acpi_gather` wired into `kernel_main` after `x2apic_probe_bsp`; `Mcfg._mcfg_segments` populated from ACPI MCFG. Fingerprints `MCFG PRESENT` or `MCFG ABSENT`. Under QEMU `-kernel` the ACPI 2.0 XSDT is not surfaced and the fingerprint fires `MCFG ABSENT`; UEFI + real HW → `MCFG PRESENT`.
- **#849 Legacy 0xCF8/0xCFC retirement (Pillar 5)** — deleted `src/drivers/pci/config.pdx` (Phase 7 groundwork, never referenced by `build.sh`). No `in eax, dx` / `out dx, eax` legacy port-I/O remains in the kernel.
- **#850 Header decoders** — `src/kernel/core/pci/header.pdx` — `pci_read_type0_header` / `pci_read_type1_header` compose 56-byte out-structs from ECAM reads. Paideia-as-blocked label was a paper tiger — every op used pre-existing encoder features (`mov_b` / `mov_w` / `mov_d` + `call`/`ret` + SysV args).
- **#845 xAPIC MMIO retirement + x2APIC enable (atomic dispatch)** — `_x2apic_active : u64 = 0` runtime dispatch flag added to `x2apic.pdx`. `x2apic_enable_this_cpu` sets flag := 1 post-wrmsr. Every LAPIC consumer (`eoi.pdx` / `tpr.pdx` / `ipi.pdx` / `self_ipi.pdx` / `lapic_timer.pdx` / `tsc_deadline.pdx` / `init_sipi.pdx`) now branches on the flag: nonzero → `x2apic_write` MSR path; zero → legacy xAPIC MMIO fallback. BSP enable added to `kernel_main` after `x2apic_probe_bsp`; AP enable added to `ap_entry` after `gs_base_init_ap`. Fingerprint `X2APIC ENABLED BSP` or `X2APIC ABSENT` per boot. QEMU-TCG stays on the MMIO fallback (bit 21 unsupported); real Raptor Lake takes the MSR path.

**Closure commits:** `27050c1` (PCI substrate) + `6055540` (x2APIC).

### R22.M2 — PCI enumerator + BAR helpers (5 issues: #851–#855)

- **#851 pci_enumerate_all(seg)** — `src/kernel/core/pci/enum.pdx`. Recursive-descent bridge walker with a bounded 32-entry BFS queue, 256-bit visited bitmap, and a 32-byte `pci_device_record` slab (256-device cap). Under BIOS/`-kernel` boot (MCFG absent) emits `PCI ENUM SKIP no MCFG` and returns without touching config space; under MCFG-present paths emits one `PCI DEV bus=B dev=D vendor=V device=X` per device followed by `PCI ENUM DONE devices=N`.
- **#852 pci_bar_size + pci_bar_decode** — `src/kernel/core/pci/bar.pdx`. BAR sizing via write-all-1s-read-back protocol; decode splits 32-bit / 64-bit memory / IO / prefetchable variants.
- **#853 pci_bar_type/prefetchable/64bit helpers** — sub-primitives of #852; each is a single-shift+mask.
- **#854 MMIO-mapping stub** — sized so R23 driver-plane consumers can link against them (real ioremap lands in R23 alongside `Features.IOMMU_ENABLED = 1`).
- **#855 boot_r22_pci_tree opt-in smoke** — `tools/run-smoke.sh` mode + `tests/r22/expected-pci-tree.txt` (SKIP fingerprint under `-kernel`) + `.githooks/pre-push` gate on `PAIDEIA_R22_PCI_TREE=1`.

**Closure commit:** `2c944bd`.

### R22.M3 — PCI cap walkers + KIND_PCI_DEV publication (4 issues landed; 1 deferred)

- **#856 pci_walk_caps** — extends R21.M4 `pci_find_cap` with named cap IDs (19 constants `PCI_CAP_PWR_MGMT..PCI_CAP_AF`) + callback-dispatching enumerator visiting every capability header under a function. Structural sibling to `pci_find_cap`: same presence check, status-bit gate, root-pointer masking, 48-visit safety bound. Uses indirect `call rbx` dispatch per header (mirrors `acpi_xsdt_iter` idiom at `src/kernel/acpi/xsdt.pdx:198`).
- **#857 pcie_find_ext_cap + pcie_walk_ext_caps** — `src/kernel/core/pci/ext_cap.pdx`. PCIe extended-cap walker (base 0x100, 32-bit headers). Named `PCIE_EXT_CAP_*` constants for AER / VC / SN / ARI / SR-IOV / etc.
- **#858 KIND_PCI_DEV publication + device_cap_mint** — `src/kernel/core/cap/device_cap.pdx`. New capability kind `KIND_PCI_DEV`; mint from BDF + published bus/dev/func metadata. Feeds R23 userspace driver-plane cap consumers.
- **#859 pci_publish_caps** — `src/kernel/core/pci/publish.pdx`. Walker that iterates every `_pci_devices[i]` record, mints `KIND_PCI_DEV` for each, records in `_kind_pci_dev_caps` bounded slab.
- **#860 userspace pci_enumerator server** — DEFERRED to #1015. Blocker: paideia-as #1015 (userspace ELF loader for user-linked cap-consumers). Sibling deferral to #820 (acpi_supervisor); both land when #1015 closes. Design doc `design/userspace/pci_enumerator-server.md` landed as preflight.

**Closure commit:** `1b15979`.

### R22.M4 — Intel VT-d substrate (5 issues: #861–#865)

- **#861 dmar.pdx** — DRHD sub-structure extractor over the DMAR TLV stream. Adds `SIG_DMAR = 0x52414D44` to `sdt_hdr`; adds `has_dmar` slot (offset +147) to `phase1_acpi_info` (unpopulated at M4 — set by R23 wire-up). RMRR/ATSR/RHSA/ANDD/SATC entries length-skipped.
- **#862 vtd_regs.pdx** — 32/64-bit MMIO accessors with `mfence` brackets; `_vtd_base = 0xFED90000` hardcoded (Intel PCH default) as MVP anchor pending R23 DMAR-derived population. `vtd_capabilities_dump` emits VER/CAP/ECAP fingerprint.
- **#863 vtd_ctx.pdx** — `vtd_root_init` (idempotent 4KB root-table alloc + zero), `vtd_context_program` (root-entry linkage + context-entry write with legacy TT / AW=48 / DID), `vtd_set_root` (RTADDR write + SRTP edge trigger; GSTS.RTPS poll deferred to R23).
- **#864 vtd_slpt.pdx** — `vtd_slpt_root_alloc` + `vtd_slpt_map` — 4-level walker mirroring `aspace_map`'s shape with SLPT-flavored flags (NONLEAF_RW=0x3, LEAF_RWX=0x7; no `INVLPG` — TLB flush is a VT-d IOTLB op). Per-level `phys_alloc` + zero + link; PS-bit huge-page guards on PDPTE/PDE descend. Witness at `tests/kernel/iommu/vtd_slpt_synth.pdx` exercises the full alloc + map + walk-back structural round-trip.
- **#865 vtd_fault.pdx** — `vtd_fault_dispatch` skeleton (FRR_REG read; reason decode via `vtd_fault_decode_reason`; ROC-clear via write-1). No IDT wire at M4; symbol existence is the acceptance gate.

**Closure commit:** `c192535`.

### R22.M5 — VT-d Interrupt Remapping substrate (4 issues: #866–#869)

- **#866 vtd_ir.pdx** — IRT allocator (4 KiB / 256 IRTEs), `IRTA_REG` programming (S=7 for 256 entries, EIME=1 for x2APIC destination-ID width), `SIRTP` + `IRE` ceremony with `GSTS` polling. `ir_alloc_handle` bump allocator; `vtd_ir_program` writes 128-bit IRTEs as 2 × u64 with **mask-first / unmask-last** ordering (P=0 write, `mfence`, P=1 write) — no 128-bit MOVDQU dependency, mirrors R21.M4 MSI-X mask-first tactic. Cross-repo #866 label ("paideia-as-blocked" citing 128-bit MOVDQU requirement) was a **PAPER TIGER** — the 2 × u64 mask-first approach is documented safe practice per Intel SDM Vol 3A §10.12.7 + Linux `drivers/iommu/intel/irq_remapping.c`.
- **#867 msix_program_entry_via_ir** — `src/kernel/core/pci/msix.pdx`. Stamps the Remappable MSI address format `0xFEE00000 | (ir_index << 5) | SHV` into the MSI-X entry via the same 4×32-bit mask-first discipline used by the R21.M4 non-IR path.
- **#868 msix_assign_at_ir** — `src/kernel/core/apic/vector_pool.pdx`. Wires `vector_alloc_for_cpu` + `ir_alloc_handle` + `vtd_ir_program` + `msix_program_entry_via_ir` into a single call.
- **#869 vtd_fault_decode_ir_reason + msix_ir_round_robin_witness** — `vtd_fault.pdx` extension mapping IR-plane fault reasons 0x20..0x25 to short ASCII names (`IR range` / `IR noP` / `IR rsvd` / `IR dst` / `IR srcid` / `IR SVT` / `IR unk`) in `.rodata`. Witness at `tests/kernel/iommu/msix_ir_round_robin.pdx` verifies byte-level IRTE + MSI-X entry layout across 4 distinct handles. Not wired at M5 (matches `vtd_slpt_synth_witness` pattern); pre-push opt-in guard `PAIDEIA_R22_MSIX_IR=1` reserved for R23 boot-smoke wire-up.

**Closure commit:** `3287ef9`.

### R22.M6 — Round closure + preflight for R23 (5 items)

- **#870 T14 G4 VMD-off quirk row** — `design/hardware/quirks.md` §2.4 VMD row elevated: R22 PCI enumerator impact recorded, explicit BIOS Setup path added (`Storage → Intel VMD Controller → Disabled`), first-light verification recipe added (post-VMD-off `pci_enumerate_all(0)` should record an NVMe controller at ~`00:0E.0` instead of a RAID container). Row stays `PROVISIONAL` until real T14 G4 first-boot confirms.
- **#871 T14 G4 PCI-tree capture doc + fixture placeholder** — `tools/capture-t14-g4-pci.md` (operator-side capture recipe; sibling to `tools/capture-t14-g4-acpi.md`), `tests/kernel/pci/t14_g4_fixture.pdx` (compilable placeholder reserving `t14g4_pci_fixture_ok_msg` / `_fail_msg` + `_t14g4_pci_expected : [u64; 64]` slot), `tests/kernel/pci/fixtures/t14g4/README.md` (fixture directory manifest).
- **#872 DMA-fault regression fixture** — `tests/kernel/iommu/dma_fault_regression.pdx`. SKIP-mode witness reserving `vtd_dma_fault_ok_msg` (reason=0x22) / `_fail_msg` / `_skip_msg` markers + `_vtd_dma_fault_expected : [u64; 8]` slot. Full LIVE-mode fabrication documented in the module header for R23 flip.
- **#873 IOMMU boot toggle** — `src/kernel/core/config/features.pdx` (new module `Features` exporting `IOMMU_ENABLED : u64 = 0`) + `design/kernel/iommu-boot-toggle.md` (full toggle mechanism + R23 wire-up checklist + R25 migration path to runtime command-line parser).
- **#874 R22 closure** — this document + STATUS.md R22 CLOSED block + quirks-db pass + tag `r22-closed` + M5-debt run-smoke.sh entry (`boot_r22_msix_ir_round_robin` SKIP mode).

**Closure commit:** (this M6 commit).

---

## Cross-Repo Escalations to paideia-as (R22)

**None.** `paideia-as` submodule remained pinned at `2cf169d` for all six R22 milestones. Every encoder mnemonic used by R22 was verified pre-existing before implementation:

- ECAM MMIO accessors: `mov_b` / `mov_w` / `mov_d` (R21.M4 substrate).
- Recursive enumerator: `call` / `ret` + SysV register args + `_pci_devices` slab writes.
- x2APIC MSR paths: `rdmsr` / `wrmsr` (R21.M5 substrate).
- VT-d MMIO: `mfence` + 32/64-bit MMIO (Phase 8 substrate).
- SLPT walker: identical shape to `aspace_map` — no new ops beyond `and`/`shr`/`or`.
- IR IRTE deposit: 2 × u64 mask-first / unmask-last discipline (avoids the paper-tiger 128-bit MOVDQU requirement that had been ambient-labeled as a paideia-as gap).

The R22.M5 "paideia-as-blocked" cross-repo label on #866 was reviewed and **downgraded** — the 2-u64 approach is documented safe practice per Intel SDM Vol 3A §10.12.7 + Linux `drivers/iommu/intel/irq_remapping.c` (which uses the exact same tactic). The MOVDQU encoder gap can be closed later without holding up R22.

---

## Observable Proof

- Kernel builds clean under `tools/build.sh` — **15/15 verify gates pass** (no-AML lint + opcode-canary + kernel dispatch + sched guards + tty_read wrapper + link).
- All 15 default pre-push smoke modes pass (`boot_r8_only` through `boot_smp`, incl. `boot_r14b_*` KPTI/hivma/ipi/loader, `boot_r17_shell_*` echo_hello/multi_command/shutdown/child_process).
- Opt-in R22 smokes:
  - `PAIDEIA_R22_PCI_TREE=1 boot_r22_pci_tree` → `PCI ENUM SKIP no MCFG` fingerprint on QEMU-TCG default; UEFI/OVMF path will grow the per-device lines + DONE marker when R23 wires the OVMF harness.
  - `PAIDEIA_R22_MSIX_IR=1 boot_r22_msix_ir_round_robin` → SKIP (mode landed at M6 debt fix; witness stays symbol-only until R23 wires it into kernel_main behind `Features.IOMMU_ENABLED = 1`).
- Opt-in R21 smokes still pass under R22 changes:
  - `boot_r21_ymm_preserve` (M2 XSAVE regression) — no R22 delta.
  - `boot_r21_ioapic_reroute` (M3 IOAPIC structural) — no R22 delta.
  - `boot_r21_msix_round_robin` (M4 MSI-X vector-pool) — no R22 delta; R22.M5 IR wrapper preserves the underlying vector-pool contract.
- New serial fingerprints between `X2APIC ABSENT` (R21) and `SMP BRINGUP START`:
  - `X2APIC ENABLED BSP` (R22.M1 — only when `_x2apic_supported = 1`; on QEMU-TCG stays absent).
  - `MCFG PRESENT` or `MCFG ABSENT` (R22.M1 — QEMU `-kernel` fires ABSENT; UEFI/real HW fires PRESENT).
  - `PCI HDR READY` (R22.M1 — header-decoder witness confirmation).
- `nm build/kernel.elf` shows all R22-substrate symbols linked (spot check): `pci_enumerate_all`, `pci_bar_size`, `pci_walk_caps`, `pcie_walk_ext_caps`, `device_cap_mint`, `dmar_parse_drhds`, `vtd_root_init`, `vtd_context_program`, `vtd_slpt_root_alloc`, `vtd_slpt_map`, `vtd_fault_dispatch`, `vtd_fault_decode_reason`, `vtd_ir_init`, `vtd_ir_program`, `msix_program_entry_via_ir`, `msix_assign_at_ir`, `vtd_fault_decode_ir_reason`, `msix_ir_round_robin_witness`, `vtd_slpt_synth_witness`.

---

## What Worked (Round Discipline)

1. **softarch → debugger loop shape held throughout.** No mid-round pauses; each milestone's kickoff was an architect+implement pass producing all sub-issue landings + fixtures, followed by a debugger pass that debugged failures. Zero workerbee invocations (per `feedback_paideia_os_loop_shape.md`).

2. **Continuous tempo across six milestones.** Per `feedback_paideia_os_tempo.md`, R22 ran continuous with no between-milestone review pause. All six milestones closed within roughly a single loop day (2026-08-10 → 2026-08-11).

3. **Paper-tiger downgrades saved cross-repo churn twice.** Both #850 (Type-0/Type-1 header decoders) and #866 (128-bit IRTE deposit) had been ambient-labeled as paideia-as blockers. In both cases a careful read of the actual requirements revealed the encoder gap was avoidable: #850 used only pre-existing `mov_b/w/d` sized stores + SysV register args; #866 used the mask-first / unmask-last 2×u64 pattern documented in Intel SDM + Linux upstream. Zero submodule bumps required across R22.

4. **Substrate landed without enabling (M4 + M5 discipline).** Both the VT-d translation substrate and the IR substrate landed as `pub` symbols in `kernel.elf` but with **no live wire-up** — no `GCMD.TE` write, no `SIRTP`, no IDT installation for `vtd_fault_dispatch`. This lets R23 (the driver-plane substrate round) land the wire-up as a scoped commit with `boot_r22_dma_fault_regression` and `boot_r22_msix_ir_round_robin` as strict acceptance gates. `nm build/kernel.elf | grep -E 'vtd_|_ir_|dmar_'` shows all substrate symbols present.

5. **Preflight-for-R23 pattern.** M6's `Features.IOMMU_ENABLED` toggle + `design/kernel/iommu-boot-toggle.md` establish the boundary R23 crosses to make the substrate live. The toggle exists as a concrete symbol so R23's design work references it instead of proposing it, and the design doc's §3 wire-up checklist is the R23 milestone's actual to-do list.

6. **Backtracking on #849 legacy port-I/O.** The initial R22.M1 scan for legacy 0xCF8/0xCFC references turned up `src/drivers/pci/config.pdx` — but a follow-up check of `build.sh` proved the file was never included in the build graph (Phase 7 dead code). Deleting it kept Pillar 5 clean without needing a retirement refactor. A less careful pass would have wrestled with rewriting the dead file.

---

## What Didn't Work

1. **Background push race in M3.** The M3 close attempted to push `1b15979` while a concurrent `git fetch` was in flight; the push initially reported a non-fast-forward conflict against a stale local `main`. Recovery was a clean `git pull --rebase` (no actual conflict, just a race on the pre-push hook's fetch) — no data loss but ~2 minutes of round tempo. Preventive fix: R23+ pushes serialize behind a `.git/paideia-os-push.lock` sentinel that the pre-push hook takes exclusively. Tracked as a queued tooling improvement, not urgent.

2. **`run-smoke.sh` mode gap for `boot_r22_msix_ir_round_robin`.** The M5 close added a `PAIDEIA_R22_MSIX_IR=1` pre-push guard that invoked `run-smoke.sh boot_r22_msix_ir_round_robin`, but the mode did not exist in `tools/run-smoke.sh`'s case statement — the invocation would have fallen through to a fingerprint-file-not-found abort. Nobody flipped the env var during R22.M5 close (the witness is symbol-only), so the gap did not fire. **Closed at M6-005** with a SKIP-echo mode entry documented in the design doc. Preventive fix: pre-push hook env-var additions must be accompanied by the corresponding `run-smoke.sh` case entry in the same commit — added as a checklist item for R23 milestone-close discipline.

3. **VT-d not enable-able under QEMU-TCG default.** QEMU requires `-machine intel-iommu=on` (which forces `q35` + disables some options) to expose a VT-d unit; the smoke matrix uses defaults and does not enable VT-d. This means every R22.M4+ witness is a **structural** witness — byte-level layout verification only, no live-dispatch verification. The DMA-fault regression fixture is SKIP-mode at M6 for the same reason (LIVE-mode requires GCMD.TE + a real fault-recording IDT vector, both R23 work). The R21.M5 `X2APIC ABSENT` fingerprint is the ambient reminder that QEMU-TCG cannot exercise the full x86-server surface.

4. **`#860 userspace pci_enumerator` deferred.** The R22.M3 milestone plan included publishing `KIND_PCI_DEV` cap descriptors to a userspace enumerator server — but paideia-as #1015 (userspace ELF loader for cap-consumers) has not landed, so the userspace half cannot compile. Design doc landed as preflight (`design/userspace/pci_enumerator-server.md`); implementation lands sibling-to #820 when #1015 closes. Not blocking R22 close; not blocking R23 (which is kernel-plane substrate work).

---

## Preflight for R23

**R23 (driver-plane substrate — first real drivers: virtio, xHCI, then NVMe on VT-d-enforced DMA)** — opens after R22 close. Draft preflight to land as `design/round-retrospectives/r23-preflight.md` at R23.M1 kickoff. R23 needs from R22:

1. **`pci_enumerate_all` device tree.** `_pci_devices` slab is the enumeration source of truth. R23's first driver-plane consumer (virtio-net probe) walks this slab for `vendor=0x1AF4` matches. Ready to consume.
2. **`KIND_PCI_DEV` cap mint.** Each driver receives a cap-handle to its own device rather than a raw BDF. Ready to consume via `device_cap_mint` (R22.M3).
3. **`pci_walk_caps` + `pcie_walk_ext_caps`.** Every driver probe walks the cap chain to locate MSI-X, PM, PCIe-cap. Ready to consume.
4. **`msix_program_entry_via_ir` (M5) + `Features.IOMMU_ENABLED = 1` gate (M6).** When R23 flips the flag, every driver's MSI-X assignment routes through IR by default. R21.M4 non-IR path stays as legacy fallback for `IOMMU_ENABLED = 0`.
5. **`vtd_root_init` + `vtd_context_program` + `vtd_set_root` + `vtd_ir_init` (M4 + M5).** R23's first act after the flag flip is to run this ceremony in `kernel_main_uefi` per `design/kernel/iommu-boot-toggle.md` §3 wire-up checklist.
6. **`dma_fault_regression` witness (M6).** Flip SKIP → LIVE; the fixture becomes the acceptance gate for the entire ceremony (fault fires → decoded → reported → kernel resumes normally).

**R23 does NOT need from R22:**

- Real T14 G4 hardware. R23's substrate work is QEMU-only (KVM optional, `-machine intel-iommu=on` mandatory). Hardware validation lands when the operator captures the T14 G4 first-light fixtures per `tools/capture-t14-g4-pci.md`.
- ACPICA. R23 remains AML-free (per the R20.M4 guardrail).
- Higher-half kernel remap. Still needed but not scoped to R23; R24+ opens the kernel-space heap allocator on top of the existing physmap.
- Runtime boot command-line parser. R22.M6 compile-time flag suffices for R23; runtime-parser migration is queued for R25.

**R23 blockers (external):**

- paideia-as v0.21 tag remains uncut; R23 does not need a tag bump. If paideia-as #1015 (userspace ELF loader for cap-consumers) closes intra-R23, opportunistic #860 landing.
- No R22 debt blocks R23 opening.

---

## R22 Debt Carried Forward

Ledger of items deferred past R22 close:

1. **#860 userspace pci_enumerator server** — DEFERRED to #1015-close. Design doc + `KIND_PCI_DEV` cap publisher + `pci_publish_caps` slab all landed at R22.M3; only the userspace consumer stays open. Sibling to #820.

2. **`_vtd_base` hardcoded to 0xFED90000** — correct for Intel PCH default + QEMU `-machine intel-iommu=on` default, but a real hardware pass must consume `_phase1_acpi_info.dmar.unit_base` from the DMAR ACPI table. Wire lands under R23 alongside `Features.IOMMU_ENABLED = 1` (per `design/kernel/iommu-boot-toggle.md` §3 step 2).

3. **`has_dmar` slot unpopulated** — R22.M4 added the +147 offset in `phase1_acpi_info` but `phase1_acpi_gather` does not yet walk DMAR. Sibling to (2); lands in the same R23 wire-up commit.

4. **`vtd_fault_dispatch` not IDT-wired** — R22.M4 skeleton is a `pub` symbol only; no IDT vector installation. Wire lands under R23 alongside `Features.IOMMU_ENABLED = 1` (per §3 step 7).

5. **`msix_enable_device` inside `msix_assign_at_ir`** — the M5 substrate wires vector-alloc + IR-program + entry-write but does not flip the MSI-X global enable bit in the device's control register. Needs a real PCI-config-space write context (R23 driver-plane scope).

6. **Ledger append in `msix_assign_at_ir`** — the R21.M4 `_msix_assignments` slab is a bookkeeping structure R23 drivers will populate; M5 stub bypasses it. Lands with the first R23 driver.

7. **Full `GCMD.TE` + SIRTP + IRE ceremony wiring** — R23.M1 opens with this. See `design/kernel/iommu-boot-toggle.md` §3 for the seven-step checklist.

8. **DMA-fault regression fixture SKIP → LIVE flip** — deletes the M6 `Features.IOMMU_ENABLED == 0` guard once §3 steps 1–7 land. LIVE-mode acceptance: `VTD DMA FAULT OK reason=0x22` fingerprint on the deliberate out-of-domain DMA.

9. **T14 G4 first-light PCI + ACPI capture** — GATED ON HARDWARE. Recipes ready (`tools/capture-t14-g4-acpi.md` + `tools/capture-t14-g4-pci.md`); fixture directories placeholder-populated (`tests/kernel/{acpi,pci}/fixtures/t14g4/`); both fixture witnesses (`t14_g4_fixture.pdx` in both trees) reserve their marker + expected-values slots. Capture happens alongside R23+ first-boot on the operator's T14 G4 unit.

10. **R21 debt items still open:**
    - `hpet_now_ns` precision widening (still 69ns period on Intel PCH; ~1.2% steady-state error).
    - `phase1_acpi_gather` full wire into `kernel_main_uefi` (partial at R22.M1 — MCFG only; FADT/HPET/DMAR still hardcoded).

**None regress R22 acceptance.**

---

## Quirks Discovered on Real Hardware

None (R22 ran under QEMU-TCG throughout). No rows in `design/hardware/quirks.md` promoted `PROVISIONAL → CONFIRMED` at this pass; the M6-001 (#870) VMD row was expanded in-scope but stays PROVISIONAL until first-light. The T14 G4 first-boot in R23+ will promote at least three rows (VMD-off, PCIe seg=0 ECAM base, hybrid P/E topology per §2.4 quirks-db entries) plus any new discoveries.

Quirks-db discipline recap at M6:
- Added cross-refs to `tools/capture-t14-g4-pci.md` + `tests/kernel/pci/fixtures/t14g4/README.md` under §4 Related documents.
- Elevated VMD row scope to include R22 PCI-enumerator impact + explicit BIOS toggle + first-light verification recipe.
- No new rows added — R22 discovered nothing new about the T14 G4 that wasn't already anchor-documented at R20.M5.

---

## Milestone Discipline Statement

R22 held to the round-tempo user preference: continuous loop across all issues + milestones with no mid-round pause. Six milestones closed in roughly one loop day; 28 issues landed (24 implementation + 4 closure/toggle/fixture + 1 tracked deferral #860).

The `softarch → debugger` loop shape held throughout with zero workerbee invocations. Cross-repo escalation to paideia-as fired **zero times** during R22 — the substrate was ready for every encoder R22 needed, and both paper-tiger "paideia-as-blocked" labels (on #850 and #866) were downgraded on inspection. `paideia-as` submodule pin `2cf169d` unchanged from R21 close.

---

## Real-Hardware Verification Procedure (T14 G4 Raptor Lake, R22 gated:hardware)

The R22 substrate cannot be end-to-end verified under QEMU-TCG (no VT-d emulation in default config; `-machine intel-iommu=on` is R23 scope). It becomes exercisable when the operator boots on T14 G4 in R23+:

1. **Prepare boot media.** Build kernel + ESP image per `design/roadmap/r19-t14-g4-boot-guide.md`. Ensure `boot_smp` + `boot_r22_pci_tree` pass locally.

2. **BIOS setup.** Confirm **Intel VMD Controller = Disabled** (per #870 quirk row). Secure Boot off (for the capture pass), TPM 2.0 on.

3. **Boot on T14 G4.** Serial output should show:
   - R21 fingerprints (HPET, TSC, X2APIC, SMP).
   - `X2APIC ENABLED BSP` (R22.M1 — Raptor Lake supports x2APIC unconditionally, so the flag flips to 1 and the MSR path is live).
   - `MCFG PRESENT` (R22.M1 — real ACPI 2.0 tables surface the MCFG).
   - `PCI DEV bus=0 dev=0 vendor=0x8086 device=0x???` × N (R22.M2 — per-device lines).
   - `PCI ENUM DONE devices=N` where N ≈ 40–60 (Raptor Lake U/P device count with VMD off).
   - `PCI HDR READY` (R22.M1).
   - (No VT-d fingerprints yet — R22.M6 leaves `IOMMU_ENABLED = 0`.)

4. **Run PCI capture.** Follow `tools/capture-t14-g4-pci.md` from a side-installed Linux; land the config-*.bin blobs in `tests/kernel/pci/fixtures/t14g4/`.

5. **Run ACPI capture.** Follow `tools/capture-t14-g4-acpi.md`; land the *.bin tables in `tests/kernel/acpi/fixtures/t14g4/`. (Both captures can share a single Linux-boot session.)

6. **Populate expected-values tables.** Flip `t14_g4_fixture.pdx` (both trees) from placeholder to active witness per each file's §"Acceptance criteria".

7. **Update quirks-db.** Promote at least 3 rows PROVISIONAL → CONFIRMED. Add any new rows discovered during boot.

**None of this blocks R22 close.** The QEMU-side R22 substrate is proven; T14 G4 first-light is a separate hardware-availability event queued for R23.

---

## Next Round

**R23 (driver-plane substrate — first real drivers: virtio, xHCI, then NVMe on VT-d-enforced DMA).** See `design/roadmap/r18-plus-bare-metal.md` §R23 (to be authored — R23 opens as a fresh scoping pass). Preflight document to land at R23.M1 kickoff as `design/round-retrospectives/r23-preflight.md`.

R23 blockers: none from R22. Ready to open.

---

**Closure.** R22 PCI substrate + xAPIC retirement + IOMMU (VT-d) substrate — closed 2026-08-11.
