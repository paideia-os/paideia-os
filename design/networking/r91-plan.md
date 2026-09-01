# R91–R99 Plan: Reaching the Internet from a QEMU Guest

**Status:** Proposal — osarch voice, kernel-side only. Ready for milestone/issue filing.
**Date:** 2026-09-01.
**Scope:** Complete the kernel-side networking stack (NIC drivers → L2 → L3 →
L4 → sockets syscall surface → DHCP/DNS → TLS placement decision → boot
witnesses) so a user-space program (the sibling softarch wave's curl-like
tool) can open a TCP connection to a real Internet host from a QEMU guest
using an emulated NIC, resolve its name via DNS, and exchange HTTP bytes.
**Companion:** a parallel softarch wave designs the user-space consumer
(curl-like tool + any user-space TLS). This document declares the syscall
surface that tool needs and stops there — no user-space design here.
**Round numbering:** R91–R99. **R90 is not available** — it is already in
use as the cross-repo housekeeping tag (`R90-XREPO.005`, `R90-XREPO.009` in
git history; see `design/user/syscall-table.md`'s own reference list). The
last feature round is R89 (`KIND_TUI_CANVAS`, closed). This wave is
therefore R91 through R99, nine rounds.

---

## 0. This is NOT a greenfield wave — read this first

The task brief that produced this document assumed `src/kernel/core/net/`
was empty. **It is not.** R27 (2026-08-11, "e1000e/i219 NIC + L2/L3/L4
substrate + ping/echo") and R72 ("TCP substrate") already landed a working,
if narrowly-exercised, kernel-native IPv4/TCP/UDP/ICMP/ARP/Ethernet stack
plus a real e1000e driver and BSD-ish socket syscalls 87–94. Re-proposing
that work would waste review effort and risk clobbering real invariants
(the exact failure mode `[[feedback-spec-vs-codebase-conflicts]]` warns
against). This document instead:

1. Catalogs precisely what is landed and load-bearing (§1).
2. Catalogs the **real** gaps — mostly *integration* and *hardening* gaps,
   not missing protocol logic (§2).
3. Reconciles with a pre-existing aspirational design corpus at
   `design/network/*.md` (dated 2026-06-17, pre-R27) that already answered
   several questions this brief asks me to decide fresh (§3).
4. Plans nine rounds (R91–R99) that close the integration gaps without
   re-deriving landed protocol logic (§4–§12).

### 0.1 Executive summary

**What lands in R91–R99:** a generic NIC dispatch layer so the kernel-native
L2/L3 stack stops being e1000e-specific; a from-scratch virtio-net driver
and a tiny rtl8139 witness driver; actual boot-time wiring of e1000e (which
today is dead code — never called from `kernel_main.pdx`, never in
`tools/run-qemu.sh`'s QEMU invocation, never in `driver_table.pdx`); a real
routing-table structure (today a single hardcoded gateway constant); a DHCP
client; a minimal DNS stub resolver; TCP hardening (wire the already-built
but unwired retransmit timer, data-retransmit replay, TIME_WAIT/half-close,
blocking accept/recv); socket syscall completion (`sendto`/`recvfrom`,
`getsockopt`/`setsockopt`, `getpeername`/`getsockname`, `poll`); a
capability/security hardening pass (MAC-spoof policy, privileged-port gate,
verify NIC DMA sits in an IOMMU domain); a TLS placement decision (ratifying
an existing design commitment: **user-space**, not in-kernel); and three
boot witnesses run through a **real** emulated NIC (not the R72 loopback
fast path) wired into `run-smoke.sh`.

**What is explicitly deferred**, each with a one-line reason:

- **IPv6** — `design/network/stack.md` NET-D3 wants IPv6-native long-term,
  but R27/R72 shipped IPv4-only and `ipv4-only-policy.md` already treats
  IPv4-only operation as a normal, audited (not alarmed) mode. Adding v6
  now means dual-stacking ARP+NDP, routing, and every socket call in the
  same wave as first-ever hardware-in-the-loop verification — too much
  simultaneous risk. Deferred to a follow-up round once R91–R99's IPv4
  path is proven end-to-end.
- **QUIC** — `stack.md` NET-D2 wants it as an L4 peer, but that requires
  the Phase-2 userspace `net-stack` server architecture (§0.3 below);
  building QUIC against the current in-kernel monolith would be thrown
  away at the Phase-2 migration.
- **BBRv3** — `design/network/bbrv3.md` commits to it as the long-term
  default, but its design (§2: "pacer integration with the wait-free IPC
  slot-cap economy") is written against the Phase-2 userspace stack, not
  the current in-kernel TCB model. R94 stays with R72's Reno-lite plus
  RFC 6298 Karn refinement; BBRv3 is revisited at the Phase-2 migration.
- **In-kernel TLS** — see §9. Recommendation: user-space, matching the
  pre-existing `NET-D6` decision in `stack.md` §8.
- **Fragmentation/reassembly, MPTCP, TCP-AO, WireGuard overlay, NAT** —
  all explicitly Phase-3+ in `stack.md` §0.2/§15.2; untouched.
- **Full packet filter implementation** — `design/network/filter-chain.md`
  already specifies chain semantics (numeric priority, `Drop`
  short-circuits). R96 reserves `KIND_PACKET_FILTER` and points at that
  doc; it does not implement the filter chain.

**Total scope:** 9 rounds, 39 milestones, **99 issues** (table in §19).

### 0.2 Architecture tension this plan does NOT resolve

`design/network/stack.md` describes a Phase-2 target architecture:
a single userspace `net-stack` server, internally layered by algebraic
effect handlers (not process boundaries), consuming NIC drivers via a
`NetIfSchema` IPC contract, with TCP/UDP/QUIC as peer L4 effects. **None
of R27, R72, or this plan build that.** Everything through R99 stays
kernel-native: syscalls 87–94 dispatch directly into `net/tcp.pdx` and
friends, exactly as R72 built it, and NIC drivers stay in-kernel
monolithic code in the e1000e style — not the R29+ "every driver is a
separately-restartable userspace process" model that `driver_table.pdx`
now exists to support for hardware drivers landing after R29.

This is a **deliberate, scoped decision**, not an oversight: `tcp-substrate.md`
already declared R72 "a realistic MVP, not production TCP", and stack.md's
own §15.2 names an IRQ-driven, single-NIC, kernel-adjacent "Phase 1" that
is what actually shipped. R91–R99 is the completion of that Phase 1, not
the start of Phase 2. **A future round-family must migrate the kernel-native
stack to the userspace `net-stack` server design** before QUIC, BBRv3, the
`tls-server`/`dns-resolver`/`nts-client` process split, or IPv6-native dual
stack land for real — that migration is out of scope here and should be
its own osarch-planned wave once R91–R99 proves the IPv4 path works against
real hardware. This plan flags it so it is not lost.

---

## 1. What is already landed (ground truth, verified against source)

| Area | File(s) | State |
|---|---|---|
| e1000e/i219 NIC driver | `src/kernel/core/drivers/e1000e/{probe,regs,reset,phy,mac,rx_ring,tx_ring,msix,irq}.pdx` | Real code. Probe requires `_pci_devices` populated (MCFG/ACPI surface) — **stays empty under `-kernel` direct boot** per the driver's own probe.pdx comment. **Never called from `kernel_main.pdx`.** Not registered in `driver_table.pdx` (only mentioned in a comment). `tools/run-qemu.sh` passes **no** `-netdev`/`-device` flags at all — QEMU never gives the guest a NIC to find. |
| Ethernet L2 | `net/ethernet.pdx`, `net/l2_tx.pdx`, `net/l2_rx.pdx` | Real: parse/build, RX ethertype dispatch, TX with bump-allocated buffer + descriptor publish. **Hardcoded to e1000e's `(bar0, tx_ring_pa)` calling convention** — not NIC-agnostic despite the generic name. |
| ARP | `net/arp.pdx` (1018 lines) | Real: request/reply, 16-slot cache with round-robin eviction + tick expiry, gratuitous-ARP detection. |
| IPv4 | `net/ipv4.pdx` (910 lines) | Real: header parse/build/checksum, RX engine (dst filter + protocol demux), TX engine (same-/24 subnet check → ARP resolve → build → `l2_tx_send`). **`_ipv4_my_ip = 10.0.0.2`, `_ipv4_gw_ip = 10.0.0.1` are hardcoded rodata constants**, not a routing table — comment explicitly says "DHCP lands R29+" (never happened). |
| ICMP | `net/icmp.pdx` | Echo Reply responder landed (R27.M6). No echo-request-originate (ping *client*) path. |
| UDP | `net/udp.pdx` (538 lines) | Header parse/build (checksum field always 0 — "no bit-flip surface on QEMU virtual link" posture, stated explicitly). RX only echoes hardcoded port 7; **real per-port → `KIND_UDP_SOCKET` dispatch is stubbed out, deferred to "#1015"** which never landed. `KIND_UDP_SOCKET = 0x50` is a **pre-R30-numbering-scheme** ordinal, absent from `design/architecture/next-wave-derived-kinds.md`'s registry entirely (a real documentation gap). |
| TCP | `net/tcp.pdx` (1365 lines), `net/tcp_socket.pdx` | Real 11-state RFC 793 machine, 64-TCB pool, Reno-lite congestion control, single-timer retransmit. **Exercised only via the R72 boot witness's loopback self-connect fast path** (`local_ip == remote_ip`) — the real off-box `ipv4_tx_send` path exists in code but has never been run. Retransmit timer (`tcp_poll_retransmits`) is **not wired to any interrupt/tick source** — exported but never called. Data retransmit only replays control segments correctly (SYN/ACK/FIN), not payload bytes (`_tcp_tx_buf_table` declared, not wired). TIME_WAIT frees immediately (no 2MSL). `accept()`/`recv()` are non-blocking only. |
| Sockets syscalls | `syscall/handlers/sys_{socket,bind,listen,accept,connect,send,recv,shutdown}.pdx`, syscall numbers 87–94 | Real, TCP-only. `KIND_TCP_LISTENER = 0x1A4`, `KIND_TCP_SOCKET = 0x1A5` (both root-minted, over `KIND_IPC_ENDPOINT`) — **landed in `cap/kind.pdx` at R72 but never backfilled into `design/architecture/next-wave-derived-kinds.md`'s table** (verified: grep for either name in that file returns nothing). This plan backfills both (§10). |
| Legacy virtio-net stub | `src/drivers/virtio_net/probe.pdx` | Pre-refactor, Phase-7-era ("D7-006" issue numbering), disconnected from every current convention (not in `src/kernel/core/drivers/`, doesn't use `cap/kind.pdx`, doesn't use `driver_table.pdx`). Its own header says "no packet transmission" and gates its PCI config reads as non-live. **Dead code; superseded by this plan's R91.M6 (retire it).** |
| paideia-as crypto/bit primitives | `tools/paideia-as/CHANGELOG.md` | `bswap r32/r64` (PA-R15-001, PA-R13-014), `lock xadd/cmpxchg/cmpxchg16b/bts/btr/btc/and/or/xor` (PA-R16.x), `ChaCha20-Poly1305` seal/open + `Argon2id` derive (#1305, v0.22.0), `mldsa65_sign` (#1330, v0.23.0), `f32/f64` SSE encoder (v0.24.0). **No SHA-256/HMAC/HKDF, no X25519/ECDH, no ECDSA/RSA verify, no ML-KEM intrinsic.** Directly informs §9's TLS decision. |

---

## 2. The real gaps (what R91–R99 actually closes)

Ranked by "how much does this block reaching the Internet":

1. **The whole stack has never touched a real NIC ring in QEMU.** Zero
   `-netdev`/`-device` flags in `run-qemu.sh`; e1000e's probe never runs;
   the R72 witness deliberately avoids the real TX/RX path. This is the
   single highest-risk gap — every protocol layer above it is unverified
   against actual hardware DMA, MSI-X delivery, and QEMU's SLIRP backend.
2. **L2/L3 is single-NIC-and-single-driver-hardcoded.** `l2_tx_send(bar0,
   tx_ring_pa, ...)` bakes in e1000e's exact MMIO register layout
   (`TDT` at offset `0x3818`) inside a "generic" L2 module. Adding
   virtio-net or rtl8139 needs a real dispatch layer, not a second
   hardcoded copy.
3. **No DHCP** — the IP/gateway are rodata constants. A real "reach the
   Internet" demo against QEMU SLIRP needs a lease from `10.0.2.2`.
4. **No DNS** — no resolver at all.
5. **UDP's per-port socket delivery was deferred at R27 and never
   returned to.** Only port 7 (echo) works; the socket-syscall family
   only covers TCP.
6. **TCP has multiple "exported but unwired" primitives**: retransmit
   timer, data retransmit replay, blocking semantics.
7. **Socket syscall surface is incomplete** relative to what a real
   client needs: no `sendto`/`recvfrom` (UDP has no send/recv syscalls
   at all), no `getsockopt`/`setsockopt`, no `getpeername`/`getsockname`,
   no readiness (`poll`).
8. **Security model is aspirational-only.** No verification that NIC
   DMA buffers sit in an IOMMU domain (R22/R25's VT-d work is cited in
   comments, never confirmed wired to e1000e). No MAC-spoof policy. No
   privileged-port gate on `bind()`.
9. **TLS is entirely undecided in the shipped code**, though the
   pre-existing design corpus already decided it (§3, §9).

---

## 3. Reconciliation with `design/network/*.md` (pre-existing, 2026-06-17)

A full aspirational Phase-2/3 design already exists at
`design/network/stack.md` plus twelve satellite docs. It predates R27 by
about two months and describes an architecture (userspace `net-stack`
server, algebraic-effect layering, IPv6-native dual stack, QUIC as an L4
peer, BBRv3, a separate `tls-server`/`dns-resolver`/`nts-client` process
split) that **R27/R72 did not build** and **this plan does not build
either** (§0.2). Where it settles a question this brief poses as open,
this plan ratifies rather than re-decides:

| Brief's open question | `design/network/*.md` answer | This plan's action |
|---|---|---|
| IPv6 in scope? | NET-D3 wants IPv6-native long-term; `ipv4-only-policy.md` V4-D2 already treats IPv4-only as a normal, non-alarming mode | Defer IPv6 (§0.1); log an informational klog line on DHCP lease, echoing V4-D3's audit-not-alarm posture |
| TCP congestion control | `bbrv3.md` BBR-D1: BBRv3 default, designed against the Phase-2 pacer/slot-cap substrate | Stay on R72's Reno-lite + Karn refinement (R94.M5); revisit at Phase-2 migration |
| Packet filter design | `filter-chain.md` FIL-D1..D6: numeric priority 0–999, `Drop` short-circuits, `Accept` continues, tie-break by registration order | R96.M3 reserves `KIND_PACKET_FILTER` and cites this doc; no new chain-ordering decision needed |
| TLS: in-kernel or user-space? | `stack.md` §8 NET-D6: separate `tls-server` process holding long-term keys, isolated from the network stack's AS, explicitly rejecting kTLS-style in-stack integration (§8.3) | Ratified (§9): user-space, independently reconfirmed by the paideia-as crypto-substrate gap (no X25519/SHA-256/HKDF/ECDSA today) |
| DNS resolver scope | `dns-cache.md`: full LRU cache, 10k entries/100MiB, per-user namespaces, negative caching | R93's stub explicitly does **none** of this (single hostname, no cache) — this plan flags `dns-cache.md`'s parameters as the target for a later "professionalize the resolver" round, not R93 |
| TLS session resumption | `tls-resume.md`: in-memory tickets, optional CoW-FS persistence | N/A this wave — no TLS lands in-kernel or in R91-R99's own scope |

**One nuance worth surfacing to main:** `stack.md`'s `tls-server` is a
separate *process* consuming a `Channel(TcpConnectSchema)` from a future
`net-stack` server. Today there is no `net-stack` server — TCP is
in-kernel, reached via syscalls. The sibling softarch wave's curl-like
tool therefore plays the role `tls-server` will eventually play, just
directly against syscalls 87–94/96–102 instead of an IPC schema. This is
forward-compatible (the tool can be refactored into a dedicated process
at the Phase-2 migration without an ABI break, since it already only
touches socket syscalls) but is worth saying explicitly so softarch's
design doesn't accidentally invent a competing TLS-boundary story.

---

## 4. Architecture decisions this plan makes

### 4.1 NIC dispatch layer (R91.M1) — the central new mechanism

`l2_tx_send`/`l2_rx_handle`/`ipv4_tx_send`'s NIC-facing calls are
currently e1000e-specific despite generic names. Rather than duplicate a
full L2/L3 stack per NIC (three drivers × the same 900+ lines of IPv4/ARP
logic — unacceptable), R91.M1 introduces:

- **`KIND_NIC`** (new ordinal, §10) — a device-level capability naming
  which NIC backend is active (`NIC_KIND_E1000E = 1`, `NIC_KIND_VIRTIO_NET
  = 2`, `NIC_KIND_RTL8139 = 3`) plus its MAC and link state. Root-minted
  at the single boot-time probe (§4.2), over `KIND_DEVICE`.
- **A small dispatch shim** (`net/nic_dispatch.pdx`, new) holding one
  `_active_nic_kind` global and three thin wrapper functions
  (`nic_l2_tx_send`, `nic_l2_rx_poll`, `nic_mac_addr`) that branch to the
  matching backend. **Before committing to paideia-as's `@jump_table`
  attribute** (mentioned in the paideia-as "Net-primitives" CHANGELOG
  release as landing "stdlib forward-declarations... and the @jump_table
  attribute for O(1) protocol dispatch") **verify it is actually lowered
  and not merely forward-declared** — the paideia-as CHANGELOG has a
  documented history of "trait declared, lowering deferred" gaps (e.g.
  `FreelistOps`/`BitmapOps` in the same release). R91.M1-002 includes this
  verification as its first step; if `@jump_table` is not usable, fall
  back to an explicit `cmp`/`je` chain over the 3 NIC kinds — negligible
  cost at this scale (≤3 backends) and consistent with the existing
  `ipv4_rx_handle` protocol-dispatch style (a straight compare chain, not
  an indirect call).
- **Single active NIC per boot** (MVP scope, matches `stack.md` §0.2
  NET-D15 "phase 1–2 ships single-NIC"). Multi-NIC selection and
  bonding are explicitly out of scope, matching the existing design
  corpus.
- Boot probe order: e1000e → virtio-net → rtl8139 (first found wins).
  Rationale: e1000e is the most-tested existing code; virtio-net is
  QEMU's modern default and the more likely long-term target; rtl8139 is
  a witness/fallback per the brief's own framing.

### 4.2 Driver placement: stays in-kernel, does not migrate to `driver_table.pdx`'s process model

`driver_table.pdx` (read in full during research) is the R29+ substrate
for *userspace-process* drivers — it tracks `(pid, generation)` binding,
DMA-domain cardinality, and a restart-supervision FSM for a driver that
runs as its own address space. e1000e (R27) predates this and runs as
in-kernel code with no process boundary at all — the whole TCP/IP stack
runs the same way. **Migrating NIC drivers to the userspace-process
model in this wave would be a second, unrelated architecture change
bundled into a networking wave.** R91 keeps virtio-net and rtl8139
in-kernel, matching e1000e's existing style, and registers the winning
NIC in `driver_table.pdx` **only for supervisor visibility** (a row that
records "yes, a NIC driver's code is active," not a real process/FSM
binding) — this is honestly labeled as a visibility shim in the issue
spec, not a real lifecycle migration.

### 4.3 Routing: minimal real routing table, not a full table

The task brief asks for "minimum: single default route via configured
gateway." Today that's a single `_ipv4_gw_ip` rodata constant. R92.M1
replaces it with a tiny in-`.bss` structure (`{iface_kind, my_ip[4],
gw_ip[4], netmask[4], dns_ip[4], lease_expiry}`) that DHCP (R93.M1) can
overwrite at runtime. This is *not* a general routing table (no multiple
routes, no metrics) — it is exactly the "single default route" scope
the brief asks for, made mutable instead of const.

### 4.4 UDP socket model: unify with TCP's syscall pattern, retire the old IPC-RPC posture

R27.M6 gave `KIND_UDP_SOCKET` a mint gate plus an "IPC RPC schema" for
delivery — a different mechanism than TCP's direct syscall-to-TCB
resolution. Continuing two different socket-delivery mechanisms (one
IPC-RPC, one direct-syscall) is exactly the kind of inconsistency this
plan should not leave in place. **Decision: re-platform
`KIND_UDP_SOCKET` onto the same posture as `KIND_TCP_SOCKET`/
`KIND_TCP_LISTENER`** — direct syscall resolution via a `udp_socket_resolve`
helper mirroring `tcp_socket_resolve`, dropping the IPC-RPC delivery path.
The old `KIND_UDP_SOCKET = 0x50` ordinal predates the modern 0x1xx
numbering scheme entirely; R93.M2 mints a new ordinal in that scheme
(§10) and documents `0x50` as superseded (not reused — a stale reference
to `0x50` in any dormant code must fail loudly, not silently alias a new
meaning).

### 4.5 Blocking semantics: reuse `wake_block.pdx`, do not invent a second wait mechanism

`sched/wake_block.pdx` already exists (used by `sys_wait4` per
`tcp-substrate.md`'s own citation, "R17.M0-724-D5a precedent"). R94.M4 and
R95.M3 (`poll`) both build on it rather than inventing a socket-specific
blocking primitive.

---

## 5. R91 — NIC substrate: dispatch layer, virtio-net, rtl8139, real boot wiring

**Depends on:** R27 (e1000e code, IPv4/ARP/L2 substrate), R29 (`driver_table.pdx`
for the visibility-shim registration only — not a hard functional dependency).
**Headline capability:** `KIND_NIC`.

### R91.M1 — NIC dispatch substrate (4 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R91.M1-001 | `KIND_NIC` capability: device-level NIC authority (nic_kind selector, MAC, link state), root-minted over `KIND_DEVICE`. | `cap/kind_nic.pdx` (new), `cap/kind.pdx` | `R91 KIND_NIC OK` | M | none |
| R91.M1-002 | Verify paideia-as `@jump_table` is lowered (not just forward-declared); build `net/nic_dispatch.pdx` dispatch shim (`nic_l2_tx_send`/`nic_l2_rx_poll`/`nic_mac_addr`) over the 3 NIC kinds, falling back to an explicit compare chain if `@jump_table` is unusable. | `net/nic_dispatch.pdx` (new) | n/a (covered by R91.M5 witness) | L | R91.M1-001 |
| R91.M1-003 | Re-point `ipv4_tx_send`/`l2_tx_send` call sites through `nic_dispatch` instead of hardcoding e1000e's `(bar0, tx_ring_pa)` globals. | `net/ipv4.pdx`, `net/l2_tx.pdx` | n/a | M | R91.M1-002 |
| R91.M1-004 | Re-point e1000e's IRQ handler's `l2_rx_handle` call through `nic_dispatch` so RX also routes generically. | `drivers/e1000e/irq.pdx`, `net/l2_rx.pdx` | n/a | S | R91.M1-002 |

### R91.M2 — e1000e real boot wiring (currently orphaned code) (4 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R91.M2-001 | Call `e1000e_probe` from `kernel_main.pdx` after PCI enumeration; verify `_pci_devices` is actually populated under this tree's real boot path (not just `-kernel` direct boot, which the probe's own comment says stays empty). | `boot/kernel_main.pdx` | `R91 E1000E PROBE OK` / `R91 E1000E PROBE NONE` | M | R91.M1-004 |
| R91.M2-002 | Register the probed e1000e as a `driver_table.pdx` row (visibility shim per §4.2 — not a process migration) plus mint `KIND_NIC` with `nic_kind = NIC_KIND_E1000E`. | `boot/kernel_main.pdx`, `driver/driver_table.pdx` | `R91 NIC REGISTER OK kind=1` | M | R91.M2-001, R91.M1-001 |
| R91.M2-003 | Confirm RX ring refill + MSI-X vector arm actually run at boot (currently only unit-exercised); fix any dormant-path bugs found. | `drivers/e1000e/{rx_ring,msix,irq}.pdx` | `R91 E1000E RING LIVE OK` | M | R91.M2-001 |
| R91.M2-004 | `tools/run-qemu.sh`: add `-netdev user,id=n1 -device e1000e,netdev=n1,mac=<fixed>` behind a flag/mode so e1000e boots have a NIC to find. | `tools/run-qemu.sh` | n/a | S | R91.M2-001 |

### R91.M3 — virtio-net driver, built fresh (6 issues)

Per §0.1, the existing `src/drivers/virtio_net/probe.pdx` is superseded,
not extended (retired in R91.M6). This is a **from-scratch** driver under
`src/kernel/core/drivers/virtio_net/`, mirroring e1000e's file layout.

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R91.M3-001 | `probe.pdx`: PCI class filter + vendor/device match (0x1AF4/0x1000, modern virtio-net) against `_pci_devices`, BAR discovery for the modern virtio PCI capability layout (common cfg / notify / ISR / device cfg BARs per virtio 1.1 §4.1.4). | `drivers/virtio_net/probe.pdx` (new) | `R91 VIRTIO PROBE OK` | M | R91.M1-001 |
| R91.M3-002 | `common_cfg.pdx`: virtio common configuration structure accessors (device_status, device_feature_select/-bits, queue_select/size/desc/driver/device). | `drivers/virtio_net/common_cfg.pdx` (new) | n/a | M | R91.M3-001 |
| R91.M3-003 | `virtqueue.pdx`: split virtqueue layout (descriptor table + avail ring + used ring) allocation and the driver-side add-to-avail / reap-from-used primitives, generic over queue index (used for both RX queue 0 and TX queue 1). | `drivers/virtio_net/virtqueue.pdx` (new) | n/a | L | R91.M3-002 |
| R91.M3-004 | `tx.pdx`: `virtio_net_tx_send` — build `virtio_net_hdr` (legacy 10-byte, no offloads negotiated) + Ethernet frame into a descriptor chain, publish to the TX virtqueue, kick via notify BAR. Same call signature shape as `l2_tx_send` so `nic_dispatch` can wrap it uniformly. | `drivers/virtio_net/tx.pdx` (new) | n/a | M | R91.M3-003 |
| R91.M3-005 | `rx.pdx` + `isr.pdx`: pre-populate RX virtqueue with buffers, ISR (legacy INTx or MSI-X per negotiated feature) reaps completed RX descriptors and calls `l2_rx_handle`. | `drivers/virtio_net/{rx,isr}.pdx` (new) | n/a | L | R91.M3-003 |
| R91.M3-006 | `mac.pdx`: read MAC from `device_cfg` BAR (`VIRTIO_NET_F_MAC` feature) or synthesize a locally-administered MAC if the feature isn't offered; link-status query (`VIRTIO_NET_F_STATUS`). | `drivers/virtio_net/mac.pdx` (new) | `R91 VIRTIO MAC OK mac=%s` | S | R91.M3-002 |

### R91.M4 — rtl8139 tiny witness driver (4 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R91.M4-001 | `probe.pdx`: PCI vendor/device match (0x10EC/0x8139), BAR0 I/O-port-or-MMIO discovery, power-on + software reset (CR register). | `drivers/rtl8139/probe.pdx` (new) | `R91 RTL8139 PROBE OK` | S | R91.M1-001 |
| R91.M4-002 | `rx.pdx`: single contiguous RX buffer ring (the classic rtl8139 8KiB+16+1500 layout, no descriptor table — this NIC predates descriptor rings), CAPR/CBR cursor management. | `drivers/rtl8139/rx.pdx` (new) | n/a | M | R91.M4-001 |
| R91.M4-003 | `tx.pdx`: 4-slot TX descriptor round-robin (TSAD0-3/TSD0-3 register pairs — no ring, no chaining). | `drivers/rtl8139/tx.pdx` (new) | n/a | M | R91.M4-001 |
| R91.M4-004 | `mac.pdx` + IRQ handler: MAC from IDR0-5 registers; ISR handles ROK/TOK bits, calls `l2_rx_handle`. | `drivers/rtl8139/{mac,irq}.pdx` (new) | `R91 RTL8139 MAC OK mac=%s` | S | R91.M4-002, R91.M4-003 |

### R91.M5 — multi-NIC boot probe order + witness (3 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R91.M5-001 | Boot sequence: probe e1000e, then virtio-net, then rtl8139; first found sets `_active_nic_kind` and mints `KIND_NIC`. | `boot/kernel_main.pdx` | n/a | M | R91.M2-002, R91.M3-006, R91.M4-004 |
| R91.M5-002 | `tools/run-qemu.sh`: add a `PAIDEIA_NIC=e1000e\|virtio\|rtl8139\|none` env switch selecting which `-netdev`/`-device` pair to pass (default `virtio` — QEMU's modern default per the brief). | `tools/run-qemu.sh` | n/a | S | R91.M3-001, R91.M4-001 |
| R91.M5-003 | Boot witness `boot_r91_nic_probe`: probes the active NIC, prints `net nic ok mac=xx:xx:xx:xx:xx:xx kind=<n>`, asserted by `tests/expected-r91-nic-probe.golden`. | `boot/witness/r91_nic_probe.pdx` (new), `tools/run-smoke.sh` (mode `boot_r91_nic`) | `R91 NIC PROBE LIVE OK` | M | R91.M5-001, R91.M5-002 |

### R91.M6 — retire the legacy stub + round closure (2 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R91.M6-001 | Delete `src/drivers/virtio_net/probe.pdx` (superseded by R91.M3); note the removal and why in the round retrospective rather than silently dropping it from `git log`. | `src/drivers/virtio_net/probe.pdx` (removed) | n/a | XS | R91.M3-001 |
| R91.M6-002 | R91 closure retrospective + STATUS.md update + tag `r91-closed`. | `design/round-retrospectives/r91-closure.md` (new) | n/a | S | all R91.M1–M5 |

**R91 total: 23 issues.**

---

## 6. R92 — L2/L3 completion: routing table, real off-box verification

**Depends on:** R91 (a real NIC path to test against).

### R92.M1 — routing-table generalization (3 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R92.M1-001 | Replace `_ipv4_my_ip`/`_ipv4_gw_ip` rodata constants with a mutable `.bss` route record (`{iface_nic_kind, my_ip, gw_ip, netmask, dns_ip, lease_expiry_ticks}`); all existing readers (`ipv4_tx_send`'s subnet check, etc.) repoint at the new record with unchanged default values (10.0.0.2/24, gw 10.0.0.1) so R92 alone changes nothing observable — DHCP (R93) is what actually mutates it. | `net/ipv4.pdx`, `net/route_table.pdx` (new) | n/a | M | none |
| R92.M1-002 | `route_table_set`/`route_table_get` accessors with the same bounds-check-then-single-store discipline as `driver_table.pdx`'s row accessors (cite as the house style). | `net/route_table.pdx` | n/a | S | R92.M1-001 |
| R92.M1-003 | Unit witness: manually call `route_table_set` with a different IP/gateway pair mid-boot, verify `ipv4_tx_send`'s subnet decision picks up the change without a rebuild. | `boot/witness/r92_route_table.pdx` (new) | `R92 ROUTE TABLE OK` | S | R92.M1-002 |

### R92.M2 — ARP hardening for a live link (2 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R92.M2-001 | ARP probe + announce (RFC 5227 minimal subset — send a gratuitous ARP announcing our IP) on lease acquisition, so QEMU SLIRP's ARP cache and any real switch update promptly. Needed by R93's DHCP round; landed here since it is an ARP-layer change. | `net/arp.pdx` | n/a | S | R91 (real NIC) |
| R92.M2-002 | ARP cache miss during real (non-loopback) IPv4 TX: confirm the existing `IPV4_E_ARP_PENDING` retry path actually resolves and retransmits against a real NIC (today only reachable via code reading, never run) — fix any bug found. | `net/ipv4.pdx`, `net/arp.pdx` | n/a | M | R91 |

### R92.M3 — real off-box round-trip witness (3 issues)

This is the first time ANY of R27/R72's protocol code runs against a real
NIC ring instead of the loopback fast path or unit-level direct calls.

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R92.M3-001 | Boot witness: ARP-resolve and ICMP-ping QEMU SLIRP's gateway (`10.0.2.2`) through the real NIC TX/RX ring; verify Echo Reply arrives. This is the first real proof the e1000e/virtio-net rings, MSI-X delivery, and `ipv4_tx_send`'s non-loopback path all work together. | `boot/witness/r92_icmp_ping.pdx` (new) | `R92 ICMP PING OK rtt_ticks=%d` | M | R92.M2-002, R91.M5 |
| R92.M3-002 | ICMP echo-request-*originate* path (`icmp_send_echo_request`) — R27 only landed the responder; a ping client needs the originator too. | `net/icmp.pdx` | n/a | S | none |
| R92.M3-003 | Wire `boot_r92_icmp_ping` into `run-smoke.sh` (new mode `boot_r92_icmp`), golden fingerprint file. | `tools/run-smoke.sh`, `tests/expected-r92-icmp-ping.golden` (new) | n/a | S | R92.M3-001 |

### R92.M4 — IPv6 non-scope decision + round closure (1 issue)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R92.M4-001 | Write `design/networking/ipv6-deferral.md`: formalizes §0.1's IPv6 deferral rationale (cites `stack.md` NET-D3 and `ipv4-only-policy.md`), so a future reader doesn't mistake the absence of IPv6 work for an oversight. Also R92 closure retrospective. | `design/networking/ipv6-deferral.md` (new), `design/round-retrospectives/r92-closure.md` (new) | n/a | S | all R92.M1–M3 |

**R92 total: 9 issues.**

---

## 7. R93 — DHCP + UDP socket completion + DNS

**Depends on:** R92 (route table must be mutable before DHCP can write to it).

### R93.M1 — DHCP client (6 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R93.M1-001 | DHCP message parse/build (RFC 2131 §2/§3: op/htype/hlen/xid/... + options list; minimal option set: 53 msg-type, 50 requested-IP, 54 server-id, 51 lease-time, 1 subnet-mask, 3 router, 6 DNS-server). | `net/dhcp.pdx` (new) | n/a | L | R92.M1 |
| R93.M1-002 | DISCOVER → OFFER: broadcast DISCOVER from `0.0.0.0:68` to `255.255.255.255:67`, parse the first OFFER. | `net/dhcp.pdx` | n/a | M | R93.M1-001 |
| R93.M1-003 | REQUEST → ACK: broadcast REQUEST echoing the offered IP + server-id, parse ACK, extract lease/gateway/subnet/DNS. | `net/dhcp.pdx` | n/a | M | R93.M1-002 |
| R93.M1-004 | Wire the ACK's fields into `route_table_set` (R92.M1-002) — this is the first real mutation of the route table. Emit the `ipv4-only-policy.md` V4-D3-style informational klog line ("net dhcp ok ip=... gw=... — IPv4-only lease, no IPv6 RA observed") rather than a warning. | `net/dhcp.pdx`, `net/route_table.pdx` | `R93 DHCP LEASE OK ip=%d.%d.%d.%d` | S | R93.M1-003 |
| R93.M1-005 | Boot-time policy: run DHCP synchronously before any other net-dependent boot witness, with a bounded timeout (e.g. 3 retries × 4s) falling back to the R27 hardcoded 10.0.0.2/24 static config if no lease arrives — QEMU SLIRP always answers, but a real-hardware boot must not hang forever. | `boot/kernel_main.pdx`, `net/dhcp.pdx` | `R93 DHCP TIMEOUT FALLBACK STATIC` | M | R93.M1-004 |
| R93.M1-006 | Send ARP announce (R92.M2-001) immediately after lease acquisition. | `net/dhcp.pdx` | n/a | XS | R93.M1-004, R92.M2-001 |

### R93.M2 — UDP socket completion (5 issues)

Implements §4.4's decision to unify UDP onto TCP's syscall-resolution
posture.

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R93.M2-001 | New `KIND_UDP_SOCKET` ordinal in the modern 0x1xx scheme (§10); mark the old `0x50` value superseded (a stale reference must fail a build-time grep check, not silently alias). | `cap/kind.pdx`, `cap/udp_socket_cap.pdx` | n/a | M | none |
| R93.M2-002 | `udp_socket_resolve` mirroring `tcp_socket_resolve`'s direct cap-table-slot resolution; drop the IPC-RPC delivery path R27.M6 stubbed. | `net/udp_socket.pdx` (new) | n/a | M | R93.M2-001 |
| R93.M2-003 | Real per-port UDP RX dispatch: `udp_rx_handle` looks up a bound `KIND_UDP_SOCKET` by destination port instead of hardcoding port 7; port-7 echo becomes an ordinary bound socket rather than special-cased code. | `net/udp.pdx` | n/a | M | R93.M2-002 |
| R93.M2-004 | `sys_sendto`/`sys_recvfrom` syscalls (new numbers, §11) — UDP's first send/recv syscalls; also usable by TCP as the general form (`sys_send`/`sys_recv` stay as the connected-socket shorthand). | `syscall/handlers/sys_{sendto,recvfrom}.pdx` (new) | n/a | M | R93.M2-003 |
| R93.M2-005 | `sys_bind` extended to accept `KIND_UDP_SOCKET` (today TCP-only); `sys_socket(AF_INET, SOCK_DGRAM, 0)` path. | `syscall/handlers/sys_{socket,bind}.pdx` | n/a | S | R93.M2-002 |

### R93.M3 — DNS resolver stub (4 issues)

Deliberately minimal per §3's reconciliation — `dns-cache.md`'s full
LRU/per-user-namespace design is explicitly NOT built here.

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R93.M3-001 | DNS message parse/build (RFC 1035 §4: header + question + minimal A-record answer parse; no compression-pointer following beyond one hop, no AAAA, no DNSSEC). | `net/dns.pdx` (new) | n/a | M | R93.M2-004 |
| R93.M3-002 | `dns_resolve(hostname) -> u32 ip` — single UDP query to the route table's `dns_ip` (from DHCP), fixed 2s timeout, one retry, no cache (a repeat lookup re-queries — explicitly acceptable at this scope). | `net/dns.pdx` | n/a | M | R93.M3-001 |
| R93.M3-003 | Negative-result and malformed-response handling (NXDOMAIN, truncated response, wrong transaction ID) — refuse cleanly, don't crash or loop. | `net/dns.pdx` | n/a | S | R93.M3-002 |
| R93.M3-004 | Note in `design/networking/r91-plan.md`'s successor doc (or a new `design/network/dns-stub-vs-cache.md`) that `dns-cache.md`'s full design is the target once a resolver is worth professionalizing — this stub is not that resolver. | `design/network/dns-stub-vs-cache.md` (new) | n/a | XS | R93.M3-002 |

### R93.M4 — boot witness + closure (2 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R93.M4-001 | Boot witness: after DHCP lease, resolve a hardcoded hostname against QEMU SLIRP's DNS (`10.0.2.3`), print `net dns ok ip=x.x.x.x`. Wire into `run-smoke.sh` as `boot_r93_udp_dns`. | `boot/witness/r93_udp_dns.pdx` (new), `tools/run-smoke.sh`, `tests/expected-r93-udp-dns.golden` (new) | `R93 DNS RESOLVE OK ip=%d.%d.%d.%d` | M | R93.M3-002, R93.M1-004 |
| R93.M4-002 | R93 closure retrospective. | `design/round-retrospectives/r93-closure.md` (new) | n/a | S | all R93.M1–M3 |

**R93 total: 17 issues.**

---

## 8. R94 — TCP hardening (wire what R72 already built but left unwired)

**Depends on:** R92 (real NIC path for the off-box witness), not R93.

This round is smaller than a from-scratch TCP round would be, because
R72 already landed the state machine, TCB pool, and Reno-lite congestion
control (§1). The gaps are specifically the primitives `tcp-substrate.md`
itself flagged as "exported but not wired" or "honesty note: only replays
control segments."

### R94.M1 — retransmit timer wiring (2 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R94.M1-001 | Hook `tcp_poll_retransmits` into the existing LAPIC tick path (`int/exceptions.pdx` per `tcp-substrate.md`'s own note on where this belongs) — bounded cost: 64-TCB scan gated to run only every N ticks (e.g. every 10th tick, ~100ms) to keep the interrupt hot path cheap. | `int/exceptions.pdx`, `net/tcp.pdx` | n/a | M | none |
| R94.M1-002 | Witness: force an RTO by dropping a segment in a test harness (or, since QEMU SLIRP rarely drops, by adding a debug-only artificial-loss knob gated behind a build flag) and confirm a control-segment retransmit fires within one tick window. | `boot/witness/r94_retransmit.pdx` (new) | `R94 TCP RETRANSMIT OK` | M | R94.M1-001 |

### R94.M2 — data retransmit replay buffer (3 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R94.M2-001 | Wire `tcp_send_segment`'s payload copy into the already-declared `_tcp_tx_buf_table` (declared at R72, never populated). | `net/tcp.pdx` | n/a | M | R94.M1-001 |
| R94.M2-002 | `tcp_retransmit_last` reads the cached payload bytes instead of resending a zero-length control segment when the TCB has outstanding unacked data. | `net/tcp.pdx` | n/a | M | R94.M2-001 |
| R94.M2-003 | Witness: send a multi-segment payload, force a mid-stream RTO, verify the retransmitted segment carries the original bytes (not a zero-length probe). | `boot/witness/r94_data_retransmit.pdx` (new) | `R94 TCP DATA RETRANSMIT OK` | M | R94.M2-002 |

### R94.M3 — TIME_WAIT 2MSL + half-close (3 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R94.M3-001 | TIME_WAIT holds the TCB for a bounded 2MSL-equivalent tick count (e.g. 2×RTO, not RFC 793's literal 4-minute MSL — too long for a kernel-native fixed-size TCB pool with no dynamic growth) before freeing, instead of freeing immediately. | `net/tcp.pdx` | n/a | M | R94.M1-001 (needs the tick hook) |
| R94.M3-002 | `sys_shutdown`'s `how` argument (currently ignored) distinguishes `SHUT_RD`/`SHUT_WR`/`SHUT_RDWR`, enabling real half-close. | `syscall/handlers/sys_shutdown.pdx`, `net/tcp.pdx` | n/a | M | none |
| R94.M3-003 | Witness: half-close one direction, verify the other direction still delivers data, then full-close and verify TIME_WAIT holds the TCB for the bounded window before the slot frees. | `boot/witness/r94_half_close.pdx` (new) | `R94 TCP HALF CLOSE OK` | M | R94.M3-001, R94.M3-002 |

### R94.M4 — blocking accept()/recv() (3 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R94.M4-001 | `sys_accept` blocks (via `wake_block.pdx`, per §4.5) when no connection is pending, instead of returning `-EAGAIN`; woken by the RX path when a listener's backlog fills. | `syscall/handlers/sys_accept.pdx`, `net/tcp.pdx`, `sched/wake_block.pdx` | n/a | L | R93 (not hard-blocking, but exercised by real client traffic) |
| R94.M4-002 | `sys_recv`/`sys_recvfrom` block when no data is available and the socket is not explicitly non-blocking (a new `O_NONBLOCK`-equivalent flag on `sys_socket`, defaulting to blocking — matches the brief's "blocking vs non-blocking semantics" ask). | `syscall/handlers/sys_{recv,recvfrom}.pdx`, `net/tcp.pdx` | n/a | L | R94.M4-001 |
| R94.M4-003 | Witness: a real off-box TCP client blocks in `accept()`/`recv()` across a real RTT to QEMU SLIRP rather than busy-polling `-EAGAIN`. | `boot/witness/r94_blocking_accept.pdx` (new) | `R94 TCP BLOCKING OK` | M | R94.M4-002 |

### R94.M5 — RFC 6298 Karn's algorithm + backoff (2 issues)

Explicitly staying with Reno-lite (§0.1) but fixing the fixed-1s-RTO gap
`tcp-substrate.md` flagged.

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R94.M5-001 | RTT sampling (SRTT/RTTVAR per RFC 6298 §2) on ACKs that unambiguously ack a non-retransmitted segment (Karn's algorithm — a retransmitted segment's ACK does not update RTT, resolving retransmission ambiguity). | `net/tcp.pdx` | n/a | M | R94.M2 |
| R94.M5-002 | Exponential backoff on repeated RTO (double RTO up to a cap, e.g. 60s) instead of the fixed 1s always. | `net/tcp.pdx` | n/a | S | R94.M5-001 |

### R94.M6 — real off-box TCP witness (3 issues)

The first time TCP's handshake/data/close cycle runs through a real NIC.

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R94.M6-001 | Boot witness: real TCP connect (via `sys_connect`, not the R72 direct-TCB-call style) to a QEMU SLIRP-forwarded port (`hostfwd`), 3-way handshake through the real NIC ring. | `boot/witness/r94_tcp_offbox.pdx` (new) | `R94 TCP OFFBOX HANDSHAKE OK` | L | R92.M3, R94.M1–M4 |
| R94.M6-002 | Same witness sends `"GET / HTTP/1.0\r\n\r\n"`, reads a response, verifies non-zero byte count. | `boot/witness/r94_tcp_offbox.pdx` | `R94 TCP OFFBOX ROUNDTRIP OK bytes=%d` | M | R94.M6-001 |
| R94.M6-003 | Wire into `run-smoke.sh` as `boot_r94_tcp_offbox`; requires `tools/run-qemu.sh` `hostfwd` support (new flag, e.g. `PAIDEIA_HOSTFWD=tcp::8080-:80` forwarding to a throwaway local HTTP server the smoke harness starts). | `tools/run-smoke.sh`, `tools/run-qemu.sh` | n/a | M | R94.M6-002 |

**R94 total: 16 issues.**

---

## 9. R95 — socket syscall completion + poll

**Depends on:** R93.M2 (UDP sockets), R94.M4 (blocking + `wake_block` integration).

### R95.M1 — getsockopt/setsockopt (2 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R95.M1-001 | `sys_setsockopt`: minimal option set — `SO_REUSEADDR` (bool, relevant once a server workload rebinds a TIME_WAIT'd port), `O_NONBLOCK`-equivalent (ties to R94.M4-002's flag), `TCP_NODELAY` (disables any future Nagle — R72 never implemented Nagle, so this is a no-op today but reserves the option number for when it might). | `syscall/handlers/sys_setsockopt.pdx` (new) | n/a | M | R94.M4 |
| R95.M1-002 | `sys_getsockopt`: `SO_ERROR` (last async error, e.g. a failed non-blocking connect), `SO_TYPE` (SOCK_STREAM/SOCK_DGRAM). | `syscall/handlers/sys_getsockopt.pdx` (new) | n/a | S | R95.M1-001 |

### R95.M2 — getpeername/getsockname (2 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R95.M2-001 | `sys_getpeername`: read remote (ip, port) off the resolved TCB/UDP-socket row. | `syscall/handlers/sys_getpeername.pdx` (new) | n/a | S | none |
| R95.M2-002 | `sys_getsockname`: read local (ip, port); for an unbound socket, return the route table's `my_ip` with port 0. | `syscall/handlers/sys_getsockname.pdx` (new) | n/a | S | R92.M1 |

### R95.M3 — poll (3 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R95.M3-001 | `sys_poll(fds[], nfds, timeout_ms) -> nready`: readiness check across a small fixed-size array of (fd, events) pairs — `POLLIN` (data pending / connection pending on a listener), `POLLOUT` (send buffer has room), `POLLERR`. Reuses `wake_block.pdx`'s wait/wake primitive rather than a new one (§4.5). | `syscall/handlers/sys_poll.pdx` (new) | n/a | L | R94.M4 |
| R95.M3-002 | TCP/UDP RX and TX-completion paths call the wake side of `wake_block` so a blocked `poll` actually returns promptly instead of only on the next scheduler tick. | `net/tcp.pdx`, `net/udp_socket.pdx`, `sched/wake_block.pdx` | n/a | M | R95.M3-001 |
| R95.M3-003 | Witness: `poll()` on a socket with no data returns 0 within the timeout window; `poll()` on a socket that receives data mid-wait wakes promptly. | `boot/witness/r95_poll.pdx` (new) | `R95 POLL OK` | M | R95.M3-002 |

### R95.M4 — rights model (3 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R95.M4-001 | `R_SOCKET_READ`/`R_SOCKET_WRITE`/`R_SOCKET_LISTEN`/`R_SOCKET_CONNECT` rights bits on `KIND_TCP_SOCKET`/`KIND_TCP_LISTENER`/`KIND_UDP_SOCKET`; each syscall handler checks the relevant bit before touching the TCB/socket row (today any cap holder can do anything to the socket it names — no refinement rights exist at all). | `cap/kind_tcp_socket.pdx` (new — backfilling what R72 should have had), `cap/udp_socket_cap.pdx` | n/a | L | R93.M2.001 |
| R95.M4-002 | `sys_socket`'s default mint grants all four rights (matches today's de-facto behavior — this issue is additive, not a behavior change, setting up R96's privileged-port gate to actually have a bit to check). | `syscall/handlers/sys_socket.pdx` | n/a | S | R95.M4-001 |
| R95.M4-003 | Round closure. | `design/round-retrospectives/r95-closure.md` (new) | n/a | S | all R95.M1–M3 |

**R95 total: 11 issues.**

---

## 10. R96 — security / capability hardening

**Depends on:** R95.M4 (rights bits must exist before a privileged-port gate can check one).

### R96.M1 — MAC-address spoofing policy (2 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R96.M1-001 | Decision + doc: hard-refuse-in-driver (not a rights bit). Rationale: a MAC-spoof capability is meaningless without a corresponding "trust this MAC" concept anywhere else in the stack (no bridging, no VLAN, no multi-tenant NIC sharing at this scope per `stack.md` NET-D15's Phase-3+ deferral) — a rights bit would gate a feature nothing consumes. Document at `design/networking/mac-spoof-policy.md`. | `design/networking/mac-spoof-policy.md` (new) | n/a | S | none |
| R96.M1-002 | Implementation: the L2 TX path always sources `src_mac` from the active NIC's burned-in address (`_e1000e_devices[0].mac` / virtio-net's `device_cfg` MAC / rtl8139's IDR registers) — there is no code path today that lets a caller override it, so this issue is primarily a confirming assertion + a unit witness that a crafted TX request cannot alter the emitted source MAC. | `net/l2_tx.pdx`, `boot/witness/r96_mac_confine.pdx` (new) | `R96 MAC CONFINE OK` | S | R96.M1-001 |

### R96.M2 — DMA / IOMMU domain verification (3 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R96.M2-001 | Audit: confirm whether e1000e's RX/TX ring buffers are actually mapped through an R22/R25 VT-d domain today, or whether the "simplifies R25 IOMMU-domain mapping" comments in `rx_ring.pdx` are aspirational. Report findings even if the answer is "not wired" — this is a verification issue, its output may be a bug report rather than a fix. | none (audit) | n/a | M | none |
| R96.M2-002 | If R96.M2-001 finds the domain is not wired: mint a `KIND_DMA_DOMAIN` for the active NIC's ring + buffer pool pages via the same `driver_table_set_domain` mechanism R29 built for other drivers, confining NIC DMA to its own IOMMU domain. | `boot/kernel_main.pdx`, `driver/driver_table.pdx` (call site only) | `R96 NIC DMA DOMAIN OK` | L | R96.M2-001 |
| R96.M2-003 | Extend R96.M2-002's confinement to virtio-net and rtl8139's ring/buffer allocations. | `drivers/virtio_net/*.pdx`, `drivers/rtl8139/*.pdx` | n/a | M | R96.M2-002 |

### R96.M3 — packet filter: reserve, do not implement (1 issue)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R96.M3-001 | Reserve `KIND_PACKET_FILTER` ordinal (§10) as **design-only** — no implementation this wave. Doc cites `design/network/filter-chain.md`'s already-decided chain semantics (numeric priority, `Drop` short-circuits, `Accept` continues, tie-break by registration order) as the spec a future implementation must follow; explicitly do not re-derive chain-ordering policy. | `design/architecture/next-wave-derived-kinds.md` (reservation row only) | n/a | XS | none |

### R96.M4 — privileged port enforcement (1 issue)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R96.M4-001 | `R_NET_PRIVILEGED_PORT` rights bit; `sys_bind` refuses `local_port < 1024` unless the caller's socket cap carries the bit. Root-minted sockets (today's only mint path — no elevation broker hookup yet) get the bit by default; a future `KIND_USER`-scoped elevation (per R48's `svc.elevate-broker`) is the natural place to gate this for non-root callers, noted as follow-up rather than built here. | `syscall/handlers/sys_bind.pdx`, `cap/kind_tcp_socket.pdx` | n/a | M | R95.M4-001 |

### R96.M5 — round closure (1 issue)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R96.M5-001 | Round closure retrospective. | `design/round-retrospectives/r96-closure.md` (new) | n/a | S | all R96.M1–M4 |

**R96 total: 8 issues.**

---

## 11. R97 — TLS placement decision + kernel-side wire support

### 11.1 The decision

**Recommendation: user-space, not in-kernel.** This is not a novel
judgment call — it ratifies an existing decision (§3): `design/network/
stack.md` §8 (NET-D6) already specifies a separate `tls-server` process
holding long-term keys, explicitly rejecting a kTLS-style in-kernel
integration (§8.3: "a `net-stack` CVE doesn't leak keys" / "TLS server
can be updated independently" / "multiple TLS implementations can
coexist"). Independently, the paideia-as crypto substrate (§1's table)
reconfirms it from a different angle: today paideia-as has `ChaCha20-
Poly1305` AEAD, `Argon2id` KDF, and `MlDsa65` signing — but **no SHA-256/
HMAC/HKDF, no X25519/ECDH, and no ECDSA/RSA verification**. A real TLS
1.3 handshake against an actual Internet HTTPS server needs, at minimum,
HKDF-SHA256 (the TLS 1.3 key schedule, RFC 8446 §7.1) and the ability to
verify the server's certificate chain, which for the overwhelming
majority of deployed servers means ECDSA-P256 or RSA verification — pure
classical primitives paideia-as has never had, and PaideiaOS's own PQ
posture (Pillar 6) has never asked for, since its signature intrinsic is
ML-DSA-65 (a scheme no public web server presents). Building all of that
into the kernel now, in the same wave as the first-ever real-NIC
verification, would compound two large, independently risky changes.

**Kernel-side consequence:** nothing new to build for TLS itself. The
user-space curl-like tool (sibling softarch wave) does the TLS 1.3
handshake and record layer entirely in its own address space, using
paideia-as's landed `ChaCha20-Poly1305` (a mandatory TLS 1.3 cipher
suite, RFC 8446 §9.1) once it also has HKDF-SHA256 and a certificate
verifier — both flagged as cross-repo escalations (§13), not blocking
this wave, since R91–R99's own boot witnesses use plain HTTP against a
QEMU-local responder (§13's witness plan), not real HTTPS.

### R97.M1 — decision doc (1 issue)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R97.M1-001 | `design/networking/tls-placement-decision.md`: formalize §11.1's decision, cite `stack.md` NET-D6 and the paideia-as crypto-substrate gap; explicitly state this is a ratification, not a fresh design. | `design/networking/tls-placement-decision.md` (new) | n/a | S | none |

### R97.M2 — reserve `KIND_TLS_CONN` for later (1 issue)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R97.M2-001 | Reserve the ordinal (§10) **unimplemented**, explicitly for a future in-kernel PQ-hybrid TLS round (per `design/security/pq-trust-root.md`'s universal hybrid KEM, once paideia-as gains the classical primitives to interoperate with real servers, or once enough of the Internet supports PQ-hybrid key exchange directly that a from-scratch PQ-only handshake becomes viable without classical fallback). | `design/architecture/next-wave-derived-kinds.md` (reservation row only) | n/a | XS | R97.M1-001 |

### R97.M3 — verify the socket surface is sufficient for user-space TLS (2 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R97.M3-001 | Audit: does a user-space TLS client need anything beyond `connect`/`send`/`recv`/`poll`/`setsockopt(TCP_NODELAY)` (all landed by R95)? Check specifically for `MSG_PEEK`-equivalent (TLS record boundary detection sometimes wants to peek) and partial-write handling on `send` (R72's `send` caps at 1024B/call — confirm the curl-like tool's design doesn't assume unbounded single-call sends). | none (audit; may produce a follow-up issue) | n/a | S | R95 |
| R97.M3-002 | If R97.M3-001 finds a gap: close it (e.g. loop `sys_send` internally is a user-space concern, not a kernel gap, so this issue is likely a no-op — filed as a placeholder in case the audit disagrees). | TBD per audit | n/a | S | R97.M3-001 |

### R97.M4 — cross-repo escalation filing (1 issue)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R97.M4-001 | File paideia-as issues (§13) for HKDF-SHA256, SHA-256, and a certificate-verification primitive (ECDSA-P256 at minimum) — **not blocking this wave**, filed so the sibling softarch wave's user-space TLS work has a tracked dependency rather than discovering the gap mid-implementation. | (paideia-as issues, not this repo) | n/a | S | R97.M1-001 |

### R97.M5 — round closure (1 issue)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R97.M5-001 | Round closure. | `design/round-retrospectives/r97-closure.md` (new) | n/a | S | all R97.M1–M4 |

**R97 total: 6 issues.**

---

## 12. R98 — boot witnesses + smoke matrix (integration round)

**Depends on:** R91 (NIC), R93 (DHCP/DNS), R94 (TCP off-box), R95 (poll —
useful for a well-behaved HTTP witness that doesn't busy-poll).

### R98.M1 — full smoke-matrix wiring (2 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R98.M1-001 | Consolidate R91.M5-003 (`boot_r91_nic`), R93.M4-001 (`boot_r93_udp_dns`), R94.M6-003 (`boot_r94_tcp_offbox`) into a single documented "networking smoke lane" section in `run-smoke.sh`, run in sequence (NIC probe → DHCP/DNS → TCP roundtrip) since each depends on the previous succeeding. | `tools/run-smoke.sh` | n/a | M | R91, R93, R94 |
| R98.M1-002 | Gate the networking smoke lane behind an opt-in env var (`PAIDEIA_NET_SMOKE=1`), matching the existing `PAIDEIA_R72_TCP=1` precedent in `.githooks/pre-push` — real-NIC QEMU boots are slower and flakier (SLIRP DNS/DHCP timing) than the rest of the smoke suite, so this should not be an unconditional pre-push gate. | `.githooks/pre-push`, `tools/run-smoke.sh` | n/a | S | R98.M1-001 |

### R98.M2 — HTTP roundtrip witness (2 issues)

Task brief asks for "a known-open port" via SLIRP hostfwd; R94.M6 already
built the mechanics. This milestone is the polish pass: golden output,
byte-count assertion, and a documented throwaway local HTTP responder the
smoke harness starts (rather than depending on a live Internet host,
which `run-smoke.sh`'s CI-adjacent local-only philosophy per `[[feedback_paideia_os_no_cicd]]`
already rules out).

| Issue | One-liner | Files touched | Fingerprint | Effort | Effort | Deps |
|---|---|---|---|---|---|---|
| R98.M2-001 | `tools/net-smoke-httpd.sh` (or similar): a minimal local HTTP/1.0 responder (bash+nc, or a tiny paideia-as-independent script) the smoke harness starts before boot and stops after, bound to the port `hostfwd` forwards. | `tools/net-smoke-httpd.sh` (new) | n/a | S | — | R94.M6-003 |
| R98.M2-002 | Golden-file assertion on the exact byte count / a fixed known response body, not just "non-zero bytes" — tightens R94.M6-002's assertion now that the responder is deterministic. | `tests/expected-r94-tcp-offbox.golden` | n/a | S | — | R98.M2-001 |

### R98.M3 — permanent QEMU networking flags + docs (2 issues)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R98.M3-001 | Consolidate R91.M2-004/R91.M5-002/R94.M6-003's incremental `run-qemu.sh` flag additions into one documented `PAIDEIA_NIC=`/`PAIDEIA_HOSTFWD=` interface with a `--help`-visible summary (the R91-R94 issues added flags piecemeal; this issue is the cleanup pass). | `tools/run-qemu.sh` | n/a | S | R91.M5-002, R94.M6-003 |
| R98.M3-002 | Document the full networking QEMU invocation (`-netdev user,id=n1 -device virtio-net-pci,netdev=n1 -netdev user,id=n1,hostfwd=tcp::8080-:80`-shape) in `design/networking/qemu-net-invocation.md` so main and future contributors don't have to reverse-engineer the flags from `run-qemu.sh`. | `design/networking/qemu-net-invocation.md` (new) | n/a | S | R98.M3-001 |

### R98.M4 — round closure (1 issue)

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R98.M4-001 | Round closure. | `design/round-retrospectives/r98-closure.md` (new) | n/a | S | all R98.M1–M3 |

**R98 total: 7 issues.**

---

## 13. R99 — wave closure

| Issue | One-liner | Files touched | Fingerprint | Effort | Deps |
|---|---|---|---|---|---|
| R99.M1-001 | Wave-level retrospective covering R91–R98 as a unit (separate from each round's own closure doc) — what shipped, what's still deferred (IPv6, QUIC, BBRv3, in-kernel TLS, packet filter implementation, the Phase-2 userspace `net-stack` migration per §0.2), and the concrete "next wave" pointer for whoever picks up IPv6 or the Phase-2 migration. | `design/round-retrospectives/r91-r99-wave-closure.md` (new) | n/a | M | all R91–R98 |
| R99.M1-002 | `STATUS.md` update + tag `r99-closed` (or per-round tags `r91-closed`..`r99-closed` if the project's tagging convention wants one per round — match whatever R89/R84/R51 actually did rather than inventing a wave-tag convention here). | `STATUS.md` | n/a | S | R99.M1-001 |

**R99 total: 2 issues.**

---

## 14. Cross-repo escalations (paideia-as)

None of these block R91–R99 — the plan is scoped to avoid needing them
(§0.1, §11). Filed for the sibling softarch wave's user-space TLS work
and for general hygiene:

1. **Verify `@jump_table` is lowered, not just forward-declared** (R91.M1-002's
   first step). If it turns out to still be forward-declaration-only,
   file a paideia-as issue to either land the lowering or explicitly
   document it as not-yet-usable — do not let a second feature quietly
   depend on a half-landed attribute the way `FreelistOps`/`BitmapOps`
   did in the Net-primitives release.
2. **HKDF-SHA256** (RFC 8446 §7.1 key schedule) — needed by user-space
   TLS 1.3. Not present in paideia-as today (verified via CHANGELOG grep,
   §1).
3. **SHA-256** — needed as HKDF's underlying hash and for TLS transcript
   hashing. Not present (paideia-as has no SHA-2 family intrinsic at
   all; the one confirmed hash-adjacent primitive is an unspecified SHA3
   construction implied by `KIND_USER`'s "SHA3-256 fp" language in
   `next-wave-derived-kinds.md`, itself unverified as a paideia-as
   intrinsic versus hand-rolled `.pdx`).
4. **Certificate verification primitive** (ECDSA-P256 minimum; RSA-2048
   PKCS#1v1.5/PSS for broader compatibility) — needed to validate a real
   server's X.509 chain. Classical, not PQ — a genuine tension with
   Pillar 6's PQ-first posture that the escalation issue should name
   explicitly rather than paper over: the pragmatic reality is that
   almost no public HTTPS server offers a PQ-only certificate today, so
   "reach the Internet" requires classical verification regardless of
   PaideiaOS's own preferences. Frame the ask as "the classical bridge
   primitive needed for interop," not a reversal of Pillar 6.
5. **X25519** (or defer entirely to a PQ-hybrid combiner per `pq-trust-
   root.md` §7's X25519+ML-KEM-1024, which needs X25519 anyway) — needed
   for the TLS 1.3 key exchange with any real-world server, since
   virtually no public server offers pure ML-KEM key exchange yet.

None of these are filed as blocking R91–R99; they are filed (R97.M4-001)
so the softarch wave's TLS design has tracked dependencies from day one
rather than discovering the gap mid-implementation, per `[[feedback_cross_repo_escalation]]`'s
file-early principle.

---

## 15. Sibling-round dependency map

| This wave needs... | From... | Status |
|---|---|---|
| PCI enumeration (`_pci_devices` populated) | R22 (PCIe tree) | Landed, but R91.M2-001 must verify it actually populates under whatever boot path this tree uses today — e1000e's own probe comment says it stays empty under `-kernel` direct boot. |
| VT-d / IOMMU domain infrastructure | R22/R25 | Landed as infrastructure (`driver_table_set_domain` etc.); R96.M2 verifies/wires it for NICs specifically — not previously done for e1000e despite comments suggesting it was "simplified for." |
| Driver lifecycle FSM / `driver_table.pdx` | R29 | Landed; R91.M2-002/M5-001 use it only as a visibility shim (§4.2), not a functional dependency. |
| `wake_block.pdx` scheduler primitive | R17 (`sys_wait4` precedent) | Landed; R94.M4/R95.M3 depend on it directly. |
| `KIND_USER`/elevate-broker (for future non-root privileged-port grants) | R48 | Landed; R96.M4 notes it as follow-up, not a hard dependency (root-minted sockets get the bit by default this wave). |
| R51 (NVMe/AHCI) | — | **No dependency either direction.** Confirmed per the task brief's own suspicion. |
| R64v2 (volume tooling) | — | **No dependency either direction.** |
| R65v2 (persistent home / storage) | — | **Soft dependency, not filed here**: DHCP lease persistence and `/etc/resolv.conf`-equivalent persistence across reboots would consume R65v2's persistent storage once it exists, but R93's DHCP/DNS re-acquire on every boot (matching the "no NAT/no persistence Phase 1–2" posture of `stack.md` §12.4) — explicitly not blocked on R65v2, just noting the natural future consumer. |

---

## 16. KIND ordinal reservations

Backfills two undocumented-but-landed R72 kinds, then reserves five new
ordinals. Applied directly to `design/architecture/next-wave-derived-kinds.md`
(see the diff applied alongside this plan).

| Tag | Kind name | Parent (base) | Purpose | Discipline | Landed at |
|---|---|---|---|---|---|
| 0x1A4 | `KIND_TCP_LISTENER` | `KIND_IPC_ENDPOINT = 5` | *(backfill)* A `KIND_TCP_SOCKET` retagged in place after `listen()`. Root-minted. | derived | R72 (already shipped; this plan only documents it) |
| 0x1A5 | `KIND_TCP_SOCKET` | `KIND_IPC_ENDPOINT = 5` | *(backfill)* Active or not-yet-connected TCP socket. Root-minted. | derived | R72 (already shipped; this plan only documents it) |
| 0x1A7 | `KIND_NIC` | `KIND_DEVICE = 10` | Device-level NIC authority: active backend selector (e1000e/virtio-net/rtl8139), MAC, link state. | derived | R91.M1-001 (new) |
| 0x1A8 | `KIND_UDP_SOCKET` | `KIND_IPC_ENDPOINT = 5` | Modern re-registration superseding the pre-R30-scheme `0x50` value (§4.4). Root-minted, mirrors `KIND_TCP_SOCKET`. | derived | R93.M2-001 (new) |
| 0x1A9 | `KIND_PACKET_FILTER` | `KIND_IPC_ENDPOINT = 5` | *(reserved, unimplemented)* Future packet-filter-chain installation authority per `design/network/filter-chain.md`. | reserved | R96.M3-001 (reservation only) |
| 0x1AA | `KIND_TLS_CONN` | `KIND_TCP_SOCKET = 0x1A5` | *(reserved, unimplemented)* Future in-kernel PQ-hybrid TLS connection, pending paideia-as classical-bridge primitives (§13). | reserved | R97.M2-001 (reservation only) |

**Note on 0x1A6:** already claimed by `KIND_TUI_CANVAS` (R89) — confirmed
via `r89-closure.md`. `KIND_NIC` therefore starts at 0x1A7, not 0x1A6.
**Verify at filing time** that no intervening ordinal was claimed between
this research and issue filing (the same gap that let 0x1A4/0x1A5 go
undocumented could recur) — a quick grep for `0x1A[6-9]|0x1AA` across
`src/kernel/core/cap/kind.pdx` immediately before filing is cheap
insurance.

---

## 17. Syscall reservations

Next free syscall number is **96** (95 = `sys_kill`, per `design/user/
syscall-table.md`'s current table). Applied directly to that file (see
the diff applied alongside this plan).

| # | Syscall | Args | Notes |
|---|---|---|---|
| 96 | `sendto` | `fd`, `buf`, `len`, `dst_ip`, `dst_port` | UDP's first send path; also usable by TCP (dst args ignored on a connected socket). |
| 97 | `recvfrom` | `fd`, `buf`, `len`, `src_ip_out`, `src_port_out` | UDP's first recv path. |
| 98 | `getsockopt` | `fd`, `level`, `optname`, `optval_ptr`, `optlen_ptr` | `SO_ERROR`, `SO_TYPE` at R95. |
| 99 | `setsockopt` | `fd`, `level`, `optname`, `optval_ptr`, `optlen` | `SO_REUSEADDR`, `O_NONBLOCK`-equivalent, `TCP_NODELAY` at R95. |
| 100 | `getpeername` | `fd`, `sockaddr_out` | |
| 101 | `getsockname` | `fd`, `sockaddr_out` | |
| 102 | `poll` | `fds_ptr`, `nfds`, `timeout_ms` | Fixed-size array, no dynamic `nfds` allocation. |

**No new syscall for DHCP/DNS configuration read-back** — deliberately
descoped. A future `/proc`-or-`sysctl`-equivalent read path for the route
table (my_ip/gw/dns/lease) is the natural mechanism once one exists; this
wave's boot witnesses read the route table directly (kernel-internal),
and user-space has no need to read it back within this wave's scope
(the curl-like tool gets its server's IP from `sys_connect`'s own DNS-
resolved argument, not by inspecting the kernel's lease).

---

## 18. Boot witnesses + smoke matrix summary

| Witness | Round | Fingerprint | `run-smoke.sh` mode |
|---|---|---|---|
| NIC probe (real ring, real MAC) | R91.M5-003 | `R91 NIC PROBE LIVE OK` | `boot_r91_nic` |
| Route table live-mutation unit check | R92.M1-003 | `R92 ROUTE TABLE OK` | (unit-level, not smoke-gated) |
| ICMP ping through real NIC | R92.M3-001 | `R92 ICMP PING OK rtt_ticks=%d` | `boot_r92_icmp` |
| DHCP lease + DNS resolve | R93.M4-001 | `R93 DNS RESOLVE OK ip=%d.%d.%d.%d` (DHCP's own `R93 DHCP LEASE OK` fires first as a precondition) | `boot_r93_udp_dns` |
| TCP retransmit (control) | R94.M1-002 | `R94 TCP RETRANSMIT OK` | (unit-level) |
| TCP retransmit (data) | R94.M2-003 | `R94 TCP DATA RETRANSMIT OK` | (unit-level) |
| TCP half-close + TIME_WAIT | R94.M3-003 | `R94 TCP HALF CLOSE OK` | (unit-level) |
| TCP blocking accept/recv | R94.M4-003 | `R94 TCP BLOCKING OK` | (unit-level) |
| TCP off-box handshake + HTTP roundtrip | R94.M6-001/002 | `R94 TCP OFFBOX HANDSHAKE OK` / `R94 TCP OFFBOX ROUNDTRIP OK bytes=%d` | `boot_r94_tcp_offbox` |
| poll() readiness | R95.M3-003 | `R95 POLL OK` | (unit-level) |
| MAC confinement | R96.M1-002 | `R96 MAC CONFINE OK` | (unit-level) |
| NIC DMA domain | R96.M2-002 | `R96 NIC DMA DOMAIN OK` | (unit-level) |

**QEMU flags needed** (consolidated at R98.M3, introduced incrementally
R91–R94): `-netdev user,id=n1[,hostfwd=tcp::8080-:80] -device
{e1000e,virtio-net-pci,rtl8139},netdev=n1[,mac=<fixed>]`. QEMU's
user-mode (SLIRP) networking backend supplies DHCP (`10.0.2.2` gateway,
lease pool from `10.0.2.15`), DNS (`10.0.2.3`), and `hostfwd` port
forwarding for the HTTP witness — no external network access is required
to run any witness in this plan.

**Opt-in, not unconditional**: per §12 (R98.M1-002), the full networking
smoke lane is gated behind `PAIDEIA_NET_SMOKE=1`, matching the existing
`PAIDEIA_R72_TCP=1` precedent — real-NIC QEMU boots are slower and more
timing-sensitive (DHCP/DNS round-trips) than the rest of the smoke suite.

---

## 19. Total issue count by round

| Round | Theme | Milestones | Issues |
|---|---|---:|---:|
| R91 | NIC substrate: dispatch layer, virtio-net, rtl8139, real boot wiring | 6 | 23 |
| R92 | L2/L3 completion: routing table, real off-box verification | 4 | 9 |
| R93 | DHCP + UDP socket completion + DNS | 4 | 17 |
| R94 | TCP hardening | 6 | 16 |
| R95 | Socket syscall completion + poll | 4 | 11 |
| R96 | Security/capability hardening | 5 | 8 |
| R97 | TLS placement decision + wire | 5 | 6 |
| R98 | Boot witnesses + smoke matrix | 4 | 7 |
| R99 | Wave closure | 1 | 2 |
| **Total** | | **39** | **99** |

---

*End of document.*
