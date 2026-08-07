# R16-M0-D11a: aspace_teardown CoW-aware — register-discipline fix

**Status:** landed
**Issue:** paideia-os D11a follow-up (filed against #730 D10 landing)
**Depends on:** #559 (frame_meta refcount), #649 (phys_free real body), #552 (aspace_clone_cow), #730 (D10 execve completes)
**Precondition wire-state:** `boot_r17_init` — 29/29 lines match, AC line `WAIT: pid=2 status=42\nREAPED` present, but `sys_execve_body` SKIPs `aspace_teardown` on the success path → ~64 KiB leaked per exec.
**Post-fix wire-state:** identical 29/29 lines match; `aspace_teardown` restored on success path; free-frame count returns to steady state after every exec.

---

## 1. Symptom + wire evidence pre-fix

`sys_execve_body`'s success path had a commented-out `aspace_teardown` on the OLD aspace:

```asm
mov [rbx + 16], r15;   ; commit new_pml4
; Was: mov rdi, r14; call aspace_teardown;
; TODO(D11): investigate + restore.
```

D10's investigation log recorded that re-enabling the call crashed the kernel whenever execve ran from a CoW-cloned aspace (i.e. init's fork'd child). Re-enabling the teardown call and re-running `tools/run-smoke.sh boot_r17_init` reproduced the crash immediately:

```
INIT ENTERED RING3
INIT OK
000000001448fb5a|0|P|INT_|TRAP FRAME vec=0x0000000b00000000 err=0x0000000000000000 rip=0x0000000700000000 cs=0x0000000800000000
0000000014639d60|0|P|INT_|TRAP FRAME rfl=0x0000000000000000 rsp=0x0000000a00000000 ss=0x0000000a00000000
00000000146e17f0|0|P|INT_|EXC HALT
```

`vec=0x0000000b_00000000` is the **shifted-frame signature** documented in `src/kernel/core/int/idt.pdx:343` — every field appears in bits 32..63 with 0s in bits 0..31, which happens when a page fault (#PF) hits during an already-running #PF handler and corrupts the IST stack. The underlying vector is 14 (#PF); the display is scrambled because the nested fault mangled the outer trap frame. Post-#661 `_isr_stub_14` was supposed to eliminate this class of failure by moving #PF from IST1 (shared with #DF) to IST3, but the specific corruption pattern still surfaces when the handler itself faults deeply enough to overrun its own stack.

---

## 2. Root cause — NOT the CoW machinery

The task hypothesized CoW-aware teardown as the fix (per-frame refcount decrement, only `phys_free` when refcount → 0). That mechanism is **already in place** at the `phys_free` layer, landed with #559:

```asm
; phys_free.pdx:43–58
lea r10, [rip + _frame_meta];
mov r11, [r10 + rdi*8];
cmp r11, 0;
je phys_free_idempotent;      ; refcount already 0 → no-op OK
sub r11, 1;
mov [r10 + rdi*8], r11;
cmp r11, 0;
jne phys_free_still_shared;   ; refcount > 0 → return OK, bit stays set
; fall through: refcount hit 0 → clear bitmap bit → frame returned to pool
```

So calling `phys_free(shared_frame, 0)` on a CoW-shared leaf correctly:
- Decrements the frame's refcount by 1.
- If refcount was ≥ 2 (parent still owns), the bit stays set — the frame remains allocated for the parent.
- If refcount hits 0 (last owner), the bit is cleared and the frame returns to the pool.

`aspace_teardown` needs no CoW logic of its own — dispatching every present leaf through `phys_free` is sufficient. That was the R14-m2-005 design and it is CoW-safe by construction, provided the walker itself is correct.

### The actual bug: register-clobber in the walker

`phys_free` is a SysV function that clobbers **all caller-save registers** (rax, rcx, rdx, rsi, rdi, r8–r11) — see phys_free.pdx which pushes nothing and uses r8/r9/r10/r11 as scratch (bitmap word, mask, refcount ptr, refcount value). Pre-D11a `aspace_teardown` used r8 (pdpt_pa), r9 (pd_pa), r10 (pt_pa) as outer-loop bases and preserved the wrong registers around each nested `phys_free`:

```asm
; Pre-D11a L4 body — leaf phys_free:
push r10;    ; save r10 (pt_pa)         ← r10 preserved
push r15;    ; save r15 (pd_index)      ← unnecessary (phys_free preserves r15)
push r14;    ; save r14 (pdpt_index)    ← unnecessary
push r13;    ; save r13 (pml4_index)    ← unnecessary
push rbx;    ; save rbx (pt_index)      ← unnecessary
call phys_free;
; r8 (pdpt_pa) and r9 (pd_pa) SILENTLY TRASHED here.
```

The pushed regs (r13, r14, r15, rbx) are SysV callee-save — `phys_free` preserves them by convention, so those pushes are pure noise. r8 (pdpt_pa) and r9 (pd_pa) are NOT saved, and they are exactly what `phys_free` uses as scratch. On return, r9 holds a bitmap word and r8 holds a bit mask — garbage from the walker's perspective.

The clobber propagates outward:

```
L4 body:  phys_free(leaf) trashes r8, r9    (L4 body only reads r10 → OK)
L4 done:  phys_free(pt)   trashes r8, r9, r10
          → L3_next → L3_loop reads [r9 + r15*8]   ← r9 is garbage → #PF
          
L3 done:  phys_free(pd)   trashes r8, r9, r10
          → L2_next → L2_loop reads [r8 + r14*8]   ← r8 is garbage → #PF

L2 done:  phys_free(pdpt) trashes r8, r9, r10
          → L1_next → L1_loop reads [r12 + r13*8]  ← r12 callee-save → OK
```

### Why it was silent until R17.M0

- **R15.M5 `task_free_witness` (100 iterations):** task_new produces an aspace where PML4[0..255] are all zero (aspace_create_user only allocates the trampoline chain at PML4[256]). The L1 loop finds no present user entries → never enters L2/L3/L4 → walker's `phys_free` calls never fire → clobber never happens. Witness passed 100/100 by coincidence.
- **sys_execve error paths (partial aspace teardown):** if `elf_lite_load` fails after a few `aspace_map` calls, teardown DOES exercise the inner loops. But the test suite has no forced-OOM witness for elf_lite_load, so this branch is never taken in the smoke matrix.
- **sys_fork rollback (aspace_clone_cow OOM):** same as above — no forced-OOM witness for clone_cow at 32 MiB pool, so this branch also never fires.
- **R17.M0 first real execve success path (D10):** init forks child_hello, child does `sys_execve("/bin/child_hello")` → sys_execve_body commits new aspace → tries to teardown OLD (init's CoW-cloned copy, populated with init's segments + user stack, at least 5 present leaves across multiple PT/PD entries) → walker enters inner loops → clobber → nested #PF → shifted-frame trap → EXC HALT.

The R17 test surface is the first that exercises `aspace_teardown` on a non-empty aspace. That is what "landed" the bug.

---

## 3. Fix

### 3.1 Preserve r8/r9/r10 across every `phys_free` call

Around each `phys_free` call site in the walker, push r8/r9/r10 (as needed for the following code path) with alignment pad, restore afterward. Indices (r13, r14, r15, rbx) are SysV callee-save and phys_free preserves them automatically — those pushes are removed.

| Site        | Preserve   | Push bytes | Pad | Total | rsp % 16 at CALL |
|-------------|------------|-----------:|----:|------:|:----------------:|
| L4 body     | r8, r9, r10|         24 |   8 |    32 |        0         |
| L4 done     | r8, r9     |         16 |   0 |    16 |        0         |
| L3 done     | r8         |          8 |   8 |    16 |        0         |
| L2 done     | (none)     |          0 |   0 |     0 |        0         |
| L1 done     | (none)     |          0 |   0 |     0 |        0         |

Prologue = 5 pushes (40 B) landing rsp % 16 == 0. Every phys_free call site above ends at rsp % 16 == 0 immediately before the CALL — SysV compliant.

### 3.2 Frame mask normalization

Pre-D11a: `mov rcx, 0xFFFFFFFFF000` — 12 hex digits = bits 12..47 = 36-bit frame → caps PA at 128 GiB.

Post-D11a: `mov rcx, 0x000FFFFFFFFFF000` — 16 hex digits = bits 12..51 = 40-bit frame per Intel SDM Vol 3A §4.5. Matches aspace_map, aspace_clone, pf_handler, pt_walk. Latent-only at R17.M0 (32 MiB pool → frame PAs all < 24 bits), but wrong per spec and out-of-band with the rest of the mm layer.

### 3.3 Restore call site in sys_execve

```asm
; src/kernel/core/syscall/handlers/sys_execve.pdx step 4
mov [rbx + 16], r15;      ; commit new_pml4
mov rdi, r14;             ; r14 = old_pml4_va
call aspace_teardown;     ; ~64 KiB reclaimed
mov rdx, [r12 + 24];      ; entry_rip
xor rax, rax;             ; ELF_OK
```

The `Was:` comment is removed and replaced with a forward-pointing note that references this design doc.

---

## 4. CoW-aware algorithm — layered ownership

The two-layer discipline as it now stands:

**Layer 1: `aspace_teardown`** — walker.
1. For each PML4 slot 0..255 (skip 256+, the KPTI trampoline mirror).
2. Descend PDPT → PD → PT.
3. For each present leaf with U=1, call `phys_free(leaf_pa, 0)` and move on.
4. After L4 loop completes, `phys_free(pt_pa, 0)`.
5. After L3 loop completes, `phys_free(pd_pa, 0)`.
6. After L2 loop completes, `phys_free(pdpt_pa, 0)`.
7. After L1 loop completes, `phys_free(pml4_pa, 0)`.
8. Return 0.

The walker knows nothing about sharing — it dispatches every present frame through `phys_free` unconditionally.

**Layer 2: `phys_free`** — refcount arbiter.
1. Bounds-check the input.
2. Load `_frame_meta[page_index]`. If 0, idempotent no-op (return OK).
3. Decrement. If new value > 0, keep bitmap bit set (still shared), return OK.
4. If new value == 0, clear bitmap bit (frame returned to pool), return OK.

The arbiter knows nothing about page tables — it just enforces the "N sharers before free" invariant on the per-frame refcount.

### 4.1 CoW-shared leaves — correctness

- Post-fork: parent + child share every leaf frame at refcount 2 (aspace_clone_cow increfs each leaf after aspace_map).
- Child faults on write → pf_handle_cow split path allocates a private new frame (refcount 1), memcpys, updates child PT, decrefs the old frame (2 → 1). Parent still holds the old frame at refcount 1.
- Later, either child or parent execve's:
  - Child's execve teardown walks the (post-split) child aspace. Its leaf points at the private frame (refcount 1). `phys_free` decrefs to 0 → returned to pool. Parent unaffected.
  - Parent's execve teardown walks the parent aspace. Its leaf points at the still-shared frame (refcount 1). `phys_free` decrefs to 0 → returned to pool. Child's private frames not touched.
- Case where both parent and child hold pre-split refcount 2:
  - First execve's teardown decrefs to 1 → bit stays set (correct: still owned by other party).
  - Second execve's teardown decrefs to 0 → bit clears.

All four cases fall out of the refcount discipline without additional logic in the walker.

### 4.2 Intermediate tables — always unique per aspace

At R17.M0, aspace_clone_cow delegates leaf installation in DST to `aspace_map`, which allocates fresh PDPT/PD/PT frames on demand (via `phys_alloc(0)` → refcount 1). Intermediates are never shared between aspaces — each aspace's PDPT/PD/PT chain is uniquely owned.

Consequence: freeing intermediates unconditionally via `phys_free` decrefs from 1 → 0 and returns the frame to the pool. No sharing means no keep-bit case for intermediates. This is why the walker calls `phys_free` for PT/PD/PDPT without any refcount check — the check is already inside `phys_free` and always resolves to "free".

(Future-work note: PT-level sharing between related aspaces — e.g., THP-style shared kernel-half PTs — would flow through the same refcount discipline unchanged; the walker would decref-and-move-on and the arbiter would keep the bit set. No walker change would be needed.)

### 4.3 KPTI trampoline PDPT — singleton, never walked

`kpti_build_user_pml4` populates PML4[256] with a shared singleton PDPT (cached in `_kpti_trampoline_pdpt_pa`). PT[260] maps the syscall trampoline text page; PT[261] maps the trampoline data page. The singleton is allocated once at first user aspace creation and never freed.

The walker stops at PML4 index 256 (`cmp r13, 256; jge teardown_l1_done`) so the trampoline PDPT chain is never visited. The trampoline PDPT's refcount stays at 1 (from its one-shot phys_alloc) for the lifetime of the kernel — freeing any user PML4 root drops PML4[256]'s POINTER TO the singleton but does not decref the singleton itself. That's correct: the singleton is a "kernel resource" not owned by any user aspace.

### 4.4 Current-aspace teardown — CR3 discipline

`sys_execve_body` step 4 commits `new_pml4` to TCB+16 BEFORE calling `aspace_teardown(old_pml4)`. But at teardown time, CR3 is still `_kernel_pml4_pa` — under strict KPTI, syscall_entry flipped CR3 to the kernel PML4 on entry, and it stays there through the whole body. The user PML4 being freed is NOT the current CR3.

The CR3 flip to the NEW user PML4 happens in the syscall_entry epilogue on sysret, which reads TCB+16 (already the new value). So freeing the old PML4 root at the end of teardown does not pull the rug out from under the CPU's page walker.

### 4.5 Refcount underflow — impossible by construction

`phys_free`'s #559 guard:
```asm
mov r11, [r10 + rdi*8];   ; load refcount
cmp r11, 0;
je phys_free_idempotent;  ; already 0 → no-op OK
sub r11, 1;
```

If the walker ever calls `phys_free` on a frame whose refcount is already 0 (bug elsewhere — double-free, stale PTE, ...), phys_free is a no-op. Underflow to `0xFFFFFFFF...` cannot happen through this path.

The R17.M0 shape guarantees no double-free through teardown: each aspace root has its own PT/PD/PDPT (unique intermediates at refcount 1); each shared leaf is decref'd once per teardown of the sharing aspace (so refcount matches the count of live sharers exactly).

---

## 5. Edge cases catalog

| Case                                       | Behavior                                                              |
|--------------------------------------------|-----------------------------------------------------------------------|
| Empty aspace (all PML4[0..255] == 0)       | L1 loop no-ops, phys_free the PML4 root only. Same as R15.M5.        |
| Fresh ELF-loaded aspace (execve rollback)  | Walker frees ELF-mapped leaves + intermediates + PML4 root.          |
| CoW-cloned aspace, unmodified              | Every leaf has refcount 2; teardown decrefs each to 1 (parent still owns). Intermediates decref to 0 → freed. PML4 root freed. |
| CoW-cloned aspace, post-split (some leaves private) | Split leaves have refcount 1 → freed. Unsplit leaves refcount 2 → decref only. |
| CoW-cloned aspace where parent already exited | Parent's earlier teardown decrefs shared leaves to 1; child's teardown finds refcount 1 → decref to 0 → freed. |
| Frame outside pool (PA ≥ 4 MiB)            | phys_free bounds-check returns PHYS_FREE_INVALID; teardown ignores return. No corruption. |
| Refcount underflow                         | Impossible: phys_free's idempotency guard turns refcount==0 case into a no-op. |
| Preemption during teardown                 | R17.M0 UP-only, IRQs disabled through syscall body per M4-003. Serialized on this CPU. Multi-core discipline is future-work (needs per-frame CAS on refcount decref). |

---

## 6. Test plan

### 6.1 AC preservation (primary)

`tools/run-smoke.sh boot_r17_init` must continue to produce the AC lines `CHILD HELLO 42` → `WAIT: pid=2 status=42` → `REAPED` in order. If teardown corrupts the child's aspace or the parent's state, either line will drop from the wire. 29/29 fingerprint match required.

### 6.2 Full smoke matrix

All 16 boot modes must remain green:
`boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`, `boot_r12_denial`, `boot_r14b_hivma`, `boot_r14b_kpti`, `boot_r14b_ipi`, `boot_r14b_loader`, `boot_r14b_ud`, `boot_r15_ring3`, `boot_r15_process`, `boot_r17_init`, `boot_panic`, `boot_panic_halt`, `boot_exc3`.

### 6.3 Frame-count witness (leak plug direct proof)

Added a boot-time witness `aspace_teardown_witness` in kernel_main that:
1. Snapshots `phys_alloc_free_count()`.
2. Creates a user aspace via `aspace_create_user` (allocates PML4 + KPTI PDPT/PD/PT — 4 frames for the first call, PML4 only for subsequent because the trampoline chain is a singleton).
3. Maps N pages via `aspace_map` (allocates N PT frames + up to log-N intermediate levels).
4. Tears down via `aspace_teardown`.
5. Verifies `phys_alloc_free_count()` returns to the snapshot value.

The witness runs twice to prove idempotence and to shake out any singleton-alloc surprises on the first call. Emitted marker: `R16 M0 D11A TEARDOWN OK\n`.

### 6.4 Adversarial verification

Post-landing, the r17_init wire log is inspected for:
- `CHILD HELLO 42` appears (proves child's aspace is intact — teardown didn't accidentally free the child's frames).
- `WAIT: pid=2 status=42` appears (proves parent's aspace is intact — teardown of the child's aspace didn't affect the parent's state).
- No `EXC HALT` between INIT ENTERED RING3 and REAPED.

---

## 7. Files changed

| File                                                     | Change                                                                 |
|----------------------------------------------------------|------------------------------------------------------------------------|
| `src/kernel/core/mm/aspace_teardown.pdx`                 | Rewrite walker with r8/r9/r10 preservation + 40-bit frame mask.        |
| `src/kernel/core/syscall/handlers/sys_execve.pdx`        | Restore `aspace_teardown(r14)` on the success path; remove SKIP note.  |
| `src/kernel/boot/kernel_main.pdx`                        | Add `aspace_teardown_witness` (§6.3) — pre/post frame-count assertion. |
| `tools/boot_stub.S`                                      | Add `aspace_teardown_ok_msg` string.                                   |
| `tests/r17/expected-boot-r17-init.txt`                   | Add `R16 M0 D11A TEARDOWN OK` fingerprint line.                        |

---

## 8. Follow-ups (post-D11a)

- **D11a-1**: same register-discipline audit for other walkers. `aspace_activate`, `aspace_unmap`, `pt_reclaim` may have similar clobber patterns; audit and fix as a batch.
- **D11a-2**: multi-core-safe refcount decref. `phys_free`'s current `mov r11, [r10+rdi*8]; sub r11, 1; mov [r10+rdi*8], r11` is not atomic. Under R18+ SMP, replace with `lock xadd` or `lock cmpxchg` loop. Discussed at length in `design/kernel/cow-multishare.md` but deferred.
- **D11a-3**: per-frame refcount pool overflow. `_frame_meta[]` is fixed at 1024 slots (matching `_phys_page_pool`); when pool grows past 1024, refcount storage must grow in lockstep. Currently no allocation-time check for this.
- **D11a-4**: witness for double-execve stress. Extend init.pdx to fork+execve N times and verify no unbounded free-count drift (would fold in the D12 dec-formatter for `WAIT: pid=X status=Y`).

---

## 9. Instruction-count budget

| Site                          | Instructions | Notes                                    |
|-------------------------------|-------------:|------------------------------------------|
| L1 loop body                  |          ~10 | Unchanged from R14-m2-005.               |
| L2 loop body                  |          ~10 | Unchanged.                               |
| L3 loop body                  |          ~10 | Unchanged.                               |
| L4 loop body (per leaf)       |          ~20 | +8 for r8/r9/r10 save/restore + pad.     |
| L4 done (PT free)             |           ~8 | +6 for r8/r9 save.                       |
| L3 done (PD free)             |           ~6 | +4 for r8 save + pad.                    |
| L2 done (PDPT free)           |           ~3 | No preserve needed.                      |
| L1 done (PML4 free)           |           ~3 | Terminal.                                |

Net cost for a 5-leaf aspace: ~150 additional instructions vs. pre-D11a — negligible next to phys_free's ~50 instructions per call.
