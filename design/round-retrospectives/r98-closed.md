# R98 Retrospective: net-tools smoke lane consolidation

**Date:** 2026-09-02
**Milestones:** R98.M1 (net-smoke composite + PAIDEIA_NET_SMOKE gate),
R98.M2 (net-smoke-httpd + tightened R94 golden), R98.M3 (PAIDEIA_*
flag consolidation + design doc), R98.M4 (round closure retrospective).
**Issues closed at landing:** #2100, #2101, #2102, #2103, #2104, #2105,
#2106.
**HEAD at closure:** paideia-os (this landing).
**Release tag:** `r98-closed` recommended -- R98 is a tooling round
so the "attests on every boot" criterion the earlier R91-R97 tags used
does not apply; the substitute discipline is that `boot_net_smoke`
passes cleanly against the tightened R94 golden.

## Round intent

The R91-R97 wave landed three NIC drivers, ARP + route table + ICMP,
DHCP + UDP + DNS, TCP + off-box, socket API + poll, MAC-spoof / IOMMU /
priv-port hardening, and the TLS placement decision. What it did NOT
land was a single opt-in flag that runs the whole networking smoke
matrix as one green/red rollup, and the R94 off-box golden was
deliberately permissive (admitted a skip variant) so that a stock
`git push` on a host without a background responder would not gate on
the R94 leg. R98 consolidates: one composite mode, one env var, one
strict golden, one host-side responder, one design doc for the QEMU
invocation catalogue.

R98 is a tooling round. No `.pdx` code lands; the changes are
`tools/`, `tests/expected-*.golden`, and `design/`.

## Per-milestone disposition

### R98.M1 -- net-smoke composite + PAIDEIA_NET_SMOKE gate -- LANDED

* **#2100 (M1-001) -- Composite lane.**
  Added `boot_net_smoke` synthetic mode to `tools/run-smoke.sh`. Runs
  the three lane members in order:
  1. `boot_r91_nic` (cheapest -- pins the R91.M5-003 fingerprint that
     fires on every boot; NEW MODE this round, retires R91.M6 deferred
     item #8).
  2. `boot_r93_udp_dns` (DHCP + DNS against SLIRP built-ins; no
     external responder).
  3. `boot_r94_tcp_offbox` (needs `tools/net-smoke-httpd.sh` on host
     tcp/5555).
  Aborts on first failure. Emits `smoke: boot_net_smoke lane passed
  -- boot_r91_nic=ok boot_r93_udp_dns=ok boot_r94_tcp_offbox=ok` as
  the rollup line. Sets `PAIDEIA_NET_SMOKE=1` + `PAIDEIA_HOSTFWD=
  'tcp::5555-:5555'` for its children. Uses a `trap _netsmoke_cleanup
  EXIT` guard so the responder is reaped whether the R94 leg passes,
  fails, or the shell is interrupted mid-lane.

  **Spec ambiguity resolved:** the R98 planning brief named
  `boot_r91_nic` as one of the three consolidated modes, but that
  mode did not yet exist -- R91.M6-closed.md's deferred item #8
  flagged `boot_r91_nic smoke mode + expected-r91-nic-probe.golden`
  as not-yet-landed. The composite depends on it, so this issue
  created it. Reads the R91.M5-003 witness's `boot r91 nic probe ok`
  fingerprint from a new golden at
  `tests/r91/expected-r91-nic-probe.golden`.

* **#2101 (M1-002) -- PAIDEIA_NET_SMOKE gate.**
  Each of the three lane members (`boot_r91_nic`, `boot_r93_udp_dns`,
  `boot_r94_tcp_offbox`) now refuses cleanly outside the lane:
  ```
  if [[ "${PAIDEIA_NET_SMOKE:-0}" != "1" ]]; then
      echo "smoke: ... skipped (PAIDEIA_NET_SMOKE!=1; opt-in via composite boot_net_smoke)"
      exit 0
  fi
  ```
  Matches the `PAIDEIA_R72_TCP=1` gate precedent that sits below it
  in `.githooks/pre-push`. `boot_r92_icmp` is deliberately NOT gated
  -- its permissive skip golden means it is harmless outside the lane
  and it already runs in the default matrix by virtue of being wired
  into every boot.

### R98.M2 -- net-smoke-httpd + tightened R94 golden -- LANDED

* **#2102 (M2-001) -- `tools/net-smoke-httpd.sh`.**
  New minimal single-shot TCP responder. Prefers `python3` (universal
  on Linux, byte-exact writes, supports `MODE=http` for future
  R100+ pdxcurl smokes); falls back to `nc -l ... -N` / `nc -l -q 1`
  when python3 is absent (echo mode only). Configurable via env vars
  (`PORT`, `PAYLOAD`, `MODE`, `HANG`) with defaults chosen for the
  R94 lane (`PORT=5555`, `PAYLOAD=PONG`, `MODE=echo`, `HANG=3`).
  Exit codes: 0 = one client served, 1 = bind refused / neither
  interpreter present, 124 = HANG budget elapsed with no client
  connection.

  **Spec ambiguity resolved:** the R98 planning brief suggested
  `port 8080` with an HTTP envelope response. The R94 witness that
  is actually the lane's consumer uses port 5555 with a raw echo
  reply. Reconciled by making the tool configurable (defaults match
  R94; `MODE=http` fires the HTTP envelope path for future use).

* **#2103 (M2-002) -- Tightened R94 golden.**
  `tests/expected-r94-tcp-offbox.golden` moved from the permissive
  substring
  ```
  boot r94 offbox
  ```
  to the strict two-line ok pair
  ```
  boot r94 offbox handshake ok --
  boot r94 offbox roundtrip ok -- bytes=4
  ```
  `bytes=4` pins the responder's `PAYLOAD="PONG"` default. A run
  outside the lane never reaches this file (the mode is now gated
  behind `PAIDEIA_NET_SMOKE=1` per M1-002); a run inside the lane
  either produces the ok pair (all-green) or fails cleanly on the
  missing line (real regression signal, not a skip masquerading as
  pass).

### R98.M3 -- PAIDEIA_* flag consolidation + design doc -- LANDED

* **#2104 (M3-001) -- `run-qemu.sh --help`.**
  Added a `--help` / `-h` branch to `tools/run-qemu.sh` that prints a
  short summary of PAIDEIA_NIC / PAIDEIA_HOSTFWD / PAIDEIA_NET_SMOKE
  with example invocations and a pointer to the full catalogue in
  `design/networking/qemu-net-invocation.md`. Runs before the kernel-
  existence check so `--help` works even on a fresh clone without
  `build/kernel.elf`.

* **#2105 (M3-002) -- QEMU networking invocation catalogue.**
  New doc `design/networking/qemu-net-invocation.md` (~180 lines).
  Sections: env-var interface table; full R94 lane example
  (composite + manual invocation); SLIRP addressing envelope table
  (10.0.2.0/24, 10.0.2.2 gw, 10.0.2.3 dns); host prerequisites
  table; per-lane-member proof table; non-scope notes (IPv6 / TLS /
  multi-NIC / TAP-bridge deferrals); cross-reference table.
  Pointed to from `tools/run-qemu.sh --help` and `tools/run-smoke.sh`
  mode headers.

### R98.M4 -- round closure -- LANDED

* **#2106 (M4-001) -- This retrospective.**
  Companion `r91-r98-wave-closed.md` (R99.M1-001 #2107) covers the
  wave-level view.

## What did NOT land in R98

* **No `.pdx` code.** R98 is a tooling round.
* **No CI hookup.** paideia-os has no GitHub Actions (per project
  memory `feedback_paideia_os_no_cicd`); the lane is invoked
  operator-side via `PAIDEIA_NET_SMOKE=1 bash tools/run-smoke.sh
  boot_net_smoke`. A future landing may add a `PAIDEIA_NET_SMOKE=1`
  opt-in block to `.githooks/pre-push` mirroring `PAIDEIA_R72_TCP=1`
  once the lane has a run of consecutive clean passes on green tree.
* **No `pdxcurl` HTTP smoke.** `MODE=http` in `net-smoke-httpd.sh`
  is ready for a future R100+ smoke that exercises a real HTTP
  client, but no such witness exists at R98 close.
* **No IPv6 lane member.** Per `design/networking/ipv6-deferral.md`
  IPv6 remains deferred through R99; R98 does not touch it.

## Spec ambiguities resolved during landing

* **`boot_r91_nic` mode did not pre-exist.** R91.M6-closed.md's
  deferred item #8 flagged it; this round created it as part of
  #2100's composite dependency chain.
* **httpd port and payload shape.** Planning brief said port 8080 +
  HTTP envelope; R94 needs port 5555 + raw echo. Tool made
  configurable with R94-matching defaults + optional `MODE=http`.
* **Golden tightening breaks the skip path.** True by design -- the
  mode is now gated behind `PAIDEIA_NET_SMOKE=1` so the skip variant
  is unreachable inside the lane and irrelevant outside it.
* **`boot_r92_icmp` gating.** Not in the R98 gate scope. Its
  permissive skip golden is intentional (see R92.M3 comment thread
  + `design/round-retrospectives/r92-closed.md` deferred item #2 --
  rt_init subnet mismatch means the ok path is unreachable until R93
  DHCP installs the SLIRP-matching address before witness runs; R93
  now does exactly that, so a future round can also tighten R92's
  golden and add it to the composite).

## Files touched

| File | Kind | Notes |
|---|---|---|
| `tools/run-smoke.sh` | edit | +boot_r91_nic mode; +boot_net_smoke composite; +PAIDEIA_NET_SMOKE gate on R91/R93/R94; header docstring updates |
| `tools/run-qemu.sh` | edit | +--help / -h branch |
| `tools/net-smoke-httpd.sh` | new (~90 lines) | R98.M2-001 responder |
| `tests/r91/expected-r91-nic-probe.golden` | new (1 line) | R98.M1-001 fingerprint |
| `tests/expected-r94-tcp-offbox.golden` | edit | R98.M2-002 strict two-line ok pair |
| `design/networking/qemu-net-invocation.md` | new doc (~180 lines) | R98.M3-002 catalogue |
| `design/round-retrospectives/r98-closed.md` | new doc (this file) | R98.M4-001 |

## Cross-references

* `design/round-retrospectives/r91-closed.md` -- deferred item #8
  (boot_r91_nic mode) retired by #2100.
* `design/round-retrospectives/r94-closed.md` -- the "permissive
  substring" R94 golden this round tightens.
* `design/networking/qemu-net-invocation.md` -- catalogue R98.M3-002
  lands.
* `design/round-retrospectives/r91-r98-wave-closed.md` -- the wave-
  level view (R99.M1-001 #2107).
* `.githooks/pre-push` -- carries the `PAIDEIA_R72_TCP=1` precedent
  the R98 lane gates copy verbatim.
