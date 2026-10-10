# tests/graphics — Raw Intel VBT (Video BIOS Table) fixtures

Static byte-stream fixtures the kernel's
`src/kernel/core/drivers/dpy/iris_xe_vbt.pdx` parser is driven against.
Each `.bin` file is a VBT buffer formatted per the Intel IGD OpRegion
spec rev 2.4 (`$VBT ` + BDB header + block stream) ready to be handed
to `vbt_parse(vbt_ptr, vbt_size, out)` without any OpRegion wrapper.

## Current fixtures

| File                       | Source       | Shape                                     | Issue |
|----------------------------|--------------|-------------------------------------------|-------|
| `vbt-sample-t14g4.bin`     | synthesized  | 4 ports, eDP WUXGA panel, PWM backlight   | #2538 |

### `vbt-sample-t14g4.bin` — synthesized

398 bytes, byte-exact per Intel VBT spec, synthesized by
`tools/gen_vbt_fixture.py` to exercise every classification path
in `vbt_parse` the T14 G4 WUXGA SKU is expected to hit at first
boot:

| Offset | Len | Section                     | Decodes to                                |
|-------:|----:|-----------------------------|-------------------------------------------|
|   0x00 |  48 | VBT header                  | `version=254 vbt_size=398 bdb_offset=48`  |
|   0x30 |  32 | BDB header                  | `bdb_version=254 bdb_size=350`            |
|   0x50 | 172 | Block 2 Child Device Table  | 4 child entries, `child_dev_size=40`      |
|   0xFC |  75 | Block 42 LFP Panel Info     | `lvds_panel_type=0`, 70-byte DTD slot 0   |
|  0x147 |  51 | Block 27 eDP electrical     | `link_rate[0]=1 (2.7 Gbps)`, `lane_count[0]=3 (4 lanes)` |
|  0x17A |  20 | Block 43 LFP Backlight Pwr  | `type=PWM pwm_freq=200 bl_default=60 bl_curve=[8,24,…,255]` |

**Panel (slot 0 DTD):**
- `pixel_clock_khz_div_10 = 30_000` → `pixel_clock_khz = 300_000`
- h_active = 1920, h_blank =   80 → h_total = 2000
- v_active = 1200, v_blank =   50 → v_total = 1250
- bpp enum = 1 → 24 bits per pixel (8:8:8)
- `edp_hz = 300_000 * 1000 / (2000 * 1250) = 120` exactly

Numbers chosen for byte-exact integer arithmetic — a real T14 G4
WUXGA panel runs 60 Hz at 193.25 MHz, but the fixture pins 120 Hz
at 300 MHz to make the fingerprint `edp_hz=120` instead of `edp_hz=59`
(which drifts across firmware versions and would mask off-by-one
mistakes in the parser's division). The real-hardware fingerprint
lands under `tests/hw/vbt-t14-g4.txt` (future wave) with the live
numbers.

**Ports (Block 2 child devices, 40 bytes each):**

| Idx | dvo_port | device_type   | aux_ch | hpd | lane_raw+1 | Role                 |
|----:|---------:|---------------|-------:|----:|-----------:|----------------------|
|  0  |    0 (A) | 0x3010 eDP    |      0 |   1 |          4 | eDP → internal panel |
|  1  |    1 (B) | 0x0004 HDMI   |      0 |   2 |          1 | HDMI 2.1 right-side  |
|  2  |    2 (C) | 0x0014 DP     |      2 |   3 |          4 | TB4 left (DP-alt)    |
|  3  |    3 (D) | 0x0014 DP     |      3 |   4 |          4 | TB4 right (DP-alt)   |

Expected `vbt_parse` outcome (recorded verbatim in
`tests/fingerprints/iris_xe_vbt.golden`):

```
VBT PARSE OK n_ports=4 edp_hz=120 vbt_ver=254 panel=1920x1200@24
```

## Replacing with a real T14 G4 capture

Once Wave 59 G2 (modeset) and G1's downstream `KIND_VBT_TOPOLOGY`
emit stabilise, the hw-smoke runner will dump the live OpRegion to
`tests/hw/vbt-t14-g4.bin` and compare against
`tests/hw/vbt-t14-g4.txt`. The synthesized fixture stays as the
QEMU-first lane's single source of truth for the parser's byte
invariants — a real capture varies by BIOS revision but the
parser's byte invariants do not.

## Regeneration

`tools/gen_vbt_fixture.py` is NOT shipped in-tree; it lives
alongside this README as a scratchpad artefact that produced
`vbt-sample-t14g4.bin` once. Re-run from scratchpad if any field
changes; the fingerprint golden must be bumped in lockstep.
