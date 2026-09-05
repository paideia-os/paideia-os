# tools/hw-smoke-g12.md — G12 first-app toolkit bring-up recipe

**Round:** G12
**Milestone:** `g12-toolkit`
**Issue:** #2339 — T14 hw-smoke-g12.md: first-app smoke (settings + clock + editor)
**Size:** S
**Depends on:** G12-M3-001 (#2334, settings color panel)
**Status:** SPECIFICATION — every fingerprint below is data-only today
(see §Notes), the same posture `tools/hw-smoke-g11.md` shipped in
before its own wire-body milestone landed.

Operator recipe for the G12 first-app hardware-only test, per D7
`gated:hardware` discipline (`design/roadmap/next-wave-synthesis.md`
§D7). Runs on a real ThinkPad T14 Gen4 with the G7 compositor's
first-window substrate and the G12.M1/M2 `libpaideia-ui` toolkit
(`KIND_UI_CONTEXT=0x1D5`) landed. Not run in CI or QEMU — there is no
QEMU witness for these five samples yet, dormant or otherwise (contrast
G5/G7/G8/G11, each of which carries a synth witness that compiles and
links before wiring; see §Notes).

Terminal doc for #2339 (design authority: `design/roadmap/
next-wave-softarch.md` §"G12 — Developer APIs + first-party toolkit";
`design/roadmap/next-wave-synthesis.md` line 99). It does **not** close
the full 14-issue `g12-toolkit` milestone — the G12.M2 Vello draw wire
remains open. It covers the three first-party sample applications
landed in Wave0 Batch 13/14: settings (input #2333 + color #2334),
clock (analog #2335 + timezone #2336), and text editor (buffer
primitives #2337 — syntax highlighting + BiDi caret navigation is
#2338, filed but not landed).

## 1. Purpose

Prove end-to-end first-app bring-up on real T14 Gen4 hardware once the
sample-app dispatcher and `KIND_UI_CONTEXT` mint path are wired:

- The `libpaideia-ui` immediate-mode context (`KIND_UI_CONTEXT=0x1D5`,
  G12.M1-001 / #2326) as the shared substrate: mint, `begin_frame`/
  `end_frame`, and the widget-row hover/click read path
  (`widget_slider` / `widget_checkbox`, G12.M1-002 / #2327).
- Two settings panels sharing one load/render/save composition shape:
  the 7-row input+IME panel (#2333) and the 9-row color+HDR panel
  (#2334).
- Both toolkit paradigms side by side: the analog clock (#2335) drives
  the **immediate**-mode path against `widget_paint_rect`; the
  world-clock timezone list (#2336) drives the **retained**-mode path
  (`view_tree.pdx` #2329, `retained_widgets.pdx` #2330).
- The text editor's buffer substrate (`KIND_EDITOR_BUFFER=0x1E5`,
  #2337), a real gap-list edit engine, plus the forward look at syntax
  highlighting + BiDi caret navigation (#2338, open) built on
  `bidi_caret.pdx`'s caller-owned cell (#2324, already landed).

The G7 first-window substrate is a pre-condition, not part of the test
matrix. Unlike `hw-smoke-g11.md`'s IME stack, none of these five
samples has any call path from a boot witness or launcher today — every
fingerprint below is declared but never emitted on real hardware.
Treat this document as the spec the G12 wire-body milestone must
satisfy, and re-run it for real once that milestone lands.

## 2. Test matrix

| ID | Test | Sample app(s) | KIND cap | Fingerprint marker |
|----|------|----------------|----------|---------------------|
| T1 | settings-input-panel-boot | `samples/settings/input.pdx` (#2333) | `KIND_UI_CONTEXT`=0x1D5 | `settings input ready ok [legacy: SETTINGS INPUT READY OK]` |
| T2 | settings-color-panel-boot | `samples/settings/color.pdx` (#2334) | `KIND_UI_CONTEXT`=0x1D5 | `settings color ready ok [legacy: SETTINGS COLOR READY OK]` |
| T3 | clock-analog-frame-rate | `samples/clock/analog.pdx` (#2335) | `KIND_UI_CONTEXT`=0x1D5 | `clock analog ready ok [legacy: CLOCK ANALOG READY OK]` |
| T4 | clock-timezone-multizone | `samples/clock/timezone.pdx` (#2336) | `KIND_UI_CONTEXT`=0x1D5 | `clock timezone ready ok [legacy: CLOCK TIMEZONE READY OK]` |
| T5 | editor-buffer-insert-cycle | `samples/editor/buffer.pdx` (#2337) + `text_editor/render.pdx` (#2338, pending) | `KIND_EDITOR_BUFFER`=0x1E5 (+ BidiCaret cell, no KIND cap) | `editor buffer init ok [legacy: EDITOR BUFFER INIT OK]` |

T1–T4 derive from `KIND_UI_CONTEXT`'s own base (`KIND_WINDOW`=0x1C1);
`KIND_EDITOR_BUFFER` derives from `KIND_MEMORY` (slot 4) — a text
buffer is memory-shaped, not window-shaped. The BiDi caret is
deliberately **not** a capability: `bidi_caret.pdx` documents it as a
caller-owned 32-byte cell, allocated by whichever substrate owns focus
(a future `KIND_IME_ROUTER` session, or the editor's own per-field
state) — there is no `KIND_BIDI_CARET` in the tree, and citing one
would misstate the design.

## 3. T1: settings-input-panel-boot

**Preconditions**
- G7 first-window bring-up passed; the sample owns one `KIND_WINDOW`
  and a `KIND_UI_CONTEXT` row minted via `ui_context_new`.
- `KIND_UI_CONTEXT`'s mint dispatcher is wired into `cap_table` /
  `cap_invoke_dispatch` — **not true today**; the fingerprint is
  data-only (§Notes).
- A pointer-routing writer sets `immediate_context.pdx`'s row `hover_
  widget_id` / `click_widget_id` words between frames. The file
  documents these as set by `KIND_INPUT_ROUTE` pointer routing, but no
  writer is exported today — only the readers (`ui_context_is_hovered`
  / `ui_context_was_clicked`) exist. A second, distinct gap from the
  mint-dispatcher one above.

**Run steps**
1. `input_settings_load` seeds the 16-byte `InputSettings` struct
   (IME provider 0, keyboard layout 0, accel 100/100, natural scroll
   off, tap-to-click on, palm-reject on, stylus curve linear).
2. Loop `begin_frame(ctx)` → `input_settings_render(&s, ctx)` →
   `end_frame(ctx)` once per vblank.
3. Drive pointer hover/click across the panel's seven rows
   (`INPUT_PANEL_X`=10, `INPUT_ROW_Y0`=20, `INPUT_ROW_STEP`=28): Row 0
   keyboard-layout slider, Row 1 IME-provider slider, Row 2
   pointer-accel-num slider, Row 3 natural-scroll checkbox, Row 4
   tap-to-click checkbox, Row 5 palm-reject checkbox, Row 6
   stylus-curve slider. (`tools/verify-fingerprint-coverage.sh`'s
   allowlist comment for this fingerprint uses looser shorthand —
   "keyboard repeat + repeat delay + ... + trackpad gesture" — written
   before the final field layout landed; the seven rows above are what
   `input_settings_render` actually paints.)
4. Toggle each checkbox once; drag each slider across its range.
5. Confirm the aggregate `WidgetResult` reaches `INPUT_WR_CHANGED` (4)
   at least once (CHANGED outranks HOVERED/CLICKED/ACTIVE).

**Expected observables**
- `settings input ready ok` fingerprint once, at first successful
  load+render pass.
- `_input_stats[INPUT_ST_RENDERS]` increments once per frame;
  `INPUT_ST_CHANGED` bumps on any `WR_CHANGED` row; `INPUT_ST_REFUSED`
  stays 0 across a clean run.

**Failure modes**
- Invalid `ctx_row_id` or NULL `settings_ptr` collapses every row to
  `WR_NONE` and bumps `INPUT_ST_REFUSED` **silently** —
  `INPUT_BAD_CTX` (0xFFFFE92E) / `INPUT_BAD_PTR` (0xFFFFE92F) are
  reserved for a future G12.M4 settings-service boundary and are never
  returned by the current entry points.
- No keyboard-focus or Tab-cycle path exists — `widgets.pdx` is
  pointer/hover-driven only. A rig expecting Tab to move row focus
  will see no state change; that is a known gap (compositor-side
  `keynav_taborder.pdx`, #2311, is itself data-only), not a regression.

**Artifact paths**
- `src/samples/settings/input.pdx`
- `src/user/libpaideia_ui/immediate_context.pdx`, `widgets.pdx`
- `tools/verify-fingerprint-coverage.sh` (~line 1127)

## 4. T2: settings-color-panel-boot

**Preconditions**
- Same `KIND_UI_CONTEXT` mint-dispatcher gap as T1.
- `KIND_REFERENCE_DISPLAY` / `KIND_HDR_METADATA` / `KIND_TONEMAP_LUT`
  are named in the design authority but not resolved against live caps
  here — `color_profile_kind_id` / `hdr_tonemap_mode` are raw struct
  fields, not capability lookups.

**Run steps**
1. `color_settings_load` seeds the 16-byte `ColorSettings` struct
   (profile 0, HDR peak/avg 1000/250 nits, tonemap 0 = BT.2408 Hable,
   night-light off at 4500 K / 21:00–06:00, blue-light filter 0).
2. Loop `begin_frame` → `color_settings_render(&s, ctx)` → `end_frame`.
3. Drive pointer hover/click across the nine rows (`COLOR_ROW_Y0`=20,
   `COLOR_ROW_STEP`=28): Row 0 color-profile slider, Row 1 HDR
   peak-nits (100–10000), Row 2 HDR avg-nits (100–1000), Row 3
   tonemap-mode (0–3), Row 4 night-light-enabled checkbox, Row 5
   night-light-temp (2700–6500 K), Rows 6/7 night-light start/end hour
   (0–23 each), Row 8 blue-light-filter (0–100).
4. **HDR mode toggle round-trips:** toggle Row 4 off→on→off across two
   render passes; confirm `COLOR_WR_CHANGED` each transition and
   `_color_stats[COLOR_ST_CHANGED]` increments by 2.
5. **Night-light schedule accepts a value:** drag Rows 6/7 to new
   in-range hours; confirm `COLOR_OFF_NIGHT_START` / `_END` bytes
   update.

**Expected observables**
- `settings color ready ok` fingerprint once.
- `COLOR_ST_RENDERS` / `COLOR_ST_CHANGED` as above; `COLOR_ST_REFUSED`
  stays 0.

**Failure modes**
- `color_settings_save` is a **stub** — it does not write
  `/system/prefs/color.pdxpref` (the file-backed store is a G12.M4
  concern); `COLOR_WRITE_FAIL` (0xFFFFE91B) is reserved, never
  returned.
- `COLOR_BAD_PROFILE` (0xFFFFE91A) / `COLOR_BAD_TONEMAP` (0xFFFFE919)
  are reserved for the future cap-resolve named above; neither check
  runs today, so a bogus profile ID renders and saves without
  complaint.

**Artifact paths**
- `src/samples/settings/color.pdx`
- `tools/verify-fingerprint-coverage.sh` (~line 1137)

## 5. T3: clock-analog-frame-rate

**Preconditions**
- `present_feedback_kind.pdx` (`KIND_PRESENT_FEEDBACK`=0x1DA, #2297)
  landed so `present_feedback_row_last_present(sub_id)` can return a
  live monotonic-ns vblank timestamp. This substrate is itself
  data-only per its own coverage-script entry — kernel dispatcher and
  `vk_present_feedback_channel` wire-body not yet wired — so on real
  hardware today there is no live `sub_id`; the tester must supply
  `nsec` from a manual stand-in loop (see `analog.pdx`'s own frame-loop
  comment).

**Run steps**
1. `analog_clock_new(surface_kind_id, center_x, center_y, radius_px)`
   allocates the 32-byte clock struct.
2. Advance `nsec` across a 10 s window in ≥16 discrete steps (one per
   intended paint), feeding each to `analog_clock_tick`.
3. Call `analog_clock_render_frame(&clock, ctx_row_id)` after every
   tick.
4. Read `_analog_stats[ANALOG_ST_PAINTS]` before/after the window;
   expect delta == 16 × render-frame calls issued (1 face + 12 hour
   ticks + 3 hands, per the file's own accounting).

**Expected observables**
- `clock analog ready ok` fingerprint once.
- `ANALOG_ST_RENDERS` increments once per render call reaching the
  paint loop; `ANALOG_ST_PAINTS` delta == 16× that.
- The second-hand angle (`analog_clock_compute_hand_angle`) advances
  monotonically, using `subsecond_ms` for a smooth sweep.

**IMPORTANT — no visual observable today.** `widget_paint_rect` only
bumps `widgets_stats[WIDGETS_ST_PAINTS]`; it never touches a
framebuffer. There is no real pixel output until the G12.M2 Vello
vector-face draw wire replaces each call site with a real primitive.
"16 paints/frame ... animates" is a **counter** observable read off
the serial/klog stats dump, not something visible on screen, until
G12.M2 lands. Do not fail T3 for lack of an on-screen hand.

**Failure modes**
- `radius_px == 0` or `surface_kind_id == 0` → `analog_clock_new`
  returns 0 (NULL) and bumps `ANALOG_ST_REFUSED`; no per-cause
  sentinel escapes the call (the file's 0xFFFFE920..0xFFFFE92F page is
  documented as internal-reasoning-only).
- "No dropped frames over 10 s" is unverifiable against real
  compositor timing until `present_feedback`'s dispatcher wires a live
  vblank source; a manually-stepped `nsec` loop can only catch a wrong
  tick cadence, not a real dropped frame.

**Artifact paths**
- `src/samples/clock/analog.pdx`
- `src/user/compositor/present_feedback_kind.pdx`
- `src/user/libpaideia_ui/widgets.pdx` (`widget_paint_rect`)
- `tools/verify-fingerprint-coverage.sh` (~line 1146)

## 6. T4: clock-timezone-multizone

**Preconditions**
- `view_tree.pdx` (#2329) and `retained_widgets.pdx` (#2330) landed
  (both closed). `KIND_UI_CONTEXT` mint-dispatcher gap from T1 still
  applies.

**Run steps**
1. `clock_timezone_app_init` zeroes the 7-word app struct and seeds
   `unix_seconds` / `ready_flag`.
2. `clock_timezone_main()` runs the one-time build: `view_tree_new` →
   `retained_list_new` + `retained_list_add_item` × 12 (one per zone)
   → `view_tree_diff` → `begin_frame`/`reconcile`/`end_frame`.
3. Advance `unix_seconds` via `clock_timezone_advance_tick` (+30 s per
   call) across several ticks; confirm each per-tick rebuild completes
   without `CTZ_REFUSED_DENSE`.
4. Read all 12 zones' derived HH:MM labels against the fixed table
   (Los Angeles −08:00 through Sydney +10:00, standard-time only, no
   DST) and confirm every UTC-offset label is correct.

**Expected observables**
- `clock timezone ready ok` fingerprint once.
- The one-time build returns `rows_built == 12`, not
  `CLOCKTZ_BUILD_FAIL_MARKER` (`0xFFFFFFFFFFFFFFFF`).

**Failure modes**
- `CTZ_NOT_INIT` (0xFFFFE89F) `ready_flag==0`; `CTZ_NULL` (0xFFFFE89E)
  `app_ptr==0`; `CTZ_UI_CTX_MINT_FAIL` (0xFFFFE89D) mint refused;
  `CTZ_ROW_LAYOUT_FAIL` (0xFFFFE89B) one-time row-hash packing failed;
  `CTZ_ZONE_OUT_OF_RANGE` (0xFFFFE89A) `zone_index>=12`;
  `CTZ_REFUSED_DENSE` (0xFFFFE899) a later per-tick rebuild refused.
- `CTZ_TIME_UNAVAILABLE` (0xFFFFE89C) is reserved for a future
  `KIND_WALL_CLOCK` subscription that does not exist yet:
  `unix_seconds` is a synthetic +30 s/tick counter, **not** real
  wall-clock time, in this landing.

**"Scroll list responds to input" is not exercisable today.** The
file's own header states `VNK_LIST` rows are built and reconciled but
no scroll-viewport primitive exists yet; all 12 zones render as one
flat, unscrolled list. Treat scroll response as future work, not a T4
pass/fail gate, until that primitive lands.

**Artifact paths**
- `src/samples/clock/timezone.pdx`
- `src/user/libpaideia_ui/view_tree.pdx`, `retained_widgets.pdx`
- `tools/verify-fingerprint-coverage.sh` (~line 1316)

## 7. T5: editor-buffer-insert-cycle

**Preconditions**
- `samples/editor/buffer.pdx` (#2337, closed) landed — a real gap-list
  edit engine, not a stub. `text_editor/render.pdx` (#2338, syntax
  highlighting + BiDi caret navigation) is **filed but not landed**;
  steps 6–8 below are forward-looking spec, not runnable today.
- `bidi_caret.pdx` (#2324, closed) supplies `bidi_caret_move_left` /
  `_move_right` / `_extend_selection` over a caller-owned 32-byte cell
  — no `KIND_BIDI_CARET` capability exists (§2).

**Run steps — buffer half (landed, runnable today)**
1. `ebuf_init()` — idempotent `.bss` scrub of the 32-node shared pool.
2. `buffer_id = editor_buffer_mint()` against `KIND_EDITOR_BUFFER=0x1E5`
   (derived over `KIND_MEMORY`, slot 4).
3. `editor_buffer_insert_at(buffer_id, 0, "hello", 5)` — pre-flight
   atomic: worst-case new-node count is checked against
   `ebuf_count_free_nodes` before any byte is written.
4. `editor_buffer_read_range(buffer_id, 0, 5, dst_ptr)` — confirm the
   5 bytes read back as `"hello"`.
5. `editor_buffer_delete_range(buffer_id, 4, 1)` (backspace the
   trailing `o`) — confirm `editor_buffer_len_bytes == 4` and a re-read
   returns `"hell"`.

**Run steps — render half (pending #2338, spec only)**
6. Once `render.pdx` lands: tokenize the buffer through the syntax
   highlighter and confirm each emitted token carries a
   `TOKEN_ID`-shaped tag. No `TOKEN_ID` constant exists in the tree
   today — #2338 is the landing that defines it.
7. Drive a `BidiCaret` cell (`bidi_caret_init` over the buffer's
   paragraph) through `move_left` / `move_right` across the 4-byte
   `"hell"` buffer; confirm `logical_offset` / `visual_x` stay
   mirrored (LTR-stub: visual == logical until `bidi_uba.pdx`
   integration lands) and the anchor fields update per
   `extend_selection` semantics.
8. **Home/End caret jumps are not yet implemented anywhere.**
   `bidi_caret.pdx` exports only `move_left` / `move_right` /
   `extend_selection` today; a paragraph-boundary jump primitive is
   unfiled follow-on work for #2338 or a sibling G11.M5 row. Do not
   gate T5 on Home/End until that primitive exists.

**Expected observables**
- `editor buffer init ok` fingerprint once, on the buffer half.
- `EBUF_ST_INSERTS` / `EBUF_ST_DELETES` increment once per call;
  `editor_buffer_len_bytes` reflects each edit exactly (5, then 4).

**Failure modes** (buffer half — live, returned sentinels, unlike the
settings panels' reserved-but-unused bands):
- `EBUF_NULL` (0xFFFFE8BF) `src_ptr`/`dst_ptr`==0; `EBUF_NOT_INIT`
  (0xFFFFE8BE) called before `ebuf_init`; `EBUF_RANGE_INVALID`
  (0xFFFFE8BD) `buffer_id` names no live head; `EBUF_OOB` (0xFFFFE8BC)
  offset(+len) outside `[0,total_len]`; `EBUF_NODE_POOL_EXHAUSTED`
  (0xFFFFE8BB) mid-loop allocation failed despite a sound pre-flight
  (should be unreachable); `EBUF_REFUSED_DENSE` (0xFFFFE8B9) pre-flight
  capacity check refused atomically before any byte was written — the
  ordinary refusal path under pool pressure.

**Artifact paths**
- `src/samples/editor/buffer.pdx`
- `src/user/ime/bidi_caret.pdx`, `bidi_uba.pdx`
- `tools/verify-fingerprint-coverage.sh` (~line 1325)

---

## Notes

**All five fingerprints are data-only today.** Per `tools/
verify-fingerprint-coverage.sh`'s own allowlist comments, no boot
witness and no sample-app dispatcher calls `input_settings_load`,
`color_settings_load`, `analog_clock_new`, `clock_timezone_app_init`,
or `ebuf_init` yet — each fingerprint above is declared but never
reaches a serial log on real hardware. This mirrors `hw-smoke-g11.md`'s
posture before its own wire-body milestone: this recipe is a
specification, not an executable procedure, until a future G12
wire-body milestone (post `g12-toolkit`, not yet filed) lands:

- A sample-app launcher running one of these five files as the focused
  client of a minted `KIND_UI_CONTEXT` row, driving each `*_load` →
  per-frame `*_render` → `*_save` triple to completion.
- The `KIND_UI_CONTEXT` mint dispatcher in `cap_table` /
  `cap_invoke_dispatch` (T1–T4's shared precondition).
- A pointer-routing writer for `immediate_context.pdx`'s `hover_
  widget_id` / `click_widget_id` — today only the readers exist.
- The G12.M2 Vello draw wire, so `widget_paint_rect` (T1–T4's shared
  paint primitive) emits real pixels instead of bumping a counter.
- A `PAIDEIA_G12_SMOKE` mode-matrix entry in `tools/run-smoke.sh` —
  none exists today, QEMU or real-hardware side.
- #2338's `render.pdx` — syntax highlighting, `TOKEN_ID`, and Home/End
  caret navigation, none of which exist in the tree yet.

Until that milestone lands, treat every "expected observable" above as
the target state and every fingerprint as unverified — recording an
expected value nobody measured on real hardware is exactly the failure
this file exists to avoid (same discipline as `tools/hw-smoke-r30.md`,
`tools/hw-smoke-r51-nvme-t14g4.md`, and every other `UNSEEDED` recipe
in this directory).

Cross-reference `tools/hw-smoke-g7.md` for the compositor/first-window
substrate `KIND_UI_CONTEXT` derives from, `tools/hw-smoke-g11.md` for
the BiDi UBA + caret substrate T5 depends on, and `design/roadmap/
next-wave-softarch.md` §"G12 — Developer APIs + first-party toolkit"
for the toolkit's design authority.
