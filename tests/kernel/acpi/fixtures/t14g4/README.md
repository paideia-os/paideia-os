# T14 G4 ACPI Fixture Directory

**Status:** PLACEHOLDER — awaiting first hardware capture
**Issue:** paideia-os#823
**Round:** R20.M5

This directory holds raw ACPI static-table binaries captured from a
live Thinkpad T14 Gen 4 boot. The captured tables serve as the
real-hardware regression corpus for the R20.M1..M3 kernel parsers
(RSDP, XSDT, MADT, MCFG, FADT, HPET, GAS).

## Capture recipe

See `tools/capture-t14-g4-acpi.md` for the operator-side procedure
(boot Linux on the T14 G4, `dd` from `/sys/firmware/acpi/tables/*`).

## Expected files (post-capture)

| File     | Sig        | Consumer parser (src/kernel/acpi/) | R20 issue |
|----------|------------|-------------------------------------|-----------|
| rsdp.bin | `RSD PTR ` | `rsdp.pdx` (acpi_rsdp_scan_range)   | #805      |
| xsdt.bin | `XSDT`     | `xsdt.pdx` (acpi_xsdt_find/iter)    | #806      |
| apic.bin | `APIC`     | `madt.pdx` (madt_parse_*)           | #809–#812 |
| mcfg.bin | `MCFG`     | `mcfg.pdx` (mcfg_parse_segments)    | #814      |
| facp.bin | `FACP`     | `fadt.pdx` (fadt_parse)             | #815      |
| hpet.bin | `HPET`     | `hpet.pdx` (hpet_parse)             | #816      |

Plus metadata:

- `dmi.txt` — output of `dmidecode -t 0 -t 1` (BIOS vendor/version +
  system product; **serial number MUST be redacted** before committing).
- `uname.txt` — Linux release used to capture, for reproducibility.

## Validation

Run the harness against this directory:

```
bash tools/parse-acpi-fixture.sh tests/kernel/acpi/fixtures/t14g4/
```

At R20.M5 close the harness only verifies file-presence + SIG4 header
match; the runtime parser drive lands with the T14 G4 fixture witness
in `tests/kernel/acpi/t14_g4_fixture.pdx` (see that file's header for
the enabling conditions).

## Why no fixtures yet?

R20 ran entirely under QEMU + OVMF; the R19.M5 UEFI stub reaches
first-light but does not yet boot the kernel end-to-end on real
hardware (see `design/roadmap/r19-t14-g4-boot-guide.md` §1). The T14
G4 first-boot is queued for R21+ when the R19 stub lands the ELF
loader that consumes its LMA substitution. The ACPI capture happens
alongside that first boot — the operator can either capture from a
side-installed Linux (any live USB), or capture in a follow-up boot
after first-light succeeds.

## Not committed

`*.bin` files under this directory are `.gitignore`-neutral (we DO
want them committed once real captures land — they are load-bearing
fixtures). The gitignore does NOT exclude this path; the tables are
under 2 KiB each and versioning them lets bisect + git-blame associate
firmware-revision quirks with the specific captured bytes.
