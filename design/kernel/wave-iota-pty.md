# Wave iota: KIND_PTY real body (paideia-os + pdxterm)

Status: landed. Five items across the paideia-os monorepo and the
pdxterm satellite repo, giving pdxterm a real pty master fd, a real
fork+execve'd shell attached to the slave side, resize, and a byte-level
smoke test -- replacing the prior `sys_cap_invoke` stub.

## ι-01: KIND_PTY kernel capability

`src/kernel/core/cap/kind_pty.pdx` -- `KIND_PTY = 0x1E7` (first free
ordinal above every `pub let ... : u64 = 0x...` allocation found by a
tree-wide grep at landing time; not `0x1D0`, which is already
`KIND_INPUT_SERVER`). Real 32-row pool, 96 bytes/row:
`{master_fd, slave_fd, session_leader_pid, winsize, four ring cursors}`.
Two 8 KiB byte rings (`_pty_ring_m2s`, `_pty_ring_s2m`), 256 bytes/row/
direction, generalising `core/uart/rx_ring.pdx`'s SPSC enqueue/dequeue
idiom with a `row_id * 256` base offset.

MINT (`pty_cap_mint`) is direct-call-only, invoked by `sys_openpty_body`
-- no parent-slot gate, matching `sys_volume_mint`'s posture, since a
pty pair has no pre-existing server capability to derive from. QUERY and
SET_DIMS are cap_invoke-reachable via `src/kernel/core/cap/handlers/
cap_handler_pty.pdx`, wired into `cap/invoke.pdx`'s `cap_invoke_dispatch`
right after the KIND_A11Y_NODE arm. This landing adds three ops beyond
the literal MINT/QUERY/SET_DIMS ask (QUERY_MASTER_FD, QUERY_SLAVE_FD,
QUERY_SESSION_PID, SET_SESSION_PID) because `session_leader_pid` cannot
be populated until AFTER `fork()` returns the child pid -- which happens
after `sys_openpty` has already returned -- so a settable op is required
for the field to ever hold a real value.

Failure taxonomy: `0xFFFFE310..0xFFFFE31F` (verified free by grep at
landing time).

SIGWINCH is not a real signal in this kernel yet (`sys_kill.pdx`'s own
header: only SIGSTOP/SIGCONT exist). `pty_winch_notify(pid)` is an
honest proxy -- it bumps a per-pid pending-resize counter
(`_pty_winch_pending[64]`); `pty_winch_pending_take` is the read-and-
clear consumer a future real signal-dispatch loop wires up. Shipped now,
consumed later, per this tree's usual substrate-then-wire-in posture.

## ι-02: sys_openpty / sys_grantpt / sys_unlockpt

SC+ IDs 122/123/124 (not 117..121: 118 and 119 are already reserved by
other in-flight floor-only landings named in `src/user/syscall_shim.pdx`
and `src/user/ps.pdx`).

- `sys_openpty(rows, cols) -> master_fd | (slave_fd << 8) | (cap_slot << 16)`
  (`src/kernel/core/syscall/handlers/sys_openpty.pdx`). Composes
  `pty_cap_mint` with two `fd_alloc`/`fd_set` calls. fd_table entries for
  a pty fd reuse the existing packed-entry field (`vnode_idx | offset<<16`
  from `fd_table.pdx`) but set bit 15 as a PTY tag -- safe because
  `VNODE_MAX = 256` (fs/vnode_pool.pdx) so a real vfs fd's low-16 field
  never reaches bit 15. Bits `[4:0]` carry `row_id`, bit 5 the side
  (0 = master, 1 = slave). Full unwind on partial failure (master fd
  allocated but slave fails; either fd fails after mint succeeds) so a
  refused `openpty` never leaks a live row or cap.
- `sys_grantpt` / `sys_unlockpt(master_fd) -> 0 | -EBADF`
  (`sys_grantpt.pdx`, `sys_unlockpt.pdx`). Both are honest structural
  no-ops: this kernel has no `/dev/pts` and no per-fd ownership model, so
  there is nothing to grant or unlock. They validate `master_fd` names a
  live PTY-tagged fd on the master side and return `-EBADF` otherwise.

`sys_read.pdx` / `sys_write.pdx` gained a PTY fd phase (inserted right
after the existing `fd_get` decode, before the vfs dispatch): a
PTY-tagged entry routes through `pty_ring_pop` / `pty_ring_push` in a
byte loop instead of `vfs_read`/`vfs_write`, with no offset tracking and
no `fd_set` writeback. Direction: master reads what the slave wrote
(`dir = 1 - side` on read) and writes what the slave will read
(`dir = side` on write); both loops stop early (non-blocking partial
I/O) on `PTY_RING_EMPTY` / `PTY_RING_FULL`.

## ι-03/ι-04/ι-05: pdxterm satellite

Landed in the `paideia-os/pdxterm` repo, tagged v1.4.0:

- `src/pty_wire.pdx` -- replaced the `sys_cap_invoke` stub with a real
  `sys_openpty` (122) call, then `fork()` + in the child `dup2(slave_fd,
  0/1/2)` + `execve("/bin/sh", ...)`. The parent keeps `master_fd` (and
  `pty_cap`) for I/O and later resize calls.
- `src/pty_resize.pdx` (`Module PtyResize`) -- on a window geometry
  change, calls `sys_cap_invoke(pty_cap, OP_PTY_SET_DIMS, packed)`. The
  kernel-side `SET_DIMS` op stores the new dims and calls
  `pty_winch_notify` against the row's `session_leader_pid` (the forked
  shell's pid, registered via `OP_PTY_SET_SESSION_PID` right after
  `fork()` returns).
- `tests/pty_output_smoke.pdx` -- forks + execve's `echo hello` through
  a real pty pair, reads the master fd, and asserts `"hello\n"` lands in
  the scrollback ring's head slot.

## Encoder pitfalls hit / avoided

Every file in this wave follows `feedback_pdx_encoder_pitfalls`: no
`test rN, rN`, no 2-op `imul r, imm`, no `and reg, imm64` (large masks
staged through a register first), no `cmp reg, [mem]`, no reserved-
keyword labels (all prefixed `pty_` / `pth_` / `sys_openpty_` /
`sys_read_pty_` / `sys_write_pty_`), module basenames matching file
stems, and every 64-bit sentinel compare staged via `mov r10, imm64` +
`cmp reg, r10`.
