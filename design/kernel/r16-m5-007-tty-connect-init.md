---
issue: 608
milestone: R16.M5 (TTY / cooked line discipline)
subsystem: 15 — TTY / cooked line discipline
topic: tty_connect_init — publish _tty0 into a task's fd_table[0/1/2] and lift _tty0.refcount by 3
prereq:
  - "#602 (R16.M5-001 tty_init — LANDED; publishes _tty0 as a live CHRDEV vnode idx in a u64 slot, low 16 bits carry the index, initial refcount=1)"
  - "#603 (R16.M5-002 tty_vops_table — LANDED; wires _tty0.ops_ptr → &_tty_vops so a downstream sys_read(0) / sys_write(1) reaches tty_read / tty_write via vops dispatch)"
  - "#606 (R16.M5-005 tty_read — LANDED; the cooked-mode reader that init's fd 0 will end up reaching once R17's SYSCALL entry lands)"
  - "#607 (R16.M5-006 tty_write — LANDED; the newline-expanding writer that init's fd 1/2 will end up reaching once R17's SYSCALL entry lands; also this issue's kernel_main insertion point is immediately after tty_write_witness_done at line 4841)"
  - "#549 (R15-M5-007 fd_table embed — LANDED; freezes FD_TABLE_OFFSET=168, FD_TABLE_MAX=32, provides fd_set/fd_get with a single SIB+disp addressing form used verbatim here)"
  - "#587 (R16-M3-001 sys_open — LANDED; froze the packed fd_entry encoding this issue writes verbatim into slots 0/1/2: vnode_idx in bits [0,16), offset=0 in bits [16,64))"
  - "#592 (R16-M3-006 fd_inherit_hold — LANDED; the structural precedent for `refcount++ per fd_table slot` — this issue's refcount+=3 walker mirrors its `vnode_slot + mov_w [+4]` idiom exactly, minus the loop)"
blocks:
  - "#609 (R16.M5-CLOSER — the composed 'init writes to fd 1, echo appears on UART' smoke; requires this issue's fd wire before it can call sys_write(1, ...) through the vops chain)"
  - "R17 kernel_launch_init (#620) — the real init bring-up that supersedes this issue's dedicated-witness-task pattern; #620 will call tty_connect_init(_init_task) directly at the end of task_new(_init) but before ring-3 return, replacing the witness slab with the real init TCB. The tty_connect_init primitive shipped here is directly reusable — no signature change, no body change."
touching:
  - src/kernel/core/tty/connect.pdx                          (new file — ~65 LOC incl. justification)
  - src/kernel/boot/kernel_main.pdx                          (witness block ~90 LOC + _tty_connect_witness_task slab ~5 LOC; insertion after tty_write_witness_done at line 4842)
  - tools/boot_stub.S                                        (2 rodata additions: tty_connect_ok_msg, tty_connect_fail_msg)
  - tests/r14b/expected-boot-r14b-loader.txt                 (marker `R16 TTY CONNECT OK` after `R16 TTY WRITE OK`)
  - tests/r15/expected-boot-r15-ring3.txt                    (marker)
  - tests/r15/expected-boot-r15-process.txt                  (marker)
  - design/kernel/r16-m5-007-tty-connect-init.md             (this doc)
related:
  - design/kernel/r16-m5-001-tty-vnode-alloc.md              (#602 — §3.3 sets _tty0.refcount = 1 at init; this issue is the first refcount++ event on _tty0; see §3.5 for the refcount ceiling argument)
  - design/kernel/r16-m5-002-tty-vops-table.md               (#603 — wires _tty0.ops_ptr so the fd_table entries this issue publishes actually dispatch through the CHRDEV vops when a syscall consumes them)
  - design/kernel/r16-m3-001-sys-open.md                     (#587 — §3.2 froze the packed fd_entry encoding (vnode_idx low 16 | offset high 48). This issue writes the same encoding into fd_table[0/1/2] without going through fd_alloc — direct slot assignment for reserved stdio slots.)
  - design/kernel/r16-m3-006-fd-inherit-fork.md              (#592 — the structural precedent for a "walk N slots, refcount++ each referenced vnode" pattern; this issue reuses the vnode_slot + narrow load/inc/store idiom minus the loop, since the count is known to be 3.)
  - design/kernel/r15-m5-007-fd-table-embed.md               (#549 — freezes FD_TABLE_OFFSET=168 and the SIB+disp addressing this issue uses in three consecutive fd_set-shaped writes.)
  - design/milestones/r14b-tactical-plan.md                  §Subsystem 15 line ~1600, item 7 (this issue's plan pointer)
---

# R16-M5-007 — `tty_connect_init`: publish `_tty0` into a task's fd_table[0/1/2] (#608)

## 1. Scope

Land the seventh R16.M5 subsystem-15 issue: a leaf helper that
plugs the singleton TTY vnode `_tty0` into a task's stdio slots
(fd 0/1/2) and bumps `_tty0.refcount` by 3 to account for the
three new holds.

```
tty_connect_init(task_ptr) -> u64
    rdi = task_ptr           (task_struct*)
    rax = 0                  on success
    rax = 0xFFFFFFFFFFFFFFFF on failure (_tty0 == 0 — tty_init never ran)

    side effects (on success):
      task_ptr->fd_table[0] = packed_entry(_tty0)
      task_ptr->fd_table[1] = packed_entry(_tty0)
      task_ptr->fd_table[2] = packed_entry(_tty0)
      _vnode_pool[_tty0 & 0xFFFF].refcount += 3
```

The packed entry stored in each slot is the same u64 encoding
frozen by #587 §3.2:

```
bits [ 0, 16):  vnode_idx     = _tty0 & 0xFFFF
bits [16, 64):  file_offset   = 0    (stdio starts at offset 0)
```

Because `_tty0` is a u64 with the u16 idx in the low 16 bits and
zero everywhere else (per #602 §3.2), the packed entry value is
literally `[rip + _tty0]` — no shift, no OR. This is the same
zero-cost identity as sys_open's Phase-3 store when its
`r12` == `vnode_idx` with `offset=0`.

### 1.1 The parent-brief acceptance vs. what R16.M5 can actually witness

The issue-body's literal acceptance criterion is:

> **init's sys_write(1, ..) goes through tty.**

At R16.M5 that AC cannot be evaluated end-to-end for two reasons:

1. **The init task does not exist yet.** #620 (R17) is what
   creates the first user-mode task. At R16.M5, all "tasks" are
   either kernel witnesses (`.bss` slabs) or the idle TCB.
2. **SYSCALL entry is not yet wired.** Even if init existed, its
   `sys_write(1, ...)` from ring-3 would trap into a
   non-installed handler. The R16.M3 syscall bodies
   (`sys_open`, `sys_read`, `sys_write`, ...) are all
   witness-callable only until an R17-tempo wiring issue
   installs them into the SYSCALL dispatch table.

The **witness scope** for #608 is therefore the same reduction
every R16 subsystem has used successfully:

> Prove the **primitive** — `tty_connect_init(task_ptr)` populates
> `fd_table[0/1/2]` with the correct packed entry and lifts
> `_tty0.refcount` by 3 — on a **dedicated witness task slab**,
> and rely on the composition (vops wired at #603, tty_write body
> proven at #607, sys_write body proven at #590) to guarantee that
> the R17 bring-up path composes without further R16 rework.

The end-to-end "user writes to fd 1, echo appears on UART" test
is the R16.M5 CLOSER smoke (#609) once the tty_connect wire lands,
composed through the tty_write path #607 already witnessed.

### 1.2 What this issue proves

- **Direct-slot fd write bypasses fd_alloc for the reserved 0/1/2
  slots.** Unlike sys_open which scans `[3, 32)` for a free slot
  (#549 fd_alloc discipline), fd 0/1/2 are the reserved stdio
  triplet — they must be written directly, without allocator
  round-trip. This issue is the first codepath in the kernel that
  writes the reserved slots.
- **`fd_set(task, 0, entry)` works with the SIB+disp form when
  `fd=0`.** The addressing computation `[rdi + rsi*8 + 168]`
  with `rsi=0` collapses to `[rdi + 168]` — the base+disp form
  the encoder already emits for fd_set's single instruction. No
  new encoder work, no `imm=0`-specific edge case.
- **`_tty0.refcount` can be atomically bumped by more than 1 in a
  single primitive.** Every prior refcount bump (vfs_open, vfs_close,
  sys_dup2, fd_inherit_hold) increments by exactly 1. This issue's
  `+3` is a bulk increment that still fits in the u16 refcount
  field (see §3.5 for the ceiling argument).
- **The packed fd_entry encoding composes with `_tty0`'s
  representation.** Because `_tty0` stores the u16 idx in the low
  16 bits of a u64 with zeros above, the packed entry for a
  fresh-open (offset=0) IS `_tty0` verbatim. No shift, no OR, no
  synthesis — a single `mov rax, [rip + _tty0]` produces the exact
  bit pattern the three fd_set writes need.

### 1.3 What this issue deliberately does NOT do

- **No init task creation.** #620 (R17) is what creates
  `_init_task` and calls `tty_connect_init(_init_task)` as part
  of user-mode bring-up. The witness at §5 uses a dedicated
  `_tty_connect_witness_task : [u64; 278]` `.bss` slab, mirroring
  the #587/#588/#589/#590/#591 witness-task pattern verbatim.
- **No SYSCALL entry wiring.** Even after this issue lands, calling
  `sys_read(0, ...)` or `sys_write(1, ...)` from ring-3 does
  nothing — the dispatch table is not yet installed. That is R17's
  concern.
- **No fd 3+ population.** Only fd 0/1/2 are written. Slots 3..31
  stay at 0 (the "free" sentinel per #549 §3.4). This matches
  POSIX init's convention.
- **No dup2 or O_CLOEXEC handling on the three slots.** The
  packed entry stored here has no flags byte; the encoding
  frozen by #587 §3.2 is idx+offset only. Flag bits (like
  CLOEXEC) live in a separate `_fd_cloexec_bitmap` per task —
  #593 (fd_cloexec_walker) already ships that discipline. This
  issue does NOT set any CLOEXEC bits: stdio is inheritable
  across execve by POSIX convention.
- **No error path if `task_ptr` is NULL.** The primitive is called
  from a boot-time witness (this issue) or from #620's init
  bring-up (a compile-time guaranteed non-NULL fresh task_struct).
  Adding a NULL guard would be defensive noise the trust boundary
  doesn't require. #620's callsite will pass `&_init_task` — a
  `.bss`-resident struct with an address known at link time.
- **No refcount overflow guard.** §3.5 argues the ceiling never
  binds in practice (`u16` cap = 65535; this bumps by 3, once).
  A future NPROC×FD_TABLE_MAX audit at R18+ may formalize the
  bound if multi-tty lands.
- **No devfs binding of `_tty0` to `/dev/tty0`.** `_tty0`'s
  name_slot_idx stays `VNODE_IDX_NONE` per #602. Devfs is an R18+
  concern; `/dev/tty0` path resolution is not required for fd
  0/1/2 wiring, because we write the fd slots directly with the
  vnode idx (no path traversal involved).

## 2. Prereq check

### 2.1 What is in place

| Primitive                     | Location                                                   | Contract used                                                                                                                    |
|-------------------------------|------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------|
| `_tty0`                       | `core/tty/init.pdx:23` (#602, LANDED)                      | u64 slot; low 16 bits = vnode idx (u16), upper 48 = 0. Sentinel value 0 = "tty_init never ran".                                    |
| `vnode_slot(idx)`             | `core/fs/vnode_pool.pdx:148-159` (#571, LANDED)            | `(idx: u64) -> &_vnode_pool[idx * 64]`. Leaf; no callee-save touched; no bounds check by policy.                                    |
| Fd-entry encoding (#587 §3.2) | Documented at design/kernel/r16-m3-001-sys-open.md         | `entry = vnode_idx (low 16) | offset (high 48)`. This issue emits `entry = _tty0` verbatim (offset=0 in high 48 by construction).  |
| `fd_set`-shape store          | `core/fs/fd_table.pdx:36` (#549, LANDED)                   | Single SIB+disp store `mov [rdi + rsi*8 + 168], rdx`. This issue uses **inline** stores at fd=0/1/2 with rsi=const and rdx=entry. |
| `fd_get` (for witness only)   | `core/fs/fd_table.pdx:22` (#549, LANDED)                   | Single SIB+disp load `mov rax, [rdi + rsi*8 + 168]`. Used in sub-tests A/B/D to read back the three writes.                        |
| Refcount narrow load/store    | `core/fs/fd_inherit.pdx:65-67` (#592, LANDED)              | `mov_w rcx, [rax + 4]` / `mov_w [rax + 4], rcx` — the u16 refcount at vnode +4. This issue uses the identical idiom, +3 not +1.    |
| Witness `.bss` task slab      | `_fd_witness_task` @ `kernel_main.pdx:5365` (#549)         | 278-u64 `.bss` blob = 2224 bytes covering the full task_struct extent (+168+256 = 424 bytes minimum; 278 u64s is the current shape sanctioned by every R16.M3 witness). This issue adds one more: `_tty_connect_witness_task`. |
| Insertion point               | `kernel_main.pdx:4841-4843` (post-#607 witness done)       | The `pop r12` at line 4842 closes the tty_write witness's push. This issue inserts immediately after, before the R14b-m5-002 wrmsr block at line 4844. |

### 2.2 What is NOT in place

- **No `src/kernel/core/tty/connect.pdx` file.** New module in the
  existing `core/tty/` directory (created by #602). This is the
  seventh (and last real R16.M5 subsystem-15) tty module.
- **No `_tty_connect_witness_task` slab.** Added alongside the
  five existing `_sys_*_witness_task` slabs at
  `kernel_main.pdx:5373-5408` (see §4.2).
- **No `tty_connect_ok_msg` / `tty_connect_fail_msg` in
  `tools/boot_stub.S`.** Appended after `tty_write_ok_msg` /
  `tty_write_fail_msg` (currently at boot_stub.S line ~812 per
  #607's touching list).
- **No `R16 TTY CONNECT OK` marker in the three fingerprint
  files.** Inserted after `R16 TTY WRITE OK` (line 58 in the
  process fingerprint — verified by grep).
- **`_init_task` does NOT exist.** #620 creates it. This issue
  stays independent of that landing: the primitive
  `tty_connect_init(task_ptr)` accepts an arbitrary task_ptr and
  #620's callsite will pass `&_init_task` unchanged.

### 2.3 Encoder gaps

**None.** Every mnemonic used has landed precedent:

| Mnemonic                        | Proven at                                                                     |
|---------------------------------|-------------------------------------------------------------------------------|
| `push r64` / `pop r64`          | Ubiquitous.                                                                   |
| `mov [reg + imm], reg` (u64)    | `fd_table.pdx:36` (fd_set body); trivially generalizes to imm=168/176/184.    |
| `mov rax, [rip + sym]`          | Ubiquitous.                                                                   |
| `mov r64, r64`                  | Ubiquitous.                                                                   |
| `cmp r64, imm32`                | Ubiquitous.                                                                   |
| `je` / `jne` / `jmp`            | Ubiquitous.                                                                   |
| `mov_w rcx, [reg + imm]`        | `fd_inherit.pdx:65` (refcount narrow load).                                    |
| `mov_w [reg + imm], rcx`        | `fd_inherit.pdx:67` (refcount narrow store).                                   |
| `add rcx, imm8`                 | Ubiquitous (`add r12, 1` in every loop). `add rcx, 3` is a trivial imm8 delta.|
| `call sym`                      | Ubiquitous.                                                                   |
| `ret`                           | Ubiquitous.                                                                   |

No SIB gymnastics (all three fd_set stores are `[rdi + imm]`
with imm ∈ {168, 176, 184}); no REX.B-extended-base; no imm64.
**Cross-repo escalation not needed.**

## 3. Design

### 3.1 File and module structure

New file: `src/kernel/core/tty/connect.pdx`. Populates the last
gap in `core/tty/`:

```
src/kernel/core/tty/
    init.pdx           (#602 — vnode alloc + _tty0 publish)
    vops.pdx           (#603 — _tty_vops table + wire)
    line_buffer.pdx    (#604 — 256-char accumulator)
    process_input.pdx  (#605 — cooked-mode byte router)
    read.pdx           (#606 — cooked-mode reader)
    write.pdx          (#607 — \n→\r\n TX loop)
    connect.pdx        <-- THIS ISSUE (#608)
```

Module name: `Connect`. Public export: `tty_connect_init`.

### 3.2 Stdio slot offsets (frozen constants)

Rather than compute `168 + fd*8` at runtime for each of the three
fd writes, the body inlines the three constants:

```
FD_TABLE_OFFSET  =  168     (fd_table base, #549)
STDIN_OFFSET     =  168     (fd_table[0])   = 168 + 0*8
STDOUT_OFFSET    =  176     (fd_table[1])   = 168 + 1*8
STDERR_OFFSET    =  184     (fd_table[2])   = 168 + 2*8
```

The primitive does not export these — they are private inlined
constants inside the body's three `mov` instructions.

### 3.3 `tty_connect_init` — body sequence

```asm
; ================================================================
; tty_connect_init(task_ptr) -> u64
;   rdi = task_ptr
;
; Returns rax:
;   0                      on success
;   0xFFFFFFFFFFFFFFFF     if _tty0 == 0 (tty_init never ran)
;
; Side effects (on success):
;   task_ptr->fd_table[0..2] = packed_entry(_tty0)
;   _vnode_pool[_tty0 & 0xFFFF].refcount += 3
;
; Register discipline:
;   rbx = task_ptr        (saved across vnode_slot)
;   r12 = entry / _tty0   (saved across vnode_slot; also serves as
;                          the packed entry since offset=0 upper
;                          48 are already zero in _tty0's layout)
;   rax/rcx/rdx/rdi = scratch
;
; Prologue: push rbx, r12.  Entry rsp % 16 == 8 (SysV post-call);
; 2 pushes drop rsp by 16, keeping rsp % 16 == 8 → for the ONE
; nested call (vnode_slot) an extra `sub rsp, 8` is NOT needed
; because vnode_slot is a LEAF (§2.1, per vnode_pool.pdx:148-159):
; its entry alignment is irrelevant to correctness.  Mirror of
; sys_fork_body's rationale for the same 2/3-push family.
; ================================================================
tty_connect_init:
    push rbx
    push r12

    mov  rbx, rdi                        ; rbx = task_ptr

    ; --- Load _tty0 (guard against pre-init sentinel) ---
    mov  rax, [rip + _tty0]
    cmp  rax, 0
    je   tty_connect_init_fail           ; _tty0 == 0 → tty_init never ran

    mov  r12, rax                        ; r12 = _tty0 (== packed entry:
                                         ;   vnode_idx in low 16, 0 in high 48)

    ; --- Publish _tty0 into fd_table[0/1/2] ---
    ; entry lives in r12; store to +168, +176, +184.  Three writes,
    ; identical shape, imm-different by 8.
    mov  [rbx + 168], r12                ; fd_table[0] (stdin)
    mov  [rbx + 176], r12                ; fd_table[1] (stdout)
    mov  [rbx + 184], r12                ; fd_table[2] (stderr)

    ; --- Lift _tty0.refcount by 3 ---
    ; vnode_slot(vnode_idx) with vnode_idx = _tty0 & 0xFFFF.  Since
    ; _tty0's high 48 bits are 0 by construction (#602 §3.2), no mask
    ; is needed — pass _tty0's low half directly.  We already have
    ; _tty0 in r12; and rdi with the low 16 to be explicit.
    mov  rdi, r12
    and  rdi, 0xFFFF                     ; rdi = vnode_idx
    call vnode_slot                      ; rax = &_vnode_pool[vnode_idx]

    xor  rcx, rcx
    mov_w rcx, [rax + 4]                 ; rcx = refcount (u16, zero-extended)
    add  rcx, 3                          ; refcount += 3
    mov_w [rax + 4], rcx                 ; store back

    ; --- Success: return 0 ---
    xor  rax, rax
    jmp  tty_connect_init_done

tty_connect_init_fail:
    ; _tty0 was 0 — do NOT touch any fd_table slot, do NOT touch any
    ; refcount.  Return -1.  This branch is unreachable in practice
    ; at R16.M5 (kernel_main call order guarantees tty_init runs before
    ; this witness), but the guard is kept for R17 defensive posture:
    ; if #620's init bring-up reorders tty_init after tty_connect_init,
    ; the failure fingerprint fires loudly instead of corrupting slot 0.
    mov  rax, 0xFFFFFFFFFFFFFFFF

tty_connect_init_done:
    pop  r12
    pop  rbx
    ret
```

**Instruction count**: ~18 body + prologue/epilogue. Comparable
to `tty_init` (~18) and considerably simpler than `sys_open_body`
(~25) — one nested call, three inline stores, one refcount RMW.

### 3.4 File contents (target)

```pdx
// src/kernel/core/tty/connect.pdx — R16-M5-007 (#608)
// tty_connect_init — publish _tty0 into a task's fd_table[0/1/2] and
// lift _tty0.refcount by 3 to account for the three new holds.
//
// Per design/kernel/r16-m5-007-tty-connect-init.md and the packed
// fd_entry encoding frozen by #587 §3.2:
//
//   Each fd_table slot receives the packed u64:
//     bits [ 0, 16):  vnode_idx = _tty0 & 0xFFFF
//     bits [16, 64):  offset    = 0
//   Because _tty0's upper 48 bits are 0 by construction (#602 §3.2),
//   the packed entry IS _tty0 verbatim — no shift, no OR needed.
//
// See design doc for the R17 successor (init bring-up will call this
// primitive on _init_task without body change).

module Connect = structure {
  // ==========================================================================
  // tty_connect_init(task_ptr) -> u64
  //   Input:  rdi = task_ptr (task_struct*, non-NULL)
  //   Output: rax = 0 on success, 0xFFFFFFFFFFFFFFFF if _tty0 == 0.
  //   Side effects (on success):
  //     task_ptr->fd_table[0..2] = packed_entry(_tty0)
  //     _vnode_pool[_tty0 & 0xFFFF].refcount += 3
  // ==========================================================================
  pub let tty_connect_init : (u64) -> u64 !{mem} @{} =
    fn (task_ptr: u64) -> unsafe {
      effects: {mem},
      capabilities: {},
      justification: "R16-M5-007 (#608): tty_connect_init — publish _tty0 into task_ptr->fd_table[0/1/2] and bump _tty0.refcount by 3. 2-push prologue (rbx=task_ptr, r12=entry) preserves both across the one nested call (vnode_slot, which is a leaf per vnode_pool.pdx and thus indifferent to caller's stack alignment). Body: mov rax, [rip + _tty0]; cmp rax, 0; je fail (defensive guard against pre-init, unreachable at R16.M5 by kernel_main call order but kept for R17 posture where #620 may reorder). Save entry in r12; three `mov [rbx + imm], r12` writes to +168/+176/+184 (fd_table[0/1/2] per #549 FD_TABLE_OFFSET freeze — no runtime `rsi*8` because fd is a compile-time constant for each of the three slots). Then extract vnode_idx via `and rdi, 0xFFFF` (upper 48 already zero but the mask is documentation), call vnode_slot to get &vnode, and refcount+=3 via the same `mov_w [+4]; add; mov_w` idiom fd_inherit uses (with +3 instead of +1 — u16 refcount ceiling of 65535 is not a concern; see design §3.5). Success path: xor rax; jmp done. Fail path: mov rax, 0xFFFFFFFFFFFFFFFF. Epilogue: pop r12, pop rbx, ret. Non-leaf: one call to vnode_slot; alignment safe because vnode_slot is itself a leaf. Audit: r16-m5-007-tty-connect-init.",
      block: {
        push rbx;
        push r12;

        mov rbx, rdi;                        // rbx = task_ptr

        mov rax, [rip + _tty0];
        cmp rax, 0;
        je  tty_connect_init_fail;

        mov r12, rax;                        // r12 = packed entry (_tty0 verbatim)

        mov [rbx + 168], r12;                // fd_table[0]
        mov [rbx + 176], r12;                // fd_table[1]
        mov [rbx + 184], r12;                // fd_table[2]

        mov rdi, r12;
        and rdi, 0xFFFF;                     // vnode_idx
        call vnode_slot;                     // rax = &_vnode_pool[vnode_idx]

        xor rcx, rcx;
        mov_w rcx, [rax + 4];                // refcount (u16, zero-extended)
        add rcx, 3;
        mov_w [rax + 4], rcx;                // refcount += 3

        xor rax, rax;
        jmp tty_connect_init_done;

      tty_connect_init_fail:
        mov rax, 0xFFFFFFFFFFFFFFFF;

      tty_connect_init_done:
        pop r12;
        pop rbx;
        ret
      }
    }
}
```

### 3.5 Refcount ceiling — why `+3` is unconditionally safe

The vnode `refcount` field is a `u16` at vnode +4 (frozen by
#570). The ceiling is `65535`. This issue bumps by exactly 3
exactly once per boot at R16.M5, and once per task at R17+ init
bring-up.

Concrete upper bound at any point after this issue lands:

| Source of refcount++          | Count                                                  |
|-------------------------------|--------------------------------------------------------|
| tty_init self-hold            | 1                                                      |
| tty_connect_init (this issue) | 3 (one per stdio slot)                                 |
| Future: multiple task inheritance across fork | +3 per forked task                       |

To reach 65535, we'd need ~21800 forks of a task that inherits
the tty fds. R16.M5 kernel_main forks zero tasks that inherit
stdio (the fd_inherit walker at #592 runs during sys_fork_body,
and no witness at R16.M5 forks a task with populated fd_table[0/1/2]).
R17 will add init + shell as the first pair of stdio-holding tasks
— a lifetime that far, far short of the ceiling.

If R18+ ever grows a fork-storm workload, the refcount widening
to u32 is a #570-family unfreeze — this issue does not preempt
that decision, but its `+3` bump is safe against every plausible
R17-era workload.

### 3.6 Why we bypass `fd_alloc` for slots 0/1/2

`fd_alloc` (#549 fd_table.pdx:44) scans slots `[3, 32)` for the
first free slot. It **by design** never allocates 0/1/2 — the
scan floor at line 50 is `mov rcx, 3`. This is why every prior
witness has seen `sys_open` return `3` on the first call.

For stdio wiring we need to write slots 0/1/2 directly, without
going through `fd_alloc`. The write itself is safe because:

1. The three slots are guaranteed 0 (free) in a fresh task_struct
   — either because it's a `.bss` witness slab (zero-initialized)
   or because `task_new` zeros the whole slab (#547).
2. There is no other codepath at R16.M5 that reserves 0/1/2 —
   `sys_dup2`'s destination fd can technically be 0/1/2, but no
   R16 witness exercises that (see #591's sub-tests).

The direct-write pattern here is the "reserved slot init" idiom
that POSIX libcs use — same shape as Linux's `init/main.c` early
console wire-up.

### 3.7 Register + stack discipline (non-leaf)

`tty_connect_init` calls one nested function: `vnode_slot`. SysV
AMD64 requires `rsp % 16 == 0` at every nested `call`.

- Entry: `rsp % 16 == 8` (post outer-call push of return addr).
- **2-push prologue** drops `rsp` by 16 → `rsp % 16 == 8` at the
  nested call site.
- **BUT**: `vnode_slot` is a **leaf** (per vnode_pool.pdx:148-159:
  three instructions, no further call, no callee-save touched).
  Leaf-callee entry alignment is irrelevant to correctness — the
  ABI's 16-byte alignment requirement applies to callees that
  themselves call further (they may spill to XMM/AVX slots that
  need aligned addressing). A leaf that only touches integer
  regs works at any alignment.
- This matches every other 2-push-into-leaf-nested pattern in
  the kernel (fd_inherit.pdx, tty_write.pdx, etc.).

**Volatility.** On return, `rcx`, `rdx`, `rdi`, `r8`, `r9`,
`r10`, `r11` are clobbered (SysV caller-saves used or clobbered
by vnode_slot). `rbx`, `r12` are preserved (push/pop). Caller
must treat all caller-saves as clobbered across the call —
standard SysV.

## 4. Witness placement

### 4.1 Position in kernel_main.pdx

Inserted immediately after `tty_write_witness_done:` (line 4841)
and before the R14b-m5-002 GS_BASE `wrmsr` block (line 4844).

```
tty_write_witness_done:
    pop  r12

<-- INSERT R16.M5-007 WITNESS HERE (§5.2 body) -->

// R14b-m5-002 (#507): IA32_GS_BASE = &_cpu_locals[0] on CPU0.
lea rax, [rip + _cpu_locals];
...
```

If a follow-on R16.M5 patch slips in between #607 and #608, the
insertion point moves to the actual last-landed R16.M5 witness's
`_done:` label. No R16.M5 witness downstream of tty_write holds
state this issue reads.

### 4.2 Witness task slab

Add alongside the existing five `_sys_*_witness_task` slabs at
`kernel_main.pdx:5373-5408`:

```pdx
// R16-M5-007 (#608): tty_connect_init witness task storage.
// Static .bss blob (2224 bytes = 278 u64s) backing a dedicated
// witness task_struct.  Same rationale as _sys_open_witness_task
// (#587 §4.1) and its siblings: witness storage stays independent
// of the scheduler init sequence so R16.M5 witnesses run before
// idle_init / runq_init without ordering hazards.  Slots 0..31 of
// fd_table (bytes +168..+424) are the interesting extent — the
// rest of the 278-u64 blob is padding to match the frozen
// task_struct total size.
pub let mut _tty_connect_witness_task : [u64; 278] = uninit @align(8)
```

Alignment 8 is sufficient (fd_table SIB+disp addressing requires
only 8-byte alignment). The 278-u64 shape matches every prior
witness task slab verbatim.

## 5. Test canary — kernel_main witness block

### 5.1 Preamble

Inputs the witness relies on:

- `_tty_connect_witness_task`: fresh 278-u64 `.bss` blob (all
  zeros — `.bss` zero-init contract). fd_table[0..31] all 0.
- `_tty0`: published by #602 (tty_init) at line 4223, refcount=1
  after init. No R16.M5 witness between #602 and this one
  touches _tty0.refcount (verified by grep across tty/*.pdx and
  the tmpfs/vfs witnesses that follow tty_init).
- `vnode_slot`: leaf primitive from #571, stable across all
  boot-stage callers.

### 5.2 Sub-tests

**Preamble** (snapshot refcount before the call):

```asm
; Snapshot _tty0.refcount into r15 (callee-save) before tty_connect_init.
; This lets sub-test C check the +3 delta regardless of prior boot state.
mov  rax, [rip + _tty0]
and  rax, 0xFFFF                              ; vnode_idx
mov  rdi, rax
call vnode_slot                               ; rax = &_tty0_vnode
xor  rcx, rcx
mov_w rcx, [rax + 4]                          ; rcx = R (refcount before)
mov  r15, rcx                                 ; r15 = R (survives all sub-tests)
```

**Sub-test A**: `fd_table[0]` receives the packed `_tty0` entry.

```asm
lea  rdi, [rip + _tty_connect_witness_task]
call tty_connect_init
cmp  rax, 0
jne  tty_connect_witness_fail                 ; primitive must succeed

; fd_get(w, 0) — extract vnode_idx from low 16 bits, compare to _tty0's idx
lea  rdi, [rip + _tty_connect_witness_task]
xor  rsi, rsi                                 ; fd = 0
call fd_get                                   ; rax = fd_table[0]
and  rax, 0xFFFF                              ; extract vnode_idx
mov  rcx, [rip + _tty0]
and  rcx, 0xFFFF                              ; _tty0's vnode_idx
cmp  rax, rcx
jne  tty_connect_witness_fail
```

**Sub-test B**: `fd_table[1]` receives the same entry (stdout).

```asm
lea  rdi, [rip + _tty_connect_witness_task]
mov  rsi, 1                                   ; fd = 1
call fd_get
and  rax, 0xFFFF
mov  rcx, [rip + _tty0]
and  rcx, 0xFFFF
cmp  rax, rcx
jne  tty_connect_witness_fail
```

**Sub-test C** (parent-brief's sub-test C): `_tty0.refcount ==
R + 3`.

```asm
mov  rax, [rip + _tty0]
and  rax, 0xFFFF
mov  rdi, rax
call vnode_slot                               ; rax = &_tty0_vnode
xor  rcx, rcx
mov_w rcx, [rax + 4]                          ; rcx = refcount AFTER

; Expected: R + 3.  r15 holds R (from preamble).
mov  rax, r15
add  rax, 3
cmp  rcx, rax
jne  tty_connect_witness_fail
```

**Sub-test D** (fd_table[2] check — completes the triplet):

```asm
lea  rdi, [rip + _tty_connect_witness_task]
mov  rsi, 2                                   ; fd = 2
call fd_get
and  rax, 0xFFFF
mov  rcx, [rip + _tty0]
and  rcx, 0xFFFF
cmp  rax, rcx
jne  tty_connect_witness_fail
```

The parent brief listed A/B/C only; sub-test D is added so all
three stdio slots are asserted equally (not just 0 and 1). D
costs 8 instructions and closes the door on a "off-by-one write
skipped fd 2" regression.

### 5.3 Witness assembly (complete block)

```asm
; ============================================================
; R16-M5-007 (#608): tty_connect_init witness — 4 sub-tests, 1 marker
; ============================================================
tty_connect_witness:
    push r15                                  ; callee-save: carries R (pre-refcount)

    ; ---------- Preamble: snapshot _tty0.refcount ----------
    mov  rax, [rip + _tty0]
    and  rax, 0xFFFF
    mov  rdi, rax
    call vnode_slot
    xor  rcx, rcx
    mov_w rcx, [rax + 4]
    mov  r15, rcx                             ; r15 = R (survives sub-tests)

    ; ---------- Call the primitive under test ----------
    lea  rdi, [rip + _tty_connect_witness_task]
    call tty_connect_init
    cmp  rax, 0
    jne  tty_connect_witness_fail

    ; ---------- Sub-test A: fd_table[0] == packed _tty0 ----------
    lea  rdi, [rip + _tty_connect_witness_task]
    xor  rsi, rsi
    call fd_get
    and  rax, 0xFFFF
    mov  rcx, [rip + _tty0]
    and  rcx, 0xFFFF
    cmp  rax, rcx
    jne  tty_connect_witness_fail

    ; ---------- Sub-test B: fd_table[1] == packed _tty0 ----------
    lea  rdi, [rip + _tty_connect_witness_task]
    mov  rsi, 1
    call fd_get
    and  rax, 0xFFFF
    mov  rcx, [rip + _tty0]
    and  rcx, 0xFFFF
    cmp  rax, rcx
    jne  tty_connect_witness_fail

    ; ---------- Sub-test D: fd_table[2] == packed _tty0 ----------
    lea  rdi, [rip + _tty_connect_witness_task]
    mov  rsi, 2
    call fd_get
    and  rax, 0xFFFF
    mov  rcx, [rip + _tty0]
    and  rcx, 0xFFFF
    cmp  rax, rcx
    jne  tty_connect_witness_fail

    ; ---------- Sub-test C: _tty0.refcount == R + 3 ----------
    mov  rax, [rip + _tty0]
    and  rax, 0xFFFF
    mov  rdi, rax
    call vnode_slot
    xor  rcx, rcx
    mov_w rcx, [rax + 4]
    mov  rax, r15
    add  rax, 3
    cmp  rcx, rax
    jne  tty_connect_witness_fail

    ; ---------- All green ----------
    lea  rdi, [rip + tty_connect_ok_msg]
    call uart_puts
    jmp  tty_connect_witness_done

tty_connect_witness_fail:
    lea  rdi, [rip + tty_connect_fail_msg]
    call uart_puts

tty_connect_witness_done:
    pop  r15
```

Total: ~65 lines including labels and the push/pop pair.

**Register discipline of the witness block:** `push r15` before
the sub-tests balances `pop r15` at the exit label. Sub-tests
mixing `mov rcx, [rip + _tty0]; and rcx, 0xFFFF` for comparison
never leak across a `call` because they occur after each `call
fd_get` and before the next one.

### 5.4 Marker

On A, B, C, D all green:

```
R16 TTY CONNECT OK
```

Emitted via `uart_puts` on `tty_connect_ok_msg`.

### 5.5 String data — `tools/boot_stub.S`

Append after `tty_write_ok_msg` / `tty_write_fail_msg` (per #607
touching list, currently ~line 812):

```asm
# R16-M5-007 (#608): tty_connect_init witness success message
.global tty_connect_ok_msg
.align 8
tty_connect_ok_msg: .ascii "R16 TTY CONNECT OK\n\0"

# R16-M5-007 (#608): tty_connect_init witness failure message
.global tty_connect_fail_msg
.align 8
tty_connect_fail_msg: .ascii "R16 TTY CONNECT FAIL\n\0"
```

### 5.6 Fingerprint files — marker insertion

Insert `R16 TTY CONNECT OK` in three files immediately after
`R16 TTY WRITE OK`:

| File                                        | Insert after         | Insert before         |
|---------------------------------------------|----------------------|-----------------------|
| `tests/r14b/expected-boot-r14b-loader.txt`  | `R16 TTY WRITE OK`   | `LOADER OK`           |
| `tests/r15/expected-boot-r15-ring3.txt`     | `R16 TTY WRITE OK`   | `R15 IDLE TASK OK`    |
| `tests/r15/expected-boot-r15-process.txt`   | `R16 TTY WRITE OK`   | `R15 IDLE TASK OK`    |

Contains-in-order matching (per `tools/run-smoke.sh`) means the
addition is strictly additive. All 5 smoke modes that do not
observe R16 markers stay byte-identically green.

## 6. Alternatives considered / follow-ups

### 6.1 Combine with #609 (R16.M5 CLOSER smoke) in one PR

**Rejected.** #609 is the composed end-to-end fingerprint that
uses this issue's wired fd_table to call
`sys_write(1, "prompt", 6, 0)` and observe a matching UART
character stream. Bundling would inflate the diff by another
witness block plus a fingerprint-string introduction and would
couple the primitive (this issue) to its consumer (#609). The
tactical-plan split is `007-connect-init` and `008-closer-smoke`
for exactly this bisection reason.

### 6.2 Wait for #620 (init task creation) and skip the dedicated slab

**Rejected.** #620 is an R17 issue; blocking #608 on it delays
the R16.M5 subsystem-15 closer past its natural window. The
dedicated witness slab pattern is already sanctioned by five
prior R16.M3 issues (`_sys_*_witness_task`), and #620 can adopt
`tty_connect_init` verbatim once `_init_task` exists — no rework
required. The primitive's `task_ptr`-argument shape is precisely
what an R17 caller needs.

### 6.3 Fold refcount bump into `fd_set` itself

**Rejected.** `fd_set` (#549) is a **single-instruction store**
by design (`mov [rdi + rsi*8 + 168], rdx`). Adding refcount
awareness would break its leaf discipline and force every
existing caller (sys_open, sys_close, sys_dup2, fd_inherit) to
either pass or bypass an "already held" flag. The current split
— `fd_set` writes the slot, the caller manages refcount — is the
pattern all R16.M3 syscalls converged on. #608 fits the same
pattern by making its `+3` explicit rather than N `fd_set +
refcount++` iterations.

### 6.4 Use a loop over 0/1/2 instead of unrolled writes

**Rejected.** The count is a compile-time constant of 3. Three
unrolled `mov [rbx + imm], r12` instructions cost 3×5 bytes of
code (~15 B) and 3 cycles issue. A loop would cost prologue +
comparison + jump per iteration + still 3 stores — 5x the code
without runtime advantage. Unrolling is idiomatic for `.bss`
init in the kernel (`vnode_free` unrolls 8x zero stores; `task_new`
unrolls the reserved-fd zero writes).

### 6.5 Set CLOEXEC on fd 0/1/2

**Rejected.** POSIX inherits stdio across execve; setting
CLOEXEC on 0/1/2 would break the shell↔program contract. The
`_fd_cloexec_bitmap` frozen by #593 stays zero for these three
slots. This matches every Unix libc's convention.

### 6.6 Emit `R16 TTY CONNECT OK` from within `tty_connect_init`

**Rejected.** Same discipline as every R16 primitive: callers
own emission. `tty_connect_init` is a driver primitive; the
witness owns the marker line. This matches R16.M5-001 §6.6 and
R16.M4-001 §6.7.

### 6.7 Validate fd_table[0/1/2] were 0 before writing

**Rejected.** The primitive is called on freshly-allocated
task_structs (either `.bss` witness slabs or task_new-zeroed
kernel task_structs at R17). Adding a "was zero before write"
check would fire spuriously on legitimate re-init sequences
(e.g., R18+ session leader restarts). Defense-in-depth here is
the R17 caller's responsibility (a `bring_up_init_task` wrapper
can pre-zero if paranoia demands).

## 7. Invariants

### 7.1 `_tty0.refcount` monotonic non-decreasing until first vfs_close

Before this issue: `_tty0.refcount = 1` (from tty_init).
After this issue's witness: `_tty0.refcount = 4` (R+3, R=1).

No codepath at R16.M5 calls `vfs_close(_tty0)` — the tty is
permanent. The refcount only ever grows (fd_inherit_hold on
fork, sys_dup2 on tty fd, etc.) until R17+ introduces
`sys_close(0)` from userland (which would decrement, but always
above the base `_tty0` self-hold of 1).

Sub-test C's assertion (`R + 3`) directly verifies the bump.

### 7.2 `fd_table[0/1/2]` all reference the same vnode idx

Guaranteed by three identical stores of the same `r12` value.
Sub-tests A/B/D each check that fd's slot's low 16 bits match
`_tty0 & 0xFFFF`, so all three point at the singleton `_tty0`
vnode.

This is what makes `sys_dup2(1, 2)` a no-op — both slots already
reference `_tty0`, so nothing changes on that path (and the
refcount++ that sys_dup2 would trigger is balanced by the
sys_close on the dst before dup, both of which no-op at
R16.M5 witness scope).

### 7.3 Idempotence — deliberately NOT held

`tty_connect_init` is NOT idempotent. A second call would:

1. Overwrite fd_table[0/1/2] with the same value (no-op).
2. Bump `_tty0.refcount` by another +3, resulting in a leak of
   the three earlier holds (which are still counted).

Kernel_main calls this exactly once per task_ptr. If R17's #620
calls it once per init task creation, that's also once per boot.
No re-entry path exists.

If a future refactor moves the call into a "bring_up_all_tasks"
loop, the caller MUST ensure `tty_connect_init` runs at most
once per task_ptr.

### 7.4 `_tty0`-not-yet-initialized guard

If `_tty0 == 0` at entry (tty_init never ran), the primitive
returns `0xFFFFFFFFFFFFFFFF` without touching any state. At
R16.M5 this branch is unreachable (kernel_main calls tty_init
before this witness by ~600 lines), but is retained for R17
robustness.

## 8. Cross-cutting risks

- **fd_table byte layout drift.** If a future refactor changes
  `FD_TABLE_OFFSET` from 168 to another value, the three inlined
  stores (+168/+176/+184) would corrupt neighboring fields
  instead of writing the fd table. Mitigation: `FD_TABLE_OFFSET
  = 168` is frozen by #543 (task-struct-layout.md) and consumed
  by every fd_table.pdx-based primitive; any refactor would
  ripple through fd_table.pdx and be caught by the fd_witness
  first.
- **Packed encoding drift.** If #587 §3.2 unfreezes the "vnode_idx
  in low 16" convention (e.g., moves to a 24-byte record), the
  `mov [rbx + 168], r12` here would write a bogus entry. Mitigation:
  the encoding freeze is documented at #587 §3.2 and cited by
  every R16.M3+ consumer; unfreezing would require re-witnessing
  all six consumers (this one being the seventh).
- **refcount width narrowing.** If `refcount` at vnode +4 is
  ever narrowed from u16 to u8, the +3 bump could still work at
  R16.M5 witness time (base 1 + 3 = 4, fits in u8), but the
  ceiling argument in §3.5 would break — flagged for #570
  unfreezes.
- **Witness slab alignment.** `_tty_connect_witness_task :
  [u64; 278] = uninit @align(8)` — the 8-byte alignment is
  required by the fd_table SIB+disp addressing. `.bss`-zero
  contract handles the initial state. If a future R18 change
  makes task_struct require 16-byte alignment (e.g., for XMM
  spills), this slab would need widening.
- **Two witness paths that both bump refcount.** If a future
  R16.M5 witness inserts between #602 and #608 and bumps
  `_tty0.refcount`, the sub-test C invariant (`R + 3`) still
  holds because R is snapshotted at witness start. The witness
  is robust against any prior boot-time refcount inflation.

## 9. LOC estimate

| File                                                         | LOC        |
|--------------------------------------------------------------|------------|
| `src/kernel/core/tty/connect.pdx` (new)                      | ~65        |
|   - module boilerplate + justification                       |   ~20      |
|   - `tty_connect_init` body (~18 instructions)               |   ~25      |
|   - inline comments                                          |   ~20      |
| `src/kernel/boot/kernel_main.pdx` (witness block + slab)     | ~95        |
|   - `_tty_connect_witness_task` declaration                  |    ~5      |
|   - 4 sub-tests + preamble + fail/success labels             |   ~70      |
|   - inline comments                                          |   ~20      |
| `tools/boot_stub.S` (2 messages)                             | ~8         |
| 3 expected-output fingerprint files (1 marker each)          | ~3         |
| `design/kernel/r16-m5-007-tty-connect-init.md` (this doc)    | (this)     |
| **Total executable / testing / test-data**                   | **~171**   |

Executable code path: ~65 LOC. Witness + fingerprint: ~106 LOC.
Sizing sits between R16.M5-001 (`tty_init`: ~116 LOC total, 3
sub-tests) and R16.M3-001 (`sys_open`: ~196 LOC total, 5 sub-tests).

## 10. Tractability

**HIGH — small R16 issue, one leaf-plus-primitive pattern, four
narrowly-scoped sub-tests, zero encoder gaps.**

- **Zero paideia-as encoder gap.** Every mnemonic proven at
  `fd_table.pdx` (`mov [reg+imm], reg` and `mov rax, [reg+imm]`
  in various SIB forms), `fd_inherit.pdx` (`mov_w [+4]` refcount
  RMW), and `tty_init.pdx` (nested `vnode_slot` call from a
  2-push prologue). No new instruction shape.
- **One nested-call boundary** (`tty_connect_init` → `vnode_slot`).
  Callee is a leaf per vnode_pool.pdx; no callee-save save/restore
  needed in `tty_connect_init` beyond the `rbx`/`r12` for its own
  cross-call live values.
- **Four sub-tests** with mechanical structure: A/B/D each check
  a fd_table slot's low 16 bits equal `_tty0 & 0xFFFF`; C checks
  the refcount delta. No fixture allocation, no scratch structure,
  no cross-subsystem interaction. Snapshot pattern (r15 = R) is
  the same one #591 sys_dup2 witness uses for its dst-fd
  precondition preserve.
- **Marker line is contains-in-order** — strictly additive to
  fingerprints; no reordering risk.
- **No cross-repo escalation risk.**
- **Sizing (~171 LOC total)** is within the R16 tempo band and
  smaller than any R16.M3 syscall issue.

Estimated implementation time: **~45 minutes of a workerbee
session** — comparable to R16.M5-001 (`tty_init`, ~40 min) plus
a small increment for the 4-sub-test structure and R-snapshot
preamble.

Estimated risk of regressing an existing smoke mode: **near-zero**
— purely additive (one new file, one new `.bss` slab, one new
witness block, one new emit line, two new rodata strings, one
new marker line in three fingerprint files).

**Known follow-ups (do NOT block #608's landing)**:

- **#609 (R16.M5 CLOSER smoke)** — composes this issue's fd_table
  wire with #607's tty_write and #606's tty_read to run a
  round-trip echo through the cooked line discipline. Emits
  `R16 M5 OK` as the subsystem-closer marker.
- **R17 kernel_launch_init (#620)** — creates `_init_task`, then
  calls `tty_connect_init(&_init_task)` as the last step before
  ring-3 return. The primitive shipped here is directly reusable
  — no signature change.
- **CLOEXEC audit at R17+ execve** — verify that the three
  stdio fds are NOT in the CLOEXEC bitmap (per §6.5, and per
  #593's inheritance discipline). Trivially verified once
  execve gains its stdio-preservation witness.

## 11. References

- Issue: paideia-os#608
- Milestone: paideia-os R16.M5 (TTY / cooked line discipline)
- Prereq issues: #602 (tty_init), #603 (tty_vops_table), #606
  (tty_read), #607 (tty_write), #549 (fd_table embed), #587
  (sys_open + packed fd_entry freeze), #592 (fd_inherit_hold)
- Blocks: #609 (R16.M5 CLOSER), R17 kernel_launch_init (#620)
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 15 line ~1600, item 7
- Master plan: `design/milestones/r14b-master-plan.md` §M21 (TTY)
- Prior-art body pattern: `src/kernel/core/fs/fd_inherit.pdx`
  (#592 — 2-push prologue, vnode_slot leaf call, refcount RMW
  via mov_w [+4])
- Prior-art witness slab pattern: `src/kernel/boot/kernel_main.pdx:5373-5408`
  (five _sys_*_witness_task slabs at 278 u64 each)
- Prior-art witness structure: `src/kernel/boot/kernel_main.pdx:2814-2880`
  (sys_open witness — same "call primitive, then N fd_get sub-tests")
- Layout freeze source: `design/kernel/task-struct-layout.md` (#543 —
  FD_TABLE_OFFSET=168) and `design/kernel/vfs-layout.md` §3 (#570
  — VNODE_REFCOUNT_OFFSET=4)
- Encoding freeze source: `design/kernel/r16-m3-001-sys-open.md` §3.2
  (packed fd_entry: vnode_idx low 16 | offset high 48)
