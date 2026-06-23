---
audit_id: b2-003-escalation
issue: 329, PA8-m1-002
file: src/kernel/boot/entry.pdx
function: _start, long_mode_entry
effects: [sysreg]
capabilities: [boot]
reviewed_by: Santiago
date: 2026-06-23
---

# B2-003 Escalation: paideia-as PA8-m1-002 Multi-Function Symbol Offset Tracking

## Objective

Implement B2-003 (far-jump to 64-bit long_mode_entry) with ljmp instruction:
```asm
ljmp 0x08, long_mode_entry
```

## Issue Summary

**paideia-as v0.10.0 does not properly track symbol offsets (st_value) for multiple let-fn bindings within the same module.**

When a .pdx module defines two or more functions (let-fn), the paideia-as encoder assigns all functions st_value=0 in the ELF object file, preventing correct relocation resolution when one function references another.

### Evidence

**Test case: Multiple functions in single module (entry.pdx)**

```pdx
module Entry = structure {
  let _start : () -> () !{sysreg} @{} = fn () -> unsafe {
    block: { ljmp 0x08, long_mode_entry }
  }

  let long_mode_entry : () -> () !{} @{} = fn () -> unsafe {
    block: { hlt }
  }
}
```

**Actual symbol table output:**
```
nm build/boot/entry.o:
  0000000000000000 t long_mode_entry
  0000000000000000 T _start
```

Both symbols at offset 0000000000000000, even though ljmp and hlt instructions are at distinct offsets in .text section.

**Linker error:**
```
ld: /home/snunez/Development/PaideiaOS/build/boot/entry.o(.text+0x15): reloc against `long_mode_entry': error 4
```

Relocation error 4 = "undefined symbol or relocation overflow" because linker can't correctly place the relocation when st_value is incorrect.

### Root Cause

**paideia-as encoder issue (PA8-m1-002):** The encoder's function_offsets tracking does not properly record offsets for all functions in a module. Build output shows:

```
[PA8-m1-002] warning: function symbol `long_mode_entry` (ir_node 25) has no function_offsets entry — emitting with st_value=0, st_size=0
```

The encoder falls back to st_value=0 when function_offsets entry is missing.

### Impact on B2 Milestone

**B2-003 Blocker:** Cannot reference long_mode_entry via ljmp because symbol is not properly located in object file.

**Attempted Workarounds:**
1. Define long_mode_entry in separate module (long_mode.pdx) + ljmp from entry.pdx → Cross-module relocation error.
2. Define long_mode_entry inline within _start → Still same offset-tracking issue since both are in Entry module.
3. Hardcoded address (0x100000+offset) → Brittle, breaks with relocations.

All workarounds fail due to root cause in encoder.

## Investigation Details

### Multi-Function Module Test

Both intra-module and same-file multi-function patterns fail:

```pdx
module TestInnerCall = structure {
  let callee : () -> () !{} @{} = fn () -> unsafe { block: { hlt } }
  let caller : () -> () !{} @{} = fn () -> unsafe { block: { call callee } }
}
```

Result: Both symbols at offset 0.

### Cross-Module Test

Attempting ljmp with symbol from long_mode.pdx → Same relocation failure:

```pdx
// entry.pdx
ljmp 0x08, long_mode_entry    // long_mode_entry defined in long_mode.pdx

// Linker output:
// ld: reloc against `long_mode_entry': error 4
```

### Valid paideia-as Features Confirmed Working (v0.10.0)

- `ljmp 0x08, immediate` — Far jump with immediate selector + offset works ✓
- `mov al, 0x42` — Byte immediate operands work ✓
- `mov dx, 0x3F8` — Word immediate operands work ✓
- Single-function modules with internal function references (uart_init, uart_puts in kernel_main.pdx) — Works for same-module local calls ✓

## Blocking Criteria

**Hard blocker for B2-003:** paideia-as encoder cannot emit correct st_value for multiple functions in a module.

This is not a syntax limitation (ljmp 0x08, symbol works), but a code-generation limitation (encoder doesn't track offsets).

## Path Forward

### Required paideia-as Fix

1. Investigate PA8-m1-002 in paideia-as encoder (src/paideia-as-encoder/src/encode.rs or InstructionSideTable tracking)
2. Ensure function_offsets entries are generated for ALL let-fn bindings in a module
3. Compute st_value correctly for each function based on its offset in .text section
4. Retest: `nm build/boot/entry.o` should show:
   ```
   0000000000000001 T _start
   0000000000000009 T long_mode_entry
   ```
   (with correct st_value offsets, not all 0)

### B2-003 Resume Condition

Once paideia-as fix lands and is bumped in submodule:
1. entry.pdx ljmp 0x08, long_mode_entry should link correctly
2. Verify kernel.elf builds without relocation errors
3. Complete B2-003 + B2-004 commits

## References

- paideia-as repo: tools/paideia-as/ (submodule)
- Build warning: `[PA8-m1-002] warning: function symbol ... has no function_offsets entry`
- Intel SDM Vol 3A §9.8.5: Long-mode transition (ljmp target is in 64-bit code)
- Issue #329 (B2-003): Far-jump to 64-bit code
