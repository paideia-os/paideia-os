# T14 G4 PCI Fixture Directory

**Status:** PLACEHOLDER — awaiting first hardware capture
**Issue:** paideia-os#871
**Round:** R22.M6

This directory holds raw PCI configuration-space blobs and `lspci`
verbose output captured from a live Thinkpad T14 Gen 4 boot. The
captured artifacts serve as the real-hardware regression corpus for
the R22 PCI substrate (enumerator, BAR helpers, cap walkers,
extended-cap walkers, KIND_PCI_DEV publisher).

## Capture recipe

See `tools/capture-t14-g4-pci.md` for the operator-side procedure
(boot Linux on the T14 G4 with **Intel VMD Controller OFF** — see
`design/hardware/quirks.md` §2.4 — then `dd` from
`/sys/bus/pci/devices/*/config` and `lspci -vvv`).

## Expected files (post-capture)

| File                              | Producer                     | R22 issue |
|-----------------------------------|------------------------------|-----------|
| `lspci-verbose.txt`               | `lspci -vvv -mm -nn`         | #855      |
| `lspci-tree.txt`                  | `lspci -tv`                  | #855      |
| `lspci-configspace.txt`           | `lspci -xxx` (256 B/dev)     | #856      |
| `lspci-configspace-extended.txt`  | `lspci -xxxx` (4 KiB/dev)    | #857      |
| `config-DDDD:BB:DD.F.bin`         | `dd if=/sys/…/config` (4KiB) | #851      |
| `dmi.txt`                         | `dmidecode -t 0 -t 1`        | — (prov.) |
| `uname.txt`                       | `uname -a`                   | — (prov.) |

Consumer parsers under `src/kernel/core/pci/`:

- `config.pdx` (R21.M4) — MMIO ECAM accessor, exercised by every
  read of every `config-*.bin`.
- `header.pdx` (R22.M1) — Type-0 and Type-1 header decoders.
- `enum.pdx` (R22.M2) — recursive-descent bridge walker with the
  256-device bounded slab.
- `bar.pdx` (R22.M2) — BAR size + decode helpers.
- `cap.pdx` (R22.M3) — legacy capability walker (offset 0x34 chain).
- `ext_cap.pdx` (R22.M3) — PCIe extended-capability walker (0x100
  chain, 32-bit headers).
- `publish.pdx` (R22.M3) — KIND_PCI_DEV cap-descriptor mint.

## Validation

Once populated, run the harness against this directory (harness lands
alongside the first hardware capture — pattern-matches
`tools/parse-acpi-fixture.sh`):

```
bash tools/parse-pci-fixture.sh tests/kernel/pci/fixtures/t14g4/
```

At R22.M6 close the harness does not yet exist; the capture recipe
+ placeholder fixture + this README lands together and the harness
follows the first real capture.

## Why no fixtures yet?

R22 ran entirely under QEMU-TCG (`-machine q35` + `-machine i440fx`).
The R22 enumerator + BAR + cap walkers were exercised against the
QEMU device tree (rtl8139, PCI Bridge, VGA, and a handful of virtio
placeholders under `-kernel` with `MCFG ABSENT` fallback). The T14
G4 first-light PCI capture is queued for the same session that
captures the ACPI tables (see
`tests/kernel/acpi/fixtures/t14g4/README.md` §"Why no fixtures yet?"
for the same reasoning) — both captures happen alongside R23+ boot
bring-up.

## Not committed

`*.bin` files under this directory are `.gitignore`-neutral (we DO
want them committed once real captures land — they are load-bearing
fixtures). Each blob is ≤4 KiB, so the corpus for 40–60 devices is
<300 KiB — well within the version-control comfort zone. Versioning
them lets bisect + `git blame` associate BIOS-revision quirks with
the specific captured bytes.

## Cross-refs

- `design/hardware/quirks.md` §2.4 (VMD-off row is the load-bearing
  prerequisite for this capture).
- `tools/capture-t14-g4-pci.md` (the capture recipe).
- `tests/kernel/pci/t14_g4_fixture.pdx` (the future fixture witness
  placeholder).
- `tests/kernel/acpi/fixtures/t14g4/README.md` (sibling — ACPI
  static tables from the same first-light session).
- `design/round-retrospectives/r22-closure.md` §"Preflight for R23".
