# R113.M4-021 vblank vs. frame_capture_emit ordering — Wave VVV verification (COMP-IMPL-14)

Status: VERIFIED, no gap. Umbrella: R113 (#2380). Real issue: #2401
(`R113.M4-021 — VBlank sync: KIND_DISPLAY vblank event triggers
commit`). The dispatch's "was #2450" does not resolve to this item
(#2450 is an unrelated `touch` in-tree tool issue); #2401 is the
correct vblank-handler landing.

## 1. What "inverted ordering" would look like

A bug would be: `frame_capture_emit` (or its consent wrapper) reading
"the last completed frame" before the compositor has actually
produced that frame's pixels for the current tick — i.e., capturing
stale or half-composited state.

## 2. Trace — call order inside `vblank_handler`

`src/kernel/core/graphics/vblank.pdx` §SCOPE / body, per file header
and code:

1. Bump `_vblank_counter`.
2. Fire the compositor pass: `scanout_try_direct()`, and on fallback
   `composite_gpu_blend()` — this is where the frame's pixels (or the
   direct-scan binding) actually get produced/latched.
3. Walk `_z_stack` and call `surface_present_notify(cur_slot,
   row_serial)` per rendered surface.
4. Emit `VBLANK TICK counter=<n>` (klog).

`surface_present_notify` (`src/kernel/core/graphics/surface_present.pdx`
lines 258–296) itself, in order: (a) emits `SURFACE PRESENT OK`, THEN
(b) calls `frame_capture_maybe_emit_for_surface(surface_slot, serial)`
— the frame-capture hook — as its last action before returning.

So the full sequence within one `vblank_handler` invocation is:

```
bump counter -> composite/scanout (produce frame) -> per-surface
present-notify -> frame_capture_maybe_emit_for_surface (consume/
record frame) -> VBLANK TICK fingerprint
```

Frame capture is called strictly AFTER the compositor pass that
produces the frame, and is driven off `row_serial` (the surface's own
monotonic commit counter, already advanced by the time vblank fires),
not off any pre-composite state. There is no separate, differently-
ordered call site for `frame_capture_emit` / `frame_capture_maybe_
emit_for_surface` anywhere else in the tree (`frame_capture_emit.pdx`
§EXTERNAL SYMBOLS / the sole call site grepped in
`surface_present.pdx:296`).

## 3. Conclusion

Ordering is correct as landed: vblank triggers compositing first, then
frame capture reads the result of that same tick's compositing pass.
No swap needed. No code change made.
