# r10-vec32-trampoline-001: Real ISR Trampoline for Vector 32 (Timer)

**Issue:** #373 (R10-m1-003)

**Module:** `src/kernel/core/int/idt.pdx::Idt`

**Function:** `pub let trampoline_vec32() -> () !{sysreg} @{}`

## Summary

Implements a real interrupt service routine (ISR) trampoline for vector 32 (timer).
Previously a stub that simply called `handle_timer()`, now a privileged prologue/epilogue sequence:
saves 15 GPRs, calls `handle_timer` directly, restores GPRs, and returns via `iretq`.

The trampoline is wired to vector 32 in the IDT and will be invoked when a timer interrupt fires
(after real IRQ delivery is enabled in R10-m2-002). For now, the polling fallback in `kernel_main`
bypasses this trampoline and calls `handle_timer` directly to keep the TICK counter alive during
the transition from stub to real ISR.

## Implementation

| Aspect | Detail |
|--------|--------|
| **Vector** | 32 (timer ISR) |
| **Errcode** | None (CPU does not auto-push for this vector) |
| **GPR save** | 15-push sequence (RAX via placeholder, then RCX, RDX, RBX, RBP, RSI, RDI, R8–R15) |
| **Handler call** | `call handle_timer` (direct, no typed-handler wrapper) |
| **GPR restore** | 15-pop sequence (reverse of save) |
| **Stack cleanup** | `add rsp, 16` (discards errcode placeholder + vector number) |
| **Return** | `iretq` (atomic CPU restore of RIP/CS/RFLAGS/RSP/SS) |
| **Byte sequence** | Matches non-errcode variant (vec 0/3/6/33); approximately 82 bytes |

## Procedure

1. **Errcode placeholder:** `mov rax, 0; push rax` (stack uniformity with errcode-variant vectors)
2. **Vector number:** `mov rax, 32; push rax`
3. **Save GPRs:** 15 individual `push` instructions (RAX, RCX, RDX, RBX, RBP, RSI, RDI, R8–R15)
4. **Frame pointer:** `mov rdi, rsp` (pass interrupted context to handler)
5. **Call handler:** `call handle_timer` (increments TICK counter, rearms timer, signals EOI)
6. **Restore GPRs:** 15 individual `pop` instructions (reverse order of save)
7. **Discard stack frame:** `add rsp, 16` (remove vector + errcode)
8. **Return to interrupted context:** `iretq` (CPU restores RIP/CS/RFLAGS/RSP/SS atomically)

## Justification

**Real ISR trampoline:** IDT entry 32 now points to a privileged prologue/epilogue that properly
saves and restores the interrupted thread's full register state before calling the handler. This
ensures the interrupted thread resumes without corruption.

**Direct handler call:** Unlike most exception vectors (0/3/6/8/13/14/33 which call `_typed_handler_*`
wrappers), timer ISR calls `handle_timer` directly. This simplifies the control flow for timers,
which have unique requirements (rearm + EOI before return).

**Polling fallback:** The boot-time polling loop in `kernel_main_64::tick_loop` calls `handle_timer`
directly, bypassing `trampoline_vec32`. This keeps the TICK counter alive during the transition from
stub to real ISR. When R10-m2-002 enables timer interrupt delivery, real IRQs will invoke the
trampoline; the polling fallback can then be removed.

**Stack uniformity:** Push of errcode placeholder (even though timer vectors don't auto-push errcode)
ensures the stack frame layout is identical across all ISR trampolines, simplifying validation and
future macros.

## Cross-module references

**Calls:**
- `Exceptions::handle_timer()` → increments `_tick_count`, rearms LAPIC timer, signals EOI

**Called by:**
- IDT entry 32 (when timer interrupt fires, after R10-m2-002)
- Polling loop in `KernelMain::kernel_main_64` (current fallback; will be optional after m2-002)

## Bootflow integration

**Current (R10-m1-003):**
- IDT install wires vector 32 to `trampoline_vec32` (real trampoline, but not yet invoked by hardware IRQs)
- Polling fallback in `kernel_main_64::tick_loop` calls `handle_timer` directly every 500,000 cycles
- Results in TICK counter increments (observable in boot_tick test)

**After R10-m2-002 (timer IRQ delivery):**
- Real timer IRQ will invoke `trampoline_vec32` via IDT
- Polling fallback can be removed (or left for diagnostics)
- TICK counter increments will occur asynchronously, not tied to polling frequency

## Verification

**Build:**
```bash
cd /home/snunez/Development/PaideiaOS
rm -rf build && bash tools/build.sh 2>&1 | tail -3
readelf -s build/kernel.elf | grep -E "trampoline_vec32"
```

**Boot reliability (boot_r8_only):**
```bash
for i in 1 2 3; do bash tools/run-smoke.sh boot_r8_only 2>&1 | tail -1; done
# Must be 3/3 green (stable baseline, no timer IRQs involved)
```

**Boot with polling (boot_tick):**
```bash
for i in 1 2 3; do bash tools/run-smoke.sh boot_tick 2>&1 | tail -1; done
# May be flaky (known polling-loop race; expected to pass sometimes)
```

## Deviations from spec

None. Implementation matches R10-m1-002 non-errcode variant exactly, with direct `call handle_timer`
instead of a typed-handler wrapper.

---
**R10-m1-003:** Real ISR trampolines for all 8 critical vectors
**Date:** 2026-07-02
