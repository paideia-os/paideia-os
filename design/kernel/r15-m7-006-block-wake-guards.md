# R15.M7-006 Guards: sched_block / sched_wake preconditions (#663)

## Origin

Verification pass of #567 (sched_block/sched_wake landing at 9fc81b0)
surfaced two documented-deliberate design gaps as trackable issue #663.
This addendum documents the fix. Base design doc: `design/kernel/r15-m7-006-block-wake.md` (backfilled by #674).

## 1. Failure modes

**Double-wake (sched_wake):** unconditionally setting state=RUNNABLE +
runq_enqueue on an already-RUNNABLE task splices it into the doubly-
linked circular runq a second time, producing a "figure-8" topology.
Silent corruption until the next pick_next walks the bad links → page
fault far from the call site.

**Block-on-non-RUNNABLE (sched_block):** unconditionally writing state=
WAITING on _current_tcb regardless of its actual state. Would
resurrect a ZOMBIE as WAITING, or dequeue an already-off-runq task.

## 2. Guard specs

### sched_wake — cheap silent early-exit

At entry: `mov ecx, [rdi+8]; cmp ecx, 1; je sched_wake_noop`. Falls
through on RUNNABLE-mismatch (2 instrs, ~0 cycle cost). No state
mutation, no side effect, idempotent.

### sched_block — terminal soft-panic

At entry (after loading _current_tcb): `mov ecx, [rax+8]; cmp ecx, 1;
jne sched_block_precond_fail`. Fail path: `uart_puts("SCHED PRECOND
FAIL: block on non-RUNNABLE\n"); cli; hlt` loop. Same idiom as
exceptions.pdx / entry.pdx.

## 3. Asymmetry rationale

Silent for wake, terminal for block:

- Double-wake is semantically a no-op — the caller's intent (task
  should be runnable) is already true. Early-exit preserves
  idempotence.
- Block-on-!RUNNABLE is a serious invariant violation. Silently
  returning would fall through into a caller that expects to resume
  from another task; continuing in an inconsistent state is worse
  than freezing. Terminal soft-panic matches exceptions.pdx pattern.

## 4. Witness coverage

- **Runtime (Sub-test D in block_wake_witness):** exercises the wake
  guard directly — calls sched_wake twice, asserts state + runq_next
  unchanged after the second call.
- **Structural (tools/verify-sched-guards.sh):** confirms both guard
  byte patterns present in compiled kernel + that sched_block
  references the fail-message symbol. The block guard fail path
  cannot be exercised at runtime without freezing boot — verifier
  proves the code is there.

## 5. Cross-references

- Parent: #567 (sched_block/sched_wake landing).
- Base doc: #674 (backfill r15-m7-006-block-wake.md).
- This issue: #663.
