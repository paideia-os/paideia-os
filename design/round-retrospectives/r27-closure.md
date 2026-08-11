# R27 Retrospective: e1000e/i219 NIC + L2/L3/L4 substrate + ping/echo

**Date:** 2026-08-11
**Milestone:** R27.M1–R27.M6 (all closed; M6 = closure milestone this
doc + #993/#994/#995/#996/#997)
**Issues:** 27 landed across 6 milestones (23 implementation + 4
closure). Zero fully-deferred R27-scoped issues. All 3 ambient
`paideia-as-blocked` labels on R27 issues resolved as paper tigers
on inspection.
**HEAD at closure:** (bumped by the R27.M6 commit that lands this doc)
**paideia-as pinned at:** `2cf169d` — unchanged across R27
(**seventh consecutive round** with zero cross-repo escalations,
since R21 close).

---

## Round Intent

R27 was scoped as the networking round per
`design/roadmap/r18-plus-bare-metal.md` §R27 — first packet on and
off the wire, from PCI-attached NIC (Intel i219-LM / e1000e family)
through ARP + IPv4 + ICMP/UDP up to a live ping responder + UDP echo
server. The six milestones threaded the NIC substrate first (probe +
regmap + reset + PHY + MAC), then the ring plumbing (RX/TX
descriptor rings + MSI-X + IRQ), then the L2 framework (Ethernet
parse/build + RX dispatch + TX submit), then ARP (packet + cache +
request + reply), then IPv4 (header + checksum + RX/TX), then round
closure (UDP header + KIND_UDP_SOCKET cap + ICMP Echo Reply + UDP
echo demo + retro):

- **M1:** e1000e/i219 NIC substrate — `probe.pdx` (class 0x02/0x00/0x00
  match filter against `_pci_devices` + i219-LM device-ID whitelist),
  `regs.pdx` (u16/u32/u64 MMIO accessors with mfence discipline),
  `reset.pdx` (CTRL.RST assert + settle poll + link-check clear),
  `phy.pdx` (MDIC-mediated PHY read/write), `mac.pdx` (RAL/RAH read
  of the burned-in EEPROM MAC into `_e1000e_devices[i].mac`).
- **M2:** Ring plumbing — `rx_ring.pdx` (256-descriptor RX ring +
  2 KiB per-descriptor buffer pool + RDBAL/RDBAH/RDLEN/RDT program),
  `tx_ring.pdx` (128-descriptor TX ring + TDBAL/TDBAH/TDLEN/TDT
  program), `msix.pdx` (per-vector MSI-X table entry + vector-0 arm),
  `irq.pdx` (ICR read/write with RW1C latch preservation).
- **M3:** L2 Ethernet — `ethernet.pdx` (14-byte header struct +
  parse/build + htons/ntohs helpers), `l2_rx.pdx` (dst-MAC filter +
  ethertype dispatch), `l2_tx.pdx` (bump-alloc TX buffer + eth_build
  + descriptor publish + TDT bump).
- **M4:** ARP — `arp.pdx` (28-byte parse/build; 16-slot cache with
  round-robin eviction + tick expiry; send_request + reply +
  rx_handle with unconditional sender learning + gratuitous
  detection).
- **M5:** IPv4 — `ipv4.pdx` (20-byte header parse/build + checksum
  with big-endian word reading and carry-fold; RX engine with parse
  + checksum verify + dst filter + protocol demux; TX engine with
  same-/24 subnet check + ARP resolve + build + payload memcpy +
  l2_tx_send).
- **M6:** Round closure — UDP header + parse/build + pseudo-header
  checksum + port-7 echo `rx_handle` (#993, #996),
  KIND_UDP_SOCKET capability + mint gate + IPC RPC schema (#994),
  ICMP Echo Request -> Echo Reply responder (#995), R27 closure
  retro + STATUS.md block + tag `r27-closed` (#997, this document).

Pillar 4 target (`design/00-feature-inventory.md`): give the kernel
exactly the substrate a networked application needs to see a packet
on the wire, resolve MACs via ARP, receive and validate IPv4 headers,
respond to ICMP ping, and echo UDP payloads — with userspace socket
delivery and TCP itself deferred to R28+ (userspace-server via
#1015) and R30+ (TCP) respectively.

---

## What Shipped

### R27.M1 — NIC substrate (5 issues: #971–#975)

- **#971 e1000e probe** — `src/kernel/core/drivers/e1000e/probe.pdx`.
  Class-code triple 0x02/0x00/0x00 filter over `_pci_devices` with
  i219-LM device-ID whitelist; publishes `_e1000e_devices` (32 B
  stride: seg/bus/dev/fn @+0, bar0_pa @+8, ..., mac[6] @+24) +
  `_e1000e_device_count`. Under `-kernel` boot the count stays 0
  (no MCFG surface).
- **#972 register accessors** — `regs.pdx`. `e1000e_reg_read_u32` +
  `e1000e_reg_write_u32` with mfence before/after and cache-quiescing
  discipline. u16 and u64 variants for MAC/RAL/RAH.
- **#973 controller reset** — `reset.pdx`. CTRL.RST (bit 26) assert
  + delay + poll clear; link-check clear (STATUS.LU); ready.
- **#974 PHY MDIC** — `phy.pdx`. MDIC MMIO-mediated PHY read/write
  with regaddr + phyaddr encoding + poll for READY (bit 28).
- **#975 MAC read** — `mac.pdx`. RAL (32b low) + RAH (16b high, with
  AV valid bit) into `_e1000e_devices[i].mac` at offset +24.

**Closure commit:** `52a7f2d`.

### R27.M2 — Ring plumbing (5 issues: #976–#980)

- **#976 RX ring init** — `rx_ring.pdx`. 256 × 16 B RX descriptor
  ring + per-descriptor 2 KiB buffer pool (`_e1000e_rx_buffers`,
  512 KiB); RDBAL/RDBAH/RDLEN/RDT/RDH program; RCTL.EN set.
- **#977 TX ring init** — `tx_ring.pdx`. 128 × 16 B TX descriptor
  ring; TDBAL/TDBAH/TDLEN/TDT/TDH program; TCTL.EN set.
- **#978 MSI-X table map + arm** — `msix.pdx`.
  `_e1000e_msix_table_info` (BAR + offset + N cached);
  `e1000e_msix_map_arm_vec0` writes the LAPIC MSI Message Address
  + Data + Vector Control mask clear.
- **#979 IMS enable / ICR RW1C** — `irq.pdx`. IMS/IMC read + write;
  ICR read with RW1C-clear-on-read discipline (once IMS enables
  RXQ/TXQ vectors).
- **#980 IRQ dispatch stub** — same file. `e1000e_irq_dispatch` is a
  callable symbol only at M2; real IDT-vector wiring lands with
  R28+ driver-attach ceremony.

**Closure commit:** `7415fef`.

### R27.M3 — L2 Ethernet (4 issues: #981–#984)

- **#981 ethernet.pdx** — 14-byte struct (dst_mac[6] + src_mac[6] +
  ethertype[2]); `eth_parse` copies 14 B into scratch; `eth_build`
  writes dst/src/type + returns total_len = 14 + payload_len;
  htons/ntohs helpers.
- **#982 l2_rx_handle** — dst-MAC filter (accept unicast to
  `_e1000e_devices[0].mac`, broadcast `FF:*`, multicast `01:*`
  drop by default); ethertype dispatch (0x0800 -> ipv4_rx_stub;
  0x0806 -> arp_rx_stub; else bump `_l2_rx_unknown_cnt`).
- **#983 l2_tx_send** — bump-alloc TX buffer (16-slot pool ×
  2048 B); eth_build; publish descriptor at
  `_e1000e_tx_ring + tail*16` (buf_pa + len + EOP|IFCS|RS); bump
  TDT + shadow.
- **#984 mac_is_broadcast + mac_is_multicast** — same file.
  Six-byte compare against `FF:FF:FF:FF:FF:FF` (broadcast) and
  single-byte low-bit test on byte[0] (multicast).

**Closure commit:** `dc15cea`.

### R27.M4 — ARP (4 issues: #985–#988)

- **#985 arp.pdx parse/build** — 28-byte parse (htype=1 + ptype=
  0x0800 + hlen=6 + plen=4 validate); build (fixed header + op +
  sender_mac[6] + sender_ip[4] + target_mac[6] + target_ip[4]).
- **#986 arp cache** — 16-slot direct table (16 B/entry: ip u32 +
  expiry u32 + mac[6] + pad[2]); add with matching-ip update /
  empty-slot / round-robin evict; lookup gated on expiry > 0;
  tick expire (decrement non-zero expiries).
- **#987 arp_send_request** — arp_build(op=1, sender_mac=devices[0]
  .mac, sender_ip=_arp_my_ip=10.0.0.2, target_mac=0, target_ip=
  request) + l2_tx_send(dst=broadcast, ethertype=0x0806).
- **#988 arp_reply + arp_rx_handle** — arp_build(op=2) + l2_tx_send
  (dst=target_mac unicast); rx_handle parses + unconditional
  sender learning + optional reply on op=1 + target_ip=_arp_my_ip
  + non-gratuitous.

**Closure commit:** `9e3781a`.

### R27.M5 — IPv4 (4 issues: #989–#992)

- **#989 ipv4_parse + ipv4_build** — 20-byte header parse
  (validates version=4, IHL=5; options-bearing packets dropped);
  build with total_length=20+payload_len, ident, DF bit set, TTL=
  64, protocol, src_ip=_ipv4_my_ip, dst_ip; checksum computed
  and stored BE at bytes 10..11.
- **#990 ipv4_checksum** — ones-complement 16-bit sum with BE
  word reading + carry-fold + XOR-0xFFFF invert (paideia-as has
  no `not` mnemonic; XOR-with-mask-after-fold is equivalent when
  the accumulator is already <= 0xFFFF).
- **#991 ipv4_rx_handle** — L3 receive engine: klog fingerprint +
  length gate (>= 34) + parse + checksum verify (sum-all yields
  ~0 = 0 for valid headers) + dst_ip filter (`_ipv4_my_ip` +
  limited broadcast) + protocol demux to icmp_rx_stub /
  udp_rx_stub (M5 fingerprint stubs — replaced at M6).
- **#992 ipv4_tx_send** — L3 transmit: same-/24 subnet check +
  ARP resolve (arp_cache_lookup; miss triggers arp_send_request
  + returns IPV4_E_ARP_PENDING for caller retry) + ident bump +
  ipv4_build + payload memcpy + l2_tx_send with ethertype 0x0800.

**Closure commit:** `5b45f7f`.

### R27.M6 — Round closure (5 issues: #993–#997)

- **#993 UDP header + build/parse + checksum** —
  `src/kernel/core/net/udp.pdx`. 8-byte header (src_port + dst_port
  + length + checksum, all u16 BE); `udp_parse` copies 8 bytes and
  returns 1; `udp_build` writes header with checksum=0 (RFC 768
  "no checksum" latitude); `udp_checksum` computes IPv4-pseudo-
  header (src_ip[4] + dst_ip[4] + zero + proto=17 + udp_len) +
  UDP-packet ones-complement sum using the same 16-bit BE-word
  loop shape as `ipv4_checksum`.
- **#994 KIND_UDP_SOCKET capability + IPC RPC schema** —
  `src/kernel/core/cap/udp_socket_cap.pdx` (mint gate) +
  `design/ipc/udp-socket-rpc-schema.md` (wire format).
  KIND_UDP_SOCKET = 0x50 (new range for network caps, above the
  0x30/0x40/0x42 device/interrupt/blkdev range). Rights R_UDP_BIND
  (0x01), R_UDP_SEND (0x02), R_UDP_RECV (0x04). Descriptor 24 B
  (local_port + remote_port + remote_ip + state + rights + reserved
  qword). Mint gate rejects port=0 (ephemeral allocator lands with
  #1015 userspace-server); rights subset check via
  `udp_rights_valid`. Real descriptor write deferred to #1015 per
  the AcpiCap / BlkdevCap scaffolding pattern.
- **#995 ICMP Echo Reply** — `src/kernel/core/net/icmp.pdx`.
  `icmp_rx_handle(pkt_pa, pkt_len, src_ip, dst_ip)` klog + length
  gate + type-8 detect. On Echo Request: rep_movsb the received
  ICMP packet into `_icmp_tx_scratch`, overwrite byte[0] = 0 (Echo
  Reply), zero cksum @+2..+3, recompute via `ipv4_checksum`
  (identical algorithm — ICMP checksum has no pseudo-header, matches
  IPv4 header checksum shape), store BE @+2..+3, send via
  `ipv4_tx_send(protocol=1, dst_ip=received src_ip)`. Non-Echo
  types logged + dropped per RFC 792 process-locally latitude.
- **#996 UDP echo demo — port 7 responder** — `udp_rx_handle` in
  `net/udp.pdx`. Length gate + dst_port extract; on port 7 build
  8-byte reply header via `udp_build` with swapped ports + same
  length + checksum=0; rep_movsb payload from pkt_pa+8 to
  _udp_tx_scratch+8; send via `ipv4_tx_send(protocol=17)`. Other
  ports bump `_udp_rx_no_socket` counter (userspace delivery via
  KIND_UDP_SOCKET deferred to #1015). Userspace `echo_server`
  binary deferred to #1015.
- **#997 R27 closure retro + STATUS + T14 ping demo** — this
  document + STATUS.md R27 CLOSED block + T14 ping recipe (§T14
  ping demo below) + tag `r27-closed`.

**Closure commit:** (this M6 commit).

---

## Cross-Repo Escalations to paideia-as (R27)

**None.** `paideia-as` submodule remained pinned at `2cf169d` for all
six R27 milestones — unchanged since R21 close. This is the **seventh
consecutive round** with zero cross-repo escalations
(`feedback_cross_repo_escalation.md` never fired in R27 planning or
implementation).

Three ambient `paideia-as-blocked` labels queued into the R27
planning sheet were reviewed and downgraded on inspection as
**paper tigers**:

- **MMIO-safe u32 load/store for e1000e regs (M1 #972).** Cited as
  needing an "MMIO barrier" encoding pass. In practice
  `e1000e_reg_write_u32` uses the same `mov [reg+imm], reg` +
  bracketing `mfence` idiom the R23 fb-console and R24 NVMe paths
  already use. No paideia-as change needed.
- **BE u16 word extract for IPv4 checksum loop (M5 #990).** Cited
  as needing a `bswap` or `movbe` mnemonic. The `(byte<<8) | byte`
  shift-or idiom lands identically in fewer bytes with paideia-as's
  existing `mov_b` + `shl` + `or` encoders. No change needed.
- **Two-argument pseudo-header pass into udp_checksum (M6 #993).**
  Cited as needing an "on-stack struct copy". The 4-argument SysV
  form (src_ip ptr, dst_ip ptr, udp_pkt_pa, udp_len) fits cleanly
  in rdi/rsi/rdx/rcx; no stack marshaling needed.

Zero paideia-as submodule bumps required across R27. Zero PA-R27-*
escalation entries filed.

---

## Deferrals

R27 landed with several substrate deferrals — all chained on the
same external-blocker family the last five rounds have inherited
(#1015 userspace-server substrate). Documented in-round (each M6
module header calls out the deferral inline) rather than as
after-the-fact debt discovery.

### D1. KIND_UDP_SOCKET descriptor slab write + IPC wire code — R28+

**Scope:** `udp_socket_cap_mint` at M6 is a mint gate only — validates
port + rights but does not `slab_alloc` or `cap_mint_write` a
descriptor. The `design/ipc/udp-socket-rpc-schema.md` wire format
defines bind/sendto/recvfrom/close request/reply frames but no
kernel dispatch handles them.

**What blocks:** #1015 (userspace-server substrate — same gate that
blocks #820 acpi_supervisor / #860 pci_enumerator / #906 userspace
half of `nvme_read_blocking` / #963 userspace HID class driver).

**Rerouting:** R28+ per the R25/R26 preflight sequencing.

### D2. UDP userspace socket delivery — R28+ (blocked on #1015)

**Scope:** `udp_rx_handle` currently intercepts port 7 in-kernel
(echo demo) and drops all other destination ports with a
`_udp_rx_no_socket` counter bump. A real socket dispatch would
look up the KIND_UDP_SOCKET descriptor whose local_port matches
dst_port and post the packet to that socket's recv queue.

**What blocks:** Same #1015 gate as D1.

**Rerouting:** R28+ (`net_supervisor` boot chain).

### D3. Full TCP — R28+ or R30+

**Scope:** R27 shipped no TCP. TCP is a substantial substrate on its
own (RFC 793 + RFC 5681 congestion control + retransmit + reordering
+ connection state machine — comparable in scope to a full R25-sized
round on its own). The R27 planning sheet's original scope
(networking = e1000e + ARP + IPv4 + UDP + TCP + BPF-lite) was
carved back to "e1000e + ARP + IPv4 + UDP + ICMP" during M1 planning
after a scope-audit; TCP got pushed to R28 as its own round-or-
sub-round.

**What blocks:** No external blocker; scope decision. TCP might land
as R28 (dedicated TCP round) or as R30+ (after userspace stack
alternatives — pdxtcpd userspace TCP — are considered).

**Rerouting:** R28 or R30+.

### D4. BPF-lite packet filter — R30+

**Scope:** The R18+ roadmap §R27 listed "BPF-lite packet filter" as
part of the networking round. It was descoped during R27.M1
planning after a scope-audit; the eBPF verifier is a substantial
substrate (proof + JIT + safety) and its natural home is R30+ where
it composes with the R31 typed-refinement round.

**Rerouting:** R30+.

### D5. DHCP / dynamic address configuration — R28+

**Scope:** `_ipv4_my_ip = 10.0.0.2` and `_ipv4_gw_ip = 10.0.0.1`
are hardcoded module-static bytes. DHCP client (UDP over port 67/68
+ state machine + DHCPDISCOVER/OFFER/REQUEST/ACK) is a natural
`net_supervisor` startup ceremony that lands with #1015.

**Rerouting:** R28+ (userspace boot ceremony).

### D6. Live T14 ping capture — R28+ (gated:hardware)

**Scope:** Every R27 milestone ran under QEMU-TCG `-kernel` with no
NIC attached (no MCFG surface -> no PCI enumeration -> no e1000e
device -> zero packets on the virtual wire). The T14 first-ping
moment stays queued for R28+ hardware bring-up alongside the R23
first-visual-output, R24 first-NVMe-touch, and R26 first-keystroke
moments (none of which have fired). See §T14 ping demo below for
the operator recipe.

**Rerouting:** R28+ hardware bring-up sub-round.

---

## T14 ping demo (gated:hardware)

The operator recipe for observing a live ICMP Echo Reply on the T14
G4 with the i219-LM NIC once R28's driver-attach ceremony wires up
the e1000e IRQ walker.

### Preconditions

- T14 G4 booted via UEFI/OVMF from a USB stick containing
  `build/kernel.elf` (see `design/hardware/t14-boot.md` — anchor
  placeholder pending R28 UEFI harness).
- `Features.E1000E_ATTACH_ENABLED = 1` in `kernel_main_uefi.pdx`
  (defaults to 0 to keep `-kernel` boots side-effect-free).
- Second host on the same subnet as `_ipv4_my_ip = 10.0.0.2` —
  set the host's NIC to `10.0.0.3/24` via
  `sudo ip addr add 10.0.0.3/24 dev enp1s0` (adapt device name).
- Serial cable + `screen /dev/ttyUSB0 115200` on the host to watch
  klog fingerprints.

### Recipe

1. Boot the T14 G4 from the USB stick.
2. Wait for the boot banner `PaideiaOS R27 net-ready` (one-shot
   fingerprint emitted by the R28 driver-attach ceremony after
   e1000e reset + PHY link-up).
3. From the second host: `ping -c 3 10.0.0.2`.
4. On the serial console observe:
   ```
   [NET_] L2 RX ARP
   [NET_] L2 RX IPV4
   [NET_] L3 RX IPV4
   [NET_] L3 RX ICMP
   ```
   (one line per received frame; ARP first as the sending host
   resolves 10.0.0.2's MAC; then ICMP Echo Request; the
   `icmp_rx_handle` sends the Echo Reply which lands as the
   `ping` reply on the sending host.)
5. `ping -c 3 10.0.0.2` should report `3 packets received, 0% packet
   loss`.

### Promotion path

Once observed on real HW, promote the "T14 G4 i219-LM ICMP Echo
Reply works after e1000e reset" row in `design/hardware/quirks.md`
§2.5 (Networking) from `PROVISIONAL` to `CONFIRMED` with the
observation date + serial log capture URL.

---

## Preflight for R28

**R28 (userspace-server substrate + driver-attach ceremony)** —
opens after R27 close per `design/roadmap/r18-plus-bare-metal.md`
§R28. Draft preflight to land as
`design/round-retrospectives/r28-preflight.md` at R28.M1 kickoff.

### R28 direct scope (roadmap)

- **#1015 userspace-server substrate.** IPC syscall table
  (`sys_ipc_recv` / `sys_ipc_reply`); named endpoint registry;
  KIND_ENDPOINT capability minting.
- Driver-attach ceremony wire in `kernel_main_uefi`:
  - **NVMe** (#906 blocker resolved) — mount root FS.
  - **xHCI** (#963 + R26 D1..D4 blockers resolved) — attach HID
    keyboard, register hotplug handler with IRQ walker.
  - **e1000e** (R27 D2, D5, D6) — attach NIC, run DHCP boot
    ceremony via `net_supervisor`, wire IRQ walker into IDT.

### R28 opportunistic scope — R27 debt discharge

The R28 opening also has room to discharge the R27 socket + DHCP
debt as an M0/M1 prelude once #1015 is in-tree:

1. **R28.M0.9 (optional prelude):** land `net_supervisor` boot chain
   — bind KIND_UDP_SOCKET on ports 67 (DHCP client) + 53 (DNS
   client) + 123 (NTP client); wire DHCP DISCOVER/OFFER/REQUEST/
   ACK exchange; populate `_ipv4_my_ip` at runtime.
2. **R28.M0.95 (optional prelude):** retire the kernel-side port-7
   echo path in `udp_rx_handle` in favour of a userspace echo
   daemon that receives via `recvfrom` and replies via `sendto` — a
   paper-thin test bench for the KIND_UDP_SOCKET RPC round-trip.

If R28 scope tolerates the M0 prelude, R27 D1+D2+D5 discharge at
R28 open — probably 4-6 issues. If R28 scope is too tight
(userspace-server substrate alone is a 20+ issue round easily),
the M0 prelude moves to R28.5 / R29 as a targeted "flush the R27
socket debt" sub-round.

### R27 debt items not covered by R28 M0 prelude

- **Full TCP** (D3) — R28 or R30+ dedicated round.
- **BPF-lite** (D4) — R30+ next to typed refinements.
- **Live T14 ping capture** (D6) — pulls with (1)+(2) once R28
  driver-attach + `net_supervisor` DHCP boot lands.

Decision to defer to R28.M1 kickoff — see kickoff doc for the call.
