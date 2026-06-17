# PaideiaOS — Drivers: CPU Hot-Plug

**Status:** Draft v0.1 (phase 3+)
**Date:** 2026-06-17
**Scope:** CPU online/offline as part of the driver framework. Addresses DR-O9.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| CHP-D1 | CPUs are "devices" in the framework | Uniformity |
| CHP-D2 | Phase 3+ feature | Scope realism |
| CHP-D3 | The scheduler is the consumer of CPU device events | Natural fit |

---

## 1. CPU as device

A CPU is a device in the framework:
- Bus driver: the ACPI bubble enumerates CPUs via MADT/_OSC.
- Device driver: there isn't one — the scheduler directly consumes "CPU arrived" / "CPU departed" events.

---

## 2. Online sequence

When a CPU is hot-added (rare on PCs; common on cloud/virtualization):
1. ACPI bubble emits `device_arrived` for the new CPU.
2. Supervisor signals the scheduler.
3. Scheduler initializes per-CPU areas, runqueue, idle SC.
4. Scheduler marks the CPU online; it becomes eligible for scheduling.

---

## 3. Offline sequence

When a CPU is hot-removed:
1. Scheduler quiesces the CPU (no new SCs scheduled).
2. Running threads migrate (per NUMA migration semantics).
3. Per-CPU resources freed.
4. ACPI bubble emits `device_departed`.

---

## 4. Phase 3+ delivery

Phase 1-2: CPUs are static (discovered at boot, never change).
Phase 3+: hot-plug supported.

---

## 5. Open issues

| ID | Issue |
|---|---|
| CHP-O1 | Real-hardware support — most x86_64 client systems don't support CPU hot-plug. |
| CHP-O2 | Cloud VM resize integration. |

---

*End of document.*
