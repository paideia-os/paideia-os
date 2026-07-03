---
audit_id: r12-m3-002-kind-sched
issue: 409
file: src/kernel/core/cap/kind_sched.pdx
function: cap_handler_sched
effects: [mem, sysreg]
capabilities: [cap]
reviewed_by:
date: 2026-07-03
---

# AUDIT r12-m3-002 — KIND_SCHED_CTX Real Handler: OP_YIELD

## Section 1 — Overview

R12-m3-002 replaces the m2-002 stub handler with a real implementation of cap_handler_sched. This handler implements a single operation (OP_YIELD, op_code=5) that wraps the cooperative scheduler primitive sched_yield. Unlike KIND_PAGE which has two symmetric operations (OP_READ / OP_WRITE), KIND_SCHED_CTX is single-operation; the handler delegates immediately to sched_yield after rights checking.

The handler implements:

1. **OP_YIELD (op_code=5)**: Check RIGHT_INVOKE (bit 3), call sched_yield, return result (0 = YIELD_OK) or deny.
2. **Diagnostic emission**: Tag emitted via uart_puts at entry (cap_sched_msg) and on rights failure (cap_denied_msg).
3. **Error returns**: INVOKE_UNSUPPORTED (0xFFFFFFFFFFFFFFFC) for unknown op_code; INVOKE_DENIED (0xFFFFFFFFFFFFFFFD) for rights failure.

The real body must preserve the register discipline established in m2-002 (entry/exit via RDI/RSI/RDX, return via RAX), extend it to handle cross-uart_puts clobber (matching m3-001's pattern), and pass the rights validation gating required by m5-001's cap_dispatch_smoke test.

---

## Section 2 — Assembly Sequence (Annotated)

The full handler body, with per-line commentary:

```
# ENTRY: Preserve caller state across diagnostic emit
1.  push rdi                       # Save rights (caller-saved, but uart_puts may clobber rdi)
2.  push rsi                       # Save target_ptr (uart_puts uses rsi; unused for SCHED but preserved for uniformity)
3.  push rdx                       # Save op_arg (uart_putc will clobber dx, destroying op_arg[7:0])

# DIAGNOSTIC: Emit entry tag on COM1
4.  lea rdi, [rip + cap_sched_msg] # Load cap_sched_msg string address (RIP-relative)
5.  call uart_puts                 # Emit "CAP INVOKE SCHED\n" on COM1

# EXIT-RESTORE: Recover all caller state before op dispatch
6.  pop rdx                        # Restore op_arg (now safe from uart_putc clobber)
7.  pop rsi                        # Restore target_ptr (unused for SCHED; restored for uniformity with m3-001)
8.  pop rdi                        # Restore rights

# DECODE OP_CODE (bits [7:0] of op_arg)
9.  mov r8, rdx                    # Copy op_arg to r8
10. and r8, 0xFF                   # Mask to extract bits [7:0] = op_code

# DISPATCH
11. cmp r8, 5                      # Is op_code == 5 (OP_YIELD)?
12. je do_yield                    # Jump to OP_YIELD handler if so

# UNKNOWN OP (fallthrough)
13. mov rax, 0xFFFFFFFFFFFFFFFC    # Load INVOKE_UNSUPPORTED
14. ret                            # Return to dispatcher

# OP_YIELD HANDLER (label do_yield:)
15. mov rax, rdi                   # Copy rights to rax
16. and rax, 0x08                  # Mask to extract bit 3 = RIGHT_INVOKE
17. cmp rax, 0x08                  # Is RIGHT_INVOKE bit set?
18. jne sched_denied               # Jump to rights-failure handler if not

# OP_YIELD: Delegate to scheduler primitive
19. call sched_yield               # Call cooperative-yield stub (R10-m3-002)
20. ret                            # Return sched_yield result (YIELD_OK=0 for stub)

# RIGHTS-DENIED HANDLER (label sched_denied:)
21. lea rdi, [rip + cap_denied_msg] # Load cap_denied_msg string address
22. call uart_puts                 # Emit "CAP DENIED\n" on COM1
23. mov rax, 0xFFFFFFFFFFFFFFFD    # Load INVOKE_DENIED
24. ret                            # Return to dispatcher
```

**Line count**: 24 assembly lines (including labels, comment-only lines not counted).

---

## Section 3 — Register-Preservation Discipline Across uart_puts

### The RDX Clobber Problem (Matched from m3-001)

Standard System V AMD64 ABI classifies RDX as caller-saved. However, uart_putc (called via uart_puts) executes `mov dx, 0x3FD` to select I/O port 0x3FD, which **clobbers the low 16 bits of RDX**. This is critical for OP_YIELD:

- **op_arg arrives in RDX**, with potential payload bits at [63:8] (though OP_YIELD ignores them).
- **Low byte (op_code) is in RDX[7:0]**.
- **Clobbering DX destroys RDX[15:0]**, losing op_code bits [15:0].

To preserve the op_arg (and especially the op_code), **RDX must be saved to the stack before uart_puts and restored after**. The stack discipline matches m3-001:

```
push rdi, rsi, rdx  # Save before uart_puts

lea rdi, [rip + cap_sched_msg]
call uart_puts      # clobbers rdi, rsi, dx

pop rdx, rsi, rdi   # Restore after uart_puts; rdx now intact
```

### RSI Preservation (Uniform with m3-001)

RSI (target_ptr) is unused by OP_YIELD (the scheduler primitive is global, not indexed by target_ptr). However, m3-001 (KIND_PAGE) preserves RSI, and R12's dispatch discipline requires uniform register discipline across all handlers for debuggability. Therefore, RSI is saved and restored even though OP_YIELD doesn't read it.

---

## Section 4 — op_arg Encoding for KIND_SCHED_CTX

The cap_invoke_dispatch caller (invoke.pdx, m2-001) passes the original op_arg unchanged in RDX:

| Bits | Field | Purpose | Example |
|---|---|---|---|
| [7:0] | op_code | Operation selector | 5=YIELD, others=UNSUPPORTED |
| [63:8] | payload | Operation-specific data | For YIELD: unused (reserved for future extensions) |

**OP_YIELD example**: op_arg = 0x0000000000000005
- op_code = 0x05 (YIELD)
- payload = 0x0000000000000000 (ignored by stub)

---

## Section 5 — Rights Discipline

The handler enforces one right bit for OP_YIELD:

| Bit | Name | Purpose |
|---|---|---|
| 3 | RIGHT_INVOKE | Allows OP_YIELD (invoke the scheduler primitive) |

Check pattern:

```
For OP_YIELD:
  mov rax, rdi          # Load rights
  and rax, 0x08         # Mask bit 3 = RIGHT_INVOKE
  cmp rax, 0x08         # Test if set
  jne sched_denied      # Deny if not
```

If RIGHT_INVOKE is not set, the handler jumps to sched_denied, emits cap_denied_msg tag, and returns INVOKE_DENIED (0xFFFFFFFFFFFFFFFD).

---

## Section 6 — sched_yield Delegation

The handler delegates OP_YIELD to the scheduler module's cooperative-yield primitive:

```
pub let sched_yield : () -> u64 = fn () -> unsafe { ... }
```

Located in `src/kernel/core/sched/yield.pdx` (module Yield). Current state (R10-m3-002): stub returns YIELD_OK (0) immediately. This is sufficient for R12 to prove the dispatch path; full scheduler state manipulation (runqueue enqueue, TCB switch, etc.) is a natural R13 quality-gate aligned with interrupt-wiring completion.

The handler calls `sched_yield` unqualified (no module-prefix):

```
call sched_yield      # Call cooperative-yield stub (R10-m3-002)
```

This requires sched_yield to be a public symbol. At R12-m3-002 open, the symbol must be exported as `pub let sched_yield`.

---

## Section 7 — paideia-as Encoder Constraints and Workarounds

### Constraint E11-4 (Matches m3-001): No mov [mem], imm32

Not applicable for KIND_SCHED_CTX; the handler performs no memory writes. OP_YIELD is pure control flow (call sched_yield, return result).

### Constraint: Inline Literals Required

Module-level `let` constants are **not accessible as immediate operands** in inline assembly. All sentinel values and masks must be written as inline hex literals:

```
mov rax, 0xFFFFFFFFFFFFFFFC  # INVOKE_UNSUPPORTED (inline literal)
mov rax, 0xFFFFFFFFFFFFFFFD  # INVOKE_DENIED (inline literal)
and rax, 0x08               # RIGHT_INVOKE mask (inline literal)
```

### Constraint: No qword ptr Prefix

paideia-as does not use Intel syntax `qword ptr` prefix. Memory operands are written plainly (though KIND_SCHED_CTX has no memory operands).

---

## Section 8 — Rights-Failure Witness Pattern

The handler's rights-denial path (sched_denied label) is exercised by m5-001's cap_dispatch_smoke test:

**Test case: OP_YIELD without RIGHT_INVOKE**
- rights = 0x00 (no rights; empty descriptor)
- op_arg = 0x0000000000000005 (OP_YIELD)
- Expected: cap_denied_msg emitted, INVOKE_DENIED returned

**Test case: OP_YIELD with RIGHT_INVOKE**
- rights = 0x08 (RIGHT_INVOKE only)
- op_arg = 0x0000000000000005 (OP_YIELD)
- Expected: sched_yield called, YIELD_OK (0) returned, no denial

**Alternative test case: OP_READ (unsupported op for SCHED)**
- rights = 0x08 (RIGHT_INVOKE)
- op_arg = 0x0000000000000001 (OP_READ, invalid for SCHED)
- Expected: INVOKE_UNSUPPORTED returned, no COM1 output

The cap_sched_msg tag is always emitted (entry diagnostic). The cap_denied_msg tag is emitted only if rights check fails.

---

## Section 9 — Link-Resolution Witness

After build, the following symbols must be present:

```bash
nm build/kernel.elf | grep -E "cap_handler_sched|sched_yield|cap_sched_msg|cap_denied_msg"
```

Expected output (4 lines):

```
<addr> T cap_handler_sched         # Executable text symbol
<addr> T sched_yield               # Executable text symbol (called by handler)
<addr> R cap_sched_msg             # Read-only data (string)
<addr> R cap_denied_msg            # Read-only data (string)
```

**Dependency note**: If sched_yield is not exported as pub in yield.pdx, the link will fail with "undefined reference to sched_yield" because kind_sched.pdx cannot call a private symbol. This is a build gate: m3-002 depends on sched_yield being pub.

---

## Section 10 — Regression Preservation

R12-m3-002 must not break existing smoke tests:

1. **boot_r8_only**: Tests basic boot; does not invoke capabilities. Handler is never called.
2. **boot_r10**: Tests multi-core LAPIC + EOI; does not invoke capabilities. Handler is never called.
3. **boot_r11**: Tests full boot sequence; does not invoke capabilities. Handler is never called.

Regression criteria:
- All three smokes must pass byte-identically (same output, same exit status).
- No changes to boot logic, LAPIC config, EOI, scheduler state initialization, or current_tcb setup.
- Handler is dead code until m5-001 (cap_dispatch_smoke) exercises it.

---

## Section 11 — Cross-References

### Issue Dependencies

- **#405 (r12-m1-002)**: Dispatch architectural audit (tag discipline, handler ABI) — defines cap_sched_msg and cap_denied_msg.
- **#406 (r12-m2-001)**: Dispatcher skeleton (calls handlers) — invoke.pdx entry point; establish handler call convention.
- **#407 (r12-m2-002)**: Stub handlers (placeholders replaced by m3-002) — m2-002 is superseded; m3-002 is real body.
- **#408 (r12-m3-001)**: Real kind_page handler (OP_READ/OP_WRITE) — parallel work (can land in either order after m2-002).
- **#410 (r12-m4-001)**: Real kind_ipc handler (OP_SEND/OP_RECV) — similar structure (rights check, diagnostic, primitive delegation).
- **#411 (r12-m4-002)**: Real kind_dev handler (OP_MAP_MMIO) — hardware access pattern.
- **#412 (r12-m5)**: Regression matrix and cap_dispatch_smoke — runtime witness for all handlers; exercises all four kinds.

### File Dependencies

- **src/kernel/core/cap/invoke.pdx** (m2-001): Dispatcher that calls cap_handler_sched.
- **src/kernel/core/cap/tags.pdx** (m1-002): Defines cap_sched_msg, cap_denied_msg (external symbols).
- **src/kernel/core/uart.pdx**: uart_puts and uart_putc (entry point for diagnostic emission).
- **src/kernel/core/sched/yield.pdx**: sched_yield primitive that OP_YIELD delegates to. **Must export sched_yield as pub.**
- **design/audit/entries/r12-m1-002-dispatch-arch.md**: Architectural context (handler ABI, tag discipline).
- **design/audit/entries/r12-m2-002-stub-handlers.md**: Previous audit (m2-002 stubs); m3-002 is successor.
- **design/audit/entries/r12-m3-001-kind-page.md**: Parallel handler audit (m3-001); establishes register-preservation pattern.

---

## Section 12 — Validation Checklist

R12-m3-002 is complete when:

- [ ] File src/kernel/core/cap/kind_sched.pdx contains real cap_handler_sched implementation.
- [ ] Handler module name is KindSched.
- [ ] Handler symbol name is cap_handler_sched.
- [ ] Handler takes three u64 arguments (rights, target_ptr, op_arg).
- [ ] Handler declares effects {mem, sysreg} and capabilities {cap}.
- [ ] Entry diagnostic emits cap_sched_msg (lea + call uart_puts).
- [ ] OP_YIELD path: check RIGHT_INVOKE (0x08), call sched_yield, return result.
- [ ] Unknown op_code path: return INVOKE_UNSUPPORTED (0xFFFFFFFFFFFFFFFC).
- [ ] Rights-failure path: emit cap_denied_msg, return INVOKE_DENIED (0xFFFFFFFFFFFFFFFD).
- [ ] RDX preserved across uart_puts (push before, pop after) — critical for op_arg integrity.
- [ ] RSI preserved across uart_puts (for register-discipline uniformity with m3-001).
- [ ] RDI preserved across uart_puts (for rights register integrity).
- [ ] build/kernel.elf links successfully (cap_handler_sched and sched_yield symbols resolved).
- [ ] nm output shows cap_handler_sched (T), sched_yield (T), cap_sched_msg (R), cap_denied_msg (R).
- [ ] Smoke tests boot_r8_only, boot_r10, boot_r11 pass byte-identically.
- [ ] No decorative Unicode or emojis in source or audit.

---

## Trailer

**Audit date**: 2026-07-03
**Issue**: #409
**Status**: Ready for implementation, verification, and regression matrix check (issue #412).
