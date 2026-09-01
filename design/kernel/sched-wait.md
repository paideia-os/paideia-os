---
issue: 2117
round: R90-XREPO.011.M1-001
parent: 1997
subsystem: 10 -- Scheduler
prereq:
  - "#567 (R15.M7-006 sched_block/sched_wake primitives -- reused verbatim)"
  - "#544 (task-slab pool + task_slab_of_pid arithmetic)"
  - "state.pdx TASK_STATE_WAITING = 2 (reused)"
blocks:
  - "R90-XREPO.011.M1-003 (elevate-broker dispatch loop, blocks on a wait key rather than spin-polling)"
touching:
  - src/kernel/core/sched/wait.pdx                 (new; the primitive itself)
  - src/kernel/core/klog/keys.pdx                  (tag_sched_wait_ok, tag_sched_wake_ok, k_kind)
  - tools/verify-fingerprint-coverage.sh           (allowlist entries for the two OK tokens)
related:
  - design/kernel/r15-m7-006-block-wake.md         (sched_block / sched_wake -- the substrate reused)
  - src/kernel/core/sched/wake_block.pdx           (sched_block / sched_wake bodies)
  - src/kernel/core/sched/state.pdx                (TASK_STATE_WAITING = 2; canonical state enum)
---

# R90-XREPO.011.M1-001 -- kernel-side scheduler wait primitive (#2117)

## 1. Scope

Land a kernel-internal wait/notify pair keyed by a `(wait_kind, wait_object_ptr)` pair so a kernel service (starting with `svc.elevate-broker`) can block a worker thread until a request arrives on a channel it owns, and an ISR / cap-op / peer task can wake exactly the threads parked on that key.

This is **NOT a syscall** at this round. The primitive is called only from kernel-side service code and ISR tails. A user-facing `sys_sched_wait` (per the original parent-issue text) is intentionally deferred: the elevate broker itself runs as a kernel-side dispatch loop at this milestone, and exposing a naked wait/notify to userland at the same instant would force the ABI question (namespaced wait-object handles, capability-gated notify authority) before there is a second in-tree consumer to shape the answer.

The primitive is:

- `sched_wait(kind, obj) -> ()` -- self-suspend the caller on `(kind, obj)`. Records the pair in the caller's TCB, emits a fingerprint, invokes `sched_block` (which flips the state to `TASK_STATE_WAITING`, dequeues from the runqueue, and switches to the next runnable task). Returns to the caller when a matching `sched_wake_kind` fires.
- `sched_wake_kind(kind, obj) -> u64` -- scan the task pool for tasks that are `TASK_STATE_WAITING` with `(wait_kind == kind, wait_object == obj)`, clear their wait fields, and hand each of them to `sched_wake` (which flips state -> `RUNNABLE` and enqueues). Returns the count of tasks woken. Emits a fingerprint iff count > 0.

## 2. Wait kinds (open enum)

Values live in `wait.pdx` under `SchedWait`:

| Value | Symbol                            | Meaning |
|------:|-----------------------------------|---------|
| 0x00  | `SCHED_WAIT_NONE`                 | Sentinel. `sched_wait(0, _)` and `sched_wake_kind(0, _)` are refused (no-op that returns 0). Reserved as the freshly-zeroed value every TCB carries out of `task_new`'s `rep stosq`, so no unbound task ever satisfies a real key. |
| 0x01  | `SCHED_WAIT_ELEVATE_CHANNEL_RX`   | Elevate broker's channel-receive parking key. `obj` = address of the per-broker channel state struct (or endpoint row PA). |

New kinds land here as consumers show up. Adding a value is one line under `SchedWait` and does not require a new module or file.

## 3. TCB fields

Two new fields inside the 2224-byte task_struct slab, both u64, both covered by `task_new`'s existing 278-qword `rep stosq` zero-fill:

- `TASK_OFF_WAIT_KIND = 448` (u64) -- current wait key kind, 0 if not waiting.
- `TASK_OFF_WAIT_OBJECT = 456` (u64) -- current wait object pointer / opaque id, 0 if not waiting.

**Placement rationale.** The 6-byte gap at `+122..+127` documented in `task_pool.pdx`'s "Adopted slots" table is too small for a `(u64, u64)` pair, and no other free 16-byte-aligned slot exists below `TASK_OFF_CWD` (`+160`). The next free region is above the fd_table (`+168..+423`) and the runqueue link words (`+432`, `+440`). `+448..+463` is 8-aligned, verified clean via a full grep of `+448` / `+456` against `src/kernel/**/*.pdx` at landing (no other consumer). Both slots sit inside the 2224-byte struct pinned by `verify-task-pool-bounds.sh`, so a future field-offset audit will pick them up automatically.

The fields are **written by**:
- `sched_wait` on entry (store non-zero key), and again on resume (zero back out defensively).
- `sched_wake_kind` on match (zero back out before calling `sched_wake`, so a spurious re-wake of the same key does not double-fire).

Nothing else touches them.

## 4. Race posture (single-CPU, no preemption)

At R15.M7 the sched substrate has no timer preemption (#565 blocked on #662), and paideia-os today boots `-smp 1`. `sched_wait`'s (store wait-key, block) sequence and `sched_wake_kind`'s (scan, match, wake) sequence run with interrupts enabled but with no concurrent scheduler to observe an intermediate state. The classic wakeup race is therefore structurally impossible today.

When preemption lands (R15.M7's own §7.2 deferred `cli`/`popfq` window inside `sched_block`) the same window subsumes this primitive: the wait-key store happens before `sched_block`'s state-flip, and the state-flip + dequeue are the atomic boundary. A future SMP round will need to widen this into a per-wait-key spinlock; that is not this milestone.

## 5. Fingerprints

Emitted from inside the primitive itself (not from a boot witness):

- `sched wait ok [legacy: SCHED WAIT OK] -- kind=<n>` -- at `sched_wait` entry, after the wait-key store, before the `sched_block` call. Proves the primitive was entered with a well-formed key.
- `sched wake ok [legacy: SCHED WAKE OK] -- kind=<n>` -- at `sched_wake_kind` exit, iff at least one waiter was woken. Proves the notify path fired and matched.

Both tags carry a standalone uppercase `OK` token in their bracketed legacy alias, so `tools/verify-fingerprint-coverage.sh` demands either a golden line or an allowlist entry. This round lands the allowlist entries with the reason "no kernel-side witness exists yet -- the elevate broker dispatch loop that first invokes the primitive is R90-XREPO.011.M1-003"; the entries retire when the sibling milestone lands its own witness and a golden line pins the fingerprints.

## 6. Signatures + register discipline

```
pub let sched_wait      : (u64, u64) -> ()  !{mem, sysreg} @{sched}
pub let sched_wake_kind : (u64, u64) -> u64 !{mem, sysreg} @{sched}
```

- `sched_wait(kind, obj)` -- 3-push prologue (rbx/r12/r13), entry rsp%16==8 -> rsp%16==0 for nested calls. r12=kind, r13=obj (both callee-save so they survive `klog_s1_d1` and `sched_block`).
- `sched_wake_kind(kind, obj)` -- 5-push prologue (rbx=scan idx, r12=kind, r13=obj, r14=woken count, r15=matched slab), entry rsp%16==8 -> rsp%16==0. All five must survive `task_slab_of_pid`, `sched_wake`, and `klog_s1_d1` (only rbx/r12-r15 are guaranteed preserved across a SysV call).

## 7. Naming: `sched_wake_kind`, not `sched_wake`

The parent issue's task text names the notify primitive `sched_wake`. There is already a `sched_wake(target_tcb)` in `sched/wake_block.pdx` (R15-M7-006) that takes a target TCB and is called at ~7 sites (`sys_ipc_send`, `sys_kill`, `uart_rx_notify_wake_if_waiter`, `driver_restart_wake_pending`, `sched_block_witness_helper`). Renaming that primitive to make room for the new one is a large blast radius for a naming preference; giving the new one a distinct name is the local cost. `sched_wake_kind` is chosen for the parity with `sched_wait` (both indexed by the same key) and to keep grep discoverability: any file calling `sched_wake_kind` is unambiguously the new key-indexed primitive.

## 8. Out of scope

- **`sys_sched_wait` syscall.** The user-facing sysno is deferred until at least one non-kernel consumer needs it. Filed as follow-up under the R90-XREPO.011 umbrella (parent #1997).
- **Boot witness.** The parent-issue text names a two-thread park/notify witness; that lands with the sibling elevate-broker dispatch loop milestone (R90-XREPO.011.M1-003), which naturally exercises the primitive end-to-end.
- **Timeout parameter.** `sched_wait` blocks unconditionally. A `sched_wait_timed(kind, obj, deadline_ns)` variant that pairs with TSC-deadline expiry is future work; today the elevate broker's own request-level `expire_ns` field on the KIND_ELEVATE_CHANNEL row is the timeout surface.
- **Priority-inheritance wake.** `sched_wake_kind` wakes in scan order (low pid first). A future round will re-order by requester priority once the priority substrate lands beyond R11's placeholder.
