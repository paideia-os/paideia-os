# Audit Entry: Context Switch [unsafe]

**Issue:** #85, #95  
**File:** `src/kernel/core/sched/switch.pdx`  
**Date:** 2026-06-21  
**Reviewer:** Claude Code  

## Unsafe Operations

### Direct CPU Register Manipulation

The context switch routine must save and restore all CPU general-purpose registers (RAX, RBX, RCX, RDX, RSI, RDI, RBP, RSP, R8-R15) from/to the TCB.

**Risk:** Corruption of register state leads to thread state loss or execution of wrong code.

**Mitigation:**
- All registers must be saved to `TCB.saved_regs_ptr` before switching away
- All registers must be restored from target `TCB.saved_regs_ptr` before resuming
- Order of save/restore must match CPU calling convention
- No implicit register clobbering between save and restore

### GS-Base and Model-Specific Registers (MSR)

The routine modifies `IA32_KERNEL_GS_BASE` (MSR 0xC0000102) and/or `IA32_GS_BASE` (MSR 0xC0000101) to point to the per-CPU current TCB pointer.

**Risk:** Incorrect GS-base leaves threads pointing to wrong per-CPU data, causing cross-CPU interference.

**Mitigation:**
- GS-base update must be serialized (no reordering by CPU)
- MSR write must occur after register save but before context switch
- Verify MSR value matches expected per-CPU offset

### Control Register (CR3) Modification

Page table base is switched via CR3 write to activate target's virtual address space.

**Risk:** Incorrect CR3 exposes wrong kernel or user memory.

**Mitigation:**
- CR3 value must come from validated `TCB.vspace_ptr`
- Write to CR3 must include serialization (INVLPG or MOV CR3)
- No memory access between CR3 write and new page tables active

### Instruction Pointer (RIP) Restoration

The saved RIP from `TCB.saved_regs_ptr` is used to resume execution.

**Risk:** Malformed RIP leads to instruction fetch from invalid memory or user code.

**Mitigation:**
- RIP must be validated to lie within kernel code regions or mapped user regions
- RIP cannot point to unmapped memory
- RIP must not be modifiable by untrusted threads

## Invariants

1. **Atomicity:** Context switch must appear atomic to the thread being switched away
2. **Isolation:** Register state of one thread must not leak to another
3. **State Consistency:** TCB and CPU state must match after switch completes
4. **GS-base Coherency:** GS-base must match the running TCB's per-CPU offset

## Testing Strategy

- Unit test: save state, overwrite registers, restore state → verify all registers restored
- Isolation test: two threads with distinct register values → verify no cross-contamination
- GS-base test: verify GS-base points to correct per-CPU current TCB after switch
