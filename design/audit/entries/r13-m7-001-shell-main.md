---
audit_id: r13-m7-001-shell-main
issue: 432
file: src/user/shell.pdx
function: _start
effects: [sysreg]
capabilities: [cap, sched]
reviewed_by:
date: 2026-07-03
---

# R13-m7-001 — User shell entry point (demonstrative straight-line main)

**Issue:** #432
**Files:** src/user/shell.pdx (new)
**Backtracking:** #483 (R13 user-shell deferral record), #482 (cap_smoke migration)

## Landing scope

This issue lands the user-space shell entry point as a demonstrative straight-line program:

1. Print banner: "PaideiaOS shell v0.1\n"
2. Print prompt: "$ "
3. Print help menu: "help|exit\n"
4. Invoke capability at slot 0 with op_arg=0 (no-op dispatch_cap).
5. Exit via sys_exit_thread(0).

No interactive loop, no sys_read, no user input parsing. This is a source-of-truth reference implementation; the actual binary will not be linked into kernel.elf until m8-001 (user loader + ring-3 jump).

## Why no interactive loop?

Per §C-frozen syscall freeze (#483), `sys_read` is explicitly **not** provided at R13. The demonstrative shell cannot block on user input without `sys_read` or an alternative blocking primitive (wakeup source, IPC port). Parsing user commands to decimal-parse slot numbers (e.g., `cap 2 3`) also requires `sys_read`. This deferral is tracked in #483 and will be resolved by R14 design.

## Data layout

Two message buffers (const arrays in .rodata):
- `banner_msg : [u8; 22]` = "PaideiaOS shell v0.1\n\0"
- `prompt_msg : [u8; 4]` = "$ \0\0"

Lengths stored explicitly (21 and 2) to demonstrate syscall argument passing.

## ABI compliance (SysV x86_64)

All calls use position-dependent RDI/RSI argument convention:
- `puts(rdi=msg_ptr, rsi=msg_len)` delegates to `sys_debug_puts`.
- `dispatch_cap(rdi=slot, rsi=op_arg)` delegates to `sys_cap_invoke`.
- `builtin_exit(rdi=code)` delegates to `sys_exit_thread`.
- `builtin_help()` calls `puts` with LEA to load relative addresses.

## Execution sequence

```asm
_start:
  lea rdi, [rip + banner_msg]     # banner ptr
  mov rsi, 21                     # banner len
  call puts                       # print banner

  lea rdi, [rip + prompt_msg]     # prompt ptr
  mov rsi, 2                      # prompt len
  call puts                       # print prompt

  call builtin_help               # prints "help|exit\n"

  mov rdi, 0                      # slot 0
  mov rsi, 0                      # op_arg 0
  call dispatch_cap               # no-op invoke

  mov rdi, 0                      # exit code 0
  call builtin_exit               # never returns
  ret                             # unreachable
```

## Regression

This is a new source file outside the kernel build. No changes to existing kernel code.
`tools/build.sh` only globs `src/kernel/`, so `src/user/` .pdx files are NOT compiled at R13.
No binary produced; no regression vector.

## Acceptance

- [x] Source file created: src/user/shell.pdx
- [x] Straight-line demonstrative sequence (no loops, no input parsing).
- [x] Uses only §C-native syscall shims (sys_exit_thread, sys_yield (not called), sys_cap_invoke, sys_debug_puts).
- [x] RIP-relative addressing for banner/prompt strings.
- [x] SysV x86_64 ABI compliance (rdi/rsi arg convention).
- [x] Never returns (sys_exit_thread never returns).

## Follow-up (m8)

m8-001 will:
1. Invoke a user-space linker on src/user/*.pdx sources.
2. Link into build/shell.elf using design/user/link.ld.
3. Extract binary via objcopy -O binary -> build/shell.bin.
4. Embed shell.bin into kernel.elf via .incbin.
5. Implement ring-3 userspace jump in kernel entry.

Cross-references:

- src/user/syscall_shim.pdx (R13-m7-002 #433)
- src/user/io.pdx (R13-m7-003 #434)
- src/user/builtins.pdx (R13-m7-003 #434)
- design/user/link.ld (m8-002 sketch)
- #483 (R13 user-shell deferral record)
