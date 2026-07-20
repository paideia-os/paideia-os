---
issue: 620
milestone: R17.M2 (init process)
subsystem: 17 — init process
tier: 1 (structural)
runtime-blocked-on:
  - "#665 — path_resolve/vfs_open conflate vnode-pool indices with backend-native inode indices"
  - "#668 — syscall dispatch table stale post-SC+ freeze (routes ID 0 to legacy exit_thread stub)"
  - "#662 — LAPIC timer never delivers vector 32 in current R15 boot sequence"
prereq:
  - "#548 (task_new — LANDED, src/kernel/core/sched/task_pool.pdx)"
  - "#517 (elf_lite_load — LANDED, src/kernel/core/loader/elf_lite.pdx)"
  - "#651/#652 (enter_userland_initial — LANDED, exercised by ring-3 hello witness)"
  - "#616..#619 (init source + linker + fds + fork/exec + wait — LANDED)"
  - "#519 (userbin_embed.S — LANDED, embeds shell.elf via .incbin)"
touching:
  - tools/userbin_embed.S                              (extend: +2 symbols, +1 .incbin line)
  - src/kernel/boot/kernel_main.pdx                    (extend: init_bootstrap witness block)
  - tools/run-smoke.sh                                 (extend: boot_r17_init dispatcher entry)
  - tests/r17/expected-boot-r17-init.txt               (new: fingerprint file for structural mode)
  - design/kernel/r17-m2-005-kernel-launch-init.md    (this doc)
related:
  - design/kernel/r17-m2-001-init-source-and-linker.md (init.pdx + init.ld)
  - design/kernel/r17-m2-004-init-wait-respawn.md      (init program's wait/exit surface)
  - design/kernel/r15-m2-006b-boot-r15-ring3-hello.md  (ring-3 entry pattern this doc mirrors)
---

# R17-M2-005 — kernel_main launches init (#620)

## 1. Scope and posture

### 1.1 Charter (from issue #620)

> kernel_main, after all subsystems init, task_new(init), load init.bin into
> it, enter_userland_initial with init's entry.
>
> Acceptance: `boot_r17_init` mode boots to init, which forks shell.

### 1.2 Two-tier decomposition

Full runtime acceptance ("init boots, forks shell, shell reaches its prompt")
is **blocked** by three known-open defects:

- **#665** — vfs_open uses vnode-pool indices where backend-native inode
  indices are required. init's first syscall (`sys_open("/dev/tty0", ...)`)
  is exactly the affected path.
- **#668** — the SC+ freeze left the syscall dispatch table stale; ID 0 now
  routes to a legacy `exit_thread` stub. Since init's `sys_open` maps to
  the ID that #668 corrupted, even a byte-perfect init image cannot make
  progress past its first syscall.
- **#662** — the LAPIC timer never delivers vector 32 in the current R15
  boot sequence. init's `sys_wait4` blocks the parent indefinitely; without
  a live timer, the scheduler cannot preempt to the child (shell).

Rather than defer the entire issue until those three land, this design
splits it into two independently-shippable tiers, matching the pattern
already used at R15-M1-008 (structural loader witness) → R15-M1-008b
(runtime loader witness):

| Tier | Scope                                                                                 | Blocking prereqs               |
| ---- | ------------------------------------------------------------------------------------- | ------------------------------ |
| 1    | Structural: embed init.elf; task_new + elf_lite_load + entry-rip capture at boot     | none — implementable today     |
| 2    | Runtime: enter_userland_initial into init entry; init survives its first sys_open    | #665 + #668 + #662             |

**This document specifies Tier 1** and cites Tier 2 as a follow-up. The
`boot_r17_init` smoke mode verifies Tier 1's structural witness marker
(`R17 INIT LOAD OK`). Tier 2 will replace that marker check with a
runtime observation (`INIT OK` printed by the running init program) once
the three blockers land.

This posture is consistent with the honest-scope discipline the R14B
tactical plan repeatedly documents (§loader RUNTIME witness at
kernel_main.pdx:5499, §IPI structural witness at 5453) — structural
readiness now, runtime readiness once the substrate is honest.

## 2. Prereq audit

### 2.1 In place

| Component                | Symbol / Location                                                       | Evidence                                                         |
| ------------------------ | ----------------------------------------------------------------------- | ---------------------------------------------------------------- |
| task_new                 | `src/kernel/core/sched/task_pool.pdx:71`                                 | 7-step construction; exercised at kernel_main.pdx:957            |
| aspace_create_user       | called inside task_new (step 4)                                         | Returns pml4_pa; written to slab @ +16                           |
| elf_lite_load            | `src/kernel/core/loader/elf_lite.pdx:205`                                | Exercised at kernel_main.pdx:5516 (RUNTIME witness on shell.elf) |
| enter_userland_initial   | `.text.syscall_trampoline`                                              | Exercised at kernel_main.pdx:851 (ring-3 hello witness)          |
| userbin_embed.S          | `tools/userbin_embed.S`                                                  | Currently embeds `shell.elf` as `_shell_bin_start/_shell_bin_end` |
| .rodata.userbin section  | `src/kernel/link.ld:73`                                                  | `_shell_bin_section_start/_shell_bin_section_end`, 4KiB-aligned  |
| init.elf artifact        | `build/user/init.elf` (produced by `tools/build-user.sh`)               | 6256 bytes; init.bin (raw) 640 bytes                             |

### 2.2 Not in scope for Tier 1

- **enter_userland_initial → init entry.** Depends on Tier 2. Structural
  tier stops at "task allocated, ELF loaded, entry_rip captured."
- **pid_reset before init construction.** The existing witness cascade
  in `boot_continue_after_ring3` already consumes pids 1..11+ from
  `_pid_table`. Init would land at whatever pid is next free; that is
  fine for a structural witness but inconsistent with POSIX ("init is
  pid 1"). Explicit `pid_reset()` (or moving init_bootstrap earlier)
  is deferred to Tier 2, where init actually runs — see §5.2.
- **Fork/execve of shell from init.** init has this logic (issue #618,
  init.pdx:47-68) but it can only execute in Tier 2.

## 3. Design — Tier 1 (structural)

### 3.1 Embed init.elf alongside shell.elf

The existing `_shell_bin_start`/`_shell_bin_end` pattern is a page-aligned
`.incbin` inside `.rodata.userbin` (see `src/kernel/link.ld:73-78`). init.elf
follows verbatim.

**tools/userbin_embed.S** (delta):

```
# R15-M1-007 (#519): Embed user shell binary into kernel .rodata.userbin.
# R17-M2-005 (#620): Embed init binary alongside shell.
.section .rodata.userbin, "a", @progbits
.balign 4096
.global _shell_bin_start
_shell_bin_start:
.incbin "build/user/shell.elf"
.global _shell_bin_end
_shell_bin_end:
.balign 4096
.global _init_bin_start
_init_bin_start:
.incbin "build/user/init.elf"
.global _init_bin_end
_init_bin_end:
.balign 4096
```

**Why init.elf, not init.bin.** Despite the "_bin_" naming (a historical
misnomer inherited from R15-M1-007), the file being embedded is the full
ELF64 executable produced by `ld -T init.ld`. That is what `elf_lite_load`
requires — a real ELF header at offset 0 with `e_phoff`, `e_phnum`, and
loadable program headers. `init.bin` (from `objcopy -O binary`) is a
raw text/data flat blob with no ELF headers; feeding it to `elf_lite_load`
would fail at the magic gate (`0x464C457F`, elf_lite.pdx:229). Symbol name
retained as `_init_bin_start` for parity with `_shell_bin_start`.

**Size and section budget.** Current sizes:

- shell.elf: 6368 bytes
- init.elf:  6256 bytes
- Sum with page-align padding: three 4KiB pages worst-case (`shell` + gap
  + `init` + gap).

The `.rodata.userbin` section carries no other content and is not
size-bounded by any kernel invariant; growth to 12 KiB is a rounding
error against the kernel's total image size (currently ~150+ KiB). No
link.ld change required — the existing `KEEP(*(.rodata.userbin))` glob
picks up both symbols. The `_shell_bin_section_end` marker (link.ld:76)
continues to bracket the whole section, both blobs included; no witness
depends on it being shell-only.

### 3.2 init_bootstrap witness block

Insert at end of `boot_continue_after_ring3`, just before the R14b-m5-002
`wrmsr` GS_BASE setup at kernel_main.pdx:5053 — i.e., after the
`libc_test_witness_done` label (line 5051) and before `lea rax, [rip +
_cpu_locals]` (line 5054). Rationale for placement:

- **After** every witness that depends on a fresh pid pool (pool witness,
  sys_exit, sys_wait, sys_execve, sys_fork, orphan-adopt, fd witnesses,
  etc.) — those already own pids 1..N and would be perturbed by an
  earlier init construction.
- **Before** the scheduler bootstrap into Task A (line ~5543
  `sched_init_runqueue_r10` / `_current_tcb` set / `sti` / `task_a_entry`),
  so a future Tier 2 patch can hoist Task A's role over to the real init
  task with a single-line swap (`_current_tcb ← init_task_slab`).

**Pseudocode (paideia-as-shaped, mirrors line 5499-5528 loader RUNTIME witness):**

```
      // ============================================================
      // R17-M2-005 (#620): init_bootstrap — structural witness.
      //
      // Tier 1 scope: task_new(NULL) → elf_lite_load(init.elf) →
      // capture e_entry → emit R17 INIT LOAD OK.
      //
      // Tier 2 (blocked on #665, #668, #662): enter_userland_initial
      // with (entry_rip=e_entry, initial_rsp=user_stack_top, cr3=user_pml4).
      // ============================================================
      init_bootstrap_witness:
          // Step 1: allocate init task_struct (fresh user aspace inside).
          xor rdi, rdi;                     // parent = NULL
          call task_new;
          cmp rax, 0;
          je  init_bootstrap_fail;
          mov r12, rax;                     // r12 = init task slab

          // Step 2: load init.elf into init's aspace.
          mov rdi, [r12 + 16];              // rdi = init->user_pml4_pa (VA-form, per #652)
          lea rsi, [rip + _init_bin_start];
          lea rax, [rip + _init_bin_end];
          sub rax, rsi;
          mov rdx, rax;                     // rdx = image_len
          call elf_lite_load;               // rax = ELF_OK (0) or error code
          cmp rax, 0;
          jne init_bootstrap_fail;

          // Step 3: extract e_entry (u64 @ ELF header offset 24) and stash
          // it in the task slab at a well-known offset for Tier 2 pickup.
          // For Tier 1 we only *witness* that the read succeeds.
          lea rax, [rip + _init_bin_start];
          mov rax, [rax + 24];              // ELF64 e_entry
          cmp rax, 0;
          je  init_bootstrap_fail;          // guard: entry must be non-zero
          mov [r12 + INIT_ENTRY_OFF], rax;  // stash for Tier 2 (see §3.3)

          // Step 4: publish init's slab pointer to _init_task for Tier 2.
          lea rcx, [rip + _init_task];
          mov [rcx], r12;

          lea rdi, [rip + init_load_ok_msg];
          call uart_puts;
          jmp init_bootstrap_done;

      init_bootstrap_fail:
          lea rdi, [rip + init_load_fail_msg];
          call uart_puts;

      init_bootstrap_done:
```

**Emitted marker string** (add to Rodata block in kernel_main.pdx tail):

```
  pub let init_load_ok_msg   : [u8; 18] = "R17 INIT LOAD OK\n\0"
  pub let init_load_fail_msg : [u8; 20] = "R17 INIT LOAD FAIL\n\0"
```

### 3.3 New global for Tier 2 hand-off

Add two `.bss` slots that let Tier 2 pick up where Tier 1 left off
without re-running `task_new` + `elf_lite_load`:

```
  // R17-M2-005 (#620): published by init_bootstrap for Tier 2 pickup.
  pub let mut _init_task : u64 = 0            // slab pointer to init task_struct
```

For Tier 2, `_init_task` is loaded, its `user_pml4_pa` extracted, its
stashed entry_rip extracted, a fresh user stack mapped, and
`enter_userland_initial(entry, rsp, cr3_pa)` is called — exactly mirroring
the ring-3 hello witness at kernel_main.pdx:837-851 but with a real ELF
entry instead of a hand-written `0x0F 0x0B 0xF4` (ud2/hlt) sled.

**INIT_ENTRY_OFF selection.** task_struct has 278 u64s (2224 bytes) per
task_pool.pdx:16. Field allocation as pinned by #548, #549, #557, #556:

- +0..4:  pid (u32), parent_pid (u32)
- +8..12: state (u32), exit_status (u32)
- +16:    user_pml4_pa (u64)
- +24..152: fd_table[0..15] (16 × u64) — sys_open/close write here
- +168..296: fd_table[16..31] (16 × u64) — R16.M3 fd_cloexec range
- +1704:  wait_result_pid (u32)
- +1708:  wait_result_status (u32)

Choose **INIT_ENTRY_OFF = 1712** (immediately after the wait_result_status
u32, within the wait-result subgroup, but as its own u64 slot). This is
one of the 278 slots that is currently zero-initialized-and-untouched by
every existing witness. It leaves headroom for future task_struct field
additions in the 1720..2224 range. Document the offset at the task_struct
layout note (`design/kernel/task-struct-layout.md`); Tier 2's contract
will re-read from the same offset.

### 3.4 Failure modes and rollback

| Failure                                    | Detection                            | Behavior                                  |
| ------------------------------------------ | ------------------------------------ | ----------------------------------------- |
| `task_new` returns 0 (pid exhaustion / OOM) | `cmp rax, 0; je init_bootstrap_fail` | Emit `R17 INIT LOAD FAIL`, fall through   |
| `elf_lite_load` returns non-zero error     | `cmp rax, 0; jne init_bootstrap_fail`| Emit `R17 INIT LOAD FAIL`, fall through   |
| `_init_bin_start[24]` (e_entry) reads as 0 | `cmp rax, 0; je init_bootstrap_fail` | Emit `R17 INIT LOAD FAIL`, fall through   |

Failure path leaks: task slab + user aspace remain allocated. This matches
the leak posture of every other structural witness (KPTI, ring3, loader,
IPI); the boot sequence never runs long enough for this to be observable.
Cleaner rollback (`task_free`, `aspace_teardown`) is a Tier 2 concern —
once init actually needs to survive its own bootstrap failure, cleanup
matters; today the immediately-following `hlt` cycle absorbs the leak.

## 4. Test canary — boot_r17_init smoke mode

### 4.1 tools/run-smoke.sh delta

Add a new dispatcher entry mirroring `boot_r15_process` (which was the
last mode requiring a task_new + witness combination):

```
    boot_r17_init)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r17/expected-boot-r17-init.txt"
        TIMEOUT=8
        EXPECTED=""
        ;;
```

Also update the `MODE:` documentation block at the top of the file
(line 5-6) to list `boot_r17_init` in the enumeration, and add the
one-line description `boot_r17_init: validates R17 init load structural
witness (task_new + elf_lite_load), 8s timeout`.

### 4.2 tests/r17/expected-boot-r17-init.txt (new)

Create `tests/r17/` directory. The fingerprint file uses the same
contains-in-order semantics that every other fingerprint uses
(run-smoke.sh:197-211). Contents (each line must appear in order in
the serial log):

```
PaideiaOS R8
KPTI OK
KPTI SCRATCH OK
ENTER USER RELOC OK
R15 RING3 HELLO OK
R15 FD TABLE OK
R15 TASK NEW OK
R15 SYS EXIT OK
R15 SYS WAIT OK
R15 SYS EXECVE OK
R15 ORPHAN ADOPT OK
R15 SYS FORK OK
VFS OK
R16 TMPFS INIT OK
FD OK
UART RX SMOKE OK
TTY SMOKE OK
LIBC TEST OK
R17 INIT LOAD OK
```

(Ordering derived by tracing the ok-message sequence from kernel_main.pdx
lines 264..5043; the last existing marker before init_bootstrap is
`LIBC TEST OK` at line 5043.)

The exact prefix lines are copied from `tests/r15/expected-boot-r15-process.txt`
and extended forward to keep the fingerprint honest — a partial-fingerprint
that only checks `R17 INIT LOAD OK` would pass even if every earlier
witness silently regressed. This matches the "cumulative-log-window"
discipline documented in the LAPIC-follow-up post-mortem for #662.

### 4.3 Deferred runtime canary

Tier 2 will add `boot_r17_init_runtime` (or replace this mode's
fingerprint tail) with the extra line `INIT OK` after `R17 INIT LOAD OK`.
That marker is emitted by init.pdx:54-56 via `sys_debug_puts`, so its
appearance in the serial log is proof init both **loaded** and **executed
its first syscall**.

## 5. Design tension: pid ordering and init-is-pid-1

### 5.1 The tension

POSIX (and every downstream orphan-adoption path in R15.M6.007) assumes
init is pid 1. But `_pid_table` is populated dense-low-first
(pid_alloc, task_pool.pdx:26) and the witness cascade currently
constructs several tasks — `task_new(NULL)` at line 957 alone claims
pid 1, and every subsequent `task_new` claim runs pid 2..N. By the time
init_bootstrap runs (post-libc_test, line 5051), init would be assigned
whatever pid is next free — empirically pid ~12+.

### 5.2 Resolution and deferral

**Tier 1 (this doc):** Accept whatever pid init gets. The structural
witness only asserts "task allocated + ELF loaded"; the pid number is
not part of the assertion.

**Tier 2:** Two clean options, decision deferred to when Tier 2 ships:

- **Option A: pid_reset() before init_bootstrap.** Add a
  `pid_reset()` primitive to task_pool.pdx that zeroes `_pid_table[1..64]`
  and (optionally) reaps every ZOMBIE slab back to fresh. Call it
  immediately before `init_bootstrap_witness`. Preserves witness ordering
  (all runs first, gets torn down together), gives init pid 1. **Cost:**
  requires task_free to not leak; the ZOMBIE-reaping loop touches every
  witness task's slab exactly once.

- **Option B: Move init_bootstrap ahead of every task_new witness.**
  Init runs first (pid 1), then witnesses fill pids 2..N. **Cost:** the
  first-task-new-witness at line 952 loses its "pid == 1" assertion; it
  becomes a "pid == 2" assertion. That is a single-integer edit but
  ripples into pool_witness (which asserts pids 1→2→3 dense-low), so a
  small cascade of witness-integer edits follows.

Option A is preferred for surgical minimality; Option B is preferred if
pid_reset gets challenged as a "test-scaffolding-only" primitive that
shouldn't ship in kernel code. This design does not adjudicate; it
records the choice as pending.

## 6. Files modified (concrete)

| File                                              | Delta                                      | LOC estimate |
| ------------------------------------------------- | ------------------------------------------ | ------------ |
| `tools/userbin_embed.S`                            | +5 lines (init symbols + `.incbin`)         | +5           |
| `src/kernel/boot/kernel_main.pdx`                  | init_bootstrap witness block, rodata, .bss  | +55..70      |
| `tools/run-smoke.sh`                               | new mode dispatch + docstring update        | +8           |
| `tests/r17/expected-boot-r17-init.txt`             | new fingerprint (~20 lines)                 | +20          |
| `design/kernel/r17-m2-005-kernel-launch-init.md`   | this doc                                    | (self)       |
| `design/kernel/task-struct-layout.md`              | note `INIT_ENTRY_OFF = 1712`                | +3           |

**Total code delta: ~90 lines.** No kernel-side allocator, VM, scheduler,
or IPC touch. No new syscall dispatch entries. No link.ld edits.

## 7. Tractability assessment

**Tier 1: HIGH.**

- Every primitive (`task_new`, `elf_lite_load`, `_shell_bin_start`
  pattern) is already exercised at boot; the new witness is a
  copy-and-adjust of the existing loader RUNTIME witness at
  kernel_main.pdx:5499-5528.
- No paideia-as encoder gaps expected — the witness uses only
  `lea` / `mov` / `call` / `cmp` / `je` / `jne` / `jmp` / `xor` /
  `sub`, all of which are exercised by the existing witnesses. The
  8-bit compare bug flagged in #662's secondary-bug section does not
  apply (this witness only compares 64-bit registers).
- Serial-log fingerprint machinery is a pure `run-smoke.sh` case
  statement + new text file; no build-system changes.

**Tier 2: MEDIUM, blocked.**

- `enter_userland_initial` pattern is proven (ring-3 hello witness).
- User stack allocation is proven (ring3 witness at
  kernel_main.pdx:807-825).
- **Blockers must land first:** #665, #668, #662. Trying to Tier-2 before
  those land would regress `boot_r15_ring3` and `boot_r17_init` both
  (init's first `sys_open` would misdispatch, blocking indefinitely).
- Once blockers land, Tier 2 is a ~40-line delta: extend
  `init_bootstrap_witness` past step 4 with user-stack alloc + swap
  `_current_tcb` + `enter_userland_initial(entry, rsp, pml4_pa)` +
  add `INIT OK` to the fingerprint file.

## 8. Acceptance criteria (Tier 1)

1. `boot_r17_init` smoke mode passes: fingerprint sees
   `R17 INIT LOAD OK` after `LIBC TEST OK`.
2. All prior smoke modes (`boot_r8_only`, `boot_r10`, `boot_r11`,
   `boot_r12`, `boot_r12_denial`, `boot_r14b_*`, `boot_r15_ring3`,
   `boot_r15_process`) stay green — the new witness is inert to
   every earlier assertion (dedicated slab, dedicated pid slot,
   dedicated aspace).
3. This design doc present, cited from #620's commit body.
4. `INIT_ENTRY_OFF = 1712` noted in `design/kernel/task-struct-layout.md`.

## 9. Next steps

- **Tier 2 unblock trio: #665, #668, #662.** All three exist as tracked
  issues; #668 is the highest-impact for R17 (dispatch table freeze) and
  should be first, then #665 (vfs_open index conflation), then #662
  (LAPIC timer delivery — needed only for the parent-side wait to
  actually be unblocked by scheduler preemption; init's initial fork/exec
  path does not itself require timer preemption).
- **R17.M2-006** (implicit follow-up): milestone closure marker
  (`R17.M2 INIT OK` or similar) once Tier 2 lands and the boot log
  genuinely shows init printing its own message.
- **R17.M3 shell startup**: init.pdx already contains the fork+execve
  logic (init.pdx:47-68). Once Tier 2 clears, R17.M3's remaining work
  is limited to shell.pdx maturity, not init-side plumbing.
