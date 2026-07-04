---
audit_id: r15-m2-006-first-user-ret-target
issue: 527
file: src/kernel/core/syscall/enter_user.pdx
function: enter_userland_initial
effects: [mem, sysreg]
capabilities: [boot]
reviewed_by:
date: 2026-07-04
---

# AUDIT r15-m2-006-first-user-ret-target — Ring-3 iretq mechanism (R15.M2-006)

## Scope

Audit that the ring-3 iretq mechanism is complete for minimal user _start execution.
Runtime demonstration deferred to followup once handle_ud/#GP marker emit lands (#650)
and/or syscall dispatch (R15.M4) is implemented.

## Substrate Cross-References

- **#522** — USER_CS/USER_SS constants (ring-3 code/stack segment selectors)
- **#524** — iretq_frame_build helper (stack frame construction for ring-3 transition)
- **#525** — TSS.rsp0 preload verified (kernel stack pointer for privilege boundary crossing)
- **#526** — enter_userland_initial primitive (entry point from kernel to ring-3)
- **#644** — IDT vec 0/3/6/8/13/14/33 wired (exception handlers; real #GP handler will fire on ring-3 privileged instructions)

## What "First User _start" Would Look Like

A minimal ring-3 code page containing simply `hlt` (0xF4, 1 byte).
Ring-3 hlt is a privileged instruction → triggers #GP → handle_gp fires.
Once handle_gp prints "#GP\n" marker (#650), boot_r15_ring3_hello witnesses ring-3 execution via handle_gp reception.

## Alternative Witness Path

User _start could invoke `syscall` (which lands at syscall_entry per R15.M4).
But R15.M4 isn't landed; sys_debug_puts does not exist.
This path is deferred.

## Runtime Demonstration Status

Filed as **#652**: "boot_r15_ring3_hello smoke — user _start = hlt, expect #GP marker in serial".
All substrate for ring-3 execution is in place.
Runtime demo blocked on marker-emit followups.

## Verification

Structural witness: All upstream dependencies (iretq_frame_build, TSS.rsp0, IDT wiring, USER_CS/SS) are implemented.
The enter_userland_initial primitive can be called with a ring-3 code pointer; iretq will transition to ring-3.
Any ring-3 privileged op (hlt, lgdt, ltr, etc.) will trigger #GP, firing handle_gp.
