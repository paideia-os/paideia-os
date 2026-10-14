# Perf-sink logging layer

**Status:** R141.M2 landed (Wave UMB-W13, paideia-os #2646). Scope:
static sink that walks the microbench site registry
(`perf/microbench.pdx` + `cap/kind_microbench.pdx`, Wave UMB-W3
#2645) and emits one structured klog line per site plus a summary
`PERF SINK DUMP OK` fingerprint. Opened via `KIND_MICROBENCH` op
`MB_OP_DUMP_ALL = 5` under `R_MB_READ`.

**Umbrella:** R141 is the kernel-space performance-measurement
umbrella. M1 lit up the microbench substrate (fixed-slot site
registry + per-site cycle ring + one `cap_invoke` bracket). M2
(THIS LANDING) adds the reporting side so a userspace consumer can
observe per-site min/max/mean cycle costs without reading
`_mb_sites` directly through a side-channel map. M3 widens the
sink into a first-class capability (`KIND_LOG_SINK`), at which
point the destination becomes dynamically retargetable (userspace
ring, pdxfs view, remote collector, …).

---

## 1  Problem statement

R141.M1 freezes the microbench ABI and lights up one instrumentation
site. A userspace holder of `KIND_MICROBENCH` can poll `MB_OP_READ_
STATS` (returns `sample_count`) and `MB_OP_READ_SAMPLES_HEAD`
(returns the ring write cursor) one site at a time, but there is no
way for the consumer to see `min_cycles`, `max_cycles`, or `sum_
cycles` without either (a) walking a side-channel map into
`_mb_sites`, or (b) landing the full `_mb_site_stats` snapshot copy
across the cap-invoke boundary. Both approaches are heavier than
the actual observational need:

* The side-channel map is a security surface — any read handle into
  kernel BSS is a potential leak vector.
* The snapshot copy requires the userspace caller to allocate a
  48 B landing buffer, pass it through `op_arg`, and interpret the
  packed `(site_id, head_idx)` word. The complexity is justifiable
  for a profiler, not for a `tail -f`-style "is this hot path
  regressing" workflow.

The perf-sink is the lightweight third option: the kernel formats
one `PERF SITE ...` klog line per site, and the serial console (or
future KIND_LOG_SINK consumer) absorbs the whole snapshot as human-
readable text. No side-channel map, no landing buffer, no
packed-field decode.

## 2  Non-goals

* **Not a replacement for `_mb_site_stats`.** The snapshot copy
  stays live; it is the right primitive for a userspace sampler
  that wants the raw 48 B row for its own analysis. Perf-sink is
  the complementary primitive for a consumer that wants
  pre-formatted text.
* **Not a profiler.** The dump path emits a point-in-time snapshot
  of each site's running `min`/`max`/`mean`; it does not capture
  the ring buffer or the per-sample delta history. R141.M4+ (ring
  export) is the next primitive in that direction.
* **Not a trace format.** Each dump line is one klog line per site,
  not a time-ordered trace. The timestamp on each line is the klog
  emission time, not the sample's TSC.
* **Not security-sensitive at M2.** The sink is reached only
  through `KIND_MICROBENCH` with `R_MB_READ`; the cap gate is the
  single authority surface. The sink itself takes no capability
  arguments and has no row pool.

## 3  Design

### 3.1  Static sink

At R141.M2 the sink is a bare pass-through to `klog_emit_core`.
There is no sink table, no registration path, and no indirection
between the dump helpers and the klog ring. This is deliberate —
R141.M3's `KIND_LOG_SINK` wave will add the indirection and the
registration path together, and splitting the primitive now would
leave half of each in-tree in a shape neither consumer could use
cleanly.

The whole sink substrate is three functions in
`src/kernel/core/perf/perf_sink.pdx`:

| Symbol                    | Signature             | Role                                 |
|---------------------------|-----------------------|--------------------------------------|
| `_perf_sink_init`         | `() -> ()`            | Boot entry; emits `PERF SINK INIT OK` |
| `_perf_sink_dump_all`     | `() -> u64`           | Walk every registered site + summary |
| `_perf_sink_dump_site`    | `(site_id) -> u64`    | Single-site dump                     |

Private helpers:

| Symbol      | Signature       | Role                                   |
|-------------|-----------------|----------------------------------------|
| `_ps_note`  | `(slot) -> ()`  | Bump `_ps_stats[slot]` (observability) |

### 3.2  Dump line format

Each dumped site emits one `klog_emit_core` call with:

```
level     = LEVEL_INFO (3)
subsys    = SUBSYS_TIME ("time\0")
tag       = "PERF SITE\0"
kvs       = 5 entries (24 B each; see §3.3)
```

The rendered klog line (prefix per `boot-transcript.md §4.1`) reads:

```
[  <sec>.<usec>] INFO cpu0 time: PERF SITE name=0x<16-hex> \
                                  count=<N> min=<N> max=<N> mean=<N>
```

`name` is the djb2 u64 digest of the site's registered name string.
Printing the hash in hex (rather than resolving back to the name
literal) keeps the sink free of a reverse-lookup table — the
userspace consumer that already knows the registered names can
match the hash, and a human reader with the kernel source can
`grep` for a hash that showed up in the serial log.

`count`, `min`, `max`, `mean` are decimal cycle counts. `mean =
sum / count`, computed inline with `xor rdx, rdx; div r13` and a
`count == 0` guard that substitutes `0` so a never-sampled site
cannot raise `#DE`.

### 3.3  KV table layout

Each `klog_emit_core` KV entry is a 24-byte triple:

```
offset   width   field          note
+0       u64     key_ptr        NUL-terminated ASCII in rodata
+8       u64     value          the u64 to format
+16      u64     fmt_letter     0x78='x' (hex), 0x64='d' (dec)
```

`_perf_sink_dump_site` builds the 5-entry table on the caller stack
with `rsp[0..119]` (120 B) and an 8 B pad to keep `rsp % 16 == 0`
at every nested `call`:

| Entry | key_ptr      | value                      | fmt       |
|-------|--------------|----------------------------|-----------|
| 0     | `ps_k_name`  | `name_hash`                | `0x78` x  |
| 1     | `ps_k_count` | `sample_count`             | `0x64` d  |
| 2     | `ps_k_min`   | `min_cycles`               | `0x64` d  |
| 3     | `ps_k_max`   | `max_cycles`               | `0x64` d  |
| 4     | `ps_k_mean`  | `sum_cycles / sample_count`| `0x64` d  |

The table is built as six `mov [rsp+N]`-style stores per entry, no
loop. `klog_emit_core` is called with `rcx = rsp` (`kvs_ptr`) and
`r8 = 5` (`kv_count`).

### 3.4  Summary fingerprint

`_perf_sink_dump_all` emits one additional klog line at the tail
of a successful cascade, via `klog_s1_x1`:

```
[  <sec>.<usec>] INFO cpu0 time: PERF SINK DUMP OK sites=0x<16-hex>
```

`sites` is the registered-site count (`_mb_site_count()`), printed
hex. The fingerprint carries `OK` in its tag so the
`verify-fingerprint-coverage` gate requires either an asserting
golden or an allowlist entry; M2 lands the allowlist entry with a
retire-when-R141.M3-lands reason (see §7).

### 3.5  Return codes

```
PS_OK            = 0
PS_ERR_NO_SITES  = 0x1300
```

`PS_ERR_NO_SITES` fires in two paths:

* `_perf_sink_dump_site` with `site_id >= _mb_site_count()`.
* `_perf_sink_dump_all` when `_mb_site_count() == 0` (no `_mb_init`
  call, or `_mb_init` registered zero sites — neither case is
  reachable in a healthy boot).

Band audit (`grep -rnE '0x1300\b' src/ 2>/dev/null`) returned zero
hits at landing time. The code is far enough from the `KMB_BAD_*`
band (0xFFFFFCC6..CC9) that cross-pollination is impossible.

### 3.6  Observability

`_ps_stats[8]` is bumped by `_ps_note`:

| Slot | Name                   | Fires on                                      |
|------|------------------------|-----------------------------------------------|
| 0    | `PS_ST_INIT_OK`        | `_perf_sink_init` tail                        |
| 1    | `PS_ST_DUMP_OK`        | `_perf_sink_dump_all` success tail            |
| 2    | `PS_ST_DUMP_NO_SITES`  | `_perf_sink_dump_all` empty-registry gate     |
| 3    | `PS_ST_SITE_OK`        | `_perf_sink_dump_site` success tail           |
| 4    | `PS_ST_SITE_BAD`       | `_perf_sink_dump_site` out-of-range gate      |
| 5..7 | (reserved)             | R141.M3 KIND_LOG_SINK slots                   |

A future witness consumes these through a kernel-side read (there
is no cap gate at M2; by convention the slots are observable only
to in-kernel code).

## 4  Boot wiring

`src/kernel/boot/kernel_main.pdx` adds one call immediately after
`_mb_init`:

```
call _mb_init;            // R141.M1 (#2645)
call _perf_sink_init;     // R141.M2 (#2646)
```

Running after `_mb_init` is required: the sink's dump helpers
delegate to `_mb_site_count` / `_mb_row_base`, which require the
site registry to be live. `_perf_sink_init` itself only emits the
`PERF SINK INIT OK` fingerprint — it does not touch `_mb_*` state
— so the order is purely a "when I run, the thing I depend on
exists" discipline. Running before `_cmd_registry_load_boot`
matches the existing R141.M1 ordering.

## 5  Capability wiring

`cap/kind_microbench.pdx` adds `MB_OP_DUMP_ALL = 5` to the dispatch
cascade (§4 of the kind doc, updated by this landing). The op
takes no `site_id` argument (dump-all walks everything); its arm
runs the `R_MB_READ` gate (same gate the four existing read ops
use), calls `_perf_sink_dump_all`, and returns the sink's return
code verbatim. The stat slot bump reuses `KMB_ST_LIST_OK` since
the op is semantically a read; R141.M3's refactor widens
`_kind_mb_stats` to its own `DUMP_OK` slot.

Current full op surface:

| op_code | name                      | arg                | returns                        |
|---------|---------------------------|--------------------|--------------------------------|
| 0       | `MB_OP_LIST_SITES`        | —                  | registered site count          |
| 1       | `MB_OP_READ_STATS`        | `site_id`          | sample_count for the site      |
| 2       | `MB_OP_READ_SAMPLES_HEAD` | `site_id`          | ring write cursor (0..127)     |
| 3       | `MB_OP_RESET_SITE`        | `site_id`          | `MB_OK` (no-op at M1)          |
| 4       | `MB_OP_SITE_COUNT`        | —                  | registered site count          |
| 5       | `MB_OP_DUMP_ALL`          | —                  | `PS_OK` / `PS_ERR_NO_SITES`    |

## 6  Interaction with microbench.pdx (R141.M1)

The sink does **not** mutate `_mb_sites` / `_mb_rings` /
`_mb_site_count_var`; it is strictly read-side. Every value in a
dump line is loaded in-place from the row:

```
name_hash     = [row + 8]
sample_count  = [row + 16]
min_cycles    = [row + 24]
max_cycles    = [row + 32]
sum_cycles    = [row + 40]
mean_cycles   = sum / sample_count  (0 if sample_count == 0)
```

Row base resolution is `_mb_row_base(site_id)` — one call per
`_perf_sink_dump_site`, outside the hot path of
`_mb_sample_begin`/`_mb_sample_end`. The ring buffer at
`_mb_rings[site_id * 128 ..]` is **not** read by the sink; its
per-sample history is left for a future R141.M4+ "ring export"
primitive.

The sink races with concurrent `_mb_sample_end` writes: a torn
read sees a slightly-stale min/max/sum/count snapshot (per
microbench.pdx §0, `sample_count` is published LAST so a reader
that gates on `count > 0` sees the full stat row), never a
cross-site mixup (site_id addresses pick disjoint row regions).
At M2 the dump path is not expected to interleave with ring-3
`cap_invoke` traffic — the sole invoker is a kernel-mode or user-
mode cap holder that drives the dump explicitly — but the stale-
read behavior is correct for a future periodic-dump mode.

## 7  Fingerprint allowlist

Two `OK` fingerprints:

* `PERF SINK INIT OK` — emitted every boot by `_perf_sink_init`.
* `PERF SINK DUMP OK` — emitted at `_perf_sink_dump_all`'s success
  tail; unreachable in-tree at M2.

Both land as `verify-fingerprint-coverage` allowlist entries with
a `retire-when-R141.M3-lands` reason, so the gate itself refuses
to keep them once R141.M3 adds the first in-tree consumer that
exercises `MB_OP_DUMP_ALL = 5` end-to-end. The sibling
`PERF SITE ...` per-site lines carry no `OK` token in their tag,
so they are outside the coverage gate's regex and need no
allowlist entry.

## 8  Future wiring (R141.M3+)

The M2 shape is deliberately shallow so M3 can slot in without a
substrate rewrite:

| Slice | Addition                                                               |
|-------|------------------------------------------------------------------------|
| M3    | `KIND_LOG_SINK` cap + `_perf_sink_register(sink_fn)` + dispatch table  |
| M4    | Ring export: `_perf_sink_dump_ring(site_id)` emits ring[0..127]        |
| M5    | Periodic trigger: HPET-driven `_perf_sink_tick` on an interval         |
| M6    | pdxfs mount at `/perf/sink/` exposing one directory per registered sink |

The per-site line format from §3.2 is the stable surface: later
slices change the destination of the formatted bytes, not the
bytes themselves.

## 9  Reserved-word and encoder discipline

Every label in `perf_sink.pdx` is prefixed `ps_` (paideia-as
reserves `loop`, `if`, `let`). All `pub let` string decls fit on
one line. Mean compute uses `xor rdx, rdx; div r13` reg-reg
(paideia-as supports `div reg` directly). Rights-mask tests use
`cmp r10, 0` (never `test`). Error constants `PS_OK` (0) and
`PS_ERR_NO_SITES` (0x1300) fit imm32 (zero-extend to u64 via the
7-byte `mov rax, imm32` emit). Module basename `PerfSink` matches
file basename `perf_sink.pdx`.

The KV-table build on-stack uses the 24 B-per-entry layout
`klog_emit_core` already walks (`klog/wrappers.pdx::klog_s1_x1`
builds it the same way for one entry); the `klog_s1_x1`-shaped
summary call at the end of `_perf_sink_dump_all` reuses that
wrapper directly rather than open-coding the table.

## 10  Files touched by R141.M2

* `src/kernel/core/perf/perf_sink.pdx` — NEW module (`PerfSink`).
* `src/kernel/core/cap/kind_microbench.pdx` — `MB_OP_DUMP_ALL = 5`
  constant, cascade arm `cmp r11, 5; je kmb_hd_op_dump`, and the
  `kmb_hd_op_dump` handler.
* `src/kernel/boot/kernel_main.pdx` — one `call _perf_sink_init;`
  after `call _mb_init;`.
* `tools/verify-fingerprint-coverage.sh` — allowlist entries for
  `PERF SINK INIT OK` and `PERF SINK DUMP OK`.
* `design/perf/perf-sink-logging.md` — THIS file.
