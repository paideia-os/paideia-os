# R113 frame_capture_emit ring wrap — Wave VVV verification (COMP-IMPL-13)

Status: VERIFIED, no gap. Umbrella: R113 (#2380). Real issue: #2413
(`R113.M7-033 — Per-frame emission: frame_id + timestamp_ns +
surface_id + bbox`). No open GitHub issue titled with "M6" maps to
`frame_capture_emit.pdx` — the M6 milestone (#2407–#2411) is the
postui-desktop application track, unrelated to this file. The dispatch
prompt's "M6" / "#2419" citation does not resolve (#2419 is
`R113.M8-039`, currently OPEN); this doc verifies the actual
`frame_capture_emit.pdx` ring against its real landing, #2413.

## 1. What the dispatch assumed vs. what exists

The dispatch described a variable-length-record ring where a record
straddling the buffer end must wrap ("on head + rec_len > buf_end,
wrap head to buf_start"). `frame_capture_emit.pdx`'s ring is not that
shape — it is a **fixed-slot** ring:

```
FCE_RING_SLOTS     = 4
FCE_RECORD_BYTES   = 96   (fixed per record — FrameCaptureView@0.1)
FCE_RING_BYTES     = 384  (= 4 * 96, exact multiple)
```

Slot index is computed as `idx = _fcv_head & 3` (mask, not modulo-by-
division, and never needs a manual wrap branch), and the byte offset
is `idx * 96`, which ranges over exactly `{0, 96, 192, 288}`. Every
write spans `[offset, offset + 96)`, so the maximum reachable byte is
`288 + 96 = 384` — precisely `FCE_RING_BYTES`, the end of
`_frame_capture_records` (`[u64; 48]` = 384 bytes). There is no
record shape that can straddle the buffer end because every record is
the same fixed size and the buffer size is an exact multiple of it.

## 2. Trace — `src/kernel/core/graphics/frame_capture_emit.pdx`

- `frame_capture_emit` (§SECTION 5): `r14 = head & 3`, then
  `slot_offset = (r14 << 6) + (r14 << 5)` (`idx * 96` via shift-add,
  per the encoder's no-2-op-`imul` rule). Write base is
  `&_frame_capture_records + slot_offset`. All eight record fields
  (`+0` through `+44`) plus six reserved zero words (`+48` through
  `+88`) land inside `[slot_offset, slot_offset + 96)` — bounds-safe
  by construction for every one of the four possible `idx` values.
- `_fcv_head` advances by 1 unconditionally after each write (never
  masked itself — only the slot-index computation masks it), so the
  head counter itself is a plain 64-bit monotonic sequence number
  (wrap-in-64-bit-domain is a ~19-million-year non-issue per the file's
  own §RING LAYOUT note); the ring-slot wrap (the actual concern this
  task is checking) is the `& 3` mask, applied fresh on every call —
  there is no stored "current offset" that could be advanced past the
  buffer end and then need correcting.

## 3. Conclusion

No ring-wrap corruption is possible in this file: the fixed-slot,
power-of-two-count, mask-indexed design makes "wrap past buffer end"
structurally unreachable rather than something that needs a runtime
check. This is stronger than the wrap-and-correct pattern the dispatch
described (which is the right pattern for a variable-length-record
ring, e.g. a log/journal buffer) — no change made.
