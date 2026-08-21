# R44 HW-Smoke — Semantic Terminal (GUI frontend, HDR-aware)

R44.M4-003 (#1411). Hardware-smoke procedure for the R44 semantic
terminal GUI frontend on real T14 Gen 4 hardware. Per design
decision D7 (`gated:hardware`), this smoke stays DORMANT in the
CI-less local smoke matrix until a real T14 G4 machine boots the
Vello rasterizer + KIND_DISPLAY_OUTPUT + KIND_PRESENT_FEEDBACK path
AND executes at least one live query against the R41.M2 engine
while presenting into an HDR-capable output. The placeholder at
`tests/kernel/semterm/hw_smoke_r44_placeholder.pdx` returns `0`
unconditionally so `tools/run-smoke.sh` reports GREEN without
pretending a bring-up ran.

## Prerequisites

- Real T14 G4 booted via UEFI on real firmware (not QEMU-OVMF).
- R23 fb-console live (baseline of R41 HW-smoke; see
  `tools/hw-smoke-r41-fb-terminal.md`).
- R36 display supervisor bound: a live `KIND_DISPLAY_OUTPUT` row
  surfaced by `src/kernel/core/drivers/dpy/` topology + EDID reader,
  with the HDR-capability bit surfaced to the GUI stack through
  `gui_hdr.pdx`'s `hdr_set_capable`.
- External HDR-10 or HDR-400 rated display connected via the
  Thunderbolt DP-DDI path (R35) or the built-in eDP if the panel
  advertises HDR.
- R37 GPU backend live: Iris Xe / Vello rasterizer producing real
  scanlines into the compositor's swapchain, with the GuC firmware
  loaded per `tools/hw-smoke-r37-guc.md`.
- G9 presentation-time-feedback subscription live: the compositor's
  KIND_PRESENT_FEEDBACK stream flows into `gui_feedback.pdx`'s
  `pfb_report` seam and the adaptive flags are read by
  `gui_charts.pdx` / `gui_scroll.pdx` at render time.
- R44.M1 GUI shell attached (`gsh_reset` + region layout populated).
- R44.M2 Vello / chart / scroll seams initialised (`vel_reset`,
  `cha_reset`, `scr_reset`).
- R44.M3 IME / a11y / kbdnav seams initialised (`ime_reset`,
  `a11_reset`, `knv_reset`).
- R44.M4 HDR / feedback seams initialised (`hdr_reset`, `pfb_reset`,
  `pfb_set_budget(target_frame_ns)`).
- R41.M2 engine bound (see R41 HW-smoke); session log attached.

## Procedure

1. Reset the R44 stack (from a boot-time init):
   `gsh_reset()`, `gly_reset()`, `gth_reset()`,
   `vel_reset()`, `cha_reset()`, `scr_reset()`,
   `ime_reset()`, `a11_reset()`, `knv_reset()`,
   `hdr_reset()`, `pfb_reset()`.
2. Probe the connected display through the R36 supervisor:
   - `is_hdr := display_query_hdr(kind_display_output_row)`;
   - `hdr_set_capable(is_hdr)`.
   Expected: `is_hdr == 1` for a genuine HDR display; `hdr_capable()`
   reads back `1`.
3. Bind the G9 subscription: `pfb_set_budget(16000000)` for a 60 Hz
   target (16 ms in nanoseconds), then subscribe the
   KIND_PRESENT_FEEDBACK channel so each rendered frame drives
   `pfb_report(rendered_at, presented_at)`.
4. Boot the semantic terminal GUI window (per the R44.M1 shell
   attach seam). Populate the four regions:
   query editor (top), results table (middle), tab bar (below
   editor), status bar (bottom).
5. At the query editor, type:
   `SELECT * FROM tasks LIMIT 10\n`
6. The engine parses, types, and executes the query against the
   sources bound in the R41 HW-smoke. The results table renders
   through the Vello backend; the plot compositor renders a chart
   region (`A11Y_KIND_CHART_REGION`) with per-series colors picked
   through `hdr_pick_series` -- expect the SIX-primary-plus-two BT.2020
   palette on the HDR display (visibly more saturated than the sRGB
   fallback).
7. Watch the status bar: it must display `hdr=1`, `budget=16ms`,
   `over_budget=0/N`, `detail=full`. Drag the window rapidly across
   the screen to force scroll animation; if any frame lands past the
   16 ms budget, `pfb_over_budget_count()` bumps and the status bar
   reads `detail=reduced` / `scroll=frozen` for that frame. A quiet
   frame after that restores `detail=full`.
8. Press `Tab`; focus advances through the query editor's widgets
   (`knv_next_widget` bumps `widget_bumps`). Press `F6`; focus
   rotates to the results region (`knv_next_panel` bumps
   `panel_bumps`).
9. Trigger IME composition (any CJK input method on a T14 G4 with a
   USB keyboard configured for it): a `hanja` or `pinyin`
   composition routes through `ime_preedit_push` and commits via
   `ime_commit`; `ime_notify_pending()` reads 1 until the editor
   pump drains it with `ime_notify_ack`.
10. Confirm the a11y bridge sees the widget tree: a screen reader
    (running out-of-band on an accessibility inspector) reports the
    four regions with the roles installed by
    `a11_root_add` / `a11_child_add`.
11. Take a photograph of the display with an external camera (the
    sandbox blocks in-band captures on real hardware); attach it to
    the smoke run's evidence bundle. The chart region should show
    visibly more saturated primary colors than the sRGB baseline.
12. Detach: `slog_detach()`, unbind the G9 subscription,
    `hdr_reset()`, `pfb_reset()`.

## Success criteria

- Fingerprint emitted: `R44 SEMTERM GUI HW OK`
- Photo shows the results table + a plotted chart with
  BT.2020-primary colors distinctly more saturated than the sRGB
  reference (side-by-side capture with a second window forced to
  `hdr_set_capable(0)` before the shot).
- `pfb_reports_total()` records at least one report per frame across
  the drag test (matches display-refresh count).
- `hdr_hdr_picks() >= 8` after rendering the chart (one pick per
  series 0..7).
- `hdr_sdr_picks() == 0` on the HDR run; a repeat run after
  `hdr_set_capable(0)` records `hdr_sdr_picks() >= 8` and
  `hdr_hdr_picks() == 0`.
- No panic, no `klog` error line at level >= WARN during the run.

Until real hardware is present, the placeholder witness in
`tests/kernel/semterm/hw_smoke_r44_placeholder.pdx` returns 0 and
the fingerprint above never appears in the shell-shutdown golden.
