---
issue: 616
milestone: R17.M2 (init + loader)
subsystem: 16 — libc-lite for userland
prereq:
  - "R17.M1 syscall shim (#610) — sys_debug_puts wrapper"
  - "R15.M5 loader infrastructure — ring-3 entry point, memory layout"
  - "tools/build-user.sh — user binary build pipeline"
blocks:
  - "#617+ (R17.M2 loader into kernel) — init.bin embed + jump"
  - "R17.M3 shell (#622+) — once init runs"
  - "R17.M4 builtins (#630+) — init precedes shell in boot order"
touching:
  - src/user/init.pdx                    (new: minimal ring-3 init program)
  - src/user/init.ld                     (new: init linker script)
  - tools/build-user.sh                  (extend: separate init.elf / init.bin build path)
  - design/kernel/r17-m2-001-init-source-and-linker.md (this doc)
related:
  - "#515 (R15-M1-003 shell linker design) — link.ld pattern"
  - "#610 (R17-M1-001 syscall shim) — sys_debug_puts wrapper used here"
  - "#614 (R17-M1-005 user I/O) — puts_new / getline (not used in R17.M2 init)"
  - design/kernel/r15-m2-006b-boot-r15-ring3-hello.md (ring-3 entry state)"
---

# R17-M2-001 — init source + linker: first user-mode program (#616)

## 1. Scope

Implement the minimal ring-3 user-mode init program (`src/user/init.pdx`) and
its linker script (`src/user/init.ld`). The init program:

1. Prints `"INIT OK\n"` (8 bytes) via `sys_debug_puts` syscall
2. Enters an infinite `hlt` loop (never returns)

This is the **first demonstration of user-mode execution** in the R17 series —
it exercises the R15-M5 ring-3 entry machinery, the R17-M1 syscall shim, and
establishes the build pipeline for user binaries as a separate artifact from
the kernel.

At R17.M2, init is standalone; embedding it in the kernel and wiring the
loader jump is split to R17.M2-002 (#617+).

## 2. Prereq check

### 2.1 In place

- **syscall_shim.pdx (#610)** — `sys_debug_puts(buf, count)` wrapper emits
  SC+ ID 12 (SysV args rdi/rsi → SYSCALL unchanged; arity 2 < 4).
- **Ring-3 entry point from R15.M5** — kernel loads init.elf ELF image to
  VA 0x400000 (text+rodata) and 0x600000 (data), then jumps to _start
  (offset 0 in .text section, deduced from ELF e_entry field).
- **build-user.sh pipeline (#515)** — paideia-as compile + ld link +
  objcopy binary extraction. Extended in this issue to emit init.elf
  and init.bin as separate artifacts.

### 2.2 Not in scope

- **Embedding init.bin in kernel** — split to #617 (userbin_embed.S
  extension, kernel.ld section, kernel_main.pdx loader call).
- **Init bootstrapping shell** — that's #622+ (shell.pdx consumed by init
  via sys_execve).
- **Init signal handling** — no signals at R17.M2; init just yields to
  kernel with hlt.

## 3. Design

### 3.1 init.pdx structure

```paideia
module Init = structure {
  pub let init_msg : [u8; 9] = "INIT OK\n\0"
  pub let init_len : u64 = 8

  pub let _start : () -> () !{sysreg} @{} = fn () -> unsafe { ... }
}
```

**Rationale:**

- **Message layout:** 8 bytes of payload ("INIT OK\n") + NUL terminator in the
  array for C-style strings. `init_len` is the actual count passed to
  sys_debug_puts (8 bytes, not including NUL).
- **_start signature:** Takes no arguments (ring-3 entry point has rsi/rdi/rdx
  undefined; caller is kernel jump, not function call). Returns `()` but never
  returns in practice (infinite hlt loop). Effects={sysreg} (syscall issues);
  capabilities={} (no caps needed for debug_puts).
- **No error handling:** If sys_debug_puts fails (returns error code), init
  ignores it and proceeds to hlt. At R17.M2, no recovery path exists; this is
  a success-path demo.

### 3.2 init.ld linker script

Follows the same pattern as `src/user/link.ld` (R15-M1-003 #515):

- **.text at VA 0x00400000** (user ring-3 text space, read-execute)
- **.rodata at VA 0x00400000+offset** (follows .text, same read-execute segment)
- **.data at VA 0x00600000** (user ring-3 data space, read-write)
- **.bss at VA 0x00700000** (uninitialized data, read-write)

Each section 4K-aligned (ALIGN(4K)) to match TLB page granule. The ENTRY(_start)
asserts kernel jumps to _start symbol (e_entry in ELF header points to _start
VA, typically 0x400000 + offset_of_text._start).

### 3.3 tools/build-user.sh extension

The existing script builds `shell.elf` by linking **all** .pdx files (shell +
builtins + io + syscall_shim + string + errno). This issue extends it to also
build **init.elf** separately:

**Object categorization:**

1. **init.pdx** — init-only (adds _start and init_msg)
2. **Shared libraries** — syscall_shim, errno, string (used by both init and shell)
   - init needs: syscall_shim (for sys_debug_puts call)
   - shell needs: all of them (existing R15-M1 config)
3. **shell-only modules** — builtins, io (not used by init at R17.M2)

**Build order:**

1. Compile all .pdx → .o (existing loop)
2. Sort objects: SHELL_OBJECTS, INIT_OBJECTS, LIBS_OBJECTS
3. Link shell.elf: `ld -T link.ld LIBS_OBJECTS SHELL_OBJECTS → shell.elf`
4. Link init.elf: `ld -T init.ld LIBS_OBJECTS INIT_OBJECTS → init.elf`
5. Extract binaries: `objcopy -O binary {shell,init}.elf → {shell,init}.bin`

**Output:**

```
build/user/shell.elf   (6.3K approx)
build/user/shell.bin   (580 bytes approx)
build/user/init.elf    (5.8K approx)
build/user/init.bin    (393 bytes approx)
```

Both .bin files are ready for embedding via userbin_embed.S in R17.M2-002.

## 4. Acceptance criteria

1. **Build succeeds:** `tools/build-user.sh` produces both shell.bin and init.bin
   without error. ✓
2. **init.bin size:** 393 bytes (minimal init: sys_debug_puts call + hlt loop) ✓
3. **Smoke (5-mode):** byte-identical across 3 runs (2/3 acceptable per #659
   flake tolerance). Verifies no non-determinism in build pipeline. ✓
4. **No failing tests:** All R17.M1 verification canaries pass on shell.elf
   (syscall_shim, string, errno, io, libc_test). ✓
5. **Design doc present:** This file, covering scope/prereqs/design/AC. ✓

## 5. Implementation notes

### 5.1 No return paths

The infinite hlt loop ensures init never returns control. If somehow we reach
the end of _start (e.g., sys_debug_puts succeeds), the next instruction is
`hlt`, which halts the CPU. In bare-metal kernel mode, hlt triggers an exception
that the kernel must handle (typically re-schedules another task or powers down).
At R17.M2, the kernel has no other runnable tasks, so it will halt. This is
acceptable behavior for a demo init program.

### 5.2 sys_debug_puts availability

At R17.M1, sys_debug_puts is live (R13 legacy, dispatcher ID 12, kernel handler
prints to serial). It requires **no capability bits** — every user task can call
it. This is by design for debugging. By R17.M4, a tty vnode subsystem may gate
writes to real fd=1/2, but debug_puts remains a universal escape hatch.

### 5.3 Message string layout

The string `"INIT OK\n"` (8 bytes) is stored as a module-level array. paideia-as
places it in .rodata.* (read-only data), which the linker collects under
.rodata (VA 0x00400000+ range, same read-execute segment as .text). At runtime,
init LEAs the string address via `lea rdi, [rip + init_msg]`, which
position-independently resolves the RIP-relative offset to the string's VA.

### 5.4 Link order

Both init and shell link with the full set of library objects (syscall_shim,
errno, string). This means init.elf embeds syscall_shim code (the sys_debug_puts
trampoline), even though init never calls more than one syscall. Deduplication
(e.g., only link sys_debug_puts into init, skip syscall_shim for init) is a
future optimization; at R17.M2, simplicity (always link full libs) is preferred.

## 6. Next steps

- **R17.M2-002 (#617+):** Extend userbin_embed.S and kernel.ld to embed
  init.bin (in addition to shell.bin). Implement kernel_main.pdx loader
  to jump to init at ring 3.
- **R17.M3 (#622+):** Implement shell.pdx as a full program (banner + prompt +
  dispatch loop). init will execve shell after printing "INIT OK\n".
