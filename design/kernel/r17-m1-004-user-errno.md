---
issue: 613
milestone: R17.M1 (libc-lite for userland)
subsystem: 16 — libc-lite for userland
prereq:
  - "#610 (r17-m1-001-syscall-shim) — syscall_check consumes the raw return rax from every wrapper"
  - "#611 (r17-m1-002-user-string) — strlen/memcmp prereqs for I/O wrappers (non-blocking parallel)"
  - "#612 (r17-m1-003-user-mem) — memcpy/memset prereqs for I/O wrappers (non-blocking parallel)"
blocks:
  - "#614 (r17-m1-005-user-puts-getline) — puts=write(1,…), getline=read(0,…) will wrap via syscall_check"
  - "#615 (r17-m1-006-user-smoke-libc) — libc_test exercises errno get/set/check at runtime"
  - "R17.M2 init (#616+), R17.M3 shell (#622+), R17.M4 builtins (#630+) — all depend on errno slot for POSIX compliance"
touching:
  - src/user/errno.pdx                     (new: static _user_errno + three wrappers)
  - tools/verify-user-errno.sh             (new: build-time symbol/shape canary)
  - tools/build-user.sh                    (add verify-user-errno.sh invocation post-link)
  - design/kernel/r17-m1-004-user-errno.md (this doc)
related:
  - "#610 (r17-m1-001 syscall_shim — raw wrappers, no errno translation)"
  - "#611 (r17-m1-002 user-string — strlen/memcmp, non-blocking parallel to errno)"
  - "#612 (r17-m1-003 user-mem — memcpy/memset, non-blocking parallel to errno)"
  - design/user/syscall-table.md (SC+ frozen table — errno behavior defined at kernel boundary)
  - design/milestones/r14b-tactical-plan.md §Subsystem 16 (lines 1635–1710 + errno allocation)
  - design/audit/entries/r15-m4-xxx-syscall-dispatch.md (kernel-side error code ranges)
---

# R17-M1-004 — user errno slot + POSIX-check wrapper (#613)

## 1. Scope

Implement static errno storage (`_user_errno : u64` in user `.bss`) and three accessor/translator
functions in `src/user/errno.pdx`:

- **errno_get()** — read and return `_user_errno`.
- **errno_set(val)** — write `val` to `_user_errno`, return 0.
- **syscall_check(rax)** — POSIX-style error translator. On entry, `rax` holds a syscall return value.
  If `rax` is in the POSIX-errno range (i.e., negative and ≥ -4095), negate to extract errno, store
  in `_user_errno`, and return -1. Otherwise return `rax` unchanged.

Syscall wrapper callers (#614 puts/getline, #615 libc_test, and R17.M2+ user init/shell) invoke
`syscall_check` on raw returns from the `syscall_shim.pdx` wrappers (#610) to implement the
POSIX convention: negative syscall returns map to `(errno, -1)`.

Out of scope (deliberately deferred):

- **User-space stdlib errno macros.** `errno` itself (a macro that typically expands to
  `(*__errno_location())` or thread-local lookup) is deferred to R17.M3 (shell #622+); this
  issue lands only the static storage and check function.
- **Robust error path.** Full POSIX errno for all 130+ error codes lands piecemeal in
  R16.M3 (fs handlers) and R15.M5/6 (mm/sched handlers). R17.M1 implements the ABI layer
  only — syscall_check codifies the kernel→user error boundary.
- **Signal/exception handlers.** errno preservation across async paths is outside R17.M1.

## 2. Design

### 2.1 Static errno storage

`_user_errno` is a global `u64` initialized to 0, living in the user binary's `.bss` section.
It is visible to all user-space code and persists across function calls and system calls
(kernel does not modify it; it is purely user-managed storage).

Location: `src/user/errno.pdx` as a module-level let binding with default initializer.

### 2.2 errno_get and errno_set

These are trivial read/write accessors:

```
errno_get() -> u64
  Load _user_errno into rax via RIP-relative LEA.
  Return rax.

errno_set(val: u64) -> u64
  val in rdi (SysV ABI arg 0).
  LEA rax, [rip + _user_errno]
  MOV [rax], rdi
  XOR rax, rax  (return 0)
  RET
```

Both functions are leaf (no callee-save prologue) and contain no branches.

### 2.3 syscall_check: POSIX errno translator

The syscall_check function translates raw syscall returns to the POSIX convention:
- Syscall returns values ≥ 0 → success; returned unchanged.
- Syscall returns values < -4095 → out-of-range / kernel-internal error; returned unchanged (kernel bug or malformed return).
- Syscall returns values in [-4095, -1] → POSIX errno range; negate to extract errno code, store in `_user_errno`, return -1.

The boundary -4095 is conventional in Linux/POSIX systems:
- Error codes -1 to -4095 (i.e., 1 to 4095 in magnitude) are valid errno values.
- Values < -4095 (more negative) are reserved for kernel-internal returns or invalid encodings.
- This gives ~4000 distinct errno slots; modern Linux uses ~130 of them.

#### 2.3.1 Algorithm

```
Input: rdi = rax (raw syscall return, u64).
Output: rax (translated return).

MOV rax, rdi              # rax = syscall return
CMP rax, -4095            # Signed comparison: rax vs. -4095
JGE syscall_check_ok      # Jump if rax >= -4095 (not an error)

# Error case (rax < -4095, i.e., outside POSIX range):
MOV r8, rax
NEG r8                    # r8 = -rax (extract errno)
LEA r9, [rip + _user_errno]
MOV [r9], r8              # Store errno
MOV rax, -1               # Return -1
JMP syscall_check_out

# OK case (rax >= -4095, no error):
syscall_check_ok:
  # rax already has the return value

syscall_check_out:
RET
```

The comparison `CMP rax, -4095` uses a sign-extended 32-bit immediate (-4095 = 0xFFFFF001
in 32-bit signed, which becomes 0xFFFFFFFFFFFFF001 in 64-bit). paideia-as encodes this
as a `mov rax, imm32; cmp rcx, rax` sequence or inline immediate depending on encoder support.

#### 2.3.2 Correctness witness

The function correctly implements the convention:
1. Non-negative returns (success): `rax >= 0` → `rax >= -4095` → jump to ok → return unchanged. ✓
2. Negative errors in POSIX range: `-4095 <= rax < 0` → `rax >= -4095` is true (or false if rax is exactly at boundary) → jump to ok → return unchanged.
   - Wait, this is wrong. Let me reconsider.

Actually, let me re-examine the logic:

In two's complement (signed 64-bit):
- `-4095` in decimal = `0xFFFFFFFFFFFFF001` in binary.
- `-1` in decimal = `0xFFFFFFFFFFFFFFFF` in binary.
- `-4096` in decimal = `0xFFFFFFFFFFFFF000` in binary.

Signed comparison `CMP rax, -4095`:
- If `rax >= -4095` (numerically), the comparison result is `JGE` (jump if greater or equal).
  Examples:
  - `rax = 0` (success): `0 >= -4095` → true → jump to ok. ✓
  - `rax = -1` (error code 1): `-1 >= -4095` → true → jump to ok. ✗ (should handle as error)
  - `rax = -4095` (error code 4095): `-4095 >= -4095` → true → jump to ok. ✗ (should handle as error)
  - `rax = -4096` (invalid): `-4096 >= -4095` → false → fall through to error case. ✓

So the current logic jumps to "ok" for values in `[-4095, ∞)`, which includes error codes.
This is incorrect.

Let me reconsider the intended behavior. Looking at the inline spec again:
```
syscall_check : (u64) -> u64 !{mem} @{} = fn (rax) { if rax >= -4095 { _user_errno = -rax; return -1; } return rax; };
```

Ah! The condition is `if rax >= -4095`, meaning "if rax is >= (i.e., closer to zero than) -4095", then
it's an error. So:
- `rax >= -4095` → error: negate to get errno, store, return -1.
- `rax < -4095` → no error (or out-of-range): return unchanged.

Let me reconsider with this semantics:
- `rax = 0` (success): `0 >= -4095` → true → treat as error. ✗
- `rax = -1` (error 1): `-1 >= -4095` → true → treat as error. ✓
- `rax = -4095` (error 4095): `-4095 >= -4095` → true → treat as error. ✓
- `rax = -4096` (invalid): `-4096 >= -4095` → false → return unchanged. ✓
- `rax = -5000` (invalid): `-5000 >= -4095` → false → return unchanged. ✓

But this treats success (rax = 0) as an error!

Let me re-read the inline spec once more, very carefully:

```
pub let syscall_check : (u64) -> u64 !{mem} @{} = fn (rax) { if rax >= -4095 { _user_errno = -rax; return -1; } return rax; };
```

Hmm, the inline spec says the function takes an argument called `rax` (even though by SysV ABI it would be in `rdi`). Let me assume the parameter name is just the variable name, not the actual ABI location.

If we interpret "if rax >= -4095" in the POSIX context:
- Syscall returns: -1 to -4095 are errors; 0 and positive are success.
- "rax >= -4095" in signed comparison means "rax is numerically >= -4095", i.e., closer to zero or more positive.
  - This includes 0, 1, 2, ..., -1, -2, ..., -4095.
  - This excludes -4096, -4097, ..., which are "more negative" (further from zero).

So the condition "rax >= -4095" means "rax is in the range where error codes live AND positive success codes live".

Actually, I think the intent is:
- POSIX syscalls can return:
  - 0 to very_large: success codes.
  - -1 to -4095: error codes (errno = -rax).
  - Less than -4095: reserved/invalid (treat as-is, or kernel bug).

So the check "if rax >= -4095" is trying to say "if rax is in the valid range [-4095, +∞), then either it's a success (>= 0) or a POSIX error (-4095 to -1), and we should handle it."

But the handling is "if rax >= -4095, set errno = -rax and return -1". This would incorrectly handle rax = 0 (success) by setting errno = 0 and returning -1, which is wrong.

Let me re-read the spec one more time with fresh eyes.

Actually, I think the spec is buggy or I'm misinterpreting it. Let me check if the POSIX convention is:
- Kernel returns negative error codes in the range -1 to -4095.
- Wrapper should check: if (return < 0 && return >= -4095) then errno = -return; return -1; else return return;

With this logic:
- rax = 0 (success): `0 < 0` → false → return 0. ✓
- rax = 1 (fd from open): `1 < 0` → false → return 1. ✓
- rax = -1 (error): `-1 < 0` → true AND `-1 >= -4095` → true → errno = 1; return -1. ✓
- rax = -4095 (error): `-4095 < 0` → true AND `-4095 >= -4095` → true → errno = 4095; return -1. ✓
- rax = -4096 (out of range): `-4096 < 0` → true AND `-4096 >= -4095` → false → return -4096. ✓

This makes sense! The spec has two conditions: `rax < 0` (negative) AND `rax >= -4095` (within errno range).

But the inline spec only says "if rax >= -4095". Let me assume it's shorthand and the full condition is "if (rax < 0) && (rax >= -4095)".

Actually, let me look at actual Linux kernel errno values. In x86_64 Linux:
- Syscall returns 0 and positive values are success.
- Syscall returns -1 to -4095 (i.e., -1, -2, ..., -4095) are error codes mapped to errno 1..4095.
- Syscall never returns values < -4095 (that would be a kernel bug).

So the check should be:
- If return < 0 (negative), it's an error. Extract errno = -return. Return -1.
- Else it's success. Return return.

But we need to distinguish kernel bugs (return < -4095) from valid errors. The conservative approach:
- If -4095 <= return < 0, it's a valid error. Handle it.
- Else, return unchanged (whether success or kernel bug).

Let me rewrite the algorithm:

```
Input: rax = syscall return.
Output: rax (translated).

# Check if rax is in error range: -4095 <= rax < 0 (i.e., rax < 0 && rax >= -4095).
# paideia-as may not support two-comparison branch. Instead:
# - Compute rax + 4095. If that's <= 0xFFF... (i.e., within 4096 values), it's in range.
# - Or: If rax < 0, then CMP rax, -4095. If JL (less), it's too negative. If JGE (>=), it's in range [-4095, -1].

MOV r8, rax         # r8 = syscall return
CMP r8, 0           # Is return < 0 (error)?
JL handle_error     # Jump if return < 0
                    # Success case: return unchanged
JMP out
handle_error:
CMP r8, -4095       # Is return >= -4095 (within POSIX range)?
JL out_unchanged    # Jump if < -4095 (out-of-range; return unchanged)
                    # Else in [-4095, -1]: handle as POSIX error
NEG r8              # r8 = -r8 (extract errno)
LEA r9, [rip + _user_errno]
MOV [r9], r8        # Store errno
MOV rax, -1         # Return -1
JMP out
out_unchanged:
MOV rax, r8         # Return unchanged
out:
RET
```

Hmm, this is getting complex. Let me simplify:

Actually, in practice, for R17.M1, all syscalls should return in a sane range. The conservative
approach is:
- If rax < 0, it's an error (map to errno + -1).
- Else it's success (return unchanged).

This is simpler and matches the POSIX convention for well-behaved kernels.

```
MOV rax, rdi        # rax = syscall return
CMP rax, 0          # Is return < 0?
JL handle_error
                    # Success case
JMP out
handle_error:
NEG rax             # rax = -rax (extract errno)
                    # But we need to bounds-check too. For now, assume kernel gives valid values.
LEA r8, [rip + _user_errno]
MOV [r8], rax       # Store errno
MOV rax, -1         # Return -1
out:
RET
```

But the inline spec says "if rax >= -4095", not "if rax < 0". Let me trust the spec and implement it as written, with the understanding that it may need adjustment after testing.

Actually, re-reading once more: "if rax >= -4095 { _user_errno = -rax; return -1; } return rax;"

This means:
- If rax >= -4095, then it's an error (handle it).
- Else (rax < -4095), return it unchanged.

This only makes sense if we consider that the POSIX errno range is [-4095, -1], and anything >= -4095 (i.e., -4095, -4094, ..., -1, 0, 1, ...) needs to be checked. But checking rax >= -4095 would include 0 and positive values, which shouldn't trigger error handling.

I think there's an issue with the spec, or I'm not understanding it correctly. Let me look at similar implementations in real C libraries.

In glibc (sysdeps/unix/sysv/linux/x86_64/syscall.S), the return value from the raw syscall is
already post-processed by the Linux kernel to return negative values for errors. The wrapper
checks: `if (rax < 0 && rax > -4096)` then it's an error, set errno = -rax, return -1.

So the correct condition is: `if (rax < 0 && rax >= -4095)`.

Given the inline spec says "if rax >= -4095", I think it's missing the `rax < 0` part, which is implied
or expected to be added during implementation.

Let me implement it correctly: if rax is in the range [-4095, -1] (i.e., negative error), handle it.
Otherwise, return unchanged.

```
MOV rax, rdi           # rax = input return value
CMP rax, 0             # Is rax < 0?
JL check_errno_range   # Jump if negative (potential error)
                       # Else non-negative: return unchanged
JMP out
check_errno_range:
CMP rax, -4095         # Is rax >= -4095 (within POSIX range)?
JGE handle_errno       # Jump if >= -4095
                       # Else: out-of-range negative (kernel bug); return unchanged
JMP out
handle_errno:
NEG rax                # rax = -rax (extract errno code)
LEA r8, [rip + _user_errno]
MOV [r8], rax          # Store errno
MOV rax, -1            # Return -1
out:
RET
```

Actually, this has a logical flaw too. Let me reconsider.

If rax < 0 AND rax >= -4095, then it's in the POSIX error range.
Let's use the contrapositive: if NOT (rax < 0 AND rax >= -4095), return unchanged.
NOT (A AND B) = (NOT A) OR (NOT B) = (rax >= 0) OR (rax < -4095).

So:
- If rax >= 0, return unchanged (success).
- Else if rax < -4095, return unchanged (out-of-range; kernel bug?).
- Else (rax < 0 AND rax >= -4095), it's an error: negate to errno, store, return -1.

The simplest approach:
```
MOV rax, rdi
CMP rax, 0
JGE out                  # >= 0: success, return unchanged
CMP rax, -4095
JL out                   # < -4095: out-of-range, return unchanged
# Here: -4095 <= rax < 0: error
NEG rax
LEA r8, [rip + _user_errno]
MOV [r8], rax
MOV rax, -1
out:
RET
```

Wait, the last `MOV rax, -1` clobbers rax before the jump, so the jump to `out` after the success cases wouldn't work. Let me fix:

```
MOV rax, rdi            # rax = input return value
CMP rax, 0              # Is rax < 0?
JL check_error_range    # Jump if negative
JMP out                 # Else: success, return unchanged (rax already has the value)
check_error_range:
CMP rax, -4095          # Is rax >= -4095?
JL out                  # If < -4095: out-of-range, return unchanged (rax already has the value)
# Else: in error range [-4095, -1]
NEG rax                 # rax = errno code
LEA r8, [rip + _user_errno]
MOV [r8], rax           # Store errno
MOV rax, -1             # Return -1
out:
RET
```

Yes, this should work. The second `out:` label is at the end, so both paths (success and error) jump/fall through to it correctly.

OK let me update the errno.pdx with the corrected algorithm:
</thinking>

Let me build and test first to see what happens:

<function_calls>
<invoke name="Bash">
<parameter name="command">cd /home/snunez/Development/PaideiaOS && bash tools/build-user.sh 2>&1 | tail -50