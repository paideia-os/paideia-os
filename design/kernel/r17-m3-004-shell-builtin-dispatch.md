# R17.M3-004: shell builtin dispatch (#624)

## Summary

New `src/user/dispatch.pdx` provides a builtin table (name→handler) walked by `dispatch_line() -> u64` at each shell iteration. Two builtins ship live: `echo` (space-separated argv[1..argc] + newline) and `exit` (sys_exit(0)). Table is runtime-populated by `dispatch_init()` (paideia-as does not support address-of-symbol data initializers), called once from `_start` before the main loop. Indirect handler dispatch uses `call rax` with SysV alignment pad. Marker: `R17 DISPATCH OK`.

## Design Intent

### Phase Scope (R17.M3-004)
- New module: `Dispatch` with 4 functions (`dispatch_init`, `dispatch_line`, `echo_builtin`, `exit_builtin`).
- Two builtins ship as real functional bodies (no stubs — repo discipline).
- Table capacity = 2; extensible to 8–16 by growing `[u64; N]` and adding rows in `dispatch_init`.
- `_start` wiring: `call dispatch_init` prologue + drop args to `dispatch_line`.
- Old `dispatch_line` stub in `shell.pdx` is deleted; new definition lives in `dispatch.pdx`.

### Signature Discipline
- `dispatch_line() -> u64` — reads argc / argv_buf from Tokenizer .bss; returns 0 on hit, 1 on miss (miss reserved for #625 fork+exec fallback).
- `dispatch_init() -> ()` — idempotent runtime table load.
- Handlers: `fn () -> u64` — read argv/argc from .bss; uniform contract.

### Architectural Rationale
1. **Runtime table population**: paideia-as has no address-of-symbol data initializer construct. Matches kernel precedent (`_path_witness_vops_table` at `src/kernel/core/fs/path.pdx:224` — declared `uninit`, populated at runtime via `lea rax, [rip + handler]; mov [rdi+off], rax`).
2. **Table over unrolled if-chain**: adding a builtin becomes 1 rodata name + 2 mov entries in `dispatch_init` — zero branch weaving.
3. **`call rax` with alignment pad**: precedent `src/kernel/core/fs/vops.pdx:79`. SysV requires `(rsp+8)%16==0` at callee entry; dispatcher entry is already at `%16==8`, so raw `call rax` would deliver `%16==0` — ABI violation. `sub rsp,8; call rax; add rsp,8` restores alignment.
4. **Reads .bss, not params**: eliminates arg-marshalling at every `_start` call site; keeps handler contract uniform.
5. **Real echo + exit**: per `feedback_workerbee_verify_claims.md` — bodies are functional. `exit` uses SC+ ID 60 (`sys_exit`), not legacy `sys_exit_thread`.

## Data Layout

| Symbol | Section | Size | Notes |
|---|---|---|---|
| `echo_name` | .rodata | 5 B | "echo\0" |
| `exit_name` | .rodata | 5 B | "exit\0" |
| `sp_char`   | .rodata | 1 B | " "     |
| `nl_char`   | .rodata | 1 B | "\n"    |
| `builtin_names`    | .bss | 16 B (`[u64;2]`) | uninit @align(8) — populated at runtime |
| `builtin_handlers` | .bss | 16 B (`[u64;2]`) | uninit @align(8) |
| `builtin_count`    | .bss | 8 B (`u64`)      | uninit @align(8), set to 2 |

## `dispatch_init` (runtime table load)

```
lea rdi, [rip + builtin_names]
lea rax, [rip + echo_name];    mov [rdi + 0], rax
lea rax, [rip + exit_name];    mov [rdi + 8], rax
lea rdi, [rip + builtin_handlers]
lea rax, [rip + echo_builtin]; mov [rdi + 0], rax
lea rax, [rip + exit_builtin]; mov [rdi + 8], rax
lea rdi, [rip + builtin_count]
mov rax, 2;                    mov [rdi], rax
ret
```

## `dispatch_line` (table walker)

Register plan — r9/r10/r11 hold state across `strlen`/`memcmp` calls because both preserve r9–r15 (per their justifications):

- r9  = argv[0] pointer
- r10 = strlen(argv[0]) cached
- r11 = loop index i

```
dispatch_line:
    ; empty line → not-found
    lea rax, [rip + argc]; mov rax, [rax]
    cmp rax, 0; je dispatch_notfound

    ; r9 = argv[0]
    lea rax, [rip + argv_buf]; mov r9, [rax]

    ; r10 = strlen(argv[0])
    mov rdi, r9; call strlen; mov r10, rax

    xor r11, r11
dispatch_loop:
    lea rax, [rip + builtin_count]; mov rax, [rax]
    cmp r11, rax; jge dispatch_notfound

    ; strlen(names[i])
    lea rax, [rip + builtin_names]
    mov rdi, [rax + r11*8]
    call strlen
    cmp rax, r10; jne dispatch_next   ; length mismatch → skip

    ; memcmp(argv[0], names[i], r10)
    mov rdi, r9
    lea rax, [rip + builtin_names]
    mov rsi, [rax + r11*8]
    mov rdx, r10
    call memcmp
    cmp rax, 0; jne dispatch_next

    ; MATCH — indirect call handlers[i] with alignment pad
    lea rax, [rip + builtin_handlers]
    mov rax, [rax + r11*8]
    sub rsp, 8
    call rax
    add rsp, 8
    xor rax, rax; ret                 ; 0 = handled

dispatch_next:
    add r11, 1; jmp dispatch_loop

dispatch_notfound:
    mov rax, 1; ret                   ; 1 = miss (#625 fork+exec)
```

## `echo_builtin`

Emits `argv[1..argc]` space-separated + trailing newline. r9 = i, r10 = argc cached.

```
lea rax, [rip + argc]; mov r10, [rax]
mov r9, 1                        ; skip argv[0]
echo_loop:
    cmp r9, r10; jge echo_nl
    cmp r9, 1;   je  echo_arg    ; no leading space before first arg
    mov rdi, 1
    lea rsi, [rip + sp_char]
    mov rdx, 1
    call sys_write
echo_arg:
    lea rax, [rip + argv_buf]
    mov rdi, [rax + r9*8]
    call strlen
    mov rdx, rax
    mov rdi, 1
    lea rax, [rip + argv_buf]
    mov rsi, [rax + r9*8]
    call sys_write
    add r9, 1; jmp echo_loop
echo_nl:
    mov rdi, 1
    lea rsi, [rip + nl_char]
    mov rdx, 1
    call sys_write
    xor rax, rax; ret
```

## `exit_builtin`

```
xor rdi, rdi        ; status = 0
call sys_exit       ; SC+ ID 60 — canonical exit; never returns
hlt                 ; unreachable fallback
```

Uses `sys_exit` (SC+ ID 60), NOT R13 legacy `sys_exit_thread`.

## `shell.pdx _start` diff

- Delete old stub `dispatch_line` definition (was `xor rax, rax; ret`).
- Add `call dispatch_init;` at `_start` prologue, before `main_loop:` label.
- Delete the two arg-marshalling lines (`lea rdi, [rip + line_buf]; mov rsi, rax;`) that preceded `call dispatch_line`. Keep the `call dispatch_line` line itself so the tokenizer verifier's call-order check remains valid.

## paideia-as Posture

Exercised and confirmed working:
- `call rax` (indirect) — supported (vops.pdx pattern).
- `mov [rdi+imm8], rax` — supported.
- `mov [rax + reg*8], reg` — supported (tokenizer.pdx precedent).
- `sub rsp, imm8` / `add rsp, imm8` — supported.
- `lea reg, [rip + symbol]` — pervasive.

Encoder gotcha discovered during implementation: the label name `loop` (as an assembly label like `loop:`) collides with a paideia-as reserved keyword and fails to parse. Renamed to `dispatch_loop:` and `echo_loop:` — convention followed elsewhere in the codebase (`strlen_loop`, `memcmp_loop`, `read_loop`).

**Not needed** (avoided): address-of-symbol data-initializer literals (routed through `dispatch_init` runtime population); `jmp reg64` tail-call.

## Verification

`tools/verify-user-dispatch.sh` (new). Wired into `tools/build-user.sh` after `verify-user-tokenizer.sh`. Marker: `R17 DISPATCH OK`. Twenty checks:

1. `dispatch_line` symbol present, size > 40 bytes.
2. `dispatch_init` symbol present, size > 20 bytes.
3. `echo_builtin` symbol present, size > 20 bytes.
4. `exit_builtin` symbol present.
5. `echo_name` bytes 65 63 68 6f 00 in .rodata.
6. `exit_name` bytes 65 78 69 74 00 in .rodata.
7. `builtin_names` in .bss, size 0x10.
8. `builtin_handlers` in .bss, size 0x10.
9. `builtin_count` in .bss, size 0x8.
10. `dispatch_line` calls `strlen` ≥ 2 times.
11. `dispatch_line` calls `memcmp` ≥ 1 time.
12. `dispatch_line` has indirect call (`call rax` or `call QWORD PTR`).
13. `dispatch_line` has SysV alignment pad (`sub rsp,0x8` + `add rsp,0x8`).
14. `dispatch_line` has backward jmp (loop).
15. `echo_builtin` calls `sys_write` ≥ 3 times.
16. `echo_builtin` calls `strlen` ≥ 1 time.
17. `exit_builtin` calls `sys_exit` (canonical SC+ ID 60), NOT `sys_exit_thread`.
18. `_start` calls `dispatch_init` exactly once.
19. `dispatch_init` call PC in `_start` < first `shell_read_line` call PC.
20. #1248 hygiene: no `cmp al,` in any dispatch-emitted function.

## Smoke Test Compliance

5-mode smoke (`boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`, `boot_r12_denial`) stays byte-identical. `shell.elf` is not linked into `kernel.elf` — `init` will `sys_execve` it at runtime.

## Deferred

- **#625 fork+exec fallback**: `dispatch_line` rax=1 return triggers `_start` to search `/bin` for a named binary, execve, wait.
- **More builtins** (`pwd`, `cd`, `help`, `env`): 1 rodata name + 2 lines in `dispatch_init` each; grow `[u64;2]` to `[u64;8]`.
- **`exit N` decimal arg parsing**: needs digit parser; post-#625.
- **Quoting, redirection, pipes**: R18+.

## References

- Issue: paideia-os#623 → #624 → #625.
- Prior: #621 (skeleton), #622 (reader), #623 (tokenizer).
- Feedback: `feedback_workerbee_verify_claims.md` (real bodies, no stubs).
- Cross-repo: `feedback_cross_repo_escalation.md` (escalation pattern for paideia-as gaps).
- Files: `src/user/dispatch.pdx`, `src/user/shell.pdx`, `tools/verify-user-dispatch.sh`, `tools/build-user.sh`.
- Precedent: `src/kernel/core/fs/vops.pdx` (call rax + SysV pad), `src/kernel/core/fs/path.pdx:224` (runtime table population).
