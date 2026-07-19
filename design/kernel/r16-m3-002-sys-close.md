---
issue: 588
milestone: R16.M3 (fd table + open/read/write/close/dup2)
subsystem: 13 — file-descriptor + open/read/write/close/dup2
topic: sys_close — extract vnode_idx + vfs_close + fd_set(0) composition (the packed-encoding inverse of sys_open)
prereq:
  - "#587 (sys_open — LANDED at 3e6a550 ancestor; freezes the packed fd_entry encoding this doc consumes)"
  - "#576 (vfs_close — LANDED; decrements refcount, dispatches vops_close when refcount hits 0)"
  - "#549 (fd_table embed — LANDED; provides fd_get / fd_set / sentinel-0-means-free discipline)"
blocks:
  - "#589 (sys_read — consumes the offset half of the entry; will share the fd validation idiom frozen here)"
  - "#590 (sys_write — mirror of #589)"
  - "#591 (sys_dup2 — will need `fd_get -> is_free?` idiom identical to sub-test E's check)"
  - "R17 (userland shell demo — first ring-3 caller through SYSCALL entry once the batch-wire lands)"
touching:
  - src/kernel/core/syscall/handlers/sys_close.pdx    (new module — ~80 LOC incl. justification)
  - src/kernel/boot/kernel_main.pdx                   (witness block ~110 LOC + `_sys_close_witness_task` slab)
  - tools/boot_stub.S                                 (2 rodata strings: ok_msg, fail_msg)
  - tests/r14b/expected-boot-r14b-loader.txt          (marker: `R16 SYS CLOSE OK`)
  - tests/r15/expected-boot-r15-ring3.txt             (marker)
  - tests/r15/expected-boot-r15-process.txt           (marker)
  - design/kernel/r16-m3-002-sys-close.md             (this doc)
related:
  - design/kernel/r16-m3-001-sys-open.md              (#587 — freezes the packed FdEntry encoding
                                                       `entry = vnode_idx | (offset<<16)`; this doc consumes
                                                       the encoding via the `entry & 0xFFFF` extraction path
                                                       enumerated in §3.2)
  - design/kernel/r16-m1-007-vfs-close.md             (#576 — the refcount-decrementing primitive; this doc's
                                                       phase 3 is exactly one `call vfs_close`)
  - design/kernel/r15-m5-007-fd-table-embed.md        (#549 — `fd_get` / `fd_set` sentinel-0 discipline;
                                                       §3.4 there defines the "writing 0 clears the slot"
                                                       contract that this doc's phase 4 relies on)
  - src/kernel/core/syscall/handlers/sys_open.pdx     (the composition mirror — reverse pattern: sys_open
                                                       allocates + populates, sys_close deallocates + clears)
  - design/milestones/r14b-tactical-plan.md           §Subsystem 13, item 2
---

# R16-M3-002 — `sys_close`: release fd slot; vfs_close vnode (#588)

## 1. Scope

Land the R16.M3 subsystem-13 issue #588: the inverse of `sys_open_body`
(#587). Its full body sequence is a **four-step composition** on the
packed fd_entry encoding frozen by #587 §3.2:

```
sys_close_body(current, fd) -> u64
    rdi = current      (task_struct*)
    rsi = fd           (u64 in [3, 32) — validated here at the trust boundary)
    rax = 0                             on success
    rax = 0xFFFFFFFFFFFFFFF7 (-EBADF)   on any of:
                                          (a) fd < 3            (stdio-reserved)
                                          (b) fd >= 32          (out of range)
                                          (c) fd_table[fd] == 0 (already closed)
```

The four steps:

1. **Validate** `fd` in `[3, 32)`. Rejecting fd 0/1/2 preserves the R15.M5
   scan-from-3 discipline (`fd_alloc` never issues 0/1/2 either — #549
   §3.4); rejecting fd ≥ 32 is the mirror of the `fd_alloc` bound.
2. **Load** the packed entry via `fd_get(current, fd)`. A zero entry
   means the slot is free — return `-EBADF` (already closed).
3. **Extract** `vnode_idx = entry & 0xFFFF` (per the encoding frozen by
   #587 §3.2) and call `vfs_close(vnode_idx)`. This decrements refcount
   and, on zero, dispatches `vops_close` per #576.
4. **Clear** the slot: `fd_set(current, fd, 0)` restores the sentinel-0
   `slot-free` state.

### 1.1 What this issue proves

- **The packed fd_entry encoding round-trips.** sys_open writes
  `entry = vnode_idx | (0 << 16)` at open; sys_close reads it back
  via `entry & 0xFFFF` extraction, drops the vnode reference through
  `vfs_close`, and returns the slot to sentinel-0-free — proving the
  encoding is symmetric across a full open/close pair. Sub-test B
  verifies the slot is byte-exact zero after close.
- **The `-EBADF` error family is established for the fd-table
  subsystem.** Three failure modes (fd < 3, fd ≥ 32, slot free) all
  return the same sign-extended u64 (`0xFFFFFFFFFFFFFFF7 == -9`) —
  matching the Linux `EBADF = 9` convention already implicitly
  referenced by `r16-m1-008-vfs-read-write.md:50`. Sub-tests C/D/E
  actively exercise each mode.
- **fd validation at the syscall trust boundary is factored here, not
  in fd_get / fd_set.** Per #549 §fd_get justification, `fd_get`
  intentionally skips bounds-checking ("syscall layer validates fd <
  FD_TABLE_MAX at the trust boundary"). This issue lands the first
  concrete instance of that trust-boundary validation. #589 (sys_read),
  #590 (sys_write), and #591 (sys_dup2) will inherit the same
  three-line idiom (`cmp rsi, 3; jb ...; cmp rsi, 32; jae ...`) —
  frozen here as the reusable prologue for every fd-consuming
  syscall.

### 1.2 What this issue deliberately does NOT do

- **No SYSCALL entry wiring.** `sys_close_body` is testable in kernel
  context via the witness (§5). Wiring into the syscall dispatch
  table is the R16.M3 batch-wire concern (see #587 §6.2 — same
  rationale here; postponed until all five R16.M3 syscall bodies
  are composed).
- **No EMFILE rollback back-fill (§6.1).** `sys_open_body`'s -EMFILE
  branch (#587 §6.4) still leaks the vnode refcount `vfs_open`
  bumped before `fd_alloc` returned -1. That rollback could be
  paired here (since we now have `vfs_close` in the dependency
  graph), but folding it into #588 mixes two independent concerns.
  Flagged as a §6.1 follow-up.
- **No per-fd flags (`FD_CLOEXEC`).** The R15.M5-reserved fd_entry
  bits (the R17 24-byte widening path) don't yet include a flags
  field. Nothing to close-conditionally here. #593 (fd_cloexec-on-
  exec) is the natural home.
- **No task-scoped notification / SIGPIPE / EPOLL wake-up on close.**
  R16.M3 has no signal machinery; those are R18+ concerns.
- **No cross-vnode reference bookkeeping (e.g. hard-link count
  decrement).** `vfs_close` (#576) already handles the refcount
  arithmetic; sys_close is a pass-through. Backend-specific
  side effects (e.g. tmpfs freeing the inode when refcount hits 0)
  land through `vops_close` — that path is exercised by the
  witness only if the fd being closed drops the last reference,
  which the witness deliberately avoids (§4.3).
- **No literal-signed compare on fd.** Even though `fd < 3` naturally
  suggests a signed compare, we use unsigned semantics
  (`cmp rsi, 3; jb`) because fd is passed as an unsigned u64 in the
  ABI. A ring-3 caller could pass `fd = 0xFFFFFFFFFFFFFFFF`; that
  correctly falls into the `fd >= 32` branch under unsigned compare
  (jae is unsigned above-or-equal). Signed compare would misclassify
  it as fd < 3 → -EBADF via the wrong branch, still correct answer
  but wrong path — reader would be confused. Unsigned is
  semantically precise.

## 2. Prereq check

### 2.1 What is in place

| Primitive               | Location                                          | Contract used                                                     |
|-------------------------|---------------------------------------------------|-------------------------------------------------------------------|
| `sys_open_body`         | `core/syscall/handlers/sys_open.pdx` (#587, LANDED) | `(current, path, flags, mode) -> fd`. Populates entry per #587 §3.2. Used by the witness (§5) to seed a live fd before closing it. |
| `fd_get`                | `core/fs/fd_table.pdx:16` (#549, LANDED)          | `(task, fd) -> u64`. Single SIB+disp load; no bounds check (this issue enforces the bound at the trust boundary). |
| `fd_set`                | `core/fs/fd_table.pdx:30` (#549, LANDED)          | `(task, fd, val) -> ()`. Writing `val=0` restores sentinel-0 `slot-free` (per #549 §fd_set justification). |
| `vfs_close`             | `core/fs/vfs_close.pdx:54` (#576, LANDED)         | `(vnode_idx) -> u64`. Decrements refcount at `vnode + 4` (u16); on zero calls `vops_close` (ignoring return value). Rejects idx==0 and idx>=256 with sentinel `0xFFFFFFFFFFFFFFFF` — but sys_close never passes 0 (guarded by the entry==0 branch → -EBADF), and idx from a valid open is always < 256 (guarded by vnode_alloc's `VNODE_MAX=256` at #571). |
| Packed fd_entry format  | `design/kernel/r16-m3-001-sys-open.md` §3.2       | `entry = vnode_idx (low 16) | offset (high 48)`. `entry & 0xFFFF` extracts vnode_idx. |
| Root vnode published    | `_mount_table[0].root_idx == 1`                   | Confirmed at `core/fs/vnode_pool.pdx:42`: `VNODE_IDX_ROOT = 1`. Refcount lives at vnode +4 (per #576). |
| Witness path `"/"`      | `tools/boot_stub.S:615`                           | Reused for the witness's opening `sys_open` (§5 sub-test A prep). |
| `_sys_open_witness_task` | `kernel_main.pdx:3406` (#587, LANDED)             | Not directly reused — see §4.1 for the fresh-slab decision. |

### 2.2 What is NOT in place — no gaps

Unlike #587 (which had to work around vfs_open's O_CREAT stub), #588
has **no known missing dependency**. Every primitive it calls is
witnessed at boot time before this witness runs. Concretely:

- `vfs_close` is exercised at `kernel_main.pdx:2117` (the #576
  witness) and prints `R16 VFS CLOSE OK` before this witness even
  compiles into the boot flow.
- `fd_get`, `fd_set` are exercised at `kernel_main.pdx:903` area
  (the #549 fd_table witness) and print `R15 FD TABLE OK`.
- `sys_open_body` is exercised at `kernel_main.pdx:2815` (the #587
  witness) and prints `R16 SYS OPEN OK`.

The `R16 SYS CLOSE OK` marker sits immediately after `R16 SYS OPEN OK`
in the fingerprint files (§5.6) — a strict topological successor
in the boot event log.

### 2.3 Encoder gaps

**None.** `sys_close_body` uses only patterns proven pervasively:

| Mnemonic                 | Proven at                                             |
|--------------------------|-------------------------------------------------------|
| `push r64` / `pop r64`   | Every function with a callee-save prologue.           |
| `mov r64, r64`           | Every function.                                       |
| `call sym` (direct near) | Pervasive.                                            |
| `cmp r64, imm32`         | Pervasive (`cmp rsi, 3`, `cmp rsi, 32`, `cmp rax, 0`). |
| `jb` / `jae` / `je` / `jmp` | Every control-flow site (jb is unsigned-below,     |
|                          | proven at `fd_table.pdx:53` `jae fd_alloc_none` and its |
|                          | siblings — same encoder path).                        |
| `and r64, imm32`         | `entry & 0xFFFF` extraction; imm32 sign-extends to     |
|                          | zero-out top bits since 0xFFFF is positive in imm32.   |
| `xor r64, r64`           | Idiomatic zero (used for `xor rax, rax` and `xor rdx, rdx`). |
| `mov r64, imm64`         | For `mov rax, 0xFFFFFFFFFFFFFFF7` (-EBADF sentinel).  |

No SIB scale ambiguity (we don't index into fd_table directly — that's
`fd_get`/`fd_set`'s job). No REX.B extension surprises. No XMM/AVX.
`sys_close_body` is arithmetically simpler than `sys_open_body`
(three calls, one and-mask, no argument shuffle beyond a
`mov rdi, rbx` idiom).

## 3. Design

### 3.1 File and module structure

New file: `src/kernel/core/syscall/handlers/sys_close.pdx`. Sits
alongside the existing handlers (now including sys_open):

```
src/kernel/core/syscall/handlers/
    sys_execve.pdx   (#555)
    sys_exit.pdx     (#557)
    sys_fork.pdx     (#554)
    sys_open.pdx     (#587)
    sys_wait.pdx     (#556)
    sys_close.pdx    <-- THIS ISSUE
```

Module name: `SysClose`. Public export: `sys_close_body`.

### 3.2 Error-code convention

| Return sentinel                | Signed value | Meaning                                    |
|--------------------------------|--------------|--------------------------------------------|
| `0`                            | `0`          | success                                    |
| `0xFFFFFFFFFFFFFFF7`           | `-9`         | `-EBADF` — invalid fd (three failure modes) |

`EBADF = 9` matches Linux errno numbering (same convention family as
`ENOENT = 2` frozen by #587 §3.4). Sign-extended u64 form
(`0xFFFFFFFFFFFFFFF7`) is what `cmp rax, imm32` sees post-return; the
sign bit lets callers do `test rax, rax; js is_error` without
knowing the specific errno.

**Why one sentinel across three failure modes?** POSIX behaviour
convention for `close(2)`: all three modes are legitimately `EBADF`.
Distinguishing them (e.g. `ERANGE` for fd >= 32) would violate POSIX
and diverge from what R17 userland expects. The three modes are
distinguished at the witness sub-test level (C/D/E), not in the
return value.

### 3.3 Register discipline

- **rbx = current** (survives `fd_get`, `vfs_close`, `fd_set`).
  Pushed in the 3-push prologue.
- **r12 = fd** (survives `fd_get`, `vfs_close`, `fd_set`). Pushed
  in the 3-push prologue.
- **r13 = alignment pad** (unused semantically). Pushed to satisfy
  `rsp % 16 == 0` at nested call sites — same 3-push idiom as
  `sys_fork_body` (#554 §prologue) and `sys_open_body` (#587 §3.3).
  A 2-push prologue would leave rsp misaligned (SysV entry
  `rsp % 16 == 8` plus 2 pushes = 8-16 = -8 mod 16 = 8, unaligned;
  3 pushes = 8-24 = -16 mod 16 = 0, aligned).
- **rax, rcx, rdx, rsi, rdi**: scratch. rax carries return values
  across each nested call; content of the others after each `call`
  is what the callee's ABI says.
- **r14, r15**: not used. Kept UN-pushed to save two instruction
  cycles.

All three nested callees (`fd_get`, `fd_set`, `vfs_close`) callee-
save-preserve rbx/r12/r13 per their own justifications:

- `fd_get` and `fd_set` are leaf functions (single `ret` after one
  `mov`) — no clobbers (per #549 justifications).
- `vfs_close` has an explicit 5-push prologue that saves rbx/r12/r13/
  r14/r15 (per #576 §justification).

No cross-call live value ever sits in a caller-save register.

### 3.4 `sys_close_body` — body sequence

```asm
; ================================================================
; sys_close_body(current, fd) -> u64
;   rdi = current       (task_struct*, must be non-NULL — callers
;                        pass either _current_tcb-loaded pointer or
;                        a dedicated witness slab)
;   rsi = fd            (u64 — validated in [3, 32) here)
;
; Returns rax:
;   0                              on success
;   0xFFFFFFFFFFFFFFF7 (-EBADF)    if fd < 3, fd >= 32, or slot free
;
; Register discipline:
;   rbx = current           (saved across fd_get, vfs_close, fd_set)
;   r12 = fd                (saved across all three nested calls)
;   r13 = alignment pad     (unused; kept for pattern uniformity)
;   rax/rcx/rdx = scratch
;
; Prologue: push rbx, r12, r13.  Entry rsp % 16 == 8 (SysV post-call);
; 3 pushes drop rsp by 24, giving rsp % 16 == 0 at each nested call
; site.
; ================================================================
sys_close_body:
    push rbx
    push r12
    push r13

    ; --- Save arguments in callee-save regs ---
    mov rbx, rdi                        ; rbx = current
    mov r12, rsi                        ; r12 = fd

    ; --- Phase 1: validate fd in [3, 32) ---
    cmp r12, 3
    jb  sys_close_ebadf                 ; fd < 3 (stdio reserved)
    cmp r12, 32
    jae sys_close_ebadf                 ; fd >= 32 (out of range)

    ; --- Phase 2: fd_get(current, fd) ---
    mov rdi, rbx
    mov rsi, r12
    call fd_get                         ; rax = entry (u64)

    cmp rax, 0
    je  sys_close_ebadf                 ; slot free ↔ already closed

    ; --- Phase 3: extract vnode_idx and vfs_close it ---
    and rax, 0xFFFF                     ; rax = vnode_idx (low 16 bits)
    mov rdi, rax
    call vfs_close                      ; ignore return value
                                        ; (per #576 §justification vfs_close
                                        ;  never returns a fatal error given
                                        ;  a valid entry-derived idx; the
                                        ;  "0 idx"/"idx>=256"/"underflow"
                                        ;  branches are all guarded above)

    ; --- Phase 4: fd_set(current, fd, 0) — clear slot ---
    mov rdi, rbx
    mov rsi, r12
    xor rdx, rdx                        ; val = 0 (sentinel-0-free)
    call fd_set

    ; --- Success ---
    xor rax, rax                        ; rax = 0
    jmp sys_close_done

sys_close_ebadf:
    mov rax, 0xFFFFFFFFFFFFFFF7         ; -EBADF (-9)

sys_close_done:
    pop r13
    pop r12
    pop rbx
    ret
```

**Instruction count**: ~22 instructions across the body (including
prologue/epilogue). Slightly denser than `sys_open_body` (25 instr)
because there's no argument shuffle for a 4-arg call — sys_close is
2-arg all the way through.

### 3.5 Why the phase order matters

The four phases MUST run in the order Validate → Get → Close → Clear
because:

- **Validate before Get.** `fd_get` performs `mov rax, [rdi + rsi*8 +
  168]` unconditionally (no bounds check per #549). If we called
  `fd_get` before validation, `fd = 100` would read past the fd_table
  region into whatever task_struct fields (or adjacent .bss) sit at
  offset 168 + 100*8 = 968. That would be a boundary escape.
- **Get before Close.** We need the packed entry to extract the
  vnode_idx. Without it, we cannot compose `vfs_close`.
- **Close before Clear.** If we cleared the slot first, then called
  `vfs_close`, and `vfs_close` failed for some reason (e.g. a
  corrupted vnode caused it to page-fault), the slot would already
  be marked free with the vnode still holding the ref — a leak plus
  a stale-close hazard. Doing Close first means: if Close succeeds,
  Clear happens; if Close would fail catastrophically, the slot
  still points to the vnode so a re-close attempt has a target.
  (At R16.M3, vfs_close is documented as never failing given a
  valid entry-derived idx — but preserving the order is a
  robustness margin for later backends.)
- **Clear last.** The final observable side effect. Sub-test B
  verifies this by reading `fd_get(fd)` post-close and expecting 0.

### 3.6 File contents (skeleton)

```pdx
// src/kernel/core/syscall/handlers/sys_close.pdx — R16-M3-002 (#588)
// sys_close body: fd validate + fd_get + vfs_close + fd_set(0) composition.
//
// The inverse of sys_open_body (#587). Consumes the packed fd_entry
// encoding frozen by #587 §3.2 (vnode_idx in low 16 bits, offset in
// high 48 bits) via a single `and rax, 0xFFFF` to extract vnode_idx.
//
// See design/kernel/r16-m3-002-sys-close.md for full contract.

module SysClose = structure {
  // === Error sentinel (negative-errno u64, matches Linux errno signs) ===
  pub let SYS_CLOSE_ERR_EBADF : u64 = 0xFFFFFFFFFFFFFFF7   // -9

  // === Layout constants (from #549 fd_table freeze) ===
  pub let FD_TABLE_STDIO_LO : u64 = 3                       // matches fd_table.pdx:10
  pub let FD_TABLE_MAX      : u64 = 32                      // matches fd_table.pdx:9

  // ==========================================================================
  // sys_close_body — release fd slot; vfs_close vnode
  //
  // Input:
  //   rdi = current   (task_struct*, must be non-NULL)
  //   rsi = fd        (u64 — validated in [3, 32) at the trust boundary)
  //
  // Output:
  //   rax = 0                            on success
  //   rax = 0xFFFFFFFFFFFFFFF7 (-EBADF)  on any of:
  //         (a) fd < 3
  //         (b) fd >= 32
  //         (c) fd_table[fd] == 0
  //
  // Side effects:
  //   on success: vnode's refcount-- (by vfs_close); if refcount hits 0,
  //     vops_close fires (per #576). current->fd_table[fd] is cleared to 0
  //     (sentinel-0-free per #549 §3.4).
  //   on -EBADF: no state mutation (early return before any nested call
  //     that could produce side effects).
  // ==========================================================================
  pub let sys_close_body : (u64, u64) -> u64 !{mem} @{} =
    fn (current: u64) (fd: u64) -> unsafe {
      effects: {mem},
      capabilities: {},
      justification: "R16-M3-002 (#588): sys_close — validate fd; fd_get; vfs_close; fd_set(0). 2-arg SysV entry. rdi=current, rsi=fd. 3-push prologue (rbx, r12, r13) aligns rsp%16==0 for nested calls (r13 is a pad, unused semantically). Phase 1: validate fd in [3,32) via cmp+jb / cmp+jae; unsigned semantics catch both underflow (fd < 3 stdio reserve) and overflow (fd >= 32) with two 3-instruction sequences. Any failure jumps to sys_close_ebadf → rax = 0xFFFFFFFFFFFFFFF7 (-9). Phase 2: fd_get(rbx, r12) → rax = packed entry; cmp rax, 0; je → -EBADF (slot already free ↔ fd not open). Phase 3: and rax, 0xFFFF extracts vnode_idx per #587 §3.2 encoding; mov rdi, rax; call vfs_close. Return value ignored per #576's design (vfs_close returns 0xFFFFFFFFFFFFFFFF on idx==0/idx>=256/refcount==0 at entry — all guarded away by fd being a real live open here). Phase 4: fd_set(current, fd, 0) restores sentinel-0-free per #549 §3.4. Success returns rax=0. Register discipline: rbx (current), r12 (fd) both callee-save-preserved through 3 nested calls; r13 pushed only for rsp alignment (2-push would leave rsp%16==8 misaligned; 3-push lands rsp%16==0 as needed by SysV for nested calls' XMM/red-zone slack). All nested callees (fd_get leaf, fd_set leaf, vfs_close 5-push prologue) trusted callee-save clean per their own justifications. See design/kernel/r16-m3-002-sys-close.md §3 for full rationale.",
      block: {
        push rbx;
        push r12;
        push r13;

        mov rbx, rdi;                        // rbx = current
        mov r12, rsi;                        // r12 = fd

        // Phase 1: validate fd in [3, 32)
        cmp r12, 3;
        jb  sys_close_ebadf;
        cmp r12, 32;
        jae sys_close_ebadf;

        // Phase 2: fd_get(current, fd) → rax = entry
        mov rdi, rbx;
        mov rsi, r12;
        call fd_get;

        cmp rax, 0;
        je  sys_close_ebadf;                 // slot free ↔ fd not open

        // Phase 3: vfs_close(entry & 0xFFFF) — extract vnode_idx, drop ref
        and rax, 0xFFFF;
        mov rdi, rax;
        call vfs_close;                      // return value ignored

        // Phase 4: fd_set(current, fd, 0) — clear slot to sentinel-0-free
        mov rdi, rbx;
        mov rsi, r12;
        xor rdx, rdx;
        call fd_set;

        xor rax, rax;                        // success: rax = 0
        jmp sys_close_done;

      sys_close_ebadf:
        mov rax, 0xFFFFFFFFFFFFFFF7;         // -EBADF

      sys_close_done:
        pop r13;
        pop r12;
        pop rbx;
        ret
      }
    }
}
```

## 4. Witness task_struct — decision

### 4.1 Choice: dedicated `_sys_close_witness_task` (NOT reusing `_sys_open_witness_task`)

The parent task-brief lists sub-test A as "sys_open then sys_close
returns 0". Two ways to seed a live fd:

**Option A — reuse `_sys_open_witness_task`.** After the #587 witness
completes, `_sys_open_witness_task` has fd_table[3], fd_table[4],
fd_table[5] all pointing at root vnode idx 1. sys_close witness could
directly test `sys_close(w, 3) == 0`.

**Option B — dedicated `_sys_close_witness_task` slab.** Fresh
task_struct blob; witness first calls `sys_open` to get fd 3, then
`sys_close` on it.

**Option B wins.** Rationale (mirrors #587 §4.1's independence
argument):

1. **No cross-witness state coupling.** Option A makes the sys_close
   witness dependent on the exact final state of the sys_open witness.
   If someone later extends the sys_open witness (e.g. adds a
   sub-test F that closes fd 5), the sys_close witness silently
   breaks — because sub-test E's "already-closed fd" check would
   flip meaning. Option B's fresh slab means every sub-test's
   precondition is set up explicitly inside the sys_close witness
   block, self-contained.
2. **Matches the `_fd_witness_task` / `_sys_open_witness_task`
   idiom.** Both prior R15/R16 witnesses use dedicated `.bss` blobs
   (`_fd_witness_task`, `_sys_open_witness_task`). Continuing the
   pattern keeps the R16.M3 witness family stylistically uniform
   and search-discoverable (`grep _*_witness_task` finds all of
   them at a glance).
3. **The AC "sys_open then sys_close" reads naturally.** The witness
   literally spells out `call sys_open_body` on line N, then
   `call sys_close_body` on line N+K. A reviewer sees the composition
   in one place — no need to scroll up to the #587 witness to
   understand what's already in the fd_table.
4. **Cleaner refcount arithmetic.** With a fresh slab, the
   witness's own sys_open bumps root vnode refcount by 1, and
   sys_close decrements by 1 — net zero delta on refcount.
   Reusing `_sys_open_witness_task` would decrement refcount from
   `baseline + 3` to `baseline + 2` (or further if we close 4 and
   5 too) — visible cross-witness side effect that a later refcount
   consistency check might trip on.

### 4.2 Slab declaration (mirrors `_sys_open_witness_task`)

At the tail of `kernel_main.pdx`, alongside the existing
`_sys_open_witness_task`:

```pdx
// R16-M3-002 (#588): sys_close witness task storage.
// Static .bss blob (2224 bytes = 278 u64s) backing a dedicated
// witness task_struct.  Not related to _idle_tcb or _task_pool —
// same rationale as _sys_open_witness_task (#587 §4.1): witness
// storage stays independent of the scheduler init sequence so
// R16.M3 witnesses run before idle_init / runq_init without
// ordering hazards.
pub let mut _sys_close_witness_task : [u64; 278] = uninit @align(8)
```

### 4.3 Refcount safety at the witness

The witness performs exactly one `sys_open("/", 0, 0)` on a fresh
slab, then closes the returned fd. Refcount trajectory on root
vnode (idx 1):

| Boot event                                | root refcount |
|-------------------------------------------|---------------|
| Post-mount publication                    | 1 (baseline)  |
| Post-`vfs_open` witness (#575 sub-tests)  | ≥ 1           |
| Post-`vfs_close` witness (#576 sub-tests) | ≥ 1           |
| Post-`sys_open` witness (#587 sub-tests A/B/C, 3 opens) | baseline + 3 |
| **Enter this witness** — sub-test A `sys_open`         | baseline + 4 |
| Sub-test A `sys_close`                    | baseline + 3 |
| Exit this witness                         | baseline + 3 |

Root vnode never approaches refcount == 0 (the `vops_close`-firing
threshold). Safe. No cross-boot side effects on the root vnode's
lifecycle.

### 4.4 Position in kernel_main

Inserted immediately after `sys_open_witness_done:` (line 2875)
and before the `wrmsr` at line 2882 that begins IA32_GS_BASE
setup.

That placement satisfies all prereqs:

- vfs_close witnessed (line 2117).
- sys_open_body witnessed (this file, line 2815 — mm, this issue
  runs `sys_open_body` in sub-test A, so relying on `#587` having
  landed AND witnessed is architecturally required).
- fd_get / fd_set witnessed (line 903 area, R15 tempo).
- No coupling to idle/runq/sched_switch/block_wake witnesses that
  follow the wrmsr.

## 5. Test canary — kernel_main witness block

### 5.1 Preamble

The witness lives in `boot_continue_after_ring3` between the
existing `sys_open_witness_done:` and the `wrmsr` at ~line 2877.
Its inputs:

- `_sys_close_witness_task`: fresh 278-u64 `.bss` blob (all zeros).
- `sys_open_body` proven working end-to-end (by the #587 witness at
  line 2815).
- `sys_close_body` — this issue's function under test.
- `witness_path_slash` (`"/"`) already resident in `boot_stub.S:615`.
- Root vnode idx = 1 (per `VNODE_IDX_ROOT` at `vnode_pool.pdx:42`);
  `sys_open("/", ...)` succeeds against it (proven by #587).

### 5.2 Sub-tests

**Sub-test A**: `sys_open` then `sys_close` returns 0.
```asm
; --- Sub-test A prep: sys_open("/", 0, 0) → fd = 3 (on fresh slab) ---
lea  rdi, [rip + _sys_close_witness_task]
lea  rsi, [rip + witness_path_slash]
xor  rdx, rdx                                ; flags = 0
xor  rcx, rcx                                ; mode = 0 (ignored)
call sys_open_body
cmp  rax, 3                                  ; scan-from-3 → first fd is 3
jne  sys_close_witness_fail

; --- Sub-test A: sys_close(w, 3) → 0 ---
lea  rdi, [rip + _sys_close_witness_task]
mov  rsi, 3
call sys_close_body
cmp  rax, 0
jne  sys_close_witness_fail
```

**Sub-test B**: `fd_table[3]` cleared to 0 after close.
```asm
lea  rdi, [rip + _sys_close_witness_task]
mov  rsi, 3
call fd_get
cmp  rax, 0                                  ; slot must be sentinel-0-free
jne  sys_close_witness_fail
```

**Sub-test C**: `sys_close(w, 2)` returns `-EBADF` (below index 3).
```asm
lea  rdi, [rip + _sys_close_witness_task]
mov  rsi, 2
call sys_close_body
mov  rcx, 0xFFFFFFFFFFFFFFF7                 ; -EBADF
cmp  rax, rcx
jne  sys_close_witness_fail
```

**Sub-test D**: `sys_close(w, 32)` returns `-EBADF` (out of range).
```asm
lea  rdi, [rip + _sys_close_witness_task]
mov  rsi, 32
call sys_close_body
mov  rcx, 0xFFFFFFFFFFFFFFF7                 ; -EBADF
cmp  rax, rcx
jne  sys_close_witness_fail
```

**Sub-test E**: `sys_close(w, 3)` on the already-closed fd returns
`-EBADF`. This idempotency check is critical — it proves phase-4's
clear-to-zero landed and phase-2's `entry == 0 → -EBADF` branch fires
correctly.
```asm
lea  rdi, [rip + _sys_close_witness_task]
mov  rsi, 3
call sys_close_body
mov  rcx, 0xFFFFFFFFFFFFFFF7                 ; -EBADF
cmp  rax, rcx
jne  sys_close_witness_fail
```

### 5.3 Marker

On A, B, C, D, E all green:

```
R16 SYS CLOSE OK
```

Emitted via `uart_puts` on `sys_close_ok_msg`. Fingerprint added to
all three R16.M3-tempo expected-output files, immediately after the
existing `R16 SYS OPEN OK` line.

### 5.4 Witness assembly (complete block)

```asm
; ============================================================
; R16-M3-002 (#588): sys_close witness — 5 sub-tests, 1 marker
; ============================================================
sys_close_witness:
    ; --- Prep: sys_open on fresh slab to seed fd 3 ---
    lea  rdi, [rip + _sys_close_witness_task]
    lea  rsi, [rip + witness_path_slash]
    xor  rdx, rdx
    xor  rcx, rcx
    call sys_open_body
    cmp  rax, 3
    jne  sys_close_witness_fail

    ; --- Sub-test A: sys_close(w, 3) → 0 ---
    lea  rdi, [rip + _sys_close_witness_task]
    mov  rsi, 3
    call sys_close_body
    cmp  rax, 0
    jne  sys_close_witness_fail

    ; --- Sub-test B: fd_get(w, 3) → 0 (slot cleared) ---
    lea  rdi, [rip + _sys_close_witness_task]
    mov  rsi, 3
    call fd_get
    cmp  rax, 0
    jne  sys_close_witness_fail

    ; --- Sub-test C: sys_close(w, 2) → -EBADF ---
    lea  rdi, [rip + _sys_close_witness_task]
    mov  rsi, 2
    call sys_close_body
    mov  rcx, 0xFFFFFFFFFFFFFFF7
    cmp  rax, rcx
    jne  sys_close_witness_fail

    ; --- Sub-test D: sys_close(w, 32) → -EBADF ---
    lea  rdi, [rip + _sys_close_witness_task]
    mov  rsi, 32
    call sys_close_body
    mov  rcx, 0xFFFFFFFFFFFFFFF7
    cmp  rax, rcx
    jne  sys_close_witness_fail

    ; --- Sub-test E: sys_close(w, 3) again → -EBADF (already closed) ---
    lea  rdi, [rip + _sys_close_witness_task]
    mov  rsi, 3
    call sys_close_body
    mov  rcx, 0xFFFFFFFFFFFFFFF7
    cmp  rax, rcx
    jne  sys_close_witness_fail

    ; --- All green ---
    lea  rdi, [rip + sys_close_ok_msg]
    call uart_puts
    jmp  sys_close_witness_done

sys_close_witness_fail:
    lea  rdi, [rip + sys_close_fail_msg]
    call uart_puts

sys_close_witness_done:
```

### 5.5 String data — `tools/boot_stub.S`

Append immediately after the sys_open success/fail messages
(~line 606):

```asm
# R16-M3-002 (#588): sys_close witness success message
.global sys_close_ok_msg
.align 8
sys_close_ok_msg: .ascii "R16 SYS CLOSE OK\n\0"

# R16-M3-002 (#588): sys_close witness failure message
.global sys_close_fail_msg
.align 8
sys_close_fail_msg: .ascii "R16 SYS CLOSE FAIL\n\0"
```

`witness_path_slash` (already at `boot_stub.S:615`) is reused — no
new path strings.

### 5.6 Fingerprint files — marker insertion

The line `R16 SYS CLOSE OK` inserts into all three R16.M3-tempo
fingerprint files immediately after the `R16 SYS OPEN OK` line:

- `tests/r14b/expected-boot-r14b-loader.txt` (insert after line 27)
- `tests/r15/expected-boot-r15-ring3.txt`     (insert after line 37)
- `tests/r15/expected-boot-r15-process.txt`   (insert after line 38)

Contains-in-order matching means the addition is strictly additive
— no earlier line reorders. All existing 5-mode smoke stages
(`boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`,
`boot_r12_denial`) that do not observe R16 markers stay byte-
identically green.

## 6. Alternatives considered / follow-ups (rejected or deferred)

### 6.1 Follow-up: paired refcount rollback for sys_open's -EMFILE branch

**Problem.** `sys_open_body` (#587 §3.3) has a documented leak
(§6.4 there): on the -EMFILE branch, `vfs_open` already bumped
refcount, but no fd_table slot was populated to hold the reference.
The vnode leaks one refcount unit.

Now that `sys_close` composes `vfs_close(vnode_idx)`, the fix is
one insertion: at the top of `sys_open_emfile:` in `sys_open.pdx`,
call `vfs_close(r12)` (r12 still holds the vnode_idx from phase 1)
before setting rax = -EMFILE.

**Deferred, not folded here.** Two reasons:

1. **Scope discipline.** #588's scope is "sys_close body". Extending
   #587's error path from a different issue is a cross-issue edit
   that muddies commit provenance.
2. **Zero observability.** The EMFILE path is unreachable in the
   R16.M3 witness (fresh fd_table has 29 free slots; witness opens
   3-4). The leak is documentation-only until a fd-exhaustion stress
   test runs.

Filed as a proposed R16.M3 follow-up issue: `r16-m3-002b-sys-open-
emfile-rollback` (or fold into the R16.M3 batch-wire issue
alongside SYSCALL entry).

### 6.2 Return `-EIO` on `vfs_close` failure

**Proposal.** If `vfs_close` returns its `0xFFFFFFFFFFFFFFFF` failure
sentinel, propagate a distinct `-EIO` (Linux errno 5, u64
`0xFFFFFFFFFFFFFFFB`) instead of ignoring the return.

**Rejected for R16.M3.** Per §2.1 and #576 §mode 1/2/3, `vfs_close`
only returns its failure sentinel when the caller passes an invalid
idx (0, ≥256, or refcount==0 at entry). All three of those are
structurally impossible from `sys_close`'s call site:

- idx==0 is guarded by phase 2's `cmp rax, 0; je sys_close_ebadf`
  before we mask.
- idx≥256 is impossible for any value from `entry & 0xFFFF`... wait,
  0xFFFF > 256. So idx could be in [256, 65535] if someone stored a
  bogus vnode_idx into fd_table. Under the R16.M3 invariant that
  fd_table entries only come from `sys_open_body` (which sources
  from `vfs_open` → `vnode_alloc` → guaranteed < 256), this is
  ruled out. R17 SYSCALL entry adds `copy_from_user` for the path
  but does not otherwise touch fd_table encoding, so the invariant
  survives.
- refcount==0 at entry is a "double close" hazard — sys_close's
  phase 4 (`fd_set(fd, 0)`) prevents that by clearing the slot on
  every successful close.

Because all three failure modes are guarded upstream, ignoring
vfs_close's return keeps the return path simple. If R17 grows an
alternative fd_table producer (e.g. `sys_dup` bypassing sys_open),
this analysis re-verifies.

Additionally, POSIX `close(2)` is under-specified on backend I/O
failure — real Linux `close(2)` sometimes returns `EIO` for tmpfs
too, and the R16.M3 stub tmpfs backend can't distinguish success
from failure meaningfully. `-EBADF` is the only errno with a
crisp semantics at R16.M3.

### 6.3 Distinguish `fd < 3` from `fd >= 32` with different errnos

**Proposal.** Return `-EINVAL` for fd < 3 (semantically "you asked to
close stdin/stdout/stderr which isn't allowed at R16.M3") and
`-EBADF` for fd >= 32 (out of range).

**Rejected.** POSIX `close(2)` explicitly documents `EBADF` as the
sole errno for both cases; ring-3 code depending on the distinction
would not port to any other POSIX-shaped OS. Also, distinguishing at
this layer leaks R16.M3-internal policy ("stdio is reserved") into
the errno namespace, when the correct place for that policy is a
future R17 `sys_open`-of-stdio path (which itself doesn't exist
yet — stdio at fd 0/1/2 lands with #1613).

### 6.4 Fold `sys_close` into `sys_open`'s file (`sys_open.pdx`)

**Proposal.** Since `sys_close_body` is 22 instructions and cleanly
pairs with `sys_open_body`, put both in one module.

**Rejected.** The one-handler-per-file convention (`sys_fork.pdx`,
`sys_exit.pdx`, `sys_wait.pdx`, `sys_execve.pdx`, `sys_open.pdx`)
is strictly enforced by the existing handlers directory. Folding
breaks that convention for no code-size win (a 22-instruction body
is easy to review in its own file). Also: R16.M3 batch-wire will
walk the handlers/ directory to enumerate syscall bodies for the
dispatch table; a hidden second body in the sys_open file would
be missed.

### 6.5 Use `test rax, rax` in place of `cmp rax, 0`

**Proposal.** More idiomatic than `cmp rax, 0`.

**Rejected.** `test` is not a resolvable mnemonic in paideia-as
(explicitly documented at `vnode_pool.pdx:24-26`). Every prior
"is it zero" check in the codebase uses `cmp reg, 0` — see
`phys_alloc.pdx`, `sys_open.pdx`, `vfs_close.pdx`. Sticking with
the idiom.

### 6.6 Zero the vnode_idx-in-rax before phase 4 (defensive)

**Proposal.** Between phase 3 and phase 4, `xor rax, rax` to avoid
carrying vnode_idx into `fd_set` where it isn't the last argument
anyway.

**Rejected.** `fd_set` takes `val` in rdx, not rax. Phase 4's
`xor rdx, rdx` sets rdx=0 explicitly. rax's stale value is caller-
save scratch that dies at the next `call` boundary. No functional
issue.

## 7. Invariants

### 7.1 fd_entry encoding preserved

`sys_close_body` READS the encoding via `entry & 0xFFFF` and WRITES
sentinel-0 (all bits zero). It does not create a new entry format
or shift the field boundaries. #587 §3.2's `entry = vnode_idx |
(offset << 16)` remains the single source of truth. The `and rax,
0xFFFF` is the canonical decoder for the vnode_idx half.

### 7.2 sentinel-0-means-free preserved

Phase 4's `fd_set(fd, 0)` restores the R15.M5 sentinel exactly.
After a successful `sys_close`, `fd_alloc`'s scan (per #549
§fd_alloc justification) sees the freed slot as reallocatable —
proven at sub-test B (fd_get returns 0). No orphaned encoding
remnants (e.g. offset field still non-zero) — the whole u64
is zeroed, not just the low 16 bits.

### 7.3 Trust boundary — no downstream bounds check

Once `sys_close_body` has validated `fd in [3, 32)` and confirmed
`entry != 0`, all three downstream primitives (`fd_get`, `fd_set`,
`vfs_close`) are called with values that pre-satisfy their own
contracts:

- `fd_get`/`fd_set` receive `fd < 32`, which is the SIB `[rdi +
  rsi*8 + 168]` bound for a 32-slot table.
- `vfs_close` receives `vnode_idx = entry & 0xFFFF`, which is in
  `[1, 65535]` from encoding, and in practice `[1, 255]` from
  `vnode_alloc`'s VNODE_MAX bound. `vfs_close` re-validates
  (`cmp rbx, 0`, `cmp rbx, 256`) but never trips those branches
  when called from sys_close.

The doubly-validated pattern (sys_close pre-guards, vfs_close re-
guards) is defense in depth: if a future R17 fd_table producer
bypasses the encoding contract, `vfs_close`'s bound check catches
the escape.

### 7.4 sys_close_body register discipline

- rbx, r12, r13 are pushed in the prologue and popped in the
  epilogue. Any nested call inside sys_close_body's body MUST
  callee-save-preserve them. Currently verified for `fd_get`
  (leaf, no clobbers), `fd_set` (leaf, no clobbers), `vfs_close`
  (5-push prologue includes rbx/r12/r13 explicitly).
- rax, rcx, rdx, rsi, rdi are caller-save scratch. Content across
  a nested call is undefined except for the callee's documented
  return in rax.
- r14, r15 are NOT touched by sys_close_body. Available for any
  wrapping SYSCALL entry stub to spill user-mode-preserved regs.

### 7.5 Idempotency-under-double-close

`sys_close(current, fd)` returning `-EBADF` on a re-close means
userland can safely retry-close-idle. This lets a future R17
shell's error path (`if (close(fd) < 0) close(fd);`) not corrupt
state. Verified by sub-test E.

## 8. Cross-cutting risks

- **fd_get returning 0 for a live slot.** This would look like
  "double close" to sys_close and mistakenly return `-EBADF`
  instead of doing the real close. Mitigation: #587 §3.2 encoding
  guarantees `entry & 0xFFFF > 0` for any populated slot (vnode_alloc
  never issues idx 0 per #571; `vfs_open` writes a real idx into
  the low 16 bits). The invariant is verified live by the sys_open
  witness (sub-test D at kernel_main.pdx:2843–2854). Regression
  surface: any future primitive that populates fd_table via a path
  other than `sys_open_body`. Currently there are none — #591
  (sys_dup2) is future, and its design will re-verify.
- **vfs_close silently corrupting adjacent vnodes.** If our
  `entry & 0xFFFF` extraction ever masked the wrong bits (e.g. an
  encoding drift landed `and rax, 0xFFFFFFFF` instead), we could
  pass a bogus idx into vfs_close. Mitigation: sub-test A verifies
  `vfs_close` actually runs against the correct vnode by returning
  0 (success) — a wrong-mask value would either hit vfs_close's
  `idx==0`/`idx>=256`/`refcount==0` failure branches (return
  sentinel, which sys_close ignores → sub-test A would still
  return 0 — the mask bug would be silent). To catch encoding
  drift, sub-test B verifies `fd_get(w, 3) == 0` end-to-end which
  proves phase 4 landed. The remaining risk (mask drift in an
  R16.M3 successor issue) is caught by inter-doc §3.2 review
  discipline — no automated invariant.
- **Race between vfs_close and vops_close side effects.** R16.M3
  is single-threaded (no preemption during syscall body); no race.
  R17 SYSCALL entry landing will need `close` to hold a per-task
  fd_table lock or run with preemption disabled. Filed for R17.
- **-EBADF via wrong branch on huge unsigned fd.** A caller
  passing `fd = 0xFFFFFFFFFFFFFFFF` should hit the `fd >= 32`
  branch, not fd < 3. With `cmp rsi, 3; jb`, unsigned `0xFFFF...`
  is above 3, so jb does NOT fire — correct. `cmp rsi, 32; jae`
  DOES fire — correct. Verified by both branches being unsigned
  compares. No signed/unsigned confusion.

## 9. LOC estimate

| File                                                       | LOC        |
|------------------------------------------------------------|------------|
| `src/kernel/core/syscall/handlers/sys_close.pdx` (new)     | ~80        |
|   - module boilerplate + constants + justification         |   ~35      |
|   - `sys_close_body` (~22 instructions)                    |   ~30      |
|   - inline comments                                        |   ~15      |
| `src/kernel/boot/kernel_main.pdx` (witness block + slab)   | ~110       |
|   - `_sys_close_witness_task` declaration                  |    ~5      |
|   - prep + 5 sub-tests (A–E), fail/success labels          |   ~85      |
|   - inline comments                                        |   ~20      |
| `tools/boot_stub.S` (2 strings)                            | ~8         |
| 3 expected-output fingerprint files (1 marker each)        | ~3         |
| `design/kernel/r16-m3-002-sys-close.md` (this doc)         | (this)     |
| **Total executable / testing / test-data**                 | **~200**   |

Executable code path: ~80 LOC. Witness + fingerprint: ~121 LOC.

## 10. Tractability

**HIGH.**

- No paideia-as encoder gap. Every instruction used has landed
  precedent (§2.3).
- Composition of four already-witnessed primitives (`fd_get`,
  `fd_set`, `vfs_close`, plus `sys_open_body` in the witness prep) —
  the only novel logic is a 4-instruction fd validation prologue plus
  a one-instruction encoding decoder (`and rax, 0xFFFF`).
- Witness storage is a single `.bss` blob (mirror of #587's
  `_sys_open_witness_task`) — no allocator dependency, no CR3 flip,
  no interrupt discipline, no scheduler init dependency.
- Marker line is contains-in-order — no fingerprint reorder risk
  across other smoke modes.
- Simpler than #587 (2-arg entry vs 4-arg, no argument shuffle,
  no OOM-rollback complexity, one error sentinel instead of two).
- Sizing (~200 LOC total) matches recent R16.M3 issues (#587:
  ~196 LOC).
- No cross-repo escalation risk (no paideia-as encoder growth).

Estimated implementation time: **one workerbee session**.
Estimated risk of regressing an existing smoke mode: **near-zero**
(purely additive: one new emit line, one new witness block, one
new .pdx module).

**Known follow-ups (do NOT block #588's landing)**:

- **sys_open -EMFILE rollback** (§6.1) — a two-instruction extension
  to `sys_open.pdx`'s error branch, now that `vfs_close` is on the
  handler-side dependency graph. New R16.M3 issue proposed.
- **SYSCALL entry batch-wire** (§6.4-ish; same batch as #587 §6.2)
  — install `sys_close_body` into the syscall dispatch table so
  ring-3 code can call it. Lands after sys_read / sys_write / sys_dup2
  bodies compose.
- **-EIO from backend I/O failure** (§6.2) — reserved for R17
  when a real backend can distinguish success from failure.

## 11. References

- Issue: paideia-os#588
- Milestone: paideia-os R16.M3 (fd table + open/read/write/close/dup2)
- Prereq issues: #587 (sys_open — packed encoding freeze), #576
  (vfs_close), #549 (fd_table embed)
- Sibling / successor issues: #589 (sys_read), #590 (sys_write),
  #591 (sys_dup2), #592 (fd inherit across fork), #593 (fd_cloexec
  on execve), #594 (`boot_r16_fd` smoke mode)
- Tactical plan: `design/milestones/r14b-tactical-plan.md` §Subsystem 13, item 2
- Master plan: `design/milestones/r14b-master-plan.md` §M19 (VFS)
- Prior-art body pattern: `src/kernel/core/syscall/handlers/sys_open.pdx`
  (#587) — 3-push prologue with rbx/r12/r13, explicit `current` in rdi,
  negative-errno u64 returns, packed fd_entry encoding.
- Prior-art witness pattern: `design/kernel/r16-m3-001-sys-open.md`
  §5 — `_*_witness_task` `.bss` blob + sub-tests A/B/C/D/E + marker
  line + fingerprint insertion.
