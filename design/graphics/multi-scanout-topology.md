# Multi-Scanout Topology

**Status:** Landed at R104.M5-003 (paideia-os #2187).
**Date:** 2026-09-02.
**Scope:** Naming + invariants for the kernel-side multi-output pipeline
that G7 (compositor) and every downstream authority consumer builds
against.
**Companion:** `design/graphics/r101-kernel-plan.md` §7 R104.M5, and
`design/roadmap/next-wave-softarch.md` §P8 ("recovery-console plane
reserved under lease pressure").

---

## 1. What this document pins

A live boot has zero or more display outputs. Every consumer that
enumerates outputs (compositor, screen-capture broker, session
manager) needs a stable answer to three questions:

1. Which output is "the built-in one"?
2. What ordering do external outputs enumerate in?
3. Which plane is reserved for the recovery console?

The kernel enforces one answer to each. Higher-level software may
present them differently (a compositor showing a monitor by its
firmware name rather than a scanout index) but every layer above the
kernel MUST resolve back to these primitives when they matter for
authority.

---

## 2. Naming

### 2.1 Scanout indices

Scanouts are u16 identifiers in `[1, 0xFFFF]`. Zero is refused at
`KIND_DISPLAY_TIMELINE` mint time (see
`cap/kind_display_timeline.pdx` §dpt_output_valid); zero as a scanout
id would prevent a "not yet enumerated" sentinel from being distinct
from the first output.

### 2.2 Rule: scanout 1 is always the built-in panel

On any hardware whose firmware advertises a built-in display, that
display becomes scanout 1. The kernel's Iris Xe topology walker
(`drivers/dpy/topology.pdx`) enumerates the built-in panel FIRST
irrespective of DDI ordering; the R36 substrate's `dtopo_ddi_valid`
gate accepts DDI 0..6, and the walker's per-DDI enumeration honours
the "eDP/built-in first" invariant.

On T14 G4: scanout 1 is the eDP panel.
On QEMU with `-vga std`: scanout 1 is the Bochs LFB (single output).
On QEMU with `-vga virtio` or `-device virtio-gpu-pci`: scanout 1
is virtio-gpu's `scanout_id=0` in wire terms, mapped to output_id 1
in kernel terms per the u64-max-avoidance rule above.

### 2.3 Rule: external outputs enumerate in HPD order

External outputs (DP-over-TB, HDMI, DisplayPort direct) get scanout
ids 2, 3, ... assigned in HOT-PLUG DETECT order -- the order the
hpd_isr saw them come online, not the DDI slot they connect to. A
monitor unplugged and re-plugged gets its old scanout id back so
compositor state (window placements, per-monitor color profile) is
stable across cable-jiggle events.

The HPD ordering is stable across boot in one specific sense: on a
warm reboot, whichever external monitor was live at power-off gets
scanout 2 again at boot (assuming it's still connected). This is the
weakest invariant that keeps a `~/.config/compositor/monitors.toml`
useful across reboots without paining the compositor with
firmware-name lookups.

A monitor plugged mid-session takes the LOWEST FREE scanout id;
unplugged monitors leave their id reserved for `max_ids_seen` ticks
(default: 4 boots) before the id is released for re-use.

### 2.4 Rule: engine ids are internal

Engine ids (u16) in the KIND_DISPLAY_TIMELINE row header are internal
to the kernel. They exist to distinguish rows belonging to different
graphics engines when a system has more than one (integrated iGPU +
discrete GPU, or the future R104-follow-on multi-scanout on discrete
GPUs whose engines report per-pipe vblank separately). Userspace
authorities never see the engine id -- they hold a KIND_DISPLAY_OUTPUT
capability whose slot in the cap table is the identity that matters.

At R104 landing: engine_id 1 = Bochs sim-vblank; engine_id 2 =
virtio-gpu; engine_id 3 = Iris Xe. Values are reserved additively;
a later engine gets the next free id without disturbing existing
mints.

---

## 3. Invariants

### 3.1 Output 1's plane 0 is the reserved recovery console (P8)

The plane at (output=1, plane=0) is reserved. `KIND_SCANOUT_LEASE`
refuses to lease it (see `cap/kind_scanout_lease.pdx` §sl_reserved_
plane: `plane_slot == SL_RESERVED_PLANE_SLOT (0)`). The compositor
draws over it in its normal composition pass, but the reservation
means:

- No fullscreen client's direct-scanout lease can hijack the plane
  the recovery console lives on.
- The kernel's kmsg-to-frame path can always land a text page on
  scanout 1 even during compositor bring-up failure.
- P8's "kernel can always talk to the human" invariant is preserved.

This invariant is enforced at LEASE MINT time, not at plane-write
time -- a compositor can still repaint plane 0 (it holds the primary-
plane authority through `KIND_DISPLAY_PLANE`), but no user-space
process can grab exclusive access to it via a lease.

### 3.2 KIND_PAGE_FLIP composes with KIND_SCANOUT_LEASE

Per R104.M4-005 (paideia-os #2184): a plane held under a live
`KIND_SCANOUT_LEASE` cannot simultaneously back an active
`KIND_PAGE_FLIP`. The composition gate `pgfl_check_plane_available`
(see `cap/kind_page_flip.pdx`) wraps `sl_find_by_plane` and returns
1 iff no lease holds the plane_slot. The composed caller (compositor,
or the R104.M5 witness) refuses the mint with `PGFL_MINT_PLANE_LEASED
(0xFFFFEB57)` when the gate returns 0.

Rationale: a page-flip authority is "at the next vblank, latch this
memory". A lease authority is "you are the sole consumer of this
plane". The two overlap on the plane's backing memory, and giving
one holder either authority implicitly denies the other. Enforcing
the disjointness at mint time makes the invariant static rather than
per-frame -- neither authority needs to re-check the other on every
submit or every present.

### 3.3 Per-output timelines advance independently

Each KIND_DISPLAY_OUTPUT gets its own KIND_DISPLAY_TIMELINE (one row
per (engine, output) pair; the `dpt_find_by_engine_output` accessor
is the seam). A vblank on output 1 advances only timeline (engine,
1); a vblank on output 2 advances only timeline (engine, 2). A
compositor waiting on the two timelines separately (via distinct
`sched_wait(SCHED_WAIT_PAGE_FLIP, row_id)` calls) blocks on one
timeline without being wakened by the other's vblank.

R104.M5-002 (paideia-os #2186) is the verification: the multi-scanout
witness mints two KIND_PAGE_FLIP rows against two distinct synthetic
outputs and asserts they are distinct row_ids (not aliased into a
shared row). The stronger invariant -- that each timeline actually
advances on its own vblank event without leaking a signal from the
other output -- is asserted post-follow-on when the vblank ISR
delivers per-pipe status rather than the single-engine placeholder
this landing sits behind.

---

## 4. What this document does NOT pin

- The naming a compositor presents to users. "External DP" vs "Dell
  U2723QE" vs "Home monitor" is compositor territory; the kernel
  gives out scanout ids only.
- The layout of on-disk `monitors.toml` (a G7 compositor concern).
- The color profile per output (a G6 kernel driver concern; the
  compositor consults `KIND_COLOR_PROFILE` capabilities the driver
  minted).
- The MMIO layout of vblank status registers (a driver concern
  behind `drivers/dpy/`; a future R104-follow-on binds the real
  Iris Xe registers behind `dpy_timeline_vblank_signal` without
  changing this document).

---

## 5. Cross-references

- `cap/kind_display_output.pdx` -- KIND_DISPLAY_OUTPUT (0x170) row
  substrate. Carries the scanout id in a body field.
- `cap/kind_display_timeline.pdx` -- KIND_DISPLAY_TIMELINE (0x185),
  the u64 monotone counter the vblank source advances. One row per
  (engine, output) pair.
- `cap/kind_scanout_lease.pdx` -- KIND_SCANOUT_LEASE (0x188). Enforces
  §3.1's plane-0 reservation.
- `cap/kind_page_flip.pdx` -- KIND_PAGE_FLIP (0x1B0). Enforces §3.2's
  lease disjointness through `pgfl_check_plane_available`.
- `drivers/dpy/topology.pdx` -- Iris Xe topology walker; enforces
  §2.2's "built-in first" rule.
- `drivers/dpy/hpd_isr.pdx` -- HPD interrupt handler; drives §2.3's
  external-output ordering.
- `boot/witness/r104_multi_scanout.pdx` -- R104.M5 witness proving
  per-output KIND_PAGE_FLIP rows are distinct.
- `design/graphics/r101-kernel-plan.md` §7 R104.M5 -- the plan text
  this document was drafted against.
- `design/graphics/authority-boundary.md` -- the compositor-versus-
  kernel authority boundary that §3.1 and §3.2 keep coherent.
- `design/roadmap/next-wave-softarch.md` §P8 -- the recovery-console
  reservation §3.1 encodes.
