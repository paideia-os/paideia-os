# Wait-Graph Invariants — SCHED_WAIT_* Tag Space (ξ-04)

## Purpose

This is ξ-04 in the current architecture-doc wave, alongside
`design/architecture/kernel-cap-taxonomy.md` (ξ-01) and
`design/architecture/syscall-table-v2.md` (ξ-02), both of which may be
in progress in parallel this session. Those two documents are
capability-taxonomy and capability-gate documents: they enumerate cap
*kinds* and which syscalls a cap kind gates. This document is a
different, narrower concern — it is scheduler-internal and has nothing
to do with capabilities as such. A task blocks and wakes via the
`SCHED_WAIT_*` tag space regardless of what capability (if any) its
syscall required to get there; `sys_page_flip_wait` and
`sys_sched_wait_ns` both happen to require capabilities (`{cap,
sched}` and `{sched, boot}` respectively — see ξ-02 for the general
cap-gating picture), but the wait/wake mechanics documented here are
orthogonal to that gating and would look identical if the gating
scheme changed entirely. Treat this doc as the scheduler-substrate
sibling to the capability-focused docs in the wave, not as an
extension of either.

Canonical reference for the scheduler's wait-kind tagging scheme: the
full `SCHED_WAIT_*` enumeration, the single-wait-per-TCB invariant those
tags share, the two sweep/wake mechanisms that service them, and the
parallel untagged blocking paths that live outside this scheme entirely.
This is the first design-level treatment of the tag space as a whole —
`design/kernel/sched-wait.md` documents only the R90-XREPO.011.M1-001
landing (`SCHED_WAIT_NONE` / `SCHED_WAIT_ELEVATE_CHANNEL_RX`) and was
never updated when `SCHED_WAIT_PAGE_FLIP` (R105) or `SCHED_WAIT_TIMER_NS`
(Wave UUU) claimed the next two values; this document closes that gap
and should be treated as the living cross-reference going forward.

**Correction to a common miscue.** There is no plain `SCHED_WAIT_TIMER`
value distinct from `SCHED_WAIT_TIMER_NS`. Value `1` is
`SCHED_WAIT_ELEVATE_CHANNEL_RX`, not a timer tag of any kind — the two
names are easy to conflate because both later values (`PAGE_FLIP=2`,
`TIMER_NS=3`) read like a natural sequence with "TIMER" implied at `1`.
They are not; `1` predates both and belongs to a wholly different
consumer (§1).

## §1 Tag space

All four values are declared as `u64` constants. Only two — `NONE` and
`ELEVATE_CHANNEL_RX` — are declared in the scheme's own canonical module,
`sched/sched_wait.pdx`; the other two were claimed independently by their
own consumer files without updating that module's table (see §5).

| Tag | Value | First landed (round/issue) | Declared in | Consumer syscall(s) | TCB fields used |
|---|---|---|---|---|---|
| `SCHED_WAIT_NONE` | 0 | R90-XREPO.011.M1-001 (#2117) | `sched/sched_wait.pdx` | None — sentinel. `sched_wait(0,_)` and `sched_wake_kind(0,_)` are both refused as no-ops; this is also the value every fresh TCB carries out of `task_new`'s zero-fill, so no unbound task can ever be matched by accident. | +448 (as the zero state) |
| `SCHED_WAIT_ELEVATE_CHANNEL_RX` | 1 | R90-XREPO.011.M1-001 (#2117) | `sched/sched_wait.pdx` | **None consumed in-tree yet.** Reserved for `svc.elevate-broker`'s channel-receive park. `elevate_broker.pdx`'s own dispatch-body comment states explicitly: *"No sched_wait here — the parent-issue text names sched_wait(SCHED_WAIT_ELEVATE_CHANNEL_RX=1, channel_ptr) as the block-on-request step of a full daemon loop, but under -smp 1 with no other task publishing sched_wake_kind(1, ...) the witness would deadlock."* The tag is real and reserved but currently unexercised by any body. | +448/+456 |
| `SCHED_WAIT_PAGE_FLIP` | 2 | R105.M3-003 | `cap/kind_page_flip.pdx` (own module, **not** `sched/sched_wait.pdx`) | sysno 112 `sys_page_flip_wait`. Woken by `pgfl_deliver_vblank` (called from the simulated-tick source, real vblank, or virtio-gpu completion) via `sched_wake_kind(2, row_id)`. | +448/+456 |
| `SCHED_WAIT_TIMER_NS` | 3 | COMP-IMPL-07 (Wave UUU) | `sched/sched_wait_ns.pdx` (own module; hand-rolled wait/wake pair, does not call `SchedWait.sched_wait`/`sched_wake_kind`) | sysno 116 `sys_sched_wait_ns`. Woken by `sched_wait_ns_sweep`, wired into `int/exceptions.pdx`'s `handle_timer` per-tick path. | +448/+456/+480 (adds the deadline field) |

## §2 The single-wait-per-TCB invariant

Every tag in §1 that is actually parked (`ELEVATE_CHANNEL_RX`, `PAGE_FLIP`,
`TIMER_NS`) stores its key into the **same two TCB fields**:

- `TASK_OFF_WAIT_KIND` at `+448` (u64) — the `SCHED_WAIT_*` value.
- `TASK_OFF_WAIT_OBJECT` at `+456` (u64) — an opaque per-kind key (channel
  pointer, page-flip row id, or `0` for `TIMER_NS`, which has no `obj`
  concept and stores its own extra state in a third field instead).

`SCHED_WAIT_TIMER_NS` additionally uses `TASK_OFF_WAIT_DEADLINE_NS` at
`+480` (u64) — the one field this family needed that the generic
`(kind, obj)` shape had nowhere to carry, since `obj` was already spoken
for by every other wait-kind's own identity (`sched_wait_ns.pdx` header,
§WHY A NEW WAIT-KIND). That is the complete field list: **three** fields
total (`+448`, `+456`, `+480`), not more — confirmed by grepping every
`+448]` / `+456]` / `+480]` reference under `src/kernel/**/*.pdx`; no
other consumer of any of the three exists outside `sched_wait.pdx` and
`sched_wait_ns.pdx`.

**The invariant, stated explicitly:** a TCB may be parked on at most one
`(wait_kind, wait_object[, deadline])` triple at a time — a single wait
per task across this entire tagged family. This is never enforced by a
runtime assertion or guard. There is no code path that checks "is this
TCB already waiting on a different kind before overwriting +448/+456" —
`sched_wait` and `sched_wait_ns` both simply `mov`-store their key
unconditionally into the same two (or three) fields. **It is a numbering
discipline maintained by careful humans, not a mechanically-checked
invariant.**

The `SCHED_WAIT_TIMER_NS=3`-not-`2` comment is the concrete, in-tree
proof that this convention is load-bearing rather than decorative.
`sched_wait_ns.pdx`'s own header states the reasoning verbatim:

> *"SCHED_WAIT_TIMER_NS is 3, not 2, because KindPageFlip's
> SCHED_WAIT_PAGE_FLIP (sysno 112's own wait key) already claims 2
> against the same TCB fields... colliding on 2 would make
> sched_wait_ns_sweep spuriously match a page-flip waiter's stale
> (never-written-by-that-path) +480 deadline slot."*

Concretely: had `TIMER_NS` reused value `2`, a task genuinely parked via
`sys_page_flip_wait` (wait_kind=2, object=row_id, deadline field never
written — stays whatever garbage or zero was last there) would be
silently eligible for `sched_wait_ns_sweep`'s filter, which only checks
`wait_kind==3` and `deadline<=now`. Reusing `2` would have made that
filter also match kind-2 waiters, and a stale/zero deadline compared
`<= now` is almost always true — the page-flip waiter would be spuriously
woken by the *timer* sweep, out from under a real, still-pending flip.
This is silent corruption of an in-flight wait, not a crash: nothing
would fault, the task would simply return early from `sys_page_flip_wait`
as if its flip had completed. The invariant survives today only because
each new consumer's author manually grepped for every prior `SCHED_WAIT_`
declaration before picking a value (see §5).

## §3 Sweep mechanics

Two distinct wake mechanisms service the tagged family, and they are not
the same shape:

**Event-driven wake (`sched_wake_kind`, kinds 0/1/2).** `sched_wake_kind
(kind, obj)` is called on demand by whatever event makes a wait
condition true — `pgfl_deliver_vblank` calls it for `PAGE_FLIP`; the
(currently unbuilt) elevate-broker publish path would call it for
`ELEVATE_CHANNEL_RX`. Each call performs one **O(63) linear scan** over
`task_slab_of_pid(1..63)`, filtering on `state==TASK_STATE_WAITING(2) &&
wait_kind==kind && wait_object==obj`, clearing the matched TCB's wait
fields, and calling the target-indexed `sched_wake`. There is no
per-kind index or hash table — every wake, regardless of kind, walks the
entire live task pool. This is not amortized against a timer; it fires
exactly once per producing event.

**Periodic sweep (`sched_wait_ns_sweep`, kind 3 only).** Unlike the
event-driven wake, `TIMER_NS` has no producing event — a deadline simply
elapses. `sched_wait_ns_sweep` is therefore wired into `int/
exceptions.pdx`'s `handle_timer`, which fires once per ~10 ms LAPIC tick
(100 Hz), and runs **unconditionally on every tick** (not every 10th, as
the sibling TCP-retransmit sweep does — the render-pacing use case wants
sub-16 ms wake latency). Each invocation is also an **O(64) linear scan**
over `task_slab_of_pid(1..63)`, filtering on `state==WAITING && wait_kind
==3 && deadline<=now`. So: yes, this is a flat O(n) scan over all tasks
per tick, not a sorted timer wheel — the file's own header names the
tradeoff explicitly (`sched_wait_ns.pdx` §TIMER-WHEEL GRANULARITY),
calling this a "tick-sampled MVP" and naming a future per-CPU sorted
wheel armed via `tsc_deadline_arm_first` as the eventual replacement.
Worst-case jitter past a requested `ns` is one tick (~10 ms).

Both scans share the same iteration bound (`PID_MAX=63` / `SWN_MAX_PIDS
=64`) and the same clear-before-wake ordering (zero the wait fields
before calling `sched_wake`, so a spurious re-entry cannot double-fire).

## §4 Parallel / untagged blocking paths

**Confirmed: at least two other blocking mechanisms coexist with the
tagged `SCHED_WAIT_*` scheme, entirely bypassing it.** This is a real
architectural seam — three (arguably four, see below) independent
wait/wake substrates share the scheduler's `sched_block`/`sched_wake`
primitives but use disjoint per-task state to decide who to wake.

**sysno 40/42 (`sys_ipc_recv`/`sys_ipc_send`) — endpoint-row-keyed, not
task-pool-scanned.** `sys_ipc_recv_body` blocks by writing the *waiting
task's own TCB pointer* into the endpoint row it is waiting on
(`ENDPOINT_OFF_WAITER_TCB`, row offset `+32`) and, separately, stamps
`TASK_OFF_WAIT_ENDPOINT_ID` at TCB `+120` (a `u16`, declared in
`sched/state.pdx` — a field entirely distinct from the `+448/+456/+480`
family), then calls `sched_block` directly. `sys_ipc_send_body` wakes by
reading that single waiter slot back off the endpoint row and calling
the target-indexed `sched_wake(target_tcb)` directly — it never calls
`sched_wake_kind` and never touches `+448`/`+456`. This is a
single-waiter-per-endpoint design (one row, one slot), which is a
different sharing model than the tagged scheme's many-waiters-per-key
scan.

**sysno 61 (`wait4`) — no wait key at all.** `dispatch_wait4` (`syscall/
dispatch.pdx`) calls `sched_block` directly with **no wait-kind tag, no
endpoint-style slot, nothing stored into `+448`/`+456`/`+120` at all**.
The parent/child relationship that lets the wake side find the right
task is carried implicitly by the existing `_pid_table` parent-pointer
scan (`sys_wait_body`) on the reap side. On the wake side, `sys_exit_body`
does not call `sched_wake` or `sched_wake_kind` either — it inlines the
wake by hand: look up `_pid_table[parent_pid]`, check `parent->state ==
STATE_WAITING(2)`, write `wait_result_pid`/`wait_result_status` at parent
TCB `+1704`/`+1708`, flip `parent->state` to `RUNNABLE` directly, and call
`runq_enqueue(parent)` directly — bypassing every layer of both the
tagged scheme and the generic target-indexed `sched_wake` primitive. This
is the least-tagged of the three: it identifies its target purely by the
parent/child pid relationship and a bare `state==WAITING` check, with no
secondary key to disambiguate what the parent is waiting *for*.

**Consequence.** A parent TCB blocked in `wait4` and a parent TCB
(hypothetically) also parked via `SchedWait.sched_wait` would both leave
`state==TASK_STATE_WAITING` with nothing at `+448`/`+456` distinguishing
the two — because `wait4` never writes those fields, a `sched_wake_kind`
call with any real kind cannot mistake a `wait4`-blocked task for one of
its own waiters (the `wait_kind` field stays `0`/`SCHED_WAIT_NONE` from
the last defensive clear, and `sched_wake_kind` refuses kind `0`
entirely). So the three mechanisms do not currently collide with each
other in practice — but that is an emergent property of each one's own
filter being conservative, not a designed-in guarantee that a task could
never legitimately need two of these blocking reasons at once. No task
in this codebase currently attempts to be, e.g., both `wait4`-blocked and
`sys_ipc_recv`-blocked simultaneously; if one ever did, the two
mechanisms would silently overwrite each other's state with no error
(same failure shape as §2's collision hazard, one level up).

## §5 Collision hazards and future-tag guidance

Before claiming the next `SCHED_WAIT_*` value:

1. **Grep first, don't trust the canonical table alone.**
   `sched/sched_wait.pdx`'s own table (mirrored in `design/kernel/
   sched-wait.md`) is stale — it lists only `0` and `1`. Both `2`
   (`kind_page_flip.pdx`) and `3` (`sched_wait_ns.pdx`) were claimed by
   grepping `SCHED_WAIT_` across the whole tree at landing time, not by
   reading the canonical module's comment. Do the same: `grep -rn
   "SCHED_WAIT_" src/kernel/` and take the next free integer above every
   result, not just the ones in `sched_wait.pdx`.
2. **Update the canonical table when you claim a value**, even if your
   consumer lives in a different module (as `PAGE_FLIP` and `TIMER_NS`
   both do). This document and `design/kernel/sched-wait.md` are the two
   places that should reflect the current full set; leaving them stale
   is exactly how `PAGE_FLIP`/`TIMER_NS` drifted out of the "canonical"
   table in the first place.
3. **Decide whether you actually need the generic `(kind, obj)` shape.**
   If your wait needs more than one opaque `u64` of correlating state
   (as `TIMER_NS` did, needing a deadline), you cannot reuse `sched_wait`/
   `sched_wake_kind` verbatim — you will need your own TCB field (find
   the next free 8-aligned offset the way `sched_wait_ns.pdx` found
   `+480`, verified clean by grep against every `.pdx` file) and your own
   hand-rolled wait/wake pair, exactly as `TIMER_NS` did. Decide this
   before picking a tag value, since a hand-rolled pair changes nothing
   about needing a fresh, uncollided value in the shared `+448` enum.
4. **State explicitly whether your wake is event-driven or needs a
   sweep.** `PAGE_FLIP`/`ELEVATE_CHANNEL_RX` are woken by whatever event
   satisfies them; `TIMER_NS` needed a periodic sweep because nothing
   else would ever call `sched_wake_kind` for it. If your new kind needs
   a sweep, decide its tick cadence deliberately (every tick, like
   `TIMER_NS`'s render-latency need, vs. every-Nth, like the TCP
   retransmit sweep) rather than defaulting to "every tick" by copying
   `sched_wait_ns_sweep` without re-deriving the latency requirement.
5. **Remember there is no runtime guard (§2).** Nothing stops a new
   consumer from silently colliding with an existing value the way
   `TIMER_NS` almost did with `PAGE_FLIP`. The only defense is the
   discipline in points 1–2. If a fourth or fifth tag lands, consider
   whether it is finally time to add a debug-build assertion in
   `sched_wait`/the hand-rolled equivalents that a TCB's current
   `wait_kind` is `0` (or matches) before overwriting it — this document
   finds no such assertion anywhere in the tree today.
6. **Consider whether your new wait belongs in the tagged family at all.**
   §4 shows two consumers (`ipc_recv`/`ipc_send`, `wait4`) that
   deliberately did *not* join the tagged scheme, each for a documented
   reason (single-waiter-per-endpoint locality; implicit parent/child
   identity). If your wait has a similarly natural non-scan-based way to
   find its target, a hand-rolled `sched_block`/`sched_wake(target)` pair
   may be the better fit than adding a fifth value to a scan that already
   walks the full task pool on every event.

## §6 Open gaps

**Top gap: `sched_wake` itself is not, and cannot be, kind-aware.**
`sched_wake(target)` (`src/kernel/core/sched/wake_block.pdx:80-186`)
takes a raw TCB pointer and unconditionally flips
`state: WAITING -> RUNNABLE` and enqueues it — it never reads
`+448`/`+456`/`+480` at all, so it has no concept of "kind" to filter
on. Kind-safety is entirely a property of the three call sites that
decide *which* TCB to pass it: `sched_wake_kind`'s scan
(`sched_wait.pdx:282-324`), `sched_wait_ns_sweep`'s scan
(`sched_wait_ns.pdx:234-271`), and `sys_exit.pdx`'s hand-inlined wake
(`sys_exit.pdx:120-150`, which does not call `sched_wake` at all — see
§4). There is no shared, generic "wake matching this kind" entry point
that all three funnel through; each scan is a separate, independently
maintained filter loop over the same shared TCB fields. If a future
consumer added a fourth scan over `+448` without the same
`wait_kind==<mine>` discipline the first three demonstrate, nothing in
the type system, the capability annotations, or `sched_wake` itself
would catch it — the failure mode would be exactly the near-miss
`SCHED_WAIT_TIMER_NS=3` averted (§2): a scan matching a TCB parked for
an unrelated reason and reading its other shared field as if it were
its own.

**The collision-avoidance discipline has been exercised exactly once,
at n=2 live producers.** Of the four declared tags, only
`SCHED_WAIT_PAGE_FLIP=2` (`kind_page_flip.pdx`,
`sys_page_flip_wait.pdx:83`) and `SCHED_WAIT_TIMER_NS=3`
(`sched_wait_ns.pdx:112,170-174`) are ever actually stored into a TCB
and woken. `SCHED_WAIT_NONE=0` is the sentinel/idle value, never a real
wait. `SCHED_WAIT_ELEVATE_CHANNEL_RX=1` (`sched_wait.pdx:106`) is
declared and reserved but has no call site anywhere in the tree that
invokes `SchedWait.sched_wait(1, ...)` — `elevate_broker.pdx`'s own
dispatch body says so explicitly ("No sched_wait here"). So the one
piece of concrete evidence that the "grep first, pick the next free
integer" convention (§5 point 1) actually works under pressure is the
single `TIMER_NS` vs. `PAGE_FLIP` near-collision. That is a real,
positive data point, but it is one data point — the discipline has
never been tested with three or more simultaneously-live tags, nor
under a scenario where two authors claim a value in the same
development window without seeing each other's landing.

**`SCHED_WAIT_TIMER=1` does not exist and never has.** The value `1` is
`SCHED_WAIT_ELEVATE_CHANNEL_RX` (`sched_wait.pdx:106`), a channel-park
tag unrelated to timers, and it is unconsumed (previous paragraph). Any
future comment, issue, or design note that refers to a plain
"`SCHED_WAIT_TIMER`" tag distinct from `SCHED_WAIT_TIMER_NS=3` is
referring to something that is not in this source tree; treat such a
reference as an error to be corrected, not a fact to reconcile against.

**No runtime assertion backs the single-wait-per-TCB invariant (§2).**
Both `sched_wait` (`sched_wait.pdx:163-217`) and `sched_wait_ns`
(`sched_wait_ns.pdx:154-193`) store their key fields with a plain `mov`
and no precondition check that the TCB's current `wait_kind` is `0`
before overwriting it. A caller bug that invoked, say, `sched_wait_ns`
on a task already parked via `SchedWait.sched_wait` would silently
clobber the first wait's `(kind, obj)` pair with `(3, 0)` and add a
deadline the first waiter's own wake path knows nothing about — no
panic, no log line, just a task that stops responding to the wake it
was actually waiting for. §5 point 5 already names a debug-build
`wait_kind==0` guard as the fix; it does not exist today.

**The tagged scheme is not the only blocking substrate, and the two do
not know about each other (§4).** `sys_ipc_recv`/`sys_ipc_send` key off
an endpoint-row waiter slot plus `TASK_OFF_WAIT_ENDPOINT_ID` (+120),
and `wait4` keys off nothing but the `_pid_table` parent/child
relationship and a bare `state==WAITING` check. Both currently avoid
colliding with the tagged family only because they leave `+448` at its
zero default rather than by any designed interlock. A task that needed
two of these blocking reasons at once — hypothetical today, since none
does — would have its state silently corrupted by whichever mechanism
stored second, with no error raised by either side.

## Cross-references

Files read in full or in the cited part while researching this document:

- `src/kernel/core/sched/sched_wait.pdx` — canonical `SchedWait` module:
  `SCHED_WAIT_NONE`/`SCHED_WAIT_ELEVATE_CHANNEL_RX`, `TASK_OFF_WAIT_KIND`/
  `TASK_OFF_WAIT_OBJECT` (+448/+456), `sched_wait`, `sched_wake_kind`.
- `src/kernel/core/sched/sched_wait_ns.pdx` — `SCHED_WAIT_TIMER_NS`,
  `TASK_OFF_WAIT_DEADLINE_NS` (+480), `sched_wait_ns`,
  `sched_wait_ns_sweep`, the collision-avoidance rationale for value `3`.
- `src/kernel/core/cap/kind_page_flip.pdx` — `SCHED_WAIT_PAGE_FLIP=2`
  declaration and `pgfl_deliver_vblank`'s `sched_wake_kind(2, row_id)`
  call site.
- `src/kernel/core/syscall/handlers/sys_page_flip_wait.pdx` — sysno 112
  body; `sched_wait(SCHED_WAIT_PAGE_FLIP=2, row_id)` call site.
- `src/kernel/core/syscall/handlers/sys_sched_wait_ns.pdx` — sysno 116
  body; thin call-through into `SchedWaitNs.sched_wait_ns`.
- `src/kernel/core/syscall/dispatch.pdx` — sysno 108–116 comment block
  (GUI syscalls + `sys_sched_wait_ns`), `dispatch_wait4` (sysno 61) full
  body, sysno 40/42 placement comments.
- `src/kernel/core/syscall/handlers/sys_wait.pdx` and `sys_ipc_recv.pdx`
  and `sys_ipc_send.pdx` — the two untagged blocking paths (§4).
- `src/kernel/core/syscall/handlers/sys_exit.pdx` — the `wait4` wake side
  (`wait_result_pid`/`wait_result_status` at +1704/+1708, direct
  state-flip + `runq_enqueue`, no `sched_wake` call).
- `src/kernel/core/ipc/endpoint_table.pdx` — `ENDPOINT_OFF_WAITER_TCB`
  (row +32) declaration and `endpoint_is_dead`'s waiter-detach path.
- `src/kernel/core/sched/state.pdx` — `TASK_OFF_WAIT_ENDPOINT_ID` (+120)
  declaration.
- `src/kernel/core/ipc/elevate_broker.pdx` — the "No sched_wait here"
  comment evidencing `SCHED_WAIT_ELEVATE_CHANNEL_RX=1` as reserved but
  unconsumed.
- `design/kernel/sched-wait.md` — the R90-XREPO.011.M1-001 design doc;
  confirmed stale against the current four-value tag space.
- `design/user/syscall-table.md` — sysno 40/61 argument/return
  conventions (tone/style reference, per task instruction).
- `design/architecture/caps-decl-format.md` — structure/tone reference.
