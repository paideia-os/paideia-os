---
issue: 593
milestone: R16.M3 (fd table + open/read/write/close/dup2)
subsystem: 13 — file-descriptor + open/read/write/close/dup2
topic: fd_cloexec on execve — sys_execve walks task.fd_table, closes fds marked FD_CLOEXEC
prereq:
  - "#555 (sys_execve_body — LANDED; the fresh-then-swap aspace body this doc extends with a pre-swap walker call)"
  - "#587 (sys_open — LANDED; freezes the packed fd_entry encoding this walker decodes)"
  - "#588 (sys_close — LANDED; establishes the vfs_close + fd_set(0) release discipline the walker reuses per-slot)"
  - "#571 (vnode_pool + vnode_slot — LANDED; used transitively via vfs_close)"
  - "#576 (vfs_close — LANDED; the per-slot close primitive the walker invokes)"
  - "#549 (fd_table embed — LANDED; provides the 168-byte offset + FD_TABLE_MAX = 32 the walker sweeps)"
  - "#592 (fd_inherit on fork — LANDED; freezes the fd-table walker shape this walker mirrors verbatim)"
blocks:
  - "sys_fcntl (F_SETFD / F_GETFD) — future R16-tail issue that will teach userspace to SET the CLOEXEC bit this walker consumes"
  - "R17 sys_clone / vfork — will call fd_cloexec_walker on CLONE_EXEC paths"
touching:
  - src/kernel/core/fs/fd_cloexec.pdx                 (new module — ~55 LOC incl. justification)
  - src/kernel/core/syscall/handlers/sys_execve.pdx   (+3 body LOC + justification note update)
  - src/kernel/boot/kernel_main.pdx                   (witness block ~120 LOC)
  - tools/boot_stub.S                                 (2 rodata additions: ok_msg, fail_msg)
  - tests/r14b/expected-boot-r14b-loader.txt          (marker: `R16 FD CLOEXEC OK`)
  - tests/r15/expected-boot-r15-process.txt           (marker)
  - tests/r15/expected-boot-r15-ring3.txt             (marker)
  - design/kernel/r16-m3-007-fd-cloexec.md            (this doc)
related:
  - design/kernel/r16-m3-006-fd-inherit-fork.md       (#592 — mirror walker shape; identical prologue, loop head, entry-extract guards)
  - design/kernel/r15-m6-004-sys-execve.md            (#555 — sys_execve_body composition: aspace_create + elf_lite_load + swap-commit)
  - design/kernel/r16-m3-001-sys-open.md              (#587 — packed fd_entry encoding: `entry = vnode_idx | (offset << 16)`; §3.2 §6.4 encoding extension budget)
  - design/kernel/r16-m3-002-sys-close.md             (#588 — vfs_close + fd_set(0) release discipline reused per marked slot)
  - design/kernel/r16-m1-007-vfs-close.md             (#576 — vfs_close semantics: idx==0 skip, idx>=256 skip, refcount underflow guard)
  - design/kernel/vfs-layout.md                       (#570 — refcount at vnode +4 (u16); §7.4 refcount semantics)
  - design/kernel/r15-m5-007-fd-table-embed.md        (#549 — FD_TABLE_OFFSET = 168, FD_TABLE_MAX = 32, sentinel-0 discipline)
  - design/kernel/task-struct-layout.md               (#564 — task_struct field layout; unchanged by this issue)
  - design/milestones/r14b-tactical-plan.md           §Subsystem 13, item 7
---

# R16-M3-007 — fd_cloexec on execve (#593)

## 1. Scope

Land the R16.M3 subsystem-13 issue #593: on a successful `execve`, close
every fd whose `FD_CLOEXEC` bit is set BEFORE the aspace swap commits.
POSIX semantics: `execve` replaces the process image but preserves the
fd table; the CLOEXEC flag opts a specific fd out of that preservation.

This issue lands two things:

1. A new walker helper `fd_cloexec_walker(task) -> ()` in
   `src/kernel/core/fs/fd_cloexec.pdx`. It mirrors `fd_inherit_hold`
   (#592) verbatim in prologue / loop head / entry-extract / defensive
   guards — the per-iteration body diverges from "refcount++" to
   "vfs_close + fd_set(0)".
2. A one-call glue insertion into `sys_execve_body` (#555) at the
   commit boundary: after `elf_lite_load` returns ELF_OK, before the
   PML4-store that swaps the aspace.

Because `sys_fcntl` (F_SETFD / F_GETFD) does not exist at R16.M3, the
witness sets the CLOEXEC bit by direct fd_table byte manipulation.
`sys_fcntl` is a future issue that will teach userspace to set the bit
this walker already knows how to consume.

```
sys_execve_body(current, image_ptr, image_len) -> {rax, rdx}
    ; step 1: r14 = old_pml4_pa
    ; step 2: r15 = aspace_create_user()    ; may fail → OOM return
    ; step 3: elf_lite_load(r15, image, len); may fail → teardown-new + return

    ; NEW step 3.5 (#593) — close CLOEXEC-marked fds
    mov  rdi, rbx                              ; current task
    call fd_cloexec_walker

    ; step 4: SUCCESS — commit swap
    mov  [rbx + 16], r15                       ; current->user_pml4_pa = new
    mov  rdi, r14
    call aspace_teardown                       ; drop old
    ; ... return {rax=0, rdx=e_entry} ...
```

and

```
fd_cloexec_walker(task) -> ()
    for rcx in [0..32):
        entry = task.fd_table[rcx]
        if entry == 0: continue                ; empty slot
        if bit_63(entry) == 0: continue        ; CLOEXEC clear — preserved
        vnode_idx = entry & 0xFFFF
        if vnode_idx == 0 or vnode_idx >= 256: ; defensive (§3.5)
            fd_set(task, rcx, 0)               ; clear slot anyway (malformed)
            continue
        vfs_close(vnode_idx)                   ; refcount-- (may fire vops_close)
        fd_set(task, rcx, 0)                   ; clear slot to sentinel-0-free
```

### 1.1 What this issue proves

- **fd_cloexec_walker is refcount-conservative.** For each CLOEXEC-marked
  fd, the walker drops the referenced vnode's refcount by exactly one
  and clears the slot. Sub-test C observes the refcount transition
  2 → 1 (parent held via fd[3] AND fd[4]; CLOEXEC-closes fd[3];
  refcount drops by one; fd[4] still holds).
- **The commit-boundary hook fires exactly on success.** Placing the
  call after `elf_lite_load`'s success gate ensures that if the ELF
  is malformed (as sys_execve_witness's sub-test B exercises), the
  walker never runs and the fd_table is preserved. This is the POSIX
  contract: CLOEXEC fires on successful execve, not on any attempted
  execve.
- **The packed fd_entry encoding admits a CLOEXEC bit at position 63
  without disturbing the vnode_idx extract.** The `and rax, 0xFFFF`
  frozen by #587 §3.2 continues to extract vnode_idx byte-identically
  in the presence of a CLOEXEC-marked entry. Compare with sub-test A
  where the CLOEXEC-marked entry passes the walker's bit-63 gate and
  extracts vnode_idx cleanly.
- **The bit-63 gate is exact.** Sub-test B observes fd[4] (CLOEXEC
  clear) preserved verbatim across execve; sub-test A observes fd[3]
  (CLOEXEC set) closed. Both cases through the same walker in the
  same invocation.
- **Non-preservation across execve.** Together with #592's inherit
  proof, we now cover both halves of the R16.M3 fd-table lifecycle
  across process boundaries: fork preserves-and-holds (#592), execve
  preserves-except-CLOEXEC (#593).

### 1.2 What this issue deliberately does NOT do

- **No sys_fcntl.** F_SETFD / F_GETFD is a future R16-tail issue.
  R16.M3 witness sets the CLOEXEC bit by direct fd_table mutation
  (§5.2). This is intentional: the walker's producer-independence is
  the design contract — any producer that lands a CLOEXEC-marked
  entry into fd_table (fcntl in the future, or the witness today)
  gets the same walker semantics.
- **No sys_read / sys_write offset-mask update.** The bit-63 CLOEXEC
  marker contaminates the offset extract `shr rcx, 16` at
  sys_read.pdx:85 and sys_write.pdx:92 by planting the marker into
  bit 47 of the extracted offset. At R16.M3 this is UNOBSERVABLE
  because (a) fcntl doesn't exist so no user-space code marks
  CLOEXEC and reads/writes on the same fd, (b) the witness never
  exercises read/write on a CLOEXEC-marked fd. The contamination
  becomes observable when sys_fcntl lands. The mask update is
  filed as a follow-up in §10.2, paired with sys_fcntl. Backtrack
  path is documented in §8. **This is not a stub** — the walker
  itself is fully correct; the deferred fix is in the offset
  decoder, not the walker.
- **No POSIX dup2-clears-CLOEXEC semantics.** POSIX specifies that
  `dup2(src, dst)` clears CLOEXEC on `dst` (only `dup3(src, dst,
  O_CLOEXEC)` preserves it, and `fcntl(F_DUPFD_CLOEXEC)` sets it
  fresh). Because #591's sys_dup2 copies the packed entry
  byte-identically, CLOEXEC on `src` propagates to `dst` — a POSIX
  divergence. Same class of divergence as #591 §7.6 (independent
  offsets). Both fixes are paired at the R17 24-byte fd_entry
  widening.
- **No CLOEXEC clearance on sys_close.** sys_close clears the entire
  slot to 0 (per #588 phase 4), which trivially clears the CLOEXEC
  bit. No new logic needed.
- **No sys_execve body rewrite.** The existing sys_execve_body #555
  is preserved as-is except for the 2-line glue (mov rdi, rbx; call
  fd_cloexec_walker) and the justification-string update. Register
  discipline, phase order, error handling all unchanged.
- **No sys_open extension.** #587's sys_open allocates a fd with
  entry = vnode_idx (bit 63 clear implicitly). Adding O_CLOEXEC as
  a flag interpretation is a future issue paired with sys_fcntl.
  The walker does not care how CLOEXEC got set — only that it did.
- **No rollback on fd_cloexec_walker failure.** The walker is void
  and has no observable failure mode — each fd is either closed or
  skipped. There is no partial-close cleanup to invent.
- **No lock discipline.** R16.M3 is single-threaded. When R18
  preemption lands, sys_execve will hold the per-task fd_table lock
  around the walker call — no in-body change needed.

## 2. Prereq check

### 2.1 What is in place

| Primitive           | Location                                                         | Contract used                                                                                                                                             |
|---------------------|------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------|
| `sys_execve_body`   | `core/syscall/handlers/sys_execve.pdx` (#555, LANDED)            | Fresh-then-swap body. #593 hooks a 2-line call between the `elf_lite_load` success gate and the swap-commit `mov [rbx+16], r15`.                            |
| `vfs_close`         | `core/fs/vfs_close.pdx` (#576, LANDED)                           | `(vnode_idx) -> u64`. Decrements refcount; on zero calls vops_close. Return value ignored per #588 §3.4 phase-3 discipline.                                  |
| `fd_set`            | `core/fs/fd_table.pdx` (#549, LANDED)                            | `(task, fd, val) -> ()`. Single SIB+disp store. Used to clear each closed slot to sentinel-0-free.                                                          |
| Packed fd_entry     | `design/kernel/r16-m3-001-sys-open.md` §3.2                     | `entry = vnode_idx (low 16) | offset (high 48)`. `and rax, 0xFFFF` extracts vnode_idx. This issue reserves bit 63 for CLOEXEC — see §3.1 for the encoding extension. |
| `sys_open_body`     | `core/syscall/handlers/sys_open.pdx` (#587, LANDED)              | Used twice in witness preamble to seed fd[3] and fd[4] with real vnode-backed entries.                                                                     |
| `task_new`          | `core/proc/task_new.pdx` (LANDED)                                | Used in witness preamble to build a real parent with a live user_pml4_pa @ +16 (so sys_execve_body's aspace-swap has a valid old_pml4 to save).             |
| `vnode_slot`        | `core/fs/vnode_pool.pdx:148` (#571, LANDED)                      | Used by witness for baseline + sub-test C refcount assertions.                                                                                              |
| Mount + tmpfs       | LANDED through #586                                              | Witness preamble uses the same wire-and-trim pattern as #591/#592.                                                                                          |
| `_shell_bin_start`  | `tools/boot_stub.S` (from #555 witness — LANDED)                 | Valid ELF64 blob. Reused verbatim for sys_execve_body's ELF payload.                                                                                        |
| `witness_path_tmp_x`| `tools/boot_stub.S:680` (#589, LANDED)                            | `"/tmp/x\0"`. Reused verbatim.                                                                                                                              |
| `witness_name_tmp` / `witness_name_any` | `tools/boot_stub.S:517, 525`                   | `"tmp\0"`, `"x\0"`. Reused verbatim.                                                                                                                        |

### 2.2 What is NOT in place — just two rodata strings

**#593 introduces zero new rodata beyond the two OK/FAIL messages.**
Path strings, directory name strings, ELF blob — all pre-existing.
The witness uses `task_new` for its parent (not a `.bss` blob) and
recovers the child slab via `_pid_table`.

### 2.3 Encoder gaps

**None.** fd_cloexec_walker uses only mnemonics proven pervasively:

| Mnemonic                            | Proven at                                                     |
|-------------------------------------|---------------------------------------------------------------|
| `push r64` / `pop r64`              | Every callee-save prologue.                                   |
| `mov r64, r64`                      | Pervasive.                                                    |
| `mov r64, [r64 + r64*8 + disp]`     | fd_get, fd_alloc, sys_fork copy loop, fd_inherit_hold.        |
| `mov r64, imm64`                    | vfs_read/write sentinel, sys_close sentinel — proven.         |
| `cmp r64, imm32`                    | Pervasive.                                                    |
| `test r64, r64`                     | Standard SF-testing idiom. See use notes below.               |
| `jb` / `jae` / `je` / `jne` / `jns` / `jmp` | Every control-flow site.                              |
| `and r64, imm32`                    | `entry & 0xFFFF` — sys_dup2 phases 5/7, sys_read phase 3, sys_write phase 3, fd_inherit_hold. |
| `call sym`                          | Pervasive.                                                    |
| `add r64, imm8`                     | Loop increment — sys_fork copy loop, fd_inherit_hold.         |

The one mnemonic new relative to #592 is `test r64, r64` + `jns`
(jump if not sign — bit 63 is the sign bit of a u64, used as the
CLOEXEC test). `test` is universal x86-64; `jns` is one of the
standard Jcc conditions. If a paideia-as gap surfaces, an equivalent
`mov rcx, imm64` (CLOEXEC_MASK) + `test rax, rcx` + `jz` fallback
is trivial. See §3.4 for the exact instruction sequence.

## 3. Design

### 3.1 fd_entry encoding extension — bit 63 = CLOEXEC

R16.M3 #587 §3.2 froze:
```
    fd_entry (u64):
    ┌────────────────────────────────────┬───────────────────┐
    │ bits [16, 64):  file offset (u48)  │ bits [0, 16): idx │
    └────────────────────────────────────┴───────────────────┘
```

#593 extends this by reserving bit 63 for `FD_CLOEXEC`:
```
    fd_entry (u64):
    ┌───┬────────────────────────────────┬───────────────────┐
    │ C │ bits [16, 63):  offset  (u47)  │ bits [0, 16): idx │
    └───┴────────────────────────────────┴───────────────────┘
      bit 63 = CLOEXEC (1 = close on exec, 0 = preserve)
```

**Vnode_idx extract is byte-identical.** `and rax, 0xFFFF` still
extracts bits [0, 16) verbatim — the reserved bit 63 sits far outside
the vnode_idx window. Every existing extractor (sys_close phase 3,
sys_read phase 3, sys_write phase 3, sys_dup2 phases 5 & 7,
fd_inherit_hold body) continues to work byte-identically. Zero
downstream churn on the vnode-idx side.

**Offset extract is CONTAMINATED — deferred fix.** `shr rax, 16` at
sys_read.pdx:85 and sys_write.pdx:92 shifts a bit-63 CLOEXEC marker
into bit 47 of the extracted offset. For any fd currently marked
CLOEXEC AND subsequently used by sys_read/sys_write BEFORE execve,
the shifted-in bit 47 pushes the read/write offset by 2^47 (128 TiB) —
past tmpfs's single-page bound, causing vfs_read to short-return 0
bytes and vfs_write to reject.

At R16.M3 this contamination is unobservable because:
- sys_fcntl does not exist — user-space cannot mark CLOEXEC.
- The witness sets CLOEXEC directly but never invokes
  sys_read/sys_write on the marked fd.
- fd_cloexec_walker is the only code path that reads the CLOEXEC
  bit, and it does so via `test / jns` on the WHOLE entry (bit 63
  test) — not via `shr rax, 16`. The walker's own offset extract is
  unused (the walker doesn't advance offsets).

The mask update on sys_read/sys_write is filed as a follow-up issue
paired with sys_fcntl (see §10.2). Backtrack path if a bug surfaces
before sys_fcntl lands: add `shl rcx, 17; shr rcx, 17` (2 instructions)
immediately after the `shr rcx, 16` in each site. Zero encoder-gap
risk.

**Offset budget reduction.** The offset shrinks from 48 bits (256 TiB)
to 47 bits (128 TiB). Both are gigantic relative to R16.M3's tmpfs
single-page (4 KiB) bound — no realistic file at R16.M3 approaches
even 2^28 bytes.

### 3.2 File and module structure

**New file**: `src/kernel/core/fs/fd_cloexec.pdx`. Sits alongside
`fd_inherit.pdx` (#592):

```
src/kernel/core/fs/
    fd_table.pdx      (#549 — fd_get/fd_set/fd_alloc leaf helpers)
    fd_inherit.pdx    (#592 — walker: refcount++ across a task's whole fd_table)
    fd_cloexec.pdx    <-- THIS ISSUE (walker: close + fd_set(0) for CLOEXEC-marked slots)
    mount.pdx
    vfs_open.pdx
    vfs_close.pdx
    ...
```

Module name: `FdCloexec`. Public export: `fd_cloexec_walker`.

**Why a new file and not fd_inherit.pdx.** Layer discipline. Both
walkers share the loop-head shape, but their per-iteration bodies
differ semantically (hold vs release + clear). Keeping each
walker in its own module preserves single-responsibility per
justification block and matches the fd_inherit precedent — one
module per walker semantic.

**Why not inline in sys_execve.pdx.** Same three reasons as #592
§6.1: future reuse (R17 sys_clone with CLOEXEC-honoring semantics),
layer discipline (sys_execve already composes 4 primitives —
aspace_create + elf_lite_load + swap + teardown), and testability
(the walker can be exercised independently by a synthetic fd_table
scenario if a bug ever surfaces).

### 3.3 fd_cloexec_walker — register discipline

Three persistent values must survive the two nested calls per
iteration (vfs_close, fd_set):
- `task` (arg), for the `[task + rcx*8 + 168]` load AND for the
  `fd_set(task, fd, 0)` at the tail of each per-slot body
- loop counter, needs a callee-save reg to survive both nested calls
- `entry` — actually NO, entry is decoded before vfs_close so it's
  dead across the nested calls. rax scratch works.

2-push prologue (rbx + r12) — same as fd_inherit_hold. rsp%16==0
at both nested call sites (SysV entry has rsp%16==8; 2 pushes → 0).

| Reg | Role                                                                                                        |
|-----|-------------------------------------------------------------------------------------------------------------|
| rbx | `task` (task_struct pointer). Survives all loop iterations and both nested calls per iteration.              |
| r12 | Loop counter (0..32). Survives both nested calls. Same idiom as fd_inherit_hold's outer save.                 |
| rax | Scratch: fd_entry load, CLOEXEC-bit test, and-decode, vfs_close return (ignored).                             |
| rdi | Argument scratch: vnode_idx (vfs_close), task ptr (fd_set).                                                   |
| rsi, rdx | Argument scratch: fd (fd_set), val=0 (fd_set).                                                            |
| rcx | Scratch (unused in this walker).                                                                              |

### 3.4 fd_cloexec_walker — body sequence

```asm
; ================================================================
; fd_cloexec_walker(task) -> ()
;   rdi = task (task_struct*, non-NULL). No return value.
;
; Effects:
;   For each rcx in [0, 32): if child.fd_table[rcx] has bit 63 set
;   (FD_CLOEXEC), call vfs_close on the encoded vnode_idx (dropping
;   the vnode's refcount by one, potentially firing vops_close),
;   then fd_set(task, rcx, 0) to clear the slot to sentinel-0-free.
;
; Register discipline:
;   rbx = task              (callee-save, survives two nested calls)
;   r12 = loop counter      (callee-save, survives two nested calls)
; ================================================================
fd_cloexec_walker:
    push rbx
    push r12

    mov  rbx, rdi                         ; rbx = task
    mov  r12, 0                           ; r12 = loop counter

fd_cloexec_loop:
    cmp  r12, 32                          ; FD_TABLE_MAX
    jae  fd_cloexec_done

    mov  rax, [rbx + r12*8 + 168]         ; rax = task.fd_table[r12]
    cmp  rax, 0
    je   fd_cloexec_next                  ; empty slot — skip

    test rax, rax                          ; SF = bit 63
    jns  fd_cloexec_next                   ; CLOEXEC clear — preserved

    ; --- CLOEXEC set: extract vnode_idx and close ---
    and  rax, 0xFFFF                       ; rax = vnode_idx (low 16)
    cmp  rax, 0
    je   fd_cloexec_clear_slot             ; malformed (idx==0): clear anyway
    cmp  rax, 256                          ; VNODE_MAX
    jae  fd_cloexec_clear_slot             ; malformed (idx OOR): clear anyway

    mov  rdi, rax
    call vfs_close                         ; refcount--; may fire vops_close

fd_cloexec_clear_slot:
    mov  rdi, rbx
    mov  rsi, r12
    xor  rdx, rdx
    call fd_set                            ; task.fd_table[r12] = 0

fd_cloexec_next:
    add  r12, 1
    jmp  fd_cloexec_loop

fd_cloexec_done:
    pop  r12
    pop  rbx
    ret
```

**Instruction count**: ~22 across the body (2 push + 2 mov + loop
head + 4 gates + close-call + clear-block + 2 loop tail + 2 pop + ret).
Slightly heavier than fd_inherit_hold's ~18 because we have two
nested calls per active iteration instead of one.

### 3.5 Defensive-guard rationale (malformed idx path)

Same `cmp rax, 0; je` + `cmp rax, 256; jae` guards as fd_inherit_hold
(#592 §3.5). Two twists specific to CLOEXEC:

1. **The malformed-idx path clears the slot anyway** (jumps to
   `fd_cloexec_clear_slot`, not `fd_cloexec_next`). Rationale: a
   fd_entry with CLOEXEC set AND a malformed vnode_idx is an
   intent-signaled release — "close this fd" — that we honor by
   clearing the slot, even though we can't legally invoke vfs_close
   on the malformed idx. This is defense in depth: post-execve the
   fd_table should NOT contain any CLOEXEC-marked entries, whether
   they were originally well-formed or not.
2. **sys_fork_witness's seed values re-appear here.** Those values
   (0xDEADBEEFCAFEBABE, 0x1122334455667788, 0xF00DBEEF00000001)
   have random bit-63 states:
   - 0xDEADBEEFCAFEBABE: bit 63 = 1 (0xD = 0b1101, MSb of top byte set) — CLOEXEC "set"; vnode_idx = 0xBABE (OOR).
   - 0x1122334455667788: bit 63 = 0 (0x1 = 0b0001) — CLOEXEC "clear"; skipped by bit-63 gate.
   - 0xF00DBEEF00000001: bit 63 = 1 (0xF = 0b1111) — CLOEXEC "set"; vnode_idx = 1 (root vnode, IN-range).
   
   These seed values are consumed by sys_fork_witness which runs
   at kernel_main.pdx:1527 — BEFORE sys_execve_witness (line 1323)
   and long before fd_cloexec_witness. So this walker does NOT run
   on the seed values in the base R16.M3 witness ordering. However,
   IF a future issue reorders witnesses OR IF sys_fork_witness itself
   gains an execve step, the seed values would exercise:
   - 0xDEAD... → CLOEXEC set, OOR idx → clear slot without vfs_close.
   - 0xF00D... → CLOEXEC set, idx=1 (root) → vfs_close(1), refcount--.
   The second case would erroneously drop the root vnode's refcount.
   This is a latent cross-witness coupling documented in §8 and
   deferred to the seed-cleanup follow-up (#592 §10.2).

### 3.6 sys_execve_body edit

The change is minimal — one 2-line insertion at the boundary between
`elf_lite_load` success and the swap-commit:

**Before** (sys_execve.pdx line 56-70):
```asm
        // ===== step 3: elf_lite_load into fresh aspace =====
        mov rdi, r15;
        mov rsi, r12;
        mov rdx, r13;
        call elf_lite_load;
        cmp rax, 0;                             // ELF_OK
        jne sys_execve_load_fail;

        // ===== step 4: SUCCESS — commit swap =====
        mov [rbx + 16], r15;                    // current->user_pml4_pa = new_pml4
```

**After**:
```asm
        // ===== step 3: elf_lite_load into fresh aspace =====
        mov rdi, r15;
        mov rsi, r12;
        mov rdx, r13;
        call elf_lite_load;
        cmp rax, 0;                             // ELF_OK
        jne sys_execve_load_fail;

        // ===== step 3.5 (#593): close CLOEXEC-marked fds =====
        mov rdi, rbx;                           // arg: current task
        call fd_cloexec_walker;

        // ===== step 4: SUCCESS — commit swap =====
        mov [rbx + 16], r15;                    // current->user_pml4_pa = new_pml4
```

**Register safety across the new call.**
- `rbx` (current) — callee-save; fd_cloexec_walker's 2-push prologue
  preserves it AND uses it internally.
- `r14` (old_pml4) — callee-save; walker preserves.
- `r15` (new_pml4) — callee-save; walker preserves.
- `r12` (image_ptr), `r13` (image_len) — callee-save; walker
  preserves.
- `rax, rcx, rdx, rdi, rsi` — caller-save. All are re-derived
  fresh in subsequent step-4 code (the `mov [rbx + 16], r15` uses
  only rbx and r15; the subsequent teardown call sets rdi = r14).

**Stack alignment.** sys_execve enters with rsp%16==8. Its own
5-push prologue → rsp%16==0. The `call fd_cloexec_walker`
therefore sees rsp%16==0 as SysV requires. fd_cloexec_walker's
own 2 pushes make rsp%16==0 at its own `call vfs_close` and
`call fd_set` sites (vfs_close needs it for its own nested call;
fd_set is a leaf but the alignment is preserved for uniformity).

**Failure paths unaffected.** fd_cloexec_walker returns void with
no sentinel semantics — every fd slot either closes+clears or is
skipped. There is no error path. sys_execve's existing
`sys_execve_load_fail` and `sys_execve_oom` labels remain
reachable ONLY from the earlier steps (before fd_cloexec_walker
could run) — POSIX-correct behavior: CLOEXEC does not fire on
failed execve.

**Justification-block update.** sys_execve.pdx's existing
justification string calls out "Six steps: (1) prologue... (2)
aspace_create... (3) elf_lite_load... (4) SUCCESS commit swap...".
Extend to include step 3.5 (fd_cloexec_walker) between (3) and (4),
noting the POSIX success-gated semantics.

### 3.7 Hook-point argument — why after elf_lite_load, before swap

Three placements are structurally admissible:

1. **Before aspace_create_user** (i.e., before step 2): would fire
   CLOEXEC on every execve ATTEMPT, including OOM failures. Violates
   POSIX (CLOEXEC fires only on successful execve).
2. **After elf_lite_load success, before swap-commit** (chosen): the
   earliest point at which sys_execve is committed to succeed
   (elf_lite_load was the last failable step). Preserves the atomic
   commit: if a future issue adds a failable step between the walker
   and the swap, the CLOEXEC fires but the aspace never swaps —
   still POSIX-conformant (the process's fd state is what execve
   would have installed; the failure surfaces as a returned error
   code without an aspace swap).
3. **After swap-commit, before teardown**: also POSIX-correct. But
   the walker doesn't touch aspace at all — placing it here provides
   no ordering benefit and mixes concerns (touching fd_table AFTER
   the aspace side has completed makes the atomicity boundary less
   obvious).

Chosen: (2) — matches the parent brief and preserves the "walker
runs iff execve is committed to succeed" invariant.

**Ordering with vfs_close's vops_close dispatch.** vfs_close may
fire vops_close for a refcount-zero'd vnode (per #576). For tmpfs
that's `tmpfs_close` (which per #586 is a no-op / does nothing
memory-freeing). For future backend fs's with heavier close paths
(fsync, disk I/O), the ordering "before aspace swap" means the
close runs in the OLD aspace's CR3 context. This is fine — vops
implementations operate on kernel-side buffers (vnode + inode pool),
not on user-visible mappings.

### 3.8 File contents (skeleton)

```pdx
// src/kernel/core/fs/fd_cloexec.pdx — R16-M3-007 (#593)
// fd_cloexec_walker: walk task->fd_table[0..32] and for each entry
// with bit 63 (FD_CLOEXEC) set, invoke vfs_close on the encoded
// vnode_idx and clear the slot to sentinel-0-free via fd_set.
// Called by sys_execve_body's tail (after elf_lite_load success,
// before the aspace swap commits) to enforce POSIX FD_CLOEXEC
// semantics.
//
// Consumes the packed fd_entry encoding extended by this issue
// (#593 §3.1):
//   entry = vnode_idx (low 16) | offset (bits 16-62) | CLOEXEC (bit 63)
// The walker decodes CLOEXEC via `test rax, rax; jns` (SF = bit 63)
// and vnode_idx via `and rax, 0xFFFF`.
//
// See design/kernel/r16-m3-007-fd-cloexec.md for full contract.

module FdCloexec = structure {
  pub let FD_TABLE_OFFSET       : u64 = 168        // matches fd_table.pdx (#549)
  pub let FD_TABLE_MAX          : u64 = 32         // matches fd_table.pdx (#549)
  pub let VNODE_MAX             : u64 = 256        // matches vnode_pool.pdx (#571)

  // ==========================================================================
  // fd_cloexec_walker — walk task's fd_table, close CLOEXEC-marked fds.
  //
  // Input:
  //   rdi = task (task_struct*, non-NULL)
  //
  // Output:
  //   No return value. rax undefined.
  //
  // Side effects:
  //   For each entry in task.fd_table[0..32] with bit 63 set:
  //     - vfs_close(entry & 0xFFFF) — refcount--, may fire vops_close.
  //     - fd_set(task, fd, 0)       — clear slot to sentinel-0-free.
  //   Entries with bit 63 clear are preserved verbatim. Entries with
  //   bit 63 set BUT malformed vnode_idx (0 or >= 256) skip the
  //   vfs_close call but still clear the slot (defense in depth —
  //   see design §3.5).
  // ==========================================================================
  pub let fd_cloexec_walker : (u64) -> () !{mem} @{} =
    fn (task: u64) -> unsafe {
      effects: {mem},
      capabilities: {},
      justification: "R16-M3-007 (#593): fd_cloexec_walker — for each fd in task.fd_table[0..32] with bit 63 (CLOEXEC) set, invoke vfs_close on the encoded vnode_idx and clear the slot to sentinel-0-free via fd_set. Called by sys_execve_body's tail after elf_lite_load returns ELF_OK and before the aspace swap commits (POSIX: CLOEXEC fires iff execve succeeds). 2-push prologue (rbx, r12) aligns rsp%16==0 for two nested calls per active iteration (vfs_close, fd_set) and preserves task ptr + loop counter across both. Loop: r12 style callee-save counter (0..32). Each iteration loads task.fd_table[r12] into rax; the `cmp rax, 0; je` gate skips empty slots. For non-empty entries, `test rax, rax; jns` gates on bit 63 (SF = bit 63 of rax) — jns skips when CLOEXEC clear, preserving the entry verbatim; falls through when CLOEXEC set. For CLOEXEC-set entries, `and rax, 0xFFFF` extracts vnode_idx per #587 §3.2 encoding. Two defensive guards follow that jump to fd_cloexec_clear_slot (NOT fd_cloexec_next, so the slot IS cleared): `cmp rax, 0; je` (skip the vfs_close on the reserved sentinel slot 0), and `cmp rax, 256; jae` (skip vfs_close on out-of-VNODE_MAX indices). vfs_close(vnode_idx) drops refcount by one; return value ignored per #588 §3.4 phase-3 discipline (every entry from an R16.M3-legal producer round-trips safely through vfs_close). Then fd_set(task, r12, 0) clears the slot. Register discipline: rbx (task), r12 (loop counter) both callee-save-preserved through vfs_close (5-push prologue) and fd_set (leaf); rax, rdi, rsi, rdx caller-save scratch. Non-CLOEXEC branch: two-instruction hot path (`test rax, rax; jns fd_cloexec_next`) minimizes overhead for the common case of a non-marked entry. Bit-63 encoding budget: #587 §3.2's offset half shrinks from 48 to 47 bits (128 TiB, gigantic vs R16.M3's 4 KiB tmpfs single-page bound); vnode_idx extract at `and rax, 0xFFFF` unchanged. See design/kernel/r16-m3-007-fd-cloexec.md for full contract, including §3.7 hook-point argument and §10.2 sys_read/sys_write offset-mask follow-up paired with sys_fcntl.",
      block: {
        push rbx;
        push r12;

        mov rbx, rdi;                          // rbx = task
        mov r12, 0;                            // r12 = loop counter

      fd_cloexec_loop:
        cmp r12, 32;                           // FD_TABLE_MAX
        jae fd_cloexec_done;

        mov rax, [rbx + r12*8 + 168];          // rax = task.fd_table[r12]
        cmp rax, 0;
        je  fd_cloexec_next;                   // empty slot — skip

        test rax, rax;                         // SF = bit 63
        jns fd_cloexec_next;                   // CLOEXEC clear — preserve

        // CLOEXEC set: extract vnode_idx and close
        and rax, 0xFFFF;                       // rax = vnode_idx
        cmp rax, 0;
        je  fd_cloexec_clear_slot;             // malformed (idx=0): clear anyway
        cmp rax, 256;                          // VNODE_MAX
        jae fd_cloexec_clear_slot;             // malformed (OOR): clear anyway

        mov rdi, rax;
        call vfs_close;                        // refcount-- (may fire vops_close)

      fd_cloexec_clear_slot:
        mov rdi, rbx;
        mov rsi, r12;
        xor rdx, rdx;
        call fd_set;                           // task.fd_table[r12] = 0

      fd_cloexec_next:
        add r12, 1;
        jmp fd_cloexec_loop;

      fd_cloexec_done:
        pop r12;
        pop rbx;
        ret
      }
    }
}
```

## 4. Witness task_struct — decision

### 4.1 Choice: reuse task_new for parent + retain slab after sys_execve

Same as sys_execve_witness (kernel_main.pdx:1323, LANDED) and
fd_inherit_witness (kernel_main.pdx:3399, LANDED). Reasons:

- **sys_execve_body needs a real aspace on the target task.** Its
  step 1 loads `[rbx + 16]` (user_pml4_pa) as old_pml4, and step 4
  writes new_pml4 back. A .bss task-shaped blob has zero at +16 →
  aspace_teardown UB. task_new populates +16 via
  aspace_create_user.
- **Sub-tests access task.fd_table AFTER sys_execve_body returns.**
  task_new's slab persists across the execve (execve swaps the
  aspace, NOT the slab) — the fd_table lives at offset +168 within
  the KERNEL-side task_struct, not in user-space. So the witness
  can read `[r14 + fd*8 + 168]` post-execve to observe the walker's
  effects.
- **Preamble uses sys_open_body(parent, "/tmp/x") twice** to seed
  fd=3 AND fd=4 — exactly what fd_cloexec_walker needs to
  demonstrate (one CLOEXEC-marked, one not).

### 4.2 Slab declaration — NOT required

No `_fd_cloexec_witness_task` .bss slab needed. Parent is task_new'd
(real aspace, real slab). No child task involved (execve doesn't
create a child — it in-place mutates the parent).

### 4.3 Preamble: wire + trim + task_new + open ×2 + set CLOEXEC

Byte-identical to #592's fd_inherit witness preamble UP TO the first
sys_open call. That includes:
- Wire root vnode's vnode-pool slot (ops_ptr + backend_ptr).
- Recover tmp_idx via tmpfs_lookup(root, "tmp").
- Wire /tmp's vnode-pool slot.
- Trim /tmp/x back to fresh 0-size state: tmpfs_unlink + tmpfs_create.
- Wire fresh x_idx's vnode-pool slot.
- Reset x_idx.refcount to 0 (state normalization for the literal
  sub-test C assertion "refcount == 1 post-execve" to hold cleanly).
- task_new(NULL) → parent.

Then diverges from #592:
- sys_open_body(parent, "/tmp/x", 0, 0) → fd = 3 (baseline).
  x_idx.refcount = 1 post-open.
- **Manually set bit 63 of parent.fd_table[3]** (CLOEXEC marker):
  ```asm
  mov  rax, [r14 + 24 + 168]         ; parent.fd[3] (offset 3*8=24)
  mov  rcx, 0x8000000000000000       ; CLOEXEC_MASK
  or   rax, rcx
  mov  [r14 + 24 + 168], rax
  ```
  This is the R16.M3-legal substitute for sys_fcntl(F_SETFD).
- sys_open_body(parent, "/tmp/x", 0, 0) → fd = 4 (no CLOEXEC).
  x_idx.refcount = 2 post-open.
- Baseline sanity: assert x_idx.refcount == 2 pre-execve.

### 4.4 Vnode-pool wiring workaround — same shape as #590/#591/#592

Same defensive re-wire per #590 §4.4. Three instructions per slot
(vnode_slot + two stores).

### 4.5 Position in kernel_main

Insert **after** `fd_inherit_witness_done:` (line 3527) and **before**
the wrmsr at line 3529. This is byte-adjacent to the fd_inherit
placement — the natural spot in the R16.M3 witness ordering, and
the same slot as the previously landed R16.M3 witnesses (each
witness slots between the prior one's `_done:` label and the wrmsr).

## 5. Test canary — kernel_main witness block

### 5.1 Preamble

- Wire root/tmp/x vnode-pool slots defensively (§4.4).
- Trim /tmp/x back to fresh 0-size state via tmpfs_unlink +
  tmpfs_create.
- Reset x_idx.refcount to 0.
- task_new(NULL) → parent (r14).
- sys_open_body(parent, "/tmp/x", 0, 0) → fd = 3, x_idx.refcount = 1.
- Set bit 63 of parent.fd_table[3] (CLOEXEC marker).
- sys_open_body(parent, "/tmp/x", 0, 0) → fd = 4, x_idx.refcount = 2.
- Baseline sanity: assert x_idx.refcount == 2.

### 5.2 Sub-tests

**Sub-test act: sys_execve_body(parent, _shell_bin_start, image_len)**

```asm
mov  rdi, r14                            ; parent
lea  rsi, [rip + _shell_bin_start]
lea  rax, [rip + _shell_bin_end]
sub  rax, rsi                            ; image_len
mov  rdx, rax
call sys_execve_body                     ; rax = 0 (ELF_OK), rdx = e_entry
cmp  rax, 0
jne  fd_cloexec_witness_fail             ; execve must succeed
```

**Sub-test A: parent.fd_table[3] == 0 (CLOEXEC closed).**

```asm
mov  rax, [r14 + 24 + 168]               ; parent.fd[3] @ 168 + 3*8
cmp  rax, 0
jne  fd_cloexec_witness_fail
```

Proves: fd_cloexec_walker's per-slot close+clear fired on the
CLOEXEC-marked slot.

**Sub-test B: parent.fd_table[4] != 0 (preserved).**

```asm
mov  rax, [r14 + 32 + 168]               ; parent.fd[4] @ 168 + 4*8
cmp  rax, 0
je   fd_cloexec_witness_fail
```

Proves: the bit-63 gate correctly skipped the non-CLOEXEC entry,
preserving fd[4] verbatim. THE key negative assertion.

**Sub-test C: x_idx.refcount == 1 (dropped by CLOEXEC close).**

```asm
mov  rdi, r15                            ; r15 = x_idx (from preamble)
call vnode_slot
xor  rcx, rcx
mov_w rcx, [rax + 4]
cmp  rcx, 1
jne  fd_cloexec_witness_fail
```

Proves: vfs_close was called exactly ONCE inside fd_cloexec_walker
(refcount transitioned 2 → 1). Combined with sub-test A (fd[3]
cleared) and sub-test B (fd[4] preserved), this pins down the walker
to the exact per-slot behavior.

### 5.3 Marker

On A/B/C all green:

```
R16 FD CLOEXEC OK
```

Emitted via `uart_puts` on `fd_cloexec_ok_msg`. Marker added to all
three R16.M3-tempo expected-output files, immediately after the
existing `R16 FD INHERIT OK` line.

### 5.4 Witness assembly (complete block sketch)

```asm
; ============================================================
; R16-M3-007 (#593): fd_cloexec witness — preamble + execve + 3 sub-tests
; ============================================================
fd_cloexec_witness:
    ; --- Preamble: wire root, tmp_idx; unlink+create x; wire x_idx;
    ;               reset x_idx refcount; task_new; open fd=3;
    ;               mark CLOEXEC; open fd=4 ---
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
    je   fd_cloexec_witness_fail
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
    jne  fd_cloexec_witness_fail

    mov  rdi, r12
    lea  rsi, [rip + witness_name_any]
    mov  rdx, 1
    mov  rcx, 1                                 ; VNODE_TYPE_REG
    call tmpfs_create
    cmp  rax, 0
    je   fd_cloexec_witness_fail
    cmp  rax, 0xFFFF
    je   fd_cloexec_witness_fail
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
    je   fd_cloexec_witness_fail
    mov  r14, rax                               ; r14 = parent slab

    ; --- sys_open_body(parent, "/tmp/x", 0, 0) → fd = 3 ---
    mov  rdi, r14
    lea  rsi, [rip + witness_path_tmp_x]
    xor  rdx, rdx
    xor  rcx, rcx
    call sys_open_body
    cmp  rax, 3
    jne  fd_cloexec_witness_fail

    ; --- Set bit 63 of parent.fd_table[3] (CLOEXEC marker) ---
    mov  rax, [r14 + 24 + 168]                  ; parent.fd[3]
    mov  rcx, 0x8000000000000000                ; CLOEXEC_MASK (bit 63)
    or   rax, rcx
    mov  [r14 + 24 + 168], rax

    ; --- sys_open_body(parent, "/tmp/x", 0, 0) → fd = 4 (no CLOEXEC) ---
    mov  rdi, r14
    lea  rsi, [rip + witness_path_tmp_x]
    xor  rdx, rdx
    xor  rcx, rcx
    call sys_open_body
    cmp  rax, 4
    jne  fd_cloexec_witness_fail

    ; --- Baseline sanity: x_idx.refcount == 2 pre-execve ---
    mov  rdi, r15
    call vnode_slot
    xor  rcx, rcx
    mov_w rcx, [rax + 4]
    cmp  rcx, 2
    jne  fd_cloexec_witness_fail

    ; --- Act: sys_execve_body(parent, _shell_bin_start, image_len) ---
    mov  rdi, r14
    lea  rsi, [rip + _shell_bin_start]
    lea  rax, [rip + _shell_bin_end]
    sub  rax, rsi
    mov  rdx, rax                               ; image_len
    call sys_execve_body
    cmp  rax, 0                                 ; require ELF_OK
    jne  fd_cloexec_witness_fail

    ; --- Sub-test A: parent.fd_table[3] == 0 ---
    mov  rax, [r14 + 24 + 168]
    cmp  rax, 0
    jne  fd_cloexec_witness_fail

    ; --- Sub-test B: parent.fd_table[4] != 0 ---
    mov  rax, [r14 + 32 + 168]
    cmp  rax, 0
    je   fd_cloexec_witness_fail

    ; --- Sub-test C: x_idx.refcount == 1 ---
    mov  rdi, r15
    call vnode_slot
    xor  rcx, rcx
    mov_w rcx, [rax + 4]
    cmp  rcx, 1
    jne  fd_cloexec_witness_fail

    ; --- All green ---
    lea  rdi, [rip + fd_cloexec_ok_msg]
    call uart_puts
    jmp  fd_cloexec_witness_done

fd_cloexec_witness_fail:
    lea  rdi, [rip + fd_cloexec_fail_msg]
    call uart_puts

fd_cloexec_witness_done:
```

**Register plan for the outer witness frame:**

| Reg | Role                                                    |
|-----|---------------------------------------------------------|
| r12 | tmp_idx during preamble; dead thereafter                 |
| r14 | parent slab pointer (from task_new); persistent           |
| r15 | fresh x_idx from tmpfs_create; persistent                 |

Same idiom as #592's outer register plan, minus r13 (no child slab
to retain — execve doesn't produce a child).

## 6. Alternatives considered

### 6.1 Bit-stealing (chosen) vs cloexec bitmap in task_struct

**Chosen: bit-stealing at bit 63 of the packed fd_entry.**

**Alt considered**: add a per-task u32 CLOEXEC bitmap at a new
task_struct offset (e.g., +424 immediately after fd_table), one
bit per fd.

**Bitmap approach — merits:**
- **No encoding freeze extension.** The #587 §3.2 encoding stays
  intact; offset field remains 48 bits.
- **No sys_read / sys_write follow-up.** No offset-contamination
  hazard — the CLOEXEC bit lives in a separate memory word, invisible
  to the offset extract.
- **POSIX dup2-clears-CLOEXEC is easy.** dup2 zeros the bitmap
  slot for dst; bit-stealing (chosen) requires masking the entry
  before fd_set.
- **fcntl F_SETFD / F_GETFD are trivial** — set/clear/read a bit
  in the bitmap.

**Bitmap approach — costs:**
- **task_struct layout change.** Adds 4 bytes at +424, shifting no
  existing fields but claiming previously-unused .bss space. Would
  require a task-struct-layout.md update to freeze the new field
  offset (small, but a coordinated design-doc edit).
- **Walker becomes bit-hop-per-fd.** Each iteration must load a bit
  from the bitmap AND load the fd_entry — two loads per non-empty
  slot instead of one. Marginal cost.

**Why bit-stealing chosen:** The parent brief explicitly prescribed
Option 1 (bit-stealing) on the rationale "no task_struct layout
change." The offset-contamination follow-up is real but scoped:
sys_read/sys_write get a 2-instruction mask update paired with
sys_fcntl. R16.M3 witness ships unblocked. The bitmap is the
better long-term shape and is preserved as a fallback backtrack
if the follow-up churn on sys_read/sys_write becomes contentious
(§10.2).

### 6.2 Body edit vs new helper

**Chosen: new helper `fd_cloexec_walker` in
`src/kernel/core/fs/fd_cloexec.pdx`.**

**Alt considered**: inline the loop in sys_execve_body as an
in-body step 3.5.

**Rejected — three reasons.** Byte-identical to #592 §6.1:

1. **Future reuse.** R17 sys_clone / vfork will call
   fd_cloexec_walker on CLONE_EXEC paths. Filed on first use is
   standard practice.
2. **Layer discipline.** sys_execve_body already composes 4
   primitives (aspace_create_user, elf_lite_load, PML4 store,
   aspace_teardown). Adding a 5th responsibility inline mixes
   concerns; factoring keeps sys_execve_body's justification block
   from ballooning past its existing readability limit.
3. **Testability.** fd_cloexec_walker can be exercised
   independently (synthetic fd_table with mixed CLOEXEC states,
   observe close+clear deltas) if a bug ever surfaces. An inline
   loop is only testable through the full execve path.

### 6.3 Hook point — before vs after aspace swap

**Chosen: after elf_lite_load success, before swap-commit** (§3.7).

**Rejected alt**: after swap-commit, before teardown. Same
POSIX-correctness but muddies the commit atomicity boundary.

### 6.4 Skip the defensive guards

**Rejected — §3.5's malformed-entry argument.** A CLOEXEC-set entry
with a malformed vnode_idx is defense in depth: we clear the slot
regardless (honoring the "close on exec" intent) but skip vfs_close
(which would fail-silently anyway per its own idx==0 / idx>=256
guards).

### 6.5 fd_set-clear FIRST, then vfs_close

**Rejected.** Ordering mirrors sys_close's phase 3 → phase 4
(vfs_close then fd_set(0)). Reversing would violate the "close the
vnode before releasing the slot pointer to it" ordering that
underpins sys_close's justification. Zero benefit; a needless
divergence.

### 6.6 Fuse fd_cloexec_walker + fd_inherit_hold into a shared walker

**Rejected.** The two walkers share a loop-head skeleton but their
per-iteration bodies are semantically opposite (hold vs release +
clear). Fusing would require a walker-callback dispatch or a mode
flag, both introducing branch overhead in a hot path. The
duplication of the loop-head is ~10 LOC — well under the fusion
overhead. Same rationale as sys_read + sys_write remaining separate
despite their near-identical structures (§#590 justification).

### 6.7 Emit `R16 FD EXEC CLOEXEC OK` for clarity

**Rejected.** Marker style follows the existing R16.M3 convention:
`R16 SYS OPEN OK`, `R16 SYS DUP2 OK`, `R16 FD INHERIT OK`. The
symmetric marker for this issue is `R16 FD CLOEXEC OK`. Extra
words (EXEC, or ON EXECVE) add noise without disambiguating
against any other R16 marker.

## 7. Invariants

### 7.1 CLOEXEC drops fds on successful execve, ONLY

For every fd `i` in `[0, 32)`:
- Pre-execve: fd_table[i] = entry_i (possibly with CLOEXEC bit set).
- **On sys_execve_body success (rax = ELF_OK):**
  - If entry_i had bit 63 set: post-execve fd_table[i] = 0.
  - If entry_i had bit 63 clear: post-execve fd_table[i] = entry_i
    (byte-identical preservation).
- **On sys_execve_body failure (rax != 0):** fd_table[i] = entry_i
  regardless of CLOEXEC (walker never runs).

### 7.2 Refcount conservation across execve

Let `N_close` = count of fd slots with CLOEXEC bit set at execve
time. On success:
- Pool-wide refcount delta: `-N_close` (each CLOEXEC-marked fd
  drops its vnode's refcount by one).
- For each vnode V referenced by exactly one CLOEXEC-marked fd and
  no other holds: post-execve V.refcount = 0, vops_close fired.
- Non-CLOEXEC fds preserve their entries — vnode refcounts they
  hold are UNCHANGED.

Symmetric to fd_inherit_hold's `+N_hold` invariant (#592 §7.1).

### 7.3 fd_cloexec_walker register discipline

- rbx and r12 pushed in prologue and popped in epilogue.
- Two nested calls per active iteration (vfs_close, fd_set) — both
  preserve rbx and r12 per their own contracts:
  - vfs_close: 5-push prologue (rbx, r12, r13, r14, r15) —
    preserves all of ours.
  - fd_set: leaf function (single store + ret) — no clobbers.
- rax, rcx, rdx, rdi, rsi caller-save scratch — undefined across
  nested calls except for the documented rax return of vfs_close
  (ignored).

### 7.4 sys_execve_body register discipline (post-#593)

Unchanged from #555. rbx, r12, r13, r14, r15 preserved through the
5-push prologue and used by the surrounding steps 2/3/4. The new
`call fd_cloexec_walker` sees rsp%16==0 (SysV alignment satisfied)
and does not mutate rbx/r14/r15 per fd_cloexec_walker's own 2-push
prologue.

### 7.5 Trust boundary — walker is defensive against malformed entries

Same discipline as fd_inherit_hold: entry == 0 skips; bit-63 clear
skips (preserved); bit-63 set with vnode_idx == 0 or vnode_idx >=
256 clears the slot without vfs_close. No failure mode; no
witness-visible side effect for entries lacking CLOEXEC.

### 7.6 fd_table durability across aspace swap

The fd_table lives at task_struct offset +168 — KERNEL memory
(inside _task_pool, per task_pool.pdx). aspace_teardown drops
USER-space mappings (per aspace_teardown's contract) but does NOT
touch the task_struct. Post-execve, the fd_table is READABLE by
the witness through the same task pointer that was passed to
sys_execve_body. Sub-tests A and B rely on this durability.

## 8. Cross-cutting risks

- **sys_read / sys_write offset contamination when CLOEXEC bit is
  set.** As detailed in §1.2 and §3.1: `shr rax, 16` at
  sys_read.pdx:85 and sys_write.pdx:92 leaks the bit-63 CLOEXEC
  marker into bit 47 of the extracted offset. UNOBSERVABLE at
  R16.M3 (no fcntl; witness never reads/writes CLOEXEC-marked
  fds). Backtrack path: 2-instruction `shl rcx, 17; shr rcx, 17`
  fix per site — no encoder-gap risk, no witness fingerprint
  churn (byte-identical for all pre-existing witnesses because
  none exercises a CLOEXEC-marked fd through read/write). Filed
  as follow-up paired with sys_fcntl (§10.2).
- **POSIX dup2-clears-CLOEXEC divergence.** #591's sys_dup2 copies
  the packed entry byte-identically, so CLOEXEC on src propagates
  to dst — POSIX-divergent. Same class as #591 §7.6 (independent
  offsets). Fix path: mask off bit 63 during the fd_set(dst,
  src_entry) at sys_dup2 phase 6. Deferred to the R17 24-byte
  fd_entry widening or paired with sys_fcntl.
- **sys_fork_witness seed-value latent hazard.** As discussed
  in §3.5, the seed values 0xDEADBEEFCAFEBABE and 0xF00DBEEF00000001
  have bit 63 set. At R16.M3, sys_fork_witness runs BEFORE
  sys_execve_witness (line 1527 vs 1323), and no execve fires on
  those seeded fd_tables — so fd_cloexec_walker never sees them.
  IF a future issue reorders witnesses OR adds an execve into
  sys_fork_witness, the 0xF00D... seed would erroneously drop root
  vnode's refcount by one and clear the slot. Tracked as part of
  the sys_fork_witness seed-cleanup follow-up (#592 §10.2 also
  references this).
- **fd_cloexec_walker on step 3.5 fires BEFORE aspace swap.** In
  the OLD aspace's CR3 context. This is fine at R16.M3 (tmpfs
  vops_close is a no-op), but future backend fs's with heavier
  close paths would run their close hooks in the pre-swap aspace.
  Mitigation: if this becomes a hazard, move the hook to AFTER
  the swap-commit (§6.3 rejected alt is a valid backtrack).
- **The `test rax, rax; jns` idiom depends on bit 63 == sign bit
  in x86-64.** Universally true for u64 in the SysV ABI. No
  encoder gap; but note the semantic subtlety in the walker's
  code comment for future readers.
- **task_new inside the witness may fail (OOM).** With ~7 prior
  task_new callers before this witness, and a 32-slot pid pool,
  the margin is comfortable (~25 slots free). Same as #592 §8.
- **The sys_execve body edit changes the justification-block
  string.** Downstream tooling that snapshots the string must
  re-baseline. Same as #592 §8.

## 9. LOC estimate

| File                                                       | LOC        |
|------------------------------------------------------------|------------|
| `src/kernel/core/fs/fd_cloexec.pdx` (new)                  | ~55        |
|   - module boilerplate + constants                         |   ~10      |
|   - justification block                                    |   ~10      |
|   - `fd_cloexec_walker` body (~22 instructions)            |   ~25      |
|   - inline comments                                        |   ~10      |
| `src/kernel/core/syscall/handlers/sys_execve.pdx` (edit)   | ~5         |
|   - +2 lines body (mov rdi, rbx; call fd_cloexec_walker)   |    ~2      |
|   - justification string update (rewrite one sentence)     |    ~3      |
| `src/kernel/boot/kernel_main.pdx` (witness block)          | ~120       |
|   - preamble (wire + trim + task_new + open ×2 + mark CLOEXEC) |  ~60   |
|   - baseline refcount==2 sanity                            |    ~7      |
|   - sys_execve_body call                                   |    ~10     |
|   - 3 sub-tests A/B/C                                      |   ~25      |
|   - inline comments + fail/success labels                  |   ~18      |
| `tools/boot_stub.S` (2 strings)                            | ~8         |
| 3 expected-output fingerprint files (1 marker each)        | ~3         |
| `design/kernel/r16-m3-007-fd-cloexec.md` (this doc)        | (this)     |
| **Total executable / testing / test-data**                 | **~190**   |

Executable code path: ~60 LOC (fd_cloexec.pdx + sys_execve.pdx
delta). Witness + fingerprint: ~131 LOC.

Sizing is on par with #592 (~180 LOC total) — 3 sub-tests, minimal
walker helper, one syscall body edit.

Comfortably below any R16.M3-body budget.

## 10. Tractability

**HIGH.**

- No paideia-as encoder gap. Every mnemonic proven pervasively
  (§2.3); the only new-relative-to-#592 idiom is `test rax, rax;
  jns` which is standard x86-64.
- Composition of two already-witnessed primitives (vfs_close from
  #576, fd_set from #549). No novel logic — the loop wrapper is a
  duplicate of fd_inherit_hold's shape; the per-iteration body is
  a slight generalization of sys_close's phase 3 → phase 4.
- Register discipline is IDENTICAL to fd_inherit_hold: 2-push
  prologue, rbx = task, r12 = loop counter. Two nested calls per
  active iteration instead of one (vfs_close, fd_set) — both
  established callee-save-clean.
- Witness storage is zero .bss (uses task_new for parent).
- Marker line is contains-in-order — no fingerprint reorder risk.
- Sizing (~190 LOC total) matches #592 (~180 LOC).
- No cross-repo escalation risk (no paideia-as encoder growth).
- One documented cross-witness coupling (§8: sys_fork_witness seed
  values with bit-63 set — WOULD trigger walker paths IF witness
  order changes; benign in current order).
- One documented deferred follow-up (§10.2: sys_read/sys_write
  offset mask paired with sys_fcntl).

Estimated implementation time: **one workerbee session** (same
tempo as #592).
Estimated risk of regressing an existing smoke mode: **near-zero**
(purely additive: one new module, three-line sys_execve edit, one
new witness block, one new marker line).

### 10.1 Where to hook into sys_execve — the direct answer to the parent brief

**After the `jne sys_execve_load_fail;` at
`src/kernel/core/syscall/handlers/sys_execve.pdx:58`, before the
`mov [rbx + 16], r15;` swap-commit at line 61.** Two-line insertion:

```asm
mov rdi, rbx;                           // arg: current task
call fd_cloexec_walker;
```

Rationale (§3.7): earliest point at which sys_execve is committed
to succeed (elf_lite_load was the last failable step); preserves
the POSIX "CLOEXEC fires iff execve succeeds" contract; keeps
fd_table mutation ordered before the aspace swap.

### 10.2 Known follow-ups (do NOT block #593's landing)

- **sys_read / sys_write offset mask** — add `shl rcx, 17; shr
  rcx, 17` (2 instructions) after each site's `shr rcx, 16` to
  mask the CLOEXEC bit out of the extracted offset. Paired with
  sys_fcntl (which is the first producer that will land CLOEXEC
  on an fd from user space AND enable subsequent user-issued
  reads/writes on it). Backtrack path if a hazard surfaces
  earlier: apply now. Zero encoder-gap risk.
- **sys_fcntl F_SETFD / F_GETFD** — teaches userspace to set the
  CLOEXEC bit this walker consumes. R16-tail issue.
- **sys_dup2 POSIX CLOEXEC-clear semantics** — mask bit 63 during
  fd_set(dst, src_entry) at sys_dup2 phase 6. Paired with either
  the R17 24-byte fd_entry widening or with sys_fcntl (depending
  on which lands first).
- **sys_fork_witness seed-value cleanup** — replace
  0xDEADBEEFCAFEBABE / 0xF00DBEEF00000001 with either vnode-legal
  values (idx in [1, 256), bit 63 clear) or skip the seed
  entirely (the fd_inherit AND fd_cloexec witnesses now cover
  fd_table copy correctness at a semantic level).
- **vnode_hold factoring** (per #591 §6.1) — extract the inline
  refcount++ pattern into a shared `vnode_hold(idx)` helper. Not
  blocking; still open from #592.
- **VNODE_MAX + VNODE_REFCOUNT_OFFSET symbolic constants** —
  replace hard-coded 256 / +4 across the fs modules.
- **CLOEXEC bitmap alternative** (§6.1) — if the sys_read /
  sys_write mask update becomes contentious, backtrack to a
  per-task u32 bitmap at task_struct +424. Larger design churn
  but cleaner long-term shape.
- **R17 sys_clone / vfork CLOEXEC semantics** — CLONE_EXEC path
  reuses fd_cloexec_walker verbatim.

## 11. References

- Issue: paideia-os#593
- Milestone: paideia-os R16.M3 (fd table + open/read/write/close/dup2)
- Prereq issues: #555 (sys_execve_body — fresh-then-swap aspace),
  #587 (sys_open — packed encoding freeze), #588 (sys_close —
  vfs_close + fd_set(0) discipline), #576 (vfs_close — refcount
  decrement), #571 (vnode_slot helper), #549 (fd_table embed),
  #592 (fd_inherit_hold — mirror walker shape)
- Successor issues: sys_fcntl (F_SETFD/F_GETFD), sys_dup2 CLOEXEC
  clearance, R17 sys_clone / vfork
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 13, item 7
- Master plan: `design/milestones/r14b-master-plan.md` §M19 (VFS)
- Prior-art body pattern:
  `src/kernel/core/syscall/handlers/sys_execve.pdx` (#555) —
  5-push prologue, phase-composed body, rbx=current /
  r14=old_pml4 / r15=new_pml4 discipline preserved unchanged by
  this issue.
- Prior-art walker helper pattern:
  `src/kernel/core/fs/fd_inherit.pdx` (#592) — 2-push prologue,
  r12 loop counter, defensive vnode_idx guards. Mirrored verbatim.
- Prior-art per-slot release pattern:
  `src/kernel/core/syscall/handlers/sys_close.pdx` (#588) —
  phase 3 (vfs_close) + phase 4 (fd_set 0). Reused per-iteration.
- POSIX reference: execve(2) — "File descriptors open in the
  calling process image shall remain open in the new process
  image, except for those whose close-on-exec flag FD_CLOEXEC
  is set. For those file descriptors that remain open, all
  attributes of the open file description, including file locks
  (see fcntl(2)), remain unchanged." R16.M3 honors the
  close-on-exec half via this walker.
