---
audit_id: r13-m7-002-syscall-shim
issue: 433
file: src/user/syscall_shim.pdx
function: sys_exit_thread / sys_yield / sys_cap_invoke / sys_debug_puts
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-07-03
---

# R13-m7-002 — User-space syscall shim (§C-frozen native wrappers)

**Issue:** #433
**Files:** src/user/syscall_shim.pdx (new)
**Backtracking:** #483 (R13 user-shell deferral record), PA-R13-012 (§C freeze decision)

## Landing scope

This issue lands four user-space syscall wrappers that bridge the application layer to the §C-frozen syscall table (13 entries). Only the four minimal §C-native syscalls are exposed:

- `sys_exit_thread(code: u64) -> u64` — syscall 0, never returns
- `sys_yield() -> u64` — syscall 1, returns INVOKE_OK
- `sys_cap_invoke(slot: u64, op_arg: u64) -> u64` — syscall 4, returns op result
- `sys_debug_puts(msg_ptr: u64, msg_len: u64) -> u64` — syscall 12, returns msg_len echoed

**Explicitly NOT provided** (per §C freeze):
- `sys_read`, `sys_write` (POSIX-style I/O)
- `sys_mmap`, `sys_munmap` (memory management)
- `cap N M` decimal-parse builtin (parsing deferred to R14)

## §C ABI mapping

The §C (Section C: System Call Interface) freeze document defines the kernel-side syscall table at #419. User-space shims follow Linux x86_64 syscall ABI:

| Register | Role |
|---|---|
| RAX | Syscall number (loaded by shim) |
| RDI | First argument (preserved by caller per SysV) |
| RSI | Second argument (preserved by caller per SysV) |
| RDX | Third argument (not used here) |
| R10 | Fourth argument (not used here) |
| RCX | Clobbered by SYSCALL instruction |
| R11 | Clobbered by SYSCALL instruction |

**Preserve**: RBX, RSP, RBP, R12-R15, RAX (result), other GPRs except clobbered.

## Implementation pattern (all four syscalls)

Each shim follows the same 3-step pattern:

1. Load syscall number into RAX.
2. Confirm arguments are already in RDI/RSI per SysV (no register move needed for position-dependent args).
3. Issue SYSCALL instruction.
4. Return (syscall result already in RAX, per Linux convention).

### Example: sys_exit_thread(code)

```asm
sys_exit_thread:
  mov rax, 0          # syscall 0
  syscall             # invoke kernel
  ret                 # never executed (kernel terminates thread)
```

### Example: sys_cap_invoke(slot, op_arg)

```asm
sys_cap_invoke:
  mov rax, 4          # syscall 4
  syscall             # invoke kernel
  ret                 # return with result in rax
```

## Justification for unsafe { }

Each function uses paideia-as unsafe syntax with explicit justification:

1. **sysreg effect**: SYSCALL instruction is a privileged operation that modifies MSRs (model-specific registers, e.g., LSTAR, STAR). Only the kernel-side can manage these. User-space is allowed to **invoke** SYSCALL (ring-3 permitted), but the effect annotation flags that the kernel will modify system state.

2. **Capability requirement** (sys_cap_invoke, sys_yield): The kernel-side handlers check the caller's capability flags. The `@{cap}` and `@{sched}` annotations document that the caller must hold these rights to succeed.

3. **Never returns** (sys_exit_thread): The kernel-side handler destroys the calling thread. Control never returns to the shim.

## Regression

This is a new source file outside the kernel build. No changes to existing kernel code.
`tools/build.sh` only globs `src/kernel/`, so src/user/ .pdx files are NOT compiled at R13.
No binary produced; no regression vector.

## Acceptance

- [x] Four §C-native syscalls wrapped.
- [x] Syscall numbers match §C freeze (#419): 0, 1, 4, 12.
- [x] ABI compliance: RDI/RSI arguments, RAX result, SYSCALL instruction.
- [x] Unsafe blocks justified (sysreg effects, capability requirements, never-returns).
- [x] No POSIX sys_read / sys_write (explicit deferral per #483).

## Cross-references

- src/kernel/core/traps/syscall_handler.pdx (kernel-side dispatcher, §C table)
- src/user/shell.pdx (consumer: demonstrative _start)
- src/user/io.pdx (consumer: puts wrapper)
- src/user/builtins.pdx (consumer: dispatch_cap, builtin_exit)
- #419 (§C-frozen syscall table definition)
- #483 (R13 user-shell deferral record — no sys_read at R13)
- PA-R13-012 (paideia-as issue: §C freeze decision)
