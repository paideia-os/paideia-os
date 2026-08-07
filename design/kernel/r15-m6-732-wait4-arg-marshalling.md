# R15-M6-732: dispatch_wait4 arg-register mixup — wstatus read from `rsi` (pid), not `rdx`

**Issue**: paideia-os#732
**Blocks**: paideia-os#723 AC true closure (WAIT half)
**Landed at**: (this commit)
**Depends on**: #731 (rax preservation) landed at `55571e8` — without it, the -EFAULT wait4 return was silently overwritten by user_pml4_pa and `jl init_shutdown` never fired.

---

## 1. Empirical evidence

At `29071dc` (still present at `55571e8`), debugger-instrumentation captured:

- At the `dispatch_wait4:` label entry, `rsi = 0xFFFFFFFFFFFFFFFF`.
- The subsequent `user_ptr_ok(rsi, 4)` (from #724 D5-verify's wstatus fault gate) correctly rejected `-1` as a kernel-half address → returned non-zero.
- Control fell through to `dispatch_wait4_efault:` → `mov rax, 0xFFFFFFFFFFFFFFF2` (-EFAULT).
- Pre-#731, that -EFAULT was masked by the epilogue's rax-clobber (silently rewritten to user_pml4_pa, a positive small integer); `init.pdx`'s post-wait `cmp rax, 0; jl init_shutdown` never fired; a stale/never-updated `wait_msg` (hardcoded "WAIT: pid=2 status=42") still printed spuriously.
- Post-#731 (`55571e8`), the real -EFAULT surfaces at userspace; `jl init_shutdown` now fires; the `wait_msg` print is gone from the fingerprint (see `tests/r17/expected-boot-r17-init.txt` — line "WAIT: pid=2 status=42" absent).

`0xFFFFFFFFFFFFFFFF` is the exact bit pattern of `pid_t = -1`, which is `init.pdx:114-115`'s `xor rdi, rdi; dec rdi` (wait-for-any-child sentinel per POSIX wait4 semantics).

## 2. Arg-flow trace

Trace from `init.pdx`'s call site to the point of failure, register by register.

### 2.1 init.pdx (SysV C ABI on entry to `call sys_wait4`)

Source: `src/user/init.pdx:111-119`

```
init_parent:
  xor rdi, rdi;
  dec rdi;                      // rdi = -1 (pid_t = any child)
  lea rsi, [rip + wait_status]; // rsi = &wait_status (u32 wstatus buffer)
  xor rdx, rdx;                 // rdx = 0 (options = 0)
  xor rcx, rcx;                 // rcx = 0 (rusage = NULL)
  call sys_wait4;
```

Correct SysV C ABI setup for `wait4(pid, wstatus, options, rusage)`:
- `rdi` = pid = -1
- `rsi` = wstatus = &wait_status
- `rdx` = options = 0
- `rcx` = rusage = NULL

### 2.2 sys_wait4 shim (SysV C ABI → SYSCALL ABI)

Source: `src/user/syscall_shim.pdx:152-162`

```
pub let sys_wait4 : (u64, u64, u64, u64) -> u64 ... =
  fn (pid: u64) (wstatus: u64) (options: u64) (rusage: u64) -> unsafe {
    ...
    block: {
      mov r10, rcx;   // arg3 shuffle: SysV rcx → SYSCALL r10
      mov rax, 61;    // sysno
      syscall;
      ret
    }
  }
```

Post-shim, immediately before `syscall`:
- `rax` = 61 (sys_wait4)
- `rdi` = -1 (pid)
- `rsi` = &wait_status (wstatus)
- `rdx` = 0 (options)
- `r10` = 0 (rusage) — moved from rcx per SysV→SYSCALL arg3 shuffle (rcx would be clobbered by SYSCALL saving user RIP)
- `rcx` = (about to be clobbered by SYSCALL → user RIP)

This is correct per Linux/SC+ x86-64 SYSCALL ABI (SDM Vol 3A §6.15).

### 2.3 syscall_entry (SYSCALL ABI → SysV C ABI)

Source: `src/kernel/core/syscall/entry.pdx:92-97`

```
// Shuffle SYSCALL ABI -> SysV C ABI (rax->rdi restored via pop below)
mov r8, r10;    // r8 = old r10 (arg3)
mov rcx, rdx;   // rcx = old rdx (arg2)
mov rdx, rsi;   // rdx = old rsi (arg1)
mov rsi, rdi;   // rsi = old rdi (arg0)
pop rdi;        // rdi = sysno (pushed at step 8)

// Dispatch (result in rax)
call syscall_dispatch;
```

Post-shuffle, entering `syscall_dispatch`:
- `rdi` = sysno = 61
- `rsi` = arg0 = user's rdi = **-1 (pid)**
- `rdx` = arg1 = user's rsi = **&wait_status (wstatus)**
- `rcx` = arg2 = user's rdx = 0 (options)
- `r8`  = arg3 = user's r10 = 0 (rusage)

`syscall_dispatch`'s type signature confirms this: `syscall_dispatch : (u64, u64, u64, u64, u64) -> u64` with `(sysno, a0, a1, a2, a3)`. The first arg goes in rdi (sysno), then a0..a3 fill rsi/rdx/rcx/r8 per SysV.

### 2.4 dispatch_wait4 (pre-fix — the bug)

Source: `src/kernel/core/syscall/dispatch.pdx:266-322` (pre-fix)

```
dispatch_wait4:
mov rax, [rip + _current_tcb];
mov rdi, rax;                         // rdi = current
push rsi;                             // save wstatus user ptr across call   ← BUG
call sys_wait_body;
pop rsi;                              // restore wstatus ptr                 ← BUG
...
dispatch_wait4_writeback:
cmp rsi, 0;                           // ← rsi = -1 (pid), not wstatus!
...
mov rdi, rsi;                         // arg0 = wstatus va                   ← passes -1
mov rsi, 4;                           // arg1 = len
call user_ptr_ok;                     // rejects -1 as kernel-half → -EFAULT
...
mov [rsi], edx;                       // (unreached; -EFAULT path taken)
```

The handler assumes wstatus lives in `rsi`. Per §2.3, wstatus is in **`rdx`**; `rsi` is the pid argument (`-1` for init). Every save/restore across `sys_wait_body` and `sched_block`, every `cmp rsi, 0` null-check, every `mov rdi, rsi; call user_ptr_ok` — all read the pid instead.

## 3. Root cause

Single line, single file: `src/kernel/core/syscall/dispatch.pdx:269` — `push rsi` should read the wstatus pointer (which is in `rdx` after `syscall_entry`'s SysV shuffle), not `rsi` (which holds the pid arg after that same shuffle).

The mixup traces to a mis-mapping between two conventions the author held simultaneously:

1. **SC+ wait4 signature**: `wait4(pid, wstatus, ...)` — wstatus is arg1.
2. **SysV C ABI on entry to `syscall_dispatch`**: `syscall_dispatch(sysno, a0, a1, a2, a3)` — a1 goes in **`rdx`**, not `rsi` (rsi is a0).

The handler was coded as if wstatus were a0 (in rsi), when it is a1 (in rdx). Every other dispatch handler that takes ≥1 arg was audited (§5) and gets this right by using rdx/rcx/r8 for a1/a2/a3 respectively. `dispatch_wait4` is the sole offender because the wstatus flow (save across nested calls, null-check, then fault-gated writeback) makes the register assumption more visible than pure "pass through to body" handlers where the SysV registers already line up.

## 4. Fix

Move the wstatus pointer from `rdx` (correct) into `rsi` (where the rest of the handler expects it) as the first instruction of the handler, then leave the remaining logic unchanged. The pid arg (previously in rsi) is discarded — `sys_wait_body` scans _all_ children of `current` (its own body derives the parent pid from `current->pid` and matches every child regardless of the user's pid arg), which is the correct semantic for init's `pid=-1` (wait-for-any-child) case. Full POSIX wait4 pid-filtering (specific pid, process group) is unimplemented at R17.M0 and is not in the #723 AC.

**Diff**:

```
 dispatch_wait4:
+// #732 fix: syscall_dispatch's SysV C ABI puts arg0 (pid) in rsi and
+// arg1 (wstatus) in rdx (see entry.pdx §shuffle at L92-97). Prior code
+// read wstatus from rsi — that's the pid arg (-1 for init's wait-for-
+// any-child), which user_ptr_ok correctly rejected as kernel-half →
+// -EFAULT; pre-#731 the epilogue's rax-clobber masked that failure.
+// Move the real wstatus pointer into rsi so the rest of this handler
+// (which was written against the assumption "wstatus in rsi") operates
+// on the correct value. The pid arg is discarded: sys_wait_body scans
+// all children of current (matching init's pid=-1 wait-for-any-child
+// semantic); full POSIX pid-filtering is out of scope at R17.M0.
+mov rsi, rdx;
 mov rax, [rip + _current_tcb];
 mov rdi, rax;                         // rdi = current
 push rsi;                             // save wstatus user ptr across call
 call sys_wait_body;
```

Minimal 1-line functional change (`mov rsi, rdx;` at the top). No other lines in `dispatch_wait4` need to change — the rest of the handler already uses `rsi` consistently as the wstatus register.

### 4.1 Alternatives considered and rejected

- **Rewrite handler to use `rdx` throughout**: `rdx` is clobbered by `sys_wait_body`'s return convention (rax=pid, rdx=status). We'd need to save/restore rdx across the call anyway, and then `mov [rdx], edx` for the writeback would collide with itself. Not cleaner than the 1-line initial `mov`.
- **Hold wstatus in a callee-saved register (rbx/r12)**: Would require prologue/epilogue push/pop and is more surgery than the bug warrants. The `push rsi; ...; pop rsi` pattern already survives all intermediate calls that follow SysV callee-save discipline (`sys_wait_body`, `sched_block`, `user_ptr_ok`). Reserved for a future refactor if `dispatch_wait4` grows more nested calls.
- **Fix at `syscall_entry`'s shuffle**: The shuffle is correct per SysV C ABI and matches every other dispatch handler. Changing it would break ~10 other handlers to fix one.

## 5. Audit — do other dispatch handlers have the same bug?

Manual audit of every `dispatch_*` handler in `dispatch.pdx` against the entry.pdx shuffle. Convention check: does the handler use `rsi` for arg0, `rdx` for arg1, `rcx` for arg2, `r8` for arg3?

| Handler | Signature | Arg regs used | Correct? |
| --- | --- | --- | --- |
| `dispatch_read` | (fd, buf, count) | rsi=fd, rdx=buf, rcx=count → forwarded to `sys_read_body` as-is | Yes |
| `dispatch_write` | (fd, buf, count) | rsi=fd, rdx=buf, rcx=count (both UART fast-path and body) | Yes |
| `dispatch_open` | (path, flags, mode) | rsi=path, rdx=flags, rcx=mode | Yes |
| `dispatch_close` | (fd) | rsi=fd | Yes |
| `dispatch_cap_invoke` | (slot, op_arg) | `mov rdi, rsi; mov rsi, rdx` — slot from rsi (a0), op_arg from rdx (a1) | Yes |
| `dispatch_debug_puts` | (buf, count) | `mov rdi, rsi; mov rsi, rdx` — buf from rsi (a0), count from rdx (a1) | Yes |
| `dispatch_dup2` | (oldfd, newfd) | rsi=oldfd, rdx=newfd | Yes |
| `dispatch_getpid` | () | no args | N/A |
| `dispatch_fork` | () | no args | N/A |
| `dispatch_execve` | (path, argv, envp) | rsi=path, rdx=argv, rcx=envp | Yes |
| `dispatch_exit` | (status) | rsi=status (a0) | Yes |
| **`dispatch_wait4`** | **(pid, wstatus, options, rusage)** | **rsi read as wstatus, but rsi=pid** | **NO** |

Conclusion: `dispatch_wait4` is the sole offender. The other 4-arg-capable handlers happen to place their "interesting" arg (fd, path, etc.) at position 0 (rsi), where the SysV register alignment matches — the register mixup would surface only when a handler's semantic-arg-of-interest is at position 1 (rdx) or later AND the handler reads it directly rather than forwarding to a body function via the natural SysV alignment. `dispatch_wait4` fits: wstatus is at position 1, and it's manipulated inside the dispatch layer (save across calls, null-check, fault-gate) rather than being pass-through to `sys_wait_body` (which doesn't consume it — it returns status in rdx and dispatch writes it back).

No additional issues to file. Latent-bug audit clean.

## 6. Verification

### 6.1 Direct wire proof

Post-fix, boot_r17_init should emit `WAIT: pid=2 status=42\n` after `CHILD HELLO 42`. The pid/status values are still hardcoded in `init.pdx`'s `wait_msg` (not runtime-formatted from wait4's actual return values — that is issue #723 D12's scope and is deliberately deferred). What #732 fixes is: wait4 no longer returns -EFAULT; `init.pdx`'s post-wait `jl init_shutdown` no longer fires; the `wait_msg` print reaches the wire.

The honest post-fix wire sequence is:

```
INIT ENTERED RING3
INIT OK
CHILD HELLO 42
WAIT: pid=2 status=42
REAPED
```

The `WAIT`/`REAPED` lines reappearing on wire (missing from current `tests/r17/expected-boot-r17-init.txt` due to the pre-fix -EFAULT-then-shutdown path) is the fix's proof.

### 6.2 Test fingerprint

Add `WAIT: pid=2 status=42` and `REAPED` back to `tests/r17/expected-boot-r17-init.txt`. The pid/status numbers are hardcoded so they are stable enough for a full-line fingerprint check even under #735's pid-leak (init still shows the hardcoded string regardless of wait4's actual pid return).

### 6.3 Regression coverage

Full pre-push 10-mode matrix (boot_r8_only, boot_r10, boot_r11, boot_r12, boot_r12_denial, boot_r14b_hivma, boot_r14b_kpti, boot_r14b_ipi, boot_r14b_loader, ...) plus the r17-specific boot_r17_init.

## 7. Scope boundary

**In scope**: The register mixup that makes wait4 spuriously -EFAULT.

**Out of scope (deferred)**:
- **D12** (`init.pdx` runtime u32→decimal formatting): `wait_msg` will still print the hardcoded "pid=2 status=42" string. Real pid/status appear in wait4's return value in rax/rdx (rax = child pid, rdx = exit status) but init doesn't format them. Making the number honest requires a decimal-print utility in init or the shim, which is D12's landing.
- **#735** (pid leak): after this fix, the real reaped child pid may be 23 (or whatever the leak produces) rather than 2. That doesn't affect this fix's proof: init's `wait_msg` prints the hardcoded string regardless.
- **#733** (any other #723 AC deltas): separate landings.

## 8. Post-landing state of #723 AC

Remaining to true closure:
- **D12**: honest runtime pid/status formatting in `init.pdx`'s wait message.
- **#733**: (whatever remains on this ticket at time of investigation).
- **#735**: pid leak — cosmetic for #723 AC given D12's string is currently hardcoded, but real once D12 lands.
