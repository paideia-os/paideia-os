# PaideiaOS — SMP-Aware Scheduler

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Architectural specification of the PaideiaOS scheduler. Covers the SC (scheduling-context) dispatch policy, SC descriptor layout, per-CPU runqueue topology with bounded work-stealing, reserved-core capability, heterogeneous-core (P/E) placement, SC donation across sync IPC, the WAITPKG-tiered idle discipline, kernel pre-emption discipline, the UMWAIT-or-IPI cross-core wake-up strategy, and the mitigation-cost optimization for same-AS context switches.

**Hard inputs (do not relitigate):**
- `design/00-feature-inventory.md` — C5 (thread + SC objects), C6 (SMP-aware scheduler), C18 (per-CPU data + IPI primitives); D3 (real-time scheduling), D15 (energy-aware scheduling).
- `design/01-foundational-decisions.md` — Q8 (soft RT via SC model), Q10 (poll-mode on reserved core), Q15 (max mitigations default).
- `design/02-development-environment.md` — feature-masked CI lanes test the no-WAITPKG (Skylake/Coffee Lake), no-hybrid (pre-Alder Lake) paths (§10.5).
- `design/toolchain/custom-assembler.md` — substructural lattice (Q-A2), algebraic effects (Q-A3), R12/R13 cap band, R14/R15 effect environment, calling convention (§8).
- `design/ipc/wait-free-dataflow.md` — notification-wake + SC donation for sync sessions (IPC-Q7); enqueue may trigger a wake (§7.1).
- `design/capabilities/linearity-and-tags.md` — SC is base kind 5; `sched-ctx` capability descriptor.
- `design/kernel/memory-model.md` — per-CPU NUMA-local direct map (MEM-Q1); per-domain free lists (MEM-Q3); PCID + KPTI (MEM-Q8).

---

## 0. Decisions summary

### 0.1 Inherited (already binding)

| Source | Constraint |
|---|---|
| Q8 | Soft real-time via the scheduling-context (SC) model; admission control via `Σ(budget/period) ≤ 1` per CPU. |
| Q10 | Poll-mode networking on a reserved core when total core count ≥ N. |
| Q15 | Max Spectre/Meltdown mitigations are default; `relax-mitigations` capability is the audited escape. |
| IPC-Q7 | Notification-driven wake for async; SC donation for sync session steps. |
| MEM-Q3 | Per-NUMA-domain allocators; no automatic cross-domain rebalancing. |
| MEM-Q8 | PCID-tagged TLB + KPTI-equivalent split tables. |
| CAP-Q3 | Closed 16-kind base enum; `sched-ctx` is kind 5; new `reserved_core_cap` consumes one of the reserved slots. |
| Q-A2 / Q-A3 | Substructural lattice + algebraic effects; SC handles are linear. |

### 0.2 New decisions in this document

| # | Question | Decision |
|---|---|---|
| SCH-Q1 | Dispatch policy | Fixed-priority preemptive with SC bandwidth enforcement (seL4-MCS classic). 256 priority levels; highest-priority runnable thread with budget runs; on budget exhaustion, the thread is suspended until next period refill. |
| SCH-Q2 | SC descriptor structure | `(budget : duration, period : duration, refill_pattern : RefillKind, priority : u8, numa_affinity : NumaDomain, core_class : CoreClass)`. Six fields total; ~24 bytes in the descriptor tail. |
| SCH-Q3 | Run queue topology | Per-CPU runqueue (priority-sorted heap); bounded work stealing *within the same NUMA domain only*; cross-NUMA migration requires an explicit `explicit_migrate_cap`. |
| SCH-Q4 | Reserved core policy | `reserved_core_cap` is a new base capability kind (consuming reserved enum slot #14). Holding it grants exclusive CPU ownership; the scheduler refuses to enqueue any other thread on that CPU. Supervisor mints at boot per policy. |
| SCH-Q5 | Heterogeneous cores | The SC's `core_class` field drives placement: {P-core, E-core, Any}. The supervisor sets at thread spawn; an `upgrade_core_class_cap` allows runtime upgrades with audit. The kernel reads CPUID 0x1F at boot to discover the topology. |
| SCH-Q6 | SC donation | Full SC transfer across sync session steps: producer's SC moves to consumer for the call duration; producer suspends; on response, SC returns to producer. The consumer's own SC remains attached but inactive during donations. |
| SCH-Q7 | Idle discipline | Tiered by expected next-wake time: < 50 µs → TPAUSE; 50 µs–1 ms → UMWAIT on monitored cache line; 1 ms–10 ms → MWAIT with C1/C1E hint; > 10 ms → HLT (optionally falling into ACPI C-states under supervisor policy). Software fallback to MWAIT/HLT on pre-Tiger-Lake silicon. |
| SCH-Q8 | Pre-emption | Kernel non-preemptive between explicit yield points; user-mode fully preemptive at any IRQ. Long-running kernel ops (epoch-exhaustion migration per CAP-Q8, large subtree revocation) carry explicit `yield()` calls. |
| SCH-Q9 | Cross-core wake | Hybrid: a consumer in UMWAIT on the channel's head-index cache line is woken automatically by the producer's enqueue store (no IPI); a runnable-but-descheduled consumer is woken via targeted IPI. The channel metadata records the wait mode. |
| SCH-Q10 | Mitigation cost on context switch | Always-on default per Q15; *same-AS* context switches (intra-process SC switch) skip cross-AS mitigations (KPTI CR3 swap, IBPB) since the trust boundary is unchanged; `relax-mitigations` capability skips all mitigations with audit. |

### 0.3 Three meta-positions

1. **Soft RT is enough.** The fixed-priority + SC-bandwidth policy provides *bounded latency for cooperating threads*, which is sufficient for audio, video, networking, interactive UI, and the wait-free IPC primitive's notification latency. Hard real-time (admission-controlled EDF, WCET-bounded kernel ops) is deferred to a future revision (D3 work).

2. **The reserved-core capability is the cleanest way to encode Q10.** Q10's "reserve a core for poll-mode networking" is one specific case of a more general pattern (real-time threads, dedicated audit consumers, future GPU command-submission threads, etc.). Making it a capability puts the policy in the supervisor and makes the audit trail explicit.

3. **Mitigation savings on same-AS switch is non-trivial.** A typical IPC-heavy workload sees more *intra-process* switches (SC budget exhaustion, internal yield) than cross-process. Skipping KPTI's CR3 swap + IBPB on same-AS switches gives back ~150 cycles per intra-AS switch — significant against the Q15 max-mitigations cost.

---

## 1. Architectural overview

```
                      ┌──────────────────────────────────────┐
                      │   Scheduler (per-CPU)                 │
                      │                                       │
                      │   ┌──────────────────────────────┐   │
                      │   │ Priority heap (256 bands)    │   │
                      │   │   each band = doubly-linked  │   │
                      │   │   list of runnable SCs       │   │
                      │   └──────────────────────────────┘   │
                      │                                       │
                      │   ┌──────────────────────────────┐   │
                      │   │ Refill timer wheel            │   │
                      │   │   (high-resolution; TSC-      │   │
                      │   │    deadline-driven)           │   │
                      │   └──────────────────────────────┘   │
                      │                                       │
                      │   ┌──────────────────────────────┐   │
                      │   │ Idle-discipline state          │   │
                      │   │   (current idle level,        │   │
                      │   │    monitored cache line,      │   │
                      │   │    next expected wake)        │   │
                      │   └──────────────────────────────┘   │
                      │                                       │
                      │   ┌──────────────────────────────┐   │
                      │   │ Mitigation state shadow       │   │
                      │   │   (last AS, IBRS state,       │   │
                      │   │    L1D-flush counter)         │   │
                      │   └──────────────────────────────┘   │
                      └────────────────┬─────────────────────┘
                                       │
       ┌───────────────────────────────┼─────────────────────────┐
       │                                                          │
       ▼                                                          ▼
   Wake events                                              Schedule events
   - IPC enqueue notification                          - SC budget exhausted
   - SC refill timer                                   - Yield called
   - Inter-processor interrupt                         - IRQ entry/exit
   - Monitored cache-line write                        - Sync IPC step
                                       │
                                       ▼
                      ┌──────────────────────────────────────┐
                      │  Work-stealing window                  │
                      │  - Eligible peer CPUs: same NUMA      │
                      │  - Eligible class: matches our class  │
                      │  - Eligible budget: positive          │
                      │  Bound: one steal per idle tick       │
                      └────────────────┬─────────────────────┘
                                       │
                                       ▼
                                  ┌─────────────────┐
                                  │ Reserved cores  │
                                  │ (capability-    │
                                  │  gated;         │
                                  │  exclusive)     │
                                  └─────────────────┘
```

---

## 2. SC descriptor structure (SCH-Q2)

### 2.1 Descriptor tail layout

```
 Offset  16                  24                  32                  40       48
         ┌──────────────────┬──────────────────┬──────────────────┬─────────┐
common   │ ← header (16 bytes per CAP-Q2 — kind, flags, parent, etc.) ─→  │
header   ├──────────────────┴──────────────────┴──────────────────┴─────────┤
         │ budget (8 B)     │ period (8 B)     │ priority (1)    │ ...     │
         │                                     │ refill (1)      │         │
         │                                     │ core_class (1)  │         │
         │                                     │ numa_aff (1)    │         │
         │                                     │ flags (4)       │         │
         ├──────────────────┴──────────────────┴──────────────────┴─────────┤
         │ next_refill_time (8 B)              │ runnable_node (16 B)      │
         ├─────────────────────────────────────┴────────────────────────────┤
         │ donor_chain_ptr (8 B)               │ reserved (16 B)            │
         └────────────────────────────────────────────────────────────────────┘
```

- **budget**: maximum nanoseconds of CPU time per period.
- **period**: refill period in nanoseconds.
- **priority**: 0–255 (0 lowest; 255 highest; 255 reserved for kernel-internal use).
- **refill** (`RefillKind`): one of `Head` (full budget at start of period), `Continuous` (proportional), `Deadline` (budget refills at deadlines, EDF-style — phase 3+).
- **core_class**: 0 = Any, 1 = P-core, 2 = E-core (more values reserved).
- **numa_aff**: 0–255 NUMA domain id (0 reserved as "no preference").
- **flags**: reserved-core flag, donating-from flag, blocked-on-SC flag, etc.
- **next_refill_time**: TSC tick at which next refill occurs.
- **runnable_node**: per-CPU runqueue linkage.
- **donor_chain_ptr**: when this SC is donated, points to the consumer SC; for unwinding on return.

### 2.2 SC lifecycle

1. **Create** (`retype` from memory to `sched-ctx` kind, per CAP-Q7): supervisor mints SC with declared budget/period/priority.
2. **Bind to thread** (`bind_sc`): SC associates with a TCB; the thread becomes schedulable.
3. **Make runnable** (`wake`): SC enters its CPU's runqueue.
4. **Schedule** (kernel chooses): SC's TCB context loaded; runs.
5. **Budget consumed**: per-tick decrement; budget exhausted → SC suspended.
6. **Refill** (timer wheel): at `next_refill_time`, budget restored per `refill` pattern.
7. **Donate** (sync IPC, SCH-Q6): SC moves to consumer TCB.
8. **Release on donation return**: SC returns to donor.
9. **Unbind** (`unbind_sc`): SC released from TCB; thread no longer schedulable.
10. **Revoke** (per CAP-Q8): SC descriptor's revocation epoch bumps; outstanding handles fail.

### 2.3 Admission control

When `bind_sc` is called, the supervisor must ensure:

```
Σ (sc.budget / sc.period) for all SCs bound to threads runnable on CPU C ≤ 1.0
```

The kernel reports each CPU's current admission as a queryable metric; the supervisor enforces the policy. Over-admission produces `AdmissionExceeded` error.

### 2.4 SC linearity

Per Q-A2, an SC capability handle is **linear**. A thread holds exactly one SC at any time (its own). Donation temporarily transfers the linear handle; the donor's TCB records the chain for return.

---

## 3. Scheduling policy (SCH-Q1)

### 3.1 The dispatch rule

At every schedule decision, the per-CPU scheduler:
1. Examines the priority heap top-down.
2. Selects the highest priority band with at least one runnable SC.
3. Within the band, FIFO ordering of arrival (the runnable_node deque).
4. The selected SC's TCB context is loaded.
5. Per-CPU timer set to the smaller of (SC's remaining budget, scheduler quantum, next refill of a higher-priority SC).

### 3.2 Quantum within a priority band

For SCs at the same priority, the scheduler enforces a *quantum* (default 1 ms; configurable per-CPU) before switching to the next SC in the band. This is round-robin within a priority. The quantum is independent of the SC budget; the budget continues to decrement.

### 3.3 Budget exhaustion

When an SC's budget reaches zero:
1. The TCB is removed from the runnable set.
2. A refill timer is set for `next_refill_time`.
3. The scheduler picks the next runnable SC.

When the refill timer fires:
1. The SC's budget is recharged per `refill` pattern.
2. The TCB is re-inserted into the runnable set at its priority.
3. If the inserted priority exceeds the currently running, preemption occurs.

### 3.4 Why fixed priority

- **Predictability.** Higher priority always wins; admission control gives temporal isolation.
- **seL4-MCS lineage.** Formal latency bounds available (Lyons et al., EuroSys 2018).
- **Cooperative with the IPC primitive.** Sync RPC's SC donation (SCH-Q6) raises the consumer's effective priority to the producer's during the call — solving the classical priority-inversion in microkernel patterns.
- **Verification-friendly.** Q2's posture wants the scheduler to be easy to reason about; fixed priority is the simplest non-trivial policy.

### 3.5 Idle SC

Each CPU has a kernel-managed `IdleSC` at priority 0 with infinite budget, infinite period. It runs when no other SC is runnable. The idle SC's TCB executes the SCH-Q7 idle discipline.

### 3.6 Priorities used in PaideiaOS

Reserved priority bands (configurable; this is the recommended convention):

| Range | Use |
|---|---|
| 0 | Idle. |
| 1–32 | Background workloads (compaction, audit-log flush, GC). |
| 33–96 | General-purpose userspace. |
| 97–160 | Interactive userspace (shell, GUI). |
| 161–192 | Latency-sensitive servers (network stack, audio, video). |
| 193–224 | Drivers and time-critical kernel servers. |
| 225–254 | Kernel-supervisor (allocates reservations, handles MemoryPressure). |
| 255 | Reserved for kernel-internal scheduling (idle SC, refill timer SC). |

---

## 4. Run queue topology (SCH-Q3)

### 4.1 Per-CPU runqueue

Each CPU's scheduler owns:
- A priority heap indexed by 256 bands.
- Each band is a doubly-linked list (FIFO).
- A per-CPU `Σ (budget/period)` running total for admission tracking.
- A refill-timer wheel (high-resolution, TSC-deadline-driven).

The runqueue lives in the critical-structures region (per MEM-Q1) at a fixed offset from each CPU's GS-base.

### 4.2 Wait-free runqueue operations

Insert and dequeue are wait-free for the owning CPU. Cross-CPU operations (the work-stealing path) use a wait-free MPSC enqueue from steal-source to steal-destination's local SPSC channel; the destination CPU drains during its idle decision.

### 4.3 Work-stealing rules

When a CPU's runqueue is empty (no runnable SC outside the idle SC):
1. Enumerate peer CPUs *in the same NUMA domain*.
2. For each peer, atomically dequeue the lowest-priority entry from their runqueue (only if priority < some threshold to avoid stealing high-priority work).
3. At most one steal per idle decision.
4. Stolen SC is re-bound to the stealing CPU's runqueue temporarily; the original CPU's load decreases by the stolen SC's `budget/period`.

When the original owner becomes non-idle again, the stolen SC is *not* automatically returned; it stays on the new CPU until its budget exhausts and is refilled (refill happens at the new CPU). Migration back is an explicit `explicit_migrate_cap` operation.

### 4.4 Cross-NUMA: forbidden by default

Stealing across NUMA domains is disabled. A workload that needs cross-NUMA balance must explicitly migrate (per MEM-Q3 / SCH-Q3). The supervisor may include cross-NUMA balancing in its policy via `explicit_migrate_cap`.

### 4.5 No global queue

There is no global runqueue. The per-CPU + bounded-steal design avoids the contention point that plagued early SMP Linux.

---

## 5. Reserved core capability (SCH-Q4)

### 5.1 The `reserved_core_cap` kind

A new base capability kind consuming reserved enum slot #14. Descriptor tail:

```
 reserved_core_cap tail:
   target_cpu_id  : u32      // physical CPU id (apicid)
   policy         : ReservationPolicy
   release_token  : u64      // for revocation
```

`ReservationPolicy` options: `Exclusive` (no other thread schedules), `Cooperative` (other threads scheduled only if reserving thread blocks), `Bounded` (other threads up to a quantum percentage).

### 5.2 Effect on the scheduler

When a thread holds `reserved_core_cap` targeting CPU N:
- The scheduler on CPU N runs only this thread (Exclusive); other runnable SCs are *rejected* from CPU N's runqueue.
- The thread's SC budget enforcement is *disabled* on this CPU; the thread runs continuously until it yields or releases.
- The CPU's work-stealing receiver is disabled; no peer can steal from it.

### 5.3 Release

The thread can release the reservation via `release_reserved_core(cap)`; the CPU returns to the general pool, and pending SCs queued elsewhere become eligible for placement on this CPU.

Revocation (per CAP-Q8) by the supervisor immediately ejects the holder's thread; the CPU is reclaimed; the holder's next run reports `ReservationRevoked`.

### 5.4 Use cases

| Holder | Policy | Use |
|---|---|---|
| Network-stack server (Q10) | Exclusive | Poll-mode NIC ring; deterministic packet latency. |
| Audio engine | Exclusive on E-core | Latency-stable audio mixing. |
| GPU command submission (D5/D6 future) | Cooperative | GPU job dispatch with fallback. |
| Real-time control loops | Exclusive | Hard-RT-equivalent guarantees. |
| Debugger snapshot thread (future) | Bounded | Periodic full-system observation. |

### 5.5 Configuration at boot

The supervisor's boot policy specifies, given the discovered CPU count and topology:
- `reserved_cores_for_poll_mode` (Q10's N threshold): if `cores ≥ 8`, mint one `reserved_core_cap` for the network stack.
- `reserved_cores_for_audio`: optional, set by user policy.
- Etc.

The configuration is `design/system/reservation-policy.toml` (future).

---

## 6. Heterogeneous core handling (SCH-Q5)

### 6.1 Topology discovery

At boot, the kernel reads CPUID leaf 0x1F (extended topology v2; TODO: verify QEMU support per `02-development-environment.md` §2.10). The leaf reports:
- Each CPU's package, die, module/CCD, core_type.
- `core_type` field: 0x20 = E-core, 0x40 = P-core (Intel marking).

The kernel constructs a per-CPU descriptor with the class.

### 6.2 SC placement

When a thread becomes runnable:
1. Read its SC's `core_class`.
2. Enumerate CPUs matching the class (or all CPUs if `Any`).
3. Among matching CPUs, prefer those in the SC's preferred NUMA domain.
4. Pick the least-loaded eligible CPU (sum of priorities × budgets in the runqueue).
5. Insert into that CPU's runqueue.

### 6.3 The Any class

`core_class = Any` allows running on either P or E cores. The placement algorithm prefers P-cores for higher priorities (priority ≥ 161 in the convention above) and E-cores for lower priorities — an automatic affinity that maximizes throughput without explicit annotation.

### 6.4 `upgrade_core_class_cap`

A thread can request a `core_class` change at runtime (e.g., a background batch job promotes itself for interactive work). The change requires holding `upgrade_core_class_cap`; every upgrade is audited. Downgrades are free (no capability needed; voluntary self-demotion is safe).

### 6.5 Software fallback for non-hybrid CPUs

On pre-Alder Lake CPUs (every CPU is P-class equivalent), the kernel treats all CPUs as `Any` regardless of SC class. SCs requesting `E-core` are placed on any available CPU with a logged warning.

---

## 7. SC donation across IPC (SCH-Q6)

### 7.1 The donation operation

When a producer issues `↑Request` on a sync session-typed channel (per IPC-Q6):

```
1. Producer's TCB:
   - sc_held = producer.tcb.bound_sc           // the producer's SC
   - Save sc_held.runnable_node (it will be moved)

2. Consumer's TCB:
   - donor_chain = (producer.tcb, sc_held)
   - Push (donor_chain, consumer.tcb.original_sc) onto consumer.tcb.donor_stack
   - consumer.tcb.bound_sc = sc_held            // donated SC takes over

3. Producer's TCB:
   - producer.tcb.state = BlockedOnSession
   - producer.tcb.bound_sc = null

4. Scheduler:
   - Consumer becomes runnable at sc_held.priority (which is producer's priority — high)
   - Consumer's CPU's scheduler picks it up; runs at the donated priority
```

When the consumer issues `↑Response` (the matching session step):

```
1. Pop donor_chain off consumer.tcb.donor_stack
2. consumer.tcb.bound_sc = original_sc        // return to consumer's own SC
3. producer.tcb.bound_sc = donor_chain.sc     // donor SC returns to producer
4. producer.tcb.state = Runnable
5. Scheduler may preempt consumer if producer's priority is higher
```

### 7.2 Nested donations

If a consumer (running on a donated SC) makes a further sync RPC, the donation chains: consumer's TCB receives a *new* donation from the next-level consumer, while still holding the chain pointing to the original producer's SC. The donor_stack preserves the order.

On return, the donations unwind in reverse — correct for nested RPC patterns.

### 7.3 Donor crash

If the producer dies while donated, the consumer's `bound_sc` is the dead producer's SC. The kernel's death handler:
1. Walks all TCBs to find any holding the dead producer's SC.
2. Restores their `original_sc`.
3. Pops their donor_stack accordingly.

This is rare and slow (TCB walk); the supervisor's audit log records every such event.

### 7.4 Why full SC transfer

- The consumer literally inherits the producer's deadline pressure.
- Priority inversion is eliminated: the consumer runs at producer-priority, so lower-priority work doesn't block the responder.
- The accounting is clean: producer pays for the time it actually consumed (via the consumer).
- Matches the Lyons et al. formalization, allowing direct reuse of their proof structure.

### 7.5 SC donation cost

| Operation | Cycles |
|---|---|
| SC field swap on TCB | ~30 |
| Donor stack push/pop | ~20 |
| Schedule decision | ~50 |
| Total per donation | ~100 |

A sync RPC round-trip with donation costs the same as the IPC primitive's sub-microsecond budget (per IPC §12).

---

## 8. Idle discipline (SCH-Q7)

### 8.1 The tiered idle

When the scheduler picks the idle SC, the idle handler examines `next_expected_wake`:

```paideia-as
fn idle() -> unit !{idle_discipline} =
  let now = read_tsc()
  let next_wake = scheduler_state.next_refill_or_timer_or_wait
  let idle_duration = next_wake - now

  if idle_duration < 50_us:
    enter_tpause(next_wake)
  else if idle_duration < 1_ms:
    enter_umwait(scheduler_state.monitored_line, next_wake)
  else if idle_duration < 10_ms:
    enter_mwait_c1(next_wake)
  else:
    enter_hlt_or_deeper_cstate(next_wake)
```

### 8.2 TPAUSE path

`TPAUSE rcx` pauses up to the TSC deadline in `rdx:rax`. The CPU stays in low-power-but-fast-resume state. Interrupts or monitored-line writes wake immediately. Cost: ~10–50 ns wake latency.

### 8.3 UMWAIT path

Before UMWAIT, the kernel sets a monitor on the channel's head-index cache line for any consumer SC waiting on a channel. `UMWAIT rcx` waits up to the TSC deadline OR until the monitored line is touched. The wait is interruptible by IRQ. Cost: ~100–500 ns wake latency.

### 8.4 MWAIT path

`MONITOR` + `MWAIT` with C1/C1E hint. Deeper power saving; longer wake latency (~1 µs).

### 8.5 HLT and deeper C-states

`HLT` halts until next interrupt. If the supervisor's policy allows deeper C-states (C3/C6/C7+), the kernel writes the appropriate `MWAIT` hint or invokes ACPI `_CST` evaluation. Wake latency rises significantly (10s of µs) but power saving is large.

### 8.6 Software fallback

On pre-Tiger-Lake silicon without WAITPKG:
- The < 50 µs case falls to a `PAUSE` spin loop.
- The 50 µs–1 ms case falls to MWAIT C1.
- The rest is unchanged.

The CI feature-masked lane (`minimum-skylake-x` per dev-env §10.5) exercises the fallback path.

### 8.7 Energy interaction (D15 future)

The idle discipline interacts with energy-aware scheduling: the supervisor's policy may instruct the scheduler to *deepen* idle (favor energy over wake latency) when battery-low, or *flatten* idle (favor wake latency) when AC-powered. The hooks are present in this design; the policy implementation is D15 phase 3+.

---

## 9. Pre-emption discipline (SCH-Q8)

### 9.1 Where pre-emption happens

| Boundary | Pre-emption? |
|---|---|
| User → kernel (syscall, IPC, IRQ) | Yes — scheduler may run |
| Within kernel atomic section | No |
| Explicit `yield()` call within kernel | Yes — voluntary |
| Kernel → user return | Yes — scheduler may run |
| IRQ delivered to user thread | Yes — IRQ handler runs; scheduler may run on return |

### 9.2 Atomic-section discipline

Kernel code is partitioned into *atomic sections* — between any two yield points, the kernel runs as if interrupts are disabled (CPUID IF cleared on entry to most kernel paths). Interrupts pending during an atomic section are queued and delivered at exit.

The kernel's atomic-section length is bounded; the longest path is the epoch-exhaustion migration (per CAP-Q8), which contains explicit `yield()` calls every N descendants processed.

### 9.3 Voluntary yield

A kernel operation that may take long calls `yield()` at well-defined boundaries. Yield:
1. Re-enables interrupts briefly.
2. Allows the scheduler to preempt if a higher-priority SC is now runnable.
3. On return, re-disables interrupts and resumes.

### 9.4 Why this is sufficient

- Most kernel ops are sub-microsecond (atomic-section length easily < 1 µs).
- The few long ops (revocation tree-walks, epoch migration) have explicit yields.
- The scheduler latency budget (sub-microsecond response to a high-priority wake) is unaffected by short atomic sections.
- The kernel-internal lock-free reasoning is dramatically simpler.

---

## 10. Cross-core wake-up (SCH-Q9)

### 10.1 The two paths

When a producer's IPC enqueue must wake a consumer:

**Path A: UMWAIT-monitored wake.** The consumer is currently in `UMWAIT` with its monitor on the channel's head-index cache line. The producer's atomic store to the head index triggers the monitored-wake; the consumer's CPU resumes from UMWAIT; the consumer's scheduler picks up the consumer's SC.

**Path B: IPI wake.** The consumer is runnable-but-descheduled (its SC is in the runqueue but a higher-priority SC is running, or its SC budget is exhausted). The producer issues a targeted IPI to the consumer's CPU; the IPI handler runs the scheduler; the consumer may preempt.

### 10.2 Wait-mode tracking

When a consumer prepares to UMWAIT, it sets a flag in the channel's metadata: `wait_mode = umwait_monitored`. When the consumer is descheduled (runnable but not running), the flag is `runnable_descheduled`. The producer's enqueue path examines the flag:

```paideia-as
fn enqueue(channel : SendCap ↓, msg : Msg ↓) -> Result !{ipc_send} =
  ...
  atomic_store_release(channel.head, h + 1)         // wakes UMWAIT consumer
  if channel.wait_mode == runnable_descheduled:
    send_ipi(channel.consumer_cpu_id)               // wake via IPI
```

The flag race (consumer transitioning between modes) is benign: a missed wake is recovered by the consumer's next operation.

### 10.3 IPI cost

A targeted IPI on modern x86_64 costs ~500–1000 cycles end-to-end (sender side: x2APIC ICR write; receiver side: IDT entry + scheduler check). The UMWAIT-monitored path is ~10× cheaper.

### 10.4 Software fallback

On pre-Tiger-Lake silicon without WAITPKG, the UMWAIT path is unavailable. All cross-core wakes use IPI. The IPC latency budget regresses by ~500 ns on this path.

---

## 11. Mitigation interaction (SCH-Q10)

### 11.1 The full mitigations baseline

On every context switch under default Q15 max-mitigations:
1. CR3 swap (KPTI): user → kernel page table set, then back at exit. ~150 cycles.
2. IBRS / eIBRS write (if not always-on per CPU). ~50 cycles.
3. STIBP propagation (sibling-thread protection).
4. IBPB on cross-AS switch (clear branch predictor). ~150 cycles.
5. L1D flush (vulnerable CPUs: Skylake-pre-microcode, etc.). ~50–200 cycles.
6. RSB stuffing (return-stack-buffer protection).
7. BHB clearing where applicable.

Total: 500–1000 cycles per cross-AS context switch.

### 11.2 Same-AS optimization

When the scheduler detects that the incoming SC's TCB belongs to the *same AS* as the outgoing TCB:
- KPTI CR3 swap is *not* performed (the address space is unchanged).
- IBPB is *not* performed (the branch predictor's state is shared within the AS by design).
- IBRS state is unchanged.
- L1D flush is unchanged (the cache state is no different within an AS).
- RSB and BHB clearing may be skipped (the call/ret history is intra-AS, no inversion).

Savings: ~300 cycles per same-AS switch.

The check is one register compare: `if outgoing.tcb.aspace == incoming.tcb.aspace then skip`. Per-CPU shadow state tracks the current AS.

### 11.3 `relax-mitigations` capability

A thread whose AS holds `relax-mitigations` per Q15 has its TCB tagged. Context switches into or out of this AS skip *all* mitigations:
- No KPTI (the AS uses a combined kernel-user page table per MEM-Q8).
- No IBRS/IBPB/L1D-flush.
- No RSB/BHB clearing.

Cost: ~30 cycles per switch (just the register save/restore). The audit log records every use.

### 11.4 Per-CPU mitigation state shadow

The scheduler maintains a per-CPU record:
- Last running TCB's AS.
- Current IBRS / STIBP state.
- L1D flush counter (when last flushed).

The shadow lets context switching decisions skip redundant operations.

### 11.5 Verification

The PBT property: every cross-AS switch performs the full mitigation sequence; every same-AS switch performs only the AS-invariant subset; every relax-mitigations switch performs only the minimal context save. Property-based testing per `02-development-environment.md` §9.4 verifies.

---

## 12. paideia-as implementation

### 12.1 Module layout

`src/kernel/sched/` is the scheduler:

```
src/kernel/sched/
├── sc.s                  # SC descriptor management
├── runqueue.s            # per-CPU priority heap; insertion/removal
├── dispatch.s            # main schedule loop; SC selection
├── refill.s              # SC budget refill; timer-wheel integration
├── steal.s               # work-stealing (NUMA-bounded)
├── reserved.s            # reserved_core_cap handling
├── hybrid.s              # P/E placement; CPUID 0x1F topology
├── donate.s              # SC donation across sync IPC
├── idle.s                # tiered idle (TPAUSE/UMWAIT/MWAIT/HLT)
├── preempt.s             # preemption discipline; yield points
├── wake.s                # cross-core wake (UMWAIT-monitored or IPI)
├── mitigations.s         # context-switch mitigation logic
└── effects.s             # Sched effect declarations + default handler
```

### 12.2 Phase-1 vs. phase-2 split

Phase 1 (NASM bootstrap):
- Fixed-priority preemptive policy.
- Per-CPU runqueues, no work stealing.
- No SC donation (sync IPC blocks producer at its own priority).
- HLT-only idle.
- Always-on mitigations (no same-AS optimization).
- No reserved-core capability (Q10 deferred to phase 2).
- No hybrid-core handling.

Phase 2 (paideia-as coexistence):
- Work stealing within NUMA.
- SC donation.
- Tiered idle (TPAUSE/UMWAIT/MWAIT/HLT).
- Same-AS mitigation optimization.
- Reserved-core capability comes online for the network stack.
- Hybrid-core placement.

Phase 3 (paideia-as canonical):
- D15 energy-aware scheduling integration.
- Future EDF/CBS hybrid policy (if needed for D3 hard-RT support).

### 12.3 Calling convention

Sched ops dispatch through R15's effect environment per Q-A3 / Q-A6. R12 carries the SC capability; R13 carries the operation-specific argument.

```
mov r12, sc_cap                    ; the SC to operate on
mov r13, new_priority              ; or budget, or whatever
mov rax, [r15 + sched_handler]     ; handler dispatch
call rax
```

---

## 13. Performance budget

| Operation | Budget | Substrate |
|---|---|---|
| Schedule decision (no preempt) | ≤ 50 ns | bare-metal Sapphire Rapids |
| Schedule decision (preempt, intra-AS) | ≤ 100 ns | bare-metal |
| Cross-AS context switch (full mitigations) | ≤ 1 µs | bare-metal |
| Cross-AS context switch (relax-mitigations) | ≤ 200 ns | bare-metal |
| Same-AS context switch (full mitigations baseline minus same-AS opts) | ≤ 500 ns | bare-metal |
| SC donation across sync RPC | ≤ 100 ns | bare-metal |
| Work-steal operation | ≤ 200 ns | bare-metal intra-NUMA |
| UMWAIT-monitored wake latency | ≤ 200 ns | bare-metal Tiger Lake+ |
| IPI wake latency | ≤ 1 µs | bare-metal |
| Reserved-core admission decision | ≤ 50 ns | bare-metal |

Aspirational; baselines come from `design/kernel/sched-perf-baselines.md` (future).

---

## 14. Verification

### 14.1 TLA+ spec

`design/kernel/scheduler.tla` (future) formalizes:
- SC budget consumption and refill.
- Donation chain correctness (LIFO unwind).
- Reserved-core exclusivity.
- Same-AS mitigation optimization soundness.
- Work-stealing wait-freedom.

Properties:
- **Schedulability.** For any admission-satisfying set of SCs, the highest-priority runnable SC with budget is selected at every decision.
- **Donation soundness.** SC donation chains unwind in LIFO order; no SC is left orphaned by a death.
- **Reserved-core exclusivity.** No SC other than the holder's runs on a reserved CPU while the cap is held.
- **Mitigation correctness.** Cross-AS switches always perform full mitigations; same-AS switches do not introduce cross-AS vulnerabilities.

### 14.2 PBT

The OCaml QuickCheck-style harness (per dev-env §9.4) exercises:
- Random SC creation, binding, scheduling, unbinding.
- Random sync-RPC patterns testing donation correctness.
- Random work-steal scenarios.
- Reserved-core acquire/release races.

### 14.3 Feature-masked CI lanes

Per dev-env §10.5:
- No-WAITPKG lane verifies the spin/HLT fallback path.
- No-hybrid lane verifies the all-CPUs-are-Any treatment.
- Single-NUMA lane verifies that work-stealing degenerates correctly to no-op.

### 14.4 Bare-metal stress

- Multi-CPU IPI storm.
- High-frequency context switching with mitigations on.
- Donation chains of depth ≥ 4.
- Reserved-core + general-pool interference patterns.

---

## 15. Open issues

| ID | Issue | Resolution location |
|---|---|---|
| SCH-O1 | TLA+ spec for the scheduler — phase-2 deliverable. | `design/kernel/scheduler.tla` (future) |
| SCH-O2 | Priority assignment convention (§3.6) — formalize the per-band guidelines as a documented project policy. | `design/system/priority-policy.md` (future) |
| SCH-O3 | Reservation policy at boot (§5.5) — concrete TOML schema and supervisor implementation. | `design/system/reservation-policy.toml` (future) |
| SCH-O4 | Work-stealing threshold tuning (§4.3) — when is the lowest-priority entry too low to steal? | `design/kernel/work-stealing.md` (future) |
| SCH-O5 | SC donation under failure — TCB walk in §7.3 is slow; investigate per-CPU donor-shadow for O(1) recovery. | `design/kernel/sc-donation.md` (future) |
| SCH-O6 | Hybrid-core placement under contention — what happens when all P-cores are full and an Any-class SC is waiting? Promote? Wait? | `design/kernel/hybrid-placement.md` (future) |
| SCH-O7 | Software-fallback idle on pre-WAITPKG — quantify the latency cost vs. tiered ideal. | `design/kernel/idle-perf.md` (future) |
| SCH-O8 | Same-AS mitigation optimization formal proof — needs verification that no Spectre variant requires IBPB within an AS. | `design/security/mitigation-analysis.md` (future) |
| SCH-O9 | Phase-1 fallback API — which subset is available pre-paideia-as. | `design/kernel/phase1-sched-api.md` (future) |
| SCH-O10 | Performance baselines — first bare-metal measurements drive `sched-perf-baselines.md`. | `design/kernel/sched-perf-baselines.md` (future) |
| SCH-O11 | Refill timer wheel resolution — TSC-deadline-based; bound on minimum period; interaction with TSC drift. | `design/kernel/timer-wheel.md` (future) |
| SCH-O12 | D3 hard-RT migration story — when to add EDF/CBS as a parallel policy. | revisit at phase 3 |
| SCH-O13 | D15 energy-aware scheduling integration — extension hooks defined but unused; phase-3 plumbing. | revisit at phase 3 |

---

## 16. References

### 16.1 Scheduling-context capabilities and seL4-MCS

- Lyons, A., McLeod, K., Almatary, H., Heiser, G. *Scheduling-Context Capabilities: A Principled, Light-Weight Operating-System Mechanism for Managing Time*. EuroSys 2018.
- Almatary, H., Lyons, A., Heiser, G. *Reasoning About Time in seL4*. (technical report).
- Klein, G. et al. *seL4: Formal Verification of an OS Kernel*. SOSP 2009.

### 16.2 Real-time scheduling theory

- Liu, C. L., Layland, J. W. *Scheduling Algorithms for Multiprogramming in a Hard Real-Time Environment*. JACM 20(1), 1973.
- Buttazzo, G. *Hard Real-Time Computing Systems*, 3rd ed. Springer, 2011.
- Abeni, L., Buttazzo, G. *Integrating Multimedia Applications in Hard Real-Time Systems*. RTSS 1998 (CBS).
- Davis, R. I., Burns, A. *A Survey of Hard Real-Time Scheduling for Multiprocessor Systems*. ACM Computing Surveys 43(4), 2011.

### 16.3 Multicore scheduling

- Lozi, J.-P., Lepers, B., Funston, J., Gaud, F., Quéma, V., Fedorova, A. *The Linux Scheduler: a Decade of Wasted Cores*. EuroSys 2016.
- Anderson, T. E., Bershad, B. N., Lazowska, E. D., Levy, H. M. *Scheduler Activations: Effective Kernel Support for the User-Level Management of Parallelism*. TOCS 10(1), 1992.
- Boyd-Wickizer, S. et al. *Corey: An Operating System for Many Cores*. OSDI 2008.

### 16.4 Hybrid-core / heterogeneous scheduling

- Intel Hybrid Core Architecture documentation (Alder Lake / Meteor Lake / Raptor Lake).
- Linux scheduler heterogeneous-CPU patches (informative).

### 16.5 Idle discipline and energy

- Intel WAITPKG instruction set extension documentation (TPAUSE, UMWAIT, UMONITOR).
- Intel ACPI Specification, C-states.

### 16.6 Mitigation interaction

- Lipp, M. et al. *Meltdown*. USENIX Security 2018.
- Kocher, P. et al. *Spectre Attacks: Exploiting Speculative Execution*. IEEE S&P 2019.
- Intel Spectre/Meltdown mitigation documentation.

### 16.7 Intel documentation

- Intel® 64 and IA-32 Architectures Software Developer's Manual, Vol. 3A ch. 6 (interrupts), ch. 8 (multi-processor), ch. 10 (APIC), Vol. 3B ch. 14 (power and thermal), Vol. 1 ch. 19 (WAITPKG).
- Intel® TSC-deadline timer documentation.

---

*End of document.*
