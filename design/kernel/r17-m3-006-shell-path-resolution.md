# R17.M3-006: shell path resolution (#626)

## Summary

New `src/user/dispatch.pdx:resolve_path() -> u64` provides automatic `/bin/` prefix when shell's `exec_child()` attempts to execute a program. If `argv[0]` contains a `/` character, it is passed through unchanged. Otherwise, the path `/bin/` is prepended, forming `/bin/<command>`, stored in the `resolved_path` .bss slot, and its address returned. The modified `exec_child` child branch calls `resolve_path()` before `sys_execve`, replacing the direct `argv[0]` dereference. Marker: `R17 PATH RESOLVE OK`.

## Design Intent

### Phase Scope (R17.M3-006)
- New function: `resolve_path() -> u64` in `Dispatch` module.
- New .bss symbol: `resolved_path : [u8; 320]` (path buffer, sized for 256B line + `/bin/` prefix + slack).
- New rodata constant: `bin_prefix = "/bin/\0"` (5 bytes + NUL).
- `exec_child` child branch wiring: replace direct `lea rax, [rip + argv_buf]; mov rdi, [rax]` with `call resolve_path; mov rdi, rax`.
- No change to tokenizer, dispatch_line, or exec_child parent-side logic.

### Signature Discipline
- `resolve_path() -> u64` — reads `argv_buf[0]` (linked symbol from Tokenizer module); scans for `/` (0x2F); if found, returns `argv[0]` unchanged; if not found, prepends `/bin/` into `resolved_path` buffer and returns its address.
- Effect set `!{mem}` — reads/writes memory (memcpy, strlen, buffer operations).
- Capability set `@{}` — no syscall or privilege capability needed; pure string manipulation.
- Register plan: r8=argv[0], r9=cursor (scan pointer), rax=byte/return value.

### Architectural Rationale

1. **Why automatic `/bin/` prefix?**: Shell commands like `ls`, `cat`, `echo` (external binary variants) are typically in `/bin`. Prepending `/bin/` enables single-word command execution (user types `ls`, resolves to `/bin/ls`) without requiring the user to remember full paths or a PATH environment variable search loop. Improves UX for Phase 2 (capability system) shell; deferred full PATH support to post-#626 (see Deferred).

2. **Scan for `/` (0x2F)?**: The slash presence indicates an explicit path (relative or absolute). Absolute paths `/foo/bar` and relative paths `./cmd` both contain `/`, so should not be prefixed. Only bare words like `ls` (no slash) get the prefix.

3. **320-byte buffer?**: 256-byte input line (shell.pdx `line_buf`) + 5-byte prefix (`/bin/`) + 59 bytes slack = 320. Fits safely on a cacheline-aligned .bss slot.

4. **Two-pass scan + copy pattern**: First pass scans for `/` without modification. If found, return original. If not, prepend prefix via `memcpy(resolved_path, bin_prefix, 5)`, append original string via `memcpy(resolved_path + 5, argv[0], len(argv[0]) + 1)` (including NUL terminator).

5. **Child-branch-only call**: resolve_path is called only in the `exec_child_do_execve` label (child process after fork). Parent path is unaffected; no overhead in dispatch/builtin handling.

## Data Layout

| Symbol | Section | Size | Notes |
|---|---|---|---|
| `bin_prefix` | .rodata | 6 B (5 + NUL) | Constant string `/bin/` |
| `resolved_path` | .bss | 320 B ([u8;320]) | Buffer for resolved path; uninit, @align(8) |

## Pseudocode

```
resolve_path():
    argv0 = argv_buf[0]
    cursor = argv0
    
    # Scan for '/'
    loop:
        byte = [cursor]
        if byte == 0:
            # No '/' found; prepend '/bin/'
            goto prepend
        if byte == '/':
            # '/' found; return argv[0] unchanged
            return argv0
        cursor++
        goto loop
    
    prepend:
        # Copy '/bin/' to resolved_path
        memcpy(resolved_path, bin_prefix, 5)
        
        # Get length of argv[0] (including NUL)
        len = strlen(argv0) + 1
        
        # Copy argv[0] to resolved_path + 5
        memcpy(resolved_path + 5, argv0, len)
        
        return &resolved_path
```

## Assembly Sketch

Register plan: r8=argv[0], r9=cursor for scan, rax=byte/return.

```asm
resolve_path:
        lea rax, [rip + argv_buf]
        mov r8, [rax]             # r8 = argv[0]
        mov r9, r8                # r9 = cursor = argv[0]

resolve_scan:
        xor rax, rax
        mov al, [r9]              # rax = [cursor] (zero-extended byte)
        and rax, 0xff             # Mitigate paideia-as #1248
        cmp rax, 0                # if byte == NUL: prepend
        je resolve_prepend
        cmp rax, 0x2F             # if byte == '/' (0x2F): as-is
        je resolve_asis
        add r9, 1
        jmp resolve_scan

resolve_asis:
        mov rax, r8               # return argv[0]
        ret

resolve_prepend:
        lea rdi, [rip + resolved_path]
        lea rsi, [rip + bin_prefix]
        mov rdx, 5
        call memcpy               # memcpy(resolved_path, bin_prefix, 5)
        
        mov rdi, r8               # rdi = argv[0]
        call strlen               # rax = len(argv[0])
        add rax, 1                # include NUL terminator
        mov rdx, rax
        
        lea rdi, [rip + resolved_path]
        add rdi, 5                # offset into resolved_path
        mov rsi, r8               # rsi = argv[0]
        call memcpy               # memcpy(resolved_path+5, argv[0], len+1)
        
        lea rax, [rip + resolved_path]
        ret
```

## `exec_child` Modification Diff

### Before (R17.M3-005):
```asm
exec_child_do_execve:
        // child: execve(argv[0], &argv_buf[0], NULL)
        lea rax, [rip + argv_buf]
        mov rdi, [rax]            # rdi = argv[0]
        lea rsi, [rip + argv_buf]
        xor rdx, rdx
        call sys_execve
```

### After (R17.M3-006):
```asm
exec_child_do_execve:
        // child: execve(resolve_path(), &argv_buf[0], NULL)
        call resolve_path         # rax = resolved path (or original argv[0])
        mov rdi, rax              # rdi = result from resolve_path
        lea rsi, [rip + argv_buf]
        xor rdx, rdx
        call sys_execve
```

### Updated exec_child justification:
Append: `+ R17-m3-006 (#626): child branch calls resolve_path to prepend /bin/ when argv[0] has no slash.`

## paideia-as Posture

Exercised and confirmed working:
- `mov al, [r9]` — byte load from memory, with `and rax, 0xff` mitigation for paideia-as #1248 (matches pattern in shell.pdx shell_read_line and tokenizer.pdx tokenize).
- `lea rdi, [rip + resolved_path]; lea rsi, [rip + bin_prefix]; mov rdx, 5; call memcpy` — lea for rodata/bss symbols, memcpy call.
- `call strlen` — reuses string.pdx symbol.
- Indexed arithmetic `add rdi, 5` after lea (offset into buffer).

**Not needed** (avoided): new paideia-as patterns; all construction exercises existing proven patterns.

## Verification

`tools/verify-user-path-resolve.sh` (new). Wired into `tools/build-user.sh` after `verify-user-exec-child.sh`. Marker: `R17 PATH RESOLVE OK`. Twelve checks:

1. `resolve_path` symbol present, size ≥ 30 bytes.
2. `resolved_path` in .bss, size 0x140 (320).
3. `bin_prefix` in .rodata, bytes `2f62696e2f` present (normalized rodata stream).
4. `resolve_path` calls `memcpy` ≥ 2 times.
5. `resolve_path` calls `strlen` ≥ 1 time.
6. `resolve_path` contains `cmp` against `0x2F`.
7. `resolve_path` contains `cmp` against `0x0`.
8. `resolve_path` contains `xor rax,rax`.
9. `resolve_path` has zero `cmp al,` instructions (#1248 hygiene).
10. `exec_child` calls `resolve_path` exactly once.
11. `exec_child` ordering: `resolve_path` call PC < `sys_execve` call PC.
12. `exec_child` has `mov rdi, rax` within ~4 instructions after `call resolve_path`.

Rodata normalizer reused from `verify-user-dispatch.sh` line ~66 (awk stream extraction).

## Smoke Test Compliance

5-mode smoke (`boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`, `boot_r12_denial`) byte-identical (no kernel changes). shell.elf grows by ~150 bytes (resolve_path body + resolved_path .bss + bin_prefix rodata); kernel.elf unchanged. No new syscall handler needed; sys_execve already covered by #625 (structurally; returns ENOSYS per #668).

## Deferred

- **Full PATH search** — Post-#626. Env var `PATH=/bin:/usr/bin` parsing, walk colon-delimited list, stat each candidate, execute first executable. Requires environment variable storage in shell .bss.
- **/usr/bin fallback** — if `/bin/<cmd>` fails with ENOENT, retry `/usr/bin/<cmd>`. Deferred until #668 (kernel execve returns error codes to userspace).
- **Executable-bit check** — stat call to verify S_IXUSR before execve. Requires sys_stat wrapper; deferred.
- **Command aliases** — shell-defined command remapping (e.g., `alias ls='ls -la'`). Post-#626; requires alias table in .bss.
- **Quoting, redirection, pipes** — R18+.
- **Signal handling** — SIGCHLD handling for background jobs, etc. Deferred.

## References

- Issue: paideia-os#625 → #626.
- Prior: #621 (skeleton), #622 (reader), #623 (tokenizer), #624 (dispatch), #625 (fork/exec).
- Feedback: `feedback_workerbee_verify_claims.md` (structural canary discipline), `feedback_cross_repo_escalation.md`, `feedback_paideia_as_reserved_labels.md` (label naming conventions).
- AC Note: Kernel dispatch.pdx issue #668 (sys_execve error handling).
- Files: `src/user/dispatch.pdx`, `src/user/shell.pdx`, `tools/verify-user-path-resolve.sh`, `tools/build-user.sh`, `design/kernel/r17-m3-006-shell-path-resolution.md`.
- Precedent: #625 (exec_child canary), shell.pdx #1248 mitigation (xor rax; mov al; and rax, 0xff pattern), tokenizer.pdx (indexed stores and byte scans).
