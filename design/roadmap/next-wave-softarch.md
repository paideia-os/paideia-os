# PaideiaOS Next-Wave Roadmap — Software-Architecture Voice (softarch)

**Status:** Independent planning proposal for post-MVP wave (R29-onward).
**Date:** 2026-08-11.
**Vantage:** Post-`mvp-v0.1` (commit `836ec0d`); R18–R28 landed. Blocker #1015 (userspace-server substrate) open.
**Companion:** `osarch` next-wave proposal (parallel; synthesis follows).
**Reconciles with:** `design/roadmap/r18-plus-bare-metal.md` (canonical MVP path); this document extends and reshapes R29–R48+ with a software-architecture lens.

The osarch voice will weigh hardware bring-up ordering, physical topology and boot-time criticality. This document weighs **interface shapes, capability grammar, protocol commitments, module boundaries, testability, and how each new subsystem lands as a first-class citizen of the paideia-as effect+capability system** — the things we cannot change later without breaking every downstream client.

---

## 1. Executive summary (300 words)

The MVP demonstrated the pillar-3 microkernel *works*: kernel mints capabilities, IPC ring services requests, drivers live in userspace, framebuffer paints. The next wave is where architectural mistakes get expensive: once we ship a compositor protocol, a Bluetooth stack, a GPU command submission grammar, or an audio timing contract, we live with them for the project's life. Retractions cost the same as inventions.

**My dominant commitments:**

1. **Every subsystem lands as a `KIND_*` derived capability + one session-typed IPC schema** — no exceptions. If it has no schema, it is not shipped. This is how we avoid the X11/Linux "core protocol + 200 extensions" pathology.
2. **Effect rows are the API contract, not documentation.** A driver's public interface is its schema's effect row. Cross-cutting concerns (audit, tracing, timing, back-pressure) are effects the type system tracks, not conventions.
3. **Every buffer that crosses two hardware clocks (GPU/CPU/USB SOF/audio-mclk/net-PTP) carries an explicit timeline capability.** No implicit sync. This is the drm-syncobj lesson generalized.
4. **The compositor is not privileged.** Input, presentation, and recovery-console are three separately-restartable services with independent capabilities. A compositor lockup can never eat the input path.
5. **First-class accessibility, HDR, wide-gamut, and fractional scaling from the FIRST protocol revision** — bolt-ons never land clean.
6. **`unsafe` blocks are quarantined at the driver-substrate layer**; class drivers, compositors, and toolkits are pure paideia-as with tracked effect rows.

**Most dangerous pitfalls I flag:**

- Baking synchronous MMIO reads into a driver's public trait (impossible to move over IPC later).
- Letting the compositor own input state (X11's original sin — copied by Wayland's `wl_seat`).
- Modeling color as an sRGB scalar triple (locks out HDR forever).
- One kind per device class (blows the closed 16-base-kind enum); everything driver-facing is derived over `KIND_DEVICE` or `KIND_IPC_ENDPOINT`.
- Treating audio as "another block device" (audio's constraint is *time*, not *bytes*).

Two axes follow: **Axis 1** — 12 rounds of T14 G4 driver coverage (R29–R40); **Axis 2** — 12 rounds of GPU-native GUI (G1–G12, interleaved and post-R40).

---

## 2. Guiding architectural principles (repeated for the record)

These are the principles every round below is checked against.

- **P1 — Schema is API.** Every service exposes a `Channel(Schema)` where `Schema` is a functor signature (per `linearity-and-tags.md` CAP-Q3 + `wait-free-dataflow.md` IPC-Q5). No ad-hoc IPC.
- **P2 — Effects up-front.** Every schema declares its effect row (`!{gpu_submit, gpu_wait, hdr_present, …}`). Callers must hold caps whose rights map to those effects. This is Q7's "both static and runtime enforcement".
- **P3 — Timelines are capabilities.** Producer/consumer clocks are `KIND_TIMELINE` handles; a wait or a signal takes a value on a timeline. Never a raw fence.
- **P4 — One process per failure domain, one supervisor per hardware tier.** No "userspace kernel" mega-process ever. If subsystem X crashes, exactly the set-of-clients-of-X see `ChannelDead`.
- **P5 — Static uniqueness beats dynamic mutex.** Session types + linear caps replace locks wherever feasible.
- **P6 — Rendered output is a compute-buffer, not a set of drawing primitives.** All 2D goes through the GPU compute pipeline; the compositor sees only textures.
- **P7 — Presentation-time feedback is mandatory.** Every surface commit gets a scanout timestamp back. Applications adapt to actual timing, not desired timing.
- **P8 — Recovery is a first-class citizen.** Recovery console (`safectl`), fallback compositor (`safeface`), and single-user IPC bus (`safebus`) are separately-buildable, always-linkable.
- **P9 — The build is a matrix, not a switch.** Optional hardware (WWAN, fingerprint, external GPU) is a *feature-flag row* on the manifest, not conditional code.
- **P10 — Nothing new gets a base kind.** The 16 base kinds are frozen. Everything is derived over `KIND_IPC_ENDPOINT` (services), `KIND_DEVICE` (hardware), `KIND_MEMORY` (buffers), `KIND_INTERRUPT` (irqs), or the reserved slots 14/15 for confidential-compute / distributed.

---

## 3. Axis 1 — T14 G4 driver coverage (R29–R40)

This section covers **twelve rounds**, ~230 issues, ~80 milestones, targeting exhaustive T14 Gen 4 hardware. Each round enumerates: rationale, capability shapes, IPC schemas, userspace-vs-kernel split, test strategy, milestones, issue count. Issue titles are terse but sufficient to file directly.

### R29 — Driver framework maturation + interrupt topology (30 issues)

**Purpose.** Post-MVP hardening surfaced how much of the driver framework is aspirational versus operational. This round hardens: the lifecycle FSM (`Init→Running→Suspended→Handoff→Stopping→Stopped`) in real code, IRQ dispatch as `KIND_INTERRUPT` capability separate from `KIND_MSIX_VECTOR`, the driver registry as a versioned artifact, and the audit path for every driver op. This is a prerequisite for every round that follows.

**New capabilities.**
- `KIND_INTERRUPT` — *derived over reserved slot 14*, tail `{gsi:u32, cpu_affinity_mask:u64, edge_or_level:u8}`. Splits the current `KIND_DRIVER` monolith so a driver can mint per-vector IRQ endpoints without holding the whole device.
- `KIND_MSIX_VECTOR` — *derived over `KIND_INTERRUPT`*, tail adds `{msix_table_offset:u32, msix_data:u32}`. Explicit so the same driver can hold N of these on M-vector devices.
- `KIND_DMA_DOMAIN` — *derived over `KIND_MEMORY`*, tail `{iommu_ctx_id:u32, bus_dev_fn:u16, capacity_bytes:u64, coherency:u8}`. Every DMA-capable driver holds one per device.
- `KIND_HW_TIMELINE` — *derived over reserved slot 14*, tail `{monotonic_ns_offset:i64, resolution_ns:u32, source:{tsc|hpet|apic|dev_clock}}`. First appearance of the timeline abstraction.

**IPC schemas.**
- `driver_lifecycle_channel : Channel(DriverLifecycleSchema)` — request/reply pattern `{start, init_done, suspend, resume, handoff_begin, stop}`.
- `driver_hotplug_channel : Channel(HotplugSchema)` — stream `{device_arrived, device_departed}` with `Cap<KIND_DEVICE>` payload.
- `driver_audit_channel : Channel(DriverAuditSchema)` — one-way stream, sealed.

**User/kernel split.** Kernel owns only: IDT install, LAPIC EOI, IPI delivery, `KIND_INTERRUPT` mint, IOMMU domain switching. Everything else is the supervisor userspace + per-driver processes.

**Test strategy.**
- **Structural witness:** every driver process' effect row is checked at link time; a driver claiming `!{mmio_read}` without holding an `MmioMemCap` fails elaboration.
- **Fuzz:** the lifecycle FSM is fuzzed with random valid+invalid transitions; missed states = bug.
- **Chaos-restart:** kill each driver 100× under IO load; the supervisor's restart cascade is checked for capability leaks (audit shows monotonic descriptor count).

**Milestones (7).**
- R29.M1 — `KIND_INTERRUPT` / `KIND_MSIX_VECTOR` capability introduction (4 issues).
- R29.M2 — Lifecycle FSM real bodies + regression corpus (5).
- R29.M3 — Driver registry v2 (versioned, signed, cap'n proto persisted) (4).
- R29.M4 — Driver signing verifier + PQ ML-DSA-65 signature check (4).
- R29.M5 — `KIND_DMA_DOMAIN` introduction + IOMMU-domain-per-device supervisor (4).
- R29.M6 — Audit surface: every mint/revoke/handoff emits (4).
- R29.M7 — Cascade-restart policy + chaos harness (5).

---

### R30 — ACPICA userspace bubble + LPSS bus enablement (40 issues)

**Purpose.** The single hardest post-MVP round. Without an AML interpreter we can't reach EC, thermal zones, I²C-HID, backlight, GPIO, or lid/power events on the T14 G4. AML runs *in userspace*, in a dedicated `acpi_supervisor` process, per pillar 3. This round also brings up LPSS UART/I²C/GPIO enumeration (the T14 G4 exposes touchpad + fingerprint + sensor hub via LPSS I²C).

**New capabilities.**
- `KIND_AML_SESSION` — *derived over `KIND_IPC_ENDPOINT`*, tail `{scope_path:[u8;64], op_region_domain:u8}`. A capability the ACPI bubble uses to arbitrate concurrent AML evaluations on the same object.
- `KIND_OP_REGION` — *derived over `KIND_MEMORY` OR `KIND_PORT`*, tail `{addr_space:{sys_mem|sys_io|pci_cfg|ec|smbus|cmos|pci_bar|ipmi}, base:u64, len:u64}`. The AML `OpRegion` abstraction becomes a cap; no other component of the system can *silently* poke a hardware address.
- `KIND_I2C_BUS` — *derived over `KIND_DEVICE`*, tail `{controller_id:u16, max_speed_hz:u32, num_slaves:u8}`. LPSS I²C controllers hand these out.
- `KIND_I2C_SLAVE` — *derived over `KIND_I2C_BUS`*, tail `{addr_7bit:u8, addr_10bit:bool, driver_hint:[u8;32]}`. Every slave is a first-class cap.
- `KIND_GPIO_LINE` — *derived over `KIND_DEVICE`*, tail `{controller_id:u16, pin:u16, direction:{in|out|alt}, pull:{up|down|none}}`.

**IPC schemas.**
- `aml_eval_channel : Channel(AmlEvalSchema)` — RPC `eval(path:Text, args:[AmlObject]) -> AmlObject`; effect row `!{aml_evaluate, aml_notify, op_region_access}`.
- `acpi_event_channel : Channel(AcpiEventSchema)` — stream `{gpe_fired, sci_fired, notify_object}`; effect row `!{acpi_notify_recv}`.
- `i2c_transfer_channel : Channel(I2cTransferSchema)` — RPC `{write, read, write_read, smbus_op}` with `Cap<KIND_I2C_SLAVE>` bound at open.

**User/kernel split.** Kernel: nothing new (ACPI table walk was R20). Userspace: `acpi_supervisor` process, `lpss_i2c_bus_driver` process per LPSS controller, `lpss_gpio_bus_driver` process per GPIO controller.

**Test strategy.**
- Static AML corpus (captured from real T14 G4) evaluated against the interpreter under Miri-equivalent property tester.
- **HW-gated smoke:** `PAIDEIA_HW_SMOKE=1 boot_r30_acpica` verifies EC battery-percentage read matches BIOS-shown value ±1%.
- Structural witness: `acpi_supervisor` compile fails if any `unsafe` block outside the AML interpreter itself uses an `OpRegion`.

**Milestones (9).**
- R30.M1 — AML tokenizer + parser (5).
- R30.M2 — AML evaluator (namespace, method calls, control flow) (7).
- R30.M3 — OpRegion cap plumbing + address-space handlers (5).
- R30.M4 — GPE/SCI dispatch as `KIND_INTERRUPT` (4).
- R30.M5 — LPSS I²C controller driver + `KIND_I2C_BUS`/`KIND_I2C_SLAVE` (5).
- R30.M6 — LPSS GPIO controller driver + `KIND_GPIO_LINE` (4).
- R30.M7 — EC access via ACPI `EmbCtl` OpRegion (3).
- R30.M8 — Global lock protocol (multi-writer AML arbitration) (3).
- R30.M9 — AML fuzz + acpica-bubble crash isolation (4).

---

### R31 — Embedded Controller, platform sensors, thermal, power/battery, backlight (26 issues)

**Purpose.** Everything the T14 G4 EC exposes: battery state, AC presence, lid state, hot-key events, fan RPM, thermal zones, keyboard backlight brightness. Also panel backlight over Intel BXT-PWM or DP AUX. These are all cheap once R30 lands and expensive without it.

**New capabilities.**
- `KIND_EC_QUERY` — *derived over `KIND_IPC_ENDPOINT`*, tail `{ec_addr:u8, notify_bitmap:u32}`. The EC "query" (interrupt-carried event byte) becomes a cap-carried event stream.
- `KIND_THERMAL_ZONE` — *derived over `KIND_DEVICE`*, tail `{zone_path:[u8;32], num_trips:u8, active_cooling_devs:[u16;8]}`. One per ACPI `ThermalZone`.
- `KIND_COOLING_DEVICE` — *derived over `KIND_DEVICE`*, tail `{dev_type:{fan|passive_cpu|passive_gpu|throttle}, min_state:u8, max_state:u8}`.
- `KIND_BATTERY` — *derived over `KIND_DEVICE`*, tail `{index:u8, design_cap_mwh:u32, chemistry:u8}`.
- `KIND_BACKLIGHT` — *derived over `KIND_DEVICE`*, tail `{source:{pwm|dp_aux|acpi_bcm}, min:u16, max:u16}`.

**IPC schemas.**
- `power_policy_channel : Channel(PowerPolicySchema)` — bidirectional; `power_policy` server publishes profile (balanced/perf/save), consumers (drivers) subscribe.
- `thermal_channel : Channel(ThermalSchema)` — stream `{trip_crossed, zone_temp_read}`; effect row `!{thermal_read, thermal_trip}`.
- `battery_channel : Channel(BatterySchema)` — stream `{state_changed, low_warning}` + RPC `read_state`.
- `backlight_channel : Channel(BacklightSchema)` — RPC `{get, set, get_range}`; **critical**: the backlight cap is granted to the compositor, **not** to arbitrary clients. Compositor is the only surface that decides what "50%" means to the user.

**User/kernel split.** Fully userspace: `ec_driver`, `thermal_policy`, `battery_monitor`, `backlight_driver` are separate processes. Kernel touches nothing platform-specific.

**Test strategy.**
- **HW-gated smoke:** `boot_r31_platform` requires physical T14 G4; unplugs AC and asserts battery-percentage drops; hits Fn+F5/F6 and asserts backlight cap value changes; runs a stress loop and asserts fan RPM rises via `KIND_COOLING_DEVICE`.
- Unit: mock EC over `EmbCtl` OpRegion; deterministic replay.

**Milestones (6).**
- R31.M1 — EC driver + `KIND_EC_QUERY` events (5).
- R31.M2 — `KIND_THERMAL_ZONE` + `thermal_policy` server (5).
- R31.M3 — `KIND_BATTERY` + `battery_monitor` server (4).
- R31.M4 — `KIND_COOLING_DEVICE` + fan control (3).
- R31.M5 — `KIND_BACKLIGHT` (PWM + DP-AUX paths) (5).
- R31.M6 — Hot-key event routing (Fn+F4 mute, Fn+F5/F6 brightness, Fn+F1/F2/F3 vol) via `KIND_HID_EVENT` (from R32) (4).

---

### R32 — I²C-HID (touchpad + trackpoint), sensor hub, HID class driver expansion (22 issues)

**Purpose.** The T14 G4 touchpad + trackpoint speak I²C-HID (not USB-HID); the fingerprint sensor is USB (R34); the sensor hub (ALS + accelerometer) is on LPSS I²C. This round finishes the HID class driver so it accepts multiple transports (USB from R26, I²C from here) and produces one unified `KIND_HID_EVENT` stream.

**New capabilities.**
- `KIND_HID_DEVICE` — *derived over `KIND_DEVICE`*, tail `{transport:{usb|i2c|bt}, report_desc_hash:[u8;32], collection_kind:{kbd|mouse|touchpad|touchscreen|pen|joystick|sensor|multi}}`.
- `KIND_HID_EVENT` — *derived over `KIND_IPC_ENDPOINT`*, tail `{seat_id:u8, device_class:u8}`. Every input event carries seat + device class so the compositor can route by device without magic constants.
- `KIND_SENSOR_CHANNEL` — *derived over `KIND_IPC_ENDPOINT`*, tail `{sensor_kind:{als|accel|gyro|mag|prox|temp|hall}, sample_hz:u32, unit_scale:u32}`.

**IPC schemas.**
- `hid_event_stream : Channel(HidEventSchema)` — stream, session-typed `{kbd_press, kbd_release, mouse_move, mouse_scroll, touch_begin, touch_move, touch_end, gesture_swipe, gesture_pinch}`. **Note:** gestures are HID-side, not compositor-side — the compositor sees semantic events, never raw coordinates for non-active surfaces.
- `sensor_read_channel : Channel(SensorReadSchema)` — stream of typed samples, subscribable at min rates.

**User/kernel split.** All userspace: `i2c_hid_bus_driver` (bus-tier), `hid_class_driver` (class-tier), `sensor_hub_driver` (device-tier).

**Test strategy.**
- Structural: HID report-descriptor parser produces a typed `ReportSchema`; malformed descriptor = compile-time-checked graceful failure.
- **HW-gated smoke:** touchpad two-finger scroll on real T14 produces `gesture_scroll(dy=…)` on the HID event stream; touch coordinates verified via a paint fixture.
- Unit: replay recorded HID report streams from Linux `evemu` captures.

**Milestones (5).**
- R32.M1 — I²C-HID transport (Windows/HID-over-I²C spec) (5).
- R32.M2 — HID report-descriptor parser + `ReportSchema` (5).
- R32.M3 — `KIND_HID_EVENT` unified event stream (multi-transport merge) (4).
- R32.M4 — Gesture recognizer (kinetic scroll, two-finger scroll, pinch) (4).
- R32.M5 — `KIND_SENSOR_CHANNEL` + sensor hub driver (ALS + accel) (4).

---

### R33 — Intel HDA + Realtek ALC287 codec + Sound Open Firmware (SOF) audio path (30 issues)

**Purpose.** Audio's constraint is *time*: 48 kHz × stereo × 32-bit = 384 KB/s must land inside a 10 ms window forever. This round establishes: HDA controller driver, codec discovery, PCM stream capability, audio timeline (`KIND_AUDIO_CLOCK`), and — critically — the *no-audio-in-compositor* discipline: audio has its own supervisor, its own routing table, its own presentation-time feedback loop, independent of graphics.

**New capabilities.**
- `KIND_AUDIO_CONTROLLER` — *derived over `KIND_DEVICE`*, tail `{codec_bitmap:u16, num_streams_in:u8, num_streams_out:u8, dsp_present:bool}`.
- `KIND_PCM_STREAM` — *derived over `KIND_IPC_ENDPOINT`*, tail `{direction:{playback|capture}, sample_hz:u32, channels:u8, format:{s16|s24|s32|f32}, period_frames:u32, buffer_frames:u32}`. Substructurally *linear* — never split, never duplicated.
- `KIND_AUDIO_CLOCK` — *derived over `KIND_HW_TIMELINE`*, tail `{mclk_hz:u32, sync_source:{hda|sof|pll|sync_group_id}}`. Any node in the audio graph carries a clock cap; the graph is a DAG whose edges are annotated by shared clocks.
- `KIND_AUDIO_ROUTE` — *derived over `KIND_IPC_ENDPOINT`*, tail `{source_cap_slot:u8, sink_cap_slot:u8, sample_rate_convert:bool, mixer_gain_q15:i16}`. The audio supervisor holds these as its state.

**IPC schemas.**
- `pcm_ring_channel : Channel(PcmRingSchema)` — session-typed `{fill_next_period, drain_current_period, xrun_notify}`; **carries** `KIND_AUDIO_CLOCK` cap so consumers can compute presentation time.
- `audio_routing_channel : Channel(AudioRoutingSchema)` — RPC `{open_stream, connect_route, set_gain, close_stream}` — held by the `audio_supervisor`.
- `codec_query_channel : Channel(CodecQuerySchema)` — RPC `{get_widgets, get_pins, set_pin_ctl, get_amp_gain}`.

**User/kernel split.** Kernel: nothing new. Userspace: `hda_controller_driver`, `alc287_codec_driver`, `audio_supervisor`, `sof_dsp_loader` (loads SOF firmware, optional path).

**Test strategy.**
- **Structural:** PCM stream schema forbids buffer reuse across two `KIND_AUDIO_CLOCK` values.
- **HW-gated smoke:** `boot_r33_audio` plays a 440 Hz sine for 5 s; captures at line-in; asserts FFT peak at 440 ± 5 Hz.
- **Latency measurement:** loopback playback → capture must be < 20 ms round-trip; regression-gates each PR.

**Milestones (6).**
- R33.M1 — HDA PCI probe + controller reset + CORB/RIRB (5).
- R33.M2 — Codec discovery + widget graph traversal (5).
- R33.M3 — `KIND_PCM_STREAM` + BDL DMA + `KIND_AUDIO_CLOCK` mint (5).
- R33.M4 — ALC287 codec driver + jack detection + headphone/speaker routing (5).
- R33.M5 — `audio_supervisor` + `KIND_AUDIO_ROUTE` (5).
- R33.M6 — SOF DSP firmware loader (optional; guards Realtek DSP effects) (5).

---

### R34 — USB fabric completion: hubs, mass-storage, USB-HID hardening, fingerprint (28 issues)

**Purpose.** MVP R26 gave us xHCI + boot-protocol keyboard. Real T14 G4 use needs hub cascading, mass-storage (USB flash drives for install/rescue), USB-HID beyond boot protocol, and the fingerprint reader (Goodix/Synaptics USB). This round hardens the USB stack for arbitrary topology.

**New capabilities.**
- `KIND_USB_HUB` — *derived over `KIND_USB_DEVICE`*, tail `{num_ports:u8, tt_present:bool, super_speed:bool}`.
- `KIND_USB_INTERFACE` — *derived over `KIND_USB_DEVICE`*, tail `{if_num:u8, class:u8, subclass:u8, proto:u8, alt_setting:u8}`. **Critical:** interfaces, not devices, are the driver-binding unit; a composite device (fingerprint + camera) hands its two interfaces to two different drivers.
- `KIND_USB_ENDPOINT` — *derived over `KIND_IPC_ENDPOINT`*, tail `{addr:u8, direction:{in|out}, xfer_type:{ctrl|bulk|intr|isoch}, max_packet:u16, interval:u8}`.
- `KIND_ISOCH_STREAM` — *derived over `KIND_USB_ENDPOINT`*, tail `{sof_timeline:CapRef<KIND_HW_TIMELINE>, service_interval_us:u32}`. Isoch endpoints ALWAYS carry a timeline (webcam, USB audio class, …).
- `KIND_FP_SENSOR` — *derived over `KIND_DEVICE`*, tail `{template_max:u16, enroll_kind:{swipe|touch}, driver_hint:[u8;32]}`.

**IPC schemas.**
- `usb_transfer_channel : Channel(UsbTransferSchema)` — RPC per-endpoint `{submit_urb, cancel_urb, poll_status}`; carries the buffer as `Cap<KIND_MEMORY>` with IOMMU-mapped bit set.
- `hub_topology_channel : Channel(HubTopologySchema)` — stream `{device_attached, device_detached, port_status_change}`.
- `fp_capture_channel : Channel(FpCaptureSchema)` — RPC `{begin_capture, cancel_capture, template_extracted}`; effect row `!{biometric_capture}` — no other schema declares this effect, so the fingerprint reader is trivially audit-locatable.

**User/kernel split.** All userspace: `usb_hub_class_driver`, `usb_msc_class_driver` (mass-storage), `usb_hid_class_driver` (already exists from R26/R32; extended), `fingerprint_class_driver`, per-vendor `fp_goodix_driver` / `fp_synaptics_driver`.

**Test strategy.**
- **QEMU:** deep hub topology fuzzed with `-device usb-hub` chains; assert enumeration converges.
- **HW-gated:** hot-plug external mass-storage 20× on physical T14; assert monotone cap descriptor count (no leaks); assert fingerprint enroll+verify roundtrip works.

**Milestones (6).**
- R34.M1 — USB hub class driver (standard hub descriptor + port status FSM) (5).
- R34.M2 — `KIND_USB_INTERFACE` split from `KIND_USB_DEVICE` + composite-device binding (4).
- R34.M3 — USB mass-storage (Bulk-Only Transport / UAS) (5).
- R34.M4 — USB-HID full-protocol (report-desc parser reuse from R32) (5).
- R34.M5 — Isochronous stream substrate + `KIND_ISOCH_STREAM` + SOF timeline (5).
- R34.M6 — Fingerprint class driver + Goodix + Synaptics device drivers (4).

---

### R35 — Thunderbolt 4 / USB4 + PCIe hot-plug + external-GPU groundwork (24 issues)

**Purpose.** Thunderbolt is where every OS's driver model breaks: PCIe tunneling means new devices arrive *deep in the topology*, mid-runtime, potentially with DMA-attack risk. Correct handling drops out of pillar 6 + capability revocation cascade if we do it right; drives assumptions across the rest of the OS if we do it wrong.

**New capabilities.**
- `KIND_TB_DOMAIN` — *derived over `KIND_DEVICE`*, tail `{router_uuid:[u8;16], num_ports:u8, security_level:{none|user|secure|dp_only|usb_only}}`.
- `KIND_TB_ROUTE` — *derived over `KIND_IPC_ENDPOINT`*, tail `{route_string:u64, hop_count:u8, path_type:{pcie|dp|usb3}}`. Every tunnel is a first-class cap that can be revoked.
- `KIND_PCIE_HOTPLUG_EVENT` — *derived over `KIND_IPC_ENDPOINT`*, tail `{root_port_bdf:u16, event:{link_up|link_down|dpc_triggered|surprise_removal}}`.
- `KIND_DMA_ATTESTATION` — *derived over `KIND_IPC_ENDPOINT`*, tail `{device_bdf:u16, user_consent_token:[u8;32], iommu_domain_ref:CapRef<KIND_DMA_DOMAIN>}`. **Central design decision:** *no external DMA-capable device ever runs without a user-consent token* — the token is minted by the desktop policy manager, held by the driver, checked at IOMMU domain enable.

**IPC schemas.**
- `tb_topology_channel : Channel(TbTopologySchema)` — stream `{router_appeared, router_departed, tunnel_established, tunnel_torn}`.
- `dma_consent_channel : Channel(DmaConsentSchema)` — RPC `{request_consent, revoke_consent}` from driver-supervisor to `desktop_policy_manager`. A user-facing dialog is served by the compositor; this is the schema behind it.
- `pcie_hotplug_channel : Channel(PciHotplugSchema)` — stream, extends R22 PCI enumerator with hot-plug events.

**User/kernel split.** Kernel: PCIe hot-plug ISR (root-port service interrupt) + IOMMU domain reconfiguration. Userspace: `tb_supervisor` (topology + tunneling), `pcie_hotplug_dispatcher`, per-device drivers arrive as usual.

**Test strategy.**
- **QEMU:** limited; TB isn't well-emulated. Use Linux dmesg captures for topology-schema validation.
- **HW-gated:** physical T14 G4 + TB4 dock + external NVMe. Attach → assert `KIND_DMA_ATTESTATION` consent flow shows on screen → grant → NVMe visible; detach → assert cap-revocation cascade zeroes the driver's descriptor list.
- **Adversarial:** attach unknown device; deny consent; assert no MMIO/DMA ever occurs.

**Milestones (5).**
- R35.M1 — PCIe hot-plug ISR + `KIND_PCIE_HOTPLUG_EVENT` (5).
- R35.M2 — TB4 router discovery + `KIND_TB_DOMAIN` (5).
- R35.M3 — TB4 tunnel establishment (PCIe/DP/USB3) + `KIND_TB_ROUTE` (5).
- R35.M4 — `KIND_DMA_ATTESTATION` + consent flow + IOMMU reconfiguration (5).
- R35.M5 — Cap-revocation cascade validation + adversarial harness (4).

---

### R36 — Iris Xe foundation: display topology, KMS-equivalent, modesetting (18 issues)

**Purpose.** First half of GPU bring-up: everything needed to render the framebuffer console via the *real* display engine (not just the UEFI GOP hand-me-down) — display topology discovery, mode enumeration, atomic mode-setting, DP/HDMI hot-plug. This is the substrate the compositor (Axis 2) needs.

**New capabilities.**
- `KIND_DISPLAY_ENGINE` — *derived over `KIND_DEVICE`*, tail `{pci_bdf:u16, generation:u8, num_pipes:u8, num_planes_per_pipe:u8}`.
- `KIND_DISPLAY_OUTPUT` — *derived over `KIND_DEVICE`*, tail `{connector_kind:{edp|hdmi|dp|dp_alt}, hpd_pin:u8, aux_ch:u8, max_bpc:u8, hdr_static_metadata_supported:bool}`.
- `KIND_DISPLAY_MODE` — *derived over `KIND_MEMORY`*, tail `{width:u32, height:u32, refresh_millihz:u32, pixel_format:u16, color_space:{srgb|rec709|dcip3|rec2020}, hdr_eotf:{sdr|hdr10|hlg|dolby_vision}}`.
- `KIND_DISPLAY_PLANE` — *derived over `KIND_MEMORY`*, tail `{plane_kind:{primary|overlay|cursor}, zorder:u8, formats_bitmap:u32}`.
- `KIND_MODESET_TXN` — *linear over `KIND_IPC_ENDPOINT`*, tail `{txn_id:u64, atomic_props_count:u16}`. All mode-setting is atomic: mint a `KIND_MODESET_TXN`, populate props, commit-or-abort; never partial.

**IPC schemas.**
- `display_topology_channel : Channel(DisplayTopologySchema)` — stream `{output_connected, output_disconnected, mode_list_changed}`; carries `KIND_DISPLAY_OUTPUT`.
- `modeset_channel : Channel(ModesetSchema)` — session-typed FSM `{begin_txn → set_mode → set_plane* → commit | abort}`; the FSM is enforced by the substructural type system.
- `edid_channel : Channel(EdidSchema)` — RPC `read_edid(output_cap) -> Cap<KIND_MEMORY>`.

**User/kernel split.** Kernel: nothing new (the display engine is a PCIe device). Userspace: `display_engine_driver` (Iris Xe device driver), `display_supervisor` (aggregator that mints outputs + planes to clients).

**Test strategy.**
- **QEMU:** virtio-gpu path validates the schema; timing correctness needs real HW.
- **HW-gated:** cold boot with only eDP → assert eDP-1 mode list matches EDID; plug HDMI → assert `output_connected` event fires within 500 ms; set 4K mode via `KIND_MODESET_TXN`; screenshot via `KIND_DISPLAY_PLANE` readback.

**Milestones (4).**
- R36.M1 — Iris Xe PCI probe + BAR mapping + power-well sequencing (4).
- R36.M2 — Display topology + DP AUX + EDID read + `KIND_DISPLAY_OUTPUT` (5).
- R36.M3 — Atomic modeset FSM + `KIND_MODESET_TXN` (5).
- R36.M4 — Plane composition (primary + overlay + cursor) as `KIND_DISPLAY_PLANE` (4).

---

### R37 — Iris Xe execution engine: GEM-equivalent, GuC/HuC firmware, command submission (36 issues)

**Purpose.** Second half of GPU bring-up: the compute path. Buffer objects, virtual-memory bindings, command rings, engine scheduling, GuC firmware submission, HuC firmware for HEVC decode. This is the largest single round in Axis 1; without it there is no compositor, no Vulkan, no compute — only the framebuffer.

**New capabilities.**
- `KIND_GPU_BO` — *derived over `KIND_MEMORY`*, tail `{gpu_addr:u64, tiling:{linear|x|y|4|tf}, cache_level:u8, size_bytes:u64, dma_domain:CapRef<KIND_DMA_DOMAIN>}`. GPU buffer objects are first-class caps.
- `KIND_GPU_VM` — *derived over `KIND_IPC_ENDPOINT`*, tail `{ppgtt_root:u64, va_space_bytes:u64, num_bindings:u32}`. Per-process GPU virtual memory (like a paideia AS but on the GPU).
- `KIND_GPU_CONTEXT` — *linear over `KIND_IPC_ENDPOINT`*, tail `{vm_cap_slot:u8, engine_class:{rcs|bcs|vcs|vecs|ccs}, priority:i8}`. A GPU execution context; substructurally linear so nobody accidentally submits to the same context from two threads.
- `KIND_GPU_TIMELINE` — *derived over `KIND_HW_TIMELINE`*, tail `{last_signaled_value:u64, engine_cap_slot:u8}`. Monotonic 64-bit timeline per engine per context; the drm-syncobj lesson.
- `KIND_GPU_SUBMIT` — *linear over `KIND_IPC_ENDPOINT`*, tail `{cmd_buf_cap:CapRef<KIND_GPU_BO>, in_timelines:[Timeline;16], out_timelines:[Timeline;16]}`. One submission = one linear cap.

**IPC schemas.**
- `gpu_bo_alloc_channel : Channel(GpuBoAllocSchema)` — RPC `{alloc(size, tiling), free, export_fd, import_fd, cpu_map, cpu_unmap}`.
- `gpu_submit_channel : Channel(GpuSubmitSchema)` — session-typed `{prepare → bind_vm → submit → complete}`; enforces the FSM.
- `gpu_timeline_channel : Channel(GpuTimelineSchema)` — RPC `{wait_value(timeline, value, timeout), signal_value, query_current}`.

**User/kernel split.** Kernel: nothing new. Userspace: `gpu_execution_driver` (i915-equivalent, holds the MMIO cap for the GPU engines), `gpu_supervisor` (holds `KIND_GPU_BO`/`KIND_GPU_VM` allocators), `guc_firmware_loader` (loads GuC firmware, one-shot).

**Test strategy.**
- **QEMU:** virtio-gpu is a different arch; use software-rendered validation instead — a paideia-side WHLSL-lite → SPIR-V-lite pipeline that runs on both `llvmpipe`-equivalent and hardware.
- **HW-gated:** submit a trivial compute shader that writes `0xCAFEBABE` to a `KIND_GPU_BO`; read back on CPU; assert. Then a triangle rasterization test; screenshot.
- **Stress:** submit 100,000 no-op batches over multiple `KIND_GPU_CONTEXT`s; assert no VRAM leak (via allocator stats).

**Milestones (8).**
- R37.M1 — GPU BAR mapping + register substrate (4).
- R37.M2 — GuC firmware loader + auth (5).
- R37.M3 — `KIND_GPU_BO` allocator + tiling formats (5).
- R37.M4 — `KIND_GPU_VM` + PPGTT page-table walker (5).
- R37.M5 — `KIND_GPU_CONTEXT` + engine binding (4).
- R37.M6 — Command submission via GuC + `KIND_GPU_SUBMIT` (5).
- R37.M7 — `KIND_GPU_TIMELINE` + wait/signal semantics (4).
- R37.M8 — HuC firmware + video-decode engine substrate (deferred use in R44+) (4).

---

### R38 — Wi-Fi AX211 (iwlwifi-equivalent) + WPA3 supplicant (34 issues)

**Purpose.** The user explicitly deferred Wi-Fi to R41+ in the MVP plan, but exhaustive T14 G4 coverage demands it. The rearrangement is safe because MVP is closed. Wi-Fi is architecturally interesting because it forces us to design the mac80211-equivalent (`net80211`) *as* a class driver and the WPA supplicant *as* a userspace crypto server holding sealed key caps.

**New capabilities.**
- `KIND_WIFI_PHY` — *derived over `KIND_DEVICE`*, tail `{max_streams:u8, bands_bitmap:u8, he_supported:bool, eht_supported:bool}`.
- `KIND_WIFI_VIF` — *derived over `KIND_IPC_ENDPOINT`*, tail `{iftype:{sta|ap|monitor|mesh}, mac:[u8;6], phy_cap_slot:u8}`. Virtual interfaces; multiple per PHY.
- `KIND_WIFI_KEY` — *sealed, derived over `KIND_MEMORY`*, tail `{key_kind:{ptk|gtk|igtk}, cipher:{ccmp|gcmp|gcmp256}, key_idx:u8}`. Sealed so an application can hold the *cap* without the *material*; only the crypto server can unseal.
- `KIND_WIFI_SCAN_TXN` — *linear over `KIND_IPC_ENDPOINT`*, tail `{txn_id:u64, request_ssids:u8, request_channels:u8}`.

**IPC schemas.**
- `wifi_control_channel : Channel(WifiControlSchema)` — RPC `{scan, connect, disconnect, set_key, get_stats}`; effect row `!{net_send, net_recv, wifi_scan, wifi_key_use}`.
- `wifi_data_channel : Channel(WifiDataSchema)` — high-rate stream, feeds into `KIND_NET_L2_FRAME` (from R27).
- `wpa_supplicant_channel : Channel(WpaSupplicantSchema)` — RPC to `wpa_supervisor` process; carries `KIND_WIFI_KEY` sealed.
- `regdomain_channel : Channel(RegdomainSchema)` — periodic `{regdomain_hint}` — enforces per-country channel restrictions.

**User/kernel split.** Kernel: nothing new. Userspace: `iwlwifi_driver` (device driver, holds MMIO + MSI-X + `KIND_DMA_DOMAIN`), `net80211_class_driver` (class driver, mac80211-equivalent), `wpa_supervisor` (WPA3 SAE state machine, holds `KIND_WIFI_KEY` sealer).

**Test strategy.**
- **QEMU:** hostapd + mac80211_hwsim if we can port; else Linux capture replay.
- **HW-gated:** T14 G4 associates with a home AP running WPA3; iperf3 sustains > 500 Mbps; roam between two APs; assert `KIND_WIFI_KEY` rotation on rekey works.

**Milestones (7).**
- R38.M1 — iwlwifi PCI probe + FW loader (5).
- R38.M2 — CTXT_INFO + TX/RX queues + Rx/Tx DMA (5).
- R38.M3 — `KIND_WIFI_PHY` + `KIND_WIFI_VIF` (5).
- R38.M4 — net80211 class driver (mgmt frames, association) (5).
- R38.M5 — WPA3 SAE handshake + `KIND_WIFI_KEY` sealed (5).
- R38.M6 — Regdomain enforcement + `regdomain_channel` (4).
- R38.M7 — Roaming + rekey + scan-while-connected (5).

---

### R39 — Bluetooth HCI over Intel CNVi + L2CAP + core profiles (24 issues)

**Purpose.** Bluetooth on the AX211 is integrated CNVi — the HCI transport is shared with Wi-Fi at the PHY. This round: HCI transport, L2CAP, ATT/GATT, SDP; then HFP (headset), A2DP (audio streaming), HID (BT keyboards/mice), and BR/EDR pairing + BLE.

**New capabilities.**
- `KIND_BT_ADAPTER` — *derived over `KIND_DEVICE`*, tail `{addr:[u8;6], features_bitmap:u64, le_supported:bool, br_edr_supported:bool}`.
- `KIND_BT_HCI_CHANNEL` — *derived over `KIND_IPC_ENDPOINT`*, tail `{channel:{cmd|acl|sco|iso|event}}`. HCI is a bunch of typed streams.
- `KIND_BT_L2CAP_CHANNEL` — *derived over `KIND_IPC_ENDPOINT`*, tail `{psm:u16, cid:u16, mtu:u16, mode:{basic|retransmission|streaming|le_cbfc}}`.
- `KIND_BT_GATT_CONNECTION` — *derived over `KIND_IPC_ENDPOINT`*, tail `{peer_addr:[u8;6], mtu:u16, encrypted:bool}`.
- `KIND_BT_PAIRING` — *sealed, derived over `KIND_MEMORY`*, tail `{peer_addr:[u8;6], ltk_present:bool, irk_present:bool}`. LTK/IRK held sealed; only the pairing server unseals.

**IPC schemas.**
- `bt_hci_channel : Channel(BtHciSchema)` — session-typed HCI transport.
- `bt_l2cap_channel : Channel(BtL2capSchema)` — RPC + stream.
- `bt_gatt_channel : Channel(BtGattSchema)` — RPC `{read_char, write_char, subscribe, notify}`.
- `bt_pairing_channel : Channel(BtPairingSchema)` — RPC `{begin_pairing, confirm_passkey, complete}` — user consent brokered by desktop policy.

**User/kernel split.** All userspace. `bt_transport_driver` (HCI over CNVi), `bt_hci_supervisor` (dispatch + timing), `bt_l2cap_driver`, `bt_gatt_driver`, `bt_pairing_supervisor`, `bt_hfp_profile`, `bt_a2dp_profile`, `bt_hid_profile`.

**Test strategy.**
- **QEMU:** limited; use `hcidump` replays.
- **HW-gated:** T14 G4 pairs BLE headphones; A2DP audio streams; latency < 200 ms; then a BT keyboard, keystrokes reach the HID event stream.

**Milestones (6).**
- R39.M1 — HCI transport over CNVi + `KIND_BT_HCI_CHANNEL` (4).
- R39.M2 — L2CAP + `KIND_BT_L2CAP_CHANNEL` (4).
- R39.M3 — ATT/GATT + `KIND_BT_GATT_CONNECTION` (4).
- R39.M4 — Pairing (LE Secure Connections) + `KIND_BT_PAIRING` sealed (4).
- R39.M5 — A2DP profile + audio-graph bridge to R33 (4).
- R39.M6 — HFP + HID profiles (4).

---

### R40 — MIPI-CSI + IPU6, WWAN (M.2 modem), audit consolidation (18 issues)

**Purpose.** Close out T14 G4: MIPI-CSI camera + IPU6 (Intel's imaging processing unit) provides webcam; WWAN slot supports optional M.2 modem cards (Fibocom L850-GL is common). Also a consolidation round: unify the `audit_channel` schema across every KIND_* introduced R29–R39, close every remaining derived-kind entry in `derived-kind-catalog.md`.

**New capabilities.**
- `KIND_CSI_CAMERA` — *derived over `KIND_DEVICE`*, tail `{port:u8, lanes:u8, sensor_model:[u8;16], resolutions_bitmap:u32}`.
- `KIND_IPU6_STREAM` — *derived over `KIND_IPC_ENDPOINT`*, tail `{pipeline_id:u8, output_format:{nv12|yuyv|mjpeg|raw10}, resolution:u32}`.
- `KIND_WWAN_MODEM` — *derived over `KIND_DEVICE`*, tail `{modem_class:{qmi|mbim|at}, imei:[u8;16], sim_present:bool}`.
- `KIND_MBIM_SESSION` — *derived over `KIND_IPC_ENDPOINT`*, tail `{session_id:u8, apn_hash:[u8;32], connected:bool}`.

**IPC schemas.**
- `camera_capture_channel : Channel(CameraCaptureSchema)` — session `{open → configure → begin_stream → frames* → end_stream → close}`; frame carries `KIND_GPU_BO` (zero-copy to compositor).
- `wwan_control_channel : Channel(WwanControlSchema)` — RPC.
- `wwan_data_channel : Channel(WwanDataSchema)` — stream, feeds into IP stack.

**User/kernel split.** All userspace.

**Test strategy.**
- **HW-gated:** T14 G4 webcam produces frames at 30 fps; screenshot via display supervisor.
- **HW-gated (optional WWAN):** if modem present, `KIND_MBIM_SESSION` connects to a specified APN.

**Milestones (5).**
- R40.M1 — IPU6 PCI probe + firmware load (4).
- R40.M2 — MIPI-CSI receiver + `KIND_CSI_CAMERA` (4).
- R40.M3 — IPU6 imaging pipelines (denoise, ISP, format convert) + `KIND_IPU6_STREAM` (4).
- R40.M4 — WWAN M.2 modem + MBIM/QMI over USB (4).
- R40.M5 — Audit-schema unification + derived-kind-catalog closure (2).

---

### Axis 1 rollup

| Round | Focus | Issues | Milestones |
|---|---|---:|---:|
| R29 | Driver framework maturation | 30 | 7 |
| R30 | ACPICA + LPSS buses | 40 | 9 |
| R31 | EC + platform sensors + backlight | 26 | 6 |
| R32 | I²C-HID + sensor hub + HID class | 22 | 5 |
| R33 | HDA + ALC287 + SOF audio | 30 | 6 |
| R34 | USB fabric completion + fingerprint | 28 | 6 |
| R35 | TB4 / USB4 + PCIe hotplug + DMA consent | 24 | 5 |
| R36 | Iris Xe modesetting | 18 | 4 |
| R37 | Iris Xe execution engine | 36 | 8 |
| R38 | Wi-Fi AX211 + WPA3 | 34 | 7 |
| R39 | Bluetooth HCI + core profiles | 24 | 6 |
| R40 | Camera + WWAN + audit consolidation | 18 | 5 |
| **Total** | | **330** | **74** |

---

## 4. Axis 2 — GPU-native GUI (G1–G12; interleaved with R38–R48+)

The compositor stack takes 12 rounds. G1–G4 are R38-parallel (they need R37 GPU execution but not more); G5–G8 are R41-parallel; G9–G12 push into R45+. Each round is enumerated below with the pitfalls it avoids, its protocol shape, capabilities, and citations.

### G1 — Display substrate + explicit-sync primitive (16 issues)

**Purpose.** Everything the compositor needs from the display side: modesetting (from R36), display-plane assignment, VRR/adaptive-sync capability probe, and — **the pivotal new primitive** — an explicit-sync timeline capability shared by GPU and display engine.

**Pitfalls avoided.** Wayland's implicit-sync legacy (buffer-attached implicit fences on dmabuf, which fights modern GPU drivers and forces round-trips through the kernel). We take drm-syncobj timelines as the *only* sync primitive from day one.

**New capabilities.**
- `KIND_DISPLAY_TIMELINE` — *derived over `KIND_HW_TIMELINE`*, tail `{engine_id:u8, last_scanout_value:u64}`. Same shape as `KIND_GPU_TIMELINE` so cross-engine wait is trivially expressible.
- `KIND_VRR_RANGE` — *derived over `KIND_DISPLAY_MODE`*, tail `{min_refresh_mhz:u32, max_refresh_mhz:u32, min_frametime_ns:u32}`.

**Protocol.**
- `display_sync_channel : Channel(DisplaySyncSchema)` — RPC `{wait_scanout(timeline, value, timeout_ns) -> presented_at_ns, present_flush(timeline, target_value, target_scanout_ts)}`. Everything in nanoseconds.

**Research citations.**
- Wayland `linux-explicit-synchronization-v1` proposals, then `wp_linux_drm_syncobj_manager_v1` (2023–24) — we adopt the latter's shape.
- Nvidia's implicit-vs-explicit sync mailing-list debate (dri-devel, 2016–2023) — the failure mode is what we're avoiding.
- drm-syncobj kernel interface (Christian König, AMD, 2017).

**Milestones (3).** G1.M1 `KIND_DISPLAY_TIMELINE` (5). G1.M2 VRR probe + `KIND_VRR_RANGE` (5). G1.M3 explicit-sync wait/signal integration with R37 GPU timeline (6).

---

### G2 — Direct-scanout planes + fullscreen tearing-free VRR (14 issues)

**Purpose.** When a game or video runs fullscreen, its buffer must go **straight to the display plane** with no compositor round-trip; the GPU timeline must directly signal the display engine's frame-latch. Under VRR the frame's target refresh is chosen by the *application*, not by the compositor.

**Pitfalls avoided.** X's "always composite" default (compositor sits in the loop). Wayland's early compositor lock-step (double-buffered swap-chain implicit). macOS's inability to expose true VRR to apps.

**New capabilities.**
- `KIND_SCANOUT_LEASE` — *linear over `KIND_DISPLAY_PLANE`*, tail `{output_cap_slot:u8, timeline_cap_slot:u8, lease_ns_expiry:u64}`. Direct-scanout is a *lease*: the application holds the plane exclusively until the lease expires or is revoked (e.g., other window comes to front).

**Protocol.**
- `scanout_lease_channel : Channel(ScanoutLeaseSchema)` — session-typed `{request_lease → lease_granted | denied → present* → release}`.

**Research citations.**
- Chris Forbes / Weston direct-scanout patches (2015+).
- Steam Deck's Gamescope compositor (scanout leasing on Wayland).
- Windows Direct Flip / Independent Flip (DXGI); the closest prior art done well.

**Milestones (3).** G2.M1 `KIND_SCANOUT_LEASE` + revocation semantics (5). G2.M2 VRR frame-latch (per-frame timeline value = target scanout) (5). G2.M3 Fallback path when lease revoked mid-frame (4).

---

### G3 — Vulkan-native surface + swapchain (18 issues)

**Purpose.** Vulkan is the native rendering API; Skia/Vello/Slug/etc. all lower to Vulkan. This round establishes the paideia Vulkan surface extension, swapchain protocol, and image-acquire/release semantics. We do **not** re-invent WSI (Window System Integration); we specify paideia's `VK_paideia_surface`.

**Pitfalls avoided.** X11's XCB/XCB-XCB-XCB dance for WSI. Wayland's `wl_surface` conflated with input. Windows' HWND-as-everything.

**New capabilities.**
- `KIND_VK_SURFACE` — *derived over `KIND_IPC_ENDPOINT`*, tail `{window_id:u64, format:u16, colorspace:u16, presentation_mode:{fifo|mailbox|immediate|fifo_relaxed}}`. A surface knows its swap semantics.
- `KIND_VK_SWAPCHAIN_IMAGE` — *linear over `KIND_GPU_BO`*, tail `{image_index:u8, acquire_timeline:CapRef<KIND_GPU_TIMELINE>, release_timeline:CapRef<KIND_DISPLAY_TIMELINE>}`. Explicit sync on both ends.

**Protocol.**
- `vk_surface_channel : Channel(VkSurfaceSchema)` — RPC `{create_swapchain, acquire_image, present_image, destroy_swapchain}`.
- `vk_present_feedback_channel : Channel(VkPresentFeedbackSchema)` — stream (per acquire) of `{presented_at_ns, refresh_ns, next_refresh_ns, discarded:bool}`. **Every present gives feedback.**

**Research citations.**
- `VK_KHR_swapchain`, `VK_KHR_present_id`, `VK_KHR_present_wait` (Khronos, 2018+).
- `VK_EXT_swapchain_maintenance1` (2023) — the modern shape.
- Vulkan Presentation Timing extension (`VK_GOOGLE_display_timing`, `VK_KHR_present_id`).

**Milestones (4).** G3.M1 `KIND_VK_SURFACE` + `VK_paideia_surface` ICD entry (5). G3.M2 Swapchain image acquire/present with dual timeline (5). G3.M3 Present feedback (5). G3.M4 Presentation-time-driven adaptive rendering example (3).

---

### G4 — Compute-based 2D rasterization stack (Vello-lineage) (16 issues)

**Purpose.** All 2D rendering — text, shapes, paths, gradients, blurs — happens as *compute shaders* on the GPU. No fixed-function 2D path; no CPU rasterizer; no cairo/skia dependency for the compositor's own drawing.

**Pitfalls avoided.** Skia's dual CPU+GPU maintenance burden; cairo's software rasterization; Blink's tile-invalidation combinatorial explosion.

**New capabilities.**
- `KIND_VELLO_SCENE` — *derived over `KIND_GPU_BO`*, tail `{path_count:u32, encoded_bytes:u64}`. A scene is an encoded stream of drawing commands, uploaded as one buffer.
- `KIND_VELLO_RENDERER` — *derived over `KIND_GPU_CONTEXT`*, tail `{tile_size:u16, sample_count:u8}`. Renderer is a linear context.

**Protocol.**
- `vello_render_channel : Channel(VelloRenderSchema)` — RPC `{encode_scene, submit_render, await_completion}`.

**Research citations.**
- Raph Levien, "Vello: The Next Chapter" (2022–2024 blog series).
- piet-gpu, piet-metal (2020–2022).
- Google's Rive renderer (2023).
- Skia's Ganesh (GPU backend) — what we're *replacing*, not adopting.
- Kilgard & Bolz "GPU-Accelerated Path Rendering" (SIGGRAPH Asia 2012).

**Milestones (4).** G4.M1 Scene-encoder library in paideia-as (5). G4.M2 GPU-side path stroking + filling compute pipelines (5). G4.M3 Gradient + blur compute passes (3). G4.M4 Tile-based render coarsening (3).

---

### G5 — SDF font rasterization + text layout + fractional scaling (18 issues)

**Purpose.** SDF (signed-distance-field) glyphs, sub-pixel-positioned; fractional scaling at target resolution (not integer upscale); complex-script shaping (Latin + CJK + RTL + Indic); vertical text; color emoji.

**Pitfalls avoided.** X's FreeType-CPU-rasterize + Xft blit (upscale artifacts). macOS's Quartz-2D CPU path for text. Windows GDI's ClearType (great when it works, sub-pixel positioning locked).

**New capabilities.**
- `KIND_FONT_ATLAS` — *derived over `KIND_GPU_BO`*, tail `{atlas_width:u16, atlas_height:u16, format:{sdf|msdf|coverage}, glyphs_present:u32}`.
- `KIND_TEXT_SHAPE` — *derived over `KIND_MEMORY`*, tail `{script:u8, direction:{ltr|rtl|ttb|btt}, features_hash:[u8;16]}`.

**Protocol.**
- `font_load_channel : Channel(FontLoadSchema)` — RPC `{load_font(cap<mem>) -> Cap<KIND_FONT_ATLAS>, subset_atlas, evict}`.
- `text_shape_channel : Channel(TextShapeSchema)` — RPC `{shape(runs) -> Cap<KIND_TEXT_SHAPE>}`. This is a separate service so IME (G12) can plug in for pre-edit.

**Research citations.**
- Green, "Improved Alpha-Tested Magnification for Vector Textures and Special Effects" (SIGGRAPH 2007) — original SDF.
- Chlumsky, "MSDF" (2019) — the multi-channel refinement.
- Lengyel, "Slug: A Fast Anti-Aliased Vector Graphics Rendering Algorithm for the GPU" (2017) — direct GPU path rendering for text.
- HarfBuzz shaping engine (we port or wrap).
- Fira Code's fractional-scaling positioning discipline.

**Milestones (4).** G5.M1 SDF atlas generator + `KIND_FONT_ATLAS` (5). G5.M2 Text shaper (HarfBuzz-equivalent) + `KIND_TEXT_SHAPE` (5). G5.M3 Fractional-scale-aware sub-pixel positioning (4). G5.M4 Color emoji (COLR/CPAL, SBIX, CBDT) (4).

---

### G6 — Color management: ICC-aware, HDR, wide-gamut, tone-mapping (16 issues)

**Purpose.** From the first pixel every buffer knows its colorspace; the compositor does conversion in a dedicated compute pipeline; HDR10 / HLG / DolbyVision buffers land on HDR outputs untone-mapped; SDR content is tone-mapped up gracefully; ICC profiles for external displays.

**Pitfalls avoided.** X's no-colorspace anywhere (SDR-only forever). Wayland's late `color-management-v1` bolt-on. Windows' HDR shipping years before apps could opt in. macOS's Display-P3 conflation.

**New capabilities.**
- `KIND_COLOR_PROFILE` — *derived over `KIND_MEMORY`*, tail `{cicp:[u8;3], primaries:u8, transfer:u8, matrix:u8, icc_ref:Option<Cap<KIND_MEMORY>>}`. CICP-aligned so encoders don't guess.
- `KIND_HDR_METADATA` — *derived over `KIND_MEMORY`*, tail `{mastering_primaries:[u16;8], mastering_luminance:[u32;2], max_cll:u16, max_fall:u16}`.
- `KIND_TONEMAP_LUT` — *derived over `KIND_GPU_BO`*, tail `{lut_size:u16, direction:{sdr_to_hdr|hdr_to_sdr|hdr_to_hdr}}`.

**Protocol.**
- Every buffer that carries an image has `Cap<KIND_COLOR_PROFILE>` as a required field of its surface commit; **the surface commit fails elaboration without it**.
- `color_management_channel : Channel(ColorMgmtSchema)` — RPC `{query_output_gamut, get_tonemap_lut, set_reference_display}`.

**Research citations.**
- Wayland `color-management-v1` (Sebastian Wick, Pekka Paalanen, 2020–2024).
- Freedesktop CICP tag + BT.2100 documents.
- Apple's ColorSync architecture (well-designed but proprietary).
- ITU-R BT.2408 (guidance for HDR/SDR content interchange).
- Microsoft DirectComposition HDR paper (2018).

**Milestones (4).** G6.M1 `KIND_COLOR_PROFILE` + CICP + ICC parsing (5). G6.M2 GPU compute conversion pipeline (all combos) (5). G6.M3 `KIND_HDR_METADATA` + HDR10 direct-scanout (3). G6.M4 Reference-display tone-mapping (3).

---

### G7 — Paideia-native compositor protocol (single unified) (22 issues)

**Purpose.** ONE surface/window/input/output protocol; not "core + 200 extensions". Every capability that Wayland or X exposes is either (a) part of the base schema, or (b) explicitly excluded with a design memo. The protocol is a session-typed `Channel(CompositorSchema)`.

**Pitfalls avoided.** X11's core protocol calcification and its 100+ extensions. Wayland's `wl_seat` capability accumulation, `wl_shell` obsolescence, XDG-shell layering. macOS's undocumented CoreAnimation quirks. Windows' HWND-message accretion.

**New capabilities.**
- `KIND_SURFACE` — *derived over `KIND_IPC_ENDPOINT`*, tail `{surface_id:u64, role:{toplevel|popup|subsurface|cursor|dnd_icon}, size_hint:u64, scale_hint_q16:u32}`. Roles are baked-in — new roles need a paideia design memo, not an extension proposal.
- `KIND_SURFACE_COMMIT` — *linear over `KIND_IPC_ENDPOINT`*, tail `{commit_id:u64, buffer_cap:CapRef<KIND_GPU_BO>, damage_regions:u16, timeline_target:u64}`. One commit = one linear cap = one atomic surface update.
- `KIND_WINDOW` — *derived over `KIND_SURFACE`*, tail `{title_hash:[u8;16], app_id_hash:[u8;16], state:{normal|maximized|fullscreen|minimized|tiled}}`.
- `KIND_LAYER_TREE` — *derived over `KIND_IPC_ENDPOINT`*, tail `{root_surface_slot:u8, layer_count:u16}`. Subsurface hierarchy is a first-class cap tree.

**Protocol (canonical).**
- `compositor_channel : Channel(CompositorSchema)` — the core. Session type: `{connect → capability_advertise → (create_surface | create_window | attach_buffer | commit | destroy)*}`.
- Includes: surface creation, window role assignment, layer subsurfaces, popup positioning, decoration policy, XDG-shell-equivalent semantics, input focus request, DnD, clipboard, screencapture (permissioned).
- Excludes (with reason): window listing (privacy), arbitrary raster in compositor (that's client work), color-conversion in compositor (GPU compute).

**Research citations.**
- Wayland (Kristian Høgsberg, 2008–) — heavy influence; what we clean up.
- XDG-shell v6 → stable — the good ideas migrate to `KIND_WINDOW`.
- Fuchsia Scenic (Google, 2018) — closest philosophical prior art: layer-tree, session-typed.
- Chromium Viz / CC (compositor thread architecture, 2015+).
- macOS CoreAnimation / QuartzCompositor (proprietary but exemplary layer model).
- Windows DirectComposition (2013+) — visual tree well-designed.

**Milestones (6).** G7.M1 `KIND_SURFACE` + `KIND_SURFACE_COMMIT` + session-typed core (5). G7.M2 `KIND_WINDOW` roles (4). G7.M3 `KIND_LAYER_TREE` + subsurface + popup (5). G7.M4 Damage region protocol + buffer-age semantics (4). G7.M5 DnD + clipboard as sealed cap flow (2). G7.M6 Screencapture protocol (permissioned) (2).

---

### G8 — Input event routing (per-device, compositor-adjacent) (14 issues)

**Purpose.** Input is a service **peer** to the compositor, not owned by it. Multiple compositors can share one input service; a compositor crash never eats input. Multi-touch, stylus, touchpad gestures each have their own routing table; per-device pointer acceleration; per-device scroll direction.

**Pitfalls avoided.** X's server-side input state. Wayland's `wl_seat` monopoly. Linux's evdev-as-god blob. macOS's HID service tightly coupled to WindowServer.

**New capabilities.**
- `KIND_INPUT_ROUTE` — *linear over `KIND_IPC_ENDPOINT`*, tail `{device_cap_slot:u8, target_surface_slot:u8, mode:{grab|focus|hover}}`. A route is linear — only one owner at a time.
- `KIND_SEAT` — *derived over `KIND_IPC_ENDPOINT`*, tail `{seat_id:u8, capabilities_bitmap:u16, active_focus_slot:u8}`.

**Protocol.**
- `input_router_channel : Channel(InputRouterSchema)` — RPC `{register_target, request_focus, grab, ungrab}`.
- `input_event_channel : Channel(InputEventSchema)` — stream carrying `KIND_HID_EVENT` (from R32) tagged with `KIND_INPUT_ROUTE` at delivery.

**Research citations.**
- libinput (Peter Hutterer) — algorithm reuse; we lift the pointer-acceleration curves.
- macOS HIToolbox — well-partitioned input service.
- weston-input-method-v1 vs zwp_input_method_v1 — the layering to avoid.

**Milestones (3).** G8.M1 `KIND_INPUT_ROUTE` + `input_router` service (5). G8.M2 Per-device pointer accel + scroll direction + tap-to-click (5). G8.M3 Multi-seat + touch + stylus routing (4).

---

### G9 — Windowing + damage/buffer-age + presentation-time feedback (14 issues)

**Purpose.** Full windowing shell: floating, tiled, workspaces, cross-workspace drag; damage tracking with buffer-age; presentation-time signals delivered to clients so they adapt to actual refresh (60 Hz vs VRR 40–144 Hz).

**Pitfalls avoided.** X's Xinerama/RandR windowing quirks. Wayland's per-compositor invented workspace semantics. Windows' Aero-vs-DWM legacy.

**New capabilities.**
- `KIND_WORKSPACE` — *derived over `KIND_IPC_ENDPOINT`*, tail `{workspace_id:u16, output_binding:{single(cap)|all|policy}, layout:{floating|bsp|columns}}`.
- `KIND_DAMAGE_REGION` — *derived over `KIND_MEMORY`*, tail `{rect_count:u16, coordinate_space:{surface|output|buffer}}`.
- `KIND_PRESENT_FEEDBACK` — *derived over `KIND_IPC_ENDPOINT`*, tail `{commit_id:u64, presented_at_ns:u64, refresh_ns:u32}`.

**Protocol.**
- `windowing_channel : Channel(WindowingSchema)` — RPC `{create_workspace, move_window, tile, focus}`.
- `present_feedback_channel : Channel(PresentFeedbackSchema)` — stream of `KIND_PRESENT_FEEDBACK`.

**Research citations.**
- Wayland `wp_presentation` protocol (Pekka Paalanen).
- Chromium's frame scheduler + BeginFrame args (2015+).
- macOS `CADisplayLink` / iOS's approach.
- Weston + KWin latency papers.

**Milestones (3).** G9.M1 Workspaces + tiling (5). G9.M2 Damage tracking with buffer-age (5). G9.M3 Presentation-time feedback + client-side adaptive-rate (4).

---

### G10 — Accessibility hooks in the surface protocol (12 issues)

**Purpose.** Accessibility is **part of** the surface protocol, not an ATK/AT-SPI/UIA bolt-on. Every window and widget publishes semantic structure; screen readers subscribe; keyboard navigation is a compositor-level concept.

**Pitfalls avoided.** X's AT-SPI as separate bus. Windows' UIA vs MSAA fragmentation. macOS's accessibility protocol as afterthought.

**New capabilities.**
- `KIND_A11Y_TREE` — *derived over `KIND_IPC_ENDPOINT`*, tail `{root_node_id:u64, tree_generation:u64}`. Every application maintains an a11y tree; the tree is a *cap*, subscribable.
- `KIND_A11Y_NODE` — *derived over `KIND_MEMORY`*, tail `{node_id:u64, role:u16, state_bitmap:u32, name_len:u16, description_len:u16}`.

**Protocol.**
- `a11y_channel : Channel(A11ySchema)` — RPC + stream `{subscribe_tree, get_node, walk_tree, request_action, focus_node}`.
- Every `KIND_WINDOW` carries a bound `KIND_A11Y_TREE` at creation.

**Research citations.**
- AccessKit (Rust project by Matt Campbell) — modern platform-agnostic a11y tree; we adopt the tree shape.
- ARIA authoring practices (W3C) — role/state semantics.
- Apple Accessibility Programming Guide.
- Chromium's accessibility architecture (BrowserAccessibility trees, 2013+).

**Milestones (3).** G10.M1 `KIND_A11Y_TREE` + AccessKit-shape schema (5). G10.M2 Screen-reader client + navigation (4). G10.M3 Keyboard navigation as compositor concept (3).

---

### G11 — Unified IME (Latin/CJK/RTL) + text-input (12 issues)

**Purpose.** IME as a **service peer** to compositor and text-shape service (G5). One IME protocol handles Latin autocomplete, CJK candidate windows, RTL bidi, Indic complex composition. Pre-edit strings flow through the same text-shape pipeline as final text (so pre-edit renders identically).

**Pitfalls avoided.** Linux IBus/fcitx/scim fragmentation. Wayland `text-input-v3` slowness of adoption. macOS's TSM as separate stack from CoreText. Windows TSF's complexity.

**New capabilities.**
- `KIND_IME_SESSION` — *linear over `KIND_IPC_ENDPOINT`*, tail `{surface_slot:u8, ime_id_hash:[u8;16], preedit_active:bool}`.
- `KIND_IME_PROVIDER` — *derived over `KIND_DEVICE`*, tail `{provider_kind:{latin|pinyin|zhuyin|kana|hangul|indic}, dict_hash:[u8;32]}`.

**Protocol.**
- `ime_channel : Channel(ImeSchema)` — session-typed `{activate → begin_composition → preedit* → candidates* → commit | abandon → deactivate}`.

**Research citations.**
- IBus / fcitx protocol design (Zhuyin, Pinyin, Anthy engines).
- Wayland text-input-v3 (Dorota Czaplejewicz, 2019+).
- Windows TSF (2000+) — the well-designed proprietary one.
- macOS Text Services Manager (Objective-C legacy but principled).

**Milestones (3).** G11.M1 `KIND_IME_SESSION` + session-typed protocol (5). G11.M2 `KIND_IME_PROVIDER` + first providers (Latin + Pinyin) (4). G11.M3 Bidi + Indic support integration with G5 (3).

---

### G12 — Developer APIs + first-party toolkit (`libpaideia-ui`) (14 issues)

**Purpose.** The compositor protocol is low-level; app developers need a toolkit. One paideia-native toolkit (`libpaideia-ui`) ships with the OS, built on top of the compositor + Vello + SDF text + a11y. Immediate-mode plus retained-mode APIs (like `egui` + `Iced`); zero external dependencies.

**Pitfalls avoided.** GTK vs Qt tribalism. Every OS providing 3+ overlapping toolkits. Toolkit-as-second-class (Wayland: apps run through xdg-shell + custom draw code; macOS/AppKit: framework-locked).

**New capabilities.**
- `KIND_UI_CONTEXT` — *derived over `KIND_IPC_ENDPOINT`*, tail `{app_id_hash:[u8;16], render_mode:{immediate|retained|hybrid}}`.

**Protocol.**
- `ui_toolkit_channel : Channel(UiToolkitSchema)` — session that binds a widget tree to a `KIND_WINDOW` + `KIND_A11Y_TREE` + `KIND_VELLO_RENDERER`.

**Research citations.**
- `egui` (Emil Ernerfeldt) — immediate-mode Rust; simplicity model.
- `Iced` (Héctor Ramón) — Elm architecture in Rust.
- SwiftUI declarative patterns.
- Flutter's widget tree.
- `Xilem` (Raph Levien's post-Druid explorations, 2022+).

**Milestones (3).** G12.M1 Immediate-mode API on Vello + SDF text (5). G12.M2 Retained widget tree + a11y binding (5). G12.M3 Sample apps (settings, clock, text editor) (4).

---

### Axis 2 rollup

| Round | Focus | Issues | Milestones |
|---|---|---:|---:|
| G1 | Display substrate + explicit-sync | 16 | 3 |
| G2 | Direct-scanout + VRR | 14 | 3 |
| G3 | Vulkan-native surface + swapchain | 18 | 4 |
| G4 | Vello-lineage 2D | 16 | 4 |
| G5 | SDF text + fractional scaling | 18 | 4 |
| G6 | Color management + HDR | 16 | 4 |
| G7 | Compositor protocol (canonical) | 22 | 6 |
| G8 | Input routing (compositor-adjacent) | 14 | 3 |
| G9 | Windowing + presentation feedback | 14 | 3 |
| G10 | Accessibility hooks | 12 | 3 |
| G11 | Unified IME | 12 | 3 |
| G12 | Developer APIs + toolkit | 14 | 3 |
| **Total** | | **186** | **43** |

Combined Axis 1 + Axis 2: **~516 issues** across **~117 milestones** across ~24 named rounds.

---

## 5. Capability / interface catalogue

Every new abstraction introduced above, with derivation base and rationale. Sorted by first-appearance round.

### 5.1 Base-kind slot allocations

The 16 base kinds (from `linearity-and-tags.md` §3.1) are frozen with two reserved slots (14, 15) documented for future use. **This proposal reserves slot 14** to shelter the family of hardware-adjacent kinds (`KIND_INTERRUPT`, `KIND_HW_TIMELINE`, `KIND_DEVICE`-adjacent) that were previously derived-over-`KIND_DEVICE` but are used broadly enough to deserve LAM kind-hint fast-dispatch. Slot 15 remains reserved for confidential-compute (TDX per CAP-Q9 open issue).

### 5.2 Derived-kind catalogue (introduced in this proposal)

| KIND | Base | Round | Rationale |
|---|---|---|---|
| `KIND_INTERRUPT` | slot 14 | R29 | Every IRQ endpoint is a first-class cap; drivers hold N per device without holding the device itself. |
| `KIND_MSIX_VECTOR` | `KIND_INTERRUPT` | R29 | Fine-grained MSI-X vector routing without cross-driver reads. |
| `KIND_DMA_DOMAIN` | `KIND_MEMORY` | R29 | Per-device IOMMU domain; DMA-consent flow anchors here. |
| `KIND_HW_TIMELINE` | slot 14 | R29 | First appearance of the timeline primitive; foundation for GPU/audio/display sync. |
| `KIND_AML_SESSION` | `KIND_IPC_ENDPOINT` | R30 | Arbitration of concurrent AML evaluations. |
| `KIND_OP_REGION` | `KIND_MEMORY`/`KIND_PORT` | R30 | AML's `OpRegion` as an explicit cap; no other component can silently poke hardware. |
| `KIND_I2C_BUS` | `KIND_DEVICE` | R30 | LPSS I²C controllers hand these out. |
| `KIND_I2C_SLAVE` | `KIND_I2C_BUS` | R30 | Every I²C slave is a discrete cap. |
| `KIND_GPIO_LINE` | `KIND_DEVICE` | R30 | Per-pin GPIO cap for backlight/EC/etc. |
| `KIND_EC_QUERY` | `KIND_IPC_ENDPOINT` | R31 | EC query events as a cap-mediated stream. |
| `KIND_THERMAL_ZONE` | `KIND_DEVICE` | R31 | ACPI thermal zone. |
| `KIND_COOLING_DEVICE` | `KIND_DEVICE` | R31 | Fans / passive throttling. |
| `KIND_BATTERY` | `KIND_DEVICE` | R31 | Battery state. |
| `KIND_BACKLIGHT` | `KIND_DEVICE` | R31 | Panel + keyboard backlight. **Held by compositor only.** |
| `KIND_HID_DEVICE` | `KIND_DEVICE` | R32 | Unified HID device (multi-transport). |
| `KIND_HID_EVENT` | `KIND_IPC_ENDPOINT` | R32 | Unified event stream. |
| `KIND_SENSOR_CHANNEL` | `KIND_IPC_ENDPOINT` | R32 | ALS/accel/gyro. |
| `KIND_AUDIO_CONTROLLER` | `KIND_DEVICE` | R33 | HDA controller. |
| `KIND_PCM_STREAM` | `KIND_IPC_ENDPOINT` | R33 | Linear PCM stream. |
| `KIND_AUDIO_CLOCK` | `KIND_HW_TIMELINE` | R33 | Audio timeline. |
| `KIND_AUDIO_ROUTE` | `KIND_IPC_ENDPOINT` | R33 | Route entry held by audio supervisor. |
| `KIND_USB_HUB` | `KIND_USB_DEVICE` | R34 | Hub as first-class. |
| `KIND_USB_INTERFACE` | `KIND_USB_DEVICE` | R34 | Interface (not device) is the driver-binding unit. |
| `KIND_USB_ENDPOINT` | `KIND_IPC_ENDPOINT` | R34 | Endpoint as cap. |
| `KIND_ISOCH_STREAM` | `KIND_USB_ENDPOINT` | R34 | Isoch endpoints ALWAYS carry timeline. |
| `KIND_FP_SENSOR` | `KIND_DEVICE` | R34 | Fingerprint reader. |
| `KIND_TB_DOMAIN` | `KIND_DEVICE` | R35 | TB4 router. |
| `KIND_TB_ROUTE` | `KIND_IPC_ENDPOINT` | R35 | TB4 tunnel. |
| `KIND_PCIE_HOTPLUG_EVENT` | `KIND_IPC_ENDPOINT` | R35 | PCIe hotplug event stream. |
| `KIND_DMA_ATTESTATION` | `KIND_IPC_ENDPOINT` | R35 | User-consent token for external DMA. |
| `KIND_DISPLAY_ENGINE` | `KIND_DEVICE` | R36 | Iris Xe display engine. |
| `KIND_DISPLAY_OUTPUT` | `KIND_DEVICE` | R36 | eDP/HDMI/DP output. |
| `KIND_DISPLAY_MODE` | `KIND_MEMORY` | R36 | Mode descriptor (immutable). |
| `KIND_DISPLAY_PLANE` | `KIND_MEMORY` | R36 | Overlay/cursor/primary plane. |
| `KIND_MODESET_TXN` | `KIND_IPC_ENDPOINT` | R36 | Linear atomic modeset transaction. |
| `KIND_GPU_BO` | `KIND_MEMORY` | R37 | GPU buffer object. |
| `KIND_GPU_VM` | `KIND_IPC_ENDPOINT` | R37 | Per-process GPU virtual memory. |
| `KIND_GPU_CONTEXT` | `KIND_IPC_ENDPOINT` | R37 | Linear execution context. |
| `KIND_GPU_TIMELINE` | `KIND_HW_TIMELINE` | R37 | Per-engine timeline. |
| `KIND_GPU_SUBMIT` | `KIND_IPC_ENDPOINT` | R37 | Linear submission cap. |
| `KIND_WIFI_PHY` | `KIND_DEVICE` | R38 | Wi-Fi physical device. |
| `KIND_WIFI_VIF` | `KIND_IPC_ENDPOINT` | R38 | Virtual interface. |
| `KIND_WIFI_KEY` | sealed `KIND_MEMORY` | R38 | Sealed key material. |
| `KIND_WIFI_SCAN_TXN` | `KIND_IPC_ENDPOINT` | R38 | Linear scan transaction. |
| `KIND_BT_ADAPTER` | `KIND_DEVICE` | R39 | BT adapter. |
| `KIND_BT_HCI_CHANNEL` | `KIND_IPC_ENDPOINT` | R39 | HCI transport channel. |
| `KIND_BT_L2CAP_CHANNEL` | `KIND_IPC_ENDPOINT` | R39 | L2CAP CID. |
| `KIND_BT_GATT_CONNECTION` | `KIND_IPC_ENDPOINT` | R39 | GATT connection. |
| `KIND_BT_PAIRING` | sealed `KIND_MEMORY` | R39 | Sealed pairing keys. |
| `KIND_CSI_CAMERA` | `KIND_DEVICE` | R40 | MIPI-CSI camera. |
| `KIND_IPU6_STREAM` | `KIND_IPC_ENDPOINT` | R40 | IPU6 imaging pipeline output. |
| `KIND_WWAN_MODEM` | `KIND_DEVICE` | R40 | WWAN modem. |
| `KIND_MBIM_SESSION` | `KIND_IPC_ENDPOINT` | R40 | MBIM data session. |
| `KIND_DISPLAY_TIMELINE` | `KIND_HW_TIMELINE` | G1 | Display-engine timeline. |
| `KIND_VRR_RANGE` | `KIND_DISPLAY_MODE` | G1 | VRR range descriptor. |
| `KIND_SCANOUT_LEASE` | `KIND_DISPLAY_PLANE` | G2 | Linear direct-scanout lease. |
| `KIND_VK_SURFACE` | `KIND_IPC_ENDPOINT` | G3 | Vulkan surface. |
| `KIND_VK_SWAPCHAIN_IMAGE` | `KIND_GPU_BO` | G3 | Linear swapchain image. |
| `KIND_VELLO_SCENE` | `KIND_GPU_BO` | G4 | Encoded Vello scene buffer. |
| `KIND_VELLO_RENDERER` | `KIND_GPU_CONTEXT` | G4 | Vello renderer instance. |
| `KIND_FONT_ATLAS` | `KIND_GPU_BO` | G5 | SDF font atlas. |
| `KIND_TEXT_SHAPE` | `KIND_MEMORY` | G5 | Shaped text run. |
| `KIND_COLOR_PROFILE` | `KIND_MEMORY` | G6 | CICP + optional ICC. |
| `KIND_HDR_METADATA` | `KIND_MEMORY` | G6 | HDR mastering metadata. |
| `KIND_TONEMAP_LUT` | `KIND_GPU_BO` | G6 | Tone-map lookup table. |
| `KIND_SURFACE` | `KIND_IPC_ENDPOINT` | G7 | Compositor surface. |
| `KIND_SURFACE_COMMIT` | `KIND_IPC_ENDPOINT` | G7 | Linear atomic surface commit. |
| `KIND_WINDOW` | `KIND_SURFACE` | G7 | Toplevel window role. |
| `KIND_LAYER_TREE` | `KIND_IPC_ENDPOINT` | G7 | Subsurface hierarchy. |
| `KIND_INPUT_ROUTE` | `KIND_IPC_ENDPOINT` | G8 | Linear routing entry. |
| `KIND_SEAT` | `KIND_IPC_ENDPOINT` | G8 | Multi-seat abstraction. |
| `KIND_WORKSPACE` | `KIND_IPC_ENDPOINT` | G9 | Workspace container. |
| `KIND_DAMAGE_REGION` | `KIND_MEMORY` | G9 | Damage rects. |
| `KIND_PRESENT_FEEDBACK` | `KIND_IPC_ENDPOINT` | G9 | Presentation-time feedback stream. |
| `KIND_A11Y_TREE` | `KIND_IPC_ENDPOINT` | G10 | Accessibility tree. |
| `KIND_A11Y_NODE` | `KIND_MEMORY` | G10 | Individual node. |
| `KIND_IME_SESSION` | `KIND_IPC_ENDPOINT` | G11 | Linear IME session. |
| `KIND_IME_PROVIDER` | `KIND_DEVICE` | G11 | IME provider. |
| `KIND_UI_CONTEXT` | `KIND_IPC_ENDPOINT` | G12 | Toolkit context. |

**Total: 78 new derived kinds.** All fit within the CAP-Q3 two-tier model (kernel sees only base kind; type system distinguishes derived).

### 5.3 New stdlib traits (paideia-as)

Every stdlib trait corresponds to a schema plus the effect row a client needs to consume it.

- `HasIrqEndpoint` — driver requirement.
- `HasDmaDomain` — DMA-capable driver requirement.
- `HasTimeline<T:TimelineKind>` — trait constraining "carries a timeline of kind T"; used pervasively.
- `PcmProducer`, `PcmConsumer` — audio graph roles.
- `SurfaceProducer<F:PixelFormat, C:ColorSpace>` — the compositor client trait.
- `ColorProfileAware` — trait for buffer-carrying schemas that must not lose color info.
- `HidReportSource` — HID transport driver trait.
- `A11yProvider` — apps' a11y publishing trait.
- `SchemaVersioned<V>` — every schema declares an evolution axis.
- `LinearlyMovable`, `AffinelyDroppable`, `OrderedConsumed` — three substructural marker traits (already implicit; make explicit for elaborator use).

### 5.4 New IPC schemas summary

The new schemas total **~50** (each `KIND_*_CHANNEL` and every service-supervisor RPC surface). Full enumeration in §5.2 by-round. Every schema is a `Channel(Schema)` functor application (per IPC-Q5).

### 5.5 Effect-row additions

New effects registered in the paideia-as effect vocabulary:

`!{irq_install, irq_mask, irq_route, dma_map, dma_unmap, hw_timeline_wait, hw_timeline_signal, aml_evaluate, aml_notify, op_region_access, i2c_write, i2c_read, gpio_set, gpio_get, ec_read, ec_write, thermal_read, thermal_trip, battery_read, backlight_set, hid_recv, sensor_read, gpu_submit, gpu_wait, gpu_alloc, gpu_free, display_modeset, display_present, scanout_lease_grant, scanout_lease_revoke, wifi_scan, wifi_connect, wifi_key_use, bt_pair, bt_gatt_read, bt_gatt_write, biometric_capture, biometric_verify, camera_capture, wwan_connect, wwan_send, color_convert, tonemap_apply, hdr_present, ime_activate, ime_compose, ime_commit, a11y_subscribe, a11y_action_invoke, present_feedback_recv, dma_consent_grant, dma_consent_revoke}`

Each effect maps to a rights bit on the corresponding kind's rights bitmask; the mapping is a compile-time lookup via `rights_to_effects` (from CAP-Q4).

---

## 6. Sequencing rationale

### 6.1 Serial dependencies (must-follow)

```
R29 (framework maturation)
  ↓
R30 (ACPICA) ────────────────────────────┐
  ↓                                       │
R31 (EC/thermal/battery/backlight)       │
  ↓                                       │
R32 (I²C-HID + sensors)                  │
                                          │
R30.M5 (LPSS I²C) ────────────────────────┘
  (needed by R32.M1 and R31.M6)

R34 (USB fabric) needs R26 (from MVP) — parallel-safe with R30–R33 once R29 lands
  ↓
R34.M6 (fingerprint) needs R34.M4 (USB-HID full protocol)

R35 (TB4/PCIe hotplug) needs R22 (from MVP) + R29 + R34
  (external devices hang off TB4)

R36 (display substrate) needs R22 (PCIe) + R29 (framework)
  ↓
R37 (GPU exec) needs R36
  ↓
G1 (compositor: display substrate) needs R37
  ↓
G2 (direct scanout)  ┐
G3 (Vulkan surface)  ├── all need G1 + R37
G4 (Vello 2D)        │
G5 (SDF text)        │
G6 (color mgmt)      ┘
  ↓
G7 (compositor protocol) needs G1–G6
  ↓
G8 (input routing)      ┐
G9 (windowing+feedback) ├── need G7
G10 (a11y)              │
G11 (IME)               │
G12 (toolkit)           ┘

R38 (Wi-Fi) — depends only on R29 + R22; parallel-safe with R30–R37, G1–G4
R39 (Bluetooth) — depends on R38 (CNVi shared PHY) + R33 (audio bridge for A2DP)
R40 (camera + WWAN) — depends on R37 (camera uses KIND_GPU_BO)
```

### 6.2 Parallelizable rounds

- R30 + R34: no shared prerequisites past R29.
- R33 + R35: audio bring-up independent of TB4/PCIe hotplug work.
- R36 + R38: display and Wi-Fi bring-up parallel.
- G4 (Vello 2D) + G5 (SDF text) + G6 (color): can run in parallel with three separate implementer teams once G1 lands.
- G10 (a11y) + G11 (IME): parallel after G7.

### 6.3 Recommended calendar (assuming 4–6 wk/round tempo)

- **Months 0–6:** R29, R30, R31 (serial). R34 in parallel with R30 (weeks 4–12).
- **Months 6–10:** R32, R33 (serial); R38 in parallel (Wi-Fi).
- **Months 10–14:** R35, R36; R39 in parallel (Bluetooth).
- **Months 14–20:** R37 (big); G1 kicks off at R37 midpoint.
- **Months 18–24:** G2, G3, G4 in parallel; R40.
- **Months 22–30:** G5, G6, G7; G8, G9 finish.
- **Months 28–34:** G10, G11, G12; hardening.

### 6.4 The critical path is R29 → R37 → G7

Every architectural commitment that "locks us in" for a decade sits on this path. Every round on this path deserves double review effort. R30, R33, R38, R39 can be re-architected later without breaking the *rest of the OS*; not so R29 (capability grammar), R37 (GPU submission ABI), or G7 (compositor protocol).

---

## 7. Cross-repo dependencies on paideia-as

Every round below has a corresponding `paideia-as` bundle. Filed as blocker milestones in the paideia-as repo per `feedback_cross_repo_escalation.md`.

### 7.1 v0.25 — Session-typed functor bundle (R29 gate)

- **Functor signatures with session types** — per `wait-free-dataflow.md` IPC-Q5, first-class syntax for `signature X = protocol : SessionType !{…}`.
- **Effect-row inference at call sites** — the elaborator must compute the union of caller's + callee's effect rows.
- **Linear-cap consumption verification in `unsafe` blocks** — an `unsafe` block that receives a linear cap must document its consumption path.
- **Derived-kind derivation macro `@derive(base, refinement)`** — enables `KIND_INTERRUPT`, `KIND_MSIX_VECTOR` etc.
- ~4 weeks of paideia-as work.

### 7.2 v0.26 — AML interpreter substrate (R30 gate)

- **Recursive descent parsing helpers in stdlib** — the AML parser will use them.
- **Arbitrary-precision integer intrinsics** — AML uses 64-bit; `@mulu64`, `@divu64` sugar.
- **String interning** — AML pathnames.
- **A stable `Result<T,E>` idiom** — every AML op returns Result.
- ~3 weeks.

### 7.3 v0.27 — DMA + timeline primitives (R33 + R37 gate)

- **`@dma_buffer(size, alignment, coherency)` intrinsic** — allocates a DMA-coherent buffer and mints `KIND_DMA_DOMAIN`.
- **`@timeline_wait(cap, value, timeout_ns) -> Result<u64, Timeout>`** — first-class syntax for hardware timeline waits.
- **`@timeline_signal(cap, value)`** — first-class signal.
- **128-bit atomic CAS** — needed for wait-free timeline update loops.
- **`@include_bytes_signed(path, keyring)`** — for signed firmware blobs (GuC, iwlwifi FW, SOF).
- ~4 weeks.

### 7.4 v0.28 — GPU submission substrate (R37 gate)

- **`@gpu_context(engine)` block** — a syntactic form that constrains everything in scope to hold a `KIND_GPU_CONTEXT`.
- **`vec<T,N>` type parameterized** — for MMIO command buffer building.
- **`@endian(be|le)` conversion attribute on struct fields** — GPU command formats.
- **`@packed_struct` full support** — command TRBs / batch buffer commands.
- ~3 weeks.

### 7.5 v0.29 — Compositor protocol substrate (G7 gate)

- **Row-polymorphic effects** — critical for the compositor's "each surface commit carries a subset of effect row" pattern.
- **Handler composition (`handle E1 ∘ handle E2`)** — for compositor + a11y + IME layering.
- **Session-type recursion with well-founded induction** — the compositor protocol is recursive (nested subsurfaces).
- ~4 weeks.

### 7.6 v0.30 — Vulkan surface + SPIR-V embedding (G3 + G4 gate)

- **`@spirv_module(path)` — embed SPIR-V binaries as `Cap<KIND_MEMORY>` symbols.**
- **`@wgsl_module(path)` — same for WGSL sources (Vello uses WGSL).**
- **First-class `f16` / `f32` / `f64` intrinsics for Vello encoder.**
- ~3 weeks.

### 7.7 v0.31 — HDR + color primitives (G6 gate)

- **`@fixed_point(bits_int, bits_frac)` type modifier** — CIE XYZ conversions.
- **A `Matrix<T,R,C>` stdlib type + intrinsics** — color-conversion matrix multiplication.
- **CICP-tagged image-encoding helpers** — as stdlib module.
- ~2 weeks.

### 7.8 v0.32 — A11y + IME + toolkit substrate (G10–G12 gate)

- **Trees with generational indices in stdlib** — a11y tree, widget tree.
- **Row-based subtyping for `KIND_A11Y_NODE` polymorphism.**
- **`@retain` and `@immediate` attributes on functor signatures** — toolkit's dual-mode support.
- ~3 weeks.

### 7.9 Total paideia-as work

~26 weeks (~6 months) of language work distributed across the wave. Following `feedback_paideia_as_version_discipline.md`, each bundle is closed with workspace-version bump + git tag + CHANGELOG entry.

---

## 8. Risk register

Top ten risks, in decreasing "expected damage × probability" order.

### R1 — Compositor protocol calcification

**Damage:** irrecoverable. Once apps ship against `KIND_SURFACE`/`KIND_WINDOW`/`KIND_SURFACE_COMMIT`, every schema field is load-bearing forever. Wayland-shape mistakes (implicit sync, per-compositor extensions) cost decades. **Probability:** high without discipline.

**Mitigation:** G7 gets a dedicated 3-week protocol-freeze design review *before* any code is written; three external reviewers (from Fuchsia, Wayland, and Zed teams if reachable) approve the schema before commit; a written non-goals document forbids the extension model.

### R2 — GPU driver quality gap

**Damage:** if the Iris Xe execution engine driver is missing features Vello needs (subgroup ops, storage-image atomics, etc.), G4 slips; without G4, G7 has no rasterizer. **Probability:** medium-high — Intel's iGPU documentation is patchy for Gen12 Xe-LP.

**Mitigation:** feature-flag matrix from R37.M1; a software-rendered `llvmpipe`-equivalent fallback path built at G4 that renders the same encoded scenes on CPU. Vello runs on both from day 1.

### R3 — Timeline primitive shape drift

**Damage:** `KIND_HW_TIMELINE` looked identical across GPU/audio/display in this proposal. If GPU-team and audio-team implement subtly different semantics (monotonic-only vs modular; overflow behavior; wait-any vs wait-all), the compositor's cross-engine sync breaks. **Probability:** medium.

**Mitigation:** `KIND_HW_TIMELINE` gets a TLA+ spec at R29; every derived timeline (`KIND_GPU_TIMELINE`, `KIND_AUDIO_CLOCK`, `KIND_DISPLAY_TIMELINE`) must exhibit a refinement of this spec.

### R4 — ACPICA userspace bubble under-scoped

**Damage:** if the AML interpreter can't handle the Lenovo Insyde/T14 G4 firmware's dialect (obscure operators, vendor extensions), R30 slips indefinitely; every dependent round backs up. **Probability:** medium-high. Real-world DSDT tables are surprising.

**Mitigation:** capture T14 G4 DSDT/SSDT tables early in R30 (before implementation); include a corpus of Linux-verified AML test cases in the tester; keep a "punt to hard-coded platform quirks" fallback ready.

### R5 — Wi-Fi firmware ABI churn

**Damage:** iwlwifi firmware ABI changes across generations; upstream Linux tracks with patches. If our AX211 support only works with one FW version, we lock users into that version. **Probability:** medium.

**Mitigation:** in R38.M1 add a firmware-version compatibility matrix; abstract the FW interaction via `KIND_FW_LOADER` cap so we can support multiple; contribute firmware-format documentation upstream.

### R6 — DMA-attestation UX friction

**Damage:** every external Thunderbolt device needs `KIND_DMA_ATTESTATION` user consent (R35). If the consent dialog is annoying, users will disable; if too permissive, we lose the security we designed for. **Probability:** medium.

**Mitigation:** enroll trusted-device fingerprints at first-consent-grant + user can toggle "always trust this device"; the compositor shows a persistent indicator when DMA is active from an external device.

### R7 — Accessibility as afterthought (again)

**Damage:** if G10 slips or is under-invested, PaideiaOS ships as an unusable-for-blind-users system. Adding a11y post-hoc is 10× the effort of designing it in. **Probability:** medium (typical project failure mode).

**Mitigation:** every G7 schema field has an a11y-implication cell in the review table; G10 lands as *acceptance criterion* on G7 (compositor protocol doesn't freeze until a11y-tree binding is proven).

### R8 — Bluetooth LE Audio evolution

**Damage:** `bluetooth_supervisor` designed around Classic profiles (HFP/A2DP) will need surgery for LE Audio (LC3 + Auracast + BAP/CAP/TMAP). **Probability:** medium.

**Mitigation:** design R39 protocols around Isoch Channels (LE Audio's substrate) from the start; HFP/A2DP become "profiles running over Isoch"; Auracast plugs in.

### R9 — Paideia-as version desync

**Damage:** if paideia-as v0.25–v0.32 slip, everything downstream stalls. This has already been the pattern (STATUS.md shows paideia-as blockers routinely on the critical path). **Probability:** high.

**Mitigation:** file every paideia-as bundle at the start of the round it enables (not at the end); interleave paideia-os / paideia-as work by round; have a "structural stub" path for every driver so bring-up isn't fully gated on encoder completeness.

### R10 — Effect-row explosion in stdlib

**Damage:** 50+ new effects (per §5.5) risks type signatures that no human can read; row-polymorphism helps but doesn't eliminate the cognitive load. **Probability:** medium.

**Mitigation:** enforce a naming convention (`{subsystem}_{verb}`); provide `!{DriverEffects}`, `!{CompositorEffects}`, `!{AudioEffects}` aggregate row aliases; document the top-level effect vocabulary in `design/toolchain/effect-vocabulary.md`.

---

## 9. Suggested milestone titles (GitHub)

Format: `[round-code] [purpose] · [issue count]`

**Axis 1**
- `r29-driver-substrate` — Driver framework maturation + interrupt topology. · 30 issues
- `r30-acpica-bubble` — ACPICA userspace bubble + LPSS I²C/GPIO buses. · 40 issues
- `r31-platform-ec` — EC + thermal + battery + backlight. · 26 issues
- `r32-hid-sensors` — I²C-HID + sensor hub + HID class extension. · 22 issues
- `r33-audio-hda-sof` — HDA + ALC287 + SOF audio path. · 30 issues
- `r34-usb-fabric` — USB hubs + MSC + HID-full + fingerprint. · 28 issues
- `r35-thunderbolt` — TB4/USB4 + PCIe hotplug + DMA-consent flow. · 24 issues
- `r36-display-substrate` — Iris Xe modesetting + display topology. · 18 issues
- `r37-gpu-execution` — Iris Xe execution engine + GuC/HuC. · 36 issues
- `r38-wifi-ax211` — iwlwifi-equivalent + WPA3 supplicant. · 34 issues
- `r39-bluetooth` — Bluetooth HCI + L2CAP + core profiles. · 24 issues
- `r40-camera-wwan` — MIPI-CSI + IPU6 + WWAN + audit consolidation. · 18 issues

**Axis 2**
- `g1-display-sync` — Display substrate + explicit-sync timelines. · 16 issues
- `g2-direct-scanout` — Direct-scanout leases + VRR. · 14 issues
- `g3-vulkan-surface` — VK_paideia_surface + swapchain. · 18 issues
- `g4-vello-2d` — Compute-based 2D rasterization stack. · 16 issues
- `g5-sdf-text` — SDF fonts + fractional scaling + shaping. · 18 issues
- `g6-color-hdr` — Color management + HDR + wide-gamut. · 16 issues
- `g7-compositor-protocol` — Paideia-native compositor protocol (canonical). · 22 issues
- `g8-input-routing` — Per-device input routing (compositor-adjacent). · 14 issues
- `g9-windowing-feedback` — Windowing + damage + presentation feedback. · 14 issues
- `g10-accessibility` — Accessibility hooks in surface protocol. · 12 issues
- `g11-ime` — Unified IME (Latin/CJK/RTL). · 12 issues
- `g12-toolkit` — Developer APIs + first-party toolkit `libpaideia-ui`. · 14 issues

**Cross-cutting (paideia-as)**
- `paideia-as-v0.25-session-functors` — Session-typed functor signatures.
- `paideia-as-v0.26-aml-substrate` — AML-parsing helpers.
- `paideia-as-v0.27-dma-timeline` — DMA + timeline intrinsics.
- `paideia-as-v0.28-gpu-substrate` — GPU submission substrate.
- `paideia-as-v0.29-compositor-substrate` — Row-polymorphic effects for compositor.
- `paideia-as-v0.30-vulkan-spirv` — SPIR-V embedding + Vulkan interop.
- `paideia-as-v0.31-color-hdr` — Fixed-point + color-matrix primitives.
- `paideia-as-v0.32-a11y-toolkit` — Trees + a11y + toolkit substrate.

---

## 10. Closing architectural note

The MVP proved the microkernel + capability + IPC substrate. This wave's job is to prove **the same substrate scales to the surface area of a full-featured desktop OS** — 78 new derived kinds, 50 new schemas, 50 new effects — without introducing a single new base kind, without a single hidden global, without a single un-audited MMIO poke.

If we succeed, every subsequent piece of hardware or feature is *another handful of derived kinds and schemas* — never a new mechanism. That is the payoff for the discipline of R1–R28.

If we fail, we will notice not because tests fall over but because the schema diagrams start needing "extension X" boxes glued on the side. That is the signal to stop, revisit the base capability, and redesign — never to ship an extension.

Every round below has been checked against this rule. None of them, as designed, introduce an extension. Each of them either (a) uses an existing base kind with a new derivation, (b) uses a new session-typed IPC schema, or (c) adds an effect that maps into an existing rights-bit catalogue slot.

If synthesis with osarch's proposal reveals any round that violates this rule, that round is the top priority for redesign — before commit.

---

*End of softarch next-wave roadmap.*
