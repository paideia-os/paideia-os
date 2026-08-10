# Capturing ACPI Tables from a Live Thinkpad T14 Gen 4

**Issue:** paideia-os#823
**Round / Milestone:** R20 / R20.M5-001
**Consumer:** `tools/parse-acpi-fixture.sh` + `tests/kernel/acpi/t14_g4_fixture.pdx`

This document is the operator-side recipe for capturing the raw ACPI
static tables from a live Thinkpad T14 Gen 4 boot so the R20 parsers
have a real-hardware fixture set to regress against. Complements the
QEMU/OVMF synthetic fixtures at `tests/kernel/acpi/*_synth.pdx`.

**Prerequisite:** a bootable Linux stick or side-installed distro that
mounts `/sys/firmware/acpi/tables/`. Any Ubuntu/Fedora/Arch live USB
from the past ~10 years satisfies this — the sysfs path has been
stable since Linux 2.6.10.

---

## 1. Boot the T14 G4 into a Linux environment

Any of:

- Ubuntu 24.04+ live USB (recommended — well-tested with the R19 BIOS
  setup described in `design/roadmap/r19-t14-g4-boot-guide.md` §3).
- Fedora Workstation live USB.
- Arch install ISO (drops you at a root shell; the fewest moving
  parts).
- An already-installed Linux on the T14 G4's NVMe.

BIOS settings should match the R19 recommendation:

- **Secure Boot:** Off (only for the capture pass — for signed Linux
  it can stay on; the sysfs ACPI table export does not depend on the
  boot posture).
- **Intel VMD Controller:** Off (so NVMe is visible; not strictly
  required for this capture but matches the R19 baseline).
- **TPM 2.0:** On.

## 2. Verify the sysfs path is populated

```
$ ls /sys/firmware/acpi/tables/
APIC  BGRT  DBG2  DMAR  DSDT  ECDT  FACP  FIDT  HPET  LPIT  MCFG
NHLT  PRMT  RSDP  SSDT  SSDT1  SSDT2  SSDT3  ...  TPM2  UEFI  WSMT  XSDT
```

The exact SSDT count varies by BIOS revision; ~15–25 SSDTs is typical
on the T14 G4. **PaideiaOS ingests only the static tables** listed in
§3 below; the SSDT / DSDT content is deferred to the R34 ACPICA
bubble.

## 3. Capture the six tables PaideiaOS R20 consumes

Run these six commands (as root, or with `sudo`; the tables are
readable by root only on most distros):

```
mkdir -p /tmp/t14g4-acpi

sudo dd if=/sys/firmware/acpi/tables/RSDP of=/tmp/t14g4-acpi/rsdp.bin bs=4096
sudo dd if=/sys/firmware/acpi/tables/XSDT of=/tmp/t14g4-acpi/xsdt.bin bs=4096
sudo dd if=/sys/firmware/acpi/tables/APIC of=/tmp/t14g4-acpi/apic.bin bs=4096
sudo dd if=/sys/firmware/acpi/tables/MCFG of=/tmp/t14g4-acpi/mcfg.bin bs=4096
sudo dd if=/sys/firmware/acpi/tables/FACP of=/tmp/t14g4-acpi/facp.bin bs=4096
sudo dd if=/sys/firmware/acpi/tables/HPET of=/tmp/t14g4-acpi/hpet.bin bs=4096
```

Expected sizes on Raptor Lake T14 G4:

| File     | Bytes (approx) | Sig (bytes 0..3, or 0..7 for RSDP) |
|----------|----------------|-------------------------------------|
| rsdp.bin | 36             | `RSD PTR ` (with trailing space)    |
| xsdt.bin | 60–200         | `XSDT`                              |
| apic.bin | 200–500        | `APIC`                              |
| mcfg.bin | 60–80          | `MCFG`                              |
| facp.bin | 244+           | `FACP`                              |
| hpet.bin | 56             | `HPET`                              |

Sanity-check via `file(1)` or `xxd`:

```
$ head -c 4 /tmp/t14g4-acpi/apic.bin; echo
APIC
$ head -c 8 /tmp/t14g4-acpi/rsdp.bin; echo
RSD PTR
```

## 4. Record firmware provenance

Alongside the .bin files, capture identifying metadata so the fixture
is reproducible against the same firmware revision:

```
sudo dmidecode -t 0 -t 1 > /tmp/t14g4-acpi/dmi.txt
uname -a                 > /tmp/t14g4-acpi/uname.txt
cat /sys/firmware/acpi/tables/data/dynamic > /dev/null 2>/dev/null || true
```

`dmi.txt` records the BIOS vendor + version + release date and the
system product name/serial. **The serial should be redacted before
committing** — replace with `XXXX` before `git add`.

## 5. Transfer to the dev host

Options in decreasing convenience:

- USB stick: `cp -r /tmp/t14g4-acpi/ /run/media/USB/`
- `scp`: `scp -r /tmp/t14g4-acpi/ dev-host:~/paideia-os/tests/kernel/acpi/fixtures/`
- Network share, `git format-patch --stdout`, whatever the operator
  has handy.

## 6. Land in the repo

On the dev host:

```
cd ~/paideia-os
mv /path/to/t14g4-acpi/*.bin tests/kernel/acpi/fixtures/t14g4/
git add tests/kernel/acpi/fixtures/t14g4/*.bin tests/kernel/acpi/fixtures/t14g4/dmi.txt
```

Then run the harness:

```
bash tools/parse-acpi-fixture.sh tests/kernel/acpi/fixtures/t14g4/
```

Expected first output:

```
[parse-acpi-fixture] fixture dir: .../fixtures/t14g4
[parse-acpi-fixture] OK: rsdp.bin sig='RSD PTR ' size=36B
[parse-acpi-fixture] OK: xsdt.bin sig='XSDT' size=NNNB
[parse-acpi-fixture] OK: apic.bin sig='APIC' size=NNNB
[parse-acpi-fixture] OK: mcfg.bin sig='MCFG' size=NNNB
[parse-acpi-fixture] OK: facp.bin sig='FACP' size=NNNB
[parse-acpi-fixture] OK: hpet.bin sig='HPET' size=NNNB
[parse-acpi-fixture] summary: 6/6 tables present, 0 sig mismatches
[parse-acpi-fixture] all present tables validated
```

## 7. Enable the fixture witness

Once the .bin files are in-tree, the operator flips the T14 G4 fixture
from "reserved slot" to "active witness":

1. Populate the expected-values table in
   `tests/kernel/acpi/t14_g4_fixture.pdx` (see the file header
   §"Acceptance criteria" for the field list).
2. Add a `.S` wrapper under `tools/` mirroring
   `tools/ap_trampoline_embed.S` that `.incbin`s each of the six .bin
   files into a well-known section (or wait for paideia-as
   `@include_bytes` — filed as `paideia-as#1013` follow-up).
3. Wire a `machine_id`-gated dispatch into `kernel_main_uefi` that
   routes `phase1_acpi_gather` at the embedded fixture pointers when
   the operator boots with `PAIDEIA_MACHINE_ID=t14g4`.
4. Append a T14 G4 row to `design/hardware/quirks.md` recording any
   deltas discovered against the R20 parsers (see the quirks database
   header for the row format).

## 8. Privacy note

The captured tables contain the OEMID + OEM table ID + creator ID
fields from the T14 G4's firmware. These identify the ThinkPad model
family but NOT the individual machine. `dmi.txt` DOES contain
per-unit serial numbers. **Redact `Serial Number` and `UUID` fields
before committing** — replace with `XXXX`. See
`design/acpi/vendor-quirks.md` §3 for the corpus-privacy policy.
