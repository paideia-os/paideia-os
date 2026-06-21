# Audit Entry: Minimal IDT Entry for Timer Interrupt [unsafe]

**Issue:** #111  
**File:** `src/kernel/core/sched/timer_idt.pdx`  
**Date:** 2026-06-21  
**Reviewer:** Claude Code  

## Unsafe Operations

### Direct IDT Manipulation (LIDT)

The LIDT instruction loads the Interrupt Descriptor Table Register (IDTR). Incorrect IDT base or size crashes the system on next interrupt.

**Risk:** Malformed IDT causes:
- GPF when interrupt fires
- System crash if IDT pointer is invalid
- Unauthorized code execution if handler address is wrong
- Cross-CPU interference if IDT is shared

**Mitigation:**
- IDT must be allocated in kernel memory (non-pageable)
- IDT must be 4K-aligned (on modern CPUs)
- Verify IDT base before LIDT
- Each CPU should have its own IDT (or properly synchronized shared IDT)

### IDT Entry Construction

An IDT entry contains the interrupt handler address. Incorrect construction causes undefined behavior.

**Risk:** Malformed entry points to arbitrary code.

**Mitigation:**
- Handler address must be kernel code (in executable section)
- Handler address must be page-aligned or within code page
- All reserved bits must be zero
- Gate type must be valid (0x0E for 64-bit interrupt gate)
- DPL and PRESENT bits must be set correctly

### Vector Selection

Interrupt vector determines which IDT entry fires on interrupt. Using wrong vector causes wrong handler to run.

**Risk:** Timer interrupt triggers wrong handler (e.g., runs page fault handler).

**Mitigation:**
- Vector 0x20 (32) is standard for first PIC/APIC interrupt
- Vectors 0x00-0x1F are reserved for CPU exceptions
- Document vector allocation scheme
- Verify vector doesn't conflict with exception handlers

### Interrupt Enable/Disable Coordination

LIDT is usually called once at boot, but care needed if called at runtime.

**Risk:** Changing IDT while interrupts are enabled causes double fault.

**Mitigation:**
- Disable interrupts before LIDT
- Verify IDTR and all entries valid before enabling
- Provide rollback mechanism in case of error

### Gate Type and IST

The gate type (interrupt vs. trap vs. task) affects whether interrupts are disabled during handler.

**Risk:** Using wrong gate type causes unexpected behavior.

**Mitigation:**
- Use interrupt gate (type 0x0E) for most cases
- Interrupt gate disables interrupts automatically
- Trap gate does not (usually not needed)
- Document chosen gate type and rationale

## Invariants

1. **IDT Validity:** IDT base must be valid kernel memory, size must match entry count
2. **Handler Validity:** Each IDT entry must point to valid kernel code
3. **Vector Uniqueness:** Each vector mapped to intended handler (no conflicts)
4. **Atomicity:** IDT load (LIDT) is atomic
5. **Isolation:** Each CPU has independent IDT (no cross-CPU interference)

## Testing Strategy

- Unit test: load IDT, trigger timer interrupt → verify handler runs
- Corruption test: intentionally corrupt IDT entry → verify GPF on interrupt
- Vector test: verify each exception/interrupt uses correct vector
- Multicore test: load different IDTs on different CPUs → verify isolation
- Rollback test: LIDT failure should leave system in known state
