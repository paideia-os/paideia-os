# R11-m1-001 Preflight Audit & Preemption Frame Pinning

**Issue**: #388  
**Phase**: R11-m1 (Preemption scaffold verification + frame layout + TCB budget)  
**Status**: In Progress  
**paideia-as**: fe2293b+ (PA-R10-001 all shipped)

---

## 1. R10 Timer State Audit

### 1.1 LAPIC Timer Register Configuration

**File**: `src/kernel/core/apic/lapic_timer.pdx`

| Register | Address | Value | Purpose |
|----------|---------|-------|---------|
| LVT Timer | 0xFEE00320 | 0x20020 | Periodic mode + vector 32 |
| Divide Configuration | 0xFEE003E0 | 0xB | Divide-by-1 (no division) |
| Timer Initial Count | 0xFEE00380 | Variable | Reload counter per init |
| IA32_TSC_DEADLINE MSR | 0x6E0 | N/A (periodic) | TSC-deadline (QEMU TCG N/A) |

**Finding**: LVT Timer correctly configured for periodic mode:
- Bits [7:0] = 32 (vector 32 for timer interrupt)
- Bits [17:16] = 0b01 (periodic mode)
- Divisor = 0xB (divide by 1, full bus clock)

### 1.2 ISR Delivery Verification

**File**: `src/kernel/core/int/exceptions.pdx` lines 107–140

**Finding**: Timer ISR (`handle_timer`) **is delivered via real IRQ**, not polling:
- Handler defined at lines 124–140
- Increments `_tick_count` global (line 130)
- Prints "TICK\n" diagnostic (line 134)
- Rearms LAPIC timer via `lapic_timer_rearm` (line 136)
- Signals EOI to LAPIC (line 137)
- Returns (line 138); trampoline performs `iretq`

**Calling context** (from IDT):
- Trampoline `trampoline_vec32` (file `src/kernel/core/int/idt.pdx` lines 195–213)
  calls `handle_timer` directly (no wrapper)
- CPU delivers vector 32 → trampoline → handler

### 1.3 STI Timing Relative to TCB Init

**File**: `src/kernel/boot/kernel_main.pdx` lines 47–50

**Sequence**:
1. `uart_init` — Initialize UART
2. `idt_install` — Install IDT + load IDTR
3. `apic_enable` — Enable LAPIC global bit
4. `lapic_timer_init` — Program LAPIC timer (periodic mode, vector 32)
5. **`sti` — Enable interrupts** (line 9 of block; corresponds to source line ~45)
6. Infinite `hlt` loop (line 10)

**Finding**: `sti` executes **after** all interrupt scaffolds initialized.
- Per-CPU TCB would be initialized before `sti` in R11+ scheduling context
- Timer fires while CPU halted; `handle_timer` runs at ring 0 (kernel context)

**Result**: ✓ Timer state audit complete; ready for preemption integration.

---

## 2. Preemption Frame Layout (Pinned)

### 2.1 Trampoline Behavior (R10-m1-002/003)

**File**: `src/kernel/core/int/idt.pdx` lines 72–234 (all 8 trampolines)

Each trampoline's prologue (before handler call):

```
(Non-errcode vectors 0, 3, 6, 32, 33):
  mov rax, 0; push rax            # Errcode placeholder
  mov rax, <vector>; push rax     # Vector number

(Errcode vectors 8, 13, 14):
  mov rax, <vector>; push rax     # Vector (CPU already pushed errcode)
  [Note: CPU-pushed errcode sits below vector on stack]
```

Then all trampolines:
```
  push rax; push rcx; push rdx; push rbx; push rbp
  push rsi; push rdi; push r8; push r9; push r10
  push r11; push r12; push r13; push r14; push r15
  mov rdi, rsp                    # RDI = frame pointer (passed to handler)
  call <handler>
  <epilogue: pop all 15, add rsp,16, iretq>
```

**Finding**: Trampoline saves **15 GPRs** (all except RSP, which is implicit in CPU frame).

### 2.2 Canonical Preempt-Frame Layout (Post-Trampoline)

On entry to `handle_timer`, the kernel stack contains:

```
Offset (bytes)  | Width | Saved Register | Purpose
================|=======|================|=========================================
    0           |  8    | errcode/0      | Placeholder or CPU-pushed errcode
    8           |  8    | vector (32)    | Interrupt vector
   16           |  8    | RAX            | General-purpose register (trampoline-saved)
   24           |  8    | RCX            | General-purpose register
   32           |  8    | RDX            | General-purpose register
   40           |  8    | RBX            | General-purpose register
   48           |  8    | RBP            | Base pointer
   56           |  8    | RSI            | Source index
   64           |  8    | RDI            | Destination index
   72           |  8    | R8             | General-purpose register
   80           |  8    | R9             | General-purpose register
   88           |  8    | R10            | General-purpose register
   96           |  8    | R11            | General-purpose register
  104           |  8    | R12            | General-purpose register
  112           |  8    | R13            | General-purpose register
  120           |  8    | R14            | General-purpose register
  128           |  8    | R15            | General-purpose register
  136           |  8    | RIP            | CPU-pushed instruction pointer
  144           |  2    | CS             | CPU-pushed code segment
  146           |  6    | (padding)      | Alignment within u64 slot
  152           |  8    | RFLAGS         | CPU-pushed flags register
  160           |  8    | RSP (user)     | CPU-pushed stack pointer (if ring transition)
  168           |  2    | SS             | CPU-pushed stack segment
  170           |  6    | (padding)      | Alignment
```

**Total trap-frame size**: 176 bytes (22 u64 slots + 2 u16 segments).

**Key properties**:
- Errcode/vector: 2 × 8 = 16 bytes
- Trampoline-saved GPRs: 15 × 8 = 120 bytes
- CPU-pushed frame (RIP/CS/RFLAGS/RSP/SS): 5 × 8 = 40 bytes (with alignment)
- **Total**: 176 bytes

### 2.3 Preemption Strategy (In-Place Frame Rewrite)

**Decision**: For R11 preemption, use **in-place trap-frame rewrite** (xv6 style), **not** `fabricate_iret_frame`:

1. On timer interrupt, `handle_timer` increments budget counter (or checks budget).
2. If preemption needed:
   - Rewrite trap frame in place: update RIP to point to next task's entry
   - Modify RBP/RSP/other registers to match target TCB state
   - Return from handler; trampoline `iretq` restores modified frame
3. No need for separate frame allocation; frame sits on kernel stack.

**Rationale**:
- Simpler implementation (no frame allocation/deallocation)
- Lower latency (in-place modification)
- Matches xv6 preemption model
- Avoids TCB_BUDGET field as global timer state; budget is per-TCB

---

## 3. TCB Layout Verification & Budget Field

### 3.1 Current TCB Byte-Offset Layout

**File**: `src/kernel/core/sched/tcb.pdx` lines 23–52

| Field | Offset | Width | Type | Notes |
|-------|--------|-------|------|-------|
| regs[0..15] | 0–127 | 8×16 | u64×16 | 16 saved GPRs (xv6-style; includes user context) |
| RIP | 128 | 8 | u64 | Saved instruction pointer |
| RFLAGS | 136 | 8 | u64 | Saved flags register |
| CS | 144 | 2 | u16 | Code segment selector (kernel or user) |
| SS | 146 | 2 | u16 | Stack segment selector (kernel or user) |
| KSTACK | 152 | 8 | u64 | Pointer to top of kernel stack |
| CAPTABLE | 160 | 8 | u64 | Pointer to capability table root |
| PRIORITY | 168 | 1 | u8 | Scheduling priority (0 = highest, 15 = lowest) |
| STATE | 169 | 1 | u8 | TCB state (running/runnable/blocked) |
| **BUDGET** | **172** | **4** | **u32** | **Remaining cycle budget (R4.5-007, R11)** |
| NEXT | 176 | 8 | u64 | Singly-linked list link (same priority) |
| **TCB_SIZE** | **184** | — | — | **Total: 184 bytes** |

### 3.2 Budget Field Decision

**Finding**: Budget field **already defined** at offset 172 (u32).

**Location**: `TCB_OFFSET_BUDGET = 172` (file `src/kernel/core/sched/tcb.pdx` line 46).

**Rationale**:
- Phase R4.5 (Architecture) pre-allocated budget field for future use
- Per design, budget is **per-TCB** (not global)
- R11-m1 will use this field to track remaining cycle budget per task
- Initialized on task creation; decremented on each timer tick
- When budget exhausted, preemption triggered (task moved to runqueue tail)

**No changes needed**: TCB layout is already correct.

### 3.3 Budget Accounting Constants

For R11-m1 prototype:

```
const TCB_BUDGET_R11_DEFAULT : u32 = 8       # Initial budget: 8 timer ticks
const TCB_BUDGET_MIN : u32 = 1               # Minimum: 1 tick (forced preemption)
const TCB_BUDGET_QUANTUM : u32 = 8           # Recharge quantum (cooperative refill)
```

---

## 4. Preflight Probes (Skipped)

**Decision**: Skip R11-m1 probes.

**Rationale**:
- R10-m1 already probed all critical encoders: push, pop, iretq, mov, cmp, add, lidt
- R11-m1 uses only R10-tested encoders (no new mnemonics needed)
- Critical path: in-place frame rewrite + budget tracking (both use existing encoders)
- Encoder substrate (paideia-as fe2293b+) is stable; R10 smoke tests pass

---

## 5. Architectural Decisions

### 5.1 Preemption Mechanism

**Mechanism**: In-place trap-frame rewrite (xv6 style)
- Modify RIP, registers, stack pointers **in situ** within kernel stack frame
- No separate frame allocation
- Handler returns; trampoline `iretq` restores modified state
- **Not**: `fabricate_iret_frame` (would require heap allocation, complexity)

### 5.2 Budget Storage

**Storage**: Per-TCB u32 field at offset 172
- Budget initialized on task creation (e.g., 8 ticks)
- Decremented on each timer ISR (R11-m2)
- Checked against 0 for preemption decision
- Simple, affine state (one budget per task)

### 5.3 Timer Interval

**Interval**: TSC-deadline with periodic fallback
- QEMU TCG: periodic mode (current, R10-m2)
- KVM/real hardware: TSC-deadline mode (future, R11+)
- Interval: 100 TSC cycles (adjustable in R11-m2)
- Rearm on each `handle_timer` invocation

### 5.4 Kernel-Preempt Build Target

**Build artifact**: `kernel-preempt-r11.elf`
- Separate from non-preemptive `kernel-r10.elf`
- Contains full IDT, timer ISR, preemption frame logic
- Requires paideia-as fe2293b+ (PA-R10-001 shipped)
- Smoke tests: `boot_r8_only`, `boot_r10` (no preemption yet; R11-m2 adds scheduler)

---

## 6. Acceptance Criteria

- [x] R10 timer state audited (LVT, vector 32, ISR delivery, STI timing)
- [x] Preempt-frame layout pinned (176 bytes: 15 GPRs + vector + CPU frame)
- [x] TCB layout verified (184 bytes; budget at offset 172)
- [x] Budget field: u32 per-TCB, not global (decision: per-TCB)
- [x] Preemption strategy documented: in-place frame rewrite (xv6 style)
- [x] No encoder escalations (R10 substrate sufficient)
- [x] R10 smoke tests pass (boot_r8_only, boot_r10)

---

## 7. Cross-References

- **Issue**: #388 (paideia-os r11-m1-001)
- **Related milestones**:
  - R9-m2: LAPIC timer initialization (TSC-deadline mode)
  - R10-m1: Trap-frame layout pinning (R10-preflight.md)
  - R10-m2: Timer ISR + autonomous delivery (handle_timer real)
  - R10-m3: Scheduler stubs (Switch, Yield, PickNext)
  - **R11-m1**: **This preflight + preemption frame pinning**
  - R11-m2: Budget tracking + cooperative scheduler
- **Files**:
  - `src/kernel/core/apic/lapic_timer.pdx` (timer config)
  - `src/kernel/core/int/exceptions.pdx` (handle_timer ISR)
  - `src/kernel/core/int/idt.pdx` (trampolines, vector 32)
  - `src/kernel/core/sched/tcb.pdx` (TCB layout with budget)
  - `src/kernel/boot/kernel_main.pdx` (boot sequence, sti timing)

---

**Prepared**: 2026-07-02  
**paideia-os SHA**: (to be filled on commit)  
**Document Status**: Ready for commit with implementation
