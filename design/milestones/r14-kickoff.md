# PaideiaOS R14 Kickoff: Ring-3 Reach + Four-Path Scope Decision

**Status:** DESIGN — pending path decision
**Date:** 2026-07-03
**Depends on:** R13 closure (`design/milestones/r13-closure.md`), R13 retrospective (`design/round-retrospectives/r13-shell-foundation.md`)

---

## Overview

R13 landed the substrate under the ring-0/ring-3 boundary — cap-dispatch surface (10 real + 2 structural kinds), SYSCALL/SYSRET fast path (5 MSRs + trampoline + 13-entry §C table), MMU-hardening perimeter (PML4[256] alias, KPTI stub, SMEP/SMAP/NX, real GDT, IST stacks, IDT rewire), and a §C-native user-space source tree at `src/user/` — but **did not reach ring-3**. R14's job is to close that boundary and execute the deferred Rev-2 milestones on top of it.

Four scope paths are available. **Path B is recommended as the R14 opener** (lowest lift, unblocks the largest downstream fan-out), with Path A or Path C selectable as the second track after B lands. Path D is the R14+1 close-out target.

**Common R14 pre-work (all paths):** the R13 carryover chain (see retrospective §"R14 Carryover"), specifically PA-R13-001 (`ltr r16` in paideia-as v0.12.0), `aspace_map` huge-page detection, cap_smoke migration (#482), user-linker discipline (`tools/build-user.sh`), and the §C amendment or user-space RX-ring decision for `sys_read`. These must be scheduled as R14.M1–M4 regardless of which scope path is selected for M5+.

---

## Path A: Multicore Bring-Up

**Headline:** Real multicore with per-CPU runqueues, cross-CPU IPI, GS-based thread-local storage, and TLB shootdown.

**Observable:** Boot output shows `CPU 0` / `CPU 1` tags on COM1, proving SIPI (Startup IPI) woke the AP and both CPUs run distinct tasks concurrently. Fingerprint anchor: alternation across CPU tags interleaved with the R11 preemptive `TASK A / TASK B` tags.

**Issues:** #471–#476 (deferred Rev-2 M13 bundle).

**Substrate blockers (HARD):**

1. **paideia-as PA-R13-012** (#925) — `xchg [mem], reg` / `lock cmpxchg` / `lock` prefix. Required for atomic counters (AP wake counter, per-CPU cap-table generation) and spinlocks (per-CPU runqueue lock, IPI-mailbox lock). No safe fallback under multicore; single-threaded serialization defeats the point of multicore.
2. **GS-relative memory addressing** (`gs:[base+disp]` with 65 segment prefix). Required for per-CPU state access (`_current_tcb`, per-CPU runqueue head). **Note discrepancy:** the softarch analysis of #428 called this "PA-R13-010 (GS-relative memory addressing) — DEFER to R13-m6 or R14", but the actual PA-R13-010 escalation was filed for `sub reg, imm` (see R13 closure §"Cross-Repo Work"). **GS-relative addressing needs a proper new escalation** — provisionally PA-R14-001 — before Path A can open. Kernel-side fallback (`rdmsr` GS_BASE and add to base register) works for cold paths but not for hot per-CPU dispatch.
3. **`mfence`** (`0F AE F0`). Required for TLB-shootdown ordering between IPI send and CR3-invalidate ack. Escalation status carried from R11 (PA-R11-004) — verify not yet landed in paideia-as v0.12.0 before opening M13-005.

**Estimated size:** 15–18 issues (M1–M6 in preflight §I).

**Risk:** High on substrate (three encoder items across two repos, one of which is not yet filed). Low on kernel logic — multicore is well-understood from seL4, Linux, xv6. The critical path is entirely gated by paideia-as v0.12.x / v0.13.x releases.

**Recommendation for Path A:** **Defer until Path B lands** — Path A cannot open before the GS-relative escalation is filed and cleared. Filing PA-R14-001 (GS-rel) should be R14.M1 side-work regardless of primary path, so that Path A is unblocked by the time R14 completes Path B or Path C.

---

## Path B: Higher-Half Kernel VA + KPTI (Phase 2 of #480)

**Headline:** Move the kernel `.text` / `.data` from the low-VA identity map (currently 0x0010_0000) to canonical higher-half at **0xFFFF_8000_0010_0000**, with far-jmp transition on boot and runtime CR3 switch for KPTI.

**Observable:** Same boot fingerprint byte-for-byte (kernel behavior unchanged), but a debug-inspection tag confirming `%rip` runs from the high VA post-transition. Optionally: `CR3 SWITCH KPTI` tag on the first ring-0/ring-3 boundary crossing.

**Issues:** #480 (m3-001 Phase 2 backtracking record).

**Scope:**

1. **Update `link.ld` KERNEL_VMA** from 0x0010_0000 to 0xFFFF_8000_0010_0000. Section addresses become canonical-high; `LMA` (load-memory-address) stays low so the boot stub can still write the kernel image where BIOS/GRUB places it.
2. **Update all boot-stub code + IDT trampolines** to use RIP-relative or absolute-64-bit addressing consistent with the high VA. Every `lea r, [rip + sym]` continues to work; every `mov r, imm32` referencing a kernel symbol needs to become `mov r, imm64` (paideia-as encoder support to be verified in preflight).
3. **Far-jmp transition on boot.** After PML4[256] alias is installed and CR3 loaded, execute `ljmp *high_kernel_entry` to switch `%cs:%rip` from low identity map to high canonical. From that point, the low identity map for kernel code can be retired (kept only for early boot and later user-page temporaries).
4. **Runtime CR3 switch for KPTI.** On ring-0 → ring-3 transition (in the SYSCALL trampoline's return path), load user-only CR3 (PML4 with user pages + minimal kernel trampoline mapped). On ring-3 → ring-0 (SYSCALL entry), load kernel CR3. This mirrors Linux's page-table isolation post-Meltdown.

**Substrate blockers:** None hard. Verify at preflight: paideia-as supports `mov r64, imm64` for kernel symbol loads; `ljmp *m64` (indirect far jump) for the transition. If either is missing, escalate before opening M1.

**Estimated size:** 6–9 issues (M1: preflight; M2: linker + LMA/VMA split; M3: boot-stub far-jmp; M4: SYSCALL trampoline CR3 switch; M5: KPTI CR3 install per aspace; M6: smoke + closure).

**Risk:** Low on substrate. Medium on kernel logic — the far-jmp transition is a one-shot that has to be byte-perfect (a bad far-jmp target triple-faults immediately), and the runtime CR3 switch has to preserve the trampoline mapping in both PGDs or the syscall path breaks. Both are mitigable by an extra audit pass and by explicit `qemu -d int` debugging.

**Recommendation for Path B: SELECTED as R14 opener.** Rationale:
   - Smallest lift of the four paths (6–9 issues vs. 10–20).
   - **Unblocks the `aspace_map` huge-page problem indirectly.** With the kernel executing from higher-half, the entire user aspace can safely populate the low half (below 0x0000_8000_0000_0000) without any risk of colliding with kernel pages. The boot-stub 1 GiB huge-page entries in PML4[0] can be retired after the far-jmp transition (kept only during early boot), removing the walker-collision failure mode for `aspace_map`.
   - Preserves fingerprint byte-identically — a substrate landing consistent with the R13 discipline.
   - Independent of both PA-R13-012 (Path A / C / D blocker) and the §C `sys_read` decision (Path C blocker), so it can open on the current paideia-as pin (v0.11.0+28) without waiting for a substrate bump.

---

## Path C: VFS + tmpfs + fork/exec/wait

**Headline:** Land the deferred Rev-2 M9 (VFS + tmpfs bundle #485) and M10 (fork/exec/wait bundle #486). File descriptors as caps; `tmpfs` in-memory node table; `fork` copy-on-write via new address-space + cap-table clone; `exec` ELF-lite load into current process; `wait` on KIND_REPLY.

**Observable:** From ring-3 shell: `$ echo hello > /tmp/x` then `$ cat /tmp/x` returns `hello`. Second observable: `$ fork; child echo A; parent echo B` interleaves on COM1.

**Issues:** #456–#465 (all currently deferred).

**Substrate blockers:**

1. **§C amendment for `sys_read`** (or user-space UART RX ring). The §C freeze intentionally omits `sys_read`; VFS without read is not a useful VFS. Decision required at R14 preflight: extend §C to §C' (add `sys_read`, `sys_open`, `sys_close`, `sys_stat`) or hand-roll read via user-space UART polling in the shim. Canonical answer is §C', but that is a preflight-scope amendment, not a mid-round change.
2. **`aspace_map` huge-page fix** — required for `fork` (copy-on-write requires per-page walker without collision) and `exec` (loader maps ELF-lite segments into fresh user aspace).
3. **cap_smoke migration** (#482) — required for `KIND_PROCESS OP_CREATE` to return a fresh pid without breaking R8 fingerprint.
4. **paideia-as PA-R13-012** (spinlocks) — soft blocker under single-CPU (`fork` is not concurrent yet) but hard blocker once multicore lands. Path C shipping under single-CPU is acceptable if Path A is deferred to R14+1.

**Estimated size:** 18–22 issues (VFS: 8–10; fork/exec/wait: 10–12).

**Risk:** Medium on substrate (§C amendment is a governance change, not a technical one). Medium on kernel logic — `fork` copy-on-write in a capability model has subtle semantics (do child caps share generation with parent? do child descriptors reference-count parent pages until first write?). Preflight will need a full data-flow diagram.

**Recommendation for Path C: R14 second track, after Path B.** Rationale: Path B unblocks the `aspace_map` huge-page fix by moving the kernel out of the low half, which is a prerequisite for both VFS mmap and fork COW. Once Path B closes, Path C opens with 3 of 4 blockers cleared (only PA-R13-012 remains, and that is soft under single-CPU).

---

## Path D: Multi-Process + Ring-3 Preemption

**Headline:** Multiple ring-3 processes running concurrently under preemptive scheduling, with cross-process IPC via KIND_IPC_PORT.

**Observable:** From ring-3: two shell processes both printing to COM1, alternating under R11 preemption, message-passing via cap-invoke on shared IPC ports.

**Issues:** #477 / #478 (Rev-2 M14).

**Substrate blockers:**

1. **Ring-3 execution** (Path C dependency chain: aspace_map huge-page fix + TSS + user-linker + cap_smoke migration + real `sys_read` decision). Path D cannot open before Path C ring-3 lands.
2. **Multicore** (Path A dependency chain: PA-R13-012 + GS-rel + mfence + SIPI + IPI). Path D is preemptive-across-CPUs, which requires the multicore substrate to be live.

**Estimated size:** 4–6 issues.

**Risk:** Low on substrate (all blockers are Path A + Path C prerequisites, resolved by the time Path D opens). Low on kernel logic (R11 preemption + Path A per-CPU runqueues already give the primitives).

**Recommendation for Path D: R14+1 close-out.** Sequential dependency on both Path A and Path C makes Path D the natural culminating milestone of an R14 that pursues Paths B → C → A → D, or the opening milestone of R15 if R14 ships only B + C.

---

## Recommended R14 Sequencing

**Selected opener: Path B (higher-half kernel + KPTI).**

**Baseline plan:**

```
R14.M1  — Preflight audit (§C amendment decision, PA-R14-001 GS-rel escalation filing, encoder verification for imm64/ljmp).
R14.M2  — R13 carryover: aspace_map huge-page detection; cap_smoke migration (#482); tools/build-user.sh discipline.
R14.M3  — Path B: linker + LMA/VMA split (#480).
R14.M4  — Path B: boot-stub far-jmp transition.
R14.M5  — Path B: SYSCALL trampoline CR3 switch + KPTI CR3 install.
R14.M6  — Path B: smoke fixture + closure.
R14.M7+ — Path C opens (VFS + fork/exec/wait), Path A opens in parallel once PA-R14-001 clears.
R14.M15 — Path D (multi-process + ring-3 preemption) IF both A and C close in-round; otherwise R15 opener.
```

**Alternate plan (if PA-R13-001 / v0.12.0 slips):** Path B does not depend on paideia-as v0.12.0 and can open on the current pin (v0.11.0+28). Path C's TSS dependency (#424) still requires v0.12.0, so Path C opens later even under this alternate. Path A cannot open until PA-R14-001 + PA-R13-012 both land — likely v0.13.0.

---

## Round-Close Ceremony (R13)

**Executed as part of #443 (this issue):**

1. **Pre-push against `main`** — 5 modes green (`boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`, `boot_r12_denial`), 3 reps each = 15/15 PASS. **Already validated per commit 2c27d90** (R13 closure landing).
2. **Submodule pin verification** — `tools/paideia-as` currently at **ae6039b (v0.11.0-28)**. **Not yet at v0.12.0** — PA-R13-001 (`ltr r16` encoder) has not landed; the v0.12.0 tag is pending. R14.M1 opens on this pin and bumps to v0.12.0 as its first substrate action (see paideia-as milestone plan for v0.12.0 scope: PA-R13-001 + PA-R13-010 + PA-R13-011 + PA-R13-012 bundled).
3. **Tag merge commit `r13-closed`** on the current HEAD (after #443 lands) — marks the R13 substrate as the frozen ring-3-substrate reference for R14 execution.

---

## Deferred to R14+ (Not in Scope for R14 Opening)

Preserved from R13 kickoff carryover; still applicable:

- **Curried-call wrapper support** — `cap_invoke(slot)(op_arg)` surface syntax.
- **Per-cap IPC channel addressing** — descriptor.target_ptr encodes channel indices.
- **Generation-based revocation validation** — check `descriptor.generation` in dispatch.
- **Sealed capabilities** — sealed flag + sealing-key check.
- **Kind-specific rights lattice** — high 32 bits per kind.
- **Audit-log integration** — persistent runtime log, not just COM1 tags.
- **Multimode device support** — multiple BAR mappings per KIND_DEVICE.
- **Handler-table migration (A2 dispatch style)** — from linear cmp/je chain to indirect through 16-entry table. Deferred to R15+ once kind count and handler-hot-path profile stabilise (R12 boundary #7, restated in R13 closure §"Design Decisions Pinned").

---

## Pillar Alignment

**Path B (Higher-half + KPTI):**
- Pillar 3 (Strict microkernel) — canonical higher-half VA layout is a prerequisite for cap-mediated user memory management.
- Pillar 5 (Memory safety) — KPTI runtime CR3 switch closes the Meltdown-class side channel.

**Path A (Multicore):**
- Pillar 1 (Cooperative scheduling → preemptive + multicore).
- Pillar 3 (Strict microkernel) — per-CPU capability enforcement via cross-CPU IPI.
- Pillar 10 (Functional discipline) — per-CPU GS-based data as function parameters (implicit via `%gs`).

**Path C (VFS + fork/exec/wait):**
- Pillar 3 (Strict microkernel) — file descriptors as capabilities; VFS entirely user-space above cap layer.
- Pillar 5 (Memory safety) — `fork` copy-on-write under strict cap semantics.

**Path D (Multi-process preemption):**
- Pillar 1 (Preemptive scheduling across processes and CPUs).
- Pillar 3 (Cap-mediated IPC between mutually-distrusting user processes).

---

**Status:** Awaiting R14 kickoff decision confirmation on Path B as opener.
**Author:** Santiago Nunez-Corrales
**Date:** 2026-07-03
