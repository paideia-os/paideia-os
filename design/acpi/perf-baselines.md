# PaideiaOS — ACPI: ACPICA Bubble Performance Baselines

**Status:** Placeholder
**Date:** 2026-06-17
**Scope:** Performance baselines for the ACPICA bubble. Addresses AC-O5 (restart perf) and broader perf.

---

## 0. Status

Placeholder. Populated at phase 2.

---

## 1. Aspirational targets (from `acpica-bubble.md` §11)

| Operation | Target |
|---|---|
| `AcpiOsGetTimer` | ≤ 50 ns |
| OSL MMIO read/write | ≤ 200 ns |
| Simple AML method evaluation | ≤ 50 µs |
| Complex AML method (boot) | ≤ 100 ms |
| Sleep state entry | ≤ 500 ms |
| SCI dispatch latency | ≤ 50 µs |
| PCIe hot-plug notification | ≤ 100 ms |
| Bubble restart after crash | ≤ 1 s |

---

*End of placeholder.*
