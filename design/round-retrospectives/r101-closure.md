# R101 Closure Retrospective — Dumb-framebuffer backend (QEMU `-vga std` / Bochs)

**Status:** Closed
**Date:** 2026-09-02
**Design authority:** `design/graphics/r101-kernel-plan.md` §5 (R101 sub-scope)
**Companion (userland):** `design/graphics/r102-user-plan.md`

---

## 1. What R101 landed

R101 delivers the kernel-side kernel-half of the graphics substrate on
QEMU's Bochs/stdvga path. Before this round the kernel had no display
path at all on QEMU (`run-qemu.sh` used `-display none` and nothing in
the tree bound to any emulated display device). After this round, a
kernel-mode boot witness can paint a checkerboard through a fresh
capability chain and read the pixels back from the LFB.

The delivered surface:

| Sub-scope | Milestones landed | Cap ordinals | Files |
|---|---|---|---|
| M1 — KIND_DISPLAY_BACKEND | M1-001..004 (4 issues) | `0x1AE` | `core/cap/kind_display_backend.pdx`, `core/graphics/backend_dispatch.pdx` |
| M2 — Bochs/stdvga driver | M2-001..005 (5 issues) | — | `core/drivers/gfx/bochs_stdvga/{probe,modeset,lfb_map,flush}.pdx` |
| M3 — KIND_FRAMEBUFFER + flush | M3-001..005 (5 issues) | `0x1AF` | `core/cap/kind_framebuffer.pdx`, `core/graphics/fb_flush.pdx`, `core/graphics/sim_vblank.pdx` |
| M4 — Boot witness `boot_r101_stdvga` | M4-001..003 (3 issues) | — | `boot/witness/r101_stdvga_checkerboard.pdx`, `tools/run-qemu.sh` (PAIDEIA_VGA env), `tools/run-smoke.sh` (boot_r101_stdvga mode), `tests/expected-r101-stdvga.golden` |
| M5 — Closure | M5-001 (this file) | — | `design/round-retrospectives/r101-closure.md` |

Total: **18 issues landed in one wave** (no deferrals).

## 2. Architectural choices honoured verbatim

- **KIND_DISPLAY_BACKEND as the multi-backend anchor** (plan §4.1
  Option C). A new abstract kind at `0x1AE` above `KIND_DISPLAY_ENGINE`
  (`0x16F`) that carries a `backend_kind` selector (`BOCHS_STDVGA=1`,
  `VIRTIO_GPU_2D=2`, `VIRTIO_GPU_3D=3`, `IRIS_XE=4`), so the
  Iris-Xe-specific `gpu_gen ∈ {1,2,3}` mint gate on
  `KIND_DISPLAY_ENGINE` stays unchanged while a QEMU stdvga still gets
  first-class capability representation.
- **KIND_FRAMEBUFFER as a distinct, GPU-optional scan-out kind** (plan
  §4.2). Derived over `KIND_MEMORY` (not `KIND_GPU_BO`), so the mint
  requires no `KIND_GPU_VM` — which is what lets Bochs (no GPU) mint a
  framebuffer at all. Format enum is `BGRA8888=1`; a full R104 landing
  will widen the format matrix.
- **Simulated 60 Hz vblank source** (plan §4.4). Driven off the 100 Hz
  LAPIC scheduler tick in `int/exceptions.pdx::handle_timer`, gated on
  `_active_backend_kind == BOCHS_STDVGA`. Fires
  `dpy_timeline_vblank_signal(engine_id=1, output_id=1)` on 5 of every
  10 ticks (≈50 Hz — see the R103 note below for the tightening path).

## 3. Deviations from the plan (each with justification)

1. **Row `+0` header is a packed field, not a bare `kind_tag`.** The
   prompt-supplied row shape names `kind_tag@+0`; the tree-wide
   convention (every existing `kind_*.pdx` file) reserves `+0` for a
   packed header whose high byte is the allocator's `in_use` flag, so
   `tail_alloc`'s low-first scan can find a free row. This landing
   honours the tree convention and packs `backend_kind` /
   `pixel_format` into the header's low bytes rather than at the
   plan-named offsets (`+8` / `+20`). Section 1 of each kind's header
   documents the exact bit layout. This is a structural fit, not a
   behavioural change.

2. **Simulated vblank rate is ~50 Hz, not 60 Hz.** The plan asks for
   60 Hz; the R101 MVP fires on 5 of every 10 LAPIC ticks (100 Hz / 2
   = 50 Hz). A proper 60 Hz driver from a 100 Hz source needs a
   fractional counter with a fixed-point residue (fire on residues
   {0,2,3,5,7,8} of every 10 ticks). Deferred to R103.M4-002 — that
   milestone lands a real virtio-gpu completion source that supersedes
   this simulated path, at which point the residue arithmetic becomes
   fallback-only and the tightening is a smaller code change.

3. **`SOURCE_SIMULATED = 3` is a compile-time constant, not a row
   field.** `KIND_DISPLAY_TIMELINE`'s current row shape does not
   carry a `source` field (see `cap/kind_display_timeline.pdx` §2:
   the row records only `{header, timeline_id, engine_id/output_id,
   last_scanout_value}`). Adding one requires changing the row's byte
   layout, a cross-cutting change out of scope for R101. The constant
   is published in `core/graphics/sim_vblank.pdx` so R103's rebase has
   a stable binding target; the actual row-field addition is R103's
   own scope.

4. **`KIND_FRAMEBUFFER` mint entry point is `_mint_simple` not the
   full 9-arg `_mint_body`.** The plan's R101.M3-001 issue text
   documents a 9-arg mint (memory_slot, rights, backend_row,
   pixel_format, width, height, stride, lfb_pa, lfb_va). paideia-as
   caps SysV register args at 6; a 9-arg call requires 3 on-stack
   args. `_mint_simple` folds pixel_format (BGRA8888 fixed),
   stride (=width×4), and owner_pid (=0) into hard-coded defaults so
   the R101.M4-001 witness fits everything in registers. `_mint_body`
   with the stack-arg convention arrives at R105 when
   `sys_framebuffer_create` needs to pass caller-supplied values.

## 4. Encoder / paideia-as observations

- **No `in`/`out` I/O port encoder gap surfaced as a live blocker.**
  The plan pre-empted the issue by naming BAR2 MMIO as the primary
  access path for VBE-DISPI registers; modeset uses direct-mapped
  16-bit stores at `BAR2 + 0x500 + (index * 2)` with mfence brackets.
  If a later BIOS-legacy path needs I/O ports, the paideia-as gap is
  real and would need a v0.25+ encoder addition — filed as a note
  for a hypothetical R101-follow-on, no issue opened yet.
- **`imul reg64, reg64` is used** for the `total_bytes = bytes_per_row
  * height` computation in `bochs_flush`. Confirmed present in
  paideia-as v0.24.x per the R91 e1000e / rtl8139 probe precedents.
- **Sized MMIO stores through `mov_w` / `mov_d`** everywhere; no bare
  `mov [addr], reg` that would widen to REX.W and clobber neighbouring
  memory. `bochs_vbe_write` is the one place where the sized `mov_w`
  is critical (VBE-DISPI registers are 16 bits).

## 5. What R101 explicitly does NOT deliver

- **No virtio-gpu backend.** R103 (see plan §6) lands the virtio-gpu
  control-queue + resource_create_2d + set_scanout + flush cascade,
  and the ISR wiring that replaces `sim_vblank_tick` with a real
  completion source for that backend.
- **No Iris Xe wire-up on T14.** R104 (see plan §7) actually calls
  the R36/R37/G1-G6 substrate from `kernel_main.pdx`.
- **No compositor syscall surface.** R105 (see plan §8) lands
  `sys_display_enumerate`, `sys_framebuffer_{create,map}`,
  `sys_page_flip{,_wait}`, `sys_display_hotplug_subscribe`, plus the
  authority-boundary document a user compositor consumes.
- **No `KIND_PAGE_FLIP`** — the per-frame compositor swap authority
  (plan §4.3). Reserved at ordinal `0x1B0`; landing arrives with R104.M4.
- **No `KIND_HOTPLUG_CHANNEL`** — reserved at `0x1B1`; landing arrives
  with R105.M4.
- **No R23 GOP fb-console retargeting.** The plan's R101.M2-005 issue
  offered a "decide at landing time" between skipping R23's fb console
  on Bochs boots vs re-targeting it to stdvga's LFB. This landing takes
  the SKIP path: R23's fb-console binds to `_boot_env.fb` which is
  0 on QEMU `-kernel` boots (no GOP), so R23 stays dormant on QEMU
  regardless of `-vga std`. A future round can add fb-console
  re-targeting once a stable multi-backend console model exists.

## 6. Observable proof

Under `PAIDEIA_VGA=std tools/run-smoke.sh boot_r101_stdvga`, the log
carries (contains-in-order):

```
r101 bochs probe ok N=1
r101 bochs modeset ok width=1024 height=768
r101 bochs lfb map ok va=0xffffa80000000000
r101 display_backend mint ok row=0
r101 framebuffer mint ok row=0
boot r101 stdvga ok -- w=1024 h=768
```

The `boot r101 stdvga ok` fingerprint fires only after all 8 witness
stages pass, including the pixel readback at the 4 boundary positions
(0,0), (8,0), (512,384), (1023,767). A stride-off-by-one or
byte-swap in the format would surface as a mismatch and take the fail
path (`boot r101 stdvga fail line=<N>`) with the failing stage number.

On any boot without `PAIDEIA_VGA=std` (the default `none` case, and
every T14 UEFI boot) the witness fingerprints `boot r101 stdvga skip`
and returns cleanly. The `boot_r101_stdvga` smoke mode's golden file
requires the success line, so a regression that silently takes the
skip path fails the smoke.

## 7. Cross-round dependencies opened / closed

- **Opens:** R103 depends on `KIND_DISPLAY_BACKEND` +
  `KIND_FRAMEBUFFER` + `backend_dispatch` (all landed here). R103.M4
  supersedes `sim_vblank_tick` with a real virtio-gpu completion
  source. R104.M1 opens by minting `KIND_DISPLAY_BACKEND` with
  `backend_kind=IRIS_XE` and a `provider_slot` naming the R36
  `KIND_DISPLAY_ENGINE` row.
- **Closes:** Every R101 issue (#2136–#2153, 18 total).

## 8. Fingerprint coverage notes

Every fingerprint this round emits is all-lowercase without the
bracketed `[legacy: ... OK]` uppercase suffix, so the `OK_TOK`
extractor in `tools/verify-fingerprint-coverage.sh` does not flag any
of them as requiring golden coverage. The `boot r101 stdvga ok`
success line IS pinned by `tests/expected-r101-stdvga.golden` for the
smoke mode; the driver-side lines (`r101 bochs probe ok`, `r101 bochs
modeset ok`, `r101 bochs lfb map ok`, `r101 display_backend mint ok`,
`r101 framebuffer mint ok`) are pinned by the same golden as the
success-path predecessors.

## 9. Tag

`r101-closed`.
