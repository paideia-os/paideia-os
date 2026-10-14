# Per-session history segmentation (R139.M1)

Issue: paideia-os#2639
Wave:  UMB-W20
Lands: 2026-10-14

## 1 Why

R127.M4 (Wave UMB-W15, #2600) landed the shell-history TEXT ring — a
128-entry-per-session command-string store addressed by shell_session
row-id. R127.M7 (Wave UMB-W18, #2603) landed the structured
history-facts FACT store at the same cardinality (8 sessions × 128
facts × 64 B). Both are already SEGMENTED by session_id — a
per-session scan is one `_hf_query_by_session` call away, and a
per-session count is one `_shell_history_count`.

What is NOT yet available is a cross-session PROJECTION surface. When
the user is running:

- a local kernel REPL session,
- an R137 remote-shell session,
- and one or more R135 jails, each with its own shell,

each session owns its own history ring. The sessions themselves
remain isolated — a jail's commands never land in the local session's
ring, and remote-shell's commands never land in a jail's ring. The
question R139.M1 answers is: _given a `sessions_mask` selecting any
subset of those sessions, can the user get a UNION view across their
rings and an INTERSECT view on `cmd_hash` without re-plumbing the
underlying storage?_

The answer is yes, and it needs no new storage. The projection surface
reads from `_hf_pool` and `_hf_heads` (owned by history_facts.pdx)
and writes 64-byte row copies to a caller-supplied buffer.

Design posture (`feedback_novel_clean_design`): POSIX bash's
`HISTFILE` + `history -a` plus the per-shell-pid implicit file name
is retired. The kernel owns the fact table and the projection is a
first-class capability of the OS — not a text-file post-processor.

## 2 Non-goals (deferred to M2+)

M1 is a projection-over-RAM surface. The following are explicitly
out of scope:

1. **Cross-boot persistence.** The fact ring lives in `.bss` and is
   zeroed on every warm boot. R139.M2 lands a persistence layer
   that spills per-session fact rings to a pdxfs volume at shell
   teardown and reloads on boot, so a reboot does not erase a
   session's history.

2. **A true tsc-ordered k-way merge for `_hs_project_union`.** M1
   emits per-session newest-first, concatenated in sid-ascending
   order (see §4). M2 lifts this to a bounded 8-way merge over
   `tsc_start` once R127.M8 has filled it.

3. **A KIND_SHELL_SESSION cap-invoke op surface.** M1 is direct-call
   only. The three verbs fold into cap-invoke ops in a later wave
   whose issue number is TBD.

4. **A built-in `history --all` / `history --filter cmd=<hash>`.**
   The shell parent gains these built-ins once the dispatch loop is
   ready (R127.M5+ delivery).

5. **A caller-visible row header.** The projection emits raw 64-B
   fact rows; the row's `session_id` field at `[+0]` is itself the
   per-row session tag, so the caller can post-sort or group
   without a wrapper record.

## 3 Public API

```
_hs_init() -> ()

_hs_project_union(
    sessions_mask: u64,
    out_rows_ptr: u64,
    out_cap:      u64
) -> packed u64

_hs_project_intersect(
    cmd_hash_a:   u64,
    cmd_hash_b:   u64,
    sessions_mask: u64,
    out_rows_ptr: u64,
    out_cap:      u64
) -> packed u64

_hs_session_summary(
    session_id:       u64,
    out_summary_ptr:  u64
) -> errno
```

### 3.1 Projection packed-return shape

`_hs_project_union` and `_hs_project_intersect` return the same
packed u64 as `_hf_query_by_session`:

```
result = (bytes_written << 32) | status
```

`bytes_written = written_rows * 64`. On success `status == HS_OK (0)`
so the whole word is `bytes_written << 32`; a caller recovers
`rows_written` by `shr rax, 38` (shr 32 to extract bytes, then shr 6
to divide by 64).

Error codes have bit 31 clear so no error word collides with a
success word.

### 3.2 Summary struct

`_hs_session_summary` writes a fixed 24-byte struct:

```
  [+0]   total_cmds       u64   = _hf_heads[sid]  (monotonic;
                                  includes evicted rows)
  [+8]   non_zero_exits   u64   = count of live facts with
                                  (exit_code u32 at [+24]) != 0
  [+16]  tsc_span_cycles  u64   = max(tsc_end) - min(tsc_start)
                                  over live facts with
                                  tsc_start != 0; 0 if none
```

The output is a plain POD struct — there is no `out_cap` parameter;
the caller is responsible for providing at least 24 bytes.

### 3.3 Mask semantics

`sessions_mask` is a 64-bit value where bit `N` set (i.e.
`(sessions_mask >> N) & 1 == 1`) means "include session N". Bits
above `HS_SESSIONS = 8` are silently ignored (the implementation
iterates `sid` in `[0, 8)` only).

A bit set for a session that was never minted or never ran a command
is harmless — the per-session count via `min(_hf_heads[sid], 128)`
naturally returns 0 and that session contributes zero rows. No
`HS_ERR_BAD_SESSION` is raised for a mask-filter miss. The error
code is reserved for `_hs_session_summary` where the caller named
one specific session by id.

## 4 Union order at M1

The brief asks for "newest-first across the union". A true merge
requires an absolute timestamp per row; the fact row carries
`tsc_start` at `[+8]`, but R127.M7 ships with `tsc_start == 0` on
every row and leaves M8 to fill it from `RDTSC` at command dispatch.

Three implementation options:

| Option | Pre-M8 behaviour | Post-M8 behaviour | Code shape |
|---|---|---|---|
| A. Per-session newest-first, sids ascending | Deterministic | Lossy (ignores timestamps) | Simple double loop |
| B. tsc-based bounded k-way merge | Degenerates to A (all keys tie at 0) | Correct global newest-first | 8-way heap or linear-pick |
| C. tsc-based k-way merge with sid as tiebreak | Equal to A pre-M8 | Correct, with stable order on ties | 8-way linear-pick |

M1 lands option A. Rationale:

- Pre-M8 (today) all three options produce the SAME output on the
  common path (every tsc_start is 0 → the merge collapses to a
  concatenation in whatever tiebreak order the merge uses).
- Option A is the simplest code (one outer sid loop, one inner slot
  loop) and the fewest encoder pitfalls (no cross-session
  prioritisation).
- Option C is the right answer post-M8 and is the M2 retirement
  target for this module. The surface — same three verbs — stays
  stable; only the inner `_hs_project_union` body is replaced.

The emit order post-M1 is therefore documented as:

```
  for sid in [0, 8):
    if (sessions_mask >> sid) & 1 == 0: continue
    for i in [0, min(_hf_heads[sid], 128)):
      slot  = (_hf_heads[sid] - 1 - i) & 0x7F
      emit  = _hf_pool[sid * 8192 + slot * 64 .. +64]
```

A caller who needs real "newest-first across the union" pre-M8 can
sort the output buffer by `tsc_start` client-side; after M8 lands
and R139.M2 switches to option C, that sort becomes a no-op.

## 5 Intersect semantics

`_hs_project_intersect` is a datalog disjunction on `cmd_hash` with
a session filter:

```
  { row | row ∈ facts
        AND (row.cmd_hash = cmd_hash_a OR row.cmd_hash = cmd_hash_b)
        AND (sessions_mask >> row.session_id) & 1 = 1 }
```

The two-hash shape covers the common pattern "did `<cmd>` or its
alias run?" (e.g. `djb2("ls")` and `djb2("ll")`) without forcing
two separate queries + a client-side union. To query a single hash,
the caller passes the same value as both arguments:

```
_hs_project_intersect(h, h, mask, out, cap)
```

Row ordering mirrors `_hs_project_union`: per-session newest-first,
sids ascending. The hash compare uses the row's `cmd_hash` field
(u32 at `[+4]`) loaded as a u64 and isolated via `shr 32` — the
high 32 of the full u64 at `[row+0]` carries the hash because the
row is laid out as `{sid: u32, hash: u32}` at `[+0..+8]`.

Caller-passed hashes are isolated to low 32 via `shl 32 / shr 32`
round-trip at function entry and stashed on the stack so the inner
compare is two memory loads with no imm64 encoder risk.

## 6 Summary semantics

`_hs_session_summary` validates `session_id` via `ss_row_in_use`
(the single-session gate shared with every other svc.* verb). The
three output fields:

- **total_cmds** is the MONOTONIC head counter `_hf_heads[sid]`, not
  the live count `min(head, 128)`. Rationale: the caller is asking
  "how many commands has this session ever run?", not "how many
  are still in the ring?". The eviction behaviour of the ring is
  the ring's concern.
- **non_zero_exits** is a count over LIVE facts (`min(head, 128)`).
  Pre-M8 all `exit_code` fields are 0 so this reads back as 0; post-M8
  it tallies real non-zero exits.
- **tsc_span_cycles** is `max(tsc_end) - min(tsc_start)` over live
  facts where `tsc_start != 0`. The non-zero guard excludes pre-M8
  rows whose `tsc_start` is still at the default of 0 — otherwise
  the min would latch at 0 and the span would be meaningless.

If no row has `tsc_start != 0`, or `max(tsc_end) == 0`, or `min >
max` (inconsistency), the span is 0. A caller may distinguish
"nothing ran" from "pre-M8 run" by cross-checking `total_cmds > 0`
against `tsc_span_cycles == 0`.

## 7 Return codes

```
  HS_OK                 = 0
  HS_ERR_BAD_SESSION    = reuse SS_ERR_BAD_ID = 0x1102
  HS_ERR_OUT_TOO_SMALL  = 0x1F00
```

Band audit (2026-10-14):

```
  grep -rnE '0x1F00\b' src/kernel/   -> zero hits.  Clean band.
```

The 0x1F00 band is reserved for the HistorySegmentation module; the
next three codes 0x1F01..0x1F03 are reserved for M2's persistence
errors (write-fail, read-fail, version-mismatch).

## 8 Stack discipline (SysV, entry rsp%16==8)

```
  _hs_init                1 push + 0 sub       (klog_s1 parity)
  _hs_project_union       5 pushes + sub rsp,16  (klog + orig_mask save)
  _hs_project_intersect   5 pushes + sub rsp,32  (klog + 2 hash + orig_mask + pad)
  _hs_session_summary     5 pushes + sub rsp,16  (klog + total_cmds save)
```

All four functions land `rsp%16 == 0` at every nested call site.

## 9 Encoder pitfalls (prevented)

1. **No `bt rN, rM`.** The sessions_mask walk is a rolling-mask-plus-
   sid-counter: at each outer iter `and r10, 1` tests the low bit,
   then `shr rbx, 1; add r15, 1` advances. No bit-test instruction
   is required.
2. **No `shl rN, cl`.** All shifts are imm8 shifts (1, 6, 13, 32).
3. **No `imul r, imm`.** All power-of-two strides use `shl` with the
   log2 directly (slot=6, ring=13, u64=3).
4. **No `and r11, imm64` with bit 31 set.** The u32 hash isolation
   is a `shl 32 / shr 32` round-trip; `mov rax, imm32` writes error
   codes.
5. **No `test rN, rN`.** All zero probes are `cmp rN, 0`.
6. **No `mov_d [reg + reg*1 + off], reg`.** All u64 writes use
   `mov [reg + imm8], reg`. The summary struct is three u64 stores
   so no u32-sized target.
7. **No `test r, imm` with bit 31 set.** Not used.
8. **No multiline `pub let name = "..."`.** All fingerprint tags
   are single-line.
9. **Module basename matches file basename.** `HistorySegmentation`
   ↔ `history_segmentation.pdx`.
10. **Fingerprint tag array sized `len(string) + 1`** (NUL counts).

## 10 Boot wiring

```
  call _hf_init;              // R127.M7
  call _hs_init;              // R139.M1 (this file)
  call _shell_jobs_init;      // R127.M5
```

`_hs_init` runs AFTER `_hf_init` so the audit grep sees the three
history-shaped fingerprints in subsystem order:

```
  SHELL_HISTORY INIT OK
  HISTORY_FACTS INIT OK
  HISTORY_SEG INIT OK
```

No data dependency on `_shell_jobs_init`; the convention keeps all
history-shaped substrates in one contiguous block.

## 11 Observability

`_hs_stats : [u64; 8]` carries the stats pool:

```
  HS_ST_INIT_OK        = 0
  HS_ST_UNION_OK       = 1
  HS_ST_UNION_REJ      = 2
  HS_ST_INTERSECT_OK   = 3
  HS_ST_INTERSECT_REJ  = 4
  HS_ST_SUMMARY_OK     = 5
  HS_ST_SUMMARY_REJ    = 6
  (slot 7 reserved)
```

The `hs_note` helper (local to the module) is a bounded load-inc-
store on `_hs_stats[slot < 8]`. The stats pool follows the same
shape as `_hf_stats` / `_shell_history_stats` so a unified
observability witness in a future wave can treat all three uniformly.

## 12 M1 → M2 split

**M1 (this wave):** in-RAM projection over the existing fact ring.
Three verbs, direct-call API, no persistence, no cap-invoke
surface, concatenation-order union.

**M2 (future wave):**

1. Persistence: at shell teardown (R127.M6 session_teardown
   discipline) write the session's live fact rows to a
   `/var/history/<sid>.pdxfacts` file on pdxfs. On boot, reload
   from any present files back into `_hf_pool` so a reboot does
   not erase a session's history. Add two new error codes
   `0x1F01` (write-fail) and `0x1F02` (read-fail).
2. True tsc-ordered k-way merge in `_hs_project_union` once R127.M8
   fills `tsc_start`. The public API is unchanged; the inner body
   is replaced.
3. A KIND_SHELL_SESSION op surface exposing all three verbs to
   userspace, with the sessions_mask carried in the op payload.
   Add fingerprint allowlist retirements for all four
   `HISTORY_SEG *` tags.

## 13 Audit grep patterns

```
  # Where the module writes and how the band is used:
  grep -rnE '\bHS_(OK|ERR_[A-Z_]+)\b'  src/kernel/
  grep -rnE '0x1F0[0-9A-F]\b'          src/kernel/
  grep -rnE '_hs_(project|session)_'   src/kernel/

  # Fingerprint shape and coverage:
  grep -rn  'HISTORY_SEG '              src/kernel/
  grep -n   'HISTORY_SEG'               tools/verify-fingerprint-coverage.sh
```

## 14 Closing map

```
  Closes paideia-os#2639.
```
