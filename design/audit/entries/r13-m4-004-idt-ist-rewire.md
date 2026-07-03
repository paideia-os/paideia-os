# R13-m4-004: IDT Rewire with IST Fields for DF/NMI/MC/PF

**Issue:** [#426](https://github.com/snunez-cortex/paideia-os/issues/426)  
**Milestone:** r13-m4 (Exception Stack Segregation)  
**Phase:** 13 / Fault Tolerance & Isolation  
**Date:** 2026-07-03  
**Status:** Implemented

## Justification

Certain x86-64 exceptions (Double Fault, Non-Maskable Interrupt, Machine Check, Page Fault) require execution on known-good stacks even if user RSP is corrupted. The Interrupt Stack Table (IST) in the Task State Segment (TSS) allows the CPU to automatically switch to a dedicated stack on exception delivery.

Per Intel SDM Vol 3A §6.14.1, the IDT gate descriptor includes an IST field (bits 2:0 of byte 4) that selects one of 7 dedicated stacks in the TSS. IST=0 means no stack switch (use current RSP); IST=1..7 select TSS.ist[1]..ist[7].

For architectural robustness:
- **vec 8 (DF)**: IST=1 (dedicated double-fault stack)
- **vec 14 (PF)**: IST=1 (reuse DF stack; faults during DF recovery are terminal)
- **vec 2 (NMI)**: IST=2 (dedicated NMI stack)
- **vec 18 (MC)**: IST=3 (dedicated machine-check stack)

All other vectors use IST=0 (no stack switch; assumes user RSP corruption is not a hazard).

## Gate Descriptor Format

Per Intel SDM Vol 3A §6.14.1, a 64-bit interrupt gate occupies 16 bytes:

```
Bytes [0..1]:  Offset[15:0]
Bytes [2..3]:  Segment Selector (0x08 = kernel CS)
Byte [4]:      IST field (bits 2:0) + reserved (bits 7:3 = 0)
Byte [5]:      Type-Attr = P|DPL|Type (0x8E = present, DPL=0, interrupt gate)
Bytes [6..7]:  Offset[31:16]
Bytes [8..15]: Offset[63:32] + reserved(32 bits = 0)
```

In memory (little-endian), this packs into two u64 words:
- **word0**: Offset[15:0] | (Selector << 16) | (IST << 32) | (Type << 40) | (Offset[31:16] << 48)
- **word1**: Offset[63:32] | (reserved << 32)

IST occupies bits [32:39] of word0 (byte 4 in memory).

## Implementation

In `src/kernel/core/int/idt.pdx`, after the main 256-vector IDT population loop, invoke `idt_apply_ist_fields()` to rewrite the IST field for the four critical vectors.

Each entry is 16 bytes from _idt_storage base:
- vec 2: offset = 2 * 16 = 32
- vec 8: offset = 8 * 16 = 128
- vec 14: offset = 14 * 16 = 224
- vec 18: offset = 18 * 16 = 288

The function reads word0, masks out byte [4], then ORs in the target IST value:
```asm
mov r10, [base + offset]      ; read word0
mov r11, 0xFFFFFFFF00FFFFFF   ; mask to clear byte 4
and r10, r11                  ; r10 &= mask
or  r10, IST_value << 32      ; set new IST
mov [base + offset], r10      ; write back
```

Why qword masking instead of byte store? The paideia-as encoder may not support `mov byte [addr], imm8`, so we read-modify-write at qword granularity. This is safe because we operate on the first qword only (no adjacent gate interference).

## Invariants

1. **IST rewiring happens after all 256 gates are initialized.** The main loop writes IST=0 for all vectors; the rewiring function overwrites byte [4] for the target vectors.

2. **IST values are hardcoded per vector.** No dynamic selection; each vector has a fixed IST index.

3. **TSS ist[] population is deferred.** This module only rewires the IDT gates. The TSS.ist[1..3] stacks are initialized in r13-m4-002 (blocked on paideia-as PA-R13-001 TSS descriptor encoding).

4. **Vectors 8 and 14 share IST=1.** This is intentional: a page fault during double-fault handling is fatal, and reusing the same stack simplifies isolation strategy.

## Non-Invariants

- **TSS.ist[] not yet populated:** The IST indexes are now wired in the IDT, but the TSS does not yet reference actual stack addresses. This will be populated in r13-m4-002.
- **No boot regression expected:** IST fields only affect exception delivery if an exception fires. The boot smoke tests do not trigger DF/NMI/MC/PF, so runtime behavior is unchanged.
- **Byte-order assumption:** This code assumes little-endian x86-64 memory layout (standard for all Intel targets).

## Verification

1. **Build:** Verify `idt_apply_ist_fields` symbol is present in kernel.elf.
2. **Smoke tests:** Run all 5 boot smoke tests; all must remain byte-identical (no exceptions fired).
3. **Symbol inspection:** Use nm and objdump to confirm the function is linked.

## Cross-References

- **r13-m4-001 (ISR trampolines):** Each exception vector dispatch occurs through a trampoline that saves registers and calls a typed handler. IST stack switch happens transparently via CPU hardware.
- **r13-m4-002 (TSS ist[] population):** Blocked on paideia-as PA-R13-001 (TSS descriptor support). Once TSS is initialized, each ist[] entry points to a 4KB stack allocated from early free memory.
- **r13-m4-003 (IST stack allocation & layout):** Defines the physical layout and guard pages for the three IST stacks (DF/PF, NMI, MC).
- **Intel SDM Vol 3A §6.14.1:** Gate descriptor layout.
- **Intel SDM Vol 3A §7.7:** Interrupt handling with IST.

## Design Trade-Offs

**Per-Vector IST over Global IST:** We could use a single IST for all exceptions, but separating NMI (IST=2) from MC (IST=3) allows independent analysis if both fire. DF and PF share (IST=1) to reduce stack allocation overhead (both are data-structure corruption handlers).

**Qword Masking over Byte Store:** If paideia-as 0.7.0+ adds `mov byte [addr], imm8`, we can simplify to direct byte stores. Qword masking is safe but adds a mask constant per vector.

**IST Rewiring Post-Loop over Per-Vector IST in Loop:** The loop could check vector number and compute IST on-the-fly. Post-loop rewiring is clearer for auditing (all IST assignments in one place) and avoids branch overhead in the inner loop.

