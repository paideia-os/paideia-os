---
audit_id: uart-puts-r15
issue: 268
file: src/kernel/boot/uart.pdx
function: uart_puts
effects: [sysreg]
capabilities: []
reviewed_by: Santiago
date: 2026-06-21
---

# AUDIT uart-puts-r15 — uart_puts (R1.5-003)

## Justification

uart_puts outputs a buffer of bytes to COM1 UART. Intended design:
- Input: pointer (u64, in RDI) and length (u64, in RSI) per x86-64 ABI
- Loop: iterate over buffer[0..len), read each byte, call uart_putc for transmission
- Precondition: UART initialized (uart_init called first)

Full loop pseudocode:
```
for i in 0..len {
  let b = read_byte(ptr + i);
  uart_putc(b)
}
```

This requires:
1. Multi-parameter function syntax: fn(ptr: u64, len: u64) -> ()
2. Memory-read operand: mov al, [rdi + rsi*1] (addressing modes)
3. Loop control: while (i < len) { ... i = i + 1 } OR cmp + jz/jle
4. Inter-function call: uart_putc(b)

## Implementation Status (R1.5-003)

**Honest scope:** paideia-as 0.6.0 does not support any of the above features:

1. **Multi-parameter functions (paideia-as Phase 2 feature):** Parser rejects
   `fn (arg1: u64, arg2: u64) -> ()` syntax. Single-parameter functions only.
   
2. **Memory-read operand (m3-004, pending):** mov al, [rdi] addressing mode not
   in resolver table. Requires x86-64 addressing-mode encoder.
   
3. **Loop codegen (PA7-004):** while syntax parses but codegen to conditional
   jumps not yet wired. Deferred to Phase 5 codegen pass.
   
4. **Conditional-jump codegen (m4-001/m4-002):** cmp/test + jcc not yet supported
   in unsafe blocks. Deferred to Phase 4+ encoder work.

Current implementation: single-parameter placeholder (buffer_addr in RDI only).
Caller discipline documented: RDI ← ptr, RSI ← len (ready for future multi-param).

## Blocking Issues

- paideia-as #704: Multi-parameter function syntax (Phase 2)
- paideia-as #708: Memory-read operand m3-004 (x86-64 addressing)
- paideia-as #706: while-loop codegen to conditional branches (Phase 5)
- paideia-as #710: Conditional-jump encoders m4-001/m4-002 (Phase 4+)

## Mnemonic Encoding Status

- `mov rax, rax`: Encoded by m2-001, 3 bytes (0x48 0x89 0xc0)
- `out_al rax`: Encoded by m2-003, 1 byte (0xee)
- `mov al, [rdi]`: Deferred (m3-004 pending)
- `cmp rsi, rax`: Deferred (m4-001 pending)
- `jle loop_label`: Deferred (m4-002 pending)

## Next Steps (Priority Order)

1. **Multi-parameter functions (paideia-as #704):** Unblock uart_puts, uart_getc, etc.
   Est. Phase 2 (1-2 weeks). Enables parameter passing per ABI.

2. **Memory-read operand (m3-004):** Load bytes from buffer. Est. Phase 3 (2-3 weeks).
   Requires x86-64 addressing-mode parser (SIB, displacement) + encoder.

3. **Conditional-jump codegen (m4-001/m4-002):** Required for loop lowering.
   Est. Phase 4 (3-4 weeks). Immediate operand encoders (m3-003) prerequisite.

4. **while-loop codegen (PA7-004):** Rewrite loop to cmp + jle + jmp.
   Est. Phase 5 (1 week). Depends on m4-001/m4-002.

## Citation

x86-64 ABI calling convention: RDI ← arg0, RSI ← arg1, RDX ← arg2, etc.
16550 UART datasheet, Section 2.1 (Transmit Data Port).
