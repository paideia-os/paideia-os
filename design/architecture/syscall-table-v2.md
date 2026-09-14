# ξ-02: SC+ Syscall Table — Capability-Gate Cross-Reference

## 0. What this document is

This is **ξ-02** in the architecture-doc wave that also produced
**ξ-01** (`design/architecture/kernel-cap-taxonomy.md`, the closed
16-kind base enum + derived-kind lattice) and **ξ-05**
(`design/architecture/security-model-overview.md`, the capability
model as designed vs. as it exists today). All three may be read
independently; this one is narrowly the syscall-table cross-reference
the other two cite.

`design/user/syscall-table.md` is the **frozen ABI source of truth**:
sysnos, argument slots (rdi/rsi/rdx/r10/r8/r9), and return-value
semantics for every syscall 0-116 plus the out-of-band sysnos 517
(`cwd_resolve`) and 527 (`pdxfs_fault_inject`). This document does
**not** repeat that file's prose — exact arg names, per-field return
semantics, and historical numbering rationale live there and only
there. What this document adds is the one column `syscall-table.md`
does not track at all: **which capability KIND (if any) gates each
syscall**, verified against `src/kernel/core/syscall/dispatch.pdx`
(the dispatch switch) and the handler files it calls into, versus
which syscalls run on **ambient authority** — reachable by any task
holding a valid fd, pid, or path string, with no `cap_table` lookup
anywhere on the path.

Every row below was checked against source, not inferred from a
sibling row's shape. Where a gate is real but unconfirmed against a
specific handler, or where a comment describes a *planned* gate that
is not wired yet, the table says so explicitly rather than guessing a
KIND.

**Correction to a prior draft of this document and to ξ-05 §2 as
currently published:** both describe the entire BSD-socket surface
(87-102, 96-97) as ambient with "no cap-table lookup at dispatch at
all." That is **not what the handler files show**. See §5 below —
the socket family's `fd` argument is, for every TCP/UDP syscall,
literally the `cap_table` slot index (`tcp_socket_resolve(cap_slot,
want_kind)` in `src/kernel/core/net/tcp_socket.pdx:259-283` indexes
`cap_table` directly by the value the syscall calls `fd`), and most
of the family checks a specific `R_SOCKET_*` rights bit on top of the
kind match. This is flagged again in §7 (Open gaps) as a needed
reconciliation with ξ-05.

## 1. Calling convention (brief — see `syscall-table.md` for the full statement)

| Register | Role |
|---|---|
| `rax` | syscall number in, return value out |
| `rdi`, `rsi`, `rdx`, `r10`, `r8`, `r9` | args 0-5 |
| `rcx`, `r11` | clobbered by `SYSCALL`/`SYSRET`; not usable as arg slots |

No arguments on the stack. Return: non-negative on success, negative
errno on failure (§6). All other GP registers preserved.

## 2. Capability-gate column: how to read it

- **`none — ambient (fd/pid/path)`** — the handler performs zero
  `cap_table` lookups. Any task that can name the syscall number and
  a valid fd/pid/path string can invoke it.
- **`KIND_X (0xNN), rights 0xNN`** — the handler resolves a caller
  argument (a cap slot, or an fd that IS a cap slot — see §5) against
  `cap_table`, requires descriptor `kind == KIND_X`, and requires
  `(rights & required) == required`. Cited to the exact resolver
  function and line.
- **`mints KIND_X`** — the syscall does not check an incoming cap; it
  allocates a fresh `cap_table` slot and writes a new descriptor into
  it (the "root mint, no parent authority" pattern `sys_open` and
  `sys_socket` share).
- **`capability-gated (body-resolved)`** — the dispatch shim performs
  no cap check; the handler body does its own `cap_table` walk
  in-line, confirmed by reading the handler file.
- **`planned, not wired`** — a comment in the handler or dispatch
  names a future capability gate (a specific `KIND_X` + rights), but
  the code path that would enforce it does not exist yet. Treated as
  ambient for the tally in §5 until it lands.

## 3. Full syscall table

| # | Name | Arity | Effect (one clause) | Capability gate | Landing (abbreviated) |
|---|------|-------|----------------------|------------------|------------------------|
| 0 | `read` | 3 | read bytes from fd | none — ambient (fd table) | R17-M0-668 #668; KPTI bounce R16-M3 #738 |
| 1 | `write` | 3 | write bytes to fd (fd∈{1,2} fast-paths to UART) | none — ambient (fd table) | #668; #734 |
| 2 | `open` | 3 | open path, allocate fd | none — ambient (path resolution) | #668 |
| 3 | `close` | 1 | close fd | none — ambient (fd table) | #668 |
| 4 | `cap_invoke` | 2 | op-defined, dispatches on the invoked cap's own kind | **per-kind, resolved inside `cap_invoke` itself** — not a fixed KIND_X at this shim | retained from R13 |
| 12 | `debug_puts` | 2 | emit to kernel debug channel | none — ambient (bypasses fd routing) | R13 |
| 13 | `dmesg` | 2 | copy klog ring tail to user buf | none — ambient (klog read) | logging-m9-002 #709 |
| 32 | `dup2` | 2 | duplicate fd | none — ambient (fd table) | #668 |
| 39 | `getpid` | 0 | return current pid | none — ambient (inline TCB read) | #668 |
| 40 | `ipc_recv` | 4 | blocking receive on an endpoint | **KIND_IPC_ENDPOINT (5)**, rights `0x09` (R_IPC_READ\|R_IPC_INVOKE) via `ipc_slot_to_endpoint` (dispatch.pdx:343-384) | R20b.M3-001 #1558; cap-slot resolve wired R20b.M6-002 #1565 |
| 41 | `ipc_reply` | 4 | reply on an endpoint (bit-7 pre-check, tail into send) | **KIND_IPC_ENDPOINT (5)**, rights `0x0A` (R_IPC_WRITE\|R_IPC_INVOKE) | R20b.M3-002 #1559 |
| 42 | `ipc_send` | 4 | send on an endpoint | **KIND_IPC_ENDPOINT (5)**, rights `0x0A` | #1559 |
| 43 | `svc_lookup` | 2 | resolve a service name to an endpoint | none required on input; **mints** a KIND_IPC_ENDPOINT cap into a free slot — deliberately NOT routed through `ipc_slot_to_endpoint` (dispatch.pdx:259-262) | R20b.M3-003 #1560 |
| 56 | `fork` | 0 | clone the calling task | none — ambient | #668 |
| 59 | `execve` | 3 | replace image (path→copy-in→ELF load) | none — ambient (path-based) | R17-M0-671 #671 |
| 60 | `exit` | 1 | terminate calling task (never returns) | none — ambient | R17-M0-724-D2 #724 |
| 61 | `wait4` | 4 | reap a child, blocking if none zombie | none — ambient (parent/child pid relation) | R17-M0-724-D5a #724 |
| 66 | `clock_read_ns` | 0 | HPET nanoseconds since boot | none — ambient | #1582 part A |
| 67 | `sched_setaffinity` | 1 | write TCB cpu-mask field | none — ambient (TCB field write) | #1582 part B; **not tabulated as its own row in `syscall-table.md`'s table** — only in its prose References list |
| 68 | `sched_getaffinity` | 0 | read TCB cpu-mask field | none — ambient (TCB field read) | #1582 part B; same tabulation gap |
| 69 | `reserve_lpe_class` | 1 | claim the global LP-E reservation for a pid | none — ambient (global reservation) | #1582 part B; same tabulation gap |
| 70 | `pdxfs_txn_open` | 4 | mint a KIND_PDXFS_TXN | `parent_slot` gated as **KIND_MEMORY** carrying `RIGHT_MINT` — CONFIRMED, `sys_pdxfs_txn_open.pdx:14,36` (`PXT_MINT_BAD_PARENT` on mismatch) | R42-PREP-007 #1629 |
| 71 | `pdxfs_open` | 2 | mint a KIND_PDXFS_FILE | `parent_slot` gated as **KIND_MEMORY** carrying `RIGHT_MINT` — CONFIRMED, `sys_pdxfs_open.pdx:8,23` | R42-PREP-008 #1630 |
| 72 | `pdxfs_dir_readnext` | 2 | advance a directory cursor | `dir_cap_slot` gated as a held **KIND_PDXFS_FILE** cap in DIR posture — CONFIRMED, `sys_pdxfs_dir_readnext.pdx:16,23-26` | #1630 |
| 74 | `blkdev_cap_request` | 1 | resolve `bdev_id` against `_blkdev_index_table` + attestation, mint | none required on input (`bdev_id` is a raw registration key, not a cap slot); body performs an internal attestation check then **mints** a **KIND_BLKDEV (0x42)** cap — CONFIRMED, `src/kernel/core/cap/blkdev_cap_request.pdx:1-40` | R51.M8-001 #1675 |
| 75 | `mount` | 5 | mount a backend at a path | **none — ambient path/string args.** Backend=5 (block) arm resolves a `/dev/pdxvol<hex>` string to a KIND_BLKDEV cap via the volume registry to *locate the device*, but authorizes nothing about the *caller* — any task naming a valid path succeeds. Backend=0 (tmpfs) has no device to gate at all. CONFIRMED, `sys_mount.pdx:388-438` | R53.M2-001 #1736; block-arm devfs bridge R107.M1 #2345 |
| 76 | `umount` | 3 | unmount by mount-point path | **none — ambient.** `sys_umount_body` resolves purely via a linear `_mount_table` scan keyed on the mount-point path; no caller-cap check anywhere in the body. **This corrects a claim in a prior draft of this document** that umount checks a "mount-table entry's originating cap for VOL_RIGHT_UMOUNT" — no such check exists in `sys_umount.pdx` as read. CONFIRMED, `sys_umount.pdx:332-336` (header + justification) | R53.M2-003 #1738 |
| 77 | `stat` | 3 | populate a stat record | none — ambient (path resolution) | R56.M3-001 #1790 |
| 78 | `getdents` | 3 | read directory entries via fd | none — ambient (fd table) today; the file's own effect-row comment names `cap` as "forward-compat for R57+ per-task cap_table (fd_get → cap_get)" — **planned, not wired**, `sys_getdents.pdx:79-81` | #1790 |
| 79 | `mkdir` | 3 | create a directory | none — ambient (path resolution) | #1790 |
| 80 | `rmdir` | 2 | remove an empty directory | none — ambient | #1790 |
| 81 | `unlink` | 2 | remove a directory entry | none — ambient today. Header names `VOL_RIGHT_UNLINK` as a "forward-compat placeholder for a R57+ per-mount ... gate ... no cap op runs today" — **planned, not wired**, `sys_unlink.pdx:74-79` | #1790 |
| 82 | `rename` | 4 | rename within one directory (cross-dir refused `-EXDEV`) | none — ambient today; `VOL_RIGHT_RENAME` is the same kind of forward-compat placeholder as row 81 — **planned, not wired**, `sys_rename.pdx:75-79` | #1790 |
| 83 | `taskinfo` | 2 | fill a 64-byte task-pool record | none — ambient today. The body's own header names a planned dispatch-shim gate ("KIND_TASKINFO with R_INTROSPECT rights BEFORE the body is called") — CONFIRMED NOT WIRED: `dispatch_taskinfo` in `dispatch.pdx` does a `user_ptr_ok` check and calls `sys_taskinfo_body` directly, no kind check anywhere in the shim. **Planned, not wired.** `sys_taskinfo.pdx:89-93` | R57.M4-003 #1799; record widened #1817 |
| 84 | `mountinfo` | 2 | fill a 32-byte mount-table record | none — ambient today; same pattern as row 83 — the header explicitly labels `KIND_MOUNTINFO` a "**future** capability gate ... symmetric to the planned KIND_TASKINFO gate" — **planned, not wired**, `sys_mountinfo.pdx:161-166` | R57.M4-004 #1800 |
| 85 | `chdir` | 2 | mutate `TASK_OFF_CWD` | none — ambient | R86.M1-002 #1955 |
| 86 | `getcwd` | 2 | read `TASK_OFF_CWD` | none — ambient | R86.M1-003 #1956 |
| 87 | `socket` | 3 | allocate a TCB + mint a socket cap | none required on input (root mint, mirrors `open`'s no-authority posture); **mints KIND_TCP_SOCKET (0x1AB)**, default rights `0x00F` (LISTEN\|READ\|WRITE\|CONNECT) — CONFIRMED, `sys_socket.pdx:81-118`. The returned "fd" **is** the `cap_table` slot number — see §5. | R72.M1-005 #1927 |
| 88 | `bind` | 2 | bind local port | fd resolved as **KIND_TCP_SOCKET (0x1AB)** or **KIND_UDP_SOCKET (0x1A8)** via `tcp_socket_resolve`; requires **R_SOCKET_LISTEN (0x004)**; binding to port < 1024 additionally requires **R_NET_PRIVILEGED_PORT (0x010)** via `sock_cap_check_rights` — CONFIRMED, `sys_bind.pdx:55,102-143` | #1927; port gate R96.M4-001 #2092 |
| 89 | `listen` | 2 | mark socket listening, retag cap | same kinds; requires **R_SOCKET_LISTEN (0x004)**; on success retags the cap in place to **KIND_TCP_LISTENER (0x1AC)** via `tcp_socket_retag_listener` | R95.M4-001 #2083 |
| 90 | `accept` | 1 | accept a pending connection | fd resolved as **KIND_TCP_LISTENER (0x1AC)**; requires **R_SOCKET_LISTEN**; on success **mints** a child **KIND_TCP_SOCKET** cap over the accepted TCB — CONFIRMED, `sys_accept.pdx:28,37` | #1927; blocking path R94.M4-001 #2068 |
| 91 | `connect` | 3 | initiate/complete a connection | same kinds; requires **R_SOCKET_CONNECT (0x008)** | #2083 |
| 92 | `send` | 3 | send on a connected socket | same kinds; requires **R_SOCKET_WRITE (0x002)** | #2083 |
| 93 | `recv` | 3 | receive from a connected socket | same kinds; requires **R_SOCKET_READ (0x001)** | #2083 |
| 94 | `shutdown` | 2 | half/full-close | KIND_TCP_SOCKET; requires **R_SOCKET_WRITE (0x002)** (even for `SHUT_RD`) | #2083 |
| 95 | `kill` | 2 | deliver SIGSTOP/SIGCONT only (MVP) | none — ambient, pid-keyed | R73.M1-001 #1938 |
| 96 | `sendto` | 5 | send with an explicit per-call peer | KIND_TCP_SOCKET or KIND_UDP_SOCKET via `tcp_socket_resolve`; requires **R_SOCKET_WRITE (0x002)** | R93.M2-004 #2052 |
| 97 | `recvfrom` | 5 | receive with peer-address out-params | same kinds; requires **R_SOCKET_READ (0x001)** | #2052 |
| 98 | `getsockopt` | 5 | read a socket option | KIND_TCP_SOCKET/KIND_UDP_SOCKET gate only — **no R_SOCKET_\* rights bit required** beyond holding the socket cap | R95.M1-002 #2077 |
| 99 | `setsockopt` | 5 | set a socket option | same kind gate; header states explicitly "setsockopt does not require any of the R_SOCKET_\* bits at this landing" — CONFIRMED, `sys_setsockopt.pdx:41-43` | R95.M1-001 #2076 |
| 100 | `getpeername` | 2 | read remote {ip,port} | kind gate only, no rights bit | R95.M2-001 #2078 |
| 101 | `getsockname` | 2 | read local {ip,port} | kind gate only, no rights bit; does not even gate on connection state (unbound socket is a legal callee) | R95.M2-002 #2079 |
| 102 | `poll` | 3 | compute readiness across up to 32 fds | kind gate only (a non-socket fd yields `revents=0`, not an error), no rights bit; may block via `sched_block` | R95.M3-001 #2080 |
| 103 | `icmp_echo` | 5 | send one ICMP echo, return rtt_ns | **`R_NET_PRIVILEGED_PROTOCOL` (0x1000)**, checked via `cap_check_r_net_privileged_protocol` — **but this is NOT a `cap_table` lookup.** The "gate" is a hardcoded allow-list: `task_ptr == 0` (boot context) OR the caller's pid `== 1` (init); every other pid is refused `-EPERM`. Named like a capability right, implemented as a pid allow-list pending the libpdx-elevate broker wire-in. CONFIRMED, `src/kernel/core/cap/cap_net_privileged.pdx:21-30,57` | R100-PREP-003 #2009 |
| 104 | `pdxfs_txn_commit` | 1 | commit a transaction | `cap_slot` gated as **KIND_PDXFS_TXN** via `pdxfs_txn_row_of_slot`; bad slot/kind → `-EBADF` — CONFIRMED, `sys_pdxfs_txn_commit.pdx:111,118` | R90-XREPO.010.M1-003 #2111 |
| 105 | `pdxfs_txn_abort` | 1 | abort a transaction | `cap_slot` gated as **KIND_PDXFS_TXN**, same resolver | #2111 |
| 106 | `pdxfs_stat_by_inode` | 2 | populate a 32-byte stat record | none — ambient, keyed by a raw `inode_no` — CONFIRMED, no `KIND_` reference anywhere in `sys_pdxfs_stat_by_inode.pdx` | R90-XREPO.010.M1-002 #2110 |
| 107 | `pdxfs_undo_write` | 5 | stage a pre-image undo record | `cap_slot` gated as **KIND_PDXFS_TXN**; row must additionally be in OPEN state — CONFIRMED, `sys_pdxfs_undo_write.pdx:102` | R90-XREPO.010.M1-004 #2112 |
| 108 | `display_enumerate` | 2 | enumerate live display backends | none — ambient enumeration of `KIND_DISPLAY_BACKEND` rows; caller presents no cap | R105.M1-001 |
| 109 | `framebuffer_create` | 4 | mint a framebuffer over a backend | `backend_cap_slot` gated as **KIND_DISPLAY_BACKEND (0x1AE)**; on success **mints KIND_FRAMEBUFFER (0x1AF)**, rights = `R_FB_MAP` only — CONFIRMED, `sys_framebuffer_create.pdx:37-46,82` | R105.M2-001 |
| 110 | `framebuffer_map` | 3 | return the mapped LFB kernel VA | **KIND_FRAMEBUFFER (0x1AF)**, requires `R_FB_MAP (0x001)` — CONFIRMED, `sys_framebuffer_map.pdx:15,49` | R105.M2-002 |
| 111 | `page_flip` | 2 | non-blocking flip submit | **KIND_PAGE_FLIP (0x1B0)**, requires `R_FLIP_INVOKE (0x001)` — CONFIRMED, `sys_page_flip.pdx:5,53` | R105.M3-002 |
| 112 | `page_flip_wait` | 2 | block until flip latches | **KIND_PAGE_FLIP (0x1B0)**, requires `R_FLIP_INVOKE` — CONFIRMED, `sys_page_flip_wait.pdx:5,49` | R105.M3-003 |
| 113 | `display_hotplug_subscribe` | 1 | attach to the HPD fanout | **KIND_HOTPLUG_CHANNEL (0x1B1)**, requires `R_HPCH_SUBSCRIBE (0x001)` — CONFIRMED, `sys_display_hotplug_subscribe.pdx:5,46` | R105.M4-002 |
| 114 | `volume_mint` | 2 | mint a volume cap from a descriptor | none required on input — CONFIRMED: the descriptor's `device_slot` field is bounds-checked `< 256` only (`sys_volume_mint.pdx:232-233`), never looked up in `cap_table` or checked for `KIND_BLOCK_DEVICE`, despite the file's own field-comment aspirationally naming it a cap slot. Stages a transient KIND_MEMORY parent, then **mints KIND_VOLUME (0x1A0)**, rights `R_VOL_INVOKE\|R_VOL_OBSERVE` (`0x408`) | R90-XREPO.LV11.M2-003 #2225 |
| 115 | `semantic_send` | 3 | write a record into the global semantic ring | none — ambient; writes into `_semantic_ring`, schema opaque to the kernel; producer-only landing | R107-M0-001 #2350 |
| 116 | `sched_wait_ns` | 1 | block via timer-wheel for `ns` | none — ambient timer-wheel primitive | COMP-IMPL-07 (Wave UUU) |
| **517** | `cwd_resolve` | 3 | realpath a path via the caller's stored cwd | none — ambient (TCB `TASK_OFF_CWD` + path walk); out-of-band sysno, pre-bound early check (§4) | R90-XREPO.010.M1-007 #2115 |
| **527** | `pdxfs_fault_inject` | 1 | arm/disarm a PdxFS fault-injection class | **not a capability gate at all** — refused `-EPERM` when the boot flag `_pdxfs_fault_enabled` is 0 (a release-build posture switch, not a per-caller authority check); out-of-band sysno, pre-bound early check (§4) | R90-XREPO.010.M1-005 #2113 |

## 4. Bounds-check widening history

The dispatch switch's upper bound has widened every time a new
contiguous sysno block landed — from 61 (the R13 preflight baseline)
through the present 116, in the sequence `dispatch.pdx`'s own inline
comments record verbatim (lines 393-551): 61→69 (#1582, time/affinity
block) → 70 (#1629, `pdxfs_txn_open`) → 72 (#1630, `pdxfs_open` +
`pdxfs_dir_readnext`) → 74 (#1675, `blkdev_cap_request`, 73
deliberately skipped) → 76 (R53.M2-001 #1736, `mount`/`umount`) → 82
(R56.M3-001 #1790, VFS metadata block) → 83 (#1799, `taskinfo`) → 84
(#1800, `mountinfo`) → 86 (R86.M1 #1955/#1956, `chdir`/`getcwd`) → 94
(R72.M1-005 #1927, TCP socket block) → 95 (R73.M1-001 #1938, `kill`)
→ 103 (R100-PREP-003 #2009, `icmp_echo`; 96-102 stay reserved and are
filled by the R95 socket-option block within the existing bound) →
105 (R90-XREPO.010.M1-003 #2111, PdxFS txn commit/abort) → 106
(#2110, `pdxfs_stat_by_inode`) → 107 (#2112, `pdxfs_undo_write`) → 114
(R90-XREPO.LV11.M2-003 #2225, `volume_mint`, absorbing the R105 GUI
block 108-113 which had already widened the bound in its own landing)
→ 115 (#2350, `semantic_send`) → 116 (COMP-IMPL-07, `sched_wait_ns`).
Current: `cmp rdi, 116; ja dispatch_enosys` (`dispatch.pdx:550-551`).

The out-of-band sysnos 517 and 527 are **explicitly not folded into
this bound**: widening it to 527 would collapse the entire 108..526
reserved gap into linear switch fall-through. Instead, two early
checks precede the bounds gate (`dispatch.pdx:501-504`):

```
cmp rdi, 517; je dispatch_cwd_resolve;
cmp rdi, 527; je dispatch_pdxfs_fault_inject;
```

ordered ascending to match the rest of the chain's discipline. Every
widening comment in the file also notes which `tools/verify-syscall-
dispatch.sh` fingerprint check (the `cmp.*0x3d` grep for `wait4`, sysno
61) stays untouched by the change — the pre-bound checks and every
widening land without a fingerprint-gate rewrite.

## 5. Ambient authority vs. capability-native: the socket-family correction

Counting the ~120 defined syscalls in §3 (0-116 minus the unclaimed
gaps, plus 517/527):

- **Capability-gated, confirmed:** the IPC family (40-43, with 43 a
  mint rather than a check), the PdxFS constructor/transaction family
  (70-72, 104-105, 107), the R105 GUI block (109-113), `volume_mint`'s
  *output* posture (114 mints but does not check an input cap), and
  the **entire socket family that resolves through `tcp_socket_resolve`**
  — `bind`/`listen`/`accept`/`connect`/`send`/`recv`/`shutdown`/
  `sendto`/`recvfrom`/`getsockopt`/`setsockopt`/`getpeername`/
  `getsockname`/`poll` (88-94, 96-102). That is roughly 27 syscalls.
- **Named as a capability right but not actually `cap_table`-gated:**
  `icmp_echo` (103) — `R_NET_PRIVILEGED_PROTOCOL` is a pid allow-list,
  not a cap lookup. Counted separately below rather than folded into
  either bucket.
- **Ambient, confirmed (zero `cap_table` touch on the syscall's own
  path):** the legacy POSIX-shaped core (0-3, 32, 39, 56, 59-61), the
  time/affinity block (66-69), `mount`/`umount` (75-76, despite an
  internal device-lookup use of `cap_table` that authorizes nothing
  about the caller), the VFS metadata block (77-82), `chdir`/`getcwd`
  (85-86), `kill` (95), `pdxfs_stat_by_inode` (106),
  `display_enumerate` (108), `semantic_send` (115), `sched_wait_ns`
  (116), `cwd_resolve` (517). `volume_mint`'s *input* posture (114)
  belongs here too (device_slot is never verified). Roughly 25
  syscalls.
- **Planned but not wired (ambient today, comment names a future
  gate):** `getdents` (78), `unlink` (81), `rename` (82), `taskinfo`
  (83), `mountinfo` (84) — 5 syscalls.
- **Flag-gated, not capability-gated:** `pdxfs_fault_inject` (527) —
  a boot-time release/debug posture switch, not a per-caller check.
- `cap_invoke` (4) and `svc_lookup` (43) sit outside this tally: the
  former's gate is fully capability-driven but resolved per-invoked-
  kind rather than against one fixed KIND_X at this shim; the latter
  mints rather than checks.

This roughly-even split between ambient and capability-native is the
same tension `security-model-overview.md` (ξ-05) §2 frames as a real
architectural deviation rather than a documentation gap — see that
section for the narrative (why the legacy core is frozen, why later
additions "follow whichever sibling syscall they extend" rather than
being audited against the newer subsystems' discipline). **The one
correction this pass makes to that narrative:** ξ-05 §2 currently
states the socket surface 87-102 has "no cap-table lookup at dispatch
at all." Per the handler-file evidence in §3 above, that is true only
for `socket` itself (87, a root mint) and for the read-only
introspection calls (`getsockopt`/`setsockopt`/`getpeername`/
`getsockname`/`poll`, which check kind but not rights) — every
send/recv/bind/listen/accept/connect/shutdown/sendto/recvfrom call
resolves its `fd` argument as a literal `cap_table` slot and checks
both `kind` and a specific `R_SOCKET_*` rights bit. See §7.

## 6. Errno table (unchanged from `syscall-table.md`)

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

## 7. Open gaps

- **This document's cap-gate column has no automated check.** Unlike
  `syscall-table.md`'s numbers (guarded by
  `tools/verify-syscall-dispatch.sh`'s fingerprint), nothing regenerates
  §3's gate column when a syscall's gate shape changes. It must be
  hand-refreshed whenever a new syscall lands or an existing gate is
  rewired — there is no substitute for re-grepping the handler.
- **ξ-05 (`security-model-overview.md`) §2 needs reconciling** with
  the socket-family finding in §5 above: its ambient-vs-gated tally
  currently folds 87-102 entirely into the ambient bucket, which this
  pass's handler-file reads contradict for 88-94 and 96-97 (real
  `R_SOCKET_*` rights checks) and partially contradicts for 98-102
  (real kind checks, no rights bit). Whoever next touches ξ-05 should
  re-read this section rather than re-deriving the socket family from
  scratch.
- **Syscalls marked "planned, not wired"** (78 `getdents`, 81
  `unlink`, 82 `rename`, 83 `taskinfo`, 84 `mountinfo`) each carry a
  header comment naming the intended gate (a per-mount `VOL_RIGHT_*`
  for the VFS pair, `KIND_TASKINFO`/`KIND_MOUNTINFO` with
  `R_INTROSPECT` for the introspection pair). None of the five actually
  enforces it today; follow-up work should either wire the gate or
  strip the aspirational comment so a future reader does not mistake
  intent for implementation — this document already made that mistake
  once (see the row-76 `umount` correction in §3).
- **`icmp_echo`'s `R_NET_PRIVILEGED_PROTOCOL`** (103) is a hardcoded
  pid allow-list standing in for a capability right pending the
  libpdx-elevate broker wire-in (`design/tooling/r49-r50-plan.md` §5).
  Not a defect to fix here, but worth flagging so a reader does not
  read "capability gate" in §3 and assume a `cap_table` lookup exists.
- **Sysnos 67-69** (`sched_setaffinity`/`sched_getaffinity`/
  `reserve_lpe_class`) are implemented in `dispatch.pdx` and cited by
  `syscall-table.md`'s own References list (#1582 part B) but have no
  row in `syscall-table.md`'s actual table. This document tabulates
  them from `dispatch.pdx` directly (§3); the frozen ABI doc itself
  should probably grow these three rows in a future refresh, though
  that is `syscall-table.md`'s maintainer's call, not this document's.

## Sources

- `design/user/syscall-table.md` — the frozen ABI: sysnos, arg names,
  return semantics, full numbering rationale (unchanged, not repeated
  here).
- `design/architecture/kernel-cap-taxonomy.md` (ξ-01) — the KIND_*
  base enum and derived-kind numbering this document's gate column
  cites throughout.
- `design/architecture/security-model-overview.md` (ξ-05) — the
  capability model as designed vs. as it exists; §2's ambient-vs-gated
  framing, corrected per §5/§7 above.
- `src/kernel/core/syscall/dispatch.pdx` — the dispatch switch itself;
  every widening milestone and the 517/527 pre-bound checks trace to
  this file's own inline comments (lines 1-551 read in full for this
  pass).
- `src/kernel/core/syscall/handlers/*.pdx` and
  `src/kernel/core/syscall/sys_{mount,umount,stat,getdents,mkdir,
  rmdir,unlink,rename,taskinfo,mountinfo,chdir,getcwd}.pdx` — every
  handler cited by name and line in §3 was opened and grepped for
  `KIND_`/`cap_table`/`R_SOCKET_`/`VOL_RIGHT_` this pass, not assumed
  from a sibling syscall's shape.
- `src/kernel/core/net/tcp_socket.pdx:259-283` —
  `tcp_socket_resolve`, the shared cap-slot-as-fd resolver underlying
  the §5 socket-family correction.
- `src/kernel/core/cap/blkdev_cap_request.pdx`,
  `src/kernel/core/cap/cap_net_privileged.pdx` — the two body-internal
  gates (`blkdev_cap_request`'s attestation table, `icmp_echo`'s pid
  allow-list) that are not ordinary `cap_table` checks.
