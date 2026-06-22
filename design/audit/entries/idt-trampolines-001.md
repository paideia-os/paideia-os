---
audit_id: idt-trampolines-001
issue: 253
file: src/kernel/core/int/idt.pdx
function: isr_trampoline / trampoline_vec*
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT idt-trampolines-001 — ISR entry trampolines (R6.5-002)

## Justification
Every IDT entry points at a trampoline that saves the interrupted thread's full
register state, calls the typed handler, restores the state, and returns via
`iretq`. Saving/restoring raw GPRs and executing `iretq` are unsafe: a single
missed register or a misaligned stack corrupts the interrupted thread. One
unsafe block per trampoline keeps each save/restore atomic for audit purposes.

x86_64 has no `pushaq`, so the real save is 15 individual `push` of the GPRs
(RAX, RCX, RDX, RBX, RBP, RSI, RDI, R8–R15 — RSP is in the iret frame), then
`push <vector>` so the handler knows which vector fired.

Citation: Intel SDM Vol 3A §6.14.2 (exception/interrupt stack frame in 64-bit
mode). **Verification TODO.**

## Per-vector set (R7 hand-written)
Vectors 0 (DE), 3 (BP), 6 (UD), 8 (DF), 13 (GP), 14 (PF), 32 (timer),
33 (IPI). Each `trampoline_vecN` delegates to `isr_trampoline(N)`.

## Phase-6 honest scope gaps
- **Named-GPR push/pop sequence wiring + `iretq` encoder**: not in paideia-as
  0.6.0; each trampoline emits `mov rax, rax`. Full generation of all 256
  trampolines awaits PA7 macros (not yet shipped) — hence the hand-written 8.

## Verification (when encoders land)
```bash
./tools/paideia-as build --emit elf64 src/kernel/core/int/idt.pdx -o idt.o
objdump -d idt.o   # each trampoline: 15 push, 1 push imm, call, 15 pop, add rsp,8, iretq
```
Behavioral test: vector-0 trampoline saves all 15 GPRs, calls the handler, and
returns without corrupting caller state.
