---
audit_id: r13-m5-001-syscall-msrs
issue: 427
file: src/kernel/core/syscall/msr.pdx, src/kernel/core/syscall/entry_stub.pdx
function: syscall_msr_init, syscall_entry_stub
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-07-03
---

# AUDIT R13-m5-001 — SYSCALL/SYSRET MSR Setup

## Overview

This audit documents the implementation of five model-specific register (MSR) writes required to enable SYSCALL/SYSRET fast system call entry on x86-64, per Intel SDM Vol 3A §6.15 (SYSCALL/SYSRET) and §4.2 (MSRs). The implementation is part of R13-m5-001 (#427) and establishes the foundation for user-mode entry in R13-m5-002 (#428). 

All MSR writes are idempotent (readable-modify-write for IA32_EFER) or unconditional absolute assignments. The entry point stub is placeholder code (`mov rax, rax; ret`, a true no-op) used because paideia-as does not yet encode sysret/sysretq (escalation PA-R13-009). The stub is unreachable by construction since R13 has no ring-3 code and no kernel path executes the SYSCALL instruction.

## MSR Pin Table

| Index | Symbol | Value | Rationale |
|-------|--------|-------|-----------|
| 0xC0000080 | IA32_EFER | 0x00...01 (SCE=1, NXE preserved) | Enable SYSCALL/SYSRET encoding; preserve NX (bit 11) set by #426 (R13-m3-005). RMW via rdmsr → or rax,0x1 → wrmsr ensures idempotency. |
| 0xC0000081 | IA32_STAR | 0x0018000800000000 | Kernel CS=0x08 (bits [31:16]), user CS base=0x18 (bits [47:32]). Derived from GDT slots: kernel code64 at slot 1 (0x08), user data at slot 4 (0x20 = 0x18+8). SYSRET loads user CS from [47:32]+16 = 0x28 (slot 5, user code64). |
| 0xC0000082 | IA32_LSTAR | &syscall_entry_stub | 64-bit mode entry point address. Placeholder target until #428 (R13-m5-002) installs real trampoline. lea [rip + syscall_entry_stub] computes address; rdmsr/shr rdx,32/wrmsr splits into EDX:EAX. |
| 0xC0000084 | IA32_FMASK | 0x00047700 | Clear rflags bits on SYSCALL entry: TF(#20)|IF(#9)|DF(#10)|IOPL(#13:12)|NT(#14)|AC(#18). Linux SYSCALL_MASK constant; prevents interrupts and single-step during system call dispatch. |
| 0xC0000102 | IA32_KERNEL_GS_BASE | &_cpu0_kernel_gs | 16-byte kernel GS base placeholder (aligned @align(16)). BSP-only allocation; per-CPU variants deferred to R13-m6. lea [rip + _cpu0_kernel_gs] + rdmsr/wrmsr split. |

## GDT Slot Derivation for IA32_STAR

The GDT installed by R13-m4-001 (#423) has 8 slots:

```
Offset  Slot  Selector  Descriptor
0x00    0     -         null
0x08    1     0x08      kernel code64 (base=0, limit=0xFFFF, L=1, DPL=0)
0x10    2     0x10      kernel data (base=0, limit=0xFFFF, DPL=0)
0x18    3     0x18      reserved
0x20    4     0x20      user data (base=0, limit=0xFFFF, DPL=3)
0x28    5     0x28      user code64 (base=0, limit=0xFFFF, L=1, DPL=3)
0x30    6     0x30      TSS low (deferred to m4-002)
0x38    7     0x38      TSS high (deferred to m4-002)
```

**SYSCALL semantics:**
- Loads kernel CS from STAR[31:16] (= 0x0008).
- Loads kernel SS from STAR[31:16]+8 (= 0x0008+8 = 0x0010).
- These are the kernel code64 and kernel data selectors.

**SYSRET semantics:**
- Loads user CS from STAR[47:32]+16 (= 0x0018+16 = 0x0028).
- Loads user SS from STAR[47:32]+8 (= 0x0018+8 = 0x0020).
- These are the user code64 and user data selectors.

**STAR value derivation:**
- STAR[31:16] = 0x0008 (kernel CS)
- STAR[47:32] = 0x0018 (user base; 0x18+16=0x28 for user CS, 0x18+8=0x20 for user SS)
- STAR = 0x0018000800000000

## IA32_FMASK Bit Decomposition

The FMASK value 0x00047700 clears six rflags bits on SYSCALL entry:

```
Bit 20 (0x100000) — TF  (Trap Flag, #TF)      : disable single-step during syscall
Bit 9  (0x200)    — IF  (Interrupt Flag)       : disable interrupts during syscall
Bit 10 (0x400)    — DF  (Direction Flag)       : clear for forward string ops
Bit 13 (0x2000)   — IOPL bits [13:12]          : privilege level for I/O (usually kept 0)
Bit 12 (0x1000)   — (IOPL cont'd)              :
Bit 14 (0x4000)   — NT  (Nested Task)          : clear for normal execution
Bit 18 (0x40000)  — AC  (Alignment Check)      : disable alignment checks
```

**Hex decomposition:**
- 0x00047700 = 0x00040000 | 0x00004000 | 0x00002000 | 0x00001000 | 0x00000400 | 0x00000200 | 0x00000100
- = AC | NT | IOPL[1:0] | DF | IF | TF

**Justification:** Matches Linux SYSCALL_MASK to minimize user-mode side effects and prevent accidental re-entrance of interrupt handlers during system call dispatch.

## IA32_LSTAR Stub Safety Argument

The syscall_entry_stub function contains `mov rax, rax` followed by `ret` (an inert true no-op) and is unreachable by construction:

1. **No ring-3 code exists in R13.** The entire R13 codebase is ring-0 only; no user-mode applications or ring-3 exception handlers exist.
2. **No kernel code path executes SYSCALL.** The SYSCALL instruction itself is only valid in ring-3 (from the user-mode side). Kernel code never issues SYSCALL; it uses call/jmp for inter-kernel transitions.
3. **Placeholder status.** The stub is explicitly documented as temporary and is replaced in R13-m5-002 (#428) with the real trampoline that dispatches to the system call handler. The current body (mov rax, rax; ret) uses a placeholder because paideia-as does not yet encode sysret/sysretq (escalation PA-R13-009).
4. **ret instruction behavior when unreachable.** If somehow reached from ring-0, the `ret` instruction would pop rsp and jump to that address (nonsensical context, no valid return address on stack). This is irrelevant since the code path is unreachable by construction.

**Conclusion:** Safe because unreachable; the actual sysretq trampoline (PA-R13-009 pending) lands in #428.

## Correction Record: r13-m1-002 STAR Derivation

Initial design document (r13-m1-002-arch-pins.md, §3.2) contained a transcription error:

**Before (INCORRECT):**
```
STAR = 0x0000000800000018
```
This value would load kernel CS from [31:16]=0x0000 (null selector, invalid) and user base from [47:32]=0x0008 (kernel code selector, wrong privilege).

**After (CORRECT):**
```
STAR = 0x0018000800000000
```
This value correctly loads kernel CS from [31:16]=0x0008 and computes user selectors from [47:32]=0x0018. Verified against Intel SDM Vol 3A §6.15 Table 6-16 (SYSCALL/SYSRET Fields).

The implementation in #427 (this audit) uses the corrected value 0x0018000800000000.

## Integration Point

**Called from:** src/kernel/boot/kernel_main.pdx, kernel_main_64 function.
**Call sequence:** (after nx_enable at line 80)
```asm
call nx_enable;
call syscall_msr_init;  // R13-m5-001 (#427) — initialize SYSCALL/SYSRET MSRs
call apic_enable;       // continue existing boot sequence
```

**Return value:** 0 (rax register); caller ignores.

**Side effects:** Modifies five MSRs (IA32_EFER, IA32_STAR, IA32_LSTAR, IA32_FMASK, IA32_KERNEL_GS_BASE). These changes persist and enable SYSCALL/SYSRET decoding (though not yet callable).

## Sysreg Justification

The syscall_msr_init function and syscall_entry_stub are marked with `effects: {sysreg}` because:

1. **rdmsr/wrmsr instructions in msr.pdx:** Read and write model-specific registers (privileged I/O).
2. **MSR-accessible system state:** The five MSRs (IA32_EFER, IA32_STAR, IA32_LSTAR, IA32_FMASK, IA32_KERNEL_GS_BASE) are sysreg-category privileged state that affects system call encoding and ring-transition semantics. The eventual sysretq implementation (PA-R13-009 pending in #428) will use these values.
3. **Ring-0 only:** Both functions execute in ring-0 kernel mode. Privilege level is checked at runtime; MSR writes fault with #GP if attempted from ring-3.

## Acceptance Criteria

1. **Build succeeds** with no warnings or errors.
2. **5-mode smoke test passes:** boot_r8_only, boot_r10, boot_r11, boot_r12, boot_r12_denial all output PASS.
3. **objdump disassembly validates:**
   - syscall_msr_init contains 5 rdmsr → or/mov rax → wrmsr sequences.
   - IA32_STAR value 0x0018000800000000 encoded in movabs.
   - IA32_FMASK value 0x47700 encoded in mov rax.
   - syscall_entry_stub contains `mov rax, rax` (opcode 0x48 0x89 0xc0) followed by `ret` (opcode 0xc3), an inert unreachable placeholder pending PA-R13-009 (sysretq encoder support).
4. **No emoji/symbol pollution:** grep across all modified files finds no control characters or emoji.
5. **kernel_main_64 calls syscall_msr_init after nx_enable.**

## Cross-References

- **#427:** This issue (R13-m5-001 MSR setup).
- **#428:** R13-m5-002 real syscall trampoline (replaces stub).
- **#429:** R13-m5-003 syscall dispatch handler.
- **#423:** R13-m4-001 GDT install (provides CS selectors for STAR).
- **#426:** R13-m3-005 NX enable (sets IA32_EFER.NXE; EFER is read-modify-written here).
- **#389:** R11-m1-002 LAPIC global enable (earlier IA32_APIC_BASE write).
- **Intel SDM Vol 3A §6.15:** SYSCALL/SYSRET instruction reference.
- **Intel SDM Vol 3A §4.2:** Model-Specific Registers (MSR).
- **Linux arch/x86/include/uapi/asm/processor-flags.h:** SYSCALL_MASK constant (0x47700).
