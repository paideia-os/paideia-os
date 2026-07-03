---
audit_id: r12-m4-001-kind-ipc
issue: 410
file: src/kernel/core/cap/kind_ipc.pdx
function: cap_handler_ipc
effects: [mem, sysreg]
capabilities: [cap]
reviewed_by:
date: 2026-07-03
---

# AUDIT r12-m4-001 — KIND_IPC_ENDPOINT Real Handler: OP_SEND and OP_RECV

## Section 1 — Overview

R12-m4-001 replaces the m2-002 stub handler with a real implementation of cap_handler_ipc. This handler implements two operations (OP_SEND, op_code=3; OP_RECV, op_code=4) that wrap the B6-002/003 SPSC channel primitives ipc_enqueue (send) and ipc_dequeue (receive). Unlike KIND_SCHED_CTX which has one operation (OP_YIELD), KIND_IPC_ENDPOINT has two symmetric operations: sender and receiver.

The handler implements:

1. **OP_SEND (op_code=3)**: Check RIGHT_INVOKE (bit 3) + RIGHT_WRITE (bit 1) (combined as 0x0A), extract message from op_arg[63:8], call ipc_enqueue, return enqueue result (1=success, 0=full).
2. **OP_RECV (op_code=4)**: Check RIGHT_INVOKE (bit 3) + RIGHT_READ (bit 0) (combined as 0x09), call ipc_dequeue, return message or 0 if empty.
3. **Diagnostic emission**: Tag emitted via uart_puts at entry (cap_ipc_msg) and on rights failure (cap_denied_msg).
4. **Error returns**: INVOKE_UNSUPPORTED (0xFFFFFFFFFFFFFFFC) for unknown op_code; INVOKE_DENIED (0xFFFFFFFFFFFFFFFD) for rights failure.

The real body must preserve the register discipline established in m2-002 (entry/exit via RDI/RSI/RDX, return via RAX), extend it to handle cross-uart_puts clobber (matching m3-002's pattern), and pass the rights validation gating required by m5-001's cap_dispatch_smoke test.

**Scope note (R12):** The handler delegates to a global SPSC channel (`channel_data`, B6-002/003). The target_ptr parameter is unused for R12. Scoped channel invocation (per-cap channel multiplexing) is deferred to R13 when the global channel becomes insufficient for multi-agent scenarios.

---

## Section 2 — Assembly Sequence (Annotated)

The full handler body, with per-line commentary:

```
# ENTRY: Preserve caller state across diagnostic emit
1.  push rdi                       # Save rights (caller-saved, but uart_puts may clobber rdi)
2.  push rsi                       # Save target_ptr (uart_puts uses rsi; unused for IPC but preserved for uniformity)
3.  push rdx                       # Save op_arg (uart_putc will clobber dx, destroying op_arg[7:0])

# DIAGNOSTIC: Emit entry tag on COM1
4.  lea rdi, [rip + cap_ipc_msg]  # Load cap_ipc_msg string address (RIP-relative)
5.  call uart_puts                 # Emit "CAP INVOKE IPC\n" on COM1

# EXIT-RESTORE: Recover all caller state before op dispatch
6.  pop rdx                        # Restore op_arg (now safe from uart_putc clobber)
7.  pop rsi                        # Restore target_ptr (unused for IPC; restored for uniformity with m3-002)
8.  pop rdi                        # Restore rights

# DECODE OP_CODE (bits [7:0] of op_arg)
9.  mov r8, rdx                    # Copy op_arg to r8
10. and r8, 0xFF                   # Mask to extract bits [7:0] = op_code

# DISPATCH
11. cmp r8, 3                      # Is op_code == 3 (OP_SEND)?
12. je do_send                     # Jump to OP_SEND handler if so
13. cmp r8, 4                      # Is op_code == 4 (OP_RECV)?
14. je do_recv                     # Jump to OP_RECV handler if so

# UNKNOWN OP (fallthrough)
15. mov rax, 0xFFFFFFFFFFFFFFFC    # Load INVOKE_UNSUPPORTED
16. ret                            # Return to dispatcher

# OP_SEND HANDLER (label do_send:)
17. mov rax, rdi                   # Copy rights to rax
18. and rax, 0x0A                  # Mask to extract bits 3,1 = (RIGHT_INVOKE, RIGHT_WRITE)
19. cmp rax, 0x0A                  # Is (RIGHT_INVOKE | RIGHT_WRITE) both set?
20. jne ipc_denied                 # Jump to rights-failure handler if not

# OP_SEND: Extract message and delegate to IPC primitive
21. mov rdi, rdx                   # Copy op_arg to rdi
22. shr rdi, 8                     # Shift right 8 bits to extract payload (op_arg[63:8])
23. call ipc_enqueue               # Call enqueue with message in rdi
24. ret                            # Return ipc_enqueue result (1=success, 0=full)

# OP_RECV HANDLER (label do_recv:)
25. mov rax, rdi                   # Copy rights to rax
26. and rax, 0x09                  # Mask to extract bits 3,0 = (RIGHT_INVOKE, RIGHT_READ)
27. cmp rax, 0x09                  # Is (RIGHT_INVOKE | RIGHT_READ) both set?
28. jne ipc_denied                 # Jump to rights-failure handler if not

# OP_RECV: Delegate to IPC primitive (no args; returns message in rax)
29. call ipc_dequeue               # Call dequeue (returns message in rax or 0 if empty)
30. ret                            # Return ipc_dequeue result

# RIGHTS-DENIED HANDLER (label ipc_denied:)
31. lea rdi, [rip + cap_denied_msg] # Load cap_denied_msg string address
32. call uart_puts                 # Emit "CAP DENIED\n" on COM1
33. mov rax, 0xFFFFFFFFFFFFFFFD    # Load INVOKE_DENIED
34. ret                            # Return to dispatcher
```

**Line count**: 34 assembly lines (including labels, comment-only lines not counted).

---

## Section 3 — Register-Preservation Discipline Across uart_puts

### The RDX Clobber Problem (Matched from m3-002)

Standard System V AMD64 ABI classifies RDX as caller-saved. However, uart_putc (called via uart_puts) executes `mov dx, 0x3FD` to select I/O port 0x3FD, which **clobbers the low 16 bits of RDX**. This is critical for OP_SEND and OP_RECV:

- **op_arg arrives in RDX**, with message payload at [63:8] (OP_SEND) or unused (OP_RECV).
- **Low byte (op_code) is in RDX[7:0]**.
- **Clobbering DX destroys RDX[15:0]**, losing op_code bits [15:0].

To preserve the op_arg (and especially the op_code for dispatch), **RDX must be saved to the stack before uart_puts and restored after**. The stack discipline matches m3-002:

```
push rdi, rsi, rdx  # Save before uart_puts

lea rdi, [rip + cap_ipc_msg]
call uart_puts      # clobbers rdi, rsi, dx

pop rdx, rsi, rdi   # Restore after uart_puts; rdx now intact
```

### RSI Preservation (Uniform with m3-002)

RSI (target_ptr) is unused by OP_SEND and OP_RECV in R12 (the IPC primitive operates on the global channel, not indexed by target_ptr). However, m3-002 (KIND_SCHED_CTX) preserves RSI, and R12's dispatch discipline requires uniform register discipline across all handlers for debuggability. Therefore, RSI is saved and restored even though OP_SEND/OP_RECV don't read it.

---

## Section 4 — op_arg Encoding for KIND_IPC_ENDPOINT

The cap_invoke_dispatch caller (invoke.pdx, m2-001) passes the original op_arg unchanged in RDX:

| Bits | Field | Purpose | Example |
|---|---|---|---|
| [7:0] | op_code | Operation selector | 3=SEND, 4=RECV, others=UNSUPPORTED |
| [63:8] | payload | Operation-specific data | For SEND: message (56-bit u64); For RECV: unused (reserved for future extensions) |

**OP_SEND example**: op_arg = 0x1234567890ABCD03
- op_code = 0x03 (SEND)
- payload = 0x1234567890ABCD (56-bit message to enqueue)

**OP_RECV example**: op_arg = 0x0000000000000004
- op_code = 0x04 (RECV)
- payload = 0x0000000000000000 (ignored by stub)

---

## Section 5 — Rights Discipline

The handler enforces distinct rights for OP_SEND and OP_RECV:

### OP_SEND Rights

| Bit | Name | Purpose |
|---|---|---|
| 3 | RIGHT_INVOKE | Allows invoking any capability-mediated operation |
| 1 | RIGHT_WRITE | Allows sending (writing to the channel) |

Check pattern:

```
For OP_SEND:
  mov rax, rdi          # Load rights
  and rax, 0x0A         # Mask bits 3,1 = (RIGHT_INVOKE, RIGHT_WRITE)
  cmp rax, 0x0A         # Test if both set
  jne ipc_denied        # Deny if not
```

Combined mask 0x0A = 0000_1010 = bits 1 and 3.

### OP_RECV Rights

| Bit | Name | Purpose |
|---|---|---|
| 3 | RIGHT_INVOKE | Allows invoking any capability-mediated operation |
| 0 | RIGHT_READ | Allows receiving (reading from the channel) |

Check pattern:

```
For OP_RECV:
  mov rax, rdi          # Load rights
  and rax, 0x09         # Mask bits 3,0 = (RIGHT_INVOKE, RIGHT_READ)
  cmp rax, 0x09         # Test if both set
  jne ipc_denied        # Deny if not
```

Combined mask 0x09 = 0000_1001 = bits 0 and 3.

If either OP_SEND or OP_RECV lacks the required rights combination, the handler jumps to ipc_denied, emits cap_denied_msg tag, and returns INVOKE_DENIED (0xFFFFFFFFFFFFFFFD).

---

## Section 6 — ipc_enqueue / ipc_dequeue Delegation

The handler delegates OP_SEND and OP_RECV to the IPC module's channel primitives:

```
pub let ipc_enqueue : (u64) -> u64 = fn (msg: u64) -> unsafe { ... }
pub let ipc_dequeue : () -> u64 = fn () -> unsafe { ... }
```

Located in `src/kernel/core/ipc/enqueue.pdx` and `src/kernel/core/ipc/dequeue.pdx` (modules Enqueue, Dequeue). Current state (R8-B6-002/003): real implementations using a 64-slot SPSC ring stored at `channel_data` global.

### OP_SEND Delegation

```
# Extract message from op_arg[63:8]
mov rdi, rdx                   # Copy op_arg to rdi
shr rdi, 8                     # Shift right 8 bits: rdi = op_arg >> 8 (payload)
call ipc_enqueue               # Call with msg in rdi
# ipc_enqueue returns 1 (success) or 0 (ring full) in rax
ret                            # Return result
```

### OP_RECV Delegation

```
# No arguments; channel_data global is implicit
call ipc_dequeue               # Call with no args
# ipc_dequeue returns message in rax (0 if empty)
ret                            # Return result
```

Both primitives are callable unqualified (no module-prefix), requiring them to be exported as `pub let`. At R12-m4-001 open, both must be public symbols.

---

## Section 7 — paideia-as Encoder Constraints and Workarounds

### Constraint PA-R12-003: Inline Literals for Top-Bit-Set Values

paideia-as v0.11.0+19 (commit 43d62f9) fixed encoder PA-R12-003 to handle inline imm64 literals where the top bit is set. The handler's two sentinel values have the top bit set:

- `INVOKE_UNSUPPORTED = 0xFFFFFFFFFFFFFFFC` (bits [63:2] all 1)
- `INVOKE_DENIED = 0xFFFFFFFFFFFFFFFD` (bits [63:3] all 1, bit [0] = 1)

Prior to PA-R12-003, these would fail to encode. As of v0.11.0+19, they encode correctly:

```
mov rax, 0xFFFFFFFFFFFFFFFC      # Encodes as: movabs rax, 0xFFFFFFFFFFFFFFFC
mov rax, 0xFFFFFFFFFFFFFFFD      # Encodes as: movabs rax, 0xFFFFFFFFFFFFFFFD
```

Byte-verification (see Verification plan §4) confirms both movabs forms appear in the object code.

### Constraint: Module-level let Constants NOT Accessible as Immediate Operands

Module-level `let` constants (like `R12_IPC_STUB_SENTINEL`) are **not accessible as immediate operands** in inline assembly. All rights masks and sentinel values must be written as inline hex literals:

```
and rax, 0x0A                  # RIGHT_INVOKE | RIGHT_WRITE (inline literal)
and rax, 0x09                  # RIGHT_INVOKE | RIGHT_READ (inline literal)
mov rax, 0xFFFFFFFFFFFFFFFC    # INVOKE_UNSUPPORTED (inline literal)
mov rax, 0xFFFFFFFFFFFFFFFD    # INVOKE_DENIED (inline literal)
```

### Constraint: No qword ptr Prefix

paideia-as does not use Intel syntax `qword ptr` prefix. Memory operands are written plainly (though KIND_IPC_ENDPOINT has no memory operands in its dispatch path).

---

## Section 8 — Rights-Failure Witness Pattern

The handler's rights-denial paths (ipc_denied label) are exercised by m5-001's cap_dispatch_smoke test. Five test cases:

**Test case 1: OP_SEND without RIGHT_INVOKE**
- rights = 0x02 (RIGHT_WRITE only)
- op_arg = 0x0000000000ABCD03 (OP_SEND with message 0x0000000000ABCD)
- Expected: cap_denied_msg emitted, INVOKE_DENIED returned

**Test case 2: OP_SEND without RIGHT_WRITE**
- rights = 0x08 (RIGHT_INVOKE only)
- op_arg = 0x0000000000ABCD03 (OP_SEND with message)
- Expected: cap_denied_msg emitted, INVOKE_DENIED returned

**Test case 3: OP_SEND with full rights**
- rights = 0x0A (RIGHT_INVOKE + RIGHT_WRITE)
- op_arg = 0x0000000000CAFEBABE03 (OP_SEND with message 0x0000000000CAFEBABE)
- Expected: ipc_enqueue called, result returned (1 or 0), no denial

**Test case 4: OP_RECV without RIGHT_INVOKE**
- rights = 0x01 (RIGHT_READ only)
- op_arg = 0x0000000000000004 (OP_RECV)
- Expected: cap_denied_msg emitted, INVOKE_DENIED returned

**Test case 5: OP_RECV with full rights**
- rights = 0x09 (RIGHT_INVOKE + RIGHT_READ)
- op_arg = 0x0000000000000004 (OP_RECV)
- Expected: ipc_dequeue called, message returned (or 0 if empty), no denial

The cap_ipc_msg tag is always emitted (entry diagnostic). The cap_denied_msg tag is emitted only if rights check fails.

---

## Section 9 — Link-Resolution Witness

After build, the following symbols must be present:

```bash
nm build/kernel.elf | grep -E "cap_handler_ipc|ipc_enqueue|ipc_dequeue|cap_ipc_msg|cap_denied_msg"
```

Expected output (5 lines):

```
<addr> T cap_handler_ipc         # Executable text symbol
<addr> T ipc_enqueue             # Executable text symbol (called by handler for OP_SEND)
<addr> T ipc_dequeue             # Executable text symbol (called by handler for OP_RECV)
<addr> R cap_ipc_msg             # Read-only data (string)
<addr> R cap_denied_msg          # Read-only data (string)
```

**Dependency note**: If ipc_enqueue or ipc_dequeue is not exported as pub in their respective .pdx files, the link will fail with "undefined reference to ipc_enqueue" or "undefined reference to ipc_dequeue" because kind_ipc.pdx cannot call a private symbol. This is a build gate: m4-001 depends on both being pub.

---

## Section 10 — Regression Preservation

R12-m4-001 must not break existing smoke tests:

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

- **#405 (r12-m1-002)**: Dispatch architectural audit (tag discipline, handler ABI) — defines cap_ipc_msg and cap_denied_msg.
- **#406 (r12-m2-001)**: Dispatcher skeleton (calls handlers) — invoke.pdx entry point; establish handler call convention.
- **#407 (r12-m2-002)**: Stub handlers (placeholders replaced by m4-001) — m2-002 is superseded; m4-001 is real body.
- **#408 (r12-m3-001)**: Real kind_page handler (OP_READ/OP_WRITE) — parallel work (can land in either order after m2-002).
- **#409 (r12-m3-002)**: Real kind_sched handler (OP_YIELD) — parallel work (can land in either order after m2-002).
- **#411 (r12-m4-002)**: Real kind_dev handler (OP_MAP_MMIO) — similar structure (rights check, diagnostic, primitive delegation).
- **#412 (r12-m5)**: Regression matrix and cap_dispatch_smoke — runtime witness for all handlers; exercises all four kinds.

### File Dependencies

- **src/kernel/core/cap/invoke.pdx** (m2-001): Dispatcher that calls cap_handler_ipc.
- **src/kernel/core/cap/tags.pdx** (m1-002): Defines cap_ipc_msg, cap_denied_msg (external symbols).
- **src/kernel/core/uart.pdx**: uart_puts and uart_putc (entry point for diagnostic emission).
- **src/kernel/core/ipc/enqueue.pdx**: ipc_enqueue primitive that OP_SEND delegates to. **Must export ipc_enqueue as pub.**
- **src/kernel/core/ipc/dequeue.pdx**: ipc_dequeue primitive that OP_RECV delegates to. **Must export ipc_dequeue as pub.**
- **design/audit/entries/r12-m1-002-dispatch-arch.md**: Architectural context (handler ABI, tag discipline).
- **design/audit/entries/r12-m2-002-stub-handlers.md**: Previous audit (m2-002 stubs); m4-001 is successor.
- **design/audit/entries/r12-m3-002-kind-sched.md**: Parallel handler audit (m3-002); establishes register-preservation pattern.

---

## Section 12 — Validation Checklist

R12-m4-001 is complete when:

- [ ] File src/kernel/core/cap/kind_ipc.pdx contains real cap_handler_ipc implementation.
- [ ] Handler module name is KindIpc.
- [ ] Handler symbol name is cap_handler_ipc.
- [ ] Handler takes three u64 arguments (rights, target_ptr, op_arg).
- [ ] Handler declares effects {mem, sysreg} and capabilities {cap}.
- [ ] Entry diagnostic emits cap_ipc_msg (lea + call uart_puts).
- [ ] OP_SEND (op_code=3) path: check (RIGHT_INVOKE | RIGHT_WRITE) = 0x0A, extract message from op_arg[63:8], call ipc_enqueue, return result.
- [ ] OP_RECV (op_code=4) path: check (RIGHT_INVOKE | RIGHT_READ) = 0x09, call ipc_dequeue, return result.
- [ ] Unknown op_code path: return INVOKE_UNSUPPORTED (0xFFFFFFFFFFFFFFFC).
- [ ] Rights-failure path: emit cap_denied_msg, return INVOKE_DENIED (0xFFFFFFFFFFFFFFFD).
- [ ] RDX preserved across uart_puts (push before, pop after) — critical for op_arg integrity.
- [ ] RSI preserved across uart_puts (for register-discipline uniformity with m3-002).
- [ ] RDI preserved across uart_puts (for rights register integrity).
- [ ] build/kernel.elf links successfully (cap_handler_ipc, ipc_enqueue, ipc_dequeue symbols resolved).
- [ ] nm output shows cap_handler_ipc (T), ipc_enqueue (T), ipc_dequeue (T), cap_ipc_msg (R), cap_denied_msg (R).
- [ ] Smoke tests boot_r8_only, boot_r10, boot_r11 pass byte-identically.
- [ ] No decorative Unicode or emojis in source or audit.

---

## Trailer

**Audit date**: 2026-07-03
**Issue**: #410
**Status**: Ready for implementation, verification, and regression matrix check (issue #412).
