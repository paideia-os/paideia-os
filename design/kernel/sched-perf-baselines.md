# PaideiaOS — Kernel: Scheduler Performance Baselines

**Status:** Placeholder
**Date:** 2026-06-17
**Scope:** Performance baselines for the scheduler. Addresses SCH-O10.

---

## 0. Status

Placeholder. Populated when phase-2 implementation runs on bare metal.

---

## 1. Aspirational targets (from `scheduler.md` §13)

| Operation | Target |
|---|---|
| Schedule decision (no preempt) | ≤ 50 ns |
| Schedule decision (preempt, intra-AS) | ≤ 100 ns |
| Cross-AS context switch (full mitigations) | ≤ 1 µs |
| Cross-AS context switch (relax-mitigations) | ≤ 200 ns |
| Same-AS context switch | ≤ 500 ns |
| SC donation across sync RPC | ≤ 100 ns |
| Work-steal operation | ≤ 200 ns |
| UMWAIT-monitored wake | ≤ 200 ns |
| IPI wake | ≤ 1 µs |
| Reserved-core admission decision | ≤ 50 ns |

---

*End of placeholder.*
