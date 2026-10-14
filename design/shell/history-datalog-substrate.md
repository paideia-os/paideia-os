# Datalog-queryable history fact store (R127.M7)

Issue: paideia-os#2603
Wave:  UMB-W18
Lands: 2026-10-14

## 1 Why

R127.M4 (Wave UMB-W15, #2600) landed the shell-history ring: 128
entries of raw command TEXT per session, keyed by the per-session
`history_head` / `history_tail` counters on the shell_session row.
That substrate answers one question only: "what did I type?" Up-arrow,
Ctrl-R, HISTORY op surface — all three resolve by walking the text
ring and copying bytes.

A REPL that logs commands only as text leaves the audit-shaped
questions unanswered:

- "Which commands exited non-zero in the last session?"
- "Did `cat` ever run against `/etc/shadow` across any session?"
- "What was the median wall-clock latency of commands with cmd_hash
  = djb2("ls")?"

Each of those is a scan over STRUCTURED data: exit codes, timestamps,
hashes, argv descriptors. Reparsing the text ring every time is both
slow (variable-length lines, no index) and lossy (exit code is not
in the text at all).

R127.M7 lands a parallel, structured fact store: each command's
execution becomes a 64-byte row of audit-shaped fields over which a
tiny datalog-style query engine filters. The two stores stay
deliberately independent: the text ring remains the UX substrate
(up-arrow, Ctrl-R), the fact store becomes the audit substrate
(predicates, joins).

Design posture (feedback_novel_clean_design): POSIX bash's
`HISTTIMEFORMAT` plus per-shell log file is retired. The kernel
holds a structured fact table whose only reach is through direct-call
API (M7) and, in a later wave, a KIND_SHELL_SESSION cap-invoke op.
The fact store is content-addressable: a replay or `jq`-style filter
is a native capability of the kernel, not an afterthought wrapped
around a text file.

## 2 Geometry

```
  per-fact stride   = 64 bytes                            (shl 6)
  per-session ring  = 128 facts  x 64 bytes = 8 KiB       (shl 13)
  pool              = 8 sessions x 8 KiB    = 64 KiB
```

Backing storage: `_hf_pool : [u8; 65536]` in `.bss`, `@align(64)` so
the first ring (session 0) sits on a cache-line boundary and session
N's ring starts at `(N << 13)` from the pool base — no `imul r, imm`
is ever needed to address a fact slot.

Each fact is a cache-line-sized row (64 B). A line of command text
is bounded at 126 B in the text ring; a fact's structured fields are
bounded at a fixed 64 B here. Equal cardinality (128 per session)
means the two stores stay in-step without any cross-store counter
sync — eviction in one does not even approximately coincide with
eviction in the other, but neither is logically dependent on the
other's state.

## 3 Fact row shape

```
  [+0]   session_id        u32   mirrors the shell_session row id (0..7)
  [+4]   cmd_hash          u32   djb2(cmd_bytes[0..len])
  [+8]   tsc_start         u64   RDTSC captured at dispatch     (M8 fills)
  [+16]  tsc_end           u64   RDTSC captured at exit         (M8 fills)
  [+24]  exit_code         i32   process-exit code              (M8 fills)
  [+28]  argc              u32   parsed-argv count              (M8 fills)
  [+32]  argv_blob_offset  u32   offset into argv blob arena    (M8 fills)
  [+36]  flags             u32   fact-flags (0 at M7, reserved)
  [+40]  reserved         [u8; 24]  explicit-zero on write; M8 may
                                    reinterpret low 8 as pid and
                                    high 16 as cwd_hash.
```

Total: 4+4+8+8+4+4+4+4+24 = 64 bytes.

Field choices:

- `session_id` is duplicated here (also implied by the pool index)
  because cross-session queries (`by_cmd_hash`, `by_exit`) need to
  attribute matches back without passing the pool index as metadata.
- `cmd_hash` is djb2 of the command bytes stored in the TEXT ring.
  djb2 is a kernel-wide hash: cheap (shl 5 + add), has no imul-with-
  imm encoder dependency, and the collision probability on 128
  commands per session is below any threshold we actually audit.
  The hook in `_shell_history_append` computes it inline from
  `cmd_ptr` / `clamped_len` before the APPEND fingerprint fires.
- `tsc_start` / `tsc_end` are RDTSC readings around the command's
  execution. At M7 both are stored as 0; M8 captures real TSC at
  dispatch and exit respectively.
- `exit_code` is the kernel-side process-exit result, sign-extended
  to 64-bit at query-time (M8). Zero at M7.
- `argc` + `argv_blob_offset` reference a future per-session blob
  arena; both are zero at M7.
- `flags` is reserved for M8+ fact-flag discipline (e.g. truncated
  argv, backgrounded, piped).
- `reserved[24]` is zero on every write and may be reinterpreted
  by M8+ as (`pid: u64`, `cwd_hash: [u8; 16]`) without breaking the
  wire shape — the field width is contracted now so M7 queries that
  copy the whole 64-byte row forward also carry the yet-unused
  trailer.

## 4 API

Signatures (direct-call, no endpoint claim):

```
  _hf_append(session_id, cmd_hash, tsc_start, tsc_end,
             exit_code, argc_blob)                    -> errno
  _hf_query_by_session (session_id,  out_rows_ptr, out_cap) -> packed u64
  _hf_query_by_cmd_hash(cmd_hash,    out_rows_ptr, out_cap) -> packed u64
  _hf_query_by_exit    (exit_code,   out_rows_ptr, out_cap) -> packed u64
```

### 4.1 Append

Validate `session_id` via `ss_row_in_use`; else `HF_ERR_BAD_SESSION`.
Compute `slot = _hf_heads[sid] & 0x7F` and `fact_base = _hf_pool +
(sid << 13) + (slot << 6)`. Store the nine row fields (seven live +
flags zero + reserved zero) in row-order. Advance `_hf_heads[sid]`
by one; if the new value exceeds 128 bump the eviction counter
(observability only — the ring silently evicts).

Signature packing: the brief's seven field parameters (`session_id`,
`cmd_hash`, `tsc_start`, `tsc_end`, `exit_code`, `argc`,
`argv_blob_offset`) collapse to six by packing the two u32 argv
descriptors into one u64:

```
  argc_blob = (argc << 32) | argv_blob_offset
```

The six-arg call fits SysV register args (`rdi..r9`) with no on-stack
arg — avoiding the one 7-arg paideia-as encoder shape nothing in the
kernel exercises yet.

### 4.2 Query predicates

M7 ships three predicates as flat scans:

- `session(S)`:  facts with `session_id == S`  (per-sid scan)
- `cmd_hash(H)`: facts with `cmd_hash == H`    (cross-sid scan)
- `exit(E)`:     facts with `exit_code == E`   (cross-sid scan)

Each query emits matching rows into `out_rows_ptr`, newest-first
within each session, and returns a packed u64:

```
  result = (bytes_written << 32) | status
```

where `bytes_written = matched_rows * 64`. On success `status == HF_OK`
(0) so the whole word is `bytes_written << 32`. A caller recovers
`rows_written` by `shr rax, 38` (shr 32 to extract bytes, then shr 6
to divide by 64).

Error codes:

- `HF_OK                = 0`
- `HF_ERR_BAD_SESSION   = 0x1102` (alias `SS_ERR_BAD_ID`)
- `HF_ERR_POOL_FULL     = 0x1109` (reserved for M8 planner; ring
                                   silently evicts at M7)
- `HF_ERR_OUT_TOO_SMALL = 0x110A` (`out_cap < 64` with at least one
                                   candidate match)

All codes fit imm32 with bit 31 clear so `mov rax, imm32` emits the
7-byte zero-extending form.

A query with `count == 0` on `by_session`, or no matches on
`by_cmd_hash` / `by_exit`, is a SUCCESS with zero bytes written.
`HF_ERR_OUT_TOO_SMALL` fires only when there IS a candidate row to
write and the caller's buffer cannot hold even one.

## 5 Join composition semantics

M7 does NOT ship a query planner. A compound predicate like

```
  { f | session(f, 2) AND exit(f, != 0) AND tsc_start < T }
```

is composed by the caller: issue one query, filter the result inline,
and (if needed) issue a second query into a scratch buffer and
intersect by row identity. For example, the compound predicate above
is:

```
  rows = []
  ret = _hf_query_by_session(2, buf, buf_cap)
  n   = (ret >> 32) / 64
  for i in 0..n:
      row = buf[i*64 : i*64+64]
      if row.exit_code != 0 and row.tsc_start < T:
          rows.append(row)
```

A caller intersecting two queries uses `(session_id, cmd_hash,
tsc_start)` as the row identity (natural key: the hash alone is not
unique across sessions; sessions reset `_hf_heads` to 0 implicitly
on bss zero but a session can see the same hash twice if the user
re-runs a command).

This caller-composed shape keeps the kernel surface tiny (three verbs)
and defers the real planner to M8 — see §6.

### 5.1 Why not a planner at M7

Three reasons:

1. The query VOLUME at M7 is low. The shell parent's dispatch loop
   (R127.M5) is the first production caller and it queries the fact
   store only on explicit audit requests (not on every command). A
   flat scan over 1024 facts × 64 B = 64 KiB is a cache-friendly
   straight-line read; the time cost is dominated by the fingerprint
   emission around it, not the scan itself.

2. A planner at M7 would need to materialise an INDEX side (sorted
   by hash, sorted by exit code) that doubles the memory footprint
   without a landing that stresses the latency difference. We keep
   the memory footprint at 64 KiB until a workload argues otherwise.

3. The three-predicate surface is the DATALOG EDN form a planner
   would consume. Caller-side composition at M7 is the exact shape
   a planner-driven M8 will subsume without changing the on-disk
   fact row.

## 6 M8 forward path

M8 (`R127.M8`, future wave) lands four things on top of M7:

1. **Real TSC capture**: `_shell_history_append`'s hook reads
   `rdtsc` into `tsc_start`; a companion `_hf_mark_exit(cmd_hash,
   exit_code)` reads `rdtsc` into `tsc_end` and stamps the exit
   code on the most-recent live fact matching `(session_id,
   cmd_hash)` within the session. At M7 both `tsc_*` fields are
   placeholder zeros.

2. **argv blob arena**: a per-session 4 KiB arena stores the parsed
   argv bytes contiguously; `argv_blob_offset` + `argc` + `len[argc]`
   addresses them. The arena is a bump allocator with wraparound
   eviction aligned to fact ring eviction.

3. **Compound predicate planner**: a thin `_hf_select(pred_set,
   out_ptr, out_cap)` surface takes a bitmask of predicates plus
   per-predicate operands (session, hash, exit, tsc_range) and
   executes them in optimal order (most-selective first). The three
   M7 primitives remain as fallbacks the planner may call.

4. **KIND_SHELL_SESSION op**: a new op in the cap-invoke surface
   exposes `select` to userspace with capability-gated access to the
   caller's own session plus (optionally) cross-session reads for
   audit-privileged tasks.

The row shape in §3 is the WIRE M8 inherits. The 24-byte reserved
trailer gives M8 room to park a 64-bit pid plus a 16-byte cwd hash
without widening the row.

## 7 Encoder discipline

Labels prefixed `hf_` (history-facts) to stay clear of `sh_`
(shell_history), `ss_` (shell_session), `sj_` (shell_jobs) and `svc_`
(ipc/svc_broker). Encoder-pitfall posture (feedback_pdx_encoder_
pitfalls):

- `cmp rN, 0` (never `test rN, rN`)
- `shl rN, 6` (fact-stride compose)
- `shl rN, 13` (ring-base compose)
- `and rN, 0x7F` (slot-index mask; fits imm32)
- `mov rax, imm32` (never `and r11, imm64` with bit 31)
- `mov_d [mem], reg` for every u32 row field store — bare `mov
  [mem], reg` would REX.W-widen to a 64-bit store and clobber the
  neighbouring u32 field in the row
- single-line `pub let name = "..."`
- module basename `HistoryFacts` matches file basename
  `history_facts.pdx`
- fingerprint `[u8; N]` with `N = len(string) + 1` (NUL counts)

Low-32 isolation uses the `shl 32 / shr 32` round-trip pattern (as
in `superblock.pdx::sb_validate_sig_scope_`): `and r, 0xFFFFFFFF`
has bit 31 set, which `AND r64, imm32` sign-extends to all-ones and
silently no-ops the mask. Round-trip shifts are proven safe and
land in two instructions.

Stack discipline (SysV, entry `rsp%16==8`):

```
  _hf_init                1 push + 0 sub       (klog_s1 parity)
  _hf_append              3 pushes + sub rsp,48 (5 stack slots)
  _hf_query_by_session    5 pushes + sub rsp,16 (klog slot + pad)
  _hf_query_by_cmd_hash   5 pushes + sub rsp,16
  _hf_query_by_exit       5 pushes + sub rsp,16
```

For `_hf_append` the 5 stack slots carry [+0] = klog stack-arg,
[+8..+32] = 4 saved arg slots (tsc_start, tsc_end, exit_code,
argc_blob), [+40] = alignment pad. `rbx = session_id`, `r12 =
cmd_hash`, `r13 = fact_base` are the three callee-saves that span
the ring write and the fingerprint call.

## 8 Boot wiring and fingerprint discipline

`kernel_main.pdx` picks this up with one new call right after
`_shell_history_init` and before `_shell_jobs_init`:

```
  call _shell_history_init;    // R127.M4
  call _hf_init;               // R127.M7 (this file)
  call _shell_jobs_init;       // R127.M5
```

Placement rationale: `_hf_init` MUST follow `_shell_history_init` so
the audit grep sees the two history-shaped fingerprints in subsystem
order (`SHELL_HISTORY INIT OK` -> `HISTORY_FACTS INIT OK`). It
SHOULD precede `_shell_jobs_init` by convention — there is no data
dependency.

Only three "OK" fingerprints are extracted by the fingerprint-coverage
gate:

```
  HISTORY_FACTS INIT OK      (always fires on boot)
  HISTORY_FACTS APPEND OK    (fires on every _hf_append call;
                              transitively driven by the hook in
                              _shell_history_append at R127.M5+)
  HISTORY_FACTS QUERY OK     (fires on every query; no production
                              caller at M7)
```

All three are allowlisted upstream in
`tools/verify-fingerprint-coverage.sh`:

- `HISTORY_FACTS INIT OK` retires when R127.M5+ (shell parent
  dispatch loop) adds an asserting smoke-mode golden driving APPEND
  end-to-end.
- `HISTORY_FACTS APPEND OK` retires alongside `SHELL_HISTORY APPEND
  OK` when that same dispatch loop lands.
- `HISTORY_FACTS QUERY OK` retires when a KIND_SHELL_SESSION op
  surface exposing the queries lands with an asserting smoke-mode
  golden.

REJ fingerprints (`HISTORY_FACTS APPEND REJ`, `HISTORY_FACTS QUERY
REJ`) are opaque to the gate so no allowlist entry is required for
them.

## 9 Hook contract with shell_history

`_shell_history_append` (R127.M4) adds a hook between the eviction
block and the APPEND OK fingerprint:

```
  sh_ap_no_evict:
    [compute djb2(cmd_bytes[0..clamped_len]) into r14]
    [_hf_append(sid=rbx, cmd_hash=r14, 0, 0, 0, 0); errno ignored]
    [SHELL_HISTORY APPEND OK fingerprint fires]
```

Register contract: `rbx = session_id`, `r12 = cmd_ptr`, `r13 =
clamped_len` are callee-save and the hook preserves them for the
subsequent `klog_s1_x1_d1` call. `r14` and `r15` are callee-save and
free at `sh_ap_no_evict` (the eviction block above was their last
use); the djb2 round-trip uses them as hash + per-byte scratch.
`rcx` is caller-save and used as the djb2 loop index; `_hf_append`
preserves all callee-saves per SysV so none of the shell_history
state survives through a nested call issue.

The hook does NOT alter the shell_history fingerprint wire; it only
adds an additional `HISTORY_FACTS APPEND OK` emission that occurs
just before `SHELL_HISTORY APPEND OK`. Smoke-mode goldens that assert
on the shell-history line are unaffected; a later golden that asserts
on the HISTORY_FACTS line retires the APPEND allowlist entries for
both subsystems in lockstep.

The hook does NOT propagate `_hf_append`'s errno: an append failure
in the fact store (e.g. `HF_ERR_BAD_SESSION`) is observability-only
at M7 (bumps `HF_ST_APPEND_REJ`) and must not fail the shell-history
append — the two stores evolve independently and shell-history is
authoritative for the UX surface.

## 10 Testing posture

M7 ships NO new smoke-mode golden. The INIT fingerprint rides on the
existing boot wire and shows up in the serial log on every boot.
APPEND / QUERY fingerprints are not reached by any shipped caller and
are allowlisted upstream (see §8).

The first wave to retire any of the three allowlist entries is R127.M5
when the shell parent dispatch loop lands with an asserting smoke-mode
golden that mints a session, dispatches one or more commands, and
asserts on both `SHELL_HISTORY APPEND OK` and `HISTORY_FACTS APPEND
OK` in order. The QUERY allowlist entry retires separately when the
KIND_SHELL_SESSION op surface exposes the three predicates and a
smoke-mode golden drives at least one.

A future witness task (`witness_history_facts`) may drive each query
predicate directly from the kernel to retire the QUERY entry without
waiting on the cap-invoke surface. Such a witness is explicitly NOT
part of M7's scope: fingerprint allowlists exist precisely so that
substrates can land without a synthetic witness, and the real driver
(shell parent) is a short wave away.
