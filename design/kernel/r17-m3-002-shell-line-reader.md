# R17.M3-002: shell line reader (#622)

## Summary

Extends the shell main loop skeleton (R17.M3-001) with a proper line reader: `shell_read_line(buf, sz) -> u64` reads bytes from stdin (fd 0) one at a time via `sys_read(0, buf, 1)` in a loop, stopping when a newline (0x0A), EOF (sys_read returns 0), or buffer full (sz bytes accumulated) is encountered. Acceptance: "R17 SHELL READER OK" from verifier.

## Design Intent

### Phase Scope (R17.M3-002)
- Extend shell._start to call shell_read_line instead of the generic getline
- Byte-by-byte reading loop with explicit newline detection (0x0A)
- Return total bytes read (including the newline byte if present)
- Verify loop structure, syscall pattern, and newline cmp instruction via verifier
- Shell hangs on sys_read (intended — blocks waiting for kernel I/O)

### Architectural Rationale
1. **Byte-by-byte semantics**: Unlike getline (which reads up to sz bytes in one go), shell_read_line reads a single byte per sys_read call and checks for line termination
2. **Newline detection**: Explicitly compares each byte against 0x0A (\n) to stop at line boundaries
3. **EOF handling**: When sys_read returns ≤ 0, the loop exits, signaling end-of-file
4. **Buffer boundaries**: Loop checks `rcx >= sz` to prevent overflow into line_buf
5. **Build canary**: Verifies sys_read pattern, newline cmp instruction, and loop structure

## Implementation

### Function Signature (shell.pdx §5: shell_read_line)

```rust
pub let shell_read_line : (u64, u64) -> u64 !{mem, sysreg} @{fs} =
  fn (buf: u64) (sz: u64) -> unsafe { ... }
```

**Arguments**:
- `rdi` (buf): pointer to input buffer
- `rsi` (sz): maximum bytes to read

**Returns**:
- `rax`: total bytes read (including newline if encountered, or 0 if EOF at entry)

### Loop Structure (shell.pdx §5: shell_read_line body)

**Pseudocode**:
```asm
xor rcx, rcx;               // rcx = bytes_read counter (0)
mov r8, rdi;                // r8 = current buffer pointer (starts at buf)
mov r9, rsi;                // r9 = max size (sz)

read_loop:
  cmp rcx, r9;              // if rcx >= sz: break (buffer full)
  jge read_done;

  mov rdi, 0;               // rdi = fd (stdin)
  mov rsi, r8;              // rsi = current buffer pointer
  mov rdx, 1;               // rdx = count (1 byte)
  call sys_read;            // sys_read(0, r8, 1) → rax = bytes read (1, 0, or -errno)

  cmp rax, 0;               // if rax <= 0: EOF or error
  jle read_done;

  inc rcx;                  // rcx++ (increment counter)
  mov al, [r8];             // al = byte we just read
  inc r8;                   // r8++ (move buffer pointer forward)

  cmp al, 0x0A;             // if byte == 0x0A (newline): break
  je read_done;

  jmp read_loop;            // loop

read_done:
  mov rax, rcx;             // return bytes_read in rax
  ret
```

**Flow**:
1. Initialize counter (rcx = 0), buffer pointer (r8), max size (r9)
2. Loop:
   - Check if buffer is full (rcx >= sz)
   - Call sys_read(0, r8, 1) to read one byte
   - If sys_read returns ≤ 0 (EOF), exit loop
   - Increment counter and buffer pointer
   - Load the byte we just read into al
   - Compare al against 0x0A (newline)
   - If newline, exit loop; otherwise continue
3. Return total bytes read in rax

**Byte Impact**: ~45 LOC in shell_read_line function body.

### Updated _start (shell.pdx §6: _start)

**Change**: Replace `call getline` with `call shell_read_line`.

```asm
main_loop:
  lea rdi, [rip + prompt_msg];
  call puts_new;

  lea rdi, [rip + line_buf];
  mov rsi, 256;
  call shell_read_line;           // (was: call getline)

  cmp rax, 0;
  je exit_on_eof;

  lea rdi, [rip + line_buf];
  mov rsi, rax;
  call dispatch_line;

  jmp main_loop;

exit_on_eof:
  mov rdi, 0;
  call builtin_exit;

  ret
```

**Impact**: ~1 line changed (getline → shell_read_line); flow unchanged.

## Verification (tools/verify-user-shell.sh)

**Updated marker**: "R17 SHELL READER OK" (pass) / "R17 SHELL READER FAIL" (fail).

**New checks** (in addition to R17.M3-001 checks):
- `call shell_read_line` in _start (replaces getline check)
- shell_read_line function exists
- `call sys_read` in shell_read_line function body (byte-by-byte reading)
- `cmp` instruction against 0x0A in shell_read_line (newline detection)

**Removed checks**:
- `call getline` in _start (replaced by shell_read_line)

**Kept checks**:
- prompt_msg rodata symbol
- line_buf .bss symbol
- call puts_new in _start (prompt)
- call dispatch_line in _start (dispatch)
- jmp in _start (loop)
- cmp+je in _start (EOF branch)

**Example objdump pattern**:
```
0x401234 <shell_read_line>:
  ...
  xor    rcx,rcx                      # counter = 0
  mov    r8,rdi                       # r8 = buf
  ...
  cmp    rcx,r9                       # buffer full check
  jge    401288                       # exit if full
  ...
  mov    rdi,0x0                      # fd = 0 (stdin)
  mov    rsi,r8                       # buf pointer
  mov    rdx,0x1                      # count = 1
  call   401100 <sys_read>            # read one byte
  cmp    rax,0x0                      # EOF check
  jle    401288                       # exit if EOF
  ...
  mov    al,BYTE PTR [r8]             # load byte
  cmp    al,0xa                       # newline check (← key pattern)
  je     401288                       # exit if newline
  jmp    401250 <read_loop>           # back to loop
```

## Behavior at Runtime

When the shell is executed:

1. Shell._start emits "$ " to stdout
2. Shell calls shell_read_line(line_buf, 256)
3. shell_read_line enters read_loop, calls sys_read(0, current_ptr, 1) **blocks here**
4. Kernel's tty_read stub returns EAGAIN or blocks (depending on implementation)
5. Once kernel I/O (#665/#668) is ready:
   - User types "ls\n" on console
   - Each character arrives as a separate sys_read return (1 byte at a time in the loop)
   - After 'l' (0x6C): not 0x0A, continue loop
   - After 's' (0x73): not 0x0A, continue loop
   - After '\n' (0x0A): **matches cmp al, 0x0A**, exit loop
   - shell_read_line returns 3 (bytes read: l, s, \n)
6. Shell calls dispatch_line(line_buf, 3)
7. dispatch_line returns 0 (stub — real parsing in #624)
8. Shell loops back to emit next prompt

**Key Semantic Difference from getline**: The generic getline does not stop at '\n'; it reads up to sz bytes or EOF. shell_read_line explicitly checks for '\n' and stops there, making it suitable for line-oriented input.

## Smoke Test Compliance

5-mode smoke (`tools/run-smoke.sh`) must remain byte-identical:
- Shell binary still not linked into kernel.elf (init loads it via execve in #620)
- Kernel smoke fingerprints unchanged
- Build artifact changes are limited to shell.elf (not tested in smoke)

## Ground Rules Checklist

✓ Deliver "R17 SHELL READER OK" from verifier (tools/verify-user-shell.sh)  
✓ Extend src/user/shell.pdx: add shell_read_line function, update _start to call it  
✓ Update verifier script: check for shell_read_line call, sys_read in function, cmp 0x0A pattern  
✓ Include this design doc (design/kernel/r17-m3-002-shell-line-reader.md)  
✓ Build + verify + smoke (byte-identical)  
✓ Commit + verify git log origin/main..HEAD empty  

## Acceptance Test (R17.M3-002)

Run:
```bash
cargo build --release -p paideia-os
tools/verify-user-shell.sh build/user/shell.elf
tools/run-smoke.sh boot_r17_init
```

Expected:
- build-user.sh completes: "[ok] build/user/shell.elf"
- Verifier: "R17 SHELL READER OK"
- Smoke: boot_r17_init mode passes, kernel output unchanged

## Design Trade-offs

### Byte-by-byte vs. Single sys_read

**Chosen**: Byte-by-byte loop (shell_read_line)
- **Pro**: Explicit newline detection (0x0A); semantically clearer intent
- **Pro**: Testable via verifier (syscall pattern + cmp instruction)
- **Con**: More syscalls (~3 for "ls\n" vs. 1 for getline); higher overhead under cooked-mode TTY
- **Con**: Assumes kernel can handle rapid short reads without deadlock

**Alternative**: Single sys_read(0, buf, sz) followed by strchr(buf, '\n')
- **Pro**: Fewer syscalls; simpler kernel interface
- **Con**: Requires second pass (strchr) to find line length
- **Con**: getline already does this; defeats purpose of #622 (distinct line reader)

**Decision**: Byte-by-byte loop is semantically correct for a line reader and verifiable. Once cooked-mode TTY (#665) is in place, the kernel can buffer multiple bytes and return them in a single sys_read, reducing syscall overhead while preserving the byte-by-byte loop semantics in userspace.

## Deferred (R17.M3 → #624 dispatch)

- Command parsing and execution in dispatch_line
- Builtin commands (cd, exit, help)
- External command fork/exec
- Environment variables, PATH search

## Deferred (R17.M3 → #665/#668 I/O)

- Cooked-mode TTY (echo, backspace, line discipline)
- Non-blocking I/O event loop in kernel
- Kernel buffering for efficient batch reads

## Addendum 2026-07-20: #1248 Mitigation

**Issue**: paideia-as #1248 incorrectly emits `cmp al, imm8` as `cmp rax, imm8` with REX.W flag (full-register compare). This bypasses the intent of `al`-only register operations. In `shell_read_line`, the `cmp al, 0x0A` instruction currently passes only because `sys_read` leaves `rax ∈ {0, 1}` and upper bits happen to be zero. Future edits touching `rax` between `sys_read` and the `cmp` would silently corrupt EOF/newline detection.

**Mitigation**: Insert `and rax, 0xff` immediately after `mov al, [r8]` and before `cmp al, 0x0A` to explicitly zero upper bits, making the byte-width intent explicit to the assembler and robust to future changes.

**Verification Tightening**: `tools/verify-user-shell.sh` now checks that any `cmp .*, 0xa` in `shell_read_line` is preceded by one of:
- `and rax, 0xff` (explicit mitigation) — preferred
- `movzx eax, al` (zero-extension) — acceptable alternative
- Byte-narrow opcode `3c 0a` (assembler chose correct form) — acceptable alternative

If none are found, the verifier emits `[WARN]` and fails the check, surfacing the #1248 risk.

**Impact**: ~1 instruction added to `shell_read_line` loop body (no functional change; improves robustness until paideia-as #1248 is fixed upstream).

## References

- R17.M3-001 (#621): shell main loop skeleton
- R17.M1-001 (#610): syscall shim (sys_read definition)
- R17.M1-005 (#614): user I/O helpers (getline design)
- design/kernel/r17-m3-001-shell-main-loop.md: shell skeleton design
- design/user/syscall-table.md: SC+ frozen syscall enumeration
- src/user/shell.pdx: shell implementation
- src/user/syscall_shim.pdx: sys_read syscall wrapper
- tools/verify-user-shell.sh: verification script
- paideia-as issue #1248: cmp al, imm8 incorrectly emitted with REX.W
