# PaideiaOS — PCI Enumeration Design (R7 / D7-002)

**Status:** Draft v0.1 (R7 groundwork)
**Date:** 2026-06-21
**Issue:** D7-002 (#260)
**Depends on:** D7-001 (driver-framework architecture)
**Scope:** How PaideiaOS discovers PCI/PCIe devices: the two config-space access
mechanisms, the bus-0 enumeration walk, BDF addressing, the vendor-ID sweep, and
bridge recursion. This document scopes what D7-003 implements (legacy port-IO
config accessors) and what is deferred until ACPI parsing exists.

## Pillar alignment

- **Pillar 9 (hierarchical, hot-pluggable).** PCI is the canonical hardware
  hierarchy: host bridge → bus 0 → devices/bridges → secondary buses. The
  enumeration walk *is* the construction of the driver-framework device tree.
- **Pillar 3 (microkernel).** Enumeration runs in a userspace bus-driver task
  holding a port-range capability (0xCF8/0xCFC) or an MMCONFIG region capability;
  the kernel only mints those capabilities.

## 1. Config-space access mechanisms

PCI configuration space (256 bytes legacy, 4096 bytes PCIe extended) is reached
two ways:

### 1.1 Legacy port-IO (CONFIG_ADDRESS / CONFIG_DATA)

Two 32-bit I/O ports:

- `0xCF8` — CONFIG_ADDRESS. Write a BDF-encoded address:
  ```
  bit 31      : enable (1)
  bits 30..24 : reserved (0)
  bits 23..16 : bus      (8 bits)
  bits 15..11 : device   (5 bits)
  bits 10..8  : function (3 bits)
  bits 7..2   : register (6 bits — dword-aligned offset)
  bits 1..0   : 00
  ```
- `0xCFC` — CONFIG_DATA. Read/write the 32-bit word at the addressed register.

This mechanism reaches only the legacy 256-byte config space. It is universally
available (no ACPI needed), so **D7-003 implements this path only.**

### 1.2 MMCONFIG (PCIe Enhanced Configuration Access Mechanism)

PCIe maps all 4096 bytes of each function's config space into physical memory at
`MMCONFIG_BASE + (bus << 20) + (device << 15) + (function << 12) + offset`.
`MMCONFIG_BASE` is reported by the ACPI **MCFG** table.

**Dependency:** MMCONFIG requires ACPI parsing to locate the MCFG table. ACPI is
not yet available at R7. **R7 punts: the MMCONFIG path waits until ACPI parsing
lands; D7-003 ships legacy port-IO only.** Extended config space (offsets
0x100..0xFFF, e.g. MSI-X capability tables) is therefore unreachable until then.

## 2. BDF addressing

A PCI function is addressed by **Bus / Device / Function**:

- Bus: 0..255 (8 bits)
- Device: 0..31 (5 bits)
- Function: 0..7 (3 bits)

A single physical chip may expose up to 8 functions. BDF (0,0,0) is the host
bridge on every PC-class machine.

## 3. Bus-0 enumeration walk

The minimal viable enumeration (what Phase 7 builds on):

```
for device in 0..31:
    if vendor_id(bus=0, device, function=0) == 0xFFFF: continue   # absent
    enumerate_function(0, device, 0)
    if header_type(0, device, 0) has multi-function bit:
        for function in 1..7:
            if vendor_id(0, device, function) != 0xFFFF:
                enumerate_function(0, device, function)
```

`enumerate_function` reads the class/subclass, the header type, and (for
header-type-1, i.e. PCI-to-PCI bridges) the secondary bus number, then recurses
onto that secondary bus.

## 4. Vendor-ID sweep for present devices

A function is *present* iff a config read of register 0 (vendor_id in bits 0..15,
device_id in bits 16..31) returns something other than `0xFFFF` for the vendor.
`0xFFFF` is the bus's response to a config read with no responder.

QEMU default chipset (Intel 440FX) responds at BDF (0,0,0) with
vendor=0x8086 (Intel), device=0x1237 — i.e. a 32-bit register-0 read returns
`0x12378086`. D7-003's smoke test asserts exactly this.

## 5. Header-type-1 bridge recursion

A PCI-to-PCI bridge (header type 1) has a *secondary bus number* at config
offset 0x19. Enumeration recurses onto each secondary bus, producing the full
device tree. Header type 0 (regular device) terminates recursion. The tree built
here is handed to the driver framework (D7-001 §5) as the hot-plug-able device
hierarchy.

## 6. Citations (verification TODO)

- PCI Local Bus Specification rev 3.0 — config-space layout, CONFIG_ADDRESS /
  CONFIG_DATA semantics. **Verify** the revision number and that the bit
  layout above matches the cited revision.
- PCI Express Base Specification 5.0 — MMCONFIG / ECAM addressing. **Verify**
  version and the MCFG-table dependency claim.
- ACPI Specification — MCFG table format (MMCONFIG base discovery). **Verify**
  the ACPI revision once ACPI parsing is designed.

> Reference discipline: the spec/revision numbers above are carried from the
> round plan as **unverified**. Confirm against the primary specs before this
> document loses Draft status.
