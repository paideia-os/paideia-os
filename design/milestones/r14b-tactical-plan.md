# PaideiaOS R14B Tactical Per-Subsystem Plan

**Scope:** From current substrate (paideia-as v0.12.0, R14.M2 landed) to an interactive shell over serial (`init` execs `sh`, user types `echo hello`, kernel prints `hello`, shell exits cleanly, kernel powers off).

**Vantage:** This is the **tactical** companion to osarch's strategic milestone/dependency-graph plan. This document pins per-subsystem design contracts and issue-level decomposition. Rounds R14B (higher-half + KPTI + IPI), R15 (ring-3 + syscalls + processes + scheduler), R16 (VFS + tmpfs + fd + UART RX + TTY), R17 (libc-lite + init + shell) are covered.

**North star:** every issue in this document must trace either to the shell demo or to load-bearing infrastructure for it. No infrastructure is scoped for its own sake.

**Discipline:** 5-mode smoke stays byte-identically green throughout. New modes are additive. Cross-repo escalation for paideia-as encoder gaps follows the standard triangle (softarch→workerbee→debugger in paideia-as; paideia-os agent bumps submodule after tag). No hidden-shortcut stubs; only real handlers or explicit structural stubs with R_N-deferral audit.

**Total tactical issues below:** 152, spanning 20 subsystems, average 7.6/subsystem, all sized as one PR-sized commit.

---

## Table of Contents

- **Global sections**
  - G.1 Calling convention spec
  - G.2 Errno convention
  - G.3 fd numbering + allocation policy
  - G.4 PID allocation policy
  - G.5 Memory ownership model
  - G.6 Scheduling policy MVP
  - G.7 Shutdown protocol
- **Subsystems 1–20** (per-subsystem contract + issue list + tests + deps)
- **Aggregate encoder gap forecast** (chronological, categorized by paideia-as milestone)
- **Highest-risk issue register**
- **Definition of "shell echo working"** (byte-level serial transcript)

---

## G.1 Calling convention spec

**Kernel-internal (all `.pdx` functions).** SysV AMD64 (Linux ABI), as already used throughout R8–R14.

| Slot | Register | Notes |
|---|---|---|
| arg0 | rdi | |
| arg1 | rsi | |
| arg2 | rdx | |
| arg3 | rcx | Caller-saved in SysV; syscall entry clobbers it |
| arg4 | r8 | |
| arg5 | r9 | |
| ret  | rax | Second return value in rdx if a pair |
| scratch | r10, r11 | r11 also clobbered by syscall |
| callee-saved | rbx, rbp, r12–r15, rsp | Save on entry, restore on return |

Effect/capability annotations `!{...} @{...}` remain mandatory on every kernel function. Unsafe blocks carry `justification: "..."`.

**Ring-3 → ring-0 syscall entry.** Linux-compatible SYSCALL ABI, so the paideia-as encoder gap surface remains small and the syscall_shim from `src/user/syscall_shim.pdx` can be extended without ABI churn.

| Slot | Register | Notes |
|---|---|---|
| syscall# | rax | Number of the syscall from the §C+ table |
| arg0 | rdi | |
| arg1 | rsi | |
| arg2 | rdx | |
| arg3 | r10 | *Not rcx.* SYSCALL clobbers rcx (return RIP) and r11 (user RFLAGS). |
| arg4 | r8 | |
| arg5 | r9 | |
| ret  | rax | Negative errno on error (see G.2). |
| clobbers (kernel side) | rcx, r11 | Restored by sysretq |

The `syscall_entry` trampoline in `src/kernel/core/syscall/entry.pdx` already shuffles `rax→rdi, rdi→rsi, rsi→rdx, rdx→rcx, r10→r8` before `call syscall_dispatch`. This spec is already live; the only change in R15.M3 is adding `swapgs` at entry/exit and KPTI CR3 flip inside the sysretq window.

**Ring-0 → ring-3 initial jump.** Via `iretq` (for the `init` bring-up) and via `sysretq` (for subsequent returns). Both take a fully-constructed frame: for `iretq` the interrupt frame is `SS:RSP, RFLAGS, CS:RIP`; for `sysretq` the return is `RIP=rcx, RFLAGS=r11 (with reserved bits set)`.

## G.2 Errno convention

**Decision:** negative-return-value semantics on syscall boundary. Rust-style Result only lives internally to the kernel; it does not cross ring-0/ring-3.

**Rationale.**
- SYSCALL ABI has one return register (rax). Two-register (value, error_code) needs an extra out-parameter — cost per syscall, and a departure from the Linux convention that our syscall_shim already assumes.
- Errno tests in userspace collapse to `mov r, rax; cmp r, -4095; ja .error` (i.e. rax ∈ [-4095, -1] is error). Straight and cheap in paideia-as.

**Errno table (initial set — extend as syscalls are added).**

| Symbol | Value | Meaning |
|---|---|---|
| `EPERM` | -1 | Insufficient rights on cap |
| `ENOENT` | -2 | Path not found |
| `EBADF` | -9 | Not a valid fd |
| `EAGAIN` | -11 | RX queue empty, retry |
| `ENOMEM` | -12 | Out of pages / slots |
| `EFAULT` | -14 | Bad user pointer |
| `EEXIST` | -17 | File already exists |
| `ENOTDIR` | -20 | Path component is not a dir |
| `EINVAL` | -22 | Bad arg |
| `EMFILE` | -24 | Per-process fd table full |
| `ENOSYS` | -38 | Unimplemented syscall (already used) |

**Kernel-side rule.** `syscall_dispatch` returns `u64` where the top bit distinguishes error from value. Handlers may return raw `-errno` cast to u64 (e.g. `mov rax, 0xFFFFFFFFFFFFFFF7` for `-9 EBADF`). paideia-as `mov r64, imm64` supports this directly.

## G.3 fd numbering + allocation policy

**Reserved fds.**
- `fd 0` — stdin  (init/shell inherits from `tty0`)
- `fd 1` — stdout (init/shell inherits from `tty0`)
- `fd 2` — stderr (init/shell inherits from `tty0`)

**Allocation policy.** *Dense low-first.* On `open`, `dup`, `dup2`, walk the per-process fd table from index 3 upward, return the lowest free index. This is POSIX-compatible and predictable for shell scripts (`2>&1` semantics).

**Per-process fd table size.** 64 slots at R14B/R17 landing (`FD_MAX = 64`). Extensible without ABI break by growing the array.

**Layout.** `fd_table` is a fixed-size array of `fd_entry` structs at 24 bytes each (`vnode_ptr:u64, offset:u64, flags:u32, ref_count:u32`). Lives at a fixed offset inside `task_struct`.

## G.4 PID allocation policy

**Decision:** *dense low-first with reuse.* On `fork`, walk `pid_table` from `1` upward, return the lowest free slot. On `wait` reaping, mark slot free. `pid 0` is reserved as sentinel (used already as `parent_pid=0` in `kind_process`). `pid 1` is `init`.

**Rationale.**
- Predictable pid space (0..MAX_PIDS-1) — shell can print pids as small ints.
- Reuse avoids monotonic exhaustion that KIND_PROCESS's current `_next_pid` would eventually hit.
- Security implication (pid reuse attacks) is deferred to a "generation counter" in the slot; check on `wait` and `kill`. This mirrors the cap generation scheme.

**Slot table.** `MAX_PIDS = 64` at R15.M5 landing. `pid_table[i]` is a `task_struct*`; free slots hold `NULL_TASK_PTR`. Sized to grow without ABI churn.

**Not chosen (sparse random):** rejected — has no security benefit under a strict-cap model where pid is not the security token, and complicates the shell UX for demoing.

## G.5 Memory ownership model

Three owners, no overlap:

1. **Process aspace** — pages backing user text/data/stack/heap. Owned by the task_struct that created them (via `aspace_create`). Released on process teardown by walking the aspace and returning frames to the phys allocator. COW pages are ref-counted at the frame level (implemented at R15.M6).
2. **Kernel slab** — pages backing kernel structures (task_struct pool, fd tables, vfs inodes, ipc rings). Owned by the module that declared the pool. Never released; sized at build time from a static `.bss` reservation (R14B does not yet have dynamic kernel slabs).
3. **IPC buffer** — pages shared between two aspaces via KIND_IPC_ENDPOINT / KIND_IPC_PORT. Owned by the sender until dequeue, then transferred to the receiver. On process teardown of either endpoint, the ring is drained and unmapped from both aspaces.

**Invariant:** exactly one owner writes a page's "free" bit in the phys allocator on release. Ownership is encoded in the frame's owner_kind tag in the frame descriptor. R14B introduces the tag; enforcement is at R15.M6 (fork/exec/teardown).

## G.6 Scheduling policy MVP

**Round-robin with fixed timeslice.** All runnable tasks at the same priority. Priority-bitmap runqueue already exists (`sched/priority_bitmap.pdx`); we use one bit (bit 8, "normal") for all tasks at MVP.

**Timeslice.** 10 ms (100 Hz LAPIC-timer TDR at TSC-deadline mode). Chosen because a shell demo cannot demonstrate preemption if the slice is too long, and QEMU TCG is deterministic — an interactive demo wants perceptible task alternation.

**Yield paths.** (a) budget exhaustion (existing `budget.pdx`); (b) blocking on RX empty (EAGAIN from `sys_read` → `wake_block` on tty's KIND_NOTIFICATION); (c) blocking on child (`sys_wait` on KIND_REPLY).

**Idle.** When runqueue is empty, kernel `hlt`s in an idle stub task at slot 0 (`task[0] = idle`), woken by any interrupt.

**Deferred to R15+ / R16+.**
- Multi-priority (real bitmap fanout).
- CFS/EEVDF-style fairness.
- Multi-CPU per-CPU runqueue (blocked on paideia-as GS-relative, PA-R14-001, cleared by v0.12.0 bundle).
- Work stealing.

## G.7 Shutdown protocol

**Chain:** `shell _exit(status)` → `sys_exit` in init/shell → task reaped by parent → when task 1 (init) exits, kernel powers off.

**Mechanism.** QEMU ACPI shutdown via IO port `0x604`, magic value `0x2000` (QEMU-specific "S5" sleep state). Fallback: port `0xB004` value `0x2000` (older Bochs/QEMU). Real ACPI FADT-driven shutdown is deferred until ACPI/AML is a going concern (R18+).

**Kernel-side sequence on final exit:**
1. Reap process (release aspace pages, clear pid slot, close all fds, close cap slots).
2. If reaped process was pid 1: uart_puts("PaideiaOS: init exited (status=N), powering off.\n").
3. `cli`.
4. `mov dx, 0x604; mov ax, 0x2000; out dx, ax`.
5. `hlt` in an infinite loop as final fallback.

**Encoder gap:** `out dx, ax` (word out) — verify present; paideia-as has `outb` from R9. If absent, escalate as small item.

---

## Subsystem 1 — Higher-half kernel VMA + linker VMA/LMA split (R14.M3)

### A. Design contract

**Responsibility.** Move the kernel from low identity map (VMA=LMA=0x00100000) to canonical higher-half (VMA=0xFFFF800001000000, LMA=0x00100000). Boot stub, IDT trampolines, all kernel `.pdx` code, and all cap/sched/ipc state must resolve correctly from the higher-half address after transition, while the boot stub itself continues to execute from the low identity map until the far-jmp.

**Invariants.**
- After far-jmp: `%rip ≥ 0xFFFF800001000000` for all kernel code.
- PML4[0] identity map remains valid for the boot stub's data (GDT32, banner, PT structures in `.bss`) but is retired for kernel `.text` at end of Path B.
- Every existing R8/R10/R11/R12/R12-denial smoke fingerprint reproduces **byte-identically** to the pre-transition baseline.
- Symbols in `.text.boot` and `boot .rodata`/`.bss` retain LMA-VMA=0 (low identity); symbols in kernel `.text`/`.data`/`.bss` get VMA in higher-half, LMA stays low.

**Primary interfaces.** No cross-module ABI changes. Internal-only: linker script + boot_stub.S + `_kernel_high_entry` new symbol.

**Failure modes.**
- Bad far-jmp target → triple-fault at first instruction after `ljmp`. Debugger: `qemu -d int,cpu_reset -no-reboot`.
- Symbol in `.text` still referenced via `mov r, imm32` (won't fit) → link-time R_X86_64_32 overflow. Caught by `readelf -r` in preflight.
- Boot stub referencing kernel symbol via low VA after transition → GP or PF. Contained by keeping boot-stub → kernel calls only via `_kernel_high_entry`.

**State machine.** Not applicable; one-shot boot transition.

### B. Issue list

1. **`r14b-m3-001-linker-vma-lma-split`** — Amend `src/kernel/link.ld`: set `KERNEL_VMA = 0xFFFF800001000000`; split `.text` / `.data` / `.rodata` / `.bss` sections into (VMA higher-half, LMA low) via `AT( )` clause; keep `.text.boot` and boot-stub `.rodata`/`.bss` at VMA=LMA=0x100000.
   - AC: `readelf -l build/kernel.elf` shows two PT_LOAD segments (boot low, kernel high).
   - AC: `readelf -r build/kernel.elf` still shows zero relocations.
   - AC: `objdump -d build/kernel.elf | grep '<syscall_entry>' | head -1` shows an address ≥ 0xffff800001000000.
   - AC: 5-mode smoke still passes (no runtime code change yet; only linker layout).
   - Touching: `src/kernel/link.ld`.
   - Encoder gaps: none.
   - Prereq: none within subsystem.

2. **`r14b-m3-002-symbol-imm64-audit`** — Grep every `mov r*, imm32` load of a kernel symbol; verify each has an `imm64` (movabs) equivalent or uses `lea r, [rip + sym]`. Fix references that would overflow.
   - AC: `objdump -d build/kernel.elf` shows no R_X86_64_32 fixups that reference kernel symbols with hi-half addresses.
   - AC: build with `-Wl,--warn-common,--fatal-warnings` succeeds.
   - AC: audit log at `design/audit/entries/r14b-m3-002-imm64-audit.md` lists every site inspected.
   - Touching: any `.pdx` referencing symbols by imm.
   - Encoder gaps: verify `mov r64, imm64` movabs (already present per r14-preflight §A.2).
   - Prereq: 1.

3. **`r14b-m3-003-boot-stub-page-tables-add-high-mapping`** — Extend `tools/boot_stub.S` to install a PML4[256] entry pointing at a PDPT that maps VA range 0xFFFF_8000_0000_0000 + [0..1GiB) via a 1 GiB huge page pointing at phys 0. This gives higher-half a valid path to the kernel's low-loaded LMA.
   - AC: after boot, `qemu-monitor info mem` (or QEMU `-d mmu` trace) shows a valid mapping for VA 0xFFFF800000100000.
   - AC: 5-mode smoke still passes (boot stub still runs from low VA; no consumer of high mapping yet).
   - Touching: `tools/boot_stub.S`.
   - Encoder gaps: none (this is GAS-syntax assembly, not paideia-as).
   - Prereq: 1.

4. **`r14b-m3-004-kernel-high-entry-symbol`** — Add `_kernel_high_entry:` label in `src/kernel/boot/kernel_main.pdx` immediately preceding the current `kernel_main` body; ensure this symbol is emitted with high-half VMA (via linker section `.text` placement).
   - AC: `nm build/kernel.elf | grep _kernel_high_entry` shows an address ≥ 0xffff800001000000.
   - AC: `objdump -d build/kernel.elf --disassemble=_kernel_high_entry` shows the first byte matches `kernel_main`'s first byte.
   - Touching: `src/kernel/boot/kernel_main.pdx`.
   - Encoder gaps: none.
   - Prereq: 1, 2.

5. **`r14b-m3-005-boot-stub-far-jmp-transition`** — Replace the current low-VA jump into kernel_main in `tools/boot_stub.S` with an indirect far-jmp `ljmp *high_target_ptr`, where `high_target_ptr` is a 10-byte (segment:64-bit-offset) memory operand holding `{0x08 : &_kernel_high_entry}`.
   - AC: Boot fingerprint identical byte-for-byte to pre-change.
   - AC: `qemu -d int -no-reboot -no-shutdown` shows no triple-fault; kernel main banner still prints.
   - AC: `qemu -monitor -` `info registers` at first breakpoint shows `%rip` ≥ 0xffff800001000000.
   - Touching: `tools/boot_stub.S`.
   - Encoder gaps: `ljmp *m64` — confirmed present per r14-preflight §A.
   - Prereq: 3, 4.

6. **`r14b-m3-006-low-identity-retire-audit`** — Audit every kernel .pdx for residual low-VA data references (should be zero after 2). Add a build-time check in `tools/build.sh` that runs `objdump -R` on `build/kernel.elf` and fails on any R_X86_64_32 whose target symbol is in `.text`/`.data`/`.rodata` and whose VMA is in higher-half.
   - AC: build.sh exit 1 if the check fails.
   - AC: passing build shows the check in build log.
   - Touching: `tools/build.sh`, potentially `.pdx` fixups.
   - Encoder gaps: none.
   - Prereq: 5.

7. **`r14b-m3-007-idt-vector-thunks-hi-check`** — Verify every IDT-installed vector's offset (currently packed in `idt.pdx`) lives in higher-half after transition. This matters because the CPU loads the raw offset from the IDT descriptor at fault time; if a vector still resolves to low-VA, a fault post-transition triple-faults.
   - AC: `objdump -s -j .rodata build/kernel.elf | grep -A2 _idt_entries` shows each vector's offset high 32 bits are set to 0xffff8000-something.
   - AC: an intentional `#UD` fixture (opcode `0f 0b`) in a test mode dispatches to `handle_ud` and prints `#UD` on serial rather than triple-faulting.
   - Touching: `src/kernel/core/int/idt.pdx`, possibly a new test mode `boot_r14b_ud`.
   - Encoder gaps: none.
   - Prereq: 5.

8. **`r14b-m3-008-smoke-hifp-fingerprint-fixture`** — Add a debug tag `HI VA <hex>` emitted in `kernel_main`'s prologue that prints the top 32 bits of `%rip` at that point, so the smoke can positively witness the higher-half transition landed. Fingerprint file: `tests/r14b/expected-boot-r14b-hivma.txt`.
   - AC: new mode `boot_r14b_hivma` prints `HI VA FFFF8000` before `CAP OK`.
   - AC: added to `tools/run-smoke.sh` and pre-push hook.
   - AC: fingerprint reproduces 3/3 reps.
   - Touching: `src/kernel/boot/kernel_main.pdx`, `tests/r14b/expected-boot-r14b-hivma.txt`, `tools/run-smoke.sh`.
   - Encoder gaps: none.
   - Prereq: 5.

### C. Testing strategy

- **Smoke modes exercised.** All existing 5 modes must still pass byte-identically (regression). One new additive mode `boot_r14b_hivma` positively witnesses the transition.
- **New expected-boot files.** `tests/r14b/expected-boot-r14b-hivma.txt` (banner + `HI VA FFFF8000` + rest of R12 fingerprint).
- **paideia-as canary.** None. All encoder needs (`imm64`, `ljmp *m64`) already present.
- **Userland test.** None. Ring-3 not yet reachable.

### D. Cross-subsystem dependencies

- **Depends on:** none (this is the R14B opener).
- **Depended on by:** #2 (KPTI needs kernel in higher-half so user aspace populates low half cleanly). #3 (IPI substrate — trampoline in higher-half). #4 (User aspace loader — user text goes in low half, kernel in high). All downstream subsystems 4–20 depend transitively.

---

## Subsystem 2 — KPTI: per-process kernel/user PML4 (R14.M4)

### A. Design contract

**Responsibility.** Two PML4s per process (user PML4, kernel PML4). On SYSCALL entry, flip to kernel PML4. On SYSRET, flip to user PML4. User PML4 maps only the minimal syscall trampoline stub (to serve as the entry point without immediately faulting). Kernel PML4 maps the entire kernel.

**Invariants.**
- User PML4 [0..255] holds the user's low-half mappings; [256] maps the syscall trampoline page (`.text.syscall_trampoline`) at 0xFFFF800000000000; all other high-half PML4 entries are zero.
- Kernel PML4 [0..255] is not populated (kernel doesn't need low half except during boot); [256..511] holds the full higher-half kernel map.
- CR3 switch is atomic w.r.t. SYSCALL entry — the CPU is single-threaded on that path so no memory barrier needed on single-CPU. mfence added when Path A opens.
- SYSCALL trampoline page must be executable in both PML4s.

**Primary interfaces.**

```
kpti_switch_to_kernel : () -> () !{sysreg} @{}         // mov cr3, kernel_pml4_pa
kpti_switch_to_user   : (pml4_pa: u64) -> () !{sysreg} @{}  // mov cr3, rdi
kpti_build_user_pml4  : (task_pml4_pa: u64) -> u64 !{mem} @{}
                       // Copies kernel entries for trampoline page only; returns user PML4 phys.
```

**Failure modes.**
- Missing trampoline mapping in user PML4 → PF on SYSCALL entry before dispatch → cannot recover (no valid stack). Test as a fixture and catch at aspace_create time.
- CR3 write with non-4KiB-aligned PA → GP. Sanity-check with `and rax, 0xFFFFFFFFFFFFF000` before write.
- Missing INVLPG on trampoline page after user pml4 rebuild → stale TLB entry. Emit INVLPG in `kpti_switch_to_user`.

**State machine.** Not applicable per-call; runtime state is (current_cr3 ∈ {kernel, user}).

### B. Issue list

1. **`r14b-m4-001-user-pml4-frame-alloc`** — In `kpti.pdx`, replace `aspace_create_user_pgd` sentinel with real allocation: `phys_alloc_page()`, zero, store phys in `task_struct.user_pml4_pa`.
   - AC: creating a task returns a distinct 4KiB-aligned pml4 phys.
   - AC: fresh page is byte-zero on allocation (`memcheck` or hex dump in fixture).
   - AC: `boot_r12` and `boot_r12_denial` still pass.
   - Touching: `src/kernel/core/mm/kpti.pdx`, `src/kernel/core/sched/tcb.pdx` (field addition).
   - Encoder gaps: none.
   - Prereq: none.

2. **`r14b-m4-002-syscall-trampoline-section`** — Add `.text.syscall_trampoline` section in `src/kernel/link.ld` with 4KiB alignment; move `syscall_entry` label into that section.
   - AC: `nm build/kernel.elf | grep syscall_entry` address is 4KiB-aligned.
   - AC: `readelf -S build/kernel.elf | grep syscall_trampoline` shows the section exists with `AX` (alloc, exec).
   - AC: 5-mode smoke passes.
   - Touching: `src/kernel/link.ld`, `src/kernel/core/syscall/entry.pdx`.
   - Encoder gaps: none.
   - Prereq: subsystem 1.

3. **`r14b-m4-003-kpti-build-user-pml4`** — Real body of `kpti_build_user_pml4(task_pml4_pa)`: copy the entries needed for trampoline mapping only (PML4 slot 256 pointing at a shared trampoline-PDPT with only the trampoline page mapped). Do NOT copy the full kernel map (that's Meltdown-vulnerable).
   - AC: after `kpti_build_user_pml4`, dump of user PML4 shows only [X→trampoline] where X is the slot index for VA 0xFFFF800000000000.
   - AC: attempting to fetch from a kernel-only address after switching to user PML4 (e.g. `mov rax, [0xFFFF800001000000]` from ring-0 with user CR3 loaded) faults with #PF, not returning kernel data.
   - Touching: `src/kernel/core/mm/kpti.pdx`.
   - Encoder gaps: none.
   - Prereq: 1, 2.

4. **`r14b-m4-004-kernel-pml4-shared-boot-init`** — Compose a single kernel PML4 at boot in `kernel_main` before first user aspace exists. Store phys in `_kernel_pml4_pa` (module-level u64).
   - AC: `readelf` shows `_kernel_pml4_pa` symbol.
   - AC: kernel operates from this pml4 after boot init (CR3 read after init returns this value).
   - AC: 5-mode smoke passes.
   - Touching: `src/kernel/boot/kernel_main.pdx`.
   - Encoder gaps: none.
   - Prereq: none.

5. **`r14b-m4-005-cr3-switch-primitives`** — Add `kpti_switch_to_kernel` / `kpti_switch_to_user` primitives in `kpti.pdx`. Real `mov cr3, rN` on entry.
   - AC: `objdump -d` shows a `mov cr3, r*` in each function.
   - AC: an isolated fixture (test mode `boot_r14b_kpti`) switches to user pml4, faults on a kernel-only VA, switches back, prints `KPTI OK`.
   - Touching: `src/kernel/core/mm/kpti.pdx`.
   - Encoder gaps: `mov cr3, r64` — verify (may already be present from CR4 fixes).
   - Prereq: 3, 4.

6. **`r14b-m4-006-syscall-entry-cr3-flip-on-entry`** — In `syscall_entry`, immediately after saving user rsp, emit `mov rax, [rip + _kernel_pml4_pa]; mov cr3, rax`. Before `sysretq`, restore user pml4.
   - AC: `objdump -d` of `syscall_entry` shows two `mov cr3` sites.
   - AC: a fixture syscall from a fake ring-3 context (via test harness with an explicit iretq) returns cleanly and prints `SYS OK`.
   - AC: 5-mode smoke passes.
   - Touching: `src/kernel/core/syscall/entry.pdx`.
   - Encoder gaps: none.
   - Prereq: 5.

7. **`r14b-m4-007-swapgs-add-on-syscall-boundary`** — Emit `swapgs` at first instruction of `syscall_entry` and last instruction before `sysretq`. Even at single-CPU, this pins the discipline for Path A.
   - AC: `objdump -d syscall_entry` shows two `swapgs` (`0f 01 f8`).
   - AC: KERNEL_GS_BASE is initialized in `syscall_msr_setup` (already done).
   - AC: 5-mode smoke passes; `boot_r14b_kpti` still passes.
   - Touching: `src/kernel/core/syscall/entry.pdx`.
   - Encoder gaps: `swapgs` — verify or escalate as PA-R15-00X.
   - Prereq: 6.

8. **`r14b-m4-008-user-pml4-populate-lowhalf-in-aspace-map`** — When `aspace_map` is called for a user aspace, write into user_pml4_pa (not kernel_pml4_pa). `aspace_map` takes an `aspace_root` argument already; the change is passing the user pml4 phys through.
   - AC: `aspace_map(user_pml4_pa, low_va, phys, len, RW|U)` results in a valid low-half mapping visible only under user CR3.
   - AC: mm_torture test (extend existing) writes a page under user pml4, faults under kernel pml4, restores.
   - Touching: `src/kernel/core/mm/aspace_map.pdx` (caller-side; core walker unchanged).
   - Encoder gaps: none.
   - Prereq: 1.

9. **`r14b-m4-009-smoke-kpti-fixture-mode`** — New mode `boot_r14b_kpti` with fingerprint `KPTI OK`. Exercises: alloc user pml4, populate one page at 0x400000, mov cr3 user, access page, mov cr3 kernel, access kernel-only page.
   - AC: mode boot_r14b_kpti passes 3/3 reps.
   - AC: added to `tools/run-smoke.sh`.
   - AC: `expected-boot-r14b-kpti.txt` file lands.
   - Touching: `src/kernel/boot/kpti_smoke.pdx` (new), `tests/r14b/expected-boot-r14b-kpti.txt`, `tools/run-smoke.sh`.
   - Encoder gaps: none.
   - Prereq: 5, 6, 7, 8.

### C. Testing strategy

- **Smoke modes.** Existing 5 must remain byte-identical. New mode `boot_r14b_kpti` witnesses CR3 flip works and kernel data is inaccessible under user PML4.
- **Fingerprint.** `KPTI OK` line added after `CAP OK`.
- **paideia-as canary.** Verify `swapgs`, `mov cr3, r64` encoders present; escalate as needed.
- **Userland test.** Not yet — no ring-3.

### D. Cross-subsystem dependencies

- **Depends on:** Subsystem 1 (higher-half kernel).
- **Depended on by:** 3 (IPI TLB shootdown crosses user/kernel PML4s), 4 (user aspace loader), 5 (ring-3 iretq — must load user CR3 before iretq), 6 (syscall MSR setup — swapgs pairs with CR3 flip), 9 (fork/exec needs KPTI-aware clone).

---

## Subsystem 3 — TLB shootdown / IPI substrate (R14.M5, SMP-ready even at single-CPU)

### A. Design contract

**Responsibility.** Provide the hooks and per-CPU mailboxes that TLB shootdown and cross-CPU reschedule will use, even if there is only one CPU at R14B. When Path A opens, wiring APs will not require touching subsystems 4–20.

**Invariants.**
- Per-CPU mailbox structure exists at a stable offset in a per-CPU struct (`cpu_local_t`), even if only CPU 0 has one instantiated.
- IPI vector 0xF0 (TLB shootdown) has an IDT entry with a real trampoline that reads the mailbox and INVLPGs the addresses in it.
- IPI vector 0xF1 (reschedule request) has a real trampoline that sets a "resched needed" flag on the target CPU.
- `send_ipi(cpu_id, vector)` compiles and returns immediately when cpu_id == BSP (single CPU) — no self-IPI.

**Primary interfaces.**

```
tlb_shootdown_broadcast : (va: u64, count: u64) -> () !{mem, sysreg} @{}
tlb_shootdown_local     : (va: u64) -> () !{sysreg} @{}    // just invlpg
ipi_send                : (cpu_id: u64, vector: u64) -> () !{mem, sysreg} @{}
cpu_local_get           : () -> u64 !{sysreg} @{}          // returns &cpu_local_t for this CPU
```

**Failure modes.**
- Sending IPI to non-existent CPU → GP or silent drop. R14B: return early if cpu_id != 0.
- INVLPG on a VA not mapped → no-op (safe).
- Missing mfence around mailbox write/IPI-send → reorder can lose invalidation. R14B is single-CPU so no ordering issue; document that mfence is required when APs come up.

**State machine.** Per-CPU: (idle) → (ipi_pending vector V) → (in_isr) → (mailbox_processed) → (idle).

### B. Issue list

1. **`r14b-m5-001-cpu-local-struct-layout`** — Define `cpu_local_t` in `src/kernel/core/cpu/local.pdx` (new file): 128 bytes, offsets pinned (0:cpu_id, 8:current_tcb_ptr, 16:tlb_mailbox_head, 24:tlb_mailbox_va[8]).
   - AC: struct layout documented in `design/multicore/per-cpu-layout.md`.
   - AC: `_cpu_locals[MAX_CPUS=1]` array in .bss with static init cpu_id=0 for slot 0.
   - AC: `boot_r12` still passes.
   - Touching: `src/kernel/core/cpu/local.pdx` (new), `design/multicore/per-cpu-layout.md` (new).
   - Encoder gaps: none.
   - Prereq: none.

2. **`r14b-m5-002-gs-base-msr-setup-cpu0`** — At boot, wrmsr IA32_GS_BASE = &`_cpu_locals[0]`. This gives `mov rax, [gs:0]` a valid target once the encoder lands.
   - AC: `rdmsr(IA32_GS_BASE)` after boot returns &_cpu_locals[0].
   - AC: verified via a fixture that reads back the value (workaround: `swapgs; mov rax, [rax+8]` if gs-mem-operand still not landed — or `rdmsr` sequence).
   - Touching: `src/kernel/boot/kernel_main.pdx`, `src/kernel/core/cpu/local.pdx`.
   - Encoder gaps: wrmsr already present.
   - Prereq: 1.

3. **`r14b-m5-003-cpu-local-get-workaround`** — Provide `cpu_local_get()` returning &_cpu_locals[0] via rdmsr(IA32_GS_BASE). This is the interim path before PA-R14-001 (gs-mem-operand) lands. When encoder lands, single-line replacement to `mov rax, [gs:0]`; call sites unchanged.
   - AC: `cpu_local_get()` returns the same address every call after boot.
   - AC: `boot_r12` still passes.
   - AC: `TODO(PA-R14-001)` comment in code, pointer to escalation.
   - Touching: `src/kernel/core/cpu/local.pdx`.
   - Encoder gaps: `mov r64, [gs:disp32]` — PA-R14-001; workaround via rdmsr.
   - Prereq: 2.

4. **`r14b-m5-004-tlb-shootdown-local`** — `tlb_shootdown_local(va)` = `invlpg [va]`. One-liner but pinned as a callable primitive so upstream code doesn't emit invlpg inline.
   - AC: fixture: map a VA under user pml4, switch to it, read succeeds; invalidate; switch away; back; re-read succeeds (should still succeed since mapping is still valid — this tests that invlpg doesn't corrupt).
   - AC: `objdump -d` shows `0f 01 38` (invlpg [rax]) or `0f 01 3f` etc.
   - Touching: `src/kernel/core/ipi/tlb_shootdown.pdx`.
   - Encoder gaps: `invlpg [reg]` — verify present, escalate PA-R14-002 if not.
   - Prereq: none within subsystem.

5. **`r14b-m5-005-tlb-shootdown-broadcast-stub`** — `tlb_shootdown_broadcast(va, count)` = for each va, call tlb_shootdown_local; when Path A opens, add IPI broadcast. R14B: local only.
   - AC: fixture invalidates 3 VAs, boot proceeds.
   - AC: comment blocks note the SMP extension path.
   - Touching: `src/kernel/core/ipi/tlb_shootdown.pdx`.
   - Encoder gaps: none.
   - Prereq: 4.

6. **`r14b-m5-006-ipi-vector-idt-slots`** — Install IDT vectors 0xF0 (TLB shootdown) and 0xF1 (reschedule) with real trampolines that (a) EOI via LAPIC, (b) call the handler. Handlers are stubs on single-CPU (log and return).
   - AC: `objdump -d _ipi_trampoline_f0` shows a valid trampoline.
   - AC: an intentionally-triggered self-IPI via LAPIC ICR (once LAPIC allows) lands in the trampoline.
   - AC: `boot_r14b_ipi` mode prints `IPI OK`.
   - Touching: `src/kernel/core/ipi/vectors.pdx` (new), `src/kernel/core/int/idt.pdx`.
   - Encoder gaps: none.
   - Prereq: 4.

7. **`r14b-m5-007-smoke-ipi-mode`** — New mode `boot_r14b_ipi` fingerprint `IPI OK` after `KPTI OK`.
   - AC: 3/3 reps green.
   - AC: added to `run-smoke.sh`.
   - Touching: `tests/r14b/expected-boot-r14b-ipi.txt`, `tools/run-smoke.sh`.
   - Encoder gaps: none.
   - Prereq: 6.

### C. Testing strategy

- **Smoke modes.** New `boot_r14b_ipi` witnesses IDT vectors 0xF0/0xF1 installed. Existing modes unaffected.
- **paideia-as canary.** Verify `invlpg [reg]` and consider filing PA-R14-002 for gs-mem workaround if not yet cleared. LAPIC ICR write path already used.
- **Userland test.** None yet.

### D. Cross-subsystem dependencies

- **Depends on:** Subsystem 1 (higher-half — IPI trampoline lives in kernel .text).
- **Depended on by:** 4 (aspace_unmap triggers shootdown), 9 (fork COW breaks require shootdown), 10 (scheduler reschedule IPI), 12 (tmpfs page write triggers shootdown when pages remapped), 15 (TTY buffer shared between CPUs — Path A).

---

## Subsystem 4 — User aspace creation & loader (R15.M1)

### A. Design contract

**Responsibility.** Create a fresh user address space, load an ELF-lite binary (paideia-as-emitted, PT_LOAD only, no dynamic linking, no relocations) into it, allocate initial user stack, and return a task_struct-populatable descriptor `{user_pml4_pa, entry_rip, initial_rsp, aslr_offset=0}`.

**Invariants.**
- User aspace maps user text as R+X (no W), user data as R+W (no X), user stack as R+W (no X), all with U bit set.
- No mapping in the user aspace has both W and X (W^X invariant).
- User stack top page has `pgprot_guard` (unmapped) directly below to catch stack overflow.
- Loader refuses ELF with sections that would map into higher-half.

**Primary interfaces.**

```
aspace_create_user     : () -> u64 !{mem} @{}
                         // Returns user_pml4_pa (allocates + zeroes pml4 + copies trampoline slot)
elf_lite_load          : (aspace: u64, image_bytes: ptr, image_len: u64) -> LoadResult !{mem} @{}
                         // Returns {entry_rip:u64, initial_rsp:u64, status:i64}
user_stack_alloc       : (aspace: u64, size_pages: u64) -> u64 !{mem} @{}
                         // Returns initial rsp (top of stack)
```

`LoadResult` = 24-byte struct passed via memory pointer (rdi = out ptr, rsi/rdx/rcx = args).

**Failure modes.**
- ELF magic mismatch → ENOEXEC (-8).
- PT_LOAD extends into high-half → EINVAL.
- Out of phys frames → ENOMEM.
- All failures release partial aspace pages (RAII in the sense of manual `aspace_teardown` on error).

**State machine.** Not applicable per-call.

### B. Issue list

1. **`r15-m1-001-aspace-create-user-real`** — Fill body of `aspace_create_user`: allocate pml4 frame, zero, call `kpti_build_user_pml4` (from Subsystem 2), return phys.
   - AC: two calls return two distinct pml4 phys addrs.
   - AC: `boot_r14b_aspace` prints `USER ASPACE OK` and `PML4 <hex>` before halting.
   - Touching: `src/kernel/core/mm/aspace_create.pdx`.
   - Encoder gaps: none.
   - Prereq: Subsystem 2 issue 3.

2. **`r15-m1-002-elf-lite-format-spec`** — Design doc: `design/user/elf-lite-format.md`. Frozen minimal ELF64 subset (magic, ident, PT_LOAD, R+X/R+W flags, no dynamic, no notes).
   - AC: doc lands and lists exact byte offsets for all fields we parse.
   - AC: doc has a matched `objdump -h` for the shell.bin we plan to produce.
   - Touching: `design/user/elf-lite-format.md`.
   - Encoder gaps: none.
   - Prereq: none.

3. **`r15-m1-003-user-linker-script-and-build-user-sh`** — Add `src/user/link.ld` and `tools/build-user.sh`. Linker script places user `.text` at 0x400000, `.data` at 0x600000, `.bss` at 0x700000. Build script compiles `src/user/*.pdx`, links, `objcopy -O elf64-x86-64 shell.bin`.
   - AC: `tools/build-user.sh` produces `build/user/shell.elf` and `build/user/shell.bin`.
   - AC: `readelf -l build/user/shell.elf` shows one PT_LOAD segment.
   - AC: 5-mode smoke unaffected (shell.bin not yet embedded in kernel).
   - Touching: `src/user/link.ld`, `tools/build-user.sh`, `tools/build.sh` (invoke user build).
   - Encoder gaps: none.
   - Prereq: none.

4. **`r15-m1-004-elf-lite-parser`** — `elf_lite_parse(image_bytes, image_len)` returns count of PT_LOAD segments, each with (offset, filesz, memsz, vaddr, flags). Kernel-side.
   - AC: fixture parses shell.bin and prints `ELF PARSE N=1`.
   - AC: rejects any file whose e_ident[EI_MAG] != {0x7f, E, L, F}.
   - Touching: `src/kernel/core/loader/elf_lite.pdx` (new).
   - Encoder gaps: none.
   - Prereq: 2.

5. **`r15-m1-005-elf-lite-load-into-aspace`** — For each PT_LOAD segment, allocate memsz/4KiB pages, copy filesz bytes from image, zero the rest, `aspace_map` into user aspace with translated flags.
   - AC: fixture loads shell.bin into a fresh user aspace, then dumps entry RIP.
   - AC: entry RIP matches `readelf -h` e_entry.
   - AC: attempting to load an ELF with a segment vaddr in high-half returns EINVAL.
   - Touching: `src/kernel/core/loader/elf_lite.pdx`.
   - Encoder gaps: `rep movsb` — verify present; if not, byte-loop workaround.
   - Prereq: 4, 1.

6. **`r15-m1-006-user-stack-alloc`** — Allocate `size_pages` frames, map at `0x7FFFFFFFF000 - size_pages*0x1000` in user aspace with R+W+U, no X, no G. Map a guard page below at `not present`.
   - AC: fixture calls `user_stack_alloc(aspace, 4)`, receives rsp = 0x7FFFFFFFF000.
   - AC: reading below the guard page from a fake ring-3 context triggers #PF.
   - Touching: `src/kernel/core/mm/user_stack.pdx` (new).
   - Encoder gaps: none.
   - Prereq: 1.

7. **`r15-m1-007-embed-shell-bin`** — Add `.incbin` (or paideia-as equivalent `@include_bytes`) of `build/user/shell.bin` into a kernel section `.rodata.userbin`.
   - AC: `nm build/kernel.elf | grep _shell_bin_start` shows the symbol.
   - AC: `_shell_bin_end - _shell_bin_start == wc -c < build/user/shell.bin`.
   - Touching: `src/kernel/boot/userbin_embed.pdx` (new), `tools/build.sh` (order deps).
   - Encoder gaps: `@include_bytes` — verify or escalate PA-R15-001.
   - Prereq: 3.

8. **`r15-m1-008-loader-smoke-fixture`** — New mode `boot_r14b_loader` — creates a user aspace, loads embedded shell.bin, prints `LOADER OK entry=<hex> rsp=<hex>`, halts before iretq (that's Subsystem 5).
   - AC: fingerprint matches expected file.
   - AC: 3/3 reps green.
   - Touching: `src/kernel/boot/loader_smoke.pdx`, `tests/r14b/expected-boot-r14b-loader.txt`.
   - Encoder gaps: none.
   - Prereq: 1, 5, 6, 7.

9. **`r15-m1-009-aspace-teardown`** — `aspace_teardown(aspace)` walks the user PML4, releases every frame mapped with U-bit set, releases page-table pages, releases pml4.
   - AC: create + teardown 100 aspaces in a loop; `phys_alloc.free_count` returns to initial value.
   - AC: fixture prints `TEARDOWN OK`.
   - Touching: `src/kernel/core/mm/aspace_teardown.pdx` (new).
   - Encoder gaps: none.
   - Prereq: 1, 6.

### C. Testing strategy

- **Smoke modes.** New `boot_r14b_loader` witnesses aspace + ELF load. Existing 5 unaffected.
- **paideia-as canary.** `rep movsb` (or byte-loop workaround), `@include_bytes`.
- **Userland test.** shell.bin is the first user binary but doesn't execute yet — it's only a byte-level payload.

### D. Cross-subsystem dependencies

- **Depends on:** Subsystem 2 (KPTI for user pml4 construction).
- **Depended on by:** 5 (iretq needs entry_rip + initial_rsp), 8 (process abstraction wraps aspace), 9 (fork clones aspace, exec calls into loader).

---

## Subsystem 5 — Ring-3 transition primitive: iretq to user text (R15.M2)

### A. Design contract

**Responsibility.** Build the initial iretq frame (SS, RSP, RFLAGS, CS, RIP) on the kernel stack, then `iretq` to transition into ring 3 for the first time. This is the one-shot bring-up path; subsequent returns to user use sysretq.

**Invariants.**
- SS = user data selector (0x23 with RPL=3).
- CS = user code selector (0x2B with RPL=3).
- RFLAGS with IF=1 (interrupts on), no other flags asserted.
- RSP = initial user rsp from loader.
- RIP = entry_rip from loader.
- CR3 must be user pml4 before iretq.
- swapgs must precede iretq so user code sees user GS_BASE (undefined at first entry — set to 0).

**Primary interfaces.**

```
enter_userland_initial : (entry_rip: u64, initial_rsp: u64, user_pml4_pa: u64) -> !
                        // never returns; iretq
```

**Failure modes.**
- CS/SS with wrong RPL → #GP on iretq.
- RIP not in user aspace → #PF as first instruction fault.
- Missing CR3 flip → user tries to execute kernel VA → #PF.

**State machine.** Not applicable; one-shot function.

### B. Issue list

1. **`r15-m2-001-user-selector-constants`** — Pin USER_CS (0x2B) and USER_SS (0x23) constants in `src/kernel/core/int/gdt_selectors.pdx`. Verify GDT layout matches (already done at slot 5/6 for user code/data with RPL=3 setting).
   - AC: constants match hex breakdown (0x28 | 3 = 0x2B).
   - AC: build + 5-mode smoke pass.
   - Touching: `src/kernel/core/int/gdt_selectors.pdx` (new).
   - Encoder gaps: none.
   - Prereq: none.

2. **`r15-m2-002-user-text-page-mapping`** — Verify Subsystem 4's aspace_map calls set U=1 for user text pages; add a fixture that reads page-flag bits from the walker to confirm.
   - AC: fixture prints `U=1 W=0 NX=0` for shell.bin's text pages.
   - AC: `U=1 W=1 NX=1` for user stack pages.
   - Touching: `src/kernel/boot/pageflag_check.pdx` (fixture only).
   - Encoder gaps: none.
   - Prereq: Subsystem 4 issue 5.

3. **`r15-m2-003-iretq-frame-builder`** — Function that pushes SS, RSP, RFLAGS, CS, RIP onto current kernel stack in the exact iretq-expected order.
   - AC: `objdump -d` shows 5 pushes.
   - AC: annotated with `justification` explaining the SDM frame order.
   - Touching: `src/kernel/core/syscall/iretq_enter.pdx` (new).
   - Encoder gaps: none.
   - Prereq: 1.

4. **`r15-m2-004-tss-rsp0-preload`** — Before iretq, ensure TSS.rsp0 points at kernel stack top so subsequent syscalls have somewhere to switch to. TSS.rsp0 is already loaded in ltr flow (Subsystem 6 will finish it); this issue is the audit that it's set.
   - AC: rdmsr / peek shows TSS.rsp0 == &_syscall_kernel_stack + 16384.
   - Touching: `src/kernel/core/int/tss.pdx` (audit / assert).
   - Encoder gaps: none.
   - Prereq: none (TSS already installed via r13-m4-002).

5. **`r15-m2-005-enter-userland-initial`** — Full body: (a) mov cr3, user_pml4_pa; (b) swapgs; (c) build iretq frame with args; (d) iretq.
   - AC: `objdump -d enter_userland_initial` shows the exact instruction sequence.
   - AC: after invocation (in a fixture that does NOT return), execution appears to leave ring 0.
   - AC: qemu `-d int` trace shows CS=0x2B on iretq exit.
   - Touching: `src/kernel/core/syscall/iretq_enter.pdx`.
   - Encoder gaps: `iretq` — verify present (SDM opcode `48 CF`); if absent, escalate PA-R15-002.
   - Prereq: 3, 4.

6. **`r15-m2-006-first-user-ret-target`** — Design + implement a minimal user _start that does one thing: `mov rax, 12; mov rdi, ptr; mov rsi, N; syscall; hlt`. Puts a byte string on serial via sys_debug_puts (already ID 12).
   - AC: `boot_r15_ring3_hello` mode prints `RING3 HELLO` from user code (via sys_debug_puts).
   - AC: fingerprint file lands.
   - Touching: `src/user/hello_ring3.pdx` (new), `src/user/link.ld`, `tests/r15/expected-boot-r15-ring3-hello.txt`.
   - Encoder gaps: none.
   - Prereq: 5.

7. **`r15-m2-007-triple-fault-diagnostic-mode`** — QEMU flag `-no-reboot -no-shutdown -d int,cpu_reset` wrapped in a helper script `tools/qemu-tripleft-debug.sh` so any iretq mistake produces a trace instead of a silent reboot.
   - AC: script exists, invocable.
   - AC: intentionally-broken CS produces a documented cpu_reset trace.
   - Touching: `tools/qemu-tripleft-debug.sh`.
   - Encoder gaps: none.
   - Prereq: none.

### C. Testing strategy

- **Smoke modes.** New `boot_r15_ring3_hello` — first evidence of ring 3 executing.
- **Fingerprint.** `RING3 HELLO` after `LOADER OK`.
- **paideia-as canary.** `iretq` verify.
- **Userland test.** Yes — smallest possible ring-3 program.

### D. Cross-subsystem dependencies

- **Depends on:** Subsystem 4 (loader gives entry/rsp), Subsystem 2 (user pml4).
- **Depended on by:** 6 (once we return via sysret, we need MSRs), 7 (dispatch table catches the first user syscall), 9 (fork clones after first user), 17 (init lands via this path).

---

## Subsystem 6 — syscall/sysret ABI + STAR/LSTAR/FMASK MSR setup (R15.M3)

### A. Design contract

**Responsibility.** Set IA32_EFER.SCE, IA32_STAR, IA32_LSTAR, IA32_FMASK, IA32_KERNEL_GS_BASE so that SYSCALL from ring 3 transfers cleanly to `syscall_entry` with proper stack and CR3 flip, and SYSRET returns to ring 3.

**Invariants.**
- IA32_STAR[47:32] = 0x0008 (kernel CS = 0x08, kernel SS = 0x10 implied).
- IA32_STAR[63:48] = 0x001B (SYSRET selector base — actual user CS = base+16 = 0x2B, user SS = base+8 = 0x23).
- IA32_LSTAR = &syscall_entry.
- IA32_FMASK = TF|IF|DF|IOPL|NT|AC (0x47700) — masks these flags on SYSCALL entry.
- IA32_EFER.SCE = 1.
- IA32_KERNEL_GS_BASE = &_cpu_locals[0] (for swapgs to load).
- MSRs are written once at boot; not touched at runtime.

**Primary interfaces.**

```
syscall_msr_setup : () -> () !{sysreg} @{}
                    // idempotent, callable once at boot
```

Most of this is landed already (`src/kernel/core/syscall/msr.pdx`, r13-m5-001). Subsystem 6 is completion + verification, not from-scratch.

**Failure modes.**
- IA32_STAR miscalculation → SYSRET returns to CS=0x28 (kernel code!) → #GP.
- LSTAR pointing at low VA when kernel is higher-half → PF on first syscall.
- KERNEL_GS_BASE=0 → swapgs makes GS_BASE=0 → NULL deref in trampoline.

**State machine.** Not applicable.

### B. Issue list

1. **`r15-m3-001-msr-audit-post-higher-half`** — After Subsystem 1, verify LSTAR value is a higher-half VA (not low VA).
   - AC: `rdmsr(IA32_LSTAR)` returns 0xFFFF8000-something.
   - AC: fixture prints `LSTAR OK`.
   - Touching: `src/kernel/core/syscall/msr.pdx` (assert / audit).
   - Encoder gaps: none.
   - Prereq: Subsystem 1.

2. **`r15-m3-002-star-selector-audit`** — Verify IA32_STAR is 0x001B_0008_0000_0000.
   - AC: read-back matches expected literal.
   - AC: audit note in `design/audit/entries/r15-m3-002-star.md`.
   - Touching: audit only.
   - Encoder gaps: none.
   - Prereq: none.

3. **`r15-m3-003-kernel-gs-base-init`** — Ensure IA32_KERNEL_GS_BASE = &_cpu_locals[0] at boot. Delta from r13-m5-001 (which pointed at `_cpu0_kernel_gs`, a 64-byte stub).
   - AC: `rdmsr(IA32_KERNEL_GS_BASE)` returns &_cpu_locals[0].
   - AC: swapgs in syscall_entry lands GS_BASE at the cpu_local struct.
   - Touching: `src/kernel/core/syscall/msr.pdx`, `src/kernel/core/cpu/local.pdx`.
   - Encoder gaps: none.
   - Prereq: Subsystem 3 issue 1.

4. **`r15-m3-004-sysret-canonical-sanity`** — Check IA32_LSTAR is canonical (bit 47 sign-extended to bit 63). If not, SYSCALL raises #GP.
   - AC: build-time or boot-time assert.
   - AC: fixture logs `LSTAR CANONICAL OK`.
   - Touching: `src/kernel/core/syscall/msr.pdx`.
   - Encoder gaps: none.
   - Prereq: 1.

5. **`r15-m3-005-syscall-entry-slow-path-audit`** — Trace a syscall from ring 3 (via subsystem 5 test) end-to-end: swapgs, save user rsp, load kernel rsp, push rcx/r11/rax, shuffle, cr3 flip, call dispatch, restore, cr3 flip, swapgs, sysretq.
   - AC: `qemu -d cpu` trace at first syscall shows CS transitions 0x2B → 0x08 → 0x2B.
   - AC: sys_debug_puts round-trip from ring 3 prints message.
   - Touching: none (audit only).
   - Encoder gaps: none.
   - Prereq: Subsystem 5 issue 6.

6. **`r15-m3-006-fmask-if-audit`** — Verify FMASK masks IF, so kernel executes interrupts disabled on syscall entry. Explicit `sti` in dispatch if we want interrupt-friendly kernel; leave off for R14B (no in-kernel blocking yet).
   - AC: `rdmsr(IA32_FMASK)` returns 0x47700.
   - AC: syscall trace shows IF=0 during dispatch.
   - Touching: `src/kernel/core/syscall/msr.pdx` (audit).
   - Encoder gaps: none.
   - Prereq: none.

### C. Testing strategy

- **Smoke modes.** Same `boot_r15_ring3_hello` mode from Subsystem 5 exercises this.
- **Fingerprint.** No new tags in default flow; audit runs at boot in a debug mode.
- **paideia-as canary.** None.
- **Userland test.** hello_ring3.pdx already invokes sys_debug_puts.

### D. Cross-subsystem dependencies

- **Depends on:** Subsystem 1 (higher-half — LSTAR), Subsystem 3 (cpu_local).
- **Depended on by:** 5 (sysret returns after syscall), 7 (dispatch table sits under syscall_entry), all subsystems 8–20 (rely on syscall as their kernel/user boundary).

---

## Subsystem 7 — Syscall dispatch table (kernel-side) (R15.M4)

### A. Design contract

**Responsibility.** Extend `syscall_dispatch` from R13's 13-entry §C table to a §C+ table that covers the shell demo: `sys_exit`, `sys_yield`, `sys_read`, `sys_write`, `sys_open`, `sys_close`, `sys_dup2`, `sys_fork`, `sys_execve`, `sys_wait`, `sys_getpid`, `sys_debug_puts`, `sys_cap_invoke`. Migrate from linear cmp/je chain to a dispatch-table (indirect through a `_syscall_handler_table[N]`) once the table exceeds ~16 entries.

**Invariants.**
- Bounds check first: `cmp rax, SYS_NR; jae dispatch_enosys`.
- Table entries are function pointers; NULL entry returns ENOSYS.
- Argument shuffle happens once in `syscall_entry`; handlers see SysV C ABI.
- Handlers document effect widening (`!{mem, sysreg} @{fs, cap, sched, mem}`) — the union bounds the syscall trampoline's effect signature.

**Primary interfaces.**

```
_syscall_handler_table : @align(64) [SYS_NR]fn(u64,u64,u64,u64,u64) -> u64
syscall_dispatch       : (sysno, a0, a1, a2, a3) -> u64
```

**Failure modes.**
- Out-of-bounds sysno → return ENOSYS.
- NULL entry → return ENOSYS.
- Handler returns negative → propagate as errno.

**State machine.** Not applicable.

### B. Issue list

1. **`r15-m4-001-syscall-table-freeze-sc-plus`** — Amend `design/kernel/syscall-table-c-plus.md` freezing IDs 0–20 with the shell-demo minimum. Governance step; no code.
   - AC: doc lands.
   - AC: issue-body audit rule (per r13-retro (a)) verified: every downstream issue in this plan references the frozen ID.
   - Touching: `design/kernel/syscall-table-c-plus.md`.
   - Encoder gaps: none.
   - Prereq: none.

2. **`r15-m4-002-syscall-handler-table-array`** — Replace linear cmp/je with `_syscall_handler_table[SYS_NR]` at 8-byte entries. Populate entries for landed handlers; NULL for stubs.
   - AC: `objdump -s -j .data build/kernel.elf | grep -A4 _syscall_handler_table` shows the table.
   - AC: `syscall_dispatch` shrinks to `lea r10, [rip+_syscall_handler_table]; call [r10+rax*8]` pattern.
   - AC: existing sys_yield, sys_cap_invoke, sys_debug_puts still work.
   - Touching: `src/kernel/core/syscall/dispatch.pdx`, `src/kernel/core/syscall/table.pdx`.
   - Encoder gaps: `call qword ptr [reg+reg*8]` — indirect call via SIB. Verify or escalate PA-R15-003.
   - Prereq: 1.

3. **`r15-m4-003-sys-exit-handler`** — Wire `sys_exit(status) -> !`: calls `process_exit(current_task, status)`. Never returns.
   - AC: syscall from ring 3 with rax=0 kills current process.
   - Touching: `src/kernel/core/syscall/handlers/sys_exit.pdx` (new).
   - Encoder gaps: none.
   - Prereq: 2, Subsystem 8 (task_struct).

4. **`r15-m4-004-sys-write-handler-tty-only`** — Wire `sys_write(fd, buf, count)`: R14B path — only fd 1 / 2 wired to `uart_puts`. Full VFS path in Subsystem 13.
   - AC: sys_write(1, "hi", 2) puts "hi" on serial.
   - AC: sys_write(3, ..) returns EBADF.
   - AC: user pointer validity: reject buf if `buf ≥ 0xFFFF800000000000` (kernel VA) with EFAULT.
   - Touching: `src/kernel/core/syscall/handlers/sys_write.pdx`.
   - Encoder gaps: none.
   - Prereq: 2.

5. **`r15-m4-005-sys-read-handler-tty-only`** — Wire `sys_read(fd, buf, count)`: only fd 0 → tty RX ring. Full VFS in Subsystem 13.
   - AC: sys_read(0, buf, 1) blocks until UART RX has a byte, then returns 1.
   - AC: EBADF for fd > 0 (until Subsystem 13 completes).
   - Touching: `src/kernel/core/syscall/handlers/sys_read.pdx`.
   - Encoder gaps: none.
   - Prereq: 2, Subsystem 14 (UART RX), Subsystem 15 (TTY).

6. **`r15-m4-006-sys-getpid-handler`** — `sys_getpid()`: returns current_task->pid.
   - AC: init returns 1; child of fork returns 2, 3, ...
   - Touching: `src/kernel/core/syscall/handlers/sys_getpid.pdx`.
   - Encoder gaps: none.
   - Prereq: Subsystem 8.

7. **`r15-m4-007-syscall-arg-validation-pointer-fault`** — Helper `user_ptr_ok(va, len)` that (a) checks va < 0xFFFF800000000000, (b) walks user pml4 to confirm mapping. Called by every syscall that takes a user pointer.
   - AC: bad pointer syscall returns EFAULT.
   - AC: fixture invokes `sys_write(1, 0xFFFFFFFFFFFFFFFF, 4)` → -14.
   - Touching: `src/kernel/core/syscall/ptr_check.pdx`.
   - Encoder gaps: none.
   - Prereq: 2.

8. **`r15-m4-008-syscall-enosys-audit`** — All still-stubbed syscalls (dup2, open, close, fork, execve, wait) return ENOSYS explicitly; each has an audit entry naming the milestone that lands the real handler.
   - AC: `syscall_test` fixture invokes each stub, prints `ID N -> -38`.
   - AC: audit doc entries lined up.
   - Touching: audit docs; `src/kernel/core/syscall/dispatch.pdx`.
   - Encoder gaps: none.
   - Prereq: 2.

### C. Testing strategy

- **Smoke modes.** `boot_r15_syscall_dispatch` — fixture invokes each syscall from ring 3 and records return.
- **Fingerprint.** `DISPATCH: exit=OK write=OK read=OK ...`.
- **paideia-as canary.** Indirect call via SIB — potential PA-R15-003.

### D. Cross-subsystem dependencies

- **Depends on:** Subsystem 6 (syscall entry).
- **Depended on by:** 8, 9 (fork/exec/wait need handlers), 13 (fd table wired via handlers), 14 (RX read via handler), 15 (TTY plumbing), 16 (libc-lite wraps).

---

## Subsystem 8 — Process abstraction: task_struct, PID allocator, fd table skeleton (R15.M5)

### A. Design contract

**Responsibility.** Define `task_struct` layout, PID allocator, task lifecycle (new → runnable → running → blocked → zombie → reaped). Reserve fd table slots but keep tty as the only backing target.

**Invariants.**
- `task_struct` size ≤ 4 KiB (fits in a page for slab allocation).
- Fields pinned by offset for asm access (paideia-as does not yet have struct-field syntax across .pdx modules).
- pid_table[0] = NULL sentinel; pid_table[1] = init.
- Every runnable task appears in exactly one runqueue slot.
- Fields:
  ```
    0: pid : u32
    4: parent_pid : u32
    8: state : u32  (0=new,1=runnable,2=running,3=blocked,4=zombie)
   12: exit_status : u32
   16: user_pml4_pa : u64
   24: kernel_stack : u64
   32: regs_save : [15]u64  (callee-saved + rsp)
  152: sched_next : *task
  160: sched_budget : u64
  168: fd_table[64]{vnode_ptr:u64, offset:u64, flags:u32, refcount:u32}  = 1536 bytes
 1704: wait_child_pid : u32
 1708: wait_reply_slot : u32
 1712: reserved : [512]u8
 2224: total struct size (rounded to 4KiB)
  ```

**Primary interfaces.**

```
task_new         : (parent: *task) -> *task !{mem} @{}
task_free        : (*task) -> ()   !{mem} @{}
pid_alloc        : () -> u32       !{mem} @{}
pid_free         : (pid: u32) -> () !{mem} @{}
current_task     : () -> *task     !{sysreg} @{}   // via gs
fd_alloc         : (t: *task) -> i32 !{mem} @{}
fd_set           : (t: *task, fd: i32, vn: *vnode) -> () !{mem} @{}
```

**Failure modes.**
- pid_alloc: no free slots → -EAGAIN (rare at MAX_PIDS=64; extend later).
- fd_alloc: no free slots → -EMFILE.
- task_new: no free frame for pml4 → -ENOMEM.

**State machine.** (new) → runnable (by fork/exec) → running (by scheduler pick) → blocked (by sys_read/wait) → runnable (by wake) → running → ... → zombie (by sys_exit) → reaped (by parent's sys_wait).

### B. Issue list

1. **`r15-m5-001-task-struct-layout-freeze`** — Freeze offsets in `design/kernel/task-struct-layout.md`. Reference document; asm code and paideia-as sources refer to symbolic constants.
   - AC: doc lands with byte-perfect layout and total size.
   - Touching: `design/kernel/task-struct-layout.md`.
   - Encoder gaps: none.
   - Prereq: none.

2. **`r15-m5-002-task-slab`** — Static `_task_pool[MAX_TASKS=64]` in `.bss`, aligned 4KiB, each entry 4KiB.
   - AC: pool exists; sizeof matches doc.
   - AC: task_new returns a distinct pointer per call, monotonically for a fresh boot.
   - Touching: `src/kernel/core/sched/task_pool.pdx`.
   - Encoder gaps: `@align(4096)` on mutable table — verify.
   - Prereq: 1.

3. **`r15-m5-003-pid-alloc-dense-lowest`** — Linear scan of pid_table[1..MAX_PIDS] for first NULL slot.
   - AC: 3 sequential calls after boot return 1, 2, 3.
   - AC: after pid_free(2), next call returns 2.
   - Touching: `src/kernel/core/sched/pid_alloc.pdx`.
   - Encoder gaps: none.
   - Prereq: 2.

4. **`r15-m5-004-current-task-getter`** — `current_task()` = `cpu_local_get()->current_tcb_ptr`. Uses subsystem 3's workaround until PA-R14-001 clears.
   - AC: called from any point returns the currently-running task.
   - AC: after scheduler switch, updated value returned.
   - Touching: `src/kernel/core/sched/current.pdx`.
   - Encoder gaps: none.
   - Prereq: Subsystem 3 issue 3.

5. **`r15-m5-005-task-state-machine`** — Enum + transitions with `justification` string.
   - AC: illegal transition (e.g. zombie → running) triggers `panic("bad task state transition")`.
   - AC: audit doc lists all legal transitions.
   - Touching: `src/kernel/core/sched/task_state.pdx`.
   - Encoder gaps: none.
   - Prereq: 1.

6. **`r15-m5-006-task-new-real`** — Body of task_new: alloc pid, alloc slab, zero, task_pool[pid] = &slab, populate parent_pid + state.
   - AC: task_new(init) returns a valid task with pid 1.
   - AC: fresh task has state=new.
   - Touching: `src/kernel/core/sched/task_pool.pdx`.
   - Encoder gaps: `rep stosb` — for zeroing; verify.
   - Prereq: 2, 3, 5.

7. **`r15-m5-007-fd-table-embed`** — fd_table lives at fixed offset in task_struct; fd_alloc / fd_set / fd_get one-liners.
   - AC: fd_alloc after boot returns 3 (fds 0/1/2 reserved).
   - AC: fd_set(t, 5, vn) then fd_get(t, 5) returns vn.
   - Touching: `src/kernel/core/fs/fd_table.pdx`.
   - Encoder gaps: none.
   - Prereq: 1.

8. **`r15-m5-008-task-free-real`** — Body of task_free: teardown aspace, free pid slot, zero slab, close all fds.
   - AC: create 100 tasks in a loop, free each; pid slot 1 always available for the next allocation after freeing.
   - Touching: `src/kernel/core/sched/task_pool.pdx`.
   - Encoder gaps: none.
   - Prereq: 6, Subsystem 4 issue 9 (aspace_teardown).

9. **`r15-m5-009-smoke-process-mode`** — `boot_r15_process` fingerprint `TASK pool ok pids=1,2,3`.
   - AC: 3/3 reps green.
   - Touching: `tests/r15/expected-boot-r15-process.txt`.
   - Encoder gaps: none.
   - Prereq: 6, 7.

### C. Testing strategy

- **Smoke modes.** `boot_r15_process` witnesses task pool + pid alloc + fd table.
- **Fingerprint.** As above.
- **Userland test.** Not yet.

### D. Cross-subsystem dependencies

- **Depends on:** Subsystem 3 (cpu_local for current_task).
- **Depended on by:** 9 (fork/exec/wait manipulate task_struct), 10 (scheduler picks tasks), 11–15 (fd table backs VFS+TTY).

---

## Subsystem 9 — fork / exec / wait / _exit (R15.M6)

### A. Design contract

**Responsibility.** Implement the POSIX-lite process primitives on top of Subsystem 8. `fork` = clone aspace (COW), clone fd table (refcount++), clone task_struct. `execve` = replace aspace with a fresh loader result, keep pid + fds (with FD_CLOEXEC respected). `wait` = block current task until any child exits, return child pid + exit_status. `_exit` = mark zombie, wake parent's KIND_REPLY.

**Invariants.**
- COW: after fork, all writable pages in child aspace are marked R-only in both parent and child until one writes; PF handler splits (copy).
- fd sharing: fork increments fd_table entry refcounts in child; exec closes CLOEXEC fds.
- wait model: on _exit, child's exit_status is stored in `zombie_slot[pid]`; parent's wait consumes.
- Single-CPU: no COW race (only one CPU executes at a time). Multicore: needs spinlock — R15.M6 code carries `// TODO(SMP)` and `TODO(PA-R13-012)` markers.

**Primary interfaces.**

```
sys_fork    : () -> i64  // returns child pid to parent, 0 to child
sys_execve  : (path: ptr, argv: ptr, envp: ptr) -> i64  // -1 on error, no return on success
sys_wait    : (status_out: ptr) -> i64  // child pid or -ECHILD
sys_exit    : (status: i32) -> !
```

**Failure modes.**
- fork ENOMEM if aspace clone fails.
- execve ENOENT if path not in VFS.
- wait -ECHILD if no children.
- exit always succeeds.

**State machine.** In terms of task: (running) --sys_exit--> (zombie) --wait--> (reaped/freed).

### B. Issue list

1. **`r15-m6-001-aspace-clone-cow`** — `aspace_clone_cow(src_pml4, dst_pml4)`: walk src, for each mapped page mark it R-only in src, insert same phys R-only in dst.
   - AC: after clone, both aspaces read from same phys.
   - AC: writing from src triggers PF (Subsystem 9 issue 2 handles it).
   - Touching: `src/kernel/core/mm/aspace_clone.pdx`.
   - Encoder gaps: none.
   - Prereq: Subsystem 4.

2. **`r15-m6-002-pf-handler-cow-split`** — Real body of `pf_handler` (currently stub `panic_trace.pdx`): on write PF to R-only page with COW flag, alloc fresh frame, copy, remap R+W in the faulting aspace, invlpg, iretq.
   - AC: fixture forks, child writes; parent reads original value; child reads new.
   - AC: qemu -d int trace shows one PF, then normal execution resumes.
   - Touching: `src/kernel/core/mm/pf_handler.pdx`.
   - Encoder gaps: none.
   - Prereq: 1, Subsystem 3 issue 4 (tlb_shootdown_local).

3. **`r15-m6-003-sys-fork`** — Real body: task_new(current), aspace_clone_cow, fd_table_clone (refcount++), sched_enqueue(child), return child pid.
   - AC: fixture forks; parent gets pid > 0, child gets 0.
   - AC: 100 forks in a loop don't exhaust pid pool if `wait` is called between.
   - Touching: `src/kernel/core/syscall/handlers/sys_fork.pdx`.
   - Encoder gaps: none.
   - Prereq: 1, Subsystem 8.

4. **`r15-m6-004-sys-execve`** — Real body: elf_lite_load(current->aspace, image_bytes), reset regs_save, set entry_rip + initial_rsp, close CLOEXEC fds, return via sysret to new user rip.
   - AC: fixture forks, child execves shell.bin, child now runs shell code.
   - AC: fds 0/1/2 still open after exec.
   - Touching: `src/kernel/core/syscall/handlers/sys_execve.pdx`.
   - Encoder gaps: none.
   - Prereq: Subsystem 4 issue 5.

5. **`r15-m6-005-sys-wait`** — Real body: scan children (parent_pid == current->pid); if any zombie, reap + return {pid, status}; else set current->state = blocked, current->wait_reply_slot = <cap slot>, kind_reply wait.
   - AC: fixture forks child that immediately _exits(42); parent waits, receives (child_pid, 42).
   - AC: no children → -ECHILD.
   - Touching: `src/kernel/core/syscall/handlers/sys_wait.pdx`.
   - Encoder gaps: none.
   - Prereq: 3.

6. **`r15-m6-006-sys-exit`** — Real body: current->state = zombie, current->exit_status = status, if parent waiting reply-cap signal parent, else defer.
   - AC: exit propagates status to parent via wait.
   - AC: fds released.
   - Touching: `src/kernel/core/syscall/handlers/sys_exit.pdx`.
   - Encoder gaps: none.
   - Prereq: 5.

7. **`r15-m6-007-orphan-adoption-by-init`** — On task_free of parent, walk task_pool, reparent children to init (pid 1).
   - AC: fixture: A forks B, B forks C, A exits; C's parent_pid is now 1.
   - Touching: `src/kernel/core/sched/task_free.pdx`.
   - Encoder gaps: none.
   - Prereq: 6.

8. **`r15-m6-008-cow-refcount-frame-metadata`** — Extend phys_alloc to store refcount per frame in a `_frame_meta[NUM_FRAMES]` array.
   - AC: refcount visible in fixture that forks, then increment observed.
   - AC: frame not freed until refcount==0.
   - Touching: `src/kernel/core/mm/phys_alloc.pdx`, `src/kernel/core/mm/frame_meta.pdx` (new).
   - Encoder gaps: none.
   - Prereq: none.

9. **`r15-m6-009-fork-exec-wait-smoke`** — `boot_r15_forkexec` mode: init forks, child execs a "child_hello" binary that prints `CHILD HELLO N` and exits N; parent waits and prints `WAIT: pid=child status=N`.
   - AC: fingerprint `CHILD HELLO 42\nWAIT: pid=2 status=42`.
   - Touching: `src/user/child_hello.pdx`, tests fingerprint file.
   - Encoder gaps: none.
   - Prereq: 3, 4, 5, 6.

10. **`r15-m6-010-fork-exec-wait-audit-multicore-notes`** — Audit doc lists every place that would race under Path A. Each site carries `TODO(PA-R13-012)` and estimates the diff.
    - AC: audit doc lands.
    - Touching: `design/audit/entries/r15-m6-010-fork-multicore.md`.
    - Encoder gaps: none.
    - Prereq: all above.

### C. Testing strategy

- **Smoke modes.** `boot_r15_forkexec` — the first real process demo.
- **Fingerprint.** `CHILD HELLO 42\nWAIT: pid=2 status=42`.
- **paideia-as canary.** None new.

### D. Cross-subsystem dependencies

- **Depends on:** 4 (loader), 8 (task_struct), 11 (VFS for `execve`'s path resolution — but R15.M6 can hard-code /init/shell.bin from embedded userbin until VFS lands).
- **Depended on by:** 17 (init forks shell), 18 (shell forks child).

---

## Subsystem 10 — Scheduler: cooperative → timer-preemptive (R15.M7)

### A. Design contract

**Responsibility.** Round-robin all runnable tasks at fixed 10 ms timeslice. Idle task when nothing runnable. LAPIC timer at 100 Hz drives preemption.

**Invariants.**
- Runqueue is a doubly-linked list of task_struct pointers indexed by priority bit 8 (all same priority for MVP).
- `pick_next()` never returns NULL — falls back to idle task.
- Task state transitions atomic w.r.t. interrupt (cli/sti or per-CPU-lock — Path A).
- On timer tick, if `current->sched_budget == 0`, sched_switch to next.
- Yield paths: budget-exhaust, blocking-on-RX, blocking-on-wait.

**Primary interfaces.**

```
sched_enqueue    : (t: *task) -> ()   !{mem} @{sched}
sched_dequeue    : (t: *task) -> ()   !{mem} @{sched}
sched_pick_next  : () -> *task        !{mem} @{sched}
sched_switch     : (from: *task, to: *task) -> () !{mem, sysreg} @{sched}
sched_yield      : () -> ()           !{mem, sysreg} @{sched}   // already exists
sched_block      : (reason: u32) -> () !{mem} @{sched}
sched_wake       : (t: *task) -> ()   !{mem} @{sched}
```

**Failure modes.**
- pick_next never returns NULL — idle guarantees it.
- switching to a task with an invalid regs_save → GP on iretq/switch — caught by pre-write consistency check.

**State machine.** Task states from Subsystem 8; scheduler moves tasks between them.

### B. Issue list

1. **`r15-m7-001-idle-task-boot-init`** — Create task[0] at boot as the idle task, code = `1: hlt; jmp 1b`.
   - AC: after boot, sched_pick_next() returns idle when nothing else runnable.
   - AC: idle task consumes CPU when no other tasks.
   - Touching: `src/kernel/core/sched/idle.pdx`, kernel_main.
   - Encoder gaps: none.
   - Prereq: Subsystem 8.

2. **`r15-m7-002-runqueue-real`** — Replace r10's fixed 2-task alternation with a real linked list of runnable tasks.
   - AC: enqueue 5 tasks; pick_next in sequence returns each once, round-robin.
   - AC: dequeue removes from list.
   - Touching: `src/kernel/core/sched/runqueue.pdx`.
   - Encoder gaps: none.
   - Prereq: 1.

3. **`r15-m7-003-sched-switch-real`** — Save current->regs_save, load next->regs_save, jump to next->rip. Uses existing switch primitive but generalizes for arbitrary tasks (currently hardwired 2-task).
   - AC: switch from task A to task B and back; TASK A/B logs interleave.
   - Touching: `src/kernel/core/sched/switch.pdx`.
   - Encoder gaps: none.
   - Prereq: 2.

4. **`r15-m7-004-lapic-timer-100hz`** — Program LAPIC timer TSC-deadline at 10 ms intervals.
   - AC: `TICK` prints 100 times per second (approx; QEMU TCG determinism).
   - AC: existing r11 preemption fingerprint reproduces.
   - Touching: `src/kernel/core/apic/lapic_timer.pdx`.
   - Encoder gaps: none.
   - Prereq: none.

5. **`r15-m7-005-timer-isr-preempt`** — In timer ISR, if `current->sched_budget-- == 0`, sched_switch to pick_next.
   - AC: fixture: 3 tasks; each prints its id in a loop; output alternates roughly evenly.
   - Touching: `src/kernel/core/timer/lapic_isr.pdx`.
   - Encoder gaps: none.
   - Prereq: 3, 4.

6. **`r15-m7-006-sched-block-wake`** — sched_block(reason) removes current from runqueue and sets state=blocked. sched_wake(t) sets state=runnable and enqueues.
   - AC: fixture blocks a task; sched_pick_next skips it; wake makes it eligible again.
   - Touching: `src/kernel/core/sched/block_wake.pdx`.
   - Encoder gaps: none.
   - Prereq: 2.

7. **`r15-m7-007-yield-on-sys-read-empty`** — sys_read on empty tty RX ring calls sched_block(BLOCK_RX_EMPTY). Wake on interrupt-driven RX push.
   - AC: shell blocks on read; typing a key wakes it.
   - Touching: `src/kernel/core/syscall/handlers/sys_read.pdx`, Subsystem 14/15 hooks.
   - Encoder gaps: none.
   - Prereq: 6, Subsystem 14, 15.

8. **`r15-m7-008-scheduler-smp-ready-hooks`** — Every scheduler entry point uses `cpu_local_get()` for current, and per-CPU runqueue would sit at cpu_local + offset — leave the pointer set to a single global runqueue for R14B but structure the calls so switching to per-CPU is a symbol-swap.
   - AC: audit doc lists all runqueue accesses and confirms all go through the cpu_local pointer.
   - Touching: `src/kernel/core/sched/*.pdx`.
   - Encoder gaps: none.
   - Prereq: 2.

### C. Testing strategy

- **Smoke modes.** `boot_r15_sched_rr` — 3-task round-robin fingerprint.
- **Fingerprint.** `T1 T2 T3 T1 T2 T3 T1 T2 T3` (approx).
- **paideia-as canary.** None new.

### D. Cross-subsystem dependencies

- **Depends on:** 8, 3.
- **Depended on by:** 9 (fork enqueues child), 14 (RX wake blocked reader), 15 (TTY unblock on line-complete), 18 (shell blocks on stdin).

---

## Subsystem 11 — VFS: superblock/inode/dentry/vnode abstract layer (R16.M1)

### A. Design contract

**Responsibility.** Provide a generic VFS interface so `sys_open("/tmp/x")` resolves through mount points to a filesystem-specific inode. R14B has exactly one filesystem type (tmpfs) but the interface allows adding more without touching syscall handlers.

**Invariants.**
- Every path resolution walks dentries from root.
- `struct vnode` has function-pointer table `vops` for read/write/close.
- Mount table is static (`_mount_table[8]` slots).
- Root filesystem is tmpfs, mounted at `/`.

**Primary interfaces.**

```
vnode_ops : {
  read  : (vn, buf, count, offset) -> i64,
  write : (vn, buf, count, offset) -> i64,
  close : (vn) -> ()
}
vfs_open   : (path: ptr) -> *vnode
vfs_close  : (*vnode) -> ()
vfs_read   : (vn, buf, count, offset) -> i64
vfs_write  : (vn, buf, count, offset) -> i64
vfs_lookup : (dir: *vnode, name: ptr, name_len: u32) -> *vnode
vfs_create : (dir: *vnode, name: ptr, name_len: u32, mode: u32) -> *vnode
```

**Failure modes.**
- lookup miss → -ENOENT.
- create over existing → -EEXIST.
- read past EOF → 0 (POSIX semantics).

**State machine.** N/A per-vnode; refcount governs freeing.

### B. Issue list

1. **`r16-m1-001-vfs-vnode-struct-layout`** — Freeze layout in `design/kernel/vfs-layout.md`: 64 bytes per vnode.
   - AC: doc lands.
   - Touching: `design/kernel/vfs-layout.md`.
   - Encoder gaps: none.
   - Prereq: none.

2. **`r16-m1-002-vnode-slab`** — Static `_vnode_pool[VNODE_MAX=256]`.
   - AC: pool exists; alloc returns distinct.
   - Touching: `src/kernel/core/fs/vnode_pool.pdx`.
   - Encoder gaps: none.
   - Prereq: 1.

3. **`r16-m1-003-vops-function-pointer-table`** — Each vnode has vops pointer to a shared table (tmpfs_vops).
   - AC: fixture calls vn->vops->read; dispatches through pointer.
   - Touching: `src/kernel/core/fs/vops.pdx`.
   - Encoder gaps: `call qword ptr [reg+imm]` — verify.
   - Prereq: 2.

4. **`r16-m1-004-path-resolver`** — Split path on `/`, resolve component-by-component via vfs_lookup.
   - AC: `/tmp/x` → dentry.
   - AC: `//tmp//x` collapses.
   - AC: bad component → -ENOENT.
   - Touching: `src/kernel/core/fs/path.pdx`.
   - Encoder gaps: none.
   - Prereq: 3.

5. **`r16-m1-005-mount-table`** — Static `_mount_table[8]`; mount tmpfs at `/`.
   - AC: root vnode is tmpfs.
   - Touching: `src/kernel/core/fs/mount.pdx`.
   - Encoder gaps: none.
   - Prereq: 3.

6. **`r16-m1-006-vfs-open`** — Resolve path → alloc vnode wrapper if not cached → refcount++.
   - AC: two opens of same path return same vnode with refcount 2.
   - Touching: `src/kernel/core/fs/vfs_open.pdx`.
   - Encoder gaps: none.
   - Prereq: 4, 5.

7. **`r16-m1-007-vfs-close`** — refcount-- → if 0, vops->close.
   - AC: close pair with open leaves vnode refcount at 0.
   - Touching: `src/kernel/core/fs/vfs_close.pdx`.
   - Encoder gaps: none.
   - Prereq: 6.

8. **`r16-m1-008-vfs-read-write`** — Dispatch through vops.
   - AC: read/write against a tmpfs vnode round-trips bytes.
   - Touching: `src/kernel/core/fs/vfs_read.pdx`, `src/kernel/core/fs/vfs_write.pdx`.
   - Encoder gaps: none.
   - Prereq: 3, Subsystem 12.

9. **`r16-m1-009-vfs-smoke`** — `boot_r16_vfs` mode — create tmpfs vnode, write/read, close.
   - AC: fingerprint `VFS OK`.
   - Touching: tests fingerprint file.
   - Prereq: 6, 7, 8.

### C. Testing strategy

- **Smoke modes.** `boot_r16_vfs`.
- **Fingerprint.** `VFS OK`.
- **paideia-as canary.** Indirect call via mem.

### D. Cross-subsystem dependencies

- **Depends on:** 8 (fd table), 12 (tmpfs backend).
- **Depended on by:** 13 (fd table wired through vfs), 15 (TTY is a vnode too).

---

## Subsystem 12 — tmpfs: in-memory VFS backend (R16.M2)

### A. Design contract

**Responsibility.** Provide a purely in-memory filesystem backing `/` and `/tmp` for the shell demo. Files are byte arrays in a paged pool; directories are linked lists of dentries.

**Invariants.**
- All storage in kernel .bss (fixed-size pool).
- File max size 64 KiB (16 pages); dir max entries 64.
- No persistence across boot.
- tmpfs is the vops implementation for `_tmpfs_vops`.

**Primary interfaces.**

```
tmpfs_init          : () -> *vnode    // returns root vnode
tmpfs_read          : (vn, buf, count, off) -> i64
tmpfs_write         : (vn, buf, count, off) -> i64
tmpfs_close         : (vn) -> ()
tmpfs_lookup        : (dir, name, len) -> *vnode
tmpfs_create        : (dir, name, len, mode) -> *vnode
```

**Failure modes.**
- Out of pool → -ENOSPC.
- Write past 64 KiB → truncate/-EFBIG.

**State machine.** N/A per-file.

### B. Issue list

1. **`r16-m2-001-tmpfs-inode-pool`** — `_tmpfs_inode_pool[TMPFS_MAX=64]` with (type, size, page_ptrs[16], name[32], parent_ptr).
   - AC: pool declared.
   - Touching: `src/kernel/core/fs/tmpfs/inode.pdx`.
   - Encoder gaps: none.
   - Prereq: none.

2. **`r16-m2-002-tmpfs-root-init`** — Initialize root inode = directory, then `/tmp` as child.
   - AC: after init, `/tmp` resolves.
   - Touching: `src/kernel/core/fs/tmpfs/init.pdx`.
   - Prereq: 1.

3. **`r16-m2-003-tmpfs-lookup`** — Linear scan of directory's dentry list.
   - AC: lookup existing name returns inode; miss returns NULL.
   - Touching: `src/kernel/core/fs/tmpfs/lookup.pdx`.
   - Prereq: 2.

4. **`r16-m2-004-tmpfs-create`** — Alloc inode from pool, insert into parent's dentry list.
   - AC: create `/tmp/x`; subsequent lookup returns it.
   - Touching: `src/kernel/core/fs/tmpfs/create.pdx`.
   - Prereq: 3.

5. **`r16-m2-005-tmpfs-write`** — Allocate page(s) on first write; copy from user buf; update inode.size.
   - AC: write 100 bytes → inode.size == 100.
   - Touching: `src/kernel/core/fs/tmpfs/write.pdx`.
   - Encoder gaps: `rep movsb` for copy.
   - Prereq: 4.

6. **`r16-m2-006-tmpfs-read`** — Copy from inode's page(s) into user buf; respect offset + count.
   - AC: read after write returns same bytes.
   - AC: read past EOF returns 0.
   - Touching: `src/kernel/core/fs/tmpfs/read.pdx`.
   - Prereq: 5.

7. **`r16-m2-007-tmpfs-unlink`** — Not required for shell demo but useful. Release inode + pages.
   - AC: unlink → subsequent lookup miss.
   - Touching: `src/kernel/core/fs/tmpfs/unlink.pdx`.
   - Prereq: 5.

8. **`r16-m2-008-tmpfs-vops-wire`** — Populate `_tmpfs_vops` with pointers to the above.
   - AC: VFS operations through mount dispatch to tmpfs.
   - AC: `boot_r16_tmpfs` mode: create, write, read, close; print `TMPFS OK`.
   - Touching: `src/kernel/core/fs/tmpfs/vops.pdx`.
   - Prereq: 3, 5, 6.

### C. Testing strategy

- **Smoke modes.** `boot_r16_tmpfs`.
- **Fingerprint.** `TMPFS OK`.

### D. Cross-subsystem dependencies

- **Depends on:** 11 (VFS shape).
- **Depended on by:** 13 (fds pointing at tmpfs vnodes), 17 (init reads a config from /etc), 18 (shell tab-completes files).

---

## Subsystem 13 — fd table + open/read/write/close/dup2 (R16.M3)

### A. Design contract

**Responsibility.** Wire the per-task fd table to VFS operations. `sys_open` allocates lowest free fd; `sys_read/write` dispatches through vfs_read/write on the vnode; `sys_close` releases fd; `sys_dup2` copies fd entry to a target slot.

**Invariants.**
- fd 0/1/2 always TTY-backed after init.
- Refcount on vnode incremented when fd points to it, decremented on close.
- dup2(N, N) is a no-op.
- dup2(src, dst) closes dst first if it was open.

**Primary interfaces.**

```
sys_open  : (path, flags, mode) -> fd
sys_close : (fd) -> i64
sys_read  : (fd, buf, count) -> i64      // dispatches through vfs
sys_write : (fd, buf, count) -> i64      // dispatches through vfs
sys_dup2  : (src_fd, dst_fd) -> fd
```

**Failure modes.**
- EBADF: bad fd.
- EMFILE: no free fd slot.
- EFAULT: bad user pointer.

**State machine.** N/A.

### B. Issue list

1. **`r16-m3-001-sys-open-real`** — vfs_open(path), allocate fd, store vnode+offset in fd_table.
   - AC: sys_open("/tmp/x", O_CREAT|O_RDWR, 0644) returns 3.
   - AC: consecutive opens return 3, 4, 5.
   - Touching: `src/kernel/core/syscall/handlers/sys_open.pdx`.
   - Encoder gaps: none.
   - Prereq: Subsystem 11, 12.

2. **`r16-m3-002-sys-close-real`** — Release fd slot; vfs_close vnode.
   - AC: sys_close returns 0.
   - AC: after close, fd_table[fd].vnode_ptr == NULL.
   - Touching: `src/kernel/core/syscall/handlers/sys_close.pdx`.
   - Prereq: 1.

3. **`r16-m3-003-sys-read-through-vfs`** — Extend sys_read to handle fd > 2 via vfs_read.
   - AC: read from /tmp/x returns written bytes.
   - Touching: `src/kernel/core/syscall/handlers/sys_read.pdx`.
   - Prereq: 1.

4. **`r16-m3-004-sys-write-through-vfs`** — Extend sys_write to handle fd > 2 via vfs_write.
   - AC: write to /tmp/x persists; read back returns bytes.
   - Touching: `src/kernel/core/syscall/handlers/sys_write.pdx`.
   - Prereq: 1.

5. **`r16-m3-005-sys-dup2`** — Copy fd_table[src] to fd_table[dst] (close dst first if open).
   - AC: dup2(1, 5) then write(5, ..) writes to fd 1's target.
   - Touching: `src/kernel/core/syscall/handlers/sys_dup2.pdx`.
   - Prereq: 2.

6. **`r16-m3-006-fd-inherit-across-fork`** — In sys_fork, walk fd_table, refcount++ vnodes into child's slot.
   - AC: parent opens /tmp/x, forks, child reads same fd — sees same offset.
   - Touching: `src/kernel/core/syscall/handlers/sys_fork.pdx`.
   - Prereq: 2, Subsystem 9 issue 3.

7. **`r16-m3-007-fd-cloexec-on-exec`** — On execve, close fds marked FD_CLOEXEC.
   - AC: fd with CLOEXEC set is not inherited across execve.
   - Touching: `src/kernel/core/syscall/handlers/sys_execve.pdx`.
   - Prereq: 2, Subsystem 9 issue 4.

8. **`r16-m3-008-fd-smoke`** — `boot_r16_fd` mode — open /tmp/x, write, close, reopen, read; print `FD OK`.
   - AC: fingerprint.
   - Touching: tests file.
   - Prereq: all above.

### C. Testing strategy

- **Smoke modes.** `boot_r16_fd`.
- **Fingerprint.** `FD OK`.

### D. Cross-subsystem dependencies

- **Depends on:** 8, 11, 12.
- **Depended on by:** 15 (TTY becomes a vnode; init connects fd 0/1/2 to it), 16 (libc-lite wraps), 18 (shell opens files).

---

## Subsystem 14 — UART input driver (16550 RX interrupt-driven) (R16.M4)

### A. Design contract

**Responsibility.** Configure COM1 to raise IRQ on RX; ISR reads received byte into a kernel-side ring buffer; a KIND_NOTIFICATION cap fires when a byte is available. Line editing / cooking is Subsystem 15.

**Invariants.**
- UART Interrupt Enable Register (IER) bit 0 set (data available).
- IRQ 4 (COM1) routed through IOAPIC (or PIC on legacy path) to vector 0x24.
- RX ring is SPSC-safe on single-CPU (writer=ISR, reader=sys_read).
- Ring size 256 bytes.
- On overflow, oldest byte dropped (no back-pressure to sender at 115200 baud).

**Primary interfaces.**

```
uart_rx_init      : () -> ()          !{mem, sysreg}
uart_rx_isr       : () -> ()          !{mem, sysreg} @{}    // vector 0x24
uart_rx_read_nonblock : (buf, count) -> i64  !{mem}         // returns immediately, may be 0
uart_rx_available : () -> u64          !{mem}
```

**Failure modes.**
- RX overrun (LSR bit 1) → drop byte, increment counter.
- Framing/parity error → drop byte.

**State machine.** Ring: (empty) → (partial) → (full) → drop-oldest.

### B. Issue list

1. **`r16-m4-001-uart-rx-init`** — Set IER=0x01 on COM1; unmask IRQ 4.
   - AC: rdmsr / port read confirms IER=1.
   - Touching: `src/kernel/core/uart/rx_init.pdx`.
   - Encoder gaps: none.
   - Prereq: none.

2. **`r16-m4-002-uart-rx-ring`** — Static `_uart_rx_ring[256]` in .bss with head/tail indices.
   - AC: enqueue/dequeue round-trip preserves bytes.
   - Touching: `src/kernel/core/uart/rx_ring.pdx`.
   - Prereq: none.

3. **`r16-m4-003-uart-rx-isr`** — ISR body: while LSR.data_ready, read RBR, enqueue to ring; EOI.
   - AC: typing a character in qemu monitor stdin lands in ring.
   - Touching: `src/kernel/core/uart/rx_isr.pdx`.
   - Encoder gaps: none.
   - Prereq: 2.

4. **`r16-m4-004-idt-vector-24-wire`** — IDT slot 0x24 → uart_rx_isr trampoline (push state, call, iretq).
   - AC: idt dump shows vector 0x24 populated.
   - Touching: `src/kernel/core/int/idt.pdx`.
   - Prereq: 3.

5. **`r16-m4-005-ioapic-route-irq4`** — Program IOAPIC RTE for IRQ 4 → vector 0x24 on CPU 0.
   - AC: writing IOREGSEL / IOWIN sequence confirmed via peek.
   - Touching: `src/kernel/core/apic/ioapic.pdx`.
   - Encoder gaps: none.
   - Prereq: 4.

6. **`r16-m4-006-uart-rx-notification-cap`** — Wire uart_rx_isr to signal a KIND_NOTIFICATION cap; sys_read blocks on this cap when ring empty.
   - AC: fixture blocks; injected char wakes.
   - Touching: `src/kernel/core/uart/rx_notify.pdx`.
   - Prereq: 3, Subsystem 10 issue 6.

7. **`r16-m4-007-uart-rx-smoke`** — `boot_r16_uart_rx` mode: inject 3 chars via QEMU's `-serial mon:stdio` and receive them.
   - AC: fingerprint `UART RX: abc`.
   - Touching: fingerprint + `tools/run-smoke.sh` with `-serial pty` fixture.
   - Prereq: 3, 5.

### C. Testing strategy

- **Smoke modes.** `boot_r16_uart_rx` — first evidence of user input working.
- **Fingerprint.** `UART RX: abc` after injecting `abc`.
- **paideia-as canary.** IOAPIC MMIO write patterns.

### D. Cross-subsystem dependencies

- **Depends on:** 3 (IDT vector infrastructure).
- **Depended on by:** 15 (TTY reads from RX ring), 18 (shell reads via TTY).

---

## Subsystem 15 — TTY / cooked line discipline (R16.M5)

### A. Design contract

**Responsibility.** Wrap UART RX ring in a line discipline: buffer characters until '\n' or Ctrl-D, echo typed characters back to TX, handle backspace, deliver complete line to sys_read on fd 0.

**Invariants.**
- Line buffer is 256 chars per TTY.
- Echo happens byte-by-byte as chars arrive.
- `\r` from terminal is translated to `\n` (input); `\n` on output becomes `\r\n`.
- Backspace erases last char in buffer + emits `\b \b` for visual delete.
- Ctrl-D (0x04) at start of empty line → EOF (read returns 0).
- Ctrl-C (0x03) → send SIGINT (deferred to R17+; log-only in R14B).
- TTY is a vnode wired to fd 0/1/2 of init.

**Primary interfaces.**

```
tty_init          : () -> *vnode
tty_read          : (vn, buf, count, off) -> i64   // vops entry
tty_write         : (vn, buf, count, off) -> i64
tty_process_input : (byte) -> ()   // called from RX notification handler
```

**Failure modes.**
- Line buffer overflow → drop char + bell.

**State machine.** (idle) → (accumulating) → (complete-line-ready) → (reader-consuming) → (idle).

### B. Issue list

1. **`r15-m5-001-tty-vnode-alloc`** — Alloc a tty vnode at boot; store in `_tty0`.
   - AC: `_tty0` exists post-init.
   - Touching: `src/kernel/core/tty/init.pdx`.
   - Prereq: Subsystem 11.

2. **`r15-m5-002-tty-vops-table`** — tty_vops with read/write/close pointers.
   - AC: fixture vfs_open("/dev/tty0") returns _tty0.
   - Touching: `src/kernel/core/tty/vops.pdx`.
   - Prereq: 1.

3. **`r15-m5-003-line-buffer`** — Per-tty 256-char buffer with head/tail + complete-line flag.
   - AC: line buffer populated by ISR feed.
   - Touching: `src/kernel/core/tty/line_buffer.pdx`.
   - Prereq: 1.

4. **`r15-m5-004-tty-process-input-echo`** — For each byte: echo to TX, append to buffer, handle \r→\n, handle backspace.
   - AC: typing "hello\n" leaves buffer "hello\n" and echoes correctly.
   - Touching: `src/kernel/core/tty/process_input.pdx`.
   - Prereq: 3, Subsystem 14 issue 6.

5. **`r15-m5-005-tty-read-blocking`** — tty_read: if complete-line ready, copy to user buf; else block via KIND_NOTIFICATION.
   - AC: sys_read blocks; typing "hello\n" completes and returns 6 bytes.
   - Touching: `src/kernel/core/tty/read.pdx`.
   - Prereq: 4, Subsystem 10 issue 7.

6. **`r15-m5-006-tty-write-nl-cr-translate`** — On write, translate '\n' to '\r\n'.
   - AC: write("hi\n") emits "hi\r\n".
   - Touching: `src/kernel/core/tty/write.pdx`.
   - Prereq: 2.

7. **`r15-m5-007-connect-tty-to-init-fd012`** — In init bring-up, set task[1].fd_table[0/1/2] = tty0.
   - AC: init's sys_write(1, ..) goes through tty.
   - Touching: kernel_main / init bring-up.
   - Prereq: 5, 6.

8. **`r15-m5-008-tty-smoke`** — `boot_r16_tty` mode: inject "hello\n", read returns 6 bytes "hello\n", write "hi\n" produces "hi\r\n" on serial.
   - AC: fingerprint.
   - Touching: tests file.
   - Prereq: all above.

### C. Testing strategy

- **Smoke modes.** `boot_r16_tty`.
- **Fingerprint.** `TTY: hello\nHI: hi`.

### D. Cross-subsystem dependencies

- **Depends on:** 11, 14, 10.
- **Depended on by:** 17, 18.

---

## Subsystem 16 — libc-lite for userland (R17.M1)

### A. Design contract

**Responsibility.** Provide `.pdx` wrappers for syscalls so user code (`init.pdx`, `shell.pdx`) can call `write(fd, buf, count)` rather than emit raw syscall opcodes. Also provide minimal string ops (strlen, memcmp) since the shell tokenizer needs them.

**Invariants.**
- Every wrapper is a straight-line syscall trampoline: shuffle args, syscall, return rax.
- Errno lives in a per-thread `errno` (single-slot for now).
- No dynamic memory allocation in R17 libc-lite — shell uses caller-provided buffers.

**Primary interfaces (userland).**

```
write   : (fd, buf, count) -> i64
read    : (fd, buf, count) -> i64
open    : (path, flags, mode) -> i32
close   : (fd) -> i32
dup2    : (src, dst) -> i32
exit    : (status) -> !
fork    : () -> i32
execve  : (path, argv, envp) -> i32
wait    : (status_ptr) -> i32
getpid  : () -> i32

strlen  : (str) -> u64
memcmp  : (a, b, n) -> i32
memcpy  : (dst, src, n) -> ptr
strcmp  : (a, b) -> i32
```

**Failure modes.** Wrappers return -errno directly; no exceptions.

### B. Issue list

1. **`r17-m1-001-syscall-shim-extend`** — Extend `src/user/syscall_shim.pdx` from R13's 4 wrappers to all 13 syscalls in §C+.
   - AC: `build-user.sh` succeeds; each wrapper compiles to `mov rax, N; syscall; ret` after arg shuffle.
   - Touching: `src/user/syscall_shim.pdx`.
   - Encoder gaps: none.
   - Prereq: Subsystem 7.

2. **`r17-m1-002-user-strlen-memcmp`** — Byte-loop implementations in `src/user/string.pdx`.
   - AC: fixture calls strlen("hello") returns 5.
   - Touching: `src/user/string.pdx`.
   - Encoder gaps: none.
   - Prereq: none.

3. **`r17-m1-003-user-memcpy-memset`** — Byte-loop (rep movsb once encoder confirmed).
   - AC: memcpy round-trip byte-identical.
   - Touching: `src/user/string.pdx`.
   - Encoder gaps: `rep movsb`, `rep stosb` — verify or byte-loop.
   - Prereq: none.

4. **`r17-m1-004-user-errno-slot`** — Static `_user_errno : u64` in user .bss.
   - AC: on wrapper return < 0, set errno = -rax; return -1.
   - Touching: `src/user/errno.pdx`.
   - Prereq: 1.

5. **`r17-m1-005-user-puts-getline`** — puts(str) = write(1, str, strlen(str)). getline(buf, sz) = read(0, buf, sz).
   - AC: puts("hello") emits "hello" on serial.
   - Touching: `src/user/io.pdx`.
   - Prereq: 1, 2.

6. **`r17-m1-006-user-smoke-libc`** — User-side test binary `libc_test` that calls each wrapper; kernel-side fixture invokes it.
   - AC: fingerprint `LIBC TEST OK`.
   - Touching: `src/user/tests/libc_test.pdx`.
   - Prereq: all above.

### C. Testing strategy

- **Smoke modes.** `boot_r17_libc`.
- **Fingerprint.** `LIBC TEST OK`.

### D. Cross-subsystem dependencies

- **Depends on:** 7.
- **Depended on by:** 17, 18, 19, 20.

---

## Subsystem 17 — init process (ring-3, statically linked, execs shell) (R17.M2)

### A. Design contract

**Responsibility.** The first ring-3 process. pid=1. Its job:
1. Open /dev/tty0 as fd 0, 1, 2.
2. Fork a child.
3. In child: execve("/bin/sh").
4. In parent: infinite loop wait() for children; on any child exit, print `[init] pid=N status=M`; if sh exits, execve("/bin/sh") again OR trigger shutdown.

**Invariants.**
- init never itself exits (unless as a triggered shutdown path).
- init reaps all zombies (via wait loop).
- init is bit-identical across boots (embedded via `.incbin`).

**Primary interfaces.** Standalone binary; no exports.

**Failure modes.**
- If exec fails, init prints error and shuts down.

**State machine.** (init-boot) → (spawn-shell) → (wait-loop) → (reap+respawn OR shutdown on shell-exit).

### B. Issue list

1. **`r17-m2-001-init-source-and-linker`** — `src/user/init.pdx` + `src/user/init.ld` producing `build/user/init.bin`.
   - AC: build succeeds.
   - Touching: `src/user/init.pdx`, `src/user/init.ld`, `tools/build-user.sh` extended.
   - Prereq: Subsystem 16.

2. **`r17-m2-002-init-open-tty-fds`** — In init _start, open("/dev/tty0"), dup2 to 0, 1, 2.
   - AC: writes from init reach TTY.
   - Touching: `src/user/init.pdx`.
   - Prereq: Subsystem 13, 15.

3. **`r17-m2-003-init-fork-exec-shell`** — Fork; child execves "/bin/sh" (path resolves to embedded shell.bin loaded via a boot-time tmpfs seed).
   - AC: after init runs, sh's banner appears on serial.
   - Touching: `src/user/init.pdx`, boot-time tmpfs seed of /bin/sh.
   - Prereq: Subsystem 9, 12.

4. **`r17-m2-004-init-wait-loop-respawn`** — Parent loop: wait, log status, respawn shell OR shutdown.
   - AC: shell exit followed by init's shutdown path.
   - Touching: `src/user/init.pdx`.
   - Prereq: 3.

5. **`r17-m2-005-kernel-launch-init-bootstrap`** — kernel_main, after all subsystems init, task_new(init), load init.bin into it, enter_userland_initial with init's entry.
   - AC: `boot_r17_init` mode boots to init, which forks shell.
   - Touching: `src/kernel/boot/kernel_main.pdx`.
   - Prereq: 1, 2, Subsystem 5.

### C. Testing strategy

- **Smoke modes.** `boot_r17_init` — boot up to shell banner via init.
- **Fingerprint.** `PaideiaOS init v0.1\nPaideiaOS shell v0.1\n$ `.

### D. Cross-subsystem dependencies

- **Depends on:** 5, 9, 12, 13, 15, 16.
- **Depended on by:** 18 (shell is what init execs), 20 (integration harness drives through init).

---

## Subsystem 18 — Shell: reader → tokenizer → dispatch → builtin/child (R17.M3)

### A. Design contract

**Responsibility.** Interactive shell. Prints prompt `$ `, reads a line from fd 0 (TTY), tokenizes on whitespace, dispatches to builtin table or forks + execves child; waits for child; loops.

**Invariants.**
- Line buffer 256 bytes.
- Argv max 16 entries.
- Prompt is `$ ` (2 bytes).
- Empty line → reprompt.
- Ctrl-D (read returns 0) → exit cleanly.

**Primary interfaces.** Standalone binary.

**Failure modes.**
- Bad command → `sh: not found: <cmd>` on stderr.

**State machine.** (prompt) → (read-line) → (tokenize) → (dispatch) → (wait-child OR builtin exec) → (prompt).

### B. Issue list

1. **`r17-m3-001-shell-main-loop-skeleton`** — src/user/shell.pdx main loop: write prompt, read line, dispatch, loop.
   - AC: builds; runs to prompt; hangs on read.
   - Touching: `src/user/shell.pdx`.
   - Prereq: Subsystem 16, 17.

2. **`r17-m3-002-shell-line-reader`** — Wrapper around read(0, buf, 256) that stops at '\n' or EOF.
   - AC: prompt appears, user types line, buffer contains it.
   - Touching: `src/user/shell.pdx`.
   - Prereq: 1.

3. **`r17-m3-003-shell-tokenizer`** — Split line at spaces/tabs; produce argv[] + argc.
   - AC: `echo hello world` → argv = ["echo","hello","world"].
   - Touching: `src/user/tokenizer.pdx`.
   - Prereq: 2.

4. **`r17-m3-004-shell-builtin-dispatch`** — Match argv[0] against builtin table; call handler or return not-found.
   - AC: `echo` and `exit` recognized as builtins.
   - Touching: `src/user/dispatch.pdx`.
   - Prereq: 3.

5. **`r17-m3-005-shell-fork-exec-child`** — For non-builtin: fork; child execves argv[0]; parent waits.
   - AC: `/bin/true` (a simple test binary) runs and returns.
   - Touching: `src/user/shell.pdx`.
   - Prereq: 4.

6. **`r17-m3-006-shell-path-resolution`** — Prepend "/bin/" if argv[0] has no `/`.
   - AC: `echo` resolves to /bin/echo (or is a builtin).
   - Touching: `src/user/shell.pdx`.
   - Prereq: 5.

7. **`r17-m3-007-shell-ctrld-eof-exit`** — read returns 0 → sys_exit(0).
   - AC: Ctrl-D at prompt cleanly exits.
   - Touching: `src/user/shell.pdx`.
   - Prereq: 2.

8. **`r17-m3-008-shell-empty-line-reprompt`** — Empty line → skip dispatch, reprompt.
   - AC: hitting enter shows `$ ` again immediately.
   - Touching: `src/user/shell.pdx`.
   - Prereq: 2.

### C. Testing strategy

- **Smoke modes.** `boot_r17_shell_scripted` — driven with QEMU stdin pipeline.
- **Fingerprint.** `$ echo hello\r\nhello\r\n$ `.

### D. Cross-subsystem dependencies

- **Depends on:** 16, 17.
- **Depended on by:** 19, 20.

---

## Subsystem 19 — Shell builtins: cd, pwd, echo, exit, help, env (R17.M4)

### A. Design contract

**Responsibility.** In-process implementations of builtins. `echo` prints args joined by spaces + \n. `exit` calls sys_exit(status). `pwd` prints current directory. `cd` changes it. `help` lists commands. `env` prints environment (for R17, environment is empty except for hardcoded `PATH=/bin`).

**Invariants.**
- `echo` supports `-n` (no trailing newline) for round-trip byte tests.
- `exit` accepts optional numeric status; default 0.
- `pwd` prints starting `/`.
- `cd` fails with -ENOENT for bad paths.

**Primary interfaces.** Called from dispatch table (Subsystem 18 issue 4).

**Failure modes.** Return int status; shell prints error tag if nonzero.

### B. Issue list

1. **`r17-m4-001-builtin-echo`** — Loop over argv[1..], write with spaces + trailing \n; -n flag suppresses \n.
   - AC: `echo hello world` produces `hello world\n`.
   - AC: `echo -n foo` produces `foo` (no newline).
   - Touching: `src/user/builtins/echo.pdx`.
   - Prereq: Subsystem 18 issue 4.

2. **`r17-m4-002-builtin-exit`** — Parse optional numeric arg; sys_exit(status).
   - AC: `exit` returns 0; `exit 42` returns 42; visible in init's log.
   - Touching: `src/user/builtins/exit.pdx`.
   - Prereq: Subsystem 18 issue 4.

3. **`r17-m4-003-builtin-pwd`** — Print `_cwd_buf`.
   - AC: at boot, prints `/`.
   - Touching: `src/user/builtins/pwd.pdx`, `_cwd_buf` static.
   - Prereq: Subsystem 18.

4. **`r17-m4-004-builtin-cd`** — Path resolve; if directory, update _cwd_buf.
   - AC: `cd /tmp` then `pwd` prints `/tmp`.
   - Touching: `src/user/builtins/cd.pdx`.
   - Prereq: Subsystem 11, 12.

5. **`r17-m4-005-builtin-help`** — Static table of command name + short description; iterate + write.
   - AC: `help` lists all 6 builtins.
   - Touching: `src/user/builtins/help.pdx`.
   - Prereq: none.

6. **`r17-m4-006-builtin-env`** — Print `PATH=/bin\n`.
   - AC: `env` prints one line.
   - Touching: `src/user/builtins/env.pdx`.
   - Prereq: none.

### C. Testing strategy

- **Smoke modes.** `boot_r17_shell_builtins` — drives shell through each builtin.
- **Fingerprint.** Multi-line reproducible transcript.

### D. Cross-subsystem dependencies

- **Depends on:** 18.
- **Depended on by:** 20.

---

## Subsystem 20 — Shell integration test harness (R17.M5)

### A. Design contract

**Responsibility.** End-to-end automated test driver. Feeds a scripted command stream to QEMU via `-serial pty`; captures output; asserts byte-level match against expected fingerprint. Runs as part of `tools/run-smoke.sh`.

**Invariants.**
- Every scripted test finishes deterministically under QEMU TCG.
- Test asserts full transcript byte-identical (not substring match).
- Test cleanup: kill QEMU on timeout (30s).

**Primary interfaces.** `tools/run-shell-test.sh <script> <expected>` returns 0 on match.

### B. Issue list

1. **`r17-m5-001-serial-pty-driver-script`** — Bash/expect script that opens PTY, launches QEMU, sends scripted input line-by-line, captures output.
   - AC: script exists; runs with args.
   - Touching: `tools/run-shell-test.sh`.
   - Prereq: none.

2. **`r17-m5-002-echo-hello-golden`** — Golden: `tests/r17/shell-echo-hello.golden` = full transcript from boot to `$ ` + `echo hello` + `hello` + `$ ` + `exit`.
   - AC: golden lands; matches actual byte-identically.
   - Touching: `tests/r17/shell-echo-hello.golden`, `tests/r17/shell-echo-hello.script`.
   - Prereq: 1, Subsystems 17–19.

3. **`r17-m5-003-shell-multi-command-golden`** — Script: `pwd\ncd /tmp\npwd\nhelp\nexit\n`. Golden matches.
   - AC: passes 3/3 reps.
   - Touching: `tests/r17/shell-multi.golden`.
   - Prereq: 2.

4. **`r17-m5-004-shell-child-process-golden`** — Script forks a child via `/bin/true` (a trivial test binary added to embedded tmpfs).
   - AC: golden captures init's `[init] pid=N status=0` log.
   - Touching: `tests/r17/shell-child.golden`, `src/user/tests/true.pdx`.
   - Prereq: 2.

5. **`r17-m5-005-shell-shutdown-golden`** — Script: `exit\n`. Golden matches: shell exits, init logs, kernel outputs shutdown message, QEMU actually powers off within 5s.
   - AC: `qemu` exits with code matching ACPI shutdown handshake.
   - Touching: `tests/r17/shell-shutdown.golden`.
   - Prereq: G.7 shutdown protocol landed.

6. **`r17-m5-006-add-shell-tests-to-run-smoke`** — Extend `tools/run-smoke.sh` to run the shell tests as modes 6, 7, 8, 9.
   - AC: `run-smoke.sh` reports 9 modes.
   - AC: pre-push hook enforces all 9 modes green.
   - Touching: `tools/run-smoke.sh`.
   - Prereq: 1–5.

### C. Testing strategy

- **Smoke modes.** Multiple new modes with real transcript.
- **Fingerprint.** Documented per test.

### D. Cross-subsystem dependencies

- **Depends on:** 17, 18, 19.
- **Depended on by:** none (this closes R17 / R14B).

---

# Aggregate paideia-as encoder gap forecast (chronological)

Ordered by first R14B use-site. Categorized by likely paideia-as milestone bundle.

## paideia-as v0.12.0 (already scoped for release)

Already covered by preflight; no new escalation in this document.

| # | Instruction | First use | Notes |
|---|---|---|---|
| PA-R13-001 | `ltr r16` | R14.M4 (TSS already installed) | landed |
| PA-R13-005 | `mfence` | R14.M5 IPI | landed (per v0.12.0) |
| PA-R13-012 | `xchg [mem], reg` + `lock cmpxchg` | R15.M6 fork COW ref | landed |
| PA-R14-001 | `mov r64, [gs:disp32]` | R14.M5 cpu_local | landed |

## paideia-as v0.13.0 (new for R14B/R15)

| # | Instruction | First use | Subsystem | Priority |
|---|---|---|---|---|
| PA-R15-001 | `@include_bytes` (assembler directive to embed a binary as .rodata bytes) | Subsystem 4 issue 7 | HARD — no clean workaround |
| PA-R15-002 | `iretq` (opcode `48 CF`) — verify present | Subsystem 5 issue 5 | HARD — no clean workaround for initial ring-3 entry |
| PA-R15-003 | `call qword ptr [reg + reg*8]` (SIB-form indirect call) | Subsystem 7 issue 2 | soft — workaround `mov rax, [reg+reg*8]; call rax` |
| PA-R15-004 | `call qword ptr [reg + imm8]` (vops dispatch) | Subsystem 11 issue 3 | soft — workaround as above |
| PA-R15-005 | `jmp qword ptr [reg]` (indirect near jump) | Subsystem 5 (if used), 7 | already noted absent per r14-preflight §A |
| PA-R15-006 | `rep movsb`, `rep stosb` | Subsystem 4 issue 5, Subsystem 12 issue 5, Subsystem 8 issue 6 | soft — byte-loop workaround |
| PA-R15-007 | `swapgs` (`0f 01 f8`) | Subsystem 2 issue 7 | HARD — mandatory for KPTI ABI |
| PA-R15-008 | `invlpg [reg]` (`0f 01 3X`) | Subsystem 3 issue 4 | HARD — TLB shootdown |
| PA-R15-009 | `mov cr3, r64` — verify present | Subsystem 2 issue 5 | HARD — KPTI CR3 flip |
| PA-R15-010 | `out dx, ax` (word out) | G.7 shutdown | soft — `out dx, al; out dx, al` byte fallback if absent, though ACPI port needs 16-bit write |

## paideia-as v0.14.0 (R16 forecast)

| # | Instruction | First use | Subsystem |
|---|---|---|---|
| PA-R16-001 | `bt`, `bts`, `btr`, `btc` (bit ops) | Subsystem 13 fd bitmap, if we use one | soft |
| PA-R16-002 | Function-pointer-typed module-level tables (`_syscall_handler_table`, `_tmpfs_vops`) | Subsystem 7, 11, 12, 15 | HARD if the compiler doesn't lay out fn ptrs correctly |
| PA-R16-003 | Mutable module-level tables with `@align(4096)` on structs > 4KiB (task_pool[64] at 4KiB each) | Subsystem 8 issue 2 | verify |

## Verifications required (may already be present)

| Instruction | Status per this doc | Verify command |
|---|---|---|
| `cpuid` | landed per feature guards | `objdump -d build/kernel.elf \| grep cpuid` |
| `sti`, `cli` | landed | grep in preexisting code |
| `wrmsr`, `rdmsr` | landed | present |
| `hlt` | landed | present |
| `mov cr4, r64`, `mov cr0, r64` | landed | present |
| `outb dx, al` | landed | present (banner uses it) |
| `inb al, dx` | landed | present (UART LSR poll) |

---

# Highest-risk issue register

Ranked by likelihood of triple-fault or blocked-by-deep-encoder-work.

1. **`r14b-m3-005-boot-stub-far-jmp-transition`** (Subsystem 1, issue 5). *Risk:* triple-fault on any bit-error in the far-jmp target. Mitigation: audit the 10-byte operand byte-by-byte; use `-d int,cpu_reset -no-reboot` to catch reset before losing state; add a two-byte `hlt` at low-VA `_kernel_high_entry` sentinel to fault-detect a bad transition without triple-faulting.
2. **`r14b-m4-006-syscall-entry-cr3-flip-on-entry`** (Subsystem 2, issue 6). *Risk:* If CR3 flips before the trampoline page is mapped in both PML4s, the next fetch faults with no valid PT → triple-fault. Mitigation: the trampoline section IS the shared page; ensure `.text.syscall_trampoline` alignment + mapping is verified in a fixture BEFORE the first syscall attempt.
3. **`r15-m2-005-enter-userland-initial`** (Subsystem 5, issue 5). *Risk:* First iretq — any of {CS RPL wrong, RIP not user-mapped, RFLAGS reserved bits wrong, SS RPL wrong, CR3 wrong} triple-faults. Mitigation: build the frame in kernel using known-good constants; step through with `-d int,cpu_reset`; keep a `boot_r15_ring3_hello` mode that only exercises this one instruction and a `hlt` on the user side, so any misfire is immediately localized.
4. **`r15-m6-002-pf-handler-cow-split`** (Subsystem 9, issue 2). *Risk:* PF handler must not re-fault. Any allocator call that itself triggers PF, any invlpg on a bad VA, any missed swap of the mapping bits, cascades into double-fault → triple-fault. Mitigation: hand-audit; write in the smallest form; PF handler runs on IST stack (already wired r13-m4-003, #425).
5. **`r16-m4-005-ioapic-route-irq4`** (Subsystem 14, issue 5). *Risk:* IOAPIC MMIO writes must land at the correct RTE offset; wrong routing → IRQ not delivered → shell blocks forever waiting for input, appearing as a hang not a fault. Mitigation: read back RTE after write; log routing tuple; timeout in test harness.
6. **`r16-m2-005-tmpfs-write`** (Subsystem 12, issue 5). *Risk:* Off-by-one in the page-boundary crossing logic corrupts adjacent pool bytes silently, surfacing as intermittent shell-output corruption. Mitigation: add write-then-read round-trip fixture for offsets 4090..4106 to catch boundary crossings explicitly.
7. **`r15-m4-005-sys-read-handler-tty-only`** (Subsystem 7, issue 5) combined with **`r15-m7-006-sched-block-wake`** (Subsystem 10, issue 6). *Risk:* Race between ISR waking a blocked task and scheduler observing the wake — even at single-CPU, if the wake happens during a partial state transition in sys_read, the task may double-enqueue or miss the wake. Mitigation: block/wake sequence is `cli`-bracketed; single audit pass; observable as `SHELL HANG` in test harness with timeout.
8. **`r15-m6-004-sys-execve`** (Subsystem 9, issue 4). *Risk:* execve replaces its own aspace while executing; any live register or stack reference to the old aspace after the swap crashes. Mitigation: exec does the swap-and-jump strictly in the syscall return path, on the kernel stack, never touching the user aspace after unmap.

---

# Definition of "shell echo working" (byte-level serial transcript)

Given `tests/r17/shell-echo-hello.script` containing exactly the bytes:

```
echo hello\n
exit\n
```

the expected COM1 serial transcript, byte-for-byte, from cold boot through QEMU shutdown, is:

```
B
PaideiaOS R8
CAP OK
IPC OK
CAP INVOKE MEM
CAP INVOKE IPC
CAP INVOKE SCHED
CAP INVOKE DEV
CAP DISPATCH OK
IDT OK
TSS OK
HI VA FFFF8000
KPTI OK
IPI OK
LOADER OK entry=0000000000400000 rsp=00007FFFFFFFF000
RING3 HELLO
VFS OK
TMPFS OK
FD OK
UART RX: <no injected>
TTY OK
PaideiaOS init v0.1
PaideiaOS shell v0.1
$ echo hello\r
hello\r
$ exit\r
[init] pid=2 status=0
PaideiaOS: init exited (status=0), powering off.
```

followed by QEMU exit code matching the ACPI shutdown handshake (0x604 write of 0x2000). The two `\r` inside the shell output are the TTY layer's `\n → \r\n` translation on write; the input `\n` on typing is not echoed as-is because line discipline delivers it after echo-suppress at `\n`.

The load-bearing byte pairs for "the shell demo actually works" are:
- `$ ` (2 bytes) — first evidence of interactive shell.
- `echo hello\r` — evidence that TTY line editing echoed the typed line back cleanly (\r comes from '\n' write on TX by the shell's own line-completion write; if the shell built the line correctly, the second `\r\n` on hello also lands cleanly).
- `hello\r` — evidence that argv[1] was tokenized correctly and echo builtin wrote it.
- `$ ` again — evidence the shell looped correctly.
- `[init] pid=2 status=0` — evidence that init reaped the shell cleanly.
- ACPI exit — evidence that G.7 shutdown protocol closed the loop.

If all of those are present in the transcript byte-identically across 3 reps in `tools/run-smoke.sh`, the R14B → R17 tactical plan has landed its north star.

---

**Author:** softarch (paideia-os tactical channel)
**Date:** 2026-07-04
**Sibling:** osarch strategic milestone plan (produced in parallel)
**Status:** Advisory / reference. Issue creation to be done by the main context (not by any subagent per constraints).
