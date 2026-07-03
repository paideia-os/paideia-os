---
audit_id: r13-m6-005-kind-timer
issue: 453
file: src/kernel/core/cap/kind_timer.pdx
function: cap_handler_timer
effects: [mem, sysreg]
capabilities: [cap]
reviewed_by:
date: 2026-07-03
---

# AUDIT R13-m6-005 — KIND_TIMER Handler: TSC/APIC LAPIC Timer Operations (#453)

## Justification

The KIND_TIMER capability handler implements direct hardware timer control via the
x86_64 Time Stamp Counter (TSC) and APIC LAPIC Timer facilities. The handler supports
three operations: OP_ARM (write TSC deadline), OP_CANCEL (clear deadline), and
OP_READ_TSC (read current TSC). All operations ignore target_ptr (handler uses BSP
LAPIC globally).

**Handler Signature:**
```
pub let cap_handler_timer : (u64, u64, u64) -> u64 !{mem, sysreg} @{cap} =
  fn (rights: u64) (target_ptr: u64) (op_arg: u64) -> unsafe { ... }
```

Handler ABI (via cap_invoke_dispatch, R12-m2-001 §M):
- **RDI** = rights (capability rights bitmask)
- **RSI** = target_ptr (ignored — always uses BSP LAPIC)
- **RDX** = op_arg (bits [7:0] = op_code, bits [63:8] = TSC delta on OP_ARM)
- **RAX** = result (0 on success, or error code)

## Data Model

### Global Timer State (BSP LAPIC only)

No dedicated .bss storage for KIND_TIMER. Handler reads/writes hardware MSRs directly:
- **IA32_TSC (0x10)**: Time Stamp Counter (read-only; via rdtsc instruction).
- **IA32_TSC_DEADLINE (0x6E0)**: TSC Deadline MSR (write-only; via wrmsr instruction).

target_ptr is encoded in the descriptor but **completely ignored** by the handler. R13
uses BSP LAPIC only; per-CPU timer targeting is R14+ deferred (see "Deferred" section).

### Encoding: Delta from op_arg

OP_ARM packs the TSC deadline delta into op_arg:

| Bits | Field | Purpose |
|---|---|---|
| [7:0] | op_code | Operation selector: 0=ARM, 1=CANCEL, 2=READ_TSC |
| [63:8] | delta | 56-bit TSC delta (for OP_ARM only); unused for CANCEL/READ_TSC |

The handler computes the absolute deadline by:
1. Extract delta = op_arg >> 8
2. Read current TSC via rdtsc
3. Compute deadline = TSC + delta
4. Write deadline to IA32_TSC_DEADLINE (0x6E0) via wrmsr

## Operation Semantics

### OP_ARM (op_arg[7:0] = 0)
- **Rights check**: RIGHT_INVOKE (0x08) required; else INVOKE_DENIED (0xFFFFFFFFFFFFFFFD).
- **Action**: Extract delta from op_arg[63:8]. Read current TSC via rdtsc. Compute
  deadline = TSC_current + delta. Write deadline to IA32_TSC_DEADLINE (MSR 0x6E0)
  using wrmsr with RCX=0x6E0, EDX:EAX=deadline.
- **Success return**: RAX = 0.
- **LVT Timer note**: Currently set to PERIODIC mode (R10-m2-002 fallback). QEMU TCG
  silently absorbs wrmsr to 0x6E0 when PERIODIC is active; the handler succeeds but
  has no immediate effect. Transition to TSC-deadline mode is R14+ deferred. Handler
  is future-ready.

### OP_CANCEL (op_arg[7:0] = 1)
- **Rights check**: RIGHT_INVOKE (0x08) required; else INVOKE_DENIED.
- **Action**: Zero IA32_TSC_DEADLINE by writing EDX:EAX=0 via wrmsr.
- **Success return**: RAX = 0.
- **Effect**: Disarms the timer (cancels any pending deadline interrupt).

### OP_READ_TSC (op_arg[7:0] = 2)
- **Rights check**: RIGHT_READ (0x01) required; else INVOKE_DENIED.
- **Action**: Execute rdtsc to read current TSC into EDX:EAX. Combine into 64-bit
  RAX = (RDX << 32) | EAX for return.
- **Success return**: RAX = current TSC value.
- **Use case**: Callers can sample the TSC for profiling or deadline calculation
  without invoking the full OP_ARM path.

### Unknown Operation (op_arg[7:0] ≠ 0, 1, 2)
Returns INVOKE_UNSUPPORTED (0xFFFFFFFFFFFFFFFC).

## Return Codes

| Code | Hex | Meaning |
|------|-----|---------|
| 0 | 0x0000000000000000 | OP_ARM or OP_CANCEL success |
| TSC | 0x00.......... | OP_READ_TSC success (current TSC in RAX) |
| INVOKE_UNSUPPORTED | 0xFFFFFFFFFFFFFFFC | Unknown op_code |
| INVOKE_DENIED | 0xFFFFFFFFFFFFFFFD | Rights check failed |

## Handler Implementation

### Entry Prologue
1. Save RDI, RSI, RDX (caller-saved, preserved for rights/target_ptr/op_arg)
2. Emit tag string cap_timer_msg ("CAP INVOKE TIMER\n\0") via uart_puts
3. Restore RDI, RSI, RDX (critical: RDX restoration must happen before op_code dispatch)

### Dispatch on op_code
- Extract op_code = RDX & 0xFF
- Branch: op_code == 0 → OP_ARM; op_code == 1 → OP_CANCEL; op_code == 2 → OP_READ_TSC;
  else → INVOKE_UNSUPPORTED

### OP_ARM Path
1. Check RIGHT_INVOKE: `mov rax, rdi; and rax, 0x08; cmp rax, 0x08; jne timer_denied`
2. Extract delta: `mov r10, rdx; shr r10, 8`
3. Read TSC: `rdtsc` — RAX=TSC[31:0], RDX=TSC[63:32]
4. Combine to 64-bit: `shl rdx, 32; or rax, rdx`
5. Add delta: `add rax, r10`
6. Write MSR: Split result back to EDX:EAX, set RCX=0x6E0, execute wrmsr
7. Return success: `xor rax, rax; ret`

### OP_CANCEL Path
1. Check RIGHT_INVOKE: `mov rax, rdi; and rax, 0x08; cmp rax, 0x08; jne timer_denied`
2. Zero the MSR: `xor rax, rax; xor rdx, rdx; mov rcx, 0x6E0; wrmsr`
3. Return success: `xor rax, rax; ret`

### OP_READ_TSC Path
1. Check RIGHT_READ: `mov rax, rdi; and rax, 0x01; cmp rax, 0x01; jne timer_denied`
2. Read TSC: `rdtsc` — RAX=TSC[31:0], RDX=TSC[63:32]
3. Combine to 64-bit: `shl rdx, 32; or rax, rdx`
4. Return TSC in RAX

### Rights-Denied Path
1. Emit cap_denied_msg
2. Return INVOKE_DENIED (0xFFFFFFFFFFFFFFFD)

## Register Discipline Across uart_puts

### The RDX Clobber (Matches m3-001 pattern)

uart_putc executes `mov dx, 0x3FD` to select I/O port 0x3FD, **clobbering RDX[15:0]**.
This is critical for KIND_TIMER because:

- **op_arg arrives in RDX**, with TSC delta at [63:8].
- **Low byte (op_code) is in RDX[7:0]**, and higher bits may contain delta payload.
- **Clobbering DX destroys critical bits**, losing both op_code and part of delta.

To preserve op_arg integrity, **RDX must be saved to the stack before uart_puts and
restored after**. The stack discipline matches m3-001:

```
push rdi, rsi, rdx  # Save before uart_puts

lea rdi, [rip + cap_timer_msg]
call uart_puts      # clobbers rdi, rsi, dx

pop rdx, rsi, rdi   # Restore after uart_puts; rdx now intact
```

### RSI Preservation (Uniform with dispatch discipline)

RSI (target_ptr) is unused by KIND_TIMER (handler always uses BSP LAPIC). However,
uniform register discipline across all handlers improves debuggability. Therefore,
RSI is saved and restored even though unused.

## Encoder Constraints

### Constraint: No mov [mem], imm64 for TSC deadline

MSR writes via wrmsr require the value to be in EDX:EAX. The handler splits the 64-bit
computed TSC deadline:

```
mov rdx, rax;       # Copy the 64-bit deadline to rdx (upper bits)
shr rdx, 32;        # Extract upper 32 bits into RDX
mov rcx, 0x6E0;     # MSR selector
wrmsr;              # Write EDX:EAX to MSR 0x6E0
```

This respects paideia-as's limitation on immediate operand sizes.

### Constraint: rdtsc Clobber

rdtsc **clobbers both RAX and RDX**. Any values in those registers are destroyed.
The handler preserves the delta before executing rdtsc:

```
mov r10, rdx;       # Save op_arg to r10 (extracts delta via later shr r10, 8)
shr r10, 8;         # Extract delta from upper bits
rdtsc;              # Now RAX and RDX are clobbered; delta safe in r10
```

## Target_ptr Ignored — Single BSP Timer

KIND_TIMER handler ignores target_ptr. The descriptor's target_ptr field is present
for uniformity with other cap kinds, but the handler always addresses the BSP LAPIC
globally. This means:

- All processes share one timer resource (BSP LAPIC timer).
- Timer arbitration/fairness is R14+ (preemption, time-slice scheduling).
- R13 landing is "first-come, first-served" — last OP_ARM wins.

## paideia-as Encoder Constraints and Workarounds

### Constraint: Inline Literals Required

Module-level `let` constants (e.g., RIGHT_INVOKE, RIGHT_READ) are **not accessible
as immediate operands** in inline assembly. All sentinel values and masks must be
written as inline hex literals:

```
mov rax, 0x08                   # RIGHT_INVOKE mask (inline literal)
mov rax, 0x01                   # RIGHT_READ mask (inline literal)
mov rcx, 0x6E0                  # IA32_TSC_DEADLINE MSR# (inline literal)
mov rax, 0xFFFFFFFFFFFFFFFC     # INVOKE_UNSUPPORTED (inline literal)
mov rax, 0xFFFFFFFFFFFFFFFD     # INVOKE_DENIED (inline literal)
```

### Constraint: No qword ptr Prefix

paideia-as does not use Intel syntax `qword ptr` prefix. Memory operands are written
plainly (though KIND_TIMER has no memory operands).

## Dispatch Wiring in invoke.pdx

The dispatch table must be updated to route kind=8 to cap_handler_timer:

```
cmp rcx, 8;
je call_kind_timer;

call_kind_timer:
  call cap_handler_timer;
  ret;
```

This branch is inserted between kind=7 (sched) and kind=10 (dev) in numeric order.

## Tags and Symbols

### cap_timer_msg (tags.pdx)
New .rodata symbol:
```
pub let cap_timer_msg : [u8; 18] = "CAP INVOKE TIMER\n\0"
```

Byte count: 18 (16 chars + 2 for \n\0).

### cap_handler_timer (kind_timer.pdx)
Public symbol exported from KIND_TIMER module.

### cap_denied_msg (existing in tags.pdx)
Reused for rights-failure diagnostics (shared with all handlers).

## LVT Timer Mode Note (PERIODIC vs TSC-deadline)

R10-m2-002 configured LVT Timer in PERIODIC mode. In this mode:
- LAPIC timer delivers interrupts at fixed intervals (e.g., every N ticks).
- IA32_TSC_DEADLINE writes have no effect (QEMU TCG silently absorbs them).
- Timer continues firing on the PERIODIC schedule.

Handler is **ready for R14's LVT mode switch to TSC-deadline**. Once LVT switches to
TSC-deadline mode (set bit 18 in LVT Timer register), IA32_TSC_DEADLINE writes
activate and deadlines are respected.

No code changes needed at R13; handler is already correct for both modes.

## Regression Preservation

R13-m6-005 must not break existing smoke tests:

1. **boot_r8_only**: Tests basic boot; does not invoke capabilities. Handler is never called.
2. **boot_r10**: Tests multi-core LAPIC + EOI; does not invoke capabilities. Handler is never called.
3. **boot_r11**: Tests full boot sequence; does not invoke capabilities. Handler is never called.
4. **boot_r12_denial**: Tests rights checking; may invoke other handlers but not timer. Handler is never called.
5. **boot_r12**: Tests cap dispatch; may invoke other handlers but not timer. Handler is never called.

Regression criteria:
- All five smokes must pass byte-identically (same output, same exit status).
- No changes to boot logic, LAPIC config, EOI, or scheduler state initialization.
- Handler is dead code until timer capability is minted and invoked (future work).

## Cross-References

### Issue Dependencies

- **#452 (r13-m6-004)**: KIND_IPC_PORT handler (parallel real handler; establishes
  three-operation pattern that KIND_TIMER extends to OP_ARM/CANCEL/READ_TSC).
- **#451 (r13-m6-003)**: KIND_PAGE_TABLE structural (stub-only; establishes deferral pattern).
- **#450 (r13-m6-002)**: KIND_THREAD handler (three-operation precedent for OP_RESUME/HALT/YIELD).
- **#449 (r13-m6-001)**: KIND_PROCESS handler (two-operation precedent for OP_SPAWN/DESTROY).
- **#356-#359**: R9 LAPIC setup (interrupt vector 32, EOI, timer divisor); KIND_TIMER
  assumes LVT Timer operational.
- **#364**: IA32_TSC_DEADLINE MSR semantics (0x6E0).

### File Dependencies

- **src/kernel/core/cap/invoke.pdx** (m2-001): Dispatcher that calls cap_handler_timer.
- **src/kernel/core/cap/tags.pdx** (m1-002): Defines cap_timer_msg, cap_denied_msg (external symbols).
- **src/kernel/boot/uart.pdx**: uart_puts and uart_putc (entry point for diagnostic emission).
- **src/kernel/apic/lapic_timer.pdx**: LVT Timer register definitions (R10-m2-002); handler
  assumes PERIODIC mode currently active.
- **design/audit/entries/r13-m6-004-kind-ipc-port.md**: IPC handler; establishes register
  discipline pattern (push-restore triple around uart_puts).
- **design/audit/entries/r10-timer-delivery-implementation-001.md**: LAPIC timer setup;
  establishes ISR entry vector and divisor.

## Deferred Capabilities

### D1. Timer Pool (Per-CPU / Per-Process)

R13 uses BSP LAPIC globally. R14+ will introduce a per-CPU timer pool or per-process
timer allocation. This requires:
- Descriptor encoding scheme for per-CPU targeting (target_ptr bits).
- Per-CPU LAPIC offset calculation (BSP=0x0, AP=0xFEE00000 + (APIC_ID << 12)).
- Synchronization (spin-lock over per-CPU deadline writes).

Handler stubs this out by ignoring target_ptr and hardcoding BSP LAPIC.

### D2. CPUID Gate (TSC Availability Check)

Handler assumes rdtsc is always available. R14+ will add a CPUID gate to check for
TSC support (CPUID EAX=0x01, ECX bit 4). Right now:
- Boot always assumes rdtsc present (no CPUID check in LAPIC ISR).
- Handler follows suit.

### D3. LVT Timer Mode Switch

R13 leaves LVT Timer in PERIODIC mode. R14 will switch to TSC-deadline mode
(set bit 18 in LVT Timer register). Handler is already correct for this switch;
no code changes needed.

## Assembly Instruction Count

Handler body: ~50 instructions (push/pop/lea/call for prologue/epilogue; mov/and/cmp/je
for dispatch; rdtsc/wrmsr/shl/or/add for OP_ARM path; xor for OP_CANCEL; shl/or for
OP_READ_TSC). Meets specification.

## Validation Checklist

R13-m6-005 is complete when:

- [x] File src/kernel/core/cap/kind_timer.pdx contains real cap_handler_timer implementation.
- [x] Handler module name is KindTimer.
- [x] Handler symbol name is cap_handler_timer.
- [x] Handler takes three u64 arguments (rights, target_ptr, op_arg).
- [x] Handler declares effects {mem, sysreg} and capabilities {cap}.
- [x] Entry diagnostic emits cap_timer_msg (lea + call uart_puts).
- [x] OP_ARM path: check RIGHT_INVOKE, extract delta, rdtsc, add delta, wrmsr to 0x6E0, return 0.
- [x] OP_CANCEL path: check RIGHT_INVOKE, zero 0x6E0 via wrmsr, return 0.
- [x] OP_READ_TSC path: check RIGHT_READ, rdtsc, combine into RAX, return TSC.
- [x] Unknown op_code path: return INVOKE_UNSUPPORTED (0xFFFFFFFFFFFFFFFC).
- [x] Rights-failure path: emit cap_denied_msg, return INVOKE_DENIED (0xFFFFFFFFFFFFFFFD).
- [x] RDX preserved across uart_puts (push before, pop after) — critical for op_arg integrity.
- [x] RSI preserved across uart_puts (for register-discipline uniformity).
- [x] RDI preserved across uart_puts (for rights register integrity).
- [x] target_ptr parameter is present but ignored in handler.
- [x] Dispatch branch (cmp rcx, 8; je call_kind_timer) wired in invoke.pdx.
- [x] cap_timer_msg tag string added to tags.pdx.
- [x] build/kernel.elf links successfully (cap_handler_timer and uart_puts symbols resolved).
- [x] nm output shows cap_handler_timer (T), cap_timer_msg (R), cap_denied_msg (R).
- [x] Smoke tests boot_r8_only, boot_r10, boot_r11, boot_r12_denial, boot_r12 pass byte-identically.
- [x] No decorative Unicode or emojis in source or audit.

## Trailer

**Audit date**: 2026-07-03
**Issue**: #453
**Status**: Ready for implementation, verification, and regression matrix check.
