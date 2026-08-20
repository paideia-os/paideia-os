# R38.M6 regdomain enforcement hardware smoke — operator recipe (T14 G4)

**Owner issue:** #1317 (R38.M6-004, `gated:hardware`).
**Status:** **UNSEEDED.** Every procedure below is written to be run on a
real ThinkPad T14 Gen 4 with a real Intel AX211 CNVi Wi-Fi radio, and no
expected values are recorded, because recording an expected value nobody
measured is the failure this file exists to avoid.

This follows the discipline of `tools/hw-smoke-r37-guc.md`,
`tools/hw-smoke-r35-hotplug.md`, `tools/hw-smoke-r34-isoch.md`,
`tools/hw-smoke-r34.md`, `tools/hw-smoke-r30.md` and
`tools/hw-smoke-fingerprints.md`: the recipe lands before first light,
and the expectations are filled in from a real capture, at which point
the corresponding check promotes from SKIP to LIVE.

---

## 0. Scope

This document is the operator-run recipe that promotes the
regulatory-domain composition landed across R38.M6 (#1314-#1316) from
a QEMU-OVMF structural witness to a real-hardware acceptance witness
on the T14 G4.  It exercises the **regdom composition** — country
code discovery, regdom mapping, and channel-set enforcement — end to
end against the AX211 CNVi transport.

The wire this smoke exercises:

- `src/kernel/core/drivers/wifi/regdom_loader.pdx` — country-code
  resolver (EEPROM path + WW default), publishes to net80211_regdom
  via `nrd_bind`.
- `src/kernel/core/drivers/wifi/geo_hint.pdx` — two-tier discovery
  (USB modem GNSS via R40 stub, WW fallback), reports
  (country_code, source, confidence).
- `src/kernel/core/ipc/regdomain_channel.pdx` — periodic
  {country_code, source, timestamp} wire hint schema.
- `src/kernel/core/drivers/wifi/net80211_regdom.pdx` — the CHANNEL
  ADMISSION gate that refuses out-of-domain transmit and
  channel-switch attempts.

None of this is wired into `kernel_main_uefi` at boot on either
target — the R38.M6 witnesses run only from the boot-witness chain
in QEMU-OVMF (`R30Platform`), which resets both regdom_loader and
net80211_regdom on entry and on exit.  There is no live CNVi
transport binding on the QEMU path, no radio EEPROM to read, and no
USB modem to poll for a GNSS lock; that wiring is R38.M7+ (live
supervisor) and R40 (USB modem) scope.

---

## 1. Prerequisites

### 1.1 Hardware

- T14 G4 physical unit (Intel Raptor Lake, MVP target — the AX211
  CNVi-attached Wi-Fi is the qualified path).
- A working 2.4 GHz access point per region under test, on an
  agreed-in-advance channel:
  - US test: an AP on channel 6.
  - EU test: an AP on channel 13.
  - JP test: an AP on channel 14.
- Optional: a USB CDC-ACM GNSS receiver (u-blox 7 class or later)
  with a fix in a known region, for the R40 GNSS-arbitration test
  in §2.5.  A receiver without a fix at recipe time is fine —
  the fallback branch is exercised in that case.
- Serial-over-USB or ethernet-tethered GDB stub, per
  `tools/xhci-keyboard-smoke.md §1.1`.

### 1.2 Firmware / BIOS toggles

Same as `tools/xhci-keyboard-smoke.md §1.2`, plus:
- Wi-Fi enabled in BIOS and the CNVi transport not blocked by a
  region-lock signed image (a locked CNVi will refuse regdom
  overrides regardless of what this recipe attempts).
- Intel VT-d **disabled** for the first-light capture.  VT-d routes
  CNVi MMIO through the IOMMU, which is a later-wave scope.

### 1.3 Software

- `build/kernel.elf` from `bash tools/build.sh` (must pass all
  gates, including the R38.M6 `r38-m6-confine` one-writer check).
- UEFI boot image via `tools/build-uefi-image.sh`.
- GDB with `gdb-multiarch`.

---

## 2. Operator recipe

### 2.1 Reset composition, verify unbound

1. Boot the T14 G4.
2. Attach GDB; break on any post-`R30Platform` witness.
3. Reset the composition to a clean state:
   ```
   (gdb) call rdl_reset()
   (gdb) call gh_reset()
   (gdb) call nrd_reset()
   ```
4. Assert unloaded / unqueried / unbound:
   ```
   (gdb) call rdl_loaded()     ; expect 0
   (gdb) call gh_queried()     ; expect 0
   (gdb) call nrd_bound()      ; expect 0
   ```

**Acceptance:** the three-module composition begins clean.  **Expected
values as specified above.**

### 2.2 EEPROM path: country code from radio OTP

This is the load-bearing bring-up path.  A qualified AX211 has a
country code programmed in its OTP; this section reads it and
publishes.

1. Read the country code the AX211 CNVi reports (via a future R38.M7
   `wifi_ctl_read_regdom` verb; until that lands, substitute a
   known-good ISO code for the region you are in, packed as ASCII
   u16, e.g. `0x5553` for US, `0x4555` for EU, `0x4A50` for JP):
   ```
   (gdb) call rdl_load_eeprom($cc)
   ```
   Assert `== 0` (`RDL_OK`).
2. Read the recorded state:
   ```
   (gdb) call rdl_loaded()     ; expect 1
   (gdb) call rdl_source()     ; expect 1 (RDL_SRC_EEPROM)
   (gdb) call rdl_country()    ; expect $cc
   ```
3. Publish to net80211_regdom:
   ```
   (gdb) call rdl_publish()
   ```
   Assert `== 0` (`RDL_OK`).
4. Read the bound regdom:
   ```
   (gdb) call nrd_bound()      ; expect 1
   (gdb) call nrd_regdom()     ; expect 1 (US) / 2 (EU) / 3 (JP)
   ```

**Acceptance:** the EEPROM path resolves to the expected NRD domain.
**Expected values: NOT YET MEASURED on a live AX211.**

This assertion promotes from SKIP to LIVE when R38.M7 lands the
`wifi_ctl_read_regdom` verb; until then substitute a manual `$cc`
matching the region under test.

### 2.3 Channel-set enforcement per region

For each region under test, assert the correct channel set is
admitted / refused:

**US-bound (`nrd_regdom() == 1`), test channels 1..14:**
```
(gdb) call nrd_channel_allowed(1)    ; expect 1
(gdb) call nrd_channel_allowed(6)    ; expect 1
(gdb) call nrd_channel_allowed(11)   ; expect 1
(gdb) call nrd_channel_allowed(12)   ; expect 0
(gdb) call nrd_channel_allowed(13)   ; expect 0
(gdb) call nrd_channel_allowed(14)   ; expect 0
```

**EU-bound (`nrd_regdom() == 2`):**
```
(gdb) call nrd_channel_allowed(11)   ; expect 1
(gdb) call nrd_channel_allowed(12)   ; expect 1
(gdb) call nrd_channel_allowed(13)   ; expect 1
(gdb) call nrd_channel_allowed(14)   ; expect 0
```

**JP-bound (`nrd_regdom() == 3`):**
```
(gdb) call nrd_channel_allowed(13)   ; expect 1
(gdb) call nrd_channel_allowed(14)   ; expect 1
```

**Acceptance:** the boundary channels are admitted / refused per
region.  **Expected values as specified above** (these are numeric
constants from `net80211_regdom.pdx §1`).

### 2.4 Transmit refuse gate

For each region under test, attempt a transmit against a channel
outside the admitted set and assert the tx_check gate refuses:

**US-bound, transmit on channel 12:**
```
(gdb) call nrd_tx_check(12)
```
Assert `== 0xFFFFF3FC` (`NRD_CHANNEL_FORBIDDEN`).

**US-bound, transmit on channel 15 (out of 2.4 GHz range):**
```
(gdb) call nrd_tx_check(15)
```
Assert `== 0xFFFFF3FA` (`NRD_BAD_CHANNEL`).

**Live-radio validation** (requires the R38.M7 tx wire): configure
the AX211 to channel 12, then attempt a beacon transmit.  Assert
the transmit was NOT emitted on-air (verify with a second
capturing radio in monitor mode on channel 12).

**Acceptance:** the class driver refuses out-of-domain transmits
before any bytes reach the doorbell.  **Live-radio half: NOT YET
MEASURED.**

### 2.5 GNSS arbitration (optional; requires USB GNSS receiver)

This section requires R40 to have landed the USB modem CDC-ACM
transport wire that `gh_query_gnss_stub` currently stubs out.
Until R40 lands, skip this section — `gh_arbitrated()` returns 0
and this branch is dormant.

1. Ensure a USB CDC-ACM GNSS receiver is present with a fix.
2. Reset and query:
   ```
   (gdb) call gh_reset()
   (gdb) call gh_query(<modem_id>)
   ```
   Assert `== 0` (`GH_OK`).
3. Read the recorded state:
   ```
   (gdb) call gh_queried()      ; expect 1
   (gdb) call gh_source()       ; expect 2 (GH_SRC_GNSS)
   (gdb) call gh_country()      ; expect the ISO code matching
                                ;   the fix (e.g. 0x5553 in the US)
   (gdb) call gh_confidence()   ; expect 100 (GH_CONF_HIGH)
   ```

**Acceptance:** with a live GNSS fix, the discovery reports the
correct region at HIGH confidence.  **Expected values: NOT YET
MEASURED.**

### 2.6 WW fallback

1. With no GNSS receiver (or receiver removed):
   ```
   (gdb) call gh_reset()
   (gdb) call rdl_reset()
   (gdb) call gh_query(0)
   ```
   Assert `== 0`.
2. Read the state:
   ```
   (gdb) call gh_source()       ; expect 3 (GH_SRC_DEFAULT)
   (gdb) call gh_country()      ; expect 0x5757 (WW)
   (gdb) call gh_confidence()   ; expect 10 (GH_CONF_LOW)
   ```
3. Load default and publish:
   ```
   (gdb) call rdl_load_default()
   (gdb) call rdl_publish()
   (gdb) call nrd_regdom()      ; expect 1 (US-safe subset)
   ```
4. Assert channel 11 is admitted (US-subset) and channel 12 is
   refused:
   ```
   (gdb) call nrd_channel_allowed(11)  ; expect 1
   (gdb) call nrd_channel_allowed(12)  ; expect 0
   ```

**Acceptance:** the fallback path lands the safest 2.4 GHz subset.
**Expected values as specified above.**

---

## 3. Quirks-database promotion pass

On successful live capture, add a row to `design/hardware/quirks.md`
for the specific AX211 stepping used (vendor/device ID from lspci,
CNVi generation, observed OTP country code, whether the CNVi
transport honoured the regdom override).  Any deviation observed (a
CNVi that refuses regdom overrides despite BIOS toggles, an EEPROM
that reports a country code outside the loader's known set, a
handshake that reproducibly times out) gets its own row with the
observed behavior and the R38.M6 handling gap.

---

## 4. Related documents

- `design/roadmap/next-wave-synthesis.md §2` — R38 round scope.
- `design/roadmap/next-wave-softarch.md §3` — R38 milestone breakdown.
- `tools/hw-smoke-r37-guc.md` — sibling UNSEEDED recipe for R37.M2;
  same discipline.
- `tools/hw-smoke-r34-isoch.md` — sibling UNSEEDED recipe for R34.M5.
- `tools/hw-smoke-r35-hotplug.md` — sibling UNSEEDED recipe for R35.M1.
- `tools/hw-smoke-r30.md` — sibling UNSEEDED recipe for R30.M9.
- `tools/xhci-keyboard-smoke.md` — sibling recipe for the R26 xHCI
  keyboard smoke.
- `tests/kernel/drivers/wifi/regdom_loader_synth.pdx`,
  `tests/kernel/ipc/regdomain_channel_synth.pdx`,
  `tests/kernel/drivers/wifi/geo_hint_synth.pdx` — the QEMU-OVMF
  structural witnesses this recipe promotes from.
- `tests/kernel/drivers/wifi/hw_smoke_regdom_placeholder.pdx` —
  the dormant placeholder module this recipe drives.
