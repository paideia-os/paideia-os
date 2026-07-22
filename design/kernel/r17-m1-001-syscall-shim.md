---
issue: 610
milestone: R17.M1 (libc-lite for userland)
subsystem: 16 — libc-lite for userland
prereq:
  - "Subsystem 7 (R15.M4 syscall dispatch) — SC+ table frozen at design/user/syscall-table.md"
  - "R15.M4 kernel dispatcher (src/kernel/core/syscall/dispatch.pdx) — the 12 IDs this shim emits are the exact IDs the dispatcher recognizes"
blocks:
  - "#611 (r17-m1-002-user-strlen-memcmp) — non-blocking (parallel; no shim dep)"
  - "#613 (r17-m1-004-user-errno-slot) — will consume every wrapper's rax return"
  - "#614 (r17-m1-005-user-puts-getline) — puts=write(1,…), getline=read(0,…) use write/read wrappers"
  - "#615 (r17-m1-006-user-smoke-libc) — libc_test binary exercises all wrappers at runtime"
  - "R17.M2 init (#616+), R17.M3 shell (#622+), R17.M4 builtins (#630+)"
touching:
  - src/user/syscall_shim.pdx                     (extend from 4 → 13 wrappers)
  - tools/verify-syscall-shim.sh                  (new: build-time byte-pattern canary)
  - tools/build-user.sh                           (add verify-syscall-shim.sh invocation post-link)
  - design/kernel/r17-m1-001-syscall-shim.md      (this doc)
  - design/user/syscall-table.md                  (addendum: reconcile "13" figure with SC+ freeze)
related:
  - "#432 (R13-m7-001 shell _start — consumes builtin_exit → sys_exit_thread today)"
  - "#433 (R13-m7-002 syscall_shim — the file being extended)"
  - "#434 (R13-m7-003 builtins — calls sys_exit_thread, sys_cap_invoke)"
  - "#483 (R13 backtrack record — why sys_read/sys_write were absent in R13)"
  - "#538 (R15-M4-004 sys_write handler)"
  - design/milestones/r14b-tactical-plan.md §Subsystem 16 (lines 1635–1710)
  - design/user/syscall-table.md (SC+ frozen table — source of truth for numbers)
  - design/audit/entries/r13-m7-002-syscall-shim.md (baseline this doc extends)
---

# R17-M1-001 — syscall_shim extend: 4 → 13 user-space syscall wrappers (#610)

## 1. Scope

Extend `src/user/syscall_shim.pdx` from R13's 4-entry ABI-legacy shim
(sys_exit_thread=0, sys_yield=1, sys_cap_invoke=4, sys_debug_puts=12)
to the full R17-consumer surface: every syscall the R17.M2 init,
R17.M3 shell, and R17.M4 builtins will ever need to name from user
`.pdx`. Each wrapper is a straight-line trampoline that (a) shuffles
`rcx → r10` when the syscall takes ≥4 arguments (SysV → SYSCALL ABI
mismatch), (b) loads the SC+ syscall number into `rax`, (c) issues
`SYSCALL`, (d) returns.

At R17.M1 an **fd is an opaque `i64`** returned by the kernel; the
shim performs **no errno translation** — return values ≤ `-1` are
propagated verbatim. `_user_errno` and the `-1`-return convention
land in a separate issue (#613, `r17-m1-004-user-errno-slot`) that
wraps this shim's raw returns. This separation keeps `syscall_shim.pdx`
a pure ABI translation layer (SysV↔SYSCALL) — every wrapper is a
one-shot straight-line block with **no branches**, matching the
acceptance-criterion phrasing "compiles to `mov rax, N; syscall; ret`
after arg shuffle".

Out of scope (deliberately deferred):

- **errno translation.** #613 owns `_user_errno` and the negative-rax
  → errno-slot dance. Every wrapper in this issue returns raw rax.
- **String helpers.** `strlen`, `memcmp`, `memcpy`, `strcmp`,
  `strncmp`, `memset` all live in `src/user/string.pdx` (#611, #612)
  — a different module.
- **puts / getline convenience wrappers.** `puts(str)` is
  `write(1, str, strlen(str))` — lives in `src/user/io.pdx` (#614),
  consumes the `write` wrapper this issue lands.
- **Runtime canary.** The AC is compile-only ("build-user.sh
  succeeds"). Runtime exercise of every wrapper lands as
  `libc_test.pdx` in #615 (fingerprint `LIBC TEST OK`). This issue
  installs a **build-time byte-pattern canary** (§4) — no kernel-side
  witness, no smoke-fingerprint drift.
- **sys_yield resurrection.** R13's `sys_yield` (number 1) is
  superseded by SC+ `sys_write` at number 1. Yield has no reserved
  SC+ slot; it is dropped from the shim. Any future re-introduction
  is a separate SC+ freeze extension (new number allocation +
  dispatcher entry + shim entry), tracked as a follow-up to R17.

## 2. Prereq check

### 2.1 What's in place

- **SC+ syscall table frozen** at `design/user/syscall-table.md`
  (R15.M4-001, #535): IDs 0/1/2/3/12/32/39/56/59/60/61 with
  argument-slot semantics. This shim's wrapper set is a 1:1
  materialization of that freeze plus the two R13 legacy IDs (4, 12)
  the dispatcher still handles.
- **Kernel dispatcher lives at those numbers** —
  `src/kernel/core/syscall/dispatch.pdx` (R15.M4-004 / #538) has a
  linear cmp/je over exactly the IDs {0, 1, 2, 3, 4, 12, 32, 39, 56,
  59, 60, 61} = 12 IDs. Handlers wired: 1 (sys_write real body),
  4 (sys_cap_invoke), 12 (sys_debug_puts), 60 (sys_exit). Everything
  else → ENOSYS at R15.M4; real bodies land in R15.M5/6 and R16.M3.
  **The shim can safely emit ENOSYS-stubbed IDs** — the AC is
  compile-time, not functional.
- **paideia-as encodes `mov rN, rM` for the r10←rcx shuffle**
  — `mov r10, r9`, `mov r10, rax`, `mov r10, [rax + disp]`
  all in flight (`src/kernel/core/fs/vnode_pool.pdx:71`,
  `src/kernel/core/fs/mount.pdx:286`,
  `src/kernel/core/int/idt.pdx:265`). Encoder gap: **none** —
  `mov r10, rcx` = `49 89 CA` (REX.WB + 0x89 + ModRM 0xCA), a
  straight extension-register two-byte reg-reg move.
- **paideia-as encodes `mov rax, imm32` and `syscall` and `ret`**
  — every R13 shim wrapper landed with this exact pattern
  (`0x48 0xC7 0xC0 <imm32> 0x0F 0x05 0xC3` = 10 bytes per wrapper).
  Baseline verified in `design/audit/entries/r13-m7-002-syscall-shim.md`.
- **`build-user.sh` links every `.pdx` under `src/user/`** — the
  discovery is a `find -name '*.pdx'` walk, so a widened
  `syscall_shim.pdx` is picked up automatically. No changes to
  `link.ld` are required (all wrappers land in `.text`).

### 2.2 What is *not* in place (and doesn't block this issue)

- **`_user_errno` slot** (#613) — this shim does not touch it; every
  wrapper returns raw `rax`. #613 will wrap these returns.
- **kernel-side real bodies** — IDs {0, 2, 3, 32, 39, 56, 60, 61} are
  wired per #668 (R17.M0) and ship with R15.M6 (#553–#558) and R16.M3
  (#587–#591). ID 59 (execve) returns ENOSYS pending #671 path→image
  shim. The shim itself compiles and behaves correctly independent of
  body landing. Runtime AC in #615 exercised all 11 wired IDs post-#668.
- **Follow-up caller updates** — `src/user/builtins.pdx:28` currently
  calls `sys_exit_thread` (R13 name). §3.6 explains why we preserve
  the legacy name as an alias so `builtins.pdx` compiles unchanged.

### 2.3 Discrepancy to resolve (design decision embedded in this doc)

**The issue title reads "all 13 syscalls in §C+".** The SC+ freeze
(`design/user/syscall-table.md`) lists **11 entries**. The tactical
plan §Subsystem 7 line 769 names **13 handlers** (adds `sys_yield`
+ `sys_cap_invoke`). The kernel dispatcher handles **12 IDs**
(SC+ 11 + `sys_cap_invoke` at 4, minus `sys_yield` — whose R13 number
1 was reallocated to `sys_write` at SC+ freeze). None of these three
numbers match "13" cleanly.

**Resolution.** Ship **12 canonical SC+ wrappers + 1 R13-legacy alias
(`sys_exit_thread` → number 60) = 13 exported names**. Enumeration:

| # | Wrapper name        | SC+ ID  | Arity | Notes                                                     |
|---|---------------------|---------|-------|-----------------------------------------------------------|
| 1 | `sys_read`          | 0       | 3     | new; kernel handler lands R15.M5+ (ENOSYS stub until)     |
| 2 | `sys_write`         | 1       | 3     | new; kernel body live at R15.M4-004 (#538)                |
| 3 | `sys_open`          | 2       | 3     | new; kernel handler lands R16.M3-001                      |
| 4 | `sys_close`         | 3       | 1     | new; kernel handler lands R16.M3-002                      |
| 5 | `sys_cap_invoke`    | 4       | 2     | **preserved from R13** — dispatcher still routes ID 4     |
| 6 | `sys_debug_puts`    | 12      | 2     | **preserved from R13** — SC+ retains 12 (divergence)      |
| 7 | `sys_dup2`          | 32      | 2     | new; kernel handler lands R16.M3-003                      |
| 8 | `sys_getpid`        | 39      | 0     | new; kernel handler lands R15.M5-006                      |
| 9 | `sys_fork`          | 56      | 0     | new; kernel handler lands R15.M6 (SC+ names it `clone`)   |
|10 | `sys_execve`        | 59      | 3     | new; kernel handler lands R15.M6                          |
|11 | `sys_exit`          | 60      | 1     | new; kernel body live at R15.M4-003 (#537)                |
|12 | `sys_wait4`         | 61      | 4     | new; **only 4-arg wrapper — needs r10←rcx shuffle**       |
|13 | `sys_exit_thread`   | 60      | 1     | **legacy alias** — retained for `builtins.pdx:28` caller  |

`sys_yield` is **explicitly dropped**. No caller in `src/user/` or
`src/kernel/` invokes it after R13-era code; its number 1 is now
`sys_write`. A follow-up issue may re-introduce yield under a new SC+
ID if the shell's cooperative-scheduling requirements resurface it.

An addendum to `design/user/syscall-table.md` (§8) records the "13"
count reconciliation so future readers of the tactical plan don't
re-fork over the same discrepancy.

## 3. Design

### 3.1 ABI translation: SysV → SYSCALL

paideia-as user code calls each wrapper as a plain SysV C function:
args in `rdi, rsi, rdx, rcx, r8, r9`. The kernel expects
`rdi, rsi, rdx, r10, r8, r9`. The single register mismatch is at
argument slot 3: SysV puts it in `rcx`, SYSCALL requires it in `r10`
(because the CPU stores return-`rip` into `rcx` on `SYSCALL` entry).

The shuffle is a single instruction:

```asm
mov r10, rcx   ; 49 89 CA — REX.WB + MOV r/m64,r64 + ModRM
```

It is emitted **only** in wrappers with arity ≥ 4. In our set, that
is exclusively `sys_wait4` (pid, wstatus, options, rusage). All other
wrappers have 0–3 args and require no register motion.

`rcx` and `r11` are clobbered by the `SYSCALL` instruction itself
(the CPU writes `rip → rcx` and `rflags → r11`). The kernel does not
save them across the boundary. Callers of these wrappers must treat
`rcx` and `r11` as caller-saved across every wrapper — this is
already the SysV convention (`rcx`, `r11` are caller-saved), so no
special discipline is required at the call site.

### 3.2 Wrapper template — no arg shuffle (arity 0..3)

The 11 wrappers with arity 0, 1, 2, or 3 all emit the identical
byte pattern modulo the immediate:

```asm
; sys_<name>(a0, a1, a2) -> i64
;   Args already in rdi/rsi/rdx per SysV; no shuffle needed.
sys_<name>:
    mov rax, <SC+ ID>       ; 48 C7 C0 <imm32>  (7 bytes)
    syscall                 ; 0F 05             (2 bytes)
    ret                     ; C3                (1 byte)
                            ;   TOTAL: 10 bytes
```

Because paideia-as uses the 32-bit-immediate form of `mov rN, imm`
(`48 C7 C0 <imm32>` = 7 bytes) rather than the sign-extended 8-bit or
the full 64-bit `48 B8 <imm64>` = 10-byte form, every wrapper is
exactly 10 bytes. The immediate encoding is uniform across the whole
shim, which simplifies the byte-pattern canary (§4).

Immediate widths — all SC+ IDs are ≤ 61 (0x3D), so an 8-bit
sign-extended form would fit. paideia-as's `mov r64, imm` selects
the imm32 form; this is intentional (avoids assembler-level
optimization surprises) and matches the R13 baseline in
`src/user/syscall_shim.pdx` today (each R13 wrapper emits
`48 C7 C0 <imm32>`). No encoder change needed.

### 3.3 Wrapper template — with rcx→r10 shuffle (arity ≥ 4)

Only `sys_wait4` in our set. Pattern:

```asm
; sys_wait4(pid, wstatus, options, rusage) -> i64
;   Args in rdi/rsi/rdx/rcx per SysV.
;   Shuffle: rcx (arg3) → r10 (kernel's arg3 slot).
sys_wait4:
    mov r10, rcx            ; 49 89 CA          (3 bytes) — shuffle
    mov rax, 61             ; 48 C7 C0 3D 00 00 00  (7 bytes)
    syscall                 ; 0F 05             (2 bytes)
    ret                     ; C3                (1 byte)
                            ;   TOTAL: 13 bytes
```

`sys_execve` has arity 3 (path, argv, envp) — all three args fit
in rdi/rsi/rdx. No shuffle. It follows the §3.2 template exactly.

If a future syscall extension adds arity ≥ 5 or ≥ 6, args in
`r8` / `r9` are **already in the SYSCALL slot** per SysV — no
additional shuffle. Only the arg-3 slot is misaligned between the
two ABIs. The `sys_wait4` shuffle is therefore the maximal shuffle
this shim ever needs, regardless of future syscalls.

### 3.4 Effect signatures

Every wrapper carries `!{sysreg}` because `SYSCALL` mutates
`rcx, r11, rflags`. The `@{}` capability set widens per
kernel-handler-reachable side effect:

| Wrapper           | Effects            | Capabilities  | Rationale                                                       |
|-------------------|--------------------|---------------|-----------------------------------------------------------------|
| sys_read          | `{mem, sysreg}`    | `{fs}`        | writes to user buf; kernel may block on backing store           |
| sys_write         | `{mem, sysreg}`    | `{fs}`        | reads user buf; kernel emits to backing store                   |
| sys_open          | `{mem, sysreg}`    | `{fs}`        | reads user path; kernel allocates fd slot                       |
| sys_close         | `{sysreg}`         | `{fs}`        | kernel closes fd slot; no user-mem touch                        |
| sys_cap_invoke    | `{sysreg}`         | `{cap}`       | capability invocation (retained from R13)                       |
| sys_debug_puts    | `{sysreg}`         | `{}`          | debug channel; no capability gate (retained from R13)           |
| sys_dup2          | `{sysreg}`         | `{fs}`        | fd-table mutation only                                          |
| sys_getpid        | `{sysreg}`         | `{}`          | pure read of task_struct                                        |
| sys_fork          | `{mem, sysreg}`    | `{sched, mem}`| clones task + address space                                     |
| sys_execve        | `{mem, sysreg}`    | `{sched, mem}`| loads ELF; overwrites current task                              |
| sys_exit          | `{sysreg}`         | `{sched}`     | terminates task                                                 |
| sys_wait4         | `{mem, sysreg}`    | `{sched}`     | writes user *wstatus; blocks on child reap                      |
| sys_exit_thread   | `{sysreg}`         | `{sched}`     | alias for sys_exit; same effects                                |

These bound the syscall trampoline's effect signature on the
kernel side and are already covered by the R15.M4 dispatcher's
`!{mem, sysreg} @{cap, sched}` union in
`src/kernel/core/syscall/dispatch.pdx:19`. The shim's per-wrapper
narrowing preserves higher-fidelity effect information for user code
that only calls a subset (e.g., a pure computation task that only
calls `sys_getpid` + `sys_exit` needs only `{sysreg}` + `{sched}`
capability).

### 3.5 Module structure

```pdx
// src/user/syscall_shim.pdx — R17-m1-001 (#610)
// User-space wrappers for the SC+ frozen syscall table (design/user/syscall-table.md).
// Each wrapper is a straight-line SysV → SYSCALL trampoline.
// See design/kernel/r17-m1-001-syscall-shim.md for the enumeration and rationale.

module SyscallShim = structure {

  // ==========================================================================
  // §3.2 template — arity 0..3 (11 wrappers, 10 bytes each)
  // ==========================================================================

  pub let sys_read  : (u64, u64, u64) -> u64 !{mem, sysreg} @{fs} = ...
  pub let sys_write : (u64, u64, u64) -> u64 !{mem, sysreg} @{fs} = ...
  pub let sys_open  : (u64, u64, u64) -> u64 !{mem, sysreg} @{fs} = ...
  pub let sys_close : (u64)           -> u64 !{sysreg}      @{fs} = ...

  // Preserved from R13 (numbers 4 and 12 still frozen in SC+/dispatcher).
  pub let sys_cap_invoke : (u64, u64) -> u64 !{sysreg} @{cap} = ...
  pub let sys_debug_puts : (u64, u64) -> u64 !{sysreg} @{}    = ...

  pub let sys_dup2   : (u64, u64)         -> u64 !{sysreg}      @{fs}         = ...
  pub let sys_getpid : ()                 -> u64 !{sysreg}      @{}           = ...
  pub let sys_fork   : ()                 -> u64 !{mem, sysreg} @{sched, mem} = ...
  pub let sys_execve : (u64, u64, u64)    -> u64 !{mem, sysreg} @{sched, mem} = ...
  pub let sys_exit   : (u64)              -> u64 !{sysreg}      @{sched}      = ...

  // ==========================================================================
  // §3.3 template — arity ≥ 4 (only sys_wait4; 13 bytes with r10 shuffle)
  // ==========================================================================

  pub let sys_wait4 : (u64, u64, u64, u64) -> u64 !{mem, sysreg} @{sched} = ...

  // ==========================================================================
  // §3.6 — R13 legacy alias (backward compat for src/user/builtins.pdx:28)
  // ==========================================================================

  pub let sys_exit_thread : (u64) -> u64 !{sysreg} @{sched} = ...  // maps to ID 60
}
```

Body of each wrapper: exactly the byte pattern in §3.2 or §3.3.
Nothing else — no local variables, no branches, no memory access.
The `justification` string on each `unsafe` block cites this doc's
enumeration row and the relevant SC+ table entry.

### 3.6 The `sys_exit_thread` legacy alias

Under R13 §C, `sys_exit_thread` was syscall ID 0. Under SC+ (R15.M4),
ID 0 is `sys_read`. A naïve rebuild that removes `sys_exit_thread` or
leaves it pointing at ID 0 would:

- Break `src/user/builtins.pdx:28` (`call sys_exit_thread`) — either
  a link failure (name removed) or a silent misroute to `sys_read`
  with `code` interpreted as `fd` (badly broken; `exit` never happens).

The issue's declared touching scope is `src/user/syscall_shim.pdx`
only — we do not modify `builtins.pdx`. Solution: **retain the
`sys_exit_thread` name; change its body to emit `mov rax, 60`**
(i.e., alias to `sys_exit`). This keeps the R13-era `builtins.pdx`
compiling and behaving semantically identical (thread-scope exit
under a single-task R13 world = process-scope exit under R15's
process world when the task has only one thread — which is every
task in R17). A comment marks the wrapper as a **compatibility
alias, deprecated for new call sites**; a follow-up issue in R17.M2
or R17.M4 can rename the caller and delete the alias.

Same-analysis-with-different-conclusion for `sys_yield`: it has
**no caller** in the current tree (`grep -rn "sys_yield" src/`
returns only the shim's own definition). We delete it outright — no
alias, no follow-up compat surface.

### 3.7 Assembly detail — the full wrapper for each row

For completeness, the 13 wrapper bodies (concrete `block:`
contents):

```pdx
// 1. sys_read (rdi=fd, rsi=buf, rdx=count) → i64
block: { mov rax, 0;  syscall; ret }

// 2. sys_write (rdi=fd, rsi=buf, rdx=count) → i64
block: { mov rax, 1;  syscall; ret }

// 3. sys_open (rdi=path, rsi=flags, rdx=mode) → i64
block: { mov rax, 2;  syscall; ret }

// 4. sys_close (rdi=fd) → i64
block: { mov rax, 3;  syscall; ret }

// 5. sys_cap_invoke (rdi=slot, rsi=op_arg) → u64      -- R13 preserved
block: { mov rax, 4;  syscall; ret }

// 6. sys_debug_puts (rdi=buf, rsi=count) → u64        -- R13 preserved
block: { mov rax, 12; syscall; ret }

// 7. sys_dup2 (rdi=oldfd, rsi=newfd) → i64
block: { mov rax, 32; syscall; ret }

// 8. sys_getpid () → u64
block: { mov rax, 39; syscall; ret }

// 9. sys_fork () → i64
block: { mov rax, 56; syscall; ret }

// 10. sys_execve (rdi=path, rsi=argv, rdx=envp) → i64
block: { mov rax, 59; syscall; ret }

// 11. sys_exit (rdi=status) → i64 (never returns; ret unreachable)
block: { mov rax, 60; syscall; ret }

// 12. sys_wait4 (rdi=pid, rsi=wstatus, rdx=options, rcx=rusage) → i64
block: { mov r10, rcx; mov rax, 61; syscall; ret }

// 13. sys_exit_thread (rdi=code) → i64 (legacy alias for sys_exit)
block: { mov rax, 60; syscall; ret }
```

Total: 12 × 10 + 1 × 13 = **133 emitted bytes** across all wrappers.

## 4. Test canary — build-time byte-pattern verifier

The AC is compile-only: `build-user.sh succeeds` **and** each wrapper
compiles to the exact byte pattern `mov rax, N; syscall; ret` (after
optional shuffle). "Compiles" is verified by `paideia-as`; the
byte-pattern shape is verified by a new **build-time canary** that
objdumps `shell.elf` and matches each wrapper symbol against its
expected pattern.

Runtime exercise of every wrapper against a live kernel lands as
`libc_test.pdx` in **#615** (fingerprint `LIBC TEST OK`, smoke mode
`boot_r17_libc`). This issue installs no boot marker and no
kernel-side witness — the smoke fingerprint is byte-identically green
after this landing.

### 4.1 `tools/verify-syscall-shim.sh` (new)

```bash
#!/usr/bin/env bash
# Byte-pattern canary for src/user/syscall_shim.pdx (R17-M1-001 / #610).
# Verifies each wrapper compiles to the exact SysV→SYSCALL trampoline.
set -euo pipefail

ELF="${1:-build/user/shell.elf}"
FAIL=0

# Expected pattern per wrapper: {name, hex_id, has_shuffle}.
# hex_id is the 2-hex-digit form of the imm32's low byte (bytes 2..5 of the
# `mov rax, imm32` are the little-endian imm32; low byte carries the ID).
declare -a WRAPPERS=(
    "sys_read           00 no"
    "sys_write          01 no"
    "sys_open           02 no"
    "sys_close          03 no"
    "sys_cap_invoke     04 no"
    "sys_debug_puts     0c no"
    "sys_dup2           20 no"
    "sys_getpid         27 no"
    "sys_fork           38 no"
    "sys_execve         3b no"
    "sys_exit           3c no"
    "sys_wait4          3d yes"
    "sys_exit_thread    3c no"
)

for row in "${WRAPPERS[@]}"; do
    read -r name id shuffle <<< "$row"

    # Extract the wrapper's bytes via objdump.
    bytes=$(objdump -d --no-show-raw-insn=no -M intel "$ELF" \
        | awk -v sym="$name" 'BEGIN{seen=0} /^<'"$name"'>:|:$/ {
              if ($0 ~ "<"sym">:") seen=1; else if (seen) exit
          } seen && /^[[:space:]]*[0-9a-f]+:/ {
              # trim address, keep hex bytes column
              sub(/^[[:space:]]*[0-9a-f]+:[[:space:]]*/, "");
              # keep only the hex-bytes column (before the mnemonic)
              n=split($0, f, /  +/); printf "%s ", f[1]
          }' | tr -s ' ' | tr -d '\n' | tr '[:upper:]' '[:lower:]')

    if [[ "$shuffle" == "yes" ]]; then
        want="49 89 ca 48 c7 c0 $id 00 00 00 0f 05 c3"
    else
        want="48 c7 c0 $id 00 00 00 0f 05 c3"
    fi

    # Normalize spacing.
    got=$(echo "$bytes"  | tr -s ' ')
    exp=$(echo "$want"   | tr -s ' ')

    if [[ "$got" == "$exp"* ]]; then
        echo "[ok]   $name: $exp"
    else
        echo "[FAIL] $name"
        echo "         want: $exp"
        echo "         got : $got"
        FAIL=1
    fi
done

if [[ $FAIL -eq 0 ]]; then
    echo "R17 SYSCALL SHIM OK"
    exit 0
else
    echo "R17 SYSCALL SHIM FAIL"
    exit 1
fi
```

The awk fragment for symbol extraction is defensive but not rocket
science; the implementer may prefer a `readelf --syms` +
`dd if=shell.bin bs=1 skip=<offset> count=13` two-liner. Either
approach lands the same guarantee — pin the byte pattern, refuse to
green the build if the assembler drifts.

### 4.2 `tools/build-user.sh` — add verifier invocation

Two-line append at the end of `build-user.sh`:

```bash
echo "[verify-user] byte-pattern canary on shell.elf"
"${REPO_ROOT}/tools/verify-syscall-shim.sh" "${BUILD_DIR}/shell.elf"
```

Failing canary means non-zero exit from `build-user.sh`. The
pre-push hook (per `feedback_paideia_os_no_cicd.md` — no CI/CD;
verification is local) picks up the failure locally before the
commit propagates.

### 4.3 Why no kernel-side runtime witness

Three reasons:

1. **AC is compile-only.** The issue text pins "compiles to
   `mov rax, N; syscall; ret` after arg shuffle" — verified by §4.1.
2. **No user runtime yet.** R17.M2 (#616+) lands `init` which
   actually gets loaded and jumped to as ring-3 code. Prior to init,
   `shell.elf` is dead code in the tree (embedded via
   `tools/userbin_embed.S` for R13 archival; not executed). A
   kernel-side witness that exercises the shim would need to
   fabricate a ring-3 entry, which duplicates the R15.M2 `boot_r15_
   ring3_hello` mode's plumbing without adding new coverage.
3. **Runtime witness exists in the pipeline.** #615's `libc_test.pdx`
   is a bona fide user binary that calls each wrapper and prints
   `LIBC TEST OK`. That is the correct altitude for runtime AC — not
   this issue.

The build-time canary is sufficient discipline: it prevents
paideia-as encoder drift from silently reshaping any wrapper (e.g.,
selecting a different immediate form or emitting a spurious
prologue) without the pre-push hook catching it.

## 5. Addendum to `design/user/syscall-table.md`

Append §8 "Reconciliation with tactical plan '13 syscalls' figure":

> The R14B tactical plan (§Subsystem 7, line 769; §Subsystem 16, line
> 1670) refers to "13 syscalls in §C+". The SC+ frozen table above
> lists 11 entries. The kernel dispatcher
> (`src/kernel/core/syscall/dispatch.pdx`, R15.M4-004 / #538)
> currently handles 12 IDs (SC+ 11 + legacy `sys_cap_invoke` at 4).
> The user shim `src/user/syscall_shim.pdx` (R17-M1-001 / #610)
> exports 13 names: the 12 dispatcher-live IDs + a `sys_exit_thread`
> alias to ID 60 for R13-era caller (`src/user/builtins.pdx:28`)
> backward compatibility.
>
> R13's `sys_yield` (ID 1) is superseded by SC+ `sys_write` (ID 1)
> and is not carried forward. Any future re-introduction requires a
> new SC+ ID allocation + dispatcher entry + shim entry, tracked as
> a follow-up to R17.

This addendum is 8 lines and closes the "13" question permanently.

## 6. LOC estimate

| File                                                          | LOC delta |
|---------------------------------------------------------------|-----------|
| `src/user/syscall_shim.pdx` (extend 4 → 13 wrappers)          | +170      |
| `tools/verify-syscall-shim.sh` (new)                          | +65       |
| `tools/build-user.sh` (append verifier invocation)            | +3        |
| `design/user/syscall-table.md` (§8 addendum)                  | +8        |
| `design/kernel/r17-m1-001-syscall-shim.md` (this doc)         | +410      |
| **Total**                                                     | **~656**  |

Executable / build code: ~240 LOC (170 shim + 65 verifier + 3 build).
Design + prose: ~420 LOC. The 170-LOC shim figure assumes each
wrapper is ~11 lines including the `justification` comment block
and effect signature (13 × 11 = 143) plus module header (~15) and
inter-wrapper section-comment banners (~15).

## 7. Backtrack candidates

Ordered by preference.

### 7.1 Backtrack A — Drop `sys_exit_thread` alias; update `builtins.pdx` in same PR

Rename the R13 caller in `src/user/builtins.pdx:28` from
`call sys_exit_thread` to `call sys_exit`. Delete the legacy alias
from the shim. Ship 12 wrappers (not 13).

Consequence: cleaner name-space; two files touched (issue's declared
scope was one). Ship-count matches SC+-live dispatcher exactly
(12). Explains the "13" figure in the issue title as an
overcount from the tactical plan; addendum §5 still records the
reconciliation.

**Recommend as first backtrack** if the reviewer prefers scope
expansion over name-space pollution. Not primary because the issue
explicitly declares `Touching: src/user/syscall_shim.pdx` (single
file) and a scope creep even to a one-line adjacent edit is a
governance departure worth avoiding when a pragmatic alias exists.

### 7.2 Backtrack B — Include `sys_yield` at a new SC+ ID (e.g., 24)

Allocate `sys_yield` a fresh SC+ ID that Linux does not use for a
common syscall (Linux 24 is `sched_yield` — same semantics; take it
verbatim). Add wrapper. Add dispatcher entry (stub → ENOSYS at
R17.M1; real body in a follow-up).

Consequence: matches Linux more literally; enables future
cooperative-yield loops in shell. Requires amending
`design/user/syscall-table.md` (SC+ freeze extension — a governance
step) and touching `src/kernel/core/syscall/dispatch.pdx` (blows
scope). Ship-count becomes 14 (SC+ 12 + yield + exit_thread alias).

**Reject as primary.** SC+ freeze is intentional; extending it is
its own issue. No current caller of sys_yield exists in the tree,
so shipping the wrapper is speculative.

### 7.3 Backtrack C — Move errno translation into this shim

Wrap every return so negative `rax` writes `_user_errno = -rax` and
returns `-1`, per the tactical plan's §Subsystem 16 primary
interfaces ("Wrappers return -errno directly").

Consequence: each wrapper grows from 10 bytes to ~30 bytes (test
sign; conditional store to `_user_errno`; conditional return -1).
Loses the "compiles to `mov rax, N; syscall; ret`" AC — the wrapper
now has branches.

**Reject.** The tactical plan explicitly separates this into a
distinct issue (#613 `r17-m1-004-user-errno-slot`). The AC's
byte-pattern shape is what makes the canary in §4.1 possible.
Keeping this shim pure (SysV↔SYSCALL translation only) preserves
the invariant.

### 7.4 Backtrack D — Use 64-bit immediate form for the syscall number

Emit `mov rax, imm64` (`48 B8 <imm64>` = 10 bytes for the mov, 13
bytes total per wrapper) instead of `mov rax, imm32` (`48 C7 C0
<imm32>` = 7 bytes for the mov, 10 bytes total per wrapper).

Consequence: uniform 13-byte wrapper size (including the `sys_wait4`
shuffle version becomes 16 bytes). Byte-pattern canary must accept
the alternate encoding. paideia-as's `mov r64, imm` selects the
imm32 form when the value fits in i32; forcing imm64 requires an
encoder-level directive.

**Reject.** The R13 baseline is imm32 (`48 C7 C0`) — no reason to
churn it. Encoder selection is stable; the canary pins the current
choice.

### 7.5 Backtrack E — Split the shim into per-subsystem files

`src/user/sys/io.pdx` (read/write/open/close/dup2),
`src/user/sys/proc.pdx` (fork/execve/exit/wait4/getpid),
`src/user/sys/cap.pdx` (cap_invoke), `src/user/sys/debug.pdx`
(debug_puts). Each file has ~3 wrappers.

Consequence: cleaner navigation as the shim grows past ~20 entries.
At 13 wrappers the split is premature; the whole file fits on one
screen. `build-user.sh` walks `find -name '*.pdx'` so no build
change needed, but the canary in §4.1 would need to point at a
single monolithic `shell.elf` (unchanged — the linker rolls them
together).

**Reject at R17.M1.** Revisit at R18+ when the shim likely grows
past ~25 wrappers (mmap, ioctl, signal, epoll analogs, …).

## 8. Tractability

**HIGH.**

- **No paideia-as encoder gap.** Every instruction used
  (`mov rax, imm32`, `mov r10, rcx`, `syscall`, `ret`) is already
  emitted elsewhere in the tree. `mov rax, imm32` is 4 places in
  the current R13 shim; `mov r10, r*` is exercised in
  `src/kernel/core/int/idt.pdx`, `.../fs/vnode_pool.pdx`,
  `.../fs/mount.pdx`; `syscall` and `ret` are trivial. Issue
  declares `Encoder gaps: none` — verified.
- **No kernel-side change.** The dispatcher already accepts all 12
  IDs the shim emits (missing bodies return ENOSYS, which is fine
  for a compile-time AC). Runtime AC lands with #615.
- **No smoke-fingerprint drift.** No boot marker added. Every
  smoke (`boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`,
  `boot_r12_denial`, plus every R14b/R15/R16 mode) stays
  byte-identically green through this commit. The build-time canary
  emits `R17 SYSCALL SHIM OK` to build-user.sh's stdout, not to the
  boot fingerprint.
- **No cross-repo escalation expected.** paideia-as ships every
  needed encoding. If a wrapper's byte pattern comes out different
  from §4.1's `want` string, the escalation is against the current
  paideia-as (find why `mov rax, N` regressed, file
  paideia-as issue, bump submodule) — but no upstream gap is
  anticipated because the R13 shim already emits identical bytes.
- **~170 LOC executable across a single existing `.pdx` file** +
  65-LOC canary + 3-line build.sh append. Fits the tempo of the
  other R17.M1 issues (#611–#615), each of which is a similarly
  scoped one-module addition.
- **`sys_exit_thread` legacy alias is a 4-line addition** — 3 lines
  of Pdx (mov/syscall/ret) inside a `pub let` block + one comment
  citing this doc's §3.6. No caller-side change required.

Known follow-ups (not blockers for #610):

- **#611 (`r17-m1-002-user-strlen-memcmp`)** — parallelizable; no
  shim dependency.
- **#613 (`r17-m1-004-user-errno-slot`)** — depends on this issue's
  wrappers; wraps their raw-rax return.
- **#615 (`r17-m1-006-user-smoke-libc`)** — runtime AC for the shim;
  lands the `LIBC TEST OK` fingerprint via a real ring-3 user
  binary.
- **R17.M2 (#616+)** — init consumes the wrappers as its first
  ring-3 caller in production.
- **Follow-up rename issue** (post-R17.M4) — remove the
  `sys_exit_thread` legacy alias and rename `builtins.pdx`'s caller
  to `sys_exit`. Not scheduled; recorded as tech debt.

## 9. Cross-cutting risks

- **paideia-as `mov rax, imm` encoding drift.** If paideia-as ships
  a future version that prefers the imm8-sign-extended form
  (`48 83 C0 <imm8>`) for small values, every wrapper's byte size
  shrinks and the §4.1 canary rejects the build. Mitigation: canary
  MUST run pre-push; when the drift happens, the fix is to update
  the `want` string in the canary AND re-freeze the byte pattern in
  this doc. This is a **desired failure mode** — silent encoder
  drift is worse than a caught mismatch.
- **`sys_exit_thread` alias divergence from `sys_exit`.** If
  `sys_exit` ever gains additional semantics that `exit_thread`
  should NOT share (e.g., process-wide vs. thread-wide teardown
  when true multi-threading lands post-R17), the alias becomes
  incorrect. Mitigation: today R17 has one thread per process, so
  the aliasing is exact. When threading lands (post-R17 vision),
  the follow-up rename issue (§8) MUST land before the alias's
  semantics diverge from its name.
- **SC+ ID reallocation.** If a future SC+ freeze extension moves,
  say, `sys_write` off ID 1, the shim's `mov rax, 1` becomes a call
  to whatever new syscall inherits ID 1. Mitigation: SC+ freeze is
  a governance-heavy step (design/user/syscall-table.md); any
  renumbering issue lists this shim in its `blocks:` and must ship
  a shim update in the same PR. The single-source-of-truth is the
  SC+ table doc; the shim materializes it and MUST be co-updated.
- **`sys_wait4` r10 shuffle rot.** If the SC+ freeze ever redefines
  `wait4`'s 4th argument to fit in `rcx` natively (impossible — SysV
  4th arg is always `rcx`), or if paideia-as introduces a compiler
  pass that recognizes SysV→SYSCALL shuffle and elides the `mov r10,
  rcx` (also impossible — the shuffle is semantically required),
  the wrapper breaks. Both scenarios are outside the physical
  possibility of the ABI; the risk is theoretical only.
- **Canary false negative.** If the objdump output format changes
  across binutils versions, `verify-syscall-shim.sh`'s awk parser
  fails to extract bytes and the canary passes vacuously (no rows
  to check). Mitigation: the script MUST exit non-zero if it finds
  zero wrappers in the ELF (add a sanity assertion after the loop:
  `[[ ${#WRAPPERS[@]} -eq $matched ]] || exit 1`).

## 10. References

- Issue: paideia-os#610
- Milestone: paideia-os milestones/69 (R17.M1 libc-lite for userland)
- Sibling issues (R17.M1): #611 strlen/memcmp, #612 memcpy/memset,
  #613 errno slot, #614 puts/getline, #615 libc smoke
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 16 (lines 1635–1710); §Subsystem 7 (line 769 — the
  13-syscall enumeration this doc reconciles)
- Master plan: `design/milestones/r14b-master-plan.md` §R17 (libc)
- SC+ frozen table: `design/user/syscall-table.md` (R15.M4-001 /
  #535 — source of truth for numbers)
- R13 baseline: `src/user/syscall_shim.pdx` (R13-m7-002 / #433) —
  the file this issue extends
- Prior R13 audit: `design/audit/entries/r13-m7-002-syscall-shim.md`
- Kernel dispatcher: `src/kernel/core/syscall/dispatch.pdx`
  (R15-M4-004 / #538) — the receiving end of every wrapper
- R13 legacy caller preserved by §3.6: `src/user/builtins.pdx:28`
- paideia-as encoder baseline (`mov rN, rM` reg-reg): tests at
  `tools/paideia-as/tests/build-emit/pa7c_unsafe_body/unsafe_body_mov_reg_reg.pdx`;
  live use at `src/kernel/core/fs/vnode_pool.pdx:71`,
  `src/kernel/core/int/idt.pdx:265`
