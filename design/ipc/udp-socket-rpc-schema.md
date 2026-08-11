# PaideiaOS — UDP Socket RPC Schema (KIND_UDP_SOCKET)

**Status:** Draft v0.1 (R27.M6 scaffolding)
**Date:** 2026-08-11
**Issue:** #994 (r27-m6-002)
**Depends on:** #1015 (userspace-server substrate — see r20-closure blocker)
**Sibling:** `src/kernel/core/cap/udp_socket_cap.pdx` (cap rights model)
**Scope:** Wire format for `bind` / `sendto` / `recvfrom` / `close`
RPCs exchanged between a KIND_UDP_SOCKET holder (userspace network
client — DNS resolver, syslog forwarder, echo daemon) and the
`net_supervisor` driver-server.

## Pillar alignment

- **Pillar 3 (microkernel).** All UDP I/O leaves the kernel over a
  named-endpoint IPC to `net_supervisor`. The kernel path
  (`src/kernel/core/net/udp.pdx §udp_rx_handle`, landed at R27.M6)
  hosts a special-case echo responder on port 7 for the ping-family
  demo; every other port routes to userspace via the KIND_UDP_SOCKET
  handle.
- **Pillar 6 (security by construction).** Every RPC frame carries a
  KIND_UDP_SOCKET capability handle. The driver-server validates the
  handle's rights on receive (BIND for bind, SEND for sendto, RECV
  for recvfrom) via `udp_cap_verify` (lands with #1015 unblock).
  Handle revocation invalidates every outstanding RPC citing it.
- **Pillar 8 (post-quantum readiness).** UDP is a transport; end-to-end
  crypto lives above it. The R32 ML-DSA-65 signature substrate signs
  DNS-over-UDP responses and syslog packets at the application layer;
  this schema does not encrypt.

## 1. Transport (post-#1015)

The transport is the wait-free dataflow IPC substrate from
`design/ipc/wait-free-dataflow.md`, framed via
`design/ipc/typed-handoff.md`. Each RPC is a request/reply pair over
a per-client endpoint minted by `net_supervisor`.

Until #1015 lands the substrate is not in the syscall table (no
`sys_ipc_recv` / `sys_ipc_reply`), so wire code is intentionally
absent from R27.M6. The kernel-side `udp_rx_handle` port-7 special
case is the proxy the eventual userspace echo server will replace
once it exists.

## 2. RPC methods

All request/reply frames start with a common 4-byte magic
(`0x53554450` = "SUDP") + 2-byte op + 2-byte flags. This mirrors the
`0x424C4B52` / "BLKR" scheme in `design/ipc/blkdev-rpc-schema.md`.

### 2.1 `bind(port) -> u16`

Wire request frame (16 B):

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0  | 4 | magic         | `0x53554450` ("SUDP") |
| 4  | 2 | op            | `0x0001` = bind |
| 6  | 2 | flags         | reserved (0) |
| 8  | 2 | port          | local port to bind (host-order u16) |
| 10 | 6 | _pad          | 0 |

Wire reply frame (16 B):

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0  | 4 | magic         | `0x53554450` |
| 4  | 2 | status        | 0=OK, 1=EADDRINUSE, 2=EACCES, 3=EBADF |
| 6  | 2 | flags         | reserved |
| 8  | 8 | _pad          | 0 |

Rights required on the KIND_UDP_SOCKET handle: `R_UDP_BIND` (bit 0).

**State transition:** UNBOUND -> BOUND on success. Cap descriptor
`local_port` field updated to the bound port.

### 2.2 `sendto(dst_ip, dst_port, buf_cap, len) -> u16`

Wire request frame (32 B):

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0  | 4 | magic         | `0x53554450` |
| 4  | 2 | op            | `0x0002` = sendto |
| 6  | 2 | flags         | bit 0 = "reply expected" hint |
| 8  | 4 | dst_ip        | destination IPv4 (network-byte-order u32) |
| 12 | 2 | dst_port      | destination port (host-order u16) |
| 14 | 2 | len           | payload length (bytes; max 1472 for 1500 MTU) |
| 16 | 8 | buf_cap       | KIND_PAGE cap handle for the send buffer |
| 24 | 8 | _pad          | 0 |

Wire reply frame (16 B):

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0  | 4 | magic         | `0x53554450` |
| 4  | 2 | status        | 0=OK, 4=EMSGSIZE, 5=ENETDOWN, 6=EARP_TIMEOUT |
| 6  | 2 | flags         | reserved |
| 8  | 8 | bytes_sent    | len on success, 0 on error |

Rights required: `R_UDP_SEND` (bit 1).

**Note:** an ARP miss maps to `EARP_TIMEOUT` (6); the driver-server
kicks an `arp_send_request` and retries once with a 3-tick budget
before failing back. The kernel-side `ipv4_tx_send` return code 3
(`IPV4_E_ARP_PENDING`) surfaces as this status on the second miss.

### 2.3 `recvfrom(buf_cap, max_len) -> (src_ip, src_port, len)`

Wire request frame (16 B):

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0  | 4 | magic         | `0x53554450` |
| 4  | 2 | op            | `0x0003` = recvfrom |
| 6  | 2 | flags         | bit 0 = "non-blocking" |
| 8  | 8 | buf_cap       | KIND_PAGE cap handle for the recv buffer |

Wire reply frame (24 B):

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0  | 4 | magic         | `0x53554450` |
| 4  | 2 | status        | 0=OK, 7=EAGAIN (non-blocking + empty), 8=EBADF |
| 6  | 2 | flags         | reserved |
| 8  | 4 | src_ip        | packet source IPv4 (network-byte-order u32) |
| 12 | 2 | src_port      | packet source port (host-order u16) |
| 14 | 2 | len           | bytes written into buf_cap |
| 16 | 8 | _pad          | 0 |

Rights required: `R_UDP_RECV` (bit 2).

**Backpressure:** the driver-server keeps a bounded per-port recv
queue. Under overflow the incoming packet is dropped and the
`_udp_drops` counter is bumped (name mirrors the kernel's
`_udp_rx_no_socket` counter). No signal is delivered to the client
— the semantic is "UDP is unreliable; senders retry if they care".

### 2.4 `close() -> u16`

Wire request frame (8 B):

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0  | 4 | magic         | `0x53554450` |
| 4  | 2 | op            | `0x0004` = close |
| 6  | 2 | flags         | 0 |

Wire reply frame (8 B):

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0  | 4 | magic         | `0x53554450` |
| 4  | 2 | status        | 0=OK, 8=EBADF |
| 6  | 2 | flags         | 0 |

Rights required: none (any KIND_UDP_SOCKET holder can close).

**State transition:** any state -> CLOSED. Cap remains valid for
introspection until revoked; all subsequent RPCs return EBADF.

## 3. Kernel-side kernel_main wire-up (R28+ target)

At R28 the `net_supervisor` boot chain will mint one KIND_UDP_SOCKET
cap per configured port (or per port on demand once ephemeral-port
allocation lands) and hand it to the userspace network stack. The
current `udp_rx_handle` port-7 kernel-side echo will be retired in
favour of a userspace echo daemon that receives via `recvfrom` and
replies via `sendto` — a paper-thin test bench for the RPC round-
trip.

Until then the kernel remains the only speaker of UDP on the wire,
and the KIND_UDP_SOCKET cap is a scaffolding placeholder that
proves the mint-gate wires up cleanly against the rest of the cap
system.

## 4. Deferrals

- **Multicast + broadcast address filtering.** The R27.M5 IPv4
  `dst_ip` filter accepts `_ipv4_my_ip` + limited broadcast
  (`255.255.255.255`) only; multicast group joins (IGMP) land with
  R30+ when we get a real routing table.
- **UDP checksum on TX.** `udp_build` writes `checksum = 0` per RFC
  768 "no checksum" latitude. Real checksum wire-up defers until an
  operator observes packet corruption on the wire; MTU-1500 QEMU
  virtual link has none.
- **Port ephemeral allocator.** `udp_socket_cap_mint(0, ...)`
  currently rejects port 0. A userspace ephemeral-port allocator
  lands with the R28+ `net_supervisor` boot chain and either
  reserves the [49152, 65535] IANA-dynamic range or mints a cap
  after the allocator hands back a concrete port.
