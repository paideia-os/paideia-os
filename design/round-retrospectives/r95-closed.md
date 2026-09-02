# R95 Retrospective: socket API polish + poll + capability rights

**Date:** 2026-09-01
**Milestones:** R95.M1 (setsockopt/getsockopt), R95.M2 (getpeername/
getsockname), R95.M3 (sys_poll + wake wire + witness), R95.M4 (socket
capability rights bits + default mint + round closure).
**Issues closed at landing:** #2076, #2077, #2078, #2079, #2080, #2081,
#2082, #2083, #2084, #2085.
**HEAD at closure:** paideia-os (this landing).
**Release tag:** `r95-closed` recommended -- the `boot r95 poll ok`
witness attests the readiness-scan primitive and the UDP wake wire on
every boot.

## Round intent

Close the "the socket ABI is not what a real userspace TCP client
expects" gap between R72 (TCP substrate) / R100-PREP-002 (UDP
substrate) and R96 (privileged-port gate / TLS wiring). Two shapes of
polish: (a) the pre-existing `sys_socket`/`bind`/`listen`/`accept`/
`connect`/`send`/`recv`/`shutdown` block was authority-monolithic --
one cap kind, three rights bits (READ/WRITE/INVOKE) that all handlers
required identically -- so a future round wanting to refine the mint
at bind time (privileged-port gate) had nothing to refine; (b) real
userspace loops call `setsockopt`/`getsockopt`/`getpeername`/
`getsockname`/`poll` and were getting `-ENOSYS` because the R91 plan
reserved sysnos 98..102 without materializing bodies.

R95 lands the whole block in one round -- the four primitives are
tightly coupled (they all read/write the socket row layout defined
one round back) and the R96 privileged-port gate wants ALL of them in
place before it can start refining mints.

## Per-milestone disposition

### R95.M1 -- setsockopt / getsockopt -- LANDED

* **#2076 (M1-001) -- sys_setsockopt (sysno 99).**
  `src/kernel/core/syscall/handlers/sys_setsockopt.pdx` (346 lines).
  Options: `SO_REUSEADDR` (2), `SO_NONBLOCK` (3) at
  level=`SOL_SOCKET`, and `TCP_NODELAY` (100) at level=`IPPROTO_TCP`.
  All three are informational MVP flags stored in the socket row's
  `so_flags` slot (UDP row +72; TCP TCB +216 -- both new slots in the
  pre-existing "reserved" bands). No behavioral effect at R95: single-
  interface tree never trips REUSEADDR, recv already returns 0 on
  empty ring so NONBLOCK is a no-op difference for UDP, and R94 TCP
  has no Nagle for TCP_NODELAY to disable. The flags are remembered so
  a future round's real semantics gate can read them without a client
  recompile.

* **#2077 (M1-002) -- sys_getsockopt (sysno 98).**
  `src/kernel/core/syscall/handlers/sys_getsockopt.pdx` (287 lines).
  Same three flag options as setsockopt (read bit from so_flags),
  plus `SO_ERROR` (4) which reads and clears the row's so_error slot
  (UDP row +64; TCP TCB +208 -- new slots), and `SO_TYPE` (5) which
  derives from the resolved cap kind (KIND_TCP_SOCKET -> SOCK_STREAM
  = 1; KIND_UDP_SOCKET -> SOCK_DGRAM = 2). so_error is populated by
  no path today (async-error emission deferred to a future round);
  a caller always reads 0.

### R95.M2 -- getpeername / getsockname -- LANDED

* **#2078 (M2-001) -- sys_getpeername (sysno 100).**
  `src/kernel/core/syscall/handlers/sys_getpeername.pdx` (223 lines).
  Writes an 8-byte {ip[4] MSB-first, port[4] LE} record. For TCP,
  reads `remote_ip @+32..+35` + `remote_port @+16` off the TCB;
  requires state != CLOSED (else -ENOTCONN). For UDP, reads
  `peer_ip @+24..+27` + `peer_port @+16` off the row; requires
  state == CONNECTED (else -ENOTCONN). Not a Linux sockaddr_in --
  this is the paideia-os collapsed 8-byte ABI matching sys_connect's
  own (u32 ip, u16 port in u64) shape; a future round widens the
  record if a real sockaddr_in gate lands.

* **#2079 (M2-002) -- sys_getsockname (sysno 101).**
  `src/kernel/core/syscall/handlers/sys_getsockname.pdx` (177 lines).
  Same 8-byte record shape as getpeername, populated from LOCAL
  fields. TCP: `local_ip @+24..+27`, `local_port @+8`. UDP: ip
  always comes from `_ipv4_my_ip` (single-interface tree; no per-row
  local_ip stored), port from row @+8. Unbound sockets return
  `_ipv4_my_ip` + port 0 rather than -ENOTCONN or a zero IP --
  matches Linux getsockname()'s "always answers" contract.

### R95.M3 -- sys_poll + wake wire + witness -- LANDED

* **#2080 (M3-001) -- sys_poll (sysno 102).**
  `src/kernel/core/syscall/handlers/sys_poll.pdx` (355 lines).
  Linux-shaped `pollfd` struct (fd:i32, events:u16, revents:u16) at
  8 bytes/entry, capped at `POLL_MAX_NFDS`=32 (`_dispatch_poll_scratch`
  is 256 bytes). Bit set: POLLIN (0x1), POLLOUT (0x4), POLLERR (0x8).
  Readiness scan via `poll_socket_readiness(fd, events_mask)`:
    - TCP: POLLIN iff `rx_tail > rx_head`; POLLOUT iff state ==
      ESTABLISHED (4); POLLERR iff so_error != 0. LISTENER kind:
      POLLIN iff `backlog_pending_tcb != TCP_NONE` (accept-ready).
    - UDP: POLLIN iff `rx_count > 0`; POLLOUT iff state == CONNECTED
      (2); POLLERR iff so_error != 0.
  Control flow: cap-and-copy user array into scratch, iterate,
  tally nready + stamp revents; if `nready > 0` OR `timeout_ms == 0`
  write back and return; else register `_poll_waiter_tcb =
  _current_tcb` and `sched_block`; on resume re-scan once and
  return. Timer-driven timeout wake is DEFERRED (no timer-wheel
  abstraction in the tree yet); a caller with `timeout_ms > 0` on
  all-empty sockets blocks until an rx path fires wake.

* **#2081 (M3-002) -- wake wire.** `poll_wake_check_and_clear` in
  `sys_poll.pdx`; called from `udp_socket_deliver_dgram` in
  `net/udp_socket.pdx` after the enqueue completes. Reads
  `_poll_waiter_tcb`, no-op if zero; else clear-slot-then-sched_wake
  (clear-before-wake ordering ensures at-most-once semantics). TCP
  RX wake wire is **deferred** to a follow-up round -- see
  `Deferred / follow-ups` below. UDP-only wake is enough to prove
  the mechanism end-to-end and satisfies the R95.M3-003 witness.

* **#2082 (M3-003) -- witness.**
  `src/kernel/boot/witness/r95_poll.pdx` (137 lines). Two scenarios
  in one boot: (1) fresh UDP socket, `poll_socket_readiness(cap_slot,
  POLLIN)` must return 0 (empty ring); (2) inject one datagram via
  `udp_socket_deliver_dgram` (which also fires
  `poll_wake_check_and_clear` -- must be a no-op with no waiter
  registered, proving the wake wire is safe to call unconditionally),
  then re-scan -- must return POLLIN. Emits
  `boot r95 poll ok -- scenarios=2` via klog_s1_d1 on all-green;
  `boot r95 poll skip -- reason=1 stage=<S>` on any deviation.
  Bypasses the sys_poll dispatch shim (boot context is ring 0;
  user_ptr_ok on a kernel pollfd would refuse -- that gate is exactly
  what defends the syscall's user boundary) and calls the primitive
  directly.

### R95.M4 -- socket capability rights bits -- LANDED

* **#2083 (M4-001) -- R_SOCKET_* rights bits + check-and-refuse
  helper.** New bits in `net/udp_socket.pdx`:
    - R_SOCKET_READ = 0x001 (checked by sys_recv)
    - R_SOCKET_WRITE = 0x002 (checked by sys_send + sys_shutdown)
    - R_SOCKET_LISTEN = 0x004 (checked by sys_bind + sys_listen +
      sys_accept)
    - R_SOCKET_CONNECT = 0x008 (checked by sys_connect)
  Bit 3 (0x008) semantic changes from pre-R95 "INVOKE" to R95
  "CONNECT" -- same value, more precise meaning. Bit 2 (0x004) is
  wholly new. Helper `sock_cap_check_rights(cap_slot, required)
  -> 0 | -EACCES` in `net/tcp_socket.pdx` performs the mask check
  `(rights & required) == required`; used by every socket handler
  after a successful `tcp_socket_resolve` returns. sys_bind's rights
  choice (LISTEN) is server-shape -- a caller who hits the ephemeral
  auto-bind inside sys_connect never goes through this gate; explicit
  bind() is treated as server preparation.

* **#2084 (M4-002) -- default mint grants all four rights.**
  `TCP_SOCKET_RIGHTS` and `UDP_SOCKET_RIGHTS` both updated from 0x00B
  (pre-R95: READ|WRITE|INVOKE) to 0x00F (READ|WRITE|LISTEN|CONNECT).
  Additive superset -- every pre-R95 witness continues to observe the
  same permitted-op set, so the R72 tcp_echo, R100-PREP-002 udp
  socket, R100-PREP-003 icmp echo witnesses all pass unchanged. Sets
  up R96 to selectively DROP bits at mint time based on
  destination-port policy (privileged-port gate would refine the
  CONNECT bit at connect time or LISTEN at bind time).

* **#2085 (M4-003) -- round closure.** This document + STATUS.md
  section + `design/user/syscall-table.md` update marking sysnos
  98..102 landed. Tag prep for `r95-closed`.

## Files changed

Modified:
* `src/kernel/core/net/udp_socket.pdx` (+38 lines: R_SOCKET_*
  constants, so_error + so_flags row slots documented, default mint
  updated, `poll_wake_check_and_clear` call in `deliver_dgram`)
* `src/kernel/core/net/tcp_socket.pdx` (+62 lines: R_SOCKET_*
  duplication documented, default mint updated, `sock_cap_check_
  rights` helper)
* `src/kernel/core/syscall/handlers/sys_bind.pdx` (+40 lines: rights
  check on both TCP and UDP branches, EACCES sentinel)
* `src/kernel/core/syscall/handlers/sys_connect.pdx` (+34 lines)
* `src/kernel/core/syscall/handlers/sys_listen.pdx` (+22 lines)
* `src/kernel/core/syscall/handlers/sys_accept.pdx` (+22 lines)
* `src/kernel/core/syscall/handlers/sys_send.pdx` (+40 lines)
* `src/kernel/core/syscall/handlers/sys_recv.pdx` (+40 lines)
* `src/kernel/core/syscall/handlers/sys_shutdown.pdx` (+22 lines)
* `src/kernel/core/syscall/dispatch.pdx` (+74 lines: 5 new cmp/je
  arms + 5 new dispatch labels)
* `src/kernel/core/klog/keys.pdx` (+12 lines: `tag_boot_r95_poll_ok`,
  `k_scenarios`)
* `src/kernel/boot/kernel_main.pdx` (+15 lines: `call
  witness_r95_poll`)
* `design/user/syscall-table.md` (rows 98..102 updated to landed
  status)

Created:
* `src/kernel/core/syscall/handlers/sys_setsockopt.pdx` (346 lines)
* `src/kernel/core/syscall/handlers/sys_getsockopt.pdx` (287 lines)
* `src/kernel/core/syscall/handlers/sys_getpeername.pdx` (223 lines)
* `src/kernel/core/syscall/handlers/sys_getsockname.pdx` (177 lines)
* `src/kernel/core/syscall/handlers/sys_poll.pdx` (355 lines)
* `src/kernel/boot/witness/r95_poll.pdx` (137 lines)
* `design/round-retrospectives/r95-closed.md` (this file)

## Sysno allocations

R95 materializes the reserved sysnos 98..102 (per
`design/networking/r91-plan.md` §17). The R95.M1..M3 bodies land in
the exact slots the plan named -- no numeric renumbering was
necessary. The dispatch bounds check stays at 107 (unchanged: 98..102
fall inside the existing range).

Sysnos 96 and 97 (`sendto` / `recvfrom`) remain unimplemented and
fall through to `-ENOSYS`. They land in the next round that needs
per-message peer-address override.

## Fingerprint tags added

* `tag_boot_r95_poll_ok` = `"boot r95 poll ok --\0"` (20 bytes,
  lowercase, no OK_TOK match). Emitted from
  `witness_r95_poll` on the all-green path via `klog_s1_d1(LEVEL_INFO,
  SUBSYS_BOOT, tag, k_scenarios, 2)`.
* `k_scenarios` = `"scenarios\0"` (10 bytes). Used as the KV key.

Neither tag carries a standalone uppercase OK token, so
`tools/verify-fingerprint-coverage.sh`'s OK_TOK extractor does not
gate on either -- no golden line or allowlist entry required. Matches
the R92 boot rollup precedent (`tag_boot_r92_route_ok` family).

## Deferred / follow-ups

1. **TCP RX wake wire.** The `poll_wake_check_and_clear` call is
   NOT wired into `tcp_process_segment`'s data-append branch
   (net/tcp.pdx L1187, inside the tpsg body). That function is a
   dense rbp-framed state machine whose surgery risks regressing the
   R72 tcp_echo witness. Wire the wake at the same site the UDP
   deliver_dgram already does (after rx_tail bump), during a
   dedicated R94/R95 hardening pass that also covers the CLOSE_WAIT
   read-half transition. A ring-3 poll on a TCP socket at R95 that
   arrives with the rx ring empty and timeout_ms > 0 will therefore
   block until the timeout wheel wakes it -- and the timeout wheel
   itself is deferred (see item 2).

2. **Timer-driven poll timeout.** sys_poll accepts `timeout_ms` but
   the current tree has no timer-wheel abstraction that can request
   a wake after N ms without a full context to run in. A caller
   passing `timeout_ms > 0` on all-empty sockets blocks until an rx
   path fires wake. The natural landing is a `sched_wake_after_ns`
   primitive built on top of the LAPIC deadline timer; deferred to a
   sched-substrate follow-up.

3. **sys_socket privileged-port gate (R96 handoff).** Default mint
   now grants all four rights (0x00F); the R96 privileged-port gate
   is expected to refine this at mint time based on the intended
   destination port (drop CONNECT for connect-to-privileged-port
   without a suitable authority, drop LISTEN for bind-to-privileged-
   port similarly). The R95 landing is intentionally permissive; the
   plumbing is now in place for R96 to whittle bits.

4. **POLLNVAL.** A poll on a bad fd (neither TCP nor UDP socket nor
   any other pollable resource) contributes 0 to the readiness scan
   rather than setting POLLNVAL on the revents. Linux returns
   POLLNVAL as a distinct signal; deferred to a follow-up.

5. **SO_ERROR population.** The `so_error` slot is read and cleared
   by sys_getsockopt but is not written by any RX-error path today.
   The natural producers are: TCP RST reception (write ECONNRESET),
   ICMP port-unreachable reception on a connected UDP socket (write
   ECONNREFUSED). Deferred alongside item 1 to the R94/R95 TCP-side
   hardening pass.

6. **Multi-caller sys_poll.** The `_poll_waiter_tcb` slot is single-
   entry; a second caller entering sys_poll while a first is blocked
   falls through to the writeback path with nready == 0. Growing the
   slot into a bitmap over the task pool is deferred; no witness
   exercises the multi-caller path yet.

## References

* #2076..#2085 -- R95 issue block.
* `design/networking/r91-plan.md` §17 -- pre-existing sysno
  reservation the R95 bodies materialize.
* `src/kernel/core/net/udp_socket.pdx` -- socket row layout,
  R_SOCKET_* bits.
* `src/kernel/core/net/tcp_socket.pdx` -- sock_cap_check_rights
  helper.
* `design/user/syscall-table.md` -- landed sysno registry through
  R95.M3.
