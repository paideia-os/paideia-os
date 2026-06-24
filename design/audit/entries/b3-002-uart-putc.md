---
audit_id: b3-002-uart-putc
issue: 333
file: src/kernel/boot/uart.pdx
function: uart_putc
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-24
status: deferred-paideia-as-label-support
---

# AUDIT B3-002-uart-putc — Polled character transmit to COM1 16550 UART (DEFERRED)

## Issue

Attempted to implement the NS PC16550D §3.4 polling-write protocol as specified in softarch for issue #333. Implementation blocked by **paideia-as label support gap**: the encoder code for local label references (Phase 6 m4-003) exists but is not wired into the parser/elaborator pipeline.

## Intended implementation

COM1 16550 UART character transmit with polling on the Transmitter Holding Register (THR) empty condition:

```pdx
let uart_putc : (u64) -> () !{sysreg} @{} = fn (ch: u64) -> unsafe {
  effects: { sysreg },
  capabilities: { },
  justification: "16550D §3.4 polling-write protocol on COM1...",
  block: {
    mov rax, rdi;
    poll_lsr:
      mov dx, 0x3FD;
      in_al al;
      and rax, 0x20;
      jz poll_lsr;
    mov rax, rdi;
    mov dx, 0x3F8;
    out_al al
  }
}
```

## Root cause: paideia-as label reference gap

The paideia-as assembly language supports **two types of references** in unsafe blocks:

1. **SymbolRef** (external symbols, link-time resolution): Parsed successfully for bare identifiers in Jcc position
2. **LabelRef** (local labels, assembly-time resolution): Encoder code exists but parser doesn't generate these

### Current behavior

When the parser encounters `jz poll_lsr`, it creates a `Operand::SymbolRef { name: "poll_lsr" }` operand, treating it as an external symbol. The encoder's `encode_jcc` function has two match arms:

```rust
[Operand::Imm64(rel)] => { /* encode immediate displacement */ }
[Operand::LabelRef { name, addend }] => { /* Phase 6 m4-003 label fixup */ }
_ => Err(Unsupported("jcc form not in phase-3-m2-002 minimum"))
```

Since the operand is `SymbolRef` (not `LabelRef`), the encoder rejects it with the error message:
```
error: encoder failed on IR node 208: encoding error: Unsupported("jcc form not in phase-3-m2-002 minimum")
```

### Expected behavior (post-fix)

The elaborator should:

1. **Pass 1**: Scan unsafe block for label declarations (identifiers ending with `:`)
2. **Pass 2**: When encountering a bare identifier in Jcc operand position, check if it's a **local** label (in the collected set). If so, create `Operand::LabelRef`; otherwise create `Operand::SymbolRef`

The encoder would then route to the Phase 6 m4-003 label fixup path.

## Workarounds attempted

- **Immediate displacement**: Not viable—polling offset is unknown at assembly time
- **SymbolRef with external linkage**: Would require runtime symbol resolution (not available in kernel boot context)
- **Unrolled loop without backward jump**: Violates softarch spec (single characterpoly loop intended)

## paideia-as commits involved

- **Phase 6 m4-002** (commit 426dc73): `ir + unsafe-walker: label declaration + forward-label operand shape` — Parser support for label syntax and validation
- **Phase 6 m4-003** (commit be142c2): `encoder: real Jcc encoder for forward labels (rel32 form)` — Encoder support for LabelRef operands

Both commits are in the current paideia-as submodule HEAD (`eef5f35`), but the integration is incomplete. The label declaration pass (m4-002) mentions "two-pass processing" in comments but the second pass doesn't actually produce `LabelRef` operands for Jcc.

## Sysreg justification

The intended implementation would require:
- `in_al al` (opcode EC): privileged I/O port read → `effects: [sysreg]`
- `out_al al` (opcode EE): privileged I/O port write → `effects: [sysreg]`
- `and rax, 0x20`: unprivileged (included for ZF semantics)

## Traceability

- Issue: #333 (B3-002 real uart_putc polling-write)
- Softarch: uart_putc polling-loop spec
- Blocker: paideia-as label reference integration (Phase 6 m4-002/m4-003)
- Related: #332 (B3-001 uart_init, real implementation complete), #329 (uart_puts, deferred)
- Honest scope: Encoder code exists but parser/elaborator pipeline doesn't produce the required operand type
