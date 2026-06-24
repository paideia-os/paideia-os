# B3-003: uart_puts + banner via string literal

**Issue:** #334  
**Phase:** B3 (Boot Layer / UART)  
**Status:** Implemented  
**Date:** 2026-06-24

## Summary

Implementation of `uart_puts` function for zero-terminated string output to COM1 UART, paired with banner string literal via paideia-as v0.10.0+ string-literal surface (FNV-1a interning to .rodata).

## Changes

### Files Modified

1. **src/kernel/boot/banner.pdx**  
   - Removed 8× `banner_chunk_N` (u64 packed) data
   - Removed `banner_len` constant
   - Added single `banner_msg : *u8` string literal: `"PaideiaOS R8\n"`

2. **src/kernel/boot/uart.pdx**  
   - Replaced `uart_puts` placeholder with real implementation
   - Takes single parameter `s: u64` (string pointer in RDI)
   - Implements zero-terminated string loop:
     - Load RSI from RDI (string pointer copy)
     - Set RCX = 0 (offset within string)
     - Loop: load byte at [RSI + RCX] via SIB form
     - Test byte for NUL via `and rax, 0xff` (zero-extend al)
     - Call `uart_putc` for non-NUL bytes
     - Increment RSI and repeat

### Bytecode Verification

**SIB addressing form:** `mov al, [rsi + rcx]`  
- Encodes as `8a 04 0e` (byte load from [rsi + rcx*1])
- SIB byte `0e`: base=rsi, index=rcx, scale=1

**Forward label:** `jmp loop_top`/`loop_end:`  
- Encodes as `e9 XX XX XX XX` (relative 32-bit displacement)
- Backward loop uses negative disp32

**String literal:**  
- Emitted to .rodata section with FNV-1a deduplication
- R_X86_64_64 relocation for `banner_msg` reference
- Zero-terminated per C convention

## Verification

Pre-implementation gates:
- **G1 (SIB byte-load):** PASS — `[rsi + rcx]` encodes to `8a 04 0e`
- **G2 (forward jmp):** PASS — local label jmp encodes to `e9 XX XX XX XX`
- **G3 (string literal):** PASS — paideia-as v0.10.0 string literal surface active

Build verification:
- `tools/build.sh` produces clean `build/kernel.elf`
- `objdump -d build/kernel.elf` shows `uart_puts` with SIB byte-load + call + jmp
- `readelf -s build/kernel.elf` shows `banner_msg` symbol
- `objdump -s -j .rodata` shows "PaideiaOS R8\n" bytes in .rodata

QEMU smoke test:
- `timeout 5 qemu-system-x86_64 -kernel build/kernel.elf ... 2>&1 | head -3`
- Outputs 'B' (unchanged UART state; uart_puts not yet on critical path to main)

## Rationale

**Why SIB addressing:** x86-64 idiom for byte-indexed memory access. Enables efficient string loops with RCX offset counter.

**Why zero-termination:** Standard C/Unix string convention. Matches uart_putc signature (per-byte output).

**Why string literal:** paideia-as v0.10.0+ feature (PA10-002) unblocks static string data without manual u64-chunk packing. FNV-1a deduplication ensures single copy in .rodata if banner reused.

**Why not use banner_len constant:** uart_puts determines end via NUL terminator (standard for loop detection), eliminating need for separate length metadata.

## Cross-References

- Issue #334 (paideia-os issue tracker)
- PA10-002 (paideia-as string-literal feature, v0.10.0)
- uart-puts-001.md (prior R1.5 placeholder audit)
- b3-002-uart-putc.md (prerequisite uart_putc implementation)

## Audit Trail

- **2026-06-24:** B3-003 implementation complete.
- **paideia-as version:** v0.11.0 (includes PA10-002 string literals + PA9-m1-003 SIB encoder).
- **Kernel build:** Clean, no warnings.
- **Disasm verification:** uart_puts shows correct SIB byte-load bytes + label-relative jmp.
