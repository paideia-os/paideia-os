---
audit_id: idt-install-001
issue: 252
file: src/kernel/core/int/idt.pdx
function: idt_lidt / idt_install
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT idt-install-001 — IDT build + lidt (R6.5-001)

## Justification
`idt_install` builds the 256-entry interrupt descriptor table and loads it with
`lidt`. Loading the IDTR is privileged and changes how the CPU dispatches every
subsequent interrupt and exception — inherently unsafe. The entry-packing
arithmetic (offset split into lo16/mid16/hi32, OR-ing in selector/IST/type) is
ordinary computation done in the typed surface; only the `lidt` is unsafe.

Citation: Intel SDM Vol 3A §6.10 (Interrupt Descriptor Table) and §6.14.1
(64-bit IDT gate descriptor layout). **Verification TODO.**

## Entry layout (16 bytes, two u64 words)
- word0 = offset[0:15] | selector<<16 | ist<<32 | type_attr<<40 | offset[16:31]<<48
- word1 = offset[32:63] | reserved(0)<<32
- type_attr 0x8E = present, DPL 0, 64-bit interrupt gate.
- Vector 8 (double fault) uses IST index 1; all others IST 0.

## Install map
- vectors 0..31  → CPU exception trampolines (exceptions.pdx)
- vector  32     → LAPIC timer ISR (R6.5-003/004)
- vector  33     → TLB-shootdown / reschedule IPI (R6.5-005)
- vectors 34..255 → default handler

## Phase-6 honest scope gaps
- **lidt encoder**: not in paideia-as 0.6.0; `idt_lidt` emits `mov rax, rax`.
  Real instruction `lidt [rdi]` with RDI → a 10-byte IDTR (limit 4095 + base).
- **Per-entry stores** into the IDT table: base+displacement mem operands,
  gated. Implemented for real: the word0/word1 packing for all 256 vectors.

## Verification (when encoders land)
```bash
./tools/paideia-as build --emit elf64 src/kernel/core/int/idt.pdx -o idt.o
objdump -d idt.o   # expect a 256-iteration build loop + one lidt
```
Behavioral test: trigger int 0 (div by zero); the vector-0 handler runs and
writes "EXC0" to UART.
