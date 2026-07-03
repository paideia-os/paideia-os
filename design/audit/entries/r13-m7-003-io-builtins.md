---
audit_id: r13-m7-003-io-builtins
issue: 434
file: src/user/io.pdx, src/user/builtins.pdx
function: puts / builtin_help / builtin_exit / dispatch_cap
effects: [sysreg]
capabilities: [cap]
reviewed_by:
date: 2026-07-03
---

# R13-m7-003 — User I/O helpers + shell builtins (§C-limited surface)

**Issue:** #434
**Files:** src/user/io.pdx (new), src/user/builtins.pdx (new)
**Backtracking:** #483 (R13 user-shell deferral record), #432 (shell main), #433 (syscall shim)

## Landing scope

This issue lands two support modules for the demonstrative shell:

### src/user/io.pdx (I/O helpers)

- `puts(msg_ptr: u64, msg_len: u64) -> u64` — thin wrapper of `sys_debug_puts`. Returns message length echoed.

**Explicitly NOT provided** (per §C freeze at R13):
- `getline(buf_ptr, buf_len)` — requires `sys_read`; deferred to R14.

### src/user/builtins.pdx (shell builtins)

- `help_msg : [u8; 12]` — constant "help|exit\n" (null-padded to 12 bytes).
- `builtin_help() -> u64` — prints help menu via `puts`.
- `builtin_exit(code: u64) -> u64` — never returns; delegates to `sys_exit_thread`.
- `dispatch_cap(slot: u64, op_arg: u64) -> u64` — thin wrapper of `sys_cap_invoke`. Returns op result.

**Explicitly NOT provided** (per §C freeze + #483):
- `parse_decimal(str, len) -> u64` — decimal string parsing (needed for `cap N M` builtin).
- `cap N M` builtin — requires both `sys_read` and decimal parsing; deferred to R14.

## Design rationale: limited builtin surface

At R13, the shell has no way to:
1. Read user input (no `sys_read` in §C).
2. Parse user input (no decimal parsing, no buffer manipulation).
3. React to wakeup sources (no IPC port events, no timer events).

Therefore, the only meaningful builtins at R13 are:
- `help` — static output (can print).
- `exit` — terminate (can do immediately).
- `cap` dispatch — invoke a capability (can do immediately, but no arguments from user).

## Data layout (builtins)

```
help_msg : [u8; 12] = b"help|exit\n\0\0"
```

Stored as a fixed-size byte array (12 u64s = 96 bits). Length tracked separately (10 bytes of content, 2 null terminators for padding).

## Implementation pattern

### puts (io.pdx)

```asm
puts:
  call sys_debug_puts   # args already in rdi/rsi per SysV
  ret                   # return with result in rax
```

Thin wrapper; adds no logic. Arguments (msg_ptr, msg_len) are already in RDI/RSI per SysV ABI, so no register manipulation needed.

### builtin_help (builtins.pdx)

```asm
builtin_help:
  lea rdi, [rip + help_msg]   # load help_msg address via RIP-relative
  mov rsi, 10                 # length = 10 bytes
  call puts                   # delegate to puts
  ret
```

Uses RIP-relative LEA to load the address of help_msg (position-independent code).

### builtin_exit (builtins.pdx)

```asm
builtin_exit:
  call sys_exit_thread  # code already in rdi per SysV
  ret                   # never executed
```

Code argument (exit code) is already in RDI, so no setup needed. Never returns.

### dispatch_cap (builtins.pdx)

```asm
dispatch_cap:
  call sys_cap_invoke   # slot in rdi, op_arg in rsi per SysV
  ret                   # return with result in rax
```

Thin wrapper; args (slot, op_arg) already in RDI/RSI per SysV ABI.

## Justification for unsafe { }

- **sysreg effect**: All four functions call syscall shims, which issue SYSCALL instructions. The kernel modifies system state (MSRs, thread state).
- **cap capability** (dispatch_cap only): The kernel-side `sys_cap_invoke` handler checks capability rights. The `@{cap}` annotation flags this dependency.

## Why "decimal-parse cap N M" is deferred

The demonstrative shell at R13 cannot execute `cap 2 3` because:

1. **No sys_read**: Cannot read user input from the terminal/UART.
2. **No parsing**: No decimal string parsing library (would need dynamic allocation or fixed buffer, both absent at R13).
3. **Static dispatch only**: The only meaningful capability operation at R13 is `dispatch_cap(0, 0)` (hard-coded no-op).

Once R14 lands `sys_read`, the shell can:
1. Read a line from UART: `sys_read(buf, len)`.
2. Parse decimal numbers: `strtoul(buf, 10)` or inline parser.
3. Implement `cap N M` builtin with dynamic slot/op_arg.

This is tracked in #483.

## Regression

New source files outside the kernel build. No changes to existing kernel code or src/kernel/.
`tools/build.sh` only globs `src/kernel/`, so src/user/ .pdx files are NOT compiled at R13.
No binary produced; no regression vector.

## Acceptance

- [x] I/O module created: src/user/io.pdx (puts only).
- [x] Builtins module created: src/user/builtins.pdx (help, exit, dispatch_cap).
- [x] No getline (requires sys_read; deferred to R14).
- [x] No cap N M decimal parsing (requires sys_read + parsing; deferred to R14).
- [x] RIP-relative addressing for help_msg (position-independent).
- [x] SysV x86_64 ABI compliance (rdi/rsi arg convention).
- [x] Unsafe blocks justified (sysreg effects, capability requirements).

## Cross-references

- src/user/syscall_shim.pdx (R13-m7-002 #433 — sys_debug_puts, sys_exit_thread, sys_cap_invoke)
- src/user/shell.pdx (R13-m7-001 #432 — consumer of puts, builtin_help, dispatch_cap, builtin_exit)
- #419 (§C-frozen syscall table)
- #483 (R13 user-shell deferral record — justifies deferred features)
