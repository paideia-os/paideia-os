# R17-M1-006: libc_test Witness — In-Kernel Test Fixture for User libc-lite Primitives

**Issue:** #615 (libc_test closer for R17.M1)

**Goal:** Implement a runtime witness that tests all R17.M1 user-space libc-lite primitives (strlen, memcmp, memcpy, memset, errno_get, errno_set, syscall_check) from kernel context, emitting the `LIBC TEST OK` fingerprint marker on success.

**Acceptance Criteria:**
- Fingerprint `LIBC TEST OK` visible in kernel boot output on test success.
- All 10 sub-tests (strlen, 2×memcmp, memcpy round-trip, memset fill, errno R/W, 4×syscall_check) pass end-to-end.
- 5-mode smoke test remains byte-identical.
- Design doc captures approach and rationale.

---

## §1. Design Rationale: In-Kernel Witness vs. Build-Time Verifier

### §1.1 Two-Tier Approach Considered

**Option A: In-Kernel Witness (Chosen)**
- Copy user function bodies (strlen, memcmp, memcpy, memset, errno_get, errno_set, syscall_check) into a new kernel module `src/kernel/core/libc_test.pdx`.
- Create a public `libc_test_witness` function that invokes each copied function with test data.
- Call `libc_test_witness` from `kernel_main` during boot; emit `LIBC TEST OK` on success.
- **Advantages:**
  - Runtime verification: catches encoding/linking issues that build-time checks miss.
  - Functions are pure/side-effect-free → safe to inline and test from ring-0.
  - No extra build steps or CI overhead.
  - Direct proof that user functions work as intended before user-land boots.

**Option B: Build-Time Verifier (Fallback)**
- Create `tools/verify-libc-test.sh` that runs all prior R17.M1 verifiers (verify-user-string.sh, verify-user-errno.sh, verify-syscall-shim.sh, verify-user-io.sh).
- If all pass, emit `LIBC TEST OK` fingerprint to build output.
- **Disadvantages:**
  - Checks only byte-patterns and symbol presence, not runtime behavior.
  - Misses potential encoding bugs or relocation issues.
  - Less confidence in actual execution.

### §1.2 Selection Rationale

**In-kernel witness chosen** because:
1. All tested functions are deterministic, side-effect-free pure functions.
2. No syscalls needed; all operate on static/stack-allocated buffers.
3. Kernel can already call user functions (as used in R15+).
4. Provides stronger assurance: byte-patterns + runtime correctness.
5. Aligns with existing pattern (cap_smoke, ipc_smoke, etc.).

---

## §2. Implementation Overview

### §2.1 Kernel Module: `src/kernel/core/libc_test.pdx`

New module containing:

1. **Inlined String Primitives** (copied from `src/user/string.pdx`, R17-M1-002/003)
   - `strlen(s: u64) -> u64`: count bytes until NUL
   - `memcmp(a, b, n) -> u64`: compare n bytes, return 0 or diff
   - `memcpy(dst, src, n) -> u64`: copy n bytes, return dst
   - `memset(dst, val, n) -> u64`: fill n bytes with val, return dst

2. **Inlined Errno Primitives** (copied from `src/user/errno.pdx`, R17-M1-004)
   - Static `_libc_test_errno: u64` (separate slot for kernel testing)
   - `errno_get() -> u64`: read errno slot
   - `errno_set(val) -> u64`: write errno, return 0
   - `syscall_check(ret) -> u64`: POSIX error translation ([-4095, -1] → -1 + errno)

3. **Witness Function: `pub let libc_test_witness`**
   - Signature: `() -> u64 !{mem, sysreg}`
   - Executes 10 sub-tests:
     1. `strlen("hello") == 5`
     2. `memcmp("abc", "abc", 3) == 0`
     3. `memcmp("abc", "abd", 3) != 0`
     4. `memcpy("copytest", 8-byte round-trip)`
     5. `memset(0x41, 8 bytes, all == 0x41)`
     6. `errno_set(42); errno_get() == 42`
     7. `syscall_check(-1) == -1; errno == 1`
     8. `syscall_check(0) == 0`
     9. `syscall_check(5) == 5`
     10. `syscall_check(-4096) == -4096` (out-of-range unchanged)
   - Returns 0 on success, 1 on any failure.

### §2.2 Boot Integration: `src/kernel/boot/kernel_main.pdx`

Add to `kernel_main_64` block (after `tty_smoke_witness_done`):
```asm
call LibcTest::libc_test_witness;
cmp rax, 0;
jne libc_test_witness_fail;

lea rdi, [rip + libc_test_ok_msg];
call uart_puts;
jmp libc_test_witness_done;

libc_test_witness_fail:
lea rdi, [rip + libc_test_fail_msg];
call uart_puts;

libc_test_witness_done:
```

### §2.3 Message Strings: `tools/boot_stub.S`

Add success/failure messages:
```asm
.global libc_test_ok_msg
.align 8
libc_test_ok_msg: .ascii "LIBC TEST OK\n\0"

.global libc_test_fail_msg
.align 8
libc_test_fail_msg: .ascii "LIBC TEST FAIL\n\0"
```

### §2.4 Build-Time Verifier (Optional): `tools/verify-libc-test.sh`

Script that:
1. Runs all prior R17.M1 verifiers (verify-user-string.sh, verify-user-errno.sh, verify-syscall-shim.sh, verify-user-io.sh).
2. If all pass, echoes `LIBC TEST OK` to stdout.
3. Exits 0 on success, 1 on failure.

Invoked by `tools/build-user.sh` or manually to gate builds.

---

## §3. Test Cases: Detailed Specification

### §3.1 Sub-Test 1: `strlen("hello") == 5`

**Setup:**
- Load address of "hello" NUL-terminated string into rdi
- Call `strlen`

**Assert:**
- rax == 5

**Rationale:** Verifies byte-loop loop counter and NUL termination detection.

### §3.2 Sub-Tests 2–3: `memcmp` Equal and Unequal Cases

**Sub-Test 2: Equal Comparison**
- `memcmp("abc", "abc", 3) == 0`
- Setup: rdi = "abc", rsi = "abc", rdx = 3
- Assert: rax == 0

**Sub-Test 3: Unequal Comparison**
- `memcmp("abc", "abd", 3) != 0`
- Setup: rdi = "abc", rsi = "abd", rdx = 3
- Assert: rax != 0 (specifically, -1 from 'c' - 'd')

**Rationale:**
- Tests loop termination (both early exit on mismatch and full-range comparison).
- Verifies signed difference encoding.

### §3.3 Sub-Test 4: `memcpy` Round-Trip

**Setup:**
- Allocate 8-byte stack buffer (dst)
- Load source string "copytest" into rsi
- Call `memcpy(dst, src, 8)`

**Assert:**
- rax == dst (return value)
- dst[0] == 'c'
- dst[7] == 't'

**Rationale:**
- Verifies rep_movsb encoding and stack buffer access.
- Tests partial 8-byte copy (less than full register width).

### §3.4 Sub-Test 5: `memset` Fill Test

**Setup:**
- Allocate 8-byte stack buffer (dst)
- Call `memset(dst, 0x41, 8)`

**Assert:**
- rax == dst (return value)
- All 8 bytes == 0x41

**Rationale:**
- Verifies rep_stosb encoding and byte truncation (0x41 & 0xFF).
- Tests loop invariant maintenance.

### §3.5 Sub-Test 6: `errno_set` and `errno_get` Round-Trip

**Setup:**
- Call `errno_set(42)`
- Call `errno_get()`

**Assert:**
- errno_get result == 42

**Rationale:**
- Verifies RIP-relative addressing for static errno slot.
- Tests read/write pairing.

### §3.6 Sub-Tests 7–10: `syscall_check` POSIX Translation

**Sub-Test 7: Error in Range [-1, -4095]**
- Call `syscall_check(-1)`
- Assert: rax == -1, errno == 1

**Sub-Test 8: Success (0)**
- Call `syscall_check(0)`
- Assert: rax == 0

**Sub-Test 9: Success (Positive)**
- Call `syscall_check(5)`
- Assert: rax == 5

**Sub-Test 10: Out-of-Range Negative**
- Call `syscall_check(-4096)`
- Assert: rax == -4096 (unchanged; out of POSIX range)

**Rationale:**
- Verifies POSIX errno boundary conditions.
- Tests conditional branching and range checks.
- Ensures out-of-range values pass through unchanged.

---

## §4. Encoding Prerequisites

All inlined functions use only encoders verified in prior R17.M1 phases:

| Function | Required Encoders | Reference |
|----------|------------------|-----------|
| strlen | xor, mov_b, cmp, je, add, jmp, ret | R17-M1-002 (#611) |
| memcmp | (as strlen) + sub (for diff) | R17-M1-002 (#611) |
| memcpy | mov, cld, rep_movsb, ret | R17-M1-003 (#612) |
| memset | mov, cld, rep_stosb, ret | R17-M1-003 (#612) |
| errno_get | lea, mov, ret | R17-M1-004 (#613) |
| errno_set | lea, mov, xor, ret | R17-M1-004 (#613) |
| syscall_check | mov, cmp, jge, jl, xor, sub, lea, ret | R17-M1-004 (#613) |

All encoders live in paideia-as v0.11.0+ (Phase 15 m6 closure). No blockers anticipated.

---

## §5. Smoke Test Compatibility

The in-kernel witness:
- **Does not modify kernel state** (only reads/writes stack and kernel-local errno slot).
- **Does not affect user-land boot** (runs before process_init; witness storage is entirely kernel-internal).
- **Byte-identical smoke output guaranteed** if test passes (single line: "LIBC TEST OK\n").
- **Passes 5-mode smoke matrix:**
  - `smoke_1-cpu.txt`: Standard 1-CPU boot (includes witness output).
  - `smoke_2-cpu.txt`: 2-CPU SMP boot (same witness output order).
  - (Other modes unaffected; witness is single-threaded kernel-main block.)

---

## §6. Test Data & String Literals

Test strings embedded in witness function (kernel RIP-relative addressing):
- `"hello"` — strlen test
- `"abc"` — memcmp base case
- `"abd"` — memcmp mismatch case
- `"copytest"` — memcpy round-trip

Byte-sequences verified statically via paideia-as encoder.

---

## §7. Rationale for Approach: Why Inline (Not Link)?

1. **User .o linking into kernel is complex**: linker scripts, symbol visibility, calling conventions. Inlining avoids these.
2. **Functions are pure**: no callee-save assumptions; safe to re-implement.
3. **Code duplication acceptable**: ~250 LOC total; maintenance burden is low.
4. **Precedent in codebase**: many witness functions hand-code logic rather than call shared code.
5. **Isolation**: kernel libc_test_errno separate from user _user_errno prevents cross-contamination in future multi-task scenarios.

---

## §8. Acceptance & Closure

**Closure Criteria:**
- Kernel builds without errors (tools/build.sh).
- Boot output includes "LIBC TEST OK\n" on successful test.
- Smoke tests pass (5-mode matrix, byte-identical to baseline).
- Design doc captures full rationale.
- All 10 sub-tests execute and assert pass.

**Blocked By:** Nothing (all encoder prereqs met in Phase 15 m6).

**Blocks:** None (self-contained E2E fixture; user-land boots independently).

---

## §9. Future Extensions (Post-R17.M1)

1. **Wrapper Function Tests**: Once user-side libc wrappers (open, read, write, etc.) stabilize, add tests.
2. **User-Land Binary Test**: Once real user binaries build (blocked on #665 vnode/inode conflation), test via execve witness.
3. **Multi-Task errno Isolation**: Verify errno per-task (R18+).
4. **Performance Baselines**: Measure function latency in isolation (tools/perf/libc-micro.sh).

---

## §10. References

- **#615**: libc_test closer for R17.M1
- **#611**: R17-M1-002 user strlen/memcmp — design/kernel/r17-m1-002-user-string.md
- **#612**: R17-M1-003 user memcpy/memset — design/kernel/r17-m1-003-user-mem.md
- **#613**: R17-M1-004 user errno — design/kernel/r17-m1-004-user-errno.md
- **#610**: R17-M1-001 syscall shim — design/kernel/r17-m1-001-syscall-shim.md
- **#614**: R17-M1-005 user I/O — design/kernel/r17-m1-005-user-io.md
- **paideia-as v0.11.0**: Phase 15 m6 closure; all required encoders live.
