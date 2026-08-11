# PaideiaOS Post-MVP Roadmap — Systems-Architecture Proposal (R29–R43)

**Status:** Independent proposal for synthesis with softarch counterpart (parallel wave).
**Author:** osarch voice.
**Date:** 2026-08-11.
**Vantage:** Post-R28 MVP demo (bootable USB + T14 G4 first-boot smoke). Commit `836ec0d` tags `mvp-v0.1`.
**Reference hardware:** Lenovo Thinkpad T14 Gen 4 (Intel Raptor Lake-U/P, i5-1335U or i7-1365U class; Xe-LP Gen12.2 iGPU; Intel i219-LM ethernet already covered R27; Intel AX211 CNVi Wi-Fi 6E; Realtek ALC287 + Intel cAVS/HDA; Intel IPU6 camera; TBT4 on-die; Lenovo ACPI EC).
**Reconciles:** the existing R29–R40 hardening slate captured in `design/roadmap/r18-plus-bare-metal.md` §3, but re-sequences it to unblock laptop-class hardware (ACPICA-first) and to fold in the GPU-native GUI stack.
**Companion:** softarch is authoring an independent proposal against the same brief; the synthesis step will file GitHub issues. This document files nothing.

---

## 0. What this document is and is not

This is a **systems-architecture** proposal. The voice emphasises: interrupt-path latency budgets, DMA / IOMMU-domain partitioning, buffer ownership and cache-coherency, MMIO ordering fences, power-state transitions, command-streamer submission topology, and direct-scanout / presentation-time plumbing. The parallel softarch proposal is expected to emphasise type-safe IPC schemas, session-typed protocol decomposition, and paideia-as language ergonomics. Neither replaces the other; the synthesis reconciles them.

It is **not** a paideia-as roadmap. Cross-repo asks appear in §5 for pre-filing.

It **files no GitHub issues.** Every issue count is an estimate for the synthesizer; the actual issues land after both perspectives are merged.

---

## 1. Executive summary

Fifteen post-MVP rounds (R29–R43) deliver two interleaved axes: (i) exhaustive Lenovo Thinkpad T14 G4 driver coverage, and (ii) a GPU-native graphical stack designed to sidestep the pitfalls that shipped compositors have accumulated over the last decade. Total scope: **~440 issues** across the two axes.

**Dominant architectural stance.** The T14 G4 driver bring-up is *serialised by ACPICA* — without an AML interpreter, everything laptop-shaped (touchpad, battery, thermal, backlight, hotkeys, S0ix idle) is off the table. The current `design/roadmap/r18-plus-bare-metal.md` slate slots ACPICA at R34; **this proposal promotes it to R29** and sequences the laptop-experience rounds (EC, backlight, I²C-HID touchpad, sensors, thermal, PM) tight against it. That single reordering shortens the wall-clock to a usable-daily-driver T14 G4 by an estimated 4–6 months and is the single most consequential recommendation.

**GUI stance.** The graphical stack is designed as a **compute-first render graph on top of a KMS-equivalent (`paideia-drm`) and a Vulkan-native command-streamer path (`paideia-vk`) on Iris Xe Gen12**. Composition is **explicit-sync-only** from day one (drm-syncobj timelines, per Vulkan `VK_KHR_timeline_semaphore` shape), which structurally forecloses the NVIDIA-on-Wayland-implicit-sync race class. 2D uses a Vello/piet-gpu-lineage GPU-tile rasteriser, text uses SDF (Slug lineage) with GPU-side subpixel positioning, and HDR + wide-gamut ICC compositing is day-one, not bolted on.

**Pitfalls I consider most dangerous** (each becomes a first-class architectural invariant in §3):

1. **Implicit fence semantics.** Wayland's implicit dmabuf sync leaked GPU-scheduler assumptions into the compositor and produced the "NVIDIA flicker" class. We adopt explicit-sync exclusively (Pillar 5: no legacy).
2. **Compositor on the input path.** GNOME/KDE compositor hangs kill the recovery console. We split input routing into a compositor-independent server that survives compositor death.
3. **Fractional scaling by supersample.** GNOME's ~9-year integer-scale-then-downsample legacy costs measurable battery and blur. We render at the target resolution.
4. **Accessibility as afterthought.** AT-SPI was added late; screen-readers see stale trees. We put accessibility in the protocol wire format.
5. **HDR as afterthought.** X11 never got HDR; Wayland is still stabilising it. We build a scRGB-linear compositing space and ICC-aware output transforms from R38.
6. **Firmware-blob denial.** AX211 UMAC and IPU6 pipeline firmware are non-negotiable proprietary blobs. Pretending otherwise means no Wi-Fi and no camera. We land the blob-driver capability policy (`design/drivers/blob-policy.md`) before Wi-Fi (R41) and camera (R43).
7. **Vendor-tunnel drift.** TBT4 hot-plug tunnels PCIe from arbitrary docks into our IOMMU. Trust boundaries must be enforced at the TB4 protocol layer (R42), not at PCIe capability minting time.

**Load-bearing paideia-as asks** (§5 has the full schedule): a floating-point substrate + AVX/AVX-512 packed-float ops (needed R34+ for display-engine pixel-clock math and R37+ for shader lowering); a `@device_context` / `@gpu_batch` effect for GPU command submission (R35); WC/UC/WB PAT selection helpers already partly landed by v0.23; and an `@endianness(little)` marker on the CSI-2 receiver structs (R43).

---

## 2. Axis 1 — T14 G4 driver coverage

### 2.0 Round schedule at a glance (Axis 1 rows only; Axis 2 in §3)

| Round | Theme | Est. issues | Milestones | Depends on |
|---|---|---:|---:|---|
| **R29** | ACPICA userspace bubble + AML interpreter | 38 | 7 | R20, R22, R28 |
| **R30** | Interrupt + time hardening (x2APIC-only, TSC-deadline, MCE/RAS, PSCI-analogue) | 22 | 5 | R21, R28 |
| **R31** | Lenovo EC + battery + thermal + backlight + hotkeys + lid + power button + sensors | 28 | 6 | R29 |
| **R32** | PQ crypto substrate + TPM 2.0 driver + measured-boot deepening | 36 | 8 | R28, paideia-as v0.25 |
| **R33** | I²C-HID class + Synaptics/ELAN touchpad + trackpoint tunnel + full HID class stack | 24 | 6 | R29 (LPSS I²C), R26 (HID core) |
| **R34** | *(Axis 2 lead — Iris Xe display engine)* | — | — | — |
| **R35** | *(Axis 2 lead — Iris Xe render engine)* | — | — | — |
| **R36** | HDA controller (Intel cAVS 2.5) + Realtek ALC287 codec + jack detect + PCM ring | 26 | 6 | R29 (ACPI SST notify), R22 (MSI-X) |
| **R37** | *(Axis 2 lead — Vulkan-native path + color mgmt)* | — | — | — |
| **R38** | *(Axis 2 lead — direct scanout + VRR + presentation-time)* | — | — | — |
| **R39** | *(Axis 2 lead — 2D compute rasterisation + SDF text + IME)* | — | — | — |
| **R40** | *(Axis 2 lead — windowing + accessibility + gesture routing)* | — | — | — |
| **R41** | Wi-Fi 6E (Intel AX211 via CNVi/iwlwifi) + WPA3-SAE + 802.11ax MCS + Bluetooth (Intel HCI over USB) + BR/EDR + LE + LE Audio | 42 | 8 | R32 (crypto), R28 (blob-policy), R26 (xHCI) |
| **R42** | Thunderbolt 4 / USB4 protocol above xHCI — connection manager, DP-tunnel, PCIe-tunnel, IOMMU-domain-per-dock policy | 26 | 6 | R22 (VT-d + IR), R26 (xHCI), R29 (ACPI PCH TBT power) |
| **R43** | MIPI CSI-2 + Intel IPU6 camera (firmware blob under IOMMU) + fingerprint (Synaptics/Goodix USB) + WWAN M.2 (Fibocom/Qualcomm MBIM) + additional ACPI/HID sensors | 32 | 8 | R22, R28 (blob-policy), R32 (fingerprint template signing) |

**Axis 1 subtotal:** ~274 issues across 10 rounds (R29–R33, R36, R41–R43).

Every subsection below carries a **Pillar alignment** line (per `feedback-pillar-alignment`) and a **systems-architecture concerns** paragraph.

---

### 2.1 R29 — ACPICA userspace bubble + AML interpreter

**Pillar alignment.** P3 (userspace bubble is not in-kernel); P5 (we do not re-use ACPICA in-kernel like Linux does; we bubble it); P6 (AML in an SFI-jacketed sandbox — audit-channel logs every OpRegion write); P9 (produces the hot-plug + power event streams the driver framework consumes).

**Systems-architecture concerns.**
- AML is a *bytecode with side-effects into unspecified physical memory and I/O ports*; running it in-kernel means giving firmware the kernel-privilege axe. The bubble runs the interpreter in a userspace process granted narrow, per-OpRegion `KIND_MMIO_REGION` / `KIND_PORT` caps derived from the FADT + `_CRS` at parse time.
- The bubble must be a *deterministic serialiser* of `Notify()`, `_Qxx` events, and GPE handling; interrupt priorities are set so GPEs never preempt page-fault handlers.
- Because ACPI thermal + HWP feedback must be latency-bounded (Intel HWP notification loop expects ≤ millisecond turn-around on some SKUs), the bubble carries a `reserved_core_cap` on a single E-core (per `design/kernel/scheduler.md`) so it never falls behind under load.
- OpRegion access to PCI config space must funnel through the R22 ECAM path so IOMMU accounting stays coherent.

**Milestones and issues.**

- **R29.M1 — AML parser + IR** (S, p0, 5 issues): DefBlock parser; NameSpace tree; OpCode table for AML 6.5; DeferredLoad tables; unit fixtures against captured T14 G4 DSDT/SSDT dumps.
- **R29.M2 — AML interpreter runtime** (M, p0, 6 issues): stack machine; Package/Buffer/String/Integer objects; ArgN/LocalN frames; control flow (If/Else/While/Return); Method invocation with reference semantics; MethodMutex.
- **R29.M3 — OpRegion + Field access** (M, p0, 6 issues): SystemMemory / SystemIO / PCIConfig / EmbeddedControl / SMBus OpRegion types; typed Field access (per-bit lock/preserve semantics); dependent-typed access-width verification.
- **R29.M4 — GPE + Notify + fixed events** (M, p0, 5 issues): GPE block enumeration; SCI IRQ routing; `_Lxx`/`_Exx` GPE handler dispatch; `Notify()` fan-out to driver-framework channels; power/sleep-button fixed events.
- **R29.M5 — Namespace queries + wildcards** (S, p1, 4 issues): `\_SB.PCI0.LPCB.EC.*` walks; `_CRS` decode; `_PRT` PCI IRQ routing table; `_STA` presence bit set.
- **R29.M6 — ACPI supervisor server** (M, p0, 6 issues): completes #820 (bubble as `KIND_ACPI_SUPERVISOR` service); routes device-arrived → PCIe enumerator + LPSS bus + EC; capability-minting from `_CRS` decode; audit log; hard restart on assertion.
- **R29.M7 — DSDT/SSDT parse smoke on T14 G4** (S, p1, 6 issues): captured-DSDT unit fixtures; live DSDT parse on QEMU-OVMF and T14 G4; expected-namespace fingerprint; regressions for known-quirky Lenovo AML idioms.

**Rationale for promotion (R34 → R29).** ACPICA is the "unlock" whose absence forces ~7 subsequent rounds into unusable-on-T14-G4 territory. Every laptop-class driver (touchpad, backlight, thermal, EC, PM) blocks on it. Landing it earlier compresses the critical path and pays back with interest across R31, R33, R36, and every idle-power savings claim.

---

### 2.2 R30 — Interrupt + time hardening (x2APIC-only, TSC-deadline everywhere, MCE/RAS, PSCI-analogue)

**Pillar alignment.** P1 (Intel Core Ultra baseline — no legacy xAPIC MMIO); P2 (per-CPU deadline timers); P6 (MCE/RAS forwards recoverable errors to userspace RAS server, not silent panic).

**Systems-architecture concerns.**
- Retiring xAPIC MMIO fully (was R29 in the prior slate) after R21 shipped x2APIC substrate: this round removes the compatibility path.
- MCE handler (`#MC` vector 18) must run on an *interrupt stack* segregated from the NMI stack; MCA bank decode is architecturally per-CPU and must run pinned to the reporting core.
- HWP feedback (Intel HWP INT thresholds) is wired here; without it R31 has no way to close the fan/thermal loop.
- Timekeeping: TSC-deadline replaces HPET periodic on cores where invariant TSC is present (all Raptor Lake U/P); HPET degrades to time-of-day only.

**Milestones and issues.**

- **R30.M1 — x2APIC-only path** (S, p0, 3 issues): remove xAPIC MMIO writes; assert MSR mode at boot; retire compat shim.
- **R30.M2 — TSC-deadline everywhere + monotonic clock cap** (M, p0, 5 issues): TSC calibration via ART/HPET cross-check; monotonic-clock `KIND_CLOCK` service; wallclock via RTC + drift model.
- **R30.M3 — MCE handler + MCA banks decode** (M, p0, 5 issues): `#MC` handler; per-core MCA_STATUS/MCA_ADDR/MCA_MISC decode; recoverable vs unrecoverable classification.
- **R30.M4 — RAS userspace server** (M, p1, 4 issues): `KIND_RAS_STREAM` typed record stream; corrected-error rate telemetry; DIMM/L3 attribution table; ML-DSA-signed RAS journal per `design/security/pq-trust-root.md`.
- **R30.M5 — PSCI-analogue power-op cap** (S, p1, 5 issues): typed `KIND_POWER_OP` (Shutdown/Reboot/SleepS3/HibernateS4) minted by ACPI bubble; unblocks R31 lid-close and power-button.

**Notes.** No AVX-512 opt path here — Raptor Lake U/P has AVX-512 disabled at core level (per hwman §7 and confirmed by Intel).

---

### 2.3 R31 — Lenovo EC + battery + thermal + backlight + hotkeys + lid + power button + sensors

**Pillar alignment.** P3 (each driver is a userspace server); P8 (typed records for battery + thermal telemetry, semantically queryable); P9 (registers with driver-framework hot-plug); P10 (the closed-loop controllers are effect-typed algebraic actions).

**Systems-architecture concerns.**
- The T14 G4 EC lives behind the standard ACPI EC interface (`0x62/0x66` IO ports + EC OpRegion + `_Qxx` events), per hwman confirmation. A generic ACPI EC driver gets battery/thermal/lid; ThinkPad-specific behaviour (Fn keys, TrackPoint sensitivity, ThinkLight, keyboard backlight) needs an `HKEY`/`thinkpad_acpi`-analogue class driver bound to the Lenovo VEN0100 HID.
- Backlight has two rails on T14 G4: eDP AUX-channel PWM (preferred, per DisplayPort 1.4 §7.3.4) and GMBus PWM legacy (fallback if PSR2 breaks AUX-side control). Both plumb into the R34 display engine.
- Sensors (accelerometer / hinge angle) surface via ACPI HID (`ACPI0016` accelerometer class or vendor `LEN000x`) — bind through the R33 HID class stack, not directly.
- Thermal control loop: on modern Raptor Lake we defer to hardware HWP (`IA32_HWP_REQUEST`) with `EPP=0x80` mid-band as the default, and use ACPI `_PSV`/`_CRT`/`_HOT` as the safety net; software-managed P-states are explicitly out of scope.

**Milestones and issues.**

- **R31.M1 — Generic ACPI EC driver** (M, p0, 5 issues): EC transaction FSM (0x62/0x66 handshake); burst-mode; interrupt vs polling; OpRegion binding; `_Qxx` event routing to userspace channels.
- **R31.M2 — Battery + AC-adapter class** (M, p0, 5 issues): ACPI `_BIF`/`_BIX` + `_BST` + `_BMC` parse; PdxBattery service; typed battery-state `KIND_POWER_STATE` records; low-battery notifications.
- **R31.M3 — Thermal zones + HWP feedback loop** (M, p0, 5 issues): `_TMP`/`_PSV`/`_CRT`/`_HOT` thermal-zone parse; HWP request/status MSR wrappers; safety cutoff; thermal telemetry stream.
- **R31.M4 — Backlight (eDP AUX + GMBus PWM)** (S, p0, 4 issues): AUX-side backlight (VESA eDP TCON DPCD 0x701..0x724); GMBus PWM fallback; brightness curve; save/restore across DPMS.
- **R31.M5 — Hotkeys / lid / power button + ThinkPad HKEY** (M, p0, 5 issues): fixed-event routing; `HKEY` method dispatch; Fn-key event stream; TrackPoint sensitivity; keyboard backlight; ThinkLight LED.
- **R31.M6 — Accelerometer + hinge + ambient sensors** (S, p1, 4 issues): ACPI sensor HID binding; typed sensor `KIND_SENSOR_STREAM`; unit-frame semantics (m/s², degrees, lux).

---

### 2.4 R32 — PQ crypto substrate + TPM 2.0 driver + measured-boot deepening

**Pillar alignment.** P6 (post-quantum where applicable — this is the "applicable" round); P1 (AVX2-vectorised, constant-time); P3 (crypto lives in userspace crypto server, kernel gets IPC witness only).

**Systems-architecture concerns.**
- Entropy pool: RDRAND + RDSEED (both DRBG'd through SHA-3, not consumed raw) + Müller-jitter (jitterentropy 3.4 lineage) + TPM 2.0 `TPM2_GetRandom`. Never trust any single source.
- ML-KEM-768, ML-DSA-65 (Dilithium3), SLH-DSA-128f (SPHINCS+) — the FIPS-203/204/205 finalists. AVX2 vectorised. Constant-time throughout. Cite: FIPS 203, FIPS 204, FIPS 205 (all published 2024 by NIST).
- TPM 2.0 (Intel PTT / fTPM is default on T14 G4 per hwman): TIS or CRB interface (T14 G4 uses CRB @ 0xFED40000 for dTPM SKU; PTT/fTPM is via MEI). Detection order: MEI → CRB → TIS. Measured-boot deepens R19's PCR-extend seed with full boot-chain measurements per TCG PC Client Platform Firmware Profile.
- The crypto server exposes typed capabilities: `KIND_KEM_KEYPAIR`, `KIND_SIG_KEYPAIR`, `KIND_AEAD_KEY`, each with algorithm parameter as a *phantom-typed* refinement so mixing curves is a compile-time error.

**Milestones and issues.**

- **R32.M1 — Entropy substrate** (M, p0, 4 issues): RDRAND/RDSEED wrappers with CPUID gating; SHA-3 DRBG (per SP 800-90A); jitterentropy; TPM RNG mixer.
- **R32.M2 — ML-KEM-768 (FIPS 203)** (M, p0, 5 issues): keygen/encaps/decaps; AVX2 NTT; constant-time comparison; KAT harness against NIST vectors.
- **R32.M3 — ML-DSA-65 (FIPS 204)** (M, p0, 5 issues): keygen/sign/verify; AVX2; constant-time; KAT.
- **R32.M4 — SLH-DSA-128f (FIPS 205)** (M, p1, 4 issues): stateless-hash-based signature (SPHINCS+ finalist); WOTS+ / FORS / hypertree; AVX2 SHA-256.
- **R32.M5 — TPM 2.0 CRB + TIS driver** (M, p0, 5 issues): interface discovery; command/response FIFO; locality management; PCR read/extend; TPM2_GetRandom; TPM2_HierarchyChangeAuth.
- **R32.M6 — Intel MEI + PTT/fTPM path** (M, p0, 4 issues): HECI transport; MEI client discovery; PTT client binding; `EFI_TCG2_PROTOCOL` compatibility.
- **R32.M7 — Measured-boot deepening** (M, p0, 5 issues): full boot-chain PCR extends (kernel, userspace init, driver-framework, ACPI bubble); TCG event-log via ACPI TPM2 table; remote-attestation quote path.
- **R32.M8 — Crypto server + typed keypair caps** (M, p0, 4 issues): `KIND_KEM_KEYPAIR`/`KIND_SIG_KEYPAIR`/`KIND_AEAD_KEY` phantom-typed derived kinds; per-algorithm mint policy; audit channel.

---

### 2.5 R33 — I²C-HID + Synaptics/ELAN touchpad + trackpoint tunnel + full HID class stack

**Pillar alignment.** P3 (HID class + I²C bus drivers are userspace); P9 (I²C bus driver publishes hot-plug channel); P8 (raw HID → typed input records is where the semantic-terminal input path begins).

**Systems-architecture concerns.**
- Intel LPSS I²C controllers appear as PCI devices with vendor-specific ACPI enumeration. LPSS controllers cannot be bound without ACPICA (`_ADR` / `_CRS` on the child bus tree), which is exactly why R29 must precede this round.
- I²C-HID (Microsoft's protocol per HID over I²C 1.0 spec) uses a wake-line-driven interrupt (`HID-DESCRIPTOR` at register `0x0020` per `_DSM` UUID `4F1F...`); interrupt latency budget for touchpad is < 8 ms to keep gesture feel.
- The TrackPoint on T14 G4 is *PS/2 protocol tunneled through I²C-HID* (per Lenovo firmware convention). A single I²C-HID device advertises both touchpad and pointer report descriptors on distinct report IDs. The class driver must demux per report ID.
- Report parsing must be a *pure function of the report descriptor*, not per-vendor `#ifdef` — parse the descriptor once, generate a typed parser per device.

**Milestones and issues.**

- **R33.M1 — LPSS I²C bus driver** (M, p0, 4 issues): Intel LPSS I²C controller (Designware IP); FIFO xfer + DMA xfer; ACPI-side `_HID`/`_CRS` binding; `KIND_I2C_BUS` cap.
- **R33.M2 — I²C-HID class driver** (M, p0, 4 issues): `_DSM` HID-desc address discovery; interrupt-driven report read; report descriptor parse; typed HID report record.
- **R33.M3 — HID report descriptor compiler** (M, p0, 4 issues): descriptor parser (HID 1.11); per-device typed report struct emission at driver bind time; usage-page + usage-ID enum.
- **R33.M4 — Touchpad class (Synaptics/ELAN + generic)** (M, p0, 4 issues): multitouch report (HID digitizer usage page 0x0D); contact ID tracking; palm-rejection heuristics as first-class typed algebra (not tunables).
- **R33.M5 — TrackPoint via I²C-HID tunnel** (S, p0, 4 issues): PS/2-in-HID demux; pointer-report record; TrackPoint sensitivity via ThinkPad HKEY (R31 bridge).
- **R33.M6 — Gesture library (touchpad → semantic input)** (M, p1, 4 issues): 2/3/4-finger swipe recognition; pinch/zoom; typed `KIND_GESTURE_STREAM`; consumer is the compositor at R38.

---

### 2.6 R36 — HDA controller (Intel cAVS 2.5) + Realtek ALC287 codec + jack detect + PCM

**Pillar alignment.** P3 (audio server in userspace); P9 (HDA is a hot-pluggable bus for codecs); P1 (SSE2 for sample-rate conversion; AVX2 opt path for the compute-2D compositor's audio-visual sync at R38).

**Systems-architecture concerns.**
- Raptor Lake exposes both a legacy HDA controller AND an Intel cAVS 2.5 DSP with its own firmware (SOF / Sound Open Firmware). MVP uses legacy HDA; the DSP path is filed as an R43+ follow-up because dual-mic beam-forming and echo-cancel on the ALC287 require the DSP.
- HDA is a *streaming DMA* protocol — CORB/RIRB command rings + BDL (buffer descriptor list) for PCM streams. The BDL entries must live in a WB-cached region with `clwb` fences before the controller reads them (Intel HDA spec §3.3).
- Jack detection is an *asynchronous notification* through Realtek codec verb 0xF00; must be routed as a hot-plug event through the driver framework (`KIND_AUDIO_JACK_EVENT`), not polled.
- Interrupt aggregation: HDA MSI vector fires for a set of streams simultaneously; the ISR must be O(1) in the number of active streams (bitmap-based dispatch, no per-stream scan).

**Milestones and issues.**

- **R36.M1 — HDA controller driver** (M, p0, 5 issues): PCI probe (class 04/03); CORB/RIRB rings; interrupt routing; MSI-X binding; reset dance.
- **R36.M2 — Codec enumeration + verb table** (M, p0, 4 issues): codec address scan; widget graph walk; typed `KIND_HDA_CODEC` per codec; verb send/receive with typed responses.
- **R36.M3 — Realtek ALC287 codec init** (M, p0, 4 issues): vendor coef init sequence (verb 0x500/0x400); pin widget config; DAC/ADC routing default; HP amp; SPK amp.
- **R36.M4 — PCM stream engine** (M, p0, 5 issues): BDL construction; stream descriptor programming; ring/wall-clock cursor; sample-rate/format negotiation; typed `KIND_PCM_STREAM`.
- **R36.M5 — Jack detection + hot-plug** (S, p0, 4 issues): unsolicited response handler; jack sense verb (0xF09); typed jack event stream; auto-mute speaker on HP insert.
- **R36.M6 — Audio server (paideia-audio)** (M, p1, 4 issues): mixer graph; per-app stream caps; volume control; latency-bounded scheduling on a reserved LP-E core.

---

### 2.7 R41 — Wi-Fi 6E (Intel AX211 via CNVi/iwlwifi) + Bluetooth (Intel HCI over USB)

**Pillar alignment.** P6 (WPA3-SAE + hybrid handshake ready via R32 crypto; MAC randomisation on scan); P3 (Wi-Fi + Bluetooth stacks fully userspace); P5 (802.11ax first — no ac/n/g fallback binaries; scan and associate at HE-MCS or fail).

**Systems-architecture concerns.**
- AX211 is a **CNVi (Connected Network Interface)** part per hwman confirmation — the MAC is exposed to the OS over a CNVi transport, not PCIe. iwlwifi binds to the CNVi companion device; the RF frontend lives on the PCH-integrated CRF (Companion RF). This means R22's ECAM cap is not sufficient; a *CNVi bus driver* is required.
- **Firmware blob is mandatory.** Per hwman: the UMAC (upper MAC) firmware runs on the wireless MAC processor and is a proprietary Intel blob. No open alternative. This forces the **blob-driver capability policy** (`design/drivers/blob-policy.md`) to close before this round; the AX211 driver runs under `blob_driver_cap` with a dedicated IOMMU domain, no audit-write capability, no reserved-core cap (per `design/drivers/framework.md` §DR-D11).
- The DMA descriptor rings must live in an IOMMU-isolated domain; a compromised UMAC firmware cannot exfiltrate host memory beyond the ring buffer window.
- Bluetooth on T14 G4 is Intel HCI over the internal USB (AX211 shares silicon with BT; BT surfaces as a USB device on the internal USB hub). HCI transport is USB bulk + interrupt endpoints. LE Audio (BAP/CAP profiles) requires isochronous endpoints (xHCI already handles them, but PCM streaming to LE Audio needs the R36 PCM engine as producer).

**Milestones and issues.**

- **R41.M1 — CNVi bus driver + AX211 probe** (M, p0, 5 issues): CNVi transport; AX211 device ID enumeration; MFG-mode boot; firmware load handshake.
- **R41.M2 — iwlwifi-analogue MVM/UMAC firmware loader (blob-driver)** (L, p0, 5 issues): blob signature verify against Intel key pinned in `design/security/pq-trust-root.md`; per-driver IOMMU domain; UMAC init cmd sequence.
- **R41.M3 — 802.11 MAC state machine** (L, p0, 6 issues): scan (active/passive); association; deauth/disassoc; MLME; regulatory-domain enforcement; PMF.
- **R41.M4 — WPA3-SAE + KRACK-safe handshake** (M, p0, 5 issues): 4-way handshake driven by R32 crypto server; SAE per RFC 7664 / draft-ietf-wpa3; PMKSA cache; MFP required.
- **R41.M5 — 802.11ax HE-MCS + rate control + TX/RX ring** (M, p1, 5 issues): HE-MCS 0..11 table; MU-MIMO; OFDMA; PER-driven rate control.
- **R41.M6 — Bluetooth HCI over USB (Intel)** (M, p0, 5 issues): HCI transport (bulk-out cmd + bulk-in event + isoc SCO); Intel firmware load (blob-driver policy); HCI reset + set-address.
- **R41.M7 — L2CAP + RFCOMM + HID over BT** (M, p1, 5 issues): L2CAP channels; RFCOMM; HID-over-BT profile; pair keyboard/mouse.
- **R41.M8 — LE + GATT + LE Audio (BAP)** (L, p1, 6 issues): LE advertising/scanning; GATT client/server; SM pairing (LE Secure Connections); LE Audio Basic Audio Profile.

---

### 2.8 R42 — Thunderbolt 4 / USB4 protocol above xHCI

**Pillar alignment.** P6 (per-dock IOMMU domain; PCIe-tunnel over TBT gets its own capability scope); P9 (TBT is the archetypal hot-pluggable bus); P5 (USB4-only — no TBT2/3 daisy-chain compat).

**Systems-architecture concerns.**
- On Raptor Lake U/P per hwman, TBT4 is *integrated into the SoC* — there is no discrete Maple Ridge NHI. The OS sees the on-die NHI (Native Host Interface) as a PCIe device plus a firmware-mediated Connection Manager. Only one driver stack.
- The **crown-jewel security question**: when a TBT4 dock hot-plugs a downstream PCIe device (e.g. a docked NVMe), do we mint a `KIND_PCI_DEV` cap for it? The proposal is *yes, but under a per-dock IOMMU domain* — the dock is a first-class capability-scoping unit, and a compromised device on that dock cannot IOMMU-attack the host.
- USB4 tunnels three protocol types over the same physical link: USB3, DisplayPort, and PCIe. DP-tunnel plumbs into R34's display engine as a virtual DDI. PCIe-tunnel plumbs into R22's ECAM enumerator as a virtual root complex.
- Connection Manager: TBT4 supports both firmware-CM (default, safer) and software-CM (Linux-like, more capable, harder to secure). MVP is firmware-CM; software-CM is filed as R43+ scope.

**Milestones and issues.**

- **R42.M1 — On-die NHI driver + firmware handshake** (M, p0, 4 issues): NHI PCIe probe; TX/RX rings for CM commands; firmware-CM init.
- **R42.M2 — Connection Manager event stream** (M, p0, 4 issues): typed `KIND_TBT_EVENT` (device-connected, device-disconnected, security-level-change); route to driver framework.
- **R42.M3 — TBT security-level + user consent** (M, p0, 4 issues): SL0..SL3 (None/User/Secure/DP-only) per Intel TBT security spec; user-consent flow through display server; audit log; ML-DSA-signed dock allowlist.
- **R42.M4 — DP-tunnel adapter** (M, p1, 4 issues): virtual DDI mapping; DP-AUX pass-through; hot-plug through R34 display engine.
- **R42.M5 — PCIe-tunnel + per-dock IOMMU domain** (L, p0, 5 issues): virtual root-complex enumeration under the dock BDF; per-dock IOMMU DID allocation; ATS/PRS gating.
- **R42.M6 — USB3-tunnel + power / USB-PD** (M, p1, 5 issues): virtual xHCI extension; USB-PD contract negotiation; DP-alt-mode via USB-PD SVDMs.

---

### 2.9 R43 — MIPI CSI-2 + IPU6 camera + fingerprint + WWAN + misc sensors

**Pillar alignment.** P6 (fingerprint template signed under ML-DSA; IPU6 firmware under blob-driver policy); P3 (each driver its own userspace server); P9 (WWAN and CSI camera are hot-plug via M.2 slot / USB / ACPI).

**Systems-architecture concerns.**
- IPU6 is a *microkernel-inside-a-microkernel*: it runs its own scheduling, has its own MMU (IPU MMU), and requires a large firmware blob (`ipu6-fw`). It also requires per-sensor `libcamera`-style pipeline tuning files. Per hwman: blob is mandatory, no open alternative. The IPU6 driver takes `blob_driver_cap`; the pipeline tuning file signature is checked at load.
- CSI-2 receiver DMA feeds into IPU6, not into host memory directly. The camera server therefore exposes a *typed frame stream* (`KIND_CAMERA_FRAME`) whose backing memory is IOMMU-mapped from IPU6's isolated domain into the consumer's AS on demand.
- Fingerprint sensors (Synaptics or Goodix) are USB devices with vendor-specific enrolment protocols. Template storage must be encrypted with a key sealed to TPM PCRs (R32 dependency) so a stolen NVMe cannot yield usable templates.
- WWAN M.2 3042 (Fibocom L860 / Qualcomm SDX55) exposes MBIM (Mobile Broadband Interface Model) over USB. Signal-strength + registration state through typed record streams (P8).

**Milestones and issues.**

- **R43.M1 — CSI-2 receiver + IPU6 firmware loader** (L, p0, 5 issues): IPU6 PCIe probe (device ID *TODO-verify against Intel Raptor Lake-U datasheet*); firmware blob load; IPU MMU init; blob-driver capability minting.
- **R43.M2 — IPU6 pipeline + sensor bind** (L, p0, 5 issues): pipeline tuning file (`.aiqb`) load; sensor discovery (OV02C10 / IMX208 typical on T14 G4 — *TODO-verify per shipped SKU*); 3A (AE/AWB/AF) loop.
- **R43.M3 — Camera server + frame streaming** (M, p0, 4 issues): typed `KIND_CAMERA_FRAME`; frame ring; consumer-side IOMMU mapping; user-consent LED semantics.
- **R43.M4 — Fingerprint (Synaptics/Goodix USB)** (M, p0, 4 issues): vendor protocol; enrol/verify FSM; template AEAD-encrypted with TPM-sealed key.
- **R43.M5 — WWAN M.2 (MBIM over USB)** (M, p1, 4 issues): MBIM class driver; QMI fallback for Qualcomm; connection state machine.
- **R43.M6 — WWAN network integration** (M, p1, 4 issues): raw IP mode; bring-up into R27 IPv4 + R32.5 TCP stack; APN + PIN.
- **R43.M7 — Additional ACPI sensors (hinge, ambient light, e-privacy)** (S, p2, 3 issues): `ACPI0016` binding; unit conversion; typed sensor stream.
- **R43.M8 — Camera privacy shutter + hardware kill enforcement** (S, p0, 3 issues): F9 privacy shutter GPIO through EC (R31 bridge); enforced camera-off state; audit log.

---

## 3. Axis 2 — GPU-native graphical interface

### 3.0 Architectural stance + pitfall register

The graphical stack is layered as follows, with each layer a userspace server per Pillar 3:

```
                    ┌─────────────────────────────────────────────┐
                    │      Applications (paideia-terminal,        │
                    │      paideia-shell, semantic viewers)       │
                    └─────────┬───────────────────────────────────┘
                              │ paideia-window-protocol (PWP)
                              │  — explicit-sync timelines
                              │  — presentation-time feedback
                              │  — accessibility in wire format
                              ▼
        ┌─────────────────────────────────────────────────────────┐
        │        paideia-compositor (userspace)                    │
        │   render graph · damage tracking · buffer-age            │
        │   direct-scanout bypass · VRR · HDR/ICC transform        │
        └──────┬──────────────────────────────────┬────────────────┘
               │                                  │
               ▼                                  ▼
       ┌───────────────────┐              ┌─────────────────────┐
       │ paideia-vello     │              │ paideia-input       │
       │ compute-2D + SDF  │              │ (compositor-INDEP)  │
       │ text (GPU tile)   │              │ HID/I²C-HID/touch/  │
       └───────┬───────────┘              │ TB4-HID/gesture     │
               │                          └─────────────────────┘
               │ SPIR-V + timeline sema
               ▼
       ┌───────────────────────────────────────────────────────────┐
       │        paideia-vk  (Vulkan-native, Iris Xe Gen12)         │
       │        pipelines · queues · sync objects                  │
       └───────┬───────────────────────────────────────────────────┘
               │
               ▼
       ┌───────────────────────────────────────────────────────────┐
       │        paideia-gem  (GPU memory + command streamer)        │
       │        GTT/PPGTT · BOs · contexts · engines · reset       │
       └───────┬───────────────────────────────────────────────────┘
               │
               ▼
       ┌───────────────────────────────────────────────────────────┐
       │        paideia-drm (KMS-equivalent: display engine)        │
       │        pipes · planes · transcoders · DDIs · CRTC         │
       └───────────────────────────────────────────────────────────┘
```

**Pitfall register.** Each pitfall becomes an invariant enforced at a specific layer.

| # | Pitfall | Layer | Invariant |
|---|---|---|---|
| G1 | Implicit dmabuf sync (NVIDIA-on-Wayland flicker) | paideia-vk, PWP | Timelines only; every buffer handoff carries a `(timeline_id, value)` wait+signal pair. No fallback to implicit path. |
| G2 | Compositor hang locks input | paideia-input | Input server is compositor-independent, holds its own recovery-console cap, and can render an emergency framebuffer if the compositor is dead. |
| G3 | Fractional scaling by supersample | paideia-vk + PWP | The scale factor is a *first-class geometry parameter*; clients render at the target pixel grid; the compositor never downsamples an oversampled surface. |
| G4 | Accessibility as sidecar | PWP | Every window advertises an *accessibility subtree* as part of the wire protocol; screen reader is a first-class PWP client, not an X-Server-side-channel. |
| G5 | HDR as retrofit | paideia-drm + compositor | Composition space is scRGB-linear (fp16); output transform (PQ or HLG) is a display-engine LUT + shader per output. ICC v4 profiles are mandatory. |
| G6 | Input latency drift | compositor + PWP | Every present carries `(target_time, actual_time, refresh_period)` back to the client (presentation-time feedback); the compositor budgets one refresh, not two. |
| G7 | VRR + fullscreen tearing regressions | paideia-drm | Direct-scanout with VRR-safe cadence is the *default* for a fullscreen client, not an opt-in flag. |
| G8 | Compositor-locked recovery | paideia-drm | The recovery console has a reserved plane on the primary pipe that the compositor cannot claim. |
| G9 | Font-rendering blur under scale | paideia-vello | SDF glyphs with subpixel positioning at render time; no glyph atlas caching keyed on integer positions. |
| G10 | Fragmented IME | PWP | One IME protocol, one keyboard-event contract, one text-input-3-analogue — the compositor is the exclusive router. |

**Cited prior art** (verified references; §8 lists all):
- Explicit-sync timelines: Vulkan `VK_KHR_timeline_semaphore` (Ekstrand et al., Khronos, 2019); Linux `drm_syncobj` timelines (Ekstrand, LWN 2020–2021 series).
- Compute-2D: Levien, "vello" and predecessor "piet-gpu" (open source; Levien has written a design writeup at raphlinus.github.io on 2020-05-19 "A sort-middle architecture for 2D graphics" and follow-ups). The piet-gpu-hal / wgsl split is documented in the Vello repository.
- SDF text: Lengyel, "GPU-Centered Font Rendering Directly from Glyph Outlines," *Journal of Computer Graphics Techniques* (JCGT) 6(2), 2017. (Slug library companion.)
- Direct scanout / presentation-time: Chromium Viz architecture (Chromium project design docs, `docs/ui/ozone/`); Wayland `wp_presentation` protocol.
- HDR pipeline: BT.2100 (ITU-R Recommendation, 2016 and later revisions); Apple EDR documentation (WWDC 2020, 2021); Chris Wilson's Linux HDR series on LWN (2023–2024, *TODO-verify exact LWN URLs*).
- Adaptive Sync: VESA DisplayPort AdaptiveSync (part of DP 1.2a addendum, 2014); Intel eDP-VRR support notes in i915 driver commit history (verify latest state via kernel git log).
- Compositor architecture references: Fuchsia Scenic (`fuchsia.dev/reference/fidl/fuchsia.ui.composition`), Windows DirectComposition (Microsoft docs), macOS Metal-CoreAnimation integration (Apple WWDC 2019 "Modern Rendering with Metal", 2021 "Discover advances in Metal for A14 Bionic").
- Wayland-fragmentation critique: multiple LWN articles 2022–2024 covering the wlroots / GNOME Mutter divergence and the ext- vs wp- protocol chaos.

### 3.1 Round schedule at a glance (Axis 2 rows)

| Round | Theme | Est. issues | Milestones |
|---|---|---:|---:|
| **R34** | `paideia-drm` — Iris Xe Gen12 display engine (pipes, planes, transcoders, DDIs, CRTC, eDP + HDMI + DP-alt) | 30 | 6 |
| **R35** | `paideia-gem` — GPU memory + command streamer (GTT/PPGTT, BOs, contexts, RCS/BCS/VCS engines, hang detect, reset) | 28 | 6 |
| **R37** | `paideia-vk` — Vulkan-native path + color management + HDR compositing space | 28 | 6 |
| **R38** | Direct scanout + VRR + presentation-time + compositor v0 (paideia-compositor scaffold) | 26 | 6 |
| **R39** | `paideia-vello` — compute-2D + SDF text + IME | 30 | 7 |
| **R40** | `paideia-window-protocol` — windowing + accessibility + gesture routing + input event routing | 30 | 7 |

**Axis 2 subtotal:** ~172 issues across 6 rounds (R34, R35, R37, R38, R39, R40).

---

### 3.2 R34 — `paideia-drm`: Iris Xe Gen12 display engine (KMS-equivalent)

**Pillar alignment.** P3 (display engine driver is userspace); P5 (no VBE / no VGA fallback — GOP → paideia-drm directly); P9 (each DDI is hot-pluggable via TBT4 at R42); P6 (framebuffer memory is capability-scoped; no display-controller DMA outside its IOMMU domain).

**Systems-architecture concerns.**
- Iris Xe Gen12 display engine has *pipes → planes → transcoders → DDIs*. Per-pipe hardware plane counts and per-plane color LUT sizes on Gen12 are documented in the Intel Gen12 PRM (Volume 12: Display Engine). *TODO-verify current pipe/plane count against the Alder Lake / Raptor Lake variant of the PRM.* Recent i915 kernel commits confirm the plane count is 7 planes/pipe on Gen12+ but the compositor design should treat this as a runtime-queried number.
- The display engine's CDCLK (Core Display Clock) must be programmed before enabling any pipe; wrong CDCLK produces immediate underrun and screen tearing. CDCLK squash+crawl transitions are supported on Gen12 and must be used to avoid mode-set flashes.
- eDP PSR2 (Panel Self-Refresh 2) is required for battery; it interacts with backlight AUX (R31.M4) and with cursor updates (single-frame updates must skip PSR entry). *TODO-verify PSR2 default state on Raptor Lake per current i915 source (hwman noted this as uncertain).*
- DDI topology on T14 G4: eDP is DDI-A (or DDI-eDP on newer variants); external outputs use DDI-B..DDI-F depending on the specific chassis wiring. Exact DDI count is *TODO-verify per T14 G4 schematic*; the paideia-drm driver queries at probe.

**Milestones and issues.**

- **R34.M1 — MMIO discovery + GT power well sequencing** (M, p0, 4 issues): BAR0 mapping; PWR_WELL_CTL enable dance; RC6 defer; GT interrupt setup.
- **R34.M2 — CDCLK + reference clock init** (M, p0, 4 issues): CDCLK squash-and-crawl programming; DPLL config; reference PLL for DP/HDMI.
- **R34.M3 — Pipes + transcoders** (M, p0, 5 issues): pipe A/B/C enable FSM; transcoder programming; PIPE_CONF; vblank interrupts.
- **R34.M4 — Planes (primary/overlay/cursor) + WM (watermark)** (M, p0, 5 issues): plane sizing; WM latency programming; SAGV; DBUF slice allocation.
- **R34.M5 — DDIs + eDP + HDMI + DP-alt** (L, p0, 6 issues): DDI clock config; eDP link training (DP 1.4); HDMI TMDS/FRL; DP-alt through TBT4 stub for R42 completion.
- **R34.M6 — Modeset + hotplug + panel PSR2** (M, p0, 6 issues): mode enumeration via EDID/DisplayID; atomic modeset primitive; HPD interrupt routing; PSR2 enter/exit.

---

### 3.3 R35 — `paideia-gem`: Iris Xe Gen12 render engine + memory

**Pillar alignment.** P3 (GEM lives in a userspace GPU server); P1 (context descriptor + LRC layout is architecture-specific by design); P6 (each GPU context runs under an isolated PPGTT; cross-process BO sharing goes through explicit-sync export).

**Systems-architecture concerns.**
- Iris Xe Gen12 has three primary command engines: RCS (Render), BCS (Blitter), and VCS (Video). Command submission uses execlists (Intel's per-context ring architecture) with the LRC (Logical Ring Context) — a 64 KB context descriptor per context per engine.
- GEM buffer objects are backed by either **stolen memory** (BIOS-reserved for the display engine), **system memory** (WB or WC PAT), or **LMEM-ish** (Xe-LP has no discrete VRAM, but Gen12 supports a "system-graphics-only" memory pool). Xe-LP on Raptor Lake has no dedicated VRAM.
- PPGTT (Per-Process GTT) is a 48-bit virtual GPU address space per context — this is *literally* a page table walked by the GPU, and page-in/out semantics must interact with the R22 IOMMU (IOMMU sits above PPGTT). BO pinning discipline determines when a BO can be paged.
- Command streamer submission from userspace requires the paideia-as `@gpu_batch` effect (paideia-as v0.26 ask in §5) so batch construction is a linear-type-tracked operation — no fire-and-forget MMIO writes.
- Hang detection: the GPU's own hangcheck (ELSP queue timeout) plus a software watchdog; recovery is per-engine reset first, per-GT reset second, full GPU reset last resort.

**Milestones and issues.**

- **R35.M1 — GT reset + power domain** (M, p0, 4 issues): full GPU reset dance; RC6 residency stats; forcewake.
- **R35.M2 — GTT + PPGTT + BO allocator** (L, p0, 6 issues): global GTT setup; PPGTT per-context creation; BO create/destroy; pin/unpin; PAT selection (WB/WC/UC).
- **R35.M3 — Contexts + LRC per engine** (M, p0, 5 issues): LRC layout for RCS/BCS/VCS on Gen12; per-context state save; scheduler hooks.
- **R35.M4 — Execlists submission (RCS)** (M, p0, 5 issues): ELSP write; guc-less fallback path; batch buffer submission; MI_BATCH_BUFFER_START.
- **R35.M5 — Blitter (BCS) + Video (VCS) engines** (M, p1, 4 issues): BCS for framebuffer blits (Vello can use it as fast path for opaque tile fills); VCS for future codec bring-up (deferred).
- **R35.M6 — Hang detect + per-engine reset** (M, p0, 4 issues): hangcheck FSM; ELSP timeout; RESET_ENGINE MMIO; error state capture; audit log.

---

### 3.4 R37 — `paideia-vk`: Vulkan-native + color management + HDR

**Pillar alignment.** P1 (SPIR-V lowering targets Gen12 EU ISA); P3 (Vulkan driver in userspace); P5 (Vulkan only — no GL/GLES; no OpenGL compat context).

**Systems-architecture concerns.**
- SPIR-V → Gen12 EU ISA lowering is the biggest single piece of the round. Intel's open-source lowering pass (in Mesa's `intel/compiler`) is the reference; we cannot reuse it directly (Mesa is C, we are assembly) but we can *cite its passes as design landmarks* and re-implement in paideia-as.
- Pipeline compilation caches must be signed under ML-DSA (R32) so a compromised NVMe cannot inject shader binaries.
- Memory heaps: because Xe-LP has no dedicated VRAM, all Vulkan memory is `HOST_VISIBLE | HOST_COHERENT` or `HOST_VISIBLE | HOST_CACHED` (with `vkFlushMappedMemoryRanges` semantics mapping to `clwb`).
- Timeline semaphores are the ONLY sync primitive exposed at the Vulkan API level — binary semaphores are deprecated in our profile from day one (Pillar 5).
- Color management: the swapchain surface format defaults to `VK_FORMAT_R16G16B16A16_SFLOAT` in scRGB-linear; SDR clients render in sRGB and the compositor applies the sRGB→scRGB-linear inverse transform per source-plane LUT.

**Milestones and issues.**

- **R37.M1 — Vulkan 1.3 loader + instance** (M, p0, 4 issues): loader stubs; instance creation; physical-device enumeration; queue-family exposure (RCS as graphics+compute, BCS as transfer).
- **R37.M2 — SPIR-V IR reader + validator** (L, p0, 5 issues): SPIR-V binary parser; validation layer scaffold; capability check (SubgroupOps, StorageBuffer16BitAccess).
- **R37.M3 — SPIR-V → Gen12 EU ISA lowering** (XL, p0, 6 issues): scalarisation; instruction selection; register allocation; peephole; ISA emit. **Largest single milestone in Axis 2.**
- **R37.M4 — Pipeline compiler + cache** (M, p0, 4 issues): VkPipeline; per-stage compile; disk-persisted cache with ML-DSA signature.
- **R37.M5 — Timeline semaphores + memory model** (M, p0, 4 issues): timeline sync objects on top of R35 fences; Vulkan memory model coherence via `clwb` fences.
- **R37.M6 — Swapchain in scRGB-linear + color management** (M, p0, 5 issues): swapchain format policy; sRGB→linear inverse transform LUT; per-output ICC v4 profile; HDR10 metadata infoframe.

---

### 3.5 R38 — Direct scanout + VRR + presentation-time + compositor v0

**Pillar alignment.** P2 (per-CPU render-thread pinning); P6 (recovery-console reserved plane per G8); P3 (compositor is a userspace server).

**Systems-architecture concerns.**
- **Direct-scanout fullscreen bypass** (against G7): when a single fullscreen client owns the primary pipe, its buffers are handed straight to a display-engine plane, bypassing the compositor's render step entirely. The compositor still owns the timeline handoff, but does not GPU-composite.
- **VRR (Adaptive Sync)**: on internal eDP + supported panels, the compositor drives frame timing by programming pipe timings on demand. AdaptiveSync range comes from the DPCD 0x000E `_MISC_CAPABILITIES` per DisplayPort 1.4. Cadence enforcement (no VRR hitches) is done by clamping the min-refresh at 2× the previous frame duration.
- **Presentation-time feedback** (against G6): every present carries `(target_time, actual_time, refresh_period_ns)` back to the client. This closes the loop that Wayland's `wp_presentation` opened; we improve on it by making the feedback *typed and mandatory*, not opt-in.
- **Recovery-console reserved plane** (against G8): plane 0 on pipe 0 is reserved for the compositor-independent recovery console. If the compositor dies, the input server + recovery console render a text mode on that plane; the user can invoke the driver framework to restart the compositor.

**Milestones and issues.**

- **R38.M1 — Direct-scanout path** (M, p0, 4 issues): compositor pipeline analyzer (single-fullscreen-client detect); direct plane handoff; PSR2 interaction.
- **R38.M2 — VRR / AdaptiveSync** (M, p0, 4 issues): VRR-capable output detect; VRR pipe programming; cadence clamp.
- **R38.M3 — Presentation-time feedback loop** (M, p0, 4 issues): typed `PresentFeedback` record; per-swapchain-image feedback; per-client latency budget.
- **R38.M4 — Compositor v0 (scaffold)** (L, p0, 6 issues): compositor process; per-surface state; render graph placeholder; input-server IPC hook (for G2 independence); recovery-console reserved plane enforcement.
- **R38.M5 — Damage tracking + buffer-age** (M, p0, 4 issues): per-surface damage regions; buffer-age heuristic; incremental redraw.
- **R38.M6 — HDR output transform (PQ + HLG)** (M, p0, 4 issues): HDR10 tone-map; PQ EOTF; HLG OETF; per-display peak-luminance metadata.

---

### 3.6 R39 — `paideia-vello`: compute-2D + SDF text + IME

**Pillar alignment.** P1 (AVX2 opt path for CPU-side path pre-processing); P3 (paideia-vello runs as a shared render service); P8 (typed text records → SDF glyph runs).

**Systems-architecture concerns.**
- **Vello lineage** (against G9 blur + against per-glyph atlas): the rasteriser is compute-first — path curves are subdivided on the GPU, coarse-rasterised into tiles, then per-tile scanline blend into the output. This design is documented in Raph Levien's "vello" open-source project and predecessor "piet-gpu"; the piet-gpu design doc "A sort-middle architecture for 2D graphics" (Levien, raphlinus.github.io, 2020-05-19) is the anchor citation for the tile/sort/blend decomposition.
- **SDF text** (against G9): glyph outlines are converted to a signed-distance field (either at build time — precomputed per font — or on-demand at first-use with GPU coverage integration). Slug's approach (Lengyel 2017, JCGT) uses per-glyph analytic distance-field bands, which is superior to raster atlases at fractional scales and rotations.
- **Subpixel positioning at render time**: the SDF sample position is computed to subpixel precision in the fragment shader; no glyph is cached to an integer-pixel-position atlas. This is what makes fractional scaling look correct.
- **IME** (against G10): one IME protocol on top of the PWP text-input surface; committing candidates goes through a compositor-mediated channel so the compositor is the exclusive text-input router. CJK (via IBus-like backend adapted to PWP) and RTL (via typed direction attribute on text runs) are day-one.

**Milestones and issues.**

- **R39.M1 — Path IR + Bezier flattening** (M, p0, 4 issues): path IR (moveto/lineto/curveto/quadto); GPU-side flattening pass.
- **R39.M2 — Tile assignment + sort-middle** (L, p0, 5 issues): per-path tile assignment (compute shader); sort-middle merge; per-tile command list.
- **R39.M3 — Per-tile scanline blend** (M, p0, 5 issues): pixel-perfect blend; premultiplied alpha; blend-mode LUT.
- **R39.M4 — SDF font pipeline** (L, p0, 5 issues): font parser (TrueType 6 / OpenType 1.9 / CFF2); per-glyph SDF generation (analytic bands per Slug); font-atlas-free rendering.
- **R39.M5 — Subpixel positioning + hinting-free rendering** (M, p0, 4 issues): fragment-shader subpixel eval; gamma-correct alpha; no hinting (renders correctly at all scales).
- **R39.M6 — Text-input protocol + IME** (M, p0, 4 issues): text-input surface; preedit + commit; CJK IME backend integration point; RTL direction attribute.
- **R39.M7 — Native Unicode text layout (BiDi + shaping)** (L, p0, 3 issues): UAX #9 BiDi (P8); OpenType shaping via HarfBuzz-analogue in paideia-as (deferred piece for R42+); direction-aware caret.

---

### 3.7 R40 — `paideia-window-protocol` + accessibility + gesture routing + input event routing

**Pillar alignment.** P5 (single coherent protocol — no wp- / ext- / KDE-specific- split); P6 (accessibility tree is in the protocol, per-window ACL); P9 (each input device hot-plugs into the input server via typed channel).

**Systems-architecture concerns.**
- **Single protocol** (against G4 fragmentation): `paideia-window-protocol` (PWP) is the sole client-facing protocol. There is no extensible-namespace addition path in the sense of Wayland `ext-*` protocols; new capabilities land in a minor version bump of PWP, not as sidecar protocols. This is Pillar 5 taken seriously.
- **Accessibility in the protocol** (against G4): every window exposes an accessibility subtree as part of its PWP handshake. Screen readers are PWP clients that request the a11y-tree of the focused window through a typed channel; there is no AT-SPI-like sidecar bus. The a11y tree is a *typed record graph* per Pillar 8.
- **Input event routing** (against G2 + G10): input events (keyboard, pointer, touch, gesture, IME) route through the paideia-input server (R38.M4) which is *outside the compositor's process space*. The compositor requests focus from the input server; if the compositor dies, input still works and the recovery console still receives events.
- **Per-device gestures**: the touchpad gesture recogniser (R33.M6) publishes a typed `KIND_GESTURE_STREAM` that the compositor may bind to global actions (workspace switch, overview). Compositor-side gestures do not preempt the input server's device-level routing.

**Milestones and issues.**

- **R40.M1 — PWP wire format + connection handshake** (M, p0, 4 issues): typed record framing; connection FSM; version negotiation; capability advertisement.
- **R40.M2 — Surface + role + commit atomicity** (L, p0, 5 issues): surface object; roles (window, popup, tooltip, cursor); commit atomicity; timeline sync attach.
- **R40.M3 — Window management (positioning, focus, workspace)** (L, p0, 5 issues): window state (mapped/unmapped/minimised); focus policy; workspace / virtual desktop.
- **R40.M4 — Accessibility subtree protocol** (L, p0, 4 issues): a11y tree record definition; role/state/action enums; screen-reader client protocol; typed queryability per Pillar 8.
- **R40.M5 — Keyboard event contract + IME routing** (M, p0, 4 issues): typed key events; keymap negotiation; modifier state; IME preedit routing through compositor.
- **R40.M6 — Pointer/touch/stylus event contract** (M, p0, 4 issues): pointer motion/button; multi-touch contact stream; stylus tilt/pressure/eraser; per-device axis vs per-event axis.
- **R40.M7 — Gesture routing + global gesture channel** (M, p1, 4 issues): touchpad gesture stream binding; compositor-global gestures; conflict resolution with per-window gestures.

---

## 4. Sequencing rationale

### 4.1 Serial vs parallel structure

- **Strictly serial** (each blocks the next by construction):
  - R29 → R31 (ACPICA is the only way to talk to the EC)
  - R29 → R33 (LPSS I²C is enumerated by ACPI)
  - R29 → R36 (HDA jack-detect notify comes through ACPI)
  - R34 → R35 (rendering into nowhere is meaningless without a display)
  - R35 → R37 (Vulkan cannot lower without a command streamer)
  - R37 → R38 (compositor needs the swapchain contract)
  - R38 → R39 (Vello needs the compositor's timeline handoff to sync per-frame)
  - R39 → R40 (windowing needs text/IME to be a usable protocol)
  - R32 → R41 (WPA3-SAE needs PQ-safe crypto substrate)
  - R22 → R42 (TB4 tunnels PCIe onto the IOMMU)
  - R32 → R43 (fingerprint templates need TPM-sealed AEAD)

- **Parallelisable within a wave** (can proceed concurrently once their upstream lands):
  - After R29 lands: R30, R31, R33, R36 can run in parallel (all consume ACPI + the HID class stack independently).
  - After R37 lands: R38 and R43 (camera) can proceed on distinct teams — camera needs no GUI dependency.
  - R41 (Wi-Fi + BT) can start any time after R32 completes; it has no GUI dependency.

### 4.2 Which drivers unblock which GUI features

- **R29 ACPICA → R34 paideia-drm**: eDP power sequencing (`_PS0`/`_PS3`) and PSR2 wake-up notifications route through ACPI. Without ACPICA, the display engine cannot sleep correctly.
- **R31 backlight → R34.M6**: PSR2 entry hides backlight-brightness transitions during panel refresh; the backlight controller must announce brightness changes to the display engine.
- **R33 touchpad + gesture → R38 compositor v0 + R40 gesture routing**: the compositor needs a typed gesture stream to bind global actions; without R33, the compositor has only keyboard + mouse.
- **R36 HDA → future audio-visual sync in R39/R40**: the presentation-time feedback loop synchronises with audio streams; HDA must be up before end-to-end AV latency can be measured.
- **R42 TB4 DP-tunnel → R34 DDI**: TB4 hot-plug creates virtual DDIs; the display engine must be able to enumerate + configure them dynamically. R42 files a shim in R34 that R42 fills in.

### 4.3 Which GUI features unblock which drivers

- **R34 paideia-drm → R31.M4 backlight**: eDP AUX-side backlight requires an open DP link, which the display engine owns. R31.M4 is filed as a *stub* if R34 is not yet landed and is completed once R34 exposes the AUX channel.
- **R38 direct-scanout → R43 camera privacy UX**: the camera activity indicator (mandatory F9 privacy shutter status LED) has a screen-side companion (the "camera active" overlay) that lives on a reserved plane above the compositor; this is designed in at R38 so R43 can just fill the plane.
- **R40 accessibility → R43 fingerprint UX**: the fingerprint enrol flow needs a screen-reader-accessible surface for visually-impaired users.

### 4.4 Wall-clock estimate

At the paideia-os continuous-loop tempo (~1 round per 4–6 weeks per `feedback_paideia_os_tempo`):

- Axis 1 pure-serial minimum: R29 → R30 → R31 → R32 → R33 → R36 → R41 → R42 → R43 = 9 rounds ≈ 9–13 months.
- Axis 2 pure-serial: R34 → R35 → R37 → R38 → R39 → R40 = 6 rounds ≈ 6–9 months.
- Total interleaved wall-clock (R29 through R43): 15 rounds ≈ 15–22 months.

Paralellisation (once R29 lands, R30/R31/R33/R36 can proceed on the axis-1 side while R34/R35 open axis-2 side) can compress this to ~12–15 months if the loop runs both axes concurrently.

---

## 5. Cross-repo dependencies on `paideia-as`

Filed early per `feedback_paideia_as_version_discipline`. Each bundle closes with a workspace-version bump + git tag + CHANGELOG entry.

| paideia-as bundle | Contents | Unblocks | Est. weeks |
|---|---|---|---|
| **v0.25 — Crypto substrate** | AVX2 packed-int intrinsics (VPADDQ/VPMULLQ/VPXORQ); PCLMULQDQ; SHA extensions (SHA-NI); constant-time discipline verifier (`@constant_time` attribute); typed BigInt slice; ML-KEM/ML-DSA/SLH-DSA test-vector harness | **R32** (PQ crypto) | ~6 |
| **v0.26 — GPU substrate** | `@device_context` effect (paideia-as effect type; discharged only in a `KIND_DEVICE_CONTEXT`-holding function); `@gpu_batch` linear-typed builder; `clflushopt`/`clwb`/`clflush` intrinsics; PAT-selector helpers; scanline-precise pixel-clock arithmetic (fp32 with rounding modes) | **R34, R35, R37** | ~8 |
| **v0.27 — Float substrate** | SSE/AVX packed-float ops; subnormal handling policy; FTZ/DAZ MXCSR discipline; typed fp32/fp64 with NaN-tainting; SIMD path helpers for Bezier flattening | **R37, R39** (Vello + shader lowering) | ~6 |
| **v0.28 — Audio + streaming substrate** | Deep-buffer ring types (SPSC + MPSC + broadcast); `@isochronous` deadline effect; float32 sample arithmetic; SIMD FIR/IIR helpers | **R36, R41** (LE Audio) | ~4 |
| **v0.29 — Networking substrate refresh** | `@endianness(little)`/`@endianness(big)` marker on struct fields with auto-swap; CNVi transport bindings; typed 802.11 MAC frame parser generator | **R41, R43** | ~5 |
| **v0.30 — TB4 + hot-plug substrate** | `KIND_HOTPLUG_STREAM` typed record channel primitives; per-dock capability-scope inheritance helpers | **R42** | ~3 |
| **v0.31 — SPIR-V lowering substrate** | Not a paideia-as compiler feature per se, but a paideia-as **stdlib module**: SPIR-V binary parser generator; Gen12 EU ISA encoder | **R37** | ~6 |

**File-early recommendation.** v0.25, v0.26, v0.27, and v0.31 should be filed as paideia-as milestones *now*, in parallel with R29–R33 execution on paideia-os. v0.31 (SPIR-V) is the longest lead and drives R37's schedule.

---

## 6. Risk register

Top 10 risks, ranked by expected damage-to-schedule × probability, each with a mitigation.

| # | Risk | Damage | P | Mitigation |
|---|---|---|---|---|
| **R1** | **IPU6 firmware blob under license terms incompatible with our redistribution model** | Very High (camera + potentially display-side computer-vision features are indefinitely blocked) | Med | R43 gate 0: procure Intel's IPU6 firmware distribution license terms before scoping the round; if unfavourable, drop IPU6, ship camera as post-R43 optional module using an external USB webcam under UVC. |
| **R2** | **AX211 CNVi transport is under-documented outside Intel; iwlwifi source is our only public reference** | High (R41 slips 2–3 months) | High | Buy an M.2 2230 discrete-PCIe Wi-Fi card (Intel AX210, non-CNVi) for the T14 G4 as a fallback path; retain AX211 support as the primary target but ship v1 on AX210 topology. |
| **R3** | **SPIR-V → Gen12 EU lowering (R37.M3) is the biggest single milestone; underestimates likely** | High (R37 slips 3–6 months, cascading through Axis 2) | High | Pre-flight R37.M3 as its own scoping doc at R35 close; land a subset of shader capabilities first (vertex + fragment; compute later) so the compositor can proceed. |
| **R4** | **Direct-scanout on Iris Xe Gen12 with PSR2 + VRR interaction is under-tested outside Linux i915** | Med (visible glitches on daily-driver use) | Med | Land direct-scanout without PSR2 first; add PSR2 as R38 optional milestone; keep VRR opt-in per client for a full cycle. |
| **R5** | **Blob-driver capability policy (`design/drivers/blob-policy.md`) has open questions that block AX211 + IPU6** | Very High (both R41 and R43 blocked) | Med | Close blob-policy design before R41 kickoff; specifically resolve: signature key store (which key signs each vendor blob), IOMMU-domain granularity, audit-channel policy. |
| **R6** | **TB4 PCIe-tunneling exposes hot-plugged devices to arbitrary IOMMU domain choices; wrong policy = security regression** | Very High (privilege escalation via malicious dock) | Low-Med | R42.M3 (security level) gates the entire R42 round; no PCIe-tunnel without user consent (SL1 minimum); per-dock IOMMU domain is default (SL2). Cite [Thunderclap 2019] as the archetypal attack we defend against. |
| **R7** | **ACPICA userspace bubble under-performs the Linux in-kernel ACPICA path; latency-sensitive HWP feedback misses deadlines** | Med (thermal control loop softens; battery life regresses) | Med | R29.M6 reserves a LP-E core for the bubble; R30 wires HWP-INT as a real interrupt to the reserved core; measure round-trip at R31 close and iterate if > 2 ms. |
| **R8** | **Wayland-fragmentation critique underestimates the effort of maintaining a single-protocol regime as ecosystem demand for extensions grows** | Med (protocol churn; app authors ask for wp- style escape hatches) | Med | PWP versioning discipline is that minor versions add capabilities, major versions never come. Publish a written no-extension-protocol policy at R40 open (`design/graphics/pwp-versioning.md`). |
| **R9** | **Firmware version drift on T14 G4 Lenovo BIOS (Insyde) breaks R29 ACPI parse against captured DSDT** | Med (bring-up wedges on a specific BIOS revision) | Med | Capture DSDT/SSDT across at least 3 Lenovo BIOS revisions before R29.M7 close; add unit fixtures per captured version; document the tested-BIOS matrix in `design/hardware/quirks.md`. |
| **R10** | **Cross-repo pacing: paideia-as v0.25–v0.31 delivery slips, blocking paideia-os round openings** | High (osarch stalls waiting on encoder) | Med-High | File the paideia-as milestones *now* (as recommended in §5); land v0.25 before R32 open; land v0.26 as a strict blocker on R34 open. Use `feedback_cross_repo_escalation`. |

---

## 7. Suggested GitHub milestone titles

Titles below use the repo's existing `r{round}-m{milestone}-{slug}` shape (per `.plans/issue-map.tsv` convention). One title per milestone. Titles are proposed literally; the synthesizer may rename.

### Axis 1 titles

```
r29-m1-acpica-parser-ir
r29-m2-acpica-interpreter-runtime
r29-m3-acpica-opregion-fields
r29-m4-acpica-gpe-notify-fixed
r29-m5-acpica-namespace-queries
r29-m6-acpica-supervisor-server
r29-m7-acpica-t14-dsdt-smoke

r30-m1-x2apic-only-path
r30-m2-tsc-deadline-monotonic-clock
r30-m3-mce-handler-mca-banks
r30-m4-ras-userspace-server
r30-m5-psci-analogue-power-op-cap

r31-m1-generic-acpi-ec-driver
r31-m2-battery-ac-adapter-class
r31-m3-thermal-zones-hwp-feedback
r31-m4-backlight-edp-aux-gmbus
r31-m5-hotkeys-lid-power-thinkpad-hkey
r31-m6-accelerometer-hinge-ambient

r32-m1-entropy-substrate
r32-m2-mlkem-768
r32-m3-mldsa-65
r32-m4-slhdsa-128f
r32-m5-tpm2-crb-tis
r32-m6-intel-mei-ptt-ftpm
r32-m7-measured-boot-deepening
r32-m8-crypto-server-typed-keypair-caps

r33-m1-lpss-i2c-bus-driver
r33-m2-i2c-hid-class-driver
r33-m3-hid-report-descriptor-compiler
r33-m4-touchpad-class-multitouch
r33-m5-trackpoint-i2c-hid-tunnel
r33-m6-gesture-library

r36-m1-hda-controller-driver
r36-m2-codec-enumeration-verb-table
r36-m3-alc287-codec-init
r36-m4-pcm-stream-engine
r36-m5-jack-detection-hotplug
r36-m6-paideia-audio-server

r41-m1-cnvi-bus-driver-ax211-probe
r41-m2-iwlwifi-mvm-umac-firmware-blob
r41-m3-802-11-mac-state-machine
r41-m4-wpa3-sae-mfp
r41-m5-802-11ax-he-mcs-rate-control
r41-m6-bluetooth-hci-over-usb-intel
r41-m7-l2cap-rfcomm-hid-over-bt
r41-m8-bt-le-gatt-le-audio-bap

r42-m1-on-die-nhi-firmware-cm
r42-m2-tbt-connection-manager-events
r42-m3-tbt-security-level-consent
r42-m4-dp-tunnel-adapter
r42-m5-pcie-tunnel-per-dock-iommu-domain
r42-m6-usb3-tunnel-usb-pd

r43-m1-csi2-receiver-ipu6-firmware
r43-m2-ipu6-pipeline-sensor-bind
r43-m3-camera-server-frame-streaming
r43-m4-fingerprint-synaptics-goodix
r43-m5-wwan-mbim-usb
r43-m6-wwan-network-integration
r43-m7-additional-acpi-sensors
r43-m8-camera-privacy-shutter
```

### Axis 2 titles

```
r34-m1-paideia-drm-mmio-power-well
r34-m2-paideia-drm-cdclk-ref-pll
r34-m3-paideia-drm-pipes-transcoders
r34-m4-paideia-drm-planes-watermark
r34-m5-paideia-drm-ddi-edp-hdmi-dp-alt
r34-m6-paideia-drm-modeset-hotplug-psr2

r35-m1-paideia-gem-gt-reset-power
r35-m2-paideia-gem-gtt-ppgtt-bo
r35-m3-paideia-gem-context-lrc
r35-m4-paideia-gem-execlists-rcs
r35-m5-paideia-gem-bcs-vcs-engines
r35-m6-paideia-gem-hang-detect-reset

r37-m1-paideia-vk-loader-instance
r37-m2-paideia-vk-spirv-reader-validator
r37-m3-paideia-vk-spirv-to-gen12-lowering
r37-m4-paideia-vk-pipeline-compiler-cache
r37-m5-paideia-vk-timeline-sema-mem-model
r37-m6-paideia-vk-swapchain-scrgb-color

r38-m1-direct-scanout-path
r38-m2-vrr-adaptivesync
r38-m3-presentation-time-feedback
r38-m4-compositor-v0-scaffold
r38-m5-damage-tracking-buffer-age
r38-m6-hdr-output-transform-pq-hlg

r39-m1-vello-path-ir-bezier-flatten
r39-m2-vello-tile-assign-sort-middle
r39-m3-vello-per-tile-scanline-blend
r39-m4-sdf-font-pipeline
r39-m5-subpixel-positioning-no-hinting
r39-m6-text-input-protocol-ime
r39-m7-unicode-text-layout-bidi-shaping

r40-m1-pwp-wire-format-handshake
r40-m2-pwp-surface-role-commit
r40-m3-window-management-focus-workspace
r40-m4-accessibility-subtree-protocol
r40-m5-keyboard-event-contract-ime-routing
r40-m6-pointer-touch-stylus-contract
r40-m7-gesture-routing-global-channel
```

---

## 8. References

### 8.1 Confirmed references

- **NIST FIPS 203** (2024) — Module-Lattice-based Key-Encapsulation Mechanism Standard (ML-KEM).
- **NIST FIPS 204** (2024) — Module-Lattice-based Digital Signature Standard (ML-DSA).
- **NIST FIPS 205** (2024) — Stateless Hash-Based Digital Signature Standard (SLH-DSA).
- **NIST SP 800-90A Rev. 1** — Recommendation for Random Number Generation Using Deterministic Random Bit Generators.
- **UEFI Specification** 2.10 — `EFI_TCG2_PROTOCOL`, `EFI_CONFIGURATION_TABLE`, `EFI_GRAPHICS_OUTPUT_PROTOCOL`. UEFI Forum.
- **ACPI Specification** 6.5 — DSDT / SSDT / MADT / MCFG / FADT / HPET / EC OpRegion / GPE / `_Qxx` methods. UEFI Forum.
- **Intel 64 and IA-32 Architectures Software Developer's Manual** — Volume 3B/3C: x2APIC, TSC-Deadline, HWP MSRs, MCA banks. Intel Corporation.
- **Intel Programmer's Reference Manual (Gen12)** — Volume 12 (Display Engine): pipes, planes, transcoders, DDIs, CDCLK. Volume 5 (Memory Views): GTT, PPGTT. Volume 7 (Command Reference): execlists, LRC. Publicly at 01.org / kernel.org.
- **DisplayPort Standard** 1.4a — VESA. Link training, AUX channel, DPCD register map, panel PSR2, AdaptiveSync (via DP 1.2a addendum).
- **HDMI 2.1 Specification** — HDMI Forum. FRL, DSC.
- **HID over I²C Protocol Specification** 1.0 — Microsoft. `_DSM` UUID `4F1F0DE6-89E4-45C7-A76A-6F5A6E3B3C4A` (verify UUID text against Microsoft spec doc).
- **USB Implementers Forum Class Specifications** — HID 1.11, USB 3.2 xHCI 1.2, USB4 (2.0), USB-PD 3.1.
- **Intel Thunderbolt Security Specification** — TBT security levels SL0..SL3. Intel Corporation.
- **VESA Embedded DisplayPort Standard** 1.5 — TCON DPCD 0x701..0x724 backlight control; PSR2.
- **TCG PC Client Platform Firmware Profile Specification** 1.05 — event log, PCR extends.
- **TCG PC Client TPM 2.0 Interface Specifications** — TIS, CRB.
- **Vulkan 1.3 Specification** — Khronos Group. `VK_KHR_timeline_semaphore` (originally KHR extension, promoted to core in 1.2).
- **SPIR-V Specification** 1.6 — Khronos Group.
- **ITU-R Recommendation BT.2100** — Reference PQ/HLG transfer functions for HDR (BT.2100-2, 2018).
- **RFC 7664** — Dragonfly Key Exchange (foundation of WPA3 SAE handshake).
- **draft-ietf-tls-hybrid-design** — Hybrid classical+PQ key exchange for TLS (IETF draft; do not cite a specific revision number).
- **Lengyel, Eric.** "GPU-Centered Font Rendering Directly from Glyph Outlines." *Journal of Computer Graphics Techniques (JCGT)* 6(2), 2017. — Slug SDF text lineage.
- **Levien, Raph.** "A sort-middle architecture for 2D graphics." raphlinus.github.io, 2020-05-19. Follow-up posts on the piet-gpu / Vello architecture over 2020–2023. — compute-2D lineage.
- **Thunderclap** (Markettos, Rothwell, Gutstein, Pearce, Neumann, Moore, Watson) — "Thunderclap: Exploring Vulnerabilities in Operating System IOMMU Protection via DMA from Untrustworthy Peripherals." NDSS 2019. — TBT+IOMMU attack surface.
- **Ekstrand, Jason** — series of LWN articles (2020–2021) documenting `drm_syncobj` timelines and their Vulkan timeline-semaphore alignment.
- **Chromium Viz architecture** — Chromium project design documents under `docs/ui/ozone/` and `docs/gpu/`. — direct-scanout, presentation-time, over-scheduling avoidance.
- **Wayland Protocols** — `wp_presentation`, `wp_linux_dmabuf_v1`, `zwp_linux_explicit_synchronization_v1`. wayland-protocols repo.
- **Fuchsia Scenic architecture** — `fuchsia.dev/reference/fidl/fuchsia.ui.composition` — hierarchical scene-graph compositor.
- **Windows DirectComposition and DirectManipulation** — Microsoft docs (`learn.microsoft.com/windows/win32/directcomp/`). — compositor plane model.
- **Apple, WWDC 2019** — "Modern Rendering with Metal"; **WWDC 2020, 2021** — EDR / HDR pipeline talks. developer.apple.com/videos.
- **Linux `i915` driver, `iwlwifi` driver, `ipu6` staging driver, `sof-firmware`, `thunderbolt` driver** — Linux kernel source tree. Cited as design reference, not for copy-paste; verify current-tree state at round open.

### 8.2 TODO: verify

The following claims in this document should be independently verified before locking scope:

- **IPU6 PCI device ID on RPL-U/P** (§2.9 R43.M1) — flagged by hwman as uncertain; check current-tree `drivers/media/pci/intel/ipu6/`.
- **Exact DDI count and any HDMI 2.1 LSPCON on T14 G4** (§3.2 R34.M5) — flagged by hwman.
- **Current i915 PSR2 default state on Raptor Lake** (§3.2 R34) — flagged by hwman; check kernel git log.
- **Per-plane LUT sizes on Gen12** (§3.5 R38) — flagged by hwman; check Intel Gen12 PRM Volume 12.
- **HID over I²C protocol `_DSM` UUID exact text** (§8.1) — verify against Microsoft HID-over-I2C spec PDF.
- **HDR LWN article series exact URLs** (§3.0 pitfall table + §3.5 R38.M6) — cited as "Chris Wilson's Linux HDR series on LWN (2023–2024)"; the series exists but I have not verified the author name; do not rely on the byline. Verify at lwn.net search.
- **AdaptiveSync exact spec addendum revision** (§3.5 R38.M2) — cited as "DP 1.2a addendum" for AdaptiveSync; verify against VESA current publication.
- **Current wave of Wayland ext- / wp- fragmentation critique** (§3.0 preamble) — cited as "multiple LWN articles 2022–2024"; no specific article named; verify or drop the citation.
- **Sensor SKU on T14 G4** (§2.9 R43.M2) — the specific CSI-2 sensor part (OV02C10 / IMX208 typical) varies by chassis SKU; check `/proc/asound` and `libcamera` scan output on the physical unit.

---

## 9. Open architectural questions (for the synthesis wave to resolve)

1. **Should the ACPICA bubble promotion (R34 → R29) require re-baselining the whole `design/roadmap/r18-plus-bare-metal.md` §3 table, or does the two-doc pattern (bare-metal + next-wave) stand?** Proposed answer: two-doc pattern stands; §3 of the bare-metal roadmap becomes archived-once-R28-closes.
2. **Blob-driver capability policy finalisation** — see risk R5. Blocking for R41 and R43.
3. **VMD long-term stance** — still open per `r18-plus-bare-metal.md` §8 Q1. Not blocking R29–R43 as long as BIOS-off remains the policy, but paints the R41+ "docked NVMe over TBT4" story a specific colour.
4. **PdxFS v1 slot** — the bare-metal roadmap places PdxFS v1 at R40. This proposal *does not touch that slot*, but recommends the synthesizer consider R44+ (after Axis 2 stabilises) so the FS bring-up doesn't compete with compositor bring-up for reviewer attention.
5. **Semantic terminal (R39 in bare-metal roadmap)** — this proposal re-uses the R39 slot for `paideia-vello`. Synthesizer must decide: rename semantic-terminal to R44 (or later), or push Axis-2 rounds up by one. Recommend the former (the semantic terminal is the *payoff* of a GPU-native GUI, so it naturally slots after R40).
6. **Software Connection Manager for TBT4** (§2.8) — MVP is firmware-CM. Software-CM (which unlocks display-tunnel-priority arbitration and multi-host TB4 topologies) is a research-year of work. Defer to R44+.

---

**End of osarch next-wave proposal.**
