# COMP-IMPL-01: sys_cap_invoke sysno reconciliation

Wave: compositor-impl-backtrack (TTT). Authority for the syscall number
is `src/kernel/core/syscall/dispatch.pdx`'s `syscall_dispatch` linear
cmp-chain, which is the ONLY place a sysno turns into a dispatched
handler.

## Finding

`cap_invoke` is dispatched at **sysno 4**:

```
src/kernel/core/syscall/dispatch.pdx:549   cmp rdi, 4;
src/kernel/core/syscall/dispatch.pdx:550   je dispatch_cap_invoke;
src/kernel/core/syscall/dispatch.pdx:1169  call cap_invoke;
```

A tree-wide audit of every real (non-worktree) `.pdx` file that issues
or names the `sys_cap_invoke` syscall found universal agreement on 4:

| Caller | Value | Line |
|---|---|---|
| `src/user/syscall_shim.pdx` `sys_cap_invoke` | `mov rax, 4` | 68 |
| `tools/user/shell/src/syscall.pdx` `SYS_CAP_INVOKE` | `4` | 171 |
| `tools/user/shell/src/syscall.pdx` `sys_cap_invoke` | `mov rax, 4` (implied by `SYS_CAP_INVOKE`) | 604 |
| `design/user/syscall-table.md` row 4 | `cap_invoke` | 45 |
| `design/kernel/pdxfs-syscalls.md` | "via `sys_cap_invoke` sysno 4" | 69 |
| `design/round-retrospectives/r90-xrepo-010-substrate-live.md` | "invoke through `sys_cap_invoke` (sysno 4)" | 41 |

**No caller anywhere in `src/` or `tools/` references sysno 120 for
`cap_invoke`.** A tree-wide grep for `= 120` turns up only unrelated
byte-offset / size / count constants (e.g. `PDXB_D_OFF_SNAP_HEAD`,
`SBS_OFF_ROOT_INODE`, `PERCPU_OFF_HYBRID_CLASS`, `MOVE_RECORD_LEN`) --
none of them name `cap_invoke` or any syscall dispatch. The "many
callers cite sysno 4, others cite 120" premise this wave item was
scoped against does not hold against the current tree: there is no
discrepancy to reconcile.

## Disposition

No code changes. This document is the audit artifact establishing
sysno 4 as authoritative and recording that every live caller already
agrees, so a future contributor hitting a stale "120" reference (in a
comment draft, an issue description, or a stale worktree) has a single
citable source of truth to check against instead of re-deriving it.

## If a sysno-120 caller is ever found

1. Confirm against `src/kernel/core/syscall/dispatch.pdx`'s cmp-chain
   first -- it is the only authority; a design doc or comment that
   disagrees with the dispatcher is wrong, not the other way around.
2. Fix the caller to sysno 4, not the dispatcher.
3. Re-run `tools/verify-syscall-dispatch.sh` (the fingerprint /
   bounds-check verifier already gating this cmp-chain) to confirm the
   `TOTAL_CHECKS` count and bounds (`cmp rdi, 115; ja dispatch_enosys`)
   are unaffected.
