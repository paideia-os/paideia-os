---
audit_id: acpi-rsdp-001
issue: 166
file: src/kernel/core/acpi/rsdp.pdx
function: stub_rsdp_find
effects: [rawmem]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT acpi-rsdp-001 — RSDP discovery and RSDT/XSDT parsing

## Justification

The RSDP (Root System Descriptor Pointer) is located in UEFI-provided tables or low
memory (0x000E0000-0x000FFFFF), and points to either RSDT (32-bit) or XSDT (64-bit)
tables. These are raw memory regions provided by firmware that must be parsed to
discover platform configuration tables like MADT (Multiple APIC Description Table).

The unsafe operations include:
- Scanning low memory for RSDP signature ("RSD PTR ")
- Reading raw memory at firmware-provided physical addresses
- Parsing ACPI table headers and entry arrays
- Validating checksums (requires careful pointer arithmetic)
- Following address pointers to MADT and other dependent tables

This is inherently unsafe because:
- Firmware may provide invalid or corrupted addresses
- Table structures vary between ACPI versions
- Checksums must be verified before trusting table data
