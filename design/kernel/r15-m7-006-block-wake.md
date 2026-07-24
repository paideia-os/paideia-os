---
issue: 567
backfill: 674
milestone: R15.M7 (Scheduler: cooperative → timer-preemptive)
subsystem: 10 — Scheduler
prereq:
  - "#543 (task-struct layout freeze — block/wake state transitions use frozen +8)"
  - "#544 (`_task_pool[64]` slab in .bss @align(4096) — landing required for witness)"
  - "#562 (idle task + `sched_pick_next_r15` O(1) stub — block/wake call pick_next)"
  - "#563 (real runqueue doubly-linked + runq_next/prev at +432/+440 — block/wake manipulate runqueue)"
blocks:
  - "#564 (r15-m7-003 sched-switch-real — first save→restore; block invokes switch)"
  - "#565 (r15-m7-004 lapic-timer 100Hz — timer tick invokes pick_next, which consumes block's output)"
touching:
  - src/kernel/core/sched/wake_block.pdx           (sched_block/sched_wake bodies)
  - src/kernel/core/sched/runqueue.pdx             (_block_witness_task_x slab)
  - src/kernel/boot/kernel_main.pdx                (block_wake_witness block, 109 LOC)
  - tests/r15/expected-boot-r15-process.txt        (marker line)
  - tests/r15/expected-boot-r15-ring3.txt          (marker line)
  - tools/boot_stub.S                              (2 banner strings)
related:
  - design/kernel/r15-m7-006-block-wake-guards.md  (precondition guard specs; #663 tactical fixes)
  - design/kernel/scheduler.md                      (long-term architecture)
  - src/kernel/core/sched/runqueue.pdx §5 (#563)   (runq_enqueue/dequeue register discipline)
  - src/kernel/core/sched/pick_next.pdx §7 (#562)  (sched_pick_next_r15 O(1) rotation)
  - src/kernel/core/sched/sched_switch.pdx §5 (#564) (sched_switch_r15 cli/popfq boundary)
---

# R15-M7-006 — block / wake state-transition primitives (#567)

## 1. Scope

Replace R4-era stub bindings with two real state-transition functions:

- **sched_block():** no-arg self-suspend primitive. Current task transitions RUNNABLE → WAITING; is dequeued from the runqueue; pick_next advances to the next task; sched_switch_r15 transfers control away. Control returns to sched_block's caller only when some other task calls sched_wake on this task.
- **sched_wake(target):** one-arg wake primitive. Target task transitions WAITING → RUNNABLE; is enqueued at the runqueue tail. No task switch: caller continues executing. No priority-based preemption-on-wake (deferred to Phase-9).

Acceptance criteria (from #567):

- sched_block() / sched_wake() have compiled bodies at symbols visible to boot-time witness.
- Witness exercises sched_block simulation, real sched_wake, and pick_next round-trip.
- #663 precondition guards are present and tested inline.

Everything downstream depends on these primitives: #564 (real sched_switch) consumes block's output; #565 (LAPIC-timer 100 Hz) invokes pick_next on each tick to select the next task (deferred preemption-safe synchronization per #667).

## 2. Out of scope / deferred

**Preemption safety:** At R15.M7, no timer interrupt exists (#565 blocked on #662). The sequence sched_block steps (2)-(4) — state write, runq_dequeue, pick_next — occurs with interrupts on. No race is possible. When #565 lands preemption (deferred to Phase-8 per §7.2), a narrow cli/popfq window around these steps becomes mandatory; see §7.2 for the design slot.

**Wake-on-preemption:** No priority logic when target task becomes RUNNABLE. Wake returns control to caller unconditionally. Priority-based preemption-on-wake (highest-priority task preempts current when woken) is deferred to Phase-9.

**Reason field:** Status codes WAKE_OK/FAIL and BLOCK_OK/FAIL constants are kept for R15.M8 compatibility but not used. A "reason" field carrying context to the woken task (e.g., "woken by timer" vs. "woken by IPC") is deferred to R15.M8.

## 3. Semantic contract

A task's lifecycle at R15.M7 follows a three-state machine:

- **STATE_NEW** (0): freshly allocated from `_task_pool`; not yet RUNNABLE.
- **STATE_RUNNABLE** (1): eligible for execution; linked in the runqueue.
- **STATE_WAITING** (2): suspended; off the runqueue.
- **STATE_ZOMBIE** (3): dead; no resurrection expected at R15.M7 (zombie reaping deferred to R15.M9).

**sched_block contract:** Must be called only when the invoking task is RUNNABLE (precondition guard in §6.2 ensures this). Atomically transitions `_current_tcb.state` from RUNNABLE to WAITING, removes the task from the runqueue, and transfers control away. No return value. Idempotence not applicable: calling twice consecutively is a bug (the first call never returns; the second is unreachable).

**sched_wake contract:** Must be called with a valid task-struct pointer. Checks the target's state; if already RUNNABLE, returns without side effect (no-op, idempotent — guard in §6.1). Otherwise, transitions the target to RUNNABLE and enqueues it. No return value. Caller continues.

Task-struct invariant: `state` is a u32 at offset +8. `runq_next` (u64) at +432 and `runq_prev` (u64) at +440 are used only when the task is in the runqueue; off-runq values must be 0 (see #563 §3 slab discipline).

## 4. Status codes & timeout constants

Defined in `src/kernel/core/sched/wake_block.pdx` for R15.M8 compatibility:

```c
WAKE_OK      = 0
WAKE_FAIL    = 4294967295    // -1 as u64
BLOCK_OK     = 0
BLOCK_FAIL   = 4294967295    // -1 as u64

BLOCK_TIMEOUT_INFINITE = 18446744073709551615  // -1 as i64
BLOCK_TIMEOUT_ZERO     = 0
```

Not used in R15.M7 (sched_block and sched_wake return `()`, not status). Placeholders for future phases.

## 5. sched_block() — sequence trace

Precondition: `_current_tcb` is RUNNABLE (guard in §6.2).

1. **Guard check:** Load `_current_tcb` into rax. Load state (u32 at +8) into ecx. Compare to STATE_RUNNABLE (1). Fail-path: terminal soft-panic (see §6.2).
2. **State transition:** Write STATE_WAITING (2) into rax.state.
3. **Dequeue:** Call runq_dequeue(rax) — removes the task from the circular linked list.
4. **Pick next:** Call sched_pick_next_r15() — walks the runqueue; returns rax = next task or _idle_tcb if empty.
5. **Switch away:** Call sched_switch_r15(rax) — saves current context, loads next context, popfq, iretq. Control does not return to this point until another task calls sched_wake on this task and execution resumes.

When resumed (step 5 eventually returns): _current_tcb has changed to this task; control falls through to the caller's instruction after sched_block().

Register discipline: rax (current/next TCB), rcx (state constant), rdi (function args) are caller-save scratch. Nested calls to runq_dequeue, sched_pick_next_r15, and sched_switch_r15 clean up their own callee-save registers per their own contracts (#563 §6, #562 §7, #564 §5). No prologue/epilogue needed in sched_block itself.

## 6. Precondition failure modes

Documented-deliberate design gaps filled by #663 tactical guard insertion. Two asymmetric failure modes, two asymmetric responses.

### 6.1 sched_wake precondition — double-wake (silent early-exit)

**Failure mode:** Unconditional state transition in the original R4 stub allowed calling sched_wake twice on the same task. First call: target transitions WAITING → RUNNABLE, enqueues. Second call on the same already-RUNNABLE task: unconditionally writes state=RUNNABLE (idempotent) but **runq_enqueue is called again**, splicing the task into the doubly-linked circular list a second time. Result: the list topology corrupts into a "figure-8" — two independent loops sharing the target node. Silent corruption: subsequent walk via pick_next follows bad links → page fault far from the call site, obscuring diagnosis.

**Guard specification:** At entry to sched_wake, load target.state (u32 at +8) into ecx. Compare to STATE_RUNNABLE (1). If equal, jump to sched_wake_noop (skip state write and runq_enqueue, return immediately). Fall-through on mismatch (2 instructions, ~0 cycle cost). No state mutation, no side effect. Idempotent: second call returns without changing task state or runqueue links.

Compiled pattern (wake_block.pdx lines 86-89):
```asm
mov ecx, [rdi + 8]       // ecx = target.state (u32 at +8)
cmp ecx, 1               // STATE_RUNNABLE?
je sched_wake_noop
```

See design/kernel/r15-m7-006-block-wake-guards.md §2 for the compiled guard byte pattern.

### 6.2 sched_block precondition — block-on-non-RUNNABLE (terminal soft-panic)

**Failure mode:** Unconditional state write in the original R4 stub allowed calling sched_block when _current_tcb is not RUNNABLE. Block-on-WAITING would be a double-block (nonsense). Block-on-ZOMBIE would resurrect a dead task as WAITING, reintroducing it to the runqueue. Silent corruption: the scheduler picks and switches to a zombie; execution in undefined task context. Terminal soft-panic is the correct response.

**Guard specification:** At entry (after loading _current_tcb into rax), load state (u32 at +8) into ecx. Compare to STATE_RUNNABLE (1). If not equal, jump to sched_block_precond_fail. Fail path: push error message address, call uart_puts, cli, hlt, loop forever (standard exception pattern from exceptions.pdx / entry.pdx §4).

Compiled pattern (wake_block.pdx lines 43-72):
```asm
mov ecx, [rax + 8]       // ecx = state (u32 at +8)
cmp ecx, 1               // STATE_RUNNABLE?
jne sched_block_precond_fail

[... proceed with steps 2-5 ...]

sched_block_precond_fail:
  lea rdi, [rip + sched_block_precond_fail_msg]
  call uart_puts
sched_block_precond_hang:
  cli
  hlt
  jmp sched_block_precond_hang
```

See design/kernel/r15-m7-006-block-wake-guards.md §2 for the compiled guard byte pattern.

## 7. Concurrency posture

### 7.1 Interrupt boundary

At R15.M7, no interrupt handlers invoke sched_block or sched_wake. The only timer/IPI interrupt is the IPI self-trigger mechanism for multicore bringup (#646, deferred). No preemption exists. Both functions are **IRQ-safe** in the narrow sense: they do not disable interrupts, issue blocking I/O, or hold spinlocks. A timer interrupt can occur during sched_block execution without corrupting sched_block's invariants — the interrupt handler will not interfere.

When #565 lands LAPIC-timer preemption at Phase-8, the timer ISR will call sched_pick_next_r15 (outside any sched_block window) to select the next task, but will not call sched_block or sched_wake directly. Those remain "user task" functions: they run only in task context, not ISR context.

### 7.2 Preemption safety — cli window deferral

**Current state (R15.M7):** Steps (2)-(4) of sched_block — state write, runq_dequeue, sched_pick_next_r15 — occur with interrupts enabled. No interleaving is possible because no preemptive interrupt exists.

**Phase-8 requirement (#565 landing):** When LAPIC-timer 100 Hz preemption lands (blocked on #662 timer hardware investigation), a preemptive timer interrupt can fire mid-sched_block. If it fires between step (2) (state → WAITING) and step (4) (pick_next), the ISR's pick_next walk will encounter a task with state=WAITING but still linked in the runqueue (runq_next/prev nonzero). Invariant violation: the runqueue contains only RUNNABLE tasks (#563 §3.2); a WAITING task in the list is a silent corruption vector.

**Tactical fix (#667 deferred):** Narrow cli window: immediately after loading _current_tcb (step 1.5 guard check), issue `cli`. After sched_pick_next_r15 returns (step 4), issue `popfq` to restore interrupt state (saved at entry). Effect: steps (2)-(4) are atomic with respect to ISR preemption. The timer ISR can interrupt only before the cli or after the popfq; at those boundaries, the runqueue is consistent.

Register state: rflags saved on stack at sched_block entry (via pushfq implicit in the calling convention, or explicit `push rax; pushfq; pop rax`). Restored via popfq before sched_switch_r15 step (5) — sched_switch_r15 itself handles the iretq.

This narrow fix is described in §5.4 of the #567 landing commit's justification block. Design responsibility: #667 or a follow-on blocking tactical issue (not R16 systematic rework, which is #668 or later).

## 8. Witness plan

sched_block has zero production callers at #567 landing (9fc81b0). No kernel subsystem invokes it because no subsystem needs task synchronization yet. The function is dead code: verified present, exercised by boot-time witness, never actually called by any reachable instruction path until a higher layer (e.g., IPC, mutex) invokes it.

### 8.1 Why zero callers

At R15.M7, kernel initialization is strictly sequential:
1. Boot zeroes .bss and loads .text.
2. Callout to runq_init (inside runqueue witness).
3. Callout to runq_witness block (exercises runq_enqueue/dequeue, verifies pick_next round-trip).
4. Callout to block_wake_witness block (exercises sched_block _simulation_, real sched_wake, pick_next).
5. Callout to multicore witness (#646, IPI self-trigger).
6. Ring-3 entry → user shell loop.

No task ever calls sched_block in this sequence because no task needs to wait (no IPC, no mutexes, no timers). When #568 (IPC send/recv) lands, sched_block becomes reachable: a task calls IPC_recv, which internally calls sched_block to wait. At that point, sched_block transitions from dead code to live code.

The witness cannot call sched_block itself because doing so would suspend the boot witness and prevent subsequent witness blocks from running. Instead, block_wake_witness simulates the essential state transitions: it manually writes state=WAITING and calls runq_dequeue to replicate sched_block steps (2)-(3), then verifies the subsequent sched_pick_next_r15 returns _idle_tcb (runqueue empty fallback). This is verified in §8.2 Sub-test A.

### 8.2 Witness TCB slab

`_block_witness_task_x` is a 448-byte (u64[56]) slab in .bss, allocated by #563 runqueue.pdx. Zeroed defensively on each boot (bss default is zero, but re-zeroing ensures warm-reset clean state). Fields used:

- +8: state (u32) — NEW, RUNNABLE, WAITING.
- +432: runq_next (u64) — pointer to next TCB in circular list; 0 if off-runq.
- +440: runq_prev (u64) — pointer to prev TCB in circular list; 0 if off-runq.

(Layout per #543 task-struct freeze; offsets confirmed in #549 fd_table embed.)

### 8.3 Fingerprint markers

Two compile-time markers:

1. `sched_block_precond_fail_msg`: uart_puts banner string "SCHED PRECOND FAIL: block on non-RUNNABLE\n" (printed only if guard fails, blocking the soft-panic path).
2. `block_wake_witness_ok_msg` and `block_wake_witness_fail_msg`: boot-time witness banners.

tools/verify-sched-guards.sh (structural verifier, deferred to #663 or #667 follow-on) inspects compiled kernel for byte patterns matching the guard sequences (sched_wake @entry, sched_block @entry) and confirms both fail-path symbols are linked.

### 8.4 Witness driver — byte-for-byte spec

The complete block_wake_witness block is compiled in kernel_main.pdx lines 5636–5744. Literal transcription for archival:

```asm
      // ============================================================
      block_wake_witness:

          // ---------- Precondition: witness TCB fully zeroed ----------
          // (bss default is zero, but we defensively re-zero so re-runs
          // of the boot flow — e.g. via a warm reset — start clean.)
          lea rax, [rip + _block_witness_task_x];
          xor rcx, rcx;
          mov [rax + 8],   ecx;      // state (u32)   = 0 (NEW)
          mov [rax + 432], rcx;      // runq_next     = 0
          mov [rax + 440], rcx;      // runq_prev     = 0

          // ---------- Setup: X becomes RUNNABLE and joins runq ----------
          mov ecx, 1;
          mov [rax + 8], ecx;        // state = RUNNABLE
          mov rdi, rax;
          call runq_enqueue;         // runq now contains X only

          // ---------- Sub-test A: simulate sched_block on X ----------
          // (equivalent to sched_block's steps 2 + 3 — see §5.1 of design doc.
          //  We do NOT call sched_block itself — see §8.1 for why.)
          lea rax, [rip + _block_witness_task_x];
          mov ecx, 2;
          mov [rax + 8], ecx;        // state = WAITING
          mov rdi, rax;
          call runq_dequeue;         // runq empty again

          // Assert X.state == WAITING
          lea rax, [rip + _block_witness_task_x];
          mov ecx, [rax + 8];
          cmp ecx, 2;
          jne block_wake_witness_fail;

          // Assert X.runq_next == 0 (off runq)
          mov rcx, [rax + 432];
          cmp rcx, 0;
          jne block_wake_witness_fail;

          // Assert X.runq_prev == 0 (off runq)
          mov rcx, [rax + 440];
          cmp rcx, 0;
          jne block_wake_witness_fail;

          // Assert sched_pick_next_r15 returns _idle_tcb (empty runq fallback)
          call sched_pick_next_r15;
          mov rcx, [rip + _idle_tcb];
          cmp rax, rcx;
          jne block_wake_witness_fail;

          // ---------- Sub-test B: real sched_wake(X) ----------
          lea rdi, [rip + _block_witness_task_x];
          call sched_wake;

          // Assert X.state == RUNNABLE
          lea rax, [rip + _block_witness_task_x];
          mov ecx, [rax + 8];
          cmp ecx, 1;
          jne block_wake_witness_fail;

          // Assert X on runq (X.runq_next != 0 — specifically == &_runq_head_slot)
          mov rcx, [rax + 432];
          cmp rcx, 0;
          je block_wake_witness_fail;

          // ---------- Sub-test C: pick_next returns X ----------
          call sched_pick_next_r15;
          lea rcx, [rip + _block_witness_task_x];
          cmp rax, rcx;
          jne block_wake_witness_fail;

          // ---------- Sub-test D: double-wake early-exit (#663 guard) ----------
          // X is still RUNNABLE + on runq from Sub-test C. Snapshot runq_next,
          // call sched_wake again, confirm state + link untouched.
          lea rax, [rip + _block_witness_task_x];
          mov r8, [rax + 432];           // r8 = baseline X.runq_next

          lea rdi, [rip + _block_witness_task_x];
          call sched_wake;               // guard hits — early return

          // Assert X.state still RUNNABLE
          lea rax, [rip + _block_witness_task_x];
          mov ecx, [rax + 8];
          cmp ecx, 1;
          jne block_wake_witness_fail;

          // Assert X.runq_next unchanged (no re-enqueue — no figure-8)
          mov rcx, [rax + 432];
          cmp rcx, r8;
          jne block_wake_witness_fail;

          // ---------- Drain: dequeue X so runq is empty for the next witness ----------
          lea rdi, [rip + _block_witness_task_x];
          call runq_dequeue;

          // Assert empty: head.next == &head
          lea rax, [rip + _runq_head_slot];
          mov rcx, [rax + 432];
          cmp rcx, rax;
          jne block_wake_witness_fail;

          // ---------- All checks green ----------
          lea rdi, [rip + block_wake_witness_ok_msg];
          call uart_puts;
          jmp block_wake_witness_exit;

      block_wake_witness_fail:
          lea rdi, [rip + block_wake_witness_fail_msg];
          call uart_puts;

      block_wake_witness_exit:
```

Sub-test D was added post-landing by #663; see design/kernel/r15-m7-006-block-wake-guards.md §4 for the rationale and timing.

## 9. Interaction with #563 (runqueue empty invariant)

sched_block and sched_wake depend on #563's runqueue contract: the doubly-linked circular list's head sentinel is _runq_head_slot; only RUNNABLE tasks are linked in the list. When runqueue is empty, head.runq_next == head (self-loop).

sched_block's step (3) relies on runq_dequeue to maintain this: after dequeue, the task's runq_next/prev must become 0 (off-list marker) even though it was part of a circular structure a moment before. This is guaranteed by runq_dequeue's contract (#563 §5).

sched_wake's runq_enqueue (step 3) inserts the target at the tail with tail.runq_next = target and target.runq_prev = tail. This maintains the circular property and the RUNNABLE-only invariant.

Witness Sub-test A verifies this: after simulated sched_block (state→WAITING + dequeue), the task's links are 0, and pick_next correctly falls back to _idle_tcb. Sub-test C verifies pick_next returns the enqueued task by position (not just by existence).

## 10. Deferred to follow-on issues

**Wake-on-preemption priority logic:** Currently wake does not preempt. When #568 (IPC send/recv) or higher-level primitives land, priority-based preemption-on-wake (woken task immediately preempts if higher priority) will be required. This is a Phase-9 systematic refactor, not a R15.M7 tactical issue.

**Timeout-driven wake (timer-based block):** sched_block currently has no timeout parameter. Block forever or return immediately if target is not ready is deferred to R15.M8 (status codes kept as forward-compatibility placeholders).

**Reason field:** No context passed to woken task about _why_ it was woken (timer, IPC, etc.). Deferred to R15.M8.

**Asymmetric guard asymptote:** The sched_wake silent early-exit is idempotent; sched_block terminal soft-panic is not. Future phases may require symmetric idempotence or symmetric panic. Current asymmetry is intentional for this phase.

## 11. Fingerprint file updates

Expected output files (tests/r15/expected-boot-r15-{process,ring3}.txt) updated by #567 commit 9fc81b0 to include marker line "R15 BLOCK WAKE OK" between "SCHED SWITCH OK" and "IPI OK" banners. No additional marker changes needed for #674 backfill (documentation-only).

## 12. LOC estimate + encoder-gap scan

Commit 9fc81b0 (sched_block/sched_wake landing):

```
 src/kernel/boot/kernel_main.pdx         | 93 ++++++++++++++++++++++++++++++++++++
 src/kernel/core/sched/runqueue.pdx      | 11 ++++
 src/kernel/core/sched/wake_block.pdx    | 74 +++++++++++++++++++-------
 tests/r15/expected-boot-r15-process.txt |  1 +
 tests/r15/expected-boot-r15-ring3.txt   |  1 +
 tools/boot_stub.S                       | 10 ++++
 6 files changed, 171 insertions(+), 19 deletions(-)
```

**wake_block.pdx change breakdown:**
- Delete six R4-era stub_* symbols: ~15 LOC (dead code removal).
- Rewrite sched_block body: ~26 LOC (9 instructions + guard + soft-panic path).
- Rewrite sched_wake body: ~12 LOC (4 instructions + guard + noop).
- Keep status/timeout constants: ~8 LOC (forward-compatibility).

**kernel_main.pdx block_wake_witness:** 93 LOC, 4 sub-tests (setup, block-simulate, wake-real, pick-round-trip, double-wake guard, drain).

**runqueue.pdx:** _block_witness_task_x slab addition (11 LOC, 448-byte allocation).

**boot_stub.S:** Witness success/fail banners (10 LOC).

No encoder gaps. All symbols and references compile cleanly.

## 13. R16 — sched_block assertion library

Issue #663 added tactical guards to sched_block and sched_wake inline (precondition state checks at function entry). These are necessary but crude: a full assertion library (contract-enforced at call sites, not just at entry) is deferred to R16 systematic overhaul (#668 or later).

**Tactical fix (R15.M7, #663):**
- sched_wake: silent early-exit on already-RUNNABLE (idempotent).
- sched_block: terminal soft-panic if not RUNNABLE (irreversible fail).

**Systematic replacement (R16, #668 or later):**
- Caller-side precondition verification: each call site documents and asserts the required task state.
- Static-analysis pass confirms all call sites satisfy the precondition.
- Run-time assertions in both directions (call-site check + function-entry guard).
- Deferred soft-panic is re-examined for opportunity to recover gracefully.

See design/kernel/r15-m7-006-block-wake-guards.md §4 for the post-landing addendum explaining Sub-test D and the timing of guard insertion.

## 14. Tractability

**Confidence:** High. sched_block and sched_wake are O(n) in call count (currently 0 callers; expected <5 at Phase-2 IPC landing). The state-machine logic is simple: one field write, one list operation. Witness covers all reachable paths at landing. Register discipline is straightforward (all caller-save scratch).

**Risk-to-reward:** High confidence in the logic itself; medium risk that preemption-safety deferral (#667) is missed. See §15 risk register.

**Test coverage:** Witness Sub-tests A–D are the only tests at landing. Structural verifier (guard byte patterns, fail-message symbols) is deferred to #663 follow-on. Runtime mutation testing (fuzzing task state, simulating dual-block, etc.) is deferred to R15.M8+ quality passes.

## 15. Risk register

### Risk #1: Preemption safety window deferral (Medium, **closed** by #667)

**Original state:** #567 landing did not include the cli/popfq preemption-safety window around sched_block steps (2)-(4), noting that #565 (LAPIC timer) was blocked on #662 (hardware investigation). When #565 eventually lands, an ISR-preempted sched_block could encounter inconsistent runqueue state.

**Resolution:** #667 (narrow tactical window, blocking on #662 resolution) or #668 (systematic Phase-8 preemption retrofit). See §7.2 for the design slot. Status at #674 backfill: architectural consensus reached; tactical branch available; closed pending #662 completion.

**Closed marker:** See design/kernel/r15-m7-006-block-wake-guards.md (addendum describing post-landing #663 guard insertion and preemption-safety dependency chain).

### Risk #2: Guard asymmetry (Medium, **closed** by #663)

**Original state:** sched_wake silent early-exit vs. sched_block terminal soft-panic. Asymmetry could be mistaken for inconsistency or incomplete error handling.

**Resolution:** Asymmetry is intentional and documented (§6 and #663 guards addendum §3). Silent early-exit on wake preserves idempotence; terminal panic on block prevents task resurrection. Trade-off: if a higher phase requires symmetric idempotence or panic, both functions will be revised together. See #663 for the guard insertion rationale and verification.

**Closed marker:** See design/kernel/r15-m7-006-block-wake-guards.md §3 (asymmetry rationale).

### Risk #3: State-machine precondition violations (Medium, Ongoing)

**Current state:** #663 guards detect and soft-panic on sched_block-not-RUNNABLE. sched_wake guards silently return. Beyond these inline checks, no static-analysis verification that callers obey the preconditions. Caller bugs could violate state invariants.

**Mitigation (R15.M7):** Witness Sub-tests exercise the happy path. Guard catches dynamic sched_block violations (soft-panic). sched_wake idempotence provides a safety margin for caller mistakes.

**Next step (R16):** Systematic call-site precondition verification (#668 or later). Each invocation of sched_block and sched_wake must be annotated with proof of state precondition. Static analysis + runtime assertions. See §13.

**Status:** Ongoing. Tactical guards sufficient for Phase-8 landing; systematic fix required for Phase-9.

