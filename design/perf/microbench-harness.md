# Kernel-side microbenchmark harness

**Status:** R141.M1 chain-head skeleton landed (Wave UMB-W3, paideia-os #2645).
Scope: substrate (fixed-slot site registry + per-site cycle ring) + ONE
instrumented site (`cap_invoke`) + one capability KIND
(`KIND_MICROBENCH = 0x5E`) so user-space can enumerate measurement
sites and read per-site statistics.

**Umbrella:** R141 is the kernel-space microbenchmark harness umbrella.
It frames the end-state as "every hot path in the kernel has a stable
sampling bracket whose per-site min/max/sum/count is readable from
user-space without a probe effect that distorts the measurement."

**Chain:** M1 (THIS LANDING) freezes the ABI and lights up one site.
M2 instruments `ctx_switch`. M3 instruments `vfs_fast_path`. M4
instruments `klog_slow_path`. M5 adds the user-space consumer utility
(reads via KIND_MICROBENCH, writes to a `/perf/microbench` pdxfs
view).

---

## 1  Problem statement

The kernel grows hot paths faster than it grows ways to notice when
they regress. Three symptoms motivate the harness:

1. **Dispatch cost is unknown.** `cap_invoke` sits in the fast-path
   budget of every ring-3 → ring-0 crossing. Across Waves 59..88 the
   dispatch cascade grew from four `cmp rcx, imm` arms to ~90 arms;
   there is no landed number that says what the median caller pays
   today.
2. **A regression without a sampling floor is invisible.** When a
   patch adds a `klog_s1` to a hot path "just for witness coverage",
   the ensuing 300-cycle round trip disappears into noise unless
   someone was watching the specific window; the harness turns "did
   this change dispatch cost?" into a one-line check.
3. **The alternative is probing from user-space, which is strictly
   worse.** A ring-3 timer sampler sees the syscall entry/exit tax
   plus the dispatch cost plus any cache disturbance from the sampler
   itself. The harness measures *inside* the window the regression
   lives in.

## 2  Non-goals

* Not a general-purpose profiler. The harness samples *fixed sites*
  the kernel has registered at init; it never grows an arbitrary new
  measurement point without a kernel change.
* Not a tracer. No per-event metadata (caller, args, result) is
  captured — only the cycle delta between a paired begin/end bracket.
* Not a cross-CPU aggregator at M1. Updates to per-site state are
  made with no lock and no atomic; a torn read sees a slightly stale
  min/max/sum but never a cross-site mixup. A later slice may lift
  this to per-CPU rings merged at read time.
* Not security-sensitive. Rights on `KIND_MICROBENCH` are read / write
  (R_MB_READ / R_MB_WRITE), modelled on `KIND_CAP_ENV`. A ring-3
  holder of the cap cannot mint a new site; registration is a
  kernel-side primitive the harness itself drives at init.

## 3  Design

### 3.1  Site registry

Fixed array of 16 rows at
`src/kernel/core/perf/microbench.pdx:_mb_sites`:

```
offset  width  field                 note
+0      u32    site_id               row index 0..15 (low 32 bits)
+4      u32    head_idx              ring write cursor 0..127 (high 32 bits)
+8      u64    name_hash             djb2 u64 of the registered name
+16     u64    sample_count          monotonic sample counter
+24     u64    min_cycles            smallest observed delta
+32     u64    max_cycles            largest observed delta
+40     u64    sum_cycles            running sum
                                     (consumer computes avg = sum/count)
```

Row size: **48 B** (6 u64; the (site_id, head_idx) pair packs into one
u64 slot at [+0]). The 32-bit halves of [+0] are updated with `mov_d`
so a torn reader never splits a site_id across two writes. Total
registry footprint: `16 × 48 = 768 B`.

### 3.2  Per-site ring buffer

Fixed array of 2048 u64 at `_mb_rings` — 16 contiguous blocks of 128
`u64` samples each. The write pattern inside
`_mb_sample_end(site_id, start_tsc)` is:

```
delta = rdtsc() - start_tsc
ring[site_id * 128 + head_idx] = delta
head_idx = (head_idx + 1) & 0x7F
```

Per-site stride is 1024 bytes = 2^10, so a single `shl rN, 10` lands
the base. Wrap mask 0x7F fits imm32 and is staged through a register
per the paideia-as encoder discipline. Total ring footprint:
`16 × 128 × 8 = 16 KiB`.

**Why 128 samples?** 128 is enough to see "has this bimodal behavior
re-emerged" without being enough to detect long-period beating with
other subsystems. The ring is sized for the *regression-notice*
mission, not for distribution reconstruction; that is M5+'s job via
the user-space consumer which can accumulate a longer window.

**Why not more than 16 sites?** Hot paths worth instrumenting are
rare. Growing the ceiling costs 1024 B / site in ring footprint.
Four sites are already named for M1..M4; the headroom covers one more
generation of hot paths without a substrate change.

### 3.3  Public API

Signatures in `src/kernel/core/perf/microbench.pdx`:

| Symbol                   | Signature                        | Role                           |
|--------------------------|----------------------------------|--------------------------------|
| `_mb_init`               | `() -> ()`                       | Boot entry; registers `cap_invoke` site |
| `_mb_site_register`      | `(ptr, len) -> site_id | 0xFF`   | Append a site; returns row index |
| `_mb_sample_begin`       | `(site_id) -> start_tsc`         | `rdtsc` wrapper (site_id unused at M1) |
| `_mb_sample_end`         | `(site_id, start_tsc) -> ()`     | `rdtsc` + stats + ring update  |
| `_mb_site_stats`         | `(site_id, out_ptr) -> errno`    | 48-byte snapshot copy          |
| `_mb_site_count`         | `() -> u64`                      | Registered-site count accessor |
| `_mb_tables_reset`       | `() -> ()`                       | Defensive zero (chaos-restart) |

### 3.4  Capability facade (KIND_MICROBENCH = 0x5E)

A ring-3 (or kernel-mode) consumer invokes
`cap_invoke(slot, op_arg)` on a `KIND_MICROBENCH` cap:

| op_code | name                      | arg (op_arg[15:8]) | returns                        |
|---------|---------------------------|--------------------|--------------------------------|
| 0       | `MB_OP_LIST_SITES`        | —                  | registered site count          |
| 1       | `MB_OP_READ_STATS`        | site_id            | sample_count for the site      |
| 2       | `MB_OP_READ_SAMPLES_HEAD` | site_id            | ring write cursor (0..127)     |
| 3       | `MB_OP_RESET_SITE`        | site_id            | `MB_OK` (no-op at M1)          |
| 4       | `MB_OP_SITE_COUNT`        | —                  | registered site count          |

Rights:

* `R_MB_READ`  (0x001) — gates ops 0, 1, 2, 4
* `R_MB_WRITE` (0x002) — gates op 3

An out-of-range `site_id` returns `KMB_BAD_SITE = 0xFFFFFCC7`. A
rights violation returns `INVOKE_DENIED`.

### 3.5  Overhead budget

**Target:** begin + end ≤ 40 cycles on x86_64 (two `rdtsc` ≈ 20 cycles
+ 2 loads + 4 stores). At skeleton level the pair crosses two function
call boundaries so **measured overhead is ~60–120 cycles per
begin+end on silicon** (and higher on QEMU-TCG, which is irrelevant
for the budget — the metric that matters is silicon). A future slice
(R141.M* "inline brackets") lifts begin/end to macro-expanded inline
sequences at the call site, bringing the pair under the 40-cycle
target.

Why acceptable at M1:

1. The overhead is **bounded** — no loops, no cap-invoke bounce, no
   klog chatter from the hot path (klog fires only during
   `_mb_init`).
2. The overhead is **constant** across all sites, so differences in
   per-site min/max/sum are attributable to the site under test, not
   to harness variance.
3. The overhead is **documented**, so a reader comparing numbers
   between kernel builds knows the floor.

### 3.6  First measurement site: `cap_invoke`

Instrumentation lives in
`src/kernel/core/cap/invoke.pdx:cap_invoke`. The bracket shape is:

```
block: {
    push rbx; push r12; push r13; push r14; sub rsp, 8;
    mov rbx, rdi; mov r12, rsi;

    mov rdi, [rip + _mb_site_cap_invoke_id];
    call _mb_sample_begin;
    mov r13, rax;              // start_tsc

    cmp rbx, 256;
    jae ci_mb_bad;
    mov rdi, rbx; mov rsi, r12;
    call cap_invoke_dispatch;
    jmp ci_mb_end;

ci_mb_bad:
    mov rax, 0xFFFFFFFFFFFFFFFE;

ci_mb_end:
    mov r14, rax;
    mov rdi, [rip + _mb_site_cap_invoke_id];
    mov rsi, r13;
    call _mb_sample_end;
    mov rax, r14;

    add rsp, 8; pop r14; pop r13; pop r12; pop rbx; ret
}
```

The site_id is reached via a single memory load of
`_mb_site_cap_invoke_id`, which `_mb_init` writes once (per the
`cmp` chain in `cap_invoke_dispatch`, this measurement wraps the
*entire* dispatch — rights load, kind read, per-kind handler call).

## 4  Boot wiring

`src/kernel/boot/kernel_main.pdx` adds one call immediately after
`tsc_calibrate` and before the first subsystem that invokes
`cap_invoke`:

```
mov rdi, 0x608;
call tsc_calibrate;

call _mb_init;              // UMB-W3 R141.M1 (paideia-os #2645)

call x2apic_probe_bsp;
```

Running _after_ `tsc_calibrate` lets a future consumer convert cycle
deltas to seconds via `_tsc_hz`. Running _before_ the first
`cap_invoke` makes sure the first sample is captured.

## 5  Future sites (R141.M2..M4)

Each future slice adds one `_mb_site_register` call at the init path
of its subsystem and one `_mb_sample_begin` / `_mb_sample_end` bracket
at the hot-path entry/exit:

| Slice | Site           | Register from                                        | Bracket at                            |
|-------|----------------|------------------------------------------------------|---------------------------------------|
| M2    | `ctx_switch`   | `sched_init_runqueue_r10`                            | `trampoline_vec32` preempt tail       |
| M3    | `vfs_fast_path`| `vops_init`                                          | `vfs_lookup_fast` entry/exit          |
| M4    | `klog_slow_path`| `klog_emit_core_init`                               | `klog_emit_core` entry/exit           |

Each slice follows the same shape as the M1 `cap_invoke` instrumentation:
one static `*_id` global, one `_mb_init`-time registration, one
pair of brackets in the hot path.

## 6  Reserved-word and encoder discipline

Every label in `microbench.pdx` is prefixed `mb_`; every label in
`kind_microbench.pdx` is prefixed `kmb_` (paideia-as reserves `loop`,
`if`, `let`). Row stride 48 uses `mov r11, 48; imul rax, r11` reg-reg
(no 2-op `imul r, imm`). Head wrap mask 0x7F is staged through a
register (no `and r11, imm64`). Head-idx update uses `mov_d [row+4],
rN` so the 32-bit store leaves the site_id untouched. All liveness
checks use `cmp rN, 0`; no `test rN, rN`.

## 7  Files touched by R141.M1

* `src/kernel/core/perf/microbench.pdx` — NEW substrate module.
* `src/kernel/core/cap/kind_microbench.pdx` — NEW capability facade.
* `src/kernel/core/cap/invoke.pdx` — dispatch arm (`cmp rcx, 0x5E;
  je call_kind_microbench;` + the matching
  `call_kind_microbench: call cap_handler_microbench; ret;` label),
  plus the instrumentation bracket in `cap_invoke`.
* `src/kernel/boot/kernel_main.pdx` — one `call _mb_init;` after
  `tsc_calibrate`.
* `design/perf/microbench-harness.md` — THIS file.
