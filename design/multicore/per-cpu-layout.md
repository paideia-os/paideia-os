---
audit_id: r14b-m5-001-cpu-local-layout
issue: 506
file: src/kernel/core/cpu/local.pdx
function: (per-CPU control block layout)
effects: []
capabilities: []
reviewed_by:
date: 2026-07-04
---

# Per-CPU Control Block Layout (cpu_local_t)

## Overview
R14b-m5-001 (#506) introduces `cpu_local_t` — a per-CPU control block used
by the R14.M5 TLB shootdown / IPI substrate. Slot 0 backs the single BSP
at MAX_CPUS=1; the layout is designed to survive MAX_CPUS scale-up without
reflow.

## Layout table

| Offset | Size | Field              | Notes                                              |
|-------:|-----:|--------------------|----------------------------------------------------|
|      0 |    8 | cpu_id             | APIC / logical index; slot-0 = 0 via .bss zero-init |
|      8 |    8 | current_tcb_ptr    | mirrors _current_tcb; consumed by GS[+8] fast path  |
|     16 |    8 | tlb_mailbox_head   | ring head index into tlb_mailbox_va[] (0..8)        |
|     24 |   64 | tlb_mailbox_va[8]  | 8-slot ring of pending shootdown VAs               |
|     88 |   40 | reserved           | future: idle_tcb, preempt_disable, tsc_deadline    |
|    128 |    — | end                | 128 B = 2 cache lines, @align(64)                   |

## Access pattern (planned)
- `mov rax, [gs:0]` → cpu_id (once gs-mem-operand encoder confirms, PA-R14-001).
- `mov rax, [gs:8]` → current_tcb_ptr.
- Ring mailbox for TLB shootdown per R14.M5-004 wiring.

## Initialization
- MAX_CPUS=1: .bss zero-init satisfies slot 0 (cpu_id=0). No boot code needed.
- MAX_CPUS>1: cpu_local_init() stamps cpu_id=i per slot i, lands with AP bring-up.

## Cross-references
- Conflicting stub: src/kernel/core/sched/gs_current.pdx — retire in R14.M5-002.
- IPI mailbox migration: src/kernel/core/ipi/tlb_shootdown.pdx — R14.M5-003.
- MAX_CPUS unification: currently 1 (CpuLocal) vs 16 (TlbShootdown) — resolve in R14.M5-003.
