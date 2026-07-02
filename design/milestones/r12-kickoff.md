# PaideiaOS R12 Kickoff: Multicore Bootstrap or Alternative Cap Path

**Status:** PLANNED  
**Expected Milestones:** R12.M1–R12.M5  
**Target Date:** Post-R11 closure  

---

## Overview

**R12** pursues one of three architecture paths based on substrate readiness and design priorities:

1. **Multicore Path (R12A):** SIPI/AP bootstrap, per-CPU GS-based data, SMP scheduling
2. **Capability System Path (R12B):** Per-kind cap_invoke dispatch, extensible operations
3. **Memory Management Path (R12C):** MM API activation, aspace_map/unmap implementations

This document outlines all three paths. The chosen path will be determined during R11 closure based on paideia-as substrate readiness and project priorities.

---

## R12 Path Decision Matrix

### Path 1: Multicore (R12A) — SMP Scheduling Foundation

**Preconditions:**
- ✓ Preemptive scheduling works (R11 complete)
- ✓ LAPIC + timer IRQ delivery (R11.M1–M2)
- ⚠ paideia-as escalations required:
  - PA-R11-001: GS mem operand (e.g., `mov rax, [gs:offset]`)
  - PA-R11-002: xchg instruction (atomic swap)
  - PA-R11-003: cmpxchg+lock prefix (atomic compare-and-swap)
  - PA-R11-004: mfence instruction (memory fence)

**Target Boot Output:**
```
B
PaideiaOS R8
CAP OK
IPC OK
IDT OK
TASK A (CPU 0)
TASK B (CPU 1)
TASK A (CPU 0)
...
```

**Planned Issues (R12A.M1–R12A.M5):**

- **R12A.M1-001:** SIPI sequence design + AP boot stub
  - Start IPI to wake Application Processors (APs)
  - AP entry vector: 0x000_08000 (real-mode boot code)
  - Protected mode transition on AP (per-AP GDT/TSS)

- **R12A.M2-001:** Per-CPU data structures via IA32_GS_BASE MSR
  - Per-CPU current_tcb pointer stored in GS base
  - Per-CPU runqueue (16 priority levels per core)
  - Per-CPU interrupt stack

- **R12A.M3-001:** AP runqueue initialization
  - Each core gets independent runqueue (no load balancing yet)
  - Task distribution: Task A on CPU 0, Task B on CPU 1

- **R12A.M4-001:** Cross-CPU IPI for TLB shootdown
  - Rearm existing tlb_ipi infrastructure with multicore awareness
  - Per-CPU IPI ack counter

- **R12A.M5-001:** Multicore boot fixture + regression matrix
  - boot_r12_smp mode: Both CPUs boot, tasks distributed
  - Pre-push hook: boot_r8_only + boot_r10 + boot_r11 + boot_r12_smp

**Substrate Blockers:**
- paideia-as must support GS-relative mem operands (currently missing)
- paideia-as must support xchg, cmpxchg, mfence (partially supported)

---

### Path 2: Capability System (R12B) — Per-Kind Dispatch

**Preconditions:**
- ✓ Preemptive scheduling works (R11 complete)
- ✓ Capability scaffolding (R2.5, R5.5, R6.5, D7)
- ✓ paideia-as match-expression support (already in Phase 15 substrate)

**Target Boot Output:**
```
B
PaideiaOS R8
CAP OK
IPC OK
IDT OK
CAP_DISPATCH OK
TASK A
TASK B
...
```

**Planned Issues (R12B.M1–R12B.M5):**

- **R12B.M1-001:** Extend cap_invoke dispatcher for KIND_IPC_ENDPOINT
  - Per-operation dispatch: send, recv, poll, close
  - Real handler table lookup via kind+op indices
  - Audit: cap-dispatch-ipc-001.md

- **R12B.M2-001:** Extend cap_invoke dispatcher for KIND_MEMORY
  - Per-operation dispatch: alloc, map, unmap, query_perm
  - Integrated with buddy allocator + page-table walk
  - Audit: cap-dispatch-memory-001.md

- **R12B.M3-001:** Extend cap_invoke dispatcher for KIND_DEVICE
  - Per-operation dispatch: query_bar, request_mmio_mapping, request_io_port
  - Driver framework integration (D7 continuation)
  - Audit: cap-dispatch-device-001.md

- **R12B.M4-001:** Multi-kind capability fixture
  - Mint IPC + Memory capabilities
  - Invoke each with 3+ per-kind operations
  - Output: "CAP_DISPATCH OK\n"

- **R12B.M5-001:** Cap dispatch regression matrix
  - boot_r8_only + boot_r10 + boot_r11 + boot_r12_caps
  - All must pass (cap_dispatch fixture proves per-kind ops)

**Substrate Blockers:**
- None (match-expression + cap scaffolding already in place)

**Start Date:** Immediate (no external dependencies)

---

### Path 3: Memory Management (R12C) — MM API Activation

**Preconditions:**
- ✓ Preemptive scheduling works (R11 complete)
- ✓ Buddy allocator scaffolding (R5.5 implemented)
- ⚠ paideia-as partial mem-operand support (improving in Phase 15)

**Target Boot Output:**
```
B
PaideiaOS R8
CAP OK
IPC OK
IDT OK
MM API OK
TASK A
TASK B
...
```

**Planned Issues (R12C.M1–R12C.M5):**

- **R12C.M1-001:** Real aspace_map implementation
  - 4-level page-table walk (PML4→PDP→PD→PT)
  - PTE composition + INVLPG on update
  - Pre-allocated page tables (no recursive allocation yet)

- **R12C.M2-001:** Real aspace_unmap implementation
  - PTE invalidation + INVLPG
  - Per-CPU TLB shootdown via IPI (already scaffolded in R5.5)
  - Deferred to R12C.M4: concurrent task scheduling

- **R12C.M3-001:** Per-address-space allocation tracking
  - Metadata array (one per AS) tracking mapped regions
  - Query operations (aspace_query_perm, aspace_query_vrange)

- **R12C.M4-001:** Concurrent MM + scheduler integration
  - Task context switch with per-AS CR3 reload
  - Address-space TLB shootdown during preemption
  - Audit: mm-context-switch-001.md

- **R12C.M5-001:** MM API fixture + regression matrix
  - boot_mm mode: Allocate, map, touch memory from tasks
  - Tasks write/read shared page via MM API
  - Output: "MM API OK\n"

**Substrate Blockers:**
- paideia-as mem-operand support improving but not complete
- Pointer dereferencing ([ptr + offset]) partially working

---

## Recommendation & Decision Process

### Quick Evaluation

| Path | Blocker Status | Complexity | Impact | Start Date |
|------|---|---|---|---|
| **R12A (Multicore)** | Blocked on paideia-as PA-R11-* | High | Core infrastructure | After PA-R11 completed |
| **R12B (Cap Dispatch)** | Clear ✓ | Medium | Extensible caps | Immediate |
| **R12C (MM API)** | Partial blocker | High | Dynamic memory | After paideia-as mem-operand |

### Recommended Approach

**Option 1 (Conservative):** Start with **R12B (Cap Dispatch)** immediately (no blockers). Parallel prepare **R12A** by filing paideia-as escalations PA-R11-{1–4}. Punt **R12C** to R13 pending paideia-as mem-operand.

**Option 2 (Parallel):** Spike all three paths simultaneously:
- R12B starts immediately (no prep)
- R12A: File PA-R11 issues + architect GS-based per-CPU layout
- R12C: Verify paideia-as mem-operand capabilities + prototype aspace_map

**Recommendation:** **Option 1 (Conservative)** — Start R12B now, unblock R12A in parallel. This ensures forward progress while resolving substrate gaps.

---

## Deferred to R13+

- **Load balancing across CPUs** (R12A only, deferred to R13)
- **Recursive page-table allocation** (R12C only, deferred to R13)
- **Hot-plug CPU support** (R12A only, deferred to R14)
- **NUMA awareness** (R12A only, deferred to R14+)

---

## Testing & Verification

### R12B (Cap Dispatch) Test Plan

1. **boot_r12_caps mode:** Execute cap dispatch fixture
   - Mint KIND_IPC_ENDPOINT + KIND_MEMORY caps
   - Invoke each with 3+ per-kind operations
   - Assert "CAP_DISPATCH OK\n" in serial log

2. **Regression matrix:**
   - boot_r8_only ✓
   - boot_r10 ✓
   - boot_r11 ✓
   - boot_r12_caps ✓ (NEW)

### R12A (Multicore) Test Plan

1. **boot_r12_smp mode:** Execute multicore boot fixture
   - BSP bootstrap to Task A (CPU 0)
   - SIPI sends APs into Task B (CPU 1+)
   - Timer preemption alternates across CPUs

2. **Per-CPU isolation test:**
   - Task A writes to per-CPU data on CPU 0
   - Task B writes to per-CPU data on CPU 1
   - Verify no cross-CPU corruption

### R12C (MM API) Test Plan

1. **boot_r12_mm mode:** Execute MM API fixture
   - Allocate 4KiB page via phys_alloc
   - Map to task address space via aspace_map
   - Task writes + reads value (e.g., 0xDEADBEEF)
   - Assert value matches (MM + tasks work together)

---

## Architecture Decision Dependency

The chosen R12 path will influence R13+ planning:

- **If R12A:** R13 focuses on load balancing + scheduler preemption optimization
- **If R12B:** R13 focuses on driver framework completion (D7 continuation)
- **If R12C:** R13 focuses on demand paging + fault handling

---

## Key Unknowns

1. **paideia-as PA-R11 timeline:** When will GS mem operand, xchg, cmpxchg, mfence land?
2. **Preemption observability:** Can QEMU TCG detect actual preemption boundaries, or is timing deterministic?
3. **Driver timeline:** When should D7 (driver framework) complete relative to cap dispatch (R12B)?

---

## Audit Trail Placeholder

**Pending R12 path decision:**
- r12a-m1-sipi-sequence.md (if multicore chosen)
- r12b-m1-cap-dispatch-ipc.md (if cap dispatch chosen)
- r12c-m1-aspace-map-real.md (if MM API chosen)

---

## Status

**R12 planning ready. Awaiting R11 completion + paideia-as PA-R11 status check for path selection.**

---

**Milestone:** R12 Kickoff  
**Related Issues:** TBD (depends on chosen path)  
**Author:** Santiago Nunez-Corrales  
**Date:** 2026-07-02
