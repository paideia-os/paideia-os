# R93 Closure Retrospective

**Wave:** R93 -- DHCP client + UDP socket integration + DNS resolver stub + boot witness.
**Issues:** #2043..#2059 (17 total).
**Landed:** paideia-os 2026-09-02.

## Scope shipped

### M1 -- DHCP client (6 issues: #2043..#2048)

`src/kernel/core/net/dhcp.pdx` (new). Single-shot RFC 2131 DISCOVER/OFFER/REQUEST/ACK
handshake with fixed sentinel xid (0x50414944), minimal option set (53 msg-type,
50 requested-IP, 54 server-id, 51 lease-time, 1 subnet-mask, 3 router, 6 DNS,
55 param-req-list, 255 END), bounded 8M-iter poll budget. On success: writes
lease into `route_table_set` for all four fields (MY_IP, GW_IP, NETMASK, DNS_IP)
and calls `arp_announce_on_lease_acquired` to publish the new binding. On
timeout: emits `boot r93 dhcp timeout fallback static` and returns cleanly with
R27 defaults kept in place. Silent skip when PAIDEIA_NIC=none.

Route table extended with `RT_FIELD_DNS_IP` (field id 4) and a `_ipv4_dns_ip`
mutable .bss slot (`src/kernel/core/net/route_table.pdx`). `rt_init` seeds
dns_ip = 0.0.0.0 so a `dns_resolve` invoked before DHCP settles refuses
cleanly rather than reading uninit bytes.

### M2 -- UDP socket integration (5 issues: #2049..#2053)

`KIND_UDP_SOCKET=0x1A8` was already landed by R100-PREP-002 (#2008); this wave
retires the pre-R30-numbering-scheme `UdpSocketCap.KIND_UDP_SOCKET=0x50`
posture as documented dead weight (see `src/kernel/core/cap/udp_socket_cap.pdx`
deprecation banner). Added `udp_socket_resolve` thin alias over
`tcp_socket_resolve` (which is generic in its `want_kind` arg) in
`src/kernel/core/net/udp_socket.pdx`.

Rewrote `udp_rx_handle` (`src/kernel/core/net/udp.pdx`) to dispatch by
destination port: `udp_socket_find_by_local_port` -> `udp_socket_deliver_dgram`.
The R27.M6 port-7-hardcoded echo path is retired; a bind on port 7 now claims
the port like any other socket. The `_udp_tx_scratch`, `_udp_rx_echoed`
counters stay as dead .bss (retention rather than removal to keep the diff
focused on the dispatch change).

Wire path in `udp_socket_send_body` for off-box (peer_ip != my_ip): now
builds a UDP header at `_udp_tx_scratch` and calls `ipv4_tx_send` with
proto=17; the previous "return fake success" stub is replaced.
`udp_socket_recv_body`'s state gate now accepts BOUND as well as CONNECTED
(a bound-not-connected socket can receive from any peer -- classic UDP; this
is what DHCP and DNS need).

New syscalls: `sys_sendto` (SC+ ID 96, `src/kernel/core/syscall/handlers/sys_sendto.pdx`)
and `sys_recvfrom` (SC+ ID 97, `src/kernel/core/syscall/handlers/sys_recvfrom.pdx`).
Both dispatch by cap kind: TCP arm mirrors `sys_send`/`sys_recv`; UDP arm uses
temporary row-mutation (peer_ip/peer_port stamped for the send, restored after)
to honor sendto's "different peer per call" contract without changing
`udp_socket_send_body`'s CONNECTED-state gate. Wire-in via
`src/kernel/core/syscall/dispatch.pdx` at sysnos 96/97 (bounds check already
covered 96/97 under the 107 cap, no widening required).

`sys_bind` already handled `KIND_UDP_SOCKET` (delegated to
`udp_socket_bind_body`) from R100-PREP-002; no additional change.

### M3 -- DNS resolver stub (4 issues: #2054..#2057)

`src/kernel/core/net/dns.pdx` (new). Minimal RFC 1035 §4: 12-byte header +
QNAME encoding (labels + terminator) + QTYPE=1 QCLASS=1. `dns_resolve` uses
a fresh connected UDP socket bound to port 53001 -> `dns_ip:53`. Poll for
reply, 8M-iter budget per attempt, 2 attempts (one retry), no cache.
Parser refuses NXDOMAIN (RCODE != 0), TRUNCATED (TC bit set), wrong txid,
QDCOUNT != 1, ANCOUNT == 0, malformed labels/pointers -- all return 0.
Accepts one-hop compression pointer in NAME per RFC 1035 §4.1.4.

Design note `design/network/dns-stub-vs-cache.md` (new) documents the split
between this stub and `dns-cache.md`'s target full-resolver design, and the
trigger conditions for upgrading (a second caller, ring-3 daemon consumers,
DNSSEC/DoT/DoH, NXDOMAIN discrimination).

### M4 -- witness + retro (2 issues: #2058, #2059)

`src/kernel/boot/witness/r93_udp_dns.pdx` (new). Post-DHCP witness: resolves
"example.com" against the DHCP-installed DNS server (10.0.2.3 under QEMU
SLIRP). Emits `boot r93 dns resolve ok --` with 4 ip-byte KVs on success.
Silent skip on no-NIC, no-DHCP-lease, or resolver refusal. Wired into
`kernel_main.pdx` after `witness_r92_icmp_ping`.

Smoke mode `boot_r93_udp_dns` added to `tools/run-smoke.sh` with 20s timeout;
golden `tests/expected-r93-udp-dns.golden` pins both fingerprints
(contains-in-order match). Klog tags added to `src/kernel/core/klog/keys.pdx`:
`tag_boot_r93_dhcp_lease_ok`, `tag_boot_r93_dhcp_timeout_static`,
`tag_boot_r93_dns_resolve_ok`, plus per-byte keys `k_ip_b0..k_ip_b3`.

## Side benefit: #2218 closed

R92's ICMP-ping witness (`witness_r92_icmp_ping`) was previously unreachable
under `PAIDEIA_NIC=virtio` because `rt_init` seeded `my_ip=10.0.0.2` while
QEMU SLIRP places the guest on `10.0.2.0/24`; `ipv4_tx_send`'s same-/24 subnet
gate would then route the ICMP request via the (unreachable) 10.0.0.1 gateway
rather than through SLIRP's real 10.0.2.2 gateway. The R92 retrospective
flagged this as follow-up issue #2218.

This wave's DHCP client runs BEFORE `witness_r92_icmp_ping` in kernel_main
(see the R93.M1-005 hook site). Under `PAIDEIA_NIC=virtio` the DHCP client
installs SLIRP's `10.0.2.15 / 10.0.2.2 / 255.255.255.0` lease before the
R92 witnesses observe the route table, so the same-/24 subnet gate now
correctly treats 10.0.2.2 as on-link. The R92 ICMP-ping witness succeeds on
first run without any per-witness workaround. Issue #2218 is resolved as a
side effect of R93.M1-005; the R92.M3-001 ICMP-ping witness now emits
`boot r92 icmp ping ok -- rtt_us=<n>` on the SLIRP default rather than the
former `boot r92 icmp skip -- reason=2` (no-link).

## Encoder-gap posture

`paideia-as` at v0.24.x continues to enforce:
- G1: byte / word stores route via `mov_b` / `mov_w`.
- G4: zero-extend byte loads use `xor+mov_b`, never `mov_bzx`.
- G6: `[reg+imm]` addressing only; no SIB `[base+index]`.

All R93 landings observe these. In `dhcp_parse_reply` and `dns_skip_name`
the cursor + base is computed in a scratch register (`mov r8, base; add r8,
cursor`) before every byte load to stay within [reg+imm]. No `no_frame`
attributes; all bodies rely on paideia-as #1606's implicit frame prologue.

No new paideia-as encoder gaps were hit during this landing.

## Spec ambiguities resolved

1. **DHCP MAC source under multi-NIC.** `arp_send_request` / `arp_reply` /
   `l2_tx_send.eth_build` all read the Ethernet source MAC from
   `_e1000e_devices+24` unconditionally, even when the active NIC is virtio
   or rtl8139. `dhcp_build_and_send` follows the same posture so the DHCP
   chaddr matches what the server observes at Ethernet layer -- the lease
   keys correctly regardless of NIC substrate. A future landing that
   introduces per-NIC MAC storage in a routed accessor will fix both
   consumers together.

2. **UDP bound-not-connected recv.** The R100-PREP-002 landing of
   `udp_socket_recv_body` gated on `state == CONNECTED`. That gate blocks
   the DHCP client (which binds port 68 but has no peer to connect() to
   before DISCOVER lands an OFFER). R93.M2-004 relaxes the gate to `state
   != CLOSED`, matching classic UDP semantics where a bound socket can
   receive from any peer. The R100-PREP-002 witness that exercised the
   CONNECTED-only path continues to work (its socket is still CONNECTED
   pre-recv).

3. **sendto per-call peer under connected socket.** Linux returns
   `-EISCONN` when sendto's dst mismatches the connected peer. This MVP
   temporarily rewrites the socket row's peer_ip / peer_port with the
   caller's dst, sends, then restores -- no EISCONN refusal. Consequence:
   a caller can sendto() with different peers on the same socket, matching
   the actual behaviour a DNS resolver or DHCP relay needs. Documented in
   sys_sendto.pdx's file header.

4. **sys_recvfrom source-address reporting.** The `_udp_socket_table` row
   layout has no per-datagram-slot src_ip/src_port fields today. As an
   MVP approximation, `sys_recvfrom` reports the socket's stored
   peer_ip/peer_port (correct for a connected socket, WRONG for a bound
   socket receiving from multiple peers). A future landing that widens
   `_udp_rx_dgram_lens[16][4]` to `[16][4][12]` (len + src_ip[4] +
   src_port[4]) fixes this structurally.

## Follow-ups (out of scope for R93)

- DHCP lease renewal (T1/T2 timers, RENEW/REBIND state machine).
- Per-datagram src_ip / src_port tracking in UDP socket rings (see spec
  ambiguity #4).
- Multi-NIC MAC source in TX build path (see spec ambiguity #1).
- DNS professionalization per `dns-cache.md` (see
  `design/network/dns-stub-vs-cache.md` for the trigger conditions).
- Kernel RNG so DHCP xid and DNS txid can be truly random instead of
  fixed sentinels.
- `sys_close` for UDP sockets.
- Real DHCP INFORM support (client-configured IP, DNS lookup only).

## Files changed / created

Created:
- `src/kernel/core/net/dhcp.pdx`
- `src/kernel/core/net/dns.pdx`
- `src/kernel/core/syscall/handlers/sys_sendto.pdx`
- `src/kernel/core/syscall/handlers/sys_recvfrom.pdx`
- `src/kernel/boot/witness/r93_udp_dns.pdx`
- `tests/expected-r93-udp-dns.golden`
- `design/network/dns-stub-vs-cache.md`
- `design/round-retrospectives/r93-closure.md`
- `tools/verify-udp-socket-kind-superseded.sh`

Modified:
- `src/kernel/core/net/route_table.pdx` (RT_FIELD_DNS_IP + _ipv4_dns_ip)
- `src/kernel/core/net/udp.pdx` (per-port dispatch rewrite)
- `src/kernel/core/net/udp_socket.pdx` (udp_socket_resolve + wire send + BOUND-recv)
- `src/kernel/core/klog/keys.pdx` (5 tags + 4 keys)
- `src/kernel/core/syscall/dispatch.pdx` (sysno 96/97 shims)
- `src/kernel/boot/kernel_main.pdx` (dhcp_acquire + witness_r93_udp_dns)
- `tools/run-smoke.sh` (boot_r93_udp_dns mode)
- `design/user/syscall-table.md` (mark sysnos 96/97 as landed)

## Sysnos consumed

- 96 (`sendto`) -- R93.M2-004.
- 97 (`recvfrom`) -- R93.M2-004.

## Klog fingerprints emitted

- `boot r93 dhcp lease ok --` (26 bytes NUL-incl) with 4 KV pairs
  `ip_b0`, `ip_b1`, `ip_b2`, `ip_b3` (6 bytes each).
- `boot r93 dhcp timeout fallback static` (38 bytes NUL-incl), no KVs.
- `boot r93 dns resolve ok --` (27 bytes NUL-incl) with 4 KV pairs
  `ip_b0..ip_b3`.

All three lines are lowercase with no standalone uppercase OK token, so
`tools/verify-fingerprint-coverage.sh`'s OK_TOK gate does not require an
allowlist entry.
