# NIC DMA / IOMMU audit (R96.M2, paideia-os #2088/#2089/#2090)

**Round:** R96.M2
**Status:** Audit complete 2026-09-01. Findings summarised below; no code
change lands in R96 for the wiring itself (deferred — see §4).

## 1. The question

Are the NIC drivers' RX/TX ring buffers actually mapped through an
R22/R25 VT-d IOMMU domain today, or is the "simplifies R25 IOMMU-domain
mapping" comment thread that runs through
`drivers/e1000e/rx_ring.pdx` L102-104, `drivers/virtio_net/virtqueue.pdx`
L137-140, and (by extension) `drivers/rtl8139/*.pdx` aspirational?

## 2. Findings — audit walk

### 2.1 e1000e

**Ring / buffer allocation:** `drivers/e1000e/rx_ring.pdx` L106-107:

    pub let mut _e1000e_rx_ring       : [u64; 256]   = uninit @align(4096)
    pub let mut _e1000e_rx_buffers    : [u64; 32768] = uninit @align(4096)

`drivers/e1000e/tx_ring.pdx` follows the same pattern. Both live in
`.bss`, both `@align(4096)`, both **directly-programmed as physical
addresses** into RDBAL/RDBAH/RDLEN (RX) and TDBAL/TDBAH/TDLEN (TX) at
init time (`e1000e_rx_ring_init` L135-, `e1000e_tx_ring_init`
analogously).

**VT-d mapping site:** none. Grep of
`src/kernel/core/drivers/e1000e/` for `iommu`, `vtd`, `VT-d`,
`dma_domain`, `KIND_DMA` returns exactly two hits — both comment
strings acknowledging the alignment is stricter than the hardware
requires *specifically to simplify a future R25 IOMMU-domain wire-up*
(`rx_ring.pdx` L27, L104). No call site programs a VT-d context entry
for the NIC's bus/dev/fn. The `_e1000e_rx_ring` and
`_e1000e_rx_buffers` physical addresses reach the controller's
bus-master port with **no IOMMU translation interposed**.

**Attribution.** R91.M2-003 (paideia-os #2017) added first-device
activation to the probe path (`drivers/e1000e/probe.pdx` step 16 —
`e1000e_reset` → `e1000e_rx_ring_init` → `e1000e_rx_refill` →
`e1000e_msix_setup`). None of those steps calls a VT-d substrate
primitive. R91.M2-002 (paideia-os #2016) added `driver_table_register`
and `kind_nic_mint_body`, but the register is a visibility shim per
`r91-plan.md` §4.2 — it does not thread a KIND_DMA_DOMAIN through the
driver process.

### 2.2 virtio-net

**Ring allocation:** `drivers/virtio_net/virtqueue.pdx` L295-298:

    pub let mut _virtio_net_rx_desc_pg          : [u64; 512] = uninit @align(4096)
    pub let mut _virtio_net_rx_avail_used_pg    : [u64; 512] = uninit @align(4096)
    pub let mut _virtio_net_tx_desc_pg          : [u64; 512] = uninit @align(4096)
    pub let mut _virtio_net_tx_avail_used_pg    : [u64; 512] = uninit @align(4096)

Four 4-KiB pages, all `@align(4096)`. `virtqueue.pdx` L136-140 documents
the alignment rationale in the same terms as e1000e — **"simplifies R25
IOMMU-domain mapping when R96.M2 wires vtd_slpt_map for the NIC's DMA
pages"**. That comment is literally naming R96.M2 as the future wire-up
round. This audit is R96.M2-001; the wire-up is R96.M2-002, and this
document sits between the two.

**VT-d mapping site:** none. Same shape as e1000e — grep returns only
the aspirational comment threads. The virtio-net probe path calls
`virtio_net_init_handshake` (`common_cfg.pdx`) and
`virtio_net_vq_init` (`virtqueue.pdx`), neither of which programs a
VT-d context.

### 2.3 rtl8139

**Ring allocation:** grep of `src/kernel/core/drivers/rtl8139/` for
`iommu`, `vtd`, `VT-d`, `KIND_DMA` returns **zero hits** — no comment
thread, no code path, no mention. `drivers/rtl8139/rx.pdx` and
`drivers/rtl8139/tx.pdx` declare their ring/buffer pools in `.bss`
directly, same as e1000e/virtio.

**VT-d mapping site:** none.

## 3. Verdict

**All three NIC drivers currently perform bus-master DMA against
physical addresses with no IOMMU domain interposed.** The R22/R25 VT-d
substrate (KIND_DMA_DOMAIN, IOMMU context switching, cascade-revoke on
domain teardown) exists and is exercised by boot witnesses for
non-NIC KIND_DMA_DOMAIN paths — see `core/cap/kind_dma_domain.pdx` and
`design/round-retrospectives/r29-closure.md` for the R29 substrate
landing — but no NIC arm is wired to it.

This is not a regression; it is exactly what the aspirational comment
threads warned they would leave behind. R91's plan (§10.M2) named this
audit as a prerequisite to any wire-up round, and its finding — "not
wired" — matches what the driver comments predicted.

## 4. Consequence for R96 scope

**Reservation, not wire-up.** R96.M2-002 (#2089) and R96.M2-003 (#2090)
in the R91 plan were both drafted as "*if the audit finds unwired,
mint / extend KIND_DMA_DOMAIN for NIC ring buffers*." Given the audit
result, the plan's own §10.M2 lets us reserve rather than build in R96:
the KIND_DMA_DOMAIN substrate the wire-up would consume **already
exists** (0x142, R29.M5-001/002/003/004, `core/cap/kind_dma_domain.pdx`),
and the wire-up itself is a per-driver refactor touching probe /
init / teardown paths in all three drivers — a bigger footprint than
R96's security-hardening round scope tolerates.

### 4.1 Ordinal note

The R96 planning brief (2026-09-01) suggested reserving a new
`KIND_DMA_DOMAIN` ordinal at `0x1B3` "next after KIND_SCHEMA_HANDLE=
0x1B2." **This is stale — KIND_DMA_DOMAIN is already landed at 0x142
from R29.** No new ordinal is minted. The R96.M2 wire-up round will
consume the existing kind:

* Value: `0x142` (R29.M5-001, `core/cap/kind_dma_domain.pdx` L249).
* Derivation: over KIND_MEMORY (4), *not* over KIND_HW — see the kind
  file's L28-38 rationale ("a DMA domain is a memory-access scope, not
  a device-authority handle").
* Rights: R_DMA_INVOKE / R_DMA_REVOKE / R_DMA_MINT / R_DMA_OBSERVE
  (R_DMA_ALL = 0x618).
* One domain per driver process (R29.M5-003 D1.b). NIC rx/tx rings and
  buffer pools would share the driver's single domain — no per-ring
  domain minting.

### 4.2 What the R96 audit round does NOT change

* No `KIND_DMA_DOMAIN` mint call added to `drivers/e1000e/probe.pdx`,
  `drivers/virtio_net/probe.pdx`, or `drivers/rtl8139/probe.pdx`.
* No VT-d context-entry programming for the NIC's BDF.
* No `driver_table_set_domain` (R29 substrate) call for the NIC
  driver row registered by `driver_table_register` at R91.M2-002.

## 5. What the wire-up round would do

Recording the sketch here so the deferred round has a concrete starting
point rather than re-deriving it.

For each NIC driver (e1000e, virtio-net, rtl8139):

1. At probe-time (`*probe.pdx`, after `kind_nic_mint_body` succeeds
   and before the first bus-master activation), call
   `dma_cap_mint(parent_memory_slot, R_DMA_ALL, iommu_ctx_id,
   bus_dev_fn, capacity_bytes = <sum of ring/buffer pool sizes>,
   coherency = DMA_COH_COHERENT)`.
   * `parent_memory_slot` — the driver process's memory-root cap
     (R29.M5-003 wiring point).
   * `iommu_ctx_id` — allocated by the VT-d substrate.
   * `bus_dev_fn` — the NIC's PCI BDF, already known to probe at
     step 9 (`e1000e/probe.pdx`).
   * `capacity_bytes` — pool-total (e1000e: 2 KiB ring + 256 KiB
     buffers + TX ring + TX buffers).
2. Program the VT-d context entry for `bus_dev_fn` to translate
   through the domain's second-level page table (SLPT).
3. `vtd_slpt_map` each ring/buffer page into the domain SLPT with
   R+W permissions.
4. Cascade-revoke on driver teardown: the driver process's memory-root
   revoke triggers `dma_cascade_revoke_by_parent`, which zeros the
   domain row, and the VT-d substrate zeros the context entry.

Steps 2-3 are the primitives R25 landed (`vtd_slpt_map`,
`vtd_ctx_program`); step 4 is R29.M5-003's cascade edge. The wire-up
is a small function per driver plus one supervisor-side call — the
substrate does not need extension.

## 6. Follow-up issues

* **New round to be planned** — "R-<n>.M<m> NIC-DMA-domain wire-up"
  covering steps 1-4 above for e1000e, virtio-net, rtl8139. Blocking
  dependencies: R29 substrate (landed), R91 NIC-probe path (landed).
  Non-blocking dependency: `nic_dispatch_mac` unification per
  `l2_tx.pdx` header (R91.M2 follow-up) — makes the "for each NIC
  driver" loop above shorter.

## 7. Cross-references

* `src/kernel/core/cap/kind_dma_domain.pdx` — the substrate.
* `design/round-retrospectives/r29-closure.md` — R29.M5 landing notes.
* `design/networking/r91-plan.md` §10.M2 — planning rows.
* `src/kernel/core/drivers/e1000e/rx_ring.pdx` L102-104 — aspirational
  comment thread that motivated this audit.
* `src/kernel/core/drivers/virtio_net/virtqueue.pdx` L136-140 — same
  thread, explicitly naming R96.M2 as the wire-up round.
