# R37.M2 GuC firmware bring-up hardware smoke — operator recipe (T14 G4)

**Owner issue:** #1261 (R37.M2-005, `gated:hardware`).
**Status:** **UNSEEDED.** Every procedure below is written to be run on a
real ThinkPad T14 Gen 4 with a real Intel Iris Xe (Gen12) GPU and no
expected values are recorded, because recording an expected value nobody
measured is the failure this file exists to avoid.

This follows the discipline of `tools/hw-smoke-r34-isoch.md`,
`tools/hw-smoke-r34.md`, `tools/hw-smoke-r30.md`,
`tools/hw-smoke-r35-hotplug.md` and `tools/hw-smoke-fingerprints.md`:
the recipe lands before first light, and the expectations are filled
in from a real capture, at which point the corresponding check
promotes from SKIP to LIVE.

---

## 0. Scope

This document is the operator-run recipe that promotes the GuC
firmware substrate landed across R37.M2 (#1257-#1259) from a
QEMU-OVMF structural witness to a real-hardware acceptance witness
on the T14 G4. It exercises the **GuC firmware bring-up path** — the
KMD's admission gate (dual signature verify), the WOPCM upload FSM,
and the post-load handshake that reads the firmware version and
negotiates the enabled feature set.

The wire this smoke exercises:

- `src/kernel/core/drivers/gpu/guc_verify.pdx` — RSA-2048 vendor +
  Dilithium-2 paideia re-sign admission gate, per D1.a.
- `src/kernel/core/drivers/gpu/guc_load.pdx` — WOPCM alignment +
  size validation, WOPCM_BASE/SIZE/RESET write sequence per bspec
  §21.3-§21.4.
- `src/kernel/core/drivers/gpu/guc_hs.pdx` — GUC_STATUS
  UKERNEL_LOADED poll, SLPC init kick, VERSION + FEATURES read,
  KMD/GuC feature-set intersection per bspec §21.5-§21.6.

None of this is wired into `kernel_main_uefi` at boot on either
target — the R37.M2 witnesses run only from the boot-witness chain
in QEMU-OVMF (`R30Platform`), which mints synthetic blob buffers,
stamps the shadow MMIO backing, and scrubs both on the way out.
There is no live blob supply, no live BAR0 mint over Iris Xe MMIO,
and no live GT DMA engine bound to `gucl_load`'s upload seam yet;
that wiring is R37.M3+ scope (mirrors the R34.M3 → R34.M5 shape —
see `tools/hw-smoke-r34.md §0`).

---

## 1. Prerequisites

### 1.1 Hardware

- T14 G4 physical unit (Intel Raptor Lake, MVP target — the
  Iris Xe integrated variant is the qualified path).
- HDMI or DisplayPort external monitor bound to the internal
  Iris Xe (see §1.2 for the toggles that route to Iris Xe rather
  than the discrete GPU on hybrid SKUs).
- Serial-over-USB or ethernet-tethered GDB stub, per
  `tools/xhci-keyboard-smoke.md §1.1`.

### 1.2 Firmware / BIOS toggles

Same as `tools/xhci-keyboard-smoke.md §1.2`, plus:
- Discrete GPU (if the SKU has one) **disabled** in BIOS. A hybrid
  boot with the dGPU active can steal the display path and mask a
  live iGPU that this recipe assumes owns Iris Xe MMIO.
- Intel VT-d **disabled** for the first-light capture. VT-d routes
  Iris Xe MMIO through the IOMMU, which is a R37.M4+ scope wire;
  this recipe reads the BAR directly and would be blocked by an
  active IOMMU translation.
- Legacy Video **disabled**, GOP-only. A CSM path can leave the
  GuC in a shipped-firmware-loaded state that clashes with a
  re-load; a GOP-only path leaves the GuC in a known-reset state
  the paideia loader can start from.

### 1.3 Software

- `build/kernel.elf` from `bash tools/build.sh` (must pass all
  gates, including the R37.M2 `guc-m2-confine` one-writer check).
- UEFI boot image via `tools/build-uefi-image.sh`.
- GDB with `gdb-multiarch`.
- A paideia-re-signed GuC firmware image. The vendor half comes from
  Intel's public firmware release for the Gen12 GuC (SHA-256 pinned
  in `design/hardware/quirks.md §3` once the first capture is done);
  the paideia re-sign is produced offline through the paideia signing
  workflow (out of scope for this recipe — see
  `design/security/dual-signing.md` under D1.a).

---

## 2. Operator recipe

### 2.1 BAR0 window discovery

1. Boot the T14 G4 with NO external Iris Xe consumer active.
2. Attach GDB; break on any post-`R30Platform` witness (`init_task`
   entry is safe).
3. Read the recorded BAR0 base + length via the R37.M1 substrate:
   ```
   (gdb) call gmmio_bar_base_of()
   (gdb) call gmmio_bar_len_of()
   ```
   Record the {base, length} pair. Assert `length >= 0x1000000`
   (16 MiB) and `base % 0x1000000 == 0` per `gpu_mmio.pdx §1`.

**Acceptance:** the recorded BAR0 is 16 MiB aligned and at least
16 MiB long. **Expected values: NOT YET MEASURED.**

This assertion requires the R37.M2+ probe wire (a live PCI probe
minting the BAR window into `gmmio_bind`) — the accessor path does
not exist yet as a boot-time wire, only as the seam each witness
exercises against a fabricated `gmmio_bind` argument. Until that
wiring lands, this section stays blocked and the reads return 0,
matching the R30.M9 and R34.M3 `Blocked. Do not attempt yet.`
posture in `tools/hw-smoke-r34.md §2.2`.

### 2.2 Dual-signature admission on a real vendor blob

This is one half of the #1261 deliverable's core assertion.

1. Load the paideia-re-signed vendor firmware image into a scratch
   region (via UEFI file protocol pre-boot, or via the loader path
   R37.M3+ will introduce). Record `{blob_ptr, blob_len}`.
2. Break on any post-`R30Platform` witness.
3. Call `gucv_verify(blob_ptr, blob_len)` via GDB. Assert `== 0`
   (`GUCV_OK`).
4. Read the recorded row:
   ```
   (gdb) call gucv_is_verified()
   (gdb) call gucv_blob_ptr_of()
   (gdb) call gucv_blob_len_of()
   ```
   Assert `verified == 1`, `blob_ptr` matches the argument, and
   `blob_len` matches the argument.
5. Repeat with a corrupted vendor signature slot (flip one byte in
   the RSA-2048 payload at offset 8 of the blob). Assert the call
   returns `0xFFFFF67C` (`GUCV_BAD_VENDOR_SIG`).
6. Repeat with a corrupted paideia signature slot (flip one byte at
   offset 24). Assert the call returns `0xFFFFF67B`
   (`GUCV_BAD_PAIDEIA_SIG`).

**Acceptance:** the real blob verifies, and single-bit corruption
in EITHER signature slot is caught. **Expected values: NOT YET
MEASURED.**

This becomes a full-crypto assertion only when the KIND_HASH_SESSION
substitution lands (R32 wave-2 scope) — until then the check is
structural (non-empty slot), and the corruption tests above will
NOT catch mid-signature bit flips, only slot-erasure.

### 2.3 WOPCM upload FSM

The second half of the #1261 deliverable's core assertion.

1. Determine a valid WOPCM window from the platform's GSM map (see
   `design/hardware/gsm-layout.md §2` once written; until then use a
   fabricated 512 KiB region carved by hand).
2. Call `gucl_load(wopcm_base, wopcm_size)` via GDB. Assert `== 0`
   (`GUCL_OK`).
3. Read the recorded row:
   ```
   (gdb) call gucl_is_loaded()
   (gdb) call gucl_wopcm_base_of()
   (gdb) call gucl_wopcm_size_of()
   ```
   Assert `loaded == 1`, `wopcm_base` matches the argument, and
   `wopcm_size` matches the argument.
4. Read the three register echoes on the live BAR:
   ```
   (gdb) call gmmio_read32(GUCL_REG_WOPCM_BASE)   # 0xC020
   (gdb) call gmmio_read32(GUCL_REG_WOPCM_SIZE)   # 0xC024
   (gdb) call gmmio_read32(GUCL_REG_RESET)        # 0xC028
   ```
   Assert the first two echo the write pattern
   `((wopcm_base >> 16) | 1)` and `(wopcm_size >> 12)` respectively.
   Assert the third has cleared to 0 (release edge).

**Acceptance:** the WOPCM writes are visible on the live BAR at the
expected pattern, and the reset register clears. **Expected values:
NOT YET MEASURED.**

This assertion requires a live GT DMA engine binding at the upload
seam — the R37.M2 substrate writes three registers and does NOT
copy blob bytes into GuC WOPCM. On a live boot without the DMA wire,
the GuC will find WOPCM empty when reset releases and the handshake
below will TIMEOUT (§2.4). That is the honest signal; the assertion
promotes from SKIP to LIVE when R37.M3 lands the DMA wire.

### 2.4 Handshake + version + feature negotiation

1. Call `guchs_handshake()` via GDB. On a live GuC with a
   successful upload, this should return 0 (`GUCHS_OK`) within a
   few milliseconds.
2. Read the recorded row:
   ```
   (gdb) call guchs_is_ready()
   (gdb) call guchs_version_of()
   (gdb) call guchs_features_of()
   ```
   Assert `ready == 1`, `version != 0`, and `features_enabled` is a
   subset of `GUCHS_KMD_SUPPORT_MASK` (0x3 as of R37.M2).
3. Decode `version` — Intel GuC firmware layout is
   `(major << 16) | minor`. Cross-reference against the pinned
   {major, minor} range in `design/hardware/quirks.md §3` (added
   from the first successful capture).

**Acceptance:** the GuC reports itself loaded, the version matches
the paideia-blessed range, and the enabled feature mask is a subset
of the KMD's support mask. **Expected values: NOT YET MEASURED.**

This assertion is blocked on §2.3 landing the DMA wire — a scaffold
that writes three registers but no firmware body will time out here
because `GUC_STATUS.UKERNEL_LOADED` will never rise.

---

## 3. Quirks-database promotion pass

On successful live capture, add a row to `design/hardware/quirks.md
§3` for the specific Iris Xe stepping used (vendor/device ID from
lspci, PCH stepping from the RSDP, observed GuC firmware version,
observed features_enabled mask). Any deviation observed (a firmware
that reports a version outside the paideia-blessed range, a features
mask that includes a bit the KMD does not enumerate, a handshake
that reproducibly times out) gets its own row with the observed
behavior and the R37.M2 handling gap.

---

## 4. Related documents

- `design/roadmap/next-wave-synthesis.md §2` — R37 round scope.
- `design/roadmap/next-wave-softarch.md §3` — R37 milestone breakdown.
- `design/security/dual-signing.md` — D1.a dual-signature discipline.
- `tools/hw-smoke-r34-isoch.md` — sibling UNSEEDED recipe for R34.M5;
  same discipline.
- `tools/hw-smoke-r30.md` — sibling UNSEEDED recipe for R30.M9.
- `tools/hw-smoke-r35-hotplug.md` — sibling UNSEEDED recipe for R35.M1.
- `tools/xhci-keyboard-smoke.md` — sibling recipe for the R26 xHCI
  keyboard smoke; same shape for the hot-plug wiring this doc is
  blocked on.
- `tests/kernel/drivers/gpu/guc_verify_synth.pdx`,
  `tests/kernel/drivers/gpu/guc_load_synth.pdx`,
  `tests/kernel/drivers/gpu/guc_hs_synth.pdx` — the QEMU-OVMF
  structural witnesses this recipe promotes from.
- `tests/kernel/drivers/gpu/hw_smoke_guc_placeholder.pdx` —
  the dormant placeholder module this recipe drives.
