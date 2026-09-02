# R96 Retrospective: MAC-spoof policy + IOMMU audit + privileged-port gate

**Date:** 2026-09-01
**Milestones:** R96.M1 (MAC-spoof policy + witness), R96.M2 (NIC DMA /
IOMMU audit), R96.M3 (KIND_PACKET_FILTER reservation), R96.M4
(R_NET_PRIVILEGED_PORT rights bit + sys_bind gate), R96.M5 (round
closure).
**Issues closed at landing:** #2086, #2087, #2088, #2089, #2090, #2091,
#2092, #2093.
**HEAD at closure:** paideia-os (this landing).
**Release tag:** `r96-closed` recommended — the `boot r96 mac spoof
refuse ok` witness attests the MAC-spoof structural refuse on every
boot; the R_NET_PRIVILEGED_PORT gate becomes live for every socket
minted post-R96.

## Round intent

Close the "security model is aspirational-only" gap the R91 plan
(§2) named as gap #8, one round before R97 ratifies the TLS placement
decision. Three shapes of hardening: (a) a written MAC-spoof policy
that documents what the code already enforces structurally, plus a
witness proving the property observably; (b) an audit answering the
long-standing question "are NIC DMA rings actually IOMMU-domain
mapped?" (verdict: no, but the substrate that would land the wire-up
is already built); (c) a privileged-port gate that finally gives R95's
socket rights bits something to refine at mint time.

R96 lands in a single wave with R97 because R97 is design-only work
(a ratification doc, an audit disposition, a paideia-as escalation
issue) that shares no build artefacts with R96 — the two rounds are
mutually independent and closing them together keeps the R91-R99
networking-wave planning cadence tight.

## Per-milestone disposition

### R96.M1 — MAC-address spoof policy — LANDED

* **#2086 (M1-001) — Decision doc.**
  `design/networking/mac-spoof-policy.md` (new, ~130 lines). Chose
  hard-refuse-in-driver (option A) over rights-bit / cap-kind /
  ambient-toggle alternatives. Grounded in the observation that no
  in-tree consumer trusts a frame's source MAC for authentication, so
  a spoof-authorising bit would gate a feature nothing consumes — and
  its bare existence would invite a future round to accidentally wire
  a caller up.
* **#2087 (M1-002) — L2 TX src_mac hardening + witness.**
  Audit finding: `src/kernel/core/net/l2_tx.pdx` L189-301 already
  hardcodes `src_mac` from `&_e1000e_devices[0] + 24` (record `+24` =
  burned-in MAC populated by `e1000e_read_mac` at probe). The
  `l2_tx_send` signature has six arguments, none of which is
  `src_mac` — a caller has no ABI position to spoof from. No
  hardening code change was needed; the property is structural.
  New witness at `src/kernel/boot/witness/r96_mac_spoof_refuse.pdx`
  constructs a stack-local candidate MAC that a hostile caller might
  wish to emit, invokes `l2_tx_send` with a legitimate payload, reads
  the emitted frame back out of the TX buffer pool at bytes [6..11],
  and asserts the six bytes equal the six bytes at
  `_e1000e_devices+24`. Runs unconditionally (both under
  `PAIDEIA_NIC=none` and with a real NIC attached) since the property
  holds either way. Fingerprint:
  `boot r96 mac spoof refuse ok --`.

### R96.M2 — DMA / IOMMU audit — LANDED

* **#2088 (M2-001) — Audit.**
  `design/networking/iommu-audit.md` (new, ~140 lines) walks all three
  NIC drivers (e1000e, virtio-net, rtl8139). Finding: **none of the
  three currently perform bus-master DMA through an IOMMU domain.**
  All three declare their rx/tx rings and buffer pools in `.bss`
  `@align(4096)`, and the aspirational "simplifies R25 IOMMU-domain
  mapping" comment threads that motivated the alignment are just
  that — aspirational. No `vtd_slpt_map` / `vtd_ctx_program` call
  reaches a NIC BDF anywhere in the tree.
* **#2089 (M2-002) — KIND_DMA_DOMAIN reservation for NIC ring/buffer
  pool.** Spec ambiguity resolved: the R96 planning brief suggested
  reserving a new `KIND_DMA_DOMAIN` ordinal at `0x1B3`, but
  KIND_DMA_DOMAIN **already exists at 0x142 from R29**
  (`core/cap/kind_dma_domain.pdx`, R29.M5-001/002/003/004). No new
  ordinal minted. The reservation this issue records is "the wire-up
  round consumes existing kind 0x142." Wire-up itself deferred — the
  audit doc §4 documents the sketch a future round starts from.
* **#2090 (M2-003) — Extend confinement to virtio-net + rtl8139.**
  Same disposition as #2089 for the other two drivers; the audit doc
  §2.2-2.3 covers both. No code lands in R96; the wire-up round covers
  all three drivers with the same substrate.

### R96.M3 — KIND_PACKET_FILTER reservation — LANDED

* **#2091 (M3-001) — Reservation doc.**
  `design/networking/filter-chain.md` (new, ~100 lines). Ordinal
  ambiguity resolved: the planning brief suggested `0x1B4`, but
  `0x1A9` was reserved during the R91 wave and is already recorded
  in `design/architecture/next-wave-derived-kinds.md` L2381 and
  referenced in `kind.pdx` L3012's comment thread. Reused `0x1A9`;
  no new ordinal minted. Cites `design/network/filter-chain.md`
  FIL-D1..D6's already-decided chain semantics (numeric priority
  0-999, `Drop` short-circuits, `Accept` continues, tie-break by
  registration order) as the spec a future implementation round must
  inherit verbatim.

### R96.M4 — R_NET_PRIVILEGED_PORT rights bit — LANDED

* **#2092 (M4-001) — Rights bit + sys_bind gate.**
  `src/kernel/core/net/tcp_socket.pdx` and
  `src/kernel/core/net/udp_socket.pdx`: add
  `R_NET_PRIVILEGED_PORT : u64 = 0x010` (next bit after
  R_SOCKET_CONNECT = 0x008). Default mint at socket-new stays at
  `0x00F` (READ | WRITE | LISTEN | CONNECT) — the privileged-port
  bit is **not** granted by default; a caller must explicitly request
  it via a future `sys_socket` variant or `setsockopt` extension
  (deferred to a follow-up round).
  `src/kernel/core/syscall/handlers/sys_bind.pdx`: before the existing
  R_SOCKET_LISTEN check, if `local_port < 1024`, call
  `sock_cap_check_rights(fd, R_NET_PRIVILEGED_PORT)`. Refuses
  `-EACCES` (0xFFFFFFFFFFFFFFF3) if the bit is not held. Every
  post-R96 witness that binds to port `>= 1024` continues to pass
  without change; a caller trying to bind port 80 without an
  explicitly-widened cap refuses cleanly.

### R96.M5 — round closure — LANDED

* **#2093 (M5-001) — This retrospective.**

## What did NOT land in R96

* **No wire-up of NIC ring buffers into a VT-d domain.** The audit
  (M2-001) found the wire-up unbuilt and the substrate ready; the
  wire-up itself is a per-driver refactor a security-hardening round
  should not carry. Deferred to a dedicated future round — see
  `design/networking/iommu-audit.md` §4-5 for the sketch and §6 for
  the pointer.
* **No `KIND_PACKET_FILTER` implementation.** Reservation only —
  see `design/networking/filter-chain.md` §2 for the "no consumer
  today" rationale.
* **No elevation-broker hookup for the privileged-port bit.** The
  default mint drops the bit; the natural place to gate it for
  non-root callers is R48's `svc.elevate-broker`, which is
  cross-cutting and out of R96 scope. Noted as follow-up.

## Spec ambiguities resolved during landing

* **KIND_DMA_DOMAIN ordinal.** Planning brief said `0x1B3`; already
  landed at `0x142` from R29. Documented in
  `design/networking/iommu-audit.md` §4.1.
* **KIND_PACKET_FILTER ordinal.** Planning brief said `0x1B4`;
  already reserved at `0x1A9` from R91. Documented in
  `design/networking/filter-chain.md` §1.
* **KIND_TLS_CONN ordinal** (R97, not R96 but same wave). Planning
  brief said `0x1B5`; already reserved at `0x1AA` from R91.
  Documented in `design/networking/tls-placement-decision.md` §3.
* **`l2_tx.pdx` src_mac hardening.** Planning brief said "if l2_tx.pdx
  accepts a caller-provided src_mac, harden it." Audit finding: the
  API has no `src_mac` argument; hardening is structural, only the
  witness lands. Documented in
  `design/networking/mac-spoof-policy.md` §5.

## Files touched

| File | Kind | Notes |
|---|---|---|
| `design/networking/mac-spoof-policy.md` | new doc (~135 lines) | R96.M1-001 |
| `design/networking/iommu-audit.md` | new doc (~145 lines) | R96.M2-001/002/003 |
| `design/networking/filter-chain.md` | new doc (~105 lines) | R96.M3-001 |
| `design/round-retrospectives/r96-closed.md` | new doc (this file) | R96.M5-001 |
| `src/kernel/core/net/tcp_socket.pdx` | edit | R_NET_PRIVILEGED_PORT constant |
| `src/kernel/core/net/udp_socket.pdx` | edit | R_NET_PRIVILEGED_PORT constant (mirror) |
| `src/kernel/core/syscall/handlers/sys_bind.pdx` | edit | port < 1024 gate |
| `src/kernel/core/klog/keys.pdx` | edit | `tag_boot_r96_mac_spoof_refuse_ok` |
| `src/kernel/boot/witness/r96_mac_spoof_refuse.pdx` | new (~120 lines) | R96.M1-002 witness |
| `src/kernel/boot/kernel_main.pdx` | edit | call new witness |

## Cross-references

* `design/networking/r91-plan.md` §10 — the plan this round closes.
* `design/round-retrospectives/r95-closed.md` — the socket-rights
  substrate R96.M4 refines.
* `design/round-retrospectives/r97-closed.md` — sibling wave-closing
  round.
