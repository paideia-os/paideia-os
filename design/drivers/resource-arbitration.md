# PaideiaOS — Drivers: Resource Conflict Resolution

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Tiebreaker rules when multiple drivers match a device. Addresses DR-O5.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| ARB-D1 | Most-specific match wins | Standard |
| ARB-D2 | Among ties: registry priority field | Explicit |
| ARB-D3 | Among ties at same priority: PR order (deterministic) | Reproducible |
| ARB-D4 | User can override via boot parameter | Flexibility |

---

## 1. Specificity ranking

| Match | Specificity |
|---|---|
| Exact VID + PID + Class | 100 |
| VID + PID range | 80 |
| VID + Class | 60 |
| VID only | 40 |
| Class only | 20 |
| Schema match (phase 3+) | varies |

---

## 2. Priority field

```toml
[driver."generic-nic"]
priority = 10  # low; can be overridden by more-specific
matches = [{ class = "network" }]

[driver."intel-igc"]
priority = 100  # higher; preferred for Intel NICs
matches = [{ vid = 0x8086, class = "network" }]
```

---

## 3. Boot override

`driver_force=0x8086:0x15F2:generic-nic` overrides the registry for a specific device.

---

## 4. Open issues

| ID | Issue |
|---|---|
| ARB-O1 | Schema-based matching priority (phase 3+). |

---

*End of document.*
