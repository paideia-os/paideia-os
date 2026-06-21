# Audit Entry: Per-CPU Current TCB via GS-Base [unsafe]

**Issue:** #86  
**File:** `src/kernel/core/sched/gs_current.pdx`  
**Date:** 2026-06-21  
**Reviewer:** Claude Code  

## Unsafe Operations

### Direct MSR Access (IA32_KERNEL_GS_BASE / IA32_GS_BASE)

Reading and writing MSR 0xC0000102 (IA32_KERNEL_GS_BASE) and 0xC0000101 (IA32_GS_BASE) modifies CPU state that affects all memory accesses using the GS segment.

**Risk:** Incorrect GS-base value causes:
- Threads to access wrong per-CPU data
- Kernel to read wrong current_tcb pointer
- Cross-CPU data corruption (thread A reads data meant for CPU B)

**Mitigation:**
- GS-base must be set only during context switch or CPU initialization
- Each CPU must have distinct per-CPU data region allocated
- GS-base write must use WRMSR with proper serialization (MFENCE or LFENCE)
- MSR value must be validated before write

### GS:[0] Memory Access

Direct memory read/write via `GS:[offset]` accesses the per-CPU data structure at the address stored in GS-base.

**Risk:** If GS-base is corrupted, `GS:[0]` read/write accesses arbitrary kernel memory.

**Mitigation:**
- GS-base must be initialized before any GS-based access
- GS-base must point to a valid, allocated per-CPU region
- All GS-based accesses must be serialized with GS-base writes
- No user code can trigger GS-base modification

### Per-CPU Data Isolation

Multiple CPUs have separate per-CPU data regions, each pointed to by their own GS-base.

**Risk:** Race condition if CPU 0 reads/modifies CPU 1's per-CPU data.

**Mitigation:**
- Each per-CPU region must be allocated at distinct physical addresses
- GS-base setup must be per-CPU (only at CPU initialization or context switch)
- No shared writes between per-CPU regions
- Synchronization between CPUs must use inter-CPU interrupts or lock-free structures

## Invariants

1. **GS-Base Coherency:** Each CPU's GS-base points to its own per-CPU data region
2. **current_tcb Validity:** `GS:[PERCPU_CURRENT_TCB_OFFSET]` always contains valid TCB pointer or NULL
3. **Atomicity:** Read of `GS:[PERCPU_CURRENT_TCB_OFFSET]` is atomic (single memory op)
4. **Isolation:** CPU 0's GS-base changes do not affect CPU 1's memory accesses

## Testing Strategy

- Unit test: write GS-base, read GS:[0] → verify value matches
- Multicore test: two CPUs with different GS-base values → verify each reads correct per-CPU data
- Corruption test: intentionally corrupt GS-base → verify error detection/recovery
