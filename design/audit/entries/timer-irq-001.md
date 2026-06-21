# Audit Entry: Timer Interrupt Handler [unsafe]

**Issue:** #110  
**File:** `src/kernel/core/sched/timer_irq.pdx`  
**Date:** 2026-06-21  
**Reviewer:** Claude Code  

## Unsafe Operations

### Interrupt Handler Context

The timer IRQ handler runs with interrupts disabled, at a specific privilege level (ring 0 only). It must not block, hold locks for long, or trigger general protection faults.

**Risk:** If handler blocks, CPU deadlocks.

**Mitigation:**
- Handler must not call blocking functions
- Handler must not acquire locks held by interrupted code
- Handler must complete in < 1 microsecond
- Use lock-free data structures for scheduler state

### Scheduler State Manipulation

The timer handler directly modifies scheduler state (budget, queues, preemption flags) while other CPUs might also modify it.

**Risk:** Race conditions if not serialized properly.

**Mitigation:**
- Use atomic operations for shared counters
- Per-CPU data (current_tcb, per-CPU queue) is safe from multicore races
- Global scheduler state (e.g., thread birth/death) uses locks
- Budget updates use per-thread atomics

### Context Switch from IRQ

If preemption is triggered, the timer handler might indirectly cause a context switch (when returning from IRQ).

**Risk:** Restoring incorrect register state or switching to invalid thread.

**Mitigation:**
- Set preemption flag, don't switch directly
- Actual context switch deferred to IRQ exit
- Verify next thread is valid before switch
- Preserve interrupted thread's state correctly

### Nested Interrupts

While timer handler runs, other higher-priority interrupts might fire.

**Risk:** Timer handler interrupted, causing reentrancy issues.

**Mitigation:**
- Set interrupt priority level (IPL) during timer handler
- Use APIC interrupt masking to prevent reentrancy
- Ensure timer handler is reentrant or protected by disable

### Accurate Timing

The handler must measure elapsed time and update budgets accurately.

**Risk:** Inaccurate measurement causes budget over/under accounting.

**Mitigation:**
- Use TSC or high-resolution timer counter
- Sample TSC at IRQ entry and exit
- Account for IRQ latency in budget calculations
- Calibrate timer frequency against wall-clock

## Invariants

1. **Atomicity:** Timer handler runs atomically with respect to user code
2. **Progress:** Handler completes in finite time (no deadlock)
3. **Correctness:** Budget accounting matches actual elapsed time
4. **Safety:** No invalid memory access or privilege escalation

## Testing Strategy

- Unit test: trigger timer interrupt, verify budget updated
- Latency test: measure time from deadline to handler execution
- Accuracy test: verify budget accounting over many interrupts
- Stress test: high interrupt rate → verify no deadlock
- Corruption test: intentionally corrupt scheduler state → verify recovery
