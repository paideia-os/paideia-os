---
issue: 573
milestone: R16.M1 (VFS abstract layer — superblock/inode/dentry/vnode)
subsystem: 11 — VFS abstract layer
topic: Path resolver — split-on-'/' component walk via vops_lookup (R16-M1-004)
freeze-discipline: soft (path_resolve signature is pinned for the R16 series;
  the internal component-buffer + PATH_MAX/NAME_MAX caps may grow via a
  freeze-bump issue once real workloads exercise them)
blocks:
  - "#575 (vfs_open — turns a resolved vnode idx into an fd via fd_alloc + refcount++)"
  - "R16.M4 sys_open / sys_execve — first user-facing path-string consumers"
  - "R16.M2 tmpfs directory tests — exercise real vops_lookup implementations"
touching:
  - src/kernel/core/fs/path.pdx                 (new module — resolver + scratch buffer + witness fixtures)
  - src/kernel/boot/kernel_main.pdx             (witness block ~200 LOC)
  - tools/boot_stub.S                           (2 message strings)
  - tests/r14b/expected-boot-r14b-loader.txt    (marker: "R16 PATH RESOLVE OK")
  - tests/r15/expected-boot-r15-ring3.txt       (marker: "R16 PATH RESOLVE OK")
  - tests/r15/expected-boot-r15-process.txt     (marker: "R16 PATH RESOLVE OK")
  - design/kernel/r16-m1-004-path-resolver.md   (this doc)
related:
  - design/kernel/vfs-layout.md                 (#570 — freezes VNODE_PARENT_IDX_OFFSET=+8 and the
    0xFFFF sentinel for "root or detached")
  - design/kernel/r16-m1-003-vops.md            (#572 — pins vops_lookup slot at +32; return
    convention: u16 child idx in low 16 bits, 0 = ENOENT)
  - src/kernel/core/fs/vnode_pool.pdx           (#571 — provides vnode_slot(idx) → ptr, which
    the resolver uses to obtain the vnode pointer that vops_lookup takes)
  - design/milestones/r14b-tactical-plan.md    §Subsystem 11 item 4 (VFS path-resolver contract)
---

# R16-M1-004 — path resolver (`path_resolve`, #573)

## 1. Scope

Turn a null-terminated ASCII path string ("`/tmp/x`", "`foo/bar`", "`.`",
"`..`") into a **vnode index** by walking the tree one component at a
time. Each component becomes a `vops_lookup(dir_vn, name_ptr)` call
against the current directory vnode. The resolver is the single glue
layer between "user gives us a path" and "backend answers `does this
name exist under this directory`."

Every VFS-level syscall the R16 series ships (`sys_open`, `sys_stat`,
`sys_unlink`, `sys_mkdir`, `sys_execve`) either calls `path_resolve`
directly, or calls a wrapper that does (`vfs_open` in #575, `sys_open`
in R16.M4). The resolver has no idea what backend a directory is —
that indirection lives one layer down, in the vops table it dispatches
through. It only knows:

- Absolute vs. relative (`path[0] == '/'`).
- `.` and `..` are structural, not backend queries.
- Repeated `/` collapses.
- Trailing `/` is benign.
- Component length is capped at `NAME_MAX = 63` bytes; whole path at
  `PATH_MAX = 256` bytes.

Out of scope (deliberately deferred):

- **Task-scoped cwd** as a `task_struct` field. The R15-frozen
  `task_struct` layout has no free slot in the hot half (parent_pid
  @+4, state @+8, and 168-byte prefix are pinned). Adding
  `cwd_vnode_idx` is a task-struct **re-freeze issue** that lands with
  #587 (fd_entry + cwd + credentials phase at R16.M3). At R16.M1 the
  resolver takes `cwd_vnode_idx` as an argument — callers pass whatever
  root they choose. The witness passes explicit indices; sys_open at
  R16.M4 will pass `_current_cwd_vnode_idx` (a global set at kernel
  init) until the task-struct re-freeze lands.
- **Mount-point traversal**. The `_mount_table[8]` from #574 (issue
  5 in the tactical plan) is not yet populated. A directory vnode with
  the `MOUNTPT` flag bit set (currently unused per vfs-layout.md §3
  `VNODE_FLAG_MOUNTPT = 0x08`) will grow a `mount_ptr` lookup in the
  cold half; the resolver will follow it before the vops_lookup call.
  Added at R16.M1-005 (#574).
- **Symlink following**. `VNODE_TYPE_SYMLINK = 3` is reserved but no
  resolver-side follow is implemented. Symlink following is a
  configurable-depth walk (Linux uses 40) with loop detection; lands
  when the first real symlink use case does (R18+).
- **Case folding, canonicalization to absolute, `~` expansion**.
  Shell-layer concerns; the resolver takes bytes as given.
- **Reference-count discipline on the returned vnode idx**. `path_resolve`
  returns a bare u16 in the low bits of rax. The caller (`vfs_open` at
  #575) is responsible for `vnode_hold`. No transient refcount++ during
  the walk — the tree is stable at R16.M1 (no concurrent unlink).

## 2. Signature — frozen for the R16 series

```
path_resolve : (path_ptr : u64,
                root_vnode_idx : u64,
                cwd_vnode_idx : u64) -> u64  !{mem} @{}
```

Three arguments, one return; all callee-visible in the SysV AMD64
argument registers `rdi/rsi/rdx`, return in `rax`. **`path_ptr` is a
null-terminated ASCII byte string; the other two are vnode indices as
u64-widened u16s (low 16 bits used, upper 48 must be zero).**

### 2.1 Argument semantics

| Arg | Reg | Type | Meaning                                                                        |
|-----|-----|------|--------------------------------------------------------------------------------|
| 1   | rdi | u64  | Pointer to null-terminated ASCII path. Must be non-null and safely readable up to the first `\0` or PATH_MAX bytes. |
| 2   | rsi | u64  | Root vnode idx. Used only when the path is absolute (`path[0] == '/'`). Set by the mount-table init at R16.M1-005; passed explicitly by the R16.M1 witness. |
| 3   | rdx | u64  | Cwd vnode idx. Used only when the path is relative. May be 0 if no cwd is configured — in that case a relative-path lookup fails.                        |

**Why 3 args and not 2 (start-vnode picker in the caller):** the
absolute/relative decision is a property of the path itself, not of the
call site. If the caller had to peek `path[0]` to pick between root and
cwd, every consumer (sys_open, sys_execve, vfs_open, path_resolve's own
"." handler for chdir-alike operations) would replicate that peek.
Folding it into the resolver keeps the caller side single-liner
(`call path_resolve` with both anchors passed in).

**Why not "the resolver reads a global root":** the resolver is
side-effect-free with respect to VFS state; passing anchors explicitly
lets the witness thread a fake tree through without touching kernel
globals, and lets a future re-mount / chroot layer scope roots
per-task without changing this signature.

### 2.2 Return value — u16 idx in low bits, 0 = fail

`rax` low 16 bits carry the resolved vnode idx. Upper 48 bits are
zero. **`rax == 0` is the sole failure sentinel** — matches the
"slot-0 reserved as invalid-vnode sentinel" discipline pinned by
vfs-layout.md §7.2. Every failure path — path pointer is null, empty
path, non-existent component, component too long, path too long,
`cwd_vnode_idx == 0` for a relative path — collapses to a single
`rax = 0` return.

**Why not `-1` (u64 0xFFFFFFFFFFFFFFFF) as fail:** the vops layer uses
`-1` for E_NOT_SUPPORTED — a distinct semantic ("this backend cannot
answer") from ENOENT. `vops_lookup`'s own contract already says
"`0 = ENOENT`" (r16-m1-003-vops.md §2 table row 4). The resolver
promoting that same convention up to path-level keeps the sentinel
economy: 0 = "no such file", `-1` = "backend cannot answer" (rare;
distinguished only when the caller needs to). At R16.M1 the resolver
folds both into `0` because the syscall layer above cares only about
"got a vnode" vs. "didn't." R17 may split them if a real caller needs
the discrimination.

### 2.3 Register discipline — nested-call callee

`path_resolve` makes nested `call vops_lookup` and `call vnode_slot`.
It is **not a leaf** per SysV. Prologue pushes five callee-saved
registers (`rbx`, `r12`, `r13`, `r14`, `r15`); the odd count means
`rsp mod 16` shifts from the entry state (`== 8`) to `0`, exactly the
value SysV requires at a nested `call` site. No `sub rsp, 8`
alignment pad is needed around inner calls — the prologue already
lands us on 16-byte alignment.

Loop-invariant register plan across nested calls:

| Reg | Role                                                                                                                       |
|-----|----------------------------------------------------------------------------------------------------------------------------|
| rbx | `cur` — current vnode idx (u64 with low 16 bits used). Updated at each successful component step.                         |
| r12 | `p` — path cursor. Advances one byte at a time through the input; component-copy loop moves it past the current name.       |
| r13 | `scanned` — total bytes consumed. Compared against PATH_MAX at each iteration to bound work and catch missing terminators.   |
| r14 | write cursor into `_path_component_buf` during the copy phase; used solely inside a single component iteration.             |
| r15 | `&_path_component_buf` (base). Preserved across the whole call; passed as `rsi` to `vops_lookup` after each component copy.  |

Every nested `call` sees the SysV caller-saved regs (`rax`, `rcx`,
`rdx`, `rsi`, `rdi`, `r8-r11`) as scratch — we do not rely on any of
them across the call. All state that must survive lives in the five
callee-saves listed above.

## 3. Algorithm — five phases

### 3.1 Prologue and anchor selection

```
push rbx; push r12; push r13; push r14; push r15    ; rsp%16 = 0

; sanity: path_ptr != 0
cmp  rdi, 0
je   path_fail

mov  r12, rdi                                        ; r12 = p
xor  r13, r13                                        ; r13 = scanned

; peek [p] to decide absolute vs relative
xor  rax, rax
mov_b rax, [r12]
cmp  rax, 0x2F                                       ; '/'
jne  relative_start

; absolute: cur = root, skip leading '/'
mov  rbx, rsi                                        ; cur = root_vnode_idx
add  r12, 1
add  r13, 1
jmp  validate_cur

relative_start:
mov  rbx, rdx                                        ; cur = cwd_vnode_idx

validate_cur:
cmp  rbx, 0                                          ; 0 → invalid anchor
je   path_fail
cmp  rbx, 256                                        ; VNODE_MAX
jae  path_fail
lea  r15, [rip + _path_component_buf]                ; r15 = buffer base
```

Consuming the leading `/` immediately (rather than treating the first
component as "the empty string before the first slash") is what makes
"`/`" resolve cleanly: after the skip, `scanned == 1`, `p` points at
`\0`, and the main loop's terminator check fires on the very first
iteration → returns `cur == root`. No dedicated "handle absolute root
alone" case.

### 3.2 Outer component loop — slash-skip + terminator check

```
component_loop:
  cmp  r13, 256                                      ; PATH_MAX
  jae  path_fail

  ; skip any run of '/' (collapses '//' and eats trailing '/')
skip_slashes:
  xor  rax, rax
  mov_b rax, [r12]
  cmp  rax, 0x2F                                     ; '/'
  jne  after_skip
  add  r12, 1
  add  r13, 1
  cmp  r13, 256
  jae  path_fail
  jmp  skip_slashes

after_skip:
  cmp  rax, 0                                        ; \0 → done
  je   return_cur
```

The `//` collapse and trailing-`/` are naturally handled by the
skip_slashes inner loop: consecutive `/` are eaten before any
component-copy attempt, so "`//tmp//x`" behaves identically to
"`/tmp/x`" — which is exactly one of the acceptance criteria on the
issue (`//tmp//x collapses`).

The terminator check reads the same `rax` the skip loop already
loaded — no re-load. `\0` at any position past a `/` means we have
consumed a full path and can return `cur`.

### 3.3 Inner copy loop — one component into `_path_component_buf`

```
  ; r14 = write cursor at buffer base
  mov  r14, r15
  xor  rcx, rcx                                      ; rcx = j (component length)

copy_char:
  cmp  r13, 256
  jae  path_fail

  xor  rax, rax
  mov_b rax, [r12]
  cmp  rax, 0
  je   end_component
  cmp  rax, 0x2F
  je   end_component

  cmp  rcx, 63                                       ; NAME_MAX (component too long)
  jae  path_fail

  mov_b [r14 + 0], rax                               ; store one byte
  add  r14, 1                                        ; advance write cursor
  add  r12, 1                                        ; advance path cursor
  add  r13, 1
  add  rcx, 1
  jmp  copy_char

end_component:
  mov_b [r14 + 0], 0                                 ; null-terminate the component
```

`_path_component_buf` is a 64-byte .bss scratch region (§4). The
component-copy loop maintains three cursors — `r12` (input), `r14`
(output), `rcx` (length). The pointer-advance idiom for `r14`
sidesteps a paideia-as encoder gap: `mov_b [base + idx*scale + disp],
reg` is **not currently supported** for register-source narrow stores
(see §6). Advancing the write pointer one byte at a time lets us use
the supported `mov_b [base + disp], reg` form (disp = 0) uniformly.

**Verify fix (#573 post-landing audit):** the `NAME_MAX = 63` length
gate must come *after* the terminator check, not before. The original
landed order checked `rcx >= 63` first, which fires at `rcx == 63`
before `[r12]` (the 64th input byte) is ever read again — so a
component of exactly `NAME_MAX` = 63 bytes was rejected one byte early
instead of resolving cleanly, even though 63 is the documented
maximum, not the first over-length value. Moving the gate below the
terminator check lets a legal 63-byte component reach its `'\0'`/`'/'`
on the next iteration and terminate normally, while the gate still
fires (with no store) the moment a 64th real character shows up,
so a 64+-byte component is rejected exactly as before with no
buffer overrun — `_path_component_buf` is sized exactly 64 B so a
max-length (63-byte) component plus its terminator fits with no
overrun.

### 3.4 Handle `.` and `..` before dispatching to lookup

```
  cmp  rcx, 1
  jne  check_dotdot
  xor  rax, rax
  mov_b rax, [r15 + 0]
  cmp  rax, 0x2E                                     ; '.'
  jne  regular_lookup
  jmp  component_loop                                ; "." — cur unchanged

check_dotdot:
  cmp  rcx, 2
  jne  regular_lookup
  xor  rax, rax
  mov_b rax, [r15 + 0]
  cmp  rax, 0x2E
  jne  regular_lookup
  xor  rax, rax
  mov_b rax, [r15 + 1]
  cmp  rax, 0x2E
  jne  regular_lookup

  ; ".." — read parent_idx from cur's vnode (+8, VNODE_PARENT_IDX_OFFSET)
  mov  rdi, rbx
  call vnode_slot                                    ; rax = &vnode[cur]
  xor  rcx, rcx
  mov_w rcx, [rax + 8]
  cmp  rcx, 0xFFFF                                   ; VNODE_IDX_NONE
  je   component_loop                                ; root's parent → stay at root
  mov  rbx, rcx                                      ; cur = parent
  jmp  component_loop
```

`.` and `..` are structural — they don't cost a `vops_lookup` call.
Every backend (tmpfs, devfs, procfs, ...) would have to implement them
identically otherwise; folding them into the resolver removes O(backend
count) duplication.

For `..`, the root's `parent_idx` slot carries the sentinel `0xFFFF`
(`VNODE_IDX_NONE`, pinned by vfs-layout.md §7.3). We interpret it as
"root's parent is root" — a common POSIX convention — and simply keep
`cur` unchanged. This closes the "you can't `cd ..` out of `/`"
invariant with a single `je` at the sentinel check.

The `mov_w rcx, [rax + 8]` loads a u16 into the low 16 bits of rcx;
the preceding `xor rcx, rcx` guarantees the upper 48 bits are zero,
so a subsequent `cmp rcx, 0xFFFF` (or `cmp rcx, imm32`) compares the
full u64 correctly.

### 3.5 Regular component — dispatch to `vops_lookup`

```
regular_lookup:
  mov  rdi, rbx
  call vnode_slot                                    ; rax = &vnode[cur]
  mov  rdi, rax                                      ; rdi = dir vnode ptr
  mov  rsi, r15                                      ; rsi = &_path_component_buf
  call vops_lookup                                   ; rax = child_idx | 0 | -1
  and  rax, 0xFFFF                                   ; mask to u16 idx
  cmp  rax, 0
  je   path_fail                                     ; ENOENT (or E_NOT_SUPPORTED masked to 0xFFFF)
  cmp  rax, 0xFFFF
  je   path_fail                                     ; explicit reject on masked-in-range sentinel
  mov  rbx, rax                                      ; cur = child
  jmp  component_loop
```

`vops_lookup` returns either:
- **`u16 child_idx`** in low 16 bits (success) — nonzero, < VNODE_MAX.
- **`0`** — ENOENT (r16-m1-003-vops.md §2 table row 4).
- **`VOPS_ERR_NOT_SUPPORTED = 0xFFFF...FF`** — the backend has a null
  lookup slot in its vops table.

Both failures collapse into `path_fail` after the `and rax, 0xFFFF`
mask (which leaves ENOENT as `0` and pins the E_NOT_SUPPORTED case at
`0xFFFF` — deliberately not a live vnode idx, and separately caught).

### 3.6 Epilogue

```
return_cur:
  mov  rax, rbx
  jmp  path_done

path_fail:
  xor  rax, rax

path_done:
  pop  r15; pop r14; pop r13; pop r12; pop rbx
  ret
```

## 4. Constants and storage — pinned by `src/kernel/core/fs/path.pdx`

Single source of truth. Downstream consumers (vfs_open #575, sys_open
R16.M4) encode these bounds as immediates only via re-import from this
module.

```
// Path caps
PATH_MAX          : u64 = 256              // whole-path byte budget
NAME_MAX          : u64 = 63               // per-component budget (excl. NUL)
NAME_BUF_SIZE     : u64 = 64               // _path_component_buf sizing (NAME_MAX + 1)

// Sentinels (mirrors of vnode_pool + vops constants — not re-frozen here)
PATH_IDX_FAIL     : u64 = 0                // sole failure sentinel (matches VNODE_IDX_ROOT-1)

// ASCII bytes hard-coded in the resolver — pinned for readability
BYTE_SLASH        : u64 = 0x2F             // '/'
BYTE_DOT          : u64 = 0x2E             // '.'
BYTE_NUL          : u64 = 0x00
```

### 4.1 Scratch buffer — non-reentrant at R16.M1

```
pub let mut _path_component_buf : [u8; 64] = uninit @align(8)
```

**Non-reentrant** in the sense that a single global buffer is shared
across all path_resolve calls. At R16.M1 the kernel is not preemptible
during VFS operations (interrupts are enabled but the scheduler never
runs while a syscall is in flight — R15.M7 discipline). No two path
resolutions can be simultaneously in progress on one CPU. On the AP
side, SMP is deferred to R18 — no cross-CPU sharing concern yet.

**Growth plan.** When kernel preemption during I/O lands (R17.M3 —
sleepable syscalls for TTY / pipe reads), the scratch buffer becomes
per-task: it moves into `task_struct` at the 208-byte re-freeze
(R17.M3-002) or lives on the syscall's kernel stack. Either way, a
freeze-bump issue makes the change explicit and re-runs every
downstream test.

### 4.2 Why `PATH_MAX = 256`, not 4096

R16-scale filesystems have a shallow tree (`/`, `/tmp`, `/dev`,
`/proc`, `/init`, `/bin`, plus a handful of R17 shell-created files).
The longest path we can plausibly form is ~40 bytes. 256 gives 6×
headroom and matches typical embedded caps. When R18 grows a real
persistent backend (ext2-lite or fatfs) with deeper directory trees,
PATH_MAX bumps to 1024 via a freeze-bump issue.

The `NAME_MAX = 63` cap matches historical UNIX (SunOS/HP-UX era);
POSIX minimum is 14. Modern Linux is 255. 63 is a comfortable middle
that keeps the scratch buffer at exactly one L1 cache line — every
byte of the component name fits in one line-fill from the buffer, and
`vops_lookup` on a name-string never straddles a line boundary.

## 5. Test canary — R16 PATH RESOLVE OK

The witness runs in `kernel_main` immediately after the vops witness
(§5 of r16-m1-003-vops.md). It constructs a tiny fake tree of three
vnodes and a purpose-built lookup stub, then drives `path_resolve`
through five sub-tests and one bonus.

### 5.1 Fixture setup — one stub, one vops table, three vnodes

Storage lives in `src/kernel/core/fs/path.pdx`:

```
// Witness-only fixtures — path_resolve.md §5
pub let mut _path_witness_vops_table : [u64; 7] = uninit @align(8)

pub let _path_witness_lookup_stub : (u64, u64) -> u64 !{} @{} =
  fn (dir_vn : u64) (name_ptr : u64) -> unsafe {
    // Return 2 for names starting with 'f' (foo), 3 for names starting
    // with 'b' (bar), 0 otherwise. Ignores dir_vn — the witness tree
    // is flat enough that name uniquely identifies the target.
    ...
  }
```

Kernel_main witness:

1. **Allocate three vnodes** via `vnode_alloc` — expect indices 1, 2, 3
   (first free slot after the reserved 0).
2. **Populate the fake vops table**:
   - Zero all 7 slots.
   - Write `&_path_witness_lookup_stub` into slot `+32` (`VOPS_LOOKUP_OFFSET`).
3. **Populate vnode fields** (using `vnode_slot(idx)` to get pointers):
   - **root (idx=1)**: `type` (+0) = `VNODE_TYPE_DIR = 2`;
     `parent_idx` (+8) = `0xFFFF` (root = no parent);
     `ops_ptr` (+24) = `&_path_witness_vops_table`.
   - **foo (idx=2)**: `type` = 2; `parent_idx` = 1 (root);
     `ops_ptr` = table.
   - **bar (idx=3)**: `type` = `VNODE_TYPE_REG = 1`; `parent_idx` = 2 (foo);
     `ops_ptr` = table.

### 5.2 Sub-test A — resolve `/` from root returns root

```
lea  rdi, [rip + witness_path_slash]        ; "/"
mov  rsi, 1                                 ; root_vnode_idx
xor  rdx, rdx                               ; cwd = 0 (unused for absolute)
call path_resolve
cmp  rax, 1
jne  path_witness_fail
```

Passing this proves: leading `/` triggers absolute-mode init, empty
path after the skip returns `cur` unchanged, `cur == root` in that
case.

### 5.3 Sub-test B — resolve `.` from cwd returns cwd

```
lea  rdi, [rip + witness_path_dot]          ; "."
mov  rsi, 1
mov  rdx, 2                                 ; cwd = foo
call path_resolve
cmp  rax, 2
jne  path_witness_fail
```

Proves: relative-mode init uses `cwd_vnode_idx`; `.` short-circuit
skips the `vops_lookup` call and preserves `cur`; single-component
path with no trailing slash terminates cleanly.

### 5.4 Sub-test C — resolve `..` walks to parent

Two sub-cases in one section:

**C.1 — `..` from foo returns root:**
```
lea  rdi, [rip + witness_path_dotdot]       ; ".."
mov  rsi, 1
mov  rdx, 2                                 ; cwd = foo (parent = root = 1)
call path_resolve
cmp  rax, 1
jne  path_witness_fail
```

**C.2 — `..` from root stays at root (0xFFFF clamps):**
```
lea  rdi, [rip + witness_path_dotdot]       ; ".."
mov  rsi, 1
mov  rdx, 1                                 ; cwd = root (parent_idx = 0xFFFF)
call path_resolve
cmp  rax, 1
jne  path_witness_fail
```

Together they prove: `..` reads `parent_idx` from the current vnode's
`+8` slot; the `0xFFFF` sentinel clamps to self (POSIX root-idempotent
`..`).

### 5.5 Sub-test D — resolve `/foo/bar` walks two components

```
lea  rdi, [rip + witness_path_foo_bar]      ; "/foo/bar"
mov  rsi, 1
xor  rdx, rdx
call path_resolve
cmp  rax, 3
jne  path_witness_fail
```

Proves: the outer component loop iterates; each iteration copies its
component into the scratch buffer, calls `vops_lookup`, updates `cur`
with the child idx; the final `\0` terminates the walk on the third
iteration.

### 5.6 Sub-test E — non-existent component returns 0

```
lea  rdi, [rip + witness_path_nope]         ; "/nope"
mov  rsi, 1
xor  rdx, rdx
call path_resolve
cmp  rax, 0
jne  path_witness_fail
```

The lookup stub returns 0 for any name not starting with `f` or `b`.
This proves: an ENOENT from `vops_lookup` short-circuits to
`path_fail`; the resolver returns 0 (not the previously-successful
`cur`).

### 5.7 Bonus — `//tmp//x`-style collapse (acceptance-criterion coverage)

```
lea  rdi, [rip + witness_path_double_slash] ; "//foo//bar"
mov  rsi, 1
xor  rdx, rdx
call path_resolve
cmp  rax, 3
jne  path_witness_fail
```

Same result as sub-test D; proves the `skip_slashes` inner loop
collapses redundant separators. This maps to the "AC: `//tmp//x`
collapses" line on issue #573.

### 5.8 Marker

On all sub-tests green:

```
R16 PATH RESOLVE OK
```

Fingerprint added to `tests/r14b/expected-boot-r14b-loader.txt`,
`tests/r15/expected-boot-r15-ring3.txt`, and
`tests/r15/expected-boot-r15-process.txt` on the line immediately
following `R16 VOPS OK`.

## 6. Encoder gaps and workarounds

The tactical plan (§Subsystem 11 item 4) lists this issue as
"encoder gaps: none." One narrow-mov shape does gap out under actual
use — worked around in-source, not by re-freezing the encoder.

### 6.1 `mov_b [base + idx*scale + disp], reg` — unsupported, worked around

`crates/paideia-as-encoder/src/encode_instruction.rs` `encode_mov_sized`
implements the register-source SIB-store only for the `index: None`
case (arm at ~line 563: `[MemSib { base, index: None, scale: X1, disp,
.. }, Reg(src)]`). The `index: Some(_)` arm for the same shape
(register source into a full SIB memory operand) is **absent**.
Attempting `mov_b [r14 + rcx], al` would land at the fallthrough
`OperandShape` error.

**Workaround (used in §3.3):** advance the write cursor one byte at a
time (`add r14, 1` per byte). The supported `[base + disp]` (no index)
form covers every store site in the resolver with `disp = 0`.

Cost: one extra `add r14, 1` per copied byte. Component names are
capped at 63 bytes, so worst-case 63 extra adds per resolution —
negligible.

**Deferred fix:** file a paideia-as issue to add the missing SIB-index
register-source arm at some point after R16 lands. Not on the critical
path.

### 6.2 First production consumer of `mov_b` / `mov_w` in the kernel

`grep -rn 'mov_[bwd] ' src/kernel/` returns zero hits pre-#573.
`vnode_pool.pdx`, `vops.pdx`, and the rest of the fs/ module use only
u64-wide moves. The resolver is the first consumer of narrow moves in
production kernel code.

The encoder unit-test suite (`encode_mov_sized_w8_dispatches_to_b0_imm8`
and neighbors at `crates/paideia-as-encoder/src/encode_instruction.rs`
around line 4342) exercises these encodings, so the risk of a
prod-observable encoder bug is small — but not zero. If a witness
sub-test fails with an unexpected byte pattern in the resolved
component buffer, the first thing to check is the emitted opcode for
each `mov_b` / `mov_w` site.

### 6.3 Byte and word loads leave upper bits unmodified

`mov_b rax, [r12]` writes AL only; `mov_w rax, [r14+8]` writes AX only.
Upper bits of RAX are **not** cleared by these forms (unlike a 32-bit
mov which zero-extends). Every narrow load in §3 is preceded by
`xor rax, rax` (or the target register's equivalent) so subsequent
`cmp rax, imm` compares the full u64 correctly. This is documented
inline at each site; it is not an encoder gap, it is x86 semantics.

## 7. Alternatives considered (rejected)

### 7.1 In-place delimiter substitution

**Proposal.** Overwrite each `/` with `\0` while walking, so the current
component is null-terminated at its original byte range. Pass
`p + offset` directly to `vops_lookup`. Restore the `/` after the
call.

**Rejected.** Requires the path buffer to be writable — rules out
paths in `.rodata` or in a user-supplied read-only mapping. The
sys_open call at R16.M4 will accept paths from userland; a shared
scratch buffer is a fault-hardening move (userland can never fault us
by handing us an unwriteable path).

### 7.2 Component + length pair (avoid null-termination)

**Proposal.** Change `vops_lookup`'s ABI to accept `(name_ptr,
name_len)`. Skip the buffer copy — pass `p + start_offset` and
`current_length` directly.

**Rejected at R16.M1.** Would re-freeze the vops table (r16-m1-003-vops.md
§2 row 4 pins the 2-arg signature). Every backend (tmpfs #573,
devfs R17, procfs R17) would have to grow one arg. The current
null-terminated convention keeps `vops_lookup` a one-liner internally
(`strcmp`-alike loop against each directory entry). If profiling
later shows the copy-then-lookup is a hot-path cost, we re-freeze at
R17 with a bulk update.

### 7.3 Recursive resolver (each `/` triggers a recursive call)

**Proposal.** `path_resolve(p, cur) = path_resolve(next_p, lookup(cur,
component))`. Elegant, matches classical VFS textbook.

**Rejected.** Deep paths (bounded here at PATH_MAX/2 ~ 128 components)
would burn stack frames — 128 × 40-byte SysV frames = 5 KiB, which is
within the R15 kernel stack budget but leaves no headroom for a
nested syscall path. Iterative loop with fixed loop invariants is
strictly cheaper and matches the rest of the R16.M1 module style
(vnode_pool, vops).

### 7.4 Task-scoped cwd via `task_struct` field this issue

**Proposal.** Extend `task_struct` with a `cwd_vnode_idx` slot at some
offset (176? 184? — the fd_table currently ends at 168+256 = 424; next
free offset is 424+).

**Rejected at R16.M1.** The R15 `task_struct` layout is frozen by
#543/#564. Adding a field requires a re-freeze issue — separate
scope, separate PR, separate witness. R16.M3 (fd_entry growth phase)
is the natural home for cwd, credentials, and umask together. Until
then the resolver takes cwd as an argument; the witness passes
explicit values; #575 (`vfs_open`) will use a temporary global
`_current_cwd_vnode_idx` for its sys_open plumbing until R16.M3 lands.

### 7.5 Symlink following in R16.M1

**Proposal.** Also handle `VNODE_TYPE_SYMLINK` — after any successful
`vops_lookup`, if the returned vnode's type is symlink, read its
target (a stored path string) and restart resolution.

**Rejected.** No symlink use case surfaces until R18+. Adds
loop-detection state (per-resolution depth counter, max 40 per
Linux). Adds one more field-read per component step. Better to keep
the R16.M1 resolver flat and land symlinks as an explicit R18 issue
when a consumer appears.

## 8. Invariants

### 8.1 Non-reentrant scratch buffer

`_path_component_buf` is a single-copy global. Nested `path_resolve`
calls corrupt each other's component buffer. Enforced by policy:
- Kernel is not preemptible during a VFS syscall at R16.M1 (interrupts
  are enabled but the scheduler tick handler defers a slice-end until
  syscall return).
- SMP is deferred to R18; only CPU0 executes at R16.M1.
- No syscall handler recurses through `path_resolve`.

Violation of any of these three points is a re-freeze event: buffer
moves to per-task storage.

### 8.2 `path_ptr` must be a stable, readable byte string until return

The caller guarantees `path_ptr` points at valid ASCII bytes up to
the first `\0` OR up to `PATH_MAX = 256` bytes. Between R16.M1
(kernel-space callers only) and R16.M4 (userland callers via
sys_open), this is trivially satisfied — kernel-space strings are
static or on the syscall's stack, both stable across the call. R16.M4
adds a `copy_from_user`-style path-string import that lands on the
kernel stack before `path_resolve` is invoked; the buffer becomes
stable at that boundary.

### 8.3 Return-value discipline

- On success: `rax` low 16 bits ∈ [1, VNODE_MAX) — a live, allocated
  vnode idx.
- On failure: `rax == 0` exactly. Upper 48 bits always zero on both
  paths (no partial-mask bug from the `and rax, 0xFFFF` step).

Callers may test `rax == 0` in place of a null check; the "slot-0
reserved as invalid-vnode sentinel" discipline pinned by
vfs-layout.md §7.2 guarantees `0` is never a live idx.

### 8.4 Vnode side effects — none

`path_resolve` does not increment `refcount` on any vnode it visits or
returns. It reads `parent_idx` at `+8` and calls `vops_lookup` (which
reads directory backend state but does not mutate the vnode struct).
The vnode returned in `rax` has the same refcount before and after
the call. `vfs_open` (#575) is responsible for `vnode_hold` on the
returned idx.

### 8.5 Failure economics — no error propagation state

Every failure path collapses to `rax = 0`. The resolver does not
distinguish "bad component" from "path too long" from "cwd is 0" —
callers see one binary outcome. R17+ may split them if `errno`-style
feedback becomes required (as it will at the userland-syscall
boundary); the split is a signature-widening issue that leaves the
successful-return convention untouched.

## 9. Performance sketch

Per-component cost (hot cache):
- Skip-slashes inner loop: 1-2 byte-load + cmp/je per byte, typically
  1 byte of leading `/` per component after the first, 0 in the last.
- Copy-char inner loop: ~4 instructions per byte (load, compare, store,
  advance) × component length (~4-8 bytes typical) = ~16-32 instructions
  per component.
- `.` / `..` fast path: skips the vops_lookup call entirely — pure
  register arithmetic.
- Regular component: 1 × `vnode_slot` (3 instructions) + 1 ×
  `vops_lookup` (dispatcher ~11 instructions + backend `strcmp`-alike
  ~O(name_len × dir_entries)). At R16.M2 tmpfs directories are ~4
  entries deep, so per-component cost is well under 200 cycles.

Whole-path cost for `/tmp/x` (3 components, 6 bytes): ~600 cycles
warm, ~2 kilocycles cold (worst case one L1D miss per vnode field
access). Not the hot path for anything at R16 scale.

## 10. Growth plan (R17 and beyond)

- **R16.M1-005 (#574) — mount points.** After a successful
  `vops_lookup`, if the returned vnode's `flags` byte at `+1` has the
  `VNODE_FLAG_MOUNTPT` bit set (per vfs-layout.md §3), the resolver
  follows the mount by loading a `mount_ptr` field from the vnode's
  cold half. This adds ~5 instructions to the regular-component step.
  Frozen at R16.M1-005 in a follow-on issue.
- **R16.M3 (#587-adjacent) — task-scoped cwd.** `task_struct` grows a
  `cwd_vnode_idx` field. `sys_open` reads it via `current->cwd`
  instead of a global. Resolver signature unchanged (cwd is still an
  arg — the caller does the field load).
- **R17.M2 — reference-count discipline.** Under a `--follow` flag,
  the resolver `vnode_hold`s each intermediate vnode during the walk
  and `vnode_put`s them at return. Prevents concurrent unlink from
  invalidating the walk. Requires signature widening (flag arg).
- **R17.M3 — sleepable resolution.** Once `vops_lookup` may block
  (waiting on a page-in for a real backend), the scratch buffer moves
  to per-task. Re-freeze issue with new invariant.
- **R18+ — symlinks + PATH_MAX 1024.** Both are freeze-bump issues
  with their own witnesses.

## 11. Cross-references

- Issue: paideia-os#573
- Milestone: R16.M1 (VFS abstract layer)
- Upstream: #570 (vnode layout — pins `VNODE_PARENT_IDX_OFFSET = +8`
  and the `0xFFFF` "root/detached" sentinel), #571 (vnode_pool —
  provides `vnode_slot` and the u16 idx contract), #572 (vops
  dispatch — the resolver dispatches through `vops_lookup`).
- Downstream consumers: #574 (mount table — extends the
  regular-component step with mount-point traversal), #575
  (`vfs_open` — first user; wraps `path_resolve` + `vnode_hold` +
  fd_alloc), R16.M4 (`sys_open`, `sys_execve`, `sys_stat`, `sys_mkdir`,
  `sys_unlink` — every path-taking syscall).
- Sibling doc: `design/kernel/r16-m1-003-vops.md` §3.1 (register
  discipline) — same pattern applied to a longer nested-call function.
- Encoder verification: mnemonic table entries `mov_b`, `mov_w`,
  `mov_q`, `xor`, `cmp`, `je`, `jne`, `jae`, `add`, `sub`, `call`,
  `ret`, `push`, `pop`, `lea` all in
  `crates/paideia-as-elaborator/src/unsafe_walker.rs` MNEMONIC_TABLE
  (lines 91-304). The one gap surfaced in §6.1 is worked around
  in-source without touching the encoder.
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 11 item 4 (line 1252 onwards) — pins the file location
  (`src/kernel/core/fs/path.pdx`) and the ACs (`/tmp/x → dentry`,
  `//tmp//x collapses`, `bad component → -ENOENT`).

---

## Amended by R17-M0-665

**Change**: path_resolve now uses `vnode_cache_or_alloc` to allocate vnodes on-demand during component lookup (regular_lookup block).

**Impact on witness**: Sub-test D (resolve "/foo/bar") no longer asserts a specific vnode_idx; instead, it:
1. Asserts the return value is non-zero and non-0xFFFF (valid vnode).
2. Inspects the returned vnode's backend_ptr at +32, masking to low 16 bits.
3. Asserts backend_ptr & 0xFFFF == 3 (bar's backend index from witness_lookup_stub).

The key insight: vnode_cache_or_alloc may deduplicate or allocate different vnode slots on repeated calls (depending on cache state), but the backend_ptr invariant holds: it always identifies the backend inode index that vops_lookup returned.
