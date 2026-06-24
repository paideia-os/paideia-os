# PaideiaOS R9 Kickoff: Interrupt & Timer Reactivation (Stub Plan)

## Overview

**R9** reactivates interrupt handling and preemptive scheduling on top of the R8 bootstrap foundation. This phase builds the CPU exception and timer infrastructure required for multi-threaded workloads.

**Target Boot Output (R9 final):**
```
B
PaideiaOS R8
CAP OK
IPC OK
SCHED OK
```

---

## Planned Issues (B8–B10)

### B8: Interrupt Descriptor Table (IDT) & Exception Handling

- **B8-001:** IDT installation (256 entries, real word0/word1 packing)
- **B8-002:** ISR trampolines (8 hand-written entry points: vectors 0, 3, 6, 8, 13, 14, 32, 33)
- **B8-003:** Exception handlers (trace + halt for divide-by-zero, breakpoint, NMI, double-fault, GPF, page-fault)
- **B8-004:** CR2 preservation in page-fault path
- **B8-005:** E2E exception fixture + closure

### B9: LAPIC Timer & Preemption

- **B9-001:** LAPIC TSC-deadline mode initialization (LVT, deadline composition)
- **B9-002:** Timer ISR body (sched_tick call, re-arm, EOI)
- **B9-003:** Timer tick rate calibration (1-second or 10-millisecond budget)
- **B9-004:** Preemption trigger (budget decrement + context switch path)
- **B9-005:** E2E preemptive two-TCB fixture + closure

### B10: Round Closure

- **B10-001:** Combined smoke matrix (B + PaideiaOS R8 + CAP OK + IPC OK + SCHED OK)
- **B10-002:** R9 milestone document (summarizing B8–B10)
- **B10-003:** Scheduler state snapshot (TCB layout audit, per-CPU runqueue)
- **B10-004:** Round closure + R10 kickoff

---

## Key Design Points (Placeholder)

- **IDT location:** Kernel .bss at known PHYSICAL address (identity-mapped)
- **ISR trampoline pattern:** RSP setup → GP regs save → call handler → restore → iretq
- **LAPIC access:** MSR writes for TSC-deadline mode (x2APIC architecture)
- **Context switch:** Sched_pick_next → sched_switch unsafe block (rax/rbx context)
- **Cooperative preemption:** Budget countdown triggers sched_yield; scheduler picks next runnable

---

## Dependencies & Blockers

- Paideia-as encoders: mem-operand, iretq, privileged-register mov
- Status: Gated on paideia-as Phase 8+ (v0.7.0+)
- Currently blocked: cannot emit IDT install loop or context-switch prologue/epilogue

---

## Testing Strategy

- **Fixture 1:** Two-TCB alternation test (ipc_alternate_e2e.pdx)
  - Task A: enqueue 0xAAAA, yield
  - Task B: dequeue 0xAAAA, verify, yield
  - Repeat 5 cycles
  - Output: "SCHED OK\n" on completion

- **Fingerprint harness:** R9 boot output matches `tests/r8/expected-boot-sched.txt`

---

## Next Phase: R10 (Memory Management Reactivation)

Placeholder stub for future planning. R10 will reactivate:
- Buddy allocator (11 orders: 4 KiB – 4 MiB)
- Page-table walk (4-level paging, EPT compatibility)
- Address-space create/map/unmap with TLB shootdown

---

## Status

**R9 planning complete.** Awaiting paideia-as v0.7.0+ encoders for implementation start.
