---
audit_id: uart-puts-001
issue: 8
file: src/kernel/boot/uart.pdx
function: uart_puts
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT uart-puts-001 — uart_puts Phase-1 stub

## Justification
COM1 16550 UART bulk byte transmission via iteration over a buffer. The `uart_puts` function
iterates over a byte array and writes each byte via `uart_putc`, which performs the privileged
`out dx, al` I/O port write to 0x3F8 (COM1 data port).

Phase-1 implementation is a stub: writes a single byte without the full loop. Caller discipline
arranges DX=0x3F8 (COM1 data port) and AL=first byte. The loop iteration mechanism requires
paideia-as support for conditional jumps (`cmp`, `jl`, `jcc`), which is not yet available in
unsafe blocks.

## Specification (deferred loop)
The intended full loop design (Phase 6+):
```
; Parameters: RSI = pointer to buffer s, RDX = length len (in bytes)
; Caller sets DX=0x3F8 (UART port), counter (RCX or R8) = 0

loop_iterate:
  mov al, [rsi + counter]      ; load s[counter]
  call uart_putc               ; write byte via uart_putc
  inc counter                  ; counter++
  cmp counter, len             ; compare counter with len
  jl loop_iterate              ; jump if counter < len
  ret
```

This requires paideia-as encoders for:
- `cmp` (compare instruction) — Phase 6 (m2-001)
- `jl`, `jcc` (conditional jump) — Phase 6 (m2-002)

## Implementation notes
The function signature `fn (buffer_len: u64) -> ()` takes a single parameter for type
compatibility with paideia-as Phase 1 (v0.5.0) function syntax, which does not yet support
multiple-parameter function definitions.

Phase-1 implementation semantics:
- Parameter `buffer_len` is accepted per calling convention (placed in RDI by x86_64 ABI)
  but not used in the Phase-1 stub. It documents the intended loop length for Phase 6+.
- Caller pre-loads: DX = 0x3F8 (COM1 UART data port), AL = first byte to transmit
- Phase-6+ full signature will be: `fn (s: u64, len: u64) -> ()` with RSI and RDX
  pre-loaded by caller with buffer pointer and length

Note: Phase-1 stub writes only the pre-loaded AL byte to the pre-arranged DX port via a
single `out_al rax` instruction. This matches the design pattern established by uart_putc
(P1-007). When paideia-as syntax evolves to support tuple parameters in unsafe blocks,
the function signature will be updated without changing the audit entry's loop deferral
reasoning.

The unsafe block justification covers:
- `sysreg` effect: `out dx, al` is a privileged I/O port write instruction that directly
  modifies external hardware state (UART TX).
- No external capabilities required: UART port 0x3F8 (COM1) is always accessible from
  kernel ring-0 in Phase-1 identity-mapped I/O space.

## Mnemonic encoding status
The `out_al rax` mnemonic is identical to uart_out (P1-006) and uart_putc (P1-007);
successfully encoded by paideia-as m2-003.

## Phase progression

### Phase 1 (Current)
- Stub implementation: single-byte write
- No loop; parameters accepted but unused
- Placeholder for loop design documentation

### Phase 6+ (Deferred)
- Full loop iteration once paideia-as ships conditional-jump encoders (m2-001 + m2-002)
- Upgrade emits: load byte from [s + counter], call uart_putc, increment, cmp, jl back
- Tracking: paideia-as STATUS.md milestones and m2 encoder roadmap

## Testing strategy (Phase 1)
1. Verify function exists and compiles without error
2. Verify audit entry is present
3. Confirm kernel.elf builds and no undefined references
4. Single-byte transmission via uart_puts can be manually tested by calling with arranged
   DX=0x3F8 and AL=test byte (identical behavior to uart_putc)

Full loop testing deferred until Phase 6+ paideia-as encoders ship.
