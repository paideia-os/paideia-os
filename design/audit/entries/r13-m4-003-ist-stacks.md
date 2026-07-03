# R13-m4-003: IST Stacks in .bss

**Issue:** #425  
**Status:** Implementation complete  
**File:** `src/kernel/core/int/ist.pdx`

## Justification

Interrupt Stack Tables (IST) provide isolated kernel stacks for critical exceptions that may occur during stack overflow or other exceptional conditions. Per Intel SDM Vol 3A §6.14.5, IST entries 1–3 are used for:

- **IST 1 (DF):** Double fault — critical for recovering from kernel stack overflow.
- **IST 2 (NMI):** Non-maskable interrupt — must not share the kernel stack to ensure NMI handlers run safely during exception contexts.
- **IST 3 (MC):** Machine check — similar isolation requirement; also repurposed for page-fault discipline (IST 4 → IST 1).

Without dedicated IST stacks, a double fault during an exception (e.g., page fault on kernel stack expansion) cannot be handled, leading to triple-fault CPU halt. IST stacks are mandatory for kernel correctness.

## Sizes

- **Stack size:** 16 KiB (16384 bytes) per stack.
- **Total allocation:** 3 stacks × 16 KiB = 48 KiB.
- **Element type:** `u64` (8 bytes); 2048 elements per stack.
- **Alignment:** 16 B (`@align(16)`) — required by x86-64 calling convention for RSP alignment at function entry.

Rationale for 16 KiB:
- Sufficient depth for nested exception handlers and context-save frames.
- Conservative margin for exceptional code paths (machine-check handlers, NMI processing).
- Multiples of 4 KiB page size for potential future isolation.

## Access Pattern

Stacks are allocated as static arrays in kernel `.bss`:

```paideia-as
pub let mut _ist1_stack : [u64; 2048] = uninit @align(16)
pub let mut _ist2_stack : [u64; 2048] = uninit @align(16)
pub let mut _ist3_stack : [u64; 2048] = uninit @align(16)
```

Stack-top addresses are computed via runtime accessor functions:

```paideia-as
pub let ist1_top : () -> u64 = fn () -> unsafe { ... }
pub let ist2_top : () -> u64 = fn () -> unsafe { ... }
pub let ist3_top : () -> u64 = fn () -> unsafe { ... }
```

Each accessor:
1. Loads the stack base address via `lea rax, [rip + _istN_stack]`.
2. Adds 16384 to compute the stack top.
3. Returns the value in RAX.

**Why functions, not compile-time constants?** Kernel code runs with position-independent execution. A static address cannot be computed at compile time; it must be RIP-relative at runtime. The accessor functions are inlined by the assembler, incurring no runtime overhead.

**Stack growth:** x86-64 stacks grow downward (toward lower addresses). RSP points to the top of the stack on entry. Exception handlers receive RSP = stack-top on IST frame switch.

## Invariants

**I1:** All 3 IST stacks are exactly 16 KiB (16384 bytes).  
- Verified: each array is `[u64; 2048]` → 2048 × 8 = 16384 bytes.

**I2:** All 3 IST stacks are aligned to 16 bytes.  
- Verified: `@align(16)` attribute applied to all three stacks.

**I3:** IST indices match TSS field layout.  
- IST 1 → TSS.ist1 (DF)
- IST 2 → TSS.ist2 (NMI)
- IST 3 → TSS.ist3 (MC)

## Non-Invariants

**NI1:** Stacks are not explicitly zero-initialized.  
- Stacks are allocated in `.bss`, which is zeroed by the bootloader at kernel load. Explicit zeroing is unnecessary.
- The `uninit` keyword indicates they start as uninitialized data; the `.bss` zeroing happens before kernel execution begins.

**NI2:** TSS.ist1..3 fields are not yet populated.  
- IST stack allocation (m4-003) is complete.
- TSS registration (m4-002) is still blocked on PA-R13-001 (per-CPU data structures).
- Once m4-002 lands, ist1_top(), ist2_top(), ist3_top() will be called to populate TSS fields.

**NI3:** IST 4 is not allocated as a separate stack.  
- IST 4 (page-fault discipline, per Intel SDM Vol 3A) reuses IST 1 (DF stack).
- This is a valid optimization; both handlers run in the same exception context.

## Cross-References

- **m4-002:** TSS installation; will call ist1_top(), ist2_top(), ist3_top() to populate TSS.ist1..3. Blocked on PA-R13-001.
- **m4-004:** IST exception handler stubs; will use IST stacks via TSS during #DF, #NMI, #MC delivery.
- **PA-R13-001:** Per-CPU data structures; unblocks m4-002.
- **Intel SDM Vol 3A §6.14.5:** Task State Segment (TSS) Descriptor — IST field definitions and semantics.

## Implementation Notes

All three accessor functions are unsafe with empty effects/capabilities and a justification string. They emit minimal x86-64 code:

```asm
lea rax, [rip + _ist1_stack]   ; Load stack base (RIP-relative)
add rax, 16384                 ; Compute top
ret
```

This is inlined in all call sites, producing no function-call overhead in release builds.
