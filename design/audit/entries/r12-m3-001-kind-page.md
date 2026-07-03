---
audit_id: r12-m3-001-kind-page
issue: 408
file: src/kernel/core/cap/kind_page.pdx
function: cap_handler_page, _r12_mem_test_buf
effects: [mem, sysreg]
capabilities: [cap]
reviewed_by:
date: 2026-07-02
---

# AUDIT r12-m3-001 — KIND_PAGE Real Handler: OP_READ / OP_WRITE

## Section 1 — Overview

R12-m3-001 replaces the m2-002 stub handler with a real implementation of cap_handler_page. This is the largest per-handler surface in R12 capability dispatch: it must decode operation codes, enforce rights discipline, perform two memory access patterns (read from array, write sentinel), and emit diagnostic tags.

The handler implements:

1. **OP_READ (op_code=1)**: Extract array index from op_arg[63:8], check RIGHT_READ (bit 0), return array element or deny.
2. **OP_WRITE (op_code=2)**: Write 0xCAFEBABE to first element of array, check RIGHT_WRITE (bit 1), return success or deny.
3. **Diagnostic emission**: Tags emitted via uart_puts at entry (cap_mem_msg) and on rights failure (cap_denied_msg).
4. **Error returns**: INVOKE_UNSUPPORTED (0xFFFFFFFFFFFFFFFC) for unknown op_code; INVOKE_DENIED (0xFFFFFFFFFFFFFFFD) for rights failure.

The real body must preserve the register discipline established in m2-002 (entry/exit via RDI/RSI/RDX, return via RAX), extend it to handle cross-uart_puts clobber, and pass the rights+memory validation patterns required by m5-001's cap_dispatch_smoke test.

---

## Section 2 — Assembly Sequence (Annotated)

The full handler body, with per-line commentary:

```
# ENTRY: Preserve caller state across diagnostic emit
1.  push rdi                       # Save rights (caller-saved, but uart_puts may clobber rdi)
2.  push rsi                       # Save target_ptr (uart_puts uses rsi)
3.  push rdx                       # Save op_arg (uart_putc will clobber dx, destroying index bits [63:8])

# DIAGNOSTIC: Emit entry tag on COM1
4.  lea rdi, [rip + cap_mem_msg]   # Load cap_mem_msg string address (RIP-relative)
5.  call uart_puts                 # Emit "CAP INVOKE MEM\n" on COM1

# EXIT-RESTORE: Recover all caller state before op dispatch
6.  pop rdx                        # Restore op_arg (index bits [63:8] now safe)
7.  pop rsi                        # Restore target_ptr
8.  pop rdi                        # Restore rights

# DECODE OP_CODE (bits [7:0] of op_arg)
9.  mov r8, rdx                    # Copy op_arg to r8
10. and r8, 0xFF                   # Mask to extract bits [7:0] = op_code

# DISPATCH
11. cmp r8, 1                      # Is op_code == 1 (OP_READ)?
12. je do_read                     # Jump to OP_READ handler if so

13. cmp r8, 2                      # Is op_code == 2 (OP_WRITE)?
14. je do_write                    # Jump to OP_WRITE handler if so

# UNKNOWN OP (fallthrough)
15. mov rax, 0xFFFFFFFFFFFFFFFC    # Load INVOKE_UNSUPPORTED
16. ret                            # Return to dispatcher

# OP_READ HANDLER (label do_read:)
17. mov rax, rdi                   # Copy rights to rax
18. and rax, 0x01                  # Mask to extract bit 0 = RIGHT_READ
19. cmp rax, 0x01                  # Is RIGHT_READ bit set?
20. jne mem_denied                 # Jump to rights-failure handler if not

# OP_READ: Extract index and fetch
21. mov r9, rdx                    # Copy op_arg to r9
22. shr r9, 8                      # Shift right 8 bits; now r9 = op_arg[63:8]
23. mov rax, [rsi + r9 * 8]        # SIB: load array[index] (scale=8 for u64)
24. ret                            # Return array element in rax

# OP_WRITE HANDLER (label do_write:)
25. mov rax, rdi                   # Copy rights to rax
26. and rax, 0x02                  # Mask to extract bit 1 = RIGHT_WRITE
27. cmp rax, 0x02                  # Is RIGHT_WRITE bit set?
28. jne mem_denied                 # Jump to rights-failure handler if not

# OP_WRITE: Store sentinel to first element
29. mov rax, 0xCAFEBABE            # Load sentinel to rax (E11-4: two-instruction store workaround)
30. mov [rsi], rax                 # Store rax to array[0] (no imm32 form available)

# OP_WRITE: Success return
31. mov rax, 0                     # Load success result (0)
32. ret                            # Return to dispatcher

# RIGHTS-DENIED HANDLER (label mem_denied:)
33. lea rdi, [rip + cap_denied_msg] # Load cap_denied_msg string address
34. call uart_puts                 # Emit "CAP DENIED\n" on COM1
35. mov rax, 0xFFFFFFFFFFFFFFFD    # Load INVOKE_DENIED
36. ret                            # Return to dispatcher
```

**Line count**: 36 assembly lines (including labels, comment-only lines not counted).

---

## Section 3 — Register-Preservation Discipline Across uart_puts

### The RDX Clobber Problem

Standard System V AMD64 ABI classifies RDX as caller-saved. However, uart_putc (called via uart_puts) executes `mov dx, 0x3FD` to select I/O port 0x3FD, which **clobbers the low 16 bits of RDX**. This is critical:

- **op_arg arrives in RDX**, with index bits at [63:8].
- **Index <= 255** maps to RDX[7:0]; clobbering DX destroys these bits.
- **Index > 255** maps to RDX[15:8] and above; clobbering DX only destroys [7:0], leaving [63:8] intact.

To preserve all index bits, **RDX must be saved to the stack before uart_puts and restored after**. The stack discipline is:

```
push rdi, rsi, rdx  # Save before uart_puts

lea rdi, [rip + cap_mem_msg]
call uart_puts      # clobbers rdi, rsi, dx

pop rdx, rsi, rdi   # Restore after uart_puts; rdx now has [63:8] intact
```

Note: The pop order (rdx, rsi, rdi) restores in reverse LIFO order to match the push order (rdi, rsi, rdx).

---

## Section 4 — op_arg Encoding for KIND_PAGE

The cap_invoke_dispatch caller (invoke.pdx, m2-001) passes the original op_arg unchanged in RDX:

| Bits | Field | Purpose | Example |
|---|---|---|---|
| [7:0] | op_code | Operation selector | 1=READ, 2=WRITE, others=UNSUPPORTED |
| [63:8] | payload | Operation-specific data | For READ: array index (0-7); for WRITE: unused |

**OP_READ example**: op_arg = 0x0000000000000101
- op_code = 0x01 (READ)
- payload (index) = 0x0000000000000100 >> 8 = 0x01 (index 1)

**OP_WRITE example**: op_arg = 0x0000000000000002
- op_code = 0x02 (WRITE)
- payload = 0x0000000000000000 (ignored)

---

## Section 5 — Rights Discipline

The handler enforces two right bits:

| Bit | Name | Purpose |
|---|---|---|
| 0 | RIGHT_READ | Allows OP_READ (read from array) |
| 1 | RIGHT_WRITE | Allows OP_WRITE (write to array[0]) |

Check pattern:

```
For OP_READ:
  mov rax, rdi          # Load rights
  and rax, 0x01         # Mask bit 0
  cmp rax, 0x01         # Test if set
  jne mem_denied        # Deny if not

For OP_WRITE:
  mov rax, rdi          # Load rights
  and rax, 0x02         # Mask bit 1
  cmp rax, 0x02         # Test if set
  jne mem_denied        # Deny if not
```

If a right is missing, the handler jumps to mem_denied, emits cap_denied_msg tag, and returns INVOKE_DENIED (0xFFFFFFFFFFFFFFFD).

---

## Section 6 — Test-Buffer Layout

The handler reads from and writes to **_r12_mem_test_buf**, a 64-byte global BSS array:

```
pub let mut _r12_mem_test_buf : [u64; 8] = uninit
```

Layout (linear addresses within the buffer, assuming rsi = &_r12_mem_test_buf):

| Index | Address | Content (Initial) | Used by |
|---|---|---|---|
| 0 | rsi+0 | uninit (written by OP_WRITE) | OP_WRITE target |
| 1 | rsi+8 | uninit (readable by OP_READ) | OP_READ test |
| 2 | rsi+16 | uninit | Reserved |
| 3 | rsi+24 | uninit | Reserved |
| 4 | rsi+32 | uninit | Reserved |
| 5 | rsi+40 | uninit | Reserved |
| 6 | rsi+48 | uninit | Reserved |
| 7 | rsi+56 | uninit | Reserved |

Size: 8 * 8 = 64 bytes (0x40). BSS symbol (B type in nm).

Indexing via SIB: `mov rax, [rsi + r9 * 8]` where r9 = index, scale=8 (byte offset = index * 8).

---

## Section 7 — paideia-as Encoder Constraints and Workarounds

### Constraint E11-4: No mov [mem], imm32

**Problem**: paideia-as v0.11.0+19 does not encode `mov [rsi], 0xCAFEBABE` (destination is memory, source is 32-bit immediate).

**Workaround**: Two-instruction sequence
```
mov rax, 0xCAFEBABE    # Load immediate into register
mov [rsi], rax         # Store register to memory
```

This sequence is 10 bytes (mov imm64 + mov mem64) but is supported by the encoder.

### Constraint: Inline Literals Required

Module-level `let` constants (e.g., `let ERROR_CODE = 0xFFFFFFFFFFFFFFFC`) are **not accessible as immediate operands** in inline assembly. All sentinel values, masks, and operation codes must be written as inline hex literals:

```
mov rax, 0xFFFFFFFFFFFFFFFC  # INVOKE_UNSUPPORTED (inline literal)
and r8, 0xFF                 # Mask (inline literal)
```

### Constraint: No qword ptr Prefix

paideia-as does not use Intel syntax `qword ptr` prefix. Memory operands are written plainly:

```
mov rax, [rsi + r9 * 8]      # Not: mov rax, qword ptr [rsi + r9 * 8]
```

### Constraint: SIB Scale=8 for u64 Indexing

Array indexing uses scaled index bytes (SIB) with scale=8:

```
mov rax, [rsi + r9 * 8]      # SIB: rsi (base) + r9 * 8 (scaled index)
```

This expands to ModRM byte + SIB byte, encoding base register (rsi=6), index register (r9=1, in R field of SIB), and scale (8=11b in scale field). Disassembly should show `4A 8B 04 CE` (approximately) for this form.

---

## Section 8 — Rights-Failure Witness Pattern

The handler's rights-denial path (mem_denied label) is exercised by m5-001's cap_dispatch_smoke test:

**Test case: OP_READ without RIGHT_READ**
- rights = 0x02 (only RIGHT_WRITE)
- op_arg = 0x0000000000000101 (OP_READ, index 1)
- Expected: cap_denied_msg emitted, INVOKE_DENIED returned

**Test case: OP_WRITE without RIGHT_WRITE**
- rights = 0x01 (only RIGHT_READ)
- op_arg = 0x0000000000000002 (OP_WRITE)
- Expected: cap_denied_msg emitted, INVOKE_DENIED returned

**Test case: OP_READ with RIGHT_READ**
- rights = 0x01 (RIGHT_READ)
- op_arg = 0x0000000000000101 (OP_READ, index 1)
- Expected: array[1] returned, no denial

**Test case: OP_WRITE with RIGHT_WRITE**
- rights = 0x02 (RIGHT_WRITE)
- op_arg = 0x0000000000000002 (OP_WRITE)
- Expected: array[0] = 0xCAFEBABE, success (0) returned

The cap_mem_msg tag is always emitted (entry diagnostic). The cap_denied_msg tag is emitted only if rights check fails.

---

## Section 9 — Link-Resolution Witness

After build, the following symbols must be present:

```bash
nm build/kernel.elf | grep -E "cap_handler_page|_r12_mem_test_buf|cap_mem_msg|cap_denied_msg"
```

Expected output (4 lines):

```
<addr> T cap_handler_page         # Executable text symbol
<addr> B _r12_mem_test_buf        # Uninitialized BSS symbol (size 0x40)
<addr> R cap_mem_msg              # Read-only data (string)
<addr> R cap_denied_msg           # Read-only data (string)
```

**BSS symbol verification**:

```bash
nm --print-size --size-sort build/kernel.elf | grep _r12_mem_test_buf
```

Expected: size = 0x40 (64 bytes).

---

## Section 10 — Regression Preservation

R12-m3-001 must not break existing smoke tests:

1. **boot_r8_only**: Tests basic boot; does not invoke capabilities. Handler is never called.
2. **boot_r10**: Tests multi-core LAPIC + EOI; does not invoke capabilities. Handler is never called.
3. **boot_r11**: Tests full boot sequence; does not invoke capabilities. Handler is never called.

Regression criteria:
- All three smokes must pass byte-identically (same output, same exit status).
- No changes to boot logic, LAPIC config, EOI, or scheduler.
- Handler is dead code until m5-001 (cap_dispatch_smoke) exercises it.

---

## Section 11 — Cross-References

### Issue Dependencies

- **#405 (r12-m1-002)**: Dispatch architectural audit (tag discipline, handler ABI) — defines cap_mem_msg and cap_denied_msg.
- **#406 (r12-m2-001)**: Dispatcher skeleton (calls handlers) — invoke.pdx entry point; establish handler call convention.
- **#407 (r12-m2-002)**: Stub handlers (placeholders replaced by m3-001) — m2-002 is superseded; m3-001 is real body.
- **#409 (r12-m3-002)**: Real kind_sched handler (OP_YIELD) — similar structure (rights check, diagnostic, operation dispatch).
- **#410 (r12-m4-001)**: Real kind_ipc handler (OP_SEND/OP_RECV) — larger payload handling.
- **#411 (r12-m4-002)**: Real kind_dev handler (OP_MAP_MMIO) — hardware access.
- **#412 (r12-m5)**: Regression matrix and cap_dispatch_smoke — runtime witness for all handlers; exercises all four kinds.

### File Dependencies

- **src/kernel/core/cap/invoke.pdx** (m2-001): Dispatcher that calls cap_handler_page.
- **src/kernel/core/cap/tags.pdx** (m1-002): Defines cap_mem_msg, cap_denied_msg (external symbols).
- **src/kernel/core/uart.pdx**: uart_puts and uart_putc (entry point for diagnostic emission).
- **design/audit/entries/r12-m1-002-dispatch-arch.md**: Architectural context (handler ABI, tag discipline).
- **design/audit/entries/r12-m2-002-stub-handlers.md**: Previous audit (m2-002 stubs); m3-001 is successor.

---

## Section 12 — Validation Checklist

R12-m3-001 is complete when:

- [ ] File src/kernel/core/cap/kind_page.pdx contains real cap_handler_page implementation.
- [ ] Handler module name is KindPage.
- [ ] Handler symbol name is cap_handler_page.
- [ ] Handler takes three u64 arguments (rights, target_ptr, op_arg).
- [ ] Handler declares effects {mem, sysreg} and capabilities {cap}.
- [ ] Entry diagnostic emits cap_mem_msg (lea + call uart_puts).
- [ ] OP_READ path: check RIGHT_READ, extract index, perform SIB load, return.
- [ ] OP_WRITE path: check RIGHT_WRITE, write 0xCAFEBABE via two-instruction store, return 0.
- [ ] Unknown op_code path: return INVOKE_UNSUPPORTED (0xFFFFFFFFFFFFFFFC).
- [ ] Rights-failure path: emit cap_denied_msg, return INVOKE_DENIED (0xFFFFFFFFFFFFFFFD).
- [ ] RDX preserved across uart_puts (push before, pop after).
- [ ] _r12_mem_test_buf declared as pub let mut [u64; 8] in KindPage module.
- [ ] BSS symbol _r12_mem_test_buf present in build/kernel.elf (B type, size 0x40).
- [ ] build/kernel.elf links successfully (all four symbols resolved).
- [ ] nm output shows cap_handler_page (T), _r12_mem_test_buf (B), cap_mem_msg (R), cap_denied_msg (R).
- [ ] Smoke tests boot_r8_only, boot_r10, boot_r11 pass byte-identically.
- [ ] No decorative Unicode or emojis in source or audit.

---

## Trailer

**Audit date**: 2026-07-02  
**Issue**: #408  
**Status**: Ready for implementation, verification, and regression matrix check (issue #412).
