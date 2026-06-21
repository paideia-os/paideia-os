---
audit_id: boot-longmode-001
issue: 3
file: src/kernel/boot/long_mode.pdx
function: transition
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT boot-longmode-001 — transition

## Justification
Long-mode entry sequence per Intel SDM Vol 3A §9.8.5. Transitions from 32-bit
protected mode to 64-bit long mode by setting CR4.PAE, EFER.LME, CR0.PG, and
performing a far jump to a 64-bit code segment. All operations are privileged
system-register writes with no typed surface in paideia-as Phase-1. Single
unsafe block to keep the sequence atomic in audit terms.

## Implemented Phase-1 scope
The unsafe block executes the following register-to-register sequence:
1. `cli` — disable interrupts (m2-002 encoder)
2. `mov cr3, rdi` — load PML4 base (caller provides in RDI)
3. `mov cr4, rcx` — set CR4 with PAE bit (caller pre-loads in RCX)
4. `wrmsr` — set EFER.LME via MSR write (caller pre-loads ECX/EDX/EAX per x86 discipline)
5. `mov cr0, rax` — set CR0 with PG|PE bits (caller pre-loads in RAX)

## Phase-1 honest scope gaps and future work
- **Immediate encoding (m1-002)**: `mov rax, imm64` not yet in paideia-as encoder set.
  Workaround: caller pre-computes and loads CR4_PAE and CR0_PG_PE values into
  RCX and RAX respectively before calling transition().
- **Far jump parsing (m2-010)**: `ljmp [rsi]` mnemonic parsing not yet implemented.
  Deferred to Phase-1.5 once paideia-as FarJmp encoder is available.
- **Integration with entry path**: _start currently halts (P0-005); transition()
  wiring into the boot flow lands in Phase-1.4+ incrementally.

## Caller discipline
```
RDI ← PML4 base address
RCX ← CR4 value with PAE bit set (0x20)
RAX ← CR0 value with PG|PE bits set (0x80000001)
ECX ← EFER MSR index (0xC0000080)
EDX:EAX ← EFER value with LME bit set (0x00000100 in EAX, 0 in EDX)
RSI ← far address descriptor [reserved for Phase-1.5 ljmp]
```
