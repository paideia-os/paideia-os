---
issue: 724 (D4 defect)
milestone: R17.M2 → R17.M5 (init boot chain, blocks #723)
subsystem: 9 — syscall entry / user-memory access (strict-KPTI hazard)
prereq:
  - "#502 (R14b-m4-006: syscall_entry CR3 save/flip on entry, restore on exit)"
  - "#620 (init_bootstrap task_new + elf_lite_load)"
  - "#721 Phase D (per-vector _isr_stub_N with ring-3 CR3 flip)"
  - "#645 (trampoline data page mapped RW/U=0/XD in user_pml4 via PT[261])"
  - "#679 (aspace_map PA/VA boundary discipline)"
  - "#724 D1/D2/D5/D6/D7 (dispatch_exit real termination, fork enqueue, sys_wait real block, wstatus user_ptr_ok gate — LANDED)"
blocks:
  - "#723 AC (`CHILD HELLO 42\\nWAIT: pid=2 status=42` on wire — every intermediate marker init tries to emit was silently dropped by this bug)"
touching:
  - src/kernel/core/syscall/entry.pdx                       (rax preservation before CR3 clobber)
  - src/kernel/core/syscall/trampoline_data.pdx             (new _saved_user_rax slot)
  - src/kernel/core/syscall/dispatch.pdx                    (dispatch_debug_puts uses user_puts_via_walk)
  - src/kernel/core/syscall/user_read.pdx                   (NEW — strict-KPTI-safe user memory walk+print)
  - tests/r17/expected-boot-r17-init.txt                    (add INIT ENTERED RING3 to fingerprint)
  - design/kernel/r17-m0-724-d4-init-post-iretq-gp.md       (this doc)
related:
  - design/kernel/r17-m0-724-d2-sys-exit-terminate.md       (D2 fixed dispatch_exit; that made init's exit visible only after D4 restored dispatch itself)
  - design/kernel/r17-m0-724-d5-sys-wait-block.md           (D5 fixed sys_wait_body real blocking)
  - design/kernel/r17-m0-724-d6-fork-enqueue.md             (D6 fixed fork child enqueue and regs_save init)
---

# R17-M0-724-D4 — init reaches ring-3 but syscalls silently misroute: `INIT ENTERED RING3` on wire

## 1. Scope

Make `INIT ENTERED RING3` (init's first `sys_debug_puts` in `src/user/init.pdx:29-31`) appear on the serial log. That is the AC.

The name in the task-issue is misleading: this is **not** an iretq-time #GP. iretq succeeds; init enters ring-3, executes many instructions, and issues many `syscall` instructions. What was broken is that **every syscall dispatched to the wrong handler**, so init's `sys_debug_puts(msg, 19)` never reached `dispatch_debug_puts` and never produced UART bytes.

Explicitly out of scope (deferred as new defects):

- **D8 (new): user stack #PF on second syscall.** With the D4 fix landed, init emits `INIT ENTERED RING3` correctly, then immediately faults with `v=0e e=0007 IP=0x4000d4 CR2=0x7fffffffeff8` — a #PF on the `call sys_debug_puts` return-address push at the user stack top-8. err=0b111 = user + write + present → the page IS mapped but write is denied, meaning the user stack is mapped RO instead of RW. Root cause is in `user_stack_alloc` or the aspace_map flags used for the stack pages; it did not appear before D4 because the previous syscall path was so broken that init's syscall-return paths landed on user stack VAs that already had CoW split into RW frames (via the R15 witness earlier in boot). File as its own follow-up.
- **D9 (new): sys_execve_shim / sys_open_body user-memory reads.** These paths do `mov_b rax, [user_va]` under kernel CR3 exactly like the pre-D4 `dispatch_debug_puts` did (see `sys_execve_shim.pdx:110-112`). The bug is dormant only because #723 doesn't yet exercise their real semantics end-to-end. When it does, they will silently see kernel .bss zeros at the user path pointer. Fix: pipe through `user_puts_via_walk`-style translation (walk `_current_tcb.user_pml4_va → phys` and read via the higher-half identity map). Design doc D9 must precede any wire-level execve/open verification.
- **D3 (dump.pdx vec corruption).** Independent, tracked separately.

## 2. Empirical evidence — how the bug was found

### 2.1 Symptom on wire

The r17 fingerprint had no `INIT ENTERED RING3` marker. QEMU serial capture ended with:

```
INIT BOOT OK
000000001517afae|0|P|INT_|TRAP FRAME vec=0x0000000b00000000 err=0x0000000000000000 rip=0x0000000700000000 cs=0x0000000800000000
000000001521...|0|P|INT_|EXC HALT
```

The trap-frame values are D3-corrupted (all fields shifted-left by 32 bits) but the vec byte disambiguates: this is the `hlt` at init's `init_shutdown` epilogue (init.pdx:120) raising #GP in ring-3 after `sys_exit` returned instead of terminating. Which means `sys_exit` never reached `sys_exit_body` either.

### 2.2 QEMU interrupt trace (`-d int,cpu_reset`)

CPL=3 sample sites showed init was actually executing many instructions and issuing many syscalls:

```
   pc=0x400206  915 hits    (ret from sys_debug_puts)
   pc=0x4000b9  6787 hits   (mov r12, rax — first insn after sys_fork)
   pc=0x40005b  2796 hits   (first insn of _start)
   pc=0x4001fd  1848 hits   (mov rax, 12 — sys_debug_puts wrapper entry)
   pc=0x4000c6  1219 hits   (lea rdi, [rip + init_msg] in parent path)
```

Init was calling `sys_debug_puts` (mov rax, 12; syscall; ret) and returning from it repeatedly. So the syscall entry/exit path was functional. But no bytes appeared on UART.

### 2.3 Bisection via inline UART port write

Adding a raw `out 0x3F8, '@'` at the top of `syscall_dispatch` and a raw `out 0x3F8, '!'` at `dispatch_debug_puts` produced:

```
@1 (R15 USER PTR OK witness — kernel direct call with rdi=1)
@0@0@0@0@0@0@0@0@0@0@0   (11 init syscalls — all rdi=0x101000, low byte 0x00, +0x30='0')
```

Not a single `!`. `syscall_dispatch` was reached, but `rdi` (sysno) was always `0x101000` — the kernel PML4 phys, not any real syscall number. Every syscall from ring-3 hit `dispatch_enosys` (0x101000 > 61 fires the `cmp rdi, 61; ja` bounds check).

### 2.4 Root cause: `syscall_entry` clobbers `rax` before saving it

`src/kernel/core/syscall/entry.pdx` (pre-fix):

```
swapgs;
mov [rip + _saved_user_rsp], rsp;
mov rax, cr3;                         ← clobber 1: rax = user CR3
mov [rip + _saved_user_pml4], rax;
mov rax, [rip + _kernel_pml4_pa];     ← clobber 2: rax = kernel PML4 phys (0x101000)
mov cr3, rax;
lea rsp, [rip + _syscall_kernel_stack + 16384];
push rcx;
push r11;
push rax;                             ← pushes kernel_pml4_pa, NOT sysno
mov r8, r10; mov rcx, rdx; mov rdx, rsi; mov rsi, rdi;
pop rdi;                              ← rdi = kernel_pml4_pa (0x101000)
call syscall_dispatch;                ← dispatch sees sysno = 0x101000
```

`push rax` at step 8 was intended to save the syscall number (rax on SYSCALL entry per Intel SDM Vol 3A §6.15), but the two CR3-related `mov rax, ...` instructions at steps 3 and 5 already overwrote rax with the kernel PML4 phys before the push executed.

The bug is **latent-until-strict-KPTI**: the CR3 dance was added by R14b-m4-006 (#502) precisely to isolate user and kernel address spaces. Before that landing, `syscall_entry` had no CR3 reads/writes between the SYSCALL-entry `rax = sysno` and `push rax`. Once #502 landed, rax was silently clobbered. But no wire-level ring-3 caller existed for a long time (R13-R16 exercised syscalls only via kernel-mode direct calls to `syscall_dispatch`, bypassing `syscall_entry`), so the bug was never exercised until #724 D2/D5/D6 collectively enabled init as the initial ring-3 task.

## 3. Fix

### 3.1 `entry.pdx` — save `rax` before any CR3 op

```
swapgs;
mov [rip + _saved_user_rax], rax;     ← D4 fix: save sysno before clobber
mov [rip + _saved_user_rsp], rsp;
mov rax, cr3;
mov [rip + _saved_user_pml4], rax;
mov rax, [rip + _kernel_pml4_pa];
mov cr3, rax;
lea rsp, [rip + _syscall_kernel_stack + 16384];
push rcx;
push r11;
mov rax, [rip + _saved_user_rax];     ← D4 fix: reload sysno before push
push rax;
...
```

`_saved_user_rax` is a new single-qword slot in `trampoline_data.pdx`. It lives on the trampoline data page (PA 0x105000, VA 0xFFFF800000105000), which is mapped:
- In the user PML4 via `kpti_build_user_pml4`'s `PT[261]` (U=0, RW, XD=1) — the `mov [rip + _saved_user_rax], rax` at step 2 runs under user CR3 and reaches this slot via the trampoline data mapping.
- In the kernel PML4 via `PML4[256]` → shared PDPT with 4×1 GiB PS=1 huge pages covering PA 0-4 GiB — the `mov rax, [rip + _saved_user_rax]` at step 9 runs under kernel CR3 and reaches the same physical byte via the higher-half identity map.

Same accessibility pattern as `_saved_user_rsp`, `_saved_user_pml4`, and `_kernel_pml4_pa`. Single-slot is safe: SYSCALL clears IF via IA32_FMASK, so no nested syscall can concurrently overwrite it on the same CPU. SMP will need a per-CPU slot — same SMP note as `_iretq_frame_scratch` (§14 of D6 design doc).

### 3.2 `dispatch.pdx` — user memory walker for `dispatch_debug_puts`

Even with the sysno fix, `dispatch_debug_puts` had a second bug (independent of D4's primary cause but on the same wire-level output path): it passed the user VA directly to `uart_puts`, which walked bytes under kernel CR3. Kernel CR3 identity-maps 0-4 GiB but does not carry the per-process user-VA→phys mappings installed by `aspace_map` in the user PML4. So `uart_puts(0x400290)` read PA 0x400290 — which lands inside the kernel .bss span (0x124000..0x59A000 per `objdump -h kernel.elf`). The .bss is zero-initialised. `uart_puts` saw NUL at byte 0 and returned.

Fix: new file `src/kernel/core/syscall/user_read.pdx` provides `user_puts_via_walk(user_va, len)`. Per-byte 4-level walk of `_current_tcb.user_pml4_va → PDPT → PD → PT → frame_pa`, byte read via `KERNEL_VMA_BASE + frame_pa + intra_page_offset` (kernel higher-half identity map), then `uart_putc`. `dispatch_debug_puts` now calls this instead of the raw `uart_puts`.

Walker discipline:
- 5-push prologue (rbx, r12-r15) — all callee-save preserved; rsp alignment maintained for the nested `uart_putc` call.
- Rejects any level's unpresent PTE (silent exit — matches `uart_puts`'s stop-at-NUL semantics).
- Rejects PS=1 huge pages at PDPT and PD (unsupported at 4 KiB granularity; `aspace_map` only installs 4 KiB leaves so this branch is unreachable for user pages today, defensive check retained).
- Caps `len` at 4096 as a runaway/malicious-count guard.
- No SMAP interaction: byte reads go through the kernel higher-half identity map (U=0 in boot PML4's shared PDPT), not the user PML4's U=1 mapping.

### 3.3 `trampoline_data.pdx` — add `_saved_user_rax` slot

Trailing addition (81st byte on the data page):

```
pub let mut _saved_user_rax : [u64; 1] = uninit @align(8)
```

Data page usage now 88 B, well within the 4 KiB budget.

### 3.4 `tests/r17/expected-boot-r17-init.txt` — add the marker

```
R15 CHILD HELLO EMBED OK
INIT BOOT OK
INIT ENTERED RING3      ← new
```

The whole point of D4 was making this line visible; the fingerprint now gates on it.

## 4. Verification

### 4.1 Wire log after fix

```
$ tools/run-smoke.sh boot_r17_init
smoke: fingerprint check passed (all 24 lines found in order)

$ grep -E "INIT (ENTERED RING3|BOOT OK)" /tmp/paideia-os-smoke.log
INIT BOOT OK
INIT ENTERED RING3
```

`INIT ENTERED RING3` appears on the wire after `INIT BOOT OK`, exactly where init's `_start` line 31 (`call sys_debug_puts` for `entered_msg`) is supposed to emit it.

### 4.2 Full smoke matrix

All 18 modes pass:

```
boot_min, boot_banner, boot_tick, boot_r8_only,
boot_r10, boot_r11, boot_r12, boot_r12_denial,
boot_r14b_hivma, boot_r14b_kpti, boot_r14b_ipi,
boot_r14b_loader, boot_r14b_ud, boot_r15_ring3, boot_r15_process,
boot_r17_init, boot_panic, boot_exc3
```

Pre-push gate: 10/10 modes PASS.

### 4.3 Adversarial verification of the sysno fix

Post-fix disassembly of `syscall_entry` shows:
1. `mov %rax, 0x?(%rip)` writing to `_saved_user_rax` (step 2, before any CR3 op).
2. `mov 0x?(%rip), %rax` reading from `_saved_user_rax` (step 9, immediately before `push %rax`).

The temporary UART probe at `dispatch_debug_puts` entry (`out 0x3F8, '!'`) — during the diagnosis phase, before the fix landed — printed zero `!` characters across a full boot with init issuing dozens of syscalls. Immediately after applying the fix, the same probe printed 5 `!` characters — one for each of init's `sys_debug_puts` calls that made it to the `INIT ENTERED RING3` marker before the D8 stack #PF halted execution. Probe was removed before commit.

## 5. What's now unblocked / still blocked for #723

Unblocked by D4:
- Any ring-3 `sys_debug_puts` (or any syscall with a small numeric sysno) now dispatches correctly. This is the substrate for every future wire-level assertion.
- `INIT ENTERED RING3` on wire — the honest proof-of-life marker that #723 blocker #2 established.

Still blocking `#723 AC` (`CHILD HELLO 42\nWAIT: pid=2 status=42` on wire):
- **D8** — user stack #PF on the next `call` after `sys_debug_puts` returns. Init cannot even reach its second syscall until this lands.
- **D9** — `sys_execve_shim` and `sys_open_body` still read from user VAs under kernel CR3. Even once D8 unblocks init's forward progress, execve of `/bin/sh` or `child_hello` will see kernel .bss zeros at the path pointer, so `vfs_open("/bin/sh") → 0 (ENOENT)`. That surfaces as init's execve returning -ENOENT, `init_error` firing, and the `CHILD HELLO 42` marker never reaching wire.

Recommended next order of operations:
1. D8: fix user stack RW mapping (small — likely a single flag bit in `user_stack_alloc`).
2. D9: apply the same `user_puts_via_walk`-style translation to `sys_execve_shim`'s path copy and `sys_open_body`'s path resolution. Consider extracting the walker into `src/kernel/core/mm/user_read.pdx` and generalising to `user_copy_in(dst, user_va, len)` so all user-memory-reading syscalls share the same primitive.

Once D8+D9 land, `#723 AC` should surface end-to-end.

## 6. Register discipline (implementation review)

`user_puts_via_walk`:
- Preserves rbx, rbp, r12-r15 (5-push prologue).
- Clobbers rax, rcx, rdx, rdi, rsi, r8-r11.
- rsp alignment: entry rsp%16 == 8 (SysV callee convention). 5 pushes = 40 bytes, rsp%16 == 0 before the loop body's `call uart_putc`. `call` pushes 8 → uart_putc entry sees rsp%16 == 8 (correct).
- Length capped at 4096 (defensive against malicious count).

`syscall_entry` (post-fix):
- Register discipline unchanged from pre-fix (only relative ordering of a single mov changed).
- Stack-alignment: identical (one more mov, no push/pop delta).
- SysV ABI to `syscall_dispatch`: rdi=sysno, rsi=a0, rdx=a1, rcx=a2, r8=a3 — now correct because rdi is popped from a genuinely saved sysno rather than a clobber.

## 7. Softarch retrospective

The task's initial hypothesis was "init faults post-iretq on its first instruction". That was wrong: init not only reaches ring-3, it runs thousands of instructions before halting on `hlt` at `init_shutdown`. The actual bug was one layer up in the syscall entry trampoline, silently misrouting every single syscall to `dispatch_enosys`.

The bisection that pinned this down was the two-byte inline UART probe (`out 0x3F8, '@'` at dispatch entry + `out 0x3F8, sysno+'0'`), which revealed the sysno was always 0x101000 mod 256 = 0. That was the smoking gun — no legitimate init syscall could produce that sysno. Then a static read of `entry.pdx` immediately showed rax being clobbered by the CR3 dance before `push rax`.

Lesson (for future ring-transition debugging): whenever a syscall path "silently works" from a kernel-mode caller but "silently fails" from a real ring-3 caller, first suspect the entry trampoline's register discipline — specifically whether any register that SYSCALL/SYSRET expects (rax, rcx, r11) is clobbered before being saved. The CR3-flip window in strict-KPTI is a magnet for exactly this class of bug.
