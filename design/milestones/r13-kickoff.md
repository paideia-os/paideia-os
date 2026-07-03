# PaideiaOS R13 Kickoff: Three-Path Decision Gate (Multicore / MM / Handler-Table)

**Status:** DESIGN — pending path decision  
**Date:** 2026-07-03  

---

## Overview

R12 closed the per-kind capability dispatch system and deferred three distinct next-round options. R13 will pursue **one path** (recommended: A) and document a parallel alternative for R14. This document outlines scope, substrate blockers, and observable payoff for each path.

---

## Path A (Recommended): Multicore Bring-Up

**Headline:** Real multicore with per-CPU runqueues, cross-CPU IPI, and GS-based thread-local storage.

**Observable:** Boot output shows `CPU 0 / CPU 1` tags on COM1, proving SIPI (Start IPI) woke the second AP (Application Processor) and both CPUs are running distinct tasks concurrently.

**Milestones (sketch):**

- **A1:** Pre-flight (encoder verification for four new paideia-as escalations).
- **A2:** LAPIC SIPI sequence (send Start IPI to AP, bootstrap page, AP entry point).
- **A3:** Per-CPU GS-based data (`_current_tcb` becomes `[gs:0]`, per-CPU runqueues).
- **A4:** Cross-CPU IPI handler (real vec33 dispatch for TLB shootdown, per-CPU wakeup).
- **A5:** Smoke fixture (mint two tasks per CPU, run concurrently, observe alternation across CPUs).
- **A6:** Closure (multicore foundation, pre-push gate on boot_r13_mp).

**Substrate Requirements (HARD blockers, filed as PA-R12-001..004):**

1. **PA-R12-001:** GS-relative mem operand (`mov rax, [gs:offset]`). Blocking m2 (per-CPU data access).
2. **PA-R12-002:** `xchg [mem], reg` (atomic swaps for per-CPU spinlocks). Blocking m4 (IPI dispatch).
3. **PA-R12-003:** `lock cmpxchg` (compare-and-swap for cap table updates across CPUs). Blocking m5 (concurrent cap invoke).
4. **PA-R12-004:** `mfence` (memory barrier for inter-CPU ordering). Blocking m4/m5 (IPI memory sync).

**Estimated size:** 15–20 issues. If all four escalations land in a single paideia-as bump, R13A is straightforward. If any slip, multicore opens blocked and Path B (MM activation) becomes the fallback R13.

**Risk:** High on substrate; low on kernel logic (multicore code is well-understood per seL4, Linux, etc.). Mitigation: file PA escalations in a single GitHub PR to the paideia-as repo, target a shared v0.12.0 release (vs. multiple point releases).

**Recommendation:** **Pursue Path A.** Multicore is the highest-leverage observable (true parallelism) and unlocks downstream R13.5/R14 work (per-CPU memory management, per-CPU device drivers). The four escalations are "S" or "M" in paideia-as; bundling them in one substrate bump is the highest ROI use of paideia-as engineering effort.

---

## Path B (Alternative): Memory Management API Activation

**Headline:** Real `aspace_map` / `aspace_unmap` with 4-level page-table walk, per-address-space CR3 reload, and cap-mediated MM via KIND_PAGE_TABLE.

**Observable:** Boot output shows virtual-vs-physical address mapping, proving page tables are walked and CR3 is context-switched per address space.

**Milestones (sketch):**

- **B1:** Pre-flight (MM API design, KIND_PAGE_TABLE handler).
- **B2:** Page-table walker (real 4-level PML4→PDP→PD→PT, leaf PTE composition, INVLPG).
- **B3:** aspace_map real body (walk page tables, allocate intermediate levels, set permission bits).
- **B4:** Per-aspace CR3 reload during preemption (`sched_preempt_to` now CR3-switches).
- **B5:** KIND_PAGE_TABLE handler and cap-driven OP_MAP (cap_invoke(slot, OP_MAP) → aspace_map).
- **B6:** Smoke fixture (mint KIND_PAGE_TABLE cap, invoke OP_MAP, verify virtual mapping).
- **B7:** Closure (MM activation, pre-push gate on boot_r13_mm).

**Substrate Requirements:**

- **Minor:** Likely some additional mem-operand variants (INVLPG with register operand; LLDT/SLDT for per-aspace descriptor-table switching — deferred to R14).
- **Architectural:** PAGE_TABLE entry structure in kind.pdx. CR3 composition and switch in preemption logic.

**Estimated size:** 15–18 issues. No HARD blockers; substrate risk is lower than Path A.

**Risk:** Medium on kernel logic (4-level walk with bounds checking is error-prone; off-by-one in index extraction causes silent corruption). Medium on testing (MM correctness is hard to verify without address-space isolation; smoke must use distinct virtual ranges to avoid collisions).

**Recommendation:** **Defer to R14.** MM activation is second in priority; pursuing it now (if Path A multicore slips) keeps momentum. But multicore is the higher observable and unblocks more downstream work. If R13A completes early and sub-budget, MM can be R13.5.

---

## Path C (Optional): Handler-Table Migration + Remaining Kinds

**Headline:** Refactor dispatch from direct if/else-chain (A1 style, limited to ~12 kinds) to indirect function-pointer table (A2 style), then land the eight remaining cap-kinds (PROCESS, THREAD, PAGE_TABLE, IPC_PORT, TIMER, INTERRUPT, NOTIFICATION, REPLY).

**Observable:** boot_r13c shows eight additional `CAP INVOKE ...` tags, proving eight kinds now dispatch to real handlers.

**Milestones (sketch):**

- **C1:** Pre-flight (handler-table architecture, per-kind bit assignments).
- **C2:** Refactor dispatch (replace m2-001's four-way branch with indirect call through `handler_table[16]`).
- **C3:** Land 4 remaining mem-adjacent kinds (PAGE_TABLE, PROCESS, THREAD, IPC_PORT).
- **C4:** Land 4 remaining async kinds (TIMER, INTERRUPT, NOTIFICATION, REPLY).
- **C5:** Smoke fixture (mint all 12 kinds, invoke each, verify handlers reached).
- **C6:** Closure (12-kind dispatch, pre-push gate on boot_r13c).

**Substrate Requirements:** None. Direct use of paideia-as v0.11.0+19 encoders; no escalations.

**Estimated size:** 12–15 issues. All parallelizable; fastest of the three paths wallclock.

**Risk:** Low on substrate; medium on design coherence (eight new handlers, each with different op semantics, could lead to inconsistency). Medium on regression (boot_r12 fingerprint must still pass; adding 8 new tags between existing anchor points requires tight contains-in-order matching).

**Recommendation:** **Pursue as R13.5 add-on, not standalone R13.** R13A (multicore) + R13.5C (handler-table + 8 kinds) gives a complete picture: multicore + dispatch scalability + extensibility. Path C standalone leaves multicore deferred to R14, which is inefficient.

---

## Decision Checklist for R13 Kickoff

At the start of R13 m1 (pre-flight audit), confirm:

1. **Path A multicore:** All four PA-R12-001..004 escalations landed in paideia-as. If yes → pursue Path A. If no, any slip → pursue Path B as fallback.
2. **Path B MM:** No hard blockers. Substrate risk is lower; can start immediately even if Path A stalls.
3. **Path C handler-table:** No blocking dependencies. Can launch as R13.5 parallel track if A finishes early.

---

## Recommended Sequencing for R13

**Scenario 1 (all escalations land):**

```
Week 1: R13A m1-m3 (pre-flight, SIPI, per-CPU data) in parallel with setup
Week 2: R13A m4-m5 (IPI, smoke)
Week 3: R13A m6 (closure)
Week 4: R13.5C m1-m3 (handler-table, first 4 kinds) in parallel
Week 5: R13.5C m4-m6 (remaining 4 kinds, smoke, closure)
```

**Scenario 2 (some escalations slip):**

```
Week 1: Begin R13B m1 (MM pre-flight) while waiting for paideia-as
Week 2: If escalations land, pivot to R13A. If not → continue R13B.
Week 3-5: Pursue selected path (A or B).
```

---

## Deferred to R14+

- **Curried-call wrapper support** (cap_invoke surface syntax).
- **Per-cap IPC channel addressing** (descriptor.target_ptr encodes channel indices).
- **Generation-based revocation validation** (check descriptor.generation in dispatch).
- **Sealed capabilities** (sealed flag + sealing-key check).
- **Kind-specific rights lattice** (high 32 bits per kind).
- **Audit-log integration** (persistent runtime log, not just COM1 tags).
- **Multimode device support** (multiple BAR mappings per KIND_DEVICE).
- **Per-address-space privilege levels** (x86 rings 0/1/2/3, or seL4-style fault handlers).

---

## Pillar Alignment

**Path A (Multicore):**
- Pillar 1 (Cooperative scheduling) → upgraded to preemptive + multicore.
- Pillar 3 (Strict microkernel) → per-CPU capability enforcement via cross-CPU IPI.
- Pillar 10 (Functional discipline) → per-CPU GS-based data as function parameters (implicit via RGS).

**Path B (MM API):**
- Pillar 5 (Memory safety) → active address-space isolation via page tables.
- Pillar 3 (Strict microkernel) → cap-driven `aspace_map` (KIND_PAGE_TABLE dispatch).

**Path C (Handler-Table):**
- Pillar 10 (Functional discipline) → data-driven dispatch table vs. control-flow chain (extensibility).
- Pillar 11 (Research-driven) → seL4 `Arch_decodeInvocation` table-based architecture (formal methods alignment).

---

**Status:** Awaiting R13 kickoff decision on substrate and path selection.  
**Author:** Santiago Nunez-Corrales  
**Date:** 2026-07-03
