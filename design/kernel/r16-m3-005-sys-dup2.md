---
issue: 591
milestone: R16.M3 (fd table + open/read/write/close/dup2)
subsystem: 13 — file-descriptor + open/read/write/close/dup2
topic: sys_dup2 — dual-fd validate; copy fd_table[src] to fd_table[dst] (closing dst first if open); increment shared-vnode refcount
prereq:
  - "#587 (sys_open — LANDED; freezes the packed fd_entry encoding this doc copies bit-for-bit)"
  - "#588 (sys_close — LANDED; freezes the fd validation idiom; also provides the `fd_get -> is_free?` idiom used to decide whether the dst slot needs a pre-close)"
  - "#589 (sys_read — LANDED; freezes the 5-push prologue this doc mirrors register-for-register)"
  - "#590 (sys_write — LANDED; freezes the pattern of a 4-arg / 3-arg body atop the shared prologue)"
  - "#576 (vfs_close — LANDED; called on the dst-slot's vnode when dst was previously open)"
  - "#549 (fd_table embed — LANDED; provides fd_get / fd_set / sentinel-0-means-free discipline)"
  - "#571 (vnode_pool + vnode_slot — LANDED; used inline to reach `_vnode_pool[shared_idx]` for the refcount++)"
blocks:
  - "#592 (fd inherit across fork — will reuse the `vnode_slot + inc-u16 @+4` refcount-hold idiom frozen here; when landed, both this issue's inline hold and vfs_open's inline hold should be factored into a shared `vnode_hold` helper — see §6.1)"
  - "R16.M3 batch-wire (SYSCALL entry table install) — sys_dup2_body is the last body slot the batch-wire will consume"
  - "R17 (userland shell demo — first ring-3 sys_dup2 caller for stdio redirection: `dup2(pipe_read_end, 0)`)"
touching:
  - src/kernel/core/syscall/handlers/sys_dup2.pdx          (new module — ~120 LOC incl. justification)
  - src/kernel/boot/kernel_main.pdx                        (witness block ~170 LOC + `_sys_dup2_witness_task` slab)
  - tools/boot_stub.S                                      (2 rodata additions: ok_msg, fail_msg — path + src_buf reused)
  - tests/r14b/expected-boot-r14b-loader.txt               (marker: `R16 SYS DUP2 OK`)
  - tests/r15/expected-boot-r15-ring3.txt                  (marker)
  - tests/r15/expected-boot-r15-process.txt                (marker)
  - design/kernel/r16-m3-005-sys-dup2.md                   (this doc)
related:
  - design/kernel/r16-m3-001-sys-open.md                   (#587 — packed fd_entry encoding
                                                            `entry = vnode_idx | (offset<<16)` consumed here via
                                                            `and rax, 0xFFFF` to reach vnode_idx for both the
                                                            optional pre-close and the refcount++; the entry
                                                            copy `fd_set(dst, src_entry)` is a byte-identical
                                                            duplication of the encoding — same vnode_idx,
                                                            same offset, semantic-perfect share)
  - design/kernel/r16-m3-002-sys-close.md                  (#588 — §3.4 fd-validation idiom used TWICE here
                                                            (src_fd and dst_fd); §7.3 doubly-validated pattern
                                                            applies to vfs_close(dst_vnode_idx) call
                                                            unchanged)
  - design/kernel/r16-m3-003-sys-read.md                   (#589 — 5-push prologue with rbx/r12/r13/r14/r15
                                                            proven register-legal for nested calls; sys_dup2
                                                            reuses the same 5-push prologue and morphs r14/r15
                                                            at hard control-flow boundaries)
  - design/kernel/r16-m3-004-sys-write.md                  (#590 — the sibling body preceding this one; frozen
                                                            the "add witness after the previous witness_done,
                                                            before the wrmsr" placement pattern)
  - design/kernel/r16-m1-007-vfs-close.md                  (#576 — the primitive called to release the old
                                                            dst-slot's vnode; §3 refcount-decrement contract
                                                            + on-zero vops_close dispatch)
  - design/kernel/r16-m1-006-vfs-open.md                   (#575 — the primitive whose inline refcount++
                                                            pattern (`mov_w rcx, [vnode+4]; inc rcx; mov_w
                                                            [vnode+4], rcx`) is duplicated here for the
                                                            share-side hold; factoring proposed in §6.1)
  - design/kernel/r15-m5-007-fd-table-embed.md             (#549 — fd_get / fd_set / sentinel-0 discipline)
  - design/milestones/r14b-tactical-plan.md                §Subsystem 13, item 5
---

# R16-M3-005 — `sys_dup2`: dual-fd validate; entry copy; conditional dst-close; shared-vnode hold (#591)

## 1. Scope

Land the R16.M3 subsystem-13 issue #591: the fd-duplication body. Full
body sequence is a **seven-phase composition** over the packed fd_entry
encoding frozen by #587 §3.2 and the fd-validation idiom frozen by #588
§3.4:

```
sys_dup2_body(current, src_fd, dst_fd) -> u64
    rdi = current      (task_struct*)
    rsi = src_fd       (u64 in [3, 32) — validated at the trust boundary)
    rdx = dst_fd       (u64 in [3, 32) — validated at the trust boundary)
    rax = dst_fd                        on success
    rax = 0xFFFFFFFFFFFFFFF7 (-EBADF)   on any of:
                                          (a) src_fd < 3   (stdio-reserved at R16.M3)
                                          (b) src_fd >= 32 (out of range)
                                          (c) dst_fd < 3   (stdio-reserved at R16.M3)
                                          (d) dst_fd >= 32 (out of range)
                                          (e) fd_table[src_fd] == 0 (src not open)
```

The seven phases:

1. **Validate `src_fd`** in `[3, 32)` — same idiom as `sys_close_body`
   phase 1 (#588 §3.4).
2. **Validate `dst_fd`** in `[3, 32)` — identical idiom applied to the
   second argument.
3. **Load** the packed `src_entry` via `fd_get(current, src_fd)`. A
   zero entry means the src slot is free → return `-EBADF`.
4. **POSIX no-op check.** If `src_fd == dst_fd`, return `dst_fd`
   immediately without touching state. This branch mirrors Linux
   `dup2(2)` semantics: "If oldfd is a valid file descriptor, and
   newfd has the same value as oldfd, then dup2() does nothing, and
   returns newfd." Validation of both fds and confirmation that
   src is open happens BEFORE this check — the no-op still requires
   src to be a valid open fd.
5. **Load** the packed `dst_entry` via `fd_get(current, dst_fd)`. If
   non-zero, extract its vnode_idx and call `vfs_close` — this
   decrements the old dst-vnode's refcount, releasing the fd's prior
   binding. Return value ignored (same discipline as #588 §3.4 phase
   3; every entry populated by an R16.M3-legal producer round-trips
   safely through vfs_close).
6. **Copy** the src entry to the dst slot: `fd_set(current, dst_fd,
   src_entry)`. Vnode_idx AND offset are copied byte-identically —
   both fds now reference the exact same file position (per Linux
   dup2 semantics: shared file description).
7. **Hold** the shared vnode: increment its refcount by 1 so that
   subsequent `sys_close` on either fd will only decrement — not
   free — the vnode. Inline pattern: `vnode_slot(vnode_idx)` + `mov_w
   rcx, [vnode+4]; inc rcx; mov_w [vnode+4], rcx`. Byte-identical to
   the inline hold at `vfs_open.pdx:122-130` (see §6.1 for the
   proposed follow-up factoring both call-sites into a shared
   `vnode_hold` helper).

Return `dst_fd` in rax.

### 1.1 What this issue proves

- **The packed fd_entry encoding survives a fd-slot copy.** Prior
  R16.M3 syscalls (#587-#590) each read the encoding, mutate one
  half (offset), and write back. #591 is the first syscall that
  copies the whole encoding across slots. Sub-test B verifies the
  packed u64 is byte-identical between `fd_table[src_fd]` and
  `fd_table[dst_fd]` after dup2 — proving no accidental
  offset-clobber or vnode_idx-remask happens in transit.
- **Refcount arithmetic composes cleanly with sys_close.** sys_open
  bumps refcount to 1; sys_dup2 bumps to 2; sys_close on either fd
  drops to 1 (still open); sys_close on the last fd drops to 0 and
  fires vops_close. Sub-test C observes refcount == 2 immediately
  after dup2 — proving the hold fired. The full lifecycle
  (`open → dup2 → close(src) → close(dst) → vops_close`) is
  transitively proven via #591's hold + #588's decrement.
- **The conditional-close-dst branch establishes the "close the
  slot before overwriting it" pattern.** POSIX dup2 requires that
  if `newfd` was open, its resource be released before the copy —
  otherwise the dup2 leaks the old vnode's refcount. Sub-test F
  verifies this: fd 4 opens `/` (root vnode refcount+1), then dup2
  targets fd 4 with fd 3's `/tmp/x` entry — the witness observes
  root vnode's refcount decremented back to its pre-open value.
- **The `-EBADF` error family propagates cleanly across two-fd
  syscalls.** Both `src_fd < 3 | >= 32` and `dst_fd < 3 | >= 32`
  return the same sign-extended u64 (`0xFFFFFFFFFFFFFFF7 == -9`)
  as single-fd syscalls (#588, #589, #590). Sub-test E actively
  exercises the src-out-of-range mode; the dst-out-of-range mode
  is proven by inspection (it's a byte-identical `cmp/jae` pair to
  the src validation).

### 1.2 What this issue deliberately does NOT do

- **No SYSCALL entry wiring.** Same rationale as #587-#590 —
  batch-wire after all five R16.M3 syscall bodies compose.
  `sys_dup2_body` is testable in kernel context via the witness (§5).
  This is the LAST body slot the R16.M3 batch-wire will consume,
  so the batch-wire issue (§6.2) can be filed immediately after
  #591 lands.
- **No `O_CLOEXEC` clearing.** Linux dup2 clears the FD_CLOEXEC
  flag on the new dst_fd (unlike dup3 which preserves it). The
  R15.M5-frozen fd_entry encoding does not yet carry a per-fd flags
  byte — the R17 24-byte widening (§6.4) will. At R16.M3 there is
  no flag to clear, so this behavior is vacuously correct.
- **No `sys_dup3` semantics.** POSIX dup3(2) is dup2 + a flags
  argument controlling FD_CLOEXEC. Blocked on the same fd_entry
  widening as O_CLOEXEC handling. Future R17 issue.
- **No `sys_dup` (one-arg).** POSIX dup(oldfd) allocates the lowest
  free fd. That's `fd_alloc + sys_dup2(oldfd, allocated_fd)` — a
  compact wrapper. Not in R16.M3 subsystem-13 scope; future R17
  addition (~10 LOC).
- **No `-EBUSY` for in-use dst_fd race.** R16.M3 is single-threaded;
  no other task can race with the dup2 body. When R17 preemption
  lands, the syscall entry will hold the per-task fd_table lock
  around this body — no in-body change needed.
- **No `-EMFILE` path.** dup2 targets an explicit dst_fd, not a
  `fd_alloc`'d one — the -EMFILE branch that #587 exercises has no
  analogue here. dst_fd out-of-range is `-EBADF`, matching Linux
  dup2(2).
- **No refcount rollback on vfs_close failure.** vfs_close is
  documented (#576 §3) as never failing given a valid entry-derived
  idx. All three failure modes (idx==0, idx>=256, refcount==0-at-
  entry) are structurally impossible from a live fd_table entry
  (same argument as #588 §7.3). If the R17 fd_table producers grow
  (e.g., sys_dup, sys_dup3), this analysis re-verifies.
- **No signal-interruptible dup2.** dup2 is atomic at R16.M3. R18+
  signal machinery adds -EINTR, but dup2 is short-body enough that
  Linux itself does not typically make it interruptible.
- **No dst_fd == 0/1/2 acceptance.** Linux dup2(oldfd, 0) is a
  legitimate way to redirect stdin. At R16.M3 we reject dst < 3
  with -EBADF, same as sys_close/sys_read/sys_write. The R16.M5
  TTY milestone will change the policy uniformly across the fd-
  consuming body family — that policy change is a single edit
  pattern across five files.

## 2. Prereq check

### 2.1 What is in place

| Primitive         | Location                                             | Contract used                                                                                                                                                                                     |
|-------------------|------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `sys_open_body`   | `core/syscall/handlers/sys_open.pdx` (#587, LANDED)  | Used by witness preamble to seed `fd=3 -> /tmp/x` and `fd=4 -> /` for sub-test F's pre-open-dst branch.                                                                                             |
| `fd_get`          | `core/fs/fd_table.pdx:16` (#549, LANDED)             | `(task, fd) -> u64`. Called twice inside sys_dup2_body: once on src, once on dst. Also used by sub-test B (equality check on both slots).                                                            |
| `fd_set`          | `core/fs/fd_table.pdx:30` (#549, LANDED)             | `(task, fd, val) -> ()`. Called once (phase 6) to write `src_entry` into the dst slot.                                                                                                              |
| `vfs_close`       | `core/fs/vfs_close.pdx` (#576, LANDED)               | `(vnode_idx) -> u64`. Called at most once (phase 5) when `dst_entry != 0`. Return value ignored per §3.4.                                                                                            |
| `vnode_slot`      | `core/fs/vnode_pool.pdx:148` (#571, LANDED)          | `(idx) -> u64` — returns `&_vnode_pool[idx*64]`. Called inline in phase 7 to reach the shared vnode's refcount field.                                                                                |
| Packed fd_entry   | `design/kernel/r16-m3-001-sys-open.md` §3.2          | Encoding frozen: `entry = vnode_idx (low 16) | offset (high 48)`. `and rax, 0xFFFF` extracts vnode_idx (used in phase 5 for the optional close AND in phase 7 for the refcount++).                  |
| `mov_w` mnemonic  | proven at `vfs_open.pdx:124,130`, `vfs_close.pdx:83,91` | u16 zero-extending load / u16 store — used in phase 7 for the refcount arithmetic (byte-identical to vfs_open's inline hold).                                                                        |
| `witness_path_tmp_x` | `tools/boot_stub.S:670` (#589, LANDED)            | `"/tmp/x\0"`. Reused by the witness preamble to open fd=3.                                                                                                                                          |
| `witness_path_slash` | `tools/boot_stub.S:645` (#587, LANDED)             | `"/\0"`. Used by the witness preamble to open fd=4 for sub-test F's pre-open-dst branch.                                                                                                             |
| `witness_name_tmp` / `witness_name_any` | `tools/boot_stub.S:517, 525`   | `"tmp\0"`, `"x\0"`. Reused by the preamble's `tmpfs_lookup`/`unlink`/`create` chain (same shape as #590 preamble).                                                                                   |
| Vnode-pool wiring | Persisted from #589-#590 preambles                   | Root vnode, tmp_idx, x_idx vnode slots wired to `_tmpfs_vops`. Preamble re-wires defensively (same rationale as #590 §4.4).                                                                          |
| `mount_root_vnode` | `core/fs/mount.pdx` (LANDED)                        | Used by preamble to recover root vnode idx (same idiom as #590 preamble line 3101).                                                                                                                 |
| `tmpfs_lookup` / `tmpfs_unlink` / `tmpfs_create` | `core/fs/tmpfs/*` (LANDED) | Preamble uses the same unlink+create cycle as #590 to trim `/tmp/x` back to a fresh 0-size state (see §4.3 for why).                                                                                 |

### 2.2 What is NOT in place — nothing new

**#591 introduces zero new rodata beyond the two OK/FAIL messages.**
The source buffer, destination-buffer-if-needed, path strings
(`/tmp/x` AND `/`), and directory name strings all already exist.
The witness slab (`_sys_dup2_witness_task`) is a new .bss blob, as
before.

### 2.3 Encoder gaps

**None.** `sys_dup2_body` uses only mnemonics landed pervasively:

| Mnemonic                    | Proven at                                                     |
|-----------------------------|---------------------------------------------------------------|
| `push r64` / `pop r64`      | Every callee-save prologue.                                   |
| `mov r64, r64`              | Pervasive.                                                    |
| `call sym`                  | Pervasive.                                                    |
| `cmp r64, imm32`            | Pervasive.                                                    |
| `jb` / `jae` / `je` / `jne` / `jmp` | Every control-flow site.                              |
| `and r64, imm32`            | `entry & 0xFFFF` extraction — proven at sys_close/read/write. |
| `mov r64, imm64`            | For `mov rax, 0xFFFFFFFFFFFFFFF7` (-EBADF sentinel).          |
| `mov_w r64, [r64+disp]`     | u16 zero-extending load — proven at vfs_open/vfs_close.       |
| `mov_w [r64+disp], r64`     | u16 store — proven at vfs_open/vfs_close.                     |
| `inc r64`                   | Refcount increment — proven at vfs_open.pdx:127.              |
| `lea r64, [rip + sym]`      | Witness rodata addressing — pervasive.                        |
| `shl r64, imm8`             | Not used (no offset-advance arithmetic here — sys_dup2 copies
                                the entry whole; no `bytes_X << 16` needed).                    |

Zero new encoder surface vs the R16.M3 baseline.

## 3. Design

### 3.1 File and module structure

New file: `src/kernel/core/syscall/handlers/sys_dup2.pdx`. Sits
alongside the existing R16.M3 handlers:

```
src/kernel/core/syscall/handlers/
    sys_close.pdx    (#588)
    sys_dup2.pdx     <-- THIS ISSUE
    sys_execve.pdx   (#555)
    sys_exit.pdx     (#557)
    sys_fork.pdx     (#554)
    sys_open.pdx     (#587)
    sys_read.pdx     (#589)
    sys_wait.pdx     (#556)
    sys_write.pdx    (#590)
```

Module name: `SysDup2`. Public export: `sys_dup2_body`.

### 3.2 Register discipline — 5-push prologue

Mirror of sys_read (#589 §3.2) / sys_write (#590 §3.2). Five persistent
values must survive nested calls (`fd_get` twice, `vfs_close`
conditional, `fd_set`, `vnode_slot`):

| Reg | Role                                                                                                                                    |
|-----|-----------------------------------------------------------------------------------------------------------------------------------------|
| rbx | `current` — caller's arg1. Survives all nested calls.                                                                                    |
| r12 | `src_fd` — caller's arg2. Survives all nested calls.                                                                                     |
| r13 | `dst_fd` — caller's arg3. Survives all nested calls; also the return value on success.                                                   |
| r14 | `src_entry` (packed) — populated by phase 3's `fd_get(current, src_fd)`. Survives all subsequent calls; drives the `fd_set` in phase 6 and the vnode_slot arg in phase 7. |
| r15 | `dst_entry` (packed) — populated by phase 5's `fd_get(current, dst_fd)`. Transient — used only for the "is dst open?" test and the `and rax, 0xFFFF` extraction feeding vfs_close. Dead after phase 5. |

**Why 5 pushes and why the persistent set works.** Same arguments as
#589 §3.2 (SysV entry has rsp%16==8; 5 pushes yield rsp%16==0 at each
nested call site; no register morphs beyond r15's death after phase 5).
Unlike sys_read/sys_write, r14 does NOT morph here — src_entry stays
live from phase 3 through phase 7 in one register, without repurposing.
r15 is used-then-dead cleanly (no second life). Slightly SIMPLER register
plan than sys_read/sys_write.

### 3.3 `sys_dup2_body` — body sequence

```asm
; ================================================================
; sys_dup2_body(current, src_fd, dst_fd) -> u64
;   rdi = current       (task_struct*)
;   rsi = src_fd        (u64, validated in [3, 32))
;   rdx = dst_fd        (u64, validated in [3, 32))
;
; Returns rax:
;   dst_fd                          on success
;   0xFFFFFFFFFFFFFFF7 (-EBADF)     on any of:
;                                      (a) src_fd < 3      (stdio reserved at R16.M3)
;                                      (b) src_fd >= 32    (out of range)
;                                      (c) dst_fd < 3      (stdio reserved at R16.M3)
;                                      (d) dst_fd >= 32    (out of range)
;                                      (e) fd_table[src_fd] == 0 (src not open)
;
; Register discipline (5-push prologue for rsp%16==0 at nested calls):
;   rbx = current                  (saved across all nested calls)
;   r12 = src_fd                   (saved across all nested calls)
;   r13 = dst_fd                   (saved across all nested calls; also return value)
;   r14 = src_entry                (persistent from phase 3 onward)
;   r15 = dst_entry                (transient — dies after phase 5)
; ================================================================
sys_dup2_body:
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; --- Save arguments in callee-save regs ---
    mov rbx, rdi                        ; rbx = current
    mov r12, rsi                        ; r12 = src_fd
    mov r13, rdx                        ; r13 = dst_fd

    ; --- Phase 1: validate src_fd in [3, 32) ---
    cmp r12, 3
    jb  sys_dup2_ebadf                  ; src_fd < 3
    cmp r12, 32
    jae sys_dup2_ebadf                  ; src_fd >= 32

    ; --- Phase 2: validate dst_fd in [3, 32) ---
    cmp r13, 3
    jb  sys_dup2_ebadf                  ; dst_fd < 3
    cmp r13, 32
    jae sys_dup2_ebadf                  ; dst_fd >= 32

    ; --- Phase 3: fd_get(current, src_fd) → r14 = src_entry ---
    mov rdi, rbx
    mov rsi, r12
    call fd_get

    cmp rax, 0
    je  sys_dup2_ebadf                  ; src slot free ↔ src_fd not open

    mov r14, rax                        ; r14 = src_entry (persistent)

    ; --- Phase 4: POSIX no-op — src_fd == dst_fd → return dst_fd ---
    ; Validation of both fds AND confirmation that src is open have
    ; ALREADY happened. Only after those pass do we honor the no-op.
    cmp r12, r13
    je  sys_dup2_noop

    ; --- Phase 5: fd_get(current, dst_fd) → r15 = dst_entry ---
    ; If dst was previously open, decrement its old vnode's refcount
    ; before overwriting the slot.
    mov rdi, rbx
    mov rsi, r13
    call fd_get

    mov r15, rax                        ; r15 = dst_entry (transient)

    cmp r15, 0
    je  sys_dup2_copy                   ; dst free ↔ nothing to close

    ; dst was open: vfs_close(dst_entry & 0xFFFF).
    mov rdi, r15
    and rdi, 0xFFFF                     ; rdi = old dst vnode_idx (low 16)
    call vfs_close                      ; return value ignored (same
                                        ;   discipline as #588 §3.4 phase 3)

    ; --- Phase 6: fd_set(current, dst_fd, src_entry) — copy entry ---
sys_dup2_copy:
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14                        ; rdx = src_entry (whole packed u64)
    call fd_set

    ; --- Phase 7: hold — increment refcount on shared vnode ---
    ; Byte-identical to vfs_open's inline hold at vfs_open.pdx:122-130.
    ; (See §6.1 for the proposed factoring of both call-sites into a
    ;  shared `vnode_hold` helper.)
    mov rdi, r14
    and rdi, 0xFFFF                     ; rdi = shared vnode_idx (low 16)
    call vnode_slot                     ; rax = &_vnode_pool[shared_idx]

    xor rcx, rcx
    mov_w rcx, [rax + 4]                ; rcx = refcount (u16 zero-extended)
    inc rcx
    mov_w [rax + 4], rcx                ; [vnode + 4] = refcount + 1

    ; --- Success: return dst_fd ---
    mov rax, r13
    jmp sys_dup2_done

sys_dup2_noop:
    ; POSIX dup2(oldfd, oldfd) — no state change, return dst_fd.
    mov rax, r13
    jmp sys_dup2_done

sys_dup2_ebadf:
    mov rax, 0xFFFFFFFFFFFFFFF7         ; -EBADF (-9)

sys_dup2_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
```

**Instruction count**: ~40 across the body. Slightly denser than
sys_read/sys_write (~35) because of:
- Two fd validation blocks instead of one (+4 instructions).
- The src == dst no-op branch (+2 instructions).
- The optional dst close branch (+5 instructions).
- The inline refcount++ (+5 instructions vs sys_read's `mov r14, rax
  ; mov rcx, r14; shl rcx, 16; add r15, rcx` offset-advance
  arithmetic, same size).

### 3.4 Error-code convention

| Return sentinel                | Signed value | Meaning                                                     |
|--------------------------------|--------------|-------------------------------------------------------------|
| `dst_fd` (in [3, 32))          | success      | fd_table[dst_fd] now holds the src entry                     |
| `0xFFFFFFFFFFFFFFF7`           | `-9`         | `-EBADF` — one of five failure modes                        |

**Why one sentinel across five failure modes.** POSIX `dup2(2)` uses
EBADF for both "oldfd is not a valid file descriptor" and "newfd is
out of range". Also EINVAL is documented for `newfd == max`, but Linux
returns EBADF uniformly. Sticking with the Linux convention keeps
sys_dup2 error semantics aligned with what R17 userland (glibc port)
will expect. The five failure modes are distinguished at the witness
sub-test level (E for out-of-range src), not in the return value.

### 3.5 Why the phase order matters

- **Validate before Get (phases 1-2 before phase 3).** Same reason as
  #588 §3.5: `fd_get` performs an unconditional `mov rax, [rdi +
  rsi*8 + 168]` — no bounds check. Passing an unvalidated fd would
  reach past the fd_table region into adjacent task_struct fields
  or .bss.
- **Validate both fds up front (phase 1 AND phase 2 before phase 3).**
  We could interleave `validate src → fd_get src → validate dst`,
  but the phase-2 dst validation is cheap (4 instructions) and
  short-circuits BEFORE we've touched any state or called any
  primitive. Fail-fast on bad args.
- **Get src (phase 3) before src==dst check (phase 4).** Linux
  dup2 semantics: the no-op requires src to be a VALID open fd. If
  src is closed and src==dst, we must return -EBADF, not silently
  succeed. Phase 3's `entry == 0 → -EBADF` catches this correctly.
- **src==dst check (phase 4) before Get dst / Close dst / Copy /
  Hold.** If we skipped this check and let src==dst flow through
  phase 5-7, we would: (a) call vfs_close on the src's vnode
  (refcount--), (b) copy the entry to itself (no-op), (c) increment
  the refcount (++). Net refcount change: 0. Actually semantically
  correct! But there are two hazards:
  - vfs_close on refcount==1 (if the shared vnode is only held by
    this fd) would drop to 0 and fire `vops_close`, which for tmpfs
    might trigger backend cleanup that DOESN'T get undone by phase 7's
    hold. The vnode is now "closed" from the backend's perspective
    but still referenced by both fds. Refcount-consistent, backend-
    inconsistent. Toxic.
  - Even when the shared vnode is held by multiple fds and refcount
    stays >0 across the close-then-hold sequence, calling vfs_close
    is wasteful.
  The early `src==dst → return` avoids both hazards.
- **Get dst (phase 5) before Copy (phase 6).** We need to know if
  dst was previously open so we can close its vnode. If we copied
  first, we would lose the old dst_entry and leak the refcount.
- **Close dst (phase 5) before Copy (phase 6).** Same argument —
  we must decrement the old vnode's refcount BEFORE the slot is
  overwritten, because after the overwrite there is no way to
  reach the old vnode_idx.
- **Copy (phase 6) before Hold (phase 7).** Order-independent
  semantically (both operations are side effects on independent
  state), but doing Copy first makes the "post-copy state" visible
  before the "hold effect" — a hypothetical future observer sees
  a moment where both fds reference the vnode but refcount is
  still 1. That's a hazard only if the observer runs BETWEEN the
  copy and the hold — impossible at R16.M3 (single-threaded, no
  preemption). But the ordering (Copy then Hold) is nonetheless
  what Linux does and what the R18 preemption port will need
  once locks arrive. Freezing the order here is prescient.

### 3.6 File contents (skeleton)

```pdx
// src/kernel/core/syscall/handlers/sys_dup2.pdx — R16-M3-005 (#591)
// sys_dup2 body: dual-fd validate; entry copy; conditional dst-close; shared-vnode hold.
//
// Consumes the packed fd_entry encoding frozen by #587 §3.2:
//   entry = vnode_idx | (offset << 16)
// Copies src_entry to dst slot byte-identically (both vnode_idx and
// offset preserved). Increments the shared vnode's refcount inline —
// same idiom as vfs_open.pdx:122-130 (see r16-m3-005 §6.1 for the
// proposed factoring into a shared `vnode_hold` helper).
//
// See design/kernel/r16-m3-005-sys-dup2.md for full contract.

module SysDup2 = structure {
  // === Error sentinel (negative-errno u64, matches Linux errno signs) ===
  pub let SYS_DUP2_ERR_EBADF : u64 = 0xFFFFFFFFFFFFFFF7   // -9

  // === Layout constants (from #549 fd_table freeze) ===
  pub let FD_TABLE_STDIO_LO : u64 = 3                     // matches fd_table.pdx:10
  pub let FD_TABLE_MAX      : u64 = 32                    // matches fd_table.pdx:9

  // === Layout constants (from #570 vnode-pool freeze) ===
  pub let VNODE_REFCOUNT_OFFSET : u64 = 4                 // u16 refcount at vnode +4

  // ==========================================================================
  // sys_dup2_body — dual-fd validate; entry copy; conditional dst-close; hold
  //
  // Input:
  //   rdi = current   (task_struct*, must be non-NULL)
  //   rsi = src_fd    (u64 — validated in [3, 32) at the trust boundary)
  //   rdx = dst_fd    (u64 — validated in [3, 32) at the trust boundary)
  //
  // Output:
  //   rax = dst_fd                        on success (both fd_table[src_fd]
  //                                        and fd_table[dst_fd] now point at
  //                                        the same packed entry — same
  //                                        vnode_idx, same offset)
  //   rax = 0xFFFFFFFFFFFFFFF7 (-EBADF)   on any of:
  //         (a) src_fd < 3
  //         (b) src_fd >= 32
  //         (c) dst_fd < 3
  //         (d) dst_fd >= 32
  //         (e) fd_table[src_fd] == 0
  //
  // Side effects:
  //   on success:
  //     - If dst_fd was previously open, its old vnode's refcount is
  //       decremented (vfs_close side effect).
  //     - fd_table[dst_fd] is populated with fd_table[src_fd]'s value
  //       (byte-identical packed u64: same vnode_idx AND same offset).
  //     - The shared vnode's refcount is incremented by 1 (so subsequent
  //       sys_close on either fd decrements without freeing).
  //     - If src_fd == dst_fd, no state mutation — the no-op branch
  //       still returns dst_fd (POSIX-compliant).
  //   on -EBADF: no state mutation (early return before any nested call
  //     that could produce side effects).
  // ==========================================================================
  pub let sys_dup2_body : (u64, u64, u64) -> u64 !{mem} @{} =
    fn (current: u64) (src_fd: u64) (dst_fd: u64) -> unsafe {
      effects: {mem},
      capabilities: {},
      justification: "R16-M3-005 (#591): sys_dup2 — dual-fd validate; fd_get(src); POSIX no-op check; fd_get(dst); conditional vfs_close(dst_vnode); fd_set(dst, src_entry); inline hold of shared vnode. 3-arg SysV entry. rdi=current, rsi=src_fd, rdx=dst_fd. 5-push prologue (rbx, r12, r13, r14, r15) aligns rsp%16==0 for nested calls and saves current/src_fd/dst_fd/src_entry across up to five nested calls (fd_get x2, vfs_close conditional, fd_set, vnode_slot). Phase 1: validate src_fd in [3,32) via cmp+jb / cmp+jae. Phase 2: byte-identical validation of dst_fd. Both failures jump to sys_dup2_ebadf → rax = 0xFFFFFFFFFFFFFFF7 (-9). Phase 3: fd_get(rbx, r12) → rax = src_entry; cmp rax, 0; je → -EBADF (src slot free ↔ src_fd not open). mov r14, rax saves src_entry across all subsequent calls. Phase 4: cmp r12, r13; je sys_dup2_noop — POSIX no-op semantics (dup2(x, x) with x valid returns x without touching state). The check happens AFTER phase 3, so an invalid src still returns -EBADF even when src==dst. Phase 5: fd_get(rbx, r13) → rax = dst_entry, saved in r15. cmp r15, 0; je sys_dup2_copy skips the close when dst was already free. Otherwise: mov rdi, r15; and rdi, 0xFFFF extracts the old dst vnode_idx per #587 §3.2 encoding; call vfs_close drops that vnode's refcount (return value ignored per #588 §3.4 phase 3 — every entry from an R16.M3-legal producer round-trips safely through vfs_close). Phase 6: fd_set(rbx, r13, r14) writes src_entry (whole packed u64: vnode_idx AND offset) into the dst slot. Phase 7 (inline hold, byte-identical to vfs_open.pdx:122-130): mov rdi, r14; and rdi, 0xFFFF extracts shared vnode_idx; call vnode_slot → rax = &_vnode_pool[shared_idx]. xor rcx, rcx; mov_w rcx, [rax + 4]; inc rcx; mov_w [rax + 4], rcx increments the u16 refcount at vnode +4 in place. Return mov rax, r13 (dst_fd). Register discipline: rbx (current), r12 (src_fd), r13 (dst_fd), r14 (src_entry) all callee-save-preserved through up to 5 nested calls; r15 (dst_entry) used-then-dead across the single vfs_close it feeds. All nested callees (fd_get leaf, fd_set leaf, vfs_close 5-push prologue, vnode_slot leaf) trusted callee-save clean per their own justifications. See design/kernel/r16-m3-005-sys-dup2.md §3 for full rationale.",
      block: {
        push rbx;
        push r12;
        push r13;
        push r14;
        push r15;

        mov rbx, rdi;                        // rbx = current
        mov r12, rsi;                        // r12 = src_fd
        mov r13, rdx;                        // r13 = dst_fd

        // Phase 1: validate src_fd in [3, 32)
        cmp r12, 3;
        jb  sys_dup2_ebadf;
        cmp r12, 32;
        jae sys_dup2_ebadf;

        // Phase 2: validate dst_fd in [3, 32)
        cmp r13, 3;
        jb  sys_dup2_ebadf;
        cmp r13, 32;
        jae sys_dup2_ebadf;

        // Phase 3: fd_get(current, src_fd) → r14 = src_entry
        mov rdi, rbx;
        mov rsi, r12;
        call fd_get;

        cmp rax, 0;
        je  sys_dup2_ebadf;                  // src slot free

        mov r14, rax;                        // r14 = src_entry

        // Phase 4: POSIX no-op check — src_fd == dst_fd → return dst_fd
        cmp r12, r13;
        je  sys_dup2_noop;

        // Phase 5: fd_get(current, dst_fd); if non-zero, vfs_close it
        mov rdi, rbx;
        mov rsi, r13;
        call fd_get;
        mov r15, rax;                        // r15 = dst_entry (transient)

        cmp r15, 0;
        je  sys_dup2_copy;                   // dst was free — skip close

        mov rdi, r15;
        and rdi, 0xFFFF;                     // rdi = old dst vnode_idx
        call vfs_close;                      // return value ignored

      sys_dup2_copy:
        // Phase 6: fd_set(current, dst_fd, src_entry) — copy the packed u64
        mov rdi, rbx;
        mov rsi, r13;
        mov rdx, r14;
        call fd_set;

        // Phase 7: hold — increment shared vnode's refcount inline.
        // Byte-identical to vfs_open's inline hold at vfs_open.pdx:122-130
        // (see §6.1 for the proposed factoring into `vnode_hold`).
        mov rdi, r14;
        and rdi, 0xFFFF;                     // rdi = shared vnode_idx
        call vnode_slot;                     // rax = &_vnode_pool[shared_idx]

        xor rcx, rcx;
        mov_w rcx, [rax + 4];                // rcx = refcount (u16)
        inc rcx;
        mov_w [rax + 4], rcx;                // [vnode + 4] = refcount + 1

        mov rax, r13;                        // return dst_fd
        jmp sys_dup2_done;

      sys_dup2_noop:
        // POSIX dup2(oldfd, oldfd) with valid oldfd — no state change.
        mov rax, r13;
        jmp sys_dup2_done;

      sys_dup2_ebadf:
        mov rax, 0xFFFFFFFFFFFFFFF7;         // -EBADF

      sys_dup2_done:
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

### 4.1 Choice: dedicated `_sys_dup2_witness_task`

Same three-way trade as #587-#590: dedicated slab vs. `_idle_tcb` vs.
reusing a prior witness's slab. Dedicated wins for the same three
reasons (no scheduler-init ordering hazard; no cross-witness state
coupling; stylistic uniformity), plus one dup2-specific reason:

- **Sub-test C requires a KNOWN refcount baseline** to make the
  literal assertion `refcount == 2` work. Reusing `_sys_write_witness_task`
  would carry over the +1 refcount from #590's sys_open on `/tmp/x`;
  our own sys_open in the preamble would then land refcount at 2
  BEFORE the dup2, making sub-test C's "== 2" fire vacuously. A
  fresh slab combined with the preamble's refcount reset (§4.3.1)
  guarantees `sys_open → refcount == 1`, and `dup2 → refcount == 2`,
  cleanly.

### 4.2 Slab declaration

At the tail of `kernel_main.pdx`, alongside the sibling witness
task slabs (after `_sys_write_witness_task` at line ~3763):

```pdx
// R16-M3-005 (#591): sys_dup2 witness task storage.
// Static .bss blob (2224 bytes = 278 u64s) backing a dedicated
// witness task_struct. Same rationale as _sys_write_witness_task
// (#590 §4.1): witness storage stays independent of the scheduler
// init sequence so R16.M3 witnesses run before idle_init / runq_init
// without ordering hazards.
pub let mut _sys_dup2_witness_task : [u64; 278] = uninit @align(8)
```

### 4.3 Preamble: unlink + create + reset refcount + open

**The choice.** The sys_dup2 preamble does the same
`tmpfs_lookup → tmpfs_unlink → tmpfs_create → vnode wiring` cycle as
#590, then adds a **refcount reset** step before opening the fd. It
then opens BOTH `/tmp/x` (as fd=3) AND `/` (as fd=4). fd=4 is used
by sub-test F to observe the pre-close-dst branch.

#### 4.3.1 Why the refcount reset

Post-#590, `_vnode_pool[x_idx].refcount` is at 1 (from sys_write's
sys_open, never closed). If we skip the reset and just re-open, sys_open
increments to 2 — and dup2 would push to 3, breaking sub-test C's
literal `refcount == 2` assertion.

The unlink+create cycle DOES NOT reset the vnode-pool's refcount
field. tmpfs_unlink frees the tmpfs INODE; the vnode-pool slot's u16
refcount at `[vnode + 4]` is untouched. tmpfs_create reallocates the
tmpfs inode (usually into the same slot per #590 §4.4), but the
associated vnode-pool slot's refcount field stays whatever the
previous open/close arithmetic left.

**Reset idiom.** Directly zero the u16 refcount field:

```asm
; --- Reset x_idx vnode refcount to 0 (state normalization for the
;     literal sub-test C assertion — see §4.3.1). ---
mov  rdi, r13                            ; r13 = fresh x_idx
call vnode_slot                          ; rax = &_vnode_pool[x_idx]
xor  rcx, rcx
mov_w [rax + 4], rcx                     ; refcount = 0
```

This is an abstraction violation (direct write to a field owned by
vfs_open/vfs_close), but it's contained within the witness — production
code never touches vnode refcount directly. Analogous to #590 §4.3's
"trim /tmp/x back to fresh 0-size state" via unlink+create: witness
state normalization for the literal assertion. §6.3 proposes an
alternative (relative-delta sub-test C) that would avoid the reset —
rejected for the reasons documented there.

#### 4.3.2 Second fd (fd=4 → root) for sub-test F

After opening fd=3 → `/tmp/x`, the preamble also opens fd=4 → `/`.
Why:

- Sub-test F needs a case where `fd_table[dst_fd] != 0` at dup2
  time, so that the phase-5 vfs_close branch fires.
- Opening `/` gives fd=4 (scan-from-3 finds fd=3 taken, returns 4).
- The root vnode is a DIFFERENT vnode than /tmp/x, so we can
  observe the root vnode's refcount decrement independently from
  the shared /tmp/x vnode's refcount increment.

The order matters: sys_open("/tmp/x") happens first (returns 3),
then sys_open("/") (returns 4). Reversing the order would give
`fd=3 -> /` and `fd=4 -> /tmp/x` — sub-test A/B/C/D would then need
to dup2 fd=4 instead of fd=3, which is fine but reorders the
canary; the current order matches the parent brief exactly.

### 4.4 Vnode-pool wiring workaround — same shape as #590

The preamble re-wires root_idx, tmp_idx, and x_idx's vnode-pool slots
defensively, matching #590 §4.4's pattern. Same rationale: the
underlying `path_resolve` conflates vnode-pool indices with backend-
native inode indices; wiring persists from earlier witnesses in most
cases but a witness-added-between could shift x_idx to a different
slot. Three instructions (vnode_slot + two stores) per slot to re-wire;
cheap enough not to gate on the actual index equality.

### 4.5 Position in kernel_main

Inserted immediately after `sys_write_witness_done:` (line 3205) and
before the `wrmsr` at line 3212. Placement satisfies all prereqs:

- vfs_close witnessed at line ~2117 (#576 canary).
- sys_open_body witnessed at line 2815 (#587 canary).
- sys_close_body witnessed at line 2880 (#588 canary; but sys_dup2
  doesn't CALL sys_close_body, only vfs_close directly — kept in the
  prereq list because the semantic model composition (open, dup2,
  close, close) needs sys_close to be understood by the reader).
- sys_read_body witnessed at line 2942 (#589 canary; not called
  by sys_dup2 or its witness, but tacit).
- sys_write_body witnessed at line 3096 (#590 canary; leaves
  x_idx.refcount at 1, which the sys_dup2 preamble resets to 0 per
  §4.3.1).
- No coupling to idle/runq/sched_switch witnesses that follow
  the wrmsr.

## 5. Test canary — kernel_main witness block

### 5.1 Preamble

Inputs:

- `_sys_dup2_witness_task`: fresh 278-u64 `.bss` blob (all zeros).
- `sys_open_body`, `fd_get`, `vnode_slot` proven working.
- `witness_path_tmp_x`, `witness_path_slash` resident.
- `witness_name_tmp`, `witness_name_any` resident.
- root vnode wiring persisted from #590; re-wired defensively.
- x_idx vnode wiring persisted from #590; re-wired defensively.
- x_idx.refcount is 1 entering the witness (from #590's sys_open);
  reset to 0 in the preamble (§4.3.1).

### 5.2 Sub-tests

Matches the parent brief exactly: A/B/C for the success path,
D for the src==dst no-op, E for the src-out-of-range trust-boundary,
F for the pre-open-dst branch.

**Preamble prep — trim + wire + reset + open fd=3 → /tmp/x and fd=4 → /.**

```asm
; --- Wire root vnode's vnode-pool slot ---
call mount_root_vnode                        ; rax = root vnode idx
mov  rdi, rax
call vnode_slot                              ; rax = &vnode[root]
lea  rcx, [rip + _tmpfs_vops]
mov  [rax + 24], rcx                         ; ops_ptr = &_tmpfs_vops
mov  rcx, 1                                  ; TMPFS_INODE_IDX_ROOT
mov  [rax + 32], rcx                         ; backend_ptr = root_idx

; --- Recover tmp_idx via lookup on root ---
mov  rdi, 1
lea  rsi, [rip + witness_name_tmp]           ; "tmp\0"
call tmpfs_lookup
cmp  rax, 0
je   sys_dup2_witness_fail
mov  r12, rax                                ; r12 = tmp_idx

; --- Wire /tmp's vnode-pool slot ---
mov  rdi, r12
call vnode_slot
lea  rcx, [rip + _tmpfs_vops]
mov  [rax + 24], rcx
mov  rcx, r12
mov  [rax + 32], rcx

; --- Trim /tmp/x back to fresh 0-size state: unlink + create ---
mov  rdi, r12
lea  rsi, [rip + witness_name_any]           ; "x\0"
mov  rdx, 1
call tmpfs_unlink
cmp  rax, 0
jne  sys_dup2_witness_fail                   ; unlink success == 0
                                              ; (or 1 depending on tmpfs_unlink
                                              ;  convention — mirror the
                                              ;  #590 witness's exact check
                                              ;  when implementing)

mov  rdi, r12
lea  rsi, [rip + witness_name_any]           ; "x\0"
mov  rdx, 1
mov  rcx, 1                                  ; VNODE_TYPE_REG
call tmpfs_create
cmp  rax, 0
je   sys_dup2_witness_fail
cmp  rax, 0xFFFF
je   sys_dup2_witness_fail                   ; alloc-OOM sentinel
mov  r13, rax                                ; r13 = fresh x_idx

; --- Wire fresh x_idx's vnode-pool slot ---
mov  rdi, r13
call vnode_slot                              ; rax = &_vnode_pool[x_idx]
lea  rcx, [rip + _tmpfs_vops]
mov  [rax + 24], rcx
mov  rcx, r13
mov  [rax + 32], rcx

; --- CRITICAL: reset x_idx vnode refcount to 0 (§4.3.1) ---
mov  rdi, r13
call vnode_slot                              ; rax = &_vnode_pool[x_idx]
xor  rcx, rcx
mov_w [rax + 4], rcx                         ; refcount = 0

; --- sys_open("/tmp/x", 0, 0) → fd = 3, x_idx.refcount → 1 ---
lea  rdi, [rip + _sys_dup2_witness_task]
lea  rsi, [rip + witness_path_tmp_x]         ; "/tmp/x\0"
xor  rdx, rdx
xor  rcx, rcx
call sys_open_body
cmp  rax, 3
jne  sys_dup2_witness_fail

; --- sys_open("/", 0, 0) → fd = 4, root_idx.refcount ++ ---
lea  rdi, [rip + _sys_dup2_witness_task]
lea  rsi, [rip + witness_path_slash]         ; "/\0"
xor  rdx, rdx
xor  rcx, rcx
call sys_open_body
cmp  rax, 4
jne  sys_dup2_witness_fail
```

**Sub-test D**: `sys_dup2(w, 3, 3)` returns `3` (no-op). Done FIRST
because it's state-neutral — it doesn't touch refcount or fd_table
values, so it's the safest to run before any state-mutating sub-test.

```asm
lea  rdi, [rip + _sys_dup2_witness_task]
mov  rsi, 3                                  ; src_fd
mov  rdx, 3                                  ; dst_fd
call sys_dup2_body
cmp  rax, 3                                  ; returns dst_fd
jne  sys_dup2_witness_fail
```

Proves: (a) validation passes for both fds; (b) fd_get(src) confirms
src is open; (c) the src==dst branch fires BEFORE any vfs_close or
fd_set; (d) return is dst_fd (== src_fd here).

**Sub-test A**: `sys_dup2(w, 3, 5)` returns `5`.

```asm
lea  rdi, [rip + _sys_dup2_witness_task]
mov  rsi, 3                                  ; src_fd
mov  rdx, 5                                  ; dst_fd (previously free)
call sys_dup2_body
cmp  rax, 5                                  ; returns dst_fd
jne  sys_dup2_witness_fail
```

Proves: (a) both fds validated; (b) src is open; (c) src!=dst; (d)
dst_fd 5 was free (fd_get returned 0), so vfs_close was skipped; (e)
fd_set(5, src_entry) succeeded; (f) refcount++ ran; (g) return is
dst_fd.

**Sub-test B**: `fd_table[5] == fd_table[3]` (packed u64 equal).

```asm
lea  rdi, [rip + _sys_dup2_witness_task]
mov  rsi, 3
call fd_get
mov  r12, rax                                ; r12 = src_entry (scope-local
                                              ;   reuse; witness leaf frame)

lea  rdi, [rip + _sys_dup2_witness_task]
mov  rsi, 5
call fd_get
cmp  rax, r12
jne  sys_dup2_witness_fail
```

Proves: the whole packed u64 copied byte-identically — same vnode_idx
in low 16 bits AND same offset (0 here) in high 48 bits. Encoding
survived the copy without any mask drift or shift error.

**Sub-test C**: shared vnode's refcount == 2.

```asm
; Extract vnode_idx from fd_table[3]'s entry.
lea  rdi, [rip + _sys_dup2_witness_task]
mov  rsi, 3
call fd_get
and  rax, 0xFFFF                             ; rax = vnode_idx (shared)

mov  rdi, rax
call vnode_slot                              ; rax = &_vnode_pool[shared_idx]
xor  rcx, rcx
mov_w rcx, [rax + 4]                         ; rcx = refcount (u16)
cmp  rcx, 2
jne  sys_dup2_witness_fail
```

Proves: the phase-7 hold fired. Combined with the preamble's
refcount-reset-to-0 and sys_open's ++, the pre-dup2 refcount was 1;
after dup2, refcount is 2. Both fd=3 and fd=5 now safely reference the
shared vnode.

**Sub-test E**: `sys_dup2(w, 99, 5)` returns `-EBADF` (src out of range).

```asm
lea  rdi, [rip + _sys_dup2_witness_task]
mov  rsi, 99                                 ; src_fd (out of range)
mov  rdx, 5
call sys_dup2_body
mov  rcx, 0xFFFFFFFFFFFFFFF7                 ; -EBADF
cmp  rax, rcx
jne  sys_dup2_witness_fail
```

Proves: the phase-1 `cmp r12, 32; jae` branch fires. No fd_get,
no vfs_close, no fd_set — early return with -EBADF.

Note: dst_fd out-of-range is NOT explicitly tested. It's proven by
inspection — the phase-2 validation is a byte-identical copy of
phase-1 applied to r13. If the reviewer wants active coverage,
add sub-test E' with `sys_dup2(3, 99) → -EBADF`; ~5 witness LOC.

**Sub-test F**: `sys_dup2(w, 3, 4)` — closes fd 4's old vnode (root),
copies fd 3's entry to slot 4.

Pre-state:
- fd_table[3] = x_entry (still there from preamble)
- fd_table[4] = root_entry (from preamble sys_open("/"))
- fd_table[5] = x_entry (from sub-test A)
- x_idx.refcount = 2 (from sub-test A's hold)
- root_idx.refcount = whatever `mount_root_vnode`'s baseline + 1

Save root_idx.refcount BEFORE dup2 (call it `R_root_before`), then:

```asm
; --- Sample root_idx refcount before dup2 ---
lea  rdi, [rip + _sys_dup2_witness_task]
mov  rsi, 4
call fd_get
and  rax, 0xFFFF                             ; rax = root_idx
mov  r12, rax                                ; r12 = root_idx (save)
mov  rdi, rax
call vnode_slot
xor  rcx, rcx
mov_w rcx, [rax + 4]
mov  r13, rcx                                ; r13 = R_root_before (save)

; --- Sub-test F: sys_dup2(w, 3, 4) → 4 ---
lea  rdi, [rip + _sys_dup2_witness_task]
mov  rsi, 3
mov  rdx, 4
call sys_dup2_body
cmp  rax, 4
jne  sys_dup2_witness_fail

; --- Sub-test F.1: fd_table[4] == fd_table[3] (packed u64 equal) ---
lea  rdi, [rip + _sys_dup2_witness_task]
mov  rsi, 3
call fd_get
mov  r14, rax                                ; r14 = fd_table[3]

lea  rdi, [rip + _sys_dup2_witness_task]
mov  rsi, 4
call fd_get
cmp  rax, r14
jne  sys_dup2_witness_fail

; --- Sub-test F.2: root_idx refcount decremented by 1 (old dst closed) ---
mov  rdi, r12                                ; root_idx from earlier
call vnode_slot
xor  rcx, rcx
mov_w rcx, [rax + 4]
inc  rcx                                     ; rcx = R_root_after + 1
cmp  rcx, r13                                ; == R_root_before?
jne  sys_dup2_witness_fail

; --- Sub-test F.3: shared x_idx refcount now == 3 (3 fds reference it) ---
lea  rdi, [rip + _sys_dup2_witness_task]
mov  rsi, 3
call fd_get
and  rax, 0xFFFF                             ; rax = x_idx
mov  rdi, rax
call vnode_slot
xor  rcx, rcx
mov_w rcx, [rax + 4]
cmp  rcx, 3                                  ; fd 3, 4, 5 all reference x_idx
jne  sys_dup2_witness_fail
```

Proves: (a) the phase-5 fd_get(dst) + fd_get-returned-nonzero branch
recognized dst=4 as previously open; (b) vfs_close ran on root's
vnode_idx (refcount--); (c) the entry copy landed byte-identically;
(d) the phase-7 hold fired again for x_idx (refcount 2 → 3).

### 5.3 Marker

On D, A, B, C, E, F all green:

```
R16 SYS DUP2 OK
```

Emitted via `uart_puts` on `sys_dup2_ok_msg`. Fingerprint added to
all three R16.M3-tempo expected-output files, immediately after
the existing `R16 SYS WRITE OK` line.

### 5.4 Witness assembly (complete block sketch)

```asm
; ============================================================
; R16-M3-005 (#591): sys_dup2 witness — preamble + 6 sub-tests
; ============================================================
sys_dup2_witness:
    ; --- Preamble: wire root, tmp_idx; unlink+create x; wire x_idx;
    ;               reset x_idx refcount; open fd=3 (/tmp/x) and fd=4 (/) ---
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
    je   sys_dup2_witness_fail
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
    ; (unlink success check — mirror #590 witness's exact convention)

    mov  rdi, r12
    lea  rsi, [rip + witness_name_any]
    mov  rdx, 1
    mov  rcx, 1                                 ; VNODE_TYPE_REG
    call tmpfs_create
    cmp  rax, 0
    je   sys_dup2_witness_fail
    cmp  rax, 0xFFFF
    je   sys_dup2_witness_fail
    mov  r13, rax                               ; r13 = fresh x_idx

    mov  rdi, r13
    call vnode_slot
    lea  rcx, [rip + _tmpfs_vops]
    mov  [rax + 24], rcx
    mov  rcx, r13
    mov  [rax + 32], rcx

    ; Reset x_idx refcount to 0 (state normalization for sub-test C).
    mov  rdi, r13
    call vnode_slot
    xor  rcx, rcx
    mov_w [rax + 4], rcx

    lea  rdi, [rip + _sys_dup2_witness_task]
    lea  rsi, [rip + witness_path_tmp_x]
    xor  rdx, rdx
    xor  rcx, rcx
    call sys_open_body
    cmp  rax, 3
    jne  sys_dup2_witness_fail

    lea  rdi, [rip + _sys_dup2_witness_task]
    lea  rsi, [rip + witness_path_slash]
    xor  rdx, rdx
    xor  rcx, rcx
    call sys_open_body
    cmp  rax, 4
    jne  sys_dup2_witness_fail

    ; --- Sub-test D: sys_dup2(w, 3, 3) → 3 (no-op) ---
    lea  rdi, [rip + _sys_dup2_witness_task]
    mov  rsi, 3
    mov  rdx, 3
    call sys_dup2_body
    cmp  rax, 3
    jne  sys_dup2_witness_fail

    ; --- Sub-test A: sys_dup2(w, 3, 5) → 5 ---
    lea  rdi, [rip + _sys_dup2_witness_task]
    mov  rsi, 3
    mov  rdx, 5
    call sys_dup2_body
    cmp  rax, 5
    jne  sys_dup2_witness_fail

    ; --- Sub-test B: fd_table[5] == fd_table[3] ---
    lea  rdi, [rip + _sys_dup2_witness_task]
    mov  rsi, 3
    call fd_get
    mov  r12, rax                               ; r12 = src_entry

    lea  rdi, [rip + _sys_dup2_witness_task]
    mov  rsi, 5
    call fd_get
    cmp  rax, r12
    jne  sys_dup2_witness_fail

    ; --- Sub-test C: shared vnode's refcount == 2 ---
    lea  rdi, [rip + _sys_dup2_witness_task]
    mov  rsi, 3
    call fd_get
    and  rax, 0xFFFF
    mov  rdi, rax
    call vnode_slot
    xor  rcx, rcx
    mov_w rcx, [rax + 4]
    cmp  rcx, 2
    jne  sys_dup2_witness_fail

    ; --- Sub-test E: sys_dup2(w, 99, 5) → -EBADF ---
    lea  rdi, [rip + _sys_dup2_witness_task]
    mov  rsi, 99
    mov  rdx, 5
    call sys_dup2_body
    mov  rcx, 0xFFFFFFFFFFFFFFF7
    cmp  rax, rcx
    jne  sys_dup2_witness_fail

    ; --- Sub-test F prep: sample fd_table[4]'s vnode_idx + refcount ---
    lea  rdi, [rip + _sys_dup2_witness_task]
    mov  rsi, 4
    call fd_get
    and  rax, 0xFFFF
    mov  r12, rax                               ; r12 = root_idx
    mov  rdi, rax
    call vnode_slot
    xor  rcx, rcx
    mov_w rcx, [rax + 4]
    mov  r13, rcx                               ; r13 = R_root_before

    ; --- Sub-test F: sys_dup2(w, 3, 4) → 4 ---
    lea  rdi, [rip + _sys_dup2_witness_task]
    mov  rsi, 3
    mov  rdx, 4
    call sys_dup2_body
    cmp  rax, 4
    jne  sys_dup2_witness_fail

    ; F.1: fd_table[4] == fd_table[3]
    lea  rdi, [rip + _sys_dup2_witness_task]
    mov  rsi, 3
    call fd_get
    mov  r14, rax
    lea  rdi, [rip + _sys_dup2_witness_task]
    mov  rsi, 4
    call fd_get
    cmp  rax, r14
    jne  sys_dup2_witness_fail

    ; F.2: root_idx refcount decreased by 1
    mov  rdi, r12
    call vnode_slot
    xor  rcx, rcx
    mov_w rcx, [rax + 4]
    inc  rcx
    cmp  rcx, r13
    jne  sys_dup2_witness_fail

    ; F.3: x_idx refcount == 3
    lea  rdi, [rip + _sys_dup2_witness_task]
    mov  rsi, 3
    call fd_get
    and  rax, 0xFFFF
    mov  rdi, rax
    call vnode_slot
    xor  rcx, rcx
    mov_w rcx, [rax + 4]
    cmp  rcx, 3
    jne  sys_dup2_witness_fail

    ; --- All green ---
    lea  rdi, [rip + sys_dup2_ok_msg]
    call uart_puts
    jmp  sys_dup2_witness_done

sys_dup2_witness_fail:
    lea  rdi, [rip + sys_dup2_fail_msg]
    call uart_puts

sys_dup2_witness_done:
```

### 5.5 String data — `tools/boot_stub.S`

Append after the sys_write messages (~line 632):

```asm
# R16-M3-005 (#591): sys_dup2 witness success message
.global sys_dup2_ok_msg
.align 8
sys_dup2_ok_msg: .ascii "R16 SYS DUP2 OK\n\0"

# R16-M3-005 (#591): sys_dup2 witness failure message
.global sys_dup2_fail_msg
.align 8
sys_dup2_fail_msg: .ascii "R16 SYS DUP2 FAIL\n\0"
```

All other rodata (`witness_path_tmp_x`, `witness_path_slash`,
`witness_name_tmp`, `witness_name_any`) already exists. **No new
rodata strings beyond the two messages.**

### 5.6 Fingerprint files — marker insertion

The line `R16 SYS DUP2 OK` inserts into all three R16.M3-tempo
fingerprint files immediately after the `R16 SYS WRITE OK` line:

- `tests/r14b/expected-boot-r14b-loader.txt`  (insert after line 30)
- `tests/r15/expected-boot-r15-ring3.txt`     (insert after line 40)
- `tests/r15/expected-boot-r15-process.txt`   (insert after line 41)

Contains-in-order matching means the addition is strictly additive
— no earlier line reorders. All existing 5-mode smoke stages
(`boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`,
`boot_r12_denial`) that do not observe R16 markers stay
byte-identically green.

## 6. Alternatives considered / follow-ups (rejected or deferred)

### 6.1 Follow-up: factor `vnode_hold` from vfs_open + sys_dup2

**Proposal.** Extract the byte-identical inline refcount-increment
pattern (currently duplicated at `vfs_open.pdx:122-130` and at
sys_dup2 phase 7) into a shared helper:

```pdx
pub let vnode_hold : (u64) -> u64 !{mem} @{} =
  fn (idx: u64) -> unsafe {
    effects: {mem},
    capabilities: {},
    justification: "...refcount increment shared between vfs_open and sys_dup2...",
    block: {
      mov rdi, rdi;                          // idx (arg preserved)
      call vnode_slot;                       // rax = &vnode
      xor rcx, rcx;
      mov_w rcx, [rax + 4];
      inc rcx;
      mov_w [rax + 4], rcx;
      ret
    }
  }
```

**Deferred to #592 (fd inherit across fork).** Rationale:

1. **Scope discipline.** Factoring during #591 mixes two concerns
   (sys_dup2 body + vnode_pool refactor). Doing them separately
   keeps commit provenance clean.
2. **Wait for a third call-site.** Two identical inline blocks
   arguably still fit within a "grep-visible pattern" convention.
   The third call-site — #592 (fd inherit across fork) — will
   need the same operation for every fd_table slot inherited by
   the child. Three call-sites is the standard trigger for
   extraction.
3. **No functional benefit at R16.M3.** Inline hold works
   identically to a called-hold; the `call vnode_hold` alternative
   trades 4 instructions inline for `mov rdi, rdi; call vnode_hold`
   plus the callee's `ret` — no code size win, one extra call
   frame.

Filed as an R16 tail issue: `r16-tail-vnode-hold-factor`. Blocks
#592.

### 6.2 Follow-up: R16.M3 SYSCALL entry batch-wire

**Proposal.** Now that all five R16.M3 syscall bodies compose
(sys_open, sys_close, sys_read, sys_write, sys_dup2), install them
into the syscall dispatch table so ring-3 code can call them via
`SYSCALL`. Would consist of five one-line dispatch-table entries
plus argument-marshaling glue.

**Deferred, not folded here.** Same discipline as #587-#590 §6:
scope-per-issue. The batch-wire is a distinct commit whose
provenance should not mix with any single body's landing. Also,
the batch-wire depends on `copy_from_user` / `copy_to_user`
infrastructure that R16.M3 does not yet include — those pass
paths for `sys_open`'s path_ptr and `sys_read/write`'s buf_ptr.

Filed as R16.M3 tail: `r16-m3-006-syscall-entry-batch-wire` (or
in the batch-wire epic if one is already open).

### 6.3 Relative-delta sub-test C instead of literal `refcount == 2`

**Proposal.** Sub-test C samples refcount BEFORE dup2 (call it
`R_before`), then after dup2 samples `R_after`, and asserts
`R_after == R_before + 1`. Avoids the preamble refcount reset
(§4.3.1).

**Rejected for #591, kept as fallback.** The literal `refcount == 2`
assertion is more reader-friendly: a reviewer immediately
understands "one fd from sys_open + one fd from dup2 = 2 references".
The relative-delta version reads as "the hold fired", which is
correct but less semantically anchored. Also, the preamble's
refcount reset is a small, contained normalization (3 instructions);
the literal assertion is worth those 3 instructions.

If a future revisit removes the refcount reset (e.g., because a
new invariant makes vnode refcount always fresh when a slot is
first vnode-pool-wired), sub-test C flips to the relative form
without changing its semantic content. Sub-test F's F.2
(root refcount decremented by 1) already uses the relative form,
so both styles are proven in the same witness.

### 6.4 Return `-EBADF` vs `-EINVAL` for dst out-of-range

**Proposal.** POSIX permits `EINVAL` for dst_fd out of range
(distinct from EBADF for "not a valid open fd"). Return -EINVAL
for the phase-2 failures.

**Rejected.** Linux `dup2(2)` returns EBADF uniformly. R17 userland
(porting glibc / musl) expects the Linux convention. Diverging here
would create a portability speed bump for the shell demo. Keep
uniform EBADF.

### 6.5 Fold `sys_dup` (one-arg) into this file

**Proposal.** POSIX dup(oldfd) is a compact wrapper: allocate a
free fd via `fd_alloc`, then dup2(oldfd, allocated). ~10 LOC of
composition.

**Rejected — out of R16.M3 scope.** `sys_dup` is not in R14B
Subsystem 13's issue list; it's an R17 addition. Landing it now
would exceed #591's scope. When sys_dup lands, it composes cleanly
over sys_dup2_body and fd_alloc (both frozen).

### 6.6 Move refcount++ before the entry copy (Hold before Copy)

**Proposal.** Swap phase 6 and 7 order.

**Rejected.** See §3.5's "Copy before Hold" justification. Both
orders are correct at R16.M3 (single-threaded), but "Copy first"
matches Linux and the R18 preemption port's lock-order needs.
Freezing "Copy then Hold" here is prescient.

### 6.7 Return the freed dst vnode_idx as diagnostic on close

**Proposal.** If dst was open, return the old vnode_idx (or a
sentinel meaning "close fired") somewhere observable.

**Rejected.** POSIX dup2 return type is `int` (fd on success,
-1 on error). No room for diagnostics. Witness sub-test F.2
provides the observability the design needs.

## 7. Invariants

### 7.1 fd_entry encoding preserved

`sys_dup2_body` READS the encoding twice (once for src, once for
dst's optional close), WRITES the encoding once (dst copy of src),
and never modifies the low-16 / high-48 boundary. #587 §3.2's
`entry = vnode_idx | (offset << 16)` remains the single source of
truth. The `and rax, 0xFFFF` at phase 5 (dst close) and phase 7
(shared hold) is the canonical decoder for the vnode_idx half.

### 7.2 Refcount conservation across dup2 lifecycle

For a dup2 that closes an open dst:
- Old dst vnode refcount: R_old → R_old - 1 (vfs_close side effect)
- Shared vnode refcount: R_shared → R_shared + 1 (phase 7 hold)
- Total refcount delta across the vnode pool: 0 (one released,
  one held).

For a dup2 where dst was previously free:
- Shared vnode refcount: R_shared → R_shared + 1 (phase 7 hold)
- Total refcount delta: +1 (one new reference added; the dst slot
  wasn't holding anything before).

For the src==dst no-op:
- Total refcount delta: 0 (no state mutation).

All three lifecycles preserve refcount consistency. Verified live
by sub-tests C (shared hold fires) and F.2/F.3 (old close + new
hold both fire).

### 7.3 Trust boundary — no downstream bounds check

Once `sys_dup2_body` has validated `src_fd in [3, 32)` and
`dst_fd in [3, 32)`, both fd_get / fd_set calls receive fds
that pre-satisfy their SIB `[rdi + rsi*8 + 168]` bound. Once the
src_entry has been confirmed non-zero, the vnode_idx it carries
is in `[1, 65535]` from the encoding (in practice `[1, 255]` from
vnode_alloc's VNODE_MAX bound). vfs_close and vnode_slot both
receive values pre-satisfying their own contracts.

### 7.4 sys_dup2_body register discipline

- rbx, r12, r13, r14, r15 are pushed in the prologue and popped
  in the epilogue. Any nested call MUST callee-save-preserve
  them. Currently verified for `fd_get` (leaf, no clobbers),
  `fd_set` (leaf, no clobbers), `vfs_close` (5-push prologue
  saves rbx/r12/r13/r14/r15 explicitly), `vnode_slot` (leaf, no
  clobbers).
- rax, rcx, rdx, rsi, rdi are caller-save scratch. Content across
  a nested call is undefined except for the callee's documented
  return in rax.

### 7.5 POSIX-conformant no-op semantics

`dup2(fd, fd)` on a valid open fd returns fd without state
mutation. Sub-test D verifies this. `dup2(bad_fd, bad_fd)` returns
-EBADF (phase 3's `entry == 0 → -EBADF` catches this before the
phase-4 no-op). Verified by inspection.

### 7.6 Byte-identical entry copy — no encoding drift

fd_set(dst_fd, src_entry) writes the WHOLE packed u64 —
vnode_idx AND offset — unchanged. Both fds now reference the same
"file description" in POSIX terms: shared vnode, shared offset.
This differs from dup(oldfd) which in the Linux kernel would
copy the file description POINTER; our packed encoding makes
the sharing eager (offset advances on either fd will NOT be
visible to the other — a divergence from POSIX file-description
sharing).

**Note on POSIX divergence.** At R16.M3 the packed encoding
stores offset in-line with vnode_idx per-fd. After dup2, if a
read on fd 3 advances its offset, fd 5's offset does NOT
advance — because the offsets live in separate fd_table slots.
POSIX requires the two fds to share a `struct file` and thus a
shared offset. This is a known R16.M3-vs-POSIX divergence
tracked in the R17 24-byte fd_entry widening (§6.4 of #587
mentions "R17 24-byte widening path"). At R17, the packed fd_entry
becomes a pointer to a shared file_description struct with the
offset moved out — and dup2 will copy the pointer, restoring
POSIX semantics. Filed for R17.

## 8. Cross-cutting risks

- **Sub-test C's refcount reset creates a witness-only surface
  where refcount is directly written.** If a future refactor
  changes the vnode layout (e.g., moves refcount to a different
  offset), sub-test C's `mov_w [rax + 4], rcx` must be updated in
  lockstep with vfs_open.pdx and vfs_close.pdx. Mitigation: `+4`
  appears at 4 sites — once in vfs_open, once in vfs_close, and
  twice in this witness (once for reset, several times for reads).
  Constant-tag proposal: introduce `VNODE_REFCOUNT_OFFSET = 4` in
  vnode_pool.pdx and reference symbolically. Not blocking on this
  issue but noted as an R16-tail cleanup.
- **Preamble's second sys_open("/") could fail if fd_alloc's
  scan-from-3 doesn't return 4.** fd_alloc scans linearly for the
  first zero slot; after the first sys_open takes fd=3, fd=4 is
  the next zero. Verified — no risk.
- **Sub-test F.2's relative check saves R_root_before in a
  callee-save register (r13) that survives across the sys_dup2
  call.** Since sys_dup2_body's own 5-push prologue saves r13,
  the outer witness's r13 (which held R_root_before) is preserved
  by the callee ABI. Verified. Alternative: spill to memory —
  overkill for R16.M3 witness idiom.
- **The refcount++ inside phase 7 could overflow the u16 field
  if a vnode is held by 2^16 fds simultaneously.** With
  FD_TABLE_MAX = 32, no single task can hold more than 32
  references from its own fd_table. Cross-task references (via
  file mmap, fork inheritance) grow the risk marginally but not
  past u16. When R18 preemption + multi-task fd sharing scales
  up, promote refcount to u32. Filed for R18.
- **A misaligned rsp during the preamble's mount_root_vnode call.**
  The preamble starts with `rsp % 16 == 8` (SysV entry). The first
  call is `mount_root_vnode` — the outer witness code path does
  NOT push anything before it, so rsp is unaligned. Mitigation:
  same as sys_write witness (which also calls mount_root_vnode
  first at line 3101) — mount_root_vnode has its own prologue
  handling the alignment. Verified by #590's successful boot.

## 9. LOC estimate

| File                                                       | LOC        |
|------------------------------------------------------------|------------|
| `src/kernel/core/syscall/handlers/sys_dup2.pdx` (new)      | ~120       |
|   - module boilerplate + constants + justification         |   ~40      |
|   - `sys_dup2_body` (~40 instructions)                     |   ~60      |
|   - inline comments                                        |   ~20      |
| `src/kernel/boot/kernel_main.pdx` (witness block + slab)   | ~170       |
|   - `_sys_dup2_witness_task` declaration                   |    ~5      |
|   - preamble (wire + reset + open fd=3 and fd=4)           |   ~50      |
|   - 6 sub-tests (D/A/B/C/E/F with F.1/F.2/F.3)             |   ~95      |
|   - inline comments + fail/success labels                  |   ~20      |
| `tools/boot_stub.S` (2 strings)                            | ~8         |
| 3 expected-output fingerprint files (1 marker each)        | ~3         |
| `design/kernel/r16-m3-005-sys-dup2.md` (this doc)          | (this)     |
| **Total executable / testing / test-data**                 | **~300**   |

Executable code path: ~120 LOC. Witness + fingerprint: ~181 LOC.

Sizing is slightly larger than #590 (~250 LOC total) because of:
- Two fd validation blocks vs one (+5 body LOC).
- Sub-test F's sub-cases F.1/F.2/F.3 (+30 witness LOC).
- Preamble's second sys_open("/") and refcount reset (+15 witness LOC).

Still comfortably within an R16.M3-body budget.

## 10. Tractability

**HIGH.**

- No paideia-as encoder gap. Every instruction used has landed
  precedent (§2.3).
- Composition of five already-witnessed primitives (`fd_get`,
  `fd_set`, `vfs_close`, `vnode_slot`, plus `sys_open_body` in the
  witness preamble) — the only novel logic is a
  triply-composed fd validation prologue and an inline refcount++
  that duplicates vfs_open's existing pattern.
- Witness storage is a single `.bss` blob (mirror of #590's
  `_sys_write_witness_task`) — no allocator dependency, no CR3 flip,
  no interrupt discipline, no scheduler init dependency.
- Marker line is contains-in-order — no fingerprint reorder risk
  across other smoke modes.
- The register discipline is SIMPLER than sys_read/sys_write:
  r14 (src_entry) does not morph, r15 (dst_entry) is used-then-
  dead cleanly, no shift-and-add arithmetic. Fewer places for a
  register-lifetime error.
- Sub-test F is the most complex sub-test of any R16.M3 body
  witness (three sub-sub-tests with save-and-relative-check
  arithmetic), but each sub-sub-test is orthogonal (fd_table copy,
  root-refcount decrement, x-refcount increment) — the pieces are
  independently readable.
- Sizing (~300 LOC total) is 20% larger than #590 (~250), still
  well within workerbee session budget.
- No cross-repo escalation risk (no paideia-as encoder growth).

Estimated implementation time: **one workerbee session**.
Estimated risk of regressing an existing smoke mode: **near-zero**
(purely additive: one new emit line, one new witness block, one
new .pdx module).

**Known follow-ups (do NOT block #591's landing)**:

- **vnode_hold factoring** (§6.1) — extract the inline
  refcount++ pattern from both vfs_open and sys_dup2. Blocked
  until #592 (fd inherit across fork) surfaces the third call-site.
- **R16.M3 SYSCALL entry batch-wire** (§6.2) — install all five
  R16.M3 syscall bodies into the dispatch table. Lands after
  copy_from_user / copy_to_user primitives are in place.
- **VNODE_REFCOUNT_OFFSET symbolic constant** (§8) — replace
  hard-coded `+4` at four call-sites with a shared constant.
  Small R16-tail cleanup.
- **R17 24-byte fd_entry widening** (§7.6) — restore POSIX
  file-description-sharing semantics. Large R17 follow-up.
- **Sub-test E' for dst-out-of-range** (§5.2 tail) — five-line
  witness extension if reviewer wants active coverage of the
  phase-2 validation. Optional.

## 11. References

- Issue: paideia-os#591
- Milestone: paideia-os R16.M3 (fd table + open/read/write/close/dup2)
- Prereq issues: #587 (sys_open — packed encoding freeze), #588
  (sys_close — fd-validation idiom), #589 (sys_read — 5-push
  prologue pattern), #590 (sys_write — sibling body), #576
  (vfs_close — refcount decrement), #571 (vnode_slot — pointer
  helper), #549 (fd_table embed)
- Successor issues: #592 (fd inherit across fork), #593
  (fd_cloexec on execve), #594 (`boot_r16_fd` smoke mode)
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 13, item 5
- Master plan: `design/milestones/r14b-master-plan.md` §M19 (VFS)
- Prior-art body pattern: `src/kernel/core/syscall/handlers/sys_write.pdx`
  (#590) — 5-push prologue with rbx/r12/r13/r14/r15, explicit
  register discipline, negative-errno u64 returns, packed
  fd_entry encoding.
- Prior-art witness pattern: `design/kernel/r16-m3-004-sys-write.md`
  §5 — `_*_witness_task` `.bss` blob + preamble with unlink+create
  + sub-tests + marker line + fingerprint insertion.
- POSIX reference: dup2(2) man page — the src==dst no-op branch,
  the close-newfd-first semantics, and the EBADF return codes.
