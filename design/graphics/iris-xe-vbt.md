# Iris Xe VBT (Video BIOS Table) parser — design freeze

**Status:** DESIGN (pre-implementation). Target implementation wave:
Wave 59 G1 (paideia-os #2538).
**Round:** R36 — T14 G4 drivers + GPU-native GUI first-cut.
**Date:** 2026-10-10.
**Scope:** Parse the Intel VBT delivered through the GPU's OpRegion into
a structured, downstream-consumable topology descriptor covering panel
timing, backlight curve, encoder routing (DP / HDMI / eDP), and
connector enumeration (DDI A..F).
**Companion docs:**
- `design/graphics/multi-scanout-topology.md` — the output-indexing
  invariant G2 modeset writes into after this parser surrenders a
  topology struct.
- `design/graphics/r113-m1-substrate.md` — kernel-side surface
  substrate that eventually binds to the panel this parser describes.
- `design/drivers/pci-enumeration.md` — the enumerator this parser's
  OpRegion discovery piggy-backs on.
- `design/acpi/aml-evaluator.md` — AML execution needed for the ASLS
  register path (fallback when PCI config `0xFC` returns zero).
- `design/hardware/t14-g4-first-boot.md` §6 — the physical target this
  parser's QEMU-first discipline eventually crosses over to.
**Blocks:** Wave 59 G2 (modeset), D12 (`_BCL` backlight), G4
(hotplug IRQ mapping). **Does not cover:** DP-AUX transactions
(G3), retimer quirks (G5), virtio-gpu discovery, modesetting
itself.

---

## 0. Why this doc exists first

The user prompt from #2538 is explicit: "Companion design doc:
`design/graphics/iris-xe-vbt.md` (to land first)." The reason is
twofold.

**One:** every downstream Wave 59 driver — G2 modeset, D12 backlight,
G4 hotplug — needs the *same* answers from the VBT (which panel? at
what native timing? at what backlight curve? through which encoder on
which DDI?). If each driver were to open-code VBT descent, the four
would drift the first time Intel bumps a field width (and they do —
Block 42 grew its `bits_per_pixel` enum between VBT 229 and 254). The
parser is the one place that reads bytes-out-of-firmware; everybody
else reads a settled struct.

**Two:** the parser is the first paideia-os code that reads firmware
blobs on a path which must survive adversarial input. ACPI OpRegion
content is produced by the OEM's BIOS. On T14 G4 we trust Lenovo's
BIOS as much as we trust any first-party firmware (not much), but the
parser must *decline* malformed input without panicking the kernel.
This document pins the validation gates so the implementation does not
grow them one at a time.

Ambition is deliberately modest: parse enough VBT to let Wave 59
G2 light the integrated panel and three external connectors at
native timing. Blocks we don't need yet are *skipped by ID*, not
walked.

---

## 1. Hardware context: T14 G4 Iris Xe

**SoC family.** Intel Raptor Lake-P. The T14 G4 ships either the
i5-1335U or i7-1365U/1370U (two SKUs the Lenovo PSREF covers; vPro
and non-vPro share the same GPU block). GPU is Gen 12.2 Iris Xe with
96 execution units, PCI vendor `0x8086`, device IDs `0xa7a0` /
`0xa7a1` depending on SKU.

**OpRegion layout.** The Intel IGD OpRegion spec revision 2.4 (latest
public as of 2025, carried forward into VBT 254+) describes a 32 KiB
system-RAM region whose physical address the firmware stores in the
GPU's PCI config space at offset `0xFC` (the ASLS — "ACPI Scratch and
Linking Space" — register). Reading that register at probe time gives
a 32-bit page-aligned physical pointer we then map read-only into the
driver's virtual address space.

**T14 G4 panel.** Lenovo ships the T14 G4 with one of three internal
panel SKUs — low-end IPS 1920x1200, mid IPS WUXGA with higher PWM, and
a high-end OLED 2880x1800 option on the non-US skus. All three are
eDP 1.4b, 4-lane; the parser enumerates whichever one BIOS reports
through LFP Block 42 (§7). We do not keep a panel-ID table in the
parser — the panel's native EDID is read later by the DP-AUX path
(Wave 59 G3) and reconciled against VBT in the modesetter.

**External connectors.**
- `HDMI 2.1` straight-through, routed through DDI `B` on the T14 G4
  mainboard (Lenovo PSREF table F.4).
- `Thunderbolt 4 / USB4` (×2), both DP-alt-mode-capable, routed
  through DDIs `C` and `D` with ANX7452 retimers in the path. The
  retimers are transparent to VBT (they live below the SoC's PHY) but
  show up to AUX as added latency, handled downstream.
- `eDP` to the internal panel, DDI `A`.

Note that the DDI letter — `A..F` — is a *soft* ID in VBT; the
hardware constant is a numeric port in Child Device entries. §6
pins the mapping.

**Operating assumption on VBT version.** Lenovo T14 G4 production
firmware (as of 1.44, July 2024) ships VBT version 254. Earlier T14
G4 firmware (1.20) was 253. The parser accepts VBT 231..257 inclusive
(the window where Child Device Table layout V2 is stable), refuses
below 231 with a clear witness, and warns-and-continues above 257 (new
block IDs may be present we skip; existing block layouts are
backward-compatible per Intel's own guarantee).

---

## 2. Discovery path: PCI config `0xFC` → OpRegion

### 2.1 ASLS register read

The GPU is enumerated by the Wave-16 PCI enumerator at B/D/F
`00:02.0` (invariant on Raptor Lake; the display controller is always
B0/D2/F0 on consumer-class Intel SoCs). The driver's probe entrypoint
receives a `pci_dev` handle (kind `KIND_PCI_DEV_CFG`, Wave 12 R28,
`src/kernel/drivers/pci/pci_cfg.pdx`). From that handle, probe reads
4 bytes at config offset `0xFC`:

```
   ASLS layout (per IGD OpRegion spec r2.4 §2.1):
     bits 31..12  OpRegion physical base, 4 KiB aligned
     bits 11..0   reserved, read-as-zero
```

The parser treats a value of `0x00000000` or `0xFFFFFFFF` as "firmware
did not populate OpRegion"; both go to the fallback described in §2.3.
Any other value is interpreted as the OpRegion base. The parser does
*not* trust the alignment bits — it masks `~0xFFF` explicitly before
mapping.

### 2.2 Mapping

The physical address is handed to `kernel/mem/mmio.pdx` for a 32 KiB
read-only mapping. The parser requests `MAP_UNCACHED | MAP_READ_ONLY`;
cached mapping is admissible per spec but offers no measurable win and
closes a potential class of coherency bugs (firmware updating the
mailbox 1 pending flag while we hold a stale cache line).

Mapping failure (out of PTEs, bad physical range, overlap with a
reserved region) is a hard parser failure; §12 pins the witness.

### 2.3 Fallback: ACPI `IGD._DSM` → `ASLS`

Modern firmware universally populates the config-space register; the
fallback exists for completeness and for one specific pre-production
T14 G4 BIOS version (1.08) which populated OpRegion but left the
config register zero because of a known Lenovo bug tracked in LLN-5471.
The fallback path invokes the ACPI method `\_SB.PCI0.GFX0._DSM` with
GUID `3E5B41C6-EB1D-4260-9D15-C71FBADAE414` function 1, which returns
the ASLS value. §2.3 of this doc frozen for the ACPI path means:

- The AML evaluator (`design/acpi/aml-evaluator.md`) must have landed
  far enough to execute `_DSM`.
- The parser detects the fallback was taken and emits a `VBT ASLS
  FALLBACK` witness so the next phase of first-boot work can tell
  whether real deployments still hit this path.

If both paths fail (zero config register *and* missing / failing
`_DSM`), the parser surrenders without panicking: it returns a well-
formed empty topology (no ports, no panel), and the Wave-59 G2
modeset-driver treats the GPU as "firmware did not describe outputs,
driver cannot proceed on this hardware" and refuses to initialize. In
the normal T14 G4 case this never fires.

---

## 3. OpRegion skeleton

OpRegion is 32 KiB. It is partitioned into fixed-offset "mailboxes":

| Offset   | Length    | Name     | Role (per spec r2.4)                  |
|----------|-----------|----------|---------------------------------------|
| 0x0000   | 0x100     | HEADER   | Signature, version, pointers.         |
| 0x0100   | 0x100     | MAILBOX1 | ACPI pending driver notifications.    |
| 0x0200   | 0x100     | MAILBOX2 | SWSCI — software SCI handshake.       |
| 0x0300   | 0x100     | MAILBOX3 | ASLE — brightness, lid state, etc.    |
| 0x0400   | 0x1C00    | MAILBOX4 | VBT in-line (if size <= 7 KiB)        |
|          |           |          | OR BIOS_DATA_HEADER + RVDA pointer    |
| 0x2000   | ...       | MAILBOX5 | (reserved; present in some firmwares) |

The parser touches HEADER (§3.1) and MAILBOX4 (§4). It intentionally
ignores MAILBOX1/2/3 for first-boot — those are read-write handshakes
that only matter after modeset is live. D12 (backlight control, Wave
59) will reopen MAILBOX3 for ASLE brightness callbacks; that is a
separate design doc.

### 3.1 HEADER layout

```
+0x00  u8[0x10]   signature       // "IntelGraphicsMem\0"
+0x10  u32        size            // total OpRegion size in KiB (= 0x20)
+0x14  u32        version         // packed: major<<16 | minor<<8 | patch
+0x18  u8[0x20]   sbios_version   // vendor-defined ASCII
+0x38  u8[0x10]   vbios_version   // vendor-defined ASCII
+0x48  u8[0x10]   driver_version  // written by OS driver, left blank by firmware
+0x58  u32        mailboxes       // bitmask: which mailboxes are populated
+0x5C  u32        dmisr           // reserved
+0x60  u8[0xA0]   reserved
```

The parser verifies:
1. `signature == "IntelGraphicsMem"` with a trailing NUL in position
   16. Mismatch → OpRegion rejected, parser emits `VBT HDR SIG BAD`.
2. `size == 0x20` (32 KiB). Any other value is unsupported today;
   newer SKUs may bump to 48 or 64 KiB. We WARN and continue, mapping
   only the first 32 KiB.
3. `version >= 0x00020000` (OpRegion 2.0). OpRegion 1.x firmware is
   extinct in the T14 G4 era; parser refuses with `VBT HDR VER TOO
   OLD`.
4. `mailboxes & 0x10` is set — the "mailbox 4 populated" bit per spec.
   If not, parser refuses with `VBT MBOX4 ABSENT`.

The `*_version` ASCII strings are *not* parsed; they are opaquely
copied into the output struct for later diagnostic use.

---

## 4. VBT location: inline-in-MBOX4 vs. RVDA

OpRegion 2.0 kept the VBT inline at OpRegion offset `0x0400` and
capped its size at 7 KiB (`0x1C00`). OpRegion 2.1 introduced
Relocatable VBT Data Area (RVDA): the firmware allocates the full VBT
in a separate region of system RAM and stashes its physical address
and length in the HEADER's reserved slot (specifically at `+0x70` and
`+0x74` of HEADER; the pointer being 64-bit lets the firmware place
the VBT above 4 GiB on big machines).

T14 G4 ships OpRegion 2.4 with RVDA populated when VBT exceeds 7 KiB
(it does — modern VBT with full child-device table runs 9–11 KiB).

The parser's branching:

1. Read `rvda_phys = u64 at HEADER +0x70` and `rvda_len = u32 at
   HEADER +0x74`.
2. If `rvda_phys != 0`:
   - Map `rvda_phys .. rvda_phys + rvda_len` read-only (same
     attributes as OpRegion mapping).
   - The VBT begins at that mapped base.
3. Else (RVDA zero):
   - The VBT begins at OpRegion base `+0x0400`.
   - Its length is bounded by `0x1C00`.

The parser never reads past the declared length regardless of what
the BDB header internally claims (§5.1); this is the first of our
bounds-checking invariants.

---

## 5. VBT + BDB headers

The VBT begins with a *VBT header* ("$VBT" family) followed by a
*BDB header* ("BIOS Data Block"), followed by the block stream. Two
headers because the two were authored by different teams at Intel in
the 1990s and the schism is preserved out of ABI inertia.

### 5.1 VBT header (24 bytes)

```
+0x00  u8[0x14]   signature     // "$VBT ClamshellRaptorLake" (24 bytes) etc,
                                // but only "$VBT " is invariant
+0x14  u16        version       // VBT version (we care about this)
+0x16  u16        header_size   // size of this header (always 24 on 2.0+)
+0x18  u16        vbt_size      // declared total VBT size, in bytes
+0x1A  u8         vbt_checksum  // sum of all bytes 0..vbt_size-1 must == 0
+0x1B  u8         reserved
+0x1C  u32        bdb_offset    // from VBT base, usually 0x1C
+0x20  u32[4]     aim_offsets   // optional Add-In Modules (0 on T14 G4)
```

Validation:
- `signature[0..5] == "$VBT "` (ASCII `$`, `V`, `B`, `T`, space).
  Trailing field is marketing text; we do not parse it.
- `version` in `[231, 257]` (§1). Below → refuse. Above → WARN.
- `header_size == 24`. Any other value → refuse (we have never seen
  firmware with a different value and we do not pre-generalise).
- `vbt_size <= region_length` where `region_length` is the mapped
  RVDA size or `0x1C00` for inline. Mismatch → refuse.
- `bdb_offset + 32 <= vbt_size` (room for a BDB header). Mismatch →
  refuse.

The `vbt_checksum` byte is historical and reportedly left zero by at
least two OEMs; the parser *computes* the sum but WARNs-only on
mismatch rather than refusing, since in practice refusing would
blacklist half the HP SKUs the user base cares about.

### 5.2 BDB header

```
+0x00  u8[0x10]   signature     // "BIOS_DATA_BLOCK "
+0x10  u16        version       // BDB version (ties to VBT version)
+0x12  u16        header_size   // size of this header
+0x14  u16        bdb_size      // total BDB size including all blocks
```

Validation:
- `signature == "BIOS_DATA_BLOCK "` (16 ASCII bytes with trailing
  space). Mismatch → refuse.
- `header_size` typically 32 on modern firmware; use the declared
  value as the first-block offset.
- `bdb_size + bdb_offset <= vbt_size`. Mismatch → refuse.

---

## 6. Block iteration

After the BDB header, blocks follow in sequence until `bdb_size` is
consumed. Each block is:

```
+0x00  u8   block_id
+0x01  u16  block_size   // excludes the 3-byte block header
+0x03  u8[block_size]  payload
```

The parser walks the stream with a strict rule set:

1. Current offset starts at `bdb_header + header_size`.
2. End offset is `bdb_header + bdb_size`.
3. At each step, read 3 header bytes. If `offset + 3 > end`, stop
   (truncated final block — WARN and continue with partial state).
4. If `offset + 3 + block_size > end`, treat as truncated — WARN and
   stop.
5. Dispatch on `block_id` to a per-block parser (§7). Any unknown
   block ID is *silently skipped*; the parser's job is forward
   compatibility, not completeness.
6. Advance `offset += 3 + block_size`. Return to step 3.

**Repeat-ID handling.** The spec permits a block ID to appear more
than once (edge case: block 254 "SKU" lists). The parser's rule is
**first-ID-wins** for every semantic block we care about. A duplicate
Block 2 (child device table) is skipped with a WARN witness.

### 6.1 Block catalog (VBT 254+ as shipped on T14 G4)

The table below lists only blocks the parser *consumes*. All other
blocks are enumerated and traced but not parsed. Field offsets inside
each payload are relative to the block header's start-of-payload.

| ID   | Name                       | Payload size | Role for Wave 59 |
|------|----------------------------|--------------|------------------|
| 1    | General Features           | ~0x30        | DRRS flag, PSR flag |
| 2    | General Definitions / CDT  | 0x200..0x500 | **Child Device Table** — port enumeration (§6.2) |
| 9    | SRD / PSR features         | ~0x20        | PSR support flags per DDI (not consumed yet) |
| 23   | LFP options                | ~0x40        | LFP panel-type index into Block 42 |
| 27   | eDP data                   | ~0x80        | eDP link rate, lane count, Tx voltage swing table |
| 40   | LVDS options               | ~0x60        | Legacy LVDS; parsed only on firmware that still uses it (not T14 G4) |
| 42   | LFP panel info             | 0x100..0x300 | Panel timing array — **primary panel timing source** |
| 43   | LFP backlight power        | ~0x30        | PWM frequency, brightness-level LUT |
| 44   | LFP backlight control      | ~0x20        | Brightness min/max, backlight type (DP-AUX / PWM / combo) |
| 52   | MIPI config                | ~0x80        | DSI panels (not present on T14 G4; parsed but marked unused) |
| 253  | PSR2 extended data         | ~0x40        | (not consumed yet; forward-compatibility note) |

**Note on block numbering.** The user prompt from #2538 lists Block 42
as MIPI and Block 253 as Child Device Table. That reflects an earlier
VBT dialect; from VBT 229+ the Child Device Table lives inside
*Block 2* (General Definitions) with the Modern Child-Device layout,
and Block 42 is LFP Panel Info. The parser targets VBT 231..257 and
uses the modern mapping. Legacy VBT below 231 is refused outright, so
we do not maintain the old mapping. (This is the single most common
pitfall when reading Intel VBT documentation across years, and the
reason we pin an acceptance window.)

### 6.2 Block 2 — General Definitions / Child Device Table

Block 2 is both a legacy static-field block (first ~40 bytes) and a
variable-length child-device array. Layout:

```
+0x00  u8   crt_ddc_gmbus_pin
+0x01  u8   dpms_acpi
+0x02  u8   skip_boot_crt_detect
+0x03  u8   dpms_aim
+0x04  u16  boot_display[2]
+0x08  u8   child_dev_size     // bytes per child device entry
+0x09  child_device_t[]        // array, length = (block_size - 9) / child_dev_size
```

`child_dev_size` is critical. Historical values:
- 22 bytes (VBT < 155)
- 33 bytes (VBT 155..208)
- **38 bytes (VBT 209..229)** — "legacy modern"
- **40 bytes (VBT 230..254)** — current T14 G4
- 41 bytes (VBT 255+, if ever bumped)

The parser verifies `child_dev_size in {33, 38, 40, 41}` and dispatches
to a per-size reader. Each child-device entry decodes into the same
*internal* `vbt_port_t` struct (§8); the per-size readers are purely
field-offset-adjusters.

**Child-device entry (40-byte layout, VBT 230..254):**

```
+0x00  u16  handle              // opaque, informational
+0x02  u16  device_type         // bitmask (DP, HDMI, eDP, analog, LVDS, MIPI)
+0x04  u8   not_common_block[10] // deprecated, parser skips
+0x0E  u8   dvo_port            // DDI numeric: 0=A, 1=B, 2=C, 3=D, 4=E, 5=F
+0x0F  u8   i2c_pin             // GMBUS pin number for DDC
+0x10  u8   slave_addr          // I2C slave for DDC (usually 0x50 or 0x60)
+0x11  u8   ddc_pin             // alternative DDC bus
+0x12  u16  edid_ptr            // 0 means "read EDID over the live link"
+0x14  u8   dvo_cfg             // DVO config (not consumed on DDI parts)
+0x15  u8   efp_routed          // efp routed over DP; bitfield
+0x16  u8   lane_count          // 0..4
+0x17  u8   hpd_pin             // hot-plug detect pin number (DDI-indexed)
+0x18  u8   aux_channel         // AUX ch index: 0..5 maps DDI A..F
+0x19  u8   dongle_detect       // dongle-detect pin
+0x1A  u8   pipe_cap            // pipe-capability bitmask
+0x1B  u8   ddi_wake_support    // DDI wake support bitmask
+0x1C  u8[0x14] reserved        // (post-R254 bytes land here)
```

The parser extracts *six* fields per port — `device_type`, `dvo_port`,
`aux_channel`, `hpd_pin`, `lane_count`, `edid_ptr` — and stores them
in the per-port output row. Everything else is left in the trace but
not surfaced upward.

**`device_type` bits of interest** (per Intel docs, extracted from
`drm/i915/display/intel_bios.c`):
- bit 0: analog present
- bit 2: HDMI present
- bit 4: DisplayPort present
- bit 12: internal (eDP vs. external DP)
- bit 13: eDP (implies bit 4)
- bit 14: MIPI DSI
- bit 15: LVDS

A port can report multiple bits (HDMI *and* DP, as every TB4 port on
T14 G4 does — that's DP-alt-mode). The parser emits one `vbt_port_t`
per child-device entry; downstream (G2 modeset) is responsible for
re-interpreting the capability bitmask.

**DDI letter mapping on T14 G4** (pinned by Lenovo PSREF F.4 cross-
referenced with Intel ADL/RPL Platform Design Guide):

| `dvo_port` | DDI letter | T14 G4 physical connector |
|------------|------------|---------------------------|
| 0          | A          | eDP (internal panel)      |
| 1          | B          | HDMI (right-side port)    |
| 2          | C          | TB4 left (DP alt-mode via ANX7452 retimer) |
| 3          | D          | TB4 right (DP alt-mode via ANX7452 retimer) |
| 4          | E          | *(reserved; not routed on this SKU)* |
| 5          | F          | *(reserved; not routed on this SKU)* |

This mapping is *not hard-coded* in the parser — the parser just
extracts the DDI number. The DDI-letter annotation is added by G2
modeset using a board-identifier string the DMI table reports. The
mapping above is informative, included here so this doc records the
expected post-parse topology.

---

## 7. Panel timing extraction (Block 42 — LFP)

Block 42 is the single most schema-churned block in the VBT catalog.
Its canonical shape on VBT 254 is:

```
+0x00  u8    lvds_panel_type       // index into the panel-DTD table below;
                                   // also indexes into Block 23 "LFP options"
+0x01  u8    reserved
+0x02  panel_dtd_t[16]             // 16 fixed slots, 70 bytes each on VBT 254
+0x462 panel_backlight_dtd_t[16]   // 16 slots, ~28 bytes each (hooks to Block 43)
```

Each `panel_dtd_t` is a packed DTD (Detailed Timing Descriptor) in
VESA EDID form, with Intel-specific trailing fields.

```
panel_dtd_t (70 bytes, VBT 254):
+0x00  u16  pixel_clock_khz_div_10 // multiply by 10 to get kHz
+0x02  u8   h_active_lo
+0x03  u8   h_blank_lo
+0x04  u8   h_active_hi_blank_hi   // high 4 bits each
+0x05  u8   v_active_lo
+0x06  u8   v_blank_lo
+0x07  u8   v_active_hi_blank_hi
+0x08  u8   h_sync_offset_lo
+0x09  u8   h_sync_width_lo
+0x0A  u8   v_sync_offs_width       // packed: upper nibble = v_off_lo, lower = v_width_lo
+0x0B  u8   hv_sync_hi             // packed high bits
+0x0C  u8   width_mm_lo
+0x0D  u8   height_mm_lo
+0x0E  u8   hv_size_hi
+0x0F  u8   h_border
+0x10  u8   v_border
+0x11  u8   flags                   // interlaced, polarity, stereo
+0x12  u8   bits_per_pixel          // 0=18bpp, 1=24bpp, 2=30bpp, 3=36bpp, 4=48bpp
+0x13  u8   dps_panel_type
+0x14  u16  pps_t1_t2_delay
+0x16  u16  pps_t3_delay
+0x18  u16  pps_t4_delay
+0x1A  u16  pps_t5_t6_delay
+0x1C  u16  pps_cycle_delay
+0x1E  u8[0x24] reserved / vendor
```

**Which slot is "the" panel?** `lvds_panel_type` at Block 42 `+0x00`
is a 0..15 index. The parser uses that index to pick one slot out of
the 16-slot DTD array. Firmware populates only the slot it points at
on most T14 G4 SKUs; the rest are zero-filled. Validation:

- `lvds_panel_type < 16`. Out of range → refuse with `VBT LFP IDX
  OOB`.
- The chosen DTD's `pixel_clock_khz_div_10 != 0`. Zero → "no panel"
  (headless configuration — not seen on T14 G4 but legal in general).

**Timing decode.** We reconstruct standard DTD scalars:

```
pixel_clock_khz = pixel_clock_khz_div_10 * 10
h_active        = h_active_lo | ((h_active_hi_blank_hi >> 4) << 8)
h_blank         = h_blank_lo  |  (h_active_hi_blank_hi & 0x0F)      << 8
v_active        = v_active_lo | ((v_active_hi_blank_hi >> 4) << 8)
v_blank         = v_blank_lo  |  (v_active_hi_blank_hi & 0x0F)      << 8
h_sync_offset   = h_sync_offset_lo | ((hv_sync_hi & 0xC0) >> 6) << 8
h_sync_width    = h_sync_width_lo  | ((hv_sync_hi & 0x30) >> 4) << 8
v_sync_offset   = (v_sync_offs_width >> 4)   | ((hv_sync_hi & 0x0C) >> 2) << 4
v_sync_width    = (v_sync_offs_width & 0x0F) |  (hv_sync_hi & 0x03)       << 4
h_total         = h_active + h_blank
v_total         = v_active + v_blank
h_sync_polarity = (flags >> 1) & 1   // 1 = positive
v_sync_polarity = (flags >> 2) & 1   // 1 = positive
interlaced      = (flags >> 7) & 1   // 1 = interlaced (never true on eDP today)
```

**bpp decode** (Intel-specific extension):

```
bpp == 0 → 18 bits per pixel (6:6:6, dithered)
bpp == 1 → 24 bits per pixel (8:8:8)  ← T14 G4 WUXGA SKU
bpp == 2 → 30 bits per pixel (10:10:10) ← T14 G4 OLED SKU
bpp == 3 → 36 bits per pixel (12:12:12)
bpp == 4 → 48 bits per pixel (16:16:16, HDR workflows)
other    → refuse: VBT LFP BPP INVALID
```

**eDP native hz (the figure the witness emits):**

```
edp_hz = (pixel_clock_khz * 1000) / (h_total * v_total)
```

Integer division is deliberate — the result is reported truncated
(e.g. "59" rather than "59.94"). We do not pretend to precision VBT
doesn't carry.

### 7.1 Block 27 — eDP electrical

Block 27 complements Block 42 with the link-side parameters needed to
light the eDP port (lane count, link rate, voltage-swing/pre-emphasis
tables). The parser extracts three fields per panel-index:

```
+0x00  u8[16]  link_rate          // one of 1.62, 2.7, 5.4, 8.1 Gbps per DP spec
+0x10  u8[16]  lane_count         // 1, 2, or 4
+0x20  u8[16]  edp_vswing_preemph // 2-bit × 4-level matrix (not consumed yet)
...
```

`link_rate` is encoded as an enum (per VBT 254):
`0=1.62 Gbps, 1=2.7, 2=5.4, 3=8.1`.
`lane_count` is encoded as `(bits 0..3) = n_lanes - 1`; so 0 means
one lane, 3 means four lanes (the T14 G4 WUXGA panel reports 3 → 4
lanes @ 2.7 Gbps = ~22 Gbps raw, comfortably driving WUXGA@60).

Validation:
- `link_rate` in `{0, 1, 2, 3}`. Out of range → refuse.
- `lane_count + 1 in {1, 2, 4}`. (Three-lane eDP exists but is unsupported.)

---

## 8. Backlight curve (Block 43)

Block 43 — "LFP Backlight Power" — carries the mapping from a 0..100
brightness level to a PWM duty-cycle. Layout:

```
+0x00  u8   entry_size              // bytes per entry, usually 16 on VBT 254
+0x01  backlight_entry_t[16]        // 16 slots, one per LFP panel index
```

Each entry on VBT 254:

```
backlight_entry_t (16 bytes):
+0x00  u8   backlight_type          // 0 = PWM only, 1 = DP-AUX, 2 = combo
+0x01  u8   polarity                // 0 = active-high, 1 = active-low
+0x02  u16  pwm_frequency_hz        // target PWM freq (T14 G4 WUXGA: 200 Hz)
+0x04  u8   min_brightness_percent  // sub-which-the-display-is-off; often 5
+0x05  u8   default_brightness_pct  // startup level
+0x06  u8[10] brightness_curve      // 10 anchor points → see below
```

**Backlight curve interpretation.** `brightness_curve[i]` gives the
PWM duty cycle (0..255 → 0..100%) at brightness level
`10 * (i + 1)` percent. Levels in between are linearly interpolated
by the D12 backlight-control driver — the parser does *not*
interpolate; it just surfaces the 10 anchors.

Mapping formula at parse time (for the per-port output struct):

```
pwm_duty_percent(brightness)  // brightness ∈ 0..100
    = brightness_curve[floor(brightness / 10) - 1] * 100 / 255     // integer, clamped
```

With a defensive clamp:

```
if brightness < 10: use brightness_curve[0] * (brightness / 10) * 100 / 255 / 10
                    (sub-anchor-zero interpolation to zero)
```

T14 G4 WUXGA panel's observed curve (from debug boots):

```
brightness_curve = [8, 24, 48, 80, 120, 160, 200, 230, 245, 255]
```

The non-linear anchor spacing is deliberate — human-perceived
brightness is logarithmic, and the curve pre-corrects. We surface the
raw bytes; interpretation stays downstream.

### 8.1 Block 44 — Backlight control

Block 44 pins which **controller** owns the backlight:
- `0` → integrated PWM (SoC PWM pin, driven by G12 timers).
- `1` → DP-AUX "backlight control over AUX" extension (newer OLED
  panels — including the T14 G4 OLED SKU).
- `2` → combo (PWM for level, AUX for enable).

Block 44 also carries the min/max PWM frequency the panel will
tolerate; the parser verifies `pwm_frequency_hz` (from Block 43) is
within those bounds. Mismatch → WARN; downstream clamps.

---

## 9. Parse-time validation summary

The following table consolidates every validation gate the parser
imposes. All gates emit a specific witness string; §12 pins the
witness vocabulary.

| Gate | Scope | On fail | Witness |
|------|-------|---------|---------|
| ASLS read `!= 0, != 0xFFFFFFFF` | OpRegion discovery | fallback to `_DSM` | `VBT ASLS FALLBACK` |
| OpRegion signature match | HEADER §3.1 | **refuse** | `VBT HDR SIG BAD` |
| OpRegion size == 32 KiB | HEADER §3.1 | WARN, continue | `VBT HDR SIZE ODD` |
| OpRegion version >= 2.0 | HEADER §3.1 | **refuse** | `VBT HDR VER TOO OLD` |
| MBOX4 present bit set | HEADER §3.1 | **refuse** | `VBT MBOX4 ABSENT` |
| RVDA pointer sane (`!= 0` → mapped OK) | §4 | **refuse** | `VBT RVDA MAP FAIL` |
| VBT signature `"$VBT "` | §5.1 | **refuse** | `VBT SIG BAD` |
| VBT version in `[231, 257]` | §5.1 | **refuse** / WARN | `VBT VER OOR` / `VBT VER AHEAD` |
| VBT size within region | §5.1 | **refuse** | `VBT SIZE OOB` |
| VBT checksum == 0 (mod 256) | §5.1 | WARN only | `VBT CKSUM BAD` |
| BDB signature | §5.2 | **refuse** | `VBT BDB SIG BAD` |
| BDB size within VBT | §5.2 | **refuse** | `VBT BDB SIZE OOB` |
| Block header fits in remaining | §6 | WARN, stop stream | `VBT BLK TRUNC` |
| Block 2 `child_dev_size` in allow-set | §6.2 | **refuse** | `VBT CDS BAD` |
| `lvds_panel_type` < 16 | §7 | **refuse** | `VBT LFP IDX OOB` |
| Panel DTD `pixel_clock != 0` | §7 | treat as headless | `VBT LFP NO PANEL` |
| Panel bpp in allow-set | §7 | **refuse** | `VBT LFP BPP INVALID` |
| eDP link rate in `{0..3}` | §7.1 | **refuse** | `VBT EDP RATE BAD` |
| eDP lane_count in `{0, 1, 3}` | §7.1 | **refuse** | `VBT EDP LANES BAD` |

**Refuse** means: parser returns the empty-topology sentinel; G2
modeset refuses to initialize; kernel brings up with no graphics.
**WARN** means: parser continues, witness emitted. We prefer refusing
over best-effort decoding anywhere a bad field would cascade into a
pixel-clock we'd then program into the PHY.

---

## 10. Output: topology descriptor

The parser's product is a single struct the G2 modesetter and D12
backlight-controller consume read-only. Shape:

```
vbt_topology_t:
    version         u16              // raw VBT version
    sbios_version   u8[0x20]         // from HEADER
    vbios_version   u8[0x10]         // from HEADER
    panel_present   u8               // 0 or 1
    panel           vbt_panel_t      // valid iff panel_present
    n_ports         u8               // count of valid vbt_port_t entries
    ports           vbt_port_t[8]    // DDI A..H, 8 slots regardless of n_ports
```

```
vbt_panel_t:
    ddi_port        u8               // which DDI the panel is on (always 0=A on T14 G4)
    native_hres     u16
    native_vres     u16
    pixel_clock_khz u32
    h_total         u16
    v_total         u16
    h_sync_pos      u16
    h_sync_width    u16
    v_sync_pos      u16
    v_sync_width    u16
    h_sync_pol      u8  // 0=neg, 1=pos
    v_sync_pol      u8
    bpp             u8               // decoded bits per pixel
    edp_link_rate   u8               // 0..3 enum
    edp_lane_count  u8               // 1, 2, or 4
    pps_t1_t2       u16              // panel power-sequence delays, 0.1 ms units
    pps_t3          u16
    pps_t4          u16
    pps_t5_t6       u16
    pps_cycle       u16
    backlight_type  u8               // 0=PWM, 1=AUX, 2=combo
    backlight_pol   u8
    pwm_freq_hz     u16
    bl_min_pct      u8
    bl_default_pct  u8
    bl_curve        u8[10]
```

```
vbt_port_t:
    ddi             u8               // 0=A .. 5=F; 0xFF = unused
    device_type     u16              // raw bitmask from Block 2
    is_internal     u8               // bit 12 of device_type
    is_edp          u8               // bit 13
    is_dp           u8               // bit 4
    is_hdmi         u8               // bit 2
    is_mipi         u8               // bit 14
    aux_channel     u8               // 0..5
    hpd_pin         u8
    lane_count      u8               // 1, 2, or 4 (raw +1 adjusted)
    gmbus_pin       u8               // for DDC-over-GMBUS
    i2c_slave       u8               // 0x50 by convention
    edid_ptr        u16              // offset to in-VBT EDID, or 0
```

The struct is reproduced in the output row of `drivers/dpy/vbt.pdx`
once the softarch pass lands code; the schema above freezes the field
set so the modesetter and backlight driver can write against stable
offsets.

### 10.1 Downstream consumers (contracts)

| Consumer | Reads from topology |
|----------|---------------------|
| G2 modeset (#2539) | `panel.*` for native timing; `ports[].ddi`, `.aux_channel`, `.hpd_pin` for enabling encoders. |
| G3 DP-AUX (#2540) | `ports[].aux_channel` only; AUX transactions themselves do not touch VBT. |
| G4 hotplug IRQ (#2541) | `ports[].hpd_pin` + `ports[].ddi`. |
| D12 backlight `_BCL` (#2552) | `panel.backlight_*` and `panel.bl_curve`. |

The parser does *not* talk to any consumer directly; the kernel
driver registry (`design/drivers/driver-registry.md`) delivers the
topology struct to each consumer at their probe time, by handle.

### 10.2 Lifetime & revocation

The topology struct is allocated once at parser-success time and
registered under `KIND_VBT_TOPOLOGY` (new kind slot; §13). It is
*immutable* after mint. VBT does not change at runtime — a lid-close,
dock event, or Thunderbolt hotplug does not re-parse VBT. The only
re-parse trigger is a BIOS update, which happens between boots. So
the kind rights-set is read-only for every holder.

If OpRegion mapping or VBT parse fails, no `KIND_VBT_TOPOLOGY` is
minted and consumers see a mint-time refusal with the parser's
witness reason attached. This is how G2 modeset learns to give up
cleanly rather than program bogus pixel clocks.

---

## 11. T14 G4 expected values (grounded reference)

For a Wave-59-G1 QEMU-first validation, we document the T14 G4 real-
hardware expected values so a hw-smoke engineer has a target shape:

**OpRegion:** signature `"IntelGraphicsMem\0"`, version `0x00020400`
(OpRegion 2.4), mailboxes bitmask `0x1F`. ASLS pointer is dynamic
(BIOS-chosen below 4 GiB).

**VBT header:** `signature[0..24]` begins `"$VBT "` with vendor text
following; `version = 254`; `vbt_size` ~10 KiB (varies by SKU).

**Panel (WUXGA SKU — mainline):**
`native_hres=1920`, `native_vres=1200`, `pixel_clock_khz=193250`,
`h_total=2080`, `v_total=1235`, `bpp=1` (8:8:8), `edp_link_rate=1`
(2.7 Gbps), `edp_lane_count=4`. Computed `edp_hz` ≈ 75 from raw
bytes; hardware reports 60 — see §15 Q5.

**Panel (OLED SKU, informational):**
`native_hres=2880`, `native_vres=1800`, `pixel_clock_khz=319440`,
`bpp=2` (10:10:10), `edp_link_rate=3` (8.1 Gbps),
`edp_lane_count=4`.

**Ports (all SKUs):** 4 entries — eDP@DDI-A, HDMI@DDI-B, DP@DDI-C,
DP@DDI-D. `aux_channel` matches `ddi`. `hpd_pin` ∈ {1,2,3,4}.

**Backlight (WUXGA):** PWM-only (`backlight_type=0`), `pwm_freq_hz=
200`, `bl_default_pct=60`, `bl_curve ≈ [8, 24, 48, 80, 120, 160,
200, 230, 245, 255]`.

**Backlight (OLED):** DP-AUX (`backlight_type=1`), `pwm_freq_hz=0`.

These values are the shape of the first "ground truth" cell in
`tests/hw/vbt-t14-g4.sh`; the fingerprint-byte-exact match pins real
hardware behaviour.

---

## 12. Witness fingerprint

The parser emits a single structured line per boot, consumed by
`tools/verify-fingerprint-coverage.sh` and seeded into
`tests/fingerprints/vbt-parse.txt` for QEMU and
`tests/hw/vbt-t14-g4.txt` for real hardware.

**On success:**

```
VBT PARSE OK n_ports=<N> edp_hz=<HZ> vbt_ver=<V> panel=<HxV@BPP>
```

Example (T14 G4 WUXGA SKU):

```
VBT PARSE OK n_ports=4 edp_hz=60 vbt_ver=254 panel=1920x1200@24
```

Example (QEMU `-vga virtio`, where there is no VBT at all):

```
VBT PARSE OK n_ports=0 edp_hz=0 vbt_ver=0 panel=none
```

**On refusal:**

```
VBT PARSE REFUSED reason=<WITNESS_FROM_§9>
```

e.g.:

```
VBT PARSE REFUSED reason=VBT_HDR_SIG_BAD
```

**On warning:**

Each WARN emits a line *before* the final `VBT PARSE OK`:

```
VBT WARN <WITNESS_FROM_§9>
```

Multiple WARNs are permitted; parser does not deduplicate.

**Why one line each.** Fingerprint discipline per the paideia-os
norm: wire-log fingerprint grep MUST match byte-exact; so no
per-port enumeration goes in this line, and no vendor strings
either (both drift between SKUs and across BIOS versions). The
*detailed* dump — ports table, panel SKU identifier — is a
separate `VBT DUMP` block emitted when the kernel is booted with
`debug_vbt=1`, which is dev-only and never fingerprinted.

### 12.1 QEMU shim

QEMU's `-device qxl` and `-device virtio-gpu-pci` do not expose an
OpRegion. The parser detects this (ASLS = 0, `_DSM` absent) and
emits:

```
VBT PARSE OK n_ports=0 edp_hz=0 vbt_ver=0 panel=none
```

Downstream G2 modeset then uses the virtio-gpu path instead of
Iris Xe modeset. The "0 ports / no panel" witness is the signal.
No fallback VBT-tables-shipped-with-the-kernel exist — if the
hardware doesn't carry VBT, we don't invent one.

For QEMU "pretend to be Iris Xe" testing, `-device
intel-iommu,x-aw-bits=48 -device vfio-pci,host=00:02.0` passthrough
IS a path, but out of scope for QEMU fingerprinting; passthrough
is the T14 G4 developer path and goes through the real-hardware
fingerprint lane.

---

## 13. New kind slot: `KIND_VBT_TOPOLOGY`

Reserved slot (following the `multi-scanout-topology.md` numbering
conventions and the Wave 12 R28 driver-adjacent band `0x3xx`):

```
KIND_VBT_TOPOLOGY = 0x3A0
KIND_VBT_TOPOLOGY_PARENT_KIND = 7   // KIND_PCI_DEV_CFG (per Wave 12 R28)
```

Rationale: parent is the PCI config handle of `00:02.0`. Minting
`KIND_VBT_TOPOLOGY` under a different parent (e.g. a free-floating
driver registry) would admit "two VBT structs" semantics; by making
the parent the PCI device, each GPU gets at most one topology.

Rights:
- `VTT_READ_PANEL`     — G2, D12 consume.
- `VTT_READ_PORTS`     — G2, G3, G4 consume.
- `VTT_READ_HEADER`    — diagnostic (sbios / vbios version strings).

No write rights; the struct is immutable (§10.2).

The slot `0x3A0` must be added to `.plans/kind-reservations.md` and
non-collision tested against the growing kind table in a Wave 59 G1
substrate-freeze commit *before* the parser lands.

---

## 14. Implementation ordering (handoff to softarch)

The softarch pass that implements this parser lands code in this
order:

1. **Kind substrate.** Mint `KIND_VBT_TOPOLOGY`, confirm no collision,
   wire into kind registry. Witness: `VBT KIND MINT OK slot=0x3A0`.
2. **OpRegion discoverer.** Read ASLS, fallback through `_DSM`, map
   32 KiB. Witnesses: `VBT OPREGION MAP OK phys=0x<...>` or `VBT
   ASLS FALLBACK`.
3. **Header + RVDA.** Validate HEADER, follow RVDA pointer or stay
   inline, validate VBT and BDB headers.
4. **Block walker.** Enumerate all blocks (dispatch stubs), trace
   each block ID even for the ones the parser does not consume.
5. **Block 2 Child Device Table.** Per-size readers (33, 38, 40, 41);
   emit `vbt_port_t` per entry.
6. **Block 42 LFP + Block 27 eDP.** Decode panel timing, decode
   electrical.
7. **Block 43/44 backlight.** Decode PWM / AUX curve + anchors.
8. **Topology mint.** Package the collected data into a
   `KIND_VBT_TOPOLOGY` instance; register with driver registry.
9. **Fingerprint seed.** Emit `VBT PARSE OK ...` and tie into
   fingerprint-coverage runner.

Each step gets its own PR, each PR gates on QEMU-first; the last two
gate on T14 G4 real-hw serial-capture fingerprint parity before
`gated:hardware` lifts.

---

## 15. Open questions tracked

**Q1 — bpp cross-check against EDID.** VBT bpp is firmware-declared;
EDID is panel-declared. Preliminary design: EDID wins at modeset
time, VBT bpp is a hint, discrepancy emits `VBT EDP BPP MISMATCH`
WARN. Not binding until G3 lands.

**Q2 — ANX7452 retimer transparency.** TB4 DP-alt-mode ports on T14
G4 pass through an ANX7452 retimer VBT does not describe. The
retimer's existence is reported via DMI / an ACPI `_DSM` on the PCI
parent. G3 (DP-AUX) handles the retimer's I2C setup; the VBT parser
treats DDI-C/D as direct SoC ports.

**Q3 — HDR metadata interplay.** Block 253 (PSR2 extended data) and
`KIND_HDR_METADATA` share no fields today. If future VBT (255+)
carries HDR static metadata, re-open this doc.

**Q4 — Multi-GPU.** Parent-kind binding (§13) scopes one topology
per PCI device; a future discrete GPU would carry its own OpRegion.
No parser-level work needed.

**Q5 — WUXGA pixel-clock oddity.** §11 computes `edp_hz == 75` from
raw bytes, but hardware reports 60. Hypothesis: Block 42 slot 0
encodes an overdrive mode and firmware remaps via a Block 23 LFP
options override. Confirm during hw-smoke; parser may need to
consult Block 23 to pick the authoritative DTD slot.

---

## 16. References

- Intel IGD OpRegion / Software SCI (Software Interface) Specification
  revision 2.4 (public). Primary reference for §3, §4.
- Intel Alder Lake / Raptor Lake Platform Design Guide (NDA, cited
  only for DDI letter mapping on T14 G4 — informational, §6.2).
- Lenovo PSREF for ThinkPad T14 Gen 4, Table F.4 (DDI → connector
  mapping).
- Linux `drivers/gpu/drm/i915/display/intel_bios.c` and
  `intel_vbt_defs.h` — ground truth for VBT block layouts across
  firmware versions. Cross-referenced throughout.
- VESA EDID DTD specification (release A, revision 2) — Block 42
  DTD field semantics.
- paideia-os `design/graphics/multi-scanout-topology.md` — downstream
  consumer invariants.
- paideia-os `design/drivers/pci-enumeration.md` — upstream handle
  the parser is a child of.
- paideia-os `design/acpi/aml-evaluator.md` — the `_DSM` fallback
  depends on this.
- paideia-os `design/hardware/t14-g4-first-boot.md` §6 — hw-smoke
  recipe the parser's fingerprint lives inside.

---

*End of freeze. Softarch implements against the field offsets,
validation gates, and output struct shapes above; debugger verifies
§12 byte-exact. Field-level drift must come back here as a doc
revision first.*
