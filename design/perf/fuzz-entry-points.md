# Kernel fuzz-testing entry points

**Status:** R141.M3 landed (Wave UMB-W22, paideia-os #2647). Scope:
three in-tree fuzz entry shims (`fuzz_cmd_reg`, `fuzz_wit_br`,
`fuzz_stdout`) that wrap the kernel's open byte-level parse surfaces
(`_cmd_registry_parse`, `_wit_bridge_parse_type_decl`,
`_stdout_records_feed`) in an RDTSC bracket, dump the enclosing site
via `_perf_sink_dump_site` after every call, and expose a newline-
delimited corpus runner that drives all three from a single kernel
blob.

**Umbrella:** R141 is the kernel-space performance-measurement
umbrella. M1 (Wave UMB-W3, #2645) landed the microbench harness
substrate. M2 (Wave UMB-W13, #2646) landed the perf-sink logging
layer. **M3 (this landing)** adds the fuzz entry layer -- hot-path
instrumentation of the parser surfaces most likely to be reached by
hostile or malformed userspace input, with the measurement loop
re-using R141.M1's RDTSC bracket and R141.M2's `PERF SITE` dump
format.

---

## 1  Problem statement

The paideia-os kernel has grown four byte-level parse surfaces that
accept data crossing a trust boundary:

* **`_cmd_registry_parse`** -- parses a TOML-subset configuration
  blob (`/system/shell/commands.toml`) that the on-boot
  `_cmd_registry_load_boot` hook feeds into the KIND_CMD_MODULE row
  pool. The buffer today is a 4 KiB kernel read from an FS the
  bootloader hands over, but a future userspace-provided reload
  (`_cmd_registry_reload`, see `shell/cmd_registry_parser.pdx`
  §10) takes the buffer through a cap-held pdxfs view -- a surface a
  compromised shell can poison.
* **`_wit_bridge_parse_type_decl`** -- parses a WIT (WebAssembly
  Interface Type) `record` declaration into a 32-byte-per-field
  schema. The buffer is produced by a userspace `wit convert`
  invocation and threaded into the kernel via
  `_wit_bridge_register_module`. The parser is a hand-written byte
  state machine with 32 field slots and a 30-byte name cap -- a shape
  that fuzzing is well suited to probe.
* **`_stdout_records_feed`** -- parses typed records written to stdout
  by a WASI module whose module registered a schema via the WIT
  bridge. Called from `_wasi_fd_mediation_write` on every WASI stdout
  byte, with the module itself writing bytes under its own control.
  Any bug here crosses from one WASI tenant's address space into the
  per-pid records ring and (because the records ring is readable by
  cap-holders) potentially into other tenants.

A fourth candidate -- **`caps_decl_loader`** -- reads kernel-mapped
ELF bytes (an in-kernel image walked by the loader after
authentication). At R141.M3 we deliberately exclude this surface
from the fuzz catalog: the loader runs *after* ELF-signature
verification, so a fuzz corpus bypassing the authentication path
would exercise a code region that is unreachable from the actual
trust boundary. A future wave covering the pre-authentication
surface (`elf/header_scan.pdx`, when it lands) is the right place to
add that entry.

The three parsers at the trust boundary each have between 400 and
1500 lines of hand-written byte-advancing state machine. Static
review has caught the obvious classes (off-by-one, OOB loads,
missing length-pre-checks); what remains are the "weird middle"
classes -- a state machine that reaches an unexpected arm when a
specific byte sequence lands at a specific cursor position. Fuzzing
is the right tool.

## 2  Non-goals

* **Not a user-space fuzzer.** The entries are reached from inside
  the kernel. A future KIND_FUZZ cap handler lands the user-space
  bridge; this milestone does not.
* **Not a crash detector.** At R141.M3 the fuzz loop *measures time*
  and *records parser return codes*. A real `(crashed_at_offset)` is
  the forward path (§8) and lives behind a trampoline that this
  milestone leaves as a stub returning 0.
* **Not a coverage tool.** No instrumentation of basic-block hits.
  The sampling signal is cycle cost per case, not path breadth. A
  coverage-driven loop lands at R141.M* once the kernel supports
  cap-held per-site hit counters (R141.M4 roadmap entry).
* **Not a persistent corpus store.** The corpus is a byte buffer the
  caller provides on each run. A future milestone binds a corpus
  file in pdxfs so a reboot preserves findings (§8).

## 3  Design

### 3.1  Entry catalog

The three fuzz entries each wrap one parser surface:

| id | shim name              | target parser                    | signature |
|----|------------------------|----------------------------------|-----------|
| 0  | `_fuzz_cmd_registry`   | `_cmd_registry_parse`            | `(buf_ptr, buf_len) -> errno` |
| 1  | `_fuzz_wit_bridge`     | `_wit_bridge_parse_type_decl`    | `(buf_ptr, buf_len) -> errno` |
| 2  | `_fuzz_stdout_records` | `_stdout_records_feed`           | `(pid, buf_ptr, buf_len) -> errno` |

Entry 1 (wit_bridge) needs two additional arguments from the target
parser (`out_schema_ptr`, `out_schema_cap`). The shim provides its
own 1056-byte scratch (`_fz_wit_scratch`), sized to the maximum WIT
schema (`WB_SCRATCH_MAX = (WB_MAX_FIELDS + 1) * 32 = 1056`), so the
fuzz corpus is pure input bytes and the output descriptor region is
owned by the shim.

Entry 2 (stdout_records) needs a `pid` argument so the parser can
resolve the per-pid schema row. In the direct 3-arg form the pid is
passed by the caller; in `_fuzz_run_corpus`, the pid is read from a
stashed BSS slot (`_fz_corpus_stdout_pid`, default 1) so the corpus
dispatch loop does not have to thread pid through its byte state
machine. A caller that wants to exercise multiple pids calls
`_fuzz_stdout_records` directly, outside the corpus runner.

### 3.2  RDTSC bracket  --  monitor hook

Every `_fuzz_<entry>` call pairs with the microbench harness
(R141.M1) via the following five-step bracket:

```asm
; 1. site_id resolved at _fz_init
mov  r13, [rip + _fz_site_<entry>_id]

; 2. begin -- rdtsc + 64-bit pack
mov  rdi, r13
call _mb_sample_begin
mov  r14, rax                           ; r14 = start_tsc

; 3. the measured window -- a single target-parser call
;    (args pre-shuffled into rdi/rsi/[rdx/rcx] per the signature)
call <target_parser>
mov  r15, rax                           ; r15 = errno

; 4. end -- rdtsc + delta + per-site min/max/sum/ring update
mov  rdi, r13
mov  rsi, r14
call _mb_sample_end

; 5. perf-sink dump -- one klog line per call
mov  rdi, r13
call _perf_sink_dump_site
```

The dump at step 5 is deliberately per-call. A userspace holder of
`KIND_MICROBENCH` with `R_MB_READ` can tail the klog ring and see
`PERF SITE name=0x<hash> count=... min=... max=... mean=...` lines
accrete in real time as the corpus is drained. A future tuning may
hoist the dump out of the measurement window (either to a periodic
timer, or deferred to `_fuzz_run_corpus`'s end-of-pass summary) if
the klog chatter dominates the fuzz throughput; at R141.M3 the
simplest observable loop is the right default.

### 3.3  Corpus format

The corpus is a single flat byte buffer. Cases are delimited by
`0x0A` (`'\n'`). Each inter-newline run is one case. A final run
without a trailing newline is still fed as a case (tail-flush
discipline). Empty cases (two newlines in a row) are dispatched with
`case_len = 0` -- all three target parsers absorb empty input
cleanly (parser-reject or zero-write OK), so this is a feature not a
bug: it exercises the "degenerate input" code path.

Example (32-byte corpus, three cases):

```
[command.one]\n[command.two]\n[command.thr
^-- case 0 (14 B) --^ ^-- case 1 (13 B) --^ ^-- case 2 (10 B, tail) --^
```

After this corpus:

* `cases_run` = 3
* `first_crash_byte_offset` = 0 (M3 stub; see §8)

### 3.4  Return codes

```
FZ_OK                = 0
FZ_ERR_BAD_ENTRY     = 0x2400     ; entry_id >= 3
FZ_ERR_CORPUS_EMPTY  = 0x2401     ; corpus_len == 0
```

Each per-entry fuzz shim returns the *target parser's errno*
verbatim. The shim does not re-code or interpret the value; a
caller that wants to classify "finding" vs "expected reject" reads
the parser's own return band from its public header.

`_fuzz_run_corpus` returns a packed u64:

```
(cases_run << 32) | first_crash_byte_offset_or_0
```

At M3 the low 32 bits are always zero. The split is forward-
compatible with the fault-trampoline landing described in §8.

### 3.5  Observability counters

Eight-slot `_fz_stats[8]`, bumped via `_fz_note`:

| slot | name                      | fires on |
|------|---------------------------|----------|
| 0    | FZ_ST_INIT_OK             | `_fz_init` tail |
| 1    | FZ_ST_CMD_OK              | `_fuzz_cmd_registry` tail |
| 2    | FZ_ST_WIT_OK              | `_fuzz_wit_bridge` tail |
| 3    | FZ_ST_STDOUT_OK           | `_fuzz_stdout_records` tail |
| 4    | FZ_ST_CORPUS_OK           | `_fuzz_run_corpus` end-of-pass |
| 5    | FZ_ST_CORPUS_BAD_ENTRY    | `_fuzz_run_corpus` entry gate |
| 6    | FZ_ST_CORPUS_EMPTY        | `_fuzz_run_corpus` empty gate |
| 7    | (reserved)                | M4 crash-trampoline hit |

Slot 7 is reserved for the fault-trampoline wave (§8).

## 4  Boot wiring

`kernel_main.pdx` inserts a single call to `_fz_init` immediately
after `_perf_sink_init`:

```asm
call _mb_init          ; R141.M1 microbench harness
call _perf_sink_init   ; R141.M2 perf-sink logging
call _fz_init          ; R141.M3 fuzz-entry harness   <-- new
call _cmd_registry_load_boot
```

`_fz_init` registers three sites via `_mb_site_register`:

* `fuzz_cmd_reg` (name_len = 12)
* `fuzz_wit_br` (name_len = 11)
* `fuzz_stdout` (name_len = 11)

The returned site_ids are stashed in BSS (`_fz_site_cmd_reg_id`,
`_fz_site_wit_br_id`, `_fz_site_stdout_id`). After this init runs,
the microbench site table reads:

| slot | name          | registered by |
|------|---------------|---------------|
| 0    | cap_invoke    | `_mb_init`    |
| 1    | fuzz_cmd_reg  | `_fz_init`    |
| 2    | fuzz_wit_br   | `_fz_init`    |
| 3    | fuzz_stdout   | `_fz_init`    |

12 slots remain in the `MB_MAX_SITES = 16` pool for future R141.M*
instrumentation sites.

`_fz_init` emits one fingerprint via `klog_s1`:

```
INFO cpu0 time: FUZZ ENTRY INIT
```

no KV body -- the three following `MICROBENCH REGISTER site_id=0x...`
lines (one per fuzz site, emitted by `_mb_site_register`) carry the
per-site metadata.

## 5  Interaction with R141.M1 (microbench)

The fuzz entries are a pure *consumer* of the microbench harness --
they call `_mb_sample_begin` / `_mb_sample_end` and never touch
`_mb_sites` or `_mb_rings` directly. The three-slot allocation from
the fixed-slot pool is the only R141.M1 state the fuzz layer
mutates, and it does so once at `_fz_init` time via the public
`_mb_site_register` entry.

Future R141.M* instrumentation sites (ctx_switch, vfs_fast_path,
klog_slow_path per the microbench harness roadmap) coexist with the
fuzz sites in the same pool. Allocation order after _fz_init is
sequential-append (`_mb_site_count_var` has advanced to 4), so a
future `_mb_init`-side `_mb_site_register` for a new instrumentation
site will land at slot 4+. The fuzz shims read their site_ids
through dedicated BSS slots and do not care about absolute slot
numbers.

## 6  Interaction with R141.M2 (perf-sink)

Each fuzz call emits one `PERF SITE ...` klog line via
`_perf_sink_dump_site`. The dump format is unchanged from R141.M2
(5-KV table: name_hash, count, min, max, mean). A userspace tail of
the klog ring reads one line per fuzz case; the mean / max per site
converges as the case count grows.

Alternative placements considered and rejected:

* **Dump once at `_fuzz_run_corpus` end.** Rejected because the
  per-case progress signal is useful: a user watching a long corpus
  drain wants to see mean cycles tick up every N cases, not get a
  terminal snapshot.
* **No dump; expose stats via `_mb_site_stats` only.** Rejected
  because that forces a cap-held caller to allocate a landing
  buffer and poll; the klog-line path is the lower-friction read.

A future tuning milestone may add a `_fuzz_set_dump_mode(mode)`
switch so a cold-run corpus can opt out of per-case dumps, but at
M3 the single mode is the simpler shape.

## 7  Future milestones

### 7.1  R141.M4  --  fault-trampoline + crash offset

Install a per-CPU fault-handler trampoline that intercepts `#PF`,
`#UD`, `#DE`, `#GP` while a fuzz window is open. On a trap:

1. Snapshot the current corpus byte offset into a per-CPU slot.
2. Longjmp back to the top of `_fuzz_run_corpus`'s dispatch arm.
3. Set the low 32 bits of the packed return to the snapshot.
4. Bump `_fz_stats[7]` (FZ_ST_TRAP_HIT, slot reserved at M3).

The trampoline needs IDT-slot cooperation with the main #PF handler
and a per-CPU "fuzz_depth" counter so nested cap_invoke→fuzz→cap_
invoke chains unwind cleanly. This is a non-trivial surface and
deferred as its own milestone.

### 7.2  R141.M5  --  persistent corpus

Bind a corpus file in pdxfs (`/perf/fuzz/corpus/<entry>.bin`), each
line one case. `_fuzz_load_corpus(entry_id)` opens the file into a
kernel-side buffer and dispatches to `_fuzz_run_corpus`. A finding
appends a line to a `findings.log` sibling with:

```
<entry_id> <crash_byte_offset> <errno> <timestamp>
```

### 7.3  R141.M6  --  KIND_FUZZ capability

Wraps the four public entries (`_fuzz_cmd_registry`,
`_fuzz_wit_bridge`, `_fuzz_stdout_records`, `_fuzz_run_corpus`) in a
cap handler so a userspace fuzz orchestrator (likely a native-ELF
process holding `R_FUZZ_DRIVE`) can drive corpus runs from
ring-3. Design chase-list:

* Op codes: FZ_OP_CMD_REG, FZ_OP_WIT_BR, FZ_OP_STDOUT, FZ_OP_RUN_CORPUS.
* Buffer landing: cap-mapped pdxfs view so the orchestrator does not
  pin kernel buffers for the corpus bytes.
* Rights: `R_FUZZ_DRIVE` for the four entries; `R_FUZZ_READ_STATS`
  for a sibling op that returns `_fz_stats` without triggering a
  parser call.

## 8  paideia-as encoder posture

Every encoder-pitfall discipline flagged in
`feedback_pdx_encoder_pitfalls` is observed in
`src/kernel/core/perf/fuzz_entries.pdx`:

* No 2-op `imul r, imm` -- the fuzz layer has no stride compute.
* No `and r, imm64` -- no mask ops at all.
* All liveness/zero tests use `cmp rN, 0` (never `test rN, rN`).
* All `pub let` string decls are single-line.
* Module basename `FuzzEntries` matches file basename
  `fuzz_entries.pdx`.
* Every label prefixed `fz_` (reserved-word discipline: `loop`,
  `if`, `let` are keywords in paideia-as).
* Return constants `FZ_OK = 0`, `FZ_ERR_BAD_ENTRY = 0x2400`,
  `FZ_ERR_CORPUS_EMPTY = 0x2401` all fit `imm32` with bit 31 clear.
* Byte load via `mov_b` with pre-zeroed destination (`xor rax, rax;
  mov_b rax, [rN + rN*1]`), the proven pattern from
  `cmd_registry_parser.pdx` / `wit_bridge.pdx`.
* Packed-return high half via `shl rax, 32` -- power-of-two shift,
  encoder-safe.
* Fingerprint tag `fz_tag_init` byte count is 15 (NUL-inclusive),
  matching `"FUZZ ENTRY INIT\0"`.
* Site-name byte counts verified: `fuzz_cmd_reg\0` = 13, `fuzz_wit_
  br\0` = 12, `fuzz_stdout\0` = 12; the name_len arguments passed to
  `_mb_site_register` are the ex-NUL lengths 12 / 11 / 11.

## 9  Testing posture

The fuzz layer at M3 does not yet have a kernel witness. The forward
witness, landing with M6 (KIND_FUZZ), will:

1. Register three canonical corpora (one per entry) in a kernel
   fixture.
2. Call `_fuzz_run_corpus` on each.
3. Assert `cases_run == expected_count` for each corpus.
4. Assert `_fz_stats[FZ_ST_INIT_OK] == 1` after boot.
5. Grep the klog ring for the three `MICROBENCH REGISTER site_id=`
   lines emitted by `_fz_init`.

Until that witness lands, the smoke acceptance for R141.M3 is the
single `FUZZ ENTRY INIT` fingerprint on every boot, and the three
`MICROBENCH REGISTER` lines (one for each fuzz site) immediately
following it in the klog ring. The fingerprint coverage script in
`tools/verify-fingerprint-coverage.sh` is the natural home for the
`FUZZ ENTRY INIT` assertion; that script's update lands with the
witness milestone (M4), not here.

## 10  File layout

New files landed by Wave UMB-W22 R141.M3:

* `src/kernel/core/perf/fuzz_entries.pdx` -- the module.
* `design/perf/fuzz-entry-points.md` -- this document.

Modified files:

* `src/kernel/boot/kernel_main.pdx` -- adds `call _fz_init` after
  `call _perf_sink_init`.

No existing file in `src/kernel/core/perf/` is changed; the fuzz
layer is a pure additive consumer of the microbench harness and the
perf-sink logging layer.
