# Out-of-process functor invoke ABI (R123.M4)

**Issue:** paideia-os#2588 (UMB-W6 R123.M4)
**Code:** `src/kernel/core/shell/functor_invoke_oop.pdx`
**Depends on:**
  - `src/kernel/core/cap/kind_cmd_module.pdx` (UMB-W1 R123.M1, KIND_CMD_MODULE=0x5C)
  - `src/kernel/core/shell/cmd_registry_parser.pdx` (UMB-W4 R123.M2)
  - `src/kernel/core/shell/functor_invoke.pdx` (UMB-W5 R123.M3, same KIND row pool)
  - `src/kernel/core/syscall/handlers/sys_fork.pdx` (sys_fork_body shape; this file mirrors but does not call it)
  - `src/kernel/core/syscall/handlers/sys_exit.pdx` (sys_exit_body — child drains here)
  - `src/kernel/core/syscall/handlers/sys_wait.pdx` (sys_wait_body — parent reaps here)
  - `src/kernel/core/sched/task_pool.pdx` (task_new, pid_free, task-slab offsets)
  - `src/kernel/core/mem/aspace_clone.pdx` (aspace_clone_cow)
  - `src/kernel/core/sched/runqueue.pdx` (runq_enqueue)
  - `src/kernel/core/sched/switch.pdx` (sched_switch_r15_continuation — landing convention)
**Status:** landed 2026-10-11.

---

## 1. Purpose and scope

R123.M3 landed the in-process invoke boundary: a shell command name resolves to a functor VA, and the shell dispatches it with a direct `call rax` in its own address space. That works for trusted built-ins — `echo`, `pwd`, `set` — where a bug in the functor is a bug in the kernel and the shell can share its stack and cap env with the callee.

R123.M4 adds the opposite case: a functor the shell does not trust at the stack-sharing level. Think of a user-authored script loaded dynamically, or a third-party command module whose capability footprint should not touch the shell's own. For these, the shell:

1. Spawns a child task with a fresh COW-cloned aspace.
2. Hands the child the functor VA and a packed argv buffer.
3. Lets the scheduler drive the child; waits via `sys_wait_body`.
4. Receives the child's exit code as the functor's result.

The trust boundary is **the aspace, the pid, and the cap env** — not the ring. The functor runs ring-0 in paideia-os today (userspace is still being materialised); the "isolation" is that a fault inside the functor dies in a scheduler-owned pid, not inside the shell's. R125 adds the cap-env narrowing; R30+ adds the ring-3 boundary.

Non-scope: the shell dispatcher that picks between the in-process (M3) and out-of-process (M4) arm. No dispatcher exists yet in `src/kernel/core/shell/`; the picker is a follow-up slice.

---

## 2. When to use OOP vs. in-process

| Dimension | In-process (M3) | Out-of-process (M4) |
| --- | --- | --- |
| Aspace | shell's own | fresh COW-cloned from shell |
| Pid | shell's own | fresh pid via `pid_alloc` |
| Stack | shell's own kernel stack | child's per-pid kernel stack |
| Fault domain | shared with shell | child only; `sys_exit_body` reaps |
| Cap env | shell's | narrowed to functor's declared caps (R125) |
| Scheduler | synchronous (same slice) | asynchronous (new runq entry) |
| Return path | `rax` from direct `call` | `exit_status` from `sys_wait_body` |
| Overhead | ~10 instructions | ~`fork+exec`-level: `task_new` + `aspace_clone_cow` + `fd_table` copy + fingerprint |
| Argv passing | registers / shell's own buffer | marshalled packed buffer (§3) |

The pick is per-command. The registry row's `flags` word (`_kcm_table[row+32]`) carries bit 1 = `CM_FLAG_ISOLATE` to encode it; see §4. The decision belongs to whoever MINTS the row — currently the parser (R123.M2) via its parse of `isolate = true` in `commands.toml` (follow-up; §9).

The in-process path is the default. OOP is opt-in by setting `isolate = true` on the command's TOML section. Reasons to opt in:

- **Capability narrowing**: the shell holds a broader cap env than the functor needs; crossing an aspace boundary makes the narrowing enforceable at the page-table level once R125 lands.
- **Fault containment**: a functor that may crash should not take the shell with it. `sys_exit_body` reaps the child; the shell sees the exit code and moves on.
- **Stack discipline**: a functor with deep recursion or a large stack frame should not share the shell's kernel stack. Each child has its own `_task_kernel_stacks[pid]`.
- **Future ring-3 crossing**: when the shell materialises ring-3, every OOP child becomes a candidate for ring-3 execution via `sys_execve_body`; the in-process path cannot cross rings without rework.

Reasons NOT to opt in:

- The functor is a leaf primitive (echo, pwd) where the overhead of `fork+exec` exceeds the work by two orders of magnitude.
- The functor manipulates shell-local state (environment, cwd) that only in-process access can touch.
- The functor's success is observed through side effects on the shell's own address space (e.g. parsing into shell locals).

---

## 3. Argv marshalling format

The packed buffer at `_fio_argv_scratch` (4096 bytes, `.bss`, kernel-mapped high half so both parent and child observe the same bytes without COW split):

```
offset  width  field
-----   -----  -----
+0      u32    argc           -- argument count (>= 1)
+4      u32    total_bytes    -- bytes 0..total_bytes-1 are valid
+8      u32    offsets[0]
+12     u32    offsets[1]
...
+8+4*(argc-1)  u32  offsets[argc-1]
+8+4*argc      bytes  argv[0] (NUL-terminated)
...
```

### 3.1 Invariants

- `argc >= 1`. Zero-argc dispatch is rejected at the entry with `FIO_ERR_ARGV_TOO_BIG` (same errno as overflow — both are not-a-legitimate-invocation shapes).
- `total_bytes <= 4096`. Overflow returns `FIO_ERR_ARGV_TOO_BIG`.
- `offsets[0] == 8 + 4*argc`. The first string starts immediately after the offset table.
- `offsets[i+1] == offsets[i] + strlen(argv[i]) + 1`. Each string carries its own terminating NUL inside its byte range.
- `offsets[argc-1] + strlen(argv[argc-1]) + 1 == total_bytes`.

### 3.2 Caller contract (shell side)

The shell passes a flat 16-byte-per-entry (ptr, len) tuple list:

```
+0*16  ptr0  u64
+0*16+8  len0  u64
+1*16  ptr1  u64
+1*16+8  len1  u64
...
```

The marshaller (`fio_marshal_argv`) walks it in two passes: a size pass that computes cursor positions and gates overflow, and a copy pass that writes each argv string into `_fio_argv_scratch` at its offset. The caller does NOT share argv memory with the child — the scratch buffer is the handoff.

### 3.3 Callee contract (functor side)

The functor is invoked with:

- `rdi = &_fio_argv_scratch` (the whole buffer, header included)
- `rsi = argc`

The functor can walk the offsets table to recover each argv[i] as a NUL-terminated byte range. The buffer is read-only in intent; functors that write to it corrupt siblings' argv. The follow-up slice adds a per-child copy before the handoff.

### 3.4 Why packed, not pointer-array

A pointer array (`char **argv`) would require either (a) userspace pointers that cross a COW boundary with the parent's layout preserved — impossible without a mapping contract we don't have — or (b) kernel-space pointers that the functor then dereferences, which negates the isolation we're building. Packed byte offsets dodge both: the only pointer the functor dereferences is the buffer base, and that base is the same (kernel-high-half) VA in both parent and child.

---

## 4. Isolate flag

### 4.1 Where it lives

Bit 1 of the KIND_CMD_MODULE row's `flags` word at `_kcm_table[row+32]`. The row shape (kind_cmd_module.pdx §2) already specifies `flags` with bit 0 = `CM_FLAG_LIVE`, bits 1..63 reserved. UMB-W6 claims bit 1:

```
flags bits:
  0  CM_FLAG_LIVE     -- row is valid (published)
  1  CM_FLAG_ISOLATE  -- dispatch via OOP path (M4 claim)
  2..63  reserved
```

We do **not** grow the row. The reserved u64 slot at `_kcm_table[row+40]` stays reserved for R125's `cap_env_ptr`. Adding a column there would ripple through every KIND_CMD_MODULE witness and every cap/invoke dispatch stride, and the one-bit flag has no reason to exist as its own column.

### 4.2 How it's set

Two paths:

1. **Parser-side (follow-up slice)**: `cmd_registry_parser.pdx` recognises `isolate = true` in a `[command.NAME]` section's keys. After `cmd_module_open` mints the row and returns `row_id`, the parser calls `_functor_invoke_oop_set_isolate(row_id)`.

2. **Direct kernel-boot binding**: for built-ins we want to isolate from the start, `kernel_main.pdx` (or a seed-time hook) can call `_functor_invoke_oop_set_isolate(row_id)` after `_functor_invoke_bind` has populated the shadow.

The setter is **not** publish-last. `CM_FLAG_LIVE` is already published; the shell reads the full `flags` word with a single aligned 8-byte `mov`, so both bits are observed atomically within one load. There is no reader that sees `ISOLATE` set but `LIVE` clear.

### 4.3 How it's queried

Three primitives expose it:

- `_functor_invoke_oop_is_isolated(row_id) -> u64` — returns 1 iff LIVE and ISOLATE both set, 0 otherwise. The shell dispatcher consults this to pick the arm.
- `_functor_invoke_oop_spawn(...)` — refuses with `FIO_ERR_NOT_ISOLATED` if the row is LIVE but not ISOLATE. The caller can retry via the M3 path.
- Direct read of `flags` and-mask against `CM_FLAG_ISOLATE = 0x2`.

---

## 5. Three public primitives

### 5.1 `_functor_invoke_oop_spawn(name_ptr, name_len, argv_ptr, argc) -> u64`

Resolve a command name, verify isolate, marshal argv, spawn child.

| Register in | Meaning |
| --- | --- |
| `rdi` | `name_ptr` -- byte pointer |
| `rsi` | `name_len` -- bytes at `name_ptr` |
| `rdx` | `argv_ptr` -- flat `[ptr0, len0, ptr1, len1, ...]` buffer |
| `rcx` | `argc` |

| Register out (packed) | Bits |
| --- | --- |
| `rax[63:32]` | `child_pid` on success, 0 on failure |
| `rax[31:0]`  | 0 on success, errno (`FIO_ERR_*`) on failure |

The packed shape mirrors the M3 lookup's low-bit-tagged return and the kernel's existing `{rax, rdx}` convention for syscalls that return a two-field tuple. Callers unpack with `pid = rax >> 32; errno = rax & 0xFFFFFFFF`.

### 5.2 `_functor_invoke_oop_wait(child_pid) -> i64`

Drain the next zombie child.

| Register in | Meaning |
| --- | --- |
| `rdi` | `child_pid` -- stashed for the fingerprint; NOT yet used as a filter |

| Register out | Meaning |
| --- | --- |
| `rax` | `exit_status` on success (0..255 or wider i64), `-ECHILD` (`0xF...FF6`) on no-children, `-EAGAIN` (`0xF...FF5`) on would-block |

The M4 primitive drains the next zombie regardless of pid (POSIX `wait()` semantics). A caller that fired multiple OOP spawns must either reap in-order and track the mapping itself, or wait for the follow-up slice that adds a pid filter.

### 5.3 `_functor_invoke_oop_set_isolate(row_id) -> u64`

Mark a row as isolate-dispatched.

| Register in | Meaning |
| --- | --- |
| `rdi` | `row_id` -- in `[0, 8)` |

| Register out | Meaning |
| --- | --- |
| `rax` | `FIO_OK` on success, `FIO_ERR_NOT_FOUND` if row_id is out of range or the LIVE bit is clear |

---

## 6. IPC path

### 6.1 Parent → child

The parent builds the packed buffer in `_fio_argv_scratch` and passes its base VA to `fio_spawn_task` as `argv_scratch_va`. `fio_spawn_task` stores the VA in the child slab at `TASK_OFF_FIO_ARGV_PTR = 1752`, along with the functor VA at `+1744` and argc at `+1760`. The child's landing (`fio_oop_child_landing`) reads those three slab fields and sets up the SysV call.

No `sys_ipc_send` is involved. The buffer is kernel-mapped high-half memory; both parent and child's pml4s share the same high-half mapping, so the VA is identical in both aspaces. The follow-up slice swaps this for a real `sys_ipc_send` + `sys_ipc_recv` round-trip once the shell materialises as a ring-3 process.

### 6.2 Child → parent

The child's functor returns an i64 in `rax`. `fio_oop_child_landing` then calls `sys_exit_body(current, exit_code)`, which:

1. Marks the child `STATE_ZOMBIE` and stores `exit_code` in `[current+12]` (per sys_exit.pdx).
2. Wakes any parent waiting via `sys_wait_body`.
3. Dequeues and switches to the next runnable task.

The parent, blocked (or soon-blocked) in `_functor_invoke_oop_wait → sys_wait_body`, finds the child in `_pid_table`, reads its exit_status, and calls `pid_free`. The child's slab is reclaimed by task_free (sched/tasks.pdx) on the next cycle.

---

## 7. Isolation guarantees

### 7.1 At M4

- **Fresh pid**: `task_new(parent)` allocates a new slot via `pid_alloc`; collisions impossible until pid pool exhausts.
- **Fresh aspace**: `aspace_clone_cow` installs a new pml4 whose user-half entries are copy-on-write of the parent's. User-space writes diverge; kernel-high-half remains shared (`_fio_argv_scratch` lives there).
- **Fresh kernel stack**: `task_new` populates `TASK_OFF_KSTACK_TOP = 24` with `&_task_kernel_stacks + pid*16384` (per #728 D9). A child's syscall path uses its own stack; the shell's call-chain cannot be clobbered.
- **Independent fault domain**: a #PF, #UD, or kernel panic in the functor stays inside the child's scheduler lineage. `sys_exit_body` on a trap path reaps the child normally.

### 7.2 Pending at M4 (R125 adds)

- **Cap-env narrowing**: the child currently inherits the parent's cap env (via COW aspace share). R125 wires `_kcm_table[row+40]` to a `cap_env_ptr` that `fio_spawn_task` installs into the child slab before enqueue; `cap_invoke` on the child then narrows against that env.
- **Fd table narrowing**: the child inherits all 32 fds (via `fd_table` copy + `fd_inherit_hold`); R125+ adds a `fd_isolate_filter` that keeps only CLOEXEC-cleared fds + a per-functor whitelist.
- **IPC endpoint narrowing**: the child inherits none of the parent's IPC endpoints at M4 (none exist in the fd_table today). When they do, the same whitelist applies.

### 7.3 Not planned

- **Ring-3 execution**: paideia-os is still ring-0; the OOP boundary is aspace + pid, not ring. Ring-3 is a later cascade.
- **Timeout**: `_functor_invoke_oop_wait` blocks indefinitely (or returns EAGAIN immediately). A timeout variant lands when sched_wait_ns gets a shell-caller.

---

## 8. Interaction with R123.M3

### 8.1 Same lookup, different dispatch arm

Both the M3 in-process primitive and the M4 OOP primitive resolve a name by:

1. `kcm_name_hash(name_ptr, name_len)` -- djb2 u64.
2. `kcm_find_hash(hash)` -- linear scan over the row pool, returns `row_id` or `0xFF`.
3. `_fi_entry_va[row_id]` -- the M3 shadow carries the functor VA.

M3 then does `call rax` with the VA. M4 reads `flags` first, checks `ISOLATE`, marshals argv, and spawns.

### 8.2 Shared constants

- `FIO_ROW_MAX = FI_ROW_MAX = CM_MODULE_MAX = 8`
- `FIO_NAME_MAX = FI_NAME_MAX = CM_NAME_MAX = 64`
- `FIO_KCM_ROW_NONE = FI_KCM_ROW_NONE = CM_ROW_NONE = 0xFF`

Each file defines its own copy to avoid cross-module namespace imports.

### 8.3 Shared shadow

Both M3 and M4 read `_fi_entry_va` (defined in functor_invoke.pdx). The M3 bind path (`_functor_invoke_bind`) is the only writer; M4 is a read-only consumer. This keeps the write side single-sourced.

### 8.4 Non-shared taxonomy

M3's errno band is `0x0C21..0x0C23`; M4's is `0x0C41..0x0C44`. The gap at `0x0C24..0x0C3F` is deliberate — an R123.M5 (bus/async) landing can occupy it without bumping either neighbour.

---

## 9. Follow-up slices (deferred)

| Slice | Owner file | What it adds |
| --- | --- | --- |
| **9.a parser isolate** | `cmd_registry_parser.pdx` | parses `isolate = true` in a section's keys; calls `_functor_invoke_oop_set_isolate(row_id)` |
| **9.b real IPC marshal** | `functor_invoke_oop.pdx` | swaps `_fio_argv_scratch` for a `sys_ipc_send` + `sys_ipc_recv` round-trip; needed once the shell materialises as ring-3 |
| **9.c cap-env sealing** | `functor_invoke_oop.pdx` + R125 | derives the child's cap env from the functor's declared caps; installs before enqueue |
| **9.d pid-filtered wait** | `functor_invoke_oop.pdx` | adds a `child_pid` filter to `_functor_invoke_oop_wait` so a shell firing N OOP spawns can reap each one independently |
| **9.e per-child kstack hand-off** | `functor_invoke_oop.pdx` | fio_oop_child_landing moves rsp onto `_task_kernel_stacks[pid]` before the functor call, instead of running on the in-slab tail |
| **9.f ring-3 crossing** | future | OOP children execve to a userspace entry; moves the whole mechanism across the ring boundary |

Each slice is independently landable; none blocks the others.

---

## 10. Encoder discipline

Standard paideia-as discipline, same as functor_invoke.pdx §4:

- `cmp reg, 0` for every zero-check (never `test rN, rN`).
- `and reg, reg` only (no `and reg, imm64`).
- `shl` for stride multiplies (no 2-op `imul r, imm`).
- `mov reg, [mem]` + `cmp reg, reg2` (no `cmp reg, [mem]`).
- `mov_b` byte load preceded by `xor r10, r10` for zero-extension (encoder does not zero-extend on its own).
- `mov_d` 4-byte stores for u32 writes (argv header + state field).
- Single-line `pub let` string / byte-array declarations.
- Fingerprint tag `[u8; N]` byte-array literals have `N = string length + 1` (NUL counts).
- Module basename `FunctorInvokeOop` matches file basename `functor_invoke_oop.pdx`.
- Entry `rsp % 16 == 8`; alignment pad lands `rsp % 16 == 0` at nested-call sites.

Labels use the `fio_` top-level prefix with inner-second-level demarcation:

- `fio_sp_` — spawn (internal task-materialisation helper)
- `fio_sp_x_` — spawn public API body (distinguishes from internal `fio_sp_`)
- `fio_wa_` — wait
- `fio_mg_` — marshal
- `fio_sr_` — shadow-reset
- `fio_cl_` — child-landing
- `fio_si_` — set-isolate
- `fio_cq_` — check-isolated
- `fio_nt_` — note (stats bump)

---

## 11. Failure taxonomy

| Code | Name | When |
| --- | --- | --- |
| `0x0000` | `FIO_OK` | success |
| `0x0C41` | `FIO_ERR_NOT_FOUND` | name does not resolve to a LIVE row, or the row's M3 shadow entry is zero |
| `0x0C42` | `FIO_ERR_NOT_ISOLATED` | row is LIVE but `CM_FLAG_ISOLATE` is clear (caller should take the M3 path) |
| `0x0C43` | `FIO_ERR_SPAWN` | `task_new` OOM, `aspace_clone_cow` OOM, or any other spawn-step failure |
| `0x0C44` | `FIO_ERR_ARGV_TOO_BIG` | `argc == 0` or marshalled total bytes exceed `FIO_ARGV_BUF_SIZE` (4096) |

Band audit (2026-10-11):
- `cmd_registry_parser.pdx` (R123.M2): `0x0C01..0x0C04`
- `functor_invoke.pdx` (R123.M3): `0x0C21..0x0C23`
- `functor_invoke_oop.pdx` (R123.M4): `0x0C41..0x0C44` — THIS FILE
- Gap `0x0C24..0x0C3F` reserved for R123.M5.

All four codes fit imm32 (zero-extend to u64 via `mov rax, imm32` 7-byte emit).

---

## 12. Observability

`_fio_stats[8]` carries per-primitive counters:

| Slot | Name | Bumped by |
| --- | --- | --- |
| 0 | `FIO_ST_SPAWN_OK` | successful spawn |
| 1 | `FIO_ST_SPAWN_NF` | spawn: name not found |
| 2 | `FIO_ST_SPAWN_NI` | spawn: not isolated |
| 3 | `FIO_ST_SPAWN_FAIL` | spawn: `task_new` / `aspace_clone_cow` OOM |
| 4 | `FIO_ST_SPAWN_ARGV` | spawn: argv too big |
| 5 | `FIO_ST_WAIT_OK` | wait: zombie reaped |
| 6 | `FIO_ST_WAIT_NONE` | wait: `-ECHILD` or `-EAGAIN` |
| 7 | `FIO_ST_SETISO_OK` | set_isolate: committed |

Fingerprint emission:
- `FUNCTOR SPAWN pid=0x<pid> errno=0x<e>` via `klog_s1_x2` on both success and failure arms.
- `FUNCTOR WAIT pid=0x<pid> status=0x<status>` via `klog_s1_x2` on every wait exit.
- `FUNCTOR ISOLATE rowid=0x<row>` via `klog_s1_x1` on successful set.
- `ARGV MARSHAL bytes=0x<n>` via `klog_s1_x1` on overflow (future enablement).

All fingerprints use `SUBSYS_CAP_` (same subsystem as R123.M3 and the KIND_CMD_MODULE substrate; follow-up may fan out a dedicated `SUBSYS_SHELL`).

---

## 13. Known gaps

- **(G1)** Parser does not yet set `CM_FLAG_ISOLATE`. Until §9.a lands, every row stays non-isolate; `_functor_invoke_oop_spawn` on a row always returns `FIO_ERR_NOT_ISOLATED`. Boot witnesses can set the bit directly via `_functor_invoke_oop_set_isolate` for M4 testing.
- **(G2)** No per-child kernel stack hand-off at the oop-landing. The child's first functor call runs on the tail of the slab (8 bytes above the landing RA slot). Functors with any depth will overflow into unrelated slab fields. §9.e lands the hand-off.
- **(G3)** No pid filter in `_functor_invoke_oop_wait`. Multiple concurrent spawns reap in zombie-arrival order, not spawn order. §9.d lands the filter.
- **(G4)** No cap-env narrowing. The child inherits the parent's cap env; R125 narrows it.
- **(G5)** `_fio_argv_scratch` is a single global buffer. Concurrent spawns race on it. §9.b (real IPC) replaces this with per-spawn message payloads.

Each gap is documented inline at the file's SECTION 0 "DEFERRED" list.

---

## 14. Audit queries

```bash
# Verify no other file claims 0x0C41..0x0C44
grep -rnE '0x0C4[0-9A-Fa-f]' src/
# Expected: only functor_invoke_oop.pdx

# Verify TASK_OFF_FIO_* slots don't collide
grep -rnE 'TASK_OFF_[A-Z_]+ *: *u64 *= *17(4[4-9]|5[0-9]|6[0-9])' src/
# Expected: only functor_invoke_oop.pdx

# Verify CM_FLAG_ISOLATE bit not reused
grep -rn 'CM_FLAG_ISOLATE\|FIO_FLAG_ISOLATE' src/
# Expected: declaration in functor_invoke_oop.pdx + possibly parser follow-up
```
