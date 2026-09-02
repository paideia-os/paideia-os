# QEMU networking invocation catalogue

**Status:** LANDED (R98.M3-002 paideia-os #2105).
**Scope:** every knob `tools/run-qemu.sh` and `tools/run-smoke.sh`
expose for the R91-R94 kernel-side networking substrate, plus the
SLIRP addressing envelope and host-side prerequisites each smoke
mode depends on.

Sits under `design/networking/` alongside `mac-spoof-policy.md`,
`iommu-audit.md`, `filter-chain.md`, `tls-placement-decision.md`,
`ipv6-deferral.md`, and `r91-plan.md`. Pointed to from
`tools/run-qemu.sh --help` (R98.M3-001 #2104) and the header block
of `tools/run-smoke.sh`'s three networking lane modes.

---

## 1. Environment-variable interface

Three env vars govern all networking behaviour. Every other QEMU knob
(`-cpu`, `-smp`, `-serial`, ...) is orthogonal.

### `PAIDEIA_NIC` = `e1000e | virtio | rtl8139 | none`

Attaches (or omits) an emulated NIC. Default: `virtio` (R91.M5-002).

| Value    | QEMU flags emitted (by `run-qemu.sh`)                                                                     |
|----------|------------------------------------------------------------------------------------------------------------|
| `virtio` | `-netdev user,id=net0,hostfwd=tcp::0-:0[,hostfwd=...]` `-device virtio-net-pci,netdev=net0`               |
| `e1000e` | `-netdev user,id=net0,hostfwd=tcp::0-:0[,hostfwd=...]` `-device e1000e,netdev=net0`                       |
| `rtl8139`| `-netdev user,id=net0[,hostfwd=...]` `-device rtl8139,netdev=net0`                                        |
| `none`   | no NIC flags emitted (opt-in for bit-identical pre-R91 arg lists on non-network smokes)                    |

The dispatch cascade at `src/kernel/core/net/nic_dispatch.pdx` probes
all three regardless of which `-device` QEMU attached; the driver
whose PCI IDs match is the one that lands in the KIND_NIC row and
sets `_active_nic_kind` (1=e1000e, 2=virtio, 3=rtl8139, 0=none).

### `PAIDEIA_HOSTFWD` = `<hostfwd-spec>[,<hostfwd-spec>...]`

Extra `hostfwd=` fragments appended to the SLIRP `-netdev user`
argument (R94.M6-003 #2075). Comma-separated for multiple rules;
ignored when `PAIDEIA_NIC=none`.

Example — R94 off-box TCP smoke lane:
```
PAIDEIA_HOSTFWD='tcp::5555-:5555' tools/run-qemu.sh
```
yields
```
-netdev user,id=net0,hostfwd=tcp::0-:0,hostfwd=tcp::5555-:5555
```
The default `hostfwd=tcp::0-:0` placeholder is a wildcard QEMU
accepts but never binds — retained so pre-R94 smokes see byte-
identical arg lists.

### `PAIDEIA_NET_SMOKE` = `0 | 1`

Read by `tools/run-smoke.sh`, NOT by `run-qemu.sh` directly.
Gates the three networking-smoke lane modes (`boot_r91_nic`,
`boot_r93_udp_dns`, `boot_r94_tcp_offbox`) — each refuses cleanly
outside the lane (R98.M1-002 #2101). The `boot_net_smoke` composite
mode sets it for its child invocations. Setting it on `run-qemu.sh`
has no direct effect on QEMU flags.

---

## 2. Full example — R94 off-box TCP smoke

Composite invocation (main way — one command, one green/red rollup):

```bash
bash tools/run-smoke.sh boot_net_smoke
```

That composite performs, in order:
1. `PAIDEIA_NET_SMOKE=1 bash tools/run-smoke.sh boot_r91_nic`
2. `PAIDEIA_NET_SMOKE=1 bash tools/run-smoke.sh boot_r93_udp_dns`
3. Starts `tools/net-smoke-httpd.sh` on host tcp/5555 (PAYLOAD=`PONG`).
4. `PAIDEIA_NET_SMOKE=1 PAIDEIA_HOSTFWD='tcp::5555-:5555' bash tools/run-smoke.sh boot_r94_tcp_offbox`.
5. Kills the responder, emits `smoke: boot_net_smoke lane passed -- ...`.

Manual invocation of the R94 leg alone (equivalent):
```bash
PORT=5555 PAYLOAD=PONG bash tools/net-smoke-httpd.sh &
sleep 0.2
PAIDEIA_NET_SMOKE=1 \
PAIDEIA_HOSTFWD='tcp::5555-:5555' \
    bash tools/run-smoke.sh boot_r94_tcp_offbox
wait
```

The R94 witness at `src/kernel/boot/witness/r94_tcp_offbox.pdx`
connects out through virtio-net rings, sends 4 B "PING", drains 4 B
"PONG", and orderly-closes. The tightened golden at
`tests/expected-r94-tcp-offbox.golden` (R98.M2-002 #2103) pins
`bytes=4` — mismatched responder byte counts fail cleanly.

---

## 3. SLIRP addressing envelope

QEMU SLIRP is a user-mode virtual network in the QEMU process.
When `PAIDEIA_NIC` is `virtio`, `e1000e`, or `rtl8139`, the guest sees:

| Role         | IPv4          | Notes                                                    |
|--------------|---------------|----------------------------------------------------------|
| Guest        | `10.0.2.15/24`| Assigned via SLIRP's built-in DHCP server (R93 lease).   |
| Gateway      | `10.0.2.2`    | R92 ICMP witness pings this; SLIRP proxies to host.      |
| DNS          | `10.0.2.3`    | R93 DNS witness queries this; SLIRP forwards to resolver.|
| Netmask      | `255.255.255.0` | /24 -- rt_init default matches SLIRP.                  |
| Broadcast    | `10.0.2.255`  | Never actually used on the wire at R94 scope.            |
| Host loopback| `10.0.2.2`    | Same as gateway -- hostfwd rules land on host `localhost`.|

IPv6 is not exposed. See `design/networking/ipv6-deferral.md` for
the three-reason rationale (R99+ scope).

---

## 4. Host prerequisites

| Tool     | Used by                        | Required for                              |
|----------|--------------------------------|-------------------------------------------|
| `qemu-system-x86_64` | every smoke        | boot                                       |
| `python3`| `tools/net-smoke-httpd.sh` (preferred) | R94 lane + future HTTP smoke      |
| `nc`     | `tools/net-smoke-httpd.sh` (fallback)  | R94 lane echo-mode only            |
| `timeout`| every smoke                    | bounded smoke wall-clock                   |
| `mktemp` | every smoke                    | serial-log staging                         |

The composite `boot_net_smoke` preflights for python3 OR nc; if both
are absent it skips cleanly (rc=0 with a diagnostic) rather than
failing the R94 leg on a missing responder.

---

## 5. What each lane member proves

| Mode                  | Witness file                                          | Proves                                                                                    |
|-----------------------|-------------------------------------------------------|-------------------------------------------------------------------------------------------|
| `boot_r91_nic`        | `boot/witness/r91_nic_probe.pdx`                      | NIC dispatch cascade -> KIND_NIC published -> readback via `nic_dispatch_mac` / `_link`.  |
| `boot_r92_icmp`       | `boot/witness/r92_icmp_ping.pdx`                      | route table mutable; ARP resolve against SLIRP gw; ICMP echo (permissive skip variant).   |
| `boot_r93_udp_dns`    | `boot/witness/r93_udp_dns.pdx`                        | DHCP DISCOVER/OFFER/REQUEST/ACK; A-record resolve of `example.com`.                       |
| `boot_r94_tcp_offbox` | `boot/witness/r94_tcp_offbox.pdx`                     | virtio TX/RX ring; TCP 3-way handshake to `localhost:5555`; 4 B payload roundtrip; close. |

`boot_r92_icmp` is deliberately NOT gated behind `PAIDEIA_NET_SMOKE`
today (its permissive skip golden means it is harmless outside the
lane); the composite `boot_net_smoke` still runs the three R91/R93/R94
members strictly because those are the ones whose goldens either
require an external responder or would drift into a "lane not
opted-in" state.

---

## 6. Non-scope notes (deliberate)

- **IPv6.** Deferred through R99. `design/networking/ipv6-deferral.md`.
- **TLS.** User-space only per NET-D6 / R97 ratification.
  `design/networking/tls-placement-decision.md`.
- **Multi-NIC.** Single-active-NIC MVP through the R91-R94 wave;
  multi-iface deferred (R91-plan.md deferred items).
- **TAP / bridge modes.** Not wired -- SLIRP suffices for all R91-R94
  smokes and doesn't require host `CAP_NET_ADMIN` or a bridge helper.

---

## 7. Cross-references

- `tools/run-qemu.sh` — `--help` (R98.M3-001) prints a summary of §1.
- `tools/run-smoke.sh` — mode headers cite this document.
- `tools/net-smoke-httpd.sh` — the host responder for the R94 lane.
- `design/networking/r91-plan.md` — the wave plan §17 sysno reservations.
- `design/round-retrospectives/r91-closed.md` .. `r98-closed.md` —
  per-round dispositions covering every line above.
- `design/round-retrospectives/r91-r98-wave-closed.md` — the wave-
  closing retrospective this catalogue feeds into.
