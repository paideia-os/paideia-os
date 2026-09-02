# MAC-address spoofing policy (R96.M1-001, paideia-os #2086)

**Round:** R96.M1
**Status:** Ratified 2026-09-01. Enforced structurally by `net/l2_tx.pdx`.
**Design authorities cited:** `design/network/stack.md` NET-D15
(single-NIC phase-1/2 posture), `design/networking/r91-plan.md` §10.M1
(the framing question this doc answers).

## 1. The decision, in one line

**A caller cannot supply the source MAC on a transmit path. Full stop.
It is drawn from the active NIC's burned-in address at TX build time and
there is no ABI position for it — the property is structural, not a
rights check.**

## 2. Options considered

| Option | Shape | Verdict |
|---|---|---|
| **A. Hard-refuse in driver** (chosen) | `l2_tx_send` takes no `src_mac` argument at all; `eth_build` sources `src_mac` from `&_e1000e_devices[0] + 24` (record `+24` = burned-in MAC populated by `e1000e_read_mac` at probe). | **Chosen.** No policy branch, no gate to bypass, no rights bit to remember to mint. The API surface makes spoofing unrepresentable. |
| B. Rights bit `R_NET_SPOOF_MAC` | Ordinary rights-mask gate at TX. A trusted process asks for the bit; `l2_tx_send` accepts a caller-supplied `src_mac` when the bit is present. | Rejected — see §3. |
| C. Capability kind `KIND_MAC_SPOOF` | Separate cap type authorising per-frame src_mac override. | Rejected — same reasoning as B, plus a whole new cap kind to describe a feature no consumer needs. |
| D. Ambient policy toggle | Boot-time flag "spoofing allowed / not". | Rejected — ambient authority the capability system exists to avoid. |

## 3. Why option A wins

**A rights bit gates a feature nothing consumes.** The wider stack has
no bridging, no VLAN, no multi-tenant NIC sharing, no MAC-based access
control anywhere at this scope (all deferred to Phase-3+ per `stack.md`
§0.2/§15.2). A `R_NET_SPOOF_MAC` bit would create a gate whose
"enabled" side has no legitimate customer — and whose bare existence
signals to a future reader that some caller somewhere *does* spoof,
inviting the next round to accidentally wire one up.

**Symmetric point on the receive side:** no path in this tree trusts a
frame's source MAC for authentication. ARP-cache poisoning is
constrained by the R92 route-table's single-interface tree; ICMP/UDP/TCP
identity is IP-scoped, not L2-scoped. So even if a caller *could* spoof
outbound, no in-tree receiver would have granted it any authority based
on the spoofed address. The two halves of the argument agree:
*there is no consumer, so refusing at the source is free and total*.

**The paideia-as unforgeability posture reinforces the choice.** A cap
system's guarantee is "authority is exactly the caps you hold." A rights
bit whose semantic is "let me *lie* about my identity" cuts against
that: it authorises deception in a codebase whose value proposition is
transparent authority. Removing the ABI position for `src_mac`
altogether keeps the code honest to its own model.

## 4. What the code already does (2026-09-01 audit)

`src/kernel/core/net/l2_tx.pdx` L189-301 shows the property is
already enforced structurally today. The `l2_tx_send` signature is:

    l2_tx_send(bar0, tx_ring_pa, dst_mac, ethertype, payload_pa, payload_len) -> u64

Six arguments, none of which is `src_mac`. Inside the body (L255-256):

    lea rdx, [rip + _e1000e_devices];
    add rdx, 24;                             // src_mac ptr

The `eth_build` call receives `src_ptr = &_e1000e_devices[0] + 24`
verbatim. `_e1000e_devices` is populated by `e1000e_read_mac` during
driver attach (R91.M2-002, paideia-os #2016); record `+24` is the
burned-in 6-byte MAC read out of RAL/RAH at probe.

The L2 module already documents this as a "KNOWN deferred sub-scope"
(L157-166) — deferred meaning "the multi-NIC dispatcher
`nic_dispatch_mac(kind, out)` will replace this hardcoded e1000e read
once its per-driver arms wire up in R91.M2 / R91.M3-006 / R91.M4-004."
The MAC-spoof-refuse property survives that later refactor: the caller
still supplies no `src_mac` and `nic_dispatch_mac` will pull from the
active NIC's burned-in address just as `_e1000e_devices+24` does today.

## 5. What R96.M1-002 (#2087) adds

Given §4, R96.M1-002 is not a hardening pass — the property already
holds. It is a witness demonstrating that the property holds
observably:

* `src/kernel/boot/witness/r96_mac_spoof_refuse.pdx` (new).
* Constructs a stack-local candidate MAC (six non-zero bytes) that a
  hostile caller might *wish* to emit as `src_mac`.
* Calls `l2_tx_send` with a legitimate destination + payload — noting
  the API does not accept the candidate.
* Reads the emitted frame back out of the TX pool at bytes `[6..11]`
  (Ethernet II header `src_mac` field, per `net/ethernet.pdx` L13).
* Asserts the six bytes equal the six bytes at `&_e1000e_devices[0]+24`.

Under `PAIDEIA_NIC=none` the MAC field at `_e1000e_devices+24` is zero
(probe never ran). The assertion still holds — the emitted frame
carries six zero bytes, matching the (zero) burned-in address. The
property is invariant to whether a NIC is attached; the witness runs
unconditionally and is meaningful in every boot mode.

## 6. Non-goals

* **No multi-tenant NIC arbitration** — deferred to Phase-3+ per
  `stack.md` §0.2. When that lands, `l2_tx_send` may grow a `nic_index`
  argument selecting *which* NIC (and therefore which burned-in MAC) to
  source from. It still will not accept a caller-supplied `src_mac`.
* **No VLAN tagging** — `stack.md` NET-D15's phase-3+ deferral covers
  this. A VLAN tag is not a source-MAC override; when 802.1Q lands, the
  Ethertype path grows a VLAN case and the source MAC still comes from
  the burned-in address.
* **No promiscuous / MAC-programming ops** — separate concern from
  source-MAC on transmit; those are RX-side and covered by NIC-specific
  authority (KIND_NIC's `R_NIC_PROGRAM` — reserved but not landed at
  R91.M1-001).

## 7. Cross-references

* `design/networking/r91-plan.md` §10.M1 — planning row for R96.M1.
* `src/kernel/core/net/l2_tx.pdx` — hardcoded src_mac source.
* `src/kernel/core/net/ethernet.pdx` — `eth_build` frame layout.
* `src/kernel/core/drivers/e1000e/probe.pdx` + `mac.pdx` — where
  the burned-in MAC is read at probe and staged at `_e1000e_devices+24`.
* `src/kernel/boot/witness/r96_mac_spoof_refuse.pdx` (new) —
  the R96.M1-002 witness.
