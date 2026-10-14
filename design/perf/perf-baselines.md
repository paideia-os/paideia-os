# Performance baselines

**Status:** R141.M5 landed (Wave UMB-W24, paideia-os #2649). Scope: an
operator-facing reference for what "normal" looks like on each of the
microbench harness's 16 measurement site slots, how to collect fresh
numbers against a current build, and the handshake with the R141.M6
regression gate that will consume this file as its oracle.

**Umbrella.** R141 is the kernel-space performance-measurement umbrella.
M1 (`#2645`) landed the microbench RDTSC harness. M2 (`#2646`) landed
the perf-sink klog dumper. M3 (`#2647`) landed the fuzz entry shims. M4
(`#2648`) landed the capability-flow adversary. **M5 (this document)**
is the operator-facing baseline reference. M6 (forward) will add an
automated smoke-mode regression gate that compares a boot's observed
numbers against the shapes recorded here.

**Companion files.** This document reads as a layered extension of the
four R141 design docs it rests on:

| doc                                                         | provides                        |
|-------------------------------------------------------------|---------------------------------|
| `design/perf/microbench-harness.md`                         | ABI of the 16-site row + ring   |
| `design/perf/perf-sink-logging.md`                          | `PERF SITE` klog line format    |
| `design/perf/fuzz-entry-points.md`                          | `fuzz_*` site semantics         |
| `design/perf/capability-flow-adversarial.md`                | adversary interaction with M1-3 |

---

## 1  Purpose

A number without a shape is not a baseline — it is a point. An
operator reading `PERF SITE name=0x<hash> count=1024 min=2871
max=48221 mean=4312` from the serial console has no way to tell
whether the dispatch cost regressed, whether the sample contains a
TLB miss outlier that moved the max up by two orders of magnitude, or
whether the mean drifted because a probe effect added two memory
stores to the hot path. This document gives each landed site:

1. A **nominal cycle shape** — the expected cold-cache magnitude, the
   expected warm-cache magnitude, and the per-call variance budget.
2. A **triggering workload** — the kernel-side activity that must run
   to populate the site before the dump is meaningful.
3. A **variance tolerance** — the window a healthy boot stays inside,
   expressed as a multiplier over the cold and warm numbers.

The three together are what R141.M6's smoke mode will test, and what
an operator uses to decide whether a surprising dump is a *finding*
or a *known in-band fluctuation*.

### 1.1  Non-goals

* **Not a benchmark table for silicon comparison.** The numbers in
  §4 are shapes, not points: nobody should compare a laptop-class
  Alder Lake-U to a desktop-class Raptor Lake using this file. The
  per-site variance budget deliberately swamps CPU-model variation so
  the gate stays single-threshold across every supported platform
  (§7).
* **Not a performance SLO.** A failing M6 gate flags a *change in
  shape*, not a *violation of a committed response time*. Hard SLOs
  on dispatch cost belong in a later ring-3 reliability layer that
  does not yet exist.
* **Not a trace format.** Each entry here is a running
  min/max/mean/count across a sample window. The ring buffer that
  holds the last 128 per-site deltas is a separate export surface
  (`MB_OP_READ_RING`, forward R141.M*) and has its own interpretation
  rules.

## 2  Measured surfaces

The microbench harness (R141.M1) exposes 16 fixed site slots. Each
slot is a 48-byte row at `_mb_sites[site_id * 48]` and a 1024-byte
ring at `_mb_rings[site_id * 128]`. A slot is **registered** when
`_mb_site_register(name_ptr, name_len)` has returned its row index
during boot; a registered slot is **populated** once at least one
`_mb_sample_end` has landed a delta into it.

At the R141.M5 landing the registry occupancy is:

| slot | name            | source wave     | registered by          | kernel caller                                    |
|------|-----------------|-----------------|------------------------|--------------------------------------------------|
| 0    | `cap_invoke`    | Wave 89 / M1    | `_mb_init`             | `cap/invoke.pdx::cap_invoke` dispatch bracket    |
| 1    | `fuzz_cmd_reg`  | R141.M3         | `_fz_init`             | `_fuzz_cmd_registry` shim (`fuzz_entries.pdx`)   |
| 2    | `fuzz_wit_br`   | R141.M3         | `_fz_init`             | `_fuzz_wit_bridge` shim (`fuzz_entries.pdx`)     |
| 3    | `fuzz_stdout`   | R141.M3         | `_fz_init`             | `_fuzz_stdout_records` shim (`fuzz_entries.pdx`) |
| 4-15 | *(unassigned)*  | —               | —                      | —                                                |

Twelve slots remain free. The chain documented in
`microbench-harness.md` reserves M2/M3/M4 slots for `ctx_switch`,
`vfs_fast_path`, and `klog_slow_path`; those are expected to land in
slots 4/5/6 in the order their chains land. §6 covers the procedure
for a new wave registering a new site.

### 2.1  Row and ring geometry

The ABI the baseline shape rests on, abbreviated from
`microbench-harness.md §3.1`:

```
site row (48 B)                   per-site ring (1024 B = 128 u64)
+0  u32 site_id   u32 head_idx    ring[0..127]  u64 cycle_delta
+8  u64 name_hash                 head wraps mod 128 after every
+16 u64 sample_count              _mb_sample_end
+24 u64 min_cycles
+32 u64 max_cycles
+40 u64 sum_cycles                mean = sum/count (count==0 -> 0)
```

A dumped `PERF SITE` line (`perf-sink-logging.md §3.2`) covers
`name_hash`, `sample_count`, `min_cycles`, `max_cycles`, and the
derived `mean = sum/count`. Baselines in §4 are expressed in the same
four axes.

## 3  Baseline measurement protocol

An operator reproducing a baseline follows the five steps below. The
procedure is deterministic given the same QEMU + kernel pair; the
cycle numbers themselves are not deterministic (TSC walks under TCG
in jumps, not clocks), but their shape — magnitude band, cold-vs-warm
ratio, outlier frequency — is stable to within the variance budgets
of §4.

### 3.1  Boot the kernel

Use the project standing pair documented in
`feedback_paideia_os_test_defaults`:

```
bash tools/build.sh
bash tools/run-qemu.sh
```

`build.sh` assembles the kernel with the current `src/kernel/` tree
and the current `paideia-as` submodule. `run-qemu.sh` boots the
image under QEMU-TCG with the serial console wired to stdout. The
klog ring is written to that console per `kernel-logging-substrate.md`,
and every microbench site dumped by `_perf_sink_dump_*` becomes a
grep-able line of the form:

```
[  <sec>.<usec>] INFO cpu0 time: PERF SITE name=0x<16-hex>
  count=<N> min=<N> max=<N> mean=<N>
```

### 3.2  Trigger measurement activity

A newly-booted kernel has written zero samples into every site. To
populate a baseline the matching workload must be exercised:

| site           | triggering workload                                                                      |
|----------------|------------------------------------------------------------------------------------------|
| `cap_invoke`   | Any ring-3 or kernel-mode cap invocation. Boot already runs several hundred invocations through the KIND_* dispatch arms; a plain boot is enough. |
| `fuzz_cmd_reg` | A `_fuzz_cmd_registry(bytes_ptr, len)` call, or a `_fuzz_run_corpus(FZ_ENTRY_CMD_REG, …)` over a prepared corpus. No automatic boot hook. |
| `fuzz_wit_br`  | A `_fuzz_wit_bridge(bytes_ptr, len)` call, or `_fuzz_run_corpus(FZ_ENTRY_WIT_BR, …)`. No automatic boot hook. |
| `fuzz_stdout`  | A `_fuzz_stdout_records(pid, bytes_ptr, len)` call, or `_fuzz_run_corpus(FZ_ENTRY_STDOUT, …)` with `_fz_corpus_stdout_pid` stashed. No automatic boot hook. |

An operator reaching the three fuzz sites during a baseline run
drives them via a kernel-mode call site (today, a one-shot stub in
`kernel_main.pdx`; later, through the forward KIND_FUZZ cap handler).
A standing corpus of ~1024 cases per entry is enough to populate the
ring and let the min/max/mean settle inside the variance budgets of
§4; smaller corpora still land valid data but widen the variance
because the max is pulled by rare outliers (TLB miss on first page
touch, APIC-timer window, …).

### 3.3  Dump the sites

Call `_perf_sink_dump_all()` from kernel mode (today: an explicit
one-shot in `kernel_main.pdx` after the triggering activity; forward:
a KIND_MICROBENCH `MB_OP_DUMP_ALL` under `R_MB_READ`). The sink emits
one `PERF SITE` line per registered site plus a final `PERF SINK DUMP
OK sites=0x<N>` summary.

For a single site, call `_perf_sink_dump_site(site_id)` directly.

### 3.4  Capture the klog output

The serial console under `run-qemu.sh` writes to stdout; redirect to
a file for later diffing:

```
bash tools/run-qemu.sh 2>&1 | tee /tmp/boot-$(date +%s).log
```

Beware the pipe-swallows-exit-code trap recorded in
`feedback_pipe_swallows_exit`: for a numeric exit check use the
no-pipe form (`run-qemu.sh > log; echo $?`); for a klog capture the
`tee` form is fine because the exit code is advisory, not gating.

### 3.5  Extract the per-site numbers

```
grep "PERF SITE" /tmp/boot-<ts>.log
```

Each line is self-contained. Compare the four axes (`count`, `min`,
`max`, `mean`) against §4 for each site. A single boot's output is
one data point; a baseline is the shape across three to five boots
with the same build, so an operator capturing a new baseline runs the
sequence three times and records the median of each axis.

## 4  Known baselines

**At the R141.M5 landing (this document's birth) only slot 0
(`cap_invoke`) carries a nontrivial boot-time sample count.** The
three fuzz sites were landed with no automatic boot hook (see
`fuzz-entry-points.md §9`), so a fresh boot of the current kernel
emits `PERF SITE` lines for them with `count=0` and derived
`mean=0`. The entries below record the **expected shape once the
site is driven**, with the operator responsible for driving the
workload in §3.2 before comparing.

### 4.1  `cap_invoke` (slot 0)

**Shape (QEMU-TCG, cold):**

| axis    | nominal     | variance budget     |
|---------|-------------|---------------------|
| `min`   | ~2 000      | ×0.5–×1 (cold floor is the fast path landing from a cold BTB) |
| `mean`  | ~3 500      | ×0.7–×1.3           |
| `max`   | ~5 000      | ×1–×3 (first miss) |
| `count` | 100+        | boot grows this monotonically |

**Shape (QEMU-TCG, warm, after 1 000+ invocations):**

| axis    | nominal     | variance budget     |
|---------|-------------|---------------------|
| `min`   | ~1 500      | ×0.7–×1.3           |
| `mean`  | ~2 500      | ×0.8–×1.2           |
| `max`   | ~4 000      | ×1–×2               |
| `count` | 1 000+      | fuzz corpora and smoke tests push this to 10⁴+ |

**Interpretation.** The dispatch cost `cap_invoke` measures is the
cycle delta between the `_mb_sample_begin` immediately before the
dispatch cascade (`cmp rcx, KIND_*; je kind_*_arm; ...`) and the
`_mb_sample_end` immediately after the arm returns. Across Waves
59..88 the dispatch cascade grew from four `cmp rcx, imm` arms to
~90 arms. The nominal shape is for the median arm; the max is
dominated by first-use arms that pay a cold-cache tax. A `mean >
5 000` on warm cache is a regression signal — the usual causes are a
new `klog_s1` landed inside the dispatch window, or a new per-arm
cap-check that was not there in the previous build.

### 4.2  `fuzz_cmd_reg` (slot 1)

**Shape (populated by `_fuzz_run_corpus(FZ_ENTRY_CMD_REG, corpus, len)`):**

| axis    | nominal        | variance budget     |
|---------|----------------|---------------------|
| `min`   | ~800           | small case (<16 B)  |
| `mean`  | ~5 000         | ×0.7–×1.3           |
| `max`   | ~50 000        | one TOML section + comments |
| `count` | corpus length  | one sample per `\n`-delimited case |

**Interpretation.** The TOML-subset parser's cost is linear in the
case length with a strong per-section coefficient. A median case
(one `[section.key]` + two `key=value` lines) lands near 5 000
cycles; a long inline-comment-heavy case pushes the max up by an
order of magnitude. The variance budget is deliberately wide
because the corpus content drives the distribution.

### 4.3  `fuzz_wit_br` (slot 2)

**Shape (populated by `_fuzz_run_corpus(FZ_ENTRY_WIT_BR, corpus, len)`):**

| axis    | nominal        | variance budget     |
|---------|----------------|---------------------|
| `min`   | ~500           | parser-reject in prefix |
| `mean`  | ~8 000         | ×0.7–×1.3           |
| `max`   | ~100 000       | full 32-field record |
| `count` | corpus length  | one sample per case |

**Interpretation.** The WIT record parser is a 32-field state
machine. Cases that reject in the prefix (bad `record` keyword,
missing `{`) land at the floor; cases that walk the full 32 fields
with 30-byte names pay the full tax. The max is wider than
`fuzz_cmd_reg` because the per-field cost accumulates linearly over
32 fields rather than linearly over a short line.

### 4.4  `fuzz_stdout` (slot 3)

**Shape (populated by `_fuzz_run_corpus(FZ_ENTRY_STDOUT, corpus, len)`):**

| axis    | nominal        | variance budget     |
|---------|----------------|---------------------|
| `min`   | ~300           | empty case / bad PID |
| `mean`  | ~2 500         | ×0.7–×1.3           |
| `max`   | ~20 000        | full typed-record decode |
| `count` | corpus length  | one sample per case |

**Interpretation.** The typed-records parser dispatches on a 1-byte
tag then walks a schema-prescribed field vector. Bad-PID and
empty-case paths bail early (near the floor); the max is set by
long schema vectors with wide string fields.

### 4.5  Interpretation summary

Across the four live sites the magnitudes land in three bands:

* **Fast-path dispatch (`cap_invoke`):** 10³ cycles. Any single sample
  outside the warm 10³–10⁴ band is suspect; a mean move of >30% is
  a regression signal.
* **Short-case parse (`fuzz_cmd_reg`, `fuzz_stdout`):** 10³–10⁴
  cycles. The variance band is wide; use `min` as the stability
  anchor and `mean` as the drift signal.
* **Full-schema parse (`fuzz_wit_br`):** 10³–10⁵ cycles. Max is
  expected to span two orders of magnitude; the useful regression
  signal is `mean`, not `max`.

## 5  Regression gates (R141.M6 forward)

R141.M6 (future, not landed at the time of this document) will add a
**smoke mode** to the microbench harness that:

1. Runs the kernel to a known populated state (boot + a scripted
   workload that drives every registered site).
2. Reads `_mb_site_stats` for each site via `KIND_MICROBENCH
   MB_OP_READ_STATS`.
3. Compares each axis (`min`, `max`, `mean`) against the shape
   recorded in §4 of **this file**.
4. Reports a `PERF GATE PASS` or `PERF GATE FAIL name=<N> axis=<a>
   observed=<N> expected=<N>` fingerprint per site.

**Variance tolerance.** The smoke-mode gate uses:

```
cold-cache tolerance   = ×2.0  (observed  may be up to 2× nominal)
warm-cache tolerance   = ×1.3  (observed  may be up to 1.3× nominal)
```

Both tolerances are deliberately generous relative to the per-site
budgets in §4 — the gate's job is to catch **shape** changes (e.g.
dispatch cost tripled), not **jitter** (±30% is noise on QEMU-TCG and
is well inside the warm tolerance). An observed value **below** the
nominal is never a gate failure; a kernel that got faster is a
successful build.

**Which axis gates on which tolerance.**

| axis   | tolerance | rationale                                       |
|--------|-----------|-------------------------------------------------|
| `min`  | warm      | min stabilises after a few hundred samples     |
| `mean` | warm      | mean is the primary drift signal                |
| `max`  | cold      | max is set by rare outliers (TLB, APIC window) |
| `count`| —         | gates only on >0 (the site was actually driven)|

**How the gate reads this file.** R141.M6's gate implementation will
embed a small kernel-side table of the §4 shapes (one row per site,
with the four axes and their variance budgets). This document
remains the AUTHORITY — a change to §4 lands with a corresponding
change to the gate's embedded table, and the two must stay in sync
or the gate drifts away from what the operator reads.

**Why not a floating oracle.** An operator-facing baseline is more
useful than an auto-tuning gate because:

* A new build that drifts the mean up by 20% is a regression; an
  auto-tuning oracle would ratchet the baseline up and hide the
  regression on the next run.
* A build that drifts the mean down by 20% is a successful
  improvement; the operator reading §4 sees the delta and can
  update the baseline deliberately.
* A fixed oracle, versioned in the repo, is diffable: `git log
  design/perf/perf-baselines.md` tells an operator exactly when the
  shape of each site changed and which wave moved it (§8).

## 6  How to add a new baseline

A wave registering a new microbench site (via `_mb_site_register`
during its boot hook) and inserting the matching `_mb_sample_begin
/ _mb_sample_end` bracket at the measured hot path must also land a
new §4.X block in this file. The procedure:

1. **Pick a slot.** Allocation is sequential (`_mb_site_register`
   returns `_mb_site_count_var` and bumps it). The next free slot
   at the time of this document is **slot 4**; a wave adding
   `ctx_switch` as its first R141.M* follow-up gets slot 4.
2. **Register.** In the subsystem's init path add a `_mb_site_
   register(&name_bytes, name_len)` call and stash the returned
   `site_id` in a module-local BSS global (shape: see
   `fuzz_entries.pdx::_fz_init`).
3. **Bracket.** Open with `_mb_sample_begin(site_id) -> start_tsc`
   immediately before the hot-path body; close with
   `_mb_sample_end(site_id, start_tsc)` immediately after. The
   bracket's overhead is bounded (§3 of
   `microbench-harness.md`); callers in the fast path should
   confirm the bracket does not itself move the measurement into a
   different magnitude band.
4. **Drive.** Add a kernel-mode caller or document the external
   workload that populates the site during a baseline run.
   Without a driver the site stays at `count=0` and the regression
   gate has nothing to gate on.
5. **Shape.** Boot the kernel three times, drive the workload, dump
   `_perf_sink_dump_all`, and record the median of each axis in a
   new §4.X block in **this file**. Follow the three-table shape of
   the existing §4.1–§4.4 entries (cold shape, warm shape,
   interpretation).
6. **Update the registry table in §2.** Add the new slot's row.
7. **Add a §8 entry.** Record the date, the wave number, the issue
   number, and a one-line description of what moved.

### 6.1  Audit a site before documenting it

Before adding a §4 entry, confirm the site is actually populated
and the raw numbers are not degenerate:

```
grep "PERF SITE" /tmp/boot-*.log | grep "name=0x<hash-of-new-site>"
```

Look for:

* `count` > 0 (the bracket was reached);
* `min` > 0 (the measurement is not a `rdtsc` degeneracy);
* `max` within 100× `min` (an outlier beyond that is a sign the
  bracket is catching something non-local — a klog_slow_path reached
  from inside the measurement window, a nested cap_invoke, …).

A site that fails any of these checks is not ready for a baseline;
tighten the bracket first.

## 7  Platform assumptions

The nominal numbers in §4 are shapes for a **QEMU-TCG** boot. Real
silicon numbers will differ, and the differences matter:

**Reference platform (as of R141.M5):**

* **CPU:** 12th-gen Intel Core (Alder Lake-U family), running at ~3
  GHz nominal, ~4 GHz turbo.
* **Build host:** Linux x86_64, QEMU-TCG with the `qemu-system-
  x86_64` default machine (`q35`), 1 vCPU, 512 MiB RAM.
* **Clock discipline:** `rdtsc` under TCG is not a cycle counter
  — it's a monotonic that increments by TCG's internal
  instruction-count heuristic. Numbers are **ordered correctly** but
  are **not comparable** to real-silicon cycle counts without a
  scaling constant.
* **Scaling note.** QEMU-TCG cycles land at roughly **5–10×** real
  Alder Lake-U cycles for the same code path. The §4 shapes are
  the TCG numbers; a real-silicon run of the same workload should
  land in the same magnitude band but with a lower median.

**Real-silicon posture.** Once the kernel boots on bare metal (a
future wave past Phase 2) the §4 shapes will be re-captured there and
this file will gain a §4.X-silicon companion block per site, with
R141.M6's gate selecting the right block based on a boot-time
`CPUID`-derived platform tag. Until then every entry in §4 is
TCG-flavoured and should be read as a shape, not a point.

**Why gate on TCG at all.** The gate is a *change detector*, not a
*performance claim*. A gate that catches "the dispatch cost tripled
on TCG" catches the same regression on silicon, because the ratio
survives the scaling. The gate's job is to notice that a wave moved
the shape — the silicon numbers follow once the kernel runs there.

## 8  Historical trajectory

A chronological log of shape-moving events in §4. Each entry names
the date, the wave, the issue, and a one-line description. Operators
updating a baseline add an entry below the latest one; the file is
diffable and `git log design/perf/perf-baselines.md` tells the
longer story.

| date       | wave       | issue   | event                                             |
|------------|------------|---------|---------------------------------------------------|
| 2026-10-14 | UMB-W24    | #2649   | Initial document. Four site slots occupied (`cap_invoke`, `fuzz_cmd_reg`, `fuzz_wit_br`, `fuzz_stdout`). §4 shapes are TCG-flavoured and are expected rather than captured for the three fuzz sites (no boot hook yet). `cap_invoke` warm shape is captured from Wave 89 instrumentation. |

<!-- Future entries land one row per shape-moving event. Example:
| 2026-11-02 | R141.M6/M? | #<N>    | ctx_switch landed at slot 4 (cold ~1 200 c, warm ~800 c, mean move signal: ±25%). |
| 2026-11-15 | R141.M6    | #<N>    | Smoke-mode gate landed; §5 tolerances now enforced. |
-->

### 8.1  How to amend a shape

A legitimate shape change — a wave that intentionally moves a site's
numbers (optimisation, new instrumentation, dispatch rework) — lands
the shape amendment in the same PR as the code change:

1. Edit the §4.X entry's `nominal` numbers.
2. Add a §8 row with the date, wave, issue, and a one-line
   explanation of what moved and why.
3. Confirm the gate (once R141.M6 lands) still passes with the new
   shape by running the smoke-mode after the amendment.

A shape amendment without a §8 entry is reviewable as a regression —
the file's audit trail is load-bearing.

### 8.2  Retiring a site

Site retirement is a non-goal at the current harness design. The
registry is append-only; a slot once allocated is never reclaimed
(see `microbench-harness.md §2`). If a measured hot path is removed
from the kernel the slot stays allocated with `count=0` after reset,
and the §4 entry notes "retired on <date>, slot preserved for
registry stability" rather than being deleted. This keeps the
`site_id` → `name` mapping stable across builds, which matters for
operators grepping historical logs.

---

**Cross-references.**

* `design/perf/microbench-harness.md` — ABI the baselines rest on.
* `design/perf/perf-sink-logging.md` — `PERF SITE` line format.
* `design/perf/fuzz-entry-points.md` — three fuzz-site semantics.
* `design/perf/capability-flow-adversarial.md` — adversary doesn't
  register a microbench site; its runtime is observed through the
  three fuzz sites' numbers when the adversary drives corpora.
* `src/kernel/core/perf/microbench.pdx` — site registry + ring code.
* `src/kernel/core/perf/perf_sink.pdx` — dumper code.
* `src/kernel/core/perf/fuzz_entries.pdx` — fuzz-site registrations.
* `tools/build.sh`, `tools/run-qemu.sh` — the standing boot pair.
