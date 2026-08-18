# R35.M1 PCIe hotplug hardware smoke — operator recipe (T14 G4)

**Owner issue:** #1199 (R35.M1-005, `gated:hardware`).
**Status:** **UNSEEDED.** Every procedure below is written to be run on a
real ThinkPad T14 Gen 4 with a real Thunderbolt 4 dock and no expected
values are recorded, because recording an expected value nobody
measured is the failure this file exists to avoid.

This follows the discipline of `tools/hw-smoke-r34-isoch.md`,
`tools/hw-smoke-r34.md`, `tools/hw-smoke-r30.md` and
`tools/hw-smoke-fingerprints.md`: the recipe lands before first light,
and the expectations are filled in from a real capture, at which point
the corresponding check promotes from SKIP to LIVE.

---

## 0. Scope

This document is the operator-run recipe that promotes the PCIe
hotplug substrate landed across R35.M1 (#1195-#1198) from a QEMU-OVMF
structural witness to a real-hardware acceptance witness on the T14
G4. It exercises the **Thunderbolt 4 dock plug/unplug path** — the
PCIe root port under which Thunderbolt-tunneled devices arrive raises
Slot Status events on every physical connect/disconnect cycle, and
those events are what the R35.M1 fabric decodes, enqueues, and
retrains against.

The wire this smoke exercises:

- `src/kernel/core/cap/kind_pcie_hotplug_event.pdx` —
  KIND_PCIE_HOTPLUG_EVENT (0x16B), one root-port hotplug event
  subscription, derived over KIND_IPC_ENDPOINT.
- `src/kernel/core/drivers/pcie/hotplug_isr.pdx` — Slot Status
  decode + write-1-to-clear, per PCIe base §6.7.
- `src/kernel/core/ipc/pcie_hotplug_channel.pdx` — one-way event
  stream, per-endpoint fanout, subscriber routing.
- `src/kernel/core/drivers/pcie/link_retrain.pdx` — LTSSM Retrain
  Link sequence + Link Status polling + speed/width readback, per
  PCIe base §4.2.6.

None of this is wired into `kernel_main_uefi` at boot — the R35.M1
witnesses run only from the boot-witness chain in QEMU-OVMF
(`R30Platform`), which mints and scrubs its own fixtures. There is no
live MSI-X registration wire that would attach the ISR to the T14
G4's PCH-tunneled Thunderbolt root port; that wiring is R35.M2+ scope
(mirrors the R34.M3 → R34.M5 shape — see `tools/hw-smoke-r34.md §0`).

---

## 1. Prerequisites

### 1.1 Hardware

- T14 G4 physical unit (Intel Raptor Lake, MVP target — the Intel
  JHL8x40 Thunderbolt controller PCH-integrated variant is the
  qualified path).
- A Thunderbolt 4 dock. Any TB4-certified dock with an active
  passthrough port will do; Lenovo Thunderbolt 4 Dock (40B0) is the
  reference part.
- A test payload plugged INTO the dock — commonly a USB peripheral
  such that unplugging the dock also exercises the tunneled
  enumeration teardown path.
- Serial-over-USB or ethernet-tethered GDB stub, per
  `tools/xhci-keyboard-smoke.md §1.1`.

### 1.2 Firmware / BIOS toggles

Same as `tools/xhci-keyboard-smoke.md §1.2`, plus:
- Thunderbolt security level set to **User Authorisation** or
  **Secure Connect** (NOT No Security). This is what makes the
  hotplug event visible to the OS on connect — a No Security profile
  auto-authorises and can race the OS event handler.
- Intel VMD Controller **disabled** — VMD hides root ports behind
  a virtual bus and would move the Slot Status registers out of the
  address range this recipe walks.

### 1.3 Software

- `build/kernel.elf` from `bash tools/build.sh` (must pass all gates,
  including the R35.M1 `pcie-hp-evt-confine`, `pcie-hotplug-isr-confine`,
  `pcie-hotplug-channel-confine` and `pcie-link-retrain-confine`
  one-writer checks).
- UEFI boot image via `tools/build-uefi-image.sh`.
- GDB with `gdb-multiarch`.

---

## 2. Operator recipe

### 2.1 Root-port enumeration inventory

1. Boot the T14 G4 with NO Thunderbolt device attached.
2. Attach GDB; break on any post-`R30Platform` witness (`init_task`
   entry is safe).
3. Enumerate every PCIe root port with the Slot Implemented bit set:
   ```
   (gdb) call pci_walk_caps(...)   # placeholder until R35.M2 wires
                                   # a live root-port enumerator
   ```
   Record every {bus:dev.fn, physical slot number, Link Speed cap,
   Link Width cap} tuple.

**Acceptance:** at least one root port reports Slot Implemented and
identifies as the Thunderbolt controller downstream port. **Expected
values: NOT YET MEASURED.**

### 2.2 Hotplug event dispatch under 10x plug/unplug

This is the #1199 deliverable's core assertion.

1. Before the first plug, read the ISR stats cell via GDB:
   ```
   (gdb) p _pcie_hotplug_isr_stats
   ```
   Layout is `[INTERRUPTS, PRESENCE, DLL_CHANGE, CMD_DONE, POWER_FLT,
   SPURIOUS, REJECTS, _]`. Record baseline.
2. Plug the TB4 dock. Wait 2 seconds for the platform to stabilise.
   Re-read the stats. Assert:
   - `PRESENCE` incremented by exactly 1 (or 2 if a bounce is
     observed — record which and add a quirks row per §3).
   - `DLL_CHANGE` incremented by at least 1 (the link comes up).
   - `SPURIOUS` unchanged (every interrupt raised a handled bit).
   - `REJECTS` unchanged (the channel accepted every enqueue).
3. Unplug. Wait 2 seconds. Re-read the stats. Assert:
   - `PRESENCE` incremented by 1 (departure).
   - `DLL_CHANGE` incremented by at least 1 (the link goes down).
4. Repeat steps 2-3 **10 times** (a fresh plug cycle each time — do
   not reuse the enumerated state from a prior cycle).
5. After the 10th unplug, assert:
   - `INTERRUPTS == PRESENCE + DLL_CHANGE + CMD_DONE + POWER_FLT +
     SPURIOUS` (accounting closes — every interrupt was decoded).
   - Enumeration is CONSISTENT across all 10 cycles (the dock's
     downstream device tree reads the same from lspci-equivalent
     each time).

**Acceptance:** 10 consecutive cycles report the same event pattern
and enumeration converges to the same state after each plug. **Expected
values: NOT YET MEASURED.**

This assertion requires the R35.M2+ MSI-X registration wire (a live
KIND_HW_MSIX_VECTOR bound against the root port's service interrupt) —
the ISR path does not exist yet as a boot-time wire, only as the
scaffold each witness exercises against synthetic Slot Status
snapshots. Until that wiring lands, this section stays blocked and
the numbers stay at zero, matching the R30.M9 and R34.M3 `Blocked. Do
not attempt yet.` posture in `tools/hw-smoke-r34.md §2.2`.

### 2.3 Link retrain speed/width convergence

Once the ISR wire admits real Slot Status reads, this section becomes
runnable:

1. After the 5th plug in §2.2, break on `pcie_lr_sequence` with GDB.
2. Read the arguments: `ls_training`, `ls_done`, `iters_cap`.
3. Assert `iters_cap` in [1000, 100000] (a live driver's poll count
   for a 100 ms budget at 1 us..100 us poll periods).
4. Read `_pcie_link_retrain_stats[PCIE_LR_ST_TIMEOUTS]`. Assert 0
   across all 10 cycles (no dock/root-port combination timed out).
5. Continue past the return; capture the return value and decode
   speed[7:0] and width[13:8]. Assert:
   - `speed` in {3, 4, 5, 6} (TB4 negotiates at least 8.0 GT/s).
   - `width` in {1, 2, 4} (TB4 tunneled PCIe is x1 or x2 at most
     depending on the dock; some x4 docks exist).

**Acceptance:** every retrain completed within the caller's iters_cap
and negotiated a speed/width the dock's marketing claims. **Expected
values: NOT YET MEASURED.**

---

## 3. Quirks-database promotion pass

On successful live capture, add a row to `design/hardware/quirks.md
§2.5` for the specific TB4 dock used (vendor/product string from
Thunderbolt authorisation, dock model, observed event pattern per
plug, negotiated speed/width, whether presence-detect bounces on
connect). Any deviation observed (an unexpected COMMAND_COMPLETED
storm, a POWER_FAULT that never clears, a retrain that times out at
100 ms) gets its own row with the observed behavior and the R35.M1
handling gap.

---

## 4. Related documents

- `design/roadmap/next-wave-synthesis.md §2` — R35 round scope.
- `design/roadmap/next-wave-softarch.md §3` — R35 milestone breakdown.
- `tools/hw-smoke-r34-isoch.md` — sibling UNSEEDED recipe for R34.M5;
  same discipline.
- `tools/hw-smoke-r30.md` — sibling UNSEEDED recipe for R30.M9.
- `tools/xhci-keyboard-smoke.md` — sibling recipe for the R26 xHCI
  keyboard smoke; same shape for the hot-plug wiring this doc is
  blocked on.
- `tests/kernel/cap/pcie_hotplug_event_synth.pdx`,
  `tests/kernel/drivers/pcie/hotplug_isr_synth.pdx`,
  `tests/kernel/drivers/pcie/link_retrain_synth.pdx`,
  `tests/kernel/ipc/pcie_hotplug_channel_synth.pdx` — the QEMU-OVMF
  structural witnesses this recipe promotes from.
- `tests/kernel/drivers/pcie/hw_smoke_hotplug_placeholder.pdx` —
  the dormant placeholder module this recipe drives.
