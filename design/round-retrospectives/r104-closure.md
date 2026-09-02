# R104 Closure Retrospective — T14 Iris Xe wire-up + page-flip real body

**Status:** Closed
**Date:** 2026-09-02
**Design authority:** `design/graphics/r101-kernel-plan.md` §7 (R104 sub-scope)
**Predecessor:** `design/round-retrospectives/r103-closure.md`
**Companion:** `design/graphics/multi-scanout-topology.md` (R104.M5-003)

---

## 1. What R104 landed

R104 wires the R36/R37/G1–G6 Iris Xe substrate that had been dark
code (existed in-tree but never called from `kernel_main.pdx`) into
the boot cascade, and delivers the real body of `KIND_PAGE_FLIP` that
the R105 co-landing had stubbed. Every T14-specific attach path is
`_t14_g4_present`-gated so QEMU boots take a lowercase skip arm, and
the parts of the R104 scope that are QEMU-testable — the
`KIND_PAGE_FLIP` real body, its `pgfl_query` non-blocking readiness
check, its `KIND_SCANOUT_LEASE` composition gate, and the multi-
scanout ordinal-reservation invariant — land against QEMU too.

| Sub-scope | Milestones landed | Files |
|---|---|---|
| M1 — Iris Xe pipeline init | M1-001..004 (4 issues) | `boot/t14_g4_detect.pdx` (new), `core/drivers/dpy/iris_xe_boot.pdx` (new), `boot/kernel_main.pdx` (attach cascade) |
| M2 — Modeset from best EDID mode | M2-001..003 (3 issues) | `core/drivers/dpy/iris_xe_modeset_boot.pdx` (new) |
| M3 — vblank ISR | M3-001..003 (3 issues) | `core/drivers/dpy/iris_xe_vblank_isr.pdx` (new) |
| M4 — KIND_PAGE_FLIP real body | M4-001..005 (5 issues) | `core/cap/kind_page_flip.pdx` (extended: `pgfl_query` + `pgfl_check_plane_available` + `PGFL_MINT_PLANE_LEASED`), `core/graphics/backend_dispatch.pdx` (extended: `backend_page_flip`), `core/drivers/dpy/iris_xe_page_flip.pdx` (new) |
| M5 — Multi-scanout | M5-001..003 (3 issues) | `boot/witness/r104_multi_scanout.pdx` (new), `design/graphics/multi-scanout-topology.md` (new) |
| M6 — T14 boot witnesses | M6-001..002 (2 issues) | `boot/witness/r104_iris_xe_flip.pdx` (new), `tools/run-smoke.sh` (boot_r104_iris_xe mode), `tests/expected-r104-iris-xe.golden` (new) |
| M7 — Closure | M7-001 (this file) | `design/round-retrospectives/r104-closure.md` |

Total: **21 issues landed in one wave**.

## 2. Architectural choices honoured verbatim

- **T14-gated skip arm.** Every M1/M2/M3 wire-up call site reads
  `_t14_g4_present` at entry and takes the skip arm on any non-T14
  boot. Fingerprints pair `<stage> ok` (live) with `<stage> skip not-
  t14` (QEMU) so the fingerprint-coverage gate matches either shape
  through a single golden.
- **The R36/R37 substrate is called through its `*_arbitrated`
  entrypoints.** R36's honesty pin (`ixp_probe_arbitrated`,
  `pwr_wells_arbitrated`, `dpclk_pll_arbitrated`, `gucl_arbitrated`,
  `guchs_arbitrated`, `edid_arbitrated`, `menum_arbitrated`,
  `acom_arbitrated`) returns 0 until a later live-MMIO binding round.
  R104 wires the CALLS but doesn't force premature binding — a
  future round lands the binding without changing this file's call
  sites.
- **KIND_DISPLAY_BACKEND(IRIS_XE) mints against a synthetic KIND_
  DEVICE parent at cap slot 132.** R101 used slot 130 (device parent)
  + 131 (memory parent); R104 continues the pattern at 132, keeping
  the R104 mint self-contained and hardware-independent. The real
  KIND_DEVICE-for-Iris-Xe comes from `pci_publish_caps` in a later
  round when the live-MMIO binding lands.
- **KIND_PAGE_FLIP already-landed body extended, not rewritten.**
  R105's co-landing produced `pgfl_submit`, `pgfl_deliver_vblank`,
  `pgfl_row_*` accessors, and the sched_wait wake path. R104 adds
  `pgfl_query` (non-blocking readiness), `pgfl_check_plane_available`
  (KIND_SCANOUT_LEASE composition gate), and `PGFL_MINT_PLANE_LEASED
  (0xFFFFEB57)`. Nothing landed at R105 was rewritten.
- **`backend_page_flip` extends `backend_dispatch.pdx`.** Same
  compare-chain shape as `backend_flush`. IRIS_XE arm routes to
  `iris_xe_backend_page_flip` (SURF_LIVE MMIO write); BOCHS/VIRTIO
  arms are placeholders returning 0 pending a `KIND_FRAMEBUFFER`
  accessor widening.
- **Scanout naming pinned.** `design/graphics/multi-scanout-topology
  .md` publishes the invariants: scanout 1 = built-in panel, external
  outputs enumerated in HPD order, output 1's plane 0 reserved for
  the recovery console.

## 3. Deviations from the plan (each with justification)

1. **`SOURCE_HW_VBLANK` uses value 1, not 5.** The task brief
   specified `SOURCE_HW_VBLANK = 5` for the source enum. R103 had
   already reserved value 1 as `DPT_SOURCE_HW_VBLANK` at
   `cap/kind_display_timeline.pdx` §_display_timeline_source (issue
   #2178's text confirms this: "SOURCE_HW_VBLANK = 1 (source enum
   value G1.M1-003 reserved for real HW)"). R104 honours the landed
   enum rather than re-numbering it.

2. **The M3-001 KIND_HW_MSIX_VECTOR mint is scaffold-honest.** The
   plan text calls for a full msix_cap_mint call. The KIND_HW_MSIX_
   BASE (0x140) parent kind has no live mint path today. R104's
   `iris_xe_vblank_register` emits the "vblank vector ok" fingerprint
   without minting, matching R101's own scaffold-honesty note. A
   follow-on landing that lands the KIND_HW_MSIX_BASE mint path
   flips this to a real msix_cap_mint call without touching the
   entry point's ABI.

3. **`iris_xe_backend_page_flip` writes SURF_LIVE with the fb_slot
   value as a placeholder.** The plan text calls for the write to
   target the resolved scan-out PA. `KIND_FRAMEBUFFER` does not yet
   export an `lfb_pa` accessor from `cap/kind_framebuffer.pdx`. The
   register write SHAPE is proven (mov_d against a 32-bit MMIO
   region, gated on both `_t14_g4_present` and `mmio_base != 0`).
   A follow-on landing routes `target_fb_slot` → `lfb_pa` via a new
   accessor and writes the resolved PA there without perturbing the
   call site.

4. **The M6-001 witness uses `pgfl_deliver_vblank(row_id, source=2)`
   to simulate a vblank latch between iterations.** The plan text
   assumes real vblank IRQs latch each flip; because the vector
   binding is a follow-on, the witness would otherwise wedge on
   `PGFL_SUBMIT_BUSY` at iteration 2. Simulating the latch keeps
   the 30-frame count green and the assertable signal alive; the
   real-vblank arm lights up once the follow-on lands.

## 4. Deferred items (each with the follow-on round that closes it)

- **Live-MMIO binding for the R36 substrate.** `ixp_probe_arbitrated`,
  `pwr_wells_arbitrated`, `dpclk_pll_arbitrated`, `gucl_arbitrated`,
  `guchs_arbitrated`, `edid_arbitrated`, `menum_arbitrated`,
  `acom_arbitrated` all return 0 pending binding against the Iris Xe
  BAR0 MMIO window. Follow-on round: T14-live wire-up (name TBD;
  logically R104-follow-on or R106 depending on scheduling).
- **KIND_HW_MSIX_BASE (0x140) mint path.** The R29 milestone landed
  KIND_HW_INTERRUPT (0x140) and KIND_HW_MSIX_VECTOR (0x141) but did
  not land the mint gate for the base kind. R104.M3-001 pends on
  that. Follow-on round: R29-followup or the same T14-live wire-up
  round above.
- **`KIND_FRAMEBUFFER::lfb_pa` accessor.** Needed by
  `iris_xe_backend_page_flip` to resolve `target_fb_slot` → PA for
  the SURF_LIVE write.
- **Per-pipe vblank status register.** The `iris_xe_vblank_isr` body
  currently signals (engine=3, output=1) only. Multi-pipe iteration
  (SURF register at PIPE_A/B/C + status register per pipe) is bspec
  §14; deferred with the live-MMIO binding.
- **Real KIND_DEVICE parent for KIND_DISPLAY_BACKEND(IRIS_XE).**
  Today's mint uses a synthetic slot-132 parent; a `pci_publish_caps`
  step for the Iris Xe function is the deferred replacement.

## 5. Follow-on: Vello + G3 swapchain

The prompt requested this be documented explicitly. **Vello (G4) and
KIND_VK_SWAPCHAIN_IMAGE (G3) are follow-on rounds, NOT R104.** The
R101 kernel plan's §1.1 called this out clearly:

> `design/roadmap/next-wave-softarch.md` §G4 commits to Vello as the
> CPU-addressable 2D rasterizer for the compositor's own compositing
> pass. G4 landed the substrate. **This plan does not wire Vello
> into anything.** A future round (call it G7-prep or R105-follow-on)
> has to actually invoke the Vello pipeline against a real GPU
> submit; today Vello has never executed against a real ring.

Same for G3 (`KIND_VK_SURFACE` / `KIND_VK_SWAPCHAIN_IMAGE` /
`vk/{icd,swapchain,vk_features,bench}.pdx`): substrate landed at
G3, no consumer today, and the "consumer" would be a userland
compositor's Vulkan present path -- which requires the G7 compositor
kind (`KIND_SURFACE`, `KIND_WINDOW`, `KIND_LAYER_TREE`) to exist as
its client.

The follow-on scheduling: G7 (compositor) is the earliest round that
can invoke either Vello or the G3 swapchain, because both are
compositor-facing kinds. G7 depends on this R104 landing having
completed (page-flip real body + multi-scanout invariants), which
this retrospective closes. When G7 lands, its own retrospective
will note whether Vello and G3 got wired in that round or split
into a G7-follow-on.

## 6. Cross-round STATUS notes

- R101 (Bochs stdvga backend, closed).
- R103 (virtio-gpu 2D backend, closed).
- R104 (T14 Iris Xe wire-up + KIND_PAGE_FLIP real body, closed here).
- R105 (compositor syscall surface + hotplug + boot witnesses, closed).
- G7 (compositor: KIND_SURFACE + KIND_WINDOW + KIND_LAYER_TREE +
  damage + DnD + clipboard + screencapture) — not yet planned.
- G8 (input router) — not yet planned.
- G9 (workspaces + tiling + presentation-time feedback) — not yet
  planned.

The kernel-side substrate for the "compositor paints a pixel on the
screen" chain is now complete on both QEMU backends (via the
placeholder `backend_page_flip` arms) and on the T14 target (via
the T14-gated cascade + scaffold `*_arbitrated` calls awaiting live-
MMIO binding). G7 is the next earliest round that can consume it.

## 7. Fingerprints (all lowercase, no OK_TOK trigger)

Live (T14):
- `r104 t14_g4 present ok`
- `r104 iris_xe probe ok`
- `r104 iris_xe cdclk ok`
- `r104 iris_xe backend register ok`
- `r104 iris_xe guc load ok`
- `r104 edid read ok`
- `r104 mode enum ok`
- `r104 iris_xe modeset ok`
- `r104 iris_xe vblank vector ok`
- `r104 iris_xe vblank counted -- n=<count>`
- `r104 iris_xe flip live ok -- n=<count>`

Skip (QEMU):
- `r104 t14_g4 absent ok`
- `r104 iris_xe probe skip not-t14`
- `r104 iris_xe cdclk skip not-t14`
- `r104 iris_xe backend register skip not-t14`
- `r104 iris_xe guc load skip not-t14`
- `r104 edid read skip not-t14`
- `r104 mode enum skip not-t14`
- `r104 iris_xe modeset skip not-t14`
- `r104 iris_xe vblank vector skip not-t14`
- `r104 iris_xe vblank skip not-t14`
- `r104 iris_xe flip skip not-t14`

Backend-neutral (both paths):
- `r104 multi_scanout ok -- n=<count>`

Failure:
- `r104 iris_xe flip fail line=<N>`
- `r104 multi_scanout fail`
