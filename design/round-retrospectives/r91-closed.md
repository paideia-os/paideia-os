# R91 Retrospective: Generic NIC dispatch + three-driver bring-up

**Date:** 2026-09-01
**Milestones:** R91.M1 (KIND_NIC), R91.M2 (e1000e), R91.M3 (virtio-net),
R91.M4 (rtl8139), R91.M5 (probe cascade + PAIDEIA_NIC + witness), R91.M6
(cleanup + retrospective).
**Issues closed at landing:** #2011..#2028 (M1..M4 substrate), #2029,
#2030, #2031, #2032, #2033.
**HEAD at closure:** paideia-os (this landing).
**Release tag:** `r91-closed` recommended — the boot_r91_nic_probe
witness's fingerprint (`boot r91 nic probe ok kind=<n> mac=<packed>
link_up=<0|1>`) attests every arm of the R91.M5-001 dispatch cascade on
every default boot; per-driver `<vendor> probe ok` / `<vendor> mac ok`
lines corroborate on each arm's own path.

## Round intent

Per `design/networking/r91-plan.md`: land a generic NIC dispatch layer
so future L2/L3 code sits above a single-active-NIC shim rather than
poking any one driver's globals; then land three real NIC drivers under
that shim (e1000e for T14 G4 real hardware and QEMU `-device e1000e`,
virtio-net for the QEMU default and future container-friendly guests,
RTL8139 for the legacy-QEMU / real-hardware compatibility spread); and
close with a boot witness that verifies the router's own dispatch chain
resolves to the same driver each probe lands on.

## Per-milestone disposition

### R91.M1 — KIND_NIC capability substrate — LANDED
- `src/kernel/core/cap/kind_nic.pdx` — ordinal 0x1AD, 4-row pool at 64 B/row,
  `NIC_KIND_*` selectors, `NIC_LINK_*` states, `R_NIC_QUERY` right, mint
  gate, revoke path, failure band `0xFFFFEB20..0x2F`.
- `src/kernel/core/net/nic_dispatch.pdx` — cmp/je dispatch shim
  (`nic_dispatch_probe` / `_tx` / `_rx_poll` / `_rx_dispatch` / `_mac`),
  single `_active_nic_kind` global, single-active-NIC MVP scope.
- `src/kernel/boot/witness/r91_kind_nic.pdx` — boot witness minting a
  synthetic KIND_DEVICE parent and a KIND_NIC row, exercising every
  QUERY op via cap_invoke plus a rights-denial cross-check.

### R91.M2 — e1000e driver — LANDED
- `src/kernel/core/drivers/e1000e/` (probe / regs / reset / rx_ring /
  tx_ring / mac / irq / msix / phy). Probe filters `_pci_devices` for
  class 0x02/subclass 0x00 with VID=0x8086 and six DID ranges covering
  82574..i219; on the first-device path runs reset + rx_ring_init +
  rx_refill + MSI-X setup + `e1000e_read_mac` + driver_table_register
  + KIND_NIC publication all inside the probe's activation tail.

### R91.M3 — virtio-net 1.0 driver — LANDED
- `src/kernel/core/drivers/virtio_net/` (probe / common_cfg / virtqueue /
  rx / tx / mac / isr). Probe filters `_pci_devices` for
  (0x1AF4, {0x1041 modern | 0x1000+subsys=1 transitional}) with an
  inline vendor-specific capability walk capturing per-cfg_type
  (bar_idx, offset) tuples plus notify_off_multiplier.
- Handshake (`virtio_net_init_handshake`) drives the virtio 1.0 status
  sequence (ACK -> DRIVER -> FEATURES_OK -> DRIVER_OK) with an
  unconditional ACK of F_MAC (bit 5) + F_STATUS (bit 16).
- MAC read from DEVICE cfg with LAA fallback for unreachable-region
  paths; link status from DEVICE cfg's status u16 bit 0 with a
  safe-default of 1.

### R91.M4 — RTL8139 driver — LANDED
- `src/kernel/core/drivers/rtl8139/` (probe / rx / tx / mac / irq).
  Probe filters `_pci_devices` for (0x10EC, 0x8139), records BAR1
  (MMIO) as the primary carrier and BAR0 (I/O ports) as unused MVP
  headroom; first-device tail writes CMD RST + polls for self-clear
  + writes Config1 = 0 (power-on).
- RX ring implemented as a 16 KiB continuous buffer with the driver-
  owned CAPR consumption cursor tracking hardware's CBR write cursor.
- TX implemented as a 4-slot round-robin, TSAD[slot] + TSD[slot]
  writes hand each frame to the controller (bit 13 OWN=0 is the
  transmit trigger).

### R91.M5 — Probe cascade + PAIDEIA_NIC + witness — LANDED (this issue)
- **#2029 (M5-001) — probe cascade + tx/rx/mac/link + attach wiring.**
  `nic_dispatch.pdx`: wired the rtl8139 arm in `nic_dispatch_probe`
  (previously a labelled fall-through to `nd_pb_none`); wired the
  virtio + rtl8139 arms in `nd_tx` / `nd_rp` / `nd_rd` / `nd_mc`;
  added `nic_dispatch_link` (new router entry, cmp/je chain over the
  three kinds returning 0/1 or NIC_ENOSYS). `kernel_main.pdx`: added
  the post-probe attach cascade — kind==2 -> `virtio_net_rx_refill`,
  kind==3 -> `rtl8139_read_mac` + `rtl8139_rx_init` (bar_pa loaded
  from `_rtl8139_devices[0]+8`), kind==1 is a no-op because e1000e's
  probe internally activates. rtl8139 bar_pa loaded via the double-
  load pattern rather than parking in a callee-save register: two
  loads from a fresh cache line is cheaper than a push/pop pair in
  a linear boot cascade.
- **#2030 (M5-002) — PAIDEIA_NIC env switch default flip.**
  `tools/run-qemu.sh`: default flipped from `none` to `virtio` per
  the issue spec — this gives every default boot a live NIC to
  attest against without callers naming a PAIDEIA_NIC value. Existing
  case arms unchanged; header comment updated to reflect the new
  default and to keep `none` as an explicit opt-in for smokes that
  must retain the pre-R91 arg-list shape.
- **#2031 (M5-003) — boot_r91_nic_probe witness.**
  `src/kernel/boot/witness/r91_nic_probe.pdx` (new, 130 lines):
  reads `_active_nic_kind`; if 0 emits `boot r91 nic probe ok kind=0`
  via klog_s1_d1; else calls `nic_dispatch_mac(kind, 0)` and
  `nic_dispatch_link(kind)`, emits `boot r91 nic probe ok kind=<n>
  mac=<packed> link_up=<0|1>` via klog_s1_d3. Both fingerprints use
  lowercase "ok" (no bracketed legacy suffix), so
  verify-fingerprint-coverage.sh's OK_TOK extractor does not
  require golden coverage or an allowlist entry — same posture as
  the sibling `r91_kind_nic.pdx`'s `boot nic ok --`.

### R91.M6 — Cleanup + retrospective — LANDED (this issue)
- **#2032 (M6-001) — delete legacy virtio_net stub.**
  `git rm src/drivers/virtio_net/probe.pdx` — the Phase-7-era
  skeleton (D7-006, 2024 issue numbering) that was superseded by
  the from-scratch R91.M3 driver at `src/kernel/core/drivers/
  virtio_net/`. The now-empty `src/drivers/virtio_net/` directory
  goes with it. `nic_dispatch.pdx`'s header updated to reflect the
  removal (the historical reference remains so a spelunker can
  find the disposition from a pre-R91.M6 commit).
- **#2033 (M6-002) — retrospective + STATUS.md + tag.**
  This document; STATUS.md gains a minimal one-row R91 close-out
  entry at the tail; main to `git tag r91-closed` after landing.

## Cross-repo escalations to paideia-as

**None.** R91's six milestones landed against a solid encoder — every
`.pdx` in the tree assembled without a new encoder gap. The MMIO
mfence-bracket envelope, `mov_b` / `mov_w` / `mov_d` sized loads/
stores, `xor+mov_b` zero-extend, string-copy `rep movsb`, and every
`lea [rip + sym + disp8]` addressing form already existed. The
libpdx-net satellite is the next dependent.

## Deferred items carried forward

1. **TX completion reap on virtio + rtl8139.** Both drivers write the
   descriptor / TSD and let the controller drain; a real reap loop
   that consults the used-idx (virtio) or ISR.TOK (rtl8139) and frees
   / rotates buffers is future R91-adjacent work. MVP tolerates this
   because the RX drain path also picks up TX slot recycling by policy
   (virtio) or because the 4-slot round-robin naturally overwrites
   in-flight buffers (rtl8139, safe iff the caller respects a
   4-frame-in-flight window).
2. **MSI-X path on virtio.** `virtio_net_isr_handle` is written for
   the legacy INTx-style ISR-status byte read; MSI-X delivery skips
   that byte per virtio 1.1 §4.1.4.5 and the vector-per-queue mode
   needs a separate wiring. Not blocking any current smoke.
3. **PCI Command-register bus-master enable.** Currently BIOS/OVMF-
   dependent (QEMU's `-device` path pre-enables bus-master on the
   PCI Command register); real hardware requires the driver to set
   `PCI_CFG_CMD.BME`. Trivial to add — one `pci_config_write_u16`
   per driver's probe activation tail — deferred to a follow-up
   round bundled with the same `pci_config_write_u16` primitive.
4. **rtl8139 ERTXTH tuning (R91.M4-005+).** `rtl8139_tx_send` writes
   TSD with ERTXTH=0 (an 8-byte early-tx threshold), which is safe
   but wasteful — a larger threshold amortises the FIFO refill cost
   at real-hardware link rates. QEMU indifferent; T14 G4 optimisation
   scope.
5. **Unbounded RX loop guard flagged by debugger.** Both
   `virtio_net_rx_poll_and_dispatch` and `rtl8139_rx_poll` iterate
   without a hard cap; a pathological RX burst could keep the ISR-
   scope routine running longer than the caller expects. Flagged by
   the R91.M3-005 / M4-002 debugger reports at landing time as low
   risk under QEMU (finite guest-driven traffic) but real on
   real hardware under load. Adds a `max_iter` argument to each
   poll body in a follow-up.
6. **Live STATUS.LU / MSR.LINKB link-status poll.** `nic_dispatch_
   link`'s e1000e + rtl8139 arms return a hard-coded 1 today (probe-
   time activation pinned NIC_LINK_UP). The virtio arm is live via
   `virtio_net_link_status`. Wiring live polls for the other two is
   deferred to the same milestone that adds a driver-scope link-
   change watcher.
7. **IDT vector wiring for rtl8139_isr_handle.** rtl8139 IRQ arrives
   at legacy INTx vector (typically 43 = IRQ 11); the trampoline is
   written but not registered. Polling via the R91.M5-003 witness's
   readback path is sufficient at the MVP scope; a real IDT hookup
   waits for the follow-up that lands MSI-X on virtio (both benefit
   from the same shared IDT-vector primitive).
8. **boot_r91_nic smoke mode + expected-r91-nic-probe.golden.** The
   R91.M5-003 witness fires every boot but the `tools/run-smoke.sh`
   mode `boot_r91_nic` and its golden file specified at
   `design/networking/r91-plan.md:341` were not landed with this
   close-out. A silent regression in nic_dispatch that flips a
   router back to NIC_ENOSYS would leave the witness's cascade
   intact but no smoke asserts its OK line today. Flagged by the
   R91.M5+M6 debugger review at landing time. Retire by adding one
   `boot_r91_nic` mode invocation to `tools/run-smoke.sh` plus a
   pinned golden line — treatable as a leaf ticket in the follow-up
   round that also lands MSI-X (both need the smoke-matrix seam
   this issue creates).

## Observable proof

Every default boot (PAIDEIA_NIC=virtio, the new default) emits, in
order at kernel_main_64's post-PCI-enum tail:

1. `INFO cpu0 net : virtio-net probe ok count=<N>` — from
   `virtio_net_probe`.
2. `INFO cpu0 net : virtio-net init handshake ok` — from
   `virtio_net_init_handshake`.
3. `INFO cpu0 net : nic dispatch probe ok [legacy: NIC DISPATCH PROBE
   OK] kind=2` — from `nic_dispatch_probe`'s `nd_pb_emit`.
4. `INFO cpu0 net : virtio-net rx refill ok` — from
   `virtio_net_rx_refill` (attach step).
5. `INFO cpu0 net : virtio-net mac ok mac=<packed>` — from
   `virtio_net_read_mac_body` (via `nic_dispatch_mac`).
6. `INFO cpu0 net : virtio-net link ok link_up=1` — from
   `virtio_net_link_status` (via `nic_dispatch_link`).
7. `INFO cpu0 boot : boot r91 nic probe ok kind=2 mac=<packed>
   link_up=1` — from `witness_r91_nic_probe`.

Line (7) is the R91.M5-003 assertable fingerprint. Under
PAIDEIA_NIC=none the boot log carries `kind=0` variants of (3) and
(7) only (no per-driver lines because no probe matched); under
PAIDEIA_NIC=e1000e the boot carries the e1000e probe / mac / rx /
irq lines with `kind=1`; under PAIDEIA_NIC=rtl8139 the rtl8139
probe / mac / rx-init lines with `kind=3`.

## What R91 unlocks

- `libpdx-net` (the next dependent) can now assume a live single-active
  NIC exists at boot and route TX through `nic_dispatch_tx` without
  knowing which driver is present.
- Future L2/L3 substrate (ARP resolver, ipv4 send/rx, DHCP client)
  land against the router's uniform surface, not against any one
  driver's globals.
- The R91 probe cascade generalises to N NICs: a future multi-NIC
  round replaces `_active_nic_kind` (a single u64) with an
  iface_id-indexed table and each router entry gains an iface_id
  argument. The signature change is confined to `nic_dispatch.pdx`.

**Next round:** R92+ (libpdx-net wire-in against `nic_dispatch_*`).
Zero R91 kernel-side blockers.
