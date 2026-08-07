# R17-M0 #728 (#724 D9): sys_exit → sched_switch #UD — Shared Kernel Stack Corruption

**Issue**: paideia-os#728 (parent of #724 D9)
**Landed on**: 2026-08-06
**Predecessor**: #727 (D8) — init reaches both INIT OK markers on wire (parent post-fork + child post-execve-failure)
**Successor (blocker cascade)**: still gates #723 AC (`CHILD HELLO 42\nWAIT: pid=2 status=42`)

---

## 1. Wire evidence

Reproducible under `tools/run-smoke.sh boot_r17_init` at HEAD `38d583d`. Trap frame
verbatim from `/tmp/paideia-os-smoke.log`:

```
0000000014757fba|0|P|INT_|TRAP FRAME vec=0x0000000000000006 err=0x0000000000000000 rip=0x000000000000002d cs=0x0000000000000008
0000000014915c38|0|P|INT_|TRAP FRAME rfl=0x0000000000000093 rsp=0xffff800000598fc8 ss=0x0000000000000010
```

Decoded:

| Field | Value | Interpretation |
|---|---|---|
| vec  | 6    | #UD — Invalid Opcode (no `err_code`) |
| cs   | 0x08 | ring-0 kernel code segment |
| rip  | 0x2d | garbage (kernel-VA 0x2d has no code) |
| rfl  | 0x93 | garbage flags — bit 1 (reserved-must-be-1) plus CF/AF/SF; no IF, no ID |
| rsp  | 0xffff800000598fc8 | inside `_syscall_kernel_stack` |
| ss   | 0x10 | ring-0 kernel data segment |

Address math: `_syscall_kernel_stack = 0xffff800000595000`, size 16384 bytes,
so top = `0x599000`. `0x598fc8 = top − 56 = top − 0x38`. This is the rsp
value **immediately after** the `ret` inside `sched_switch_r15`'s load phase
popped one qword.

Chain of markers leading to the fault:

```
INIT ENTERED RING3   <- parent init first ring-3 syscall (sys_debug_puts)
INIT OK              <- parent after fork(), before wait4
INIT OK              <- child after failed execve() falls through into init_error
<fault>              <- child sys_exit dispatch → sched_switch_r15(init) → ret
```

## 2. Why the earlier framing was wrong

The original #728 report guessed `execve` was reading a user VA from kernel CR3
and #PF'ing during copy-in. The debugger's D-run at 2026-08-06 falsified this by
GDB-stepping to the exact faulting instruction and observing:

- The vector was `#UD` (0x6), not `#PF` (0xE) — CR2 was not even in the trap frame.
- The faulting rip was `0x2d`, not a user VA. This is not "unmapped memory" —
  it is a value the CPU dereferenced as an instruction pointer.
- The rsp at fault was on the kernel stack (higher-half `0xffff800000598fc8`),
  not on any user or trampoline page — meaning the fault happened well past
  `execve`, in a much later scheduler swap.

Moving past that framing: the fault is at the `ret` in `sched_switch_r15`'s
load phase, popping what should be the incoming task's `regs_save.rip` off the
incoming task's own kernel stack. It popped `0x2d` instead of a real code
address and #UD'd on the jump.

## 3. Instrumentation and empirical root cause

The debugger added klog probes at three points:

1. `sys_exit_body` after the state=RUNNABLE store (right before dispatch_exit's
   runq_dequeue), dumping the parent slab pointer and `[parent + 40]`
   (`regs_save.rip`). **Observed**: parent = init's TCB at
   `0xffff800000571000`, `regs_save.rip = 0xffff800000112310` — i.e., exactly
   `&sched_switch_r15_continuation`, as it should be.

2. `sched_switch_r15` load phase, right before the `push rcx` that pushes the
   incoming rip onto the incoming stack. **Observed**: `rdi = 0xffff800000571000`
   (init), loaded `rcx = 0xffff800000112310` (same continuation address). The
   value being pushed onto init's kernel stack is correct.

3. `sched_switch_r15` load phase, right before the `ret` that consumes the
   pushed rip. **Observed**: `[rsp] = 0xffff800000112310` (correct). GDB then
   stepped the `ret` and observed CPL=0 rip = `0xffff800000112310` (successful
   jump into `sched_switch_r15_continuation`).

So the **first** `ret` in the chain (`sched_switch_r15` → `continuation`)
works exactly as intended. The `regs_save.rip` slot is neither uninitialized
nor overwritten. All the original candidate root causes are refuted:

- ~~sched_block doesn't save rip~~ → It does; the slot holds `&continuation`.
- ~~sched_switch_r15 has an offset bug~~ → No; save@+40, load@+40, both correct.
- ~~init's regs_save was never populated~~ → It was, and it holds the right value.
- ~~picked task is idle, not parent~~ → It is init, confirmed by TCB pointer.

The fault is one `ret` later. `sched_switch_r15_continuation` executes:

```
popfq;                                    // pop rflags off init's kernel stack
ret                                       // pop caller's return address off init's kernel stack
```

That second `ret` is what triggers the #UD. It is popping the **caller's
return address** — the return address for `call sched_switch_r15` that was
saved on init's kernel stack when init entered `sched_switch_r15` from
`sched_block` back in `dispatch_wait4`.

The debugger observed that slot's content is unstable across timings:
`0x2d` in the natural run, `0x16` under single-step — i.e., it is **stale
data left over by unrelated writes**, not any value the sched path stored.

## 4. Root cause: `_syscall_kernel_stack` is a single global shared across all tasks

Located: `src/kernel/core/syscall/kernel_stack.pdx:10`.

```pdx
pub let mut _syscall_kernel_stack : [u64; 2048] = uninit @align(16)
```

Every `syscall_entry` (`src/kernel/core/syscall/entry.pdx:51`) resets rsp
to the top of this **one** buffer:

```pdx
lea rsp, [rip + _syscall_kernel_stack + 16384];
```

Timing that produces the fault (all four steps happen on the same physical
kernel stack region):

| Time | Task | Action | Effect on init's saved kernel stack |
|---|---|---|---|
| T1 | init  | `syscall_entry` for wait4 sets rsp = top of _syscall_kernel_stack | init's push chain begins near top |
| T2 | init  | `dispatch_wait4 → sched_block → call sched_switch_r15` — RA is pushed at kstack top-48 (approx) | init's RA lives at approximately `top − 48` (in bytes: `_syscall_kernel_stack + 16336`) |
| T3 | init  | `sched_switch_r15` saves `init.regs_save.rsp = <top − 48>`, `.rip = &continuation`, then switches out to child | init's saved rsp _points into the shared stack_ |
| T4 | child | `sys_fork_child_landing` → ring-3 → child issues execve, debug_puts, debug_puts, exit — each with its own `syscall_entry` that resets rsp to `top` and pushes a fresh call chain | child's pushes overwrite the bytes at `top − 8, top − 16, …, top − 48, …` — the same region that holds init's RA |
| T5 | child | `dispatch_exit → sched_switch_r15(init)` — save child's regs; load init's regs; push init's rflags at `top − 56`; push init's rip (`&continuation`) at `top − 64`; `ret` pops `&continuation` and jumps to it | reaches `continuation`; init's kernel stack rsp is now `top − 56` |
| T6 | init resumed | `continuation` does `popfq; ret` — the `ret` pops the qword at `top − 48` expecting init's saved RA, but that byte has been overwritten by child's pushes; **pops `0x2d` and #UD's** | fault |

The one-line summary: **the kernel syscall stack is per-CPU (implicitly, via
being a single global), but the R17-M0-724-D5a wait4→sched_block change made
kernel-stack lifetime per-task-block-cycle rather than per-syscall.** Blocking
inside a syscall while another task's syscalls execute breaks the shared-stack
assumption. The `kernel_stack.pdx` header already notes the SMP hazard
(`SINGLE-CPU ONLY`), but the deeper problem is that even on a single CPU,
cooperative-blocking syscalls need per-task kernel stacks.

## 5. Bug class

This is a new class in the R17.M0 fault taxonomy — call it **"shared per-CPU
global vs. per-task lifetime mismatch"**. It is distinct from:

- rax-clobber (register discipline within a single trampoline)
- PTE mask (bit-layout wrongness in aspace_map)
- IST hazards (interrupt stack sharing between vectors)
- CR3-source (encoder gap for `mov crN, r14`)

The concrete symptom family: any global state that a task depends on across
its own `blocked → runnable` transition can be clobbered by another task while
the first task is blocked. In this landing we fix two members of the family:

1. `_syscall_kernel_stack` (this bug, direct cause of the #UD)
2. `_saved_user_rsp` (latent — would cause init to sysret to the wrong rsp
   the moment the first bug is fixed and init actually reaches the epilogue)

The third potential member — `_saved_user_pml4` — we neutralise by
derivation rather than storage.

## 6. Fix

### 6.1 Per-task kernel stack

**Storage**: `_task_kernel_stacks : [u64; 65 × 2048] = uninit @align(16)` in
`task_pool.pdx`. 65 × 16 KiB = 1040 KiB in `.bss`. Sixty-four slots for pids
1..64 plus a padding slot to keep the address math simple.

**TCB field**: `TASK_OFF_KSTACK_TOP : u64 = 24`. Byte offset 24 is a
previously-unused gap in the 2224-byte task_struct (between `user_pml4_pa` at
+16 and `regs_save.rsp` at +32); grep confirms nothing else on task_struct
slabs writes there.

**Population**: `task_new` sets the field on step 6, computing
`kstack_top = &_task_kernel_stacks + pid × 16384`. Pid 0 slot is unused
(pids start at 1) but keeping the arithmetic uniform avoids a subtract.

**Consumption**: `syscall_entry`'s stack-switch instruction changes from

```
lea rsp, [rip + _syscall_kernel_stack + 16384];
```

to

```
mov rax, [rip + _current_tcb];
mov rsp, [rax + 24];
```

This executes **after** the CR3 flip to kernel PML4, so both `_current_tcb`
(kernel `.bss`) and the TCB slab (kernel `.bss`) are accessible. Per-task
kernel stacks in `.bss` need no `kpti` mapping into user PML4 — they are only
touched under kernel CR3.

The existing `_syscall_kernel_stack` symbol stays defined (with a comment
downgrading it to "legacy, unused") to keep the smoke-test fingerprint stable
during the crossover; a follow-up can delete it once nothing else references
the name.

### 6.2 Per-task saved user rsp

**TCB field**: `TASK_OFF_SAVED_USER_RSP : u64 = 104`. Also a previously-unused
gap (between the last callee-save slot at +96 and `fd_table` at +168).

**Population**: `syscall_entry` copies from the global trampoline slot into
the per-task slot immediately after switching to the per-task kernel stack:

```
mov rax, [rip + _current_tcb];
mov rsp, [rax + 24];                     // (this is the kstack switch above)
mov rcx, [rip + _saved_user_rsp];
mov [rax + 104], rcx;                    // per-task copy
```

Every syscall from any task re-populates its own slot; the value survives
being blocked across another task's arbitrary syscalls because the other task
writes only its own slot.

**Consumption**: `syscall_entry`'s epilogue reads from the per-task slot:

```
mov rax, [rip + _current_tcb];
mov rsp, [rax + 104];                    // per-task saved user rsp
```

replacing the previous global read of `[rip + _saved_user_rsp]`.

### 6.3 Deriving user PML4 from the TCB (avoids adding a third field)

`_saved_user_pml4` has the same shared-global hazard as `_saved_user_rsp`,
but the value is fully determined by the current TCB (`user_pml4_pa` at +16,
in "phys_alloc VA form" per #658). The epilogue derives it in-place:

```
mov rax, [rip + _current_tcb];
mov rsp, [rax + 104];                    // per-task rsp (§6.2)
mov rax, [rax + 16];                     // user_pml4_va
mov r10, 0xFFFF800000000000;             // KERNEL_VMA_BASE
sub rax, r10;                            // convert to genuine PA
mov cr3, rax;
```

This mirrors the `sub r9, r10` pattern used in `sys_fork_child_landing`
(`enter_user.pdx:92-93`) and in the shell/init boot path
(`kernel_main.pdx:7026-7028`). No new TCB field is needed. `_saved_user_pml4`
in `trampoline_data.pdx` stays defined but its epilogue read is dropped.

### 6.4 Fork snapshot rewire

`sys_fork_body` (`sys_fork.pdx:119-129`) previously read parent's saved user
rip and rflags from fixed offsets in `_syscall_kernel_stack`:

```
lea rax, [rip + _syscall_kernel_stack];
add rax, 16376;                          // 16384 − 8, where syscall_entry pushed rcx
mov rcx, [rax];                          // parent user rip
```

With per-task kernel stacks, this must read from **parent's** kernel stack
top instead. `rbx` already holds the parent slab; the rewrite:

```
mov rax, [rbx + 24];                     // parent kstack top
mov rcx, [rax - 8];                      // parent user rip  (first push in syscall_entry)
mov [r12 + 1720], rcx;                   // child.fork_user_rip

mov rcx, [rax - 16];                     // parent user rflags (second push)
mov [r12 + 1736], rcx;                   // child.fork_user_rflags
```

Negative displacements are already used elsewhere (`klog/wrappers.pdx:50` etc.)
so the encoder accepts this.

### 6.5 Nothing to change in `sched_switch_r15`

Because syscall_entry now writes the per-task saved_user_rsp on every entry,
the switch code itself does not need to know about it. Each task's
per-task-slot always reflects that task's most-recent syscall entry, which is
exactly what the epilogue needs on resume.

## 7. Files touched

| File | Change |
|---|---|
| `src/kernel/core/sched/task_pool.pdx` | Add `_task_kernel_stacks`, constants, populate `[slab+24]` in `task_new` |
| `src/kernel/core/syscall/entry.pdx` | Per-task kstack switch; per-task saved_rsp copy on entry; TCB-derived pml4 on epilogue |
| `src/kernel/core/syscall/handlers/sys_fork.pdx` | Snapshot parent's user rip/rflags from parent's kstack, not from global |
| `src/kernel/core/syscall/kernel_stack.pdx` | Comment `_syscall_kernel_stack` as legacy/unused (no code changes) |

## 8. Verification (observed at fix commit)

Under `tools/run-smoke.sh boot_r17_init`, wire log tail:

```
INIT BOOT OK
INIT ENTERED RING3
INIT OK           <- parent init after fork
INIT OK           <- child init after execve failure (init_error)
REAPED            <- parent init: wait4 returned, dispatch_wait4 writeback + sysret works
```

Then init calls `sys_exit(0)` → `dispatch_exit` → `sys_exit_body` (parent
already reaped, orphan_adopt no-op, parent_pid=0 so no wake) →
`runq_dequeue(init)` → `sched_pick_next_r15` returns `_idle_tcb` (runq
empty) → `sched_switch_r15(idle)`. Idle `hlt` loop. QEMU timeout at 8s
with no faults.

No trap frames in the run. Six `TRAP FRAME` lines appear in the log but
all six are the panic-dump witness's `MAX LEN CANARY` fixture (values
`0xdeadbeef`, `0xfeedface`, `0x0badc0de`, etc.) emitted long before the
init boot phase.

Fingerprint `tests/r17/expected-boot-r17-init.txt` extended by two lines
(the second `INIT OK` and `REAPED`) to 27 total — all present, in order.

Full 19-mode smoke matrix green: boot_min, boot_banner, boot_tick,
boot_r8_only, boot_r10, boot_r11, boot_r12, boot_r12_denial,
boot_r14b_hivma, boot_r14b_kpti, boot_r14b_ipi, boot_r14b_loader,
boot_r14b_ud, boot_r15_ring3, boot_r15_process, boot_r17_init, boot_panic,
boot_panic_halt, boot_exc3. Pre-push gate (10 modes) also green.

## 9. Follow-ups (out of scope for D9)

- `_syscall_kernel_stack` can be deleted entirely once a full-tree grep
  confirms nothing else references the name.
- SMP will need per-CPU × per-task kstack indexing; the current 65-slot
  static array becomes per-CPU-per-task, but the per-task field structure
  survives unchanged.
- `_saved_user_rax` in `trampoline_data.pdx` is not a member of this bug
  family: it only lives across the CR3-dance inside a single `syscall_entry`,
  never across a task switch. It stays global.
- The `_iretq_frame_scratch` slot (used by `sys_fork_child_landing` and
  `enter_userland_initial`) is also a member of the family — but both users
  execute with IF=0 through the `iretq`, so no other task can preempt-write
  it. Its SMP fix is separate.

## 10. AC distance from #723

D9 removes the sys_exit→sched_switch #UD and confirms init's full
fork → wait → reap → exit cycle works. On wire:

```
INIT ENTERED RING3
INIT OK              (parent post-fork)
INIT OK              (child post-execve-failure — init_error branch)
REAPED               (parent wait4 completes)
```

The AC (`CHILD HELLO 42\nWAIT: pid=2 status=42`) requires two more layers:

1. **execve /bin/sh (or /bin/child_hello) must succeed** — currently fails,
   which is why the child prints the second INIT OK from `init_error`.
   The failure surface is inside `sys_execve_shim` or the ELF load path;
   D10 will bisect exactly which step returns non-zero. Once execve
   succeeds, `sys_fork_child_landing` iretq's into the loaded image
   rather than back to the parent's saved user rip, and the child never
   reaches `init_error`.

2. **A user program that emits `CHILD HELLO 42` and exits with status 42**
   must be reachable and running. `child_hello_embed` is embedded in the
   kernel (per `R15 CHILD HELLO EMBED OK`); making it the child's execve
   target and wiring the parent to print `WAIT: pid=N status=42` on
   reap completes the AC.

D9 does not remove #723 by itself — but it clears the last kernel-side
scheduler blocker. Everything remaining is either in the userland ELF
image, the execve path, or the shell/init respawn logic — none of which
touched by this landing.
