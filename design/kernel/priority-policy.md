# PaideiaOS — Kernel: Priority Band Policy

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Formalization of the priority-band convention from `scheduler.md` §3.6 as project policy. Addresses SCH-O2.

---

## 0. Priority bands (policy)

| Range | Use | Example holders |
|---|---|---|
| 0 | Idle | Kernel idle SC only |
| 1–32 | Background workloads | Audit-log flush, GC, compaction, snapshot creation |
| 33–96 | General-purpose userspace | Most applications |
| 97–160 | Interactive userspace | Shell, GUI, editors |
| 161–192 | Latency-sensitive servers | Network stack, audio, video, FS |
| 193–224 | Drivers and time-critical kernel servers | NVMe, NIC, USB |
| 225–254 | Kernel-supervisor | Allocator, MemoryPressure handler, audit log |
| 255 | Reserved for kernel-internal scheduling | Idle SC, refill timer SC |

---

## 1. Enforcement

The supervisor's policy enforces:
- A process registered in band X cannot mint SC handles outside the band's range.
- Cross-band escalation (e.g., a user process requesting priority 200) requires a `priority_escalation_cap` granted by the supervisor; audited.

---

## 2. Band 255 is special

Band 255 is reserved for *kernel-internal* SCs (idle, refill timer, MemoryPressure handler stub). User code cannot run at band 255 even with capability escalation.

---

## 3. Why a convention, not enforcement

This is *policy*, not *mechanism*. The scheduler does not enforce band semantics; the supervisor enforces band-to-process assignment via the capability system.

A misbehaving supervisor could assign band 192 to a user app; this would be visible in the audit log. The convention exists for predictability and reasoning across the codebase.

---

## 4. Open issues

| ID | Issue |
|---|---|
| PRI-O1 | Granularity within bands — how do drivers self-prioritize within band 193–224? |
| PRI-O2 | Cross-band promotion via SC donation — when a producer at band 100 donates to a consumer at band 50, the consumer runs effectively at 100; this is expected and audited. |

---

*End of document.*
