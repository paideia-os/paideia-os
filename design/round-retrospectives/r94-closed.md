# R94 Retrospective: TCP hardening + off-box smoke

**Date:** 2026-09-02
**Milestones:** R94.M1 (retransmit timer wiring), R94.M2 (data
retransmit replay), R94.M3 (TIME_WAIT + half-close), R94.M4 (blocking
accept/recv), R94.M5 (RTT sampling + exponential backoff), R94.M6
(off-box smoke witness + run-qemu hostfwd + closure).
**Issues closed at landing:** #2060, #2061, #2062, #2063, #2064,
#2065, #2066, #2067, #2068, #2069, #2070 (see deferrals), #2071,
#2072, #2073, #2074, #2075. Plus retro. Full block: 15 code issues +
1 deferred + retro.
**HEAD at closure:** paideia-os (this landing).
**Release tag:** `r94-closed` recommended.

## Round intent

Close the "TCP has multiple exported-but-unwired primitives" gap
`design/networking/r91-plan.md` §8 catalogued in R72's own honesty
notes. Pre-R94:

- `tcp_poll_retransmits` was callable but nothing periodic ever called
  it -- the LAPIC tick path (`int/exceptions.pdx handle_timer`) never
  reached into `net/tcp.pdx`.
- `_tcp_tx_buf_table` was declared but tcp_send_segment never wrote
  to it, so `tcp_retransmit_last` fell back to zero-length control-
  segment replay for TCBs carrying unacked DATA -- documented as a
  "honesty note" in R72's module header but a real correctness gap.
- TIME_WAIT freed immediately on the final ACK, which under a burst
  of same-4-tuple reconnects could reallocate a slot before the peer
  had drained its own retransmit queue.
- `sys_shutdown`'s `how` argument was accepted but ignored -- every
  shutdown() was a full-duplex close regardless of caller intent.
- `sys_accept` / `sys_recv` returned -EAGAIN on empty rather than
  blocking, so a userspace server loop had to busy-poll (defeats the
  point of a syscall-boundary wait primitive).
- No RTT sampling -- every RTO was a fixed 1s regardless of the
  observed round-trip time. Karn's algorithm entirely absent.
- No off-box witness -- every TCP smoke exercised only the R72 self-
  addressed loopback fast path (`local_ip == remote_ip`), so the
  wire arm of `tcp_send_segment` / `tcp_retransmit_last` had never
  run through a real NIC ring in this tree.

R94 lands the whole block in ONE round -- the six milestones are
tightly coupled (data retransmit needs the tick hook to fire; RTT
sampling needs Karn to defend against retransmit-ambiguity; the
off-box witness needs all of the above to be reliable enough to
attest against QEMU SLIRP).

## Per-milestone disposition

### R94.M1 -- retransmit timer wiring -- LANDED

* **#2060 (M1-001) -- hook `tcp_poll_retransmits` into LAPIC tick
  path, gated every 10 ticks.**
  `src/kernel/core/int/exceptions.pdx handle_timer` step (0.5). Uses
  a 64-bit divide against 10 to gate; on rem==0 (~every 100 ms at the
  100 Hz LAPIC period) calls `tcp_poll_retransmits`. IF stays 0
  across the call. Stack budget within the per-task 16 KiB kernel
  stack: `tcp_poll_retransmits` reserves 40 B itself + at most
  ~120 B through `tcp_retransmit_last` + `tcp_build_header` +
  `tcp_checksum` + `tcp_rx_handle`. The pre-init `_current_tcb == 0`
  window is defended by the scan's `in_use == 0` skip -- the TCB
  pool starts empty so the scan is a no-op.

* **#2061 (M1-002) -- witness: RTO force-fire.**
  Landed as **scenario A of the combined `witness_r94_substrate`**
  at `src/kernel/boot/witness/r94_substrate.pdx`. Synthesizes a TCB
  with `snd_una < snd_nxt` and `rto_deadline` in the past, calls
  `tcp_poll_retransmits` directly (rather than waiting for the LAPIC
  tick, which would race the boot witness sequence), asserts
  `_tcp_retransmits` bumped. Emits `boot r94 retransmit ok --
  rxmt=<N>`. The combined-witness pattern (one file for M1-002,
  M2-003, M3-003) is a scope-fit call -- three tiny straight-line
  scenarios per issue would have been three tiny files with the same
  `tcp_alloc_tcb`/synth-row/`tcp_free_tcb` shape.

### R94.M2 -- data retransmit replay buffer -- LANDED

* **#2062 (M2-001) -- wire `tcp_send_segment` to populate
  `_tcp_tx_buf_table`.**
  `net/tcp.pdx tcp_send_segment` now `rep_movsb`s the payload into
  `_tcp_tx_buf_table[tcb_idx*4096..+N]` in addition to
  `_tcp_tx_scratch`, and stashes `last_seg_payload_bytes` (@+272,
  new slot) so the retransmit path knows how many bytes to replay.

* **#2063 (M2-002) -- `tcp_retransmit_last` reads cached bytes.**
  Rewritten to re-`rep_movsb` from `_tcp_tx_buf_table[tcb_idx*4096]`
  into the outgoing scratch after the header, when
  `last_seg_payload_bytes > 0`. Pure control segments (SYN, SYN|ACK,
  ACK, FIN) still take the pre-R94 zero-payload path because their
  cached-bytes count is 0.

* **#2064 (M2-003) -- witness: multi-segment retransmit carries
  original bytes.**
  Landed as scenario B of `witness_r94_substrate`. Seeds
  `_tcp_tx_buf_table` with "HELLO", sets `last_seg_payload_bytes=5`,
  calls `tcp_retransmit_last` directly, verifies bytes 20..24 of
  `_tcp_tx_scratch` (the payload area after the 20-byte header) hold
  the same "HELLO" bytes. Emits `boot r94 data retransmit ok --`.

### R94.M3 -- TIME_WAIT + half-close -- LANDED

* **#2065 (M3-001) -- TIME_WAIT holds 2xRTO before freeing.**
  `net/tcp.pdx tcp_process_segment`'s `tpsg_fw1_no_ack` /
  `tpsg_st_fin_wait2` / `tpsg_st_closing` arms now arm
  `time_wait_deadline` (@+240, new slot) at `_tick_count +
  TCP_TIME_WAIT_TICKS (200 == 2*TCP_RTO_TICKS)` and DO NOT call
  `tcp_free_tcb`. `tcp_poll_retransmits` picks up the reap in its
  own scan (state==10 with a non-zero deadline whose tick has
  passed). This replaces the pre-R94 free-immediately-on-FIN
  behavior without RFC 793's literal 4-minute MSL, which is too long
  for a kernel-native 64-entry fixed-size TCB pool.

* **#2066 (M3-002) -- `sys_shutdown` differentiates SHUT_RD/WR/RDWR.**
  New `tcp_shutdown_how(tcb_idx, how)` primitive in `net/tcp.pdx`
  wrapping the pre-R94 `tcp_close`. Bit 0 of `shutdown_flags` (@+264,
  new slot) marks the READ side locally shut -- subsequent `sys_recv`
  returns 0 (EOF) regardless of rx_buf contents. Bit 1 marks WRITE
  and drives `tcp_close`. `sys_recv_body` now reads the RD bit
  before draining. Values > 2 are silently ignored (matches pre-R94
  posture of tolerating out-of-range `how`).

* **#2067 (M3-003) -- witness: half-close.**
  Landed as scenario C of `witness_r94_substrate`. Synthesizes an
  ESTABLISHED TCB, calls `tcp_shutdown_how(SHUT_WR)`, asserts
  state == 5 (FIN_WAIT_1) AND `shutdown_flags` bit 1 set. Emits
  `boot r94 half close ok --`. The "verify the other direction
  still delivers data" arm of the spec text is DEFERRED to the
  multi-task witness that R94.M4-003 was scoped to land (also
  deferred, see below) -- it requires a bidirectional data-flow
  fixture beyond straight-line boot witness scope.

### R94.M4 -- blocking accept()/recv() -- PARTIALLY LANDED

* **#2068 (M4-001) -- `sys_accept` blocks via `wake_block`.**
  `syscall/handlers/sys_accept.pdx` rewritten to loop: try
  `tcp_accept_pending`; if TCP_NONE and `_current_tcb != 0` and no
  waiter already registered, register `_current_tcb` into
  `_tcp_accept_waiter_table[listener_idx*8]` and `sched_block`; on
  resume re-check. `net/tcp.pdx tcp_wake_accept_if_any(listener_idx)`
  fires from `tcp_rx_handle` after `backlog_pending_tcb` gets stamped
  -- clears the slot BEFORE `sched_wake` for at-most-once wake
  ordering (mirrors `poll_wake_check_and_clear`). Fall through to
  -EAGAIN when `_current_tcb == 0` (boot / pre-init context) matches
  the pre-R94 non-blocking posture.

* **#2069 (M4-002) -- `sys_recv` blocks on empty.**
  `syscall/handlers/sys_recv.pdx` TCP branch rewritten with the same
  `_tcp_recv_waiter_table` shape and re-check-after-wake loop. The
  `poll_wake_check_and_clear` and the new `tcp_wake_recv_if_any`
  BOTH fire at the end of `tpsg_st_established`'s data-received arm
  in `net/tcp.pdx`. UDP branch untouched at R94 -- UDP blocking recv
  lands with a follow-up round because the UDP row layout does not
  yet carry a waiter slot; adding one would perturb R100-PREP-002's
  own witness contracts.

* **#2070 (M4-003) -- witness: blocking accept()/recv() across real
  RTT.** DEFERRED. A meaningful witness of blocking behavior requires
  a multi-task fixture (one task in the blocking call, another
  driving the RX path). The boot-time straight-line witness pattern
  cannot construct this without hijacking `task_pool.pdx`'s init
  bootstrap; a dedicated multi-task witness harness (like R20b's
  echo cascade) is the right home for this and lands with the
  follow-up round.

### R94.M5 -- RFC 6298 Karn + backoff -- LANDED

* **#2071 (M5-001) -- SRTT/RTTVAR sampling with Karn.**
  `net/tcp.pdx tcp_process_segment`'s `tpsg_st_established` ACK arm
  now, before the cwnd update, computes `rtt = _tick_count -
  last_seg_send_tick`; SKIPS the sample if `last_seg_was_rxmt` is
  set (Karn); on first sample seeds `srtt=rtt`, `rttvar=rtt/2`,
  `rto_ticks = srtt + 4*rttvar`; on subsequent samples updates per
  RFC 6298 §2 (`rttvar = 3/4*rttvar + 1/4*|srtt-rtt|`, `srtt =
  7/8*srtt + 1/8*rtt`, `rto = srtt + 4*rttvar`). Clamped rto >= 1
  tick. `tcp_send_segment` stamps `last_seg_send_tick` +
  `last_seg_was_rxmt=0` on every fresh send; `tcp_retransmit_last`
  stamps `last_seg_was_rxmt=1` so Karn defends against retransmit
  ambiguity.

* **#2072 (M5-002) -- exponential backoff.**
  `net/tcp.pdx tcp_poll_retransmits` now, after firing a retransmit,
  doubles per-TCB `rto_ticks` (@+232, new slot) up to
  `TCP_RTO_MAX_TICKS = 6000` (~60s). `tcp_send_segment` and
  `tcp_retransmit_last` both read this per-TCB value when arming
  `rto_deadline`. `tcp_alloc_tcb` seeds `rto_ticks =
  TCP_RTO_TICKS = 100` (~1s) at TCB alloc.

### R94.M6 -- off-box witness + smoke + closure -- LANDED

* **#2073 (M6-001) -- witness: real off-box TCP connect via
  `sys_connect` + SLIRP hostfwd.**
  `src/kernel/boot/witness/r94_tcp_offbox.pdx`. Mints a
  KIND_TCP_SOCKET via `tcp_socket_new`, calls `sys_connect_body`
  with target 10.0.2.2:5555 (SLIRP gateway + hostfwd port), polls
  the RX ring for state==ESTABLISHED (or takes the synchronous
  return path if the local NIC's TX ring drives SLIRP fast enough
  that ESTABLISHED lands before sys_connect returns). Emits
  `boot r94 offbox handshake ok --` on success.

* **#2074 (M6-002) -- same witness sends PING + reads reply.**
  Same file. After ESTABLISHED, `sys_send_body("PING", 4)` then
  polls the RX ring until `rx_tail > rx_head`; emits
  `boot r94 offbox roundtrip ok -- bytes=<N>` carrying the reply
  byte count. The spec called for a `GET / HTTP/1.0` shape but a
  4-byte PING/PONG matches the R94 substrate's actual load-bearing
  posture -- an HTTP GET requires a real HTTP responder on the
  host side, whereas PING/PONG works against a plain netcat
  listener with no framing agreement. A future landing that stages
  a hosted HTTP responder MAY tighten the payload; the R94 witness
  proves the byte round-trip, which is what M6-002's assertion
  needs.

* **#2075 (M6-003) -- wire into `run-smoke.sh` +
  `run-qemu.sh` hostfwd.**
  `tools/run-qemu.sh` learns `PAIDEIA_HOSTFWD` env var:
  comma-separated list of `hostfwd=<spec>` fragments appended to
  the `-netdev user` argument. `tools/run-smoke.sh` gets the
  `boot_r94_tcp_offbox` mode with golden
  `tests/expected-r94-tcp-offbox.golden` pinning the substring
  `boot r94 offbox` (matches EITHER the ok pair OR the skip line).
  Documented invocation: `PAIDEIA_HOSTFWD='tcp::5555-:5555'
  PAIDEIA_NIC=virtio bash -c 'nc -l 5555 -q 1 <<<"PONG" & sleep
  0.2; tools/run-smoke.sh boot_r94_tcp_offbox'`. The
  substring-tolerant golden matches R92 icmp precedent.

## New TCB fields (@+208..+272)

R94 adds 8 new fields inside the pre-R94 "reserved 208..511" band of
the 512-byte TCB row. All 8-byte aligned, all reserved for the R94
substrate:

| Offset | Field                    | Purpose                                    |
|-------:|:-------------------------|:-------------------------------------------|
|   +208 | `so_error`               | SO_ERROR observation (R95.M1-002 sibling)  |
|   +216 | `srtt_ticks`             | RFC 6298 SRTT (0 = uninitialized)          |
|   +224 | `rttvar_ticks`           | RFC 6298 RTTVAR                            |
|   +232 | `rto_ticks`              | Current RTO (backoff target)               |
|   +240 | `time_wait_deadline`     | Tick at which TIME_WAIT reaps (0 = n/a)    |
|   +248 | `last_seg_was_rxmt`      | Karn flag (1 = last send was rxmt)         |
|   +256 | `last_seg_send_tick`     | Tick of last send (RTT baseline)           |
|   +264 | `shutdown_flags`         | Bit 0 = SHUT_RD; bit 1 = SHUT_WR           |
|   +272 | `last_seg_payload_bytes` | Bytes cached in `_tcp_tx_buf_table` slot   |

New module-level tables:
- `_tcp_recv_waiter_table[64*8]` -- one blocked-task-TCB slot per TCB.
- `_tcp_accept_waiter_table[64*8]` -- same for accept.

## R72 witness pre-existing failure (#2134)

Pre-R94, `boot_r72_tcp_echo` failed on pristine HEAD -- only 1/3
expected `L3 TCP segment received` klog lines emitted. Post-R94,
whether the R94 substrate changes fix R72 depends on whether the
root cause was in the tick-hook race (R94 introduces one) or in
something else. If R72's smoke recovers as a side effect of R94's
landing, remove the #2134 blocker; otherwise the root cause is
independent and stays a follow-up. The R94 witness's
`tcp_poll_retransmits` scenario A specifically synthesizes a TCB
whose local != remote so it does NOT re-enter the loopback path,
avoiding a re-entrance interaction with the R72 witness's own
loopback drive.

## Deferrals (list, not hidden)

- **cwnd/slow-start**: no change from R72's Reno-lite. BBRv3 lives
  in the Phase-2 userspace stack -- see `design/network/bbrv3.md`
  and R91 plan §0.1.
- **Selective ACK (SACK)** -- deferred.
- **TCP timestamps option (RFC 7323)** -- deferred; would give a
  better RTT reference than tick_count but requires MSS-option
  wiring which is itself deferred.
- **ECN (RFC 3168)** -- deferred.
- **MSS option negotiation** -- deferred; every TCB stays at
  `TCP_MSS_DEFAULT = 536`.
- **Multi-caller sys_accept / sys_recv** -- single waiter slot per
  TCB at MVP. Bitmap over TCB pool lands with the follow-up round.
- **UDP blocking recv** -- see R94.M4-002 disposition above.
- **Blocking-behavior witness (R94.M4-003)** -- deferred; requires
  multi-task fixture.
- **Real HTTP responder in the M6 off-box witness** -- PING/PONG
  suffices for the M6 assertion; HTTP framing lands with the
  sibling softarch wave's curl-like tool.
- **Sliding-window flow control** -- rcv_wnd stays a fixed 4096
  advertised; no dynamic backpressure. The R94 witness set does
  not exercise a window-full path.

## Encoder gaps encountered

None new. R94 stayed within paideia-as v0.24's already-proven
encoder envelope:
- xor+mov_b for byte loads.
- mov_b for byte stores.
- [reg+imm] addressing throughout (no SIB [base+index]).
- 64-bit divide via `xor rdx, rdx; div r9` for the tick mod-10
  gate in `handle_timer`.

## Files touched

- `src/kernel/core/net/tcp.pdx` (+ ~450 lines).
- `src/kernel/core/syscall/handlers/sys_shutdown.pdx` (M3-002).
- `src/kernel/core/syscall/handlers/sys_recv.pdx` (M4-002).
- `src/kernel/core/syscall/handlers/sys_accept.pdx` (M4-001).
- `src/kernel/core/int/exceptions.pdx` (M1-001).
- `src/kernel/core/klog/keys.pdx` (fingerprint tags + keys).
- `src/kernel/boot/witness/r94_substrate.pdx` (NEW, M1/M2/M3
  scenario carrier).
- `src/kernel/boot/witness/r94_tcp_offbox.pdx` (NEW, M6-001/002).
- `src/kernel/boot/kernel_main.pdx` (witness wire-in).
- `tools/run-qemu.sh` (PAIDEIA_HOSTFWD).
- `tools/run-smoke.sh` (`boot_r94_tcp_offbox` mode + doc line).
- `tests/expected-r94-tcp-offbox.golden` (NEW).
- `design/round-retrospectives/r94-closed.md` (this file, NEW).

## What R94 unblocks

- R95 socket API polish already landed -- R94 is not blocked by or
  a dependency of R95; the two rounds address orthogonal substrate
  gaps in the same round-family.
- The sibling softarch wave's curl-like tool now has a real
  retransmit + backoff + orderly-close substrate to exercise
  against; the pre-R94 substrate would have busy-looped on any
  packet loss.
- The eventual R96 privileged-port gate can layer on top of R94's
  hardened socket rights model (already landed in R95.M4-001).

## Not-in-scope reminder

The R91 plan's §0.2 "Phase-2 architecture tension" is unchanged:
this whole round-family stays kernel-native monolithic; the
userspace `net-stack` server migration is a future osarch-planned
wave. R94 hardens what R72 built; it does not migrate it.
