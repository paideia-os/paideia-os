# WASI-jail / command-registry wire-up

**Status:** M7 skeleton, 2026-10-14.
**Umbrella:** paideia-os R135 ("WASI-jail: a sandboxed execution environment for WASI / WebAssembly modules running on paideia-os").
**Milestone:** R135.M7 (paideia-os #2632, Wave UMB-W21).
**Companion substrates:**
- [kind_cmd_module.pdx](../../src/kernel/core/cap/kind_cmd_module.pdx) (R123.M1 command-registry row pool; kind tag 0x5C)
- [functor_invoke.pdx](../../src/kernel/core/shell/functor_invoke.pdx) (R123.M3 in-process functor-invoke ABI)
- [functor_invoke_oop.pdx](../../src/kernel/core/shell/functor_invoke_oop.pdx) (R123.M4 OOP spawn-based functor-invoke)
- [jail_supervisor.pdx](../../src/kernel/core/svc/jail_supervisor.pdx) (R135.M1 WASI-jail daemon)
- [wasi_args_conv.pdx](../../src/kernel/core/wasi/wasi_args_conv.pdx) (R135.M3 WASI argv register)
- [wasi_fd_mediation.pdx](../../src/kernel/core/wasi/wasi_fd_mediation.pdx) (R135.M6 fd mediation)
**Companion module:** [cmd_jail_wire.pdx](../../src/kernel/core/shell/cmd_jail_wire.pdx) (this landing)

---

## Table of contents

1. Why a shim (not a direct call into jail_supervisor)
2. Dispatch decision tree
3. Public API
   - 3.1 `_cmd_jail_wire_dispatch(cmd_row_id, argv_ptr, argc, caller_cap_env_slot) -> errno`
   - 3.2 `_cmd_jail_wire_mark_wasi(row_id) -> errno`
   - 3.3 `cjw_marshal_wasi_blob(src_argv_ptr, argc) -> packed u64`
4. Row-flags convention
5. Interaction with R123.M3/M4 and R125.M4
6. Argv-format bridge
7. Return code band
8. Fingerprints
9. Encoder-pitfall posture
10. What ships in M7 vs. follow-ups
11. Testing posture

---

## 1. Why a shim (not a direct call into jail_supervisor)

R135.M1 through R135.M6 landed the WASI-jail substrate piecemeal: the
jail daemon's row pool, the per-jail spawn primitive, the argv/stdin
plumbing, the stdout_records substrate, the WIT bridge, and the fd
mediation layer. Each of those primitives is independently callable;
each has its own return code band and its own observability contract.

What was missing: a single CALL SITE that composes those primitives
into "the shell dispatched a command and the command happens to be a
WASI binary." The composition is not a single function because:

* The dispatch decision is NOT "always wire through the jail." A
  command row may be a classic in-process shell builtin (no isolation
  needed), an isolated-but-native functor (OOP spawn only, no WASI),
  or a WASI binary that MUST run inside a jail. The composition
  branches on the row's flags word.

* The composition's error band is coarser than the sum of its parts:
  the shell cares about "did this command dispatch succeed, and if not,
  was it a bad command, a spawn failure, or an in-process shadow miss?"
  Not about which of five sub-primitives failed. The shim collapses
  the finer bands into three errnos.

* The composition owns ONE kernel-global argv-blob scratch so each
  dispatch does not stack-allocate 1 KiB on an already-tight shell
  thread stack. The scratch's lifetime is scoped to the duration of
  the dispatch call because the dispatch is serial at M7 (one shell
  thread, no concurrent command invocations).

The shim is `cmd_jail_wire.pdx`. It introduces NO new substrate; its
only state is the WASI argv-blob scratch (1024 bytes) and an 8-slot
observability counter array.

## 2. Dispatch decision tree

On entry the shim has:

| arg                   | shape                                               |
|-----------------------|-----------------------------------------------------|
| `cmd_row_id`          | `u64` in `[0, CM_MODULE_MAX=8)` — caller has already resolved a command name to this row via `kcm_find_hash` and knows it is live |
| `argv_ptr`            | `u64` pointer to `[ptr0, len0, ptr1, len1, ...]` — the (ptr,len)-tuple-list format `_functor_invoke_oop_spawn` consumes |
| `argc`                | `u64` arg count, `1..=255` by convention            |
| `caller_cap_env_slot` | `u64` row_id into the KIND_CAP_ENV substrate; the jail inherits this slot verbatim at M7 |

The dispatch tree, in order:

1. **Row LIVE gate.** `kcm_row_live(cmd_row_id)` must return 1, else
   `CJW_ERR_BAD_ROW` (`0x2000`). This also pins `row_id` in the
   kernel-protected range.
2. **Flags load.** `flags := _kcm_table[row_id * 48 + 32]`.
3. **Mis-configuration gate.** `(flags & CM_FLAG_WASI) != 0 AND
   (flags & CM_FLAG_ISOLATE) == 0` is REJECTED with `CJW_ERR_BAD_ROW`.
   A WASI binary MUST run isolated (its jail depends on an own-aspace
   spawn); the parser must set both bits together.
4. **Case split on (ISOLATE, WASI):**

   | ISOLATE | WASI | path                                                                       |
   |:-------:|:----:|----------------------------------------------------------------------------|
   | 0       | 0    | **In-process.** Load `_fi_entry_va[row_id]`; zero → `CJW_ERR_IN_PROCESS`. Else `_functor_invoke_call(entry_va, argv_ptr, argc)`. |
   | 1       | 0    | **OOP, no jail.** Resolve name via `kcm_read_name` into a 64-byte stack scratch; call `_functor_invoke_oop_spawn(name_ptr, name_len, argv_ptr, argc)`. Nonzero errno → `CJW_ERR_JAIL_SPAWN`. |
   | 1       | 1    | **WASI pipeline** (see below).                                             |
   | 0       | 1    | **REJECTED** at step 3 (`CJW_ERR_BAD_ROW`).                                |

5. **WASI pipeline** (ISOLATE=1, WASI=1):

   a. Resolve name via `kcm_read_name(row_id, &name_scratch[0])`. Dead
      row → `CJW_ERR_BAD_ROW` (defensive; the live gate already proved
      liveness, but `kcm_read_name` has its own gate and we honour its
      sentinel).

   b. `_functor_invoke_oop_spawn(name_ptr, name_len, argv_ptr, argc)` →
      packed `(pid << 32) | errno`. Nonzero errno → `CJW_ERR_JAIL_SPAWN`.
      Extract `child_pid := packed >> 32`.

   c. `cjw_marshal_wasi_blob(argv_ptr, argc)` converts the
      (ptr,len)-tuple list into a flat NUL-separated byte blob in
      `_cjw_wasi_blob`. Overflow (`> CJW_BLOB_MAX=1024`) →
      `CJW_ERR_JAIL_SPAWN`. Returns packed `(total_bytes << 32) | 0`.
      Extract `blob_len := packed >> 32`.

   d. `_jail_supervisor_create(child_pid, caller_cap_env_slot,
      mask_lo=0, mask_hi=0, name_ptr, name_len)`. Low-2-bits of the
      packed result encode the errno (`JS_OK=0` on success). Nonzero →
      `CJW_ERR_JAIL_SPAWN`. (The deny-all syscall allowlist at M7 is
      intentional: the follow-up installs the WASI syscall allowlist.
      For M7, a WASI binary is fail-closed past the cap-check — see §5.)

   e. `_wasi_args_register(child_pid, &_cjw_wasi_blob[0], blob_len)`.
      `WASI_OK=0` on success. Nonzero → `CJW_ERR_JAIL_SPAWN`.

6. **Emit fingerprint and return.**

## 3. Public API

### 3.1 `_cmd_jail_wire_dispatch(cmd_row_id, argv_ptr, argc, caller_cap_env_slot) -> errno`

The entry point. Signature:

```
_cmd_jail_wire_dispatch
    : (u64, u64, u64, u64) -> u64
      effects {mem, sysreg}
      capabilities {cap, sched}
```

`cap` for the jail_supervisor cap-env traversal; `sched` for the OOP
spawn's task_new/clone_cow pipeline (inherited from
`_functor_invoke_oop_spawn`).

### 3.2 `_cmd_jail_wire_mark_wasi(row_id) -> errno`

Kernel-trusted setter that OR-s `CM_FLAG_WASI` (`0x4`) into
`_kcm_table[row*48 + 32]` after the parser already set
`CM_FLAG_LIVE | CM_FLAG_ISOLATE` via `cmd_module_open`. Returns `CJW_OK`
on success or `CJW_ERR_BAD_ROW` if the row is not live.

Direct precedent is `_functor_invoke_oop_set_isolate` in
`functor_invoke_oop.pdx`. The parser-side wiring that calls this on
reading `wasi = true` from `/system/shell/commands.toml` is deferred
to the `cmd_registry_parser` follow-up (bundled with the `isolate`
reader slice from R123.M4 UMB-W6).

### 3.3 `cjw_marshal_wasi_blob(src_argv_ptr, argc) -> packed u64`

Internal helper (not `_`-prefixed; `pub` only to simplify dependency
expression). Walks the (ptr,len)-tuple list, copies each argv entry
into `_cjw_wasi_blob` with a trailing NUL byte, overflows if the
cumulative size exceeds `CJW_BLOB_MAX=1024`.

Returns `(total_bytes << 32) | 0` on success, `(0 << 32) |
CJW_ERR_JAIL_SPAWN` on overflow.

The one-blob scratch limits concurrent dispatch to one in-flight call
at M7; this is acceptable because the shell is single-threaded. A
later R135 slice that lands a per-session shell may grow this to a
pool indexed by session.

## 4. Row-flags convention

The flags word at `_kcm_table[row*48 + 32]` is a bitfield:

| bit | mask  | name              | setter                                        | owner      |
|:---:|-------|-------------------|-----------------------------------------------|------------|
| 0   | `0x1` | `CM_FLAG_LIVE`    | `cmd_module_open` (publish-last)              | R123.M1    |
| 1   | `0x2` | `CM_FLAG_ISOLATE` | `_functor_invoke_oop_set_isolate` (idempotent OR) | R123.M4 (UMB-W6) |
| 2   | `0x4` | `CM_FLAG_WASI`    | `_cmd_jail_wire_mark_wasi` (idempotent OR)    | R135.M7 (THIS LANDING) |
| 3-63 | —    | reserved          | —                                             | —          |

The parser-side wiring for both ISOLATE and WASI bits is deferred to a
later `cmd_registry_parser` extension slice; the setters here let the
bits be exercised from a kernel-trusted test harness in the meantime.

Enforced constraints:

* `WASI=1, ISOLATE=0` is **rejected** at dispatch time with
  `CJW_ERR_BAD_ROW`. The parser must set both bits together.
* `ISOLATE=0, WASI=0` is a classic in-process shell builtin.
* `ISOLATE=1, WASI=0` is an OOP native binary (not a WASI module).
* `ISOLATE=1, WASI=1` triggers the full WASI pipeline.

## 5. Interaction with R123.M3/M4 and R125.M4

**R123.M3 `_functor_invoke_call`** — the in-process arm. The shim
calls it directly with `(entry_va, argv_ptr, argc)` and propagates its
`i64` return verbatim (lossy cast to `u64`; the shell interprets any
negative return).

**R123.M4 `_functor_invoke_oop_spawn`** — the OOP arm, used for both
the (ISOLATE=1, WASI=0) and (ISOLATE=1, WASI=1) paths. The shim
collapses the packed `(pid<<32)|errno` return into a boolean fail/
not-fail via a low-32 mask; the pid is preserved only when the pipeline
continues into jail-create.

**R125.M4 `_syscall_cap_check`** — the jail allowlist chains AFTER
the cap-check (see `design/shell/jail-supervisor-daemon.md` §6.2). At
R135.M7 the shim passes `mask_lo=0, mask_hi=0` to
`_jail_supervisor_create`: the WASI binary is fail-closed past the
cap-check. The follow-up slice (R135.M8+) extends the shim to carry a
per-command syscall allowlist derived from the TOML `wasi_syscalls`
key.

**Leak posture.** If `_jail_supervisor_create` or
`_wasi_args_register` fails AFTER a successful spawn, the shim does
NOT reap the child. The child task slab is leaked at M7. The follow-up
R135.M8 teardown slice closes this by replacing the direct propagation
with a `cjw_abort_spawn(child_pid)` helper that walks
`sys_wait_body`'s zombie-and-reap pipeline. For M7, we accept the leak
so the entry-level errno band stays at three codes.

## 6. Argv-format bridge

The shim bridges two incompatible argv formats:

**FIO format** (`_functor_invoke_oop_spawn` input, matching
`fio_marshal_argv` in `functor_invoke_oop.pdx` §3):

```
+0  u32 argc
+4  u32 total_bytes
+8  u32 offsets[0]
+12 u32 offsets[1]
...
+8+4*argc  bytes "arg0\0arg1\0...\0"
```

Delivered to the OOP child task through `_fio_argv_scratch` (a
kernel-global 4096-byte buffer).

**WASI format** (`_wasi_args_register` input):

```
+0  bytes "arg0\0arg1\0...\0"       (NUL-separated, no header)
```

Delivered to the WASI runtime through `_wasi_args_blobs[pid*1024]`
(the WASI argv row pool).

The two formats differ in **shape** (header + offsets array vs. bare
concatenation) and in **size ceiling** (4096 vs. 1024 bytes). The
shim's `cjw_marshal_wasi_blob` walks the SAME (ptr,len)-tuple-list
input the shell hands to the dispatch entry and writes the WASI shape
into `_cjw_wasi_blob`, leaving the OOP spawn's own call to
`fio_marshal_argv` to independently fill `_fio_argv_scratch`. The two
marshals run from the same input but write to different buffers; this
is intentional — the formats are source-of-truth-separated so a later
format change on either side does not require a cross-module edit.

If `blob_len > 1024`, the WASI marshal overflows and the shim returns
`CJW_ERR_JAIL_SPAWN`. The OOP spawn's 4096-byte ceiling is NOT
re-imposed here; it is `_functor_invoke_oop_spawn`'s own gate.

## 7. Return code band

| code             | value   | meaning                                                                                               |
|------------------|:-------:|-------------------------------------------------------------------------------------------------------|
| `CJW_OK`         | `0`     | dispatch dispatched successfully (the dispatched functor's own return is in `rax` for in-process)     |
| `CJW_ERR_BAD_ROW` | `0x2000` | row_id out of range, not LIVE, or (`WASI=1, ISOLATE=0`) mis-configuration                           |
| `CJW_ERR_JAIL_SPAWN` | `0x2001` | OOP spawn OR jail_create OR wasi_args_register OR argv-blob marshal failed                      |
| `CJW_ERR_IN_PROCESS` | `0x2002` | in-process arm hit an unbound `_fi_entry_va[row_id]` shadow slot                                 |

All three error codes fit `imm32` with bit 31 clear, so
`mov rax, imm32` zero-extends to `u64` directly. No `r9` staging and
no `and r11, imm64` dance.

Grep audit at landing time:
`grep -rnE '\b0x200[012]\b' src/kernel/core/shell/` returned 0
non-encoder-offset occurrences.
`grep -rnE 'CJW_(OK|ERR_)' src/` returned 0 occurrences.

## 8. Fingerprints

Three events, byte counts NUL-inclusive:

```
CJW DISPATCH rowid=0x<id> flags=0x<flags>   // in-process arm fingerprint
CJW DISPATCH rowid=0x<id> pid=0x<pid>       // OOP / WASI arm fingerprint
CJW BAD_ROW rowid=0x<id>                    // row LIVE gate failure
CJW MARK rowid=0x<id>                       // _cmd_jail_wire_mark_wasi success
```

Emits via `klog_s1_x2` (hex + hex, 7th argument spilled at
`[rsp+0]` after `sub rsp, 16` per Wave 73 I7 regression) or
`klog_s1_x1` (single-hex) as appropriate. Subsys tag is `SUBSYS_CAP_`
(same as every other R123.M* / UMB-W1-W6 file emits — the dispatch is
cap-adjacent even when it is actually a shell op; there is no
`SUBSYS_SHELL` constant yet).

Observability counters at `_cjw_stats[0..8]`:

| slot | ordinal                 | increment event                          |
|:----:|-------------------------|------------------------------------------|
| 0    | `CJW_ST_DISPATCH_INPROC` | in-process dispatch dispatched          |
| 1    | `CJW_ST_DISPATCH_OOP`    | OOP dispatch dispatched (no WASI wiring)|
| 2    | `CJW_ST_DISPATCH_WASI`   | full WASI pipeline dispatched            |
| 3    | `CJW_ST_BAD_ROW`         | row LIVE gate failure                   |
| 4    | `CJW_ST_IN_PROCESS_FAIL` | `_fi_entry_va` shadow unbound           |
| 5    | `CJW_ST_JAIL_SPAWN_FAIL` | spawn / jail-create / argv-reg failure  |
| 6    | `CJW_ST_MARK_WASI_OK`    | `_cmd_jail_wire_mark_wasi` succeeded    |
| 7    | `CJW_ST_MARK_WASI_FAIL`  | `_cmd_jail_wire_mark_wasi` rejected     |

## 9. Encoder-pitfall posture

* **Row-flag masks** (`0x1`, `0x2`, `0x4`) fit `imm32`; staged through
  `r11` for the AND gate. No `and r11, imm64` ever.
* **Row stride 48** encoded as `mov r11, 48; imul rax, r11` (reg-reg);
  never the 2-op `imul r, imm` form.
* **Liveness tests** use `cmp rN, 0` (never `test rN, rN`).
* **Error constants** `0x2000..0x2002` fit `imm32`; emit via
  `mov rax, imm32`.
* **Module basename** `CmdJailWire` matches `cmd_jail_wire.pdx`.
* **Every label** prefixed `cjw_` (reserved-word discipline: `loop`,
  `if`, `let` are keywords).
* **All `pub let` string declarations** are single-line.
* **Fingerprint tag** `[u8; N]` literals have `N = string length + 1`
  (trailing NUL counts). `N` spelled next to each literal for audit.
* **`klog_s1_x2` 7th stack argument** lives at `[rsp+0]` AFTER
  `sub rsp, 16` per the Wave 73 I7 regression memory.
* **Byte-copy loops** use `mov_b r,[rbx+rcx*1]` with `xor r10, r10`
  pre-zero (encoder does not zero-extend 8-bit loads on its own, per
  pipe_backend.pdx §57).
* **Alignment math** for `_cmd_jail_wire_dispatch`: entry `rsp%16==8`,
  6 pushes (`48` bytes) + `sub rsp, 88` land `rsp%16==0` at nested
  calls (`8 + 48 + 88 = 144`, `144 % 16 == 0`). `klog_s1_x2` adds
  `sub rsp, 16` which keeps `rsp%16==0`.
* **Frame layout** under `rbp` (`sub rsp, 88` = 88-byte frame):
  * `[rbp-64..rbp]` — 64-byte name scratch (`CJW_NAME_MAX`)
  * `[rbp-72..rbp-64]` — `child_pid` spill (8 bytes)
  * `[rbp-80..rbp-72]` — `blob_len` spill (8 bytes)
  * `[rbp-88..rbp-80]` — alignment pad (8 bytes)

## 10. What ships in M7 vs. follow-ups

**Ships in M7:**

- `_cmd_jail_wire_dispatch(cmd_row_id, argv_ptr, argc,
  caller_cap_env_slot) -> errno` — the full dispatch tree with all
  three arms (in-process, OOP-no-jail, OOP+WASI-pipeline).
- `_cmd_jail_wire_mark_wasi(row_id) -> errno` — the parser-side setter
  for the `CM_FLAG_WASI` bit.
- `cjw_marshal_wasi_blob` — the (ptr,len)-tuple-list → NUL-separated
  bridge marshaller.
- `CM_FLAG_WASI = 0x4` claim on the `_kcm_table[row*48 + 32]` flags
  word.
- Three-code return band `CJW_OK | CJW_ERR_BAD_ROW |
  CJW_ERR_JAIL_SPAWN | CJW_ERR_IN_PROCESS`.
- Four observability counters per arm (OK/fail).
- Fingerprints on every exit path.

**Deferred to a follow-up (R135.M8+):**

- Parser-side `wasi = true` / `isolate = true` reader slice in
  `cmd_registry_parser.pdx` that calls the `_cmd_jail_wire_mark_wasi`
  / `_functor_invoke_oop_set_isolate` setters at TOML parse time.
- Per-command WASI syscall allowlist derived from the TOML
  `wasi_syscalls` key, carried into `_jail_supervisor_create`'s
  `mask_lo` / `mask_hi` arguments instead of the current `0, 0`
  deny-all.
- Child-task reap on jail-create / wasi-args-register failure
  (currently leaks the child slab; see §5 Leak posture).
- Per-session argv-blob scratch pool (currently one kernel-global
  scratch limits dispatch to serial; acceptable at M7 because the
  shell is single-threaded).
- Shell-dispatch loop that drives `_cmd_jail_wire_dispatch` — the
  shell_main that reads from the TTY, resolves a command name to a
  `_kcm_table` row, and calls the dispatch entry. This arrives bundled
  with the user-space shell materialisation (R127.M+ / R129.M+); for
  now the shim is callable from a kernel-trusted test harness.

## 11. Testing posture

The shim's three arms are independently exercisable from a kernel-
trusted witness:

1. **In-process arm.** Open a cmd row via `cmd_module_open`, bind a
   functor VA via `_functor_invoke_bind`, call
   `_cmd_jail_wire_dispatch(row_id, argv_ptr, argc, 0)` with
   `caller_cap_env_slot = 0`. Expect `CJW_OK` and
   `_cjw_stats[CJW_ST_DISPATCH_INPROC] == 1`.

2. **OOP-no-jail arm.** Same as (1), then call
   `_functor_invoke_oop_set_isolate(row_id)`. Dispatch should take the
   OOP path, spawn a child, and return `CJW_OK` with
   `_cjw_stats[CJW_ST_DISPATCH_OOP] == 1`.

3. **Full WASI arm.** Same as (2), then call
   `_cmd_jail_wire_mark_wasi(row_id)`. Dispatch should take the WASI
   pipeline, spawn a child, create a jail row, register the argv blob,
   and return `CJW_OK` with `_cjw_stats[CJW_ST_DISPATCH_WASI] == 1`.
   The jail row's `pid` field matches the spawned child's pid; the
   WASI argv row's `blob_len` matches the marshalled blob's byte
   count.

4. **Mis-configuration.** Set `CM_FLAG_WASI` directly on the flags
   word WITHOUT `CM_FLAG_ISOLATE`. Dispatch returns `CJW_ERR_BAD_ROW`
   and `_cjw_stats[CJW_ST_BAD_ROW] == 1`.

5. **Overflow.** Pass an argv whose cumulative bytes exceed 1024.
   Dispatch returns `CJW_ERR_JAIL_SPAWN` (`cjw_marshal_wasi_blob`
   overflow) and `_cjw_stats[CJW_ST_JAIL_SPAWN_FAIL] == 1`.

The dispatch's fingerprints are observable through the klog UART tail;
the counter array can be read directly from `_cjw_stats` via a
cap-table read of the KIND_MEMORY cap that overlays the kernel data
section.
