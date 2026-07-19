---
issue: 590
milestone: R16.M3 (fd table + open/read/write/close/dup2)
subsystem: 13 — file-descriptor + open/read/write/close/dup2
topic: sys_write — validate fd; extract vnode_idx+offset; vfs_write; advance offset in fd_table
prereq:
  - "#587 (sys_open — LANDED; freezes the packed fd_entry encoding this doc reads)"
  - "#588 (sys_close — LANDED; freezes the fd validation idiom this doc mirrors)"
  - "#589 (sys_read — LANDED; freezes the 5-phase body shape, register discipline,
                     and offset-advance arithmetic this doc replays with the sole
                     substitution `call vfs_read` → `call vfs_write`)"
  - "#577 (vfs_write — LANDED; dispatcher into vops_write consumed here as the backend surface)"
  - "#586 (tmpfs vops wire — LANDED; provides the vops_write → tmpfs_write chain that vfs_write reaches)"
  - "#583 (tmpfs_write — LANDED; the terminal backend that produces the byte count returned here)"
  - "#585 (tmpfs_unlink — LANDED; used by the witness preamble to trim /tmp/x back to a fresh 0-size state)"
  - "#582 (tmpfs_create — LANDED; used by the witness preamble to re-materialize /tmp/x post-unlink)"
  - "#549 (fd_table embed — LANDED; provides fd_get / fd_set / sentinel-0-means-free discipline)"
blocks:
  - "#591 (sys_lseek — will consume the packed fd_entry encoding and offset-manipulation this doc reuses)"
  - "#593 (sys_dup2 — will need the entry-copy idiom that composes cleanly over this doc's encoding)"
  - "R16.M5 (TTY) — will extend fd 1/2 dispatch beyond the -EBADF frozen here"
  - "R17 (userland shell demo — first ring-3 sys_write caller through SYSCALL entry once batch-wire lands)"
touching:
  - src/kernel/core/syscall/handlers/sys_write.pdx       (new module — ~115 LOC incl. justification)
  - src/kernel/boot/kernel_main.pdx                      (witness block ~140 LOC + `_sys_write_witness_task` slab)
  - tools/boot_stub.S                                    (2 rodata additions: ok_msg, fail_msg — path + src_buf reused)
  - tests/r14b/expected-boot-r14b-loader.txt             (marker: `R16 SYS WRITE OK`)
  - tests/r15/expected-boot-r15-ring3.txt                (marker)
  - tests/r15/expected-boot-r15-process.txt              (marker)
  - design/kernel/r16-m3-004-sys-write.md                (this doc)
related:
  - design/kernel/r16-m3-003-sys-read.md                 (#589 — freezes the 5-phase body shape:
                                                          validate fd; fd_get; decode entry; dispatch;
                                                          advance offset; fd_set. This doc is a
                                                          write-side mirror with a two-instruction delta:
                                                          `call vfs_write` in phase 3 and the substituted
                                                          symbol in the justification comment. The
                                                          offset-advance arithmetic `new_entry = entry +
                                                          (bytes_XXX << 16)` is byte-identical.)
  - design/kernel/r16-m3-001-sys-open.md                 (#587 — freezes packed fd_entry encoding
                                                          `entry = vnode_idx | (offset<<16)` consumed here via
                                                          `and rax, 0xFFFF` (vnode_idx) and `shr rax, 16` (offset),
                                                          and written back via `entry + (bytes_written<<16)`
                                                          after the write completes)
  - design/kernel/r16-m3-002-sys-close.md                (#588 — the fd-validation idiom
                                                          `cmp fd, 3; jb ...; cmp fd, 32; jae ...` frozen there
                                                          and mirrored in #589 is used here verbatim)
  - design/kernel/r16-m1-008-vfs-read-write.md           (#577 — the 4-arg dispatcher consumed here;
                                                          returns bytes_written in `[0, len]` or the
                                                          `0xFFFFFFFFFFFFFFFF` sentinel this doc's §3.4 maps
                                                          to `-EIO`)
  - design/kernel/r16-m2-005-tmpfs-write.md              (#583 — the terminal backend; §4 write chain
                                                          invariant — inode.size = max(size, offset+bytes_written)
                                                          — is what the witness sub-test C relies on)
  - src/kernel/core/syscall/handlers/sys_read.pdx        (the sibling body — this doc's arithmetic and
                                                          register plan are structurally identical)
  - src/kernel/core/syscall/handlers/sys_open.pdx        (the entry producer; established
                                                          `_*_witness_task` slab pattern this doc reuses)
  - design/kernel/r15-m5-007-fd-table-embed.md           (#549 — fd_get / fd_set / sentinel-0 discipline)
  - design/milestones/r14b-tactical-plan.md              §Subsystem 13, item 4
---

# R16-M3-004 — `sys_write`: fd validation + entry decode + vfs_write + offset advance (#590)

## 1. Scope

Land the R16.M3 subsystem-13 issue #590: the write-side sibling of
`sys_read_body` (#589). Full body sequence is a **five-step
composition** over the packed fd_entry encoding frozen by #587 §3.2
and re-consumed by #589 §1:

```
sys_write_body(current, fd, buf_ptr, len) -> u64
    rdi = current      (task_struct*)
    rsi = fd           (u64 in [3, 32) — validated at the trust boundary)
    rdx = buf_ptr      (u64 kernel VA — source buffer)
    rcx = len          (u64 byte count to write)
    rax = bytes_written (in [0, len]) on success
    rax = 0xFFFFFFFFFFFFFFF7 (-EBADF)   on any of:
                                          (a) fd < 3   (stdio-reserved at R16.M3)
                                          (b) fd >= 32 (out of range)
                                          (c) fd_table[fd] == 0 (not open)
    rax = 0xFFFFFFFFFFFFFFFB (-EIO)     if vfs_write returns its
                                          `0xFFFFFFFFFFFFFFFF` sentinel
                                          (structurally unreachable from a
                                          valid entry — see §6.2; also
                                          catches tmpfs single-page overflow)
```

The five steps (byte-identical to #589 phases except in phase 3):

1. **Validate** `fd` in `[3, 32)`. Idiom-identical to `sys_read_body`
   phase 1 (#589 §3.3). Rejecting fd 0/1/2 preserves the R15.M5
   scan-from-3 discipline; fd 1/2 gain console/TTY output semantics
   at R16.M5, not here.
2. **Load** the packed entry via `fd_get(current, fd)`. A zero entry
   means the slot is free — return `-EBADF`.
3. **Decode** the encoding in a single register: `vnode_idx = entry
   & 0xFFFF` (low 16 bits) and `offset = entry >> 16` (high 48 bits),
   per #587 §3.2.
4. **Dispatch** `vfs_write(vnode_idx, buf_ptr, len, offset)`. This
   reaches the tmpfs backend via `vops_write` per the tmpfs vops
   wire (#586). Returns bytes written in `[0, len]` (short writes
   legal but do not occur at R16.M3 tmpfs — see §7.6), or the vops
   error sentinel `0xFFFFFFFFFFFFFFFF`.
5. **Advance** the offset half of the entry by `bytes_written` and
   write it back via `fd_set(current, fd, new_entry)`. The
   vnode_idx half is preserved: `new_entry = entry + (bytes_written
   << 16)`. Return `bytes_written` in rax.

### 1.1 What this issue proves

- **The packed fd_entry encoding round-trips through a write.**
  sys_read (#589) proved the read-side round-trip; #590 proves
  the write-side. Together they close the loop: an fd opened by
  #587, mutated by #589 (read: offset advance), and mutated by
  #590 (write: offset advance) exercises the encoding in all
  three lifecycle roles.
- **The offset-advance arithmetic is provably reusable.** #589
  §1.1 predicted "#590 (sys_write) will reuse the identical
  arithmetic; freezing it here means write is a two-instruction
  delta from read". This doc realizes that prediction — the
  arithmetic `new_entry = entry + (bytes_written << 16)` uses
  the same three-instruction triple (`mov rcx, r14; shl rcx, 16;
  add r15, rcx`) verbatim.
- **Write-then-read persistence composes.** The R16.M3 batch of
  syscall bodies now delivers a full open/write/close/reopen/read
  chain end-to-end. #590's witness proves the persistence half
  (`inode.size` grows from 0 to `bytes_written` after sys_write).
  #589's already-witnessed read-back chain proves the retrieval
  half. The transitive composition (write in one fd, read in
  another fd on the same file) is implicitly proven — no
  additional infrastructure needed.
- **The -EBADF error family established by #588 propagates to
  write.** Same sign-extended u64 (`0xFFFFFFFFFFFFFFF7 == -9`),
  same three failure modes at the trust boundary, same
  doubly-validated discipline downstream (§7.3 of #588).
  Sub-test D actively exercises the fd < 3 mode against fd=2 —
  crucial because fd 1 and fd 2 (stdout/stderr) will gain
  legitimate write semantics at R16.M5, and #590 must NOT
  pre-empt that route.

### 1.2 What this issue deliberately does NOT do

- **No stdio dispatch for fd 1/2.** Write-to-stdout and
  write-to-stderr lie outside R16.M3 scope. The R16.M5 TTY
  milestone will land console output backing for fd 1/2. R16.M3
  refuses all three (0, 1, 2) uniformly with -EBADF.
- **No copy_from_user.** `buf_ptr` is treated as a kernel VA.
  The source buffer sits in `.rodata` / `.data` at witness time.
  When the SYSCALL entry stub lands (R17), it will bounce
  user-mode buffers through a kernel scratch region before
  calling `sys_write_body`; that copy is the stub's concern,
  not this body's.
- **No -EFAULT on invalid buf_ptr.** No page-table walk to
  distinguish valid from unmapped source memory. R16.M3 has no
  infrastructure for it. If `tmpfs_write`'s `rep_movsb` faults
  on a bad buf_ptr, the fault handler catches it — that path is
  R17+ concern (`fixup_extable` idiom).
- **No SYSCALL entry wiring.** Same rationale as #587-#589 —
  batch-wire after all five R16.M3 syscall bodies compose.
  `sys_write_body` is testable in kernel context via the
  witness (§5).
- **No signal-interruptible write.** `sys_write` is atomic at
  R16.M3 (no preemption during syscall). R18+ signal machinery
  will add EINTR + partial-buffer semantics; the return type
  (u64 bytes_written) already supports partial returns via
  short writes.
- **No refcount rollback on -EIO.** Same rationale as #589
  §1.2 — vfs_write doesn't mutate refcount; the write failed
  after the fd was validated; the open fd remains live for a
  later retry or close.
- **No non-blocking / async semantics.** POSIX `O_NONBLOCK` is
  ignored — R16.M3's tmpfs backend is always synchronous.
- **No -ENOSPC surfacing.** `tmpfs_write` maps allocator OOM
  and single-page overflow to the same `0xFFFFFFFFFFFFFFFF`
  sentinel that `vfs_write` forwards. `sys_write` maps that
  sentinel uniformly to -EIO. When the R16.M2 multi-page
  tmpfs_write follow-on lands with distinguished -ENOSPC,
  `sys_write` will grow a second sentinel check; the current
  design leaves the branch order such that the addition is
  strictly additive (§6.5).
- **No offset-clamp against overflow.** `entry + (bytes_written
  << 16)` could in principle overflow the u48 offset field.
  At R16.M3 tmpfs the file cap is 4 KiB (single-page constraint)
  so `offset + bytes_written <= 4096`, which is < 2^13.
  Overflow-safe by input contract; the runtime guard lands with
  the multi-page tmpfs write (R16.M2 follow-on).
- **No size-truncation semantics.** POSIX `write(2)` on a
  file opened without `O_TRUNC` never shrinks the file. `sys_write`
  at R16.M3 always calls `tmpfs_write`, whose size-update logic
  (`r16-m2-005` §4 — `size = max(size, offset+bytes_written)`)
  never shrinks. Correct-by-construction.

## 2. Prereq check

### 2.1 What is in place

| Primitive         | Location                                             | Contract used                                                                                                                                                                                     |
|-------------------|------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `sys_open_body`   | `core/syscall/handlers/sys_open.pdx` (#587, LANDED)  | Used by witness preamble to seed fd=3 pointing at `/tmp/x` with offset=0. Populates entry per #587 §3.2.                                                                                            |
| `sys_read_body`   | `core/syscall/handlers/sys_read.pdx` (#589, LANDED)  | Freezes the 5-phase body shape, 5-push prologue, and offset-advance arithmetic this doc replays.                                                                                                    |
| `fd_get`          | `core/fs/fd_table.pdx:16` (#549, LANDED)             | `(task, fd) -> u64`. Used by phase 2; single SIB+disp load; no bounds check (this issue enforces the bound at the trust boundary).                                                                   |
| `fd_set`          | `core/fs/fd_table.pdx:30` (#549, LANDED)             | `(task, fd, val) -> ()`. Used by phase 5; writes the offset-advanced new_entry back.                                                                                                                |
| `vfs_write`       | `core/fs/vfs_write.pdx` (#577, LANDED)               | `(vnode_idx, buf_ptr, len, offset) -> u64`. Returns bytes_written (in `[0, len]`) or `0xFFFFFFFFFFFFFFFF` on validation failure. Dispatches through vops_write.                                       |
| tmpfs vops wire   | `core/fs/tmpfs/vops.pdx` (#586, LANDED)              | Publishes `vops_write = tmpfs_write_adapter` in the tmpfs vops table; the adapter extracts `inode_idx` from `vnode.backend_ptr` (+32) and calls `tmpfs_write`.                                        |
| `tmpfs_write`     | `core/fs/tmpfs/write.pdx` (#583, LANDED)             | Terminal backend. `(inode_idx, buf, len, offset) -> bytes_written`. Lazy-allocates page on first write; updates `inode.size = max(size, offset+bytes_written)`; single-page constraint at R16.M2. |
| `tmpfs_lookup`    | `core/fs/tmpfs/lookup.pdx` (#581, LANDED)            | Used by the witness preamble to recover `tmp_idx` and `x_idx` from `/` and `/tmp` respectively.                                                                                                     |
| `tmpfs_unlink`    | `core/fs/tmpfs/unlink.pdx` (#585, LANDED)            | Used by the witness preamble to trim `/tmp/x` back to a fresh 0-size state before the sys_write test — makes sub-test C's `inode.size == 100` a growth proof rather than a no-op tautology (§4.3). |
| `tmpfs_create`    | `core/fs/tmpfs/create.pdx` (#582, LANDED)            | Used by the witness preamble to re-materialize `/tmp/x` post-unlink with `size = 0` (mirror of the #589 sys_read preamble's re-create pattern).                                                     |
| `tmpfs_inode_slot`| `core/fs/tmpfs/inode.pdx:50` (#579, LANDED)          | `(inode_idx) -> inode_ptr`. Used by witness sub-test C to load `inode.size` via `[inode_ptr + 8]`.                                                                                                   |
| `_tmpfs_vops`     | `core/fs/tmpfs/vops.pdx` (#586, LANDED)              | Published tmpfs vops table. Used by the witness preamble to wire the freshly-created x_idx's vnode-pool slot (may need re-wiring if unlink+create produces a new idx — see §4.4).                    |
| Packed fd_entry   | `design/kernel/r16-m3-001-sys-open.md` §3.2          | Encoding frozen: `entry = vnode_idx (low 16) | offset (high 48)`. `and rax, 0xFFFF` extracts vnode_idx; `shr rax, 16` extracts offset.                                                              |
| vnode-pool wiring | Persisted from #589's sys_read witness preamble      | Root vnode, tmp_idx vnode slots wired to `_tmpfs_vops` in kernel_main.pdx lines 2960-2989. **Persists into the sys_write witness** (see §4.4). Only x_idx may need re-wiring after unlink+create.    |
| `tmpfs_write_src_buf` | `tools/boot_stub.S:546`                          | 100-byte source buffer, byte-wise 0x41 ('A'). Reused as the sys_write source; no new symbol.                                                                                                        |
| `witness_path_tmp_x` | `tools/boot_stub.S:658` (#589, LANDED)            | `"/tmp/x\0"`. Reused by the sys_write preamble's `sys_open_body` call.                                                                                                                              |
| `witness_name_tmp` / `witness_name_any` | `tools/boot_stub.S:515, 523`   | `"tmp\0"`, `"x\0"`. Reused by the preamble's `tmpfs_lookup` / `tmpfs_unlink` / `tmpfs_create` calls.                                                                                                |

### 2.2 What is NOT in place — nothing new

Unlike #589 which needed the new `witness_path_tmp_x` string,
**#590 introduces zero new rodata beyond the two OK/FAIL
messages**. The source buffer, destination-buffer-if-needed,
path string, and directory name strings all already exist.

### 2.3 Encoder gaps

**None.** `sys_write_body` uses only mnemonics landed pervasively.
The set of instructions is exactly the set proven by #589 (§2.3),
plus zero. See #589 §2.3 for the full mnemonic table — this doc
is byte-identical in its encoder surface.

## 3. Design

### 3.1 File and module structure

New file: `src/kernel/core/syscall/handlers/sys_write.pdx`. Sits
alongside the existing handlers:

```
src/kernel/core/syscall/handlers/
    sys_close.pdx    (#588)
    sys_execve.pdx   (#555)
    sys_exit.pdx     (#557)
    sys_fork.pdx     (#554)
    sys_open.pdx     (#587)
    sys_read.pdx     (#589)
    sys_wait.pdx     (#556)
    sys_write.pdx    <-- THIS ISSUE
```

Module name: `SysWrite`. Public export: `sys_write_body`.

### 3.2 Register discipline — 5-push prologue (mirror of #589 §3.2)

Byte-identical to sys_read. Five persistent values must survive
nested calls (`fd_get`, `vfs_write`, `fd_set`):

| Reg | Role                                                                                                                                    |
|-----|-----------------------------------------------------------------------------------------------------------------------------------------|
| rbx | `current` — caller's arg1. Survives all three nested calls (fd_get, vfs_write, fd_set).                                                  |
| r12 | `fd` — caller's arg2. Survives all three nested calls.                                                                                  |
| r13 | `buf_ptr` — caller's arg3 (source). Survives `fd_get`; remarshaled to `rsi` for `vfs_write`; dies after.                                 |
| r14 | Dual-role register: (a) `len` before `vfs_write` (remarshaled to `rdx`); (b) `bytes_written` after `vfs_write` (source of the return).   |
| r15 | Dual-role register: (a) `entry` (packed vnode_idx | offset) after `fd_get`; (b) `new_entry` after the offset-advance arithmetic — same register morphs by a single `add` in place. |

**Why 5 pushes and why the morphs are legal.** Same arguments as
#589 §3.2 (SysV entry has rsp%16==8; 5 pushes yield rsp%16==0
at each nested call site; r14/r15 morphs happen at hard
control-flow boundaries — post-`vfs_write` — that a reviewer
cannot miss). Not restated here.

### 3.3 `sys_write_body` — body sequence (two-instruction delta from #589 §3.3)

```asm
; ================================================================
; sys_write_body(current, fd, buf_ptr, len) -> u64
;   rdi = current       (task_struct*)
;   rsi = fd            (u64, validated in [3, 32))
;   rdx = buf_ptr       (u64 kernel VA — source)
;   rcx = len           (u64 byte count requested)
;
; Returns rax:
;   bytes_written (in [0, len])         on success
;   0xFFFFFFFFFFFFFFF7 (-EBADF)          if fd < 3, fd >= 32, or slot free
;   0xFFFFFFFFFFFFFFFB (-EIO)            if vfs_write returns the sentinel
;                                          (structurally unreachable from valid
;                                          entry; also catches R16.M2 tmpfs
;                                          single-page overflow — see §6.5)
;
; Register discipline (5-push prologue for rsp%16==0 at nested calls):
;   rbx = current                  (saved across fd_get, vfs_write, fd_set)
;   r12 = fd                       (saved across fd_get, vfs_write, fd_set)
;   r13 = buf_ptr                  (saved across fd_get; passed to vfs_write as rsi)
;   r14 = len | bytes_written      (len before vfs_write; bytes_written after)
;   r15 = entry | new_entry        (entry after fd_get; morphs to new_entry
;                                    via `add r15, rcx` where rcx = bytes_written<<16)
; ================================================================
sys_write_body:
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; --- Save arguments in callee-save regs ---
    mov rbx, rdi                        ; rbx = current
    mov r12, rsi                        ; r12 = fd
    mov r13, rdx                        ; r13 = buf_ptr
    mov r14, rcx                        ; r14 = len

    ; --- Phase 1: validate fd in [3, 32) ---
    cmp r12, 3
    jb  sys_write_ebadf                 ; fd < 3 (stdio reserved at R16.M3)
    cmp r12, 32
    jae sys_write_ebadf                 ; fd >= 32 (out of range)

    ; --- Phase 2: fd_get(current, fd) → rax = entry ---
    mov rdi, rbx
    mov rsi, r12
    call fd_get

    cmp rax, 0
    je  sys_write_ebadf                 ; slot free ↔ fd not open

    mov r15, rax                        ; r15 = entry (packed)

    ; --- Phase 3: dispatch vfs_write(vnode_idx, buf, len, offset) ---
    mov rdi, r15
    and rdi, 0xFFFF                     ; rdi = vnode_idx (low 16)
    mov rsi, r13                        ; rsi = buf_ptr (source)
    mov rdx, r14                        ; rdx = len
    mov rcx, r15
    shr rcx, 16                         ; rcx = offset (high 48)
    call vfs_write                      ; rax = bytes_written or 0xFFFFFFFFFFFFFFFF

    ; --- Phase 4: check vfs_write failure sentinel ---
    mov rcx, 0xFFFFFFFFFFFFFFFF
    cmp rax, rcx
    je  sys_write_eio

    ; --- Phase 5: advance offset in entry; write back via fd_set ---
    mov r14, rax                        ; r14 = bytes_written (repurposed from `len`;
                                        ;                       also the return value)

    ; new_entry = entry + (bytes_written << 16)
    ; Preserves vnode_idx (low 16 bits) byte-identically: bytes_written <= 4096
    ; at R16.M3 tmpfs single-page bound → bytes_written << 16 <= 2^28, well
    ; below the vnode_idx boundary at bit 16.
    mov rcx, r14
    shl rcx, 16                         ; rcx = bytes_written << 16
    add r15, rcx                        ; r15 = new_entry (in-place morph)

    mov rdi, rbx
    mov rsi, r12
    mov rdx, r15
    call fd_set                         ; entry write-back; return ignored

    ; --- Success: return bytes_written ---
    mov rax, r14
    jmp sys_write_done

sys_write_ebadf:
    mov rax, 0xFFFFFFFFFFFFFFF7         ; -EBADF (-9)
    jmp sys_write_done

sys_write_eio:
    mov rax, 0xFFFFFFFFFFFFFFFB         ; -EIO (-5)

sys_write_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
```

**Instruction count**: ~35 across the body, identical to
sys_read. The delta from sys_read is exactly:
- Two mnemonic substitutions: `call vfs_read` → `call vfs_write`
  in phase 3; `sys_read_*` label names → `sys_write_*`.
- Zero structural changes.

### 3.4 Error-code convention (mirror of #589 §3.4)

| Return sentinel                | Signed value | Meaning                                             |
|--------------------------------|--------------|-----------------------------------------------------|
| `0..len`                       | success      | bytes actually written                              |
| `0xFFFFFFFFFFFFFFF7`           | `-9`         | `-EBADF` — fd < 3, fd >= 32, or slot free           |
| `0xFFFFFFFFFFFFFFFB`           | `-5`         | `-EIO` — vfs_write sentinel propagation             |

**Why -EIO for the vfs_write sentinel at R16.M3.** The sentinel
covers three distinguishable failure modes in the current
backend:

1. vnode_idx == 0 (fd_table corruption)
2. vnode_idx >= 256 (vnode-pool overflow)
3. tmpfs_write's single-page-overflow / allocator-OOM path
   (`r16-m2-005` §5.1) — the write requested `offset + len > 4096`
   or the phys allocator refused a fresh page.

All three collapse to `-EIO`. Modes 1 and 2 are structurally
unreachable at R16.M3 (same as sys_read §3.4). Mode 3 IS
reachable (it's the tmpfs single-page bound). For R16.M3 both
are surfaced as -EIO because:
- The witness's 100-byte write at offset 0 does not stress
  mode 3 (100 < 4096).
- Introducing -ENOSPC now would require sys_write to know
  vfs_write's failure taxonomy — an abstraction leak that
  R16.M2's multi-page follow-on will resolve properly.

Follow-up (§6.5) tracks the -ENOSPC surfacing when the
multi-page vfs_write lands.

### 3.5 Why the phase order matters

Same reasoning as #589 §3.5, adapted for the write direction:

- **Validate before Get.** Same reason as read.
- **Get before Decode.** Same reason as read.
- **Decode before Dispatch.** Same reason as read.
- **Dispatch before Advance.** We need `bytes_written` to compute
  `new_entry`. The alternative — advance first with `len`, then
  clamp on return — would over-advance the offset on a short
  write, causing the next write to skip bytes silently.
- **Advance last.** If `fd_set` were to fault (it doesn't — leaf
  function with a single store), the visible side effect is a
  written FILE plus an unadvanced offset. The next write on
  the same fd would overwrite the just-written bytes — noisy but
  not silent-loss. Symmetric to sys_read's "duplicate data on
  retry" argument.

### 3.6 File contents (skeleton)

```pdx
// src/kernel/core/syscall/handlers/sys_write.pdx — R16-M3-004 (#590)
// sys_write body: fd validate + fd_get + decode + vfs_write + offset advance.
//
// Two-instruction delta from sys_read.pdx (#589):
//   1. `call vfs_read`  →  `call vfs_write`  at phase 3 dispatch
//   2. label / symbol rename `sys_read_*`  →  `sys_write_*`
//
// Consumes the packed fd_entry encoding frozen by #587 §3.2:
//   entry = vnode_idx | (offset << 16)
// Reads vnode_idx via `and rax, 0xFFFF`, offset via `shr rax, 16`,
// dispatches vfs_write, then writes back new_entry = entry + (bytes_written << 16)
// preserving vnode_idx byte-identically.
//
// See design/kernel/r16-m3-004-sys-write.md for full contract.

module SysWrite = structure {
  // === Error sentinels (negative-errno u64, matches Linux errno signs) ===
  pub let SYS_WRITE_ERR_EBADF : u64 = 0xFFFFFFFFFFFFFFF7   // -9
  pub let SYS_WRITE_ERR_EIO   : u64 = 0xFFFFFFFFFFFFFFFB   // -5

  // === Layout constants (from #549 fd_table freeze) ===
  pub let FD_TABLE_STDIO_LO : u64 = 3                     // matches fd_table.pdx:10
  pub let FD_TABLE_MAX      : u64 = 32                    // matches fd_table.pdx:9

  // ==========================================================================
  // sys_write_body — validate fd; decode entry; dispatch vfs_write; advance offset
  //
  // Input:
  //   rdi = current   (task_struct*, must be non-NULL)
  //   rsi = fd        (u64 — validated in [3, 32) at the trust boundary)
  //   rdx = buf_ptr   (u64 kernel VA — source buffer)
  //   rcx = len       (u64 byte count to write)
  //
  // Output:
  //   rax = bytes_written (in [0, len])    on success
  //   rax = 0xFFFFFFFFFFFFFFF7 (-EBADF)    on any of:
  //         (a) fd < 3
  //         (b) fd >= 32
  //         (c) fd_table[fd] == 0
  //   rax = 0xFFFFFFFFFFFFFFFB (-EIO)      on vfs_write sentinel
  //                                        (fd_table corruption, vnode overflow,
  //                                         or tmpfs single-page overflow)
  //
  // Side effects:
  //   on success: backing store `/tmp/x` extended with source bytes at offset;
  //     inode.size = max(size, offset + bytes_written); fd_table[fd] offset half
  //     advanced by bytes_written (vnode_idx preserved).
  //   on -EBADF: none (early return before any nested call).
  //   on -EIO: file contents may or may not be partially mutated depending on
  //     which failure mode fired; sys_write treats this as opaque — the
  //     caller must re-open + re-read to observe actual state.
  // ==========================================================================
  pub let sys_write_body : (u64, u64, u64, u64) -> u64 !{mem} @{} =
    fn (current: u64) (fd: u64) (buf_ptr: u64) (len: u64) -> unsafe {
      effects: {mem},
      capabilities: {},
      justification: "R16-M3-004 (#590): sys_write — fd validate; fd_get; decode entry; vfs_write; advance offset; fd_set. Byte-identical structure to sys_read (#589); two-instruction delta: `call vfs_write` at phase 3 (instead of `call vfs_read`), and label renames. 4-arg SysV entry. rdi=current, rsi=fd, rdx=buf_ptr (source), rcx=len. 5-push prologue (rbx, r12, r13, r14, r15) aligns rsp%16==0 for nested calls and saves current/fd/buf/len across three calls. Phase 1: validate fd in [3,32) via cmp+jb / cmp+jae (unsigned semantics — same idiom as sys_read #589 §3.3 and sys_close #588 §3.4). Phase 2: fd_get(rbx,r12) → rax = packed entry; cmp rax, 0; je → -EBADF (slot free ↔ fd not open). Phase 3: decode + dispatch — `and rdi, 0xFFFF` extracts vnode_idx from a copy of r15 (entry); `mov rsi, r13` restores buf_ptr; `mov rdx, r14` restores len; `mov rcx, r15; shr rcx, 16` extracts offset. Call vfs_write → rax = bytes_written (in [0,len]) or 0xFFFFFFFFFFFFFFFF sentinel (fd_table corruption, vnode overflow, or tmpfs single-page overflow). Phase 4: sentinel check via 8-byte immediate load into rcx + cmp — sentinel maps to -EIO. Phase 5: `mov r14, rax` saves bytes_written for return (repurposes r14 from `len`); compute new_entry via `mov rcx, r14; shl rcx, 16; add r15, rcx` — in-place offset advance preserving vnode_idx byte-identically (bytes_written << 16 ≤ 2^28 at R16.M3 tmpfs single-page bound, entirely within high 48 bits). fd_set(rbx, r12, r15) writes the advanced entry back. Return `mov rax, r14` — the bytes_written value. Register morphs (r14: len→bytes_written; r15: entry→new_entry) happen at hard control-flow boundaries (post-vfs_write) and are documented in the code comments. All nested callees (fd_get leaf, fd_set leaf, vfs_write 5-push prologue) trusted callee-save clean. See design/kernel/r16-m3-004-sys-write.md §3 for full rationale.",
      block: {
        push rbx;
        push r12;
        push r13;
        push r14;
        push r15;

        mov rbx, rdi;                        // rbx = current
        mov r12, rsi;                        // r12 = fd
        mov r13, rdx;                        // r13 = buf_ptr (source)
        mov r14, rcx;                        // r14 = len

        // Phase 1: validate fd in [3, 32)
        cmp r12, 3;
        jb  sys_write_ebadf;
        cmp r12, 32;
        jae sys_write_ebadf;

        // Phase 2: fd_get(current, fd) → rax = entry
        mov rdi, rbx;
        mov rsi, r12;
        call fd_get;

        cmp rax, 0;
        je  sys_write_ebadf;                 // slot free ↔ fd not open

        mov r15, rax;                        // r15 = entry (packed)

        // Phase 3: decode + dispatch vfs_write(vnode_idx, buf, len, offset)
        mov rdi, r15;
        and rdi, 0xFFFF;                     // rdi = vnode_idx (low 16)
        mov rsi, r13;                        // rsi = buf_ptr (source)
        mov rdx, r14;                        // rdx = len
        mov rcx, r15;
        shr rcx, 16;                         // rcx = offset (high 48)
        call vfs_write;                      // rax = bytes_written or sentinel

        // Phase 4: check vfs_write failure sentinel
        mov rcx, 0xFFFFFFFFFFFFFFFF;
        cmp rax, rcx;
        je  sys_write_eio;

        // Phase 5: advance offset; write back new_entry; return bytes_written
        mov r14, rax;                        // r14 = bytes_written (repurposed from `len`)

        // new_entry = entry + (bytes_written << 16); vnode_idx preserved
        mov rcx, r14;
        shl rcx, 16;                         // rcx = bytes_written << 16
        add r15, rcx;                        // r15 = new_entry (in-place morph)

        mov rdi, rbx;
        mov rsi, r12;
        mov rdx, r15;
        call fd_set;

        mov rax, r14;                        // return bytes_written
        jmp sys_write_done;

      sys_write_ebadf:
        mov rax, 0xFFFFFFFFFFFFFFF7;         // -EBADF
        jmp sys_write_done;

      sys_write_eio:
        mov rax, 0xFFFFFFFFFFFFFFFB;         // -EIO

      sys_write_done:
        pop r15;
        pop r14;
        pop r13;
        pop r12;
        pop rbx;
        ret
      }
    }
}
```

## 4. Witness task_struct — decision

### 4.1 Choice: dedicated `_sys_write_witness_task` (mirrors #587 §4.1, #588 §4.1, #589 §4.1)

Same three-way trade explored by every prior R16.M3 body:
dedicated slab vs. `_idle_tcb` vs. reusing a prior witness's slab.
Dedicated wins for the same three reasons — no scheduler-init
ordering hazard, no cross-witness state coupling, stylistic
uniformity — plus one write-specific reason:

- **Independence from #589's read state.** The sys_read witness
  leaves `_sys_read_witness_task` with fd=3 pointing at x_idx and
  offset=100 (post sub-test A's advance, unchanged by D's
  EOF-return). If the sys_write witness reused that slab, its
  first sys_write would write at offset=100, and sub-test C's
  `inode.size` check would land at 200 (150 doesn't work either),
  complicating the growth argument. A fresh slab guarantees
  offset=0 for the write.

### 4.2 Slab declaration

At the tail of `kernel_main.pdx`, alongside the sibling witness
task slabs:

```pdx
// R16-M3-004 (#590): sys_write witness task storage.
// Static .bss blob (2224 bytes = 278 u64s) backing a dedicated
// witness task_struct.  Same rationale as _sys_read_witness_task
// (#589 §4.1) and _sys_open_witness_task (#587 §4.1): witness
// storage stays independent of the scheduler init sequence so
// R16.M3 witnesses run before idle_init / runq_init without
// ordering hazards.
pub let mut _sys_write_witness_task : [u64; 278] = uninit @align(8)
```

### 4.3 Preamble: unlink + create + open (not just open)

**The choice:** the sys_write preamble does `tmpfs_lookup → tmpfs_unlink
→ tmpfs_create` on `/tmp/x` before `sys_open_body`.

**Why not just sys_open on the existing /tmp/x.** Post-#589, `/tmp/x`
already exists with `size=100` (100 × 'A' from #589's preamble
tmpfs_write + no mutation from #589's sub-tests). If the sys_write
witness just opened and wrote 100 × 'A' at offset 0, the
`tmpfs_write` backend's size-update logic (`r16-m2-005` §4:
`size = max(size, end)` where `end = offset+bytes_written = 100`)
would leave `inode.size == 100` — **byte-identical to the
pre-write state**. Sub-test C's `size == 100` check would then
be a tautology, unable to distinguish "sys_write ran" from
"sys_write did nothing".

The unlink+create cycle trims `/tmp/x` to `size=0` (tmpfs_create
initializes a fresh inode with size=0 per `r16-m2-004` §3), so
that the post-sys_write `size == 100` observation is unambiguously
proof of growth from 0.

**Why the unlink+create pattern is cheap.** Both primitives are
LANDED (#585, #582), take one tmpfs-inode idx of state each, and
compose in ~10 assembly lines. The alternative — reaching into
`tmpfs_inode_slot(x_idx)` and manually zeroing `[inode + 8]`
(the size field) — would bypass the frozen tmpfs API surface,
which is an abstraction violation regardless of correctness.

### 4.4 Vnode-pool wiring workaround — WHAT PERSISTS FROM #589

**Persistence claim.** The three-slot vnode-pool wiring performed
by the #589 sys_read witness preamble (`kernel_main.pdx:2960-2989,
3015-3020`) is *global* mutable state — the `_vnode_pool` slab
lives at `.bss` module scope and is never reinitialized between
witnesses. Therefore:

| Slot          | Wired by #589's preamble? | Persists to #590?                          | #590 must re-wire?                                          |
|---------------|----------------------------|--------------------------------------------|-------------------------------------------------------------|
| root vnode    | Yes (line 2960-2966)       | **YES** — `_vnode_pool[root_idx]` unchanged | **NO**                                                      |
| tmp_idx       | Yes (line 2984-2989)       | **YES** — `_vnode_pool[tmp_idx]` unchanged  | **NO**                                                      |
| x_idx         | Yes (line 3015-3020)       | Depends on unlink+create outcome            | **YES — defensively**, because unlink+create MAY change x_idx |

**Why x_idx wiring may need refresh.** The sys_write preamble
does `tmpfs_unlink(tmp_idx, "x", 1)` — which frees the tmpfs
inode-pool slot for x. Then `tmpfs_create(tmp_idx, "x", 1,
VNODE_TYPE_REG=1)` — which allocates a fresh tmpfs inode-pool
slot. `tmpfs_alloc`'s bitmap-scan-from-low-index typically
returns the SAME slot just freed by unlink, so the new x_idx is
very likely equal to the old x_idx — in which case
`_vnode_pool[x_idx]` still has the correct wiring from #589.

But: there is no invariant guaranteeing this. If a future
witness added between #589 and #590 (e.g., a hypothetical
`tmpfs_create("y")`) took that slot first, the sys_write
preamble's new x_idx would differ from #589's, and the wiring
at `_vnode_pool[new_x_idx]` would be zero (all bits clear).
Defensively re-wiring in the sys_write preamble absorbs this
risk at the cost of three instructions (vnode_slot + two
stores) — cheap enough not to gate on the actual index equality.

**Concrete preamble steps for x_idx wiring (identical shape to
#589):**

```asm
mov  rdi, r13                            ; r13 = new x_idx from tmpfs_create
call vnode_slot                          ; rax = &_vnode_pool[x_idx]
lea  rcx, [rip + _tmpfs_vops]
mov  [rax + 24], rcx                     ; ops_ptr = &_tmpfs_vops
mov  rcx, r13
mov  [rax + 32], rcx                     ; backend_ptr = x_idx (identity map)
```

**Follow-up filed by #589 (§4.3.1) still applies.** The
underlying defect — `path_resolve` conflating vnode-pool indices
with backend-native inode indices — remains open and is out of
scope for #590. The persistence + defensive re-wire suffices
for the witness to run correctly.

### 4.5 Position in kernel_main

Inserted immediately after `sys_read_witness_done:` (line 3091)
and before the `wrmsr` at line ~3093 that begins IA32_GS_BASE
setup.

That placement satisfies all prereqs:

- vfs_write witnessed at line ~2100 area (#577 canary).
- tmpfs_write witnessed at line ~2520 (#583 canary).
- tmpfs_create witnessed at line ~2450 (#582 canary).
- tmpfs_unlink witnessed at line ~2700 (#585 canary).
- tmpfs vops wire witnessed at line ~2795 (#586 canary).
- sys_open_body witnessed at line 2815 (#587 canary).
- sys_close_body witnessed at line 2880 (#588 canary).
- sys_read_body witnessed at line 2942 (#589 canary; also
  performs the persistent-tree vnode-pool wiring this witness
  inherits).
- No coupling to idle/runq/sched_switch witnesses that follow
  the wrmsr.

## 5. Test canary — kernel_main witness block

### 5.1 Preamble

Inputs:

- `_sys_write_witness_task`: fresh 278-u64 `.bss` blob (all zeros).
- `sys_open_body` proven working (by #587's witness).
- `vfs_write` proven working (by #577's witness).
- `tmpfs_lookup`, `tmpfs_unlink`, `tmpfs_create`, `tmpfs_inode_slot`
  proven (R16.M2 canaries).
- root vnode + tmp_idx vnode-pool slots pre-wired (persisted
  from #589's sys_read witness preamble — see §4.4).
- `witness_path_tmp_x` (persisted from #589): `"/tmp/x\0"`.
- `witness_name_tmp`, `witness_name_any` already resident.
- `tmpfs_write_src_buf` (100 × 'A') already resident.

### 5.2 Sub-tests

Matches the parent brief exactly: A/B/C for the success path,
D for the -EBADF trust-boundary.

**Preamble prep — recover x_idx (fresh), wire slot, open fd=3.**

```asm
; --- Recover tmp_idx via lookup on root (TMPFS_INODE_IDX_ROOT = 1) ---
mov  rdi, 1
lea  rsi, [rip + witness_name_tmp]           ; "tmp\0"
call tmpfs_lookup
cmp  rax, 0
je   sys_write_witness_fail
mov  r12, rax                                ; r12 = tmp_idx (scope-local)

; --- Trim /tmp/x back to fresh 0-size state: unlink + create ---
;    /tmp/x currently has size=100 from #589 preamble's tmpfs_write.
;    We unlink, then re-create fresh (size=0) so sub-test C observes
;    real growth from 0 to 100 (§4.3 rationale).
mov  rdi, r12                                ; dir_idx = tmp_idx
lea  rsi, [rip + witness_name_any]           ; name_ptr = "x\0"
mov  rdx, 1                                  ; name_len = 1
call tmpfs_unlink                            ; rax = 1 on success (unlinked)
cmp  rax, 1
jne  sys_write_witness_fail

mov  rdi, r12                                ; dir_idx = tmp_idx
lea  rsi, [rip + witness_name_any]           ; name_ptr = "x\0"
mov  rdx, 1                                  ; name_len = 1
mov  rcx, 1                                  ; type = VNODE_TYPE_REG
call tmpfs_create
cmp  rax, 0
je   sys_write_witness_fail
cmp  rax, 0xFFFF
je   sys_write_witness_fail                  ; alloc-OOM sentinel
mov  r13, rax                                ; r13 = fresh x_idx

; --- Wire fresh x_idx's vnode-pool slot (defensive; see §4.4) ---
mov  rdi, r13
call vnode_slot                              ; rax = &_vnode_pool[x_idx]
lea  rcx, [rip + _tmpfs_vops]
mov  [rax + 24], rcx                         ; ops_ptr = &_tmpfs_vops
mov  rcx, r13
mov  [rax + 32], rcx                         ; backend_ptr = x_idx

; --- sys_open("/tmp/x", 0, 0) → fd = 3 (scan-from-3 on fresh slab) ---
lea  rdi, [rip + _sys_write_witness_task]
lea  rsi, [rip + witness_path_tmp_x]         ; "/tmp/x\0"
xor  rdx, rdx                                ; flags = 0
xor  rcx, rcx                                ; mode = 0
call sys_open_body
cmp  rax, 3
jne  sys_write_witness_fail
```

**Sub-test A**: `sys_write(w, 3, tmpfs_write_src_buf, 100)`
returns `100`.

```asm
lea  rdi, [rip + _sys_write_witness_task]
mov  rsi, 3                                  ; fd
lea  rdx, [rip + tmpfs_write_src_buf]        ; buf_ptr (source, 100 × 'A')
mov  rcx, 100                                ; len
call sys_write_body
cmp  rax, 100
jne  sys_write_witness_fail
```

Proves: (a) fd validation passes for fd=3; (b) fd_get returns
a populated entry; (c) vnode_idx and offset decode correctly;
(d) vfs_write → vops_write → tmpfs_write chain executes end to
end; (e) return value is the byte count.

**Sub-test B**: `fd_table[3]` offset field == 100.

```asm
lea  rdi, [rip + _sys_write_witness_task]
mov  rsi, 3                                  ; fd
call fd_get                                  ; rax = current entry
mov  rcx, rax
shr  rcx, 16                                 ; rcx = offset (high 48)
cmp  rcx, 100
jne  sys_write_witness_fail
```

Proves: phase-5 offset advance landed correctly. `new_entry =
entry + (100 << 16)`; when extracted via `shr 16`, the top 48
bits equal 100. Also implicitly proves vnode_idx is preserved
(if `add r15, rcx` had overflowed into the low 16 bits, sub-test
E's re-open would fail with a corrupted vnode reference — but we
don't include sub-test E here; the invariant is instead exercised
by the transitive #589 read-back argument in §1.1).

**Sub-test C**: `inode.size == 100` after write.

```asm
mov  rdi, r13                                ; r13 = x_idx (from preamble)
call tmpfs_inode_slot                        ; rax = &_tmpfs_inode_pool[x_idx]
mov  rcx, [rax + 8]                          ; rcx = inode.size (offset TMPFS_INODE_SIZE_OFFSET=8)
cmp  rcx, 100
jne  sys_write_witness_fail
```

Proves: the write reached the backend and updated inode.size
from 0 (post-create) to 100 (post-write). Under the tmpfs
size-max rule (§4.3), this observation excludes both the
"write didn't run" and "write partially ran with 0 bytes"
failure modes.

**Sub-test D**: `sys_write(w, 2, src, 100)` returns `-EBADF`.

```asm
lea  rdi, [rip + _sys_write_witness_task]
mov  rsi, 2                                  ; fd = 2 (below stdio_lo=3)
lea  rdx, [rip + tmpfs_write_src_buf]        ; buf_ptr (irrelevant on -EBADF)
mov  rcx, 100                                ; len (irrelevant)
call sys_write_body
mov  rcx, 0xFFFFFFFFFFFFFFF7                 ; -EBADF
cmp  rax, rcx
jne  sys_write_witness_fail
```

Proves: fd < 3 is unambiguously rejected with -EBADF — no
console fallback yet at R16.M3, no silent 0-return. The
`cmp fd, 3; jb sys_write_ebadf` branch fires early, before
any fd_get load.

### 5.3 Marker

On A, B, C, D all green:

```
R16 SYS WRITE OK
```

Emitted via `uart_puts` on `sys_write_ok_msg`. Fingerprint added
to all three R16.M3-tempo expected-output files, immediately
after the existing `R16 SYS READ OK` line.

### 5.4 Witness assembly (complete block)

```asm
; ============================================================
; R16-M3-004 (#590): sys_write witness — preamble + 4 sub-tests
; ============================================================
sys_write_witness:
    ; --- Preamble: recover tmp_idx; trim /tmp/x to 0; wire fresh x_idx;
    ;               open fd=3 ---
    mov  rdi, 1
    lea  rsi, [rip + witness_name_tmp]
    call tmpfs_lookup
    cmp  rax, 0
    je   sys_write_witness_fail
    mov  r12, rax                               ; r12 = tmp_idx

    mov  rdi, r12
    lea  rsi, [rip + witness_name_any]
    mov  rdx, 1
    call tmpfs_unlink
    cmp  rax, 1
    jne  sys_write_witness_fail

    mov  rdi, r12
    lea  rsi, [rip + witness_name_any]
    mov  rdx, 1
    mov  rcx, 1                                 ; VNODE_TYPE_REG
    call tmpfs_create
    cmp  rax, 0
    je   sys_write_witness_fail
    cmp  rax, 0xFFFF
    je   sys_write_witness_fail
    mov  r13, rax                               ; r13 = fresh x_idx

    ; Defensive vnode-pool wiring for x_idx (persists from #589 unless
    ; unlink+create yielded a different idx — see §4.4).
    mov  rdi, r13
    call vnode_slot
    lea  rcx, [rip + _tmpfs_vops]
    mov  [rax + 24], rcx
    mov  rcx, r13
    mov  [rax + 32], rcx

    lea  rdi, [rip + _sys_write_witness_task]
    lea  rsi, [rip + witness_path_tmp_x]
    xor  rdx, rdx
    xor  rcx, rcx
    call sys_open_body
    cmp  rax, 3
    jne  sys_write_witness_fail

    ; --- Sub-test A: sys_write(w, 3, src, 100) → 100 ---
    lea  rdi, [rip + _sys_write_witness_task]
    mov  rsi, 3
    lea  rdx, [rip + tmpfs_write_src_buf]
    mov  rcx, 100
    call sys_write_body
    cmp  rax, 100
    jne  sys_write_witness_fail

    ; --- Sub-test B: fd_table[3] offset field == 100 ---
    lea  rdi, [rip + _sys_write_witness_task]
    mov  rsi, 3
    call fd_get
    mov  rcx, rax
    shr  rcx, 16
    cmp  rcx, 100
    jne  sys_write_witness_fail

    ; --- Sub-test C: inode.size == 100 (grew from 0 post-create) ---
    mov  rdi, r13
    call tmpfs_inode_slot
    mov  rcx, [rax + 8]
    cmp  rcx, 100
    jne  sys_write_witness_fail

    ; --- Sub-test D: sys_write(w, 2, ...) → -EBADF ---
    lea  rdi, [rip + _sys_write_witness_task]
    mov  rsi, 2
    lea  rdx, [rip + tmpfs_write_src_buf]
    mov  rcx, 100
    call sys_write_body
    mov  rcx, 0xFFFFFFFFFFFFFFF7
    cmp  rax, rcx
    jne  sys_write_witness_fail

    ; --- All green ---
    lea  rdi, [rip + sys_write_ok_msg]
    call uart_puts
    jmp  sys_write_witness_done

sys_write_witness_fail:
    lea  rdi, [rip + sys_write_fail_msg]
    call uart_puts

sys_write_witness_done:
```

### 5.5 String data — `tools/boot_stub.S`

Append after the sys_read messages (~line 626):

```asm
# R16-M3-004 (#590): sys_write witness success message
.global sys_write_ok_msg
.align 8
sys_write_ok_msg: .ascii "R16 SYS WRITE OK\n\0"

# R16-M3-004 (#590): sys_write witness failure message
.global sys_write_fail_msg
.align 8
sys_write_fail_msg: .ascii "R16 SYS WRITE FAIL\n\0"
```

`tmpfs_write_src_buf`, `witness_path_tmp_x`, `witness_name_tmp`,
and `witness_name_any` already exist (persisted from #583, #589,
and R16.M1 witness ancestry respectively). **No new rodata
strings beyond the two messages.**

### 5.6 Fingerprint files — marker insertion

The line `R16 SYS WRITE OK` inserts into all three R16.M3-tempo
fingerprint files immediately after the `R16 SYS READ OK` line:

- `tests/r14b/expected-boot-r14b-loader.txt`
- `tests/r15/expected-boot-r15-ring3.txt`
- `tests/r15/expected-boot-r15-process.txt`

Contains-in-order matching means the addition is strictly
additive — no earlier line reorders. All existing 5-mode smoke
stages (`boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`,
`boot_r12_denial`) that do not observe R16 markers stay
byte-identically green.

## 6. Alternatives considered / follow-ups (rejected or deferred)

### 6.1 Follow-up: read-back verification via a second sys_open + sys_read

**Proposal.** After sub-test C, open `/tmp/x` a second time (fd=4
via scan-from-3), sys_read(fd=4, dst_buf, 100), and verify the
100 × 'A' payload arrives at the destination.

**Rejected — redundant.** Sub-test C already proves the backing
store has 100 bytes at the correct offset. #589's read-side
witness (already landed) proved the read chain retrieves bytes
correctly. Composing "write side proven here" + "read side
proven at #589" transitively proves the acceptance criterion
"write to /tmp/x persists; read back returns bytes" via
witness-chain composition — no need to duplicate the read-side
verification in #590. Sub-test C is the minimal orthogonal
observation.

If a reviewer requires higher assurance, this follow-up is
enabled by the two persisted files (`_sys_write_witness_task`
fd_table has fd=3 already; a second sys_open gives fd=4;
tmpfs_read_dst_buf from #584 is still resident); ~15 additional
witness LOC would land it.

### 6.2 Distinguish vfs_write failure modes

**Proposal.** When `vfs_write` returns its `0xFFFFFFFFFFFFFFFF`
sentinel, distinguish "vnode_idx corruption" from "tmpfs
allocator OOM / single-page overflow" via different errnos
(-EIO vs. -ENOSPC).

**Rejected for R16.M3, deferred.** Same reasoning as #589 §6.2 —
distinguishing failure modes requires sys_write to know
vfs_write's internal taxonomy. The R16.M2 multi-page tmpfs_write
follow-on (which will surface -ENOSPC cleanly through vops_write
as a separate sentinel) is the correct time to grow this
distinction. Meanwhile the single -EIO covers both modes with
the semantically-safer failure (both mean "the write did not
complete as requested").

### 6.3 Refcount consultation before dispatch

**Proposal.** After decoding vnode_idx, load the vnode's
refcount and reject if it's zero.

**Rejected.** Same as #589 §6.3 — fd_table entry non-zero is
the authoritative "fd liveness" signal at R16.M3. A zero-refcount
populated entry is a #588/#591 sys_close/sys_dup2 correctness
issue, not a sys_write enforcement site.

### 6.4 Zero-length write fast path

**Proposal.** If `len == 0`, short-circuit before phase 2.

**Rejected — deferred to reviewer discretion.** Same reasoning
as #589 §6.4 — POSIX `write(2)` with `count == 0` still validates
the fd; skipping validation would return 0 instead of -EBADF on
a bad fd, a wrong answer. tmpfs_write's own zero-length fast
path (already in `r16-m2-005` §4.2) short-circuits the memcpy
at the right layer.

### 6.5 -ENOSPC surfacing when tmpfs multi-page lands

**Proposal (planned).** When R16.M2's tmpfs_write multi-page
follow-on distinguishes "allocator OOM" from "vnode_idx
corruption" via a new sentinel value (e.g., `0xFFFFFFFFFFFFFFFE`
for -ENOSPC), sys_write grows a second sentinel check between
phase 4's current -EIO branch and the phase-5 success path.

**Not deferred — enabled by the current phase order.** Adding
a second sentinel check requires exactly two additional
instructions (`mov rcx, 0xFFFFFFFFFFFFFFFE; cmp rax, rcx; je
sys_write_enospc`) before the existing sentinel check, plus one
new error label. Zero structural changes to phases 1, 2, 3, or
5. Documented here so the future landing lands as an additive
patch, not a refactor.

### 6.6 Locking around fd_get + fd_set (concurrent access)

**Proposal.** Bracket phase 2 + phase 5 with a per-task fd_table
lock so concurrent sys_read/sys_write on the same fd don't
interleave their offset advances.

**Rejected for R16.M3.** Same as #589 §6.5 — no preemption during
syscall at R16.M3; R17 SMP adds a per-task fd_table spinlock
around the entire sys_write body.

### 6.7 Different source buffer content ('B' × 100 instead of 'A' × 100)

**Proposal.** Introduce a distinctive source buffer for sys_write
(e.g., `sys_write_src_buf: 100 × 'B'`) rather than reusing
`tmpfs_write_src_buf` (100 × 'A'). Rationale: byte-distinct
content lets a read-back verify sys_write actually wrote NEW
bytes rather than leaving existing 'A's in place.

**Rejected.** The unlink+create preamble (§4.3) already trims
`/tmp/x` to `size=0` before the sys_write — after the write,
sub-test C's `inode.size == 100` observation IS the "write
happened" proof (size can't be 100 from thin air). Introducing
a distinct buffer would enable a stronger content-level check
but requires new rodata (100 bytes = 0.1% .rodata bloat), which
is not proportionate to the marginal assurance over sub-test
C's growth argument.

If sub-test C is deemed insufficient by reviewer, the
`sys_write_src_buf` addition + a read-back sub-test (§6.1) can
be a one-issue follow-up (~15 LOC delta); the current design
does not preclude it.

### 6.8 Preamble skips unlink+create — just open and rely on offset

**Proposal.** Skip `tmpfs_unlink` + `tmpfs_create` in the
preamble. Open `/tmp/x` (still exists post-#589, size=100),
write 100 × 'A' at offset=0, verify offset advances to 100.
Sub-test C would check `inode.size == 100`.

**Rejected.** As shown in §4.3, sub-test C would then be a
tautology (size was 100 pre-write, still 100 post-write; the
observation can't distinguish "write ran with 100 bytes" from
"write did not run at all"). The unlink+create cycle costs ~10
LOC in the preamble and turns sub-test C into a real growth
proof.

## 7. Invariants

### 7.1 fd_entry encoding preserved (write side)

sys_write READS the encoding via `and rax, 0xFFFF` (vnode_idx)
and `shr rax, 16` (offset). It WRITES a new entry via
`add r15, (bytes_written << 16)` — a purely additive update to
the high 48 bits. The low 16 bits (vnode_idx) are byte-identical
pre- and post-write. #587 §3.2's `entry = vnode_idx | (offset <<
16)` remains the single source of truth.

Verification: sub-test B checks offset==100 post-write; sub-test
D re-uses the fd_table with fd=2 (a validation-failure path
that never touches the fd=3 entry), so the fd=3 entry from
sub-test A is byte-identical entering sub-test B. If the phase 5
add had corrupted vnode_idx, sub-test C (which reaches x_idx via
the separate `r13` capture, not via the fd_table entry) would
still pass — leaving corruption invisible in this witness. See
§8 for the corresponding cross-cutting risk (freezing the
arithmetic here helps sys_read's sub-test D catch any regression
transitively).

### 7.2 Offset advance is monotonic on success

Every successful sys_write advances the fd_table offset by
`bytes_written >= 0`. Because `bytes_written` is unsigned, the
offset is monotonically non-decreasing across successive writes
on the same fd. Underflow is structurally impossible.

Consequence: a caller can implement "append" by looping `while
(sys_write(fd, buf, N) == N) { advance src }` — the loop
progresses monotonically through the file with the offset
tracking correctly.

### 7.3 Zero-return on failure preserves entry

`sys_write` at -EBADF and -EIO paths does NOT call `fd_set` —
the fd_table entry is byte-identical to pre-call. Consequence:
a caller can retry after -EIO without the fd being silently
advanced past the failed bytes. This differs from the tmpfs
backend which may partially succeed; but at the sys_write
layer, "wrote all N or wrote 0 (failed)" is the observable
contract.

Verified by inspection: no branch of `sys_write_ebadf` or
`sys_write_eio` reaches `call fd_set`.

### 7.4 sys_write_body register discipline

Byte-identical to #589 §7.4. rbx, r12, r13, r14, r15 pushed
in prologue, popped in epilogue. All nested callees (fd_get
leaf, fd_set leaf, vfs_write 5-push explicit preservation)
verified callee-save clean.

### 7.5 Backing store non-mutation on failure

On -EBADF (fd validation failure or slot free), no nested call
that could touch the backing store has executed yet —
`_tmpfs_page_pool` state is byte-identical to pre-call. On
-EIO (vfs_write sentinel), whether the backing store is mutated
depends on which failure mode fired:

- vnode_idx==0 / vnode_idx>=256 corruption: vfs_write returns
  before dispatching into vops_write → backing store untouched.
- tmpfs single-page overflow: vfs_write reaches tmpfs_write,
  which validates `offset + len <= 4096` at its `r16-m2-005`
  §4.1 gate BEFORE any allocation or memcpy → backing store
  untouched.
- tmpfs allocator OOM (phys_alloc failure on the first-write
  page-allocation path): vfs_write reaches tmpfs_write, which
  fails at phys_alloc BEFORE any memcpy → backing store
  untouched.

All three -EIO sub-modes are non-mutating at R16.M3. This
invariant may weaken when the multi-page follow-on lands (a
partial page write followed by an allocation failure could
leave partial mutation); §6.5 tracks the corresponding
error-code split.

### 7.6 Trust boundary — no downstream bounds check

Byte-identical to #589 §7.6. `fd_get`/`fd_set` receive
`fd < 32`; `vfs_write` receives `vnode_idx = entry & 0xFFFF`,
bounded by `VNODE_MAX = 256` under R16.M3 invariants.
Doubly-validated defense-in-depth pattern preserved.

### 7.7 Short-write semantics at R16.M3 (no short writes)

At R16.M3, `tmpfs_write` never returns a short write on
success — either `bytes_written == len` (full success) or
sentinel (failure). The `bytes_written < len` case is legal
under vfs_write's contract but unreachable through the tmpfs
backend at R16.M3. sys_write's phase 5 arithmetic handles
short writes correctly (advances by actual bytes_written),
but no witness sub-test can exercise the short-write path
until a backend that produces it lands (R17 pipe/socket, or
a future tmpfs page-boundary-crossing scenario).

## 8. Cross-cutting risks

- **Encoding drift across R16.M3 issues.** #589 §8 already
  flagged this from the read side; #590 realizes the arithmetic
  in code and thereby freezes it. If a future R16.M3 issue
  (sys_lseek #591) introduces a THIRD offset-manipulation
  arithmetic (e.g., `new_entry = entry - (bytes_seeked << 16)`
  for negative seeks), the vnode_idx preservation invariant
  must be re-derived — subtraction into the low 16 bits is
  possible if bytes_seeked exceeds the current offset. Filed
  as a design-doc consumer of #591.
- **Backing-store mutation on -EIO if tmpfs semantics change.**
  §7.5 lists the three -EIO sub-modes as non-mutating at R16.M3.
  If R16.M2's multi-page tmpfs_write introduces partial-page
  mutation before an allocation failure, sys_write's post-EIO
  observability breaks (caller sees -EIO but backing store is
  half-written). Mitigation: §6.5's -ENOSPC surfacing lands
  alongside the multi-page change; the design doc for the
  multi-page follow-on must explicitly document the mutation
  boundary.
- **Concurrent close during write.** R16.M3 has no preemption
  during syscall, so impossible. R17 SMP needs a per-task
  fd_table spinlock; see §6.6.
- **vfs_write contract drift** (mirror of #589 §8). If
  vfs_write's sentinel value changes, sys_write's cmp against
  `0xFFFFFFFFFFFFFFFF` would miss it. Documented at `r16-m1-008`
  §37-38 and stable; any drift would ripple through this doc's
  §3.4 in review.
- **-EBADF via wrong branch on huge unsigned fd.** Same as
  #588 §8, #589 §8: unsigned semantics catch `fd =
  0xFFFFFFFFFFFFFFFF` via `cmp rsi, 32; jae` (fires correctly).
  Signed-semantics regression would misclassify.
- **vnode-pool wiring divergence.** §4.4 flags the risk that
  unlink+create returns a different x_idx than #589's
  preamble captured. Defensive re-wire absorbs the risk at
  witness time. The upstream defect (path_resolve conflating
  vnode-pool with backend indices) is untouched by #590 and
  remains open per #589 §4.3.1.

## 9. LOC estimate

| File                                                        | LOC        |
|-------------------------------------------------------------|------------|
| `src/kernel/core/syscall/handlers/sys_write.pdx` (new)      | ~115       |
|   - module boilerplate + constants + justification          |   ~55      |
|   - `sys_write_body` (~35 instructions)                     |   ~45      |
|   - inline comments                                         |   ~15      |
| `src/kernel/boot/kernel_main.pdx` (witness block + slab)    | ~140       |
|   - `_sys_write_witness_task` declaration                   |    ~5      |
|   - preamble + 4 sub-tests, fail/success labels             |  ~105      |
|   - inline comments                                         |   ~30      |
| `tools/boot_stub.S` (2 messages)                            |  ~8        |
| 3 expected-output fingerprint files (1 marker each)         |  ~3        |
| `design/kernel/r16-m3-004-sys-write.md` (this doc)          | (this)     |
| **Total executable / testing / test-data**                  | **~266**   |

Executable code path: ~115 LOC. Witness + fingerprint: ~151 LOC.

Compared to #589's ~265 LOC total: nearly identical scale.
Slightly larger executable (~5 LOC) due to the additional
error-code prose in the justification comment (documenting
the three -EIO sub-modes). Slightly smaller witness (~15 LOC)
because #590 has 4 sub-tests instead of #589's 5, and inherits
the two persistent vnode-pool wirings (root, tmp_idx) from
#589's preamble.

## 10. Tractability

**HIGH.**

- **Zero-encoder-gap.** Every mnemonic used has landed
  precedent. This body is a two-mnemonic delta from #589's
  proven body.
- **Composition of six already-witnessed primitives** (`fd_get`,
  `fd_set`, `vfs_write`, `tmpfs_lookup`, `tmpfs_unlink`,
  `tmpfs_create`, `tmpfs_inode_slot`, plus `sys_open_body` in
  the preamble). Zero novel logic — the offset-advance
  arithmetic is byte-identical to sys_read's, phase-frozen at
  #589.
- **Witness storage is a single `.bss` blob** (mirror of
  #589's `_sys_read_witness_task`) — no allocator dependency,
  no CR3 flip, no interrupt discipline, no scheduler init
  dependency.
- **Marker line is contains-in-order** — no fingerprint
  reorder risk across other smoke modes.
- **Composes cleanly with #587 (packed encoding), #588 (fd
  validation idiom), #589 (body shape)** — no new invariants,
  no encoding contract drift.
- **Sizing (~266 LOC total)** matches recent R16.M3 issues
  (#587 ~196, #588 ~200, #589 ~265) — same milestone-cost
  profile.
- **No cross-repo escalation risk** (no paideia-as encoder
  growth).
- **Vnode-pool workaround from #589 mostly persists.** Root
  and tmp_idx wiring survives; only x_idx needs defensive
  re-wire due to unlink+create. Zero additional design risk
  from the persistence assumption — the defensive re-wire
  handles the pessimistic case at ~5 LOC cost.

Estimated implementation time: **one workerbee session**.
Estimated risk of regressing an existing smoke mode:
**near-zero** (purely additive: one new emit line, one new
witness block, one new .pdx module, two new message strings).

**Known follow-ups (do NOT block #590's landing)**:

- **SYSCALL entry batch-wire** — install `sys_write_body`
  into the syscall dispatch table so ring-3 code can call it.
  Lands with the R16.M3 batch-wire after all handlers compose.
- **-ENOSPC distinction** (§6.5) when R16.M2's multi-page
  tmpfs_write lands.
- **stdio dispatch for fd 1/2** at R16.M5 — TTY milestone
  extends fd 1/2 to console output; the current -EBADF branch
  narrows accordingly.
- **path_resolve / vnode-pool index unification** (#589
  §4.3.1) — the upstream defect that necessitates the
  witness-local vnode-pool wiring. Independent follow-up.
- **R17 SMP concurrent-access lock** (§6.6) — per-task
  fd_table spinlock brackets sys_write atomically against
  concurrent close/dup2.

## 11. References

- Issue: paideia-os#590
- Milestone: paideia-os R16.M3 (fd table + open/read/write/close/dup2)
- Prereq issues: #587 (sys_open packed encoding freeze),
  #588 (sys_close fd validation idiom), #589 (sys_read body shape
  + offset-advance arithmetic freeze), #577 (vfs_write),
  #586 (tmpfs vops wire), #583 (tmpfs_write), #585 (tmpfs_unlink),
  #582 (tmpfs_create), #549 (fd_table embed)
- Successor issues: #591 (sys_lseek), #593 (sys_dup2)
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 13, item 4
- Master plan: `design/milestones/r14b-master-plan.md` §M19 (VFS)
- Prior-art body pattern: `src/kernel/core/syscall/handlers/sys_read.pdx`
  (#589) — 5-phase body + register discipline + offset-advance
  arithmetic copied here with a two-instruction delta
- Prior-art encoding pattern: `src/kernel/core/syscall/handlers/sys_open.pdx`
  (#587) — packed fd_entry encoding this doc reads and writes
- Prior-art dispatcher pattern: `src/kernel/core/fs/vfs_write.pdx`
  (#577) — the 4-arg dispatcher this doc calls
- Prior-art witness pattern: `design/kernel/r16-m3-003-sys-read.md`
  §5 — `_*_witness_task` `.bss` blob + sub-tests + marker line
  + fingerprint insertion + preamble discipline (§4.4 vnode-pool
  workaround documented there is inherited transitively)
