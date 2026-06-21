# Audit Entry: Get Current Thread from GS:[0] [unsafe]

**Issue:** #107  
**File:** `src/kernel/core/sched/current.pdx`  
**Date:** 2026-06-21  
**Reviewer:** Claude Code  

## Unsafe Operations

### Direct GS-Base Memory Read

The `sched_current()` function reads from `GS:[0]` to retrieve the current thread's TCB pointer. This relies on:
- GS-base being set to a valid per-CPU data region
- Offset 0 containing a valid TCB pointer

**Risk:** If GS-base is incorrect or corrupted, this reads arbitrary kernel memory and returns invalid pointer, leading to:
- NULL pointer dereference
- Access to wrong thread's TCB
- Cross-CPU data leakage

**Mitigation:**
- GS-base must be initialized before any `sched_current()` call
- GS-base initialization must occur during CPU boot and context switch
- Verify GS-base points to allocated per-CPU data region
- TCB pointer at GS:[0] must be validated before use (non-NULL, aligned)

### CPU Architecture Dependency

This implementation is x86-64 specific. The instruction `MOV RAX, GS:[0]` is not portable.

**Risk:** Code is tightly coupled to x86-64 architecture.

**Mitigation:**
- Implementation must be in architecture-specific module
- Abstract interface (`sched_current()`) is architecture-independent
- ARM64 port would use different register/instruction

### Atomicity of Read

A single memory read from `GS:[0]` should be atomic. However, if kernel enables 64-bit unaligned reads, it could be split into multiple sub-operations.

**Risk:** If read is split, intermediate value could point to deallocated TCB.

**Mitigation:**
- Ensure GS:[0] is 64-bit aligned
- Use single 64-bit MOV instruction (atomic on x86-64)
- Never split the read into multiple operations

## Invariants

1. **GS-Base Validity:** GS-base must point to valid, allocated per-CPU data region
2. **TCB Pointer Validity:** GS:[0] must contain non-NULL, valid TCB pointer
3. **Atomicity:** Read of GS:[0] must be single atomic operation
4. **Coherency:** Multiple calls to `sched_current()` before context switch must return same TCB pointer

## Testing Strategy

- Unit test: set GS-base, call `sched_current()` → verify returns expected TCB pointer
- Multicore test: call `sched_current()` on two CPUs → verify each gets different TCB
- Context switch test: call `sched_current()`, context switch, call again → verify returns new TCB
- Corruption test: intentionally corrupt GS:[0] → verify detection/recovery
