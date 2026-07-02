---
audit_id: r10-m3-003-fabricate-frame
issue: 379
file: src/kernel/core/sched/frame.pdx
function: fabricate_iret_frame
effects: [mem]
capabilities: [sched]
reviewed_by:
date: 2026-07-02
status: complete
---

# AUDIT R10-m3-003 — Preemption iretq frame fabrication (COMPLETE)

## Issue

R10-m3-003 (#379): Implement fabricate_iret_frame(target_stack, target_rip, target_rsp) -> () to construct a 40-byte iretq frame on a target task's kernel stack for context restoration during preemption (timer interrupt, etc.).

## Implementation

Frame construction for x86-64 protected-mode iretq instruction:

```pdx
pub let fabricate_iret_frame : (u64, u64, u64) -> () !{mem} @{sched} =
  fn (target_stack: u64, target_rip: u64, target_rsp: u64) -> unsafe {
    effects: { mem },
    capabilities: { sched },
    justification: "R10 m3-003: build 40-byte iretq frame (SS/RSP/RFLAGS/CS/RIP) on target task kernel stack for preemption. Frame format per Intel SDM Vol 3A §6.14.1. Descending writes from target_stack: [rdi-8]=SS, [rdi-16]=RSP, [rdi-24]=RFLAGS, [rdi-32]=CS, [rdi-40]=RIP.",
    block: {
      ; RDI = target_stack (top-of-stack for target task)
      ; RSI = target_rip
      ; RDX = target_rsp (== target_stack for MVP)

      ; Write from high to low addresses:
      mov rax, 0x10
      mov [rdi - 8], rax            ; SS = 0x10 (kernel data segment)
      mov [rdi - 16], rdx           ; RSP = target_rsp
      mov rax, 0x202
      mov [rdi - 24], rax           ; RFLAGS = 0x202 (IF=1, reserved bit 1)
      mov rax, 0x08
      mov [rdi - 32], rax           ; CS = 0x08 (kernel code segment)
      mov [rdi - 40], rsi           ; RIP = target_rip
      ret
    }
  }
```

## Frame Layout

Intel SDM Vol 3A §6.14.1 iretq frame (64-bit protected mode):

```
[rsp + 32] = SS      (offset -8 relative to target_stack)
[rsp + 24] = RSP     (offset -16 relative to target_stack)
[rsp + 16] = RFLAGS  (offset -24 relative to target_stack)
[rsp + 8]  = CS      (offset -32 relative to target_stack)
[rsp + 0]  = RIP     (offset -40 relative to target_stack)
```

Total: 40 bytes (5 * 8-byte slots, though only 2 bytes of SS/CS used).

## Arguments

- RDI (target_stack): Top-of-stack address where frame is constructed (descends from here)
- RSI (target_rip): Instruction pointer to resume execution
- RDX (target_rsp): User-mode RSP to restore (== target_stack for MVP; may differ for preemption during syscalls)

## Segment Selectors

- CS = 0x08 (kernel code segment, Ring 0)
- SS = 0x10 (kernel data segment, Ring 0)

Fixed MVPvalues for kernel-context preemption. User-mode return would use Ring 3 selectors (CS=0x1B, SS=0x23).

## RFLAGS Value

- 0x202 = IF (Interrupt Flag, bit 9) | reserved bit 1
  - IF=1: interrupts enabled after iretq
  - Bit 1 reserved (always 1 in RFLAGS)

## Use Case

Invoked by the timer interrupt handler (or other preemption trigger) to construct the resumption frame before iretq'ing back to user code:

```
handle_timer:
  ...save interrupt context...
  ; Select target task to preempt to
  ; Build frame on its kernel stack:
  mov rdi, target_stack_top
  mov rsi, target_code_address
  mov rdx, target_stack_pointer
  call fabricate_iret_frame
  mov rsp, rdi              ; switch to target's stack
  iretq                     ; restore context from frame
```

## Verification

- Symbols present in kernel.elf: fabricate_iret_frame
- Boot path functional: boot_r8_only 3/3 passes (no functional change to boot yet; wiring to interrupt handler deferred to m5)
- Frame format matches Intel SDM specification

## References

- Intel SDM Vol 3A §6.14.1 "Return from an Interrupt or Exception"
- Intel SDM Vol 3A §6.14.5 "Switching Stacks in IA-32e Mode"
- R10-m3-001 sched_switch_regs (complementary context switch mechanism)
