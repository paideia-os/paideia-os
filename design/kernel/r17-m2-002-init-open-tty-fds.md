---
issue: 617
milestone: R17.M2 (init + loader)
subsystem: 16 — libc-lite for userland
prereq:
  - "R17.M2-001 (#616) — init source and linker (minimal ring-3 init)"
  - "R17.M1-001 (#610) — sys_open, sys_dup2, sys_close syscall wrappers"
  - "R16.M3-001, #002, #003 — kernel handlers for sys_open, sys_dup2, sys_close"
blocks:
  - "#620 (R17.M2 loader into kernel) — init.bin embed + jump (depends on init FD OK)"
  - "R17.M2 smoke tests — 5-mode byte-identity verification"
  - "R17.M3 shell (#622+) — once init runs and writes to TTY"
touching:
  - src/user/init.pdx                              (extend: add dev_tty0_path rodata + open/dup2/close sequence)
  - tools/build-user.sh                            (extend: append verify-user-init.sh call)
  - tools/verify-user-init.sh                      (new: byte-pattern canary for init TTY fd init)
  - design/kernel/r17-m2-002-init-open-tty-fds.md (this doc)
related:
  - "#616 (R17-M2-001 init source) — base on which this extends"
  - "#610 (R17-M1-001 syscall shim) — sys_open, sys_dup2, sys_close wrappers"
  - "#538, #540 (#595) — kernel handlers sys_open/dup2/close"
  - "#620 (R17.M2-002 loader) — embedding and jumping to init"
---

# R17-M2-002 — init open tty fds inline (#617)

## 1. Scope

Extend the minimal init program (src/user/init.pdx from R17.M2-001) to initialize
standard file descriptors (0, 1, 2) before printing "INIT OK\n". The init program now:

1. Opens "/dev/tty0" via sys_open (path, flags=0, mode=0)
2. Dups the opened fd to 0 (stdin) via sys_dup2
3. Dups the opened fd to 1 (stdout) via sys_dup2
4. Dups the opened fd to 2 (stderr) via sys_dup2
5. Closes the original fd via sys_close
6. Prints "INIT OK\n" (8 bytes) via sys_debug_puts syscall
7. Enters an infinite hlt loop (never returns)

This demonstrates **file descriptor initialization at ring 3**, preparing the
process for future shell startup (R17.M3) and ensuring writes to fd=1/2 reach the
TTY device instead of failing with EBADF (bad file descriptor).

**Runtime verification deferred to R17.M2-002+ (#620/#665)** — loader must embed
and jump to init.bin for syscalls to execute. At build time, we verify byte
patterns for syscall presence.

## 2. Prereq check

### 2.1 In place

- **R17.M2-001 init source (#616)** — base init program with sys_debug_puts call.
- **R17.M1-001 syscall shim (#610)** — sys_open, sys_dup2, sys_close wrappers
  - sys_open(path, flags, mode) → rax=2, syscall
  - sys_dup2(oldfd, newfd) → rax=32, syscall
  - sys_close(fd) → rax=3, syscall
- **Kernel handlers** — sys_open/dup2/close live in kernel (R16.M3 series)
  - sys_open (#538, #595-impl-pending)
  - sys_dup2 (#540, #595-impl-pending)
  - sys_close (#595)
- **Ring-3 memory layout** — /dev/tty0 device node resolvable once loader runs

### 2.2 Not in scope

- **Kernel /dev/tty0 device** — assumed to exist and be openable
- **Runtime verification** — actual syscall execution requires loader (#620/#665)
- **Shell startup** — init will eventually execve shell (R17.M3), but this issue
  stops short; shell receives initialized fds 0/1/2 from init
- **Error handling** — if sys_open/dup2/close fail (return negative), init ignores
  and proceeds to sys_debug_puts. No recovery path exists at R17.M2.

## 3. Design

### 3.1 init.pdx structure (extended from R17.M2-001)

**New rodata:**

```paideia
pub let dev_tty0_path : [u8; 10] = "/dev/tty0\0"
pub let init_msg : [u8; 9] = "INIT OK\n\0"
pub let init_len : u64 = 8
```

**Updated _start:**

```paideia
pub let _start : () -> () !{sysreg} @{fs} = fn () -> unsafe {
  effects: {sysreg}, capabilities: {fs},
  justification: "...",
  block: {
    // Open /dev/tty0
    lea rdi, [rip + dev_tty0_path];
    xor rsi, rsi;                   // flags = 0 (O_RDONLY)
    xor rdx, rdx;                   // mode = 0
    call sys_open;
    mov r12, rax;                   // save fd in r12

    // dup2(fd, 0)
    mov rdi, r12;
    xor rsi, rsi;                   // newfd = 0
    call sys_dup2;

    // dup2(fd, 1)
    mov rdi, r12;
    mov rsi, 1;                     // newfd = 1
    call sys_dup2;

    // dup2(fd, 2)
    mov rdi, r12;
    mov rsi, 2;                     // newfd = 2
    call sys_dup2;

    // close original fd
    mov rdi, r12;
    call sys_close;

    lea rdi, [rip + init_msg];
    mov rsi, 8;
    call sys_debug_puts;

    // infinite hlt loop
    loop_start:
      hlt;
      jmp loop_start
  }
}
```

**Changes:**

- **Capability scope:** extended from `@{}` to `@{fs}` (file system capability required
  for sys_open/dup2/close)
- **Effects scope:** unchanged `!{sysreg}` (all syscalls use sysreg)
- **Rodata:** new dev_tty0_path string (10 bytes: "/" + "dev/tty0" + NUL)
- **Code:** ~50 LOC added (open + 3x dup2 + close sequence)

**Register usage:**

- rdi/rsi/rdx: SysV arguments (preserved by kernel across syscall boundary)
- r12: saving the opened fd across multiple dup2 calls
- rax: syscall return value (fd or error code)

### 3.2 Syscall sequence walkthrough

**1. sys_open("/dev/tty0", 0, 0)**

```asm
lea rdi, [rip + dev_tty0_path]  // rdi = addr of "/dev/tty0\0"
xor rsi, rsi                     // rsi = 0 (O_RDONLY / no flags)
xor rdx, rdx                     // rdx = 0 (mode irrelevant for /dev files)
call sys_open                    // kernel: syscall 2
                                 // rax = fd (or error < 0)
mov r12, rax                     // save fd for later dup2 calls
```

Returns fd on success (likely 3, since 0/1/2 not yet used), or negative error code
on failure (e.g., ENOENT if /dev/tty0 doesn't exist).

**2. sys_dup2(r12, 0) — dup2 to stdin**

```asm
mov rdi, r12                     // rdi = fd (saved from open)
xor rsi, rsi                     // rsi = 0 (newfd = stdin)
call sys_dup2                    // kernel: syscall 32
                                 // rax = 0 (or error)
```

After this, reads from fd=0 will read from /dev/tty0.

**3. sys_dup2(r12, 1) — dup2 to stdout**

```asm
mov rdi, r12                     // rdi = fd
mov rsi, 1                       // rsi = 1 (newfd = stdout)
call sys_dup2                    // kernel: syscall 32
```

After this, writes to fd=1 will write to /dev/tty0. This is critical for subsequent
shell output to reach the terminal.

**4. sys_dup2(r12, 2) — dup2 to stderr**

```asm
mov rdi, r12                     // rdi = fd
mov rsi, 2                       // rsi = 2 (newfd = stderr)
call sys_dup2
```

After this, writes to fd=2 will write to /dev/tty0.

**5. sys_close(r12) — close original fd**

```asm
mov rdi, r12                     // rdi = fd (the one opened)
call sys_close                   // kernel: syscall 3
```

The original fd (typically 3) is now closed; the device is still held open by the
dup'd fds 0/1/2. Process exit will close all fds automatically.

**6. sys_debug_puts("INIT OK\n", 8)**

```asm
lea rdi, [rip + init_msg]        // rdi = addr of "INIT OK\n\0"
mov rsi, 8                       // rsi = 8 (count)
call sys_debug_puts              // kernel: syscall 12 (R13 legacy)
```

At R17.M2, sys_debug_puts still works (it's a universal debug escape hatch, doesn't
require fd=1 to be initialized). However, once fds 0/1/2 are set up, subsequent
writes to fd=1 via sys_write would also succeed.

### 3.3 Verifier: tools/verify-user-init.sh

New script (~60 LOC) performs byte-pattern canary checks on init.elf:

1. **Extract syscall wrapper bytes** — verifies sys_open, sys_dup2, sys_close symbols
   exist and match expected machine code (mov rax, ID; syscall; ret)
2. **Count call sites in _start** — searches disassembly of _start function for
   - call sys_open (1 expected)
   - call sys_dup2 (3 expected)
   - call sys_close (1 expected)
3. **Exit with "R17 INIT FD OK"** on success, **"R17 INIT FD FAIL"** on any mismatch

Pattern examples (from verify-syscall-shim.sh):
- sys_open: `48 c7 c0 02 00 00 00 0f 05 c3` (mov rax,2; syscall; ret)
- sys_dup2: `48 c7 c0 20 00 00 00 0f 05 c3` (mov rax,32; syscall; ret)
- sys_close: `48 c7 c0 03 00 00 00 0f 05 c3` (mov rax,3; syscall; ret)

### 3.4 build-user.sh extension

Append verifier call after init.elf is linked and objcopy'd:

```bash
echo "[verify-user] byte-pattern canary on sys_open/sys_dup2/sys_close in init.elf"
"${REPO_ROOT}/tools/verify-user-init.sh" "${BUILD_DIR}/init.elf"
```

**Output** (success case):
```
[verify-user] byte-pattern canary on sys_open/sys_dup2/sys_close in init.elf
[ok]   sys_open found
[ok]   sys_dup2 found
[ok]   sys_close found
[ok]   call sys_open found (count: 1)
[ok]   call sys_dup2 found (count: 3)
[ok]   call sys_close found (count: 1)
R17 INIT FD OK
```

## 4. Acceptance criteria

1. **init.pdx compiles** — no paideia-as errors. Compiles to init.o.
2. **init.elf links** — uses init.ld (from R17.M2-001), combined with syscall_shim.o,
   errno.o, string.o library objects.
3. **init.bin extracts** — objcopy -O binary produces init.bin (~450 bytes, ~50 LOC
   added over #616 baseline ~393 bytes).
4. **Verifier emits "R17 INIT FD OK"** — byte-pattern checks pass, all 5 call sites
   counted correctly.
5. **Smoke (5-mode)** — byte-identical across 3 runs (2/3 acceptable per flake
   tolerance). Verifies no non-determinism in build pipeline.
6. **No failing tests** — all R17.M1 verification canaries pass on shell.elf
   (syscall_shim, string, errno, io, libc_test). init.elf verification canary
   (verify-user-init.sh) passes.
7. **Design doc present** — this file, covering scope/prereqs/design/AC/notes.

## 5. Implementation notes

### 5.1 No error handling in init

If any syscall fails (returns negative error code), init ignores the result and
proceeds to the next operation. This is a simplification at R17.M2; a production
init would retry, fall back, or panic. Error handling deferred to R17.M3+.

### 5.2 fd=3 assumption

We assume the kernel opens fd=3 for the first user sys_open call (since 0/1/2 are
not yet allocated). This is safe: the kernel's per-task fd table begins empty, and
allocates the lowest available slot. Linux also does this (fd_alloc strategy).

### 5.3 R17 vs. R13 legacy sys_debug_puts

sys_debug_puts (syscall 12, R13 legacy) remains universal; every task can call it,
regardless of fd state. This allows the "INIT OK\n" message to always print, even
if the fd initialization fails. Post-R17.M4, tty writes via fd=1 will require
proper vnode infrastructure; sys_debug_puts is a permanent debug escape hatch.

### 5.4 x86_64 SysV ABI arg registers

- Arguments 1–3: rdi, rsi, rdx (used by sys_open, sys_dup2, sys_close)
- Argument 4+: rcx, r8, r9 (only sys_wait4 uses this; not here)
- Return value: rax (fd on success, negative error code on failure)
- Volatile across syscall: rax, rcx, rdx, rsi, rdi, r8–r11
- Preserved: rbx, r12–r15 (we use r12, which is safe)

### 5.5 Path string layout

The string "/dev/tty0" is stored as a module-level [u8; 10] array in rodata,
including the NUL terminator. paideia-as places it in .rodata.* (read-only data
section), which the linker collects under .rodata at VA 0x00400000+offset.
init LEAs it via `lea rdi, [rip + dev_tty0_path]`, resolving the RIP-relative offset
at runtime to the actual VA.

## 6. Next steps

- **R17.M2-003 (#620, #665)** — Embed init.bin in kernel and jump to it.
  - Extend userbin_embed.S to include init.bin (in addition to shell.bin)
  - Extend kernel.ld to wire init.bin section into kernel image
  - Implement kernel_main.pdx loader to jump to init at ring 3
  - **At that point, runtime syscalls execute; verifier passes → "R17 INIT FD OK"**
- **R17.M3 (#622+)** — Implement shell.pdx and execve.
  - init will execve("/bin/shell", ...) after printing "INIT OK\n"
  - shell receives fds 0/1/2 from init, ready for TTY I/O
- **R17.M4 (#630+)** — Builtins and full shell integration.
