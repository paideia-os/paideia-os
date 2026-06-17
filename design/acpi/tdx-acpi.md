# PaideiaOS — ACPI: TDX Guest ACPI Semantics

**Status:** Draft v0.1 (phase 3+)
**Date:** 2026-06-17
**Scope:** ACPI handling when PaideiaOS runs as a TDX guest. Addresses AC-O9.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| TXA-D1 | TDX guests have minimal ACPI — most platform abstraction handled by SEAM module | TDX-specific |
| TXA-D2 | The ACPICA bubble operates as normal; minimal tables suffice | Standard |
| TXA-D3 | No SCI from host firmware; TDX-specific event delivery | TDX |

---

## 1. TDX guest ACPI tables

- MADT: lists vCPUs.
- MCFG: minimal PCIe config.
- FADT: minimal (no PM ports typical of bare metal).

The TDX VMM provides these tables; ACPICA reads as normal.

---

## 2. Event delivery

TDX guests don't see SCI from host firmware. Power button, lid, etc. are TDX-specific notifications via the host VMM.

---

## 3. Sleep state limitations

- S3 may not be supported (depends on TDX VMM).
- S5 (shutdown) is host-mediated.

---

## 4. Open issues

| ID | Issue |
|---|---|
| TXA-O1 | Concrete TDX guest ACPI integration once TDX upstream stabilizes. |

---

*End of document.*
