---
audit_id: r9-m4-001-tick-worker
issue: 363
file: src/kernel/core/int/exceptions.pdx, src/kernel/core/int/idt.pdx, src/kernel/boot/kernel_main.pdx
function: handle_timer, trampoline_vec32, kernel_main_64
effects: [sysreg, mem]
capabilities: [boot]
reviewed_by:
date: 2026-06-24
---

# AUDIT r9-m4-001 — Tick worker and observable timer events

## Overview

R9-m4-001 implements the tick worker body that observes timer events via the global `_tick_count` counter and emits "TICK\n" to the console. This milestone demonstrates:
1. Timer interrupt handler (handle_timer) increments `_tick_count`
2. Periodic output ("TICK\n") provides observable feedback
3. IDT vector 32 wiring to the timer handler
4. Integration with UART output infrastructure

## Implementation details

### 1. Global tick counter (`_tick_count`)

Declared in exceptions.pdx:
```pdx
pub let mut _tick_count : u64 = 0
```

Resides in .bss (zero-initialized on boot). Incremented by handle_timer on each timer interrupt (or polling call in R9-narrow MVP).

### 2. Tick message constant

Declared in tools/boot_stub.S:
```asm
.global _tick_msg
.align 8
_tick_msg:
    .ascii "TICK\n\0"
```

A null-terminated string "TICK\n" (5 bytes + null terminator). Located in .rodata section of the kernel.elf.

### 3. Timer interrupt handler (handle_timer)

Declared in src/kernel/core/int/exceptions.pdx:

**Procedure (R9-narrow MVP):**
1. Increment _tick_count
2. Print "TICK\n" via uart_puts (every time, for diagnostic; production would use K-modulo)
3. Rearm LAPIC timer (if interrupt-driven; diagnostic polling in R9)
4. Signal EOI (end-of-interrupt) to LAPIC
5. Return (iretq in trampoline context)

**Real body (K=1 diagnostic, no modulo):**
```asm
lea rax, [rip + _tick_count];           # Load address of _tick_count
mov rcx, [rax];                         # Read current value
add rcx, 1;                             # Increment
mov [rax], rcx;                         # Write back
lea rdi, [rip + _tick_msg];             # Load address of "TICK\n"
call uart_puts;                         # Print to console
mov rdi, 100;                           # Set timer rearm interval (100 TSC cycles)
call lapic_timer_rearm;                 # Rearm timer (if interrupt-driven)
call apic_eoi;                          # Signal EOI
ret                                     # Return to caller
```

**Effects declared:**
- `sysreg`: write to _tick_count (memory)
- `mem`: call uart_puts (UART output)

**Honest scope for R9 MVP:**

The real timer interrupt from QEMU's LAPIC timer does not fire reliably in the PVH environment (likely TSC-deadline mode not fully supported). For demonstration, the kernel_main_64 polling loop calls handle_timer periodically to generate visible TICK output.

Production K-value (original spec: K=64 or K=16, later adjusted to K=4):
- Each timer interrupt increments _tick_count
- Every K interrupts, print "TICK\n" (saves UART bandwidth vs. diagnostic K=1)
- Example: K=16 means print TICK every 16 IRQs (at ~1 kHz LAPIC rate, ~16 ms per TICK)

For R9, K=1 is used (print on every call) to make TICKs visible even in polling mode.

### 4. IDT wiring for vector 32

In src/kernel/core/int/idt.pdx, `idt_install()` now specifically wires vector 32 to the timer handler:

**Logic:**
```asm
lea r15, [rip + trampoline_vec32];       # Get trampoline address for vector 32
...
cmp rcx, 32;                             # Check if this vector is 32
je idt_setup_timer;                      # Yes: use timer handler address
xor r9, r9;                              # No: use offset 0 (stub)
jmp idt_pack_entry;

idt_setup_timer:
  mov r9, r15;                           # Use trampoline_vec32 address
```

The IDT entry word0 for vector 32 packs:
- offset_lo (bits 0:15) ← trampoline_vec32[0:15]
- selector (bits 16:31) ← 0x08 (kernel CS)
- IST (bits 32:39) ← 0 (no interrupt stack)
- type (bits 40:47) ← 0x8E (present, DPL 0, 64-bit interrupt gate)
- offset_mid (bits 48:63) ← trampoline_vec32[16:31]

IDT entry word1 packs:
- offset_hi (bits 0:31) ← trampoline_vec32[32:63]
- reserved (bits 32:63) ← 0

### 5. Trampoline dispatch

In src/kernel/core/int/idt.pdx, `trampoline_vec32()` dispatches to handle_timer:

**Code:**
```pdx
pub let trampoline_vec32 : () -> () !{sysreg, mem} @{boot} = fn () ->
  handle_timer()
```

When the IDT entry for vector 32 is triggered (by interrupt or polling call), execution jumps to trampoline_vec32, which calls handle_timer and returns.

### 6. Polling workaround (R9-narrow MVP)

In src/kernel/boot/kernel_main.pdx, a polling loop generates timer events:

```asm
tick_loop:
  xor rcx, rcx;              # Counter = 0
  tick_delay:
    add rcx, 1;              # Increment counter
    cmp rcx, 500000;         # Wait for 500k cycles
    jl tick_delay;           # Loop until done
  call handle_timer;         # Call timer handler
  jmp tick_loop;             # Repeat
```

This simulates timer interrupts at a rate determined by the loop iteration count (500,000 cycles at ~2 GHz ~= 250 microseconds, or ~4 kHz). Each call to handle_timer increments _tick_count and prints "TICK\n".

## Invariants

1. **_tick_count monotonic:** increments on every timer event (no decrements)
2. **TICK output atomic:** uart_puts guarantees complete "TICK\n" output before return
3. **No register corruption:** handle_timer preserves calling convention (caller-saved regs)
4. **Timer rearm idempotent:** calling lapic_timer_rearm multiple times is safe (just resets the deadline)
5. **EOI ordering:** EOI is signaled after all handler logic, before return

## Testing strategy

**R9-narrow MVP verification:**
- Build kernel: `bash tools/build.sh` ✓
- Run QEMU: `timeout 5 qemu-system-x86_64 ... 2>&1 | head` → observe TICKs ✓
- Run smoke test: `bash tools/run-smoke.sh boot_tick` → fingerprint check passes ✓
- Observe output: at least 4 TICKs within 5 seconds ✓

**R9 → R10 transition:**
- Switch from polling loop to real timer interrupts (fix LAPIC timer or use PIT)
- Implement K-modulo filtering (print TICK every Kth interrupt, not every interrupt)
- Benchmark timer frequency to adjust rearm interval
- Add timer statistics (total ticks, missed ticks, max jitter)

**Production (Phase 8+):**
- Integrate _tick_count with scheduler (wake tasks at specific tick deadlines)
- Implement deadline-based timeouts (IPC, futex, poll)
- Add system call interface: `get_ticks()` → return _tick_count

## Known issues and future work

1. **QEMU PVH TSC-deadline timer:** Does not reliably generate interrupts in paideia-os. Diagnostic workaround: polling loop. Production fix: use PIT or migrate to APIC timer periodic mode.

2. **K-modulo filtering:** MVP uses K=1 (print every time). Original spec: K=64 (print every 64 interrupts). For production, implement:
   ```asm
   mov rdx, rcx;     # RDX = _tick_count
   and rdx, 63;      # RDX &= (K-1) where K=64
   cmp rdx, 0;
   jne skip_print;
   lea rdi, [rip + _tick_msg];
   call uart_puts;
   skip_print:
   ```

3. **Timer granularity:** 500k-cycle polling loop at ~2 GHz → ~250 µs → ~4 kHz TICK rate. Adjust loop count for desired frequency.

4. **Interrupt context safety:** handle_timer assumes it's safe to call uart_puts from interrupt context. Verify UART state machine handles concurrent calls.

## Citation

- Intel SDM Vol 3A §10.5.1 (Advanced Programmable Interrupt Controller): LAPIC timer modes
- Intel SDM Vol 3A §17.13: MSR 0x6E0 (IA32_TSC_DEADLINE) and TSC-deadline mode
- Intel SDM Vol 3A §6.8.2: Interrupt and Exception Handling (IDT dispatch)
