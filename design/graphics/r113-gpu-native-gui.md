# R113 — GPU-native GUI compositor kernel (status refresh)

Tracking: paideia-os #2380 (R113.M0 umbrella).
Status: **docs-only refresh, 2026-09-13.** No code changes. Refreshes
the umbrella's status against the live issue tracker; `#2380` closes
alongside this refresh as an umbrella whose body of work is done
except for the hardware-gated M8 tail, which stays open under its own
milestone (see §3).

## 0. Summary

Wayland-equivalent compositor stack over R37 `KIND_GPU` (BO / VM /
context / submit) and R36 `KIND_DISPLAY` (modeset / plane): surface +
buffer handoff, window management, input routing, rendering path,
session/seat model, first client (`postui-desktop`), and screen
capture. Capability-based throughout — clients mint surfaces via
`sys_cap_invoke`, buffer sharing is DMA-BUF import from the R37 GPU
allocator, no POSIX socket protocol.

**M1 through M7 (36 issues) are closed.** Only M8 (4 issues,
hardware-gated real-T14 smoke) remains open. The compositor kernel and
its first client are code-complete and QEMU-verified; what's left is
proving the same stack on physical Lenovo ThinkPad T14 Gen 4 hardware.

## 1. Milestone status table

| Milestone | Scope | Issues | Status |
|---|---|---|---|
| M1 | Surface + buffer object handoff (mint/destroy, commit protocol, damage tracking, format negotiation, present-fence) | #2381, #2382, #2383, #2384, #2385 (+ freeze/reconcile follow-ups #2423, #2424) | **CLOSED** |
| M2 | Window manager (toplevel/popup/layer-shell roles, wl_shm-equivalent CPU path, z-order + activation, focus model) | #2386, #2387, #2388, #2389, #2390, #2391 | **CLOSED** |
| M3 | Input routing (keyboard, pointer, touch, modifiers, keymap) | #2392, #2393, #2394, #2395, #2396 | **CLOSED** |
| M4 | Rendering path (DMA-BUF import, direct-scanout, GPU-composite, damage-driven redraw, vblank sync) | #2397, #2398, #2399, #2400, #2401 | **CLOSED** |
| M5 | Session + seat (KIND_SESSION, login/lockscreen hooks, multi-seat, revocation) | #2402, #2403, #2404, #2405, #2406 | **CLOSED** |
| M6 | First client — `postui-desktop` (bootstrap, KIND_SURFACE consumption, terminal widget, status bar, launcher stub) | #2407, #2408, #2409, #2410, #2411 | **CLOSED** |
| M7 | Screenshot / screencast (FrameCaptureView@0.1, on-demand + continuous capture, consent policy) | #2412, #2413, #2414, #2415, #2416 | **CLOSED** |
| M8 | Real-HW smoke on T14 G4 | #2417, #2418, #2419, #2420 | **OPEN** — hardware-gated |

40 sub-issues total (36 closed, 4 open), matching the umbrella body's
"Sub-waves (40 issues)" count exactly.

## 2. Architectural freeze note (M1)

`design/graphics/r113-m1-substrate.md` records a Wave-12 rollback and
re-freeze of the M1 substrate: `KIND_SURFACE = 0x1B8` (not the
originally proposed `0x1B5`, which collided with `KIND_HDR_METADATA`)
reused an *already-live* kind from G7.M2-001 (#2246) rather than
minting a second one, resolving a four-way collision (kind ID, row
layout, failure-band, fingerprint coverage). #2423/#2424 are the
reconciliation issues that landed against the frozen shape. This is
why M1 shows 7 issues (5 planned + 2 freeze-driven) against a 5-issue
sub-wave estimate — expected overhead from a rollback-and-refreeze,
not scope creep.

## 3. What remains open: M8

All four M8 issues are blocked on **physical T14 G4 hardware
availability**, not on kernel or compositor code:

- **#2417** — R113.M8-037, T14 G4 real-HW compositor smoke. Titled
  "blocked on R111.M4-015" (GOP framebuffer console) — that
  dependency is **already closed** (#2367), so the title is stale;
  the actual remaining blocker is HW-gated per `design/hardware/
  t14-real-hw-smoke-scope.md` (companion doc to this refresh).
- **#2418** — R113.M8-038, external-USB-keyboard input smoke on T14.
- **#2419** — R113.M8-039, direct-scanout witness on Iris Xe.
- **#2420** — R113.M8-040, multi-surface composite witness on Iris Xe.

M8's dependency chain (`R111` T14-boot-to-`$` umbrella #2353, plus
`R111.M4-015` GOP console and `R111.M5-017`/`M5-018` xHCI+HID) is
fully closed. Nothing in the compositor kernel, `postui-desktop`, or
the QEMU-side smoke path blocks M8 — it is purely an operator-driven,
hardware-in-loop verification wave. See
`design/hardware/t14-real-hw-smoke-scope.md` for the scoping of what
each M8 issue actually needs from the physical unit and what can (or
cannot) be pre-validated in QEMU first.

## 4. Closed-umbrella disposition

Per the ECOTABLE/AISSUE cohort instruction, #2380 closes as a docs-only
umbrella refresh: the umbrella's own job — landing the compositor
stack — is done (M1-M7, 36/40 issues). The remaining M8 hardware wave
tracks under its own milestone issues (#2417-#2420) rather than
keeping the umbrella open indefinitely for a hardware-availability
gate. Reopening #2380 (or filing a successor umbrella, e.g. "R113.M9 —
real-HW closure") is the right move only if M8 uncovers a genuine
compositor-kernel defect that widens beyond the four listed issues;
until then, M8 stays scoped to what `t14-real-hw-smoke-scope.md`
defines.

## 5. Cross-references

- `design/graphics/r113-m1-substrate.md` — M1 freeze rationale.
- `design/hardware/t14-real-hw-smoke-scope.md` — M8 scoping (this
  cohort's companion doc, paideia-os #2417).
- `design/roadmap/t14-bootable-usb-wave.md`, `design/boot/
  t14-hw-in-loop.md`, `design/hardware/t14-g4-first-boot.md` — the R111
  T14-boot-to-`$` prerequisite chain M8 builds on.
- `design/semantic/frame_capture_view_v0_1.md` — the M7
  FrameCaptureView@0.1 schema.
