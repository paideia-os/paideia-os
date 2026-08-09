# PaideiaOS R18+ Bare-Metal Roadmap

**Status:** Canonical planning document — R18 through MVP demo (R28) with post-MVP hardening (R29–R40) and deferred scope (R41+).
**Date:** 2026-08-08
**Vantage:** Post-R17.M5 (interactive shell on QEMU with fork/exec/wait/exit + tmpfs + TTY line discipline).
**Reference hardware:** **ThinkPad T14 Gen 4** (Intel Raptor Lake, i7-1365U class).
**Reconciles:** `osarch` R18+ roadmap (2026-08-08) with `softarch` companion plan (`paideia-as` + `paideia-os` bare-metal breakdown, 2026-08-08). Where the two disagree on ordering, osarch's ordering wins because it respects Pillars 2/5/6 literally; softarch's per-module LoC estimates carry into deliverables.

---

## 0. Locked user decisions

These are the four constitutional decisions that shape every round below. Do not revisit inside a round; escalate a fresh design memo if you must.

1. **Target hardware — ThinkPad T14 Gen 4** (not Framework Laptop 13). Rationale: on-hand availability + broader chipset coverage (Raptor Lake iGPU, Intel i219-LM ethernet on-board, AX211 Wi-Fi, xHCI, NVMe, Intel VMD togglable, Insyde/Lenovo UEFI). Framework 13 becomes a secondary regression target only after MVP demo.
2. **Persistent filesystem strategy** — **PdxFS-lite** interim at R25 → **PdxFS v1 (CoW-PQ)** at R40. Rationale: de-risks R25 to a ~30-issue round, unblocks R28 MVP demo, accepts a documented one-way on-disk migration path at R40 rather than locking the R25 format prematurely.
3. **Bootloader — paideia-native EFI PE32+ stub from day 1.** Multiboot2/GRUB stopgap is **dropped**. Consequence: `paideia-as` MS x64 ABI emit (paideia-as #1011) becomes an R18-blocker (it lands as `v0.21`), and the round previously slotted at R29 (UEFI-native) folds into R19. Estimated schedule cost: +3–6 months relative to the GRUB-stopgap plan, in exchange for Pillar 5 (no legacy) and Pillar 10 (functional-discipline assembly) held cleanly from first boot on real hardware.
4. **Wi-Fi — deferred to R41+.** Wired ethernet (i219-LM) is the sole network path through the MVP demo. Rationale: iwlwifi/AX211 is a research-year of driver work; T14 G4 has integrated i219-LM already; USB-C tether remains available as an operator escape hatch if the MVP demo needs offsite connectivity.

---

## 1. Executive summary

Eleven MVP rounds land in strict serial order, followed by twelve hardening rounds and open-ended deferred scope. Each round follows the R13–R17 tempo: 4–7 milestones × 3–6 issues ≈ 12–35 issues.

| Round | Purpose | Est. issues | Est. dev-weeks |
|---|---|---|---|
| **R18** | SMP substrate (bring APs online; per-CPU state; MCS locks; TLB shootdown IPI) | 26 | 8 |
| **R19** | Paideia-native UEFI PE32+ boot (drops Multiboot2 entirely) | 22 | 12 |
| **R20** | ACPI static tables (RSDP → XSDT/MADT/MCFG/FADT/HPET) | 20 | 6 |
| **R21** | FPU/XSAVE + IOAPIC full + MSI/MSI-X + x2APIC | 22 | 7 |
| **R22** | PCIe ECAM + VT-d IOMMU | 28 | 10 |
| **R23** | Framebuffer console via GOP (direct from UEFI handoff) | 11 | 4 |
| **R24** | NVMe driver (userspace, per Pillar 3) | 25 | 12 |
| **R25** | **PdxFS-lite** persistent FS MVP (ML-DSA superblock signature only) | 30 | 14 |
| **R26** | USB xHCI + HID keyboard | 30 | 12 |
| **R27** | e1000e ethernet + ARP + IPv4 + UDP + ICMP | 27 | 12 |
| **R28** | Bootable USB distribution + real-HW smoke on T14 G4 → **MVP DEMO** | 14 | 6 |
| | **MVP subtotals** | **~255** | **~103** |

At the current continuous-loop tempo (~1 round per 4–6 weeks), MVP demo lands in **~13–18 months** with the paideia-native EFI stub decision priced in.

Post-MVP hardening (R29–R40) then deferred scope (R41+) are decomposed in sections 3 and 4.

---

## 2. MVP Path (R18–R28) — per-round detail

### R18 — SMP substrate (multicore bring-up)

**Purpose.** Bring APs online with per-CPU state, real spinlocks and atomics; retire the "single-CPU deferred" audit posture. Pillar 2 non-negotiable: no BKL phase.

**Prereqs.**
- **`paideia-as v0.21`** (MS x64 ABI emit + naked ISR sugar + full atomics bundle + `gs`-relative memory operand + mfence/sfence/lfence + xsave family + CPUID typed record + RDMSR/WRMSR wrapper + invpcid/invlpg/wbinvd + 128-bit MOVDQA/MOVDQU + `ltr r16` verify + MSR stdlib wrapper + bitfield struct read/write helpers). Filed as blocker milestone in paideia-as.

**Deliverables.**
- SIPI AP boot trampoline (real-mode → protected → long-mode) placed in low mem.
- Per-CPU control block via `[gs:offset]`; `swapgs` discipline at syscall/IRQ boundaries.
- Per-CPU runqueue (retire BSP-only RQ).
- MCS spinlock (per-CPU queue node, CAS-based).
- Atomic ref-count primitive.
- TLB shootdown IPI (mfence-fenced; INVPCID where available).
- Cross-CPU reschedule IPI.
- Per-CPU TSC-deadline timer arming.
- CPUID 0x1A per-AP hybrid-topology tagging (P/E/LP-E per hwman §7).
- `boot_smp` smoke fingerprint (all N cores tag `CPU_ID_X_HELLO`).

**Testing.** QEMU `-smp 4` + `-smp 8`; per-core fingerprint witness; TLB shootdown regression fixture (map+unmap under concurrent read).

**Issues.** ~26 across 6 milestones (R18.M1..M6).

---

### R19 — Paideia-native UEFI PE32+ boot

**Purpose.** Real boot on T14 G4 via UEFI Boot Services with typed handoff — no GRUB, no Multiboot2 tag list. Retires the QEMU `-kernel` monotone permanently.

**Prereqs.**
- `paideia-as v0.21` (MS x64 ABI + PE32+ emitter, both blocker).
- R18 (multicore-safe kernel entry required by UEFI-guaranteed BSP-first + AP wake sequence).

**Deliverables.**
- `src/boot/uefi_stub.pdx` — PE32+ EFI application entry `(ImageHandle, SystemTable*)`.
- `src/boot/uefi_bs.pdx` — GetMemoryMap / AllocatePages / LocateProtocol wrappers (with map-key retry per hwman §1).
- `src/boot/uefi_gop.pdx` — GOP framebuffer discovery (base + pitch + bpp cached for R23).
- `src/boot/uefi_acpi.pdx` — RSDP discovery via `EFI_CONFIGURATION_TABLE` (staged for R20 consumption).
- `src/boot/uefi_measured.pdx` — TPM 2.0 `EFI_TCG2_PROTOCOL` PCR-extend for kernel-image hash (measured-boot seed; deepens at R33).
- `src/boot/handoff.pdx` — typed `boot_env_t` struct (memmap, framebuffer descriptor, RSDP*, TPM log*).
- `src/boot/exit_bs.pdx` — ExitBootServices + jump to `kernel_main_uefi`.
- `src/kernel/boot/kernel_main_uefi.pdx` — new entry replacing legacy PVH entry.
- `tools/build-uefi-image.sh` — .efi image + ESP layout + ISO/USB assembly.

**Testing.** QEMU `-bios OVMF.fd` first; then `dd` to USB and boot the T14 G4 (this is the "hello from real hardware" moment). SwTPM for measured-boot fixture.

**Issues.** ~22 across 5 milestones.

---

### R20 — ACPI static-table bring-up

**Purpose.** Discover hardware topology from firmware tables so subsequent rounds stop hard-coding. AML is **not** in scope (see R34 — ACPICA userspace bubble).

**Prereqs.** R19 (RSDP handed off from UEFI); paideia-as slice + bitfield helpers (soft; workable via `bytes.pdx` interim).

**Deliverables.**
- RSDP scanner (fallback: EBDA + `0xE0000..0xFFFFF` if UEFI handoff absent).
- XSDT walker.
- MADT parser (LAPIC, IOAPIC, ISO overrides, LAPIC address override).
- MCFG parser (PCIe ECAM base per segment).
- FADT parse (PM1/PM_TMR I/O ports, reset register).
- HPET table (base + period).
- Typed `phase1_acpi_info` handoff record.
- MADT-driven AP init (replaces R18's hard-coded N).
- Userspace `acpi_supervisor` server (per Pillar 3 — kernel only mints the RSDT/XSDT capability).

**Testing.** QEMU `-machine q35 -smp 8` (realistic MADT/MCFG); host-side parse-only unit fixtures against captured T14 G4 tables; boot witness `ACPI RSDP @0x… XSDT[N] MADT MCFG FADT HPET`.

**Issues.** ~20 across 5 milestones.

---

### R21 — FPU/XSAVE + interrupt controller completion

**Purpose.** Full ISA state discipline (Pillar 1) + interrupt vectoring plumbing for MSI-capable devices (blocking prereq for NVMe/xHCI/NIC).

**Prereqs.** R20 (MADT for IOAPIC bases + LAPIC IDs); `paideia-as v0.21` xsave family already landed.

**Deliverables.**
- XSAVE area sized from CPUID leaf `0xD` per-thread; eager save/restore in context switch (lazy deferred — measure at R35).
- AVX2 / AVX-512 state gated by CPUID feature bits.
- IOAPIC GSI-to-vector programming (full, not IRQ-4-only).
- MSI capability walker + write to device capability register.
- MSI-X table + PBA mapping.
- HPET as monotonic-time source; wallclock calibration.
- x2APIC enable (MSR mode, replaces xAPIC MMIO on all supported CPUs).

**Testing.** QEMU `-device virtio-net-pci` to exercise MSI-X path; AVX fingerprint fixture (YMM compute across preemption); IOAPIC re-route smoke.

**Issues.** ~22 across 5 milestones.

---

### R22 — PCIe ECAM + VT-d IOMMU

**Purpose.** Real device tree; per-device DMA isolation (Pillar 6 by construction).

**Prereqs.** R20 (MCFG for ECAM); R21 (MSI-X — required for interrupt-remapping under x2APIC MSI on modern chipsets).

**Deliverables.**
- ECAM config-space accessor (replaces 0xcf8/0xcfc; keeps legacy path as forensic-only per Pillar 5).
- BDF walk + PCI-to-PCI bridge recursion.
- BAR sizing.
- Capability list parsing (MSI, MSI-X, PM, PCIe).
- Device-tree publication via `KIND_DEVICE` cap tree.
- VT-d DMAR parse.
- Per-device IOMMU domain.
- Interrupt-remapping table (required on Intel client chipsets before x2APIC MSI works reliably).
- Userspace enumerator process (Pillar 3 — kernel only mints the ECAM cap).

**T14 G4 note.** VMD-off in BIOS recommended for MVP — NVMe visible as a plain PCIe device rather than under Intel VMD's remapping. VMD support is R37+ scope.

**Testing.** QEMU q35 with virtio-net-pci + assigned devices; fingerprint of device tree; DMA-fault fixture (deliberate out-of-domain access → expected fault).

**Issues.** ~28 across 6 milestones.

---

### R23 — Framebuffer console (GOP direct)

**Purpose.** Real display output on the T14 G4. No more serial-only. Consumes GOP framebuffer cached from R19 UEFI handoff directly (no Multiboot2 tag path).

**Prereqs.** R19 (framebuffer descriptor in handoff struct).

**Deliverables.**
- LFB mapping with Write-Combining memory type via PAT.
- Embedded 8×16 bitmap font (public-domain VGA glyphs, `@include_bytes`).
- Glyph rasterizer.
- Scrolling text console with backing ring.
- ANSI subset (bold, color, cursor).
- TTY vnode gains alt-sink → framebuffer alongside COM1.
- Kernel-log ring surfaced to framebuffer in the panic path (photograph-recoverable — most modern laptops have no debug UART).

**Testing.** QEMU `-vga std` visual check (headless via `-display none -vnc :0` + screenshot); real HW visual check on T14 G4 iGPU.

**Issues.** ~11 across 3 milestones.

---

### R24 — NVMe driver (userspace)

**Purpose.** Block storage on modern laptops (AHCI is extinct per hwman §3; T14 G4 ships NVMe only).

**Prereqs.** R22 (PCIe + MSI-X + IOMMU domain); R21 (XSAVE for AVX memcpy paths in bulk I/O).

**Deliverables.**
- NVMe controller identify (class `01/08`).
- Admin queue setup (SQ/CQ pair) + IDENTIFY.
- IO queue creation per CPU; MSI-X vector per pair.
- PRP list construction for DMA descriptors.
- Interrupt handler → notification cap (`KIND_INTERRUPT` + `KIND_NOTIFICATION` composition).
- Block-device cap (`KIND_BLKDEV`) exposed via IPC.
- Userspace sync read/write API.
- `csts.cfs` reset / timeout / abort error paths (fault-injected via QEMU flags first).

**Testing.** QEMU `-drive if=none,file=disk.img,format=raw -device nvme`; IDENTIFY witness; sector R/W round-trip; then T14 G4 with a dedicated scratch NVMe.

**Issues.** ~25 across 6 milestones.

---

### R25 — PdxFS-lite (persistent FS MVP)

**Purpose.** Store files across boots. Fixed-size superblock, extent-based, no CoW yet, ML-DSA-signed superblock only. Upgradable to full CoW-PQ (PdxFS v1) at R40 via a documented one-way migration tool.

**Prereqs.** R24 (block cap); paideia-as slice + bitfield helpers.

**Deliverables.**
- On-disk format v0 document (`design/filesystem/pdxfs-lite-format.md`).
- Superblock + inode table + extent map.
- Host-side `mkfs.pdxfs-lite` (paideia-as-compiled binary running under Linux for image prep).
- VFS backend that mounts a `KIND_BLKDEV` as PdxFS-lite.
- ML-DSA-65 superblock signature — uses R32 crypto if landed at R25 time; otherwise stub-and-audit with an issue-linked TODO.
- CREATE / RENAME / UNLINK.
- Write-through only (no cache) at MVP.

**Testing.** QEMU with NVMe image containing pre-built PdxFS-lite; boot → `ls` / `cat` / `echo > file` → reboot → data persists.

**Issues.** ~30 across 7 milestones. **Largest MVP round.**

---

### R26 — USB xHCI + HID keyboard

**Purpose.** Real keyboard input on the T14 G4 (no PS/2 controller). Handles the BIOS-owned → OS-owned handoff dance per hwman §4.

**Prereqs.** R22 (PCIe MSI-X + IOMMU).

**Deliverables.**
- xHCI probe (class `0c/03/30`).
- BIOS-owned → OS-owned handoff via `USBLEGSUP`.
- Command ring + event ring (16 B TRBs).
- Port reset + device address.
- Device-context array; slot management.
- USB descriptor parsing.
- HID class driver (userspace).
- HID boot-protocol keyboard translation → TTY input ring (bridges to existing `_tty_line_buf`).

**Deferred to post-MVP.** HID mouse + touchpad (I²C-HID needs ACPICA — R34).

**Testing.** QEMU `-device qemu-xhci -device usb-kbd`; T14 G4: type on internal keyboard, see chars land in shell prompt.

**Issues.** ~30 across 6 milestones. **Second-largest MVP round.**

---

### R27 — Ethernet + minimal network stack (UDP + ARP + ICMP)

**Purpose.** IP connectivity from bare metal. Full TCP deferred to R31.

**Prereqs.** R22. Target driver: Intel i219-LM (T14 G4 on-board) — cleanest errata per hwman §5. e1000e-family is one codebase across i219 variants.

**Deliverables.**
- e1000e driver (userspace).
- TX/RX ring descriptors.
- MSI-X handler.
- L2 frame framework.
- ARP resolver.
- IPv4 send/receive (per existing `design/network/ipv4-only-policy.md`).
- UDP socket cap (`KIND_UDP_SOCKET`).
- ICMP echo reply.

**Deferred.** TCP → R31 (full stack round).

**Testing.** QEMU `-netdev user + -device e1000e`; `ping` from host to guest; UDP echo demo. T14 G4: `ping 8.8.8.8` from bare metal.

**Issues.** ~27 across 6 milestones.

---

### R28 — Bootable distribution + real-HW smoke → MVP DEMO

**Purpose.** Package everything as a bootable USB and validate on the physical T14 G4; add HW regression matrix.

**Prereqs.** R22–R27.

**Deliverables.**
- `tools/build-image.sh` — assembles kernel + userland binaries + PdxFS-lite blob + ESP layout (paideia-native UEFI stub) into an ISO/USB image.
- `mkfs.pdxfs-lite` host tool (from R25).
- ESP layout (FAT32 with `/EFI/PAIDEIA/PAIDEIA.EFI` — self-hosted, no shim).
- Pre-push HW smoke script (`tools/run-smoke-hw.sh`, gated by `PAIDEIA_HW_SMOKE=1`).
- Framebuffer log ring in panic handler (photograph-recoverable).
- HW quirks database seed (`design/hardware/quirks.md` — T14 G4 initial rows).
- Regression matrix seed rows: T14 G4 (primary), Framework 13 (secondary — post-MVP), QEMU-OVMF (primary CI).
- Serial-console fallback for headless HW where available.

**Testing.** Boot on T14 G4, run `boot_r28_hw_smoke` (per-subsystem fingerprint), reboot, ping, `cat /etc/hello`.

**Issues.** ~14 across 4 milestones.

---

## 3. Post-MVP hardening (R29–R40)

Not yet decomposed into GitHub milestones — Phase 2 planning will file these once R28 closes.

| Round | Purpose | Est. issues |
|---|---|---|
| **R29** | Retire xAPIC MMIO for good; kernel timer redesign (TSC-deadline everywhere) | ~15 |
| **R30** | Time subsystem hardening (RTC wallclock, TSC/HPET calibration, monotonic clock cap) | ~10 |
| **R31** | Full TCP + BBRv3 + QUIC (per `design/network/bbrv3.md`) + DNS-over-QUIC (per `design/network/dns-cache.md`) | ~40 (may split R31a/R31b) |
| **R32** | Post-quantum crypto subsystem (RDRAND/RDSEED entropy + Müller-jitter + TPM RNG mixed via SHA-3 DRBG; ML-KEM-768; ML-DSA-65; SLH-DSA-128f; AVX2 vectorized, constant-time) | ~30 |
| **R33** | TPM 2.0 driver + measured boot deepening (PCR extend for full boot chain; TCG event-log via ACPI TPM2) | ~15 |
| **R34** | ACPICA userspace bubble (AML interpreter per `design/acpi/acpica-bubble.md`); unlocks LPSS UART/I2C/GPIO, thermal zones, lid/power buttons | ~40 (may split R34a/R34b) |
| **R35** | Hardening trifecta: KPTI-full + CET IBT + Shadow Stack + MPK/PKU for in-process isolation | ~20 |
| **R36** | Machine-check + RAS (`#MC` handler with MCA-bank decode; recoverable-error forwarding to userspace RAS server) | ~12 |
| **R37** | USB mass storage + AHCI as forensic-only fallback for pre-2018 chipsets we opt-in to support | ~20 |
| **R38** | Driver framework maturation (full E3 per `design/drivers/framework.md`: hierarchical supervisor, hot-plug, hard-restart-default lifecycle, blob-driver hook) | ~30 |
| **R39** | Semantic terminal runtime (Pillar 8): typed records, Datalog-flavoured pipeline query, PDS wire format, command registry; POSIX shell retires to `wasi-shell` for POSIX-jail use | ~35 |
| **R40** | **PdxFS v1** (full CoW-PQ FS; snapshot GC per `design/filesystem/snapshot-gc.md`; per-extent PQ signatures; multi-device pool). Retires PdxFS-lite via in-place upgrade tool | ~40 (may split R40a/R40b) |

---

## 4. Deferred / optional (R41+)

Not on the MVP or hardening critical line. Ordering is nominal; user can promote any into an earlier slot on demand.

- **R41+ Wi-Fi.** Order by complexity per hwman §5: rtw89 first (~35 issues) if we ever add a USB dongle; iwlwifi (Intel AX211 on T14 G4) is ~50 issues and a research-year of driver work; never ath11k. **User's decision: deferred entirely for the R28 MVP window; wired ethernet is the sole network path.**
- **R42+ GPU acceleration.** Intel iGPU only (Q6). Enormous. Framebuffer console suffices indefinitely.
- **R43+ ACPI S3/S4 sleep.** Complex + rarely-perfect even in Linux; defer until user demand is real.
- **R44+ Audio.** HDA / SoundWire — non-essential for OS-research demo.
- **R45+ Touchpad / gestures.** I²C-HID needs ACPICA (R34) as prereq.
- **R46+ Bluetooth, sensors, thermal-sensor-driven fan control.**
- **AMX / AVX-512 opt passes for PQ crypto & PdxFS hashing** — R32 delivers baseline; opt passes optional.
- **BIOS/CSM boot path** — permanently excluded by Pillar 5 for boot; may live only as forensic-only tooling in R37 tier.

---

## 5. `paideia-as` capability-gap dependency schedule

Substrate is the pacing item for R18–R23. File the `paideia-as` bundles now so `paideia-os` never blocks on encoder work at round-boundary time. Per `feedback_paideia_as_version_discipline.md`, each paideia-as vX bundle is closed with a workspace-version bump + git tag + CHANGELOG entry moving together.

| paideia-as bundle | Contents (softarch item numbers in `[]`) | Unblocks | Est. weeks |
|---|---|---|---|
| **v0.21 — Bare-metal substrate** | MS x64 ABI emit [A10, #1011] · naked ISR `@interrupt` sugar [A7] · full atomics bundle (`lock cmpxchg`/`xadd`/`xchg`/`lock` prefix) [A13] · `mfence`/`sfence`/`lfence` intrinsics [A2] · `gs`-relative memory operand + `PerCpuOps` trait [A14] · CPUID typed leaf-record [—] · RDMSR/WRMSR typed wrapper [A3] · `invpcid`/`invlpg`/`wbinvd` [—] · 128-bit `MOVDQA`/`MOVDQU` [—] · `xsave`/`xrstor`/`xsaveopt` verify [A19] · `ltr r16` re-verify against R15 TSS work [—] · bitfield struct read/write helpers [A6 phase 1] · MMIO volatile load/store lowering [A1, #1036] | **R18** (atomics/mfence/gs-rel/xsave/MSR) + **R19** (MS x64 + PE32+ path) | ~6–8 |
| **v0.22 — Driver substrate** | Full packed-struct / bitfield syntax [A6 phase 2] · `Slice<T>` type + bounds accessor [A15] · `@requires_cpu(FEATURE)` gating [A16] · DMA-buffer attribute + `phys_addr_of()` intrinsic [A5] · MMIO/PerCpu/Refcount elaborator lowering completion [#1036] | R20 (ACPI slice walks), R22 (PCI cap walk), R24 (NVMe SQE/CQE), R26 (xHCI TRB) | ~6–8 |
| **v0.23 — Perf substrate** | Framebuffer stdlib (`stdlib/pdx/framebuffer.pdx` — parametric `put_pixel`/`fill_rect`/`blit`) [A22] · `@device_memory` type modifier [A21] · `bswap` endian helpers exposed [A11] · SIMD packed arith `vpaddq`/`vpsubq` [A12] · CET `Endbr64` landing-pad enforcement | R23 (framebuffer), R27 (endian for L2/L3 headers), R35 (CET), R32 (SIMD crypto — optional) | ~3–4 |
| **v0.24 — PE32+ hardening** | PE32+ emitter completeness edge cases (relocations, base-of-code hints) · UEFI `EFI_SYSTEM_TABLE` + `EFI_BOOT_SERVICES` typed vtable stubs · UTF-16 string literal for UEFI protocol calls | R19 hardening; R28 image build | ~2–3 |

The v0.21 milestone is filed in this Phase 1 pass. v0.22–v0.24 file in Phase 2.

---

## 6. Cross-cutting concerns already covered

No new round required for the following — existing design docs cover R18–R28 needs:

- **IPC (wait-free dataflow):** `design/ipc/` covers new device-driver channels.
- **Capability derivation for driver caps:** `design/drivers/driver-cap.md` covers R18–R28 driver caps.
- **Security posture:** `design/security/mitigation-analysis.md` covers Spectre/Meltdown discipline through R35.
- **Per-CPU layout:** `design/multicore/per-cpu-layout.md` is R18-ready.
- **Boot-path spec:** `design/infrastructure/boot-path.md` BP-D3 UEFI deferral is now collected at R19.

---

## 7. ThinkPad T14 Gen 4 hardware inventory (MVP target)

Anchor rows for `design/hardware/quirks.md` when R28 seeds it. Verified against public Lenovo PSREF for T14 G4 Intel (2023) — cross-check when the physical unit is on the bench.

| Subsystem | Detail | MVP impact |
|---|---|---|
| **CPU** | Intel Raptor Lake U/P (i5-1335U or i7-1365U class typical); P/E-core hybrid; AVX2 present, AVX-512 disabled at core level | R18 CPUID 0x1A hybrid tagging is meaningful; do not depend on AVX-512 |
| **Chipset** | Intel PCH (SoC-integrated on U/P); Insyde/Lenovo UEFI firmware | R19 GetMemoryMap key-retry loop is essential (Insyde is stricter than OVMF) |
| **BIOS quirks** | Lenovo defaults: VMD-on, Secure Boot-on, TPM-on; UEFI Boot Order editable; Legacy CSM available but leave off (Pillar 5) | R19: turn VMD-off before R24 NVMe brings NVMe up as plain PCIe (documented workaround; VMD support is R37+). Secure Boot compatibility: R33 signs kernel with our own keys enrolled via `KEK` |
| **RAM** | Soldered LPDDR5-6400, 16 GB or 32 GB; single package, single NUMA node | R18 NUMA topology is trivial; single-node fixture sufficient through MVP |
| **Storage** | M.2 2280 NVMe (PCIe Gen 4 x4); typically Samsung PM9A1 / WD SN740 class | R24 test target |
| **Ethernet** | Intel i219-LM (on-board, PCH-integrated PHY) | R27 target driver (e1000e family) |
| **Wi-Fi** | Intel AX211 (Wi-Fi 6E, integrated CNVi) | **Deferred to R41+** per user decision |
| **Bluetooth** | Integrated with AX211 | Deferred (R46+) |
| **USB** | xHCI (2× USB-C Thunderbolt 4 + 2× USB-A + 1× USB-C USB-3.2) | R26 target |
| **Display** | Intel iGPU (Iris Xe or UHD, per SKU); internal eDP; HDMI 2.1; DP-alt over TB4 | R23 framebuffer console via UEFI GOP handoff. **No accelerated GPU driver on the MVP critical line.** |
| **Audio** | Realtek HDA + Intel SST | Deferred (R44+) |
| **TPM** | dTPM 2.0 (TCG-compliant, TIS/CRB @ 0xFED40000) or fTPM (integrated in PCH); Lenovo default is dTPM | R19 measured-boot seed via `EFI_TCG2_PROTOCOL`; deepens at R33 |
| **Debug** | No debug UART exposed on modern T14 chassis; Intel DCI over USB-C possible with a debug dongle | **R28 fallback: framebuffer log ring photographable in panic path.** |
| **Battery / EC / thermal** | Lenovo Embedded Controller behind ACPI EC + PECI thermal | Fan defaults to BIOS-set HWP; safe for demo duration without ACPICA per hwman §9 |

**Recommended BIOS setup before first R19 boot on real HW:**
1. Secure Boot: Off (until R33 key enrollment lands; then flip on).
2. Intel VMD Controller: **Off** (so NVMe appears as a bare PCIe device at R24; re-enable never — VMD is R37+).
3. Legacy CSM: Off.
4. TPM 2.0: On (required for R19 measured-boot seed).
5. Fast Boot: Off (predictable timing during framebuffer console bring-up).
6. Boot from USB: enabled; UEFI boot mode only.

---

## 8. Open architectural questions (still user-decision)

The four constitutional decisions in §0 are locked. These seven remain and are safe to answer any time before their gating round.

1. **VMD stance long-term.** MVP requires BIOS-off (documented). At R37+ do we invest in an in-tree VMD driver, or does BIOS-off remain the permanent supported policy? Deadline: R37 planning.
2. **Minimum supported CPU generation.** LAM is Meteor Lake+ (client); older i7 requires software-LAM fallback per `design/capabilities/linearity-and-tags.md`. **Working assumption:** Raptor Lake+ for MVP (matches T14 G4 primary); soft-LAM fallback lands R35+. Alternatively raise floor to Alder Lake if LAM is not strictly needed at MVP. Deadline: R21 (XSAVE work exposes CPUID leaf `0xD` and forces the answer).
3. **AML deferral cost.** Without ACPICA (R34), we cannot reach LPSS UART, thermal-driven fan control, or hot-plug. Per hwman §9: HLT + BIOS-set HWP is thermal-safe for MVP-demo duration. Is that a permanent MVP position, or a 6-month clock? Deadline: R28 closure.
4. **On-disk-format lock-in policy** at R25. **Working assumption:** one-way migration tool at R40 (per §0 decision 2). If we later flip to "zero on-disk breaking changes to v1," the R25 format spec must be frozen before R25 opens. Deadline: R25 kickoff.
5. **POSIX WASM slotting** (Q9). Not on any current round. Suggest R41+ once semantic terminal (R39) stabilizes the native shell contract. Deadline: R39 kickoff.
6. **Persistent-storage FS signature scope** at R25. Per `design/01-foundational-decisions.md` cross-tension §6, per-block PQ signing is infeasible (ML-DSA is 3+ KB). Per-extent? Per-snapshot? **Working assumption:** per-superblock at R25; per-extent at R40. Deadline: R25 kickoff.
7. **Hardware-in-the-loop cadence.** Per `feedback_paideia_os_no_cicd.md`, paideia-os has no GitHub Actions. Real-HW smoke at R28 needs a physical T14 G4 with serial/photographable console attached. Is that in the lab now, and what is the pre-push HW smoke cadence (every commit vs. every milestone-close)? Deadline: R28 kickoff.

---

## 9. Sequencing summary (critical path)

Each item strictly blocks the next.

```
paideia-as v0.21 (MS x64 + atomics + gs-rel + xsave + mfence)
     │
     ▼
R18 SMP substrate
     │
     ▼
R19 paideia-native UEFI PE32+ boot   ◄── first observable "hello from real hardware"
     │
     ▼
R20 ACPI static tables
     │
     ▼
R21 XSAVE + full APIC + MSI/MSI-X + x2APIC
     │
     ▼
R22 PCIe ECAM + VT-d IOMMU
     │
     ├─────► R23 framebuffer console  (parallel-safe within a round)
     │
     ▼
R24 NVMe
     │
     ▼
R25 PdxFS-lite
     │
     ▼
R26 xHCI + HID keyboard
     │
     ▼
R27 e1000e + UDP/ARP/ICMP
     │
     ▼
R28 MVP DEMO — bootable USB + real-HW smoke on T14 G4
```

Parallelizable within a round; serial across rounds per `feedback_paideia_os_tempo.md`.

---

**End of R18+ bare-metal roadmap.**
