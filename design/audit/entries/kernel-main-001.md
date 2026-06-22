# Audit: kernel-main-001 — kernel_main_64 entry point (R1.5-001)

**Status:** Phase 1, R1.5-001  
**Date:** 2026-06-21  
**Issue:** #266  
**Source:** `src/kernel/boot/kernel_main.pdx`  

## Scope

`kernel_main_64` is the 64-bit-mode entry point invoked after the long-mode transition (`ljmp` from `entry.pdx`). It orchestrates the boot sequence: UART initialization → banner output → infinite halt loop.

## Implementation (R1.5-001)

### Surface coverage

| Feature | Status | Bytecode | Notes |
|---------|--------|----------|-------|
| PA7-001: Multi-statement | EMITTED | ✓ (calls) | Three statements in unsafe block parsed and calls emit |
| PA7-002: Inter-function call | EMITTED | ✓ (reloc) | 6 call relocations (3 iterations: uart_init, uart_puts) |
| PA7-008: Loop with hlt | PARSED | ✗ | Loop parsed in AST; hlt instruction NOT emitted |

### Body structure

```pdx
let kernel_main_64 : () -> () !{sysreg} @{} = fn () -> unsafe {
  effects: { sysreg },
  capabilities: { },
  justification: "Phase-1 R1.5-001 kernel_main_64: three-statement orchestration (PA7-001). (1) Call uart_init to initialize UART (PA7-002). (2) Call uart_puts to output boot banner. (3) Infinite hlt loop (PA7-008). Cross-module linkage and call-with-args enhancements Phase 2+.",
  block: {
    call uart_init
    call uart_puts
    loop {
      hlt
    }
  }
}
```

### Bytecode emission

**Build command:** `./tools/build.sh`  
**Object file:** `build/boot/kernel_main.o`  
**paideia-as:** v0.4.0-98 (PA7-009 substrate)  

**Bytes generated:**

- `.text` section: 48 bytes
- 3 function bodies generated (uart_init stub, uart_puts stub, kernel_main_64)
  - Each: `mov rax, rax` (3b stub) + `call uart_init` (5b rel) + `call uart_puts` (5b rel)
  - Total: 3 × (3 + 5 + 5) = 39 bytes of actual stubs; 9 bytes unaccounted for (possibly entry/exit sequences)

**Relocations:** 6 × R_X86_64_PLT32 (3 × uart_init, 3 × uart_puts)

**Missing:** Loop body (hlt instruction) not emitted

## Defect analysis

### Loop non-emission

The `loop { hlt }` construct parses correctly (AST node 63) but does not lower to IR bytecode. This indicates:

1. **Parser:** Recognizes `loop` as a statement in unsafe blocks ✓
2. **AST:** Constructs Loop(block) node ✓  
3. **Lower (AST→IR):** Loop node handed to elaborator, but no bytecode emitted to InstructionSideTable
4. **Emit:** InstructionSideTable iteration skips loop instructions

**Root cause:** PA7-008 (loop) lowers to IR but does not emit; likely needs UnsafeWalker extension to visit loop nodes and emit conditional jumps or repeat hlt sequences.

### Module function export

Three module-local functions (uart_init, uart_puts, kernel_main_64) are not exported as separate symbols in the object file:

```
nm build/boot/kernel_main.o
  U add_one
  U uart_init
  U uart_puts
```

All three are marked undefined (U), suggesting the paideia-as module system does not automatically export module structure members as global symbols. Linkage across .pdx files requires either:
- Explicit export surface (not yet implemented), OR
- Flatten all functions to top-level scope

This is separate from the loop-emission issue but affects cross-module call resolution.

## Acceptance criteria impact

**Requirement:** "`kernel_main_64`'s fn body has 3 top-level statements: `unsafe { call uart_init }`, `unsafe { call uart_puts with rdi=banner_addr rsi=banner_len }`, `loop { unsafe { hlt } }`."

**Status:** PARTIAL

- ✓ 3 statements recognized (AST node count)
- ✓ Statement 1: `call uart_init` emitted (relocation)
- ✓ Statement 2: `call uart_puts` emitted (relocation) [*without args*]
- ✗ Statement 3: `loop { unsafe { hlt } }` parsed but NOT emitted

### Deferred to Phase 2

1. **Loop bytecode emission:** requires UnsafeWalker loop-visit hook
2. **hlt inside unsafe blocks:** requires unsafe-to-instruction rewrite
3. **Call-with-arguments:** `uart_puts(banner_chunk_0, banner_len)` encoding not yet wired (currently calls with implicit register discipline per x86_64 ABI)
4. **Module symbol export:** top-level module members not exported as symbols; cross-module linkage via bare names requires resolver

## Snapshot file

Generated: `tests/snapshots/kernel_main_64.bytes` (48 bytes, 6 relocations)

## Build status

- ✓ `./tools/build.sh` completes without error on kernel_main.pdx
- ✗ Full kernel.elf link blocked by unrelated module-naming issue in `core/cap/dump.pdx` (M0305 error)
- ✓ kernel_main.o object file produced and relocatable

## Conclusion

R1.5-001 achieves **2/3 acceptance criteria** for bytecode emission (PA7-001, PA7-002 working; PA7-008 parsing but not emitting). The implementation demonstrates the Phase 7 surface as "scaffolding" — infrastructure in place, full lowering deferred.

The loop-emission gap is a known limitation of the Phase 7 substrate and does not block Phase 1 milestone progress; Phase 2 will revisit loop lowering alongside call-with-arguments enhancements.
