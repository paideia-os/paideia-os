# R17.M0 #668 — SC+ freeze alignment of kernel syscall dispatch

**Status**: Complete (R17.M0)  
**Phase**: R17.M0  
**Issue**: #668  
**Related**: #587–#591, #553–#558, #671

---

## 1. Overview

#668 wires the kernel's syscall dispatcher to the R16-M3 real handler bodies, completing the SC+ (Synchronized Commit) freeze alignment. The dispatcher had been routing all syscalls except ID 1 (write) to ENOSYS stubs; this issue bridges that gap by connecting the dispatch table to the actual implementation bodies that ship with #587–#591 and #553–#558.

### Scope
- Wire IDs {0, 2, 3, 32, 39, 56, 60, 61} to their real bodies
- ID 1 (write) preserves fd∈{1,2}→UART fast-path until R17.M2 Tier-2 unlocks TTY device I/O
- ID 59 (execve) remains ENOSYS with a TODO comment marking the deferral point (#671)
- ID 4 (cap_invoke) and ID 12 (debug_puts) unchanged

### Dependencies
- **R16-M3**: syscall handler bodies (#587–#591) for read/write/open/close/dup2
- **R15-M6**: syscall handler bodies (#553–#558) for fork/exit/wait4
- **R15-M4**: dispatch infrastructure (entry/exit/trampoline)
- **Upstream**: paideia-as encoder support for symbol references in inline assembly

---

## 2. Architecture

### 2.1 Dispatch Table Structure

The dispatcher is a linear `cmp/je` chain over syscall IDs (per R13 preflight §C design), structured as:

```
syscall_dispatch:
  [bounds check: cmp rdi, 61; ja dispatch_enosys]
  [cmp/je table for IDs 0, 1, 2, 3, 4, 12, 32, 39, 56, 59, 60, 61]
  [dispatch_* labels with handler bodies]
```

### 2.2 Handler Calling Convention

All handler stanzas follow this pattern:

1. Load `_current_tcb` from RIP-relative symbol (stored in runqueue.pdx)
2. Move pointer to RDI as the first argument (`current` task_struct*)
3. SysV args (RSI, RDX, RCX) remain positioned as-is by the caller
4. Call the handler body (e.g., `sys_read_body`)
5. Return via `ret` (or special halt loop for exit)

**Example**: ID 0 (read)
```asm
dispatch_read:
    mov rax, [rip + _current_tcb]
    mov rdi, rax                    ; arg0 = current
    ; rsi=fd, rdx=buf, rcx=len — already positioned by SysV
    call sys_read_body
    ret
```

### 2.3 Per-ID Routing

| ID  | Name      | Handler                                  | Notes                                         |
|-----|-----------|------------------------------------------|-----------------------------------------------|
| 0   | read      | `sys_read_body` (4-arg)                  | Validates fd ∈ [3,32); decodes; vfs_read     |
| 1   | write     | Fast-path fd∈{1,2}→UART; else sys_write_body | Preserves TTY fallback until R17.M2         |
| 2   | open      | `sys_open_body` (4-arg)                  | vfs_open + fd_alloc + fd_set                  |
| 3   | close     | `sys_close_body` (2-arg)                 | Validates fd; vfs_close; fd_set(0)            |
| 4   | cap_invoke| `cap_invoke` (unchanged)                 | Tail-call after rsi/rdx shuffle               |
| 12  | debug_puts| `uart_puts` (unchanged)                  | Echo msg_len; no change from R15-M4           |
| 32  | dup2      | `sys_dup2_body` (3-arg)                  | Dual-fd validate; copy; conditional close    |
| 39  | getpid    | Inline from _current_tcb @ TASK_OFF_PID=0| No call; u32 zero-extends into rax           |
| 56  | fork      | `sys_fork_body` (1-arg)                  | task_new + aspace_clone_cow + fd_copy       |
| 59  | execve    | → dispatch_enosys (ENOSYS)               | TODO: path→image vfs_open+read shim (#671)  |
| 60  | exit      | `sys_exit_body` (1-arg); then halt       | Never returns; halt loop after body          |
| 61  | wait4     | `sys_wait_body` (1-arg); writeback wstatus| Shim for wstatus pointer copy-out            |

### 2.4 Special Patterns

#### Write (ID 1) — Fast-Path + Body

For backward compatibility with init bootstrap (which writes to stdout/stderr before TTY fds open), write uses a dual dispatch:

```asm
dispatch_write:
    cmp rsi, 1; je dispatch_write_uart
    cmp rsi, 2; je dispatch_write_uart
    ; Real body for fd >= 3
    mov rax, [rip + _current_tcb]
    mov rdi, rax
    call sys_write_body
    ret

dispatch_write_uart:
    ; UART byte-loop (r12=buf, r13=len)
    ; returns count in rax on success
```

The UART fast-path bypasses fd_table validation and writes directly to COM1 serial. fd≥3 routes to `sys_write_body` which enforces the fd_table contract.

#### Exit (ID 60) — Halt Loop

Unlike other handlers, exit never returns:

```asm
dispatch_exit:
    mov rax, [rip + _current_tcb]
    mov rdi, rax
    call sys_exit_body
    jmp dispatch_exit_halt
dispatch_exit_halt:
    hlt
    jmp dispatch_exit_halt
```

After `sys_exit_body` completes (marking the task ZOMBIE and potentially waking the parent), control never returns to userland. The halt loop prevents any further instruction fetch.

#### Wait4 (ID 61) — Wstatus Writeback Shim

Bridges the userland ABI (wstatus pointer at RSI) to the body's return convention (status in RDX):

```asm
dispatch_wait4:
    mov rax, [rip + _current_tcb]
    mov rdi, rax
    push rsi                         ; save wstatus user ptr across call
    call sys_wait_body               ; returns pid in rax, status in rdx
    pop rsi                          ; restore wstatus ptr
    test rsi, rsi
    jz dispatch_wait4_done
    mov [rsi], edx                   ; write 4-byte status
dispatch_wait4_done:
    ret
```

Stack alignment via `push/pop rsi` (1 push = 8 bytes) ensures RSP%16==0 at the body call.

#### Getpid (ID 39) — Inline

No nested call needed:

```asm
dispatch_getpid:
    mov rax, [rip + _current_tcb]
    mov eax, [rax + 0]               ; TASK_OFF_PID = 0 (u32)
    ret
```

The u32 load zero-extends into RAX per x86-64 semantics.

---

## 3. Implementation Details

### 3.1 _current_tcb Symbol

Defined in `src/kernel/core/sched/runqueue.pdx` line 85:
```
pub let mut _current_tcb : u64 = 0
```

All dispatch stanzas load via RIP-relative addressing:
```asm
mov rax, [rip + _current_tcb]
```

This avoids hardcoding absolute addresses and works under ASLR-like relocation schemes.

### 3.2 Handler Body Signatures

All bodies follow a consistent SysV calling convention after the dispatcher shuffle:

- **1-arg bodies** (fork, wait4): `(current: u64)` → RDI
- **2-arg bodies** (close): `(current: u64, fd: u64)` → RDI, RSI
- **3-arg bodies** (dup2): `(current: u64, src_fd: u64, dst_fd: u64)` → RDI, RSI, RDX
- **4-arg bodies** (read, write, open): `(current, a1, a2, a3)` → RDI, RSI, RDX, RCX

All bodies preserve callee-save registers (RBX, RBP, R12–R15) across nested calls.

### 3.3 Return Conventions

- **Success**: Error-free syscalls return result in RAX (typically fd, pid, bytes, or 0)
- **Errors**: Negative-errno u64 (Linux convention; sign-extended into RAX)
- **Special**: fork/wait4 use RDX for secondary return (child pid → RDX; wait4 status in RDX)

---

## 4. Verification

### 4.1 Compile-Time Checks

- Encoder validates symbol references for all `call sys_*_body` and `[rip + _current_tcb]` directives
- Linker resolves symbols; unresolved symbols cause link failure

### 4.2 Runtime Verification

`tools/verify-syscall-dispatch.sh` post-build audit:

1. **Symbol checks**: All 11 routing IDs have `cmp rdi, ID` and correct label routing
2. **Body calls**: Each ID ≠ 39 has a `call sys_*_body` (or fast-path for ID 1, inline for 39)
3. **_current_tcb usage**: At least 5 references expected (one per main dispatch row + wait4 shim)
4. **ENOSYS constant**: dispatch_enosys returns `0xFFFFFFFFFFFFFFDA`
5. **Exit halt loop**: dispatch_exit has unreachable halt sequence
6. **Wait4 writeback**: Stack push/pop and memory write pattern present

Marker: `KERNEL SYSCALL DISPATCH OK` on success.

---

## 5. Known Limitations & Deferrals

### 5.1 Execve Shim (#671)

ID 59 (execve) remains ENOSYS pending a user-ABI bridge (#671). The userland syscall passes (path, argv, envp); sys_execve_body expects a loaded binary image. The shim needs to:

1. Copy path pointer from userland
2. Call `vfs_open(path, flags)` → vnode_idx
3. Call `vfs_read(vnode_idx, ...)` → load into tmpfs buffer
4. Validate ELF header; trim padding
5. Call `sys_execve_body(current, image, image_len)`

This work is deferred to R17.M2 Tier-2 runtime initialization and tracked in #671.

### 5.2 SMAP (Supervisor Mode Access Prevention)

The wait4 writeback stanza assumes SMAP is **not** enabled:
```asm
mov [rsi], edx          ; SMAP not enabled — safe
```

At R17.M0 single-CPU with SMAP disabled, kernel→user writes are allowed. When SMAP lands (future kernel feat), this must transition to a copy-out helper (COPY_TO_USER idiom or equivalent).

### 5.3 Exit Marker Message

The old `sys_exit` function printed `[exit]` via `exit_marker_msg`. This has been removed; real exit behavior is now purely via `sys_exit_body` which updates scheduler state. The TTY message was a debugging artifact and is no longer printed at R17.M0.

---

## 6. Design Rationale

### Why Load _current_tcb in Dispatch?

The dispatcher is the trust boundary: syscalls arrive unsanitized from userland. Pinning the current task pointer at dispatch entry ensures all handlers receive the authentic task context, rather than trusting a register that could be corrupted by a malicious syscall argument.

### Why Fast-Path ID 1?

Init bootstrap writes before opening TTY fds. A full fd_table lookup would fail (EBADF) or panic. The fast-path allows init to printf before TTY init completes, unblocking the boot sequence. Once R17.M2 Tier-2 opens TTY fds (fd 1→/dev/tty1), sys_write_body takes over and enforces the fd_table contract.

### Why Inline Getpid?

Getpid is a single load from a fixed offset in the task struct. No nested call or callee-save prologue is needed. Inlining saves 2–3 instructions per syscall.

### Why ENOSYS for Execve?

Userland syscall ABIs (Linux: path, argv, envp) do not map cleanly to kernel-internal image representations (loaded binary buffer + length). A shim layer is necessary to bridge the gap. This is a cross-boundary impedance mismatch, not a missing feature.

---

## 7. Testing Strategy

### Phase 1: Build Verification
- `tools/build.sh` runs `verify-syscall-dispatch.sh` post-link
- Audit checks all 11 wired IDs and the ENOSYS fallback
- On FAIL, build halts; on OK, proceeds

### Phase 2: 5-Mode Smoke Test (No New Tests)
- Existing smoke tests in `tools/run-smoke.sh` do **not** reach dispatch boundaries at R17.M0
- All smoke tests pass unchanged (zero delta)
- Once init lands (R17.M2+), integration tests will exercise dispatch

### Phase 3: Manual Witness
- Each handler body (#587–#591, #553–#558) has its own design-doc audit
- This doc audits the dispatcher wiring only; handlers are out-of-scope

---

## 8. Commit Message

```
Implement #668: SC+ freeze alignment — wire kernel dispatch to real bodies (read/write/open/close/dup2/getpid/fork/exit/wait4)

- Wire syscall IDs {0, 2, 3, 32, 39, 56, 60, 61} to sys_*_body handlers
- ID 1 (write) preserves fd∈{1,2}→UART fast-path until R17.M2 Tier-2
- ID 59 (execve) routes to ENOSYS; deferral to #671 (path→image shim)
- ID 4, 12 unchanged (cap_invoke, debug_puts)
- Add tools/verify-syscall-dispatch.sh post-build audit
- Remove old sys_write/sys_exit stubs from dispatch.pdx
- Update build.sh to run verification after kernel link
```

---

## 9. References

- **R16-M3**: #587 (sys_open), #588 (sys_close), #589 (sys_read), #590 (sys_write), #591 (sys_dup2)
- **R15-M6**: #553 (task_new), #554 (sys_fork), #555 (pid_free), #556 (sys_wait), #557 (sys_exit), #558 (orphan_adopt)
- **R15-M4**: #536 (dispatcher entry/exit), #537 (sys_exit MVP), #538 (sys_write MVP)
- **R13**: #429 (syscall table), design/user/syscall-table.md
- **Cross-Repo**: paideia-as encoder for symbol-reference support in inline assembly
- **Follow-Up**: #671 (sys_execve dispatch shim for R17.M2 Tier-2)
