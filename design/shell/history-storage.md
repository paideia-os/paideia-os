# Shell history storage (parser-tier) — R229.M5

Parent: paideia-os#2493. Milestone: paideia-os#2723.

## 1 Why

A REPL evaluator needs a bounded, in-process ring of the turns it
has dispatched, with per-turn provenance rich enough that:

- Ctrl-R (reverse incremental search) can locate a prior turn by
  substring and recall its command text.
- The `history` built-in can render the recent-turn window with
  command text, result code, cap-env snapshot, and timestamp.
- Up-arrow / down-arrow in READLINE scrolls through the recent
  commands.
- A later pdxfs CoW-persistence hook (R229.M5.1) can serialise
  the ring to a per-user history file, scoped by the user's
  cap env.

R229 already landed the dispatch loop (R229.M1 kernel-side,
`src/kernel/core/shell/repl_loop.pdx`), the session-scoped bindings
(R229.M2, `session_env.pdx`), the type scheme store (R229.M3,
`type_env.pdx`), and the per-session job table (R229.M4,
`job_control.pdx`). R229.M5 (this landing) adds the fifth per-
session substrate: the committed-turn log.

### 1.1 Posture (novel + clean design)

The parent brief originally held R229.M5 for "lexical nested
scopes". The novel-clean-design directive
(`feedback_novel_clean_design`) retires the POSIX bash
`HISTFILE`-shaped design in favour of a kernel-cooperative
substrate anchored on the session, not on a file descriptor. The
R229.M5 slot is re-scoped to history storage per
paideia-os#2723, taking the richer provenance (cap-env mask,
result code, FNV-1a 64 cmd_hash, rdtsc timestamp, result summary
inline) that the user's cap-env + capability-row typing (R224.M4)
unlocks. "Lexical nested scopes" relocates to a later R229 slot
when the shell's lexical-scope semantics come back into focus
over the finalized session-env + type-env + history tier.

### 1.2 Boundary with R127.M4 (kernel-side shell_history)

R127.M4 (paideia-os#2600, `src/kernel/core/svc/shell_history.pdx`)
lands a 128-slot ring on the KERNEL side under the
`shell_session` row, reachable via KIND_SHELL_SESSION cap-invoke
ops. Its 128-byte entries record `(len u16, cmd_bytes u8[126])`.

R229.M5 lands a parallel user-space ring under the shell
evaluator's satellite library, with a RICHER 128-byte record:
turn_id, rdtsc timestamp, FNV-1a 64 cmd_hash, result_code,
flags, cap_env_mask, 64-byte cmd_inline, 16-byte summary_inline,
plus 16 bytes reserved for M5.1+ (pdxfs persist offset + per-turn
ipc fingerprint).

The two tiers co-exist:

| aspect                | R127.M4 (kernel)                | R229.M5 (user, THIS)             |
|-----------------------|---------------------------------|----------------------------------|
| session binding       | per-session (`shell_session`)   | session-flat (M5)                |
| reach                 | KIND_SHELL_SESSION cap-invoke   | direct linker call               |
| record size           | 128 B (`len u16 + bytes[126]`)  | 128 B (richer; see §2)           |
| provenance            | command text only               | +hash +ts +result +cap_env +sum  |
| timestamp             | not stored                      | rdtsc u64                        |
| cap_env snapshot      | not stored                      | u32 cap-mask                     |
| result code           | not stored                      | u8                               |
| result summary        | not stored                      | 16 B inline                      |
| persistence           | not planned at M4               | pdxfs CoW at M5.1 (deferred)     |

R229.M5.1 pdxfs persistence may reconcile the two tables; at raw
M5 they are independent.

### 1.3 Posture against POSIX bash

POSIX bash's `HISTFILE` is a text file on disk, written at shell
exit (or on `history -w`), with per-line entries sometimes
annotated by a `HISTTIMEFORMAT`-formatted timestamp comment. The
file is unauthenticated, has no cap-env provenance, and offers
no durable duplicate-detection seed.

This landing retires that design in favour of:

- An in-process ring at R229.M5 (THIS landing).
- A pdxfs-backed CoW file at R229.M5.1, mediated by a kernel
  bridge, carrying the full 128-byte record with cap-env
  provenance.
- Ctrl-R dispatches to `_h_search_substring` directly — no
  separate `.inputrc`-level config, no `HISTCONTROL` env var; the
  substrate's deduplication is the FNV-1a 64 cmd_hash field,
  consumed by an opt-in M5.1 `history --unique` flag.

## 2 Record layout

The History record (`H_RECORD_BYTES = 128`):

```
offset  size  field
------  ----  --------------------------------------------------------
  0x00   4   magic           u32   'HIST' (0x54534948 LE)
  0x04   4   turn_id         u32   1-based session-scoped turn id
  0x08   8   timestamp_us    u64   rdtsc sample (combined edx:eax)
  0x10   8   cmd_hash        u64   FNV-1a 64 of full command text
  0x18   1   result_code     u8    low 8 bits of caller-supplied code
  0x19   1   flags           u8    reserved; 0 at M5
  0x1A   2   reserved        u16   zeroed
  0x1C   4   cap_env_mask    u32   caller-supplied cap-env snapshot
  0x20  64   cmd_inline      u8[64] bytes 0..min(cmd_len, 64), 0-padded
  0x60  16   summary_inline  u8[16] bytes 0..min(summary_len, 16), 0-pad
  0x70   8   reserved        u64   zeroed; reserved for M5.1+ (pdxfs
                                   persist offset)
  0x78   8   reserved        u64   zeroed; reserved for M5.1+ (per-turn
                                   ipc fingerprint)
```

Total: 128 B.

Pool: `_h_entries : [u8; 16384]` (`H_POOL_SLOTS = 128` ×
`H_RECORD_BYTES = 128`) @align(8) in `.bss`.

Scalars:

- `_h_entry_count : u64` — monotonic session-lifetime turn
  counter. Equals `turn_id` of the most recently appended
  record. Serves `_h_count()` return and the `turn_id - 1` basis
  for `_h_append`. Never decremented.
- `_h_cursor : u64` — next write slot (0..127; wraps). Equals
  `_h_entry_count & 127` by construction, held as a scalar for
  cache locality on the append fast-path.

Record stride 128 is a power of two; slot addressing uses `shl
rN, 7` directly (no `(idx<<5) + (idx<<4)` 48-stride dance from
`job_control.pdx` / `cmd_registry.pdx`; never 2-op `imul r,
imm`).

Magic `'HIST'` little-endian:
- byte 0 = 'H' = 0x48
- byte 1 = 'I' = 0x49
- byte 2 = 'S' = 0x53
- byte 3 = 'T' = 0x54
- u32 value = `0x54534948`

Storing `0x54534948` to memory LE yields on-disk bytes 0x48, 0x49,
0x53, 0x54 — reads as `"HIST"` under a sequential hex dump,
matching the FourCC-as-identifier convention established by
`FILT` (R223.M3), `SORT`/`GRPS`/`REDU` (R223.M4), `JOBS` (R229.M4),
and `PLAM` (R224.M6).

### 2.1 Ring semantics

At cold start: `_h_entry_count = _h_cursor = 0`.

On the N-th append (1-based):

```
slot_idx     := _h_cursor                       // = (N - 1) & 127
turn_id      := _h_entry_count + 1              // = N
write slot_idx-th record (128 bytes)
_h_entry_count := _h_entry_count + 1            // = N
_h_cursor      := (_h_cursor + 1) & 127         // = N & 127
```

Live-turn range after N appends:
- if N ≤ 128: turn_id ∈ `[1, N]` (nothing evicted).
- if N > 128: turn_id ∈ `[N - 127, N]` (turns 1..N-128 evicted).

Combined lower bound: `max(1, N - 127)`.

`_h_get_turn(t)` admits iff `t > 0 AND t ≤ N AND (N - t) < 128`.
`_h_search_substring` walks `t` from `start_turn` (clamped to N)
down to `max(1, N - 127)`.

### 2.2 Acceptance scenario (100-turn session)

Issue scope: "100-turn session persists to CoW file; `C-r` search
finds turn 42."

At raw M5 (pdxfs persistence deferred to M5.1), the acceptance is
satisfied by the in-memory ring:

- N = 100 appends, with turn 42's command text containing the
  marker substring `"turn-42"`.
- `_h_count()` returns 100.
- Lower bound = `max(1, 100 - 127) = 1`; upper = 100. All 100
  turns are in the live-ring window.
- Slot index for turn 42 = `(42 - 1) & 127 = 41`.
- `_h_get_turn(42, buf, 128)` returns `(128 << 32) | H_OK` with
  buf's 128 bytes = turn 42's record.
- `_h_search_substring("turn-42", 7, 0, &ids, 1)` walks `t` from
  100 down to 1, hits slot 41 whose cmd_inline[0..64] starts with
  `"turn-42-<rest>"`, writes 42 to `ids[0]`, and returns `(1 <<
  32) | H_OK`.

The pdxfs CoW persistence (`_h_persist`) lands at R229.M5.1 to
satisfy the "persists to CoW file" phrasing of the acceptance
scope. The acceptance behaviour that reaches a user keystroke —
"`C-r` search finds turn 42" — is satisfied at raw M5 by the
substrate alone.

## 3 Public API

| Entry point                                                              | Signature                                                           |
|--------------------------------------------------------------------------|---------------------------------------------------------------------|
| `_h_init()`                                                              | `() -> ()`                                                          |
| `_h_append(cmd_ptr, cmd_len, result_code, cap_env_mask, summary_ptr, summary_len)` | `(u64, u64, u64, u64, u64, u64) -> u64` (errno)           |
| `_h_get_turn(turn_id, out, out_cap)`                                     | `(u64, u64, u64) -> u64` (packed `(bytes_written << 32) \| status`) |
| `_h_search_substring(needle, needle_len, start_turn, out_turn_ids, max_results)` | `(u64, u64, u64, u64, u64) -> u64` (packed `(result_count << 32) \| status`) |
| `_h_count()`                                                             | `() -> u64`                                                         |

Signatures frozen at M5 so R229.M5.1+ layers extensions
(`_h_persist` with a pdxfs path; `_h_restore` with the reverse)
without an ABI break.

### 3.1 `_h_append` semantics

```
_h_append(cmd_ptr, cmd_len, result_code, cap_env_mask,
          summary_ptr, summary_len) -> errno
```

Allocates slot `_h_cursor`; writes a 128-byte History record;
bumps `_h_entry_count` and advances `_h_cursor := (cursor + 1) &
127`.

Guards:
- `cmd_ptr != 0 AND cmd_len > 0` → `H_ERR_BAD_CMD` (0x5100).
- `summary_len > 0 ⇒ summary_ptr != 0` → `H_ERR_BAD_SUMMARY`
  (0x5101). A caller with no summary passes `summary_len = 0`
  with any `summary_ptr` (summary_inline fills with 16 zero
  bytes).

Writes (in order; see §4 for register discipline):
- `magic := 'HIST'` u32 at `[slot+0]`.
- `turn_id := entry_count + 1` u32 at `[slot+4]`.
- `timestamp := rdtsc` u64 at `[slot+8]`.
- `result_code` u8 (low 8 of caller input) at `[slot+24]`.
- `flags := 0` u8 at `[slot+25]`.
- `reserved := 0` u16 (two u8 writes) at `[slot+26..+28]`.
- `cap_env_mask` u32 (low 32 of caller input) at `[slot+28]`.
- `cmd_inline` 64 B at `[slot+32]`: copy
  `min(cmd_len, 64)` from `cmd_ptr`, zero-pad to 64.
- `summary_inline` 16 B at `[slot+96]`: copy
  `min(summary_len, 16)` from `summary_ptr`, zero-pad to 16.
- `reserved := 0` u64 at `[slot+112]` and `[slot+120]`.
- `cmd_hash := FNV-1a 64(cmd_ptr, cmd_len)` u64 at `[slot+16]`
  (inlined FNV; see §4.1).

Then `_h_entry_count += 1` and `_h_cursor := (_h_cursor + 1) &
127`.

Returns `H_OK` on success.

### 3.2 `_h_get_turn` semantics

```
_h_get_turn(turn_id, out, out_cap) -> packed_u64
```

Validates:
- `out != 0` → `H_ERR_BAD_OUT_PTR` (0x5104).
- `out_cap >= 128` → `H_ERR_OUT_TOO_SMALL` (0x5103).
- `turn_id != 0` → `H_ERR_BAD_TURN` (0x5102).
- `turn_id <= entry_count` → `H_ERR_BAD_TURN`.
- `entry_count - turn_id < 128` (not evicted) → `H_ERR_BAD_TURN`.

Computes `slot_idx := (turn_id - 1) & 127`; copies 128 B via 16
u64 moves from `_h_entries + slot_idx * 128` to `out`.

Returns `(128 << 32) | H_OK` on success.

### 3.3 `_h_search_substring` semantics

```
_h_search_substring(needle, needle_len, start_turn,
                    out_turn_ids, max_results) -> packed_u64
```

Validates:
- `needle != 0` → `H_ERR_BAD_NEEDLE` (0x5105).
- `needle_len ∈ [1, 64]` → `H_ERR_BAD_NEEDLE`.
- `out_turn_ids != 0` → `H_ERR_BAD_OUT_PTR` (0x5104).

Clamps `start_turn` to `entry_count` (or uses `entry_count` if
`start_turn == 0`). Determines `eff_end := max(1, entry_count -
127)`.

Walks `t` from `eff_start` down to `eff_end` (inclusive). For
each slot whose `magic == 'HIST'`, scans `cmd_inline[0..64]` for
the first substring match of `needle[0..needle_len]`. The scan
cursor `j` sweeps `[0, 65 - needle_len)`; the inner cmp `k` sweeps
`[0, needle_len)`. On a full-match hit, writes `turn_id` as u32
to `out_turn_ids[result_count * 4]`, bumps `result_count`, and
breaks the inner scan (next slot).

Returns `(result_count << 32) | H_OK`. `result_count = 0` is a
valid return — no error, just no matches in the live window.

Walks STOP when:
- `t < eff_end` (walked past oldest live turn), or
- `result_count >= max_results` (caller buffer full).

Walks SKIP when `magic != 'HIST'` (never-used slot). A zero `max_
results` returns `(0 << 32) | H_OK` without walking.

### 3.4 `_h_count` semantics

Returns `_h_entry_count` (session-lifetime monotonic turn
count). The count is NOT the live-ring count — a 300-turn
session returns 300 even though only turns 173..300 are
retrievable through `_h_get_turn`.

## 4 Encoder discipline

### 4.1 Pure-leaf shape

All five entry points are pure leaves (zero nested CALL). FNV-1a
64 is INLINED in `_h_append` (10 insns) rather than factored to a
helper, keeping the function a leaf and avoiding the nested-CALL
alignment pad.

| Function              | Pushes | Scratch | rsp%16 at ret |
|-----------------------|--------|---------|---------------|
| `_h_init`             | 0      | 0       | 8 (pure leaf) |
| `_h_append`           | 6 × 8  | 0       | 8 (pure leaf) |
| `_h_get_turn`         | 0      | 0       | 8 (pure leaf) |
| `_h_search_substring` | 6 × 8  | 0       | 8 (pure leaf) |
| `_h_count`            | 0      | 0       | 8 (pure leaf) |

### 4.2 Stride

Stride 128 is a power of two:
```
mov rax, idx                  // 0..127
shl rax, 7                    // * 128
lea r11, [rip + _h_entries]
add rax, r11                  // slot_addr
```

Never 2-op `imul r, imm` for this stride.

Slot-index mask `0x7F = 127` fits imm8 so `and rax, 127` is safe.

### 4.3 Encoder pitfalls

- No `test rN, rN` — every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64` — slot-idx mask `and rax, 127` fits imm8;
  no other mask is wider.
- No 2-op `imul r, imm` — stride is `shl rN, 7`.
- No multiline `pub let = "..."` — single-line justifications.
- Module basename `History` matches `history.pdx`.
- Labels prefixed `h_`:
  - `h_ini_` — `_h_init`
  - `h_app_` — `_h_append`
  - `h_gt_` — `_h_get_turn`
  - `h_srch_` — `_h_search_substring`
  - `h_cnt_` — `_h_count`
- Byte loads via `xor rax, rax; mov_b rax, [base + disp]`.
- Byte stores via `mov_b [dst + disp], reg`.
- u32 loads via `xor rax, rax; mov_d rax, [base + disp]`.
- u32 stores via `mov_d [dst + disp], reg`.
- u64 stores via plain `mov [dst + disp], reg`.
- `.bss` writes via `lea r11, [rip + sym]; mov [r11 + disp], reg`.

### 4.4 Inline-byte-copy destination base

`cmd_inline` lives at `[slot + 32]`; `summary_inline` at
`[slot + 96]`. The copy loops use the precomputed-destination
idiom (precedent: `session_env.pdx` L440 note; `job_control.pdx`
`_jc_submit` command_inline copy):

```
mov rsi, r9         ; slot_addr
add rsi, 32         ; cmd_inline base (or 96 for summary)
...
mov_b [rsi + r10 * 1], rax
```

sidestepping the `mov_b [reg + reg + imm], reg` encoder gap.

### 4.5 rdtsc timestamp

```
rdtsc                 ; edx:eax = TSC (upper 32 of rax, rdx zeroed)
shl rdx, 32
or  rax, rdx
mov [r9 + 8], rax     ; store at slot[+8]
```

Matches the `pdxfs_lite/create.pdx` atime/mtime/ctime precedent.
The tsc_hz divisor is caller responsibility; this module stores
the raw TSC. A later R229.M5.4 wire-up populates a per-session
tsc_hz scalar from the kernel's calibration and the shell-side
renderer converts to µs for `history` output.

### 4.6 FNV-1a 64 inline

```
mov rax, 0xCBF29CE484222325   ; h = fnv_offset_basis (imm64)
mov rcx, 0x100000001B3        ; fnv_prime (held across loop)
xor r10, r10                  ; i = 0
h_app_fnv_loop:
cmp r10, rbp                  ; i < cmd_len?
jae h_app_fnv_done
xor r11, r11
mov_b r11, [rbx + r10 * 1]    ; byte load
xor rax, r11                  ; h ^= byte
xor rdx, rdx                  ; clear mul high half
mul rcx                       ; rdx:rax = rax * fnv_prime
add r10, 1
jmp h_app_fnv_loop
h_app_fnv_done:
mov [r9 + 16], rax            ; cmd_hash u64
```

The `mul rcx` is the one-op unsigned-mul form (writes rdx:rax
from rax * rcx), distinct from the 2-op `imul r, imm` pitfall.

## 5 Error band

`0x5100..0x5105` (six codes); `0x5106..0x51FF` reserved for M5.1+.

| Code     | Name                   | Meaning                                                  |
| -------- | ---------------------- | -------------------------------------------------------- |
| `0`      | `H_OK`                 | operation succeeded                                      |
| `0x5100` | `H_ERR_BAD_CMD`        | `_h_append`: `cmd_ptr == 0` OR `cmd_len == 0`            |
| `0x5101` | `H_ERR_BAD_SUMMARY`    | `_h_append`: `summary_len > 0 AND summary_ptr == 0`      |
| `0x5102` | `H_ERR_BAD_TURN`       | `_h_get_turn`: `turn_id` outside the live-ring window    |
| `0x5103` | `H_ERR_OUT_TOO_SMALL`  | `_h_get_turn`: `out_cap < 128`                           |
| `0x5104` | `H_ERR_BAD_OUT_PTR`    | `out == 0` (`_h_get_turn`) OR `out_turn_ids == 0`        |
| `0x5105` | `H_ERR_BAD_NEEDLE`     | `_h_search_substring`: `needle == 0`, `len == 0`, OR > 64 |

Reserved slots at `0x5106..0x51FF`:
- `H_ERR_PERSIST_UNAVAILABLE` (M5.1 pdxfs bridge).
- `H_ERR_CAP_DENIED` (M5.2 KIND_HISTORY cap-invoke surface).
- `H_ERR_FS_FULL` (M5.1 per-user-history-file quota).
- `H_ERR_SCHEMA_VERSION_MISMATCH` (M5.1 persisted-ring load).

### 5.1 Band disjointness

`0x5100..0x51FF` is disjoint from every other parser-tier packed-
status band in the paideia-os tree. The parent brief listed 0x4F00
(R222.M8 describe serialisation) and 0x5000 (R224.M6 PipelineLambda)
as reservations; R229.M5 skips to 0x5100 to keep the disjointness
proof simple against both landed-this-wave (`0x5000..0x50FF`,
PipelineLambda, R224.M6) and still-reserved (`0x4F00..0x4FFF`,
describe serialisation, R222.M8) kilo-step boundaries.

Grep confirmation at R229.M5 landing time:

```
grep -rE '0x510[0-5]\b' paideia-os/{src,tools,design,tests}
  -> no packed-status hits outside this file + caps.decl +
     history.pdx. (The TPM / wifi driver 0x510x constants and
     the SLOG_INIT_MARK 0x510C sentinel in src/kernel/core/
     semterm/session_log.pdx are MMIO offsets / init-marker
     constants, not status codes; the grep uses `0x510[0-5]\b`
     and will not match them.)
```

## 6 Interactions

- **R229.M1 (`repl_loop.pdx`, kernel)** — drives per-cycle state;
  does NOT touch History at M1. R229.M5-dispatch (not landed
  here; follows at the kernel-side REPL-dispatch layer) wires
  the EVAL → WRITING tick to call `_h_append` on turn commit.
- **R229.M2 (`session_env.pdx`)** — holds the session's bindings.
  No direct interaction with History; `let x = ...` writes
  through SessionEnv unchanged and the command text flows
  separately into History.
- **R229.M3 (`type_env.pdx`)** — holds type schemes. No direct
  interaction with History.
- **R229.M4 (`job_control.pdx`)** — holds the in-flight job
  table. No direct interaction with History; a background
  command (`cmd &`) flows into BOTH `_jc_submit` AND `_h_append`
  at the R229.M5-dispatch layer; the two substrates capture
  orthogonal state (job lifecycle vs committed-turn log).
- **R127.M1 (`shell_session.pdx`)** — `session_id` is NOT part of
  the History record at M5 (the pool is a flat 128-slot ring).
  Multi-session isolation partitions at the dispatch layer; raw
  M5 is session-flat so the 100-turn acceptance test runs
  against a single session.
- **R127.M4 (`shell_history.pdx`, KERNEL side)** — kernel-side
  history substrate under KIND_SHELL_SESSION. R229.M5.1 pdxfs
  persistence may reconcile the two tables; at raw M5 they
  co-exist with disjoint reach.

## 7 Fingerprint matrix

```
HIST APPEND OK              per-turn     _h_append H_OK path
HIST APPEND BAD_CMD         per-turn     _h_append cmd_ptr/cmd_len guard
HIST APPEND BAD_SUMMARY     per-turn     _h_append summary_ptr guard
HIST GET_TURN OK            per-call     _h_get_turn H_OK path
HIST GET_TURN BAD_TURN      per-call     _h_get_turn turn-id guard
HIST SEARCH HIT             per-call     _h_search_substring, result_count > 0
HIST SEARCH MISS            per-call     _h_search_substring, result_count = 0
HIST SEARCH BAD_NEEDLE      per-call     _h_search_substring needle guard
```

M5 does NOT itself emit fingerprints — the module stays pure
parser-tier, and the `klog_s1_*` wrapper lives at the R229.M5-
dispatch kernel-side REPL layer. The eight tags above allowlist
to retire at R229.M5.3 when the asserting smoke-mode goldens
(`tests/fingerprints/history.golden`) land alongside the 100-turn
proptest harness (`tests/proptest_history.pdx`).

## 8 Forward path

| wave         | adds                                                                      |
|--------------|---------------------------------------------------------------------------|
| R229.M5.1    | pdxfs CoW persistence hook `_h_persist(path_ptr, path_len)`               |
| R229.M5.2    | `_h_get_turn_all` variant that includes evicted turns via a cold-cache    |
|              | pdxfs read                                                                |
| R229.M5.3    | fingerprint goldens + 100-turn proptest harness                           |
| R229.M5.4    | tsc_hz calibration wire for the renderer-side µs conversion               |
| R229.M6      | cross-session history query (per-user profile scope)                      |

## 9 References

- paideia-os#2493 — R229 REPL evaluator umbrella.
- paideia-os#2723 — R229.M5 History (THIS landing).
- paideia-os#2600 — R127.M4 kernel-side shell_history substrate.
- paideia-os#2722 — R229.M4 JobControl (sibling substrate).
- paideia-os#2721 — R229.M3 TypeEnv (sibling substrate).
- paideia-os#2720 — R229.M2 SessionEnv (sibling substrate).
- paideia-os#2719 — R229.M1 REPL loop substrate.
- `design/shell/repl-loop-scaffold.md` — umbrella design.
- `design/shell/shell-history-substrate.md` — R127.M4 kernel-
  side design (parallel kernel-tier substrate).
- `design/shell/job-control.md` — R229.M4 sibling design (closest
  structural analogue; both are session-anchored rings in the
  parser-tier satellite).
- `tools/user/libpdx-pds-parser/src/history.pdx` — the landed
  module.
- `tools/user/libpdx-pds-parser/caps.decl` — band + catalogue
  entries (grep for `0x5100`).
