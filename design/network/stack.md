# PaideiaOS — Network Stack

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Architectural specification of the PaideiaOS network stack: a single network-stack server internally layered by algebraic-effect handlers (L2/L3/L4); zero-copy packet transport via memory capabilities; Q10's poll-mode-reserved-core + IRQ-driven hybrid; TCP / UDP / QUIC as first-class peers; IPv6 + IPv4 dual stack; separate TLS, DNS, NTS services consuming typed transport channels; capability-typed packet filtering; integration with the NIC driver model.

**Hard inputs (do not relitigate):**
- `design/00-feature-inventory.md` — E7 (networking stack), E9 (TLS 1.3 + hybrid PQ handshake), E15 (NTS time sync), E18 (DNS resolver); U9 (virtualization VT-x — affects vhost-user paths in phase 3+).
- `design/01-foundational-decisions.md` — Q10 (poll-mode reserved core when ≥ N cores; IRQ otherwise), Q6 (universal hybrid KEM = X25519 + ML-KEM-1024 — relevant to TLS), Q15 (max mitigations default), Q13 (typed records).
- `design/02-development-environment.md` — QEMU `-netdev` topologies for testing; CI lanes include cross-VM L2 hops (§2.11 of dev-env).
- `design/toolchain/custom-assembler.md` — algebraic effects (Q-A3), functor modules (Q-A7), substructural lattice.
- `design/ipc/wait-free-dataflow.md` — session-typed channels are the transport for application↔stack and TLS↔transport interactions.
- `design/capabilities/linearity-and-tags.md` — memory cap transport; derived kinds.
- `design/kernel/memory-model.md` — `IpcSlotRingCap`-equivalent for NIC ring buffers; hugepages; per-NUMA pools.
- `design/kernel/scheduler.md` — `reserved_core_cap` for the poll-mode core (Q10's mechanism); SC donation.
- `design/security/pq-trust-root.md` — universal hybrid KEM (§7 of PQ doc) defines the TLS / VPN handshake construction; algorithm catalog tracks scheme versions.
- `design/drivers/framework.md` — NIC drivers expose `Channel(NetIfSchema)`; the network stack server consumes these.

---

## 0. Decisions summary

### 0.1 Inherited (already binding)

| Source | Constraint |
|---|---|
| Q10 | Poll-mode networking on a reserved core when total core count ≥ N (default N=8); IRQ-driven otherwise. |
| Q6 (PQ) | Every confidentiality boundary uses hybrid X25519 + ML-KEM-1024; TLS handshakes follow draft-ietf-tls-hybrid-design successor. |
| Pillar 7 (network) | Forward-looking, RFC-compliant, robust OSI stack. |
| Pillar 5 (no legacy) | Drop POSIX/legacy idioms unless they are demonstrably the best design. TCP, UDP, IP are not "legacy" — they're forward-looking when correctly implemented. |
| Pillar 3 (microkernel) | The stack is a userspace server. Internal layering via effects, *not* via multiple processes (per §0.3). |
| IPC primitive | Applications consume the stack via session-typed channels; the slot-cap economy provides backpressure. |
| Drivers framework | NIC drivers provide `Channel(NetIfSchema)` upward. The stack consumes these as its L2 input. |

### 0.2 New decisions in this document (all taken without questionnaire)

| # | Choice | Rationale |
|---|---|---|
| NET-D1 | Stack architecture | Single network-stack server (`net-stack`), internally layered via algebraic-effect handlers — L2 effect (frame in/out), L3 effect (packet in/out), L4 effect (segment in/out). Layering is *within* the process via effect dispatch; *not* a process boundary per layer. |
| NET-D2 | L4 protocols | TCP, UDP, and QUIC as first-class peers. No "primary" protocol; consumers choose based on need. |
| NET-D3 | Address families | IPv6 + IPv4 dual stack. IPv6 is the native preference; IPv4 is supported because the world has IPv4. Connection establishment prefers Happy Eyeballs v2 (RFC 8305). |
| NET-D4 | Packet representation | Zero-copy: a packet is a linear `MemCap` to a hugepage-backed buffer. The capability passes through the L2→L3→L4 layers without copying; modifications happen in place under linear discipline. |
| NET-D5 | Poll-mode vs IRQ | Q10 literal implementation: at boot, supervisor evaluates `cores ≥ N`. If yes: mints `reserved_core_cap` to the network-stack server; the stack pins one thread to that core in a poll-mode loop. If no: standard IRQ-driven dispatch. |
| NET-D6 | TLS integration | A separate TLS server process (`tls-server`) consumes typed transport channels from `net-stack`; produces hybrid-KEM-encrypted typed channels for applications. The TLS server holds the operational signing keys per PQ doc §3.1. |
| NET-D7 | DNS resolver | Separate service (`dns-resolver`), consumes UDP and TCP channels from `net-stack`, exposes a typed-record DNS-query schema to applications. |
| NET-D8 | NTS time service | Separate service (`nts-client`), consumes UDP channels, manages the system clock via supervisor-mediated capability. |
| NET-D9 | Routing daemons | Phase 1–2: host-only routing. Routing daemons (BGP, OSPF) are optional userspace processes; they live in `src/userspace/routing/` and consume the L3 routing-table service via a typed channel. |
| NET-D10 | Packet filtering | Capability-typed effect handlers installed in the L3 layer; a firewall rule is a function (or set of functions) registered with the `PacketFilter` effect. The supervisor mints `packet_filter_cap` to authorized administrators. |
| NET-D11 | NIC offloads | TSO, LRO, RSS, checksum offload, MSI-X are used where the NIC driver advertises them; the offload negotiation is part of the `NetIfSchema` handshake. |
| NET-D12 | Buffer management | Hugepage-backed (2 MiB pages) per-NUMA buffer pools; each pool managed via slab allocator over `Page2MCap`s. Each packet buffer is one cache line × N (sized to MTU + headers). |
| NET-D13 | Application API | Two layers: the *foundation* (session-typed channels `Channel(TcpConnectSchema)`, `Channel(QuicConnectSchema)`, etc.); the *ergonomic* (functor-typed library modules `module HttpClient = HttpClient(TlsServer)`). |
| NET-D14 | WireGuard-style overlay | Phase 3+. The PaideiaOS PQ universal KEM (per PQ doc §7) is the natural handshake substrate. Out of phase 1–2 scope; design hooks present in the modular layer architecture. |
| NET-D15 | Multi-NIC / VLAN / bridging | Phase 3+. The L2 layer is structured to accommodate multiple NICs and VLAN-tagged frames; phase 1–2 ships single-NIC + no VLAN. |

### 0.3 Three meta-positions

1. **Layering is by effect handlers, not by process boundaries.** A naive "microkernel" interpretation would say: L2 server, L3 server, L4 server should be separate processes, each communicating via IPC. PaideiaOS rejects this for the dataplane: every packet would pay 3 IPC hops, killing throughput on the wait-free primitive's already-tight budget. Instead, the algebraic-effect handler framework (Q-A3) is *how* layering happens. The L3 effect handler invokes L2 operations as effects; the implementation is intra-process; the protocol boundary is the *type signature*, not the process boundary. This is precisely why effects were chosen over alternatives in Q-A3 — to enable layering without process overhead.

2. **Zero-copy from NIC ring to application.** A NIC's hardware DMA delivers a packet into a hugepage-backed buffer; the buffer's `MemCap` walks up the L2→L3→L4 stack with capability transfer (no copy); the TCP layer assembles segments into the receiver's buffer (one copy at the boundary); the application receives the buffer cap on its session channel. Outbound: application provides a buffer; TCP segments it; IP encapsulates; L2 frames; NIC DMA from the same buffer. The total memory touches per packet is bounded by 2 (one read, one write — or fewer with TSO/LRO).

3. **TCP, UDP, and QUIC are peers, not a hierarchy.** Linux's stack treats TCP as primary, UDP as secondary, QUIC as a userspace overlay. PaideiaOS treats them as three first-class L4 protocols, each a separate session-typed channel kind. Applications choose based on workload (QUIC for HTTP/3 and head-of-line-blocking-sensitive flows; TCP for compatibility; UDP for low-latency stateless).

---

## 1. Architectural overview

```
                 ┌────────────────────────────────────────────────────────────────────┐
                 │                       net-stack (server process)                    │
                 │                                                                      │
                 │  ┌──────────────────────────────────────────────────────────────┐ │
                 │  │ L4 effect handlers (TCP / UDP / QUIC)                         │ │
                 │  │   - connection tables                                          │ │
                 │  │   - congestion control (BBRv3 default)                        │ │
                 │  │   - retransmission (TCP), stream multiplex (QUIC)            │ │
                 │  └────────────┬─────────────────────┬────────────────────────────┘ │
                 │               │                     │                                │
                 │               ▼                     ▼                                │
                 │  ┌──────────────────────────────────────────────────────────────┐ │
                 │  │ L3 effect handlers (IPv6 + IPv4 + ICMP)                       │ │
                 │  │   - routing table                                              │ │
                 │  │   - neighbor cache (NDP / ARP)                                 │ │
                 │  │   - fragmentation (rare; PMTUD usual)                          │ │
                 │  │   - PacketFilter effect dispatch (firewall hooks)             │ │
                 │  └────────────┬─────────────────────────────────────────────────┘ │
                 │               │                                                     │
                 │               ▼                                                     │
                 │  ┌──────────────────────────────────────────────────────────────┐ │
                 │  │ L2 effect handlers (Ethernet, VLAN, bonding [phase 3+])      │ │
                 │  │   - per-NIC ring poll (poll-mode) or IRQ dispatch (IRQ-mode) │ │
                 │  │   - MAC filtering                                              │ │
                 │  │   - NIC offload negotiation                                    │ │
                 │  └────────────┬─────────────────────────────────────────────────┘ │
                 └───────────────┼──────────────────────────────────────────────────┘
                                 │
            ┌────────────────────┼────────────────────┐
            │                    │                    │
            ▼                    ▼                    ▼
   ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
   │ NIC driver   │    │ NIC driver   │    │ NIC driver   │
   │ (Intel igc)  │    │ (Realtek)    │    │ (virtio)     │
   │ Channel(    │    │              │    │              │
   │ NetIfSchema)│    │              │    │              │
   └──────────────┘    └──────────────┘    └──────────────┘

   Application side (via session-typed channels):
   ┌────────────────────────────────────────────────────────────────────────────┐
   │  Applications                                                               │
   │   ┌──────────────────┐  ┌──────────────────┐  ┌─────────────────────────┐ │
   │   │ HTTP client      │  │ DNS resolver     │  │ NTS client             │ │
   │   │ via HttpClient   │  │ (E18)            │  │ (E15)                  │ │
   │   │ ── over TLS ──   │  │ — UDP + TCP —    │  │ — UDP NTP+NTS-KE —     │ │
   │   └──────────┬───────┘  └────────┬─────────┘  └───────────┬─────────────┘ │
   │              │                   │                          │             │
   │              ▼                   │                          │             │
   │   ┌──────────────────┐           │                          │             │
   │   │ tls-server       │           │                          │             │
   │   │ (separate proc)  │           │                          │             │
   │   │ hybrid-KEM       │           │                          │             │
   │   │ X25519+ML-KEM    │           │                          │             │
   │   └──────────┬───────┘           │                          │             │
   │              │                   │                          │             │
   │              └───────────────────┴──────────┬───────────────┘             │
   │                                              │                              │
   │                                              ▼                              │
   │   ┌────────────────────────────────────────────────────────────────────┐ │
   │   │  net-stack: typed transport channels                                │ │
   │   │   - Channel(TcpConnectSchema)  for TCP                              │ │
   │   │   - Channel(UdpDgramSchema)    for UDP                              │ │
   │   │   - Channel(QuicConnectSchema) for QUIC                             │ │
   │   └────────────────────────────────────────────────────────────────────┘ │
   └────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Stack architecture (NET-D1)

### 2.1 The single-process model

`net-stack` is one userspace server holding:
- A NIC capability set: send/recv `Channel(NetIfSchema)` to each NIC driver.
- A scheduler capability: optionally `reserved_core_cap` for the poll-mode thread.
- A buffer pool capability: a memory cap covering its hugepage-backed packet buffers.
- A routing-table capability (for routing daemon clients).
- A neighbor-cache capability.
- An audit channel capability.

### 2.2 Internal layering via effects

The L4, L3, L2 layers are *not* separate processes. They are *effect handlers* installed in the stack's effect environment:

```paideia-as
effect L2 {
  op frame_in   : (port: NetIfId, frame: FrameCap) -> unit
  op frame_out  : (port: NetIfId, frame: FrameCap) -> unit
  op offload_query : (port: NetIfId) -> OffloadSet
}

effect L3 {
  op packet_in  : (port: NetIfId, packet: PacketCap, encap: L2Encap) -> unit
  op packet_out : (dst: IpAddr, packet: PacketCap) -> Result
  op filter     : (packet: PacketCap, dir: Direction) -> FilterDecision
}

effect L4_TCP {
  op segment_in : (conn: ConnId, segment: SegmentCap, hdr: TcpHeader) -> unit
  op segment_out : (conn: ConnId, segment: SegmentCap) -> Result
  op connect    : (peer: IpAddr, port: u16) -> ConnId
  op accept     : (listener: ListenerId) -> ConnId
  op close      : (conn: ConnId) -> unit
}

effect L4_UDP { ... }
effect L4_QUIC { ... }
```

A frame arriving at the NIC:
1. L2 handler receives `frame_in(port, frame)`.
2. L2 handler decodes the Ethernet header; identifies the L3 protocol (IPv4, IPv6, ARP, etc.).
3. L2 handler invokes the L3 effect: `L3.packet_in(port, frame_payload_cap, encap)`.
4. L3 handler decodes the IP header; identifies the L4 protocol.
5. L3 handler invokes the appropriate L4 effect.
6. L4 handler delivers to the application via its session-typed channel.

Each step is an intra-process effect dispatch (one indirect call, ~2 instructions per the calling convention §8 of the assembler doc). No IPC; no copy.

### 2.3 Why this is pillar-aligned

- **Pillar 3 (microkernel)**: the stack *is* a userspace process; the kernel handles only IRQ delivery and IOMMU isolation.
- **Pillar 7 (network)**: the layering matches the OSI model precisely; each layer's responsibility is explicit; the protocol-typed interfaces are documented in the schemas.
- **Pillar 1 (full ISA)**: the stack uses AVX-512 for checksumming, BLAKE3 for QUIC integrity, vectorized memcpy for the unavoidable copies.
- **Pillar 9 (drivers hierarchical)**: the stack consumes the framework's `NetIfSchema` — no driver-specific code in the stack itself.

### 2.4 Why not separate processes per layer

A process-per-layer architecture would impose 3 IPC hops per packet (App → L4 server → L3 server → L2 server → NIC), each ~100 ns. At 1 Mpps (a modest rate), this is 300 ns × 1M = 300 ms per second per process — meaningful overhead. With the wait-free IPC primitive being already tight on its budget, the math doesn't favor process-per-layer.

The effect-handler architecture provides the *type-level* separation (the `L3` effect's signature is independent of how it's implemented) without the *process-level* overhead. This is exactly why effects were chosen in Q-A3.

---

## 3. Packet representation (NET-D4)

### 3.1 The packet buffer

Each packet lives in a hugepage-backed buffer:
- 2 MiB hugepage (per MEM-Q4) from the NUMA-local pool.
- Sized per MTU + offsets (typical: 4 KiB allocation per packet, with room for L2/L3/L4 headers and TLS overhead).
- Owned by a linear `MemCap` until consumed.

### 3.2 The capability transport

A packet's `MemCap` flows from NIC driver → L2 → L3 → L4 → application:
- NIC driver: hands the cap to the stack as part of `NetIfSchema.RxComplete`.
- L2: consumes the cap; reads the frame header; *re-mints* a child cap pointing to the payload (linearity discipline: the parent is consumed, the child is the new owner).
- L3: same pattern — consumes the L2 cap, re-mints for the L3 payload.
- L4: assembles segments; for TCP, may copy bytes into the receiver's reassembly buffer (one unavoidable copy); for UDP/QUIC, hands the cap directly.
- Application: receives the final cap on its session channel.

Each re-mint is one descriptor write (the child cap's descriptor records the new offset and length, the parent's pointer fixed to the same physical page).

### 3.3 The zero-copy claim

Pure zero-copy is achievable for:
- Forwarded packets (router/firewall: NIC → stack → NIC).
- UDP/QUIC packets where the application reads the buffer in place.
- Outbound TCP segments where the application's buffer becomes the segment buffer.

TCP receive requires one copy at the reassembly boundary (out-of-order segments are buffered separately from in-order delivered data). Modern TCP stacks accept this; the offload (LRO) reduces frequency.

### 3.4 Per-NUMA buffer pools

Each NIC's NUMA affinity dictates which pool its packets come from. Cross-NUMA transmits pay one mapping cost. The buffer pools are typed via `IpcSlotRingCap`-equivalent derived kind for cache discipline.

---

## 4. Poll-mode and IRQ-driven (NET-D5, Q10)

### 4.1 Boot-time decision

At supervisor start, after the scheduler has discovered CPU topology:

```
if total_cpus >= N (default 8):
   mint reserved_core_cap targeting CPU C (typically the highest-numbered P-core)
   pass to net-stack at start
   net-stack enters POLL-MODE
else:
   net-stack enters IRQ-MODE
```

### 4.2 Poll-mode

The reserved-core thread runs an infinite loop:

```paideia-as
fn poll_mode_loop(reserved_cap : ReservedCoreCap) -> unit !{l2, ...} =
  loop {
    for each NIC:
      while NIC.rx_ring.has_packet():
        let packet = NIC.rx_ring.dequeue()
        L2.frame_in(NIC.id, packet)
    for each connection:
      if connection.tx_pending:
        let segments = build_segments(connection)
        for each segment:
          L4_TCP.segment_out(connection.id, segment)
    if no_work_done_in_last_n_ms:
      TPAUSE for the budget configurable period
  }
```

The loop never yields the CPU (it holds `reserved_core_cap`); other threads' SCs are rejected from this CPU.

### 4.3 IRQ-mode

Without `reserved_core_cap`, the stack runs as ordinary userspace threads:
- A per-NIC IRQ handler thread is scheduled on a NIC-IRQ event.
- The handler dispatches a few packets, then yields.
- For backlog beyond a budget, the stack defers to its own worker pool.

This is the standard pattern for smaller systems; latency is ~5–10× higher than poll-mode but acceptable for laptops, single-tenant servers.

### 4.4 Mode transition at runtime

The stack can transition between modes (e.g., a server's workload drops, and the reserved core is released). The supervisor revokes `reserved_core_cap`; the stack catches the revocation, transitions to IRQ-mode; rebinds NIC interrupts. The transition is bounded to ~5 ms.

### 4.5 NIC-side support

NIC drivers expose two paths in `NetIfSchema`:
- `IrqDriven`: the NIC interrupts on packet arrival; the driver wakes the stack.
- `PollDriven`: the stack polls NIC's RX/TX rings directly; the driver does not interrupt.

The stack negotiates the path at NIC enumeration; the choice depends on the stack's mode and the NIC's capabilities.

---

## 5. TCP implementation outline

### 5.1 RFC compliance

PaideiaOS implements TCP per RFC 9293 (the current consolidated TCP specification, 2022 — TODO: verify current revision and any successors). Mandatory features:
- Connection establishment via three-way handshake.
- Reliable, ordered byte stream.
- Flow control (advertised window).
- Congestion control: **BBRv3** as default (per pillar 7's "forward-looking"); CUBIC as a per-connection alternative for compatibility with legacy peers.
- Path MTU Discovery (RFC 4821 / 8201).
- Selective Acknowledgments (RFC 2018).
- Timestamps (RFC 7323).
- Window scaling (RFC 7323).

### 5.2 Modern extensions

- **TCP Fast Open** (RFC 7413) supported.
- **Multipath TCP** (RFC 8684) — phase 3+ (requires multi-NIC coordination).
- **Encrypted ClientHello** (RFC 9460 — TODO: verify) for TLS — supported by TLS server.
- **TCP-AO** (RFC 5925) for BGP sessions when routing daemons request.

### 5.3 What is dropped

- **Urgent pointer** (RFC 793 / 6093 advise against use): supported on receive (RFC compliance), unused on send.
- **TCP timestamps for measurement** (PAWS): used internally.

### 5.4 Connection table

Per-connection state in a B-tree keyed by 4-tuple `(src_ip, src_port, dst_ip, dst_port)`. The table is intra-stack data; not exposed to the IPC primitive. Per-NUMA shards for scalability under load.

### 5.5 Session type

```paideia-as
signature TcpConnectSchema =
  protocol = μX. (↑Send T | ↑Close) . (↓Recv T | ↓Close) . X
  payload_type = bytes
  effects = !{tcp_send, tcp_recv, tcp_close}
```

The application sees a typed channel; the stack handles the wire protocol.

---

## 6. UDP implementation outline

### 6.1 RFC compliance

RFC 768 (foundational); RFC 8085 (UDP usage guidelines).

### 6.2 Features

- Connected and connectionless UDP.
- Source-port randomization for unsolicited sockets.
- Per-AF (IPv4 / IPv6) endpoint binding.

### 6.3 Session type

```paideia-as
signature UdpDgramSchema =
  protocol = μX. (↑Datagram T | ↑Close) . (↓Datagram T | ↓Close) . X
  payload_type = bytes
  effects = !{udp_send, udp_recv, udp_close}
```

### 6.4 No TCP-like guarantees

UDP is best-effort; applications must implement reliability if needed. The stack does *not* simulate TCP semantics under a UDP API.

---

## 7. QUIC implementation outline

### 7.1 RFC compliance

QUIC v1 per RFC 9000 (transport), RFC 9001 (TLS-based handshake), RFC 9002 (recovery and congestion control). QUIC v2 (RFC 9369) where available.

### 7.2 Why QUIC is first-class

- Streams multiplexing without head-of-line blocking.
- Connection migration across address changes.
- 0-RTT resumption.
- Built-in TLS 1.3 (so the universal-KEM hybrid integrates directly).
- HTTP/3 substrate.
- Forward-looking pillar 7.

### 7.3 PaideiaOS QUIC extensions

- **PQ key exchange**: the TLS 1.3 handshake within QUIC uses the universal hybrid X25519 + ML-KEM-1024 (per PQ doc §7). This is the same combiner used everywhere; QUIC inherits the property by virtue of using TLS 1.3.
- **Hybrid signatures for QUIC certificates**: when the QUIC server's certificate is needed, the hybrid Ed25519 + ML-DSA-65 signature scheme applies.

### 7.4 Session type

```paideia-as
signature QuicConnectSchema =
  protocol = (↑OpenStream | ↓StreamFromPeer | ↑Close) . ...
  stream_type = bytes  // per-stream
  effects = !{quic_open_stream, quic_send, quic_recv, quic_close}
```

QUIC's stream multiplexing is naturally a session type with stream-id branching.

### 7.5 Implementation

The QUIC layer is implemented in `net-stack` as an L4 effect handler. It uses:
- The L3 layer's IP datagram delivery (UDP-encapsulated QUIC packets).
- Internal cryptographic primitives (the QUIC stack ships its own AEAD implementations).
- A shared connection table per NUMA shard.

---

## 8. TLS server (NET-D6)

### 8.1 Why a separate process

TLS holds long-term signing keys (per PQ doc §3 release-line / operational tier). Pillar 3 (microkernel) + pillar 6 (security) argue strongly for isolating these keys in their own AS, behind an IOMMU-protected boundary.

### 8.2 Architecture

```
   Application                tls-server                  net-stack
       │                         │                            │
       │ — open_tls(peer) ──────►│                            │
       │                         │ — open_tcp(peer) ─────────►│
       │                         │◄──── TcpConnect ───────────│
       │                         │ — TLS hybrid-KEM handshake ─────► (with peer over TCP)
       │                         │                            │
       │◄──── EncryptedChannel ──│                            │
       │                         │                            │
       │ — send(plaintext) ─────►│                            │
       │                         │ encrypt with AES-256-GCM   │
       │                         │ — tcp_send(ciphertext) ───►│
       │                         │                            │
```

The TLS server:
- Consumes a `Channel(TcpConnectSchema)` from `net-stack` per active session.
- Performs the hybrid-KEM handshake.
- Encrypts/decrypts application data.
- Provides the application with a typed `Channel(EncryptedSchema)`.

### 8.3 Why not in-stack (kTLS-style)

In Linux, kTLS embeds TLS into the kernel for zero-copy + DMA-offload. PaideiaOS doesn't: the TLS server is separate. The cost:
- One extra IPC hop per encrypt/decrypt.
- ~1 µs latency added.

The benefits:
- Long-term keys never touch `net-stack`'s AS (a `net-stack` CVE doesn't leak keys).
- TLS server can be updated independently.
- Multiple TLS implementations can coexist (e.g., a "high-throughput TLS" server and a "constant-time-paranoid TLS" server).

### 8.4 NIC TLS offload

When the NIC supports TLS offload (Intel E810, modern Mellanox), the TLS server can negotiate per-connection offload: the NIC encrypts and DMA's the ciphertext from the application's buffer. This recovers some kTLS performance without sacrificing the architectural separation. Phase 3+ work.

---

## 9. DNS resolver (NET-D7, E18)

### 9.1 Separate service

`dns-resolver` is a userspace server:
- Consumes UDP and TCP channels from `net-stack`.
- Implements RFC 1034/1035 plus DNSSEC (RFC 4033/4034/4035).
- Supports DNS-over-TLS (RFC 7858), DNS-over-HTTPS (RFC 8484), DNS-over-QUIC (RFC 9250).
- Exposes a typed-record DNS query schema to applications.

### 9.2 Query schema

```paideia-as
signature DnsQuerySchema =
  protocol = ↑Query . ↓Answer . end
  query_type = struct { name: DomainName; type: QType; class: QClass }
  answer_type = struct { rcode: u8; answers: List<RR>; aa: bool; tc: bool; rd: bool; ra: bool; ad: bool; cd: bool }
  effects = !{dns_query}
```

Applications request DNS lookups by sending a typed query; receive a typed answer. Strings are *typed domain names*, not raw bytes — preventing classes of injection bugs.

### 9.3 Caching

The resolver maintains a TTL-respecting cache, sized configurable. Cache eviction is LRU.

### 9.4 DoH/DoQ as defaults

PaideiaOS prefers encrypted DNS (DoH or DoQ) over plain UDP/53 when the resolver's upstream supports it. The decision is per-connection: secure if possible.

---

## 10. NTS time service (NET-D8, E15)

### 10.1 The service

`nts-client` is a userspace process:
- Consumes UDP channels for NTP and NTS-KE.
- Implements NTP v4 (RFC 5905) plus NTS (RFC 8915).
- Holds the supervisor's `system_clock_cap` for clock adjustments.

### 10.2 Cryptographic identity

NTS uses TLS 1.3 (via `tls-server`) for the key-exchange phase, then symmetric authentication for the NTP messages. The TLS 1.3 portion benefits from the hybrid KEM (per PQ doc §7).

### 10.3 Operational pattern

- Configure 4+ NTS upstream servers.
- Compute median of recent samples.
- Slew the system clock to converge (avoid time jumps).
- Audit log records each major adjustment.

### 10.4 Roughtime as alternative

NTS is the primary. Roughtime (Google's alternative) is supported as a secondary verification source via a separate channel.

---

## 11. Packet filtering (NET-D10)

### 11.1 Effect-based firewall

The L3 layer's `filter` effect is dispatched once per packet:

```paideia-as
effect PacketFilter {
  op filter_inbound  : (packet: PacketCap, port: NetIfId) -> FilterDecision
  op filter_outbound : (packet: PacketCap, dst: IpAddr) -> FilterDecision
}

type FilterDecision = Accept | Drop | Redirect(NetIfId) | Mark(u32) | Log
```

A firewall rule is registered as a handler for this effect. The handler may:
- Inspect packet headers.
- Inspect partial payload (DPI — though this is heavyweight).
- Maintain state (connection tracking).
- Return a decision.

Multiple handlers can be installed in a chain (`Accept` continues; `Drop` short-circuits). The chain order is supervisor-policy.

### 11.2 Capability-gated installation

Installing a packet filter requires `packet_filter_cap`. The supervisor grants this to administrative processes; misuse is auditable.

### 11.3 Comparison with eBPF

Linux's eBPF is a sandboxed VM for kernel-level packet filtering. PaideiaOS's effect-based filtering is the same idea framed in PaideiaOS native concepts:
- Effect handlers replace eBPF programs.
- The substructural type system replaces eBPF's verifier (paideia-as catches at compile time).
- Capability discipline replaces the eBPF capability checks.
- The result: filtering with full language expressiveness, type safety by construction, and no separate VM.

---

## 12. IPv6 + IPv4 (NET-D3)

### 12.1 IPv6 as primary

The stack's address families are typed: `Ipv4Addr` and `Ipv6Addr` are distinct types. Internal data structures (routing table, connection tables) handle both.

### 12.2 Happy Eyeballs v2

When an application connects to a hostname, the DNS resolver may return both A and AAAA records. The stack uses Happy Eyeballs v2 (RFC 8305) to race connections; the first to succeed wins. Default preference: IPv6 over IPv4 with a 50 ms head-start (per RFC 8305 §2).

### 12.3 IPv4-mapped IPv6 addresses

The stack supports IPv4-mapped IPv6 representation (`::ffff:0:0/96`) at the application API for ergonomics, but internally distinguishes.

### 12.4 NAT

Phase 1–2: no NAT. PaideiaOS hosts use real addresses (IPv6) or routable IPv4. Phase 3+ for systems that need NAT: a separate NAT service installable as a `packet_filter_cap` holder.

---

## 13. The NetIfSchema (driver interface)

The schema between a NIC driver and `net-stack`:

```paideia-as
signature NetIfSchema =
  protocol = capability_protocol  // negotiation + ongoing rx/tx
  offloads : OffloadSet            // TSO, LRO, RSS, checksum, etc.
  mtu : u32
  mac_addr : MacAddr
  link_state : LinkState
  effects = !{nic_send, nic_recv, nic_query_link, nic_set_promisc, …}

  // tx/rx channels
  tx_channel : Channel<EthernetFrameCap>
  rx_channel : Channel<EthernetFrameCap>

  // control
  ctrl_channel : Channel<NetIfControlSchema>
```

The driver hands the schema instance to the stack at registration; the stack consumes packets from `rx_channel`, sends via `tx_channel`, and controls the NIC via `ctrl_channel`.

### 13.1 Offload negotiation

At schema instantiation:

```
stack: send NetIfControlSchema.QueryOffloads
driver: reply OffloadSet { tso: true, lro: false, rss: true, ... }
stack: send NetIfControlSchema.EnableOffloads(tso, rss)
driver: configure NIC; reply Ack
```

The stack tailors its tx/rx code paths to the negotiated set.

### 13.2 RSS for poll-mode

When RSS (Receive Side Scaling) is available, the NIC distributes incoming packets across multiple rings based on hash. In poll-mode, the stack's reserved-core thread polls all rings; in IRQ-mode, multiple threads handle their respective rings.

---

## 14. Application API (NET-D13)

### 14.1 Foundation: session-typed channels

Applications get typed channels from `net-stack` via the service registry pattern (per drivers §8.4):

```paideia-as
let tcp_conn : Channel(TcpConnectSchema) = supervisor.lookup_service("net.tcp", connect_args)
let response = tcp_conn.send(payload)
tcp_conn.close()
```

The channel is the foundation. All higher-level libraries build on it.

### 14.2 Ergonomic: functor-typed libraries

```paideia-as
module Http3Client(Tls: TlsServerSig)(Net: NetStackSig) : Http3ClientSig = struct
  let request(url: Uri, method: Method, headers: Headers, body: Body) -> Response
    = ...
end

// Application:
module MyClient = Http3Client(SystemTls)(SystemNet)
MyClient.request("https://example.com/", GET, ...)
```

The functor parameterizes by the TLS and network services; the application picks instances. This is pillar 9 (hierarchical) for libraries: the library is a functor over the system services.

### 14.3 Library catalog (initial)

| Library | Purpose | Built on |
|---|---|---|
| `HttpClient` | HTTP/1.1, HTTP/2, HTTP/3 client | TLS + QUIC + TCP |
| `HttpServer` | HTTP server | Same |
| `WebSocketClient` / `Server` | RFC 6455 | HTTP upgrade |
| `Smtp` | SMTP / RFC 5321 | TCP + TLS |
| `Sftp` | SSH file transfer | TCP + SSH (future) |
| `MqttClient` | MQTT 5.0 | TCP + TLS |

These libraries are independent of `net-stack`'s internals; they consume the public schemas only.

---

## 15. paideia-as implementation

### 15.1 Module layout

```
src/userspace/net/
├── stack/                          # the net-stack server
│   ├── server.s                    # main loop, IPC entrypoints
│   ├── poll.s                      # poll-mode loop
│   ├── irq.s                       # IRQ-mode dispatcher
│   ├── l2/
│   │   ├── ethernet.s
│   │   ├── vlan.s                  # phase 3+
│   │   └── netif.s                 # NetIfSchema consumer
│   ├── l3/
│   │   ├── ipv6.s
│   │   ├── ipv4.s
│   │   ├── icmp.s
│   │   ├── ndp.s                   # IPv6 neighbor discovery
│   │   ├── arp.s
│   │   ├── routing.s
│   │   └── filter.s                # PacketFilter effect dispatch
│   ├── l4/
│   │   ├── tcp/
│   │   ├── udp/
│   │   └── quic/
│   ├── buffers/                    # hugepage-backed pools
│   └── effects.s
├── tls-server/                     # separate process
├── dns-resolver/                   # separate process
├── nts-client/                     # separate process
└── lib/                            # functor-typed libraries (HttpClient, etc.)
```

### 15.2 Phase 1 vs phase 2

Phase 1 (NASM bootstrap):
- A minimal stack: IPv4 + TCP + UDP only.
- IRQ-driven only (no poll-mode); no reserved-core capability yet.
- A single NIC supported.
- No TLS; no DNS; no NTS.
- Used for basic networked diagnostics during bring-up.

Phase 2 (paideia-as coexistence):
- IPv6 native; IPv4 dual.
- QUIC.
- Poll-mode with `reserved_core_cap`.
- TLS server with hybrid-KEM handshake.
- DNS resolver with DoT/DoH.
- NTS time service.
- BBRv3 congestion control.

Phase 3+ (paideia-as canonical):
- WireGuard-style overlay.
- VLAN + bonding + multi-NIC.
- Hardware NIC TLS offload.
- Multipath TCP.

---

## 16. Performance considerations

| Metric | Budget | Substrate |
|---|---|---|
| Single-flow TCP throughput, IRQ-mode | ≥ 10 Gbps | bare-metal SR + 25G NIC |
| Single-flow TCP throughput, poll-mode | ≥ 25 Gbps (line rate of common NIC) | bare-metal SR + 25G NIC |
| Packet rate, poll-mode, small packets | ≥ 5 Mpps | bare-metal |
| Single TCP connect-to-handshake latency | ≤ 100 µs (RTT + stack) | LAN |
| Single QUIC connect with 0-RTT | ≤ 50 µs | LAN |
| Hybrid TLS handshake (X25519 + ML-KEM-1024) | ≤ 1.5 ms | bare-metal w/ AVX-512 |
| DNS query (UDP, cached) | ≤ 1 µs | bare-metal |
| DNS query (DoT, uncached) | ≤ 50 ms (network-dominated) | LAN |

Aspirational; baselines come from `design/network/perf-baselines.md` (future).

---

## 17. Verification

### 17.1 Compliance test suites

- IETF protocol conformance tests where available (`packetdrill`-style scripts).
- RFC 9293 test vectors.
- TLS 1.3 KAT (known-answer tests).
- QUIC interop matrix (phase 3+).

### 17.2 Fuzz testing

Per dev-env §9.5: every protocol parser is a fuzz target. The fuzz corpus is seeded from real captures and the IETF interop test vectors.

### 17.3 Stress and performance regression

CI runs a `iperf3`-equivalent on the QEMU `-netdev socket` topology; throughput regression alerts at the perf-regression threshold.

### 17.4 Cross-protocol property tests

Property: a packet sent via TCP arrives bit-identical on the receiver (modulo framing).
Property: a UDP datagram is either delivered or dropped; if delivered, it is bit-identical.
Property: a QUIC stream's bytes arrive in order on the receiving side.

---

## 18. Open issues

| ID | Issue | Resolution |
|---|---|---|
| NET-O1 | The per-NIC offload negotiation table — concrete schema for what each driver advertises. | `design/network/offload-schema.md` (future) |
| NET-O2 | BBRv3 implementation — open-source reference; integration with PaideiaOS structures. | `design/network/bbrv3.md` (future) |
| NET-O3 | The packet-filter chain ordering policy — when multiple filters are installed, what's the rule? | `design/network/filter-chain.md` (future) |
| NET-O4 | The TLS server's session-resumption ticket storage — a CoW FS file or in-memory? | `design/network/tls-resume.md` (future) |
| NET-O5 | The DNS resolver's cache size and policy. | `design/network/dns-cache.md` (future) |
| NET-O6 | NTS upstream server selection and trust — how does PaideiaOS pick? | `design/network/nts-upstreams.md` (future) |
| NET-O7 | Performance baselines — first bare-metal measurements drive `perf-baselines.md`. | `design/network/perf-baselines.md` (future) |
| NET-O8 | The HTTP library — built-in PaideiaOS implementation, port a respected open-source one, or both? | `design/network/http.md` (future) |
| NET-O9 | The WireGuard-style overlay — design hooks present but the full design is phase 3+. | `design/network/overlay.md` (future) |
| NET-O10 | The QUIC connection migration interaction with reserved-core poll-mode — when a connection migrates between NICs, does poll-mode polling discover the migration? | `design/network/quic-migration.md` (future) |
| NET-O11 | The choice between in-stack TLS offload negotiation vs. application-controlled TLS offload — phase 3+. | `design/network/tls-offload.md` (future) |
| NET-O12 | IPv4 reachability degradation strategy — if the local network is IPv4-only, what's the fallback? | `design/network/ipv4-only-policy.md` (future) |

---

## 19. References

### 19.1 Protocol RFCs

- RFC 9293 *Transmission Control Protocol (TCP)*, 2022.
- RFC 768 *User Datagram Protocol*, 1980.
- RFC 8085 *UDP Usage Guidelines*, 2017.
- RFC 9000 *QUIC: A UDP-Based Multiplexed and Secure Transport*, 2021.
- RFC 9001 *Using TLS to Secure QUIC*, 2021.
- RFC 9002 *QUIC Loss Detection and Congestion Control*, 2021.
- RFC 9369 *QUIC Version 2*, 2023.
- RFC 8446 *TLS 1.3*, 2018.
- RFC 8200 *IPv6*, 2017.
- RFC 1122 *Requirements for Internet Hosts*, 1989 (historical).
- RFC 8305 *Happy Eyeballs Version 2*, 2017.
- RFC 1034/1035 *Domain Names*, 1987.
- RFC 4033/4034/4035 *DNSSEC*, 2005.
- RFC 7858 *DNS over TLS*, 2016.
- RFC 8484 *DNS over HTTPS*, 2018.
- RFC 9250 *DNS over QUIC*, 2022.
- RFC 5905 *NTP Version 4*, 2010.
- RFC 8915 *Network Time Security*, 2020.

### 19.2 Congestion control

- Cardwell, N. et al. *BBR: Congestion-Based Congestion Control*. ACM Queue 2016.
- BBRv3 IETF draft (TODO: verify current revision).

### 19.3 Packet processing architectures

- *DPDK Programmer's Guide*. (Reference for poll-mode userspace networking.)
- *VPP / FD.io* documentation. (Vectorized packet processing.)
- McSherry, F., Murray, D. *Naiad: A Timely Dataflow System*. SOSP 2013 (dataflow-style packet handling inspiration).

### 19.4 Filter / firewall

- Borkmann, D., Bertin, J. *BPF and XDP: A Practical Overview*. (Linux eBPF lineage.)

### 19.5 Hybrid PQ in TLS

- Stebila, D. et al. *Hybrid Key Exchange in TLS 1.3*. IETF draft / RFC successor (TODO: verify final number).

---

*End of document.*
