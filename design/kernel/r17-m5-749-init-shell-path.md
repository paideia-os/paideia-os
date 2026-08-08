# R17-M5-749: init.pdx path — fork /bin/sh without breaking #723 AC

**Status:** landing — third prereq of #636 (r17-m5-002-echo-hello-golden)
**Issue:** paideia-os #749 (`r17-m5-636-prereq-4`)
**Milestone:** `r17-m5` (Shell integration test harness)
**Depends on:** #636 seed (befaa1b: `/bin/sh` in tmpfs), #748 (cd70e1a: tty stdin bridge)
**Parent:** paideia-os #636 (`r17-m5-002-echo-hello-golden`)

This landing wires init to fork+exec `/bin/sh` after its existing
`/bin/child_hello` fork+exec cycle. `/bin/sh` is seeded in tmpfs by the
`bin_sh_seed` block that landed at befaa1b (prereq #2). `/bin/child_hello`
remains as init's first child so that the #723 wire acceptance criteria
(`CHILD HELLO 42\nWAIT: pid=2 status=42\nREAPED`) is preserved
byte-identically.

---

## 1. Constraint

#723 AC is on the wire in `boot_r17_init` and `boot_r16_uart_rx`
fingerprints:

```
CHILD HELLO 42
WAIT: pid=2 status=42
REAPED
```

That tail must survive this landing byte-identically. It comes from init
forking `/bin/child_hello` (pid 2), waiting, and emitting the
`WAIT: pid=<N> status=<M>\n` line (D12 runtime-formatted) followed by
`REAPED\n`.

Any restructuring of init's `_start` that either (a) changes which binary
is exec'd first, (b) alters the pid arithmetic so pid becomes ≠ 2, or
(c) suppresses the `CHILD HELLO 42` / `WAIT` / `REAPED` line group
directly breaks the AC. The chosen option must preserve **all three
lines, in that order, with pid=2 and status=42**.

---

## 2. Option analysis

Four candidates were considered:

### Option A — sequential fork in a single init binary

init.pdx keeps its existing child_hello fork+wait cycle. After the
existing `REAPED\n` emission, init falls through into a **second**
fork+exec+wait cycle for `/bin/sh`.

| Aspect | Value |
|--------|-------|
| Surface change | init.pdx only (+ two fingerprint files, + shell start marker) |
| Binaries | 1 (existing init.elf) |
| Kernel bootstrap | unchanged (kernel_main still loads init.elf via init_bootstrap_witness) |
| Boot binary selection | none (single-path) |
| #723 AC preservation | byte-identical (child_hello runs first, emits AC lines, wait4 reaps, then shell fork begins) |
| Blast radius on failure | shell fork fails cleanly (child sys_exit(1); parent wait4 reaps) |
| Fingerprint update | append 2 lines (`INIT FORK SH OK`, `SHELL START`) after existing `REAPED` |
| Future extension for #636 | matches naturally: same init, boot_r17_shell_echo_hello only differs in stdin injection |

### Option B — mode-gated init (runtime discriminator)

init reads a kernel-provided flag (via cmdline, MSR, or a specific
tmpfs marker file) to decide between AC mode (exec child_hello only)
and shell mode (exec /bin/sh only).

| Aspect | Value |
|--------|-------|
| Surface change | init.pdx + kernel_main.pdx (flag injection) + one new syscall or convention |
| Binaries | 1 |
| Kernel bootstrap | needs a new mechanism to pass the flag |
| #723 AC preservation | conditional on the flag path being wired correctly at boot |
| Blast radius | flag-injection bugs affect both modes |
| Fingerprint update | AC mode unchanged; shell mode needs new fingerprint |
| Future extension | requires a way for smoke driver to select mode |

Rejected: introduces a new kernel↔init contract (flag passing) that has
no precedent in the current codebase and no immediate justification
beyond this one decision. Higher entanglement than Option A.

### Option C — sh forks child_hello internally

/bin/sh, on startup, forks child_hello and waits before showing the
prompt. Init unchanged.

| Aspect | Value |
|--------|-------|
| Surface change | shell.pdx (large — new fork+exec+wait logic in shell) |
| Binaries | 2 (init.elf, shell.elf both changed) |
| #723 AC preservation | conditional on shell's fork logic behaving identically to init's |
| Blast radius | shell's exec_child logic already exists but is user-driven; hardcoding a bootstrap child inside shell couples the shell binary to test infrastructure |

Rejected: architecturally wrong. Shell should not have hardcoded
knowledge of child_hello as a bootstrap child. That coupling would be
carried forever as tech debt and complicate future single-user builds.

### Option D — separate init_shell.elf variant

Build a new `src/user/init_shell.pdx` that only forks /bin/sh. Embed
it alongside init.elf. Add a new smoke mode `boot_r17_shell_*` that
selects init_shell.elf at kernel_main load time via a build variant
(e.g., a separate kernel.elf-shell target) or a runtime flag.

| Aspect | Value |
|--------|-------|
| Surface change | new src/user/init_shell.pdx + tools/userbin_embed.S + tools/build-user.sh + tools/build.sh + kernel_main.pdx + tools/run-smoke.sh |
| Binaries | 2 init binaries (init.elf, init_shell.elf) OR 2 kernel builds |
| #723 AC preservation | trivial — boot_r17_init still uses init.elf, unchanged |
| Blast radius | isolated per binary |
| Fingerprint update | boot_r17_init unchanged; new smoke mode needs its own fingerprint |
| Future extension | requires selection mechanism |
| Complexity | ~5 file changes, new build target, new smoke mode |

Rejected as **first partial**: high surface change for a step that
Option A can accomplish with far less machinery. Option D is a viable
retreat if Option A surfaces a runtime issue that cannot be fixed
inline (e.g., shell binary crashes on entry and blocks the shared init
binary from being useful for the child_hello AC).

### Decision matrix

| Option | Surface | AC risk | Reversibility | Fit for #636 |
|--------|---------|---------|---------------|--------------|
| **A** (sequential fork) | **low** | **low** | high | high |
| B (mode-gated) | medium | medium | medium | medium |
| C (sh forks child_hello) | medium | medium | low | low |
| D (separate init_shell) | high | low | high | medium |

**Chosen: Option A.**

Rationale:
1. Smallest surface change consistent with the constraint.
2. #723 AC preserved by construction — the first fork+wait cycle is
   entirely unchanged; new logic is appended after the existing
   `REAPED\n` emission.
3. Wire evidence for the shell path is unambiguous and self-witnessing
   (init emits `INIT FORK SH OK\n`; shell emits `SHELL START\n` from
   its own `_start` before dispatch_init runs).
4. When #636's shell smoke mode lands, it can reuse the same init
   binary — the difference between `boot_r17_init` and
   `boot_r17_shell_echo_hello` is *what gets injected on stdin*, not
   *which init binary is loaded*.
5. Backtracking cost to Option D is bounded: extract the sh fork logic
   into a new `init_shell.pdx`, delete from init.pdx, add build target
   and mode. All changes local to the sh fork block.

---

## 3. Landing summary

Four touched surfaces:

| Surface | Change |
|---------|--------|
| `src/user/init.pdx` | Add `bin_sh_path` rodata, `init_fork_sh_msg` witness marker, `init_fork_sh_fail_msg` fail marker. Restructure `_start`: after existing `REAPED\n` emission, fall through into a new `init_fork_sh` block that emits marker, forks, execs `/bin/sh` in child, waits in parent, emits second `WAIT:` + `REAPED` sequence. |
| `src/user/shell.pdx` | Add early `sys_debug_puts("SHELL START\n", 12)` at very top of `_start`, before `dispatch_init`. Adds ~10 bytes to shell.elf. |
| `tests/r17/expected-boot-r17-init.txt` | Append `INIT FORK SH OK\n` and `SHELL START\n` after existing `REAPED\n` line. |
| `tests/r16/expected-boot-r16-uart-rx.txt` | Same append (r16 smoke also runs init to completion). |

No changes to:
- `kernel_main.pdx` (init binary unchanged; kernel bootstrap unchanged).
- `tools/build-user.sh`, `tools/userbin_embed.S` (single init.elf).
- `tools/run-smoke.sh` (no new mode in this landing; that's prereq #7 of #636).
- Boot-stub `.S` files (no new global kernel symbols).
- `tools/verify-user-init.sh` (call counts use `>= 1`; ≥1 fork/execve/wait4 already covered).

---

## 4. init.pdx — new sequence

### 4.1 Layout at entry (unchanged)

```
_start:
    debug_puts("INIT ENTERED RING3\n")
    sys_open("/dev/tty0")            → fd (r12)
    sys_dup2(r12, 0/1/2)             (3 calls)
    sys_close(r12)
    sys_fork                         → rax = 0 (child) or child_pid (parent)
    if child: goto init_child        (execs /bin/child_hello)
    debug_puts("INIT OK\n")
    goto init_parent
```

### 4.2 First fork+wait cycle (unchanged — preserves #723 AC)

```
init_child:
    sys_execve("/bin/child_hello", NULL, NULL)
    on failure: goto init_error

init_parent:
    sys_wait4(-1, &wait_status, 0, NULL)     → rax = child_pid (=2)
    if rax < 0: goto init_shutdown
    r13 = rax (child pid)
    emit "WAIT: pid="
    emit r13 as u64 decimal
    emit " status="
    emit wait_status[0] as u64 decimal
    emit "\n"
    emit "REAPED\n"
    # WAS: jmp init_shutdown
    # NEW: fall through to init_fork_sh
```

### 4.3 Second fork+wait cycle (NEW — Option A)

```
init_fork_sh:
    emit "INIT FORK SH OK\n"                 (sys_debug_puts, len 16)
    sys_fork                                 → rax = 0 (child) or child_pid (parent)
    r12 = rax                                (unused after this — retained for symmetry)
    if child (rax == 0): goto init_fork_sh_child
    jmp init_fork_sh_parent

init_fork_sh_child:
    sys_execve("/bin/sh", NULL, NULL)
    # execve normally does not return. If it does, /bin/sh was
    # missing (seed failed) or malformed. Emit a distinct fail
    # marker so triage is possible, then sys_exit(1) so the parent's
    # wait4 unblocks and boot_r17_init doesn't hang past its timeout.
    emit "INIT FORK SH FAIL\n"
    sys_exit(1)

init_fork_sh_parent:
    sys_wait4(-1, &wait_status, 0, NULL)
    # wait_status[0] is re-used from the first cycle; kernel writes
    # the new child's status here. Same 8-byte .bss slot; no aliasing
    # issue because the first cycle has completed.
    if rax < 0: jmp init_shutdown
    r13 = rax (shell pid)
    emit "WAIT: pid="
    emit r13 as u64 decimal
    emit " status="
    emit wait_status[0] as u64 decimal
    emit "\n"
    emit "REAPED\n"
    jmp init_shutdown

init_shutdown: (unchanged)
    sys_exit(0)
```

### 4.4 Register discipline

`print_u64_dec` preserves r12–r15 (callee-save). Both fork+wait
cycles reuse the same convention: r13 holds the reaped pid across the
`WAIT: pid=` emission and the print_u64_dec call. No cross-cycle
register liveness — each cycle is independent from the register
perspective.

### 4.5 Failure semantics

| Failure | Behavior | Wire artifact |
|---------|----------|---------------|
| child_hello execve fails | falls into init_error (unchanged) | "INIT OK\n" (bug in existing init_error — out of scope) |
| /bin/sh execve fails | emits `INIT FORK SH FAIL\n`, sys_exit(1) | `INIT FORK SH OK\nINIT FORK SH FAIL\n` (parent then reaps, prints `WAIT: pid=3 status=1\nREAPED\n`) |
| second sys_wait4 fails | jmp init_shutdown; sys_exit(0) | `WAIT:` line not emitted |
| shell blocks forever on stdin | init blocks in wait4 | `INIT FORK SH OK\nSHELL START\n$ ` then QEMU timeout — matches boot_r17_init AC (no shell wait4 line in fingerprint) |

The "shell blocks forever" case is the expected behavior for
`boot_r17_init` where no stdin is injected. The `INIT FORK SH OK\n`
and `SHELL START\n` markers land on the wire before shell blocks in
`sys_read`; the fingerprint check terminates at `SHELL START` and
passes on the timeout exit (QEMU rc=124 accepted).

---

## 5. shell.pdx — SHELL START marker

Adds a single `sys_debug_puts` at the top of `_start`, before any
other work:

```
_start:
    lea rdi, [rip + shell_start_msg]     # "SHELL START\n\0"
    mov rsi, 12                          # length excluding NUL
    call sys_debug_puts
    call dispatch_init                   # (existing)
    call cwd_init                        # (existing)
    ... (existing main_loop)
```

Rationale for placement:
- **Before dispatch_init**: if dispatch_init crashes or takes an
  unexpected path, we still see the marker; it proves the SYSCALL
  entry path works and shell reached _start.
- **sys_debug_puts (not puts_new)**: bypasses the tty layer. If the
  tty write path has a bug, the marker still lands on serial. This
  gives an unconflated witness of shell's entry point.
- **12 bytes**: strlen("SHELL START\n") = 12.

Wire impact: +12 bytes on serial. Fingerprint appends one line.

Adversarial self-check (per the task): this marker is what the task
brief calls "SHELL START\n" — it exists precisely to prove the shell
binary reaches its entry point after init's fork+execve. Its presence
on wire between `INIT FORK SH OK\n` (from init) and any subsequent
prompt/read blocking is sufficient evidence that
`sys_execve_shim("/bin/sh")` transferred control into shell's
`_start`, that the ELF loader placed the entry correctly, and that
the shell's syscall_shim resolves against the kernel's SC+ dispatch.

---

## 6. Wire fingerprint updates

### 6.1 tests/r17/expected-boot-r17-init.txt

Existing tail:
```
INIT ENTERED RING3
INIT OK
CHILD HELLO 42
WAIT: pid=2 status=42
REAPED
```

New tail (2 lines appended):
```
INIT ENTERED RING3
INIT OK
CHILD HELLO 42
WAIT: pid=2 status=42
REAPED
INIT FORK SH OK
SHELL START
```

The existing 5 lines are byte-identical — #723 AC is preserved by
insertion, not modification.

### 6.2 tests/r16/expected-boot-r16-uart-rx.txt

Same tail as boot_r17_init. Same 2-line append.

### 6.3 Not included in fingerprint

- `$ ` (shell prompt): substring-safe but stylistically noisy in
  fingerprint files. Excluded — SHELL START is sufficient evidence
  shell reached its entry point.
- `WAIT: pid=3 status=0\nREAPED\n` for the second cycle: only fires
  if shell exits. In boot_r17_init and boot_r16_uart_rx, shell blocks
  in sys_read (no stdin injection). Excluded — belongs to the future
  `boot_r17_shell_echo_hello` fingerprint (prereq #7 of #636).

### 6.4 AC-preservation matrix

The 20 smoke modes and how each interacts with the new markers:

| Mode | Fingerprint | Markers appear on wire? | Fingerprint change? |
|------|-------------|-------------------------|---------------------|
| boot_min | expected-boot-min.txt | no (boot exits before) | no |
| boot_banner | expected-boot-banner.txt | no | no |
| boot_tick | expected-boot-tick.txt | no | no |
| boot_r8_only | expected-r8-only.txt | no | no |
| boot_r10 | expected-boot-r10.txt | no | no |
| boot_r11 | expected-boot-r11.txt | no | no |
| boot_r12 | expected-boot-r12.txt | no | no |
| boot_r12_denial | expected-boot-r12-denial.txt | no | no |
| boot_r14b_hivma | expected-boot-r14b-hivma.txt | no | no |
| boot_r14b_kpti | expected-boot-r14b-kpti.txt | no | no |
| boot_r14b_ipi | expected-boot-r14b-ipi.txt | no | no |
| boot_r14b_loader | expected-boot-r14b-loader.txt | no | no |
| boot_r14b_ud | expected-boot-r14b-ud.txt | no | no |
| boot_r15_ring3 | expected-boot-r15-ring3.txt | no (ends at CHILD HELLO EMBED OK) | no |
| boot_r15_process | expected-boot-r15-process.txt | no (same) | no |
| boot_r16_uart_rx | expected-boot-r16-uart-rx.txt | **yes** | **+2 lines** |
| boot_r17_init | expected-boot-r17-init.txt | **yes** | **+2 lines** |
| boot_panic | expected-panic-dump.txt | no | no |
| boot_panic_halt | expected-panic-halt.txt | no | no |
| boot_exc3 | expected-exc3.txt | no | no |

The fingerprint check is contains-in-order (`tools/run-smoke.sh`
§326-341). Appending 2 lines after the existing `REAPED` in the
fingerprint is safe: the previous 5 lines still match, and the 2 new
lines match the new wire output.

---

## 7. Kernel bug surfaced: dispatch_wait4 pid_free leak (#753)

**Filed + fixed inline as part of this landing.**

Adding a second `sys_wait4` cycle to init exposed a pre-existing kernel
defect: `dispatch_wait4`'s sched_block+wake path never called
`pid_free`, so the reaped ZOMBIE persisted in `_pid_table`. Every
subsequent `wait4` immediately re-reaped the leaked ZOMBIE instead of
blocking for the new child.

Pre-fix wire artifact (observed on first run of this landing):

```
INIT FORK SH OK
WAIT: pid=2 status=42    <- WRONG: should have been blocking for shell (pid=3)
REAPED
SHELL START
```

Root cause: `sys_wait_body`'s reap path (rax != 0 return) calls
`pid_free` in its zombie-found branch (sys_wait.pdx L60). The
sched-block wake path returns via a separate control flow — it reads
`wait_result_{pid, status}` from the parent's TCB slab (@1704, @1708)
after `sched_block` resumes — and never called `pid_free` for the
child whose exit fired the wake.

Fix (src/kernel/core/syscall/dispatch.pdx, dispatch_wait4 sched-block
resume path, immediately after reading wait_result_pid into rax):

```asm
push rax                  # save zombie pid
push rdx                  # save exit status
push rsi                  # save wstatus user ptr
mov rdi, rax              # arg0 = zombie pid
call pid_free             # _pid_table[pid] = 0
pop rsi                   # restore wstatus user ptr
pop rdx                   # restore exit status
pop rax                   # restore zombie pid
```

Alignment: entry to dispatch_wait4 is rsp%16==8 (SysV). After
sched_block returned and `pop rsi`, we're at %16==8. Three pushes →
%16==0 (correct for pid_free's SysV call). Three pops restore %16==8.

Post-fix wire (from tools/run-smoke.sh boot_r17_init):

```
INIT FORK SH OK
SHELL START
```

Clean — no duplicate WAIT/REAPED. Shell is scheduled after init calls
sys_exit(0); the shell task blocks on stdin (no injection); QEMU times
out at 8s; fingerprint check passes (contains-in-order over the 5-line
new tail).

Issue filed: paideia-os #753. AC:
- Wire trace post-fix shows exactly one WAIT/REAPED pair between INIT
  FORK SH OK and SHELL START (satisfied — see above).
- Full 20-mode smoke green byte-identically (satisfied).
- #723 AC preserved (satisfied).

Design implication: the reap-versus-wake split for pid_free is asymmetric
in the current dispatch. A future refactor could hoist pid_free into
sys_exit_body's wake path, but that changes ownership semantics
(sys_exit_body would then free its own pid, coupling exit to reap).
The current split — sys_wait_body owns pid_free in the reap path, and
dispatch_wait4 owns it in the wake path — keeps sys_wait_body a leaf
+ pid_free (per §8 of design/kernel/r17-m0-724-d5-sys-wait-block.md)
and confines the composition responsibility to dispatch_wait4.

---

## 8. Adversarial self-check

What could go wrong.

1. **`/bin/sh` execve returns -ENOENT** — means the #636 seed
   (befaa1b) failed. Guard: emit `INIT FORK SH FAIL\n`, sys_exit(1).
   Parent's wait4 reaps with status=1; log shows the failure. Boot
   completes cleanly.
2. **shell binary crashes in _start** — SHELL START marker would NOT
   appear on wire; only INIT FORK SH OK. If observed, backtrack:
   check sys_execve_shim's entry-frame setup, ELF loader's e_entry
   dispatch, syscall_shim linkage.
3. **shell reaches _start but blocks in dispatch_init or cwd_init** —
   SHELL START marker appears; no "$ " prompt on wire. That's still a
   pass for THIS landing (SHELL START is the AC), but flags a shell
   bug to file separately.
4. **wait4 double-call race** — the same wait_status .bss slot is
   reused for both cycles. Kernel writes on each reap; no aliasing
   between cycles (first cycle completes before second cycle's fork).
5. **pid arithmetic changes** — currently pid=2 for child_hello.
   Second cycle assigns pid=3 to shell. If any test asserts pid=2 for
   shell (none currently do), it will break. Not applicable — all
   existing fingerprints reference pid=2 for the child_hello wait.
6. **Fork/exec bomb** — init only forks twice, both children exit or
   block. No respawn logic. Bounded.
7. **Register-clobber from print_u64_dec** — print_u64_dec is
   callee-save for r12–r15 (per its own justification comment); the
   second cycle's r13 (shell pid) survives across its own print calls.
8. **/bin/sh path length** — 8 bytes ("/bin/sh\0"), well under
   PATH_MAX (256) in sys_execve_shim.
9. **Reserved-label collision** — new labels prefixed
   `init_fork_sh_*`; none clash with `loop`, `if`, etc.

---

## 9. What this does NOT do

- Does not close #636 (needs prereqs #5, #6, #7).
- Does not add a new smoke mode (that's prereq #7).
- Does not wire QEMU stdin injection for the shell test (that's
  prereq #5).
- Does not create the golden transcript (that's prereq #6).
- Does not change how init handles child_hello's fork/exec. That
  cycle is byte-identical to pre-landing.

---

## 10. Rollback plan

Localized. If a runtime regression surfaces:

1. Revert `src/user/init.pdx`: delete the `init_fork_sh` block and
   restore the `jmp init_shutdown` after the first `REAPED`
   emission. Delete `bin_sh_path`, `init_fork_sh_msg`,
   `init_fork_sh_fail_msg` rodata.
2. Revert `src/user/shell.pdx`: delete the SHELL START emission at
   the top of `_start` and the `shell_start_msg` rodata.
3. Revert the 2-line append in
   `tests/r17/expected-boot-r17-init.txt` and
   `tests/r16/expected-boot-r16-uart-rx.txt`.
4. Revert the pid_free insertion in
   `src/kernel/core/syscall/dispatch.pdx` dispatch_wait4 sched-block
   resume path (paideia-os #753 fix). Note: reverting the pid_free
   fix independently is safe (it only affects the wake path's slab
   cleanup); reverting it BUT keeping the second wait4 in init.pdx
   will restore the duplicate WAIT/REAPED wire artifact.

The /bin/sh tmpfs seed from befaa1b remains untouched (independent
of this landing). Future re-attempts of this same design can build
on the seed without redoing prereq #2.

Backtracking to Option D: if runtime issues in the shell binary make
sharing an init between AC mode and shell mode untenable, extract
the `init_fork_sh` block into a new `src/user/init_shell.pdx`, add
to `tools/build-user.sh` and `tools/userbin_embed.S`, add a new
kernel bootstrap path that loads `init_shell.elf` under a build
variant, and add `boot_r17_shell` to `tools/run-smoke.sh`. This
backtrack is one commit and does not require reverting befaa1b or
cd70e1a.
