---
audit_id: uart-init-r15
issue: 267
file: src/kernel/boot/uart.pdx
function: uart_init
effects: [sysreg]
capabilities: []
reviewed_by: Santiago
date: 2026-06-21
---

# AUDIT uart-init-r15 — uart_init (R1.5-002)

## Justification

COM1 16550 UART initialization to 115200 baud, 8N1 framing per NS PC16550D §3.3.
The `uart_init` function orchestrates a 7-step port-write sequence:

1. Port 0x3FB ← 0x80 (LCR: DLAB=1, enable divisor latch access)
2. Port 0x3F8 ← 0x03 (DLL: divisor low byte, sets 115200 baud)
3. Port 0x3F9 ← 0x00 (DLM: divisor high byte)
4. Port 0x3FB ← 0x03 (LCR: 8N1 framing, DLAB=0, disable divisor latch)
5. Port 0x3FA ← 0xC7 (FCR: FIFO enable, clear, 14-byte threshold)
6. Port 0x3FC ← 0x0B (MCR: DTR + RTS + OUT2 control lines)
7. Port 0x3F9 ← 0x00 (IER: disable all interrupts)

Each write: `mov al, byte_value; mov dx, port_address; out_al rax`.
Total expected bytecode: ~22 instructions (7×3-instruction patterns + ret).

## Implementation Status (R1.5-002)

**Honest scope:** paideia-as 0.6.0 does not support immediate-operand syntax in unsafe
blocks (limitation in operand parser, not architectural). Immediate-load encoders (m3-003)
are planned. Current implementation is a placeholder (`mov rax, rax`) that demonstrates:
- Cross-module linkage (uart_init called from kernel_main_64)
- Effect signature (sysreg, no capabilities)
- Justification discipline

**Citation:** NS PC16550D datasheet, Section 3.3 (Initialization Sequence).

## Mnemonic Encoding Status

- `mov rax, rax`: Encoded by paideia-as m2-001 (register-to-register), 3 bytes (0x48 0x89 0xc0)
- `mov al, imm8`: Deferred (paideia-as m3-003 pending, ~Feb 2026)
- `mov dx, imm16`: Deferred (m3-003)
- `out_al rax`: Encoded by paideia-as m2-003, 1 byte (0xee)

**Blocking issue:** paideia-as #712 (immediate-operand parsing in unsafe-block operand context).

## Next Steps

When paideia-as m3-003 ships (immediate encoders):
1. Replace placeholder with full 7-step sequence.
2. Re-emit uart_init.bytes snapshot.
3. Update DRAM allocation: uart_init grows from 3 bytes to ~22 bytes.
4. Cross-check linker map for symbol collisions (unlikely in .text).
