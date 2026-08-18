# pcm-ring-channel-schema — R33.M3-004 (#1150)

## §0 Purpose

The wire face of a KIND_PCM_STREAM: a session-typed contract between a
PCM producer and a PCM consumer, both holding one KIND_PCM_STREAM
capability and one KIND_AUDIO_CLOCK capability that the session carries
so the consumer can compute presentation time.

The schema lives as code (`src/kernel/core/ipc/pcm_ring_channel.pdx`)
because the packer is the load-bearing artefact — a producer that packs
`fill_next_period` with `period_frames` in the wrong bit range and a
consumer that unpacks from a different range disagree on how much of
the ring the producer just claimed, and the disagreement manifests as
audible glitching rather than a refusal.

## §1 Session type

```
pcm_ring : Channel {
  ! { audio_clock_read }
  { fill_next_period(buf_id, period_frames),
    drain_current_period,
    xrun_notify(period),
    seek(sample_index) }*
}
```

- `!{audio_clock_read}` names the ONE capability the session carries.
  A session that carried two clocks would give the consumer two
  presentation-time answers for one sample with no principled tiebreak.
- The four RPCs cycle indefinitely on a live stream; xrun is
  asynchronous (server-emitted) and does not interleave into the
  producer's fill/drain order.

## §2 Request / reply layout

Each request and reply is one `u64`. Multi-word frames would require
ordering guarantees this schema does not undertake to provide.

| Op            | Value  | Payload layout                                     |
|---------------|--------|----------------------------------------------------|
| FILL_NEXT     | 0x10   | buf_id[23:8], period_frames[47:24], reserved[63:48]|
| DRAIN_CURRENT | 0x11   | reserved[63:8]                                     |
| XRUN_NOTIFY   | 0x12   | period[47:8], reserved[63:48]                      |
| SEEK          | 0x13   | sample_index[63:8]                                 |
| FILL_ACK      | 0xE0   | status[63:8]                                       |
| DRAIN_ACK     | 0xE1   | period_id[47:8], frames[63:48]                     |
| XRUN_ACK      | 0xE2   | status[63:8]                                       |
| SEEK_ACK      | 0xE3   | status[63:8]                                       |

Request ops occupy `0x10..0x13`; replies occupy `0xE0..0xE3`. A
dispatcher switching on the op byte cannot route a reply as a request.

## §3 Bounds — refuse, never clamp

- `buf_id` in `[1, 65535]`
- `period_frames` in `[1, 2^24)`  (16 M frames is > 5 minutes at 48 kHz)
- `period` (xrun) in `[1, 2^40)`
- `sample_index` in `[0, 2^56)`

## §4 The forbidden case §3 of `kind_pcm_stream.pdx` states

A KIND_PCM_STREAM row's `ring_bo_key` field MUST NOT appear on two
live rows whose `audio_clock_slot` values name different
KIND_AUDIO_CLOCK capabilities. The mint refuses with
`PCM_STREAM_MINT_XCLOCK_CONFLICT` (#1151). This schema does not
represent that invariant on the wire — the CAP mint refuses the
attempt to establish two conflicting sessions long before either
sends a frame.

## §5 Session establishment carries the KIND_AUDIO_CLOCK cap

The frame that MINTS the KIND_PCM_STREAM on the consumer side is
NOT this schema's business — it is a `cap_dispatch` invocation on
the parent endpoint that resolves the audio clock slot as part of
the mint arguments. This schema documents ONLY the steady-state
per-period RPCs; the session establishment lives in
`design/ipc/typed-handoff.md` and one row of `_pcm_stream_table`.

## §6 What this schema does NOT do

- NO endpoint. NO transport. NO byte crosses a process boundary in
  this tree; when a userspace audio server lands, the packers here
  become its wire face.
- NO period allocation — that is the ring buffer object's job (an
  R33.M5 milestone; `bdl.pdx` §4 records the deferrals).
- NO consumer scheduling — the server decides when to drain.

## §7 Error codes

Range `0xFFFFFCB0..0xFFFFFCBF`, disjoint from every other in-tree band.

## §8 References

- `src/kernel/core/ipc/pcm_ring_channel.pdx`
- `src/kernel/core/cap/kind_pcm_stream.pdx` §3 (cross-cap invariant)
- `src/kernel/core/cap/kind_audio_clock.pdx` §0-§4
- `src/kernel/core/drivers/hda/bdl.pdx` §0
- `design/ipc/codec-query-channel-schema.md` (sibling)
