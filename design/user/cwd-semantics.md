# CWD-Semantics for Path-Resolving Syscalls

**Round / issue:** R90-XREPO.010.M1-007 (paideia-os #2115).
**Parent:** R90-XREPO.010 substrate (#1996).
**Plan pointer:** `design/round-retrospectives/r90-xrepo-wave3-plan.md`
§2 "R90-XREPO.010.M1-007 cwd-semantics decision + implementation for
sysno 517".
**Substrate priors:** R86.M1-001..006 (paideia-os #1954..#1959) —
`TASK_OFF_CWD` + every path-touching syscall body wired to read it.

---

## §1. Purpose

Nail down — as a **single shared invariant** — how ring-3 relative
paths resolve across every path-touching syscall in the paideia-os
ABI, and record the resolution anchor the future sysno-517
`sys_cwd_resolve` helper (the mv/rm/cp satellite consumers' shared
realpath primitive) must obey when it lands.

The R86 relative-path substrate already established the anchor for
existing path syscalls; this doc **codifies** that anchor as the
frozen policy and **extends** it forward to sysno 517.

---

## §2. Decision (Option A — caller's `TASK_OFF_CWD`)

Every path-resolving syscall in the paideia-os ABI (including the
future sysno-517 `sys_cwd_resolve` helper) resolves a **relative**
user path against the CALLER's `TASK_OFF_CWD` (+160 in the TCB slab,
per `src/kernel/core/sched/task_pool.pdx:337`), read fresh at entry.

The kernel does **not**:

- Accept a `cwd_vnode_idx` argument from the caller (Option B,
  rejected — changes the ABI for a value the kernel already owns per
  R86.M1-001 and would let a task probe outside its own cwd).
- Anchor against init-root or any other synthetic anchor (Option C,
  rejected — breaks `cd`, breaks user expectations, breaks POSIX-shaped
  scripting).
- Anchor against the parent of the first-supplied file (multi-arg
  Option A' considered for mv/rm/cp; rejected — inconsistent when the
  first argument is itself absolute, and every argument would need its
  own anchor decision).

The anchor is uniform across all path-resolving syscalls listed in §3.

---

## §3. Scope — syscalls this invariant binds

Every syscall body below reads `[_current_tcb + TASK_OFF_CWD]` as
`path_resolve`'s `cwd_vnode_idx` argument on every entry.

| # | Name                | Body                                      | Wired by       |
|---|---------------------|-------------------------------------------|----------------|
| 2 | `open`              | `handlers/sys_open.pdx` (via `vfs_open`)  | R86 substrate  |
| 77 | `stat`             | `sys_stat.pdx`                            | R86.M1-005 (#1958) |
| 79 | `mkdir`            | `sys_mkdir.pdx`                           | R86.M1-005 (#1958) |
| 80 | `rmdir`            | `sys_rmdir.pdx`                           | R86.M1-005 (#1958) |
| 81 | `unlink`           | `sys_unlink.pdx`                          | R86.M1-005 (#1958) |
| 82 | `rename`           | `sys_rename.pdx` (both old_ptr, new_ptr)  | R86 substrate  |
| 85 | `chdir`            | `sys_chdir.pdx`                           | R86.M1-002 (#1955) |
| 86 | `getcwd`           | `sys_getcwd.pdx` (reads, does not resolve)| R86.M1-003 (#1956) |
| **517** | **`cwd_resolve`** (reserved) | *not yet implemented*         | **this doc**   |
| **527** | **`pdxfs_fault_inject`** (reserved) | *not yet implemented*  | R90-XREPO.010.M1-005 |

sysnos 517 and 527 are RESERVED against the R90 wave — see
`design/round-retrospectives/r90-xrepo-wave3-plan.md` §2 for the
allocation record. Every other unlisted sysno in the 100..526 and
528+ range is unassigned.

---

## §4. Anchor selection (path_resolve invariant)

`path_resolve(path_ptr, root_vnode_idx, cwd_vnode_idx)`
(`src/kernel/core/fs/path.pdx:70`) already implements the following
switch, which every §3 caller enters uniformly:

1. **First byte is `/`** → **absolute**. Anchor = `root_vnode_idx`
   (from `mount_root_vnode()`), consume the leading `/`.
2. **First byte is not `/`** → **relative**. Anchor = `cwd_vnode_idx`
   (from `[_current_tcb + TASK_OFF_CWD]`).

Neither the syscall body nor `path_resolve` distinguishes `foo` from
`./foo`: after step (2) the outer component loop's `.` fast-path
(`path.pdx:213`) treats `.` as a no-op component, so both walks end at
the same vnode idx. Callers MUST NOT rely on `./foo` implying anything
different from `foo`.

`..` climbs from the anchor via each vnode's `parent_idx` (+8), so
`../foo` from cwd `/a/b` resolves to `/a/foo`. The task's own cwd is
never rewritten by `path_resolve`; only `sys_chdir_body` mutates
`TASK_OFF_CWD`.

---

## §5. Freshness — the "read once at entry" rule

Every §3 body loads `TASK_OFF_CWD` into a scratch register **before**
the `call path_resolve`, and does not re-read the slot across the
call. `sys_chdir_body` (the only mutator) reads the OLD cwd **before**
overwriting it, so `cd ./sub` resolves against the pre-mutation cwd —
never against a half-updated value (see `sys_chdir.pdx:138-160`).

The future sysno-517 body MUST follow the same read-once discipline.
A skeleton is:

```
mov rax, [rip + _current_tcb]
mov rdx, [rax + 160]                  ; rdx = cwd (TASK_OFF_CWD)
call mount_root_vnode                  ; rax = root_idx
mov rsi, rax
lea rdi, [rip + _sys_cwd_resolve_path_scratch]
call path_resolve                      ; rax = vnode_idx or 0
```

— identical shape to `sys_chdir_body`'s steps (3)–(5).

---

## §6. What sysno 517 does NOT change

- The invariant applies **regardless** of whether sysno 517 exists.
  Every §3 body except sysno 517 is already wired to the invariant as
  of R86.M1-002..006. Sysno 517 inherits it on landing; nothing else
  moves.
- `TASK_OFF_CWD`'s type (u64 holding a `_vnode_pool` index) is
  unchanged. The slot's stamp policy (init to `VNODE_IDX_ROOT = 1` at
  `task_new`, mutated only by `sys_chdir_body`) is unchanged.
- `sys_getcwd`'s parent-chain walk (`sys_getcwd.pdx`) is unaffected —
  it reads `TASK_OFF_CWD` but does not resolve; only the anchor
  syscalls in §3 rows 2, 77–82, 85, and 517 hit `path_resolve`.

---

## §7. Implementation status

- **§3 rows 2, 77–86** — LIVE. Wired to the invariant across the R86
  substrate (paideia-os #1954..#1959) — grep `TASK_OFF_CWD` and
  `+ 160]` across `src/kernel/core/syscall/` for the exact call sites.
  R86.M1-005 (#1958) landed the stat/mkdir/rmdir/unlink cwd wire; the
  chdir/getcwd mutator+reader pair landed at R86.M1-002/003
  (#1955/#1956); rename and open (via `vfs_open`) went through the
  same substrate.
- **§3 row 517 (`sys_cwd_resolve`)** — RESERVED, NOT IMPLEMENTED. No
  body exists in `src/kernel/core/syscall/`, no dispatch case, no
  fingerprint. When the body is landed (separate follow-on issue), it
  MUST resolve against `TASK_OFF_CWD` per §2–§5.
- **§3 row 527 (`sys_pdxfs_fault_inject`)** — RESERVED per
  R90-XREPO.010.M1-005; landing in that sibling issue.

---

## §8. Blocker for the .010.M1-007 implementation sub-scope

Sysno 517 has no body in the tree as of this doc's landing (grep
`sysno 517` across `src/kernel/`: no hits; syscall-table.md's
last-assigned entry is sysno 103). The .010.M1-007 sub-issue
therefore splits cleanly:

- **Design half — SHIPPED (this doc).** Codifies Option A across every
  path-resolving syscall so the future body is not a policy question.
- **Implementation half — DEFERRED.** Requires a follow-on issue that
  (a) picks a caller shape (single-path realpath returning an absolute
  string, most likely — but the shape is not decided in this round),
  (b) lands `src/kernel/core/syscall/sys_cwd_resolve.pdx` following
  the §5 skeleton, (c) adds the `dispatch_cwd_resolve` case in
  `src/kernel/core/syscall/dispatch.pdx`, (d) adds the R90-XREPO.010.M1-007
  fingerprint (`sys pdxfs 517 ok cwd=<n>`), (e) adds a boot witness
  exercising the syscall from init (pid==1) against a seeded relative
  path.

Filing the follow-on and unblocking mv/rm/cp is the next step; nothing
in the mv/rm/cp satellites is blocked on the DECISION any longer —
they can code against the §2 invariant today, and the sysno-517 body
will land under that same rule.

---

## §9. References

- `src/kernel/core/sched/task_pool.pdx:305-338` — `TASK_OFF_CWD`
  header comment (why init is the literal `VNODE_IDX_ROOT`).
- `src/kernel/core/syscall/sys_chdir.pdx` — template body for the
  invariant; use as the shape for sysno 517.
- `src/kernel/core/fs/path.pdx:70-105` — `path_resolve` anchor
  selection (§4 §5).
- `design/user/syscall-table.md` — sysno registry; sysno 517 reserved
  row cross-references this doc.
- `design/round-retrospectives/r90-xrepo-wave3-plan.md` §2 — parent
  plan and sysno 517/527 out-of-band reservations.
