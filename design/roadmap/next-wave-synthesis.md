# PaideiaOS Next-Wave Roadmap — Synthesis

**Status:** Canonical unified proposal, merging `next-wave-osarch.md` (766 lines, systems-architecture voice) and `next-wave-softarch.md` (1170 lines, software-architecture voice).
**Date:** 2026-08-11.
**Vantage:** Post-`mvp-v0.1` (paideia-os commit `836ec0d`; paideia-as commit `cdbf779`).
**Scope:** R29–R40 (driver axis) + G1–G12 (GUI axis) — **24 milestones, ~500 issues, ~15–22 months** at continuous-loop tempo. Both agents reached agreement on all architectural commitments; disagreements are procedural (numbering, sequencing granularity) and resolved below.

---

## 0. Reconciliation summary

| Dimension | osarch (systems) | softarch (software) | **Synthesis decision** |
|---|---|---|---|
| Numbering | R29–R43 (single axis, GUI slots interleaved) | R29–R40 driver + G1–G12 GUI (two axes) | **Adopt softarch's two-axis scheme.** Cleaner separation; the "R34 is display, R37 is Vulkan" osarch overload was confusing. |
| ACPICA slot | R29 (leftmost) | R30 (after R29 driver-substrate maturation) | **Adopt softarch's R30.** R29 as driver-substrate hardening (interrupt topology, DMA domain caps, lifecycle FSM) makes ACPICA cleaner. |
| Wi-Fi/BT/Camera | R41/R41/R43 (postponed) | R38/R39/R40 (earlier) | **Adopt softarch's earlier placement.** MVP closed; no schedule reason to defer. |
| Capability catalogue | Prose only | 78 new derived kinds enumerated | **Adopt softarch's catalogue.** Concrete for issue filing. |
| Pitfall register | 10-row table with layer + invariant | Bullet list per round | **Adopt osarch's table** (§3.0 of osarch). Better for compositor-review checklist. |
| Layer names | paideia-drm, paideia-gem, paideia-vk, paideia-vello | G1-G12 (numeric) | **Both.** Layer names in prose; G-numbers as milestone slugs. |
| Cross-repo bundles | 7 paideia-as bundles (v0.25–v0.31) | 8 bundles (v0.25–v0.32) | **Adopt softarch's 8.** Extra bundle (v0.32 a11y+toolkit) is real work. |
| Wall-clock | 15–22 months, 12–15 with parallelism | 30 months serial calendar | **Osarch's 15–22 months.** Softarch's is a Gantt chart, not a promise. |
| Risk register | Firmware blobs, CNVi docs, SPIR-V lowering, TB4 security, ACPI perf | Compositor calcification, GPU gaps, timeline shape drift, a11y afterthought, effect explosion | **Merge both — 15-row register in §7.** |

**Where they fully agree** (no synthesis needed):
- ACPICA userspace bubble is the single largest unlock.
- Blob-driver capability policy must close before Wi-Fi + camera bring-up.
- Explicit-sync timelines (drm-syncobj shape) are the only sync primitive from day one.
- Compositor cannot own the input path.
- HDR + wide-gamut + ICC + fractional scaling designed in from R36/G6, not bolted on.
- Compute-based 2D (Vello lineage) instead of triangle-based.
- SDF text (Slug lineage) with GPU-side subpixel positioning.
- Single coherent PWP/`CompositorSchema` protocol, no `wp-`/`ext-` fragmentation.
- Accessibility as first-class in the surface protocol (AccessKit-shape tree).
- Unified IME (Latin + CJK + RTL + Indic) as one session-typed schema.
- Presentation-time feedback loop is mandatory and typed, not opt-in.
- Direct-scanout is the *default* for fullscreen clients, not an opt-in.
- Every paideia-as bundle files at round-open, not round-close (avoid the pattern of "waiting on encoder").

---

## 1. Executive summary (600 words)

Post-MVP, PaideiaOS has 24 rounds of work to reach a daily-driver Thinkpad T14 G4 with a paideia-native GPU-accelerated GUI. Twelve rounds (R29–R40) exhaust laptop hardware; twelve (G1–G12) build the compositor stack. All 24 land within a single architectural regime: every subsystem is a `KIND_*` derived capability + one session-typed IPC schema + one effect-row declaration; nothing is a global, nothing is an extension protocol, nothing skips accessibility, and nothing takes an implicit sync path.

**Critical path: R29 → R30 → R37 → G7.** Every commitment that locks-us-in-for-a-decade sits on this path. R29 sets the capability grammar (KIND_INTERRUPT, KIND_DMA_DOMAIN, KIND_HW_TIMELINE); R30 lands ACPICA + LPSS buses (the "unlock" for everything laptop-shaped); R37 sets the GPU submission ABI; G7 freezes the compositor protocol. Every round on this path deserves double review effort. The remaining 20 rounds are individually re-architectable if we discover we were wrong.

**Two dominant commitments unifying both proposals:**

1. **Every hardware clock domain crossing carries a `KIND_HW_TIMELINE` capability.** GPU→display, GPU→GPU, GPU→CPU, audio-mclk→CPU, USB-SOF→isoch endpoint, network-PTP→application — all use the same timeline shape. This is the drm-syncobj lesson generalized. It structurally forecloses the entire "implicit fence → race → flicker" bug class that plagued Wayland-on-NVIDIA and every OS that touched HDR retrofits.

2. **The compositor is one of three separately-restartable services in the display subsystem** (compositor + input server + recovery console). A compositor lockup can never kill the input path or the recovery console — the reserved-plane invariant on pipe 0 guarantees that if the compositor dies, `safectl` still renders and the user still types. This is Pillar 6 taken seriously.

**GUI research grounding.** The compositor design cites (verified) piet-gpu/Vello (Levien, 2020–2024 — the "sort-middle 2D architecture" writeup), Slug SDF text (Lengyel, JCGT 2017), Vulkan `VK_KHR_timeline_semaphore`, `VK_EXT_swapchain_maintenance1`, drm-syncobj (König, AMD 2017), Chromium Viz architecture, Fuchsia Scenic, Wayland's `wp_presentation` + `wp_linux_drm_syncobj_manager_v1`, ITU-R BT.2100 for HDR, and AccessKit for the a11y tree shape. Prior compositor mistakes we structurally avoid: X's server-side input state, Wayland's implicit dmabuf sync, GNOME's integer-scale-then-downsample, macOS's HDR retrofit, Windows' HDR-shipped-before-apps-could-opt-in, and the wlroots-vs-GNOME `ext-*` vs `wp-*` fragmentation.

**T14 G4 driver strategy.** Every driver runs in userspace as its own process, holds narrow capabilities (per-vector IRQ + per-device IOMMU domain + per-endpoint MMIO), and is separately-restartable. Blob-driver policy (Wi-Fi UMAC firmware, IPU6 firmware, GuC firmware, Intel BT firmware) closes at R29 before any driver that consumes a blob boots; blob drivers hold a distinct `blob_driver_cap` with no audit-write, dedicated IOMMU domain, and signature-verified load. Thunderbolt 4 is architected as the archetypal hot-plug bus with per-dock capability-scoping; a compromised device on a dock cannot IOMMU-attack the host or a sibling dock.

**Total scope:** ~500 issues across 24 milestones, ~15–22 months wall-clock at continuous-loop tempo, 8 paideia-as version bundles (v0.25–v0.32) interleaved.

---

## 2. Unified milestone catalogue

Every milestone below carries the accepted round code, purpose, issue count, dependency arrows, and headline capability introductions. Sources merged from both agents.

### Axis 1 — T14 G4 driver coverage (R29–R40)

| Round | Slug | Purpose | Issues | Depends on | Headline caps introduced |
|---|---|---|---:|---|---|
| **R29** | `r29-driver-substrate` | Driver framework maturation, interrupt topology, DMA domain caps, lifecycle FSM real bodies, driver registry v2 (signed), audit surface, chaos-restart | 30 | R28 MVP | `KIND_INTERRUPT`, `KIND_MSIX_VECTOR`, `KIND_DMA_DOMAIN`, `KIND_HW_TIMELINE` |
| **R30** | `r30-acpica-lpss` | ACPICA userspace bubble + AML interpreter + LPSS I²C/GPIO enumeration + EC OpRegion | 40 | R29, R22 (ECAM), R20 (ACPI table walk) | `KIND_AML_SESSION`, `KIND_OP_REGION`, `KIND_I2C_BUS`, `KIND_I2C_SLAVE`, `KIND_GPIO_LINE` |
| **R31** | `r31-platform-ec` | EC driver + battery + AC + thermal zones + fan/cooling + backlight (PWM + DP-AUX) + hotkeys + lid + power button + accelerometer/ambient sensors + ThinkPad HKEY | 26 | R30 | `KIND_EC_QUERY`, `KIND_THERMAL_ZONE`, `KIND_COOLING_DEVICE`, `KIND_BATTERY`, `KIND_BACKLIGHT` |
| **R32** | `r32-hid-sensors` | I²C-HID transport + HID report-descriptor compiler + unified `KIND_HID_EVENT` stream + Synaptics/ELAN touchpad + TrackPoint I²C-HID tunnel + sensor hub + gesture recognizer | 22 | R30 (LPSS I²C), R26 (HID core from MVP) | `KIND_HID_DEVICE`, `KIND_HID_EVENT`, `KIND_SENSOR_CHANNEL` |
| **R33** | `r33-audio-hda-sof` | HDA controller + ALC287 codec + widget-graph traversal + `KIND_PCM_STREAM` + `KIND_AUDIO_CLOCK` (first non-GPU timeline consumer) + audio_supervisor + optional SOF firmware loader + jack detect | 30 | R30 (ACPI SST), R22 (MSI-X), R29 (timeline substrate) | `KIND_AUDIO_CONTROLLER`, `KIND_PCM_STREAM`, `KIND_AUDIO_CLOCK`, `KIND_AUDIO_ROUTE` |
| **R34** | `r34-usb-fabric` | USB hub cascading + mass-storage (BOT/UAS) + full USB-HID (beyond boot proto) + fingerprint (Goodix/Synaptics) + isoch stream substrate | 28 | R26 (xHCI from MVP) | `KIND_USB_HUB`, `KIND_USB_INTERFACE`, `KIND_USB_ENDPOINT`, `KIND_ISOCH_STREAM`, `KIND_FP_SENSOR` |
| **R35** | `r35-thunderbolt` | TB4/USB4 on-die NHI + Connection Manager + tunneling (PCIe/DP/USB3) + per-dock IOMMU domain + `KIND_DMA_ATTESTATION` user-consent flow + security-level policy | 24 | R22 (VT-d+IR), R26 (xHCI), R29 (framework), R30 (ACPI PCH TBT) | `KIND_TB_DOMAIN`, `KIND_TB_ROUTE`, `KIND_PCIE_HOTPLUG_EVENT`, `KIND_DMA_ATTESTATION` |
| **R36** | `r36-display-substrate` | Iris Xe Gen12 display engine: MMIO + CDCLK + pipes + planes + transcoders + DDIs (eDP + HDMI + DP-alt) + atomic modeset + hotplug + PSR2 | 18 | R22 (PCIe), R29 (framework) | `KIND_DISPLAY_ENGINE`, `KIND_DISPLAY_OUTPUT`, `KIND_DISPLAY_MODE`, `KIND_DISPLAY_PLANE`, `KIND_MODESET_TXN` |
| **R37** | `r37-gpu-execution` | Iris Xe Gen12 render/blitter/video engines: GT reset + GTT/PPGTT + BO allocator + LRC per engine + execlists + GuC firmware + HuC + hang detect + per-engine reset | 36 | R36 | `KIND_GPU_BO`, `KIND_GPU_VM`, `KIND_GPU_CONTEXT`, `KIND_GPU_TIMELINE`, `KIND_GPU_SUBMIT` |
| **R38** | `r38-wifi-ax211` | Intel AX211 (CNVi transport) + iwlwifi-equivalent MVM/UMAC blob loader + 802.11 MAC state machine + WPA3-SAE + 802.11ax HE-MCS + rate control + regulatory | 34 | R32 (crypto), R29 (framework), blob-policy | `KIND_WIFI_PHY`, `KIND_WIFI_VIF`, `KIND_WIFI_KEY` (sealed), `KIND_WIFI_SCAN_TXN` |
| **R39** | `r39-bluetooth` | Bluetooth HCI over Intel CNVi + L2CAP + ATT/GATT + LE Secure Connections pairing + A2DP (bridges to R33 audio) + HFP + HID over BT + LE Audio (BAP/CAP) | 24 | R38 (shared CNVi PHY), R33 (audio bridge), R34 (BT isoch) | `KIND_BT_ADAPTER`, `KIND_BT_HCI_CHANNEL`, `KIND_BT_L2CAP_CHANNEL`, `KIND_BT_GATT_CONNECTION`, `KIND_BT_PAIRING` (sealed) |
| **R40** | `r40-camera-wwan` | MIPI-CSI + Intel IPU6 (firmware blob) + camera server + WWAN M.2 (MBIM/QMI over USB) + fingerprint UX + camera privacy shutter + audit-schema unification | 18 | R37 (GPU BO for zero-copy frames), R32 (fingerprint sealing) | `KIND_CSI_CAMERA`, `KIND_IPU6_STREAM`, `KIND_WWAN_MODEM`, `KIND_MBIM_SESSION` |

**Axis 1 subtotal: 330 issues across 12 milestones.**

### Axis 2 — GPU-native GUI (G1–G12, interleaved from R37 midpoint)

| Round | Slug | Purpose | Issues | Depends on | Headline caps introduced |
|---|---|---|---:|---|---|
| **G1** | `g1-display-sync` | Display substrate + `KIND_DISPLAY_TIMELINE` explicit-sync primitive (drm-syncobj shape) + VRR probe | 16 | R37 | `KIND_DISPLAY_TIMELINE`, `KIND_VRR_RANGE` |
| **G2** | `g2-direct-scanout` | Direct-scanout `KIND_SCANOUT_LEASE` (linear) + tearing-free VRR + Steam-Deck-style fullscreen bypass | 14 | G1 | `KIND_SCANOUT_LEASE` |
| **G3** | `g3-vulkan-surface` | Vulkan 1.3 loader + SPIR-V reader + `VK_paideia_surface` extension + dual-timeline swapchain (acquire on GPU-timeline, release on display-timeline) + present-time feedback | 18 | G1, R37 | `KIND_VK_SURFACE`, `KIND_VK_SWAPCHAIN_IMAGE` |
| **G4** | `g4-vello-2d` | Compute-based 2D rasterization (Vello sort-middle): path IR + Bezier flattening + per-tile scanline blend + gradient/blur compute passes | 16 | G3 | `KIND_VELLO_SCENE`, `KIND_VELLO_RENDERER` |
| **G5** | `g5-sdf-text` | SDF font pipeline (Slug analytic bands + MSDF fallback) + subpixel positioning at render time + HarfBuzz-equivalent shaping + BiDi + Indic + color emoji (COLR/CPAL/SBIX/CBDT) | 18 | G4 | `KIND_FONT_ATLAS`, `KIND_TEXT_SHAPE` |
| **G6** | `g6-color-hdr` | CICP-tagged `KIND_COLOR_PROFILE` + ICC v4 parse + scRGB-linear composition space + HDR10/HLG/DV output transforms + tone-mapping LUTs + reference-display metadata | 16 | G3 | `KIND_COLOR_PROFILE`, `KIND_HDR_METADATA`, `KIND_TONEMAP_LUT` |
| **G7** | `g7-compositor-protocol` | Paideia-native compositor protocol (PWP): `KIND_SURFACE` + `KIND_SURFACE_COMMIT` (linear) + `KIND_WINDOW` + `KIND_LAYER_TREE` + XDG-shell-equivalent + DnD/clipboard as sealed cap flow | 22 | G1–G6 | `KIND_SURFACE`, `KIND_SURFACE_COMMIT`, `KIND_WINDOW`, `KIND_LAYER_TREE` |
| **G8** | `g8-input-routing` | Compositor-adjacent input server + `KIND_INPUT_ROUTE` (linear) + per-device pointer accel + multi-touch/stylus/gesture routing + multi-seat | 14 | G7, R32 (HID stream), R31 (hotkeys) | `KIND_INPUT_ROUTE`, `KIND_SEAT` |
| **G9** | `g9-windowing-feedback` | Workspaces + tiling + damage tracking with buffer-age + `KIND_PRESENT_FEEDBACK` stream + client-side adaptive-rate example | 14 | G7 | `KIND_WORKSPACE`, `KIND_DAMAGE_REGION`, `KIND_PRESENT_FEEDBACK` |
| **G10** | `g10-accessibility` | `KIND_A11Y_TREE` bound at window creation (AccessKit-shape) + screen-reader client protocol + keyboard-nav as compositor concept | 12 | G7 | `KIND_A11Y_TREE`, `KIND_A11Y_NODE` |
| **G11** | `g11-ime` | Unified IME: `KIND_IME_SESSION` (linear) + Latin autocomplete + Pinyin + Zhuyin + Kana + Hangul + Indic complex + BiDi integration with G5 | 12 | G5, G7 | `KIND_IME_SESSION`, `KIND_IME_PROVIDER` |
| **G12** | `g12-toolkit` | First-party `libpaideia-ui` toolkit (immediate + retained modes, egui/Xilem shape) + sample apps (settings, clock, text editor) | 14 | G7–G11 | `KIND_UI_CONTEXT` |

**Axis 2 subtotal: 186 issues across 12 milestones.**

**Grand total: 516 issues across 24 milestones.** (Osarch estimated ~440; softarch ~516; adopt the higher estimate — better to over-file and consolidate than under-file and lose scope.)

---

## 3. Layer naming (osarch's contribution)

The compositor stack has both a G-number (milestone) and a component name (layer):

```
┌──────────────────────────────────────────────────────┐
│  Applications + libpaideia-ui toolkit (G12)          │
└─────────────┬────────────────────────────────────────┘
              │ paideia-window-protocol (PWP)  — G7
              ▼
┌──────────────────────────────────────────────────────┐
│  paideia-compositor  (G7)                            │
│  render graph · damage · direct-scanout · HDR/ICC    │
└──┬────────────────────────────┬──────────────────────┘
   │                            │
   ▼                            ▼
┌────────────────┐   ┌─────────────────────────┐
│ paideia-vello  │   │ paideia-input           │
│ compute-2D+SDF │   │ (compositor-INDEPENDENT)│  — G8
│ (G4+G5)        │   │ HID/I²C-HID/touch/TB4   │
└───┬────────────┘   └─────────────────────────┘
    │ SPIR-V + timeline
    ▼
┌──────────────────────────────────────────────────────┐
│  paideia-vk  (G3, G6)                                │
│  Vulkan-native, Iris Xe Gen12; ICC-aware compositing │
└───┬──────────────────────────────────────────────────┘
    ▼
┌──────────────────────────────────────────────────────┐
│  paideia-gem  (R37)                                  │
│  GPU memory + command streamer                       │
└───┬──────────────────────────────────────────────────┘
    ▼
┌──────────────────────────────────────────────────────┐
│  paideia-drm  (R36, G1, G2)                          │
│  KMS-equivalent display engine                       │
└──────────────────────────────────────────────────────┘
```

Layer names appear in prose + design docs; G-numbers appear in milestone slugs + issue references.

---

## 4. Pitfall register (osarch's §3.0 table, adopted as canonical)

Every pitfall becomes an invariant enforced at a specific layer. Every G-round has an acceptance criterion tied to at least one of these.

| # | Pitfall | Layer | Invariant | Round |
|---|---|---|---|---|
| **P1** | Implicit dmabuf sync (NVIDIA-on-Wayland flicker class) | paideia-vk, PWP | Timelines only; every buffer handoff carries `(timeline_id, value)` wait+signal. **No implicit fallback.** | G1 |
| **P2** | Compositor hang kills input | paideia-input | Input server is compositor-independent; holds its own recovery-console cap; can render emergency framebuffer if compositor dies. | G8 |
| **P3** | Fractional scaling by supersample (GNOME 9-year legacy) | paideia-vk + PWP | Scale factor is a first-class geometry parameter; clients render at target pixel grid; compositor never downsamples an oversampled surface. | G3, G7 |
| **P4** | Accessibility as sidecar (X AT-SPI bus) | PWP | Every window advertises a11y subtree as part of wire protocol; screen reader is a first-class PWP client, not a side-channel. | G10 |
| **P5** | HDR as retrofit (Windows/macOS lessons) | paideia-drm + compositor | Composition space is scRGB-linear (fp16); output transform is display-engine LUT + shader per output; ICC v4 mandatory. | G6 |
| **P6** | Input latency drift | compositor + PWP | Every present carries `(target_time, actual_time, refresh_period)` back to client; compositor budgets one refresh, not two. | G9 |
| **P7** | VRR + fullscreen tearing regressions | paideia-drm | Direct-scanout with VRR-safe cadence is the **default** for fullscreen clients, not an opt-in. | G2 |
| **P8** | Compositor-locked recovery | paideia-drm | Recovery console has reserved plane on primary pipe; compositor cannot claim it. | G7 (design) + G2 (enforcement) |
| **P9** | Font-rendering blur under scale | paideia-vello | SDF glyphs with subpixel positioning at render time; no glyph atlas caching keyed on integer positions. | G5 |
| **P10** | Fragmented IME (IBus/fcitx/scim; Wayland `text-input-v3` slowness) | PWP | One IME protocol, one keyboard-event contract, one text-input surface — compositor is exclusive router. | G11 |
| **P11** | Protocol fragmentation ("core + 200 extensions") | PWP | Single coherent protocol; new capabilities are minor version bumps, never sidecar `ext-*` protocols. Written no-extension policy at G7. | G7 |
| **P12** | Firmware blob denial (AX211 UMAC, IPU6, GuC) | driver framework | Blob-driver capability policy closes before R38+R40; blob drivers hold `blob_driver_cap` (no audit-write, dedicated IOMMU domain, PQ-signed load). | R29 (policy) + R38, R40 (consumers) |
| **P13** | Vendor-tunnel drift (TB4 dock IOMMU attack) | R35 | Per-dock IOMMU domain default; DMA-consent flow gated by user-facing dialog; `KIND_DMA_ATTESTATION` cap minted per session. Cite [Thunderclap NDSS 2019]. | R35 |
| **P14** | Base-kind enum overflow | R29 | 16 base kinds frozen; slot 14 reserved for hardware-adjacent derived kinds (INTERRUPT, HW_TIMELINE, DEVICE-adjacent); slot 15 reserved for TDX/confidential-compute. All new kinds are derived. | R29 |
| **P15** | Effect-row explosion | R29+ | 50+ new effects declared per §5.5 of softarch; aggregate `!{DriverEffects}`, `!{CompositorEffects}`, `!{AudioEffects}` row-aliases; `design/toolchain/effect-vocabulary.md` documents the top-level. | R29 |

---

## 5. Capability catalogue (78 new derived kinds, softarch §5.2 adopted)

The full 78-row catalogue is reproduced verbatim from softarch §5.2 (rows R29 through G12) as `design/architecture/next-wave-derived-kinds.md` (to be created as part of R29.M1 issue enumeration). Key totals:

- **Base slots:** 16 frozen; slot 14 opened for hardware-adjacent kinds (`KIND_INTERRUPT`, `KIND_HW_TIMELINE`); slot 15 reserved for TDX (per CAP-Q9 open issue).
- **Derived over `KIND_IPC_ENDPOINT`:** 38 (services + linear-consumed cap flows).
- **Derived over `KIND_MEMORY`:** 15 (typed memory: OpRegion, ColorProfile, DamageRegion, IPU6 frames, sealed keys).
- **Derived over `KIND_DEVICE`:** 18 (hardware devices).
- **Derived over `KIND_HW_TIMELINE`:** 4 (GPU / display / audio / net-PTP).
- **Derived over another derived kind:** 3 (`KIND_MSIX_VECTOR` over `KIND_INTERRUPT`, `KIND_WINDOW` over `KIND_SURFACE`, `KIND_VELLO_RENDERER` over `KIND_GPU_CONTEXT`).

Every schema is a `Channel(SchemaFunctor)` per IPC-Q5 wait-free-dataflow discipline; every effect maps to a rights bit via `rights_to_effects` (CAP-Q4).

---

## 6. Cross-repo paideia-as bundles (softarch's 8 bundles, adopted)

Each bundle closes with workspace-version bump + git tag + CHANGELOG entry per `feedback_paideia_as_version_discipline.md`.

| Bundle | Contents | Gates | Est. weeks |
|---|---|---|---|
| **v0.25 — Session-typed functors** | Functor signatures with session types; effect-row inference at call sites; linear-cap consumption verification in unsafe blocks; `@derive(base, refinement)` macro | R29 | 4 |
| **v0.26 — AML interpreter substrate** | Recursive-descent parsing helpers; arbitrary-precision integer intrinsics (`@mulu64`, `@divu64`); string interning; stable `Result<T,E>` idiom | R30 | 3 |
| **v0.27 — DMA + timeline primitives** | `@dma_buffer(size, alignment, coherency)` intrinsic; `@timeline_wait/signal` first-class syntax; 128-bit atomic CAS; `@include_bytes_signed(path, keyring)` for GuC/iwlwifi/SOF blobs | R33 + R37 | 4 |
| **v0.28 — GPU submission substrate** | `@gpu_context(engine)` scope; `vec<T,N>` type parameterization; `@endian(be|le)` on struct fields; `@packed_struct` full support | R37 | 3 |
| **v0.29 — Compositor protocol substrate** | Row-polymorphic effects; handler composition (`handle E1 ∘ handle E2`); session-type recursion with well-founded induction (for nested subsurfaces) | G7 | 4 |
| **v0.30 — Vulkan + SPIR-V embedding** | `@spirv_module(path)` embeds SPIR-V binaries as `Cap<KIND_MEMORY>` symbols; `@wgsl_module(path)` for Vello's WGSL; first-class `f16`/`f32`/`f64` intrinsics | G3 + G4 | 3 |
| **v0.31 — HDR + color primitives** | `@fixed_point(bits_int, bits_frac)` type modifier; `Matrix<T,R,C>` stdlib type + intrinsics; CICP-tagged image-encoding helpers | G6 | 2 |
| **v0.32 — A11y + IME + toolkit substrate** | Trees with generational indices in stdlib; row-based subtyping for `KIND_A11Y_NODE` polymorphism; `@retain`/`@immediate` attributes on functor signatures | G10–G12 | 3 |

**Total paideia-as work:** ~26 weeks (~6 months) distributed across the wave.

**File-early recommendation:** v0.25 files immediately (blocking R29); v0.26 files with R29 close; v0.27+v0.28 file at R32 close; v0.29+v0.30 file at R36 close; v0.31+v0.32 file at G4 close.

---

## 7. Merged risk register (15 rows)

Ranked by expected damage × probability, both proposals merged:

| # | Risk | Damage | Prob | Mitigation |
|---|---|---|---|---|
| **R1** | Compositor protocol calcification (G7 mistakes cost a decade) | Irrecoverable | High | 3-week protocol-freeze design review before any G7 code; three external reviewers if reachable (Fuchsia/Wayland/Zed); no-extension-protocol written policy; a11y-tree binding is *acceptance* on G7 close. |
| **R2** | ACPICA userspace bubble under-scoped for Lenovo Insyde dialect | Very High (all R31+ blocks) | Med-High | Capture T14 G4 DSDT/SSDT across ≥3 BIOS revisions before R30.M9; unit fixtures per version; Linux-verified AML corpus as regression suite; hard-coded platform-quirk fallback path ready. |
| **R3** | GPU driver quality gap: missing subgroup ops, storage-image atomics, etc. → G4 slips → G7 has no rasterizer | High | Med-High | Feature-flag matrix from R37.M1; software-rendered `llvmpipe`-equivalent fallback for Vello — runs on both from day 1; land vertex+fragment shader path before compute (R37.M4-M5 split). |
| **R4** | SPIR-V → Gen12 EU lowering (R37.M3-equivalent inside G3) is the biggest single milestone; likely under-scoped | High | High | Pre-flight scoping doc at R36 close; land subset of shader capabilities first (vertex + fragment; compute later); compositor can proceed with reduced shader set. |
| **R5** | Firmware blob license terms (IPU6 primarily) incompatible with our redistribution model | Very High (camera indefinitely blocked; possibly Wi-Fi too) | Med | R40 gate 0: procure Intel IPU6 firmware distribution license before scoping the round; if unfavourable, drop IPU6, ship webcam as post-R40 optional module via external USB UVC. Same gate applies to AX211 UMAC and GuC. |
| **R6** | AX211 CNVi under-documented outside Intel; iwlwifi source is our only public reference | High (R38 slips 2–3 months) | High | Buy an M.2 2230 discrete-PCIe Intel AX210 (non-CNVi) as fallback path; retain AX211 as primary target but ship v1 on AX210 topology if AX211 slips. |
| **R7** | Timeline primitive shape drift across GPU/audio/display teams | High (cross-engine sync breaks) | Med | `KIND_HW_TIMELINE` gets a TLA+ spec at R29; every derived timeline (`KIND_GPU_TIMELINE`, `KIND_AUDIO_CLOCK`, `KIND_DISPLAY_TIMELINE`) must exhibit refinement of the base spec. |
| **R8** | Blob-driver capability policy has open questions blocking AX211 + IPU6 | Very High (both R38, R40 blocked) | Med | Close blob-policy design (`design/drivers/blob-policy.md`) before R38 kickoff; resolve: signature keystore, IOMMU-domain granularity, audit-channel policy. |
| **R9** | TB4 PCIe-tunneling exposes hot-plugged devices to arbitrary IOMMU domain choices; wrong policy = security regression | Very High (privilege escalation via malicious dock) | Low-Med | R35 security-level milestone gates entire R35; no PCIe-tunnel without user consent (SL1 min); per-dock IOMMU domain is default (SL2). Cite [Thunderclap NDSS 2019]. |
| **R10** | paideia-as v0.25–v0.32 delivery slips, blocking paideia-os round openings | High (osarch stalls on encoder) | Med-High | File paideia-as bundles at round-*open*, not round-close; land v0.25 before R29.M1 open; every driver has a "structural stub" path so bring-up isn't fully gated on encoder completeness. |
| **R11** | ACPICA userspace bubble under-performs kernel ACPICA; HWP feedback misses ms deadlines | Med (thermal loop softens; battery regresses) | Med | R30 reserves LP-E core for the bubble; R31 wires HWP-INT to reserved core; measure round-trip at R31 close, iterate if > 2 ms. |
| **R12** | DMA-attestation UX friction (annoying dialog → users disable → lose security) | Med | Med | Enroll trusted-device fingerprints at first-consent; "always trust this device" toggle; compositor shows persistent indicator when DMA active from external device. |
| **R13** | Direct-scanout on Iris Xe Gen12 with PSR2 + VRR interaction under-tested outside Linux i915 | Med (visible daily-driver glitches) | Med | Land direct-scanout without PSR2 first; PSR2 as G2 optional milestone; VRR opt-in per client for one full cycle. |
| **R14** | Bluetooth LE Audio evolution (LC3/Auracast/BAP/CAP/TMAP) requires surgery on Classic-designed bt_supervisor | Med | Med | Design R39 protocols around Isoch Channels from start; HFP/A2DP become "profiles running over Isoch"; Auracast plugs into same layer. |
| **R15** | Effect-row explosion (50+ new effects → unreadable type signatures) | Med | Med | Enforce `{subsystem}_{verb}` naming; aggregate row aliases (`!{DriverEffects}`, `!{CompositorEffects}`); `design/toolchain/effect-vocabulary.md` documents top-level vocabulary. |

---

## 8. Sequencing (osarch's §4 dependency graph adopted, with softarch's parallelism annotations)

**Serial critical path:**
```
R29 → R30 → R31 → R32 → R33 (audio needs framework + ACPI + I²C)
                    ↓
R29 → R36 → R37 → G1 → G3 (Vulkan) → G4 (Vello) → G5 (text) → G6 (color) → G7 (compositor) → G8..G12
                    ↓
                    G2 (direct scanout — needs G1 only; parallel with G3+)
R29 → R34 (USB) — parallel with R30 once R29 lands
R29 → R38 (Wi-Fi) — parallel; only depends on R32 crypto + framework
R38 → R39 (BT shares CNVi PHY)
R37 → R40 (camera needs KIND_GPU_BO)
```

**Parallelizable waves (once R29 lands):**
- **Wave A (months 0–6):** R29 → R30 → R31; R34 parallel with R30 from week 4.
- **Wave B (months 6–10):** R32 (HID/sensors); R33 (audio); R38 (Wi-Fi) parallel.
- **Wave C (months 10–14):** R35 (TB4); R36 (display); R39 (BT — needs R33+R38 done).
- **Wave D (months 14–20):** R37 (GPU exec — big); G1 kicks off mid-R37.
- **Wave E (months 18–24):** G2, G3, G4 parallel; R40 (camera) parallel.
- **Wave F (months 22–30):** G5, G6, G7 → G8, G9 finish.
- **Wave G (months 28–34):** G10, G11, G12; hardening + closure.

**Wall-clock estimate (both proposals reconciled):** 15–22 months with continuous parallelism at 4–6 wk/round tempo; 30 months if fully serialized.

**GUI-features-that-unblock-drivers** (osarch's §4.3):
- R36 paideia-drm → R31.M4 backlight (eDP AUX needs open DP link).
- G2 direct-scanout → R40 camera privacy overlay (reserved plane above compositor).
- G10 a11y → R40 fingerprint enroll UX (screen-reader-accessible).

---

## 9. GitHub milestone titles (canonical filing list)

**Axis 1 (12 milestones, ~330 issues):**
```
r29-driver-substrate                          30 issues
r30-acpica-lpss                               40 issues
r31-platform-ec                               26 issues
r32-hid-sensors                               22 issues
r33-audio-hda-sof                             30 issues
r34-usb-fabric                                28 issues
r35-thunderbolt                               24 issues
r36-display-substrate                         18 issues
r37-gpu-execution                             36 issues
r38-wifi-ax211                                34 issues
r39-bluetooth                                 24 issues
r40-camera-wwan                               18 issues
```

**Axis 2 (12 milestones, ~186 issues):**
```
g1-display-sync                               16 issues
g2-direct-scanout                             14 issues
g3-vulkan-surface                             18 issues
g4-vello-2d                                   16 issues
g5-sdf-text                                   18 issues
g6-color-hdr                                  16 issues
g7-compositor-protocol                        22 issues
g8-input-routing                              14 issues
g9-windowing-feedback                         14 issues
g10-accessibility                             12 issues
g11-ime                                       12 issues
g12-toolkit                                   14 issues
```

**paideia-as cross-repo (8 milestones, filed in the paideia-as repo — not counted in ~516):**
```
paideia-as-v0.25-session-functors             (blocks R29)
paideia-as-v0.26-aml-substrate                (blocks R30)
paideia-as-v0.27-dma-timeline                 (blocks R33 + R37)
paideia-as-v0.28-gpu-submit                   (blocks R37)
paideia-as-v0.29-compositor-substrate         (blocks G7)
paideia-as-v0.30-vulkan-spirv                 (blocks G3 + G4)
paideia-as-v0.31-color-hdr                    (blocks G6)
paideia-as-v0.32-a11y-toolkit                 (blocks G10–G12)
```

---

## 10. Open architectural questions — RESOLVED

All seven open questions resolved via user disambiguation on 2026-08-11. Decisions are load-bearing and referenced by every round below.

### D1 — Blob-driver capability policy (three sub-decisions)

- **D1.a Signing trust model: DUAL SIGNATURE.** Every vendor firmware blob (Intel AX211 UMAC, Intel IPU6, Intel GuC/HuC, Intel BT HCI, Realtek SOF) must carry BOTH the vendor signature AND a Paideia manifest re-sign (ML-DSA-65 under our project root key from R32). Rejects blobs with only one. Highest assurance; costs a per-blob review step; blocks emergency vendor security updates until we re-sign (acknowledged trade-off).
  - Implementation: `blob_load(fw_path)` verifies vendor sig against pinned vendor pubkey (`assets/keys/{intel,realtek}-firmware-*.pk`), then reads `.pdxsig` manifest, verifies `manifest.blob_hash == sha3_256(blob)`, verifies manifest sig against `paideia_root_pk`.
  - Design doc: `design/drivers/blob-policy.md` (R29 close).

- **D1.b IOMMU domain granularity: PER-DRIVER-PROCESS.** One `KIND_DMA_DOMAIN` per driver process, shared across all devices that driver owns. Accepts the risk that a compromised AX211 UMAC could peek at BT ring memory (both live in the same process). Chose over per-device for simplicity; over per-firmware-image for domain-churn cost.

- **D1.c Audit access: FULL.** Blob drivers have same audit access (read + write) as non-blob drivers. Matches how Linux firmware-loading drivers work. Loses one layer of blast-radius reduction; accepted for operational simplicity.

### D2 — Intel VMD: BIOS-OFF THROUGH NEXT-WAVE, VMD DRIVER AT R47+

BIOS-off policy remains through R29–R46. Users on VMD-on hardware must toggle BIOS Setup → Storage → Intel VMD → Off. Documented in `design/hardware/quirks.md` §2.4 (already present from R22.M6 #870). VMD driver lands in a post-G-series hardening round (R47+). Accepts that some users must toggle BIOS through the whole 15–22 month wave.

### D3 — Thunderbolt 4 Connection Manager: SOFTWARE-CM FROM R35

R35 lands software-CM directly (Linux-style). ~40 issues (vs ~24 for firmware-CM). Strong Pillar 3 (userspace-first) and Pillar 5 (no legacy) alignment: one code path forever. OS drives topology walk + tunnel provisioning + per-dock IOMMU domain + DMA-consent arbitration. Non-goal: firmware-CM fallback path.

### D4 — Semantic terminal: SPLIT (R41 fb-console + R44 GUI-native)

Ship semantic terminal TWICE with shared `semantic-term-core` library:
- **R41 `semantic-terminal-fb`** — uses R23 fb-console + R26 HID keyboard. Ships immediately after driver-closure R40. Preserves fb-console as recovery-mode terminal.
- **R44 `semantic-terminal-gui`** — uses G12 `libpaideia-ui` + Vello + SDF text + IME + a11y + HDR. First-class GPU-accelerated app after G-series closes.
- **Shared:** `semantic-term-core` (command lexer, semantic query engine, plot compositor) — two frontends, one backend.

### D5 — PdxFS v1: R42, PARALLEL WITH G-SERIES

PdxFS v1 (CoW + journal + snapshot upgrade of PdxFS-lite) lands at R42, immediately after R41 semantic-terminal-fb, running in parallel with G-series GUI stack. Uses R24 NVMe write path once #906 unblocks. ~4–6 weeks of dedicated work. Users get durable filesystem before GUI arrives.

### D6 — Slot 14 base-kind: RESERVED FOR KIND_HW

Slot 14 of the 16-frozen-base-kind enum is allocated to `KIND_HW` — a new base kind for hardware-adjacent capabilities. `KIND_INTERRUPT`, `KIND_HW_TIMELINE`, `KIND_MSIX_VECTOR`, and `KIND_DMA_DOMAIN` all derive over `KIND_HW`. Enables LAM kind-hint fast-dispatch on the CPU tag (saves one indirection per hardware-cap use). Slot 15 remains reserved for confidential-compute / TDX (per CAP-Q9 open issue).

Document in `linearity-and-tags.md` §3.1 at R29.M1 open:
```
0  PAGE       8  CHANNEL
1  MEMORY     9  SUPERVISOR
2  DEVICE     10 (existing)
...            14 HW              ← new (R29)
               15 CONFIDENTIAL    ← reserved (TDX)
```

### D7 — HW-smoke discipline: EVERY ROUND HAS QEMU + T14 RECIPE

Every next-wave round with a `gated:hardware` label ships BOTH:
- (a) a QEMU-OVMF structural witness (compiles, links, dormant path exercised via synth fixture);
- (b) a `tools/hw-smoke-<round>.md` operator recipe for T14 G4 real HW.

Round does NOT close until both exist. Real-HW recipe execution remains user-triggered (not auto-CI, per `feedback_paideia_os_no_cicd.md`); each execution promotes quirks-db rows from PROVISIONAL → CONFIRMED. Aligns with R28.M2 HW-smoke harness landed at adf5083.

### Consequences for milestone catalogue (§2)

Adjustments to §2 driven by these decisions:
- **R35 issue count: 24 → ~40** (D3 software-CM adds ~16 issues for topology walker, tunnel provisioner, multi-host arbitration).
- **R41 slot renamed** from "hardening-slot" to `r41-semantic-terminal-fb` (D4). New round, ~15 issues (`semantic-term-core` + fb frontend).
- **R42 slot added** as `r42-pdxfs-v1` (D5). New round, ~20 issues (CoW walker + journal + snapshot semantics).
- **R44 slot added** as `r44-semantic-terminal-gui` (D4). New round, ~12 issues (G12 toolkit consumer of `semantic-term-core`).
- **R47+ slot pre-registered** as `r47-vmd-driver` for the deferred VMD landing (D2). ~15 issues.
- **R29.M1 issue added:** promote slot 14 → `KIND_HW`; update `linearity-and-tags.md` (D6). +1 issue.
- **R29 issue added:** draft `design/drivers/blob-policy.md` capturing D1.a/D1.b/D1.c (D1). +1 issue. Blocking for R38 + R40 close.
- **Every round with `gated:hardware`:** acceptance criterion updated to require both QEMU witness AND T14 recipe (D7). No new issues (existing AC updated); adjusts round-close discipline.

**Revised grand total: 24 milestones + 3 new (R41/R42/R44) + 1 hardening (R47) = 28 milestones. Issues ~516 + ~65 = ~581.** Wall-clock estimate unchanged (parallelism absorbs the additions).

**Revised milestone titles for GitHub filing (additions):**
```
r41-semantic-terminal-fb                     15 issues
r42-pdxfs-v1                                 20 issues
r44-semantic-terminal-gui                    12 issues
r47-vmd-driver                               15 issues
```

All decisions load-bearing; §11 bulk-filing plan now unblocked.

---

## 11. Bulk-filing plan (post-synthesis operational step)

Given ~516 issues + 24 milestones + 8 paideia-as bundles = ~548 GitHub artifacts to create:

1. **Phase A (immediate, blocking):** Resolve the 7 open architectural questions in §10 above.
2. **Phase B (milestone creation):** 24 paideia-os milestones + 8 paideia-as milestones via `gh api repos/{owner}/{repo}/milestones -f title=... -f description=...`. ~30 seconds each via script.
3. **Phase C (issue creation):** ~516 paideia-os issues distributed across milestones. Generate issue titles + bodies from this document via a synthesis script; file via `gh issue create --milestone <m>`. Batch of 10 issues per commit-safety-window; expect ~10 API calls per minute rate limit.
4. **Phase D (dependencies):** GitHub issues don't have a first-class dependency field; use `blocks:` / `blocked-by:` labels + a linking comment. Optionally use `gh project` if we adopt Projects.
5. **Phase E (autonomous loop resume):** Once R29's issues are filed, resume the autonomous softarch → debugger loop against them per `feedback_paideia_os_tempo.md`. R29 opens; the rest cascade per §8.

**Estimated wall-clock for bulk-filing:** ~2 hours of scripted API work + ~4 hours of manual issue-body refinement (spread across the 24 milestones) = ~1 day of concentrated work.

---

## 12. Convergence note

Both agents converged on every architectural commitment listed in §1's "where they fully agree" block. The synthesis is not a compromise between two competing designs — it is the same design produced twice with different emphasis (systems vs software), reconciled on procedural questions only (numbering, sequencing granularity, capability enumeration depth). This is the strongest possible signal that the design is right: two independent voices, briefed once, reached the same conclusion.

The one substantive disagreement (Wi-Fi/BT/Camera at R38–R40 vs R41–R43) was resolved in softarch's favor because osarch's rationale for deferring was schedule-only, and MVP closure removes that concern.

**Ready for §11 Phase A once the seven open questions in §10 are resolved.**

---

*End of synthesis. Companion docs: `design/roadmap/next-wave-osarch.md`, `design/roadmap/next-wave-softarch.md`.*
