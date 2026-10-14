# WASI stdout → typed-record conversion — M4 landing

**Status:** M4, 2026-10-14.
**Umbrella:** paideia-os R135 ("WASI-jail: a sandboxed execution environment
for WASI / WebAssembly modules running on paideia-os").
**Milestone:** R135.M4 (paideia-os #2629, Wave UMB-W18).
**Companion module:** [`stdout_records.pdx`](../../src/kernel/core/wasi/stdout_records.pdx)
**Companion substrates:**
- [`wasi_args_conv.pdx`](../../src/kernel/core/wasi/wasi_args_conv.pdx) (R135.M3 — the twin side table for WASI argv / stdin; same 8-row shape, same encoder-pitfall posture).
- [`jail_supervisor.pdx`](../../src/kernel/core/svc/jail_supervisor.pdx) (R135.M1/M2 — the daemon that owns the per-jail cap-env + spawn-gate; the three WASI side tables are logically 1:1 with its 8 rows).
- [`schema_fmt.pdx`](../../src/kernel/core/term/schema_fmt.pdx) (R129.M4, pending — the downstream formatter that consumes drained records and renders them to the terminal using schema + ANSI256 / Kitty-graphics substrates).
- [`fd_mediation.pdx`](../../src/kernel/core/wasi/fd_mediation.pdx) (R135.M5, pending — the fd dispatch arm that calls `_stdout_records_feed` from `wasi_fd_write(1, ...)` and routes drained records into formatter + telemetry sinks).

---

## Table of contents

1. Why typed records at all
2. Wire format
3. Row + schema + ring layout
4. Public API
   - 4.1 `_stdout_records_register_schema(pid, schema_ptr, schema_len) -> errno`
   - 4.2 `_stdout_records_feed(pid, bytes_ptr, bytes_len) -> packed u64`
   - 4.3 `_stdout_records_drain(pid, out_records_ptr, out_cap) -> packed u64`
5. Return code band
6. Parse state machine
7. Interaction with the R129.M4 schema formatter
8. Interaction with R135.M5 fd mediation
9. Encoder-pitfall posture
10. Follow-up tickets and open questions

---

## 1. Why typed records at all

A paideia-os terminal is "semantically queryable" by charter: a command's
output is not an opaque byte-stream of pre-rendered glyphs but a sequence of
structured records that the shell, the formatter, and downstream tools can
inspect, filter, sort, and recolor without re-parsing. For native paideia-os
binaries the plan is a direct typed-record syscall (not landed yet); for WASI
modules — which were written against POSIX-shaped `stdout` and emit flat text
— we need an adapter that converts their byte-stream into our native record
shape at the kernel boundary.

The natural place for this adapter is the kernel-side intake of
`wasi_fd_write(1, ...)`: the dispatch arm already sits at the WASI /
paideia-os seam, has a per-pid handle, and is the only path a WASI jail
reaches `stdout`. M4 lands the storage and the parser; M5 wires it to the
dispatch arm. From the WASI module's point of view nothing changes — it
calls `fd_write` and gets a byte-count back — but from the paideia-os point
of view, each successful write materialises zero or more typed records on
the per-pid ring, ready for the formatter to drain.

### Why not have the shell parse records out-of-process?

Because the schema is already available at the kernel side (declared at
exec time), the parse is a tight tab-and-newline split, and the alternative
is round-tripping bytes through user-space just to re-materialise them with
less context. Keeping the parser in-kernel also lets the formatter consume
records directly from the ring without the extra copy. For record-emitting
WASI modules (expected to be the dominant case for data-shaped tools —
`ls`, `ps`, `find`, `grep -c`, etc.), this is a visible latency win and a
smaller code surface.

### Why not a per-task buffer on the task struct?

Same reasoning as `jail_supervisor.pdx` §0 and `wasi_args_conv.pdx` §0:
record-conversion state is dead weight for the 99 % of tasks that are not
WASI jails. A dedicated 8-row side table keyed by pid matches the two
peers' 1:1 shape and keeps the task hot path (every `current` deref, every
scheduler tick) free of WASI-specific widening.

---

## 2. Wire format

### 2.1 M4 baseline — tab-separated, newline-delimited

A WASI module writes to `stdout` lines of the form:

```
field0 \t field1 \t field2 \t ... \t fieldN-1 \n
```

Where:
- `\t` is `0x09` (ASCII tab).
- `\n` is `0x0A` (ASCII line feed).
- Fields are opaque raw bytes except for `\t` and `\n`, which are
  reserved as delimiters. (A module wishing to emit a literal tab or
  newline in a field must escape it; M4 does not define an escape
  mechanism — the field byte is passed through and the parser will see
  it as a delimiter. See §10 Q2.)
- No field count prefix. No sentinel. Blank lines are skipped silently.

The module's declared schema at exec time is itself a tab-separated line
of field names (no trailing newline):

```
name \t size \t mtime \t mode
```

This yields `num_fields = 4` and establishes the per-record arity. Every
subsequent record on `stdout` must have exactly `num_fields - 1` tabs
(i.e. exactly `num_fields` fields); a tab-count mismatch returns
`SR_ERR_SCHEMA_MISMATCH` from `_stdout_records_feed` and the feed
aborts at the offending line.

### 2.2 Why newline-tab, not JSON or protobuf

The dispatch is at the WASI / paideia-os seam, which is already a tight
box (every write byte is parsed in the kernel). JSON and protobuf need a
state machine with multi-byte tokens, backtracking, and a schema
representation we don't have in the kernel today. Newline-tab is the
lowest-cost encoding that satisfies the record-shape requirement without
adding a dependency. It is also what the overwhelming majority of
real-world WASI tools emit when asked to produce "machine-readable"
output (`-0`, `--tsv`, etc.).

M5+ may add a bespoke binary record encoding on a side-fd (e.g.
`fd_write(3, length-prefixed-record)`) for tools that opt in; the M4
format is the fallback for POSIX-shaped tools and will remain supported.

### 2.3 Record slot shape (in the ring)

Each ring slot is 128 bytes:

```
[+0]       record_len (u64)   payload byte count (0 .. SR_RECORD_PAYLOAD_MAX)
[+8..+127] payload (120 B)    raw tab-separated bytes of the line
                              (no trailing '\n')
```

The record_len header is the authoritative payload length — the payload
is NOT NUL-terminated and may contain embedded tabs (which the downstream
formatter re-splits using `num_fields` as the arity target).

---

## 3. Row + schema + ring layout

### 3.1 Row layout (256 bytes per row, 8 rows)

Stride 256 is a power of two so row addressing uses `shl rax, 8` —
matches the encoder-pitfall posture (feedback_pdx_encoder_pitfalls: 2-op
`imul r, imm` is an encoder gap). Width is 256 (not 128 like
`wasi_args_conv.pdx`) because we inline the per-pid partial-line buffer
(128 bytes) alongside the control fields.

```
Row (256 bytes = 32 u64):
  [+0]    pid                 (u64)  owning pid; 0 is reserved
  [+8]    schema_len          (u64)  bytes stored (<= SR_SCHEMA_MAX = 256)
  [+16]   num_fields          (u64)  derived at register time
  [+24]   ring_head           (u64)  write cursor, 0..SR_RING_CAP
  [+32]   ring_tail           (u64)  read cursor, 0..SR_RING_CAP
  [+40]   ring_count          (u64)  live record count, 0..SR_RING_CAP
  [+48]   total_records       (u64)  monotonic lifetime count
  [+56]   partial_len         (u64)  bytes buffered in partial_buf
  [+64..+191] partial_buf     (128 B, usable 120)
  [+192..+247] reserved       (56 B)  slack for M5 fd mediation state
  [+248]  in_use              (u64)  0 = free, 1 = allocated. .bss zero-init
                                     gives us FREE at boot.  Written LAST at
                                     register time (concurrent scanner sees
                                     FREE or fully-initialised).
```

### 3.2 Schema store (2 KiB total, 256 B per row)

```
_stdout_records_schemas : [u8; 2048] @align(64)
```

Row `i` owns bytes `[i*256 .. (i+1)*256)`. Stride 256 = 2^8 so
`shl rax, 8`. `SR_SCHEMA_MAX = 256`.

### 3.3 Ring store (16 KiB total, 2 KiB per row)

```
_stdout_records_rings : [u8; 16384] @align(64)
```

Row `i` owns bytes `[i*2048 .. (i+1)*2048) = SR_RING_CAP (16) * SR_RECORD_BYTES (128)`.
Ring stride is 2048 = 2^11 (`shl rax, 11`). Slot stride is 128 = 2^7
(`shl rax, 7`).

### 3.4 Capacity

- 8 WASI pids × 256 B row = 2 KiB pool.
- 8 WASI pids × 256 B schema = 2 KiB schema.
- 8 WASI pids × 2 KiB ring = 16 KiB ring.
- Total static footprint ≈ 20 KiB — matches `JS_POOL_MAX = 8`
  (jail_supervisor) and `WA_POOL_MAX = 8` (wasi_args_conv); the three
  tables grow in lockstep (see §10 Q3).

---

## 4. Public API

### 4.1 `_stdout_records_register_schema(pid, schema_ptr, schema_len) -> errno`

Mint (or replace) a side-table row for `pid`, owning a copy of the
schema line. Resets the per-pid ring, partial buffer, and counters.

**Semantics:**
1. `pid == 0` → `SR_ERR_BAD_PID`.
2. `schema_len > SR_SCHEMA_MAX` (256) → `SR_ERR_SCHEMA_MISMATCH`.
3. Lookup existing row for `pid`:
   - Hit → overwrite its schema (replace semantics; M5 re-registers on
     execve without a prior deregister).
   - Miss → find a free row; if none → `SR_ERR_RING_FULL` (overload for
     "pool full").
4. Copy `schema_len` bytes from `schema_ptr` into the row's slice of
   `_stdout_records_schemas`.
5. Scan the copied schema: `tab_count = count('\t' bytes)`.
   `num_fields = (schema_len > 0) ? (tab_count + 1) : 0`.
6. Zero per-pid ring state: `ring_head = ring_tail = ring_count = 0`,
   `total_records = 0`, `partial_len = 0`.
7. Write row fields: `pid`, `schema_len`, `num_fields`, then `in_use = 1`
   LAST.
8. Return `SR_OK`.

The `schema_ptr` source is a **kernel pointer** at M4 (register is
called from in-kernel paths only — the dispatch arm marshalls the WASI
module's schema declaration into a kernel blob before calling).

### 4.2 `_stdout_records_feed(pid, bytes_ptr, bytes_len) -> packed u64`

Parse `bytes_ptr[0..bytes_len)` against the schema registered for
`pid`. Each `\n` closes a record; blank lines are silently skipped.
On each non-blank line the kernel validates `tab_count + 1 == num_fields`
and emits the line into the per-pid ring as `(record_len, payload)`.

**Return packing:**
```
bits [63..32] = records_emitted (u32)
bits [31.. 0] = status (one of SR_*)
```

**Status band:**
- `SR_OK` — feed accepted; trailing partial line retained in `partial_buf`.
- `SR_ERR_BAD_PID` — pid not registered; `records_emitted = 0`.
- `SR_ERR_RING_FULL` — per-pid ring exhausted at the offending line;
  earlier records in this feed are already in the ring (count reflects
  that).
- `SR_ERR_SCHEMA_MISMATCH` — parsed line's tab-count ≠ `num_fields`, or
  partial-line length exceeded `SR_PARTIAL_MAX`; earlier records are in
  the ring.

Non-OK statuses leave `partial_buf` in whatever state the loop was in;
the caller recovers by re-registering (which resets ring + partial state)
or by draining the already-emitted records and then re-registering.

**At M4** `bytes_ptr` is a **kernel pointer** (the dispatch arm marshalls
the WASI module's `fd_write` payload into a kernel buffer before calling,
exactly the symmetric pattern of `_wasi_args_register` at M3).

### 4.3 `_stdout_records_drain(pid, out_records_ptr, out_cap) -> packed u64`

Copy up to `out_cap` records from the per-pid ring into
`out_records_ptr`. Each record is a 128-byte slot
(`record_len` u64 header + 120-byte payload). Advances `ring_tail` by
`records_copied` and decrements `ring_count`.

**Return packing:**
```
bits [63..32] = records_copied (u32)
bits [31.. 0] = status
```

**Status band:**
- `SR_OK` — copy complete (ring may still hold more records; drain again).
- `SR_ERR_BAD_PID` — pid not registered; `records_copied = 0`.

**Null-pointer semantics:** if `out_records_ptr == 0` the function
returns at the first iteration with `records_copied = 0` and `SR_OK` —
useful as a "how full is the ring right now" probe when paired with
reading `ring_count` directly from the row (M5 may expose a dedicated
`_stdout_records_count(pid)` helper if that pattern recurs).

---

## 5. Return code band

```
SR_OK                   = 0
SR_ERR_BAD_PID          = 0x08    (pid==0 at register, or pid not registered)
SR_ERR_RING_FULL        = 0x1A00  (pool full at register, or per-pid ring full
                                   at feed)
SR_ERR_SCHEMA_MISMATCH  = 0x1A01  (schema oversized at register, tab-count
                                   mismatch at feed, line too long at feed)
```

**Overload rationale:**
- `SR_ERR_BAD_PID = 0x08` matches `WASI_EBADF` (and the overload used in
  `wasi_args_conv.pdx` §5) because the observational outcome for a WASI
  module is the same: "I asked for state that is not there." Keeping the
  two side tables aligned on this code lets a WASI shim surface a single
  "not registered" diagnostic without branching on which table failed.
- `SR_ERR_RING_FULL = 0x1A00` is reused for the register-time "pool full"
  case because the WASI module's visible outcome is the same: capacity
  exhausted. The dispatch arm distinguishes by looking at which call
  surfaced the code.
- `SR_ERR_SCHEMA_MISMATCH = 0x1A01` covers three parser-level failures.
  M5 may split them if diagnostics gain value from the distinction;
  current posture is tight code band (feedback_novel_clean_design: four
  codes is the right altitude for the first landing).

All four codes fit `imm32` with bit 31 clear so `mov rax, imm32` emits
the 7-byte zero-extending form (never `and r11, imm64` — see
feedback_pdx_encoder_pitfalls).

---

## 6. Parse state machine

The feed loop is a byte-by-byte state machine over `bytes_ptr[0..bytes_len)`:

```
state ::= (partial_len, ring_head, ring_tail, ring_count, total_records)
```

Transition on byte `b`:
```
if b == '\n':
    if partial_len == 0:
        skip  (blank line)
    else:
        field_count := count_tabs(partial_buf[0..partial_len]) + 1
        if field_count != num_fields:
            return (records_emitted << 32) | SR_ERR_SCHEMA_MISMATCH
        if ring_count == SR_RING_CAP:
            return (records_emitted << 32) | SR_ERR_RING_FULL
        slot := ring_base + ring_head * SR_RECORD_BYTES
        slot[0..8]   := partial_len
        slot[8..8+partial_len] := partial_buf[0..partial_len]
        ring_head    := (ring_head + 1) mod SR_RING_CAP
        ring_count   += 1
        total_records += 1
        partial_len  := 0
        records_emitted += 1
else:  // non-newline byte
    if partial_len == SR_PARTIAL_MAX:
        return (records_emitted << 32) | SR_ERR_SCHEMA_MISMATCH
    partial_buf[partial_len] := b
    partial_len += 1
```

Exhausting `bytes_ptr` (no error) returns
`(records_emitted << 32) | SR_OK` with the trailing partial line (if any)
retained in `partial_buf`. Subsequent feeds continue from where this one
left off — a module calling `fd_write` in small chunks sees exactly the
same record stream as a module writing one giant buffer.

**Observable guarantees:**
- Record order on the ring is the order lines arrived on `stdout`
  (FIFO; `ring_head` and `ring_tail` are the only cursors).
- `total_records` is monotonic across the lifetime of the registration
  (not reset by drain; reset by `_stdout_records_register_schema`).
- `ring_count` is the authoritative live-count; a caller inspecting
  `ring_count` directly from the row sees the same count the drain path
  bounds against.

---

## 7. Interaction with the R129.M4 schema formatter

The downstream formatter (`term/schema_fmt.pdx`, pending landing)
consumes records drained from this module and renders them using:
- The schema line (field names) — the formatter re-splits the schema
  by `\t` to materialise column headers.
- `num_fields` — the formatter already knows the arity by the time it
  drains (same side table), so it can validate drained payloads with a
  cheap sanity check instead of re-counting tabs.
- `ANSI256` + `Kitty graphics` substrates — the formatter chooses a
  per-field colouring based on field semantics (name heuristics) and
  renders with the appropriate terminal escape.

**Protocol between this module and schema_fmt (M5):**
1. A WASI jail calls `fd_write(1, bytes)`.
2. The fd dispatch arm calls `_stdout_records_feed(pid, bytes, len)`.
3. On non-zero `records_emitted`, the dispatch arm calls
   `_stdout_records_drain(pid, scratch_buf, SR_RING_CAP)`.
4. For each drained slot, the dispatch arm calls the formatter's
   per-record entry point with `(schema_ptr, schema_len, num_fields,
   record_len, payload_ptr)`.
5. The formatter emits the ANSI / Kitty-sequence output to the real tty.

The split (feed → drain → format) keeps the parser (this module) free of
terminal state, and keeps the formatter free of parse state. The ring in
between is a classic bounded producer/consumer buffer.

**Why drain-and-format instead of feed-and-format?** Because the feed
path happens inside the WASI `fd_write` syscall, which is a hot path we
want to keep short. Draining into a formatter that renders to the tty is
much more expensive (it may block on tty readiness, choose fonts, invoke
Kitty graphics for a thumbnail, etc.). Buffering records on the ring
lets the formatter run asynchronously on a different task (M6 — not yet
scoped).

---

## 8. Interaction with R135.M5 fd mediation

The M5 landing (`wasi/fd_mediation.pdx`, pending) is the dispatch arm
that:
1. Resolves `pid`'s `fd_table[1]` to a vnode (same shape as M5's stdin
   mediation in `wasi_args_conv.pdx` §4.4).
2. Decides between "pass-through to vfs_write" (the module did not
   register a schema) and "intercept and convert" (schema registered).
3. For the intercept path:
   - Marshals the WASM-space bytes into a kernel buffer.
   - Calls `_stdout_records_feed(pid, kernel_buf, len)`.
   - On non-zero `records_emitted`, drains and routes to the formatter
     (§7) or to a telemetry sink (M6 — not yet scoped).
   - Returns the original `bytes_len` to the WASI module (the module's
     view is "I wrote N bytes" regardless of whether they became records
     or glyphs).
4. For the pass-through path: unchanged from M3 (direct `vfs_write`).

**Schema registration from the dispatch arm:**
M5 adds a bespoke `wasi_paideia_declare_schema(fd, schema_ptr,
schema_len)` call that the dispatch arm maps to
`_stdout_records_register_schema(pid, schema_ptr, schema_len)`. The
dispatch arm is the only caller of the register path from ring-3.

**Deregister on task exit:**
M5 adds a `_stdout_records_release(pid)` hook into `sys_exit`'s
task-cleanup path to free the row and drop any undrained records on the
floor. Current M4 posture: no automatic release; a pid is recycled only
if `_stdout_records_register_schema` is called on it (replace
semantics).

---

## 9. Encoder-pitfall posture

Per feedback_pdx_encoder_pitfalls:
- `cmp rN, 0` (never `test rN, rN`).
- `shl rN, 8` for 256-byte row stride; `shl rN, 11` for 2048-byte ring
  stride; `shl rN, 7` for 128-byte slot stride — all power-of-two (never
  `imul r, imm`).
- `shl rax, 32` for packed-return hi half (imm8 operand, standard x86
  encoding).
- `mov rax, imm32` for all return codes (bit 31 clear on all SR codes
  used — never `and r11, imm64`).
- `or rax, r11` for packed-return low-half fold-in (reg-reg form).
- Single-line `pub let name = "..."` — none emitted at M4 (no
  fingerprint strings; no boot bringup).
- Module basename `StdoutRecords` matches file basename
  `stdout_records.pdx` (ddc requires exact match; task directive
  confirms).
- Labels prefixed `sr_` (stdout-records) to stay clear of `wa_`
  (wasi-args), `js_` (jail_supervisor), `ss_` (shell_session), `cmnt_`
  (cap_minter), `ks_` (kind_shell_session), `sh_` (shell_history).
- Memory addressing: `[base + disp]`, `[base + index * scale]`, and
  `lea reg, [base + disp]` — all proven forms in sibling modules
  (`journal_ondisk.pdx` uses `mov [r10 + 4088]`; `acpi/crs.pdx` uses
  imm32 disp). We use `[r14 + 248]` for the `in_use` write.

### Stack discipline (SysV, entry `rsp%16==8`)

```
_sr_find_row                       0 pushes (pure leaf scan)
_sr_find_free                      0 pushes (pure leaf scan)
_stdout_records_register_schema    3 pushes (odd -> aligned at nested call)
_stdout_records_feed               5 pushes (odd -> aligned at nested call)
_stdout_records_drain              5 pushes (odd -> aligned at nested call)
```

Entry `rsp%16==8`:
- 3-push → `+24` → `rsp%16==0` at nested call sites.
- 5-push → `+40` → `rsp%16==0` at nested call sites.

Both are odd-push counts, so the "odd # of pushes puts us back on
16-byte alignment" invariant handles alignment without `sub rsp, 8`
padding.

---

## 10. Follow-up tickets and open questions

- **Q1 — ring capacity:** does `SR_RING_CAP = 16` suffice for a
  real workload (e.g. `ls -l /usr/bin | wc -l` on a jail that pipes
  to a slow formatter)? If drain-starvation is observed, grow to 64
  (still power-of-two) or make it per-pid configurable at register
  time.
- **Q2 — escape mechanism for literal `\t` / `\n` in fields:** M4 has
  no escape — a tab inside a field is seen as a delimiter. Options:
  (a) require tools to pre-escape (write `\t` as `\\t` by convention);
  (b) add a bespoke binary record encoding on a side-fd (see §2.2);
  (c) widen the baseline wire format to length-prefixed fields.
  Current posture: (a) at M4 (document; tools that need the control
  bytes use the binary side-fd when M5 lands it).
- **Q3 — table coupling with jail_supervisor and wasi_args_conv:** at
  M4 the three side tables are independent (same capacity, no
  cross-check). M5 may add a one-line coupling —
  `_stdout_records_register_schema` refuses pids that are not in
  `jail_supervisor` — once the dispatch arm is the only caller. Not
  needed at M4 because in-kernel witnesses may register without a
  jail.
- **Q4 — formatter back-pressure:** when the ring fills (ring_count ==
  SR_RING_CAP), the feed path currently aborts the offending line and
  returns `SR_ERR_RING_FULL`. The WASI module's `fd_write` would
  then surface a short write to the module. Alternative: block the
  feed in-kernel until the formatter drains. Not a good fit for M4
  because the feed is on the syscall path and must not block;
  short-write-on-full is the Unix-shaped answer and matches what WASI
  modules already handle.
- **Q5 — deregister on task exit:** M4 does not drop rows on task
  exit. If a pid is recycled, the old schema is still bound to that
  pid until a replace. M5 adds `_stdout_records_release(pid)` into
  the task-cleanup path (symmetric with the planned
  `_wasi_args_release(pid)` in `wasi_args_conv.pdx` §9 Q5).
- **Q6 — kernel-wide schema registry:** if multiple WASI jails
  declare the same schema line, we store 8 copies. A side-registry
  that interns schemas (hash → slot) would amortise the storage.
  Deferred — 8 × 256 B = 2 KiB is not pressing.

---

**Pointers:**
- Source: [`src/kernel/core/wasi/stdout_records.pdx`](../../src/kernel/core/wasi/stdout_records.pdx)
- Twin: [`src/kernel/core/wasi/wasi_args_conv.pdx`](../../src/kernel/core/wasi/wasi_args_conv.pdx)
  ([design](wasi-argv-stdin-conversion.md))
- Parent umbrella: paideia-os R135 ("WASI-jail").
