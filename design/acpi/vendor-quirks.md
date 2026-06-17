# PaideiaOS — ACPI: Vendor Quirk Corpus

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Vendor-quirk test corpus for the ACPICA bubble. Addresses AC-O3.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| VQ-D1 | Maintain a corpus of ACPI tables from real motherboards | Compatibility |
| VQ-D2 | Tables collected via a dump utility | Manual collection |
| VQ-D3 | Test corpus run nightly | CI |

---

## 1. Collection mechanism

A small utility (`dump-acpi`) runs on a target system and produces a binary blob of all ACPI tables. Users contribute via a project repo.

---

## 2. Test format

For each table set:
- The table dump.
- The expected behavior (which devices ACPICA should discover).
- The expected events (button presses, lid open/close, etc.).

Test runs ACPICA against the dump in a QEMU sandbox; verifies expectations.

---

## 3. Public corpus

A public collection encourages contribution. Privacy: dumps contain motherboard identifiers; users opt-in to sharing.

---

## 4. Open issues

| ID | Issue |
|---|---|
| VQ-O1 | Specific motherboards to target for corpus collection. |

---

*End of document.*
