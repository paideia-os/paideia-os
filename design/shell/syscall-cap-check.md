# Syscall-entry capability check integration (R125.M4)

**Wave:** UMB-W12
**Issue:** paideia-os #2594
**Status:** Landed (M4 bridge posture).
**Scope:** Kernel syscall dispatch; new `src/kernel/core/syscall/cap_check.pdx`;
dispatch-layer insertion in `src/kernel/core/syscall/dispatch.pdx`; boot wire
in `src/kernel/boot/kernel_main.pdx`.

---

## 1. Why this document exists

R125 (umbrella **paideia-os #2478**, "every command runs in a bounded
cap-flow") is a stack of four milestones, three of which already landed:

| Milestone | Wave | Issue | Lands |
| --- | --- | --- | --- |
| R125.M1 | W1 (W87) | #2591 | `KIND_CAP_ENV` substrate: 16 envs × 6 slots in `_cap_env_table`. Shells mint, insert, freeze, destroy. |
| R125.M2 | W96 | #2592 | `svc.cap-minter` daemon with `_cap_minter_derive`, `_cap_minter_set_active_env`, `_cap_minter_get_active_env`. |
| R125.M3 | W98 | #2593, #2733 | ELF `.caps.decl` loader (`caps_decl_locate` → `caps_decl_parse` → `caps_decl_apply`) with sys_execve splice. Soft-fail bridge posture. |
| **R125.M4** | **W12** | **#2594** | **This document.** Syscall-entry gate: before dispatching to a syscall body, verify the caller's active cap-env grants the required right. |

Without M4, every userspace process could call every syscall regardless of
what caps the shell handed in. The R125 "bounded cap-flow" invariant stays
advisory, not enforced. M4 flips the gate.

---

## 2. The problem

The kernel's syscall dispatch has three structural phases:

1. **Entry trampoline** (`entry.pdx`): SysV left-rotate `rax/rdi/rsi/rdx/r10/r8/r9`
   so the SysV syscall-ABI `syscno + 6 args` collapses to a function call to
   `syscall_dispatch` with `rdi=sysno, rsi=a0, rdx=a1, rcx=a2, r8=a3`.
2. **Dispatch cascade** (`dispatch.pdx` lines ~400–4050): a linear
   `cmp/je` chain over sysnos, each arm shuffles its args and calls the
   per-syscall body.
3. **Per-body logic**: individual handlers in `syscall/handlers/*.pdx`
   enforce their own user_ptr_ok / KPTI-bounce / argument validation.

Prior to M4 there was **no cap-rights check** at any of these phases. A
ring-3 caller holding no caps at all could invoke `sys_mount`, `sys_dek_seal`,
and every other syscall just by issuing the right int/syscall instruction.
The R125 cap-env substrate existed but no code path consulted it on the
syscall boundary.

## 3. The design

### 3.1 Insertion point

The cap check lives **in the dispatcher**, between the out-of-band 517/527
arms and the main bounds check:

```
cmp rdi, 517; je dispatch_cwd_resolve;        // out-of-band arm (M4 bypass)
cmp rdi, 527; je dispatch_pdxfs_fault_inject; // out-of-band arm (M4 bypass)
                                              // >>> cap-check preamble <<<
cmp rdi, 137; ja dispatch_enosys;             // main bounds check
cmp rdi, 0;   je dispatch_read;               // dispatch cascade starts
...
```

Three reasons:

1. **One site, O(syscalls) coverage.** Every arrival to a real handler
   funnels through this point. A per-handler check (as the IPC family does
   via `ipc_slot_to_endpoint`) would require 100+ edits and leave gaps.
2. **Before the arm shuffle.** The arms clobber `rdi/rsi/rdx/rcx/r8`
   repositioning args. The check runs while they still match the SysV
   syscall-ABI left-rotate, so the saved copies on the stack have a
   predictable layout.
3. **After 517/527.** Those two sysnos are supervisor-only pre-reserved
   slots that M4 does not yet cover (table is sized to 138 for the in-band
   0..137 range; 517/527 are out-of-band and M5 widens).

### 3.2 Rights table

A new static `[u64; 138]` in `cap_check.pdx`:

```
_syscall_rights_table[sysno] = required_right_mask
```

At M4, only four entries are non-zero:

| Sysno | Name            | Required right mask      |
| ----- | --------------- | ------------------------ |
| 75    | sys_mount       | `R_SYS_MOUNT     = 0x001`|
| 135   | sys_vol_mint    | `R_SYS_VOL_MINT  = 0x002`|
| 136   | sys_dek_seal    | `R_SYS_CRYPTO    = 0x004`|
| 137   | sys_dek_apply   | `R_SYS_CRYPTO    = 0x004`|

Every other sysno keeps `R_SYS_ANY = 0`, which the fast-path returns
`CC_OK` for without any env scan.

Boot init (`_syscall_rights_table_init`) is called from `kernel_main_tail`
right after `_cap_minter_init` and before `_shell_session_init`. Without
the call the gate still runs; the bss-zero table reads `R_SYS_ANY` for
every sysno which is identical to the gate being bypassed, so **a missed
wire fails open, not closed.** The boot fingerprint `SYSCALL CAP_CHECK
TABLE OK` is the audit anchor.

### 3.3 Check body

```
_syscall_cap_check(sysno, caller_env_handle) -> errno
```

| Phase | Check | Return |
| ----- | ----- | ------ |
| 1 | `sysno >= 138` | `CC_BAD_SYSNO` |
| 2 | `_syscall_rights_table[sysno] == 0` | `CC_OK` (fast-path) |
| 3 | `caller_env_handle == 0xFF` (`CM_ENV_NONE`) | `CC_OK` (bridge soft-fail) |
| 3 | `caller_env_handle >= 16` (`CAP_ENV_MAX`) | `CC_OK` (treat as unset) |
| 4 | Scan slots 0..5 via `cap_env_lookup`; find a slot where `(stored & required) == required` | `CC_OK` on hit |
| 4 | Exhaust all 6 slots | `CC_DENIED` |

### 3.4 Return taxonomy

Three internal codes, chosen in the clean 0x0F40..0x0F41 band so an audit
grep is trivial and they can never collide with the Linux-style negative-
errno sentinels (0xFFFFFxxx band):

| Code | Value   | Dispatch returns to userspace |
| ---- | ------- | ----------------------------- |
| `CC_OK`        | `0`      | — (dispatch cascade continues) |
| `CC_DENIED`    | `0x0F40` | `-EACCES = 0xFFFFFFFFFFFFFFF3` |
| `CC_BAD_SYSNO` | `0x0F41` | `-ENOSYS = 0xFFFFFFFFFFFFFFDA` |

`CC_BAD_SYSNO` deliberately maps to the same `-ENOSYS` the existing
`dispatch_enosys` arm returns, so a ring-3 probe cannot distinguish
"table out-of-range" from "kernel-side ENOSYS stub". The internal
distinction is kept for the audit grep only.

### 3.5 Cap interpretation (M4 simplification)

A KIND_CAP_ENV slot stores a u64. M3's `caps_decl_apply` → `_cap_minter_
derive` pipeline writes **cap-table indices** into those slots at execve
time.

M4 reads the stored u64 as a **rights mask directly** and tests
`(stored & required) == required`. Two reasons:

1. The task directive spells the check that way ("scan for a cap whose
   `rights & required_right == required_right`") — treating the slot
   value as a bitmask is the smallest literal reading.
2. The shell is the only cap-env minter at R125.M4 and already picks
   which rights-level mask to store (R_SYS_* constants) when it mints
   caps for a child command.

M5 (deferred) swaps the direct read for a `cap_table[idx + 8]` fetch to
recover the full capability-descriptor semantics. The scan shape (slot
0..5, `rights & required == required`) stays identical.

### 3.6 Bridge posture

M4 is **intentionally incomplete**. Three softening rules keep the kernel
booting while the forward path tightens:

1. **Only four populated sysnos.** sys_mount / sys_vol_mint / sys_dek_seal
   / sys_dek_apply are the supervisor-privileged volume/crypto surface
   that already runs through the shell's cap-env (R123 cmd-module launch).
   Every other syscall (read, write, open, pipe, fork, execve, mkdir,
   chdir, …) stays unchecked at M4.
2. **Env-unset → CC_OK.** `caller_env_handle == 0xFF` (returned by
   `_cap_minter_get_active_env` when no env is bound) passes. Kernel-
   origin paths and the pre-userspace init task do not run under any
   cap-env; failing them hard would break every boot witness.
3. **Out-of-range env → CC_OK.** `caller_env_handle >= 16` is treated the
   same as 0xFF. A nonsense handle is almost certainly a stale harness
   pass; the audit trail belongs in `svc.cap-minter`'s own fingerprints.

M5 (follow-on) flips every rule. The table grows to cover every sysno;
env-unset becomes `CC_DENIED` once the init task mint-FREEZEs its own
supervisor cap-env; out-of-range becomes `CC_DENIED` once the per-task
cap-env binding is stable.

---

## 4. Interaction with R125.M3

M3 landed `caps_decl_apply` on the `sys_execve_body` tail. At execve
time, the ELF's `.caps.decl` section (if present) is parsed and each
declared cap is derived via `_cap_minter_derive` into the active
cap-env's free slot. M3's posture is **soft-fail**: any manifest error
klogs but does not abort execve.

M4 picks up where M3 left off:

| Boundary | M3 | M4 |
| -------- | -- | -- |
| execve (`sys_execve_body`) | caps.decl parsed; caps inserted into active env; soft-fail on malformed decl | unchanged |
| syscall-entry (`syscall_dispatch` preamble) | — | **new gate**: `_syscall_cap_check(sysno, active_env)` runs before the dispatch cascade |

The two layers share `_cap_minter_get_active_env` as the single
caller-identity source: M3 writes to it (via `_cap_minter_set_active_env`
at execve bind time), M4 reads from it. There is no new state introduced
at M4 — the entire check runs over the M1 table and the M2 ambient-env
slot.

A caller that successfully invoked `caps_decl_apply` with a correct
`.caps.decl` declaring `mount` and `crypto` caps now sees its M4 syscall
check pass for the four populated sysnos. A caller whose manifest is
missing (M3 soft-fail trajectory) and whose env is unset still passes
every M4 check (bridge-posture softening (b)). M5 is the single-flip
transition from this soft-fail stack to a hard-fail stack.

---

## 5. Code map

| File | Role | LOC (±) |
| ---- | ---- | ------- |
| `src/kernel/core/syscall/cap_check.pdx` | **NEW.** Rights-table storage, `_syscall_rights_table_init`, `_syscall_cap_check`. | ~330 |
| `src/kernel/core/syscall/dispatch.pdx` | Preamble inserted between 517/527 arms and main bounds check; fail arms (`sd_cap_check_fail`, `sd_cap_denied`) added near `dispatch_enosys`. | +85 |
| `src/kernel/boot/kernel_main.pdx` | `call _syscall_rights_table_init` inserted after `_cap_minter_init`, before `_shell_session_init`. | +15 |
| `design/shell/syscall-cap-check.md` | **This document.** | ~250 |

### 5.1 Dispatch preamble shape

```
// (after cmp rdi, 517 ... je dispatch_pdxfs_fault_inject)
push rsi;                                 // save a0           (%16==0)
push rdx;                                 // save a1           (%16==8)
push rcx;                                 // save a2           (%16==0)
push r8;                                  // save a3           (%16==8)
push rdi;                                 // save sysno (TOS)  (%16==0)

call _cap_minter_get_active_env;          // rax = env (0xFF unset)
mov rsi, rax;                             // arg2 = caller env_handle
mov rdi, [rsp + 0];                       // reload sysno from TOS
call _syscall_cap_check;                  // rax = CC_* code

cmp rax, 0;                               // CC_OK ?
jne sd_cap_check_fail;

// CC_OK: restore the SysV args, fall through to bounds check.
pop rdi;  pop r8;  pop rcx;  pop rdx;  pop rsi;
// (falls through to cmp rdi, 137; ja dispatch_enosys)
```

### 5.2 Fail arms

```
sd_cap_check_fail:
  mov r10, 0x0F40;                          // CC_DENIED
  cmp rax, r10;
  je  sd_cap_denied;
  // CC_BAD_SYSNO fallthrough.
  add rsp, 40;                              // discard 5 saved args
  mov rax, 0xFFFFFFFFFFFFFFDA;              // -ENOSYS
  ret;

sd_cap_denied:
  add rsp, 40;                              // discard 5 saved args
  mov rax, 0xFFFFFFFFFFFFFFF3;              // -EACCES
  ret;
```

### 5.3 Register plan audit

Entry to `syscall_dispatch`: `rsp%16==8` (SysV call pushed the return
address).
- 5 pushes → +40 → `rsp%16==0` (call-ready at both nested calls).
- `[rsp + 0]` is the top of stack = saved sysno (last push = rdi).
- Pop order (reverse): rdi, r8, rcx, rdx, rsi → back to entry parity.
- On fail: `add rsp, 40` discards all 5 at once; `rsp` back to entry
  parity before `ret`.

Nested calls (`_cap_minter_get_active_env`, `_syscall_cap_check`):
- Both callees are SysV-correct and preserve `rbx/r12/r13/r14/r15`.
- Both see `rsp%16==8` at their own entry (the call pushed 8 bytes).
- Both free to clobber all caller-save regs; we re-load `rsi` and `rdi`
  from the stack after each call.

---

## 6. Forward path (M5)

Scope of the follow-on milestone:

1. **Table expansion.** Populate every sysno in `_syscall_rights_table`
   with its minimum required-rights mask. New right constants per family
   (R_SYS_FS, R_SYS_NET, R_SYS_IPC, R_SYS_PROC, R_SYS_TIME, R_SYS_DEBUG).
2. **Out-of-band coverage.** Extend the check to 517 / 527 (and future
   out-of-band sysnos) so no supervisor path escapes the gate.
3. **Env-unset = CC_DENIED.** Flip the bridge-posture softening once the
   init task mint-FREEZEs its own supervisor cap-env in boot-tail.
4. **Cap-table-rights lookup.** Swap the direct `(stored & required)`
   test for a real `cap_table[stored + 8]` fetch so the check honours
   the full capability-descriptor rights field rather than the slot's
   raw u64.
5. **Per-task cap-env binding.** Move the ambient-env slot out of
   `svc.cap-minter`'s global `[u64; 1]` and into the TCB. The current
   single-task phase cannot distinguish concurrent callers; the TCB
   binding is the trajectory `svc.cap-minter`'s own file header already
   calls out as deferred.

Any one of these can land independently. Order (1) first for test matrix
coverage, then (3), then (4), then (2), then (5).

---

## 7. Audit anchors

- `grep -rn 'SYSCALL CAP_CHECK TABLE OK' src/kernel/` → fingerprint at
  boot confirms the table scrub ran.
- `grep -rnE '0x0F4[01]\b' src/kernel/` → CC_DENIED / CC_BAD_SYSNO
  sentinels. Reserved for this module; any new hit outside
  `cap_check.pdx` or `dispatch.pdx` is a leak.
- `grep -rnE '_syscall_rights_table\b' src/kernel/` → table reads/writes.
  Reads live only in `_syscall_cap_check`; writes only in
  `_syscall_rights_table_init`. The init writes the four M4 entries at
  decimal offsets 600 (75\*8), 1080 (135\*8), 1088 (136\*8), 1096 (137\*8).

---

## 8. Non-goals (M4)

Explicitly out of scope for this landing (any one of these is a separate
ticket):

- Checking caps on 517 / 527 and future out-of-band sysnos.
- Checking caps for sysnos below 138 that are not {75, 135, 136, 137}.
- Hard-failing kernel-origin / pre-userspace syscalls that run without
  an active env.
- Dereferencing stored slot values into `cap_table` rows for real rights
  recovery.
- Per-task cap-env binding.
- Any new user-visible API or syscall surface.
- Any paideia-as encoder changes.

Each of these appears in §6 as part of the M5 forward path.
