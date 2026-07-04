# SC+ Syscall Table (Frozen — R15.M4)

## Purpose

Canonical syscall table for the paideia-os user↔kernel ABI (SC+ family). This document is the source of truth for the R15.M4 dispatch table (#536): kernel implementation must materialize exactly these numbers, argument slots, and return conventions.

Scope: minimum surface required to run the R15 shell demo (`sh`, `cat`, `echo`, redirection, pipes to be added later). Numbers reserved but unlisted here are `ENOSYS` until a follow-up freeze extends this table.

## Calling Convention

paideia-os user programs enter the kernel via the `SYSCALL` instruction. Register roles:

| Register | Role |
|----------|------|
| `rax` | Syscall number (input) / return value (output) |
| `rdi` | arg 0 |
| `rsi` | arg 1 |
| `rdx` | arg 2 |
| `r10` | arg 3 (per Linux SYSCALL — `rcx` is clobbered by the CPU) |
| `r8`  | arg 4 |
| `r9`  | arg 5 |

Return: `rax` holds a non-negative result on success, or a negative errno on failure (see below). No arguments are passed on the stack. `rcx` and `r11` are clobbered by `SYSCALL` semantics. All other GP registers are preserved by the kernel.

## Syscall Table

| # | Name | Args (rdi, rsi, rdx, r10, r8, r9) | Return semantics |
|---|------|------------------------------------|------------------|
| 0 | `read` | `fd`, `buf`, `count` | bytes read (0 = EOF) or `-errno` |
| 1 | `write` | `fd`, `buf`, `count` | bytes written or `-errno` |
| 2 | `open` | `path`, `flags`, `mode` | fd (>= 0) or `-errno` |
| 3 | `close` | `fd` | 0 or `-errno` |
| 12 | `debug_puts` | `buf`, `count` | bytes emitted; kernel-owned debug channel (bypasses normal fd routing) |
| 32 | `dup2` | `oldfd`, `newfd` | `newfd` or `-errno` |
| 39 | `getpid` | — | current pid (always succeeds) |
| 56 | `clone` | (simplified; no args in R15) | child pid to parent, `0` to child, `-errno` on failure |
| 59 | `execve` | `path`, `argv`, `envp` | does not return on success; `-errno` on failure |
| 60 | `exit` | `status` | never returns |
| 61 | `wait4` | `pid`, `wstatus`, `options`, `rusage` | reaped pid or `-errno` |

Numbering intentionally tracks Linux for the common core (0–3, 32, 39, 56, 59, 60, 61) to keep future userland ports mechanical; `12` is repurposed from Linux `brk` for the paideia-os debug channel and is a stable divergence.

## Errno Constants

Negative return values encode errno:

| Value | Symbol | Meaning |
|-------|--------|---------|
| -1 | `EPERM` | Operation not permitted |
| -2 | `ENOENT` | No such file or directory |
| -9 | `EBADF` | Bad file descriptor |
| -12 | `ENOMEM` | Out of memory |
| -14 | `EFAULT` | Bad address (user pointer invalid) |
| -22 | `EINVAL` | Invalid argument |
| -38 | `ENOSYS` | Syscall not implemented / unknown number |

Any syscall number not listed in the table above returns `-ENOSYS` (-38).

## References

- #536 — R15.M4 kernel dispatch table (implementation of this freeze).
- `design/user/elf-lite-format.md` — user binary format that consumes this ABI.
