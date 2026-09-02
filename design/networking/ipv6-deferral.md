# IPv6 Deferral (R92.M4-001)

**Date:** 2026-09-01
**Status:** Ratified — IPv6 is OUT OF SCOPE for rounds R92 through R99.
**Owner:** osarch
**Companion:** `design/network/ipv4-only-policy.md`,
`design/network/stack.md` §NET-D3, `design/networking/r91-plan.md` §0.1.

## Decision

The kernel-native networking stack stays **IPv4-only** through R99. No
dual-stack ARP+NDP, no IPv6 address configuration, no `KIND_IPV6_*`
capabilities, no IPv6 socket-syscall surface, no `AF_INET6` handling
anywhere in this repository at this landing.

The stack.md long-term commitment to IPv6-native operation (NET-D3)
survives — it moves to a follow-up round-family that lands AFTER
R91–R99's IPv4 path is proven end-to-end against real hardware.

## Rationale

Three reinforcing reasons.

### 1. Test surface is IPv4-only

Every bring-up and verification path this project has is a QEMU
`-netdev user` boot. QEMU SLIRP is an IPv4-only NAT — it does not
speak IPv6 to the guest. So even if we landed a full dual-stack today,
there would be no assertable off-box verification for the v6 path
until the tooling grows a v6-capable backend (`-netdev bridge` on a
v6-configured host, or a `-netdev tap` with a userspace DHCPv6/RA
server). Neither exists in `tools/run-qemu.sh` today, and adding one
is not in R92's scope.

### 2. libpdx-net client stack is IPv4-only

The sibling `libpdx-net` user-space stack (curl-like tool + resolver +
socket wrapper) is designed and being built to the IPv4 syscall
surface (bind/listen/accept/connect/send/recv, sockaddr_in). Its
Phase-1 MVP names only `AF_INET`. Extending the kernel now to `AF_INET6`
would land a syscall surface with no consumer, and by the time
libpdx-net grows a v6 client the kernel surface would be waiting for
whatever wire-format shape that library committed to — the wrong end
to fix the ABI from.

### 3. Simultaneous-change risk

R92–R99 is the first time ANY of the R27 IPv4/ICMP/UDP/TCP protocol
code runs against a live NIC ring in a real QEMU boot. Dual-stacking
onto that same wave means every discovered bug has to be triaged
across two protocol families, and every fix touches paths that share
no state (v6 has its own NDP, DAD, RA, MLD; the L2 dispatch is
different — ethertype 0x86DD; the sockaddr layout is different).
Landing v6 alongside v4 in the same wave doubles the diagnosis surface
for negligible product gain during a period when the v4 stack is still
finding real-hardware bugs. The `ipv4-only-policy.md` V4-D2 posture
("IPv4-only is a normal, audited, non-alarming operational mode") is
exactly the guarantee the R92 witnesses need to be able to run — a
"you MUST have IPv6" boot policy would break the R92 witness cascade
on the SLIRP surface it targets.

## What this defers explicitly

* **`AF_INET6` sockets** — no `KIND_TCP6_SOCKET` / `KIND_UDP6_SOCKET`
  capabilities, no v6 sockaddr in bind/listen/accept/connect.
* **IPv6 header parse / build** — no `net/ipv6.pdx` module.
* **NDP (Neighbor Discovery Protocol)** — the v6 analog of ARP,
  covering neighbor solicitation, DAD (RFC 4862), Router Solicitation,
  Router Advertisement, MLD reports. All deferred.
* **DHCPv6 / SLAAC** — v6 address configuration. R93's DHCP client is
  DHCPv4-only.
* **v6-aware routing** — the R92 route table `_ipv4_my_ip` /
  `_ipv4_gw_ip` symbols and `route_table_set / _get` field ids are
  v4-only (RT_FIELD_MY_IP, RT_FIELD_GW_IP name IPv4 addresses,
  netmask is /24-shape not /64-shape).
* **v6 firewall / packet-filter rules** — filter-chain.md's chain
  semantics stay IPv4-only in the current substrate.

## What this does NOT defer

* Physical-link agnosticism. The R91 NIC dispatch layer
  (`nic_dispatch.pdx`) does not care about L3 payload; the v4-only
  posture is layered above L2. A future v6 landing adds an
  `ipv4_or_ipv6` dispatch above `l2_rx_handle`'s ethertype selector
  without touching NIC drivers.
* The `_ipv4_*` symbol prefix in the route table. R92 chose the prefix
  deliberately: when a v6 landing arrives, it adds `_ipv6_my_ip` etc.
  under the same route-table module rather than reusing the v4 slots.
  The current names document the fact that v4-only is the state, not
  that v6 support has been erased.

## Where to look when v6 lands

The follow-up round-family that lands v6 must, at minimum:

1. Add `net/ipv6.pdx` alongside `net/ipv4.pdx` (parse/build/checksum,
   RX/TX engines mirroring the v4 shape).
2. Add `net/ndp.pdx` alongside `net/arp.pdx` (neighbor cache with
   same lookup/expiry discipline; ICMPv6 embed for NS/NA/RS/RA).
3. Add `_ipv6_my_ip`, `_ipv6_gw_ip`, `_ipv6_prefix_len`, `_ipv6_dns_ip`
   to `net/route_table.pdx` as new `pub let mut` fields with new
   `RT_FIELD_*` ids.
4. Land v6 socket kinds `KIND_TCP6_SOCKET` / `KIND_UDP6_SOCKET` with
   the same rights-bit taxonomy as their v4 siblings.
5. Extend the boot witnesses that speak on-wire (R92 ICMP-ping,
   R93 DHCP, R93 DNS, R94 TCP off-box) to run both stacks in
   parallel or gated by an env switch.
6. Update `run-qemu.sh` for a v6-capable QEMU network backend.
7. Update `design/network/ipv4-only-policy.md` to document that the
   v4-only mode is now an operator-chosen operational stance rather
   than a default.

## References

* `design/network/stack.md` §NET-D3 — long-term IPv6-native
  commitment (dated 2026-06-17).
* `design/network/ipv4-only-policy.md` — audit-not-alarm posture for
  v4-only operation.
* `design/networking/r91-plan.md` §0.1 — this deferral's origin.
* `design/round-retrospectives/r92-closed.md` — R92 milestone
  disposition where this doc lands as R92.M4-001.
