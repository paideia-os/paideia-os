---
issue: 555
milestone: R15.M6 (fork / exec / wait / _exit)
subsystem: 9 — fork / exec / wait / _exit
prereq:
  - "#548 (task_new real — LANDED at src/kernel/core/sched/task_pool.pdx; provides task_struct with user_pml4_pa @ 16 the witness drives)"
  - "#549 (fd_table embed — LANDED; pins task_struct offsets 0/4/8/12/16 sys_execve reads/writes)"
  - "#517 (elf_lite_load real body — LANDED at src/kernel/core/loader/elf_lite.pdx; consumed verbatim as the load primitive)"
  - "#648 (elf_lite_load runtime bugs — LANDED at 149c563/89029d9; W^X mask 0x3, HIGH_HALF jae, phys_alloc order=0)"
  - "#513 (aspace_create_user — LANDED at src/kernel/core/mm/aspace_create.pdx:96)"
  - "#649 (phys_free real body — LANDED at 6bbd247)"
  - "R14-m2-005 (aspace_teardown — LANDED at src/kernel/core/mm/aspace_teardown.pdx; walks user PML4 [0..255], frees leaves + PT + PD + PDPT via phys_free)"
  - "R15.M6-006 / #557 (sys_exit_body — LANDED; source of the body/wrapper split pattern this doc mirrors)"
  - "R15.M6-005 / #556 (sys_wait_body — LANDED; witness-authored discipline this doc extends)"
blocks:
  - "R15.M6-007 / #558 (orphan reparent — independent; but shares the task_struct pinning)"
  - "R15.M6-009 / #560 (fork/exec/wait smoke — the fingerprint 'child now runs shell code' proves fork+execve+wait round-trip)"
touching:
  - src/kernel/core/syscall/handlers/sys_execve.pdx        (NEW module in existing handlers/ dir)
  - src/kernel/boot/kernel_main.pdx                        (witness block, ~110 LOC)
  - tools/boot_stub.S                                      (2 rodata strings + 64B BAD_ELF stub)
  - tests/r15/expected-boot-r15-process.txt                (marker line, contains-in-order)
  - tests/r15/expected-boot-r15-ring3.txt                  (marker line, contains-in-order)
  - tests/r14b/expected-boot-r14b-loader.txt               (marker line, contains-in-order)
  - design/kernel/r15-m6-004-sys-execve.md                 (this doc)
related:
  - design/kernel/r15-m1-008b-elf-lite-load-runtime-bugs.md  (§4 W^X mask + HIGH_HALF fixes this body consumes)
  - design/kernel/r15-m6-006-sys-exit.md                    (§3.2 body/wrapper split — this doc mirrors)
  - design/kernel/r15-m6-005-sys-wait.md                    (§3.7 minimal-reap leak budget analogue)
  - design/kernel/r15-m5-006-task-new-real.md               (task_struct field offsets — 0/4/8/12/16 pinned)
  - design/milestones/r14b-tactical-plan.md                 (§Subsystem 9 issue 4 — sys_execve entry)
---

# R15-M6-004 — sys_execve real body: fresh-then-swap aspace + elf_lite_load (#555)

## 1. Scope

Give `sys_execve` a real, testable body so that:

1. `sys_execve_body(current, image_ptr, image_len)`:
   - Allocates a fresh user address space via `aspace_create_user()`.
   - Loads the ELF64 image at `image_ptr` (kernel-space pointer,
     length `image_len`) into the fresh aspace via
     `elf_lite_load(new_pml4, image_ptr, image_len)`.
   - On success: swaps `current->user_pml4_pa` (@ 16) to the new
     aspace, tears down the old aspace via `aspace_teardown`,
     extracts `e_entry` from the ELF header at `image_ptr + 24`,
     and returns `{rax = 0, rdx = entry_rip}`.
   - On failure at any step: tears down the fresh (partially
     mapped) aspace via `aspace_teardown`, leaves
     `current->user_pml4_pa` unchanged (rollback), and returns
     `{rax = error_code, rdx = 0}` where the error code comes
     from `aspace_create_user` (OOM) or `elf_lite_load`
     (`ELF_BAD_HDR`, `ELF_WX`, `ELF_HIGH_HALF`, `ELF_BAD_SIZE`,
     `ELF_OOM`, `ELF_MAP_ERR`) verbatim.

2. **POSIX-preserved fields (unchanged by this body):**
   - `current->pid` @ 0            — survives exec by contract.
   - `current->parent_pid` @ 4     — process identity does not change.
   - `current->state` @ 8          — the state machine is not touched
     (the caller decides RUNNABLE post-exec; body neither reads nor
     writes state).
   - `current->fd_table` @ 168     — 256 bytes (32 u64 slots) untouched;
     R15.M5 fd slots are opaque u64s with no CLOEXEC flag concept yet,
     so "close CLOEXEC fds" is a no-op at R15.M6 (deferred to R16.M3
     when fd_entry grows a flags word).

3. **AC "fixture forks, child execves shell.bin, child now runs
   shell code":** met at the *body* level by proving
   (a) new_pml4 differs from old, (b) new_pml4 has PT_LOAD segments
   mapped (structurally, via elf_lite_load's success return),
   (c) entry_rip returned matches `_shell_bin_start + 24` (the ELF
   `e_entry` field). Actually *running* the shell requires the
   syscall wrapper + iretq into ring-3 with CR3 = new_pml4, which
   is the wrapper's concern (deferred; see §Scope out-of-scope).

Two invariants define completion:

- **Rollback atomicity.** After a failing `sys_execve_body`, the
  parent task's aspace (`current->user_pml4_pa`) is byte-identical
  to its pre-call state. No half-swap. The failed fresh aspace is
  freed (leaves + intermediate PTs/PDs/PDPTs); the new PML4 frame
  itself leaks (§3.7 leak budget, matches aspace_teardown's
  R14-m2-005 discipline).

- **Commit atomicity.** On success, `current->user_pml4_pa` is
  swapped to the new aspace in one u64 store BEFORE the old
  aspace is torn down. If the body were interrupted between the
  swap and the teardown (impossible at R15.M6 single-CPU with
  IRQs disabled through the body), the parent would already be
  seeing the new aspace on next return-to-user; the old aspace
  would be an orphan leak but not corrupt.

Explicitly out of scope (deferred):

- **Syscall wrapper wiring.** The current `sys_execve` slot in
  `src/kernel/core/syscall/dispatch.pdx:11` is listed among the
  five R15.M6 syscalls but has no dispatch label (routes to
  `dispatch_enosys`). This doc lands the *body*
  (`sys_execve_body`) as a nested-call function testable without
  a real syscall entry. The wrapper that reads `current` from
  cpu_local (via `cpu_local_get`), calls `sys_execve_body`,
  then either (a) on success, installs `entry_rip` into the
  iretq frame + user_stack_alloc into rsp + CR3 = new_pml4_pa +
  iretq; or (b) on failure, returns the error code to userspace
  via rax — that wire-up is a downstream edit paired with
  R15.M6-001 sched_pick_next OR sys_execve-specific enter-user
  helper. Deferred.

- **User stack allocation.** The AC "child now runs shell code"
  needs a fresh user stack in the new aspace. `user_stack_alloc`
  is a separate function at
  `src/kernel/core/mm/user_stack.pdx`. This body deliberately
  does NOT call it — stack allocation is the wrapper's concern
  (it needs to know the initial_rsp to write into the iretq
  frame). Split rationale: keeping the body a pure
  aspace-transform + ELF-load leaf makes it re-usable for
  cases where the caller wants to pre-allocate stack
  differently (e.g., for a thread-of-existing-process
  variant later).

- **Path-based execve (`sys_execve(path, argv, envp)`).**
  R15.M6 has no VFS; the body signature is
  `(current, image_ptr, image_len)` where `image_ptr` is a
  kernel-space pointer to an already-loaded ELF blob. Path
  resolution is deferred to R16.M1+ when VFS lands (§6.5
  backtrack E is the migration path).

- **argv / envp / auxv setup.** POSIX execve pushes argv,
  envp, and an auxv onto the new user stack. That's a
  wrapper concern (needs the initial_rsp from
  user_stack_alloc; needs userspace copy_from_user for the
  original argv/envp). Deferred to the wrapper landing.

- **CLOEXEC fd handling.** R15.M5 fd_table is 32 opaque u64
  slots with no flags word. The POSIX "close CLOEXEC fds"
  requirement is met vacuously (no fd carries CLOEXEC yet).
  When R16.M3 grows fd slots to `fd_entry` with a flags word,
  a `fd_close_cloexec(current)` call inserts here at step 3.5
  (before elf_lite_load — see §6.3 backtrack C for the
  insertion point).

- **Signal state reset.** POSIX execve resets signal handlers
  to SIG_DFL. R15.M6 has no signal state on task_struct;
  vacuous.

- **File-based ELF payload validation on failure semantics.**
  POSIX execve does NOT return on success, and returns
  -errno on failure. This body's rax = 0 return on success
  is a *body-level* success signal for the wrapper; the
  wrapper never returns to userspace on that path (it does
  iretq into `entry_rip`). The body-level "return with 0" is
  the wrapper's cue to iretq; the wrapper is where the
  "does-not-return" property is realized.

- **fork+execve round-trip smoke.** This body's witness
  drives sys_execve on a task without a live fork parent
  (r15-m6-009 smoke is where the fork+exec pipeline is
  exercised end-to-end).

## 2. Prereq check

### 2.1 What's in place

| Primitive                    | Location                                           | Contract used by sys_execve_body                    |
|------------------------------|----------------------------------------------------|-----------------------------------------------------|
| `task_struct.user_pml4_pa @ 16` | `#549 §3.1 layout freeze`                       | u64, read (old pml4) + written (swap to new pml4)   |
| `task_struct.pid @ 0`        | `#549 §3.1 layout freeze`                          | not touched (POSIX preserves)                       |
| `task_struct.parent_pid @ 4` | `#549 §3.1 layout freeze`                          | not touched                                         |
| `task_struct.state @ 8`      | `#557 §3.4 state freeze`                           | not touched                                         |
| `task_struct.fd_table @ 168` | `#549 §3.1 layout freeze`                          | not touched (opaque u64s survive exec)              |
| `aspace_create_user()`       | `core/mm/aspace_create.pdx:96`                     | Returns rax = new pml4_pa (VA form), or 0xFFFFFFFF on OOM |
| `elf_lite_load(pml4, ptr, len)` | `core/loader/elf_lite.pdx:205`                  | Returns rax = 0 on success, error code on failure   |
| `aspace_teardown(pml4)`      | `core/mm/aspace_teardown.pdx:14`                   | Walks user PML4 [0..255], frees leaves + PT/PD/PDPT via phys_free; PML4 frame itself is left behind |
| ELF e_entry @ image_ptr + 24 | ELF64 spec §4.1.1 (Elf64_Ehdr)                     | u64 load; extracted after elf_lite_load succeeds    |
| `_shell_bin_start` / `_end`  | `tools/userbin_embed.S`                            | RIP-relative bracket around embedded shell.elf      |

### 2.2 What is not in place — required prerequisites this doc consumes on faith

- **cpu_local `current_task()` accessor** — needed by the
  syscall wrapper `sys_execve`, NOT by `sys_execve_body`. This
  split lets the body land testably without the accessor.
  Same discipline as #557 §2.2 and #556 §2.2.
- **user_stack_alloc integration.** The wrapper (deferred)
  is where `user_stack_alloc(new_pml4_pa)` runs to produce
  the initial rsp for iretq. Body-level witness proves
  entry_rip extraction; wrapper-level integration test
  (r15-m6-009 smoke) proves the initial_rsp round-trip.
- **iretq frame construction.** The wrapper (deferred) writes
  {cs=USER_CS, ss=USER_SS, rflags=0x200, rip=entry_rip,
  rsp=initial_rsp} to the syscall-entry stack frame. Body
  returns entry_rip via rdx; that's the sole handoff.

### 2.3 Encoder gaps

**None.** The sys_execve_body uses only:

- Register-to-register `mov`, `xor`, `cmp` — audited substrate
- `mov r64, [reg + disp8]` — audited by fd_table stores,
  sys_exit body, sys_wait body
- `mov [reg + disp8], r64` — same
- `push` / `pop` on rbx / r12 / r13 / r14 / r15 — audited by
  elf_lite_load, task_new, sys_wait
- 5 `call rel32` — audited by task_new (3-call chain),
  elf_lite_load (nested calls to phys_alloc + aspace_map)
- `mov rax, imm32` (error code constants like 0xFFFFFFFB) —
  audited everywhere

**No new paideia-as patterns.** Every mnemonic maps to an
existing precedent.

## 3. Design

### 3.1 task_struct field consumption (R15.M6 addendum)

This body reads/writes exactly one field on `current`:

```
offset   size   field           type   role
------   ----   -------------   ----   -------------------------------------
  16       8    user_pml4_pa    u64    read (old, for teardown), written (new, on commit)
```

Preserved (neither read nor written):

```
   0       4    pid             u32    POSIX: survives exec
   4       4    parent_pid      u32    POSIX: survives exec
   8       4    state           u32    caller's decision (wrapper resumes at RUNNABLE)
  12       4    exit_status     u32    only meaningful post-sys_exit
 168     256    fd_table[32]    u64[]  POSIX: fds survive exec (CLOEXEC deferred R16.M3)
```

No new field pins. This doc consumes the #549 / #557 freeze
verbatim.

### 3.2 Function split — testable body + syscall wrapper

```
sys_execve_body : (u64, u64, u64) -> {u64, u64} !{mem, sysreg} @{}
    Body function with nested calls (aspace_create_user,
    elf_lite_load, aspace_teardown). Testable via witness with
    explicit `current` pointer, kernel-space image pointer, and
    length — no cpu_local, no scheduler, no return-to-user.
    Returns {rax = 0, rdx = entry_rip} on success;
    {rax = error_code, rdx = 0} on failure.

sys_execve_wrapper : (image_ptr: u64, image_len: u64) -> ! !{mem, sysreg} @{sched}
    NOT LANDED THIS ISSUE. Downstream edit. Reads
    current = cpu_local_get()->current_task; validates
    userspace pointer if image_ptr is a userspace address
    (R16.M1 with VFS); calls sys_execve_body; on success
    calls user_stack_alloc(new_pml4_pa) for initial_rsp,
    writes iretq frame {cs=USER_CS, ss=USER_SS,
    rflags=0x200, rip=entry_rip, rsp=initial_rsp}, loads
    CR3 = new_pml4_pa, iretq — never returns. On failure
    returns error_code via rax to the sysret path.
```

Why the split. Same rationale as #557 §3.2 and #556 §3.2 —
the R15.M6 discipline is "witness pattern, no real syscall
wiring". Splitting the leaf body from the wrapper ships now,
wrapper edits `dispatch.pdx` when the scheduler + iretq-frame
helper are ready.

### 3.3 Body sequence — six steps, one rationale

```
sys_execve_body(current, image_ptr, image_len):
  step 1   old_pml4 = current->user_pml4_pa                (u64 load @ 16)
           r14 = old_pml4                                   (save for teardown-on-success or rollback identity)
           r12 = image_ptr, r13 = image_len                (survive nested calls)

  step 2   new_pml4 = aspace_create_user()                  (nested call)
           if new_pml4 == 0xFFFFFFFF: return {ELF_OOM, 0}   (aspace-alloc OOM)
           r15 = new_pml4

  step 3   rc = elf_lite_load(new_pml4, image_ptr, image_len)  (nested call)
           if rc != 0: goto step 5 (rollback with rc)

  step 4   // SUCCESS PATH — commit
           current->user_pml4_pa = new_pml4                 (u64 store @ 16)
           aspace_teardown(old_pml4)                        (nested call — leaves + PTs freed)
           rdx = *(u64 *)(image_ptr + 24)                   (e_entry from ELF header)
           return {rax = 0, rdx = entry_rip}

  step 5   // FAILURE PATH — rollback
           save rc into r14 (repurpose; old_pml4 not needed on rollback)
           aspace_teardown(new_pml4)                        (nested call — free partial mappings)
           // current->user_pml4_pa unchanged (still = old_pml4)
           return {rax = rc, rdx = 0}
```

**Why this order.**

1. **Save old_pml4 BEFORE new-aspace creation (step 1).** The
   rollback path (step 5) must be able to leave `current`
   pointing at the ORIGINAL aspace. We never *store* to
   `current->user_pml4_pa @ 16` on the failure path — the
   original value is retained by omission. But saving old_pml4
   into r14 in step 1 makes the on-success teardown (step 4)
   possible without a second u64 load.

2. **Fresh-then-swap over in-place-mutate (§3.4 discusses
   alternatives).** Creating a NEW aspace via
   `aspace_create_user`, loading into IT, and swapping on
   success gives transactional semantics. In-place mutation
   (aspace_teardown → elf_lite_load into same pml4) would
   partially destroy the old aspace before we know if the
   load succeeds, breaking the AC "on failure, original state
   preserved".

3. **elf_lite_load into fresh aspace (step 3).** The load
   primitive is trusted end-to-end after #648. It allocates
   physical pages via phys_alloc and calls aspace_map for
   each PT_LOAD segment page. On error it does NOT unwind
   partial mappings — that's step 5's job via aspace_teardown.
   This body treats elf_lite_load as an atomic "either loaded
   or partially-mapped-into-a-throwaway-aspace".

4. **Commit ordering (step 4).** The u64 store
   `current->user_pml4_pa = new_pml4` happens BEFORE
   `aspace_teardown(old_pml4)`. If the store completed and
   teardown was interrupted (single-CPU R15.M6: interrupts
   must be disabled through this body — see §3.6), the
   worst case is: current points at new (correct), old
   leaks (bad, but not corrupt). Reversing the order
   (teardown-first, store-later) would produce: current
   points at old (which was already partially freed) — a
   correctness bug.

5. **e_entry extraction AFTER elf_lite_load succeeds
   (step 4).** elf_lite_load has already validated the ELF
   header (magic, class, endian, version, type, machine,
   phentsize, bounds). Reading `[image_ptr + 24]` at this
   point is trusted. If the caller passes a bogus image_ptr
   that happens to satisfy elf_lite_load's checks but has
   garbage at offset 24 (unreachable per format: the header
   is a fixed 64-byte struct that either validates as a whole
   or is rejected), rdx = garbage. That's an ELF-format
   invariant violation, not a body bug.

6. **aspace_teardown of new_pml4 on failure (step 5).** The
   new pml4 may have partial PT_LOAD mappings (elf_lite_load
   allocated pages via phys_alloc and mapped them via
   aspace_map before failing). aspace_teardown walks and
   frees them. The new PML4 frame itself leaks (aspace_teardown
   does not free the root). Rationale: this matches the R14b
   aspace_teardown contract; a follow-up (§6.2 backtrack B)
   promotes to full-teardown once phys_free's frame-metadata
   audit is complete.

**Register discipline note.** The 5-call chain (aspace_create_user,
elf_lite_load, aspace_teardown [x2 branches]) requires a stable
scratch base. r12/r13/r14/r15 all callee-save; rbx also. Five
callee-save regs are held live across nested calls; prologue = 5
pushes = 40 bytes. Combined with return-address push (8 bytes) =
48 bytes = 16 mod 0. Nested calls see rsp aligned to 16.

### 3.4 Aspace teardown strategy — fresh-then-swap vs. alternatives

Three feasible strategies. This doc adopts **A**.

#### Strategy A: Fresh-then-swap (adopted, §3.3)

1. `new = aspace_create_user()`
2. `elf_lite_load(new, image, len)` — into fresh aspace
3. **On success:** `current->user_pml4_pa = new; aspace_teardown(old)`
4. **On failure:** `aspace_teardown(new)` (rollback); current unchanged

Pros:
- Transactional. Failure atomicity is trivial (current unchanged).
- No moment where current points at a half-built aspace.
- elf_lite_load runs against a known-empty aspace — no
  worry about stale PT PRESENT bits.

Cons:
- Peak memory: ~2× aspace during the fresh-then-swap window.
  At R15.M6 with a 32 MiB pool budget and typical shell.elf
  size (a few pages of PT_LOAD), peak is negligible.
- New PML4 frame leaks on rollback (~4 KiB per failed exec).
  Same leak class as R14b aspace_teardown; §6.2 backtrack B
  is the follow-up.

#### Strategy B: In-place teardown-then-load (rejected)

1. `aspace_teardown(current->user_pml4_pa)` — clear old mappings
2. `elf_lite_load(current->user_pml4_pa, image, len)` — reload

Pros:
- No peak-memory overhead (1× aspace throughout).
- No PML4-frame allocation for the new aspace.

Cons:
- **Non-atomic failure.** If elf_lite_load fails after
  aspace_teardown ran, the original aspace is already
  destroyed. The caller cannot recover — the task must die.
  Violates the AC "on invalid ELF: verify original state
  preserved".
- **Stale PT PRESENT bit hazard.** aspace_teardown walks
  user PML4 [0..255] and frees leaf pages via phys_free, but
  does it CLEAR the PTE (write 0 to the entry) after freeing?
  Reading aspace_teardown.pdx §3.7 (teardown_l4_next add rbx),
  the loop only calls phys_free on the leaf address; it does
  NOT store 0 to `[pt_pa + rbx*8]`. So the PT entry keeps
  its PRESENT bit set with a now-freed frame address.
  Subsequent `elf_lite_load → aspace_map` would find the PTE
  PRESENT and skip the map_pt allocation, then write the new
  leaf entry — but the intermediate PT/PD/PDPT frames were
  freed too. Aliased-frame corruption ensues.
- Fixing strategy B requires editing aspace_teardown to zero
  PTEs after phys_free, which is a substrate change with
  broader impact (KPTI structural witness, ring3 witness).
  Out of scope for this issue.

Reject.

#### Strategy C: Teardown-only-leaves, keep intermediate PTs (rejected)

A variant of B where aspace_teardown is called with a "leaves
only" mode that leaves the PT/PD/PDPT structure intact, allowing
elf_lite_load to reuse them.

Cons:
- Requires a new aspace_teardown mode → substrate churn.
- elf_lite_load's aspace_map WOULD collide with the retained
  intermediate PTs (present bit set with stale leaf frame
  addresses) — same problem as B, just at a lower level.
- No obvious performance advantage over A at R15.M6 pool sizes.

Reject.

### 3.5 File and module structure

```
src/kernel/core/syscall/handlers/sys_execve.pdx    <-- NEW module (this issue)
src/kernel/core/syscall/handlers/sys_exit.pdx      <-- exists (#557)
src/kernel/core/syscall/handlers/sys_wait.pdx      <-- exists (#556)
```

`handlers/` directory created by #557. No layout / build-script
edit needed.

**Full module skeleton:**

```pdx
// src/kernel/core/syscall/handlers/sys_execve.pdx — R15-M6-004 (#555)
// execve body: fresh-then-swap aspace + elf_lite_load, extract e_entry.
//
// Issue #555 (R15.M6 subsystem 9 issue 4).

module SysExecve = structure {
  // ==========================================================================
  // Field offsets — pinned by #549 / #557
  // ==========================================================================
  pub let TASK_OFF_USER_PML4_PA : u64 = 16

  // ELF64 header field offsets (per ELF64 spec §4.1.1 Elf64_Ehdr)
  pub let ELF_E_ENTRY_OFFSET    : u64 = 24

  // Error code passthrough (mirror elf_lite.pdx constants)
  pub let ELF_OK                : u64 = 0
  pub let ELF_OOM               : u64 = 0xFFFFFFFB

  // aspace_create_user OOM sentinel (per aspace_create.pdx:99)
  pub let ASPACE_OOM_SENTINEL   : u64 = 0xFFFFFFFF

  // ==========================================================================
  // R15-M6-004 (#555): sys_execve_body — testable via witness
  // ==========================================================================
  pub let sys_execve_body : (u64, u64, u64) -> u64 !{mem, sysreg} @{} =
    fn (current: u64) (image_ptr: u64) (image_len: u64) -> unsafe {
      effects: {mem, sysreg},
      capabilities: {},
      justification: "R15-M6-004 (#555): sys_execve body — fresh-then-swap aspace strategy. Entry: rdi = current (*task, non-NULL), rsi = image_ptr (kernel-space ELF64 blob), rdx = image_len (byte count). Return via {rax, rdx}: on success rax = 0 and rdx = entry_rip (ELF e_entry, u64 @ image_ptr+24); on failure rax = error_code from aspace_create_user (0xFFFFFFFB=OOM) or elf_lite_load (0xFFFFFFFF=BAD_HDR, 0xFFFFFFFE=HIGH_HALF, 0xFFFFFFFD=WX, 0xFFFFFFFC=BAD_SIZE, 0xFFFFFFFB=OOM, 0xFFFFFFFA=MAP_ERR) and rdx = 0. Six steps: (1) prologue push rbx,r12,r13,r14,r15 (5 pushes = 40B; +8 return-addr = 48B = 16 mod 0 aligned). Save rbx=current, r12=image_ptr, r13=image_len, r14=old_pml4 (loaded from current->user_pml4_pa @ 16). (2) Call aspace_create_user() → rax. If rax == 0xFFFFFFFF, jump to oom_return with rax=ELF_OOM. Else r15 = new_pml4. (3) Call elf_lite_load(r15=new_pml4, r12=image_ptr, r13=image_len). If rax != 0, save rc to r14 (repurpose; old_pml4 no longer needed), tear down partial new aspace via aspace_teardown(r15), return {rax=r14, rdx=0}. (4) SUCCESS: store r15 → [rbx + 16] (commit swap). Call aspace_teardown(r14=old_pml4). Load rdx = [r12 + 24] (e_entry from ELF header, u64). Return {rax=0, rdx=entry_rip}. Register discipline: rbx (current), r12 (image_ptr), r13 (image_len), r14 (old_pml4 / repurposed rc), r15 (new_pml4) all callee-save-preserved via 5-push prologue. All nested calls (aspace_create_user, elf_lite_load, aspace_teardown) trusted callee-save clean per their own justifications. Rollback atomicity: on failure path, [rbx + 16] is NEVER written; current->user_pml4_pa retains its original value. Commit atomicity: [rbx + 16] store happens BEFORE aspace_teardown(old); at R15.M6 single-CPU with IRQs disabled through the body, no interleaving is possible. Leak budget: on rollback path, new_pml4 root frame leaks (~4 KiB); on commit path, old_pml4 root frame leaks — matches aspace_teardown's R14-m2-005 contract (root frame not freed by teardown). Follow-up §6.2 backtrack B promotes to full-teardown once phys_free of the root frame is safe.",
      block: {
        // ===== prologue =====
        push rbx;
        push r12;
        push r13;
        push r14;
        push r15;

        mov rbx, rdi;                           // rbx = current
        mov r12, rsi;                           // r12 = image_ptr
        mov r13, rdx;                           // r13 = image_len

        // ===== step 1: save old pml4 =====
        mov r14, [rbx + 16];                    // r14 = old_pml4_pa (u64 @ 16)

        // ===== step 2: allocate fresh aspace =====
        call aspace_create_user;
        mov rcx, 0xFFFFFFFF;                    // ASPACE_OOM_SENTINEL
        cmp rax, rcx;
        je sys_execve_oom;
        mov r15, rax;                           // r15 = new_pml4_pa

        // ===== step 3: elf_lite_load into fresh aspace =====
        mov rdi, r15;                           // arg 1: new_pml4_pa
        mov rsi, r12;                           // arg 2: image_ptr
        mov rdx, r13;                           // arg 3: image_len
        call elf_lite_load;
        cmp rax, 0;                             // ELF_OK
        jne sys_execve_load_fail;

        // ===== step 4: SUCCESS — commit swap =====
        mov [rbx + 16], r15;                    // current->user_pml4_pa = new_pml4

        // Teardown old aspace (best-effort; leaks root frame per aspace_teardown contract)
        mov rdi, r14;
        call aspace_teardown;

        // Extract e_entry from ELF header @ image_ptr + 24
        mov rdx, [r12 + 24];                    // rdx = entry_rip (u64)
        xor rax, rax;                           // rax = ELF_OK (0)
        jmp sys_execve_return;

      sys_execve_load_fail:
        // rax = error_code from elf_lite_load. Save it; teardown new aspace.
        mov r14, rax;                           // r14 = rc (repurpose)
        mov rdi, r15;
        call aspace_teardown;                   // free partial mappings in new_pml4
        mov rax, r14;                           // restore rc
        xor rdx, rdx;
        jmp sys_execve_return;

      sys_execve_oom:
        mov rax, 0xFFFFFFFB;                    // ELF_OOM
        xor rdx, rdx;

      sys_execve_return:
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

Total executable LOC: ~40 assembly lines + ~15 justification /
constants = ~75 LOC in `sys_execve.pdx`. Slightly larger than
`sys_wait_body` (~60 LOC) due to the multi-branch commit/rollback
structure.

### 3.6 Register discipline — 5-push prologue

**Registers this body uses:**

| Register | Role                                            | Callee-save? | Prologue push? | Survives nested calls? |
|----------|-------------------------------------------------|--------------|----------------|-----------------------|
| rbx      | current (parent slab, for commit store)         | callee-save  | yes            | yes                   |
| r12      | image_ptr (survives elf_lite_load, used at step 4 for e_entry read) | callee-save | yes | yes |
| r13      | image_len (survives aspace_create_user; needed by elf_lite_load) | callee-save | yes | yes |
| r14      | old_pml4 (step 1) / repurposed rc (step 5)      | callee-save  | yes            | yes                   |
| r15      | new_pml4 (from aspace_create_user; needed by elf_lite_load + teardown-on-fail + commit-on-succ) | callee-save | yes | yes |
| rax      | return value / scratch                          | caller-save  | no             | n/a                   |
| rcx      | OOM-sentinel constant load                      | caller-save  | no             | n/a                   |
| rdi      | arg reg (aspace_create_user takes 0 args; elf_lite_load arg 1; aspace_teardown arg 1) | caller-save | no | n/a |
| rsi      | arg reg (elf_lite_load arg 2)                   | caller-save  | no             | n/a                   |
| rdx      | arg reg (elf_lite_load arg 3) / return value    | caller-save  | no             | n/a                   |

**5 pushes** (rbx, r12, r13, r14, r15) = 40 bytes; combined with
return-address push (8 bytes) = 48 bytes = 16 mod 0. All nested
calls see rsp aligned to 16 bytes — required by System V AMD64
ABI at every `call` site.

**All 5 nested calls (aspace_create_user, elf_lite_load,
aspace_teardown x2) are audited callee-save-clean per their own
justification strings.** Specifically:

- `aspace_create_user` (aspace_create.pdx:96): pushes r12/r13/r14
  in its own prologue; guarantees rbx/r12/r13/r14/r15 preserved.
- `elf_lite_load` (elf_lite.pdx:205): pushes r12/r13/r14/r15/rbx
  in prologue; guarantees all 5 callee-save preserved.
- `aspace_teardown` (aspace_teardown.pdx:14): pushes rbx/r15/r14/
  r13/r12; guarantees all 5 callee-save preserved.

**The endemic bug class NOT reached.** Recent post-mortems
(`f6195ed` phys_alloc r12-r15 fix, `3e6a550` self-IPI callee-save
audit) show what happens when this discipline is violated. This
body's 5-push prologue matches the elf_lite_load discipline and
survives every nested call correctly.

### 3.7 Leak budget — the fresh-then-swap PML4 frame residue

Same discipline as sys_wait §3.7. This body leaks the root PML4
frame in two paths:

| Path       | Leaked resource               | Size    | Recovered by                              |
|------------|-------------------------------|---------|-------------------------------------------|
| Success    | Old PML4 root frame           | 4 KiB   | R15.M6-007+ full-teardown promotion       |
| Failure    | New PML4 root frame           | 4 KiB   | R15.M6-007+ full-teardown promotion       |

**Why the leak is acceptable at R15.M6:**

1. **aspace_teardown contract inherited.** R14-m2-005's
   `aspace_teardown` walks user PML4 [0..255] freeing leaves +
   PT/PD/PDPT via phys_free, but explicitly leaves the root PML4
   frame in place — the caller decides root disposal. Every
   caller of aspace_teardown in the tree inherits this leak (the
   R15.M1-008 loader witness leaks by design; the KPTI structural
   witness leaks by design). sys_execve is consistent with this
   discipline.
2. **Bounded leak surface.** Every failed exec leaks 4 KiB; every
   successful exec leaks 4 KiB. With a 32 MiB physical pool
   budget and typical exec churn (dozens of execs per boot),
   worst-case leak is <1 MiB. Well within R14b budget.
3. **Explicit backtrack path.** §6.2 backtrack B lands
   `aspace_teardown_root(pml4)` (a wrapper that calls
   aspace_teardown then phys_free(pml4, 0)) as a follow-up
   once phys_free of the root frame is verified safe. One-line
   swap in sys_execve_body's step 4 and step 5.
4. **Rollback atomicity is preserved.** The leak does not affect
   correctness — failure atomicity means current->user_pml4_pa
   is unchanged; leaked frames are unreachable from any live
   task_struct and will be swept by a future GC pass or R16+
   audit-log design.

### 3.8 Encoding notes — every mnemonic used

| Mnemonic                       | Byte pattern (nominal)          | Audited by                              |
|--------------------------------|---------------------------------|-----------------------------------------|
| `push rbx`                     | 53                              | elf_lite_load prologue                  |
| `push r12 / r13 / r14 / r15`   | 41 54 / 41 55 / 41 56 / 41 57   | elf_lite_load, task_new                 |
| `pop rbx / r12 / r13 / r14 / r15` | 5B / 41 5C / 41 5D / 41 5E / 41 5F | elf_lite_load epilogue           |
| `mov rbx, rdi`                 | 48 89 FB                        | Everywhere                              |
| `mov r12, rsi / r13, rdx`      | 49 89 F4 / 49 89 D5             | elf_lite_load setup                     |
| `mov r14, [rbx + disp8]`       | 4C 8B 73 xx                     | REX.R + 8B; task_pool.pdx / sys_wait    |
| `mov [rbx + disp8], r15`       | 4C 89 7B xx                     | REX.R + 89; task_new field store        |
| `mov rdx, [r12 + disp8]`       | 49 8B 54 24 xx                  | REX.B + SIB (r12 requires SIB byte)     |
| `call rel32`                   | E8 xx xx xx xx                  | Everywhere                              |
| `mov rcx, imm32` (0xFFFFFFFF)  | 48 C7 C1 xx xx xx xx           | sys_wait constant load                  |
| `mov rax, imm32` (0xFFFFFFFB)  | 48 C7 C0 xx xx xx xx           | Everywhere                              |
| `cmp rax, rcx / rax, 0`        | 48 39 C8 / 48 83 F8 00          | Everywhere                              |
| `je / jne / jmp / ret`         | 74 / 75 / EB / C3               | Everywhere                              |
| `xor rax, rax / rdx, rdx`      | 48 31 C0 / 48 31 D2             | Everywhere                              |

**Note on `mov rdx, [r12 + disp8]`.** r12 as a base register
requires a SIB byte encoding (r12's 3-bit index collides with
the "SIB follows" ModRM encoding). paideia-as handles this
correctly (audited by `elf_lite_load` at line 279 where
`[rsp + 0]` and similar r12-based accesses are already emitted).
No new gap.

**No new paideia-as encoder gap.** Every mnemonic maps to an
existing precedent in the codebase.

## 4. Test canary — kernel_main witness block

### 4.1 Witness shape

Two sub-tests exercise the success + rollback paths:

- **Sub-test A** (valid ELF → success + swap):
  Use the embedded shell.elf blob at `_shell_bin_start` /
  `_shell_bin_end` (already used by the loader runtime witness
  at kernel_main.pdx:990). Task constructed via `task_new(NULL)`,
  which populates `user_pml4_pa` from a fresh
  `aspace_create_user`. Call `sys_execve_body(t, image_ptr,
  image_len)`. Assert:
  - `rax == 0` (ELF_OK)
  - `rdx == *(u64 *)(_shell_bin_start + 24)` (ELF e_entry)
  - `t->user_pml4_pa @ 16 != old_pml4` (swap occurred)
  - `t->pid @ 0 == pre_call_pid` (unchanged)
  - `t->state @ 8 == pre_call_state` (unchanged)

- **Sub-test B** (invalid ELF → rollback):
  Create a 64-byte "BAD_ELF" stub in `tools/boot_stub.S`
  rodata — a 64-byte block that starts with garbage magic
  (`\xDE\xAD\xBE\xEF...`). Task constructed via `task_new(NULL)`.
  Save `old_pml4 = t->user_pml4_pa`. Call `sys_execve_body(t,
  _bad_elf_stub, 64)`. Assert:
  - `rax != 0` (specifically, `rax == 0xFFFFFFFF` = ELF_BAD_HDR
    — the first gate elf_lite_load checks after bounds)
  - `t->user_pml4_pa @ 16 == old_pml4` (unchanged — rollback)
  - `t->pid @ 0 == pre_call_pid` (unchanged)
  - `t->state @ 8 == pre_call_state` (unchanged)

Both sub-tests emit a single joint marker `R15 SYS EXECVE OK\n`
on success.

### 4.2 Witness storage

- **Sub-test A payload:** reuse `_shell_bin_start` /
  `_shell_bin_end` (embedded via `tools/userbin_embed.S`).
  Already validated by the loader runtime witness — proves the
  embed is a well-formed ELF64.
- **Sub-test B payload:** NEW 64-byte rodata stub in
  `tools/boot_stub.S`. Contains deliberately-bad bytes:

  ```
  # R15-M6-004 (#555): sys_execve witness — bad-ELF stub for rollback test.
  # 64 bytes; first 4 bytes deliberately NOT \x7fELF.
  .global _bad_elf_stub_start
  .align 8
  _bad_elf_stub_start:
      .byte 0xDE, 0xAD, 0xBE, 0xEF     # bad magic (offset 0-3)
      .byte 0x02, 0x01, 0x01, 0x00     # class/endian/version/pad
      .fill 56, 1, 0                    # 56 zero bytes to reach 64
  .global _bad_elf_stub_end
  _bad_elf_stub_end:
  ```

- **Tasks constructed:** two — sub-test A parent (t_a),
  sub-test B parent (t_b). Both via `task_new(NULL)`. Pids
  assigned by dense-low-first pid_alloc after prior witnesses
  (sys_exit consumed pids 4-7; sys_wait consumed pids 8-11 with
  pid 9 reaped; so t_a = pid 9 [reused after wait's reap] or
  pid 12 depending on ordering; t_b = next available).

**MAX_PIDS budget.** _task_pool holds 64 slots. Post-witness
occupancy: ~13 slots. Well within budget.

### 4.3 Witness assembly

Placement: inside `boot_continue_after_ring3` immediately after
`sys_wait_witness_exit` label (line 929) and before the GS_BASE
setup (line 932).

```asm
; ============================================================
; R15-M6-004 (#555): sys_execve witness — 2 sub-tests, 1 marker
; ============================================================
sys_execve_witness:
    ; ---------- Sub-test A: valid ELF, success + swap ----------
    ; t_a = task_new(NULL) — provides a live user_pml4_pa @ 16
    xor rdi, rdi;
    call task_new;
    cmp rax, 0;
    je  sys_execve_witness_fail;
    mov r12, rax;                                ; r12 = t_a slab

    ; Save t_a->user_pml4_pa (old_pml4), pid, state for later compare
    mov rax, [r12 + 16];
    mov r13, rax;                                ; r13 = old_pml4
    mov eax, [r12 + 0];
    mov r14d, eax;                               ; r14 = t_a->pid (u32)
    mov eax, [r12 + 8];
    mov r15d, eax;                               ; r15 = t_a->state (u32)

    ; sys_execve_body(t_a, _shell_bin_start, image_len)
    mov rdi, r12;
    lea rsi, [rip + _shell_bin_start];
    lea rax, [rip + _shell_bin_end];
    sub rax, rsi;                                ; rax = image_len
    mov rdx, rax;
    call sys_execve_body;

    ; Assert: rax == 0 (ELF_OK)
    cmp rax, 0;
    jne sys_execve_witness_fail;

    ; Assert: rdx == *(u64 *)(_shell_bin_start + 24) (ELF e_entry)
    lea rcx, [rip + _shell_bin_start];
    mov rax, [rcx + 24];                         ; expected entry_rip
    cmp rdx, rax;
    jne sys_execve_witness_fail;

    ; Assert: t_a->user_pml4_pa != old_pml4 (swap happened)
    mov rax, [r12 + 16];
    cmp rax, r13;
    je  sys_execve_witness_fail;

    ; Assert: t_a->pid unchanged
    mov eax, [r12 + 0];
    cmp eax, r14d;
    jne sys_execve_witness_fail;

    ; Assert: t_a->state unchanged
    mov eax, [r12 + 8];
    cmp eax, r15d;
    jne sys_execve_witness_fail;

    ; ---------- Sub-test B: invalid ELF, rollback ----------
    ; t_b = task_new(NULL) — fresh user_pml4_pa
    xor rdi, rdi;
    call task_new;
    cmp rax, 0;
    je  sys_execve_witness_fail;
    mov r12, rax;                                ; r12 = t_b slab

    ; Save t_b->user_pml4_pa (old_pml4_b), pid, state
    mov rax, [r12 + 16];
    mov r13, rax;                                ; r13 = old_pml4_b
    mov eax, [r12 + 0];
    mov r14d, eax;                               ; r14 = t_b->pid
    mov eax, [r12 + 8];
    mov r15d, eax;                               ; r15 = t_b->state

    ; sys_execve_body(t_b, _bad_elf_stub_start, 64)
    mov rdi, r12;
    lea rsi, [rip + _bad_elf_stub_start];
    mov rdx, 64;
    call sys_execve_body;

    ; Assert: rax != 0 (some error code)
    cmp rax, 0;
    je  sys_execve_witness_fail;

    ; Assert: rax == 0xFFFFFFFF (ELF_BAD_HDR — magic gate rejected the stub)
    mov rcx, 0xFFFFFFFF;
    cmp rax, rcx;
    jne sys_execve_witness_fail;

    ; Assert: t_b->user_pml4_pa == old_pml4_b (unchanged — rollback preserved)
    mov rax, [r12 + 16];
    cmp rax, r13;
    jne sys_execve_witness_fail;

    ; Assert: t_b->pid unchanged
    mov eax, [r12 + 0];
    cmp eax, r14d;
    jne sys_execve_witness_fail;

    ; Assert: t_b->state unchanged
    mov eax, [r12 + 8];
    cmp eax, r15d;
    jne sys_execve_witness_fail;

    ; ---------- All checks green ----------
    lea rdi, [rip + sys_execve_witness_ok_msg];
    call uart_puts;
    jmp sys_execve_witness_exit;

sys_execve_witness_fail:
    lea rdi, [rip + sys_execve_witness_fail_msg];
    call uart_puts;

sys_execve_witness_exit:
```

**Rodata strings (added to `tools/boot_stub.S`):**

```
# R15-M6-004 (#555): sys_execve witness success message
.global sys_execve_witness_ok_msg
.align 8
sys_execve_witness_ok_msg: .ascii "R15 SYS EXECVE OK\n\0"

# R15-M6-004 (#555): sys_execve witness failure message
.global sys_execve_witness_fail_msg
.align 8
sys_execve_witness_fail_msg: .ascii "R15 SYS EXECVE FAIL\n\0"

# R15-M6-004 (#555): sys_execve witness — bad-ELF payload for sub-test B.
# 64 bytes; first 4 bytes deliberately NOT \x7fELF, so elf_lite_load
# rejects at the magic gate (returns ELF_BAD_HDR = 0xFFFFFFFF).
.global _bad_elf_stub_start
.align 8
_bad_elf_stub_start:
    .byte 0xDE, 0xAD, 0xBE, 0xEF
    .byte 0x02, 0x01, 0x01, 0x00
    .fill 56, 1, 0
.global _bad_elf_stub_end
_bad_elf_stub_end:
```

### 4.4 What the ten assertions prove

Sub-test A (valid ELF, success + swap):

1. **rax == 0.** elf_lite_load returned ELF_OK; commit path
   ran fully.
2. **rdx == e_entry.** Step 4's `mov rdx, [r12 + 24]` loaded the
   correct u64 field from the ELF header.
3. **user_pml4_pa != old.** Step 4's commit store
   `mov [rbx + 16], r15` executed; the swap took effect.
4. **pid unchanged.** No write to offset 0 anywhere in the body.
5. **state unchanged.** No write to offset 8 anywhere in the body.

Together these prove the success path: load succeeded, e_entry
correctly extracted, swap committed, POSIX-preserved fields
untouched.

Sub-test B (invalid ELF, rollback):

6. **rax != 0.** Some error code path executed.
7. **rax == 0xFFFFFFFF (ELF_BAD_HDR).** The specific error
   from elf_lite_load's magic gate — confirms elf_lite_load
   was called AND rejected the stub AND the rejection code
   propagated through step 5's rollback correctly.
8. **user_pml4_pa == old.** Step 4's commit store did NOT
   execute; rollback path was taken; original pml4 retained.
9. **pid unchanged.** Body doesn't touch offset 0 on either path.
10. **state unchanged.** Body doesn't touch offset 8 on either path.

Together these prove the rollback path: bad ELF rejected,
original aspace preserved, no partial commit.

Combined: 10 field-level assertions on 2 tasks. Covers the
commit path (rax=0 sync) and the rollback path (rax=error).

### 4.5 Fingerprint additions

Marker line appended to three fingerprint files (contains-in-order):

`tests/r15/expected-boot-r15-process.txt`:

```diff
 R15 SYS EXIT OK
 R15 SYS WAIT OK
+R15 SYS EXECVE OK
 IPI OK
```

`tests/r15/expected-boot-r15-ring3.txt`:

```diff
 R15 SYS EXIT OK
 R15 SYS WAIT OK
+R15 SYS EXECVE OK
 IPI OK
```

`tests/r14b/expected-boot-r14b-loader.txt`:

```diff
 R15 SYS EXIT OK
 R15 SYS WAIT OK
+R15 SYS EXECVE OK
 LOADER OK
```

The other 5 fingerprint files (`boot_r8_only`, `boot_r10`,
`boot_r11`, `boot_r12`, `boot_r12_denial`) do **not** need
editing — their scope is pre-R15 substrate; contains-in-order
matching stays byte-identically green.

### 4.6 What the witness does NOT test (deferred)

- **Syscall wrapper.** The `sys_execve` dispatch slot at
  `dispatch.pdx:11` still routes to ENOSYS. Wire-up requires
  cpu_local_current_task + iretq-frame construction + CR3
  swap — deferred.
- **Actually running the shell.** The witness proves the
  aspace is swapped and entry_rip extracted correctly, but
  does NOT iretq into ring-3 with CR3 = new_pml4. That
  requires the wrapper's iretq machinery (deferred). r15-m6-009
  fork+execve+wait smoke is where the end-to-end run happens.
- **Rollback under mid-load OOM.** Sub-test B fails at the
  magic gate (earliest possible rejection). Rollback under
  a *partial* mapping (elf_lite_load returned ELF_MAP_ERR
  after mapping some pages) is a more strenuous test. The
  rollback path is code-identical (aspace_teardown on the
  partial aspace), but coverage would benefit from a
  sub-test B' where elf_lite_load is coaxed into ELF_OOM
  mid-load. Physical exhaustion is hard to arrange
  deterministically at witness time; punt to r15-m6-009.
- **Concurrent execve / exit / wait.** SMP-only concern.
- **fd_table survival verification.** The body doesn't touch
  fd_table at offset 168, so it survives by omission. A
  dedicated assertion would check `[t + 168] == pre_call_val`;
  omitted here because task_new zeroes fd_table (rep stosq)
  and the body never writes past offset 16. Adds no signal.
- **Aspace leak measurement.** The 4-KiB PML4-root leak per
  exec is documented in §3.7; witnesses don't assert it (it's
  a memory metric, not a functional one).

## 5. LOC estimate

| File                                                              | LOC delta |
|-------------------------------------------------------------------|-----------|
| `src/kernel/core/syscall/handlers/sys_execve.pdx` (NEW)           | +75       |
| `src/kernel/boot/kernel_main.pdx` (witness block)                 | +110      |
| `tools/boot_stub.S` (2 rodata strings + bad-ELF stub)             | +20       |
| `tests/r15/expected-boot-r15-process.txt`                         | +1        |
| `tests/r15/expected-boot-r15-ring3.txt`                           | +1        |
| `tests/r14b/expected-boot-r14b-loader.txt`                        | +1        |
| `design/kernel/r15-m6-004-sys-execve.md` (this doc)               | +700      |
| **Total**                                                         | **~908**  |

Executable code: ~40 asm lines + ~15 constants/scaffolding in
`sys_execve.pdx` = ~75 LOC. Witness: ~100 asm lines + ~10 rodata
refs = ~110 LOC in `kernel_main.pdx`. Boot_stub rodata: ~20 LOC
(2 strings + 64-byte bad-ELF stub with symbol brackets).
Fingerprint: ~3 LOC. Design: ~700 LOC.

Same order of magnitude as #556 (~881 LOC total) and #557
(~736 LOC total). Well within R15.M6 per-issue budget.

## 6. Backtrack candidates

Ordered by preference.

### 6.1 Backtrack A — Land sys_execve wrapper with the body

Rather than splitting `sys_execve_body` and leaving `dispatch.pdx`
at ENOSYS, implement the full wrapper this issue:

```
sys_execve(image_ptr, image_len):
    current = cpu_local_get()->current_task
    {rc, entry_rip} = sys_execve_body(current, image_ptr, image_len)
    if rc != 0: return rc                           // failure → sysret with -errno
    initial_rsp = user_stack_alloc(current->user_pml4_pa)
    if initial_rsp == 0: sys_exit(-1)               // stack OOM → fatal
    iretq_frame = {cs=USER_CS, ss=USER_SS, rflags=0x200,
                   rip=entry_rip, rsp=initial_rsp}
    load CR3 = current->user_pml4_pa
    iretq                                            // never returns
```

**Consequence.** Requires:
- `cpu_local_get()->current_task` accessor (~10 LOC in `cpu/local.pdx`)
- `user_stack_alloc(pml4_pa)` — LANDED (`core/mm/user_stack.pdx`).
- iretq-frame writer + CR3 load helper — deferred infrastructure.

Net: couples this issue's landing to two currently-absent
primitives (accessor + iretq helper). Defeats independent
testability.

**Reject as primary.** Retain as backtrack once the accessor
lands. The dispatch.pdx edit is then a 5-line replacement of the
ENOSYS route.

### 6.2 Backtrack B — Full aspace teardown incl. root PML4 frame

Replace `aspace_teardown(pml4)` with
`aspace_teardown_full(pml4)` that additionally does
`phys_free(pml4, 0)` at the end.

**Consequence.**
- Eliminates the 4-KiB PML4-root leak.
- Requires a new function OR modification of `aspace_teardown`
  (substrate change).
- The PML4 frame allocation was done via
  `aspace_create_user_pgd` which called `phys_alloc(order=0)`;
  `phys_free(pml4, 0)` is the exact inverse. #649 landed the
  real phys_free body, so the call is safe.

**Reject as primary** because the leak fits within the R14b
memory budget (§3.7). **Prefer as follow-up** once R15.M6 is
closed and phys_free's frame-metadata audit (#559 frame_meta
LANDED) confirms the free is idempotent.

### 6.3 Backtrack C — In-body fd_close_cloexec (when R16.M3 adds flags)

Insert `fd_close_cloexec(current)` between step 3 (elf_lite_load
success) and step 4 (commit swap). Needs a `fd_close_cloexec`
that iterates the 32 fd slots and closes those with the CLOEXEC
flag set.

**Consequence.** Requires the R16.M3 `fd_entry` schema with a
flags word. Vacuous at R15.M6 (no fd carries CLOEXEC). Backtrack
insertion point: step 3.5 (after successful load, before commit).

**Retain for R16.M3.** Not blocking for #555.

### 6.4 Backtrack D — Return {rax, rdx, rcx} for initial_rsp

Have the body also allocate the user stack (call
`user_stack_alloc(new_pml4)` at step 3.5) and return
`{rax=0, rdx=entry_rip, rcx=initial_rsp}` on success.

**Consequence.**
- Wrapper is simpler (one primitive call, no user_stack_alloc
  in wrapper).
- Body must handle user_stack_alloc failure (add another
  rollback branch). Increases body complexity.
- initial_rsp is fundamentally a wrapper concern — it's the
  rsp field of the iretq frame, which is wrapper-owned data.

**Reject.** Keep the body a pure aspace-transform + ELF-load.
User stack allocation is downstream (wrapper's job).

### 6.5 Backtrack E — Path-based execve after VFS lands (R16.M1+)

Once VFS + inode + read primitives land, add
`sys_execve_by_path(current, path_ptr, path_len)`:

```
inode = vfs_lookup(path_ptr, path_len)
image = vfs_read_all(inode)         // kernel buffer
image_ptr, image_len = image.bytes, image.len
return sys_execve_body(current, image_ptr, image_len)
```

**Consequence.** The bytes-based body becomes the shared
substrate for both path-based and blob-based execve. Argv/envp
are a wrapper concern layered on top.

**Prefer as follow-up** once VFS lands. R15.M6's bytes-only
signature is Pareto-adequate for the fork+exec smoke.

### 6.6 Backtrack F — Body inline in dispatch.pdx

Same as #557 §6.6 and #556 §6.6 — reject for the same reason
(per-syscall handler discipline; the tactical plan §Subsystem 9
issue 4 explicitly names `handlers/sys_execve.pdx`).

### 6.7 Backtrack G — Keep old aspace as fallback until wrapper commits

Delay the commit store `[rbx + 16] = new_pml4` and the
teardown of old_pml4 to the wrapper (post-body). The body
returns `{rc, entry_rip, new_pml4_ptr}`; wrapper decides
when to swap.

**Consequence.**
- Wrapper gains flexibility (e.g., abort the exec if
  user_stack_alloc fails post-body).
- Body no longer touches `current->user_pml4_pa` — the swap
  is deferred to the wrapper.
- On wrapper-side abort, the body's fresh aspace leaks (no
  automatic rollback).

**Neutral.** Trades body simplicity (fewer stores) for wrapper
complexity (must handle abort-cleanup). Choose based on
wrapper design when it lands. Retained as a design option.

### 6.8 Backtrack H — argv/envp copy-in at body level

Extend the body signature to `(current, image_ptr, image_len,
argv_ptr, argc, envp_ptr, envc)` and have the body:
- copy_from_user argv/envp into kernel buffers
- call user_stack_alloc(new_pml4)
- write argv/envp/auxv onto the new stack
- return {rc, entry_rip, initial_rsp}

**Reject.** Fundamentally a wrapper concern (copy_from_user is
a userspace-boundary operation; user_stack_alloc is a wrapper
resource). Deferred to wrapper landing.

## 7. Tractability

**HIGH.**

- No new paideia-as encoder gap — every mnemonic mapped to an
  existing precedent (#548 task_new, #556/#557 sys_wait/sys_exit,
  elf_lite_load).
- Three-to-five nested calls (aspace_create_user, elf_lite_load,
  aspace_teardown x1-2 depending on branch); 5-push prologue
  matches elf_lite_load discipline.
- Body is ~40 asm lines; witness is ~100 asm lines. Same tempo
  as #556 (~135 asm total) and #557 (~85 asm total).
- Zero new field offsets — consumes #549 / #557 freeze verbatim.
- Zero new directory — `handlers/` exists per #557.
- Witness driver is real: `task_new` (#548) LANDED, `_pid_table`
  LANDED, `aspace_create_user` (#513) LANDED, `elf_lite_load`
  (#517+#648) LANDED, `aspace_teardown` LANDED. `_shell_bin_start`
  / `_end` LANDED (validates as ELF64 already). No mocks.
- Marker line contains-in-order across three fingerprint files.
- Bad-ELF stub is a 64-byte rodata block with symbol brackets
  — trivial to add to `tools/boot_stub.S` (same class as the
  existing witness message strings).

Known follow-ups (not blockers for #555):

- **R15.M6-001 sched_pick_next** — provides scheduler dispatch
  for the syscall wrapper.
- **Syscall wrapper wire-up** — replace `dispatch.pdx` ENOSYS
  route for slot 59 (sys_execve) with `call sys_execve_body` +
  iretq-frame + CR3 swap. Lives with whichever issue exposes
  cpu_local_current_task first (likely paired with sys_exit /
  sys_wait wrapper landing).
- **Backtrack B (§6.2)** — full-teardown promotion to close
  the PML4-root leak. File as follow-up.
- **VFS + path-based execve (§6.5)** — R16.M1+ layer atop this
  body.
- **R15.M6-009 fork/exec/wait smoke** — end-to-end validation
  that this body's design shape holds up under
  fork → child_execve(shell) → child_run → child_exit →
  parent_wait.

## 8. Cross-cutting risks

- **AC "fds released" (from #557 sys_exit) vs. "fds preserved
  across exec" (this issue) interpretation.** These are
  compatible: exec preserves; exit closes. This body's
  no-op-on-fd_table policy is correct per POSIX. Mitigation:
  §1 point 2 and §Scope out-of-scope point 6 pin the "vacuous
  no-op at R15.M5, real work at R16.M3" contract.
- **Old-pml4 aliasing after commit swap.** Between the u64
  store `[rbx + 16] = new_pml4` and the `aspace_teardown(old)`
  call, if an interrupt fired that ran a scheduler pick + CR3
  swap on `current`, the CPU could load CR3 = old_pml4 which
  is about to be torn down. At R15.M6 single-CPU with the body
  running under IRQ-disabled (enforced by the syscall entry
  path per #557 §3.6), no interrupt fires inside the body.
  Mitigation: body runs with IRQs disabled; wrapper must
  preserve this discipline. Flagged in the justification
  string.
- **Kernel-space vs. userspace image_ptr.** This body accepts a
  kernel-space pointer (e.g., `_shell_bin_start`). If the
  wrapper eventually accepts userspace `image_ptr`, it must
  copy_from_user into a kernel buffer BEFORE calling
  sys_execve_body. Backtrack E (§6.5) is where this pipe
  gets built. Mitigation: body signature is kernel-only;
  wrapper adds the copy_from_user layer.
- **elf_lite_load leaves partial mappings on failure.** The
  body relies on `aspace_teardown` walking the partial
  aspace and freeing what elf_lite_load already mapped.
  aspace_teardown's U-bit gating means only USER-mapped
  leaves get freed (correct: elf_lite_load produces U-bit-set
  PTEs). Intermediate PT/PD/PDPT frames are freed unconditionally
  by aspace_teardown. Mitigation: teardown-then-load loops
  through the entire allocated tree; no leak beyond the root
  PML4 frame (§3.7).
- **`aspace_teardown` on empty aspace is safe.** After
  `aspace_create_user` returns a fresh (empty) pml4 and BEFORE
  elf_lite_load runs, if elf_lite_load fails at header
  validation (never mapped anything), the rollback path calls
  `aspace_teardown(new_pml4)` on a fresh, empty aspace. Walk
  finds no PRESENT entries; no phys_free calls; returns 0.
  Mitigation: verified by inspection of aspace_teardown.pdx
  §3-83 (loop skips !PRESENT entries via `and rcx, 1; jz next`).
  No risk.
- **State enum discrepancy (from #557 §3.4).** sys_execve_body
  does NOT read or write state. Vacuous risk.
- **Register clobber across nested calls.** 5-push prologue
  matches elf_lite_load's own 5-push discipline. All 5
  callee-save regs (rbx, r12, r13, r14, r15) held live across
  5 nested-call sites. Recent post-mortems (`f6195ed`,
  `3e6a550`) confirm this discipline works when applied.
  Mitigation: §3.6 audit + witness-driven end-to-end proof
  (sub-test A validates the r13→e_entry chain, which depends
  on r12 surviving elf_lite_load).
- **Compact pid↔slab mapping.** Body touches only
  `current->user_pml4_pa @ 16`; does NOT touch pid_table.
  Vacuous risk.
- **Fingerprint drift.** Same discipline as #557 / #556 —
  pre-push hook blocks smoke-negative pushes.
- **Bad-ELF stub magic alignment.** The stub's `\xDE\xAD\xBE\xEF`
  first 4 bytes are little-endian 0xEFBEADDE, which is NOT
  0x464C457F (\x7fELF). elf_lite_load's magic gate rejects
  with ELF_BAD_HDR. Mitigation: sub-test B expects
  0xFFFFFFFF (ELF_BAD_HDR), which is the byte pattern the
  magic gate returns. Verified against elf_lite.pdx:47.
- **`_bad_elf_stub_start` symbol availability at witness
  time.** The stub is defined in `tools/boot_stub.S` in the
  `.rodata` section (default from `.byte`/`.fill` after
  `.section .rodata`). If boot_stub.S organizes its rodata
  differently (e.g., a `.rodata.witnesses` subsection), the
  symbol may not be in the same section as
  `sys_execve_witness_ok_msg`. Mitigation: place the stub
  and its symbols right after `sys_execve_witness_fail_msg`
  in the existing witness-msgs cluster (verified per
  `tools/boot_stub.S:374-392` for the existing
  sys_exit/sys_wait messages).
- **ELF e_entry field @ offset 24 alignment.** The ELF64
  header is 64-byte aligned overall, and e_entry is a u64
  at file offset 24. If the shell.bin embed is 8-byte
  aligned (`.balign 4096` per userbin_embed.S:3), the
  `mov rdx, [r12 + 24]` load is 8-byte aligned. Guaranteed.
  Mitigation: `.balign 4096` on the embed enforces 4096-byte
  alignment (stronger than needed).

## 9. Backtrack markers

For the debugger-agent if the witness reports FAIL:

| Symptom                                          | Root cause hypothesis                                    | Where to look                                              |
|--------------------------------------------------|----------------------------------------------------------|------------------------------------------------------------|
| Sub-test A: rax != 0                             | elf_lite_load rejected shell.bin (unlikely; loader witness passes) | Verify _shell_bin_start actually contains ELF64        |
| Sub-test A: rdx != e_entry                       | Step 4 e_entry load offset wrong OR image_ptr clobbered  | Verify `mov rdx, [r12 + 24]`; check r12 preservation      |
| Sub-test A: user_pml4_pa unchanged               | Commit store never executed OR wrong offset              | Verify `mov [rbx + 16], r15` on success branch             |
| Sub-test A: pid or state changed                 | Bug: body wrote to offset 0 or 8                         | Grep for any `mov [rbx + 0/8]` — should not exist          |
| Sub-test B: rax == 0                             | Body took success path on bad ELF — elf_lite_load bug OR wrong branch | Verify `cmp rax, 0; jne sys_execve_load_fail`     |
| Sub-test B: rax != 0xFFFFFFFF                    | elf_lite_load returned a different error OR rollback clobbered rax | Verify `mov rax, r14` in rollback restores rc         |
| Sub-test B: user_pml4_pa changed                 | Rollback path took the commit store — control-flow bug   | Verify `sys_execve_load_fail` jump target NEVER falls through to step 4 |
| Silent hang, no OK/FAIL                          | task_new returned 0 (pid exhaustion) OR body clobbered rip / stack corruption | Check pool occupancy; verify 5-push prologue balance |
| Fingerprint mismatch, R15 SYS EXECVE OK missing  | Marker not emitted; sub-test failed silently             | Check jmp targets around sys_execve_witness_exit          |
| Fingerprint mismatch, extra line before marker   | Wrong witness block ordering                             | Verify witness sits after sys_wait_witness_exit           |
| Stack imbalance / crash post-return              | Prologue/epilogue push/pop count mismatch                | Count pushes (5) vs. pops (5); verify order matches       |

## 10. References

- Issue: paideia-os#555
- Milestone: paideia-os milestones/62 (R15.M6 fork / exec / wait / _exit)
- Sibling issues in R15.M6:
  - #552 (aspace_clone_cow), #553 (pf_handler_cow_split)
  - #554 (sys_fork), #556 (sys_wait — LANDED), #557 (sys_exit — LANDED)
  - #558 (orphan adoption), #559 (frame_meta refcount — LANDED)
  - #560 (fork/exec/wait smoke)
- Landed prereqs:
  - #548 task_new (`src/kernel/core/sched/task_pool.pdx:71`)
  - #549 fd_table + task_struct field freeze
    (`src/kernel/core/fs/fd_table.pdx`)
  - #513 aspace_create_user (`src/kernel/core/mm/aspace_create.pdx:96`)
  - #517 elf_lite_load (`src/kernel/core/loader/elf_lite.pdx:205`)
  - #648 elf_lite_load runtime bugs (W^X mask, HIGH_HALF, order)
  - #557 sys_exit_body (`src/kernel/core/syscall/handlers/sys_exit.pdx`)
  - #556 sys_wait_body (`src/kernel/core/syscall/handlers/sys_wait.pdx`)
  - aspace_teardown (`src/kernel/core/mm/aspace_teardown.pdx:14`)
  - #649 phys_free real body
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 9 issue 4 (sys_execve entry)
- Master plan: `design/milestones/r14b-master-plan.md`
  §R15.M6 fork/exec/wait/_exit
- Prior-art register-discipline post-mortems:
  - `f6195ed` (phys_alloc callee-save fix)
  - `3e6a550` (self-IPI callee-save audit)
- Prior-art witness pattern:
  - `design/kernel/r15-m6-006-sys-exit.md` §4 (2 sub-tests)
  - `design/kernel/r15-m6-005-sys-wait.md` §4 (3 sub-tests)
  - `design/kernel/r15-m1-008b-elf-lite-load-runtime-bugs.md` §4
    (runtime loader witness — precedent for using shell.bin)
- Prior-art fingerprint discipline:
  - `design/kernel/r15-m5-007-fd-table-embed.md` §4.3
    (contains-in-order marker addition)
- Prior-art rodata addition to boot_stub.S:
  - `tools/boot_stub.S:374-392` (sys_exit / sys_wait witness msgs)
- ELF64 specification:
  - `Elf64_Ehdr` struct — e_entry at offset 24, e_phoff at
    offset 32, e_phnum at offset 56, e_phentsize at offset 54.
- paideia-as encoder audits:
  - `tools/paideia-as/tests/build-emit/mov_mem_imm_sib_disp.pdx`
    (SIB+disp32 store; r12-as-base requires SIB byte)
  - elf_lite_load's own encoding as precedent for r12-r15
    heavy usage under prologue push discipline
