# R17.M4: Shell Builtins Batch (#629-634)

## 1. Overview

Extend the PaideiaOS shell with 5 new built-in commands: `pwd` (print working directory), `help` (list all builtins), `env` (print environment), and enhancements to `echo` (add `-n` flag support) and `exit` (accept optional numeric exit code). These are fundamental utilities for shell usability and bootstrap.

Issues: #629 (echo -n), #630 (exit N), #631 (pwd), #632 (cd — deferred), #633 (help), #634 (env).

## 2. Table Growth

### Builtin Registry Expansion

The three dispatch tables grow from 2 entries (echo, exit) to 5 entries (echo, exit, pwd, help, env):

- `builtin_names[8]`: Holds pointers to null-terminated builtin name strings (64 bytes = 8 × u64).
- `builtin_handlers[8]`: Holds pointers to builtin function addresses (64 bytes = 8 × u64).
- `builtin_descs[8]`: NEW — holds pointers to human-readable description strings for help (64 bytes = 8 × u64).
- `builtin_count`: Updated to 5 during `dispatch_init`.

The tables remain overallocated to 8 entries; indices 5–7 are unused, reserved for future builtins (cd, etc.).

## 3. State & Buffers

### Working Directory Buffer (`_cwd_buf`)

- **Symbol**: `_cwd_buf[256]`
- **Section**: `.bss`
- **Alignment**: 8 bytes
- **Purpose**: Holds the current working directory path as a null-terminated C-string. Initially `/\0...\0`.
- **Init**: Called via `cwd_init()` during `_start`.
- **Reserved for**: Future `cd` builtin (when `sys_chdir` kernel syscall is available).

### Echo Control Flag (`echo_emit_nl`)

- **Symbol**: `echo_emit_nl`
- **Section**: `.bss`
- **Size**: 8 bytes (u64)
- **Purpose**: Transient flag set by `echo_builtin` to control whether a trailing newline is emitted. Set to 1 (default) or 0 if `-n` flag is detected.

## 4. Data Strings

### Rodata Entries

```
echo_name    = "echo\0"
exit_name    = "exit\0"
pwd_name     = "pwd\0"
help_name    = "help\0"
env_name     = "env\0"
echo_desc    = "echo text to stdout\0"
exit_desc    = "exit shell (opt N)\0"
pwd_desc     = "print working directory\0"
help_desc    = "list all builtins\0"
env_desc     = "print environment vars\0"
help_sep     = " - \0"
env_path_msg = "PATH=/bin\n\0"
```

### Rodata Verification

Hex byte sequences in `.rodata`:
- `help_sep`: `20 2d 20` (space-dash-space)
- `env_path_msg`: `50 41 54 48 3d 2f 62 69 6e 0a` (PATH=/bin\n)

## 5. Function Changes & New Functions

### Affected: `dispatch_init() → ()`

**Size requirement**: ≥ 0x90 bytes (144 decimal).

Updated to populate three tables:

1. Write echo_name, exit_name, pwd_name, help_name, env_name into `builtin_names[0..4]`.
2. Write echo_builtin, exit_builtin, pwd_builtin, help_builtin, env_builtin into `builtin_handlers[0..4]`.
3. Write echo_desc, exit_desc, pwd_desc, help_desc, env_desc into `builtin_descs[0..4]`.
4. Set `builtin_count = 5` via `mov rax, 5; mov [builtin_count], rax`.

### Enhanced: `echo_builtin() → u64`

**Changes**:
- Detects `-n` flag in `argv[1]` (exactly: `-`, `n`, NUL).
- If `-n` present: suppresses trailing newline, starts output from `argv[2]`.
- Otherwise: outputs `argv[1..argc-1]` with trailing newline (unchanged from M3).

**Verification**:
- References `echo_emit_nl`.
- Contains `cmp rax, 0x2d` (dash byte) and `cmp rax, 0x6e` (n byte).

### Enhanced: `exit_builtin() → u64`

**Changes**:
- Accepts optional numeric exit code in `argv[1]`.
- Calls `dec_parse(argv[1])` to convert decimal string to u64.
- Passes parsed value to `sys_exit`; falls back to 0 if no argument.

**Verification**:
- Calls `dec_parse` function.

### New: `dec_parse(rdi: u64) → u64`

**Signature**: Takes C-string pointer in `rdi`, returns parsed decimal u64 in `rax`.

**Algorithm**:
1. Initialize `rax = 0` (accumulator).
2. Loop: Load byte at `[rdi]`, zero-extend to u64.
3. If byte < 0x30 or > 0x39: exit loop (non-digit).
4. Accumulate: `rax = rax*8 + rax + rax + (byte - 0x30)` (equivalent to `rax*10 + digit`).
   - Implemented as: `shl rax, 3` (multiply by 8), `add rax, rax` twice (add rax twice = +2*rax), total +10*rax. Then add digit.
5. Increment pointer, loop.

**Verification**:
- Contains `cmp rax, 0x30`, `cmp rax, 0x39`, `shl rax, 0x3`.
- Pure function: no effects, no capabilities.

### New: `cwd_init() → ()`

**Signature**: No arguments, no return.

**Algorithm**:
1. Load address of `_cwd_buf`.
2. Set `_cwd_buf[0] = 0x2F` (ASCII `/`).
3. Return. (.bss is zero-init; byte 1 is already NUL.)

**Verification**:
- Called once from `_start`, after `dispatch_init`.
- PC ordering: `cwd_init` starts after `dispatch_init`, before `shell_read_line`.
- Pure function: no effects, no capabilities.

### New: `pwd_builtin() → u64`

**Signature**: No arguments. Returns 0 (success).

**Algorithm**:
1. Call `puts_new(_cwd_buf)` to emit current working directory.
2. Call `sys_write(1, "\n", 1)` to emit newline.
3. Return 0.

**Verification**:
- References `_cwd_buf`.
- Calls `puts_new` and `sys_write`.
- Capabilities: `{fs}` (stdout write).

### New: `help_builtin() → u64`

**Signature**: No arguments. Returns 0 (success).

**Algorithm**:
1. Save `r12` (callee-saved).
2. Initialize `r12 = 0` (builtin index loop counter).
3. Loop:
   - Load `builtin_count` into `rax`.
   - If `r12 >= rax`: exit loop (done).
   - Emit: `builtin_names[r12]`, then `" - "`, then `builtin_descs[r12]`, then newline.
   - Increment `r12`, loop.
4. Restore `r12`, return 0.

**Verification**:
- References `builtin_names`, `builtin_descs`, `builtin_count`.
- Calls `puts_new` ≥ 2 times (names and descs).
- Calls `sys_write` ≥ 2 times (sep and newlines).
- Contains backward `jmp` (loop structure).
- Capabilities: `{fs}` (stdout write).

### New: `env_builtin() → u64`

**Signature**: No arguments. Returns 0 (success).

**Algorithm**:
1. Call `sys_write(1, "PATH=/bin\n", 10)` to emit environment stub.
2. Return 0.

**Verification**:
- Calls `sys_write` exactly once.
- Capabilities: `{fs}` (stdout write).

## 6. Integration: `shell.pdx` _start

In the `_start` function:

```x86-64
call dispatch_init;
call cwd_init;
// main_loop:
main_loop:
  ...
```

The `cwd_init` call must occur immediately after `dispatch_init` and before the main loop begins (`shell_read_line` call).

## 7. Compiler Hygiene (#1248)

**Paideia-as Issue #1248**: The assembler may emit `cmp al, imm8` as a full-width `cmp rax, imm8` with REX.W, causing unexpected sign-extension.

**Mitigation** (applied in all new functions):
- Avoid byte-narrow `cmp al,` instructions.
- Use explicit zero-extend: `xor rax, rax; mov al, [ptr]; and rax, 0xff; cmp rax, imm` before comparing bytes.

**Verification check**: No `cmp al,` patterns in `pwd_builtin`, `help_builtin`, `env_builtin`, `dec_parse`, or `cwd_init`.

## 8. Verifier Coverage

**Script**: `tools/verify-user-builtins-m4.sh`

**Marker**: `R17 BUILTINS M4 OK` / `R17 BUILTINS M4 FAIL`

**35 checks**:

1. Symbol presence: pwd_builtin, help_builtin, env_builtin, dec_parse, cwd_init.
2. .bss sizes: builtin_descs (0x40), echo_emit_nl (0x8), _cwd_buf (0x100).
3. Rodata byte sequences: pwd_name, help_name, env_name, env_path_msg, help_sep.
4. dispatch_init size ≥ 0x90 and writes builtin_count=5.
5. _start calls cwd_init exactly once.
6. cwd_init PC ordering (after dispatch_init, before shell_read_line).
7. echo_builtin: references echo_emit_nl, contains cmp 0x2d and cmp 0x6e.
8. exit_builtin: calls dec_parse.
9. dec_parse: contains cmp 0x30, cmp 0x39, shl 0x3.
10. pwd_builtin: references _cwd_buf, calls puts_new and sys_write.
11. help_builtin: references builtin_names/descs/count, calls sys_write ≥2, puts_new ≥2, backward jmp.
12. env_builtin: calls sys_write exactly once.
13. #1248 hygiene: no `cmp al,` in new functions.

## 9. Effect Sets & Capabilities

| Function | Effects | Capabilities |
|----------|---------|--------------|
| cwd_init | `{mem}` | `{}` |
| dec_parse | `{mem}` | `{}` |
| echo_builtin | `{mem, sysreg}` | `{fs}` |
| exit_builtin | `{mem, sysreg}` | `{}` |
| pwd_builtin | `{mem, sysreg}` | `{fs}` |
| help_builtin | `{mem, sysreg}` | `{fs}` |
| env_builtin | `{mem, sysreg}` | `{fs}` |

## 10. Deferred Work (#632: cd)

The `cd` builtin is intentionally deferred until kernel-side `sys_chdir` syscall (issue #732 or later) is available. The `_cwd_buf` buffer and `pwd` command are in place to support it.

When `sys_chdir` is implemented:
1. Parse destination path from `argv[1]`.
2. Call `sys_chdir(dest_path)`.
3. On success: update `_cwd_buf` with new path; return 0.
4. On error: return non-zero; emit error message.

---

**References**:
- [R17-M3-004: Shell Builtin Dispatch](r17-m3-004-shell-builtin-dispatch.md)
- [Softarch Brief](../softarch/r17-shell-batch.md)
- [Paideia-as Issue #1248](https://github.com/anthropics/paideia-as/issues/1248)
- [PaideiaOS Issue #632: cd builtin](https://github.com/PaideiaOS/paideia-os/issues/632)
