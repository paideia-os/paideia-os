---
issue: 549
milestone: R15.M5 (Process abstraction — task_struct, PID allocator, fd table)
subsystem: 8 — Process abstraction
prereq:
  - "#543 (task-struct layout freeze) — must land offsets/constants first"
blocks:
  - "#551 (boot_r15_process smoke — fingerprint needs fd_alloc/set/get in place)"
  - "#550 (task_free — must close all fds; consumes FD_TABLE_MAX)"
  - "#1613 (r15-m5-007-connect-tty-to-init-fd012 — populates fd[0/1/2] with tty0)"
  - "R16.M3 (sys_open/close — grows u64 slot into full fd_entry {vnode_ptr, offset, flags, refcount})"
touching:
  - src/kernel/core/fs/fd_table.pdx           (new module)
  - src/kernel/boot/kernel_main.pdx           (witness block, ~40 LOC)
  - design/kernel/task-struct-layout.md       (from #543 — this doc pins the fd-table region)
  - design/kernel/r15-m5-007-fd-table-embed.md (this doc)
  - tests/r14b/expected-boot-r14b-loader.txt  (marker line, contains-in-order)
related:
  - "#543 (task_struct layout freeze — pins FD_TABLE_OFFSET)"
  - "#544 (task_pool slab — provides the storage backing task_struct)"
  - "#548 (task_new real body — allocates + zeroes a task_struct)"
  - design/milestones/r14b-tactical-plan.md §Subsystem 8 (source-of-truth layout)
---

# R15-M5-007 — fd_table embed: fixed-offset slots + fd_alloc / fd_set / fd_get one-liners (#549)

## 1. Scope

Give every `task_struct` an in-band **file-descriptor table** at a
fixed byte offset so that:

- `fd_get(t, fd)` compiles to a single `mov rax, [rdi + rsi*8 + FD_TABLE_OFFSET]`.
- `fd_set(t, fd, v)` compiles to a single `mov [rdi + rsi*8 + FD_TABLE_OFFSET], rdx`.
- `fd_alloc(t)` linearly scans the table for the first free slot,
  skipping fds 0/1/2 (reserved for stdin/stdout/stderr).

At R15.M5 an **fd slot is an opaque `u64`** — its interpretation is
frozen at "handle to a future vnode wrapper" and remains sentinel-`0`
= free / non-zero = allocated. The full `fd_entry`
`{vnode_ptr:u64, offset:u64, flags:u32, refcount:u32}` (24-byte
record from the tactical plan) is **deferred to R16.M3** (`sys_open`
lands VFS and grows the slot). This design pins the byte region and
scan discipline so R16.M3 can grow the slot in place without
re-plumbing every `fd_*` call site.

Out of scope (deliberately deferred):

- **VFS backing.** Nothing dereferences the `u64` value — this issue
  only provides the storage lattice. `sys_open` (R16.M3) puts real
  vnode pointers into slots.
- **Refcounting / close-on-exec / dup2.** Handled in R16.M3 once slots
  grow to `fd_entry`.
- **stdin/stdout/stderr population.** Slots 0/1/2 are *reserved by
  discipline* (fd_alloc skips them) but remain zero on a fresh task.
  The init sequence (#1613 — `connect-tty-to-init-fd012`) writes
  tty0 into task[1].fd[0/1/2] later.
- **Fork inheritance.** R15.M6 `sys_fork` clones the fd table with
  refcount bumps; here the slots are per-task and independent.
- **Concurrency.** Every `fd_*` call is on the task the caller
  currently owns (either `current_task()` or a task in `NEW` state
  before scheduler enqueue). No locking at R15.M5.

## 2. Prereq check

### 2.1 What's in place

- **paideia-as v0.20**: SIB + disp addressing
  (`mov r64, [base + index*scale + disp]`) — confirmed via
  `tools/paideia-as/tests/build-emit/mov_mem_imm_sib_disp.pdx`
  (`mov [rax + rcx*8 + 16], 42`). The three one-liners lower directly.
- **Reg-CL variable shifts** and **REX-encoded reg-mem stores** — used
  everywhere (`kpti.pdx`, `phys_free.pdx`, `enter_userland.pdx`).
- **`.bss` u64 array + `@align`** — established substrate
  (`_phys_page_pool`, `_task_a_tcb`, `_cpu_locals`). No encoder gaps.
- **`cmp reg, imm` + `jae` / `je`** — the whole `fd_alloc` loop is
  vanilla control flow that already ships in `phys_free.pdx`.

### 2.2 What is *not* in place (blocks not blocked by us)

- **#543** — `task_struct` layout freeze doc has **not** landed. #549
  must not be merged before #543. See §3.1 for the offset this doc
  contributes back to #543.
- **#544 / #548** — `_task_pool` and `task_new` do not exist yet. For
  the witness (§5) we back the assertion with a **standalone
  `_witness_task_struct` `.bss` blob** (2224 u64s == 17792 bytes) —
  no dependency on the task pool substrate.
- **cpu_local `current_task()`** (#546) not required — we operate on
  a `.bss` blob by RIP-relative `lea`.

### 2.3 Discrepancy to resolve (design decision embedded in this doc)

The milestone description of R15.M5 (issue #549's parent milestone
title / summary) specifies **32 fd slots**:

> "per-task fd table (32 slots reserved 0/1/2 for stdin/stdout/stderr)"

The tactical plan (`design/milestones/r14b-tactical-plan.md` §Subsystem
8, line 884) specifies **64 slots × 24-byte fd_entry = 1536 bytes**:

> "168: fd_table[64]{vnode_ptr:u64, offset:u64, flags:u32, refcount:u32}
> = 1536 bytes"

**Resolution (§3.1).** We take the milestone description's slot count
(`FD_TABLE_MAX = 32`) and the tactical plan's *offset* (168). Slot
size is `u64` at R15.M5 (not `fd_entry`) per the user brief
"for #549 just u64 opaque slot". Total fd-table region is
32 × 8 = 256 bytes. The tactical plan's remaining task_struct fields
(`wait_child_pid` @ 1704, etc.) stay at the frozen offsets — the space
between fd_table end (168 + 256 = 424) and 1704 becomes reserved
padding (1280 bytes) that R16.M3 uses to grow slots to 24 bytes and/or
FD_TABLE_MAX to 64 without shifting any subsequent field.

This resolution is called out to #543 as a doc note: the layout
freeze doc should record `FD_TABLE_OFFSET = 168`, `FD_TABLE_MAX = 32`
(R15.M5), `FD_ENTRY_SIZE = 8` (R15.M5), `FD_TABLE_RESERVED = 1280`,
`FD_TABLE_REGION_END = 1704`.

## 3. Design

### 3.1 task_struct fd-table region (freeze)

```
task_struct byte layout, R15.M5 (values pinned by this doc; feeds #543):

  offset   size   field
  ------   ----   ------------------------------------------------
     0       4    pid           : u32
     4       4    parent_pid    : u32
     8       4    state         : u32  (NEW=0,RUNNABLE=1,RUNNING=2,BLOCKED=3,ZOMBIE=4)
    12       4    exit_status   : u32
    16       8    user_pml4_pa  : u64
    24       8    kernel_stack  : u64
    32     120    regs_save     : [u64; 15]   (callee-saved + rsp)
   152       8    sched_next    : *task
   160       8    sched_budget  : u64
   168     256    fd_table      : [u64; 32]   <-- THIS ISSUE
   424    1280    _fd_reserved  : [u8; 1280]  (R16.M3 slot-widening headroom)
  1704       4    wait_child_pid   : u32
  1708       4    wait_reply_slot  : u32
  1712     512    reserved      : [u8; 512]
  2224     ---    total struct size (rounded to 4 KiB at slab layer)
```

Constants exported by `fd_table.pdx`:

```
FD_TABLE_OFFSET    : u64 = 168        // byte offset within task_struct
FD_TABLE_MAX       : u64 = 32         // slot count
FD_TABLE_STDIO_LO  : u64 = 3          // first fd fd_alloc will hand out
FD_TABLE_ERR_EMFILE: i64 = -1         // fd_alloc failure (−EMFILE per POSIX)
```

FD_TABLE_OFFSET = 168 aligns with the tactical plan's freeze (§3.1
of `r14b-tactical-plan.md` line 884). FD_TABLE_MAX = 32 aligns with
the R15.M5 milestone description.

### 3.2 fd_get — one-liner load

```asm
; fd_get(task: *task, fd: i32) -> u64 !{mem} @{}
;   rdi = task base;  rsi = fd (zero-extended)
;   returns raw u64 slot value in rax (0 if the slot is free / unused)
;
; Encoder: SIB + disp32 → 4-byte SIB opcode payload; one Mov instruction.
fd_get:
    mov rax, [rdi + rsi*8 + 168]
    ret
```

**Bounds check policy at R15.M5**: none. `fd_get` is a trusted
kernel-side primitive; the syscall layer (R16.M3 `sys_read` /
`sys_write`) is responsible for validating `fd < FD_TABLE_MAX`
before calling. Rationale: keeping the primitive branch-free is
what makes it a "one-liner" per the AC; adding a bounds check
inflates it to ~5 instructions and moves the policy question to the
wrong altitude. When R16.M3 lands its syscall wrapper, it enforces
the bound once, at the trust boundary, before calling `fd_get`.

### 3.3 fd_set — one-liner store

```asm
; fd_set(task: *task, fd: i32, val: u64) -> () !{mem} @{}
;   rdi = task base;  rsi = fd;  rdx = new slot value
fd_set:
    mov [rdi + rsi*8 + 168], rdx
    ret
```

Same bounds-check policy as `fd_get` (§3.2). Value semantics: any
`u64` — including 0 (which clears the slot back to "free"). No
refcount or vnode-close side effect at R15.M5; those land in R16.M3
when the slot grows into an `fd_entry`.

### 3.4 fd_alloc — linear scan starting at FD_TABLE_STDIO_LO

```asm
; fd_alloc(task: *task) -> i32 !{mem} @{}
;   rdi = task base
;   Returns lowest fd in [3, FD_TABLE_MAX) whose slot is zero;
;   returns -1 (FD_TABLE_ERR_EMFILE) if none is free.
;
; Design: fds 0/1/2 are reserved by discipline (skipped even when
; empty). fd_set may still write to them explicitly (init sequence
; installs tty0 there).
fd_alloc:
    mov rcx, 3                       ; start after stdin/stdout/stderr
fd_alloc_loop:
    cmp rcx, 32                      ; FD_TABLE_MAX
    jae fd_alloc_none
    mov rax, [rdi + rcx*8 + 168]     ; load slot
    test rax, rax
    je  fd_alloc_found               ; zero → free
    add rcx, 1
    jmp fd_alloc_loop
fd_alloc_found:
    mov rax, rcx                     ; return fd
    ret
fd_alloc_none:
    mov rax, -1                      ; FD_TABLE_ERR_EMFILE
    ret
```

**AC "fd_alloc after boot returns 3"** is satisfied unconditionally
by the scan starting at index 3 — no dependency on prior population
of fd[0/1/2]. This is the smallest correct implementation that
meets AC even in the absence of tty init (which lands as #1613).

**AC "fd_set(t, 5, vn); fd_get(t, 5) == vn"** is trivial by the
symmetry of §3.2 and §3.3.

**Complexity.** Worst case at FD_TABLE_MAX=32 is 29 slot loads + 29
tests + 29 branches ≈ 90 μops. At 4 GHz that is ~25 ns. Steady state
after boot is 1-3 slots (stdin/stdout/stderr + a few open files) so
`fd_alloc` returns within one or two iterations for realistic loads.
Bitmap-accelerated `fd_alloc` (bsf over a 4-byte free-slot bitmap
adjacent to fd_table) is a future optimization once fd churn is
observably a hot path; at R15.M5 the linear scan is Pareto-adequate
and matches the "one-liner" spirit of the AC.

### 3.5 File and module structure

```
src/kernel/core/fs/                    <-- NEW directory (first fs/ module)
    fd_table.pdx                       <-- this issue
```

`src/kernel/core/fs/` did not exist prior to this issue. That is
correct per the tactical plan §Subsystem 8 (`fs/fd_table.pdx` first,
`fs/vfs.pdx` and `fs/tmpfs.pdx` and `fs/console.pdx` later at
R16.M3). Creating the directory is a plain `mkdir` in the layout,
no linker-script or build.sh change required (the build discovers
`.pdx` files by directory walk — verified against
`kernel_build.sh` behavior for `src/kernel/core/mm/` and
`src/kernel/core/ipc/`).

Full module skeleton:

```pdx
// src/kernel/core/fs/fd_table.pdx — R15-M5-007 (#549)
// File-descriptor table embedded in task_struct at fixed byte offset 168.

module FdTable = structure {
  // ==========================================================================
  // Layout constants — pinned by design/kernel/task-struct-layout.md (#543)
  // ==========================================================================
  pub let FD_TABLE_OFFSET     : u64 = 168        // byte offset within task_struct
  pub let FD_TABLE_MAX        : u64 = 32         // slot count
  pub let FD_TABLE_STDIO_LO   : u64 = 3          // fd_alloc scan-start
  pub let FD_TABLE_ERR_EMFILE : i64 = 0-1        // fd_alloc failure sentinel

  // ==========================================================================
  // fd_get — one-liner load
  // ==========================================================================
  pub let fd_get : (u64, u64) -> u64 !{mem} @{} =
    fn (task: u64) (fd: u64) -> unsafe {
      effects: {mem},
      capabilities: {},
      justification: "R15-M5-007 (#549): fd_get is a single SIB+disp load `mov rax, [rdi + rsi*8 + 168]`. No bounds check by policy — syscall layer (R16.M3) validates fd < FD_TABLE_MAX at the trust boundary. Value semantics: opaque u64 slot; zero means unused. FD_TABLE_OFFSET=168 pinned by design/kernel/task-struct-layout.md.",
      block: {
        mov rax, [rdi + rsi*8 + 168];
        ret
      }
    }

  // ==========================================================================
  // fd_set — one-liner store
  // ==========================================================================
  pub let fd_set : (u64, u64, u64) -> () !{mem} @{} =
    fn (task: u64) (fd: u64) (val: u64) -> unsafe {
      effects: {mem},
      capabilities: {},
      justification: "R15-M5-007 (#549): fd_set is a single SIB+disp store `mov [rdi + rsi*8 + 168], rdx`. No bounds check by policy (see fd_get). Writing 0 clears the slot back to `free`; no vnode-close side effect at R15.M5 (u64 slots are opaque; R16.M3 grows to fd_entry and adds close semantics).",
      block: {
        mov [rdi + rsi*8 + 168], rdx;
        ret
      }
    }

  // ==========================================================================
  // fd_alloc — linear scan skipping stdin/stdout/stderr
  // ==========================================================================
  pub let fd_alloc : (u64) -> i64 !{mem} @{} =
    fn (task: u64) -> unsafe {
      effects: {mem},
      capabilities: {},
      justification: "R15-M5-007 (#549): linear scan of task->fd_table[3..32] for first zero slot; returns fd index or -1 (EMFILE). Skipping 0/1/2 by design meets AC 'fd_alloc after boot returns 3' unconditionally — no dependency on stdio pre-population (which lands as #1613). Worst-case 29 iterations; Pareto-adequate at MAX=32. Bitmap-accelerated version deferred until fd churn is observably hot.",
      block: {
        mov rcx, 3;                          // FD_TABLE_STDIO_LO
      fd_alloc_loop:
        cmp rcx, 32;                         // FD_TABLE_MAX
        jae fd_alloc_none;
        mov rax, [rdi + rcx*8 + 168];        // load slot
        test rax, rax;
        je  fd_alloc_found;
        add rcx, 1;
        jmp fd_alloc_loop;
      fd_alloc_found:
        mov rax, rcx;
        ret;
      fd_alloc_none:
        mov rax, 0-1;                        // -1
        ret
      }
    }
}
```

Note the assembly-literal `-1` is expressed as `0-1` for the
parser — same idiom used in `PhysFree` for `PHYS_FREE_INVALID =
0xFFFFFFFFFFFFFFFF`.

## 4. Test canary — kernel_main witness block

The witness lives in `kernel_main.pdx` (same pattern as #649 phys_free
witness, #650 UD witness, #652 ring-3 witness). It runs between the
existing loader-witness and IPI-witness blocks so that its marker
line lands ordered relative to the other R14b/R15 markers.

### 4.1 Witness storage

Static `.bss` blob backing the witness task:

```pdx
// In fd_table.pdx (or kernel_main.pdx) — 2224 bytes = 278 u64s
pub let mut _fd_witness_task : [u64; 278] = uninit @align(8)
```

Alignment 8 is sufficient (task_struct has no >8-byte alignment
requirement at R15.M5; 4 KiB alignment is only enforced at the slab
layer per #544, which is unused here).

### 4.2 Witness assembly

```asm
; ============================================================
; R15-M5-007 (#549): fd_table witness — three one-liners.
; ============================================================

; Zero the witness task so all fd slots are 'free'.
; (uninit .bss is zero on ELF load, but be explicit: the compile-time
; guarantee is well-formed layout, not zero-fill. We rely on the ELF
; loader zeroing .bss; verified in the loader witness.)
lea rdi, [rip + _fd_witness_task];

; --- (1) fd_alloc should return 3 on a fresh task ---
call fd_alloc;
cmp  rax, 3;
jne  fd_witness_fail;

; --- (2) fd_set(t, 5, 0xDEADBEEFCAFEBABE) then fd_get(t, 5) round-trip ---
lea rdi, [rip + _fd_witness_task];
mov rsi, 5;
mov rdx, 0xDEADBEEFCAFEBABE;
call fd_set;

lea rdi, [rip + _fd_witness_task];
mov rsi, 5;
call fd_get;
mov rcx, 0xDEADBEEFCAFEBABE;
cmp rax, rcx;
jne fd_witness_fail;

; --- (3) fd_alloc after fd_set(5, x) still returns 3 (first hole is 3) ---
lea rdi, [rip + _fd_witness_task];
call fd_alloc;
cmp rax, 3;
jne fd_witness_fail;

; --- (4) fd_set(t, 3, x) → fd_alloc returns 4 (first free slot moved up) ---
lea rdi, [rip + _fd_witness_task];
mov rsi, 3;
mov rdx, 0x1;                                ; non-zero → allocated marker
call fd_set;

lea rdi, [rip + _fd_witness_task];
call fd_alloc;
cmp rax, 4;
jne fd_witness_fail;

; --- All four checks passed. Emit marker. ---
lea rdi, [rip + fd_witness_ok_msg];
call uart_puts;
jmp  fd_witness_done;

fd_witness_fail:
    lea rdi, [rip + fd_witness_fail_msg];
    call uart_puts;

fd_witness_done:
```

Rodata strings:
```
fd_witness_ok_msg   : "R15 FD TABLE OK\n"
fd_witness_fail_msg : "R15 FD TABLE FAIL\n"
```

The four checks together prove:
1. `fd_alloc` skips 0/1/2.
2. `fd_set` writes the exact `u64` value.
3. `fd_get` reads back the exact `u64` value (round-trip).
4. `fd_alloc` re-scans and finds the *next* hole (not the just-set
   slot), confirming the loop tests non-zero correctly.

### 4.3 Smoke fingerprint

Marker line appended to `tests/r14b/expected-boot-r14b-loader.txt`
(the "everything-post-loader" fingerprint — same file where the
loader, KPTI, ring-3, IPI, and phys_free witnesses all cluster):

```
R15 FD TABLE OK
```

Contains-in-order matching means every other smoke
(`boot_r10 / boot_r11 / boot_r12 / boot_r14b_*`) continues to pass
without touching their expected files — the new marker is an extra
line, not a re-ordering.

`boot_r15_process` (#551) will consume `_fd_witness_task` in the
same way after #548 (task_new) lands, at which point the witness
switches to `task_new(NULL)` for a real task_struct backing. That is
#551's concern, not #549's.

### 4.4 Non-witness discipline

- **objdump structural check** (`tools/verify-fd-table-layout.sh`,
  optional): `nm build/kernel.elf | grep _fd_witness_task` non-empty;
  `nm | grep fd_alloc` / `fd_set` / `fd_get` non-empty. Verify the
  `mov rax, [rdi + rsi*8 + 0xa8]` (168 = 0xa8) byte pattern shows up
  in `objdump -d` output for `fd_get`. Runnable by hand, not required
  as a script.

## 5. LOC estimate

| File                                                              | LOC delta |
|-------------------------------------------------------------------|-----------|
| `src/kernel/core/fs/fd_table.pdx` (new)                           | +80       |
| `src/kernel/boot/kernel_main.pdx` (witness block + `_fd_witness_task`) | +45       |
| `tests/r14b/expected-boot-r14b-loader.txt` (one line)             | +1        |
| `design/kernel/task-struct-layout.md` (#543 addendum: fd-table region row) | +8        |
| `design/kernel/r15-m5-007-fd-table-embed.md` (this doc)           | +420      |
| **Total**                                                         | **~554**  |

Executable code: ~125 LOC. Design + fingerprint: ~430 LOC.

## 6. Backtrack candidates

Ordered by preference.

### 6.1 Backtrack A — Widen to full fd_entry (24-byte record) now

Store the tactical plan's original `{vnode_ptr, offset, flags,
refcount}` at 24 bytes per slot from R15.M5. `fd_get` returns a
pointer into the slot (not the vnode); callers dereference `.vnode_ptr`
themselves.

Consequence: `fd_get` is no longer a one-liner — it becomes
`lea rax, [rdi + rsi*24 + 168]; ret`, which is fine as a **two-liner**
except that `*24` is not a SIB scale (scales are 1/2/4/8). We would
have to emit `lea rax, [rdi + rsi*8]; add rax, rsi; add rax, rsi*16;
add rax, disp; ret` — five instructions, defeats "one-liner" AC. Also
pulls in R16.M3's semantics prematurely.

**Reject as primary.** Retain as fallback if R16.M3 shipping-order
concerns force VFS-adjacent semantics into R15.M5.

### 6.2 Backtrack B — Grow FD_TABLE_MAX to 64 (tactical plan literal)

Take the tactical plan's `[64]` slot count instead of the milestone
description's `32`. Doubles the fd_table region to 512 bytes; wait_*
fields still stay at offset 1704 (reserved padding shrinks from
1280 to 1024 bytes). `fd_alloc` worst case moves from 29 to 61
iterations — still well within microsecond budget.

Consequence: reserved padding shrinks 1280 → 1024 bytes, so future
`fd_entry` growth to 24 bytes/slot is capped at ~43 slots (1024/24)
before shifting subsequent fields. Trade-off is against R16.M3's
final `fd_entry` × `FD_TABLE_MAX` product staying ≤ 1536 bytes.

**Recommend as first backtrack** if a maintainer prefers to align
literally with the tactical plan §Subsystem 8 rather than the
milestone description. Reject as primary because the "usually 8-32
for micro-kernels" guidance from the parent task brief and the
milestone summary both point to 32.

### 6.3 Backtrack C — fd_alloc scans from 0 (POSIX-standard behavior)

`fd_alloc` starts at slot 0. The witness code becomes:

```
call fd_alloc;    -> returns 0 (fresh task, slot 0 empty)
cmp rax, 0;       -> different AC
```

Then to meet AC "returns 3 after boot", the boot code (or the witness
setup) must first `fd_set(t, 0, tty); fd_set(t, 1, tty); fd_set(t, 2,
tty);` to reserve those slots. That is exactly what #1613 does at init
time.

Consequence: The AC "fd_alloc after boot returns 3" only holds
**after** the tty is wired to the init task. For R15.M5 alone (before
#1613), the witness must fake the tty population — one extra 3-line
`fd_set` prelude. Simple, but adds coupling between #549's witness
and the init sequence that #549 does not otherwise need.

**Reject as primary.** POSIX-clean behavior is preferable long term,
but it moves the burden of reservation from `fd_alloc`'s policy into
every caller of `task_new`. The current design keeps the policy
local. Retain as backtrack if the reviewer preferring POSIX
strictness over policy locality wins.

### 6.4 Backtrack D — External fd_table (separate allocation, `task->fd_table_ptr`)

Instead of embedding the fd_table inline, store a pointer in
task_struct that references a separately-allocated array. Cheaper
task_struct (256 bytes reclaimed); more expensive `fd_get` (extra
indirection).

Consequence: `fd_get` becomes `mov rax, [rdi + FD_TABLE_PTR_OFFSET];
mov rax, [rax + rsi*8]; ret` — three instructions. Defeats "one-liner"
AC. Enables fd_table resizing dynamically (grow beyond 32 without
rebuilding task_struct), but at R15.M5 the fd_table is statically
sized anyway. Also complicates fork's fd-table clone (allocate a new
backing array vs. just copying the inline block).

**Reject.** Inline embedding is exactly what the "fixed offset in
task_struct" AC calls for.

### 6.5 Backtrack E — Bitmap-accelerated fd_alloc

Reserve a `u32` bitmap adjacent to fd_table (or reuse the low 32 bits
of a u64 header). `fd_alloc` becomes:

```
mov eax, [rdi + FD_BITMAP_OFFSET]
or  eax, 7                       ; mask fds 0/1/2 as "allocated" so bsf skips
not eax                          ; invert: bit set = free
bsf ecx, eax                     ; find first free
cmp ecx, 32
jae emfile
bts [rdi + FD_BITMAP_OFFSET], ecx  ; atomic-friendly set
mov eax, ecx
ret
```

O(1). But `bsf` on 32-bit input needs the top 32 bits set to garbage
concerns (32-bit form clears zero-input flag; that path is one extra
branch). Adds a new field to task_struct which shifts everything after
by 8 bytes — cascades into #543 layout freeze.

**Reject at R15.M5** — linear scan is < 100 ns and no measurement
shows it as a hot path. Retain as a *deliberate optimization
follow-up* once #649 (phys_free), #650 (UD marker), #648 (elf_lite),
and #651 (relocate) all retire and R15.M5 lands its full witness set.

## 7. Tractability

**HIGH.**

- No new paideia-as encoder gap. SIB + disp32 store/load is confirmed
  by `tools/paideia-as/tests/build-emit/mov_mem_imm_sib_disp.pdx` and
  is exercised by every existing `[base + index*8]` idiom in
  `phys_free.pdx`, `aspace_teardown.pdx`, `kpti.pdx`,
  `aspace_map.pdx`, `kind_page.pdx`.
- No new IDT / GDT / TSS / CR3 / MSR discipline.
- No new module directory build discipline — `src/kernel/core/fs/`
  is discovered by the build's directory walker (same as `mm/`,
  `ipc/`, `int/`).
- 125 LOC of executable across a new `.pdx` and a witness insertion.
- Witness backing storage is a single `.bss` u64 array — no allocator
  dependency, no CR3 flip, no interrupt discipline.
- Marker line is contains-in-order — no fingerprint drift across the
  other 5 smokes.
- Fits the R15.M5 tempo: parallels #649 (~30 LOC witness), #650
  (~25 LOC witness), #651 (~40 LOC witness), #652 (~90 LOC witness).

Known follow-ups (not blockers for #549):

- **#1613** — `connect-tty-to-init-fd012`: init sequence populates
  `task[1].fd_table[0/1/2]` with tty0 handle. R15.M5 subsystem 8
  landing does not depend on this.
- **R16.M3-001** — `sys_open_real`: grows the `u64` slot into a full
  `fd_entry` struct. The reserved 1280-byte padding after fd_table
  accommodates the growth without shifting `wait_child_pid` or any
  later field.
- **R15.M6-003** — `sys_fork`: walks the child's fd_table, refcount++
  vnodes into slots (once slots are `fd_entry` records).

## 8. Cross-cutting risks

- **AC drift from #543.** If #543's frozen layout ends up disagreeing
  with `FD_TABLE_OFFSET = 168`, this issue's one-liners become
  wrong. Mitigation: #549 must land after #543 with an explicit doc
  reference; the constants in `fd_table.pdx` are the single source
  of truth for offset arithmetic (no scattered `168` immediates
  outside this module).
- **Layout drift within task_struct.** If a future subsystem inserts
  a field between `sched_budget` (@160) and fd_table (@168) — e.g.,
  a scheduler tag — the offset shifts. Mitigation: `#543` freezes
  the layout; any change is a **layout re-freeze** issue with a
  bumped task-struct version constant and a rebuild-witness
  discipline. The 1280-byte reserved region after fd_table absorbs
  slot-widening; anything else is a re-freeze event.
- **Slot-value collision with `NULL_VNODE_PTR`.** The R16.M3 growth
  path must reserve `0` as "unused" so `fd_alloc`'s zero-test stays
  correct after the slot widens. If the vnode allocator can ever
  return `0` as a valid pointer, fd_alloc misclassifies it as free.
  Fix at R16.M3: vnode alloc never returns 0 (initialized to point
  at a low-half sentinel). Not a R15.M5 concern; flagged here for
  the R16.M3 designer.
- **Bounds check absence at fd_get/fd_set.** A misbehaving syscall
  layer that passes `fd >= FD_TABLE_MAX` reads/writes into the
  reserved 1280-byte pad — no observable damage at R15.M5 (the pad
  is unused), but at R16.M3 that overwrite could hit
  `wait_child_pid` at offset 1704 (fd = 192 = 1704 / 8 - 21).
  Mitigation: R16.M3 syscall wrappers **must** enforce `fd < 32`
  before calling `fd_get`/`fd_set`. This design pins that
  requirement as a documented contract on the primitive, not an
  enforced runtime check.

## 9. References

- Issue: paideia-os#549
- Milestone: paideia-os milestones/61 (R15.M5 Process abstraction)
- Sibling issues: #543 (layout freeze), #544 (task_pool),
  #548 (task_new), #550 (task_free), #551 (boot_r15_process smoke)
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 8 (line 862 onwards; fd_table @ 168 line 884)
- Master plan: `design/milestones/r14b-master-plan.md`
  §M19 / VFS deliverables (line 523: `fs/fd_table.pdx`)
- paideia-as: `tools/paideia-as/tests/build-emit/mov_mem_imm_sib_disp.pdx`
  (SIB + disp32 encoding baseline for the three one-liners)
- Prior-art witness pattern: `design/kernel/r15-m1-010-phys-free-real-body.md`
  (phys_free — same shape of `.bss` blob + witness block + marker line)
