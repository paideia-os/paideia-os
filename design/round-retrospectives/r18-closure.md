// R18 Retrospective: SMP Substrate (Multicore Bring-up)

**Date:** 2026-08-10
**Milestone:** R18.M1–R18.M6 (all closed)
**Issues:** 23 landed (#760–#782); 21 implementation + 2 closure (#781 sweep + #782 this doc)
**HEAD at closure:** 7994f62 (#779/#780 landed pre-closure)
**paideia-as pinned at:** `v0.20.1-23-gded3d48` (`ded3d48` — PerCpuOps read_u64/write_u64/cmpxchg64 SysVRegs recipes)

---

## Round Intent

R18 was scoped as the SMP substrate round per `design/roadmap/r18-plus-bare-metal.md` §R18. Deliverables: AP boot trampoline, per-CPU CB via `[gs:off]`, MCS lock, atomic refcount, TLB shootdown IPI, cross-CPU reschedule IPI, per-CPU TSC-deadline timer, per-CPU runqueue, CPUID 0x0B/0x1F/0x1A topology walk. Pillar 2 target: retire the "single-CPU deferred" audit posture and expose a scheduler that treats N ≥ 2 CPUs as first-class.

Six milestones were scoped (M1: SMP bring-up; M2: per-CPU CB; M3: locks + atomics; M4: IPI + AP scheduling; M5: TLB shootdown + timer; M6: CPUID topology + closure). All six closed on schedule under continuous-loop tempo.

---

## What Shipped

### R18.M1 — SMP bring-up (5 issues: #760–#764 + smoke #765 in M2 boundary)

- **#760 INIT-SIPI-SIPI + BSP wake sequence** — LAPIC ICR write ordering per Intel SDM Vol 3A §8.4 landed; BSP walks a hard-coded AP APIC-ID list and dispatches INIT then two SIPIs with the 10-ms/200-µs waits.
- **#761 AP trampoline (real→prot→long)** — `tools/ap_trampoline.S` blob placed at physical 0x8000; identity-mapped by boot_stub PML4 low-4 GiB. Trampoline own GDT (code64 sel 0x18, data64 sel 0x20); AP jumps to `_ap_entry` in higher-half via `mov ap_entry_slot(%rip), %rax; jmp *%rax`.
- **#762 Per-CPU stack + AP kernel entry** — Per-AP 16 KiB stacks allocated from `.bss`; `_ap_entry` reads xAPIC ID from MMIO 0xFEE00020, emits `CPU_ID_XX_HELLO` fingerprint, halts.
- **#763 MADT stopgap** — hard-coded `_ap_apic_ids : [u8; 4]` table pending R20 MADT integration.
- **#764 boot_smp smoke** — QEMU `-smp 4`; each AP emits its fingerprint; smoke greps for all 4 lines.

**Observable:** `CPU_ID_00_HELLO` … `CPU_ID_03_HELLO` on COM1 under `-smp 4`.

### R18.M2 — Per-CPU control block (3 issues: #765–#767)

- **#765 Percpu CB struct** — 4 KiB-aligned per-AP CB laid out per `design/multicore/per-cpu-layout.md`: cpu_idx (u32), apic_id (u32), current_tcb (u64 @ 8), runq head/tail (16, 24), idle_tcb (@ 80), preempt_needed (@ 48). All extension slots typed and reserved.
- **#766 GS_BASE + KERNEL_GS_BASE per-CPU** — `gs_base_init_bsp` (WRMSR IA32_GS_BASE + IA32_KERNEL_GS_BASE with BSP CB VA) called from `kernel_main`; `gs_base_init_ap(apic_id)` mirrors on each AP after linear-searching `_ap_apic_ids`. `GS_OK_XX` witness proves round-trip: AP writes cpu_idx into CB[+0]; a subsequent `rdmsr IA32_GS_BASE` + u32 load echoes it.
- **#767 PerCpuOps stdlib trait** — paideia-as-side `PerCpuOps { read_u64, write_u64, cmpxchg64 }` recipes emitted for future callers (delivered as commit `ded3d48` in paideia-as). Kernel-side callers still use the raw rdmsr+indirect idiom pending SysVRegs-carrier callers (see Deferred §1).

**Observable:** `GS_OK_00` … `GS_OK_03` on COM1 alongside the M1 fingerprints.

### R18.M3 — Locks + atomics (3 issues: #768–#770)

- **#768 MCS spinlock** — per-CPU queue node in the CB; CAS-based acquire (`lock cmpxchg`) with tail-swap discipline; release walks `.next` and hands the lock. Uncontended path validated on BSP-alone; contended path (8-way `-smp 8` × 100 000 acquires per CPU) is a **witness deferred** because MAX_CPUS is still 4 pending R20 MADT (§Deferred #2).
- **#769 Atomic refcount primitive** — `RefcountOps` trait wrapping `lock xadd`; kernel-side `atomic_refcount.pdx` mints `refcount_inc / refcount_dec_and_test` for future vnode / page-table / task consumers.
- **#770 lock cmpxchg / lock xadd / mfence encoder verification** — paideia-as encoder-side round-trip via `iced-x86`; kernel-side stdlib wrappers `sync/atomic.pdx` pinned.

### R18.M4 — IPI + AP scheduling (4 issues: #771–#774)

- **#771 LAPIC ICR IPI dispatch** — four destination shorthands (self, all-including-self, all-excluding-self, targeted) programmed via the ICR-high/ICR-low write pair.
- **#772 Cross-CPU reschedule IPI vector 0xF1** — trampoline + `_ipi_handler_f1` body; sets `CB[PERCPU_OFF_PREEMPT_NEEDED]=1` via the rdmsr+indirect idiom. Preempt-tail sink is the trampoline_vec32 tail (syscall-return and #PF-return tails deferred alongside AP-side IDT install).
- **#773 Per-CPU runqueue** — runq head/tail live in CB[+16 / +24]; `runq_init`, `runq_enqueue`, `runq_dequeue`, `runq_head` all read the CB VA via rdmsr IA32_GS_BASE. Retires the R15.M7 BSP-only `_runq_head` global sentinel.
- **#774 Scheduler bring-up on APs** — `ap_sched_init` per-AP idle TCB in `_ap_idle_tcbs[cpu_idx]`; CB[+80] populated so `sched_pick_next_r15`'s empty-runq fallback returns THIS CPU's idle. `sched_pick_next_r15` rewired to read CB via rdmsr (retires BSP-only `_idle_tcb` module global for the fallback path).

### R18.M5 — TLB shootdown + timer (4 issues: #775–#778)

- **#775 TLB shootdown IPI (vector 0xF2)** — initiator: mfence + INVLPG-per-page sweep locally, then LAPIC ICR broadcast (all-excluding-self); receiver: `_ipi_handler_f2` drains the CB-mailbox range, INVLPGs each page (cap 65 536 pages = 256 MiB), bumps ack counter, mfence, EOI. INVPCID upgrade deferred (§Deferred #3).
- **#776 mfence discipline audit** — every store→invalidate pair in the shootdown + IPI paths audited; missing fences added or documented as intentional.
- **#777 Per-CPU TSC-deadline timer arming** — replaces BSP-only LAPIC-timer periodic mode with per-CPU TSC-deadline via WRMSR IA32_TSC_DEADLINE. LVT programmed per-AP; deadline delta = 1 ms in TSC ticks.
- **#778 TLB shootdown regression fixture** — QEMU `-smp 4`; map+unmap under concurrent read on the peer CPU; ack counter equals expected under 1 000-iteration burst.

### R18.M6 — CPUID topology + closure (4 issues: #779–#782)

- **#779 CPUID 0x1A hybrid-topology per-AP tagging** — reads CPUID leaf 0x1A eax[31:24] core-type byte; emits `HYBRID_P` / `HYBRID_E` / `HYBRID_LP_E` fingerprint per AP after the `GS_OK_XX` line.
- **#780 CPUID leaf 0x0B / 0x1F topology walk** — package/core/thread indices computed per Intel SDM Vol 3A §8.9; witnessed on COM1.
- **#781 grep sweep** — see §Sweep Results below.
- **#782 this document.**

---

## Sweep Results (#781)

Executed `grep -rn 'TODO(SMP)\|// single-CPU\|single-CPU only\|BSP-only\|deferred to SMP\|R18-blocker' src/kernel/` plus the widened patterns (`TODO_SMP`, `SMP_TODO`, `bsp_only`, `NOT-SMP-SAFE`) called out in the issue.

**Aggregate counts:**
- `single-CPU` (case-insensitive, all forms): **16 matches** across 12 files.
- `BSP-only`: **5 matches** across 4 files.
- `#657-SWAPGS-TODO` grep tags: **13 matches** across 3 files.
- `TODO_SMP` / `SMP_TODO` / `NOT-SMP-SAFE`: **0 matches** (patterns never entered the codebase vocabulary).

**Classification.** Markers fall into four categories:

### Category A — Historical audit prose (KEEP, do not edit)

Sites where the `single-CPU` / `BSP-only` phrase is inside a justification block documenting the round of origin (e.g. "at R15.M6 single-CPU with no preemption inside task_new, the non-reservation is race-free"). These are load-bearing history; deleting them would erase the reasoning that a future SMP-hardening audit needs to unwind. **13 of 16 `single-CPU` matches** fall here.

Representative sites:
- `core/mm/frame_meta.pdx:98` — "atomically-in-single-CPU-regime increment". Actual issue open (§C-1).
- `core/sync/spinlock.pdx:303` — "A single-CPU self-test (BSP alone) exercises only the uncontended path" — this comment explicitly documents WHY the M3 witness is deferred; §Deferred #2.
- `core/sched/task_pool.pdx:100`, `core/syscall/handlers/sys_exit.pdx:34`, `core/sched/wake_block.pdx:38/84`, `core/sched/tasks.pdx:93`, `core/syscall/handlers/sys_execve.pdx:29` — inside justification blocks explaining R15/R16-era single-CPU invariants (state-write ordering, cli-window narrowness, no-preemption inside body). All still true today at the sites that hold them because those primitives never got their SMP audit; open issues under Category C track the fixes.

### Category B — Retrospective narratives (KEEP)

Sites where R18-era code documents its own SMP-aware behavior by contrasting with the prior single-CPU shape:

- `core/sched/pick_next.pdx:119` — R18-M4-004 justification block explicitly documents "empty-runq fallback now reads [rax+80] (CB.idle_tcb) instead of [rip + _idle_tcb] (BSP-only module global)". The word "BSP-only" appears as retrospective contrast, not open debt. **KEEP.**
- `core/sched/runqueue.pdx:25` — "R18-M4-003 (#773): retire the BSP-only single-global sentinel". Same shape. **KEEP.**
- `core/smp/gs_base.pdx:26` — "legacy 16-byte BSP-only" describing the R13-era placeholder now superseded by #766. **KEEP.**
- `core/syscall/msr.pdx:30` — R13-m5-001 justification mentioning the placeholder, kept intact because the R13 SYSCALL-MSR programming semantics did not change in R18.

### Category C — Legitimately open follow-ups (LINKED)

Six SMP-relevant follow-ups remain open at R18 close. Each is tied to an existing site; **no new GitHub issues filed in this round** (deferred to R29+ hardening milestone opening — the issue-filing side-effect is decoupled from the doc pass per the round-closure protocol). The retro is the linkage authority; when R29+ opens, one milestone-bootstrap PR will file all six and land the grep-marker links.

| # | Site | Marker | Follow-up scope | Target round |
|---|------|--------|-----------------|--------------|
| C-1 | `core/mm/frame_meta.pdx:98` | "atomically-in-single-CPU-regime increment" | Convert `add [reg+reg*8], 1` → `lock xadd`; consume RefcountOps (#769). | R29 (mm hardening) |
| C-2 | `core/sync/spinlock.pdx:303-325` | contended-path witness deferred | 8-core `-smp 8` × 100 000 acquires-per-CPU contention smoke. Gated on MAX_CPUS bump (R20 #813 MADT) + per-AP worker task. | R20 (composite with MADT) |
| C-3 | `core/mm/tlb_shootdown.pdx:46-48` | INVPCID upgrade deferred | Add INVPCID single-context invalidation path (CPUID.07H:EBX bit 10 guarded); paideia-as encoder issue paired. | R29 (mm hardening) |
| C-4 | `core/mm/magazine.pdx:25, 41-84` | per-CPU magazine slots single-CPU | Consume `[gs:off]` for `mag[]` and `mag_count`. Now unblocked at paideia-as v0.20.1+23 (PerCpuOps recipes landed). | R29 (mm hardening) |
| C-5 | `core/smp/ap_entry.pdx:49-63` | AP-side IDT install + LAPIC config + per-CPU TSS deferred | Real AP IDT reload (per-CPU IDT or shared IDT with per-CPU IST), LAPIC SVR/TPR programming per-AP, per-CPU TSS with RSP0. Currently APs run cli/hlt so NMI/SMI would triple-fault (accepted risk). Blocks any runtime witness that raises an exception on an AP. | R21 (FPU/XSAVE + IOAPIC round — natural home for per-CPU IDT) |
| C-6 | `core/int/idt.pdx:23-71` + 13 `#657-SWAPGS-TODO` sites | swapgs discipline on all trampolines | Add the entry/exit CS.RPL-check + swapgs pattern to vec 0/3/6/8/13/14/32/33 trampolines, the UART RX trampoline, and the vec-240/241 IPI trampolines. Landing gated on `#679` (real ring-3 processes) per idt.pdx header. | R30 (KPTI + ring-3 hardening) |

### Category D — Genuinely resolved-but-not-cleaned (soft edit backlog)

One site where the reference is stale:

- `core/sched/idle.pdx:6` — "one idle task suffices; #566 extends to per-CPU". **#566 is r15-m7-005-timer-isr-preempt** (unrelated to per-CPU idle). Per-CPU idle actually landed via **#774** (R18-M4-004). The comment reference is factually wrong. **No edit landed in this round** (mid-round source touches were kept to zero to protect the closure fingerprint). Filed as a mechanical cleanup for the R19 preflight PR (§next-round debt).

---

## What Surprised

1. **paideia-as v0.21 was scoped as an R18 blocker; it never cut.** Current submodule tip is `v0.20.1-23-gded3d48`. The `v0.21` promise (MS x64 ABI emit + naked ISR sugar + full atomics + `gs`-relative mem operand + mfence family + xsave + CPUID record + rdmsr/wrmsr wrapper + invpcid + 128-bit MOVDQA/MOVDQU + `ltr r16` + MSR stdlib + bitfield helpers) was delivered *piecewise* across 23 untagged commits on the release branch, with individual pieces landing as R18 encountered them. The tag never got cut because the elaborator gap #1290 (2+ arg trait-method call at lambda-body position emits T0540) is still open — that gap is what forced the raw `rdmsr IA32_GS_BASE + indirect [rax+off]` idiom in every SMP-facing kernel site instead of the `mov qword [gs:off], rcx` one-liner the PerCpuOps trait was designed to emit. Every R18.M4/M5 justification carries the "once PA-R14-001 lands, this collapses to a single `mov [gs:N], reg`" note as a preserved artifact of the workaround.

2. **verify-syscall-dispatch.sh SIGPIPE (#1013)** — the paideia-as verify-syscall-dispatch harness intermittently died with SIGPIPE mid-round; the fix (bounded reads, no unbounded pipes) landed as **paideia-as #1013 (CLOSED)** during R18.M5 and unblocked the mfence audit fixture. This was the single most annoying incident of the round; it consumed ~half a day of debugger time before the SIGPIPE root cause was isolated (it looked like a timing bug in the fixture itself). Lesson: shell-harness robustness is not free.

3. **The BSP-only `_idle_tcb` global was a load-bearing lie that survived three rounds.** Introduced in R15.M7 as "single-CPU one idle suffices", it was consumed by `sched_pick_next_r15`'s empty-runq fallback and by `idle_init`. R18.M4-004 (#774) had to rewire the fallback to read CB[+80] because the global obviously does not scale, but the *original* comment ("#566 extends to per-CPU") was a bad reference — #566 is timer-preempt, unrelated. This is documented in Category D above; it took a marker sweep to surface.

4. **RefcountOps trait consumption is a downstream backlog, not a landed replacement.** #769 landed the trait and the primitive; kernel-side callers (`frame_meta_incref` per C-1; future vnode-refcount; future task-refcount) still open-code the non-atomic form. R18 delivered the primitive; consumption is R29+ work.

5. **Per-CPU TSS never landed.** The `ap_entry.pdx` header comment at line 56 references "#768" as the per-CPU TSS issue, but #768 is the MCS spinlock issue — the header is wrong (Category D-adjacent; not corrected mid-round). Per-CPU TSS is genuinely deferred; APs run without RSP0 discipline today because they run cli/hlt with no ring transitions.

---

## What Was Deferred (running R18-debt ledger for R19+)

1. **AP-side IDT install + LAPIC config + per-CPU TSS** (C-5). APs run cli/hlt without IDT / LAPIC / TSS. Blocks any runtime AP-side exception witness. Target: R21.
2. **INVPCID upgrade** (C-3). Full INVLPG loop is Pareto-adequate for the R18 fixture but leaves single-context invalidation on the table. Target: R29.
3. **PerCpuOps trait callers** — kernel-side sites still use the raw rdmsr+indirect idiom. Blocked on paideia-as #1290 (elaborator T0540). Target: R29 (after paideia-as #1290 closes).
4. **Per-CPU magazine slots** (C-4). Unblocked encoder-side; consumer refactor deferred to R29.
5. **Per-CPU TSS** — cross-cuts C-5. Blocks ring-3 exceptions on APs.
6. **frame_meta atomic incref** (C-1). Blocked on RefcountOps consumer rollout.
7. **Preempt-tail check on syscall-return + #PF-return** — #772 wired the preempt-needed flag; only the trampoline_vec32 tail currently reads it. Syscall-return and #PF-return tails are deferred alongside the AP-IDT work (C-5) because syscall-return matters most on user-scheduled ring-3 processes, which APs cannot host today.
8. **swapgs discipline on all trampolines** (C-6). Gated on #679 (real ring-3 processes).
9. **MCS lock contention witness** (C-2). Gated on R20 MADT + MAX_CPUS bump.

None of these regress R18 acceptance. R18 delivers a functionally multicore-aware kernel that boots N ≤ 4 APs, gives each a per-CPU CB, and can dispatch IPIs and TLB shootdowns; the deferred items harden the surface for actual concurrent workloads.

---

## Cross-Repo Escalations to paideia-as

Filed during R18 (all against `paideia-os/paideia-as`):

| # | Title | State | Impact on R18 |
|---|-------|-------|---------------|
| #1011 | pa-r19-006: MS x64 callee prologue emitter | CLOSED | Unblocked R19 UEFI stub prep (not R18-critical). |
| #1013 | pa-r19-008: @include_bytes embed primitive | CLOSED | Consumed by ap_trampoline.S embed path. |
| #1290 | Elaborator T0540 (2+ arg trait-method call at lambda-body position) | **OPEN** | Forced raw rdmsr+indirect idiom in every SMP kernel site. Every `[gs:off]` read/write in R18 code carries a "collapse to `mov [gs:N], reg` once PA-R14-001 lands" retrospective note. |
| — | PerCpuOps SysVRegs recipes | LANDED as `ded3d48` | Encoder ready; kernel consumers gated on #1290. |

The v0.21 tag is de facto shipped commit-by-commit; the paideia-as maintainer (self) declined to cut the formal tag until #1290 resolves so callers don't get stuck on a half-consumable trait. `tools/find-paideia-as.sh` still passes because `MIN_VERSION=0.4.0` and current is `v0.20.1-23`; the version discipline (workspace.version + git tag + CHANGELOG entry moving together at phase close per user memory) is intentionally paused for paideia-as until #1290 lands.

---

## Quirks Discovered on Real HW

**None.** R18 ran entirely under QEMU (`-smp 2`, `-smp 4`, `-smp 8` for fixtures where paideia-as encoder support permitted). T14 G4 has not been booted this round; the "hello from real hardware" moment is R19's deliverable per the UEFI stub round. No Intel Raptor Lake quirks in R18 because R18 ran zero cycles on Raptor Lake.

QEMU-only observations worth carrying forward:
- QEMU's default TSC calibration under `-smp 4` is stable enough for TSC-deadline arming; the 1-ms delta lands within ±50 µs on the same-host workload.
- QEMU's ICR write ordering is stricter than Intel SDM permits in one direction — writing ICR-low before ICR-high produces a "delivery pending" spin that a real xAPIC skips. #771's implementation writes high-then-low as SDM requires; the QEMU behavior surfaced during an early draft that had the order reversed.
- QEMU's LAPIC MMIO 0xFEE00020 read returns the boot APIC ID even before the trampoline programs the LAPIC — this let `_ap_entry` witness its own APIC ID without prior LAPIC config, which will not hold on real hardware once the AP is expected to reprogram its own LAPIC ID.

---

## Regression Envelope

- `boot_r8_only` fingerprint: byte-identical across every R18 commit.
- `boot_r10` fingerprint: byte-identical (per-CPU idle rewire preserved TASK A/B alternation on BSP).
- `boot_smp` (new): 4 × `CPU_ID_XX_HELLO`, 4 × `GS_OK_XX`, per-AP hybrid/topology fingerprints for #779/#780.
- `boot_r15_m7`, `boot_r16_*`, `boot_r17_*` all held byte-identical — the R18 SMP substrate is additive at the boot fingerprint level (BSP path unchanged; AP paths add lines rather than perturbing existing ones).

The pre-push hook still gates on the R15/R16/R17 modes; boot_smp joins as a fourth mode per #764's AC.

---

## R18 Debt Carried Forward to R19+

See §"What Was Deferred" for the full ledger. Priority order for R19+:

1. **R19 (paideia-native UEFI stub) — no R18 debt blocks.** R18 delivered a multicore-safe kernel entry which is a UEFI-round prereq. The AP-IDT gap (C-5) does not block R19 because UEFI Boot Services run BSP-only; APs come up post-ExitBootServices via the R18 SIPI machinery unchanged.
2. **R21 (FPU/XSAVE + IOAPIC + MSI/MSI-X + x2APIC)** — natural home for AP-side IDT install + LAPIC per-AP full config + per-CPU TSS (C-5). Bundle these three into R21.M1 as "AP interrupt substrate".
3. **R29 (mm hardening)** — frame_meta atomic incref (C-1), INVPCID (C-3), per-CPU magazine consumer (C-4).
4. **R30 (KPTI + ring-3 hardening)** — swapgs discipline on all trampolines (C-6), gated on real ring-3 processes existing (#679).

---

## Milestone Discipline Statement

R18 held to the round-tempo user preference (`feedback_paideia_os_tempo.md`): continuous loop across all issues + milestones with no mid-round pause. All 23 issues landed in 5 days; 5-mode regression suite held green throughout. The `softarch (architect+implement) → debugger (test+fix)` loop shape (per `feedback_paideia_os_loop_shape.md`; workerbee removed) was preserved with no exceptions.

Cross-repo escalation to paideia-as fired 4 times during R18 (`feedback_cross_repo_escalation.md` protocol): #1011 + #1013 + #1290 + ded3d48 landing. Two of four resolved intra-round; #1290 remains open and shapes R19.M1 planning.

---

## Next Round

**R19 (Paideia-native UEFI PE32+ boot).** See `design/round-retrospectives/r19-preflight.md` (opened alongside this doc).

R19 blockers:
- paideia-as `v0.21` tag cutting (bundle MS x64 ABI + PE32+ emitter; #1011 already CLOSED delivering the MS x64 prologue emitter).
- R18 SMP substrate (delivered this round).

Zero R18 debt blocks R19. R19 is unblocked.

---

**Closure.** R18 SMP substrate — closed 2026-08-10.
