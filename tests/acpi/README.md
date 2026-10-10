# tests/acpi — Raw ACPI _CRS / resource buffers

Static byte-stream fixtures the kernel's `src/kernel/core/acpi/crs.pdx`
parser is driven against. Each `.bin` file is a verbatim ACPI 6.5 §6.4
resource-descriptor stream (small + large items terminated by an END_TAG).

## Current fixtures

| File                      | Source      | Shape                                                   | Issue |
|---------------------------|-------------|---------------------------------------------------------|-------|
| `crs-sample-t14g4.bin`    | synthesized | bus 0..ff, 2 MMIO wins (one ECAM-sized), 1 I/O win      | #2560 |

### `crs-sample-t14g4.bin` — synthesized

Fabricated byte-exact per ACPI 6.5 §6.4 / §19.6.90 to exercise every
code path in `crs_parse` that a T14 G4 PCI root bridge is expected to
hit at R21+ first-boot. 82 bytes total, five descriptors:

| Off  | Len | Descriptor                                 | Decodes to                                    |
|------|-----|--------------------------------------------|-----------------------------------------------|
|  +0  |  16 | Word Address Space (Resource Type = Bus)   | `bus_lo = 0x00`, `bus_hi = 0xFF`              |
| +16  |  26 | DWord Address Space (Resource Type = Mem)  | MMIO win `base=0xC0000000 len=0x10000000` → ECAM (≥ 256 MiB) |
| +42  |  12 | Memory32Fixed                              | MMIO win `base=0xA0000000 len=0x00020000`     |
| +54  |  26 | DWord Address Space (Resource Type = I/O)  | I/O win  `base=0x00001000 len=0x00007000`     |
| +80  |   2 | End Tag                                    | parser returns 1                              |

Expected `crs_parse` outcome (recorded verbatim in
`tests/fingerprints/acpi_crs.golden`):

```
CRS PARSE OK bus_lo=0 bus_hi=ff mmio_wins=2 io_wins=1 ecam=1
```

The ECAM window counts towards `mmio_wins` *and* sets `has_ecam` — the
caller is expected to cross-check the owning device HID (PNP0A08 →
ECAM, PNP0A03 → no ECAM) before trusting the flag.

## Replacing with a real T14 G4 capture

Once the ACPICA DSDT walker (D5) is wired in on real hardware we can
replace this synthesised fixture with the actual firmware payload. The
capture recipe lives alongside the sibling table captures:

- `tools/capture-t14-g4-acpi.md` describes the Linux-side extraction.
- Dump the PNP0A08 root-bridge device's `_CRS` buffer bytes (strip the
  AML Buffer wrapper so only the raw descriptor stream remains).
- Overwrite `crs-sample-t14g4.bin` and regenerate the golden file.

The parser itself does not care whether the input is synthetic or
captured — both go through the same byte-stream decoder.
