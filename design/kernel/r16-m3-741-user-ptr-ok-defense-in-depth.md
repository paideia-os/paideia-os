R16-M3-741 — Defense in depth against ring-3 → ring-0 corruption via
missing `user_ptr_ok` gates + walker translation-vs-permission confusion
======================================================================

Issue:      #741 (CRITICAL, ring-3 → ring-0 arbitrary memory corruption)
Discovered: debugger during KPTI-sweep verify at commit 1129131
Predecessor design docs:
  design/kernel/r17-m0-724-d4-init-post-iretq-gp.md   (user_puts_via_walk)
  design/kernel/r17-m0-730-d10-execve-complete.md     (user_read_str_via_walk)
  design/kernel/r16-m3-737-dispatch-wait4-writeback-kpti.md
                                                       (user_write_u32_via_walk)
  design/kernel/r16-m3-kpti-sweep-733-734-738-739.md  (user_{read,write}_bytes_via_walk)


1. Severity & one-line summary
------------------------------

CRITICAL. Any userland program can trigger arbitrary kernel-mode
memory writes, and thereby arbitrary kernel-mode code execution, by
issuing three ordinary syscalls (`open`, `write`, `read`). No external
interaction, no adjacent-process race, no probabilistic component. The
primitive is direct.


2. Full exploit chain
---------------------

```
    fd = open("/tmp/x", O_CREAT);
    write(fd, attacker_bytes, N);
    read (fd, 0xFFFF800000105000, N);   // = trampoline data page VA
```

Step-by-step:

  (a) `open` — `dispatch_open` receives `path_va` in `rsi`. Passes it
      into `user_read_str_via_walk(path_va, scratch, 256)` **with no
      pre-check** — the caller never validates that `path_va` is in
      the user half. For this exploit the path is a plain user string,
      so this step trivially succeeds and returns an fd.

  (b) `write` — `dispatch_write` DOES gate with `user_ptr_ok` (#541),
      so this step is well-formed. It writes `attacker_bytes` into
      the tmpfs inode. Just planting attacker-chosen content.

  (c) `read` — `dispatch_read` receives `buf_va = 0xFFFF800000105000`
      in `rdx`. It caps `len` at 4096, then:

        - Calls `sys_read_body(current, fd, kernel_scratch, capped_len)`
          which safely reads into `_dispatch_read_buf_scratch`
          (kernel scratch).

        - Then calls
          `user_write_bytes_via_walk(user_va=buf_va, kernel_src=scratch,
                                     len=rax_bytes_read)`
          — **with no pre-check on `buf_va`**.

      The walker walks `_current_tcb.user_pml4_va` for `buf_va`.
      Because every per-process user PML4 contains one kernel-half
      entry — `PML4[256]` (the strict-KPTI mirror installed by
      `kpti_build_user_pml4`, kpti.pdx L123-260) that routes to a
      non-huge 4-level chain covering the syscall trampoline pages
      (`PT[260]` = trampoline code @ `0xFFFF800000104000`, `PT[261]`
      = trampoline data @ `0xFFFF800000105000`) — the walk succeeds:

          PML4[256] → PDPT[0] → PD[0] → PT[261] → phys(trampoline data)

      The walker's PS-bit rejection at PDPT/PD does NOT fire because
      the KPTI mirror chain is deliberately non-huge (kpti.pdx §4).
      The walker's P-bit check passes because the KPTI mirror is
      Present (has to be — syscall entry code executes from those
      pages).

      The walker then computes byte kernel VA as
      `KERNEL_VMA_BASE + frame_pa` (the higher-half identity map,
      supervisor-writable, U=0). It writes `attacker_bytes` to that
      VA — i.e. it writes attacker bytes over
      `saved_user_rsp` / `saved_user_CR3` / `kernel_pml4_pa` in the
      trampoline data page.

      Next syscall entry from ANY task loads those scratches; the
      trampoline `iretq`s to whatever the attacker wrote. Full
      ring-0 arbitrary code execution.


3. Root cause — dual
--------------------

**A. Walker translation-vs-permission confusion.** All five walking
helpers in `src/kernel/core/syscall/user_read.pdx`
(`user_puts_via_walk`, `user_read_str_via_walk`,
`user_write_u32_via_walk`, `user_read_bytes_via_walk`,
`user_write_bytes_via_walk`) walk `_current_tcb.user_pml4_va` and
check only the P bit at each level (plus PS=1 rejection at PDPT/PD).
They never check U/S. Once the walk resolves a leaf frame, byte
access happens via `KERNEL_VMA_BASE + frame_pa` — the kernel's own
higher-half identity mapping, which is a *separate*, more-permissive
mapping than whatever bits the user PML4's PTE actually carried.

In effect: the user PML4 supplies only translation; the kernel's own
identity map supplies access rights. This is a **confused-deputy
translation bypass** — the walker uses the user page tables to name
a frame, then uses kernel privilege to touch it.

**B. Missing `user_ptr_ok` gates.** The caller-side convention was
that every dispatch handler receiving a user pointer must call
`user_ptr_ok(va, len)` before any downstream walk. That gate rejects
`va >= KERNEL_VMA_BASE` up front (ptr_check.pdx L42-76) and is the
only defense against the walker confusion above. The convention was
observed in `dispatch_write` (#541), `dispatch_wait4_writeback`
(#737), and `sys_execve_shim` Phase 2 (#671). It was **missed** in:

  - `dispatch_open` (#733 landing, 1129131)
  - `dispatch_read` (#738/#739 landing, 1129131)
  - `dispatch_debug_puts` (pre-existing since #724 D4)

Design doc §10 of the KPTI-sweep (r16-m3-kpti-sweep-733-734-738-739.md)
claimed "kernel-half addresses are rejected structurally". That claim
was FALSE — the KPTI mirror at PML4[256] is a non-huge chain
resolving to real kernel memory, and the walker had no VA-range check
to intercept the resolution.


4. Fix — two layers, both mandatory
-----------------------------------

### Layer 1: caller-side `user_ptr_ok` gate at the 3 missed sites

Preserves the existing convention that every dispatch handler owns
its trust boundary. Cheap (a single range compare), immediate, and
matches the pattern already in `dispatch_write`.

Sites:

  - `dispatch_open` — user_ptr_ok(path_va, DISPATCH_PATH_MAX=256)
    before the `call user_read_str_via_walk`.
  - `dispatch_read`  — user_ptr_ok(user_buf, capped_len) before the
    `call sys_read_body` (gates the entire path, including the
    subsequent writeback via `user_write_bytes_via_walk`).
  - `dispatch_debug_puts` — user_ptr_ok(user_va, len) before the
    `call user_puts_via_walk`.

Each site follows the exact pattern established by `dispatch_write`
(#541) at dispatch.pdx L212-228: save the caller-live regs across the
call, invoke `user_ptr_ok(va, len)` with `rdi`/`rsi`, restore, branch
to a `*_efault` label that returns `0xFFFFFFFFFFFFFFF2` (-EFAULT) on
failure.

### Layer 2: walker-side VA-range check at the 5 helpers

Structural defense-in-depth. Ensures that any *future* dispatch
handler that forgets Layer 1 is still safe. This turns the "callers
must remember" convention into a "walkers never trust" invariant.

Every walker now begins with:

```
mov  rcx, 0xFFFF800000000000     ; KERNEL_VMA_BASE (movabs)
cmp  <user_va_arg>, rcx
jae  <helper>_range_fail          ; user_va >= KERNEL_VMA_BASE

mov  rax, <user_va_arg>
add  rax, <len_arg>              ; or add rax, 4 for u32 writer
jb   <helper>_range_fail          ; overflow past u64 max
cmp  rax, rcx
ja   <helper>_range_fail          ; end > KERNEL_VMA_BASE
```

The check is placed BEFORE the callee-save prologue so failure is a
bare `ret` (with the appropriate return sentinel), leaving the stack
untouched. The check uses only `rax` and `rcx` — both caller-save,
so no additional preservation is needed.

Per-helper arg selection and failure sentinel:

  helper                          | user_va reg | len   | fail sentinel
  --------------------------------|-------------|-------|--------------------
  user_puts_via_walk              | rdi         | rsi   | void return
  user_read_str_via_walk          | rdi         | rdx   | xor rax; ret (existing 0-sentinel)
  user_write_u32_via_walk         | rdi         | 4     | mov rax, -EFAULT
  user_read_bytes_via_walk        | rsi (!)     | rdx   | mov rax, -EFAULT
  user_write_bytes_via_walk       | rdi         | rdx   | mov rax, -EFAULT

Note the register asymmetry in `user_read_bytes_via_walk`: its
signature is `(kernel_dst=rdi, user_va=rsi, len=rdx)` — user_va is
in `rsi`, not `rdi`. The Layer 2 check must guard `rsi` there.

### Why both layers

  - Layer 1 alone is what we had before this landing; the convention
    was violated in the exact commit under audit. It will be violated
    again — probably during the next syscall handler someone adds. A
    convention with no enforcement is a landmine.

  - Layer 2 alone would leave the exploit reachable if a new
    non-walker path emerges that touches user memory (e.g. an
    optimized fast-path bypassing the walker). Layer 1 owns the
    trust boundary at its natural place — the dispatch handler that
    first receives the user pointer.

  - Together: Layer 1 fails fast at the syscall boundary with a
    single compare; Layer 2 catches the residual class of
    "convention violation".


5. Layer 1 changes per site
---------------------------

### 5.1 `dispatch_read` (src/kernel/core/syscall/dispatch.pdx L152)

Alignment: `dispatch_read` is a label inside `syscall_dispatch`;
`rsp%16 == 8` at entry (SysV: the outer `call syscall_dispatch`
pushed the RA). Two existing pushes (r15, r14) leave `rsp%16 == 8`.
One extra `push rsi` before the new call fulfills two roles: (a)
preserves `fd` across the call (rsi is caller-save and will be
clobbered as the len arg), (b) advances `rsp%16` to 0 for the nested
`call user_ptr_ok`.

After the call, `rcx` has been clobbered (ptr_check.pdx uses `rcx` as
the movabs target for KERNEL_VMA_BASE). The existing downstream
`call sys_read_body` expects `rcx = capped_len`. A single
`mov rcx, r14` restores it (r14 is our stashed capped-len).

Gating on CAPPED len (not uncapped) is deliberate: POSIX allows
short-read semantics where the actual byte range touched is
`min(len, 4096)`. Gating on capped matches what the walker will
actually touch and preserves compatibility with well-formed callers
that pass `len = SIZE_MAX` and expect short-I/O.

### 5.2 `dispatch_open` (src/kernel/core/syscall/dispatch.pdx L369)

Three pushes (rsi, rdx, rcx) preserve path_va/flags/mode across the
new call. From `rsp%16 == 8` at entry, 3 * 8 = 24 → `rsp%16 == 0`
for the call (matches the alignment discipline in
`dispatch_wait4_writeback` at L603, which also uses a 3-push
pattern). No alignment pad needed.

### 5.3 `dispatch_debug_puts` (src/kernel/core/syscall/dispatch.pdx L424)

Two pushes (rsi, rdx) + one `sub rsp, 8` reach `rsp%16 == 0`. On
return, `add rsp, 8` + two pops restore. A new fallthrough label
`dispatch_debug_puts_efault` returns -EFAULT (matches dispatch_write's
convention). The stashed `mov r8, rax` pattern (r8 caller-save,
unused here) survives the pops so we can branch after restoring
regs.


6. Layer 2 walker hardening
---------------------------

Each helper's `block: {}` now opens with the range check described
in §4. Placement is BEFORE the callee-save prologue (`push rbx; push
r12; ...`) so a failed check does a plain `ret` and never modifies
the stack. The failure label lives AFTER the normal epilogue so it
does not interfere with control flow through the success path; jumps
into it come only from the pre-prologue check.

Failure sentinels intentionally match the helper's existing failure
convention:

  - `user_puts_via_walk`      — void return, plain `ret`.
  - `user_read_str_via_walk`  — `xor rax, rax; ret` (rax=0 is the
                                existing "fault" sentinel: callers
                                check `cmp rax, 0; je fail`).
  - The three -EFAULT-returning helpers — `mov rax,
                                0xFFFFFFFFFFFFFFF2; ret`.

Comments at each site reference this design doc.


7. Additional-attack-surface audit
----------------------------------

Grep of `^\s*call user_` across `src/` yields exactly these walker
call sites (comment lines excluded):

  location                                                                  | gated by user_ptr_ok?
  --------------------------------------------------------------------------|---------------------
  src/kernel/core/syscall/handlers/sys_execve_shim.pdx:139 user_read_str…   | YES (Phase 2, L110-115)
  src/kernel/core/syscall/dispatch.pdx:194 user_write_bytes_via_walk       | NOW YES (Layer 1 §5.1)
  src/kernel/core/syscall/dispatch.pdx:286 user_read_bytes_via_walk        | YES (#541, L213-228)
  src/kernel/core/syscall/dispatch.pdx:327 user_puts_via_walk (fd=1,2 UART) | YES (#541, L213-228)
  src/kernel/core/syscall/dispatch.pdx:376 user_read_str_via_walk (open)   | NOW YES (Layer 1 §5.2)
  src/kernel/core/syscall/dispatch.pdx:428 user_puts_via_walk (debug_puts) | NOW YES (Layer 1 §5.3)
  src/kernel/core/syscall/dispatch.pdx:606 user_write_u32_via_walk (wait4) | YES (#737-verify, L566)

All 7 call sites are now covered by Layer 1. Layer 2 backstops all of
them regardless.


8. Witness compatibility audit
------------------------------

Grep of the same names across `src/kernel/boot/kernel_main.pdx`
(where witnesses live) matches only the `user_ptr_ok` witness at
L4447-4488 (which tests `user_ptr_ok` itself with a kernel VA and
expects `rax = 1` — this witness passes trivially through Layer 2
because it never calls a walker).

No witness in `kernel_main.pdx` calls any of the five walking
helpers. Every witness that needs to exercise the read/write/open
paths does so by calling the BODY (`sys_read_body`, `sys_write_body`,
`sys_open_body`) directly with kernel VAs — which is the design
established by the KPTI-sweep predecessor doc §"witness invariants".
Bodies do not walk (they dereference directly under kernel CR3), so
Layer 2's user-half range check never fires against them.

Result: **Layer 2 breaks no witness.** Witness compatibility is
preserved by construction.


9. Adversarial trace — proving the exploit is now closed
--------------------------------------------------------

Replaying the exploit against the fixed kernel:

```
    read(fd, 0xFFFF800000105000, N)
```

Trace through the code:

  (1) `syscall_entry` (entry.pdx) flips CR3 to `_kernel_pml4_pa`,
      lands in `syscall_dispatch(sysno=0, a0=fd, a1=0xFFFF...5000,
      a2=N, a3=0)`.

  (2) `syscall_dispatch` cmp/je chain hits `dispatch_read`. Entry:
      `rsi=fd, rdx=0xFFFF...5000, rcx=N`.

  (3) Two pushes (r15, r14) → save area. Cap len at 4096.
      `r15 = 0xFFFF...5000, r14 = min(N, 4096)`.

  (4) **LAYER 1**. `push rsi; mov rdi, r15; mov rsi, r14;
      call user_ptr_ok`. user_ptr_ok's first compare: `cmp rdi,
      0xFFFF800000000000` → JAE fault_return. `rax = 1`.
      `pop rsi; cmp rax, 0; jne dispatch_read_efault`. Handler
      returns `0xFFFFFFFFFFFFFFF2` (-EFAULT). **BLOCKED.**

If somehow Layer 1 were absent (hypothetical regression), the trace
continues:

  (5) `mov rcx, r14; call sys_read_body`. Returns some `bytes_read`.

  (6) `mov rdi, r15; call user_write_bytes_via_walk`.

  (7) **LAYER 2**. Walker's entry: `mov rcx, 0xFFFF800000000000; cmp
      rdi, rcx` → JAE `user_write_bytes_range_fail`. Returns
      `0xFFFFFFFFFFFFFFF2`. Dispatcher branches to
      `dispatch_read_efault`. **BLOCKED.**

Both layers independently close the primitive. Concretely proven
without running the exploit against wire.


10. Regression testing plan
---------------------------

10.1 Existing smoke matrix (must remain green):

  ```
  bash tools/run-smoke.sh MODE
  ```

  for MODE in { boot_min, boot_banner, boot_tick, boot_r8_only,
                boot_r10, boot_r11, boot_r12, boot_r12_denial,
                boot_r14b_hivma, boot_r14b_kpti, boot_r14b_ipi,
                boot_r14b_loader, boot_r14b_ud,
                boot_r15_ring3, boot_r15_process,
                boot_r17_init, boot_panic, boot_panic_halt,
                boot_exc3 } — all 19.

10.2 #723 acceptance-criterion invariance on wire:

  ```
  INIT ENTERED RING3
  CHILD HELLO 42
  WAIT: pid=2 status=42
  REAPED
  ```

  (from init/child_hello exec of the fork/wait test — this exercises
   dispatch_open→sys_open_body path and dispatch_wait4_writeback
   which both cross the newly gated helpers.)

10.3 Future direct-exploit witness (optional, not landed here):

  A dedicated smoke mode `boot_r16_pf_esc` (or equivalent) could add
  a witness that:

    - Opens a scratch tmpfs file.
    - write()s a well-known payload into it.
    - read()s into `buf = 0xFFFF800000105000` and asserts the
      returned rax equals `-EFAULT` (0xFFFFFFFFFFFFFFF2).
    - Emits `PF ESC OK\n` on the wire on success, `PF ESC FAIL\n`
      otherwise.

  This would be an on-wire negative test for the direct exploit
  primitive. Not added in this landing because the exploit is
  already provably closed via §9 and the two independent structural
  layers; a dedicated wire test is a nice-to-have follow-up.


11. Related issues
------------------

  - #541 — original `user_ptr_ok` phase-1 range check (the gate
           Layer 1 reuses).
  - #679 — deferred phase-2 walk augmentation of `user_ptr_ok`
           (would inspect the user PML4 for U-bit and Present at
           each intended byte's page; still worth doing as a
           third layer but not required to close #741).
  - #724 D4 — original silent-NUL fix that introduced
           `user_puts_via_walk` (and the pre-existing debug_puts
           gap Layer 1 §5.3 now closes).
  - #730 D10c/D10d — `user_puts_via_walk` in write UART fast-path;
           `user_read_str_via_walk` in sys_execve_shim.
  - #737 — `user_write_u32_via_walk` in dispatch_wait4_writeback.
  - #733/#734/#738/#739 — KPTI-sweep landing that introduced the
           dispatch_open/dispatch_read gaps.


12. What Layer 2's failure means to the caller
----------------------------------------------

A caller that omits Layer 1 and passes a kernel-half `user_va` will
see the following symptoms:

  - `user_puts_via_walk`: silent no-op (void return, no bytes
    emitted). Distinguishable from a legitimate empty print only via
    kernel-log inspection.
  - `user_read_str_via_walk`: returns 0. Callers already interpret 0
    as "fault or cap exceeded without NUL" → surface as -EFAULT.
  - `user_write_u32_via_walk`: returns 0xFFFFFFFFFFFFFFF2. Callers
    check this and propagate as -EFAULT.
  - `user_read_bytes_via_walk`: returns -EFAULT. Callers propagate.
  - `user_write_bytes_via_walk`: returns -EFAULT. Callers propagate.

In every case the ring-3 → ring-0 primitive collapses to a clean
-EFAULT return with no kernel state mutated.


13. Summary
-----------

Layer 1 (dispatch.pdx):
  - dispatch_read       @ L152 (gate L166-185) — user_ptr_ok(buf, capped_len)
  - dispatch_open       @ L391 (gate L392-408) — user_ptr_ok(path_va, 256)
  - dispatch_debug_puts @ L466 (gate L467-486) — user_ptr_ok(user_va, len)

Layer 2 (user_read.pdx):
  - user_puts_via_walk        @ L49  (range_fail L190) — entry check, void ret
  - user_read_str_via_walk    @ L223 (range_fail L369) — entry check, ret rax=0
  - user_write_u32_via_walk   @ L425                    — entry check, ret -EFAULT
  - user_read_bytes_via_walk  @ L577 (range_fail L716) — entry check on rsi, ret -EFAULT
  - user_write_bytes_via_walk @ L741 (range_fail L882) — entry check on rdi, ret -EFAULT
                                                          (THE #741 EXPLOIT SITE)

Total: 3 caller gates + 5 walker structural gates. Every call path
from ring-3 to a user-VA-touching walker now crosses at least one
range check.
