# R91-R98 Wave Retrospective: The Networking Wave

**Date:** 2026-09-02
**Rounds covered:** R91 (generic NIC dispatch + three drivers), R92
(routing table + ARP + off-box ICMP), R93 (DHCP + UDP socket
integration + DNS stub), R94 (TCP hardening + off-box smoke), R95
(socket API polish + poll + capability rights), R96 (MAC-spoof + IOMMU
audit + priv-port gate), R97 (TLS placement decision), R98 (net-tools
smoke lane consolidation).
**Issues:** #2011..#2106 (96 issues over 8 rounds).
**Duration:** 2026-09-01 -- 2026-09-02.
**Wave-closing issue:** #2107 (R99.M1-001, this retrospective).
**Release tag:** `net-wave-closed` recommended alongside each round's
own `r91-closed` .. `r98-closed` tag.

## Wave intent

Take the tree from "e1000e-probe only, no route table, no live TCP
off-box" (post-R28 state) to "three NIC drivers behind a dispatch
shim, DHCP-installed lease, live ICMP + UDP + TCP off-box against
QEMU SLIRP, socket API a real Linux client expects, hardening pass
that closes the priv-port gap and formalises the MAC-spoof + IOMMU
audits, TLS placement ratified for user-space, and a single opt-in
flag that runs the whole networking smoke matrix as one green/red."

That is exactly what R91-R98 land. The wave was planned as one
integrated block (per `design/networking/r91-plan.md`) so downstream
cross-references between rounds (R92's route table underpinning R93's
DHCP writeback; R94's off-box witness sharing R92's ARP + route
substrate; R95's socket rights feeding R96's priv-port gate; R96's
audit-only landings gated so a future wire-up round consumes existing
kind ordinals) all resolve cleanly at wave close.

## Per-round scope shipped

### R91 -- Generic NIC dispatch + three-driver bring-up (2026-09-01)

- `KIND_NIC` (0x1AD) + 4-row pool + rights + failure band.
- `nic_dispatch.pdx` router: probe / tx / rx_poll / rx_dispatch / mac
  / link cmp/je dispatch over `_active_nic_kind`.
- Three drivers landed together:
  - **e1000e** (`core/drivers/e1000e/`): probe + reset + rx_ring +
    tx_ring + mac + irq + msix + phy. Filters class 0x02/subclass
    0x00 + VID=0x8086 + 6 DID ranges (82574..i219).
  - **virtio-net 1.0** (`core/drivers/virtio_net/`): probe +
    common_cfg + virtqueue + rx + tx + mac + isr. Handshake through
    the ACK -> DRIVER -> FEATURES_OK -> DRIVER_OK sequence with
    F_MAC + F_STATUS negotiation.
  - **rtl8139** (`core/drivers/rtl8139/`): probe + rx + tx + mac +
    irq. 4-slot round-robin TX + 16 KiB continuous RX buffer with a
    driver-owned CAPR consumption cursor.
- R91.M5 probe cascade in `kernel_main.pdx` publishes the winning
  driver into KIND_NIC + wires TX/RX/MAC/link accessors.
- `PAIDEIA_NIC` env switch (default `virtio`) in `run-qemu.sh`.
- Boot witness `r91_nic_probe.pdx` fingerprint `boot r91 nic probe ok
  kind=<n> mac=<packed> link_up=<0|1>`.

**R91 debt at close:** 8 deferred items (TX completion reap, virtio
MSI-X, PCI BME enable, rtl8139 ERTXTH tuning, unbounded RX loop guard,
live link-status poll, rtl8139 IDT vector wiring, boot_r91_nic smoke
mode). Item #8 retired by R98.M1-001.

### R92 -- L2/L3 completion (2026-09-01)

- Mutable route record at `core/net/route_table.pdx` (my_ip / gw_ip /
  netmask / mtu). Retires the pre-R92 rodata `_ipv4_my_ip` +
  `_ipv4_gw_ip` constants.
- `route_table_set` + `route_table_get` field-id API (0=my_ip,
  1=gw_ip, 2=netmask, 3=mtu; R93 adds 4=dns_ip).
- `arp_probe_announce` (RFC 5227 minimal): 3x PROBE + 2x ANNOUNCE.
- `arp_announce_on_lease_acquired(new_my_ip)` -- callable symbol
  ready for R93 DHCP's ACK-handling path.
- ICMP-ping off-box witness against QEMU SLIRP gateway 10.0.2.2 --
  first end-to-end IPv4 round-trip in this tree.
- `design/networking/ipv6-deferral.md` formalising v6 out-of-scope
  through R99.

**R92 debt at close:** 5 deferred items (dhcp.pdx not-yet-existing --
retired by R93; ICMP witness unreachable success path -- retired by
R93 DHCP installing SLIRP-matching lease; TSC calibration; RFC 5227
randomisation; route table growth to N routes).

### R93 -- DHCP + UDP socket + DNS resolver stub (2026-09-02)

- `core/net/dhcp.pdx` (new): RFC 2131 DISCOVER/OFFER/REQUEST/ACK
  handshake, fixed sentinel xid, minimal option set. Writes lease
  into `route_table_set` for all four fields + `arp_announce_on_
  lease_acquired`.
- Route table extended with `RT_FIELD_DNS_IP` (field id 4).
- UDP socket integration: retires the pre-R30 `UdpSocketCap.KIND_
  UDP_SOCKET=0x50` posture; adopts the R100-PREP-002 landed
  `KIND_UDP_SOCKET=0x1A8`. `udp_rx_handle` rewritten to dispatch by
  destination port. Wire path in `udp_socket_send_body` for
  off-box (peer_ip != my_ip): builds UDP header, calls
  `ipv4_tx_send` with proto=17.
- New syscalls: `sys_sendto` (sysno 96) + `sys_recvfrom` (sysno 97).
- `core/net/dns.pdx` (new): minimal RFC 1035 §4 stub -- 12-byte
  header + QNAME + QTYPE/QCLASS=1. Refuses NXDOMAIN, TC, malformed
  labels/pointers, wrong txid, ANCOUNT==0.
- R93 witness: `boot r93 dhcp lease ok --` + `boot r93 dns resolve
  ok --`.
- Side benefit: R92.M3 ICMP witness's success path is now reachable
  because DHCP runs before it and installs a SLIRP-matching lease.

**R93 debt at close:** DNS cache upgrade path documented in
`design/network/dns-stub-vs-cache.md`.

### R94 -- TCP hardening + off-box smoke (2026-09-02)

- Retransmit timer wiring: `tcp_poll_retransmits` gated every 10
  LAPIC ticks via `int/exceptions.pdx handle_timer`.
- Data retransmit replay: `_tcp_tx_buf_table` now populated on send,
  read on `tcp_retransmit_last`. Retires the "honesty note" pre-R94
  zero-length-control-segment fallback.
- TIME_WAIT deferred free (2 MSL wait); half-close via honouring
  `sys_shutdown`'s `how` argument.
- Blocking `sys_accept` / `sys_recv` -- replaces the busy-poll shape
  a userspace server otherwise needs.
- RTT sampling + Karn's algorithm defence against retransmit
  ambiguity; exponential backoff on repeated RTO.
- Off-box witness `r94_tcp_offbox.pdx`: connects out through
  virtio-net rings + `hostfwd=tcp::5555-:5555` to a host-side
  netcat listener. First on-wire TCP roundtrip in this tree.
- `PAIDEIA_HOSTFWD` env switch in `run-qemu.sh`.

**R94 debt at close:** off-box golden left permissive so an
opportunistic push didn't gate on a background responder. Retired by
R98.M2-002 alongside the composite lane.

### R95 -- Socket API polish + poll + capability rights (2026-09-01)

- Sysnos materialised: 98 `getsockopt`, 99 `setsockopt`, 100
  `getpeername`, 101 `getsockname`, 102 `poll`.
- `SO_REUSEADDR` / `SO_NONBLOCK` at SOL_SOCKET; `TCP_NODELAY` at
  IPPROTO_TCP; `SO_ERROR` + `SO_TYPE` at SOL_SOCKET. Informational
  MVP flags at R95; real semantics deferred.
- `sys_poll` Linux-shaped `pollfd` (fd:i32, events:u16, revents:u16),
  capped at 32 fds. POLLIN / POLLOUT / POLLERR. UDP wake wire via
  `poll_wake_check_and_clear` from `udp_socket_deliver_dgram`. TCP
  RX wake wire deferred.
- `R_SOCKET_READ` / `WRITE` / `LISTEN` / `CONNECT` rights bits.
  `sock_cap_check_rights` helper threaded through every socket
  handler. Default mint updated from 0x00B to 0x00F.
- Sets up R96 privileged-port gate to selectively DROP bits.

**R95 debt at close:** 6 deferred items (TCP RX wake wire; timer
poll timeout; sys_socket privileged-port refinement; POLLNVAL;
SO_ERROR async population; multi-caller poll).

### R96 -- Hardening pass: MAC-spoof + IOMMU + priv-port (2026-09-01)

- `design/networking/mac-spoof-policy.md`: hard-refuse-in-driver
  (option A). Grounded in "no in-tree consumer trusts a frame's
  source MAC for authentication".
- Audit finding: `l2_tx_send`'s six-arg signature has no `src_mac`
  argument -- the property is structural. Witness `r96_mac_spoof_
  refuse.pdx` reads the emitted frame back out of the TX buffer pool
  at bytes [6..11] and asserts they equal `_e1000e_devices+24`.
- `design/networking/iommu-audit.md`: walked all three drivers.
  Finding: none currently perform bus-master DMA through a VT-d
  domain. `KIND_DMA_DOMAIN` already exists at 0x142 from R29; the
  wire-up round consumes it (deferred).
- `design/networking/filter-chain.md`: `KIND_PACKET_FILTER` ordinal
  ratification at 0x1A9 (already reserved from R91 wave). No
  implementation.
- `R_NET_PRIVILEGED_PORT = 0x010` rights bit. `sys_bind` refuses
  `-EACCES` on `local_port < 1024` without the bit. Default mint
  does NOT grant it.

**R96 debt at close:** 3 audit items each deferred to their own
follow-up round (VT-d wire-up; `KIND_PACKET_FILTER` implementation;
elevation-broker hookup for the priv-port bit).

### R97 -- TLS placement decision + KIND_TLS_CONN reservation (2026-09-01)

- `design/networking/tls-placement-decision.md`: ratifies NET-D6
  (2026-06-17). Two independent lines of reasoning: (a) architecture
  -- `stack.md` §8 explicitly rejects kTLS-style integration on
  key-isolation grounds; (b) crypto substrate -- paideia-as has no
  ECDSA-P256 or RSA-2048 verify intrinsic today, so building
  in-kernel TLS would compound "first real-NIC verification" and
  "adopt classical crypto" in the same wave.
- `KIND_TLS_CONN` reserved at ordinal 0x1AA (already recorded from
  R91 wave, not a fresh mint).
- Socket-surface sufficiency audit: `MSG_PEEK` and partial-write
  handling both found sufficient for a user-space TLS library.
- Cross-repo escalation: one paideia-as issue filed for
  ECDSA-P256 sign+verify intrinsic (non-blocking).

**R97 debt at close:** No `KIND_TLS_CONN` implementation. No
`net/tls_*.pdx`. No paideia-as submodule bump (main-scope).

### R98 -- net-tools smoke lane consolidation (2026-09-02)

- `boot_net_smoke` composite mode in `tools/run-smoke.sh`. Runs
  `boot_r91_nic` (NEW mode; retires R91.M6 deferred item #8) +
  `boot_r93_udp_dns` + `boot_r94_tcp_offbox` in sequence.
- `PAIDEIA_NET_SMOKE=1` opt-in gate on all three lane members.
  Follows the `PAIDEIA_R72_TCP=1` precedent.
- `tools/net-smoke-httpd.sh`: minimal single-shot TCP responder
  (python3 preferred, nc fallback). Configurable via `PORT` /
  `PAYLOAD` / `MODE` / `HANG` env vars. `MODE=http` supports future
  R100+ pdxcurl-shaped smokes.
- `tests/expected-r94-tcp-offbox.golden` tightened from the
  permissive substring `boot r94 offbox` to the strict two-line ok
  pair pinning `bytes=4` (matches responder default `PAYLOAD=PONG`).
- `tools/run-qemu.sh --help` prints the consolidated env-var summary
  (PAIDEIA_NIC / PAIDEIA_HOSTFWD / PAIDEIA_NET_SMOKE) with a pointer
  to the full catalogue.
- `design/networking/qemu-net-invocation.md`: env-var interface,
  full invocation example, SLIRP addressing envelope, host
  prerequisites, per-lane-member proof table.

## What the wave DID NOT ship

- **IPv6.** Deferred through R99 per
  `design/networking/ipv6-deferral.md`. Every witness, socket-row
  layout, DHCP client, DNS resolver, and TCP TCB is IPv4-only.
- **In-kernel TLS.** Formalised as out-of-scope in R97.
- **KIND_PACKET_FILTER implementation.** R96 reserved the ordinal;
  no filter chain runs today.
- **VT-d domain wire-up for NIC DMA.** R96 audit found the wire-up
  unbuilt; substrate ready.
- **TCP RX wake wire for sys_poll.** R95 shipped UDP wake only; TCP
  RX poll on empty ring falls through to a timeout the timer wheel
  doesn't yet honour.
- **Timer-driven sys_poll timeout.** No timer-wheel abstraction in
  the tree at wave close.
- **Multi-NIC.** Single-active-NIC MVP.
- **Elevation-broker hookup for R_NET_PRIVILEGED_PORT.** R96 lands
  the bit; the natural mint-time gate at R48 `svc.elevate-broker` is
  cross-cutting and deferred.
- **Multi-caller sys_poll.** Single-entry `_poll_waiter_tcb` slot.
- **User-space server processes for TCP / DNS / DHCP.** All three
  live in the kernel today; a userspace `net-stack` server split is
  the natural Phase-2 landing.

## Debt inventory at wave close (union of every round's deferred list)

| # | Debt item | First flagged | Retire trigger |
|---|-----------|---------------|-----------------|
| 1 | TX completion reap on virtio + rtl8139 | R91.M6 | driver-cleanup follow-up |
| 2 | virtio MSI-X path | R91.M6 | shared MSI-X primitive round |
| 3 | PCI Command-register BME enable | R91.M6 | same |
| 4 | rtl8139 ERTXTH tuning | R91.M6 | T14 G4 real-hardware optimisation |
| 5 | Unbounded RX loop guard on virtio + rtl8139 | R91.M6 | driver-cleanup follow-up |
| 6 | Live STATUS.LU / LINKB link poll on e1000e + rtl8139 | R91.M6 | driver-scope link-change watcher |
| 7 | rtl8139 IDT vector wiring | R91.M6 | same round as virtio MSI-X |
| 8 | ~~boot_r91_nic smoke mode~~ RETIRED R98.M1-001 | R91.M6 | -- |
| 9 | TSC calibration primitive | R92.M4 | `design/kernel/tsc-cal.md` (not yet written) |
| 10 | RFC 5227 randomisation for ARP probe/announce | R92.M4 | secure entropy landing |
| 11 | Route table growth to N routes | R92.M4 | Phase-2 substrate |
| 12 | DNS full-cache upgrade | R93.M4 | second caller / ring-3 resolver |
| 13 | TCP RX wake wire for sys_poll | R95.M3 | R94/R95 hardening follow-up |
| 14 | Timer-driven sys_poll timeout | R95.M3 | `sched_wake_after_ns` primitive |
| 15 | POLLNVAL for bad-fd poll | R95.M3 | poll-hardening follow-up |
| 16 | SO_ERROR async population | R95.M3 | R94/R95 TCP-side hardening pass |
| 17 | Multi-caller sys_poll | R95.M3 | poll-hardening follow-up |
| 18 | KIND_DMA_DOMAIN wire-up for NIC rings | R96.M2 | dedicated VT-d wire-up round |
| 19 | KIND_PACKET_FILTER implementation | R96.M3 | first consumer landing |
| 20 | Elevation-broker hookup for R_NET_PRIVILEGED_PORT | R96.M4 | R48-adjacent |
| 21 | KIND_TLS_CONN implementation | R97.M2 | classical bridge in paideia-as + net-stack posture decision |
| 22 | paideia-as ECDSA-P256 sign+verify | R97.M4 | paideia-as-side |
| 23 | paideia-as submodule bump (v0.24.0 -> v0.27.0+) | R97.M4 | main-scope |
| 24 | `.githooks/pre-push` gate for `PAIDEIA_NET_SMOKE=1` | R98.M4 | run of consecutive clean lane passes |
| 25 | Tighten `boot_r92_icmp` golden to require ok line | R98.M4 | after R93 DHCP proves ok path reliably |
| 26 | `MODE=http` consumer -- pdxcurl-shaped smoke | R98.M4 | R100 wave |

## Next-wave pointer

Two mutually independent tracks are ready to open after the R91-R98
wave. The user's directive for the "networking wave" is complete; the
next wave decision is up to main, but the two natural continuations
are:

### Track A: IPv6 substrate (deferred through R99 by design)

`design/networking/ipv6-deferral.md` names what a v6 landing must
add: `net/ipv6.pdx` (ULA scope, link-local); ND (RFC 4861) replacing
ARP; SLAAC (RFC 4862) or DHCPv6-PD; ICMPv6 with the required message
types; extended socket API (`AF_INET6`, `sockaddr_in6`, `getaddrinfo`
covering both families). Cost estimate: comparable to R91-R94
together -- roughly 4 rounds' work at the R91-R98 tempo (one round
each for the wire substrate, ND, SLAAC/DHCPv6, and dual-stack socket
API). Prerequisite: none from the R91-R98 wave; every substrate the
wave lands generalises cleanly.

### Track B: Phase-2 net-stack server migration

Move the kernel-resident DHCP / DNS / TCP / UDP code into a
user-space `svc.net-stack` server, exposed via the R20b userspace-
server substrate (`design/ipc/userspace-server-substrate.md`). The
socket capability API (R95) stays kernel-side as the thin
"userspace TLS terminates against a socket cap" boundary; every
protocol implementation moves to ring 3. Cost estimate:
substantially larger than Track A -- touches every module the
wave landed, plus the R20b RPC surface, plus a redesign of the
route table's storage authority (single-writer server vs.
kernel-side static). Prerequisite: R95 poll + socket API polish
(landed); TCP RX wake wire (deferred item #13) -- must be retired
first, otherwise a ring-3 net-stack server has no way to wake on
TCP arrival without busy-polling.

**Recommended ordering:** Track B first (retires debt items #13,
#14, #17 as byproducts of the migration; enables a real
`KIND_PACKET_FILTER` consumer per debt item #19), then Track A
against the ring-3 server (v6 lands as a per-family branch in the
already-userland stack, not as a second kernel-side codebase).

Deferring both is also a defensible option -- the wave's landed
substrate is production-shaped for IPv4-only paideia workloads,
and every debt item in the table above has a clear retire trigger
so nothing is silently rotting.

## Wave-level metrics

- **Rounds:** 8.
- **Issues:** 96.
- **New `.pdx` modules landed:** ~35 (nic_dispatch, three driver
  directories, route_table, dhcp, dns, r91_nic_probe witness,
  r92_route_table + r92_arp_pending + r92_icmp_ping witnesses,
  r93_udp_dns witness, r94_substrate + r94_tcp_offbox witnesses,
  r95_poll witness, r96_mac_spoof_refuse witness, sys_setsockopt +
  sys_getsockopt + sys_getpeername + sys_getsockname + sys_poll +
  sys_sendto + sys_recvfrom handlers).
- **New design docs:** 6 (`mac-spoof-policy.md`, `iommu-audit.md`,
  `filter-chain.md`, `tls-placement-decision.md`, `ipv6-deferral.md`,
  `qemu-net-invocation.md`).
- **New retrospectives:** 9 (r91..r98-closed.md + this wave close).
- **New sysnos materialised:** 7 (96 sendto, 97 recvfrom, 98
  getsockopt, 99 setsockopt, 100 getpeername, 101 getsockname, 102
  poll).
- **New KIND_* ordinals reserved:** 3 (KIND_NIC 0x1AD active;
  KIND_TLS_CONN 0x1AA reserved; KIND_PACKET_FILTER 0x1A9 reserved).
  KIND_DMA_DOMAIN 0x142 (R29) confirmed as the wire-up ordinal.
- **New env vars:** 3 (PAIDEIA_NIC, PAIDEIA_HOSTFWD,
  PAIDEIA_NET_SMOKE).
- **Cross-repo escalations to paideia-as:** 1 (ECDSA-P256).

## References

- `design/networking/r91-plan.md` -- the wave plan.
- `design/round-retrospectives/r91-closed.md` .. `r98-closed.md` --
  per-round dispositions.
- `design/networking/qemu-net-invocation.md` -- QEMU networking
  invocation catalogue (R98.M3-002).
- `design/networking/ipv6-deferral.md` -- Track A gating doc.
- `design/ipc/userspace-server-substrate.md` -- Track B foundation.
- `design/network/stack.md` §8 NET-D6 -- TLS placement anchor.
- `design/library-status.md` -- paideia-as crypto state for the
  Track B / TLS-consumer trigger.
