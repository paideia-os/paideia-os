# Cascade restart: supervisor tree, restart budget, and ChannelDead

**Round.** R29 — Driver framework maturation + interrupt topology
**Sub-milestone.** R29.M7 (chaos + restart)
**Issues.** #1044 (policy + supervisor tree), #1047 (budget + rate-limit),
#1048 (dependent-client recovery)

**Implements.**
`src/kernel/core/driver/restart.pdx`,
`src/kernel/core/driver/driver_table.pdx` (supervision word, re-arm),
`src/kernel/core/driver/lifecycle.pdx` (Init → Stopping edge),
`src/kernel/core/ipc/endpoint_table.pdx` (driver binding + dead state),
`src/kernel/core/syscall/handlers/sys_ipc_recv.pdx` and
`sys_ipc_send.pdx` (ChannelDead).

**Witness.** `kernel_main.pdx §r29_cascade_restart_witness` — fingerprint
`R29 CASCADE RESTART OK`.

---

## 1. The claim this document defends

A driver dies. Three questions follow, and each has exactly one defensible
answer given the authority structure R29 already built:

1. **Who else has to die?** Its descendants, and nobody else.
2. **Who gets restarted?** The dead node, and nobody else.
3. **What happens to clients holding channels to it?** They wake with
   `ChannelDead` and must re-connect through a fresh endpoint.

The rest of this document shows that each answer is *forced* by the
capability architecture rather than chosen from a menu of supervision
policies.

---

## 2. The supervisor tree is the capability derivation tree

PaideiaOS does not get to pick an arbitrary supervision topology, because
one already exists: the capability derivation graph. A driver process's
DMA authority is a `KIND_DMA_DOMAIN` derived from its process memory root
(`blob-policy.md` §2.4, enforced at `driver_lifecycle_start`), and
`dma_cascade_revoke_by_parent` already tears down every domain derived
from a dying parent. The supervisor tree does not add structure; it makes
the structure that governs authority *visible to the lifecycle layer*, so
that process lifetime and authority lifetime cannot drift apart.

Concretely, the parent link lives in the driver descriptor itself — the
previously-reserved `[+40]` word of the 48-byte row (`driver_table.pdx`
§Row layout), now the **supervision word**:

```
[+40] u64 supervision word
  bits [4:0]    parent_slot            (0..31, meaningful iff bit 5 set)
  bit  [5]      parent_present
  bit  [6]      perm_failed            (escalation latch — see §5)
  bit  [7]      reserved
  bits [15:8]   restart_count          (restarts inside the current window)
  bits [23:16]  incarnation            (u8, wraps; identity of this life)
  bits [63:24]  window_start_coarse    (TSC >> 20, 40 bits)
```

Putting the link in the descriptor rather than in a side table is the
same decision the DMA-domain field made at `[+32]`: the row is the thing
that would have to be corrupted for the invariant to break, so the row is
where the invariant is enforced. `driver_sup_set_parent` refuses a link
that would close a cycle (walking up to 32 hops from the proposed parent
and refusing on either reaching the child or exceeding the depth bound),
which is what makes "the subtree of a node" a total, terminating
computation rather than a hope.

The tree is a forest, not a single rooted tree: a driver with no parent
link is its own root. The bus enumerators (PCI, ACPI) are the natural
roots; a function driver's parent is the enumerator that discovered it.

---

## 3. Restart strategy: one-for-one across siblings, cascade downward

### 3.1 The choice

From the classic set — one-for-one, one-for-all, rest-for-one — this
design takes **one-for-one for siblings**, combined with a **mandatory
downward cascade** over descendants.

The restart set for a death at node `D` is therefore:

```
  kill set     = { D } ∪ descendants(D)
  restart set  = { D }
```

Descendants are stopped, torn down, and **unregistered** — not restarted.
Siblings and ancestors are not touched at all.

### 3.2 Why one-for-one and not one-for-all

One-for-all is the correct answer when siblings share mutable state they
cannot resynchronise after one of them dies mid-update. That condition is
*structurally absent* here, and absent by construction rather than by
luck: R29 gives each driver process exactly one `KIND_DMA_DOMAIN` (D1.b
cardinality, enforced at `driver_table_set_domain`), its own
`KIND_INTERRUPT` / `KIND_MSIX_VECTOR` vectors, and its own MMIO windows.
Two sibling drivers share no writable object. There is nothing for one to
have corrupted on behalf of the other.

Choosing one-for-all anyway would mean taking NVMe down because e1000e
faulted — losing the root filesystem over a network fault — with no
correctness benefit to buy back the availability loss. The capability
partitioning that R29 spent five milestones building is precisely what
earns the cheaper policy.

Rest-for-one is likewise unmotivated: it exists to model start-order
dependencies between siblings, and sibling start order carries no
authority relation in this design. Where a real dependency exists it is
expressed as a parent link, and the cascade already handles it.

### 3.3 Why the downward cascade is not a policy choice

A child's authority is *derived* from its parent's. When the parent's
process dies its memory root dies, and `dma_cascade_revoke_by_parent`
(already invoked from `driver_lifecycle_teardown`) revokes every domain
descended from it. The child's IOMMU domain is gone whether or not the
supervisor agrees. Letting the child process continue to run would leave
a driver executing against revoked authority — the exact "stale IOMMU
context entry" hazard `driver_lifecycle_teardown` documents.

So the cascade is not the supervisor choosing to kill the subtree; it is
the supervisor making the *process* lifetime match the *authority*
lifetime that the capability layer already ended.

### 3.4 Why descendants are not auto-restarted

This is the subtle half, and it is what makes the restart set exactly
`{D}`.

A descendant's capabilities were minted against an incarnation of `D`
that no longer exists. Auto-restarting the descendant would require the
kernel to re-mint that authority — but the kernel cannot attribute the
new grant to anyone: the principal that justified it is dead, and the
restarted `D` has not yet asked for anything. Re-minting anyway is
precisely the mistake §6 exists to prevent, one level up.

The sound answer is the one hotplug already uses: the restarted `D`
re-enumerates its bus and re-registers its children, at which point every
child capability is minted afresh against a live, identified principal.
The kernel's job on the way down is to leave no descendant descriptor
behind, so `driver_restart_kill_descendants` unregisters each one after
tearing it down.

---

## 4. What "restart" means against the FSM

### 4.1 The walk down is ordinary FSM traffic

`driver_restart_force_stop` drives the node to the terminal state using
only whitelisted edges:

```
  Init      → Stopping → Stopped
  Running   → Stopping → Stopped
  Suspended → Stopping → Stopped
  Handoff   → Stopping → Stopped
  Stopping  → Stopped
  Stopped   → (already there)
```

It is a bounded loop — at most two edges from any state, with a hard cap
of eight iterations — and every step goes through
`driver_lifecycle_transition`, so every step is validated against
`DRIVER_LIFECYCLE_TABLE` and the descriptor is the only thing that
records state.

**The `Init → Stopping` edge is new in this landing.** It was already the
documented intent of the FSM — `lifecycle.pdx` §R29.M5-003 describes the
signature-check path as "walking Init -> Stopping without the driver ever
executing" — but byte 0 of the packed table admitted only `Running`, so
the documented path was unreachable. Restart makes the gap load-bearing:
a driver that faults during its own initialisation is in `Init`, and
without this edge it could never reach `Stopped` and could never be
reaped. The table constant moves from `0x00000020101A1C02` to
`0x00000020101A1C12` (byte 0: `0x02 → 0x12`). No previously legal
transition changes, and no previously refused transition other than this
one becomes legal.

### 4.2 The walk back up is *not* an FSM edge, and must not be

`Stopped` stays terminal. There is no `Stopped → Init` transition, and
adding one would be a mistake: it would say that the thing which comes
back is the same driver that died, and every capability decision in §6
depends on it not being.

Instead, `driver_table_rearm_incarnation` **retires one incarnation and
installs the next in the same descriptor slot**. It is a storage-layer
operation, not a lifecycle transition, and it is gated so that it cannot
be used as an FSM bypass:

| gate | refusal |
| --- | --- |
| slot in range and `in_use` | `DRIVER_TABLE_REARM_BAD_SLOT` |
| state == `Stopped` | `DRIVER_TABLE_REARM_NOT_STOPPED` |
| no live DMA domain (`[+32]` present bit clear) | `DRIVER_TABLE_REARM_DOMAIN_LIVE` |
| `perm_failed` clear | `DRIVER_TABLE_REARM_PERM_FAILED` |

Only when all four hold does it commit: state byte → `Init`, `[+32]` →
zero, and the incarnation counter in `[+40]` bits [23:16] increments. The
increment is not bookkeeping — it is the identity change, and it happens
in the same store as the state reset so no observer can see incarnation
`N`'s number over incarnation `N+1`'s state.

The `Stopped` + no-domain gates mean re-arming is unreachable until
`driver_lifecycle_teardown` has revoked the domain, released the IOMMU
context entry, and cascaded through the memory root. Capability state is
therefore **rebuilt, never inherited**: the new incarnation starts with an
empty `[+32]` and mints a fresh domain on its own `Init → Running` edge.
What survives a restart is exactly the descriptor identity that the
supervisor owns — slot, pid field, name, caps-manifest offset, parent
link, and the restart budget — and nothing the driver itself held.

---

## 5. Restart budget, rate-limit, and escalation

### 5.1 The mechanism

Per-driver, carried in the supervision word:

* `restart_count` — restarts observed inside the current window.
* `window_start_coarse` — `kread_tsc() >> 20`, truncated to 40 bits.

`kread_tsc` is the monotonic source already used to timestamp every
driver audit record (`audit_channel.pdx §drv_audit_emit`); no new clock is
introduced. The `>> 20` shift buys range: 40 bits of coarse ticks covers
60 bits of TSC, roughly a decade at 3 GHz, so the field cannot wrap during
a boot.

On each restart:

```
  now = kread_tsc() >> 20                    (40 bits)
  if restart_count == 0 or now - window_start >= WINDOW:
      window_start = now
      restart_count = 0
  restart_count += 1
  if restart_count > MAX_INTENSITY:  escalate
```

`MAX_INTENSITY = 5`, `WINDOW = 32768` coarse ticks (≈ 11 s at 3 GHz) —
deliberately close to the OTP default shape of a handful of restarts
inside roughly ten seconds. The `restart_count == 0` arm makes the first
restart always open a fresh window, so the sequence is deterministic from
a cold descriptor regardless of how long the machine had been up.

Subtracting an unsigned `window_start` that somehow exceeds `now` yields a
huge difference and therefore a window reset — the conservative direction,
since a reset can only *delay* escalation and never fabricate one.

### 5.2 Escalation is the FSM's own terminal state

Escalation invents nothing. The node has already walked
`… → Stopping → Stopped` through the whitelist by the time the budget is
consulted, so it is sitting in the FSM's terminal state via a legal
transition. Escalation consists of *not re-arming it* — and of setting
`perm_failed` so that nothing else re-arms it either.

This is why `perm_failed` is checked inside
`driver_table_rearm_incarnation` rather than only in the restart driver.
Terminality is enforced at the store, so it holds against every future
caller, not just against the one that exists today. A permanently-failed
driver has exactly two legal futures: stay in `Stopped`, or be
unregistered by the supervisor and registered again as a genuinely new
driver.

`driver_restart_node` refuses up front with `DRV_RESTART_ERR_PERM_FAILED`
on an already-escalated node, so a crash-loop cannot even pay the cost of
the teardown walk once escalation has landed.

---

## 6. ChannelDead: recovery of dependent clients

### 6.1 The failure being closed

A client blocked in `sys_ipc_recv` on an endpoint served by a driver that
just died waits forever. The wake source (`sys_ipc_send`) is the dead
driver. Nothing else will ever touch `endpoint.waiter_tcb`. This is the
hang #1048 names.

### 6.2 Binding endpoints to driver incarnations

The endpoint row's previously-reserved `[+40]` word becomes the **driver
binding word**:

```
[+40] u64 binding word
  bits [4:0]    driver_slot
  bit  [5]      bound
  bit  [6]      dead
  bits [15:8]   incarnation      (the driver incarnation this serves)
  bits [63:16]  reserved
```

`endpoint_bind_driver(id, driver_slot, incarnation)` stamps it. Free rows
are fully zeroed by `endpoint_free`, so a freshly allocated endpoint is
unbound and alive by construction.

### 6.3 The cascade

`driver_restart_reap_endpoints(driver_slot)` scans all 128 rows and, for
each live row bound to that slot and not already dead:

1. `endpoint_mark_dead(id)` — sets the dead bit **first**, then reads and
   clears `waiter_tcb`, returning the previous value. The ordering is
   load-bearing: a woken waiter re-examining the endpoint must never find
   it alive, so the dead bit is published before the wake becomes
   possible. It mirrors the clear-before-wake discipline
   `sys_ipc_send_body` step 4 already uses.
2. Emits a `DRV_AUDIT_EV_CHANDEAD` record (subject = driver slot,
   principal = endpoint id) so the reconciler in #1046 can account for
   every channel torn down by a restart.
3. `sched_wake(waiter)` if there was one — the same idempotent
   `sched_wake` `sys_ipc_send_body` uses, so a spurious double-wake
   cannot corrupt the runqueue.

This runs inside `driver_restart_kill_one`, so it applies to the dead node
and to every descendant, before any teardown.

### 6.4 The woken client's return path

`sys_ipc_recv_body` checks `endpoint_is_dead(id)` at the **top of its
retry loop**, before `user_bounce_recv`:

* A client already blocked wakes, loops, sees the dead endpoint, and
  returns `-ECONNRESET` (`0xFFFFFFFFFFFFFF98`) instead of re-blocking.
* A client that calls `recv` on an already-dead endpoint returns the same
  error without ever blocking.

The check precedes the drain deliberately. A residual message sitting in
a dead endpoint was published by an incarnation that no longer exists and
whose authority is revoked; delivering it would let a client act on a
reply from a driver that is gone. A dead channel delivers nothing.

`sys_ipc_send_body` carries the mirror check at entry. A send to a dead
driver that returned `OK` would be worse than a hang: the client would
believe its request was accepted, and the message would sit in a row
nobody will ever drain. Both directions return the same
`-ECONNRESET`-class code so a client can handle "the server is gone" in
one place.

`-ECONNRESET` (104) rather than a bespoke code: it is already the POSIX
meaning of "the peer went away mid-conversation", it is distinct from the
handlers' existing `-EFAULT` (14) and `-EBADF` (9), and a client that
happens to be a port of existing code handles it correctly by accident.

### 6.5 Why a stale endpoint capability cannot attach to the restarted driver

This is the security-relevant half of #1048. A client holds a
`KIND_IPC_ENDPOINT` capability naming endpoint id `E`. The driver serving
`E` dies and is restarted. If `E` were silently re-bound to the new
incarnation, the client would hold authority over a principal it never
re-crossed a boundary to reach — the restart would launder a stale grant
into a live one.

Two mechanisms close this, and the first is sufficient on its own:

**A dead endpoint is never revived.** `endpoint_bind_driver` refuses a row
whose dead bit is set, with `EP_BIND_ERR_DEAD`. There is no "un-dead"
operation. The only exit from the dead state is `endpoint_free`, which
zeroes the whole row — and after a free, the stale capability names a row
that `endpoint_lookup` reports as not live, so every syscall on it
returns `-EBADF`. The restarted driver must therefore call
`endpoint_alloc` and obtain a **fresh** endpoint id, which the client can
only reach by going back through `sys_svc_lookup` and being minted a new
capability.

**The incarnation must match.** `endpoint_attach_ok(id, slot, incarnation)`
returns 1 only for a row that is live, bound, not dead, bound to that
driver slot, *and* carrying that incarnation number. It is the predicate
any future attach path (R30's driver-side dispatch loop) must consult, and
it fails closed on a row whose incarnation has moved on even if some later
code path forgets the dead-bit rule.

The witness asserts both: `endpoint_bind_driver(E_old, D, 1)` →
`EP_BIND_ERR_DEAD`, `endpoint_attach_ok(E_old, D, 1)` → 0, while a freshly
allocated `E_new` binds and attaches cleanly at incarnation 1.

---

## 7. Audit

Three event codes join `audit_channel.pdx`, continuing the existing
non-capability-event convention of `kind = 0` established by
`DRV_AUDIT_EV_HANDOFF`:

| code | event | subject | principal | outcome |
| --- | --- | --- | --- | --- |
| 4 | `DRV_AUDIT_EV_RESTART` | driver slot | new incarnation | 0 |
| 4 | `DRV_AUDIT_EV_RESTART` | descendant slot | slot that died | 1 = cascaded stop, not restarted |
| 5 | `DRV_AUDIT_EV_ESCALATE` | driver slot | restart count | 1 |
| 6 | `DRV_AUDIT_EV_CHANDEAD` | driver slot | endpoint id | 0 |

Because the records are sealed and sequenced by the same
`drv_audit_emit`, `drv_audit_gap_check` and `drv_audit_seal_check` cover
restart history for free, and #1046's post-restart accounting has a
complete trace: every channel that died, every node that was cascaded,
every re-arm, and the escalation that ended the loop.

---

## 8. What is deliberately not here

* **A restart back-off delay.** The budget bounds the *number* of
  restarts in a window, which is what stops a crash loop from consuming
  the machine. Sleeping between restarts additionally requires a timer
  capability held by the supervisor and a scheduler that can park it —
  R30 territory. The rate-limit is the part that has to exist for the
  loop to be bounded, and it exists.
* **SMP safety.** The supervision word is read-modify-written across
  several stores, and the endpoint scan is not atomic against a
  concurrent `endpoint_alloc`. This matches the concurrency note the
  driver table and endpoint table already carry (single-flow,
  non-preemptible at this layer). A per-row lock or a generation counter
  lands with the SMP pass, not here.
* **Chaos injection and post-restart accounting.** #1045 and #1046,
  deliberately written against this completed mechanism rather than
  alongside it.
