# PaideiaOS — ACPI: Power, Thermal, Battery Server Architecture

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Sketch of the power-management, thermal, and battery servers referenced by the ACPICA bubble. Addresses AC-O6.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| PM-D1 | Three separate userspace servers: `power-policy`, `thermal-policy`, `battery-monitor` | Microkernel pillar |
| PM-D2 | Each consumes the ACPICA bubble's IPC interface | Standard pattern |
| PM-D3 | The supervisor coordinates cross-server decisions | Central policy |

---

## 1. power-policy

Owns:
- Decisions on entering S3, S4, S5.
- CPU P-state targets.
- Wake source configuration.

Consumes:
- ACPI events from the bubble (power button, lid switch).
- System-wide capability set (running processes).

Produces:
- Requests to the bubble to execute state transitions.

---

## 2. thermal-policy

Owns:
- Temperature thresholds.
- Active cooling decisions (fan up/down).
- Passive cooling (P-state throttling under heat).
- Emergency shutdown.

Consumes:
- Temperature readings from the bubble (via `_TMP` evaluations).
- Cross-component info (CPU load, NIC traffic).

Produces:
- EC (embedded controller) commands via the bubble.
- P-state hints to power-policy.

---

## 3. battery-monitor

Owns:
- Battery state (level, charging, time-remaining).
- Charging policy.

Consumes:
- Battery and AC adapter events from the bubble.

Produces:
- State publishing to supervisor and user-facing services.

---

## 4. Integration

Cross-server: when battery is low, battery-monitor signals power-policy, which decides to enter S3.

---

## 5. Open issues

| ID | Issue |
|---|---|
| PM-O1 | Detailed protocol between the three servers and the supervisor. |
| PM-O2 | Multi-battery / multi-zone systems. |
| PM-O3 | Phase delivery — phase 2 for basics; phase 3+ for refinements. |

---

*End of document.*
