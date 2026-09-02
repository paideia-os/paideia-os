# SC+ Syscall Table (Frozen — R15.M4; extended through R86/R72/R73)

## Purpose

Canonical syscall table for the paideia-os user↔kernel ABI (SC+ family).
This document is the source of truth for the kernel dispatch table
(`src/kernel/core/syscall/dispatch.pdx`): kernel implementation
materializes exactly these numbers, argument slots, and return
conventions.

Numbers reserved but unlisted are `ENOSYS` until a follow-up round
extends this table. R90-XREPO.009 (paideia-os #2003) refreshed this
document to match live dispatch through sysno 95; R90-XREPO.010.M1-008
(paideia-os #2116) extended the refresh through sysno 107 plus the
out-of-band sysnos 517 (`cwd_resolve`) and 527 (`pdxfs_fault_inject`).

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
| 96 | `sendto` | `fd`, `buf`, `len`, `dst_ip`, `dst_port` | bytes sent or `-errno`; UDP's first send path. Also usable by TCP — `dst_ip`/`dst_port` ignored on a connected socket. UDP arm honours the per-call peer by temporarily rewriting the socket row's peer_ip/peer_port around `udp_socket_send_body` and restoring on return, so a caller can sendto multiple peers on the same bound socket without an EISCONN refusal. R93.M2-004 (paideia-os #2052) landed. |
| 97 | `recvfrom` | `fd`, `buf`, `len`, `src_ip_out`, `src_port_out` | bytes received or `-errno`; UDP's first recv path. If `src_ip_out` / `src_port_out` are non-zero, writes 4 bytes each via KPTI-safe walker. Per-datagram-slot src tracking is DEFERRED; MVP reports the socket's stored peer_ip/peer_port (correct for a connected socket, approximation for a bound-not-connected multi-peer socket -- see `design/round-retrospectives/r93-closure.md` §Spec ambiguity 4). R93.M2-004 (paideia-os #2052) landed. |
| 98 | `getsockopt` | `fd`, `level`, `optname`, `optval_ptr`, `optlen_ptr` | 0 or `-errno`; `SO_REUSEADDR`/`SO_NONBLOCK`/`SO_ERROR`/`SO_TYPE` (level=`SOL_SOCKET`=1); `TCP_NODELAY` (level=`IPPROTO_TCP`=6). `SO_TYPE` derives from cap kind (`KIND_TCP_SOCKET`->`SOCK_STREAM`=1, `KIND_UDP_SOCKET`->`SOCK_DGRAM`=2). `SO_ERROR` reads and clears the row's so_error slot. R95.M1-002 (paideia-os #2077) landed. |
| 99 | `setsockopt` | `fd`, `level`, `optname`, `optval_ptr`, `optlen` | 0 or `-errno`; `SO_REUSEADDR`/`SO_NONBLOCK`/`TCP_NODELAY` set/clear bit in row's so_flags slot (informational MVP -- no bind-collision or blocking-recv semantics change today). R95.M1-001 (paideia-os #2076) landed. |
| 100 | `getpeername` | `fd`, `sockaddr_out` | 0 or `-errno`; writes 8-byte {ip[4] MSB-first, port[4] LE} record; requires state != CLOSED (TCP) or state == CONNECTED (UDP), else `-ENOTCONN`. R95.M2-001 (paideia-os #2078) landed. |
| 101 | `getsockname` | `fd`, `sockaddr_out` | 0 or `-errno`; writes 8-byte {ip[4], port[4]} record; for an unbound socket, ip fills from `_ipv4_my_ip` (single-interface tree) and port stays 0. R95.M2-002 (paideia-os #2079) landed. |
| 102 | `poll` | `fds_ptr`, `nfds`, `timeout_ms` | nready or `-errno`; fixed-size `fds` array (nfds cap 32, stride 8 bytes per Linux `pollfd`); `POLLIN`/`POLLOUT`/`POLLERR` readiness across TCP/UDP sockets. `nready > 0` or `timeout_ms == 0` short-polls without blocking; else registers waiter and calls `sched_block`. R95.M3-001 (paideia-os #2080) landed. R95.M3-002 (#2081) wired `poll_wake_check_and_clear` into `udp_socket_deliver_dgram`; TCP RX wake deferred (see round-retro). |
| 103 | `icmp_echo` | `dst_addr_ptr`, `seq`, `payload_ptr`, `payload_len`, `timeout_ms` | rtt_ns (>=0) or `-errno`; requires R_NET_PRIVILEGED_PROTOCOL (kernel-side check via `cap_check_r_net_privileged_protocol`). Loopback (dst 127.x.x.x or `_ipv4_my_ip`) is synchronous through the ICMP send path; off-box wire dispatch deferred pending real ARP + wait-for-reply plumbing. R100-PREP-003 (paideia-os #2009). |
| 104 | `pdxfs_txn_commit` | `cap_slot` | 0 or `-errno` / sentinel; commits the KIND_PDXFS_TXN behind `cap_slot` (writes JOP_COMMIT + BD_OP_FLUSH via `pdxfs_txn_commit_wal`, transitions OPEN → COMMITTED via `pdxfs_txn_row_transition`, bumps `PXT_ST_COMMITS`). `-EBADF` on a bad cap slot; underlying journal / transition sentinels forwarded verbatim. Row release + cap-slot clear are DEFERRED to a future `sys_pdxfs_txn_close`. R90-XREPO.010.M1-003 (paideia-os #2111). |
| 105 | `pdxfs_txn_abort` | `cap_slot` | 0 or `-errno` / sentinel; aborts the KIND_PDXFS_TXN behind `cap_slot` (writes JOP_ABORT via `pdxfs_txn_abort_wal`, transitions OPEN → ABORTED, bumps `PXT_ST_ABORTS`). Per-record undo-body replay DEFERRED to paideia-os #2112 (blocked on this milestone). R90-XREPO.010.M1-003 (paideia-os #2111). |
| 106 | `pdxfs_stat_by_inode` | `inode_no`, `out_stat_ptr` | 0 or `-errno`; populates a 32-byte record at `out_stat_ptr` with `{mode_bits, size_bytes, mtime_ns, ctime_ns}` for the tmpfs inode `inode_no`. `mode_bits` = `S_IFREG\|0o644` (`0x81A4`) for `VNODE_TYPE_REG`, `S_IFDIR\|0o755` (`0x41ED`) for `VNODE_TYPE_DIR`. `mtime_ns` = `_tick_count * 10_000_000` (matches UEJ convention). `ctime_ns` reserved zero. `-EFAULT` on bad `out_stat_ptr`; `-ENOENT` on OOR `inode_no` or unallocated slot. Blocks 3 of 6 columns in `ls -l` (mode/size/mtime). R90-XREPO.010.M1-002 (paideia-os #2110). |
| 107 | `pdxfs_undo_write` | `cap_slot`, `inode_no`, `offset`, `len`, `kbuf_ptr` | 0 or `-errno`; stages a pre-image snapshot (`[offset, offset+len)` of `inode_no`) into the KIND_PDXFS_TXN row named by `cap_slot`. Must be called BEFORE the corresponding mutation; on `sys_pdxfs_txn_abort` (sysno 105) the substrate replays every staged record in reverse order to restore each pre-image. Length bound `0 < len <= 4064`; per-row cap 32 records / 4 KiB. `-EBADF` on a bad cap slot; `-EINVAL` if the row is not OPEN or the substrate refuses (len bounds); `-ENOSPC` on per-row buffer or record-cap exhaustion. Body takes a KERNEL VA for `kbuf_ptr`: the dispatch shim performs the KPTI bounce for user callers (a bounded per-call kernel scratch), boot witnesses pass a `.rodata` pointer directly. Undo records live in kernel `.bss` at this landing — crash between undo_write and abort loses staged pre-images; folding into the PdxFS journal is deferred. Closes the I5 invariant for cp/mv/rm at the syscall layer. R90-XREPO.010.M1-004 (paideia-os #2112). |
| 108 | `display_enumerate` | `out_buf_va`, `out_buf_cap` | count of live display backends, or `-errno`. Writes at most `out_buf_cap/16` 16-byte records `{backend_kind (u64), row_id (u64)}` into `out_buf_va` via a body-owned KPTI-bounced scratch. Total count returned regardless of buffer capacity (POSIX-adjacent -- caller can grow buf and re-call). `-EFAULT` on bad `out_buf_va` (null pointer or walker fault). `-EINVAL` on `out_buf_cap % 16 != 0`. R105.M1-001 (paideia-os R105 landing). |
| 109 | `framebuffer_create` | `backend_cap_slot`, `width`, `height`, `fmt` | fresh KIND_FRAMEBUFFER cap_slot in [0..255] or `-errno`. Resolves `backend_cap_slot` -> KIND_DISPLAY_BACKEND row (kind gate); mints a transient KIND_MEMORY parent at cap slot 132, calls `kind_framebuffer_mint_simple`, publishes the resulting fb row_id into a fresh cap_table slot with rights = `R_FB_MAP` (0x001) only (per `design/graphics/authority-boundary.md`). `-EBADF` on bad backend cap; `-EINVAL` on `fmt != FB_FMT_BGRA8888` (1); `-ENOSPC` on full cap_table; `-EIO` on mint refusal. R105.M2-001 (paideia-os R105 landing). |
| 110 | `framebuffer_map` | `fb_cap_slot`, `user_va`, `len` | mapped kernel LFB VA (nonzero) or `-errno`. Requires `R_FB_MAP` (0x001) on the framebuffer cap. `user_va` and `len` are RESERVED for a future R106 mmap wire-in that maps the LFB into the caller's user PML4; at R105 the compositor consumes the returned kernel VA from ring-0. `-EBADF` on kind mismatch; `-EACCES` on missing R_FB_MAP; `-EIO` on lfb_va read failure (0 or decode-bad sentinel from `fb_row_lfb_va`). R105.M2-002 (paideia-os R105 landing). |
| 111 | `page_flip` | `pgfl_cap_slot`, `target_fb_slot_hint` | 0 or `-errno`. NON-BLOCKING submit against a KIND_PAGE_FLIP cap. Requires `R_FLIP_INVOKE` (0x001). Delegates to `pgfl_submit`. The `target_fb_slot_hint` arg is repurposed as the flip's pending_fb_slot; a params-block-ptr shape arrives with R106 once KIND_MODESET_TXN's atomic-commit path is wired. `-EBADF`, `-EACCES`, `-EAGAIN` (in-flight -- retry after a wait), `-EIO`. R105.M3-002 (paideia-os R105 landing). |
| 112 | `page_flip_wait` | `pgfl_cap_slot`, `timeout_ms` | 0 or `-errno`. Block the caller until the flip latches. Requires `R_FLIP_INVOKE` (0x001). Poll-then-block loop keyed by `sched_wait(SCHED_WAIT_PAGE_FLIP=2, row_id)`; waker is `pgfl_deliver_vblank` (called by simulated-tick / real-vblank / virtio-gpu completion). `timeout_ms` capped at 256 sched_wait iterations at this landing; a real deadline-scheduled timeout arrives with R106's timer-wheel wire-in. `-EBADF`, `-EACCES`, `-ETIMEDOUT`. R105.M3-003 (paideia-os R105 landing). |
| 113 | `display_hotplug_subscribe` | `hpch_cap_slot` | 0 or `-errno`. Attaches a KIND_HOTPLUG_CHANNEL cap to the HPD fanout. Requires `R_HPCH_SUBSCRIBE` (0x001). At R105 the fanout table IS `_hpch_table`, so the syscall's observable effect is validating the cap; the ISR path (`hotplug_channel_deliver`) iterates over every live row. `-EBADF` on kind mismatch or dangling row; `-EACCES` on missing right. R105.M4-002 (paideia-os R105 landing). |
| 114 | `volume_mint` | `vol_desc_va`, `vol_desc_len` | fresh KIND_VOLUME cap slot in [0..255] or `-errno`. Marshalling shim for the previously kernel-internal `volume_cap_mint_inner` primitive: walks the caller's 40..256-byte volume descriptor via user_ptr_ok + user_read_bytes_via_walk into a body-local scratch, parses `{magic="PDXVDSC1", device_slot, uuid_lo, uuid_hi, backend_kind=1}`, stages a transient KIND_MEMORY parent at cap slot 134, calls `volume_cap_mint_inner`, publishes the resulting row into a fresh cap_table slot with rights = `R_VOL_INVOKE | R_VOL_OBSERVE` (0x408). `-EFAULT` on bad user pointer / walker fault; `-EINVAL` on length OOR / magic mismatch / device_slot >= 256 / backend_kind != 1; `-ENOSPC` on full cap_table; `-EIO` on `volume_cap_mint_inner` refusal (folds `VOL_MINT_BAD_*` / `VOL_REGISTRY_FULL` into a single surface-level `-EIO`). Semantic validation of the superblock lives in libpdx-volume/pdxb_verify_superblock; this handler carries the marshalling only. R90-XREPO.LV11.M2-003 (paideia-os #2225) -- closes the SECTION 0 gap kind_volume.pdx §0 has named since R52.M5-001. |
| **517** | **`cwd_resolve`** | `path_ptr`, `abs_out_ptr`, `abs_out_cap` | strlen (excl. NUL) or `-errno`; realpath primitive for the mv/rm/cp satellite consumers. Resolves the caller's path (absolute OR relative — relative anchors at `[_current_tcb + TASK_OFF_CWD]` per `design/user/cwd-semantics.md`) via `mount_root_vnode` + `path_resolve` + a parent-chain walk composing the canonical absolute form (leading `/`, `_vnode_name_table` components joined by `/`), writing the NUL-terminated result to `abs_out_ptr` (up to `abs_out_cap` bytes). Returns strlen (excluding NUL). Body takes KERNEL VAs (dispatch shim does the KPTI bounce for user callers, matching `sys_pdxfs_undo_write`'s split). `-ENOENT` if the path does not resolve or no root mounted; `-ERANGE` if the composed path + NUL exceeds `abs_out_cap` or the parent-chain walk exceeds `SYS_CWD_RESOLVE_MAX_DEPTH=32`; `-EFAULT` (dispatch-shim only) if either user pointer is refused. The `path_len_hint` field the earlier design skeleton proposed was dropped — the walker sizes the path via NUL. R90-XREPO.010.M1-007 (paideia-os #2115). |
| **527** | **`pdxfs_fault_inject`** | `class` | 0 or `-errno`; arms/disarms a PdxFS fault-injection class. `class` = 0 disarms; 1..4 arm one of `WAL_WRITE_FAIL` / `INODE_ALLOC_FAIL` / `EXTENT_ALLOC_FAIL` / `UNDO_APPEND_FAIL`. Single-shot: the arm is consumed by the next traversal of the named hook site (`wal_append` / `tmpfs_inode_alloc` / `tmpfs_write` pre-`phys_alloc` / `pdxfs_txn_undo_append`). Refused with `-EPERM` when the boot flag `_pdxfs_fault_enabled` is 0 (release-build gate; see `design/kernel/pdxfs-fault-inject.md` §3), refused with `-EINVAL` when class > 4. Dispatch is an explicit early check ahead of the linear switch bounds gate — the sysno sits far above the 0..107 core range, chosen out-of-band by the mv/rm design docs to preserve the tightly-packed low band. R90-XREPO.010.M1-005 (paideia-os #2113). |

Syscalls 96 and 97 (`sendto` / `recvfrom`) LANDED in R93.M2-004
(paideia-os #2052) per the table rows above. Sysnos 98..102 (the
socket option/name/poll block) landed in R95 (paideia-os
#2076..#2080); the R95 landing is documented per row above and in
`design/round-retrospectives/r95-closed.md`. Sysno 103
(`sys_icmp_echo`) landed in R100-PREP-003.

Sysnos **517** and **527** are **out-of-band** allocations by the
R90-XREPO.010 wave (`design/round-retrospectives/r90-xrepo-wave3-plan.md`
§2). Both slot numbers were chosen above the tightly-packed 0..103 core
range so no future contiguous allocation displaces them. Sysno 517
(`sys_cwd_resolve`) is the mv/rm/cp satellite consumers' realpath
primitive; the cwd resolution semantics are frozen (Option A) by
`design/user/cwd-semantics.md`, and the body landed with
R90-XREPO.010.M1-007 (paideia-os #2115). Sysno 527
(`sys_pdxfs_fault_inject`) landed with R90-XREPO.010.M1-005.

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

Sysno 107 (`sys_pdxfs_undo_write`) occupies the first slot above
`sys_pdxfs_stat_by_inode` (106) under the same rule — contiguous-with-
last-allocated inside the linear switch chain, the 96–102 R91–R99
reservation intact. Grouped by role with the txn lifecycle (open/commit/
abort/undo_write) in `design/kernel/pdxfs-syscalls.md` §3, dispatched
contiguously with sysno 106 in the switch. The 5-argument body is the
first PdxFS handler that takes more registers than the 3-arg SysV shim
family (`sys_open` / `sys_read` / `sys_stat`); the dispatch shim
handles the KPTI bounce for the user `kbuf_ptr` and shuffles all five
args into SysV order before the body call.

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
- #2003 (R90-XREPO.009) — first refresh through sysno 95.
- #2009 (R100-PREP-003) — sys_icmp_echo (sysno 103).
- #2076..#2085 (R95) — socket API polish + poll block (sysnos 98..102)
  plus R_SOCKET_READ/WRITE/LISTEN/CONNECT rights bits threaded through
  every socket handler. See
  `design/round-retrospectives/r95-closed.md`.
- #2043..#2059 (R93) — DHCP client + UDP socket integration + DNS
  resolver stub + boot witness. See
  `design/round-retrospectives/r93-closure.md`. #2052 landed sysnos
  96 (`sendto`) and 97 (`recvfrom`); other issues in the wave carry
  no new sysnos.
- #2109..#2116 (R90-XREPO.010) — the R42 PdxFS syscall substrate wave.
  #2109 landed the KIND_PDXFS_FILE `PFF_OP_READ_BYTES` op (cap-invoke
  path; no new sysno). #2110 landed sysno 106
  (`sys_pdxfs_stat_by_inode`). #2111 landed sysnos 104 / 105
  (`sys_pdxfs_txn_commit` / `sys_pdxfs_txn_abort`). #2112 landed sysno
  107 (`sys_pdxfs_undo_write`). #2113 landed sysno 527
  (`sys_pdxfs_fault_inject`). #2114 landed the real multi-entry
  readdir body on sysno 72 (existing sysno; no new number). #2115
  landed sysno 517 (`sys_cwd_resolve`) body — the witness stays
  partial pending a follow-on fix (see #2115 open state). #2116 is
  this refresh.
- R105 (paideia-os R105 landing) — the GUI syscall block.
  `sys_display_enumerate` (108), `sys_framebuffer_create` (109),
  `sys_framebuffer_map` (110), `sys_page_flip` (111),
  `sys_page_flip_wait` (112), `sys_display_hotplug_subscribe` (113).
  Co-lands KIND_PAGE_FLIP (0x1B0) and KIND_HOTPLUG_CHANNEL (0x1B1).
  See `design/round-retrospectives/r105-closure.md` and
  `design/graphics/authority-boundary.md`.
- R90-XREPO.LV11 (paideia-os #2223 / #2224 / #2225) — the libpdx-
  volume v1.1.0 kernel-side substrate wave. #2223 landed KIND_VOLUME_
  SNAPSHOT (0x1B3, cap-only, no new sysno); #2224 landed KIND_KEK
  (0x1B4, cap-only, no new sysno); #2225 landed `sys_volume_mint`
  (sysno 114) as the first slot above the R105 GUI block. The bounds
  check widened from 113 to 114 in the same edit. See
  `src/kernel/core/cap/kind_volume_snapshot.pdx`,
  `src/kernel/core/cap/kind_kek.pdx`, and
  `src/kernel/core/syscall/handlers/sys_volume_mint.pdx` for the
  landing details.
- `design/kernel/pdxfs-syscalls.md` — consolidated PdxFS syscall
  reference produced by #2116.
- `design/round-retrospectives/r90-xrepo-010-substrate-live.md` —
  R90-XREPO.010 round-close retrospective.
- `design/networking/r91-plan.md` §17 — reservation of 96–102 for the
  R91–R99 networking wave (sendto/recvfrom/getsockopt/setsockopt/
  getpeername/getsockname/poll).
- `design/user/elf-lite-format.md` — user binary format that consumes
  this ABI.
