# R72 TCP handshake witness — diagnosis (paideia-os#2134)

Diagnostic pass only. No code changed. Confirmed pre-existing per the issue
(fails on pristine HEAD, independent of the #2008 UDP diff).

## §1 Repro command + observed symptom

```
bash tools/run-smoke.sh boot_r72_tcp_echo
```

`/tmp/paideia-os-smoke.log` (read from an existing run timestamped
2026-09-01 12:56, not re-run by this pass — debugger sub-agents do not
invoke `run-smoke.sh`) shows, in the whole boot, exactly two TCP-related
lines:

```
[    1.933452] INFO  cpu0 net     : tcp syn sent [legacy: R72 TCP SYN OK]
[    1.934056] INFO  cpu0 net     : L3 TCP segment received [legacy: L3 RX TCP]
```

Expected per `witness_r72_tcp_echo`'s own design (module header,
`src/kernel/boot/witness/r72_tcp_echo.pdx:1-52`): 3× "L3 TCP segment
received" (SYN, SYN|ACK, ACK) plus "tcp handshake complete", "tcp echo
verified", "tcp orderly close". None of the fingerprints past the first
"L3 TCP segment received" appear. Boot continues normally afterward (SVC
LOOKUP OK, IPC CAP SLOT OK, ring-3 init, shell — all unaffected), which
means `witness_r72_tcp_echo` returned via its `r72te_fail` label (a plain
`ret`, no panic) rather than crashing — confirmed by
`src/kernel/boot/witness/r72_tcp_echo.pdx:129-132`'s
`cmp rcx, 4; jne r72te_fail;` gate failing.

## §2 Actual state reached

- **Client TCB**: allocated, set to `TCP_ST_SYN_SENT` (2) by the witness
  itself before calling `tcp_send_segment`, and **never observed to
  advance past SYN_SENT** — the handshake-complete check at
  `r72_tcp_echo.pdx:130-132` fails, meaning the client TCB's state field
  is not 4 (ESTABLISHED) when read back.
- **Server (listener) TCB**: stays in `TCP_ST_LISTEN` (1), as expected —
  it never transitions itself (only its child TCB does).
- **Child TCB**: cannot be directly observed from the log (the witness
  only reads it via `tcp_accept_pending` in step 4, which is never
  reached because step 3 already failed). Whether the child TCB is
  spawned into SYN_RCVD at all, or whether `tcp_alloc_tcb`/
  `tcp_find_tcb_listen` even ran, is **not distinguishable from the boot
  log alone** — there is no counter dump or per-branch klog fingerprint
  in `tcp_rx_handle` between "L3 TCP segment received" and the function's
  three exits (`trh_established_found`, `trh_no_socket`,
  `trh_malformed`).

## §3 Root cause

**Not yet pinned to a specific line — this is the headline finding of
this pass.** A full static line-by-line trace of the demux and loopback
path that the issue asked about turns up no defect:

- `tcp_find_tcb_listen` (tcp.pdx:367-407) correctly matches the
  witness's listener TCB (state==LISTEN, local_port==7).
- `tcp_rx_handle`'s listener branch (tcp.pdx:969-1031) correctly checks
  SYN-set/ACK-clear, calls `tcp_alloc_tcb`, stamps the child TCB's
  ports (`local_port=dst_port=7`, `remote_port=src_port=50000`,
  tcp.pdx:990-991) and IP fields (both copied from the same
  `src_ip`/`dst_ip` pointer the caller passed, tcp.pdx:993-1003),  sets
  `irs`/`rcv_nxt`/`iss`/`snd_una`/`snd_nxt`/state=SYN_RCVD
  (tcp.pdx:1005-1018), links `listener.backlog_pending_tcb = child_idx`
  (tcp.pdx:1020-1025), and calls `tcp_send_segment(child_idx, SYN|ACK,
  0, 0)` (tcp.pdx:1027-1031).
- `tcp_send_segment`'s loopback-vs-wire compare (tcp.pdx:696-706) reads
  the **freshly recomputed** TCB row for whatever `tcb_idx` was passed
  (not a stale caller pointer), and for the child TCB both `local_ip`
  and `remote_ip` were stamped from the *same* source address in step
  above, so the byte-compare should trivially succeed and dispatch back
  into `tcp_rx_handle` in-process — never touching `ipv4_tx_send`/e1000e.
- Register-preservation audit across the whole nested call chain
  (`tcp_send_segment` → `tcp_rx_handle` → `tcp_alloc_tcb` /
  `tcp_find_tcb_established` / `tcp_find_tcb_listen` / `tcp_next_iss` →
  `tcp_send_segment` → …) checked clean: every callee that must
  preserve `rbx`/`r12`-`r15` across the call sites in question does so
  (`tcp_find_tcb_established` pushes/pops `rbx, r12, r13, r14`;
  `klog_emit_core`, reached via `klog_s1`, pushes/pops all six
  callee-saves including `rbp`). `tcp_process_segment`'s `SYN_SENT` and
  `SYN_RCVD` branches (tcp.pdx:1123-1141) also check out arithmetically
  against the values the trace predicts.

In short: **the demux the issue asked about ("what demuxes the SYN into
the server's accept-pending queue... is loopback delivery wired up?") is
present and, on paper, correct.** This contradicts the issue's working
assumption that the gap is a missing/unimplemented primitive. The actual
defect is therefore either (a) a runtime value diverging from what the
static trace assumes — most likely `tcp_alloc_tcb` unexpectedly failing,
`tcp_find_tcb_listen` unexpectedly missing, or the loopback IP-compare
unexpectedly taking the wire branch for a reason not visible in the
source text — or (b) a paideia-as code-generation defect specific to
this function's self-recursive `call` shape (`tcp_send_segment` calling
`tcp_rx_handle` calling `tcp_send_segment` calling `tcp_rx_handle` again,
three levels deep, all sharing the single global `_tcp_tx_scratch`
buffer and the single `_tcp_tcb_table`). Neither can be distinguished
from source reading alone; dynamic instrumentation is required (see §4).

## §4 What a fix would need to do

This is instrumentation-first, not a known fix:

1. Add temporary `klog_s1_x1`/`klog_s1_x2` probes (or equivalent) at:
   - `tcp_rx_handle` right after `tcp_find_tcb_listen` returns
     (tcp.pdx:970-972) — emit the returned listener idx (or
     `TCP_NONE`).
   - Right after `tcp_alloc_tcb` returns in the listener branch
     (tcp.pdx:979-981) — emit the returned child idx (or `TCP_NONE`).
   - Immediately before the loopback/wire branch decision in
     `tcp_send_segment` (tcp.pdx:696) — emit the 4 local_ip and 4
     remote_ip bytes being compared, and which branch was taken.
2. Re-run `boot_r72_tcp_echo` and read which of the three hypotheses
   (alloc failure / listen-lookup failure / loopback-compare failure)
   fires.
3. Once the runtime divergence point is identified, fix that specific
   line — the surrounding state-machine shape does not need a rewrite.
4. If the probes show everything succeeding as traced (alloc ok, lookup
   ok, loopback branch taken) and it *still* doesn't reach a second "L3
   TCP segment received", the defect is in the recursive-call
   compilation itself (paideia-as codegen) rather than in tcp.pdx's
   logic, and the follow-up owner should escalate to paideia-as per this
   project's cross-repo escalation convention rather than continue
   patching tcp.pdx.
5. Separately (§6), the `_tcp_tx_scratch` aliasing hazard should be
   fixed before the echo phase (step 5 of the witness) is exercised,
   regardless of what closes the handshake bug.

## §5 Estimated effort

**M.** The state machine itself does not need new primitives (contrary
to the issue's framing) — this is a targeted instrumented-debug session
to find one runtime divergence, likely a single-line fix once found.
Budget for the possibility that it lands in paideia-as codegen instead
(cross-repo escalation), which would add a day for the escalation loop.

## §6 Related latent bugs surfaced during the audit

- **`_tcp_tx_scratch` aliasing across recursive sends** (tcp.pdx:646,
  664, 701-706, and `tcp_rx_handle`'s `payload_pa` at tcp.pdx:959,
  passed through to `tcp_process_segment` at tcp.pdx:1041). `pkt_pa`
  handed to `tcp_rx_handle` on the loopback path is a raw pointer into
  the single global `_tcp_tx_scratch` buffer, not a copy. For the
  handshake (all-zero-payload control segments) this is harmless. Once
  the echo phase (witness step 5, "hello") is exercised, if *any*
  nested `tcp_send_segment` call happens between a segment's arrival
  and `tcp_process_segment`'s `rep_movsb` copy out of that same
  scratch buffer (tcp.pdx:1185), the payload bytes copied into `rx_buf`
  would be corrupted by whatever the nested call last wrote into
  `_tcp_tx_scratch`. Worth a dedicated review before trusting the echo
  fingerprint even after the handshake bug is fixed.
- **`tcp_send_segment`'s loopback dispatch passes the same pointer for
  both `src_ip` and `dst_ip`** (tcp.pdx:702-703: `lea rdx, [rbp+24]; lea
  rcx, [rbp+24];` — both compute the sending TCB's own `local_ip`
  field, never its `remote_ip`). This only produces correct behavior
  because the self-connect witness guarantees `local_ip == remote_ip`
  on every TCB it touches. The moment a real non-loopback two-party
  connection is exercised even through this "loopback fast path" (e.g.
  a future test with `local_ip != remote_ip` that still wants the
  in-process shortcut), this would silently stamp the wrong IP into
  whichever TCB reads it back. Not a bug for `boot_r72_tcp_echo` today,
  but a trap for whoever generalizes the loopback path later.
- **`tcp_poll_retransmits` is not wired to any timer/idle-loop caller**
  (documented candidly in tcp.pdx:83-104, 826-836) — not exercised by
  this witness (loopback resolves synchronously, well under one RTO
  tick) but a real gap for any workload that outlives one boot tick.
- **`tcp_retransmit_last` only replays zero-payload control segments
  correctly** (tcp.pdx:83-97, 734-744) — a TCB with unacked *data*
  whose RTO fires re-sends a bare flag segment, not the lost bytes,
  because `_tcp_tx_buf_table` is declared but never populated by
  `tcp_send_segment`'s payload-copy step. Documented, not hidden, but
  still an open gap.
- No SYN cookies (RFC 4987), no MSS-option negotiation, no window
  scaling, no SACK, no real RFC 5681 byte-accounting for congestion
  avoidance — all explicitly and honestly documented as deferred in the
  module header (tcp.pdx:1-10, 106-118, 413-419) and not implicated in
  this failure.
