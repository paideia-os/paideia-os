# R38.M7 WiFi feature hardware smoke — operator recipe (T14 G4)

**Owner issue:** #1322 (R38.M7-005, `gated:hardware`).
**Status:** **UNSEEDED.** Every procedure below is written to be run on a
real ThinkPad T14 Gen 4 with a real Intel AX211 CNVi Wi-Fi radio, and no
expected values are recorded, because recording an expected value nobody
measured is the failure this file exists to avoid.

This follows the discipline of `tools/hw-smoke-r38-regdom.md`,
`tools/hw-smoke-r37-guc.md`, `tools/hw-smoke-r35-hotplug.md`,
`tools/hw-smoke-r34-isoch.md`, `tools/hw-smoke-r34.md`,
`tools/hw-smoke-r30.md` and `tools/hw-smoke-fingerprints.md`: the recipe
lands before first light, and the expectations are filled in from a real
capture, at which point the corresponding check promotes from SKIP to
LIVE.

---

## 0. Scope

This document is the operator-run recipe that promotes the WiFi feature
composition landed across R38.M7 (#1318-#1321) from a QEMU-OVMF
structural witness to a real-hardware acceptance witness on the T14 G4.
It exercises the **WiFi feature wire** — HE-MCS rate tables, PER-driven
rate adaptation, scan-while-connected roaming, and rekey rotation — end
to end against the AX211 CNVi transport.

The wire this smoke exercises:

- `src/kernel/core/drivers/wifi/he_mcs.pdx` — 802.11ax HE MCS 0..11
  rate table + MU-MIMO group/user metadata.
- `src/kernel/core/drivers/wifi/rate_control.pdx` — PER-driven
  adaptive rate control per {peer, MCS} with a 64-packet rolling
  window (step down at PER > 20%, step up at PER < 5%).
- `src/kernel/core/drivers/wifi/roaming.pdx` — scan-while-connected
  cadence, weighted candidate scoring (RSSI + load + speed), reassoc
  trigger via net80211_assoc.
- `src/kernel/core/drivers/wifi/rekey.pdx` — PTK/GTK rotation FSM
  composed with wpa_4way; retains the old KIND_WIFI_KEY slot briefly
  for in-flight decrypt.

None of this is wired into `kernel_main_uefi` at boot on either target
— the R38.M7 witnesses run only from the boot-witness chain in
QEMU-OVMF (`R30Platform`), which resets every module on entry and on
exit.  There is no live CNVi transport binding on the QEMU path, no
neighbouring AP to roam to, and no over-the-air 4-way handshake to
rekey; that wiring is R38.M8+ (live supervisor) scope.

---

## 1. Prerequisites

### 1.1 Hardware

- T14 G4 physical unit (Intel Raptor Lake, MVP target — the AX211
  CNVi-attached Wi-Fi is the qualified path).
- Two 802.11ax APs on the same SSID, same PSK, different channels
  (e.g. channel 6 + channel 149) for the roaming test — placed so
  that walking from one to the other flips the stronger BSSID at a
  predictable distance.
- A WPA3-SAE or WPA2-PSK AP configured to force a GTK rekey every
  60 seconds (hostapd `wpa_group_rekey=60`) for the rekey test.
- Serial-over-USB or ethernet-tethered GDB stub, per
  `tools/xhci-keyboard-smoke.md §1.1`.

### 1.2 Firmware / BIOS toggles

Same as `tools/xhci-keyboard-smoke.md §1.2`, plus:
- Wi-Fi enabled in BIOS and the CNVi transport not blocked by a
  region-lock signed image.
- Intel VT-d **disabled** for the first-light capture.  VT-d routes
  CNVi MMIO through the IOMMU, which is a later-wave scope.

### 1.3 Software

- `build/kernel.elf` from `bash tools/build.sh` (must pass all
  QEMU-OVMF fingerprints in `tests/r17/shell-shutdown.golden`,
  including `R38 HE MCS OK`, `R38 RATE CONTROL OK`, `R38 ROAMING OK`,
  `R38 REKEY OK`).
- A `wpa_supplicant`-equivalent ring-3 supervisor (deferred to
  R38.M8+) that drives the composition into `kernel_main_uefi`.

---

## 2. Procedure

Each subsection is a distinct check.  Every one starts SKIP; every
one is promoted to LIVE by observing a real value on the T14 G4 and
recording it in the *Expected* box.  A LIVE check whose observation
disagrees with the recorded value is a REGRESSION — the recorded
value is what R38.M7 landed against, not what a passing boot happens
to produce this month.

### 2.1 Rate-table peak lookup (HE-MCS)

Purpose: verify that `hem_rate_lookup(MCS11, 160MHz, 0.8us, 2NSS)`
returns the standard-defined 2288 Mbps on the target.

Steps (deferred to R38.M8+ supervisor):
1. Boot with the ring-3 supervisor that binds a KIND_WIFI_PHY.
2. Issue an IPC call `he_rate_lookup(11, 3, 0, 2)` and read the
   returned Mbps.

Expected: **UNSEEDED.**

### 2.2 PER-driven rate adaptation (rate_control)

Purpose: verify that `rc2_decide` steps DOWN on a lossy peer and
steps UP on a clean peer over 64-sample windows.

Steps (deferred to R38.M8+ supervisor):
1. Associate to the primary AP.  Read `rc2_current_mcs(peer)` after
   1 second of quiescent traffic — record as `initial_mcs`.
2. Attenuate the primary AP path (move the machine 3–5 m further
   away).  Wait 10 seconds; read `rc2_current_mcs(peer)` again —
   record as `attenuated_mcs`.  Verify `attenuated_mcs < initial_mcs`.
3. Restore proximity.  Wait 10 seconds; read `rc2_current_mcs(peer)`
   — verify it climbs back toward `initial_mcs`.

Expected: **UNSEEDED.**

### 2.3 Roaming reassoc (roaming)

Purpose: verify that a stronger candidate triggers a reassoc.

Steps (deferred to R38.M8+ supervisor):
1. Associate to AP-A on channel 6, positioned close.
2. Physically walk toward AP-B on channel 149 until AP-B's beacon
   RSSI (as reported through `rm_candidate_report`) exceeds AP-A's
   by more than `RM_MARGIN` (32 units by default).
3. Verify that `rm_decide()` returns AP-B's BSSID and that the
   subsequent `rm_trigger_reassoc` completes with the current
   BSSID switched to AP-B (readable via `rm_current_bssid`).

Expected: **UNSEEDED.**

### 2.4 Rekey rotation (rekey)

Purpose: verify that the AP's periodic GTK rekey is admitted and
that the retired slot is briefly retained.

Steps (deferred to R38.M8+ supervisor):
1. Associate to the AP configured with `wpa_group_rekey=60`.
2. Read `rk_current_key_slot()` — record as `slot0`.
3. Wait 65 seconds.  Read `rk_current_key_slot()` — record as
   `slot1`.  Verify `slot1 != slot0`.
4. Read `rk_retired_slot()` within the retention window (bounded
   in the driver; consult `src/kernel/core/drivers/wifi/rekey.pdx`
   §1 for the concrete bound once R38.M8+ lands that policy).
   Verify it equals `slot0` briefly, then transitions to 0.
5. Read `rk_rotate_count()` — verify it incremented by 1.

Expected: **UNSEEDED.**

---

## 3. What promotes this document from UNSEEDED to LIVE

- All four sub-checks recorded against a single physical unit + AP
  environment.
- Every SKIP mark replaced with a concrete measurement.
- The four QEMU-OVMF fingerprints (`R38 HE MCS OK`, `R38 RATE
  CONTROL OK`, `R38 ROAMING OK`, `R38 REKEY OK`) still pass on the
  same `build/kernel.elf` used for the hardware capture.
- A follow-up issue lands `tests/kernel/drivers/wifi/hw_smoke_wifi.pdx`
  replacing the placeholder in
  `tests/kernel/drivers/wifi/hw_smoke_wifi_placeholder.pdx`.
