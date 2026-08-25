# TCP substrate (R72)

Issues #1923–#1932. Kernel-native TCP over the existing IPv4/e1000e
stack (R27), with a BSD-ish socket API (SC+ 87–94) on top. This is a
**realistic MVP**, not a production TCP: the goal is a stream primitive
solid enough for a future userspace `curl`/`pkg install http://` client
to build on, not RFC-complete correctness under adversarial network
conditions.

## Scope and non-goals

In scope:

- 11-state TCP state machine (RFC 793 §3.2), real transitions on
  SYN/SYN-ACK/ACK/FIN/RST.
- Plain 3-way handshake with a monotonically-increasing local ISN.
- A single-timer retransmit primitive (RTO = 1s, no backoff).
- Reno-lite congestion control (slow start + a fixed congestion-
  avoidance increment + dup-ACK-triggered cwnd halving).
- A socket API (`sys_socket`/`bind`/`listen`/`accept`/`connect`/`send`/
  `recv`/`shutdown`) backed by two new capability kinds.
- A kernel-side boot witness proving the whole cycle: handshake, data
  exchange (port-7 echo), orderly close.

Explicitly deferred (documented at each call site, not silently
dropped):

- SYN cookies / stateless SYN defense (RFC 4987).
- RFC 6298 Karn's-algorithm RTT sampling and exponential backoff.
- Real RFC 5681 congestion avoidance (per-byte / per-ACK accounting).
- Selective ACK, window scaling, MSS option negotiation.
- A full data-retransmit replay buffer (only control segments —
  SYN/FIN/ACK — replay correctly on RTO; see §Retransmit below).
- 2MSL TIME_WAIT delay (TCBs free immediately on reaching TIME_WAIT).
- Half-close (SHUT_RD/SHUT_WR distinct from SHUT_RDWR).
- Blocking accept()/recv() (both are non-blocking; no data/connection
  pending returns -EAGAIN or 0 rather than parking on a wait queue).

## State machine

```
                    CLOSED
                       |
                 (app: listen())
                       v
                    LISTEN --------------------+
                       |                       |
              (rx: SYN, no ACK)                |
                       v                        |
                  SYN_RCVD                      |
                       |                        |
              (rx: ACK, ack==snd_nxt)           |
                       v                        |
                 ESTABLISHED <------------------+
             (app: connect() draws SYN_SENT,
              rx: SYN+ACK -> ESTABLISHED here too)
                    /        \
        (app: close())    (rx: FIN)
              v                  v
        FIN_WAIT_1          CLOSE_WAIT
         /       \               |
  (rx:ACK)      (rx:FIN)   (app: close())
      v             v              v
 FIN_WAIT_2      CLOSING       LAST_ACK
      |             |              |
  (rx:FIN)      (rx:ACK)       (rx:ACK)
      v             v              v
        `---> TIME_WAIT <---------'
                  |
          (freed immediately —
           no 2MSL wait at MVP)
                  v
               CLOSED
```

Eleven states total: `CLOSED, LISTEN, SYN_SENT, SYN_RCVD, ESTABLISHED,
FIN_WAIT_1, FIN_WAIT_2, CLOSE_WAIT, CLOSING, LAST_ACK, TIME_WAIT`
(`net/tcp.pdx`'s `TCP_ST_*` constants, values 0–10). Simultaneous
open/close paths beyond the ones the diagram shows (e.g. SYN_SENT
receiving a bare SYN) are not implemented — dropped, not crashed.

## TCB layout

Fixed-size pool: 64 TCBs × 512 bytes = 32 KiB, in `net/tcp.pdx`'s
`_tcp_tcb_table`. No dynamic allocation; `tcp_alloc_tcb`/`tcp_free_tcb`
scan/clear the `in_use` flag.

| Offset | Field | Notes |
|---|---|---|
| +0 | `state` | 0–10, see above |
| +8 | `local_port` | low 16 bits meaningful |
| +16 | `remote_port` | low 16 bits meaningful |
| +24 | `local_ip` | 4 bytes, byte-indexed |
| +32 | `remote_ip` | 4 bytes, byte-indexed |
| +40 | `snd_una` | oldest unacked seq |
| +48 | `snd_nxt` | next seq to send |
| +56 | `snd_wnd` | peer's advertised window (informational) |
| +64 | `rcv_nxt` | next expected seq |
| +72 | `rcv_wnd` | our advertised window (fixed 4096) |
| +80 | `iss` | initial send sequence number |
| +88 | `irs` | initial receive sequence number |
| +96 | `cwnd` | bytes |
| +104 | `ssthresh` | bytes |
| +112 | `dup_ack_count` | |
| +120 | `rto_deadline` | tick count (`_tick_count`-based) |
| +128 | `last_seg_seq` | retransmit replay |
| +136 | `last_seg_len` | retransmit replay (seq-space consumed) |
| +144 | `last_seg_flags` | retransmit replay |
| +152 | `backlog_pending_tcb` | LISTENER only: one pending child, or `TCP_NONE` |
| +160 | `claimed` | child TCB: 1 once `accept()` has taken it |
| +168 | `in_use` | 0 = free |
| +176 | `rx_head` | bytes consumed by `recv()` |
| +184 | `rx_tail` | bytes appended by RX |
| +200 | `mss` | fixed `TCP_MSS_DEFAULT` (536); no option negotiation |

RX/TX buffers are NOT embedded in the row: `_tcp_rx_buf_table` and
`_tcp_tx_buf_table` are separate 64×4096-byte tables (512 KiB each),
indexed by `tcb_idx * 4096`. `_tcp_tx_buf_table` is declared but not yet
wired into the send path (see §Retransmit).

Listener backlog is exactly **one** pending connection per listener —
a real accept queue is future work once a server workload needs depth
> 1.

## RX/TX paths

**TX** (`tcp_send_segment`): builds a 20-byte header (no options) plus
payload into a scratch buffer, computes the real pseudo-header checksum
over the whole segment, advances `snd_nxt` by the seq-space the segment
consumes (payload length + 1 for SYN + 1 for FIN), records
retransmit-replay bookkeeping, and dispatches.

**The loopback fast path is this round's central architectural
decision.** When a segment's `local_ip == remote_ip` (a self-connect —
the only case the boot witness exercises, since this tree has no
127.0.0.0/8 loopback interface; `net/ipv4.pdx` defines only
`_ipv4_my_ip`), `tcp_send_segment` calls `tcp_rx_handle` **directly, in
the same call stack**, rather than going through
`ipv4_tx_send`/`l2_tx_send`/the e1000e ring. A non-loopback destination
takes the real `ipv4_tx_send(protocol=6, ...)` path (real code, just
unexercised by this round's witness).

This keeps `e1000e.pdx` untouched and `ipv4.pdx` touched by exactly one
line (the `proto == 6 -> tcp_rx_handle` dispatch branch in
`ipv4_rx_handle`, alongside the existing ICMP/UDP branches). It also
means a self-connect's ENTIRE handshake resolves synchronously: the
`SYN` call recurses through the listener's `tcp_rx_handle` (spawn child
+ reply SYN|ACK), the connector's `tcp_rx_handle` (ESTABLISHED, reply
ACK), and the child's `tcp_rx_handle` (ESTABLISHED) before returning —
recursion depth bounded at ≤4 by the handshake/close shapes themselves.
No scheduler, no interrupt, no async wait: `boot_r72_tcp_echo` is
ordinary straight-line kernel code.

**RX** (`tcp_rx_handle`): parses the header in place (no scratch copy —
`ipv4_rx_handle` already copied the IPv4 header to its own scratch;
this function indexes the TCP header directly off the packet pointer),
resolves the segment to a TCB via the established 4-tuple
(`local_port, remote_ip, remote_port`) first, then a `LISTEN` match by
`local_port` alone. A 4-tuple miss with no listener match is dropped. A
listener match on a bare SYN (no ACK) allocates a fresh child TCB in
`SYN_RCVD` and replies `SYN|ACK`; anything else addressed to a listener
is dropped (no simultaneous-open support).

`tcp_process_segment` is the 11-state dispatch proper, applied to an
already-resolved TCB. `ESTABLISHED`'s data-received branch checks
`local_port == 7` (RFC 862, matching `net/udp.pdx`'s own port-7 echo
convention) and echoes the payload straight back — the mechanism
`boot_r72_tcp_echo` exercises.

Checksums are computed and sent on TX but **not verified on RX** — the
same "no bit-flip surface on the QEMU virtual link" posture
`net/udp.pdx` already takes, stated explicitly here rather than left as
a silent omission.

## Retransmit

Single timer per TCB: `rto_deadline = _tick_count + 100` (~1s at the
~100 Hz LAPIC tick), (re)armed on every segment sent. No RFC 6298 Karn
refinement, no exponential backoff — a fixed 1-second RTO, always.

`tcp_poll_retransmits()` scans all 64 TCBs and replays any TCB past its
deadline with outstanding unacked data via `tcp_retransmit_last`, which
resends `last_seg_seq`/`last_seg_flags` **without** advancing `snd_nxt`
(a retransmit reuses already-numbered seq-space).

**Honesty note**: `tcp_retransmit_last` only replays correctly for
zero-payload control segments (SYN, SYN|ACK, ACK, FIN). A TCB carrying
unacked *data* whose RTO fires re-sends a zero-length segment with the
current flags — it acks/probes but does not recover the lost bytes. A
full replay needs the originally-sent bytes cached in
`_tcp_tx_buf_table`, which this landing declares but does not yet wire
`tcp_send_segment`'s payload copy through.

`tcp_poll_retransmits` is **not wired to the LAPIC timer ISR**
(`int/exceptions.pdx`) — that file is outside this round's touched-file
set, and its hot path is not somewhere to bolt an unrelated 64-TCB scan
without a dedicated review. It is exported and callable; a future
round's idle-loop or timer-tick hook wires it in. `boot_r72_tcp_echo`
never observes an RTO fire, since the loopback path resolves every
segment synchronously, well under one tick.

## Congestion control (Reno-lite)

`cwnd` starts at 1 MSS; `ssthresh` starts at 0xFFFF (effectively
unbounded until a real loss event). On an ACK covering new data:
`cwnd += MSS` while `cwnd < ssthresh` (slow start); `cwnd += max(1,
MSS/8)` once `cwnd >= ssthresh` — a fixed small increment standing in
for RFC 5681's per-byte accounting, not real AIMD tuning. Three
consecutive duplicate ACKs (same ack value, no new data) halve `cwnd`
(floored at 1 MSS), set `ssthresh` to the halved value, and reset the
dup count — no fast-retransmit / fast-recovery segment resend at this
landing, matching the round brief's explicit "skeleton Reno" ask rather
than RFC 5681 in full.

## Socket API → capability mapping

Two new derived kinds in `cap/kind.pdx`, both over `KIND_IPC_ENDPOINT`
for documentation symmetry with that file's derived-kind family, both
**root-minted** (no parent-capability argument — `sys_socket` needs no
authority, matching `sys_open`'s own posture):

- `KIND_TCP_SOCKET` (0x1A5) — an active or not-yet-connected socket:
  `bind`/`connect`/`send`/`recv`/`shutdown` all require this kind.
- `KIND_TCP_LISTENER` (0x1A4) — a socket after `listen()`: only
  `accept()` operates on this kind.

`listen()` **retags** an existing `KIND_TCP_SOCKET` slot to
`KIND_TCP_LISTENER` in place (same slot, same `tcb_idx` target_ptr) —
it does not mint a second capability over the same TCB row.
`accept()`'s new socket mints a fresh `KIND_TCP_SOCKET` over the
already-allocated child TCB.

Neither kind is registered in `cap_invoke_dispatch` (no
`cap/invoke.pdx` change) — every operation goes through the dedicated
SC+ 87–94 syscalls, which resolve the cap_table slot directly via
`net/tcp_socket.pdx`'s `tcp_socket_resolve`, the same posture
`KIND_PDXFS_FILE` takes for its own syscall family.

| Syscall | SC+ ID | Args | Notes |
|---|---|---|---|
| `sys_socket` | 87 | domain, type, proto | AF_INET/SOCK_STREAM only |
| `sys_bind` | 88 | fd, local_port | address is always `_ipv4_my_ip` |
| `sys_listen` | 89 | fd, backlog | backlog ignored (1-deep) |
| `sys_accept` | 90 | fd | -EAGAIN if nothing pending |
| `sys_connect` | 91 | fd, remote_ip (u32), remote_port | -EINPROGRESS off-box |
| `sys_send` | 92 | fd, buf, len | capped 1024B/call |
| `sys_recv` | 93 | fd, buf, len | non-blocking |
| `sys_shutdown` | 94 | fd, how | `how` ignored; full-duplex close only |

## Boot witness

`boot_r72_tcp_echo` (`boot/witness/r72_tcp_echo.pdx`) builds two TCBs
directly against `net/tcp.pdx`'s primitives (no cap_table/syscall layer
— a boot witness runs before any ring-3 process exists), self-connects
port 50000 → port 7, sends `"hello"`, verifies the port-7 echo landed
byte-for-byte in the client's `rx_buf`, then drives a mutual
`tcp_close` and confirms both TCBs freed. Four klog fingerprints, one
per checkpoint: `R72 TCP SYN OK`, `R72 TCP HANDSHAKE OK`,
`R72 TCP ECHO OK`, `R72 TCP CLOSE OK` — asserted in order by
`tests/expected-r72-tcp-echo.golden`, gated opt-in via
`PAIDEIA_R72_TCP=1` in `.githooks/pre-push`.

## Judgment calls worth flagging

- **fd space is cap_table slots**, not a separate socket-fd table —
  matches the `sys_pdxfs_open` precedent of returning a raw cap slot as
  the caller-visible handle.
- **No RX checksum verification** — matches `net/udp.pdx`'s existing
  posture for this QEMU-virtual-link tree.
- **`accept()`/`recv()` are non-blocking** rather than integrated with
  the scheduler's block/wake path (`sys_wait4`'s own R17.M0-724-D5a
  precedent) — a real blocking implementation is a follow-up.
- **Two-TCB-per-connection self-connect** rather than any special-cased
  "loopback socket" — the same TCB/state-machine code path a real
  off-box connection takes, just delivered in-process.
