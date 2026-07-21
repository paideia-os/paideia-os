# R17.M3-003: shell tokenizer (#623)

## Summary

In-place tokenizer that splits `line_buf` at whitespace ({0x20 space, 0x09 tab, 0x0A newline}) into `argv_buf[16]` with an `argc` count. Function signature `tokenize(buf, byte_count) -> u64`, returning argc in `rax` and also storing it in the `argc` .bss slot. Called from `_start` after `shell_read_line` and before `dispatch_line`. Acceptance marker: `R17 TOKENIZER OK`.

## Design Intent

### Phase Scope (R17.M3-003)
- New file `src/user/tokenizer.pdx` providing `tokenize`, `argv_buf[16]`, `argc`.
- `_start` wiring updated to call `tokenize(line_buf, bytes_read)` after `shell_read_line`.
- `dispatch_line` signature unchanged this issue; #624 rewires it to consume argv/argc.

### Architectural Rationale
1. **In-place mutation**: whitespace bytes overwritten with NUL; each argv[i] is a pointer into `line_buf`. Matches Unix argv semantics, zero arena required.
2. **Fixed 16-slot argv**: sufficient for MVP shell command lines; 128 B; power of two; cheap bounds check.
3. **NUL as early terminator**: belt-and-suspenders vs. byte_count. Halts scan at first 0x00.
4. **Full-register cmp only**: uses `xor rax,rax; mov_b rax, [r8]; cmp rax, imm` pattern (already convention in `src/user/string.pdx`) — sidesteps paideia-as #1248 entirely. No `cmp al, imm8` anywhere.
5. **argc mirror in .bss**: consumers of #624 can pick up argc from either the return value or the .bss slot.

## Data Layout

| Symbol | Section | Size | Align |
|---|---|---|---|
| `argv_buf` | .bss | 128 B (`[u64; 16]`) | 8 |
| `argc`     | .bss | 8 B (`u64`)         | 8 |

Both declared `uninit @align(8)` — .bss NOLOAD, zero-initialized at load time.

## Function Signature + Register Plan

```
pub let tokenize : (u64, u64) -> u64 !{mem} @{}
```

| Reg | Role |
|---|---|
| `rdi` | in: buf pointer |
| `rsi` | in: byte_count |
| `r8`  | cursor pointer into buf |
| `r9`  | end pointer = buf + byte_count |
| `r10` | argc accumulator (0..16) |
| `r11` | scratch: address of `argv_buf` / `argc` |
| `rax` | byte load (zero-extended via `xor rax,rax; mov al,[r8]`) |
| `rcx` | scratch: zero for NUL store |

## Loop Structure

```
tokenize:
    mov r8, rdi           ; cursor
    mov r9, rdi
    add r9, rsi           ; end = buf + n
    xor r10, r10          ; argc = 0
skip_ws:
    cmp r8, r9; jge done
    cmp r10, 16; jge done
    xor rax, rax
    mov al, [r8]          ; byte load, upper bits zero
    cmp rax, 0;    je done          ; NUL terminator
    cmp rax, 0x20; je consume_ws    ; space
    cmp rax, 0x09; je consume_ws    ; tab
    cmp rax, 0x0A; je consume_ws    ; newline
    ; token start
    lea r11, [rip + argv_buf]
    mov [r11 + r10*8], r8
    add r10, 1
in_token:
    add r8, 1
    cmp r8, r9; jge done
    xor rax, rax
    mov al, [r8]
    cmp rax, 0;    je done
    cmp rax, 0x20; je terminate_token
    cmp rax, 0x09; je terminate_token
    cmp rax, 0x0A; je terminate_token
    jmp in_token
terminate_token:
    xor rcx, rcx
    mov [r8], cl          ; in-place NUL
    add r8, 1
    jmp skip_ws
consume_ws:
    add r8, 1
    jmp skip_ws
done:
    lea r11, [rip + argc]
    mov [r11], r10
    mov rax, r10
    ret
```

## Whitespace Rule

Whitespace class = {0x20 space, 0x09 tab, 0x0A newline}. NUL (0x00) is a **terminator**, not whitespace: scan halts. Every other byte is token content. Matches POSIX `IFS=" \t\n"` default modulo `\r` (not needed on QEMU serial).

## In-place Mutation Contract

`tokenize` mutates the caller-supplied buffer: whitespace bytes at token boundaries are overwritten with 0x00 so that each `argv_buf[i]` becomes a C-string pointer. Callers must treat `line_buf` as clobbered after `tokenize` returns. On the next iteration of the shell main loop, `shell_read_line` overwrites `line_buf` from offset 0, invalidating all argv pointers — this is by design; #624's dispatch runs before the next read.

## Hook Point (shell.pdx `_start`)

**Before:**
```
lea rdi, [rip + line_buf];
mov rsi, rax;              ; bytes_read
call dispatch_line;
```

**After:**
```
mov rsi, rax;              ; rsi = bytes_read (2nd arg)
lea rdi, [rip + line_buf];
call tokenize;             ; sets argc slot, returns argc in rax
lea rdi, [rip + line_buf];
mov rsi, rax;              ; rsi = argc (stub ignores)
call dispatch_line;        ; #623 dispatch signature unchanged; #624 rewires
```

Keeps the existing `call dispatch_line` marker in `_start` so #621 verifier check remains valid.

## paideia-as #1248 Guards

#1248: `cmp al, imm8` emits as REX.W `cmp rax, imm8` — full-register compare against garbage upper bits. Mitigation everywhere in tokenize: use `xor rax,rax; mov al, [r8]` followed by `cmp rax, imm` — full-register compare against a value with provably zero upper bits. No byte-narrow cmp appears in the tokenize body.

The verifier check 10 enforces this: it fails if any `cmp al,` appears, and requires `xor rax,rax` to be present in the tokenize body.

## Verification

`tools/verify-user-tokenizer.sh` (new). Wired into `tools/build-user.sh` after `verify-user-shell.sh`. Marker: `R17 TOKENIZER OK`. Ten checks:

1. `argv_buf` symbol in `.bss`, size 0x80.
2. `argc` symbol in `.bss`, size 0x8.
3. `tokenize` function symbol present.
4. `cmp rax, 0x20` present in tokenize disassembly.
5. `cmp rax, 0x9` present (objdump prints `0x9`, not `0x09`).
6. `cmp rax, 0xa` present.
7. In-place NUL store: `mov BYTE PTR [...], 0x0` OR `mov [...], cl`/`al`/`bl`/`dl`.
8. Indexed argv_buf store using `*8` scaling.
9. `_start` calls in order: `shell_read_line` → `tokenize` → `dispatch_line`.
10. No `cmp al,` byte-narrow compares; `xor rax,rax` zero-extend present (#1248 hygiene).

## Smoke Test Compliance

5-mode smoke (`boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`, `boot_r12_denial`) byte-identically green. `shell.elf` is not linked into `kernel.elf`, so it cannot touch kernel fingerprints.

## Deferred

- #624 `builtin_dispatch`: rewire `dispatch_line` signature to `(argc, argv_ptr) -> u64`; walk a builtin table (echo, exit, pwd, cd, help, env); fall through to fork+exec on miss.
- Quoting, escape sequences, redirection, pipes — out of scope for R17.M3; deferred to a later shell milestone.

## References

- Issue: paideia-os#623.
- Prior: paideia-os#621 (skeleton), #622 (line reader).
- Next: paideia-os#624 (builtin dispatch), #625 (fork/exec_child).
- Upstream mitigated: paideia-as#1248.
- Files: `src/user/tokenizer.pdx`, `src/user/shell.pdx`, `tools/verify-user-tokenizer.sh`, `tools/build-user.sh`.
