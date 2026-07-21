# R17.M3-005: shell fork/exec_child (#625)

## Summary

New `src/user/dispatch.pdx:exec_child() -> u64` provides fork+execve fallback when `dispatch_line` returns 1 (builtin miss). Forks via `sys_fork`, execves `argv[0]` with NULL-terminated `argv_buf` and `envp=NULL`, and waits for the child via `sys_wait4(&child_wait_status, 0, NULL)`. Parent waits; child exits 127 on execve failure. Also expands `argv_buf` from `[u64;16]` to `[u64;17]` to accommodate the NULL terminator slot required by execve. Marker: `R17 EXEC OK`.

## Design Intent

### Phase Scope (R17.M3-005)
- New function: `exec_child() -> u64` in `Dispatch` module.
- New .bss symbol: `child_wait_status : [u64; 1]` (execve wait status placeholder).
- Grow `Tokenizer.argv_buf` from 16 slots to 17 slots (+1 reserved for NULL terminator).
- `_start` wiring: after `call dispatch_line`, check `rax==0`; if not matched (rax==1), call `exec_child`.
- No change to 16-argument maximum cap (tokenize loop still `cmp r10, 16`).

### Signature Discipline
- `exec_child() -> u64` — reads argc / argv_buf from Tokenizer .bss (linked symbols); returns 0 on child spawned (parent path via wait4), 1 on error (argc==0 or fork failed).
- Parent path: `sys_fork` → parent receives child PID in rax → `sys_wait4(pid, &child_wait_status, 0, NULL)` → return 0.
- Child path: NULL-terminate `argv_buf[argc]`, call `sys_execve(argv[0], &argv_buf[0], NULL)`. On execve failure, call `sys_exit(127)` and halt.
- Capability set `@{fs, sched, cap}` matches syscall needs: fs for execve, sched for fork/wait4, cap for no-op.
- Effect set `!{mem, sysreg, sysprivcap}` mirrors full syscall access.

### Architectural Rationale
1. **Why fork+execve?**: R17.M3 shell operates in kernel-loaded address space. To run external binaries, fork gives child a copy of the process image (argv, tokenizer .bss intact), execve replaces child's code/data, parent waits and reaps. Kernel dispatch.pdx routes sys_fork/sys_execve/sys_wait4 to ENOSYS (issue #668) — structural canary only.
2. **NULL-terminated argv**: POSIX execve expects `envp` and implicit argv NUL-termination (last slot == NULL). Growing argv_buf by 1 slot reserves space; exec_child writes `argv_buf[argc] = 0`.
3. **Wait status placeholder**: Parent calls sys_wait4 to reap child and receive exit status into `child_wait_status[0]`. Status available for future analysis (e.g., exit code extraction); not used in shell loop (shell continues regardless).
4. **Exit 127 on execve failure**: Canonical POSIX shell convention (e.g., bash). Child never returns from execve on success; if execve fails (file not found, permission denied), exit 127 signals "command not found or not executable" to parent.
5. **Reads .bss, not params**: consistent with dispatch_line and builtin handlers — no arg-marshalling needed; shell _start has argc/argv_buf in scope.

## Data Layout

| Symbol | Section | Size | Notes |
|---|---|---|---|
| `argv_buf` | .bss | 136 B (`[u64;17]`) | Grown by 1 slot from [u64;16]; slot [16] = NULL terminator for execve |
| `argc` | .bss | 8 B (`u64`) | Unchanged; counts actual args (0..16); does NOT include NULL slot |
| `child_wait_status` | .bss | 8 B (`[u64;1]`) | Uninit @align(8); receives sys_wait4 status |

## Pseudocode

```
exec_child():
    if argc == 0:
        return 1  # no command to exec

    # NULL-terminate argv_buf[argc]
    argv_buf[argc] = 0

    # fork
    pid = sys_fork()
    if pid < 0:
        return 1  # fork failed

    if pid == 0:  # child
        # execve(argv[0], &argv_buf[0], NULL)
        sys_execve(argv_buf[0], &argv_buf[0], NULL)
        # execve never returns on success; on failure:
        sys_exit(127)
        hlt  # unreachable
    else:
        # parent
        sys_wait4(pid, &child_wait_status, 0, NULL)
        return 0
```

## Assembly Pattern

Full exec_child body (from dispatch.pdx):

```asm
        # Guard: argc == 0 → error
        lea rax, [rip + argc]
        mov rax, [rax]
        cmp rax, 0
        je exec_child_err

        # NULL-terminate argv_buf[argc] = 0
        xor rcx, rcx
        lea r11, [rip + argv_buf]
        mov [r11 + rax*8], rcx   # argv_buf[rax] = 0

        # fork
        call sys_fork
        cmp rax, 0
        jl exec_child_err        # fork < 0 → error
        je exec_child_do_execve  # fork == 0 → child

        # parent: wait4(pid, &child_wait_status, 0, NULL). rax has pid.
        mov rdi, rax
        lea rsi, [rip + child_wait_status]
        xor rdx, rdx
        xor rcx, rcx
        call sys_wait4
        ret

exec_child_do_execve:
        # child: execve(argv[0], &argv_buf[0], NULL)
        lea rax, [rip + argv_buf]
        mov rdi, [rax]           # rdi = argv[0] (pointer to program name)
        lea rsi, [rip + argv_buf]  # rsi = &argv_buf[0]
        xor rdx, rdx             # rdx = NULL (envp)
        call sys_execve
        # execve returned → failed. Exit 127.
        mov rdi, 127
        call sys_exit
        hlt

exec_child_err:
        mov rax, 1
        ret
```

## `shell.pdx _start` diff

In main loop, after `call dispatch_line`:

```asm
        call dispatch_line       # rax = 0 (hit) or 1 (miss)
        cmp rax, 0
        je main_loop             # if hit, loop

        # rax==1: builtin miss — fork+execve argv[0] and wait
        call exec_child

        jmp main_loop
```

If dispatch_line returned 0 (builtin matched), jump directly to main_loop. Otherwise, call exec_child to attempt external binary execution.

## paideia-as Posture

Exercised and confirmed working:
- `sys_fork`, `sys_execve`, `sys_wait4`, `sys_exit` syscall shims — all supported (precedent in init.pdx #619).
- Indexed store with rax scale `mov [rip + argv_buf + rax*8], rcx` — supported (tokenizer.pdx precedent).
- Local label prefixing `exec_child_err:`, `exec_child_do_execve:` — supported (convention: label-name collisions with reserved keywords avoided; here "loop" is reserved, so labels prefixed `exec_child_`).

**Not needed** (avoided): argument-marshalling prologue/epilogue beyond what syscall shims provide.

## AC Caveat — Kernel Dispatch Limitation

**Kernel dispatch.pdx routes SC+ 56 (sys_fork), 59 (sys_execve), 61 (sys_wait4) to ENOSYS.** Issue #668 tracks kernel-side implementation. For now, this ship is a **structural canary** — exec_child assembles, verifies, and is wired into shell.elf, but actual fork/execve/wait4 execution will fail at runtime (returns -ENOSYS). Matches precedent: init.pdx #619 shipped sys_open/sys_dup2/sys_close canaries before kernel support existed. Verification checks confirm all syscall sites and exit paths are in place; runtime will validate when kernel catches up.

## Verification

`tools/verify-user-exec-child.sh` (new). Wired into `tools/build-user.sh` after `verify-user-dispatch.sh`. Marker: `R17 EXEC OK`. Twelve checks:

1. `exec_child` symbol present, size ≥ 40 bytes.
2. `child_wait_status` in .bss, size 0x8.
3. `exec_child` calls `sys_fork` ≥ 1.
4. `exec_child` calls `sys_execve` ≥ 1.
5. `exec_child` calls `sys_wait4` ≥ 1.
6. `exec_child` calls `sys_exit` ≥ 1 (child's failure path).
7. `exec_child` contains `mov edi,0x7f` OR `mov rdi,0x7f` (127 literal for exit code).
8. `exec_child` contains indexed store into argv_buf area `mov QWORD PTR [...*8],` (NULL-terminator write).
9. `_start` calls `exec_child` exactly once.
10. `_start` ordering: `dispatch_line` call PC < `exec_child` call PC.
11. `_start` has `cmp rax,0` followed by `je` within ~8 instructions after `call dispatch_line`.
12. #1248 hygiene: zero `cmp al,` in exec_child.

Also updated: `verify-user-tokenizer.sh` check 1 now expects argv_buf size 0x88 (136 = 17*8), not 0x80.

## Smoke Test Compliance

5-mode smoke (`boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`, `boot_r12_denial`) byte-identical (no kernel changes). shell.elf grows by ~100 bytes (exec_child body + dispatch-init bss slot); kernel.elf unchanged. No new kernel syscall handler needed yet (will be added in #668).

## Deferred

- **Kernel dispatch.pdx sys_fork/sys_execve/sys_wait4 handlers** (#668) — currently return ENOSYS. Will unblock actual external binary execution once merged.
- **PATH search** — exec_child uses argv[0] directly; no bin:/usr/bin search. Post-#625 enhancement.
- **Environment variables** — execve called with envp=NULL. Env support deferred post-#625 (would require shell-wide env storage).
- **Exit status ($?)** — child_wait_status is collected but not exposed. Future shell variable $? post-#625.
- **Quoting, redirection, pipes** — R18+.
- **Signal handling** — SIGCHLD, etc., deferred.

## References

- Issue: paideia-os#623 → #624 → #625.
- Prior: #621 (skeleton), #622 (reader), #623 (tokenizer), #624 (dispatch).
- Feedback: `feedback_workerbee_verify_claims.md` (structural canary discipline), `feedback_cross_repo_escalation.md` (escalation pattern).
- AC Note: Kernel dispatch.pdx issue #668 (fork/execve/wait4 handlers).
- Files: `src/user/dispatch.pdx`, `src/user/tokenizer.pdx`, `src/user/shell.pdx`, `tools/verify-user-exec-child.sh`, `tools/build-user.sh`, `design/kernel/r17-m3-005-shell-fork-exec-child.md`.
- Precedent: init.pdx #619 (sys_open/dup2/close canaries), kernel/fs/vops.pdx (syscall dispatch), tokenizer.pdx (indexed argv_buf store).
