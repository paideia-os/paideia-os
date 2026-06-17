# PaideiaOS — Drivers: Restart Policy

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Concrete numbers for cascade-restart limits and policy behavior. Addresses DR-O10.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| RST-D1 | Default: 3 restarts within 60 seconds → give up | Reasonable threshold |
| RST-D2 | Configurable per driver via registry metadata | Flexibility |
| RST-D3 | "Give up" actions: log audit + emit `unmatched_device` event | Visibility |
| RST-D4 | Supervisor-overridable for specific drivers | Flexibility |
| RST-D5 | Restart backoff: 100ms, 500ms, 2s before each retry | Avoid hammering |

---

## 1. Restart policy

```toml
[driver_restart]
default_max_attempts = 3
default_window_seconds = 60
backoff_schedule = [100, 500, 2000]  # ms before each attempt
on_giveup = "log_and_emit_unmatched"  # or "kill_supervisor", etc.
```

---

## 2. Per-driver overrides

A driver's registry entry can override:

```toml
[driver."critical-network-stack"]
max_attempts = 10           # very tolerant for critical components
window_seconds = 600
```

---

## 3. Driver "give up" semantics

- The supervisor logs to audit: `driver_giveup` with driver_id, attempt count, last failure reason.
- The device is marked "unmatched"; subsequent device_arrived events for this device emit `unmatched_device` audit.
- The user can manually trigger a fresh start via shell command.

---

## 4. Open issues

| ID | Issue |
|---|---|
| RST-O1 | Restart-policy ML tuning — policies could adapt based on observed failure rates. |
| RST-O2 | Cross-driver dependencies — driver A depends on driver B; B's failure cascades. |

---

*End of document.*
