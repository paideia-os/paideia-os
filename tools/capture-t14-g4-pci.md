# Capturing the PCI Device Tree from a Live Thinkpad T14 Gen 4

**Issue:** paideia-os#871
**Round / Milestone:** R22 / R22.M6-002
**Consumer:** `tests/kernel/pci/t14_g4_fixture.pdx` + future `tools/parse-pci-fixture.sh`

This document is the operator-side recipe for capturing the PCI
device tree of a live Thinkpad T14 Gen 4 boot so the R22 enumerator
(`src/kernel/core/pci/enum.pdx`) + BAR helpers
(`src/kernel/core/pci/bar.pdx`) + cap walkers
(`src/kernel/core/pci/cap.pdx` / `ext_cap.pdx`) have a real-hardware
fixture set to regress against. Sibling to `tools/capture-t14-g4-acpi.md`
(ACPI static tables).

**Prerequisite:** a bootable Linux stick or side-installed distro that
mounts `/sys/bus/pci/`. Any Ubuntu/Fedora/Arch live USB from the past
~10 years satisfies this.

**BIOS prerequisite:** Intel VMD Controller must be OFF for the R22
enumerator to see the NVMe controller as a first-class PCIe endpoint
rather than a RAID container child. See `design/hardware/quirks.md`
§2.4 (VMD row, promoted PROVISIONAL → CONFIRMED at first-light) and
the T14 G4 boot guide (`design/roadmap/r19-t14-g4-boot-guide.md` §3).

---

## 1. Boot the T14 G4 into a Linux environment

Same options as `tools/capture-t14-g4-acpi.md` §1. BIOS settings for
this capture pass:

- **Secure Boot:** irrelevant to PCI enumeration; leave at your
  Linux distro's preference.
- **Intel VMD Controller:** **OFF** (mandatory — see #870 quirk row).
- **TPM 2.0:** On.
- **Thunderbolt security:** whatever your distro requires; not
  observed by the PaideiaOS PCI substrate at R22.

## 2. Verify the sysfs PCI hierarchy is populated

```
$ ls /sys/bus/pci/devices/ | head
0000:00:00.0
0000:00:02.0
0000:00:04.0
0000:00:0e.0
0000:00:14.0
...
$ ls /sys/bus/pci/devices/ | wc -l
40-60   # typical Raptor Lake U/P device count with VMD off
```

If VMD is still on, the NVMe controller will be hidden behind a
`10000:` domain instead of visible at `0000:00:0E.0` — abort and
flip the BIOS setting before continuing.

## 3. Capture the device tree

Run these commands (as root or with `sudo`; `lspci -vvv` requires
root to read the extended config space and BAR sizing information):

```
mkdir -p /tmp/t14g4-pci

sudo lspci -vvv -mm -nn > /tmp/t14g4-pci/lspci-verbose.txt
sudo lspci -tv           > /tmp/t14g4-pci/lspci-tree.txt
sudo lspci -xxx          > /tmp/t14g4-pci/lspci-configspace.txt
sudo lspci -xxxx         > /tmp/t14g4-pci/lspci-configspace-extended.txt
```

Then dump the raw 4-KiB configuration space per device (this is what
the R22 ECAM accessor reads at runtime):

```
for d in /sys/bus/pci/devices/*/config; do
  bdf=$(basename "$(dirname "$d")")
  sudo dd if="$d" of="/tmp/t14g4-pci/config-${bdf}.bin" bs=4096 count=1 status=none
done
```

Expected outputs:

- `lspci-verbose.txt` — human-readable per-device capability + BAR
  dump. Anchor for cross-checking the R22 walker output.
- `lspci-tree.txt` — bridge tree in ASCII (matches the R22 recursive
  descent order).
- `lspci-configspace.txt` / `-extended.txt` — 256-byte / 4-KiB config
  hex dumps.
- `config-DDDD:BB:DD.F.bin` — one raw 4-KiB blob per device, byte-
  identical to what `pci_config_read_u32` will observe under
  MCFG-present boot.

## 4. Record firmware provenance

```
sudo dmidecode -t 0 -t 1 > /tmp/t14g4-pci/dmi.txt
uname -a                 > /tmp/t14g4-pci/uname.txt
```

**Redact `Serial Number` and `UUID` before committing** (same privacy
policy as the ACPI capture — see `design/acpi/vendor-quirks.md` §3).

## 5. Transfer to the dev host

Options in decreasing convenience (identical to the ACPI capture
recipe §5): USB stick, `scp`, network share, `git format-patch`.

## 6. Land in the repo

```
cd ~/paideia-os
mkdir -p tests/kernel/pci/fixtures/t14g4/
mv /path/to/t14g4-pci/*.bin tests/kernel/pci/fixtures/t14g4/
mv /path/to/t14g4-pci/*.txt tests/kernel/pci/fixtures/t14g4/
git add tests/kernel/pci/fixtures/t14g4/
```

## 7. Enable the fixture witness

Once the .bin files are in-tree, the operator flips the T14 G4 PCI
fixture from "reserved slot" to "active witness":

1. Populate the expected-values table in
   `tests/kernel/pci/t14_g4_fixture.pdx` — the file header lists the
   fields the operator records (top-level device BDFs, per-device
   VID/DID, BAR count + widths, capability chain per device).
2. Add a `.S` wrapper under `tools/` mirroring
   `tools/ap_trampoline_embed.S` that `.incbin`s each raw config
   blob into a well-known section, OR wait for paideia-as
   `@include_bytes` (`paideia-as#1013`).
3. Wire a `machine_id`-gated dispatch into `kernel_main_uefi` that
   drives the fixture-window pointers through `pci_enumerate_all`
   when the operator boots with `PAIDEIA_MACHINE_ID=t14g4`.
4. Append the observed PCI-plane quirks to `design/hardware/quirks.md`
   §2.4 (a promoted `WORKED-AROUND` row for the VMD-off requirement,
   plus any device-specific rows that surface).

## 8. Expected top-level device inventory (T14 G4 U/P, VMD off)

Rough anchor for anyone reviewing the capture — do NOT hardcode
these into the fixture until the operator confirms on their unit
(exact BDFs vary with BIOS revision + option-card population):

| BDF        | Device                            | R23+ driver |
|------------|-----------------------------------|-------------|
| 00:00.0    | Intel Host Bridge (Raptor Lake)   | — (root)    |
| 00:02.0    | Intel Iris Xe Graphics            | R28 GPU     |
| 00:04.0    | Intel DPTF (Dynamic Platform)     | — (skip)    |
| 00:06.0    | PCIe Root Port                    | — (bridge)  |
| 00:0e.0    | Intel RST NVMe (post-VMD-off)     | R24 NVMe    |
| 00:14.0    | Intel USB 3.1 xHCI                | R26 xHCI    |
| 00:14.2    | Intel Shared SRAM                 | — (skip)    |
| 00:14.3    | Intel CNVi WiFi (AX211)           | R41+ WiFi   |
| 00:16.0    | Intel MEI (ME Interface)          | — (skip)    |
| 00:17.0    | Intel SATA AHCI                   | — (empty)   |
| 00:1f.0    | Intel LPC ISA Bridge              | — (bridge)  |
| 00:1f.3    | Intel HDA (SoundWire + iDSP)      | R30 audio   |
| 00:1f.4    | Intel SMBus                       | — (skip)    |
| 00:1f.5    | Intel SPI Flash                   | — (skip)    |
| 00:1f.6    | Intel i219-LM Ethernet            | R27 e1000e  |

The exact function counts vary — this is the anchor Lenovo PSREF row
for cross-check, not a fixture-hard-coded expectation.

## 9. Privacy note

The captured `lspci-verbose.txt` includes device serial numbers for
some devices (notably the NVMe and the WiFi module). The raw
`config-*.bin` files do NOT — the vendor / device / class / BAR bytes
are model-family identifiers only. **Grep `lspci-verbose.txt` for
`Serial number` or `S/N` and redact before committing.**
