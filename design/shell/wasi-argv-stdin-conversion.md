# WASI argv / stdin conversion — M3 stub landing

**Status:** M3 stub, 2026-10-13.
**Umbrella:** paideia-os R135 ("WASI-jail: a sandboxed execution environment for
WASI / WebAssembly modules running on paideia-os").
**Milestone:** R135.M3 (paideia-os #2628, Wave UMB-W17).
**Companion module:** [`wasi_args_conv.pdx`](../../src/kernel/core/wasi/wasi_args_conv.pdx)
**Companion substrates (M4+ touch-points):**
- [`jail_supervisor.pdx`](../../src/kernel/core/svc/jail_supervisor.pdx) (R135.M1/M2 — the daemon that owns the per-jail cap-env + spawn-gate; M4 register-on-execve hooks fire from the jail's child task boundary).
- [`sys_execve.pdx`](../../src/kernel/core/syscall/handlers/sys_execve.pdx) (R15.M6 — execve body; M4 marshals argv at execve into `_wasi_args_register` just before the user-aspace commit).
- [`vfs_read.pdx`](../../src/kernel/core/fs/vfs_read.pdx) (R16.M1 — the vnode-indexed read backend; M5 mediates `_wasi_stdin_read` through the jailed task's `fd[0]` entry via `fd_table` + `vfs_read`).

---

## Table of contents

1. Why a conversion layer at all
2. WASI spec surface this module adapts
3. Row + blob store layout
4. Public API
   - 4.1 `_wasi_args_register(pid, blob_ptr, blob_len) -> errno`
   - 4.2 `_wasi_args_sizes_get(pid, argc_out, argv_buf_size_out) -> errno`
   - 4.3 `_wasi_args_get(pid, argv_out, argv_buf_out) -> errno`
   - 4.4 `_wasi_stdin_read(pid, iovs_ptr, iovs_len, nread_out) -> errno`
5. Return code band (WASI-aligned)
6. M3 → M4 → M5 milestone split
7. Encoder-pitfall posture
8. Interaction with the jail supervisor
9. Follow-up tickets and open questions

---

## 1. Why a conversion layer at all

A WASI module running inside a paideia-os `svc.jail-supervisor` row expects to see
its argv / argc via two spec-defined calls (`wasi_args_sizes_get`,
`wasi_args_get`) and its stdin via `wasi_fd_read(0, ...)`. paideia-os does not
natively carry a POSIX-shaped `argv[]` on the task row (feedback_novel_clean_design:
POSIX inheritance is retired by default; the task struct's `user_pml4_pa` is the
only "process view" we carry). The marshalling that execve already does for the
loader is a flat kernel buffer, not a WASI-shaped `(argv_ptrs, argv_buf,
argv_buf_size)` triple.

Rather than widen the task row with WASI-specific fields that would be dead weight
for the 99 % of tasks that are not WASI jails (see jail_supervisor.pdx §0 for the
same reasoning on jail state), this module lands a small side-table keyed by pid.
The table is populated by the jailed task's launcher (M4 — a hook inside the
execve path when the loaded ELF is identified as a WASI runtime) and consulted by
the three WASI shim functions (M3 — this landing).

### Why not a per-task argv blob on the task struct?

Because 99 % of tasks are not WASI. The task struct is on the hot path (every
`current` deref, every scheduler tick, every syscall dispatch); widening it for a
WASI-specific blob is a visible regression for non-WASI workloads. A side table
of 8 entries (`WA_POOL_MAX = 8`) matches the jail-supervisor's `JS_POOL_MAX = 8`
cap — a WASI jail cannot exist without a jail-supervisor row, so the two tables
cannot drift. If `JS_POOL_MAX` grows in a later milestone, `WA_POOL_MAX` grows
in lockstep (see §9 open-question Q3).

### Why not read argv directly from the user aspace at `_wasi_args_get` time?

Because by the time a WASI module calls `wasi_args_get`, its address space has
been swapped (execve commits the swap AFTER the ELF loader runs; see
sys_execve.pdx step 4). The original argv pointer the parent passed to execve
no longer lives in the child aspace — it was marshalled into a kernel-side blob
and the parent aspace was torn down. This module is the kernel-side owner of
that blob for the lifetime of the WASI task.

---

## 2. WASI spec surface this module adapts

Per the WASI preview1 interface (`wasi_snapshot_preview1`,
<https://github.com/WebAssembly/WASI/blob/main/legacy/preview1/witx/wasi_snapshot_preview1.witx>):

```
args_get: (argv: *mut *mut u8, argv_buf: *mut u8) -> errno
args_sizes_get: () -> (argc: size, argv_buf_size: size, errno)
fd_read: (fd: fd, iovs: iovec_array) -> (nread: size, errno)
```

The WASI module's view: `argv_buf` is a flat buffer of NUL-separated strings
(`"arg0\0arg1\0arg2\0..."`), and `argv` is an array of `argc` pointers into that
buffer. `argv_buf_size` is the total byte count including trailing NULs.

The kernel-held blob this module stores is the same NUL-separated flat buffer.
`argc` and `argv_buf_size` are not stored separately — they are computed from
the blob at register time (one scan to count NULs → argc; `blob_len` ↔
`argv_buf_size`). Keeping only the blob is the single-source-of-truth posture
and matches jail_supervisor.pdx's "store the primitive, derive the composite"
discipline (jail_supervisor stores a 128-bit mask and derives per-sysno
allowed-ness, not a 128-slot array of booleans).

---

## 3. Row + blob store layout

### 3.1 Row layout (128 bytes per row, 8 rows)

Stride 128 is a power of two so row addressing uses `shl rax, 7` — matches the
encoder-pitfall posture (feedback_pdx_encoder_pitfalls: 2-op `imul r, imm` is an
encoder gap).

```
Row (128 bytes = 16 u64):
  [+0]    pid                 (u64)  owning pid; 0 is reserved
  [+8]    blob_len            (u64)  bytes stored (<= WA_BLOB_MAX = 1024)
  [+16]   argc                (u64)  derived at register time (NUL count)
  [+24]   argv_buf_size       (u64)  == blob_len (WASI-named alias)
  [+32..103]                   reserved (M4 adds exec-time metadata — see §6)
  [+104]  reserved_a          (u64)  slack
  [+112]  in_use              (u64)  0 = free, 1 = allocated. .bss zero-init
                                     gives us FREE at boot.
  [+120]  reserved_b          (u64)  slack
```

### 3.2 Blob store (8 KiB total, 1 KiB per row)

```
_wasi_args_blobs : [u8; 8192] @align(64)
```

Row `i` owns bytes `[i*1024 .. (i+1)*1024)`. Row base pointer for the blob is
`_wasi_args_blobs + (row_idx << 10)` — power-of-two stride matches the row-base
discipline above.

### 3.3 Capacity

- 8 jailed tasks × 1 KiB argv blob = 8 KiB static storage.
- Matches `JS_POOL_MAX = 8` (jail_supervisor §1); the two tables are 1:1
  logically even though they are not keyed on the same ordinal (jail_supervisor
  rows are keyed by `jail_id`; this module's rows are keyed by `pid`).

---

## 4. Public API

### 4.1 `_wasi_args_register(pid, blob_ptr, blob_len) -> errno`

Mint a side-table row owning a copy of `[blob_ptr .. blob_ptr+blob_len)`.

**Semantics:**
1. `pid == 0` → `WASI_EINVAL`.
2. `blob_len > WA_BLOB_MAX` (1024) → `WASI_ENOMEM`.
3. Lookup existing row for `pid`:
   - Hit → overwrite its blob (replace semantics; M4 re-registers on execve
     without a prior deregister).
   - Miss → find a free row; if none → `WASI_ENOMEM`.
4. Copy `blob_len` bytes from `blob_ptr` into the row's slice of
   `_wasi_args_blobs`.
5. Scan the copied blob: `argc = count(NUL bytes)`.
6. Write row fields: `pid`, `blob_len`, `argc`, `argv_buf_size = blob_len`,
   `in_use = 1` LAST.
7. Return `WASI_OK`.

The blob_ptr source is a **kernel pointer** at M3 (register is called from
in-kernel paths only — not reachable from ring-3). M4 adds a user-aspace
pre-copy at the execve boundary.

### 4.2 `_wasi_args_sizes_get(pid, argc_out, argv_buf_size_out) -> errno`

Query the sizes for a WASI module to allocate its argv buffer.

**Semantics:**
1. Lookup row for `pid`; miss → `WASI_EBADF`.
2. Validate `argc_out != 0` and `argv_buf_size_out != 0` → else `WASI_EINVAL`.
3. Write `*argc_out = row.argc`, `*argv_buf_size_out = row.argv_buf_size`.
4. Return `WASI_OK`.

### 4.3 `_wasi_args_get(pid, argv_out, argv_buf_out) -> errno`

Fill the WASI module's argv-pointer array and argv-string buffer.

**Semantics:**
1. Lookup row for `pid`; miss → `WASI_EBADF`.
2. Validate `argv_out != 0` and `argv_buf_out != 0` → else `WASI_EINVAL`.
3. Byte-copy `blob_len` bytes from the row's blob slice to `argv_buf_out`.
4. Walk the copied buffer: at offset `0` and after every NUL (if more bytes
   remain), write `argv_out[k++] = argv_buf_out + offset`. Stop at `k == argc`.
5. Return `WASI_OK`.

**At M3** the `argv_out` and `argv_buf_out` pointers are **kernel pointers**
(callers from in-kernel setup paths). **M4** adds the ring-3 wiring: the WASI
runtime passes WASM-space pointers; the dispatch layer translates to kernel
pointers before invoking this function.

### 4.4 `_wasi_stdin_read(pid, iovs_ptr, iovs_len, nread_out) -> errno`

Read from the jailed task's stdin into a WASI `iovec` array.

**M3 stub posture:**
1. Lookup row for `pid`; miss → `WASI_EBADF`.
2. Validate `nread_out != 0` → else `WASI_EINVAL`.
3. Write `*nread_out = 0`.
4. Return `WASI_OK` (clean EOF stub).

**M5** replaces step 3 with: resolve `pid`'s `fd[0]` entry via its task row's
`fd_table`, decode the vnode index, dispatch to `vfs_read(vnode_idx, ...)` for
each iovec entry, sum the byte counts into `*nread_out`.

The M3 shape is deliberately useless for real I/O (every read is EOF) but
exercises the registration gate — a WASI module calling `fd_read(0, ...)`
without having been registered first still gets `WASI_EBADF` instead of a
silent success.

---

## 5. Return code band (WASI-aligned where sensible)

Per the WASI preview1 `errno` enum (same spec cite as §2):

```
WASI_OK      = 0       (success)
WASI_EBADF   = 0x08    (bad file descriptor — reused here for "pid not registered")
WASI_EINVAL  = 0x1C    (invalid argument)
WASI_ENOMEM  = 0x30    (not enough space / cannot allocate)
```

**Reuse rationale for `WASI_EBADF` on unregistered pid:** The WASI module's
view is "I asked for an fd that is not open" — the stdin fd being
unregistered is the same observational outcome. For `args_get` /
`args_sizes_get`, the alternative would be a bespoke "no argv registered"
code, but WASI preview1 does not define one; `WASI_EBADF` is the closest
spec-conformant choice (the WASI reference implementations in wasi-libc
also surface EBADF when args_get is called on a module that was not launched
with argv). M4 revisits once per-jail argv is always-present (never
unregistered post-execve); at that point `WASI_EBADF` becomes dead code on
the args_* paths and we can drop it from their justification tails.

All four codes fit `imm32` with bit 31 clear so `mov rax, imm32` emits the
7-byte zero-extending form (never `and r11, imm64` — see
feedback_pdx_encoder_pitfalls).

---

## 6. M3 → M4 → M5 milestone split

### M3 (this landing — paideia-os #2628)

- **Scope:** stub skeleton + register-side table.
- **Deliverables:**
  - `wasi_args_conv.pdx` with the four public functions.
  - `wasi-argv-stdin-conversion.md` (this file).
- **Who can call `_wasi_args_register`:** in-kernel paths only. There is no
  syscall or cap-invoke dispatch for it at M3 — the register side is a direct
  function call from kernel setup code or a kernel-side witness.
- **Who can call `_wasi_args_{sizes_get,get,stdin_read}`:** WASI-shim dispatch
  arms (not yet landed). At M3 these are callable from in-kernel witnesses
  and from any future WASI dispatch arm that opts to use them.
- **Stub posture:** `_wasi_stdin_read` on a registered pid returns clean EOF
  (0 bytes). This is **intentional**: it exercises the lookup gate without
  implying any file descriptor plumbing.

### M4 (follow-up ticket, not yet filed)

- **Scope:** wire `_wasi_args_register` into the execve boundary for WASI tasks.
- **Where:** `sys_execve.pdx` gets a new step 3.8 (after `caps_decl_apply` at
  step 3.75): if the loaded ELF declares a WASI entry point (TBD —
  `caps_decl_apply`'s manifest might also carry a `wasi = true` flag), marshal
  the parent-passed argv into a kernel blob and call `_wasi_args_register(pid,
  blob_ptr, blob_len)` before the aspace swap commits.
- **Backtrack:** M4 may surface that `blob_len > WA_BLOB_MAX` for a legitimate
  WASI launch (long argv). If so, grow `WA_BLOB_MAX` to 4 KiB (one page) and
  bump the blob store to `[u8; 32768]`. This is cheap and keeps the stride
  power-of-two (`shl rax, 12`).

### M5 (follow-up ticket, not yet filed)

- **Scope:** replace the M3 stdin EOF stub with real file-descriptor mediation.
- **Where:** `_wasi_stdin_read` resolves `pid`'s task row via a new
  `task_lookup_by_pid(pid)` helper (not yet landed), reads `fd_table[0]`,
  decodes the vnode index, and dispatches to `vfs_read` for each iovec entry.
- **Open question:** should `_wasi_stdin_read` consult the jail-supervisor's
  syscall-mask to deny stdin reads for jails that mask off `sysno(read)`?
  Current posture: no — WASI's `fd_read` is a module-level call that does not
  cross the paideia-os syscall boundary (the dispatch arm serves it directly).
  M5 revisits.

---

## 7. Encoder-pitfall posture

Per feedback_pdx_encoder_pitfalls:
- `cmp rN, 0` (never `test rN, rN`).
- `shl rN, 7` for 128-byte row stride; `shl rN, 10` for 1024-byte blob stride
  (both power-of-two — never `imul r, imm`).
- `mov rax, imm32` for all error codes (bit 31 clear on all WASI codes used —
  never `and r11, imm64`).
- Single-line `pub let name = "..."` for fingerprint tag strings.
- Module basename `WasiArgsConv` matches file basename `wasi_args_conv.pdx`
  (ddc requires exact match; task directive confirms).
- Fingerprint `[u8; N]` with `N = string length + 1` (NUL counts).
- Labels prefixed `wa_` (wasi-args) to stay clear of `js_` (jail_supervisor),
  `ss_` (shell_session), `cmnt_` (cap_minter), `ks_` (kind_shell_session) —
  and specifically out of the `w_` family (which is unused today but reserved
  for witness paths).

### Stack discipline (SysV, entry `rsp%16==8`)

```
_wasi_args_row_base        0 pushes (pure address compute)
_wasi_args_find_row        0 pushes (pure leaf scan)
_wasi_args_register        3 pushes + sub rsp, 8 (byte-copy loop state)
_wasi_args_sizes_get       1 push   (rbx = pid across lookup)
_wasi_args_get             4 pushes (rbx = pid, r12 = argv_out,
                                     r13 = argv_buf_out, r14 = row_base)
_wasi_stdin_read           1 push   (rbx = pid across lookup)
```

Entry `rsp%16==8`:
- 3-push +sub rsp,8 → `+32` → `rsp%16==0` at nested call sites.
- 1-push → `+8+8` → `rsp%16==0` at nested call sites.
- 4-push → `+8+32` → `rsp%16==8` → fallthrough body **must not call anything**
  without first adding `sub rsp, 8`. See the function's register plan.

---

## 8. Interaction with the jail supervisor

M3 does not consult `svc.jail-supervisor` on any path. The register side only
checks pool capacity (not jail membership), and the three WASI shims only
check whether the pid is registered (not whether the pid is jailed).

**Rationale:** keeping these layers orthogonal lets the WASI shims be exercised
by in-kernel witnesses without a live jail. If a future directive requires
"only jailed pids may register", it is a one-line addition to
`_wasi_args_register` (`cmp` the result of `_jail_supervisor_lookup(pid)`
against `JS_ID_NONE`). The M3 posture is "trust the caller" because the only
caller is kernel-side setup code; M4's execve hook is also kernel-side and
has already established that the pid is a WASI jail by the time it reaches
this module.

---

## 9. Follow-up tickets and open questions

- **Q1 — pool growth:** does M4's execve hook ever need more than 8
  registered pids? If so, grow `WA_POOL_MAX` to 32 (matches the near-term
  task cap) and shift to `shl rax, 7 + shl rax, 2` (still power-of-two row
  stride).
- **Q2 — blob size:** does the real workload (long argv — shell command lines
  piped into WASI binaries) exceed 1 KiB? If so, grow `WA_BLOB_MAX` to 4 KiB
  (one page) and keep stride power-of-two.
- **Q3 — table coupling:** should `_wasi_args_register` refuse pids that are
  not in `svc.jail-supervisor`? At M3 the two tables are intentionally
  decoupled (so in-kernel witnesses can test this module without a jail).
  M4 may couple them if execve wiring reveals a correctness gap.
- **Q4 — EBADF overload:** `WASI_EBADF` means "bad file descriptor" in the
  spec; we overload it to mean "pid not registered" on `args_*` paths. If a
  WASI module author surfaces this as "fd error" in their diagnostics, the
  mismatch is confusing. M4 revisits — either introduce a bespoke
  `WASI_ENOENT`-ish code for args_*, or document the overload in the WASI
  shim's own API docs.
- **Q5 — register deregister on task exit:** M3 does not drop rows on task
  exit. If a pid is recycled and a new (non-WASI) task picks it up, the old
  argv blob is still associated with that pid. M4's execve hook does a
  replace-on-register (per §4.1), which papers over the hazard for WASI
  tasks but not for a non-WASI task that reuses a dead pid. M5 adds a
  `_wasi_args_release(pid)` hook into `sys_exit`'s task-cleanup path.
