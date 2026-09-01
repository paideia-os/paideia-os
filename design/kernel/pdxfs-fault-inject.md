# pdxfs-fault-inject.md — R90-XREPO.010.M1-005 (paideia-os #2113)

## 1. Purpose

`sys_pdxfs_fault_inject` (sysno **527**, pre-reserved out-of-band by the
mv/rm design docs — see `design/user/syscall-table.md` §Reserved out-of-band
sysnos) is a kernel-side switchboard that lets a boot witness (and, later,
a userspace fault-harness) arm a single, one-shot failure at one of four
PdxFS-substrate call sites. When armed, the *next* traversal of the named
site fails with a class-specific errno; the arm is CONSUMED by that
firing (single-shot), so a caller wanting to fail the *next-next* op must
re-arm.

The primitive exists to close two long-standing test-authoring gaps:

  1. `mv.ENH-001` — a stack-imbalance-under-fault harness that never
     existed because there was no way to force an intermediate PdxFS
     failure without corrupting the disk. This gate unblocks it.
  2. `cp.ENH-002/003/007` and `rm.ENH-005` — partial-txn rollback proofs
     that need a controlled failure INSIDE the commit path. The
     UNDO_APPEND_FAIL class fires exactly that failure without a real
     ENOSPC condition.

## 2. Fault classes (v1)

| Class | Value | Site hooked | Injected failure |
|-------|-------|-------------|------------------|
| `WAL_WRITE_FAIL`     | 1 | `wal_append` (fs/pdxfs/wal.pdx §wal_append entry) | Sets `wal_last_err = WAL_ERR_INJECTED (0xFFFFEFC9)`, returns 0 (per wal_append's "0 = failure" contract). Callers observing `wal_err() == WAL_ERR_INJECTED` see an equivalent-to-`-EIO` failure without a real disk fault. |
| `INODE_ALLOC_FAIL`   | 2 | `tmpfs_inode_alloc` (fs/tmpfs/inode.pdx entry) | Returns `TMPFS_INODE_ALLOC_OOM (0xFFFF)`, byte-identical to a real pool-exhaustion refusal — no bitmap bit consumed, pool state byte-identical to entry. |
| `EXTENT_ALLOC_FAIL`  | 3 | `tmpfs_write` immediately before `phys_alloc` (fs/tmpfs/write.pdx §4.7) | Skips the `phys_alloc` call and jumps to `tmpfs_write_fail`, returning `0xFFFFFFFFFFFFFFFF` — byte-identical to a real OOM. The page-slot publish store (line 104) is skipped since we branch before it, so the inode's page_ptrs stay untouched. |
| `UNDO_APPEND_FAIL`   | 4 | `pdxfs_txn_undo_append` (fs/pdxfs/undo.pdx entry) | Returns `PDXFS_UNDO_ENOSPC (0xFFFFFFFFFFFFFFE4 = -ENOSPC)`, byte-identical to a real per-row buffer or record-cap overflow — no header stored, no offsets slot published, state byte-identical to entry. |

Class `0` means "disarm" — a caller passing arg=0 to the syscall clears
`_pdxfs_fault_armed` without arming a new class. A caller passing an
out-of-range class (>= 5) receives `-EINVAL`.

Single-shot semantics: `pdxfs_fault_check_and_consume(class)` returns
true (1) iff `_pdxfs_fault_armed == class`, and in that case it also
zeroes `_pdxfs_fault_armed` in the same call, so a second traversal of
the same site returns false (0). This matches the design intent
("*next* txn WAL append returns -EIO") and prevents a leftover arm from
silently poisoning unrelated later ops (e.g. init's post-witness
sys_open path).

## 3. Boot-flag gate

`_pdxfs_fault_enabled : u64 = 0` in .bss.

`sys_pdxfs_fault_inject_body` refuses to arm/disarm with `-EPERM
(0xFFFFFFFFFFFFFFF3 = -13)` whenever `_pdxfs_fault_enabled == 0`. That
flag is set to 1 by `pdxfs_fault_enable()`, called from `kernel_main`
immediately before `witness_r90_xrepo_010_005_pdxfs_fault_inject`.

Under `PAIDEIA_BUILD_MODE=release` a future landing gates the
`pdxfs_fault_enable()` call on `_kernel_build_mode == 0`, matching the
"refuses to arm in release builds without the flag" wording in the
parent-issue text. At this landing every build enables the flag at boot
(the kernel already runs many other witness-driven diagnostics; the
fault-inject enable is symmetric).

Even in test mode, `pdxfs_fault_check_and_consume` still short-circuits
to "not armed" when `_pdxfs_fault_enabled == 0`, so a stale arm can
never fire against a caller after the flag is cleared — defense in
depth against a future teardown that clears the enable but not the
armed class.

## 4. Fingerprints

Three lines. None carry a standalone uppercase `OK` token, so no
`tools/verify-fingerprint-coverage.sh` allowlist entries are needed.

| Tag | Emitter | Text (NUL-inclusive) |
|-----|---------|------|
| `tag_sys_pdxfs_fault_inject_armed` | `sys_pdxfs_fault_inject_body` on OK (both arm and disarm) | `sys pdxfs fault inject armed [legacy: SYS PDXFS FAULT INJECT ARMED] class=<n>` |
| `tag_sys_pdxfs_fault_fired`        | `pdxfs_fault_check_and_consume` when the class matches | `sys pdxfs fault fired [legacy: SYS PDXFS FAULT FIRED] class=<n>` |
| `tag_boot_pdxfs_fault_inject_ok`   | Witness rollup once every scenario passes | `boot pdxfs fault inject ok -- count=<n>` |

## 5. Syscall dispatch — sysno 527 out-of-band

Sysno 527 sits far above the current linear `cmp rdi, 107; ja
dispatch_enosys` bounds gate. Rather than widen the gate to 527 (which
would collapse 108..526 into the fall-through chain), the landing adds
one explicit early check *before* the bounds gate:

```
cmp rdi, 527
je  dispatch_pdxfs_fault_inject
cmp rdi, 107
ja  dispatch_enosys
```

The `tools/verify-syscall-dispatch.sh` grep for `cmp.*0x3d` (the wait4
sysno-61 sentinel inside the existing switch chain) still matches, so
no fingerprint-gate rewrite is required.

## 6. Boot witness

`src/kernel/boot/witness/r90_xrepo_010_005_pdxfs_fault_inject.pdx`.
Six stages:

  1. `pdxfs_fault_enable()` — set the boot flag.
  2. `pdxfs_fault_arm(WAL_WRITE_FAIL)` via the syscall body — assert 0.
  3. `pdxfs_fault_check_and_consume(WAL_WRITE_FAIL)` — assert 1 (fired).
  4. `pdxfs_fault_check_and_consume(WAL_WRITE_FAIL)` again — assert 0
     (already consumed).
  5. `pdxfs_fault_arm(INODE_ALLOC_FAIL)`; `tmpfs_inode_alloc()` —
     assert `0xFFFF` (synthetic OOM); `tmpfs_inode_alloc()` again —
     assert success; `tmpfs_inode_free(idx)` — restore pool.
  6. Emit `boot pdxfs fault inject ok -- count=2` rollup.

## 7. Deferred sub-scopes

  * Cross-boot persistence of an arm. Today the .bss zero-init clears
    the arm at every boot; a widening that folds arms into the journal
    is deferred (matches the undo-log `§0 not durable` posture).
  * Multi-class arm (bitfield of armed classes). Today a single u64
    holds the one armed class; a widening to a bitfield lands with the
    first caller that needs to force two failure classes in one op.
  * `PAIDEIA_FAULT_INJECT=1` cmdline arg. Today `pdxfs_fault_enable()`
    is called unconditionally from `kernel_main` in the witness site;
    a widening that reads the kernel cmdline / build_mode gate lands
    with the release-mode enforcement pass.
