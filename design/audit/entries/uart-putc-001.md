---
audit_id: uart-putc-001
issue: 7
file: src/kernel/boot/uart.pdx
function: uart_putc
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT uart-putc-001 — uart_putc Phase-1 stub

## Justification
COM1 16550 UART character transmit at 0x3F8 (data port). The `out dx, al` instruction
is a privileged sysreg operation that writes the byte in AL to the I/O port specified
in DX.

Phase-1 implementation is a stub: assumes the UART transmitter is ready and writes
directly without polling the Line Status Register (LSR) bit 5 (THRE — Transmitter
Holding Register Empty). Caller discipline arranges DX=0x3F8 (COM1 data port) and
AL=byte to transmit.

## Known limitations
- No polling loop: Phase-1 lacks support for conditional jumps (`jz`, `jcc`) and the
  `test` instruction in paideia-as encoders. These are planned for Phase 6+ (m2-001,
  m2-002 encoder milestones in paideia-as).
- Full polling sequence (specification) requires:
  ```
  poll:
    in al, 0x3FD        ; LSR (Line Status Register at COM1+5)
    test al, 0x20       ; bit 5 = THRE (Transmitter Holding Register Empty)
    jz poll             ; busy-wait if not ready
    mov al, <byte>      ; load character
    out 0x3F8, al       ; write to data port
  ```

## Implementation notes
The function signature `fn (port_byte: u64) -> ()` takes a parameter for calling-convention
anchoring (placed in RDI by x86_64 ABI), though actual I/O values (port and byte) are
pre-loaded in DX and AL registers by the caller. This matches the caller discipline
for I/O port operations per the paideia-as surface specification.

The unsafe block justification covers:
- `sysreg` effect: `out dx, al` is a privileged I/O port write instruction that
  directly modifies external hardware state (UART TX).
- No external capabilities required: UART port 0x3F8 (COM1) is always accessible
  from kernel ring-0 in Phase-1 identity-mapped I/O space.

## Mnemonic encoding status
The `out_al rax` mnemonic is identical to the uart_out implementation (P1-006);
successfully encoded by paideia-as m2-003 without errors.

## Deferred to Phase 6+
When paideia-as ships conditional-jump encoders (m2-001 + m2-002 + full m2 IR payload
support), uart_putc will be upgraded to emit the full polling loop shown above. This
upgrade is tracked in the paideia-as STATUS.md milestones.
