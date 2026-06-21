# Audit Entry: Idle Thread (HLT-only) [unsafe]

**Issue:** #108  
**File:** `src/kernel/core/sched/idle.pdx`  
**Date:** 2026-06-21  
**Reviewer:** Claude Code  

## Unsafe Operations

### HLT Instruction

The HLT instruction halts the CPU. It can only be executed in kernel mode (ring 0). If HLT is executed in user mode, it triggers a general protection fault (#GP).

**Risk:** If idle loop is entered in user mode (e.g., due to privilege escalation bug), HLT causes crash.

**Mitigation:**
- Idle thread must execute in kernel mode only
- Verify privilege level (CPL) before HLT
- Make idle thread non-switchable to user mode
- Add runtime checks in privileged instruction handler

### Interrupt Handler Interleaving

While CPU is halted (HLT), interrupts will wake it. However, the interrupt handler runs before idle loop resumes.

**Risk:** If interrupt modifies scheduler state (enqueue new thread), the halted CPU may miss the change.

**Mitigation:**
- Interrupt handler must set a flag or IPI to wake CPU
- Before HLT, re-check that no new threads became runnable
- Use atomic checks between queue inspection and HLT

### Race Condition: Check-then-HLT

A new thread might become runnable between the "check for runnable threads" and "HLT" operations.

**Risk:** CPU halts even though threads are ready, causing starvation.

**Mitigation:**
- Disable interrupts before checking queue
- Enable interrupts only after HLT (atomically combined)
- Use STI (Set Interrupt Flag) immediately before HLT
- Ensure no memory stores between queue check and HLT

### Multicore Idle Synchronization

Multiple CPUs can enter idle state. Care must be taken when waking idle CPUs (e.g., load balancing, IPI).

**Risk:** Idle CPU doesn't receive wake-up IPI, stalls indefinitely.

**Mitigation:**
- IPI (Inter-Processor Interrupt) must reliably wake idle CPU
- Idle state must be recorded in per-CPU data
- Load balancer must check per-CPU idle state before queuing work

## Invariants

1. **Privilege Level:** Idle thread executes only in kernel mode (CPL=0)
2. **Interrupt Enabled:** Interrupts must be enabled before HLT
3. **No Runnable Threads:** HLT only when scheduler confirms no runnable threads
4. **Atomicity:** Check-and-HLT must be atomic with respect to interrupt handlers

## Testing Strategy

- Unit test: enter idle, trigger interrupt → verify CPU wakes
- Stress test: idle loop under high load → verify no starvation
- Race test: enqueue thread, trigger interrupt → verify thread runs
- Multicore test: idle on multiple CPUs, send IPI → verify wake-up
