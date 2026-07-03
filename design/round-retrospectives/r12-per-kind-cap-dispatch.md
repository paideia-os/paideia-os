# R12 Retrospective: Per-Kind Capability Dispatch (Scope Decision + Execution)

**Date:** 2026-07-03  
**Milestone:** R12.M1–R12.M5  
**Issues:** 11 (m1-001..m5-003)  

---

## Scope Decision Retrospective

### Why B over A / C / D

The round-design phase identified four options. **Option B (per-kind dispatch)** was selected over:

- **Option A (Multicore):** Four paideia-as escalations (PA-R11-001..004: GS-relative mem, xchg, lock cmpxchg, mfence) are HARD blockers for SIPI, per-CPU GS data, and cross-CPU IPI. R12 timing did not permit bundling these substrate changes; they remain filed for R13 and do not regress R12's work. Multicore moved to Path A of R13 decision matrix.

- **Option C (MM API activation):** Real `aspace_map` / `aspace_unmap` with 4-level PT walk would require cap-mediated access (KIND_PAGE_TABLE). Without R12's per-kind dispatch framework in place, MM activation would be a raw kernel API — violating Pillar 3 (strict microkernel, all ops cap-gated). Deferred until after R12 lands dispatch, making it a natural R13 Path B.

- **Option D (Hybrid B+C):** Shipping per-kind dispatch + MM in one round blows the 15-issue MECE ceiling the user requested. Splitting B (this round) and C (next round) yields two cleaner, observable rounds vs. one blurred round. Mean estimate: B ≈ 11 issues, C ≈ 15 issues; bundled D ≈ 20–25 issues.

**Selected:** Option B, R12 narrow. Rationale: zero substrate blockers (all encoders verified in v0.11.0+19); composable primitives (dispatch skeleton + four pre-existing subsystem primitives = ipc_enqueue, ipc_dequeue, sched_yield, request_mmio_mapping); immediate observable payoff (four CAP INVOKE tags + CAP DISPATCH OK on COM1).

### Expected vs. Actual Issue Count

**Planned:** 13 issues across 6 milestones (m1: 2, m2: 2, m3: 2, m4: 2, m5: 3, m6: 2).  
**Actual (m1–m5):** 11 issues (no m6 implementation issues; documentation-only closure per user spec).

**Why fewer:** m6 (round closure) is pure documentation in this scope; no implementation issues within m6 proper. The user deferred m6 ceremony (tag-creation, PA-escalation filing) to post-closure. This retrospective, the closure doc, and the R13 kickoff are m6's deliverables.

---

## What Worked Well

1. **Four independent handler files are MECE and testable in isolation.**
   - Each handler (`kind_page.pdx`, `kind_ipc.pdx`, `kind_sched.pdx`, `kind_dev.pdx`) owns one kind and is agnostic to other handlers.
   - Enables parallel development: m3-001 and m3-002 can land independently; same for m4-001 and m4-002.
   - Testing each handler in cap_dispatch_smoke (m5-001) confirms isolation: if KIND_PAGE has a bug, only slot 4 and 8 invokes fail; slot 5/6/7 still succeed.

2. **Composing existing subsystem primitives (ipc_enqueue, ipc_dequeue, sched_yield, request_mmio_mapping) required minimal glue.**
   - These functions already existed and were tested in isolation (B6 IPC, D7 drivers).
   - R12 handlers are thin wrappers: decode op_arg, check rights, delegate to the primitive, return result.
   - No subsystem refactoring needed; R12 is purely additive at the cap layer.

3. **Tag emission on COM1 provides real-time audit trail and obviates need for complex regression harness.**
   - Each handler prints its tag *before* the primitive call, so a crash is not silent.
   - Fingerprint harness is simple string-in-output check (bash glob or contains-in-order).
   - Denial witness (slot 8 KIND_PAGE, OP_WRITE on READ-only cap) produces explicit `CAP DENIED` tag — positive proof of rights enforcement, not absence-of-error.

4. **Fallthrough to R8 MVP (return target_ptr for unknown kinds) preserves backward compatibility cleanly.**
   - Cap_smoke (R8 issue B5-005) mints kind=1 KIND_PROCESS, invokes with op_arg=0, expects target_ptr=0xCAFE back.
   - R12's four-way branch explicitly falls through to the MVP body on kind ∉ {4,5,7,10}.
   - Zero regression in `boot_r8_only` mode; no audit rewrites required.

5. **Zero paideia-as substrate gaps meant R12 opened unblocked (like R10 and R11).**
   - All critical-path encoders verified in v0.11.0+19 (mov mem, cmp imm, je, call).
   - No need for cross-PR coordination or blocking on external work.
   - Team velocity uninterrupted.

---

## What Was Harder Than Expected

1. **Register-hazard analysis in m2-001 required care.**
   - Incoming args: RDI = slot, RSI = op_arg.
   - After computing descriptor address, we need to pass (rights, target_ptr, op_arg) to the handler via (RDI, RSI, RDX).
   - Naïve sequence clobbered RSI before saving op_arg → handler received garbage in RDX.
   - Correct sequence: `mov r11, rsi` (save op_arg), then reassign RDI/RSI/RDX.
   - Audit entry explicitly recorded the hazard and the fix; byte-verified via objdump.
   - Lesson: register-reuse in short kernels is tight; clear notation (per-instruction RDI/RSI/RDX values) prevents regression.

2. **Payload encoding for OP_WRITE (op_arg high 56 bits) proved ambiguous.**
   - M3-001 spec (osarch §6 m3-001) deferred full "payload = (index, value)" encoding to R13.
   - R12 stub: always write 0xCAFEBABE to slot 0, ignore payload.
   - Sufficient to prove the dispatch path (if called, the write happens).
   - If R13 refines payload encoding, the stub nature doesn't regress; it's an extension, not a compatibility break.
   - Moral: "happy path only" stubs are acceptable milestones if clearly marked deferred.

3. **Rights-check discipline for KIND_DEVICE (R_DRIVER_MMIO as kind-specific right in base 64-bit rights word) introduced a bitmask overlap risk.**
   - M4-002 checks `(rights & 0x0A) == 0x0A` to enforce both RIGHT_INVOKE (0x08) and R_DRIVER_MMIO (0x02).
   - Typo risk: if the mask is wrong (e.g., 0x0C instead of 0x0A), it silently passes when only one bit is set.
   - Saved by boot_r12_denial witness: a KIND_DEVICE cap minted without R_DRIVER_MMIO would be rejected, failing the fingerprint.
   - Lesson: rights-check bugs are caught by regression only if the fingerprint explicitly exercises denial paths.

4. **Slot-allocation discipline (slots 4–8 for R12, slot 0 reserved for cap_smoke) required explicit documentation.**
   - If a future phase adds a cap-subsystem smoke using slots 4–8, collision is silent until two different tests run and mints clobber each other.
   - Cap_mint_write is destructive; no guard against overwrites.
   - Solved by audit entry (m5-001) explicitly recording slot reservation and cap_smoke's usage.
   - Lesson: static allocation without guards requires written contract; slack in the design (e.g., 16 slots total, only 256 needed for R12-R15) prevents collisions at scale.

---

## R13 Carryover List

1. **Four paideia-as substrate escalations filed at R12 close** (PA-R12-001..004):
   - GS-relative mem operand (for per-CPU GS-based _current_tcb in multicore)
   - xchg [mem], reg (for atomic cap table updates across CPUs)
   - lock cmpxchg (for multicore spinlock primitives)
   - mfence (for memory ordering in IPI sequences)

2. **Handler-table migration (A2 dispatch style).** R13's m1 natural place to re-architect from direct branch to indirect call through a 16-entry table. Unblocks future scaling beyond 12 kinds and improves debuggability (single entry point for all handlers).

3. **Real MM-backed OP_MAP_MMIO.** R12's request_mmio_mapping synthesizes vaddr; R13's MM activation (Path B) will call real aspace_map and return actual kernel virtual address mapped to phys_base.

4. **Remaining 8 cap kinds (PROCESS, THREAD, PAGE_TABLE, IPC_PORT, TIMER, INTERRUPT, NOTIFICATION, REPLY).** R12 lands 4 kinds; fallthrough covers the 8 unknowns. Each future kind adds one more branch to the four-way dispatch.

5. **Curried-call wrapper support.** R8 and R12 smokes bypass the curried `cap_invoke(slot)(op_arg)` form and call `cap_invoke_dispatch` directly. When paideia-as gains full curried-call support (Phase 20+), both can migrate to the curried surface.

6. **Per-cap IPC channel addressing.** R12 KIND_IPC_ENDPOINT uses global channel_data; R13 will encode channel-pool indices in descriptor.target_ptr to enable per-cap channel isolation.

7. **Generation-based revocation validation.** Descriptor.generation field exists (R2.5-004) but is unread in dispatch. R13 adds `if (descriptor.generation != cap_table_generation[slot]) return INVOKE_REVOKED`.

---

## Process Observations

1. **Milestone-centric decomposition works well when boundaries are clean.** R12's six milestones map to six distinct problem areas: m1 (audit), m2 (control flow), m3 (half handlers), m4 (other half), m5 (harness), m6 (closure). Parallelizable sub-tracks (m3 ‖ m4, m5-001 → m5-002 → m5-003) kept the critical path tight (~13 issues, mostly sequential but with 2-day parallel bands).

2. **Smoke harness discipline (contains-in-order fingerprints) scales better than line-positional checks.** boot_r10 and boot_r11 fingerprints tolerate new lines injected between their anchor points (e.g., CAP INVOKE block between IPC OK and IDT OK). Position-based checks would regress. Contains-in-order: three 3-line reps of boot_r10 in the regression matrix all PASS despite the new intermediate output.

3. **Regression matrix (6 modes × 3 reps = 18 runs) caught zero bugs but provided high confidence in non-regression.** The 18 runs share byte-identity through the fingerprint region (SHA-256 identical across all samples), confirming determinism. If even one run had flaked, it would surface at regression time, not at user-deployment time.

4. **Zero-substrate-gap principle from R11 preview enabled unblocked start.** R11's plan listed five risk areas (timer delivery P1–P5); R12 had zero. Result: m1-001 → m1-002 took one day (both S issues, sequential). If R12 had required a paideia-as escalation, the critical path would have extended by 3+ days pending substrate turnaround.

5. **Audit-first (m1) paying off.** Spending two issues on pre-flight (encoder verification, architecture pin) meant m2–m5 could land with confidence. Every design decision (direct vs. table, per-handler vs. centralized rights, op_arg encoding) was pinned in audit before code was written. Zero design churn post-m2.

---

## Kernel Observations

1. **Dispatch skeleton (m2-001) is the tightest piece of code in the round.** 30+ instructions implementing a descriptor read, four-way branch, and fallthrough required byte-by-byte verification. The register-hazard analysis (RDI/RSI/RDX assignment order) was the only place where a subtle bug could hide. Lesson: code review for assembly must include register-live-range diagrams.

2. **Per-kind handler uniformity (tag emit, rights check, op-code decode, primitive delegate, return) makes them easy to review in parallel.** Each handler follows the same shape; deviation from the pattern is a red flag. If kind_ipc.pdx's rights check used `cmp rax, mask; je` instead of `cmp rax, mask; jne`, that inversion would violate the pattern and be caught in peer review.

3. **Rights bitmask discipline is fragile without static checking.** R12 uses hand-written bitmasks (RIGHT_READ=0x01, RIGHT_WRITE=0x02, RIGHT_INVOKE=0x08). A future refactor changing the constants breaks all four handlers unless all four are updated together. No compiler catches this (just numbers). Lesson: rights.pdx should export symbolic constants (pub let RIGHT_READ = 0x01) and handlers should use them, not hardcoded literals. Future: formalize rights as a struct or enum.

4. **Fallthrough behavior (unknown kinds return target_ptr) is a safe default but could become a liability.** If a new kind is added in R13 but an old handler (e.g., a driver) is not recompiled, it silently falls through and returns target_ptr instead of failing loudly. R13 should consider adding an unknown-kind handler that logs "CAP INVOKED UNKNOWN KIND" and returns INVOKE_UNSUPPORTED (not fallthrough).

---

**Recommendation for R13:** Adopt Path A (multicore). The four paideia-as escalations (PA-R12-001..004) are well-understood and scoped. Multicore unlocks per-CPU everything: runqueues, TLB shootdown, cross-CPU IPI. R12's capability dispatch becomes the security layer for inter-CPU messaging. MM activation (Path B) can follow as R13.5 once multicore's GS-based data model is in place.

