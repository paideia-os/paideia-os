---
audit_id: r12-m4-002-kind-dev
issue: 411
file: src/kernel/core/cap/kind_dev.pdx
function: cap_handler_dev
effects: [mem, sysreg]
capabilities: [cap]
reviewed_by:
date: 2026-07-03
---

# AUDIT r12-m4-002 — KIND_DEVICE Real Handler: OP_MAP_MMIO

## Section 1 — Overview

R12-m4-002 replaces the m2-002 stub handler with a real implementation of cap_handler_dev. This handler implements one operation (OP_MAP_MMIO, op_code=6) that wraps the D7-005 capability dispatch point request_mmio_mapping, which performs MMIO region capability minting and virtual-address mapping into the requesting task's aspace.

The handler implements:

1. **OP_MAP_MMIO (op_code=6)**: Check RIGHT_INVOKE (bit 3) + RIGHT_WRITE (bit 1) (combined as 0x0A), call request_mmio_mapping with LAPIC test arguments (phys_base=0xFEE00000, length=0x1000, flags=0), return mapped virtual address or denial sentinel.
2. **Diagnostic emission**: Tag emitted via uart_puts at entry (cap_dev_msg) and on rights failure (cap_denied_msg).
3. **Error returns**: INVOKE_UNSUPPORTED (0xFFFFFFFFFFFFFFFC) for unknown op_code; INVOKE_DENIED (0xFFFFFFFFFFFFFFFD) for rights failure.

The real body must preserve the register discipline established in m2-002 (entry/exit via RDI/RSI/RDX, return via RAX), extend it to handle cross-uart_puts clobber (matching m3-002's pattern), and pass the rights validation gating required by m5-001's cap_dispatch_smoke test.

**Scope note (R12):** The handler uses fixed LAPIC MMIO test arguments (phys_base=0xFEE00000, length=0x1000). Dynamic per-request physical base addresses are deferred to R13 when the full capability-scoped address translation lands. The target_ptr parameter is unused for R12 device operations.

---

## Section 2 — Assembly Sequence (Annotated)

The full handler body, with per-line commentary:

```
# ENTRY: Preserve caller state across diagnostic emit
1.  push rdi                       # Save rights (caller-saved, but uart_puts may clobber rdi)
2.  push rsi                       # Save target_ptr (uart_puts uses rsi; unused for DEV but preserved for uniformity)
3.  push rdx                       # Save op_arg (uart_putc will clobber dx, destroying op_arg[7:0])

# DIAGNOSTIC: Emit entry tag on COM1
4.  lea rdi, [rip + cap_dev_msg]   # Load cap_dev_msg string address (RIP-relative)
5.  call uart_puts                 # Emit "CAP INVOKE DEV\n" on COM1

# EXIT-RESTORE: Recover all caller state before op dispatch
6.  pop rdx                        # Restore op_arg (now safe from uart_putc clobber)
7.  pop rsi                        # Restore target_ptr (unused for DEV; restored for uniformity with m3-002)
8.  pop rdi                        # Restore rights

# DECODE OP_CODE (bits [7:0] of op_arg)
9.  mov r8, rdx                    # Copy op_arg to r8
10. and r8, 0xFF                   # Mask to extract bits [7:0] = op_code

# DISPATCH
11. cmp r8, 6                      # Is op_code == 6 (OP_MAP_MMIO)?
12. je do_map_mmio                 # Jump to OP_MAP_MMIO handler if so

# UNKNOWN OP (fallthrough)
13. mov rax, 0xFFFFFFFFFFFFFFFC    # Load INVOKE_UNSUPPORTED
14. ret                            # Return to dispatcher

# OP_MAP_MMIO HANDLER (label do_map_mmio:)
15. mov rax, rdi                   # Copy rights to rax
16. and rax, 0x0A                  # Mask to extract bits 3,1 = (RIGHT_INVOKE, RIGHT_WRITE)
17. cmp rax, 0x0A                  # Is (RIGHT_INVOKE | RIGHT_WRITE) both set?
18. jne dev_denied                 # Jump to rights-failure handler if not

# OP_MAP_MMIO: Delegate to MMIO mapping primitive with fixed test args
19. mov rsi, 0xFEE00000            # Load LAPIC MMIO physical base
20. mov rdx, 0x1000                # Load MMIO region length (4 KiB)
21. mov rcx, 0                     # Load flags (no special flags in R12)
22. call request_mmio_mapping      # Call with rights in rdi (already set), phys_base in rsi, length in rdx, flags in rcx
23. ret                            # Return mapped vaddr (or 0 on denial)

# RIGHTS-DENIED HANDLER (label dev_denied:)
24. lea rdi, [rip + cap_denied_msg] # Load cap_denied_msg string address
25. call uart_puts                 # Emit "CAP DENIED\n" on COM1
26. mov rax, 0xFFFFFFFFFFFFFFFD    # Load INVOKE_DENIED
27. ret                            # Return to dispatcher
```

**Line count**: 27 assembly lines (including labels, comment-only lines not counted).

---

## Section 3 — Register-Preservation Discipline Across uart_puts

### The RDX Clobber Problem (Matched from m3-002)

Standard System V AMD64 ABI classifies RDX as caller-saved. However, uart_putc (called via uart_puts) executes `mov dx, 0x3FD` to select I/O port 0x3FD, which **clobbers the low 16 bits of RDX**. This is critical for OP_MAP_MMIO:

- **op_arg arrives in RDX**, with message payload at [63:8] (unused in R12 OP_MAP_MMIO) or other op-specific data.
- **Low byte (op_code) is in RDX[7:0]**.
- **Clobbering DX destroys RDX[15:0]**, losing op_code bits [15:0].

To preserve the op_arg (and especially the op_code for dispatch), **RDX must be saved to the stack before uart_puts and restored after**. The stack discipline matches m3-002:

```
push rdi, rsi, rdx  # Save before uart_puts

lea rdi, [rip + cap_dev_msg]
call uart_puts      # clobbers rdi, rsi, dx

pop rdx, rsi, rdi   # Restore after uart_puts; rdx now intact
```

### RSI Preservation (Uniform with m3-002)

RSI (target_ptr) is unused by OP_MAP_MMIO in R12 (the MMIO mapping logic uses fixed test arguments, not indexed by target_ptr). However, m3-002 (KIND_SCHED_CTX) preserves RSI, and R12's dispatch discipline requires uniform register discipline across all handlers for debuggability. Therefore, RSI is saved and restored even though OP_MAP_MMIO doesn't read it.

---

## Section 4 — op_arg Encoding for KIND_DEVICE

The cap_invoke_dispatch caller (invoke.pdx, m2-001) passes the original op_arg unchanged in RDX:

| Bits | Field | Purpose | Example |
|---|---|---|---|
| [7:0] | op_code | Operation selector | 6=OP_MAP_MMIO, others=UNSUPPORTED |
| [63:8] | reserved | Reserved for future extensions | 0x0000000000000000 in R12 |

**OP_MAP_MMIO example**: op_arg = 0x0000000000000006
- op_code = 0x06 (OP_MAP_MMIO)
- reserved = 0x0000000000000000

---

## Section 5 — Rights Discipline

The handler enforces rights for OP_MAP_MMIO:

### OP_MAP_MMIO Rights

| Bit | Name | Purpose |
|---|---|---|
| 3 | RIGHT_INVOKE | Allows invoking any capability-mediated operation |
| 1 | RIGHT_WRITE | Allows performing MMIO mapping requests (write-side access to capability interface) |

**Note on R_DRIVER_MMIO overlap**: dispatch.pdx defines `R_DRIVER_MMIO = 0x2` (bit 1). The handler's RIGHT_WRITE check (bit 1) coincides with R_DRIVER_MMIO's definition. This is by design: a KIND_DRIVER capability carrying R_DRIVER_MMIO is eligible to invoke OP_MAP_MMIO on a KIND_DEVICE capability that requires RIGHT_INVOKE | RIGHT_WRITE. The semantic overlap is intentional.

Check pattern:

```
For OP_MAP_MMIO:
  mov rax, rdi          # Load rights
  and rax, 0x0A         # Mask bits 3,1 = (RIGHT_INVOKE, RIGHT_WRITE)
  cmp rax, 0x0A         # Test if both set
  jne dev_denied        # Deny if not
```

Combined mask 0x0A = 0000_1010 = bits 1 and 3.

If OP_MAP_MMIO lacks the required rights combination, the handler jumps to dev_denied, emits cap_denied_msg tag, and returns INVOKE_DENIED (0xFFFFFFFFFFFFFFFD).

---

## Section 6 — request_mmio_mapping Delegation

The handler delegates OP_MAP_MMIO to the dispatch module's MMIO mapping primitive:

```
pub let request_mmio_mapping : (u64, u64, u64, u64) -> u64 = fn (driver_rights: u64) (phys_base: u64) (length: u64) (flags: u64) -> { ... }
```

Located in `src/kernel/core/cap/dispatch.pdx`, promoted from private to public by R12-m4-002 (issue #411). Current state (R7 permissive): accepts any non-zero phys_base/length, mints an MMIO region cap, calls aspace_map, and returns the mapped vaddr (or 0 on denial).

### OP_MAP_MMIO Delegation

```
# R12 test: Fixed LAPIC MMIO arguments
mov rsi, 0xFEE00000               # phys_base = LAPIC MMIO physical address
mov rdx, 0x1000                   # length = 4 KiB
mov rcx, 0                        # flags = 0 (no special flags)
call request_mmio_mapping         # Call with rights in rdi (already set from entry)
# request_mmio_mapping returns mapped vaddr in rax (or 0 if denied)
ret                               # Return result
```

The primitive is callable unqualified (no module-prefix), requiring it to be exported as `pub let`. At R12-m4-002 open, it must be a public symbol.

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

Module-level `let` constants (like `R12_DEV_STUB_SENTINEL`) are **not accessible as immediate operands** in inline assembly. All rights masks and sentinel values must be written as inline hex literals:

```
and rax, 0x0A                  # RIGHT_INVOKE | RIGHT_WRITE (inline literal)
mov rax, 0xFFFFFFFFFFFFFFFC    # INVOKE_UNSUPPORTED (inline literal)
mov rax, 0xFFFFFFFFFFFFFFFD    # INVOKE_DENIED (inline literal)
```

### Constraint: No qword ptr Prefix

paideia-as does not use Intel syntax `qword ptr` prefix. Memory operands are written plainly (though KIND_DEVICE has no memory operands in its dispatch path).

---

## Section 8 — Rights-Failure Witness Pattern

The handler's rights-denial path (dev_denied label) is exercised by m5-001's cap_dispatch_smoke test. Test cases:

**Test case 1: OP_MAP_MMIO without RIGHT_INVOKE**
- rights = 0x02 (RIGHT_WRITE only)
- op_arg = 0x0000000000000006 (OP_MAP_MMIO)
- Expected: cap_denied_msg emitted, INVOKE_DENIED returned

**Test case 2: OP_MAP_MMIO without RIGHT_WRITE**
- rights = 0x08 (RIGHT_INVOKE only)
- op_arg = 0x0000000000000006 (OP_MAP_MMIO)
- Expected: cap_denied_msg emitted, INVOKE_DENIED returned

**Test case 3: OP_MAP_MMIO with full rights**
- rights = 0x0A (RIGHT_INVOKE + RIGHT_WRITE)
- op_arg = 0x0000000000000006 (OP_MAP_MMIO)
- Expected: request_mmio_mapping called with fixed args, result returned (vaddr or 0), no denial

The cap_dev_msg tag is always emitted (entry diagnostic). The cap_denied_msg tag is emitted only if rights check fails.

---

## Section 9 — Link-Resolution Witness

After build, the following symbols must be present:

```bash
nm build/kernel.elf | grep -E "cap_handler_dev|request_mmio_mapping|cap_dev_msg|cap_denied_msg"
```

Expected output (4 lines):

```
<addr> T cap_handler_dev           # Executable text symbol
<addr> T request_mmio_mapping      # Executable text symbol (called by handler for OP_MAP_MMIO)
<addr> R cap_dev_msg               # Read-only data (string)
<addr> R cap_denied_msg            # Read-only data (string)
```

**Dependency note**: If request_mmio_mapping is not exported as pub in dispatch.pdx, the link will fail with "undefined reference to request_mmio_mapping" because kind_dev.pdx cannot call a private symbol. This is a build gate: m4-002 depends on request_mmio_mapping being promoted from private to public in dispatch.pdx.

---

## Section 10 — Regression Preservation

R12-m4-002 must not break existing smoke tests:

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

- **#405 (r12-m1-002)**: Dispatch architectural audit (tag discipline, handler ABI) — defines cap_dev_msg and cap_denied_msg.
- **#406 (r12-m2-001)**: Dispatcher skeleton (calls handlers) — invoke.pdx entry point; establish handler call convention.
- **#407 (r12-m2-002)**: Stub handlers (placeholders replaced by m4-002) — m2-002 is superseded; m4-002 is real body.
- **#408 (r12-m3-001)**: Real kind_page handler (OP_READ/OP_WRITE) — parallel work (can land in either order after m2-002).
- **#409 (r12-m3-002)**: Real kind_sched handler (OP_YIELD) — parallel work (can land in either order after m2-002).
- **#410 (r12-m4-001)**: Real kind_ipc handler (OP_SEND/OP_RECV) — parallel work (similar structure, symmetric operations).
- **#412 (r12-m5)**: Regression matrix and cap_dispatch_smoke — runtime witness for all handlers; exercises all four kinds.

### File Dependencies

- **src/kernel/core/cap/invoke.pdx** (m2-001): Dispatcher that calls cap_handler_dev.
- **src/kernel/core/cap/dispatch.pdx** (D7-005): Defines request_mmio_mapping (must export as pub). **Must be promoted to pub by m4-002.**
- **src/kernel/core/cap/tags.pdx** (m1-002): Defines cap_dev_msg, cap_denied_msg (external symbols).
- **src/kernel/core/uart.pdx**: uart_puts and uart_putc (entry point for diagnostic emission).
- **design/audit/entries/r12-m1-002-dispatch-arch.md**: Architectural context (handler ABI, tag discipline).
- **design/audit/entries/r12-m2-002-stub-handlers.md**: Previous audit (m2-002 stubs); m4-002 is successor.
- **design/audit/entries/r12-m3-002-kind-sched.md**: Parallel handler audit (m3-002); establishes register-preservation pattern.
- **design/audit/entries/r12-m4-001-kind-ipc.md**: Parallel handler audit (m4-001); similar structure (rights checks, diagnostics, primitive delegation).

---

## Section 12 — Validation Checklist

R12-m4-002 is complete when:

- [ ] File src/kernel/core/cap/kind_dev.pdx contains real cap_handler_dev implementation.
- [ ] Handler module name is KindDev.
- [ ] Handler symbol name is cap_handler_dev.
- [ ] Handler takes three u64 arguments (rights, target_ptr, op_arg).
- [ ] Handler declares effects {mem, sysreg} and capabilities {cap}.
- [ ] Entry diagnostic emits cap_dev_msg (lea + call uart_puts).
- [ ] OP_MAP_MMIO (op_code=6) path: check (RIGHT_INVOKE | RIGHT_WRITE) = 0x0A, set phys_base=0xFEE00000, length=0x1000, flags=0, call request_mmio_mapping, return result.
- [ ] Unknown op_code path: return INVOKE_UNSUPPORTED (0xFFFFFFFFFFFFFFFC).
- [ ] Rights-failure path: emit cap_denied_msg, return INVOKE_DENIED (0xFFFFFFFFFFFFFFFD).
- [ ] RDX preserved across uart_puts (push before, pop after) — critical for op_arg integrity.
- [ ] RSI preserved across uart_puts (for register-discipline uniformity with m3-002).
- [ ] RDI preserved across uart_puts (for rights register integrity).
- [ ] request_mmio_mapping promoted from private to public in dispatch.pdx (line 76).
- [ ] build/kernel.elf links successfully (cap_handler_dev, request_mmio_mapping symbols resolved).
- [ ] nm output shows cap_handler_dev (T), request_mmio_mapping (T), cap_dev_msg (R), cap_denied_msg (R).
- [ ] Smoke tests boot_r8_only, boot_r10, boot_r11 pass byte-identically.
- [ ] No decorative Unicode or emojis in source or audit.

---

## Trailer

**Audit date**: 2026-07-03
**Issue**: #411
**Status**: Ready for implementation, verification, and regression matrix check (issue #412).
