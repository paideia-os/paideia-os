---
audit_id: r10-m3-002-yield
issue: 378
file: src/kernel/core/sched/yield.pdx
function: sched_yield
effects: [mem]
capabilities: [sched]
reviewed_by:
date: 2026-07-02
status: complete
---

# AUDIT R10-m3-002 — Cooperative yield with schedule-next dispatch (COMPLETE)

## Issue

R10-m3-002 (#378): Implement the real body of sched_yield() -> u64 to voluntarily release the CPU by selecting the next highest-priority runnable task and switching to it via sched_switch_regs.

## Implementation

Cooperative yield with priority-based task selection:

```pdx
pub let sched_yield : () -> u64 !{mem} @{sched} = fn () -> unsafe {
  effects: { mem },
  capabilities: { sched },
  justification: "R10 m3-002: cooperative yield. Pick next runnable TCB via sched_pick_next, then switch to it via sched_switch_regs if different from current. MVP: CPU 0 only.",
  block: {
    // 1. Call pick_next(cpu=0) -> next TCB in RAX
    mov rdi, 0                   ; RDI = cpu=0 (arg to sched_pick_next)
    call PickNext.sched_pick_next
    ; RAX = next_tcb

    // 2. Get current TCB from Runqueue._current_tcb global
    lea rcx, [rip + Runqueue._current_tcb]
    mov rcx, [rcx]               ; RCX = current_tcb

    // 3. Check if next == current
    cmp rcx, rax                 ; compare current vs next
    je _yield_noop

    // 4. Switch: sched_switch_regs(current, next)
    mov rdi, rcx                 ; RDI = current_tcb (arg0 to sched_switch_regs)
    mov rsi, rax                 ; RSI = next_tcb (arg1)
    call sched_switch_regs
    mov rax, YIELD_OK
    ret

  _yield_noop:
    mov rax, YIELD_NOOP
    ret
  }
}
```

## Semantics

1. Call sched_pick_next(cpu=0) to find the highest-priority runnable task
   - Returns head TCB of the first non-empty priority level (RAX)
   - Falls back to idle_tcb if all levels empty
2. Fetch current running TCB from the shared global Runqueue._current_tcb
3. Compare: if next == current, no runnable alternative exists
   - Return YIELD_NOOP (no-op, stay running)
4. If next != current:
   - Call sched_switch_regs(current, next) for context switch
   - Update Runqueue._current_tcb via sched_switch_regs (indirect)
   - Return YIELD_OK

## MVP Scope

- CPU 0 only (hardcoded in call to sched_pick_next)
- Assumes Runqueue.level_heads array is populated by boot/scheduling setup
- sched_pick_next scans priorities 0..15 for first non-empty level (linear scan; BSR instruction optimization pending paideia-as encoder)

## Return Values

- YIELD_OK (0): switch performed (next TCB != current)
- YIELD_NOOP (1): no alternative runnable (next TCB == current, stay running)

## Cross-Module Dependencies

- PickNext.sched_pick_next(cpu: u64) -> u64 (next TCB base address)
- sched_switch_regs (this module's unsafe block for context switch)
- Runqueue._current_tcb (shared global, updated by sched_switch)

## Verification

- Symbols present in kernel.elf: sched_yield
- Boot path functional: boot_r8_only 3/3 passes (no functional change to boot yet; wiring to interrupt handler deferred to m5)
- Cross-module reference resolution verified

## References

- R10-m3-001 sched_switch_regs implementation
- src/kernel/core/sched/pick_next.pdx
- src/kernel/core/sched/runqueue.pdx (_current_tcb tracking)
