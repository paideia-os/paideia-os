---
audit_id: r13-m5-002-syscall-trampoline
issue: 428
file: src/kernel/core/syscall/entry.pdx, src/kernel/core/syscall/kernel_stack.pdx, src/kernel/core/syscall/dispatch.pdx
function: syscall_entry, SyscallKernelStack, syscall_dispatch
effects: [sysreg, mem]
capabilities: []
reviewed_by:
date: 2026-07-03
---

# AUDIT R13-m5-002 — SYSCALL Entry Trampoline

## Overview

This audit documents the real SYSCALL entry trampoline that implements the transition from user-mode ring-3 to kernel-mode ring-0 on x86-64, per Intel SDM Vol 3A §6.15 (SYSCALL/SYSRET). The implementation is part of R13-m5-002 (#428) and supersedes the placeholder stub from R13-m5-001 (#427). The trampoline:

1. **Saves user rsp** to a kernel-visible slot (`_saved_user_rsp[0]`).
2. **Loads kernel rsp** from a static BSS array (`_syscall_kernel_stack`).
3. **Preserves ring-transition state** (user RIP in rcx, user RFLAGS in r11, syscall# in rax).
4. **Shuffles register ABI** from SYSCALL convention to SysV C ABI for dispatch.
5. **Calls the syscall dispatcher** (stub in R13-m5-002; real table in R13-m5-003 #429).
6. **Restores ring-transition state** and user rsp.
7. **Executes sysret** to return to user mode.

All three supporting files are introduced here:
- **kernel_stack.pdx:** 16 KiB kernel stack + saved-rsp slot (single-CPU for R13).
- **dispatch.pdx:** Syscall dispatch stub (returns 0; real table in #429).
- **entry.pdx:** Trampoline entry point (registered as IA32_LSTAR by msr.pdx).

R13 simplifications are documented; each deferred feature has an R13-m6 follow-up.

## Register Discipline

### On SYSCALL Entry (SDM Vol 3A §6.15)

| Register | Contents | Note |
|----------|----------|------|
| rax | syscall# | User provides; read first, preserved on stack |
| rdi | arg0 | User provides; C ABI arg0 (Linux convention) |
| rsi | arg1 | User provides; C ABI arg1 |
| rdx | arg2 | User provides; C ABI arg2 |
| r10 | arg3 | User provides; C ABI arg3 (syscall clobbers rcx, so r10 used instead) |
| rcx | return RIP | SYSCALL loads from user code (implicit); preserved on kernel stack |
| r11 | user RFLAGS | SYSCALL loads from user state; preserved on kernel stack |
| rsp | user stack | User RSP; saved to kernel memory before switch |

### ABI Shuffle to SysV C ABI

The syscall_dispatch function signature (5-arg form):
```
syscall_dispatch(rdi=sysno, rsi=arg1, rdx=arg2, rcx=arg3, r8=arg4) -> u64
```

Shuffle sequence (dependency-safe):
```
rdi <- rax         (sysno moved directly; rax → rdi)
rsi <- rdi         (arg0 was in rdi; move to rsi=arg1)
rdx <- rsi         (arg1 was in rsi; already in rdx=arg2)
rcx <- rdx         (arg2 was in rdx; move to rcx=arg3)
r8  <- r10         (arg3 was in r10; move to r8=arg4)
```

### Register Encoding in Trampoline

The trampoline saves/restores state on the kernel stack:

1. **Push rcx** — user RIP saved (line 1 of pushes).
2. **Push r11** — user RFLAGS saved (line 2).
3. **Push rax** — syscall# saved for later pop-to-rdi.
4. **Shuffle** — rsi, rdx, rcx, r8 updated in-place; rdi will be restored via pop.
5. **Pop rdi** — syscall# restored to rdi (C ABI arg0).
6. **Call syscall_dispatch** — returns rax (result).
7. **Pop r11** — user RFLAGS restored (reverse of push r11).
8. **Pop rcx** — user RIP restored (reverse of push rcx).
9. **Sysret** — rcx and r11 now hold user state; rsp restored; sysret executes atomically.

## Kernel Stack Layout (R13 Single-CPU)

### File: kernel_stack.pdx

```
pub let mut _saved_user_rsp : [u64; 1] = uninit @align(8)
pub let mut _syscall_kernel_stack : [u64; 2048] = uninit @align(16)
```

- **_saved_user_rsp[0]:** Single-element array (lands in .bss, accessed via `[rip + _saved_user_rsp]` as base address).
  - At entry: `mov [rip + _saved_user_rsp], rsp` stores user RSP.
  - At exit: `mov rsp, [rip + _saved_user_rsp]` restores user RSP.
  - Size: 8 bytes.
  - Alignment: @align(8) — unnecessary but explicit for clarity.

- **_syscall_kernel_stack[2048]:** 16 KiB kernel stack.
  - Array of 2048 u64 slots = 16384 bytes.
  - Alignment: @align(16) — 16-byte stack alignment required by ABI (base+16).
  - At entry: `lea rsp, [rip + _syscall_kernel_stack + 16384]` loads top of stack.
  - Stack grows downward from top; pushes use downward growth.

### Memory Map

```
+------- (RIP-relative base of .rodata/.bss section)
| _saved_user_rsp[0]           ; 1 u64 (8 bytes)
+------- (offset 8)
| _syscall_kernel_stack[0]     ; start of 16 KiB array
+------- (offset 8 + 16384 = 16392)
| _syscall_kernel_stack[2047]  ; end of 16 KiB array (last qword)
+------- (top of kernel stack, RSP loaded here)
```

## Dispatcher Stub (R13-m5-002)

### File: dispatch.pdx

```rust
pub let syscall_dispatch : (u64, u64, u64, u64, u64) -> u64 !{} @{} =
  fn (syscall_num: u64) (arg1: u64) (arg2: u64) (arg3: u64) (arg4: u64) -> unsafe {
    // ...
    block: {
      xor rax, rax;
      ret
    }
  }
```

- **Signature:** Five u64 args (C ABI: rdi, rsi, rdx, rcx, r8); returns u64 in rax.
- **Body:** `xor rax, rax` sets rax = 0; `ret` returns.
- **Justification:** Stub for R13-m5-002 (no ring-3 code, never invoked). Real table installed in R13-m5-003 (#429).
- **Return value:** 0 (harmless in R13; maps to SYS_EXIT_THREAD, a no-op if somehow reached).

## Entry Trampoline (R13-m5-002)

### File: entry.pdx

```asm
syscall_entry:
  // Switch stack: save user rsp, load kernel rsp top
  mov [rip + _saved_user_rsp], rsp
  lea rsp, [rip + _syscall_kernel_stack + 16384]

  // Preserve SYSCALL-clobbered ring-transition state + syscall#
  push rcx
  push r11
  push rax

  // Shuffle SYSCALL ABI -> SysV C ABI (rax->rdi restored via pop below)
  mov r8, r10
  mov rcx, rdx
  mov rdx, rsi
  mov rsi, rdi
  pop rdi

  // Dispatch (result in rax)
  call syscall_dispatch

  // Restore ring-transition state
  pop r11
  pop rcx
  mov rsp, [rip + _saved_user_rsp]

  // sysret: encoded 48 0F 07 (sysretq in 64-bit mode).
  // RIP <- rcx, RFLAGS <- r11 with reserved bits, ring 0 -> 3.
  sysret
```

### Instruction-Level Comments

| Line | Instruction | Effect | Note |
|------|-------------|--------|------|
| 1 | `mov [rip + _saved_user_rsp], rsp` | Save user RSP to kernel memory | RIP-relative addressing (PA10-006w). Atomicity: single MOV, not split. |
| 2 | `lea rsp, [rip + _syscall_kernel_stack + 16384]` | Load kernel RSP to stack top | 16384 = 2048 * 8 (top of 16 KiB array). |
| 4 | `push rcx` | Preserve user RIP | On kernel stack, grows downward. |
| 5 | `push r11` | Preserve user RFLAGS | |
| 6 | `push rax` | Preserve syscall# | Will be popped into rdi below. |
| 8 | `mov r8, r10` | arg3: r10 → r8 | Shuffle to C ABI. |
| 9 | `mov rcx, rdx` | arg3: rdx → rcx | Shuffle to C ABI. |
| 10 | `mov rdx, rsi` | arg2: rsi → rdx | Shuffle to C ABI (already correct, but explicit). |
| 11 | `mov rsi, rdi` | arg1: rdi → rsi | Shuffle to C ABI. |
| 12 | `pop rdi` | arg0: rax (from push) → rdi | Restores syscall# as sysno arg. |
| 14 | `call syscall_dispatch` | Call dispatcher | Stack grows; return address pushed by call. |
| 17 | `pop r11` | Restore user RFLAGS | Reverse of push r11. |
| 18 | `pop rcx` | Restore user RIP | Reverse of push rcx. |
| 19 | `mov rsp, [rip + _saved_user_rsp]` | Restore user RSP | Load from kernel memory. |
| 21 | `sysret` | Return to user mode | Encoded 48 0F 07; RIP <- rcx, RFLAGS <- r11, ring 0 -> 3. |

### Sysret Encoding Confirmation

**paideia-as encoder support:**
- Mnemonic `sysret` is listed in `unsafe_walker.rs:94`.
- Encoder function `encode_sysret()` in `encode_instruction.rs` generates `48 0F 07` (REX.W prefix + two-byte opcode).
- Verified at pinned rev `ae6039b46cef060c85745ac559b9883df7e5d884`.

## R13 Simplifications and Deferred Features

### 1. No swapgs

**R13:** Single-CPU; GS_BASE register (IA32_KERNEL_GS_BASE) is set but not switched.

**R13-m6:** Multi-CPU support will add `swapgs` to swap GS.base with IA32_KERNEL_GS_BASE at entry/exit.

### 2. No KPTI CR3 Switch

**R13:** No runtime CR3 flip between kernel and user page tables. R13-m3 (#425) does not wire dynamic CR3 switching.

**R13-m6 or R14:** KPTI mitigation (CR3 switch) deferred; adds vulnerability window but R13 has no unprivileged code anyway.

### 3. Single-CPU Stack

**R13:** _syscall_kernel_stack is a single 16 KiB array. Data race if another CPU tries to use it simultaneously.

**R13-m6:** Per-CPU allocation via GS_BASE offset register (IA32_KERNEL_GS_BASE + per-CPU offset).

### 4. No User RSP Validation

**R13:** No bounds checking on user RSP before save. Assumes user stack is valid (no triple-fault mitigation).

**R13-m6 or R14:** User RSP validation (e.g., canonical-form check for x86-64) deferred.

## Effects Widening on Dispatch Replacement (#429)

The current syscall_entry signature is:
```
pub let syscall_entry : () -> () !{sysreg, mem} @{}
```

When #429 (R13-m5-003) installs the real 13-entry syscall table, syscall_dispatch's effects may expand (e.g., `effects: {sysreg, mem, device}`), causing the `effects` set of syscall_entry to widen correspondingly. This is expected; the trampoline's `effects` will be re-audited at that point.

## Acceptance Criteria

1. **Build succeeds** with no warnings or errors.
2. **5-mode smoke test passes:** boot_r8_only, boot_r10, boot_r11, boot_r12, boot_r12_denial all output PASS.
   - Trampoline is dead code (no ring-3 in R13); smoke tests do not execute it.
   - Smoke tests verify that kernel boots and LAPIC timer fires (per R13-m5 bundle goal).
3. **objdump disassembly validates:**
   - syscall_entry: `mov QWORD PTR [rip+0x...], rsp` (direct stack store), `lea rsp, [rip+0x...]`, pushes, shuffle, `call`, pops, `mov rsp, [rip+0x...]`, `sysret` (48 0f 07).
   - syscall_dispatch: `xor rax, rax`, `ret`.
   - Sysret opcodes: 48 0f 07 (confirmed by paideia-as encoder).
4. **syscall_msr_init's LSTAR write** now points to `syscall_entry` (verified via `objdump -d build/kernel.elf | grep -A5 'lea.*<syscall_entry>'`).
5. **No emoji/symbol pollution:** grep across all modified files finds no control characters or emoji.
6. **IA32_LSTAR MSR initialized** by kernel_main_64 -> syscall_msr_init -> wrmsr (line 49 in msr.pdx).

## Cross-References

- **#427 (R13-m5-001):** MSR setup (this issue depends on #427; #427 stub is superseded here).
- **#428 (R13-m5-002):** This issue. Real trampoline implementation.
- **#429 (R13-m5-003):** Real 13-entry syscall table (replaces dispatch stub).
- **#423 (R13-m4-001):** GDT install (provides CS selectors for STAR/SYSRET).
- **#425 (R13-m3-002):** Paging setup (KPTI CR3 switch deferred to R13-m6).
- **#426 (R13-m3-005):** NX enable (IA32_EFER read-modify-written by msr_init).
- **PA-R13-009 (paideia-as #922):** WITHDRAWN. sysret mnemonic IS supported (this audit confirms).
- **Intel SDM Vol 3A §6.15:** SYSCALL/SYSRET instruction reference.
- **Intel SDM Vol 3A §4.2:** Model-Specific Registers (MSR).
- **Linux arch/x86/include/asm/entry_64.S:** entry_SYSCALL_64 reference implementation.

## Correction Record: PA-R13-009 Withdrawn

**Previous claim (r13-m5-001 audit):**
- "paideia-as does not yet encode sysret/sysretq (escalation PA-R13-009)."
- Stub body was `mov rax, rax` (placeholder) because sysret was believed missing.

**Current status (r13-m5-002 audit, 2026-07-03):**
- sysret mnemonic IS fully supported in paideia-as at pinned rev ae6039b.
- Encoder: `encode_sysret()` in `crates/paideia-as-encoder/src/encode_instruction.rs`.
- Encoding: `48 0F 07` (REX.W prefix + two-byte opcode; correct for 64-bit mode).
- Entry point: unsafe_walker.rs:94 recognizes `sysret` as a mnemonic.

**Resolution:**
- paideia-as issue #922 (PA-R13-009 escalation) is **withdrawn as invalid**.
- The original report in paideia-os #427 was based on a faulty workerbee probe; corrected here.
- entry_stub.pdx (placeholder with `mov rax, rax`) is DELETED in this issue.
- Real syscall_entry (with sysret) is installed as IA32_LSTAR target.

## Security Considerations (Informational)

1. **Timing-side-channel risk:** sysret does not serialize. KPTI mitigation (with RSB flushing) is deferred to R13-m6+.
2. **User RSP validation:** No canonical-form check. Assumption: user stack is valid (R13 has no actual user code).
3. **Multi-CPU race:** _saved_user_rsp is single-element, not per-CPU. Multi-CPU load of this code = data race.

These are noted as R13 simplifications, documented in design/audit/entries/.

## Verification Checklist

- [X] sysret encoder support confirmed (paideia-as ae6039b).
- [X] kernel_stack.pdx: 16 KiB stack + saved-rsp slot (option b: array form for .bss placement).
- [X] dispatch.pdx: stub dispatcher (xor rax, rax; ret).
- [X] entry.pdx: trampoline with all register shuffles and sysret.
- [X] msr.pdx: updated reference from syscall_entry_stub to syscall_entry.
- [X] entry_stub.pdx: DELETED via git rm.
- [X] r13-m5-001-syscall-msrs.md: correction record added (PA-R13-009 withdrawn).
- [X] paideia-as #922: closed as invalid (see correction record).
- [ ] Build test (to be run).
- [ ] 5-mode smoke test (to be run).
- [ ] objdump validation (to be run).
