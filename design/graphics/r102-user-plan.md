# R102 (softarch) — User-Space Graphical Display Stack: libpdx-font + libpdx-gfx + libpdx-event + svc-compositor + svc-wm + pdxterm + pdxclock + pdxwatch + pdxpaint

**Status:** proposal (2026-09-01, softarch counterpart to osarch R101 kernel
plan being drafted in parallel).

**Companion (osarch):** `design/graphics/r101-kernel-plan.md` — the
kernel-side half of this wave. This document is the userland half. As
of writing, `design/graphics/r101-kernel-plan.md` is being authored in
parallel; every kernel dependency this plan names is either (a) already
landed and referenced by file/kind ordinal (§7.1), or (b) an ask
directed at R101 (§7.2) that this plan stages around exactly the way
R100's §12 staged around unbuilt syscalls.

**Depends on:**
- `design/roadmap/postui-scope.md` and `paideia-os/postui` `docs/design.md`
  — the *text-mode* analog this plan mirrors wholesale. Every discipline
  postui set for TUI (cap-derived surface, per-frame damage diff,
  semantically-queryable rendering, integer-only geometry) has a
  graphical counterpart here.
- `design/kernel/kind-tui-canvas.md` — the `KIND_TUI_CANVAS` (ordinal
  `0x1A6`) design. `KIND_SURFACE` (§7.2.1) is its graphical sibling and
  reuses its derivation shape (KIND_MEMORY parent + server-conversation
  reference) exactly.
- `design/networking/r100-user-tools-plan.md` — the M1..M5-per-satellite
  wave shape this plan copies wholesale (issue-body template, fingerprint
  discipline, cross-repo escalation posture, fail-closed elevate stance,
  semantic-pipe fallback-header convention).
- `design/round-retrospectives/r90-xrepo-wave3-plan.md` — the sub-issue
  numbering convention `R90-XREPO.<NNN>.M<M>-<seq>` and the
  Scope/Files/Fingerprint/Effort/Deps body template.
- Existing kernel-side display substrate — the whole G-axis synthesis
  document (`design/roadmap/next-wave-synthesis.md`) commits to Vello +
  Vulkan + explicit-sync as the eventual **G-series** graphics stack.
  **R102 is not that.** R102 is the modest CPU-side framebuffer stack
  that lands *now*, gives the OS a usable graphical face while the
  driver work (R77 Iris Xe modeset, R37 Vulkan) matures, and hands off
  its public library API to the G-series compositor unchanged. §8.3
  states this hand-off contract explicitly.
- `src/kernel/core/cap/kind_display_engine.pdx`,
  `kind_display_output.pdx`, `kind_display_mode.pdx`,
  `kind_display_plane.pdx`, `kind_display_timeline.pdx`,
  `kind_gpu_bo.pdx` — the six display kinds that already exist in-tree
  (per `ls src/kernel/core/cap/`). The plane path is stubbed on modeset
  today (R77 is unlanded); §7.1 documents what is *actually usable*
  right now vs. what needs R77 first.
- `src/kernel/core/drivers/fb_font.pdx` — the kernel's 8x16 embedded
  bitmap font. `libpdx-font` v1 (§2.1) reuses the same glyph data
  verbatim so kernel-console text and userspace text render identically.
- `src/kernel/core/cap/kind_hid_device.pdx`, `kind_hid_event.pdx`,
  `src/kernel/core/ipc/hid_event_stream_channel.pdx` — the input surface
  the compositor's event pump subscribes to. Already landed; §7.1.

**Sibling documents to keep in step:**
- `design/graphics/r101-kernel-plan.md` — osarch's parallel doc. Every
  kernel primitive this plan asks for is named at §7.2 with a
  fingerprint sentence; if osarch has chosen a different name or
  ordinal, rename here on landing (this plan does not attempt to
  pre-empt R101's naming decisions).
- `design/roadmap/next-wave-synthesis.md` §G7 — the **future**
  Vello/PWP compositor. §8.3 states R102's API-stability contract with
  it so a G-series consumer can port from R102 without a library API
  break.
- `design/architecture/next-wave-derived-kinds.md` — gains rows for
  `KIND_SURFACE` and `KIND_INPUT_FOCUS` on landing (§7.2.1/§7.2.2).

---

## 0. Reading order and framing

- §0.1 what "R102 user stack" delivers — 9 satellites.
- §0.2 vision alignment: graphical windows as typed records.
- §0.3 the one honesty rule — R102 is CPU-side framebuffer only.
- §0.4 divergence from the eventual G-series compositor (`stack.md`
  precedent).
- §1 round shape, milestones, dep on R101.
- §2 satellite inventory — 9 repos, one-line purpose, wave placement.
- §3 per-repo M1..M5 milestone breakdown.
- §4 exhaustive issue list per repo per milestone.
- §5 new semantic-pipe schema records.
- §6 cross-repo dependency matrix.
- §7 coordination with R101 kernel plan (what caps we consume, what we
  ask of osarch).
- §8 deferred sub-scopes (3D, video, GPU compositing, remote display,
  a11y).
- §9 landing order and first-pixel-on-screen smoke.

### 0.1 What R102 delivers

Nine new public repos under `github.com/paideia-os/`. Repo shape mirrors
R100 exactly (paideia-as manifest at root, `caps.decl` at root, `src/`
module tree, `tests/`, `release/`, `doc/<name>.pdxdoc`, dual-signed
`manifest.pdxsig` at 1.0.0).

| Repo | Kind | Purpose |
|---|---|---|
| `libpdx-font` | library | bitmap glyph store + text metrics (8x16 v1) |
| `libpdx-gfx`  | library | CPU-side draw primitives (rect, blit, line, glyph) into a `KIND_SURFACE`-backed pixel buffer |
| `libpdx-event`| library | client-side event routing (subscribe to input events on a window handle) |
| `svc-compositor` | service | holds framebuffer cap, arbitrates window Z-order, delivers input events, presents frames |
| `svc-wm`      | service | window placement policy, decoration, focus, keyboard shortcuts |
| `pdxterm`     | app     | framebuffer terminal emulator (graphical alternative to the UART TTY) |
| `pdxclock`    | app     | reference clock (smallest useful window app) |
| `pdxwatch`    | app     | system-monitor GUI (graphical peer of `postui-top`) |
| `pdxpaint`    | app     | reference paint app (exercises pointer + drag + full-surface redraw) |

Nine repos, sized to match R100's seven — one library-family (`libpdx-*`)
in the same shape as `libpdx-net`/`libpdx-url`, one new service-family
(`svc-*`) that is the first such prefix in the org, and four graphical
peers of the postui reference-app family.

### 0.2 Vision alignment: windows as typed records

paideia-os's vision commits to the terminal being **semantically
queryable** — every observable state change of the system is a typed
record on a typed pipe. postui extended that discipline to text-mode
UIs (a widget catalog whose per-widget query surface returns typed
records, not screen scrapings). R102 extends it to graphical UIs on the
same terms:

- **Windows are typed records.** Every live window in the system
  materializes as a `WindowRecord@0.1` (§5.1) on the compositor's
  semantic-pipe stream. `pdxwatch` (or any consumer) queries "what
  windows exist" by reading the pipe, not by scraping pixel bytes.
- **Input events are typed records.** `InputEventRecord@0.1` (§5.2)
  is the wire form for every keyboard, pointer, and focus event
  delivered from compositor to client — never a raw kernel keycode
  stream that a client must parse.
- **Display geometry is a typed record.** `DisplayGeometryRecord@0.1`
  (§5.3) is what a client asks the compositor for to learn "how big is
  the screen, what is the pixel format, what is the DPI." No process
  reads a `/sys/class/drm/*` moral-equivalent — that data lives on the
  compositor's `svc.compositor.geometry` query endpoint as a typed
  record.
- **Fonts and their metrics are typed records.** `FontMetricsRecord@0.1`
  (§5.4) is how `libpdx-gfx` publishes text-layout inputs (ascent,
  descent, advance-per-glyph) to a consumer that wants to lay out its
  own text without linking `libpdx-gfx` directly.
- **The compositor exposes queries via semantic-pipe.** `svc-compositor`
  registers a `svc.compositor` name (via the R90-XREPO.012.M2-002
  broker) with query ops: `list-windows`, `get-focus`, `get-geometry`,
  `screenshot-region` (returns typed pixel-region record + BLAKE3
  digest, not a bare `.png`). A future `pdxcompquery` CLI can dump the
  compositor's live state without any custom protocol.

None of this is aspirational: the fallback-line-based emission pattern
libpdx-audit/libpdx-volume/libpdx-net all inherit from `mount.pdxfs`
carries every record over the same wire until the schema registry
(paideia-os#2000 → R90-XREPO.012) lands, at which point the emission
upgrades in place with no consumer change.

### 0.3 The one honesty rule: R102 is CPU-side framebuffer only

R102 targets the CPU-side scanout path — the compositor holds a
framebuffer cap, walks its own linear pixel buffer once per frame in
user code, and flips the plane cap when the frame is ready. It does
**not** use the GPU for compositing, does **not** render text via SDF,
does **not** use Vulkan, does **not** wait on drm-syncobj timelines,
does **not** do HDR-linear compositing. All of that is the
`next-wave-synthesis.md` G-series roadmap and requires R37 (Iris Xe
Vulkan) which requires R36/R77 (Iris Xe modeset) which is a materially
larger project than R102's whole scope.

This is a deliberate scope reduction that lets R102 ship on **the
current stubbed-modeset kernel** by consuming the GOP-handoff LFB the
loader already maps (§7.1), plus one new kernel primitive (§7.2.1)
that exposes it to a userspace holder as a `KIND_MEMORY`-derived
scanout cap. Every satellite here is buildable and testable in QEMU
without any of the R77/R37 driver work; the day those land, the
compositor's flip path swaps from "write to the LFB and IPI the
console driver to redraw" to "commit a `KIND_DISPLAY_PLANE` atomic
modeset" — an internal implementation swap, not an API break.

Concretely, "CPU-side framebuffer only" means:

1. Pixel format at v1: **BGRA8888** (one 32-bit word per pixel, the GOP
   default). No 10-bit-per-channel, no scRGB-linear, no ICC — all G6
   material.
2. Blending: **source-over with premultiplied alpha, in sRGB space**,
   done in software with saturating u8 math. Correct enough for
   solid-colored windows with drop-shadow-style translucency; visibly
   wrong under color-critical use, and this plan says so out loud
   rather than shipping a fake HDR posture. §8.2.
3. Scaling: **integer only** (1×, 2×, 3×). Fractional scaling is a G3
   deliverable; R102 refuses fractional-scale factors at compositor mint
   with a documented error. §8.4.
4. Text: **bitmap fonts** (8x16 v1 from `fb_font.pdx`, plus a couple of
   larger `libpdx-font` shipped faces at M5). TrueType parsing, hinting,
   subpixel positioning, and SDF-GPU-text are all **G5**. §8.1.
5. Present cadence: **single-buffered scanout with a per-window
   back-buffer** (client renders into its own `KIND_SURFACE` memory;
   compositor blits into the LFB). No page-flip queue, no
   drm-syncobj-shaped fence timeline, no VRR — all G-series. The
   compositor drives its own render loop on an HPET-derived tick, best
   effort at 60 Hz; the tick and observed present latency are reported
   on `PresentRecord@0.1` (§5.5) so the honesty is visible at runtime.

### 0.4 Divergence from `next-wave-synthesis.md` G-series

The G-axis (G1–G12) is the eventual paideia-native GPU-accelerated
graphical stack: `paideia-drm` (G1–G2) → `paideia-vk` (G3) →
`paideia-vello` (G4) → text (G5) → color (G6) → **G7 compositor
protocol** → G8+ (input server, latency, a11y, IME, DnD). That work
sits behind R37 Vulkan and R36/R77 modeset and is measured in years,
not weeks.

R102 is the **pre-G-series** stack. It exists so paideia-os has a
usable graphical face before that long tail matures. Every public
library API in R102 (`gfx_draw_rect`, `event_next`, `wm_place_window`,
`compositor_present`) is designed to be re-hosted under G7 without a
signature break — the internals swap; the callers don't. Concretely:

- `libpdx-gfx`'s `Surface` handle is opaque; today it wraps a
  `KIND_SURFACE` memory buffer, tomorrow it wraps a `KIND_SURFACE`
  whose backing is a `KIND_GPU_BO` and whose commit-op is a GPU
  submission. Same call site.
- `libpdx-event`'s `event_next(window) -> InputEventRecord` reads the
  same schema G-series input server would emit. Same wire type.
- `svc-compositor`'s wire protocol is a small closed set of typed
  requests over an IPC endpoint, not a "PWP subset" — PWP (Paideia
  Wire Protocol) at G7 is a superset R102's protocol should be
  forward-compatible with by naming its own version explicitly and
  refusing G7-only request codes cleanly.

**Nobody should reconcile this plan against G7-plan.md by trying to
make R102 a stepping stone toward Vello.** They are two different
compositors sharing a public API. R102 dies when G7 lands (or gets
demoted to a fallback path a headless smoke fixture still uses), and
the applications that were written against R102's `libpdx-gfx` keep
running on the G7 substrate unchanged.

### 0.5 The single main-checkable decision

The trust-model call R100 asks main to sanity-check hardest is
`pdxcurl`'s "raw-public-key TLS, no CA store" choice. R102's peer
main-checkable is:

**Single-compositor vs. pluggable-compositor.** R102 ships **exactly
one compositor** (`svc-compositor`); the WM plugs into it, but the
compositor itself is a fixed binary the boot bundle seeds. There is no
runtime "which compositor am I using" question, no compositor-swap
protocol, no compositor version negotiation with the client. This is
the same posture Wayland-the-protocol was originally intended to have
(and lost to `weston`/`mutter`/`kwin`/`sway`/`hyprland`
fragmentation); R102 forecloses it structurally by making the
compositor the *only* holder of the framebuffer cap — a second
compositor cannot exist while the first holds the plane, and the
compositor cannot hand off its plane cap to a peer without going
through revocation-and-remint the WM can veto. §8.5 states the trade-
off (research/experimentation cost) explicitly. If main disagrees, the
call belongs in the report, not in the implementation.

---

## 1. Round shape

R102 has **five internal milestones** (M1..M5) landing across the nine
satellites in a partial order the §6 dep matrix pins:

- **M1 — Scaffold and API freeze.** Every satellite creates its repo,
  writes its `caps.decl`, freezes its public API surface with stub
  bodies, and lands its `.pdxdoc`. No real functionality; a `libpdx-gfx`
  `draw_rect` returns `OK` without touching any memory.
- **M2 — Real body over kernel primitives available today.** Every
  satellite lands its real function against the caps/syscalls that
  already exist in-tree (fb_font, hid_event_stream_channel, KIND_MEMORY,
  the existing IPC endpoint substrate). Anything blocked on new kernel
  work is a documented stub matching R100's "parses, doesn't
  transmit, ships anyway" pattern.
- **M3 — Consume new R101 kernel primitives.** The compositor consumes
  the R101 framebuffer-scanout cap (§7.2.1) for real; the input pump
  consumes the R101 focus-routing hook (§7.2.2); every satellite that
  was stubbed at M2 becomes real.
- **M4 — Smokes and end-to-end tests.** Boot smokes cross the whole
  stack (`boot_r102_first_pixel`, `boot_r102_window_present`,
  `boot_r102_input_route`, `boot_r102_pdxterm_hello`).
- **M5 — Signed release.** Dual-signed manifest, `.pdxdoc`, CHANGELOG-1.0,
  mirror push. Standard.

**Dep on osarch R101.** The compositor's real M3 body depends on
R101's framebuffer-scanout cap (§7.2.1) landing. Every satellite's M1
and M2 are unblocked; M3 lands after R101.M1 (or whichever R101
milestone owns the cap; softarch does not pre-empt osarch's numbering).

---

## 2. Satellite inventory

Nine new public repos under `github.com/paideia-os/`. Each repo's
shape mirrors R100 exactly: paideia-as manifest at root, `caps.decl` at
root, `src/` module tree, `tests/`, `release/`, `doc/<name>.pdxdoc`,
dual-signed `manifest.pdxsig` at 1.0.0.

### 2.1 `libpdx-font` — bitmap glyph store + text metrics

**Purpose.** One library every graphical repo (except `libpdx-event`)
either links or consumes via metrics records. Ships:

- A **glyph store** (8x16 bitmap font at v1, copied bit-exact from
  `src/kernel/core/drivers/fb_font.pdx`'s `_fb_font` `[u8;4096]` so
  kernel-console text and userspace text render identically); one
  additional 16x32 face at M5 for HiDPI-adjacent use.
- A **metrics API** — `font_open(name) -> FontHandle`,
  `font_metrics(handle) -> FontMetricsRecord`,
  `font_glyph(handle, codepoint) -> GlyphRef` (a pointer+dims into the
  glyph store, ownership stays with the handle).
- A **text layout helper** — `font_layout_line(handle, text, x, y) ->
  Vec<GlyphPlacement>` (position each glyph on the baseline; monospaced
  advance at v1, per-glyph advance is a G5/M5 stretch item that stays
  behind a feature flag until proportional fonts arrive).
- **US-ASCII + Latin-1 v1** (256 glyphs, the same range `fb_font.pdx`
  covers). UTF-8 handling parses multi-byte sequences and emits a
  fallback glyph (the "missing character" glyph at index `0x7F`)
  for anything outside 0x00..0xFF — matches postui's own v1 posture
  under the width-table model.

**Ships in wave:** R102.M1..M5. Blocks `libpdx-gfx`.M2 (glyph render)
and `pdxterm`.M2 (needs a monospaced face + metrics). Does not block
`libpdx-event`, `svc-compositor` (compositor draws no text of its
own at v1 — the WM does), `svc-wm`.M1..M2.

### 2.2 `libpdx-gfx` — CPU-side draw primitives

**Purpose.** The one library every graphical app links to draw pixels.
Ships:

- **Surface handle** — `gfx_surface_open(width, height) ->
  SurfaceHandle` mints a `KIND_SURFACE` (§7.2.1) whose backing is a
  `KIND_MEMORY` allocation the compositor can read at present time; the
  handle wraps the writable mmap of that memory.
- **Draw primitives** — `gfx_fill_rect(surf, x, y, w, h, color)`,
  `gfx_blit(dst_surf, dx, dy, src_surf, sx, sy, w, h)`,
  `gfx_draw_line(surf, x0, y0, x1, y1, color, width)`,
  `gfx_draw_glyph(surf, x, y, glyph, fg, bg)`. All operate in
  BGRA8888. Line drawing uses integer Bresenham at v1; anti-aliasing is
  a G4 deliverable (§8.4). Alpha handling: source-over blend with
  premultiplied alpha in sRGB space (§0.3).
- **Damage-tracking helpers** — `gfx_damage_reset(surf)`,
  `gfx_damage_add(surf, x, y, w, h)`, `gfx_damage_take(surf) ->
  DamageRect`. The compositor at present time reads accumulated damage
  rects and blits only those regions to the scanout buffer; this is the
  R102 analogue of `KIND_TUI_CANVAS`'s row-level damage diff, at
  rect granularity rather than per-cell.
- **Commit** — `gfx_commit(surf)` publishes the current back-buffer +
  damage set to the compositor as a `SurfaceCommitRecord@0.1` via the
  `svc.compositor` IPC endpoint. This is the only synchronous point in
  the client-side draw loop.

**Ships in wave:** R102.M1..M5. Blocks every graphical app (`pdxclock`,
`pdxwatch`, `pdxpaint`, `pdxterm`).M2+.

### 2.3 `libpdx-event` — client-side event routing

**Purpose.** The one library every graphical app links to receive
input. Ships:

- **Subscription** — `event_subscribe(surface_handle) ->
  EventChannel`. Registers with `svc-compositor` (via IPC) that the
  caller wants events destined for the window backing `surface_handle`.
- **Blocking read** — `event_next(chan, timeout_ms) ->
  Result<InputEventRecord, EventErr>`. Blocks up to `timeout_ms` for
  the next event; returns `NO_EVENT` on timeout, an
  `InputEventRecord@0.1` (§5.2) on delivery.
- **Non-blocking drain** — `event_poll(chan) -> Vec<InputEventRecord>`.
  Returns every event queued at call time, empty if none.
- **Focus queries** — `event_has_focus(chan) -> bool`. Convenience
  wrapper over the last-seen focus event.

Kept separate from `libpdx-gfx` because a headless app that only wants
to observe input (imagine a keybinding daemon) needs event subscription
without linking any drawing code, and vice versa.

**Ships in wave:** R102.M1..M5. Blocks every interactive app
(`pdxpaint`, `pdxterm`).M2+; `pdxclock` and `pdxwatch` at v1 do not
consume input (they render on a timer and exit on window-close, which
is a `WindowRecord` state change, not an input event — a shape a
future round can revisit).

### 2.4 `svc-compositor` — the compositor service

**Purpose.** The one process that holds the framebuffer cap. Owns:

- **The scanout cap** — a `KIND_FB_SCANOUT` (§7.2.1) obtained at boot
  from the loader/kernel, held for the compositor's whole lifetime. No
  other process ever gets a copy; a compositor crash cascades into a
  cap revocation the R101 restart-policy handler catches (§7.2.4).
- **The window table** — one row per live window, each row holding the
  window's `KIND_SURFACE` cap (borrowed from the client), its screen-
  space position (as decided by `svc-wm`), and its Z-order.
- **The render loop** — HPET-derived tick at 60 Hz, best effort. Each
  tick: (1) drain the WM's placement queue; (2) drain each window's
  damage set; (3) for every damaged screen region, walk the window
  table front-to-back, composite the topmost opaque region into the
  scanout buffer; (4) emit `PresentRecord@0.1` (§5.5) with the tick
  number, damaged pixel count, and wall-clock duration.
- **The input pump** — subscribes to the R101 focus-routed input
  channel (§7.2.2), receives raw HID events tagged with the focused
  window id, materializes each as `InputEventRecord@0.1`, and delivers
  it to that window's client via the client's event subscription.
- **The query surface** — registers `svc.compositor` on `svc_broker`,
  exposes `list-windows`, `get-focus`, `get-geometry`,
  `screenshot-region` as typed-record query ops (§0.2).

Single-compositor by construction (§0.5); no plugin surface.

**Ships in wave:** R102.M1..M5. Blocks `svc-wm`.M2 (WM can't place
what the compositor doesn't hold), `pdxterm`.M2, every graphical app
M2+. M3 blocked on R101.M1 (framebuffer-scanout cap).

### 2.5 `svc-wm` — the window manager

**Purpose.** A **separate** process from the compositor (per Pillar 6:
compositor lockup does not kill WM policy that the compositor's own
render loop still needs). Owns:

- **Placement policy** — a simple tiling policy at v1 (fixed-column
  vertical tiling, one column per open app; `pdxpaint`-style "full
  screen this one window" via a modifier-key). No floating windows at
  v1 (floating is a G7 gesture story); tiling was picked because it
  removes an entire class of window-placement-ambiguity records nobody
  has to explain to `pdxwatch`'s query surface.
- **Decoration** — 1-pixel focus outline (blue when focused, gray
  otherwise). No title bars at v1 (title bars need proportional text
  layout that libpdx-font v1 does not provide; a monospaced-title-bar
  path is a stretch item flagged at §8.6).
- **Focus policy** — click-to-focus, plus a keyboard shortcut
  (`Alt+Tab`) cycling forward through the tile stack. Focus is a
  `KIND_INPUT_FOCUS` (§7.2.2) minted by the WM and consumed by the
  compositor's input pump.
- **Keyboard shortcuts** — `Alt+F4` closes the focused window (sends a
  `WindowRecord` state=CLOSING to the client via its event channel),
  `Alt+Space` opens a WM-owned command palette (v1: a fixed 3-command
  menu — swap-columns, close-focused, quit-wm; palette is a stretch
  extension point).

**Ships in wave:** R102.M1..M5. Blocks nothing downstream — apps
subscribe to their own event channels regardless of WM policy. But
`boot_r102_input_route` needs a live WM to route the "close this
window" test case, so M4 test wiring depends on `svc-wm`.M3.

### 2.6 `pdxterm` — framebuffer terminal emulator

**Purpose.** A **graphical** alternative to the UART TTY, running as a
normal windowed app. Renders a terminal grid onto its own
`KIND_SURFACE`; sinks user keyboard input to a child shell process via
a `KIND_PTY` (§7.2.3). Semantically a peer of `postui-top` but
graphics-backed rather than tty-backed.

- **Grid size** — 80x25 default, resizable to the window's current
  pixel dims / 8x16 glyph size (integer only; the window resizer snaps
  the window to whole-glyph multiples).
- **Rendering** — one `gfx_draw_glyph` call per cell per redraw, damage
  tracked per row (a scrollback advance dirties every visible row
  once). Text color: 8-color ANSI palette baked in.
- **Input** — subscribes via libpdx-event; forwards keydown events
  through the pty as UTF-8 bytes (Enter → `0x0A`, arrow keys → the
  standard `ESC [ A/B/C/D` sequences, ctrl-modified letters → the
  corresponding control code).
- **Shell** — spawns whichever shell is at `/bin/shell` as its child
  and connects both directions of the pty; on shell exit, pdxterm
  closes its window.

**Ships in wave:** R102.M1..M5. Blocks nothing (it's a top-of-stack
consumer). M2 blocked on `libpdx-gfx`.M2, `libpdx-event`.M2,
`libpdx-font`.M2. M3 blocked on the pty kind (§7.2.3, itself an R101
ask).

### 2.7 `pdxclock` — reference clock app

**Purpose.** The **smallest useful** window app. Renders a
`HH:MM:SS` digital clock on a 128x48 window, updates once per second.

- **Rendering** — one full-window redraw per second (small enough that
  damage tracking is not worth the complexity; the whole window is
  always damaged).
- **Input** — none. Closes on WM-sent `WindowRecord` state=CLOSING.
- **Time source** — `sys_clock_monotonic_ns` (already landed, per
  syscall-table refresh).

**Ships in wave:** R102.M1..M5. Blocks nothing; used at M4 as the
`boot_r102_first_window` smoke's actor.

### 2.8 `pdxwatch` — system-monitor GUI

**Purpose.** The graphical peer of `postui-top`. Reads the same live-
system query surface `postui-top` reads (via semantic-pipe), renders
CPU/memory/network as bar-graph and sparkline widgets.

- **Data source** — subscribes to the existing system-metrics
  semantic-pipe stream (assumes `postui-top`'s upstream endpoint;
  §8.7 flags "does that endpoint exist yet outside postui" as an open
  question this plan does not resolve — worst case, pdxwatch reads
  the same `KIND_SYS_STAT` cap postui-top does and does its own
  aggregation, at extra client-side cost).
- **Rendering** — three widgets stacked vertically: a CPU bar (one bar
  per online CPU), a memory usage bar (used/free/cached tri-color), a
  network sparkline (last-N-samples per interface). All drawn with
  `libpdx-gfx` rect + line primitives; text labels via
  `gfx_draw_glyph`.
- **Input** — clicking a CPU bar cycles that bar's detail mode
  (compact/expanded); pressing `q` closes the window.
- **Update rate** — 1 Hz. Damage tracked per widget region.

**Ships in wave:** R102.M1..M5. Blocks nothing.

### 2.9 `pdxpaint` — reference paint app

**Purpose.** The **input-heavy** reference app. Freehand drawing with
the pointer; exercises pointer routing, drag events, and full-surface
persistent state (the canvas the user is painting on).

- **Canvas** — the entire window is a single BGRA8888 buffer the app
  owns as a `KIND_SURFACE` back-buffer.
- **Input** — subscribes via libpdx-event; on `PointerButtonDown` starts
  a stroke, on `PointerMove` extends it (Bresenham line from previous
  point), on `PointerButtonUp` closes it. Color palette is a fixed
  8-swatch row at the bottom of the window.
- **Keyboard** — `c` clears the canvas, `s` saves to a file (needs a
  KIND_PDXFS_FILE write cap; v1 saves as raw BGRA to `~/pdxpaint.bgra`,
  a `.png` writer is a future round), `u` undoes the last stroke (v1
  keeps the last 16 strokes as a bounded ring of damage-rect+pre-image
  records — same undo posture cp/mv/rm land under R90-XREPO.010.M1-004,
  scaled to a client-local ring).

**Ships in wave:** R102.M1..M5. Blocks nothing; used at M4 as the
`boot_r102_input_route` smoke's actor (drag a stroke, assert the pixels
show up).

---

## 3. Per-repo M1..M5

Every repo has the same five milestones (M1 scaffold + API freeze, M2
real body on today's primitives, M3 real body on R101 primitives, M4
smokes, M5 signed release), but *what lands where* differs per repo.
This section lays each repo's five out; §4 turns each M into
individual issues.

### 3.1 `libpdx-font`

- **M1** — repo scaffold; caps.decl (KIND_MEMORY for glyph store);
  frozen public API stubs.
- **M2** — glyph store: `_libpdx_font_8x16` as an `@include_bytes`
  copy of `fb_font.pdx`'s `_fb_font` (bit-exact); `font_open("default")`
  returns the 8x16 handle; `font_glyph` returns a `GlyphRef` into the
  store; text-layout returns fixed-advance placements.
- **M3** — `FontMetricsRecord@0.1` emission on `font_metrics(handle)`;
  fallback-line-based per §0.2 until schema registry lands.
- **M4** — smokes: bit-exact glyph equivalence to kernel-console,
  UTF-8-out-of-range fallback glyph, per-line layout correctness for a
  seeded 80-char string.
- **M5** — second face (16x32) landed as an additional
  `font_open("default-large")` handle; signed release.

### 3.2 `libpdx-gfx`

- **M1** — repo scaffold; caps.decl (KIND_MEMORY for surface, IPC
  endpoint for compositor commit); frozen public API stubs;
  `SurfaceHandle` type defined.
- **M2** — real bodies against a stub `KIND_SURFACE` that is just a
  bare KIND_MEMORY at v1 (real KIND_SURFACE lands at M3). `gfx_fill_rect`,
  `gfx_blit`, `gfx_draw_line` (Bresenham), `gfx_draw_glyph` (walks
  `libpdx-font`'s glyph bitmap, writes BGRA cells); damage tracking as
  a client-side rect ring.
- **M3** — real `KIND_SURFACE` mint via §7.2.1; `gfx_commit` sends
  `SurfaceCommitRecord@0.1` to svc-compositor over IPC.
- **M4** — smokes: rect equivalence across the four color combinations,
  line rendering for the 8 octant cases, glyph-row equivalence to
  `libpdx-font`'s glyph store.
- **M5** — signed release.

### 3.3 `libpdx-event`

- **M1** — repo scaffold; caps.decl (IPC endpoint for compositor
  subscription); frozen public API stubs; `InputEventRecord@0.1`
  layout frozen.
- **M2** — real subscription over IPC to a stub compositor endpoint
  (real endpoint at svc-compositor.M2); local event ring; blocking
  `event_next` using the R51 sched-wait (dep on R90-XREPO.011.M1-001);
  `event_poll` non-blocking drain.
- **M3** — consumes real compositor-emitted events (svc-compositor
  M3 landing); focus-state cache updated on FOCUS_IN/OUT events.
- **M4** — smokes: subscribe → receive fixture event → assert record
  fields; timeout path; focus-cache correctness.
- **M5** — signed release.

### 3.4 `svc-compositor`

- **M1** — repo scaffold; caps.decl (KIND_FB_SCANOUT — real cap
  arrives at M3, stub at M1/M2; IPC endpoints for client + WM +
  broker registration); frozen wire protocol; startup sequence:
  register `svc.compositor` on svc_broker, spin an accept loop for
  client subscriptions.
- **M2** — real body against **loader-mapped LFB** (§7.1.1) as a
  hard-coded VA + dims (no cap boundary yet — R102 says explicitly
  this is the M2 posture); render loop ticks at 60 Hz off HPET; window
  table lives; client `SurfaceCommitRecord@0.1` receives are honored
  by blitting the surface's damage rects into the LFB. **No input pump
  at M2** — input work is entirely M3 material.
- **M3** — replace loader-LFB with real `KIND_FB_SCANOUT` cap (§7.2.1);
  input pump subscribes to R101 focus-routed channel (§7.2.2);
  `InputEventRecord@0.1` delivery to clients; query surface
  (`list-windows`, `get-focus`, `get-geometry`, `screenshot-region`)
  wired.
- **M4** — smokes: `boot_r102_first_pixel` (compositor solo, no client,
  paints the whole scanout blue); `boot_r102_window_present` (pdxclock
  window shows up); `boot_r102_input_route` (pdxpaint drag stroke shows
  up); `boot_r102_screenshot` (screenshot query returns correct pixel
  digest).
- **M5** — signed release.

### 3.5 `svc-wm`

- **M1** — repo scaffold; caps.decl (KIND_INPUT_FOCUS for focus mint —
  stub at M1/M2, real at M3; IPC endpoint to compositor); frozen wire
  protocol; startup: connect to `svc.compositor`, register as WM.
- **M2** — real body over stub-focus: tiling policy (compute the new
  tile map on every window add/remove, send placement events to
  compositor); 1-pixel focus outline; `Alt+Tab` cycle; `Alt+F4` close.
- **M3** — real KIND_INPUT_FOCUS mint; `Alt+Space` command palette
  (fixed 3 commands: swap-columns, close-focused, quit-wm).
- **M4** — smokes: tile arithmetic for 1/2/3/4 windows; focus cycle;
  close-focused; palette dispatch.
- **M5** — signed release.

### 3.6 `pdxterm`

- **M1** — repo scaffold; caps.decl (libpdx-gfx surface, libpdx-event
  chan, KIND_PTY — stub at M1/M2, real at M3, plus KIND_PROCESS for
  child spawn); argv parser; window creation stub.
- **M2** — grid math + full-window redraw over libpdx-gfx + libpdx-font;
  keyboard-input pass-through to a **stub pty** that echoes back
  (real pty at M3); scrollback ring (256 rows).
- **M3** — real pty spawn (§7.2.3); connect to /bin/shell; ANSI escape
  parsing for the 8-color palette + cursor movement.
- **M4** — smokes: rendering identity for a seeded 80x25 grid; shell
  echo round-trip; cursor movement correctness.
- **M5** — signed release.

### 3.7 `pdxclock`

- **M1** — repo scaffold; caps.decl (libpdx-gfx, libpdx-event, clock);
  argv parser; window creation.
- **M2** — full-window HH:MM:SS render every second; libpdx-gfx +
  libpdx-font composition; no input handling (closes on WindowRecord
  CLOSING).
- **M3** — WindowRecord CLOSING handling wired via libpdx-event.M3.
- **M4** — smokes: single-second visible output; close on WM-quit.
- **M5** — signed release.

### 3.8 `pdxwatch`

- **M1** — repo scaffold; caps.decl (libpdx-gfx, libpdx-event, sys-stat
  cap or whatever postui-top uses); argv parser; window creation.
- **M2** — three widget layout; CPU bar per online CPU; memory tri-color
  bar; network sparkline (last-N ring); 1 Hz refresh; damage-per-widget.
- **M3** — click-to-cycle-detail per CPU bar; `q` to quit.
- **M4** — smokes: seeded stat stream renders expected bar heights;
  click cycles correctly; keyboard quit.
- **M5** — signed release.

### 3.9 `pdxpaint`

- **M1** — repo scaffold; caps.decl (libpdx-gfx, libpdx-event,
  KIND_PDXFS_FILE for save); argv parser; window creation.
- **M2** — pointer-driven stroke drawing over libpdx-gfx (Bresenham
  segments between consecutive pointer positions); color palette bar;
  keyboard shortcuts (`c` clear, `s` save-to-disk).
- **M3** — undo ring (16 strokes, per-stroke damage-rect + pre-image).
- **M4** — smokes: scripted-input drag → assert pixel; save-file
  round-trip; undo correctness.
- **M5** — signed release.

---

## 4. Issue list

Every issue below uses the R90-XREPO body template: **Scope** (2–4
sentences) · **Files touched** · **Fingerprint** · **Effort** (S/M/L) ·
**Deps**. Fingerprints follow the `... ok [legacy: ... OK]` shape.
Issue titles use the numbering `R102.M<M>-<seq> <short-title>` and the
**Target repo** field names which satellite owns the issue.

Total issue count: **114** (nine repos × avg ~13 issues each).

### 4.1 `libpdx-font` (11 issues)

#### R102.M1-001 libpdx-font: repo scaffold

**Scope:** Create the new repo with README, MIT LICENSE,
`find-paideia-as.sh` submodule pin (mirror libpdx-audit), `.gitignore`,
empty `src/` skeleton. No code yet.

**Target repo:** `paideia-os/libpdx-font` (new).

**Files touched:** entire new repo skeleton.

**Fingerprint:** n/a (scaffolding). Verification: `find-paideia-as.sh`
passes; submodule-addable from monorepo.

**Effort:** S · **Deps:** none.

#### R102.M1-002 libpdx-font: caps.decl + public API stubs

**Scope:** Land `caps.decl` (KIND_MEMORY for the embedded glyph
store); freeze the public API (`font_open`, `font_metrics`,
`font_glyph`, `font_layout_line`, `FontHandle`, `GlyphRef`,
`GlyphPlacement`, `FontMetricsRecord`); stub bodies that return
`FONT_STUB` for every call.

**Files touched:** `caps.decl`, `src/font.pdx`, `src/types.pdx`.

**Fingerprint:** libpdx-font api stub ok [legacy: LIBPDX-FONT API STUB OK]

**Effort:** S · **Deps:** M1-001.

#### R102.M2-001 libpdx-font: 8x16 glyph store from fb_font.pdx

**Scope:** Copy `_fb_font` bit-exact via `@include_bytes` into
`_libpdx_font_8x16`; `font_open("default")` returns a real handle;
`font_glyph(h, cp)` returns a `GlyphRef` for ASCII codepoints, the
fallback glyph (`0x7F`) for others; UTF-8 multi-byte parsing rejects
non-Latin-1 cleanly to the fallback path.

**Files touched:** `src/font.pdx`, `src/glyph_store_8x16.pdx`,
`assets/fb_font.bin` (copied from `src/kernel/core/drivers/fb_font.pdx`
source-of-truth), tests.

**Fingerprint:** libpdx-font 8x16 ok [legacy: LIBPDX-FONT 8X16 OK]

**Effort:** M · **Deps:** M1-002.

#### R102.M2-002 libpdx-font: fixed-advance text layout

**Scope:** `font_layout_line(handle, text, x, y) ->
Vec<GlyphPlacement>` for the 8x16 handle; monospaced advance = glyph
width (8px); baseline computation from the metrics record; handles the
full-line width bound (returns a truncated placement vec, no wrapping
at v1 — wrapping is caller responsibility).

**Files touched:** `src/layout.pdx`, tests.

**Fingerprint:** libpdx-font layout ok [legacy: LIBPDX-FONT LAYOUT OK]

**Effort:** S · **Deps:** M2-001.

#### R102.M2-003 libpdx-font: metrics record

**Scope:** `font_metrics(handle)` returns a `FontMetricsRecord@0.1`
(§5.4) populated for the 8x16 face; ascent=13, descent=3, line-height=16,
advance=8; emission via the fallback-line-based path (§0.2) until schema
registry lands.

**Files touched:** `src/metrics.pdx`, tests.

**Fingerprint:** libpdx-font metrics ok [legacy: LIBPDX-FONT METRICS OK]

**Effort:** S · **Deps:** M2-001.

#### R102.M3-001 libpdx-font: schema-registry integration

**Scope:** When schema registry (R90-XREPO.012.M4-001) is live,
`font_metrics` binds `FontMetricsRecord@0.1` by name and emits with the
real handle; retains fallback path behind a feature flag until schema
handle is confirmed non-zero.

**Files touched:** `src/metrics.pdx`, tests.

**Fingerprint:** libpdx-font schema ok [legacy: LIBPDX-FONT SCHEMA OK]

**Effort:** S · **Deps:** M2-003, R90-XREPO.012.M4-001 (external).

#### R102.M4-001 libpdx-font: glyph equivalence smoke vs fb_font.pdx

**Scope:** Test that walks every glyph 0..255 in both the userspace
store and the kernel's `fb_font_row(glyph, row)` accessor via a
kernel-side witness, and asserts bit-exact equality per row per glyph.

**Files touched:** `tests/glyph_equivalence.pdx`.

**Fingerprint:** libpdx-font eq fb-font ok [legacy: LIBPDX-FONT EQ FB-FONT OK]

**Effort:** S · **Deps:** M2-001.

#### R102.M4-002 libpdx-font: UTF-8 fallback smoke

**Scope:** Test that feeds `font_glyph` a curated set of non-Latin-1
codepoints (multi-byte UTF-8 sequences: em-dash, curly quotes, a CJK
character, an emoji) and asserts each returns the `0x7F` fallback
glyph; test that a malformed UTF-8 sequence also returns the fallback
(no crash).

**Files touched:** `tests/utf8_fallback.pdx`.

**Fingerprint:** libpdx-font utf8-fallback ok [legacy: LIBPDX-FONT UTF8-FALLBACK OK]

**Effort:** S · **Deps:** M2-001.

#### R102.M4-003 libpdx-font: layout correctness smoke

**Scope:** Test that lays out a seeded 80-char string, asserts placements
are at x = 0, 8, 16, ..., 632, all with y = baseline.

**Files touched:** `tests/layout.pdx`.

**Fingerprint:** libpdx-font layout correct ok [legacy: LIBPDX-FONT LAYOUT CORRECT OK]

**Effort:** S · **Deps:** M2-002.

#### R102.M5-001 libpdx-font: 16x32 face

**Scope:** Ship a second face at 16x32 pixels (Latin-1 subset,
generated from the 8x16 via 2x nearest-neighbor upsample at v1 — a
distinct hand-drawn face is a future round); `font_open("default-large")`
returns its handle; metrics record populated.

**Files touched:** `src/glyph_store_16x32.pdx`,
`assets/fb_font_16x32.bin`, `src/font.pdx`, tests.

**Fingerprint:** libpdx-font 16x32 ok [legacy: LIBPDX-FONT 16X32 OK]

**Effort:** M · **Deps:** M2-001.

#### R102.M5-002 libpdx-font: signed 1.0.0 release

**Scope:** Dual-signed manifest, .pdxdoc, CHANGELOG-1.0, mirror push.
Standard.

**Files touched:** `manifest.pdxsig`, `doc/libpdx-font.pdxdoc`, `CHANGELOG.md`.

**Fingerprint:** libpdx-font 1.0.0 signed ok [legacy: LIBPDX-FONT 1.0.0 SIGNED OK]

**Effort:** S · **Deps:** M4-001, M4-002, M4-003, M5-001.

### 4.2 `libpdx-gfx` (13 issues)

#### R102.M1-001 libpdx-gfx: repo scaffold

**Scope:** Create the new repo, standard scaffolding.

**Target repo:** `paideia-os/libpdx-gfx` (new).

**Files touched:** entire new repo skeleton.

**Fingerprint:** n/a.

**Effort:** S · **Deps:** none.

#### R102.M1-002 libpdx-gfx: caps.decl + API surface freeze

**Scope:** Land `caps.decl` (KIND_MEMORY for surface backing;
KIND_IPC_ENDPOINT for compositor commit); freeze `SurfaceHandle`,
`Color`, `DamageRect`, `SurfaceCommitRecord`, and the public draw
signatures.

**Files touched:** `caps.decl`, `src/gfx.pdx`, `src/types.pdx`.

**Fingerprint:** libpdx-gfx api stub ok [legacy: LIBPDX-GFX API STUB OK]

**Effort:** S · **Deps:** M1-001.

#### R102.M2-001 libpdx-gfx: surface open over KIND_MEMORY stub

**Scope:** `gfx_surface_open(w, h)` mints a KIND_MEMORY of size
`w*h*4`, maps it writable, returns a handle wrapping the mmap ptr +
dims + damage ring. No KIND_SURFACE derivation at M2 — that is M3
material.

**Files touched:** `src/surface.pdx`, tests.

**Fingerprint:** libpdx-gfx surface open ok [legacy: LIBPDX-GFX SURFACE OPEN OK]

**Effort:** M · **Deps:** M1-002.

#### R102.M2-002 libpdx-gfx: fill_rect + blit

**Scope:** `gfx_fill_rect` writes a solid BGRA color into a rect; clips
to surface bounds; adds the rect to the damage ring. `gfx_blit` copies
a src rect into a dst rect (same or different surface); handles
overlapping src/dst by choosing scan direction.

**Files touched:** `src/draw_rect.pdx`, `src/blit.pdx`, tests.

**Fingerprint:** libpdx-gfx rect+blit ok [legacy: LIBPDX-GFX RECT+BLIT OK]

**Effort:** M · **Deps:** M2-001.

#### R102.M2-003 libpdx-gfx: draw_line via Bresenham

**Scope:** Integer Bresenham line; handles all 8 octants; width=1 at v1
(width>1 is a stretch — v1 supports it by drawing parallel offset
lines, no anti-aliasing).

**Files touched:** `src/draw_line.pdx`, tests.

**Fingerprint:** libpdx-gfx line ok [legacy: LIBPDX-GFX LINE OK]

**Effort:** M · **Deps:** M2-001.

#### R102.M2-004 libpdx-gfx: draw_glyph over libpdx-font

**Scope:** `gfx_draw_glyph(surf, x, y, glyph, fg, bg)` walks the
`GlyphRef` bitmap, writes fg for set bits and bg for clear bits.
Consumes libpdx-font.M2-001's glyph store.

**Files touched:** `src/draw_glyph.pdx`, tests.

**Fingerprint:** libpdx-gfx glyph ok [legacy: LIBPDX-GFX GLYPH OK]

**Effort:** M · **Deps:** M2-001, libpdx-font.M2-001.

#### R102.M2-005 libpdx-gfx: damage tracking

**Scope:** `gfx_damage_reset/add/take` back the per-surface damage ring;
`take` returns the coalesced damage set (adjacent-rect merge is
optional at v1 — safe to return the raw ring).

**Files touched:** `src/damage.pdx`, tests.

**Fingerprint:** libpdx-gfx damage ok [legacy: LIBPDX-GFX DAMAGE OK]

**Effort:** S · **Deps:** M2-001.

#### R102.M3-001 libpdx-gfx: real KIND_SURFACE mint

**Scope:** Retire the bare-KIND_MEMORY M2 posture; `gfx_surface_open`
now mints a `KIND_SURFACE` (§7.2.1) whose parent is the KIND_MEMORY it
allocated; handle wraps the surface cap slot + mapped ptr.

**Files touched:** `src/surface.pdx`, tests.

**Fingerprint:** libpdx-gfx kind-surface ok [legacy: LIBPDX-GFX KIND-SURFACE OK]

**Effort:** M · **Deps:** M2-001, R101 KIND_SURFACE (§7.2.1).

#### R102.M3-002 libpdx-gfx: commit → svc-compositor

**Scope:** `gfx_commit(surf)` sends `SurfaceCommitRecord@0.1` to the
`svc.compositor` IPC endpoint carrying the surface cap slot + damage
set; blocks on ack (compositor confirms it has queued the commit).

**Files touched:** `src/commit.pdx`, tests.

**Fingerprint:** libpdx-gfx commit ok [legacy: LIBPDX-GFX COMMIT OK]

**Effort:** M · **Deps:** M3-001, svc-compositor.M3-001.

#### R102.M4-001 libpdx-gfx: fill_rect equivalence smoke

**Scope:** Test that fills 4 rects of the 4 canonical colors (opaque
black, white, red, green) at 4 corners; reads the surface back and
asserts pixel-exact per rect.

**Files touched:** `tests/fill_rect_smoke.pdx`.

**Fingerprint:** libpdx-gfx fill-rect smoke ok [legacy: LIBPDX-GFX FILL-RECT SMOKE OK]

**Effort:** S · **Deps:** M2-002.

#### R102.M4-002 libpdx-gfx: line 8-octant smoke

**Scope:** Test that draws 8 lines, one per octant, from a common
origin; asserts each traversed pixel matches a golden set.

**Files touched:** `tests/line_octants.pdx`.

**Fingerprint:** libpdx-gfx line-octants ok [legacy: LIBPDX-GFX LINE-OCTANTS OK]

**Effort:** S · **Deps:** M2-003.

#### R102.M4-003 libpdx-gfx: glyph render smoke

**Scope:** Test that renders every glyph 0..255 into a 32x16 grid,
computes a BLAKE3 digest over the whole surface, and asserts it equals
a committed golden digest.

**Files touched:** `tests/glyph_render.pdx`.

**Fingerprint:** libpdx-gfx glyph-render ok [legacy: LIBPDX-GFX GLYPH-RENDER OK]

**Effort:** S · **Deps:** M2-004.

#### R102.M5-001 libpdx-gfx: signed 1.0.0 release

**Scope:** Standard signed release.

**Files touched:** `manifest.pdxsig`, `doc/libpdx-gfx.pdxdoc`, `CHANGELOG.md`.

**Fingerprint:** libpdx-gfx 1.0.0 signed ok [legacy: LIBPDX-GFX 1.0.0 SIGNED OK]

**Effort:** S · **Deps:** M4-001, M4-002, M4-003.

### 4.3 `libpdx-event` (11 issues)

#### R102.M1-001 libpdx-event: repo scaffold

**Scope:** Standard scaffolding.

**Target repo:** `paideia-os/libpdx-event` (new).

**Files touched:** entire new repo skeleton.

**Fingerprint:** n/a.

**Effort:** S · **Deps:** none.

#### R102.M1-002 libpdx-event: caps.decl + API + InputEventRecord layout

**Scope:** `caps.decl` (KIND_IPC_ENDPOINT for compositor subscription);
freeze `EventChannel`, `event_subscribe`, `event_next`, `event_poll`,
`event_has_focus`; freeze `InputEventRecord@0.1` (§5.2) layout.

**Files touched:** `caps.decl`, `src/event.pdx`, `src/record.pdx`.

**Fingerprint:** libpdx-event api stub ok [legacy: LIBPDX-EVENT API STUB OK]

**Effort:** S · **Deps:** M1-001.

#### R102.M2-001 libpdx-event: subscribe over stub compositor

**Scope:** `event_subscribe(surf)` opens an IPC channel to
`svc.compositor` (stub endpoint at M2, real at M3); stores channel
handle; returns EventChannel.

**Files touched:** `src/subscribe.pdx`, tests.

**Fingerprint:** libpdx-event subscribe ok [legacy: LIBPDX-EVENT SUBSCRIBE OK]

**Effort:** S · **Deps:** M1-002.

#### R102.M2-002 libpdx-event: blocking event_next via sched-wait

**Scope:** `event_next(chan, timeout_ms)` parks on the channel's
wait-key via `sys_sched_wait` (R90-XREPO.011.M1-001); returns first
event on the ring, `NO_EVENT` on timeout, `CHANNEL_CLOSED` if
compositor revoked.

**Files touched:** `src/event_next.pdx`, tests.

**Fingerprint:** libpdx-event next ok [legacy: LIBPDX-EVENT NEXT OK]

**Effort:** M · **Deps:** M2-001, R90-XREPO.011.M1-001 (external).

#### R102.M2-003 libpdx-event: non-blocking event_poll

**Scope:** `event_poll(chan)` drains every queued event and returns
them as a Vec; no wait, no timeout; returns empty if ring is empty.

**Files touched:** `src/event_poll.pdx`, tests.

**Fingerprint:** libpdx-event poll ok [legacy: LIBPDX-EVENT POLL OK]

**Effort:** S · **Deps:** M2-002.

#### R102.M2-004 libpdx-event: focus-cache

**Scope:** `event_has_focus(chan)` returns the last-seen FOCUS_IN/OUT
state; updated as events flow through `event_next` and `event_poll`.

**Files touched:** `src/focus_cache.pdx`, tests.

**Fingerprint:** libpdx-event focus-cache ok [legacy: LIBPDX-EVENT FOCUS-CACHE OK]

**Effort:** S · **Deps:** M2-002.

#### R102.M3-001 libpdx-event: consume real compositor endpoint

**Scope:** Retire stub compositor; connect to the live
`svc.compositor` name via svc_broker; wire receive-side to unmarshal
`InputEventRecord@0.1` from wire bytes (fallback-line-based per §0.2).

**Files touched:** `src/subscribe.pdx`, `src/wire.pdx`, tests.

**Fingerprint:** libpdx-event live ok [legacy: LIBPDX-EVENT LIVE OK]

**Effort:** M · **Deps:** M2-001, svc-compositor.M3-002.

#### R102.M4-001 libpdx-event: fixture-event round-trip smoke

**Scope:** Test that subscribes, receives a scripted fixture event
(pointer-move at coords 100,50), and asserts every field of the
returned InputEventRecord.

**Files touched:** `tests/fixture_roundtrip.pdx`.

**Fingerprint:** libpdx-event fixture ok [legacy: LIBPDX-EVENT FIXTURE OK]

**Effort:** S · **Deps:** M3-001.

#### R102.M4-002 libpdx-event: timeout path smoke

**Scope:** Test that calls `event_next(chan, 100)` on an idle channel;
asserts `NO_EVENT` returned after ≥ 100 ms; asserts wall-clock delta
sensible (< 200 ms).

**Files touched:** `tests/timeout.pdx`.

**Fingerprint:** libpdx-event timeout ok [legacy: LIBPDX-EVENT TIMEOUT OK]

**Effort:** S · **Deps:** M2-002.

#### R102.M4-003 libpdx-event: focus-cache correctness smoke

**Scope:** Test that scripts a FOCUS_IN, asserts `event_has_focus`
becomes true; scripts a FOCUS_OUT, asserts false; scripts a POINTER_MOVE
between, asserts focus cache does not flip.

**Files touched:** `tests/focus_cache.pdx`.

**Fingerprint:** libpdx-event focus-cache correct ok [legacy: LIBPDX-EVENT FOCUS-CACHE CORRECT OK]

**Effort:** S · **Deps:** M2-004.

#### R102.M5-001 libpdx-event: signed 1.0.0 release

**Scope:** Standard signed release.

**Files touched:** `manifest.pdxsig`, `doc/libpdx-event.pdxdoc`, `CHANGELOG.md`.

**Fingerprint:** libpdx-event 1.0.0 signed ok [legacy: LIBPDX-EVENT 1.0.0 SIGNED OK]

**Effort:** S · **Deps:** M4-001, M4-002, M4-003.

### 4.4 `svc-compositor` (16 issues)

#### R102.M1-001 svc-compositor: repo scaffold

**Scope:** Standard scaffolding.

**Target repo:** `paideia-os/svc-compositor` (new).

**Files touched:** entire new repo skeleton.

**Fingerprint:** n/a.

**Effort:** S · **Deps:** none.

#### R102.M1-002 svc-compositor: caps.decl + wire protocol freeze

**Scope:** `caps.decl` (KIND_FB_SCANOUT stub, KIND_IPC_ENDPOINT for
client subs, KIND_IPC_ENDPOINT for WM channel, KIND_IPC_ENDPOINT for
svc_broker registration); freeze wire request codes
(SUBSCRIBE_WINDOW, COMMIT_SURFACE, WM_PLACE_WINDOW, WM_SET_FOCUS,
QUERY_LIST_WINDOWS, QUERY_GET_FOCUS, QUERY_GET_GEOMETRY,
QUERY_SCREENSHOT_REGION); explicit protocol version = R102-v0.

**Files touched:** `caps.decl`, `src/proto.pdx`, `src/main.pdx`.

**Fingerprint:** svc-compositor wire-protocol frozen ok [legacy: SVC-COMPOSITOR WIRE-PROTOCOL FROZEN OK]

**Effort:** S · **Deps:** M1-001.

#### R102.M1-003 svc-compositor: broker registration + accept loop

**Scope:** On startup, register `svc.compositor` on svc_broker
(R90-XREPO.012.M2-002 pattern); spawn an accept loop that receives
client `SUBSCRIBE_WINDOW` requests and stores each subscription in a
per-window row.

**Files touched:** `src/main.pdx`, `src/accept_loop.pdx`, tests.

**Fingerprint:** svc-compositor accept-loop ok [legacy: SVC-COMPOSITOR ACCEPT-LOOP OK]

**Effort:** M · **Deps:** M1-002.

#### R102.M2-001 svc-compositor: loader-LFB scanout body

**Scope:** Retrieve the loader-mapped LFB VA + dims from the boot
handoff record (§7.1.1); store as scanout target; no cap boundary yet
(hard-coded VA); render loop's blit path writes into this buffer.

**Files touched:** `src/scanout_loader.pdx`, tests.

**Fingerprint:** svc-compositor loader-lfb ok [legacy: SVC-COMPOSITOR LOADER-LFB OK]

**Effort:** M · **Deps:** M1-003.

#### R102.M2-002 svc-compositor: window table + Z-order

**Scope:** Window-row struct (window_id, client_surface_slot,
screen_pos, dims, z_order, state); WM_PLACE_WINDOW request updates
position + z_order; window table ordered by z_order for front-to-back
composition.

**Files touched:** `src/window_table.pdx`, tests.

**Fingerprint:** svc-compositor window-table ok [legacy: SVC-COMPOSITOR WINDOW-TABLE OK]

**Effort:** M · **Deps:** M1-003.

#### R102.M2-003 svc-compositor: 60 Hz render loop over HPET

**Scope:** HPET-derived tick at 60 Hz (best effort); each tick: drain
placement queue, drain per-window damage, blit damaged regions
front-to-back into scanout buffer; emit PresentRecord@0.1 with tick +
damaged-pixel-count + wall-clock duration.

**Files touched:** `src/render_loop.pdx`, `src/present_record.pdx`, tests.

**Fingerprint:** svc-compositor render-loop ok [legacy: SVC-COMPOSITOR RENDER-LOOP OK]

**Effort:** L · **Deps:** M2-001, M2-002.

#### R102.M2-004 svc-compositor: COMMIT_SURFACE handler

**Scope:** On COMMIT_SURFACE, look up the client's window row, borrow
the client's surface cap slot, merge the delivered damage into the
window's damage ring; reply with a queued-ack. Actual blit deferred to
render loop's next tick.

**Files touched:** `src/commit_surface.pdx`, tests.

**Fingerprint:** svc-compositor commit-surface ok [legacy: SVC-COMPOSITOR COMMIT-SURFACE OK]

**Effort:** M · **Deps:** M2-003.

#### R102.M3-001 svc-compositor: real KIND_FB_SCANOUT cap

**Scope:** Retire hard-coded loader-LFB VA; retrieve KIND_FB_SCANOUT
cap from loader-passed cap slot (§7.2.1); scanout write path uses the
mapped VA the cap advertises. Compositor's crash-cascade path
(§7.2.4) revokes the cap on exit.

**Files touched:** `src/scanout_cap.pdx`, tests.

**Fingerprint:** svc-compositor kind-fb-scanout ok [legacy: SVC-COMPOSITOR KIND-FB-SCANOUT OK]

**Effort:** M · **Deps:** M2-001, R101 KIND_FB_SCANOUT (§7.2.1).

#### R102.M3-002 svc-compositor: input pump over R101 focus channel

**Scope:** Subscribe to R101's focus-routed input channel (§7.2.2);
each event carries the focused window id already resolved (WM told
compositor which id has focus; kernel tags events); materialize as
InputEventRecord@0.1 and route to that window's subscribed client via
its event channel.

**Files touched:** `src/input_pump.pdx`, `src/event_route.pdx`, tests.

**Fingerprint:** svc-compositor input-pump ok [legacy: SVC-COMPOSITOR INPUT-PUMP OK]

**Effort:** L · **Deps:** M2-003, R101 focus-routed input channel (§7.2.2).

#### R102.M3-003 svc-compositor: query surface (list/focus/geometry)

**Scope:** Wire QUERY_LIST_WINDOWS → returns Vec<WindowRecord@0.1>;
QUERY_GET_FOCUS → returns focused WindowRecord + focus event summary;
QUERY_GET_GEOMETRY → returns DisplayGeometryRecord@0.1 (dims, format,
DPI-hint).

**Files touched:** `src/query.pdx`, tests.

**Fingerprint:** svc-compositor query ok [legacy: SVC-COMPOSITOR QUERY OK]

**Effort:** M · **Deps:** M2-002, M3-001.

#### R102.M3-004 svc-compositor: screenshot query

**Scope:** QUERY_SCREENSHOT_REGION → returns a pixel-region record
(x, y, w, h, BGRA bytes, BLAKE3 digest of the bytes). Region is
clamped to scanout dims; oversized region returns SCREENSHOT_TOO_LARGE.

**Files touched:** `src/screenshot.pdx`, tests.

**Fingerprint:** svc-compositor screenshot ok [legacy: SVC-COMPOSITOR SCREENSHOT OK]

**Effort:** M · **Deps:** M3-001.

#### R102.M4-001 svc-compositor: boot_r102_first_pixel smoke

**Scope:** Boot smoke: compositor solo (no clients), paints the whole
scanout blue (single fill_rect over the whole geometry), one present
tick, verifies scanout memory reads back as expected pixel value in
the first + middle + last positions.

**Files touched:** `src/kernel/boot/witness/r102_first_pixel.pdx`
(monorepo-side), svc-compositor test hooks.

**Fingerprint:** first pixel ok [legacy: FIRST PIXEL OK]

**Effort:** M · **Deps:** M3-001.

#### R102.M4-002 svc-compositor: boot_r102_window_present smoke

**Scope:** Boot smoke: pdxclock starts, opens a window, presents its
first frame; compositor blits it; witness reads scanout at pdxclock's
window origin and asserts non-blue pixels present.

**Files touched:** `src/kernel/boot/witness/r102_window_present.pdx`,
svc-compositor test hooks.

**Fingerprint:** window present ok [legacy: WINDOW PRESENT OK]

**Effort:** M · **Deps:** M4-001, pdxclock.M2-002.

#### R102.M4-003 svc-compositor: boot_r102_input_route smoke

**Scope:** Boot smoke: pdxpaint starts, scripted-HID-injection drags a
diagonal stroke; witness reads pdxpaint's window scanout region and
asserts pixels along the stroke line are the current-color palette
entry.

**Files touched:** `src/kernel/boot/witness/r102_input_route.pdx`,
svc-compositor test hooks.

**Fingerprint:** input route ok [legacy: INPUT ROUTE OK]

**Effort:** L · **Deps:** M3-002, pdxpaint.M2-002.

#### R102.M4-004 svc-compositor: boot_r102_screenshot smoke

**Scope:** Boot smoke: after `boot_r102_window_present`, issue
QUERY_SCREENSHOT_REGION over the full display; verify BLAKE3 digest
matches a committed golden.

**Files touched:** `src/kernel/boot/witness/r102_screenshot.pdx`,
svc-compositor test hooks.

**Fingerprint:** screenshot ok [legacy: SCREENSHOT OK]

**Effort:** M · **Deps:** M3-004, M4-002.

#### R102.M5-001 svc-compositor: signed 1.0.0 release

**Scope:** Standard signed release.

**Files touched:** `manifest.pdxsig`, `doc/svc-compositor.pdxdoc`, `CHANGELOG.md`.

**Fingerprint:** svc-compositor 1.0.0 signed ok [legacy: SVC-COMPOSITOR 1.0.0 SIGNED OK]

**Effort:** S · **Deps:** M4-001..M4-004.

### 4.5 `svc-wm` (12 issues)

#### R102.M1-001 svc-wm: repo scaffold

**Scope:** Standard scaffolding.

**Target repo:** `paideia-os/svc-wm` (new).

**Files touched:** entire new repo skeleton.

**Fingerprint:** n/a.

**Effort:** S · **Deps:** none.

#### R102.M1-002 svc-wm: caps.decl + wire protocol freeze

**Scope:** `caps.decl` (KIND_INPUT_FOCUS stub; KIND_IPC_ENDPOINT to
compositor); freeze the WM→compositor request set (WM_PLACE_WINDOW,
WM_SET_FOCUS, WM_CLOSE_WINDOW); freeze the compositor→WM notification
set (WM_WINDOW_OPENED, WM_WINDOW_CLOSED, WM_KEYCHORD).

**Files touched:** `caps.decl`, `src/proto.pdx`, `src/main.pdx`.

**Fingerprint:** svc-wm wire-protocol frozen ok [legacy: SVC-WM WIRE-PROTOCOL FROZEN OK]

**Effort:** S · **Deps:** M1-001.

#### R102.M1-003 svc-wm: connect to svc.compositor + register

**Scope:** On startup, resolve `svc.compositor` from svc_broker,
connect, send REGISTER_WM (a new compositor-side request code M1-002
adds); accept notifications thereafter.

**Files touched:** `src/main.pdx`, `src/connect.pdx`, tests.

**Fingerprint:** svc-wm register ok [legacy: SVC-WM REGISTER OK]

**Effort:** M · **Deps:** M1-002, svc-compositor.M1-003.

#### R102.M2-001 svc-wm: tiling policy (fixed-column vertical)

**Scope:** On WM_WINDOW_OPENED, add the window to the tile list;
recompute one column per window (widths = display_width /
n_windows, heights = full); send WM_PLACE_WINDOW for each. On
WM_WINDOW_CLOSED, remove and recompute.

**Files touched:** `src/tile_policy.pdx`, tests.

**Fingerprint:** svc-wm tiling ok [legacy: SVC-WM TILING OK]

**Effort:** M · **Deps:** M1-003.

#### R102.M2-002 svc-wm: focus outline decoration

**Scope:** On focus change, send WM_PLACE_WINDOW with a decoration hint
(the outline is composited by svc-compositor over the window's own
pixels — a 1-px blue rect around the focused window, gray for
unfocused). Decoration hints frozen in the wire protocol at M1-002.

**Files touched:** `src/decoration.pdx`, tests.

**Fingerprint:** svc-wm focus-outline ok [legacy: SVC-WM FOCUS-OUTLINE OK]

**Effort:** S · **Deps:** M2-001.

#### R102.M2-003 svc-wm: Alt+Tab cycle + Alt+F4 close

**Scope:** On WM_KEYCHORD(Alt+Tab), advance focus one step through the
tile list, send WM_SET_FOCUS; on WM_KEYCHORD(Alt+F4), send
WM_CLOSE_WINDOW for the focused window; compositor forwards CLOSING
event to that window's client.

**Files touched:** `src/shortcuts.pdx`, tests.

**Fingerprint:** svc-wm shortcuts ok [legacy: SVC-WM SHORTCUTS OK]

**Effort:** M · **Deps:** M2-001, M2-002.

#### R102.M3-001 svc-wm: real KIND_INPUT_FOCUS mint

**Scope:** Retire focus stub; mint KIND_INPUT_FOCUS (§7.2.2) for the
focused window; hand cap to compositor via WM_SET_FOCUS; compositor
uses it to tag input events for that window.

**Files touched:** `src/focus.pdx`, tests.

**Fingerprint:** svc-wm kind-input-focus ok [legacy: SVC-WM KIND-INPUT-FOCUS OK]

**Effort:** M · **Deps:** M2-002, R101 KIND_INPUT_FOCUS (§7.2.2).

#### R102.M3-002 svc-wm: Alt+Space command palette

**Scope:** On Alt+Space, WM opens its own 200x100 window over the
current focused window; renders a 3-command menu (swap-columns,
close-focused, quit-wm) via its own libpdx-gfx surface; on click or
Enter, dispatches the command and closes the palette. Palette itself
is a regular window and appears in list-windows queries.

**Files touched:** `src/palette.pdx`, tests.

**Fingerprint:** svc-wm palette ok [legacy: SVC-WM PALETTE OK]

**Effort:** M · **Deps:** M3-001, libpdx-gfx.M3-002.

#### R102.M4-001 svc-wm: tile arithmetic smoke

**Scope:** Test with a mock compositor stream that opens 1, then 2,
then 3, then 4 windows and asserts the computed tile layout at each
step matches the golden geometry table.

**Files touched:** `tests/tile_math.pdx`.

**Fingerprint:** svc-wm tile-math ok [legacy: SVC-WM TILE-MATH OK]

**Effort:** S · **Deps:** M2-001.

#### R102.M4-002 svc-wm: focus cycle smoke

**Scope:** Test with 3 open windows that scripts 3× Alt+Tab and asserts
the WM_SET_FOCUS sequence hits windows 1→2→3→1.

**Files touched:** `tests/focus_cycle.pdx`.

**Fingerprint:** svc-wm focus-cycle ok [legacy: SVC-WM FOCUS-CYCLE OK]

**Effort:** S · **Deps:** M2-003.

#### R102.M4-003 svc-wm: palette dispatch smoke

**Scope:** Test that opens the palette, scripted-clicks each of the 3
commands (in three separate runs) and asserts each dispatches the
expected downstream action (swap window order, WM_CLOSE_WINDOW to
focused, quit signal).

**Files touched:** `tests/palette_dispatch.pdx`.

**Fingerprint:** svc-wm palette-dispatch ok [legacy: SVC-WM PALETTE-DISPATCH OK]

**Effort:** M · **Deps:** M3-002.

#### R102.M5-001 svc-wm: signed 1.0.0 release

**Scope:** Standard signed release.

**Files touched:** `manifest.pdxsig`, `doc/svc-wm.pdxdoc`, `CHANGELOG.md`.

**Fingerprint:** svc-wm 1.0.0 signed ok [legacy: SVC-WM 1.0.0 SIGNED OK]

**Effort:** S · **Deps:** M4-001..M4-003.

### 4.6 `pdxterm` (13 issues)

#### R102.M1-001 pdxterm: repo scaffold

**Scope:** Standard scaffolding.

**Target repo:** `paideia-os/pdxterm` (new).

**Files touched:** entire new repo skeleton.

**Fingerprint:** n/a.

**Effort:** S · **Deps:** none.

#### R102.M1-002 pdxterm: caps.decl + argv + window stub

**Scope:** `caps.decl` (KIND_SURFACE via libpdx-gfx, KIND_IPC via
libpdx-event, KIND_PTY stub, KIND_PROCESS for shell spawn); argv
parser (`--geometry=WxH`, `--font=default|default-large`);
`gfx_surface_open` returns a real surface; blank window shown.

**Files touched:** `caps.decl`, `src/main.pdx`, `src/argv.pdx`.

**Fingerprint:** pdxterm window ok [legacy: PDXTERM WINDOW OK]

**Effort:** S · **Deps:** M1-001, libpdx-gfx.M1-002.

#### R102.M2-001 pdxterm: grid math + full-window redraw

**Scope:** Compute (cols, rows) = (win_w / glyph_w, win_h / glyph_h)
snapping to whole glyph multiples; full-window redraw walks the grid,
`gfx_draw_glyph` per cell with fg/bg from the ANSI palette; damage-per-
row (a scrollback advance dirties every visible row).

**Files touched:** `src/grid.pdx`, `src/render.pdx`, tests.

**Fingerprint:** pdxterm grid ok [legacy: PDXTERM GRID OK]

**Effort:** M · **Deps:** M1-002, libpdx-gfx.M2-004, libpdx-font.M2-001.

#### R102.M2-002 pdxterm: keyboard→bytes pass-through (stub pty)

**Scope:** Subscribe to input events via libpdx-event; on KEYDOWN,
translate to UTF-8 bytes (letters direct, Enter → `0x0A`, Backspace →
`0x7F`, arrow keys → `ESC [ A/B/C/D`, Ctrl-letters → the corresponding
control code); write to a stub pty that echoes back as if a real shell
had produced output.

**Files touched:** `src/keymap.pdx`, `src/pty_stub.pdx`, tests.

**Fingerprint:** pdxterm keyboard ok [legacy: PDXTERM KEYBOARD OK]

**Effort:** M · **Deps:** M2-001, libpdx-event.M2-002.

#### R102.M2-003 pdxterm: scrollback ring (256 rows)

**Scope:** Fixed-256-row ring buffer for scrollback; on newline past
last visible row, ring advances by one; PageUp/PageDown key events
scroll the view (M4 will add scrollbar rendering).

**Files touched:** `src/scrollback.pdx`, tests.

**Fingerprint:** pdxterm scrollback ok [legacy: PDXTERM SCROLLBACK OK]

**Effort:** M · **Deps:** M2-001.

#### R102.M3-001 pdxterm: real KIND_PTY spawn + shell attach

**Scope:** Mint KIND_PTY (§7.2.3); spawn /bin/shell as child with
stdin/stdout/stderr wired to the pty (via existing sys_execve +
sys_dup2); replace pty-stub reads/writes with real pty ops; on shell
exit, close pdxterm window.

**Files touched:** `src/pty_real.pdx`, `src/shell_spawn.pdx`, tests.

**Fingerprint:** pdxterm pty ok [legacy: PDXTERM PTY OK]

**Effort:** L · **Deps:** M2-002, R101 KIND_PTY (§7.2.3).

#### R102.M3-002 pdxterm: ANSI escape parser (8-color palette + cursor moves)

**Scope:** State-machine parser for `ESC [ ... m` (SGR: reset,
bold, fg 30-37/90-97, bg 40-47/100-107) and `ESC [ ... H` (cursor
move); unknown escape sequences swallowed silently (log to
libpdx-audit for diagnosis).

**Files touched:** `src/ansi.pdx`, tests.

**Fingerprint:** pdxterm ansi ok [legacy: PDXTERM ANSI OK]

**Effort:** M · **Deps:** M3-001.

#### R102.M4-001 pdxterm: rendering identity smoke

**Scope:** Test that seeds an 80x25 grid with a known pattern (an
alphabet-repetition + solid color blocks), renders once, BLAKE3-digests
the surface and asserts equal to a golden.

**Files touched:** `tests/render_identity.pdx`.

**Fingerprint:** pdxterm render-identity ok [legacy: PDXTERM RENDER-IDENTITY OK]

**Effort:** S · **Deps:** M2-001.

#### R102.M4-002 pdxterm: shell echo round-trip smoke

**Scope:** Boot-smoke variant: pdxterm starts, spawns /bin/shell,
scripted-HID types `echo hello`\n, witness reads pdxterm's surface and
finds the string `hello` rendered in the row after the prompt.

**Files touched:** `src/kernel/boot/witness/r102_pdxterm_hello.pdx`,
pdxterm test hooks.

**Fingerprint:** pdxterm hello ok [legacy: PDXTERM HELLO OK]

**Effort:** L · **Deps:** M3-001, M3-002.

#### R102.M4-003 pdxterm: cursor movement smoke

**Scope:** Test that pipes `ESC [ 5;10 H hello` into pdxterm, asserts
"hello" renders at row 5 column 10.

**Files touched:** `tests/cursor_move.pdx`.

**Fingerprint:** pdxterm cursor-move ok [legacy: PDXTERM CURSOR-MOVE OK]

**Effort:** S · **Deps:** M3-002.

#### R102.M4-004 pdxterm: scrollback smoke

**Scope:** Test that pipes 30 lines into an 80x25 pdxterm, asserts
PageUp scrolls back to reveal the earliest line; PageDown returns to
live view.

**Files touched:** `tests/scrollback.pdx`.

**Fingerprint:** pdxterm scrollback smoke ok [legacy: PDXTERM SCROLLBACK SMOKE OK]

**Effort:** S · **Deps:** M2-003, M3-002.

#### R102.M5-001 pdxterm: signed 1.0.0 release

**Scope:** Standard signed release.

**Files touched:** `manifest.pdxsig`, `doc/pdxterm.pdxdoc`, `CHANGELOG.md`.

**Fingerprint:** pdxterm 1.0.0 signed ok [legacy: PDXTERM 1.0.0 SIGNED OK]

**Effort:** S · **Deps:** M4-001..M4-004.

### 4.7 `pdxclock` (8 issues)

#### R102.M1-001 pdxclock: repo scaffold

**Scope:** Standard scaffolding.

**Target repo:** `paideia-os/pdxclock` (new).

**Files touched:** entire new repo skeleton.

**Fingerprint:** n/a.

**Effort:** S · **Deps:** none.

#### R102.M1-002 pdxclock: caps.decl + argv + 128x48 window

**Scope:** `caps.decl` (KIND_SURFACE, libpdx-event chan, monotonic clock
syscall); argv parser (`--face=default|default-large`); open a 128x48
surface.

**Files touched:** `caps.decl`, `src/main.pdx`, `src/argv.pdx`.

**Fingerprint:** pdxclock window ok [legacy: PDXCLOCK WINDOW OK]

**Effort:** S · **Deps:** M1-001, libpdx-gfx.M1-002.

#### R102.M2-001 pdxclock: HH:MM:SS render + 1 Hz loop

**Scope:** Format wall-clock as HH:MM:SS (8 glyphs at 8px each = 64px
wide, centered in a 128px window); render every second; entire window
is damaged each tick.

**Files touched:** `src/render.pdx`, tests.

**Fingerprint:** pdxclock hh-mm-ss ok [legacy: PDXCLOCK HH-MM-SS OK]

**Effort:** M · **Deps:** M1-002, libpdx-gfx.M2-004, libpdx-font.M2-001.

#### R102.M3-001 pdxclock: WindowRecord CLOSING handling

**Scope:** Poll events each second (event_poll); on WindowRecord
CLOSING event, exit cleanly (releases surface cap, closes IPC).

**Files touched:** `src/close.pdx`, tests.

**Fingerprint:** pdxclock close ok [legacy: PDXCLOCK CLOSE OK]

**Effort:** S · **Deps:** M2-001, libpdx-event.M3-001.

#### R102.M4-001 pdxclock: seeded-time smoke

**Scope:** Boot smoke: seed clock to 12:34:56 via monotonic-clock hook
(kernel witness fixture); start pdxclock; witness reads the surface
and finds "12:34:56" rendered.

**Files touched:** `src/kernel/boot/witness/r102_pdxclock.pdx`.

**Fingerprint:** pdxclock seeded-time ok [legacy: PDXCLOCK SEEDED-TIME OK]

**Effort:** M · **Deps:** M2-001.

#### R102.M4-002 pdxclock: close-on-WM-quit smoke

**Scope:** Test that starts pdxclock, sends WM_CLOSE_WINDOW, asserts
pdxclock exits within one second (event_poll cadence).

**Files touched:** `tests/close_on_wm_quit.pdx`.

**Fingerprint:** pdxclock close-on-wm-quit ok [legacy: PDXCLOCK CLOSE-ON-WM-QUIT OK]

**Effort:** S · **Deps:** M3-001.

#### R102.M5-001 pdxclock: signed 1.0.0 release

**Scope:** Standard signed release.

**Files touched:** `manifest.pdxsig`, `doc/pdxclock.pdxdoc`, `CHANGELOG.md`.

**Fingerprint:** pdxclock 1.0.0 signed ok [legacy: PDXCLOCK 1.0.0 SIGNED OK]

**Effort:** S · **Deps:** M4-001, M4-002.

### 4.8 `pdxwatch` (10 issues)

#### R102.M1-001 pdxwatch: repo scaffold

**Scope:** Standard scaffolding.

**Target repo:** `paideia-os/pdxwatch` (new).

**Files touched:** entire new repo skeleton.

**Fingerprint:** n/a.

**Effort:** S · **Deps:** none.

#### R102.M1-002 pdxwatch: caps.decl + 480x360 window

**Scope:** `caps.decl` (KIND_SURFACE, libpdx-event, KIND_SYS_STAT or
whatever postui-top uses); argv parser; open a 480x360 surface;
placeholder layout (three empty widget rects).

**Files touched:** `caps.decl`, `src/main.pdx`, `src/argv.pdx`.

**Fingerprint:** pdxwatch window ok [legacy: PDXWATCH WINDOW OK]

**Effort:** S · **Deps:** M1-001, libpdx-gfx.M1-002.

#### R102.M2-001 pdxwatch: CPU bar-per-core widget

**Scope:** Read live per-CPU stats each second; render one horizontal
bar per online CPU (width scaled to load %); labels via
gfx_draw_glyph.

**Files touched:** `src/widget_cpu.pdx`, tests.

**Fingerprint:** pdxwatch cpu-widget ok [legacy: PDXWATCH CPU-WIDGET OK]

**Effort:** M · **Deps:** M1-002, libpdx-gfx.M2-002, libpdx-font.M2-001.

#### R102.M2-002 pdxwatch: memory tri-color widget

**Scope:** Read live memory stats each second; render one bar with
three colored segments (used, cached, free) scaled to bar width;
labels via gfx_draw_glyph.

**Files touched:** `src/widget_mem.pdx`, tests.

**Fingerprint:** pdxwatch mem-widget ok [legacy: PDXWATCH MEM-WIDGET OK]

**Effort:** M · **Deps:** M1-002.

#### R102.M2-003 pdxwatch: network sparkline widget

**Scope:** Read live per-interface bytes each second; maintain last-N
ring (N=60); render as sparkline via gfx_draw_line segments; labels
via gfx_draw_glyph.

**Files touched:** `src/widget_net.pdx`, tests.

**Fingerprint:** pdxwatch net-widget ok [legacy: PDXWATCH NET-WIDGET OK]

**Effort:** M · **Deps:** M1-002, libpdx-gfx.M2-003.

#### R102.M3-001 pdxwatch: click-cycle CPU detail + 'q' quit

**Scope:** Subscribe events; on POINTER_BUTTON_DOWN inside a CPU bar,
cycle that bar's detail mode (compact ↔ expanded — expanded shows
per-mode breakdown as sub-bars); on KEYDOWN 'q', exit.

**Files touched:** `src/input.pdx`, tests.

**Fingerprint:** pdxwatch input ok [legacy: PDXWATCH INPUT OK]

**Effort:** M · **Deps:** M2-001, libpdx-event.M3-001.

#### R102.M4-001 pdxwatch: seeded-stat render smoke

**Scope:** Boot smoke: seed sys-stat stream to a known snapshot (4
CPUs each at 50%, 8 GB used of 16, network rx=1000/tx=500 for eth0);
start pdxwatch; witness reads the surface and asserts each widget
region has the expected bar heights (via digest of the widget's
sub-rect).

**Files touched:** `src/kernel/boot/witness/r102_pdxwatch.pdx`.

**Fingerprint:** pdxwatch seeded-stat ok [legacy: PDXWATCH SEEDED-STAT OK]

**Effort:** M · **Deps:** M2-001, M2-002, M2-003.

#### R102.M4-002 pdxwatch: click-cycle smoke

**Scope:** Scripted-click into CPU bar #0; assert its detail mode
cycled from compact to expanded; verify sub-bar rendering appeared.

**Files touched:** `tests/click_cycle.pdx`.

**Fingerprint:** pdxwatch click-cycle ok [legacy: PDXWATCH CLICK-CYCLE OK]

**Effort:** S · **Deps:** M3-001.

#### R102.M4-003 pdxwatch: 'q'-quit smoke

**Scope:** Scripted keyboard 'q'; assert pdxwatch exits.

**Files touched:** `tests/keyboard_quit.pdx`.

**Fingerprint:** pdxwatch quit ok [legacy: PDXWATCH QUIT OK]

**Effort:** S · **Deps:** M3-001.

#### R102.M5-001 pdxwatch: signed 1.0.0 release

**Scope:** Standard signed release.

**Files touched:** `manifest.pdxsig`, `doc/pdxwatch.pdxdoc`, `CHANGELOG.md`.

**Fingerprint:** pdxwatch 1.0.0 signed ok [legacy: PDXWATCH 1.0.0 SIGNED OK]

**Effort:** S · **Deps:** M4-001..M4-003.

### 4.9 `pdxpaint` (10 issues)

#### R102.M1-001 pdxpaint: repo scaffold

**Scope:** Standard scaffolding.

**Target repo:** `paideia-os/pdxpaint` (new).

**Files touched:** entire new repo skeleton.

**Fingerprint:** n/a.

**Effort:** S · **Deps:** none.

#### R102.M1-002 pdxpaint: caps.decl + 640x480 window + palette bar

**Scope:** `caps.decl` (KIND_SURFACE, libpdx-event, KIND_PDXFS_FILE for
save); argv parser; open a 640x480 surface; render fixed 8-swatch
palette bar at bottom (each swatch 80x40).

**Files touched:** `caps.decl`, `src/main.pdx`, `src/argv.pdx`,
`src/palette_bar.pdx`.

**Fingerprint:** pdxpaint window ok [legacy: PDXPAINT WINDOW OK]

**Effort:** M · **Deps:** M1-001, libpdx-gfx.M1-002.

#### R102.M2-001 pdxpaint: pointer-driven stroke drawing

**Scope:** On POINTER_BUTTON_DOWN, start a stroke (record start point +
current color); on POINTER_MOVE while pressed, draw Bresenham line
from previous to current point in stroke color; on POINTER_BUTTON_UP,
close stroke.

**Files touched:** `src/stroke.pdx`, tests.

**Fingerprint:** pdxpaint stroke ok [legacy: PDXPAINT STROKE OK]

**Effort:** M · **Deps:** M1-002, libpdx-event.M2-002, libpdx-gfx.M2-003.

#### R102.M2-002 pdxpaint: palette bar click → color switch

**Scope:** On POINTER_BUTTON_DOWN in the palette bar region, set
current stroke color to the clicked swatch's color; highlight the
selected swatch with a border.

**Files touched:** `src/palette_bar.pdx`, tests.

**Fingerprint:** pdxpaint palette ok [legacy: PDXPAINT PALETTE OK]

**Effort:** S · **Deps:** M2-001.

#### R102.M2-003 pdxpaint: 'c' clear + 's' save-file

**Scope:** On KEYDOWN 'c', fill canvas with white (damage full canvas
region). On KEYDOWN 's', write canvas BGRA bytes to `~/pdxpaint.bgra`
via KIND_PDXFS_FILE write ops.

**Files touched:** `src/clear_save.pdx`, tests.

**Fingerprint:** pdxpaint save ok [legacy: PDXPAINT SAVE OK]

**Effort:** M · **Deps:** M2-001.

#### R102.M3-001 pdxpaint: undo ring (16 strokes)

**Scope:** Per stroke, capture pre-image of damaged canvas region
before drawing; push into 16-deep ring. On KEYDOWN 'u', pop most-recent
stroke, restore pre-image, damage that region. Ring is client-local
memory only (no persistence — reboot loses undo history).

**Files touched:** `src/undo.pdx`, tests.

**Fingerprint:** pdxpaint undo ok [legacy: PDXPAINT UNDO OK]

**Effort:** M · **Deps:** M2-001.

#### R102.M4-001 pdxpaint: scripted-drag stroke smoke

**Scope:** Boot smoke: pdxpaint starts, scripted HID injects
button-down at (100,100), move to (200,200), button-up; witness reads
canvas region and asserts pixels along the diagonal line are the
current stroke color.

**Files touched:** `src/kernel/boot/witness/r102_pdxpaint.pdx`.

**Fingerprint:** pdxpaint stroke-smoke ok [legacy: PDXPAINT STROKE-SMOKE OK]

**Effort:** M · **Deps:** M2-001.

#### R102.M4-002 pdxpaint: save-file round-trip smoke

**Scope:** After drawing a stroke, press 's', read
`~/pdxpaint.bgra` back via KIND_PDXFS_FILE read, compare to the
in-memory canvas byte-for-byte.

**Files touched:** `tests/save_roundtrip.pdx`.

**Fingerprint:** pdxpaint save-roundtrip ok [legacy: PDXPAINT SAVE-ROUNDTRIP OK]

**Effort:** M · **Deps:** M2-003.

#### R102.M4-003 pdxpaint: undo correctness smoke

**Scope:** Draw 3 strokes at known positions; press 'u' 3 times;
assert canvas is byte-exact to the pre-first-stroke state.

**Files touched:** `tests/undo.pdx`.

**Fingerprint:** pdxpaint undo-smoke ok [legacy: PDXPAINT UNDO-SMOKE OK]

**Effort:** M · **Deps:** M3-001.

#### R102.M5-001 pdxpaint: signed 1.0.0 release

**Scope:** Standard signed release.

**Files touched:** `manifest.pdxsig`, `doc/pdxpaint.pdxdoc`, `CHANGELOG.md`.

**Fingerprint:** pdxpaint 1.0.0 signed ok [legacy: PDXPAINT 1.0.0 SIGNED OK]

**Effort:** S · **Deps:** M4-001..M4-003.

### 4.10 paideia-os monorepo integration (10 issues)

The 9 satellites need matching monorepo work — submodules, build stage,
seed bins, boot smokes.

#### R102.MON-001 monorepo: 9 submodule adds

**Scope:** Nine new `[submodule "tools/user/<name>"]` entries in
`.gitmodules`, pinned at each repo's `r102-closed` tag once cut.

**Target repo:** `paideia-os/paideia-os`.

**Files touched:** `.gitmodules`, `tools/user/libpdx-font/`,
`tools/user/libpdx-gfx/`, `tools/user/libpdx-event/`,
`tools/user/svc-compositor/`, `tools/user/svc-wm/`,
`tools/user/pdxterm/`, `tools/user/pdxclock/`, `tools/user/pdxwatch/`,
`tools/user/pdxpaint/`.

**Fingerprint:** n/a (scaffolding).

**Effort:** S · **Deps:** each repo's M1-001.

#### R102.MON-002 monorepo: tools/build.sh r102-tools stage

**Scope:** New `r102-tools` stage in `tools/build.sh` parallel to
`r64v2-tools` / `r93-tools`; `SAT_LIBS_R102=(libpdx-font libpdx-gfx
libpdx-event)` `SAT_APPS_R102=(svc-compositor svc-wm pdxterm pdxclock
pdxwatch pdxpaint)`; same incremental-stamp + filtered-`-link`
discipline.

**Files touched:** `tools/build.sh`.

**Fingerprint:** r102 build stage ok [legacy: R102 BUILD STAGE OK]

**Effort:** M · **Deps:** MON-001.

#### R102.MON-003 monorepo: userbin_embed.S + bin_seeds.pdx

**Scope:** Six new `.incbin` lines (svc-compositor, svc-wm, pdxterm,
pdxclock, pdxwatch, pdxpaint; libraries not embedded) and six new
`/bin/<name>` seed rows in `bin_seeds.pdx`.

**Files touched:** `tools/userbin_embed.S`,
`src/kernel/boot/bin_seeds.pdx`.

**Fingerprint:** r102 bin seeds ok [legacy: R102 BIN SEEDS OK]

**Effort:** S · **Deps:** MON-002.

#### R102.MON-004 monorepo: boot_r102_first_pixel smoke wiring

**Scope:** Wire the `boot_r102_first_pixel` smoke into
`tools/run-qemu.sh` and `tools/build.sh` smoke-mode dispatch;
witness lives in `src/kernel/boot/witness/r102_first_pixel.pdx`.

**Files touched:** `tools/run-qemu.sh`, `tools/build.sh`,
`src/kernel/boot/witness/r102_first_pixel.pdx`,
`src/kernel/boot/kernel_main.pdx` (add smoke-mode dispatch).

**Fingerprint:** first pixel ok [legacy: FIRST PIXEL OK]

**Effort:** M · **Deps:** MON-003, svc-compositor.M4-001.

#### R102.MON-005 monorepo: boot_r102_window_present smoke wiring

**Scope:** As MON-004 for `boot_r102_window_present`.

**Files touched:** `tools/run-qemu.sh`, `tools/build.sh`,
`src/kernel/boot/witness/r102_window_present.pdx`,
`src/kernel/boot/kernel_main.pdx`.

**Fingerprint:** window present ok [legacy: WINDOW PRESENT OK]

**Effort:** M · **Deps:** MON-004, svc-compositor.M4-002.

#### R102.MON-006 monorepo: boot_r102_input_route smoke wiring

**Scope:** As MON-004 for `boot_r102_input_route`. Depends on the
HID-injection fixture existing in the smoke harness (osarch R101
concern, flagged in §7.2 if not landed).

**Files touched:** `tools/run-qemu.sh`, `tools/build.sh`,
`src/kernel/boot/witness/r102_input_route.pdx`,
`src/kernel/boot/kernel_main.pdx`.

**Fingerprint:** input route ok [legacy: INPUT ROUTE OK]

**Effort:** L · **Deps:** MON-005, svc-compositor.M4-003, R101 HID
injection fixture (§7.2.5).

#### R102.MON-007 monorepo: boot_r102_pdxterm_hello smoke wiring

**Scope:** As MON-004 for `boot_r102_pdxterm_hello`.

**Files touched:** `tools/run-qemu.sh`, `tools/build.sh`,
`src/kernel/boot/witness/r102_pdxterm_hello.pdx`,
`src/kernel/boot/kernel_main.pdx`.

**Fingerprint:** pdxterm hello ok [legacy: PDXTERM HELLO OK]

**Effort:** M · **Deps:** MON-006, pdxterm.M4-002.

#### R102.MON-008 monorepo: boot_r102_screenshot smoke wiring

**Scope:** As MON-004 for `boot_r102_screenshot`.

**Files touched:** `tools/run-qemu.sh`, `tools/build.sh`,
`src/kernel/boot/witness/r102_screenshot.pdx`,
`src/kernel/boot/kernel_main.pdx`.

**Fingerprint:** screenshot ok [legacy: SCREENSHOT OK]

**Effort:** M · **Deps:** MON-005, svc-compositor.M4-004.

#### R102.MON-009 monorepo: init.pdx spawn svc-compositor + svc-wm

**Scope:** Wire the boot init sequence (or equivalent) to spawn
svc-compositor before svc-wm before any graphical seed apps;
compositor blocks on scanout cap arrival, WM blocks on compositor
registration.

**Files touched:** `src/kernel/boot/init.pdx` (or existing
init-caps-sidecar per `design/loader/init-caps-sidecar.md`).

**Fingerprint:** r102 init sequence ok [legacy: R102 INIT SEQUENCE OK]

**Effort:** M · **Deps:** svc-compositor.M3-001, svc-wm.M3-001.

#### R102.MON-010 monorepo: design/graphics/r102-closure.md

**Scope:** Round closure doc summarizing landed vs deferred; matches
the retros pattern in `design/round-retrospectives/`.

**Files touched:** `design/round-retrospectives/r102-closure.md`.

**Fingerprint:** n/a (docs).

**Effort:** S · **Deps:** all M5-001 + all boot smoke wiring.

---

## 5. Semantic-pipe record schemas

All five register with the schema registry (paideia-os#2000 →
R90-XREPO.012) the day it lands; until then, every emission carries
the same fallback-line-based deferral header the R100 wave established.

### 5.1 `WindowRecord@0.1`

```
WindowRecord@0.1 {
  window_id:       u64
  client_pid:      u64
  surface_slot:    u64          # KIND_SURFACE cap slot the client holds
  screen_x:        i32
  screen_y:        i32
  width:           u32
  height:          u32
  z_order:         u8
  state:           enum { OPENING, LIVE, CLOSING, CLOSED }
  title:           string       # bounded 128-byte; v1 windows have no title bar so empty at v1
  ts_ns:           i128
}
```

Emitted on window state changes (OPENING at first commit, LIVE on WM
placement, CLOSING on WM_CLOSE_WINDOW, CLOSED on client exit). Query
surface `list-windows` returns Vec<WindowRecord@0.1>.

### 5.2 `InputEventRecord@0.1`

```
InputEventRecord@0.1 {
  window_id:       u64          # focused window this event routes to
  event_type:      enum { KEY_DOWN, KEY_UP, POINTER_MOVE, POINTER_BUTTON_DOWN,
                          POINTER_BUTTON_UP, FOCUS_IN, FOCUS_OUT, WINDOW_CLOSE }
  keycode:         u32          # HID usage code, 0 for non-key events
  modifiers:       u8           # bitflags SHIFT|CTRL|ALT|SUPER
  pointer_x:       i32          # window-local coords, 0 for non-pointer events
  pointer_y:       i32
  pointer_button:  u8           # 1=left, 2=middle, 3=right, 0 for non-button
  ts_ns:           i128
}
```

Delivered from compositor to client over the client's event
subscription channel; drawn from the R101 focus-routed input pump.

### 5.3 `DisplayGeometryRecord@0.1`

```
DisplayGeometryRecord@0.1 {
  scanout_id:      u64          # identifier for the scanout (v1 has one)
  width_px:        u32
  height_px:       u32
  pitch_bytes:     u32          # bytes per scanline (v1: width_px * 4)
  pixel_format:    enum { BGRA8888 }
  dpi_hint:        u32          # 96 if unknown; loader may seed a better value
  scale_factor:    u8           # 1, 2, or 3 (integer only, §0.3)
  ts_ns:           i128
}
```

Returned from `svc.compositor.get-geometry` query; refreshed on every
mode change (in v1 there are no mode changes — a stretch future round
adds R77 modeset event delivery).

### 5.4 `FontMetricsRecord@0.1`

```
FontMetricsRecord@0.1 {
  font_name:       string       # "default", "default-large"
  glyph_width_px:  u16          # monospaced at v1
  glyph_height_px: u16
  ascent_px:       u16
  descent_px:      u16
  line_height_px: u16
  advance_px:      u16          # monospaced == glyph_width_px at v1
  ts_ns:           i128
}
```

Returned from `libpdx-font.font_metrics(handle)`; also enumerable via a
future `svc.font.list-faces` query (out of R102 scope).

### 5.5 `PresentRecord@0.1`

```
PresentRecord@0.1 {
  tick_id:            u64
  scanout_id:         u64
  windows_composited: u16       # number of windows blitted this tick
  damaged_pixels:     u64
  frame_duration_ns:  u64       # wall-clock time to complete this frame
  target_period_ns:   u64       # nominal period (16_666_666 for 60 Hz best-effort)
  slipped:            bool      # frame_duration > target_period
  ts_ns:              i128
}
```

Emitted by the compositor once per render-loop tick; single record
regardless of window count. `slipped=true` at v1 is expected and not an
error — R102 does not commit to a 60 Hz SLO; the honest observability
is what matters. `svc.compositor.list-presents-last-N` is a future
query.

### 5.6 `SurfaceCommitRecord@0.1`

```
SurfaceCommitRecord@0.1 {
  window_id:       u64
  surface_slot:    u64
  damage_rects:    Vec<{x: i32, y: i32, w: u32, h: u32}>
  serial:          u64          # client-side commit serial for ordering
  ts_ns:           i128
}
```

Sent from client (via `libpdx-gfx.gfx_commit`) to compositor via IPC;
compositor ACKs with `serial` echoed. Not the "output" record class
(one per client action, not one per system event) but treated as a
schema for the wire.

---

## 6. Cross-repo dependency matrix

Rows are R102 milestones that depend on external work; columns are the
external repos/rounds providing it. `-` means no dep.

| Depended-on repo/round → | R101 kernel plan | R90-XREPO.011 elevate | R90-XREPO.012 schema-registry | paideia-as |
|---|---|---|---|---|
| libpdx-font.M2 | - | - | - | @include_bytes (landed) |
| libpdx-font.M3 | - | - | 012.M4-001 | - |
| libpdx-gfx.M2  | - | - | - | - |
| libpdx-gfx.M3  | 7.2.1 KIND_SURFACE | - | - | - |
| libpdx-event.M2| - | 011.M1-001 sched-wait | - | - |
| libpdx-event.M3| 7.2.2 focus routing | - | - | - |
| svc-compositor.M2 | 7.1.1 loader-LFB | - | - | - |
| svc-compositor.M3 | 7.2.1 + 7.2.2 + 7.2.4 | - | 012.M4-001 (query wire) | - |
| svc-wm.M3      | 7.2.2 KIND_INPUT_FOCUS | - | - | - |
| pdxterm.M3     | 7.2.3 KIND_PTY | - | - | - |
| pdxclock.M3    | - | - | - | - |
| pdxwatch.M3    | - | - | - | - |
| pdxpaint.M3    | - | - | - | - |
| MON-006 (input-route smoke) | 7.2.5 HID injection fixture | - | - | - |

Read: **R101 is the load-bearing external dep** — 5 satellite M3s and
one boot smoke depend on it. Every M1 and M2 is unblocked and can land
in parallel with R101 in flight. This is the same shape R100 took
against osarch's kernel-networking round.

---

## 7. Coordination with osarch's R101 kernel plan

### 7.1 What is already in-tree today

- **`src/kernel/core/drivers/fb_font.pdx`** — the 8x16 embedded font
  libpdx-font copies verbatim (§3.1). Fingerprint-equivalence test at
  libpdx-font.M4-001 ensures the copy stays in sync.
- **`src/kernel/core/drivers/fb_map.pdx`** (`fb_map_lfb` at L159) —
  the kernel-side LFB mapping at `0xFFFF_A000_0000_0000` (kernel-local
  VA). This is not directly usable by a user-mode compositor — it lives
  in kernel VA — but the underlying loader-passed physical framebuffer
  address and its dimensions are the substrate R101 needs to expose as
  a userspace-holdable cap (§7.2.1).
- **`src/kernel/core/cap/kind_display_engine.pdx`
  (0x16F)**, **`kind_display_output.pdx` (0x170)**,
  **`kind_display_mode.pdx` (0x171)**, **`kind_display_plane.pdx`
  (0x173)** — the six display kinds exist but modeset (R77) has not
  landed. `svc-compositor` M2/M3 explicitly do NOT consume these kinds
  (they consume the simpler loader-LFB path); a future round after
  R77 lands would re-plumb the compositor's scanout to hold a real
  `KIND_DISPLAY_PLANE` and program its modeset. That is not R102.
- **`src/kernel/core/cap/kind_tui_canvas.pdx` (0x1A6)** — the text-mode
  analog `KIND_SURFACE` (§7.2.1) mirrors in shape. Every derivation
  discipline (KIND_MEMORY parent + server-conversation reference,
  cascade on parent revocation, kind-checked mint gate) copies from
  this file.
- **`src/kernel/core/cap/kind_hid_device.pdx`**,
  **`kind_hid_event.pdx`**,
  **`src/kernel/core/ipc/hid_event_stream_channel.pdx`** — the input
  substrate. The compositor's input pump subscribes to
  hid_event_stream_channel today (M2 posture: no focus routing, every
  event goes to a default window). M3 needs the focus-routed variant
  (§7.2.2).
- **`sys_sched_wait`** landing under R90-XREPO.011.M1-001 —
  `libpdx-event.event_next` blocks on it. Already a documented dep,
  gated by the wave-3 landing order.

#### 7.1.1 The loader-LFB M2 posture

svc-compositor.M2 (§4.4.M2-001) consumes the LFB the loader mapped
already — same physical address the kernel's fb-console uses. Concretely:

- The loader passes the LFB physical address, dims (width/height),
  pitch, and pixel format in the boot handoff record already read by
  `fb_map_lfb`; svc-compositor at M2 reads the same handoff record
  from userspace (needs one small kernel escape: a
  `sys_bootinfo_get_lfb() -> (paddr, w, h, pitch, format)` syscall,
  §7.2.6, tiny surface).
- The compositor mmaps the physical range into its own address space
  (needs a `sys_mmap_physical(paddr, len, writable) -> vaddr` syscall
  gated on a specific "framebuffer" cap that the loader hands only to
  the compositor at boot — this is a smaller ask than the full
  KIND_FB_SCANOUT at §7.2.1 but larger than zero, and is the
  compositor's M2 blocker if osarch prefers to land the full cap
  first).
- **Simpler-M2 alternative** — instead of two smaller syscalls at M2
  and the full cap at M3, osarch could land only the full
  KIND_FB_SCANOUT cap and svc-compositor.M2 waits for it. That
  collapses M2 and M3, at the cost of svc-compositor.M2 not being
  independently landable (a scope loss the alternative-posture doc
  should acknowledge). **This plan defers the pick to osarch.**

### 7.2 What R102 asks R101 to provide

Every ask below has a fingerprint sentence — the string osarch's boot
witness should print on landing the primitive, so R102 satellites can
be gated on the fingerprint appearing in boot log rather than on a
tag/sha.

#### 7.2.1 KIND_FB_SCANOUT — userspace-holdable scanout cap

**Ask.** A new kind (`KIND_FB_SCANOUT`, ordinal reserved by osarch, in
the same band as `KIND_DISPLAY_PLANE`), derived over `KIND_MEMORY`,
that names one linear framebuffer + dims + format the compositor can
scan out of. Distinguishing from KIND_DISPLAY_PLANE: KIND_DISPLAY_PLANE
requires R77 modeset infra; KIND_FB_SCANOUT is the pre-R77 fallback
that names the loader-mapped GOP LFB directly. Once R77 lands,
KIND_FB_SCANOUT stays as the smoke-test / recovery-console path (per
Pillar P8, `next-wave-synthesis.md`) and is precisely the "reserved
plane on primary pipe" the recovery-console posture already commits
to; the compositor's normal path re-plumbs to KIND_DISPLAY_PLANE.

**Ops:** `PRESENT` (blocks on next V-sync-equivalent — v1: returns
immediately with slipped-frame semantics), `QUERY_GEOMETRY`,
`REVOKE`.

**Fingerprint sentence:** `fb scanout mint ok`, `fb scanout present ok`,
`fb scanout revoke ok`.

**Consumed by:** svc-compositor.M3-001. Also §7.2.4 (crash cascade).

#### 7.2.2 KIND_INPUT_FOCUS + focus-routed HID channel

**Ask.** (a) A new `KIND_INPUT_FOCUS` cap the WM mints for the focused
window, hands to the compositor; (b) an extension to the existing
`hid_event_stream_channel` (or a peer channel) that tags each event
with the current focus's window_id, using the KIND_INPUT_FOCUS cap
the compositor holds. This is the "input server that survives
compositor death" (Pillar P2) reduced to R102's scope: at v1 the
compositor IS the input router, but the cap boundary is drawn now so a
future round can split the input server out without a client-side
change.

**Ops on KIND_INPUT_FOCUS:** mint (WM only), revoke, transfer (WM
hands to compositor), QUERY_WINDOW_ID.

**Fingerprint sentence:** `kind input focus mint ok`, `hid focus route
ok`.

**Consumed by:** svc-compositor.M3-002, svc-wm.M3-001,
libpdx-event.M3-001.

#### 7.2.3 KIND_PTY

**Ask.** A pseudo-terminal cap kind: a bi-directional byte pipe with a
master end (pdxterm) and a slave end (the shell child's stdin/stdout/
stderr). This is a well-worn concept everywhere else — the R102
novelty is only the cap-shape.

**Ops:** mint (allocates a pair), write (master → slave or slave →
master), read (blocking with timeout), revoke (both ends).

**Fingerprint sentence:** `kind pty mint ok`, `kind pty read/write
ok`, `kind pty revoke ok`.

**Consumed by:** pdxterm.M3-001. Nothing else at R102.

#### 7.2.4 Compositor crash cascade

**Ask.** When svc-compositor's process dies (crash or clean exit),
KIND_FB_SCANOUT revokes automatically; the loader-passed "compositor
mint cap" (the authority to re-mint KIND_FB_SCANOUT) is handed to a
kernel-side restart handler (or a designated recovery-console process),
so the next compositor can start with a fresh scanout cap. In R102
scope this can be as simple as "kernel logs the crash, panics; hard-
reset needed" — but the cap-shape has to admit the eventual
restart-policy shape (`next-wave-synthesis.md` P8, `paideia-drm`
recovery-console). Concretely: KIND_FB_SCANOUT's revocation invariant
must be encoded in the mint gate so a second compositor cannot start
against a still-live cap.

**Fingerprint sentence:** `fb scanout revoke cascade ok`.

**Consumed by:** svc-compositor.M3-001 (design), MON-009 (init sequence
must be robust to crash-and-restart even if the recovery policy is
"log and halt" at v1).

#### 7.2.5 HID injection fixture for smoke harness

**Ask.** A boot-witness hook that lets a kernel-side test fixture
inject HID events (keydown, pointer-move, button-down/up) into the
`hid_event_stream_channel`. Small, kernel-only, gated on a boot flag.
Without this, `boot_r102_input_route` cannot script pdxpaint's stroke.

**Fingerprint sentence:** `hid inject ok`.

**Consumed by:** MON-006 (boot_r102_input_route smoke),
`boot_r102_pdxterm_hello` (types `echo hello` into pdxterm).

#### 7.2.6 sys_bootinfo_get_lfb (§7.1.1)

**Ask.** Only needed if osarch takes the two-syscalls-at-M2 posture
(§7.1.1's default over the alternative). A tiny read-only syscall
returning the loader's LFB tuple. Reserve next sysno.

**Fingerprint sentence:** `bootinfo lfb ok`.

**Consumed by:** svc-compositor.M2-001 (only if §7.1.1 alternative not
taken).

### 7.3 If R101 does not land in time

Each satellite's M1 + M2 lands regardless (they stub the R101 caps
exactly the way R100's M1/M2 stubbed unbuilt syscalls). M3 landings
block on the corresponding §7.2 item's fingerprint. M4 boot smokes
block on all M3 landings plus §7.2.5. M5 signed releases block on M4.

Escalation posture (mirroring the paideia-os ↔ paideia-as escalation
memory): if a R102 satellite discovers a gap in R101's landed caps that
was not §7.2 in advance, file an issue against `paideia-os/paideia-os`
under the `R101` milestone, push a stub in R102 that fails closed, and
resume R102's next issue. Do not block R102 on an unfiled R101 gap.

---

## 8. Deferred sub-scopes

### 8.1 Text: TrueType / OpenType / SDF-GPU

libpdx-font v1 is bitmap-only. TrueType parsing (fonttools-shape),
subpixel positioning, hinting, and BiDi/complex-script shaping are all
G5 material and requires a shape-engine substrate paideia-as does not
ship today. A future `libpdx-font-tt` sibling library would live at
the same repo shape; libpdx-font's public API (`FontHandle` opaque)
does not change.

### 8.2 Color: HDR + wide gamut + ICC

R102 composites in sRGB space with u8 saturating math. scRGB-linear
composition, ICC v4 profiles, wide-gamut display support (`Display P3`,
`Rec.2100`), and per-monitor color LUT programming are G6. A future
`libpdx-color` library owns these.

### 8.3 GPU-accelerated compositing (G7 hand-off contract)

R102's `svc-compositor` is CPU-only. G7's Vello/Vulkan compositor
replaces it. The public API contract R102 commits to for the G7 hand-off:

- **libpdx-gfx**: every public function keeps its signature. `SurfaceHandle`
  becomes opaque wrapper over KIND_SURFACE-with-KIND_GPU_BO-backing;
  the drawing calls become GPU submissions internally.
- **libpdx-event**: `InputEventRecord@0.1` becomes the input server's
  wire type unchanged.
- **svc-compositor** binary: replaced. Its wire protocol version (R102-v0)
  is refused by the G7 compositor with a clean version-mismatch reply;
  clients upgrade to a G7-shaped libpdx-gfx that speaks G7-vN.

### 8.4 2D anti-aliasing + fractional scaling

R102 draws with integer Bresenham; no AA. Fractional scaling is
refused. Both belong to G3/G4.

### 8.5 Remote display (VNC/RDP)

Not R102. A `svc-remote-display` sibling would wrap the compositor's
scanout cap and stream over TCP once the pdxcurl HTTP stack (R100)
lands. Explicit refusal at R102 removes the whole class of
KIND_CAP-crossing-network-boundary concerns from the compositor.

### 8.6 Window decorations (title bars, resize handles)

R102 ships a 1-px focus outline only. Full title bars need proportional
text layout (libpdx-font v1 gap). Resize handles need a WM interaction
mode R102's tiling posture forecloses. Both are pending a
libpdx-font-tt landing and a floating-window WM policy.

### 8.7 Accessibility

`KIND_A11Y_TREE` is a G10 concept. R102 does not attach an a11y tree to
any window. This is a real gap this plan calls out honestly rather than
half-implementing — an a11y tree that lies about the app's structure is
worse than none. When G10 lands, existing R102 apps get an a11y
attachment via a new opt-in library call; the compositor forwards the
tree to a screen-reader client.

### 8.8 Video playback + 3D

Both are G8+ material. R102 declines both.

### 8.9 IME + complex text input

R102 supports US-ASCII keyboard input only. No dead keys, no compose
sequences, no IBus/fcitx analog. Full IME is G11.

### 8.10 Single-compositor posture (§0.5)

Restated as a deferred choice: pluggable compositors are foreclosed at
R102. If a future round wants multi-compositor experimentation, the
KIND_FB_SCANOUT revocation-and-remint path (§7.2.4) is the mechanism —
but no plumbing exists at R102 for a compositor negotiation protocol,
and this plan actively recommends against ever adding one.

---

## 9. Landing order and first-pixel smoke

### 9.1 Whole-wave landing order (osarch R101 + softarch R102)

1. **R101 lands its M1** (KIND_FB_SCANOUT + sys_bootinfo_get_lfb or
   equivalent per §7.1.1's alternative). Softarch R102 satellites'
   M1+M2 land in parallel throughout — they do not block on R101.
2. **R101 lands its M2** (KIND_INPUT_FOCUS + focus-routed HID channel +
   HID injection fixture). Softarch svc-compositor.M3-002,
   svc-wm.M3-001 unblock.
3. **R101 lands its M3** (KIND_PTY + compositor crash cascade
   invariant). pdxterm.M3-001 unblocks; svc-compositor.M3-001 crash
   posture finalized.
4. **All R102 satellites land M3** in the partial order §6 pins.
5. **All R102 satellites land M4** — smokes run through the whole stack.
   `boot_r102_first_pixel` is the earliest gate; then window_present;
   then input_route; then pdxterm_hello; then screenshot.
6. **All R102 satellites tag `r102-closed` and sign 1.0.0** (M5).
7. **paideia-os monorepo tags `r102-closed`** after MON-010 (round
   closure retro).

### 9.2 First-pixel-on-screen smoke

**`boot_r102_first_pixel` is the earliest smoke and the load-bearing
milestone for "the graphical stack is real."** Its shape:

- **Actor:** svc-compositor solo, no clients.
- **Behavior:** On startup, obtain KIND_FB_SCANOUT (§7.2.1), fill the
  entire scanout with a solid blue via one `gfx_fill_rect` over the
  whole geometry, PRESENT once, exit cleanly.
- **Witness:** kernel-side witness at
  `src/kernel/boot/witness/r102_first_pixel.pdx` reads the LFB physical
  bytes back (kernel has authority regardless of cap state), asserts
  the pixel at (0,0), (w/2, h/2), (w-1, h-1) all equal the blue value.
- **Fingerprint:** `first pixel ok [legacy: FIRST PIXEL OK]`.

This is the smallest end-to-end smoke that exercises: cap-mint of the
scanout, libpdx-gfx surface open (against a stub or the real
KIND_SURFACE depending on M2 vs M3 posture), draw path, PRESENT op,
LFB write. If it passes, every subsequent smoke is an incremental
addition (one window, then input routing, then pty, then screenshot);
if it fails, exactly one thing is wrong and it is easy to isolate.

### 9.3 Reference-app-of-choice for early demo

`pdxclock` is the deliberate first-window-on-screen app: smallest
useful window, no input handling, one predictable pixel pattern per
second. `boot_r102_window_present` is its dedicated smoke and is the
next after `first_pixel`.

`pdxpaint` is the input-heavy demo (`boot_r102_input_route`).
`pdxterm` is the "the OS has a real graphical terminal now" demo
(`boot_r102_pdxterm_hello`) — the moment R102 becomes not just
"a graphical stack works" but "the graphical stack is a usable
substitute for the UART TTY."

### 9.4 Handoff to G7

When G7 begins (post-R37 Vulkan, post-R77 modeset), the R102 stack
either dies or gets demoted to the recovery-console path. The libraries
(`libpdx-font`, `libpdx-gfx`, `libpdx-event`) stay — their public API
was designed §0.4 to survive G7 unchanged. The services
(`svc-compositor`, `svc-wm`) are replaced by G7's Vello-and-PWP
compositor + a G7-shaped WM. The reference apps (`pdxterm`,
`pdxclock`, `pdxwatch`, `pdxpaint`) stay unchanged — they link libraries,
not services, and the libraries' internals swap under them.

The signature this plan commits to (§0.4, §8.3) is what makes that
handoff possible without a two-tree fork. R102's design job is not
"build a compositor that lasts forever" — it is "build a compositor
that is honest about its scope and forecloses one class of legacy
mistakes G7 does not have to inherit."

---

## 10. Ambiguities for main to resolve

1. **[POSTURE] Single-compositor vs pluggable-compositor (§0.5).** Plan
   picks single-compositor. Main sanity-check this — it forecloses
   compositor experimentation.
2. **[SEQUENCING] KIND_FB_SCANOUT at M2 vs M3 (§7.1.1).** Plan defaults
   to two smaller syscalls at M2 + full cap at M3. Main can prefer the
   alternative (only full cap at M3, no M2 split) if osarch signals it
   is simpler.
3. **[SCOPE] pdxwatch's sys-stat source (§2.8).** Does postui-top's
   metric endpoint exist as a shared service pdxwatch subscribes to, or
   does pdxwatch consume KIND_SYS_STAT directly and re-aggregate?
   Should not block filing but affects pdxwatch.M2 dep list.
4. **[NAMING] `svc-*` prefix (§2). R100 established `libpdx-*`
   convention. R102 introduces the first `svc-*` service repo prefix.
   Alternative name: `libpdx-compositor` / `libpdx-wm` (matching
   R90-XREPO.012's "libpdx-schema-registry vs svc-schema-registry"
   discussion). Plan defaults to `svc-*` because these are services
   (long-lived processes) not libraries (called into a client's
   address space); if main prefers `libpdx-*` for the org-wide
   consistency, rename before filing.
5. **[SCOPE] pdxpaint save format (§2.9). v1 saves raw BGRA (`.bgra`
   extension). A `.png` writer is a stretch item. Main can bump PNG
   into R102.M5 if it prefers, at the cost of a new
   `libpdx-imgcodec` dep (~100 LOC for a PNG encoder alone).
6. **[REPO COUNT] pdxpaint's presence at all.** Nine repos is a lot;
   pdxpaint could defer to a follow-on round (leaving 8 repos: font,
   gfx, event, compositor, wm, term, clock, watch). Plan keeps it
   because it is the only R102 app that exercises pointer routing, and
   boot_r102_input_route needs an actor. If pdxwatch's click-cycle
   exercise is judged sufficient, pdxpaint drops trivially.
7. **[NUMBERING] R102 sub-issue vs R90-XREPO.014.** The convention
   `R90-XREPO.<NNN>` reserves 014 as the next-free integer if this
   plan's issues want to piggyback on that numbering. R102 uses its
   own top-level round number (matching R100's precedent); this plan
   assumes R102 is the right level, but if main prefers keeping every
   softarch-orchestrated wave under R90-XREPO, rename `R102.M<M>-<seq>`
   to `R90-XREPO.014.M<M>-<seq>` before filing.
