# R17.M3-001: shell main loop skeleton (#621)

## Summary

Establishes interactive shell main loop structure: prompt emission, line reading, command dispatch (stub), and loop. Builds as structural canary; hangs on first read (awaiting real kernel I/O support, deferred to #665/#668). Acceptance: "R17 SHELL SKELETON OK" from verifier.

## Design Intent

### Phase Scope (R17.M3)
- Structural: main loop skeleton inline in shell._start
- No new syscalls (puts_new, getline, builtin_exit already in R17.M1 + R17.M2)
- Verify prompt_msg rodata, line_buf .bss, function call sequences
- Stub dispatch_line for now (real command dispatch in #624)
- Shell hangs on getline (intended — blocks waiting for kernel read I/O)

### Architectural Rationale
1. **Loop structure**: Establish prompt → read → dispatch → loop pattern
2. **Line buffering**: 256-byte stack buffer for user input
3. **EOF handling**: Detect Ctrl-D (0 bytes read) → sys_exit
4. **Dispatch staging**: Stub dispatch_line returns 0; real implementation in #624
5. **Build canary**: Verifies loop instructions and rodata/bss placement

## Implementation

### Rodata (shell.pdx §1)
```
pub let prompt_msg : [u8; 3] = "$ \0"
pub let prompt_len : u64 = 2
```

Added: simple 2-byte prompt + NUL terminator.

### BSS (shell.pdx §2)
```
pub let line_buf : [u8; 256] = [0u8; 256]
```

Added: 256-byte input buffer (standard shell line length).

### Main Loop (shell.pdx §3: _start)

**Pseudocode**:
```
main_loop:
  lea rdi, [rip + prompt_msg];
  call puts_new;                       // emit "$ "

  lea rdi, [rip + line_buf];
  mov rsi, 256;
  call getline;                        // read up to 256 bytes into line_buf

  cmp rax, 0;                          // test if bytes_read == 0
  je exit_on_eof;                      // branch if EOF (Ctrl-D)

  lea rdi, [rip + line_buf];
  mov rsi, rax;
  call dispatch_line;                  // stub: returns 0 (real dispatch in #624)

  jmp main_loop;                       // loop forever

exit_on_eof:
  mov rdi, 0;
  call builtin_exit;                   // sys_exit_thread(0)

  ret                                  // unreachable
```

**Flow**:
1. Emit prompt via puts_new
2. Read line via getline (hangs here until kernel I/O available)
3. Test for EOF (0 bytes returned → user hit Ctrl-D)
4. Dispatch to command handler (stub version)
5. Repeat

**Byte Impact**: ~60 LOC in _start (prompt, getline, dispatch, loop structure, EOF exit).

### Dispatch Stub (shell.pdx §4: dispatch_line)

```rust
pub let dispatch_line : (u64, u64) -> u64 !{mem, sysreg} @{fs} =
  fn (buf: u64) (len: u64) -> unsafe {
    block: {
      xor rax, rax;       // return 0 (ignored)
      ret
    }
  }
```

**Purpose**: Accept buf pointer and line length; return 0. Real implementation (parsing, command execution) deferred to #624.

## Verification (tools/verify-user-shell.sh)

Checks:
- prompt_msg rodata symbol exists
- line_buf .bss symbol exists AND is in .bss (not .rodata/.data)
- call puts_new in _start (prompt emission)
- call getline in _start (line reading)
- call dispatch_line in _start (command dispatch)
- jmp instruction in _start (loop structure)
- cmp + je in _start (EOF branch)

**Exit marker**: "R17 SHELL SKELETON OK" (pass) / "R17 SHELL SKELETON FAIL" (fail).

**Append to build-user.sh**: After verify-libc-test.sh, invoke verify-user-shell.sh on shell.elf.

## Behavior at Runtime

When the shell binary is loaded and executed by init (via sys_execve, deferred to #620):

1. Shell._start emits "$ " to stdout (fd 1, connected to /dev/tty0)
2. Shell calls getline(line_buf, 256)
3. getline calls sys_read(0, line_buf, 256) — **blocks here**
4. Kernel's tty_read is called, which is currently a stub returning EAGAIN (non-blocking mode)
   - Actual cooked-mode I/O (line buffering, echo, backspace handling) is in #665
   - Multicore I/O event loop is in #668
5. Shell hangs in sys_read (expected behavior for R17.M3)

Once #665/#668 are complete:
- User types "ls\n" on the tty console
- Kernel's tty_read returns 3 bytes (l, s, \n)
- getline returns 3
- Shell calls dispatch_line(line_buf, 3)
- dispatch_line currently returns 0 (no-op) — real command parsing in #624
- Shell loops back to emit next prompt

## Smoke Test Compliance

5-mode smoke (`tools/run-smoke.sh`) must remain byte-identical:
- Shell binary not loaded into kernel.elf yet (init loads it via sys_execve in #620)
- Smoke fingerprints are for kernel only, not shell binary
- No change to kernel smoke baseline

## Ground Rules Checklist

✓ Deliver "R17 SHELL SKELETON OK" from verifier (tools/verify-user-shell.sh)  
✓ Extend shell.pdx with main loop (prompt, getline, dispatch_line stub, loop)  
✓ Create verify-user-shell.sh with byte-pattern and call-site checks  
✓ Append to build-user.sh (post verify-libc-test, pre final echo)  
✓ Include this design doc  
✓ Build + verify + smoke (byte-identical)  
✓ Commit + verify git log origin/main..HEAD empty  

## Acceptance Test (R17.M3-001)

Run:
```bash
cargo build --release -p paideia-os
tools/verify-user-shell.sh build/user/shell.elf
tools/run-smoke.sh boot_r17_init
```

Expected:
- build-user.sh completes: "[ok] build/user/shell.elf"
- Verifier: "R17 SHELL SKELETON OK"
- Smoke: boot_r17_init mode passes, kernel output unchanged

## Deferred (R17.M3 → #624 dispatch)

- Real command parsing (tokenization, quoting)
- Builtin command implementations (cd, exit, help)
- External command execution (find .bin in /bin, fork, execve)
- Environment variables and PATH search
- Signal handling (Ctrl-C, Ctrl-Z)
- Job control
- Redirection and pipes

## Deferred (R17.M3 → #665/#668 I/O)

- Cooked-mode TTY input (echo, backspace, line discipline)
- Non-blocking I/O event loop in kernel
- Integration with shell's getline

## References

- R17.M1-005 (#614): puts_new, getline I/O helpers
- R17.M2-001 (#616): ring-3 user program launch
- R17.M2-003 (#618): init fork_exec_shell (shell loading)
- R17.M3-001 (#621): this document — shell main loop
- design/kernel/r17-m1-005-user-io.md: puts_new, getline design
- design/terminal/semantic-shell.md: shell architecture overview
- src/user/shell.pdx: main loop implementation
- src/user/io.pdx: puts_new, getline functions
- tools/verify-user-shell.sh: verification script
