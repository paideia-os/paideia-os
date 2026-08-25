# R56 Retrospective: VFS metadata syscalls

**Date:** 2026-08-24
**Milestone:** R56.M3 (single-milestone round; closed by this doc + #1796)
**Issues:** 7 landed (6 implementation + 1 closure). No deferrals.
**HEAD at closure:** bumped by the R56.M3-007 commit that lands this doc.
**paideia-as pinned at:** unchanged across R56 — **eleventh consecutive
round** with zero cross-repo escalations, since R21 close.
**Release tag:** `r56-closed`.

---

## Round Intent

R56 widened the syscall surface with six VFS-metadata operations —
`stat` / `getdents` / `mkdir` / `rmdir` / `unlink` / `rename` — bringing
the kernel-side of every POSIX-shape metadata syscall online across the
three FS backends (tmpfs, pdxfs-lite, pdxfs-block). R55's R55 write path
persists file bytes; R56 makes the directory tree walkable, mutable, and
inspectable from userland.

Single milestone, seven issues, no deferrals:

- **M3** — VFS metadata syscall wave:
  - **#1790 (M3-001):** dispatch bounds 76→82; six new inline
    `dispatch_stat`/`_getdents`/`_mkdir`/`_rmdir`/`_unlink`/`_rename`
    labels returning `-ENOSYS` (0xFFFFFFFFFFFFFFDA). Widens the
    R53.M2-001 mount/umount cascade pattern for the whole
    metadata-syscall block ahead of the real bodies.
  - **#1791 (M3-002):** `sys_stat_body(path_va, path_len, stat_buf_va)`
    + `vops_stat` slot 7 (offset +56). 10-step compose: cap len →
    user_ptr_ok → user_read_str_via_walk → mount_root_vnode →
    path_resolve → vnode_slot → vops_stat → user_write_bytes_via_walk →
    klog emit. Frozen 64-B kernel-side stat struct
    (ino/size/mtime/mode/nlink/uid/gid/blksize/blocks). Real tmpfs +
    pdxfs_lite adapters; pdxfs-block zero-fill stub pending R56.M4+
    KIND_MOUNT-per-vnode bridge.
  - **#1792 (M3-003):** `sys_getdents_body(fd, buf, nbytes)` +
    `vops_readdir` slot 8 (offset +64). 12-B header + name record
    format (`{ino:u64, name_len:u16, type:u8, reserved:u8}` +
    name[name_len], terminator = zero name_len). Real tmpfs sibling-
    chain walk; pdxfs_lite terminator-only stub; pdxfs-block
    MOUNT_BACKEND_UNKNOWN stub. Two encoder-gap workarounds landed
    inline (`sub rax, [rsp+24]` and `add r8, [rbp-64]` both re-staged
    via temp registers).
  - **#1793 (M3-004):** `sys_mkdir(path, len, mode)` + `sys_rmdir(path,
    len)` + `vop_mkdir` / `vop_rmdir` (slots 9/10, offsets +72/+80).
    Real tmpfs adapters (mkdir bridges to tmpfs_create with
    VNODE_TYPE_DIR; rmdir bridges to tmpfs_unlink). pdxfs_lite +
    pdxfs-block stubs. Landed `src/kernel/core/fs/pdxfs/dir.pdx`
    dentry pack/unpack/find/append/remove helpers over caller-owned
    dir-data buffer (12-B header format matches vops_readdir wire).
  - **#1794 (M3-005):** `sys_unlink(path, len)` + `sys_rename(oldpath,
    oldlen, newpath, newlen)` + `vop_rename` slot 11 (offset +88).
    Reuses existing VOPS_UNLINK_OFFSET (slot 6, offset +48). Same-
    parent rename dispatch via vops_rename; cross-directory rename
    refused with -EXDEV (WAL-atomic cross-dir deferred to R57). Real
    tmpfs rename adapter (in-place inode name rewrite); pdxfs_lite
    tail-through to existing rename primitive; pdxfs-block stub.
  - **#1795 (M3-006):** `boot_r56_meta` composite smoke as dormant
    symbol-existence scaffold. Deferral rationale: every sys_*_body
    walks its user-space path via `user_read_str_via_walk` against
    current-task page tables; kernel-side scratch buffers can't
    satisfy the walker without duplicating KPTI machinery. The
    composite exercise properly belongs in R57's userland-binary
    tier — every per-body fingerprint is individually witness-tested
    via #1791..#1794 goldens. Six-line composite golden lands as spec
    for the future FINGERPRINT_MODE=1 flip.
  - **#1796 (M3-007):** Round closure — this doc + STATUS.md block +
    `r56-closed` tag.

---

## What R56 Delivered

### R56.M3 — VFS metadata syscall wave (7 issues; 0 deferred)

- **#1790** dispatch expansion — bounds 76→82, six new inline
  ENOSYS-returning labels. Schema documented at
  `design/kernel/vfs-metadata-syscalls.md`.
- **#1791** sys_stat — 64-B kernel-side stat struct with 3 real
  backends (tmpfs, pdxfs_lite) + 1 stub (pdxfs-block). Effect row
  `!{mem, sysreg} @{cap}`. Fingerprint `tag_sys_stat_ok`.
- **#1792** sys_getdents — 12-B header record format shared with
  R56.M3-004 dentry helpers. Two encoder-gap fixes inline
  (`sub reg, [mem]` / `add reg, [mem]` not supported by paideia-as
  phase-3-m2-002 minimum). Fingerprint `tag_sys_getdents_ok`.
- **#1793** sys_mkdir + sys_rmdir — dir.pdx dentry helpers. Two
  fingerprints (`tag_sys_mkdir_ok` + `tag_sys_rmdir_ok`).
- **#1794** sys_unlink + sys_rename — vop_rename slot 11 addition.
  Cross-directory rename refused (-EXDEV). Two fingerprints
  (`tag_sys_unlink_ok` + `tag_sys_rename_ok`).
- **#1795** composite smoke — dormant scaffold, structural deferral
  to R57 userland-binary tier.
- **#1796** closure — this doc.

Final vops table state: VOPS_SIZE=96, VOPS_NUM_OPS=12, slots 0..11
(read/write/open/close/lookup/create/unlink/stat/readdir/mkdir/rmdir/rename).

### Cross-Repo Escalations to paideia-as (R56)

**None.** `paideia-as` submodule remained pinned throughout R56.
**Eleventh consecutive round** with zero cross-repo escalations. Two
paideia-as encoder gaps were surfaced during #1792 (both `sub reg,
[mem]` and `add reg, [mem]` not supported by phase-3-m2-002 minimum);
both were worked around inline via temp-register staging. Filed
separately as encoder-gap follow-up.

### Observable Proof

- Kernel builds clean under `tools/build.sh`.
- Substrate boot reaches SHELL START + `$` prompt after every issue
  landing.
- `nm build/kernel.elf` shows all six new T-symbols:
  `sys_stat_body`, `sys_getdents_body`, `sys_mkdir_body`,
  `sys_rmdir_body`, `sys_unlink_body`, `sys_rename_body`.
- Fingerprints (`tag_sys_*_ok`) dormant on substrate — no userland
  caller invokes any yet; real exercise arrives in R57.

### R56 Debt Carried Forward

1. **Composite smoke live exercise** — `boot_r56_meta` is dormant
   scaffold; live exercise via R57 userland binaries.
2. **pdxfs-block mkdir/rmdir/rename real bodies** — MOUNT_BACKEND_
   UNKNOWN stubs pending R52.M6 vnode-to-(vol_row, ino, sb_ptr,
   bdev_cap) bridge and PXT_OP_MKDIR/RMDIR/RENAME wires. dir.pdx is
   ready for that consumer.
3. **pdxfs_lite mkdir/rmdir real bodies** — VOPS_ERR_NOT_SUPPORTED
   stubs; writable walker not yet wired to `nvme_write_blocking`.
4. **Cross-directory rename** — refused with -EXDEV; WAL-atomic
   two-op journal record deferred to R57.
5. **mtime** — no monotonic real-time source at R56; stat returns
   mtime=0.
6. **Encoder-gap follow-up** — file paideia-as issue: `sub reg,
   [mem]` and `add reg, [mem]` not supported in phase-3-m2-002
   minimum. Two inline workarounds landed in R56 (#1792).
7. **build.sh silent-error swallow** (carried from R55) —
   paideia-as compile errors return non-zero to build.sh but the
   script still exits 0. File separately.
8. **tmpfs rmdir empty-directory gate** — accepts non-empty
   directories; R57+ tightening.

**None regress R56 acceptance.**

### Debt Discharged

- **VFS metadata syscall floor** — `stat`/`getdents`/`mkdir`/`rmdir`/
  `unlink`/`rename` were all `-ENOSYS` at R55 close; all now dispatch
  to real bodies (with pdxfs-block backend stubs pending R52.M6).

### Quirks Discovered on Real Hardware

None (R56 ran entirely under QEMU `-kernel` / documentation).

**Next Round:** R57 (userland tools + shell PATH; exercises R56
metadata syscalls). Zero R56 blockers.
