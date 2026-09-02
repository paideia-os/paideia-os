# KIND_PACKET_FILTER — reservation (R96.M3-001, paideia-os #2091)

**Round:** R96.M3
**Status:** Reserved (ordinal + design pointer only). No implementation
in R96. Any future landing that adds the chain-installation authority
must inherit the chain-ordering semantics named in §3 — do not
re-decide them.

## 1. The reservation

* **Ordinal:** `KIND_PACKET_FILTER = 0x1A9`.
* **Base kind:** `KIND_IPC_ENDPOINT = 5`.
* **Row source of truth:** already present in
  `design/architecture/next-wave-derived-kinds.md` L2381 as a
  "reserved, unimplemented" entry. This document is the *reason* that
  row exists — it commits the R96 round to that ordinal and points at
  the pre-existing chain-semantics spec so a later implementation round
  starts from a settled design surface.

**Ordinal-choice note.** The R96 planning brief (2026-09-01) suggested
`0x1B4` "next after KIND_SCHEMA_HANDLE=0x1B2." This is stale — `0x1A9`
was reserved during the R91 wave (part of the R91-R99 networking
reservation block, `design/architecture/next-wave-derived-kinds.md`
L2370-2372) and has been referenced in the catalog and in `kind.pdx`
comment threads (e.g. L3012) ever since. Reusing `0x1A9` keeps the
networking reservation block contiguous and avoids abandoning a slot
that other code already names.

## 2. Why "reserved, not implemented"

Packet filtering has never been exercised by any consumer in this tree.
The current stack:

* has no bridging, VLAN, or NAT (all Phase-3+ per `design/network/stack.md`
  §0.2/§15.2);
* runs a single interface (`_ipv4_my_ip`, updated at R92.M1 to be
  DHCP-mutable but still one entry);
* has no multi-tenant NIC sharing;
* has no consumer that would install a filter chain.

Building the installation authority now would ship a kind whose only
callers are witnesses that assert the substrate is callable — no
downstream code would actually filter a packet. The reservation records
the *intent* and pins the *ordinal + base + chain semantics* so a later
round with a real consumer (typical shapes: an off-box firewall,
per-container isolation on a hypothetical multi-tenant NIC substrate,
egress policy for a `pdxcurl`-class privileged tool) does not have to
re-litigate the design.

## 3. Chain semantics — cite, do not re-decide

The chain-ordering discipline was decided at
`design/network/filter-chain.md` (FIL-D1..D6, 2026-06-17):

* **Numeric priority 0-999** — filter registrations name a priority
  integer; the chain traverses in ascending order.
* **`Drop` short-circuits** — the first rule returning `Drop` ends the
  chain; downstream rules are not consulted.
* **`Accept` continues** — an `Accept` verdict permits the frame *for
  this rule* but does not exit the chain; a later higher-priority
  `Drop` still wins.
* **Tie-break by registration order** — two rules at the same priority
  fire in the order they were registered.
* **No implicit final rule** — the chain's default is decided by the
  installer, not by the substrate; an empty chain accepts nothing (a
  policy the installer opts into, not the safest-default trap).

A future R-<n>.M<m> implementation round for `KIND_PACKET_FILTER` must
inherit this discipline verbatim. Do not re-derive it. If the
implementation round encounters a case FIL-D1..D6 does not name, the
correct move is to *extend* `design/network/filter-chain.md` with an
FIL-D7+ decision, not to duplicate ordering language here.

## 4. Rights (planning-only)

Not committed by this reservation — pinned once by the implementation
round. The strong candidate shape mirrors other install-once-consume-many
kinds (KIND_TLS_TRUST, KIND_SIG_KEY):

* `R_PF_INSTALL` (bit 0) — install a new filter rule under a chain
  identifier and priority.
* `R_PF_REVOKE` (bit 1) — remove a previously-installed rule (revokes
  the caller's own install; a supervisor cascade-revoke lands per the
  usual kind-teardown discipline).
* `R_PF_OBSERVE` (bit 2) — read the current chain state for
  introspection tools. Distinct from INSTALL/REVOKE because a monitoring
  probe should be able to enumerate rules without holding the authority
  to change them (same posture `R_DMA_OBSERVE` takes on
  KIND_DMA_DOMAIN).

## 5. Non-goals for R96

* **No `filter_chain_install` implementation.**
* **No `sys_filter_*` syscall surface.**
* **No boot witness** — a reservation is not code; no fingerprint
  emits from this doc.
* **No wire between the packet-RX path and a filter-chain traversal.**
  The chain-installation authority is meaningless without a substrate
  that actually consults the chain on every RX frame; that substrate
  landing is the same future round §3's citation names as a separate
  implementation.

## 6. Cross-references

* `design/network/filter-chain.md` — the chain-ordering spec (FIL-D1..D6).
* `design/architecture/next-wave-derived-kinds.md` L2381 — the reserved
  row this doc commits to.
* `src/kernel/core/cap/kind.pdx` L3012 — comment thread naming
  `KIND_PACKET_FILTER` as reserved at `0x1A9`.
* `design/networking/r91-plan.md` §10.M3 — planning row for this
  reservation.
