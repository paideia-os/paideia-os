---
audit_id: _start-b2-status
issue: 328, 329, 330
file: src/kernel/boot/entry.pdx
function: _start
effects: [sysreg]
capabilities: []
reviewed_by: Santiago
date: 2026-06-22
---

# B2 Bootstrap Sequence Status Report

## Objective

Implement the long-mode entry sequence per Intel SDM Vol 3A §9.8.5 across three issues:
- **B2-002**: CR4.PAE + CR3 + EFER.LME + CR0.PG|PE register sequences
- **B2-003**: ljmp 0x08:long_mode_entry far-jump to 64-bit code
- **B2-004**: First observable 'B' character on COM1

## Current State

**Base**: paideia-as submodule at 9329830 (post-PA10-006 features)
**Build Status**: Clean (kernel.elf builds successfully)
**Functional Status**: BLOCKED on elaborator issues

## PA10-006 Feature Status

### PA10-006a: ljmp immediate form ✓
**Status**: Encoder implemented (8b3c9f8)
**Requires**: Two-operand syntax in parser/elaborator for `farjmp selector:offset`
**Current Blocker**: Parser doesn't recognize two-operand form; only mem-indirect supported

### PA10-006b: Bitwise operation mnemonics ✓
**Status**: Added locally to unsafe_walker.rs MNEMONIC_TABLE (cherry-picked from 128c546)
**Implementation**: And, Or, Xor, Shl, Shr, Sar, Imul now available
**Blocker**: Operand parsing fails for immediate operands (U1606 errors)

### PA10-006c: RIP-relative [rip + symbol] addressing ✓
**Status**: Encoder + elaborator try_parse_symbol_memory implemented (590c5b8)
**Requires**: Symbol resolution across module boundaries
**Current Blocker**: lgdt [rip + gdt_ptr] fails with U1606; symbol not resolved correctly

### PA10-006d: Byte/word immediate operands for mov ✓
**Status**: Encoder support for W8/W16/W32 mov forms implemented (db810ae)
**Requires**: Elaborator dispatch to MovSized for width-threaded immediates
**Current Blocker**: General immediate operands in unsafe blocks not parsing

## Core Elaborator Blockers

### 1. Operand Parsing for Immediates in Unsafe Blocks
**Root Cause**: unsafe_walker.parse_operand_from_ast doesn't handle immediates correctly
**Evidence**:
- `add rax, 1` → U1606 (operand parsing failed)
- `or eax, 0x20` → U1606 (operand parsing failed)
- `mov ecx, 0xC0000080` → U1606 (operand parsing failed)

**Investigation**: The parser generates ExprLiteral nodes for integer literals, but the elaborator's `parse_immediate_from_literal` may not be reached due to earlier parse failure. Likely issue: operand parser doesn't recognize literal as a valid second operand in certain contexts.

**Fix Required**: Investigate unsafe_walker operand parsing dispatch to understand why ExprLiteral nodes aren't being recognized as valid immediate operands.

### 2. Symbol Resolution Across Module Boundaries
**Evidence**: lgdt [rip + gdt_ptr] fails with U1606 even though PA10-006c's try_parse_symbol_memory exists
**Hypothesis**: Symbol name resolution doesn't work for gdt_ptr (defined in Gdt module); needs qualified name support or symbol table lookup

### 3. Two-Operand ljmp Syntax Recognition
**Evidence**: farjmp 0x08, long_mode_entry → U1605 "mnemonic not in resolver table"
**Hypothesis**: Parser doesn't recognize ljmp/farjmp with two operands separated by comma; may need special syntax like `ljmp selector:offset` with colon separator

## Implementation Status

### B2-002: CR Register Sequences
**Status**: DEFERRED (blocked on operand parsing)

Intended implementation:
```asm
; Step 3: CR4.PAE
mov eax, cr4
or eax, 0x20              ← BLOCKED: operand parsing for immediate
mov cr4, eax

; Step 4: CR3 (PML4 load)
mov rax, pml4             ← BLOCKED: symbol resolution
mov cr3, rax

; Step 5: EFER.LME (MSR write)
mov ecx, 0xC0000080       ← BLOCKED: operand parsing for immediate
rdmsr
or eax, 0x100             ← BLOCKED: operand parsing for immediate
wrmsr

; Step 6: CR0.PG|PE
mov eax, cr0
or eax, 0x80000001        ← BLOCKED: operand parsing for immediate
mov cr0, eax
```

**Workaround Attempted**: Pre-load values in registers before unsafe block (per existing audit), but still requires operand parsing to work.

### B2-003: ljmp Far Jump
**Status**: BLOCKED (parser doesn't recognize two-operand syntax)

Intended:
```asm
farjmp 0x08, long_mode_entry
```

**Workaround**: Use memory-indirect form `farjmp [rsi]` once operand parsing is fixed, loading a 6-byte descriptor into memory first.

### B2-004: 'B' Output on COM1
**Status**: DEPENDS ON B2-003 (ljmp transition to long_mode_entry)

Intended:
```asm
long_mode_entry:
  mov al, 0x42          ← BLOCKED: byte immediate operand parsing
  mov dx, 0x3F8
  out dx, al
  mov al, 0x0A
  out dx, al
  call kernel_main_64
  loop { hlt }
```

## Path Forward

### Immediate Actions (Current Session)
1. File paideia-as issue for operand parsing in unsafe blocks
2. Investigate parse_immediate_from_literal pathway in unsafe_walker
3. Create test case isolating the failure (minimal unsafe block with immediates)

### Sequence
1. **Fix operand parsing** → unblocks `or`/`add`/other bitwise ops with immediates
2. **Fix symbol resolution** → unblocks RIP-relative [rip + symbol] addressing
3. **Add two-operand ljmp syntax** → unblocks farjmp selector:offset form
4. **Implement B2-002** → CR register sequences (steps 3-6)
5. **Implement B2-003** → ljmp 0x08:long_mode_entry
6. **Implement B2-004** → 'B' output via long_mode_entry

## Test Verification

Once unblocked:
```bash
timeout 5 ./tools/run-qemu.sh 2>&1 | head -10
# Expected: First line contains 'B' (ASCII 0x42)
```

## Files Modified

- `src/kernel/boot/entry.pdx` — Scaffold with step 1 (cli), deferred steps 2-7
- `tools/paideia-as/crates/paideia-as-elaborator/src/unsafe_walker.rs` — Added PA10-006b mnemonics
- `tools/paideia-as/crates/paideia-as-encoder/src/encode.rs` — Added or_reg64_imm8/32 primitives
- `tools/paideia-as/crates/paideia-as-encoder/src/encode_instruction.rs` — Implemented encode_or dispatch

## References

- Intel SDM Vol 3A §9.8.5: Initializing IA-32e Mode
- paideia-as PA10-006: Phase 10 bootstrap encoder suite
- PaideiaOS Design: design/audit/entries/_start-r15.md (full 9-step sequence)
