---
issue: 587
milestone: R16.M3 (fd table + open/read/write/close/dup2)
subsystem: 13 — file-descriptor + open/read/write/close/dup2
topic: sys_open — compose vfs_open + fd_alloc + fd_set into a fd-returning syscall body
prereq:
  - "#549 (fd_table embed — LANDED at 22437af; provides fd_alloc / fd_get / fd_set)"
  - "#575 (vfs_open — LANDED; provides vnode_idx-returning path open with refcount++)"
  - "R16.M2 (tmpfs backend — LANDED; provides / mount + tmpfs vops table)"
blocks:
  - "#588+ (sys_read / sys_write — consume the fd_table entry format frozen here)"
  - "#591 (sys_close — inverse: fd_set(0) + vfs_close on fd_table entry)"
  - "#593 (sys_dup2 — copy fd_table[src] to fd_table[dst], vfs refcount++)"
  - "R17 (userland shell demo — first end-to-end user of sys_open via SYSCALL entry)"
touching:
  - src/kernel/core/syscall/handlers/sys_open.pdx  (new module — ~90 LOC incl. justification)
  - src/kernel/boot/kernel_main.pdx                (witness block ~90 LOC + _sys_open_witness_task slab)
  - tools/boot_stub.S                              (3 rodata strings: ok_msg, fail_msg, witness_path_tmp)
  - tests/r14b/expected-boot-r14b-loader.txt       (marker: "R16 SYS OPEN OK")
  - tests/r15/expected-boot-r15-ring3.txt          (marker)
  - tests/r15/expected-boot-r15-process.txt        (marker)
  - design/kernel/r16-m3-001-sys-open.md           (this doc)
related:
  - design/kernel/r15-m5-007-fd-table-embed.md     (#549 — freezes FD_TABLE_OFFSET=168, FD_TABLE_MAX=32,
                                                    scan-from-3 discipline; documents u64 slot with sentinel-0
                                                    contract that sys_open extends here into a packed encoding)
  - design/kernel/r16-m1-006-vfs-open.md           (#575 — the composed primitive; §4.4 O_CREAT stub is a
                                                    KNOWN GAP called out in §6 below)
  - design/kernel/r15-m6-003-sys-fork.md           (#554 sys_fork_body — the mirror pattern: explicit
                                                    `current` argument in rdi, 3-push prologue, negative-
                                                    errno u64 returns)
  - design/milestones/r14b-tactical-plan.md        §Subsystem 13 (line ~1050) — the fd-table + open/read/
                                                    write/close/dup2 sequence
---

# R16-M3-001 — `sys_open`: compose `vfs_open` + fd allocation into the first fd-returning syscall (#587)

## 1. Scope

Land the R16.M3 subsystem-13 entry point:

```
sys_open_body(current, path_ptr, flags, mode) -> u64
    rdi = current      (task_struct*)
    rsi = path_ptr     (const char*, NUL-terminated)
    rdx = flags        (u64 bitmask — passed to vfs_open)
    rcx = mode         (u64 — accepted but IGNORED at R16.M3; see §6.5)
    rax = fd (>= 3) on success, negative-errno u64 on failure
```

`sys_open_body` is a pure **three-step composition** of already-landed
primitives:

1. `vnode_idx = vfs_open(path_ptr, flags)` — resolves the path, bumps
   refcount, returns u16 idx (or 0 on failure) (#575).
2. `fd = fd_alloc(current)` — linear scan `[3, 32)` of `current->fd_table`
   for the first zero slot; returns fd or `0xFFFFFFFFFFFFFFFF` (EMFILE)
   (#549).
3. `fd_set(current, fd, entry)` — stores the packed `entry` u64 into
   `current->fd_table[fd]` (#549).

The **entry** is a `u64` encoded per this doc's freeze (§3.2):

```
bits [ 0, 16):  vnode_idx     (u16)
bits [16, 64):  file_offset   (u48, initialized to 0 at open)
```

Because a valid `vnode_idx` is never `0` (vfs_open returns 0 to mean
failure), the composite entry is never `0` for an allocated slot — so
the R15.M5 fd_table sentinel-`0`-means-free discipline (frozen by #549
§3.4) composes cleanly with the packed encoding.

### 1.1 What this issue proves

- **sys_open composes into a working fd-returning syscall body.** The
  three-primitive pipeline (`vfs_open → fd_alloc → fd_set`) is exercised
  end-to-end for a real success path, with fd allocation returning
  `3, 4, 5` across three consecutive opens on a fresh task.
- **The packed fd_table entry format is frozen.** `entry = vnode_idx |
  (offset << 16)` becomes the R16.M3 contract that #588 (sys_read),
  #589 (sys_write), and #591 (sys_close) all read/write. This is the
  narrower successor to the R15.M5 "opaque u64" contract; still 8 B
  per slot, still sentinel-`0`-means-free, but now with semantically
  frozen bit-field layout.
- **The negative-errno u64 return convention is established for the
  fd-table subsystem.** Matches the pattern already frozen by
  `sys_fork_body` (#554) and `sys_exit_body` (#557): `rax` sign-extends
  a small negative i32 into a u64 whose top bits are all 1s.

### 1.2 What this issue deliberately does NOT do

- **No `sys_read` / `sys_write` / `sys_close` / `sys_dup2` bodies.**
  Those are #588, #589, #591, #593. Only sys_open lands here — the
  bare minimum for R16.M3 subsystem-13 item 1 in the tactical plan.
- **No path parsing.** The path string is passed through to `vfs_open`
  unchanged. `vfs_open` calls `path_resolve`; sys_open has no path-
  parsing logic of its own.
- **No `mode` handling.** The `mode` argument (rcx) is accepted but
  never inspected at R16.M3. Real mode → type translation
  (`S_IFREG | 0644` → `VNODE_TYPE_REG`) lands with #588's siblings
  when userland actually cares. Rationale: §6.5.
- **No `vfs_open` refcount rollback on EMFILE.** If `fd_alloc` returns
  EMFILE after `vfs_open` already succeeded, the vnode's refcount is
  now permanently one too high — a leak. R16.M3 acceptance does not
  exercise the EMFILE path (fd_table is fresh), so the leak is
  documentation-only. #591 (`sys_close`) followup lands the paired
  `vfs_close` call on EMFILE and every future error branch. §6.4.
- **No task-scoped cwd.** `vfs_open` is called with cwd=0 internally.
  Relative paths remain rooted at `/`. Real cwd tracking lands with
  R16.M3's later issues (`sys_chdir` and friends).
- **No SYSCALL entry wiring.** `sys_open_body` is testable in kernel
  context via the witness (§5). Wiring `sys_open_body` to the
  `syscall_dispatch` table (accessible from ring-3 via `syscall`
  instruction) lands with a followup R17-tempo issue — see §6.1.
- **No stdin/stdout/stderr population.** Fresh `_sys_open_witness_task`
  has fd_table[0..32] all zero. `fd_alloc` starts at index 3 by
  design (#549), so the first sys_open returns 3 regardless of whether
  0/1/2 are populated. Real `tty` binding to fd[0/1/2] is #1613.

## 2. Prereq check

### 2.1 What is in place

| Primitive               | Location                                        | Contract used                                                    |
|-------------------------|-------------------------------------------------|------------------------------------------------------------------|
| `vfs_open`              | `core/fs/vfs_open.pdx` (#575, LANDED)           | `(path_ptr, flags) -> vnode_idx or 0`. Success bumps refcount at vnode +4. |
| `fd_alloc`              | `core/fs/fd_table.pdx:44` (#549, LANDED)        | `(task) -> fd (u64)`. Scans `[3, 32)`; returns `0xFFFFFFFFFFFFFFFF` on EMFILE. |
| `fd_set`                | `core/fs/fd_table.pdx:30` (#549, LANDED)        | `(task, fd, val) -> ()`. Single SIB+disp store `mov [rdi + rsi*8 + 168], rdx`. |
| `fd_get`                | `core/fs/fd_table.pdx:16` (#549, LANDED)        | `(task, fd) -> u64`. Sub-test D reads entry back. |
| `FD_TABLE_OFFSET`       | `core/fs/fd_table.pdx:8`                        | `168` (byte offset within task_struct — pinned by #543). |
| `FD_TABLE_MAX`          | `core/fs/fd_table.pdx:9`                        | `32` (slot count). |
| `tmpfs` `/` mount       | `core/fs/mount.pdx` via kernel_main line 1971   | Root vnode published as `_mount_table[0].root_idx`. |
| `witness_path_slash`    | `tools/boot_stub.S:603`                         | The string `"/"` — reused by the witness (§5) for consecutive opens. |
| `_pid_table` / `_task_pool` | `core/sched/task_pool.pdx`                  | Not used — witness uses a dedicated 278-u64 `.bss` blob mirroring #549. |

### 2.2 What is NOT in place (KNOWN GAP — see §6.1 for resolution)

**vfs_open's O_CREAT path is a REACHED-but-returns-0 stub** (see
`src/kernel/core/fs/vfs_open.pdx:109`):

```asm
// O_CREAT is set: for R16.M1, this is a REACHED-but-returns-0 stub.
// Real create body deferred to R16.M2 tmpfs backend (design §4.6).
jmp  vfs_open_fail;                     // R16.M1: return 0
```

That branch was NOT completed in R16.M2 (the tmpfs backend landed but
`vfs_open` was not extended to call `vops_create` on the parent). This
means that the issue-body's aspirational acceptance criterion
"`sys_open("/tmp/x", O_CREAT|O_RDWR, 0644)` returns 3" **cannot pass
end-to-end** through the composition:

- `vfs_open("/tmp/x", O_CREAT | O_RDWR)` currently returns 0 (path
  not found → O_CREAT branch taken → stub jump to failure).
- `sys_open` therefore returns `-ENOENT`.
- The AC fd sequence `3, 4, 5` never materializes.

**Resolution.** The witness (§5) is designed to satisfy the *spirit*
of the AC — "three consecutive opens return `3, 4, 5`" — using an
**existing path** (`"/"`, already published by the mount witness at
kernel_main.pdx:1968–1989). The **literal AC** is deferred to the
follow-up issue proposed in §6.1 (`vfs_open O_CREAT completion` —
new issue in R16.M3). That follow-up wires `vops_create` on the
parent vnode when the leaf is missing and O_CREAT is set. Once that
lands, the witness can be extended (or a `boot_r16_process` smoke
added) to exercise the literal AC.

This is called out unambiguously here so a reviewer does not chase
`R16 SYS OPEN OK` printing while `/tmp/x` remains uncreatable.

### 2.3 Encoder gaps

**None.** `sys_open_body` uses only patterns proven pervasively:

| Mnemonic                 | Proven at                                     |
|--------------------------|-----------------------------------------------|
| `push r64` / `pop r64`   | Every function with a callee-save prologue.   |
| `mov r64, r64`           | Every function.                               |
| `call sym` (direct near) | Pervasive.                                    |
| `cmp r64, imm32`         | Pervasive (all error-sentinel comparisons).   |
| `mov r64, imm64`         | Every large-immediate site (e.g. sys_fork.pdx line 73: `mov rax, 0xFFFFFFFFFFFFFFF4`). |
| `je` / `jne` / `jae` / `jmp` | Every control-flow site.                  |

No SIB, no REX.B-extended-base gotchas, no ADR-relative constants,
no XMM/AVX. sys_open is arithmetically simpler than `sys_fork_body`.

## 3. Design

### 3.1 File and module structure

New file: `src/kernel/core/syscall/handlers/sys_open.pdx`. Sits alongside
the four existing handler files in that directory:

```
src/kernel/core/syscall/handlers/
    sys_execve.pdx   (#555)
    sys_exit.pdx     (#557)
    sys_fork.pdx     (#554)
    sys_wait.pdx     (#556)
    sys_open.pdx     <-- THIS ISSUE
```

Module name: `SysOpen`. Public export: `sys_open_body`.

### 3.2 Fd-table entry encoding (frozen)

```
type FdEntry = u64
  bits [ 0, 16):  vnode_idx    : u16   ; the vnode index from vfs_open's return
  bits [16, 64):  file_offset  : u48   ; byte-granular; 0 on open; advanced by
                                       ; sys_read/sys_write; wraps at 2^48-1
                                       ; (256 TiB — beyond any practical use
                                       ; at R16.M3)
```

**Composability with the R15.M5 sentinel-0 discipline.** An entry of
value `0` means "slot free". A valid `vnode_idx` is always `> 0`
(`vfs_open` returns 0 to mean failure per `vfs_open.pdx:137`; the vnode
pool's `vnode_alloc` never publishes idx 0 — verified against
`vnode_pool.pdx`). Therefore a successfully-populated slot has
`entry & 0xFFFF != 0`, so the whole u64 is non-zero. The `fd_alloc`
loop's `cmp rax, 0; je fd_alloc_found` (fd_table.pdx:56) correctly
sees the slot as allocated after `fd_set`.

**Field extraction primitives** (used by `sys_read` / `sys_write` /
`sys_close` in #588 / #589 / #591):

```
vnode_idx = entry & 0xFFFF
offset    = entry >> 16
new_entry = (offset << 16) | (entry & 0xFFFF)     ; offset update, idx frozen
```

None of those extractors land here — sys_open only WRITES entries.
The extractor codepaths land with their consuming syscalls.

**Why bit-packed and not a separate offset table?** R15.M5 pinned
`FD_ENTRY_SIZE = 8` (fd_table.pdx:11 header) with the reserved
1280-byte pad after fd_table to allow widening to a 24-byte
`{vnode_ptr, offset, flags, refcount}` record at some future R16/R17
tempo (see #549 §3.1 the "reserved padding" comment). Bit-packing
inside u64 avoids consuming any of that reservation now — R17 can
still widen to 24 B without a re-freeze. The u48 offset ceiling
(256 TiB) never binds at R16.M3 or R17. The `flags` and `refcount`
fields are `sys_close`-time concerns (#591) that land in the
widening.

**Why offset in the high bits (not the low)?** Because `vnode_idx`
in the low 16 bits lets a single `and rax, 0xFFFF` recover the idx
— same mask already frozen by the tmpfs backend_ptr contract at
`design/kernel/r16-m2-008-tmpfs-vops-wire.md` §3.1. The offset
sits high because its increment (`add high_word, len`) doesn't need
to mask or shift when the idx is untouched — R16.M3's read/write
increment sequence is `entry += (len << 16)`, one add, one write-back.

### 3.3 `sys_open_body` — body sequence

```asm
; ================================================================
; sys_open_body(current, path_ptr, flags, mode) -> u64
;   rdi = current
;   rsi = path_ptr
;   rdx = flags
;   rcx = mode          ; ACCEPTED-BUT-IGNORED at R16.M3 (§6.5)
;
; Returns rax:
;   fd (u64, in [3, 32))          on success
;   0xFFFFFFFFFFFFFFFE (-ENOENT)   if vfs_open returned 0
;   0xFFFFFFFFFFFFFFE8 (-EMFILE)   if fd_alloc returned 0xFFFFFFFFFFFFFFFF
;
; Register discipline:
;   rbx = current           (saved across vfs_open, fd_alloc, fd_set)
;   r12 = vnode_idx / entry (saved across fd_alloc, fd_set)
;   r13 = fd                (saved across fd_set)
;   rax/rcx/rdx = scratch
;
; Prologue: push rbx, r12, r13.  Entry rsp % 16 == 8 (SysV post-call);
; 3 pushes drop rsp by 24, giving rsp % 16 == 0 at the nested call
; sites — same alignment idiom as sys_fork_body (#554 §prologue).
; ================================================================
sys_open_body:
    push rbx
    push r12
    push r13

    ; --- Save arguments in callee-save regs ---
    mov rbx, rdi                        ; rbx = current
    ; rsi (path_ptr), rdx (flags) already in the right regs for vfs_open;
    ; rcx (mode) unused, will be clobbered by fd_set below — that's OK
    ; because we don't need it after this point.

    ; --- Phase 1: vfs_open(path_ptr, flags) ---
    mov rdi, rsi                        ; rdi = path_ptr
    mov rsi, rdx                        ; rsi = flags
    call vfs_open                       ; rax = vnode_idx or 0

    cmp rax, 0
    je  sys_open_enoent

    mov r12, rax                        ; r12 = vnode_idx (also serves as
                                        ;        the packed entry — offset=0
                                        ;        means high 48 bits are 0)

    ; --- Phase 2: fd_alloc(current) ---
    mov rdi, rbx
    call fd_alloc                       ; rax = fd or 0xFFFFFFFFFFFFFFFF

    ; Sentinel check: fd_alloc returns 0xFFFFFFFFFFFFFFFF on EMFILE.
    ; A successful return is in [3, 32).  cmp rax, 32; jae is exact:
    ; it catches both -1 and any hypothetical >=32 stray value.
    cmp rax, 32
    jae sys_open_emfile

    mov r13, rax                        ; r13 = fd

    ; --- Phase 3: fd_set(current, fd, entry) ---
    ; entry == vnode_idx (in low 16); offset=0 in high 48 → entry == r12.
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r12                        ; rdx = entry
    call fd_set

    ; --- Success: return fd ---
    mov rax, r13
    jmp sys_open_done

sys_open_enoent:
    ; Path resolution failed.  vfs_open returned 0 without bumping
    ; anything, so no rollback is needed.
    mov rax, 0xFFFFFFFFFFFFFFFE         ; -ENOENT (-2)
    jmp sys_open_done

sys_open_emfile:
    ; fd_table full.  vfs_open already bumped the vnode's refcount —
    ; that increment is now LEAKED because we return without setting
    ; a fd_table slot to hold the reference.  Documented as §6.4 and
    ; will be paired with vfs_close in a followup once #591 lands.
    ; At R16.M3 witness time this path is UNREACHABLE (fresh fd_table
    ; has ≥ 29 free slots), so no observable leak in the witness log.
    mov rax, 0xFFFFFFFFFFFFFFE8         ; -EMFILE (-24)

sys_open_done:
    pop r13
    pop r12
    pop rbx
    ret
```

**Instruction count**: 25 instructions across the body (including
prologue/epilogue). Comparable to `sys_fork_body`'s 30 instructions
and considerably simpler (no aspace clone, no fd-table copy loop).

### 3.4 Error-code convention

| Return sentinel                | Signed value | Meaning                            |
|--------------------------------|--------------|------------------------------------|
| `0xFFFFFFFFFFFFFFFE`           | `-2`         | `-ENOENT` — path resolution failed |
| `0xFFFFFFFFFFFFFFE8`           | `-24`        | `-EMFILE` — fd table full           |

Mirrors Linux errno signs (`ENOENT=2`, `EMFILE=24`). Both fit in
`cmp rax, imm32`'s sign-extended range trivially. The sign-extended
u64 view lets `sys_open`'s single return convention (u64 in rax)
distinguish success (0..31) from error (top bit set) with a plain
`test rax, rax; js ...` at any caller.

Aligns with `sys_fork_body`'s error family (#554: `-EAGAIN =
0xFFFFFFFFFFFFFFF5`, `-ENOMEM = 0xFFFFFFFFFFFFFFF4`) — same u64
sign-extension, same errno numbering, different constants.

### 3.5 Register discipline recap

- **rbx = current** (survives `vfs_open`, `fd_alloc`, `fd_set`).
  Pushed in the 3-push prologue.
- **r12 = vnode_idx / entry** (survives `fd_alloc`, `fd_set`).
  Pushed in the 3-push prologue.
- **r13 = fd** (survives `fd_set`). Pushed in the 3-push prologue.
- **r14, r15**: not used. Kept UN-pushed to save two instruction
  cycles — no cross-call live value needs them at R16.M3.
- **rax, rcx, rdx, rsi, rdi**: scratch. All caller-save; content
  after each `call` is what the callee's ABI says (usually just
  `rax` for the return).

All nested callees (`vfs_open`, `fd_alloc`, `fd_set`) callee-save
correctly per their own justifications — verified by reading
`vfs_open.pdx:67`, `fd_table.pdx:20/34/47`. No rbx/r12/r13
clobbers under the covers.

### 3.6 File contents (skeleton)

```pdx
// src/kernel/core/syscall/handlers/sys_open.pdx — R16-M3-001 (#587)
// sys_open body: vfs_open + fd_alloc + fd_set composition.
//
// Frozen contract: the fd_table entry is packed as
//   bits [0, 16):  vnode_idx (u16)
//   bits [16, 64): file offset (u48)
// This encoding is consumed by #588 (sys_read), #589 (sys_write),
// #591 (sys_close), #593 (sys_dup2).
//
// See design/kernel/r16-m3-001-sys-open.md for full contract.

module SysOpen = structure {
  // === Error sentinels (negative-errno u64, matches Linux errno signs) ===
  pub let SYS_OPEN_ERR_ENOENT : u64 = 0xFFFFFFFFFFFFFFFE   // -2
  pub let SYS_OPEN_ERR_EMFILE : u64 = 0xFFFFFFFFFFFFFFE8   // -24

  // === Layout constants (from #549 fd_table freeze) ===
  pub let FD_TABLE_MAX        : u64 = 32                   // matches fd_table.pdx:9

  // ==========================================================================
  // sys_open_body — compose vfs_open + fd_alloc + fd_set into a fd-returning body
  //
  // Input:
  //   rdi = current   (task_struct*, must be non-NULL — callers pass either
  //                    _current_tcb-loaded pointer or a dedicated witness slab)
  //   rsi = path_ptr  (const char*, NUL-terminated)
  //   rdx = flags     (u64 bitmask; forwarded to vfs_open unchanged)
  //   rcx = mode      (u64 — IGNORED at R16.M3; reserved for #588 successor)
  //
  // Output:
  //   rax = fd (in [3, 32)) on success, or one of:
  //         0xFFFFFFFFFFFFFFFE (-ENOENT)  if vfs_open returned 0
  //         0xFFFFFFFFFFFFFFE8 (-EMFILE)  if fd_alloc had no free slot
  //
  // Side effects:
  //   on success: vnode's refcount++ (by vfs_open) and current->fd_table[fd]
  //     is populated with entry = vnode_idx (offset=0 in high 48 bits).
  //   on -ENOENT: none (vfs_open bumped nothing before failing).
  //   on -EMFILE: vnode's refcount is left one too high (LEAK — §6.4).
  // ==========================================================================
  pub let sys_open_body : (u64, u64, u64, u64) -> u64 !{mem} @{} =
    fn (current: u64) (path_ptr: u64) (flags: u64) (mode: u64) -> unsafe {
      effects: {mem},
      capabilities: {},
      justification: "R16-M3-001 (#587): sys_open — vfs_open + fd_alloc + fd_set composition. 4-arg SysV entry. rdi=current, rsi=path, rdx=flags, rcx=mode (mode ignored at R16.M3). 3-push prologue (rbx,r12,r13) aligns rsp%16==0 for nested calls and saves current/vnode_idx/fd across three calls. Phase 1: shuffle rdi<-rsi, rsi<-rdx and call vfs_open → rax = vnode_idx or 0. On 0 → -ENOENT. Phase 2: call fd_alloc(rbx) → rax = fd or 0xFFFFFFFFFFFFFFFF. cmp rax,32; jae catches both EMFILE and any stray >=32 value → -EMFILE. Phase 3: call fd_set(current, fd, entry=vnode_idx) — entry has vnode_idx in bits [0,16) and offset=0 in bits [16,64); since r12=vnode_idx has high 48 bits already 0, no shifting needed. Return fd in rax. Error return convention: negative-errno u64 (Linux errno signs sign-extended). Refcount rollback on -EMFILE is DEFERRED to a follow-up paired with sys_close (#591) — not observable at R16.M3 witness time because a fresh fd_table has 29 free slots. See design/kernel/r16-m3-001-sys-open.md §3 for full rationale.",
      block: {
        push rbx;
        push r12;
        push r13;

        mov rbx, rdi;                       // rbx = current

        // Phase 1: vfs_open(path_ptr, flags)
        mov rdi, rsi;                       // rdi = path_ptr
        mov rsi, rdx;                       // rsi = flags
        call vfs_open;                      // rax = vnode_idx or 0

        cmp rax, 0;
        je  sys_open_enoent;

        mov r12, rax;                       // r12 = vnode_idx (== packed entry)

        // Phase 2: fd_alloc(current)
        mov rdi, rbx;
        call fd_alloc;                      // rax = fd or 0xFFFFFFFFFFFFFFFF

        cmp rax, 32;
        jae sys_open_emfile;

        mov r13, rax;                       // r13 = fd

        // Phase 3: fd_set(current, fd, entry)
        mov rdi, rbx;
        mov rsi, r13;
        mov rdx, r12;
        call fd_set;

        mov rax, r13;
        jmp sys_open_done;

      sys_open_enoent:
        mov rax, 0xFFFFFFFFFFFFFFFE;        // -ENOENT
        jmp sys_open_done;

      sys_open_emfile:
        mov rax, 0xFFFFFFFFFFFFFFE8;        // -EMFILE

      sys_open_done:
        pop r13;
        pop r12;
        pop rbx;
        ret
      }
    }
}
```

## 4. Witness task_struct — decision

### 4.1 Choice: dedicated `_sys_open_witness_task` (NOT `_idle_tcb`)

The parent task-brief speculated that `_idle_tcb` (from #562) could
back the witness since it exists and has an unused `fd_table` at +168.
That is architecturally sound in isolation but **boot-order-unsafe** at
the R16.M3 witness's actual placement:

- **`_idle_tcb` is not published until `idle_init` runs at
  `kernel_main.pdx:2835`** (line inside the `idle_witness:` block).
- **R16 witnesses cluster earlier**: the tmpfs vops witness ends at
  `kernel_main.pdx:2810`, and this issue's sys_open witness (§5)
  must precede the `wrmsr` at line 2813 that starts scheduler init.
- Therefore, at the point the sys_open witness runs, `[rip + _idle_tcb]`
  loads `0` — dereferencing it faults.

Two ways out — re-order (place the witness after idle_init) or use a
dedicated slab. **The dedicated slab wins** because:

1. **It matches the prior-art pattern.** #549's fd_table witness uses
   `_fd_witness_task : [u64; 278]` — a 278-u64 (2224-byte) `.bss`
   blob. Reusing that idiom keeps the R16.M3 witness stylistically
   consistent with the R15.M5 witness that gave us fd_table.
2. **It is dependency-lean.** No coupling to `idle_init`, no
   coupling to scheduler init order, no coupling to any future
   `_current_tcb` initialization sequence. The sys_open witness
   depends only on primitives that have already run (vfs_open,
   fd_alloc, fd_set — all landed before its position in kernel_main).
3. **It is refactor-safe.** If a future R17 refactor re-orders
   scheduler init before R16 witnesses, or vice versa, the sys_open
   witness stays green byte-identically. `_idle_tcb`-based witness
   would break silently in that refactor.
4. **The idle task's fd_table is not a proper testing scratch anyway.**
   `_idle_task_slot`'s +168 is documented at
   `sched/idle.pdx:25-26` as "frozen at 0 — idle has no file
   descriptors". Using it for sys_open testing quietly violates that
   freeze — the witness would leave non-zero fd_table entries in
   idle's slab. Real idle scheduling doesn't touch fd_table, so the
   violation is invisible at R16.M3, but it seeds a landmine for
   any future consistency check on idle's TCB.

### 4.2 Slab declaration (mirrors `_fd_witness_task`)

At the tail of `kernel_main.pdx`, alongside the existing
`pub let mut _fd_witness_task : [u64; 278] = uninit @align(8)`:

```pdx
// R16-M3-001 (#587): sys_open witness task storage.
// Static .bss blob (2224 bytes = 278 u64s) backing a dedicated
// witness task_struct.  Not related to _idle_tcb or _task_pool —
// same rationale as _fd_witness_task (#549 §4.1): witness storage
// stays independent of the scheduler init sequence so R16.M3
// witnesses run before idle_init / runq_init without ordering hazards.
pub let mut _sys_open_witness_task : [u64; 278] = uninit @align(8)
```

Alignment 8 is sufficient (fd_table.pdx's SIB+disp encoding at
`[rdi + rsi*8 + 168]` requires only 8-byte alignment; the task_pool's
4 KiB alignment is a slab concern, not a functional one).

### 4.3 Position in kernel_main

Inserted immediately after `tmpfs_vops_witness_done:` (line 2810)
and before the `wrmsr` at line 2813 that begins scheduler init.

That placement satisfies all prereqs:

- vfs_open landed & witnessed (line 2065).
- vnode pool / mount table / tmpfs vops all initialized & witnessed.
- fd_table primitives landed & witnessed (line 949 area, R15 tempo).
- No coupling to idle/runq/sched_switch/block_wake witnesses that
  follow.

## 5. Test canary — kernel_main witness block

### 5.1 Preamble

The witness lives in `boot_continue_after_ring3` between the
existing `tmpfs_vops_witness_done:` and the `wrmsr` GS_BASE
setup. Its inputs:

- `_sys_open_witness_task`: fresh 278-u64 `.bss` blob (all zeros).
- vfs_open working end-to-end for existing paths (proven by the
  #575 witness at line 2028).
- `witness_path_slash` (`"/"`) already resident in boot_stub.S:605.
- Root vnode published at `_mount_table[0].root_idx` (proven by
  the #574 mount witness at line 1971–1989).

### 5.2 Sub-tests

Matches the AC pattern (three consecutive opens returning 3, 4, 5)
using an existing path (`"/"`) to sidestep the vfs_open O_CREAT gap
called out in §2.2. The literal AC path (`"/tmp/x"` with O_CREAT)
becomes reachable once the follow-up in §6.1 lands.

**Sub-test A**: `sys_open_body(w, "/", 0, 0)` returns `3`.
```asm
lea  rdi, [rip + _sys_open_witness_task]     ; current
lea  rsi, [rip + witness_path_slash]         ; "/"
xor  rdx, rdx                                ; flags = 0 (O_RDONLY)
xor  rcx, rcx                                ; mode = 0 (ignored)
call sys_open_body
cmp  rax, 3
jne  sys_open_witness_fail
mov  r14, rax                                ; r14 = first_fd (== 3) for sub-test D
```

**Sub-test B**: consecutive `sys_open_body(w, "/", 0, 0)` returns `4`.
```asm
lea  rdi, [rip + _sys_open_witness_task]
lea  rsi, [rip + witness_path_slash]
xor  rdx, rdx
xor  rcx, rcx
call sys_open_body
cmp  rax, 4
jne  sys_open_witness_fail
```

**Sub-test C**: third `sys_open_body(w, "/", 0, 0)` returns `5`.
```asm
lea  rdi, [rip + _sys_open_witness_task]
lea  rsi, [rip + witness_path_slash]
xor  rdx, rdx
xor  rcx, rcx
call sys_open_body
cmp  rax, 5
jne  sys_open_witness_fail
```

**Sub-test D**: verify the packed encoding in `fd_table[3]` — non-zero
`vnode_idx` in low 16 bits, offset=0 in high 48 bits.
```asm
; fd_get(w, 3) → rax = entry
lea  rdi, [rip + _sys_open_witness_task]
mov  rsi, 3                                  ; fd = 3
call fd_get
; Assert: low 16 bits of rax are non-zero (== root vnode idx)
mov  rcx, rax
and  rcx, 0xFFFF                             ; extract vnode_idx
cmp  rcx, 0
je   sys_open_witness_fail
; Assert: high 48 bits of rax are zero (offset == 0 at open time)
mov  rcx, rax
shr  rcx, 16                                 ; extract offset
cmp  rcx, 0
jne  sys_open_witness_fail
```

**Sub-test E (bonus — error-path proof)**: prove `-ENOENT` is
returned for a path that vfs_open cannot resolve. Uses
`witness_path_nope` (`"/nope"`), already resident in boot_stub.S
(added by #573 / #575 witnesses).
```asm
; sys_open_body(w, "/nope", 0, 0) → rax = 0xFFFFFFFFFFFFFFFE (-ENOENT)
lea  rdi, [rip + _sys_open_witness_task]
lea  rsi, [rip + witness_path_nope]
xor  rdx, rdx
xor  rcx, rcx
call sys_open_body
mov  rcx, 0xFFFFFFFFFFFFFFFE                 ; -ENOENT
cmp  rax, rcx
jne  sys_open_witness_fail
```

Sub-test E is optional (satisfies §1.1 "error return convention
established") but NOT part of the parent brief's A/B/C/D list. Ship
it because it costs 8 instructions and closes the door on silent
error-path regressions.

### 5.3 Marker

On A, B, C, D (and E if included) all green:

```
R16 SYS OPEN OK
```

Emitted via `uart_puts` on `sys_open_ok_msg`. Fingerprint added to
all three R16.M3-tempo expected-output files (see the touching list
in the frontmatter).

### 5.4 Witness assembly (complete block)

```asm
; ============================================================
; R16-M3-001 (#587): sys_open witness — 5 sub-tests, 1 marker
; ============================================================
sys_open_witness:
    ; --- Sub-test A: first open returns 3 ---
    lea  rdi, [rip + _sys_open_witness_task]
    lea  rsi, [rip + witness_path_slash]
    xor  rdx, rdx
    xor  rcx, rcx
    call sys_open_body
    cmp  rax, 3
    jne  sys_open_witness_fail

    ; --- Sub-test B: second open returns 4 ---
    lea  rdi, [rip + _sys_open_witness_task]
    lea  rsi, [rip + witness_path_slash]
    xor  rdx, rdx
    xor  rcx, rcx
    call sys_open_body
    cmp  rax, 4
    jne  sys_open_witness_fail

    ; --- Sub-test C: third open returns 5 ---
    lea  rdi, [rip + _sys_open_witness_task]
    lea  rsi, [rip + witness_path_slash]
    xor  rdx, rdx
    xor  rcx, rcx
    call sys_open_body
    cmp  rax, 5
    jne  sys_open_witness_fail

    ; --- Sub-test D: fd_table[3] has valid packed entry ---
    lea  rdi, [rip + _sys_open_witness_task]
    mov  rsi, 3
    call fd_get
    mov  rcx, rax
    and  rcx, 0xFFFF                          ; vnode_idx (low 16)
    cmp  rcx, 0
    je   sys_open_witness_fail
    mov  rcx, rax
    shr  rcx, 16                              ; offset (high 48)
    cmp  rcx, 0
    jne  sys_open_witness_fail

    ; --- Sub-test E: error path returns -ENOENT for "/nope" ---
    lea  rdi, [rip + _sys_open_witness_task]
    lea  rsi, [rip + witness_path_nope]
    xor  rdx, rdx
    xor  rcx, rcx
    call sys_open_body
    mov  rcx, 0xFFFFFFFFFFFFFFFE
    cmp  rax, rcx
    jne  sys_open_witness_fail

    ; --- All green ---
    lea  rdi, [rip + sys_open_ok_msg]
    call uart_puts
    jmp  sys_open_witness_done

sys_open_witness_fail:
    lea  rdi, [rip + sys_open_fail_msg]
    call uart_puts

sys_open_witness_done:
```

### 5.5 String data — `tools/boot_stub.S`

Append after the tmpfs_vops witness strings (~line 780 area, exact
insertion point resolved at implementation time):

```asm
# R16-M3-001 (#587): sys_open witness success message
.global sys_open_ok_msg
.align 8
sys_open_ok_msg: .ascii "R16 SYS OPEN OK\n\0"

# R16-M3-001 (#587): sys_open witness failure message
.global sys_open_fail_msg
.align 8
sys_open_fail_msg: .ascii "R16 SYS OPEN FAIL\n\0"
```

`witness_path_slash` and `witness_path_nope` already exist
(boot_stub.S:603 and thereabouts) — no new path strings needed for
the relaxed-AC witness. If the follow-up in §6.1 lands and the
witness grows the literal AC (`"/tmp/x"` etc.), those path strings
are added then.

### 5.6 Fingerprint files — marker insertion

The line `R16 SYS OPEN OK` inserts into all three R16.M3-tempo
fingerprint files immediately after the `R16 TMPFS VOPS OK` line
(#586's marker):

- `tests/r14b/expected-boot-r14b-loader.txt`
- `tests/r15/expected-boot-r15-ring3.txt`
- `tests/r15/expected-boot-r15-process.txt`

Contains-in-order matching means the addition is strictly
additive — no earlier line reorders, so all existing smoke modes
(`boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`,
`boot_r12_denial`) that don't observe R16 markers stay
byte-identically green.

## 6. Alternatives considered / follow-ups (rejected or deferred)

### 6.1 Follow-up (STRONGLY RECOMMENDED as next R16.M3 issue): complete vfs_open's O_CREAT path

**Problem.** As documented in §2.2, `vfs_open`'s O_CREAT branch is a
REACHED-but-returns-0 stub. This means the issue-body's literal AC
(`sys_open("/tmp/x", O_CREAT|O_RDWR, 0644)` returns 3) does not pass
end-to-end.

**Proposed follow-up (new issue in R16.M3 tempo).** Complete
`vfs_open.pdx`'s O_CREAT body to:

1. On path_resolve miss + O_CREAT set, find the parent directory
   vnode (split the path at the last `/`, recursively resolve the
   parent).
2. Extract the leaf name (the substring after the last `/`).
3. Call `vops_create(parent_vn, leaf_name, mode)` through the parent's
   ops table (tmpfs's create adapter handles the idx extraction —
   #586 §4.4).
4. Wrap the returned inode idx in a fresh vnode via `vnode_alloc`
   + backend_ptr publication (per #586 §8.2 publication invariant).
5. Increment refcount, return vnode idx.

**Why not fold into #587?** Because the create semantics span a
different subsystem (VFS abstract layer, not fd table). Folding
inflates #587's scope by ~150 LOC of assembly plus a name-parsing
helper that has no other consumer at R16.M3. The tactical plan
explicitly assigns "subsystem 11" (VFS) to a different set of
issues than "subsystem 13" (fd table). Keeping the boundary sharp
respects the plan.

**Interim mitigation shipped here.** The witness uses `"/"` (proven
existing) so `sys_open_body`'s composition ships and can be
consumed by #588 (sys_read on an existing file) and #591 (sys_close)
before the O_CREAT gap closes. When the follow-up lands, the
sys_open witness gains the literal-AC sub-tests as an incremental
extension.

**Alternative rejected.** Complete O_CREAT inside `sys_open_body`
by having sys_open detect vfs_open's -ENOENT and manually call
`vops_create`. That works but is **architecturally wrong** — path
parsing is a VFS-layer concern (vfs_open owns path→vnode; sys_open
owns vnode→fd_entry). Duplicating parsing at the syscall layer
leaks knowledge downwards.

### 6.2 Syscall entry wiring (SYSCALL instruction dispatch) — DEFERRED

**Proposal.** Also install `sys_open_body` into the syscall
dispatch table so ring-3 code can invoke it via `syscall`.

**Rejected for #587.** The dispatch table (`syscall_dispatch.pdx`)
is not yet a landed data structure — the four existing handlers
(`sys_fork`, `sys_exit`, `sys_wait`, `sys_execve`) are also
witness-callable only. Syscall entry wiring is a joint concern
across all R16.M3 handlers; it lands with a batch-wire issue after
sys_open, sys_read, sys_write, sys_close, sys_dup2 are all
composed. Postponing to that batch keeps #587's scope tight.

### 6.3 Widening fd_entry to 24 bytes now (`{vnode_ptr, offset, flags, refcount}`)

**Proposal.** Instead of packing into a u64, use the R15.M5-reserved
1280-byte pad after fd_table to store a 24-byte record per slot
from R16.M3.

**Rejected.** #549's freeze pinned `FD_ENTRY_SIZE = 8` and every
`fd_get` / `fd_set` / `fd_alloc` call site (all of `fd_table.pdx`
plus `sys_fork_body`'s fd-table copy loop at
`sys_fork.pdx:56-58` — `mov rax, [rbx + rcx*8 + 168]`) uses that
`*8` scale. Widening to 24 breaks:

- The SIB scale (24 is not 1/2/4/8; requires 5-instruction address
  arithmetic instead of a single-cycle SIB+disp).
- The `sys_fork` fd_table copy loop (which currently copies 32 u64s).
- Any future primitive that assumes u64-per-slot.

Wait until R17 to widen — the packed u64 buys R16.M3 everything it
needs (vnode_idx and offset) without breaking the R15.M5 encoding
contract. Refcount and flags land when there's a caller for them
(`sys_dup2` for refcount, `sys_open`'s FD_CLOEXEC for flags).

### 6.4 Refcount rollback on -EMFILE — DEFERRED

**Proposal.** On the EMFILE branch (fd_alloc found no free slot
after vfs_open bumped refcount), call `vfs_close(vnode_idx)` to
release the reference before returning `-EMFILE`.

**Deferred, not rejected.** The rollback is architecturally correct
but adds ~5 instructions of body plus a `vfs_close` symbol
dependency. At R16.M3 witness time the EMFILE path is unreachable
(fresh fd_table has 29 free slots; the witness opens 3), so the
leak is invisible. Once #591 lands `sys_close`, that issue can
extend `sys_open_body`'s -EMFILE branch to call `vfs_close`
symmetrically — the two rollback sites (`sys_open`'s EMFILE and
`sys_close`'s normal path) can then share the same idiom.

Flagged in the `sys_open_body` justification comment so it isn't
lost.

### 6.5 `mode` handling at R16.M3

**Proposal.** Decode `mode` (POSIX-shaped `S_IFREG | 0644`) into a
`VNODE_TYPE_*` constant and forward it through vfs_open into
vops_create.

**Rejected for R16.M3.** No R16.M3 caller (the witness, tests, or
kernel code paths) supplies a POSIX mode — every call site would
pass 0 or a raw `VNODE_TYPE_*` constant. Building the mode-decode
helper without a consumer is speculative. The follow-up in §6.1
(vfs_open O_CREAT completion) is a natural home for the helper
because vops_create is where the type gets used. sys_open just
passes `mode` through as an opaque u64.

The `sys_open_body` signature reserves `rcx` for mode so a future
grow-in is signature-compatible — no re-plumb, no ABI churn.

### 6.6 `_current_tcb`-based witness

**Proposal.** Have the witness first set `_current_tcb =
&_sys_open_witness_task`, then have `sys_open_body` load current
implicitly from `_current_tcb` (dropping the rdi arg).

**Rejected.** Explicit `current` matches the sys_fork_body / sys_exit_body
pattern (both take current in rdi — see #554 §2, #557). That
pattern isolates the syscall body from the machinery that decides
"who is current" — the SYSCALL entry stub loads `_current_tcb` (or
%gs:$offset once cpu_local is wired at #558/#546) into rdi before
calling the body. Keeping the body current-agnostic makes it
testable from any driver (witness, unit test, alternative dispatch
path) without a global-state ceremony.

## 7. Invariants

### 7.1 fd_entry encoding freeze

Once #587 lands, every consumer/producer of a fd_table slot at
R16.M3+ uses the encoding

```
entry & 0xFFFF        =  vnode_idx
entry >> 16           =  file_offset
entry == 0            =  slot is free
```

No consumer of fd_table[N] at R16.M3+ reads it as an opaque u64
(the R15.M5 semantics); every read applies at least the vnode_idx
mask. This freeze binds #588 (sys_read), #589 (sys_write), #591
(sys_close), #593 (sys_dup2), and the fd-table copy path in
`sys_fork_body` (which now copies packed entries, still opaquely
— since the copy is bit-exact, the encoding survives fork
trivially).

### 7.2 vnode_idx = 0 sentinel preservation

`vnode_alloc` (per vnode_pool.pdx witnessed at #571) never returns
idx 0. `vfs_open` returns 0 on failure. Therefore any successfully-
open fd's entry has `entry & 0xFFFF != 0`, so
`(entry != 0) ↔ (fd is allocated)`. This co-conversation with
#549's sentinel-0-free discipline is what lets `fd_alloc`'s
straight `cmp rax, 0; je fd_alloc_found` (fd_table.pdx:55-56) keep
working unchanged.

Any future change to `vnode_alloc` that permits returning idx 0
breaks this invariant — flagged as a design-doc consumer of that
future issue.

### 7.3 sys_open_body register discipline

- rbx, r12, r13 are pushed in the prologue and popped in the
  epilogue. Any nested call inside sys_open_body's body MUST
  callee-save-preserve them. Currently verified for vfs_open (5-
  push prologue, saves rbx/r12/r13 among others), fd_alloc (leaf
  function per fd_table.pdx:48), fd_set (leaf function per
  fd_table.pdx:34).
- rax, rcx, rdx, rsi, rdi are caller-save scratch. Content across
  a nested call is undefined except for the callee's documented
  return in rax.
- r14, r15 are NOT touched by sys_open_body. That leaves them
  available for a caller (the SYSCALL entry stub at some future
  issue) to spill user-mode-preserved regs into.

### 7.4 Path string ownership

sys_open_body treats `path_ptr` as a pointer into caller-owned,
NUL-terminated memory that stays valid across the vfs_open call.
No copy, no ownership transfer. The path_resolver (called via
vfs_open → path_resolve) walks the string in place. Once vfs_open
returns, the string can be freed by the caller with no aliasing
concern.

At R16.M3 witness time, the path lives in `.rodata` (boot_stub.S)
which is immortal — no lifetime issue.

At R17 userland time (when SYSCALL entry lands), the SYSCALL stub
must copy the path from user memory into a kernel scratch buffer
before calling sys_open_body (the classic
"copy_from_user of path string" pattern). That copy is the SYSCALL
stub's concern, not sys_open_body's. Flagged in the follow-up in
§6.2.

## 8. Cross-cutting risks

- **fd_alloc sentinel collision if it returns 0.** `fd_alloc`'s
  documented sentinel is `0xFFFFFFFFFFFFFFFF` (-1). If a future
  refactor accidentally returns 0 as the sentinel, sys_open's
  `cmp rax, 32; jae` would treat 0 as success and store `entry =
  vnode_idx` into `fd_table[0]` — silently overwriting the
  stdin-reserved slot. Mitigation: fd_alloc.pdx's contract is
  explicit ("returns fd index or -1 (EMFILE)") and the witness
  in #549 (line 907: `cmp rax, 3`) actively verifies fd_alloc
  returns 3, not 0. That witness re-runs every boot.
- **vfs_open contract drift.** If vfs_open is ever changed to
  return an error sentinel other than 0 (e.g. a negative-errno u64),
  sys_open's `cmp rax, 0; je sys_open_enoent` would miss the error
  and store a bogus entry into fd_table. Mitigation: vfs_open.pdx's
  return contract is documented at line 67 as "0 on failure", and
  the #575 witness's sub-test C actively verifies `vfs_open("/nope",
  0)` returns 0. Any future contract change ripples through
  vfs_open.pdx's justification and this doc's §3.3.
- **Encoding freeze regression across R16.M3 issues.** #588 (sys_read)
  and #589 (sys_write) will need to update the offset half of the
  entry after each I/O call. If #588's implementation writes the
  low 16 bits instead of the high 48, the vnode_idx corrupts and
  subsequent reads on the same fd land in the wrong vnode. Mitigation:
  §3.2's diagram is the single source of truth. Every consumer's
  design doc must cross-reference this doc's §3.2. Enforced by
  reviewer discipline; no automated invariant.
- **EMFILE-branch leak (#6.4 rollback).** Documented; visible when
  R17 stress-tests fd exhaustion. Not a R16.M3 witness concern.

## 9. LOC estimate

| File                                                       | LOC        |
|------------------------------------------------------------|------------|
| `src/kernel/core/syscall/handlers/sys_open.pdx` (new)      | ~90        |
|   - module boilerplate + constants + justification         |   ~40      |
|   - `sys_open_body` (~25 instructions)                     |   ~35      |
|   - inline comments                                        |   ~15      |
| `src/kernel/boot/kernel_main.pdx` (witness block + slab)   | ~95        |
|   - `_sys_open_witness_task` declaration                   |    ~5      |
|   - 5 sub-tests (A–E), fail/success labels                 |   ~70      |
|   - inline comments                                        |   ~20      |
| `tools/boot_stub.S` (2 strings)                            | ~8         |
| 3 expected-output fingerprint files (1 marker each)        | ~3         |
| `design/kernel/r16-m3-001-sys-open.md` (this doc)          | (this)     |
| **Total executable / testing / test-data**                 | **~196**   |

Executable code path: ~90 LOC. Witness + fingerprint: ~106 LOC.

## 10. Tractability

**HIGH.**

- No paideia-as encoder gap. Every instruction used has landed
  precedent (§2.3).
- Composition of three already-witnessed primitives — the only
  novel logic is a 3-push prologue plus argument shuffling.
- Witness storage is a single `.bss` blob (mirror of #549's
  `_fd_witness_task`) — no allocator dependency, no CR3 flip, no
  interrupt discipline, no scheduler init dependency.
- Marker line is contains-in-order — no fingerprint reorder risk
  across the other 12 smoke modes.
- Sizing matches the R16.M2 issues that recently landed cleanly
  (#586 tmpfs vops wire: ~325 LOC total; this issue: ~196 LOC).
- No cross-repo escalation risk (no paideia-as encoder growth).

Estimated implementation time: **one workerbee session**.
Estimated risk of regressing an existing smoke mode: **near-zero**
(purely additive: one new emit line, one new witness block, one
new .pdx module).

**Known follow-ups (do NOT block #587's landing)**:

- **vfs_open O_CREAT completion** (§6.1) — new R16.M3 issue.
  Enables the literal AC (`sys_open("/tmp/x", O_CREAT|O_RDWR, 0644)`
  returns 3). Recommended as the immediate successor to #587.
- **SYSCALL entry wiring** (§6.2) — batched with sys_read /
  sys_write / sys_close / sys_dup2 dispatch registration.
- **Refcount rollback on -EMFILE** (§6.4) — paired with #591
  `sys_close` landing.
- **`mode` decoding** (§6.5) — lands where vops_create actually
  consumes it (vfs_open O_CREAT body, per §6.1).

## 11. References

- Issue: paideia-os#587
- Milestone: paideia-os R16.M3 (fd table + open/read/write/close/dup2)
- Prereq issues: #549 (fd_table embed), #575 (vfs_open), R16.M2 issues
  (tmpfs backend + vops wire)
- Sibling / successor issues: #588 (sys_read), #589 (sys_write),
  #591 (sys_close), #593 (sys_dup2)
- Tactical plan: `design/milestones/r14b-tactical-plan.md` §Subsystem 13
- Master plan: `design/milestones/r14b-master-plan.md` §M19 (VFS)
- Prior-art witness pattern: `design/kernel/r15-m5-007-fd-table-embed.md`
  (fd_table witness — same `.bss` blob + kernel_main witness insertion
  + marker line + `_*_witness_task` naming idiom).
- Prior-art body pattern: `src/kernel/core/syscall/handlers/sys_fork.pdx`
  (#554) — 3-push prologue with rbx/r12/r13, explicit `current` in rdi,
  negative-errno u64 returns, callee-save-across-nested-call discipline.
