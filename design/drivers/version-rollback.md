# PaideiaOS — Drivers: Driver Versioning and Rollback

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Driver update failure recovery via automatic rollback. Addresses DR-O6.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| VRB-D1 | Driver registry keeps current + previous version | Rollback path |
| VRB-D2 | If new driver crashes on first start, supervisor rolls back automatically | Self-healing |
| VRB-D3 | Manual rollback via shell command | Operator control |
| VRB-D4 | Audited | Visibility |

---

## 1. Update flow

```
1. New driver version is installed.
2. Registry entry updated.
3. Hot-plug events route to new driver.
4. New driver starts.
5. If crashes during init: supervisor logs, reverts registry, starts previous version.
6. If runs successfully: previous version kept as fallback for cascade-restart window.
```

---

## 2. Manual rollback

`drivers rollback <driver_id>` reverts to previous version. Audited.

---

## 3. Open issues

| ID | Issue |
|---|---|
| VRB-O1 | How many versions to keep — currently 2 (current + previous). |

---

*End of document.*
