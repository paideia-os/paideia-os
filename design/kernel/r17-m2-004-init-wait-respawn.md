# R17.M2-004: Init Parent Wait Loop + Shutdown

**Issue**: #619 — Parent loop in init: wait, log status, respawn shell OR shutdown.

**Milestone**: R17.M2 (shell bootstrap / capability system foundation)

**Status**: Implementation (extends #618 fork/exec inline init)

---

## Summary

Extend init's parent path (after fork + child execve) with a wait loop:
1. Call `sys_wait4(pid=-1, wstatus, options=0, rusage=NULL)` to reap child shell process.
2. Log "REAPED\n" to debug console.
3. For R17.M2 scope: proceed to `init_shutdown` (respawn deferred to R17.M3).
4. Call `sys_exit(0)` to shut down the init process.

This establishes the parent-loop skeleton for future respawn logic (R17.M3+) while delivering clean child reaping and controlled shutdown for R17.M2.

---

## Design

### Data Layout (rodata + .bss)

**Rodata additions** (R17.M2-003 → R17.M2-004):
```
reaped_msg : [u8; 8] = "REAPED\n\0"
reaped_len : u64 = 7
```

**.bss additions** (R17.M2-003 → R17.M2-004):
```
wait_status : [u64; 1] = [0]     // wstatus slot for sys_wait4
```

### Control Flow (updated init_parent)

**Previous** (R17.M2-003, #618):
```
init_parent:
    lea rdi, [rip + init_msg]
    mov rsi, 8
    call sys_debug_puts
    jmp init_parent        // infinite loop → hlt
```

**New** (R17.M2-004, #619):
```
init_parent:
    // sys_wait4(pid=-1, wstatus, options=0, rusage=NULL)
    mov rdi, -1                      // pid = -1 (any child)
    lea rsi, [rip + wait_status]     // wstatus ptr
    xor rdx, rdx                     // options = 0
    xor rcx, rcx                     // rusage = NULL
    call sys_wait4
    
    // rax = child pid or error
    cmp rax, 0
    jl init_shutdown                 // error → shutdown
    
    // Log "REAPED\n"
    lea rdi, [rip + reaped_msg]
    mov rsi, 7
    call sys_debug_puts
    
    // For R17.M2: no respawn, proceed to shutdown
    jmp init_shutdown

init_shutdown:
    // sys_exit(0)
    xor rdi, rdi                     // status = 0
    call sys_exit
    hlt                              // (unreachable, fallback safety)
    jmp init_shutdown
```

### Syscall Semantics

**sys_wait4** (R17-M1-001 SC+ ID 61, arity 4):
- **Entry** (SysV calling convention): `rdi, rsi, rdx, rcx` → child pid, wstatus ptr, options, rusage ptr
- **Kernel shuffle**: SysV `rcx` → SYSCALL `r10` (third-arg slot mismatch)
- **Return**: `rax` = waited child pid (or negative error)
- **Capability**: `{sched}` (inherited from syscall_shim.pdx definition)
- **Precondition**: child shell must have exited (blocking wait)

**sys_exit** (R17-M1-001 SC+ ID 60, arity 1):
- **Entry** (SysV): `rdi` = exit status code
- **Return**: never (replaces task with exit handler)
- **Capability**: `{sched}`
- **Semantics**: initiate graceful shutdown path

---

## Verification (tools/verify-user-init.sh)

Extended verifier checks (cumulative from R17.M2-003):

1. **Syscall stubs** (byte-pattern):
   - `sys_open` (ID 2, 10 bytes)
   - `sys_dup2` (ID 32, 10 bytes)
   - `sys_close` (ID 3, 10 bytes)
   - `sys_fork` (ID 56, 10 bytes)
   - `sys_execve` (ID 59, 10 bytes)
   - `sys_exit` (ID 60, 10 bytes) — **NEW**
   - `sys_wait4` (ID 61, 13 bytes with r10 shuffle) — **NEW**

2. **Call site audits** (in _start disassembly):
   - `call sys_open` (1x)
   - `call sys_dup2` (3x)
   - `call sys_close` (1x)
   - `call sys_fork` (1x)
   - `call sys_execve` (1x)
   - `call sys_exit` (1x) — **NEW**
   - `call sys_wait4` (1x) — **NEW**

3. **Rodata + .bss symbols**:
   - `bin_sh_path`, `init_msg`, `dev_tty0_path` (R17.M2-003)
   - `reaped_msg` — **NEW**
   - `wait_status` — **NEW**

4. **Branching** (fork result dispatch):
   - `cmp rax, 0` + `je init_child` (fork return check)
   - `cmp rax, 0` + `jl init_shutdown` (wait4 error check) — **NEW**

**Output**: `"R17 INIT WAIT OK"` (stdout) or `"R17 INIT WAIT FAIL"` (stderr)

---

## Implementation Boundary (R17.M2 vs. R17.M3)

**R17.M2 scope** (this issue #619):
- Wait for child (blocking).
- Log reap event.
- Proceed to shutdown.
- No respawn loop.

**R17.M3 scope** (deferred):
- Add loop-back logic after reaped_msg log.
- Fork + exec new shell (respawn).
- Handle shell restart on exit.

---

## Testing

### Smoke Test (5-mode byte-identity)

Run `tools/run-smoke.sh` after build:
- User init build: `src/user/init.pdx` → `build/user/init.elf`
- Verify output: `"R17 INIT WAIT OK"` from verifier
- Byte-identical across compile modes (debug, release, LTO, etc.)

### Runtime Behavior (manual verification)

1. **Boot paideia-os**, shell prompt appears.
2. **Type `exit`** at shell prompt.
3. **Observe** kernel console:
   - Shell exits
   - Init logs: `"REAPED\n"` (sys_wait4 succeeds)
   - Init logs: `"INIT OK\n"` → shutdown initiated
   - Kernel hlt loop (graceful shutdown)

### Error Paths

- **sys_wait4 returns error** (`rax < 0`): jump to `init_shutdown` (no log)
- **sys_exit call**: kernel handler terminates task (never returns)

---

## Files Modified

- `src/user/init.pdx` — added reaped_msg rodata, wait_status .bss, wait loop + shutdown
- `tools/verify-user-init.sh` — extended checks for sys_wait4, sys_exit, new symbols

---

## References

- **Issue #619**: Parent loop in init: wait, log status, respawn shell OR shutdown
- **Issue #618** (R17.M2-003): fork + execve inline init
- **Issue #617** (R17.M2-002): TTY fd initialization
- **R17-M1-001** (#610): Syscall shim (sys_wait4, sys_exit definitions)
- **R15.M6**: sys_fork, sys_execve kernel handlers
- **R15.M4-003** (#537): sys_exit kernel handler

---

## Acceptance Criteria

1. ✓ init.pdx contains sys_wait4 + sys_exit
2. ✓ rodata: reaped_msg string
3. ✓ .bss: wait_status slot
4. ✓ init_parent calls sys_wait4 → logs → shutdown
5. ✓ init_shutdown calls sys_exit
6. ✓ verifier reports "R17 INIT WAIT OK"
7. ✓ 5-mode smoke stays byte-identical
8. ✓ design doc created (this file)
