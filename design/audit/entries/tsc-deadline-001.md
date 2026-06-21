# Audit Entry: TSC-Deadline Timer [unsafe]

**Issue:** #109  
**File:** `src/kernel/core/sched/tsc_deadline.pdx`  
**Date:** 2026-06-21  
**Reviewer:** Claude Code  

## Unsafe Operations

### Direct MSR Access (IA32_TSC_DEADLINE)

Writing IA32_TSC_DEADLINE (MSR 0x6E0) arms a per-CPU timer that fires when TSC >= deadline value. Only ring-0 can write this MSR.

**Risk:** Incorrect deadline causes:
- Timer fires too early (false preemption)
- Timer fires too late (budget violation)
- Timer never fires (starvation)
- Cross-CPU interference if MSR is shared

**Mitigation:**
- Deadline value must be in future (> current TSC)
- Deadline must be validated before write
- MSR is per-CPU (safe from cross-CPU interference)
- Must check CPU supports TSC-deadline before use

### TSC Clock Skew (Multicore)

TSC values can differ across cores, especially on NUMA systems or with power management enabled.

**Risk:** Comparing TSC across cores leads to timing inconsistencies.

**Mitigation:**
- Each CPU uses its own local TSC
- Deadlines are always local to CPU that armed timer
- Do not compare TSC values across CPUs
- Synchronize using wall-clock or HPET if cross-CPU timing needed

### Timer Interrupt Race

Deadline is set, but interrupt handler might not run immediately if interrupts are disabled.

**Risk:** Interrupt fires but is delayed, causing missed deadline.

**Mitigation:**
- Check for deadline expiration after enabling interrupts
- Use compare-and-swap to atomically check deadline
- Timer interrupt handler must not trigger context switch while holding locks

### Overflow and Deadline Validation

TSC wraps around every ~584 years on modern CPUs, but edge cases need handling.

**Risk:** Very large deadline values might overflow or be misinterpreted.

**Mitigation:**
- Validate deadline > current TSC (future deadline)
- Validate deadline < current TSC + 2^63 (within reasonable range)
- Handle wraparound case (TSC + offset wraps to 0)
- Document assumption about TSC frequency

## Invariants

1. **Deadline Ordering:** `current_tsc < deadline < current_tsc + 2^63`
2. **Per-CPU Isolation:** Each CPU has independent TSC-deadline timer
3. **Atomicity:** Setting deadline must be atomic (single WRMSR)
4. **Monotonicity:** Deadline increases (or resets to 0) over time

## Testing Strategy

- Unit test: set deadline, wait, verify interrupt fires at deadline
- Accuracy test: measure actual delay vs. programmed delay (should be < 1 ms)
- Race test: set deadline with interrupts disabled, enable interrupts → verify fires
- Overflow test: set deadline near wraparound → verify correct behavior
- Multicore test: set different deadlines on different CPUs → verify isolation
