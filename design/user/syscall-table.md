# SC+ Syscall Table (Frozen — R15.M4; extended through R86/R72/R73)

## Purpose

Canonical syscall table for the paideia-os user↔kernel ABI (SC+ family).
This document is the source of truth for the kernel dispatch table
(`src/kernel/core/syscall/dispatch.pdx`): kernel implementation
materializes exactly these numbers, argument slots, and return
conventions.

Numbers reserved but unlisted are `ENOSYS` until a follow-up round
extends this table. R90-XREPO.009 (paideia-os #2003) refreshed this
document to match live dispatch through sysno 95.

## Calling Convention

paideia-os user programs enter the kernel via the `SYSCALL` instruction.
Register roles:

| Register | Role |
|----------|------|
| `rax` | Syscall number (input) / return value (output) |
| `rdi` | arg 0 |
| `rsi` | arg 1 |
| `rdx` | arg 2 |
| `r10` | arg 3 (per Linux SYSCALL — `rcx` is clobbered by the CPU) |
| `r8`  | arg 4 |
| `r9`  | arg 5 |

Return: `rax` holds a non-negative result on success, or a negative
errno on failure. No arguments are passed on the stack. `rcx` and `r11`
are clobbered by `SYSCALL` semantics. All other GP registers are
preserved by the kernel.

## Syscall Table

| # | Name | Args (rdi, rsi, rdx, r10, r8, r9) | Return semantics |
|---|------|------------------------------------|------------------|
| 0 | `read` | `fd`, `buf`, `count` | bytes read (0 = EOF) or `-errno` |
| 1 | `write` | `fd`, `buf`, `count` | bytes written or `-errno` |
| 2 | `open` | `path`, `flags`, `mode` | fd (>= 0) or `-errno` |
| 3 | `close` | `fd` | 0 or `-errno` |
| 4 | `cap_invoke` | `slot`, `op_arg` | op-defined; retained from R13 |
| 12 | `debug_puts` | `buf`, `count` | bytes emitted; kernel-owned debug channel (bypasses normal fd routing) |
| 13 | `dmesg` | `buf`, `cap` | bytes copied out of the klog ring or `-errno` |
| 32 | `dup2` | `oldfd`, `newfd` | `newfd` or `-errno` |
| 39 | `getpid` | — | current pid (always succeeds) |
| 40 | `ipc_recv` | `endpoint`, `buf`, `cap`, `timeout` | bytes received or `-errno` |
| 41 | `ipc_reply` | `endpoint`, `buf`, `len`, `flags` | 0 or `-errno` |
| 42 | `ipc_send` | `endpoint`, `buf`, `len`, `flags` | 0 or `-errno` |
| 43 | `svc_lookup` | `name_ptr`, `name_len` | endpoint id or `-errno` |
| 56 | `fork` | — (SC+ names it `clone`) | child pid to parent, `0` to child, `-errno` on failure |
| 59 | `execve` | `path`, `argv`, `envp` | does not return on success; `-errno` on failure |
| 60 | `exit` | `status` | never returns |
| 61 | `wait4` | `pid`, `wstatus`, `options`, `rusage` | reaped pid or `-errno` |
| 70 | `pdxfs_txn_open` | `vol_slot`, `flags` | txn slot or `-errno` |
| 71 | `pdxfs_open` | `vol_slot`, `path_ptr`, `flags` | pdxfs handle or `-errno` |
| 72 | `pdxfs_dir_readnext` | `dir_handle`, `entry_out_ptr` | 1 = entry filled, 0 = EOD, `-errno` on failure |
| 74 | `blkdev_cap_request` | `bus`, `devfn`, `flags` | KIND_BLOCK_DEVICE slot or `-errno` |
| 75 | `mount` | `src_slot`, `mp_path_ptr`, `fs_name_ptr`, `flags`, `data_ptr` | 0 or `-errno` |
| 76 | `umount` | `mp_path_ptr`, `flags`, `data_ptr` | 0 or `-errno` |
| 77 | `stat` | `path_ptr`, `path_len_hint`, `stat_buf_out` | 0 or `-errno`; fills 64-byte stat scratch at `stat_buf_out` |
| 78 | `getdents` | `fd`, `buf`, `cap` | bytes returned (0 = EOD) or `-errno`; record layout in `sys_getdents.pdx` §Record layout |
| 79 | `mkdir` | `path_ptr`, `path_len_hint`, `mode` | 0 or `-errno` |
| 80 | `rmdir` | `path_ptr`, `path_len_hint` | 0 or `-errno` |
| 81 | `unlink` | `path_ptr`, `path_len_hint` | 0 or `-errno` |
| 82 | `rename` | `old_ptr`, `old_len`, `new_ptr`, `new_len` | 0 or `-errno` |
| 83 | `taskinfo` | `buf`, `cap` | bytes filled or `-errno`; fixed 40-byte-per-task records for /bin/ps |
| 84 | `mountinfo` | `buf`, `cap` | bytes filled or `-errno`; mount-table snapshot for /bin/mount no-args |
| 85 | `chdir` | `path_ptr`, `path_len_hint` | 0 or `-errno`; hint is a walker CAP (255 typical), not exact strlen |
| 86 | `getcwd` | `buf`, `cap` | strlen (excl. NUL) or `-errno`; NUL-terminated on success |
| 87 | `socket` | `domain`, `type`, `proto` | fd (>= 0) or `-errno` |
| 88 | `bind` | `fd`, `sockaddr_ptr` | 0 or `-errno` |
| 89 | `listen` | `fd`, `backlog` | 0 or `-errno` |
| 90 | `accept` | `fd` | new-fd (>= 0) or `-errno` |
| 91 | `connect` | `fd`, `sockaddr_ptr`, `addrlen` | 0 or `-errno` |
| 92 | `send` | `fd`, `buf`, `len` | bytes sent or `-errno` |
| 93 | `recv` | `fd`, `buf`, `len` | bytes received or `-errno` |
| 94 | `shutdown` | `fd`, `how` | 0 or `-errno` |
| 95 | `kill` | `pid`, `signum` | 0 or `-errno`; only SIGSTOP/SIGCONT delivered at R73 |

Numbering intentionally tracks Linux for the common core (0–3, 32, 39,
56, 59, 60, 61) to keep future userland ports mechanical. `12` is
repurposed from Linux `brk` for the paideia-os debug channel and is a
stable divergence. All other numbers (13, 40–43, 70+) diverge freely
from Linux — the paideia-os ABI is not a POSIX ABI.

## Walker length hint semantics

Every syscall that takes a `path_len_hint` (chdir/stat/mkdir/rmdir/
unlink/rename) treats it as a **walker CAP**, not an exact strlen: the
kernel copies up to `min(hint, 255)` bytes from user VA until it sees
NUL. Callers pass 255 (or any bound larger than the actual path). See
`src/user/rm.pdx` header for the convention.

`getcwd` reverses the direction: `cap` is the output-buffer size; the
kernel writes at most `cap` bytes ending in NUL and returns strlen.

## Errno Constants

Negative return values encode errno:

| Value | Symbol | Meaning |
|-------|--------|---------|
| -1 | `EPERM` | Operation not permitted |
| -2 | `ENOENT` | No such file or directory |
| -9 | `EBADF` | Bad file descriptor |
| -12 | `ENOMEM` | Out of memory |
| -14 | `EFAULT` | Bad address (user pointer invalid) |
| -20 | `ENOTDIR` | Not a directory |
| -22 | `EINVAL` | Invalid argument |
| -38 | `ENOSYS` | Syscall not implemented / unknown number |

Any syscall number not listed in the table above returns `-ENOSYS`
(-38).

## References

- #536 — R15.M4 kernel dispatch table (original freeze).
- #1790 — R56.M3-001 VFS metadata block (77–82).
- #1799 — R57.M4-003 sys_taskinfo (83).
- #1800 — R57.M4-004 sys_mountinfo (84).
- #1955/#1956 — R86.M1 sys_chdir (85) / sys_getcwd (86).
- #1927 — R72.M1-005 TCP socket API block (87–94).
- #1938 — R73.M1-001 sys_kill (95).
- #2003 (R90-XREPO.009) — this table refresh.
- `design/user/elf-lite-format.md` — user binary format that consumes
  this ABI.
