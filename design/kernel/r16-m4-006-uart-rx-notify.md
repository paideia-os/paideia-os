---
issue: 600
milestone: R16.M4 (UART input driver — 16550 RX interrupt-driven)
subsystem: 14 — UART input driver (16550 RX interrupt-driven)
topic: uart_rx_notify — KIND_NOTIFICATION-style single-waiter slot; ISR-tail wake_if_waiter; consumer-side set_waiter primitive
prereq:
  - "R15-M7-006 / #567 (LANDED; core/sched/wake_block.pdx.sched_wake — sole external non-uart call. Signature `(u64) -> () !{mem} @{sched}`; enqueues target on runqueue after flipping STATE_WAITING (2) → STATE_RUNNABLE (1). This issue relies on that state-machine contract for the wake-side observable.)"
  - "R15-M7-002 / #563 (LANDED; core/sched/runqueue.pdx — runq_enqueue/runq_dequeue + `_block_witness_task_x : [u64; 56]` slab. This issue reuses the same slab as the waiter TCB fixture; runq_dequeue at the witness tail drains the wake side-effect so subsequent kernel_main flow sees an empty runq.)"
  - "R16-M4-003 / #597 (LANDED; core/uart/rx_isr.pdx.uart_rx_isr — the ISR body this issue extends with a wake-if-waiter tail. Empty-drain contract at §7.1 of #597 must survive the extension: at the M4-003 witness point (no waiter installed, `_uart_rx_notify_waiter == 0`), the added call MUST reduce to a load + compare + branch + ret, leaving `_uart_rx_head` unchanged as its own witness already asserts.)"
  - "R16-M4-002 / #596 (LANDED; core/uart/rx_ring.pdx.uart_rx_enqueue/uart_rx_dequeue — the ring this issue's notification decorates. This issue writes/reads no ring bytes on its own; every byte flow goes through the ring already.)"
  - "R16-M4-001 / #595 (LANDED; establishes core/uart/ directory. This issue extends it with rx_notify.pdx.)"
blocks:
  - "#601 (r16-m4-007 RX smoke — end-to-end AC (\"UART RX: abc\" after 3-char injection). Consumer half — sys_read blocking on the notification — is exercised only when #601's stdin-injection fixture is present.)"
related:
  - src/kernel/core/uart/rx_isr.pdx                     (R16-M4-003 / #597 — this issue extends its epilogue with
                                                          a single `call uart_rx_notify_wake_if_waiter` inserted
                                                          BEFORE `call apic_eoi`. Precedent for producer-then-wake-
                                                          then-EOI is `handle_timer` (exceptions.pdx:138) which
                                                          calls sched_tick_r15 before apic_eoi. This issue mirrors
                                                          that discipline verbatim.)
  - src/kernel/core/uart/rx_ring.pdx                    (R16-M4-002 / #596 — read/written by the ring path only.
                                                          This issue introduces no new coupling between wake and
                                                          ring state. Spurious wake (waiter set but no byte
                                                          enqueued at this ISR entry) is safe: consumer re-checks
                                                          the ring on wake and re-blocks if empty, per §3.4 of
                                                          this doc.)
  - src/kernel/core/sched/wake_block.pdx                (R15-M7-006 / #567 — sched_wake is the sole side-effect
                                                          endpoint. Signature `!{mem} @{sched}`. Reading its
                                                          precondition list at §6.2 of #567's design: target
                                                          must be non-null, state == STATE_WAITING (2), off runq.
                                                          This issue's contract for the consumer's set_waiter call
                                                          matches those preconditions exactly — see §3.5.)
  - src/kernel/core/sched/runqueue.pdx                  (R15-M7-002 / #563 — reuses `_block_witness_task_x`
                                                          448-byte slab as the waiter TCB fixture. Same slab used
                                                          by the block_wake_witness in kernel_main.pdx:4322; the
                                                          two witnesses run at different kernel_main positions
                                                          and clean up after themselves (both call runq_dequeue at
                                                          tail).)
  - src/kernel/core/cap/kind_notification.pdx           (R13-m6-006 / #454 — the userland-facing KIND_NOTIFICATION
                                                          cap primitive. This issue's producer-side wake path is
                                                          the kernel-internal counterpart to that userland
                                                          OP_SIGNAL. Semantic mapping documented in §3.7. At
                                                          R16.M4-006 the two remain distinct symbols — cap-table
                                                          integration is deferred to §6.5.)
  - src/kernel/core/apic/eoi.pdx                        (R9-m2-003 / #358 — apic_eoi is called AFTER the wake
                                                          in the extended ISR epilogue. Ordering justified in §3.6.)
  - src/kernel/boot/kernel_main.pdx                     (block_wake_witness at line 4322 — the discipline
                                                          template for driving a witness against a fake TCB. This
                                                          issue's witness mirrors that structure: zero the fake
                                                          TCB, flip state, drive the primitive, assert
                                                          post-state, drain.)
  - design/kernel/r16-m4-003-uart-rx-isr.md             §7.1, §8 — freezes the "head unchanged on empty drain"
                                                          invariant that this issue must not violate; §6.4
                                                          re-defers `_uart_rx_dropped_count` to this issue.
                                                          Deferral status re-answered in §6.4 of this doc.
  - design/kernel/r15-m7-006-sched-block-wake.md        (LANDED; sched_block/sched_wake contract. This issue is
                                                          the first non-witness caller of sched_wake in the tree.)
  - design/milestones/r14b-tactical-plan.md             §Subsystem 14, item 6 (this issue's plan pointer)
---

# R16-M4-006 — `uart_rx_notify`: single-waiter slot + ISR-tail wake (#600)

## 1. Scope

Land the sixth R16.M4 subsystem-14 issue: the kernel-internal
plumbing that lets a byte arriving at COM1 wake a task that is
blocked waiting for input. Concretely:

- A single `.bss` slot `_uart_rx_notify_waiter : u64` (0 = no
  waiter, else TCB base address of a task in `STATE_WAITING`).
- A leaf primitive `uart_rx_notify_set_waiter(tcb)` that stores
  a TCB pointer into the slot. Called by the consumer (a future
  `uart_rx_read` / `sys_read` on `/dev/ttyS0`) *after* the
  consumer has flipped its own state to `STATE_WAITING` and
  detached from the runqueue.
- A leaf primitive `uart_rx_notify_wake_if_waiter()` that reads
  the slot; if non-zero, clears it and calls `sched_wake(tcb)`.
  Called from the tail of `uart_rx_isr` (this issue extends
  `rx_isr.pdx` by one line).

```
uart_rx_notify_set_waiter(tcb : *TCB) -> ()
    precondition:  tcb != 0, tcb.state == STATE_WAITING (2), tcb off runq
    side effect:   _uart_rx_notify_waiter := tcb
    postcondition: _uart_rx_notify_waiter == tcb

uart_rx_notify_wake_if_waiter() -> ()
    input:  (none)
    output: (none)
    side effect: if _uart_rx_notify_waiter != 0:
                     tmp := _uart_rx_notify_waiter
                     _uart_rx_notify_waiter := 0
                     sched_wake(tmp)          ; state WAITING→RUNNABLE, enqueue on runq
                 else: no-op.
```

Acceptance (issue AC): **fixture blocks; injected char wakes.**
That AC is composed of two halves:

- **"fixture blocks"** — the consumer path that transitions
  `_current_tcb` to `STATE_WAITING` and switches away via
  `sched_block`. That path is `sched_block` itself (landed at
  #567), gated by a caller that installs a waiter first. The
  caller is the future `uart_rx_read` / `sys_read` handler, not
  yet wired at R16.M4-006 because the syscall dispatch chain
  for `read()` against a `/dev/ttyS0` vnode does not yet exist
  (Subsystem 15 TTY + Subsystem 18 shell). What R16.M4-006 lands
  is the **producer-side wake and the state slot the consumer
  will target**; the consumer's syscall integration lands at a
  later R16.M5+ issue once TTY is in place.
- **"injected char wakes"** — the ISR must, on producing a byte
  into the ring, transition an already-parked waiter from
  `STATE_WAITING` back to `STATE_RUNNABLE` and back onto the
  runqueue. This half is entirely at this issue's scope and is
  the primary witness observable.

The witness is therefore a **manual half-cycle proof**: install
a fake TCB in `STATE_WAITING`, register it in the waiter slot,
call `uart_rx_isr` (which reaches the wake tail), and verify (a)
the slot is cleared to 0, (b) the fake TCB is `STATE_RUNNABLE`,
and (c) the fake TCB is on the runqueue. The parked-side of the
cycle (the blocked task actually resuming from `sched_block`) is
exercised end-to-end at #601 once TTY reads are wired.

### 1.1 What this issue proves

- **The ISR-tail wake path composes.** `uart_rx_isr` gains one
  `call uart_rx_notify_wake_if_waiter` before its existing
  `call apic_eoi`. Verified by sub-test B calling `uart_rx_isr`
  with a fake waiter installed and observing the wake side-effect
  the sub-test A already isolated.
- **`sched_wake` is called with a legally-shaped target from a
  non-witness site.** Before this issue, `sched_wake` had exactly
  one non-witness caller — none. Every landed use was inside the
  R15.M7 witness itself. This issue is the first "real" caller —
  from within a hot ISR path — and inherits sched_wake's
  precondition list (§6.2 of #567 design). The consumer-side
  `set_waiter` primitive is what enforces those preconditions on
  the parking side; §3.5 unpacks the invariant.
- **The empty-drain invariant of `uart_rx_isr` (§7.1 of #597) is
  preserved.** At the M4-003 witness point, `_uart_rx_notify_waiter`
  is `.bss`-zero. The added `call uart_rx_notify_wake_if_waiter`
  reduces to a load, a `test`, a `jz`, and a `ret` — 4
  instructions, no side effect. `_uart_rx_head` remains
  unchanged (still asserted by the M4-003 witness), sched_wake is
  not called, no runqueue mutation occurs.
- **A single-waiter slot is a legal SPSC contract at R16.M4.**
  The producer (ISR) is single: only IRQ 4 delivery through
  vector 0x24 on CPU 0 fires it, IF=0 by construction, and R17
  SMP will keep IRQ 4 UP-affine (§7.5 of #597). The consumer is
  single by design at R16.M4: only one task can be blocked on
  `/dev/ttyS0` reads because there is only one such vnode and
  only one `_current_tcb`. §3.3 unpacks why "at most one waiter"
  is the correct type for R16.M4 and §6.6 defers the
  multiple-reader case to R17.
- **The waiter slot's clear-before-wake ordering is correct.**
  `wake_if_waiter` reads the slot into a scratch register,
  writes 0 to the slot, THEN calls `sched_wake`. Reading the
  slot into rdi *before* clearing means the argument to
  sched_wake is stable across the clear (§3.8). Doing the clear
  before sched_wake means if sched_wake were preempted (it isn't
  at R16.M4 — UP + IF=0 inside the ISR — but the property is
  worth preserving for R17), a second ISR entry sees `_waiter=0`
  and does not double-wake.

### 1.2 What this issue deliberately does NOT do

- **No `uart_rx_read` / consumer-side blocking primitive.** The
  parent agent's context suggested a "skeleton uart_rx_read", but
  paideia-os discipline (see the issue body's Discipline block:
  *"No stub / placeholder implementations shipped — backtrack via
  new issue if a design gap surfaces"*) rules that out. A read
  primitive without TTY + syscall dispatch has no legal caller.
  Shipping it as an unreachable symbol would (a) inflate the
  effect/capability set of the module, (b) fail
  `find-unused-symbol` audits, and (c) invite future callers to
  bind against a contract that has not yet been proven end-to-end.
  Instead, the consumer-side primitive shipped here is
  `uart_rx_notify_set_waiter(tcb)` — a legal, testable, minimally-
  scoped primitive that stores a TCB pointer into the slot. It IS
  what a future `uart_rx_read` will call between `sched_block`'s
  step (2) (state = WAITING) and step (3) (runq_dequeue). The
  witness exercises it directly.
- **No syscall dispatch integration.** `sys_read` against a
  `/dev/ttyS0` vnode requires (a) the TTY vnode subsystem
  (Subsystem 15, R16.M5), (b) an fd table that includes fd 0
  mapped to that vnode (Subsystem 13, partial), and (c) the
  cooked-line discipline that consumes bytes from the RX ring
  and emits complete lines to the reader. None of that exists at
  R16.M4-006. Wire-up is deferred to the R16.M5 shell subsystem
  where the whole chain closes.
- **No KIND_NOTIFICATION cap-table entry for RX.** The R13
  `KindNotification` module (cap/kind_notification.pdx) is a
  userland-facing counting semaphore over a 64-slot notification
  pool. Its OP_SIGNAL bumps `pending_count` and stores a payload;
  its OP_WAIT decrements or returns WOULD_BLOCK. That is the
  right shape for **userland** consumers signaling each other via
  capability invocation. The RX ISR runs in **kernel context**
  and wakes a **specific kernel-side blocked task** — a different
  mechanism. Two designs, both legitimate: this issue lands the
  kernel-internal one; the eventual cap-table entry for RX (an
  entry in `_notification_pool` whose OP_SIGNAL is bumped by this
  ISR instead of by userland) is a §6.5 follow-up once a userland
  process needs a KIND_NOTIFICATION handle to RX (post-TTY).
- **No `cli` / `sti` in `wake_if_waiter`.** The sole caller at
  R16.M4-006 is `uart_rx_isr`, which runs with IF=0 by
  construction (IDT interrupt gate; §7.5 of #597). No re-entrant
  ISR can preempt `wake_if_waiter`. The (deferred) userland path
  that calls `set_waiter` between `sched_block` steps (2) and (3)
  is itself inside sched_block's own atomicity window (§7.2 of
  #567 explicitly notes a `cli`-bracket is deferred to #565 for
  that path). Adding a redundant `cli` here would be hostile to
  the R17 nested-interrupt design.
- **No overrun counter.** `_uart_rx_dropped_count` was
  re-deferred to this issue by §6.4 of #597. On mature
  reflection it is still deferred: the AC does not require it,
  and adding a counter alongside the notify plumbing dilutes
  this issue's bisect surface. Filed as a follow-up in §6.4.
- **No "double-wake avoidance across concurrent ISRs".** At R16.M4
  UP + IF=0 during the ISR, no second ISR entry can race the
  first — the LAPIC in-service bit for vector 0x24 stays set
  until `apic_eoi` at the ISR's exit, which sequences before any
  next-entry EOI-gated delivery. The read+clear pattern in
  `wake_if_waiter` is nonetheless serialized in the natural
  ordering, and is R17-SMP-ready modulo one atomic-exchange
  substitution (documented in §6.7).
- **No priority-based preemption on wake.** `sched_wake` explicitly
  does not switch (see §5 of #567 — "wake without switch"). This
  issue inherits that discipline: the ISR keeps running through
  its EOI + iretq; the just-woken task will be picked at the
  next `sched_pick_next` (typically at the next timer tick, or
  cooperatively). Priority-preemption-on-wake is a Phase-9
  concern.
- **No effect signature widening on `uart_rx_isr`.** Extending
  the ISR to call `wake_if_waiter` — which transitively calls
  `sched_wake` — adds `sched` to the ISR's capability set. That
  is a real widening. But it is *correct* (the ISR is legitimately
  a scheduler-touching function now, exactly like `handle_timer`),
  and the trampoline `_uart_rx_trampoline` (#598, LANDED) already
  runs at boot cap. Documented in §3.9.

## 2. Prereq check

### 2.1 What is in place

| Primitive                              | Location                                           | Contract used                                                                                            |
|----------------------------------------|----------------------------------------------------|----------------------------------------------------------------------------------------------------------|
| `sched_wake`                           | `core/sched/wake_block.pdx:68` (R15-M7-006, #567)  | `(u64) -> () !{mem} @{sched}`. Marks target `STATE_RUNNABLE`, `runq_enqueue`s. Wake without switch.       |
| `runq_enqueue` (transitive)            | `core/sched/enqueue.pdx` (R15-M7-002, #563)        | Called inside `sched_wake`. Callee-save clean per its own contract.                                       |
| `_block_witness_task_x`                | `core/sched/runqueue.pdx:72`                       | Reused as this issue's waiter TCB fixture (448 bytes, fields at +8 state / +432 runq_next / +440 runq_prev). |
| `_current_tcb`                         | `core/sched/runqueue.pdx:85`                       | Not touched by this issue's code — only relevant for the (deferred) consumer path.                        |
| `_uart_rx_head`                        | `core/uart/rx_ring.pdx:25`                         | Snapshotted-and-compared by the M4-003 witness; must remain untouched by the added wake tail.             |
| `uart_rx_isr`                          | `core/uart/rx_isr.pdx:48` (R16-M4-003, #597)       | The site of the one-line extension. Empty-drain invariant at §7.1 of #597 pinned as a witness assertion. |
| `apic_eoi`                             | `core/apic/eoi.pdx:30` (R9-m2-003, #358)           | Unchanged — called last, after the new wake tail, preserving in-service semantics.                        |
| `uart_puts`                            | `boot/uart.pdx`                                    | Witness diagnostic emission.                                                                              |
| `.bss` `u64` slot idiom                | `core/uart/rx_ring.pdx:26`                         | Freezes the "`pub let mut _sym : u64 = 0`" declaration; this issue introduces one such slot.              |
| `mov [rip + _sym], reg` / `mov reg, [rip + _sym]` | `core/uart/rx_ring.pdx:49,70`           | Both directions of the RIP-relative slot access used by this issue's set/wake primitives.                 |
| `test rax, rax; jz label`              | Ubiquitous.                                        | Nil-check pattern for the wake fast path.                                                                 |

### 2.2 What is NOT in place

- **`uart_rx_notify_set_waiter` / `uart_rx_notify_wake_if_waiter`
  symbols.** Introduced by this module.
- **`_uart_rx_notify_waiter` .bss slot.** Introduced by this module.
- **`uart_rx_notify_ok_msg` / `uart_rx_notify_fail_msg`
  rodata.** Added to `tools/boot_stub.S`.
- **Wake tail in `uart_rx_isr`.** Added by this issue as a
  minimal one-line edit to `rx_isr.pdx`.
- **`_uart_rx_dropped_count` overrun counter.** Deferred; see §6.4.
- **Consumer-side blocking read primitive (`uart_rx_read`) /
  syscall integration for `/dev/ttyS0`.** Not this issue's
  concern; see §1.2 and §6.1.

### 2.3 Encoder gaps

**None.** Every mnemonic used has landed precedent.

| Mnemonic form                        | Proven at                                                      |
|--------------------------------------|----------------------------------------------------------------|
| `mov [rip + _sym], reg`              | `core/uart/rx_ring.pdx:70` (`mov [rip + _uart_rx_head], rcx`).  |
| `mov reg, [rip + _sym]`              | `core/uart/rx_ring.pdx:49` (`mov rcx, [rip + _uart_rx_head]`).  |
| `mov rdi, rax`                       | `core/uart/rx_isr.pdx:68`.                                     |
| `xor rax, rax` / `xor rcx, rcx`      | Ubiquitous (`core/sched/enqueue.pdx`, `runqueue.pdx`).         |
| `test rax, rax` (encoding `test r,r`) | `core/sched/wake_block.pdx` (indirectly via cmp+jne) — but the safer landed idiom is `cmp rax, 0; je label`, which THIS issue adopts to match §7.1's read of `uart_rx_isr`'s own poll idiom (`cmp rax, 0; je urxi_drain_done` at `rx_isr.pdx:62`). No `test r,r` used; see §3.8.                                                                    |
| `cmp rax, 0` / `je label`            | `core/uart/rx_isr.pdx:61,62`.                                  |
| `call sym`                           | Ubiquitous.                                                    |
| `ret`                                | Ubiquitous.                                                    |
| `pub let mut _sym : u64 = 0`         | `core/uart/rx_ring.pdx:26,27` (`_uart_rx_head`, `_uart_rx_tail`). |

No SIB. No REX.B on extended registers. No new mnemonic. No 32-bit
port I/O. No MMIO write. **Cross-repo escalation not needed.**

## 3. Design

### 3.1 File and module structure

New file: `src/kernel/core/uart/rx_notify.pdx`. Fills the fourth
slot in the R16.M4 planned family per §3.1 of #597:

```
src/kernel/core/uart/
    rx_init.pdx        (#595, LANDED — IER=0x01)
    rx_ring.pdx        (#596, LANDED — 256-slot SPSC ring + enqueue/dequeue)
    rx_isr.pdx         (#597, LANDED — drain + EOI)  ←── EXTENDED by this issue
    rx_trampoline.pdx  (#598, LANDED — IDT vec 0x24 trampoline)
    rx_notify.pdx      <-- THIS ISSUE (#600 — waiter slot + set/wake primitives)
```

Module name: `RxNotify`. Public exports: `_uart_rx_notify_waiter`,
`uart_rx_notify_set_waiter`, `uart_rx_notify_wake_if_waiter`. No
internal-only helpers.

### 3.2 State: single-waiter slot

```pdx
// Single-waiter slot. 0 = no waiter. Else = TCB base address of
// a task in STATE_WAITING, off the runqueue, that will be woken
// by the next byte arriving at COM1 through uart_rx_isr.
pub let mut _uart_rx_notify_waiter : u64 = 0
```

**Why `u64` and not `[u64; N]`?** §3.3 unpacks it: at R16.M4 there
is provably at most one blocked reader of `/dev/ttyS0` at a time
(one vnode, one `_current_tcb`, no thread-per-fd yet). A single
`u64` slot is the minimum-viable data structure that admits the
"install waiter → wait → wake" cycle. Bytes-per-slot vs.
alternative designs are tabled in §3.5.

**Why `.bss` (zero-init) instead of an explicit init call?** Same
reason as `_uart_rx_head`/`_uart_rx_tail` at #596: `.bss` zero-
initialization gives the "no waiter" state (0) for free at kernel
entry, so no init call needs to be added to `kernel_main` — the
system is in a valid state before anyone has installed themselves
as a waiter.

**Why `pub`?** The waiter slot is inspected by both `set_waiter`
and `wake_if_waiter`, and by the witness at kernel_main. Marking
it `pub` matches the discipline in `rx_ring.pdx` for `_uart_rx_head`
and `_uart_rx_tail`.

### 3.3 Single-waiter invariant

At R16.M4 the invariant `|blocked readers of /dev/ttyS0| ≤ 1`
holds by three concurrent facts:

1. **One vnode.** `/dev/ttyS0` is one path, one vnode — the RX
   driver exposes exactly one input stream.
2. **One `_current_tcb`.** Only the currently-running task can
   call `sched_block`. Two tasks cannot simultaneously enter
   `sched_block`. The single-CPU R16.M4 world enforces this
   trivially.
3. **No thread-per-fd fanout.** Even in R15's process/thread
   model, one process gets one blocking `read()` call at a time
   on a given fd. Multi-thread contention on a single fd is a
   real R17+ scenario (§6.6), not an R16 scenario.

**Consequence.** The single-slot `_uart_rx_notify_waiter` is a
lossy-but-correct data structure for R16.M4: two calls to
`set_waiter` in a row (which cannot legally happen — no one is
running while the previous caller is `sched_block`ing) would
overwrite. R17 SMP + multi-reader requires a per-vnode wait queue;
that migration is `_uart_rx_notify_waiter : u64` → `waitq_head :
u64` (linked list of TCBs), a mechanical change confined to this
module. §6.6 unpacks.

### 3.4 Wake ordering: read → clear → sched_wake

The wake primitive's shape is:

```
    uart_rx_notify_wake_if_waiter:
        mov rax, [rip + _uart_rx_notify_waiter]
        cmp rax, 0
        je  urxn_no_waiter                   ; fast path: 4 instructions total

        mov rdi, rax                         ; SysV arg 0 = target TCB
        xor rax, rax
        mov [rip + _uart_rx_notify_waiter], rax   ; clear slot BEFORE waking

        call sched_wake                      ; state WAITING→RUNNABLE + runq_enqueue

    urxn_no_waiter:
        ret
```

**Read → clear → wake, in that order, for four concurrent
reasons:**

- **Clear-before-wake means at most one wake per install.** If
  the ordering were wake-before-clear, then a re-entrant path
  (theoretical only at R16.M4, but real at R17) could observe
  the slot still populated between the enqueue and the clear, and
  double-wake the same target. That would double-enqueue on the
  runqueue and corrupt the intrusive linked list. Not possible
  at R16.M4 (UP + IF=0), but the invariant is worth preserving
  for R17.
- **Read-into-rdi-before-clear means the argument is stable.**
  If the clear were done before loading rdi, the second load
  would find 0 and sched_wake would be called with a null TCB
  — undefined behavior per sched_wake's §6.2 preconditions.
  Reading first, clearing second, calling third is the only
  correct ordering.
- **The wake happens BEFORE `apic_eoi` at the ISR level.** See
  §3.6.
- **Spurious wake is safe.** If `set_waiter` were called but no
  byte arrived (impossible today — the ISR only runs on IRQ 4),
  or if the ISR fires before the ring has any byte for the
  consumer, the consumer wakes up, checks the ring, finds it
  empty, and re-blocks. This is standard `futex`/`sem_wait`
  wait-morphing discipline. The consumer is required to loop:
  `while ring_empty { install_waiter; sched_block; }` — the
  install-then-block sequence must be `cli`-bracketed by the
  consumer to avoid the "waiter installed but wake happened
  before block took effect" race. §6.2 of #567 flags that
  bracket as deferred; documented as a caller obligation in §3.5.

### 3.5 Consumer contract for `uart_rx_notify_set_waiter`

`uart_rx_notify_set_waiter(tcb)` is a leaf function with a strong
caller obligation:

```
    Precondition (caller-checked):
        tcb != 0
        tcb.state == STATE_WAITING (2)
        tcb is OFF the runqueue (runq_next == 0 && runq_prev == 0)
        _uart_rx_notify_waiter == 0                  ; no other waiter

    Sequence (canonical caller — future uart_rx_read):
        cli
        while (uart_rx_dequeue() == DEQUEUE_EMPTY):
            tcb.state = STATE_WAITING
            runq_dequeue(tcb)
            uart_rx_notify_set_waiter(tcb)
            sched_block()          ; releases cli via popfq inside sched_switch_r15
            ; --- resumed here on wake ---
        sti
        (byte in rax from the dequeue)
```

**Why the caller (not this issue) enforces the preconditions.**
Enforcing them here would require reading `tcb.state`, reading
`tcb.runq_next`, reading `_uart_rx_notify_waiter`, and either
returning an error code (unclean — no error type is defined for
this kernel-internal primitive yet) or panicking (destroys the
system for a caller bug). The R15.M7 primitives (`sched_wake`,
`sched_block`) took the same stance — caller-enforced
preconditions, silent on violation. §6.2 of #567 explicitly
documents this as design intent. R16.M4-006 inherits it.

The witness at §5 does NOT test violation paths — that would
require a poisoned-fixture harness this issue does not build.
Documented in §5.4 as a known coverage gap; filed as follow-up
§6.8.

### 3.6 Wake placement in `uart_rx_isr`: before EOI

The extended `uart_rx_isr` epilogue is:

```
    urxi_drain_done:
      call uart_rx_notify_wake_if_waiter    ; <-- NEW: wake, then EOI
      call apic_eoi
      add rsp, 8
      ret
```

**Wake-before-EOI, chosen for three reasons:**

1. **Matches the `handle_timer` precedent.** `handle_timer`
   (exceptions.pdx:138) calls `sched_tick_r15` (a scheduler-
   touching primitive) BEFORE `apic_eoi`. Same shape here. Prior
   art unanimous.
2. **The wake is short and constant-time.** `sched_wake` writes
   one u32 (state) and calls `runq_enqueue` (an intrusive-list
   insert). Both are O(1). Extending the ISR window by ~50
   cycles has negligible latency impact on the next IRQ 4
   delivery.
3. **Ordering matters for the consumer, not for the LAPIC.** The
   consumer needs to observe `state == RUNNABLE` and be on the
   runqueue *before* the next scheduler decision — i.e. before
   the next timer tick that might pick it. Placing the wake
   before the EOI means the wake side-effect is fully committed
   before the LAPIC releases vector 0x24, and therefore before
   any interrupt-driven `sched_switch` could observe the wake.
   Placing it after would create a (theoretical, R17-relevant)
   race where a preemption between EOI and wake sees the
   consumer still `STATE_WAITING`.

**Effect signature change on `uart_rx_isr`.** Currently
`!{sysreg, mem} @{boot}`. After extension, transitively via
`sched_wake`: `!{sysreg, mem} @{boot, sched}`. This is a genuine
widening — the ISR now has scheduler authority — and matches
what `handle_timer` already declares. Documented in §3.9.

### 3.7 Relation to `KindNotification` (`kind_notification.pdx`)

The R13 `KindNotification` handler (cap/kind_notification.pdx) is
a userland-facing counting-semaphore-with-payload primitive: 64
notification IDs, `pending_count` per ID, OP_SIGNAL bumps count +
stores payload, OP_WAIT decrements + returns payload or WOULD_BLOCK.

This issue's `_uart_rx_notify_waiter` is a **different** primitive:

| Aspect                | KindNotification (R13)        | uart_rx_notify (R16.M4-006, this)    |
|-----------------------|-------------------------------|--------------------------------------|
| Consumer type         | Userland process              | Kernel-internal blocked task          |
| Semantics             | Counting semaphore + payload  | Direct wake-one on event              |
| Storage               | Per-ID {count, payload}       | One TCB pointer                       |
| Trigger               | Userland OP_SIGNAL syscall    | Kernel-internal ISR-tail call         |
| Blocking mechanism    | OP_WAIT returns WOULD_BLOCK   | `sched_block` (self-suspend)          |
| Cap-table exposure    | Yes (via handle)              | No (kernel-only symbol)               |

**Why not extend `KindNotification` for RX instead of adding
`RxNotify`?** Three concurrent reasons:

- **No cap-table need at R16.M4.** No userland process holds a
  handle to /dev/ttyS0 yet — TTY is R16.M5, shell is R17.
  Bolting a KIND_NOTIFICATION handle into the kernel's ISR
  before any userland consumer exists to invoke OP_WAIT would
  be a fake abstraction.
- **The semaphore semantics are wrong for RX.** The RX ring is
  already the semaphore (256-byte buffer with head/tail
  counters). Adding a KIND_NOTIFICATION count on top would
  double-count and complicate the "byte arrived" event with a
  "notification pending" state.
- **`sched_block` / `sched_wake` are the correct primitives for
  kernel-side blocking.** They are the R15.M7 landing that the
  issue title's *"blocks on this cap when ring empty"* refers to
  in shape if not in name. §6.5 unpacks the eventual migration
  path: when userland needs a KIND_NOTIFICATION handle to RX
  (say, an `epoll`-like syscall on `/dev/ttyS0`), a KIND_NOTIF
  entry can be added whose OP_SIGNAL is bumped by *this issue's*
  `wake_if_waiter` in addition to (not instead of) the direct
  wake.

The issue title's phrase *"KIND_NOTIFICATION cap"* is thus best
read as **semantic ancestor**, not literal cap-table entry — the
mechanism this issue lands **is** kernel notification (signal one
blocked waiter on event), just implemented at the level of
directness R16.M4's kernel-only consumer requires. Documented as
a naming clarification in §6.5.

### 3.8 Alternatives considered — nil-check idiom

| Variant                              | Rejected because                                                                        |
|--------------------------------------|-----------------------------------------------------------------------------------------|
| **`cmp rax, 0; je label` (chosen)** | Matches the LSR/DR check idiom already in `uart_rx_isr:61-62`. Zero encoder novelty.    |
| `test rax, rax; jz label`            | Would introduce a new mnemonic form (`test r,r` — no landed precedent in RIP-relative-slot check sites). Costs one encoder-audit step for a 1-byte encoding win. Not worth the churn. |
| `or rax, rax; jz label`              | Older-style idiom, no landed precedent in this tree. Same drawback as `test`.           |

### 3.9 Alternatives considered — where to put the wake call

| Variant                                          | Rejected because                                                                          |
|--------------------------------------------------|-------------------------------------------------------------------------------------------|
| **`call wake_if_waiter` at ISR body tail before `apic_eoi` (chosen)** | Matches `handle_timer` (exceptions.pdx:138 → sched_tick_r15 before apic_eoi). Wake is committed before LAPIC in-service release. |
| Inline the wake logic directly in `uart_rx_isr`  | Duplicates the state-slot access; harder to unit-test independently; grows `rx_isr.pdx` by ~8 instructions for zero gain. |
| Place the wake in the trampoline `_uart_rx_trampoline` (rx_trampoline.pdx) instead of the ISR body | Bisect-hostile: the wake would be split from the ISR body across two files. `handle_timer` did NOT do this. Consistency wins. |
| Fire the wake AFTER `apic_eoi`                   | See §3.6. The wake side-effect must sequence before any potential scheduler decision that could observe it, and the LAPIC EOI is the earliest such point in the RX pipeline. |
| Wake only when a byte was actually enqueued (track `bytes_drained` in a callee-save register) | Adds a `push/pop rbx` around the drain loop and a `cmp rbx, 0; jz` at the wake site — 5 more instructions. Gains "no spurious wake" — but spurious wake is safe (§3.4) and cheap (fast-path is 4 instructions when the slot is 0). Rejected as a premature optimization. |

### 3.10 Alternatives considered — set_waiter signature

| Variant                                 | Rejected because                                                                             |
|-----------------------------------------|----------------------------------------------------------------------------------------------|
| **`set_waiter(tcb)` leaf (chosen)**     | Minimal; single store; matches sched_wake's discipline (caller enforces preconditions).      |
| `set_waiter(tcb) -> old`                | Returning the previous slot value ("compare-and-set") would let the caller detect stale-waiter bugs. But (a) no caller today can act on that return, and (b) the single-waiter invariant §3.3 makes stale-waiter a design-defect scenario, not a runtime scenario. Adding a return complicates the type without adding coverage. |
| `set_waiter(tcb) with internal precondition check + panic` | See §3.5. Caller-enforcement is the R15.M7 discipline; this issue inherits it. Panicking here would destroy the system on a caller bug (the correct response is either a `-EINVAL` return or an audit failure, neither of which is currently expressible). |

### 3.11 File contents

```pdx
// src/kernel/core/uart/rx_notify.pdx — R16-M4-006 (#600)
// uart_rx_notify: single-waiter slot + set/wake primitives.
//
// Storage:
//   _uart_rx_notify_waiter : u64  — 0 = no waiter; else TCB base
//                                    address of a task in
//                                    STATE_WAITING to wake when
//                                    a byte arrives at COM1.
//
// Primitives:
//   uart_rx_notify_set_waiter(tcb)     — leaf; stores tcb into the slot.
//                                        Called by the consumer between
//                                        sched_block's state=WAITING flip
//                                        and its runq_dequeue.
//                                        Preconditions: caller-enforced
//                                        (see design §3.5). No return.
//   uart_rx_notify_wake_if_waiter()    — non-leaf (calls sched_wake).
//                                        If slot != 0, clears it and
//                                        calls sched_wake(target). Called
//                                        from the tail of uart_rx_isr.
//
// See design/kernel/r16-m4-006-uart-rx-notify.md for full contract.

module RxNotify = structure {
  // === Storage (.bss slot; zero = "no waiter") ===
  pub let mut _uart_rx_notify_waiter : u64 = 0

  // ==========================================================================
  // uart_rx_notify_set_waiter — install a TCB as the RX waiter.
  //
  // Input:  rdi = TCB base address (non-zero, STATE_WAITING, off runq).
  // Output: (none)
  //
  // Side effects:
  //   Writes rdi to _uart_rx_notify_waiter.
  //
  // Clobbers (SysV caller-save):
  //   rax.
  // ==========================================================================
  pub let uart_rx_notify_set_waiter : (u64) -> () !{mem} @{sched} =
    fn (tcb: u64) -> unsafe {
      effects: { mem },
      capabilities: { sched },
      justification: "R16-M4-006 (#600): single-store slot install. Writes rdi (caller's TCB pointer) into _uart_rx_notify_waiter. Leaf function; no prologue; caller-save-only clobber (rax). Caller obligation (see design §3.5): tcb != 0, tcb.state == STATE_WAITING (2), tcb off runqueue, and _uart_rx_notify_waiter == 0 (no pre-existing waiter). Not enforced here — matches R15-M7-006 (#567) sched_wake's caller-enforced-precondition discipline (§6.2 of #567). Sole caller today is the block_wake witness at kernel_main; future canonical caller is the deferred uart_rx_read primitive between sched_block's steps (2) state=WAITING and (3) runq_dequeue, both bracketed inside sched_block's own cli window. Capability {sched}: this primitive touches the same waiter-slot invariant that sched_wake reads (§3.4 wake sequence), so scheduler-authority is the correct lens. Effect {mem}: single u64 store, no port I/O, no MMIO. Encoder: `mov [rip + _sym], rdi` — landed at core/uart/rx_ring.pdx:70 (identical form, different destination). Audit: r16-m4-006-uart-rx-notify.",
      block: {
        mov [rip + _uart_rx_notify_waiter], rdi;
        ret
      }
    }

  // ==========================================================================
  // uart_rx_notify_wake_if_waiter — wake the parked RX waiter, if any.
  //
  // Input:  (none)
  // Output: (none)
  //
  // Side effects:
  //   If _uart_rx_notify_waiter != 0:
  //     - loads target = _uart_rx_notify_waiter
  //     - clears the slot to 0
  //     - calls sched_wake(target)   ; state WAITING→RUNNABLE + runq_enqueue
  //   Else: no side effect.
  //
  // Clobbers (SysV caller-save):
  //   rax, rdi (own use + transitive via sched_wake).
  // ==========================================================================
  pub let uart_rx_notify_wake_if_waiter : () -> () !{mem} @{sched} =
    fn () -> unsafe {
      effects: { mem },
      capabilities: { sched },
      justification: "R16-M4-006 (#600): ISR-tail wake primitive. Read + nil-check + clear + call sched_wake. Sequence: (1) rax := _uart_rx_notify_waiter (RIP-relative load — landed idiom at core/uart/rx_ring.pdx:49). (2) `cmp rax, 0; je no_waiter` — matches the LSR poll idiom in the sibling uart_rx_isr at rx_isr.pdx:61-62; no new encoder form. (3) rdi := rax (stage sched_wake's SysV arg before clearing the slot — order matters, see §3.4). (4) _uart_rx_notify_waiter := 0 (clear before wake, so a re-entry cannot double-enqueue — R16.M4 UP + IF=0 makes re-entry impossible today, but R17 SMP will preserve this invariant; §3.4). (5) `call sched_wake` — flips target.state STATE_WAITING (2) → STATE_RUNNABLE (1), runq_enqueue. Wake without switch (§5 of #567). Non-leaf: makes one nested SysV call. `sub rsp, 8` alignment prelude around the call — matches vops.pdx / rx_isr.pdx idiom for post-outer-call bodies making nested calls; caller enters at rsp%16==8, sub restores rsp%16==0 so sched_wake sees rsp%16==8 per SysV. Fast path (slot=0): 4 instructions (load, cmp, jz, ret), no stack adjust needed because the ret is direct. Slot=0 path preserves uart_rx_isr's empty-drain invariant (§7.1 of #597): witness at M4-003 observes _uart_rx_head unchanged AND now _uart_rx_notify_waiter still 0 after the ISR returns. Capability {sched} inherited from sched_wake (§3.9). Effect {mem}: RIP-relative load, RIP-relative store, plus sched_wake's own {mem}. No port I/O, no MMIO. Audit: r16-m4-006-uart-rx-notify.",
      block: {
        // Fast path: read the slot; if zero, tail-return.
        mov rax, [rip + _uart_rx_notify_waiter];
        cmp rax, 0;
        je  urxn_no_waiter;

        // Slow path: stage arg, clear slot, align, call sched_wake.
        mov rdi, rax;                              // sched_wake arg 0 = target TCB
        xor rax, rax;
        mov [rip + _uart_rx_notify_waiter], rax;   // clear BEFORE waking (§3.4)

        sub rsp, 8;                                // rsp%16: 8 -> 0
        call sched_wake;                           // state WAITING→RUNNABLE + runq_enqueue
        add rsp, 8;                                // rsp%16: 0 -> 8
        ret;

      urxn_no_waiter:
        ret
      }
    }
}
```

**Instruction count**: `set_waiter` = 2 (mov, ret). `wake_if_waiter`
fast path = 4 (mov, cmp, jz, ret). `wake_if_waiter` slow path = 8
(mov, cmp, jne-skip, mov, xor, mov, sub, call, add, ret) — total
10 including labels. **Total code = ~14 instructions across two
functions.**

### 3.12 Extension to `rx_isr.pdx` — one line

The only change to the existing `rx_isr.pdx` is inserting one
`call uart_rx_notify_wake_if_waiter` immediately before the
existing `call apic_eoi`:

```pdx
    urxi_drain_done:
      // --- NEW at #600: wake the parked RX waiter, if any ---
      call uart_rx_notify_wake_if_waiter;

      // --- EOI: write 0 to LAPIC EOI (MMIO 0xFEE000B0) ---
      call apic_eoi;

      // Restore SysV entry alignment for the caller (trampoline / witness).
      add rsp, 8;
      ret
```

**Signature change on `uart_rx_isr`.** `!{sysreg, mem} @{boot}`
becomes `!{sysreg, mem} @{boot, sched}` — transitive from
`wake_if_waiter → sched_wake`. This widening is:

- **Legitimate**: the ISR now legitimately touches scheduler
  state.
- **Precedented**: `handle_timer` (exceptions.pdx:138) already
  has this shape.
- **Contained**: the sole caller `_uart_rx_trampoline`
  (rx_trampoline.pdx:53) runs at `@{boot}` — but its trampoline
  role is stateless w.r.t. sched, so the trampoline's own
  capability set does NOT need to widen. Capability inheritance
  in this tree is call-site-check-then-inherit: the trampoline
  invocation-site declaration must add `sched` to its cap set.
  Documented in the `rx_isr.pdx` extended justification (§3.14).

**Justification field on `uart_rx_isr`.** Appended (not replaced)
with: *"R16-M4-006 (#600) extension: adds `call
uart_rx_notify_wake_if_waiter` immediately before `call apic_eoi`,
widening capability set from `@{boot}` to `@{boot, sched}` (§3.6
of r16-m4-006 doc). Wake-before-EOI ordering matches
handle_timer (exceptions.pdx:138). Empty-drain invariant (§7.1 of
r16-m4-003 doc) is preserved: at R16-M4-003 witness time
`_uart_rx_notify_waiter` is `.bss` zero and the added call is a
4-instruction no-op fast path."*

### 3.13 Extension to `rx_trampoline.pdx` — capability set

`_uart_rx_trampoline`'s capability declaration must be widened
from `@{boot}` to `@{boot, sched}` to admit the transitive
`sched` cap from `uart_rx_isr → wake_if_waiter → sched_wake`. One
character delta in the effect signature; justification appended
noting the transitive dependency.

### 3.14 Consequential edits — the extension footprint

Two-file extension footprint outside the new module:

| File                                             | Edit                                                                                          |
|--------------------------------------------------|-----------------------------------------------------------------------------------------------|
| `src/kernel/core/uart/rx_isr.pdx`                | Insert `call uart_rx_notify_wake_if_waiter;` before `call apic_eoi;`. Widen `@{boot}` → `@{boot, sched}`. Append §3.12 note to justification. |
| `src/kernel/core/uart/rx_trampoline.pdx`         | Widen `@{boot}` → `@{boot, sched}` on `_uart_rx_trampoline`. Append §3.13 note to justification. |

Both edits are single-token capability additions plus
justification-text appends. Zero behavioral change to control
flow outside the added `call wake_if_waiter`.

## 4. Witness placement

### 4.1 Position in `kernel_main.pdx`

Inserted immediately after the R16-M4-005 witness (`ioapic_irq4_witness_done`
label — will be verified via `grep` once landed; per §5.5 of
#599's doc, the ioapic_irq4 witness's `_done` label anchors the
insertion point). This keeps all six R16.M4 witnesses contiguous,
mirroring the R16.M3 FD witness cluster.

The insertion point sits AFTER:
- `uart_rx_init_witness_done:`             (#595 witness)
- `uart_rx_ring_witness_done:`             (#596 witness)
- `uart_rx_isr_witness_done:`              (#597 witness)
- `idt_vec24_witness_done:`                (#598 witness)
- `ioapic_irq4_witness_done:`              (#599 witness, most recent M4 landing)

And BEFORE the R14b-m5-002 GS_BASE MSR block that starts at
`lea rax, [rip + _cpu_locals];` (per §4.1 of #597 — that block is
unaffected by our insertion).

### 4.2 Storage: reuse `_block_witness_task_x`

The witness reuses `_block_witness_task_x` (declared at
`core/sched/runqueue.pdx:72`, size 448 bytes, aligned to 8) as
the fake waiter TCB. Justification:

- **Right size.** 448 bytes ≥ TCB_SIZE (184) + accommodates the
  `runq_next` (+432) and `runq_prev` (+440) fields the sched_wake
  path reads/writes.
- **Right ownership.** Already declared as a witness-only slab
  by #563 (§8.1 of that doc) — no risk of production code
  reading it.
- **Precedent.** `block_wake_witness` at `kernel_main.pdx:4322`
  already uses this same slab in the same way (init to
  WAITING, drive a primitive, assert post-state, drain).
- **Sequenced clean.** The M4-006 witness runs during boot
  BEFORE the R15-M7-006 block_wake_witness (which sits at
  kernel_main:4322, well after all R16.M4 witnesses). So the
  slab is `.bss`-zero at M4-006 entry, and the M4-006 witness
  MUST leave the slab zeroed at exit so the later block_wake_
  witness (which itself defensively re-zeros — see kernel_main:
  4327-4331) sees a clean slate. The drain step (§5.2 sub-test C)
  runs `runq_dequeue` on the slab and re-zeros state, satisfying
  both the local invariant and the downstream witness's
  precondition.

**Alternative considered: a dedicated `_uart_rx_notify_witness_tcb`
slab.** Rejected because it adds ~448 bytes of `.bss` for a
witness-only fixture when a matching slab already exists. Repo
discipline favors slab reuse when semantics match.

### 4.3 LAPIC / runqueue state at witness time — safety

At witness time (after the M4-005 witness), the LAPIC has NOT
been software-enabled (apic_svr_enable runs at kernel_main:3839
after the R16.M4 cluster — see §4.2 of #597 for the same
argument). This is safe for M4-006's witness because:

- The M4-006 witness does NOT invoke `uart_rx_isr` in sub-test A
  (only sub-test B). Sub-test A calls `wake_if_waiter` directly,
  which never touches the LAPIC.
- Sub-test B DOES call `uart_rx_isr`, which now (post-extension)
  calls `wake_if_waiter` before `apic_eoi`. The `apic_eoi`
  write's safety at witness time is already justified at §4.2 of
  #597 (LAPIC MMIO writes with SVR-disabled are no-ops, not
  faults, on both real hardware and QEMU).

The runqueue is empty at witness time — the R15-M7-006 witness
that populates it does not run until much later. Sub-test C's
`runq_dequeue` drain therefore returns the runq to empty state,
which was its state at witness entry.

## 5. Test canary — kernel_main witness block

### 5.1 Sub-test structure

**Three sub-tests.**

- **Sub-test A: direct `wake_if_waiter` proof.** Zero the fake
  TCB, flip state to WAITING, install it via `set_waiter`, call
  `wake_if_waiter`, verify slot cleared + state RUNNABLE + task
  on runq.
- **Sub-test B: ISR-tail wake propagation.** Reset the fake TCB
  to WAITING + off-runq, re-install via `set_waiter`, call
  `uart_rx_isr` (empty drain — LSR.DR = 0), verify the wake
  side-effect propagated through the ISR tail.
- **Sub-test C: no-waiter fast path.** With `_uart_rx_notify_waiter
  == 0` (post-A + post-B state), call `wake_if_waiter`, verify
  no state change on the fake TCB.

Multi-sub-test structure earns coverage on:

- Sub-test A isolates the wake primitive's own correctness
  (slot cleared, state flipped, runq_enqueue happened).
- Sub-test B proves the extension edit to `uart_rx_isr` composes
  end-to-end with the wake primitive — this is the only sub-test
  that observes the two files acting together.
- Sub-test C proves the fast path is a true no-op — same idiom
  as `_uart_rx_head`-unchanged in the M4-003 witness, but from
  the wake perspective.

### 5.2 Witness assembly (complete block)

```asm
; ============================================================
; R16-M4-006 (#600): uart_rx_notify witness — 3 sub-tests
; ============================================================
uart_rx_notify_witness:
    push r12                                 ; callee-save: fake-TCB address
    push r13                                 ; callee-save: waiter slot address

    lea  r12, [rip + _block_witness_task_x]  ; fake TCB (reuse #563 slab)
    lea  r13, [rip + _uart_rx_notify_waiter] ; waiter slot address

    ; -------- Setup: zero the fake TCB (defensive, .bss = 0 at boot) --------
    xor  rcx, rcx
    mov  [r12 + 8],   ecx                    ; state (u32) = 0 (NEW)
    mov  [r12 + 432], rcx                    ; runq_next = 0
    mov  [r12 + 440], rcx                    ; runq_prev = 0

    ; -------- Sub-test A: direct wake_if_waiter proof --------
    ; Set state=WAITING (2); install waiter; call wake; verify.
    mov  ecx, 2
    mov  [r12 + 8], ecx                      ; state = WAITING

    mov  rdi, r12
    call uart_rx_notify_set_waiter           ; slot := &TCB

    mov  rax, [r13]
    cmp  rax, r12
    jne  urxn_witness_fail                   ; slot must equal our TCB

    call uart_rx_notify_wake_if_waiter       ; slot -> 0; sched_wake(TCB)

    ; Assert: slot cleared to 0
    mov  rax, [r13]
    cmp  rax, 0
    jne  urxn_witness_fail

    ; Assert: TCB.state == RUNNABLE (1)
    mov  ecx, [r12 + 8]
    cmp  ecx, 1
    jne  urxn_witness_fail

    ; Assert: TCB on runq (runq_next != 0)
    mov  rcx, [r12 + 432]
    cmp  rcx, 0
    je   urxn_witness_fail

    ; -------- Drain between A and B: dequeue TCB, re-zero fields --------
    mov  rdi, r12
    call runq_dequeue                        ; runq back to empty
    xor  rcx, rcx
    mov  [r12 + 8],   ecx                    ; state = NEW (defensive)
    mov  [r12 + 432], rcx
    mov  [r12 + 440], rcx

    ; -------- Sub-test B: ISR-tail wake propagation --------
    mov  ecx, 2
    mov  [r12 + 8], ecx                      ; state = WAITING
    mov  rdi, r12
    call uart_rx_notify_set_waiter           ; slot := &TCB

    call uart_rx_isr                         ; empty drain + wake_if_waiter + EOI

    ; Assert: slot cleared to 0 (wake propagated through ISR tail)
    mov  rax, [r13]
    cmp  rax, 0
    jne  urxn_witness_fail

    ; Assert: TCB.state == RUNNABLE (1)
    mov  ecx, [r12 + 8]
    cmp  ecx, 1
    jne  urxn_witness_fail

    ; Assert: TCB on runq
    mov  rcx, [r12 + 432]
    cmp  rcx, 0
    je   urxn_witness_fail

    ; -------- Drain between B and C: dequeue TCB, re-zero fields --------
    mov  rdi, r12
    call runq_dequeue
    xor  rcx, rcx
    mov  [r12 + 8],   ecx
    mov  [r12 + 432], rcx
    mov  [r12 + 440], rcx

    ; -------- Sub-test C: no-waiter fast path --------
    ; Slot is now 0. wake_if_waiter must be a no-op: TCB state
    ; stays 0 (NEW), TCB stays off runq, slot stays 0.
    call uart_rx_notify_wake_if_waiter

    mov  rax, [r13]
    cmp  rax, 0
    jne  urxn_witness_fail

    mov  ecx, [r12 + 8]
    cmp  ecx, 0
    jne  urxn_witness_fail                   ; state must be NEW (untouched)

    mov  rcx, [r12 + 432]
    cmp  rcx, 0
    jne  urxn_witness_fail                   ; runq_next must be 0

    ; -------- All green --------
    lea  rdi, [rip + uart_rx_notify_ok_msg]
    call uart_puts
    jmp  urxn_witness_done

urxn_witness_fail:
    lea  rdi, [rip + uart_rx_notify_fail_msg]
    call uart_puts

urxn_witness_done:
    pop  r13
    pop  r12
```

Total: ~85 lines including labels, blank lines, and end-of-block
drain sequences.

**Label uniqueness.** All labels prefixed `urxn_*` (uart_rx_notify)
to avoid clashes with `urxi_*` (uart_rx_isr) and `urrw_*`
(uart_rx_ring_witness). Same discipline as prior R16.M4 witnesses.

**Callee-save discipline.** r12 (fake TCB address) and r13 (waiter
slot address) are SysV callee-save. Both pushed at entry, popped
at exit. `sched_wake` and `runq_dequeue` do NOT touch callee-save
(per their own #567/#563 justifications), so r12/r13 survive
across the calls without spilling.

**Drain-between-subtests discipline.** Every wake sub-test's
side-effect (TCB on runq, state = RUNNABLE) is undone before the
next sub-test by `runq_dequeue` + re-zeroing. This keeps each
sub-test independently observable and leaves the runq empty for
the downstream block_wake_witness at kernel_main:4322.

### 5.3 Marker

On all three sub-tests green:

```
R16 UART RX NOTIFY OK
```

Emitted via `uart_puts` on `uart_rx_notify_ok_msg`. Fingerprint
added to all three R14B/R15 expected-output files, inserted
immediately after `R16 IOAPIC IRQ4 OK` (the R16.M4-005 marker).

### 5.4 String data — `tools/boot_stub.S`

Append after the last-landed R16.M4-005 witness strings (at
approximately line 742, right after `ioapic_irq4_fail_msg`):

```asm
# R16-M4-006 (#600): uart_rx_notify witness success message
.global uart_rx_notify_ok_msg
.align 8
uart_rx_notify_ok_msg: .ascii "R16 UART RX NOTIFY OK\n\0"

# R16-M4-006 (#600): uart_rx_notify witness failure message
.global uart_rx_notify_fail_msg
.align 8
uart_rx_notify_fail_msg: .ascii "R16 UART RX NOTIFY FAIL\n\0"
```

No other rodata changes. Single-line failure message matches
prior R16.M4 discipline — the three sub-tests all funnel through
one `_fail` label; per-sub-test failure differentiation is not
warranted at the marker level. (Bisect via commenting out
sub-tests locally, same as R16.M4-003 recommendation.)

**Coverage-gap note (from §3.5).** The witness does NOT exercise
the precondition-violation paths of `set_waiter` (null tcb, tcb
not in WAITING, tcb still on runq, slot already occupied). This
matches the R15-M7-006 witness discipline (sched_wake's own
witness at kernel_main:4322 does not violation-test either).
Filed as follow-up §6.8.

### 5.5 Fingerprint files — marker insertion

Insert `R16 UART RX NOTIFY OK` in three files:

| File                                        | Insert after            | Insert before                      |
|---------------------------------------------|-------------------------|-------------------------------------|
| `tests/r14b/expected-boot-r14b-loader.txt`  | `R16 IOAPIC IRQ4 OK`    | `LOADER OK`                         |
| `tests/r15/expected-boot-r15-ring3.txt`     | `R16 IOAPIC IRQ4 OK`    | `R15 IDLE TASK OK`                  |
| `tests/r15/expected-boot-r15-process.txt`   | `R16 IOAPIC IRQ4 OK`    | `R15 IDLE TASK OK`                  |

Contains-in-order matching makes the addition strictly additive
— no earlier line reorders. All 5-mode smoke stages that do not
observe R16 markers (`boot_r8_only`, `boot_r10`, `boot_r11`,
`boot_r12`, `boot_r12_denial`) stay byte-identically green.

## 6. Alternatives considered / follow-ups

### 6.1 Ship a `uart_rx_read` skeleton

**Rejected — see §1.2.** paideia-os discipline forbids shipping
stubs. A read primitive without TTY + syscall dispatch has no
legal caller. The reachable primitive shipped by this issue is
`set_waiter`, which IS what the future read primitive will call.

### 6.2 Combine with #601 (RX smoke) in one PR

**Rejected.** #601 needs stdin injection through QEMU
(`-serial pty`), a TTY vnode, and an actual `read()` syscall
that eventually parks a task in `sched_block`. This issue's
producer-side wake path is independently verifiable via the
manual witness at §5. Splitting keeps each issue's regression
surface minimal.

### 6.3 Combine with #598/#599 (IDT + IOAPIC wire) in one PR

**Not applicable — those already landed at #598/#599.** This
issue extends the ISR body they hooked up, which is why the
prereq chain is `#597 landed` (ISR body exists) and the
in-tree wiring at #598/#599 remains untouched.

### 6.4 Add `_uart_rx_dropped_count : u64` overrun counter here

**Deferred (again) — filed as R16.M4 tail issue.** #597 §6.4
re-deferred this to #600, and on further reflection it stays
deferred for the same reasons: (a) the AC does not require it,
(b) counter-without-reader is dead observability, (c) mixing
overrun accounting with notification plumbing in one issue
inflates the bisect surface. Filed as an R16.M4 tail issue.

### 6.5 Wire a KIND_NOTIFICATION cap-table entry for RX

**Deferred to post-TTY / post-userland-RX consumer.** §3.7
argued why a KIND_NOTIFICATION handle at R16.M4 is a fake
abstraction. Once a userland process exists that wants to
`epoll`-style poll `/dev/ttyS0` (post-Subsystem 17 shell), the
migration is:

- Allocate a fixed notification ID (e.g. `NOTIF_ID_RX_TTYS0 : u64 = 0`).
- In `wake_if_waiter`, ALSO invoke the cap handler with
  `(rights = INVOKE, target_ptr = NOTIF_ID_RX_TTYS0, op_arg = OP_SIGNAL)`.
- Expose the cap handle to userland via `openat("/dev/ttyS0",
  O_NOTIFY)` or an equivalent primitive.

The direct-wake path stays in place — the two mechanisms
compose (userland pollers get semaphore semantics; kernel-side
blocked readers get direct wake). No breaking change to this
issue's contract.

### 6.6 Multiple concurrent readers on `/dev/ttyS0` (R17+ SMP)

**Migration path.** Replace the single `u64` slot with a
`waitq_head : u64` intrusive-list head, and `set_waiter` with a
`waitq_add(tcb)` that appends. `wake_if_waiter` becomes
`wake_one` (pop head + sched_wake) or `wake_all` (loop). This is
a localized change — the `uart_rx_isr` extension remains a
one-line `call wake_one` — but the concurrency contract
sharpens: waitq operations need atomic-exchange or lock discipline
under SMP. Documented as a Subsystem-14 R17-hardening follow-up.

### 6.7 Atomic exchange on the slot for R17-SMP correctness

**Under R17 SMP**, the read-then-clear pattern in `wake_if_waiter`
needs to become `xchg [rip + _uart_rx_notify_waiter], rax` (or
the equivalent lock-prefixed sequence) to defend against a second
CPU installing a waiter between the read and the clear. paideia-as
does not yet emit `xchg` with memory operand; encoder gap filed
under R17 SMP hardening. R16.M4 UP + IF=0 makes the pattern
strictly correct today.

### 6.8 Precondition-violation tests for `set_waiter`

**Deferred to a violation-test harness.** No such harness exists
in the tree today (the R15-M7-006 sched_wake witness does not
violation-test either). Filed as a general Subsystem-14 hardening
follow-up that would install a `poisoned-fixture` framework in
`kernel_main` for precondition-catching primitives.

### 6.9 Emit `R16 UART RX NOTIFY OK` from within `wake_if_waiter`

**Rejected.** Same discipline as every prior R16 primitive: the
primitive is silent, the witness emits. Printing from
`wake_if_waiter` would fire once per real IRQ 4 with a waiter
installed — trashing console UX under any real keyboard input
rate.

### 6.10 Naming: `set_waiter` vs `register_waiter` vs `install_waiter`

**Chose `set_waiter` for symmetry with the slot semantics** —
the primitive literally sets the slot. `register_` implies a
list-of-callbacks; `install_` implies a hook that survives
across events. Neither matches the once-per-wake semantics.

## 7. Invariants

### 7.1 Fast-path preserves M4-003's empty-drain invariant

- **Precondition** (at M4-003 witness time): `_uart_rx_notify_waiter
  == 0` (`.bss` zero, no `set_waiter` yet called).
- **Extended ISR path**: drain loop exits with LSR.DR=0; then
  `call wake_if_waiter` executes `mov rax, [rip + _slot]; cmp
  rax, 0; je urxn_no_waiter; ret`. Four instructions, no side
  effect.
- **Postcondition**: `_uart_rx_head` unchanged (still asserted
  by M4-003 witness); `_uart_rx_notify_waiter` unchanged (still
  0); LAPIC EOI written exactly once.
- **Consequence**: M4-003 witness stays green across the M4-006
  edit to `rx_isr.pdx`.

### 7.2 Wake side-effect: exactly one sched_wake per install

- **Base case**: `set_waiter(tcb)` writes tcb into slot.
- **Wake case**: `wake_if_waiter` reads tcb into rdi, clears
  slot, calls `sched_wake(tcb)`.
- **Second wake case**: subsequent `wake_if_waiter` reads 0,
  short-circuits, returns without side effect.
- **Consequence**: at most one `sched_wake` per `set_waiter` call.
  No double-enqueue possible.

### 7.3 Slot clear-before-wake is atomic w.r.t. re-entry

- **R16.M4 UP + IF=0 inside ISR**: no second ISR can preempt
  `wake_if_waiter`. Atomicity is implicit.
- **R17 SMP** (deferred, see §6.7): needs `xchg` or lock prefix
  to make the read-then-clear a single atomic step. Documented.

### 7.4 Sched-wake precondition is met at every call

- **Precondition** (sched_wake §6.2 of #567): target != 0, target
  in STATE_WAITING, target off runqueue.
- **How the slot enforces it**:
  - `!= 0`: `cmp rax, 0; je urxn_no_waiter` guarantees we only
    call `sched_wake` on a non-zero read.
  - `STATE_WAITING`: enforced by the caller of `set_waiter`
    (§3.5). Witness sub-tests A and B set `state = WAITING (2)`
    before installing.
  - `off runqueue`: enforced by the caller of `set_waiter` (the
    canonical caller flow does `runq_dequeue(tcb)` first).
    Witness sub-tests A and B leave `runq_next` and `runq_prev`
    zero on install.
- **Consequence**: `sched_wake` at line "call sched_wake" always
  runs on a legally-shaped target.

### 7.5 Stack pointer discipline

`set_waiter`: leaf. No `sub rsp, 8` needed. `ret` returns caller
to `rsp%16 == 0`.

`wake_if_waiter`: non-leaf on the slow path only.
- **Fast path** (slot=0): 4 instructions, direct `ret`. Caller
  sees `rsp%16 == 0` after `ret`.
- **Slow path**: `sub rsp, 8` before `call sched_wake` (rsp%16:
  8→0; callee entry sees rsp%16==8 per SysV). `add rsp, 8` after
  the call (rsp%16: 0→8). `ret` pops the return address (caller
  sees `rsp%16 == 0`).

No stack corruption possible on either path.

## 8. Cross-cutting risks

- **A future issue installs a waiter but forgets to flip state
  to WAITING.** Sched_wake would still flip state to RUNNABLE (a
  legal state transition from anything), but the task would
  never have been off the runqueue in the first place, so
  `runq_enqueue` inside sched_wake would double-enqueue and
  corrupt the intrusive list. Mitigation: caller enforcement
  (§3.5). This is a class of bug that would appear as a runq
  cycle detected by the runq_dequeue drain in the M4-006
  witness's own sub-test cleanup, or as a boot hang in the
  block_wake_witness downstream. Both are visible on smoke.
- **A future issue calls `set_waiter` when the slot is already
  occupied.** The current implementation silently overwrites,
  losing the previous waiter forever (it stays parked). At
  R16.M4 the single-waiter invariant §3.3 makes this a design-
  defect scenario. §3.10 discussed a compare-and-set variant;
  deferred. Mitigation: caller enforcement; R17 waitq-list
  migration eliminates the class entirely.
- **The extension edit to `rx_isr.pdx` widens its capability
  set.** The trampoline's capability declaration must widen in
  lockstep (§3.13). Missing this widening would surface as a
  capability-audit failure in the paideia-as verifier, not a
  runtime bug — safe by construction.
- **`_block_witness_task_x` slab reuse across two witnesses in
  kernel_main.** Documented in §4.2. The M4-006 witness runs
  first (part of the R16.M4 cluster), so the slab is `.bss`-zero
  at entry; the M4-006 witness zeroes it at exit. The
  R15-M7-006 block_wake_witness at kernel_main:4322 defensively
  re-zeros anyway. Safe.
- **Someone types on QEMU stdin between smoke start and the
  M4-006 witness.** Same risk documented at §8 of #597 — the
  smoke harness runs headless with stdin redirected to
  `/dev/null`. If the drain loop consumed real bytes at sub-test
  B, `_uart_rx_head` would advance (not asserted by M4-006, only
  by M4-003) but the wake would still fire, so M4-006's sub-test
  B remains valid. No failure mode here.

## 9. LOC estimate

| File                                                        | LOC        |
|-------------------------------------------------------------|------------|
| `src/kernel/core/uart/rx_notify.pdx` (new)                  | ~55        |
|   - module boilerplate + justification for set_waiter       |   ~18      |
|   - `set_waiter` body (2 instructions)                      |    ~4      |
|   - justification for wake_if_waiter                        |   ~15      |
|   - `wake_if_waiter` body (10 instructions with labels)     |   ~15      |
|   - blank / comments / boilerplate                          |    ~3      |
| `src/kernel/core/uart/rx_isr.pdx` (extension)               | ~6         |
|   - insert one `call wake_if_waiter` line                   |    ~1      |
|   - widen `@{boot}` → `@{boot, sched}`                      |    ~0      |
|   - append §3.12 justification note                         |    ~5      |
| `src/kernel/core/uart/rx_trampoline.pdx` (extension)        | ~3         |
|   - widen `@{boot}` → `@{boot, sched}`                      |    ~0      |
|   - append §3.13 justification note                         |    ~3      |
| `src/kernel/boot/kernel_main.pdx` (witness block)           | ~85        |
|   - 3 sub-tests + drain-between blocks + labels             |   ~75      |
|   - preceding/trailing comment banner                       |    ~5      |
|   - blank / structural spacing                              |    ~5      |
| `tools/boot_stub.S` (2 messages)                            | ~8         |
| 3 expected-output fingerprint files (1 marker each)         | ~3         |
| `design/kernel/r16-m4-006-uart-rx-notify.md` (this doc)     | (this)     |
| **Total executable / testing / test-data**                  | **~160**   |

Executable code path: ~64 LOC (new module + two-file extension).
Witness + fingerprint: ~96 LOC. Larger than R16.M4-003 (~91 LOC)
because the witness has 3 sub-tests with drain-between-subtests
sequences, not 1.

## 10. Tractability

**HIGH — comparable to R16.M4-003, marginally more surface than
R16.M4-001.**

- **Zero paideia-as encoder gap.** Every mnemonic used is
  landed:
  - `mov [rip + _sym], reg` — landed at `rx_ring.pdx:70`.
  - `mov reg, [rip + _sym]` — landed at `rx_ring.pdx:49`.
  - `cmp rax, 0; je label` — landed at `rx_isr.pdx:61-62`.
  - `sub rsp, 8` / `add rsp, 8` — landed at `rx_isr.pdx:54,78`.
  - `call sym` / `ret` — ubiquitous.
  - `xor rax, rax` — ubiquitous.
- **Non-leaf, but uses the recent-frozen alignment discipline.**
  `sub rsp, 8` / `add rsp, 8` bracket around the sole nested
  `call sched_wake`.
- **Reuses `sched_wake`** rather than re-encoding a state-flip +
  runq_enqueue sequence.
- **Reuses `_block_witness_task_x`** as the witness slab — no
  new `.bss` for witness fixtures.
- **Witness is three sub-tests** — larger than M4-003's single
  sub-test, but the same shape as `block_wake_witness` at
  kernel_main:4322 which has three sub-tests plus a drain.
  Copy-adapt distance is small.
- **Marker line is contains-in-order** — strictly additive to
  fingerprints; no reordering risk.
- **No cross-repo escalation risk.** All encoder forms landed.
- **Two-file extension footprint** on `rx_isr.pdx` and
  `rx_trampoline.pdx` is single-line + single-token + text
  append. Very small blast radius.
- **Capability widening** on `uart_rx_isr` and `_uart_rx_trampoline`
  is a legitimate scope expansion (ISR now touches scheduler)
  and matches `handle_timer`'s precedent.

Estimated implementation time: **~50 minutes of a workerbee
session** — a little longer than R16.M4-003 because there are
three sub-tests with drain sequences, plus the two-file
extension edits, but no new mnemonics to introduce and no new
encoder audit needed.

Estimated risk of regressing an existing smoke mode:
**near-zero** — the fast path in `wake_if_waiter` (slot=0) is a
4-instruction no-op that runs at the tail of every `uart_rx_isr`
invocation, and at M4-003 witness time the slot is `.bss` zero,
preserving that witness's assertions.

**Known follow-ups (do NOT block #600's landing)**:

- **#601 (RX smoke)** — end-to-end AC via QEMU stdin injection.
  Only observable at #601 landing.
- **`_uart_rx_dropped_count` overrun counter** (§6.4) — filed as
  an R16.M4 tail issue.
- **KIND_NOTIFICATION cap-table entry for RX** (§6.5) — filed
  post-Subsystem-17 (userland shell).
- **Multi-reader waitq migration** (§6.6) — R17 SMP + shell.
- **`xchg`-based atomic slot clear** (§6.7) — R17 SMP encoder
  work.
- **Precondition-violation test harness** (§6.8) — general
  Subsystem-14 hardening.

## 11. References

- Issue: paideia-os#600
- Milestone: paideia-os R16.M4 (UART input driver — 16550 RX
  interrupt-driven)
- Prereq issues: #567 (sched_block/sched_wake), #597
  (uart_rx_isr), #596 (rx_ring), #563 (runqueue + witness slab)
- Blocks: #601
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 14, item 6
- Master plan: `design/milestones/r14b-master-plan.md` §M20
  (UART input)
- Prior-art ISR-tail wake pattern:
  `src/kernel/core/int/exceptions.pdx:138` (`handle_timer` calls
  `sched_tick_r15` before `apic_eoi`)
- Prior-art wake witness pattern:
  `src/kernel/boot/kernel_main.pdx:4322` (`block_wake_witness`)
- Prior-art slot-in-.bss + get/set primitives:
  `src/kernel/core/uart/rx_ring.pdx:25-27` (head/tail counters)
- Prior-art capability widening on scheduler-touching ISR:
  `src/kernel/core/int/exceptions.pdx:138` (handle_timer at
  `@{boot, sched}`)
- Existing primitive: `sched_wake` at
  `src/kernel/core/sched/wake_block.pdx:68` (R15-M7-006 #567)
- Existing primitive: `runq_dequeue` at
  `src/kernel/core/sched/enqueue.pdx` (R15-M7-002 #563)
- Existing storage reuse: `_block_witness_task_x` at
  `src/kernel/core/sched/runqueue.pdx:72`
- KIND_NOTIFICATION reference: `kind_notification.pdx` +
  design/audit/entries/r13-m6-006-kind-interrupt-notification.md
- TCB layout: `src/kernel/core/sched/tcb.pdx:22-60`
- Alignment idiom precedent: `src/kernel/core/fs/vops.pdx:78..242`
  (R16-M1-003 #572)
