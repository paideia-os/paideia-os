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
| 96 | `sendto` | `fd`, `buf`, `len`, `dst_ip`, `dst_port` | bytes sent or `-errno`; UDP's first send path (R93.M2). Also usable by TCP — `dst_ip`/`dst_port` ignored on a connected socket. |
| 97 | `recvfrom` | `fd`, `buf`, `len`, `src_ip_out`, `src_port_out` | bytes received or `-errno`; UDP's first recv path (R93.M2). |
| 98 | `getsockopt` | `fd`, `level`, `optname`, `optval_ptr`, `optlen_ptr` | 0 or `-errno`; `SO_ERROR`/`SO_TYPE` at R95.M1. |
| 99 | `setsockopt` | `fd`, `level`, `optname`, `optval_ptr`, `optlen` | 0 or `-errno`; `SO_REUSEADDR`/`O_NONBLOCK`-equivalent/`TCP_NODELAY` at R95.M1. |
| 100 | `getpeername` | `fd`, `sockaddr_out` | 0 or `-errno`; R95.M2. |
| 101 | `getsockname` | `fd`, `sockaddr_out` | 0 or `-errno`; R95.M2. |
| 102 | `poll` | `fds_ptr`, `nfds`, `timeout_ms` | nready or `-errno`; fixed-size `fds` array, no dynamic `nfds` allocation. R95.M3. |
| 103 | `icmp_echo` | `dst_addr_ptr`, `seq`, `payload_ptr`, `payload_len`, `timeout_ms` | rtt_ns (>=0) or `-errno`; requires R_NET_PRIVILEGED_PROTOCOL (kernel-side check via `cap_check_r_net_privileged_protocol`). Loopback (dst 127.x.x.x or `_ipv4_my_ip`) is synchronous through the ICMP send path; off-box wire dispatch deferred pending real ARP + wait-for-reply plumbing. R100-PREP-003 (paideia-os #2009). |
| 104 | `pdxfs_txn_commit` | `cap_slot` | 0 or `-errno` / sentinel; commits the KIND_PDXFS_TXN behind `cap_slot` (writes JOP_COMMIT + BD_OP_FLUSH via `pdxfs_txn_commit_wal`, transitions OPEN → COMMITTED via `pdxfs_txn_row_transition`, bumps `PXT_ST_COMMITS`). `-EBADF` on a bad cap slot; underlying journal / transition sentinels forwarded verbatim. Row release + cap-slot clear are DEFERRED to a future `sys_pdxfs_txn_close`. R90-XREPO.010.M1-003 (paideia-os #2111). |
| 105 | `pdxfs_txn_abort` | `cap_slot` | 0 or `-errno` / sentinel; aborts the KIND_PDXFS_TXN behind `cap_slot` (writes JOP_ABORT via `pdxfs_txn_abort_wal`, transitions OPEN → ABORTED, bumps `PXT_ST_ABORTS`). Per-record undo-body replay DEFERRED to paideia-os #2112 (blocked on this milestone). R90-XREPO.010.M1-003 (paideia-os #2111). |
| 106 | `pdxfs_stat_by_inode` | `inode_no`, `out_stat_ptr` | 0 or `-errno`; populates a 32-byte record at `out_stat_ptr` with `{mode_bits, size_bytes, mtime_ns, ctime_ns}` for the tmpfs inode `inode_no`. `mode_bits` = `S_IFREG\|0o644` (`0x81A4`) for `VNODE_TYPE_REG`, `S_IFDIR\|0o755` (`0x41ED`) for `VNODE_TYPE_DIR`. `mtime_ns` = `_tick_count * 10_000_000` (matches UEJ convention). `ctime_ns` reserved zero. `-EFAULT` on bad `out_stat_ptr`; `-ENOENT` on OOR `inode_no` or unallocated slot. Blocks 3 of 6 columns in `ls -l` (mode/size/mtime). R90-XREPO.010.M1-002 (paideia-os #2110). |
| **517** | **`cwd_resolve`** (RESERVED) | `path_ptr`, `path_len_hint`, `abs_out_ptr`, `abs_out_cap` | strlen (excl. NUL) or `-errno`; realpath primitive for the mv/rm/cp satellite consumers. Resolves the caller's path (absolute OR relative — relative anchors at `[_current_tcb + TASK_OFF_CWD]` per `design/user/cwd-semantics.md`) and writes the resulting absolute path back into the caller buffer. Body/dispatch/fingerprint deferred; the CWD resolution policy is frozen (Option A) by paideia-os #2115 (R90-XREPO.010.M1-007). |
| **527** | **`pdxfs_fault_inject`** | `class` | 0 or `-errno`; arms/disarms a PdxFS fault-injection class. `class` = 0 disarms; 1..4 arm one of `WAL_WRITE_FAIL` / `INODE_ALLOC_FAIL` / `EXTENT_ALLOC_FAIL` / `UNDO_APPEND_FAIL`. Single-shot: the arm is consumed by the next traversal of the named hook site (`wal_append` / `tmpfs_inode_alloc` / `tmpfs_write` pre-`phys_alloc` / `pdxfs_txn_undo_append`). Refused with `-EPERM` when the boot flag `_pdxfs_fault_enabled` is 0 (release-build gate; see `design/kernel/pdxfs-fault-inject.md` §3), refused with `-EINVAL` when class > 4. Dispatch is an explicit early check ahead of the linear switch bounds gate — the sysno sits far above the 0..107 core range, chosen out-of-band by the mv/rm design docs to preserve the tightly-packed low band. R90-XREPO.010.M1-005 (paideia-os #2113). |

Syscalls 96–102 are **reserved by `design/networking/r91-plan.md` §17,
not yet implemented** as of this table's refresh (R90-XREPO.009 covers
only through 95). They will be materialized in `dispatch.pdx` as each
round in the R91–R99 networking wave lands the corresponding handler;
until then they fall through to `-ENOSYS` like any other unlisted number.

Sysnos **517** and **527** are **pre-reserved by the R90-XREPO.010
wave** (`design/round-retrospectives/r90-xrepo-wave3-plan.md` §2) and
have **no body** in the tree yet — they fall through to `-ENOSYS`
until their owning sub-issues land. Sysno 517 (`sys_cwd_resolve`) is
the mv/rm/cp satellite consumers' realpath primitive; its cwd
resolution semantics are frozen ahead of the body's landing by
paideia-os #2115 (R90-XREPO.010.M1-007) — see
`design/user/cwd-semantics.md` for the invariant every path-resolving
syscall (§3 of that doc) already obeys and that sysno 517 inherits on
landing. Sysno 527 (`sys_pdxfs_fault_inject`) lands in
R90-XREPO.010.M1-005. Both slot numbers were chosen out-of-band
(above the tightly-packed 0..103 core range) so no future contiguous
allocation displaces them.

Sysno 103 (`sys_icmp_echo`) is placed one slot above the reserved
96–102 range rather than at 96 itself: displacing an already-documented
reservation for a preceding milestone (R91's `sendto`) would break the
one-to-one map the R91–R99 wave assumes. Choosing the first slot ABOVE
the reserved band preserves that map and is the same "IDs are
negotiable" latitude R53.M2-001 exercised when `mount`/`umount` moved
from 73/74 → 75/76 after 74 was pre-claimed by #1675.

Sysnos 104 (`sys_pdxfs_txn_commit`) and 105 (`sys_pdxfs_txn_abort`)
occupy the two slots immediately above `sys_icmp_echo` for the same
reason: displacing 96–102 would break the R91–R99 one-to-one map, and
placing them adjacent to `sys_pdxfs_txn_open` (sysno 70) would clash
with the existing sibling reservations (71 = `sys_pdxfs_open`, 72 =
`sys_pdxfs_dir_readnext`, 73 reserved for a future `sys_pdxfs_file_
close`). The two are grouped by lifecycle (`open` → `commit` / `abort`)
in this design table's discussion rather than by numeric adjacency in
the dispatch switch; kernel dispatch grouping stays contiguous with the
last allocated sysno.

Sysno 106 (`sys_pdxfs_stat_by_inode`) occupies the first slot above the
`104`/`105` txn lifecycle pair for the same reason those two chose 104
and 105 — the 96–102 R91–R99 reservation stays intact, and grouping
the R90-XREPO.010 pdxfs primitives above `sys_icmp_echo` keeps the
dispatch switch's contiguous-with-last-allocated-sysno discipline
unbroken. Together with `sys_pdxfs_open` (sysno 71) and
`sys_pdxfs_dir_readnext` (sysno 72), sysno 106 gives the ring-3
directory-listing wave three of the six columns `ls -l` needs
(mode/size/mtime); owner/group/nlink land in future evolutions of the
`sys_pdxfs_stat_by_inode` output record shape.

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
- `design/networking/r91-plan.md` §17 — reservation of 96–102 for the
  R91–R99 networking wave (sendto/recvfrom/getsockopt/setsockopt/
  getpeername/getsockname/poll).
- `design/user/elf-lite-format.md` — user binary format that consumes
  this ABI.
