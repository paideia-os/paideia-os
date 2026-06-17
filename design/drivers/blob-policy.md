# PaideiaOS — Drivers: Blob Driver Activation Policy

**Status:** Draft v0.1 (phase 3+)
**Date:** 2026-06-17
**Scope:** User-consent flow and threat model for blob driver activation. Addresses DR-O2.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| BLB-D1 | Blob driver activation requires explicit user consent | Pillar 6 |
| BLB-D2 | Consent recorded in audit log | Visibility |
| BLB-D3 | Re-confirmed annually | Renewal |
| BLB-D4 | Per-vendor consent (not global) | Granularity |

---

## 1. Consent flow

```
User: "Install NVIDIA blob driver"
System: Display:
  "This driver is NOT open source. It runs in an IOMMU-isolated process.
   Source code is unavailable for audit. Vendor: NVIDIA.
   The PaideiaOS project does not vouch for this driver's behavior.
   
   Do you consent? [yes/no]"
User: yes
System: Audit log records consent.
        Driver installed with blob_driver_cap.
```

---

## 2. Threat model

Blob drivers are *untrusted code*:
- IOMMU prevents DMA to other devices.
- Capability set is minimal (per-device only).
- Audit log records all blob driver operations.
- A malicious blob can corrupt its own device's data but not others.

---

## 3. Annual re-confirmation

Each year, the user is prompted to re-confirm blob consent (with the option to revoke).

---

## 4. Open issues

| ID | Issue |
|---|---|
| BLB-O1 | Blob driver delivery — repository, signature, update mechanism. |
| BLB-O2 | Per-vendor trust tiers (e.g., trust NVIDIA more than unknown vendors). |

---

*End of document.*
