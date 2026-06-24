---
audit_id: b3-001-uart-init
issue: 332
file: src/kernel/boot/uart.pdx
function: uart_init
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-24
---

# AUDIT B3-001-uart-init — Full 7-step COM1 16550 UART initialization

## Justification
COM1 16550 UART initialization at base address 0x3F8 per NS PC16550D §3.3 and IBM PC convention. The implementation executes a strict 7-step I/O port write sequence to configure the UART for 115200 baud, 8 data bits, no parity, 1 stop bit (8N1), with FIFO enabled and flow control signals asserted.

The function emits exactly 7 `out` instructions via `out_al al` mnemonic, each paired with a preceding `mov dx, port; mov al, value` setup sequence:

1. **IER (Interrupt Enable Register) at 0x3F9 ← 0x00**: Disable all UART interrupts
2. **LCR (Line Control Register) at 0x3FB ← 0x80**: Set DLAB (Divisor Latch Access Bit) to enable divisor load
3. **DLL (Divisor Latch Low) at 0x3F8 ← 0x03**: Divisor = 3 → 1.8432 MHz / (3 × 16) = 115,200 baud
4. **DLM (Divisor Latch High) at 0x3F9 ← 0x00**: High byte of divisor (0 for rates ≤ 115.2K)
5. **LCR at 0x3FB ← 0x03**: Clear DLAB, set 8N1 framing (word length 11b, no parity, 1 stop bit)
6. **FCR (FIFO Control Register) at 0x3FA ← 0xC7**: Enable FIFOs, clear RX+TX, set 14-byte trigger threshold
7. **MCR (Modem Control Register) at 0x3FC ← 0x0B**: Assert DTR (Data Terminal Ready), RTS (Request to Send), OUT2 (loopback enable option)

Registers DX and AL are modified as side effects; caller responsibility is to preserve any registers needed across this call (per x86-64 ABI, DX and RAX are caller-saved).

## Hardware reference
- **NS PC16550D Asynchronous Communications Element** (National Semiconductor, 1995) §3.3: Initialization sequence
- **IBM PC Technical Reference** (1983): I/O port mapping for COM1 (base 0x3F8)
- **Intel 64 and IA-32 Architectures Software Developer's Manual** Vol. 2A: `out` instruction privilege level (ring 0 only)

## Implementation notes
The unsafe block contains no jumps, loops, or conditional branches; it is a linear sequence of 14 x86-64 instructions (7 × mov pairs + 7 × out). Paideia-as 0.6.0+ supports both `mov dx, imm16` and `out_al al` mnemonics without parser limitation (immediate operands are now available post-m3-003).

The `mov dx, port` and `mov al, value` instructions use immediate operands (16-bit for DX, 8-bit for AL). These are encoded by paideia-as as standard x86-64 imm-to-register moves.

## Known limitations
- **Loopback verification deferred**: B3-001b will add diagnostic code to read LSR (Line Status Register at 0x3FD) and verify the UART is responsive. Phase 1 scope does not include polling loops.
- **Wiring deferred to B3-001-wiring**: The new `uart_init` function is not yet called by `kernel_main`. The boot path still uses a local shadow stub in kernel_main.pdx. De-shadowing (actual call site wiring) happens in B3-001-wiring.

## Sysreg justification
The `out_al al` mnemonic translates to `out dx, al` (opcode EE), a privileged I/O port write instruction. Execution requires ring-0 privilege. All 7 `out` operations modify external hardware state (the UART serial interface), hence `effects: [sysreg]`.

## Mnemonic encoding validation
Paideia-as commit m3-003 added full immediate-operand support for unsafe blocks. This audit entry validates:
- ✓ `mov dx, 0x3F8..0x3FC` (imm16 → DX register)
- ✓ `mov al, 0x00..0xC7` (imm8 → AL register)
- ✓ `out_al al` (no-operand mnemonic; DX+AL implicit)

All mnemonics tested in build and validated by objdump disassembly (7 `ee` bytes per spec).

## Traceability
- Issue: #332 (B3-001 real uart_init 7-step COM1 sequence)
- Softarch: §2 (spec verbatim), §6 (audit entry requirement)
- Milestone: Tier 3 Phase 1 (B3-001 subseries)
