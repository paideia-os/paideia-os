# PaideiaOS — Kernel: Phase-1 Scheduler API

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Phase-1 simplified scheduler interface. Addresses SCH-O9.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| P1SCH-D1 | Fixed-priority preemptive scheduling | Same policy as phase 2; simpler implementation |
| P1SCH-D2 | Per-CPU runqueues; no work stealing | Phase-2 deferred |
| P1SCH-D3 | No SC donation | Phase-2 feature |
| P1SCH-D4 | HLT-only idle | Phase-2 will add tiered |
| P1SCH-D5 | Always-on mitigations (no same-AS optimization) | Phase-2 feature |
| P1SCH-D6 | No reserved cores | Phase-2 feature |
| P1SCH-D7 | No hybrid-core handling | All CPUs treated as Any |

---

## 1. Phase-1 operations

```nasm
; Create an SC.
; Inputs: RDI = budget (ns), RSI = period (ns), RDX = priority (0-255)
; Output: RAX = SC handle
extern p1_sc_create

; Bind SC to a thread.
; Inputs: RDI = SC handle, RSI = TCB handle
extern p1_sc_bind

; Unbind SC.
; Input: RDI = SC handle
extern p1_sc_unbind

; Make a thread runnable.
; Input: RDI = TCB handle
extern p1_sched_wake

; Yield the current CPU.
extern p1_sched_yield

; Block the current thread waiting for a wake.
; Input: RDI = optional timeout (ns)
extern p1_sched_block

; Get current TCB.
; Output: RAX = current TCB
extern p1_sched_current
```

7 entry points.

---

## 2. What's missing vs phase 2

- Work stealing (per SCH-Q3).
- SC donation across sync IPC (per SCH-Q6).
- Tiered idle (per SCH-Q7).
- Same-AS mitigation optimization (per SCH-Q10).
- Hybrid-core placement (per SCH-Q5).
- Reserved-core capability (per SCH-Q4).

Phase-1 callers continue via wrappers.

---

## 3. Open issues

| ID | Issue |
|---|---|
| P1SCH-O1 | Phase-1 timer resolution — TSC-deadline only; phase 2 adds wheel for many timers. |
| P1SCH-O2 | When to migrate each subsystem to phase-2 scheduler — coordinate with `milestones.md`. |

---

*End of document.*
