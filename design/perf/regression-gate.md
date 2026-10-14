# Regression gate (R141.M6)

**Status:** R141.M6 landed (Wave UMB-W25, paideia-os #2650). Scope: a
pure-kernel .pdx regression gate (`src/kernel/core/perf/
regression_gate.pdx`) that compares a boot's observed microbench
numbers against the baseline shapes recorded in
`design/perf/perf-baselines.md §4` and emits one `PERF_GATE SITE
PASS` or `PERF_GATE SITE FAIL` fingerprint per gated site. The gate
is INFORMATIONAL ONLY at M6: it writes the fingerprint but does not
halt the boot or raise an exit code. R141.M7 (forward) adds the
smoke-mode golden that greps for `PERF_GATE SITE FAIL` and raises
the smoke exit code when the pattern appears.

**Umbrella.** R141 is the kernel-space performance-measurement
umbrella. M1 (`#2645`) landed the microbench RDTSC harness. M2
(`#2646`) landed the perf-sink klog dumper. M3 (`#2647`) landed the
fuzz entry shims. M4 (`#2648`) landed the capability-flow
adversary. M5 (`#2649`) landed the operator-facing baselines doc.
**M6 (this document)** is the regression gate. M7+ wires the smoke-
mode consumer.

**Companion files.**

| doc                                                         | provides                            |
|-------------------------------------------------------------|-------------------------------------|
| `design/perf/microbench-harness.md`                         | `_mb_site_stats` ABI the gate reads |
| `design/perf/perf-sink-logging.md`                          | klog line format the gate inherits  |
| `design/perf/fuzz-entry-points.md`                          | fuzz-site semantics (M6 placeholder)|
| `design/perf/capability-flow-adversarial.md`                | adversary that drives the sites     |
| `design/perf/perf-baselines.md`                             | AUTHORITY for the shapes gated here |

---

## 1  Purpose

An operator-facing baseline (`perf-baselines.md`) tells a human what
"normal" looks like. A regression gate turns that same shape into a
machine check: a boot that no longer sits inside the budget emits
one `PERF_GATE SITE FAIL` line per out-of-shape site, with:

* the site's `name_hash` as a stable identifier (slot-order
  independent);
* the failing axis implied by the error code (`RG_FAIL_MIN`,
  `RG_FAIL_MAX`, `RG_FAIL_MEAN`);
* the observed cycle count that tripped the budget.

The gate is purposefully NOISY on PASS as well: every live site
emits a `PERF_GATE SITE PASS` line on every `_rg_check_all` cascade,
giving an operator a grep-able cross-reference of what shapes were
observed and whether they stayed inside the budget. The honesty
posture is: if a site is live and sampled, SAY what we saw, every
time, so no boot leaves the gate silent about any slot.

### 1.1  Non-goals

* **Not a performance SLO.** A `PERF_GATE SITE FAIL` flags a *change
  in shape*, not a *committed response time*. Hard SLOs on dispatch
  cost belong in a later ring-3 reliability layer that does not
  exist.
* **Not an auto-tuning oracle.** The baseline table is seeded from
  compile-time constants in `_rg_init`; a boot that drifts the mean
  by 20% is a regression, not a ratchet.
* **Not a build gate at M6.** The fingerprint is emitted; a smoke-
  mode consumer that fails the build on `PERF_GATE SITE FAIL` lands
  with R141.M7+.
* **Not a cross-site statistic.** Each site is gated independently;
  the gate never computes a trend over multiple sites.

## 2  Gate algorithm

For each site_id in `[0..RG_MAX_SITES=8)`:

```
if baseline[site].cold_tol_num == RG_FLAG_PLACEHOLDER (0):
    skip (RG_OK, bump RG_ST_CHECK_SKIP)
    continue

stats := _mb_site_stats(site_id)
if stats returns error:
    emit FAIL fingerprint? no — site is misconfigured, return
    RG_ERR_BAD_SITE (bump RG_ST_CHECK_BAD)
    continue

if stats.count == 0:
    skip (RG_OK; the site was registered but not driven)
    continue

mean := stats.sum / stats.count

# Axis mapping per design/perf/perf-baselines.md §5:
#   min  -> warm tolerance (×warm_tol_num / warm_tol_den)
#   max  -> cold tolerance (×cold_tol_num / cold_tol_den)
#   mean -> warm tolerance

# Overflow-safe cross multiply (no integer division, no #DE on 0).
if stats.min * warm_tol_den > min_expected  * warm_tol_num:
    emit FAIL (min)      ; return RG_FAIL_MIN
if stats.max * cold_tol_den > max_expected  * cold_tol_num:
    emit FAIL (max)      ; return RG_FAIL_MAX
if mean      * warm_tol_den > mean_expected * warm_tol_num:
    emit FAIL (mean)     ; return RG_FAIL_MEAN

emit PASS                ; return RG_OK
```

An observed value **below** the nominal is never a fail (a kernel
that got faster is a successful build; §5 of `perf-baselines.md`).
The cross-multiply form keeps every intermediate in u64 range:
`max_expected * cold_tol_num` for cap_invoke is `6000 * 2 = 12000`,
far under 2^32; pathological 10^5 cycles * 100-numerator stays
under 2^24.

## 3  Baseline-table shape

The gate's static baseline table is a `[u64; 64]` encoding 8 rows of
8 u64 each. Row offsets (bytes):

| off | field          | notes                                      |
|-----|----------------|--------------------------------------------|
| +0  | `site_hash`    | djb2 of registered name, resolved at init  |
| +8  | `min_expected` | §4.X cold `min` nominal (cycles)           |
| +16 | `max_expected` | §4.X cold `max` nominal (cycles)           |
| +24 | `mean_expected`| §4.X cold `mean` nominal (cycles)          |
| +32 | `cold_tol_num` | numerator of cold-cache tolerance (0=skip) |
| +40 | `cold_tol_den` | denominator of cold-cache tolerance        |
| +48 | `warm_tol_num` | numerator of warm-cache tolerance          |
| +56 | `warm_tol_den` | denominator of warm-cache tolerance        |

Row stride is 64 B = 2^6, so address compute is `shl rax, 6` (power
of two, no imul). Matches `_mb_ring_base`'s posture rather than
`_mb_row_base`'s imul posture; the gate's hot path is shorter when
the shift replaces the reg-reg imul.

### 3.1  M6 coverage

| slot | name            | status         | min  | max  | mean | tol-cold | tol-warm |
|------|-----------------|----------------|------|------|------|----------|----------|
| 0    | `cap_invoke`    | LIVE           | 1500 | 6000 | 3500 | 2/1      | 13/10    |
| 1    | `fuzz_cmd_reg`  | PLACEHOLDER    | -    | -    | -    | 0        | -        |
| 2    | `fuzz_wit_br`   | PLACEHOLDER    | -    | -    | -    | 0        | -        |
| 3    | `fuzz_stdout`   | PLACEHOLDER    | -    | -    | -    | 0        | -        |
| 4-7  | (reserved)      | PLACEHOLDER    | -    | -    | -    | 0        | -        |

The three fuzz-site rows and the four reserved rows all carry
`cold_tol_num = 0 = RG_FLAG_PLACEHOLDER`, so `_rg_check_site`
returns `RG_OK` (skip) for each without a fingerprint — the sites
have no boot driver, so there is no observed shape to gate on.

### 3.2  Placeholder sentinel

The placeholder flag doubles as the cold-tol-num slot's VALUE
rather than a dedicated field. A `cold_tol_num == 0` makes no
mathematical sense (0× tolerance would reject every observed
sample), so it is a safe sentinel for "skip this row". The
semantic matches "reserved" (empty slot not yet carrying a
baseline) and "placeholder" (slot carries a name but no boot
driver) with one sentinel; the distinction between the two is
documentation-only.

## 4  Public API

```
pub let _rg_init() -> ()
```

Boot entry. Seeds the baseline table (cap_invoke's §4.1 shape at
slot 0; placeholder zeros at slots 1..7) and resolves the live
row's `site_hash` from the microbench registry. Emits `PERF_GATE
INIT OK` via `klog_s1`. Must run AFTER `_mb_init`,
`_perf_sink_init`, and `_fz_init` so every registered microbench
row has its name_hash populated before the gate reads it.

```
pub let _rg_check_site(site_id: u64) -> errno
```

Gates one site. Returns:

| code              | value   | meaning                                 |
|-------------------|---------|-----------------------------------------|
| `RG_OK`           | 0       | PASS, or placeholder-skip, or count==0  |
| `RG_FAIL_MIN`     | 0x2600  | observed `min` exceeds warm-tol upper   |
| `RG_FAIL_MAX`     | 0x2601  | observed `max` exceeds cold-tol upper   |
| `RG_FAIL_MEAN`    | 0x2602  | observed `mean` exceeds warm-tol upper  |
| `RG_ERR_BAD_SITE` | 0x2603  | site_id ≥ 8 or `_mb_site_stats` failed  |

Emits one `PERF_GATE SITE PASS` or `PERF_GATE SITE FAIL`
fingerprint per non-skip call via `klog_s1_x2` with two hex KVs
(`site=0x<hash>`, `actual=0x<cycles>`).

```
pub let _rg_check_all() -> packed u64 = (fail_mask << 32) | pass_count
```

Iterates all 8 slots. Returns a packed u64: high 32 bits are a
bitmap with bit N set when site N returned non-`RG_OK`; low 32 bits
are a count of sites that returned `RG_OK` (including placeholder-
skipped and count==0 sites). Emits a final `PERF_GATE ALL OK fail=
0x<mask> pass=0x<count>` summary via `klog_s1_x2`.

The packed return keeps the caller surface single-value in
preparation for a future KIND_MICROBENCH op that returns the two
32-bit halves as a one-word reply payload. A smoke-mode consumer at
R141.M7+ will ignore the packed word and grep for `PERF_GATE SITE
FAIL` lines directly, since that is the operator-facing signal.

## 5  Fingerprint format

The gate emits four tagged lines. The three per-site tags share the
`PERF_GATE SITE` prefix so an operator can locate every gate line in
one grep sweep; the two outcomes split on the trailing word so
`grep '^.*PERF_GATE SITE FAIL'` finds every regression line in one
pass. (The design doc explicitly rejected a shared `PERF_GATE SITE`
tag with a `result=<PASS|FAIL>` KV because klog's KV formatter has
no string-value fmt letter at M6 and a hex-encoded ASCII sentinel
would render as `result=0x50415353`, which defeats the fingerprint's
grep ergonomics.)

| tag                   | shape                                                                 |
|-----------------------|-----------------------------------------------------------------------|
| `PERF_GATE INIT OK`   | boot-only; emitted once at `_rg_init` tail; no KV                     |
| `PERF_GATE SITE PASS` | per-call; `site=0x<16-hex> actual=0x<16-hex>` (actual = observed min) |
| `PERF_GATE SITE FAIL` | per-call; `site=0x<16-hex> actual=0x<16-hex>` (actual = failing axis) |
| `PERF_GATE ALL OK`    | per-cascade; `fail=0x<16-hex> pass=0x<16-hex>`                        |

The `site=` KV carries the microbench site's `name_hash` (djb2 of
the registered name), not the slot index. A smoke-mode consumer
that greps for a specific site uses the hash — slot-order drift
across waves is tolerated.

The `actual=` KV on a `PASS` line reports the observed `min` (the
most stable axis across boots per §4.1 of `perf-baselines.md`); on
a `FAIL` line it reports the specific axis's observed cycles,
making the regression line self-contained ("site X went to Y
cycles"). The error code (`RG_FAIL_MIN/MAX/MEAN`) is the gate's
return value, not a klog field — a reader locates the failing axis
by cross-referencing the `actual=` value with the three §4
nominals.

## 6  Update discipline

**New site added.** The gate's baseline table and
`design/perf/perf-baselines.md §4` must stay in lockstep. A wave
adding a new measurement site (via `_mb_site_register` during its
boot hook) and the matching `_mb_sample_begin / _mb_sample_end`
bracket at the hot path proceeds in this order:

1. **Land the microbench site itself** (new boot hook, new
   bracket). The site appears at `count=0` in the next boot's
   `PERF SITE` dump.
2. **Capture the shape** per the §3 protocol in `perf-baselines.md`
   (three boots, drive the workload, record the median of each
   axis).
3. **Edit `perf-baselines.md §4.X`** with the new shape block
   (cold+warm shape, interpretation, variance budget).
4. **Edit this gate's baseline table** (`_rg_seed_<site>` or an
   expanded `_rg_init` cascade) to seed the slot with the §4.X
   numbers and the §5 tolerance ratios.
5. **Add a §8 entry** to `perf-baselines.md` (date, wave, issue,
   one-line description).
6. **Boot the kernel.** The new site should emit `PERF_GATE SITE
   PASS` on the first run; a surprise FAIL means either the §4.X
   shape was captured incorrectly or the tolerance is too tight.

**Order matters.** `perf-baselines.md` is the AUTHORITY; the gate's
embedded table is the DERIVED copy. A gate edit that LEADS the doc
edit means the file nobody reads is the one that holds the shapes
— exactly the "diffable oracle" anti-posture `perf-baselines.md §5`
rules out. If a conflict is ever observed between the gate and the
doc, the doc wins and the gate is amended to match.

**New fingerprint added.** Each new tag the gate emits lands with a
matching allowlist entry in `tools/verify-fingerprint-coverage.sh`
(Section A, by convention). The entry describes when the tag
fires and when it retires from the allowlist (typically when
R141.M7+ wires an asserting smoke-mode golden).

## 7  Platform assumptions

The baseline shapes in §3.1 are QEMU-TCG numbers (see §7 of
`perf-baselines.md`). Real-silicon numbers will differ; the
tolerance budgets (×2.0 cold, ×1.3 warm) are deliberately
generous enough that the gate stays single-threshold across every
supported platform. A real-silicon landing in a future wave
re-captures the shapes and may tighten tolerances, with the gate's
table updated per §6.

The gate itself has no platform-specific code: `_rg_check_site` is
pure u64 arithmetic plus one `_mb_site_stats` read and one
`klog_emit_core` emit. Whatever runs on QEMU-TCG today will run on
Alder Lake-U or on an ARM port tomorrow.

## 8  Historical trajectory

| date       | wave     | issue   | event                                                                |
|------------|----------|---------|----------------------------------------------------------------------|
| 2026-10-14 | UMB-W25  | #2650   | Initial landing. Slot 0 cap_invoke live; slots 1-7 placeholder.      |

<!-- Future entries land one row per gate-affecting event. Example:
| 2026-11-02 | R141.M7   | #<N>    | ctx_switch slot 4 live; added _rg_seed_ctx_switch, cold tol 2/1. |
| 2026-11-15 | R141.M7   | #<N>    | smoke-mode golden lands; `PERF_GATE SITE FAIL` now fails smoke.   |
-->

---

**Cross-references.**

* `design/perf/perf-baselines.md` — AUTHORITY for every §3.1 shape.
* `design/perf/microbench-harness.md` — `_mb_site_stats` ABI the
  gate reads.
* `design/perf/perf-sink-logging.md` — klog line format shared with
  `PERF SITE` dumps.
* `src/kernel/core/perf/regression_gate.pdx` — the gate's code.
* `src/kernel/core/perf/microbench.pdx` — site registry + ring.
* `tools/verify-fingerprint-coverage.sh` — fingerprint allowlist.
