# PaideiaOS — ACPI: User DSDT Override Mechanism

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** User-provided DSDT override for development and debugging. Addresses AC-O10.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| DO-D1 | Boot parameter `dsdt=<path>` triggers override | Standard mechanism |
| DO-D2 | User-DSDT measured into PCR-12 (separate from firmware PCRs) | Distinguishable |
| DO-D3 | Audit log records every override event | Visibility |
| DO-D4 | Production deployments warn on every boot when override active | Security |

---

## 1. Override sequence

```
1. Boot loader reads dsdt= parameter from command line.
2. Loader reads user DSDT from boot media (typically the EFI partition).
3. Loader extends PCR-12 with the user DSDT's BLAKE3 hash.
4. Loader substitutes user DSDT for firmware DSDT in RSDP.
5. Audit log entry: "DSDT override active, hash=...".
```

---

## 2. Use cases

- Debugging vendor BIOS bugs.
- Testing custom AML methods.
- Workaround for unsupported firmware.

---

## 3. Production warning

A production deployment with DSDT override prints a warning at boot:
"WARNING: ACPI DSDT override active; system may not be in production-supported configuration."

---

## 4. Open issues

| ID | Issue |
|---|---|
| DO-O1 | The boot loader's reading of dsdt= parameter (UEFI variable vs. command line). |

---

*End of document.*
