---
issue: 592
milestone: R16.M3 (fd table + open/read/write/close/dup2)
subsystem: 13 — file-descriptor + open/read/write/close/dup2
topic: fd_inherit across fork — sys_fork walks child.fd_table, refcount++'s each held vnode
prereq:
  - "#554 (sys_fork_body — LANDED; frozen the fd_table byte-copy loop this doc extends)"
  - "#587 (sys_open — LANDED; freezes the packed fd_entry encoding this walker decodes)"
  - "#588 (sys_close — LANDED; establishes the fd_get/vfs_close discipline the child inherits into)"
  - "#571 (vnode_pool + vnode_slot — LANDED; used inline to reach `_vnode_pool[shared_idx]` for the refcount++)"
  - "#549 (fd_table embed — LANDED; provides the 168-byte offset + FD_TABLE_MAX = 32 the walker sweeps)"
blocks:
  - "#593 (fd_cloexec on execve — will reuse the same walker shape to close-and-decrement fds marked FD_CLOEXEC)"
  - "R17 (sys_clone / vfork — will call the same helper to inherit fds into the clone)"
touching:
  - src/kernel/core/fs/fd_inherit.pdx              (new module — ~50 LOC incl. justification)
  - src/kernel/core/syscall/handlers/sys_fork.pdx  (+3 body LOC + justification note update)
  - src/kernel/boot/kernel_main.pdx                (witness block ~110 LOC + `_fd_inherit_witness_task` optional slab)
  - tools/boot_stub.S                              (2 rodata additions: ok_msg, fail_msg)
  - tests/r14b/expected-boot-r14b-loader.txt       (marker: `R16 FD INHERIT OK`)
  - tests/r15/expected-boot-r15-ring3.txt          (marker)
  - tests/r15/expected-boot-r15-process.txt        (marker)
  - design/kernel/r16-m3-006-fd-inherit-fork.md    (this doc)
related:
  - design/kernel/r15-m6-003-sys-fork.md           (#554 — sys_fork_body composition: task_new + aspace_clone_cow + fd_table copy)
  - design/kernel/r16-m3-001-sys-open.md           (#587 — packed fd_entry encoding: `entry = vnode_idx | (offset << 16)`)
  - design/kernel/r16-m3-005-sys-dup2.md           (#591 — §6.1 vnode_hold factoring proposal, §7.2 refcount conservation, register discipline template)
  - design/kernel/vfs-layout.md                    (#570 — refcount at vnode +4 (u16), §7.4 refcount semantics)
  - design/kernel/r15-m5-007-fd-table-embed.md     (#549 — FD_TABLE_OFFSET = 168, FD_TABLE_MAX = 32, sentinel-0 discipline)
  - design/milestones/r14b-tactical-plan.md        §Subsystem 13, item 6
---

# R16-M3-006 — fd_inherit across fork (#592)

## 1. Scope

Land the R16.M3 subsystem-13 issue #592: the vnode-refcount half of
`sys_fork`'s fd_table inheritance. `sys_fork_body` today (#554) copies
`parent.fd_table[0..32]` verbatim into `child.fd_table[0..32]` — 32
qwords of `mov rax, [rbx + rcx*8 + 168]; mov [r12 + rcx*8 + 168], rax`.
That copy alone leaves every shared vnode with the SAME refcount as
before the fork: if parent held vnode V at refcount R, after fork both
parent AND child point at V but `_vnode_pool[V].refcount` is still R.
The first `sys_close` on either fd drops refcount to R-1, the second
drops to R-2 — potentially firing `vops_close` and freeing V while the
OTHER task still holds a live fd pointing at it. A dangling-index
hazard classic.

The fix is one loop: after the copy, walk `child.fd_table[0..32]`, and
for each non-empty entry, increment the referenced vnode's refcount.
This lands as a **new helper** `fd_inherit_hold(child_task) -> ()` in
a new module `src/kernel/core/fs/fd_inherit.pdx`, called from
`sys_fork_body`'s tail with three lines of glue.

```
sys_fork_body(current) -> {rax, rdx}
    ; ... existing phases 1-4 (task_new, aspace_clone_cow, fd_table copy) ...

    ; NEW phase 4.5 — hold each vnode referenced by child.fd_table
    mov  rdi, r12                          ; child task
    call fd_inherit_hold

    ; ... existing phase 5 (return child->pid) ...
```

and

```
fd_inherit_hold(child_task) -> ()
    for rcx in [0..32):
        entry = child.fd_table[rcx]
        if entry == 0: continue           ; empty slot
        vnode_idx = entry & 0xFFFF
        if vnode_idx == 0: continue       ; sentinel (defensive)
        if vnode_idx >= 256: continue     ; out-of-range (defensive; see §3.5)
        vn_ptr = vnode_slot(vnode_idx)
        vn_ptr.refcount_u16 += 1
```

### 1.1 What this issue proves

- **fd inheritance is refcount-conservative.** Post-fork, EVERY vnode
  referenced by parent's fd_table is also held by child; refcount
  therefore MUST have grown by the number of shared holds. The
  witness (§5) opens `/tmp/x` in the parent (x_idx.refcount = 1),
  forks, then observes x_idx.refcount == 2. Symmetric to sys_dup2's
  Phase 7 (#591 §3.3): a fd copy without a hold is a refcount leak
  in the opposite direction (dangling instead of leaking).
- **The packed fd_entry encoding is decoded correctly during a
  walker sweep.** #591 established the `and rax, 0xFFFF` decoder for
  the vnode_idx half at a single call site. #592 applies the same
  decoder inside a 32-iteration loop, proving the encoding survives
  a bulk sweep with no accidental mask drift.
- **Zero-entry short-circuit is exact.** Child's fd_table[0..2]
  (stdin/out/err placeholders) are all zero at R16.M3; the walker
  must NOT try to `vnode_slot(0)` on them (slot 0 is the reserved
  sentinel per vnode-layout §2, and the "cmp rax, 0; je continue"
  gate in fd_inherit_hold is the primary correctness gate). Sub-test
  C observes child.fd[0/1/2] == 0 with the shared refcount still
  intact — no spurious hold on the sentinel.
- **Full lifecycle composability.** `open → fork → close(parent) →
  close(child) → vops_close` is transitively proven: sys_open bumps
  refcount to 1; fd_inherit_hold bumps to 2; sys_close on either
  drops to 1 (still open); sys_close on the last drops to 0 and
  fires vops_close. This is the same lifecycle sys_dup2 exercises
  (#591 §1.1), now covered via the fork path.

### 1.2 What this issue deliberately does NOT do

- **No CoW page-table refcounts.** aspace_clone_cow (called by
  sys_fork before this walker runs) is already handling the CoW
  refcounts on the page-table side. #592 is scoped strictly to the
  vfs vnode refcount arithmetic.
- **No file-description sharing.** The packed encoding at R16.M3
  copies vnode_idx AND offset per-fd (see #591 §7.6). Post-fork,
  parent and child have INDEPENDENT offsets — a POSIX divergence
  tracked for the R17 24-byte fd_entry widening. #592 preserves the
  same divergence sys_dup2 preserved; it is NOT the widening
  issue.
- **No FD_CLOEXEC handling.** #593 will walk the same fd_table on
  execve and close-and-decrement any fd marked FD_CLOEXEC. The
  fd_entry has no flags byte at R16.M3, so there is nothing to
  clear here. When #593 lands it will reuse fd_inherit_hold's walker
  shape.
- **No sys_fork body rewrite.** The existing sys_fork_body #554 is
  preserved as-is except for the 3-line glue to invoke
  fd_inherit_hold. Register discipline, phase order, error handling
  all unchanged.
- **No vnode_hold factoring in this issue.** #591 §6.1 proposed
  factoring the inline refcount++ from vfs_open + sys_dup2 into a
  shared `vnode_hold` helper once a third call-site surfaced. #592
  IS that third call-site. But rather than folding the factoring
  into this issue, we inline the same 4-instruction sequence a
  third time and file the sweep as a separate R16-tail cleanup
  (§6.2). Rationale: keeping #592 minimal shortens the review
  surface; the factoring is a mechanical 3-file edit best done in
  its own commit.
- **No rollback on task_new / clone_cow failure.** Those failure
  paths return BEFORE the fd_table copy (see sys_fork.pdx phases
  2-3), so fd_inherit_hold never runs on a partially-constructed
  child. No new failure-path bookkeeping needed.
- **No lock discipline.** R16.M3 is single-threaded. When R18
  preemption lands, sys_fork will hold the per-task fd_table lock
  around the copy + hold sequence — no in-body change needed.

## 2. Prereq check

### 2.1 What is in place

| Primitive        | Location                                            | Contract used                                                                                                                                                                    |
|------------------|-----------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `sys_fork_body`  | `core/syscall/handlers/sys_fork.pdx` (#554, LANDED) | fd_table byte-copy already lands at phase 4 (line 52-60). #592 hooks in AFTER the copy loop finishes, before phase 5 sets rax.                                                     |
| `sys_open_body`  | `core/syscall/handlers/sys_open.pdx` (#587, LANDED) | Used by witness preamble to seed parent's fd_table with a real vnode-backed entry.                                                                                                 |
| `vnode_slot`     | `core/fs/vnode_pool.pdx:148` (#571, LANDED)         | `(idx) -> u64` — returns `&_vnode_pool[idx*64]`. Called once per non-empty fd slot inside fd_inherit_hold's loop.                                                                    |
| Packed fd_entry  | `design/kernel/r16-m3-001-sys-open.md` §3.2         | `entry = vnode_idx (low 16) | offset (high 48)`. `and rax, 0xFFFF` extracts vnode_idx — same decoder as sys_dup2 phase 7.                                                          |
| `mov_w` mnemonic | proven at `vfs_open.pdx:124,130`, `vfs_close.pdx:83,91`, `sys_dup2.pdx` phase 7 | u16 zero-extending load / u16 store for the refcount arithmetic.                                                                                  |
| task_new         | `core/proc/task_new.pdx` (LANDED)                   | Used by witness preamble to build a real parent (aspace-backed, so sys_fork's clone_cow doesn't UB on `[parent + 16]`).                                                             |
| aspace_clone_cow | `core/mem/aspace_clone.pdx` (LANDED)                | Called inside sys_fork_body before the fd_table copy. Unchanged by this issue.                                                                                                     |
| _pid_table       | Persisted from #554                                 | Witness uses `_pid_table[child_pid]` to recover the child slab after sys_fork_body returns. Same idiom as sys_fork_witness (kernel_main.pdx:1570-1573).                             |
| mount + tmpfs    | LANDED through #586                                 | Witness preamble uses the same wire-and-trim pattern as #591's sys_dup2 witness (see §4.3).                                                                                         |
| `witness_path_tmp_x` | `tools/boot_stub.S:680` (#589)                  | `"/tmp/x\0"`. Reused verbatim.                                                                                                                                                     |
| `witness_name_tmp` / `witness_name_any` | `tools/boot_stub.S:517, 525` | `"tmp\0"`, `"x\0"`. Reused verbatim.                                                                                                                                                |

### 2.2 What is NOT in place — nothing new

**#592 introduces zero new rodata beyond the two OK/FAIL messages.**
Path strings, directory name strings, all pre-existing. The witness
uses `task_new` for its parent (not a `.bss` blob), so no new witness
slab is strictly required — but §4.1 argues we DO want a placeholder
slab for the child-slab lookup receipt.

### 2.3 Encoder gaps

**None.** fd_inherit_hold uses only mnemonics proven pervasively:

| Mnemonic                    | Proven at                                                     |
|-----------------------------|---------------------------------------------------------------|
| `push r64` / `pop r64`      | Every callee-save prologue.                                   |
| `mov r64, r64`              | Pervasive.                                                    |
| `mov r64, [r64 + r64*8 + disp]` | fd_get, fd_alloc, sys_fork copy loop.                     |
| `cmp r64, imm32`            | Pervasive.                                                    |
| `jb` / `jae` / `je` / `jne` / `jmp` | Every control-flow site.                              |
| `and r64, imm32`            | `entry & 0xFFFF` — sys_dup2 phase 5 + phase 7.                |
| `mov_w r64, [r64+disp]`     | u16 zero-extending load — vfs_open, vfs_close, sys_dup2.       |
| `mov_w [r64+disp], r64`     | u16 store — vfs_open, vfs_close, sys_dup2.                    |
| `inc r64`                   | vfs_open, sys_dup2 phase 7.                                   |
| `call sym`                  | Pervasive.                                                    |
| `add r64, imm8`             | Loop increment — sys_fork copy loop.                          |

Zero new encoder surface vs the R16.M3 baseline.

## 3. Design

### 3.1 File and module structure

**New file**: `src/kernel/core/fs/fd_inherit.pdx`. Sits alongside
the sibling walker/composer modules under `core/fs/`:

```
src/kernel/core/fs/
    fd_table.pdx      (#549 — fd_get/fd_set/fd_alloc leaf helpers)
    fd_inherit.pdx    <-- THIS ISSUE (walker: refcount++ across a task's whole fd_table)
    mount.pdx
    vfs_open.pdx
    vfs_close.pdx
    vfs_read.pdx
    vfs_write.pdx
    vnode_pool.pdx
    ...
```

Module name: `FdInherit`. Public export: `fd_inherit_hold`.

**Why a new file and not fd_table.pdx.** `fd_table.pdx` contains
opaque-u64 accessors that know nothing about vnode semantics
(#549 justification). fd_inherit_hold reaches into `_vnode_pool` to
touch the refcount field — that's a vnode-layer concern. Keeping
`fd_table.pdx` semantics-free preserves the layer separation. The
new file is the natural home for future fd-walker helpers
(fd_cloexec_on_execve, fd_release_all_on_exit).

**Why not inline in sys_fork.pdx.** Two future callers (#593
FD_CLOEXEC on execve; R17 sys_clone / vfork) will reuse the same
walker shape. Factoring on the first use is standard R16.M3
practice (see sys_open / sys_close / sys_dup2's shared reliance on
`fd_get` / `fd_set`).

### 3.2 fd_inherit_hold — register discipline

Two persistent values must survive the nested `vnode_slot` call:
- `task` (arg), for the `[task + rcx*8 + 168]` load each iteration
- loop counter, needs a callee-save reg to survive the call

2-push prologue (rbx + r12) gives `rsp % 16 == 0` at the `call
vnode_slot` site (SysV entry has rsp%16==8; 2 pushes → 0).

| Reg | Role                                                                                                        |
|-----|-------------------------------------------------------------------------------------------------------------|
| rbx | `task` (child slab pointer). Survives all loop iterations and the nested `vnode_slot` call.                  |
| r12 | Loop counter (0..32). Survives the nested `vnode_slot` call. Same idiom as the outer save in sys_dup2 §3.2. |
| rax | Scratch: fd_entry load, and-decode, vnode_slot return, refcount arithmetic.                                  |
| rcx | Scratch: refcount u16 register.                                                                              |
| rdi | Argument to `vnode_slot` (vnode_idx).                                                                        |

### 3.3 fd_inherit_hold — body sequence

```asm
; ================================================================
; fd_inherit_hold(task) -> ()
;   rdi = task (task_struct*, non-NULL, fd_table freshly copied
;              from parent). No return value.
;
; Effects:
;   For each rcx in [0, 32): if child.fd_table[rcx] != 0, extract
;   vnode_idx (low 16 bits), and if it names a valid vnode-pool
;   slot (idx in [1, 256)), increment `_vnode_pool[idx].refcount`
;   by one.
;
; Register discipline:
;   rbx = task              (callee-save, survives nested call)
;   r12 = loop counter      (callee-save, survives nested call)
; ================================================================
fd_inherit_hold:
    push rbx
    push r12

    mov  rbx, rdi                         ; rbx = task
    mov  r12, 0                           ; r12 = loop counter

fd_inherit_loop:
    cmp  r12, 32                          ; FD_TABLE_MAX
    jae  fd_inherit_done

    mov  rax, [rbx + r12*8 + 168]         ; rax = child.fd_table[r12]
    cmp  rax, 0
    je   fd_inherit_next                  ; empty slot — skip

    and  rax, 0xFFFF                      ; rax = vnode_idx (low 16 bits)
    cmp  rax, 0
    je   fd_inherit_next                  ; sentinel (defensive — §3.5)
    cmp  rax, 256                         ; VNODE_MAX
    jae  fd_inherit_next                  ; out of range (defensive — §3.5)

    mov  rdi, rax
    call vnode_slot                       ; rax = &_vnode_pool[vnode_idx]

    xor  rcx, rcx
    mov_w rcx, [rax + 4]                  ; rcx = refcount (u16 zero-ext)
    inc  rcx
    mov_w [rax + 4], rcx                  ; refcount++

fd_inherit_next:
    add  r12, 1
    jmp  fd_inherit_loop

fd_inherit_done:
    pop  r12
    pop  rbx
    ret
```

**Instruction count**: ~18 across the body (2 push + 2 mov + loop
head + 3 skip-check + 1 load + 4-instr refcount++ + 3 loop tail +
2 pop + 1 ret). Compact.

### 3.4 sys_fork_body edit

The change is minimal — one call site at the tail of phase 4:

**Before** (sys_fork.pdx line 51-65):
```asm
        // ===== phase 4: fd_table copy loop =====
        mov rcx, 0;
      sys_fork_fd_loop:
        cmp rcx, 32;
        jae sys_fork_fd_done;
        mov rax, [rbx + rcx*8 + 168];
        mov [r12 + rcx*8 + 168], rax;
        add rcx, 1;
        jmp sys_fork_fd_loop;
      sys_fork_fd_done:

        // ===== phase 5: return child pid =====
        mov eax, [r12 + 0];
        xor rdx, rdx;
        jmp sys_fork_return;
```

**After**:
```asm
        // ===== phase 4: fd_table copy loop =====
        mov rcx, 0;
      sys_fork_fd_loop:
        cmp rcx, 32;
        jae sys_fork_fd_done;
        mov rax, [rbx + rcx*8 + 168];
        mov [r12 + rcx*8 + 168], rax;
        add rcx, 1;
        jmp sys_fork_fd_loop;
      sys_fork_fd_done:

        // ===== phase 4.5 (#592): hold each inherited vnode =====
        mov rdi, r12;
        call fd_inherit_hold;

        // ===== phase 5: return child pid =====
        mov eax, [r12 + 0];
        xor rdx, rdx;
        jmp sys_fork_return;
```

**Register safety across the new call.**
- `rbx` (parent) — callee-save; fd_inherit_hold's 2-push prologue
  preserves it.
- `r12` (child) — callee-save; fd_inherit_hold's 2-push prologue
  preserves it AND uses it internally (as loop counter after
  pushing the caller's r12 onto the stack).
- `r13` — pushed by sys_fork's 3-push prologue as alignment
  filler, not read afterward. Unaffected.
- `rax, rcx, rdx, rdi, rsi` — caller-save. The subsequent phase 5
  writes fresh values to `eax`/`rdx`, so no live-across-call value
  needs preserving.

**Stack alignment.** sys_fork enters with rsp%16==8. Its own 3-push
prologue → rsp%16==0. The `call fd_inherit_hold` therefore sees
rsp%16==0 as SysV requires. fd_inherit_hold's own 2 pushes make
rsp%16==0 at its own `call vnode_slot`, which vnode_slot expects.

**Failure paths unaffected.** fd_inherit_hold returns void with no
sentinel semantics — every fd slot either holds successfully or is
skipped. There is no error path. sys_fork's existing fail_new and
fail_rollback labels remain reachable only from the earlier phases
(before fd_inherit_hold could run).

**Justification-block update.** sys_fork.pdx's existing
justification string calls out "sequential composition of
task_new + aspace_clone_cow + fd_table copy". Update to include the
fd_inherit_hold call and its refcount semantics — see §3.6.

### 3.5 Why the defensive bounds check

The `cmp rax, 0; je` + `cmp rax, 256; jae` guards on vnode_idx
appear redundant given that R16.M3 fd_entry producers (sys_open,
sys_dup2) always write a vnode_idx in `[1, 256)`. Two reasons they
stay:

1. **sys_fork_witness (kernel_main.pdx:1541-1547) seeds parent's
   fd_table with test-pattern magic values** — specifically:
   ```
   fd[3]  = 0xDEADBEEFCAFEBABE    (vnode_idx low-16 = 0xBABE = 47806)
   fd[5]  = 0x1122334455667788    (vnode_idx low-16 = 0x7788 = 30600)
   fd[31] = 0xF00DBEEF00000001    (vnode_idx low-16 = 0x0001 = 1)
   ```
   The BABE and 7788 values are BOTH out of the `[0, 256)`
   vnode-pool range. sys_fork_body runs BEFORE any R16.M3 witness
   (line 1527, well before line 3210's sys_dup2 witness), so this
   sys_fork_witness fires with fd_inherit_hold walking exactly
   these out-of-range values. Without the `cmp rax, 256; jae`
   guard, `vnode_slot(0xBABE)` would compute `&_vnode_pool + 0xBABE
   * 64` — a 3 MiB stride past the pool base — and the subsequent
   `mov_w [rax + 4], rcx` would silently corrupt memory somewhere
   deep in `.bss` (or worse). With the guard, all three magic
   values are cleanly skipped and sys_fork_witness stays green
   post-#592. The 0x0001 case IS a legal vnode_idx and DOES fire a
   refcount++ on slot 1 (the root vnode) — this is benign because
   the witness never re-reads slot 1's refcount, but §8 notes it as
   a residual cross-witness coupling.

2. **The producer-contract argument is soft, not structural.**
   The fd_table opaque-u64 discipline (#549) leaves any producer
   free to write any u64 into a slot; sys_open and sys_dup2 happen
   to constrain their outputs to well-formed entries, but future
   producers (an experimental sys_pipe, an IPC-fd backend) could
   temporarily emit malformed values. A walker that trusts by
   construction is fragile against future producer growth. Two
   extra `cmp` instructions per iteration is a cheap tax for
   defense in depth.

The `cmp rax, 0; je` guard also protects against a slot with
`(vnode_idx == 0, offset != 0)` — arithmetically impossible from
R16.M3 producers but semantically "invalid entry, treat as free".
Same defense-in-depth rationale.

### 3.6 File contents (skeleton)

```pdx
// src/kernel/core/fs/fd_inherit.pdx — R16-M3-006 (#592)
// fd_inherit_hold: walk task->fd_table[0..32] and refcount++ each
// referenced vnode. Called by sys_fork_body after the fd_table
// byte-copy to lift the shared refcounts to the "both parent and
// child hold" state.
//
// Consumes the packed fd_entry encoding frozen by #587 §3.2:
//   entry = vnode_idx (low 16) | offset (high 48)
// The walker decodes vnode_idx with `and rax, 0xFFFF`; the offset
// is preserved as-is because refcount++ has no offset-dependence.
//
// See design/kernel/r16-m3-006-fd-inherit-fork.md for full contract.

module FdInherit = structure {
  pub let FD_TABLE_OFFSET       : u64 = 168        // matches fd_table.pdx (#549)
  pub let FD_TABLE_MAX          : u64 = 32         // matches fd_table.pdx (#549)
  pub let VNODE_MAX             : u64 = 256        // matches vnode_pool.pdx (#571)
  pub let VNODE_REFCOUNT_OFFSET : u64 = 4          // u16 refcount at vnode +4 (#570)

  // ==========================================================================
  // fd_inherit_hold — walk child's fd_table, refcount++ each held vnode.
  //
  // Input:
  //   rdi = task (task_struct*, non-NULL; fd_table freshly copied from parent)
  //
  // Output:
  //   No return value. rax undefined.
  //
  // Side effects:
  //   For each non-empty entry in task.fd_table[0..32], the referenced
  //   vnode's u16 refcount at `_vnode_pool[vnode_idx].refcount` is
  //   incremented by 1. Empty slots (entry == 0) and out-of-range
  //   vnode_idx values (defensive — see design §3.5) are skipped.
  // ==========================================================================
  pub let fd_inherit_hold : (u64) -> () !{mem} @{} =
    fn (task: u64) -> unsafe {
      effects: {mem},
      capabilities: {},
      justification: "R16-M3-006 (#592): fd_inherit_hold — refcount++ every vnode referenced by task.fd_table[0..32]. Called by sys_fork_body's tail after the parent→child fd_table byte-copy, to lift refcounts to the 'shared between parent and child' state (without which the first sys_close on either side would drop the count and potentially fire vops_close while the other side still holds a live fd). 2-push prologue (rbx, r12) aligns rsp%16==0 for the nested vnode_slot call and preserves task ptr + loop counter across it. Loop: rcx style using r12 as callee-save counter (0..32). Each iteration loads child.fd_table[r12] into rax; the `cmp rax, 0; je` gate skips empty slots (parent's fd_table[0..2] are all zero at R16.M3, so those iterations short-circuit cleanly). For non-empty entries, `and rax, 0xFFFF` extracts vnode_idx per #587 §3.2 encoding. Two defensive guards follow: `cmp rax, 0; je` (skip the reserved sentinel slot 0 per #570 SS7.2), and `cmp rax, 256; jae` (skip out-of-VNODE_MAX indices — required for correctness against sys_fork_witness's pre-#591 seed values 0xDEADBEEFCAFEBABE / 0x1122334455667788 whose low-16 halves (0xBABE, 0x7788) are outside the vnode-pool bound; see design §3.5). vnode_slot(vnode_idx) returns &_vnode_pool[idx*64]; refcount lives at +4 as u16. Load via `mov_w rcx, [rax + 4]` (zero-extends), `inc rcx`, store via `mov_w [rax + 4], rcx`. Byte-identical to the inline hold at vfs_open.pdx:122-130 and sys_dup2's phase 7 — see #591 §6.1 for the deferred vnode_hold factoring across all three sites. Register discipline: rbx (task), r12 (loop counter) both callee-save-preserved across vnode_slot; vnode_slot itself is a leaf function (3 instructions, no clobbers per its own justification). Overflow: u16 refcount cap of 65535 is well beyond FD_TABLE_MAX (32) × plausible NPROC — same argument as #591 §8. See design/kernel/r16-m3-006-fd-inherit-fork.md for full contract.",
      block: {
        push rbx;
        push r12;

        mov rbx, rdi;                          // rbx = task
        mov r12, 0;                            // r12 = loop counter

      fd_inherit_loop:
        cmp r12, 32;                           // FD_TABLE_MAX
        jae fd_inherit_done;

        mov rax, [rbx + r12*8 + 168];          // rax = task.fd_table[r12]
        cmp rax, 0;
        je  fd_inherit_next;                   // empty slot — skip

        and rax, 0xFFFF;                       // rax = vnode_idx
        cmp rax, 0;
        je  fd_inherit_next;                   // sentinel (defensive)
        cmp rax, 256;                          // VNODE_MAX
        jae fd_inherit_next;                   // out of range (defensive; §3.5)

        mov rdi, rax;
        call vnode_slot;                       // rax = &_vnode_pool[vnode_idx]

        xor rcx, rcx;
        mov_w rcx, [rax + 4];                  // rcx = refcount (u16)
        inc rcx;
        mov_w [rax + 4], rcx;                  // refcount++

      fd_inherit_next:
        add r12, 1;
        jmp fd_inherit_loop;

      fd_inherit_done:
        pop r12;
        pop rbx;
        ret
      }
    }
}
```

### 3.7 Phase-order argument (sys_fork side)

Why "copy then hold" (fd_inherit_hold AFTER the copy loop) rather
than "hold then copy" or "hold-during-copy":

- **Hold-during-copy** (extract vnode_idx and refcount++ inside the
  same iteration that does the byte-copy): forces a nested call
  (vnode_slot) inside the copy loop, dirtying the caller-save rcx
  loop counter on every iteration — needs a callee-save reg for
  the counter, saves nothing net vs the split loop, and mixes two
  concerns (copy vs refcount) that are otherwise orthogonal.
- **Hold-then-copy** (walk parent's fd_table with refcount++ BEFORE
  the copy): puts a refcount++ side effect on the parent's vnodes
  BEFORE the child slot even exists. If aspace_clone_cow had OOM'd
  (which it can't in this order, but a future reordering could
  re-introduce), the refcount++ would need rollback — an extra
  failure-path walker.
- **Copy-then-hold** (current design): the copy is a pure memory
  move (no failure), then the hold is a pure refcount++ (no
  failure), then phase 5 returns. Both operations are separately
  atomic, and the hold ALWAYS sees a consistent child.fd_table
  because the child slab is entirely private until phase 5 puts
  its pid into _pid_table.

Copy-then-hold also matches Linux `copy_process()`'s
`copy_files()` phase order.

## 4. Witness task_struct — decision

### 4.1 Choice: reuse task_new for parent + walk _pid_table for child

Same as sys_fork_witness (kernel_main.pdx:1531). Reasons:

- **sys_fork_body needs a real aspace on the parent.** Its phase 3
  loads `[rbx + 16]` (user_pml4_va) and hands it to
  aspace_clone_cow. A .bss task-shaped blob (like #591's
  _sys_dup2_witness_task) has zero at offset +16 → clone_cow UB.
  task_new does the aspace_create_user that populates +16.
- **The child slab is retrieved from _pid_table[child_pid].** This
  is the frozen sys_fork_witness idiom and continues to work.
- **Preamble uses sys_open_body(parent, "/tmp/x")** so parent's
  fd[3] holds a real vnode-backed entry — exactly what
  fd_inherit_hold needs to demonstrate.

### 4.2 Slab declaration — NOT required

No `_fd_inherit_witness_task` .bss slab needed. Parent is
task_new'd (real aspace, real slab), child is task_new'd inside
sys_fork_body. The witness only needs .bss for its own scratch,
which fits in the 5 pushable callee-save regs.

### 4.3 Preamble: wire + trim + reset x_idx refcount + sys_open

Byte-identical to #591's sys_dup2 witness preamble UP TO the
sys_open call. That includes:
- Wire root vnode's vnode-pool slot (ops_ptr + backend_ptr).
- Recover tmp_idx via tmpfs_lookup(root, "tmp").
- Wire /tmp's vnode-pool slot.
- Trim /tmp/x back to fresh 0-size state: tmpfs_unlink + tmpfs_create.
- Wire fresh x_idx's vnode-pool slot.
- **Reset x_idx.refcount to 0** (same idiom as #591 §4.3.1 —
  witness state normalization for the literal sub-test C
  assertion "x_idx.refcount == 2 post-fork" to hold cleanly).

Then diverges from #591:
- **Instead of using a .bss task blob**, call task_new(NULL) →
  parent slab.
- sys_open_body(parent, "/tmp/x", 0, 0) → fd = 3, x_idx.refcount
  → 1.
- Immediately re-read x_idx.refcount and assert == 1 (baseline
  sanity check; makes sub-test B's "== 2 post-fork" easy to
  attribute).

### 4.4 Vnode-pool wiring workaround — same shape as #590/#591

Same defensive re-wire per #590 §4.4. Three instructions per slot
(vnode_slot + two stores).

### 4.5 Position in kernel_main

Insert **after** `sys_dup2_witness_done:` (line 3394) and **before**
the wrmsr at line 3396. This is byte-adjacent to the sys_dup2
placement — the natural spot in the R16.M3 witness ordering.

**Why not before sys_dup2_witness.** fd_inherit_hold gets exercised
by sys_fork_witness at line 1527 (via the 0xDEADBEEFCAFEBABE seed
values, which the §3.5 bounds check turns into no-ops). So the
walker's INDIRECT correctness is already partially proven by the
time sys_dup2_witness runs. Adding fd_inherit_witness AFTER
sys_dup2_witness is a purely additive last-in-family witness.

## 5. Test canary — kernel_main witness block

### 5.1 Preamble

- Wire root/tmp/x vnode-pool slots defensively (§4.4).
- Trim /tmp/x back to fresh 0-size state via tmpfs_unlink +
  tmpfs_create.
- Reset x_idx.refcount to 0.
- task_new(NULL) → parent.
- sys_open_body(parent, "/tmp/x", 0, 0) → fd = 3, x_idx.refcount
  = 1.
- Assert x_idx.refcount == 1 (baseline).

### 5.2 Sub-tests

Matches the parent brief exactly: A/B/C plus a stdio-slot check.

**Sub-test act: sys_fork_body(parent)**

```asm
mov  rdi, r14                           ; r14 = parent (from preamble)
call sys_fork_body                       ; rax = child_pid, rdx = 0

cmp  rax, 2                              ; child_pid must be >= 2
jb   fd_inherit_witness_fail
cmp  rdx, 0                              ; rdx reserved slot
jne  fd_inherit_witness_fail

mov  r12d, eax                           ; r12 = child_pid (zero-ext)

; --- Recover child slab via _pid_table[child_pid] ---
lea  rax, [rip + _pid_table]
mov  r13, [rax + r12*8]                  ; r13 = child slab
cmp  r13, 0
je   fd_inherit_witness_fail             ; pid_table not published
```

**Sub-test A: parent.fd[3] == child.fd[3] (byte-identical entries).**

```asm
mov  rax, [r14 + 24 + 168]               ; parent.fd[3] @ 168 + 3*8
mov  rcx, [r13 + 24 + 168]               ; child.fd[3]
cmp  rax, rcx
jne  fd_inherit_witness_fail
```

Proves: fd_table copy is byte-identical (already covered by
sys_fork_witness's magic-values test, but reiterating with a REAL
entry).

**Sub-test B: x_idx.refcount == 2 (parent + child both hold).**

```asm
mov  rax, [r14 + 24 + 168]               ; parent.fd[3]
and  rax, 0xFFFF                         ; rax = x_idx
mov  rdi, rax
call vnode_slot                          ; rax = &_vnode_pool[x_idx]
xor  rcx, rcx
mov_w rcx, [rax + 4]                     ; rcx = refcount (u16)
cmp  rcx, 2
jne  fd_inherit_witness_fail
```

Proves: fd_inherit_hold fired and lifted x_idx.refcount from 1
(post-open) to 2 (post-fork). This is THE key assertion.

**Sub-test C: child.fd[0/1/2] == 0 (stdio slots stayed zero).**

```asm
mov  rax, [r13 + 0 + 168]                ; child.fd[0]
cmp  rax, 0
jne  fd_inherit_witness_fail

mov  rax, [r13 + 8 + 168]                ; child.fd[1]
cmp  rax, 0
jne  fd_inherit_witness_fail

mov  rax, [r13 + 16 + 168]               ; child.fd[2]
cmp  rax, 0
jne  fd_inherit_witness_fail
```

Proves: (a) the parent-side fd[0/1/2] were zero (as expected for
task_new'd tasks pre-stdio-wiring), so (b) the copy propagated
zeros unchanged, and (c) the `cmp rax, 0; je` early-skip in
fd_inherit_hold prevented any spurious hold on the vnode-pool
sentinel slot 0.

### 5.3 Marker

On A/B/C all green:

```
R16 FD INHERIT OK
```

Emitted via `uart_puts` on `fd_inherit_ok_msg`. Marker added to
all three R16.M3-tempo expected-output files, immediately after
the existing `R16 SYS DUP2 OK` line.

### 5.4 Witness assembly (complete block sketch)

```asm
; ============================================================
; R16-M3-006 (#592): fd_inherit witness — preamble + fork + 3 sub-tests
; ============================================================
fd_inherit_witness:
    ; --- Preamble: wire root, tmp_idx; unlink+create x; wire x_idx;
    ;               reset x_idx refcount; task_new(NULL); open fd=3 ---
    call mount_root_vnode
    mov  rdi, rax
    call vnode_slot
    lea  rcx, [rip + _tmpfs_vops]
    mov  [rax + 24], rcx
    mov  rcx, 1                                 ; TMPFS_INODE_IDX_ROOT
    mov  [rax + 32], rcx

    mov  rdi, 1
    lea  rsi, [rip + witness_name_tmp]
    call tmpfs_lookup
    cmp  rax, 0
    je   fd_inherit_witness_fail
    mov  r12, rax                               ; r12 = tmp_idx

    mov  rdi, r12
    call vnode_slot
    lea  rcx, [rip + _tmpfs_vops]
    mov  [rax + 24], rcx
    mov  rcx, r12
    mov  [rax + 32], rcx

    mov  rdi, r12
    lea  rsi, [rip + witness_name_any]
    mov  rdx, 1
    call tmpfs_unlink
    cmp  rax, 0
    jne  fd_inherit_witness_fail

    mov  rdi, r12
    lea  rsi, [rip + witness_name_any]
    mov  rdx, 1
    mov  rcx, 1                                 ; VNODE_TYPE_REG
    call tmpfs_create
    cmp  rax, 0
    je   fd_inherit_witness_fail
    cmp  rax, 0xFFFF
    je   fd_inherit_witness_fail
    mov  r15, rax                               ; r15 = fresh x_idx

    mov  rdi, r15
    call vnode_slot
    lea  rcx, [rip + _tmpfs_vops]
    mov  [rax + 24], rcx
    mov  rcx, r15
    mov  [rax + 32], rcx

    ; Reset x_idx vnode refcount to 0 (state normalization)
    mov  rdi, r15
    call vnode_slot
    xor  rcx, rcx
    mov_w [rax + 4], rcx

    ; --- task_new(NULL) → parent ---
    xor  rdi, rdi
    call task_new
    cmp  rax, 0
    je   fd_inherit_witness_fail
    mov  r14, rax                               ; r14 = parent slab

    ; --- sys_open_body(parent, "/tmp/x", 0, 0) → fd = 3 ---
    mov  rdi, r14
    lea  rsi, [rip + witness_path_tmp_x]
    xor  rdx, rdx
    xor  rcx, rcx
    call sys_open_body
    cmp  rax, 3
    jne  fd_inherit_witness_fail

    ; --- Baseline sanity: x_idx.refcount == 1 pre-fork ---
    mov  rdi, r15
    call vnode_slot
    xor  rcx, rcx
    mov_w rcx, [rax + 4]
    cmp  rcx, 1
    jne  fd_inherit_witness_fail

    ; --- Act: sys_fork_body(parent) → child_pid, rdx=0 ---
    mov  rdi, r14
    call sys_fork_body
    cmp  rax, 2                                 ; child_pid >= 2
    jb   fd_inherit_witness_fail
    cmp  rdx, 0
    jne  fd_inherit_witness_fail
    mov  r12d, eax                              ; r12 = child_pid (zero-ext)

    ; --- Recover child slab via _pid_table[child_pid] ---
    lea  rax, [rip + _pid_table]
    mov  r13, [rax + r12*8]                     ; r13 = child slab
    cmp  r13, 0
    je   fd_inherit_witness_fail

    ; --- Sub-test A: parent.fd[3] == child.fd[3] ---
    mov  rax, [r14 + 24 + 168]                  ; parent.fd[3]
    mov  rcx, [r13 + 24 + 168]                  ; child.fd[3]
    cmp  rax, rcx
    jne  fd_inherit_witness_fail

    ; --- Sub-test B: x_idx.refcount == 2 ---
    mov  rdi, r15                               ; r15 = x_idx (saved from preamble)
    call vnode_slot
    xor  rcx, rcx
    mov_w rcx, [rax + 4]
    cmp  rcx, 2
    jne  fd_inherit_witness_fail

    ; --- Sub-test C: child.fd[0/1/2] all zero ---
    mov  rax, [r13 + 0 + 168]
    cmp  rax, 0
    jne  fd_inherit_witness_fail
    mov  rax, [r13 + 8 + 168]
    cmp  rax, 0
    jne  fd_inherit_witness_fail
    mov  rax, [r13 + 16 + 168]
    cmp  rax, 0
    jne  fd_inherit_witness_fail

    ; --- All green ---
    lea  rdi, [rip + fd_inherit_ok_msg]
    call uart_puts
    jmp  fd_inherit_witness_done

fd_inherit_witness_fail:
    lea  rdi, [rip + fd_inherit_fail_msg]
    call uart_puts

fd_inherit_witness_done:
```

**Register plan for the outer witness frame:**

| Reg | Role                                                       |
|-----|------------------------------------------------------------|
| r12 | tmp_idx during preamble; child_pid after sys_fork_body      |
| r13 | (reused) child slab pointer post-fork                       |
| r14 | parent slab pointer (from task_new); persistent               |
| r15 | fresh x_idx from tmpfs_create; persistent                     |

Note that r12 is used twice — first for tmp_idx (during preamble
setup), then reused for child_pid (after preamble is done). This
is safe because tmp_idx is dead after the "wire /tmp's vnode-pool
slot" step. Same idiom as sys_dup2_witness's r12 reuse.

## 6. Alternatives considered

### 6.1 Body edit vs new helper

**Chosen: new helper `fd_inherit_hold` in
`src/kernel/core/fs/fd_inherit.pdx`.**

**Alt considered**: inline the loop in sys_fork_body as a phase-4.5
in-body walk.

**Rejected — three reasons.**

1. **Future reuse.** #593 (FD_CLOEXEC on execve) walks the same
   fd_table with a similar shape (close-and-decrement instead of
   just-decrement). R17 sys_clone / vfork will reuse fd_inherit_hold
   verbatim. Factoring on first use is standard practice.
2. **Layer discipline.** sys_fork_body already composes 4
   primitives (task_new, aspace_clone_cow, fd_table copy, and
   implicitly the pid_table publish inside task_new). Adding a
   5th responsibility inline mixes concerns; factoring keeps
   sys_fork_body's justification block from ballooning past its
   existing readability limit.
3. **Testability.** fd_inherit_hold can be exercised independently
   (write a synthetic fd_table, call the helper, observe refcount
   deltas) if a bug ever surfaces. An inline loop is only testable
   through the full sys_fork path.

The cost of a helper is +2 LOC of glue in sys_fork_body (mov rdi,
r12; call fd_inherit_hold). Compared to the +6 LOC of inline loop,
this is a wash — the factoring is essentially free at the source
level and pays back as soon as #593 lands.

### 6.2 Fold vnode_hold factoring into this issue

**Rejected.** #591 §6.1 proposed factoring the inline refcount++
sequence (vnode_slot + mov_w + inc + mov_w) from vfs_open and
sys_dup2 into a shared `vnode_hold(idx) -> ()` helper. #592 IS the
third call-site, so the trigger has fired. But rather than fold
the factoring in here:

- **Landing atomicity.** Refactoring 3 files (vfs_open.pdx,
  sys_dup2.pdx, sys_fork.pdx) plus adding vnode_hold to
  vnode_pool.pdx is a mechanical but wide-cutting edit. Better to
  isolate it in its own commit so blame/diff/review are cleanly
  attributable.
- **Witness independence.** vfs_open's witness (#575) already
  exercises the inline hold; sys_dup2's witness (#591) already
  exercises it; fd_inherit_hold's witness (#592) exercises it a
  third time. Each witness is independent — no re-verification
  cost when the factoring lands later.

Filed as separate R16-tail cleanup: "factor inline refcount++ from
vfs_open / sys_dup2 / fd_inherit_hold into vnode_hold(idx)".

### 6.3 Interleave hold-during-copy in sys_fork's existing loop

**Rejected — §3.7's phase-order argument.**

### 6.4 Skip the defensive bounds check

**Rejected — §3.5's sys_fork_witness argument.** The pre-#591
magic values in sys_fork_witness's fd_table seed would corrupt
memory without the guard.

### 6.5 Use rep-prefix or unrolled walk

**Rejected.** The 32-iteration loop with a nested call per
non-empty entry is not rep-friendly. Unrolling to 32 explicit
iterations would inflate the code size 20x for a walker that runs
only on fork — a hot path but not a mega-hot inner loop. The tight
loop with `add r12, 1; jmp` costs 2 instructions per iteration;
that's fine.

### 6.6 Walk parent's fd_table instead of child's

**Rejected.** Semantically equivalent (post-copy, both fd_tables
are identical), but conceptually the hold is a property of the
CHILD's new references, not a re-hold of parent's existing ones.
Walking child matches the mental model — "child gained N holds".
It also positions the walker to easily grow into a per-fd
FD_CLOEXEC filter (#593) that operates only on child.

### 6.7 Return an error count from fd_inherit_hold

**Rejected.** No failure mode exists inside fd_inherit_hold — the
u16 refcount overflow risk is bounded far below u16 max (see #591
§8). Every iteration either holds or skips; there is no "held N,
failed M" partial success to report. `()` return keeps the ABI
minimal.

## 7. Invariants

### 7.1 Refcount conservation across fork

For each vnode V referenced by parent's fd_table:
- Pre-fork: V.refcount = R (whatever prior open/dup2/close arithmetic left it)
- Post-copy: V.refcount = R (copy doesn't touch refcount)
- Post-hold: V.refcount = R + 1 (fd_inherit_hold's ++)

Net delta across the pool: +N where N is the count of non-empty
fd slots in parent (== child, post-copy).

### 7.2 Parent-child fd binding symmetry

For each i in [0, 32):
- parent.fd_table[i] == child.fd_table[i] (byte-identical)
- If non-empty, both fds reference the same vnode (same low-16
  vnode_idx AND same high-48 offset).
- POSIX divergence: independent offsets going forward (per #591
  §7.6; R17 24-byte widening restores POSIX file-description
  sharing).

### 7.3 sys_fork_body register discipline (post-#592)

Unchanged from #554. rbx and r12 still parent/child pointers;
r13 still alignment filler. The new `call fd_inherit_hold` sees
rsp%16==0 (SysV alignment satisfied) and does not mutate rbx/r12
per fd_inherit_hold's own 2-push prologue.

### 7.4 fd_inherit_hold register discipline

- rbx and r12 pushed in prologue and popped in epilogue.
- Nested call (vnode_slot) is a leaf function that does not clobber
  rbx or r12 (per vnode_pool.pdx justification: "no prologue/
  epilogue, no nested call").
- rax, rcx, rdi, rsi caller-save scratch — undefined across the
  nested call except for the documented rax return of vnode_slot.

### 7.5 Trust boundary — walker is defensive against malformed entries

fd_inherit_hold treats fd_table as opaque input: entry == 0 skips,
vnode_idx == 0 skips (sentinel), vnode_idx >= 256 skips (OOR). No
failure mode; no witness-visible side effect for malformed
entries. Sub-test C's "child.fd[0/1/2] == 0" is the observable
witness that the skip path is correct.

## 8. Cross-cutting risks

- **sys_fork_witness (kernel_main.pdx:1527) already exercises
  fd_inherit_hold via the 0xDEADBEEFCAFEBABE / 0x1122334455667788
  / 0xF00DBEEF00000001 seeds.** All three walker paths fire during
  that early witness:
  - 0xBABE (out-of-range) → §3.5 guard skips.
  - 0x7788 (out-of-range) → §3.5 guard skips.
  - 0x0001 (in-range, root vnode) → refcount++ fires on
    `_vnode_pool[1].refcount`.
  The third case leaks a +1 refcount onto the root vnode BEFORE
  the R16.M1 vnode-pool witness begins. R16.M1 witness (line 1642)
  free-allocates fresh vnodes but doesn't touch root — so the
  leaked +1 persists to sys_dup2_witness's F.2 sub-test. Does F.2
  break? Let's check: F.2 measures root_refcount BEFORE and AFTER
  dup2 within its own frame, using the RELATIVE delta (rax + 1 ==
  r13). The absolute value is irrelevant — the relative delta
  survives the pre-existing +1 leak. GREEN.
  Mitigation: none needed; documented here as an R16-tail concern
  and a future cleanup where sys_fork_witness's magic seeds become
  vnode-legal values (e.g., wire fake but valid entries).
- **The refcount++ inside fd_inherit_hold could overflow the u16
  field.** With FD_TABLE_MAX = 32 and NPROC = 32 at R16.M3, no
  single vnode can be held by more than 32 × 32 = 1024 fds —
  well below u16 max (65535). Same argument as #591 §8.
- **task_new inside the witness may fail (OOM) — if the pid pool
  is exhausted after all preceding witnesses ran task_new for
  their own parents.** Mitigation: witness preamble checks task_new
  result and fails cleanly. R16.M3 pid pool is 32 slots; witness
  ordering has ~6 task_new callers before this one (sys_fork,
  sys_exit, sys_wait, sys_execve, orphan_adopt, plus this
  fd_inherit_witness's own two — parent + child inside sys_fork).
  Total ~7 slots consumed — comfortable margin.
- **The sys_fork body edit changes the justification-block
  string.** Any downstream tooling that snapshots the string
  (grep-based audits) must re-baseline. The new string references
  fd_inherit_hold; the existing "sequential composition" phrase
  is extended, not replaced.
- **fd_inherit_hold's `mov r12, 0` on entry clobbers r12 for the
  caller (sys_fork_body).** But sys_fork's r12 (child pointer) is
  pushed by fd_inherit_hold's own prologue and restored by its
  epilogue — so the caller's r12 is preserved across the call. No
  leak.
- **The `cmp rax, 256` bound is hard-coded rather than symbolic.**
  If VNODE_MAX ever changes, this walker must update in lockstep
  with vnode_pool.pdx. Same coupling exists in vnode_alloc/free.
  Tracked in the shared R16-tail cleanup for symbolic
  VNODE_REFCOUNT_OFFSET / VNODE_MAX constants.

## 9. LOC estimate

| File                                                       | LOC        |
|------------------------------------------------------------|------------|
| `src/kernel/core/fs/fd_inherit.pdx` (new)                  | ~55        |
|   - module boilerplate + constants                         |   ~10      |
|   - justification block                                    |   ~10      |
|   - `fd_inherit_hold` body (~18 instructions)              |   ~25      |
|   - inline comments                                        |   ~10      |
| `src/kernel/core/syscall/handlers/sys_fork.pdx` (edit)     | ~5         |
|   - +2 lines body (mov rdi, r12; call fd_inherit_hold)     |    ~2      |
|   - justification string update (rewrite one sentence)     |    ~3      |
| `src/kernel/boot/kernel_main.pdx` (witness block)          | ~110       |
|   - preamble (wire + trim + reset + task_new + sys_open)   |   ~55      |
|   - baseline refcount==1 sanity                            |    ~7      |
|   - sys_fork_body call + child slab lookup                 |   ~12      |
|   - 3 sub-tests A/B/C                                      |   ~25      |
|   - inline comments + fail/success labels                  |   ~11      |
| `tools/boot_stub.S` (2 strings)                            | ~8         |
| 3 expected-output fingerprint files (1 marker each)        | ~3         |
| `design/kernel/r16-m3-006-fd-inherit-fork.md` (this doc)   | (this)     |
| **Total executable / testing / test-data**                 | **~180**   |

Executable code path: ~60 LOC (fd_inherit.pdx + sys_fork.pdx
delta). Witness + fingerprint: ~121 LOC.

Sizing is smaller than #591 (~300 LOC total) because:
- No new syscall body — just a walker helper.
- Fewer sub-tests (3 vs 6).
- No preamble second-fd sys_open (only fd=3, no fd=4).
- No conditional-close branch to verify.

Comfortably below any R16.M3-body budget.

## 10. Tractability

**HIGH.**

- No paideia-as encoder gap. Every mnemonic proven pervasively (§2.3).
- Composition of two already-witnessed primitives (fd_table copy
  from sys_fork; vnode_slot + refcount++ from vfs_open / sys_dup2).
  No novel logic — the loop wrapper is standard, the per-iteration
  body is a duplicate of the sys_dup2 phase-7 pattern.
- Register discipline is the SIMPLEST of any R16.M3 helper: 2-push
  prologue, one nested call, r12 reused as loop counter after
  the caller's r12 is saved to the stack.
- Witness storage is zero .bss (uses task_new for parent, walks
  _pid_table for child — same idiom as #554).
- Marker line is contains-in-order — no fingerprint reorder risk.
- Sizing (~180 LOC total) is 40% smaller than #591 (~300).
- No cross-repo escalation risk (no paideia-as encoder growth).
- One cross-witness coupling (§8: root vnode +1 leak from
  sys_fork_witness's 0x0001 seed) — verified benign against
  sys_dup2_witness's F.2 relative-delta idiom.

Estimated implementation time: **one workerbee session** (smaller
than #591's session).
Estimated risk of regressing an existing smoke mode: **near-zero**
(purely additive: one new module, three-line sys_fork edit, one
new witness block, one new marker line).

### 10.1 Body edit vs new helper — the direct answer to the parent brief

**New helper.** `fd_inherit_hold` lands in
`src/kernel/core/fs/fd_inherit.pdx` (new file, ~55 LOC). sys_fork
gets a 2-line body edit (arg + call) plus a one-sentence
justification-string update. Rationale: §6.1's three reasons
(future reuse, layer discipline, testability) plus the wash on
source-LOC vs an inline loop.

### 10.2 Known follow-ups (do NOT block #592's landing)

- **vnode_hold factoring** (§6.2) — extract the inline
  refcount++ pattern from vfs_open / sys_dup2 / fd_inherit_hold
  into a shared `vnode_hold(idx) -> ()` helper. Now that #592
  provides the third call-site, the R16-tail cleanup is ready to
  file.
- **VNODE_MAX + VNODE_REFCOUNT_OFFSET symbolic constants** (§8) —
  replace hard-coded 256 / +4 at multiple call-sites with shared
  constants. Small R16-tail cleanup.
- **sys_fork_witness magic-seed cleanup** — replace
  0xDEADBEEFCAFEBABE / 0x1122334455667788 with either vnode-legal
  values (idx in [1, 256)) or skip the seed entirely (the
  fd_inherit witness now covers the fd_table copy correctness at
  a semantic level). Reduces the §8 root-vnode leak. Small
  R16-tail cleanup.
- **R17 file-description-sharing** — restore POSIX per-fd offset
  sharing between parent and child. Blocked on the 24-byte
  fd_entry widening (#587 §6.4). Large R17 follow-up.
- **#593 fd_cloexec_on_execve** — walk the same fd_table on
  execve, close-and-decrement any fd marked FD_CLOEXEC. Reuses
  fd_inherit_hold's walker shape verbatim (loop head + entry
  extract + skip guards); the per-iteration body diverges from
  refcount++ to `vfs_close + fd_set(0)`. Filed under R16.M3
  subsystem 13.

## 11. References

- Issue: paideia-os#592
- Milestone: paideia-os R16.M3 (fd table + open/read/write/close/dup2)
- Prereq issues: #554 (sys_fork_body — fd_table byte-copy),
  #587 (sys_open — packed encoding freeze), #571 (vnode_slot
  helper), #549 (fd_table embed)
- Successor issues: #593 (fd_cloexec on execve), #594
  (`boot_r16_fd` smoke mode), R17 sys_clone / vfork
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 13, item 6
- Master plan: `design/milestones/r14b-master-plan.md` §M19 (VFS)
- Prior-art body pattern:
  `src/kernel/core/syscall/handlers/sys_fork.pdx` (#554) — 3-push
  prologue, phase-composed body, rbx=parent / r12=child /
  r13=alignment discipline preserved unchanged by this issue.
- Prior-art walker helper pattern:
  `src/kernel/core/fs/fd_table.pdx` (#549) — leaf helpers under
  `core/fs/`, one-concern-per-module.
- Prior-art inline refcount++ pattern: `vfs_open.pdx:122-130`,
  `sys_dup2.pdx` phase 7 (#591 §3.3) — byte-identical to the body
  of fd_inherit_hold's per-iteration hold.
- POSIX reference: fork(2) — "The child process shall have its own
  copy of the parent's file descriptors. Each of the child's file
  descriptors shall refer to the same open file description as the
  corresponding file descriptor of the parent." R16.M3's packed
  encoding diverges from "same file description" (independent
  offsets per fd), tracked at #587 §6.4.
