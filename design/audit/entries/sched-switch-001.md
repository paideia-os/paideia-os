---
audit_id: sched-switch-001
issue: 239
file: src/kernel/core/sched/switch.pdx
function: sched_switch_regs
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT sched-switch-001 — context-switch register save/restore (R4.5-003)

## Justification
The context switch is the single point where one thread's CPU register state is
saved and another's is restored. It is inherently unsafe: it reads and writes
raw TCB memory at fixed byte offsets and rewrites RSP, RFLAGS, and RIP. A single
unsafe block keeps the save/restore atomic for audit purposes — there is no
intermediate observable state in which the CPU is "between" two TCBs.

Citation: Intel SDM Vol 3A §6.14.5 "Switching Stacks in IA-32e Mode" (stack
switching and IST semantics under long mode). **Verification TODO** — confirm
section number against the current SDM revision.

## Intended sequence (canonical, 23 instructions)
SAVE into `from_tcb` (base in RDI), at TCB offsets from tcb.pdx:
1. `mov [rdi+0x00], rbx`  — regs[0]
2. `mov [rdi+0x08], rbp`  — regs[1]
3. `mov [rdi+0x10], r12`
4. `mov [rdi+0x18], r13`
5. `mov [rdi+0x20], r14`
6. `mov [rdi+0x28], r15`
7. `pushfq`
8. `pop rax; mov [rdi+0x88], rax`  — RFLAGS (offset 136)
9. `mov [rdi+0x98], rsp`           — RSP
10. `lea rax,[rip]; mov [rdi+0x80], rax` — RIP (offset 128)

RESTORE from `to_tcb` (base in RSI): symmetric reloads of RBX/RBP/R12–R15,
`mov rsp,[rsi+0x98]`, build the iret frame (SS, RSP, RFLAGS, CS, RIP from the
TCB), then `iretq`.

## Phase-4 honest scope gaps
- **Base+displacement memory operands** (`mov [rdi+0x80], rbp`): not in the
  paideia-as 0.6.0 encoder set. Gates the entire save/restore body.
- **`iretq` encoder**: not yet implemented.
- Current implementation emits the register-resident placeholder `mov rax, rax`
  and performs the `current_tcb` bookkeeping in the typed surface.

## Caller discipline
```
RDI ← from_tcb base address
RSI ← to_tcb base address
```
After return, `current_tcb` holds `to_tcb`.

## Verification (when encoders land)
```bash
./tools/paideia-as build --emit elf64 src/kernel/core/sched/switch.pdx -o switch.o
objdump -d switch.o   # expect 11 save movs, 11 restore movs, one iretq
```
Behavioral test (R4.5-008): alternate-switch between two TCBs printing distinct
banners; verify alternation in the UART log.
