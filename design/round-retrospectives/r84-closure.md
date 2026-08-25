# R84 Retrospective (PARTIAL): Thunderbolt 4 / USB4 live

**Date:** 2026-08-25
**Milestone:** R84.M1 (single-milestone round)
**Issues:** 4 landed-as-scaffold/PROVISIONAL (#1878, #1882, #1886,
#1889); 3 partial (#1880, #1884, #1885); this doc closes #1891.
**HEAD at audit:** paideia-os bbb3d35 (fresh worktree, no code changes
made by this audit).
**Release tag:** `r84-closed` recommended as a partial-close — three
named non-hardware-gated gaps exist (see disposition below), matching
the R58/R59/R74/R78 precedent of closing honestly rather than blindly.

## Round intent

Per `design/roadmap/post-r60-daily-use-roadmap.md:541-542`: "29-file
scaffold (NHI + CM FSM + tunnels + per-dock IOMMU domain) written but
never live-exercised." Corpus: `src/kernel/core/drivers/tb/`, 30 files,
17,793 lines. `tools/hw-smoke-r35-hotplug.md:20-45` confirms the only
prior QEMU-OVMF exercise was the generic PCIe-root-port hotplug
substrate (R35.M1) — real TB4 router/dock discovery was explicitly
deferred at that time ("that wiring is R35.M2+ scope") and never
revisited until now. Confirmed: **QEMU has no Thunderbolt/USB4 device
model at all** — this entire round is real-hardware-only for its
end-state fingerprint, though three sub-areas below have real
remaining implementation work independent of that hardware gate.

## Per-issue disposition

### #1878 — NHI probe live: TB4 controller enumeration on T14 — LANDED (PROVISIONAL)
`nhi_probe.pdx` (404L): PCIe class/vendor decode (`PCI_CLASS_TRIPLE_
USB4`, `TB_NHI_VENDOR_INTEL`, BAR/ring-capability constants). Code-
complete; real-hardware-only exercise remains.

### #1880 — CM FSM live: connect docking station, verify router
discovery — PARTIAL
`sw_cm_fsm.pdx` (630L) + `cm_rings.pdx` (614L) + `sw_cm_cmdq.pdx`
(425L) + `sw_cm_evtmux.pdx` (371L) + `router_walk.pdx` (650L): FSM
states, ring submission, and topology decode logic all real.
**Named gap:** `router_walk.pdx`'s own header states "IT DOES NOT SEND
CONTROL PACKETS ITSELF... the witness synthesises those; a live driver
drives them from the cm_rings RX dequeue" — the decode half is
complete but is driven by synthetic test data, not wired to a live RX
path. This is real, non-hardware-gated remaining work (wiring
`cm_rings`'s RX dequeue into `router_walk`'s input), distinct from
"needs a physical dock to observe." PARTIAL.

### #1882 — PCIe tunnel live: dock PCIe device appears in tunneled bus — LANDED (PROVISIONAL)
`pcie_tunnel.pdx` (371L) + `topology_graph.pdx` (872L) +
`topology_diff.pdx` (1124L): tunnel establishment + topology graph
(vertices=routers, edges=port-port bonds) + diff detection, all real
logic. Real-hardware-only exercise remains.

### #1884 — DP tunnel live: external display via TB4 to dock DP output — PARTIAL
`dp_tunnel.pdx` (585L), `dp_altmode.pdx` (800L, full USB-PD alt-mode
VDM sequence), `dp_ddi_shim.pdx` (770L), `dp_aux_passthru.pdx` (670L),
`dp_hotplug_bridge.pdx` (597L) — all real logic. **Named gap:**
`dp_hotplug_bridge.pdx`'s header states its consumer, `KIND_DISPLAY_
OUTPUT`, "does not yet exist," so its current output is a placeholder
counter bump; "R36's opener will replace" it with the real fanout.
This also compounds with R77's finding (no pipe/transcoder/link-
training code exists yet) — even with a real TB4 dock, there is
currently no display pipeline on the other end of this tunnel to
receive the signal. PARTIAL, and cross-referencing the R77
retrospective is warranted for whoever picks this up.

### #1885 — USB3 tunnel live: USB peripheral enumerates via tunneled
xHCI — PARTIAL
`usb3_tunnel.pdx` (534L) + `usb3_xhci_ext.pdx` (849L): tunnel-slot
row table is real. **Named gap:** `usb3_xhci_ext.pdx`'s header states
it provides "the ROW TABLE + PLACEHOLDER EVENT half of the xHCI tunnel"
and that real port events await "once a real xHCI extension binding
lands" in "the R34 USB stack" — explicitly not yet wired, independent
of hardware. PARTIAL.

### #1886 — Per-dock IOMMU domain isolation: verify DMA confinement — LANDED (PROVISIONAL)
`iommu_domain.pdx` (640L): real per-dock domain-allocation bookkeeping
(16-domain fixed table). Isolation logic complete; DMA-confinement
verification needs a live tunneled device to test against.

### #1889 — Hot-plug live: connect/disconnect dock, verify clean
teardown — LANDED (PROVISIONAL)
`dp_hotplug_bridge.pdx`, `multi_host_contend.pdx` (516L),
`cascade_harness.pdx` (506L), `route_teardown.pdx` (361L), plus the
consent/security path (`consent_dialog.pdx`, `consent_revoke.pdx`,
`trusted_device.pdx`, `security_policy.pdx` — 453+506+542+561L).
Teardown and multi-host-contention logic is real and complete.
Real-hardware-only exercise remains.

### #1891 — Round closure — this document
STATUS + retrospective + `r84-closed` tag, partial-close discipline.

## Cross-repo escalations

None found.

## Observable proof

Driver corpus builds under its original R35 landing witnesses; no new
observable produced by this audit (no code changes made, no TB4
hardware available in this environment). `tools/hw-smoke-r35-hotplug.md`
remains the only real-hardware witness doc for anything in this
family, and it explicitly covers only the generic PCIe-hotplug signal,
not TB4-specific router/tunnel behavior.

## Debt inventory (carried forward)

1. **CM FSM live RX wiring** (#1880) — connect `cm_rings`'s RX dequeue
   to `router_walk_step`'s input; not hardware-gated.
2. **`KIND_DISPLAY_OUTPUT` fanout** (#1884) — replace
   `dp_hotplug_bridge.pdx`'s placeholder counter with the real
   subscriber fanout once it exists; cross-references R77's missing
   display pipeline (pipe/transcoder/link-training) as a shared
   blocker.
3. **xHCI extension binding** (#1885) — wire `usb3_xhci_ext.pdx`'s row
   table into the real R34 USB/xHCI stack; not hardware-gated.
4. **Real TB4 controller + TB4 dock + downstream devices (NIC, DP
   monitor, USB peripheral)** — needed for #1878, #1882, #1886, #1889's
   remaining exercise once (1)-(3) land where applicable.

**Next round:** three of this round's gaps (1-3 above) are real,
buildable, non-hardware-gated work — recommend a small follow-up pass
before the next real-hardware session, since it would let that session
verify more than the current code supports. R83 (Wi-Fi + Bluetooth
live) carries no equivalent buildable-debt list and can proceed on the
existing roadmap sequencing independently.
