# svc.elevate-broker dispatch body

Tracking: paideia-os #2122 (R90-XREPO.011.M1-003).

Consumers: kernel-side elevation requests routed through
KIND_ELEVATE_CHANNEL. Any process that wants to escalate its authority
narrowly and briefly (design/user/model.md §5 sudo-replacement)
requests a row via the KindElevateChannel mint gate, then the broker
consults `/system/policy` to decide, stamps a deadline, and updates
the row's state so the requester can read the verdict back through
ELVC_OP_QUERY_STATE.

This doc supersedes the "seam + stub" note previously carried in
`src/kernel/core/ipc/elevate_broker.pdx`'s module header — the stub
`elevate_broker_dispatch(op, arg)` from R48b substrate-prep (#1627)
still exists byte-for-byte for the two synth tests that assert
`ELVB_DISPATCH_STUB` as a return value, but the real policy-consulting
body lives in `elevate_broker_serve_one(row_id)`, landed at #2122 as
a sibling entrypoint.

## 1. Sequence

The broker's real dispatch body is a single kernel-side leaf that
runs in the caller's task context (the R48-PREP-005.M2 userspace
daemon is a separate composition; §3 below).

```
elevate_broker_serve_one(row_id) -> decision:
  # Phase 1: pull request context.
  pid       = elevate_channel_row_pid(row_id)
  system_ix = tmpfs_lookup(root_inode=1, "system")
  policy_ix = tmpfs_lookup(system_ix, "policy")
  bytes     = tmpfs_read(policy_ix, buf, 256, 0)
  # Any I/O failure short-circuits to fail-closed DENY.

  # Phase 2: parse the file line-by-line, first-match wins.
  decision = DENIED                              # fall-through default
  for line in lines(buf, bytes):
    strip_ws(line)
    if line begins with '#' or is blank: continue
    (prefix, role, action) = split_ws(line)

    if not target_default_starts_with(prefix): continue
    if not role_matches(role, pid):            continue

    if action == 'ALLOW':
      decision = APPROVED; break
    if action == 'DENY':
      decision = DENIED; break
    # 'DENY_UNLESS_ROLE' and unknown actions are v1 no-ops.

  # Phase 3: reify the verdict on the row.
  elevate_channel_row_set_expire(row_id, ELVB_DEFAULT_EXPIRE_NS)
  elevate_channel_row_set_state(row_id, decision)
  klog "elevate broker allow ok" | "elevate broker deny ok"
     pid=<n> row=<n>
  elevate_broker_note(ELVB_ST_DISPATCH)
  return decision
```

Concrete details are documented in the file justifications
(`src/kernel/core/ipc/elevate_broker.pdx` § `elevate_broker_serve_one`
and `src/kernel/core/cap/kind_elevate_channel.pdx` §
`elevate_channel_row_set_state`).

## 2. Design decisions

### 2.1 Target-path handling (v1 defer)

The KIND_ELEVATE_CHANNEL row layout carries no target path today —
`kind_elevate_channel.pdx` §Section 1 lists only `request_id`,
`requester_pid`, `target_cap_rights`, `expire_ns` and
`broker_endpoint_id` in the +8..+40 tail. v1 therefore evaluates every
request AS IF its target lay under `/system/`; the sole rule pair that
discriminates between requesters is the seeded `/system/  INIT  ALLOW`
+ `/system/  *  DENY`, so the boot witness's two scenarios exercise
exactly those two arms.

The rules for `/home/`, `/tmp/`, `/var/` in the seeded default never
fire because `/system/` is not a byte-prefix of any of them. They are
present to make the seeded file's posture legible to a human reader
and to keep it forward-compatible with a v2 broker.

Widening the row to carry a real target-path handle (an inode
reference or a bounded path buffer) is the natural v2 step; it
requires threading the target through cap_mint_elevate_channel too,
so it's a coordinated cross-cut, not a leaf.

### 2.2 Role-class handling (v1 minimum)

- `INIT` matches iff the row's `requester_pid == 1`.
- `*` matches unconditionally.
- `ADMIN` and `OWNER` are lexed successfully but never match today —
  no per-uid or per-group authority is bound to any task yet
  (design/user/model.md §5.2).

These are documented as harmless no-ops in
`design/security/elevate-policy-format.md` §2.2. When the ADMIN /
OWNER classes are populated by a later milestone, the parser here
grows a real role-resolution step; the file format does not change.

### 2.3 Action classification

Byte-for-byte comparison against the two active literals `ALLOW` and
`DENY`, plus a length-16 skip for `DENY_UNLESS_ROLE`. Any other token
falls through to the next rule (defensive: a future v2 action string
does not fail-closed at parse time, it merely doesn't fire).

### 2.4 Fail-closed I/O

Missing `/system` directory, missing `/system/policy` file, or
`tmpfs_read` returning the VOPS error sentinel all short-circuit to
`ELVC_STATE_DENIED`. This matches
`design/security/elevate-policy-format.md` §3 — an unreadable policy
file MUST default-deny rather than quietly waive the seeded posture.

### 2.5 Expire stamp

Every serviced row gets `ELVB_DEFAULT_EXPIRE_NS = 60_000_000_000` ns
(60 s) written to its `expire_ns` field via
`elevate_channel_row_set_expire` (from #2118). The client can now
distinguish a real broker verdict from a request that timed out
before the broker got to it by observing that `expire_ns` moved off
the tail_alloc-time default of 0. The reaper that treats stamped
deadlines as authoritative timeout is a separate leaf tracked outside
this milestone.

### 2.6 Fingerprint discipline

Three tags carry the dispatch cascade's audit signal:

- `elevate broker allow ok [legacy: ELEVATE BROKER ALLOW OK]` —
  emitted from within `elevate_broker_serve_one` on the ALLOW arm.
  Payload: `pid=<n> row=<n>`.
- `elevate broker deny ok [legacy: ELEVATE BROKER DENY OK]` — the
  mirror on the DENY arm.
- `boot elevate broker ok [legacy: BOOT ELEVATE BROKER OK]` — rollup
  emitted from `witness_elevate_broker_dispatch` when both scenarios
  and the cleanup free all pass.

Bracketed `[legacy: ...]` segments are the coverage-gate tag
(`tools/verify-fingerprint-coverage.sh`'s `OK_TOK` regex), same
dual-form discipline the sibling seed / mint / trust markers use.

## 3. Composition with sched_wait (future daemon)

The parent-issue text names `sched_wait(SCHED_WAIT_ELEVATE_CHANNEL_RX=1,
channel_ptr)` as the block-on-request step of a full daemon loop. This
landing does NOT include the wait in `elevate_broker_serve_one` itself,
for two reasons:

1. Under `-smp 1` with no other task publishing
   `sched_wake_kind(1, ...)`, calling `sched_wait` from the boot
   witness would deadlock the entire boot cascade — the witness
   synthesises the request row and then processes it in the same
   task, so no wake is ever emitted.
2. Splitting the wait from the work keeps the wait's composition
   explicit at the daemon layer, where the wait's semantics (level
   vs. edge; per-channel vs. per-queue) is decided by whoever owns
   the daemon's run-loop.

The composed daemon shape is:

```
elevate_broker_daemon_loop():
  loop {
    row_id = queue_next()                       # some future queue
    if row_id == QUEUE_EMPTY:
      sched_wait(SCHED_WAIT_ELEVATE_CHANNEL_RX,
                 &_elevate_broker_pending)
      continue
    _ = elevate_broker_serve_one(row_id)
  }
```

The wake side lives inside the KIND_ELEVATE_CHANNEL mint path — a
future revision of `elevate_channel_cap_mint_inner` publishes the
newly-minted row into the broker's queue AND calls
`sched_wake_kind(1, &_elevate_broker_pending)`. The plumbing for the
queue is out of scope for #2122; the leaf primitives it composes over
(`sched_wait`, `elevate_channel_row_set_expire`,
`elevate_channel_row_set_state`, `elevate_broker_serve_one`) are all
landed here.

## 4. What v2 buys

- A `target_path` (either an inode reference or a bounded path buffer)
  in the row's tail, threaded from the mint gate through to the
  dispatch body, so every /system rule is not silently the whole
  posture.
- Real `ADMIN` / `OWNER` role resolution once tasks carry uid / group
  attributes.
- A rule table cached in kernel memory at policy-file read time, so
  every dispatch is O(rules) instead of re-parsing the full file — v1
  re-parses per dispatch because the file's size is bounded and small
  and the daemon's throughput is not the bottleneck at this stage.
- Signed / attested policy files, aligned with the pkg attestation
  flow.

## 5. Cross-references

- `src/kernel/core/ipc/elevate_broker.pdx` — the dispatch body plus
  the R48b-substrate stub kept for backward-compat.
- `src/kernel/core/cap/kind_elevate_channel.pdx` — the row layout
  (`§Section 1`), the state setter `elevate_channel_row_set_state`,
  and the expire setter `elevate_channel_row_set_expire`.
- `src/kernel/core/sched/sched_wait.pdx` — the future daemon's
  block-on-request primitive.
- `src/kernel/boot/witness/rootfs_seed_policy.pdx` — the v1 policy
  seeder.
- `src/kernel/boot/witness/elevate_broker_dispatch.pdx` — the
  end-to-end boot witness for #2122.
- `design/security/elevate-policy-format.md` — the on-disk format.
- `design/user/model.md` §5 — the sudo-replacement contract this
  broker enforces.
