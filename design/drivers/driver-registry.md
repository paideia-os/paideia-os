# PaideiaOS — Drivers: Driver Registry Storage

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Concrete storage and update mechanism for the driver registry. Addresses DR-O4.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| REG-D1 | Registry stored as CoW FS file at `/system/drivers/registry.toml` | Standard |
| REG-D2 | Each entry signed by release-line key | Authentication |
| REG-D3 | Cached in supervisor memory after load | Performance |
| REG-D4 | Updates via PR-style transactional commit | Standard |

---

## 1. Registry entry

```toml
[driver."intel-igc"]
matches = [
  { vid = 0x8086, pid_range = "0x15F2-0x15F9", class = "network" }
]
binary = "/system/drivers/intel-igc.pax"
version = "1.0.0"
required_capabilities = ["pcie.access", "mmio.bar", "irq.vector"]
signature = "..."
```

---

## 2. Update mechanism

1. New driver: PR adds entry to registry.toml + uploads binary.
2. Atomic transaction: both entry and binary commit together.
3. Supervisor re-reads on next event or via reload signal.

---

## 3. Per-user override (rare)

For development: per-user driver entries override system. Audited.

---

## 4. Open issues

| ID | Issue |
|---|---|
| REG-O1 | Registry growth — when does it need indexing? |

---

*End of document.*
