---
audit_id: r12-m5-001-dispatch-smoke
issue: 412
file: src/kernel/core/cap/dispatch_smoke.pdx
function: cap_dispatch_smoke
effects: [sysreg, mem]
capabilities: [cap]
reviewed_by:
date: 2026-07-03
---

# AUDIT r12-m5-001 — Capability Dispatch Smoke Test: Multi-Kind Invocation Matrix

## Section 1 — Overview

R12-m5-001 implements cap_dispatch_smoke, a comprehensive smoke fixture that exercises the capability dispatch system across all four capability kinds (KIND_PAGE, KIND_IPC_ENDPOINT, KIND_SCHED_CTX, KIND_DEVICE). This fixture:

1. Mints five capabilities into slots 4-8 with diverse kinds and rights.
2. Invokes each capability with specific operations and arguments.
3. Verifies return values against expected results.
4. Emits "CAP DISPATCH OK\n" on COM1 if all 7 invocations succeed.
5. Tests rights enforcement via a denial witness (slot 8: KIND_PAGE READ-only, invoked with OP_WRITE).

The fixture ensures that the dispatcher (invoke.pdx, m2-001), all four handler implementations (kind_page.pdx m3-001, kind_ipc.pdx m4-001, kind_sched.pdx m3-002, kind_dev.pdx m4-002), and the mint primitive (mint.pdx, m1-001) work correctly together under realistic operation.

---

## Section 2 — Slot Allocation and Invocation Matrix

### Slot Reservation Discipline

Slot 0 is reserved by cap_smoke (B5-005 smoke test). cap_dispatch_smoke uses slots 4-8:

| Slot | Kind | Rights | Target | Purpose | Invocation | Expected Result |
|---|---|---|---|---|---|---|
| 4 | KIND_PAGE | 0x03 (R\|W) | &_r12_mem_test_buf | Read/Write test | 2 invokes (OP_WRITE, OP_READ) | 0, 0xCAFEBABE |
| 5 | KIND_IPC_ENDPOINT | 0x0B (INVOKE\|R\|W) | 0 | Send/Recv test | 2 invokes (OP_SEND, OP_RECV) | 1, 0xDEAD |
| 6 | KIND_SCHED_CTX | 0x08 (INVOKE) | 7 | Yield test | 1 invoke (OP_YIELD) | 0 (YIELD_OK) |
| 7 | KIND_DEVICE | 0x0A (INVOKE\|R_DRIVER_MMIO) | 10 | MMIO mapping test | 1 invoke (OP_MAP_MMIO) | != 0 (non-zero vaddr) |
| 8 | KIND_PAGE | 0x01 (R) | &_r12_mem_test_buf | Rights denial witness | 1 invoke (OP_WRITE, should deny) | 0xFFFFFFFFFFFFFFFD (INVOKE_DENIED) |

### Invocation Sequence and Expected Returns

| Invocation # | Slot | Operation | op_arg | Expected Return | Test Purpose |
|---|---|---|---|---|---|
| 1 | 4 (PAGE) | OP_WRITE | 2 | 0 | Write to test buffer via slot 4 |
| 2 | 4 (PAGE) | OP_READ idx=0 | 1 | 0xCAFEBABE | Read back value written by OP_WRITE |
| 3 | 5 (IPC) | OP_SEND 0xDEAD | 0xDEAD03 | 1 | Send message; return 1 (message enqueued) |
| 4 | 5 (IPC) | OP_RECV | 4 | 0xDEAD | Receive message; return payload 0xDEAD |
| 5 | 6 (SCHED_CTX) | OP_YIELD | 5 | 0 (YIELD_OK) | Yield to scheduler |
| 6 | 7 (DEVICE) | OP_MAP_MMIO | 6 | != 0 | Request MMIO mapping for LAPIC; return virtual address |
| 7 | 8 (PAGE) | OP_WRITE (denial test) | 2 | 0xFFFFFFFFFFFFFFFD | Attempt write on READ-only slot; return INVOKE_DENIED |

---

## Section 3 — Mint Operations and Kind Registration

### cap_mint_write Invocations

All five mints use the direct implementation cap_mint_write (MVP pattern; full curried functions deferred to Phase 7+):

```
cap_mint_write(slot: u64, kind: u64, rights: u64, target_ptr: u64) -> ()
```

Argument order: RDI (slot), RSI (kind), RDX (rights), RCX (target_ptr).

### Slot 4 (KIND_PAGE R/W)

```
mov rdi, 4                                    # Slot 4
mov rsi, 4                                    # kind = 4 (KIND_PAGE)
mov rdx, 0x03                                 # rights = 0x03 (RIGHT_READ | RIGHT_WRITE)
lea rcx, [rip + _r12_mem_test_buf]           # target_ptr = address of test buffer
call cap_mint_write
```

### Slot 5 (KIND_IPC_ENDPOINT INVOKE|R|W)

```
mov rdi, 5                                    # Slot 5
mov rsi, 5                                    # kind = 5 (KIND_IPC_ENDPOINT)
mov rdx, 0x0B                                 # rights = 0x0B (INVOKE | RIGHT_READ | RIGHT_WRITE)
mov rcx, 0                                    # target_ptr unused for IPC
call cap_mint_write
```

### Slot 6 (KIND_SCHED_CTX INVOKE)

```
mov rdi, 6                                    # Slot 6
mov rsi, 7                                    # kind = 7 (KIND_SCHED_CTX)
mov rdx, 0x08                                 # rights = 0x08 (RIGHT_INVOKE)
mov rcx, 0                                    # target_ptr unused for SCHED_CTX
call cap_mint_write
```

### Slot 7 (KIND_DEVICE INVOKE|R_DRIVER_MMIO)

```
mov rdi, 7                                    # Slot 7
mov rsi, 10                                   # kind = 10 (KIND_DEVICE)
mov rdx, 0x0A                                 # rights = 0x0A (RIGHT_INVOKE | R_DRIVER_MMIO)
mov rcx, 0                                    # target_ptr unused for DEVICE
call cap_mint_write
```

### Slot 8 (KIND_PAGE R only, denial witness)

```
mov rdi, 8                                    # Slot 8
mov rsi, 4                                    # kind = 4 (KIND_PAGE)
mov rdx, 0x01                                 # rights = 0x01 (RIGHT_READ only)
lea rcx, [rip + _r12_mem_test_buf]           # target_ptr = address of test buffer
call cap_mint_write
```

---

## Section 4 — Invocation Sequence (Annotated Assembly)

### Invocation 1: Slot 4, OP_WRITE

```
mov rdi, 4                    # slot = 4 (PAGE)
mov rsi, 2                    # op_arg = 2 (OP_WRITE)
call cap_invoke_dispatch      # call dispatcher
cmp rax, 0                     # compare return to 0
jne dispatch_smoke_fail        # fail if not 0
```

Expected: kind_page.pdx handler executes OP_WRITE, writes 0xCAFEBABE to [rsi] (test buffer base), returns 0.

### Invocation 2: Slot 4, OP_READ idx=0

```
mov rdi, 4                    # slot = 4 (PAGE)
mov rsi, 1                    # op_arg = 1 (OP_READ with index bits [63:8] = 0)
call cap_invoke_dispatch      # call dispatcher
mov r10, 0xCAFEBABE           # load expected value into r10 (scratch)
cmp rax, r10                  # compare return to 0xCAFEBABE
jne dispatch_smoke_fail        # fail if not match
```

Expected: kind_page.pdx handler executes OP_READ, reads from [target_ptr + index*8] = [test buffer + 0*8], returns 0xCAFEBABE (written by Invocation 1).

### Invocation 3: Slot 5, OP_SEND payload 0xDEAD

```
mov rdi, 5                    # slot = 5 (IPC_ENDPOINT)
mov rsi, 0xDEAD03            # op_arg = 0xDEAD03 (op_code=3 OP_SEND | payload=0xDEAD at [63:8])
call cap_invoke_dispatch      # call dispatcher
cmp rax, 1                     # compare return to 1 (message enqueued)
jne dispatch_smoke_fail        # fail if not 1
```

Expected: kind_ipc.pdx handler executes OP_SEND, enqueues message 0xDEAD, returns 1.

### Invocation 4: Slot 5, OP_RECV

```
mov rdi, 5                    # slot = 5 (IPC_ENDPOINT)
mov rsi, 4                    # op_arg = 4 (OP_RECV)
call cap_invoke_dispatch      # call dispatcher
cmp rax, 0xDEAD                # compare return to 0xDEAD
jne dispatch_smoke_fail        # fail if not match
```

Expected: kind_ipc.pdx handler executes OP_RECV, dequeues message 0xDEAD (sent by Invocation 3), returns 0xDEAD.

### Invocation 5: Slot 6, OP_YIELD

```
mov rdi, 6                    # slot = 6 (SCHED_CTX)
mov rsi, 5                    # op_arg = 5 (OP_YIELD)
call cap_invoke_dispatch      # call dispatcher
cmp rax, 0                     # compare return to 0 (YIELD_OK)
jne dispatch_smoke_fail        # fail if not 0
```

Expected: kind_sched.pdx handler executes OP_YIELD, yields to scheduler, returns 0 (YIELD_OK).

### Invocation 6: Slot 7, OP_MAP_MMIO

```
mov rdi, 7                    # slot = 7 (DEVICE)
mov rsi, 6                    # op_arg = 6 (OP_MAP_MMIO)
call cap_invoke_dispatch      # call dispatcher
cmp rax, 0                     # compare return to 0
je dispatch_smoke_fail         # fail if return IS 0 (expect non-zero vaddr)
```

Expected: kind_dev.pdx handler executes OP_MAP_MMIO, delegates to request_mmio_mapping with fixed LAPIC args (phys_base=0xFEE00000, length=0x1000), returns non-zero mapped virtual address.

### Invocation 7 (Denial Witness): Slot 8, OP_WRITE (should deny)

```
mov rdi, 8                    # slot = 8 (PAGE READ-only)
mov rsi, 2                    # op_arg = 2 (OP_WRITE)
call cap_invoke_dispatch      # call dispatcher
mov r10, 0xFFFFFFFFFFFFFFFD   # load INVOKE_DENIED sentinel
cmp rax, r10                  # compare return to INVOKE_DENIED
jne dispatch_smoke_fail        # fail if not INVOKE_DENIED
```

Expected: kind_page.pdx handler checks RIGHT_WRITE (bit 1) in rights 0x01, finds it not set, emits cap_denied_msg, returns INVOKE_DENIED (0xFFFFFFFFFFFFFFFD).

---

## Section 5 — Expected COM1 Log Output

When cap_dispatch_smoke executes successfully, the following sequence appears on COM1 (via QEMU/minicom):

```
CAP INVOKE PAGE
CAP INVOKE PAGE
CAP INVOKE IPC
CAP INVOKE IPC
CAP INVOKE SCHED
CAP INVOKE DEVICE
CAP INVOKE PAGE
CAP DENIED
CAP DISPATCH OK
```

Each handler emits a tag (e.g., "CAP INVOKE PAGE\n") via uart_puts at entry. The denial witness (Invocation 7) triggers cap_denied_msg. If all 7 invocations return expected values, the fixture emits "CAP DISPATCH OK\n" at the end.

---

## Section 6 — Encoder Caveats and Workarounds

### Caveats from paideia-as v0.11.0+19

#### Caveat 1: cmp rax, imm64 Beyond imm32 Range

The x86-64 `cmp` instruction cannot encode an imm64 operand directly. Values like 0xCAFEBABE (sign-extend from imm32 as 0xFFFFFFFFCAFEBABE) or 0xFFFFFFFFFFFFFFFD (negative, not imm32-representable) require a scratch register:

```
// Workaround for 0xCAFEBABE
mov r10, 0xCAFEBABE
cmp rax, r10

// Workaround for 0xFFFFFFFFFFFFFFFD (INVOKE_DENIED)
mov r10, 0xFFFFFFFFFFFFFFFD
cmp rax, r10
```

As of paideia-as v0.11.0+19, `mov r10, 0xFFFFFFFFFFFFFFFD` encodes correctly as movabs (8-byte immediate).

#### Caveat 2: Precomputed Constants

Constants like OP_SEND payload (0xDEAD03) must be precomputed and written as inline literals, not built from separate values:

```
mov rsi, 0xDEAD03    # Correct: precomputed constant
```

NOT:

```
mov rsi, 0xDEAD00
or rsi, 3            # Risky: constant folding unproven; avoid
```

#### Caveat 3: No lea with Large Offsets in Comparisons

The fixture uses `lea rcx, [rip + _r12_mem_test_buf]` to compute the test buffer address. This works because lea is not restricted to imm32. However, all comparison immediates must use the scratch-register workaround (Caveat 1).

---

## Section 7 — Positional Invariant: Slot Allocation

The test depends critically on these allocations:

- **Slot 0**: Reserved by cap_smoke (B5-005). **Do not mint here in cap_dispatch_smoke.**
- **Slots 4-8**: Reserved for cap_dispatch_smoke. **Do not overlap with other smokes.**
- **Slots 9+**: Reserved for future smokes or runtime allocation.

If cap_smoke (using slot 0) and cap_dispatch_smoke (using slots 4-8) ever mint to overlapping slots, the second mint will overwrite the first, causing invocation failures.

---

## Section 8 — Failure Modes

### Failure Mode 1: Invocation Return Mismatch

If any invocation returns an unexpected value, the fixture jumps to dispatch_smoke_fail and returns without emitting "CAP DISPATCH OK\n". COM1 output stops at the diagnostic line before the failed invocation.

Example: If Invocation 2 (OP_READ) returns 0x0000DEAD instead of 0xCAFEBABE, the fixture fails silently after emitting "CAP INVOKE PAGE\nCAP INVOKE PAGE\n".

### Failure Mode 2: Denial Witness Bypassed

If Invocation 7 (denial witness) does NOT return INVOKE_DENIED, the test fails. This would indicate that the rights check in kind_page.pdx is broken or that slot 8 was minted with wrong rights.

### Failure Mode 3: Slot Non-Collision

If slots 4-8 collide with other tests (e.g., cap_smoke uses slot 4 instead of slot 0), both tests will fail unpredictably. The audit ensures disjoint slot allocation.

---

## Section 9 — Slot Non-Collision Proof

Slot allocation by smoke test:

- **cap_smoke (B5-005)**: Uses slot 0. (Fixed in smoke.pdx line 28: `mov rdi, 0`.)
- **cap_dispatch_smoke (R12-m5-001)**: Uses slots 4-8. (First mint: line ~31, `mov rdi, 4`; last mint: line ~44, `mov rdi, 8`.)

Slot sets: {0} and {4, 5, 6, 7, 8}. Disjoint. No collision.

Any future smoke test must use slots 9+ to avoid collision.

---

## Section 10 — Wiring and Integration

### Module and Function Names

- **Module name**: DispatchSmoke (in file dispatch_smoke.pdx)
- **Function name**: cap_dispatch_smoke
- **Export**: pub let (publicly callable from kernel_main)

### Cross-Module Dependencies

cap_dispatch_smoke calls:

1. **cap_mint_write** (from mint.pdx, m1-001): Mint five capabilities into slots 4-8.
2. **cap_invoke_dispatch** (from invoke.pdx, m2-001): Invoke each capability with specific operations.
3. **uart_puts** (from uart.pdx): Emit "CAP DISPATCH OK\n" on success.

All are unqualified calls (no module prefix required), assuming they are global symbols in the linked object.

### Kernel Main Integration

kernel_main.pdx calls cap_dispatch_smoke between ipc_smoke and idt_install (R12-m5-001 insertion point):

```
call cap_smoke;
call ipc_smoke;
call cap_dispatch_smoke;    # New insertion (R12-m5-001)
call idt_install;
```

This ensures:

1. cap_smoke completes first (exercises basic capability system).
2. ipc_smoke completes second (exercises IPC system).
3. cap_dispatch_smoke completes third (integrates all four kinds via dispatch).
4. idt_install completes fourth (sets up interrupts; no dependency on cap_dispatch_smoke).

---

## Section 11 — Acceptance Criteria and Regression Tests

### Build Acceptance

```bash
cd /home/snunez/Development/PaideiaOS
./tools/build.sh 2>&1 | tail -10
```

Expected: No errors. Symbols cap_dispatch_smoke and cap_dispatch_ok_msg present in build/kernel.elf.

### Symbol Verification

```bash
nm build/kernel.elf | grep -E "cap_dispatch_smoke|cap_dispatch_ok_msg"
```

Expected (2 lines):

```
<addr> T cap_dispatch_smoke           # Text (code)
<addr> R cap_dispatch_ok_msg          # Read-only (data, string)
```

### Runtime Witness (QEMU Boot)

```bash
timeout 15 ./tools/run-qemu.sh 2>&1 | tail -30
```

Expected: Between "IPC OK\n" and "IDT OK\n", the following sequence on COM1:

```
CAP INVOKE PAGE
CAP INVOKE PAGE
CAP INVOKE IPC
CAP INVOKE IPC
CAP INVOKE SCHED
CAP INVOKE DEVICE
CAP INVOKE PAGE
CAP DENIED
CAP DISPATCH OK
```

### Regression Tests (3 Legacy Smokes)

```bash
./tools/run-smoke.sh boot_r8_only 2>&1 | tail -1    # Should pass (no cap dispatch before R12)
./tools/run-smoke.sh boot_r10 2>&1 | tail -1        # Should pass (no cap dispatch before R12)
./tools/run-smoke.sh boot_r11 2>&1 | tail -1        # Should pass (no cap dispatch before R12)
```

Expected: All three smokes pass (output contains "PASS" or "OK"). The cap_dispatch_smoke is new (R12-m5-001); legacy tests were built before R12 and do not invoke it. Regression criteria: byte-identical output before/after r12-m5-001 implementation (the three legacy smokes must not change).

### Clean Check (No Emojis)

```bash
grep -P '[\x{1F300}-\x{1FAFF}]|[\x{2600}-\x{27BF}]' src/kernel/core/cap/dispatch_smoke.pdx design/audit/entries/r12-m5-001-dispatch-smoke.md && echo "SYMBOLS FOUND" || echo "CLEAN"
```

Expected: Output "CLEAN" (no Unicode emoji or decorative symbols).

---

## Section 12 — Dependencies

### Issue Dependencies

- **#341 (B5-005)**: cap_smoke — establishes slot 0 reservation and mint/invoke pattern.
- **#359 (R9-m1-002)**: idt_install — sets up IDT before cap_dispatch_smoke runs (order requirement).
- **#408 (R12-m3-001)**: Real kind_page handler (OP_READ/OP_WRITE).
- **#409 (R12-m3-002)**: Real kind_sched handler (OP_YIELD).
- **#410 (R12-m4-001)**: Real kind_ipc handler (OP_SEND/OP_RECV).
- **#411 (R12-m4-002)**: Real kind_dev handler (OP_MAP_MMIO).
- **#412 (R12-m5-001)**: This issue — cap_dispatch_smoke fixture + regression matrix.

### File Dependencies

- **src/kernel/core/cap/dispatch_smoke.pdx** (this file): Main smoke test implementation.
- **src/kernel/boot/kernel_main.pdx**: Calls cap_dispatch_smoke between ipc_smoke and idt_install (insertion point).
- **src/kernel/core/cap/mint.pdx** (m1-001): Provides cap_mint_write.
- **src/kernel/core/cap/invoke.pdx** (m2-001): Provides cap_invoke_dispatch.
- **src/kernel/core/cap/kind_page.pdx** (m3-001): Real handler for slots 4 and 8 (KIND_PAGE).
- **src/kernel/core/cap/kind_ipc.pdx** (m4-001): Real handler for slot 5 (KIND_IPC_ENDPOINT).
- **src/kernel/core/cap/kind_sched.pdx** (m3-002): Real handler for slot 6 (KIND_SCHED_CTX).
- **src/kernel/core/cap/kind_dev.pdx** (m4-002): Real handler for slot 7 (KIND_DEVICE).
- **src/kernel/core/cap/tags.pdx** (m1-002): Defines cap_dispatch_ok_msg (external symbol).
- **src/kernel/core/uart.pdx**: uart_puts (diagnostic output).

---

## Trailer

**Audit date**: 2026-07-03
**Issue**: #412
**Status**: Ready for build verification and QEMU runtime witness.
**Line count**: 150 assembly lines (excluding labels and comments).
