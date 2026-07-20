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
  - src/user/errno.pdx                     (static _user_errno + three wrappers; #613 fix in syscall_check)
  - tools/verify-user-errno.sh              (build-time symbol/shape canary; #613 adds sign-extension regression guard)
  - tools/build-user.sh                    (verify-user-errno.sh invocation post-link)
  - design/kernel/r17-m1-004-user-errno.md (this doc)
related:
  - "#610 (r17-m1-001 syscall_shim — raw wrappers, no errno translation)"
  - "#611 (r17-m1-002 user-string — strlen/memcmp, non-blocking parallel to errno)"
  - "#612 (r17-m1-003 user-mem — memcpy/memset, non-blocking parallel to errno)"
  - "#613 (this issue) — landed at bebc377 with a sign-extension bug in syscall_check; fixed in a follow-up commit on the same issue (see §5)"
  - design/user/syscall-table.md (SC+ frozen table — errno behavior defined at kernel boundary)
  - design/milestones/r14b-tactical-plan.md §Subsystem 16 (lines 1635–1710 + errno allocation)
  - design/audit/entries/r15-m4-xxx-syscall-dispatch.md (kernel-side error code ranges)
---

# R17-M1-004 — user errno slot + POSIX-check wrapper (#613)

## 1. Purpose

Userland syscall wrappers (`syscall_shim.pdx`, #610) return the kernel's raw syscall value in
`rax` unmodified. To let userland callers use the POSIX convention (negative return → `-1` plus
an `errno` value), this issue lands:

- **`_user_errno`** — a static `u64` slot in the user binary's `.bss`, initialized to 0.
- **`errno_get()`** — read `_user_errno`.
- **`errno_set(val)`** — write `val` to `_user_errno`, return 0.
- **`syscall_check(ret_val)`** — the POSIX error translator. Every future syscall wrapper
  (#614 puts/getline, #615 libc_test, and R17.M2+ init/shell code) is expected to pipe its raw
  syscall return through `syscall_check` before returning to its own caller.

Out of scope (deliberately deferred):

- **User-space `errno` macro / TLS lookup.** A libc-style `errno` accessor (e.g.
  `(*__errno_location())`) is deferred to R17.M3 (shell #622+); this issue lands only the static
  storage and the check function.
- **Full POSIX error code table.** Populating all ~130 in-use errno codes across every kernel
  handler lands piecemeal in R15.M5/6 (mm/sched) and R16.M3 (fs). R17.M1 implements the ABI
  boundary only — `syscall_check` codifies the kernel→user error convention, not the code table.
- **Signal/exception handlers.** errno preservation across async paths is outside R17.M1.

## 2. Signatures

```
_user_errno : u64                       // .bss, initialized 0

errno_get   : () -> u64        !{mem} @{}
errno_set   : (u64) -> u64     !{mem} @{}
syscall_check : (u64) -> u64   !{mem} @{}
```

All three are leaf functions (no callee-save prologue, no calls out). SysV ABI: first argument
in `rdi`, result in `rax`.

## 3. Algorithm

### 3.1 errno_get / errno_set

Trivial RIP-relative accessors, no branches:

```
errno_get() -> u64
  lea rdi, [rip + _user_errno]
  mov rax, [rdi]
  ret

errno_set(val: u64) -> u64          // val in rdi
  lea rax, [rip + _user_errno]
  mov [rax], rdi
  xor rax, rax                      // return 0
  ret
```

### 3.2 syscall_check: POSIX errno translator

POSIX/Linux convention: a raw syscall return is either non-negative (success — the value itself,
e.g. a byte count or fd), or negative and in `[-4095, -1]` (an error — magnitude is the errno
code). Values more negative than `-4095` are not a POSIX errno encoding (out-of-range /
kernel-internal) and are passed through unchanged.

```
Input:  rdi = raw syscall return
Output: rax = translated return

mov rax, rdi
cmp rax, 0
jge ok                     ; rax >= 0 → success, return unchanged

; rax < 0 here. Determine whether it's in the POSIX errno range.
xor r8, r8
sub r8, 4095               ; r8 = -4095 (boundary, built via subtraction — see §4)
cmp rax, r8
jl out_unchanged           ; rax < -4095 → out-of-range, return unchanged

; -4095 <= rax < 0: valid POSIX error.
xor r8, r8
sub r8, rax                ; r8 = -rax  (errno magnitude)
lea r9, [rip + _user_errno]
mov [r9], r8                ; _user_errno = errno magnitude
xor rax, rax
sub rax, 1                  ; rax = -1
jmp out

ok:
  ; rax already holds the return value
out_unchanged:
  ; rax already holds the return value
out:
ret
```

Boundary values, verified by inspection:

| `rdi` (raw return) | Path taken                              | `rax` (result) | `_user_errno` |
|---------------------|------------------------------------------|-----------------|----------------|
| `0` or positive     | `jge ok`                                 | unchanged       | untouched      |
| `-1`                | falls through both checks → error path   | `-1`            | `1`            |
| `-4095`             | falls through both checks → error path   | `-1`            | `4095`         |
| `-4096`             | `jl out_unchanged` (boundary exclusive)  | `-4096`         | untouched      |
| more negative       | `jl out_unchanged`                       | unchanged       | untouched      |

The range is `[-4095, -1]` inclusive — `-4096` and below are explicitly *not* treated as errno
values, matching the design's stated range (see §5 for why this matters).

## 4. Byte-shape and the #613 regression

### 4.1 What went wrong

The first landing of this function (bebc377) built the `-4095`/`-4096` boundary with a direct
immediate load:

```
mov r8, 0xFFFFF000;   // intended: -4096, sign-extended
cmp rax, r8;
jl unchanged;
```

The author's assumption was that a 32-bit immediate loaded into a 64-bit register would be
sign-extended by the assembler, the way `mov eax, 0xFFFFF000` (which zero-extends into `rax`) or
a signed `cmp` immediate would behave in other encodings. paideia-as does not do this for a bare
`mov r64, imm`: any immediate that doesn't fit a signed imm32 encoding is emitted as
`MOVABS r64, imm64` with the immediate materialized as a **verbatim 64-bit pattern** — no sign
extension. `0xFFFFF000` was loaded as `+4,294,963,200`, not `-4096`.

Effect: `rax` at that program point is always negative (the `jge ok` branch above it already
filtered out non-negative returns), so `rax` is always numerically far below any large positive
`r8`. The signed `jl` (jump if less) is therefore **always taken**, unconditionally routing every
negative return to `out_unchanged` and skipping the errno-store/`-1`-return block entirely.
`syscall_check` was a silent no-op passthrough — every error-handling caller downstream would see
raw kernel returns instead of the POSIX `(-1, errno)` pair, with no build or link failure to flag
it.

### 4.2 The fix

Replace the bare 64-bit immediate load with an encoder-safe construction — `xor`+`sub` — which
never triggers `MOVABS`:

```
xor r8, r8;
sub r8, 4095;         // r8 = 0 - 4095 = -4095, exact, no sign-extension pitfall
cmp rax, r8;
jl syscall_check_out_unchanged;   // rax < -4095 → unchanged
```

This also fixes an off-by-one present in the original: the original boundary was `-4096`
(`0xFFFFF000`, had it been correctly sign-extended), which would have folded `-4096` into the
errno range. The design's stated range is `[-4095, -1]` (4095 slots, matching glibc/Linux's
`MAX_ERRNO`), so the corrected boundary is `-4095`.

### 4.3 Byte shape, before and after

Before (bebc377), disassembly of `syscall_check`'s boundary check:

```
400046:  49 b8 00 f0 ff ff 00 00 00 00   movabs r8,0xfffff000
400050:  4c 39 c0                        cmp    rax,r8
400053:  0f 8c 21 00 00 00               jl     <out_unchanged>
```

After (this fix):

```
400046:  4d 31 c0                        xor    r8,r8
400049:  49 81 e8 ff 0f 00 00            sub    r8,0xfff
400050:  4c 39 c0                        cmp    rax,r8
400053:  0f 8c 21 00 00 00               jl     <out_unchanged>
```

`sub r8, 0xfff` encodes as `REX.WB 81 /5 id` (`49 81 e8 ff 0f 00 00`) — 4095 does not fit a
signed imm8, so the encoder correctly falls back to imm32, and no `MOVABS` opcode appears
anywhere in the function.

## 5. Verifier strategy

`tools/verify-user-errno.sh` is a build-time canary run from `tools/build-user.sh` against the
linked `shell.elf`. It checks, per function:

- **`_user_errno`** — symbol exists (data object).
- **`errno_get`** / **`errno_set`** — byte-count budget, presence of `lea` (`8d`) and a
  memory-operand `mov` (`48 8b` / `48 89`), presence of `ret` (`c3`), absence of the `syscall`
  opcode (`0f 05`) — these must stay pure userland with no direct syscalls.
- **`syscall_check`** — same budget/shape checks, plus (added for #613) a positive check that the
  disassembly contains the `sub r8, imm32` boundary-construction pattern (`49 81 e8 ff 0f`, i.e.
  `sub r8, 0xfff` / -4095) and a negative check that **no** `MOVABS r8, imm64`-shaped byte pattern
  (`49 b8`) appears anywhere in the function body. The negative check is the regression guard:
  it fails the build if a future edit reintroduces a bare 64-bit immediate load for the boundary
  comparison, which is exactly the class of bug that shipped in bebc377.

This is a static byte-pattern check, not a semantic one — it can't prove the comparison logic is
correct, only that the specific miscompilation pattern that caused #613 hasn't come back. See §6
for the runtime check that closes that gap.

## 6. Deferred runtime test

R17.M1 has no running userland yet capable of executing `shell.elf` and observing register/memory
state directly (that lands with #615, `libc_test`, once init/exec plumbing exists). Until then,
correctness of `syscall_check` rests on:

1. The byte-shape verifier (§5), confirming the intended instruction sequence is what actually got
   emitted.
2. Manual `objdump` inspection of the boundary table in §3.2 for each landing/change.

**Deferred to #615 (`r17-m1-006-user-smoke-libc`):** a runtime `libc_test` exercising
`syscall_check` against real syscall returns — at minimum: a successful `sys_write` (positive
return, unchanged), a deliberately-invalid `sys_open` on a nonexistent path (negative return in
`[-4095,-1]`, expect `_user_errno` set and `-1` returned), and — if the kernel can be made to
produce one — a value outside the POSIX range (expect unchanged passthrough). This is the check
that would have caught #613 at the semantic level rather than relying on someone manually reading
disassembly, and it should be treated as required, not optional, before R17.M1 is considered
closed.
