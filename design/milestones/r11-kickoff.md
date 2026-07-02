# PaideiaOS R11 Kickoff: Real Timer IRQ & Preemptive Scheduling

**Status:** PLANNED  
**Expected Milestones:** R11.M1–R11.M4  
**Target Date:** Post-R10 closure  

---

## Overview

**R11** activates real timer interrupt delivery (replacing QEMU TCG polling workaround) and implements preemptive multitasking via budget-based thread preemption.

**Target Boot Output (R11 final):**
```
B
PaideiaOS R8
CAP OK
IPC OK
IDT OK
TASK A
TASK B
...
(alternation driven by timer preemption, not voluntary yields)
```

---

## Planned Issues (R11.M1–R11.M4)

### R11.M1: Real Timer IRQ Delivery

- **R11.M1-001:** Evaluate timer delivery options (KVM vs. PIT vs. periodic LAPIC)
- **R11.M1-002:** Implement timer delivery via chosen method (e.g., PIT for TCG compatibility)
- **R11.M1-003:** Verify timer IRQs fire reliably with boot_tick fingerprint mode
- **R11.M1-004:** Update pre-push hook to include boot_tick regression (now expected to pass)

**Audit entries:** r11-m1-timer-delivery.md (design decision + implementation)

### R11.M2: Preemptive Scheduling

- **R11.M2-001:** Implement budget tracking per TCB (per-thread time quantum)
- **R11.M2-002:** Update timer IRQ handler to decrement budget + trigger sched_tick on zero
- **R11.M2-003:** Real sched_switch_regs call from handle_timer (preemption vector)
- **R11.M2-004:** E2E preemptive multitasking fixture (Task A/B preempted by timer)

**Audit entries:** r11-m2-preemption.md (budget tracking + IRQ integration)

### R11.M3: Per-Kind Capability Dispatch

- **R11.M3-001:** Extend cap_invoke dispatcher for KIND_IPC_ENDPOINT operations (send, recv, poll)
- **R11.M3-002:** Extend cap_invoke dispatcher for KIND_MEMORY operations (alloc, map, unmap)
- **R11.M3-003:** E2E multi-kind capability fixture (mixed IPC + memory operations)
- **R11.M3-004:** Update boot fingerprint to include "CAP DISPATCH OK\n" marker

**Audit entries:** r11-m3-cap-dispatch.md (per-kind operation routing)

### R11.M4: Multicore Bootstrap

- **R11.M4-001:** Implement SIPI (Startup IPI) to wake Application Processors (APs)
- **R11.M4-002:** AP boot stub and long-mode entry (per-AP GDT + TSS)
- **R11.M4-003:** Per-CPU runqueue initialization (one runqueue per core)
- **R11.M4-004:** E2E multicore fixture (boot on dual-core QEMU, verify both cores scheduling tasks)

**Audit entries:** r11-m4-multicore.md (SIPI sequence + per-CPU data structures)

### R11.M5: Round Closure

- **R11.M5-001:** Combined smoke matrix (boot_r8_only, boot_tick, boot_r10 all pass)
- **R11.M5-002:** R11 milestone document (summarizing R11.M1–R11.M5)
- **R11.M5-003:** Round closure + R12 kickoff (MM API activation)

---

## Key Design Points (Placeholder)

### Timer IRQ Delivery

**Options:**
1. **KVM mode:** Real LAPIC timer (full fidelity, requires `qemu -enable-kvm`)
2. **PIT (Programmable Interval Timer):** Port-based timer (TCG compatible, real I/O)
3. **Periodic LAPIC:** Fallback if TSC-DEADLINE unreliable (simpler than PIT)

**Decision:** TBD based on QEMU compatibility testing. Likely PIT for TCG + KVM for production.

### Preemption

- **Budget model:** Per-task time quantum (default 1ms, tunable via MSR or memory)
- **Timer vector:** Vector 32 (LAPIC timer) decrement budget per tick
- **Preemption trigger:** Budget exhaustion → handle_timer calls sched_tick
- **Context switch:** sched_tick returns next task; handle_timer iret to next task's RIP/RSP

### Multicore (R11.M4)

- **SIPI sequence:** BSP sends Startup IPI to APs
- **AP boot stub:** Entry at 0x000_08000 (AP startup vector), trampoline to protected mode
- **Per-CPU state:** TSS, stack, runqueue, current_tcb via GS base register (SWAPGS)
- **Load balancing:** Deferred to R12+ (initially each core runs independently)

---

## Dependencies & Current Status

**Blockers from R10:**
- boot_tick mode regression (intentional; timer diagnostics replaced by task output)
- Multicore bootstrap requires per-CPU GS/TSS setup (not in R10)

**Ready to proceed:**
- ISR trampolines + trap frame passing (R10.M1–M2)
- Cooperative scheduler (R10.M3–M5)
- Capability system scaffolding (R2.5, R5.5)

---

## Testing Strategy

### R11.M1 (Timer Delivery)

- **Fixture 1:** boot_tick mode regression restoration
  - Verify "TICK\n" lines appear in serial log (real timer, not polling)
  - Compare timing: R9 (polling) vs. R11 (real IRQ) to measure jitter reduction

### R11.M2 (Preemption)

- **Fixture 2:** Preemptive task alternation
  - Task A: loop counter, no explicit yields
  - Task B: loop counter, no explicit yields
  - Timer fires every 1ms, preempts running task
  - Output: "PREEMPT OK\n" + alternation pattern demonstrating budget exhaustion

### R11.M3 (Cap Dispatch)

- **Fixture 3:** Multi-kind capability operations
  - Mint IPC + Memory capabilities
  - Invoke each with 3+ operations
  - Output: "CAP DISPATCH OK\n"

### R11.M4 (Multicore)

- **Fixture 4:** Dual-core task distribution
  - BSP bootstrap (CPU 0) into Task A
  - AP startup (CPU 1) into Task B
  - Alternate timer preemption across cores
  - Output: "MULTICORE OK\n"

### Fingerprint Harness

- **boot_r8_only:** R8 baseline (unchanged from R10)
- **boot_tick:** R9 timer diagnostic (restored in R11.M1, now real IRQ)
- **boot_r10:** R10 cooperative alternation (still valid, now driven by preemption timer)
- **boot_r11:** NEW multicore output (R11.M4 only)

---

## Known Risks & Mitigation

### Risk: Timer delivery unreliability in TCG

**Mitigation:** Implement PIT as fallback (port-based, fully TCG compatible). Start with PIT in R11.M1, optionally optimize to LAPIC later.

### Risk: Preemption introducing race conditions

**Mitigation:** Ensure all shared state (runqueue, budget) accessed via atomic operations or interrupt masking. Audit per-TCB state isolation.

### Risk: Multicore GS register confusion

**Mitigation:** Implement per-CPU GS base via IA32_GS_BASE MSR. Audit GS-relative addressing in sched_switch_regs (requires per-CPU current_tcb).

---

## Next Phase: R12 (Memory Management Reactivation)

Placeholder for future planning. R12 will reactivate:
- Buddy allocator with preemption-safe spinlocks
- Address-space map/unmap with TLB IPI shootdown
- Page-table walk with concurrent task scheduling
- MM API capabilitiesM1–M4 (KIND_MEMORY operations)

---

## Status

**R11 planning ready.** Awaiting R10 completion + timer delivery testing for implementation start.

---

**Milestone:** R11 Kickoff  
**Related Issues:** #387–#390 (TBD)  
**Author:** Santiago Nunez-Corrales  
**Date:** 2026-07-02
