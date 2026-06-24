# timer-isr-001: Vector-32 Timer ISR Orchestration

**Issue:** #359 (R9-m2-004)

**Module:** `src/kernel/core/int/exceptions.pdx::Exceptions`

**Functions:**
- `pub let mut _tick_count : u64 = 0` (global state)
- `pub handle_timer() -> () !{sysreg, mem} @{boot}` (ISR body)

## Summary

Implements the interrupt handler for vector 32 (timer). Each invocation increments the global `_tick_count`, rearms the timer for the next deadline, signals EOI to the LAPIC, and returns.

## Implementation

| Aspect | Detail |
|--------|--------|
| **Vector** | 32 (programmed in LVT Timer @ 0xFEE00320) |
| **Entry point** | `handle_timer()` (called by ISR trampoline via IDT) |
| **Global state** | `_tick_count: u64` (incremented once per fire) |
| **Rearm interval** | 1,000,000 TSC cycles (tunable; ~1ms @ ~1 GHz) |
| **Real body** | Load _tick_count, increment, store; call lapic_timer_rearm(1000000); call apic_eoi; ret |

## Procedure

1. **Increment tick counter:** Load _tick_count, add 1, store back.
2. **Rearm timer:** Call `LapicTimer::lapic_timer_rearm(1000000)` to set next deadline.
3. **Signal EOI:** Call `Eoi::apic_eoi()` to acknowledge to LAPIC.
4. **Return:** iretq (executed by ISR trampoline after handle_timer returns).

## Justification

**Tick counter:** Provides a simple observable of timer fire count. Applications can poll `_tick_count` to detect timer activity (or later set up periodic work queues).

**Rearm:** TSC-deadline timers are one-shot; rearm must happen in the ISR to fire again.

**EOI before return:** LAPIC EOI must be signaled before the ISR completes, per Intel SDM Vol 3A §10.8.5. Placing it before the final `ret` ensures this.

**paideia-as support:** Cross-module calls to LapicTimer and Eoi modules (v0.6.0+).

## Cross-module references

**Calls:**
- `LapicTimer::lapic_timer_rearm(interval: u64)` → sets IA32_TSC_DEADLINE MSR
- `Eoi::apic_eoi()` → writes LAPIC EOI register

**Called by:**
- ISR trampoline `Idt::trampoline_vec32` (via IDT entry after push/pop sequence)

## Bootflow integration

Timer fires only after:
1. `ApicEnable::apic_enable()` confirms LAPIC is enabled.
2. `LapicTimer::lapic_timer_init()` configures LVT Timer for TSC-deadline + vector 32.
3. `sti` instruction enables maskable interrupts.

(See `kernel_main_64` in boot/kernel_main.pdx.)

## Phase 6 integration

- Replaces the R9-m1-004 stub that printed "EXC32 timer" and halted.
- Completes the timer subsystem: enable → init → fire → rearm → EOI.
- Provides foundation for Phase 7+ scheduler integration.

---
**Audit:** R9-m2-004 bundle (June 2026)
