# PaideiaOS R10 Kickoff: Scheduler Integration & Capability Dispatch

**Status:** PLANNED  
**Expected Milestones:** B13–B15 (R10.M1–R10.M3)  
**Target Date:** Post-R9 closure  

---

## Overview

**R10** integrates the scheduler stubs from R9 into a fully preemptive multitasking kernel and completes the capability system with per-kind operation dispatch.

**Target Boot Output (R10 final):**
```
B
PaideiaOS R8
CAP OK
IPC OK
IDT OK
TICK
...
SCHED OK
```

---

## Planned Issues (B13–B15)

### B13: Real Scheduler Integration

- **B13-001:** Callee-saved register save/restore in context switch (push/pop prologue/epilogue)
- **B13-002:** Real runqueue enqueue/dequeue/pick_next operations (bitmap priority scan)
- **B13-003:** TCB array population with initial two tasks (Task A + Task B)
- **B13-004:** Budget decrement + preemption trigger in timer handler
- **B13-005:** E2E two-task preemption fixture + closure

### B14: Per-Kind Capability Dispatch

- **B14-001:** cap_invoke dispatcher expansion (per-kind + per-operation handlers)
- **B14-002:** Capability operations for KIND_IPC_ENDPOINT (send, recv, poll)
- **B14-003:** Capability operations for KIND_MEMORY (alloc, map, unmap)
- **B14-004:** E2E multi-kind cap_invoke fixture + closure

### B15: Round Closure

- **B15-001:** Combined smoke matrix (includes SCHED OK + CAP dispatch output)
- **B15-002:** R10 milestone document (summarizing B13–B15)
- **B15-003:** Round closure + R11 kickoff

---

## Key Design Points (Placeholder)

- **Context switch:** Rax/Rbx hold current TCB; save/restore via unsafe blocks (gated on paideia-as mem-operand encoders)
- **Preemption:** Timer handler decrements budget; calls sched_tick + sched_switch on zero
- **Runqueue discipline:** 16-level priority bitmap + FIFO per-level (existing data structure from R4.5)
- **Capability dispatch:** Match on kind + operation; invoke handler (per-kind subsystem calls)

---

## Dependencies & Current Status

**Blockers from R9:**
- Actual LAPIC timer interrupt delivery (QEMU PVH limitation — may use PIT or periodic mode as workaround)
- Register save/restore in context switch (paideia-as mem-operand encoders in development)

**Ready to proceed:**
- TCB layout + runqueue arrays (R9.M3-001)
- Budget decrement logic (R9 scheduler stubs)
- Capability dispatch skeleton (R2.5-006, R5.5 implementations)

---

## Testing Strategy

- **Fixture 1:** Two-task time-slice alternation (timer-driven context switch)
  - Task A: loop counter, yield on budget expiry
  - Task B: loop counter, yield on budget expiry
  - Repeat until both tasks have executed K cycles
  - Output: "SCHED OK\n" on completion

- **Fixture 2:** Multi-kind capability operations (read/write to IPC + memory)
  - Mint 2 capabilities (KIND_IPC_ENDPOINT + KIND_MEMORY)
  - Invoke each with multiple operations
  - Output: "CAP DISPATCH OK\n" on completion

- **Fingerprint harness:** R10 boot output matches `tests/r10/expected-boot-sched.txt`

---

## Next Phase: R11 (Memory Management Reactivation)

Placeholder stub for future planning. R11 will reactivate:
- Buddy allocator activation in context of R10 preemptive kernel
- Page-table walk with real TLB shootdown IPI
- Address-space create/map/unmap with concurrent context switches

---

## Status

**R10 planning ready.** Awaiting R9 completion + paideia-as mem-operand encoder stability for implementation start.

---

**Milestone:** R10 Kickoff  
**Related Issues:** TBD  
**Author:** Santiago Nunez-Corrales  
**Date:** 2026-06-24
