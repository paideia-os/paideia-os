# R101 (+ R103–R105 if split) Plan: Lighting Up a Framebuffer — QEMU + T14 G4

**Status:** Proposal — osarch voice, kernel-side only. Ready for milestone/issue filing.
**Date:** 2026-09-01.
**Scope:** Complete the kernel-side graphical display stack so a user-space
compositor (the sibling softarch wave's design) can hold a display-authority
capability, allocate a scan-out framebuffer, page-flip it to the panel, and
subscribe to vblank + hotplug events — on both QEMU (`-vga std` / `-vga virtio`
/ `-device virtio-gpu-pci`) and the Lenovo T14 Gen 4 (Intel Iris Xe, real HW).
**Companion:** `design/graphics/r102-user-plan.md` (softarch R102, 2026-09-01) is the
paired userland plan. It names this document explicitly as its osarch
companion and expects a single kernel round (R101). §2 below explains why
this document is willing to be sliced across R101 + R103–R105 if scope
warrants, and why R102 is skipped rather than used.
**Round numbering:** R101 owns the kernel side of this wave. **R102 is
already claimed by softarch's userland companion** (grep-verified against
`design/graphics/r102-user-plan.md`, 2026-09-01) — the wave design pairs
osarch R101 with softarch R102 one-to-one. If the kernel side splits into
additional rounds, they take R103 / R104 / R105 (skipping R102 entirely).
Preceding numbers: last feature round is R89 (KIND_TUI_CANVAS, closed);
R90 is the cross-repo housekeeping tag; R91–R99 is the in-flight networking
wave; R100 is user tools. The G-series (G1–G9 in
`design/roadmap/next-wave-softarch.md`) is a parallel *initiative*
namespace: G1–G6 landed graphics substrate, but nothing actually
initializes a live display pipeline at boot today. This wave closes that
gap and provides the seam G7 (compositor) will consume.

---

## 0. What is landed vs missing — this is NOT a greenfield wave

The task brief that produced this document assumed the graphics tree was
either empty or a small extension of R23's GOP framebuffer console. **It
is neither.** A great deal of Iris-Xe-specific substrate has landed across
R36, R37, G1, G2, G3, G4, G5, and G6. Re-proposing that work would waste
review effort and risk clobbering real invariants (the exact failure mode
`[[feedback-spec-vs-codebase-conflicts]]` warns against). This document
instead:

1. Catalogs precisely what is landed and load-bearing (§0.1).
2. Catalogs the **real** gaps (§0.2) — mostly *wiring* and *QEMU-backend*
   gaps, not missing display-pipeline logic on T14.
3. Plans four rounds (R101 + R103–R105) that close those gaps without re-deriving
   landed substrate (§2–§9).

### 0.1 Ground truth (verified against source, 2026-09-01)

| Area | Files | State |
|---|---|---|
| GOP linear framebuffer mapper | `drivers/fb_map.pdx` (R23.M1-001 #875) | Real: maps the UEFI-GOP-reported LFB into PML4[320] at 0xFFFF_A000_0000_0000 with PAT slot 4 = WC. **Skips silently on `fb_base_pa == 0`**, which is EVERY PVH `-kernel` QEMU boot (there is no GOP under `-kernel`). |
| Framebuffer text console | `drivers/{fb_font,fb_glyph,fb_console}.pdx` (R23.M2 #879-#882) | Real: 8x16 vgacon font, glyph rasterizer, ANSI-16-color scrolling console. Bound to WHATEVER `fb_map_lfb` returned. **Only lights up on UEFI (T14) — never on QEMU today.** Semantic-terminal front-end at `semterm/fb_frontend.pdx`. |
| Iris Xe display engine substrate | `cap/kind_display_engine.pdx` (0x16F), `cap/kind_display_output.pdx` (0x170), `cap/kind_modeset_txn.pdx` (0x171), `cap/kind_display_mode.pdx` (0x172), `cap/kind_display_plane.pdx` (0x173), `drivers/dpy/{iris_xe_probe,pwr_wells,dpclk_config,edid,hpd_isr,topology,mode_enum,atomic_commit,plane_primary,plane_overlay,plane_cursor}.pdx` (R36.M1..M4 #1238–#1249) | Real: PCI probe, power well + CDCLK programming, EDID + HPD, mode enumeration, atomic commit transaction, three plane classes. **Never called from `kernel_main.pdx`.** Existence proven only by per-kind boot witnesses that mint + query capabilities against dummy KIND_DEVICE parents. No live modeset has run against a real panel. |
| GPU substrate (Iris Xe) | `cap/kind_gpu_bo.pdx` (0x174), `cap/kind_gpu_vm.pdx` (0x175), `cap/kind_gpu_context.pdx` (0x176), `cap/kind_gpu_submit.pdx` (0x177), `drivers/gpu/{bo_alloc,ppgtt_walker,ppgtt_bind,ppgtt_prot,tiling,cache_policy,gtt_scanout,gpu_reset,lrc,execlists,ctx_priority,batch_builder,guc_load,guc_hs,guc_submit,guc_verify,huc_load,vcs_engine,hevc_frame,gpu_stress,gpu_reg_audit,gpu_mmio}.pdx` (R37.M1..M6 #1262–#1276) | Real: BO allocator, PPGTT + GTT + tiling + cache policy, GPU reset, LRC + execlists + preemption, batch builder, GuC firmware load/handshake/submit/verify, HuC load, VCS engine, HEVC frame primitive, register audit. **Never called from `kernel_main.pdx`.** No GuC has loaded firmware on a real GT; no submission has flown a real ring. |
| G1 display timeline + VRR | `cap/kind_display_timeline.pdx` (0x185), `cap/kind_vrr_range.pdx` (0x186), `drivers/dpy/{timeline,vrr}.pdx` (G1.M1..M3 #1427–#1442) | Real: drm-syncobj-shaped display timeline (one per engine+output), VRR range descriptor, explicit-sync wait/signal seam over R37 GPU timelines. **The vblank ISR that would signal the timeline is exported (`dpy_timeline_signal_vblank`) but not wired to any IRQ source** — no real vblank has fired. |
| G2 direct-scanout lease | `cap/kind_scanout_lease.pdx` (0x188), `drivers/dpy/scanout.pdx` (G2.M1..M3 #1443–#1456) | Real: fullscreen-client lease authority, grant/present/revoke seam, tearing arbiter, format matrix, HDR pass-through. Presupposes a working modeset + plane commit path (not yet wired at boot). |
| G3 Vulkan surface + swapchain | `cap/kind_vk_surface.pdx` (0x189), `cap/kind_vk_swapchain_image.pdx` (0x18A), `drivers/vk/{icd,swapchain,vk_features,bench}.pdx` (G3 #1457–#1474) | Real: `VK_paideia_surface` ICD entry point, swapchain acquire/present with dual timeline, presentation-time feedback. **Presupposes the display pipeline lights up, which it does not today.** |
| G4 Vello compute rasterizer | `drivers/vello/{vello_pipeline,vello_scene_encoder,vello_tiling,vello_effects,vello_cpu_fallback}.pdx` (G4 #1475–#1490) | Real: GPU-side path stroking/filling/gradient/blur compute pipelines, tile-based coarsening, CPU fallback. **Presupposes GuC + submit path, which has never flown a batch.** |
| G5 SDF font atlas + text | `drivers/text/{sdf,shaper,subpixel,color_emoji}.pdx` (G5 #1491–#1508) | Real: SDF atlas generator, HarfBuzz-equivalent shaper, fractional-scale sub-pixel positioning, COLR/CPAL + SBIX + CBDT color emoji. Substrate only; no consumer today. |
| G6 color management | `drivers/color/{cicp,eotf,icc,scrgb,gpu_convert,surface_check}.pdx`, `drivers/{backlight_dpaux,backlight_pwm}.pdx` (G6 #1509–#1516, #1571–#1576) | Real: CICP + ICC parsing, GPU compute conversion pipeline, HDR10 pass-through, reference-display tone-mapping, backlight over DP-AUX + PWM. Substrate only. |
| `run-qemu.sh` display flags | `tools/run-qemu.sh` | **`-display none`, no `-vga` flag, no `-device virtio-gpu-pci`.** QEMU emulates a Cirrus/stdvga PCI device by default even without `-vga`, but nothing in this tree ever binds to it. |
| Legacy stub | none | Unlike the R91 networking wave (which inherited a Phase-7 `virtio_net` stub), the display tree has no orphaned pre-refactor code — every landed kind uses the modern conventions. |

### 0.2 The real gaps (what R101 + R103–R105 actually closes)

Ranked by "how much does this block a compositor from painting a pixel on
the screen":

1. **On QEMU there is no display path at all.** No driver binds to
   Bochs/stdvga's LFB or virtio-gpu's control queue; `run-qemu.sh`
   passes `-display none` so QEMU allocates no display device at all
   under the default invocation, and even with `-vga std` nothing in
   the kernel would consume it. The entire QEMU graphics side is a
   greenfield gap. This is the single highest-blocker item.
2. **On T14, nothing initializes the R36/R37/G1–G6 substrate at boot.**
   `iris_xe_probe`, `pwr_wells`, `dpclk_config`, `mode_enum`, `atomic_commit`,
   `plane_primary`, `guc_load`, `guc_hs`, `guc_submit`, `dpy_timeline_signal_vblank`
   — none appear anywhere in `boot/kernel_main.pdx` (grep-verified). The
   R23 GOP fb console lights up (because UEFI populates `_boot_env.fb`
   from GOP), but the R36 engine + R37 GuC pipeline is dead code.
3. **No page-flip capability surface exists.** KIND_MODESET_TXN authorizes
   an atomic commit and KIND_DISPLAY_PLANE authorizes a plane's backing
   memory, but there is no cap a compositor holds that authorizes "swap
   this plane's memory to point at a new buffer and wake me on the next
   vblank." KIND_SCANOUT_LEASE addresses only the fullscreen-client
   case (P7: direct-scanout as default for fullscreen), not the normal
   compositor case.
4. **No hotplug event channel exists.** `hpd_isr.pdx` is substrate; it
   has no IPC endpoint a compositor subscribes to, and no wiring to the
   real HPD interrupt on T14.
5. **KIND_DISPLAY_ENGINE is Iris-Xe-exclusive by mint gate** (`gpu_gen
   in {1, 2, 3}` per its mint contract). A QEMU stdvga or virtio-gpu
   cannot mint one. Either the mint gate widens or a sibling abstract
   kind (KIND_DISPLAY_BACKEND) sits above it as the compositor-facing
   anchor. §4.1 chooses the latter.
6. **No syscalls address the display path.** Sysnos 0–107 cover process,
   memory, fs, task, and the R91 socket family; nothing addresses
   display. Compositor sits behind the syscall boundary; without display
   syscalls, no compositor code can even ask "which outputs exist."

---

## 1. Reconciliation with the G-round roadmap

`design/roadmap/next-wave-softarch.md` §G defines nine graphics-initiative
rounds. G1–G6 landed; G7 (compositor `KIND_SURFACE` + `KIND_WINDOW` +
`KIND_LAYER_TREE` + damage + DnD + clipboard + screencapture), G8
(input router), and G9 (workspaces + tiling + presentation-time
feedback) remain. **R101 + R103–R105 is NOT G7.** It is the substrate G7
presupposes: without a lit-up display pipeline and a page-flip cap,
G7's compositor has nothing to composite onto.

Naming-wise there are two defensible choices:

- **Continue the G-series** as G0-QEMU or GX (out-of-band): honest that
  this belongs to the graphics initiative, awkward that G1–G6 already
  shipped before what should logically precede them.
- **Open a chronological R-series round** (R101): follows the R-number
  order (R89 last feature → R91–R99 networking → R100 user tools →
  R101), consistent with how R91 was named despite being a graphics-
  adjacent initiative (networking).

This plan takes the R101 path — chronological R-numbering — matching
the R91 precedent. The G-series continues to be the *initiative* name
in roadmap discussion; R101 + R103–R105 is the *round* that materializes G7's
prerequisites. Cross-links between the two are called out where they
matter.

### 1.1 Architecture tension this plan does NOT resolve

`design/roadmap/next-wave-softarch.md` §7 (P7 "direct-scanout as
default for fullscreen") and §8 (P8 "recovery-console plane reserved
under lease pressure") describe compositor invariants that KIND_SCANOUT_LEASE
already encodes as row-table invariants (G2.M1's `scan_out_lease` refuses
plane 0). This plan does not revisit those.

`design/roadmap/next-wave-softarch.md` §G4 commits to Vello as the CPU-
addressable 2D rasterizer for the compositor's own compositing pass. G4
landed the substrate. **This plan does not wire Vello into anything.** A
future round (call it G7-prep or R105-follow-on) has to actually invoke
the Vello pipeline against a real GPU submit; today Vello has never
executed against a real ring.

---

## 2. Round shape: R101 primary, split into R101 + R103–R105 if scope demands

Softarch's `r102-user-plan.md` (2026-09-01) expects a single osarch R101
round paired one-to-one with softarch's own single R102 round. This
document honours that expectation as its **primary recommendation**:
one R101 kernel round with M1–M25 covering all four sub-scopes below.

However, R101-with-25-milestones is at the upper end of round density
(R91 shipped 6 milestones + 23 issues; R91–R99 as a *wave* shipped 39
milestones + 99 issues across nine rounds). If review or scheduling
prefers a smaller-per-round shape, the sub-scopes cleanly slice into
**four rounds R101 + R103 + R104 + R105 (skipping R102, which softarch
owns)** — see §2.2. The milestone tables in §5–§8 use the sub-scope-
per-round layout so either shape maps mechanically onto them.

**Sub-scopes (four, listed as they would land as separate rounds):**

- **R101 (kernel) — Dumb-framebuffer backend (QEMU `-vga std` / Bochs).**
  New KIND_DISPLAY_BACKEND abstract kind, Bochs/stdvga driver,
  KIND_FRAMEBUFFER scan-out buffer, minimal single-buffer flush path.
  Motivating question: "can we draw a test pattern on QEMU without any
  Iris Xe substrate?"
- **R104 (if split) — virtio-gpu 2D backend.** virtio-gpu-pci probe,
  control queue bring-up, RESOURCE_CREATE_2D + ATTACH_BACKING +
  SET_SCANOUT + RESOURCE_FLUSH ops, control-queue completion →
  simulated vblank on KIND_DISPLAY_TIMELINE. Motivating question: "can
  a page-flip on QEMU ride a real completion event, not a polled tick?"
- **R105 (if split) — T14 Iris Xe wire-up + page-flip cap.** Actually
  call `iris_xe_probe` + `mode_enum` + `atomic_commit` from
  `kernel_main.pdx`; wire the vblank ISR through
  `dpy_timeline_signal_vblank`; introduce KIND_PAGE_FLIP as the
  compositor's swap-and-await authority; multi-scanout (external DP
  over Thunderbolt, since R35 landed TB substrate). Motivating
  question: "on real Iris Xe hardware, does a compositor page-flip a
  buffer to the panel and get a vblank event back?"
- **R105 (if split) — Compositor syscall surface + hotplug + boot
  witnesses.** `sys_display_enumerate`, `sys_framebuffer_{create,map}`,
  `sys_page_flip{,_wait}`, `sys_display_hotplug_subscribe`, security
  posture (compositor holds display authority; app clients hold draw
  surfaces via IPC, never a fb directly), end-to-end witnesses under
  `PAIDEIA_VGA=std|virtio|none`. Motivating question: "can a user-space
  program open a framebuffer and page-flip it, on both QEMU backends
  and T14, without a single kernel patch after this round?"

**Total scope:** 25 milestones, **72 issues** (table in §15).

### 2.1 Why skip R102

The wave-design convention softarch adopted is **osarch odd, softarch
even for paired waves** (R91–R99 osarch networking pairs with R100
softarch user-tools; R101 osarch graphics pairs with R102 softarch
graphics-userland). Filing my R103 (or my R102) for virtio-gpu would silently
collide with softarch's already-published `r102-user-plan.md`, exactly
the failure mode `[[feedback-spec-vs-codebase-conflicts]]` warns
against. The gap between R101 and R103 is the honest documentation of
that convention, not an accident.

### 2.2 Splitting policy: single-round is primary, four-round split is fallback

Recommend landing R101 as a single round with M1–M25 if issue-filing
capacity allows; each milestone table below is already scoped to a
single-round-per-sub-scope shape, so a mid-wave decision to split
requires only re-tagging milestone numbers, not re-scoping issues.

**Split trigger:** if R101 issue count exceeds ~30 open at any point
during landing, or if the T14-gated witnesses (R105 sub-scope) start
serializing behind QEMU-only work, split into R101 + R103–R105 with
minimal churn.

---

## 3. Milestone breakdown (motivating questions)

### R101 — Dumb-framebuffer backend

- **R101.M1 — KIND_DISPLAY_BACKEND abstraction.** Q: "what capability
  does a compositor hold that names WHICH display path is active
  (Bochs, virtio-gpu, Iris Xe) so the syscall surface can be uniform?"
- **R101.M2 — Bochs/stdvga driver.** Q: "given a PCI-discovered stdvga
  device, can we program a mode and map its LFB into the kernel?"
- **R101.M3 — KIND_FRAMEBUFFER + flush primitive.** Q: "how does a
  caller name a scan-out buffer separately from its backing memory,
  and how does the kernel commit the buffer to the panel?"
- **R101.M4 — Boot witness `boot_r101_stdvga`.** Q: "does the whole
  chain (backend mint → framebuffer alloc → flush) put a checkerboard
  on QEMU's stdvga output?"
- **R101.M5 — R101 closure retrospective.**

### R103 — virtio-gpu 2D backend

- **R103.M1 — virtio-gpu probe + control queue.** Q: "does the
  virtio-net R91.M3 virtqueue pattern generalize to a virtio-gpu
  control queue?"
- **R103.M2 — RESOURCE_CREATE_2D / ATTACH_BACKING / SET_SCANOUT.**
  Q: "can we create a host-side 2D resource, back it with a KIND_MEMORY
  page range, and bind it to scanout 0?"
- **R103.M3 — TRANSFER_TO_HOST_2D + RESOURCE_FLUSH.** Q: "does a
  page-flip on virtio-gpu carry the guest-side pixel update to the
  host-visible surface?"
- **R103.M4 — Completion → KIND_DISPLAY_TIMELINE.** Q: "can the
  virtio-gpu control-queue completion signal KIND_DISPLAY_TIMELINE
  the same way a real vblank does, so the G1 explicit-sync path
  works uniformly across backends?"
- **R103.M5 — Boot witness `boot_r103_virtio_gpu`.** Q: "does a
  double-buffered page-flip on virtio-gpu complete correctly and
  advance the timeline?"
- **R103.M6 — R103 closure retrospective.**

### R104 — T14 Iris Xe wire-up + page-flip cap

- **R104.M1 — Boot-time Iris Xe pipeline init.** Q: "does calling
  `iris_xe_probe` + `pwr_wells_enable` + `dpclk_config_program` from
  `kernel_main.pdx` bring the display engine to a state where mode
  enumeration succeeds against a live EDID?"
- **R104.M2 — Modeset from best EDID mode.** Q: "given an enumerated
  set of modes and a panel's preferred timing from EDID, does an
  atomic_commit transaction actually change what shows on the panel?"
- **R104.M3 — vblank ISR wiring.** Q: "does the display engine's
  vblank IRQ actually fire, and does `dpy_timeline_signal_vblank`
  advance the KIND_DISPLAY_TIMELINE row on each vblank?"
- **R104.M4 — KIND_PAGE_FLIP capability.** Q: "what is the LINEAR
  cap the compositor holds to authorize a plane-buffer swap + await
  the next vblank, and how does it compose with G2's KIND_SCANOUT_LEASE
  for the fullscreen-client case?"
- **R104.M5 — Multi-scanout (external DP over TB).** Q: "does an
  external display attached via Thunderbolt Alt-Mode DP mint its
  own KIND_DISPLAY_OUTPUT + KIND_PAGE_FLIP + KIND_DISPLAY_TIMELINE,
  independent of the built-in panel?"
- **R104.M6 — T14-gated boot witness `boot_r104_iris_xe_flip`.**
  Q: "on real T14 hardware, does a page-flip land on the internal
  panel and does the vblank event arrive within one refresh period?"
- **R104.M7 — R104 closure retrospective.**

### R105 — Compositor syscall surface + hotplug + boot witnesses

- **R105.M1 — `sys_display_enumerate`.** Q: "how does the compositor
  discover which backends, outputs, modes, and planes exist without
  a build-time hardcode?"
- **R105.M2 — `sys_framebuffer_create` + `sys_framebuffer_map`.**
  Q: "can a client mint a KIND_FRAMEBUFFER, get a WC-mapped VA into
  its address space, and draw into it?"
- **R105.M3 — `sys_page_flip` + `sys_page_flip_wait`.** Q: "does
  the client-facing syscall pair, invoked against a KIND_PAGE_FLIP
  cap the compositor holds, atomically commit + return + block-until-
  completion in a way that composes with `sys_poll` from R95.M3?"
- **R105.M4 — KIND_HOTPLUG_CHANNEL + `sys_display_hotplug_subscribe`.**
  Q: "how does the compositor learn about external-display connect/
  disconnect events without polling?"
- **R105.M5 — Security posture (`design/graphics/authority-boundary.md`).**
  Q: "what is the invariant that says 'an app client never touches a
  framebuffer directly; it only holds an IPC endpoint the compositor
  draws from', and where is it enforced?"
- **R105.M6 — End-to-end boot witnesses (`PAIDEIA_VGA=std|virtio|none`).**
  Q: "does a single user-space program (`boot_r105_flip_client`) open
  a fb, draw a frame, page-flip, wait, and repeat, on both QEMU
  backends and (gated) T14 hardware?"
- **R105.M7 — R105 closure retrospective + cross-round STATUS.md.**

---

## 4. Architecture decisions this plan makes

### 4.1 KIND_DISPLAY_BACKEND as the multi-backend anchor (R101.M1)

KIND_DISPLAY_ENGINE's mint gate refuses `gpu_gen ∉ {1,2,3}` (Xe1/Xe2/Xe3),
so a QEMU stdvga or virtio-gpu cannot mint one. Three options considered:

- **Option A — Extend the `gpu_gen` enum** (values 100 = Bochs stdvga,
  101 = virtio-gpu 2D, 102 = virtio-gpu 3D). Least invasive; downstream
  KIND_DISPLAY_OUTPUT and MODESET_TXN keep referring to `engine_slot`
  unchanged. Rejected because "a virtio-gpu is an Iris Xe engine with
  generation 101" leaks abstraction — downstream code that branches on
  `gpu_gen` for real-HW-only concerns (DDI programming, HDCP, power
  wells) becomes littered with `if gpu_gen > 3` special-cases.
- **Option B — Sibling kinds** (KIND_QEMU_STDVGA_ENGINE,
  KIND_VIRTIO_GPU_ENGINE) with parallel shape. Rejected because the
  compositor would have to dispatch three ways at the cap-holding level
  instead of once at the driver level.
- **Option C — KIND_DISPLAY_BACKEND above KIND_DISPLAY_ENGINE.**
  Chosen. A new abstract kind, derived over KIND_DEVICE, at
  0x1AE. Carries `backend_kind` (`BOCHS_STDVGA=1, VIRTIO_GPU_2D=2,
  VIRTIO_GPU_3D=3, IRIS_XE=4`), `pci_bdf`, and a `provider_slot`
  pointer that names EITHER a KIND_DISPLAY_ENGINE (Iris Xe) OR
  a driver-private descriptor slot (Bochs / virtio-gpu — the driver
  owns the tail structure).

KIND_DISPLAY_OUTPUT's mint gate is relaxed at R104.M4 to accept a
`backend_slot` naming a KIND_DISPLAY_BACKEND (not just an
`engine_slot` naming a KIND_DISPLAY_ENGINE). Bochs and virtio-gpu
mint one output per scanout (typically 1 for QEMU); Iris Xe continues
to mint per-DDI outputs.

### 4.2 KIND_FRAMEBUFFER as a distinct, GPU-optional scan-out kind (R101.M3)

KIND_GPU_BO (0x174) is the scan-out-shaped buffer today, but its mint
requires a valid `memory_slot` PLUS the semantics presuppose a
KIND_GPU_VM (0x175) it can be bound into — a GPU_VM does not exist
on Bochs/stdvga (no GPU). Deriving Bochs's scan-out buffers as GPU_BOs
would require a stub KIND_GPU_VM that promises nothing, a design smell
identical to Option A above (a virtio-gpu "generation 101" engine).

Chosen: **KIND_FRAMEBUFFER** (0x1AF), derived over KIND_MEMORY, carrying
`{width, height, pitch, format, backend_slot, bo_slot_optional}`. On
Iris Xe, `bo_slot_optional` points at a KIND_GPU_BO (so the tiling +
cache-policy + GTT-scanout path can reach the real BO); on Bochs / early
virtio-gpu 2D, `bo_slot_optional = 0` and the framebuffer is just a
linear KIND_MEMORY range with no GPU involvement. The `backend_slot`
tells the flush path which driver to invoke. Format is an fourcc-lite
tag matching KIND_DISPLAY_PLANE's format enum.

### 4.3 KIND_PAGE_FLIP as the compositor's per-output swap authority (R104.M4)

KIND_MODESET_TXN authorizes a full mode change (heavy, per-output,
not per-frame). KIND_DISPLAY_PLANE authorizes a plane's identity
(z-order, format, class) but not "point this plane at a new buffer
now." KIND_SCANOUT_LEASE authorizes bypass-the-compositor
direct-scanout for fullscreen clients.

A compositor's normal per-frame path is **none of these**. It needs a
capability that says: "at the next vblank on this output, this plane's
backing memory shall be `fb_slot`, and here is the target timeline
value the display engine will latch." That's KIND_PAGE_FLIP
(0x1B0), derived over KIND_DISPLAY_OUTPUT, LINEAR (a page-flip in
flight cannot be duplicated), carrying `{output_slot, primary_plane_slot,
active_fb_slot, timeline_slot, in_flight_flag}`.

Rights: `R_FLIP_INVOKE` (submit + await), `R_FLIP_REVOKE` (compositor
teardown), no `R_FLIP_MINT` (LINEAR). Held per output by the
compositor; revoked on compositor exit (and cascades to invalidate
any in-flight flip queued in the driver).

### 4.4 Vblank source: uniform KIND_DISPLAY_TIMELINE regardless of backend

G1.M1-003 already put a vblank signal seam on `dpy_timeline_signal_vblank`.
On T14 (R104.M3) the real vblank IRQ calls it. On virtio-gpu (R103.M4)
the control-queue completion for RESOURCE_FLUSH calls it. On Bochs
stdvga (R101.M4) — Bochs has no vblank, so we drive a 60 Hz LAPIC-tick
scheduler slice that calls it (marked in the timeline row as
`SOURCE_SIMULATED` so a G7 compositor can degrade tearing-sensitive
behavior gracefully).

### 4.5 Driver placement: in-kernel, matching e1000e / R36 / R37 style

Same rationale as R91 §4.2. `driver_table.pdx` (R29+) is the substrate
for userspace-process drivers; every display/GPU driver landed to date
(R36, R37, G1–G6) is in-kernel. Migrating display to the userspace-
process model in this wave would bundle a second, unrelated architecture
change into a graphics-substrate wave. R101 + R103–R105 keeps the new Bochs +
virtio-gpu drivers in-kernel, matching precedent. The winning backend
is registered in `driver_table.pdx` for supervisor visibility only,
same shim posture the R91 NIC visibility row uses.

### 4.6 QEMU `-display` flag: `sdl` is not an option for headless CI

`run-qemu.sh` uses `-display none` today because every smoke test runs
headless. R101.M4 keeps `-display none` and instead validates the fb
contents by reading them back through QEMU's `pmemsave` monitor
command (post-boot), or by an in-kernel witness that reads back its
own written pattern from the LFB before flushing. This avoids adding
an SDL/GTK dependency to CI and keeps smoke tests bit-identical across
developer machines.

### 4.7 T14 boot witness gating: matches R51's real-hardware pattern

R51.M8-006 established the "real-hardware boot witness, gated" pattern
for the T14 BDEV witness. R104.M6 follows it: witness compiles into
the kernel but only runs when `_t14_g4_present` (already-existing
runtime flag from R28.M2's T14-first-boot substrate) is set. QEMU
boots always skip; T14 boots exercise the full modeset + flip cycle.

---

## 5. R101 — Dumb-framebuffer backend (QEMU `-vga std` / Bochs)

**Depends on:** R23 (fb_map + PAT slot 4 = WC), R29 (`driver_table.pdx`
for the visibility-shim registration).
**Headline capability:** KIND_DISPLAY_BACKEND, KIND_FRAMEBUFFER.

### R101.M1 — KIND_DISPLAY_BACKEND (4 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R101.M1-001 | `KIND_DISPLAY_BACKEND` (0x1AE) descriptor + row table + mint gate + rights: root-minted over `KIND_DEVICE`, carries `{backend_kind, pci_bdf, provider_slot, format_caps}`. Backend-kind enum {BOCHS_STDVGA=1, VIRTIO_GPU_2D=2, VIRTIO_GPU_3D=3, IRIS_XE=4}. | `cap/kind_display_backend.pdx` (new), `cap/kind.pdx` | `R101 KIND_DISPLAY_BACKEND OK` | M | none |
| R101.M1-002 | Backend-dispatch shim `graphics/backend_dispatch.pdx`: three thin wrappers (`backend_probe`, `backend_flush`, `backend_query_mode`) that branch on `_active_backend_kind`. Verify paideia-as `@jump_table` is lowered per R91.M1-002's identical verification step; fall back to an explicit compare chain if not. | `graphics/backend_dispatch.pdx` (new) | n/a (covered by R101.M4 witness) | M | R101.M1-001 |
| R101.M1-003 | Widen `KIND_DISPLAY_OUTPUT`'s mint gate to accept a `backend_slot` naming a live KIND_DISPLAY_BACKEND as an alternative to `engine_slot` naming a KIND_DISPLAY_ENGINE. Keep the existing engine_slot path for Iris Xe unchanged (additive). | `cap/kind_display_output.pdx` | n/a | M | R101.M1-001 |
| R101.M1-004 | Registry entry in `design/architecture/next-wave-derived-kinds.md` for KIND_DISPLAY_BACKEND. | `design/architecture/next-wave-derived-kinds.md` | n/a | S | R101.M1-001 |

### R101.M2 — Bochs/stdvga driver (5 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R101.M2-001 | `probe.pdx`: PCI vendor/device match (0x1234/0x1111 QEMU Bochs, 0x1013/0x00B8 Cirrus fallback), BAR0 (LFB) + BAR2 (MMIO for VBE-DISPI registers on QEMU) discovery, LFB size probe by writing/reading BAR0 mask. | `drivers/gfx/bochs_stdvga/probe.pdx` (new) | `R101 STDVGA PROBE OK bdf=0x%x` | M | R101.M1 |
| R101.M2-002 | `modeset.pdx`: VBE-DISPI programming — write `VBE_DISPI_INDEX_ENABLE = 0`, then `XRES / YRES / BPP`, then `ENABLE | LFB_ENABLED`. Chosen mode: `1024x768x32` initially; caller-supplied override reserved for R101.M3. Uses I/O port pair `0x1CE/0x1CF` on QEMU legacy path, or BAR2 MMIO on the modern QEMU stdvga (probe determines which). **paideia-as `in`/`out` instruction lowering must be verified** — see §7. | `drivers/gfx/bochs_stdvga/modeset.pdx` (new) | `R101 STDVGA MODESET OK 1024x768x32` | M | R101.M2-001 |
| R101.M2-003 | `lfb_map.pdx`: map the BAR0 LFB into kernel PML4[321] (next PML4 slot after PML4[320] R23 GOP LFB) with PAT slot 4 = WC — reuses `fb_map_lfb`'s discipline. Returns a kernel VA. | `drivers/gfx/bochs_stdvga/lfb_map.pdx` (new) | n/a | S | R101.M2-002 |
| R101.M2-004 | `flush.pdx`: `bochs_flush(fb_va, x, y, w, h)` — dumb copy from the caller's KIND_FRAMEBUFFER-backed KIND_MEMORY into the LFB (no page-flip; stdvga is single-buffered from the host side). Bounds-check against advertised mode geometry. | `drivers/gfx/bochs_stdvga/flush.pdx` (new) | n/a | S | R101.M2-003 |
| R101.M2-005 | Boot integration: `kernel_main.pdx` calls `bochs_stdvga_probe` before the R23 GOP fb path; on QEMU (`_boot_env_pa == 0` and Bochs found) mints KIND_DISPLAY_BACKEND with `backend_kind = BOCHS_STDVGA` and skips R23 fb console (or: R23 fb console re-targets to the stdvga LFB — decide at issue landing time). | `boot/kernel_main.pdx`, `driver/driver_table.pdx` | `R101 STDVGA REGISTER OK` | M | R101.M2-004, R101.M1-001 |

### R101.M3 — KIND_FRAMEBUFFER + minimal flush (5 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R101.M3-001 | `KIND_FRAMEBUFFER` (0x1AF): row table (32 rows × 32 bytes), mint gate derived over KIND_MEMORY, tail `{width, height, pitch, format, backend_slot, bo_slot_optional}`. Format enum matches KIND_DISPLAY_PLANE's fourcc-lite. | `cap/kind_framebuffer.pdx` (new), `cap/kind.pdx` | `R101 KIND_FRAMEBUFFER OK` | M | R101.M1-001 |
| R101.M3-002 | Bochs flush op invoked via KIND_FRAMEBUFFER: `fb_flush_via_backend(fb_slot)` reads the row, dispatches to `backend_flush(backend_slot, fb_va, geometry)`. On Bochs this hits R101.M2-004's dumb copy. | `graphics/fb_flush.pdx` (new) | n/a | S | R101.M3-001, R101.M2-004 |
| R101.M3-003 | Simulated 60 Hz vblank on Bochs: `_bochs_vblank_tick` runs from the existing LAPIC scheduler-tick path (like R94.M1's `tcp_poll_retransmits` hook), calls `dpy_timeline_signal_vblank` on the KIND_DISPLAY_TIMELINE the compositor holds for the Bochs output. Marked `SOURCE_SIMULATED = 3` (new value on the timeline's source enum). | `int/exceptions.pdx`, `drivers/dpy/timeline.pdx`, `cap/kind_display_timeline.pdx` | n/a | M | R101.M3-002, existing G1 substrate |
| R101.M3-004 | Registry entry in `next-wave-derived-kinds.md` for KIND_FRAMEBUFFER + rationale for why it is not KIND_GPU_BO (§4.2). | `design/architecture/next-wave-derived-kinds.md` | n/a | S | R101.M3-001 |
| R101.M3-005 | Add `SOURCE_SIMULATED` value to the KIND_DISPLAY_TIMELINE source enum documentation; keep row-encoding backward-compatible. | `cap/kind_display_timeline.pdx`, `design/architecture/next-wave-derived-kinds.md` | n/a | XS | R101.M3-003 |

### R101.M4 — Boot witness `boot_r101_stdvga` (3 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R101.M4-001 | Witness `boot_r101_stdvga_checkerboard`: mints KIND_DISPLAY_BACKEND (Bochs), allocates a KIND_FRAMEBUFFER, writes an 8x8 checkerboard of alternating (0xFF404040, 0xFFC0C0C0) into it, invokes `fb_flush_via_backend`, waits one simulated vblank tick, reads back 4 sample pixels from the LFB and asserts they match. Emits `R101 STDVGA CHECKERBOARD OK px=0x%08x`. | `boot/witness/r101_stdvga.pdx` (new) | `R101 STDVGA CHECKERBOARD OK` | M | R101.M3-002, R101.M3-003 |
| R101.M4-002 | `tools/run-qemu.sh`: add `PAIDEIA_VGA=std|virtio|none` env switch (default `none` to preserve bit-identical args for non-graphics smokes). `std` maps to `-vga std`. Mirror pattern from `PAIDEIA_NIC`. | `tools/run-qemu.sh` | n/a | S | none |
| R101.M4-003 | `tools/run-smoke.sh`: add `boot_r101_stdvga` mode setting `PAIDEIA_VGA=std`; golden file at `tests/expected-r101-stdvga.golden`. | `tools/run-smoke.sh`, `tests/expected-r101-stdvga.golden` (new) | n/a | S | R101.M4-001, R101.M4-002 |

### R101.M5 — Round closure (1 issue)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R101.M5-001 | R101 closure retrospective + STATUS.md update + tag `r101-closed`. | `design/round-retrospectives/r101-closure.md` (new) | n/a | S | all R101.M1–M4 |

**R101 total: 18 issues.**

---

## 6. R103 — virtio-gpu 2D backend

**Depends on:** R101 (KIND_DISPLAY_BACKEND, KIND_FRAMEBUFFER,
backend_dispatch, simulated-vblank precedent for the fallback path if
control-queue completion isn't available yet).

### R103.M1 — virtio-gpu probe + control queue (5 issues)

Shares the virtqueue pattern that R91.M3 will land for virtio-net.
R103.M1-001 explicitly does not extract a shared virtio-common module
in this round — that's a follow-on refactor once both virtio-net and
virtio-gpu are proven. This decision matches the R91.M3 "from-scratch,
not extend" posture.

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R103.M1-001 | `probe.pdx`: PCI vendor/device match (0x1AF4/0x1050 modern virtio-gpu-pci; 0x1AF4/0x1010 transitional), BAR discovery for modern virtio PCI capability layout (common cfg / notify / ISR / device cfg BARs per virtio 1.1 §4.1.4). | `drivers/gfx/virtio_gpu/probe.pdx` (new) | `R103 VIRTIO_GPU PROBE OK` | M | R101.M1-001, R91.M3-001 (as reference, not hard-dep) |
| R103.M1-002 | `common_cfg.pdx`: virtio common configuration accessors — mirrors R91.M3-002's shape but scoped to virtio-gpu-pci. | `drivers/gfx/virtio_gpu/common_cfg.pdx` (new) | n/a | M | R103.M1-001 |
| R103.M1-003 | Feature negotiation: negotiate `VIRTIO_GPU_F_VIRGL` (declined at R103 — 3D deferred, see §9), `VIRTIO_GPU_F_EDID` (accepted — supplies emulated EDID), `VIRTIO_GPU_F_RESOURCE_UUID` (declined — R105 concern). | `drivers/gfx/virtio_gpu/common_cfg.pdx` | n/a | S | R103.M1-002 |
| R103.M1-004 | `controlq.pdx`: split virtqueue on queue index 0 (controlq) — descriptor table + avail ring + used ring; add-request / reap-response primitives. | `drivers/gfx/virtio_gpu/controlq.pdx` (new) | n/a | L | R103.M1-002 |
| R103.M1-005 | `cursorq.pdx`: same as controlq but queue index 1 (cursor updates). Not used in this round; a minimal init keeps the queue live so the compositor's cursor path in G7 doesn't require re-init later. | `drivers/gfx/virtio_gpu/cursorq.pdx` (new) | n/a | S | R103.M1-004 |

### R103.M2 — RESOURCE + SET_SCANOUT (3 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R103.M2-001 | `resource.pdx`: `virtio_gpu_resource_create_2d(resource_id, format, width, height)` command; response parse; `virtio_gpu_resource_unref` for teardown. Resource IDs allocated from a per-backend counter (u32). | `drivers/gfx/virtio_gpu/resource.pdx` (new) | n/a | M | R103.M1-004 |
| R103.M2-002 | `backing.pdx`: `virtio_gpu_resource_attach_backing(resource_id, {pa, len}...)` — takes a KIND_MEMORY-backed page range from a KIND_FRAMEBUFFER row and hands it to the host as the resource's guest backing store. Bounds-check the PA list against the KIND_MEMORY parent's authority. | `drivers/gfx/virtio_gpu/backing.pdx` (new) | n/a | M | R103.M2-001 |
| R103.M2-003 | `scanout.pdx`: `virtio_gpu_set_scanout(scanout_id=0, resource_id, {x, y, w, h})` — binds a resource to a scanout for display. | `drivers/gfx/virtio_gpu/scanout.pdx` (new) | `R103 VIRTIO_GPU SCANOUT OK` | S | R103.M2-002 |

### R103.M3 — page-flip path via TRANSFER + FLUSH (3 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R103.M3-001 | `transfer.pdx`: `virtio_gpu_transfer_to_host_2d(resource_id, {x, y, w, h}, offset)` — carries the guest-side written pixels to the host resource. | `drivers/gfx/virtio_gpu/transfer.pdx` (new) | n/a | M | R103.M2-003 |
| R103.M3-002 | `flush.pdx`: `virtio_gpu_resource_flush(resource_id, {x, y, w, h})` — commits the resource to the on-screen surface. This is the page-flip on virtio-gpu 2D. `backend_flush` (R101.M1-002) dispatches here when `backend_kind == VIRTIO_GPU_2D`. | `drivers/gfx/virtio_gpu/flush.pdx` (new) | n/a | M | R103.M3-001 |
| R103.M3-003 | Double-buffer support at the KIND_FRAMEBUFFER layer: R101.M3's KIND_FRAMEBUFFER row grows a `pair_slot_optional` field pointing at a second KIND_FRAMEBUFFER whose contents are the alternate buffer; `backend_flush` alternates active resource IDs so the host sees a full page-flip, not a mid-frame tear. | `cap/kind_framebuffer.pdx`, `drivers/gfx/virtio_gpu/flush.pdx` | n/a | M | R103.M3-002 |

### R103.M4 — completion → KIND_DISPLAY_TIMELINE (2 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R103.M4-001 | virtio-gpu ISR (legacy INTx or MSI-X per negotiated feature): on used-ring completion for a RESOURCE_FLUSH request, call `dpy_timeline_signal_vblank` for the backend's KIND_DISPLAY_TIMELINE (source = `SOURCE_VIRTIO_COMPLETION` = 4, new value). | `drivers/gfx/virtio_gpu/isr.pdx` (new), `drivers/dpy/timeline.pdx`, `cap/kind_display_timeline.pdx` | `R103 VIRTIO_GPU FLIP DONE OK` | L | R103.M3-002 |
| R103.M4-002 | Fallback: if the host does not respond within a bounded window (e.g., 2 refresh periods), the R101.M3-003 LAPIC-tick fallback fires — keeps the compositor from wedging if virtio-gpu backend stalls. Log a klog warning first time it happens per boot. | `drivers/gfx/virtio_gpu/isr.pdx` | n/a | M | R103.M4-001 |

### R103.M5 — Boot witness (2 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R103.M5-001 | Witness `boot_r103_virtio_gpu_flip`: mints KIND_DISPLAY_BACKEND (virtio_gpu_2d), allocates a KIND_FRAMEBUFFER pair, draws frame A (solid red) into buffer 0, page-flips, waits for real virtio-gpu completion event, draws frame B (solid green) into buffer 1, page-flips again, verifies both frames were confirmed. Emits `R103 VIRTIO_GPU DOUBLE_FLIP OK n_flips=2`. | `boot/witness/r103_virtio_gpu.pdx` (new) | `R103 VIRTIO_GPU DOUBLE_FLIP OK` | L | R103.M4-001 |
| R103.M5-002 | `tools/run-smoke.sh`: add `boot_r103_virtio_gpu` mode setting `PAIDEIA_VGA=virtio`; golden file. | `tools/run-smoke.sh`, `tests/expected-r103-virtio-gpu.golden` (new) | n/a | S | R103.M5-001 |

### R103.M6 — Round closure (1 issue)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R103.M6-001 | R103 closure retrospective; note the virtio-common refactor as a follow-on ticket (do not do it in-round). | `design/round-retrospectives/r103-closure.md` (new) | n/a | S | all R103.M1–M5 |

**R103 total: 16 issues.**

---

## 7. R104 — T14 Iris Xe wire-up + page-flip cap

**Depends on:** R101.M1 (KIND_DISPLAY_BACKEND), R101.M3 (KIND_FRAMEBUFFER),
plus all R36 + R37 + G1 substrate (landed).

### R104.M1 — Boot-time Iris Xe pipeline init (4 issues)

This milestone is largely stitching, not implementation: every function
called already exists in `drivers/dpy/*.pdx` and `drivers/gpu/*.pdx`.
The gap is that nothing in `kernel_main.pdx` invokes them.

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R104.M1-001 | Call `iris_xe_probe` from `kernel_main.pdx` after PCI enumeration; verify `_pci_devices` is populated on the T14 UEFI boot path (R19 landed the ACPI/MCFG surface). Gated on `_t14_g4_present` (R28.M2's runtime flag) so QEMU boots skip. | `boot/kernel_main.pdx` | `R104 IRIS_XE PROBE OK bdf=0x%x` | M | R28.M2 (existing) |
| R104.M1-002 | Call `pwr_wells_enable` for the display power well, then `dpclk_config_program` to set CDCLK to the vendor-default frequency. | `boot/kernel_main.pdx` | `R104 IRIS_XE CDCLK OK khz=%d` | M | R104.M1-001 |
| R104.M1-003 | Mint KIND_DISPLAY_BACKEND with `backend_kind = IRIS_XE` and `provider_slot` naming the KIND_DISPLAY_ENGINE the Iris Xe probe minted. | `boot/kernel_main.pdx` | `R104 IRIS_XE BACKEND REGISTER OK` | S | R104.M1-002, R101.M1-001 |
| R104.M1-004 | Call `guc_load` + `guc_hs` (handshake) for the GT so the R37 submission path is initializable; witness only, no submission yet (that's R104.M4). | `boot/kernel_main.pdx` | `R104 GUC LOAD OK` | M | R104.M1-002 |

### R104.M2 — Modeset from best EDID mode (3 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R104.M2-001 | Call `edid_read` for each KIND_DISPLAY_OUTPUT the topology enumerator produced; select the panel's preferred timing (DTD 0 per VESA EDID 1.4 §3.10). | `boot/kernel_main.pdx`, `drivers/dpy/edid.pdx` (call-site only) | `R104 EDID READ OK w=%d h=%d hz=%d` | M | R104.M1-004 |
| R104.M2-002 | Call `mode_enum_walk` for the engine + best mode; mint a KIND_DISPLAY_MODE cap for the chosen timing over the mode-descriptor's KIND_MEMORY parent. | `boot/kernel_main.pdx` | n/a | M | R104.M2-001 |
| R104.M2-003 | Open a KIND_MODESET_TXN, call `atomic_commit_begin` → `atomic_commit_set_mode` (KIND_DISPLAY_MODE) → `atomic_commit_set_plane` (KIND_DISPLAY_PLANE primary, backed by KIND_FRAMEBUFFER whose bo_slot points at a KIND_GPU_BO allocated via `bo_alloc`) → `atomic_commit_commit`. This is the first modeset that actually programs the display engine on real T14 hardware. | `boot/kernel_main.pdx` | `R104 IRIS_XE MODESET OK` | L | R104.M2-002, R37 substrate |

### R104.M3 — vblank ISR wiring (3 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R104.M3-001 | Register the display engine's vblank IRQ vector with the R29.M1 KIND_HW_INTERRUPT + KIND_HW_MSIX_VECTOR path (Iris Xe advertises MSI-X). | `boot/kernel_main.pdx`, `drivers/dpy/hpd_isr.pdx` (as reference) | `R104 IRIS_XE VBLANK VECTOR OK` | M | R104.M1-004, R29.M1 substrate |
| R104.M3-002 | vblank ISR body: read the display engine's vblank status register, ACK the interrupt, call `dpy_timeline_signal_vblank(timeline_slot, source=SOURCE_HW_VBLANK)` where `SOURCE_HW_VBLANK = 1` (the source enum value G1.M1-003 already reserved for real hardware). | `drivers/dpy/vblank_isr.pdx` (new — separate from hpd_isr) | n/a | M | R104.M3-001 |
| R104.M3-003 | Boot witness: after modeset, poll KIND_DISPLAY_TIMELINE's `last_scanout` for 100ms; assert it advanced at least 4 times (60 Hz would produce 6 in 100ms; allow slack). Emits `R104 IRIS_XE VBLANK COUNTED n=%d`. Gated on `_t14_g4_present`. | `boot/witness/r104_vblank.pdx` (new) | `R104 IRIS_XE VBLANK COUNTED` | M | R104.M3-002 |

### R104.M4 — KIND_PAGE_FLIP capability (5 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R104.M4-001 | `KIND_PAGE_FLIP` (0x1B0) descriptor + row table (16 rows × 32 bytes) + mint gate + rights: derived over KIND_DISPLAY_OUTPUT, LINEAR (no R_MINT), tail `{output_slot, primary_plane_slot, active_fb_slot, timeline_slot, in_flight_flag}`. Rights `{R_FLIP_INVOKE, R_FLIP_REVOKE, R_FLIP_OBSERVE}`. | `cap/kind_page_flip.pdx` (new), `cap/kind.pdx` | `R104 KIND_PAGE_FLIP OK` | L | R104.M2-003 |
| R104.M4-002 | Page-flip op `OP_FLIP_SUBMIT(fb_slot, target_timeline_val)`: validates fb_slot names a KIND_FRAMEBUFFER of matching geometry + format for the plane; updates the plane's backing to point at fb_slot; sets `in_flight_flag = 1`. Returns immediately. Backend-neutral: dispatches to `backend_page_flip(backend_slot, ...)` which vectors to R101.M2-004 / R104.M3-002 / R104.M4-004 as appropriate. | `cap/kind_page_flip.pdx`, `graphics/backend_dispatch.pdx` | n/a | L | R104.M4-001 |
| R104.M4-003 | Page-flip op `OP_FLIP_QUERY(expected_timeline_val)`: returns 1 if timeline has reached the expected value (i.e., the flip completed), 0 otherwise. This is the non-blocking check the `sys_page_flip_wait` syscall (R104.M3) will build on. | `cap/kind_page_flip.pdx` | n/a | M | R104.M4-002 |
| R104.M4-004 | Iris Xe `backend_page_flip` implementation: writes the plane's `SURF_LIVE` register through the display engine's MMIO window; atomic w.r.t. vblank (the display engine latches SURF at vblank, hardware-enforced). | `drivers/dpy/plane_primary.pdx` (extended) | n/a | L | R104.M4-002, R36 substrate |
| R104.M4-005 | Composition with KIND_SCANOUT_LEASE (G2): document + enforce that a plane held under a KIND_SCANOUT_LEASE cannot simultaneously be the primary_plane_slot of an active KIND_PAGE_FLIP; the second mint refuses with `FLIP_MINT_PLANE_LEASED`. Same discipline G2 uses for the reserved-console plane invariant. | `cap/kind_page_flip.pdx`, `cap/kind_scanout_lease.pdx` (call-site only) | n/a | M | R104.M4-001, G2 substrate |

### R104.M5 — Multi-scanout (external DP over TB) (3 issues)

R35 landed KIND_TB_DOMAIN + Thunderbolt Alt-Mode DP substrate. An
external display attached over TB minted its own KIND_DISPLAY_OUTPUT
row at G1 landing (per topology.pdx), but no KIND_PAGE_FLIP was ever
minted for it because the whole page-flip cap didn't exist.

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R104.M5-001 | Iterate every KIND_DISPLAY_OUTPUT the topology walker produced (built-in + any TB-DP attached); mint one KIND_PAGE_FLIP per output. | `boot/kernel_main.pdx` | `R104 MULTI_SCANOUT n=%d` | M | R104.M4-001, R35 substrate |
| R104.M5-002 | Verify at boot that each output's KIND_DISPLAY_TIMELINE advances independently (the vblank ISR gets the per-output timeline_slot from the vector's context, not a global). | `drivers/dpy/vblank_isr.pdx` | n/a | M | R104.M3-002, R104.M5-001 |
| R104.M5-003 | Update `design/graphics/multi-scanout-topology.md` (new doc): naming ("scanout 0 is always the built-in panel; TB outputs are enumerated in HPD order"), invariants ("output 0's plane 0 is the reserved recovery console per P8 — G2 already encodes this"). | `design/graphics/multi-scanout-topology.md` (new) | n/a | S | R104.M5-002 |

### R104.M6 — T14 boot witness (2 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R104.M6-001 | Witness `boot_r104_iris_xe_flip`: mints a KIND_PAGE_FLIP against output 0, allocates two KIND_FRAMEBUFFER pair rows, page-flips at 60 Hz for 30 frames alternating red/green, asserts each flip completes within one vblank interval (queried via KIND_DISPLAY_TIMELINE). Gated on `_t14_g4_present`. Emits `R104 IRIS_XE FLIP LIVE OK n_flips=30`. | `boot/witness/r104_iris_xe.pdx` (new) | `R104 IRIS_XE FLIP LIVE OK` | L | R104.M4-004, R104.M3-002 |
| R104.M6-002 | Wire into `run-smoke.sh` as `boot_r104_iris_xe` — because this witness is T14-gated, the smoke mode is a no-op on QEMU and prints `R104 IRIS_XE SKIP not-t14` instead of running. Golden fixture accepts either the SKIP or the OK line. | `tools/run-smoke.sh`, `tests/expected-r104-iris-xe.golden` (new) | n/a | S | R104.M6-001 |

### R104.M7 — Round closure (1 issue)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R104.M7-001 | R104 closure retrospective. Explicitly document the Vello + G3 swapchain wire-up as a follow-on round (not R104 scope — see §9's coordination with softarch). | `design/round-retrospectives/r104-closure.md` (new) | n/a | S | all R104.M1–M6 |

**R104 total: 21 issues.**

---

## 8. R105 — Compositor syscall surface + hotplug + boot witnesses

**Depends on:** R101–R104.

### R105.M1 — `sys_display_enumerate` (2 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R105.M1-001 | `sys_display_enumerate(out_ptr, cap)` (sysno 108): copies a bounded array of `{backend_slot, output_slot, timeline_slot, mode_desc_ptr}` tuples into user memory, one per active output. Returns count. Requires `R_DISPLAY_ENUMERATE` right on the calling task (a boot-supervisor grants this to the compositor process at spawn). | `syscall/handlers/sys_display_enumerate.pdx` (new), `syscall/dispatch.pdx` | `R105 sys_display_enumerate OK n=%d` | M | R105.M5-001 |
| R105.M1-002 | Update `design/user/syscall-table.md`: rows 108, plus block-header note "108-113 reserved for R105 display syscalls." | `design/user/syscall-table.md` | n/a | S | R105.M1-001 |

### R105.M2 — `sys_framebuffer_create` + `sys_framebuffer_map` (3 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R105.M2-001 | `sys_framebuffer_create(width, height, format, backend_slot, out_cap_slot)` (sysno 109): allocates a KIND_MEMORY page range for the pixel buffer (via existing phys-alloc), mints a KIND_FRAMEBUFFER over it referring to `backend_slot`. Bounds-check `(width, height)` against the backend's advertised max. | `syscall/handlers/sys_framebuffer_create.pdx` (new) | n/a | M | R101.M3-001 |
| R105.M2-002 | `sys_framebuffer_map(fb_cap_slot, out_va_ptr, out_size_ptr)` (sysno 110): maps the fb's backing KIND_MEMORY into the caller's address space at a WC-mapped VA (PAT slot 4). Returns VA + total byte size. Requires `R_FB_MAP` right on the KIND_FRAMEBUFFER cap. | `syscall/handlers/sys_framebuffer_map.pdx` (new) | n/a | L | R105.M2-001 |
| R105.M2-003 | Rights on KIND_FRAMEBUFFER: `R_FB_MAP`, `R_FB_FLIP` (needed to submit into a KIND_PAGE_FLIP), `R_FB_REVOKE`. The compositor mints per-client framebuffers with `R_FB_MAP` only (client can write pixels but cannot flip directly); the compositor keeps `R_FB_FLIP` for itself. | `cap/kind_framebuffer.pdx` | n/a | M | R105.M2-001 |

### R105.M3 — `sys_page_flip` + `sys_page_flip_wait` (3 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R105.M3-001 | `sys_page_flip(flip_cap_slot, fb_cap_slot, target_timeline_val)` (sysno 111): invokes `OP_FLIP_SUBMIT` on the KIND_PAGE_FLIP behind `flip_cap_slot`, passing `fb_cap_slot` and `target_timeline_val`. Non-blocking. Requires `R_FLIP_INVOKE` + `R_FB_FLIP`. | `syscall/handlers/sys_page_flip.pdx` (new) | n/a | M | R105.M4-002 |
| R105.M3-002 | `sys_page_flip_wait(flip_cap_slot, expected_timeline_val, timeout_ns)` (sysno 112): blocks (via `sched/wake_block.pdx`, same primitive `sys_accept` uses per R94.M4) until the timeline reaches `expected_timeline_val` or the timeout elapses. Returns 0 on completion, `-ETIMEDOUT`, or `-errno`. | `syscall/handlers/sys_page_flip_wait.pdx` (new), `sched/wake_block.pdx` | n/a | L | R105.M3-001 |
| R105.M3-003 | Wake-side hookup: `dpy_timeline_signal_vblank` (already exists per G1) is extended to walk any KIND_PAGE_FLIP rows whose `timeline_slot` matches the just-advanced timeline and wake any `sys_page_flip_wait` blockers. `poll` (R95.M3) also sees the readiness change. | `drivers/dpy/timeline.pdx`, `sched/wake_block.pdx` | n/a | M | R105.M3-002, R95.M3 |

### R105.M4 — KIND_HOTPLUG_CHANNEL + `sys_display_hotplug_subscribe` (3 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R105.M4-001 | `KIND_HOTPLUG_CHANNEL` (0x1B1) descriptor + row table (4 rows: T14 has at most 4 outputs) + mint gate + rights: derived over KIND_IPC_ENDPOINT, one row per backend, LINEAR. Rights `{R_HP_OBSERVE, R_HP_REVOKE}`. | `cap/kind_hotplug_channel.pdx` (new), `cap/kind.pdx` | `R105 KIND_HOTPLUG_CHANNEL OK` | M | R101.M1-001 |
| R105.M4-002 | HPD ISR wiring: existing `drivers/dpy/hpd_isr.pdx` fans events into the KIND_HOTPLUG_CHANNEL's IPC endpoint (event shape `{output_slot, event = CONNECT|DISCONNECT|MODE_CHANGE, timestamp_ns}`). On QEMU (no HPD), the backend synthesizes one initial CONNECT event at boot per active output. | `drivers/dpy/hpd_isr.pdx` (extended), `drivers/gfx/bochs_stdvga/*.pdx`, `drivers/gfx/virtio_gpu/*.pdx` | n/a | L | R105.M4-001 |
| R105.M4-003 | `sys_display_hotplug_subscribe(backend_slot, out_channel_cap_slot)` (sysno 113): mints a KIND_HOTPLUG_CHANNEL for the backend and delivers the cap to the caller. Only one subscriber per backend (the compositor). Second subscribe returns `-EBUSY`. | `syscall/handlers/sys_display_hotplug_subscribe.pdx` (new) | n/a | M | R105.M4-002 |

### R105.M5 — Security posture (2 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R105.M5-001 | Design doc `design/graphics/authority-boundary.md`: states the invariant "the compositor holds KIND_DISPLAY_BACKEND + KIND_PAGE_FLIP + KIND_HOTPLUG_CHANNEL for every output; app clients never hold any of these. App clients receive per-client KIND_FRAMEBUFFER caps with `R_FB_MAP` only (draw, but cannot flip); the compositor's own copy holds `R_FB_FLIP` and pages the client's buffer through its own page-flip." Enumerates the four attack shapes this defends against (fb address forging, timeline hijack, hotplug spoof, cross-client scan-out read). | `design/graphics/authority-boundary.md` (new) | n/a | M | R105.M2, R105.M3, R105.M4 |
| R105.M5-002 | Enforcement audit: verify at R105.M5 close that no cap-mint path in the tree hands `R_FB_FLIP` or a KIND_PAGE_FLIP to a non-compositor process. Report is issue output (`design/audit/entries/r105-authority-audit.md`); may prompt fixes if any leak found. | `design/audit/entries/r105-authority-audit.md` (new) | n/a | M | R105.M5-001 |

### R105.M6 — End-to-end boot witness (3 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R105.M6-001 | User-space program `boot_r105_flip_client`: opens sys_display_enumerate, picks output 0, calls sys_framebuffer_create + sys_framebuffer_map, draws a gradient, calls sys_page_flip + sys_page_flip_wait, repeats 10 times. First user-space consumer of any display syscall. | `src/user/boot_r105_flip_client/main.pdx` (new) | `R105 FLIP CLIENT DONE OK n=10` | L | R105.M3-002, R105.M2-002, R105.M1-001 |
| R105.M6-002 | Boot witness wraps the user-space program: spawns it as a task, waits, asserts fingerprint. Runs under `PAIDEIA_VGA=std` (uses R101 Bochs backend) and `PAIDEIA_VGA=virtio` (uses R103) — one witness, two smoke modes. | `boot/witness/r105_flip_client.pdx` (new) | `R105 FLIP CLIENT WITNESS OK backend=%s` | M | R105.M6-001 |
| R105.M6-003 | Wire into `run-smoke.sh` as `boot_r105_flip_client_std` + `boot_r105_flip_client_virtio`; both goldens. Third mode `boot_r105_flip_client_t14` runs on real T14, T14-gated skip on QEMU. | `tools/run-smoke.sh`, `tests/expected-r105-flip-client-{std,virtio,t14}.golden` (new) | n/a | S | R105.M6-002 |

### R105.M7 — Round closure + STATUS.md update (1 issue)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R105.M7-001 | R105 closure retrospective + STATUS.md update (add "R101 + R103–R105 graphics substrate: LANDED"); tag `r105-closed`; note that G7 (compositor service) is now unblocked. | `design/round-retrospectives/r105-closure.md` (new), `STATUS.md` | n/a | S | all R105.M1–M6 |

**R105 total: 17 issues.**

---

## 9. New KIND ordinals (§4 anchor)

Reservation block: `0x1AE` and up. The R91-R99 wave reserved through
`0x1AD` (`0x1A8` KIND_UDP_SOCKET, `0x1A9` KIND_PACKET_FILTER, `0x1AA`
KIND_TLS_CONN, `0x1AB` KIND_TCP_SOCKET, `0x1AC` KIND_TCP_LISTENER,
`0x1AD` KIND_NIC), so `0x1AE` is next free (grep-verified against
`src/kernel/core/cap/kind.pdx`).

| Tag | Name | Base | Round | Rights | Rationale |
|---|---|---|---|---|---|
| `0x1AE` | `KIND_DISPLAY_BACKEND` | `KIND_DEVICE = 10` | R101.M1 | `R_BE_INVOKE (query mode/geometry) + R_BE_MINT (derive OUTPUT / HOTPLUG_CHANNEL) + R_BE_REVOKE + R_BE_OBSERVE` | §4.1: the multi-backend anchor (Bochs / virtio-gpu / Iris Xe) so downstream cap shapes stay uniform. |
| `0x1AF` | `KIND_FRAMEBUFFER` | `KIND_MEMORY = 4` | R101.M3 | `R_FB_MAP (map into a VA) + R_FB_FLIP (submit into a PAGE_FLIP) + R_FB_REVOKE + R_FB_OBSERVE` | §4.2: a scan-out-shaped buffer that does NOT require a GPU VM (so QEMU Bochs works without a stub GPU). Distinct from KIND_GPU_BO because on Iris Xe it optionally points at one; on Bochs the optional slot is 0. |
| `0x1B0` | `KIND_PAGE_FLIP` | `KIND_DISPLAY_OUTPUT = 0x170` (base = KIND_DEVICE) | R105.M4 | `R_FLIP_INVOKE + R_FLIP_REVOKE + R_FLIP_OBSERVE` (no R_MINT — LINEAR) | §4.3: the compositor's per-output swap-and-await authority. Distinct from KIND_SCANOUT_LEASE (fullscreen-client bypass) and KIND_MODESET_TXN (per-mode-change, not per-frame). |
| `0x1B1` | `KIND_HOTPLUG_CHANNEL` | `KIND_IPC_ENDPOINT = 5` | R105.M4 | `R_HP_OBSERVE + R_HP_REVOKE` (no R_MINT — one subscriber per backend) | §R105.M4: HPD event stream the compositor subscribes to. Not a fake polling loop. |

Reserved for G7+ (not this wave): `0x1B2..0x1BF` band left open for
KIND_SURFACE, KIND_WINDOW, KIND_LAYER_TREE (G7 planning), KIND_INPUT_ROUTE
(G8 planning). No block-level reservation is made here — G7 will pick
its own ordinals when it plans.

---

## 10. New syscalls

Reservation block: sysnos `108..113`. Contiguous with the last allocated
sysno (107 `sys_pdxfs_undo_write` per R90-XREPO.010.M1-004), preserving
the switch-dispatch grouping discipline. sysnos 96–102 remain reserved
for the R91–R99 networking wave; sysno 103 is `sys_icmp_echo`; sysnos
104–107 are pdxfs; sysno 108 is the first free slot.

| Sysno | Name | Args | Round | Return |
|---|---|---|---|---|
| 108 | `sys_display_enumerate` | `out_ptr`, `cap` | R105.M1 | count of outputs written, or `-errno`. Requires `R_DISPLAY_ENUMERATE` on the calling task. |
| 109 | `sys_framebuffer_create` | `width`, `height`, `format`, `backend_slot`, `out_cap_slot` | R105.M2 | 0 or `-errno`; mints a KIND_FRAMEBUFFER at `out_cap_slot`. |
| 110 | `sys_framebuffer_map` | `fb_cap_slot`, `out_va_ptr`, `out_size_ptr` | R105.M2 | 0 or `-errno`; writes VA + size to user pointers. Requires `R_FB_MAP`. |
| 111 | `sys_page_flip` | `flip_cap_slot`, `fb_cap_slot`, `target_timeline_val` | R105.M3 | 0 or `-errno`; non-blocking submit. Requires `R_FLIP_INVOKE` on the flip cap AND `R_FB_FLIP` on the fb cap. |
| 112 | `sys_page_flip_wait` | `flip_cap_slot`, `expected_timeline_val`, `timeout_ns` | R105.M3 | 0 on completion, `-ETIMEDOUT`, or `-errno`. Blocking. Wakes on `dpy_timeline_signal_vblank`. |
| 113 | `sys_display_hotplug_subscribe` | `backend_slot`, `out_channel_cap_slot` | R105.M4 | 0 or `-errno`; mints a KIND_HOTPLUG_CHANNEL at `out_channel_cap_slot`. `-EBUSY` if another subscriber already exists. |

Update to `design/user/syscall-table.md`: R105.M1-002 adds rows 108-113
and a block-header note "108–113 reserved for R101 + R103–R105 display syscalls;
future compositor + input rounds (G7-G9) will allocate above."

---

## 11. Boot witnesses per milestone (§6-§8 anchor)

| Round | Milestone | Witness | Fingerprint | Smoke mode |
|---|---|---|---|---|
| R101 | M4 | `boot_r101_stdvga_checkerboard` | `R101 STDVGA CHECKERBOARD OK` | `boot_r101_stdvga` (`PAIDEIA_VGA=std`) |
| R103 | M5 | `boot_r103_virtio_gpu_flip` | `R103 VIRTIO_GPU DOUBLE_FLIP OK` | `boot_r103_virtio_gpu` (`PAIDEIA_VGA=virtio`) |
| R104 | M3 | `boot_r104_vblank` | `R104 IRIS_XE VBLANK COUNTED n=%d` | `boot_r104_vblank` (T14-gated; `SKIP not-t14` on QEMU) |
| R104 | M6 | `boot_r104_iris_xe_flip` | `R104 IRIS_XE FLIP LIVE OK n_flips=30` | `boot_r104_iris_xe` (T14-gated) |
| R105 | M6 | `boot_r105_flip_client` | `R105 FLIP CLIENT WITNESS OK backend=%s` | `boot_r105_flip_client_{std,virtio,t14}` |

Every fingerprint is single-line, single-tag, `... ok` shape matching
existing house style (`grep -RIn 'CHECKERBOARD\|FLIP\|VBLANK'` returns
no prior collisions — verified against `src/kernel/`).

---

## 12. Dependencies on paideia-as (cross-repo)

Every item listed here is a candidate for a cross-repo issue against
paideia-as, matching the `[[feedback-cross-repo-escalation]]` discipline.
None of these are known-blocking today; each is a "verify before assuming"
per the discipline `[[feedback-workerbee-verify-claims]]` requires.

1. **VBE-DISPI I/O port access** (R101.M2-002). `in`/`out` r8/r16 to
   port 0x1CE (index) + 0x1CF (data) is required by the Bochs
   modeset path. paideia-as CHANGELOG has no entry mentioning `in`/`out`
   instructions; a probe issue against `tools/paideia-as/` should
   confirm they are encodable. If not, file the encoder issue there
   FIRST, land the encoder + version bump, then unblock R101.M2-002.
   MMIO fallback (BAR2 on modern QEMU stdvga) is viable if `in`/`out`
   is not available in a reasonable timeframe — R101.M2-002's scope
   note flags the choice at issue open.
2. **`@jump_table` attribute for backend_dispatch** (R101.M1-002).
   Identical concern to R91.M1-002. Verify the attribute is lowered,
   not just forward-declared; fall back to a compare chain otherwise.
3. **virtio-gpu control-queue command shapes are little-endian packed
   structures** (R104.M2-001). paideia-as has u16 / u32 / u64 sized
   MMIO stores per the R23 fb wire-up (`mov_d`/`mov_w`/`mov_b`), but
   the response-parsing side may need explicit sign-extension /
   zero-extension patterns. Verify at R104.M2-001 open; file if needed.
4. **PCI capability list walker** (R101.M2-001, R104.M1-001). Both new
   drivers walk the PCI extended capability list to find MSI-X /
   virtio-modern config space. R91.M3 (virtio-net) has the same
   dependency — coordinate reuse. If R91.M3 lands a shared PCI
   capability walker, R101/R103 consume it; if not, R101.M2-001 lands
   it first and R91.M3 consumes.
5. **Nothing about the display path requires a new paideia-as
   intrinsic** (unlike the R91 crypto-suite gap for TLS). The
   Vello/color/GPU-compute path is R37-substrate-consumed and Vello
   is written in paideia-as against existing encoder capabilities.

---

## 13. Deferred sub-scopes (explicitly out of R101 + R103–R105)

| Deferred | Reason |
|---|---|
| **3D acceleration (Virgl / Vulkan-over-virtio-gpu)** | `VIRTIO_GPU_F_VIRGL` is declined at R103.M1-003. G3 already landed `VK_paideia_surface` + swapchain against a hypothetical GPU submit; wiring that to virtio-gpu 3D adds two more virtio queues (venus / cursor + a 3D command stream), a shader translation layer, and negotiation of the 3D feature bit. Big enough to be its own round; not blocking a compositor from painting 2D. |
| **Video decode acceleration (VCS engine + HEVC path)** | R37 landed the VCS engine substrate and G4 landed HEVC frame primitive, but no user-facing codec cap or syscall exists. Meaningful only after G7 compositor + a media-playback userland exists. Defer to a "media codec round" post-G9. |
| **Vello wire-up against a real submit** | Blocked on this round (R101 + R103–R105 provides the substrate Vello would submit against). Once R104.M4 lands, a follow-on "Vello live" round can flow the Vello pipeline against real GT. Explicitly noted in R104.M7 closure retrospective. |
| **Multi-monitor extended desktop with per-monitor scaling** | R104.M5 lands multi-scanout at the *substrate* level (multiple KIND_PAGE_FLIP + KIND_DISPLAY_TIMELINE per output). Per-monitor scaling factors are compositor concerns (G7 / G9), not kernel. |
| **HDCP negotiation** | Content-protection is an entire negotiation protocol between the display engine and the sink. R36 output kind reserves the substrate but no HDCP FSM lands here. Content-protection commitments are a policy question the OS has not answered yet. |
| **DP-MST multi-stream fanout** | KIND_DISPLAY_OUTPUT names the DP-MST wire protocol but the multi-stream transport layer is not implemented. A single-stream DP link is what R104 wires; multi-stream (a single DP output driving three chained monitors) is a follow-on. |
| **Backlight control on QEMU** | Backlight is meaningless on QEMU (no panel). G6 landed backlight_dpaux + backlight_pwm for T14; those get wired into R104.M2 modeset path only if trivial; otherwise flagged as R104.M2 follow-on. |
| **HDR direct-scanout beyond G6** | G6.M3 landed HDR10 direct-scanout substrate. R101 + R103–R105 does not extend it; a compositor holding a KIND_PAGE_FLIP can pass an HDR framebuffer through if the panel supports it (validated at plane commit), but the wider HDR tone-mapping pipeline is G6-final. |
| **Cursor plane hot-path acceleration** | R36.M4 landed the plane_cursor.pdx substrate. R101 + R103–R105 treats the cursor as just another plane (via KIND_DISPLAY_PLANE). Hot-path cursor moves (60 Hz to 240 Hz cursor updates without a full page-flip) are a G7 or G8 concern. |
| **Screen capture cap** | G7 planned. Not this wave. |
| **Migration of NIC / display drivers to the userspace-process model** | Same rationale as R91 §4.2. Big architecture change; not this wave. |
| **`design/network/` vs `design/networking/` reconciliation** | Two directories exist ([[project-paideiaos-networking-r91-r99]]). R101 + R103–R105 uses `design/graphics/` consistently — no equivalent pre-existing `design/graph/` corpus, so no reconciliation debt. |

---

## 14. Coordination with the softarch compositor design

The sibling softarch wave designs G7's compositor service + window
manager + client toolkit + event routing + satellite repos. The line
between the two waves is the syscall boundary defined in §10.

**Compositor invokes (per output, per frame):**
- `sys_display_enumerate` — once at startup + on every KIND_HOTPLUG_CHANNEL event
- `sys_framebuffer_create` — one per output at startup, plus per-client on connect
- `sys_framebuffer_map` — same shape as `sys_framebuffer_create`
- `sys_page_flip` — every frame per output (nominal ~60 Hz)
- `sys_page_flip_wait` — every frame (paired)
- `sys_display_hotplug_subscribe` — once at startup per backend

**Compositor holds:**
- One KIND_DISPLAY_BACKEND per active backend (typically 1)
- One KIND_DISPLAY_OUTPUT per scanout (1 on QEMU, 1–4 on T14)
- One KIND_DISPLAY_MODE per output (per active mode)
- One KIND_DISPLAY_TIMELINE per output
- One KIND_PAGE_FLIP per output
- One KIND_HOTPLUG_CHANNEL per backend
- One KIND_DISPLAY_PLANE per plane per output (primary + optional overlay + optional cursor)
- N KIND_FRAMEBUFFER for its own compositing pass + per-client buffers it draws from

**Compositor delegates to clients:**
- KIND_FRAMEBUFFER with `R_FB_MAP` only (draw, cannot flip)
- KIND_SCANOUT_LEASE (fullscreen bypass; G2 substrate; compositor grants, client presents directly) — this is P7's "direct-scanout is default for fullscreen." Compositor policy chooses when to lease.
- KIND_IPC_ENDPOINT (the compositor↔client conversation channel; G7 scope)

**Cap operations the compositor never invokes (kernel-internal or non-compositor):**
- KIND_GPU_BO mint (allocator-only)
- KIND_GPU_VM mint (per GPU-process, not per compositor)
- KIND_MODESET_TXN — held during a mode-change, not per-frame; compositor may open one on hotplug / mode-change flow via a follow-on syscall (not this wave; noted as R105-follow-on)
- KIND_DISPLAY_ENGINE — kernel-internal, minted by iris_xe_probe

**Event channels the compositor subscribes to:**
- KIND_HOTPLUG_CHANNEL (backend-level HPD stream)
- KIND_DISPLAY_TIMELINE (per-output vblank counter) — read-only via `sys_page_flip_wait` semantics; no separate subscribe syscall
- Input events — G8 scope

**What softarch's sibling doc should NOT invent:**
- A parallel display-authority story (kernel is the source of truth)
- A parallel page-flip mechanism (only KIND_PAGE_FLIP + `sys_page_flip{,_wait}`)
- A separate compositor-side timeline abstraction (KIND_DISPLAY_TIMELINE is the source of truth for vblank; a compositor may present its own logical presentation timeline built on top, but the ground truth is the kernel's)
- A separate hotplug mechanism (only KIND_HOTPLUG_CHANNEL)

**What softarch's sibling doc SHOULD address (not this wave):**
- Compositor process supervision + restart FSM
- Client protocol schema (`KIND_SURFACE_COMMIT` per G7 planning)
- Window / layer tree model (G7)
- Input router service (G8)
- Damage tracking + buffer-age semantics (G7 / G9)
- Screen capture cap (G7)
- Workspaces + tiling (G9)

---

## 15. Round-summary table

| Round | Milestones | Issues | New KINDs | New syscalls | QEMU witnesses | T14 witnesses |
|---|---|---|---|---|---|---|
| R101 | 5 | 18 | 2 (BACKEND, FRAMEBUFFER) | 0 | 1 (stdvga checkerboard) | 0 |
| R103 | 6 | 16 | 0 (extends timeline source enum) | 0 | 1 (double flip) | 0 |
| R104 | 7 | 21 | 1 (PAGE_FLIP) | 0 | 0 | 2 (vblank + iris_xe flip) |
| R105 | 7 | 17 | 1 (HOTPLUG_CHANNEL) | 6 (108-113) | 2 (flip client on std + virtio) | 1 (flip client on t14) |
| **Total** | **25** | **72** | **4** | **6** | **4** | **3** |

---

## 16. References

- `design/architecture/next-wave-derived-kinds.md` — KIND registry.
  Extended by R101.M1-004, R101.M3-004, R105.M4-001, R105.M4-001.
- `design/networking/r91-plan.md` — template this document follows;
  reserves sysnos 96-102 and KIND ordinals 0x1A8-0x1AD.
- `design/roadmap/next-wave-softarch.md` §G1..G9 — the G-series graphics
  initiative roadmap. G1–G6 substrate landed; G7–G9 remain. §1 above
  reconciles R101 + R103–R105 numbering with the G-series.
- `design/user/syscall-table.md` — extended by R105.M1-002 with rows
  108–113.
- `src/kernel/core/cap/kind_display_engine.pdx` — R36.M1 (0x16F).
- `src/kernel/core/cap/kind_display_output.pdx` — R36.M2 (0x170).
- `src/kernel/core/cap/kind_modeset_txn.pdx` — R36.M3 (0x171).
- `src/kernel/core/cap/kind_display_mode.pdx` — R36.M3 (0x172).
- `src/kernel/core/cap/kind_display_plane.pdx` — R36.M4 (0x173).
- `src/kernel/core/cap/kind_gpu_{bo,vm,context,submit}.pdx` — R37 (0x174-0x177).
- `src/kernel/core/cap/kind_display_timeline.pdx` — G1 (0x185).
- `src/kernel/core/cap/kind_vrr_range.pdx` — G1 (0x186).
- `src/kernel/core/cap/kind_scanout_lease.pdx` — G2 (0x188).
- `src/kernel/core/cap/kind_vk_{surface,swapchain_image}.pdx` — G3 (0x189, 0x18A).
- `src/kernel/core/drivers/{dpy,gpu,vello,text,color}/*.pdx` — R36+R37+G1..G6 driver substrate.
- `src/kernel/core/drivers/{fb_map,fb_font,fb_glyph,fb_console}.pdx` — R23 GOP fb console (T14 only today).
- `src/kernel/boot/kernel_main.pdx` — grep-verified 2026-09-01: no
  call to any R36/R37/G1-G6 substrate.
- `tools/run-qemu.sh` — `-display none`, no `-vga` flag; R101.M4-002
  adds `PAIDEIA_VGA` env switch.
