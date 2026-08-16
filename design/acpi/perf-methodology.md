# PaideiaOS — AML Performance Methodology

**Status:** v1.0
**Date:** 2026-08-16
**Issue:** R30.M9-003 (#1087) — "AML performance budget (< 2 ms method round-trip on reserved LP-E core)"
**Code:** `tests/fuzz/aml/aml_fuzz.c` (`budget` mode), `tools/verify-aml-fuzz.sh`
**Supersedes:** the placeholder table in `design/acpi/perf-baselines.md` §1

---

## 1. The headline: the issue's budget cannot be measured yet, and this
## says so rather than approximating it

The issue asks for a **< 2 ms method round-trip on a reserved LP-E core**.
Neither half of that sentence is currently observable. This section
records why, with the evidence, because the failure mode being avoided is
specific: **a fabricated millisecond number is worse than an absent one,
because it will be believed.**

### 1.1 There is no clock in the bubble

The syscall surface is exactly fifteen handlers
(`src/kernel/core/syscall/handlers/`): `sys_open`, `sys_close`, `sys_read`,
`sys_write`, `sys_dup2`, `sys_execve`, `sys_exit`, `sys_fork`, `sys_wait`,
`sys_ipc_send`, `sys_ipc_recv`, `sys_ipc_reply`, `sys_svc_lookup`,
`sys_dmesg`, `sys_execve_shim`. **None reads a clock.**

This is not an oversight, and the AML subsystem already depends on it
being true. `design/acpi/global-lock.md` §8 states it outright:

> `AML_GLK_WAIT_MAX` is a bound on **work**, not on time. This process has
> no clock. That is a limitation, and it is named here rather than hidden
> behind a constant that looks like microseconds.

The same discipline governs the EC's IBF/OBF timeouts (#1081). Every
timeout in this subsystem is counted in iterations for exactly this
reason.

`rdtsc` exists as an instruction and is used **in the kernel**
(`pdxfs_lite/uuid.pdx`, `write.pdx`, `create.pdx`, `timer/lapic_isr.pdx`),
and the HPET *table* is parsed (`src/kernel/acpi/hpet.pdx`) — but the HPET
**counter is never read**, and nothing exposes any time source across the
syscall boundary to a userspace process.

### 1.2 There is no reserved LP-E core

The OS *knows about* LP-E cores: `src/kernel/core/smp/topology.pdx`
classifies each CPU's hybrid class at bring-up (`0x30` → LP-E → class 3),
storing it at `PERCPU_OFF_HYBRID_CLASS` (+120).

But nothing reserves one. There is **no affinity field in any scheduler
structure** — `grep -l affinity src/kernel/core/sched/` returns nothing.
The only `cpu_affinity_mask` in the tree belongs to `KIND_HW_INTERRUPT`
and routes *interrupts*, not threads. `process_set_affinity` is right #7
in `design/capabilities/rights-catalog.md` with **no implementation
behind it**.

### 1.3 And the harness runs on the build host anyway

The AML corpus and this budget rig are **host harnesses**: `paideia-as`
emits SysV ELF64 objects, which link against a native C driver so the same
machine code can be exercised where assertions are possible. A wall-clock
measurement taken there would measure *this build machine's scheduler, on
whatever core it happened to get*, for code that has never run on the
target. It would answer a question nobody asked.

**Conclusion.** The millisecond form of the budget is deferred to the
plumbing issue filed alongside this work. It is not approximated, not
estimated from a step count, and not recorded anywhere as if it had been
measured.

---

## 2. What is measured instead: a budget in work

The budget that *can* be gated honestly is expressed in **work**, and work
is the better unit here regardless:

| Metric | Source | Why it is the right unit |
|---|---|---|
| **fuel steps** | `aml_eval_budget() - aml_eval_fuel()` | the evaluator's own termination currency; one step per node, statement and loop iteration |
| **peak depth** | `aml_eval_depth_peak()` (#1085) | bounds native stack; the cap is 48 |
| **peak frames** | `aml_eval_frames_peak()` (#1085) | bounds method nesting; the pool is 8 |

These are **deterministic**: properties of the interpreter, not of the
machine under it. They do not vary with host load, thermal state, core
type or scheduler decisions. And they are the terms a regression actually
shows up in — an evaluator change that doubles the per-iteration cost of
`While` moves the fuel count immediately and unmistakably, whereas on a
noisy wall clock it would sit inside the variance for a long time.

Peak depth and peak frames had to be **added** for this to work; see
`design/acpi/fuzz-strategy.md` §3.1. Both counters unwind to zero on every
path, so a harness that reads them after the call reads 0 and learns
nothing. The peaks are written at the increment, after the cap test.

### 2.1 The recorded baseline

`tools/verify-aml-fuzz.sh` runs `aml_fuzz budget` on every push:

```
fixture          fuel    depth   frames   ceilings (fuel/depth/frames)
arith               4        3        1   16/8/2
loop              266        4        1   512/8/2
named               2        2        1   16/8/2
branch              8        4        1   32/8/2
package             6        3        1   32/8/2
recursive           8        8        8   64/16/8
nested              0        0        0   16/8/2
```

**`arith` is the simple-method baseline** — the closest thing this system
currently has to the issue's "method round-trip": `Method(MAR0,0) {
Return(Add(0x2A, 0x11, Zero)) }` costs **4 fuel steps at peak depth 3 in 1
frame**. That is the number this issue produces, and it is stated in the
unit it was actually measured in.

`loop` is a 32-iteration `While` at 266 steps, i.e. ~8 steps per
iteration. `recursive` is bound by the frame pool at exactly 8, which is
also the documented claim that self-recursion trips **frames before
depth** — now under test rather than asserted in a comment.

### 2.2 Two instruments, deliberately

There are two gates on cost, and the redundancy is intentional:

1. **`MANIFEST.tsv` pins every cost field exactly.** Any change to any
   corpus entry's cost fails replay. This is a *change detector*: maximally
   sensitive, and it fires on changes that are perfectly fine, which is
   why its failure mode is "explain and re-record".

2. **The ceiling table is a *budget*.** Each ceiling sits roughly a factor
   of two to four above its measurement — enough that a refactor shifting
   a constant passes, not enough that an algorithmic regression does.

A ceiling equal to the measurement would just be a second change
detector. Ten times the measurement would never fire. The gap between
those is where a budget lives.

### 2.3 The vacuity guard

A fixture that stopped being evaluated would post a cost of **zero** and
sail under every ceiling — a performance gate that passes because the work
disappeared. `cmd_budget` therefore requires forward progress: any fixture
expected to evaluate must spend non-zero fuel. (`nested` is exempt and
named as such: it declares Scopes and no method, so zero is its correct
cost.)

---

## 3. What this does not cover

Stated plainly, because a methodology document that only lists its
strengths is not one.

- **No wall-clock figure at all.** §1. The 2 ms target is untested.
- **No IPC cost.** A real "method round-trip" includes the request and
  reply across the bubble boundary. That path does not exist yet either;
  what is measured is evaluation only, from `aml_eval_method` to return.
- **No cache or memory-system effects.** Fuel counts work, not cycles. Two
  changes with identical fuel counts can differ substantially in real
  time, and this rig cannot tell them apart. That is the price of the unit,
  and it is the right trade while §1 holds.
- **No hardware measurement.** Deferred to the operator recipe in
  `tools/hw-smoke-r30.md`, which is unseeded until first light on a real
  T14 G4.

---

## 4. What would close the gap

Filed as its own issue (see the commit message for the number). Three
pieces, in dependency order:

1. **A monotonic time source across the syscall boundary.** Either a
   `sys_clock_read` handler returning a TSC sample, or — better for a
   process that must not be lied to by frequency scaling — an HPET counter
   read, whose base address the kernel already decodes into `hpet_info`.
   The TSC route needs invariant-TSC confirmed via CPUID leaf 0x80000007
   EDX[8] before it can be trusted across cores.

2. **Thread affinity, then core reservation.** An affinity mask on the
   TCB and a `pick_next` that honours it, before `reserved_core_cap` can
   mean anything. `topology.pdx` already supplies the LP-E classification
   the policy would select on.

3. **An on-target measurement mode** in the acpi_supervisor that samples
   the clock around `aml_eval_method` and reports through the audit
   channel, so the figure is taken on the machine the budget is about.

Only when all three land does "< 2 ms on a reserved LP-E core" become a
statement with a truth value. Until then, §2 is the budget, and it is
gated on every push.
