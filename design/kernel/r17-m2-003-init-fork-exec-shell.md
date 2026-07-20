# R17.M2-003: init fork_exec_shell inline (#618)

## Summary

Extends R17.M2-002 (#617) user-mode init with process forking and shell execution capability. After TTY initialization (fds 0/1/2 → /dev/tty0), init forks; child execves `/bin/sh`; parent enters wait loop printing "INIT OK\n" on serial.

**Acceptance**: sh's banner appears on serial (loader + tmpfs seed runtime deferred to #620).

## Design Intent

### Phase Scope (R17.M2)
- Structural: inline fork + execve path in init's _start
- No new syscall implementations (sys_fork ID 56 + sys_execve ID 59 already in R17.M1-001)
- Verify fork + execve call sequences and rodata symbol integrity
- Parent → serial output; child → shell handoff (shell banner deferred to #620)

### Architectural Rationale
1. **Fork semantics**: Establish user-mode child process creation via SC+ ID 56
2. **Execve semantics**: Establish user-mode program replacement via SC+ ID 59
3. **Code path separation**: Parent (monitoring) vs child (shell execution) clearly delineated
4. **Failure recovery**: If execve returns (error), fall through to debug message

## Implementation

### Rodata Extension (init.pdx §1)
```
pub let bin_sh_path : [u8; 8] = "/bin/sh\0"
```
Added alongside existing `dev_tty0_path` and `init_msg`.

### Fork/Execve Sequence (init.pdx §2: _start)

**Placement**: After close(original_fd) (end of TTY setup) and before parent sys_debug_puts.

**Pseudocode**:
```
call sys_fork;           // SC+ ID 56: fork. rax = 0 (child), child_pid (parent), or error
mov r12, rax;            // save fork result
cmp rax, 0;              // test if child
je init_child;           // branch if child (rax == 0)

// Parent path (continue after jmp init_parent label):
lea rdi, [rip + init_msg];
mov rsi, 8;
call sys_debug_puts;
jmp init_parent;

// Child path (init_child label):
lea rdi, [rip + bin_sh_path];  // "/bin/sh\0"
xor rsi, rsi;                  // argv = NULL (will link to kernel stub later)
xor rdx, rdx;                  // envp = NULL
call sys_execve;               // SC+ ID 59: should not return on success
jmp init_error;                // if execve returns, error handling

// Error path (init_error label):
lea rdi, [rip + init_msg];
mov rsi, 8;
call sys_debug_puts;

// Parent wait loop (init_parent label):
loop_start:
  hlt;
  jmp loop_start
```

**Byte Impact**: ~40 LOC added to _start.

### Verification (tools/verify-user-init.sh)

R17.M2-002 checks (FD OK):
- sys_open, sys_dup2 (3x), sys_close bytecode patterns
- call sys_open, call sys_dup2, call sys_close in _start

**R17.M2-003 additions (FORK OK)**:
- sys_fork bytecode (ID 56): `48 c7 c0 38 00 00 00 0f 05 c3`
- sys_execve bytecode (ID 59): `48 c7 c0 3b 00 00 00 0f 05 c3`
- call sys_fork in _start
- call sys_execve in _start
- bin_sh_path rodata symbol presence
- cmp+je branching (fork result test)

**Exit marker**: "R17 INIT FORK OK" (pass) / "R17 INIT FORK FAIL" (fail).

## Smoke Test Compliance

5-mode smoke (`tools/run-smoke.sh`) must remain byte-identical:
- init bytecode size/layout stable
- no new code sections or relocations
- no new syscall IDs invoked (56 + 59 already in shim)

## Ground Rules Checklist

✓ Deliver "R17 INIT FORK OK" from verifier (tools/verify-user-init.sh)  
✓ Extend init.pdx ~40 LOC (rodata + fork/execve sequence)  
✓ Extend verify-user-init.sh with sys_fork + sys_execve + bin_sh_path checks  
✓ Include this design doc  
✓ Build + verify + smoke (byte-identical)  
✓ Commit + verify git log origin/main..HEAD empty  

## Acceptance Test (R17.M2-003)

Run:
```bash
cargo build --release -p paideia-os
tools/verify-user-init.sh
tools/run-smoke.sh
```

Expected:
- Verifier: "R17 INIT FORK OK"
- Smoke: all 5 modes pass, no byte changes
- No new git commits needed between build and push (commit once, verify empty log, push)

## Deferred (R17.M2 → #620 loader + tmpfs seed)

- Shell binary load + mount tmpfs
- Shell banner output
- Interactive shell loop
- Full process initialization story

## References

- R17.M1-001 (#610): SC+ frozen syscall shim (sys_fork ID 56, sys_execve ID 59)
- R17.M2-002 (#617): init TTY fd initialization
- R17.M2-001 (#616): ring-3 user entry
- design/kernel/r17-m1-001-syscall-shim.md: syscall enumeration
- src/user/syscall_shim.pdx: sys_fork, sys_execve definitions
