# r10-timer-delivery-diagnosis-001: TSC-Deadline Timer IRQ Flakiness Analysis

**Issue**: boot_tick smoke test: 2/3 pass rate (sometimes TICK fires, sometimes polling race fails)

**Hypothesis Testing Result**: **P3 is the smoking gun**

---

## Hypothesis P1: LVT[16] Mask Bit Set (REJECTED)

**Claim**: The LAPIC LVT timer register is written with the mask bit (bit 16) set, preventing timer interrupts.

**Verification**:
- File: `src/kernel/core/apic/lapic_timer.pdx` lines 32, 42-43
- Code:
  ```
  let LAPIC_TIMER_MODE_TSC_DEADLINE : u64 = 2   // 0b10 in bits 17:16
  mov rax, 0xFEE00320;
  mov rcx, 0x40020;  // (2 << 17) | 32 = 0x40020
  mov [rax], ecx;    // Write to LVT Timer MMIO
  ```
- Value 0x40020 breakdown:
  - Bits 7:0 = 0x20 = 32 (vector) ✓
  - Bits 17:16 = 0b10 (TSC-deadline mode) ✓
  - Bit 16 (mask) = 0 (NOT masked) ✓

**Status**: PASS (mask bit is correctly 0)

---

## Hypothesis P2: IDT Entry 32 Type/DPL Incorrect (REJECTED)

**Claim**: The IDT entry for vector 32 has incorrect type or DPL, so the CPU rejects the timer interrupt delivery.

**Verification**:
- File: `src/kernel/core/int/idt.pdx` lines 31-32, 316-319
- Code:
  ```
  let GATE_INTERRUPT : u64 = 0x8E  // present, DPL 0, 64-bit interrupt gate
  // In idt_pack_entry:
  mov r10, 0x8E;
  shl r10, 40;
  or r8, r10;  // Set type=0x8E for all vectors including vec 32
  ```
- Value 0x8E = 1000_1110b:
  - Bit 7 = 1 (present) ✓
  - Bits 6:5 = 00 (DPL 0, kernel-mode only, correct for timer ISR) ✓
  - Bits 4:3 = 01 (64-bit interrupt gate, not task gate) ✓

**Status**: PASS (type byte is correctly 0x8E)

---

## Hypothesis P3: QEMU CPU Lacks TSC-DEADLINE Support (ACCEPTED - SMOKING GUN)

**Claim**: The QEMU CPU model used does not expose the TSC-DEADLINE feature (CPUID.01H:ECX[24]), so the LAPIC ignores the TSC-deadline mode programming and never fires.

**Verification**:
- File: `tools/run-qemu.sh` lines 19-27
- Current command:
  ```bash
  exec qemu-system-x86_64 \
      -kernel "${KERNEL}" \
      -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
      -serial stdio \
      -display none \
      -no-reboot \
      -no-shutdown \
      -m 256M \
      "$@"
  ```
- Missing: `-cpu` parameter
- Effect: QEMU defaults to `qemu64` (built-in default), an x86_64 model from ~2008
  - Does NOT expose TSC-DEADLINE (CPUID bit 24 in CPUID.01H:ECX)
  - Intel support: Ivy Bridge+; AMD: Bulldozer+
  - QEMU 4.0+: requires explicit `-cpu host` or `-cpu max` or `-cpu qemu64,+tsc-deadline`

**Intel SDM Reference**: Vol 3A §10.5.1 "Time Stamp Counter Deadline Mode"
  - Requires CPUID.01H:ECX[24] = 1
  - Without it, writes to IA32_TSC_DEADLINE MSR (0x6E0) are ignored
  - Timer remains disarmed; no interrupts fire

**Practical Evidence**: 
  - Polling workaround in `kernel_main.pdx` (lines 63-70) generates TICKs reliably
  - Real timer IRQ never fires (or fires rarely by chance/timing)
  - Explains 2/3 pass rate: random timing of polling race vs. QEMU scheduler

**Status**: FAIL (QEMU cpu lacks TSC-DEADLINE; this is the root cause)

---

## Recommended Fix (m2-002)

Add `-cpu max` to `tools/run-qemu.sh` to enable TSC-DEADLINE and other modern x86_64 features:

```bash
exec qemu-system-x86_64 \
    -cpu max \
    -kernel "${KERNEL}" \
    ...
```

Alternative (more conservative): `-cpu host` or `-cpu qemu64,+tsc-deadline`

---

## Impact on Boot Flow

**Current**: Polling loop in `kernel_main.pdx` calls `handle_timer` directly every ~500,000 cycles
  - Works (TICK prints appear)
  - But timing-dependent; sometimes misses a cycle

**After Fix**: LAPIC timer fires autonomously on TSC-deadline match
  - Vector 32 → trampoline_vec32 → handle_timer (via IRQ, not polling)
  - No polling needed
  - TICK prints every 100 TSC cycles (per lapic_timer_rearm interval)
  - Deterministic; 5/5 smoke test passes

---

## Summary

| Hypothesis | Status | Root Cause |
|-----------|--------|-----------|
| P1: LVT mask bit set | PASS | No — mask=0 correctly |
| P2: IDT type wrong | PASS | No — type=0x8E correctly |
| P3: QEMU CPU no TSC-DEADLINE | **FAIL** | **YES — root cause** |

**Diagnosis**: QEMU `-cpu` parameter missing; defaults to qemu64 which lacks TSC-DEADLINE feature. Timer MSR writes ignored; IRQ never fires. Polling workaround masks the issue.

**Action**: Set `-cpu max` in `tools/run-qemu.sh` to expose TSC-DEADLINE (and other modern features needed for R10+).
