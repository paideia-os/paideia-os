---
audit_id: uart-init-001
issue: 6
file: src/kernel/boot/uart.pdx
function: uart_out
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT uart-init-001 — uart_out

## Justification
COM1 16550 UART port write at 0x3F8. The `out dx, al` instruction is
a privileged sysreg operation. Caller orchestrates the 7-step init sequence
by invoking uart_out with the appropriate (port, byte) pairs:

1. Port 0x3F9 ← 0x00 (interrupts disabled)
2. Port 0x3FB ← 0x80 (DLAB = 1)
3. Port 0x3F8 ← 0x01 (divisor low: 115200 / 1)
4. Port 0x3F9 ← 0x00 (divisor high)
5. Port 0x3FB ← 0x03 (8N1, DLAB = 0)
6. Port 0x3FA ← 0xC7 (FIFO enable + clear + 14-byte threshold)
7. Port 0x3FC ← 0x0B (DTR + RTS + OUT2)

Spec: TI 16550D datasheet + DEC SRM 1.6.

## Implementation notes
The function signature `fn (port_byte: u64) -> ()` takes a parameter that
serves as the calling convention anchor (placed in RDI by x86_64 ABI), though
the actual I/O values (port and byte) are pre-loaded in DX and AL registers
by the caller before invocation. This matches the caller discipline described
in the paideia-as surface specification for I/O port operations.

The unsafe block justification covers:
- `sysreg` effect: `out dx, al` is a privileged I/O port write instruction
  that directly modifies external hardware state (the UART).
- No external capabilities required: UART port 0x3F8 (COM1) is always
  accessible from kernel ring-0 in Phase-1 identity-mapped I/O space.

## Mnemonic encoding status
The `out dx, al` mnemonic was successfully encoded by paideia-as m2-003
encoder without errors.
