# WASI fd / file-cap mediation — M6 landing

**Status:** M6, 2026-10-14.
**Umbrella:** paideia-os R135 ("WASI-jail: a sandboxed execution environment
for WASI / WebAssembly modules running on paideia-os").
**Milestone:** R135.M6 (paideia-os #2631, Wave UMB-W20).
**Companion module:** [`wasi_fd_mediation.pdx`](../../src/kernel/core/wasi/wasi_fd_mediation.pdx)
**Companion substrates:**
- [`wasi_args_conv.pdx`](../../src/kernel/core/wasi/wasi_args_conv.pdx) (R135.M3 — the twin side table for WASI argv / stdin; same 8-row shape, same encoder-pitfall posture).
- [`stdout_records.pdx`](../../src/kernel/core/wasi/stdout_records.pdx) (R135.M4 — the kernel-side typed-record ring; `_wfd_write(fd=1, ...)` routes bytes through `_stdout_records_feed` when a schema is registered).
- [`wit_bridge.pdx`](../../src/kernel/core/wasi/wit_bridge.pdx) (R135.M5 — the WIT -> schema adapter that seats the stdout_records schema at module-load time).
- [`jail_supervisor.pdx`](../../src/kernel/core/svc/jail_supervisor.pdx) (R135.M1 / M2 — the daemon that owns the per-jail cap-env + spawn-gate; the fd mediation table is logically 1:1 with its 8 rows).
- [`vfs_read.pdx`](../../src/kernel/core/fs/vfs_read.pdx) + [`vfs_write.pdx`](../../src/kernel/core/fs/vfs_write.pdx) (R16.M1-008 — the kernel-side VFS surface this module dispatches into after resolving the fd through the per-pid table).

---

## Table of contents

1. Why a dedicated WASI fd table
2. Row + entry layout
3. Public API
   - 3.1 `_wfd_register(pid, fd, cap_handle, flags) -> errno`
   - 3.2 `_wfd_lookup(pid, fd) -> packed u64`
   - 3.3 `_wfd_read(pid, fd, iovs_ptr, iovs_len, nread_out_ptr) -> errno`
   - 3.4 `_wfd_write(pid, fd, iovs_ptr, iovs_len, nwritten_out_ptr) -> errno`
   - 3.5 `_wfd_close(pid, fd) -> errno`
4. Return code band
5. Dispatch decision (fd=1 → stdout_records vs vfs_write)
6. Interaction with M4 stdout_records
7. M6 → M7 split: pread / pwrite / seek
8. Capability shape (M6 vs M8+)
9. Encoder-pitfall posture
10. Follow-up tickets and open questions

---

## 1. Why a dedicated WASI fd table

paideia-os's native per-task fd table (`core/fs/fd_table.pdx`) is already
cap-shaped: an fd slot holds a vnode index, `vfs_open` / `vfs_close` keep the
vnode refcount honest, and `fd_inherit` duplicates slots on `fork`. One
naive option is to point the WASI shim arms at that table directly: no
side state, no new storage, no sync problems.

That option fails for four reasons, each independently sufficient:

**(a) WASI preview1 integer discipline.** A WASI module sees integer fds
0..31 with stable 0 / 1 / 2 for stdin / stdout / stderr. It must not see
the kernel-side vnode index: that would let a jailed module forge handles
by observing a correlation between its own calls and the kernel's slot
allocator. The fd space is an opaque capability, which is the exact
property an integer index into a kernel-shared vnode pool does not have.

**(b) The underlying resource is a file cap, not a raw vnode.** The design
intent for R135+ is that every jailed-module I/O call goes through a cap
layer that may enforce finer permission bits than the vnode's own mode.
At M6 the cap handle happens to be the vnode index in the low 48 bits
(`cap_handle == vnode_idx`), but the surface was shaped so M8+ can widen
`cap_handle` into an index into a proper cap table without breaking any
of the surface contracts a WASI module sees.

**(c) stdout schema interception.** When a WASI jail declares a WIT
record schema (R135.M5), writes to fd 1 flow into `_stdout_records_feed`
instead of `vfs_write`, so the kernel materialises records on a per-pid
ring the formatter drains. The native fd table has no hook for this; the
check belongs on the dispatch arm and the arm needs a per-pid-per-fd
state slot to live on. A side table is the natural home.

**(d) WASI maintains a per-fd file offset.** The native per-task fd slot
in paideia-os at this altitude is just a vnode index; seek state lives
either per-vnode (uncommon in paideia-os's "stream primitives at the
cap boundary" posture) or per-process (POSIX `lseek`). WASI's offset is
per-fd, which does not map onto either of the two existing shapes.

All four together argue for a dedicated 8-row side table keyed by pid.
Capacity match (`WFD_POOL_MAX = 8 = WA_POOL_MAX = SR_POOL_MAX =
JS_POOL_MAX`) is intentional — every WASI jail owns at most one row on
each of the four side tables simultaneously. The task hot path (every
scheduler tick, every native syscall) stays free of WASI-specific
widening.

---

## 2. Row + entry layout

### 2.1 Pool rows — per-pid headers (1 KiB total)

`_wfd_pool : [u64; 128] @align(64)` — 8 rows × 128 bytes = 1024 bytes.

| offset | field       | type | notes                                       |
|-------:|-------------|------|---------------------------------------------|
|   +0   | pid         | u64  | owning pid; 0 reserved                      |
|   +8   | reserved_a  | u64  | M7+ dispatch counters                       |
|  +16   | reserved_b  | u64  | M7+ (cloexec mask, wit-schema row link, …) |
| +24..+119 | slack (12 u64) | — | M7+ (per-fd whence cache, parent pid, …) |
|  +120  | in_use      | u64  | 0 = free, 1 = allocated (publication fence) |

`.bss` zero-init gives all-FREE at boot. Row-base addressing uses
`shl rax, 7` (stride 128 is a power of two) — no imul.

### 2.2 Entries — the fd slots (4 KiB total)

`_wfd_entries : [u8; 4096] @align(64)` — 8 pid-rows × 512 bytes =
8 × 32 fds × 16 bytes per entry.

| offset | field  | type | notes                                          |
|-------:|--------|------|------------------------------------------------|
|   +0   | packed | u64  | high 48 bits cap_handle, low 16 bits flags     |
|   +8   | offset | u64  | seek position; advanced by `_wfd_read` / `_wfd_write` |

`packed == 0` iff the fd is NOT registered: `cap_handle == 0` is the
reserved "no cap" sentinel, so no live entry can have `packed == 0`.
This is what makes `_wfd_lookup` a single memory load with no explicit
"is-registered" bit — the discriminator falls out of the packed shape.

Strides:
- per-pid stride = 512 bytes = 2^9 → `shl rax, 9`
- per-fd stride  =  16 bytes = 2^4 → `shl rax, 4`

Flags (low 16 bits of `packed`):

| bit        | name           | meaning (M6)                       |
|-----------:|----------------|------------------------------------|
| 0x0001     | WFD_FLAG_READABLE | fd satisfies `_wfd_read`         |
| 0x0002     | WFD_FLAG_WRITABLE | fd satisfies `_wfd_write`        |
| 0x0004     | WFD_FLAG_APPEND   | M7: writes seek to end first     |
| 0x0008     | WFD_FLAG_SPECIAL  | M8: non-vfs backend (socket/…)   |

M6 reads the readable / writable bits advisorily (the vfs backend may
refuse a non-matching op independently); APPEND / SPECIAL are reserved
for later landings.

### 2.3 Kernel iovec shape

`_wfd_read` and `_wfd_write` take an iovec array of 16-byte kernel
iovecs: `{ buf_ptr: u64; buf_len: u64 }`. The future M7 WASM-space
translator layer marshals from WASM preview1's 32-bit (buf, len) pair
into this 64-bit shape before calling. Keeping the kernel iovec
natively 64-bit matches Linux's `struct iovec` and simplifies the
loop (16-byte stride = `shl rN, 4`).

---

## 3. Public API

### 3.1 `_wfd_register(pid, fd, cap_handle, flags) -> errno`

Mint (or replace) an fd entry mapping WASI integer fd `fd` to the
kernel-side file-cap handle `cap_handle` for the owning pid.

**Returns:**
- `WFD_OK` — entry registered or replaced.
- `WFD_EBADF` — `pid == 0`, `fd >= 32`, or `cap_handle == 0`.
- `WFD_ENOTCAP` — pool full (no free row).

**Steps:**
1. Pack `packed = ((cap_handle & 0xFFFFFFFFFFFF) << 16) | (flags & 0xFFFF)`.
2. Validate `pid != 0`, `fd < 32`, `cap_handle != 0`.
3. `_wfd_find_row(pid)` — if hit, reuse; else `_wfd_find_free()`.
4. Compute entry base; write `packed` at +0, `offset = 0` at +8.
5. If newly allocated: write `pid` at `row+0`, `in_use = 1` at `row+120`
   LAST (publication fence).

**Register-time replacement.** Calling `_wfd_register` on an already-
registered (pid, fd) pair silently overwrites the entry and resets
`offset` to 0. This matches WASI preview1's `fd_renumber` semantics
and the native fd table's slot-reuse posture.

### 3.2 `_wfd_lookup(pid, fd) -> packed u64`

Look up fd on pid's row and return the packed cap_handle / flags word.

**Returns:**
- On HIT: `(cap_handle << 16) | flags` — high 48 cap_handle (non-zero),
  low 16 flags.
- On MISS: `WFD_EBADF` (fd out of range) or `WFD_ENOTCAP` (pid-not-
  registered OR fd slot unregistered) in the low 16 bits with the high
  48 bits zero.

**Discriminator:** `(ret >> 16) == 0` iff miss. `(ret & 0xFFFF)` is the
error code on miss, or the flags on hit.

This single packed u64 is the only kernel surface a caller needs to
answer both "do I have a cap for this fd?" and "what are its flags?" —
one load, one shift, one compare.

### 3.3 `_wfd_read(pid, fd, iovs_ptr, iovs_len, nread_out_ptr) -> errno`

Walk the kernel-iovec array, dispatching each entry through `vfs_read`
against the cap_handle stored for (pid, fd). Advance the per-fd offset
by the sum of bytes read.

**Returns:**
- `WFD_OK` — all iovecs processed. `*nread_out_ptr` holds the total.
  A short / EOF read anywhere is still OK; the caller sees it via
  `*nread_out_ptr < sum(len)`.
- `WFD_EBADF` — `pid == 0`, `fd >= 32`, `nread_out_ptr == 0`, or pid
  not registered. `*nread_out_ptr` is NOT touched on EBADF.
- `WFD_ENOTCAP` — fd slot unregistered. `*nread_out_ptr = 0`.
- `WFD_IO` — `vfs_read` returned a sentinel on some iov; partial sum
  is written to `*nread_out_ptr`.

**Short-read termination.** When `vfs_read` returns fewer bytes than
requested on an iovec, the loop stops and reports `WFD_OK` with the
partial total. This is WASI preview1's `fd_read` contract.

**Offset advancement.** `offset += bytes_read` after each successful
dispatch; the final offset is persisted back to `entry+8` before
return (both WFD_OK and WFD_IO).

### 3.4 `_wfd_write(pid, fd, iovs_ptr, iovs_len, nwritten_out_ptr) -> errno`

Walk the kernel-iovec array, dispatching each entry through either
`_stdout_records_feed` (fd=1 with a schema row) or `vfs_write`
(otherwise). See §5 and §6 for the dispatch decision.

**Returns:**
- `WFD_OK` — all iovecs processed. `*nwritten_out_ptr` holds the total.
- `WFD_EBADF` — same shape as `_wfd_read`.
- `WFD_ENOTCAP` — vfs path only; fd slot unregistered.
- `WFD_IO` — downstream call (`vfs_write` or `_stdout_records_feed`)
  returned an error; partial sum written.

**Offset discipline.** Vfs path advances `offset` by bytes written;
SR path leaves `offset` untouched (stdout is a stream, not seekable).

### 3.5 `_wfd_close(pid, fd) -> errno`

Scrub the fd entry (`packed = 0`, `offset = 0`). The pool row stays
live — row teardown is driven by jail-supervisor shutdown, not by
closing the last fd. This matches `wasi_args_conv.pdx`'s permanent-row
posture (an argv row survives until the jail dies).

**Returns:**
- `WFD_OK` — entry scrubbed. Idempotent on already-empty slots.
- `WFD_EBADF` — fd ≥ 32 or pid not registered.

---

## 4. Return code band

| name          | value   | meaning                                               |
|---------------|---------|-------------------------------------------------------|
| `WFD_OK`      | `0`     | success                                               |
| `WFD_EBADF`   | `0x08`  | fd out of range, pid not registered, cap_handle==0    |
| `WFD_ENOTCAP` | `0x1E00`| fd slot has no cap registered yet (lookup); overload: pool full (register) |
| `WFD_IO`      | `0x1E01`| downstream VFS or stdout_records call returned error  |

All fit `imm32` with bit 31 clear so `mov rax, imm32` emits the
7-byte zero-extending form (never `and r11, imm64`).

**EBADF alignment with WASI.** WASI preview1 defines `errno.badf = 8`;
we re-use the same numeric so a future WASI-shim arm can forward
`WFD_EBADF` verbatim without a translation table.

**ENOTCAP overload rationale.** We overload `WFD_ENOTCAP` on register
pool-full and lookup-miss because both conditions share the user-
visible shape "the operation needs a cap that is not there". A WASI
shim arm that wants to distinguish the two can inspect its own state
(did it just try to register a new fd? → pool full; did it try to
operate on an existing fd? → unregistered).

---

## 5. Dispatch decision (fd=1 → stdout_records vs vfs_write)

`_wfd_write` consults `_sr_find_row(pid)` BEFORE the vfs-path lookup,
guarded by `fd == 1`:

```
if fd != 1:
    goto vfs_path
if _sr_find_row(pid) == WFD_ID_NONE:
    goto vfs_path          # fd=1 without schema -> treat as regular file
# stdout_records path:
for iov in iovs:
    status, _records = _stdout_records_feed(pid, iov.buf, iov.len)
    if status != SR_OK:
        return WFD_IO
    total_written += iov.len
*nwritten_out_ptr = total_written
return WFD_OK
```

Three cases, three branches:

1. **fd ≠ 1**: always vfs path. fd=2/stderr always flows this way, so a
   module that wants structured logs on stderr can register a cap for
   fd=2 that points at a syslog-shaped vnode.
2. **fd = 1, no schema**: vfs path. A WASI module that writes to stdout
   without declaring a WIT record schema sees regular file-shaped
   behaviour; this is what `cat`, `echo`, legacy POSIX ports expect.
3. **fd = 1, schema registered**: stdout_records path. The record ring
   accumulates and the formatter drains.

Nothing about M4's register / drain surface changes. The schema row is
independently gated by `wit_bridge_register_module`; M6 only reads the
`_sr_find_row` result to make a routing decision.

---

## 6. Interaction with M4 stdout_records

### 6.1 Call shape

Per iovec on the SR path, `_wfd_write` invokes:

```
_stdout_records_feed(pid, iov.buf, iov.len) -> packed u64
    bits [63..32] = records_emitted  (ignored by _wfd_write)
    bits [31.. 0] = status
```

`_wfd_write` extracts the status via `shl r11, 32; shr r11, 32` (NEVER
`and r11, imm32` with 0xFFFFFFFF — that mask has bit 31 set and would
sign-extend to `0xFFFFFFFFFFFFFFFF`; this mirrors `wit_bridge.pdx`'s
status unpack discipline).

### 6.2 Bytes-written accounting

On a successful `_stdout_records_feed`, `_wfd_write` adds `iov.len` to
the running total. The feed function consumes the entire input buffer
regardless of record boundaries: a partial record at the end is
retained in the row's `partial_buf` for the next feed. So from WASI's
point of view, every byte handed in is "written" the moment the feed
returns `SR_OK`.

Error cases:
- `SR_ERR_BAD_PID` — cannot happen because `_sr_find_row` just succeeded.
- `SR_ERR_RING_FULL` — the per-pid ring filled up before all records
  were emitted. The feed function reports a partial `records_emitted`
  in the high 32 bits; `_wfd_write` surfaces `WFD_IO` with the
  bytes-written-so-far sum. A WASI shim arm may want to pause the
  jailed task until a drain happens.
- `SR_ERR_SCHEMA_MISMATCH` — a parsed line's tab-count did not match
  `num_fields`, or a line exceeded `SR_PARTIAL_MAX`. Same WFD_IO
  surface.

### 6.3 Why fd=1-with-schema and not every fd

The schema is per-pid, not per-fd: a jailed module that wants typed
records on both stdout and a separate "metrics" fd would need to
distinguish them at the record level, not at the fd level. The
natural way is a schema prefix in the record itself; the dispatch
layer stays simple (only fd=1 is the typed path). This also matches
how structured logging works on real systems (`stdout` carries data,
`stderr` carries free-form diagnostics).

---

## 7. M6 → M7 split: pread / pwrite / seek

M6 implements only the "implicit offset" (stream-shaped) WASI read /
write surface. The per-fd offset field at `entry+8` is advanced by
the return value of each successful dispatch. WASI preview1's
`fd_pread` / `fd_pwrite` take an explicit offset and must NOT touch
the stored offset; those land at M7 together with a `_wfd_seek`
surface for `fd_seek`.

The pool row has 96 bytes of slack reserved (SECTION 1) for the
required book-keeping:

- M7 **`_wfd_pread(pid, fd, iovs, iovs_len, offset, nread_out)`**:
  identical loop to `_wfd_read` but seed from the caller-supplied
  offset and do NOT persist the final offset back to `entry+8`.
- M7 **`_wfd_pwrite(pid, fd, iovs, iovs_len, offset, nwritten_out)`**:
  same shape, mirror of the vfs path only (pread/pwrite are not
  defined for stdout_records — stdout is a stream).
- M7 **`_wfd_seek(pid, fd, offset, whence, newoffset_out)`**: direct
  write to `entry+8` after reconciling whence (SET / CUR / END). END
  requires a backend `vops_stat` call to find file size; the pool
  row's reserved_a slot caches the last known file size to short-
  circuit the common `whence == CUR` case.
- M8 **`_wfd_dup(pid, src_fd, dst_fd)`** / **`_wfd_renumber(...)`**:
  trivial after M6 — copy `packed` + `offset`.

Nothing in M6 forces M7's shape; M7 strictly extends M6.

---

## 8. Capability shape (M6 vs M8+)

M6: `cap_handle` is a 48-bit value, with the low 48 bits of a vnode
index (0..255 at the current `VNODE_MAX`) occupying the low 16 bits
and the high 32 bits zero. The dispatcher does `shr packed, 16` and
passes the result straight to `vfs_read` / `vfs_write` as `vnode_idx`.

M8+: `cap_handle` becomes an opaque index into a kernel-side cap
table (`core/cap/cap_table.pdx`, pending). The dispatcher gains a
`_cap_table_resolve(cap_handle) -> vnode_idx | errno` call between
the `shr` and the `vfs_*` dispatch. The cap table carries the
per-cap permission bits (read / write / seek / symlink-follow / …)
that the current `WFD_FLAG_*` bits approximate.

The surface shape (`_wfd_register`, `_wfd_lookup`, …) does not
change — the discipline is "cap_handle is opaque to the caller, the
mediation layer is the only thing that resolves it to a backend
address".

---

## 9. Encoder-pitfall posture

Labels prefixed `wfd_` (wasi-fd) to stay clear of `wa_` (wasi-args),
`sr_` (stdout-records), `wb_` (wit-bridge), `js_` (jail_supervisor),
`ss_` (shell_session), `cmnt_` (cap_minter). No reserved paideia-as
keyword overlap (`loop` / `if` / `let`).

Instruction-level discipline:
- `cmp rN, 0` (never `test rN, rN`).
- `shl rN, 7` (pool stride 128).
- `shl rN, 9` (entries per-pid stride 512).
- `shl rN, 4` (entries per-fd stride 16, iovec stride 16).
- `shl rN, 16` / `shr rN, 16` (cap_handle pack / unpack, `imm8`).
- `shl r11, 32` / `shr r11, 32` (status unpack; NEVER `and r11,
  imm64`, and NEVER `and r11, 0xFFFFFFFF` which would sign-extend —
  mirrors `wit_bridge.pdx`'s status unpack).
- `mov rax, imm32` for all WFD codes (bit 31 clear).
- `mov r64, imm64` for the 48-bit cap-handle mask `0xFFFFFFFFFFFF`
  and the vfs sentinel `0xFFFFFFFFFFFFFFFF`.
- Module basename `WasiFdMediation` matches file basename
  `wasi_fd_mediation.pdx` (ddc requires exact match).

Stack-frame discipline:

| function          | pushes | pad     | notes                                        |
|-------------------|:------:|:-------:|----------------------------------------------|
| `_wfd_find_row`   |   0    |   —     | pure leaf scan                               |
| `_wfd_find_free`  |   0    |   —     | pure leaf scan                               |
| `_wfd_entry_base` |   0    |   —     | pure leaf address compute                    |
| `_wfd_register`   |   3    |   —     | odd pushes aligned; new-row path inlines arithmetic to avoid an extra push/pop pair that would misalign the stack |
| `_wfd_lookup`     |   2    | sub 8   | even pushes need a pad                       |
| `_wfd_close`      |   2    | sub 8   | even pushes need a pad                       |
| `_wfd_read`       |   5    | sub 16  | odd pushes aligned; +16 slack for 2 scratch slots |
| `_wfd_write`      |   5    | sub 16  | odd pushes aligned; +16 slack for 2 scratch slots |

Why the two scratch slots in `_wfd_read` / `_wfd_write`? We have six
long-lived values across the iov loop (pid, iovs_cur, iovs_end,
nread/nwritten_out_ptr, entry_ptr, offset) and only five callee-save
slots after rsp. Spilling `offset` is cheaper than recomputing
`entry_ptr` every iteration — two 8-byte loads/stores per iteration
instead of a shl + lea + add + shl + add. `total_read` / `total_written`
takes the other slot (updating a stack u64 is as fast as a register
when the slot is hot in L1).

---

## 10. Follow-up tickets and open questions

1. **M7 — pread / pwrite / seek** (paideia-os #2632, pending):
   Explicit-offset variants that leave `entry+8` alone, plus
   `_wfd_seek`. See §7.
2. **M8 — cap table resolve** (paideia-os #2633, pending):
   `_cap_table_resolve` between `shr packed, 16` and the vfs
   dispatch; opens the surface to proper permission bits.
3. **M9 — WASM-space iovec translator** (paideia-os #2634, pending):
   The thin layer that marshals 32-bit WASM iovecs into our 64-bit
   kernel iovec shape before calling `_wfd_read` / `_wfd_write`.
   Lives at the jail-supervisor dispatch arm.
4. **M10 — dup / renumber / cloexec** (paideia-os #2635, pending):
   `_wfd_dup` and the per-row cloexec bitmask. Trivial after M6.
5. **Should EBADF write 0 to `*nread_out_ptr`?** M6 says no (undefined
   on EBADF) because EBADF can originate from `nread_out_ptr == 0`
   itself. If a future audit shows this is a footgun, we can split
   EBADF into "null out-ptr" (no write) and "bad fd" (write 0) via
   a status sub-code; the current band has slack.
6. **Register-replace vs. explicit close.** `_wfd_register` on an
   already-registered (pid, fd) silently overwrites. If a shim arm
   wants "fail if already open", it can `_wfd_lookup` first and
   check `(ret >> 16) == 0`. Alternative: a `_wfd_register_strict`
   variant; defer to M8.
7. **Entry-size locked at 16 B** by the current `packed` + `offset`
   shape. If M8 adds per-fd state (readv/writev timing, backend hint
   bits) that doesn't fit, we grow the entry to 32 B (shl rN, 5)
   while keeping the per-pid stride a power of two.
