# R39.M5 HW-Smoke — BT A2DP profile + audio-graph bridge

R39.M5-004 (#1342).  Hardware-smoke procedure for the Bluetooth A2DP
profile plus its bridge into the R33 audio graph.  Per design decision
D7 (`gated:hardware`), this smoke stays DORMANT in the CI-less local
smoke matrix until a real T14 Gen 4 machine with the Intel AX211 CNVi
controller and an A2DP-capable peer (BT headphones or a stereo
speaker) is available.  The placeholder at
`tests/kernel/drivers/bt/hw_smoke_a2dp_placeholder.pdx` returns `0`
unconditionally so `tools/run-smoke.sh` reports GREEN without
pretending a bring-up ran.

## Prerequisites

- Real T14 G4 with Intel AX211 CNVi (BT + WiFi shared silicon).
- R39.M2 HCI transport reachable (KIND_BT_HCI, KIND_L2CAP channel).
- Working KIND_BT_GATT_CONNECTION path (R39.M3).
- LE Secure Connections pairing complete against the peer (R39.M4);
  KIND_BT_PAIRING SEALED cap in hand.
- R33 audio graph in a bound-slot state: at least one live
  KIND_PCM_STREAM row (44 100 Hz or 48 000 Hz, 2 channels).
- A2DP-capable peer that advertises at least one SBC-sink SEP
  (mandatory per A2DP §4) and ideally one AAC-sink SEP.

## Procedure

1. Reset the A2DP + bridge + retx modules:
   `a2dp_init`, `a2db_init`, `a2rtx_init`.
2. Declare local SEPs mirroring the peer's capability set:
   `a2dp_sep_declare(A2DP_CODEC_SBC, A2DP_MEDIA_AUDIO,
   A2DP_SBC_SR_44100 | A2DP_SBC_SR_48000,
   A2DP_SBC_CM_STEREO | A2DP_SBC_CM_JOINT_STEREO)` -> `sep_sbc`.
3. AVDTP DISCOVER against the peer; `a2dp_discover()` must return a
   bitmask that includes `sep_sbc`.
4. GET_CAPABILITIES on `sep_sbc`; verify codec == SBC.
5. SET_CONFIGURATION on `sep_sbc` with the peer-picked
   sample_rate + channel_mode inside the declared capability masks.
6. OPEN, then START.  Confirm SEP state advances to STREAMING.
7. Attach the bridge:
   `a2db_attach(sep_sbc, pcm_stream_slot, A2DB_DIR_OUTBOUND,
   A2DB_CODEC_SBC, agreed_rate_hz, 2)` -> `bridge_row`.
8. Install the retx bookkeeping:
   `a2rtx_install(sep_sbc)` -> `retx_row`.
9. Play a 30-second 1 kHz tone through the KIND_PCM_STREAM.  For each
   encoded frame, call `a2db_encode_frame(bridge_row, 128)` (SBC
   baseline) or `1024` (AAC).  Every 128 samples emitted, call
   `a2rtx_check_drift(retx_row, a2db_row_epoch(bridge_row))`.  Assert
   the returned drift-check result is 0 for at least 95 percent of
   invocations (a live BT link should not resync more than a handful of
   times in 30 seconds).
10. Measure end-to-end latency (audio-graph produce -> audible
    playback) with an external microphone loop-back.  Assert < 200 ms.
11. Tear down: `a2dp_close(sep_sbc)`, `a2db_detach(bridge_row)`,
    `a2rtx_release(retx_row)`.

## Success criteria

- Fingerprint emitted: `R39 A2DP HW OK`
- Measured latency in the 30 s window: < 200 ms end-to-end.
- `a2rtx_stat(A2RTX_ST_RESYNCS)` records at most one resync per
  10 seconds of streaming (the drift-threshold budget above).
- `a2dp_stat(A2DP_ST_REFUSED)` is 0.

Until real hardware is present, the placeholder witness in
`tests/kernel/drivers/bt/hw_smoke_a2dp_placeholder.pdx` returns 0 and
the fingerprint above never appears in the shell-shutdown golden.
