# PaideiaOS — System: Power-Management Subsystem

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Top-level power-management subsystem organization. Addresses AC-O6 + related.

---

## 0. Subsystem components

```
   power-policy (userspace server)
     - Decides S3/S4 transitions
     - Sets CPU P-state targets
     - Wake source config

   thermal-policy (userspace server)
     - Temperature thresholds
     - Active cooling (fan control)
     - Passive cooling (P-state throttling)
     - Emergency shutdown

   battery-monitor (userspace server)
     - Battery state
     - Charging policy
     - Low-battery alerting

   ACPI bubble
     - Executes platform-specific operations on policy server requests

   Supervisor
     - Coordinates cross-server decisions
     - Audits
```

---

## 1. Server interaction

Cross-server: battery low → battery-monitor → power-policy → ACPI bubble → enter S3.

---

## 2. Configuration

User-set policies in `/system/power-management/`:
- `power-profile.toml`: balanced / performance / power-save.
- `thermal-thresholds.toml`: temperature limits.
- `battery-policy.toml`: charging limits, low-battery actions.

---

## 3. Phase delivery

Phase 2: basic functionality.
Phase 3+: refinements (D15 energy-aware integration).

---

## 4. Open issues

| ID | Issue |
|---|---|
| PMS-O1 | Multi-battery systems. |
| PMS-O2 | Workload-aware automatic policy selection. |

---

*End of document.*
