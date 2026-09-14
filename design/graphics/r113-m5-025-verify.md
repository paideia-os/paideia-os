# R113.M5-025 seat 0 fingerprint drift — Wave VVV verification (COMP-IMPL-12)

Status: VERIFIED, no gap. Umbrella: R113 (#2380). Real issue: #2405
(`R113.M5-025 — Multi-seat model: per-seat surface tree + input group
binding`) — the dispatch's "was #2415" does not resolve to this item
(#2415 is `R113.M7-035 — Continuous capture`); #2405 is the correct
KIND_SEAT landing.

## 1. What "drift" would require

A drifting `SEAT CREATE OK id=<n> session=<n>` boot fingerprint would
need one of: (a) a non-deterministic seat-id allocation, (b) a
non-deterministic session-slot argument at the boot mint call site, or
(c) an uninitialized/stale read feeding either value.

## 2. Trace — `src/kernel/core/cap/kind_seat.pdx`

- `kind_seat_init` (§SECTION 8) zero-scrubs `_seats` (64 u64) and
  `_seat_stats` (8 u64) unconditionally on every boot-cascade run
  (defensive re-scrub, same discipline as `kind_session_init` /
  `kind_surface_init`), THEN calls
  `seat_create(session_slot=0, name_ptr=&default_seat_name)` with two
  **compile-time-constant** arguments (`xor edi,edi` equivalent /
  static `default_seat_name` label — no runtime input).
- `seat_create`'s free-slot scan (§SECTION 10) is a low-first linear
  scan over the just-zeroed 8-row pool (`in_use` byte at row+0 bit 56).
  On a freshly-scrubbed pool the first row (index 0) is always free,
  so `seat_id` is always `0` — deterministically, not by convention.
- The LAM generation bump (`old_gen + 1`) reads a zeroed header
  (`old_gen == 0` post-scrub), so it always computes `1`, but this
  value is **not part of the fingerprint** (only `id` and `session`
  are emitted) — irrelevant to drift even if it varied.
- `default_seat_name` is a static `[u8; 8]` string, not derived from
  any timestamp, RNG, or hardware-identity read.

`kernel_main.pdx` calls `kind_seat_init` exactly once in the boot
cascade (line ~2676), before any other seat-mutating call exists in
the tree (no live seat-manager landing yet). There is no code path
that calls `seat_create` a second time before the boot fingerprint
fires, and no code path that reorders the scrub after the mint.

## 3. Conclusion

`SEAT CREATE OK id=0 session=0` is fully deterministic under the
current tree: fixed inputs, a scrub that runs immediately before the
mint every time, and a low-first scan over a pool the scrub just
zeroed. No drift source exists. No stable-seed initializer is needed
beyond what already exists (the scrub itself IS the stable seed — it
guarantees row 0 is free at mint time). No code change made.

If a future multi-seat landing adds a second `seat_create` call ahead
of the default seat-0 mint (e.g., a hot-plug seat registered before
the default mint runs), THAT would introduce real drift risk and
should reserve seat_id 0 for the default seat explicitly rather than
relying on scan order. Flagged here as a forward note, not an
open gap in the current tree.
