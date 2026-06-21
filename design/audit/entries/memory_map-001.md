---
audit_id: memory_map-001
issue: 90
file: src/kernel/core/mm/memory_map.pdx
function: (data structure; no function body)
effects: [rawmem]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT memory_map-001 — Memory Map Parser

## Justification
The memory map parser decodes the BIOS-provided E820 memory map entries
at kernel boot to distinguish usable RAM from reserved regions (ACPI tables,
MMIO, etc.). Each entry is read directly from bootloader-provided memory
and classified by type (MEM_MAP_TYPE_USABLE=1, MEM_MAP_TYPE_RESERVED=2).

This is a Phase-5 stub that documents the unsafe memory-read surface
(rawmem) that will be used when the parser implementation ships in Phase 6.
The real implementation will contain unbounded pointer dereferences into
the bootloader-provided E820 table.
