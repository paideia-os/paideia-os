# PaideiaOS — ACPI: Phase-1 NASM Parser

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Scope and structure of the phase-1 hardcoded ACPI table parser. Addresses AC-O4.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| P1AC-D1 | Phase-1 parses only MADT, MCFG, FADT, RSDP/XSDT | Bare minimum for boot |
| P1AC-D2 | No AML interpretation | Phase 2 ACPICA bubble |
| P1AC-D3 | Implemented in NASM, ~2000 LOC | Per acpica-bubble.md §0.2 |
| P1AC-D4 | Targets only QEMU virtual hardware | Phase-1 dev env |

---

## 1. Tables parsed

| Table | Purpose |
|---|---|
| RSDP | Root System Description Pointer; entry point |
| XSDT | Extended System Description Table; lists other tables |
| FADT | Fixed ACPI Description Table; PM I/O ports, FACS pointer |
| MADT | Multiple APIC Description Table; CPU and IOAPIC topology |
| MCFG | PCI Express memory-mapped configuration space base addresses |

---

## 2. What phase-1 *does not* parse

- DSDT / SSDT (require AML interpretation; phase 2).
- HPET / TPM2 (phase 2).
- SRAT (NUMA topology — phase 2; phase 1 assumes single NUMA).
- All vendor-specific tables.

---

## 3. Output structure

The parser produces a kernel-visible structure:

```nasm
struct phase1_acpi_info {
   u32 cpu_count
   u32 ioapic_count
   u64 ioapic_bases[16]
   u32 cpu_apic_ids[256]
   u64 pcie_cfg_base
   u64 pcie_cfg_segment_count
   u64 pm1a_control_port
   u64 pm1b_control_port
   u64 pm_timer_port
   u64 sci_vector
}
```

This is consumed by the kernel to set up x2APIC, PCIe enumeration, and basic power-management knowledge.

---

## 4. Migration to phase 2

When phase 2 lands and the ACPICA bubble brings up the full parser, the phase-1 parser remains in the kernel for *kernel-internal* table reads (the kernel still needs IOAPIC base etc. before the bubble starts). The bubble's parser is the source of truth for AML and post-init queries.

---

## 5. Open issues

| ID | Issue |
|---|---|
| P1ACP-O1 | Table-overflow detection — corrupt tables on real hardware. |
| P1ACP-O2 | The exact NASM macro structure — TBD during implementation. |

---

*End of document.*
