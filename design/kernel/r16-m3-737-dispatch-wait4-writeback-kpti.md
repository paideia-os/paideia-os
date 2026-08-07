---
issue: 737
milestone: R17.M0 (init boot chain; closes remaining lie in #723 AC)
subsystem: 9 — syscall entry / user-memory access (strict-KPTI hazard)
prereq:
  - "#502 (R14b-m4-006: strict-KPTI CR3 flip on syscall entry/exit)"
  - "#541 (user_ptr_ok range check — dispatch_wait4 gate)"
  - "#724 D4 (user_puts_via_walk — first KPTI-safe user memory helper)"
  - "#730 D10c (dispatch_write_uart → user_puts_via_walk)"
  - "#730 D10d (user_read_str_via_walk — second KPTI-safe helper)"
  - "#725 (dispatch_wait4 user_ptr_ok gate)"
  - "#731 (syscall_entry rax preservation across sysret CR3 flip)"
  - "#732 (wait4 arg marshalling: pid/wstatus register shuffle)"
  - "#736 (D12: runtime u32→decimal in init wait_msg — made the D12 lie visible)"
blocks:
  - "#723 AC (final honest line — one of two lies exposed by D12; the other is #735 pid leak, orthogonal)"
touching:
  - src/kernel/core/syscall/user_read.pdx                        (NEW helper: user_write_u32_via_walk)
  - src/kernel/core/syscall/dispatch.pdx                         (dispatch_wait4_writeback: raw store → helper call)
  - tools/verify-syscall-dispatch.sh                             (check 13 accepts the helper-call form)
  - tests/r17/expected-boot-r17-init.txt                         (fingerprint: status=0 → status=42)
  - design/kernel/r16-m3-737-dispatch-wait4-writeback-kpti.md    (this doc)
related:
  - design/kernel/r17-m0-724-d4-init-post-iretq-gp.md            (D4: first sibling KPTI fix, user_puts_via_walk)
  - design/kernel/r17-m0-730-d10-execve-complete.md              (D10c/D10d: second and third sibling KPTI fixes)
  - design/kernel/r17-m2-736-d12-runtime-u32-decimal.md          (D12: made status=0 visible on wire; unmasked #737 and #735)
follow-ups:
  - "#738 (D14a): dispatch_read fd>=3 latent — user buf write under kernel CR3 via tmpfs_read rep_movsb"
  - "#734 (D14b): dispatch_write fd>=3 latent — user buf read under kernel CR3 via tmpfs_write rep_movsb (pre-existing)"
  - "#733 (D14c): sys_open_body latent — path bytes read under kernel CR3 via path_resolve (pre-existing)"
---

# R16-M3-737 — dispatch_wait4 wstatus writeback KPTI hazard

## 1. Scope

Make `init`'s `WAIT: pid=23 status=42` line on wire report the *actual* child exit code (42 from `child_hello.sys_exit(42)`) instead of the empty-BSS zero the parent was reading.

## 2. Wire evidence

### 2.1 Baseline (pre-fix, at commit b80bf6c after #736 D12 landed)

```
$ tools/run-smoke.sh boot_r17_init
smoke: fingerprint check passed (all 29 lines found in order)

$ grep -E "CHILD HELLO|WAIT:|REAPED" /tmp/paideia-os-smoke.log
CHILD HELLO 42
WAIT: pid=23 status=0     ← child sys_exit(42) but parent sees 0
REAPED
```

`child_hello.pdx` unambiguously calls `sys_exit(42)`; `sys_exit_body` writes `[parent_slab+1708] = 42`; `dispatch_wait4_writeback` correctly loads `edx = 42` from that slab on resume. So the value is *present* in the kernel and correctly propagated all the way to the register holding the writeback source — it is the *store itself* that lands on the wrong physical page.

### 2.2 Debugger-verified snapshot at `dispatch_wait4_writeback` entry

Before the store:
- `rsi = 0x0000000000700000` (init's `wait_status` VA — see init.pdx:41 `pub let mut wait_status : [u64; 1] = uninit @align(8)`)
- `edx = 0x0000002a` (= 42)
- `cr3` = boot PML4 physical (via strict-KPTI CR3 flip in `syscall_entry`)

After the store:
- Physical byte at PA `0x700000` = 42 (whatever kernel data structure sits there gets clobbered)
- Physical byte at *init's user PML4 leaf for VA 0x700000* = 0 (unchanged — init's `wait_status` is in its own zero-initialised BSS frame)

Init subsequently reads its own user PML4 leaf and gets zero. `print_u64_dec` (from #736 D12) formats that zero and emits `status=0`.

## 3. Root cause

`src/kernel/core/syscall/dispatch.pdx:330` (pre-fix):

```asm
mov [rsi], edx;                       // write 4-byte status; validated above
```

Executed under strict-KPTI **kernel CR3** (= `_kernel_pml4_pa` = boot PML4, installed by `syscall_entry` at entry). The boot PML4's low identity map covers PA `0..4 GiB` and therefore *technically* succeeds for any user VA below 4 GiB — but it maps VA `X` to PA `X`, ignoring the per-process user PML4's own frame allocation for that VA. `aspace_map` installs user frames only into the user PML4, never into the boot PML4.

Init's `wait_status` VA is `0x700000` (in the user text/data range). At PA `0x700000` lives whatever the boot PML4's identity map covers — kernel .bss, ELF loader scratch, or unused (a poisoned page). Meanwhile, init's *own* PML4 maps VA `0x700000` to a distinct frame (allocated by `aspace_map` at boot-time for init's writable data). The two frames are physically different by construction.

The `user_ptr_ok` gate at dispatch.pdx:323 *did* protect against the specific hazard #725 was written for (kernel-half wstatus pointer, unmapped page in user-half). It does not — and cannot — detect the KPTI CR3 mismatch, because from user_ptr_ok's Phase-1-only viewpoint the address is a well-formed user-half pointer.

### 3.1 Sibling KPTI defects (same class)

| Sibling | Fix | Location | Direction |
|---------|-----|----------|-----------|
| #724 D4  | `user_puts_via_walk`         | `dispatch_debug_puts` — read from user VA | READ  |
| #730 D10c | `user_puts_via_walk`        | `dispatch_write_uart` — read from user VA | READ  |
| #730 D10d | `user_read_str_via_walk`    | `sys_execve_shim` path copy — read from user VA | READ  |
| **#737**  | **`user_write_u32_via_walk`** | **`dispatch_wait4_writeback` — write to user VA** | **WRITE** |

This is the first *write-side* member of the family. The pattern is symmetric: any `mov`/`rep_movsb` whose destination is a user VA, executed under kernel CR3, hits the boot PML4's low identity map instead of the user PML4's per-VA frame.

## 4. Fix design

### 4.1 The helper: `user_write_u32_via_walk`

New in `src/kernel/core/syscall/user_read.pdx` (module `UserRead` — the file already houses `user_puts_via_walk` and `user_read_str_via_walk`; adding the write counterpart keeps all three KPTI-safe user-memory helpers in one module rather than splitting on read/write axis).

**Contract**:
- `rdi = user_va` (caller-facing; SysV C ABI)
- `rsi = val` (u64; low 32 bits written)
- Returns `rax = 0` on success, `0xFFFFFFFFFFFFFFF2` (-EFAULT) on any failure.

**Failure conditions** — all converge on the same -EFAULT return:
- NULL `_current_tcb` or NULL `current->user_pml4_va`
- PML4E / PDPTE / PDE / PTE with P bit clear
- PDPTE.PS=1 (1 GiB huge, unsupported for user frames — `aspace_map` only installs 4 KiB leaves)
- PDE.PS=1 (2 MiB huge, same reasoning)
- Cross-page 4-byte access (`(user_va & 0xFFF) + 4 > 0x1000`) — unreachable in practice (wstatus is `@align(8)` per init.pdx) but checked defensively for future callers

**Register discipline** (leaf function, no nested call):
- No callee-save prologue. Only caller-save regs touched: `rax, rcx, rdx, rsi, rdi, r8, r9, r10`.
- `rsi` is **preserved** throughout the walk as the value source — the walk indexes are built from a copy of `rdi` in `r10`, freeing `rdi` for reuse without collision.
- `r8` alternates between "user_pml4_va" (initial) and "PTE address (LEA target)" (per level).
- `r9` holds the running kernel VA of the current level's page-table.
- `rax` / `rcx` / `rdx` are scratch (index shifts, mask constants via movabs, cross-page arithmetic).

**No SMAP interaction**: the store lands on the kernel higher-half identity map at boot PML4[256]'s shared 1 GiB PDPT (U=0), not the user PML4's U=1 leaf. SMAP fires only on ring-0 accesses to U=1 pages — same reasoning as the sibling read helpers.

### 4.2 Alternative considered (rejected): inline the walk at dispatch.pdx:330

Would save one call and 5-7 push/pop instructions per wait4 completion. Rejected because:
- Duplication of the 4-level walk boilerplate (~40 instructions) inline in dispatch.pdx would triple the site's noise and diverge from the sibling-helper pattern set by D4/D10c/D10d.
- Any future write-side caller (e.g. `sys_wait4` rusage arg, `read()`'s bytes-read return via user pointer if we grow one) would want the same shape.
- Cost is one indirect call per wait4 completion — a rare path.

### 4.3 Alternative considered (rejected): drop `user_ptr_ok` gate

The walk itself rejects unmapped pages with -EFAULT — the range check would seem redundant. Rejected because:
- `user_ptr_ok` catches kernel-half pointers *before* the walk touches page tables — cheap defense-in-depth.
- The walk today does *not* reject kernel-half VAs cleanly: a VA with PML4 index ≥ 256 would follow the shared kernel PDPT (mapped in every user PML4 by `kpti_build_user_pml4`), and if the kernel VA happens to be present in that PDPT (most kernel data is), the walk would *succeed* and write to the kernel-owned frame. That is a real security hole absent the `user_ptr_ok` gate.
- The sibling helpers (`user_puts_via_walk`, `user_read_str_via_walk`) share this limitation. They avoid the hole today because their callers never pass kernel VAs. Adding an inline `cmp user_va, KERNEL_VMA_BASE; jae fail` at the top of every helper would fix it uniformly — filed as a follow-up hygiene note (not blocking).

## 5. dispatch_wait4_writeback rewrite

**Was** (dispatch.pdx:329-330):

```asm
cmp r8, 0;
jne dispatch_wait4_efault;
mov [rsi], edx;                       // ← the KPTI-hazardous store
```

**Is** (dispatch.pdx:329-360, after the fix):

```asm
cmp r8, 0;
jne dispatch_wait4_efault;
; #737 fix: route through user_write_u32_via_walk. rax (zombie pid,
; our return) must survive; save/restore via push/pop. rdx/rsi become
; SysV args (consumed, not preserved).
push rax;                             ; save zombie pid across the call
mov rdi, rsi;                         ; arg0 = wstatus user VA
mov rsi, rdx;                         ; arg1 = status (u64; low 32 used)
call user_write_u32_via_walk;         ; rax = 0 (OK) or -EFAULT
mov r8, rax;                          ; stash walk result
pop rax;                              ; restore zombie pid
cmp r8, 0;
jne dispatch_wait4_efault;            ; walk failed → -EFAULT
```

### 5.1 Callee-save discipline

`user_write_u32_via_walk` is a **leaf** (no nested call inside it) but per SysV clobbers all caller-save regs. Only `rax` (our return value = zombie pid) needs to survive across the call; `rdx` and `rsi` are consumed as the args for the call itself.

### 5.2 Stack alignment

- `dispatch_wait4_writeback` entry: `rsp % 16 == 8` (per SysV; `syscall_dispatch` called us).
- Three prior pushes (rax/rdx/rsi) + three intervening pops after `user_ptr_ok` net to zero movement; `rsp` is back at `%16 == 8` before the writeback stanza.
- Single `push rax` moves to `%16 == 0` — correct entry alignment for the nested `call user_write_u32_via_walk` (which then adds its own return-address push, bringing the callee's entry to `%16 == 8`).
- `pop rax` restores `%16 == 8` for our own `ret`.

### 5.3 EFAULT semantics preserved

Both failure paths (user_ptr_ok reject at `dispatch_wait4_efault` and walk reject after the helper) land on the same `dispatch_wait4_efault` label:

```asm
dispatch_wait4_efault:
mov rax, 0xFFFFFFFFFFFFFFF2;          ; -EFAULT = -14
ret;
```

Same return convention as `dispatch_write_efault`.

## 6. Test/verify updates

### 6.1 `tools/verify-syscall-dispatch.sh` — check 13

The pre-existing check for the wstatus writeback grep'd for `mov (DWORD|QWORD) PTR [rsi]` within 30 instructions after `sys_wait_body`. With the raw store replaced by a helper call, that pattern no longer appears. Updated to accept either the raw-store shape (legacy tolerance) or the helper-call shape:

```bash
grep -qE "mov\s+(DWORD|QWORD) PTR \[rsi\]|call.*user_write_u32_via_walk"
```

Widened window from `-A 30` to `-A 40` to comfortably cover the extra push/pop + call instructions inserted by the helper-call form on the block-then-resume path.

### 6.2 `tests/r17/expected-boot-r17-init.txt`

Line 28: `WAIT: pid=23 status=0` → `WAIT: pid=23 status=42`.

`pid=23` unchanged (the pid-leak in `pid_alloc`'s dense-low-first scan is the other lie exposed by #736 D12, tracked as #735 — orthogonal to this fix; init reaps child pid 23 because 22 pids leaked from boot witnesses).

## 7. Verification (post-fix)

### 7.1 Wire log

```
$ bash tools/run-smoke.sh boot_r17_init
smoke: fingerprint check passed (all 29 lines found in order)

$ grep -E "CHILD HELLO|WAIT:|REAPED" /tmp/paideia-os-smoke.log
CHILD HELLO 42
WAIT: pid=23 status=42
REAPED
```

### 7.2 Verifier

```
$ bash tools/verify-syscall-dispatch.sh build/kernel.elf
[ok]   ID 61 (wait4): wstatus writeback present
Verification: 15 / 15 checks passed
KERNEL SYSCALL DISPATCH OK
```

### 7.3 Pre-push (10/10)

```
[pre-push] opcode-canary PASS
[pre-push] boot_r8_only PASS   boot_r10 PASS   boot_r11 PASS
[pre-push] boot_r12 PASS       boot_r12_denial PASS
[pre-push] boot_r14b_hivma PASS   boot_r14b_kpti PASS
[pre-push] boot_r14b_ipi PASS     boot_r14b_loader PASS
[pre-push] All checks passed. Safe to push.
```

### 7.4 Full 19-mode smoke matrix

All modes green: `boot_min`, `boot_banner`, `boot_tick`, `boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`, `boot_r12_denial`, `boot_r14b_hivma`, `boot_r14b_kpti`, `boot_r14b_ipi`, `boot_r14b_loader`, `boot_r14b_ud`, `boot_r15_ring3`, `boot_r15_process`, `boot_r17_init`, `boot_panic`, `boot_panic_halt`, `boot_exc3`.

## 8. Audit of other write-side callers (D14+)

Systematically grep'd all sites in `src/kernel/` that store to a memory operand with an ambient possibility of holding a user VA under kernel CR3.

### 8.1 In-scope of this landing (fixed)

- `dispatch.pdx:330` — `mov [rsi], edx` — **fixed here**.

### 8.2 Latent, filed as follow-ups (NOT fixed here — scope discipline)

- **#738 (NEW D14a)**: `sys_read_body → vfs_read → tmpfs_read` writes to user `buf_ptr` via `rep_movsb` at `src/kernel/core/fs/tmpfs/read.pdx:116-120`. Direct write-side sibling of this fix. Not exercised at R17.M0 because no user program calls `sys_read()`; will fire silently the moment userland grows a `read()` caller.
- **#734 (D14b, pre-existing)**: `sys_write_body → vfs_write → tmpfs_write` reads from user `buf_ptr` via `rep_movsb`. Read-side sibling. Latent because R17.M0 stdio uses UART fast path.
- **#733 (D14c, pre-existing)**: `sys_open_body → path_resolve` reads path bytes via `mov_b` under kernel CR3. Latent because init's `sys_open` return is not checked; silently fails but the boot chain doesn't observe.

### 8.3 Scanned and cleared (kernel-side stores, not user pointers)

Every remaining `mov [reg], ...` and `rep_movsb` in the syscall-reachable code paths writes into kernel-owned data structures whose base is a TCB slab, page-table entry, vnode pool slot, or kernel scratch page — all covered by the boot PML4's identity map by construction:

- `handlers/sys_fork.pdx` — child TCB slot writes (`[r12 + 8/32/40/48/168/1720/...]`).
- `handlers/sys_exit.pdx` — self TCB and parent TCB writes (`[rdi + 8/12]`, `[r8 + 8/1704/1708]`).
- `handlers/sys_execve_shim.pdx:302` — TCB `saved_user_rsp` at `[rbx + 104]`.
- `handlers/sys_dup2.pdx:129` — vnode pool refcount at `[rax + 4]`.
- `fs/fd_table.pdx:36` — fd table slot at `[rdi + rsi*8 + 168]`.
- `fs/vnode_pool.pdx:86,122,131-138,227-229` — vnode pool slot writes.
- `fs/vfs_open.pdx:231` — vnode init.
- `fs/tmpfs/inode.pdx:87` — inode pool free-list link.
- `sched/task_pool.pdx:168`, `sched/idle.pdx:81`, `sched/runqueue.pdx:131,148`, `sched/tasks.pdx:102,149`, `sched/wake_block.pdx:57,103` — all TCB fields.
- `syscall/entry.pdx:43,48,90,117` — trampoline data page slots (mapped in both PML4s per §3.1 of the D4 design doc).
- `int/idt.pdx:405`, `boot/gdt.pdx:141,147`, `cap/kind_page.pdx:78` — kernel-only structures.
- `libc_test.pdx:138` — kernel-side memcpy (`_libc_test_scratch` staging).

None of these accept a user VA on any code path today.

## 9. Distance to true #723 AC

`#723` AC: `CHILD HELLO 42\nWAIT: pid=<child pid> status=42` on serial log after init reaps its child.

Pre-#737: `WAIT: pid=23 status=0` — status was the lie.
Post-#737: `WAIT: pid=23 status=42` — status honest.
Still remaining: `pid=23` instead of `pid=2` (or whatever the first free pid post-boot-witness-cleanup would be). Tracked as **#735** (pid_alloc dense-low-first scan sees 22 leaked pids from R14b-R17 boot witnesses and starts the child at pid=23).

#737 + #735 together close the last two AC-line lies exposed by #736 D12. Neither blocks the other; #735 is an orthogonal fix in `pid_alloc` / boot-witness cleanup.

## 10. Files changed

| File | Change |
|------|--------|
| `src/kernel/core/syscall/user_read.pdx` | Added `user_write_u32_via_walk` (~110 lines including comments) |
| `src/kernel/core/syscall/dispatch.pdx` | `dispatch_wait4_writeback`: raw `mov [rsi], edx` → `call user_write_u32_via_walk`, with push/pop discipline for rax survival |
| `tools/verify-syscall-dispatch.sh` | Check 13 accepts either raw-store or helper-call form; window widened -A 30 → -A 40 |
| `tests/r17/expected-boot-r17-init.txt` | Line 28: `status=0` → `status=42` |
| `design/kernel/r16-m3-737-dispatch-wait4-writeback-kpti.md` | This doc |
